# LPIC-2 (Examen 201-450 v4.5) — Tema 204 / 1.5: Administración Avanzada de Dispositivos de Almacenamiento

---

## 1. Motivación y Contexto de Arquitectura Empresarial

En la infraestructura empresarial moderna y las operaciones de SRE, las arquitecturas de almacenamiento deben ofrecer cuatro garantías no negociables: **alta disponibilidad (HA)**, **predictibilidad horizontal**, **mantenimiento sin tiempo de inactividad (zero-downtime)** y **resiliencia contra la degradación del hardware**. 

El almacenamiento de acceso directo (Direct-Attached Storage, DAS) que opera sin rutas redundantes ni abstracción lógica crea puntos únicos de fallo (SPOF) y límites rígidos de E/S (IO). Las arquitecturas de almacenamiento en Linux empresarial desacoplan el hardware de almacenamiento físico de las abstracciones lógicas del sistema operativo mediante una pila de almacenamiento en capas:

```
+-----------------------------------------------------------------------+
|                       Filesystem Layer (ext4, xfs)                    |
+-----------------------------------------------------------------------+
|                    Logical Volume Manager (LVM2)                      |
|            [ Logical Volumes (LV) / Thin Pools / Snapshots ]          |
+-----------------------------------------------------------------------+
|                 Device-Mapper Multipathing (DM-Multipath)             |
|                 [ Active/Active or Active/Passive Failover ]          |
+-----------------------------------------------------------------------+
|                     Block Layer & I/O Schedulers                      |
|                  [ mq-deadline / kyber / bfq / none ]                 |
+-----------------------------------------------------------------------+
|                   Storage Network / Controller Layer                  |
|               [ iSCSI Initiator / Software RAID (mdadm) ]             |
+-----------------------------------------------------------------------+
|                     Physical Hardware / Fabric Path                   |
|                   [ NVMe / SAS / iSCSI Target / SAN LUNs ]            |
+-----------------------------------------------------------------------+
```

### El Espacio de Problemas del Almacenamiento Empresarial
1. **Fallo de Controlador y Medio Físico**: Los discos duros y SSD sufren de errores de lectura irrecuperables (URE), errores latentes de sector y bloqueos del controlador. El RAID por software (`mdadm`) proporciona redundancia programática a nivel de bloque sin el bloqueo de proveedor (vendor lock-in) asociado con los controladores RAID de hardware propietarios.
2. **Disponibilidad de Ruta y Resiliencia SAN**: En las redes de área de almacenamiento (SAN) que utilizan iSCSI o Fibre Channel, el fallo de un conmutador de red o la interrupción de un puerto de adaptador de bus de host (HBA) rompe la conectividad del almacenamiento de bloques. El multipath mediante Device-Mapper (`dm-multipath`) proporciona agregación transparente de rutas, balanceo de carga y conmutación por error (failover) a través de distintas infraestructuras (fabrics) de almacenamiento.
3. **Dinámica de Asignación de Capacidad**: El particionado estático fuerza el reparticionado fuera de línea cuando la demanda del volumen supera los límites iniciales. Logical Volume Manager (`LVM2`) permite la expansión en línea, la creación de snapshots para respaldos de estado en un punto en el tiempo (point-in-time), thin provisioning para modelos de sobreasignación (over-commit) y la migración de datos en vivo (`pvmove`) sin desmontar los sistemas de archivos.
4. **Congestión de E/S del Kernel**: Los dispositivos de bloque modernos NVMe y de cola múltiple (Multi-Queue, `blk-mq`) pueden procesar cientos de miles de Operaciones de Entrada/Salida Por Segundo (IOPS). Una profundidad de cola de bloques mal configurada, planificadores de E/S (I/O schedulers) incorrectos o valores inadecuados de readahead saturan los núcleos de CPU del sistema con la gestión de interrupciones y degradan las latencias de las transacciones de bases de datos.

---

## 2. Comparativas Técnicas y Tablas de Compromisos Arquitectónicos

### Matriz 1: Topologías de Almacenamiento Redundante (Software RAID vs. Hardware RAID vs. ZFS/Btrfs)

