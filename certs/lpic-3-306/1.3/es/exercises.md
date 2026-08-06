# LPIC-3 Exam 306-300 (v3.0) — Topic 306.3: High Availability Distributed Storage

**Peso:** 25  
**Fuentes Oficiales de Referencia:**
* [LPI LPIC-3 Exam 306-300 Objectives Overview](https://www.lpi.org/our-certifications/lpic-3-306-overview/)
* [Ceph Storage Documentation](https://docs.ceph.com/en/latest/)
* [GlusterFS Architecture & Administration Manual](https://docs.gluster.org/en/latest/)
* [LINBIT DRBD 9.0 User Guide](https://linbit.com/drbd-user-guide/drbd-guide-9_0-en/)

---

## Ejercicio 1: Inicialización de Clúster Ceph, Ingeniería de Reglas CRUSH y Recuperación Diagnóstica de BlueStore

### Descripción General de Arquitectura y Mecánica
Ceph logra alta disponibilidad y almacenamiento escalable de objetos/bloques/archivos a través del algoritmo **Controlled Replication Under Scalable Hashing (CRUSH)**. A diferencia de los clústeres de almacenamiento tradicionales que se basan en una tabla de búsqueda de metadatos centralizada, los clientes de Ceph calculan las ubicaciones de los objetos directamente utilizando un cálculo determinista de CRUSH basado en:
1. El ID del objeto (Object ID).
2. El mapeo al **Placement Group (PG)** de destino ($PG\_ID = hash(object\_name) \pmod {num\_pgs}$).
3. La **jerarquía del mapa CRUSH** del clúster y las **reglas CRUSH** definidas.

Los nodos de almacenamiento ejecutan **Ceph Object Storage Daemons (OSDs)** utilizando el motor backend **BlueStore**, el cual gestiona directamente dispositivos de bloques crudos (raw block devices) a través de `RocksDB` (para metadatos y registros de escritura anticipada o write-ahead logs) y `BlueFS` (un sistema de archivos interno mínimo que respalda a RocksDB), omitiendo la caché de páginas de Linux y la capa de sistema de archivos virtual (VFS) para eliminar la sobrecarga de journaling a nivel de sistema de archivos. El cuórum del clúster y el consenso de estado (mapas de OSD, mapas de Monitor, mapas de PG) son mantenidos por **Ceph Monitors (MONs)** que ejecutan un protocolo de consenso distribuido basado en Paxos.

```
+-------------------------------------------------------------------------+
|                              Ceph Client                                |
|   1. Hash Object ID ---> 2. Map to PG ---> 3. CRUSH calculation OSD Set |
+-------------------------------------------------------------------------+
                                    |
                                    v
+-------------------------------------------------------------------------+
|                          Ceph Storage Cluster                           |
|  +-------------------+  +-------------------+  +---------------------+  |
|  | OSD.0 (Primary)   |  | OSD.1 (Secondary) |  | OSD.2 (Tertiary)    |  |
|  | +---------------+ |  | +---------------+ |  | +-----------------+ |  |
|  | | BlueStore Engine|  | | BlueStore Engine|  | | BlueStore Engine| |  |
|  | | - RocksDB     | |  | | - RocksDB     | |  | | - RocksDB       | |  |
|  | | - BlueFS      | |  | | - BlueFS      | |  | | - BlueFS        | |  |
|  | +---------------+ |  | +---------------+ |  | +-----------------+ |  |
|  +-------------------+  +-------------------+  +---------------------+  |
+-------------------------------------------------------------------------+
```

---

### Pasos de Ejecución

1. Inspeccionar el estado de los demonios de Ceph en ejecución y el estado de salud a través de los nodos.
   ```bash
   sudo ceph health detail
   ```
   *Salida Esperada:*
   ```text
   HEALTH_OK
   ```

2. Obtener la estructura de árbol activa de OSD para identificar la jerarquía del dominio de falla (root, rack, host).
   ```bash
   sudo ceph osd tree
   ```
   *Salida Esperada:*
   ```text
   ID  CLASS  WEIGHT   TYPE NAME           STATUS  REWEIGHT  PRIO-SET
   -1         0.23999  root default                                  
   -3         0.07999      rack rack1                                
   -2         0.07999          host node01                           
    0   ssd   0.03999              osd.0       up   1.00000   1.00000
    1   ssd   0.03999              osd.1       up   1.00000   1.00000
   -4         0.07999      rack rack2                                
   -5         0.07999          host node02                           
    2   ssd   0.03999              osd.2       up   1.00000   1.00000
    3   ssd   0.03999              osd.3       up   1.00000   1.00000
   -6         0.07999      rack rack3                                
   -7         0.07999          host node03                           
    4   ssd   0.03999              osd.4       up   1.00000   1.00000
    5   ssd   0.03999              osd.5       up   1.00000   1.00000
   ```

3. Exportar el mapa CRUSH compilado, descompilarlo a texto plano e inspeccionar las reglas de ubicación por defecto.
   ```bash
   sudo ceph osd getcrushmap -o /tmp/crushmap.bin
   crushtool -d /tmp/crushmap.bin -o /tmp/crushmap.txt
   cat /tmp/crushmap.txt | grep -A 8 "rule replicated_ruleset"
   ```
   *Salida Esperada:*
   ```text
   rule replicated_ruleset {
           id 0
           type replicated
           step take default
           step chooseleaf firstn 0 type host
           step emit
   }
   ```

4. Crear una regla CRUSH personalizada llamada `rack_aware_rule` que fuerce la replicación de datos a través de **racks** distintos en lugar de hosts individuales.
   ```bash
   sudo ceph osd crush rule create-replicated rack_aware_rule default rack ssd
   sudo ceph osd crush rule ls
   ```
   *Salida Esperada:*
   ```text
   replicated_ruleset
   rack_aware_rule
   ```

5. Crear un pool de almacenamiento dedicado llamado `production_data` configurado con 64 PGs y asignarle la regla `rack_aware_rule`.
   ```bash
   sudo ceph osd pool create production_data 64 64 replicated rack_aware_rule
   sudo ceph osd pool set production_data size 3
   sudo ceph osd pool set production_data min_size 2
   ```

6. Verificar los parámetros del pool y el mapeo operativo de PGs.
   ```bash
   sudo ceph osd pool get production_data all | egrep "size|crush_rule"
   ```
   *Salida Esperada:*
   ```text
   size: 3
   min_size: 2
   crush_rule: rack_aware_rule
   ```

7. Simular una falla de hardware marcando `osd.0` como down y out del clúster, luego observar las transiciones de estado del PG durante el peering de pares y la recuperación por backfill.
   ```bash
   sudo ceph osd down osd.0
   sudo ceph osd out osd.0
   sudo ceph -w
   ```
   *Salida Esperada:*
   ```text
   2026-08-06 17:30:10.102938 mon.node01 osd.0 line 1: osd.0 is down
   2026-08-06 17:30:12.482019 mon.node01 pgmap v4021: 64 pgs: 64 active+clean; 0B data, 1.2GiB used, 240GiB / 241GiB avail
   2026-08-06 17:30:15.892019 mon.node01 pgmap v4022: 64 pgs: 12 active+undersized+degraded, 52 active+clean
   2026-08-06 17:30:22.110293 mon.node01 pgmap v4025: 64 pgs: 12 active+remapped+backfilling, 52 active+clean
   2026-08-06 17:30:35.402111 mon.node01 pgmap v4030: 64 pgs: 64 active+clean
   ```

8. Inspeccionar los metadatos de BlueStore y las estadísticas de asignación de bloques para un OSD saludable específico (`osd.1`).
   ```bash
   sudo ceph-volume lvm list /dev/sdb
   sudo ceph osd metadata 1 | jq '{id, bluefs_dedicated_db, osd_data, storage_backend}'
   ```
   *Salida Esperada:*
   ```json
   {
     "id": 1,
     "bluefs_dedicated_db": "1",
     "osd_data": "/var/lib/ceph/osd/ceph-1",
     "storage_backend": "bluestore"
   }
   ```

---

### Preguntas de Verificación

#### Pregunta 1.1
Un administrador de clúster Ceph crea un pool con `size = 3` y `min_size = 2`. Debido a una partición de red, dos de los tres OSDs que contienen réplicas de un PG específico quedan inalcanzables. El OSD primario restante tiene aplicado `min_size = 2`. ¿Cuál es el comportamiento preciso de escritura del cliente para las peticiones de E/S (I/O) dirigidas a este PG y por qué?

#### Pregunta 1.2
En un OSD respaldado por BlueStore, ¿qué rol específico cumple `RocksDB`, qué componente almacena los datos de `RocksDB` si no se proporciona una unidad rápida NVMe dedicada, y qué herramienta de diagnóstico proporciona información sobre el espacio de asignación de dispositivos en BlueFS?

---

## Ejercicio 2: Aprovisionamiento de Volúmenes Distribuidos-Replicados en GlusterFS y Mecánica de Recuperación de Split-Brain

### Descripción General de Arquitectura y Mecánica
GlusterFS es un sistema de archivos de clúster en espacio de usuario de escalabilidad horizontal (scale-out) que opera a través de FUSE (Filesystem in Userspace). Abstrae sistemas de archivos locales subyacentes (XFS) en servidores de almacenamiento (**Bricks**) en un espacio de nombres unificado sin servidores de metadatos centralizados. El comportamiento del volumen se rige por una pila de unidades modulares llamadas **Translators (xlators)**:

1. **Protocol/client translator**: Gestiona el transporte de red mediante TCP/IP o RDMA.
2. **AFR (Automatic File Replication) translator**: Implementa replicación sincrónica a nivel de archivos, bloqueos y actualizaciones de atributos extendidos (`xattr`) (`trusted.afr.<volume>-client-*`).
3. **DHT (Distributed Hash Table) translator**: Mapea nombres de archivos a pares de bricks específicos utilizando hashing consistente sobre un espacio de suma de comprobación (checksum) de 32 bits.

Cuando ocurre una partición de red entre bricks en un volumen replicado, las escrituras concurrentes en el mismo archivo en ambas particiones corrompen los registros de cambios de atributos extendidos, lo que resulta en un estado de **Split-Brain**. GlusterFS previene lecturas de datos inconsistentes bloqueando el acceso de E/S (I/O) a los archivos afectados hasta que se realice una resolución manual o basada en políticas utilizando la cadena de herramientas `gluster volume heal` o la modificación de atributos extendidos (`attr` / `setfattr`).

```
+-------------------------------------------------------------------+
|                        GlusterFS Client                           |
|  +-------------------------------------------------------------+  |
|  | DHT Translator (Distributes files across brick subvolumes)  |  |
|  +-------------------------------------------------------------+  |
|         |                                        |                |
|         v                                        v                |
|  +--------------------------+         +--------------------------+|
|  | AFR Translator (Replica 1)|         | AFR Translator (Replica 2)||
|  +--------------------------+         +--------------------------+|
+-------------------------------------------------------------------+
       |                  |                    |                  |
       v                  v                    v                  v
+--------------+   +--------------+     +--------------+   +--------------+
| Node1: Brick1|   | Node2: Brick2|     | Node3: Brick3|   | Node4: Brick4|
| (Subvol 0)   |   | (Subvol 0)   |     | (Subvol 1)   |   | (Subvol 1)   |
+--------------+   +--------------+     +--------------+   +--------------+
```

---

### Pasos de Ejecución

1. Verificar la conectividad de los pares en el pool de almacenamiento de confianza (trusted storage pool) de GlusterFS a través de cuatro nodos (`node01` a `node04`).
   ```bash
   sudo gluster peer status
   ```
   *Salida Esperada:*
   ```text
   Number of Peers: 3

   Hostname: node02
   Uuid: 8f4a100a-4d22-411a-a92d-904d9b1092a1
   State: Peer in Cluster (Connected)

   Hostname: node03
   Uuid: 7b311c12-32a1-432d-b102-109238471ad2
   State: Peer in Cluster (Connected)

   Hostname: node04
   Uuid: c410a991-0193-4a11-821c-99120485912a
   State: Peer in Cluster (Connected)
   ```

2. Aprovisionar un volumen de GlusterFS **Distribuido-Replicado** llamado `vol_ha` compuesto por 4 bricks (2 subvolúmenes con 2 réplicas cada uno).
   ```bash
   sudo gluster volume create vol_ha replica 2 \
     node01:/data/glusterfs/brick1/b1 \
     node02:/data/glusterfs/brick2/b1 \
     node03:/data/glusterfs/brick3/b1 \
     node04:/data/glusterfs/brick4/b1 \
     force
   sudo gluster volume start vol_ha
   ```
   *Salida Esperada:*
   ```text
   volume create: vol_ha: success: please start the volume to access data
   volume start: vol_ha: success
   ```

3. Configurar el cuórum de red en el volumen para mitigar escenarios de split-brain automáticamente cuando los nodos se desconecten.
   ```bash
   sudo gluster volume set vol_ha cluster.quorum-type auto
   sudo gluster volume set vol_ha cluster.quorum-reads false
   sudo gluster volume set vol_ha network.ping-timeout 10
   ```
   *Salida Esperada:*
   ```text
   volume set: success
   volume set: success
   volume set: success
   ```

4. Montar el volumen en una máquina cliente utilizando FUSE nativo.
   ```bash
   sudo mkdir -p /mnt/gluster_data
   sudo mount -t glusterfs node01:/vol_ha /mnt/gluster_data
   df -hT /mnt/gluster_data
   ```
   *Salida Esperada:*
   ```text
   Filesystem     Type       Size  Used Avail Use% Mounted on
   node01:/vol_ha fuse.glusterfs  100G  1.2G   99G   2% /mnt/gluster_data
   ```

5. Simular una condición forzada de split-brain: Bloquear el tráfico de red entre `node01` y `node02` usando `iptables` mientras se escriben datos en conflicto en el mismo archivo desde diferentes clientes o directamente en el backend del brick.
   ```bash
   # On node01: append data to target file on Brick 1 directly
   echo "Data block update from Node 01" >> /data/glusterfs/brick1/b1/critical_file.txt
   
   # On node02: append conflicting data to target file on Brick 2 directly
   echo "Data block update from Node 02" >> /data/glusterfs/brick2/b1/critical_file.txt
   ```

6. Inspeccionar el registro del estado de sanación (heal status) para confirmar que GlusterFS ha marcado `critical_file.txt` en estado de split-brain.
   ```bash
   sudo gluster volume heal vol_ha info split-brain
   ```
   *Salida Esperada:*
   ```text
   Brick node01:/data/glusterfs/brick1/b1
   <gfid:a8e8f230-1092-421b-8012-98401928491a>
   /critical_file.txt
   Status: Is in split-brain

   Brick node02:/data/glusterfs/brick2/b1
   <gfid:a8e8f230-1092-421b-8012-98401928491a>
   /critical_file.txt
   Status: Is in split-brain
   Number of entries in split-brain is 1
   ```

7. Resolver el estado de split-brain de manera determinista seleccionando `node01` como el archivo fuente autorizado.
   ```bash
   sudo gluster volume heal vol_ha split-brain source-brick node01:/data/glusterfs/brick1/b1 /critical_file.txt
   ```
   *Salida Esperada:*
   ```text
   Healing /critical_file.txt completed
   ```

8. Verificar la resolución del estado de split-brain.
   ```bash
   sudo gluster volume heal vol_ha info split-brain
   ```
   *Salida Esperada:*
   ```text
   Brick node01:/data/glusterfs/brick1/b1
   Number of entries in split-brain is 0

   Brick node02:/data/glusterfs/brick2/b1
   Number of entries in split-brain is 0
   ```

---

### Preguntas de Verificación

#### Pregunta 2.1
¿Cuáles son los atributos extendidos binarios (`xattrs`) exactos asignados por el translator AFR de GlusterFS a los archivos en los bricks del backend, y cómo determinan sus contadores matriciales en hexadecimal si un archivo requiere una sanación normal versus entrar en un estado de split-brain?

#### Pregunta 2.2
En un volumen de GlusterFS configurado con `replica 3`, ¿cómo afecta la habilitación de `cluster.reserve-quorum` combinada con un brick `arbiter 1` a la disponibilidad de escritura y la utilización de disco en comparación con una configuración estándar de `replica 3`?

---

## Ejercicio 3: Replicación Sincrónica a Nivel de Bloque con DRBD9 e Integración con Clúster Pacemaker

### Descripción General de Arquitectura y Mecánica
**DRBD (Distributed Replicated Block Device)** opera como un controlador de dispositivo de bloques del kernel de Linux (`drbd.ko`) situado virtualizado por debajo de los sistemas de archivos locales y por encima de los controladores de disco físicos. Sincroniza operaciones de escritura a nivel de bloque fuera de banda a través de enlaces de red entre hosts.

```
+--------------------------------------------------------------------------+
|                              Application                                 |
|                                   |                                      |
|                                   v                                      |
|                            Filesystem (XFS)                              |
+--------------------------------------------------------------------------+
                                    |
                                    v
+--------------------------------------------------------------------------+
|                          DRBD Kernel Module                              |
|   1. Local IO Write -------------------> 2. TCP/IP Network Replication    |
+--------------------------------------------------------------------------+
           |                                                 |
           v                                                 v
+-----------------------+                         +-----------------------+
|  Local Storage Disk   |                         | Remote Storage Disk   |
|  (/dev/sdb1)          |                         | (/dev/sdb1)           |
+-----------------------+                         +-----------------------+
```

DRBD admite tres modos de replicación distintos:
* **Protocolo A (Asincrónico):** La escritura local se completa tan pronto como finaliza la E/S (I/O) en el disco local y el paquete de escritura se coloca en el búfer de transmisión de red local.
* **Protocolo B (Sincrónico en Memoria):** La escritura local se completa cuando finaliza la E/S en el disco local y el paquete de red llega a la memoria del par remoto (búfer del receptor TCP).
* **Protocolo C (Totalmente Sincrónico):** La escritura local se completa ÚNICAMENTE después de que los discos de almacenamiento local y remoto reconozcan la finalización exitosa de la escritura del bloque.

Cuando se integra en clústeres de alta disponibilidad, **Pacemaker** y **Corosync** orquestan los roles primario/secundario de DRBD. Si la comunicación entre nodos se degrada, DRBD se apoya en el mecanismo de fencing (STONITH) de Pacemaker o en su propio manejador `fence-peer` ejecutando el apagado del nodo a nivel de hardware (PDU/IPMI) para evitar condiciones de escritura split-brain en dispositivos de bloques crudos.

---

### Pasos de Ejecución

1. Inspeccionar el archivo de configuración para el recurso DRBD `ha_data` en ambos nodos (`node01` y `node02`).
   ```bash
   cat /etc/drbd.d/ha_data.res
   ```
   *Salida Esperada:*
   ```text
   resource ha_data {
     protocol C;

     net {
       fencing resource-and-stonith;
       csums-alg sha1;
       verify-alg sha1;
       on-congestion pull-ahead;
       congestion-fill-threshold 10G;
       congestion-extents 2000;
     }

     handlers {
       fence-peer "/usr/lib/drbd/crm-fence-peer.9.sh";
       unfence-peer "/usr/lib/drbd/crm-unfence-peer.9.sh";
       split-brain "/usr/lib/drbd/notify-split-brain.sh";
     }

     on node01 {
       node-id 0;
       device /dev/drbd0;
       disk /dev/sdb1;
       meta-disk internal;
       address 192.168.10.11:7788;
     }

     on node02 {
       node-id 1;
       device /dev/drbd0;
       disk /dev/sdb1;
       meta-disk internal;
       address 192.168.10.12:7788;
     }
   }
   ```

2. Inicializar metadatos, habilitar el recurso DRBD y realizar la sincronización inicial forzando a `node01` como la fuente de sincronización primaria.
   ```bash
   # Executed on node01:
   sudo drbdadm create-md ha_data
   sudo drbdadm up ha_data
   sudo drbdadm primary --force ha_data
   ```
   *Salida Esperada:*
   ```text
   Initializing metadata cumulative count 1...
   Storage engine initialized.
   Resource ha_data brought up.
   ```

3. Consultar el estado de replicación de bloques en tiempo real utilizando `drbdadm`.
   ```bash
   sudo drbdadm status ha_data
   ```
   *Salida Esperada:*
   ```text
   ha_data role:Primary
     disk:UpToDate
     node02 role:Secondary
       peer-disk:UpToDate
   ```

4. Crear un sistema de archivos XFS en el dispositivo de bloques `/dev/drbd0` desde `node01`.
   ```bash
   sudo mkfs.xfs /dev/drbd0
   sudo mkdir -p /mnt/ha_block
   sudo mount /dev/drbd0 /mnt/ha_block
   ```

5. Configurar un agente de recursos de clúster Pacemaker para el dispositivo DRBD y el sistema de archivos utilizando `pcs`.
   ```bash
   sudo pcs cluster setup ha_cluster node01 node02 --force
   sudo pcs cluster start --all
   sudo pcs property set stonith-enabled=true
   
   # Create DRBD Data primitive and Master/Slave clone
   sudo pcs resource create DRBD_Data ocf:linbit:drbd \
     drbd_resource=ha_data \
     op monitor interval=60s role="Master" \
     op monitor interval=61s role="Slave"
     
   sudo pcs resource promotable DRBD_Data \
     promoted-max=1 promoted-node-max=1 \
     clone-max=2 clone-node-max=1 \
     notify=true

   # Create Mount primitive
   sudo pcs resource create FS_Data ocf:heartbeat:Filesystem \
     device="/dev/drbd0" \
     directory="/mnt/ha_block" \
     fstype="xfs"

   # Constrain execution order and colocation
   sudo pcs constraint colocation add FS_Data with promoted DRBD_Data-clone INFINITY
   sudo pcs constraint order promote DRBD_Data-clone then start FS_Data
   ```

6. Inspeccionar el estado del clúster Pacemaker para verificar la promoción exitosa a master y el montaje del sistema de archivos.
   ```bash
   sudo pcs status
   ```
   *Salida Esperada:*
   ```text
   Cluster name: ha_cluster
   Cluster Summary:
     * Stack: corosync
     * Current DC: node01 (version 2.1.2) - partition with quorum
     * Last updated: Thu Aug  6 17:45:12 2026
     * 2 nodes configured
     * 3 resource instances configured

   Node List:
     * Online: [ node01 node02 ]

   Full List of Resources:
     * Resource Group:
       * Clone Set: DRBD_Data-clone [DRBD_Data] (promotable):
         * Masters: [ node01 ]
         * Slaves: [ node02 ]
       * FS_Data	(ocf::heartbeat:Filesystem):	Started node01
   ```

7. Simular una falla de nodo en `node01` poniéndolo en modo standby y observar la conmutación por error (failover) automatizada del rol master de DRBD y el montaje del sistema de archivos a `node02`.
   ```bash
   sudo pcs node standby node01
   sudo pcs status
   ```
   *Salida Esperada:*
   ```text
   Node List:
     * Node node01: standby
     * Online: [ node02 ]

   Full List of Resources:
     * Resource Group:
       * Clone Set: DRBD_Data-clone [DRBD_Data] (promotable):
         * Masters: [ node02 ]
         * Stopped: [ node01 ]
       * FS_Data	(ocf::heartbeat:Filesystem):	Started node02
   ```

8. Verificar el estado de DRBD en `node02` para confirmar la promoción a `Primary`.
   ```bash
   sudo drbdadm status ha_data
   ```
   *Salida Esperada:*
   ```text
   ha_data role:Primary
     disk:UpToDate
     node01 connection:Standby
   ```

---

### Preguntas de Verificación

#### Pregunta 3.1
Si un clúster DRBD de dos nodos que opera con `protocol C` sufre una partición de red completa sin STONITH/fencing configurado, y se realizan escrituras independientemente en ambos nodos tras una promoción forzada manual, DRBD entra en un estado de conexión `SplitBrain` al restaurarse la red. ¿Qué pasos exactos y subcomandos de `drbdadm` se requieren para resolver esta condición manualmente y reestablecer la sincronización de replicación?

#### Pregunta 3.2
En un clúster Pacemaker que gestiona un recurso DRBD, ¿cuál es la importancia arquitectónica de configurar `fencing resource-and-stonith;` dentro de `/etc/drbd.d/ha_data.res`, y qué mecanismo exacto previene la corrupción de datos si la replicación nodo a nodo se interrumpe mientras las operaciones de E/S (I/O) están activas?

---

<details>
<summary><b>Haga clic para expandir las Soluciones y Explicaciones Técnicas Detalladas</b></summary>

### Solución: Ejercicio 1 — Ceph

#### Respuesta 1.1
Cuando fallan dos de cada tres OSDs para un PG en un pool con `size = 3` y `min_size = 2`, el OSD activo restante cuenta con solo 1 réplica superviviente. Dado que la cantidad de réplicas saludables disponibles (1) está **por debajo** del requisito estricto impuesto por `min_size` (2), Ceph **bloquea inmediatamente todas las operaciones de E/S (I/O) de escritura del cliente** para ese PG.
* **Mecanismo:** El PG pasa a un estado `active+undersized+degraded` o `active+degraded`, pero se niega a confirmar (commit) nuevas transacciones de escritura en disco.
* **Justificación Arquitectónica:** Este diseño garantiza una consistencia fuerte estricta (CP en el teorema CAP) sobre la disponibilidad. Aceptar escrituras con menos de `min_size` réplicas arriesgaría una pérdida permanente de datos si el único OSD superviviente sufriera una falla irrecuperable de hardware antes de que se completara la recuperación. Las peticiones de lectura del cliente para datos ya confirmados aún pueden completarse, según las configuraciones del clúster, pero las escrituras se detienen hasta que los OSDs pares se recuperen o se anule manualmente el `min_size`.

#### Respuesta 1.2
* **Rol de RocksDB:** En Ceph BlueStore, `RocksDB` almacena todos los metadatos de los OSD. Esto incluye estructuras clave-valor como nombres de objetos, metadatos de PG, mapas de OSD, registros de escritura anticipada (WAL, write-ahead logs) y mapas de asignación para bloques de disco crudos.
* **Almacenamiento de Respaldo:** Si no se especifica un dispositivo de bloques rápido dedicado (como una partición NVMe independiente) para `block.db`, RocksDB almacena sus datos directamente en el dispositivo de bloques primario de BlueStore (`block`) dentro de un sistema de archivos liviano integrado llamado **BlueFS**.
* **Inspección Diagnóstica:** La utilidad de línea de comandos `ceph-bluestore-tool` proporciona información profunda sobre la asignación interna de dispositivos, métricas del sistema de archivos BlueFS y estadísticas de metadatos de RocksDB. Sintaxis de ejemplo:
  ```bash
  sudo ceph-bluestore-tool bluefs-bdev-sizes --path /var/lib/ceph/osd/ceph-1
  ```

---

### Solución: Ejercicio 2 — GlusterFS

#### Respuesta 2.1
* **Atributos Extendidos de AFR:** El translator AFR de GlusterFS utiliza atributos extendidos nativos del sistema de archivos (`xattrs`) bajo el espacio de nombres `trusted.afr.<volume_name>-client-<index>`.
* **Estructura:** Cada brick mantiene un arreglo de atributos que contiene 3 contadores enteros big-endian de 4 bytes distintos (sumando 12 bytes / 24 caracteres hexadecimales):
  1. Bytes 0–3: Contador de modificación de datos.
  2. Bytes 4–7: Contador de metadatos (permisos, propiedad).
  3. Bytes 8–11: Contador de modificación de atributos extendidos.
* **Identificación de Split-Brain:**
  * **Sanación Normal:** El Brick A muestra `000000010000000000000000` (indicando 1 actualización de datos pendiente para el Brick B), mientras que el Brick B muestra `000000000000000000000000`. AFR sabe que el Brick A contiene el archivo actualizado y sincroniza automáticamente los datos al Brick B.
  * **Split-Brain:** El Brick A muestra `000000050000000000000000` (el Brick A fue modificado mientras B estaba fuera de línea) Y el Brick B muestra `000000020000000000000000` (el Brick B fue modificado mientras A estaba fuera de línea). Debido a que ambos bricks reflejan contadores distintos de cero acusando al otro par de haber perdido cambios de datos, AFR no puede determinar qué copia del archivo es autoritativa, bloquea el archivo y marca un **error de Split-Brain**.

#### Respuesta 2.2
* **Disponibilidad de Escritura y Cuórum:** En una configuración `replica 3`, el cuórum requiere una mayoría simple (2 de 3 bricks) para confirmar escrituras. Si 2 bricks fallan, las escrituras se detienen por completo.
* **Mecanismo del Brick Arbiter:** Una configuración `arbiter 1` reemplaza uno de los bricks de datos completos por un brick ligero exclusivo para metadatos (que almacena únicamente nombres de archivos, estructura y `xattrs`, sin contenido de datos real).
* **Beneficios:**
  1. **Optimización del Almacenamiento:** Reduce la huella total de almacenamiento crudo de $3 \times \text{Tamaño de Datos}$ a $2 \times \text{Tamaño de Datos} + \text{Metadatos}$, ahorrando casi un 33% de capacidad total mientras mantiene protección contra split-brain de 3 vías.
  2. **Mitigación de Split-Brain:** Si una partición de red divide los dos bricks de datos principales, el árbitro actúa como el nodo de desempate, permitiendo que el lado conectado al árbitro mantenga un cuórum de escritura activo mientras previene escrituras split-brain en el brick aislado.

---

### Solución: Ejercicio 3 — DRBD9

#### Respuesta 3.1
Para resolver una condición de DRBD `SplitBrain` manualmente, se debe designar un nodo como la víctima de datos (cuyas modificaciones se descartan) y el otro nodo como la fuente autoritativa (cuyos datos se conservan).

**Paso 1: En el Nodo Víctima (ej., `node02`):**
```bash
# Demote resource to secondary if active
sudo drbdadm secondary ha_data

# Discard modifications and set connection state to StandAlone
sudo drbdadm disconnect ha_data
sudo drbdadm secondary ha_data
sudo drbdadm connect --discard-my-data ha_data
```

**Paso 2: En el Nodo Autoritativo (ej., `node01`):**
```bash
# Force connection sync initiation
sudo drbdadm disconnect ha_data
sudo drbdadm connect ha_data
```
Al conectarse, `node01` sobrescribe los bloques en conflicto en `node02`, devolviendo ambos dispositivos a un estado `UpToDate` y limpiando la condición de split-brain.

#### Respuesta 3.2
* **Importancia Arquitectónica:** `fencing resource-and-stonith;` le indica al controlador del kernel de DRBD que detenga las operaciones de escritura en disco (colocando el dispositivo de bloques local en un estado de congelamiento de E/S) siempre que la comunicación con el nodo par se interrumpa de forma abrupta.
* **Interacciones con Pacemaker:**
  1. DRBD detiene la E/S (I/O) del almacenamiento local e invoca el script manejador designado (`crm-fence-peer.9.sh`).
  2. El script manejador se comunica con Pacemaker para solicitar el fencing inmediato (apagado o reinicio mediante IPMI/PDU STONITH) del par inalcanzable.
  3. Este bloqueo estricto garantiza que el nodo secundario no pueda intentar escrituras en el disco local ni montar el sistema de archivos de forma concurrente. La integridad de los datos se preserva en la capa de bloques antes de que Pacemaker promueva un nuevo nodo primario.

</details>