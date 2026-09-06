# AZ-900 · Tema 1.1 — Describir la informática en la nube
## Ejercicios guiados (cuaderno de laboratorio práctico)

**Peso en el examen:** 9.4 · **Versión del temario:** 2026-07-20
**Habilidades cubiertas:** definir la informática en la nube · modelo de responsabilidad compartida · modelos de nube pública / privada / híbrida y sus casos de uso · modelo basado en consumo · comparación de modelos de precios en la nube.

---

## Antes de empezar

**Lo que necesitás**

| Requisito | Notas |
|---|---|
| Azure CLI ≥ 2.60 | `az version` |
| `jq`, `curl`, `python3` | usados en los laboratorios de precios |
| Una suscripción de Azure | Owner o Contributor sobre al menos un grupo de recursos |
| ~USD 1–3 de gasto | si completás el desmantelamiento en la misma sesión |

> **Resguardo de costo.** Los bloques 1–4 crean recursos facturables. Todos los recursos viven en **un único grupo de recursos** para que el bloque 7 (desmantelamiento) los elimine todos con un solo comando. Los bloques 5 y 6 usan la **Azure Retail Prices API**, que es anónima y gratuita — podés hacerlos sin ninguna suscripción.

**Convención usada en cada bloque:** los comandos se muestran exactamente como los tipeás; el bloque que sigue es la salida *representativa*. Los precios, la cantidad de regiones, las cuotas y las versiones de kernel cambian — tus valores van a ser distintos. El ejercicio trata sobre **la forma y las relaciones**, nunca sobre hacer coincidir un número.

---

## Bloque 0 — Entorno y el resguardo de costo

1. Confirmá tus herramientas e identificá la suscripción en la que estás por gastar dinero.

   ```bash
   az version --output json | jq '{cli: ."azure-cli", core: ."azure-cli-core"}'
   az login --output none
   az account show --output table
   ```

   ```
   EnvironmentName    HomeTenantId                          IsDefault    Name                State    TenantId
   -----------------  ------------------------------------  -----------  ------------------  -------  ------------------------------------
   AzureCloud         3f1e...c02a                            True         Visual Studio Pro   Enabled  3f1e...c02a
   ```

2. Fijá los identificadores que vas a reutilizar. **No** te saltees este paso — todos los bloques posteriores asumen estas variables.

   ```bash
   export SUB_ID=$(az account show --query id -o tsv)
   export LOCATION=eastus
   export RG=rg-az900-t11
   echo "sub=$SUB_ID region=$LOCATION rg=$RG"
   ```

3. Creá el contenedor único de radio de impacto, etiquetado para que un reporte de costos pueda atribuir cada dólar a este laboratorio.

   ```bash
   az group create --name "$RG" --location "$LOCATION" \
     --tags course=az-900 topic=1.1 lifecycle=ephemeral -o table
   ```

   ```
   Location    Name
   ----------  -------------
   eastus      rg-az900-t11
   ```

4. Inspeccioná la *jerarquía de ámbitos de administración* en la que acabás de escribir. Esta jerarquía es el mismo modelo de objetos que después gobierna costo, directivas y acceso.

   ```bash
   az account management-group list -o table 2>/dev/null || echo "no management groups visible"
   echo "/subscriptions/$SUB_ID/resourceGroups/$RG"
   ```

   ```
   /subscriptions/8c3a1d5e-11b2-4d7f-9a0e-5f6c2b8e4a11/resourceGroups/rg-az900-t11
   ```

5. Registrá la línea base de gasto actual para que el bloque 4 tenga algo con qué comparar.

   ```bash
   az consumption budget list -o table 2>/dev/null || echo "budget API not available on this offer"
   ```

### Punto de control — Bloque 0

**P1.** La cadena de ámbito del paso 4 tiene cuatro segmentos. ¿Cuál de ellos es la *unidad más pequeña en la que podés aplicar simultáneamente una Azure Policy, una asignación de rol RBAC y un presupuesto de costos*, y por qué eso importa en un laboratorio?

**P2.** Creaste el grupo de recursos con `lifecycle=ephemeral`. Las etiquetas no cuestan nada y no cambian el comportamiento. En un modelo de facturación basado en consumo, ¿qué capacidad operativa concreta habilitan que sería imposible sin ellas?

**P3.** Verdadero o falso: eliminar el grupo de recursos de la suscripción elimina todo el historial de costos de los recursos que contenía. Justificá.

---

## Bloque 1 — Qué compra realmente la "informática en la nube": autoservicio, elasticidad, capacidad medida

La informática en la nube es la **entrega de servicios de computación a través de internet**. Esa definición es inerte hasta que medís las tres propiedades que la distinguen de un rack en un armario: *tiempo de aprovisionamiento*, *elasticidad bidireccional* y *el límite donde "ilimitado" deja de ser verdad*.

1. Medí la latencia de aprovisionamiento de una única unidad de cómputo. Tomale el tiempo.

   ```bash
   time az vm create -g "$RG" -n vm-t11-a \
     --image Ubuntu2204 --size Standard_B1s \
     --admin-username azureuser --generate-ssh-keys \
     --public-ip-sku Standard --nsg-rule SSH -o none
   ```

   ```
   real    1m14.822s
   user    0m2.905s
   sys     0m0.361s
   ```

2. Mirá lo que un solo `az vm create` produjo realmente. Una "máquina virtual" no es un único recurso.

   ```bash
   az resource list -g "$RG" --query "[].{name:name, type:type}" -o table
   ```

   ```
   Name              Type
   ----------------  -----------------------------------------
   vm-t11-a          Microsoft.Compute/virtualMachines
   vm-t11-aVNET      Microsoft.Network/virtualNetworks
   vm-t11-aNSG       Microsoft.Network/networkSecurityGroups
   vm-t11-aPublicIP  Microsoft.Network/publicIPAddresses
   vm-t11-aVMNic     Microsoft.Network/networkInterfaces
   vm-t11-a_disk1_…  Microsoft.Compute/disks
   ```

3. Demostrá la **elasticidad horizontal** con un conjunto de escalado. El flag `--load-balancer ""` suprime el Standard Load Balancer, que si no facturaría por hora en un laboratorio donde no lo necesitás.

   ```bash
   az vmss create -g "$RG" -n vmss-t11 \
     --image Ubuntu2204 --vm-sku Standard_B1s \
     --orchestration-mode Uniform --instance-count 2 \
     --admin-username azureuser --generate-ssh-keys \
     --load-balancer "" --upgrade-policy-mode automatic -o none

   time az vmss scale -g "$RG" -n vmss-t11 --new-capacity 6 -o none
   az vmss list-instances -g "$RG" -n vmss-t11 --query "[].{id:instanceId, state:provisioningState}" -o table
   ```

   ```
   real    1m58.311s

   Id    State
   ----  ---------
   0     Succeeded
   1     Succeeded
   2     Succeeded
   3     Succeeded
   4     Succeeded
   5     Succeeded
   ```

4. Ahora demostrá que la elasticidad es **bidireccional** — la mitad de la definición que la capacidad on-premises no puede satisfacer en absoluto.

   ```bash
   time az vmss scale -g "$RG" -n vmss-t11 --new-capacity 0 -o none
   az vmss show -g "$RG" -n vmss-t11 --query "sku.capacity"
   ```

   ```
   real    0m41.507s
   0
   ```

5. Demostrá el **escalado vertical** y su costo: no está libre de interrupciones.

   ```bash
   az vm show -g "$RG" -n vm-t11-a --query hardwareProfile.vmSize -o tsv
   az vm resize -g "$RG" -n vm-t11-a --size Standard_B2s -o none
   az vm show -g "$RG" -n vm-t11-a --query hardwareProfile.vmSize -o tsv
   az vm get-instance-view -g "$RG" -n vm-t11-a \
     --query "instanceView.statuses[?starts_with(code,'PowerState')].code" -o tsv
   ```

   ```
   Standard_B1s
   Standard_B2s
   PowerState/running
   ```

6. Encontrá dónde termina la "capacidad infinita". Esta es la propiedad de la informática en la nube que más comúnmente se enuncia mal.

   ```bash
   az vm list-usage --location "$LOCATION" -o table | head -8
   ```

   ```
   Name                              CurrentValue    Limit
   --------------------------------  --------------  -------
   Availability Sets                 0               2500
   Total Regional vCPUs              2               10
   Virtual Machines                  1               25000
   Virtual Machine Scale Sets        1               2500
   Standard BS Family vCPUs          2               10
   Standard DSv5 Family vCPUs        0               0
   ```

