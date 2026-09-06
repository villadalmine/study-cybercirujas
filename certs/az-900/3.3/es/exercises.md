# AZ-900 — Tema 3.3: Características y herramientas para administrar e implementar recursos de Azure
## Ejercicios guiados (laboratorio práctico)

> **Peso en el examen:** 8.33% · **Versión del examen:** 2026-07-20
> **Guía de estudio oficial:** https://learn.microsoft.com/en-us/credentials/certifications/resources/study-guides/az-900

---

## 0. Requisitos previos del laboratorio y control de costos

Este laboratorio usa una suscripción de Azure (sirve una prueba gratuita o Pay-As-You-Go). Todos los recursos que se crean acá son gratuitos o cuestan centavos por mes, y el Ejercicio 9 borra todo.

| Componente | Perfil de costo |
|---|---|
| Grupo de recursos, implementaciones ARM, bloqueos, etiquetas | Gratis — metadatos del plano de control |
| Cuenta de almacenamiento StorageV2 `Standard_LRS`, vacía | ~$0.02/mes, facturado según GB almacenados |
| Recurso compartido de Azure Files que respalda Cloud Shell (imagen de 5 GB) | ~$0.30/mes, o usá la sesión efímera (sin almacenamiento) |
| Servidores / Kubernetes habilitados para Azure Arc — plano de control | Gratis (configuración de invitado de Policy, inventario de Change Tracking, evaluación de Update Manager) |
| Arc + ingesta de Microsoft Defender for Cloud / Log Analytics | **Facturado** — no lo habilites en este laboratorio |

**Opciones de entorno**

1. **Azure Cloud Shell** (navegador, nada que instalar) — usado deliberadamente en el Ejercicio 2.
2. **Estación de trabajo local** — instalá la CLI de Azure (`az`) 2.60+ y, opcionalmente, el módulo de PowerShell `Az` 11+.

```bash
# Local install check
az version
```

```
{
  "azure-cli": "2.64.0",
  "azure-cli-core": "2.64.0",
  "azure-cli-telemetry": "1.1.0",
  "extensions": {}
}
```

---

## Ejercicio 1 — Azure Resource Manager: el plano de control único

**Objetivo:** demostrar empíricamente que el portal, la CLI, PowerShell y los SDK son *clientes*, no planos de administración. Azure Resource Manager (ARM) es el único servicio que autentica, autoriza, valida y ejecuta cada solicitud de administración.

### Pasos

1. Autenticate e inspeccioná el contexto de la suscripción activa.

   ```bash
   az login
   az account show --output table
   ```

   ```
   EnvironmentName    HomeTenantId                          IsDefault    Name                    State    TenantId
   -----------------  ------------------------------------  -----------  ----------------------  -------  ------------------------------------
   AzureCloud         8f2b1c4a-3e77-4a1c-9c5c-0d1e2f3a4b5c  True         Pay-As-You-Go           Enabled  8f2b1c4a-3e77-4a1c-9c5c-0d1e2f3a4b5c
   ```

2. Exportá el ID de la suscripción para reutilizarlo.

   ```bash
   export SUB_ID=$(az account show --query id -o tsv)
   export LOC=eastus
   export RG=rg-az900-lab
   echo "$SUB_ID"
   ```

3. Creá el grupo de recursos del laboratorio con etiquetas.

   ```bash
   az group create \
     --name "$RG" \
     --location "$LOC" \
     --tags env=lab course=az900 owner=student
   ```

   ```json
   {
     "id": "/subscriptions/8f2b1c4a-.../resourceGroups/rg-az900-lab",
     "location": "eastus",
     "managedBy": null,
     "name": "rg-az900-lab",
     "properties": {
       "provisioningState": "Succeeded"
     },
     "tags": {
       "course": "az900",
       "env": "lab",
       "owner": "student"
     },
     "type": "Microsoft.Resources/resourceGroups"
   }
   ```

4. Ahora emití **exactamente la misma operación** como una llamada REST cruda a ARM. `az rest` adjunta tu token bearer y habla directo con `management.azure.com` — esto es literalmente lo que hace el JavaScript del portal.

   ```bash
   az rest --method get \
     --url "https://management.azure.com/subscriptions/$SUB_ID/resourcegroups?api-version=2021-04-01" \
     --query "value[].{name:name, location:location, state:properties.provisioningState}" \
     -o table
   ```

   ```
   Name            Location    State
   --------------  ----------  ---------
   rg-az900-lab    eastus      Succeeded
   NetworkWatcherRG eastus     Succeeded
   ```

5. Descomponé un **ID de recurso** de ARM. Cada objeto en Azure tiene uno, y codifica su ruta de ámbito completa.

   ```bash
   az group show --name "$RG" --query id -o tsv
   ```

   ```
   /subscriptions/8f2b1c4a-3e77-4a1c-9c5c-0d1e2f3a4b5c/resourceGroups/rg-az900-lab
   ```

6. Inspeccioná los **proveedores de recursos** — las extensiones de ARM que realmente implementan cada tipo de recurso. Un proveedor tiene que estar *registrado* en la suscripción antes de que sus tipos puedan implementarse.

   ```bash
   az provider list --query "[?registrationState=='Registered'].namespace" -o tsv | sort | head -10
   az provider show --namespace Microsoft.Storage \
     --query "resourceTypes[?resourceType=='storageAccounts'].apiVersions[0] | [0]" -o tsv
   ```

   ```
   Microsoft.Advisor
   Microsoft.Authorization
   Microsoft.Cache
   Microsoft.Compute
   Microsoft.Network
   Microsoft.Resources
   Microsoft.Storage
   ...
   2024-01-01
   ```

7. Verificá un proveedor que *no* hayas usado todavía — lo vas a necesitar en el Ejercicio 8.

   ```bash
   az provider show --namespace Microsoft.HybridCompute --query registrationState -o tsv
   ```

   ```
   NotRegistered
   ```

### Verificá lo que entendiste — Bloque 1

- **Q1.1** — Creás una VM en el portal de Azure, después la borrás con Azure PowerShell, y después la consultás con el SDK de Python. ¿Cuántos planos de administración intervinieron, y qué implica eso para la aplicación de RBAC y Azure Policy?
- **Q1.2** — Dado el ID `/subscriptions/8f2b.../resourceGroups/rg-az900-lab/providers/Microsoft.Storage/storageAccounts/stlab001`, nombrá cada uno de los cinco segmentos e indicá cuál identifica al *proveedor de recursos*.
- **Q1.3** — El `az deployment group create` de un colega falla con `MissingSubscriptionRegistration`. ¿Cuál es la causa y cuál es la solución?
- **Q1.4** — ARM se describe como "independiente de la región y de alta disponibilidad". Si la región `eastus` está degradada, ¿podés seguir *administrando* (listar, etiquetar, borrar) recursos ubicados en `westeurope`? ¿Por qué?

---

## Ejercicio 2 — Azure Cloud Shell: Bash, PowerShell y su modelo de persistencia

**Objetivo:** entender qué es realmente Cloud Shell — un contenedor efímero por usuario con un recurso compartido de Azure Files montado — y cuándo importa que tenga estado.

### Pasos

1. Abrí https://portal.azure.com y hacé clic en el ícono de **Cloud Shell** (`>_`) en la barra de herramientas superior, o navegá directamente a https://shell.azure.com.

2. Cuando te lo pida, elegí **Bash**. Si te lo ofrece, elegí **Mount storage account** → *We will create a storage account for you*, o seleccioná **No storage account required** para una sesión efímera.

3. Inspeccioná el contenedor en el que aterrizaste.

   ```bash
   uname -a
   df -h | grep -E 'clouddrive|Filesystem'
   echo $HOME
   ```

   ```
   Linux cc-abcd1234-5678-9abc-def0-123456789abc 5.15.0-1073-azure #82-Ubuntu SMP x86_64 GNU/Linux
   Filesystem                                             Size  Used Avail Use% Mounted on
   //cs710000abcdef123.file.core.windows.net/cs-student-...  5.0G  1.2G  3.9G  24% /home/student/clouddrive
   /home/student
   ```

4. Confirmá el instrumental que viene preinstalado — este es el sentido de Cloud Shell.

   ```bash
   for t in az kubectl helm terraform ansible git jq bicep; do
     printf "%-10s %s\n" "$t" "$(command -v $t || echo MISSING)"
   done
   az bicep version
   ```

   ```
   az         /usr/bin/az
   kubectl    /usr/local/bin/kubectl
   helm       /usr/local/bin/helm
   terraform  /usr/local/bin/terraform
   ansible    /opt/ansible/bin/ansible
   git        /usr/bin/git
   jq         /usr/bin/jq
   bicep      MISSING
   Bicep CLI version 0.30.3 (managed by the Azure CLI)
   ```

