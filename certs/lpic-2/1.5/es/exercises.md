# LPIC-2: Administración Avanzada de Dispositivos de Almacenamiento (Tema 204 / Tema 1.5)
**Peso en el examen:** 7  
**Certificación objetivo:** LPIC-2 (Exámenes 201-450 y 202-450, Versión 4.5)  
**Audiencia objetivo:** SREs, Platform Engineers y Administradores de Sistemas Linux  

---

## 1. Arquitectura Técnica Profunda y Fundamento Teórico

### 1.1 La Arquitectura de la Capa de I/O de Bloques de Linux
La pila de almacenamiento de Linux abstrae hardware físico heterogéneo en dispositivos de bloques presentados bajo `/dev/`. Las solicitudes de I/O atraviesan múltiples capas de abstracción antes de llegar al medio físico:

```
+-----------------------------------------------------------------------+
|                    Virtual File System (VFS)                          |
|                       (ext4, xfs, btrfs)                              |
+-----------------------------------------------------------------------+
|                       Page Cache / Buffer Cache                       |
+-----------------------------------------------------------------------+
|                    Generic Block Layer (bio structs)                  |
+-----------------------------------------------------------------------+
|  Device Mapper (dm)   |  Multiple Devices (md) | Block Interface      |
|  (LVM2, Thin, Cache)  |  (Software RAID)       | (Loop, NVMe, SCSI)    |
+-----------------------------------------------------------------------+
|                     Multi-Queue Block Layer (blk-mq)                  |
|                 Software Queues (per-CPU) -> Hardware Queues          |
+-----------------------------------------------------------------------+
|                    I/O Scheduler (BFQ, Kyber, mq-deadline, none)      |
+-----------------------------------------------------------------------+
|                Low-Level Drivers (nvme, ahci, mpt3sas)                |
+-----------------------------------------------------------------------+
|                 Physical Storage (NVMe SSD, SATA HDD, SAN LUN)        |
+-----------------------------------------------------------------------+
```

1. **VFS y Page Cache**: Las llamadas al sistema de alto nivel (`read`, `write`, `fsync`) interactúan con las estructuras de memoria estándar del SO.
2. **Generic Block Layer**: Convierte las operaciones del sistema de archivos en instancias `struct bio` que representan operaciones de rangos de bloques contiguos.
3. **Device Mapper (DM) y Multiple Devices (MD)**: Frameworks de dispositivos de bloques virtuales que reasignan direcciones de sectores. DM sustenta LVM2, LUKS y multipathing; MD impulsa el RAID por software del kernel.
4. **blk-mq (Subsistema de Bloques Multicola)**: Mapea colas de envío por CPU directamente a colas de despacho de hardware, eliminando los cuellos de botella de bloqueos globales heredados (`blk-sq`) y soportando millones de IOPS en unidades NVMe modernas.
5. **Planificadores de I/O**: Optimizan las solicitudes de disco basándose en las características de latencia subyacentes.

---

### 1.2 RAID por Software de Linux (Módulo MD)
El módulo del kernel `md` (Multiple Devices) opera directamente por encima de los dispositivos de bloques puros, proporcionando striping, mirroring y paridad definidos por software.

```
       +------------------------------------+
       |          /dev/md0 (RAID 5)         |
       +------------------------------------+
       |  MD Kernel Driver (Parity Calc)    |
       +------------------+-----------------+
                          |
     +--------------------+--------------------+
     |                    |                    |
+----+----+          +----+----+          +----+----+
| /dev/sdb|          | /dev/sdc|          | /dev/sdd|
| (Data)  |          | (Data)  |          | (Parity)|
+---------+          +---------+          +---------+
```

#### Versiones del Superbloque de Metadatos de RAID
* **Versión 0.90**: Formato de metadatos heredado ubicado al final del dispositivo. Limitado a 28 dispositivos componentes y tamaños de array de 2TB.
* **Versión 1.0**: Ubicado al final del dispositivo (permite a los gestores de arranque leer datos directamente como una partición estándar).
* **Versión 1.1**: Ubicado al inicio del dispositivo (offset 0).
* **Versión 1.2 (Predeterminado)**: Ubicado a 4KiB del inicio del dispositivo. Deja espacio para los gestores de arranque mientras protege los metadatos de sobrescrituras.

