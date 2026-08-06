# Examen LPIC-3 306-300 (v3.0) — Tema 306.4: Single Node High Availability

## Visión General de la Arquitectura y Alcance del Dominio

Single Node High Availability (HA) establece la capa base de resiliencia de la infraestructura antes de extender las cargas de trabajo a través de clústeres multinodo distribuidos. En entornos de producción SRE, una falla en la capa de un solo nodo —como una corrupción silenciosa de datos, timeouts no manejados del watchdog del kernel, caídas del enlace de red o pérdida de rutas de almacenamiento— degrada el tiempo medio entre fallas (MTBF) del control plane del clúster de nivel superior (por ejemplo, Pacemaker, Corosync, Kubernetes).

Esta guía de estudio cubre los cuatro pilares fundamentales de Single Node High Availability definidos en el temario de LPIC-3 306-300 (Peso del examen: 25):

```
+-----------------------------------------------------------------------------------+
|                        SINGLE NODE HIGH AVAILABILITY (HA)                         |
+------------------------------------+----------------------------------------------+
| 1. Hardware & System Health        | 2. Storage Fault Tolerance                   |
|    - SMART Disk Diagnostics        |    - mdadm Software RAID (v1.2 Superblock)  |
|    - UPS Management (NUT / upsd)   |    - Write-Intent Bitmaps & Resync        |
|    - Linux Kernel & systemd        |    - LVM2 RAID1/5/6 & Thin Auto-Extend    |
|      Hardware Watchdogs            |    - dmeventd Monitoring Daemon             |
+------------------------------------+----------------------------------------------+
| 3. SAN Path Resiliency             | 4. Network Link Aggregation                  |
|    - Device-Mapper Multipathing    |    - Linux Kernel Bonding Driver             |
|    - SCSI ALUA & Path Selectors    |    - Active-Backup vs LACP (802.3ad)        |
|    - multipathd Path Checkers      |    - MII & ARP Link Health Monitoring        |
+------------------------------------+----------------------------------------------+
```

