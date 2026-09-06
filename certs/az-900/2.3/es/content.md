# 2.3 — Describir los servicios de almacenamiento de Azure

**Examen:** AZ-900 (Microsoft Azure Fundamentals), versión del temario 2026-07-20
**Dominio:** Describir la arquitectura y los servicios de Azure — **peso 9,62 %**
**Nivel:** Platform Architect / SRE — profundidad de producción

---

## 1. El problema de producción

El almacenamiento es donde los fundamentos dejan de ser académicos. El cómputo es fungible: una VM muere, el scheduler la reemplaza y nadie abre un incidente. El almacenamiento es *stateful* — es la única capa del stack donde un error de operador **no es idempotente** ni se recupera con un "redeploy". Tres clases de fallo explican casi todos los postmortems reales de almacenamiento en Azure:

1. **Unidad de blast radius equivocada.** La storage account — no el container, no el share — es la unidad de los límites de throttling, de la política de firewall, del alcance de la clave de cifrado, de la configuración de redundancia y del failover regional. Los equipos que meten "todo lo del proyecto X" en una sola cuenta descubren a las 03:00 que el techo de 20.000 req/s de un batch job se comparte con la API de cara al cliente, y que `ServerBusy` (503) se le devuelve a *ambos*.
2. **Modelo de durabilidad equivocado para el fallo del que realmente se defiende.** LRS sobrevive a un disco y a un rack. **No** sobrevive a un datacenter. ZRS sobrevive a una availability zone. **No** sobrevive a la pérdida de una región. GRS sobrevive a la pérdida de una región — de forma asincrónica, con un RPO real, medible y distinto de cero. Nadie lee el número de RPO hasta después del failover.
3. **Tier de costo/latencia elegido una vez y nunca revisado.** Archive no es "Cool barato". Es *offline*: un `GET` contra un blob archivado devuelve **HTTP 409 `BlobArchived`**, no bytes. Descubrir esto desde un stack trace de la aplicación durante una auditoría de cumplimiento es una caída común y completamente evitable.

Todo lo que sigue está organizado alrededor de esas tres decisiones: **cuál es el contenedor del riesgo**, **qué garantiza realmente la replicación** y **cuál es la latencia y la legalidad del camino de lectura**.

---

## 2. La storage account — la verdadera unidad de blast radius

Una **storage account** de Azure es un namespace DNS globalmente único más un conjunto de endpoints de servicio, una configuración de redundancia, un alcance de cifrado y un conjunto de límites duros de escalabilidad. Se crea dentro de un resource group, en una región, y todo lo que hay adentro hereda sus propiedades.

### 2.1 Anatomía y endpoints

Una sola cuenta llamada `stprodtelemetryeus01` expone hasta seis endpoints de plano de datos:

| Servicio | FQDN del endpoint | Protocolo |
|---|---|---|
| Blob | `https://stprodtelemetryeus01.blob.core.windows.net` | REST/HTTPS |
| Data Lake Gen2 (HNS) | `https://stprodtelemetryeus01.dfs.core.windows.net` | REST/HTTPS |
| File | `https://stprodtelemetryeus01.file.core.windows.net` | SMB 3.1.1 / NFS 4.1 / REST |
| Queue | `https://stprodtelemetryeus01.queue.core.windows.net` | REST/HTTPS |
| Table | `https://stprodtelemetryeus01.table.core.windows.net` | REST/HTTPS |
| Sitio web estático | `https://stprodtelemetryeus01.z13.web.core.windows.net` | HTTPS |

Con geo-redundancia de acceso de lectura, el secundario es el mismo nombre con el sufijo `-secondary` en la etiqueta de la cuenta: `https://stprodtelemetryeus01-secondary.blob.core.windows.net`.

**Restricciones de nombres (relevantes para el examen y dolorosas en la operación):** 3–24 caracteres, **solo letras minúsculas y dígitos**, **globalmente único en todo Azure**. Sin guiones, sin guiones bajos. Por eso los nombres de cuenta se ven como `stprodtelemetryeus01` y no como `st-prod-telemetry-eus-01`.

### 2.2 Tipos de cuenta

| Tipo de cuenta (`kind` / familia de SKU) | Medio de respaldo | Servicios soportados | Tiers disponibles | Uso típico |
|---|---|---|---|---|
| **General-purpose v2** (`StorageV2`, Standard) | HDD | Blob, File, Queue, Table, Disk (page blobs) | Hot, Cool, Cold, Archive | Predeterminado para ~90 % de las cargas |
| **Premium block blobs** (`BlockBlobStorage`) | SSD | Solo block + append blobs | Solo Premium (sin Cool/Cold/Archive) | Alta tasa de transacciones, objetos chicos, latencia de un solo dígito de ms |
| **Premium file shares** (`FileStorage`) | SSD | Solo Azure Files | Premium (aprovisionado) | Shares SMB/NFS que necesitan baja latencia consistente; **NFS 4.1 requiere este tipo** |
| **Premium page blobs** (`StorageV2`, Premium) | SSD | Page blobs | Premium | Discos no administrados / nicho; se prefieren los managed disks |
| **General-purpose v1** (`Storage`) — legado | HDD | Blob, File, Queue, Table | Sin access tiers | Solo legado; migrar a v2 |
| **Blob storage** (`BlobStorage`) — legado | HDD | Solo blobs | Hot, Cool, Archive | Solo legado |

> **Regla del arquitecto:** creá GPv2 salvo que tengas un requisito medido que solo Premium satisfaga. Premium cambia el *modelo de facturación* (pagás por capacidad aprovisionada, no consumida), lo que es una sorpresa de costo más grande que la diferencia de precio por GB.

### 2.3 Límites duros — por qué una cuenta no es "un proyecto"

| Límite | Valor por defecto |
|---|---|
| Capacidad máxima por cuenta | **5 PiB** (más, bajo pedido) |
| Tasa máxima de peticiones por cuenta | **20.000 requests/s** |
| Ingress máximo (LRS/ZRS, la mayoría de las regiones) | 60 Gbps |
| Egress máximo (LRS/ZRS, la mayoría de las regiones) | 120 Gbps |
| Storage accounts por región por suscripción | 250 (blando, elevable a 500) |
| Block blob individual máximo | ~190,7 TiB (50.000 bloques × 4000 MiB) |
| File share estándar máximo | 100 TiB (con large file shares habilitado) |
| Mensaje de queue máximo | 64 KiB |
| Entidad de table máxima | 1 MiB |

**Estos límites son de la cuenta, no del container.** Un `ThrottlingError` en un container degrada todos los demás containers, shares y queues de la misma cuenta. Segmentá cuentas por *perfil de throughput y dominio de fallo*, no por organigrama.

---

## 3. Los cinco servicios de almacenamiento

### 3.1 Comparación de características

| | **Blob** | **Files** | **Queue** | **Table** | **Managed Disks** |
|---|---|---|---|---|---|
| Modelo de datos | Object store plano (directorios virtuales con `/`) | Sistema de archivos jerárquico | Log de mensajes tipo FIFO | NoSQL clave/atributo | Dispositivo de bloques (page blob) |
| Protocolo de acceso | HTTPS REST, SDK, NFS 3.0 (opcional), SFTP (opcional) | SMB 2.1/3.x, NFS 4.1, REST | HTTPS REST | HTTPS REST, OData | Adjuntado a una VM como `/dev/sdX` |
| Modelo de concurrencia | Optimista (ETag), lease | Locking POSIX/SMB | Visibility timeout, at-least-once | Optimista (ETag) | Escritor único (salvo shared disk) |
| Tamaño máximo de objeto | ~190,7 TiB (block blob) | 4 TiB por archivo | 64 KiB por mensaje | 1 MiB por entidad | 64 TiB |
| Montable como sistema de archivos | Solo vía `blobfuse2` / NFS 3.0 | Nativamente (`net use`, `mount -t cifs`) | No | No | Sí |
| Clave de búsqueda | Container + nombre del blob | Share + ruta | Nombre de la queue | PartitionKey + RowKey | LUN |
| Tiering (Hot/Cool/Cold/Archive) | **Sí** | Transaction-optimized / Hot / Cool (solo standard) | No | No | No (se elige SKU en su lugar) |
| Uso típico de SRE | Logs, backups, artefactos, media, data lake | Unidades compartidas de lift-and-shift, shares de configuración, volúmenes RWX de AKS | Desacoplar componentes, buffers de reintento | Store de configuración/metadatos, registro de dispositivos | Discos de SO/datos de VM, bases de datos |

### 3.2 Tipos de blob — una trampa de examen y una restricción real de diseño

| Tipo de blob | Escrito por | Optimizado para | Tamaño máximo | Tierable |
|---|---|---|---|---|
| **Block blob** | `Put Block` + `Put Block List` | Carga secuencial de objetos discretos | 190,7 TiB | Sí |
| **Append blob** | `Append Block` (solo append atómico) | Logging, pistas de auditoría | ~195 GiB | Sí |
| **Page blob** | `Put Page` (escritura aleatoria alineada a 512 bytes) | I/O de acceso aleatorio — VHDs | 8 TiB (32 TiB premium) | No |

No podés cambiar el tipo de un blob en el lugar. Subir un VHD con la configuración por defecto de `azcopy` crea un blob de tipo *block*; adjuntarlo como disco no administrado falla después. Por eso existen los **managed disks** — Azure es dueño del page blob y de la cuenta.

### 3.3 Matriz de decisión

