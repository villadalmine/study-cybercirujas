# Examen LPIC-3 306-300 (v3.0) — Tema 1.4: Single Node High Availability

## 1. Motivación y Problema de Arquitectura en Producción

En la ingeniería de infraestructura de producción, la alta disponibilidad (HA) se confunde a menudo con marcos de trabajo (frameworks) de clústeres distribuidos (por ejemplo, Kubernetes, Pacemaker, Ceph). Sin embargo, los algoritmos de consenso distribuido (Raft, Paxos) y los modelos de quórum multi-nodo dependen estrictamente de la estabilidad de sus nodos de cómputo subyacentes. Un solo fallo de hardware no gestionado —como un controlador NVMe degradado, una NIC con oscilaciones silenciosas (flapped), o una degradación de energía de un UPS no monitoreado— puede desencadenar eventos prematuros de partición de clúster, fallos en cascada (cascading failovers), escenarios de split-brain o una corrupción de estado catastrófica.

Single Node High Availability se enfoca en construir primitivas de nodo tolerantes a fallos antes de escalar horizontalmente (scale out). El objetivo es maximizar el **Tiempo Medio Entre Fallos (MTBF)** y minimizar el **Tiempo Medio de Reparación (MTTR)** en la capa del hipervisor o del host bare-metal.

```
+-----------------------------------------------------------------------------------+
|                            SINGLE NODE HA ARCHITECTURE                            |
+-----------------------------------------------------------------------------------+
|  Resource & Power Health    |  Storage Redundancy          | Network Resilience   |
|  - smartd (Predictive)      |  - Advanced mdadm (Bitmaps)  | - LACP / Bond Mode 4 |
|  - Monit (Auto-Recovery)    |  - LVM RAID1 / Thin-Pools    | - VLAN 802.1Q        |
|  - NUT / APCUPSD (UPS Signal|  - Hot-Spares & Scrubbing    | - BGP / VRRP (VIP)   |
+-----------------------------------------------------------------------------------+
                                         |
                                         v
+-----------------------------------------------------------------------------------+
|                        HARDWARE / KERNEL SUBSYSTEM (Bare-Metal)                   |
|  [ Physical Disks ]       [ Dual PSUs / UPS ]       [ Dual Top-of-Rack Switches ] |
+-----------------------------------------------------------------------------------+
```

### Vectores Clave de Degradación Manejados a Nivel de Nodo:
1. **Corrupción Silenciosa de Datos y Degradación de Unidades:** El desgaste de los medios en las unidades flash modernas o los sectores reasignados en medios magnéticos a menudo no desencadenan errores de E/S inmediatos hasta que ocurren fallos de lectura de bloques durante una barrera de escritura (write barrier).
2. **Fallo en la Ruta de Red:** La degradación de cables, el fallo de módulos SFP o los reinicios del switch Top-of-Rack (ToR) de nivel superior pueden desconectar un host mientras su CPU y almacenamiento locales permanecen completamente sanos.
3. **Saturación Volumétrica del Almacenamiento:** Escrituras de logs sin límite o pools con aprovisionamiento fino (thin-provisioned) sin supervisión que bloquean el sistema de archivos raíz o la partición de logs de transacciones (`/var/log`, `/var/lib/docker`).
4. **Inestabilidad Térmica y Energética:** Interrupciones en el suministro eléctrico o fallos en las unidades de fuente de alimentación (PSU) locales que causan una pérdida abrupta de energía, resultando en inconsistencias en el journal o metadatos de almacenamiento corruptos.

---

## 2. Comparativas Técnicas y Análisis de Compromisos (Trade-Offs)

### 2.1 Redundancia de Almacenamiento: Software RAID (`mdadm`) vs. Advanced LVM RAID vs. ZFS Single-Node

