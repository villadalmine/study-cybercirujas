# LPIC-3 306 (Examen 306-300 v3.0) — Manual de Laboratorio Guiado Empresarial: Almacenamiento en Cluster de Alta Disponibilidad

**Certificación Objetivo:** LPIC-3 High Availability and Storage Clusters (Examen 306-300, Versión 3.0)  
**Tema 362 y 363:** High Availability Cluster Storage & Distributed Storage  
**Audiencia:** Arquitectos Principales de Plataforma, SREs Senior, Ingenieros de Sistemas  
**Prerrequisitos:** Comprensión profunda de la capa de bloques del Kernel de Linux, sistemas de archivos POSIX, redes TCP/IP y primitivas de almacenamiento.

---

## Contexto Arquitectónico y Descripción General del Tema

El almacenamiento en cluster de alta disponibilidad (HA) forma la base de la infraestructura empresarial tolerante a fallos. Garantiza la Integridad, Consistencia y Disponibilidad de los Datos a pesar de caídas de nodos, particiones de red o degradación del medio de almacenamiento.

En esta serie de laboratorios, dominará los cinco pilares fundamentales del almacenamiento en cluster HA definidos en el temario de **LPIC-3 306-300 v3.0**:
1. **DRBD (Distributed Replicated Block Device):** Replicación RAID-1 por red síncrona/asíncrona a nivel de bloque.
2. **SAN High Availability & Storage Access:** Configuración de iSCSI Target/Initiator, Target Port Groups (TPG), ALUA y conmutación por error (failover) de E/S con `multipathd`.
3. **Sistemas de Archivos en Cluster:** Sistemas de archivos de disco compartido (GFS2, OCFS2) respaldados por el Distributed Lock Manager (DLM) e integración con Pacemaker/Corosync.
4. **Sistema de Archivos Distribuido GlusterFS:** Stacks de traductores (xlators), bricks, protocolos de replicación, daemons de autorreparación (self-healing) y resolución de split-brain.
5. **Almacenamiento Distribuido Unificado Ceph:** Internos de RADOS, quorum de Paxos MON, ubicación algorítmica de CRUSH map, máquinas de estado de Placement Group (PG) y mapeo de bloques RBD.

---

## Ejercicio 1: Mecánica de DRBD v9 / v8.4, Configuración Dual-Primary y Recuperación de Split-Brain

### 1.1 Mecánica Técnica Profunda y Arquitectura

DRBD opera como un controlador de dispositivo de bloques virtual en el Kernel de Linux entre la capa de sistema de archivos / buffer cache y los controladores de disco físico subyacentes.

```
+-------------------------------------------------------------+
|                     User Space / Applications               |
+-------------------------------------------------------------+
|                     Virtual File System (VFS)               |
+-------------------------------------------------------------+
|               Kernel Block Layer (/dev/drbd0)               |
+------------------------------+------------------------------+
                               |
               +---------------+---------------+
               |                               |
               v                               v
    +--------------------+           +--------------------+
    |  Local Disk Driver |           | DRBD Network Engine|
    +--------------------+           +--------------------+
               |                               |
               v                               v
     [ Physical Storage ]             [ TCP/IP / RDMA Engine ]
                                               |
                                               v (Replication Link)
                                      [ Remote Node DRBD ]
```

#### Protocolos de Replicación:
* **Protocol A (Asíncrono):** La E/S de escritura local se completa tan pronto como los datos se escriben en el disco local y se envían al buffer de envío TCP local. Alto rendimiento a través de WAN; potencial pérdida de datos en caso de caída del Primary.
* **Protocol B (Síncrono en Memoria):** La E/S de escritura local se completa una vez que finaliza la escritura en el disco local y el paquete llega al buffer de red del peer remoto (RAM). Protege contra la pérdida de energía en un solo nodo, vulnerable a fallos en ambos nodos.
* **Protocol C (Síncrono):** La E/S de escritura se confirma a la aplicación *solo* después de confirmarse la finalización de la escritura en el disco local **Y** en el disco remoto. RPO (Recovery Point Objective) igual a cero; la latencia está directamente vinculada al Round Trip Time (RTT) de la red.

---

### 1.2 Pasos de Ejecución Guiados

#### Paso 1: Sintetizar la Configuración del Recurso DRBD
En ambos nodos (`node1.example.com` - 192.168.1.10, `node2.example.com` - 192.168.1.11), cree el manifiesto de recurso `/etc/drbd.d/r0.res`:

```conf
# /etc/drbd.d/r0.res
resource r0 {
    protocol C;

    startup {
        wfc-timeout 15;
        degr-wfc-timeout 60;
        become-primary-on both; # Enables Dual-Primary for Clustered File Systems
    }

    net {
        fencing resource-only;
        max-buffers 8000;
        max-epoch-size 8000;
        sndbuf-size 512k;
        rcvbuf-size 512k;
        allow-two-primaries yes;
        after-sb-0pri discard-younger-primary;
        after-sb-1pri discard-secondary;
        after-sb-2pri call-pri-lost-after-sb;
    }

    disk {
        on-io-error detach;
        disk-flushes yes;
        md-flushes yes;
    }

    on node1.example.com {
        node-id 0;
        device    /dev/drbd0;
        disk      /dev/sdb;
        meta-disk internal;
        address   192.168.1.10:7788;
    }

    on node2.example.com {
        node-id 1;
        device    /dev/drbd0;
        disk      /dev/sdb;
        meta-disk internal;
        address   192.168.1.11:7788;
    }
}
```