5. Probá el límite de la persistencia. Escribí un archivo dentro de `$HOME` y otro dentro de `clouddrive`.

   ```bash
   echo "ephemeral" > ~/scratch.txt
   echo "persisted"  > ~/clouddrive/lab-notes.txt
   ls -l ~/scratch.txt ~/clouddrive/lab-notes.txt
   ```

6. Escribí `exit`, esperá a que la sesión se recicle (o simplemente cerrá y volvé a abrir Cloud Shell), y después volvé a verificar ambos archivos.

   ```bash
   cat ~/clouddrive/lab-notes.txt   # survives
   cat ~/scratch.txt                # may or may not survive; not guaranteed
   ```

   ```
   persisted
   cat: /home/student/scratch.txt: No such file or directory
   ```

7. Cambiá el tipo de shell sin salir del navegador: usá el selector **Bash ⇄ PowerShell** en la barra de herramientas de Cloud Shell, y después ejecutá los equivalentes en PowerShell del Ejercicio 1.

   ```powershell
   Get-AzContext | Format-List Name, Account, Subscription, Tenant
   Get-AzResourceGroup -Name rg-az900-lab | Select-Object ResourceGroupName, Location, ProvisioningState
   ```

   ```
   ResourceGroupName Location ProvisioningState
   ----------------- -------- -----------------
   rg-az900-lab      eastus   Succeeded
   ```

8. Compará las dos CLI en la misma tarea y observá la diferencia en el modelo de objetos. La CLI de Azure emite **texto JSON**; Azure PowerShell emite **objetos .NET** que podés canalizar.

   ```bash
   # Azure CLI — JMESPath query, text out
   az group list --query "[?tags.env=='lab'].name" -o tsv
   ```

   ```powershell
   # Azure PowerShell — object pipeline, no string parsing
   Get-AzResourceGroup | Where-Object { $_.Tags.env -eq 'lab' } | Select-Object -Expand ResourceGroupName
   ```

### Verificá lo que entendiste — Bloque 2

- **Q2.1** — Cloud Shell se promociona como gratuito. ¿Qué se factura exactamente, y qué no?
- **Q2.2** — Un estudiante guarda una clave privada SSH en `~/.ssh/id_rsa` en Cloud Shell y al día siguiente ya no está. ¿Dónde debería haberla guardado, y por qué?
- **Q2.3** — Tu estación de trabajo es una laptop corporativa restringida sin permisos para instalar software, y tenés que ejecutar `kubectl` contra un clúster de AKS ahora mismo. ¿Qué herramienta resuelve esto y cuáles son sus dos opciones de shell?
- **Q2.4** — Necesitás programar "para cada grupo de recursos etiquetado con `env=lab`, listar sus recursos y totalizarlos". ¿Cuál de las dos, la CLI de Azure o Azure PowerShell, encaja más naturalmente, y cuál es la razón de fondo?
- **Q2.5** — ¿La CLI de Azure está limitada a Cloud Shell? ¿En qué sistemas operativos corre?

---

## Ejercicio 3 — El portal de Azure y Resource Graph: descubrimiento a escala

**Objetivo:** mapear las funciones del portal a sus equivalentes de API, y entender por qué el portal por sí solo no escala a miles de recursos.

### Pasos

1. En el portal, abrí **rg-az900-lab** → hoja izquierda → **Overview**. Fijate en el contador de **Deployments** (por ahora `0 Succeeded`).

2. Ancliá el grupo de recursos a un panel: **Overview → ⋯ → Pin to dashboard**. Después andá al **Dashboard hub** y confirmá que aparece el mosaico. Los paneles son en sí mismos recursos de ARM del tipo `Microsoft.Portal/dashboards` y pueden compartirse y controlarse con RBAC.

3. Verificá esa afirmación desde la CLI:

   ```bash
   az resource list --resource-type Microsoft.Portal/dashboards --query "[].{name:name, rg:resourceGroup}" -o table
   ```

4. Abrí **All services → Resource Graph Explorer** en el portal, y ejecutá esta consulta KQL:

   ```kusto
   Resources
   | summarize count() by type, location
   | order by count_ desc
   | limit 10
   ```

5. Ejecutá la misma consulta desde la CLI. Azure Resource Graph indexa recursos a lo largo de *todas* las suscripciones que podés leer, algo que las hojas del portal por grupo de recursos no pueden hacer.

   ```bash
   az extension add --name resource-graph --only-show-errors
   az graph query -q "Resources | project name, type, location, resourceGroup | limit 5" -o table
   ```

   ```
   Name                Type                                  Location    ResourceGroup
   ------------------  ------------------------------------  ----------  ---------------
   NetworkWatcher_eastus  microsoft.network/networkwatchers   eastus      NetworkWatcherRG
   ...
   ```

6. Reproducí la función **Export template** del portal desde la CLI — así es como se hace ingeniería inversa de infraestructura construida a mano ("ClickOps") para convertirla en código.

   ```bash
   az group export --name "$RG" > exported-rg.json
   head -20 exported-rg.json
   ```

   ```json
   {
     "$schema": "https://schema.management.azure.com/schemas/2015-01-01/deploymentTemplate.json#",
     "contentVersion": "1.0.0.0",
     "parameters": {},
     "resources": []
   }
   ```

7. Abrí **Help + support → Azure mobile app** (la promoción), o instalá la app móvil *Azure*, y confirmá que podés ver el mismo grupo de recursos. El portal, la app móvil y la CLI son tres front ends sobre una sola API.

### Verificá lo que entendiste — Bloque 3

- **Q3.1** — Nombrá tres cosas que ofrece el portal de Azure y que una llamada REST cruda no ofrece, y una cosa que REST/CLI ofrece y el portal no puede hacer en la práctica.
- **Q3.2** — Un gerente pregunta: "¿cuántas cuentas de almacenamiento tenemos en 47 suscripciones, y dónde están?". ¿Por qué la lista de recursos del portal es la herramienta equivocada, y qué servicio responde esto?
- **Q3.3** — La infraestructura se construyó a mano durante dos años y nadie tiene plantillas. ¿Qué capacidad del portal/CLI te da un punto de partida, y cuál es su limitación principal?
- **Q3.4** — ¿Los paneles del portal de Azure son una preferencia personal de UI o un recurso de Azure gobernable? Justificá con lo que observaste en el paso 3.

---

## Ejercicio 4 — Plantillas ARM: implementación declarativa, idempotencia y modos

**Objetivo:** escribir una plantilla ARM JSON sintácticamente válida, implementarla, volver a implementarla para observar la idempotencia, y entender la distinción entre modo *Incremental* y *Complete* — el comportamiento de ARM más relevante para el examen.

### Pasos

1. Creá el archivo de plantilla `storage.json`.

   ```bash
   mkdir -p ~/az900-lab && cd ~/az900-lab
   cat > storage.json <<'EOF'
   {
     "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
     "contentVersion": "1.0.0.0",
     "metadata": {
       "description": "AZ-900 3.3 lab - StorageV2 account with hardened defaults."
     },
     "parameters": {
       "location": {
         "type": "string",
         "defaultValue": "[resourceGroup().location]",
         "metadata": { "description": "Region; defaults to the resource group location." }
       },
       "skuName": {
         "type": "string",
         "defaultValue": "Standard_LRS",
         "allowedValues": [ "Standard_LRS", "Standard_GRS", "Standard_ZRS" ],
         "metadata": { "description": "Storage redundancy tier." }
       },
       "environment": {
         "type": "string",
         "defaultValue": "lab"
       }
     },
     "variables": {
       "storageAccountName": "[toLower(concat('stlab', uniqueString(resourceGroup().id)))]"
     },
     "resources": [
       {
         "type": "Microsoft.Storage/storageAccounts",
         "apiVersion": "2023-05-01",
         "name": "[variables('storageAccountName')]",
         "location": "[parameters('location')]",
         "sku": { "name": "[parameters('skuName')]" },
         "kind": "StorageV2",
         "tags": {
           "env": "[parameters('environment')]",
           "course": "az900",
           "managedBy": "arm-template"
         },
         "properties": {
           "accessTier": "Hot",
           "minimumTlsVersion": "TLS1_2",
           "supportsHttpsTrafficOnly": true,
           "allowBlobPublicAccess": false,
           "allowSharedKeyAccess": true,
           "networkAcls": {
             "defaultAction": "Allow",
             "bypass": "AzureServices"
           }
         }
       }
     ],
     "outputs": {
       "storageAccountName": {
         "type": "string",
         "value": "[variables('storageAccountName')]"
       },
       "primaryBlobEndpoint": {
         "type": "string",
         "value": "[reference(resourceId('Microsoft.Storage/storageAccounts', variables('storageAccountName'))).primaryEndpoints.blob]"
       }
     }
   }
   EOF
   ```