#### Bitmaps de Intención de Escritura (Write-Intent Bitmaps)
Cuando un componente del array falla o se desconecta temporalmente, mdadm rastrea los bloques modificados en un **Bitmap de Intención de Escritura** (interno o externo). Al reincorporar el dispositivo, el kernel realiza una resincronización diferencial rápida (`re-add`) en lugar de una reconstrucción completa del array.

---

### 1.3 Mecánica del Administrador de Volúmenes Lógicos (LVM2)
LVM2 utiliza el framework del kernel Device Mapper (`dm-mod`) para proporcionar una gestión flexible de volúmenes lógicos.

```
+-------------------------------------------------------------------------+
| Logical Volume (LV)         | /dev/vg_prod/lv_app (Thin / Mirrored)     |
+-------------------------------------------------------------------------+
| Volume Group (VG)           | vg_prod (Pool of Physical Extents)        |
+-------------------------------------------------------------------------+
| Physical Volume (PV)        | /dev/sdb1               | /dev/sdc1       |
+-------------------------------------------------------------------------+
| Partition / Disk            | /dev/sdb                | /dev/sdc        |
+-------------------------------------------------------------------------+
```

* **Physical Extents (PE)**: Unidades de asignación (predeterminado 4MiB) que componen un Volume Group.
* **Logical Extents (LE)**: Mapeados 1:1 a Physical Extents en LVs lineales, o intercalados a través de PVs en LVs con striping/RAID.
* **Estructura de Metadatos**: Los descriptores de LVM se escriben en el área de cabecera del Physical Volume (PV Header) en formato tipo ASCII/JSON. `vgcfgbackup` vuelca este estado en `/etc/lvm/backup/`.
* **Copy-on-Write (COW) vs. Thin Provisioning**:
  * **Snapshots COW Tradicionales**: Cuando los datos en el LV de origen cambian, el bloque original se copia al volumen de snapshot antes de ser sobrescrito. La latencia de escritura aumenta a medida que crece la cantidad de snapshots (penalización de escritura $O(N)$).
  * **Snapshots con Thin Provisioning**: Utiliza un pool dedicado de datos/metadatos. Asigna bloques a petición mediante una tabla virtual de asignación de bloques (asignación $O(1)$), lo que permite una asignación de espacio instantánea y con bajo overhead.

---

### 1.4 Análisis de Compromisos Arquitectónicos

| Característica / Métrica | RAID 1 | RAID 5 | RAID 10 | LVM Thick (Lineal) | LVM Thin Provisioning |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Tolerancia a Fallos** | 1 disco por par en espejo | 1 disco máx. | 1 disco por par en espejo | Ninguna (hereda el PV subyacente) | Ninguna (hereda el PV subyacente) |
| **Eficiencia de Almacenamiento** | 50% | $(N-1)/N$ | 50% | 100% asignado | Hasta >100% (Overcommit) |
| **Overhead de Escritura Aleatoria** | 2 Escrituras (Datos + Espejo) | 4 IOPS (Lectura D/P, Escritura D/P) | 2 Escrituras | Mínimo | Actualización de metadatos al asignar |
| **Overhead de Snapshots** | N/A | N/A | N/A | Alta amplificación de escritura COW | Despreciable (metadatos $O(1)$) |
| **Riesgo de Overcommit** | Ninguno | Ninguno | Ninguno | Ninguno | **Alto** (El agotamiento del pool deja el volumen fuera de línea) |

---

