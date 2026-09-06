# AZ-900 — Tema 2.3: Describir los servicios de Azure Storage
## Ejercicios guiados (laboratorio práctico)

**Peso en el examen:** 9.62 % · **Versión del temario:** 2026-07-20
**Guía de estudio oficial:** https://learn.microsoft.com/en-us/credentials/certifications/resources/study-guides/az-900

---

## Antes de empezar

**Requisitos previos**

- Una suscripción de Azure. Alcanza con una prueba gratuita o una suscripción de Azure for Students — todos los recursos de este laboratorio son gratuitos o cuestan centavos si completás la limpieza del Ejercicio 9.
- Azure Cloud Shell (Bash) o una shell local con Azure CLI `2.60.0` o posterior. Verificalo con `az version`.
- No hace falta una máquina Windows. Dos ejercicios (Azure File Sync, Storage Explorer) son bloques de **leer y razonar** en vez de bloques de ejecución, porque necesitan un Windows Server o una instalación de escritorio — el examen evalúa qué *son* y *cuándo los elegís*, no sus instaladores.

**Advertencia de costos.** Los discos administrados y las cuentas de almacenamiento premium facturan desde el segundo en que existen. El Ejercicio 6 crea un disco; el Ejercicio 9 borra todo. No te quedes a mitad de camino.

**Convenciones usadas más abajo**

- Las líneas que empiezan con `$` son comandos que escribís vos. Todo lo demás dentro de un bloque de salida es lo que devuelve Azure.
- La salida está recortada a los campos que importan. Tus GUIDs, marcas de tiempo e IPs van a ser distintos.
- `<...>` significa que sustituyas con tu propio valor.

---

## Ejercicio 1 — La cuenta de almacenamiento es el límite

Casi toda decisión de almacenamiento en Azure se toma **una sola vez, al crear la cuenta**, y después es cara o imposible de cambiar. Este ejercicio hace visible ese límite.

### Pasos