| Característica / Métrica | Software RAID (`mdadm`) | Controlador RAID de Hardware | ZFS / Btrfs (Almacenamiento CoW) |
| :--- | :--- | :--- | :--- |
| **Capa de Control** | Kernel de Linux (controlador `md`) | ASIC/PICA dedicado en tarjeta | Kernel / Módulo C de ZFS |
| **Portabilidad de Hardware** | **Alta**: Los arreglos se ensamblan en cualquier kernel de Linux | **Baja**: Requiere vendedor/firmware de controlador idéntico | **Alta**: Importación del pool en cualquier SO compatible con ZFS/Btrfs |
| **Protección de Write Hole** | Requiere Write-Intent Bitmap o PPL (Post-Log) | NVRAM de hardware con unidad respaldada por batería (BBU) | Garantizado mediante el diseño Copy-on-Write (CoW) |
| **Depuración de Datos / Integridad** | Lectura de patrullaje (patrol read) vía Sysfs (acción `check`) | Patrullaje en segundo plano del controlador | Verificación de checksum de extremo a extremo (sha256/fletcher4) |
| **Sobrecarga de Memoria / CPU** | Baja a moderada (calcula la paridad en RAM) | Cero sobrecarga de CPU (delegado al controlador) | Alta (la caché ARC y el cálculo de checksum demandan RAM) |
| **Latencia de Recuperación** | Límites de velocidad configurables mediante sysctl | Fijo según la prioridad de reconstrucción del controlador | Rápida (reconstruye solo los datos asignados, no bloques vacíos) |

---

### Matriz 2: Protocolos de Transporte de Almacenamiento de Bloques

| Protocolo | Capa de Transporte | Sobrecarga | Latencia Típica | Capacidades de Enrutamiento | Entorno Objetivo |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **iSCSI** | TCP/IP (Puerto 3260) | Moderada (Entramado Ethernet + IP + TCP + iSCSI) | 1–5 ms | Totalmente enrutable a través de redes estándar L2/L3 | Centros de datos empresariales generales e hipervisores KVM |
| **Fibre Channel (FC)** | Entramado FC dedicado | Mínima (Descarga por hardware en HBA) | < 0.5 ms | Fabric conmutado de FC aislado | OLTP de alto rendimiento y entornos SAN heredados |
| **NVMe-oF (RDMA/TCP)** | RoCE v2 / NVMe-TCP | Extremadamente baja | < 100 µs | Enrutable (NVMe-TCP) o Ethernet convergente L2 | Supercomputación, comercio de alta frecuencia (HFT) e IA/ML |

---

### Matriz 3: Modelos de Asignación de Almacenamiento en LVM

| Atributo Arquitectónico | LVM con Provisionamiento Denso (Thick) (`lvcreate -L`) | LVM con Provisionamiento Ligero (Thin) (`lvcreate -V -T`) | Dispositivo de Bloques en Bruto (Raw) Directo |
| :--- | :--- | :--- | :--- |
| **Asignación de Almacenamiento** | Asignado completamente por adelantado | Asignado dinámicamente al escribir | Asignado completamente por adelantado |
| **Capacidad de Sobreasignación (Over-commit)** | No soportado | Soportado (Sobresuscripción en Thin Pool) | No soportado |
| **Sobrecarga de Rendimiento** | Cero sobrecarga | Sobrecarga menor de asignación de escritura de metadatos | La latencia absoluta más baja |
| **Eficiencia de Snapshots** | Copy-on-Write (degrada el rendimiento con el tiempo) | Redirect-on-Write (solo actualización de punteros, O(1) constante) | N/A (Requiere herramientas a nivel de archivo) |
| **Riesgo Operativo** | Bajo (Imposible quedarse sin espacio si el VG tiene espacio) | Alto (El agotamiento del pool congela todos los LV constituyentes) | Bajo |

---

### Matriz 4: Planificadores de E/S de la Capa de Bloques Multi-Cola (`blk-mq`)

| Planificador | Caso de Uso Principal | Mecanismo de Encolado | Perfil de Latencia | Mejor Coincidencia de Hardware |
| :--- | :--- | :--- | :--- | :--- |
| **`none`** | Arreglos de hardware de alto rendimiento | Paso directo (passthrough) a la cola de hardware del controlador | La sobrecarga de CPU más baja | Unidades NVMe de alta gama y LUNs SAN de hardware |
| **`mq-deadline`** | Cargas de trabajo generales con lectura intensiva | Colas separadas de límite (deadline) de Lectura/Escritura (prioridad a la lectura) | Garantiza límites máximos de latencia de lectura | SSDs SATA/SAS empresariales |
| **`kyber`** | Aplicaciones multiquilante (multi-tenant) sensibles a la latencia | Colas de latencia de solicitudes síncronas/lectura objetivo | Limites estrictos de latencia p99 | Pools NVMe rápidos bajo cargas pesadas de escritura concurrente |
| **`bfq` (Budget Fair Queueing)** | Cargas de trabajo de escritorio / interactivas | Presupuesto de ancho de banda por proceso | Alta equidad, mayor sobrecarga de CPU | HDDs mecánicos rotacionales (SATA/SAS) |

---