| Si el requisito es… | Elegí | Porque |
|---|---|---|
| Muchos lectores, direccionable por HTTP, crecimiento sin límite | **Blob** | No hacen falta semánticas de sistema de archivos; el más barato por GB; tierable |
| App legada que espera `\\server\share` o un montaje POSIX | **Files** | Único servicio con SMB/NFS nativo; sin cambios de código |
| Varios pods necesitan ReadWriteMany | **Files** (o Blob NFS) | Los Managed Disks son ReadWriteOnce |
| Amortiguar trabajo entre un productor y un consumidor, sin necesidad de garantía de orden | **Queue** | Mensajes de 64 KiB, ~US$ 0,0004/10k ops, sin broker que operar |
| Ordenado, transaccional, exactly-once, topics/subscriptions | *No Storage Queues* — **Service Bus** | Las Storage Queues son at-least-once, con orden de mejor esfuerzo |
| Clave/valor disperso y sin esquema a escala masiva, sin joins | **Table** | El NoSQL más barato de Azure; camino de upgrade a la Table API de Cosmos DB |
| Dispositivo de bloques para un SO o un motor de base de datos | **Managed Disk** | Único servicio que expone I/O de bloques crudo con IOPS garantizadas |
| Analítica sobre petabytes con ACLs a nivel de directorio | **Blob + Hierarchical Namespace** (ADLS Gen2) | Rename atómico de directorios + ACLs POSIX en el endpoint `dfs` |

---

## 4. Redundancia — a qué sobrevive realmente cada opción

### 4.1 Las cuatro (seis) opciones

| Opción | Copias | Ubicación | Durabilidad anual | Sobrevive a | **No** sobrevive a | Lectura del secundario |
|---|---|---|---|---|---|---|
| **LRS** — Locally redundant | 3 | 3 fault domains en **un datacenter** | 11 nueves (99,999999999 %) | Fallo de disco, nodo, rack | Incendio/inundación del datacenter; pérdida de región | n/d |
| **ZRS** — Zone redundant | 3 | 3 **availability zones**, una región | 12 nueves | Pérdida de una AZ entera | Pérdida de región | n/d |
| **GRS** — Geo redundant | 6 | LRS en la primaria + LRS en la región emparejada | 16 nueves | Pérdida de región (vía failover) | Pérdida de AZ sin downtime | No |
| **RA-GRS** | 6 | Igual que GRS | 16 nueves | Pérdida de región | Pérdida de AZ sin downtime | **Sí** (`-secondary`) |
| **GZRS** — Geo-zone redundant | 6 | ZRS en la primaria + LRS en la secundaria | 16 nueves | Pérdida de AZ **y** pérdida de región | — | No |
| **RA-GZRS** | 6 | Igual que GZRS | 16 nueves | Pérdida de AZ **y** pérdida de región | — | **Sí** (`-secondary`) |

### 4.2 Los detalles que rompen producción

**La geo-replicación es asincrónica.** Las escrituras se confirman en la primaria y se reconocen *antes* de replicarse a la secundaria. El objetivo declarado de Microsoft es un **RPO de menos de 15 minutos**. No hay opción sincrónica entre regiones en Azure Storage. Si tu RPO es cero, la respuesta es doble escritura a nivel de aplicación u otro servicio — no un desplegable de redundancia.

**La secundaria es de solo lectura hasta el failover.** Con RA-GRS podés hacer `GET` desde `-secondary`, pero no `PUT`. Las aplicaciones deben saber con qué endpoint están hablando.

**Verificá el desfase antes de confiar en la secundaria:**

```bash
$ az storage account show \
    --name stprodtelemetryeus01 \
    --resource-group rg-platform-prod \
    --expand geoReplicationStats \
    --query "geoReplicationStats" -o json
{
  "canFailover": true,
  "canPlannedFailover": true,
  "lastSyncTime": "2026-09-04T11:47:12+00:00",
  "postFailoverRedundancy": "Standard_LRS",
  "postPlannedFailoverRedundancy": "Standard_GRS",
  "status": "Live"
}
```

`lastSyncTime` es la marca de tiempo antes de la cual **todas** las escrituras de la primaria están garantizadas como durables en la secundaria. Las escrituras posteriores pueden estar o no estar. `now() - lastSyncTime` **es tu RPO actual**. Alertá sobre eso.

**El failover no planificado es destructivo para tu postura de redundancia.** Notá `postFailoverRedundancy: Standard_LRS` arriba: después de un failover no planificado, la cuenta queda como **LRS en la nueva región primaria**. Los datos escritos en la primaria vieja después de `lastSyncTime` se **pierden**. Después tenés que rehabilitar manualmente la geo-redundancia, y la re-replicación de una cuenta grande tarda de horas a días.

```bash
# Unplanned failover — used when the primary region is genuinely unavailable.
$ az storage account failover \
    --name stprodtelemetryeus01 \
    --resource-group rg-platform-prod \
    --yes
```

```bash
# Planned failover — primary is healthy; zero data loss; preserves geo-redundancy.
# Used for DR drills and region migrations.
$ az storage account failover \
    --name stprodtelemetryeus01 \
    --resource-group rg-platform-prod \
    --failover-type Planned \
    --yes
```

**Ejecutá el failover planificado como un game day agendado.** Una configuración de DR que nunca se ejercitó es una hipótesis, no un control.

**Cambiar la redundancia no siempre es una operación de metadatos.** La conversión LRS ↔ ZRS dentro de la región está soportada (conversión iniciada por el cliente o solicitud de migración en vivo), y agregar geo-redundancia es un cambio de metadatos más una copia en segundo plano. Pero **ZRS → GZRS por algunos caminos, y cualquier cambio de región, requieren una copia manual de datos** — planificá con `azcopy sync`, no con un desplegable del portal.

---

## 5. Access tiers y ciclo de vida

### 5.1 Los cuatro tiers de blob

| Tier | ¿Online? | Costo de almacenamiento | Costo de acceso (lectura) | Retención mínima | Latencia al primer byte | SLA de disponibilidad (lectura LRS/GRS) |
|---|---|---|---|---|---|---|
| **Hot** | Sí | El más alto | El más bajo | ninguna | milisegundos | 99,9 % (99,99 % lectura RA-GRS) |
| **Cool** | Sí | Más bajo | Más alto | **30 días** | milisegundos | 99 % (99,9 % lectura RA-GRS) |
| **Cold** | Sí | Todavía más bajo | Todavía más alto | **90 días** | milisegundos | 99 % (99,9 % lectura RA-GRS) |
| **Archive** | **No — offline** | El más bajo | El más alto | **180 días** | **horas** (rehidratación) | 99 % (99,9 % lectura RA-GRS) |

**Reglas que agarran a la gente desprevenida:**

- El **access tier por defecto de la cuenta** puede ser `Hot`, `Cool` o `Cold`. **`Archive` es solo a nivel de blob** — no existe una "cuenta de almacenamiento archive".
- Los access tiers aplican a **block blobs y append blobs**. Los page blobs (discos) no tienen tiers; en su lugar elegís un SKU de disco.
- **Las cuentas premium block blob no soportan Cool/Cold/Archive.** Para tierizar datos premium tenés que copiarlos a una cuenta standard.
- **Penalidad por borrado temprano:** borrar o re-tierizar un blob antes de que transcurra su retención mínima te factura los días *restantes* a la tarifa de ese tier. Una política de ciclo de vida que mueve datos Hot → Cool → Archive en los días 30/60 cobra una penalidad de borrado temprano de 30 días de Cool sobre cada objeto, para siempre. Respetá los mínimos en la política (`daysAfterLastTierChangeGreaterThan` existe exactamente para esto).

### 5.2 Rehidratación desde Archive

Un blob archivado no se puede leer. `GET` devuelve:

```
HTTP/1.1 409 Conflict
x-ms-error-code: BlobArchived
```

Dos salidas:

1. **Set Blob Tier** — rehidratar en el lugar a Hot/Cool/Cold. El blob no se puede leer durante la rehidratación.
2. **Copy Blob** — copiar a un blob online nuevo; el original archivado queda archivado y legible-como-archivado (es decir, sigue sin ser legible). Preferido, porque no se toca el origen.

| Prioridad de rehidratación | Latencia (SLO) | Costo |
|---|---|---|
| `Standard` | puede tardar **hasta 15 horas** | menor |
| `High` | puede completarse en **menos de 1 hora** para objetos < 10 GiB | significativamente mayor |

```bash
$ az storage blob set-tier \
    --account-name stprodtelemetryeus01 \
    --container-name audit \
    --name 2024/q1/ledger.parquet \
    --tier Hot \
    --rehydrate-priority High \
    --auth-mode login

$ az storage blob show \
    --account-name stprodtelemetryeus01 \
    --container-name audit --name 2024/q1/ledger.parquet \
    --auth-mode login \
    --query "properties.{tier:blobTier, status:rehydrationStatus, inferred:blobTierInferred}" -o table
Tier     Status                Inferred
-------  --------------------  ----------
Archive  rehydrate-pending-to-hot  False
```

`Tier` sigue siendo `Archive` y `Status` dice `rehydrate-pending-to-hot` durante toda la ventana de rehidratación. El código de la aplicación debe consultar `x-ms-rehydrate-priority` / `x-ms-archive-status`, no asumir disponibilidad sincrónica. **Diseñá el SLA de recuperación alrededor de 15 horas, no de 1.**