2. **Validá** la plantilla — una verificación de esquema/parámetros/versión de API que nunca toca recursos reales.

   ```bash
   az deployment group validate \
     --resource-group "$RG" \
     --template-file storage.json \
     --query "{state:properties.provisioningState, errors:error}" -o json
   ```

   ```json
   {
     "errors": null,
     "state": "Succeeded"
   }
   ```

3. Ejecutá una vista previa **what-if**. Esto es validación más un diff real contra el estado actual — la puerta profesional previa a la implementación.

   ```bash
   az deployment group what-if \
     --resource-group "$RG" \
     --name lab-storage \
     --template-file storage.json
   ```

   ```
   Note: The result may contain false positive predictions (noise).
   You can help us improve the accuracy of the result by opening an issue here: https://aka.ms/WhatIfIssues

   Resource and property changes are indicated with these symbols:
     + Create

   The deployment will update the following scope:

   Scope: /subscriptions/8f2b1c4a-.../resourceGroups/rg-az900-lab

     + Microsoft.Storage/storageAccounts/stlab3kq7hv2nrxa4e [2023-05-01]

         apiVersion:            "2023-05-01"
         kind:                  "StorageV2"
         location:              "eastus"
         properties.accessTier: "Hot"
         ...
         sku.name:              "Standard_LRS"

   Resource changes: 1 to create.
   ```

4. Implementá de verdad, en el modo **Incremental** predeterminado.

   ```bash
   az deployment group create \
     --resource-group "$RG" \
     --name lab-storage \
     --template-file storage.json \
     --parameters skuName=Standard_LRS environment=lab \
     --query "{state:properties.provisioningState, mode:properties.mode, outputs:properties.outputs}" -o json
   ```

   ```json
   {
     "mode": "Incremental",
     "outputs": {
       "primaryBlobEndpoint": {
         "type": "String",
         "value": "https://stlab3kq7hv2nrxa4e.blob.core.windows.net/"
       },
       "storageAccountName": {
         "type": "String",
         "value": "stlab3kq7hv2nrxa4e"
       }
     },
     "state": "Succeeded"
   }
   ```

5. **Demostrá la idempotencia.** Ejecutá el comando *idéntico* otra vez y compará la salida de what-if.

   ```bash
   az deployment group what-if \
     --resource-group "$RG" --name lab-storage --template-file storage.json \
     --parameters skuName=Standard_LRS environment=lab
   ```

   ```
     = Microsoft.Storage/storageAccounts/stlab3kq7hv2nrxa4e

   Resource changes: no change.
   ```

6. Creá un recurso **fuera** de la plantilla, para que el grupo de recursos tenga ahora deriva (drift).

   ```bash
   az network vnet create \
     --resource-group "$RG" --name vnet-orphan \
     --address-prefix 10.42.0.0/16 --subnet-name default --subnet-prefix 10.42.1.0/24 \
     --query "{name:name, state:provisioningState}" -o json
   ```

7. Previsualizá una implementación en modo **Complete**. No la ejecutes a ciegas — leé el diff.

   ```bash
   az deployment group what-if \
     --resource-group "$RG" \
     --template-file storage.json \
     --mode Complete
   ```

   ```
   Resource and property changes are indicated with these symbols:
     - Delete
     = NoChange

     - Microsoft.Network/virtualNetworks/vnet-orphan

     = Microsoft.Storage/storageAccounts/stlab3kq7hv2nrxa4e

   Resource changes: 1 to delete, 1 no change.
   ```

8. Inspeccioná el **historial de implementaciones** que ARM guarda por grupo de recursos.

   ```bash
   az deployment group list --resource-group "$RG" \
     --query "[].{name:name, mode:properties.mode, state:properties.provisioningState, ts:properties.timestamp}" -o table
   ```

   ```
   Name           Mode         State      Ts
   -------------  -----------  ---------  --------------------------------
   lab-storage    Incremental  Succeeded  2026-09-05T14:22:41.118392+00:00
   vnet-orphan    Incremental  Succeeded  2026-09-05T14:25:03.771204+00:00
   ```

9. Borrá la VNet huérfana de la manera segura (explícitamente, no vía modo Complete).

   ```bash
   az network vnet delete --resource-group "$RG" --name vnet-orphan
   ```

### Verificá lo que entendiste — Bloque 4

- **Q4.1** — Definí implementación *declarativa* vs *imperativa*, y clasificá: (a) `storage.json`, (b) `az storage account create`, (c) un bucle `for` de Bash que llama a `az vm create`.
- **Q4.2** — Ejecutaste la misma plantilla dos veces y la segunda ejecución informó "no change". ¿Qué propiedad de las plantillas ARM es esta, y por qué importa para un pipeline de CI/CD que reimplementa en cada commit?
- **Q4.3** — ¿Cuál es exactamente la diferencia entre el modo Incremental y el Complete, cuál es el predeterminado, y cuál es el incidente clásico de producción causado por el modo Complete?
- **Q4.4** — ¿Qué te da `az deployment group what-if` que `az deployment group validate` no te da?
- **Q4.5** — ¿Por qué se usa `uniqueString(resourceGroup().id)` para el nombre de la cuenta de almacenamiento en vez de una cadena fija? Dá dos razones.
- **Q4.6** — ¿Dónde guarda ARM el registro de que se implementó `lab-storage`, y en qué ámbito vive ese historial?

---

## Ejercicio 5 — Bicep: el DSL que compila a ARM JSON

**Objetivo:** ver que Bicep es un *front end transpilador* para la misma API de ARM — no un motor de implementación distinto — y que JSON y Bicep son mecánicamente interconvertibles.

### Pasos

1. Descompilá a Bicep el JSON que escribiste.

   ```bash
   az bicep decompile --file storage.json
   cat storage.bicep
   ```

   ```bicep
   param location string = resourceGroup().location

   @allowed([
     'Standard_LRS'
     'Standard_GRS'
     'Standard_ZRS'
   ])
   param skuName string = 'Standard_LRS'

   param environment string = 'lab'

   var storageAccountName = toLower('stlab${uniqueString(resourceGroup().id)}')

   resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
     name: storageAccountName
     location: location
     sku: {
       name: skuName
     }
     kind: 'StorageV2'
     tags: {
       env: environment
       course: 'az900'
       managedBy: 'arm-template'
     }
     properties: {
       accessTier: 'Hot'
       minimumTlsVersion: 'TLS1_2'
       supportsHttpsTrafficOnly: true
       allowBlobPublicAccess: false
       allowSharedKeyAccess: true
       networkAcls: {
         defaultAction: 'Allow'
         bypass: 'AzureServices'
       }
     }
   }

   output storageAccountName string = storageAccount.name
   output primaryBlobEndpoint string = storageAccount.properties.primaryEndpoints.blob
   ```

2. Compilalo de vuelta a ARM JSON y mirá lo que ARM realmente recibe.

   ```bash
   az bicep build --file storage.bicep --outfile storage.compiled.json
   jq '.metadata' storage.compiled.json
   ```

   ```json
   {
     "_generator": {
       "name": "bicep",
       "version": "0.30.3.12046",
       "templateHash": "13297054621175288904"
     }
   }
   ```

3. Compará la cantidad de líneas — el argumento práctico a favor de Bicep.

   ```bash
   wc -l storage.json storage.bicep storage.compiled.json
   ```

   ```
     62 storage.json
     36 storage.bicep
     58 storage.compiled.json
   ```

4. Implementá el archivo `.bicep` directamente. La CLI transpila en memoria; ARM nunca ve sintaxis Bicep.

   ```bash
   az deployment group create \
     --resource-group "$RG" \
     --name lab-storage-bicep \
     --template-file storage.bicep \
     --confirm-with-what-if
   ```

   ```
   Resource and property changes are indicated with this symbol:
     = NoChange

   Resource changes: no change.

   Are you sure you want to execute the deployment? (y/n): y
   ```

5. Introducí un error deliberado y observá la verificación de tipos **en tiempo de compilación**, algo que las plantillas JSON no pueden ofrecer.

   ```bash
   sed -i "s/accessTier: 'Hot'/accessTier: 'Warm'/" storage.bicep
   az bicep build --file storage.bicep --outfile /dev/null
   ```

   ```
   storage.bicep(28,17) : Error BCP036: The property "accessTier" expected a value of type
   "'Cold' | 'Cool' | 'Hot' | 'Premium'" but the provided value is of type "'Warm'".
   ```

6. Reparalo.

   ```bash
   sed -i "s/accessTier: 'Warm'/accessTier: 'Hot'/" storage.bicep
   az bicep build --file storage.bicep --outfile /dev/null && echo "BUILD OK"
   ```

### Verificá lo que entendiste — Bloque 5