7. Fijate en la última línea. Leela con atención, después intentá exceder una cuota deliberadamente y observá el modo de fallo.

   ```bash
   az vmss scale -g "$RG" -n vmss-t11 --new-capacity 40 2>&1 | head -4
   ```

   ```
   (OperationNotAllowed) Operation could not be completed as it results in exceeding
   approved Total Regional Cores quota. Additional required: 38, (Minimum) New Limit
   Required: 40. Submit a request for Quota increase ...
   ```

   ```bash
   az vmss scale -g "$RG" -n vmss-t11 --new-capacity 0 -o none   # restore
   ```

### Punto de control — Bloque 1

**P4.** El paso 1 tardó ~75 segundos. El paso 4 tardó ~41 segundos en liberar seis máquinas. Nombrá las dos características distintas de la nube que estas dos mediciones demuestran, e indicá cuál de las dos también puede reclamar un centro de datos on-premises sobreaprovisionado.

**P5.** El paso 2 muestra seis recursos creados por un solo comando. Cuando el examen dice que la informática en la nube elimina la necesidad de "administrar infraestructura física", ¿cuáles de esos seis tuviste que definir igual, y qué te dice eso sobre dónde se ubica el límite de la abstracción en IaaS?

**P6.** En el paso 6, `Standard DSv5 Family vCPUs` muestra un límite de `0` mientras que `Virtual Machines` muestra `25000`. Explicá en una oración por qué ambos números son verdaderos al mismo tiempo, y qué se equivocaría un estudiante que cree que "la nube tiene capacidad ilimitada".

**P7.** El paso 5 redimensionó `B1s → B2s` mientras la VM seguía en `PowerState/running`. ¿Bajo qué condición el mismo comando habría requerido desasignar la VM primero? (Pensá en qué respalda físicamente un tamaño de VM.)

---

## Bloque 2 — El modelo de responsabilidad compartida, demostrado modelo de servicio por modelo de servicio

El modelo no es un eslogan; es observable. **Todo lo que podés configurar a través de la API es tu responsabilidad. Todo lo que no tiene perilla, lo posee el proveedor.** Usá esa regla para derivar la tabla entera experimentalmente.

### 2a — IaaS: vos sos dueño del sistema operativo

1. Metete dentro del SO invitado. Si podés leer la versión del kernel, sos dueño de su nivel de parches.

   ```bash
   az vm run-command invoke -g "$RG" -n vm-t11-a \
     --command-id RunShellScript \
     --scripts "uname -r; grep PRETTY /etc/os-release; apt list --upgradable 2>/dev/null | wc -l" \
     --query "value[0].message" -o tsv
   ```

   ```
   Enable succeeded:
   [stdout]
   6.8.0-1021-azure
   PRETTY_NAME="Ubuntu 22.04.5 LTS"
   37

   [stderr]
   ```

2. Confirmá que la orquestación de parches es un **ajuste elegido por el cliente**, no un valor por defecto de la plataforma.

   ```bash
   az vm show -g "$RG" -n vm-t11-a --query "osProfile.linuxConfiguration.patchSettings" -o json
   ```

   ```json
   {
     "assessmentMode": "ImageDefault",
     "automaticByPlatformSettings": null,
     "patchMode": "ImageDefault"
   }
   ```

3. Devolvele parte de esa responsabilidad a Microsoft — y observá que esto es un acto explícito y auditable.

   ```bash
   az vm update -g "$RG" -n vm-t11-a \
     --set osProfile.linuxConfiguration.patchSettings.patchMode=AutomaticByPlatform \
           osProfile.linuxConfiguration.patchSettings.assessmentMode=AutomaticByPlatform \
     -o none
   az vm show -g "$RG" -n vm-t11-a --query "osProfile.linuxConfiguration.patchSettings" -o json
   ```

   ```json
   {
     "assessmentMode": "AutomaticByPlatform",
     "automaticByPlatformSettings": null,
     "patchMode": "AutomaticByPlatform"
   }
   ```

4. Ahora intentá llegar un nivel más abajo — el hipervisor y el host físico.

   ```bash
   az vm show -g "$RG" -n vm-t11-a -o json | jq 'paths(scalars) | join(".")' \
     | grep -iE "host|hypervisor|firmware|rack" || echo "no host-level property exposed"
   ```

   ```
   "virtualMachineScaleSet"
   no host-level property exposed
   ```

### 2b — PaaS: sos dueño de la versión del runtime, no del runtime

5. Aprovisioná una plataforma de aplicaciones PaaS. Notá que nunca elegiste una imagen de sistema operativo.

   ```bash
   export APP="app-t11-$RANDOM"
   az appservice plan create -g "$RG" -n plan-t11 --is-linux --sku B1 -o none
   az webapp create -g "$RG" -p plan-t11 -n "$APP" --runtime "PYTHON:3.12" -o none
   az webapp show -g "$RG" -n "$APP" --query "{name:name, state:state, host:defaultHostName}" -o table
   ```

   ```
   Name             State    Host
   ---------------  -------  --------------------------------
   app-t11-24817    Running  app-t11-24817.azurewebsites.net
   ```

6. Enumerá las perillas que *sí* tenés. Estas son tus responsabilidades.

   ```bash
   az webapp config show -g "$RG" -n "$APP" \
     --query "{runtime:linuxFxVersion, alwaysOn:alwaysOn, minTls:minTlsVersion, ftps:ftpsState, http20:http20Enabled}" -o json
   ```

   ```json
   {
     "alwaysOn": false,
     "ftps": "FtpsOnly",
     "http20": false,
     "minTls": "1.2",
     "runtime": "PYTHON|3.12"
   }
   ```

7. Buscá las perillas que **no** tenés. La ausencia es la lección — ejecutá esto y leé el resultado vacío como dato, no como error.

   ```bash
   az webapp config show -g "$RG" -n "$APP" -o json \
     | jq -r 'paths(scalars) | join(".")' \
     | grep -iE "kernel|hostos|patch|hypervisor" || echo "NO host/OS/patch property exists on a Web App"
   ```

   ```
   NO host/OS/patch property exists on a Web App
   ```

8. Cuantificá la superficie de responsabilidad. Contá los recursos que ahora tenés que operar para cada modelo.

   ```bash
   az resource list -g "$RG" --query "[?contains(type,'Compute') || contains(type,'Network')] | length(@)"
   az resource list -g "$RG" --query "[?contains(type,'Web')] | length(@)"
   ```

   ```
   8
   2
   ```

### 2c — SaaS y los invariantes

9. Identificá las dos cosas que poseés en **todos** los modelos, incluido SaaS, donde no existe ninguna API de infraestructura.

   ```bash
   az ad signed-in-user show --query "{identity:userPrincipalName, objectId:id}" -o json
   ```

   ```json
   {
     "identity": "student@contoso.onmicrosoft.com",
     "objectId": "b41f7d92-8e3c-4a55-9c10-0d7a2f6b1e88"
   }
   ```

10. Completá la tabla canónica a partir de lo que acabás de observar. Llená cada celda con **C** (cliente), **M** (Microsoft) o **S** (compartida). Hacelo antes de leer las respuestas.

    | Capa | On-prem | IaaS | PaaS | SaaS |
    |---|---|---|---|---|
    | Información y datos | | | | |
    | Dispositivos (móviles y PCs) | | | | |
    | Cuentas e identidades | | | | |
    | Infraestructura de identidad y directorio | | | | |
    | Aplicaciones | | | | |
    | Controles de red | | | | |
    | Sistema operativo | | | | |
    | Hosts físicos | | | | |
    | Red física | | | | |
    | Centro de datos físico | | | | |

### Punto de control — Bloque 2

**P8.** En el paso 3 configuraste `patchMode=AutomaticByPlatform`. ¿Se transfirió a Microsoft la responsabilidad del parcheo del SO? Respondé con precisión, distinguiendo *ejecución* de *rendición de cuentas*.

**P9.** El paso 7 no devolvió nada. Escribí la regla general que te permite inferir un límite de responsabilidad a partir de una superficie de API, e indicá un caso en el que la regla resulta engañosa.