### 5.3 Política completa de gestión de ciclo de vida

Las reglas de ciclo de vida las evalúa la plataforma una vez por día; la primera ejecución después de habilitar una política puede tardar hasta 48 horas.

```json
{
  "rules": [
    {
      "enabled": true,
      "name": "telemetry-tier-and-expire",
      "type": "Lifecycle",
      "definition": {
        "filters": {
          "blobTypes": [ "blockBlob" ],
          "prefixMatch": [ "telemetry/raw/", "telemetry/enriched/" ],
          "blobIndexMatch": [
            { "name": "retentionClass", "op": "==", "value": "standard" }
          ]
        },
        "actions": {
          "baseBlob": {
            "tierToCool":    { "daysAfterModificationGreaterThan": 30 },
            "tierToCold":    { "daysAfterModificationGreaterThan": 120 },
            "tierToArchive": {
              "daysAfterModificationGreaterThan": 365,
              "daysAfterLastTierChangeGreaterThan": 90
            },
            "delete":        { "daysAfterModificationGreaterThan": 2555 }
          },
          "snapshot": {
            "tierToCool":    { "daysAfterCreationGreaterThan": 30 },
            "tierToArchive": { "daysAfterCreationGreaterThan": 180 },
            "delete":        { "daysAfterCreationGreaterThan": 365 }
          },
          "version": {
            "tierToCool":    { "daysAfterCreationGreaterThan": 30 },
            "tierToArchive": { "daysAfterCreationGreaterThan": 180 },
            "delete":        { "daysAfterCreationGreaterThan": 730 }
          }
        }
      }
    },
    {
      "enabled": true,
      "name": "purge-incomplete-multipart-uploads",
      "type": "Lifecycle",
      "definition": {
        "filters": {
          "blobTypes": [ "blockBlob" ]
        },
        "actions": {
          "baseBlob": {
            "delete": { "daysAfterCreationGreaterThan": 7 }
          }
        }
      }
    }
  ]
}
```

```bash
$ az storage account management-policy create \
    --account-name stprodtelemetryeus01 \
    --resource-group rg-platform-prod \
    --policy @lifecycle-policy.json \
    --query "policy.rules[].name" -o tsv
telemetry-tier-and-expire
purge-incomplete-multipart-uploads
```

> La segunda regla importa más de lo que parece: los bloques sin confirmar de cargas multiparte fallidas se **facturan** pero son invisibles para `az storage blob list`. Son una causa raíz clásica del "la factura de almacenamiento creció 40 % y nadie sabe por qué".

---

## 6. Managed disks

Un managed disk es un page blob cuya storage account es propiedad de Azure y está oculta. Esa sola abstracción elimina la contención de IOPS por cuenta entre VMs, y por eso los discos no administrados están obsoletos.

### 6.1 Comparación de SKUs

| SKU | Medio | Tamaño máximo | IOPS máximas | Throughput máximo | Latencia | Modelo de IOPS | Notas |
|---|---|---|---|---|---|---|---|
| **Ultra Disk** | NVMe SSD | 64 TiB | 400.000 | 10.000 MB/s | sub-milisegundo | Configurable de forma independiente, ajustable en vivo | Sin host caching; restricciones de ubicación zonal; el costo más alto |
| **Premium SSD v2** | SSD | 64 TiB | 80.000 | 1.200 MB/s | sub-milisegundo | Configurable de forma independiente (3.000 IOPS + 125 MB/s de línea base gratis) | Sin host caching; mejor precio/rendimiento para tier-1 exigente |
| **Premium SSD** (P1–P80) | SSD | 32 TiB | 20.000 | 900 MB/s | ms de un solo dígito | Fijo por tier de tamaño; bursting disponible | Requerido para el SLA de VM de 99,9 % de instancia única |
| **Standard SSD** (E1–E80) | SSD | 32 TiB | 6.000 | 750 MB/s | ms, variable | Fijo por tier de tamaño | Dev/test, producción liviana, servidores web |
| **Standard HDD** (S1–S80) | HDD | 32 TiB | 2.000 | 500 MB/s | decenas de ms, variable | Fijo por tier de tamaño | Backup, archivado, no sensible a la latencia |

Existen variantes zona-redundantes para Premium SSD y Standard SSD (`Premium_ZRS`, `StandardSSD_ZRS`), que permiten adjuntar un disco a una VM en otra zona después de un fallo de zona — la base de las cargas stateful resilientes a zona.

**Distinción clave para el examen:** el *tier de tamaño del disco determina el rendimiento* para Premium SSD / Standard SSD / Standard HDD. Aprovisionar un disco P4 de 32 GiB y esperar 20.000 IOPS es el ticket de rendimiento de almacenamiento más común de todos. Premium SSD v2 y Ultra rompen ese acoplamiento.

---

## 7. Identidad, red y cifrado (las partes que producen 403s)

**El cifrado en reposo no es opcional ni se puede desactivar.** Todos los datos se cifran con AES de 256 bits (Storage Service Encryption), conforme a FIPS 140-2. Vos elegís *quién tiene la clave*:

- **Claves administradas por Microsoft (MMK)** — por defecto, carga operativa cero.
- **Claves administradas por el cliente (CMK)** — una clave RSA en Azure Key Vault o Managed HSM; la storage account necesita una identidad administrada con `get`/`wrapKey`/`unwrapKey`. **Si la clave se borra o el firewall del vault bloquea la cuenta, toda la cuenta devuelve `KeyVaultEncryptionKeyNotFound` y queda ilegible.**
- **Cifrado de infraestructura** — una segunda capa AES de 256 bits, independiente. Debe habilitarse **en la creación de la cuenta**; no se puede activar después.

**Autorización, en orden de preferencia:**

| Mecanismo | Identidad | Revocable | Auditable | Veredicto |
|---|---|---|---|---|
| **Microsoft Entra ID + RBAC** | Usuario/service principal/identidad administrada | Al instante | Totalmente (identidad del llamador en los logs) | **Usá esto** |
| **User delegation SAS** | Firmada con una clave emitida por Entra | Sí (revocando la clave de delegación) | Sí | La mejor variante de SAS |
| **Service SAS / Account SAS** | Firmada con la clave de la cuenta | Solo rotando la clave | Identidad del llamador desconocida | Evitar para humanos |
| **Shared Key (clave de cuenta)** | La cuenta misma | Rotar ambas claves | No | **Deshabilitala** |

```bash
$ az storage account update \
    --name stprodtelemetryeus01 --resource-group rg-platform-prod \
    --allow-shared-key-access false \
    --min-tls-version TLS1_2 \
    --allow-blob-public-access false \
    --https-only true \
    --query "{sharedKey:allowSharedKeyAccess, tls:minimumTlsVersion, publicBlob:allowBlobPublicAccess}" -o table
SharedKey    Tls        PublicBlob
-----------  ---------  ------------
False        TLS1_2     False
```

**Roles RBAC que importan (plano de datos, no plano de control):**

| Rol | Otorga |
|---|---|
| `Storage Blob Data Reader` | Leer blobs y containers |
| `Storage Blob Data Contributor` | Leer/escribir/borrar blobs |
| `Storage Blob Data Owner` | Lo anterior + gestión de ACLs POSIX (ADLS Gen2) |
| `Storage File Data SMB Share Contributor` | Lectura/escritura SMB en shares |
| `Storage Queue Data Message Processor` | Peek/get/delete de mensajes |

> `Owner` o `Contributor` a nivel de recurso **no** otorga acceso de plano de datos a los blobs cuando Shared Key está deshabilitado. Esto es deliberado y es la causa n.º 1 del "soy Owner de la suscripción y me da 403".

---

## 8. Infraestructura como código — definiciones completas

### 8.1 Bicep — storage account endurecida, private endpoint, ciclo de vida, file share

