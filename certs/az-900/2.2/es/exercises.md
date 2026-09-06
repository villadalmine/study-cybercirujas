# Ejercicios guiados — Tema 2.2: Describir los servicios de computación y redes de Azure

**Certificación:** AZ-900 — Microsoft Azure Fundamentals (versión del examen 2026-07-20)
**Peso en el examen de esta área de dominio:** 9.62
**Tiempo estimado de laboratorio:** 120–150 minutos
**Requisitos previos:** una suscripción de Azure con derechos de Colaborador, y Azure Cloud Shell (Bash) o una instalación local de Azure CLI ≥ 2.60 más `jq`.

---

## ⚠️ Aviso de costo y seguridad — léalo antes del paso 1

Estos ejercicios crean **recursos facturables**. El laboratorio completo, ejecutado de principio a fin y desmantelado en la misma sesión, cuesta aproximadamente **USD 0.50–1.50** en una suscripción de pago por uso. Dos reglas:

1. Todo queda en **un único grupo de recursos** (`rg-az900-lab`), de modo que un solo borrado lo elimina todo. Esto no es cosmético: es el límite del ciclo de vida del grupo de recursos que usted debe comprender para el examen.
2. Nunca deje corriendo una **VPN Gateway** ni un **circuito ExpressRoute**. Esos se facturan por hora sin importar el tráfico y son los clásicos causantes de facturas sorpresa. Los ejercicios que los tocan son deliberadamente **de solo lectura**.

Ejecute el **Ejercicio 10 (limpieza)** el mismo día en que empiece.

---

## Ejercicio 0 — Arranque del entorno y el sustrato de regiones/zonas

Toda decisión de computación o red en Azure comienza con dos elecciones que no puede cambiar después sin volver a desplegar: **región** y **soporte de zonas de disponibilidad**. Establézcalas primero.

### Pasos

1. Abra Cloud Shell (Bash) o una terminal local, y confirme en qué suscripción está:

   ```bash
   az account show --output table
   ```

   Esperado:

   ```
   EnvironmentName    HomeTenantId                          IsDefault    Name                  State    TenantId
   -----------------  ------------------------------------  -----------  --------------------  -------  ------------------------------------
   AzureCloud         72f988bf-86f1-41af-91ab-2d7cd011db47  True         Pay-As-You-Go         Enabled  72f988bf-86f1-41af-91ab-2d7cd011db47
   ```

2. Exporte las variables que reutilizará el resto del laboratorio. El sufijo evita que los nombres globalmente únicos (cuentas de almacenamiento, aplicaciones web) colisionen con los de otros estudiantes:

   ```bash
   export RG=rg-az900-lab
   export LOC=eastus
   export SUFFIX=$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')
   echo "Resource group=$RG  Region=$LOC  Suffix=$SUFFIX"
   ```

3. Inspeccione el catálogo de regiones, incluida la **región emparejada** de cada una — el socio fijo que Azure usa para la replicación gestionada por la plataforma y para el despliegue escalonado del mantenimiento:

   ```bash
   az account list-locations \
     --query "[?metadata.regionType=='Physical'].{Region:name, Geography:metadata.geographyGroup, Paired:metadata.pairedRegion[0].name}" \
     --output table | head -20
   ```

   Esperado (abreviado):

   ```
   Region          Geography       Paired
   --------------  --------------  --------------
   eastus          US              westus
   eastus2         US              centralus
   westus          US              eastus
   northeurope     Europe          westeurope
   westeurope      Europe          northeurope
   brazilsouth     South America   southcentralus
   ```

4. Pregúntele a la plataforma qué tamaños de VM se ofrecen realmente en su región **y en qué zonas**. Esta es la verdad de campo; la capacidad es por tamaño, por zona, y cambia:

   ```bash
   az vm list-skus --location $LOC --size Standard_D2s_v5 --zone \
     --query "[].{Size:name, Zones:locationInfo[0].zones}" --output table
   ```

   Esperado:

   ```
   Size              Zones
   ----------------  ---------------
   Standard_D2s_v5   ['1', '2', '3']
   ```

5. Cree el grupo de recursos que contendrá cada recurso de este laboratorio:

   ```bash
   az group create --name $RG --location $LOC --output json
   ```

   Esperado:

   ```json
   {
     "id": "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-az900-lab",
     "location": "eastus",
     "managedBy": null,
     "name": "rg-az900-lab",
     "properties": { "provisioningState": "Succeeded" },
     "tags": null,
     "type": "Microsoft.Resources/resourceGroups"
   }
   ```

### Comprobación de comprensión

- **Q1.** El paso 5 le dio al grupo de recursos una `location` de `eastus`. ¿Significa eso que todos los recursos que coloque dentro deben vivir también en `eastus`? ¿Qué está almacenando realmente la ubicación del grupo de recursos?
- **Q2.** En el paso 4 el SKU informó las zonas `['1','2','3']`. ¿Son esos los mismos tres centros de datos físicos para usted y para otra suscripción en la misma región? ¿Por qué importa esto cuando compara notas con un colega?
- **Q3.** Un equipo quiere sobrevivir a la pérdida de una región completa de Azure. ¿La región emparejada del paso 3 les da eso automáticamente para una máquina virtual que desplieguen?