**P10.** El paso 8 contó 8 contra 2 recursos. Un colega concluye "PaaS es cuatro veces menos trabajo". Dá el contraargumento más fuerte que siga siendo consistente con el modelo de responsabilidad compartida.

**P11.** Tres filas de la tabla del paso 10 tienen el mismo valor en las cuatro columnas. Nombralas y explicá por qué el modelo está construido de modo que esas tres nunca puedan pasar al proveedor.

---

## Bloque 3 — Pública, privada e híbrida: ubicar el plano de control

La variable que distingue no es "dónde está el hardware". Es **quién posee el hardware y quién más lo comparte**. Azure te deja observar las tres posturas a través de una sola API.

1. **Nube pública** — multiinquilino, propiedad del proveedor, distribuida globalmente. Contá lo que eso significa.

   ```bash
   az account list-locations --query "[?metadata.regionType=='Physical'] | length(@)"
   az account list-locations \
     --query "[?metadata.regionType=='Physical'].{region:name, geography:metadata.geographyGroup, paired:metadata.pairedRegion[0].name}" \
     -o table | head -8
   ```

   ```
   64

   Region              Geography       Paired
   ------------------  --------------  ------------------
   eastus              US              westus
   eastus2             US              centralus
   southcentralus      US              northcentralus
   westeurope          Europe          northeurope
   northeurope         Europe          westeurope
   japaneast           Asia Pacific    japanwest
   brazilsouth         South America   southcentralus
   ```

2. Confirmá la redundancia física dentro de una región — evidencia de una escala que ningún inquilino individual financia.

   ```bash
   az vm list-skus --location "$LOCATION" --size Standard_D2s_v5 --resource-type virtualMachines \
     --query "[0].locationInfo[0].zones" -o tsv | tr '\n' ' '
   ```

   ```
   1 2 3
   ```

3. **Nube privada** — hardware de un solo inquilino, propiedad del cliente o del socio. En Azure la línea de productos es **Azure Local** (antes Azure Stack HCI) y **Azure Stack Hub**. No podés aprovisionar una en un laboratorio, pero sí podés inspeccionar el contrato ARM que la gobierna.

   ```bash
   az provider show -n Microsoft.AzureStackHCI --query "{namespace:namespace, state:registrationState}" -o table
   az provider show -n Microsoft.AzureStackHCI --query "resourceTypes[].resourceType" -o tsv | head -6
   ```

   ```
   Namespace                 State
   ------------------------  -------------
   Microsoft.AzureStackHCI   NotRegistered

   clusters
   clusters/arcSettings
   clusters/deploymentSettings
   clusters/updates
   edgeDevices
   galleryImages
   ```

4. **Nube híbrida** — las dos anteriores, unidas por un solo plano de control. Ese plano de control es **Azure Arc**. Registralo y mirá el tipo de recurso que introduce.

   ```bash
   az provider register --namespace Microsoft.HybridCompute --wait
   az extension add --name connectedmachine --upgrade -o none
   az provider show -n Microsoft.HybridCompute \
     --query "resourceTypes[?resourceType=='machines'].{type:resourceType, regions:length(locations)}" -o table
   az connectedmachine list -o table
   ```

   ```
   Type      Regions
   --------  ---------
   machines  38

   ```

5. Leé correctamente el resultado vacío del paso 4: no tenés máquinas habilitadas para Arc, pero el *contrato de la API ya existe en tu suscripción*. Compará los dos tipos de recurso de cómputo lado a lado.

   ```bash
   for NS in Microsoft.Compute/virtualMachines Microsoft.HybridCompute/machines; do
     echo "$NS"
   done
   ```

   ```
   Microsoft.Compute/virtualMachines     -> Azure-hosted, Microsoft-owned hardware
   Microsoft.HybridCompute/machines      -> anywhere (on-prem, another cloud), customer-owned hardware
   ```

6. Demostrá el beneficio operativo de la híbrida: **una consulta, todo el patrimonio**. Azure Resource Graph lee recursos nativos de Azure y proyectados por Arc a través del mismo índice.

   ```bash
   az extension add --name resource-graph --upgrade -o none
   az graph query -q "Resources | summarize count() by type | order by count_ desc | limit 8" \
     --query "data" -o table
   ```

   ```
   Count_    Type
   --------  -----------------------------------------
   3         microsoft.network/networkinterfaces
   2         microsoft.compute/disks
   2         microsoft.web/sites
   1         microsoft.compute/virtualmachines
   1         microsoft.compute/virtualmachinescalesets
   1         microsoft.network/virtualnetworks
   1         microsoft.network/networksecuritygroups
   1         microsoft.network/publicipaddresses
   ```

7. Asigná cada uno de los siguientes a **pública**, **privada**, **híbrida** o **multinube**, y anotá el atributo *decisivo* de cada uno — no una justificación general.

   | # | Escenario |
   |---|---|
   | a | Un banco mantiene los datos de titulares de tarjetas en hardware propio en su propio centro de datos, pero corre su sitio público de marketing en Azure App Service. |
   | b | Una startup corre todo en Azure, en tres regiones, sin hardware propio. |
   | c | Un hospital despliega Azure Local en una sala de servidores para que los registros de pacientes nunca salgan del edificio, administrado desde el portal de Azure. |
   | d | Un minorista corre su API en Azure y su data warehouse en Google BigQuery. |
   | e | Un fabricante corre un controlador de planta en un servidor Linux on-prem que está habilitado para Arc y gobernado por Azure Policy. |
   | f | Una agencia gubernamental usa una región de Azure físicamente aislada, disponible solo para inquilinos con habilitación de seguridad. |

### Punto de control — Bloque 3

**P12.** El paso 1 muestra `eastus` emparejado con `westus`. El emparejamiento de regiones es una propiedad de la *nube pública*. ¿Qué te dice la existencia del emparejamiento sobre quién es responsable de la recuperación ante desastres entre regiones de tus datos?

**P13.** En el paso 3 el estado del proveedor era `NotRegistered` y sin embargo los tipos de recurso se listaron igual. ¿Cuál es la diferencia entre que un proveedor de recursos esté *disponible* y que esté *registrado*, y por qué esa distinción importa cuando alguien afirma "mi suscripción no puede hacer nube privada"?

**P14.** El escenario (c) pone hardware en la sala de servidores de un hospital y lo administra desde el portal de Azure. ¿Es privada o híbrida? Defendé ambas lecturas, y después comprometete con la que espera el temario de AZ-900.

**P15.** Dá el *único* atributo que separa el escenario (d) del escenario (e). Después indicá a cuál de los dos el examen llama "híbrida".

**P16.** Un cliente dice: "Queremos la elasticidad de la nube pero nuestro regulador prohíbe la multiinquilinidad". ¿Qué modelo, qué producto de Azure, y qué pierden específicamente en comparación con la nube pública?

---

## Bloque 4 — El modelo basado en consumo: CapEx, OpEx y qué significa realmente "detenida"

Basado en consumo significa **pagás por lo que usás, medido, después del hecho** — sin compra anticipada de hardware, sin depreciación ociosa. El malentendido más caro de todo este tema es la diferencia entre *detenida* y *desasignada*.

1. Detené la VM como lo haría un administrador a nivel de SO. Observá el estado de energía.

   ```bash
   az vm stop -g "$RG" -n vm-t11-a -o none
   az vm get-instance-view -g "$RG" -n vm-t11-a --query "instanceView.statuses[].code" -o tsv
   ```

   ```
   ProvisioningState/succeeded
   PowerState/stopped
   ```

2. Ahora liberá el hardware.

   ```bash
   az vm deallocate -g "$RG" -n vm-t11-a -o none
   az vm get-instance-view -g "$RG" -n vm-t11-a --query "instanceView.statuses[].code" -o tsv
   ```

   ```
   ProvisioningState/succeeded
   PowerState/deallocated
   ```

3. Inspeccioná qué sobrevivió a la desasignación — y por lo tanto qué sigue facturando.

   ```bash
   az disk list -g "$RG" --query "[].{name:name, gib:diskSizeGb, sku:sku.name, state:diskState}" -o table
   az network public-ip list -g "$RG" --query "[].{name:name, sku:sku.name, alloc:publicIPAllocationMethod, ip:ipAddress}" -o table
   ```

   ```
   Name                    Gib    Sku              State
   ----------------------  -----  ---------------  --------
   vm-t11-a_disk1_9f2c…    30     Premium_LRS      Reserved

   Name              Sku       Alloc    Ip
   ----------------  --------  -------  -------------
   vm-t11-aPublicIP  Standard  Static   20.121.44.7
   ```