```bicep
// storage.bicep — production-grade Azure Storage account with private networking,
// customer-managed keys, immutable audit container and a lifecycle policy.
targetScope = 'resourceGroup'

@minLength(3)
@maxLength(24)
param storageAccountName string

param location string = resourceGroup().location

@allowed([
  'Standard_LRS'
  'Standard_ZRS'
  'Standard_GRS'
  'Standard_GZRS'
  'Standard_RAGRS'
  'Standard_RAGZRS'
  'Premium_LRS'
  'Premium_ZRS'
])
param skuName string = 'Standard_GZRS'

@allowed([ 'Hot' 'Cool' 'Cold' ])
param defaultAccessTier string = 'Hot'

@description('Resource ID of the subnet that will host the private endpoints.')
param privateEndpointSubnetId string

@description('Resource ID of the privatelink.blob.core.windows.net private DNS zone.')
param blobPrivateDnsZoneId string

@description('Resource ID of the privatelink.file.core.windows.net private DNS zone.')
param filePrivateDnsZoneId string

param tags object = {
  environment: 'production'
  costCenter: 'platform'
  dataClassification: 'confidential'
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  tags: tags
  sku: {
    name: skuName
  }
  kind: 'StorageV2'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    accessTier: defaultAccessTier
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    allowCrossTenantReplication: false
    defaultToOAuthAuthentication: true
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    publicNetworkAccess: 'Disabled'
    isHnsEnabled: false
    isSftpEnabled: false
    isLocalUserEnabled: false
    largeFileSharesState: 'Enabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
      ipRules: []
      virtualNetworkRules: []
    }
    encryption: {
      keySource: 'Microsoft.Storage'
      requireInfrastructureEncryption: true
      services: {
        blob: {
          enabled: true
          keyType: 'Account'
        }
        file: {
          enabled: true
          keyType: 'Account'
        }
        queue: {
          enabled: true
          keyType: 'Account'
        }
        table: {
          enabled: true
          keyType: 'Account'
        }
      }
    }
    sasPolicy: {
      sasExpirationPeriod: '01.00:00:00'
      expirationAction: 'Log'
    }
    keyPolicy: {
      keyExpirationPeriodInDays: 90
    }
  }
}

resource blobServices 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    isVersioningEnabled: true
    changeFeed: {
      enabled: true
      retentionInDays: 90
    }
    restorePolicy: {
      enabled: true
      days: 29
    }
    deleteRetentionPolicy: {
      enabled: true
      days: 30
      allowPermanentDelete: false
    }
    containerDeleteRetentionPolicy: {
      enabled: true
      days: 30
    }
    cors: {
      corsRules: []
    }
  }
}

resource telemetryContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobServices
  name: 'telemetry'
  properties: {
    publicAccess: 'None'
    metadata: {
      owner: 'observability'
    }
  }
}

resource auditContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobServices
  name: 'audit'
  properties: {
    publicAccess: 'None'
    immutableStorageWithVersioning: {
      enabled: true
    }
  }
}

resource auditImmutabilityPolicy 'Microsoft.Storage/storageAccounts/blobServices/containers/immutabilityPolicies@2023-05-01' = {
  parent: auditContainer
  name: 'default'
  properties: {
    immutabilityPeriodSinceCreationInDays: 2555
    allowProtectedAppendWrites: true
  }
}

resource lifecyclePolicy 'Microsoft.Storage/storageAccounts/managementPolicies@2023-05-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    policy: {
      rules: [
        {
          enabled: true
          name: 'telemetry-tier-and-expire'
          type: 'Lifecycle'
          definition: {
            filters: {
              blobTypes: [ 'blockBlob' ]
              prefixMatch: [ 'telemetry/raw/' ]
            }
            actions: {
              baseBlob: {
                tierToCool: {
                  daysAfterModificationGreaterThan: 30
                }
                tierToCold: {
                  daysAfterModificationGreaterThan: 120
                }
                tierToArchive: {
                  daysAfterModificationGreaterThan: 365
                  daysAfterLastTierChangeGreaterThan: 90
                }
                delete: {
                  daysAfterModificationGreaterThan: 2555
                }
              }
              version: {
                tierToArchive: {
                  daysAfterCreationGreaterThan: 90
                }
                delete: {
                  daysAfterCreationGreaterThan: 730
                }
              }
            }
          }
        }
      ]
    }
  }
}

resource fileServices 'Microsoft.Storage/storageAccounts/fileServices@2023-05-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    shareDeleteRetentionPolicy: {
      enabled: true
      days: 14
    }
    protocolSettings: {
      smb: {
        versions: 'SMB3.0;SMB3.1.1'
        authenticationMethods: 'Kerberos'
        kerberosTicketEncryption: 'AES-256'
        channelEncryption: 'AES-256-GCM'
      }
    }
  }
}

resource appConfigShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-05-01' = {
  parent: fileServices
  name: 'app-config'
  properties: {
    accessTier: 'TransactionOptimized'
    shareQuota: 5120
    enabledProtocols: 'SMB'
  }
}

resource blobPrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-11-01' = {
  name: 'pe-${storageAccountName}-blob'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: privateEndpointSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'plsc-blob'
        properties: {
          privateLinkServiceId: storageAccount.id
          groupIds: [ 'blob' ]
          requestMessage: 'Managed by platform IaC'
        }
      }
    ]
  }
}

resource blobPrivateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = {
  parent: blobPrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'privatelink-blob-core-windows-net'
        properties: {
          privateDnsZoneId: blobPrivateDnsZoneId
        }
      }
    ]
  }
}

resource filePrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-11-01' = {
  name: 'pe-${storageAccountName}-file'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: privateEndpointSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'plsc-file'
        properties: {
          privateLinkServiceId: storageAccount.id
          groupIds: [ 'file' ]
        }
      }
    ]
  }
}

resource filePrivateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = {
  parent: filePrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'privatelink-file-core-windows-net'
        properties: {
          privateDnsZoneId: filePrivateDnsZoneId
        }
      }
    ]
  }
}

output storageAccountId string = storageAccount.id
output storageAccountPrincipalId string = storageAccount.identity.principalId
output blobEndpoint string = storageAccount.properties.primaryEndpoints.blob
output fileEndpoint string = storageAccount.properties.primaryEndpoints.file
```

Desplegar y verificar:

```bash
$ az deployment group create \
    --resource-group rg-platform-prod \
    --template-file storage.bicep \
    --parameters storageAccountName=stprodtelemetryeus01 \
                 skuName=Standard_GZRS \
                 privateEndpointSubnetId="/subscriptions/8f1c.../resourceGroups/rg-net-prod/providers/Microsoft.Network/virtualNetworks/vnet-hub-eus/subnets/snet-privatelink" \
                 blobPrivateDnsZoneId="/subscriptions/8f1c.../resourceGroups/rg-net-prod/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net" \
                 filePrivateDnsZoneId="/subscriptions/8f1c.../resourceGroups/rg-net-prod/providers/Microsoft.Network/privateDnsZones/privatelink.file.core.windows.net" \
    --query "properties.{state:provisioningState, duration:duration}" -o table
State       Duration
----------  ----------------
Succeeded   PT2M41.9182633S
```

### 8.2 Equivalente en Terraform

```hcl
terraform {
  required_version = ">= 1.7.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  features {
    storage {
      data_plane_available = true
    }
  }
  storage_use_azuread = true
}

variable "storage_account_name" {
  type        = string
  description = "Globally unique, 3-24 lowercase alphanumeric characters."
  validation {
    condition     = can(regex("^[a-z0-9]{3,24}$", var.storage_account_name))
    error_message = "Storage account names must be 3-24 lowercase letters and digits only."
  }
}

variable "resource_group_name" { type = string }
variable "location"            { type = string }
variable "private_endpoint_subnet_id" { type = string }
variable "blob_private_dns_zone_id"   { type = string }

resource "azurerm_storage_account" "this" {
  name                             = var.storage_account_name
  resource_group_name              = var.resource_group_name
  location                         = var.location
  account_kind                     = "StorageV2"
  account_tier                     = "Standard"
  account_replication_type         = "GZRS"
  access_tier                      = "Hot"
  https_traffic_only_enabled       = true
  min_tls_version                  = "TLS1_2"
  allow_nested_items_to_be_public  = false
  shared_access_key_enabled        = false
  default_to_oauth_authentication  = true
  public_network_access_enabled    = false
  cross_tenant_replication_enabled = false
  infrastructure_encryption_enabled = true
  large_file_share_enabled         = true

  identity {
    type = "SystemAssigned"
  }

  blob_properties {
    versioning_enabled            = true
    change_feed_enabled           = true
    change_feed_retention_in_days = 90
    last_access_time_enabled      = true

    delete_retention_policy {
      days = 30
    }

    container_delete_retention_policy {
      days = 30
    }

    restore_policy {
      days = 29
    }
  }

  share_properties {
    retention_policy {
      days = 14
    }
    smb {
      versions                        = ["SMB3.0", "SMB3.1.1"]
      authentication_types            = ["Kerberos"]
      kerberos_ticket_encryption_type = ["AES-256"]
      channel_encryption_type         = ["AES-256-GCM"]
    }
  }

  sas_policy {
    expiration_period = "01.00:00:00"
    expiration_action = "Log"
  }

  network_rules {
    default_action = "Deny"
    bypass         = ["AzureServices"]
    ip_rules       = []
  }

  tags = {
    environment        = "production"
    costCenter         = "platform"
    dataClassification = "confidential"
  }
}

resource "azurerm_storage_container" "telemetry" {
  name                  = "telemetry"
  storage_account_id    = azurerm_storage_account.this.id
  container_access_type = "private"
}

resource "azurerm_storage_management_policy" "lifecycle" {
  storage_account_id = azurerm_storage_account.this.id

  rule {
    name    = "telemetry-tier-and-expire"
    enabled = true

    filters {
      prefix_match = ["telemetry/raw/"]
      blob_types   = ["blockBlob"]
    }

    actions {
      base_blob {
        tier_to_cool_after_days_since_modification_greater_than    = 30
        tier_to_cold_after_days_since_modification_greater_than    = 120
        tier_to_archive_after_days_since_modification_greater_than = 365
        delete_after_days_since_modification_greater_than          = 2555
      }

      version {
        tier_to_archive_after_days_since_creation = 90
        delete_after_days_since_creation          = 730
      }
    }
  }
}

resource "azurerm_private_endpoint" "blob" {
  name                = "pe-${var.storage_account_name}-blob"
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = var.private_endpoint_subnet_id

  private_service_connection {
    name                           = "plsc-blob"
    private_connection_resource_id = azurerm_storage_account.this.id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [var.blob_private_dns_zone_id]
  }
}

output "blob_endpoint" {
  value = azurerm_storage_account.this.primary_blob_endpoint
}
```

### 8.3 Kubernetes (AKS) — los tres drivers CSI, completos

AKS incluye tres drivers CSI que reemplazan a los in-tree. La elección entre ellos **es** la decisión Blob/Files/Disk, expresada como un modo de acceso.

