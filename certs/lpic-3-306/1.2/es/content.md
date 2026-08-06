# LPIC-3 Exam 306-300 (v3.0) — High Availability Cluster Storage (Topic 306.2)
**Target Certification:** LPIC-3 Specialty: High Availability and Storage Clusters  
**Exam Weight:** 25  
**Audience Level:** Senior SRE / Principal Platform Architect  

---

## 1. Motivación de Producción y Planteamiento del Problema Arquitectónico

### 1.1 El Dilema del Almacenamiento de Alta Disponibilidad
En la arquitectura de sistemas distribuidos, las cargas de trabajo con estado (stateful workloads, como bases de datos relacionales, colas de mensajes transaccionales y repositorios de archivos compartidos compatibles con POSIX) introducen un desafío fundamental: mantener la consistencia del almacenamiento a través de múltiples compute nodes sin introducir un Single Point of Failure (SPOF) ni sacrificar el rendimiento de I/O.

Los clusters de High-Availability (HA) con estado típicamente aprovechan uno de dos paradigmas de almacenamiento principales:
1. **Shared-Storage Topology (SAN/Fibre Channel/iSCSI):** Múltiples compute nodes se conectan directamente a un LUN de bloques compartido.
2. **Shared-Nothing Replicated-Block Topology (DRBD):** Los host nodes mantienen dispositivos de bloques localizados, replicando bloques de disco en bruto a través de enlaces de red dedicados.

```
       [Shared Storage Paradigm]                        [Shared-Nothing Paradigm]
       +-------+        +-------+                     +-------+        +-------+
       | NodeA |        | NodeB |                     | NodeA |        | NodeB |
       +---+---+        +---+---+                     +---+---+        +---+---+
           |                |                             |                |
           +-------+--------+                             |  DRBD Protocol |
                   |                                      +================+
            +------v------+                               | (Block Rep.)   |
            | SAN / iSCSI |                           +---v---+        +---v---+
            |  Shared LUN |                           | /dev  |        | /dev  |
            +-------------+                           | /sdb1 |        | /sdb1 |
                                                      +-------+        +-------+
```

### 1.2 Riesgos de Concurrencia y Split-Brain
Los filesystems locales estándar (por ejemplo, `ext4`, `xfs`) asumen un control exclusivo sobre los metadatos de asignación de bloques (superblocks, inodes, bitmaps de bloques libres). Si dos nodos montan de manera concurrente un filesystem no clusterizado sobre almacenamiento de bloques compartido:
* **Corrupción de Inodes:** Las page caches se desincronizan; el Node A escribe modificaciones de bloques que sobrescriben los metadatos de asignación modificados por el Node B.
* **Kernel Panics:** La incoherencia de la buffer cache desencadena aserciones críticas del kernel (`FS-Error` o remontajes silenciosos del filesystem a solo lectura).

Para prevenir la corrupción de datos, el almacenamiento en cluster de alta disponibilidad requiere mecanismos de sincronización especializados:
* **Shared-Nothing Block Replication (DRBD):** Requiere un estado estricto de single-primary o modo dual-primary combinado con un filesystem orientado a cluster.
* **Shared-Disk Clustered Filesystems (GFS2, OCFS2):** Utilizan un **Distributed Lock Manager (DLM)** o una capa de membresía de cluster para arbitrar primitivas de file-locking a través de los nodos.
* **Fencing & STONITH (Shoot The Other Node In The Head):** Los nodos que no responden o con split-brain DEBEN ser aislados por la fuerza a nivel de hardware (vía IPMI/iLO/PDU) antes de que el acceso a los bloques sea transferido a nodos sanos.

---

## 2. Comparaciones Técnicas y Matriz de Compromisos (Trade-offs)

### 2.1 Replicación a Nivel de Bloque vs. Clustered File Systems