4. Leé el estado `Reserved` del disco y la dirección IP retenida como la respuesta a "¿qué sigo pagando?". Confirmá que el medidor de cómputo es el único que se detuvo listando lo que una VM desasignada ya no reporta.

   ```bash
   az vm show -d -g "$RG" -n vm-t11-a --query "{power:powerState, privateIp:privateIps, publicIp:publicIps}" -o json
   ```

   ```json
   {
     "power": "VM deallocated",
     "privateIp": "",
     "publicIp": "20.121.44.7"
   }
   ```

5. Traé los registros medidos reales. Los datos de consumo tienen un retraso de 8–24 horas — ese retraso es en sí mismo una propiedad del modelo relevante para el examen.

   ```bash
   az consumption usage list \
     --start-date "$(date -u -d '3 days ago' +%Y-%m-%d)" \
     --end-date   "$(date -u +%Y-%m-%d)" \
     --query "[?contains(instanceName,'t11')].{resource:instanceName, meter:meterDetails.meterName, qty:usageQuantity, cost:pretaxCost, currency:currency}" \
     -o table 2>/dev/null | head -10 \
     || echo "az consumption is available on PAYG/EA offers only — use Cost Management below"
   ```

   ```
   Resource       Meter                       Qty        Cost        Currency
   -------------  --------------------------  ---------  ----------  ----------
   vm-t11-a       B2s                         1.983      0.0824      USD
   vm-t11-a       P4 LRS Disk                 0.098      0.0071      USD
   vm-t11-apublicip  Standard IPv4 Static IP  2.000      0.0072      USD
   plan-t11       B1 App                      2.000      0.0292      USD
   ```

6. Si el comando anterior falló (suscripciones con Microsoft Customer Agreement), usá Cost Management, que funciona en todas las ofertas.

   ```bash
   az extension add --name costmanagement --upgrade -o none
   az costmanagement query --type ActualCost --timeframe MonthToDate \
     --scope "/subscriptions/$SUB_ID/resourceGroups/$RG" \
     --dataset-aggregation '{"totalCost":{"name":"Cost","function":"Sum"}}' \
     --dataset-grouping name="ServiceName" type="Dimension" \
     -o json | jq '{columns: [.columns[].name], rows: .rows}'
   ```

   ```json
   {
     "columns": ["Cost", "ServiceName", "Currency"],
     "rows": [
       [0.0824, "Virtual Machines", "USD"],
       [0.0292, "Azure App Service", "USD"],
       [0.0143, "Storage", "USD"],
       [0.0072, "Virtual Network", "USD"]
     ]
   }
   ```

7. Instalá el control de OpEx que CapEx nunca necesitó: un **presupuesto**. En CapEx controlabas el gasto no firmando la orden de compra; en OpEx lo controlás con una alerta sobre un medidor.

   ```bash
   az consumption budget create-with-rg \
     --resource-group "$RG" --budget-name budget-az900-t11 \
     --amount 5 --category Cost --time-grain Monthly \
     --start-date "$(date -u +%Y-%m-01)" --end-date "$(date -u -d '+3 months' +%Y-%m-01)" \
     -o table 2>/dev/null \
     || echo "If this CLI version lacks the command: Portal > Cost Management + Billing > Budgets > Add"
   ```

8. Contrastá las dos curvas de costo explícitamente. Completá esto a partir de lo que observaste, usando palabras, no números:

   | | CapEx (on-prem) | OpEx (consumo en la nube) |
   |---|---|---|
   | Cuándo sale el dinero | | |
   | Costo de un servidor ocioso a las 3 a.m. | | |
   | Costo de un pico de demanda 3× por encima del plan | | |
   | Tratamiento contable | | |
   | Unidad que se factura | | |

### Punto de control — Bloque 4

**P17.** Los pasos 1 y 2 produjeron `PowerState/stopped` y `PowerState/deallocated`. Indicá exactamente qué medidores se detienen en cada caso. Después explicá por qué existe siquiera `az vm stop` si sigue facturando.

**P18.** El disco del paso 3 muestra `diskState: Reserved`. Tu VM está desasignada y no cuesta nada de cómputo. Anotá todos los medidores restantes de ese grupo de recursos, a partir de la salida anterior, que siguen acumulando.

**P19.** El paso 5 necesitó una ventana de 3 días para mostrar algo, y la documentación advierte de un retraso de 8–24 horas. ¿Por qué un modelo basado en consumo es *estructuralmente* incapaz de darte una factura en tiempo real, y qué mecanismo ofrece Azure en lugar de eso?

**P20.** Un director financiero dice: "Migremos a la nube y nuestro gasto en TI se vuelve predecible". Corregí la afirmación en una oración, y después nombrá los dos mecanismos de Azure que realmente aportan previsibilidad.

---

## Bloque 5 — Comparar modelos de precios con tarifas publicadas reales

Este bloque no necesita **ninguna suscripción ni autenticación**. La Azure Retail Prices API es pública.
Referencia: <https://learn.microsoft.com/en-us/rest/api/cost-management/retail-prices/azure-retail-prices>

1. Traé todos los precios publicados de un SKU en una región.

   ```bash
   FILTER="serviceName eq 'Virtual Machines' and armRegionName eq 'eastus' and armSkuName eq 'Standard_D2s_v5'"
   curl -s -G "https://prices.azure.com/api/retail/prices" \
     --data-urlencode "api-version=2023-01-01-preview" \
     --data-urlencode "currencyCode=USD" \
     --data-urlencode "\$filter=$FILTER" \
   | jq -r '.Items[] | [.skuName, .productName, .type, (.reservationTerm // "-"), .retailPrice, .unitOfMeasure] | @tsv' \
   | column -t -s $'\t'
   ```

   ```
   D2s v5        Virtual Machines Dv5 Series          Consumption         -        0.0960     1 Hour
   D2s v5        Virtual Machines Dv5 Series          Reservation         1 Year   672.1920   1 Hour
   D2s v5        Virtual Machines Dv5 Series          Reservation         3 Years  1345.6560  1 Hour
   D2s v5 Spot   Virtual Machines Dv5 Series          Consumption         -        0.0101     1 Hour
   D2s v5 Low Priority  Virtual Machines Dv5 Series   Consumption         -        0.0192     1 Hour
   D2s v5        Virtual Machines Dv5 Series Windows  Consumption         -        0.1920     1 Hour
   D2s v5        Virtual Machines Dv5 Series          DevTestConsumption  -        0.0960     1 Hour
   ```

2. Mirá con atención las filas de `Reservation`. `unitOfMeasure` dice `1 Hour` pero `retailPrice` es `672.19`. Eso no es una tarifa por hora — para las reservas la API devuelve **el precio total de todo el plazo**. Verificalo calculando la tarifa horaria efectiva y comparándola con el pago por uso.

3. Extraé las tarifas de los planes de ahorro, que la API preview anida dentro de cada ítem de consumo.

   ```bash
   curl -s -G "https://prices.azure.com/api/retail/prices" \
     --data-urlencode "api-version=2023-01-01-preview" \
     --data-urlencode "currencyCode=USD" \
     --data-urlencode "\$filter=$FILTER" \
   | jq -r '.Items[] | select(.savingsPlan != null) | .skuName as $s | .savingsPlan[] | [$s, .term, .retailPrice] | @tsv' \
   | column -t -s $'\t'
   ```

   ```
   D2s v5  1 Year   0.0782
   D2s v5  3 Years  0.0538
   ```