| Métrica Técnica | Linux Software RAID (`mdadm`) | Advanced LVM RAID (`lvcreate --type`) | ZFS en Linux (Single Pool) |
| :--- | :--- | :--- | :--- |
| **Capa Arquitectónica** | Abstracción de Dispositivo de Bloques (`/dev/mdX`) | Gestión de Volúmenes + Subsistema DM-RAID | Sistema de Archivos y Gestor de Volúmenes Integrado |
| **Sobrecarga de Recuperación por Resincronización** | Alta (sincroniza el disco entero a menos que se configure Bitmap) | Alta (utiliza el módulo backend `md` del kernel; duplica extents asignados) | Baja (sincroniza únicamente los punteros de bloques activos asignados) |
| **Soporte para Write-Intent Bitmap** | Bitmap interno/externo nativo; reduce tiempos de reconstrucción tras apagados no limpios | Soportado mediante asignación de metadatos LVM para logs de escritura | Copy-on-Write (CoW) nativo; sin write hole |
| **Flexibilidad de Almacenamiento** | Baja (tamaños de bloque fijos, flujos de trabajo de redimensionamiento manual) | Alta (redimensionamiento de volúmenes en línea, thin provisioning, snapshotting) | Asignación dinámica; cuotas de almacenamiento a nivel de Dataset |
| **Sobrecarga de CPU / RAM** | Sobrecarga de CPU mínima; bajo consumo de RAM | CPU de baja a moderada; bajo consumo de RAM | Alto requerimiento de RAM (demandas de memoria ARC) |
| **Radio de Impacto (Blast Radius) en Producción** | Degradación por fallo por array; aisla errores de bloque | Corrupción de metadatos en el Grupo de Volúmenes (VG) impacta todos los LVs | Corrupción a nivel de Pool (`zpool`) impacta toda la pila de almacenamiento |

### 2.2 Redundancia de Enlace de Red: Modos de Bonding y Estrategias de Enrutamiento

| Modo / Protocolo | Mecanismo Operativo | Requerimiento L2/L3 | Agregación de Rendimiento (Throughput) | Convergencia de Failover |
| :--- | :--- | :--- | :--- | :--- |
| **Mode 1: Active-Backup** | Interfaz primaria activa; la interfaz secundaria permanece en espera en estado promiscuo | Switch L2 estándar no administrado | Tasa de línea de interfaz única (1x) | Subsegundo (depende del intervalo de prueba de `miimon`) |
| **Mode 4: 802.3ad (LACP)** | Negociación dinámica de enlace IEEE 802.3ad usando tramas LACPDU | Requiere switch ToR configurado con LACP / MLAG | Capacidad de flujo agregada multi-interfaz basada en hash | < 1 segundo ante pérdida de enlace físico |
| **Keepalived (VRRP)** | Migración de IP Virtual entre dos nodos mediante heartbeats multicast | Dominio de broadcast L2 plano | 1x Tasa de línea (el nodo Activo enruta el tráfico) | 1-3 segundos (basado en `advert_int` y temporizadores) |
| **FRRouting (BGP / Anycast)** | Conexiones de pares ECMP de Capa 3 a switches leaf ToR duales | Fabric enrutado L3 (capacidades BGP en switches leaf) | Balanceo de carga ECMP L3 de múltiples rutas | Subsegundo con BFD (Bidirectional Forwarding Detection) |

---

## 3. Manifiestos de Infraestructura de Producción y Archivos de Configuración

### 3.1 Monitoreo Predictivo de Fallos de Unidades: `/etc/smartd.conf`

Configuración del demonio S.M.A.R.T. para entornos de producción para monitorear unidades NVMe y discos SATA/SAS, activando scripts de alerta predictiva antes de que ocurra un fallo definitivo.

```ini
# /etc/smartd.conf - Production SMART Monitoring Configuration
# Directives:
# -d auto   : Automatically detect device type
# -H        : Check SMART health status
# -l error  : Track SMART error log growth
# -l selftest : Track self-test log errors
# -f        : Check for failure of any usage attributes
# -s        : Run self-tests on schedule (Short test daily at 2AM, Long test Sundays at 3AM)
# -m        : Destination email/alert endpoint
# -M exec   : Custom notification handler binary

/dev/nvme0n1 -d nvme -H -l error -l selftest -W 2,55,65 -m sysadmin-alerts@infra.internal -M exec /usr/local/bin/smartd-pager.sh
/dev/sda -d auto -H -k on -l error -l selftest -f -s (S/../.././02|L/../../7/03) -W 4,45,55 -m sysadmin-alerts@infra.internal -M exec /usr/local/bin/smartd-pager.sh
/dev/sdb -d auto -H -k on -l error -l selftest -f -s (S/../.././02|L/../../7/03) -W 4,45,55 -m sysadmin-alerts@infra.internal -M exec /usr/local/bin/smartd-pager.sh
```

