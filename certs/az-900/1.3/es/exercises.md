# AZ-900 · Tema 1.3 — Describir los tipos de servicios en la nube
## Ejercicios guiados (IaaS / PaaS / SaaS, responsabilidad compartida, selección de casos de uso)

**Cobertura de los objetivos del examen** (guía de estudio AZ-900, versión 2026-07-20):
- Describir la infraestructura como servicio (IaaS)
- Describir la plataforma como servicio (PaaS)
- Describir el software como servicio (SaaS)
- Identificar los casos de uso apropiados para cada tipo de servicio en la nube

**Peso del dominio:** 9,4

---

## 0. Requisitos previos y control de costos

Vas a aprovisionar recursos reales y facturables. Leé este bloque antes de ejecutar nada.

| Requisito | Comprobación |
|---|---|
| Azure CLI ≥ 2.60 | `az version` |
| Una suscripción de Azure donde tengas **Contributor** sobre un grupo de recursos | `az account show` |
| `jq` para filtrar JSON | `jq --version` |
| Bicep CLI (incluido en versiones recientes de `az`) | `az bicep version` |
| Rol de Microsoft Entra para leer licencias (con Global Reader alcanza) | Solo Ejercicio 5 — de solo lectura |

**Costo estimado del recorrido completo:** menos de USD 1 si completás el Ejercicio 10 (limpieza) el mismo día. Una VM `Standard_B2s` más un plan de App Service `B1` cuestan aproximadamente USD 0,12/hora en conjunto. **No te alejes de este laboratorio dejando recursos en ejecución.**

Definí tus variables de trabajo una sola vez:

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

## Ejercicio 1 — Construí la escalera de responsabilidades antes de tocar Azure

Todo el objetivo se reduce a una pregunta: **¿dónde está el límite entre vos y Microsoft?** Hacé esto primero en papel, y después dejá que la CLI te confirme o te refute.

1. Dibujá una tabla de diez filas. Filas, de arriba hacia abajo:
   `Information and data` · `Devices (mobile and PCs)` · `Accounts and identities` · `Identity and directory infrastructure` · `Applications` · `Network controls` · `Operating system` · `Physical hosts` · `Physical network` · `Physical datacenter`.
2. Agregá cuatro columnas: `SaaS`, `PaaS`, `IaaS`, `On-premises`.
3. Completá cada celda con uno de estos valores: `Customer`, `Microsoft`, `Shared`.
4. Encerrá en un círculo las tres filas que nunca cambian de valor a lo largo de las columnas SaaS/PaaS/IaaS, y las tres filas que nunca cambian en el sentido opuesto.
5. Encerrá en un círculo la única fila que pasa de `Microsoft` a `Customer` exactamente en el límite PaaS → IaaS. Escribí su nombre en el margen: el examen evalúa esa fila más que cualquier otra.
6. Compará tu tabla con la canónica en <https://learn.microsoft.com/en-us/azure/security/fundamentals/shared-responsibility>. Corregí tus celdas; no corrijas tu recuerdo de ellas — vas a volver a derivar la tabla en el Ejercicio 9.

**Verificá tu comprensión**

- **Q1.** ¿Qué tres filas son siempre responsabilidad del cliente, en todos los modelos de servicio incluido SaaS, y por qué un proveedor de nube nunca podría hacerse cargo de ellas aunque quisiera?
- **Q2.** ¿Qué fila cambia en el límite PaaS → IaaS, y cuál es la consecuencia operativa concreta de ese cambio un martes a la mañana después de que se publica un CVE?
- **Q3.** `Identity and directory infrastructure` es `Shared` en las tres columnas de nube. Dé un ejemplo de algo que hace Microsoft en esa fila y algo que debés hacer vos.
- **Q4.** Un colega dice "nos pasamos a SaaS, así que la pérdida de datos ahora es problema de Microsoft". Usando solo la tabla, explicá con precisión por qué eso es incorrecto.

---

## Ejercicio 2 — IaaS: aprovisionalo y después demostrá que el sistema operativo es tuyo

IaaS te da las primitivas de cómputo, almacenamiento y red. Todo del sistema operativo hacia arriba es tuyo. Este ejercicio hace que esa propiedad sea *medible* en lugar de afirmada.

1. Creá una VM Linux. Notá que este único comando crea silenciosamente **seis** recursos:

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

2. Contá lo que ahora administrás:

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

3. Preguntale a Azure qué necesita el sistema operativo invitado. Esta API existe **solo** para IaaS — acordate de eso cuando busques su equivalente PaaS en el Ejercicio 3:

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

4. Confirmá que el kernel es tuyo tocándolo desde afuera:

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

Vos sos `root`. Nadie en Microsoft lo es. Esa es la definición del límite de IaaS.

5. Ahora expresá el mismo despliegue de forma declarativa, para que la superficie de responsabilidad sea visible como código. Guardalo como `iaas.bicep`:

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

6. Validalo sin desplegar (una pasada de what-if no cuesta nada y no cambia nada):

```bash
az deployment group what-if \
  -g "$RG" -f iaas.bicep \
  --parameters adminSshPublicKey="$(cat ~/.ssh/id_rsa.pub)" \
  --no-pretty-print --query "changes[].{type:changeType, id:resourceId}" -o table
```

7. Contá las líneas de ese archivo y retené el número: `wc -l iaas.bicep` → `~118`.

**Verificá tu comprensión**

- **Q5.** Configuraste `patchMode: 'AutomaticByPlatform'` y ahora Azure instala los parches por vos. ¿Se movió el sistema operativo fuera de tu columna en la tabla de responsabilidad compartida? Defendé tu respuesta.
- **Q6.** `az vm assess-patches` devolvió `"critical": 2`. En un servicio PaaS, ¿qué comando devuelve la cifra equivalente, y qué te dice eso sobre la abstracción?
- **Q7.** Un solo `az vm create` produjo seis recursos. Nombrá los tres que son *controles de red* e indicá quién es dueño de los controles de red en la columna IaaS.
- **Q8.** `az vm run-command invoke` se ejecutó como `uid=0(root)`. ¿Qué permiso de Azure RBAC otorga eso, y qué demuestra su existencia sobre el límite de IaaS?
- **Q9.** Dé dos características de carga de trabajo que hacen de IaaS la elección correcta sobre PaaS, formuladas como cosas que PaaS *no puede* hacer y no como preferencias.

---

## Ejercicio 3 — PaaS: ejecutá la misma clase de carga de trabajo sin ningún sistema operativo en tu columna

1. Creá un plan de App Service Basic y una aplicación web Linux:

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

2. Intentá encontrar la máquina. Ejecutá deliberadamente el comando de IaaS contra la app PaaS:

```bash
az vm assess-patches -g "$RG" -n "app-az900-$SUFFIX"
```

```
(ResourceNotFound) The Resource 'Microsoft.Compute/virtualMachines/app-az900-7b3af10c'
under resource group 'rg-az900-svctypes' was not found.
```