- **Q5.1** — ¿Es Bicep un servicio de implementación separado de ARM? ¿Qué recibe ARM cuando ejecutás `az deployment group create --template-file main.bicep`?
- **Q5.2** — Nombrá tres ventajas concretas de Bicep sobre ARM JSON escrito a mano, cada una respaldada por algo que viste en este ejercicio.
- **Q5.3** — Tu equipo tiene 200 plantillas ARM JSON heredadas y quiere migrar. ¿Qué único comando inicia esa migración, y qué deberías igualmente revisar a mano después?
- **Q5.4** — Tanto Bicep como Terraform son Infraestructura como Código. ¿Cuál es una herramienta propia de Microsoft atada a la API de ARM, y qué requiere la otra que Bicep no requiere?

---

## Ejercicio 6 — Ámbitos de implementación: grupo de recursos, suscripción, grupo de administración

**Objetivo:** implementar por encima del ámbito de grupo de recursos, que es la forma en que los artefactos de gobernanza (políticas, RBAC, las suscripciones mismas) se entregan como código.

### Pasos

1. Escribí una plantilla con **ámbito de suscripción** que cree un grupo de recursos — algo que una plantilla con ámbito de grupo de recursos estructuralmente no puede hacer.

   ```bash
   cat > sub-scope.bicep <<'EOF'
   targetScope = 'subscription'

   param rgName string = 'rg-az900-lab-2'
   param location string = 'eastus'

   resource newRg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
     name: rgName
     location: location
     tags: {
       env: 'lab'
       course: 'az900'
       createdBy: 'subscription-scoped-deployment'
     }
   }

   output resourceGroupId string = newRg.id
   EOF
   ```

2. Previsualizá e implementá en ámbito de suscripción — fijate en el verbo distinto de la CLI: `az deployment sub`, no `az deployment group`.

   ```bash
   az deployment sub what-if \
     --location "$LOC" \
     --name lab-rg-creation \
     --template-file sub-scope.bicep
   ```

   ```
     + Microsoft.Resources/resourceGroups/rg-az900-lab-2

   Resource changes: 1 to create.
   ```

   ```bash
   az deployment sub create \
     --location "$LOC" \
     --name lab-rg-creation \
     --template-file sub-scope.bicep \
     --query "properties.provisioningState" -o tsv
   ```

   ```
   Succeeded
   ```

3. Notá que una implementación con ámbito de suscripción requiere `--location`: no hay grupo de recursos del cual heredar una región, así que hay que decirle a ARM dónde persistir el objeto de metadatos de la implementación.

4. Listá las implementaciones en cada ámbito y observá que son historiales separados.

   ```bash
   az deployment sub list --query "[].{name:name, state:properties.provisioningState}" -o table
   az deployment group list --resource-group "$RG" --query "length(@)" -o tsv
   ```

5. Inspeccioná la jerarquía de grupos de administración — el ámbito por encima de las suscripciones, donde opera `az deployment mg create`.

   ```bash
   az account management-group list --query "[].{name:name, displayName:displayName}" -o table
   ```

   ```
   Name                                  DisplayName
   ------------------------------------  ----------------
   8f2b1c4a-3e77-4a1c-9c5c-0d1e2f3a4b5c  Tenant Root Group
   ```

6. Limpiá el segundo grupo de recursos.

   ```bash
   az group delete --name rg-az900-lab-2 --yes --no-wait
   ```

### Verificá lo que entendiste — Bloque 6

- **Q6.1** — Listá los cuatro ámbitos de implementación de ARM del más estrecho al más amplio, y dá el comando de la CLI para cada uno.
- **Q6.2** — ¿Por qué `az deployment sub create` requiere `--location` mientras que `az deployment group create` no?
- **Q6.3** — Tenés que garantizar que *todas* las suscripciones de la organización reciban una política de etiquetado idéntica y un conjunto idéntico de asignaciones RBAC. ¿A qué ámbito de implementación apuntás, y por qué la implementación por grupo de recursos es la respuesta equivocada?
- **Q6.4** — ¿Puede una plantilla con ámbito de grupo de recursos crear el grupo de recursos en el que se implementa? Explicá.

---

## Ejercicio 7 — Barandas de administración: etiquetas, bloqueos y semántica de movimiento

**Objetivo:** ejercitar las funciones de administración a nivel de ARM que se aplican de manera uniforme a todo tipo de recurso porque viven en el plano de control, no en los servicios individuales.

### Pasos

1. Leé las etiquetas que ARM aplicó y notá que las etiquetas del grupo de recursos **no** son heredadas por los recursos hijos.

   ```bash
   az group show --name "$RG" --query tags -o json
   az resource list --resource-group "$RG" --query "[].{name:name, tags:tags}" -o json
   ```

   ```json
   {
     "course": "az900",
     "env": "lab",
     "owner": "student"
   }
   [
     {
       "name": "stlab3kq7hv2nrxa4e",
       "tags": {
         "course": "az900",
         "env": "lab",
         "managedBy": "arm-template"
       }
     }
   ]
   ```

   La cuenta de almacenamiento tiene `managedBy` pero no `owner` — porque la plantilla fijó sus etiquetas explícitamente, no porque haya heredado nada.

2. Agregá una etiqueta a un recurso existente sin tocar la plantilla (deriva imperativa — fijate en lo que esto te va a costar más adelante).

   ```bash
   export SA=$(az storage account list -g "$RG" --query "[0].name" -o tsv)
   az tag update \
     --resource-id "$(az storage account show -g $RG -n $SA --query id -o tsv)" \
     --operation Merge --tags costCenter=CC-4471 \
     --query "properties.tags" -o json
   ```

   ```json
   {
     "costCenter": "CC-4471",
     "course": "az900",
     "env": "lab",
     "managedBy": "arm-template"
   }
   ```

3. Demostrá la deriva: what-if ahora informa una modificación, porque la plantilla no declara `costCenter`.

   ```bash
   az deployment group what-if --resource-group "$RG" --template-file storage.bicep
   ```

   ```
     ~ Microsoft.Storage/storageAccounts/stlab3kq7hv2nrxa4e [2023-05-01]
       - tags.costCenter: "CC-4471"

   Resource changes: 1 to modify.
   ```

4. Aplicá un bloqueo **CanNotDelete** en el ámbito del grupo de recursos.

   ```bash
   az lock create \
     --name lock-az900-lab \
     --lock-type CanNotDelete \
     --resource-group "$RG" \
     --notes "AZ-900 lab guardrail" \
     --query "{name:name, level:level}" -o json
   ```

   ```json
   {
     "level": "CanNotDelete",
     "name": "lock-az900-lab"
   }
   ```

5. Intentá borrar la cuenta de almacenamiento *hija* y observá que los bloqueos **se heredan hacia abajo**.

   ```bash
   az storage account delete -g "$RG" -n "$SA" --yes
   ```

   ```
   (ScopeLocked) The scope '/subscriptions/8f2b.../resourceGroups/rg-az900-lab/providers/
   Microsoft.Storage/storageAccounts/stlab3kq7hv2nrxa4e' cannot perform delete operation
   because following scope(s) are locked: '/subscriptions/8f2b.../resourceGroups/rg-az900-lab'.
   Please remove the lock and try again.
   Code: ScopeLocked
   ```

6. Confirmá que el bloqueo es una baranda **solo del plano de control**: bloquea el delete de ARM, pero no bloquea las escrituras del plano de datos.

   ```bash
   az storage container create --account-name "$SA" --name testdata --auth-mode login -o json
   ```

   ```json
   { "created": true }
   ```

7. Quitá el bloqueo.

   ```bash
   az lock delete --name lock-az900-lab --resource-group "$RG"
   az lock list --resource-group "$RG" -o table
   ```

### Verificá lo que entendiste — Bloque 7

- **Q7.1** — ¿Los recursos hijos heredan las etiquetas de su grupo de recursos? ¿Heredan los bloqueos? Explicá la asimetría que observaste en los pasos 1 y 5.
- **Q7.2** — ¿Qué dos niveles de bloqueo existen, y cuál rompería una aplicación que periódicamente escribe configuración de vuelta en su propio recurso?
- **Q7.3** — En el paso 6, el bloqueo impidió un delete pero permitió crear un contenedor. ¿Qué distinción arquitectónica demuestra esto?
- **Q7.4** — Después de agregar `costCenter` manualmente en el portal, un pipeline programado reimplementa la plantilla y la etiqueta desaparece. Explicá el mecanismo e indicá la solución correcta.
- **Q7.5** — Un recurso está protegido por `CanNotDelete` y realmente necesitás borrarlo. ¿Cuál es el orden de operaciones requerido, y qué permiso de RBAC necesitás?

---

## Ejercicio 8 — Azure Arc: extender el plano de control de ARM fuera de Azure

**Objetivo:** entender el valor central de Arc — proyectar máquinas y clústeres que no están en Azure dentro de ARM como recursos de primera clase, para que RBAC, etiquetas, Policy, Monitor e inventario se les apliquen de manera idéntica.