4. Normalizá todo a una tarifa horaria efectiva comparable y un porcentaje de descuento.

   ```bash
   python3 - <<'PY'
   import json, urllib.parse, urllib.request

   BASE = "https://prices.azure.com/api/retail/prices"
   FILT = ("serviceName eq 'Virtual Machines' and armRegionName eq 'eastus' "
           "and armSkuName eq 'Standard_D2s_v5'")
   url = BASE + "?" + urllib.parse.urlencode({
       "api-version": "2023-01-01-preview", "currencyCode": "USD", "$filter": FILT})
   items = [i for i in json.load(urllib.request.urlopen(url))["Items"]
            if "Windows" not in i["productName"]]

   payg = next(i for i in items
               if i["type"] == "Consumption"
               and not any(k in i["skuName"] for k in ("Spot", "Low Priority")))
   base = payg["retailPrice"]
   print(f"{'model':<22}{'eff. $/h':>10}{'discount':>11}   commitment / risk")
   print(f"{'Pay-as-you-go':<22}{base:>10.4f}{'baseline':>11}   none")

   for i in items:
       if i["type"] == "Reservation":
           years = 3 if "3" in i["reservationTerm"] else 1
           eff = i["retailPrice"] / (8760 * years)
           print(f"{'Reserved ' + i['reservationTerm']:<22}{eff:>10.4f}"
                 f"{100*(1-eff/base):>10.1f}%   fixed SKU+region, {years}y")

   for sp in payg.get("savingsPlan") or []:
       eff = sp["retailPrice"]
       print(f"{'Savings plan ' + sp['term']:<22}{eff:>10.4f}"
             f"{100*(1-eff/base):>10.1f}%   fixed $/h spend, any SKU")

   for i in items:
       if "Spot" in i["skuName"]:
           print(f"{'Spot':<22}{i['retailPrice']:>10.4f}"
                 f"{100*(1-i['retailPrice']/base):>10.1f}%   evictable, 30s notice")
   PY
   ```

   ```
   model                   eff. $/h   discount   commitment / risk
   Pay-as-you-go             0.0960   baseline   none
   Reserved 1 Year           0.0767      20.1%   fixed SKU+region, 1y
   Reserved 3 Years          0.0512      46.7%   fixed SKU+region, 3y
   Savings plan 1 Year       0.0782      18.5%   fixed $/h spend, any SKU
   Savings plan 3 Years      0.0538      44.0%   fixed $/h spend, any SKU
   Spot                      0.0101      89.4%   evictable, 30s notice
   ```

5. Aislá el componente de **licencia**. Compará los medidores de Linux y de Windows para el mismo SKU de hardware.

   ```bash
   curl -s -G "https://prices.azure.com/api/retail/prices" \
     --data-urlencode "api-version=2023-01-01-preview" \
     --data-urlencode "currencyCode=USD" \
     --data-urlencode "\$filter=$FILTER and priceType eq 'Consumption'" \
   | jq -r '.Items[] | select(.skuName | test("Spot|Low Priority") | not)
            | [.productName, .retailPrice] | @tsv' | column -t -s $'\t'
   ```

   ```
   Virtual Machines Dv5 Series          0.0960
   Virtual Machines Dv5 Series Windows  0.1920
   ```

6. La diferencia (`0.0960`) es la licencia de Windows Server. **Azure Hybrid Benefit** es el mecanismo que la elimina cuando ya sos dueño de la licencia con Software Assurance. Verificá cómo se expresa en un recurso de VM.

   ```bash
   az vm show -g "$RG" -n vm-t11-a --query "{size:hardwareProfile.vmSize, license:licenseType}" -o json
   ```

   ```json
   {
     "license": null,
     "size": "Standard_B2s"
   }
   ```

7. Demostrá que **el precio es un atributo por región**, no una constante global. Esta es la razón mecánica por la que "elegí tu región con cuidado" aparece en toda guía de optimización de costos.

   ```bash
   for R in eastus westeurope japaneast brazilsouth australiaeast; do
     P=$(curl -s -G "https://prices.azure.com/api/retail/prices" \
       --data-urlencode "api-version=2023-01-01-preview" \
       --data-urlencode "currencyCode=USD" \
       --data-urlencode "\$filter=serviceName eq 'Virtual Machines' and armRegionName eq '$R' and armSkuName eq 'Standard_D2s_v5' and priceType eq 'Consumption' and productName eq 'Virtual Machines Dv5 Series'" \
       | jq -r '.Items[0].retailPrice // "n/a"')
     printf "%-16s %s\n" "$R" "$P"
   done
   ```

   ```
   eastus           0.096
   westeurope       0.1104
   japaneast        0.1284
   brazilsouth      0.1638
   australiaeast    0.1224
   ```

8. Por último, listá los medidores que **no** son de cómputo — los que los estudiantes olvidan sistemáticamente al estimar.

   ```bash
   curl -s -G "https://prices.azure.com/api/retail/prices" \
     --data-urlencode "api-version=2023-01-01-preview" \
     --data-urlencode "currencyCode=USD" \
     --data-urlencode "\$filter=armRegionName eq 'eastus' and serviceName eq 'Bandwidth'" \
   | jq -r '.Items[] | [.meterName, .retailPrice, .unitOfMeasure] | @tsv' | head -6 | column -t -s $'\t'
   ```

   ```
   Inter-Region Egress          0.02   1 GB
   Standard Data Transfer Out   0.087  1 GB
   Data Transfer In             0.0    1 GB
   Intra-Region Egress          0.01   1 GB
   ```

### Punto de control — Bloque 5

**P21.** En el paso 1 la reserva de 1 año muestra `retailPrice 672.19` con `unitOfMeasure "1 Hour"`. Explicá la discrepancia y mostrá la aritmética que la convierte en una tarifa horaria comparable.

**P22.** Las instancias reservadas y los planes de ahorro del paso 4 quedan a ~2 puntos porcentuales uno del otro. Dado que cuestan casi lo mismo, indicá la única característica de la carga de trabajo que debería decidir entre ellos.

**P23.** Spot es ~89% más barato. Nombrá dos tipos de carga de trabajo donde esa es la elección correcta y dos donde es motivo de despido, y dá la propiedad técnica que separa los grupos.

**P24.** En el paso 5 el medidor de Windows es exactamente el doble del de Linux. Un equipo aplica Azure Hybrid Benefit a 100 de estas VMs corriendo 730 h/mes. Usando solo los números mostrados, calculá la reducción mensual e indicá qué debe poseer legalmente el equipo para que sea válido.

**P25.** El paso 7 muestra `brazilsouth` a ~1.7× `eastus`. Dá dos razones legítimas por las que un arquitecto elegiría igualmente `brazilsouth`, ambas de mayor peso que el precio unitario.

**P26.** El paso 8 muestra `Data Transfer In` en `0.0` y `Standard Data Transfer Out` en `0.087/GB`. ¿Qué antipatrón arquitectónico existe este precio asimétrico para desalentar, y cuál es el nombre de la preocupación general que crea?

---

## Bloque 6 — Ejercicio de decisión (no requiere recursos en la nube)

Para cada escenario, anotá **(i)** el modelo de nube, **(ii)** el modelo de servicio, **(iii)** el modelo de precios y **(iv)** la única oración de justificación que le darías a un evaluador de examen.

| # | Escenario |
|---|---|
| 1 | Una empresa de logística corre un trabajo por lotes de optimización de rutas cada noche durante 4 horas. Es reiniciable desde un punto de control y no tiene fecha límite antes de las 06:00. |
| 2 | Una empresa SaaS corre 40 servidores de API de producción idénticos 24×7. La arquitectura está congelada por los próximos tres años. |
| 3 | Un banco debe mantener un almacén de claves respaldado por HSM en hardware que controla físicamente, pero quiere que Azure Monitor alerte sobre él. |
| 4 | Una universidad levanta 300 VMs de laboratorio para estudiantes durante dos semanas cada cuatrimestre y las destruye después. |
| 5 | Un ISV no está seguro de si se estandarizará sobre VMs, contenedores o funciones, pero está seguro de que gastará al menos USD 8.000/mes en cómputo durante el próximo año. |
| 6 | El front end de comercio electrónico de un minorista está en 12 servidores de carga durante 11 meses y en 90 servidores durante seis semanas alrededor de las fiestas. |
| 7 | Una empresa de nóminas quiere correo, documentos e identidad con cero operaciones de infraestructura, pero es contractualmente responsable de quién puede leer los archivos de nómina. |

### Punto de control — Bloque 6

**P27.** Los escenarios 2 y 5 involucran ambos un compromiso a largo plazo. ¿Cuál recibe una reserva y cuál un plan de ahorro? Indicá la palabra decisiva en el texto de cada escenario.

**P28.** El escenario 6 es el argumento clásico de la economía de la nube. Dibujá (en palabras) la línea de capacidad CapEx contra la línea de consumo OpEx a lo largo del año, y nombrá los dos costos en los que incurre la línea CapEx y la línea OpEx no.

**P29.** El escenario 7 es SaaS. Identificá la única responsabilidad que la empresa de nóminas no puede delegar, citando la fila de la tabla de responsabilidad compartida de la que proviene.