```yaml
---
# =============================================================================
# 1. Azure Disk CSI — ReadWriteOnce block storage, zone-redundant Premium SSD.
#    Use for: databases, single-writer stateful sets.
# =============================================================================
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: managed-csi-premium-zrs
provisioner: disk.csi.azure.com
parameters:
  skuName: PremiumV2_LRS
  cachingMode: None
  DiskIOPSReadWrite: "8000"
  DiskMBpsReadWrite: "500"
  networkAccessPolicy: DenyAll
reclaimPolicy: Delete
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer
mountOptions:
  - noatime
  - nodiratime
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-data
  namespace: data-platform
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: managed-csi-premium-zrs
  resources:
    requests:
      storage: 512Gi
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
  namespace: data-platform
spec:
  serviceName: postgres
  replicas: 1
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      securityContext:
        fsGroup: 999
        runAsUser: 999
        runAsNonRoot: true
      containers:
        - name: postgres
          image: postgres:16.4-alpine
          ports:
            - name: postgres
              containerPort: 5432
          env:
            - name: PGDATA
              value: /var/lib/postgresql/data/pgdata
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: postgres-credentials
                  key: password
          volumeMounts:
            - name: data
              mountPath: /var/lib/postgresql/data
          resources:
            requests:
              cpu: "2"
              memory: 8Gi
            limits:
              cpu: "4"
              memory: 16Gi
          readinessProbe:
            exec:
              command: ["pg_isready", "-U", "postgres"]
            initialDelaySeconds: 10
            periodSeconds: 5
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: postgres-data
---
# =============================================================================
# 2. Azure Files CSI — ReadWriteMany SMB share, premium tier.
#    Use for: shared config, uploads directories, legacy apps needing RWX.
# =============================================================================
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: azurefile-csi-premium
provisioner: file.csi.azure.com
parameters:
  skuName: Premium_LRS
  protocol: smb
  secretNamespace: shared-storage
reclaimPolicy: Delete
allowVolumeExpansion: true
volumeBindingMode: Immediate
mountOptions:
  - dir_mode=0777
  - file_mode=0777
  - uid=1000
  - gid=1000
  - mfsymlinks
  - cache=strict
  - nosharesock
  - actimeo=30
  - nobrl
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: shared-uploads
  namespace: shared-storage
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: azurefile-csi-premium
  resources:
    requests:
      storage: 1Ti
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: upload-api
  namespace: shared-storage
spec:
  replicas: 6
  selector:
    matchLabels:
      app: upload-api
  template:
    metadata:
      labels:
        app: upload-api
    spec:
      containers:
        - name: api
          image: ghcr.io/example/upload-api:1.9.2
          ports:
            - containerPort: 8080
          volumeMounts:
            - name: uploads
              mountPath: /srv/uploads
          resources:
            requests:
              cpu: 250m
              memory: 512Mi
            limits:
              cpu: "1"
              memory: 1Gi
      volumes:
        - name: uploads
          persistentVolumeClaim:
            claimName: shared-uploads
---
# =============================================================================
# 3. Azure Blob CSI — object storage mounted via NFS 3.0, for read-heavy
#    analytics over an existing data lake container. No POSIX rename atomicity.
# =============================================================================
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-datalake-telemetry
spec:
  capacity:
    storage: 100Ti
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  storageClassName: azureblob-nfs-premium
  mountOptions:
    - nconnect=8
    - rsize=1048576
    - wsize=1048576
    - hard
    - timeo=600
    - retrans=2
  csi:
    driver: blob.csi.azure.com
    volumeHandle: stprodtelemetryeus01_telemetry
    volumeAttributes:
      resourceGroup: rg-platform-prod
      storageAccount: stprodtelemetryeus01
      containerName: telemetry
      protocol: nfs
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: datalake-telemetry
  namespace: analytics
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: azureblob-nfs-premium
  volumeName: pv-datalake-telemetry
  resources:
    requests:
      storage: 100Ti
---
apiVersion: batch/v1
kind: Job
metadata:
  name: telemetry-rollup
  namespace: analytics
spec:
  backoffLimit: 2
  template:
    spec:
      restartPolicy: OnFailure
      containers:
        - name: rollup
          image: ghcr.io/example/telemetry-rollup:0.14.0
          args:
            - --input=/mnt/telemetry/raw
            - --output=/mnt/telemetry/enriched
            - --parallelism=16
          volumeMounts:
            - name: lake
              mountPath: /mnt/telemetry
          resources:
            requests:
              cpu: "8"
              memory: 32Gi
      volumes:
        - name: lake
          persistentVolumeClaim:
            claimName: datalake-telemetry
```

```bash
$ kubectl apply -f azure-storage.yaml
storageclass.storage.k8s.io/managed-csi-premium-zrs created
persistentvolumeclaim/postgres-data created
statefulset.apps/postgres created
storageclass.storage.k8s.io/azurefile-csi-premium created
persistentvolumeclaim/shared-uploads created
deployment.apps/upload-api created
persistentvolume/pv-datalake-telemetry created
persistentvolumeclaim/datalake-telemetry created
job.batch/telemetry-rollup created

$ kubectl get pvc -A
NAMESPACE        NAME                 STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS              AGE
analytics        datalake-telemetry   Bound    pv-datalake-telemetry                      100Ti      RWX            azureblob-nfs-premium     41s
data-platform    postgres-data        Bound    pvc-2b6f9c41-4d0e-4a19-9f77-0c8b31a5e2d4   512Gi      RWO            managed-csi-premium-zrs   41s
shared-storage   shared-uploads       Bound    pvc-c1a7e883-92bb-4c07-8a55-7d3f11e9b6aa   1Ti        RWX            azurefile-csi-premium     41s
```

---

## 9. Mover y migrar datos

### 9.1 Selección de herramienta por escala y restricción

| Volumen de datos | Ancho de banda disponible | Herramienta recomendada | Razón |
|---|---|---|---|
| < 10 GB, ad hoc, interactivo | cualquiera | **Azure Storage Explorer** | GUI, multiplataforma, navegable; no scriptable |
| GB → decenas de TB, con scripts/CI | ≥ 100 Mbps | **AzCopy** | Paralelo, reanudable, semántica `sync`, copia servicio a servicio |
| File share híbrido continuo | cualquiera | **Azure File Sync** | Sincronización bidireccional + cloud tiering; mantiene los servidores on-prem como caché |
| 40 TB – 1 PB, WAN lenta/angosta | < 100 Mbps efectivos | Familia **Azure Data Box** | Enviar dispositivos físicos; la cuenta le gana al cable |
| Canal continuo on-prem → nube | cualquiera | **Data Box Gateway / Azure Stack Edge** | Appliance virtual/físico que presenta un share SMB/NFS que escribe en Azure |
| Servidores/BDs/apps enteros, con evaluación | cualquiera | **Azure Migrate** | Descubrimiento, mapeo de dependencias, dimensionamiento, orquestación del cutover |

**La cuenta de ancho de banda que tenés que saber hacer:**

```
Transfer time (days) = Data (TB) × 8,000,000 / (Effective Mbps × 86,400)
```

100 TB sobre un enlace de 500 Mbps al 70 % de eficiencia ≈ **26 días de WAN saturada**. El viaje de ida y vuelta de Data Box típicamente es de menos de dos semanas y no consume el enlace de producción. Esa es toda la justificación de la transferencia offline.

### 9.2 AzCopy — sesiones reales

```bash
$ azcopy --version
azcopy version 10.29.1

# Entra ID auth — no account keys, no SAS.
$ azcopy login --identity
INFO: Logging in under the identity of a managed service identity
INFO: Login succeeded.
```

**Subir un árbol de directorios, preservando la estructura:**

```bash
$ azcopy copy '/srv/exports/2026-09/' \
    'https://stprodtelemetryeus01.blob.core.windows.net/telemetry/raw/2026-09/' \
    --recursive=true \
    --block-blob-tier=Cool \
    --put-md5 \
    --log-level=INFO

INFO: Scanning...
INFO: Any empty folders will not be processed, because source and/or destination doesn't have full folder support

Job f3c1a90e-7b2d-4e51-a8c2-19d4b7e6f0aa has started
Log file is located at: /home/sre/.azcopy/f3c1a90e-7b2d-4e51-a8c2-19d4b7e6f0aa.log

100.0 %, 18422 Done, 0 Failed, 0 Pending, 0 Skipped, 18422 Total, 2-sec Throughput (Mb/s): 1842.7

Job f3c1a90e-7b2d-4e51-a8c2-19d4b7e6f0aa summary
Elapsed Time (Minutes): 9.7331
Number of File Transfers: 18422
Number of Folder Property Transfers: 0
Number of Symlink Transfers: 0
Total Number of Transfers: 18422
Number of File Transfers Completed: 18422
Number of Folder Transfers Completed: 0
Number of File Transfers Failed: 0
Number of Folder Transfers Failed: 0
Number of File Transfers Skipped: 0
Number of Folder Transfers Skipped: 0
TotalBytesTransferred: 1341829472118
Final Job Status: Completed
```

**Sincronización incremental (delete-destination es lo que la convierte en un espejo):**

