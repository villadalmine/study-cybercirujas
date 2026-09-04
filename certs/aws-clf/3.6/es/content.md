# 3.6 — Identificar los servicios de almacenamiento de AWS

**Certificación:** AWS Certified Cloud Practitioner (CLF-C02), v1.0
**Dominio:** 3 — Tecnología y servicios de la nube
**Peso del enunciado de tarea:** 4.25
**Perfil de audiencia:** SRE / Arquitecto de plataforma. Todo lo que sigue es de grado producción: límites reales, modos de falla reales, facturas reales.

---

## 1. El problema arquitectónico

Una decisión de almacenamiento es la decisión menos reversible de una plataforma. El cómputo es ganado — podés volver a rotar un ASG en diez minutos. La red es configuración. Pero los datos tienen *gravedad*: una vez que hay 40 TB en un sistema de archivos, el costo de migración (ancho de banda, ventana de cutover, riesgo de consistencia, reescritura de la aplicación) crece de forma superlineal con el volumen, y la elección que hiciste el día uno se convierte en una restricción estructural en el año tres.

El modo de falla que este enunciado de tarea existe para prevenir es el **desajuste de paradigma**: elegir una primitiva de almacenamiento cuya semántica de acceso no coincide con el patrón de acceso de la carga de trabajo. Los tres desajustes canónicos, todos los cuales hemos visto causar incidentes en producción:

| Desajuste | Qué hizo el equipo | Qué se rompió |
|---|---|---|
| Objeto usado como bloque | Respaldó un directorio de datos de PostgreSQL con un montaje S3-FUSE | Sin durabilidad de `fsync`, sin escrituras in-place por rango de bytes, sin locking POSIX → corrupción silenciosa bajo escrituras concurrentes |
| Bloque usado como archivo compartido | Adjuntó un volumen EBS a 12 instancias EC2 vía Multi-Attach con `ext4` | No es un sistema de archivos cluster-aware → dos nodos escriben los mismos bloques de journal → corrupción irrecuperable de metadatos |
| Archivo usado como objeto | Almacenó 400 millones de miniaturas de 4 KB en EFS | Sobrecarga de metadatos por archivo + precio por GB 13× S3 Standard → $11k/mes por 1,6 TB de payload real |

Así que la habilidad real no es memorizar una lista de servicios. Es **clasificar la carga de trabajo según cuatro ejes** y después leer la respuesta:

1. **Unidad de acceso** — ¿el cliente direcciona *bloques* (offsets LBA, un dispositivo crudo), *archivos* (rutas POSIX o SMB, directorios, locks, permisos) u *objetos* (PUT/GET inmutable de blob completo por clave)?
2. **Topología de compartición** — ¿un solo escritor, o muchos lectores/escritores concurrentes?
3. **Clase de latencia** — ¿sub-milisegundo (un dígito de milisegundos es demasiado lento), un dígito de milisegundos, decenas de milisegundos u horas (archivado)?
4. **Durabilidad y radio de impacto** — ¿los datos deben sobrevivir a la pérdida de una AZ? ¿De una Región? ¿A un `rm -rf` de un operador? ¿A un evento de ransomware con credenciales válidas?

Todo en el portafolio de almacenamiento de AWS es un punto en ese espacio de cuatro dimensiones. El resto de este documento ubica cada servicio con precisión, con los números que hacen que la ubicación sea defendible en una revisión de diseño.

### 1.1 La línea de responsabilidad compartida para el almacenamiento

Esto es examinable y frecuentemente malinterpretado.

| AWS es responsable de | Vos sos responsable de |
|---|---|
| Medios físicos, decomisado (borrado NIST 800-88), replicación entre hardware de AZs | Elegir una clase cuyo alcance de replicación coincida con tu RPO |
| Disponibilidad del plano de control y del plano de datos del almacenamiento | Políticas de bucket, IAM, ACLs, Block Public Access, endpoints de VPC |
| *Infraestructura* de cifrado (HSMs de KMS, claves de SSE-S3) | *Habilitar* el cifrado, la política de rotación de claves, la imposición de `aws:SecureTransport` |
| Durabilidad de lo que almacenaste | Que lo que almacenaste sea lo que quisiste almacenar — versionado, Object Lock, backup |

La durabilidad del 99,999999999% de S3 protege contra la pérdida de **hardware**. No protege contra una llamada `DeleteObject` con credenciales válidas. Durabilidad ≠ recuperabilidad. Esa distinción es la justificación completa de Versioning, Object Lock y AWS Backup.

---

## 2. La taxonomía completa

```
                        AWS Storage
                             │
   ┌─────────────┬───────────┴────────┬──────────────┬───────────────┐
   │             │                    │              │               │
 BLOCK          FILE                OBJECT         HYBRID/EDGE   DATA MOVEMENT
   │             │                    │              │               │
 ┌─┴──┐    ┌─────┼───────┐      ┌─────┴─────┐   ┌────┴────┐    ┌─────┴─────┐
 EBS  │    EFS   │   FSx family  S3     S3 Glacier  Storage   DataSync
      │          │   ├ Windows   │      ├ Instant   Gateway   Transfer Family
 Instance Store  │   ├ Lustre    │      ├ Flexible  ├ S3 File  S3 Transfer
 (ephemeral      │   ├ ONTAP     │      └ Deep      ├ FSx File   Acceleration
  NVMe/SSD)      │   └ OpenZFS   │        Archive   ├ Volume   Snow Family
                 │               │                  └ Tape
            File Cache     S3 Express One Zone
```

Ortogonales al árbol, tres servicios del **plano de gestión** se aplican a todo él: **AWS Backup** (backup centralizado dirigido por políticas), **AWS Storage Lens** (analítica de flota S3) y **snapshots de AWS Elastic Block Store / Recycle Bin**.

### 2.1 Matriz de decisión — la única tabla que hay que internalizar

| Requisito en el enunciado de la pregunta | Respuesta | Por qué no la vecina |
|---|---|---|
| "Volumen de arranque", "disco persistente para una instancia EC2", "base de datos en EC2" | **EBS** | El instance store es efímero; EFS es NFS, no un dispositivo de bloques |
| "El máximo IOPS posible, temporal, caché/scratch/buffer, pérdida de datos aceptable" | **Instance store** | EBS está conectado por red; no puede igualar la latencia del NVMe local |
| "Sistema de archivos POSIX compartido para muchas instancias Linux / contenedores" | **EFS** | EBS Multi-Attach necesita un FS de clúster; S3 no es POSIX |
| "Recurso compartido de archivos Windows, SMB, integración con Active Directory" | **FSx for Windows File Server** | EFS es solo NFS/Linux |
| "HPC, entrenamiento de machine learning, sub-milisegundo, cientos de GB/s, vinculado a S3" | **FSx for Lustre** | EFS tiene un techo muy inferior y no está vinculado a S3 |
| "Funciones de NetApp — SnapMirror, FlexClone, multiprotocolo NFS+SMB+iSCSI" | **FSx for NetApp ONTAP** | Solo ONTAP ofrece eso |
| "Activos de sitio web estático, backups, data lake, escala ilimitada, 11 nueves" | **S3** | No es un sistema de archivos, pero nada más escala así |
| "Archivado, recuperar en minutos u horas, el costo más bajo" | Familia **S3 Glacier** | Standard-IA cuesta 3–12× más por GB |
| "Retención por cumplimiento, WORM, 7 años, a prueba de reguladores" | **S3 Object Lock (modo Compliance)** + Glacier Deep Archive | El modo Governance puede ser eludido por un usuario privilegiado |
| "Una app on-premises necesita acceso local de baja latencia a almacenamiento respaldado por la nube" | **AWS Storage Gateway** | DataSync copia; Gateway *presenta* |
| "Mover 100 TB, el sitio tiene un enlace de 100 Mbps" | **AWS Snow Family** | Por el cable esto toma ~92 días |
| "Transferencia recurrente, programada, automatizada NFS/SMB → AWS, 10× más rápida que las herramientas open-source" | **AWS DataSync** | Gateway no es una herramienta de migración |
| "Clientes/partners suben vía SFTP, FTPS, FTP a S3/EFS" | **AWS Transfer Family** | Endpoint de protocolo gestionado, sin servidor que operar |
| "Usuarios de todo el mundo suben archivos grandes lentamente a un bucket" | **S3 Transfer Acceleration** | Usa la red de borde de CloudFront + backbone optimizado |
| "Una política, una consola, backups de EBS+EFS+RDS+DynamoDB+FSx+EC2" | **AWS Backup** | El ciclo de vida de snapshots por servicio no centraliza |

---

## 3. Almacenamiento de bloques

### 3.1 Amazon EBS — la mecánica

EBS es **almacenamiento de bloques conectado por red**, no un disco local. Cada lectura y escritura atraviesa la tarjeta Nitro y una red de almacenamiento dedicada hasta un backend replicado dentro de **una sola zona de disponibilidad**. Tres consecuencias que dominan el comportamiento en producción:

1. **Un volumen EBS vive en exactamente una AZ.** Solo puede adjuntarse a instancias en esa AZ. Cruzar una AZ o una Región requiere un snapshot (los snapshots son regionales; copiar para cross-Region).
2. **La latencia tiene un piso de red.** Un dígito de milisegundos para gp3/io2 en Nitro — excelente, pero ~50–100× la latencia del NVMe local. Si tu benchmark necesita menos de 100 µs, EBS es arquitectónicamente la respuesta equivocada.
3. **Se aplican dos techos independientes**: el rendimiento provisionado del *volumen* y el ancho de banda EBS de la *instancia*. Un volumen `io2` provisionado a 64.000 IOPS adjunto a un `m5.large` (4.750 Mbps de línea base EBS, ~593 MiB/s) nunca entregará 64.000 × 16 KiB. Dimensionar el volumen sin dimensionar la instancia es el bug de rendimiento de EBS más común de todos.

#### Tipos de volumen EBS — comparación completa