*Fuente: [Azure regions and availability zones](https://learn.microsoft.com/en-us/azure/reliability/availability-zones-overview) · [Azure region pairs](https://learn.microsoft.com/en-us/azure/reliability/regions-paired)*

---

## Ejercicio 1 — Desplegar una máquina virtual y enumerar los recursos que requiere

El objetivo de examen *"describir los recursos requeridos para las máquinas virtuales"* se aprende mejor desplegando una con un solo comando y contando después lo que la plataforma creó silenciosamente en su nombre.

### Pasos

1. Cree una VM Linux. `--generate-ssh-keys` escribe un par de claves en `~/.ssh/` si aún no hay uno:

   ```bash
   az vm create \
     --resource-group $RG \
     --name vm-web-01 \
     --image Ubuntu2204 \
     --size Standard_B1s \
     --admin-username azureuser \
     --generate-ssh-keys \
     --public-ip-sku Standard \
     --nsg-rule SSH \
     --output json
   ```

   Esperado (aproximadamente 45–90 segundos):

   ```json
   {
     "fqdns": "",
     "id": "/subscriptions/.../resourceGroups/rg-az900-lab/providers/Microsoft.Compute/virtualMachines/vm-web-01",
     "location": "eastus",
     "macAddress": "00-0D-3A-1B-2C-3D",
     "powerState": "VM running",
     "privateIpAddress": "10.0.0.4",
     "publicIpAddress": "20.121.44.17",
     "resourceGroup": "rg-az900-lab",
     "zones": ""
   }
   ```

2. Ahora liste lo que produjo un solo `az vm create`:

   ```bash
   az resource list --resource-group $RG \
     --query "[].{Name:name, Type:type}" --output table
   ```

   Esperado:

   ```
   Name                Type
   ------------------  -----------------------------------------
   vm-web-01           Microsoft.Compute/virtualMachines
   vm-web-01_OsDisk_1  Microsoft.Compute/disks
   vm-web-01VMNic      Microsoft.Network/networkInterfaces
   vm-web-01NSG        Microsoft.Network/networkSecurityGroups
   vm-web-01PublicIP   Microsoft.Network/publicIPAddresses
   vm-web-01VNET       Microsoft.Network/virtualNetworks
   ```

   Seis recursos para una VM. Memorice esta lista — *es* la respuesta a "¿qué recursos requiere una VM?".

3. Inspeccione la forma de computación y el disco que la respalda:

   ```bash
   az vm show -g $RG -n vm-web-01 \
     --query "{Size:hardwareProfile.vmSize, Image:storageProfile.imageReference.sku, OsDiskType:storageProfile.osDisk.managedDisk.storageAccountType, OsDiskGB:storageProfile.osDisk.diskSizeGb, DataDisks:length(storageProfile.dataDisks)}" \
     --output json
   ```

   Esperado:

   ```json
   {
     "DataDisks": 0,
     "Image": "22_04-lts-gen2",
     "OsDiskGB": 30,
     "OsDiskType": "Premium_LRS",
     "Size": "Standard_B1s"
   }
   ```

4. Adjunte un disco de datos administrado — el nivel de almacenamiento duradero sobre el que realmente escribe una carga de trabajo de producción:

   ```bash
   az vm disk attach -g $RG --vm-name vm-web-01 \
     --name disk-data-01 --new --size-gb 32 --sku StandardSSD_LRS
   ```

   Verifique:

   ```bash
   az vm show -g $RG -n vm-web-01 \
     --query "storageProfile.dataDisks[].{Name:name, Lun:lun, GB:diskSizeGb, Sku:managedDisk.storageAccountType}" -o table
   ```

   Esperado:

   ```
   Name          Lun    GB    Sku
   ------------  -----  ----  ---------------
   disk-data-01  0      32    StandardSSD_LRS
   ```

5. Conéctese y observe lo que ve el sistema operativo invitado. Note el **disco temporal**, que existe sobre el SSD local del host:

   ```bash
   az ssh vm -g $RG -n vm-web-01 -- 'lsblk; echo "---"; df -h /mnt'
   ```

   Esperado (abreviado):

   ```
   NAME    MAJ:MIN RM  SIZE RO TYPE MOUNTPOINTS
   sda       8:0    0    4G  0 disk
   └─sda1    8:1    0    4G  0 part /mnt
   sdb       8:16   0   32G  0 disk
   sdc       8:32   0   30G  0 disk
   ├─sdc1    8:33   0 29.9G  0 part /
   ---
   Filesystem      Size  Used Avail Use% Mounted on
   /dev/sda1       3.9G   28K  3.7G   1% /mnt
   ```

   Si `az ssh` no está disponible, use `ssh azureuser@<publicIpAddress>` con la IP del paso 1.

6. Desasigne la VM y observe la diferencia entre "detenida" y "desasignada":

   ```bash
   az vm deallocate -g $RG -n vm-web-01
   az vm get-instance-view -g $RG -n vm-web-01 \
     --query "instanceView.statuses[?starts_with(code,'PowerState')].displayStatus" -o tsv
   ```

   Esperado:

   ```
   VM deallocated
   ```

   Reinícela para el siguiente ejercicio:

   ```bash
   az vm start -g $RG -n vm-web-01
   ```

### Comprobación de comprensión

- **Q4.** De los seis recursos del paso 2, ¿cuáles siguen costando dinero mientras la VM está desasignada, y cuál deja de costar?
- **Q5.** En el paso 5 el invitado vio tres dispositivos de bloque. ¿Cuál de ellos nunca debe contener datos que le importen, y qué evento destruye su contenido?
- **Q6.** El paso 1 creó una VNet llamada `vm-web-01VNET` que usted nunca pidió. ¿Qué espacio de direcciones recibió, y por qué aceptar ese valor por defecto es un problema en una organización real?
- **Q7.** Un colega dice: "apagué la VM desde dentro del sistema operativo con `sudo shutdown -h now`, así que no estoy pagando por ella". Corríjalo con precisión.
- **Q8.** El disco del sistema operativo volvió como `Premium_LRS` y el disco de datos que creó como `StandardSSD_LRS`. Nombre los cuatro tipos de disco administrado disponibles e indique cuál elegiría para una base de datos sensible a la latencia.

*Fuente: [Virtual machines in Azure](https://learn.microsoft.com/en-us/azure/virtual-machines/overview) · [Azure managed disk types](https://learn.microsoft.com/en-us/azure/virtual-machines/disks-types) · [States and billing status of Azure VMs](https://learn.microsoft.com/en-us/azure/virtual-machines/states-billing)*

---

## Ejercicio 2 — Conjuntos de disponibilidad, zonas de disponibilidad y Virtual Machine Scale Sets

Tres respuestas distintas a "¿cómo se mantiene esto en pie?", con tres dominios de fallo distintos y tres SLA distintos.

### Pasos

1. Cree un **conjunto de disponibilidad** e inspeccione su configuración de dominios de fallo/actualización:

   ```bash
   az vm availability-set create \
     -g $RG -n avset-web \
     --platform-fault-domain-count 2 \
     --platform-update-domain-count 5
   ```

   ```bash
   az vm availability-set show -g $RG -n avset-web \
     --query "{Name:name, FaultDomains:platformFaultDomainCount, UpdateDomains:platformUpdateDomainCount, Members:length(virtualMachines)}" -o json
   ```

   Esperado:

   ```json
   {
     "FaultDomains": 2,
     "Members": 0,
     "Name": "avset-web",
     "UpdateDomains": 5
   }
   ```

2. Cree un **Virtual Machine Scale Set** distribuido a lo largo de las tres zonas de disponibilidad. Este es el patrón moderno; reemplaza a los conjuntos de disponibilidad en los diseños nuevos:

   ```bash
   az vmss create \
     -g $RG -n vmss-web \
     --image Ubuntu2204 \
     --vm-sku Standard_B1s \
     --instance-count 2 \
     --zones 1 2 3 \
     --orchestration-mode Flexible \
     --admin-username azureuser \
     --generate-ssh-keys \
     --upgrade-policy-mode Automatic \
     --output none
   ```

   Esto tarda 2–4 minutos.

3. Vea dónde aterrizaron realmente las instancias:

   ```bash
   az vmss list-instances -g $RG -n vmss-web \
     --query "[].{Instance:instanceId, Zone:zones[0], State:provisioningState}" -o table
   ```

   Esperado:

   ```
   Instance                              Zone    State
   ------------------------------------  ------  ---------
   vmss-web_a1b2c3                       1       Succeeded
   vmss-web_d4e5f6                       2       Succeeded
   ```

4. Adjunte una regla de escalado automático — la propiedad que hace que un scale set sea distinto de "unas VMs que hice a mano":

   ```bash
   az monitor autoscale create \
     -g $RG --resource vmss-web \
     --resource-type Microsoft.Compute/virtualMachineScaleSets \
     --name autoscale-vmss-web \
     --min-count 2 --max-count 6 --count 2 \
     --output none

   az monitor autoscale rule create \
     -g $RG --autoscale-name autoscale-vmss-web \
     --condition "Percentage CPU > 70 avg 5m" --scale out 1

   az monitor autoscale rule create \
     -g $RG --autoscale-name autoscale-vmss-web \
     --condition "Percentage CPU < 30 avg 10m" --scale in 1
   ```

   Confirme:

   ```bash
   az monitor autoscale show -g $RG -n autoscale-vmss-web \
     --query "profiles[0].{Min:capacity.minimum, Max:capacity.maximum, Default:capacity.default, Rules:length(rules)}" -o json
   ```

   Esperado:

   ```json
   { "Default": "2", "Max": "6", "Min": "2", "Rules": 2 }
   ```

5. Anule manualmente la capacidad, para observar que el escalado es una única propiedad declarativa:

   ```bash
   az vmss scale -g $RG -n vmss-web --new-capacity 3 --output none
   az vmss list-instances -g $RG -n vmss-web --query "length(@)" -o tsv
   ```

   Esperado:

   ```
   3
   ```

6. Vuelva a bajar la escala para mantener la factura chica:

   ```bash
   az vmss scale -g $RG -n vmss-web --new-capacity 2 --output none
   ```

### Comprobación de comprensión

- **Q9.** Distinga, en una frase cada uno, contra qué protege un **dominio de fallo** y contra qué protege un **dominio de actualización**.
- **Q10.** Sus dos VMs están en un conjunto de disponibilidad en `eastus`. Una inundación deja fuera de línea toda la región `eastus`. ¿Están arriba sus VMs? Ahora responda lo mismo para dos VMs en las zonas de disponibilidad 1 y 2.
- **Q11.** Empareje cada configuración con su SLA compuesto publicado: (a) una única VM con todos los discos Premium SSD, (b) dos o más VMs en el mismo conjunto de disponibilidad, (c) dos o más VMs repartidas en dos zonas de disponibilidad.
- **Q12.** El paso 2 usó `--orchestration-mode Flexible`. Contraste la orquestación Flexible con la Uniform en términos de qué gestiona la plataforma por usted.
- **Q13.** El paso 4 creó una regla "escalar horizontalmente cuando la CPU > 70% promediada en 5 minutos". ¿Es esto escalado vertical u horizontal? Indique la operación de Azure que sería del *otro* tipo para esta carga de trabajo.
- **Q14.** ¿Por qué `--min-count 2` es una elección deliberada y no `1`, dada la respuesta a Q11?

*Fuente: [Availability options for Azure VMs](https://learn.microsoft.com/en-us/azure/virtual-machines/availability) · [Virtual Machine Scale Sets overview](https://learn.microsoft.com/en-us/azure/virtual-machine-scale-sets/overview) · [SLA for Virtual Machines](https://www.microsoft.com/licensing/docs/view/Service-Level-Agreements-SLA-for-Online-Services)*

---

## Ejercicio 3 — Azure Virtual Desktop: el plano de control sin los hosts de sesión

Azure Virtual Desktop (AVD) es un **servicio de virtualización de escritorios y aplicaciones**, no un SKU de VM. Los objetos de su plano de control — grupo de hosts, grupo de aplicaciones, área de trabajo — no cuestan nada; solo cuestan las VMs de host de sesión. Eso le permite construir toda la topología gratis.

### Pasos

1. Agregue la extensión de la CLI:

   ```bash
   az extension add --name desktopvirtualization --upgrade
   az extension show --name desktopvirtualization --query "{Name:name, Version:version}" -o table
   ```

2. Cree un grupo de hosts **Pooled** — el modelo multiusuario donde muchos usuarios comparten un conjunto de hosts de sesión:

   ```bash
   az desktopvirtualization hostpool create \
     -g $RG -n hp-az900 --location $LOC \
     --host-pool-type Pooled \
     --load-balancer-type BreadthFirst \
     --preferred-app-group-type Desktop \
     --max-session-limit 10 \
     --output json
   ```

   Esperado (abreviado):

   ```json
   {
     "hostPoolType": "Pooled",
     "loadBalancerType": "BreadthFirst",
     "maxSessionLimit": 10,
     "name": "hp-az900",
     "preferredAppGroupType": "Desktop",
     "type": "Microsoft.DesktopVirtualization/hostpools"
   }
   ```

3. Cree el grupo de aplicaciones de escritorio y un área de trabajo, y luego vincúlelos:

   ```bash
   HP_ID=$(az desktopvirtualization hostpool show -g $RG -n hp-az900 --query id -o tsv)

   az desktopvirtualization applicationgroup create \
     -g $RG -n ag-desktop-az900 --location $LOC \
     --application-group-type Desktop \
     --host-pool-arm-path "$HP_ID" --output none

   AG_ID=$(az desktopvirtualization applicationgroup show -g $RG -n ag-desktop-az900 --query id -o tsv)

   az desktopvirtualization workspace create \
     -g $RG -n ws-az900 --location $LOC \
     --application-group-references "$AG_ID" --output none
   ```

4. Confirme la topología, y confirme que hay **cero hosts de sesión** — que es la razón por la que esto no cuesta nada:

   ```bash
   az desktopvirtualization workspace show -g $RG -n ws-az900 \
     --query "{Workspace:name, AppGroups:length(applicationGroupReferences)}" -o json
   az desktopvirtualization sessionhost list -g $RG --host-pool-name hp-az900 --query "length(@)" -o tsv
   ```

   Esperado:

   ```json
   { "AppGroups": 1, "Workspace": "ws-az900" }
   ```
   ```
   0
   ```

### Comprobación de comprensión

- **Q15.** Acaba de construir un grupo de hosts, un grupo de aplicaciones y un área de trabajo, y no se le cobró nada. ¿Qué *se* factura exactamente en un despliegue de AVD?
- **Q16.** Contraste un grupo de hosts **Pooled** con uno **Personal**, y dé un escenario de negocio que obligue a usar Personal.
- **Q17.** AVD permite que diez usuarios compartan un host de sesión. ¿Qué ediciones de cliente Windows admiten ese comportamiento multisesión, y por qué no puede obtenerlo con una imagen estándar de Windows 11 Pro?
- **Q18.** ¿Dónde viven los datos del usuario en un despliegue AVD pooled bien diseñado, dado que no se le garantiza al usuario el mismo host de sesión mañana?

*Fuente: [What is Azure Virtual Desktop?](https://learn.microsoft.com/en-us/azure/virtual-desktop/overview)*

---

## Ejercicio 4 — Hospedaje de aplicaciones: App Service, Container Instances, Container Apps, Functions

Cuatro modelos de hospedaje, desplegados uno al lado del otro. Observe cuánta infraestructura le pide nombrar cada uno.

### Pasos

1. **App Service (aplicación web PaaS).** Primero el plan — la computación sobre la que corre la aplicación — y después la aplicación:

   ```bash
   az appservice plan create -g $RG -n plan-az900 --sku B1 --is-linux --output none

   az webapp create -g $RG --plan plan-az900 \
     -n web-az900-$SUFFIX --runtime "PYTHON:3.12" --output none

   az webapp show -g $RG -n web-az900-$SUFFIX \
     --query "{App:name, Host:defaultHostName, State:state, Https:httpsOnly}" -o json
   ```

   Esperado:

   ```json
   {
     "App": "web-az900-4f2a",
     "Host": "web-az900-4f2a.azurewebsites.net",
     "Https": false,
     "State": "Running"
   }
   ```

2. Verifique que la plataforma la esté sirviendo, y endurezca el valor por defecto obvio:

   ```bash
   curl -s -o /dev/null -w "%{http_code}\n" https://web-az900-$SUFFIX.azurewebsites.net
   az webapp update -g $RG -n web-az900-$SUFFIX --https-only true --output none
   ```

   Esperado:

   ```
   200
   ```

3. **Azure Container Instances (ACI).** Un único contenedor, sin orquestador, sin plan que dimensionar:

   ```bash
   az container create \
     -g $RG -n aci-hello \
     --image mcr.microsoft.com/azuredocs/aci-helloworld \
     --os-type Linux --cpu 1 --memory 1.5 \
     --ports 80 --ip-address Public \
     --dns-name-label aci-az900-$SUFFIX \
     --restart-policy OnFailure \
     --output none

   az container show -g $RG -n aci-hello \
     --query "{FQDN:ipAddress.fqdn, IP:ipAddress.ip, State:instanceView.state, CPU:containers[0].resources.requests.cpu, MemGB:containers[0].resources.requests.memoryInGb}" -o json
   ```

   Esperado:

   ```json
   {
     "CPU": 1.0,
     "FQDN": "aci-az900-4f2a.eastus.azurecontainer.io",
     "IP": "20.121.98.203",
     "MemGB": 1.5,
     "State": "Running"
   }
   ```

4. Lea los registros del contenedor directamente desde la plataforma — no hay ningún host al que hacer SSH:

   ```bash
   az container logs -g $RG -n aci-hello
   curl -s -o /dev/null -w "%{http_code}\n" http://aci-az900-$SUFFIX.$LOC.azurecontainer.io
   ```

   Esperado:

   ```
   listening on port 80
   200
   ```

5. **Azure Functions (serverless / FaaS).** Una Function App necesita una cuenta de almacenamiento para su propio estado — desencadenadores, puntos de control y la carga útil de la función:

   ```bash
   az storage account create -g $RG -n stfn${SUFFIX}az900 \
     --sku Standard_LRS --kind StorageV2 --output none

   az functionapp create -g $RG -n fn-az900-$SUFFIX \
     --storage-account stfn${SUFFIX}az900 \
     --consumption-plan-location $LOC \
     --runtime python --runtime-version 3.12 \
     --functions-version 4 --os-type Linux \
     --output none

   az functionapp show -g $RG -n fn-az900-$SUFFIX \
     --query "{App:name, Host:defaultHostName, Sku:sku, State:state}" -o json
   ```

   Esperado:

   ```json
   {
     "App": "fn-az900-4f2a",
     "Host": "fn-az900-4f2a.azurewebsites.net",
     "Sku": "Dynamic",
     "State": "Running"
   }
   ```

   `"Sku": "Dynamic"` es el plan de Consumo — el nivel que escala a cero.

6. Compare qué le hizo especificar cada modelo. Cuente los parámetros que proporcionó en los pasos 1, 3 y 5, y compárelos con el paso 1 del Ejercicio 1:

   ```bash
   az resource list -g $RG --query "[].{Name:name, Type:type}" -o table
   ```

### Comprobación de comprensión

- **Q19.** Ordene los cuatro modelos — VM, App Service, Container Instances, Functions — de mayor a menor infraestructura de la que es responsable el *cliente*. ¿Qué etiqueta de modelo de servicio (IaaS / PaaS / FaaS / SaaS) aplica a cada uno?
- **Q20.** En el paso 1 creó un **plan** de App Service y luego una **aplicación**. ¿Cuál es la relación de facturación entre ambos, y qué pasa con el costo si despliega cinco aplicaciones más en `plan-az900`?
- **Q21.** ACI en el paso 3 nunca le pidió un tamaño de VM, una VNet ni un disco. ¿Qué le pidió en cambio, y cuál es la unidad de facturación?
- **Q22.** El paso 5 le impuso una cuenta de almacenamiento a la Function App. ¿Por qué un servicio "serverless" necesita almacenamiento duradero propio?
- **Q23.** Un trabajo por lotes corre durante 25 minutos. Explique por qué el plan de Consumo es el host equivocado para él, y nombre dos alternativas que lo solucionen.
- **Q24.** Un equipo tiene tres contenedores que deben comunicarse, escalar de forma independiente y escalar a cero por la noche, y no quieren operar Kubernetes. ¿Qué servicio de Azure encaja — ACI, Azure Container Apps o AKS? Justifique frente a los otros dos.

*Fuente: [App Service overview](https://learn.microsoft.com/en-us/azure/app-service/overview) · [Container Instances overview](https://learn.microsoft.com/en-us/azure/container-instances/container-instances-overview) · [Azure Functions hosting options](https://learn.microsoft.com/en-us/azure/azure-functions/functions-scale) · [Azure Container Apps overview](https://learn.microsoft.com/en-us/azure/container-apps/overview)*

---

## Ejercicio 5 — Redes virtuales, subredes y las direcciones que Azure le quita

### Pasos

1. Construya una VNet hub con un espacio de direcciones explícito y una subred:

   ```bash
   az network vnet create \
     -g $RG -n vnet-hub \
     --address-prefixes 10.10.0.0/16 \
     --subnet-name snet-app --subnet-prefixes 10.10.1.0/24 \
     --output none

   az network vnet show -g $RG -n vnet-hub \
     --query "{VNet:name, Space:addressSpace.addressPrefixes, Subnets:subnets[].{Name:name,Prefix:addressPrefix}}" -o json
   ```

   Esperado:

   ```json
   {
     "Space": ["10.10.0.0/16"],
     "Subnets": [{ "Name": "snet-app", "Prefix": "10.10.1.0/24" }],
     "VNet": "vnet-hub"
   }
   ```

2. Agregue una segunda subred — segmentación dentro de una misma VNet:

   ```bash
   az network vnet subnet create \
     -g $RG --vnet-name vnet-hub -n snet-data \
     --address-prefixes 10.10.2.0/24 --output none
   ```

3. Pregúntele a Azure cuántas direcciones le da realmente ese `/24`:

   ```bash
   az network vnet subnet show -g $RG --vnet-name vnet-hub -n snet-data \
     --query "{Prefix:addressPrefix, Available:availableIpAddressCount}" -o json
   ```

   Esperado:

   ```json
   { "Available": 251, "Prefix": "10.10.2.0/24" }
   ```

   256 direcciones en el bloque CIDR, 251 utilizables. Cinco desaparecen antes de que despliegue nada.

4. Intente crear una subred que se superponga con una existente, y lea el error con atención — este es el error de diseño de VNet más común de todos:

   ```bash
   az network vnet subnet create \
     -g $RG --vnet-name vnet-hub -n snet-bad \
     --address-prefixes 10.10.2.128/25
   ```

   Esperado:

   ```
   (NetcfgSubnetRangesOverlap) Subnet 'snet-bad' is not valid because its IP address
   range overlaps with that of an existing subnet in virtual network 'vnet-hub'.
   Code: NetcfgSubnetRangesOverlap
   ```

5. Cree un grupo de seguridad de red, adjúntelo a la subred de aplicación y agregue una regla explícita:

   ```bash
   az network nsg create -g $RG -n nsg-app --output none

   az network nsg rule create \
     -g $RG --nsg-name nsg-app -n allow-https-inbound \
     --priority 100 --direction Inbound --access Allow \
     --protocol Tcp --source-address-prefixes Internet \
     --destination-port-ranges 443 --output none

   az network vnet subnet update \
     -g $RG --vnet-name vnet-hub -n snet-app \
     --network-security-group nsg-app --output none
   ```

6. Lea las **reglas predeterminadas** que Azure aplica escriba usted alguna o no:

   ```bash
   az network nsg show -g $RG -n nsg-app \
     --query "defaultSecurityRules[].{Priority:priority, Name:name, Direction:direction, Access:access, Src:sourceAddressPrefix, Dst:destinationAddressPrefix}" -o table
   ```

   Esperado:

   ```
   Priority    Name                                  Direction    Access    Src               Dst
   ----------  ------------------------------------  -----------  --------  ----------------  ----------------
   65000       AllowVnetInBound                      Inbound      Allow     VirtualNetwork    VirtualNetwork
   65001       AllowAzureLoadBalancerInBound         Inbound      Allow     AzureLoadBalancer  *
   65500       DenyAllInBound                        Inbound      Deny      *                 *
   65000       AllowVnetOutBound                     Outbound     Allow     VirtualNetwork    VirtualNetwork
   65001       AllowInternetOutBound                 Outbound     Allow     *                 Internet
   65500       DenyAllOutBound                       Outbound     Deny      *                 *
   ```

### Comprobación de comprensión

- **Q25.** El paso 3 informó 251 direcciones utilizables en un `/24`. Enumere las cinco direcciones que Azure reserva en cada subred y para qué sirve cada una.
- **Q26.** ¿Cuál es la subred IPv4 más pequeña y la más grande que acepta Azure? Si una subred debe alojar 12 VMs, ¿cuál es el prefijo más pequeño que funciona?
- **Q27.** En el paso 6, la regla 65500 es `DenyAllInBound` y la 65001 es `AllowInternetOutBound`. Indique la postura predeterminada de un NSG recién creado para el tráfico entrante y para el saliente, y explique cómo la ordenación por prioridad la produce.
- **Q28.** Adjuntó `nsg-app` a una subred. ¿Dónde más se puede adjuntar un NSG, y cuál es el orden de evaluación cuando ambos están presentes para el tráfico entrante?
- **Q29.** Dos departamentos eligieron de forma independiente `10.0.0.0/16` para su VNet. ¿Qué operación se vuelve imposible, y cuál es la solución?
- **Q30.** ¿Una red virtual es un recurso regional o global? ¿Puede una única subred abarcar dos regiones?

*Fuente: [Azure Virtual Network overview](https://learn.microsoft.com/en-us/azure/virtual-network/virtual-networks-overview) · [Network security groups](https://learn.microsoft.com/en-us/azure/virtual-network/network-security-groups-overview)*

---

## Ejercicio 6 — Emparejamiento de VNets y su no transitividad

### Pasos

1. Cree una segunda y una tercera VNet con espacios que no se superpongan:

   ```bash
   az network vnet create -g $RG -n vnet-spoke-a \
     --address-prefixes 10.20.0.0/16 \
     --subnet-name snet-workload --subnet-prefixes 10.20.1.0/24 --output none

   az network vnet create -g $RG -n vnet-spoke-b \
     --address-prefixes 10.30.0.0/16 \
     --subnet-name snet-workload --subnet-prefixes 10.30.1.0/24 --output none
   ```

2. Empareje hub → spoke-a, y **solo en esa dirección**, y luego lea el estado:

   ```bash
   az network vnet peering create \
     -g $RG -n hub-to-spoke-a --vnet-name vnet-hub \
     --remote-vnet vnet-spoke-a --allow-vnet-access --output none

   az network vnet peering list -g $RG --vnet-name vnet-hub \
     --query "[].{Name:name, State:peeringState, Sync:peeringSyncLevel}" -o table
   ```

   Esperado:

   ```
   Name             State       Sync
   ---------------  ----------  ----------------
   hub-to-spoke-a   Initiated   RemoteNotInSync
   ```

   `Initiated`, no `Connected`. Un emparejamiento son dos objetos, uno por VNet.

3. Cree el enlace de retorno y vuelva a leer:

   ```bash
   az network vnet peering create \
     -g $RG -n spoke-a-to-hub --vnet-name vnet-spoke-a \
     --remote-vnet vnet-hub --allow-vnet-access --output none

   az network vnet peering list -g $RG --vnet-name vnet-hub \
     --query "[].{Name:name, State:peeringState}" -o table
   ```

   Esperado:

   ```
   Name             State
   ---------------  ---------
   hub-to-spoke-a   Connected
   ```

4. Complete el hub-and-spoke emparejando también hub ↔ spoke-b:

   ```bash
   az network vnet peering create -g $RG -n hub-to-spoke-b \
     --vnet-name vnet-hub --remote-vnet vnet-spoke-b --allow-vnet-access --output none
   az network vnet peering create -g $RG -n spoke-b-to-hub \
     --vnet-name vnet-spoke-b --remote-vnet vnet-hub --allow-vnet-access --output none
   ```

5. Ahora inspeccione las **rutas efectivas** en la NIC de la VM. Este es el diagnóstico que responde "¿puede A alcanzar a B?" sin adivinar:

   ```bash
   NIC=$(az vm show -g $RG -n vm-web-01 --query "networkProfile.networkInterfaces[0].id" -o tsv)
   az network nic show-effective-route-table --ids $NIC -o table
   ```

   Esperado (abreviado — `vm-web-01` sigue en su propia VNet predeterminada del Ejercicio 1, así que no ve rutas de emparejamiento):

   ```
   Source    State    Address Prefix    Next Hop Type    Next Hop IP
   --------  -------  ----------------  ---------------  -------------
   Default   Active   10.0.0.0/16       VnetLocal
   Default   Active   0.0.0.0/0         Internet
   ```

6. Liste los emparejamientos de spoke-a para confirmar qué puede y qué no puede ver:

   ```bash
   az network vnet peering list -g $RG --vnet-name vnet-spoke-a \
     --query "[].{Name:name, Remote:remoteVirtualNetwork.id, State:peeringState}" -o json \
     | jq -r '.[] | "\(.Name)  ->  \(.Remote | split("/") | last)  [\(.State)]"'
   ```

   Esperado:

   ```
   spoke-a-to-hub  ->  vnet-hub  [Connected]
   ```

   Un emparejamiento. Nada que apunte a `vnet-spoke-b`.

### Comprobación de comprensión

- **Q31.** Después del paso 4, ¿puede una VM en `vnet-spoke-a` alcanzar a una VM en `vnet-spoke-b`? Indique la propiedad del emparejamiento de VNets que lo decide.
- **Q32.** Nombre dos maneras de hacer que funcione el tráfico spoke-a-spoke en una topología hub-and-spoke.
- **Q33.** El paso 2 produjo `Initiated` en lugar de `Connected`. Explique qué significa ese estado operativamente y cómo se vería una caída real causada por él.
- **Q34.** ¿El tráfico de emparejamiento entre dos VNets de la misma región atraviesa la internet pública? ¿Y entre dos VNets en regiones distintas (emparejamiento global)?
- **Q35.** El emparejamiento no tiene tope de ancho de banda y no agrega ningún dispositivo que induzca latencia. ¿Cómo se factura, y cuál es la consecuencia práctica para un diseño entre regiones?
- **Q36.** En el paso 5, ¿por qué `vm-web-01` no mostró rutas hacia `10.20.0.0/16` aun cuando los emparejamientos están `Connected`?

*Fuente: [Virtual network peering](https://learn.microsoft.com/en-us/azure/virtual-network/virtual-network-peering-overview) · [Hub-and-spoke network topology](https://learn.microsoft.com/en-us/azure/architecture/networking/architecture/hub-spoke)*

---

## Ejercicio 7 — Azure DNS: zonas públicas y zonas privadas

Azure DNS es **hospedaje**, no registro. Las zonas públicas responden a internet; las privadas responden solo a las VNets vinculadas.

### Pasos

1. Cree una zona DNS pública. No necesita ser dueño del dominio para crear la zona — necesita serlo para delegar en ella:

   ```bash
   az network dns zone create -g $RG -n az900lab-$SUFFIX.example --output none

   az network dns zone show -g $RG -n az900lab-$SUFFIX.example \
     --query "{Zone:name, NameServers:nameServers, Records:numberOfRecordSets}" -o json
   ```

   Esperado:

   ```json
   {
     "NameServers": [
       "ns1-04.azure-dns.com.",
       "ns2-04.azure-dns.net.",
       "ns3-04.azure-dns.org.",
       "ns4-04.azure-dns.info."
     ],
     "Records": 2,
     "Zone": "az900lab-4f2a.example"
   }
   ```

   Cuatro servidores de nombres repartidos en cuatro TLD — ese es el diseño de resiliencia.

2. Agregue un registro A y consulte directamente al propio servidor de nombres de Azure:

   ```bash
   az network dns record-set a add-record \
     -g $RG -z az900lab-$SUFFIX.example -n www -a 203.0.113.10 --output none

   NS=$(az network dns zone show -g $RG -n az900lab-$SUFFIX.example --query "nameServers[0]" -o tsv)
   dig @${NS%.} www.az900lab-$SUFFIX.example A +short
   ```

   Esperado:

   ```
   203.0.113.10
   ```

   Ahora consúltelo de la manera normal, sin nombrar el servidor:

   ```bash
   dig www.az900lab-$SUFFIX.example A +short
   ```

   Esperado:

   ```
   (empty)
   ```

3. Cree una zona DNS **privada** y vincúlela a la VNet hub con el registro automático activado:

   ```bash
   az network private-dns zone create -g $RG -n internal.az900.lab --output none

   az network private-dns link vnet create \
     -g $RG -z internal.az900.lab -n link-hub \
     -v vnet-hub -e true --output none

   az network private-dns link vnet list -g $RG -z internal.az900.lab \
     --query "[].{Link:name, Registration:registrationEnabled, State:virtualNetworkLinkState}" -o table
   ```

   Esperado:

   ```
   Link      Registration    State
   --------  --------------  ---------
   link-hub  True            Completed
   ```

4. Agregue un registro manual en la zona privada:

   ```bash
   az network private-dns record-set a add-record \
     -g $RG -z internal.az900.lab -n db01 -a 10.10.2.20 --output none

   az network private-dns record-set list -g $RG -z internal.az900.lab \
     --query "[].{Name:name, Type:type, TTL:ttl}" -o table
   ```

   Esperado:

   ```
   Name    Type                                             TTL
   ------  -----------------------------------------------  -----
   @       Microsoft.Network/privateDnsZones/SOA            3600
   db01    Microsoft.Network/privateDnsZones/A              3600
   ```

5. Desde su estación de trabajo, intente resolver el registro privado:

   ```bash
   dig db01.internal.az900.lab A +short
   ```

   Esperado:

   ```
   (empty)
   ```

### Comprobación de comprensión

- **Q37.** El paso 2 resolvió cuando le preguntó directamente al servidor de nombres de Azure, pero no devolvió nada desde su resolutor normal. ¿Qué único paso falta, y dónde se realiza?
- **Q38.** ¿Puede comprar `contoso.com` en la hoja de Azure DNS? Si no, ¿qué oferta de Azure registra un dominio?
- **Q39.** El paso 3 usó `-e true` (registro habilitado). ¿Qué automatiza ese flag, y cuál es el límite de cuántas VNets de una zona privada pueden tenerlo activado?
- **Q40.** El paso 5 no devolvió nada desde su estación de trabajo, pero una VM dentro de `vnet-hub` sí resolvería `db01`. ¿Qué resolutor usa esa VM, y en qué dirección bien conocida lo expone Azure?
- **Q41.** Dé la razón operativa para usar una zona DNS privada en lugar de editar `/etc/hosts` en cada VM.

*Fuente: [Azure DNS overview](https://learn.microsoft.com/en-us/azure/dns/dns-overview) · [Azure Private DNS overview](https://learn.microsoft.com/en-us/azure/dns/private-dns-overview)*

---

## Ejercicio 8 — Puntos de conexión públicos, privados y Azure Private Link

Este es el objetivo *"definir puntos de conexión públicos y privados"*. Llevará un servicio PaaS de accesible desde internet a accesible solo desde la VNet, y verá cómo cambia el DNS por debajo.

### Pasos

1. Cree una cuenta de almacenamiento. Por defecto su servicio de blobs tiene un **punto de conexión público** con un nombre DNS público:

   ```bash
   az storage account create \
     -g $RG -n stpe${SUFFIX}az900 \
     --sku Standard_LRS --kind StorageV2 \
     --allow-blob-public-access false --output none

   az storage account show -g $RG -n stpe${SUFFIX}az900 \
     --query "{Name:name, Blob:primaryEndpoints.blob, PublicAccess:publicNetworkAccess}" -o json
   ```

   Esperado:

   ```json
   {
     "Blob": "https://stpe4f2aaz900.blob.core.windows.net/",
     "Name": "stpe4f2aaz900",
     "PublicAccess": "Enabled"
   }
   ```

2. Resuelva ese nombre **antes** de que exista ningún punto de conexión privado — registre la respuesta:

   ```bash
   dig stpe${SUFFIX}az900.blob.core.windows.net +short
   ```

   Esperado:

   ```
   blob.bl2prdstr01a.store.core.windows.net.
   20.60.241.129
   ```

   Una IP pública. Cualquiera en internet puede alcanzar este punto de conexión TCP; solo la autorización los detiene.

3. Cree la zona DNS privada que Private Link requiere, y vincúlela a la VNet:

   ```bash
   az network private-dns zone create -g $RG -n privatelink.blob.core.windows.net --output none

   az network private-dns link vnet create \
     -g $RG -z privatelink.blob.core.windows.net \
     -n link-hub-blob -v vnet-hub -e false --output none
   ```

4. Cree el **punto de conexión privado** — una NIC en su subred, con una IP privada, ligada al sub-recurso `blob` de esa cuenta de almacenamiento:

   ```bash
   SA_ID=$(az storage account show -g $RG -n stpe${SUFFIX}az900 --query id -o tsv)

   az network private-endpoint create \
     -g $RG -n pe-blob \
     --vnet-name vnet-hub --subnet snet-data \
     --private-connection-resource-id "$SA_ID" \
     --group-id blob \
     --connection-name pe-blob-conn \
     --output none

   az network private-endpoint show -g $RG -n pe-blob \
     --query "{PE:name, Subnet:subnet.id, IP:customDnsConfigs[0].ipAddresses[0], FQDN:customDnsConfigs[0].fqdn, Status:privateLinkServiceConnections[0].privateLinkServiceConnectionState.status}" -o json
   ```

   Esperado:

   ```json
   {
     "FQDN": "stpe4f2aaz900.blob.core.windows.net",
     "IP": "10.10.2.4",
     "PE": "pe-blob",
     "Status": "Approved",
     "Subnet": ".../virtualNetworks/vnet-hub/subnets/snet-data"
   }
   ```

   `10.10.2.4` — una dirección tomada de `snet-data`, la tercera IP utilizable de la subred.

5. Conecte el punto de conexión con la zona DNS privada para que el nombre resuelva de forma privada dentro de la VNet:

   ```bash
   az network private-endpoint dns-zone-group create \
     -g $RG --endpoint-name pe-blob -n zg-blob \
     --private-dns-zone privatelink.blob.core.windows.net \
     --zone-name blob --output none

   az network private-dns record-set a list -g $RG -z privatelink.blob.core.windows.net \
     --query "[].{Record:name, IP:aRecords[0].ipv4Address}" -o table
   ```

   Esperado:

   ```
   Record          IP
   --------------  ---------
   stpe4f2aaz900   10.10.2.4
   ```

   Azure creó ese registro A automáticamente a partir de la NIC del punto de conexión.

6. Desactive por completo el punto de conexión público:

   ```bash
   az storage account update -g $RG -n stpe${SUFFIX}az900 \
     --public-network-access Disabled --output none

   az storage account show -g $RG -n stpe${SUFFIX}az900 \
     --query "{PublicAccess:publicNetworkAccess, DefaultAction:networkRuleSet.defaultAction}" -o json
   ```

   Esperado:

   ```json
   { "DefaultAction": "Allow", "PublicAccess": "Disabled" }
   ```

7. Compruébelo desde fuera de la VNet:

   ```bash
   az storage container list --account-name stpe${SUFFIX}az900 --auth-mode login -o table
   ```

   Esperado:

   ```
   (AuthorizationFailure) This request is not authorized to perform this operation.
   RequestId: ...
   ```

   o, según el cliente, un fallo a nivel de conexión. Desde internet la puerta está cerrada.

8. Resuelva el nombre desde *dentro* de la VNet y compárelo con el paso 2:

   ```bash
   az ssh vm -g $RG -n vm-web-01 -- "getent hosts stpe${SUFFIX}az900.blob.core.windows.net"
   ```

   > **Nota:** `vm-web-01` vive en su propia VNet `vm-web-01VNET` creada automáticamente, no en `vnet-hub`, así que igual resolverá la IP *pública*. De eso trata la siguiente pregunta. Para ver la respuesta privada, despliegue una VM en `snet-app` (que está dentro de `vnet-hub`) y repita.

### Comprobación de comprensión

- **Q42.** Defina, en una frase cada uno, un **punto de conexión público** y un **punto de conexión privado**.
- **Q43.** En el paso 4 el punto de conexión privado consumió `10.10.2.4` de `snet-data`. ¿Qué tipo de recurso de Azure retiene realmente esa IP, y qué implica eso para el dimensionamiento de la subred cuando despliegue 40 puntos de conexión privados?
- **Q44.** El paso 5 creó un registro A en `privatelink.blob.core.windows.net`, pero las aplicaciones siguen usando `stpe....blob.core.windows.net`. Trace la cadena de resolución DNS que hace que el nombre de aplicación sin modificar devuelva una IP privada dentro de la VNet.
- **Q45.** El paso 8 devolvió una IP pública aunque el punto de conexión privado existe y está `Approved`. ¿Por qué — y cuál es la regla general que esto ilustra sobre el alcance de un punto de conexión privado?
- **Q46.** Distinga un **punto de conexión de servicio** de un **punto de conexión privado**. ¿Cuál le da al recurso PaaS una IP dentro de su espacio de direcciones, y cuál sigue usando la IP pública del servicio?
- **Q47.** Después del paso 6, una organización asociada en otro inquilino necesita acceso de lectura a esta cuenta de almacenamiento a través de una conexión privada. ¿Es posible con Private Link, y qué sugiere el estado `Approved` del paso 4?

*Fuente: [What is Azure Private Link?](https://learn.microsoft.com/en-us/azure/private-link/private-link-overview) · [Private endpoint overview](https://learn.microsoft.com/en-us/azure/private-link/private-endpoint-overview) · [Private endpoint DNS configuration](https://learn.microsoft.com/en-us/azure/private-link/private-endpoint-dns)*

---

## Ejercicio 9 — Conectividad híbrida: VPN Gateway y ExpressRoute (solo lectura)

**No despliegue una puerta de enlace.** Una VPN Gateway tarda 30–45 minutos en aprovisionarse y factura por hora desde el momento en que existe. Todo lo que sigue es inspección gratuita de datos reales de la API.

### Pasos

1. Liste los proveedores de ExpressRoute y las ubicaciones de emparejamiento disponibles para usted. Esta es una consulta en vivo contra el plano de control de Azure:

   ```bash
   az network express-route list-service-providers \
     --query "[?contains(peeringLocations, 'Washington DC')].{Provider:name, Locations:peeringLocations, Bandwidths:bandwidthsOffered[].offerName}" \
     -o json | jq -r '.[] | "\(.Provider): \(.Bandwidths | join(", "))"' | head -10
   ```

   Esperado (abreviado — varía según la región):

   ```
   Equinix: 50Mbps, 100Mbps, 200Mbps, 500Mbps, 1Gbps, 2Gbps, 5Gbps, 10Gbps
   Megaport: 50Mbps, 100Mbps, 200Mbps, 500Mbps, 1Gbps, 2Gbps, 5Gbps, 10Gbps
   Verizon: 50Mbps, 100Mbps, 200Mbps, 500Mbps, 1Gbps, 2Gbps, 5Gbps, 10Gbps
   ```

2. Obtenga precios reales de VPN Gateway desde la API pública de Precios Minoristas — no requiere autenticación:

   ```bash
   curl -s "https://prices.azure.com/api/retail/prices?\$filter=serviceName%20eq%20'VPN%20Gateway'%20and%20armRegionName%20eq%20'eastus'%20and%20priceType%20eq%20'Consumption'" \
     | jq -r '.Items[] | "\(.skuName)\t\(.meterName)\t\(.retailPrice) \(.currencyCode)/\(.unitOfMeasure)"' \
     | sort -u | head -12
   ```

   Esperado (abreviado; los precios cambian):

   ```
   Basic     Basic Gateway       0.036 USD/1 Hour
   VpnGw1    VpnGw1 Gateway      0.19  USD/1 Hour
   VpnGw2    VpnGw2 Gateway      0.49  USD/1 Hour
   VpnGw3    VpnGw3 Gateway      1.25  USD/1 Hour
   VpnGw5    VpnGw5 Gateway      4.10  USD/1 Hour
   ```

3. Haga la aritmética que decide arquitecturas reales:

   ```bash
   echo "VpnGw1 monthly floor: $(echo '0.19 * 730' | bc) USD — before any data transfer"
   ```

   Esperado:

   ```
   VpnGw1 monthly floor: 138.70 USD — before any data transfer
   ```

4. Estudie — **no ejecute** — los comandos que usaría un despliegue real. Note que el nombre de la subred no es una convención, es un requisito estricto:

   ```bash
   # DO NOT RUN — reference only. Provisions in 30-45 min, bills per hour.
   az network vnet subnet create \
     -g $RG --vnet-name vnet-hub -n GatewaySubnet \
     --address-prefixes 10.10.255.0/27

   az network public-ip create -g $RG -n pip-vpngw --sku Standard --allocation-method Static

   az network vnet-gateway create \
     -g $RG -n vpngw-hub \
     --vnet vnet-hub --public-ip-address pip-vpngw \
     --gateway-type Vpn --vpn-type RouteBased \
     --sku VpnGw1 --generation Generation2
   ```

5. Confirme que no existe ninguna puerta de enlace en su grupo de recursos, de modo que no le estén facturando:

   ```bash
   az network vnet-gateway list -g $RG --query "length(@)" -o tsv
   ```

   Esperado:

   ```
   0
   ```

### Comprobación de comprensión

- **Q48.** Indique la diferencia arquitectónica más importante entre una conexión de VPN Gateway sitio a sitio y un circuito ExpressRoute, en términos del camino que toman los paquetes.
- **Q49.** La subred de puerta de enlace del paso 4 se llama `GatewaySubnet`. ¿Qué pasa si en cambio la nombra `snet-gateway`?
- **Q50.** Nombre los tres tipos de conexión de VPN Gateway y, para cada uno, el escenario al que sirve.
- **Q51.** Compare el ancho de banda máximo: VPN Gateway (SKU más alto) frente a un circuito ExpressRoute estándar frente a ExpressRoute Direct.
- **Q52.** Una empresa financiera exige que el tráfico entre su centro de datos y Azure nunca atraviese la internet pública, y necesita un SLA de ancho de banda. ¿Qué opción especifica, y cuál es la única cosa que un circuito ExpressRoute por sí solo *no* les da y que deben agregar por separado?
- **Q53.** Dado el piso de USD 138.70/mes del paso 3 para el SKU de VPN de producción más pequeño, ¿qué le diría a un equipo cuya única necesidad es acceso SSH administrativo a tres VMs?

*Fuente: [VPN Gateway overview](https://learn.microsoft.com/en-us/azure/vpn-gateway/vpn-gateway-about-vpngateways) · [ExpressRoute overview](https://learn.microsoft.com/en-us/azure/expressroute/expressroute-introduction) · [About gateway SKUs](https://learn.microsoft.com/en-us/azure/vpn-gateway/about-gateway-skus)*

---

## Ejercicio 10 — Desmantelamiento (obligatorio)

### Pasos

1. Haga un inventario final de lo que construyó, y anote el conteo:

   ```bash
   az resource list -g $RG --query "length(@)" -o tsv
   az resource list -g $RG --query "[].{Name:name, Type:type, Location:location}" -o table
   ```

2. Elimine el grupo de recursos completo. Todo lo creado en este laboratorio desaparece con él:

   ```bash
   az group delete --name $RG --yes --no-wait
   ```

3. Confirme que el borrado está en marcha:

   ```bash
   az group show -n $RG --query "properties.provisioningState" -o tsv
   ```

   Esperado:

   ```
   Deleting
   ```

   Y unos minutos después:

   ```
   (ResourceGroupNotFound) Resource group 'rg-az900-lab' could not be found.
   ```

4. Verifique que no sobrevivió nada en el ámbito de la suscripción:

   ```bash
   az resource list --query "[?resourceGroup=='rg-az900-lab'] | length(@)" -o tsv
   ```

   Esperado:

   ```
   0
   ```

### Comprobación de comprensión

- **Q54.** Eliminar un solo grupo de recursos quitó una VM, un scale set, una aplicación web, contenedores, VNets, emparejamientos, zonas DNS y un punto de conexión privado. ¿Qué le dice esto sobre el grupo de recursos como construcción organizativa, y cuál es la única barrera de protección que aplicaría en producción para impedir exactamente ese comando?
- **Q55.** Los emparejamientos son dos objetos, uno en cada VNet. Cuando eliminó `vnet-hub`, ¿qué pasó con `spoke-a-to-hub` — que vivía en una VNet que también estaba en el grupo? ¿Cambiaría la respuesta si `vnet-spoke-a` hubiera estado en un grupo de recursos *distinto*?

*Fuente: [Azure Resource Manager overview](https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/overview) · [Lock resources to prevent changes](https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/lock-resources)*

---

<details>
<summary><strong>▶ Respuestas</strong></summary>

### Ejercicio 0

**A1.** No. La ubicación de un grupo de recursos almacena solo los **metadatos** del grupo — el registro de qué recursos le pertenecen. Los recursos que contiene pueden vivir en cualquier región. La ubicación importa por una razón: si el almacén de metadatos de Resource Manager de esa región no está disponible, usted no puede *gestionar* (crear, actualizar, eliminar, etiquetar) recursos de ese grupo, aunque los recursos en sí sigan funcionando normalmente en sus propias regiones.

**A2.** No. Los identificadores de zona de disponibilidad son **lógicos por suscripción**. La zona "1" de su suscripción y la zona "1" de la suscripción de su colega pueden corresponder a centros de datos físicos distintos. Azure expone un mapeo `physicalZone` (`az rest` contra la API `locations` con `ListAvailabilityZoneMappings`) precisamente porque, de lo contrario, comparar números de zona entre suscripciones no significa nada. En la práctica: nunca coordine un despliegue multisuscripción solo por número de zona.

**A3.** No. El emparejamiento de regiones le da (a) mantenimiento escalonado de la plataforma — Azure no actualiza ambas regiones de un par simultáneamente, (b) orden de recuperación priorizado en una caída amplia, y (c) un destino para servicios con georreplicación integrada, como el almacenamiento GRS. **No** replica su VM. La resiliencia de VMs entre regiones requiere un servicio explícito — Azure Site Recovery, o un despliegue activo/activo que usted diseñe.

### Ejercicio 1

**A4.** Se siguen facturando mientras está desasignada: el **disco del sistema operativo**, el **disco de datos** y la **IP pública de SKU Standard** (las IP públicas Standard son estáticas y se facturan estén o no adjuntas). Gratis en cualquier caso: la **VNet**, la **NIC** y el **NSG**. Deja de facturarse: la **computación de la VM** — el cargo por vCPU/RAM, que es la línea más grande. Por eso "desasignar" es el verbo que ahorra costos y "detener" no.

**A5.** `/dev/sda1`, montado en `/mnt` (en Windows, la unidad `D:`). Este es el **disco temporal** — SSD local adjunto al host físico, no un disco administrado. Se borra al desasignar, en el mantenimiento del host, al redimensionar y en cualquier evento de migración en vivo. Úselo solo para swap, scratch y archivos de paginación. Note también que algunas series de VM (`Dv5`, `Ev5`) vienen **sin** disco temporal; las variantes con sufijo `d` (`Ddv5`, `Edv5`) son las que lo tienen.

**A6.** Recibió `10.0.0.0/16` con una subred `10.0.0.0/24` — el valor por defecto de la CLI. El problema es la **colisión de espacios de direcciones**: `10.0.0.0/16` es el CIDR más tipeado del mundo. En el momento en que necesite emparejar esta VNet con la de otro equipo, o con un rango local, la superposición lo bloquea, y el espacio de direcciones de una VNet no se puede cambiar mientras existan recursos con esas IP. Las organizaciones reales asignan bloques CIDR de forma centralizada desde un IPAM antes de crear cualquier VNet.

**A7.** Un apagado desde el sistema operativo invitado deja la VM en estado **Stopped**, no **Stopped (deallocated)**. En `Stopped`, la VM sigue reteniendo su asignación en un host físico — vCPU y RAM reservadas — y Azure continúa facturando computación. Solo `az vm deallocate` (o "Detener" en el portal, que llama a deallocate) libera la asignación del host y detiene el cargo de computación. Efecto secundario que conviene conocer: la desasignación también libera una IP pública *dinámica* y el disco temporal.

**A8.** Los cuatro tipos son **Standard HDD**, **Standard SSD**, **Premium SSD** (y **Premium SSD v2**) y **Ultra Disk**. Para una base de datos sensible a la latencia, elija **Ultra Disk** cuando necesite latencia inferior al milisegundo con IOPS y rendimiento ajustables de forma independiente, o **Premium SSD v2** como el valor moderno por defecto y económico — desacopla la capacidad del rendimiento, a diferencia de Premium SSD v1, donde las IOPS están atadas al tamaño del disco. Note que tener Premium SSD/Ultra en *todos* los discos es además lo que califica a una VM de instancia única para el SLA del 99.9%.

### Ejercicio 2

**A9.** Un **dominio de fallo** es un grupo de hardware que comparte una fuente de alimentación y un switch de red comunes — protege contra un fallo de hardware a nivel de rack. Un **dominio de actualización** es un grupo que Azure reinicia en conjunto durante el mantenimiento planificado de la plataforma — protege contra que toda su flota caiga a la vez durante un parche del sistema operativo del host.

**A10.** Conjunto de disponibilidad: **caído**. Un conjunto de disponibilidad existe enteramente dentro de un único centro de datos; tanto los dominios de fallo como los de actualización son racks dentro de una misma instalación. Zonas de disponibilidad 1 y 2: también **caídas** — las zonas protegen contra el fallo de un centro de datos *dentro* de una región, no contra la pérdida de la región misma. La pérdida regional exige un diseño multirregión.

**A11.** (a) VM única con todos los discos Premium SSD → **99.9%**; (b) dos o más VMs en un conjunto de disponibilidad → **99.95%**; (c) dos o más VMs repartidas en dos zonas de disponibilidad → **99.99%**. (Como contraste: una VM única con Standard SSD es 99.5%, y con Standard HDD 99%.)

**A12.** La orquestación **Uniform** trata a las instancias como clones idénticos gestionados por la plataforma a partir de un modelo — obtiene la escala máxima (hasta 1.000 instancias) y actualizaciones automáticas del sistema operativo, pero las instancias no son objetos VM de primera clase. La orquestación **Flexible** le da recursos `Microsoft.Compute/virtualMachines` reales a los que puede conectarse individualmente, mezclar tamaños dentro del conjunto y gestionar con el instrumental estándar de VM, conservando semánticas de scale set como el escalado automático y la distribución por dominios de fallo. Flexible es el valor por defecto recomendado para despliegues nuevos.

**A13.** Escalado horizontal — **escalar hacia afuera**, agregando instancias. El equivalente vertical sería **redimensionar** el SKU de la VM, por ejemplo `az vmss update --set virtualMachineProfile.hardwareProfile.vmSize=Standard_B2s`, que cambia la capacidad de cada instancia en lugar del número de instancias. El escalado vertical requiere un reinicio y tiene un techo duro en el SKU más grande; el horizontal no.

**A14.** Porque los SLA del 99.95%/99.99% requieren **dos o más instancias**. Un mínimo de 1 permitiría que el escalado automático drenara el conjunto hasta una sola instancia en las horas tranquilas, degradando silenciosamente el despliegue al SLA de VM única justo en el momento en que nadie está mirando. El conteo mínimo de instancias es un control de disponibilidad, no solo un control de costos.

### Ejercicio 3

**A15.** Las **VMs de host de sesión** (computación + discos), cualquier **almacenamiento** para los perfiles de usuario FSLogix, la **salida de red**, y las **licencias de Windows** — que se incluyen sin costo adicional si los usuarios tienen una licencia elegible de Microsoft 365 E3/E5/A3/A5/F3/Business Premium o Windows E3/E5; de lo contrario es un cargo de acceso por usuario. El plano de control de AVD — intermediación, gateway, diagnóstico, grupos de hosts, grupos de aplicaciones, áreas de trabajo — es **gratis**.

**A16.** **Pooled**: muchos usuarios comparten un conjunto de hosts de sesión, cada usuario obtiene el host que elija el balanceador de carga, y las sesiones no son persistentes. Máxima densidad, menor costo por usuario. **Personal**: a cada usuario se le asigna permanentemente un host de sesión dedicado. Lo fuerzan escenarios como desarrolladores que instalan su propio instrumental, cargas de trabajo que requieren derechos de administrador local, estaciones de trabajo GPU/CAD, o cualquier caso regulado donde el software instalado por el usuario deba persistir y ser auditable individualmente.

**A17.** **Windows 11 Enterprise multisesión** y **Windows 10 Enterprise multisesión** — SKU que existen solo para AVD. Windows 11 Pro estándar impone una única sesión interactiva; las ediciones multisesión llevan las licencias y la configuración de kernel que permiten sesiones interactivas concurrentes sobre una misma instancia del sistema operativo, que es lo que hace económicamente viables a los grupos de hosts pooled.

**A18.** En **contenedores de perfil** — archivos VHD/VHDX de FSLogix almacenados en un recurso compartido de red (Azure Files, o Azure NetApp Files para alta escala) y montados al iniciar sesión en el host que le toque al usuario. Esto es lo que hace que hosts no persistentes se sientan persistentes. Guardar datos de usuario en el disco local del host de sesión en un despliegue pooled los pierde en cuanto el host se recicla.

### Ejercicio 4

**A19.** De mayor a menor responsabilidad del cliente: **Máquina virtual (IaaS)** — usted es dueño del sistema operativo, el parcheo, el runtime, el middleware y la aplicación. **Container Instances (PaaS/CaaS)** — usted es dueño de la imagen del contenedor y de la aplicación; Microsoft es dueño del host y del runtime. **App Service (PaaS)** — usted es dueño del código y la configuración de la aplicación; Microsoft es dueño del sistema operativo, el parcheo del runtime y la infraestructura de escalado. **Functions (FaaS/serverless)** — usted es dueño solo del cuerpo de la función y de su enlace de desencadenador. SaaS no aparece aquí; sería una aplicación terminada como Microsoft 365, donde usted es dueño solo de sus datos y sus identidades.

**A20.** Se le factura el **plan**, no la aplicación. El plan es la computación reservada (aquí, una instancia B1 de Linux); las aplicaciones son inquilinos lógicos sobre él. Desplegar cinco aplicaciones más en `plan-az900` no cuesta **nada adicional** — pero ahora las seis compiten por la misma CPU y RAM. Esta es la palanca de costos estándar de App Service y también su trampa estándar del vecino ruidoso.

**A21.** Le pidió la **imagen del contenedor**, los **núcleos de CPU**, la **memoria en GB**, los **puertos** expuestos, una **etiqueta de nombre DNS** opcional y una **política de reinicio**. La facturación es **por segundo**, según los vCPU-segundo y GB-segundo solicitados desde el inicio hasta la detención del contenedor. No hay instancia ociosa que pagar ni host que parchear — lo que hace a ACI ideal para cargas de trabajo de corta vida, con ráfagas o con forma de tarea.

**A22.** La Function App en plan de Consumo es computación sin estado que puede desmantelarse por completo, así que su estado duradero vive en otra parte. La cuenta de almacenamiento contiene: el propio paquete de código de la función (vía `WEBSITE_RUN_FROM_PACKAGE`), los metadatos de desencadenadores y los **blobs de concesión/punto de control** que coordinan qué instancia posee qué partición, el estado de programación de los desencadenadores de temporizador, y el task hub de Durable Functions si se usa. Elimine esa cuenta de almacenamiento y la Function App deja de funcionar.

**A23.** El plan de Consumo tiene un `functionTimeout` por defecto de 5 minutos y un **máximo duro de 10 minutos** — un trabajo de 25 minutos se mata a mitad de ejecución. Soluciones: (1) el **plan Premium** (Elastic Premium), que permite tiempo de espera sin límite además de instancias precalentadas e integración con VNet; (2) el **plan Dedicado (App Service)**, donde la función corre sobre computación que ya paga; (3) mejor arquitectónicamente — descomponer en **Durable Functions**, de modo que cada actividad termine dentro del límite y el orquestador maneje la coordinación de larga duración. (El plan más nuevo **Flex Consumption** también eleva el tiempo de espera conservando el escalado a cero.)

**A24.** **Azure Container Apps.** ACI está mal: no tiene descubrimiento de servicios integrado entre contenedores, ni escalado automático a cero, ni modelo de revisiones/división de tráfico — estaría construyendo un orquestador a mano. AKS funcionaría, pero le entrega al equipo un plano de control de Kubernetes, grupos de nodos, actualizaciones y CNI para operar, que es exactamente lo que excluyeron. Container Apps está construido sobre AKS + KEDA + Dapr + Envoy pero oculta todo eso: ofrece escalado automático por HTTP y por eventos **incluido el escalado a cero**, escalado independiente por aplicación, descubrimiento de servicios integrado y división de tráfico basada en revisiones.

### Ejercicio 5

**A25.** En cada subred de Azure se reservan cinco direcciones: **`x.x.x.0`** — dirección de red; **`x.x.x.1`** — la puerta de enlace predeterminada; **`x.x.x.2`** y **`x.x.x.3`** — reservadas para mapear las IP de Azure DNS dentro del espacio de la VNet; **`x.x.x.255`** (la última dirección del bloque) — dirección de difusión de red. De ahí que un `/24` rinda 251, y no 254 como sugeriría el subneteo clásico.

**A26.** La subred IPv4 más pequeña admitida: **`/29`** (8 direcciones, 3 utilizables tras las 5 reservas). La más grande: **`/2`**. Para 12 VMs necesita ≥ 12 utilizables, así que `/28` da 16 − 5 = 11 → no alcanza; **`/27`** da 32 − 5 = 27 utilizables → esta es la más pequeña que funciona. Note la trampa: la respuesta ingenua `/28` falla precisamente por las cinco reservas de Azure.

**A27.** Postura predeterminada: **todo el tráfico entrante desde fuera de la VNet se deniega**; **todo el tráfico saliente, incluido el destinado a internet, se permite**. El mecanismo es la ordenación por prioridad — las reglas de NSG se evalúan primero por el número de prioridad más bajo, y gana la primera coincidencia. `AllowVnetInBound` (65000) permite el tráfico intra-VNet, `AllowAzureLoadBalancerInBound` (65001) permite los sondeos de estado, y luego `DenyAllInBound` (65500) atrapa todo lo demás. Sus reglas personalizadas usan prioridades 100–4096, así que siempre se evalúan antes que las predeterminadas y pueden anularlas.

**A28.** Un NSG también puede adjuntarse a una **interfaz de red (NIC)**. Cuando ambos existen, el tráfico **entrante** se evalúa **primero en el NSG de la subred y luego en el de la NIC** — el paquete debe ser permitido por ambos. El saliente es al revés: **primero el NSG de la NIC, luego el de la subred**. Por eso una regla "correcta" en la NIC puede quedar silenciosamente bloqueada por una regla de subred, y por eso existe `az network nic list-effective-nsg` — muestra el resultado combinado y realmente aplicado, en lugar de cualquiera de los dos conjuntos de reglas por separado.

**A29.** El **emparejamiento de VNets** se vuelve imposible — Azure rechaza un emparejamiento cuyos espacios de direcciones se superponen, porque el enrutamiento sería ambiguo. También lo es cualquier conexión híbrida donde ambos rangos deban ser alcanzables desde el entorno local. La solución es **redireccionar una de las VNets**, lo que implica volver a desplegar cada recurso que tenga una IP en el rango en conflicto; el espacio de direcciones no puede cambiarse bajo recursos en vivo. La prevención es una gestión centralizada de direcciones IP antes de crear la primera VNet.

**A30.** Una red virtual es un recurso **regional** — está acotada a exactamente una región (y una suscripción). Una subred es una subdivisión de esa VNet y, por lo tanto, tampoco puede abarcar regiones. Una VNet *sí* puede abarcar todas las zonas de disponibilidad de su región, y por eso los despliegues con redundancia de zona comparten una única VNet. Para conectar VNets entre regiones se usa el **emparejamiento global de VNets**.

### Ejercicio 6

**A31.** **No.** El emparejamiento de VNets es **no transitivo**. Spoke-a está emparejado con el hub y spoke-b está emparejado con el hub, pero eso no crea una ruta entre los spokes — el emparejamiento instala rutas únicamente para el espacio de direcciones de la VNet emparejada *directamente*. El tráfico de `10.20.1.0/24` hacia `10.30.1.0/24` no tiene siguiente salto y se descarta.

**A32.** (1) **Emparejamiento directo** entre spoke-a y spoke-b — simple, pero el número de emparejamientos crece como n(n−1)/2 y se vuelve inmanejable pasados unos pocos spokes. (2) **Un dispositivo virtual de red o Azure Firewall en el hub**, combinado con rutas definidas por el usuario (UDR) en cada spoke que apunten el prefijo del otro spoke al dispositivo del hub, más `--allow-forwarded-traffic` en los emparejamientos. Este es el patrón hub-and-spoke estándar y le da un punto central de inspección. (**Azure Virtual WAN** es la versión gestionada de la opción 2.)

**A33.** `Initiated` significa que este lado del emparejamiento existe pero el emparejamiento recíproco en la VNet remota no — es un enlace a medio abrir, y **no fluye tráfico**. Operativamente esta es una caída clásica: un ingeniero crea un emparejamiento, ve "el emparejamiento está ahí" en el portal, y no entiende por qué falla la conectividad. El estado solo pasa a `Connected` cuando ambos objetos de emparejamiento existen y se referencian mutuamente. El mismo modo de fallo aparece como `Disconnected` si alguien luego elimina uno de los lados.

**A34.** Ninguno atraviesa la internet pública. El emparejamiento en la misma región mantiene el tráfico en la **red del centro de datos de Azure**; el emparejamiento global (regiones distintas) lo mantiene en la **red troncal global de Microsoft**. En ambos casos el tráfico es privado, y no interviene ninguna puerta de enlace, dispositivo ni túnel de cifrado. Sin embargo, el tráfico entre VNets emparejadas *no* está cifrado por la plataforma de forma predeterminada — el tráfico de emparejamiento global se cifra en la capa física entre centros de datos de Microsoft, pero si necesita cifrado visible para la aplicación debe proveerlo usted (TLS, o la característica más reciente de cifrado de VNet en los SKU compatibles).

**A35.** Se factura por los **datos transferidos hacia dentro y hacia fuera** de cada VNet emparejada — se cobran ambas direcciones. El emparejamiento dentro de la misma región es barato; el **emparejamiento global (entre regiones) cuesta bastante más por GB**, con tarifas que varían según el par de zonas de las regiones involucradas. Consecuencia: un hub-and-spoke conversador entre regiones puede generar en silencio una factura de ancho de banda importante. Diseñe de modo que el tráfico de alto volumen y sensible a la latencia se quede dentro de una región, y que el tráfico entre regiones tenga forma de plano de control en lugar de plano de datos.

**A36.** Porque `vm-web-01` no está en `vnet-hub`. El Ejercicio 1 creó automáticamente `vm-web-01VNET` (`10.0.0.0/16`) para esa VM, y los emparejamientos que construyó conectan `vnet-hub` con los spokes. Las rutas de emparejamiento se instalan únicamente en las VNets que son parte del emparejamiento. Es exactamente la misma clase de error que en A45 — una característica de red de Azure está acotada a una VNet específica, y los recursos fuera de ella no se ven afectados por más correcta que parezca la configuración en el portal.

### Ejercicio 7

**A37.** La **delegación**. Azure DNS ya es autoritativo para la zona, pero nada en internet lo sabe. Debe ir al **registrador de dominios** donde está registrado el dominio y reemplazar sus registros NS por los cuatro valores de `nameServers` que Azure devolvió en el paso 1. Hasta que esa delegación exista en la zona padre, los resolutores públicos siguen los registros NS viejos y nunca llegan a Azure. Note dónde se hace: en el registrador, *fuera* de Azure.

**A38.** **No** — Azure DNS hospeda zonas y responde consultas; no es un registrador. Para registrar un dominio desde dentro de Azure se usa **App Service Domains** (que registra a través de un registrador asociado y puede crear automáticamente la zona de Azure DNS con la delegación ya configurada). La distinción entre *registrar* un nombre y *hospedar* su zona es una trampa común del examen.

**A39.** Con el registro habilitado, las VMs desplegadas en esa VNet vinculada obtienen sus **registros A creados y eliminados automáticamente** en la zona privada a medida que se crean y se eliminan — sin gestión manual de registros, y los registros obsoletos desaparecen al eliminar la VM. El límite: **solo una VNet por zona DNS privada puede tener habilitado el registro automático**. Se pueden vincular VNets adicionales para *resolución* (`-e false`), que es exactamente lo que hizo en el paso 3 del Ejercicio 8 — esas VNets pueden resolver nombres en la zona pero no registran sus propias VMs en ella.

**A40.** La VM usa el **DNS proporcionado por Azure** (el resolutor recursivo "Azure DNS default"), accesible en la IP virtual bien conocida **`168.63.129.16`**. Esa dirección es una IP especial de la plataforma de Azure, idéntica en cada VNet de cada región, que además presta DHCP, el sondeo de estado para los balanceadores de carga y el canal de comunicación del agente de VM. Cuando una VNet está vinculada a una zona DNS privada, el resolutor en `168.63.129.16` responde por los registros de esa zona; las consultas desde fuera de las VNets vinculadas nunca lo alcanzan.

**A41.** **Escala y corrección ante los cambios.** `/etc/hosts` es un archivo por VM: agregar un servicio significa editar cada VM, y cambiar una IP significa encontrar cada copia obsoleta. Una zona DNS privada es una única fuente autoritativa, consumida automáticamente por cada VNet vinculada, y con el registro automático se mantiene correcta a medida que las VMs aparecen y desaparecen — sin necesidad de una corrida de gestión de configuración. También funciona para servicios que no son VMs en absoluto (puntos de conexión privados, como muestra el Ejercicio 8), donde un `/etc/hosts` en una VM no puede ayudar cuando el cliente es un servicio PaaS.

### Ejercicio 8

**A42.** Un **punto de conexión público** es la dirección IP enrutable públicamente y el nombre DNS de un servicio, accesibles desde cualquier lugar de internet — el acceso se rige solo por autenticación/autorización y por cualquier regla de firewall de IP, no por la ubicación en la red. Un **punto de conexión privado** es una interfaz de red con una **dirección IP privada de una subred de su propia VNet**, que se mapea a una instancia específica de un servicio PaaS mediante Azure Private Link, de modo que el servicio se vuelve accesible como si fuera un recurso dentro de su red.

**A43.** La IP pertenece a una **interfaz de red (`Microsoft.Network/networkInterfaces`)** que Azure crea y adjunta al punto de conexión privado. Cada punto de conexión privado consume exactamente una IP privada de la subred. Así que 40 puntos de conexión privados consumen 40 direcciones además de las 5 reservas de la plataforma — un `/26` (64 direcciones, 59 utilizables) es cómodo; un `/27` (27 utilizables) no. El dimensionamiento de las subredes para puntos de conexión privados debe planificarse contra el *número de servicios PaaS*, no contra el número de VMs, y la subred no puede agrandarse una vez que los vecinos ocupan el espacio adyacente.

**A44.** La cadena: la aplicación resuelve `stpe....blob.core.windows.net`; el DNS público de Azure devuelve un **CNAME** que apunta a `stpe....privatelink.blob.core.windows.net`. Fuera de la VNet, ese nombre resuelve más adelante a través del DNS público hacia la IP pública del servicio. Dentro de la VNet, la **zona DNS privada vinculada `privatelink.blob.core.windows.net`** es autoritativa para ese sufijo, así que el resolutor en `168.63.129.16` responde con el registro A que creó el grupo de zonas DNS — `10.10.2.4`. La cadena de conexión de la aplicación nunca cambia; solo cambia la respuesta, y cambia según *desde dónde proviene la consulta*. Esta indirección CNAME-a-privatelink es todo el mecanismo, y el DNS mal configurado es la causa número uno de puntos de conexión privados rotos.

**A45.** Porque `vm-web-01` vive en `vm-web-01VNET`, no en `vnet-hub`, y solo `vnet-hub` está vinculada a la zona DNS privada `privatelink.blob.core.windows.net`. La regla general: **la IP privada de un punto de conexión privado es accesible, y su respuesta DNS privada se sirve, únicamente desde redes que tengan una ruta hacia esa subred y un vínculo con esa zona DNS** — la VNet que contiene el punto de conexión, las VNets emparejadas con ella, y las redes locales conectadas por VPN/ExpressRoute con reenvío de DNS configurado. Crear un punto de conexión privado no lo vuelve visible globalmente; usted debe extender tanto el *enrutamiento* como el *DNS* a cada red que lo necesite.

**A46.** Un **punto de conexión de servicio** extiende la identidad de su VNet hacia el servicio PaaS por la red troncal de Azure: el tráfico sale de su subred, se mantiene fuera de la internet pública, y el servicio lo ve llegar desde una VNet/subred conocida — pero el destino sigue siendo la **IP pública** del servicio, y el servicio sigue teniendo un punto de conexión público. Un **punto de conexión privado** asigna una IP **dentro de su espacio de direcciones** y le permite deshabilitar el punto de conexión público por completo. Otras diferencias que importan: los puntos de conexión de servicio son gratuitos, son por servicio y no funcionan desde el entorno local; los puntos de conexión privados cuestan dinero, son por *instancia de recurso* y por sub-recurso (`blob` vs `file` vs `table` son puntos de conexión separados), y *sí* funcionan desde el entorno local sobre VPN/ExpressRoute. El punto de conexión privado es la dirección que Microsoft recomienda para diseños nuevos.

**A47.** **Sí** — este es un escenario de primera clase de Private Link. El socio crea un punto de conexión privado en *su* VNet, en *su* inquilino, apuntando a la cuenta de almacenamiento de usted por ID de recurso (o por alias). Como es entre inquilinos, la conexión llega en estado `Pending` y **usted debe aprobarla explícitamente** (`az network private-endpoint-connection approve`). Eso es lo que mostraba el estado `Approved` del paso 4: su propio punto de conexión se aprobó automáticamente porque tenía permiso de escritura sobre la cuenta de almacenamiento. El flujo de aprobación es la frontera de seguridad que hace seguro a Private Link entre inquilinos — el consumidor puede solicitar, pero solo el dueño del recurso puede conceder.

### Ejercicio 9

**A48.** La **VPN Gateway** construye un túnel IPsec/IKE cifrado **sobre la internet pública** — los paquetes atraviesan redes de ISP, protegidos por cifrado, con latencia de mejor esfuerzo y sin garantía de ancho de banda. **ExpressRoute** es un **circuito privado a través de un proveedor de conectividad directamente hacia la red global de Microsoft** — los paquetes nunca tocan la internet pública, y el circuito lleva un compromiso de ancho de banda y un SLA de disponibilidad.

**A49.** La creación de la puerta de enlace **falla**. `GatewaySubnet` es un nombre reservado y sensible a mayúsculas que Azure Resource Manager compara literalmente; el servicio de puerta de enlace VPN/ExpressRoute no se desplegará en una subred con ningún otro nombre. Dos restricciones adicionales: no adjunte un NSG a `GatewaySubnet` (rompe el tráfico de plano de control de la puerta de enlace), y dimensiónela con al menos `/27` (`/29` es el mínimo absoluto, pero no deja lugar para la coexistencia con ExpressRoute ni para futuras características de la puerta de enlace).

**A50.** (1) **Sitio a sitio (S2S)** — conecta una red local completa a una VNet mediante un dispositivo VPN local con una IP pública; el patrón estándar de centro de datos híbrido. (2) **Punto a sitio (P2S)** — conecta una máquina cliente individual a una VNet, sin necesidad de dispositivo local; para desarrolladores y administradores remotos. (3) **VNet a VNet** — conecta dos VNets a través de sus puertas de enlace; en gran medida reemplazado por el emparejamiento de VNets, que es más rápido y barato, pero sigue siendo relevante cuando las VNets están en suscripciones/inquilinos distintos con restricciones organizativas, o cuando se busca específicamente un túnel cifrado.

**A51.** **VPN Gateway**: hasta **10 Gbps** agregados en el SKU más alto (VpnGw5/VpnGw5AZ), aunque un único túnel IPsec está topeado bastante por debajo de eso — alrededor de 1–1.25 Gbps — así que alcanzar el agregado requiere múltiples túneles. **Circuito ExpressRoute estándar**: **50 Mbps a 10 Gbps**, aprovisionado como ancho de banda comprometido fijo. **ExpressRoute Direct**: pares de puertos de **10 Gbps o 100 Gbps**, conectando directamente a la red de Microsoft sin un proveedor de servicios en el camino.

**A52.** Especifique **ExpressRoute** — es la única opción que cumple "nunca atraviesa la internet pública" más un SLA de ancho de banda. Lo que no les da es **cifrado**. Un circuito ExpressRoute es privado pero no está cifrado en la capa IP; un circuito privado no es lo mismo que uno confidencial. Si el requisito de cumplimiento incluye cifrado en tránsito, agregue **MACsec** sobre ExpressRoute Direct (capa 2), o un **túnel VPN sitio a sitio corriendo sobre el emparejamiento privado de ExpressRoute** (capa 3). Una segunda respuesta común: ExpressRoute por sí solo es un punto único de fallo salvo que se aprovisione un circuito redundante o se configure una VPN Gateway como camino de conmutación por error documentado.

**A53.** No despliegue una puerta de enlace. Para acceso administrativo a un puñado de VMs, use **Azure Bastion** (gestionado, RDP-SSH por navegador o nativo sobre TLS, sin IP pública en las VMs, aproximadamente USD 0.19/hora para el SKU Basic más los datos salientes — y elimina las IP públicas, lo cual es una mejora de seguridad, no solo de costo) o, aún más barato, **VPN punto a sitio** sobre una puerta de enlace Basic si realmente hace falta un túnel completo. Mejor todavía: pregunte si el SSH interactivo es necesario siquiera: `az ssh`/Run Command, Azure Automation y las canalizaciones de despliegue con imágenes inmutables eliminan el requisito en lugar de pagar USD 1.664/año para satisfacerlo. El principio general: una puerta de enlace sitio a sitio se justifica por la integración de *red* — alcanzar muchos recursos privados desde muchos clientes locales — no por el acceso administrativo a unos pocos hosts.

### Ejercicio 10

**A54.** El grupo de recursos es el **límite de ciclo de vida y de gestión** en Azure Resource Manager: los recursos agrupados están pensados para crearse, actualizarse, permisarse y destruirse como una unidad. Eliminar el grupo es una operación única e irrecuperable sobre cada recurso que contiene, sin importar el tipo ni la región. La barrera de protección de producción es un **bloqueo de recursos** — `az lock create --lock-type CanNotDelete` (o `ReadOnly`) en el ámbito del grupo de recursos, que hace que el borrado sea rechazado hasta que alguien con permiso `Microsoft.Authorization/locks/delete` lo quite explícitamente. Los bloqueos se heredan a los recursos hijos y aplican a *todos* los usuarios, incluidos los propietarios de la suscripción, y ese es exactamente el punto: defienden contra acciones autorizadas pero equivocadas, cosa que RBAC por diseño no hace. Combínelo con **Azure Policy** para prevención a escala y con pasos de canalización conscientes de **deleteLock**, de modo que la automatización no pelee contra la barrera.

**A55.** Cuando eliminó el grupo de recursos, tanto `vnet-hub` como `vnet-spoke-a` estaban dentro de él, así que ambas VNets y ambos objetos de emparejamiento se eliminaron juntos. Si `vnet-spoke-a` hubiera estado en un **grupo de recursos distinto**, eliminar el grupo de `vnet-hub` habría destruido `vnet-hub` y su emparejamiento `hub-to-spoke-a`, mientras que `spoke-a-to-hub` habría sobrevivido como un **emparejamiento huérfano en estado `Disconnected`** — apuntando a una VNet que ya no existe. Se queda ahí, no funcional, hasta que se elimine explícitamente. Este es un riesgo real de limpieza en infraestructuras hub-and-spoke donde el hub y los spokes están deliberadamente en grupos de recursos separados (o suscripciones separadas) por razones de RBAC: eliminar un lado deja configuración visible pero muerta en el otro.

</details>

---

## Referencias

Todas las URL verificadas contra la documentación oficial de Microsoft Learn.

- AZ-900 study guide — https://learn.microsoft.com/en-us/credentials/certifications/resources/study-guides/az-900
- Virtual machines in Azure — https://learn.microsoft.com/en-us/azure/virtual-machines/overview
- Azure managed disk types — https://learn.microsoft.com/en-us/azure/virtual-machines/disks-types
- States and billing status of Azure VMs — https://learn.microsoft.com/en-us/azure/virtual-machines/states-billing
- Availability options for Azure VMs — https://learn.microsoft.com/en-us/azure/virtual-machines/availability
- Virtual Machine Scale Sets overview — https://learn.microsoft.com/en-us/azure/virtual-machine-scale-sets/overview
- Regions and availability zones — https://learn.microsoft.com/en-us/azure/reliability/availability-zones-overview
- Azure region pairs — https://learn.microsoft.com/en-us/azure/reliability/regions-paired
- What is Azure Virtual Desktop? — https://learn.microsoft.com/en-us/azure/virtual-desktop/overview
- App Service overview — https://learn.microsoft.com/en-us/azure/app-service/overview
- Container Instances overview — https://learn.microsoft.com/en-us/azure/container-instances/container-instances-overview
- Azure Container Apps overview — https://learn.microsoft.com/en-us/azure/container-apps/overview
- Azure Functions scale and hosting — https://learn.microsoft.com/en-us/azure/azure-functions/functions-scale
- Azure Virtual Network overview — https://learn.microsoft.com/en-us/azure/virtual-network/virtual-networks-overview
- Network security groups — https://learn.microsoft.com/en-us/azure/virtual-network/network-security-groups-overview
- Virtual network peering — https://learn.microsoft.com/en-us/azure/virtual-network/virtual-network-peering-overview
- Hub-and-spoke network topology — https://learn.microsoft.com/en-us/azure/architecture/networking/architecture/hub-spoke
- Azure DNS overview — https://learn.microsoft.com/en-us/azure/dns/dns-overview
- Azure Private DNS overview — https://learn.microsoft.com/en-us/azure/dns/private-dns-overview
- What is Azure Private Link? — https://learn.microsoft.com/en-us/azure/private-link/private-link-overview
- Private endpoint overview — https://learn.microsoft.com/en-us/azure/private-link/private-endpoint-overview
- Private endpoint DNS configuration — https://learn.microsoft.com/en-us/azure/private-link/private-endpoint-dns
- VPN Gateway overview — https://learn.microsoft.com/en-us/azure/vpn-gateway/vpn-gateway-about-vpngateways
- About VPN Gateway SKUs — https://learn.microsoft.com/en-us/azure/vpn-gateway/about-gateway-skus
- ExpressRoute overview — https://learn.microsoft.com/en-us/azure/expressroute/expressroute-introduction
- Azure Bastion overview — https://learn.microsoft.com/en-us/azure/bastion/bastion-overview
- Azure Resource Manager overview — https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/overview
- Lock resources to prevent changes — https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/lock-resources
- Azure Retail Prices API — https://learn.microsoft.com/en-us/rest/api/cost-management/retail-prices/azure-retail-prices