---

## Bloque 7 — Desmantelamiento (no te lo saltees)

1. Eliminá todo en una sola operación. El límite del grupo de recursos que fijaste en el bloque 0 es lo que hace que esto sea seguro.

   ```bash
   az resource list -g "$RG" --query "length(@)"
   az group delete --name "$RG" --yes --no-wait
   ```

   ```
   10
   ```

2. Confirmá, después de unos minutos, que el grupo desapareció.

   ```bash
   az group exists --name "$RG"
   ```

   ```
   false
   ```

3. Barré en busca de huérfanos que un `vm delete` (a diferencia de un borrado de grupo) habría dejado atrás. Los discos sin adjuntar y las IPs públicas ociosas son los dos cargos silenciosos más comunes.

   ```bash
   az disk list --query "[?diskState=='Unattached'].{name:name, rg:resourceGroup, gib:diskSizeGb}" -o table
   az network public-ip list --query "[?ipConfiguration==null].{name:name, rg:resourceGroup, sku:sku.name}" -o table
   ```

   ```
   (no output — nothing orphaned)
   ```

4. Verificá que el costo dejó de acumularse volviendo a ejecutar mañana la consulta de Cost Management del bloque 4. Acordate del retraso de 8–24 h: un resultado vacío hoy no prueba nada.

### Punto de control — Bloque 7

**P30.** El paso 3 busca recursos con `diskState == 'Unattached'` e `ipConfiguration == null`. En un modelo basado en consumo, ¿qué te cuesta cada una de esas dos condiciones, y por qué eliminar una VM en el portal no las elimina por defecto?

---

## Fuentes

- Guía de estudio AZ-900 — <https://learn.microsoft.com/en-us/credentials/certifications/resources/study-guides/az-900>
- Responsabilidad compartida en la nube — <https://learn.microsoft.com/en-us/azure/security/fundamentals/shared-responsibility>
- Azure Retail Prices API — <https://learn.microsoft.com/en-us/rest/api/cost-management/retail-prices/azure-retail-prices>
- Estados de máquina virtual y facturación — <https://learn.microsoft.com/en-us/azure/virtual-machines/states-billing>
- Ahorrar costos con reservas — <https://learn.microsoft.com/en-us/azure/cost-management-billing/reservations/save-compute-costs-reservations>
- Azure savings plan para cómputo — <https://learn.microsoft.com/en-us/azure/cost-management-billing/savings-plan/savings-plan-compute-overview>
- Azure Spot Virtual Machines — <https://learn.microsoft.com/en-us/azure/virtual-machines/spot-vms>
- Introducción a Azure Arc — <https://learn.microsoft.com/en-us/azure/azure-arc/overview>
- Zonas de disponibilidad — <https://learn.microsoft.com/en-us/azure/reliability/availability-zones-overview>
- Crear y administrar presupuestos — <https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/tutorial-acm-create-budgets>
- Límites de suscripción y servicio de Azure — <https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/azure-subscription-service-limits>

---

<details>
<summary><strong>Respuestas — expandí solo después de intentar todos los puntos de control</strong></summary>

### Bloque 0

**P1.** El **grupo de recursos** (`/subscriptions/{id}/resourceGroups/{name}`). Es el ámbito más pequeño que acepta simultáneamente asignaciones de Azure Policy, asignaciones de rol RBAC y presupuestos de Cost Management. Los recursos individuales aceptan RBAC y algunos efectos de directiva, pero no presupuestos. En un laboratorio esto importa porque una sola eliminación de ese ámbito único garantiza que no sobreviva ningún recurso facturable huérfano — el radio de impacto es igual al radio de costo.

**P2.** **Atribución de costos y refacturación interna.** La facturación por consumo produce un único flujo plano de ítems medidos sin noción de equipo, proyecto o propósito. Las etiquetas son el único mecanismo que proyecta significado de negocio sobre ese flujo — te permiten agrupar el costo por `course`, `owner` o centro de costos en Cost Management, y permiten que una directiva limpie automáticamente todo lo marcado como `lifecycle=ephemeral`. Sin etiquetas la factura es exacta e inútil.

**P3.** **Falso.** Los registros de costo y uso son datos del ámbito de facturación, retenidos independientemente del ciclo de vida del recurso. Eliminar el grupo de recursos detiene la acumulación futura; los ítems históricos siguen siendo consultables en Cost Management (y en las exportaciones) bajo el ámbito de suscripción/cuenta de facturación. Precisamente por eso el paso 4 del bloque 7 dice que revises de nuevo mañana en vez de inmediatamente.

### Bloque 1

**P4.** (i) **Elasticidad rápida / aprovisionamiento de autoservicio** — la capacidad aparece con una llamada a la API en ~75 s sin ciclo de compras. (ii) **Elasticidad bidireccional con liberación medida** — la capacidad se *devuelve* en ~41 s y la facturación se detiene. Un centro de datos on-prem sobreaprovisionado puede reclamar la primera (levantar rápido una VM sobre hardware de sobra) pero **nunca la segunda**: liberar una VM en hardware propio no devuelve nada, porque el capital ya se gastó y la depreciación continúa.

**P5.** Igual definiste la **red virtual, la subred, las reglas del NSG, la IP pública y la NIC** — más la imagen del SO y el disco. El límite de la abstracción en IaaS se ubica **en el hipervisor**: Microsoft eliminó el racking, el cableado, la energía, la refrigeración y el tejido de red física, pero cada constructo *lógico* de infraestructura sigue siendo tuyo para diseñar, asegurar y operar. "Sin infraestructura física" no es "sin infraestructura".

**P6.** Miden cosas distintas. `Virtual Machines` es una cuota de *cantidad* (cuántos objetos VM pueden existir); `Standard DSv5 Family vCPUs` es una cuota de *capacidad* por familia de SKU en esa región, y es `0` porque la suscripción nunca fue aprobada para esa familia ahí. Un estudiante que cree que la capacidad es ilimitada va a diseñar una regla de autoescalado a 40 instancias, pasar todas las pruebas funcionales con 2 instancias, y descubrir el techo durante el pico de tráfico que el diseño existía para sobrevivir. La capacidad en la nube es elástica **dentro de una cuota por región y por familia**; subirla es una solicitud de soporte con tiempo de espera.

**P7.** Cuando el tamaño destino pertenece a un **clúster de hardware / familia de VM distinto** del que actualmente hospeda la VM. `B1s → B2s` se mantiene dentro de la familia B en el mismo clúster, así que Azure puede redimensionar en el lugar. `B2s → D2s_v5` (o cualquier tamaño no ofrecido por el clúster actual) requiere `az vm deallocate` primero, porque la VM debe reubicarse sobre hardware físicamente distinto — lo que además significa que pierde su IP dinámica y el contenido de cualquier disco temporal local.

### Bloque 2

**P8.** **La ejecución se transfirió; la rendición de cuentas no.** `AutomaticByPlatform` hace que Azure Update Manager programe y aplique los parches, así que Microsoft *realiza* el trabajo. Pero vos elegiste el modo, sos dueño de la ventana de mantenimiento, sos dueño de lo que pasa si un parche rompe la aplicación, y seguís siendo el que responde en una auditoría por el nivel de parches de la máquina. En el modelo de responsabilidad compartida la fila del SO sigue siendo **del cliente** en IaaS sin importar quién apriete el botón. Delegar una tarea no es delegar la responsabilidad.

**P9.** Regla: **la superficie configurable de un servicio es una cota inferior de tu responsabilidad sobre él.** Si la API expone una perilla, el proveedor declaró que ese ajuste es tu decisión, y por lo tanto tu responsabilidad legal. Si no existe ninguna perilla en ninguna capa, esa capa la opera enteramente el proveedor. Dónde engaña: las propiedades de **solo lectura** (podés *ver* el dominio de fallo del host pero no configurarlo) y las filas **compartidas** como los controles de red y la infraestructura de identidad, donde ambas partes tienen obligaciones reales y la presencia de una perilla no subestima a ninguna. La ausencia de una API tampoco elimina nunca tus responsabilidades sobre datos e identidad — SaaS casi no tiene API de infraestructura y sin embargo esas filas siguen siendo tuyas.