1. Abrí Cloud Shell (https://shell.azure.com) y confirmá en qué suscripción estás:

   ```bash
   $ az account show --output table
   ```

   ```
   EnvironmentName    HomeTenantId                          IsDefault    Name                State    TenantId
   -----------------  ------------------------------------  -----------  ------------------  -------  ------------------------------------
   AzureCloud         3f1a...c9d2                           True         Pay-As-You-Go       Enabled  3f1a...c9d2
   ```

2. Exportá un nombre de cuenta globalmente único. Los nombres de cuenta de almacenamiento son de **3–24 caracteres, sólo letras minúsculas y dígitos**, y comparten un único espacio de nombres DNS global con todos los demás inquilinos de Azure del planeta:

   ```bash
   $ export RG=rg-az900-storage
   $ export LOC=eastus
   $ export SA=st900lab$RANDOM$RANDOM
   $ echo $SA
   ```

   ```
   st900lab1842229517
   ```

3. Creá el grupo de recursos y después la cuenta de almacenamiento. Fijate que **no** pasamos `--sku`, deliberadamente:

   ```bash
   $ az group create --name $RG --location $LOC --output table
   $ az storage account create \
       --name $SA \
       --resource-group $RG \
       --location $LOC \
       --output none
   ```

4. Inspeccioná lo que Azure eligió por vos:

   ```bash
   $ az storage account show --name $SA --resource-group $RG \
       --query "{kind:kind, sku:sku.name, tier:accessTier, https:enableHttpsTrafficOnly, tls:minimumTlsVersion, publicBlob:allowBlobPublicAccess}" \
       --output yaml
   ```

   ```yaml
   https: true
   kind: StorageV2
   publicBlob: false
   sku: Standard_RAGRS
   tier: Hot
   tls: TLS1_2
   ```

5. Listá los endpoints de servicio que expone la cuenta:

   ```bash
   $ az storage account show --name $SA --resource-group $RG \
       --query primaryEndpoints --output yaml
   ```

   ```yaml
   blob: https://st900lab1842229517.blob.core.windows.net/
   dfs: https://st900lab1842229517.dfs.core.windows.net/
   file: https://st900lab1842229517.file.core.windows.net/
   queue: https://st900lab1842229517.queue.core.windows.net/
   table: https://st900lab1842229517.table.core.windows.net/
   web: https://st900lab1842229517.z13.web.core.windows.net/
   ```

6. Intentá crear una segunda cuenta con el mismo nombre en un grupo de recursos distinto y leé el error:

   ```bash
   $ az storage account create --name $SA --resource-group $RG --location westus2 --output none
   ```

   ```
   (StorageAccountAlreadyExists) The storage account named st900lab1842229517 is already taken.
   Code: StorageAccountAlreadyExists
   ```

### Verificá lo que entendiste — bloque 1

**Q1.1** ¿Por qué el nombre de una cuenta de almacenamiento tiene que ser globalmente único, cuando el nombre de una máquina virtual sólo tiene que ser único dentro de su grupo de recursos?

**Q1.2** La cuenta se creó como `StorageV2` (general-purpose v2). ¿Qué cuatro *servicios* de almacenamiento contiene esa única cuenta, y cuál de los cinco servicios que suele nombrar el objetivo del examen **no** está en la lista?

**Q1.3** La CLI usó por defecto `Standard_RAGRS`. Nombrá un riesgo concreto de aceptar ese valor por defecto sin pensarlo, y un beneficio concreto.

**Q1.4** `allowBlobPublicAccess` devolvió `false`. Si un colega dice "simplemente hacé el contenedor público para que el sitio web pueda leerlo", ¿qué tiene que cambiar primero, y qué hace esa configuración a nivel de cuenta versus a nivel de contenedor?

**Q1.5** El endpoint `dfs` apareció aunque no pediste Data Lake. ¿Qué característica sirve ese endpoint, y es usable en esta cuenta tal como fue creada?

---

## Ejercicio 2 — Blob storage: contenedores, tipos de blob y el espacio de nombres plano

### Pasos

1. Las operaciones sobre blobs necesitan un modo de autorización. Usá tu identidad de Entra ID en vez de las claves de cuenta — este es el patrón de producción y además demuestra que **RBAC en el plano de control no es RBAC en el plano de datos**:

   ```bash
   $ az storage container create \
       --name media \
       --account-name $SA \
       --auth-mode login \
       --output table
   ```

   ```
   (AuthorizationPermissionMismatch) This request is not authorized to perform this operation using this permission.
   ```

2. Ese fallo es la lección. Ser Owner/Contributor en la suscripción te deja *administrar* la cuenta pero no *leer sus datos*. Asignate un rol del plano de datos:

   ```bash
   $ export ME=$(az ad signed-in-user show --query id --output tsv)
   $ export SCOPE=$(az storage account show --name $SA --resource-group $RG --query id --output tsv)
   $ az role assignment create \
       --assignee-object-id $ME \
       --assignee-principal-type User \
       --role "Storage Blob Data Contributor" \
       --scope $SCOPE \
       --output none
   ```

   Esperá de 1 a 3 minutos a que la asignación se propague, después reintentá el paso 1. Ahora funciona:

   ```
   Created
   --------
   True
   ```

3. Creá tres archivos de formas distintas y subilos:

   ```bash
   $ head -c 2M /dev/urandom > report.bin
   $ echo "2026-09-05T10:00:00Z INFO service started" > app.log
   $ echo '{"id":1,"status":"ok"}' > record.json
   $ az storage blob upload-batch \
       --destination media \
       --source . \
       --pattern "*.bin" \
       --account-name $SA --auth-mode login --output none
   $ az storage blob upload --container-name media --name logs/2026/09/app.log --file app.log \
       --account-name $SA --auth-mode login --output none
   $ az storage blob upload --container-name media --name logs/2026/09/record.json --file record.json \
       --account-name $SA --auth-mode login --output none
   ```

4. Listá lo que existe, mostrando el tipo de blob y el nivel:

   ```bash
   $ az storage blob list --container-name media \
       --account-name $SA --auth-mode login \
       --query "[].{name:name, type:properties.blobType, tier:properties.blobTier, bytes:properties.contentLength}" \
       --output table
   ```

   ```
   Name                      Type       Tier    Bytes
   ------------------------  ---------  ------  -------
   logs/2026/09/app.log      BlockBlob  Hot     42
   logs/2026/09/record.json  BlockBlob  Hot     23
   report.bin                BlockBlob  Hot     2097152
   ```

5. Demostrá que el espacio de nombres es plano, no jerárquico. Intentá borrar la "carpeta":

   ```bash
   $ az storage blob delete --container-name media --name "logs/2026/09" \
       --account-name $SA --auth-mode login
   ```

   ```
   (BlobNotFound) The specified blob does not exist.
   ```

   Después listá con un delimitador y observá la ilusión que Azure renderiza para vos:

   ```bash
   $ az storage blob list --container-name media --delimiter "/" \
       --account-name $SA --auth-mode login \
       --query "[].name" --output tsv
   ```

   ```
   logs/
   report.bin
   ```

### Verificá lo que entendiste — bloque 2

**Q2.1** El paso 1 falló mientras eras Owner de la suscripción. Explicá la diferencia entre el plano de control de Azure Resource Manager y el plano de datos de storage, y nombrá el rol que tuviste que agregar.

**Q2.2** Las tres subidas produjeron `BlockBlob`. Describí los tres tipos de blob y dá la carga de trabajo canónica de cada uno.

**Q2.3** En el paso 5, borrar `logs/2026/09` falló pero el listado del paso 4 mostraba una ruta. ¿Dónde existe realmente la "carpeta"?

**Q2.4** ¿Qué cambiaría en el paso 5 si la cuenta se hubiera creado con el espacio de nombres jerárquico (HNS / Data Lake Storage Gen2) habilitado?

**Q2.5** Un contenedor se crea dentro de una cuenta. ¿Cuál es la relación entre cuenta → contenedor → blob, y puede un blob existir fuera de un contenedor?

---

## Ejercicio 3 — Niveles de acceso y el costo de equivocarse

### Pasos

1. Bajá los blobs de logs por la escalera de niveles y observá qué transiciones permite Azure:

   ```bash
   $ az storage blob set-tier --container-name media --name logs/2026/09/app.log \
       --tier Cool --account-name $SA --auth-mode login --output none
   $ az storage blob set-tier --container-name media --name logs/2026/09/record.json \
       --tier Cold --account-name $SA --auth-mode login --output none
   $ az storage blob set-tier --container-name media --name report.bin \
       --tier Archive --account-name $SA --auth-mode login --output none
   ```

2. Volvé a listar y leé el resultado:

   ```bash
   $ az storage blob list --container-name media \
       --account-name $SA --auth-mode login \
       --query "[].{name:name, tier:properties.blobTier, status:properties.rehydrationStatus}" \
       --output table
   ```

   ```
   Name                      Tier     Status
   ------------------------  -------  --------
   logs/2026/09/app.log      Cool
   logs/2026/09/record.json  Cold
   report.bin                Archive
   ```

3. Ahora intentá leer el blob archivado:

   ```bash
   $ az storage blob download --container-name media --name report.bin --file /tmp/out.bin \
       --account-name $SA --auth-mode login
   ```

   ```
   (BlobArchived) This operation is not permitted on an archived blob.
   ```

4. Iniciá una rehidratación y observá el estado intermedio:

   ```bash
   $ az storage blob set-tier --container-name media --name report.bin \
       --tier Hot --rehydrate-priority High \
       --account-name $SA --auth-mode login --output none
   $ az storage blob show --container-name media --name report.bin \
       --account-name $SA --auth-mode login \
       --query "{tier:properties.blobTier, status:properties.rehydrationStatus}" --output yaml
   ```

   ```yaml
   status: rehydrate-pending-to-hot
   tier: Archive
   ```

5. Configurá un nivel por defecto a nivel de cuenta y confirmá que **no** mueve retroactivamente los blobs existentes:

   ```bash
   $ az storage account update --name $SA --resource-group $RG --access-tier Cool --output none
   $ az storage account show --name $SA --resource-group $RG --query accessTier --output tsv
   ```

   ```
   Cool
   ```

6. Escribí una política de administración del ciclo de vida para que el cambio de nivel ocurra sin un humano. Creá `policy.json`:

   ```json
   {
     "rules": [
       {
         "enabled": true,
         "name": "logs-age-out",
         "type": "Lifecycle",
         "definition": {
           "filters": {
             "blobTypes": [ "blockBlob" ],
             "prefixMatch": [ "media/logs/" ]
           },
           "actions": {
             "baseBlob": {
               "tierToCool":    { "daysAfterModificationGreaterThan": 30 },
               "tierToCold":    { "daysAfterModificationGreaterThan": 90 },
               "tierToArchive": { "daysAfterModificationGreaterThan": 180 },
               "delete":        { "daysAfterModificationGreaterThan": 2555 }
             }
           }
         }
       }
     ]
   }
   ```

   Aplicala:

   ```bash
   $ az storage account management-policy create \
       --account-name $SA --resource-group $RG \
       --policy @policy.json --output none
   $ az storage account management-policy show \
       --account-name $SA --resource-group $RG \
       --query "policy.rules[].name" --output tsv
   ```

   ```
   logs-age-out
   ```

### Verificá lo que entendiste — bloque 3

**Q3.1** Completá los cuatro niveles online/offline del más caro al más barato **por GB almacenado**, e indicá qué se mueve en la dirección opuesta a medida que bajás.

**Q3.2** ¿Cuál es el período mínimo de retención para Cool, Cold y Archive, y qué pasa financieramente si borrás o cambiás de nivel un blob antes de que transcurra?

**Q3.3** El paso 3 falló con `BlobArchived`. En términos simples, ¿por qué Azure no puede simplemente servir los bytes?

**Q3.4** Elegiste `--rehydrate-priority High`. Compará la rehidratación High y Standard en términos de tiempo esperado y costo, y dá la salvedad sobre el tamaño del objeto.

**Q3.5** El paso 5 puso el valor por defecto de la cuenta en `Cool`. ¿A qué blobs afecta eso, y qué nivel **nunca** puede configurarse como valor por defecto de la cuenta?

**Q3.6** La política de ciclo de vida es gratis de ejecutar, pero las transiciones de nivel no lo son. Nombrá el costo que crea una política ingenua de "archivar todo después de 30 días" para un conjunto de datos de millones de blobs diminutos.

---

## Ejercicio 4 — Redundancia: qué sobrevive a qué

### Pasos

1. Leé la redundancia actual y la región secundaria que Azure emparejó para vos:

   ```bash
   $ az storage account show --name $SA --resource-group $RG \
       --query "{sku:sku.name, primary:primaryLocation, secondary:secondaryLocation, status:statusOfPrimary, secStatus:statusOfSecondary}" \
       --output yaml
   ```

   ```yaml
   primary: eastus
   secStatus: available
   secondary: westus
   sku: Standard_RAGRS
   status: available
   ```

2. Como el SKU es geo-redundante con **acceso de lectura**, existe un segundo endpoint de lectura:

   ```bash
   $ az storage account show --name $SA --resource-group $RG \
       --query secondaryEndpoints.blob --output tsv
   ```

   ```
   https://st900lab1842229517-secondary.blob.core.windows.net/
   ```

3. Verificá cuán atrasada está la secundaria. Ese número es el RPO real:

   ```bash
   $ az storage account show --name $SA --resource-group $RG \
       --query geoReplicationStats --output yaml
   ```

   ```yaml
   canFailover: true
   lastSyncTime: '2026-09-05T09:52:11Z'
   status: Live
   ```

4. Pasá a redundancia de zona y leé el error que enseña la matriz de conversión:

   ```bash
   $ az storage account update --name $SA --resource-group $RG --sku Standard_ZRS --output none
   ```

   ```
   (InvalidAccountTypeConversion) Conversion of storage account SKU from Standard_RAGRS
   to Standard_ZRS is not supported. Convert to Standard_LRS first.
   ```

5. Hacelo en el orden soportado:

   ```bash
   $ az storage account update --name $SA --resource-group $RG --sku Standard_LRS --output none
   $ az storage account update --name $SA --resource-group $RG --sku Standard_ZRS --output none
   $ az storage account show --name $SA --resource-group $RG --query sku.name --output tsv
   ```

   ```
   Standard_ZRS
   ```

6. Confirmá que el endpoint secundario desapareció junto con la geo-redundancia:

   ```bash
   $ az storage account show --name $SA --resource-group $RG --query secondaryEndpoints --output tsv
   ```

   ```

   ```

7. Volvé a redundancia geo + de zona para el resto del laboratorio:

   ```bash
   $ az storage account update --name $SA --resource-group $RG --sku Standard_GZRS --output none
   ```

### Verificá lo que entendiste — bloque 4

**Q4.1** Completá esta tabla de memoria, después verificala contra la documentación:

| Opción | Copias en la primaria | Distribuidas en | Copias en la secundaria | ¿Secundaria legible? |
|---|---|---|---|---|
| LRS | | | | |
| ZRS | | | | |
| GRS | | | | |
| GZRS | | | | |
| RA-GRS | | | | |
| RA-GZRS | | | | |

**Q4.2** Un único rack pierde la alimentación en el datacenter. ¿Qué opciones mantienen los datos disponibles? Una zona de disponibilidad entera se inunda. ¿Qué opciones mantienen los datos disponibles? La región completa está fuera de línea. ¿Qué opciones siguen conservando una copia?

**Q4.3** La geo-replicación es asincrónica. Usando `lastSyncTime` del paso 3, explicá en una oración qué puede perder un cliente en una conmutación por error regional no planificada.

**Q4.4** ¿Por qué el SDK de una cuenta RA-GRS no escribe automáticamente en el endpoint secundario cuando la primaria está caída?

**Q4.5** Las cuentas de almacenamiento premium (premium block blob, premium file shares) no ofrecen GRS ni GZRS. Dado eso, ¿cómo construirías protección entre regiones para una carga de trabajo premium?

**Q4.6** La redundancia *no* es backup. Dá un fallo contra el que ni LRS ni RA-GZRS ni nada intermedio protege, y nombrá la característica de blob que sí lo hace.

---

## Ejercicio 5 — Azure Files, Queues y Tables en una sola cuenta

### Pasos

1. Creá un recurso compartido de archivos SMB con una cuota:

   ```bash
   $ az storage share-rm create \
       --resource-group $RG --storage-account $SA \
       --name projectdata --quota 100 \
       --output table
   ```

   ```
   AccessTier    EnabledProtocols    Name         Quota    ResourceGroup
   ------------  ------------------  -----------  -------  ----------------
   TransactionOptimized  SMB         projectdata  100      rg-az900-storage
   ```

2. Leé la cadena de montaje que Azure le entregaría a un cliente Windows o Linux:

   ```bash
   $ echo "//$SA.file.core.windows.net/projectdata"
   ```

   ```
   //st900lab1842229517.file.core.windows.net/projectdata
   ```

   En Linux esto se convierte en `mount -t cifs //<account>.file.core.windows.net/projectdata /mnt/share -o vers=3.1.1,...`. En Windows es `net use Z: \\<account>.file.core.windows.net\projectdata`. Ambos requieren **TCP 445 saliente**, que la mayoría de los ISPs y muchos firewalls corporativos bloquean — el caso de soporte más común de Azure Files.

3. Creá una cola y empujá un mensaje:

   ```bash
   $ az storage queue create --name orders --account-name $SA --auth-mode login --output none
   $ az storage message put --queue-name orders \
       --content '{"orderId":"A-1042","action":"ship"}' \
       --account-name $SA --auth-mode login --output none
   ```

4. Espiá el mensaje sin consumirlo, después leelo como corresponde:

   ```bash
   $ az storage message peek --queue-name orders --account-name $SA --auth-mode login \
       --query "[].{id:id, dequeues:dequeueCount, content:content}" --output table
   ```

   ```
   Id                                    Dequeues    Content
   ------------------------------------  ----------  ------------------------------------
   9d3b1f2e-5a44-4c0e-9b7c-1e2f3a4b5c6d  0           {"orderId":"A-1042","action":"ship"}
   ```

   ```bash
   $ az storage message get --queue-name orders --visibility-timeout 30 \
       --account-name $SA --auth-mode login \
       --query "[].{id:id, pop:popReceipt}" --output yaml
   ```

   ```yaml
   - id: 9d3b1f2e-5a44-4c0e-9b7c-1e2f3a4b5c6d
     pop: AgAAAAMAAAAAAAAAr1Zw...
   ```

5. Creá una tabla e insertá una entidad con una clave compuesta explícita:

   ```bash
   $ az storage table create --name devices --account-name $SA --auth-mode login --output none
   $ az storage entity insert --table-name devices \
       --entity PartitionKey=warehouse-01 RowKey=sensor-7 temperature=21.4 status=online \
       --account-name $SA --auth-mode login --output none
   $ az storage entity query --table-name devices \
       --filter "PartitionKey eq 'warehouse-01'" \
       --account-name $SA --auth-mode login \
       --query "items[].{pk:PartitionKey, rk:RowKey, t:temperature, s:status}" --output table
   ```

   ```
   Pk            Rk        T     S
   ------------  --------  ----  ------
   warehouse-01  sensor-7  21.4  online
   ```

6. Confirmá que los cuatro servicios viven en la misma cuenta y comparten su configuración de redundancia:

   ```bash
   $ az storage account show --name $SA --resource-group $RG \
       --query "{sku:sku.name, endpoints:primaryEndpoints}" --output yaml
   ```

### Verificá lo que entendiste — bloque 5

**Q5.1** Para cada uno de Blob, Files, Queue y Table, dá el protocolo de acceso y la carga de trabajo, en una oración, para la que fue diseñado.

**Q5.2** Cambiaste el SKU de la cuenta a GZRS en el Ejercicio 4. ¿El recurso compartido `projectdata` hereda esa redundancia, o se configura por separado?

**Q5.3** Dos equipos discuten: uno quiere Azure Files para una unidad compartida de una aplicación migrada tal cual (lift-and-shift), el otro quiere Blob storage con un cliente montado. ¿Cuál tiene razón y cuál es el motivo técnico decisivo?

**Q5.4** El mensaje en cola del paso 4 tiene un `dequeueCount` y un `popReceipt`, y `get` tomó un `--visibility-timeout 30`. Describí qué pasa si el consumidor se cae 10 segundos después de leer, y qué problema resuelve ese mecanismo.

**Q5.5** Table storage exigió tanto `PartitionKey` como `RowKey`. ¿Para qué sirve cada uno, y qué garantiza el par?

**Q5.6** Un desarrollador propone Table storage para una nueva aplicación global que necesita latencia de milisegundos de un solo dígito y escrituras multi-región. ¿Qué servicio de Azure debería usar en su lugar, y cuál es la fricción de la migración?

---

## Ejercicio 6 — Discos administrados: el servicio de almacenamiento que no está en una cuenta de almacenamiento

### Pasos

1. Creá un disco administrado independiente:

   ```bash
   $ az disk create \
       --resource-group $RG --name disk-data-01 \
       --size-gb 128 --sku StandardSSD_LRS \
       --output table
   ```

   ```
   DiskSizeGb    Location    Name          ProvisioningState    ResourceGroup     Sku
   ------------  ----------  ------------  -------------------  ----------------  ---------------
   128           eastus      disk-data-01  Succeeded            rg-az900-storage  StandardSSD_LRS
   ```

2. Buscalo dentro de la cuenta de almacenamiento que construiste:

   ```bash
   $ az storage container list --account-name $SA --auth-mode login --query "[].name" --output tsv
   ```

   ```
   media
   ```

   El disco no está por ningún lado ahí.

3. Confirmá que el disco es su propio tipo de recurso de ARM:

   ```bash
   $ az resource list --resource-group $RG --query "[].{name:name, type:type}" --output table
   ```

   ```
   Name                Type
   ------------------  ---------------------------------
   st900lab1842229517  Microsoft.Storage/storageAccounts
   disk-data-01        Microsoft.Compute/disks
   ```

4. Compará los niveles de rendimiento disponibles:

   ```bash
   $ az disk create --resource-group $RG --name disk-test --size-gb 4 --sku UltraSSD_LRS --output none
   ```

   ```
   (BadRequest) UltraSSD disks can only be created in an availability zone that supports them,
   and require the UltraSSDEnabled property on the VM.
   ```

5. Leé las opciones de SKU del disco y su redundancia:

   ```bash
   $ az disk show --resource-group $RG --name disk-data-01 \
       --query "{sku:sku.name, tier:sku.tier, size:diskSizeGb, state:diskState}" --output yaml
   ```

   ```yaml
   size: 128
   sku: StandardSSD_LRS
   state: Unattached
   tier: Standard
   ```

### Verificá lo que entendiste — bloque 6

**Q6.1** El objetivo del examen lista "discos" entre los servicios de almacenamiento de Azure, y sin embargo `disk-data-01` es `Microsoft.Compute/disks`. Explicá qué administra un disco *administrado*, y qué era un disco *no administrado*.

**Q6.2** Ordená Standard HDD, Standard SSD, Premium SSD, Premium SSD v2 y Ultra Disk por rendimiento, y nombrá la señal de carga de trabajo que debería empujarte a subir un nivel.

**Q6.3** El disco muestra `StandardSSD_LRS` y estado `Unattached`. ¿Está facturando? ¿Están sus datos protegidos contra un fallo de zona?

**Q6.4** Se borra una VM pero no su disco de datos. ¿Qué pasa con los datos, y qué te dice eso sobre el ciclo de vida del disco respecto del de la VM?

**Q6.5** En una oración cada uno, ¿cuándo elegís un disco administrado versus Azure Files versus Blob storage para los mismos 500 GB de datos?

---

## Ejercicio 7 — Mover datos hacia adentro: AzCopy, Storage Explorer, File Sync

### Pasos

1. AzCopy viene preinstalado en Cloud Shell. Confirmalo y autenticate:

   ```bash
   $ azcopy --version
   ```

   ```
   azcopy version 10.27.1
   ```

   ```bash
   $ azcopy login --identity     # in Cloud Shell; use `azcopy login` interactively elsewhere
   ```

2. Construí un árbol de origen chico y copialo recursivamente:

   ```bash
   $ mkdir -p upload/2026/{01,02}
   $ for i in 1 2 3; do head -c 512K /dev/urandom > upload/2026/01/file$i.dat; done
   $ for i in 4 5;   do head -c 512K /dev/urandom > upload/2026/02/file$i.dat; done
   $ azcopy copy "upload" "https://$SA.blob.core.windows.net/media/" --recursive
   ```

   ```
   INFO: Scanning...
   Job 6f0a2c11-... has started
   
   Elapsed Time (Minutes): 0.1001
   Number of File Transfers: 5
   Number of Folder Property Transfers: 0
   Total Number of Transfers: 5
   Number of Transfers Completed: 5
   Number of Transfers Failed: 0
   Number of Transfers Skipped: 0
   TotalBytesTransferred: 2621440
   Final Job Status: Completed
   ```

3. Cambiá un archivo y ejecutá `sync` en vez de `copy`. Leé los contadores con atención:

   ```bash
   $ head -c 512K /dev/urandom > upload/2026/01/file2.dat
   $ azcopy sync "upload" "https://$SA.blob.core.windows.net/media/upload" --recursive
   ```

   ```
   INFO: Any empty folders will not be processed...
   Job 8b31d904-... has started
   
   Files Scanned at Source: 5
   Files Scanned at Destination: 5
   Number of Copy Transfers for Files: 1
   Number of Deletions at Destination: 0
   Total Number of Transfers: 1
   Number of Transfers Completed: 1
   Final Job Status: Completed
   ```

4. Inspeccioná un trabajo completado — AzCopy guarda un archivo de plan reanudable:

   ```bash
   $ azcopy jobs list --output-type text | head -20
   ```

   ```
   JobId: 8b31d904-...
   Start Time: Saturday, 05 Sep 2026 10:14:32
   Status: Completed
   Command: sync upload https://st900lab1842229517.blob.core.windows.net/media/upload --recursive
   ```

5. **Razoná, no ejecutés.** Leé las descripciones de las dos herramientas GUI/agente y respondé las preguntas de abajo.

   - **Azure Storage Explorer** — una aplicación de escritorio independiente y gratuita (Windows, macOS, Linux) que navega blobs, recursos compartidos de archivos, colas, tablas y Data Lake a través de múltiples cuentas y suscripciones, con subida por arrastrar y soltar. Usa AzCopy por debajo para las transferencias masivas. Es interactiva e impulsada por humanos; no es programable en un cronograma.
   - **Azure File Sync** — un agente instalado en **Windows Server** que registra el servidor con un recurso *Storage Sync Service*. Un *sync group* une un **cloud endpoint** (un recurso compartido de archivos de Azure) con uno o más **server endpoints** (rutas en servidores registrados). Con **cloud tiering** habilitado, los archivos fríos se reemplazan en el servidor por punteros y sus bytes viven sólo en Azure; el servidor mantiene una caché local dimensionada por una política de espacio libre o de fecha.

### Verificá lo que entendiste — bloque 7

**Q7.1** En el paso 3, `sync` transfirió 1 archivo donde `copy` habría transferido 5. Explicá la diferencia entre `azcopy copy` y `azcopy sync`, incluyendo el comportamiento destructivo que `sync` puede tener y `copy` nunca.

**Q7.2** Para cada escenario, elegí AzCopy, Storage Explorer, Azure File Sync o Data Box, y justificá en una oración:
  a. Un trabajo cron nocturno que empuja 40 GB de artefactos de compilación a un contenedor.
  b. Un ingeniero verificando puntualmente si un blob se subió correctamente, a través de tres suscripciones.
  c. Un servidor de archivos Windows de una sucursal cuyo recurso compartido de 8 TB debe centralizarse en Azure mientras el personal conserva su ruta UNC `\\fileserver\share`.
  d. Un archivo de video de 60 TB on-premises detrás de un enlace de 100 Mbps.

**Q7.3** En Azure File Sync, ¿qué queda exactamente en el servidor para un archivo con nivel en la nube (tiered), y qué experimenta el usuario cuando lo abre?

**Q7.4** Storage Explorer "usa AzCopy por debajo". ¿Por qué importa eso cuando estás decidiendo cuál poner en un runbook?

**Q7.5** AzCopy se autenticó con `azcopy login`. ¿Cuál es el otro método de autorización común para AzCopy, y cuál es su principal riesgo operativo?

---

## Ejercicio 8 — Migración: dimensionar la decisión, no la herramienta

Este bloque es aritmética y criterio. Sin comandos.

### Pasos

1. Calculá cuánto tarda una transferencia en línea. Usá:

   ```
   hours = (size_TB × 8 × 1000 × 1000) / (Mbps × 3600 × utilisation)
   ```

2. Completá la tabla. Asumí un 70 % de utilización efectiva del enlace (una cifra realista una vez que tenés en cuenta el overhead de TCP, la contención y la limitación en horario laboral):

   | Conjunto de datos | Enlace | Horas | Días |
   |---|---|---|---|
   | 5 TB | 1 Gbps | | |
   | 50 TB | 500 Mbps | | |
   | 500 TB | 1 Gbps | | |

3. Emparejá cada resultado con un miembro de la familia Azure Data Box:

   | Producto | Capacidad bruta | Capacidad utilizable | Formato |
   |---|---|---|---|
   | Data Box Disk | 8 TB por pedido (hasta 5 SSDs, 40 TB) | ~35 TB | Discos de estado sólido, enviados a vos |
   | Data Box | 100 TB | ~80 TB | Appliance ruggedizado de un solo nodo |
   | Data Box Heavy | 1 PB | ~770 TB | Appliance a escala de rack, entregado con plataforma elevadora |

   Notá que también existe una rama **online** de la familia — Data Box Gateway (un appliance virtual) y Azure Stack Edge (uno físico) — que transmiten continuamente a Azure en vez de enviarse físicamente.

4. Leé el rol de Azure Migrate: un **hub** que descubre, evalúa y migra servidores, bases de datos, aplicaciones web y datos on-premises. Para almacenamiento en particular, su salida de evaluación te dice qué discos y recursos compartidos existen, qué tamaño tienen y cuánto costarían en Azure — es la superficie de planificación que te dice *si* necesitás un Data Box siquiera.

### Verificá lo que entendiste — bloque 8

**Q8.1** Dá las tres duraciones calculadas del paso 2 (horas y días). ¿Cuál de las tres es claramente un caso de Data Box, y cuál claramente no?

**Q8.2** ¿Por qué la "capacidad utilizable" es menor que la "capacidad bruta" en todos los productos Data Box, y por qué le importa al examen?

**Q8.3** Un Data Box tarda aproximadamente 10 días de punta a punta (envío de ida, copia, envío de vuelta, ingesta). Para la fila de 50 TB / 500 Mbps, compará eso contra la cifra online — y nombrá el factor *no temporal* que aun así podría empujarte a la transferencia online.

**Q8.4** Los datos se escriben en un Data Box en tu datacenter y el appliance se envía por mensajería a un datacenter de Microsoft. Indicá las dos protecciones que hacen esto aceptable para un equipo de seguridad.

**Q8.5** ¿Cuál es la relación de Azure Migrate con Data Box — competidor, requisito previo o complemento? Justificá.

**Q8.6** Un equipo con 3 TB en un enlace de 1 Gbps pide un Data Box "por las dudas". ¿Cuál es el argumento en contra, en una oración?

---

## Ejercicio 9 — Diagnóstico, y después limpieza

### Pasos

1. Producí deliberadamente los cuatro errores que vas a encontrar en producción. Leé cada uno antes de seguir.

   **a. Endpoint equivocado:**

   ```bash
   $ curl -s -o /dev/null -w "%{http_code}\n" https://$SA.blob.core.windows.net/media/report.bin
   ```

   ```
   404
   ```

   El acceso público está deshabilitado, así que una lectura anónima devuelve `404`, **no** `403` — Azure oculta deliberadamente la existencia del recurso.

   **b. SAS vencida o malformada:**

   ```bash
   $ SAS=$(az storage container generate-sas --name media --account-name $SA \
       --permissions r --expiry 2020-01-01T00:00Z --auth-mode login --as-user --output tsv 2>/dev/null)
   $ curl -s "https://$SA.blob.core.windows.net/media/report.bin?$SAS" | head -3
   ```

   ```xml
   <?xml version="1.0" encoding="utf-8"?>
   <Error><Code>AuthenticationFailed</Code>
   <Message>Signature not valid in the specified time frame</Message></Error>
   ```

   **c. Violación de nombre:**

   ```bash
   $ az storage account create --name "MyStorageAccount_2026" --resource-group $RG --location $LOC
   ```

   ```
   (AccountNameInvalid) The specified account name is not valid.
   ```

   **d. Violación de nivel** — viste `BlobArchived` en el Ejercicio 3. Releelo ahora con la escalera de niveles en mente.

2. Verificá el consumo real de la cuenta antes de borrarla:

   ```bash
   $ az storage account show-usage --location $LOC --output table
   $ az storage blob list --container-name media --account-name $SA --auth-mode login \
       --query "sum([].properties.contentLength)" --output tsv
   ```

   ```
   5244440
   ```

3. **Limpiá. No te saltees esto.**

   ```bash
   $ az group delete --name $RG --yes --no-wait
   $ az group exists --name $RG
   ```

   ```
   true      # returns false once the async delete finishes, typically 2-5 minutes
   ```

4. Verificá que la asignación de rol que creaste en el Ejercicio 2 se eliminó junto con el ámbito:

   ```bash
   $ az role assignment list --assignee $ME --scope $SCOPE --output table
   ```

   ```
   []
   ```

### Verificá lo que entendiste — bloque 9

**Q9.1** El paso 1a devolvió `404` en vez de `403` para un blob que existe con certeza. ¿Por qué ese es el diseño más seguro?

**Q9.2** Una SAS otorga acceso sin una identidad de Entra ID. Nombrá las dos cosas que toda SAS lleva y que una asignación de rol no, y la única cosa que no podés hacerle a una SAS ya emitida derivada de una clave de cuenta.

**Q9.3** Borrar el grupo de recursos eliminó la cuenta de almacenamiento y el disco en una sola llamada. ¿Cuál es la única característica de blob que podría haber hecho que los *blobs* sobrevivieran a un borrado accidental — y habría sobrevivido a este comando en particular?

**Q9.4** Resumí, para el examen: cuáles de estas decisiones quedan fijas al crear la cuenta y cuáles se pueden cambiar después — región, redundancia, nivel de rendimiento (standard/premium), tipo de cuenta, nivel de acceso, espacio de nombres jerárquico.

---

## Fuentes

- AZ-900 study guide — https://learn.microsoft.com/en-us/credentials/certifications/resources/study-guides/az-900
- Storage account overview — https://learn.microsoft.com/en-us/azure/storage/common/storage-account-overview
- Data redundancy — https://learn.microsoft.com/en-us/azure/storage/common/storage-redundancy
- Disaster recovery and account failover — https://learn.microsoft.com/en-us/azure/storage/common/storage-disaster-recovery-guidance
- Blob access tiers — https://learn.microsoft.com/en-us/azure/storage/blobs/access-tiers-overview
- Archive rehydration — https://learn.microsoft.com/en-us/azure/storage/blobs/archive-rehydrate-overview
- Lifecycle management — https://learn.microsoft.com/en-us/azure/storage/blobs/lifecycle-management-overview
- Azure Files introduction — https://learn.microsoft.com/en-us/azure/storage/files/storage-files-introduction
- Azure File Sync introduction — https://learn.microsoft.com/en-us/azure/storage/file-sync/file-sync-introduction
- Queue Storage introduction — https://learn.microsoft.com/en-us/azure/storage/queues/storage-queues-introduction
- Table Storage overview — https://learn.microsoft.com/en-us/azure/storage/tables/table-storage-overview
- Managed disks overview — https://learn.microsoft.com/en-us/azure/virtual-machines/managed-disks-overview
- AzCopy v10 — https://learn.microsoft.com/en-us/azure/storage/common/storage-use-azcopy-v10
- Storage Explorer — https://learn.microsoft.com/en-us/azure/storage/storage-explorer/vs-azure-tools-storage-manage-with-storage-explorer
- Azure Data Box overview — https://learn.microsoft.com/en-us/azure/databox/data-box-overview
- Azure Migrate overview — https://learn.microsoft.com/en-us/azure/migrate/migrate-services-overview
- Authorize access to blobs with Entra ID — https://learn.microsoft.com/en-us/azure/storage/blobs/authorize-access-azure-active-directory

---

<details>
<summary><strong>Respuestas</strong> — abrí sólo después de haber intentado cada bloque</summary>

### Bloque 1 — La cuenta de almacenamiento es el límite

**A1.1** El nombre de la cuenta se convierte en un nombre de host DNS público: `<name>.blob.core.windows.net` y cuatro hermanos. DNS es un único espacio de nombres global, así que la etiqueta debe ser única entre todos los clientes de Azure del mundo. El nombre de una VM es sólo un identificador de recurso de ARM con ámbito en su grupo de recursos; nunca se convierte en un registro DNS público a menos que le adjuntes por separado una IP pública con una etiqueta DNS — y *esa* etiqueta debe entonces ser única dentro de su región.

**A1.2** Una cuenta general-purpose v2 contiene **Blob** (incluyendo Data Lake Gen2), **Files**, **Queue** y **Table**. El servicio que nombra el objetivo del examen y que *no* está en la cuenta es **Disk** — los discos administrados son `Microsoft.Compute/disks`, un tipo de recurso separado (Ejercicio 6).

**A1.3**
- *Riesgo:* RA-GRS cuesta aproximadamente el doble por GB que LRS y replica cada byte a una segunda región. Para datos temporales, entornos de prueba o datos que ya son una réplica de otra cosa, pagás el doble por nada. Además coloca silenciosamente una copia de tus datos en la región emparejada, lo que puede violar un requisito de residencia de datos.
- *Beneficio:* los datos sobreviven a una caída regional completa y siguen siendo legibles desde el endpoint `-secondary` mientras dura, sin que hagas nada.

**A1.4** `allowBlobPublicAccess = false` a nivel de *cuenta* es un interruptor maestro: mientras esté en false, ningún contenedor de la cuenta puede servir solicitudes anónimas sin importar su propia configuración. Para permitir lecturas públicas primero tenés que poner el interruptor de la cuenta en true (`az storage account update --allow-blob-public-access true`), y *después* poner el nivel de acceso público del contenedor en `blob` (blobs legibles, contenedor no listable) o `container` (blobs legibles y listables). El interruptor de la cuenta es una barrera de protección; la configuración del contenedor es la concesión real. Notá que el valor por defecto de la cuenta es `false` para cuentas nuevas desde las versiones de API de 2023 — un cambio deliberado de seguro por defecto.

**A1.5** `dfs` es el endpoint de Data Lake Storage Gen2, que habla una API orientada a sistema de archivos (directorios, renombrado atómico, ACLs estilo POSIX). Aparece listado en toda cuenta StorageV2, pero el verdadero espacio de nombres jerárquico sólo existe si la cuenta se creó con HNS habilitado (`--enable-hierarchical-namespace true`). En esta cuenta no está habilitado, así que las operaciones de directorio contra `dfs` se emulan sobre el espacio de nombres plano en vez de ser nativas. HNS no se puede activar después de la creación sin una migración.

---

### Bloque 2 — Blob storage

**A2.1** El **plano de control** es Azure Resource Manager: crear, configurar y borrar la cuenta, y leer sus propiedades. Owner y Contributor otorgan esto. El **plano de datos** es la API REST de storage: leer y escribir los blobs, mensajes y entidades reales, servidos por `*.blob.core.windows.net` y sus hermanos — ARM no está en absoluto en esa ruta. El acceso al plano de datos necesita o bien una clave de cuenta, o una SAS, o un **rol de datos** de Entra ID. Agregaste **Storage Blob Data Contributor**. (Owner *puede* leer las claves de la cuenta y así llegar a los datos — pero esa es una acción separada y auditable, no lo mismo que tener el rol de datos.)

**A2.2**
- **Block blob** — compuesto por bloques que se suben independientemente y después se confirman. Optimizado para escrituras secuenciales grandes y lecturas del objeto completo. Carga de trabajo canónica: archivos, imágenes, video, backups, logs. Tipo por defecto; hasta ~190.7 TiB.
- **Append blob** — un block blob optimizado para escrituras sólo de anexado; no podés modificar ni borrar bloques existentes. Carga de trabajo canónica: archivos de log y pistas de auditoría escritos por muchos escritores concurrentes.
- **Page blob** — una colección de páginas de 512 bytes que soporta lectura/escritura aleatoria en desplazamientos arbitrarios. Carga de trabajo canónica: archivos VHD, es decir el almacenamiento subyacente de los discos no administrados y la representación interna de los discos administrados. Hasta 8 TiB.

**A2.3** Sólo en el **nombre** del blob. `logs/2026/09/app.log` es una única clave plana que casualmente contiene caracteres `/`. Blob storage no tiene objetos de directorio. El flag `--delimiter "/"` le pide al servicio que agrupe los resultados por el primer `/` y devuelva "prefijos" sintéticos, que es como los portales y las herramientas renderizan un árbol. Borrar la "carpeta" falla porque no hay ningún objeto en esa clave.

**A2.4** Con el espacio de nombres jerárquico habilitado, los directorios son **objetos reales**. `logs/2026/09` existiría, podría borrarse (recursivamente, en una única operación atómica), podría renombrarse atómicamente y podría llevar ACLs POSIX. Esta es la diferencia entre Blob storage y Azure Data Lake Storage Gen2 — misma cuenta, misma familia de endpoints, semántica de espacio de nombres distinta. Los motores de big data (Spark, Databricks, Synapse) dependen del renombrado atómico de directorios, y por eso HNS importa para analítica.

**A2.5** Cuenta → contenedor → blob es una jerarquía estricta de dos niveles: una cuenta contiene contenedores, un contenedor contiene blobs, y un blob no puede existir fuera de un contenedor. Los contenedores no se pueden anidar. Cualquier estructura más profunda se simula con `/` en los nombres de blob (a menos que HNS esté activado).

---

### Bloque 3 — Niveles de acceso

**A3.1** Del más al menos caro **por GB almacenado**: **Hot → Cool → Cold → Archive**. Moviéndose en la dirección opuesta, el **costo de acceso/transacción sube** y la **latencia sube**. Hot tiene las lecturas más baratas y latencia de milisegundos; Archive tiene las lecturas más caras y tarda horas hasta el primer byte porque los datos están offline. Archive es además el único nivel *offline* — Hot, Cool y Cold son todos online.

**A3.2** Retención mínima: **Cool = 30 días, Cold = 90 días, Archive = 180 días.** Borrar, sobrescribir o mover un blob a un nivel distinto antes de que transcurra ese período dispara un **cargo por eliminación temprana**: se te factura a prorrata por los días restantes como si el blob se hubiera quedado. Un blob escrito y borrado después de un día en Archive se factura por 180.

**A3.3** Archive es almacenamiento offline. Los bytes no están en un disco girando detrás de un sistema de archivos — están en medios de bajo costo y alta latencia no conectados a la ruta de servicio en vivo. No hay nada de donde leer hasta que Azure prepara físicamente el objeto de vuelta en almacenamiento online. Las únicas operaciones válidas sobre un blob archivado son obtener/establecer sus metadatos y propiedades, borrarlo e iniciar una rehidratación.

**A3.4**
- **Prioridad High:** típicamente menos de 1 hora para objetos **menores a 10 GB**; los objetos más grandes tardan más y la guía tipo SLA no aplica. Cuesta significativamente más por operación.
- **Prioridad Standard:** hasta **15 horas**. Más barata. Es la opción por defecto.

Dos formas de rehidratar: `set-tier` a un nivel online in situ (el blob sigue archivado y muestra `rehydrate-pending-to-hot` hasta que completa, como viste), o `copy blob` a un blob *nuevo* en un nivel online — lo que deja el original archivado y suele ser la mejor elección en producción porque el origen sigue disponible y podés cancelar borrando la copia.

**A3.5** El nivel por defecto a nivel de cuenta aplica **sólo a los blobs subidos después que no especifiquen un nivel explícitamente** — y a los blobs que estaban infiriendo el valor por defecto de la cuenta en vez de llevar un nivel explícito. Nunca re-nivela retroactivamente blobs con un nivel explícito establecido. **Archive nunca puede ser un valor por defecto de la cuenta**; es un nivel exclusivo de blob. Hot, Cool y Cold pueden ser todos valores por defecto de la cuenta.

**A3.6** Toda transición de nivel es una **operación de escritura**, facturada por cada 10.000 operaciones, y las transiciones *hacia* Cool/Cold/Archive se facturan a la tarifa de escritura más alta de "acceso infrecuente". Para millones de blobs pequeños, los cargos por transacción pueden superar directamente el ahorro de almacenamiento — sobre todo porque el ahorro por GB de Archive en un blob de 4 KB es una fracción de un centavo mientras que la operación de transición no lo es. Regla general: nivelá por tamaño y patrón de acceso, no sólo por antigüedad. Las políticas de ciclo de vida soportan `blobIndexMatch` y filtros de prefijo precisamente para que puedas excluir objetos pequeños.

---

### Bloque 4 — Redundancia

**A4.1**

| Opción | Copias en la primaria | Distribuidas en | Copias en la secundaria | ¿Secundaria legible? |
|---|---|---|---|---|
| LRS | 3 | 3 dominios de fallo en **un** datacenter/ubicación física | 0 | n/a |
| ZRS | 3 | 3 **zonas de disponibilidad** en la región | 0 | n/a |
| GRS | 3 | 1 datacenter (LRS localmente) | 3 (LRS en la región emparejada) | **No** |
| GZRS | 3 | 3 zonas de disponibilidad | 3 (LRS en la región emparejada) | **No** |
| RA-GRS | 3 | 1 datacenter | 3 | **Sí** |
| RA-GZRS | 3 | 3 zonas de disponibilidad | 3 | **Sí** |

Cifras de durabilidad que Microsoft publica a lo largo de un año: LRS ≈ 11 nueves, ZRS ≈ 12 nueves, GRS/GZRS ≈ 16 nueves.

**A4.2**
- **Fallo de rack:** las seis opciones lo sobreviven. Incluso LRS distribuye sus tres copias en dominios de fallo (racks) separados dentro de la instalación.
- **Pérdida de zona de disponibilidad:** **ZRS, GZRS, RA-GZRS** siguen disponibles. LRS desaparece si estaba en esa zona. GRS/RA-GRS pierden la primaria — RA-GRS todavía puede *leer* desde la secundaria, GRS no puede sin una conmutación por error.
- **Pérdida de la región completa:** sólo las opciones geo — **GRS, GZRS, RA-GRS, RA-GZRS** — siguen conservando una copia.

**A4.3** Todo lo escrito en la primaria después de `lastSyncTime` todavía no había llegado a la secundaria, así que una conmutación por error no planificada lo pierde permanentemente. Por eso `lastSyncTime` es el RPO concreto y observable en ese momento — típicamente minutos, pero nunca cero y nunca garantizado.

**A4.4** La secundaria es **de sólo lectura por diseño**. Permitir escrituras en ambas regiones mientras la replicación es asincrónica crearía copias divergentes e irreconciliables. La secundaria sólo se vuelve escribible después de que una conmutación por error la promueve a primaria. Notá los dos tipos de conmutación: una conmutación **no planificada** acepta la pérdida de datos descrita en A4.3 y (en su forma clásica) deja la cuenta como LRS en la nueva primaria, así que después tenés que reconfigurar la geo-redundancia; una **conmutación planificada administrada por el cliente** requiere una primaria sana, tiene cero pérdida de datos porque espera a que la replicación termine, e intercambia los roles conservando la configuración de redundancia.

**A4.5** Replicá en la capa de aplicación o de datos en vez de en la capa de almacenamiento:
- **Object replication** para block blobs — una copia asincrónica basada en reglas desde una cuenta de origen a una cuenta de destino, que puede estar en otra región.
- Una segunda cuenta en la región emparejada más un trabajo de AzCopy/Data Factory.
- Para recursos compartidos de archivos premium, **Azure Backup** para file shares, o una sincronización a nivel de aplicación.
El compromiso es que ahora sos dueño de la lógica de replicación, de su monitoreo y de su RPO.

**A4.6** Las seis protegen contra fallos de **infraestructura**. Ninguna protege contra un fallo **lógico**: un borrado accidental o malicioso, un bug de aplicación que sobrescribe datos buenos, o ransomware. El borrado se replica fielmente a todas las copias. Las mitigaciones son **soft delete** (a nivel de blob y de contenedor, recuperable dentro de una ventana de retención), **versionado de blobs** (cada sobrescritura conserva la versión anterior), **restauración a un punto en el tiempo**, **almacenamiento inmutable** con políticas basadas en tiempo o retención legal (WORM), y **Azure Backup**. La redundancia es disponibilidad; estas son recuperabilidad.

---

### Bloque 5 — Files, Queues, Tables

**A5.1**
- **Blob** — REST HTTP/HTTPS (y `dfs` para Data Lake). Almacenamiento de objetos no estructurados para cualquier cosa leída por una aplicación o servida por la web: medios, backups, logs, conjuntos de datos, sitios estáticos.
- **Files** — **SMB 3.x** (Windows/Linux/macOS) y **NFS 4.1** (sólo cuentas premium/FileStorage), más una API REST. Un recurso compartido de archivos en red totalmente administrado que puede montarse con una letra de unidad o un punto de montaje, para aplicaciones lift-and-shift y configuración o herramientas compartidas.
- **Queue** — REST HTTP/HTTPS. Mensajería durable, de al-menos-una-vez, que desacopla productores de consumidores y absorbe picos de carga. Mensajes de hasta **64 KiB**.
- **Table** — REST HTTP/HTTPS (OData). Un almacén NoSQL sin esquema, clave-valor / columna ancha, para grandes volúmenes de datos estructurados no relacionales consultados por clave. Entidades de hasta **1 MiB** y 255 propiedades.

**A5.2** La **hereda**. La redundancia es una propiedad a nivel de cuenta, así que el recurso compartido de archivos, los contenedores, la cola y la tabla de esta cuenta son todos GZRS. Eso es exactamente por qué la cuenta es el límite del Ejercicio 1: no podés hacer que un share sea LRS y un contenedor GZRS dentro de la misma cuenta. Redundancia distinta significa cuenta distinta. (Salvedad: los recursos compartidos de archivos estándar de más de 5 TiB han tenido históricamente restricciones de redundancia — revisá la matriz de soporte actual para large file shares.)

**A5.3** **Azure Files** es lo correcto. La razón decisiva: la aplicación espera un **sistema de archivos** — una ruta montada, escrituras por rango de bytes, bloqueo de archivos, semántica POSIX/NTFS y una ruta UNC o letra de unidad contra la que fue compilada. Blob storage es un almacén de objetos; `blobfuse` o similar puede presentarlo como un montaje pero no provee bloqueo de archivos real ni escrituras parciales eficientes, y se comporta mal bajo acceso concurrente. Si el código de la aplicación puede cambiarse para llamar a la API de blob, Blob es más barato y escala más. Si no puede, Files es la respuesta. Ese es el criterio de lift-and-shift.

**A5.4** `get` hace el mensaje **invisible** para otros consumidores durante el tiempo de visibilidad (30 s acá) pero **no** lo borra. Borrarlo requiere una segunda llamada con el `popReceipt` como prueba de que lo tenías. Si el consumidor se cae en t+10 s, el mensaje vuelve a ser visible en t+30 s, otro consumidor lo toma, y `dequeueCount` incrementa a 2. Esto da **entrega al menos una vez**: ningún mensaje se pierde por la caída de un consumidor. La consecuencia para la que tenés que diseñar es que un mensaje puede procesarse dos veces, así que los manejadores deberían ser idempotentes. `dequeueCount` es además cómo detectás un **mensaje envenenado** — uno que hace caer repetidamente a su consumidor — y lo enrutás a una cola de mensajes fallidos después de N intentos.

**A5.5**
- **PartitionKey** — determina en qué partición (y por lo tanto en qué servidor físico de partición) vive la entidad. Es la unidad de escalado horizontal y la unidad del ámbito transaccional: las transacciones de grupo de entidades sólo funcionan dentro de una única partición.
- **RowKey** — identifica de forma única a la entidad dentro de su partición. Las entidades se almacenan ordenadas por RowKey, así que las consultas por rango sobre RowKey dentro de una partición son eficientes.

Juntos, el par es la **clave primaria** y se garantiza único en toda la tabla; también es el único índice. Una consulta que filtra por ambos es una búsqueda puntual; una consulta sólo por PartitionKey es un escaneo de partición; una consulta por ninguno de los dos es un escaneo completo de la tabla.

**A5.6** **Azure Cosmos DB for Table** (la API de Table). Ofrece distribución global llave en mano con escrituras multi-región, latencia de milisegundos de un solo dígito respaldada por SLAs, indexación secundaria automática sobre cada propiedad y cinco niveles de consistencia ajustables — nada de lo cual tiene Table storage. La fricción de migración es deliberadamente baja: el protocolo de cable y los SDKs son compatibles, así que es en gran medida un cambio de cadena de conexión. La fricción real es el **modelo de costos** — Cosmos DB factura unidades de solicitud aprovisionadas o serverless, lo que es muchísimo más caro que el precio por GB y por transacción de Table storage, y un diseño de clave de partición que estaba bien a escala de Table storage puede convertirse en una partición caliente cara en Cosmos.

---

### Bloque 6 — Discos administrados

**A6.1** Un disco administrado sigue siendo, por debajo, un **page blob** — pero Azure es dueño de la cuenta de almacenamiento donde vive, y vos nunca la ves. Lo que está "administrado" es exactamente eso: Microsoft se encarga de la ubicación de la cuenta, los límites de IOPS/rendimiento, la distribución en dominios de fallo y el escalado. Un **disco no administrado** (el modelo previo a 2017, ya retirado para nuevas implementaciones) requería que vos crearas y administraras la cuenta de almacenamiento, lo que significaba que podías poner accidentalmente todos los discos de un availability set en una única cuenta y convertirla en un único punto de fallo — y tenías que llevar la cuenta a mano del techo de IOPS por cuenta (20.000). Los discos administrados eliminaron ambos modos de fallo.

**A6.2** Del más lento al más rápido: **Standard HDD → Standard SSD → Premium SSD → Premium SSD v2 → Ultra Disk.**
La señal que debería empujarte a subir un nivel son los **requisitos de IOPS y latencia**, no la capacidad. Los destinos de backup y dev/test toleran Standard HDD. Los servidores web y la producción de uso ligero van en Standard SSD. Las bases de datos de producción y cualquier cosa sensible a la latencia necesitan Premium SSD. Premium SSD v2 y Ultra Disk te dejan aprovisionar IOPS y rendimiento **independientemente del tamaño del disco**, y ese es el indicio: si necesitás 20.000 IOPS en un volumen de 100 GB, los niveles más viejos te obligan a comprar capacidad de más para obtener rendimiento, y v2/Ultra no. Ultra además soporta latencia de submilisegundo y redimensionado del rendimiento en vivo, a costa de restricciones de zona/VM (como mostró el paso 4) y de no tener paridad de soporte para snapshots.

**A6.3** **Sí, está facturando.** Los discos administrados se facturan por capacidad **aprovisionada**, no consumida, y estar `Unattached` no cambia nada — un disco huérfano tras borrar una VM es una de las fuentes más comunes de gasto sorpresa en Azure. En cuanto al fallo de zona: `StandardSSD_LRS` es localmente redundante, así que **no**, no está protegido contra la pérdida de una zona de disponibilidad. `StandardSSD_ZRS` sí lo estaría. Ultra Disk y Premium SSD v2 son sólo LRS.

**A6.4** Los datos **sobreviven intactos**. Un disco administrado es un recurso de ARM independiente con su propio ciclo de vida; una VM meramente lo referencia. Borrar la VM borra el disco de sistema operativo sólo si el `deleteOption` de ese disco está en `Delete` (el valor por defecto del portal para el disco de SO en versiones recientes), y los discos de datos por defecto quedan **desconectados y conservados** a menos que optes explícitamente por el borrado en cascada. En la práctica esto significa que (a) podés volver a conectar el disco a una VM nueva y recuperar los datos, y (b) tenés que auditar discos huérfanos o vas a pagarlos para siempre.

**A6.5**
- **Disco administrado** — cuando exactamente una VM lo necesita como dispositivo de bloques: el volumen del SO, los archivos de datos de una base de datos, cualquier cosa que requiera semántica de bloques cruda y garantías de rendimiento por VM.
- **Azure Files** — cuando varias máquinas o personas necesitan los *mismos* datos a través de una ruta de sistema de archivos simultáneamente: una unidad de aplicación compartida, directorios personales de usuarios, un share de configuración para un scale set.
- **Blob storage** — cuando los datos son objetos consumidos por una aplicación sobre HTTP y no se necesita semántica de sistema de archivos: medios, backups, conjuntos de datos, contenido estático. El más barato por amplio margen y el único con nivel Archive.

---

### Bloque 7 — Mover datos hacia adentro

**A7.1** `copy` transfiere cada elemento de origen incondicionalmente (o los omite según `--overwrite`), produciendo un empuje unidireccional. `sync` primero enumera **ambos** lados, compara marcas de tiempo de última modificación y tamaños, y transfiere sólo las diferencias — por eso movió un archivo. El comportamiento destructivo es `--delete-destination`: `sync` puede **borrar archivos en el destino que ya no existen en el origen**, haciendo del destino un espejo. `copy` nunca borra nada. Ejecutá `sync --delete-destination=prompt` antes de correrlo alguna vez con `=true` en un script.

**A7.2**
- **a. AzCopy.** Es un binario de línea de comandos, programable en scripts, reanudable gracias a su archivo de plan de trabajo, y maneja concurrencia y reintentos. Storage Explorer no puede programarse en un cronograma.
- **b. Azure Storage Explorer.** Navegación interactiva, multi-cuenta y multi-suscripción con una GUI. Este es exactamente el caso de la verificación puntual humana; scriptearlo sería más trabajo que la tarea.
- **c. Azure File Sync.** Mantiene el Windows Server on-premises como punto de acceso (el personal conserva `\\fileserver\share`) mientras la copia autoritativa vive en un recurso compartido de archivos de Azure, y el cloud tiering significa que los 8 TB no necesitan 8 TB de disco local. AzCopy sería una copia de una sola vez sin sincronización continua y no preservaría la ruta de acceso UNC.
- **d. Azure Data Box.** 60 TB sobre 100 Mbps al 70 % de utilización son aproximadamente 1.900 horas ≈ 79 días. Un Data Box (100 TB brutos / ~80 TB utilizables) convierte eso en unos 10 días incluyendo el envío.

**A7.3** En el servidor quedan los **metadatos del archivo y un puntero disperso (un punto de reanálisis / reparse point)** — el archivo aparece en el Explorador con su nombre, tamaño, marcas de tiempo y permisos correctos, y está marcado como offline. Cuando un usuario lo abre, el driver de filtro de File Sync recupera de forma transparente los bytes desde el recurso compartido de archivos de Azure. El usuario ve una demora proporcional al tamaño del archivo y a la velocidad del enlace, y después el archivo abre normalmente. Las aplicaciones que escanean o indexan cada archivo (algunos escáneres antivirus, agentes de backup, indexadores de búsqueda) van a recuperar el conjunto de datos entero y anular el tiering — excluirlas es práctica estándar.

**A7.4** Porque significa que Storage Explorer hereda el rendimiento y la semántica de transferencia de AzCopy pero agrega una GUI y un inicio de sesión interactivo que un runbook no puede manejar. Si lo que necesitás es el comportamiento de transferencia, llamá a AzCopy directamente: es headless, scripteable, sale con un código de estado y registra en un archivo de plan que podés consultar con `azcopy jobs`. Poner una GUI de escritorio en una ruta de automatización es el antipatrón.

**A7.5** Una **firma de acceso compartido (SAS)** anexada a la URL de destino. Su principal riesgo operativo es que la SAS es un **token al portador dentro de una URL**: cualquiera que la obtenga tiene exactamente sus permisos hasta que vence, aparece en el historial de la shell, en los listados de procesos y en los logs, y una SAS derivada de una clave de cuenta no puede revocarse individualmente — la única forma de invalidarla es rotar la clave de la cuenta, lo que rompe todas las demás SAS derivadas de ella. Una **SAS de delegación de usuario** (firmada con credenciales de Entra ID, como en el Ejercicio 9) es la forma más segura porque está acotada por los permisos de la propia identidad firmante y por una vida máxima de 7 días.

---

### Bloque 8 — Migración

**A8.1** Usando `hours = (TB × 8 × 10⁶) / (Mbps × 3600 × 0.7)`:

| Conjunto de datos | Enlace | Horas | Días |
|---|---|---|---|
| 5 TB | 1 Gbps | ≈ 16 h | ≈ 0,7 días |
| 50 TB | 500 Mbps | ≈ 317 h | ≈ 13 días |
| 500 TB | 1 Gbps | ≈ 1.587 h | ≈ 66 días |

**5 TB / 1 Gbps** claramente *no* es un caso de Data Box — termina durante la noche por el cable. **500 TB / 1 Gbps** es claramente un caso de Data Box (Data Box Heavy, o varios Data Box) — dos meses de WAN saturada no es un plan de migración. La fila de 50 TB es el punto medio genuinamente discutible, que es el objetivo del ejercicio.

**A8.2** La capacidad bruta es la suma de los medios físicos; la capacidad utilizable es lo que queda después del **overhead de cifrado, RAID/paridad, overhead del sistema de archivos y espacio reservado** del propio appliance. Al examen le importa porque la pregunta de dimensionamiento siempre se plantea contra las cifras *utilizables*: un conjunto de datos de 85 TB no entra en un Data Box de 100 TB, porque la cifra utilizable es ~80 TB.

**A8.3** Online son ~13 días; Data Box son ~10 días de punta a punta. En puro tiempo transcurrido están casi empatados, así que el tiempo no es el factor decisivo acá. El factor **no temporal** es la **contención del enlace**: la transferencia online consume 500 Mbps (o el 70 % de ellos) de forma continua durante 13 días, degradando todo otro uso comercial de ese circuito — VPNs, VoIP, SaaS, backups. Data Box saca la carga completamente de la WAN. El contraargumento a favor de online es que no necesita **logística física, ni cadena de custodia, ni congelamiento de cambios** — los datos pueden seguir cambiando durante una sincronización online larga (con una pasada final de deltas), mientras que un Data Box captura una instantánea en un punto del tiempo y todo lo escrito después de la copia debe reconciliarse por separado.

**A8.4** (1) Los datos están **cifrados en reposo en el appliance con AES-256**, y la clave de desbloqueo se te entrega por separado a través del portal de Azure, sin viajar nunca con el dispositivo — un mensajero que lo robe se lleva texto cifrado. (2) **Cadena de custodia y borrado seguro**: el dispositivo se rastrea como un recurso administrado de Azure durante todo el trayecto, y después de que los datos se ingieren en tu cuenta de almacenamiento Microsoft **borra el appliance de forma segura según los estándares NIST SP 800-88** antes de reutilizarlo. Agregá que el dispositivo es ruggedizado y a prueba de manipulaciones evidentes.

**A8.5** **Complemento, y en la práctica un requisito previo para la decisión.** Azure Migrate descubre y evalúa lo que tenés — inventario de servidores, tamaños de discos, dependencias, destinos de Azure correctamente dimensionados, estimaciones de costo. Data Box mueve bytes. Usás la evaluación de Azure Migrate para enterarte de que tenés, digamos, 47 TB en 60 servidores sobre un enlace de 500 Mbps, y *eso* es el insumo para la decisión de Data-Box-o-no. No son competidores: Azure Migrate no tiene ninguna capacidad de envío offline, y Data Box no tiene ninguna capacidad de descubrimiento o evaluación.

**A8.6** 3 TB sobre 1 Gbps con utilización realista se completa en aproximadamente **10 horas** — menos de una sola ventana nocturna — así que pedir un Data Box le agrega una semana o más de envío y manipulación, logística física y un proceso de cadena de custodia a un problema que se resuelve solo antes del próximo día hábil.

---

### Bloque 9 — Diagnóstico y limpieza

**A9.1** Devolver `403 Forbidden` le confirmaría a un llamante no autenticado que existe un blob llamado `report.bin` en un contenedor llamado `media` — una filtración de información que le permite a un atacante enumerar tu espacio de nombres sólo por el código de respuesta. `404 Not Found` es indistinguible de un blob genuinamente ausente, así que un llamante anónimo no aprende nada. Este es el mismo razonamiento detrás de "usuario o contraseña inválidos" en vez de "no existe ese usuario".

**A9.2** Toda SAS lleva (1) un **tiempo de expiración explícito** y (2) un **conjunto fijo de permisos y un ámbito** (servicio/contenedor/blob, más un rango de IP opcional y el protocolo permitido) horneados en su firma — una asignación de rol no tiene expiración y se evalúa dinámicamente en el momento de la solicitud. Lo que **no** podés hacerle a una SAS ya emitida derivada de una clave de cuenta es **revocarla individualmente**: los únicos remedios son esperar a que venza, rotar la clave de cuenta firmante (invalidando todas las SAS derivadas de ella), o — si lo previste — haberla emitido contra una **política de acceso almacenada** en el contenedor, que *sí* puede modificarse o borrarse para revocar la SAS. Una SAS de delegación de usuario también puede revocarse revocando la clave de delegación.

**A9.3** El **soft delete de blobs** (junto con el soft delete de contenedores y el versionado) es la característica que hace recuperable un borrado accidental de blob — los blobs borrados se retienen y se pueden restaurar durante el período de retención configurado. Pero **no** habría sobrevivido a este comando. `az group delete` elimina la **cuenta** de almacenamiento en sí, y el soft delete opera *dentro* de una cuenta. Las protecciones a nivel de cuenta son los **bloqueos de recursos** (`CanNotDelete`) y, si la suscripción y la cuenta cumplen los criterios, el **soft delete / recuperación de cuenta de almacenamiento** dentro de la ventana de retención de la eliminación. La lección general: las protecciones del plano de datos no defienden contra el borrado del plano de control; para eso necesitás un bloqueo o una política.

**A9.4**

| Decisión | ¿Modificable después de la creación? |
|---|---|
| **Región** | **No.** Tenés que crear una cuenta nueva en la región destino y copiar los datos (AzCopy, object replication, Data Factory). |
| **Redundancia** | **Sí**, con reglas. LRS ↔ GRS ↔ RA-GRS es una simple actualización de SKU. LRS ↔ ZRS requiere una conversión y no puede alcanzarse directamente desde un SKU geo — andá GRS → LRS → ZRS, como demostró el Ejercicio 4. Algunas conversiones están limitadas por región. |
| **Nivel de rendimiento (standard/premium)** | **No.** Standard y premium son tipos de cuenta distintos por debajo; migrar significa una cuenta nueva y una copia de datos. |
| **Tipo de cuenta** (StorageV2 / BlockBlobStorage / FileStorage) | **No** para tipos standard↔premium. Las cuentas heredadas Storage (v1) y BlobStorage *sí* pueden actualizarse a StorageV2 in situ, en un solo sentido. |
| **Nivel de acceso** | **Sí**, libremente — a nivel de cuenta (valor por defecto para blobs nuevos) y por blob, sujeto a cargos por eliminación temprana y a la demora de rehidratación de Archive. |
| **Espacio de nombres jerárquico (HNS)** | **No** en el sentido normal — se establece en la creación. Microsoft provee una ruta de actualización de un solo sentido desde una cuenta StorageV2 sin HNS a HNS, pero no puede revertirse y tiene requisitos previos. Tratalo como una decisión del momento de creación. |

El resumen listo para el examen: **la región, el nivel de rendimiento y el tipo de cuenta son permanentes; la redundancia y el nivel de acceso no.** Por eso el Ejercicio 1 llamó a la cuenta un límite.

</details>