| Métrica Arquitectónica | DRBD 9 (Protocol C) | GFS2 + DLM | OCFS2 + o2cb/DLM | iSCSI + Multipath + `lvmlockd` |
| :--- | :--- | :--- | :--- | :--- |
| **Arquitectura de Almacenamiento** | Shared-Nothing Block Replication | Shared-Disk SAN / LUN | Shared-Disk SAN / LUN | Shared-Disk SAN / LUN |
| **Modo Operativo Principal** | Single-Primary (Dual-Primary para Live Migration) | Multi-Primary (Active-Active) | Multi-Primary (Active-Active) | Volume Groups Active-Passive o Active-Active |
| **Tipo de Replicación / Lock** | Replicación sincrónica de bloques sobre TCP/IP o RDMA | Distributed Lock Manager (DLM) sobre Corosync | `o2cb` o DLM | Replicación HW en SAN Fabric + Lock Manager |
| **Cumplimiento POSIX** | Nativo (vía filesystem local sobre `/dev/drbdX`) | Full POSIX Clustered FS | Full POSIX Clustered FS | Nativo vía LVs montados |
| **Escala Máxima (Nodos Recomendados)** | 2 a 32 nodos (DRBD 9) | 2 a 16 nodos | 2 a 16 nodos | Limitado por Fabric (hasta 64 nodos) |
| **Sobrecarga de Latencia** | Latencia de Red Round-Trip (RTT) por escritura de bloque | RTT de adquisición de lock DLM por modificación de metadatos de archivo | RTT de lock DLM/o2cb | Latencia de SAN Fabric + sobrecarga de comprobación de rutas MPath |
| **Mitigación de Split-Brain** | Automatic Fencing Handlers + Quorum Control | Pacemaker STONITH obligatorio | Pacemaker STONITH o `o2cb` Heartbeat Fencing | SAN Fencing / SCSI-3 Persistent Reservations |
| **Caso de Uso Óptimo en Producción** | Bases de datos HA (PostgreSQL, MySQL, Redis), Failover Active/Passive | Directorios compartidos de subida web, escrituras concurrentes HPC | Oracle RAC, Almacenamiento VM compartido | Infraestructura de almacenamiento LVM compartido a través de clusters SAN |

### 2.2 Matriz de Protocolos de Transporte DRBD

```
Application Write -> Node A Buffer Cache -> DRBD Driver
                                               |
         +-------------------------------------+-------------------------------------+
         |                                     |                                     |
    [Protocol A]                          [Protocol B]                          [Protocol C]
 (Asynchronous)                      (Semi-Synchronous)                      (Synchronous)
         |                                     |                                     |
Sent to local TCP buffer            Sent to remote TCP buffer             Written to remote disk
RPO > 0 (Potential Loss)            RPO ~ 0 (Minimal Loss)                RPO = 0 (Zero Loss)
Best for WAN DR                     Best for Campus/LAN                   Required for HA Clusters
```

---

## 3. Manifiestos de Producción e Infraestructura de Configuración

### 3.1 Configuración Completa de Producción de DRBD 9 (`/etc/drbd.d/r0.res`)