> El **Camino A** requiere cualquier máquina Linux o Windows que **no** sea una VM de Azure (una VM en tu laptop, un invitado de Hyper-V/VirtualBox, un servidor on-prem, una instancia EC2) con HTTPS saliente. El **Camino B** es de solo lectura y no necesita ninguna máquina externa — hacé el Camino B si no podés hacer el Camino A.

### Pasos — Camino A: incorporar un servidor con Azure Arc

1. Registrá los proveedores de recursos requeridos (recordá que el Ejercicio 1, paso 7, mostraba `NotRegistered`).

   ```bash
   for ns in Microsoft.HybridCompute Microsoft.GuestConfiguration Microsoft.HybridConnectivity Microsoft.Compute; do
     az provider register --namespace "$ns" --wait
     echo "$ns -> $(az provider show --namespace $ns --query registrationState -o tsv)"
   done
   ```

   ```
   Microsoft.HybridCompute -> Registered
   Microsoft.GuestConfiguration -> Registered
   Microsoft.HybridConnectivity -> Registered
   Microsoft.Compute -> Registered
   ```

2. En la **máquina destino** (no en Cloud Shell), instalá el agente de Connected Machine.

   ```bash
   # Linux
   curl -fsSL https://aka.ms/install_linux_azcmagent -o install_linux_azcmagent.sh
   sudo bash install_linux_azcmagent.sh
   azcmagent version
   ```

   ```
   Azure Connected Machine Agent v1.46.02664.1737
   ```

3. Conectá la máquina a ARM. Esto realiza una autenticación de dispositivo de Entra ID y crea un recurso `Microsoft.HybridCompute/machines`.

   ```bash
   sudo azcmagent connect \
     --resource-group "rg-az900-lab" \
     --tenant-id "<TENANT_ID>" \
     --location "eastus" \
     --subscription-id "<SUBSCRIPTION_ID>" \
     --cloud "AzureCloud" \
     --tags "env=lab,course=az900"
   ```

   ```
   INFO    Connecting machine to Azure...
   INFO    Testing connectivity to endpoints that are needed to connect to Azure...
   INFO    Creating resource in Azure...
   INFO    Connected machine to Azure
   ```

4. Verificá desde la máquina, y después desde Azure — el mismo objeto, dos vistas.

   ```bash
   sudo azcmagent show
   ```

   ```
   Resource Name                       : lab-server-01
   Resource Group Name                 : rg-az900-lab
   Resource Location                   : eastus
   Agent Status                        : Connected
   Agent Last Heartbeat (UTC)          : 2026-09-05T14:58:12Z
   Using Proxy                         : no
   Agent Version                       : 1.46.02664.1737
   ```

   ```bash
   az connectedmachine list -g "$RG" \
     --query "[].{name:name, os:properties.osName, status:properties.status, agent:properties.agentVersion}" -o table
   ```

   ```
   Name            Os      Status     Agent
   --------------  ------  ---------  -----------------
   lab-server-01   linux   Connected  1.46.02664.1737
   ```

5. Confirmá que la máquina ahora es direccionable por un ID de recurso de ARM — el sentido entero de Arc.

   ```bash
   az connectedmachine show -g "$RG" -n lab-server-01 --query id -o tsv
   ```

   ```
   /subscriptions/8f2b1c4a-.../resourceGroups/rg-az900-lab/providers/Microsoft.HybridCompute/machines/lab-server-01
   ```

6. En el portal, abrí **Azure Arc → Machines → lab-server-01**. Confirmá las hojas disponibles: **Tags**, **Access control (IAM)**, **Policies**, **Extensions**, **Inventory**, **Updates**. Son las mismas hojas de gobernanza que tiene una VM de Azure.

7. Desconectá y desinstalá cuando termines.

   ```bash
   sudo azcmagent disconnect
   sudo bash install_linux_azcmagent.sh --uninstall   # or: sudo apt purge azcmagent
   ```

### Pasos — Camino B: inspeccionar la superficie de Arc sin una máquina externa

1. Registrá los proveedores como en el Camino A, paso 1.

2. Enumerá los tipos de recurso que Arc proyecta en ARM.

   ```bash
   az provider show --namespace Microsoft.HybridCompute --query "resourceTypes[].resourceType" -o tsv
   az provider show --namespace Microsoft.Kubernetes  --query "resourceTypes[].resourceType" -o tsv
   ```

   ```
   machines
   machines/extensions
   machines/runCommands
   licenses
   ...
   connectedClusters
   ```

3. Revisá cómo se ve la incorporación de un Kubernetes habilitado para Arc (es seguro leerlo; ejecutalo solo contra un clúster que sea tuyo, por ejemplo k3s o kind):

   ```bash
   az extension add --name connectedk8s --only-show-errors
   # az connectedk8s connect --name arc-k3s-lab --resource-group "$RG" --location "$LOC"
   # kubectl get pods -n azure-arc
   ```

   ```
   NAME                                        READY   STATUS    RESTARTS   AGE
   cluster-metadata-operator-7f9c...           2/2     Running   0          3m
   clusterconnect-agent-6b4d...                3/3     Running   0          3m
   clusteridentityoperator-59f7...             2/2     Running   0          3m
   config-agent-84cd...                        2/2     Running   0          3m
   controller-manager-7d55...                  2/2     Running   0          3m
   extension-manager-6c9b...                   3/3     Running   0          3m
   kube-aad-proxy-58bb...                      2/2     Running   0          3m
   metrics-agent-7a41...                       2/2     Running   0          3m
   resource-sync-agent-5f8e...                 2/2     Running   0          3m
   ```

4. Fijate en el modelo de red en la documentación: los agentes de Arc establecen conexiones **HTTPS (443) solo salientes** hacia endpoints como `login.microsoftonline.com`, `management.azure.com`, `*.his.arc.azure.com` y `*.guestconfiguration.azure.com`. No se abre ningún puerto entrante.

### Verificá lo que entendiste — Bloque 8

- **Q8.1** — En una oración, ¿qué problema resuelve Azure Arc? Nombrá cuatro clases de recursos que puede proyectar en ARM.
- **Q8.2** — Después de la incorporación, `lab-server-01` tiene un ID de recurso de ARM. Nombrá tres capacidades de gobernanza de Azure que esto desbloquea para una máquina que está en tu propio datacenter.
- **Q8.3** — ¿Azure Arc mueve, migra o replica tu carga de trabajo local hacia Azure? Explicá con precisión qué cruza la frontera y qué no.
- **Q8.4** — Un equipo de seguridad objeta: "no vamos a abrir puertos entrantes del firewall para esto". ¿Cómo respondés, basándote en el paso 4?
- **Q8.5** — ¿Por qué instalar el agente de Connected Machine en una VM normal de Azure no está soportado?
- **Q8.6** — La incorporación de una máquina falló con `MissingSubscriptionRegistration` para `Microsoft.HybridCompute`. Conectá esto con el Ejercicio 1.

---

## Ejercicio 9 — Diagnosticar una implementación fallida, y después limpiar

**Objetivo:** practicar el camino real de resolución de problemas cuando una implementación falla — operaciones de implementación, códigos de error, y el ID de correlación del registro de actividad.

### Pasos

1. Forzá una falla realista: un SKU inválido para el tipo de recurso.

   ```bash
   az deployment group create \
     --resource-group "$RG" \
     --name lab-failure \
     --template-file storage.bicep \
     --parameters skuName=Premium_ZRS 2>&1 | head -20
   ```

   ```
   ERROR: {"code": "InvalidTemplate", "message": "Deployment template validation failed:
   'The provided value 'Premium_ZRS' for the template parameter 'skuName' at line '1' and
   column '210' is not valid. The parameter value is not part of the allowed value(s):
   'Standard_LRS,Standard_GRS,Standard_ZRS'.'", "additionalInfo": ...}
   ```

   El decorador `@allowed` lo atrapó **antes** de que se tocara ningún recurso.

2. Ahora forzá una falla que llegue hasta el proveedor de recursos — una colisión de nombres.

   ```bash
   az deployment group create \
     --resource-group "$RG" --name lab-failure-2 \
     --template-uri "https://raw.githubusercontent.com/Azure/azure-quickstart-templates/master/quickstarts/microsoft.storage/storage-account-create/azuredeploy.json" \
     --parameters storageAccountType=Standard_LRS location="$LOC" 2>&1 | tail -5
   ```

3. Profundizá en las operaciones de implementación por recurso — la capa donde vive el error del *proveedor*.

   ```bash
   az deployment operation group list \
     --resource-group "$RG" --name lab-failure-2 \
     --query "[?properties.provisioningState=='Failed'].{op:properties.provisioningOperation, res:properties.targetResource.resourceName, status:properties.statusCode, msg:properties.statusMessage.error.code}" -o table
   ```

   ```
   Op      Res                  Status    Msg
   ------  -------------------  --------  -------------------------
   Create  store3kq7hv2nrxa4e   Conflict  StorageAccountAlreadyTaken
   ```