#### Paso 2: Inicializar los Metadatos de DRBD y Vincular el Recurso
Ejecute en **ambos nodos**:

```bash
sudo drbdadm create-md r0
sudo drbdadm up r0
```

*Salida Esperada (`node1`):*
```text
Initializing script initializing node-id 0...
Writing meta data...
New DRBD meta block successfully created.
```

#### Paso 3: Forzar el Origen de Sincronización Inicial en Node1
Ejecute en `node1`:

```bash
sudo drbdadm primary --force r0
```

Verifique el estado de la replicación utilizando `drbdadm status`:

```bash
sudo drbdadm status r0
```

*Salida Esperada:*
```text
r0 role:Primary
  disk:UpToDate
  node2 role:Secondary
    peer-disk:UpToDate
```

#### Paso 4: Simular un Escenario de Split-Brain
Un Split-Brain ocurre cuando la comunicación de red falla mientras ambos nodos permanecen en línea, lo que hace que ambos nodos pasen al rol `Primary` y procesen escrituras locales divergentes.

1. Interrumpa la interfaz de red en `node2` temporalmente o fuerce la desconexión de red:
   ```bash
   sudo drbdadm disconnect r0
   ```
2. Fuerce a `node2` al rol Primary y escriba en `/dev/drbd0`:
   ```bash
   sudo drbdadm primary --force r0
   sudo dd if=/dev/urandom of=/dev/drbd0 bs=1M count=10 seek=1 conv=notrunc
   ```
3. Escriba datos en conflicto en `node1` mientras está en rol Primary:
   ```bash
   sudo dd if=/dev/urandom of=/dev/drbd0 bs=1M count=10 seek=20 conv=notrunc
   ```
4. Intente reconectar los nodos:
   ```bash
   sudo drbdadm connect r0
   ```
5. Observe la salida de diagnóstico de Split-Brain:
   ```bash
   sudo drbdadm status r0
   ```

*Salida de Terminal Esperada (estado de Split-Brain):*
```text
r0 role:Primary
  disk:UpToDate
  node2 connection:StandAlone
```
*Log del Kernel (`dmesg | tail -n 15`):*
```text
drbd r0: Split-Brain detected, dropping connection!
drbd r0: Helper process returned 7 (split-brain detected)
drbd r0: conn( Unconnected ) -> conn( StandAlone )
```

#### Paso 5: Ejecutar la Recuperación Manual de Split-Brain (Víctima vs Superviviente)
Designe `node2` como la **Víctima** (datos sobrescritos) y `node1` como el **Superviviente** (fuente autoritativa).

En la **Víctima (`node2`)**:
```bash
sudo drbdadm secondary r0
sudo drbdadm connect --discard-my-data r0
```

En el **Superviviente (`node1`)**:
```bash
sudo drbdadm connect r0
```

Verifique el estado en `node1` mientras se completa la resincronización:
```bash
sudo drbdadm status r0
```

*Salida Esperada:*
```text
r0 role:Primary
  disk:UpToDate
  node2 role:Secondary
    replication:SyncSource peer-disk:Inconsistent done:45.32%
```

---

### 1.3 Preguntas de Verificación (Ejercicio 1)

1. In DRBD Protocol C, at what exact instant is a `write()` system call acknowledged as complete to the application process?
   - A) When written to the local disk kernel page cache.
   - B) When sent over the local TCP socket buffer.
   - C) When written to local disk AND received in remote RAM.
   - D) When written to local non-volatile storage AND committed to remote physical disk.

2. A DRBD cluster reports `cstate:StandAlone` with kernel logs stating `Split-Brain detected`. What command must be executed on the victim node first to initiate recovery?
   - A) `drbdadm primary --force r0`
   - B) `drbdadm secondary r0` followed by `drbdadm connect --discard-my-data r0`
   - C) `drbdmeta /dev/sdb v09 apply-al`
   - D) `drbdadm invalidate r0`

---

## Ejercicio 2: Acceso a Almacenamiento en Cluster — iSCSI Target, Initiator y Multipath I/O

### 2.1 Mecánica Técnica Profunda y Arquitectura

iSCSI envuelve SCSI Command Descriptor Blocks (CDBs) dentro de paquetes TCP/IP (puerto 3260). El almacenamiento SAN de alta disponibilidad se basa en múltiples rutas de red físicas distintas entre el Initiator (Cliente) y el Target (Servidor de Almacenamiento).