El recurso no existe porque **no hay ninguna VM en tu suscripción que pueda serlo**. Microsoft opera el host; vos nunca ves su ID de recurso.

3. Inspeccioná lo que *sí* podés configurar. Esa es exactamente la superficie de tu responsabilidad en PaaS:

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

Versión del runtime, piso de TLS, cantidad de workers: cuestiones de aplicación y configuración. Sin kernel, sin gestor de paquetes, sin reinicio.

4. Abrí una shell **dentro del contenedor** y observá las dos cosas que delatan la abstracción:

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

La versión del kernel que ves es la del **host**, parcheada por Microsoft según el cronograma de Microsoft; no podés reiniciar hacia otra distinta. Solo `/home` es almacenamiento persistente — `/opt/keepme` desaparece en el próximo reinicio, evento de escalado o actualización de plataforma.

5. Escalá la plataforma sin tocar ninguna máquina:

```bash
az appservice plan update -g "$RG" -n plan-paas-demo --number-of-workers 3 -o table
az appservice plan show -g "$RG" -n plan-paas-demo --query "{sku:sku.name, capacity:sku.capacity}" -o yaml
```

```yaml
capacity: 3
sku: B1
```

Ahora existen tres instancias. No aprovisionaste, ni creaste imágenes, ni uniste al dominio, ni parcheaste, ni monitoreaste ninguna de ellas, y ninguna aparece en `az resource list`.

6. Expresá la misma plataforma de forma declarativa. Guardalo como `paas.bicep`:

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

7. Compará los dos manifiestos lado a lado:

```bash
wc -l iaas.bicep paas.bicep
```

```
 118 iaas.bicep
  40 paas.bicep
 158 total
```

La misma capacidad de negocio — servir HTTP. 118 líneas contra 40, cinco recursos declarados contra dos, y uno de los dos archivos contiene una clave SSH que ahora tenés que rotar.

**Verificá tu comprensión**

- **Q10.** `az vm assess-patches` falló con `ResourceNotFound` para la aplicación web. Explicá, en términos de responsabilidad compartida, por qué ese es el comportamiento *esperado y correcto* y no una carencia de la CLI.
- **Q11.** Dentro de `az webapp ssh` viste el kernel `6.8.0-1029-azure`. ¿Quién parchea ese kernel, y qué pasa con tu sesión, con tus escrituras en `/opt` y con tus solicitudes en vuelo cuando lo hacen?
- **Q12.** Escalaste `plan-paas-demo` a tres workers. ¿Cuántas entradas adicionales aparecieron en `az resource list -g $RG`, y qué enseña ese número sobre lo que significa "administrado"?
- **Q13.** El archivo `iaas.bicep` lleva un parámetro `@secure()` con la clave SSH y `paas.bicep` no. Relacioná esa única diferencia con una fila específica de la tabla de responsabilidades.
- **Q14.** Tu equipo necesita cargar un módulo del kernel específico y aplicar un ajuste `sysctl` personalizado. ¿Sigue siendo App Service un candidato? Nombrá el tipo de servicio al que tenés que replegarte y un servicio de Azure que lo provea.

---

## Ejercicio 4 — Serverless: PaaS donde la unidad de facturación es la que te delata

Serverless no es un cuarto tipo de servicio en el examen — es PaaS llevado a su límite, donde dejás de pagar por capacidad asignada y empezás a pagar por trabajo realizado.

1. Creá la cuenta de almacenamiento que requiere una function app, y después la function app en un plan de consumo:

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

2. Listá los planes de App Service del grupo de recursos y buscá uno que vos nunca creaste:

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

`Y1` / `Dynamic` con **cero workers**. No hay nada asignado, y por lo tanto nada que pagar, hasta que llega un evento.

3. Confirmá el contrato de escalado:

```bash
az functionapp show -g "$RG" -n "func-az900-$SUFFIX" \
  --query "{sku:sku, state:state, kind:kind}" -o yaml
```

```yaml
kind: functionapp,linux
sku: Dynamic
state: Running
```

4. Contrastá las tres posturas de cómputo que ahora tenés corriendo en un mismo grupo de recursos:

```bash
az resource list -g "$RG" \
  --query "[?type=='Microsoft.Compute/virtualMachines' || type=='Microsoft.Web/sites' || type=='Microsoft.Web/serverfarms'].{name:name, type:type}" -o table
```

**Verificá tu comprensión**

- **Q15.** El plan de consumo informa `workers: 0` mientras el `state: Running`. Reconciliá esos dos hechos e indicá qué se te factura en ese estado.
- **Q16.** Una function app en un plan de consumo y una aplicación web en un plan B1 no atienden ninguna solicitud durante 24 horas. ¿Cuál cuesta dinero, y qué te dice esa diferencia sobre *capacidad asignada* versus *capacidad consumida*?
- **Q17.** Serverless elimina la planificación de capacidad. Nombrá dos cosas que **no** elimina de tu columna de responsabilidad.
- **Q18.** Un trabajo por lotes corre 40 minutos al 100% de CPU, una vez por noche. ¿Es el plan de consumo el hogar correcto para eso? Identificá la restricción concreta de la plataforma que decide la respuesta.

---

## Ejercicio 5 — SaaS: la carga de trabajo sin ningún recurso ARM

La prueba más clara de SaaS es negativa: el producto que consumís no aparece en tu suscripción, porque no estás alquilando infraestructura — estás comprando asientos en la aplicación que otro tiene corriendo.

1. Listá todos los tipos de recursos que contiene tu suscripción y buscá una suite de productividad:

```bash
az resource list --query "[].type" -o tsv | sort -u | grep -iE 'office|exchange|teams|dynamics' || echo "no SaaS product found in ARM"
```

```
no SaaS product found in ARM
```

2. Preguntale a Microsoft Graph qué es lo que realmente poseés. Ahí es donde vive el inventario de SaaS: licencias, no recursos:

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

La unidad de compra es un **asiento de usuario**, no una hora-VM ni un GB-segundo.

3. Confirmá que el tenant que contiene esas licencias es el mismo plano de identidad contra el cual se autentican tus recursos IaaS y PaaS:

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

Un tenant, tres modelos de servicio. Ese tenant compartido es exactamente la razón por la cual `Identity and directory infrastructure` es `Shared` y nunca `Microsoft` en la columna SaaS.

4. Encontrá la única superficie de control que SaaS todavía te entrega: acceso condicional sobre la identidad, no sobre la infraestructura:

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

No podés parchear Exchange Online. Sí podés decidir quién llega a él, desde qué dispositivo y bajo qué condiciones — `Accounts and identities`, sigue siendo tuyo.

**Verificá tu comprensión**