4. Rastreá el mismo evento en el **Activity Log**, que registra cada operación de escritura de ARM durante 90 días.

   ```bash
   az monitor activity-log list \
     --resource-group "$RG" \
     --offset 1h \
     --query "[?operationName.value=='Microsoft.Resources/deployments/write'].{time:eventTimestamp, status:status.value, caller:caller, corr:correlationId}" \
     -o table | head -5
   ```

   ```
   Time                              Status     Caller                  Corr
   --------------------------------  ---------  ----------------------  ------------------------------------
   2026-09-05T15:04:11.9021Z         Failed     student@contoso.com     3c2ab9f4-8e11-4f5a-9c02-7d6b1a2e3f44
   2026-09-05T14:22:41.1183Z         Succeeded  student@contoso.com     a71f0e2b-55c3-4d7e-b1a9-90cf3e4d5a61
   ```

5. **Limpieza.** Quitá primero los bloqueos, después el grupo de recursos completo. Borrar un grupo de recursos borra todos los recursos que contiene.

   ```bash
   az lock list --resource-group "$RG" -o tsv                # must be empty
   az group delete --name "$RG" --yes --no-wait
   az group exists --name "$RG"
   ```

   ```
   false
   ```

6. Si montaste el almacenamiento de Cloud Shell y querés eliminarlo también, borrá además el grupo de recursos `cloud-shell-storage-<region>`.

   ```bash
   az group list --query "[?starts_with(name,'cloud-shell-storage')].name" -o tsv
   ```

### Verificá lo que entendiste — Bloque 9

- **Q9.1** — En este ejercicio ocurrieron dos fallas. ¿Cuál fue atrapada por la validación de plantilla de ARM y cuál por el proveedor de recursos? ¿Por qué importa la distinción a nivel operativo?
- **Q9.2** — `az deployment group show` informa `Failed` pero el mensaje es genérico. ¿Qué comando te da la causa por recurso?
- **Q9.3** — ¿Para qué sirve el ID de correlación, y cuánto tiempo retiene los eventos el Activity Log de forma predeterminada?
- **Q9.4** — Borrar el grupo de recursos falló con `ScopeLocked`. ¿Qué tenés que hacer primero, y por qué este comportamiento es deseable?

---

<details>
<summary><strong>Respuestas</strong> — hacé clic para expandir</summary>

### Bloque 1 — Azure Resource Manager

**A1.1** — **Un** solo plano de administración: Azure Resource Manager. El portal, PowerShell y el SDK son todos clientes que se autentican contra Microsoft Entra ID y emiten llamadas REST a `https://management.azure.com`. Por eso RBAC, Azure Policy, los bloqueos de recursos, las etiquetas y la auditoría del Activity Log son uniformes e inevitables: los aplica el propio ARM, antes de que la solicitud llegue siquiera al proveedor de recursos. No hay "puerta lateral" — no podés eludir un deny de Policy cambiando del portal a la CLI.

**A1.2** — Segmentos:
| Segmento | Valor | Significado |
|---|---|---|
| `/subscriptions/{guid}` | `8f2b...` | Frontera de facturación y administración |
| `/resourceGroups/{name}` | `rg-az900-lab` | Contenedor de ciclo de vida |
| `/providers/{namespace}` | `Microsoft.Storage` | **El proveedor de recursos** |
| `/{resourceType}` | `storageAccounts` | Tipo implementado por ese proveedor |
| `/{name}` | `stlab001` | La instancia |

**A1.3** — El proveedor de recursos que implementa el tipo solicitado no está registrado en esa suscripción. ARM se niega a enrutar la llamada. Solución: `az provider register --namespace Microsoft.<Namespace> --wait`, y después reintentar. El registro es por suscripción e idempotente.

**A1.4** — Sí. El plano de control de ARM está distribuido globalmente y no está atado a la región que hospeda tus recursos; una interrupción regional afecta al *plano de datos* y a los recursos en sí, pero las solicitudes de administración se siguen atendiendo. (Una interrupción regional puede, por supuesto, impedir que las operaciones *se completen* contra recursos que están físicamente en la región afectada.)

---

### Bloque 2 — Azure Cloud Shell, CLI de Azure, Azure PowerShell

**A2.1** — El cómputo de Cloud Shell (el contenedor) y el instrumental preinstalado son gratuitos. Lo que se factura es el **recurso compartido de Azure Files** que respalda el `clouddrive` persistente — precio estándar de Azure Files sobre la imagen de 5 GB, aproximadamente $0.30/mes. Elegir una sesión efímera evita la cuenta de almacenamiento por completo, a costa de la persistencia.

**A2.2** — Debería haber ido a `~/clouddrive/`, que es el punto de montaje del recurso compartido de Azure Files. Los contenedores de Cloud Shell son **efímeros** — la sesión se recicla después de ~20 minutos de inactividad y el contenedor se destruye; solo sobrevive el recurso compartido montado. (El contenido de `$HOME` se restaura desde la imagen guardada en el recurso compartido en las sesiones con almacenamiento montado, pero la ubicación de persistencia garantizada es `clouddrive`.)

**A2.3** — **Azure Cloud Shell**, un shell autenticado basado en el navegador con el instrumental preinstalado (`az`, `kubectl`, `helm`, `terraform`, `git`, `ansible`). Sus dos experiencias de shell son **Bash** y **PowerShell**, intercambiables dentro de la misma sesión.

**A2.4** — **Azure PowerShell** encaja más naturalmente. Sus cmdlets emiten objetos .NET, así que `Get-AzResourceGroup | Where-Object {...} | Get-AzResource | Measure-Object` se compone sin parseo. La CLI de Azure emite *texto* JSON, así que la misma lógica necesita `--query` (JMESPath) más `jq` o bucles de shell. Ambas son plenamente capaces; la diferencia es el pipeline de objetos versus texto y consulta.

**A2.5** — No. La CLI de Azure es una herramienta multiplataforma independiente que corre en **Windows, macOS y Linux** (y en Docker). Cloud Shell es simplemente un lugar hospedado donde viene preinstalada. El módulo `Az` de PowerShell es igualmente multiplataforma sobre PowerShell 7.

---

### Bloque 3 — Portal de Azure y Resource Graph

**A3.1** — El portal aporta: una consola gráfica unificada con asistentes de creación guiados y validación en línea; paneles, favoritos y métricas/gráficos visuales; y descubribilidad — catálogo de servicios, enlaces a documentación, estimaciones de costo antes de comprometerte. Lo que REST/CLI/PowerShell ofrece y el portal no puede hacer en la práctica: **automatización y repetibilidad a escala** — scripting, pipelines de CI/CD, operaciones masivas sobre cientos de recursos, y cambios versionados y revisables.

**A3.2** — La lista de recursos del portal está acotada y paginada por suscripción/grupo de recursos; responder a lo largo de 47 suscripciones significaría 47 pasadas manuales sin agregación. **Azure Resource Graph** es la respuesta: un índice consultable con KQL, entre suscripciones, de todos los recursos, disponible en el portal (Resource Graph Explorer) y vía `az graph query`.

**A3.3** — `az group export` (equivalente en el portal: **Export template** en la hoja del grupo de recursos o del recurso). Limitaciones: el JSON exportado contiene valores fijos en vez de parámetros, puede omitir o deformar algunos tipos de recurso y propiedades, no incorpora lógica de dependencias que valga la pena conservar, e incluye estado de tiempo de ejecución que no debería reimplementarse. Es un *punto de partida* para refactorizar hacia Bicep parametrizado, no IaC de producción.

**A3.4** — Son **recursos de Azure gobernables** del tipo `Microsoft.Portal/dashboards`. El paso 3 los listó con `az resource list`, lo que prueba que viven en un grupo de recursos, tienen un ID de recurso, y por lo tanto están sujetos a RBAC, etiquetas, bloqueos y Policy como cualquier otra cosa — eso es lo que hace posibles los paneles compartidos de equipo.

---

### Bloque 4 — Plantillas ARM, idempotencia, modos de implementación

**A4.1** — *Declarativo* enuncia el **estado final deseado** y deja que el motor calcule las acciones; *imperativo* enuncia la **secuencia de acciones** a realizar. Clasificación: (a) `storage.json` — declarativo; (b) `az storage account create` — imperativo; (c) el bucle de Bash que llama a `az vm create` — imperativo (un script de comandos, no una descripción de un estado objetivo).

**A4.2** — **Idempotencia**: aplicar la misma plantilla al mismo destino repetidamente produce el mismo estado final, sin recursos duplicados y sin error en la segunda ejecución. Para CI/CD esto es esencial — el pipeline puede reimplementar con seguridad en cada commit, los reintentos después de una falla parcial son inocuos, y la plantilla se convierte en la única fuente de verdad en vez de un script de un solo uso.