```bash
$ azcopy sync '/srv/exports/2026-09/' \
    'https://stprodtelemetryeus01.blob.core.windows.net/telemetry/raw/2026-09/' \
    --recursive=true \
    --delete-destination=true \
    --compare-hash=MD5

INFO: Any empty folders will not be processed, because source and/or destination doesn't have full folder support
INFO: Scanning...
INFO: Comparing hashes; 18422 files at destination

Job 7a2b0d44-1cd8-4c7f-91b6-3e5f8a1d02ce has started

100.0 %, 214 Done, 0 Failed, 0 Pending, 18208 Skipped, 18422 Total,

Job 7a2b0d44-1cd8-4c7f-91b6-3e5f8a1d02ce Summary
Files Scanned at Source: 18422
Files Scanned at Destination: 18422
Elapsed Time (Minutes): 0.4667
Number of Copy Transfers for Files: 214
Number of Deletions at Destination: 3
Total Number of Copy Transfers: 214
Number of Copy Transfers Completed: 214
Number of Copy Transfers Failed: 0
TotalBytesTransferred: 9218447106
Final Job Status: Completed
```

**Copia servidor a servidor (ningún byte atraviesa tu máquina):**

```bash
$ azcopy copy \
    'https://stlegacywesteu01.blob.core.windows.net/archive?<sas>' \
    'https://stprodtelemetryeus01.blob.core.windows.net/archive?<sas>' \
    --recursive=true --s2s-preserve-access-tier=false --block-blob-tier=Archive
```

**Reanudar un job interrumpido — nunca reiniciar desde cero:**

```bash
$ azcopy jobs list
Existing Jobs
JobId: f3c1a90e-7b2d-4e51-a8c2-19d4b7e6f0aa
Start Time: Thursday, 04 Sep 2026 09:12:03
Status: Completed
Command: copy /srv/exports/2026-09/ https://stprodtelemetryeus01.blob.core.windows.net/telemetry/raw/2026-09/ --recursive=true

JobId: 9d81ff02-3e77-4a10-bb54-6c2a0f7b4831
Start Time: Thursday, 04 Sep 2026 10:40:55
Status: CompletedWithErrors
Command: copy /srv/exports/2026-08/ https://stprodtelemetryeus01.blob.core.windows.net/telemetry/raw/2026-08/ --recursive=true

$ azcopy jobs resume 9d81ff02-3e77-4a10-bb54-6c2a0f7b4831
```

**Perillas de ajuste que de verdad mueven el throughput:**

| Variable | Efecto |
|---|---|
| `AZCOPY_CONCURRENCY_VALUE` | Peticiones en paralelo (por defecto: automático según la cantidad de CPUs). Subilo para muchos archivos chicos. |
| `AZCOPY_BUFFER_GB` | RAM usada para los buffers en vuelo. |
| `--cap-mbps` | Limitar para no saturar la WAN de producción. **Configurá esto en horario laboral.** |
| `--block-size-mb` | Bloques más grandes para archivos grandes; más eficiente para objetos de varios GB. |

### 9.3 Azure File Sync — despliegue completo

Azure File Sync convierte a los Windows Servers en un **caché** de un file share de Azure. Los archivos que no están calientes se tierizan a la nube y se reemplazan en el volumen NTFS local por un **reparse point** — el archivo sigue apareciendo en el listado del directorio con su tamaño completo, pero ocupa casi nada de disco local. Abrirlo dispara un recall transparente.

**Topología:** `Storage Sync Service` → `Sync Group` → un **cloud endpoint** (un file share de Azure) + N **server endpoints** (una ruta en un servidor registrado).

```bash
# 1. Create the Storage Sync Service
$ az provider register --namespace Microsoft.StorageSync
$ az storagesync create \
    --resource-group rg-hybrid-prod \
    --name sss-fileservices-eus \
    --location eastus \
    --query "{name:name, state:provisioningState}" -o table
Name                    State
----------------------  ---------
sss-fileservices-eus    Succeeded

# 2. Create the sync group
$ az storagesync sync-group create \
    --resource-group rg-hybrid-prod \
    --storage-sync-service sss-fileservices-eus \
    --name sg-departmental-shares \
    --query "name" -o tsv
sg-departmental-shares

# 3. Cloud endpoint — the Azure file share that is the source of truth
$ az storagesync sync-group cloud-endpoint create \
    --resource-group rg-hybrid-prod \
    --storage-sync-service sss-fileservices-eus \
    --sync-group-name sg-departmental-shares \
    --name ce-departmental \
    --storage-account stprodtelemetryeus01 \
    --azure-file-share-name app-config \
    --query "{name:name, share:azureFileShareName, health:provisioningState}" -o table
Name             Share        Health
---------------  -----------  ---------
ce-departmental  app-config   Succeeded

# 4. Server endpoint — with cloud tiering, keeping 20% of the volume free
$ az storagesync sync-group server-endpoint create \
    --resource-group rg-hybrid-prod \
    --storage-sync-service sss-fileservices-eus \
    --sync-group-name sg-departmental-shares \
    --name se-fs01-e-shares \
    --server-id "6b1f4d92-0c33-4a58-9e2a-77b3c5d18e40" \
    --server-local-path "E:\Shares" \
    --cloud-tiering "on" \
    --volume-free-space-percent 20 \
    --tier-files-older-than-days 30 \
    --offline-data-transfer "off"
```

Registrá primero el servidor (en el Windows Server, después de instalar el agente):

```powershell
PS C:\> Register-AzStorageSyncServer `
    -ParentResourceGroupName "rg-hybrid-prod" `
    -ParentStorageSyncServiceName "sss-fileservices-eus"

ServerName          : FS01.corp.example.com
ServerId            : 6b1f4d92-0c33-4a58-9e2a-77b3c5d18e40
ServerRole          : Standalone
StorageSyncService  : sss-fileservices-eus
ServerOSVersion     : 10.0.20348.0
AgentVersion        : 18.0.0.0
ServerManagementErrorCode : 0
```

**Políticas de cloud tiering — aplican ambas, gana la que tierice más:**

| Política | Comportamiento |
|---|---|
| **Espacio libre del volumen** | Tieriza los archivos más fríos hasta que el N % del volumen quede libre. Siempre activa si el tiering está encendido. |
| **Política por fecha** | Tieriza los archivos no accedidos en N días, sin importar el espacio libre. |

**El modo de fallo que hay que conocer:** un agente de backup o un escaneo completo de antivirus que lee todos los archivos provoca una **tormenta de recalls** — cada archivo tierizado se trae de vuelta desde Azure, llenando el volumen y generando un egress enorme. Configurá el backup para que corra contra el *cloud endpoint* (Azure Backup for Files) o excluí los reparse points; nunca un backup ingenuo de volumen completo en un servidor tierizado.

### 9.4 Familia Azure Data Box

| Dispositivo | Capacidad bruta | Capacidad utilizable | Formato | Interfaces |
|---|---|---|---|---|
| **Data Box Disk** | 8 TB por SSD, hasta 5 discos (40 TB) | ~35 TB | SSDs USB/SATA | USB 3.1 |
| **Data Box** | 100 TB | ~80 TB | Appliance robusto de 50 lb | RJ45 1/10 GbE, SFP+ 10 GbE |
| **Data Box Heavy** | 1 PB | ~770 TB | Gabinete rodante de 500 lb | 4 × 40 GbE QSFP+ |

Todos los dispositivos están cifrados con AES de 256 bits, rastreados de punta a punta y borrados según los estándares NIST SP 800-88r1 después de la carga. Copiás por SMB/NFS o por la interfaz REST, devolvés el dispositivo y Microsoft lo sube a tu storage account.

También existen **Data Box Gateway** (appliance virtual para transferencia online continua) y **Azure Stack Edge** (appliance físico con inferencia acelerada por hardware en el borde que también actúa como gateway de almacenamiento en la nube).

### 9.5 Azure Migrate

Azure Migrate es el **hub**, no una sola herramienta: descubrimiento, análisis de dependencias, evaluación (dimensionamiento más proyección de costos) y migración de servidores (VMware, Hyper-V, físicos, VMs de AWS/GCP), bases de datos SQL, aplicaciones web y escritorios virtuales. Para el AZ-900, lo que importa es la *forma* del flujo de trabajo:

```
Discover  →  Assess (readiness, right-size, cost)  →  Migrate (replicate, test-failover, cut over)
```

Azure Migrate integra la familia Data Box para el tramo de datos masivos de una migración grande.

---

## 10. Verificación y diagnóstico de fallos

### 10.1 Chequeos de salud de línea base

```bash
# What redundancy and tier is this account really running?
$ az storage account show \
    --name stprodtelemetryeus01 --resource-group rg-platform-prod \
    --query "{sku:sku.name, kind:kind, tier:accessTier, tls:minimumTlsVersion, \
              sharedKey:allowSharedKeyAccess, publicNet:publicNetworkAccess, \
              defaultAction:networkAcls.defaultAction}" -o table
Sku              Kind       Tier    Tls       SharedKey    PublicNet    DefaultAction
---------------  ---------  ------  --------  -----------  -----------  ---------------
Standard_GZRS    StorageV2  Hot     TLS1_2    False        Disabled     Deny

# Consumed capacity (the Capacity metric is emitted once per day).
$ az monitor metrics list \
    --resource "/subscriptions/8f1c.../resourceGroups/rg-platform-prod/providers/Microsoft.Storage/storageAccounts/stprodtelemetryeus01" \
    --metric UsedCapacity --interval PT1H --aggregation Average \
    --query "value[0].timeseries[0].data[-1]" -o json
{
  "average": 1341829472118.0,
  "timeStamp": "2026-09-04T11:00:00+00:00"
}

# Availability and end-to-end latency over the last hour.
$ az monitor metrics list \
    --resource "/subscriptions/8f1c.../providers/Microsoft.Storage/storageAccounts/stprodtelemetryeus01/blobServices/default" \
    --metric Availability SuccessE2ELatency SuccessServerLatency \
    --interval PT5M --aggregation Average \
    --query "value[].{metric:name.value, last:timeseries[0].data[-1].average}" -o table
Metric                Last
--------------------  --------
Availability          100.0
SuccessE2ELatency     41.7
SuccessServerLatency  9.2
```