| | **gp3** | **gp2** (legado) | **io2 / io2 Block Express** | **io1** (legado) | **st1** | **sc1** |
|---|---|---|---|---|---|---|
| Medio | SSD | SSD | SSD | SSD | HDD | HDD |
| Caso de uso | Predeterminado para todo | Superado por gp3 | BD crítica en latencia, SAP HANA, Oracle RAC | Superado por io2 | Big data, procesamiento de logs, lecturas en streaming | Los datos más fríos, escaneos infrecuentes |
| Rango de tamaño | 1 GiB – 16 TiB | 1 GiB – 16 TiB | 4 GiB – 64 TiB | 4 GiB – 16 TiB | 125 GiB – 16 TiB | 125 GiB – 16 TiB |
| IOPS de línea base | **3.000 incluidos** | 3 IOPS/GiB (mín. 100) | Provisionados | Provisionados | 500 (bloques de 1 MiB) | 250 (bloques de 1 MiB) |
| IOPS máx. | 16.000 | 16.000 (a 5.334 GiB) | **256.000** (Block Express) | 64.000 | 500 | 250 |
| Relación máx. IOPS : GiB | 500 : 1 | n/a (3:1 fija) | 1.000 : 1 | 50 : 1 | n/a | n/a |
| Throughput de línea base | **125 MiB/s incluidos** | escala hasta 250 MiB/s | escala con los IOPS | escala con los IOPS | 40 MiB/s por TiB | 12 MiB/s por TiB |
| Throughput máx. | 1.000 MiB/s | 250 MiB/s | **4.000 MiB/s** | 1.000 MiB/s | 500 MiB/s (burst 250 MiB/s por TiB) | 250 MiB/s (burst 80 MiB/s por TiB) |
| Modelo de burst | Ninguno — plano, determinista | Balde de créditos de E/S (burst a 3.000 IOPS si < 1.000 GiB) | Ninguno | Ninguno | Balde de créditos de throughput | Balde de créditos de throughput |
| Durabilidad (AFR) | 99,8 – 99,9% | 99,8 – 99,9% | **99,999%** (0,001% AFR) | 99,8 – 99,9% | 99,8 – 99,9% | 99,8 – 99,9% |
| Booteable | Sí | Sí | Sí | Sí | **No** | **No** |
| Multi-Attach | No | No | **Sí** (hasta 16 instancias Nitro, misma AZ) | Sí | No | No |
| Precio de lista (us-east-1) | $0.08/GB-mes + $0.005/IOPS prov. por encima de 3.000 + $0.040/MB/s prov. por encima de 125 | $0.10/GB-mes | $0.125/GB-mes + IOPS por tramos ($0.065 / $0.046 / $0.032) | $0.125/GB-mes + $0.065/IOPS | $0.045/GB-mes | $0.015/GB-mes |

> **Los precios son de lista en us-east-1, vigentes al momento de escribir.** Confirmá siempre contra la página de precios en vivo (§13) antes de citar una cifra en un documento de diseño — AWS los revisa.

**El arbitraje gp2 → gp3.** Un volumen gp2 de 1 TiB cuesta $102,40/mes y entrega 3.000 IOPS / 250 MiB/s. El mismo 1 TiB en gp3 cuesta $81,92/mes y entrega 3.000 IOPS / 125 MiB/s de línea base; comprar los 125 MiB/s que faltan cuesta $5,00/mes → **$86,92 por un rendimiento idéntico, un ahorro del 15%**, y la migración es un `modify-volume` en línea sin downtime. No existe carga de trabajo donde gp2 sea la elección correcta para algo nuevo.

**La trampa del burst de gp2.** Los volúmenes gp2 por debajo de 1.000 GiB usan un balde de créditos de E/S que se llena a 3 IOPS/GiB-segundo y se consume a 1 crédito por E/S. Un volumen gp2 de 100 GiB tiene una línea base de 300 IOPS y hace burst hasta 3.000. Bajo carga sostenida el balde se drena (`BurstBalance` → 0) y el throughput se derrumba 10× *horas* después del despliegue — el incidente clásico de "en staging funcionaba bien". gp3 no tiene balde de créditos; su rendimiento es plano y determinista. Por eso gp3 es el predeterminado correcto.

#### Elastic Volumes

Podés cambiar el tipo de volumen, el tamaño (solo crecer), los IOPS y el throughput **en línea**, sin desconectar y sin downtime. Hay un **período de enfriamiento de 6 horas** entre modificaciones del mismo volumen. Después de agrandar el volumen todavía tenés que agrandar la partición y el sistema de archivos dentro del guest — AWS no lo hace por vos (§10.2).

### 3.2 Instance store

NVMe/SSD adjunto físicamente al host. Incluido en el precio de la instancia (sin cargo separado). Entrega los IOPS más altos y la latencia más baja disponibles en EC2 — millones de IOPS en las clases `i4i`/`im4gn`.

**Semántica de persistencia — memorizá esto exactamente:**

| Evento | Datos del instance store |
|---|---|
| Reinicio (`reboot`, `aws ec2 reboot-instances`) | **Sobreviven** |
| Stop / Start | **Se pierden** (la instancia se mueve a un host nuevo) |
| Hibernar | **Se pierden** |
| Terminar | **Se pierden** |
| Falla del host subyacente | **Se pierden** |

Usos legítimos en producción: buffers, cachés, espacio scratch, datos de shards replicados donde el clúster mismo provee durabilidad (Cassandra, nodos de datos de Elasticsearch, Kafka con RF≥3). Ilegítimos: cualquier cosa cuya pérdida requiera una restauración.

---

## 4. Almacenamiento de archivos

### 4.1 Amazon EFS

NFSv4.1/4.0, compatible con POSIX, **solo Linux**, elástico — crece y se encoge automáticamente hasta escala de petabytes, pagás solo por lo que está almacenado. Montado concurrentemente por miles de instancias EC2, funciones Lambda, tareas ECS y pods EKS, **en todas las AZs de la Región**.

| Dimensión | Regional (Standard) | One Zone |
|---|---|---|
| Alcance de replicación | ≥ 3 AZs | Una sola AZ |
| Durabilidad de diseño | 99,999999999% | 99,999999999% (dentro de la AZ) |
| Disponibilidad de diseño | 99,99% | 99,90% |
| Precio (clase Standard, us-east-1) | $0.30/GB-mes | $0.16/GB-mes |
| Caso de uso | Estado compartido en producción | Dev/test, analítica de una sola AZ, sensible al costo |

**Clases de almacenamiento y gestión de ciclo de vida** (EFS mueve los archivos entre niveles automáticamente según la hora de último acceso):

| Clase | Precio/GB-mes | Cargo de acceso | Residencia mínima |
|---|---|---|---|
| Standard | $0.30 | ninguno | — |
| Infrequent Access (IA) | $0.016 | $0.01/GB lectura/escritura | 30 días después de la transición |
| Archive | $0.008 | $0.03/GB | 90 días después de la transición |

Un sistema de archivos de 20 TB donde el 95% de los archivos no se toca después de 30 días: $6.144/mes todo en Standard versus ~$614/mes con ciclo de vida a IA — una reducción del 90% a partir de una política de cinco líneas.

**Modos de throughput:**

| Modo | Comportamiento | Cuándo usarlo |
|---|---|---|
| **Elastic** (predeterminado) | Escala hacia arriba y hacia abajo automáticamente; pagás por GB leído/escrito ($0.03/GB lectura, $0.06/GB escritura) | Patrones con picos o desconocidos — el predeterminado correcto |
| **Provisioned** | MiB/s fijos independientes del tamaño almacenado, facturados por hora | Throughput alto y estable sobre un dataset pequeño |
| **Bursting** | Línea base de 50 KiB/s por GiB almacenado, créditos de burst | Legado; los sistemas de archivos pequeños se mueren de hambre |

El modo de falla de **Bursting** refleja el de gp2: un sistema de archivos de 10 GiB obtiene 500 KiB/s de línea base. Una vez que `BurstCreditBalance` llega a cero, un pipeline de CI que lo lee se arrastra. El modo Elastic existe para eliminar esta clase de incidente.

### 4.2 Amazon FSx — cuatro motores distintos

FSx ejecuta **sistemas de archivos de terceros reales** como servicio gestionado. Ese es el punto: obtenés funciones nativas del proveedor y formatos en disco, no una reimplementación de AWS.

| | **FSx for Windows File Server** | **FSx for Lustre** | **FSx for NetApp ONTAP** | **FSx for OpenZFS** |
|---|---|---|---|---|
| Protocolo | SMB 2.0–3.1.1 | Lustre (POSIX) | **NFS + SMB + iSCSI/NVMe-oF** | NFS v3/4/4.1/4.2 |
| Identidad | Active Directory (AWS Managed AD o autogestionado) | UID/GID POSIX | AD + NFS | UID/GID POSIX |
| Capacidad distintiva | DFS Namespaces, Shadow Copies, cuotas | Latencia sub-ms, se vincula a S3 (import/export, Data Repository Associations) | SnapMirror, FlexClone, dedup/compresión, tiering a capacity pool | Snapshots instantáneos point-in-time, clones ZFS, IOPS altos desde la caché ARC |
| Despliegue | Single-AZ / Multi-AZ | Scratch (sin replicación) / Persistent (replicado dentro de la AZ) | Single-AZ / Multi-AZ | Single-AZ / Multi-AZ |
| Throughput pico | hasta ~2 GB/s+ | **cientos de GB/s** (escala por TiB) | hasta ~4 GB/s por par HA | hasta ~21 GB/s desde caché |
| Carga de trabajo clásica | Lift-and-shift de apps Windows, directorios home, SQL Server FCI | HPC, genómica, CFD, entrenamiento de ML sobre un data lake en S3 | Migración empresarial de NetApp, parques multiprotocolo | Migración de apps Linux desde ZFS/NFS on-prem |

**FSx for Lustre + S3 es el patrón a recordar para ML/HPC:** el dataset vive de forma durable y barata en S3; un sistema de archivos Lustre se vincula al bucket, carga los objetos de forma perezosa en el primer acceso, los presenta como archivos POSIX con latencia sub-milisegundo a la flota de entrenamiento, y exporta los resultados de vuelta a S3. Después los sistemas de archivos scratch se destruyen. El costo de almacenamiento es el de S3; el rendimiento es el de Lustre.

**Amazon File Cache** es la generalización: una caché de alta velocidad, totalmente gestionada, delante de datasets *dispersos* — NFS on-premises, buckets S3 en otras Regiones — presentados como un solo namespace para llevar cargas de trabajo en burst a AWS.

---

## 5. Almacenamiento de objetos

### 5.1 Amazon S3 — la mecánica

Namespace plano clave/valor dentro de un **nombre de bucket globalmente único**. No hay directorios reales — `logs/2026/09/04/app.log` es una sola clave opaca; la consola renderiza `/` como carpetas. Los objetos son **inmutables**: no hay actualización parcial, solo un PUT completo (o una carga multiparte ensamblada del lado del servidor).

Límites duros que conviene conocer:

| Límite | Valor |
|---|---|
| Tamaño máximo de objeto | 5 TB |
| PUT simple máximo | 5 GB (multiparte requerido por encima; recomendado por encima de 100 MB) |
| Multiparte: máx. partes / tamaño de parte | 10.000 partes / 5 MB–5 GB cada una |
| Tasa de solicitudes | **3.500 PUT/COPY/POST/DELETE y 5.500 GET/HEAD por segundo, por prefijo particionado** — y los prefijos escalan horizontalmente sin límite |
| Consistencia | **Read-after-write fuerte** para PUT, DELETE y LIST, en todas las solicitudes, sin costo extra (desde diciembre de 2020) |
| Buckets por cuenta | 10.000 de propósito general (blando, elevable a 1M) |