**A4.3** —
- **Incremental (predeterminado):** los recursos de la plantilla se crean o actualizan; los recursos presentes en el grupo de recursos pero *ausentes de la plantilla* **quedan intactos**.
- **Complete:** los recursos del grupo de recursos que **no están en la plantilla se borran**.

Incidente clásico: un ingeniero implementa una plantilla pequeña y correcta con `--mode Complete` dentro de un grupo de recursos compartido de producción, y ARM borra todos los recursos que esa plantilla no declara — VMs, bases de datos, interfaces de red. Por eso hacer `what-if` antes de una implementación en modo Complete es innegociable, y por eso el modo Complete pertenece únicamente a grupos de recursos que son propiedad total de una sola plantilla.

**A4.4** — `validate` realiza una verificación estática/previa: corrección del esquema, tipos de parámetros y valores permitidos, versiones de API, sintaxis de los nombres de recursos. `what-if` hace todo eso **más** comparar la plantilla contra el *estado vivo actual* y devolver un diff por recurso y por propiedad (`+ Create`, `- Delete`, `~ Modify`, `= NoChange`, `* Ignore`). `validate` responde "¿está bien formada esta plantilla?"; `what-if` responde "¿qué va a cambiar realmente si la ejecuto?".

**A4.5** — (1) **Unicidad global**: los nombres de cuentas de almacenamiento comparten un único espacio de nombres DNS en todo Azure, así que un nombre fijo va a colisionar (`StorageAccountAlreadyTaken`) y va a hacer que la plantilla no sea reutilizable. (2) **Idempotencia determinista**: `uniqueString` es un hash, no un valor aleatorio — el mismo ID de grupo de recursos siempre produce el mismo nombre, así que reimplementar actualiza la cuenta existente en vez de crear una segunda. Una función aleatoria rompería la idempotencia.

**A4.6** — En el **historial de implementaciones**, guardado por ARM como objetos `Microsoft.Resources/deployments` **en el ámbito de la implementación** — acá, el grupo de recursos `rg-az900-lab`. Es consultable con `az deployment group list/show` y visible bajo la hoja *Deployments* del grupo de recursos. ARM retiene hasta 800 implementaciones por grupo de recursos, purgando automáticamente las más viejas.

---

### Bloque 5 — Bicep

**A5.1** — No. Bicep es un **lenguaje específico de dominio que transpila a ARM JSON**; hay una correspondencia uno a uno y no hay runtime, archivo de estado ni servicio separados. Cuando implementás un archivo `.bicep`, el instrumental lo compila en memoria y ARM recibe ARM JSON común — podés ver el bloque `metadata._generator` inyectado que lo prueba en el paso 2.

**A5.2** — (1) **Concisión** — 36 líneas contra 62, sin el andamiaje de `$schema`/`contentVersion`, sin la gimnasia de funciones de cadena `[concat(...)]` (paso 3). (2) **Seguridad de tipos e IntelliSense en tiempo de autoría** — `BCP036` atrapó `accessTier: 'Warm'` en tiempo de compilación, antes de cualquier llamada a la API (paso 5); ARM JSON no tiene esa verificación. (3) **Inferencia automática de dependencias y referencias simbólicas** — `storageAccount.properties.primaryEndpoints.blob` reemplaza a `reference(resourceId(...))`, y `dependsOn` normalmente se infiere. También vale mencionar: módulos para composición, y ningún archivo de estado que administrar.

**A5.3** — `az bicep decompile --file <template>.json`. Después, revisá a mano: los nombres generados de parámetros y variables son derivados por máquina y poco útiles; las cadenas `[concat(...)]` suelen sobrevivir como interpolación de cadenas que podría simplificarse; el descompilador emite advertencias por construcciones que no puede mapear limpiamente; y las versiones de API deberían revisarse y modernizarse. La descompilación es un acelerador de migración, no una refactorización terminada.

**A5.4** — **Bicep** es el lenguaje de IaC propio de Microsoft, nativo de ARM — sin archivo de estado, con cobertura de tipos de recurso siempre actualizada vía ARM, respaldado por el soporte de Microsoft. **Terraform** es de un tercero (HashiCorp), multinube, y requiere administrar un **archivo de estado** (más su backend, bloqueo y reconciliación de deriva) y depende de un proveedor que va detrás de la API de ARM. Ambos son válidos en Azure; Bicep es la respuesta cuando el examen pregunta por el lenguaje de IaC nativo de Azure.

---

### Bloque 6 — Ámbitos de implementación

**A6.1** — Del más estrecho al más amplio:
| Ámbito | Comando | Uso típico |
|---|---|---|
| Grupo de recursos | `az deployment group create` | Recursos de carga de trabajo |
| Suscripción | `az deployment sub create` | Grupos de recursos, política/RBAC a nivel de suscripción |
| Grupo de administración | `az deployment mg create` | Política y RBAC en muchas suscripciones |
| Inquilino | `az deployment tenant create` | La jerarquía de grupos de administración en sí |

**A6.2** — La implementación en sí misma es un objeto de ARM (`Microsoft.Resources/deployments`) cuyos metadatos deben persistirse en algún lugar regional. Una implementación de grupo de recursos hereda la ubicación del grupo de recursos; una implementación con ámbito de suscripción no tiene grupo de recursos padre del cual heredar, así que tenés que decirle a ARM dónde guardar el registro de la implementación. Notá que esta es la ubicación de los *metadatos de la implementación*, no necesariamente la de los recursos que crea.

**A6.3** — Apuntá al ámbito de **grupo de administración** (`az deployment mg create`), poniendo las suscripciones bajo un grupo de administración común. Implementar por grupo de recursos está mal porque no es exhaustivo (aparecen nuevos grupos de recursos y nuevas suscripciones sin la política), no escala, y hace que el control sea inaplicable por diseño — la gobernanza debe aplicarse en o por encima de la frontera que pretende cubrir, para que todo lo que se cree por debajo la herede.

**A6.4** — No. Una implementación con ámbito de grupo de recursos se *ejecuta contra* un grupo de recursos existente, que ya debe existir para que ARM pueda enrutar la solicitud. Crear un grupo de recursos es una operación `Microsoft.Resources/resourceGroups` en ámbito de **suscripción** — que es exactamente lo que declaró `targetScope = 'subscription'` en el paso 1.

---

### Bloque 7 — Etiquetas, bloqueos y deriva

**A7.1** — **Las etiquetas no se heredan**; cada recurso lleva su propia colección de etiquetas, y las etiquetas de un grupo de recursos no dicen nada sobre sus hijos (paso 1: la cuenta de almacenamiento tiene `managedBy` pero no `owner`). La herencia hay que *simularla* con Azure Policy (`Inherit a tag from the resource group` — efecto `modify`). **Los bloqueos sí se heredan**, hacia abajo desde el ámbito donde se aplican hacia cada hijo (paso 5: el bloqueo del grupo de recursos impidió borrar la cuenta de almacenamiento). La asimetría es deliberada: las etiquetas son metadatos de organización y facturación, evaluados por recurso; los bloqueos son barandas de autorización, evaluados sobre toda la ruta del ámbito para que no puedan eludirse apuntando a un hijo.

**A7.2** — **CanNotDelete** (portal: *Delete*) — lectura y modificación permitidas, borrado bloqueado. **ReadOnly** — solo se permiten operaciones de lectura; toda escritura y borrado quedan bloqueados. **ReadOnly** es el peligroso: cualquier aplicación o servicio que escriba de vuelta en su propio recurso (rotación de claves, operaciones de escalado, actualizaciones de configuración, algunas operaciones internas de servicios administrados) se va a romper, muchas veces con errores confusos del proveedor.

**A7.3** — La distinción entre el **plano de control** (ARM: crear/leer/actualizar/borrar el *recurso*, en `management.azure.com`) y el **plano de datos** (el endpoint propio del servicio: blobs, colas, filas de base de datos, en `<account>.blob.core.windows.net`). Los bloqueos, RBAC en el ámbito de ARM, Policy y el Activity Log gobiernan el plano de control. Proteger las operaciones del plano de datos requiere controles distintos — roles de RBAC del plano de datos (por ejemplo *Storage Blob Data Contributor*), reglas de red, o políticas de inmutabilidad.

**A7.4** — La plantilla es el estado deseado declarado, y no declara `costCenter`. Cuando ARM reconcilia, aplica el objeto `tags` de la plantilla, que reemplaza la colección de etiquetas del recurso y descarta la etiqueta no declarada. Esto es **deriva de configuración**, y funciona exactamente como fue diseñado: las ediciones manuales en el portal sobre recursos administrados por IaC son efímeras. La solución correcta es agregar `costCenter` a la plantilla (como parámetro), commitearlo y reimplementar — nunca volver a aplicarlo a mano. Si las etiquetas realmente tienen que aplicarse fuera de banda, usá Azure Policy `modify`/`append` y estructurá la plantilla para que no las pise.