> `SuccessE2ELatency − SuccessServerLatency` es **tiempo de cliente y de red**. Si el E2E es de 400 ms y el del servidor es de 8 ms, el servicio de almacenamiento está sano y tu problema es DNS, handshakes TLS, verborragia de objetos chicos o un cliente sin pooling de conexiones. Esta sola resta resuelve la mayoría de los tickets de "Azure Storage está lento".

### 10.2 Síntoma → causa → comando

| Síntoma / código de error | Causa más probable | Comando de diagnóstico |
|---|---|---|
| `403 AuthorizationPermissionMismatch` | El llamador tiene un rol de plano de control (Owner/Contributor) pero ningún rol de **plano de datos** | `az role assignment list --scope <account-id> --assignee <oid> -o table` |
| `403 AuthorizationFailure` | Denegación por ACL de red — la petición vino de una IP/subred inesperada | `az storage account show --query networkAcls` |
| `403 KeyBasedAuthenticationNotPermitted` | `allowSharedKeyAccess=false` pero el cliente está usando una clave de cuenta o un service SAS | Cambiar el cliente a `DefaultAzureCredential` |
| `403 AuthenticationFailed` + `Signature did not match` | Desfase de reloj del SAS, o el recurso/permisos firmados no coinciden con la petición | Revisar `st`/`se` en el SAS; verificar el NTP del host |
| `409 BlobArchived` | El blob está en Archive; está offline | `az storage blob show --query properties.blobTier` |
| `409 ContainerBeingDeleted` | Recrear un container dentro de la ventana de gracia de borrado | Esperar, o usar otro nombre |
| `503 ServerBusy` / `ClientThrottlingError` | Se alcanzó el límite de 20.000 req/s o de ancho de banda a nivel de cuenta | KQL por `ResponseType` (abajo) |
| `500 OperationTimedOut` | Operación individual muy grande; reintentar con bloques más chicos | Reducir `--block-size-mb` |
| `413` al escribir en un file share | Se alcanzó la cuota del share | `az storage share-rm show --query properties.shareQuota` |
| La URL del blob resuelve a una IP **pública** dentro de la VNet | La zona DNS privada no está vinculada a la VNet, o falta el registro A | `nslookup <acct>.blob.core.windows.net` |
| `mount error(13): Permission denied` en SMB | Se rotó la clave de la storage account, o hay discrepancia de versión TLS/SMB, o el puerto 445 está bloqueado | `nc -zv <acct>.file.core.windows.net 445` |
| Pod de AKS trabado en `ContainerCreating`, evento `MountVolume.MountDevice failed` | El CSI no puede alcanzar la cuenta, o la identidad del kubelet no tiene un rol de datos | `kubectl describe pod`, y después revisar los logs del driver CSI |
| La factura de almacenamiento creció sin crecimiento visible de datos | Snapshots huérfanos, versiones de blob, blobs con soft delete, bloques sin confirmar | Habilitar y leer el desglose de capacidad de **Storage Insights** |

### 10.3 DNS de private endpoint — el "el almacenamiento está caído" más común

```bash
# From inside the VNet: this MUST return a private IP via the privatelink CNAME.
$ nslookup stprodtelemetryeus01.blob.core.windows.net
Server:         168.63.129.16
Address:        168.63.129.16#53

Non-authoritative answer:
stprodtelemetryeus01.blob.core.windows.net  canonical name = stprodtelemetryeus01.privatelink.blob.core.windows.net.
Name:   stprodtelemetryeus01.privatelink.blob.core.windows.net
Address: 10.42.3.14
```

Si en cambio ves una dirección pública `20.x.x.x`, la zona DNS privada `privatelink.blob.core.windows.net` no está vinculada a esta VNet, o nunca se creó el DNS zone group del private endpoint. Con `publicNetworkAccess: Disabled`, cada petición falla entonces con `403 AuthorizationFailure` — un error que *parece* de RBAC y en realidad es de DNS.

```bash
$ az network private-endpoint-connection list \
    --id "/subscriptions/8f1c.../providers/Microsoft.Storage/storageAccounts/stprodtelemetryeus01" \
    --query "[].{name:name, state:properties.privateLinkServiceConnectionState.status}" -o table
Name                                  State
------------------------------------  ---------
pe-stprodtelemetryeus01-blob.5a2c9f1  Approved
pe-stprodtelemetryeus01-file.9d3b7e4  Approved

$ az network private-dns link vnet list \
    --resource-group rg-net-prod \
    --zone-name privatelink.blob.core.windows.net \
    --query "[].{link:name, vnet:virtualNetwork.id, autoreg:registrationEnabled}" -o table
```

### 10.4 Análisis forense de throttling con KQL

Primero habilitá los diagnostic settings (`StorageRead`, `StorageWrite`, `StorageDelete` → Log Analytics), después:

```kusto
// Which response types dominate, and are we being throttled?
StorageBlobLogs
| where TimeGenerated > ago(6h)
| where AccountName == "stprodtelemetryeus01"
| summarize
    Requests = count(),
    P50 = percentile(DurationMs, 50),
    P99 = percentile(DurationMs, 99)
  by StatusCode, StatusText, OperationName
| order by Requests desc
```

```kusto
// Top callers of a throttled account — find the noisy neighbour.
StorageBlobLogs
| where TimeGenerated > ago(1h)
| where StatusText has "ServerBusy" or StatusText has "Throttl"
| summarize ThrottledRequests = count() by CallerIpAddress, UserAgentHeader, AuthenticationType
| top 20 by ThrottledRequests desc
```

```kusto
// Anonymous or Shared Key access that should not exist any more.
StorageBlobLogs
| where TimeGenerated > ago(7d)
| where AuthenticationType in ("AccountKey", "Anonymous", "SAS")
| summarize Requests = count(), FirstSeen = min(TimeGenerated), LastSeen = max(TimeGenerated)
  by AuthenticationType, CallerIpAddress, ObjectKey
| order by Requests desc
```

### 10.5 Alerta de lag de geo-replicación (este es tu SLO de RPO)

```bash
$ az monitor metrics alert create \
    --name alert-storage-geo-rpo-breach \
    --resource-group rg-platform-prod \
    --scopes "/subscriptions/8f1c.../providers/Microsoft.Storage/storageAccounts/stprodtelemetryeus01" \
    --condition "max Availability < 99" \
    --window-size 5m --evaluation-frequency 1m \
    --severity 1 \
    --description "Storage account availability below SLO"
```

Para `lastSyncTime` no hay métrica incorporada — consultá `geoReplicationStats.lastSyncTime` desde un job agendado y alertá cuando `now() - lastSyncTime > 15m`. **Tratá la ausencia de esta alerta como un RPO sin monitorear.**

### 10.6 Checklist de verificación antes de declarar "terminado" un diseño de almacenamiento

- [ ] La redundancia coincide con el RTO/RPO documentado, y alguien corrió un **simulacro de failover planificado**.
- [ ] `allowSharedKeyAccess = false`; todo el acceso es Entra ID + RBAC o user-delegation SAS.
- [ ] `publicNetworkAccess = Disabled` con private endpoints y **DNS verificado desde adentro de la VNet**.
- [ ] `minimumTlsVersion = TLS1_2`, `supportsHttpsTrafficOnly = true`, `allowBlobPublicAccess = false`.
- [ ] Soft delete de blobs, soft delete de containers, versionado y change feed habilitados; días de retención elegidos deliberadamente.
- [ ] La política de ciclo de vida respeta las retenciones mínimas de 30/90/180 días para evitar penalidades por borrado temprano.
- [ ] Diagnostic settings enviando `StorageRead/Write/Delete` a Log Analytics con una retención que sobreviva a tu ventana de auditoría.
- [ ] Alertas sobre `Availability`, `ClientThrottlingError`, `SuccessE2ELatency` y el `lastSyncTime` geo.
- [ ] Margen de capacidad verificado contra los techos de cuenta de 5 PiB y 20.000 req/s; cargas divididas entre cuentas si alguno está al 60 %.
- [ ] Camino de recuperación desde Archive probado de punta a punta, con la aplicación manejando `409 BlobArchived` y una ventana de rehidratación de 15 horas.

---

## 11. Resumen enfocado al examen y las trampas