## 3. Configuraciones de Infraestructura de Producción y Manifiestos Sintácticamente Válidos

### 3.1 Archivo de Configuración de Software RAID (`/etc/mdadm.conf`)

Esta configuración registra un arreglo RAID-5 explícito con registro de metadatos write-intent, nombres de nodos de dispositivos personalizados y ganchos (hooks) automatizados de alertas por correo electrónico para estados degradados.

```ini
# /etc/mdadm.conf - Production Software RAID Configuration
# Reference: mdadm.conf(5)

# Device scanning directive to limit discovery to physical enterprise SAS/SATA nodes
DEVICE /dev/sd[b-e]1

# Global Mail configuration for daemon alerts
MAILADDR sre-storage-alerts@infrastructure.internal
MAILFROM mdadm-daemon@node01.infrastructure.internal
PROGRAM /usr/lib/mdadm/send-spares-handler

# Array Definitions
# ARRAY <device-node> metadata=<version> UUID=<unique-id> name=<host:alias>
ARRAY /dev/md/data_raid5 metadata=1.2 UUID=a8f4c21b:991e48ba:c810d4ff:7a1102e5 name=node01:data_raid5
   spares=1
```

---

### 3.2 Script de Configuración de Exportación de iSCSI Target (`targetcli`)

Script de automatización en Python/CLI sintácticamente válido para `targetcli` para crear un iSCSI Target (servidor SAN) que presenta un dispositivo de bloques con autenticación CHAP.

```bash
#!/usr/bin/env bash
set -euo pipefail

# Provision iSCSI Target using targetcli commands non-interactively
targetcli /backstores/block create name=san_storage_block dev=/dev/vg_san/lv_san_data
targetcli /iscsi create iqn.2026-08.internal.infrastructure:storage.target01
targetcli /iscsi/iqn.2026-08.internal.infrastructure:storage.target01/tpg1/luns create /backstores/block/san_storage_block

# Enable CHAP Authentication
targetcli /iscsi/iqn.2026-08.internal.infrastructure:storage.target01/tpg1 set attribute authentication=1
targetcli /iscsi/iqn.2026-08.internal.infrastructure:storage.target01/tpg1 set auth userid=TargetUserSecret
targetcli /iscsi/iqn.2026-08.internal.infrastructure:storage.target01/tpg1 set auth password=TargetPasswordSecret123

# Create Access Control List (ACL) for the Initiator Node
targetcli /iscsi/iqn.2026-08.internal.infrastructure:storage.target01/tpg1/acls create iqn.2026-08.internal.infrastructure:node01.initiator
targetcli /iscsi/iqn.2026-08.internal.infrastructure:storage.target01/tpg1/acls/iqn.2026-08.internal.infrastructure:node01.initiator set auth userid=InitiatorUserSecret
targetcli /iscsi/iqn.2026-08.internal.infrastructure:storage.target01/tpg1/acls/iqn.2026-08.internal.infrastructure:node01.initiator set auth password=InitiatorPasswordSecret123

# Bind portal to all local IPv4 interfaces on default port 3260
targetcli /iscsi/iqn.2026-08.internal.infrastructure:storage.target01/tpg1/portals create 0.0.0.0 3260

# Save configuration persistently to /etc/rtslib-fb-target/saveconfig.json
targetcli saveconfig
```

---

### 3.3 Configuraciones de iSCSI Initiator

#### Definición del Nombre del Initiator (`/etc/iscsi/initiatorname.iscsi`)
```ini
## /etc/iscsi/initiatorname.iscsi
## Uniquely identifies this initiator host to iSCSI Targets
InitiatorName=iqn.2026-08.internal.infrastructure:node01.initiator
```

#### Configuración del Demonio Open-iSCSI (`/etc/iscsi/iscsid.conf`)
```ini
# /etc/iscsi/iscsid.conf - Production Initiator Configuration
# Reference: iscsid.conf(5)

iscsid.startup = /sbin/iscsid

# Automatic login on system boot
node.startup = automatic

# CHAP Authentication settings for Node sessions
node.session.auth.authmethod = CHAP
node.session.auth.username = TargetUserSecret
node.session.auth.password = TargetPasswordSecret123
node.session.auth.username_in = InitiatorUserSecret
node.session.auth.password_in = InitiatorPasswordSecret123

# Timeout & Retries for Network Stability Tuning
node.session.timeo.replacement_timeout = 120
node.conn[0].timeo.login_timeout = 15
node.conn[0].timeo.logout_timeout = 15
node.conn[0].timeo.noop_out_interval = 5
node.conn[0].timeo.noop_out_timeout = 5
node.session.iscsi.FastAbort = Yes
```

---