Durabilidad de diseño en todas las clases excepto las variantes One Zone: **99,999999999% (11 nueves)**, lograda escribiendo sincrónicamente en ≥3 zonas de disponibilidad. Ese número significa: almacená 10 millones de objetos y deberías esperar perder uno cada 10.000 años.

#### Clases de almacenamiento — comparación completa

| Clase | AZs | Disponibilidad de diseño | $/GB-mes (us-east-1) | Cargo por recuperación | Duración mín. facturable | Tamaño mín. facturable de objeto | Latencia del primer byte |
|---|---|---|---|---|---|---|---|
| **S3 Standard** | ≥3 | 99,99% | $0.023 | ninguno | ninguna | ninguno | ms |
| **S3 Intelligent-Tiering** | ≥3 | 99,9% | $0.023 → $0.0125 → $0.004 (automático) + $0.0025 por cada 1.000 objetos monitoreados | **ninguno** | ninguna (sin penalidad) | los objetos < 128 KB nunca cambian de nivel | ms (niveles instantáneos) |
| **S3 Standard-IA** | ≥3 | 99,9% | $0.0125 | $0.01/GB | **30 días** | **128 KB** | ms |
| **S3 One Zone-IA** | **1** | 99,5% | $0.01 | $0.01/GB | 30 días | 128 KB | ms |
| **S3 Express One Zone** | 1 (zonal) | 99,95% | $0.16 | ninguno (mayor costo por solicitud) | 1 hora | ninguno | **un dígito de ms, ~10× más rápido** |
| **S3 Glacier Instant Retrieval** | ≥3 | 99,9% | $0.004 | $0.03/GB | **90 días** | 128 KB | ms |
| **S3 Glacier Flexible Retrieval** | ≥3 | 99,99% | $0.0036 | por tramos | **90 días** | 40 KB | Expedited 1–5 min / Standard 3–5 h / **Bulk 5–12 h (gratis)** |
| **S3 Glacier Deep Archive** | ≥3 | 99,99% | $0.00099 | por tramos | **180 días** | 40 KB | Standard 12 h / Bulk 48 h |

**El cargo por duración mínima es la trampa más cara de esta tabla.** Transferí por ciclo de vida 10 TB de logs a Glacier Deep Archive y después borralos 20 días más tarde: te facturan 180 días de todos modos. Deep Archive es para datos que estás *seguro* de que vas a conservar — archivos de cumplimiento, no datos "probablemente obsoletos".

**La trampa del tamaño mínimo facturable es la segunda.** 50 millones de objetos de 8 KB = 400 GB de datos reales. En Standard-IA cada uno se factura a 128 KB → **6,4 TB facturados**, $80/mes en lugar de los $9,20/mes que amerita el payload — *más* que S3 Standard. Las clases IA son para objetos grandes y leídos con poca frecuencia. Los objetos pequeños pertenecen a Standard, o se agregan.

**Cuando genuinamente no conocés el patrón de acceso, la respuesta es Intelligent-Tiering.** No tiene cargos de recuperación ni duración mínima; el único costo es $0.0025 por cada 1.000 objetos monitoreados. El punto de equilibrio es aproximadamente: vale la pena cuando el tamaño promedio de objeto supera los ~128 KB y el acceso es impredecible.

### 5.2 Funciones de protección de datos de S3

| Función | Qué hace | Nota de producción |
|---|---|---|
| **Versioning** | Cada PUT crea una nueva versión; DELETE inserta un marcador de borrado | Prerrequisito de Replication, Object Lock y MFA Delete. No puede *deshabilitarse* una vez habilitado — solo suspenderse |
| **MFA Delete** | Requiere un token MFA para borrar permanentemente una versión o suspender el versionado | Solo el root puede configurarlo, solo por CLI. Bloquea el borrado por credenciales comprometidas |
| **Object Lock** | WORM. Modo **Governance** (eludible con `s3:BypassGovernanceRetention`) o modo **Compliance** (eludible por *nadie*, incluido el root, hasta que expire la retención) + **Legal Hold** (indefinido, sin fecha) | Debe habilitarse al crear el bucket. El modo Compliance es irreversible — una retención de 7 años mal configurada sobre 500 TB es una factura de 7 años |
| **Replication (SRR/CRR)** | Copia asíncrona a otro bucket, misma o distinta Región/cuenta | Requiere versionado en ambos extremos. Agregá **S3 Replication Time Control** para un SLA de 15 minutos. *No* replica los objetos preexistentes salvo que ejecutes Batch Replication |
| **Lifecycle** | Transición entre clases, expiración de objetos, expiración de versiones no actuales, aborto de cargas multiparte incompletas | Agregá siempre `AbortIncompleteMultipartUpload` — las partes huérfanas son invisibles a `ls` y se facturan para siempre |
| **Block Public Access** | Cuatro interruptores independientes, evaluados *antes* de las políticas/ACLs | Activado por defecto a nivel de cuenta y de bucket desde abril de 2023. Desactivalo solo con una justificación escrita |
| **Encryption** | SSE-S3 (AES-256, **aplicado por defecto a todos los objetos nuevos desde enero de 2023**), SSE-KMS, DSSE-KMS, SSE-C | Con SSE-KMS, habilitá **S3 Bucket Keys** — reduce las llamadas a la API de KMS y el costo hasta un 99% |

---

## 6. Híbrido, borde y movimiento de datos

### 6.1 AWS Storage Gateway

Un appliance virtual (VM, appliance de hardware o instancia EC2) on-premises que **presenta un protocolo local estándar y lo respalda con almacenamiento de AWS**, con una caché local para acceso de baja latencia al conjunto de trabajo caliente.

| Tipo de gateway | Protocolo on-prem | Respaldo en AWS | Caso de uso |
|---|---|---|---|
| **S3 File Gateway** | NFS / SMB | Objetos S3 (1 archivo = 1 objeto) | Mover cargas de archivos a S3 mientras las apps siguen usando rutas de archivo |
| **FSx File Gateway** | SMB | FSx for Windows File Server | Acceso on-prem de baja latencia a un recurso compartido Windows en la nube |
| **Volume Gateway — Cached** | iSCSI | S3, con caché local | Datos primarios en AWS, datos calientes cacheados localmente |
| **Volume Gateway — Stored** | iSCSI | Primario local, backup asíncrono a snapshots de EBS | Los datos primarios quedan locales, DR de bajo RTO en AWS |
| **Tape Gateway (VTL)** | VTL iSCSI | S3 Glacier / Deep Archive | Retirar una biblioteca de cintas física sin cambiar el software de backup |

**Gateway vs DataSync** es un discriminador a nivel de enunciado: Gateway *presenta* almacenamiento de forma continua (acceso híbrido permanente); DataSync lo *transfiere* (una migración o un trabajo de replicación programado, y después termina).

### 6.2 AWS Snow Family

Dispositivos físicos, robustecidos, con evidencia de manipulación, enviados a tu sitio para transferencia offline, con cifrado a bordo (claves gestionadas por KMS, nunca almacenadas en el dispositivo) y cómputo de borde opcional (instancias EC2, Lambda, EKS Anywhere).

La aritmética que los justifica: **100 TB sobre un enlace de 100 Mbps saturado ≈ 92 días.** Sobre 1 Gbps ≈ 9 días, asumiendo que tenés el enlace completo y cero contención — lo cual no es cierto. Por debajo de aproximadamente 10 TB, o por encima de ~1 Gbps de ancho de banda genuinamente libre, usá la red (DataSync). Por encima de eso, mandá la caja.

> **Advertencia de vigencia:** AWS ha estado racionalizando activamente esta familia — **AWS Snowmobile (el contenedor de envío de 100 PB) fue retirado en 2024**, y los SKUs y capacidades de dispositivos han cambiado desde entonces. Los bancos de preguntas de CLF-C02 escritos antes pueden seguir referenciando dispositivos retirados. Verificá las ofertas y capacidades actuales en la página de Snow Family (§13) antes de citar un modelo específico o una cifra de TB.

### 6.3 Servicios de movimiento de datos

| Servicio | Dirección y disparador | Propiedad clave |
|---|---|---|
| **AWS DataSync** | NFS/SMB/HDFS/objetos on-prem ↔ S3/EFS/FSx, y AWS↔AWS | Basado en agente, programado o puntual, verificación de integridad incorporada, cifrado en tránsito, hasta 10× más rápido que las herramientas de copia open-source |
| **AWS Transfer Family** | Terceros externos → S3/EFS sobre **SFTP, FTPS, FTP, AS2** | Endpoint de protocolo totalmente gestionado; sin servidores, mantiene funcionando los clientes existentes de los partners |
| **S3 Transfer Acceleration** | Clientes de todo el mundo → un bucket | Enruta las cargas por el borde de CloudFront más cercano hacia el backbone de AWS |
| **AWS Backup** | Backup dirigido por políticas de EBS, EFS, FSx, S3, RDS, Aurora, DynamoDB, DocumentDB, Neptune, EC2, Storage Gateway, VMware | Bóveda central + ciclo de vida a almacenamiento frío + **Vault Lock (WORM)** + copia cross-Region/cross-account + reportes de cumplimiento |

---

## 7. Infraestructura completa — CloudFormation

Una única plantilla desplegable que cubre las tres primitivas con valores predeterminados de producción: clave KMS gestionada por el cliente, S3 con versionado + ciclo de vida + política que impone TLS y cifrado + logging de acceso, EFS con throughput elastic y tiering por ciclo de vida, un volumen de datos gp3, y un plan de AWS Backup con una bóveda bloqueada.

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: >
  Production storage baseline - S3 (object), EFS (file), EBS gp3 (block),
  a customer-managed KMS key, and an AWS Backup plan with a WORM-locked vault.

Parameters:
  ProjectName:
    Type: String
    Default: platform-storage
    AllowedPattern: '^[a-z0-9-]{3,32}$'
    Description: Lowercase name used as a prefix for every resource.

  VpcId:
    Type: AWS::EC2::VPC::Id
    Description: VPC that will host the EFS mount targets.

  PrivateSubnetIds:
    Type: List<AWS::EC2::Subnet::Id>
    Description: Exactly three private subnets, one per Availability Zone.

  AppSecurityGroupId:
    Type: AWS::EC2::SecurityGroup::Id
    Description: Security group attached to the application instances/pods.

  DataVolumeAz:
    Type: AWS::EC2::AvailabilityZone::Name
    Description: AZ for the EBS data volume. Must match the consuming instance.

  DataVolumeSizeGiB:
    Type: Number
    Default: 500
    MinValue: 1
    MaxValue: 16384

  BackupRetentionDays:
    Type: Number
    Default: 35
    MinValue: 1
    MaxValue: 36500