### 3.2 Auto-Recuperación (Auto-Healing) de Servicios y Recursos del Sistema: `/etc/monit/monitrc` y Configuración de Módulos

`/etc/monit/conf.d/node_health.monit` garantiza que los demonios principales permanezcan operativos y que las particiones de almacenamiento no agoten los inodes del nodo ni el espacio de almacenamiento.

```monit
# /etc/monit/conf.d/node_health.monit

set daemon 30 # Poll every 30 seconds
set log /var/log/monit.log

# Monitor Host Overall Performance Metrics
check host local_node address 127.0.0.1
    if loadavg (5min) > 16 then alert
    if memory usage > 85% then alert
    if cpu usage (system) > 30% for 3 cycles then alert

# Monitor Storage Mount Point
check filesystem rootfs path /
    if space usage > 80% for 2 cycles then alert
    if space usage > 92% then exec "/usr/local/bin/purge_scratch_space.sh"
    if inode usage > 88% then alert

# Monitor Keepalived Daemon Resilience
check process keepalived with pidfile /var/run/keepalived.pid
    start program = "/usr/bin/systemctl start keepalived"
    stop program  = "/usr/bin/systemctl stop keepalived"
    if failed host 127.0.0.1 port 112 protocol vrrp timeout 5 seconds then restart
    if 3 restarts within 5 cycles then timeout
```

### 3.3 Software RAID Avanzado con Write-Intent Bitmap: Script de Aprovisionamiento

Este script de manifiesto construye un array RAID 1 resistente a degradación utilizando `mdadm`, adjunta un write-intent bitmap interno para minimizar los tiempos de recuperación y persiste la configuración de metadatos.

```bash
#!/usr/bin/env bash
set -euo pipefail

# 1. Zero out magic superblocks on raw target disks
mdadm --zero-superblock --force /dev/sdb1 /dev/sdc1

# 2. Assemble RAID 1 with an internal write-intent bitmap and 64K chunk size
mdadm --create /dev/md0 \
  --level=1 \
  --raid-devices=2 \
  --bitmap=internal \
  --bitmap-chunk=131072 \
  --metadata=1.2 \
  --name=node01:data_store \
  /dev/sdb1 /dev/sdc1

# 3. Format with ext4 featuring strict journal writeback guarantees
mkfs.ext4 -F -O journal_data_writeback,fast_commit -E lazy_itable_init=0,lazy_journal_init=0 /dev/md0

# 4. Generate persistent mdadm configuration
mkdir -p /etc/mdadm
mdadm --detail --scan --config=partitions >> /etc/mdadm/mdadm.conf
update-initramfs -u
```

### 3.4 Redundancia LVM Avanzada: Thin-Pool con Auto-Extend y LVM RAID1

El segmento de configuración a continuación habilita protecciones automatizadas de gestión de volúmenes dentro de `/etc/lvm/lvm.conf` para expandir automáticamente los thin pools antes de su agotamiento.

```ini
# /etc/lvm/lvm.conf (Partial snippet - Production critical settings)
activation {
    thin_pool_autoextend_threshold = 80
    thin_pool_autoextend_percent = 20
    snapshot_autoextend_threshold = 80
    snapshot_autoextend_percent = 20
    monitoring = 1
    raid_fault_policy = "warn"
    mirror_image_fault_policy = "remove"
}
```

Script para asignar un volumen LVM RAID1 respaldado por Volúmenes Físicos (Physical Volumes) redundantes:

```bash
#!/usr/bin/env bash
set -euo pipefail

# 1. Initialize PVs
pvcreate /dev/nvme0n1p1 /dev/nvme1n1p1

# 2. Build Volume Group
vgcreate vg_production /dev/nvme0n1p1 /dev/nvme1n1p1

# 3. Create a mirrored Logical Volume (LVM RAID1) requiring both underlying PVs
lvcreate --type raid1 -m 1 -L 100G -n lv_database vg_production

# 4. Create a Thin Pool with automatic metadata redundancy
lvcreate --type thin-pool -L 200G -n thin_pool_apps vg_production
```