**A7.5** — (1) Borrá primero el bloqueo — `az lock delete --name <lock> --resource-group <rg>`, o desde la hoja *Locks* del portal — y después (2) borrá el recurso. Administrar bloqueos requiere los permisos `Microsoft.Authorization/locks/*`, que tienen **Owner** y **User Access Administrator** pero *no* Contributor. Esa separación es el punto: un Contributor puede operar recursos pero no puede quitar silenciosamente la baranda que los protege.

---

### Bloque 8 — Azure Arc

**A8.1** — Azure Arc extiende el plano de control de Azure Resource Manager a recursos **fuera de Azure** — datacenters locales, otras nubes y el borde — para que puedan administrarse con las mismas herramientas y gobernanza que los recursos nativos de Azure. Clases que proyecta: **servidores** (Windows/Linux, `Microsoft.HybridCompute/machines`), **clústeres de Kubernetes** (`Microsoft.Kubernetes/connectedClusters`), **instancias de SQL Server y servicios de datos de Azure Arc** (SQL Managed Instance, PostgreSQL), e **infraestructura de virtualización VMware vSphere / Azure Stack HCI / SCVMM**.

**A8.2** — Tres cualesquiera de: **Azure RBAC** sobre el ID de recurso de la máquina; **etiquetas** para organización y atribución de costos; **Azure Policy** con configuración de máquina para auditar o aplicar ajustes dentro del invitado; **Microsoft Defender for Cloud** para protección contra amenazas y administración de postura; **Azure Monitor / Log Analytics** con el agente de Azure Monitor; **Azure Update Manager** para evaluación e implementación de parches; **Change Tracking and Inventory**; **Run command / extensiones** para ejecución remota de scripts; inclusión en consultas de **Azure Resource Graph** junto a las VMs de Azure.

**A8.3** — No. Arc es **solo una proyección del plano de administración**. Lo que cruza la frontera son los *metadatos y la señal de administración* de la máquina: identidad, inventario de SO y hardware, latidos, resultados de cumplimiento de políticas e instrucciones de extensiones — sobre HTTPS saliente. Lo que **no** cruza: la carga de trabajo en sí, sus datos de aplicación y su cómputo. El servidor sigue funcionando exactamente donde está; Azure gana una manija de plano de control sobre él. Arc no es una herramienta de migración (esa es Azure Migrate) ni una herramienta de replicación (esa es Azure Site Recovery).

**A8.4** — No se requiere ningún puerto entrante. El agente de Connected Machine (y los agentes de Arc para Kubernetes) inician conexiones **HTTPS solo salientes sobre TCP 443** hacia un conjunto documentado y restringible de endpoints — `login.microsoftonline.com`, `management.azure.com`, `*.his.arc.azure.com`, `*.guestconfiguration.azure.com`. El firewall puede permitir exactamente esos FQDN, se puede interponer un proxy HTTP o un ámbito de Azure Private Link, y la máquina sigue siendo inalcanzable desde internet.

**A8.5** — Una VM de Azure *ya es* un recurso de ARM (`Microsoft.Compute/virtualMachines`) con su propio agente e identidad. Instalar el agente de Connected Machine crea una segunda representación conflictiva de la misma máquina, y los dos agentes compiten por el endpoint del Instance Metadata Service (`169.254.169.254`) que se usa para obtener tokens de identidad administrada — produciendo comportamiento impredecible de identidad y extensiones. Microsoft documenta una solución alternativa solo para evaluación (bloquear la ruta a IMDS) que está explícitamente no soportada para producción.

**A8.6** — Causa raíz idéntica a la del Ejercicio 1, Q1.3: ARM no puede enrutar solicitudes para un tipo de recurso cuyo proveedor no está registrado en la suscripción. Los recursos de servidor de Arc viven bajo el espacio de nombres `Microsoft.HybridCompute`, así que ese proveedor (más `Microsoft.GuestConfiguration` y `Microsoft.HybridConnectivity` para las funciones de política y conectividad) debe registrarse primero: `az provider register --namespace Microsoft.HybridCompute --wait`. Los recursos de Arc son recursos comunes de ARM y obedecen todas las reglas de ARM.

---

### Bloque 9 — Resolución de problemas de implementación

**A9.1** — La falla de `Premium_ZRS` fue atrapada por la **validación de plantilla de ARM** (`InvalidTemplate`), porque el decorador `@allowed` restringe el parámetro antes de que ARM envíe nada a un proveedor — cero recursos tocados, cero costo, retroalimentación instantánea. La colisión de nombres (`StorageAccountAlreadyTaken`, HTTP 409 `Conflict`) vino del **proveedor de recursos**, `Microsoft.Storage`, y recién apareció a mitad de la implementación. Esto importa operativamente porque las fallas en la etapa del proveedor pueden dejar una implementación **parcialmente aplicada** — algunos recursos creados, otros no — que es precisamente la razón por la que las plantillas idempotentes y `what-if` son la disciplina: se vuelve a ejecutar para converger, en vez de desarmar a mano.

**A9.2** — `az deployment operation group list --resource-group <rg> --name <deployment>` (portal: **Deployments → <deployment> → Operation details**). El registro de implementación de nivel superior agrega el estado; la lista de *operaciones* contiene una entrada por recurso con el `statusCode` y el `statusMessage.error.code` propios del proveedor.

**A9.3** — El **ID de correlación** agrupa todos los eventos del Activity Log emitidos por una única operación lógica — una implementación que tocó doce recursos produce muchas entradas que comparten un ID de correlación — así podés reconstruir la cadena completa de una falla y entregársela al soporte de Microsoft como identificador único del incidente. El Activity Log retiene eventos durante **90 días**; retenerlos más tiempo requiere exportarlos mediante una configuración de diagnóstico a Log Analytics, una cuenta de almacenamiento o Event Hubs.

**A9.4** — Borrá primero el bloqueo **CanNotDelete** del grupo de recursos (`az lock delete`), y después volvé a ejecutar el borrado del grupo. Esto es deseable porque borrar un grupo de recursos es una cascada irreversible que destruye todos los recursos que contiene; el bloqueo fuerza una segunda acción deliberada y con privilegios distintos (administrar bloqueos requiere Owner o User Access Administrator, no Contributor) y así convierte una catástrofe accidental de un comando en una decisión de dos pasos.

</details>

---

## Fuentes oficiales

- Guía de estudio de AZ-900 — https://learn.microsoft.com/en-us/credentials/certifications/resources/study-guides/az-900
- ¿Qué es Azure Resource Manager? — https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/overview
- Modos de implementación de plantillas ARM — https://learn.microsoft.com/en-us/azure/azure-resource-manager/templates/deployment-modes
- What-if de plantillas ARM — https://learn.microsoft.com/en-us/azure/azure-resource-manager/templates/deploy-what-if
- Ámbitos de implementación (grupo de recursos, suscripción, grupo de administración, inquilino) — https://learn.microsoft.com/en-us/azure/azure-resource-manager/templates/deploy-to-subscription
- Proveedores y tipos de recursos de Azure — https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/resource-providers-and-types
- ¿Qué es Bicep? — https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/overview
- Descompilar ARM JSON a Bicep — https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/decompile
- Introducción a Azure Cloud Shell — https://learn.microsoft.com/en-us/azure/cloud-shell/overview
- Persistir archivos en Azure Cloud Shell — https://learn.microsoft.com/en-us/azure/cloud-shell/persisting-shell-storage
- ¿Qué es la CLI de Azure? — https://learn.microsoft.com/en-us/cli/azure/what-is-azure-cli
- Introducción a Azure PowerShell — https://learn.microsoft.com/en-us/powershell/azure/what-is-azure-powershell
- Introducción al portal de Azure — https://learn.microsoft.com/en-us/azure/azure-portal/azure-portal-overview
- Introducción a Azure Resource Graph — https://learn.microsoft.com/en-us/azure/governance/resource-graph/overview
- Usar etiquetas para organizar recursos de Azure — https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/tag-resources
- Bloquear recursos para evitar cambios — https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/lock-resources
- Introducción a Azure Arc — https://learn.microsoft.com/en-us/azure/azure-arc/overview
- Servidores habilitados para Azure Arc: agente de Connected Machine — https://learn.microsoft.com/en-us/azure/azure-arc/servers/agent-overview
- Requisitos de red de los servidores habilitados para Azure Arc — https://learn.microsoft.com/en-us/azure/azure-arc/servers/network-requirements
- Introducción a Kubernetes habilitado para Azure Arc — https://learn.microsoft.com/en-us/azure/azure-arc/kubernetes/overview
- Solucionar errores comunes de implementación en Azure — https://learn.microsoft.com/en-us/azure/azure-resource-manager/troubleshooting/common-deployment-errors
- Registro de actividad de Azure Monitor — https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/activity-log