### 1.5 Referencias Oficiales y Documentación
* [LPI LPIC-2 Certification Overview](https://www.lpi.org/our-certifications/lpic-2-overview/)
* [Linux Kernel MD Driver Documentation](https://www.kernel.org/doc/html/latest/driver-api/md/md.html)
* [LVM2 Administration Manual (Red Hat / Linux Docs)](https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/configuring_and_managing_logical_volumes/index)
* [Linux Block Layer & blk-mq Kernel Documentation](https://www.kernel.org/doc/html/latest/block/index.html)

---

## 2. Ejercicios Prácticos Guiados de Producción

### Bloque 1: Creación, Mantenimiento e Inyección de Fallos en RAID por Software de Linux

#### Paso 1: Crear un Array RAID 5 con un Bitmap de Intención de Escritura Interno y Spare en Caliente (Hot Spare)
Ejecutá `mdadm` para construir un array RAID 5 llamado `/dev/md0` utilizando 3 dispositivos de bloques activos (`/dev/sdb`, `/dev/sdc`, `/dev/sdd`) y 1 dispositivo spare (`/dev/sde`), especificando metadatos v1.2 y un bitmap interno.

```bash
sudo mdadm --create /dev/md0 \
  --level=5 \
  --raid-devices=3 \
  --spare-devices=1 \
  --metadata=1.2 \
  --bitmap=internal \
  /dev/sdb /dev/sdc /dev/sdd /dev/sde
```

**Salida esperada del comando:**
```text
mdadm: /dev/sdb appears to contain an logs filesystem -- continue verification? yes
mdadm: Defaulting to version 1.2 metadata
mdadm: array /dev/md0 started.
```

#### Paso 2: Consultar el Estado de Ejecución del Array e Inspeccionar Metadatos
Monitoreá el progreso de sincronización en tiempo real a través de `/proc/mdstat` y obtené atributos detallados del array:

```bash
cat /proc/mdstat
```

**Salida esperada del comando:**
```text
Personalities : [raid6] [raid5] [raid4] 
md0 : active raid5 sdd[2] sde[3](S) sdc[1] sdb[0]
      4188160 blocks super 1.2 level 5, 512k chunk, algorithm 2 [3/3] [UUU]
      bitmap: 0/1 pages [0KB], 65536KB chunk

unused devices: <none>
```

Ejecutá una consulta detallada sobre `/dev/md0`:

```bash
sudo mdadm --detail /dev/md0
```

**Salida esperada del comando:**
```text
/dev/md0:
           Version : 1.2
     Creation Time : Thu Aug  6 10:30:00 2026
        Raid Level : raid5
        Array Size : 4188160 (3.99 GiB 4.29 GB)
     Used Dev Size : 2094080 (2.00 GiB 2.14 GB)
      Raid Devices : 3
     Total Devices : 4
       Persistence : Superblock is present

     Intent Bitmap : Internal
        State : clean 
Active Devices : 3
Working Devices : 4
 Failed Devices : 0
  Spare Devices : 1

        Layout : left-symmetric
    Chunk Size : 512K

Consistency Policy : bitmap

          Name : storage-node-01:0  (local to host storage-node-01)
          UUID : e4a123bc:89f1023a:771b9c0d:12ef3456
        Events : 12

    Number   Major   Minor   RaidDevice State
       0       8       16        0      active sync   /dev/sdb
       1       8       32        1      active sync   /dev/sdc
       2       8       48        2      active sync   /dev/sdd

       3       8       64        -      spare   /dev/sde
```

#### Paso 3: Persistir la Configuración del Array en `mdadm.conf`
Generá el archivo de mapeo persistente del sistema para garantizar una inicialización predecible a través de los reinicios del sistema:

```bash
sudo mkdir -p /etc/mdadm
sudo mdadm --detail --scan | sudo tee /etc/mdadm/mdadm.conf
```

**Manifiesto sintácticamente válido de `/etc/mdadm/mdadm.conf`:**
```text
# /etc/mdadm/mdadm.conf
# Automatically generated configuration file for mdadm software RAID arrays.
MAILADDR admin@infrastructure.internal
ARRAY /dev/md0 metadata=1.2 name=storage-node-01:0 UUID=e4a123bc:89f1023a:771b9c0d:12ef3456
```

#### Paso 4: Inyectar un Fallo, Verificar la Reconstrucción Automática y Reincorporar el Hot Spare
Simulá un fallo de hardware de disco en `/dev/sdb` para probar la autorreconstrucción con el hot spare:

```bash
sudo mdadm --manage /dev/md0 --fail /dev/sdb
```

**Salida esperada del comando:**
```text
mdadm: set /dev/sdb faulty in /dev/md0
```

Verificá el estado del array inmediatamente para observar la activación automática de `/dev/sde`:

```bash
sudo mdadm --detail /dev/md0 | grep -E "(State|Device)"
```

**Salida esperada del comando:**
```text
        State : clean, degraded, recovering 
Active Devices : 2
Working Devices : 3
 Failed Devices : 1
  Spare Devices : 0
Rebuild Status : 35% complete
    Number   Major   Minor   RaidDevice State
       3       8       64        0      spare rebuild   /dev/sde
       1       8       32        1      active sync   /dev/sdc
       2       8       48        2      active sync   /dev/sdd

       0       8       16        -      faulty   /dev/sdb
```

Remové el disco defectuoso y agregá un dispositivo de reemplazo:

```bash
sudo mdadm --manage /dev/md0 --remove /dev/sdb
sudo mdadm --manage /dev/md0 --add /dev/sdf
```

---

### Preguntas — Bloque 1
1. **P1.1**: ¿Qué ventaja operacional específica ofrece un *bitmap de intención de escritura interno* cuando un disco miembro fallido en un array RAID 5 se desconecta temporalmente y luego se vuelve a agregar, en comparación con un array configurado sin bitmap?
2. **P1.2**: ¿Por qué es peligroso confiar únicamente en el autoensamblado del array mediante escaneos de dispositivos (`mdadm --assemble --scan`) sin mapear explícitamente los UUIDs en `/etc/mdadm/mdadm.conf` en sistemas con múltiples controladores de almacenamiento?

---

### Bloque 2: Ajuste Avanzado de Almacenamiento, Diagnósticos NVMe y Reglas de udev Persistentes

#### Paso 1: Consultar Parámetros de Cola de la Capa de Bloques y Métricas de Salud NVMe
Inspeccioná los algoritmos actuales del planificador de I/O, los tamaños de búfer de readahead y las flags rotacionales para los dispositivos de almacenamiento:

```bash
cat /sys/block/sda/queue/scheduler
cat /sys/block/sda/queue/read_ahead_kb
cat /sys/block/sda/queue/rotational
```

**Salida esperada del comando:**
```text
[mq-deadline] bfq kyber none
128
0
```

Usá `nvme-cli` para inspeccionar la salud del controlador, los umbrales de temperatura y las advertencias críticas del Endurance Group en un dispositivo NVMe (`/dev/nvme0n1`):

```bash
sudo nvme smart-log /dev/nvme0n1
```

**Salida esperada del comando:**
```text
Smart Log for NVMe device:nvme0n1 namespace-id:1
critical_warning                    : 0
temperature                         : 38 C
available_spare                     : 100%
available_spare_threshold           : 10%
percentage_used                     : 2%
data_units_read                     : 14523910
data_units_written                  : 9812404
host_read_commands                  : 120482103
host_write_commands                 : 89341201
controller_busy_time                : 412
power_cycles                        : 14
power_on_hours                      : 1240
unsafe_shutdowns                    : 2
media_errors                        : 0
num_err_log_entries                 : 0
```

#### Paso 2: Implementar Reglas de Rendimiento de udev Persistentes
Construí una regla personalizada de udev `/etc/udev/rules.d/99-storage-performance.rules` para aplicar automáticamente planificadores de I/O óptimos y configuraciones de readahead según el tipo de transporte del dispositivo (SSD NVMe vs. HDD SATA rotacional).

**Manifiesto sintácticamente válido de `/etc/udev/rules.d/99-storage-performance.rules`:**
```udev
# /etc/udev/rules.d/99-storage-performance.rules
# Production tuning for Enterprise Block Storage Devices

# Rule 1: Set non-rotational NVMe devices to 'none' (bypass I/O scheduler overhead for blk-mq)
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="none", ATTR{queue/read_ahead_kb}="256"

# Rule 2: Set non-rotational SATA/SAS SSDs to 'mq-deadline'
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="mq-deadline", ATTR{queue/read_ahead_kb}="128"

# Rule 3: Set rotational HDDs to 'bfq' and optimize read-ahead for sequential access
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq", ATTR{queue/read_ahead_kb}="2048"
```

#### Paso 3: Activar y Validar la Ejecución de la Regla udev
Recargá el daemon de control de udev y activá el procesamiento de reglas en todos los dispositivos de bloques sin reiniciar:

```bash
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=block
```

Verificá que las configuraciones se hayan aplicado correctamente a una unidad NVMe:

```bash
udevadm info --query=property --name=/dev/nvme0n1 | grep -E "(DEVNAME|SUBSYSTEM)"
cat /sys/block/nvme0n1/queue/scheduler
```

**Salida esperada del comando:**
```text
[none] mq-deadline bfq kyber
```

---

### Preguntas — Bloque 2
1. **P2.1**: ¿Por qué se recomienda configurar el planificador de I/O en `none` (o `noop`) para unidades de estado sólido NVMe modernas que operan sobre la arquitectura del kernel `blk-mq`?
2. **P2.2**: Si `percentage_used` en `nvme smart-log` alcanza el 100%, ¿la unidad experimenta inmediatamente un fallo de hardware crítico? Explicá el significado técnico de la métrica.

---

### Bloque 3: Arquitectura Avanzada de LVM2: Thin Provisioning, LVs en Espejo y Snapshots COW

#### Paso 1: Inicializar Physical Volumes y el Volume Group
Inicializá `/dev/md0` y `/dev/sdf` como Physical Volumes de LVM, y luego creá un Volume Group llamado `vg_production` con un tamaño de Physical Extent (PE) personalizado de 8MiB:

```bash
sudo pvcreate /dev/md0 /dev/sdf
sudo vgcreate -s 8M vg_production /dev/md0 /dev/sdf
```

**Salida esperada del comando:**
```text
  Physical volume "/dev/md0" successfully created.
  Physical volume "/dev/sdf" successfully created.
  Volume group "vg_production" successfully created
```

#### Paso 2: Configurar un Thin Pool de LVM y un Thin Logical Volume
Creá un Thin Pool de 2GiB (`thinpool_data`) dentro de `vg_production`. Luego aprovisioná un Thin Logical Volume de 10GiB (`lv_app_data`) a partir del pool (demostrando overcommit):

```bash
sudo lvcreate -L 2G --thinpool thinpool_data vg_production
sudo lvcreate -V 10G --thin -n lv_app_data vg_production/thinpool_data
```

**Salida esperada del comando:**
```text
  Thin pool metadata block size is 64.00 KiB.
  Logical volume "thinpool_data" created.
  Logical volume "lv_app_data" created.
```

Inspeccioná las estadísticas de asignación de thin usando `lvs`:

```bash
sudo lvs -o lv_name,vg_name,lv_size,data_percent,metadata_percent,thin_prov_volume vg_production
```

**Salida esperada del comando:**
```text
  LV           VG            LSize  Data%  Meta%  Thin
  lv_app_data  vg_production 10.00g 0.00   0.00       
  thinpool_data vg_production  2.00g 0.00   10.55      
```

#### Paso 3: Configurar la Extensión Automatizada del Thin Pool en `lvm.conf`
Editá `/etc/lvm/lvm.conf` para extender automáticamente los thin pools cuando se superen los umbrales de uso, protegiendo contra pánicos por asignación sin espacio.

**Manifiesto parcial para `/etc/lvm/lvm.conf`:**
```text
activation {
    ...
    thin_pool_autoextend_threshold = 80
    thin_pool_autoextend_percent = 20
    ...
}
```

*Explicación*: Cuando la asignación del pool alcanza el **80%**, LVM autoextiende el thin pool en un **20%** de su tamaño actual utilizando el espacio disponible en el Volume Group.

#### Paso 4: Crear un Snapshot y Realizar una Operación de Merge de Snapshot
Formateá y montá `lv_app_data`, escribí archivos de prueba, creá un snapshot COW, simulá cambios de corrupción y revertí el volumen usando `lvconvert --merge`.

```bash
sudo mkfs.xfs /dev/vg_production/lv_app_data
sudo mkdir -p /mnt/appdata
sudo mount /dev/vg_production/lv_app_data /mnt/appdata
echo "Production State V1" | sudo tee /mnt/appdata/state.txt
```

Creá un snapshot llamado `snap_lv_app_data`:

```bash
sudo lvcreate -s -n snap_lv_app_data /dev/vg_production/lv_app_data
```

Corrompé datos en el volumen de origen:

```bash
echo "Corrupted State V2" | sudo tee /mnt/appdata/state.txt
sudo umount /mnt/appdata
```

Hacé merge del snapshot de vuelta al volumen de origen para restaurar el estado:

```bash
sudo lvconvert --merge /dev/vg_production/snap_lv_app_data
```

**Salida esperada del comando:**
```text
  Merging of volume vg_production/snap_lv_app_data started.
  vg_production/lv_app_data: Merged: 100.00%
```

Vuelve a montar y verificá la restauración de los datos:

```bash
sudo mount /dev/vg_production/lv_app_data /mnt/appdata
cat /mnt/appdata/state.txt
```

**Salida esperada del comando:**
```text
Production State V1
```

---

### Preguntas — Bloque 3
1. **P3.1**: ¿Qué evento catastrófico ocurre si un Thin Pool de LVM alcanza el 100% de asignación de espacio de datos mientras los volúmenes lógicos thin tienen solicitudes de escritura pendientes sin responder?
2. **P3.2**: ¿Cómo maneja el kernel una operación activa de `lvconvert --merge` en un volumen de origen que actualmente está montado y ocupado?

---

## 3. Mecánica de Diagnóstico y Resolución de Problemas

Cuando surgen problemas de almacenamiento en entornos de alta disponibilidad, los SREs deben ubicar sistemáticamente los puntos de fallo utilizando interfaces del kernel de bajo nivel.

### Matriz de Diagnóstico y Flujo de Comandos

```
  +-----------------------+
  | Storage Anomaly Detected |
  +-----------+-----------+
              |
              v
   Check Device Mapper Status
   `dmsetup status` / `dmsetup table`
              |
     +--------+--------+
     |                 |
     v                 v
[ RAID Failure ]  [ LVM Thin Pool Exhaustion ]
`mdadm --detail`  `lvs -a -o +thin_count,data_percent`
     |                 |
     v                 v
[ Re-add Spare ]  [ Extend Thin Pool / VG ]
`mdadm --add`     `lvextend -L +XG vg/pool`
```

#### Script de Diagnóstico: Verificación de Integridad de la Capa de Almacenamiento
Ejecutá el siguiente script bash para auditar arrays MD RAID, Thin Pools de LVM y errores de transporte de dispositivos de bloques en todo el sistema:

```bash
#!/usr/bin/env bash
set -euo pipefail

echo "=========================================="
echo " 1. MD RAID Array Health Summary"
echo "=========================================="
if [ -f /proc/mdstat ]; then
    cat /proc/mdstat
else
    echo "No MD driver loaded."
fi

echo ""
echo "=========================================="
echo " 2. LVM Thin Pool Allocation Check"
echo "=========================================="
sudo lvs -a -o lv_name,vg_name,attr,size,data_percent,metadata_percent | grep -E "t[a-z-]" || echo "No Thin Pools found."

echo ""
echo "=========================================="
echo " 3. Kernel I/O Error Audit (dmesg)"
echo "=========================================="
sudo dmesg -T --level=err,crit,alert | grep -E "(blk_update_request|I/O error|nvme|md0)" || echo "No critical block device errors in dmesg."
```

---

<details>
<summary>Click para desplegar Respuestas y Explicaciones Detalladas</summary>

### Respuestas del Bloque 1

#### **R1.1**:
Un bitmap de intención de escritura interno rastrea los bloques desincronizados utilizando un mapa de bits de grano grueso donde cada bit representa un bloque de espacio en disco (por ejemplo, 64KB). Cuando un disco falla o se desconecta, las escrituras continúan en los miembros activos restantes del array, y solo los bits correspondientes en el bitmap se marcan como sucios (dirty). 

Cuando el disco se reincorpora, `mdadm` lee el bitmap y realiza una **resincronización diferencial** (reincorporando solo los bloques sucios) en lugar de una reconstrucción completa. Esto reduce el tiempo de recuperación de horas a segundos y evita una degradación severa de I/O en todo el array de almacenamiento.

#### **R1.2**:
Confiar puramente en el escaneo de nombres de dispositivos (`/dev/sd*`) durante el arranque no es determinista porque los kernels Linux modernos enumeran los controladores de almacenamiento y los dispositivos de bloques de forma asíncrona en paralelo. Como resultado, `/dev/sdb` durante el arranque $N$ podría convertirse en `/dev/sdc` durante el arranque $N+1$. 

Sin definiciones explícitas de `UUID` fijadas en `/etc/mdadm/mdadm.conf`, el sistema puede fallar al ensamblar los arrays correctamente o ensamblar dispositivos incorrectos juntos, lo que podría provocar la corrupción del array o fallos en el arranque.

---

### Respuestas del Bloque 2

#### **R2.1**:
Los planificadores de I/O heredados (`bfq`, `mq-deadline`) fueron diseñados para minimizar el overhead de búsqueda mecánica en discos duros giratorios de cola única mediante el reordenamiento de solicitudes. Las unidades NVMe modernas utilizan el subsistema multicola (`blk-mq`), exponiendo hasta 64,000 colas de envío de hardware paralelas con paralelismo a nivel de hardware. 

Pasar las solicitudes a través de un planificador de CPU a nivel de software introduce bloqueos inútiles de CPU, overhead de asignación de memoria y cambios de contexto de instrucciones. Configurar el planificador en `none` permite que las solicitudes pasen directamente de las colas de software por CPU a las colas de hardware NVMe, maximizando las IOPS y minimizando la latencia.

#### **R2.2**:
No. El `percentage_used` en los datos SMART de NVMe es un **indicador de durabilidad** calculado por el fabricante del dispositivo basándose en los límites de ciclos de escritura (TBW - Total Bytes Written) para el medio Flash NVM. 

Un valor del 100% significa que la unidad ha alcanzado el límite de durabilidad de escritura garantizado por el fabricante. La unidad puede continuar funcionando normalmente durante un período considerable, pero el riesgo de degradación de las celdas flash aumenta y la cobertura de la garantía del fabricante suele expirar.

---

### Respuestas del Bloque 3

#### **R3.1**:
Si un Thin Pool alcanza el 100% de asignación de espacio de datos, el controlador Device Mapper no puede asignar nuevos bloques físicos para las solicitudes de escritura entrantes. Dependiendo del parámetro de configuración `error_if_no_space` en LVM:
1. El kernel bloquea las operaciones de I/O indefinidamente esperando espacio, lo que hace que los hilos de las aplicaciones se cuelguen en estado de suspensión ininterrumpible (Uninterruptible Sleep, estado `D`).
2. O bien, las solicitudes de I/O fallan inmediatamente con `EIO` (Input/Output Error), lo que provoca que los sistemas de archivos (como XFS o ext4) se remonten en **Solo Lectura** (Read-Only) o entren en pánico para preservar la consistencia de los metadatos.

#### **R3.2**:
Si el volumen lógico de origen está montado y activo cuando se ejecuta `lvconvert --merge`, el controlador Device Mapper registra una **operación de merge diferida**. El merge del snapshot comenzará automáticamente en el próximo reinicio del sistema cuando se active el LV de origen, o tan pronto como el sistema de archivos se desmonte y el volume group se refresque mediante `vgchange -an` / `vgchange -ay`.

</details>