### 3.4 Configuración de Device Mapper Multipath (`/etc/multipath.conf`)

Esta configuración gestiona el descubrimiento dinámico de rutas, la priorización de estados ALUA (Asymmetric Logical Unit Access) y la conmutación por error (failover) transparente a través de infraestructuras (fabrics) SAN.

```conf
# /etc/multipath.conf - Production DM-Multipath Configuration
# Reference: multipath.conf(5)

defaults {
    user_friendly_names      yes
    find_multipaths          yes
    enable_foreign           "NONE"
    path_grouping_policy     group_by_prio
    path_checker             tur
    features                 "1 queue_if_no_path"
    hardware_handler         "1 alua"
    prio                     alua
    failback                 immediate
    rr_weight                uniform
    no_path_retry            12
    rr_min_io_rq             10
}

blacklist {
    devnode "^(td|hd|vd|xvd|mmcblk)[a-z0-9]*"
    devnode "^sd[a]$"
    wwid    "3600508e0000000000000000000000000"
}

multipaths {
    multipath {
        wwid                    36001405a12cd86b097b47e2a9b3d11b4
        alias                   san_block_vol01
        path_grouping_policy    multibus
        path_checker            tur
        failback                immediate
    }
}

devices {
    device {
        vendor                  "NETAPP"
        product                 "LUN.*"
        path_grouping_policy    group_by_prio
        prio                    alua
        path_checker            tur
        hardware_handler        "1 alua"
        failback                immediate
        no_path_retry           queue
    }
}
```

---

### 3.5 Reglas de Ajuste de Udev y Colas de Almacenamiento (`/etc/udev/rules.d/99-storage-performance.rules`)

Reglas automatizadas que aplican parámetros de cola y planificadores específicos según el tipo de almacenamiento (SSD NVMe vs. SATA rotacional vs. SAN Multipath).

```udev
# /etc/udev/rules.d/99-storage-performance.rules
# Custom kernel block queue parameters for production workloads

# 1. NVMe Solid State Drives: Use 'none' scheduler, disable add_random, increase nr_requests
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]", ATTR{queue/scheduler}="none", ATTR{queue/add_random}="0", ATTR{queue/nr_requests}="1024", ATTR{queue/read_ahead_kb}="2048"

# 2. SAN Multipath Virtual Devices (dm-*): Set scheduler to 'none', optimize request queues
ACTION=="add|change", KERNEL=="dm-[0-9]*", SUBSYSTEM=="block", ATTR{queue/scheduler}="none", ATTR{queue/nr_requests}="512", ATTR{queue/read_ahead_kb}="4096"

# 3. Rotational Mechanical Hard Disks (SATA/SAS): Use 'mq-deadline', enable readahead
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="mq-deadline", ATTR{queue/read_ahead_kb}="1024", ATTR{queue/nr_requests}="256"
```

---

### 3.6 Archivos de Unidad Mount y Automount de Systemd

#### Unidad Mount de Almacenamiento en Red Persistente (`/etc/systemd/system/mnt-san-data.mount`)
```ini
[Unit]
Description=Production Enterprise SAN Storage Mount
Documentation=man:fstab(5) man:systemd.mount(5)
After=network-online.target open-iscsi.service multipathd.service
Wants=network-online.target open-iscsi.service multipathd.service
Requires=open-iscsi.service multipathd.service

[Mount]
What=/dev/mapper/san_block_vol01
Where=/mnt/san-data
Type=xfs
Options=_netdev,noatime,nodiratime,logbufs=8,logbsize=256k,allocsize=64M

[Install]
WantedBy=remote-fs.target
```

#### Unidad Automount a Demanda de Systemd (`/etc/systemd/system/mnt-san-data.automount`)
```ini
[Unit]
Description=Automount for Production SAN Storage
Documentation=man:systemd.automount(5)
After=network-online.target

[Automount]
Where=/mnt/san-data
TimeoutIdleSec=300

[Install]
WantedBy=multi-user.target
```

---

## 4. Ejecución Práctica en CLI y Salidas Reales de Terminal

### 4.1 Operaciones de Software RAID (`mdadm`)

#### Creación de un Arreglo RAID-5 con un Hot Spare Activo
```console
$ sudo mdadm --create /dev/md0 --level=5 --raid-devices=3 --spare-devices=1 /dev/sdb1 /dev/sdc1 /dev/sdd1 /dev/sde1
mdadm: Defaulting to version 1.2 metadata
mdadm: array /dev/md0 started.
```