### 3.5 Alta Disponibilidad de Red: LACP Bonding + VLAN Tagging (`systemd-networkd`)

Para garantizar la redundancia de la ruta de red, configuramos un Bond IEEE 802.3ad (Modo 4) sobre dos interfaces físicas (`eth0`, `eth1`), ejecutando una etiqueta VLAN (`VLAN 100`) por encima.

`**/etc/systemd/network/10-bond0.netdev**`
```ini
[NetDev]
Name=bond0
Kind=bond

[Bond]
Mode=802.3ad
TransmitHashPolicy=layer3+4
MIIMonitorSec=100ms
LACPTransmitRate=fast
UpDelaySec=200ms
DownDelaySec=200ms
```

`**/etc/systemd/network/11-bond0-members.network**`
```ini
[Match]
Name=eth0 eth1

[Network]
Bond=bond0
```

`**/etc/systemd/network/20-bond0-vlan100.netdev**`
```ini
[NetDev]
Name=bond0.100
Kind=vlan

[VLAN]
Id=100
```

`**/etc/systemd/network/30-bond0-vlan100.network**`
```ini
[Match]
Name=bond0.100

[Network]
DHCP=no
Address=10.50.100.15/24
Gateway=10.50.100.1
DNS=10.50.100.2
```

### 3.6 Border Gateway Protocol (BGP) Multi-Homing: `/etc/frr/frr.conf`

Uso de FRRouting para establecer peering de un host único mediante BGP con switches Top-of-Rack duales para alta disponibilidad de Capa 3 e inyección dinámica de rutas ECMP.

```frr
! /etc/frr/frr.conf
frr version 8.5
frr defaults traditional
hostname node01.infra.internal
log syslogs informational
!
interface bond0.100
 ip address 10.50.100.15/24
!
router bgp 65001
 bgp router-id 10.50.100.15
 neighbor TOR_GROUP peer-group
 neighbor TOR_GROUP remote-as 65000
 neighbor TOR_GROUP timers 1 3
 neighbor 10.50.100.2 peer-group TOR_GROUP
 neighbor 10.50.100.3 peer-group TOR_GROUP
 !
 address-family ipv4 unicast
  redistribute connected
  neighbor TOR_GROUP activate
  maximum-paths 2
 exit-address-family
!
line vty
!
```

---

## 4. Comandos Reales de CLI y Salidas de Terminal Esperadas

### 4.1 Inspección Predictiva de Salud de Unidades S.M.A.R.T.

Evaluación de atributos de durabilidad (endurance) de NVMe y registros de errores del controlador para detectar fallos pendientes.

```bash
$ smartctl -a /dev/nvme0n1
```
```text
smartctl 7.3 2022-02-28 r5338 [x86_64-linux-5.15.0-88-generic] (local build)
Copyright (C) 2002-22, Bruce Allen, Christian Franke, www.smartmontools.org

=== START OF SMART DATA SECTION ===
SMART overall-health self-assessment test result: PASSED

SMART/Health Information (NVMe Log 0x02)
Critical Warning:                   0x00
Temperature:                        34 Celsius
Available Spare:                    100%
Available Spare Threshold:          10%
Percentage Used:                    2%
Data Units Read:                    14,892,104 [7.62 TB]
Data Units Written:                 38,410,299 [19.6 TB]
Host Read Commands:                 120,491,012
Host Write Commands:                410,192,840
Controller Busy Time:               1,240 minutes
Power Cycles:                       14
Power On Hours:                     4,120
Unsafe Shutdowns:                   2
Media and Data Integrity Errors:    0
Error Information Log Entries:      0
Warning Comp. Temperature Time:     0
Critical Comp. Temperature Time:    0
```

### 4.2 Consulta del Estado de Software RAID y Write-Intent Bitmap

Verificación del estado del array, bits de bitmap activos y progreso de reconstrucción en `/dev/md0`.