- **Q19.** Microsoft 365 produjo cero filas en `az resource list` pero filas reales en `subscribedSkus`. Enunciá la regla general que esto ilustra sobre cómo se inventaría y se factura el SaaS.
- **Q20.** En la columna SaaS, `Applications`, `Network controls` y `Operating system` son todas de Microsoft. Nombrá las tres filas que siguen siendo enteramente tuyas, y dé un control de Azure/Entra que hayas ejercido en este ejercicio para cada una.
- **Q21.** Tu organización debe retener datos de buzón durante siete años para un regulador. ¿De quién es la responsabilidad de esa política de retención, y qué fila de la tabla lo resuelve?
- **Q22.** Un proveedor ofrece "un producto SaaS que desplegás en tu propia suscripción y parcheás vos mismo". Usando los criterios de este ejercicio, argumentá si eso es SaaS, y qué es en realidad.

---

## Ejercicio 6 — Ejercitación rápida de clasificación por proveedor de recursos

Los proveedores de recursos son la huella digital legible por máquina de un servicio. Esta ejercitación entrena el reflejo de examen de clasificar un nombre de servicio desconocido en menos de cinco segundos.

1. Volcá los proveedores registrados en tu suscripción:

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

2. Para cada servicio de abajo, escribí `IaaS`, `PaaS` o `SaaS` **antes** de leer ninguna respuesta. Después justificá cada uno con la fila de la tabla de responsabilidades que lo decidió:

| # | Servicio | Tu respuesta | Fila decisiva |
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

3. Verificá el parecido de familia: ejecutá `az provider show -n Microsoft.Sql --query "resourceTypes[?resourceType=='servers/databases'].locations | [0] | length(@)"` y notá que una base de datos PaaS expone *regiones*, nunca *hosts*.

**Verificá tu comprensión**

- **Q23.** Los ítems (b), (c) y (d) son todos "SQL en Azure". Ordenalos de mayor a menor responsabilidad del cliente e indicá exactamente qué ganás y qué perdés en cada paso.
- **Q24.** AKS es la trampa clásica. Dé la respuesta que espera el examen, y después el matiz honesto de ingeniería sobre el plano de control versus los grupos de nodos.
- **Q25.** Azure Virtual Desktop entrega escritorios Windows a los usuarios. Argumentá a favor de clasificarlo como PaaS y a favor de clasificarlo como SaaS, y después decí cuál clasificación respalda la guía de estudio de AZ-900.

---

## Ejercicio 7 — Análisis forense de la unidad de facturación con la API de precios minoristas

Si podés nombrar la unidad en la que factura un servicio, podés nombrar su tipo de servicio. Este ejercicio usa la API pública y no autenticada de precios minoristas de Azure — sin suscripción, sin costo.

1. Preguntá cuánto cuesta una VM:

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

2. Preguntá cuánto cuesta el plan PaaS:

```bash
curl -s -G 'https://prices.azure.com/api/retail/prices' \
  --data-urlencode "\$filter=armRegionName eq 'eastus' and serviceName eq 'Azure App Service' and skuName eq 'B1' and priceType eq 'Consumption'" \
  | jq -r '.Items[] | [.productName, .meterName, .unitOfMeasure, .retailPrice] | @tsv' | column -t
```

```
Azure App Service Basic Plan - Linux  B1 App  1 Hour  0.0130
```

3. Preguntá cuánto cuesta serverless:

```bash
curl -s -G 'https://prices.azure.com/api/retail/prices' \
  --data-urlencode "\$filter=armRegionName eq 'eastus' and serviceName eq 'Functions' and priceType eq 'Consumption'" \
  | jq -r '.Items[] | [.meterName, .unitOfMeasure, .retailPrice] | @tsv' | column -t
```

```
Standard Execution Time    10 GB Second   0.000016
Standard Total Executions  10 Executions  0.000002
```

4. Escribí las tres unidades en una columna y agregá la cuarta del Ejercicio 5:

```
IaaS        → 1 Hour of an allocated machine, running or idle
PaaS        → 1 Hour of an allocated plan, running or idle
Serverless  → GB-second of memory actually used + per execution
SaaS        → 1 user seat per month  (subscribedSkus.prepaidUnits.enabled)
```

> Los precios minoristas cambian continuamente y varían por región y moneda; tratá los números de arriba como forma, no como cotizaciones. El examen nunca evalúa un precio — evalúa cuál de las cuatro *unidades* aplica.

**Verificá tu comprensión**

- **Q26.** La VM B2s y el plan B1 de App Service facturan ambos por hora. Si la unidad de facturación es idéntica, ¿qué difiere realmente entre ellos, y dónde se manifiesta esa diferencia en una factura al final de un mal trimestre?
- **Q27.** Una carga de trabajo recibe 30 solicitudes por día, cada una terminando en 200 ms. Usando las unidades de arriba, argumentá cuál es la más barata de las tres opciones de cómputo y nombrá el modo de falla de elegir en cambio el plan B1.
- **Q28.** SaaS factura por asiento. ¿Qué pasa con tu factura de SaaS cuando el tráfico al producto se triplica pero la dotación de personal se mantiene plana, y qué revela eso sobre quién absorbió el riesgo de capacidad?

---

## Ejercicio 8 — La escalera de diagnóstico: dónde viven los logs en cada modelo

Tu punto de entrada para el troubleshooting está determinado por tu tipo de servicio. Equivocarte en esto desperdicia los primeros treinta minutos de cada incidente.

1. **IaaS** — obtenés la consola, porque la máquina es tuya:

```bash
az vm boot-diagnostics get-boot-log -g "$RG" -n vm-iaas-demo | tail -5
```

```
[    3.482119] cloud-init[812]: Cloud-init v. 24.1.3 finished at ...
Ubuntu 24.04.3 LTS vm-iaas-demo ttyS0

vm-iaas-demo login:
```

2. **PaaS** — obtenés el stdout de la aplicación, no el de la máquina:

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

No hay log de arranque. No hay `dmesg`. Si el host se porta mal, no lo depurás vos — reportás contra la plataforma.

3. **Fallas del lado de la plataforma, en cualquier modelo** — Resource Health te dice cuándo el problema es de Microsoft:

```bash
SUB=$(az account show --query id -o tsv)
az rest --method get \
  --url "https://management.azure.com/subscriptions/$SUB/providers/Microsoft.ResourceHealth/events?api-version=2022-10-01&\$filter=properties/eventType eq 'ServiceIssue'" \
  --query "value[0:5].{title:properties.title, status:properties.status, impact:properties.impactStartTime}" -o table
```

4. **SaaS** — no hay ninguna API en tu suscripción. La señal vive en el centro de administración de Microsoft 365 bajo **Health → Service health**, y en el Centro de mensajes para los avisos de cambios. Confirmá la asimetría: nada de lo que ejecutaste en los pasos 1–3 puede decirte que Exchange Online está degradado.

**Verificá tu comprensión**