#### Inspección Detallada del Estado de Salud y Reconstrucción del Arreglo
```console
$ sudo mdadm --detail /dev/md0
/dev/md0:
           Version : 1.2
     Creation Time : Thu Aug  6 10:30:15 2026
        Raid Level : raid5
        Array Size : 41910272 (39.97 GiB 42.92 GB)
     Used Dev Size : 20955136 (19.98 GiB 21.46 GB)
      Raid Devices : 3
     Total Devices : 4
       Persistence : Superblock is present

     Intent Bitmap : Internal active
       State : clean 
Active Devices : 3
Working Devices : 4
Failed Devices : 0
 Spare Devices : 1

        Layout : left-symmetric
    Chunk Size : 512K

Consistency Policy : bitmap

          Name : node01:0  (local to host node01)
          UUID : a8f4c21b:991e48ba:c810d4ff:7a1102e5
        Events : 18

    Number   Major   Minor   RaidDevice State
       0       8       17        0      active sync   /dev/sdb1
       1       8       33        1      active sync   /dev/sdc1
       2       8       49        2      active sync   /dev/sdd1

       3       8       65        -      spare   /dev/sde1
```

#### Simulación de Fallo de Disco, Extracción en Caliente (Hot-Remove) y Activación de Reconstrucción
```console
$ sudo mdadm /dev/md0 --fail /dev/sdc1
mdadm: set /dev/sdc1 faulty in /dev/md0

$ sudo mdadm --detail /dev/md0 | grep -E "(State|Device)"
       State : active, degraded, recovering 
Active Devices : 2
Working Devices : 3
Failed Devices : 1
 Spare Devices : 0
Rebuild Status : 14% complete
    Number   Major   Minor   RaidDevice State
       0       8       17        0      active sync   /dev/sdb1
       3       8       65        1      spare rebuilding   /dev/sde1
       2       8       49        2      active sync   /dev/sdd1
       1       8       33        -      faulty   /dev/sdc1

$ sudo mdadm /dev/md0 --remove /dev/sdc1
mdadm: hot removed /dev/sdc1 from /dev/md0
```

---

### 4.2 Ajuste de Parámetros a Bajo Nivel de Disco y Sistema de Archivos

#### Consulta y Configuración de Parámetros de Hardware (`sdparm` y `hdparm`)
```console
$ sudo hdparm -I /dev/sdb | grep -A 4 "Capabilities"
	Capabilities:
		LBA, Logical Block Addressing Support
		Disabling IORDY permitted
		Queue depth: 32
		Capabilities: Standby timer values spoken here

$ sudo sdparm --get=WCE /dev/sdb
    /dev/sdb: SEAGATE   ST2000NX0253      NT01
WCE           1  [V_mode: 1]

# Enable Write Cache Enable (WCE) persistently on a SCSI/SAS disk
$ sudo sdparm --set=WCE --save /dev/sdb
    /dev/sdb: SEAGATE   ST2000NX0253      NT01
```

#### Ajuste de Atributos del Sistema de Archivos Ext4 (`tune2fs`)
```console
$ sudo tune2fs -m 1 -O fast_commit,journal_data_writeback /dev/mapper/vg_data-lv_production
tune2fs 1.46.5 (30-Dec-2021)
Setting reserved blocks percentage to 1% (104857 blocks)
Filesystem features set 'fast_commit,journal_data_writeback'

$ sudo tune2fs -l /dev/mapper/vg_data-lv_production | grep -i "reserved block count"
Reserved block count:     104857
```

#### Diagnóstico de Cola y Controlador NVMe (`nvme-cli`)
```console
$ sudo nvme list
Node             SN                   Model                                  Namespace Usage                      Format           FW Rev  
---------------- -------------------- -------------------------------------- --------- -------------------------- ---------------- --------
/dev/nvme0n1     S59BNX0R102938       SAMSUNG MZQL21T9HCJR-00A07             1           1.92  TB /   1.92  TB    512   B +  0 B   MPK7301Q

$ sudo nvme smart-log /dev/nvme0n1
Smart Log for NVME device:nvme0n1 namespace-id:ffffffff
critical_warning			: 0
temperature				: 33°C (306 K)
available_reserve			: 100%
percentage_used				: 1%
data_units_read				: 14,892,104 (7.62 TB)
data_units_written			: 42,109,211 (21.56 TB)
host_read_commands			: 189,201,442
host_write_commands			: 512,940,119
controller_busy_time			: 142
power_cycles				: 12
power_on_hours				: 2,410
unsafe_shutdowns			: 1
media_errors				: 0
num_err_log_entries			: 0
```

---

### 4.3 Operaciones Avanzadas de LVM2: Thin Pools y Migración de Datos en Vivo (`pvmove`)