Resources:

  # ------------------------------------------------------------------
  # Encryption - one customer-managed key for all storage in the stack
  # ------------------------------------------------------------------
  StorageKmsKey:
    Type: AWS::KMS::Key
    DeletionPolicy: Retain
    UpdateReplacePolicy: Retain
    Properties:
      Description: !Sub 'CMK for ${ProjectName} S3, EFS and EBS encryption'
      EnableKeyRotation: true
      PendingWindowInDays: 30
      KeyPolicy:
        Version: '2012-10-17'
        Statement:
          - Sid: EnableIAMUserPermissions
            Effect: Allow
            Principal:
              AWS: !Sub 'arn:${AWS::Partition}:iam::${AWS::AccountId}:root'
            Action: 'kms:*'
            Resource: '*'
          - Sid: AllowAwsServicesToUseTheKey
            Effect: Allow
            Principal:
              Service:
                - s3.amazonaws.com
                - elasticfilesystem.amazonaws.com
                - backup.amazonaws.com
            Action:
              - kms:Encrypt
              - kms:Decrypt
              - kms:ReEncrypt*
              - kms:GenerateDataKey*
              - kms:DescribeKey
              - kms:CreateGrant
            Resource: '*'
            Condition:
              StringEquals:
                'kms:CallerAccount': !Ref AWS::AccountId
      Tags:
        - Key: Project
          Value: !Ref ProjectName

  StorageKmsAlias:
    Type: AWS::KMS::Alias
    Properties:
      AliasName: !Sub 'alias/${ProjectName}-storage'
      TargetKeyId: !Ref StorageKmsKey

  # ------------------------------------------------------------------
  # Object storage - access log bucket first, then the data bucket
  # ------------------------------------------------------------------
  AccessLogBucket:
    Type: AWS::S3::Bucket
    DeletionPolicy: Retain
    UpdateReplacePolicy: Retain
    Properties:
      BucketName: !Sub '${ProjectName}-access-logs-${AWS::AccountId}-${AWS::Region}'
      # S3 server access logging cannot write to an SSE-KMS bucket, so this
      # bucket deliberately uses SSE-S3 (AES256) instead of the CMK.
      BucketEncryption:
        ServerSideEncryptionConfiguration:
          - ServerSideEncryptionByDefault:
              SSEAlgorithm: AES256
            BucketKeyEnabled: true
      PublicAccessBlockConfiguration:
        BlockPublicAcls: true
        BlockPublicPolicy: true
        IgnorePublicAcls: true
        RestrictPublicBuckets: true
      OwnershipControls:
        Rules:
          - ObjectOwnership: BucketOwnerEnforced
      VersioningConfiguration:
        Status: Enabled
      LifecycleConfiguration:
        Rules:
          - Id: expire-access-logs
            Status: Enabled
            ExpirationInDays: 400
            NoncurrentVersionExpiration:
              NoncurrentDays: 30
            AbortIncompleteMultipartUpload:
              DaysAfterInitiation: 7
      Tags:
        - Key: Project
          Value: !Ref ProjectName

  AccessLogBucketPolicy:
    Type: AWS::S3::BucketPolicy
    Properties:
      Bucket: !Ref AccessLogBucket
      PolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Sid: AllowS3ServerAccessLogging
            Effect: Allow
            Principal:
              Service: logging.s3.amazonaws.com
            Action: 's3:PutObject'
            Resource: !Sub '${AccessLogBucket.Arn}/s3-access/*'
            Condition:
              StringEquals:
                'aws:SourceAccount': !Ref AWS::AccountId
          - Sid: DenyInsecureTransport
            Effect: Deny
            Principal: '*'
            Action: 's3:*'
            Resource:
              - !GetAtt AccessLogBucket.Arn
              - !Sub '${AccessLogBucket.Arn}/*'
            Condition:
              Bool:
                'aws:SecureTransport': 'false'

  DataBucket:
    Type: AWS::S3::Bucket
    DeletionPolicy: Retain
    UpdateReplacePolicy: Retain
    Properties:
      BucketName: !Sub '${ProjectName}-data-${AWS::AccountId}-${AWS::Region}'
      BucketEncryption:
        ServerSideEncryptionConfiguration:
          - ServerSideEncryptionByDefault:
              SSEAlgorithm: 'aws:kms'
              KMSMasterKeyID: !GetAtt StorageKmsKey.Arn
            # Bucket Keys cut KMS request cost by up to 99%.
            BucketKeyEnabled: true
      PublicAccessBlockConfiguration:
        BlockPublicAcls: true
        BlockPublicPolicy: true
        IgnorePublicAcls: true
        RestrictPublicBuckets: true
      OwnershipControls:
        Rules:
          - ObjectOwnership: BucketOwnerEnforced
      VersioningConfiguration:
        Status: Enabled
      LoggingConfiguration:
        DestinationBucketName: !Ref AccessLogBucket
        LogFilePrefix: s3-access/
      LifecycleConfiguration:
        Rules:
          - Id: tier-current-versions
            Status: Enabled
            Prefix: ''
            Transitions:
              # Standard -> Standard-IA is only legal at 30 days or more.
              - StorageClass: STANDARD_IA
                TransitionInDays: 30
              - StorageClass: GLACIER_IR
                TransitionInDays: 90
              - StorageClass: DEEP_ARCHIVE
                TransitionInDays: 365
            Id: tier-current-versions
          - Id: tier-and-expire-noncurrent-versions
            Status: Enabled
            NoncurrentVersionTransitions:
              - StorageClass: STANDARD_IA
                TransitionInDays: 30
            NoncurrentVersionExpiration:
              NoncurrentDays: 180
              NewerNoncurrentVersions: 5
          - Id: housekeeping
            Status: Enabled
            AbortIncompleteMultipartUpload:
              DaysAfterInitiation: 7
            ExpiredObjectDeleteMarker: true
      Tags:
        - Key: Project
          Value: !Ref ProjectName

  DataBucketPolicy:
    Type: AWS::S3::BucketPolicy
    Properties:
      Bucket: !Ref DataBucket
      PolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Sid: DenyInsecureTransport
            Effect: Deny
            Principal: '*'
            Action: 's3:*'
            Resource:
              - !GetAtt DataBucket.Arn
              - !Sub '${DataBucket.Arn}/*'
            Condition:
              Bool:
                'aws:SecureTransport': 'false'
          - Sid: DenyUnencryptedObjectUploads
            Effect: Deny
            Principal: '*'
            Action: 's3:PutObject'
            Resource: !Sub '${DataBucket.Arn}/*'
            Condition:
              StringNotEquals:
                's3:x-amz-server-side-encryption': 'aws:kms'
          - Sid: DenyWrongKmsKey
            Effect: Deny
            Principal: '*'
            Action: 's3:PutObject'
            Resource: !Sub '${DataBucket.Arn}/*'
            Condition:
              StringNotEqualsIfExists:
                's3:x-amz-server-side-encryption-aws-kms-key-id': !GetAtt StorageKmsKey.Arn
          - Sid: DenyOutdatedTlsVersions
            Effect: Deny
            Principal: '*'
            Action: 's3:*'
            Resource:
              - !GetAtt DataBucket.Arn
              - !Sub '${DataBucket.Arn}/*'
            Condition:
              NumericLessThan:
                's3:TlsVersion': '1.2'

  # ------------------------------------------------------------------
  # File storage - EFS, elastic throughput, lifecycle tiering
  # ------------------------------------------------------------------
  EfsSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: !Sub 'NFS 2049 ingress for ${ProjectName} EFS'
      VpcId: !Ref VpcId
      SecurityGroupIngress:
        - IpProtocol: tcp
          FromPort: 2049
          ToPort: 2049
          SourceSecurityGroupId: !Ref AppSecurityGroupId
          Description: NFSv4.1 from the application security group
      SecurityGroupEgress:
        - IpProtocol: '-1'
          CidrIp: 0.0.0.0/0
          Description: Allow all egress
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-efs-sg'

  SharedFileSystem:
    Type: AWS::EFS::FileSystem
    DeletionPolicy: Retain
    UpdateReplacePolicy: Retain
    Properties:
      Encrypted: true
      KmsKeyId: !GetAtt StorageKmsKey.Arn
      PerformanceMode: generalPurpose
      ThroughputMode: elastic
      BackupPolicy:
        Status: ENABLED
      LifecyclePolicies:
        - TransitionToIA: AFTER_30_DAYS
        - TransitionToArchive: AFTER_90_DAYS
        - TransitionToPrimaryStorageClass: AFTER_1_ACCESS
      FileSystemPolicy:
        Version: '2012-10-17'
        Statement:
          - Sid: EnforceInTransitEncryption
            Effect: Deny
            Principal:
              AWS: '*'
            Action: '*'
            Condition:
              Bool:
                'elasticfilesystem:AccessedViaMountTarget': 'true'
                'aws:SecureTransport': 'false'
      FileSystemTags:
        - Key: Name
          Value: !Sub '${ProjectName}-shared'
        - Key: Project
          Value: !Ref ProjectName

  MountTargetA:
    Type: AWS::EFS::MountTarget
    Properties:
      FileSystemId: !Ref SharedFileSystem
      SubnetId: !Select [0, !Ref PrivateSubnetIds]
      SecurityGroups:
        - !Ref EfsSecurityGroup

  MountTargetB:
    Type: AWS::EFS::MountTarget
    Properties:
      FileSystemId: !Ref SharedFileSystem
      SubnetId: !Select [1, !Ref PrivateSubnetIds]
      SecurityGroups:
        - !Ref EfsSecurityGroup

  MountTargetC:
    Type: AWS::EFS::MountTarget
    Properties:
      FileSystemId: !Ref SharedFileSystem
      SubnetId: !Select [2, !Ref PrivateSubnetIds]
      SecurityGroups:
        - !Ref EfsSecurityGroup

  AppAccessPoint:
    Type: AWS::EFS::AccessPoint
    Properties:
      FileSystemId: !Ref SharedFileSystem
      PosixUser:
        Uid: '1000'
        Gid: '1000'
        SecondaryGids:
          - '1001'
      RootDirectory:
        Path: /app-data
        CreationInfo:
          OwnerUid: '1000'
          OwnerGid: '1000'
          Permissions: '0755'
      AccessPointTags:
        - Key: Name
          Value: !Sub '${ProjectName}-app-ap'

  # ------------------------------------------------------------------
  # Block storage - gp3 with explicit IOPS and throughput
  # ------------------------------------------------------------------
  DataVolume:
    Type: AWS::EC2::Volume
    DeletionPolicy: Snapshot
    UpdateReplacePolicy: Snapshot
    Properties:
      AvailabilityZone: !Ref DataVolumeAz
      Size: !Ref DataVolumeSizeGiB
      VolumeType: gp3
      Iops: 6000
      Throughput: 250
      Encrypted: true
      KmsKeyId: !GetAtt StorageKmsKey.Arn
      Tags:
        - Key: Name
          Value: !Sub '${ProjectName}-data'
        - Key: BackupPlan
          Value: !Ref ProjectName

  # ------------------------------------------------------------------
  # AWS Backup - one plan for every resource tagged BackupPlan
  # ------------------------------------------------------------------
  BackupVault:
    Type: AWS::Backup::BackupVault
    DeletionPolicy: Retain
    UpdateReplacePolicy: Retain
    Properties:
      BackupVaultName: !Sub '${ProjectName}-vault'
      EncryptionKeyArn: !GetAtt StorageKmsKey.Arn
      LockConfiguration:
        # WORM: recovery points cannot be deleted before MinRetentionDays,
        # not even by the account root. ChangeableForDays is the grace
        # period during which this lock itself can still be removed.
        MinRetentionDays: 7
        MaxRetentionDays: !Ref BackupRetentionDays
        ChangeableForDays: 3

  BackupRole:
    Type: AWS::IAM::Role
    Properties:
      RoleName: !Sub '${ProjectName}-backup-role'
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              Service: backup.amazonaws.com
            Action: 'sts:AssumeRole'
      ManagedPolicyArns:
        - !Sub 'arn:${AWS::Partition}:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup'
        - !Sub 'arn:${AWS::Partition}:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores'

  BackupPlan:
    Type: AWS::Backup::BackupPlan
    Properties:
      BackupPlan:
        BackupPlanName: !Sub '${ProjectName}-daily'
        BackupPlanRule:
          - RuleName: daily-0300-utc
            TargetBackupVault: !Ref BackupVault
            ScheduleExpression: 'cron(0 3 * * ? *)'
            StartWindowMinutes: 60
            CompletionWindowMinutes: 180
            EnableContinuousBackup: false
            Lifecycle:
              MoveToColdStorageAfterDays: 30
              DeleteAfterDays: !Ref BackupRetentionDays
            RecoveryPointTags:
              Project: !Ref ProjectName

  BackupSelection:
    Type: AWS::Backup::BackupSelection
    Properties:
      BackupPlanId: !Ref BackupPlan
      BackupSelection:
        SelectionName: !Sub '${ProjectName}-tagged-resources'
        IamRoleArn: !GetAtt BackupRole.Arn
        ListOfTags:
          - ConditionType: STRINGEQUALS
            ConditionKey: BackupPlan
            ConditionValue: !Ref ProjectName