### Referencias Oficiales
* [Linux Professional Institute (LPI) LPIC-3 306-300 Objectives](https://www.lpi.org/our-certifications/lpic-3-306-overview/)
* [Linux Kernel Bonding Driver Documentation](https://www.kernel.org/doc/Documentation/networking/bonding.txt)
* [Red Hat Enterprise Linux Device Mapper Multipathing Guide](https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/configuring_device-mapper_multipath/)
* [Network UPS Tools (NUT) User Manual](https://networkupstools.org/docs/user-manual.chunked/index.html)
* [systemd Watchdog Integration & Execution Environment](https://www.freedesktop.org/software/systemd/man/latest/systemd-system.conf.html)

---

## Módulo 1: Monitoreo de Salud del Hardware y del Sistema (SMART, UPS, Watchdogs)

### 1.1 Arquitectura Técnica Profunda y Mecánica

#### SMART (Self-Monitoring, Analysis, and Reporting Technology)
Las unidades de almacenamiento modernas (SATA HDDs, NVMe SSDs) mantienen registros internos no volátiles que rastrean la telemetría del hardware. `smartd` (parte de `smartmontools`) se ejecuta como un demonio en segundo plano monitoreando atributos clave:
* **Reallocated_Sector_Ct (Atributo 5):** Cantidad de sectores físicos remapeados. Valores distintos de cero indican degradación física de la superficie.
* **Current_Pending_Sector_Ct (Atributo 197):** Sectores inestables que aguardan verificación de lectura/escritura antes de su reubicación.
* **NVMe Percentage Used & Media Errors:** Para unidades NVMe, la telemetría se analiza a través de los registros de salud NVMe (`smartctl -a /dev/nvme0n1`), monitoreando la capacidad de reserva y las métricas de desgaste.

#### Arquitectura del Protocolo Network UPS Tools (NUT)
NUT desacopla el monitoreo de hardware de las notificaciones a los clientes mediante una arquitectura de tres niveles:
1. **Nivel de Driver (`bcmxcpy`, `usbhid-ups`, `snmp-ups`):** Se comunica con el hardware UPS físico a través de USB/Serial/SNMP y escribe el estado del hardware en sockets IPC compartidos.
2. **Demonio Servidor (`upsd`):** Escucha en el puerto TCP 3493, entregando actualizaciones de estado a las conexiones cliente autenticadas.
3. **Demonio de Monitoreo (`upsmon`):** Actúa como el motor de ejecución. En una topología Primary/Secondary (`master`/`slave`), `upsmon` detecta estados `FSD` (Forced Shutdown), inicia apagados ordenados del SO y le indica al hardware UPS que corte la energía (`upsdrvctl shutdown`).

#### Watchdogs de Hardware y Software del Kernel de Linux
La infraestructura de watchdog de Linux protege contra kernel panics, bloqueos mutuos de CPU (CPU deadlocks) y demonios de userspace colgados:
* **Hardware Watchdog (`/dev/watchdog`):** Un módulo temporizador físico (por ejemplo, IPMI, Intel TCO) o un temporizador virtual del hipervisor. El sistema debe escribir en `/dev/watchdog` dentro de un intervalo determinado (`WatchdogSec`). Si no se escribe, el hardware fuerza un reinicio inmediato del sistema (NMI/hard reset).
* **Systemd Service Watchdogs (`sd_notify`):** `systemd` configura los servicios del sistema con `WatchdogSec=N`. El servicio envía señales de keepalive (`sd_notify("WATCHDOG=1")`) a intervalos `< N/2`. Si el event loop se congela, `systemd` dispara la lógica de reinicio del servicio o reinicia el nodo si está configurado con `FailureAction=reboot`.

```
           +----------------------------------------------------------------+
           |                    Systemd Manager / Kernel                    |
           +----------------------------------------------------------------+
             | sd_notify("WATCHDOG=1")               | /dev/watchdog Ping
             v                                       v
   +-------------------+                   +-------------------+
   | Critical Service  |                   | Hardware Watchdog |
   | Event Loop        |                   | Timer (IPMI/TCO)  |
   +-------------------+                   +-------------------+
             | (If Hung)                             | (Timer Expires)
             v                                       v
   +-------------------+                   +-------------------+
   | systemd Kills &   |                   | HARD HARDWARE     |
   | Restores Service  |                   | REBOOT TRIGGERED  |
   +-------------------+                   +-------------------+
```

---

### 1.2 Archivos de Configuración y Manifests de Producción

#### `/etc/smartd.conf`
```conf
# Monitor all NVMe and SATA drives with desktop alerts and automatic self-tests
DEVICESCAN -H -m sre-alerts@infrastructure.internal -M exec /usr/share/smartmontools/smartd-runner \
-s (S/../.././02|L/../6/./03) \
-W 4,45,55 \
-I 194 -I 195 -I 200
```

#### `/etc/nut/ups.conf`
```conf
[prg-ups-01]
    driver = usbhid-ups
    port = auto
    desc = "Production Rack 01 Main Eaton UPS"
    vendorid = "0463"
    productid = "ffff"
    pollinterval = 2
```

#### `/etc/nut/upsmon.conf`
```conf
MONITOR prg-ups-01@localhost 1 upsmon_admin SecretPassword123 master
MINSUPPLIES 1
SHUTDOWNCMD "/sbin/shutdown -h +0"
POWERDOWNFLAG /etc/killpower
POLLFREQ 5
POLLFREQALERT 2
HOSTSYNC 15
DEADTIME 15
RBWARNTIME 43200
NOCOMMWARNTIME 300
FINALDELAY 5
```

#### `/etc/systemd/system.conf` (Configuración de Watchdog a Nivel de Sistema)
```ini
[Manager]
RuntimeWatchdogSec=10s
RebootWatchdogSec=10m
KExecWatchdogSec=5m
```

#### `/etc/systemd/system/ha-core-engine.service`
```ini
[Unit]
Description=Production Critical HA Engine
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStart=/usr/local/bin/ha-engine --config /etc/ha-engine/config.yaml
WatchdogSec=10s
Restart=always
RestartSec=2s
LimitCORE=infinity

[Install]
WantedBy=multi-user.target
```

---

### 1.3 Ejercicio Guiado: Implementación de Autosanación de Hardware y Automatización de UPS

#### Paso 1: Consultar la Telemetría de Diagnóstico SMART para Unidades SATA y NVMe
Ejecutar consultas detalladas de diagnóstico en los dispositivos de almacenamiento del sistema para verificar el estado de salud y monitorear métricas de falla críticas:

```bash
# Query overall health status of a SATA disk
sudo smartctl -H /dev/sda
```
*Salida Esperada:*
```text
smartctl 7.3 2022-02-28 r5338 [x86_64-linux-5.15.0-100-generic] (local build)
Copyright (C) 2002-22, Bruce Allen, Christian Franke, www.smartmontools.org

=== START OF READ SMART DATA SECTION ===
SMART overall-health self-assessment test result: PASSED
```

```bash
# Extract raw attribute tables focusing on sectors and wear count
sudo smartctl -A /dev/sda | grep -E "Reallocated_Sector|Current_Pending_Sector|Offline_Uncorrectable"
```
*Salida Esperada:*
```text
  5 Reallocated_Sector_Ct   PO--CK   100   100   010    -    0
197 Current_Pending_Sector  -O--CK   100   100   000    -    0
198 Offline_Uncorrectable   ---R--   100   100   000    -    0
```

```bash
# Inspect NVMe specific health log page
sudo smartctl -a /dev/nvme0n1 | grep -E "Critical Warning|Temperature:|Available Spare:|Percentage Used"
```
*Salida Esperada:*
```text
Critical Warning:                   0x00
Temperature:                        34 Celsius
Available Spare:                    100%
Percentage Used:                    2%
```

#### Paso 2: Validar la Comunicación del Demonio NUT UPS
Consultar el servidor `upsd` a través de `upsc` para verificar las métricas del sensor en tiempo real:

```bash
sudo upsc prg-ups-01@localhost ups.status
```
*Salida Esperada:*
```text
OL
```
*(Nota: `OL` = On Line, `OB` = On Battery, `LB` = Low Battery)*

```bash
sudo upsc prg-ups-01@localhost input.voltage battery.charge battery.runtime
```
*Salida Esperada:*
```text
input.voltage: 231.4
battery.charge: 100
battery.runtime: 2450
```

#### Paso 3: Probar la Ejecución del Watchdog del Servicio systemd
Simular un bloqueo en el main event-loop de un proceso monitoreado por watchdog utilizando suspensión por señal (`SIGSTOP`):

```bash
# Start the critical HA daemon and verify its active status
sudo systemctl restart ha-core-engine.service
sudo systemctl status ha-core-engine.service | grep -E "Active:|Main PID"
```
*Salida Esperada:*
```text
   Active: active (running) since Thu 2026-08-06 14:10:00 UTC; 4s ago
 Main PID: 4892 (ha-engine)
```

```bash
# Freeze the process using SIGSTOP to block sd_notify keepalives
sudo kill -STOP 4892

# Monitor system journal logs in real-time to watch systemd catch the watchdog timeout
sudo journalctl -u ha-core-engine.service -f
```
*Salida Esperada:*
```text
Aug 06 14:10:14 node-01 systemd[1]: ha-core-engine.service: Watchdog timeout (limit 10s)!
Aug 06 14:10:14 node-01 systemd[1]: ha-core-engine.service: Killing process 4892 (ha-engine) with signal SIGABRT.
Aug 06 14:10:15 node-01 systemd[1]: ha-core-engine.service: Main process exited, code=killed, status=6/ABRT
Aug 06 14:10:17 node-01 systemd[1]: ha-core-engine.service: Scheduled restart job, restart counter is at 1.
Aug 06 14:10:17 node-01 systemd[1]: ha-core-engine.service: Started Production Critical HA Engine.
```

---

### 1.4 Preguntas de Verificación

1. **Pregunta 1.1:** En una configuración de NUT con hosts primario/secundarios (`master`/`slave`) alimentados por un solo UPS, ¿qué mecanismo evita que el nodo primario apague el hardware del UPS antes de que los hosts secundarios hayan desmontado completamente sus sistemas de archivos root?
2. **Pregunta 1.2:** Un administrador de sistemas configura `WatchdogSec=10s` en un archivo de unidad, pero el desarrollador de la aplicación implementa un intervalo de heartbeat de `sd_notify("WATCHDOG=1")` de 9.5 segundos dentro del código de la aplicación. ¿Por qué este servicio experimentará reinicios periódicos inesperados bajo una alta utilización de CPU?

---

## Módulo 2: RAID por Software Avanzado y Redundancia de Almacenamiento LVM

### 2.1 Arquitectura Técnica Profunda y Mecánica

#### Mecánica de RAID `mdadm` y Write-Intent Bitmaps
El driver de RAID por software `md` (Multiple Devices) del kernel de Linux opera a nivel de bloques.
* **Metadata Superblocks (v1.2):** Ubicados a 4KiB del inicio del dispositivo de arreglo. Contienen el UUID del arreglo, índices de los dispositivos componentes, números de generación y mapas de estado de los discos.
* **Write-Intent Bitmap (`--bitmap=internal`):** Al escribir en un arreglo degradado o durante apagados repentinos, actualizar cada bloque requiere una resincronización completa del arreglo. Un write-intent bitmap interno divide el arreglo en regiones de chunks y establece un solo bit para las regiones sucias. Al recuperarse, `md` escanea únicamente los chunks sucios del bitmap, reduciendo el tiempo de recuperación de horas a segundos.
* **Scrubbing (`sync_action`):** La verificación programada en segundo plano lee bloques en todas las unidades de paridad, recalculando los checksums para detectar y reparar la corrupción silenciosa de bloques ("bit rot").

```
+-------------------------------------------------------------------------------+
|                             /dev/md0 (RAID-1 / RAID-5)                        |
+-------------------------------------------------------------------------------+
| Superblock v1.2 | Write-Intent Bitmap (Dirty Chunk Tracker) | Data / Parity   |
+-----------------+------------------------------------------+------------------+
         |                             |                               |
         v                             v                               v
+-----------------+           +-------------------+           +-----------------+
| /dev/sdb1 (Active)|         | /dev/sdc1 (Active)|           | /dev/sdd1 (Spare|
+-----------------+           +-------------------+           +-----------------+
```

#### Mirroring Avanzado de LVM2 y Auto-Extensión Dinámica de Thin-Pool
LVM2 abstrae estructuras de `mdadm` o de `devmapper` directo en Volume Groups (VG) y Logical Volumes (LV).
* **LVM RAID (`--type raid1` / `--type raid5`):** Utiliza los módulos `md` del kernel de forma nativa en lugar de los targets `mirror` heredados. Proporciona rastreo de metadatos sub-LV (`lv_rmeta`) junto con el rastreo de datos (`lv_rdata`).
* **Infraestructura de `dmeventd`:** El demonio de eventos de Device Mapper monitorea los thin pools y los cambios de estado de RAID. Cuando la utilización del thin pool supera el `snapshot_autoextend_threshold`, `dmeventd` ejecuta automáticamente `lvextend` en función de `snapshot_autoextend_percent`, evitando bloqueos por escritura completa en el thin pool.

---

### 2.2 Archivos de Configuración y Manifests de Producción

#### `/etc/mdadm/mdadm.conf`
```conf
# Production mdadm layout configuration
HOMEHOST <system>
MAILADDR sre-storage-alerts@infrastructure.internal
AUTO +100
ARRAY /dev/md/data0 metadata=1.2 bitmap=internal UUID=4c88a8f1:b122904a:e900c31a:df90211a
```

#### `/etc/lvm/lvm.conf` (Extracto de Auto-Extensión de Thin-Pool y Monitoreo)
```ini
activation {
    thin_pool_autoextend_threshold = 80
    thin_pool_autoextend_percent = 20
    snapshot_autoextend_threshold = 80
    snapshot_autoextend_percent = 20
    monitoring = 1
}
```

---

### 2.3 Ejercicio Guiado: Gestión de la Recuperación ante Fallas de RAID y Auto-Resiliencia de LVM

#### Paso 1: Crear un Arreglo RAID-5 con Write-Intent Bitmap
Inicializar un arreglo RAID-5 de 3 discos con un write-intent bitmap interno explícito usando `mdadm`:

```bash
# Create the array /dev/md0 using loopback devices or spare partitions
sudo mdadm --create /dev/md0 --level=5 --raid-devices=3 /dev/sdb /dev/sdc /dev/sdd --bitmap=internal
```
*Salida Esperada:*
```text
mdadm: Defaulting to version 1.2 metadata
mdadm: array /dev/md0 started.
```

```bash
# Verify detail output, superblock, and active bitmap state
sudo mdadm --detail /dev/md0
```
*Salida Esperada:*
```text
/dev/md0:
           Version : 1.2
     Creation Time : Thu Aug  6 14:20:00 2026
        Raid Level : raid5
        Array Size : 20951040 (19.98 GiB 21.45 GB)
     Used Dev Size : 10475520 (9.99 GiB 10.73 GB)
      Raid Devices : 3
     Total Devices : 3
       Persistence : Superblock is present

     Intent Bitmap : Internal
       State : clean 
 Active Devices : 3
Working Devices : 3
 Failed Devices : 0
  Spare Devices : 0

         Layout : left-symmetric
     Chunk Size : 512K

           Consistency Policy : bitmap

           Name : node-01:0  (local to host node-01)
           UUID : 4c88a8f1:b122904a:e900c31a:df90211a
         Events : 18

    Number   Major   Minor   RaidDevice State
       0       8       16        0      active sync   /dev/sdb
       1       8       32        1      active sync   /dev/sdc
       2       8       48        2      active sync   /dev/sdd
```

#### Paso 2: Inyectar Falla de Disco, Monitorear la Degradación del Arreglo y Reconstruir
Simular una falla de hardware en `/dev/sdc`, extraer en caliente (hot-remove) el dispositivo fallido y agregar un dispositivo de repuesto de reemplazo `/dev/sde`:

```bash
# Mark device as faulty in kernel space
sudo mdadm /dev/md0 --fail /dev/sdc
```
*Salida Esperada:*
```text
mdadm: set /dev/sdc faulty in /dev/md0
```

```bash
# Check degraded status via procfs
cat /proc/mdstat
```
*Salida Esperada:*
```text
Personalities : [raid6] [raid5] [raid4] 
md0 : active raid5 sdd[2] sdc[1](F) sdb[0]
      20951040 blocks super 1.2 level 5, 512k chunk, algorithm 2 [3/2] [U_U]
      bitmap: 1/1 pages [4KB], 65536KB chunk
```

```bash
# Hot-remove failed drive and add new spare drive /dev/sde
sudo mdadm /dev/md0 --remove /dev/sdc
sudo mdadm /dev/md0 --add /dev/sde
```
*Salida Esperada:*
```text
mdadm: hot removed /dev/sdc from /dev/md0
mdadm: added /dev/sde to /dev/md0
```

```bash
# Check resynchronization progress
cat /proc/mdstat
```
*Salida Esperada:*
```text
Personalities : [raid6] [raid5] [raid4] 
md0 : active raid5 sde[3] sdd[2] sdb[0]
      20951040 blocks super 1.2 level 5, 512k chunk, algorithm 2 [3/2] [U_U]
      [=>...................]  recovery =  8.4% (882100/10475520) finish=1.8min speed=86421K/sec
      bitmap: 1/1 pages [4KB], 65536KB chunk
```

#### Paso 3: Desplegar un Volumen LVM RAID-1 e Inspeccionar las Propiedades de Salud
Construir un Volume Group redundante en LVM2 y monitorear los atributos de salud de LVM usando `lvs`:

```bash
# Create physical volumes, volume group, and a true LVM RAID1 volume
sudo pvcreate /dev/sdf /dev/sdg
sudo vgcreate vg_production /dev/sdf /dev/sdg
sudo lvcreate --type raid1 -m 1 -L 5G -n lv_app_data vg_production
```
*Salida Esperada:*
```text
  Logical volume "lv_app_data" created.
```

```bash
# Inspect internal RAID sub-LVs and health statuses
sudo lvs -a -o lv_name,vg_name,copy_percent,health_status,lv_layout,stripe_size
```
*Salida Esperada:*
```text
  LV                  VG            Copy%  Health Status Layout     Stripe
  lv_app_data         vg_production 100.00 refresh       raid,sync      0
  [lv_app_data_rimage_0] vg_production                     linear         0
  [lv_app_data_rimage_1] vg_production                     linear         0
  [lv_app_data_rmeta_0]  vg_production                     linear         0
  [lv_app_data_rmeta_1]  vg_production                     linear         0
```

---

### 2.4 Preguntas de Verificación

1. **Pregunta 2.1:** ¿Cuál es el propósito estructural de los subvolúmenes lógicos `[lv_app_data_rmeta_0]` y `[lv_app_data_rmeta_1]` creados automáticamente junto a `lv_app_data` durante la creación de un LVM `--type raid1`?
2. **Pregunta 2.2:** Durante un scrub de un arreglo RAID-5 `mdadm` (`echo check > /sys/block/md0/md/sync_action`), el kernel encuentra un error de lectura en el disco 0 mientras recalcula la paridad para el offset de bloque X. El disco 1 y el disco 2 leen correctamente. ¿Cómo maneja el driver `md` del kernel el offset de bloque X para evitar la pérdida de datos?

---

## Módulo 3: Multipath I/O de Almacenamiento (`multipathd`)

### 3.1 Arquitectura Técnica Profunda y Mecánica

#### Arquitectura Principal de Device-Mapper Multipath
En redes de área de almacenamiento (SAN) que utilizan Fibre Channel (FC) o iSCSI, un único LUN se expone a través de múltiples adaptadores de bus de host (HBAs) y switches SAN. Esto presenta múltiples rutas de dispositivos de bloques sin formato (raw block devices, por ejemplo, `/dev/sdb`, `/dev/sdc`, `/dev/sdd`, `/dev/sde`) que apuntan al mismo LUN físico subyacente.

`multipathd` utiliza el framework Device-Mapper de Linux para agregar rutas individuales en un dispositivo de bloques unificado (`/dev/mapper/mpathX` o `/dev/dm-N`).

```
+-----------------------------------------------------------------------------------+
|                        /dev/mapper/mpatha (Virtual Device)                        |
+-----------------------------------------------------------------------------------+
                                         |
                       Device-Mapper Multipath Multiplexer
                                         |
               +-------------------------+-------------------------+
               | Path Group 1 (Active/Preferred)                   | Path Group 2 (Standby)
               | Priority: 50                                      | Priority: 10
               +-------------------------+                         +-------------------------+
               |                         |                         |                         |
               v                         v                         v                         v
       +---------------+         +---------------+         +---------------+         +---------------+
       |   /dev/sdb    |         |   /dev/sdc    |         |   /dev/sdd    |         |   /dev/sde    |
       |  (HBA1->SW1)  |         |  (HBA2->SW1)  |         |  (HBA1->SW2)  |         |  (HBA2->SW2)  |
       +---------------+         +---------------+         +---------------+         +---------------+
               |                         |                         |                         |
               +-------------------------+-------------------------+-------------------------+
                                         |
                                  SAN Storage Target
                               (SCSI ALUA Controller)
```

#### SCSI ALUA (Asymmetric Logical Unit Access)
Las cabinas de almacenamiento modernas implementan SCSI ALUA (estándar SPC-3), definiendo los estados de Target Port Group (TPG):
1. **Active/Optimized:** Grupo de rutas preferido conectado al controlador primario del LUN. Menor latencia.
2. **Active/Non-Optimized:** Ruta directa conectada al controlador secundario. Las operaciones de I/O incurren en penalizaciones por travesía en el bus interno de la cabina.
3. **Standby:** El puerto del controlador está pasivo; no acepta I/O de usuario hasta que ocurra un failover de ruta.
4. **Unavailable:** El puerto está en mantenimiento o desconectado físicamente.

#### Path Checkers y Mecánica de Failover
`multipathd` monitorea continuamente la salud de las rutas mediante path checkers activos:
* **`tur` (Test Unit Ready):** Envía comandos SCSI `TEST UNIT READY` por la ruta del dispositivo de bloques. Rápido y con mínimo overhead.
* **`directio`:** Emite lecturas asincrónicas de I/O directo al sector 0 del dispositivo subyacente.
* **Failover vs Failback:** Cuando fallan todas las rutas del Path Group 1, `multipathd` conmuta el tráfico al Path Group 2 (`failover`). Cuando el Path Group 1 se recupera, `failback immediate` o `failback <segundos>` conmuta automáticamente el tráfico de I/O de regreso a la ruta optimizada.

---

### 3.2 Archivos de Configuración y Manifests de Producción

#### `/etc/multipath.conf`
```conf
defaults {
    user_friendly_names         yes
    find_multipaths             yes
    enable_foreign              ""
    path_grouping_policy        group_by_prio
    path_selector               "service-time 0"
    path_checker                tur
    features                    "1 queue_if_no_path"
    hardware_handler            "1 alua"
    prio                        alua
    failback                    immediate
    rr_weight                   uniform
    no_path_retry               18
    max_fds                     8192
}

blacklist {
    devnode "^(td|hd|vd|xvd|sd[a-a])[0-9]*"
    wwid    "360000000000000000000000000000000"
}

blacklist_exceptions {
    property "(SCSI_IDENT_.*|ID_WWN)"
}

multipaths {
    multipath {
        wwid                    3600a09803830447a4f2b4d6f6835476d
        alias                   mpath_san_db
        path_grouping_policy    group_by_prio
        prio                    alua
        failback                immediate
    }
}

devices {
    device {
        vendor                  "NETAPP"
        product                 "LUN.*"
        path_grouping_policy    group_by_prio
        path_checker            tur
        features                "1 queue_if_no_path"
        hardware_handler        "1 alua"
        prio                    alua
        failback                immediate
    }
}
```

---

### 3.3 Ejercicio Guiado: Inspección de Topología Multipath y Simulación de Fallas de Ruta

#### Paso 1: Consultar la Topología Multipath e Identificar Path Groups
Examinar el mapeo multipath activo, las prioridades de ruta y los estados ALUA de hardware:

```bash
# Print detailed multipath topology
sudo multipath -ll
```
*Salida Esperada:*
```text
mpath_san_db (3600a09803830447a4f2b4d6f6835476d) dm-2 NETAPP,LUN C-Mode
size=500G features='1 queue_if_no_path' hwhandler='1 alua' wp=rw
|-+- policy='service-time 0' prio=50 status=active
| |- 1:0:0:1 sdb 8:16 active ready running
| `- 2:0:0:1 sdc 8:32 active ready running
`-+- policy='service-time 0' prio=10 status=enabled
  |- 1:0:1:1 sdd 8:48 active ready running
  `- 2:0:1:1 sde 8:64 active ready running
```

```bash
# Query multipath daemon client interface for path states
sudo multipathd show paths format "%w %i %d %D %t %T %s"
```
*Salida Esperada:*
```text
uuid                             hcil    dev dev_t dm_st chk_st dev_st
3600a09803830447a4f2b4d6f6835476d 1:0:0:1 sdb 8:16  active ready  running
3600a09803830447a4f2b4d6f6835476d 2:0:0:1 sdc 8:32  active ready  running
3600a09803830447a4f2b4d6f6835476d 1:0:1:1 sdd 8:48  active ready  running
3600a09803830447a4f2b4d6f6835476d 2:0:1:1 sde 8:64  active ready  running
```

#### Paso 2: Inyectar Falla de Ruta Fibre Channel / iSCSI en sysfs
Simular la desconexión de un cable o la deshabilitación del puerto de un switch forzando a offline dispositivos SCSI individuales a través de `sysfs`:

```bash
# Force paths sdb and sdc to offline state
echo "offline" | sudo tee /sys/block/sdb/device/state
echo "offline" | sudo tee /sys/block/sdc/device/state
```
*Salida Esperada:*
```text
offline
```

```bash
# Immediately inspect multipath topology to verify failover to secondary path group
sudo multipath -ll
```
*Salida Esperada:*
```text
mpath_san_db (3600a09803830447a4f2b4d6f6835476d) dm-2 NETAPP,LUN C-Mode
size=500G features='1 queue_if_no_path' hwhandler='1 alua' wp=rw
|-+- policy='service-time 0' prio=0 status=active
| |- 1:0:0:1 sdb 8:16 faulty offline running
| `- 2:0:0:1 sdc 8:32 faulty offline running
`-+- policy='service-time 0' prio=10 status=active
  |- 1:0:1:1 sdd 8:48 active ready   running
  `- 2:0:1:1 sde 8:64 active ready   running
```

#### Paso 3: Restaurar Rutas y Verificar la Ejecución de Failback
Volver a habilitar los estados de los dispositivos SCSI y verificar el failback inmediato al grupo de rutas primario:

```bash
# Restore paths sdb and sdc
echo "running" | sudo tee /sys/block/sdb/device/state
echo "running" | sudo tee /sys/block/sdc/device/state
sudo multipathd reconfigure
```
*Salida Esperada:*
```text
ok
```

```bash
# Confirm primary path group priority 50 is restored to active status
sudo multipath -ll | grep -E "status=|prio="
```
*Salida Esperada:*
```text
|-+- policy='service-time 0' prio=50 status=active
`-+- policy='service-time 0' prio=10 status=enabled
```

---

### 3.4 Preguntas de Verificación

1. **Pregunta 3.1:** ¿Cuál es el riesgo crítico de configurar `features "0"` (eliminando `queue_if_no_path`) en un dispositivo multipath en producción que alberga una partición de base de datos activa cuando todas las rutas de almacenamiento se desconectan momentáneamente durante 5 segundos?
2. **Pregunta 3.2:** Contraste el algoritmo de `path_selector` `"round-robin 0"` con `"service-time 0"`. ¿Por qué se prefiere `"service-time 0"` en entornos SAN heterogéneos modernos?

---

## Módulo 4: Network Interface Bonding y Agregación de Enlaces (Link Aggregation)

### 4.1 Arquitectura Técnica Profunda y Mecánica

#### Arquitectura del Driver Linux Bonding
El módulo `bonding` de Linux presenta un único dispositivo de red virtual (`bondX`) compuesto por múltiples tarjetas de interfaz de red físicas (slaves) subyacentes.

```
                      +----------------------------------+
                      |         bond0 Interface          |
                      |   IP: 192.168.10.50/24           |
                      |   MAC: 52:54:00:fa:b1:01         |
                      +----------------------------------+
                                       |
                   Linux Kernel Bonding Multiplexer Engine
                                       |
               +-----------------------+-----------------------+
               | Active Path                                   | Standby Path
               v                                               v
     +-------------------+                           +-------------------+
     |   eth0 (Slave)    |                           |   eth1 (Slave)    |
     | Link: UP (10Gbps) |                           | Link: UP (10Gbps) |
     +-------------------+                           +-------------------+
               |                                               |
               v                                               v
     +-------------------+                           +-------------------+
     | Switch 01 (ToR A) |                           | Switch 02 (ToR B) |
     +-------------------+                           +-------------------+
```

#### Comparativa de Modos de Bonding y Mecánica en Producción

| Modo | Nombre del Modo | Mecánica Clave y Requisitos | ¿Requiere Configuración del Switch? |
| :--- | :--- | :--- | :--- |
| **0** | `balance-rr` | Transmisión de tramas Round-robin entre los slaves activos. Proporciona balanceo de carga y tolerancia a fallas. | Sí (Trunk estático/EtherChannel) |
| **1** | `active-backup` | Solo un slave está activo. Otro slave se activa si el slave activo falla. Dirección MAC única visible en el puerto. | No (Ideal para switches ToR redundantes) |
| **2** | `balance-xor` | Transmite basándose en hash (`[(MAC origen XOR MAC destino) % cantidad de slaves]`). | Sí (Trunk estático) |
| **3** | `broadcast` | Transmite todo en todas las interfaces slave. | Sí |
| **4** | `802.3ad` | Agregación Dinámica de Enlaces (LACP). Crea grupos de agregación que comparten velocidad/duplex. Usa tramas LACPDU. | Sí (Switch configurado con LACP 802.3ad) |
| **5** | `balance-tlb` | Balanceo de carga de transmisión adaptativo. El tráfico saliente se distribuye según la carga actual en cada slave. | No |
| **6** | `balance-alb` | Balanceo de carga adaptativo (incluye balanceo de carga de recepción mediante negociación ARP). | No |

#### Protocolos de Monitoreo de Salud: Monitoreo MII vs ARP
* **Monitoreo MII (`miimon`):** Consulta el registro de la Media Independent Interface (MII) del driver de la NIC para verificar si el estado del enlace portador físico es `UP`. Rápido (por ejemplo, chequeos cada 100ms), pero no puede detectar el aislamiento del puerto del switch aguas arriba ni fallas silenciosas de la señal portadora.
* **Monitoreo ARP (`arp_interval`, `arp_ip_target`):** Transmite consultas ARP periódicas a destinos remotos de gateway IP (`arp_ip_target`). Si las respuestas se detienen, el driver de bonding marca el enlace como muerto. Captura estados de falla de ruteo/switches aguas arriba.

---

### 4.2 Archivos de Configuración y Manifests de Producción

#### `/etc/systemd/network/10-bond0.netdev` (systemd-networkd LACP Modo 4)
```ini
[NetDev]
Name=bond0
Kind=bond

[Bond]
Mode=802.3ad
TransmitHashPolicy=layer3+4
MIIMonitorSec=100ms
UpDelaySec=200ms
DownDelaySec=200ms
LACPTransmitRate=fast
```

#### `/etc/systemd/network/20-bond0-slaves.network`
```ini
[Match]
Name=eth0 eth1

[Network]
Bond=bond0
```

#### `/etc/systemd/network/30-bond0-ip.network`
```ini
[Match]
Name=bond0

[Network]
Address=192.168.10.50/24
Gateway=192.168.10.1
DNS=192.168.10.1
DHCP=no
```

#### Configuración Modprobe Heredada: `/etc/modprobe.d/bonding.conf` (Modo 1 Active-Backup)
```conf
alias bond0 bonding
options bonding mode=1 miimon=100 updelay=200 downdelay=200 primary=eth0 primary_reselect=failure
```

---

### 4.3 Ejercicio Guiado: Despliegue de Bonding y Validación de Failover Dinámico

#### Paso 1: Crear un Bond Active-Backup (`bond0`) a través de Sysfs / iproute2
Construir una interfaz bond active-backup dinámicamente utilizando parámetros de sysfs:

```bash
# Load kernel bonding module
sudo modprobe bonding

# Create bond0 interface and configure mode 1 (active-backup) with MII monitoring
echo "+bond0" | sudo tee /sys/class/net/bonding_masters
echo "active-backup" | sudo tee /sys/class/net/bond0/bonding/mode
echo "100" | sudo tee /sys/class/net/bond0/bonding/miimon
echo "200" | sudo tee /sys/class/net/bond0/bonding/updelay
echo "200" | sudo tee /sys/class/net/bond0/bonding/downdelay
```
*Salida Esperada:*
```text
active-backup
```

```bash
# Enslave interfaces eth0 and eth1 to bond0
sudo ip link set dev eth0 down
sudo ip link set dev eth1 down
echo "+eth0" | sudo tee /sys/class/net/bond0/bonding/slaves
echo "+eth1" | sudo tee /sys/class/net/bond0/bonding/slaves
sudo ip link set dev bond0 up
```
*Salida Esperada:*
```text
+eth0
+eth1
```

#### Paso 2: Inspeccionar el Estado del Bonding del Kernel en Procfs
Inspeccionar `/proc/net/bonding/bond0` para confirmar los estados de los slaves, el estado MII y el slave actualmente activo:

```bash
cat /proc/net/bonding/bond0
```
*Salida Esperada:*
```text
Ethernet Channel Bonding Driver: v5.15.0-100-generic

Bonding Mode: fault-tolerance (active-backup)
Primary Slave: None
Currently Active Slave: eth0
MII Status: up
MII Polling Interval (ms): 100
Up Delay (ms): 200
Down Delay (ms): 200
Peer Notification Delay (ms): 0

Slave Interface: eth0
MII Status: up
Speed: 10000 Mbps
Duplex: full
Link Failure Count: 0
Permanent HW addr: 52:54:00:fa:b1:01
Slave queue ID: 0

Slave Interface: eth1
MII Status: up
Speed: 10000 Mbps
Duplex: full
Link Failure Count: 0
Permanent HW addr: 52:54:00:fa:b1:02
Slave queue ID: 0
```

#### Paso 3: Inyectar Falla en la Interfaz Física y Monitorear la Ejecución del Failover
Simular la desconexión de un cable en la interfaz activa `eth0` mientras se ejecuta una prueba continua de ping:

```bash
# Start background ICMP monitor (or run in separate terminal)
ping -I bond0 192.168.10.1 -i 0.2 &
PING_PID=$!

# Disable eth0 interface link
sudo ip link set dev eth0 down
```
*Salida Esperada:*
```text
64 bytes from 192.168.10.1: icmp_seq=1 ttl=64 time=0.312 ms
64 bytes from 192.168.10.1: icmp_seq=2 ttl=64 time=0.298 ms
64 bytes from 192.168.10.1: icmp_seq=3 ttl=64 time=0.341 ms
# [eth0 downed here - link failure detected by miimon]
64 bytes from 192.168.10.1: icmp_seq=4 ttl=64 time=1.42 ms  <-- Packet sustained during failover
64 bytes from 192.168.10.1: icmp_seq=5 ttl=64 time=0.305 ms
```

```bash
# Re-examine procfs bonding state to confirm switchover to eth1
cat /proc/net/bonding/bond0 | grep -E "Currently Active Slave|Link Failure Count"
```
*Salida Esperada:*
```text
Currently Active Slave: eth1
Link Failure Count: 1
Link Failure Count: 0
```

```bash
# Cleanup ping background job
kill $PING_PID
```

---

### 4.4 Preguntas de Verificación

1. **Pregunta 4.1:** ¿Por qué `xmit_hash_policy=layer2` es insuficiente para el balanceo de carga de flujos TCP salientes a través de un bond LACP Modo 4 (`802.3ad`) cuando todas las conexiones cliente se rutean a través de un único router empresarial aguas arriba?
2. **Pregunta 4.2:** Explique el impacto operativo de configurar `primary_reselect=failure` frente a `primary_reselect=always` en un bond active-backup con `primary=eth0` cuando `eth0` se recupera de una intermitencia (flap-recovery) tras una breve desconexión de cable.

---

<details>
<summary>Respuestas y Explicaciones Técnicas Profundas</summary>

### Respuestas del Módulo 1

* **Respuesta 1.1:** NUT confía en el bucle de dependencia master/slave de `upsmon` junto con el mecanismo del archivo flag `/etc/killpower`. Durante un evento de energía (`OB LB` - On Battery, Low Battery), el demonio master de NUT emite una señal de apagado a todos los slaves de NUT (`upsmon secondary`). El master espera a que los hosts secundarios completen las desconexiones de red (temporizador `HOSTSYNC`). Una vez que todas las conexiones secundarias caen o expira su tiempo de espera, `upsmon` en el nodo primario crea `/etc/killpower`, monta root en modo de solo lectura e invoca `upsdrvctl shutdown`. Esto le indica al hardware UPS que retrase su temporizador de apagado (por ejemplo, 30 segundos), permitiendo que el nodo primario desmonte los sistemas de archivos de forma segura antes de que cese por completo la salida de corriente alterna (AC).

* **Respuesta 1.2:** La aplicación fallará bajo una alta carga de CPU debido al jitter de planificación (scheduling jitter) y a la latencia de colas. Cuando se configura `WatchdogSec=10s` en `systemd`, `systemd` espera un ping al menos una vez cada 10 segundos. Sin embargo, establecer el intervalo de ping en 9.5 segundos deja un margen estrecho de solo 0.5 segundos. Si la CPU experimenta contención de hilos, retrasos en el cambio de contexto de procesos o pausas en el recolector de basura (garbage collection), el hilo de la aplicación que envía `sd_notify("WATCHDOG=1")` perderá la ventana de 10 segundos. `systemd` marcará el proceso como sin respuesta, enviará `SIGABRT` y finalizará el servicio. Las mejores prácticas de SRE dictan configurar el intervalo de `sd_notify` en $\le \frac{1}{2} \times \text{WatchdogSec}$ (por ejemplo, enviando heartbeats cada 3–4 segundos para una ventana de watchdog de 10 segundos).

---

### Respuestas del Módulo 2

* **Respuesta 2.1:** En LVM RAID (`--type raid1`), los subvolúmenes lógicos `_rmeta` almacenan metadatos para cada miembro del arreglo, a diferencia de las imágenes de datos (`_rimage`). Las estructuras `_rmeta` contienen el estado del superblock, los write-intent bitmaps y los mapas de asignación de dispositivos para el motor de RAID `md` del kernel subyacente. Separar los metadatos en `_rmeta` permite el journaling independiente de metadatos, una resincronización rápida de bloques desincronizados (`Copy%`) y un rastreo de estado automatizado mediante `dmeventd`.

* **Respuesta 2.2:** Cuando ocurre un error de lectura en el Disco 0 durante un scrub programado del arreglo en segundo plano, el driver `md` del kernel atrapa el error de I/O (`EIO`). Dado que RAID-5 mantiene paridad a nivel de bloques a través de las unidades restantes, `md` lee los bloques correspondientes del Disco 1 y del Disco 2, recalcula la carga útil (payload) original del bloque fallido en el Disco 0 mediante un cálculo XOR e intenta escribir inmediatamente la carga útil recalculada de nuevo en el Disco 0 en el offset X.
  * Si la escritura tiene éxito, el controlador interno de la unidad de disco reubica el sector defectuoso de forma transparente (incrementando `Reallocated_Sector_Ct`).
  * Si la escritura falla, `md` marca el Disco 0 como fallido, lo elimina del arreglo, incrementa el conteo de dispositivos fallidos y alerta a `mdadm`.

---

### Respuestas del Módulo 3

* **Respuesta 3.1:** Configurar `features "0"` elimina la opción `queue_if_no_path`. Cuando caen todas las rutas de almacenamiento (incluso momentáneamente durante 5 segundos durante el reinicio de un switch SAN o un evento de failover), Device-Mapper no puede encolar las solicitudes de I/O. En su lugar, devuelve inmediatamente errores de lectura/escritura de I/O (`EIO`) a la capa del sistema de archivos. Un motor de base de datos activo que encuentre un `EIO` en sus archivos de registro de transacciones o en los dispositivos de bloques de tablespace cambiará instantáneamente su sistema de archivos a solo lectura (`errors=remount-ro`) o abortará el proceso mediante `panic()`, causando una caída no planificada del servicio. `queue_if_no_path` fuerza a que las solicitudes de I/O se encolen en memoria hasta que ocurra la recuperación de la ruta o expiren los intentos de `no_path_retry`.

* **Respuesta 3.2:** 
  * `"round-robin 0"` distribuye las solicitudes de I/O de manera estrictamente secuencial a través de todas las rutas activas disponibles en un grupo de rutas, sin importar la utilización de la ruta, la latencia o la profundidad de la cola. Si una ruta SAN viaja a través de un HBA de 4Gbps congestionado mientras que otra viaja a través de un HBA de 16Gbps desocupado, round-robin enruta una cantidad igual de tramas a ambas, lo que genera un cuello de botella de I/O en la ruta más lenta.
  * `"service-time 0"` selecciona dinámicamente la ruta para la siguiente instrucción de I/O evaluando tanto la prioridad de la ruta como el volumen total de I/O pendiente en tránsito (bytes in flight). Las rutas que procesan transacciones más rápido reciben una proporción mayor de la tasa de transferencia de I/O, optimizando el rendimiento del almacenamiento en entornos SAN heterogéneos modernos.

---

### Respuestas del Módulo 4

* **Respuesta 4.1:** `xmit_hash_policy=layer2` aplica un hash a los encabezados de las tramas utilizando únicamente las direcciones MAC de Origen y MAC de Destino ($MAC_{src} \oplus MAC_{dest}$). Cuando el tráfico se enruta a través de un gateway router predeterminado aguas arriba, la dirección MAC de Destino para todas las tramas salientes destinadas a subredes externas se resuelve en la dirección MAC de la interfaz del router. Debido a que la MAC del servidor ($MAC_{src}$) y la MAC del router ($MAC_{dest}$) se mantienen constantes en todas las conexiones cliente, la salida del hash da exactamente el mismo índice numérico. Por consiguiente, el 100% del tráfico TCP saliente se mapea a una sola interfaz slave física en el bond, neutralizando las ganancias de balanceo de carga de LACP. Configurar `xmit_hash_policy=layer3+4` aplica el hash a las direcciones IP y puertos TCP/UDP ($IP_{src} \oplus IP_{dest} \oplus Port_{src} \oplus Port_{dest}$), distribuyendo los flujos de tráfico equitativamente entre todos los slaves activos de la agregación de enlaces.

* **Respuesta 4.2:**
  * `primary_reselect=always` fuerza al driver de bonding a conmutar inmediatamente el tráfico activo de regreso a `eth0` tan pronto como `eth0` recupera el estado de la señal portadora del enlace (`MII UP`). Si `eth0` sufre de una degradación física intermitente del enlace ("link flapping"), configurar `always` causa interrupciones repetidas de failover de la interfaz, lo que desencadena pérdida de paquetes de red y re-aprendizaje constante de direcciones MAC en los switches ToR.
  * `primary_reselect=failure` le indica al driver de bonding que mantenga el tráfico en el slave de respaldo que está funcionando actualmente (`eth1`) incluso después de que `eth0` se recupere. `eth0` pasa a un estado de reserva pasivo (standby) y solo se activará de nuevo si `eth1` falla por completo. Esta política evita la inestabilidad por link flapping y garantiza la estabilidad de la red.

</details>