```
+---------------------------------------------------------------+
|                       Linux Kernel Block Layer                |
|                           (/dev/dm-0)                         |
+---------------------------------------------------------------+
                                |
                   +------------+------------+
                   |  dm-multipath (multipathd) |
                   +------------+------------+
                                |
             +------------------+------------------+
             |                                     |
             v                                     v
   +-------------------+                 +-------------------+
   | /dev/sdb (Path A) |                 | /dev/sdc (Path B) |
   | Network Interface 1                 | Network Interface 2
   +---------+---------+                 +---------+---------+
             |                                     |
             +------------------+------------------+
                                |
                                v
                   [ Storage Array / iSCSI Target ]
                   [ ALUA State: Active / Optimized]
```

* **Target Port Groups (TPG):** Agrupaciones lógicas de direcciones IP de target, portales y LUNs.
* **ALUA (Asymmetrical Logical Unit Access):** Permite a las cabinas de almacenamiento informar a `multipathd` sobre rutas activas/optimizadas frente a rutas pasivas/no optimizadas.
* **Path Checkers:** `multipathd` comprueba periódicamente las rutas mediante comandos SCSI (`tur` - Test Unit Ready, `directio` o `readsector0`).

---

### 2.2 Pasos de Ejecución Guiados

#### Paso 1: Configurar iSCSI Target mediante `targetcli` (Nodo de Almacenamiento)
Ejecute `targetcli` para exportar un dispositivo de bloques local `/dev/vg_san/lv_shared` al initiator `iqn.2026-08.com.example:node1`:

```bash
sudo targetcli
```

Dentro de la shell interactiva de `targetcli`, ejecute:

```text
/> cd /backstores/block
/backstores/block> create name=shared_block dev=/dev/vg_san/lv_shared
/backstores/block> cd /iscsi
/iscsi> create iqn.2026-08.com.example:storage.target1
/iscsi> cd iqn.2026-08.com.example:storage.target1/tpg1/
/iscsi/iqn.20...y/tpg1> luns/ create /backstores/block/shared_block
/iscsi/iqn.20...y/tpg1> acls/ create iqn.2026-08.com.example:node1
/iscsi/iqn.20...y/tpg1> portals/ create 192.168.10.50 3260
/iscsi/iqn.20...y/tpg1> portals/ create 192.168.20.50 3260
/iscsi/iqn.20...y/tpg1> cd /
/> saveconfig
/> exit
```

#### Paso 2: Configurar Discovery y Login del Initiator (Nodo Cliente)
En `node1`:
1. Establezca el IQN del initiator en `/etc/iscsi/initiatorname.iscsi`:
   ```conf
   InitiatorName=iqn.2026-08.com.example:node1
   ```
2. Descubra los targets a través de rutas de red duales:
   ```bash
   sudo iscsiadm -m discovery -t sendtargets -p 192.168.10.50:3260
   ```
3. Inicie sesión en todos los portales descubiertos:
   ```bash
   sudo iscsiadm -m node --login
   ```

*Salida Esperada:*
```text
Logging in to [iface: default, target: iqn.2026-08.com.example:storage.target1, portal: 192.168.10.50,3260] (multiple)
Logging in to [iface: default, target: iqn.2026-08.com.example:storage.target1, portal: 192.168.20.50,3260] (multiple)
Login to [iface: default, target: iqn.2026-08.com.example:storage.target1, portal: 192.168.10.50,3260] successful.
Login to [iface: default, target: iqn.2026-08.com.example:storage.target1, portal: 192.168.20.50,3260] successful.
```

#### Paso 3: Configurar `/etc/multipath.conf` para Conmutación por Error en Producción
Sintetice `/etc/multipath.conf` en `node1`:

```conf
# /etc/multipath.conf
defaults {
    user_friendly_names yes
    find_multipaths yes
    enable_foreign "none"
}

blacklist {
    devnode "^sda"
}

multipaths {
    multipath {
        wwid 36001405a1234567890abcdef00000001
        alias mpath_ha_storage
    }
}

devices {
    device {
        vendor "LIO-ORG"
        product "IBLOCK"
        path_grouping_policy group_by_prio
        path_selector "service-time 0"
        path_checker tur
        features "1 queue_if_no_path"
        hardware_handler "1 alua"
        prio alua
        failback immediate
        rr_weight priority
        no_path_retry 12
        fast_io_fail_tmo 5
        dev_loss_tmo 30
    }
}
```

Reinicie y verifique `multipathd`:
```bash
sudo systemctl restart multipathd
sudo multipath -ll
```

*Salida Esperada:*
```text
mpath_ha_storage (36001405a1234567890abcdef00000001) dm-0 LIO-ORG,IBLOCK
size=500G features='1 queue_if_no_path' hwhandler='1 alua' wp=rw
|-+- policy='service-time 0' prio=50 status=active
| `- 3:0:0:0 sdb 8:16 active ready running
`-+- policy='service-time 0' prio=10 status=enabled
  `- 4:0:0:0 sdc 8:32 active ready running