#### Creación de Volúmenes Físicos, Grupo de Volúmenes y Pool de Thin Provisioning
```console
$ sudo pvcreate /dev/sdb1 /dev/sdc1 /dev/sdd1
  Physical volume "/dev/sdb1" successfully created.
  Physical volume "/dev/sdc1" successfully created.
  Physical volume "/dev/sdd1" successfully created.

$ sudo vgcreate -s 4M vg_enterprise /dev/sdb1 /dev/sdc1 /dev/sdd1
  Volume group "vg_enterprise" successfully created

# Create a 50GB Thin Pool and a 200GB Thinly-Provisioned Volume (Over-provisioned)
$ sudo lvcreate -L 50G --thinpool tp_enterprise_pool vg_enterprise
  Thin pool volume with chunk size 64.00 KiB set to "vg_enterprise/tp_enterprise_pool".
  Logical volume "tp_enterprise_pool" created.

$ sudo lvcreate -V 200G --thin -n lv_app_data vg_enterprise/tp_enterprise_pool
  Logical volume "lv_app_data" created.
```

#### Creación de Snapshots de Volúmenes Lógicos Copy-on-Write
```console
$ sudo lvcreate --size 10G --snapshot --name lv_app_data_snap /dev/vg_enterprise/lv_app_data
  Logical volume "lv_app_data_snap" created.

$ sudo lvs vg_enterprise/lv_app_data_snap
  LV                VG            Attr       LSize  Pool Origin      Data%  Meta%  Move Log Cpy%Sync Convert
  lv_app_data_snap  vg_enterprise s-wi-a--- 10.00g      lv_app_data  0.02
```

#### Migración de Disco en Línea y en Vivo (`pvmove`) sin Tiempo de Inactividad
```console
$ sudo pvmove -v /dev/sdb1 /dev/sdd1
  Cluster snapshot status summary: 0 logical volumes configured.
  Moving 5120 extents of logical volume vg_enterprise/tp_enterprise_pool.
  Preparing finished.
  Un-suspending origin volume...
  /dev/sdb1: Moved: 0.00%
  /dev/sdb1: Moved: 24.50%
  /dev/sdb1: Moved: 68.20%
  /dev/sdb1: Moved: 100.00%
  Updated volume group metadata.
```

---

### 4.4 Descubrimiento de iSCSI Target y Gestión de Device-Mapper Multipath

#### Descubrimiento de Target e Inicio de Sesión
```console
$ sudo iscsiadm -m discovery -t sendtargets -p 192.168.10.50:3260
192.168.10.50:3260,1 iqn.2026-08.internal.infrastructure:storage.target01

$ sudo iscsiadm -m node -T iqn.2026-08.internal.infrastructure:storage.target01 -p 192.168.10.50:3260 --login
Logging in to [iface: default, target: iqn.2026-08.internal.infrastructure:storage.target01, portal: 192.168.10.50,3260]
Login to [iface: default, target: iqn.2026-08.internal.infrastructure:storage.target01, portal: 192.168.10.50,3260] successful.
```

#### Inspección de Sesiones iSCSI Activas
```console
$ sudo iscsiadm -m session -P 1
Target: iqn.2026-08.internal.infrastructure:storage.target01 (node01)
	Current Portal: 192.168.10.50:3260,1
	Persistent Portal: 192.168.10.50:3260,1
		---------- Session State ----------
		State: LOGGED_IN
		Session Target Name: iqn.2026-08.internal.infrastructure:storage.target01
		Credentials: Username: TargetUserSecret
		Attached scsi disk sdf State: Running
```

#### Verificación de la Topología de Device-Mapper Multipath (`multipath -ll`)
```console
$ sudo multipath -ll
san_block_vol01 (36001405a12cd86b097b47e2a9b3d11b4) dm-2 NETAPP,LUN C-Mode
size=500G features='1 queue_if_no_path' hwhandler='1 alua' wp=rw
|-+- policy='group-by-prio 0' prio=50 status=active
| |- 2:0:0:0 sdd 8:48 active ready running
| `- 3:0:0:0 sde 8:64 active ready running
`-+- policy='group-by-prio 0' prio=10 status=enabled
  |- 4:0:0:0 sdf 8:80 active ghost retention
  `- 5:0:0:0 sdg 8:96 active ghost retention
```

---

## 5. Guía SRE de Diagnóstico y Recuperación ante Fallos

```
             +--------------------------------------------------+
             |         Storage Failure Event Detected           |
             +--------------------------------------------------+
                                      |
                                      v
             +--------------------------------------------------+
             | Is it a Hardware, Network Path, or Metadata Issue?|
             +--------------------------------------------------+
               /                      |                       \
              /                       |                        \
  [ Hardware Sector / RAID ]     [ Network / iSCSI Path ]     [ LVM Metadata Fault ]
             |                        |                        |
             v                        v                        v
  1. Check dmesg / smartctl   1. Inspect iscsiadm session  1. Locate backup in
  2. Query mdadm status       2. Verify multipath -ll         /etc/lvm/backup/
  3. Replace drive & sync     3. Query dmsetup status      2. Run vgcfgrestore