```bash
$ mdadm --detail /dev/md0
```
```text
/dev/md0:
           Version : 1.2
     Creation Time : Thu Aug  6 14:22:10 2026
        Raid Level : raid1
        Array Size : 976434176 (931.20 GiB 1000.00 GB)
     Used Dev Size : 976434176 (931.20 GiB 1000.00 GB)
      Raid Devices : 2
     Total Devices : 2
       Persistence : Superblock is present

     Intent Bitmap : Internal pages 16

             State : active 
    Active Devices : 2
   Working Devices : 2
    Failed Devices : 0
     Spare Devices : 0

Consistency Policy : bitmap

              Name : node01:data_store  (local to host node01)
              UUID : 4f8a2b1c:9d3e5f7a:11223344:55667788
            Events : 4312

    Number   Major   Minor   RaidDevice State
       0       8       17        0      active sync   /dev/sdb1
       1       8       33        1      active sync   /dev/sdc1
```

### 4.3 Inspección de la Sincronización y Salud del Espejo LVM RAID1

Verificación de la disposición del volumen lógico y el porcentaje de sincronización de metadatos.

```bash
$ lvs -a -o lv_name,vg_name,attr,size,copy_percent,devices vg_production
```
```text
  LV                  VG            Attr       LSize   Copy%  Devices                           
  lv_database         vg_production rwi-a-r--- 100.00g 100.00 lv_database_rimage_0(0),lv_database_rimage_1(0)
  [lv_database_rmeta_0] vg_production rwi-a-r---   4.00m        /dev/nvme0n1p1(0)                 
  [lv_database_rmeta_1] vg_production rwi-a-r---   4.00m        /dev/nvme1n1p1(0)                 
  [lv_database_rimage_0] vg_production iwi-a-r--- 100.00g        /dev/nvme0n1p1(1)                 
  [lv_database_rimage_1] vg_production iwi-a-r--- 100.00g        /dev/nvme1n1p1(1)                 
  thin_pool_apps      vg_production twi-a-tz-- 200.00g  12.45 thin_pool_apps_tdata(0)             
```

### 4.4 Verificación del Estado de Network Bonding del Kernel

Inspección directa de la interfaz procfs para confirmar el estado de LACP y la salud del enlace dual.

```bash
$ cat /proc/net/bonding/bond0
```
```text
Ethernet Channel Bonding Driver: v5.15.0-88-generic

Bonding Mode: IEEE 802.3ad Dynamic link aggregation
Transmit Hash Policy: layer3+4 (1)
MII Status: up
MII Polling Interval (ms): 100
Up Delay (ms): 200
Down Delay (ms): 200
Peer Encryption Protocol: none

802.3ad info
LACP rate: fast
Min links: 0
Aggregator selection policy (lacp_active): stable
System priority: 65535
System MAC address: 52:54:00:a1:b2:c3
Active Aggregator Info:
	Aggregator ID: 1
	Number of ports: 2
	Actor Key: 17
	Partner Key: 1
	Partner Mac Address: 00:1c:73:00:00:01

Slave Interface: eth0
MII Status: up
Speed: 10000 Mbps
Duplex: full
Link Failure Count: 0
Permanent HW addr: 52:54:00:a1:b2:c3
Slave queue ID: 0
Aggregator ID: 1
Actor Churn State: none
Partner Churn State: none
Actor Partner State: reg_aggr

Slave Interface: eth1
MII Status: up
Speed: 10000 Mbps
Duplex: full
Link Failure Count: 0
Permanent HW addr: 52:54:00:a1:b2:c4
Slave queue ID: 0
Aggregator ID: 1
Actor Churn State: none
Partner Churn State: none
Actor Partner State: reg_aggr
```

### 4.5 Inspección de la Topología de Enrutamiento mediante la Shell de FRRouting (`vtysh`)

Verificación de sesiones BGP activas y rutas ECMP hacia los switches ToR.

```bash
$ vtysh -c "show ip bgp summary"
```
```text
IPv4 Unicast Summary:
BGP router identifier 10.50.100.15, local AS number 65001 vrf-id 0
BGP table version 12
RIB entries 5, using 960 bytes of memory
Peers 2, using 144 KiB of memory

Peer            V    AS MsgRcvd MsgSent   TblVer  InQ OutQ Up/Down  State/PfxRcd   Desc
10.50.100.2     4 65000     412     415        0    0    0 06:45:12            24   N/A
10.50.100.3     4 65000     411     414        0    0    0 06:45:10            24   N/A

Total number of neighbors 2
```