```

---

### 2.3 Preguntas de Verificación (Ejercicio 2)

1. What is the operational impact of setting `features "1 queue_if_no_path"` in `/etc/multipath.conf` when all physical storage paths fail?
   - A) System immediately returns I/O errors (`EIO`) to application processes.
   - B) Application I/O requests are blocked and queued in kernel space until a path recovers or timeouts trigger.
   - C) `multipathd` automatically unmounts the underlying file system.
   - D) The kernel kernel-panics to preserve data integrity.

2. Which command displays full path state, priority values, and ALUA metadata for all multipathing block devices?
   - A) `iscsiadm -m session -P 3`
   - B) `multipath -ll`
   - C) `targetcli ls`
   - D) `lvs -a -o +devices`

---

## Ejercicio 3: Sistemas de Archivos en Cluster de Disco Compartido — GFS2, DLM y OCFS2

### 3.1 Mecánica Técnica Profunda y Arquitectura

Los sistemas de archivos de disco compartido permiten que múltiples nodos lean y escriban de forma concurrente en el mismo dispositivo de bloques físico o virtual. La corrupción de datos se evita mediante el bloqueo distribuido (distributed locking).

```
Node 1                                              Node 2
+-----------------------+                           +-----------------------+
|  GFS2 File System     |                           |  GFS2 File System     |
+-----------------------+                           +-----------------------+
| DLM Kernel Module     |<==== Lock Ping/Ack =======>| DLM Kernel Module     |
| (Lockspace: "cluster")|      (TCP/IP / SCTP)      | (Lockspace: "cluster")|
+-----------------------+                           +-----------------------+
| Journal 0             |                           | Journal 1             |
+-----------------------+                           +-----------------------+
           |                                                   |
           +-------------------------+-------------------------+
                                     |
                                     v
                       [ Shared Block Device ]
                       [ /dev/drbd0 or dm-0  ]
```

* **DLM (Distributed Lock Manager):** Gestiona los bloqueos a nivel de cluster (`lock_dlm`) sobre redes IP a través de la mensajería de cluster de Corosync.
* **Journals de GFS2:** Cada nodo que monta un volumen GFS2 *debe* tener su propio journal dedicado (parámetro `-j`). Los journals rastrean las operaciones de metadatos no confirmadas (uncommitted). Si el Nodo 1 se cae, el Nodo 2 reproduce el journal del Nodo 1 para recuperar la consistencia del sistema de archivos.
* **Requisito de Fencing (STONITH):** STONITH (Shoot The Other Node In The Head) es obligatorio. Si un nodo pierde el quorum del cluster o no responde a las comprobaciones de heartbeat de DLM, se le debe forzar un reinicio eléctrico antes de que pueda ocurrir la recuperación de bloqueos.

---

### 3.2 Pasos de Ejecución Guiados

#### Paso 1: Verificar los Prerrequisitos del Servicio Corosync y DLM
En `node1` y `node2`, asegúrese de que los servicios de cluster de Pacemaker/Corosync estén activos y que el daemon DLM (`dlm_controld`) esté operativo:

```bash
sudo pcs status
```

*Salida Esperada:*
```text
Cluster name: alpha_cluster
Cluster Summary:
  * Stack: corosync
  * Current DC: node1.example.com (version 2.1.5) - partition with quorum
  * 2 nodes online: [ node1.example.com node2.example.com ]

Full List of Resources:
  * clone_dlm    (ocf::pacemaker:controld): Started [ node1.example.com node2.example.com ]