```
# Production DRBD 9 Resource Definition for HA Database Cluster
resource r0 {
    version 9;

    net {
        protocol C;
        max-buffers 20480;
        max-epoch-size 20480;
        sndbuf-size 1048576;
        rcvbuf-size 2048576;
        csums-alg sha256;
        verify-alg sha256;
        allow-two-primaries no;
        cram-hmac-alg sha256;
        shared-secret "SuperComplexProductionSecretKey2026!";
        on-congestion policy-engine;
    }

    handlers {
        split-brain "/usr/lib/drbd/notify-split-brain.sh root@example.com";
        fence-peer "/usr/lib/drbd/crm-fence-peer.9.sh";
        unfence-peer "/usr/lib/drbd/crm-unfence-peer-9.sh";
        before-resync-target "/usr/lib/drbd/snapshot-resync-target-backup.sh";
        pri-lost-after-sb "/usr/lib/drbd/notify-pri-lost-after-sb.sh root@example.com";
    }

    disk {
        resync-rate 110M;
        c-plan-ahead 20;
        c-fill-target 20M;
        c-max-rate 250M;
        c-min-rate 10M;
        disk-flushes yes;
        md-flushes yes;
        on-io-error detach;
        fencing resource-and-stonith;
    }

    on san-node01.example.com {
        node-id 0;
        device /dev/drbd0 minor 0;
        disk /dev/mapper/vg_storage-lv_data;
        meta-disk internal;
        address 192.168.100.11:7788;
    }

    on san-node02.example.com {
        node-id 1;
        device /dev/drbd0 minor 0;
        disk /dev/mapper/vg_storage-lv_data;
        meta-disk internal;
        address 192.168.100.12:7788;
    }
}
```

---

### 3.2 Configuración Enterprise de Device-Mapper Multipath (`/etc/multipath.conf`)

```
# Device-Mapper Multipath Production Configuration for Enterprise SAN LUNs
defaults {
    user_friendly_names yes
    find_multipaths yes
    polling_interval 5
    path_selector "service-time 0"
    path_grouping_policy group_by_prio
    supported_path_checkers "tur directio alua"
    prio "alua"
    path_checker alua
    failback immediate
    rr_weight uniform
    no_path_retry 18
    rr_min_io 1000
    flush_on_last_del yes
    dev_loss_tmo 30
    fast_io_fail_tmo 5
    features "1 queue_if_no_path"
}

blacklist {
    devnode "^(ram|raw|loop|fd|md|dm-|sr|scd|st)[0-9]*"
    devnode "^sda$"
    wwid ".*"
}

blacklist_exceptions {
    wwid "360014050a12b9845d0442c8d506eef1d"
}

multipaths {
    multipath {
        wwid "360014050a12b9845d0442c8d506eef1d"
        alias mpath_shared_gfs2
        path_grouping_policy group_by_prio
        prio alua
        path_checker alua
        failback immediate
    }
}

devices {
    device {
        vendor "PURESTORAGE"
        product "FlashArray"
        path_grouping_policy group_by_prio
        path_checker tur
        fast_io_fail_tmo 10
        dev_loss_tmo 60
        no_path_retry 12
    }
}
```

---

### 3.3 Manifiesto Completo del Cluster Pacemaker (`drbd_gfs2_stack.xml` / Comandos de Despliegue `pcs`)

Para desplegar DRBD, DLM y GFS2 bajo el control de Pacemaker, ejecute la siguiente secuencia de configuración:

```bash
# 1. Configure Cluster Property & STONITH Fencing
pcs property set stonith-enabled=true
pcs property set no-quorum-policy=freeze

# 2. Configure IPMI Hardware Fencing Devices
pcs stonith create stonith_node1 fence_ipmilan \
    pcmk_host_list="san-node01.example.com" \
    ipaddr="192.168.1.101" login="admin" passwd="SecretIpmiPassword" action="off" \
    op monitor interval=60s timeout=20s

pcs stonith create stonith_node2 fence_ipmilan \
    pcmk_host_list="san-node02.example.com" \
    ipaddr="192.168.1.102" login="admin" passwd="SecretIpmiPassword" action="off" \
    op monitor interval=60s timeout=20s

# 3. Create DRBD Resource & Promotable Clone (Master/Slave)
pcs resource create DrbdData ocf:linbit:drbd \
    drbd_resource=r0 \
    op monitor interval=15s role="Master" timeout=30s \
    op monitor interval=30s role="Slave" timeout=30s

pcs resource promotable DrbdData \
    promoted-max=1 promoted-node-max=1 \
    clone-max=2 clone-node-max=1 \
    notify=true id=DrbdData-clone

# 4. Configure DLM (Distributed Lock Manager) Clone
pcs resource create dlm ocf:pacemaker:controld \
    op monitor interval=30s timeout=30s

pcs resource clone dlm interleave=true

# 5. Configure GFS2 Filesystem Mount Resource
pcs resource create Gfs2Fs ocf:heartbeat:Filesystem \
    device="/dev/drbd0" \
    directory="/mnt/shared_gfs2" \
    fstype="gfs2" \
    options="noatime" \
    op monitor interval=20s timeout=40s \
    op start timeout=60s \
    op stop timeout=60s

pcs resource clone Gfs2Fs interleave=true

# 6. Set Ordering & Colocation Constraints
pcs constraint order start dlm-clone then start Gfs2Fs-clone
pcs constraint order promote DrbdData-clone then start Gfs2Fs-clone
pcs constraint colocation add Gfs2Fs-clone with DrbdData-clone role=Promoted
```