---

## 5. Guía de Diagnóstico y Verificación de Fallos

### 5.1 Runbook Paso a Paso: Degradación Simulada de Disco y Hot Swap

Cuando un disco entra en un estado degradado o falla las comprobaciones S.M.A.R.T:

```
[ Step 1: Detect Failure ] ---> [ Step 2: Mark & Remove Disk ] ---> [ Step 3: Replace Physical Drive ] ---> [ Step 4: Partition & Re-add ] ---> [ Step 5: Verify Rebuild ]
```

```bash
# 1. Identify failing block device via kernel log trace
$ dmesg -T | grep -E "I/O error|SATA link down|medium error"

# 2. Force-fail and remove degraded disk (/dev/sdb1) from mdadm array
$ mdadm --manage /dev/md0 --fail /dev/sdb1
$ mdadm --manage /dev/md0 --remove /dev/sdb1

# 3. Verify hot-swap capability and remove disk safely from Linux SCSI layer
$ echo 1 > /sys/block/sdb/device/delete

# 4. Insert new drive, clone partition table from functional drive (/dev/sdc) to new drive (/dev/sdb)
$ sfdisk -d /dev/sdc | sfdisk /dev/sdb

# 5. Hot-add new partition to the active RAID array
$ mdadm --manage /dev/md0 --add /dev/sdb1

# 6. Monitor real-time reconstruction speed and kernel rebuild thread
$ watch -n 1 "cat /proc/mdstat"
```

### 5.2 Runbook Paso a Paso: Diagnóstico de Ruta de Red y Flapping de Enlace

Cuando el bonding LACP pierde un agregador o pierde tramas:

```bash
# 1. Inspect interface link state and drop counters
$ ip -s link show bond0

# 2. Query physical transceiver optical levels and physical link speed via ethtool
$ ethtool eth0
$ ethtool -m eth0

# 3. Trace LACPDU frame exchange using tcpdump
$ tcpdump -nn -i eth0 ether proto 0x8809 -c 5

# 4. Check systemd-networkd operational state
$ networkctl status bond0
```

### 5.3 Runbook Paso a Paso: Recuperación de Corrupción de Metadatos de LVM

Si las cabeceras de VG de LVM o las estructuras de metadatos se corrompen:

```bash
# 1. Locate automatically created LVM metadata backup files
$ ls -la /etc/lvm/backup/

# 2. Test metadata restoration dry-run
$ vgcfgrestore --test -f /etc/lvm/backup/vg_production vg_production

# 3. Execute metadata restoration to raw PV headers
$ vgcfgrestore -f /etc/lvm/backup/vg_production vg_production

# 4. Scan and reactivate missing Volume Groups
$ vgscan
$ vgchange -ay vg_production
```

---

## 6. Referencias

- **Objetivos Oficiales de Linux Professional Institute (LPI):**  
  [https://www.lpi.org/our-certifications/lpic-3-306-overview/](https://www.lpi.org/our-certifications/lpic-3-306-overview/)
- **Documentación del Controlador Ethernet Bonding del Kernel de Linux:**  
  [https://www.kernel.org/doc/Documentation/networking/bonding.txt](https://www.kernel.org/doc/Documentation/networking/bonding.txt)
- **Wiki Oficial de Administración de Linux RAID `mdadm`:**  
  [https://raid.wiki.kernel.org/index.php/A_admin_guide](https://raid.wiki.kernel.org/index.php/A_admin_guide)
- **Red Hat Enterprise Linux 9 — Configuración y Gestión de LVM:**  
  [https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/configuring_and_managing_logical_volumes/](https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/configuring_and_managing_logical_volumes/)
- **Manual de Monitoreo y Referencia de Smartmontools:**  
  [https://www.smartmontools.org/wiki/TocDoc](https://www.smartmontools.org/wiki/TocDoc)
- **Documentación Oficial de Usuario de FRRouting:**  
  [https://docs.frrouting.org/en/latest/bgp.html](https://docs.frrouting.org/en/latest/bgp.html)