```

#### Paso 2: Formatear el Dispositivo de Bloques Compartido con GFS2
Formatee `/dev/drbd0` desde `node1`. El formato de la tabla es `-t <nombre_cluster>:<nombre_fs>`:

```bash
sudo mkfs.gfs2 -p lock_dlm -t alpha_cluster:shared_data -j 2 /dev/drbd0
```

*Salida Esperada:*
```text
It appears that the device is a DRBD block device.
This will destroy any data on /dev/drbd0.
Are you sure you want to proceed? (y/n) y
Device:                    /dev/drbd0
Block size:                4096
Journals:                  2
Resource groups:           250
Locking protocol:          lock_dlm
Lock table:                alpha_cluster:shared_data
UUID:                      a1b2c3d4-e5f6-7890-abcd-1234567890ab
```

#### Paso 3: Montar GFS2 en Nodos Concurrentes
Ejecute en **ambos `node1` y `node2`**:

```bash
sudo mkdir -p /mnt/shared_gfs2
sudo mount -t gfs2 -o noatime /dev/drbd0 /mnt/shared_gfs2
```

Verifique el estado del montaje:
```bash
findmnt /mnt/shared_gfs2
```

*Salida Esperada (`node1` y `node2`):*
```text
TARGET           SOURCE     FSTYPE OPTIONS
/mnt/shared_gfs2 /dev/drbd0 gfs2   rw,noatime,seclabel
```

#### Paso 4: Agregar Journals para la Expansión del Cluster (`gfs2_jadd`)
Para agregar un 3er nodo (`node3`) al cluster, expanda la cantidad de journals en un nodo montado existente (`node1`):

```bash
sudo gfs2_jadd -j 1 /mnt/shared_gfs2
```

Verifique la configuración actualizada de los journals:
```bash
sudo gfs2_tool journals /mnt/shared_gfs2
```

*Salida Esperada:*
```text
Journal 0: 128MB
Journal 1: 128MB
Journal 2: 128MB
3 journal(s) found.
```

#### Paso 5: Diagnóstico Avanzado de Bloqueos DLM
Inspeccione los lockspaces activos de DLM y los volcados de estado de bloqueos:

```bash
sudo dlm_tool ls
sudo dlm_tool lockdebug alpha_cluster:shared_data
```

*Salida Esperada (`dlm_tool ls`):*
```text
dlm lockspaces
name          alpha_cluster:shared_data
id            0x4b2a8f01
flags         0x00000000
change        member count 2 status dirty
members       1 2
```

---

### 3.3 Preguntas de Verificación (Ejercicio 3)

1. What happens if a node mounting a GFS2 file system suffers a hardware power failure while holding active metadata locks?
   - A) The remaining nodes freeze indefinitely waiting for lock release.
   - B) Corosync triggers fencing (STONITH); once fenced, a surviving node replays the crashed node's dedicated GFS2 journal and releases its locks.
   - C) GFS2 switches to read-only mode across all nodes.
   - D) The file system runs `fsck.gfs2` automatically across all mounted paths live.

2. When formatting a GFS2 file system using `mkfs.gfs2 -p lock_dlm -t cluster_A:data1 -j 4 /dev/sdb`, what does the string `cluster_A:data1` represent?
   - A) The username and password for DLM authentication.
   - B) The Corosync cluster name (`cluster_A`) and unique GFS2 lockspace name (`data1`).
   - C) The target directory path where the device will be mounted.
   - D) The LVM volume group and logical volume identifier.

---

## Ejercicio 4: Almacenamiento Distribuido de Alta Disponibilidad — Arquitectura y Operaciones de GlusterFS

### 4.1 Mecánica Técnica Profunda y Arquitectura

GlusterFS es un sistema de archivos distribuido en espacio de usuario y de escalado horizontal (scale-out) que opera a través de FUSE (Filesystem in Userspace). No utiliza un servidor de metadatos central; la ubicación de los datos se calcula algorítmicamente mediante Elastic Hash Algorithms.

```
                                Client App
                                    |
                            [ FUSE Layer ]
                                    |
                       [ GlusterFS Client Stack ]
                       [ (xlators: AFR, DHT)    ]
                                    |
          +-------------------------+-------------------------+
          | (RPC Port 24007)                                  | (RPC Port 24007)
          v                                                   v
   Node 1 Brick                                        Node 2 Brick
[ /data/brick1/gv0/ ]                               [ /data/brick1/gv0/ ]
[ POSIX FS + XATTR  ]                               [ POSIX FS + XATTR  ]
  trusted.glusterfs.active                            trusted.glusterfs.active
```

#### Componentes Clave y Traductores (xlators):
* **Bricks:** Un punto de montaje de sistema de archivos (ej. XFS) con un directorio de almacenamiento exportado a GlusterFS.
* **AFR (Automatic File Replication):** Maneja la replicación de datos a través de los bricks; mantiene atributos extendidos (`trusted.glusterfs.afr.*`) en los sistemas de archivos POSIX subyacentes para rastrear changelogs de metadatos y datos.
* **glustershd (Self-Heal Daemon):** Daemon en segundo plano ejecutándose en cada nodo que escanea los bricks en busca de changelogs pendientes y repara archivos desincronizados de forma asíncrona.

---

### 4.2 Pasos de Ejecución Guiados

#### Paso 1: Peer Probe e Inicialización del Pool
Desde `node1` (192.168.1.10), agregue `node2` (192.168.1.11) y `node3` (192.168.1.12) al Trusted Storage Pool:

```bash
sudo gluster peer probe 192.168.1.11
sudo gluster peer probe 192.168.1.12
```

Verifique el estado de los peers en el storage pool:
```bash
sudo gluster peer status
```

*Salida Esperada:*
```text
Number of Peers: 2

Hostname: 192.168.1.11
Uuid: 5e6f7a8b-9c0d-1e2f-3a4b-5c6d7e8f9a0b
State: Peer in Cluster (Connected)

Hostname: 192.168.1.12
Uuid: 1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d
State: Peer in Cluster (Connected)
```

#### Paso 2: Crear un Volumen Replicado de 3 Vías en GlusterFS
Cree e inicie el volumen `vol_ha` que abarca los bricks en los 3 nodos:

```bash
sudo gluster volume create vol_ha replica 3 \
  192.168.1.10:/data/brick1/vol_ha \
  192.168.1.11:/data/brick1/vol_ha \
  192.168.1.12:/data/brick1/vol_ha force