---

## 4. Comandos CLI Reales y Salidas Esperadas de la Terminal

### 4.1 Verificación de Estado de DRBD (`drbdadm` y `drbdsetup`)

```bash
$ drbdadm status r0 --verbose
```
```text
r0 node-id:0 connection:Connected role:Primary
  volume:0 minor:0 disk:UpToDate blocked:no
  san-node02.example.com node-id:1 connection:Connected role:Secondary
    volume:0 minor:0 disk:UpToDate peer-blocked:no
```

```bash
$ drbdsetup status r0 --statistics
```
```text
r0 node-id:0 role:Primary suspended:false
  volume:0 minor:0 disk:UpToDate size:104853504 KiB read:4521092 KiB written:12894520 KiB al-writes:412 bit-map-writes:0 activity-log-resyncs:0
  san-node02.example.com node-id:1 connection:Connected role:Secondary congestion:none
    volume:0 minor:0 disk:UpToDate replication:Established ap-in-flight:0 rs-in-flight:0 resync-susp:none
```

---

### 4.2 Estado del Cluster Pacemaker (`pcs status`)

```bash
$ pcs status
```
```text
Cluster name: ha_storage_cluster
Cluster Summary:
  * Stack: corosync
  * Current DC: san-node01.example.com (version 2.1.5-9.el9) - partition with quorum
  * Last updated: Thu Aug  6 17:14:00 2026
  * Last change:  Thu Aug  6 16:40:12 2026 by root via cibadmin on san-node01.example.com
  * 2 nodes configured
  * 6 resource instances configured

Node List:
  * Online: [ san-node01.example.com san-node02.example.com ]

Full List of Resources:
  * stonith_node1	(stonith:fence_ipmilan):	Started san-node02.example.com
  * stonith_node2	(stonith:fence_ipmilan):	Started san-node01.example.com
  * Clone Set: DrbdData-clone [DrbdData] (promotable):
    * Promoted: [ san-node01.example.com ]
    * Unpromoted: [ san-node02.example.com ]
  * Clone Set: dlm-clone [dlm]:
    * Started: [ san-node01.example.com san-node02.example.com ]
  * Clone Set: Gfs2Fs-clone [Gfs2Fs]:
    * Started: [ san-node01.example.com san-node02.example.com ]

Daemon Status:
  corosync: active/enabled
  pacemaker: active/enabled
  pcsd: active/enabled
```

---

### 4.3 Topología Multipath de SAN Enterprise (`multipath -ll`)

```bash
$ multipath -ll mpath_shared_gfs2
```
```text
mpath_shared_gfs2 (360014050a12b9845d0442c8d506eef1d) dm-2 PURE,FlashArray
size=500G features='1 queue_if_no_path' hwhandler='1 alua' wp=rw
|-+- policy='service-time 0' prio=50 status=active
| |- 3:0:0:1 sdb 8:16 active ready running
| `- 4:0:0:1 sdc 8:32 active ready running
`-+- policy='service-time 0' prio=10 status=enabled
  |- 3:0:1:1 sdd 8:48 active ready running
  `- 4:0:1:1 sde 8:64 active ready running