```

### Escenario 1: Recuperación de un Arreglo Software RAID Degradado

**Síntoma**: El kernel informa errores de E/S; `mdadm` marca la unidad como defectuosa.

1. **Localizar el Componente Fallido**:
   ```console
   $ sudo dmesg -T | grep -E "(sector|I/O error|md0)"
   [Thu Aug  6 10:45:12 2026] sd 2:0:0:1: [sdc] FAILED Result: hostbyte=DID_OK driverbyte=DRIVER_OK
   [Thu Aug  6 10:45:12 2026] sd 2:0:0:1: [sdc] CDB: Read(10) 28 00 00 a1 b2 c0 00 00 08 00
   [Thu Aug  6 10:45:12 2026] blk_update_request: I/O error, dev sdc, sector 10597056 op 0x0:(READ) flags 0x0 phys_seg 1 prio class 0
   [Thu Aug  6 10:45:13 2026] md/raid5:md0: Device /dev/sdc1 failed, disabling device.
   ```

2. **Aislar el Número de Serie del Disco Físico mediante `smartctl`**:
   ```console
   $ sudo smartctl -i /dev/sdc | grep "Serial Number"
   Serial Number:     WCC4M7XU8912
   ```

3. **Reemplazar el Disco Físico y Recrear la Tabla de Particiones**:
   ```console
   # Copy partition layout identically from a working array member (/dev/sdb) to new disk (/dev/sdc)
   $ sudo sfdisk -d /dev/sdb | sudo sfdisk /dev/sdc
   Checking that no-one is using this disk right now ... OK
   Successfully wrote the new partition table
   ```

4. **Agregar en Caliente (Hot-Add) la Nueva Partición de Disco al Arreglo RAID**:
   ```console
   $ sudo mdadm --manage /dev/md0 --add /dev/sdc1
   mdadm: added /dev/sdc1 to /dev/md0
   ```

---

### Escenario 2: Corrupción de Metadatos de LVM2 y Recuperación del Grupo de Volúmenes

**Síntoma**: `vgdisplay` falla con "Volume group not found" o informa encabezados de metadatos no válidos tras sobreescrituras accidentales de bloques.

1. **Localizar el Respaldo Automatizado de Metadatos de LVM**:
   LVM2 mantiene automáticamente un historial de metadatos en texto en `/etc/lvm/backup/` y `/etc/lvm/archive/`.
   ```console
   $ sudo ls -la /etc/lvm/backup/
   total 16
   -rw------- 1 root root 2415 Aug  6 09:12 vg_enterprise
   ```

2. **Inspeccionar los Requisitos de UUID del Volumen Físico**:
   ```console
   $ sudo head -n 25 /etc/lvm/backup/vg_enterprise
   # Generated by LVM2 version 2.03.11(2) (2021-01-08): Thu Aug  6 09:12:00 2026

   contents = "Text Format Volume Group"
   version = 1

   vg_enterprise {
       id = "x8A9k1-M7p2-9011-LKs2-0199-mKls-910293"
       seqno = 4
       format = "lvm2"
       
       physical_volumes {
           pv0 {
               id = "a1b2c3-d4e5-6789-0123-4567-890a-bcdef0"
               device = "/dev/sdb1"
           }
       }
   }
   ```

3. **Restaurar el UUID de Metadatos del Volumen Físico**:
   ```console
   $ sudo pvcreate --uuid "a1b2c3-d4e5-6789-0123-4567-890a-bcdef0" --restorefile /etc/lvm/backup/vg_enterprise /dev/sdb1
   Physical volume "/dev/sdb1" successfully created with UUID a1b2c3-d4e5-6789-0123-4567-890a-bcdef0
   ```

4. **Restaurar la Configuración del Grupo de Volúmenes**:
   ```console
   $ sudo vgcfgrestore -f /etc/lvm/backup/vg_enterprise vg_enterprise
   Restored volume group vg_enterprise.

   $ sudo vgscan && sudo vgchange -ay vg_enterprise
   Found volume group "vg_enterprise" using metadata type lvm2
   1 logical volume(s) in volume group "vg_enterprise" now active
   ```

---

### Escenario 3: Interrupción de la Ruta SAN y Diagnósticos de DM-Multipath

**Síntoma**: Las operaciones de archivo se cuelgan; el kernel informa errores en los dispositivos multipath.

1. **Inspeccionar la Tabla de Device-Mapper de Bajo Nivel**:
   ```console
   $ sudo dmsetup table san_block_vol01
   0 1048576000 multipath 1 queue_if_no_path 1 alua 2 1 group-by-prio 0 2 1 8:48 A 0 8:64 A 0 group-by-prio 0 2 0 8:80 F 0 8:96 F 0
   ```
   *(Nota: `A` indica ruta Activa (Active); `F` indica ruta Fallida (Failed)).*

2. **Verificar el Estado de la Conexión iSCSI para Conexiones Caídas**:
   ```console
   $ sudo iscsiadm -m session -o show | grep -i "Network Failure"
   iSCSI Connection State: LOGGED_OUT (Network Failure Timeout)
   ```

3. **Forzar el Vuelco/Reescaneo de Rutas y la Recarga del Demonio Multipath**:
   ```console
   $ sudo iscsiadm -m node --loginall=all
   $ sudo multipath -r
   $ sudo multipathd show paths format "%n %d %t %T %s"
   dev dev_t target WWNN               status
   sdd 8:48   0x200000a098001122       active
   sde 8:64   0x200000a098001123       active
   ```

---

### Escenario 4: Diagnóstico Profundo de Latencia de E/S en la Cola de Bloques

**Síntoma**: La aplicación experimenta picos altos de latencia de escritura p99; el rendimiento (throughput) de la base de datos colapsa.

1. **Recolectar Métricas en Tiempo Real de la Cola del Dispositivo de Bloques (`iostat`)**:
   ```console
   $ sudo iostat -xz 1 3
   Device            r/s     w/s     rkB/s     wkB/s   rrqm/s  wrqm/s  r_await  w_await aqu-sz  rareq-sz  wareq-sz  %util
   nvme0n1         15.00 4500.00    120.00 288000.00     0.00 1200.00     0.12    18.40   82.80     8.00     64.00  98.40
   sda              0.00    2.00      0.00     16.00     0.00    1.00     0.00     1.50    0.00      0.00      8.00   0.40
   ```
   *(Diagnóstico: un `aqu-sz` (tamaño promedio de cola) de 82.80 combinado con `w_await` > 18 ms indica una acumulación pesada en la cola de solicitudes en `nvme0n1`).*

2. **Rastrear la Distribución de Latencia de la Cola de la Capa de Bloques (`blktrace`)**:
   ```console
   $ sudo blktrace -d /dev/nvme0n1 -o - | blkparse -i -
   8,0    1        1     0.000000000  1294  Q   W 2097152 + 128 [postgres]
   8,0    1        2     0.000003112  1294  G   W 2097152 + 128 [postgres]
   8,0    1        3     0.000005421  1294  I   W 2097152 + 128 [postgres]
   8,0    1        4     0.000009120  1294  D   W 2097152 + 128 [postgres]
   8,0    1        5     0.018210441     0  C   W 2097152 + 128 [0]
   ```
   *(Análisis: El tiempo transcurrido entre la emisión `D` y la finalización `C` es de 18.2 ms, aislando la latencia a la ejecución del controlador de hardware en lugar del encolamiento del kernel del SO de `Q` a `D`).*

3. **Estrategia de Remediación**: Ajustar la profundidad de cola de bloques y la configuración del planificador dinámicamente:
   ```console
   $ echo "none" | sudo tee /sys/block/nvme0n1/queue/scheduler
   $ echo "2048" | sudo tee /sys/block/nvme0n1/queue/nr_requests
   ```

---

## 6. Referencias

- **Resumen Oficial y Objetivos de Linux Professional Institute LPIC-2**: [https://www.lpi.org/our-certifications/lpic-2-overview/](https://www.lpi.org/our-certifications/lpic-2-overview/)
- **Documentación de la Capa de Bloques del Kernel de Linux**: [https://www.kernel.org/doc/html/latest/block/index.html](https://www.kernel.org/doc/html/latest/block/index.html)
- **Documentación Oficial y Guía de Administración de Open-iSCSI**: [https://github.com/open-iscsi/open-iscsi](https://github.com/open-iscsi/open-iscsi)
- **Guía de Administración de Almacenamiento de Red Hat Enterprise Linux**: [https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/managing_storage_devices/](https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/managing_storage_devices/)
- **Código Fuente y Páginas de Man de Multipath-Tools**: [https://github.com/opensvc/multipath-tools](https://github.com/opensvc/multipath-tools)
- **Referencia de Comandos y Arquitectura de LVM2**: [https://sourceware.org/lvm2/](https://sourceware.org/lvm2/)