**P10.** PaaS elimina *amplitud* de responsabilidad, no *profundidad*. Los ocho recursos de IaaS son en gran medida definiciones de infraestructura de una sola vez; los dos recursos de PaaS todavía cargan con el código de la aplicación, sus dependencias, sus secretos, su configuración de identidad, sus datos y su diseño de disponibilidad — y ahí es donde se origina casi todo incidente. PaaS mueve tu esfuerzo **hacia arriba en la pila, no fuera de la existencia**: dejás de parchear kernels y empezás a ser dueño de un runtime que ya no podés inspeccionar por debajo del límite del contenedor. La cantidad de recursos mide superficie, no carga operativa.

**P11.** **Información y datos**, **Dispositivos** y **Cuentas e identidades** son del cliente en las cuatro columnas. El modelo está construido así porque estas tres son las cosas que el proveedor no puede ver, no puede valorar y sobre las que no puede tomar decisiones: Microsoft no sabe cuáles de tus registros están regulados, qué laptop pertenece a un empleado que se va, ni qué cuenta debería haberse deshabilitado el viernes pasado. La responsabilidad del proveedor solo puede extenderse a lo que el proveedor puede observar y controlar; estas tres están por definición fuera de ese conjunto, y por eso todo análisis de brecha en la nube termina aterrizando en alguna de ellas.

**Tabla de referencia para el paso 10** (C = cliente, M = Microsoft, S = compartida):

| Capa | On-prem | IaaS | PaaS | SaaS |
|---|---|---|---|---|
| Información y datos | C | C | C | C |
| Dispositivos (móviles y PCs) | C | C | C | C |
| Cuentas e identidades | C | C | C | C |
| Infraestructura de identidad y directorio | C | S | S | S |
| Aplicaciones | C | C | S | M |
| Controles de red | C | C | S | M |
| Sistema operativo | C | C | M | M |
| Hosts físicos | C | M | M | M |
| Red física | C | M | M | M |
| Centro de datos físico | C | M | M | M |

### Bloque 3

**P12.** El emparejamiento te dice que Microsoft diseñó una **separación física y operativa** (típicamente >300 km, actualizaciones de plataforma secuenciales, recuperación priorizada) — es una *capacidad*, no un servicio. La responsabilidad de la recuperación ante desastres entre regiones de tus datos sigue siendo **tuya**: tenés que elegir almacenamiento georredundante, configurar la replicación y probar la conmutación por error. El emparejamiento te da un destino bien elegido; no copia nada por vos. Confundir ambas cosas es el origen de "pensábamos que Azure tenía un backup".

**P13.** **Disponible** significa que el proveedor de recursos existe en la flota de Azure y que sus tipos de recurso y versiones de API están publicados — por eso los tipos se listaron. **Registrado** significa que *esta suscripción* optó por participar, permitiendo la creación de recursos en ese espacio de nombres. El registro es una operación gratuita, de autoservicio e idempotente (`az provider register`). Así que "mi suscripción no puede hacer nube privada" casi nunca es una afirmación sobre capacidades; suele ser un proveedor no registrado o un rol RBAC faltante, ambos solucionables con un solo comando. Los bloqueos reales son licenciamiento, hardware y disponibilidad regional, no el estado del proveedor.

**P14.** *Lectura privada:* el hardware es de un solo inquilino, propiedad del cliente, en una instalación controlada por el cliente; ningún otro inquilino lo comparte — esa es la definición de manual de nube privada. *Lectura híbrida:* se administra a través del plano de control de Azure, se factura mediante una suscripción de Azure y se gobierna con las mismas directivas que los recursos de Azure público, así que el patrimonio abarca ambos. **Comprometete con híbrida.** El temario define híbrida como un entorno que combina nube pública y privada *y permite operarlas juntas*; la característica definitoria de Azure Local es exactamente ese plano de administración conectado a Azure. Azure Stack Hub en modo totalmente desconectado sería la respuesta más limpia de "nube privada".

**P15.** **Si los dos entornos están unidos por un único plano de control.** (d) corre dos nubes públicas independientes lado a lado con administración, identidad y facturación separadas — eso es **multinube**. (e) proyecta una máquina on-premises dentro de Azure Resource Manager vía Arc, de modo que un solo motor de directivas, un solo modelo RBAC y un solo inventario cubren ambas — eso es **híbrida**. El examen llama híbrida a (e).

**P16.** Modelo: **nube privada**. Producto: **Azure Local** (o Azure Stack Hub para un requisito totalmente desconectado). Lo que pierden: **la verdadera elasticidad y el modelo de consumo.** La capacidad ahora está limitada por el hardware que compraron, así que escalar horizontalmente es de nuevo un ciclo de compras, el CapEx vuelve, la capacidad ociosa se paga, y la huella global de regiones, los servicios PaaS de escala ilimitada y la facturación por segundo no están disponibles. Conservan el modelo operativo y la API; renuncian a la economía.

### Bloque 4

**P17.** `PowerState/stopped`: el SO invitado está apagado, pero la VM **sigue asignada** a un host físico — el medidor de cómputo, los medidores de disco y el medidor de IP siguen corriendo. Azure está reservando ese hardware para vos. `PowerState/deallocated`: la VM se libera del host — el **medidor de cómputo se detiene**; los medidores de disco y de IP pública estática continúan. `az vm stop` existe porque la desasignación no siempre es deseable: libera la reserva del host (así que un arranque posterior puede fallar por capacidad o aterrizar en hardware distinto), descarta el disco temporal y suelta las IPs dinámicas. Cuando necesitás un reinicio rápido y garantizado sobre el mismo hardware, detenés; cuando querés dejar de pagar, desasignás.

**P18.** Sigue acumulando después de la desasignación, según las salidas mostradas:
- **Disco de SO administrado** — 30 GiB `Premium_LRS`, `diskState: Reserved` (la capacidad aprovisionada se factura esté adjunta o no).
- **IP pública estática Standard** — `20.121.44.7`, facturada por hora por la reserva de la dirección en sí.
- **Plan de App Service `plan-t11` (B1)** — un plan dedicado factura de forma continua independientemente de si hay una app corriendo.
- Más pequeños medidores de transacciones de almacenamiento/diagnóstico si el diagnóstico de arranque está habilitado.
La VNet y el NSG en sí son gratuitos.

**P19.** Porque el modelo factura **eventos medidos después de que ocurren**. Cada segundo de uso a lo largo de millones de inquilinos tiene que ser emitido por el proveedor de recursos, recolectado, deduplicado, tarifado contra tu hoja de precios específica (que depende de la oferta, los descuentos negociados, las reservas, los créditos y la moneda), y recién entonces materializado como un registro de costo. El tarifado es el paso caro y es inherentemente retrospectivo. La respuesta de Azure no es una factura en tiempo real sino **controles predictivos y reactivos**: presupuestos con alertas por umbral, detección de anomalías de costo, y límites de cuota que topean la capacidad física de gastar. Una factura OpEx se controla acotándola por adelantado, no mirándola en vivo.

**P20.** Corrección: *"La nube hace que el gasto en TI sea **variable y proporcional al uso**; eso es lo opuesto a predecible — es la razón por la que una carga de trabajo sin límites puede producir una factura sin límites."* Los dos mecanismos que restauran la previsibilidad: **(1) precios por compromiso** — reservas y planes de ahorro, que convierten una tarifa variable en una fija; **(2) controles de gobernanza** — presupuestos con alertas y grupos de acción, más cuotas y límites de Azure Policy sobre SKU y región, que topean lo que se puede aprovisionar en absoluto.

### Bloque 5

**P21.** Para los ítems con `type: "Reservation"` la API devuelve el **precio total de todo el plazo**, y `unitOfMeasure` refleja la unidad de consumo subyacente en lugar de la unidad de facturación de esa fila. Convertí dividiendo por las horas del plazo:

```
1-Year:  672.1920 / (8760 × 1)  = 0.07673 $/h   →  1 − 0.07673/0.0960 = 20.1% discount
3-Year: 1345.6560 / (8760 × 3)  = 0.05119 $/h   →  1 − 0.05119/0.0960 = 46.7% discount
```
(8760 = 365 × 24; el propio material de Azure suele usar 730 h/mes × 12.) Comparar `672.19` directamente contra `0.0960` es el error clásico — hace que una reserva parezca 7.000× más cara que el pago por uso.