- **Q29.** Ordená IaaS, PaaS y SaaS según cuántos datos de diagnóstico te expone la plataforma, y explicá por qué ese orden es exactamente el inverso del orden de la carga operativa.
- **Q30.** Una app de App Service devuelve HTTP 503. Listá, en orden, los dos lugares que revisás y el único lugar que *no podés* revisar, nombrando la fila de responsabilidad que cierra ese tercero.
- **Q31.** Los usuarios reportan que Teams está fallando. Tu hoja de Azure Service Health está toda en verde. Explicá por qué ambos hechos pueden ser ciertos a la vez.

---

## Ejercicio 9 — Ejercitación de decisión por caso de uso (formato de examen)

Para cada escenario, escribí el tipo de servicio, la restricción decisiva y un servicio de Azure concreto. Respondé sin releer los ejercicios anteriores.

1. Un hospital ejecuta una aplicación clínica de 15 años que requiere Windows Server 2012 R2, un driver ODBC específico instalado a nivel de sistema, y un agente en modo kernel con licencia del proveedor. Debe migrarse de hardware moribundo en seis semanas sin cambios de código.
2. Un equipo de nóminas de 400 personas necesita correo, documentos y videoconferencias para fin del mes que viene. No hay personal de operaciones de TI.
3. Un equipo de desarrollo quiere publicar una API REST en Python, desplegar desde GitHub en cada merge, correr staging y producción lado a lado, y nunca hablar de servidores.
4. Una plataforma de IoT recibe un mensaje aproximadamente cada 90 segundos, y debe ejecutar una rutina de validación de 300 ms en cada uno. El tráfico es cero durante la noche.
5. Un banco regulado debe mantener el motor de base de datos en una versión congelada en 15.4 durante los próximos 18 meses, con la capacidad de adjuntar un agente de auditoría de terceros al proceso de la base de datos.
6. Un despliegue de CRM para una organización de ventas de 2.000 personas, con licenciamiento por usuario y sin partida presupuestaria de infraestructura.
7. Un grupo de investigación necesita 200 nodos GPU durante once días para entrenar un modelo, con control total de las versiones del driver CUDA, y después quiere liberar todo.

**Verificá tu comprensión**

- **Q32.** ¿Cuáles escenarios son IaaS, y qué única palabra aparece en cada una de sus descripciones que fuerza la respuesta?
- **Q33.** El escenario 3 y el escenario 4 son ambos PaaS. ¿Qué distingue al *plan* correcto para cada uno, y qué unidad de facturación se deriva de eso?
- **Q34.** El escenario 5 dice "congelada en 15.4" y "adjuntar un agente al proceso de la base de datos". ¿Cuál de esas dos frases por sí sola ya descartaría una base de datos totalmente administrada, y por qué?
- **Q35.** Reescribí el escenario 1 como un conjunto de requisitos que harían viable PaaS, y estimá lo que esa reescritura le cuesta al hospital y que el lift-and-shift no.
- **Q36.** Un interesado pide "la opción más barata" entre las siete. Explicá por qué el tipo de servicio, y no el precio, es el primer filtro, y dé la secuencia correcta de preguntas a hacer en su lugar.

---

## Ejercicio 10 — Limpieza y verificación de costos

1. Confirmá qué sigue corriendo y cuánto te está costando por hora:

```bash
az resource list -g "$RG" --query "length(@)"
az vm list -d -g "$RG" --query "[].{name:name, power:powerState}" -o table
az appservice plan list -g "$RG" --query "[].{name:name, sku:sku.name, capacity:sku.capacity}" -o table
```

2. Atención a la trampa: desasignar la VM detiene los cargos de cómputo pero **no** los del disco ni los de la IP pública.

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

Se sigue facturando. Esto es `IaaS` en una línea: los recursos que asignaste siguen asignados hasta que digas lo contrario.

3. Borrá todo:

```bash
az group delete --name "$RG" --yes --no-wait
az group exists --name "$RG"
```

```
true
```

(`--no-wait` retorna de inmediato; volvé a ejecutar `az group exists` después de unos minutos hasta que devuelva `false`.)

4. Verificá que el lado SaaS no necesita limpieza, y entendé por qué:

```bash
az rest --method get --url "https://graph.microsoft.com/v1.0/subscribedSkus" \
  --query "value[].skuPartNumber" -o tsv
```

Las licencias no se ven afectadas por nada de lo que hiciste en ARM. Otro plano, otro ciclo de vida, otra factura.

**Verificá tu comprensión**

- **Q37.** Una VM desasignada seguía generando cargos. Nombrá los dos tipos de recursos responsables y explicá qué modelo de servicio hace estructuralmente posible esta clase de sorpresa.
- **Q38.** Borrar el grupo de recursos eliminó todos los artefactos de IaaS y PaaS pero no cambió nada de tus licencias de Microsoft 365. Enunciá el principio general sobre el ciclo de vida de SaaS que esto demuestra.

---

<details>
<summary><strong>Respuestas</strong></summary>

### Ejercicio 1 — Escalera de responsabilidades

**A1.** `Information and data`, `Devices (mobile and PCs)` y `Accounts and identities` son siempre del cliente, en todos los modelos. Un proveedor no puede ser dueño de ellas porque no puede conocer la semántica: solo vos sabés qué registros están regulados, qué empleado debería seguir teniendo acceso después de cambiar de equipo, y qué laptop pertenece a un contratista. Estas son decisiones de negocio expresadas como configuración, no infraestructura que Microsoft pueda operar en tu nombre. Los hosts físicos, la red física y el datacenter físico son la imagen espejo — siempre de Microsoft en las tres columnas de nube, y del cliente solo en on-premises.

**A2.** `Operating system`. Es de Microsoft en SaaS y PaaS, y del cliente en IaaS. La consecuencia del martes a la mañana: con IaaS, un CVE publicado significa que *vos* corrés la evaluación, programás la ventana de mantenimiento, instalás el paquete, reiniciás el sistema invitado y verificás la flota — medido en horas-ingeniero proporcionales a la cantidad de VMs. Con PaaS, el mismo CVE significa que Microsoft rota la imagen subyacente y quizás ni siquiera recibas una notificación. Esa única fila es donde realmente vive la mayor parte de la diferencia de costo operativo entre IaaS y PaaS.

**A3.** Microsoft opera el servicio de Entra ID en sí — la disponibilidad del directorio, la replicación, la emisión de tokens, las implementaciones del protocolo de autenticación, y la seguridad física y lógica de la infraestructura del directorio. Vos configurás lo que corre sobre él: configuración del tenant, asignaciones de grupos y roles, políticas de acceso condicional, imposición de MFA, registros de aplicaciones, reglas de colaboración externa, y el ciclo de vida de altas/cambios/bajas. Microsoft garantiza que el directorio responde; vos determinás a qué responde que *sí*.