Outputs:
  DataBucketName:
    Description: Object storage bucket
    Value: !Ref DataBucket
    Export:
      Name: !Sub '${ProjectName}-data-bucket'

  FileSystemId:
    Description: EFS file system id
    Value: !Ref SharedFileSystem
    Export:
      Name: !Sub '${ProjectName}-efs-id'

  FileSystemDnsName:
    Description: DNS name for mounting the file system
    Value: !Sub '${SharedFileSystem}.efs.${AWS::Region}.amazonaws.com'

  AccessPointId:
    Description: EFS access point for the application
    Value: !Ref AppAccessPoint
    Export:
      Name: !Sub '${ProjectName}-efs-ap'

  DataVolumeId:
    Description: gp3 data volume id
    Value: !Ref DataVolume

  KmsKeyArn:
    Description: CMK protecting all storage in this stack
    Value: !GetAtt StorageKmsKey.Arn
```

Desplegar:

```console
$ aws cloudformation deploy \
    --template-file storage-baseline.yaml \
    --stack-name platform-storage \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameter-overrides \
        ProjectName=platform-storage \
        VpcId=vpc-0a1b2c3d4e5f67890 \
        PrivateSubnetIds=subnet-0aa1,subnet-0bb2,subnet-0cc3 \
        AppSecurityGroupId=sg-041f2e3d4c5b6a798 \
        DataVolumeAz=us-east-1a

Waiting for changeset to be created..
Waiting for stack create/update to complete
Successfully created/updated stack - platform-storage
```

---

## 8. Manifiestos CSI de Kubernetes

Las mismas tres primitivas, expresadas a través de los drivers CSI de EBS y EFS en EKS. Así es como un equipo de plataforma consume realmente el almacenamiento de AWS.

```yaml
---
# gp3 block storage. Note WaitForFirstConsumer: an EBS volume is
# AZ-bound, so binding must wait until the scheduler picks a node.
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ebs-gp3-encrypted
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
reclaimPolicy: Delete
parameters:
  type: gp3
  iops: "6000"
  throughput: "250"
  encrypted: "true"
  kmsKeyId: arn:aws:kms:us-east-1:111122223333:key/1a2b3c4d-5e6f-7081-92a3-b4c5d6e7f809
  csi.storage.k8s.io/fstype: ext4
  tagSpecification_1: "Project=platform-storage"
  tagSpecification_2: "BackupPlan=platform-storage"
---
# io2 for a latency-critical stateful set.
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ebs-io2-critical
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
reclaimPolicy: Retain
parameters:
  type: io2
  iops: "20000"
  encrypted: "true"
  csi.storage.k8s.io/fstype: xfs
---
# Shared EFS with dynamic access-point provisioning. ReadWriteMany
# is possible here and impossible with EBS.
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: efs-shared
provisioner: efs.csi.aws.com
reclaimPolicy: Retain
parameters:
  provisioningMode: efs-ap
  fileSystemId: fs-0c9d8e7f6a5b4c3d2
  directoryPerms: "0755"
  uid: "1000"
  gid: "1000"
  basePath: /dynamic
  subPathPattern: "${.PVC.namespace}/${.PVC.name}"
  ensureUniqueDirectory: "true"
mountOptions:
  - tls
  - iam
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-data
  namespace: data
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: ebs-io2-critical
  resources:
    requests:
      storage: 500Gi
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: shared-uploads
  namespace: web
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: efs-shared
  resources:
    requests:
      # EFS is elastic; this value is required by the API but not enforced.
      storage: 100Gi
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
  namespace: data
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
      containers:
        - name: postgres
          image: postgres:16.4
          ports:
            - containerPort: 5432
              name: postgres
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
            - name: scratch
              mountPath: /scratch
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: postgres-data
        - name: scratch
          emptyDir:
            medium: Memory
            sizeLimit: 2Gi
```

---

## 9. Recorridos por CLI con salida real

### 9.1 EBS — crear, adjuntar, verificar, agrandar

```console
$ aws ec2 create-volume \
    --availability-zone us-east-1a \
    --size 500 \
    --volume-type gp3 \
    --iops 6000 \
    --throughput 250 \
    --encrypted \
    --tag-specifications 'ResourceType=volume,Tags=[{Key=Name,Value=platform-data}]'
{
    "AvailabilityZone": "us-east-1a",
    "CreateTime": "2026-09-04T11:42:18.000Z",
    "Encrypted": true,
    "KmsKeyId": "arn:aws:kms:us-east-1:111122223333:key/1a2b3c4d-5e6f-7081-92a3-b4c5d6e7f809",
    "Size": 500,
    "State": "creating",
    "VolumeId": "vol-0f3a9c81b7e2d4506",
    "Iops": 6000,
    "Throughput": 250,
    "VolumeType": "gp3",
    "MultiAttachEnabled": false
}

$ aws ec2 attach-volume \
    --volume-id vol-0f3a9c81b7e2d4506 \
    --instance-id i-0b7c4e2f19a8d3056 \
    --device /dev/sdf
{
    "AttachTime": "2026-09-04T11:43:02.412000+00:00",
    "Device": "/dev/sdf",
    "InstanceId": "i-0b7c4e2f19a8d3056",
    "State": "attaching",
    "VolumeId": "vol-0f3a9c81b7e2d4506"
}
```

En la instancia — notá que en Nitro el nombre de dispositivo que pediste **no** es el nombre de dispositivo que obtenés:

```console
$ lsblk
NAME          MAJ:MIN RM  SIZE RO TYPE MOUNTPOINTS
nvme0n1       259:0    0    8G  0 disk
├─nvme0n1p1   259:1    0    8G  0 part /
└─nvme0n1p128 259:2    0    1M  0 part
nvme1n1       259:3    0  500G  0 disk

$ sudo nvme id-ctrl -v /dev/nvme1n1 | grep -i '^sn\|0000:'
sn        : vol0f3a9c81b7e2d4506
0000: 2f 64 65 76 2f 73 64 66 20 20 20 20 20 20 20 20  "/dev/sdf        "

$ sudo mkfs -t xfs /dev/nvme1n1
meta-data=/dev/nvme1n1           isize=512    agcount=4, agsize=32768000 blks
         =                       sectsz=512   attr=2, projid32bit=1
data     =                       bsize=4096   blocks=131072000, imaxpct=25
naming   =version 2              bsize=4096   ascii-ci=0, ftype=1
log      =internal log           bsize=4096   blocks=64000, version=2
realtime =none                   extsz=4096   blocks=0, rtextents=0

$ sudo mkdir -p /data && sudo mount /dev/nvme1n1 /data
$ echo "UUID=$(sudo blkid -s UUID -o value /dev/nvme1n1) /data xfs defaults,nofail 0 2" | sudo tee -a /etc/fstab
UUID=8c2b4f1a-9d3e-4a75-b6c8-1e2f3a4b5c6d /data xfs defaults,nofail 0 2

$ df -hT /data
Filesystem     Type  Size  Used Avail Use% Mounted on
/dev/nvme1n1   xfs   500G  3.6G  497G   1% /data
```

> `nofail` en `/etc/fstab` no es opcional. Sin él, un volumen EBS ausente en el arranque deja la instancia en modo de emergencia y nunca llega a SSH.

**Agrandar el volumen en línea:**

```console
$ aws ec2 modify-volume --volume-id vol-0f3a9c81b7e2d4506 --size 1000 --throughput 500
{
    "VolumeModification": {
        "VolumeId": "vol-0f3a9c81b7e2d4506",
        "ModificationState": "modifying",
        "TargetSize": 1000,
        "TargetIops": 6000,
        "TargetVolumeType": "gp3",
        "TargetThroughput": 500,
        "OriginalSize": 500,
        "OriginalIops": 6000,
        "OriginalThroughput": 250,
        "Progress": 0,
        "StartTime": "2026-09-04T12:10:44.000Z"
    }
}