sudo gluster volume start vol_ha
```

Configure un quorum estricto para evitar split-brain:
```bash
sudo gluster volume set vol_ha cluster.quorum-type auto
sudo gluster volume set vol_ha cluster.ping-timeout 10
```

Verifique el estado operativo del volumen:
```bash
sudo gluster volume info vol_ha
```

*Salida Esperada:*
```text
Volume Name: vol_ha
Type: Replicate
Volume ID: c3d4e5f6-7a8b-9c0d-1e2f-3a4b5c6d7e8f
Status: Started
Snapshot Count: 0
Number of Bricks: 1 x 3 = 3
Transport-type: tcp
Bricks:
Brick1: 192.168.1.10:/data/brick1/vol_ha
Brick2: 192.168.1.11:/data/brick1/vol_ha
Brick3: 192.168.1.12:/data/brick1/vol_ha
Options Reconfigured:
cluster.ping-timeout: 10
cluster.quorum-type: auto
transport.address-family: inet
nfs.disable: on
performance.client-io-threads: off
```

#### Paso 3: Provocar y Diagnosticar Split-Brain en GlusterFS
Si dos bricks pierden conectividad y reciben escrituras divergentes de forma independiente, el volumen entra en Split-Brain.

1. Inspeccione el estado de split-brain pendiente a través de la CLI:
   ```bash
   sudo gluster volume heal vol_ha info split-brain
   ```

*Salida Esperada (split-brain detectado):*
```text
Brick 192.168.1.10:/data/brick1/vol_ha
<gfid:a4b5c6d7-e8f9-0a1b-2c3d-4e5f6a7b8c9d>
Number of entries: 1

Brick 192.168.1.11:/data/brick1/vol_ha
<gfid:a4b5c6d7-e8f9-0a1b-2c3d-4e5f6a7b8c9d>
Number of entries: 1
```

2. Inspeccione los Atributos Extendidos POSIX (xattrs) subyacentes en la ruta del brick:
   ```bash
   sudo getfattr -d -m "trusted.glusterfs" /data/brick1/vol_ha/file1.dat
   ```

*Salida Esperada:*
```text
# file: data/brick1/vol_ha/file1.dat
trusted.glusterfs.afr.vol_ha-client-0=0x000000000000000000000001
trusted.glusterfs.afr.vol_ha-client-1=0x000000010000000000000000
trusted.glusterfs.version=0x0000000000000001
```

#### Paso 4: Resolver Split-Brain mediante Políticas de CLI
Resuelva el split-brain seleccionando `192.168.1.10` como el archivo fuente autoritativo:

```bash
sudo gluster volume heal vol_ha split-brain source-brick 192.168.1.10:/data/brick1/vol_ha /file1.dat
```

*Salida Esperada:*
```text
Healing /file1.dat localized on 192.168.1.10:/data/brick1/vol_ha ... Success
```

Fuerce la verificación de autorreparación (self-healing) en segundo plano:
```bash
sudo gluster volume heal vol_ha
```

---

### 4.3 Preguntas de Verificación (Ejercicio 4)

1. How does GlusterFS track file modifications and pending sync operations across bricks without a central database?
   - A) By logging writes in `/var/log/glusterfs/glusterd.log`.
   - B) By writing metadata into POSIX Extended Attributes (`trusted.glusterfs.afr.*`) directly on file headers inside brick storage paths.
   - C) By keeping changes exclusively in host RAM caches.
   - D) By storing state in an external Etcd cluster.

2. Which GlusterFS volume option guarantees that a 3-way replicated volume blocks all client write operations if fewer than 2 nodes are active, avoiding split-brain?
   - A) `cluster.self-heal-daemon off`
   - B) `cluster.quorum-type auto`
   - C) `performance.stat-prefetch off`
   - D) `features.shard on`

---

## Ejercicio 5: Almacenamiento Empresarial Distribuido de Objetos y Bloques — Arquitectura y Operaciones de Ceph

### 5.1 Mecánica Técnica Profunda y Arquitectura

Ceph proporciona almacenamiento de objetos (RADOS), bloques (RBD) y archivos (CephFS) respaldado por un motor autónomo de almacenamiento de objetos con autorreparación.

```
+-------------------------------------------------------------------+
|               Ceph Storage Applications / Clients                 |
+-------------------+-----------------------+-----------------------+
|  RADOS Gateway    |  RADOS Block Device   |  CephFS File System   |
|   (S3 / Swift)    |      (RBD Kernel)     |      (MDS Daemon)     |
+-------------------+-----------------------+-----------------------+
                                |
                                v
+-------------------------------------------------------------------+
|                        RADOS Cluster Layer                        |
|                                                                   |
|   +-------------------+  +-------------------+  +-------------+   |
|   | Ceph MON (Paxos)  |  | Ceph MGR (Metrics)|  | CRUSH Engine|   |
|   +-------------------+  +-------------------+  +-------------+   |
|                                                                   |
|   [OSD.0]        [OSD.1]        [OSD.2]        [OSD.3]        ... |
+-------------------------------------------------------------------+
```

#### Subsistemas Principales:
* **Ceph MON (Monitors):** Mantiene el estado maestro del mapa del cluster (mon map, osd map, pg map, crush map) utilizando el algoritmo de consenso Paxos. Requiere un número impar de MONs ($N/2 + 1$) para el quorum.
* **Ceph OSD (Object Storage Daemon):** Gestiona el almacenamiento en disco local (motor BlueStore), responde a las llamadas de lectura/escritura de los clientes, maneja la replicación, el scrubbing y la recuperación.
* **Algoritmo CRUSH (Controlled Replication Under Scalable Hashing):** Elimina las búsquedas de metadatos centrales. Los clientes calculan los IDs exactos del OSD de destino de forma determinista mediante reglas CRUSH basadas en el nombre del objeto y la topología del mapa del cluster.
* **Placement Groups (PGs):** Agregaciones lógicas de objetos mapeados a conjuntos de OSDs de destino.
  * *Estados del Ciclo de Vida de los PG:* `active+clean` -> `peering` -> `degraded` -> `recovering` -> `undersized` -> `inconsistent`.

---

### 5.2 Pasos de Ejecución Guiados

#### Paso 1: Inspección de Salud y Verificación del Quorum Paxos de los MON
Ejecute comandos de CLI para la inspección de salud del cluster:

```bash
sudo ceph -s
sudo ceph quorum_status --format json-pretty
```

*Salida Esperada (`ceph -s`):*
```text
  cluster:
    id:     7f3a8b2c-1e4d-5f6a-8b0c-9d8e7f6a5b4c
    health: HEALTH_OK

  services:
    mon: 3 daemons, quorum mon1,mon2,mon3 (age 2d)
    mgr: mon1(active, since 2d), standbys: mon2
    osd: 6 osds: 6 up, 6 in

  data:
    pools:   2 pools, 64 pgs
    objects: 1.25k objects, 4.8 GiB
    usage:   14.6 GiB used, 585 GiB / 600 GiB avail
    pgs:     64 active+clean