```

---

### 4.4 Estado del Lock Manager DLM (`dlm_tool`)

```bash
$ dlm_tool status
```
```text
dlm status
daemon version 4.1.1
lockspaces 1
total nodes 2
clean nodes 2
dirty nodes 0
```

```bash
$ dlm_tool ls
```
```text
dlm lockspaces
name          gfs2_shared
id            0x5f8a2b1c
flags         0x00000000
change        member count 2 total run 1
members       1 2 
```

---

### 4.5 Inspección de Tuning y Journal del Filesystem GFS2 (`gfs2_jadd` / `tunefs.gfs2`)

```bash
$ tunefs.gfs2 -l /dev/drbd0
```
```text
Filesystem volume name: ha_storage_cluster:gfs2_shared
Filesystem UUID:        7d4a1b02-89ef-4c12-91ef-c56a88bdf201
Filesystem format #:    1801
Journal count:          2
Block size:             4096
Journal 0 size:         128 MB
Journal 1 size:         128 MB
```

```bash
$ gfs2_jadd -j 2 /mnt/shared_gfs2
```
```text
Filesystem: /mnt/shared_gfs2
Old Journals: 2
New Journals: 4
Journal 2 size: 128MB
Journal 3 size: 128MB
Done.
```

---

## 5. Guía de Verificación y Diagnóstico para Fallos en Producción

### 5.1 Escenario A: Detección de Split-Brain en DRBD y Recuperación Manual

#### 1. Manifestación del Fallo
El enlace de red entre el Node A y el Node B se interrumpe mientras ambos nodos reciben operaciones de escritura. Ambos nodos pasan al modo `StandAlone` con discos desconectados.

```bash
$ drbdadm status r0
```
```text
r0 node-id:0 connection:StandAlone role:Primary
  volume:0 minor:0 disk:UpToDate
```

Log del kernel (`dmesg | grep -i drbd`):
```text
[ 4120.512411] drbd r0: Split-Brain detected, dropping connection!
[ 4120.512490] drbd r0: Helper process /usr/lib/drbd/notify-split-brain.sh returned 0
[ 4120.512520] drbd r0: State change failed: Need access to UpToDate data
[ 4120.512550] drbd r0: conn( Unconnected -> StandAlone )
```

---

#### 2. Procedimiento de Resolución de Causa Raíz (Flujo de Trabajo de Recuperación Manual)

Paso 1: Identificar el Victim Node (el nodo cuyas modificaciones serán sobrescritas) y el Survivor Node (la fuente de datos canónica).

Paso 2: En el **Victim Node** (`san-node02.example.com`):
```bash
# Demote to Secondary
$ drbdadm secondary r0

# Force rejection of local modifications
$ drbdadm connect --discard-my-data r0
```

Paso 3: En el **Survivor Node** (`san-node01.example.com`):
```bash
# Re-establish connection as resync source
$ drbdadm connect r0
```

Paso 4: Verificar la finalización de Resync:
```bash
$ drbdadm status r0
```
```text
r0 node-id:0 connection:SyncSource role:Primary
  volume:0 minor:0 disk:UpToDate
  san-node02.example.com node-id:1 connection:SyncTarget role:Secondary
    volume:0 minor:0 disk:Inconsistent replication:SyncSource peer-disk:Inconsistent done:34.12%
```

---

### 5.2 Escenario B: Bloqueo de Lock DLM / Depuración de Fencing de Nodos en GFS2

#### 1. Síntoma
Las operaciones de I/O en `/mnt/shared_gfs2` se congelan; `df -h` se bloquea indefinidamente en los montajes de GFS2.

#### 2. Pasos de Ejecución Diagnóstica

Paso 1: Inspeccionar las estructuras del lockspace del kernel a través de `debugfs`:
```bash
$ cat /sys/kernel/debug/dlm/gfs2_shared_locks | grep -E "Granted|Waiting"
```
```text
Resource 0000000000000005: Lock master: nodeid 2
  Grant queue:
    Node: 1, Mode: PR, Status: GRANTED
  Wait queue:
    Node: 1, Mode: EX, Status: WAITING (held by Node 2 unresponsive)
