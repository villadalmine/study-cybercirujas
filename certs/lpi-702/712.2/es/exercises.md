# LPI BSD Specialist (Exam 702-100) — Tema 712.2: Crear sistemas de archivos y mantener su integridad

**Peso del tema del examen:** 1.67  
**Nivel objetivo:** Senior SRE / Principal Platform Architect  
**Referencia principal:** [LPI BSD Specialist Certification Overview](https://www.lpi.org/our-certifications/bsd-specialist-overview/)

---

## 1. Fundamentos arquitectónicos y mecánica interna

Los sistemas BSD modernos (FreeBSD, OpenBSD, NetBSD) se basan en dos arquitecturas de sistemas de archivos principales: el tradicional **Unix File System (UFS/UFS2)** y el moderno **Zettabyte File System (ZFS)**. Comprender los diseños de disco a bajo nivel, los modelos de mantenimiento de integridad y las compensaciones (trade-offs) de ambos es esencial para las operaciones en producción.

```
+-----------------------------------------------------------------------------------+
|                                 UFS2 Architecture                                 |
+-----------------------------------------------------------------------------------+
|  Boot Block | Superblock | Cylinder Group 0 | Cylinder Group 1 | ... | CG (n)      |
|             | (Backup 1) | Inodes | Data    | Inodes | Data    |     | Inodes | Data|
+-----------------------------------------------------------------------------------+
  - Structural metadata fixed at creation (Inodes, Block/Frag ratio).
  - Synchronous or Soft Updates (SU / SU+J) dependency ordering.
  - Offline repair required for structural inconsistencies (fsck_ffs).

+-----------------------------------------------------------------------------------+
|                                 ZFS Architecture                                  |
+-----------------------------------------------------------------------------------+
|  zpool (VDEV 1: Mirror / RAIDZ)  <--->  zpool (VDEV 2: Mirror / RAIDZ)            |
|  +-----------------------------------------------------------------------------+  |
|  | Merkle Tree Architecture (Root Uberblock -> Indirect Blocks -> Data Blocks) |  |
|  | - Copy-on-Write (CoW): Writes never overwrite existing active data blocks.   |  |
|  | - End-to-End Checksumming: Stored in parent block pointer (Self-Healing).   |  |
|  | - Dynamic Allocation: Inodes allocated dynamically; no fixed limits.       |  |
|  +-----------------------------------------------------------------------------+  |
+-----------------------------------------------------------------------------------+
```

### Mecánica de UFS2 (Unix File System 2)
- **Estructura de diseño y metadatos**: UFS2 organiza los slices de disco en **Cylinder Groups**. Cada cylinder group contiene un superblock de respaldo, encabezados de bloque, una tabla de inodes y bloques de datos. 
- **Tamaños de bloque y fragmento**: UFS divide los bloques del sistema de archivos en unidades más pequeñas llamadas **fragments** (típicamente bloques de 32KB / fragmentos de 4KB o 16KB / 2KB) para minimizar la fragmentación interna en archivos pequeños.
- **Asignación de inodes**: Los inodes se asignan de manera estática durante la creación del sistema de archivos mediante `newfs`. Agotar los inodes resulta en un error `ENOSPC` (No space left on device) incluso si quedan bytes libres en el disco crudo (raw disk).
- **Modelos de consistencia**:
  - **Escrituras asíncronas (Async Writes)**: Alto rendimiento, riesgo extremo de estados de sistema de archivos corruptos ante un panic o interrupción no limpia del sistema.
  - **Soft Updates (SU)**: Rastrea las dependencias de bloques en RAM para garantizar que se cumplan las reglas invariantes de la estructura en disco (por ejemplo, una entrada de directorio que apunta a un inode solo después de la inicialización del inode). Elimina la necesidad de escrituras síncronas de metadatos sin comprometer la integridad estructural.
  - **Soft Updates con Journaling (SU+J)**: Registra los cambios de metadatos en un intent journal dentro del sistema de archivos, reduciendo los tiempos de reparación con fsck al reiniciar de horas a segundos.

### Mecánica de ZFS (Zettabyte File System)
- **Modelo de almacenamiento agrupado (Pooled Storage)**: Desacopla la gestión de discos físicos de la gestión de datasets. Los discos físicos forman Storage Pools (`zpools`) utilizando Virtual Devices (`vdevs` como mirror, raidz1, raidz2). Los datasets comparten la capacidad del pool de forma dinámica.
- **Copy-on-Write (CoW)**: ZFS nunca muta los datos en el lugar (in-place). Modificar un bloque asigna un nuevo bloque, escribe los datos actualizados y actualiza el puntero del bloque padre hasta el **Uberblock** raíz.
- **Árbol de Merkle (Merkle Tree) y autoreparación (Self-Healing)**: Cada puntero de bloque padre contiene un checksum criptográfico (Fletcher4, SHA-256 o xxHash) de sus bloques hijos. Durante las lecturas o **scrubs** en segundo plano, ZFS valida los datos contra el checksum. Si se detecta corrupción (bit rot) en un pool redundante (Mirror/RAIDZ), ZFS obtiene la copia correcta del mirror/paridad, repara el bloque corrupto en el disco y devuelve los datos válidos a la aplicación de manera transparente.
- **Metaslabs y asignación de espacio**: ZFS divide el espacio del pool en metaslabs. Cuando la capacidad del pool supera el 80–90%, ZFS cambia los algoritmos de asignación de first-fit a best-fit, lo que resulta en picos masivos de latencia de escritura y una fragmentación severa.

---

## 2. Ejercicios prácticos guiados de laboratorio

### Supuestos del entorno del sistema
- **Host**: FreeBSD 14.x / OpenBSD 7.x
- **Discos objetivo**: Dispositivos de bloques sin particionar `/dev/da1` y `/dev/da2` (o `sd1`, `sd2` en OpenBSD).

---

### Ejercicio 1: Aprovisionamiento, ajuste (tuning) y diagnóstico de corrupción del sistema de archivos UFS2

#### Objetivo
Aprovisionar un sistema de archivos UFS2 personalizado, configurar parámetros de ajuste de rendimiento (`tunefs`), inspeccionar metadatos de disco crudo (`dumpfs`), simular un apagado no limpio y realizar una reparación estructural fuera de línea (`fsck_ffs`).

#### Pasos de ejecución

1. **Particionar el disco objetivo y crear una tabla de particiones GPT.**
   ```bash
   gpart create -s gpt /dev/da1
   gpart add -t freebsd-ufs -l ufs_data -a 4k /dev/da1
   ```
   *Salida esperada:*
   ```text
   da1 created
   da1p1 added
   ```

2. **Formatear la partición utilizando `newfs` con tamaños personalizados de bloque (32KB) y fragmento (4KB), desactivando Soft Updates por defecto inicialmente.**
   ```bash
   newfs -U -b 32768 -f 4096 -L PRODUCTION_UFS /dev/da1p1
   ```
   *Salida esperada:*
   ```text
   /dev/da1p1: 10240.0MB (20971520 sectors) block size 32768, fragment size 4096
           using 17 cylinder groups of 602.41MB, 19277 blks, 77312 inodes.
           with Soft Updates
   super-block backups (for fsck_ffs -b #) at:
    192, 1233920, 2467648, 3701376, 4935104, 6168832, 7402560, 8636288,
    9870016, 11103744, 12337472, 13571200, 14804928, 16038656, 17272384
   ```

3. **Inspeccionar los flags del sistema de archivos y los metadatos del superblock utilizando `tunefs` y `dumpfs`.**
   ```bash
   tunefs -p /dev/da1p1
   ```
   *Salida esperada:*
   ```text
   tunefs: POSIX.1e ACLs: (-a)                                disabled
   tunefs: NFSv4 ACLs: (-N)                                  disabled
   tunefs: MAC multi-label: (-l)                             disabled
   tunefs: soft updates: (-U)                                 enabled
   tunefs: soft updates journaling: (-j)                      disabled
   tunefs: gjournal: (-J)                                    disabled
   tunefs: trim: (-t)                                        disabled
   tunefs: maximum contiguous blks: (-maxb)                   16
   tunefs: space hold back: (-m)                             8%
   tunefs: optimization preference: (-o)                     time
   ```

4. **Habilitar Soft Updates con Journaling (SU+J) para acelerar la recuperación ante caídas (crashes).**
   ```bash
   tunefs -j enable /dev/da1p1
   ```
   *Salida esperada:*
   ```text
   tunefs: Soft Updates Journaling set to enabled
   tunefs: /dev/da1p1: file system is clean; journal initialized
   ```

5. **Configurar la entrada en `/etc/fstab` para el montaje de producción con trim habilitado para eficiencia en SSD.**
   ```bash
   echo "/dev/ufs/PRODUCTION_UFS /mnt/ufs_production ufs rw,noatime 2 2" >> /etc/fstab
   mkdir -p /mnt/ufs_production
   mount /mnt/ufs_production
   ```

6. **Simular un análisis del estado estructural del sistema de archivos utilizando `dumpfs` para identificar las ubicaciones de los metadatos del cylinder group 0.**
   ```bash
   dumpfs /dev/da1p1 | head -n 25
   ```
   *Salida esperada:*
   ```text
   magic   19540119 (UFS2) format  dynamic time    Thu Aug  6 20:28:29 2026
   sblkno  24      cblkno  32      iblkno  56      dblkno  2456
   sbsize  28672   cgsize  32768   csaddr  2456    cssize  4096
   cgmask  0xffffffff      size    2621440 blocks  2621440
   fsbtodb 3       ipg     77312   fpg     154217
   bsize   32768   fsize   4096    frag    8
   ...
   ```

7. **Simular un desmontaje forzado no limpio y ejecutar la verificación interactiva/no interactiva con `fsck_ffs`.**
   ```bash
   umount /mnt/ufs_production
   fsck_ffs -fy /dev/da1p1
   ```
   *Salida esperada:*
   ```text
   ** /dev/da1p1
   ** File system is already clean
   ** Last Mounted on /mnt/ufs_production
   ** Phase 1 - Check Blocks and Sizes
   ** Phase 2 - Check Pathnames
   ** Phase 3 - Check Connectivity
   ** Phase 4 - Check Reference Counts
   ** Phase 5 - Check Cyl groups
   0 files, 4 used, 2552835 free (0 frags, 319104 blocks, 0.0% fragmentation)
   
   ***** FILE SYSTEM MARKED CLEAN *****
   ```

---

#### Preguntas de verificación (Ejercicio 1)

**Pregunta 1.1**: ¿Cuál es el propósito arquitectónico de preservar la reserva de espacio libre mínimo por defecto del 8% (`tunefs -m 8%`) en UFS2, y qué sucede con las operaciones de escritura de usuarios no root cuando el uso del disco supera el 92%?  
**Pregunta 1.2**: Si el superblock primario en el bloque 24 se vuelve físicamente ilegible debido a sectores defectuosos, ¿qué utilidad y sintaxis de comando se deben ejecutar para reparar el sistema de archivos utilizando un superblock de respaldo redundante identificado durante `newfs`?  
**Pregunta 1.3**: ¿En qué se diferencia estructuralmente Soft Updates con Journaling (SU+J) de Soft Updates estándar (SU) durante la recuperación ante una caída del sistema?

---

### Ejercicio 2: Arquitectura de ZFS Pool, aprovisionamiento de Dataset y scrubbing de integridad

#### Objetivo
Construir un ZFS pool en espejo (mirrored), configurar propiedades de dataset de producción (compresión, cuotas, reservas, checksums), simular corrupción silenciosa de datos directamente en la capa de almacenamiento subyacente usando `dd`, y demostrar la autoreparación de extremo a extremo de ZFS mediante `zpool scrub`.

#### Pasos de ejecución

1. **Construir un ZFS storage pool en espejo llamado `tank` utilizando dos dispositivos de bloques dedicados.**
   ```bash
   zpool create -f -o ashift=12 tank mirror /dev/da1 /dev/da2
   ```
   *Salida esperada:*
   ```text
   (Command completes silently on success)
   ```

2. **Verificar el estado y la topología del pool.**
   ```bash
   zpool status tank
   ```
   *Salida esperada:*
   ```text
     pool: tank
    state: ONLINE
     scan: none requested
   config:

           NAME        STATE     READ WRITE CKSUM
           tank        ONLINE       0     0     0
             mirror-0  ONLINE       0     0     0
               da1     ONLINE       0     0     0
               da2     ONLINE       0     0     0

   errors: No known data errors
   ```

3. **Aprovisionar una jerarquía de datasets de producción multitenant segura con propiedades de rendimiento y seguridad forzadas.**
   ```bash
   zfs create tank/dbdata
   zfs set compression=lz4 tank/dbdata
   zfs set atime=off tank/dbdata
   zfs set recordsize=16k tank/dbdata
   zfs set quota=50G tank/dbdata
   zfs set reservation=10G tank/dbdata
   zfs set redundant_metadata=most tank/dbdata
   ```

4. **Verificar la configuración de las propiedades del dataset.**
   ```bash
   zfs get compression,atime,recordsize,quota,reservation tank/dbdata
   ```
   *Salida esperada:*
   ```text
   NAME         PROPERTY     VALUE    SOURCE
   tank/dbdata  compression  lz4      local
   tank/dbdata  atime        off      local
   tank/dbdata  recordsize   16k      local
   tank/dbdata  quota        50G      local
   tank/dbdata  reservation  10G      local
   ```

5. **Generar un archivo de prueba que contenga datos aleatorios dentro del dataset de ZFS.**
   ```bash
   dd if=/dev/urandom of=/tank/dbdata/critical_payload.bin bs=1M count=100
   sha256 /tank/dbdata/critical_payload.bin
   ```
   *Salida esperada:*
   ```text
   100+0 records in
   100+0 records out
   104857600 bytes transferred in 0.421054 secs (249035989 bytes/sec)
   SHA256 (/tank/dbdata/critical_payload.bin) = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
   ```

6. **Simular bit rot físico crudo inyectando corrupción de cero bytes directamente en la unidad subyacente `/dev/da1` omitiendo el stack del controlador de ZFS.**
   ```bash
   dd if=/dev/zero of=/dev/da1 bs=1M seek=50 count=10 conv=notrunc
   ```
   *Salida esperada:*
   ```text
   10+0 records in
   10+0 records out
   10485760MB transferred...
   ```

7. **Iniciar un scrub asíncrono de ZFS para detectar y reparar automáticamente la corrupción inyectada.**
   ```bash
   zpool scrub tank
   ```

8. **Monitorear el estado de ejecución del scrub e inspeccionar la salida de telemetría de autoreparación.**
   ```bash
   zpool status -v tank
   ```
   *Salida esperada:*
   ```text
     pool: tank
    state: ONLINE
   status: One or more devices repaired corrupt data. The log contains
           exceptions.
   action: No known repair errors.
     scan: scrub repaired 10.0M in 00:00:02 with 0 errors on Thu Aug  6 20:28:34 2026
   config:

           NAME        STATE     READ WRITE CKSUM
           tank        ONLINE       0     0     0
             mirror-0  ONLINE       0     0     0
               da1     ONLINE       0     0     128
               da2     ONLINE       0     0     0

   errors: No known data errors
   ```

9. **Verificar la integridad del archivo posterior a la autoreparación para confirmar la consistencia a nivel de aplicación.**
   ```bash
   sha256 /tank/dbdata/critical_payload.bin
   ```
   *Salida esperada:*
   ```text
   SHA256 (/tank/dbdata/critical_payload.bin) = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
   ```

---

#### Preguntas de verificación (Ejercicio 2)

**Pregunta 2.1**: ¿Por qué se especifica `-o ashift=12` durante `zpool create`, y qué impacto de rendimiento ocurre si se crea un pool con el valor por defecto `ashift=9` en unidades modernas NVMe/SATA Advanced Format (4Kn / 512e)?  
**Pregunta 2.2**: ¿Cómo pudo ZFS reparar los 10MB de bloques corruptos en `/dev/da1` sin reportar pérdida de datos ni arrojar un error de I/O a la aplicación que leía `/tank/dbdata/critical_payload.bin`?  
**Pregunta 2.3**: ¿Cuál es la diferencia funcional clave entre establecer una `quota` de dataset en comparación con una `reservation` de dataset?

---

### Ejercicio 3: Planificación de capacidad, monitoreo de asignación de espacio y recuperación de emergencia

#### Objetivo
Diagnosticar escenarios de agotamiento del sistema de archivos en UFS2 y ZFS, analizar el consumo de inodes frente a bloques, administrar snapshots de ZFS y resolver condiciones de saturación de capacidad del pool de ZFS.

#### Pasos de ejecución

1. **Verificar el espacio general del volumen y la utilización de inodes en los puntos de montaje de UFS y ZFS.**
   ```bash
   df -h
   df -i
   ```
   *Salida esperada (fragmento truncado de `df -i`):*
   ```text
   Filesystem           Inodes   Used  Avail Capacity iused Mounted on
   /dev/gpt/rootfs     1548286 120400 1427886     8%   120400  /
   /dev/da1p1            77312      4  77308     0%        4  /mnt/ufs_production
   tank/dbdata         3275912     15 3275897     0%       15  /tank/dbdata
   ```

2. **Diagnosticar puntos calientes de consumo de espacio en directorios mediante `du`.**
   ```bash
   du -hd 1 /var
   ```
   *Salida esperada:*
   ```text
   2.1M    /var/audit
   512K    /var/backups
   1.2G    /var/log
   4.8G    /var/db
   6.0G    /var
   ```

3. **Tomar un snapshot puntual de ZFS antes de ejecutar cambios administrativos.**
   ```bash
   zfs snapshot tank/dbdata@pre_maintenance_20260806
   zfs list -t snapshot
   ```
   *Salida esperada:*
   ```text
   NAME                                          USED  AVAIL  REFER  MOUNTPOINT
   tank/dbdata@pre_maintenance_20260806            0B      -   100M  -
   ```

4. **Simular la eliminación accidental de archivos dentro del dataset de ZFS.**
   ```bash
   rm /tank/dbdata/critical_payload.bin
   ls -la /tank/dbdata/
   ```
   *Salida esperada:*
   ```text
   total 2
   drwxr-xr-x  2 root  wheel  2 Aug  6 20:28 .
   drwxr-xr-x  3 root  wheel  3 Aug  6 20:28 ..
   ```

5. **Revertir instantáneamente el dataset al estado del snapshot.**
   ```bash
   zfs rollback tank/dbdata@pre_maintenance_20260806
   ls -la /tank/dbdata/
   ```
   *Salida esperada:*
   ```text
   total 102410
   drwxr-xr-x  2 root  wheel     3 Aug  6 20:28 .
   drwxr-xr-x  3 root  wheel     3 Aug  6 20:28 ..
   -rw-r--r--  1 root  wheel 104857600 Aug  6 20:28 critical_payload.bin
   ```

6. **Monitorear la sobrecarga del uso de espacio del snapshot de ZFS.**
   ```bash
   zfs get space tank/dbdata
   ```
   *Salida esperada:*
   ```text
   NAME         PROPERTY              VALUE  SOURCE
   tank/dbdata  name                  tank/dbdata  -
   tank/dbdata  avail                 49.9G  -
   tank/dbdata  used                  100M   -
   tank/dbdata  usedbysnapshots       0B     -
   tank/dbdata  usedbydataset         100M   -
   tank/dbdata  usedbyrefreservations 0B     -
   tank/dbdata  usedbychildren        0B     -
   ```

---

#### Preguntas de verificación (Ejercicio 3)

**Pregunta 3.1**: Un administrador ejecuta `df -h` en un sistema de archivos UFS2 y ve un 40% de espacio libre disponible, pero los procesos de la aplicación fallan con `No space left on device` (ENOSPC) al intentar crear archivos pequeños. ¿Qué salida de comando identifica la causa exacta de la falla y por qué ZFS no sufre de esta limitación estructural específica?  
**Pregunta 3.2**: Un ZFS storage pool alcanza el 96% de capacidad. Un ingeniero intenta ejecutar `zfs destroy` en snapshots innecesarios o crear un archivo para liberar espacio, pero los comandos se bloquean o devuelven mensajes de error de espacio. ¿Por qué ZFS no logra procesar operaciones de escritura/eliminación cuando un pool está 100% lleno, y qué remedio arquitectónico (por ejemplo, `zpool add` o archivos de reserva dummy) previene este bloqueo (deadlock)?

---

## 3. Respuestas de verificación y explicaciones detalladas

<details>
<summary>Haga clic para desplegar las respuestas de los ejercicios y las explicaciones técnicas detalladas</summary>

### Respuestas del Ejercicio 1

**Respuesta 1.1:**  
- **Propósito arquitectónico**: La reserva del 8% (minfree) evita que los cylinder groups de UFS sufran una fragmentación extrema en la asignación de bloques. Los algoritmos de asignación de UFS dependen de la disponibilidad de bloques contiguos dentro de los cylinder groups para mantener un alto rendimiento de E/S (I/O) secuencial.  
- **Impacto al superar el 92%**: A los procesos que no son root se les bloquea la escritura de más datos una vez que el uso del disco alcanza el umbral del 92% (`100% - minfree`), fallando con `ENOSPC`. Solo los procesos del superusuario `root` tienen permitido consumir el 8% de espacio final para realizar escrituras críticas de registros del sistema y operaciones de mantenimiento/recuperación.

**Respuesta 1.2:**  
- **Sintaxis de comando**:  
  ```bash
  fsck_ffs -b 1233920 /dev/da1p1
  ```  
- **Mecanismo**: La utilidad `fsck_ffs` lee una copia secundaria del superblock ubicada en el offset de bloque `1233920` (según lo impreso por `newfs`), copia su contenido de regreso sobre el superblock primario dañado en el bloque 24, recalculando la información del resumen del cylinder group y restaurando la legibilidad del sistema.

**Respuesta 1.3:**  
- **Soft Updates estándar (SU)**: Fuerza el orden de dependencias en RAM para las operaciones de metadatos (inodes, entradas de directorio, listas libres). En caso de una caída, se garantiza la consistencia estructural (sin punteros colgantes), pero se pueden filtrar bloques/inodes no referenciados. Un escaneo completo en segundo plano (`fsck_ffs -p`) debe recorrer todos los cylinder groups para reclamar los bloques perdidos.  
- **Soft Updates con Journaling (SU+J)**: Escribe las operaciones de intención de metadatos en un journal circular en línea. Al reiniciar después de un apagado no limpio, `fsck_ffs` lee el pequeño registro de journal, reproduce o deshace las transacciones no confirmadas en unos pocos segundos y marca el sistema de archivos como limpio sin necesidad de escanear millones de bloques de disco no referenciados.

---

### Respuestas del Ejercicio 2

**Respuesta 2.1:**  
- **Propósito**: `-o ashift=12` establece la alineación del tamaño de bloque del vdev a $2^{12} = 4096\text{ bytes}$ (sectores de 4KB).  
- **Impacto en el rendimiento**: Los discos modernos utilizan físicamente sectores de 4KB. Si se crea con `ashift=9` ($2^9 = 512\text{ bytes}$), cada escritura de 4KB realizada por ZFS causa una penalización de lectura-modificación-escritura (read-modify-write) a través de los límites físicos de 4KB, degradando el rendimiento de E/S (I/O) del disco hasta en un 800% y acelerando el desgaste físico de la unidad. `ashift` no se puede modificar después de la creación del pool.

**Respuesta 2.2:**  
- **Mecanismo**:  
  1. Cuando se leyó o escaneó `/tank/dbdata/critical_payload.bin` durante `zpool scrub`, ZFS calculó el checksum en vivo de los bloques de datos entrantes desde `/dev/da1`.  
  2. El checksum calculated no coincidió con el checksum Fletcher4/SHA256 almacenado de forma segura en el puntero del bloque padre dentro del árbol de Merkle.  
  3. ZFS detectó la corrupción de bloques en `/dev/da1` (incrementando el contador de errores `CKSUM` a 128).  
  4. Debido a que la topología del pool era un **Mirror**, ZFS leyó automáticamente el bloque de datos coincidente correcto desde `/dev/da2`.  
  5. ZFS devolvió los datos válidos de manera transparente al proceso solicitante, mientras emitía de forma asíncrona una escritura CoW para volver a escribir el bloque sano en `/dev/da1`, autoreparando el sector corrupto sin interrupción de la aplicación.

**Respuesta 2.3:**  
- **`quota`**: Define un **límite superior estricto** (hard upper limit) sobre el espacio máximo que un dataset y sus descendientes pueden consumir. Una vez alcanzado, las escrituras fallan.  
- **`reservation`**: Define una **asignación mínima garantizada de espacio en disco** reservada exclusivamente para ese dataset. Ningún otro dataset en el pool puede consumir esta capacidad reservada del pool, garantizando que las bases de datos críticas o los registros del sistema nunca me queden sin espacio debido a vecinos ruidosos (noisy neighbors) que llenen la capacidad compartida del pool.

---

### Respuestas del Ejercicio 3

**Respuesta 3.1:**  
- **Comando de diagnóstico**: Ejecutar `df -i` revela una utilización de inodes del 100% (`iused` = 100%), lo que significa que se han consumido todos los inodes estáticos fijos asignados durante la creación con `newfs`, incluso si la capacidad de bloques de datos crudos (`df -h`) permanece libre.  
- **Por qué difiere ZFS**: ZFS no utiliza tablas de inodes estáticas. Los inodes (ZFS File Nodes, o `znodes`) se asignan dinámicamente bajo demanda como objetos dentro del diseño SPA (Storage Pool Allocator) de ZFS desde el espacio general del pool. No existe un límite de inodes en ZFS hasta que todo el pool se queda sin bytes de almacenamiento crudo.

**Respuesta 3.2:**  
- **Por qué se bloquean los pools llenos**: ZFS es un sistema de archivos Copy-on-Write (CoW). Para eliminar un archivo o snapshot, ZFS primero debe escribir nuevos punteros de bloque y actualizar los árboles de metadatos en el disco. Si un pool alcanza el 100% de la capacidad cruda, ZFS no puede asignar nuevo espacio para realizar las operaciones de escritura de eliminación, lo que provoca un bloqueo operativo (deadlock) catastrófico.  
- **Remedios arquitectónicos**:  
  1. Mantener un archivo dummy preasignado (por ejemplo, un archivo de 2GB creado a través de `dd if=/dev/zero of=/tank/reservation.mem bs=1M count=2000`) en pools críticos. Cuando esté 100% lleno, desvincular (unlink) este archivo dummy libera espacio al instante sin requerir escrituras de asignación.  
  2. Adjuntar temporalmente un disco crudo o archivo disperso (sparse file) al pool usando `zpool add tank /dev/da3` para inyectar espacio fresco de bloques, permitir que se completen las actualizaciones/eliminaciones de metadatos y despejar la capacidad del pool.

</details>

---

## 4. Documentación oficial y referencias

- **FreeBSD Handbook — Storage & File Systems**: [https://docs.freebsd.org/en/books/handbook/filesystems/](https://docs.freebsd.org/en/books/handbook/filesystems/)
- **FreeBSD Handbook — The Zettabyte File System (ZFS)**: [https://docs.freebsd.org/en/books/handbook/zfs/](https://docs.freebsd.org/en/books/handbook/zfs/)
- **OpenBSD Manual Pages — `newfs(8)`**: [https://man.openbsd.org/newfs.8](https://man.openbsd.org/newfs.8)
- **OpenBSD Manual Pages — `fsck_ffs(8)`**: [https://man.openbsd.org/fsck_ffs.8](https://man.openbsd.org/fsck_ffs.8)
- **OpenBSD Manual Pages — `tunefs(8)`**: [https://man.openbsd.org/tunefs.8](https://man.openbsd.org/tunefs.8)
- **LPI BSD Specialist Objective Map**: [https://www.lpi.org/our-certifications/bsd-specialist-overview/](https://www.lpi.org/our-certifications/bsd-specialist-overview/)