**A4.** `Information and data` es del cliente en **todas** las columnas, SaaS incluido. Microsoft garantiza la disponibilidad y durabilidad de la plataforma, no la corrección ni la supervivencia de tu contenido: un usuario que borra un elemento del buzón, un script que sobrescribe una biblioteca de SharePoint, o un actor de ransomware con credenciales válidas están todos dentro de tu fila de responsabilidad. La retención, el respaldo más allá de las ventanas por defecto de la plataforma, la clasificación y la política de recuperación siguen siendo tuyas sin importar el modelo de servicio.

### Ejercicio 2 — IaaS

**A5.** No. La automatización cambia *quién ejecuta la acción*, no *quién es responsable del resultado*. Vos elegiste el modo de parcheo, sos dueño de la política de reinicio y de su radio de impacto, sos dueño de la regresión cuando un parche rompe la aplicación, y sos dueño de la evidencia de cumplimiento de que el parche se aplicó. `AutomaticByPlatform` es Azure operando un control **dentro de tu columna de responsabilidad y por instrucción tuya** — no es una transferencia de la fila. La prueba es que `az vm assess-patches` sigue existiendo y sigue devolviendo *tu* conteo de pendientes; nadie en Microsoft responde por que ese número llegue a cero.

**A6.** No existe ninguno. No hay equivalente PaaS de `az vm assess-patches`, y esa ausencia es la abstracción funcionando correctamente, no una funcionalidad faltante: el estado de parcheo del sistema operativo invitado no es una propiedad visible para el cliente en un servicio PaaS, porque el sistema operativo invitado no está en tu columna de responsabilidad. Cuando un comando no tiene contraparte en PaaS, eso suele ser una señal confiable de que la preocupación que atiende se movió al proveedor.

**A7.** `vm-iaas-demoVNET` (`Microsoft.Network/virtualNetworks`), `vm-iaas-demoNSG` (`Microsoft.Network/networkSecurityGroups`) y `vm-iaas-demoPublicIP` (`Microsoft.Network/publicIPAddresses`); la NIC podría contarse como un cuarto. `Network controls` es **Customer** en la columna IaaS — que es exactamente por qué la CLI creó un NSG cuyas reglas ahora tenés que revisar, y por qué `--nsg-rule SSH` abriendo el puerto 22 a `Internet` es tu riesgo a aceptar o acotar, no el de Azure.

**A8.** `Microsoft.Compute/virtualMachines/runCommand/action`, incluido en roles como Virtual Machine Contributor y Contributor. Su existencia demuestra que el límite de IaaS está por debajo del sistema operativo: un permiso del plano de control de Azure otorga ejecución como root sin mediación dentro del sistema invitado, porque ese sistema invitado es propiedad tuya. No existe un permiso análogo del plano de control que otorgue root en un host de App Service — porque ese host no es tuyo. También plantea un punto de seguridad importante: el RBAC del plano de control sobre IaaS es, en la práctica, acceso al plano de datos de la máquina.

**A9.** Dos cualesquiera de estas:
- **Necesitás controlar el kernel o cargar código en modo kernel** — drivers, versiones de GPU/CUDA, módulos del kernel, ajustes de `sysctl`, agentes de proveedores con licencia que corren en espacio de kernel. PaaS no puede expresar esto; no hay un kernel en tu columna para modificar.
- **El software no se puede replataformar** — versiones antiguas de Windows, instaladores MSI con efectos secundarios a nivel de sistema, aplicaciones que requieren una identidad de máquina específica, rutas locales hardcodeadas, o registro COM/GAC.
- **Necesitás lift-and-shift sin cambios de código y con una fecha límite** — PaaS requiere que la aplicación encaje en el contrato de runtime, sistema de archivos y ciclo de vida de la plataforma; cambiar la aplicación es un proyecto, y IaaS es la opción que no requiere uno.

### Ejercicio 3 — PaaS

**A10.** El comando falló porque no existe ningún recurso `Microsoft.Compute/virtualMachines` que respalde la aplicación web *en tu suscripción*. El cómputo de App Service se toma de una flota multi-tenant operada por Microsoft que no se proyecta en tu grafo de recursos. Como `Operating system` es de Microsoft en la columna PaaS, el estado de parcheo no es una propiedad que tengas derecho a consultar — y un `ResourceNotFound` es la API declinando correctamente exponer algo fuera de tu límite de responsabilidad. Una carencia de la CLI se vería como un comando no implementado; esto se ve como un recurso ausente, que es la respuesta semánticamente exacta.

**A11.** Microsoft lo parchea, según el cronograma de Microsoft, sin consultarte. Cuando lo hacen, tu sesión SSH termina, todo lo que escribiste fuera de `/home` desaparece (solo `/home` está respaldado por almacenamiento compartido persistente; el resto del sistema de archivos del contenedor es efímero), y las solicitudes en vuelo se drenan hacia otra instancia — que es precisamente por qué `alwaysOn`, múltiples workers y un diseño de aplicación sin estado no son cortesías opcionales en App Service sino requisitos del contrato de la plataforma. Consecuencia de diseño: nunca almacenes estado de sesión, cargas de archivos ni cachés en el sistema de archivos local del contenedor.

**A12.** Cero. `az resource list` sigue mostrando las mismas entradas `Microsoft.Web/serverfarms` y `Microsoft.Web/sites`; solo cambió `sku.capacity` de 1 a 3. "Administrado" significa que las unidades de ejecución de la plataforma no se modelan como recursos en tu suscripción: vos declarás una intención (`capacity: 3`) y Microsoft la satisface con máquinas que nunca nombrás, nunca parcheás, nunca monitoreás y nunca ves. Contrastá con el Ejercicio 2, donde una sola VM produjo seis recursos direccionables que ahora tenés que gobernar.

**A13.** `Operating system`. Una clave SSH existe únicamente porque hay un sistema operativo invitado con un login, un archivo `authorized_keys` y un ciclo de vida de cuenta — todo en tu columna bajo IaaS. Como el sistema operativo es de Microsoft bajo PaaS, no existe ninguna credencial de host que tengas que guardar, distribuir, almacenar en Key Vault, rotar periódicamente o filtrar. El parámetro `@secure()` en `iaas.bicep` es la tabla de responsabilidades apareciendo como una línea de código, y su ausencia en `paas.bicep` es toda una clase de trabajo de gestión de credenciales que PaaS elimina.

**A14.** No. Los módulos del kernel y los ajustes de `sysctl` requieren control del sistema operativo, que App Service no te da. Repleguate a **IaaS** — Azure Virtual Machines, o Virtual Machine Scale Sets si necesitás la elasticidad que estarías resignando. (Azure Kubernetes Service es un punto medio parcial, ya que controlás las VMs de los grupos de nodos y podés aplicar configuración a nivel de nodo mediante un DaemonSet o una imagen de nodo personalizada, pero entonces volviste a aceptar la fila del sistema operativo para esos nodos.)

### Ejercicio 4 — Serverless