| Forma de la pregunta | Respuesta correcta | Trampa |
|---|---|---|
| "Almacenamiento más barato para datos accedidos una vez al año, con demora de recuperación aceptable" | **Archive** | Cool/Cold si te salteás el "demora de recuperación aceptable" |
| "Sobrevive a un fallo de datacenter pero se queda en una región" | **ZRS** | LRS sobrevive solo a discos/racks; GRS es entre regiones |
| "El costo más bajo que sobrevive a una caída regional y a una caída de AZ" | **GZRS** | RA-GZRS agrega acceso de lectura que no te pidieron y cuesta más |
| "App de lift-and-shift que necesita `\\fileserver\data`" | **Azure Files** | Blob no se puede montar nativamente como SMB |
| "Desacoplar un front end web de un worker de back end" | **Queue storage** | Table no es una queue; Service Bus es la respuesta solo cuando se requiere orden/transacciones |
| "Guardar metadatos de dispositivos IoT, sin esquema, búsqueda por clave" | **Table storage** | Blob no tiene consulta por clave |
| "Mover 500 TB con un enlace de 50 Mbps" | **Azure Data Box Heavy** | AzCopy tardaría años de tiempo de cable |
| "Mantener los archivos de uso frecuente on-prem y el resto en Azure" | **Azure File Sync** con cloud tiering | AzCopy es de una sola vez, no un caché |
| "Evaluar VMs on-prem y planificar la mudanza" | **Azure Migrate** | Data Box mueve bytes, no evalúa |
| "GUI para navegar y gestionar blobs entre suscripciones" | **Azure Storage Explorer** | AzCopy no tiene GUI |
| "Retención mínima antes de borrar un blob Cool sin penalidad" | **30 días** | Cold es 90, Archive es 180 |
| "Qué tipo de almacenamiento para el volumen de datos de una VM con SQL Server que necesita 20.000 IOPS" | **Premium SSD** (o Premium SSD v2 / Ultra) | Standard SSD llega como máximo a 6.000 IOPS |

**Cinco afirmaciones que vale la pena memorizar textualmente:**

1. La **storage account** es el límite de la redundancia, el firewall, el alcance del cifrado, los límites de throughput y el failover — no el container ni el share.
2. La **geo-replicación es asincrónica** con un objetivo de RPO menor a 15 minutos; el failover no planificado pierde todo lo posterior a `lastSyncTime` y te deja en LRS.
3. **Archive es offline.** La rehidratación tarda hasta 15 horas con prioridad Standard; menos de una hora con prioridad High para objetos de menos de 10 GiB.
4. **El rendimiento de un managed disk es función del SKU y (para Premium SSD / Standard SSD / Standard HDD) del tamaño aprovisionado**; Premium SSD v2 y Ultra desacoplan las IOPS/throughput de la capacidad.
5. **El cifrado en reposo siempre está activo** con AES de 256 bits; la única elección es entre claves administradas por Microsoft y claves administradas por el cliente, más el cifrado de infraestructura (doble) opcional, que debe configurarse al momento de la creación.

---

## 12. Referencias

**Certificación**
- Guía de estudio AZ-900 — https://learn.microsoft.com/en-us/credentials/certifications/resources/study-guides/az-900
- Certificación Azure Fundamentals — https://learn.microsoft.com/en-us/credentials/certifications/azure-fundamentals/

**Storage accounts y servicios**
- Storage account overview — https://learn.microsoft.com/en-us/azure/storage/common/storage-account-overview
- Introduction to Azure Storage — https://learn.microsoft.com/en-us/azure/storage/common/storage-introduction
- Create a storage account — https://learn.microsoft.com/en-us/azure/storage/common/storage-account-create
- Scalability and performance targets for standard storage accounts — https://learn.microsoft.com/en-us/azure/storage/common/scalability-targets-standard-account
- Scalability targets for Blob storage — https://learn.microsoft.com/en-us/azure/storage/blobs/scalability-targets

**Redundancia y recuperación ante desastres**
- Azure Storage redundancy — https://learn.microsoft.com/en-us/azure/storage/common/storage-redundancy
- Disaster recovery and account failover — https://learn.microsoft.com/en-us/azure/storage/common/storage-disaster-recovery-guidance
- Initiate an account failover — https://learn.microsoft.com/en-us/azure/storage/common/storage-initiate-account-failover
- Change how a storage account is replicated — https://learn.microsoft.com/en-us/azure/storage/common/redundancy-migration

**Blob storage, tiers y ciclo de vida**
- Introduction to Blob Storage — https://learn.microsoft.com/en-us/azure/storage/blobs/storage-blobs-introduction
- Access tiers for blob data — https://learn.microsoft.com/en-us/azure/storage/blobs/access-tiers-overview
- Blob rehydration from the Archive tier — https://learn.microsoft.com/en-us/azure/storage/blobs/archive-rehydrate-overview
- Optimize costs by automatically managing the data lifecycle — https://learn.microsoft.com/en-us/azure/storage/blobs/lifecycle-management-overview
- Blob versioning — https://learn.microsoft.com/en-us/azure/storage/blobs/versioning-overview
- Soft delete for blobs — https://learn.microsoft.com/en-us/azure/storage/blobs/soft-delete-blob-overview
- Immutable storage for Blob Storage — https://learn.microsoft.com/en-us/azure/storage/blobs/immutable-storage-overview
- Azure Data Lake Storage introduction — https://learn.microsoft.com/en-us/azure/storage/blobs/data-lake-storage-introduction

**Azure Files, Queues y Tables**
- What is Azure Files? — https://learn.microsoft.com/en-us/azure/storage/files/storage-files-introduction
- Azure Files planning guide — https://learn.microsoft.com/en-us/azure/storage/files/storage-files-planning
- NFS file shares in Azure Files — https://learn.microsoft.com/en-us/azure/storage/files/files-nfs-protocol
- Introduction to Queue Storage — https://learn.microsoft.com/en-us/azure/storage/queues/storage-queues-introduction
- Storage queues and Service Bus queues compared — https://learn.microsoft.com/en-us/azure/service-bus-messaging/service-bus-azure-and-service-bus-queues-compared-contrasted
- Introduction to Table Storage — https://learn.microsoft.com/en-us/azure/storage/tables/table-storage-overview

**Managed disks**
- Introduction to Azure managed disks — https://learn.microsoft.com/en-us/azure/virtual-machines/managed-disks-overview
- Azure managed disk types — https://learn.microsoft.com/en-us/azure/virtual-machines/disks-types
- Azure Premium SSD v2 — https://learn.microsoft.com/en-us/azure/virtual-machines/disks-deploy-premium-v2

**Seguridad**
- Azure Storage encryption for data at rest — https://learn.microsoft.com/en-us/azure/storage/common/storage-service-encryption
- Authorize access to blobs using Microsoft Entra ID — https://learn.microsoft.com/en-us/azure/storage/blobs/authorize-access-azure-active-directory
- Grant limited access with shared access signatures — https://learn.microsoft.com/en-us/azure/storage/common/storage-sas-overview
- Configure Azure Storage firewalls and virtual networks — https://learn.microsoft.com/en-us/azure/storage/common/storage-network-security
- Use private endpoints for Azure Storage — https://learn.microsoft.com/en-us/azure/storage/common/storage-private-endpoints
- Security recommendations for Blob Storage — https://learn.microsoft.com/en-us/azure/storage/blobs/security-recommendations

**Movimiento y migración de datos**
- Get started with AzCopy — https://learn.microsoft.com/en-us/azure/storage/common/storage-use-azcopy-v10
- Optimize AzCopy performance — https://learn.microsoft.com/en-us/azure/storage/common/storage-use-azcopy-optimize
- Azure Storage Explorer — https://learn.microsoft.com/en-us/azure/storage/storage-explorer/vs-azure-tools-storage-manage-with-storage-explorer
- Planning for an Azure File Sync deployment — https://learn.microsoft.com/en-us/azure/storage/file-sync/file-sync-planning
- Deploy Azure File Sync — https://learn.microsoft.com/en-us/azure/storage/file-sync/file-sync-deployment-guide
- Azure File Sync cloud tiering overview — https://learn.microsoft.com/en-us/azure/storage/file-sync/file-sync-cloud-tiering-overview
- What is Azure Data Box? — https://learn.microsoft.com/en-us/azure/databox/data-box-overview
- Azure Data Box Disk overview — https://learn.microsoft.com/en-us/azure/databox/data-box-disk-overview
- Choose an Azure data transfer solution — https://learn.microsoft.com/en-us/azure/storage/common/storage-choose-data-transfer-solution
- About Azure Migrate — https://learn.microsoft.com/en-us/azure/migrate/migrate-services-overview

**Monitoreo y diagnóstico**
- Monitor Azure Storage — https://learn.microsoft.com/en-us/azure/storage/common/monitor-storage
- Azure Storage monitoring data reference — https://learn.microsoft.com/en-us/azure/storage/common/monitor-storage-reference
- Troubleshoot client application errors — https://learn.microsoft.com/en-us/azure/storage/common/troubleshoot-storage-client-application-errors
- Common REST API error codes — https://learn.microsoft.com/en-us/rest/api/storageservices/common-rest-api-error-codes

**Integración con Kubernetes / AKS**
- Azure Disk CSI driver on AKS — https://learn.microsoft.com/en-us/azure/aks/azure-disk-csi
- Azure Files CSI driver on AKS — https://learn.microsoft.com/en-us/azure/aks/azure-files-csi
- Azure Blob Storage CSI driver on AKS — https://learn.microsoft.com/en-us/azure/aks/azure-blob-csi

**Referencia / IaC**
- Referencia de Bicep y ARM de `Microsoft.Storage/storageAccounts` — https://learn.microsoft.com/en-us/azure/templates/microsoft.storage/storageaccounts
- Referencia del CLI `az storage` — https://learn.microsoft.com/en-us/cli/azure/storage
- Terraform `azurerm_storage_account` — https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/storage_account
- SLA for Azure Storage Accounts — https://www.microsoft.com/licensing/docs/view/Service-Level-Agreements-SLA-for-Online-Services