$ aws ec2 describe-volumes-modifications --volume-id vol-0f3a9c81b7e2d4506 \
    --query 'VolumesModifications[0].[ModificationState,Progress]' --output text
optimizing      100

# The guest still sees the old size until you grow the filesystem:
$ lsblk /dev/nvme1n1
NAME    MAJ:MIN RM  SIZE RO TYPE MOUNTPOINTS
nvme1n1 259:3    0 1000G  0 disk /data

$ df -hT /data
Filesystem     Type  Size  Used Avail Use% Mounted on
/dev/nvme1n1   xfs   500G  3.6G  497G   1% /data      <-- still 500G

$ sudo xfs_growfs /data
data blocks changed from 131072000 to 262144000

$ df -hT /data
Filesystem     Type  Size  Used Avail Use% Mounted on
/dev/nvme1n1   xfs  1000G  3.6G  997G   1% /data
```

Para un dispositivo particionado usá primero `sudo growpart /dev/nvme1n1 1`, y después `xfs_growfs` (XFS) o `resize2fs` (ext4).

### 9.2 EFS — montar y verificar

```console
$ aws efs describe-file-systems --file-system-id fs-0c9d8e7f6a5b4c3d2 \
    --query 'FileSystems[0].[FileSystemId,LifeCycleState,ThroughputMode,SizeInBytes.Value,Encrypted]' \
    --output table
------------------------------------------------------------------
|                      DescribeFileSystems                       |
+---------------------------+-----------+-----------+------+------+
|  fs-0c9d8e7f6a5b4c3d2     |  available|  elastic  | 4194304 | True |
+---------------------------+-----------+-----------+------+------+

$ sudo dnf install -y amazon-efs-utils
$ sudo mkdir -p /mnt/shared
$ sudo mount -t efs -o tls,iam,accesspoint=fsap-07e6d5c4b3a291807 fs-0c9d8e7f6a5b4c3d2 /mnt/shared

$ mount | grep efs
127.0.0.1:/ on /mnt/shared type nfs4 (rw,relatime,vers=4.1,rsize=1048576,wsize=1048576,namlen=255,hard,noresvport,proto=tcp,port=20450,timeo=600,retrans=2,sec=sys,clientaddr=127.0.0.1,local_lock=none,addr=127.0.0.1)

$ df -hT /mnt/shared
Filesystem     Type  Size  Used Avail Use% Mounted on
127.0.0.1:/    nfs4  8.0E  4.0M  8.0E   1% /mnt/shared
```

El `8.0E` (8 exabytes) es EFS informando que es elástico — no es una cuota, y las herramientas de monitoreo que alertan sobre porcentajes de "disco lleno" no tienen sentido acá. Notá que el montaje es a `127.0.0.1:20450`: `efs-utils` ejecuta un proceso `stunnel` local que termina TLS, que es la razón por la que los montajes con `tls` muestran una dirección de loopback.

### 9.3 S3 — ciclo de vida, clases, verificación

```console
$ aws s3api put-bucket-lifecycle-configuration \
    --bucket platform-storage-data-111122223333-us-east-1 \
    --lifecycle-configuration file://lifecycle.json

$ aws s3api get-bucket-lifecycle-configuration \
    --bucket platform-storage-data-111122223333-us-east-1 \
    --query 'Rules[].[ID,Status,Transitions[].StorageClass]' --output json
[
    [ "tier-current-versions", "Enabled", [ "STANDARD_IA", "GLACIER_IR", "DEEP_ARCHIVE" ] ],
    [ "tier-and-expire-noncurrent-versions", "Enabled", null ],
    [ "housekeeping", "Enabled", null ]
]

$ aws s3api get-bucket-encryption \
    --bucket platform-storage-data-111122223333-us-east-1
{
    "ServerSideEncryptionConfiguration": {
        "Rules": [
            {
                "ApplyServerSideEncryptionByDefault": {
                    "SSEAlgorithm": "aws:kms",
                    "KMSMasterKeyID": "arn:aws:kms:us-east-1:111122223333:key/1a2b3c4d-5e6f-7081-92a3-b4c5d6e7f809"
                },
                "BucketKeyEnabled": true
            }
        ]
    }
}

$ aws s3api get-public-access-block \
    --bucket platform-storage-data-111122223333-us-east-1
{
    "PublicAccessBlockConfiguration": {
        "BlockPublicAcls": true,
        "IgnorePublicAcls": true,
        "BlockPublicPolicy": true,
        "RestrictPublicBuckets": true
    }
}

# What class is each object actually in?
$ aws s3api list-objects-v2 \
    --bucket platform-storage-data-111122223333-us-east-1 \
    --prefix logs/2026/05/ \
    --query 'Contents[].[Key,StorageClass,Size]' --output text | head -5
logs/2026/05/01/app.log.gz      GLACIER_IR      184320122
logs/2026/05/02/app.log.gz      GLACIER_IR      191204488
logs/2026/05/03/app.log.gz      GLACIER_IR      177001923
logs/2026/05/04/app.log.gz      STANDARD_IA     188442017
logs/2026/05/05/app.log.gz      STANDARD_IA     190883311

# Restore an object from Glacier Flexible Retrieval.
$ aws s3api restore-object \
    --bucket platform-storage-archive-111122223333-us-east-1 \
    --key archive/2024/ledger.tar.gz \
    --restore-request 'Days=7,GlacierJobParameters={Tier=Bulk}'

$ aws s3api head-object \
    --bucket platform-storage-archive-111122223333-us-east-1 \
    --key archive/2024/ledger.tar.gz \
    --query '[StorageClass,Restore]' --output text
GLACIER ongoing-request="true"

# ...several hours later (Bulk = 5-12 h):
$ aws s3api head-object \
    --bucket platform-storage-archive-111122223333-us-east-1 \
    --key archive/2024/ledger.tar.gz \
    --query '[StorageClass,Restore]' --output text
GLACIER ongoing-request="false", expiry-date="Fri, 11 Sep 2026 00:00:00 GMT"
```

**Encontrar el dinero que estás quemando — las cargas multiparte incompletas son invisibles a `s3 ls`:**

```console
$ aws s3api list-multipart-uploads \
    --bucket platform-storage-data-111122223333-us-east-1 \
    --query 'Uploads[].[Key,Initiated]' --output text | head
backups/db-2026-06-14.dump      2026-06-14T02:11:07.000Z
backups/db-2026-06-21.dump      2026-06-21T02:10:52.000Z
backups/db-2026-07-05.dump      2026-07-05T02:12:31.000Z

$ aws s3 ls s3://platform-storage-data-111122223333-us-east-1/backups/ --human-readable --summarize | tail -3

Total Objects: 42
   Total Size: 1.1 TiB
```

Esas tres cargas consumen almacenamiento y no aparecen en ninguna parte del listado ni del total. La regla de ciclo de vida `AbortIncompleteMultipartUpload` de la plantilla existe específicamente para cosecharlas.

### 9.4 AWS Backup — verificar que el plan realmente está corriendo

```console
$ aws backup list-backup-jobs --by-state COMPLETED --max-results 3 \
    --query 'BackupJobs[].[ResourceType,ResourceArn,BackupSizeInBytes,CompletionDate]' --output table
-----------------------------------------------------------------------------------------------
|                                       ListBackupJobs                                        |
+--------+-------------------------------------------------------------+------------+---------+
|  EBS   |  arn:aws:ec2:us-east-1:111122223333:volume/vol-0f3a9c81b...  | 41231974400| 2026-09-04T03:14:02Z |
|  EFS   |  arn:aws:elasticfilesystem:us-east-1:111122223333:file-sy... |  4194304   | 2026-09-04T03:22:41Z |
|  S3    |  arn:aws:s3:::platform-storage-data-111122223333-us-east-1   | 1209462784 | 2026-09-04T03:31:19Z |
+--------+-------------------------------------------------------------+------------+---------+

# The only backup metric that matters: did anything FAIL?
$ aws backup list-backup-jobs --by-state FAILED --by-created-after 2026-08-28 \
    --query 'length(BackupJobs)'
0
```

---

## 10. Verificación y diagnóstico de fallas

### 10.1 EBS — el rendimiento es plano, hasta que de repente no lo es

**Síntoma:** la latencia p99 de la aplicación se degrada 10× horas o días después del despliegue. `iostat` muestra un `await` alto y `%util` clavado en 100%.

**Diagnóstico — chequeá el balance de créditos de burst (solo gp2, st1, sc1):**

```console
$ aws cloudwatch get-metric-statistics \
    --namespace AWS/EBS \
    --metric-name BurstBalance \
    --dimensions Name=VolumeId,Value=vol-0a1b2c3d4e5f60718 \
    --start-time 2026-09-03T00:00:00Z --end-time 2026-09-04T12:00:00Z \
    --period 3600 --statistics Average \
    --query 'sort_by(Datapoints,&Timestamp)[].[Timestamp,Average]' --output text