**P22.** **Si el SKU, la familia y la región de la carga de trabajo son estables durante el plazo.** Una *reserva* está atada a una familia de VM, región y plazo específicos; entrega el descuento más profundo pero solo rinde si realmente corrés esa forma. Un *plan de ahorro* compromete un monto **en dólares por hora** fijo y se aplica automáticamente sobre el cómputo elegible (distintas familias de VM, App Service, Container Instances, Functions Premium, entre regiones), cambiando un descuento algo menor por flexibilidad. Entonces: arquitectura congelada → reserva; arquitectura que probablemente cambie → plan de ahorro.

**P23.** **Correcto para Spot:** trabajos por lotes/ETL y de renderizado con puntos de control; agentes de compilación de CI/CD; flotas de prueba sin estado a gran escala; entrenamiento de ML oportunista con puntos de control guardados. **Motivo de despido:** la base de datos principal; una capa de API sincrónica de cara al cliente; un servidor de sesión con estado sin almacenamiento externo de sesión; cualquier cosa bajo un SLA de disponibilidad. La propiedad que los separa es la **tolerancia a la interrupción**: las instancias Spot son desalojadas con aproximadamente 30 segundos de aviso cada vez que Azure necesita recuperar la capacidad o se supera tu precio máximo, y Spot **no tiene SLA de disponibilidad**. Si perder la instancia a mitad de una solicitud pierde trabajo o rompe una promesa a un usuario, Spot está mal a cualquier descuento.

**P24.** Recargo de licencia por VM = `0.1920 − 0.0960 = 0.0960 $/h`.
`0.0960 × 730 h × 100 VMs = 7.008 USD/mes` ahorrados (≈ 84.096 USD/año).
Requisito: la organización debe **poseer licencias de Windows Server con Software Assurance activo, o licencias por suscripción**, en cantidad suficiente para los núcleos que se cubren, y debe declararlo al habilitar el beneficio (`--license-type Windows_Server`). Azure no verifica el derecho de uso en el momento del aprovisionamiento — el riesgo de cumplimiento lo asume el cliente, y esto se audita.

**P25.** (1) **Residencia de datos y cumplimiento regulatorio** — la ley brasileña (LGPD) o una regulación sectorial pueden exigir que los datos permanezcan en el país; un despliegue ilegal a mitad de precio no es más barato. (2) **Latencia hacia la base de usuarios** — para cargas interactivas que atienden usuarios brasileños, ~150 ms de ida y vuelta adicional hasta `eastus` degrada el producto de una forma que un ahorro de cómputo de ~40% no puede compensar. Una tercera respuesta válida: **costo de egreso de datos y gravedad de los datos** — ubicar el cómputo lejos de los datos que lee puede costar más en ancho de banda entre regiones que lo que ahorra el descuento de cómputo.

**P26.** Desalienta las **arquitecturas conversadoras, entre regiones y entre nubes que sacan datos de la plataforma repetidamente** — por ejemplo, una capa de cómputo en una región leyendo en cada solicitud un conjunto de datos almacenado en otra, o una capa de reportes que exporta tablas completas en vez de consultar en el lugar. La entrada es gratis precisamente porque el proveedor quiere tus datos adentro; la salida se cobra porque moverlos hacia afuera consume el backbone caro del proveedor y el tránsito de internet. La preocupación general que esto crea es la **gravedad de los datos** y su consecuencia comercial, el **bloqueo por proveedor**: cuanto más grande es el conjunto de datos, más cuesta moverlo, así que los datos anclan el cómputo a la plataforma. Arquitectónicamente las mitigaciones son: cómputo junto a los datos, agregar antes del egreso, y usar peering privado o CDN para el tráfico genuinamente externo.

### Bloque 6

| # | Modelo de nube | Modelo de servicio | Modelo de precios | Justificación |
|---|---|---|---|---|
| 1 | Pública | IaaS (VMs / Batch) | **Spot** | Reiniciable desde un punto de control con una holgura de 6 horas — un desalojo cuesta un reintento, no el trabajo. |
| 2 | Pública | IaaS | **Instancias reservadas, 3 años** | 40 servidores *idénticos*, 24×7, arquitectura *congelada por tres años*: SKU, región y plazo están todos fijos, así que aplica el descuento de compromiso más profundo sin riesgo de flexibilidad. |
| 3 | Híbrida | IaaS sobre hardware del cliente + Azure Arc | Pago por uso para los servicios de Azure | El hardware debe controlarse físicamente (privada), pero debe ser visible para Azure Monitor — esa combinación *es* híbrida, entregada por Arc. |
| 4 | Pública | IaaS (o Azure Lab Services / DevTest Labs) | **Pago por uso**, con apagado automático; tarifas Dev/Test si la suscripción califica | Dos ráfagas al año — el precio por compromiso quedaría ocioso 11 meses; el valor acá está en desasignar todo entre cuatrimestres. |
| 5 | Pública | mixto (indefinido) | **Plan de ahorro, 1 año** | El compromiso se expresa en *dólares por mes*, no como un SKU. Un plan de ahorro compromete gasto y flota entre VMs, contenedores y funciones. |
| 6 | Pública | IaaS/PaaS con autoescalado | **Híbrido: reserva o plan de ahorro para la base de ~12 servidores + pago por uso (o Spot) para el pico** | Comprometete solo con el piso que siempre vas a consumir; comprá el pico a demanda. Comprometerse a 90 desperdiciaría 78 servidores durante 11 meses. |
| 7 | Pública | **SaaS** (Microsoft 365) | Suscripción por usuario | Cero operaciones de infraestructura es la definición de SaaS; la facturación es por puesto, no por recurso-hora. |

**P27.** Escenario 2 → **reserva**; las palabras decisivas son *"40 idénticos"* y *"la arquitectura está congelada"* — el SKU es conocido e inamovible. Escenario 5 → **plan de ahorro**; las palabras decisivas son *"no está seguro de si se estandarizará sobre VMs, contenedores o funciones"* combinadas con una cifra confiada en *dólares* — podés comprometer gasto sin comprometer forma.

**P28.** **Línea CapEx:** un escalón plano en el equivalente a 90 servidores de capacidad durante todo el año — el pico debe comprarse por adelantado, aprovisionarse meses antes de que se necesite, y no baja en enero. Aproximadamente el 87% de esa capacidad está ociosa durante 11 meses. **Línea OpEx:** traza la demanda misma — plana en 12 durante 11 meses, una rampa casi vertical hasta 90 durante seis semanas, y después de vuelta abajo. Dos costos en los que incurre la línea CapEx y OpEx no: **(1) el costo de mantenimiento de la capacidad ociosa** — depreciación, energía, refrigeración, espacio en rack, licencias y soporte sobre 78 servidores sin usar durante 11 meses; **(2) el costo de equivocarse en la otra dirección** — si el pico resulta ser 120, la línea OpEx simplemente escala, mientras que la línea CapEx requiere un ciclo de compras medido en meses y pierde los ingresos mientras tanto. Un tercero frecuentemente aceptado es el **costo de oportunidad del capital** inmovilizado en la compra.

**P29.** **"Información y datos"** — y por extensión **"Cuentas e identidades"**. El escenario dice que la empresa es *contractualmente responsable de quién puede leer los archivos de nómina*. Microsoft opera la aplicación, el SO, la red y el centro de datos, pero no puede saber qué registro de empleado es confidencial ni qué cuenta debería haberse revocado. La gobernanza de accesos, la clasificación de datos, la retención y las consecuencias de un permiso equivocado quedan con el cliente en todos los modelos de servicio, SaaS incluido.

### Bloque 7

**P30.** **Disco administrado sin adjuntar:** facturado por su tamaño **aprovisionado** y su nivel de rendimiento, de forma continua, para siempre — un SSD Premium de 1 TiB cuesta lo mismo desadjuntado que adjunto, porque Azure reservó esa capacidad para vos. **IP pública con `ipConfiguration == null`:** una dirección de SKU Standard se factura por hora por la *reserva de la dirección en sí*, haya o no algo detrás; la escasez de IPv4 es la razón. Ninguna de las dos se elimina al borrar una VM en el portal porque ambas son **recursos ARM independientes con su propio ciclo de vida** — la hoja de borrado del portal ofrece eliminarlas pero históricamente no lo hacía por defecto, y las eliminaciones del recurso VM por CLI/ARM/Terraform nunca lo hacen. Esta es la fuente más común de "borramos todo y la factura no bajó", y es exactamente por eso que el bloque 0 puso todos los recursos dentro de un único grupo de recursos: `az group delete` no tiene esa brecha.

</details>