```

#### Paso 2: Crear Pool de OSDs y Mapear Dispositivo de Bloques RADOS (RBD)
Cree un pool replicado llamado `pool_ha` con 64 PGs y aprovisione una imagen de bloques RBD:

```bash
sudo ceph osd pool create pool_ha 64 64 replicated
sudo ceph osd pool application enable pool_ha rbd
rbd create --size 10240 pool_ha/vol_block_01
rbd info pool_ha/vol_block_01
```

*Salida Esperada (`rbd info`):*
```text
rbd image 'vol_block_01':
	size 10 GiB in 2560 objects
	order 22 (4 MiB objects)
	snapshot_count: 0
	id: 4f1a2b3c4d5e
	block_name_prefix: rbd_data.4f1a2b3c4d5e
	format: 2
	features: layering, exclusive-lock, object-map, fast-diff, deep-flatten
	op_features: 
	flags: 
	create_timestamp: Thu Aug  6 17:14:39 2026
```

Mapee la imagen RBD en el espacio del kernel como `/dev/rbd0`:
```bash
sudo rbd map pool_ha/vol_block_01
lsblk /dev/rbd0
```

*Salida Esperada:*
```text
NAME lg-size major:minor ro size type mountpoint
rbd0          252:0        0  10G disk 
```

#### Paso 3: Simular la Degradación de OSD y Rastrear la Máquina de Estados de PG
1. Fuerce la detención del daemon `osd.2` para activar el estado degradado:
   ```bash
   sudo systemctl stop ceph-osd@2
   ```
2. Monitoree las transiciones de salud:
   ```bash
   sudo ceph health detail
   ```

*Salida Esperada:*
```text
HEALTH_WARN 1 osds down; 16 pgs degraded; 16 pgs undersized
[WRN] OSD_DOWN: 1 osds down
    osd.2 (root=default,host=node2) is down
[WRN] PG_DEGRADED: Degraded data redundancy: 16/64 pgs degraded
    pg 2.1a is stuck degraded for 45s, act: [2,0] -> [0]
```

3. Consulte los detalles internos de metadatos de un PG específico:
   ```bash
   sudo ceph pg 2.1a query
   ```

#### Paso 4: Detectar y Reparar Placement Groups Inconsistentes (Scrubbing)
Si ocurre una corrupción silenciosa de datos en un OSD, el scrubbing marca el PG como `inconsistent`.

```bash
sudo ceph pg deep-scrub 2.1a
sudo ceph health detail
```

*Salida Esperada (Si existe corrupción silenciosa):*
```text
HEALTH_ERR 1 pgs inconsistent; 1 scrub errors
[ERR] PG_DAMAGED: Possible data damaged on 1 pgs
    pg 2.1a is active+clean+inconsistent, acting [0,1,3]