**A15.** `state: Running` describe la disposición de la *aplicación* a aceptar eventos — sus disparadores están registrados y la plataforma está escuchando. `workers: 0` describe el *cómputo asignado*, que es genuinamente nada mientras está ociosa. Se te factura únicamente la cuenta de almacenamiento que respalda la function app y las ejecuciones que ocurran; el medidor de cómputo se queda en cero. Esta es la propiedad definitoria de serverless: la capacidad es una consecuencia de la demanda, no un prerrequisito de ella.

**A16.** La aplicación web B1 cuesta dinero — aproximadamente USD 0,013/hora × 24, incurridos haya o no una sola solicitud. La function app de consumo no cuesta prácticamente nada más allá de su cuenta de almacenamiento. El plan B1 factura **capacidad asignada** (reservaste el equivalente a una máquina de plataforma y quedó lista); el plan de consumo factura **capacidad consumida** (GB-segundos realmente ejecutados más cantidad de ejecuciones). Estar ocioso es gratis en un modelo y precio completo en el otro, que es por qué la forma de las solicitudes — y no su volumen — suele decidir entre ambos.

**A17.** Dos cualesquiera de estas: la corrección del código de la aplicación y su cadena de suministro de dependencias; `Information and data` (lo que la función lee, escribe y registra); `Accounts and identities` (su identidad administrada y el RBAC que le otorgás); el manejo de secretos y configuración; y el gobierno de costos — serverless elimina la planificación de capacidad pero introduce la planificación de *concurrencia*, ya que una fuente de eventos sin límite escala tu factura linealmente sin techo salvo que le pongas uno.

**A18.** Probablemente no en Consumption. La restricción decisiva es el tiempo límite de ejecución del plan de consumo: 5 minutos por defecto, elevable a un máximo duro de 10 minutos. Un trabajo de 40 minutos no puede completarse. Las respuestas correctas son descomponerlo en pasos durables y reanudables (Durable Functions), o migrar a un plan sin ese techo (Premium o Dedicated/App Service plan), o usar un servicio orientado a lotes. Una restricción secundaria también lo descalifica: un trabajo nocturno al 100% de CPU durante 40 minutos es carga *predecible*, y la carga sostenida y predecible es donde el precio por capacidad asignada le gana al precio por GB-segundo.

### Ejercicio 5 — SaaS

**A19.** SaaS se inventaría como **derechos en un directorio**, no como recursos en una suscripción, y se factura por **asiento de usuario por mes**, no por unidad de tiempo de infraestructura. La regla general: si un servicio aparece en tu grafo de recursos ARM, estás alquilando infraestructura o una plataforma y tenés alguna responsabilidad operativa sobre él; si aparece solo como una licencia asignada a identidades, estás comprando acceso a una aplicación que otro opera enteramente.

**A20.** `Information and data`, `Devices (mobile and PCs)`, `Accounts and identities`.
- *Accounts and identities* → las políticas de acceso condicional que listaste ("Require MFA for all admins", "Block legacy authentication"), más la asignación de roles y el ciclo de vida de altas/cambios/bajas en el tenant.
- *Devices* → la política "Require compliant device for Exchange", respaldada por reglas de cumplimiento de dispositivos en Intune.
- *Information and data* → retención, etiquetado de confidencialidad, DLP y política de eDiscovery — nada de lo cual Microsoft elige por vos, y todo lo cual configurás en el tenant.

**A21.** Tuya. `Information and data` es del cliente en la columna SaaS sin excepción. Microsoft garantiza que el servicio de buzones está disponible y es durable; no garantiza que se cumpla una obligación de retención de siete años, porque no sabe que esa obligación existe. Vos configurás políticas de retención, etiquetas de retención y retención por litigio, y sos dueño de la evidencia de que se aplicaron. La fila lo resuelve: nada en SaaS traslada el gobierno de datos al proveedor.

**A22.** No es SaaS. Desplegarlo en tu suscripción significa que se materializa como recursos ARM de los que sos dueño; parchearlo vos mismo significa que `Operating system` y/o `Applications` están en tu columna. Eso es una **aplicación provista por un proveedor y entregada como IaaS o PaaS** — comúnmente una imagen de VM del marketplace, una aplicación administrada, o una oferta de contenedores. El empaquetado comercial puede ser por suscripción, pero el *tipo de servicio* lo determina dónde está el límite de responsabilidad, nunca cómo está redactada la factura. Prueba práctica: preguntá quién aplica el próximo parche crítico, y si el producto aparece en `az resource list`.

### Ejercicio 6 — Ejercitación de clasificación

| # | Servicio | Tipo | Fila decisiva |
|---|---|---|---|
| a | Azure Virtual Machines | **IaaS** | `Operating system` = Customer |
| b | Azure SQL Database | **PaaS** | El SO *y* el motor son administrados; vos sos dueño del esquema y los datos |
| c | SQL Server on Azure VMs | **IaaS** | Vos instalás, parcheás y licenciás el motor y el SO |
| d | Azure SQL Managed Instance | **PaaS** | Motor administrado con casi toda la superficie de instancia; aun así sin acceso al SO |
| e | Azure Blob Storage | **PaaS** | Se consume por API; sin SO, sin capacidad que aprovisionar |
| f | Azure App Service | **PaaS** | `Operating system` = Microsoft; vos sos dueño de la app |
| g | Microsoft 365 | **SaaS** | `Applications` = Microsoft; licencia por asiento, sin recurso ARM |
| h | Azure Kubernetes Service | **PaaS** | Plano de control administrado (ver A24 para el matiz) |
| i | Azure Virtual Desktop | **PaaS** | Brokering/gateway administrado; vos seguís siendo dueño del SO de los hosts de sesión |
| j | Dynamics 365 | **SaaS** | Aplicación de negocio terminada, licencia por asiento |
| k | Azure Functions (Consumption) | **PaaS** (serverless) | Plataforma administrada; facturado por ejecución, no por hora |
| l | Microsoft Intune | **SaaS** | Aplicación de gestión terminada consumida vía la nube |

**A23.** De mayor → menor responsabilidad del cliente: **(c) SQL Server on Azure VMs → (d) SQL Managed Instance → (b) Azure SQL Database.**
- *(c) → (d)*: resignás el sistema operativo invitado, la instalación del motor, el parcheo y la plomería de respaldos. Ganás parcheo automatizado, HA incorporada y respaldos automatizados. Perdés el acceso a nivel de SO, la capacidad de fijar indefinidamente una compilación exacta del motor, y la capacidad de instalar cualquier cosa en el host.
- *(d) → (b)*: resignás las funcionalidades de alcance de instancia (SQL Agent, consultas entre bases de datos, CLR, Service Broker, parte de la superficie de DBCC). Ganás el modelo operativo más simple, los niveles serverless y de pools elásticos, y un escalado más granular. Perdés la compatibilidad a nivel de instancia, que es justamente lo que hace de Managed Instance la zona de aterrizaje habitual para un lift-and-shift.