```

Paso 2: Verificar la membresía del cluster Corosync y el estado de quorum:
```bash
$ corosync-cmapctl | grep runtime.totem.pg.mrp.srp.members
```
```text
runtime.totem.pg.mrp.srp.members.1.config_version (u64) = 0
runtime.totem.pg.mrp.srp.members.1.ip (str) = r(0) ip(192.168.100.11) 
runtime.totem.pg.mrp.srp.members.1.status (str) = joined
runtime.totem.pg.mrp.srp.members.2.status (str) = left
```

Paso 3: Si Pacemaker STONITH no logra aplicar auto-fence al nodo caído, ejecute un STONITH de emergencia manual para liberar los locks DLM:
```bash
$ pcs stonith fence san-node02.example.com
```
```text
Node san-node02.example.com successfully fenced
```

---

### 5.3 Escenario C: Fallo de Ruta SAN y Restablecimiento de Multipath

#### 1. Rastro Diagnóstico

Comprobar las caídas del estado de las rutas en `/var/log/messages`:
```text
Aug 6 17:02:11 san-node01 kernel: multipathd: mpath_shared_gfs2: sdb - path failed
Aug 6 17:02:11 san-node01 kernel: multipathd: mpath_shared_gfs2: Remaining active paths: 3
Aug 6 17:02:15 san-node01 kernel: multipathd: mpath_shared_gfs2: sdc - path failed
Aug 6 17:02:15 san-node01 kernel: multipathd: mpath_shared_gfs2: Switching to path group 2
```

Forzar la re-comprobación de rutas de multipath y la reconfiguración del demonio:
```bash
$ multipathd reconfigure
$ multipathd show paths format "%n %d %t %T %s"
```
```text
dev dev_t failback process status
sdb 8:16  immediate active  failed
sdc 8:32  immediate active  failed
sdd 8:48  immediate active  active
sde 8:64  immediate active  active
```

Restablecer las rutas HBA fallidas después de la reparación del hardware:
```bash
$ echo 1 > /sys/block/sdb/device/rescan
$ echo 1 > /sys/block/sdc/device/rescan
$ multipathd resize map mpath_shared_gfs2
```

---

## 6. Referencias

* **Objetivos del Examen Linux Professional Institute (LPI) 306-300:**  
  [https://www.lpi.org/our-certifications/lpic-3-306-overview/](https://www.lpi.org/our-certifications/lpic-3-306-overview/)
* **Guía de Usuario y Documentación Técnica de LINBIT DRBD 9:**  
  [https://linbit.com/drbd-user-guide/drbd-guide-9_0-en/](https://linbit.com/drbd-user-guide/drbd-guide-9_0-en/)
* **Guía de Productos de Cluster de Alta Disponibilidad de Red Hat Enterprise Linux 9:**  
  [https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/configuring_and_managing_high_availability_clusters/index](https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/configuring_and_managing_high_availability_clusters/index)
* **Arquitectura y Referencia de Global File System 2 (GFS2) - Documentación de Red Hat:**  
  [https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/global_file_system_2/index](https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/global_file_system_2/index)
* **Código Fuente y Manual de Administración de Linux Device-Mapper Multipathing:**  
  [https://christophe.varoqui.free.fr/](https://christophe.varoqui.free.fr/)
* **Manual de Cierre del Kernel (Kernel Locking) DLM y Demonio de Control de Cluster (`controld`):**  
  [https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/Documentation/filesystems/dlmfs.rst](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/Documentation/filesystems/dlmfs.rst)