```

Ejecute la reparación en línea del PG:
```bash
sudo ceph pg repair 2.1a
```

*Salida Esperada:*
```text
instructing pg 2.1a on osd.0 to repair
```

Verifique que el estado vuelva a limpio (clean):
```bash
sudo ceph pg stat
```

*Salida Esperada:*
```text
64 pgs: 64 active+clean; 4.8 GiB data, 14.6 GiB used, 585 GiB / 600 GiB avail
```

---

### 5.3 Preguntas de Verificación (Ejercicio 5)

1. In a Ceph cluster with 3 Monitor nodes (MONs), what is the minimum number of MON daemons that must remain online and communicating to maintain Paxos consensus and process client requests?
   - A) 1
   - B) 2
   - C) 3
   - D) 0 (MONs are only needed during initial bootstrap)

2. How does the Ceph client library determine which specific OSD to contact when writing object `obj_data_001`?
   - A) It sends an ARP broadcast to find the master MON node address.
   - B) It queries an active Redis instance storing object metadata.
   - C) It passes the object name and CRUSH map locally through the CRUSH algorithm to calculate the target OSD ID deterministically.
   - D) It sends write operations sequentially to `osd.0`, which redirects them.

---

<details>
<summary><strong>Soluciones y Explicaciones</strong></summary>

### Soluciones del Ejercicio 1
* **1.1 Respuesta: D**  
  *Explicación:* En DRBD Protocol C, las operaciones de escritura son completamente síncronas. La capa de bloques del kernel local no devuelve la confirmación de escritura a la aplicación demandante hasta que finalice la E/S de almacenamiento local **Y** el peer remoto confirme que los datos se han guardado en el almacenamiento de disco no volátil.
* **1.2 Respuesta: B**  
  *Explicación:* Cuando DRBD detecta Split-Brain, el recurso pasa al estado `StandAlone`. Para resolver este estado manualmente, el administrador selecciona el nodo víctima, lo degrada a `secondary` si es necesario y ejecuta `drbdadm connect --discard-my-data <recurso>`. Posteriormente, conectar el nodo superviviente activa la sincronización del superviviente a la víctima.

---

### Soluciones del Ejercicio 2
* **2.1 Respuesta: B**  
  *Explicación:* La función `queue_if_no_path` (equivalente a `no_path_retry`) indica a `multipathd` que encole las peticiones de E/S de bloques entrantes de la aplicación en la memoria del kernel durante una pérdida total de rutas, en lugar de hacer fallar las escrituras inmediatamente con `EIO`.
* **2.2 Respuesta: B**  
  *Explicación:* `multipath -ll` analiza los dispositivos del kernel `/sys/class/san_path` y `dm-multipath`, mostrando las rutas activas, los estados de las rutas (`active`, `enabled`, `failed`), los valores de prioridad y los estados del target group de las rutas ALUA.

---

### Soluciones del Ejercicio 3
* **3.1 Respuesta: B**  
  *Explicación:* GFS2 requiere un mecanismo de fencing obligatorio (STONITH). Cuando un nodo se cae, Pacemaker/Corosync aisla y apaga el nodo fallido. Una vez que DLM recibe la confirmación de fencing, un nodo superviviente del cluster accede al journal de GFS2 dedicado del nodo caído, reproduce los metadatos no confirmados y libera los bloqueos huérfanos.
* **3.2 Respuesta: B**  
  *Explicación:* El parámetro `-t <nombre_cluster>:<nombre_fs>` pasado a `mkfs.gfs2` especifica el identificador de cluster Corosync (`cluster_A`) y la tabla de lockspace distinta (`data1`) a la que se vincula DLM al gestionar el estado de bloqueo entre nodos.

---

### Soluciones del Ejercicio 4
* **4.1 Respuesta: B**  
  *Explicación:* GlusterFS utiliza Atributos Extendidos POSIX (xattrs) como `trusted.glusterfs.afr.*` almacenados directamente en los directorios/archivos locales de los bricks para rastrear los changelogs pendientes de datos, metadatos y entradas para la autorreparación (self-healing).
* **4.2 Respuesta: B**  
  *Explicación:* `cluster.quorum-type auto` activa la verificación de quorum en el lado del servidor. En un volumen replicado de 3 vías, si el recuento de nodos activos cae por debajo de $\lfloor N/2 \rfloor + 1 = 2$, GlusterFS rechaza la E/S de escritura para evitar la creación de split-brain.

---

### Soluciones del Ejercicio 5
* **5.1 Respuesta: B**  
  *Explicación:* Los MON de Ceph utilizan el consenso Paxos. Mantener el quorum requiere una mayoría estricta de nodos: $Q = \lfloor N/2 \rfloor + 1$. Para $N=3$, $Q = \lfloor 3/2 \rfloor + 1 = 2$.
* **5.2 Respuesta: C**  
  *Explicación:* Ceph elimina los cuellos de botella de metadatos centrales. Los clientes de Ceph calculan la ubicación de los objetos aplicando hashing a los identificadores de objetos para obtener IDs de Placement Group (PG) y pasando el resultado, junto con el mapa de cluster actual, a través del algoritmo local CRUSH (Controlled Replication Under Scalable Hashing).

</details>

---

## Citas Técnicas y Referencias Oficiales

* **Linux Professional Institute (LPI) LPIC-3 306 Objectives:** [https://www.lpi.org/our-certifications/lpic-3-306-overview/](https://www.lpi.org/our-certifications/lpic-3-306-overview/)
* **LINBIT DRBD 9.0 Official User's Guide:** [https://docs.linbit.com/docs/users-guide-9.0/](https://docs.linbit.com/docs/users-guide-9.0/)
* **Red Hat Enterprise Linux 9 - Configuring and Managing Storage Devices (iSCSI & Multipath):** [https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/managing_storage_devices/](https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/managing_storage_devices/)
* **Red Hat Enterprise Linux 9 - GFS2 File System Architecture and Administration:** [https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/global_file_system_2/](https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/global_file_system_2/)
* **GlusterFS Architecture & Operations Documentation:** [https://docs.gluster.org/en/latest/Architecture/](https://docs.gluster.org/en/latest/Architecture/)
* **Ceph Storage Architecture & Operations Manual:** [https://docs.ceph.com/en/latest/architecture/](https://docs.ceph.com/en/latest/architecture/)