**A24.** **Respuesta de examen: PaaS.** El matiz: el plano de control de AKS (API server, scheduler, etcd) está totalmente administrado por Microsoft, no aparece como una VM en tu suscripción, y no es algo que parchees — inequívocamente PaaS. Los **grupos de nodos**, en cambio, son Virtual Machine Scale Sets que viven en un grupo de recursos de nodos dentro de tu suscripción; vos elegís su tamaño de VM y su SKU de SO, e iniciás las actualizaciones de imagen de nodo y de versión de Kubernetes. Así que la fila `Operating system` es de Microsoft para el plano de control y, en la práctica, compartida-hacia-el-cliente para los nodos. AZ-900 no evalúa esa división — evalúa "servicio administrado de Kubernetes" → PaaS. Conocé ambas, respondé PaaS.

**A25.** *Caso a favor de PaaS*: Microsoft administra el brokering, el gateway, el cliente web, los diagnósticos y la infraestructura de balanceo de carga, pero **vos** proveés, creás la imagen, parcheás, licenciás y monitoreás las VMs de los hosts de sesión, que son VMs IaaS comunes en tu suscripción — la fila del SO es firmemente tuya. *Caso a favor de SaaS*: el usuario final experimenta un escritorio terminado entregado por red sin nada que instalar, que es la experiencia de usuario de SaaS. **La guía de estudio de AZ-900 respalda PaaS**: los hosts de sesión administrados por el cliente son decisivos, y un producto SaaS verdadero nunca te dejaría una VM que parchear. Windows 365 Cloud PC, en cambio, *sí es* la respuesta con forma de SaaS en este espacio.

### Ejercicio 7 — Unidades de facturación

**A26.** La unidad es la misma; lo que difiere es **lo que tenés que hacer para que esa hora sea productiva**. La hora de VM compra capacidad cruda que solo se vuelve útil después de que creés la imagen, parcheés, endurezcas, monitorees y asegures el SO — trabajo que nunca aparece en la factura de Azure pero sí en la de sueldos. La hora de App Service compra la misma capacidad con esas tareas ya realizadas. Al final de un mal trimestre la diferencia aflora como: VMs sin parchear en el reporte de cumplimiento, horas-ingeniero consumidas por ventanas de mantenimiento, y — el clásico — VMs, discos e IPs públicas huérfanas de proyectos que nadie desasignó, porque los recursos IaaS persisten hasta que se los elimina explícitamente.

**A27.** 30 solicitudes × 200 ms ≈ **6 segundos de cómputo por día**. En el plan de consumo pagás aproximadamente 6 GB-segundos más 30 ejecuciones — fracciones pequeñas de un centavo por mes. En el plan B1 pagás ~0,013 × 730 ≈ **USD 9,50 por mes por 3 minutos de trabajo al año**, una utilización muy por debajo del 0,01%. El modo de falla de elegir B1 no es una falla técnica sino estructural: compraste capacidad asignada para una carga con forma de consumo, y el desajuste se agrava con cada servicio adicional de bajo tráfico que recibe su propio plan. (El contraargumento a favor de B1 es la latencia: los arranques en frío de Consumption agregan cientos de milisegundos a la primera solicitud tras la inactividad. Si eso importa, la respuesta es el plan Premium, no B1.)

**A28.** Nada — la factura queda plana, porque es función de la dotación de personal, no de la carga. Eso revela que en SaaS el proveedor absorbió **todo** el riesgo de capacidad: Microsoft dimensiona, escala y paga la infraestructura detrás de Exchange Online tanto si tus usuarios envían 100 como 100.000 mensajes. Es el argumento financiero más fuerte a favor de SaaS y también su principal restricción, ya que no podés optimizar una factura que no está impulsada por el consumo — la única palanca es la cantidad de licencias y su nivel.

### Ejercicio 8 — Diagnóstico

**A29.** De mayor a menor exposición: **IaaS → PaaS → SaaS**. IaaS te da la consola serie, diagnósticos de arranque, logs del kernel, telemetría completa del sistema invitado y shell de root. PaaS te da logs de aplicación, eventos del ciclo de vida de la plataforma y métricas — pero ningún host. SaaS te da una página de estado y un centro de mensajes. El orden es el inverso de la carga operativa porque el acceso y la responsabilidad son la misma cosa: se te muestran exactamente las capas que sos responsable de reparar. Todo lo que está por debajo de tu límite de responsabilidad es invisible precisamente porque arreglarlo no es tu trabajo — y que te mostraran datos sobre los que no podés actuar sería un pasivo, no una funcionalidad.

**A30.** (1) Logs de aplicación — `az webapp log tail`, más Application Insights si está instrumentado; un 503 suele ser tu proceso fallando al iniciar, fallando su sonda de warmup, o agotando los workers. (2) Estado de la plataforma — `az webapp show` para el estado del sitio, historial de despliegues/intercambio de slots, agotamiento de cuota en el plan, y Azure Service Health / Resource Health por un incidente de plataforma. Lo que *no podés* revisar es el sistema operativo del host: sin `dmesg`, sin log de arranque, sin métricas del host. `Operating system` es de Microsoft en la columna PaaS, así que si la falla está genuinamente por debajo del contenedor la única acción correcta es escalar a Microsoft, no seguir investigando.

**A31.** Monitorean planos distintos. Azure Service Health informa sobre servicios de **Azure** con alcance a tus suscripciones y regiones — los recursos IaaS/PaaS de los que sos dueño. Microsoft Teams es un servicio SaaS de Microsoft 365 cuya salud se informa en el **centro de administración de Microsoft 365 → Health → Service health**, y en la API de Service health de Microsoft 365, con alcance a tu tenant en lugar de tu suscripción. Verde en Azure no dice nada sobre Microsoft 365, que es una consecuencia más de que SaaS viva enteramente fuera de tu grafo de recursos: incluso su reporte de incidentes está del otro lado del límite.

### Ejercicio 9 — Decisiones por caso de uso

**A32.** Los escenarios **1, 5 y 7** son IaaS. Las palabras que fuerzan la respuesta son las que nombran algo *por debajo de la aplicación*: "instalado a nivel de sistema" y "agente en modo kernel" (1); "congelada en 15.4" y "adjuntar un agente de terceros al proceso de la base de datos" (5); "control total de las versiones del driver CUDA" (7). Cuando un requisito nombra el sistema operativo, un driver, un componente del kernel, o una compilación exacta del motor que el cliente debe fijar, la fila `Operating system` fue reclamada por el cliente, y PaaS queda descartado. Los escenarios **3 y 4** son PaaS (App Service; Azure Functions en Consumption). Los escenarios **2 y 6** son SaaS (Microsoft 365; Dynamics 365).