2026-09-03T00:00:00+00:00       100.0
2026-09-03T06:00:00+00:00       87.4
2026-09-03T12:00:00+00:00       41.2
2026-09-03T18:00:00+00:00       6.8
2026-09-04T00:00:00+00:00       0.0
2026-09-04T06:00:00+00:00       0.0
```

`BurstBalance = 0` es concluyente. **Arreglo:** `aws ec2 modify-volume --volume-type gp3` — en línea, sin downtime, y normalmente más barato.

**Síntoma:** el volumen está provisionado para 40.000 IOPS pero nunca supera ~12.000.

**Escalera de diagnóstico, en orden:**

1. **Techo de ancho de banda EBS de la instancia.** Chequeá `describe-instance-types`:

   ```console
   $ aws ec2 describe-instance-types --instance-types m5.large \
       --query 'InstanceTypes[0].EbsInfo.EbsOptimizedInfo' --output json
   {
       "BaselineBandwidthInMbps": 4750,
       "BaselineThroughputInMBps": 593.75,
       "BaselineIops": 18750,
       "MaximumBandwidthInMbps": 4750,
       "MaximumThroughputInMBps": 593.75,
       "MaximumIops": 18750
   }
   ```
   La instancia, no el volumen, es la restricción. Redimensioná la instancia.

2. **Tamaño de E/S.** EBS cuenta 256 KiB como una E/S para SSD (1 MiB para HDD). 40.000 IOPS a 4 KiB son 156 MiB/s; a 256 KiB los mismos 40.000 IOPS son 10 GiB/s — imposible. La E/S aleatoria pequeña choca contra el techo de IOPS; la E/S secuencial grande choca contra el techo de throughput. Sabé cuál de los dos estás probando.

3. **Profundidad de cola.** Un `dd` de un solo hilo nunca va a alcanzar IOPS altos, sin importar el provisionamiento. Hacé el benchmark con concurrencia realista:

   ```console
   $ sudo fio --name=randread --filename=/dev/nvme1n1 --rw=randread \
       --bs=16k --iodepth=32 --numjobs=4 --ioengine=libaio --direct=1 \
       --runtime=60 --time_based --group_reporting
   randread: (groupid=0, jobs=4): err= 0: pid=4127: Thu Sep  4 12:31:09 2026
     read: IOPS=5998, BW=93.7MiB/s (98.3MB/s)(5624MiB/60005msec)
       slat (usec): min=2, max=421, avg= 6.11, stdev= 3.88
       clat (usec): min=241, max=48211, avg=21324.77, stdev=2104.31
        lat (usec): min=248, max=48219, avg=21330.88, stdev=2104.29
     ...
   ```
   6.000 IOPS en un volumen provisionado a 6.000 — el volumen se comporta exactamente como fue configurado. El problema está en otra parte.

**Síntoma:** un volumen restaurado desde un snapshot es lento en la primera lectura, y después va bien.

**Causa:** los volúmenes respaldados por snapshot **cargan los bloques de forma perezosa** desde S3 en el primer acceso. El primer toque de cualquier bloque incurre en una gran penalidad de latencia. **Arreglo:** habilitá **Fast Snapshot Restore (FSR)** en el snapshot para las AZs de destino (completamente inicializado al crearse, facturado por AZ-hora), o precalentalo con `sudo fio --rw=read --bs=1M --iodepth=32 --name=warm --filename=/dev/nvme1n1 --readonly`.

**Síntoma:** `An error occurred (VolumeInUse) when calling the AttachVolume operation.`
**Causa:** el volumen está adjunto en otra parte y Multi-Attach no está habilitado. Multi-Attach requiere io1/io2, instancias Nitro en la misma AZ y — críticamente — **un sistema de archivos cluster-aware** (GFS2, OCFS2). `ext4` o `xfs` en un volumen Multi-Attach se corrompe en minutos.

**Síntoma:** `InvalidParameterValue: The volume 'vol-xxx' is in availability zone us-east-1a, but the instance is in us-east-1b.`
**Causa:** la restricción definitoria de EBS. Sacá un snapshot del volumen y creá un volumen nuevo desde el snapshot en la AZ de destino.

### 10.2 EFS — fallas de montaje, en orden de diagnóstico

```console
$ sudo mount -t efs fs-0c9d8e7f6a5b4c3d2:/ /mnt/shared
mount.nfs4: Connection timed out
```

Causa, ~90% de las veces: el security group del mount target no permite **TCP 2049** desde el security group del cliente. Verificá:

```console
$ aws efs describe-mount-targets --file-system-id fs-0c9d8e7f6a5b4c3d2 \
    --query 'MountTargets[].[AvailabilityZoneName,IpAddress,LifeCycleState]' --output text
us-east-1a      10.0.1.87       available
us-east-1b      10.0.2.143      available
us-east-1c      10.0.3.201      available

$ nc -vz 10.0.1.87 2049
Ncat: Connected to 10.0.1.87:2049.
```

Si `nc` conecta pero `mount` sigue expirando, el cliente está en una AZ **sin mount target** — el tráfico NFS entre AZs hacia un mount target funciona pero agrega latencia y cargos de transferencia de datos; un mount target *ausente* en la AZ del cliente, combinado con una ruta de alcance de subred, puede fallar directamente.

```console
$ sudo mount -t efs fs-0c9d8e7f6a5b4c3d2:/ /mnt/shared
mount.nfs4: Failed to resolve server fs-0c9d8e7f6a5b4c3d2.efs.us-east-1.amazonaws.com: \
Name or service not known
```

Causa: `enableDnsSupport` o `enableDnsHostnames` está en **false** en la VPC, o el cliente usa un resolvedor personalizado que no reenvía al resolvedor de la VPC en `VPC_CIDR_base + 2`.

```console
$ aws ec2 describe-vpc-attribute --vpc-id vpc-0a1b2c3d4e5f67890 --attribute enableDnsHostnames \
    --query 'EnableDnsHostnames.Value'
false

$ aws ec2 modify-vpc-attribute --vpc-id vpc-0a1b2c3d4e5f67890 --enable-dns-hostnames
```

```console
$ sudo mount -t efs -o tls,iam fs-0c9d8e7f6a5b4c3d2:/ /mnt/shared
mount.nfs4: access denied by server while mounting 127.0.0.1:/
```

Causa: la política del sistema de archivos o IAM deniega el montaje. Con `-o iam`, el perfil de instancia debe tener `elasticfilesystem:ClientMount` / `ClientWrite` / `ClientRootAccess`. Una política de sistema de archivos que deniega `aws:SecureTransport=false` (como en la plantilla de arriba) también rechazará un montaje intentado **sin** `-o tls`.

**Síntoma:** el throughput de EFS se derrumba bajo carga sostenida.

```console
$ aws cloudwatch get-metric-statistics --namespace AWS/EFS \
    --metric-name BurstCreditBalance \
    --dimensions Name=FileSystemId,Value=fs-0c9d8e7f6a5b4c3d2 \
    --start-time 2026-09-04T00:00:00Z --end-time 2026-09-04T12:00:00Z \
    --period 3600 --statistics Minimum \
    --query 'Datapoints[-1].Minimum'
0.0
```

**Arreglo:** `aws efs update-file-system --file-system-id fs-... --throughput-mode elastic`.

### 10.3 S3 — el árbol de decisión del access-denied

Una falla de autorización en S3 es la unión de **cinco evaluaciones independientes**. Todas deben permitir; cualquier Deny es final.

```
Request
  │
  ├─ 1. Block Public Access (account, then bucket) ──── blocks anonymous/public first
  ├─ 2. Service Control Policy (Organizations) ──────── Deny wins, invisible in the bucket
  ├─ 3. IAM identity policy (user/role) ─────────────── needs an explicit Allow
  ├─ 4. Bucket policy (resource) ───────────────────── explicit Deny wins over any Allow
  ├─ 5. VPC endpoint policy (if via a gateway endpoint) ─ silently restricts buckets
  └─ 6. Object ACL / Object Ownership ──────────────── mostly moot under BucketOwnerEnforced
        + KMS key policy, if SSE-KMS ────────────────── s3:GetObject alone is not enough
```

```console
$ aws s3 cp big.tar.gz s3://platform-storage-data-111122223333-us-east-1/
upload failed: ./big.tar.gz to s3://platform-storage-data-.../big.tar.gz \
An error occurred (AccessDenied) when calling the CreateMultipartUpload operation: \
User: arn:aws:sts::111122223333:assumed-role/deploy-role/i-0b7c4e2f19a8d3056 \
is not authorized to perform: s3:PutObject on resource "..." with an explicit deny \
in a resource-based policy
```

`with an explicit deny in a resource-based policy` nombra al culpable con precisión: la **política del bucket**. Acá es la sentencia `DenyUnencryptedObjectUploads` — el cliente no envió `x-amz-server-side-encryption: aws:kms`. Se arregla apoyándose en el cifrado por defecto del bucket (que la CLI de AWS respeta) o pasando `--sse aws:kms --sse-kms-key-id <arn>`.

**Reproducí la evaluación completa sin tocar los datos — IAM Policy Simulator vía CLI:**

```console
$ aws iam simulate-principal-policy \
    --policy-source-arn arn:aws:iam::111122223333:role/deploy-role \
    --action-names s3:PutObject \
    --resource-arns arn:aws:s3:::platform-storage-data-111122223333-us-east-1/test.txt \
    --query 'EvaluationResults[].[EvalActionName,EvalDecision]' --output text
s3:PutObject    implicitDeny
```

**403 donde esperabas un 404.** `GetObject` sobre una clave que no existe devuelve **`404 NoSuchKey`** si el llamante tiene `s3:ListBucket`, y **`403 AccessDenied`** si no lo tiene — S3 se niega a confirmar o negar la existencia. Un "bug de permisos" que en realidad es un typo en la clave es un desperdicio recurrente de una hora de guardia.

**La transición de ciclo de vida "no ocurrió".**

```console
$ aws s3api head-object --bucket platform-storage-data-111122223333-us-east-1 \
    --key logs/2026/08/29/app.log.gz --query '[StorageClass,LastModified]' --output text
None    2026-08-29T04:00:11+00:00
```

`StorageClass: None` significa `STANDARD` (S3 omite el encabezado para Standard). El objeto tiene 6 días; la regla hace la transición a los 30 días. Nada está mal. Otras causas reales cuando la antigüedad *sí* alcanza: el objeto es menor a 128 KB (las transiciones a IA se saltean por no ser económicas), o la transición está programada pero todavía no ejecutada — las acciones de ciclo de vida corren de forma asíncrona y pueden retrasarse hasta 48 horas, aunque **la facturación cambia en el momento programado, no en el momento de la ejecución**.

**Verificá toda la flota de una sola vez con Storage Lens:**

```console
$ aws s3control get-storage-lens-configuration \
    --account-id 111122223333 --config-id default-account-dashboard \
    --query 'StorageLensConfiguration.[Id,IsEnabled,AccountLevel.BucketLevel.PrefixLevel]' --output json