**A33.** El escenario 3 es una API servida de forma continua con staging y producción lado a lado: quiere un **plan de App Service** (nivel Standard o superior para slots de despliegue), facturado **por hora de plan asignado**, con el costo del plan amortizado sobre tráfico estable. El escenario 4 es esporádico, orientado a eventos, con 300 ms de trabajo por evento y noches ociosas: quiere **Functions en el plan de consumo**, facturado **por GB-segundo más por ejecución**, de modo que la inactividad nocturna no cueste nada. Mismo tipo de servicio, unidades de facturación opuestas — decide la forma de las solicitudes, no la tecnología.

**A34.** "Adjuntar un agente de auditoría de terceros al proceso de la base de datos" es, por sí sola, la descalificación más dura: requiere cargar código ajeno en el espacio de proceso del motor, y ninguna base de datos totalmente administrada lo permite, en ningún nivel. "Congelada en 15.4 por 18 meses" es severo pero no siempre fatal — los servicios de base de datos administrados sí ofrecen ventanas de fijación de versión, y 18 meses puede caer dentro de un ciclo de vida soportado de versión mayor. El requisito del agente no admite ninguna configuración que lo satisfaga, así que por sí solo fuerza IaaS (o una oferta administrada con un mecanismo de extensión explícitamente soportado, que debe verificarse en lugar de asumirse).

**A35.** Una reescritura viable para PaaS: reemplazar el agente en modo kernel del proveedor por un equivalente soportado en espacio de usuario o basado en API; eliminar la dependencia del driver ODBC a nivel de sistema migrando a un conector de base de datos administrada soportado; recompilar la aplicación contra un runtime soportado en un SO actual; externalizar todo el estado a almacenamiento administrado para que las instancias se puedan reemplazar a voluntad; y eliminar cualquier supuesto de persistencia en disco local o identidad de máquina fija. El costo que el lift-and-shift no incurre: un proyecto de replataformado medido en meses en lugar de las seis semanas indicadas, la recertificación por parte del proveedor de una aplicación clínica de 15 años, y — en un contexto hospitalario — la revalidación clínica de un sistema modificado. Esta es toda la razón por la que IaaS sigue existiendo: a veces la respuesta correcta de ingeniería es la que se entrega antes de que muera el hardware, y el replataformado es una decisión que se programa deliberadamente en lugar de forzarse por una fecha límite de migración.

**A36.** Porque el precio solo compara opciones que son efectivamente viables, y el tipo de servicio es lo que determina la viabilidad. Costear una opción PaaS para el escenario 5 produce un número barato para una solución que no puede ejecutar el agente requerido — una comparación de una opción real contra una ficticia. La secuencia correcta: **(1)** ¿Qué debe controlar la carga de trabajo por debajo de la aplicación — SO, drivers, compilación del motor? Eso elimina tipos de servicio. **(2)** ¿Cuál es la forma de la carga — estable, con picos, o esporádica? Eso elige la unidad de facturación dentro del tipo que sobrevivió. **(3)** ¿Qué capacidad operativa tiene realmente el equipo? Eso pondera administrado contra autoadministrado. **(4)** *Recién ahora*, ¿cuánto cuesta — incluyendo las horas-ingeniero que implicaron las respuestas anteriores, no solo la factura de Azure.

### Ejercicio 10 — Limpieza

**A37.** `Microsoft.Compute/disks` (el disco de SO administrado Premium_LRS) y `Microsoft.Network/publicIPAddresses` (una IP estática de SKU Standard, facturada esté o no adjunta a una máquina en ejecución). Desasignar libera únicamente la asignación de cómputo. Esta clase de sorpresa es estructuralmente un fenómeno de **IaaS**: IaaS descompone una máquina en recursos con ciclos de vida independientes que vos asignaste y que por lo tanto persisten hasta que los borrás explícitamente. PaaS y SaaS no tienen equivalente — borrar un plan de App Service elimina todo lo que facturaba, y SaaS no tiene artefactos asignados en absoluto. Es la expresión financiera directa de "vos administrás la infraestructura".

**A38.** Los derechos de SaaS viven en el **tenant de Microsoft Entra**, no en una suscripción de Azure, y los dos tienen ciclos de vida independientes. Una suscripción puede crearse, vaciarse o cancelarse sin afectar una sola licencia; e igualmente, las licencias siguen facturándose hasta que reduzcas la cantidad de asientos en el portal de licenciamiento, sin importar qué borres en ARM. El principio general: SaaS se da de baja cambiando derechos e identidades, IaaS y PaaS borrando recursos — y confundir ambos es como las organizaciones terminan pagando asientos mucho después de que el proyecto que los necesitaba fue desmantelado.

</details>

---

## Fuentes

- Guía de estudio AZ-900 (objetivos del examen, versión 2026-07-20) — <https://learn.microsoft.com/en-us/credentials/certifications/resources/study-guides/az-900>
- Describir los tipos de servicios en la nube (módulo de capacitación de Microsoft Learn) — <https://learn.microsoft.com/en-us/training/modules/describe-cloud-service-types/>
- Responsabilidad compartida en la nube — <https://learn.microsoft.com/en-us/azure/security/fundamentals/shared-responsibility>
- Servicios de Azure y sus proveedores de recursos — <https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/azure-services-resource-providers>
- Referencia de comandos `az vm` (incluidos `az vm assess-patches`, `az vm run-command`) — <https://learn.microsoft.com/en-us/cli/azure/vm>
- Descripción general de Azure App Service y planes de hospedaje — <https://learn.microsoft.com/en-us/azure/app-service/overview-hosting-plans>
- Sistema de archivos del contenedor Linux de App Service y `/home` persistente — <https://learn.microsoft.com/en-us/azure/app-service/operating-system-functionality>
- Plan de consumo de Azure Functions (escalado, tiempos límite, facturación) — <https://learn.microsoft.com/en-us/azure/azure-functions/consumption-plan>
- Comparación de escalado y hospedaje de Azure Functions — <https://learn.microsoft.com/en-us/azure/azure-functions/functions-scale>
- API de precios minoristas de Azure — <https://learn.microsoft.com/en-us/rest/api/cost-management/retail-prices/azure-retail-prices>
- Microsoft Graph `subscribedSkus` (list) — <https://learn.microsoft.com/en-us/graph/api/subscribedsku-list?view=graph-rest-1.0>
- Descripción general de Azure Update Manager — <https://learn.microsoft.com/en-us/azure/update-manager/overview>
- Descripción general de Azure Service Health — <https://learn.microsoft.com/en-us/azure/service-health/overview>
- Ver el estado del servicio de Microsoft 365 — <https://learn.microsoft.com/en-us/microsoft-365/enterprise/view-service-health>
- Introducción a Azure Kubernetes Service — <https://learn.microsoft.com/en-us/azure/aks/what-is-aks>
- Descripción general de Azure Virtual Desktop — <https://learn.microsoft.com/en-us/azure/virtual-desktop/overview>
- Opciones de implementación de Azure SQL comparadas — <https://learn.microsoft.com/en-us/azure/azure-sql/azure-sql-iaas-vs-paas-what-is-overview>