[
    "default-account-dashboard",
    true,
    null
]
```

El nivel gratuito de Storage Lens da 28 días de métricas de uso de todos los buckets de la cuenta — esta es la forma más rápida de encontrar el bucket con 40 TB de versiones no actuales que nadie conocía.

### 10.4 La escalera de verificación para cualquier cambio de almacenamiento

Ejecutá estos en orden después de cualquier modificación de almacenamiento; cada uno es barato y cada uno atrapa una clase distinta de error.

| # | Chequeo | Comando | Pasa cuando |
|---|---|---|---|
| 1 | El recurso existe y está `available` | `aws ec2 describe-volumes` / `efs describe-file-systems` / `s3api head-bucket` | El estado es `available` / exit 0 |
| 2 | El cifrado está activado, con la clave correcta | `describe-volumes --query '[].Encrypted'`, `s3api get-bucket-encryption` | `true` + el ARN de clave esperado |
| 3 | No es alcanzable públicamente | `s3api get-public-access-block`, `s3api get-bucket-policy-status` | los cuatro en `true`, `IsPublic: false` |
| 4 | El guest realmente lo ve | `lsblk`, `df -hT`, `mount \| grep nfs4` | El tamaño esperado en la ruta esperada |
| 5 | Sobrevive un reinicio | `sudo reboot`, y después volver a correr #4 | El montaje está presente sin acción manual |
| 6 | El rendimiento coincide con el provisionamiento | `fio` con tamaño de bloque y profundidad de cola realistas | Dentro de ~10% de lo provisionado |
| 7 | Existe un backup **y restaura** | `aws backup list-recovery-points-by-backup-vault`, y después una restauración real a un recurso scratch | Los datos restaurados validan |

El paso 7 es el que los equipos saltean. Un backup no probado es una hipótesis, no un control.

---

## 11. Modelo de costos — tres ejemplos trabajados

**(a) 10 TB de logs de aplicación, 90 días calientes, retenidos 7 años, us-east-1.**

| Estrategia | Costo mensual en estado estable | Notas |
|---|---|---|
| Todo S3 Standard | 10.000 GB × $0.023 = **$230** | Ingenuo |
| Ciclo de vida → Standard-IA a los 30 d → Glacier Deep Archive a los 90 d | ≈ 1.000 GB Std ($23) + 2.000 GB IA ($25) + 7.000 GB DA ($6,93) = **$54,93** | 76% de ahorro |
| Intelligent-Tiering con nivel de acceso Deep Archive | ≈ **$60–70** incluido el monitoreo | Correcto cuando el acceso es impredecible |

**(b) Volumen de base de datos de 1 TiB.**

| Opción | Mensual | IOPS | Veredicto |
|---|---|---|---|
| gp2 1 TiB | $102,40 | 3.000 (burst a 3.000) | Nunca elegir |
| gp3 1 TiB, 3.000/125 | $81,92 | 3.000 | Predeterminado de línea base |
| gp3 1 TiB, 16.000 IOPS, 1.000 MiB/s | $81,92 + $65,00 + $35,00 = **$181,92** | 16.000 | Techo de gp3 |
| io2 1 TiB, 20.000 IOPS | $128,00 + (precio del tramo de 32.000 sobre 20.000 × $0.065) = **$1.428,00** | 20.000, durabilidad 99,999% | Solo cuando los cinco nueves de durabilidad o los >16k IOPS son genuinamente necesarios |

El salto de gp3 a io2 es de casi 8× con los mismos IOPS. io2 compra **durabilidad** y margen, no solo velocidad; justificalo por la línea de durabilidad, no por la de IOPS.

**(c) Sistema de archivos compartido de 2 TB, 5% caliente.**

| Opción | Mensual |
|---|---|
| EFS Standard, sin ciclo de vida | 2.000 × $0.30 = **$600** |
| EFS con ciclo de vida (100 GB Standard, 1.900 GB Archive) | $30 + $15,20 = **$45,20** + cargos de acceso |
| FSx for OpenZFS (128 MB/s, 2 TB SSD) | ≈ **$500–600** — compralo por las funciones de ZFS, no por el precio |
| S3 Standard (si la app puede reescribirse a semántica de objetos) | 2.000 × $0.023 = **$46** |

---

## 12. Desambiguación de examen — las trampas que CLF-C02 realmente tiende

| Trampa | Instinto equivocado | Razonamiento correcto |
|---|---|---|
| "Durable" vs "disponible" | Tratar los 11 nueves como una promesa de uptime | Durabilidad = los datos sobreviven. Disponibilidad = podés alcanzarlos ahora. S3 Standard: 11 nueves de durabilidad, 99,99% de disponibilidad |
| "S3 es un sistema de archivos" | Elegir S3 para un montaje POSIX compartido | S3 es almacenamiento de objetos. POSIX compartido = EFS (Linux) o FSx (Windows/Lustre/ONTAP/OpenZFS) |
| "EBS puede compartirse" | Elegir EBS para ReadWriteMany | Una sola instancia por defecto; Multi-Attach es io1/io2 + misma AZ + FS de clúster |
| "El instance store es EBS barato" | Usarlo para una base de datos | Los datos se pierden en stop/terminate/falla del host |
| "Glacier significa lento" | Descartar Glacier para necesidades de milisegundos | **Glacier Instant Retrieval** es acceso en milisegundos a $0.004/GB |
| "Lo más barato por GB es lo más barato" | Deep Archive para datos de 20 días | Duraciones mínimas facturables: IA 30 d, Glacier IR/Flexible 90 d, Deep Archive 180 d |
| "One Zone-IA es simplemente IA más barato" | Usarlo para datos irreemplazables | Una sola AZ. Pérdida de la AZ = pérdida de datos. Solo para datos reproducibles |
| Gateway vs DataSync | Intercambiarlos | Gateway *presenta* almacenamiento on-prem de forma continua; DataSync *transfiere* datos según una programación |
| Snow vs DataSync | Usar Snow para 2 TB | Por debajo de ~10 TB, o con ancho de banda libre real, usá la red |
| "Backup = Snapshot" | Suponer que los snapshots satisfacen el cumplimiento | AWS Backup agrega política central, copia cross-Region/cross-account, Vault Lock (WORM) y reportes de auditoría |
| Modos de Object Lock | Suponer que el root puede sobrescribir | Modo **Governance**: eludible con un permiso específico. Modo **Compliance**: eludible por nadie, incluido el root |
| "S3 es eventualmente consistente" | Repetir material anterior a 2020 | S3 tiene **consistencia read-after-write fuerte** desde diciembre de 2020 |

---

## 13. Referencias

Fuentes oficiales de AWS para cada afirmación de este documento:

**Examen**
- AWS Certified Cloud Practitioner (CLF-C02) Exam Guide — https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
- AWS Certified Cloud Practitioner — página de certificación — https://aws.amazon.com/certification/certified-cloud-practitioner/

**Almacenamiento de bloques**
- Amazon EBS User Guide — https://docs.aws.amazon.com/ebs/latest/userguide/what-is-ebs.html
- Tipos de volumen EBS — https://docs.aws.amazon.com/ebs/latest/userguide/ebs-volume-types.html
- Amazon EBS Multi-Attach — https://docs.aws.amazon.com/ebs/latest/userguide/ebs-volumes-multi.html
- Modificar un volumen EBS (Elastic Volumes) — https://docs.aws.amazon.com/ebs/latest/userguide/requesting-ebs-volume-modifications.html
- Amazon EBS Fast Snapshot Restore — https://docs.aws.amazon.com/ebs/latest/userguide/ebs-fast-snapshot-restore.html
- Amazon EC2 instance store — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/InstanceStorage.html
- Precios de Amazon EBS — https://aws.amazon.com/ebs/pricing/

**Almacenamiento de archivos**
- Amazon EFS User Guide — https://docs.aws.amazon.com/efs/latest/ug/whatisefs.html
- Clases de almacenamiento y gestión de ciclo de vida de EFS — https://docs.aws.amazon.com/efs/latest/ug/storage-classes.html
- Rendimiento y modos de throughput de EFS — https://docs.aws.amazon.com/efs/latest/ug/performance.html
- Solución de problemas de montaje de Amazon EFS — https://docs.aws.amazon.com/efs/latest/ug/troubleshooting-efs-mounting.html
- Amazon FSx — https://aws.amazon.com/fsx/
- FSx for Windows File Server — https://docs.aws.amazon.com/fsx/latest/WindowsGuide/what-is.html
- FSx for Lustre — https://docs.aws.amazon.com/fsx/latest/LustreGuide/what-is.html
- FSx for NetApp ONTAP — https://docs.aws.amazon.com/fsx/latest/ONTAPGuide/what-is-fsx-ontap.html
- FSx for OpenZFS — https://docs.aws.amazon.com/fsx/latest/OpenZFSGuide/what-is-fsx.html
- Amazon File Cache — https://docs.aws.amazon.com/fsx/latest/FileCacheGuide/what-is.html

**Almacenamiento de objetos**
- Amazon S3 User Guide — https://docs.aws.amazon.com/AmazonS3/latest/userguide/Welcome.html
- Clases de almacenamiento de S3 — https://docs.aws.amazon.com/AmazonS3/latest/userguide/storage-class-intro.html
- Configuración de ciclo de vida de S3 — https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lifecycle-mgmt.html
- Modelo de consistencia de datos de S3 — https://docs.aws.amazon.com/AmazonS3/latest/userguide/Welcome.html#ConsistencyModel
- S3 Object Lock — https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lock.html
- S3 Versioning — https://docs.aws.amazon.com/AmazonS3/latest/userguide/Versioning.html
- S3 Block Public Access — https://docs.aws.amazon.com/AmazonS3/latest/userguide/access-control-block-public-access.html
- Cifrado por defecto de S3 y Bucket Keys — https://docs.aws.amazon.com/AmazonS3/latest/userguide/bucket-key.html
- Patrones de diseño de buenas prácticas de S3 (tasas de solicitud, prefijos) — https://docs.aws.amazon.com/AmazonS3/latest/userguide/optimizing-performance.html
- S3 Express One Zone — https://docs.aws.amazon.com/AmazonS3/latest/userguide/s3-express-one-zone.html
- S3 Storage Lens — https://docs.aws.amazon.com/AmazonS3/latest/userguide/storage_lens.html
- Precios de Amazon S3 — https://aws.amazon.com/s3/pricing/

**Híbrido, borde y movimiento de datos**
- AWS Storage Gateway — https://docs.aws.amazon.com/storagegateway/latest/userguide/WhatIsStorageGateway.html
- AWS Snow Family — https://docs.aws.amazon.com/snowball/latest/developer-guide/whatissnowball.html
- AWS DataSync — https://docs.aws.amazon.com/datasync/latest/userguide/what-is-datasync.html
- AWS Transfer Family — https://docs.aws.amazon.com/transfer/latest/userguide/what-is-aws-transfer-family.html
- S3 Transfer Acceleration — https://docs.aws.amazon.com/AmazonS3/latest/userguide/transfer-acceleration.html

**Protección de datos y gobernanza**
- AWS Backup Developer Guide — https://docs.aws.amazon.com/aws-backup/latest/devguide/whatisbackup.html
- AWS Backup Vault Lock — https://docs.aws.amazon.com/aws-backup/latest/devguide/vault-lock.html
- Modelo de responsabilidad compartida de AWS — https://aws.amazon.com/compliance/shared-responsibility-model/
- AWS Well-Architected Framework — Pilar de fiabilidad — https://docs.aws.amazon.com/wellarchitected/latest/reliability-pillar/welcome.html

**Infraestructura como código y Kubernetes**
- Referencia de recursos de AWS CloudFormation — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-template-resource-type-ref.html
- Driver CSI de Amazon EBS — https://docs.aws.amazon.com/eks/latest/userguide/ebs-csi.html
- Driver CSI de Amazon EFS — https://docs.aws.amazon.com/eks/latest/userguide/efs-csi.html
- Driver CSI de Mountpoint for Amazon S3 — https://docs.aws.amazon.com/eks/latest/userguide/s3-csi.html