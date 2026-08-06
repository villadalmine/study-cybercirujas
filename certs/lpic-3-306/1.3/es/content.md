# LPIC-3 Examen 306-300 (Versión 3.0) — Tema 1.3: Almacenamiento Distribuido de Alta Disponibilidad

---

## 1. Motivación Arquitectónica de Producción y Planteamiento del Problema

### 1.1 El Dilema del Estado en Entornos Cloud-Native
En las infraestructuras cloud-native modernas y en los clusters empresariales con estado (stateful), los nodos de cómputo son inherentemente efímeros, pero la persistencia de datos debe permanecer inmutable, disponible y durable. Las soluciones tradicionales SAN (Storage Area Network) y NAS (Network Attached Storage) introducen severos cuellos de botella operativos en despliegues a gran escala:
* **Puntos Únicos de Falla (SPOF):** Los backplanes de almacenamiento compartido dependen de controladores duales que sufren escenarios de split-brain o límites de escalabilidad vinculados al hardware.
* **CapEx y Bloqueo de Proveedor (Vendor Lock-in):** Las tramas SAN propietarias (por ejemplo, Fibre Channel) requieren HBAs de hardware personalizados y costosos niveles de licencia.
* **Restricciones de Escalabilidad Horizontal:** Las arquitecturas SAN tradicionales escalan verticalmente (scale-up). Aumentar la capacidad requiere arrays de almacenamiento más grandes en lugar de añadir nodos de hardware estándar (scale-out).

Los sistemas de almacenamiento distribuido superan estos límites agregando discos locales (NVMe, SSD, HDD) a través de nodos de servidores estándar en un pool de almacenamiento unificado, resiliente y definido por software.

```
       +-----------------------------------------------------------------------+
       |                         Client / Compute Layer                        |
       |             [ Kubernetes Pods / Hypervisors / Bare-Metal ]           |
       +-----------------------------------------------------------------------+
            | (RBD / NVMe-oF)               | (CephFS / NFS)       | (RGW S3)
            v                               v                      v
  +--------------------+         +--------------------+  +-------------------+
  |  Block Storage     |         | Shared File System |  |   Object Storage  |
  +--------------------+         +--------------------+  +-------------------+
  | - Persistent Disks |         | - Multi-writer     |  | - RESTful S3/Swift|
  | - Low Latency RWX  |         | - POSIX Compliance |  | - Unstructured    |
  +--------------------+         +--------------------+  +-------------------+
                                    |
  ==================================v===========================================
                      SOFTWARE-DEFINED STORAGE FABRIC
  ==============================================================================
  +----------------------------------------------------------------------------+
  | Ceph RADOS (CRUSH Engine) / GlusterFS Glusterd (Translator Stack)          |
  +----------------------------------------------------------------------------+
       |                             |                             |
       v                             v                             v
+--------------+             +--------------+             +--------------+
| Node 1 (OSD) |             | Node 2 (OSD) |             | Node 3 (OSD) |
| [NVMe] [SSD] |<----------->| [NVMe] [SSD] |<----------->| [NVMe] [SSD] |
+--------------+   Network   +--------------+   Network   +--------------+
                   Replication                  Replication
```

### 1.2 El Teorema CAP en la Arquitectura de Almacenamiento
Todo motor de almacenamiento distribuido está limitado por el **Teorema CAP** (Consistencia, Disponibilidad, Tolerancia a Particiones):

* **Consistencia (C):** Cada lectura recibe la escritura más reciente o un error.
* **Disponibilidad (A):** Cada nodo que no falla devuelve una respuesta sin error, sin garantizar que contenga la escritura más reciente.
* **Tolerancia a Particiones (P):** El sistema continúa funcionando a pesar de que la red entre nodos pierda o retrase un número arbitrario de mensajes.

Debido a que las particiones de red ($P$) son inevitables en la infraestructura física, los motores de almacenamiento distribuido deben elegir entre **CP** (Consistencia + Tolerancia a Particiones) o **AP** (Disponibilidad + Tolerancia a Particiones).

#### Clasificación de Compromisos (Trade-Offs) en Motores de Almacenamiento
1. **Ceph (Sistema CP):** Prefiere consistencia fuerte sobre disponibilidad durante eventos de split-brain. Si se pierde un quórum Paxos de Monitors (`ceph-mon`), las escrituras se bloquean para proteger la integridad de los datos.
2. **GlusterFS (CP/AP Ajustable):** Funciona principalmente como un sistema AP de forma predeterminada (permitiendo lecturas/escrituras durante particiones de red), pero puede ajustarse hacia CP utilizando mecanismos de cumplimiento de quórum (`cluster.quorum-type auto`, `cluster.quorum-action freeze-writes`) y arbiter bricks para evitar split-brain.

### 1.3 Mecánica de Split-Brain y Consenso de Quórum
El split-brain ocurre cuando una partición de red divide un cluster de almacenamiento en subclusters aislados. Si ambos subclusters continúan aceptando operaciones de escritura independientemente en los mismos bloques de almacenamiento, se produce divergencia y corrupción de datos.

#### Protocolos de Consenso
* **Motor Paxos (Ceph Monitors):** Requiere un número impar de instancias de Monitor ($N \ge 3$). El umbral de quórum se define como:
  $$\text{Quorum} = \left\lfloor \frac{N}{2} \right\rfloor + 1$$
  Si $N=3$, 2 MONs deben estar de acuerdo. Si 2 MONs fallan, el cluster detiene el I/O de escritura.
* **Quórum y Replica 3 con Arbiter (GlusterFS):** Utiliza 3 nodos donde el Nodo 3 actúa como **Arbiter** (almacena solo metadatos y atributos de archivo, sin cargas de datos de archivo completas). Esto elimina el 50% del sobrecosto (overhead) de almacenamiento mientras conserva la protección contra split-brain de 3 vías.

---

## 2. Arquitectura Técnica y Comparaciones Profundas

### 2.1 Arquitectura de Ceph y Mecánica Interna

Ceph proporciona almacenamiento de objetos, bloques y archivos desde una única capa de almacenamiento unificada llamada **RADOS** (Reliable Autonomic Distributed Object Store).

```
 +-------------------------------------------------------------------------+
 |                          Ceph User Clients                              |
 |   librbd (Block)   |   libcephfs (POSIX File)   |   radosgw (S3/Swift)   |
 +--------------------+----------------------------+-----------------------+
                                    |
                                    v
 +-------------------------------------------------------------------------+
 |                   RADOS Layer (Object Storage Fabric)                   |
 |                                                                         |
 |  +--------------------+  +--------------------+  +-------------------+  |
 |  |   Ceph Monitors    |  |    Ceph Managers   |  | Metadata Servers  |  |
 |  |  (MON - Quorum)    |  |  (MGR - Metrics)   |  |   (MDS - CephFS)  |  |
 |  +--------------------+  +--------------------+  +-------------------+  |
 |                                                                         |
 |  +-------------------------------------------------------------------+  |
 |  |                  Object Storage Daemons (OSDs)                    |  |
 |  |   OSD.0 (BlueStore)  |  OSD.1 (BlueStore)  |  OSD.2 (BlueStore)    |  |
 |  +-------------------------------------------------------------------+  |
 +-------------------------------------------------------------------------+
```

#### Componentes Principales
1. **Ceph OSD (Object Storage Daemon):** Gestiona unidades de almacenamiento (HDD/SSD/NVMe), replicación de datos, rebalanceo, recuperación y scrubbing. Utiliza el motor **BlueStore** para escribir directamente en dispositivos de bloques sin procesar (raw block devices) sin el sobrecosto de un sistema de archivos.
2. **Ceph MON (Monitor):** Mantiene los mapas del cluster (MonMap, OSDMap, PGMap, CRUSH map). Ejecuta el consenso Paxos.
3. **Ceph MGR (Manager):** Recopila métricas del cluster (exportador de Prometheus), gestiona módulos operativos y maneja la asignación de PGs.
4. **Ceph MDS (Metadata Server):** Gestiona metadatos POSIX para CephFS (permite que los OSDs sirvan lecturas directas de archivos sin cuellos de botella centrales).
5. **Algoritmo CRUSH (Controlled Replication Under Scalable Hashing):** Elimina las tablas de búsqueda centrales. Cuando un cliente escribe el objeto `obj1` en el pool `pool1`:
   $$\text{Placement Group (PG)} = \text{hash}(obj1) \pmod{\text{pg\_num}}$$
   $$\text{OSD List} = \text{CRUSH}(\text{PG}, \text{CRUSH\_Map}, \text{Rule})$$

#### Disposición del Motor de Almacenamiento BlueStore
BlueStore reemplaza al legacy FileStore (que utilizaba ext4/XFS con sobrecosto POSIX).

```
+---------------------------------------------------------------------------+
|                            Ceph BlueStore OSD                             |
+---------------------------------------------------------------------------+
|  +--------------------+  +---------------------------------------------+  |
|  |     RocksDB        |  |                 BlueFS                      |  |
|  | (Metadata / WAL)   |  | (Small Allocator for RocksDB SST files)     |  |
|  +--------------------+  +---------------------------------------------+  |
|  +---------------------------------------------------------------------+  |
|  |                       BlueStore Allocator                           |  |
|  |           (Direct I/O to Raw Block Device / NVMe / Disk)            |  |
|  +---------------------------------------------------------------------+  |
+---------------------------------------------------------------------------+
```

### 2.2 Arquitectura de GlusterFS y Pila de Traductores (Translator Stack)

GlusterFS es un sistema de archivos distribuido definido por software en espacio de usuario, construido sobre una **Pila de Traductores** (`xlators`) modular.

```
+---------------------------------------------------------------------------+
|                          GlusterFS Client Mount                           |
+---------------------------------------------------------------------------+
                                     |
                                     v
+---------------------------------------------------------------------------+
|                          FUSE Kernel Module                               |
+---------------------------------------------------------------------------+
                                     |
                                     v
+---------------------------------------------------------------------------+
|                             Translator Stack                              |
|  +---------------------------------------------------------------------+  |
|  | Performance Translators (read-ahead, write-behind, io-cache)        |  |
|  +---------------------------------------------------------------------+  |
|  | Cluster Translators (AFR - Automatic File Replication / DHT)      |  |
|  +---------------------------------------------------------------------+  |
|  | Protocol Translators (rpc-clnt -> network -> rpc-server)           |  |
|  +---------------------------------------------------------------------+  |
+---------------------------------------------------------------------------+
                                     |
                                     v
+---------------------------------------------------------------------------+
|                             GlusterFS Bricks                              |
|  Node 1: /data/brick1/b1   Node 2: /data/brick2/b1   Node 3: /data/b3/b1  |
|        (XFS File System)         (XFS File System)       (XFS File System)|
+---------------------------------------------------------------------------+
```

* **Bricks:** Una unidad básica de almacenamiento representada como un directorio montado en un sistema de archivos subyacente (típicamente XFS con atributos extendidos `user.glusterfs.*`).
* **Trusted Storage Pool (TSP):** Una colección de red de nodos de almacenamiento que ejecutan `glusterd`.
* **Self-Heal Daemon (`glustershd`):** Ejecuta procesos en segundo plano para reconciliar bricks desincronizados durante reconexiones.

---

### 2.3 Tablas Comparativas Completa de Compromisos Técnicos

#### Tabla 1: Comparación de Arquitecturas de Almacenamiento Distribuido de Alta Disponibilidad

| Característica / Métrica | Ceph (RADOS) | GlusterFS | DRBD (Distributed Replicated Block Device) |
| :--- | :--- | :--- | :--- |
| **Abstracciones de Almacenamiento** | Unificado (Bloque: RBD, Objeto: RGW, Archivo: CephFS) | Archivo (Montaje POSIX) y Bloque vía `gluster-block` | Dispositivo de Bloques de Red (`/dev/drbd*`) |
| **Motor de Ubicación de Datos** | Algorítmico (Motor de Hashing CRUSH) | Hash Elástico / DHT (Tabla de Hash Distribuida) | Replicación Estática de Bloques (Primario/Secundario) |
| **Substrato Subyacente** | Dispositivo de Bloques RAW (BlueStore DB/WAL + Datos) | Sistema de Archivos POSIX (XFS recomendado) | Partición RAW, Volumen Lógico LVM o Disco |
| **Protocolo de Consenso** | Paxos vía Quórum de Ceph Monitor | Ajustes de Quórum (`auto`/`server`) + Arbiter | Motor de Estado a Nivel de Kernel TCP |
| **Modos de Replicación** | Sincrónico dentro del PG, Async Async-Mirroring | AFR Sincrónico (Replicación Automática de Archivos) | Protocolo A (Asíncrono), B (Semi-Sincrónico), C (Sincrónico) |
| **Límites Máximos de Escala** | 10.000+ Nodos / Exabytes | ~100-200 Nodos / Petabytes | Típicamente 2 Nodos (Hasta 32 nodos en DRBD 9) |
| **Latencia I/O de Archivos Pequeños** | Moderada (Sobrecosto de metadatos vía BlueStore/MDS) | De Baja a Alta (Cambios de contexto en capa FUSE) | Ultra-Baja (Casi nativa en capa de bloques del kernel) |
| **Mecánica de Auto-recuperación** | Automática vía Peering y PG Scrubbing | Segundo plano vía `glustershd` y heal en cliente | Resincronización vía seguimiento de deltas en bitmap |

---

#### Tabla 2: Ceph BlueStore vs FileStore Legacy y Estrategias de Replicación

| Métrica / Parámetro | BlueStore (Predeterminado Moderno) | FileStore (Legacy) | Pools Replicados | Pools Erasure Coded (EC) |
| :--- | :--- | :--- | :--- | :--- |
| **Motor de Metadatos** | RocksDB embebido en BlueFS | Estructuras de directorio del sistema de archivos | N/A | N/A |
| **Problema de Doble Escritura** | Eliminado (escribe directamente en disco) | Presente (Escritura en Journal + Escritura en sistema de archivos) | N/A | N/A |
| **Eficiencia de Almacenamiento** | ~100% de utilización del dispositivo | Sobrecosto del sistema de archivos por hardware (~5-10%) | $\frac{1}{N}$ (por ejemplo, $33\%$ para réplica 3x) | $\frac{K}{K+M}$ (por ejemplo, $66\%$ para $K=4, M=2$) |
| **Tolerancia a Fallos** | Configurable vía Reglas de Pool | Configurable vía Reglas de Pool | Soporta $N-1$ fallos | Soporta $M$ fallos de nodo/disco |
| **Adecuación de Carga de Trabajo** | Altos IOPS, DBs, VMs, Cloud Native | Despliegues Obsoletos / Legacy | Bloque de Baja Latencia (RBD) e IOPS de Base de Datos | Almacenamiento en Frío, Destinos de Backup, Objeto (RGW) |

---

#### Tabla 3: Comparación de Configuraciones de Volúmenes de GlusterFS

| Tipo de Volumen | Fórmula de Disposición de Bricks | Tolerancia a Fallos | Eficiencia de Capacidad | Rendimiento de Lectura/Escritura |
| :--- | :--- | :--- | :--- | :--- |
| **Distributed** | $N$ Bricks | 0 Fallos de Brick | 100% | Alto rendimiento de Lectura/Escritura (Sin sobrecosto de réplica) |
| **Replicated (Replica 3)** | $3 \times N$ Bricks | 2 Bricks por conjunto de réplicas | $33,3\%$ | Lectura Alta (Paralela), Escritura Moderada (Bloqueo sincrónico) |
| **Replica 3 Arbiter 1** | 2 Bricks de Datos + 1 Brick Arbiter | 1 Fallo de Brick de Datos | $50,0\%$ | Lectura Alta, Escritura Optimizada (Solo metadatos en Arbiter) |
| **Dispersed (Erasure Coded)** | Redundancia $M$, Datos $K$ ($K+M$) | $M$ Bricks | $\frac{K}{K+M}$ | Alta Lectura/Escritura Secuencial, Deficiente IOPS de Escritura Aleatoria |

---

## 3. Archivos de Configuración Listos para Producción y Manifiestos Sintácticamente Completos

### 3.1 Configuración de Cluster Ceph para Producción (`/etc/ceph/ceph.conf`)

Esta configuración está optimizada para un cluster de producción con redes dedicadas, ajuste de BlueStore y programas automatizados de scrubbing.

```ini
[global]
fsid = a7f5892c-63e8-4982-a0e2-89241bda207e
mon_initial_members = ceph-mon01, ceph-mon02, ceph-mon03
mon_host = 192.168.10.11, 192.168.10.12, 192.168.10.13

# Network Separation: Public (Client I/O) vs Cluster (Replication I/O)
public_network = 192.168.10.0/24
cluster_network = 10.10.10.0/24

# Authentication and Security Protocols
auth_cluster_required = cephx
auth_service_required = cephx
auth_client_required = cephx

# Storage Architecture Limits
osd_pool_default_size = 3
osd_pool_default_min_size = 2
osd_pool_default_pg_autoscale_mode = on

[mon]
mon_clock_drift_allowed = 0.05
mon_osd_down_out_interval = 600
mon_pg_warn_max_per_osd = 300

[osd]
osd_journal_size = 10240
osd_mkfs_type = xfs
osd_max_backfills = 1
osd_recovery_max_active = 2
osd_recovery_op_priority = 2

# BlueStore Memory & Allocation Settings
bluestore_block_db_size = 67108864000
bluestore_block_wal_size = 10737418240
bluestore_cache_size_ssd = 3221225472

# Scrubbing Schedule (Off-peak maintenance window: 01:00 AM - 05:00 AM)
osd_scrub_begin_hour = 1
osd_scrub_end_hour = 5
osd_scrub_load_threshold = 2.5
osd_deep_scrub_interval = 604800

[client]
rbd_cache = true
rbd_cache_size = 67108864
rbd_cache_max_dirty = 50331648
rbd_cache_target_dirty = 33554432
rbd_cache_writethrough_until_flush = true
```

---

### 3.2 Código Fuente Descompilado del Mapa CRUSH de Ceph

Este mapa CRUSH en texto define una jerarquía de dominios de fallo (`root` $\rightarrow$ `datacenter` $\rightarrow$ `rack` $\rightarrow$ `host` $\rightarrow$ `osd`).

```crush
# Begin CRUSH Map

# Tunables
tunables legacy

# Devices
device 0 osd.0 class nvme
device 1 osd.1 class nvme
device 2 osd.2 class nvme
device 3 osd.3 class nvme
device 4 osd.4 class nvme
device 5 osd.5 class nvme

# Types
type 0 osd
type 1 host
type 2 rack
type 3 datacenter
type 4 root

# Buckets (Hierarchy Definition)
host ceph-node01 {
    id -2
    id -3 class nvme
    alg straw2
    hash 0
    item osd.0 weight 1.800
    item osd.1 weight 1.800
}

host ceph-node02 {
    id -4
    id -5 class nvme
    alg straw2
    hash 0
    item osd.2 weight 1.800
    item osd.3 weight 1.800
}

host ceph-node03 {
    id -6
    id -7 class nvme
    alg straw2
    hash 0
    item osd.4 weight 1.800
    item osd.5 weight 1.800
}

rack rack01 {
    id -8
    id -9 class nvme
    alg straw2
    hash 0
    item ceph-node01 weight 3.600
    item ceph-node02 weight 3.600
}

rack rack02 {
    id -10
    id -11 class nvme
    alg straw2
    hash 0
    item ceph-node03 weight 3.600
}

datacenter dc-primary {
    id -12
    id -13 class nvme
    alg straw2
    hash 0
    item rack01 weight 7.200
    item rack02 weight 3.600
}

root default {
    id -1
    id -14 class nvme
    alg straw2
    hash 0
    item dc-primary weight 10.800
}

# CRUSH Rules
rule replicated_ruleset {
    id 0
    type replicated
    step take default
    step chooseleaf firstn 0 type host
    step emit
}

rule hdd_rack_rule {
    id 1
    type replicated
    step take default class nvme
    step choose firstn 0 type rack
    step chooseleaf firstn 1 type host
    step emit
}
# End CRUSH Map
```

---

### 3.3 Configuración de Montaje de Cliente GlusterFS (`/etc/fstab`)

Para garantizar alta disponibilidad en los montajes de clientes, especifique servidores de archivos de volumen de respaldo para gestionar caídas de nodos durante la negociación del montaje.

```etc
# /etc/fstab: GlusterFS HA Client Mount Entry
192.168.10.21:/gv_production  /mnt/gluster_ha  glusterfs  defaults,_netdev,backup-volfile-servers=192.168.10.22:192.168.10.23,log-level=WARNING,log-file=/var/log/glusterfs/gv_production.log  0  0
```

---

### 3.4 Manifiestos de Almacenamiento Cloud-Native para Producción (Rook-Ceph en Kubernetes)

Los siguientes manifiestos despliegan una trama de almacenamiento Rook-Ceph, un `StorageClass` personalizado, un `PersistentVolumeClaim` dinámico y un `Deployment` con estado (stateful).

```yaml
apiVersion: ceph.rook.io/v1
kind: CephCluster
metadata:
  name: rook-ceph
  namespace: rook-ceph
spec:
  cephVersion:
    image: quay.io/ceph/ceph:v18.2.1
    allowUnsupported: false
  dataDirHostPath: /var/lib/rook
  skipUpgradeChecks: false
  continueUpgradeAfterChecksEvenIfNotHealthy: false
  mon:
    count: 3
    allowMultiplePerNode: false
  mgr:
    count: 2
    modules:
      - name: pg_autoscaler
        enabled: true
  dashboard:
    enabled: true
    ssl: true
  network:
    provider: host
  resources:
    mon:
      limits:
        cpu: "2"
        memory: "4Gi"
      requests:
        cpu: "1"
        memory: "2Gi"
    osd:
      limits:
        cpu: "4"
        memory: "8Gi"
      requests:
        cpu: "2"
        memory: "4Gi"
  storage:
    useAllNodes: false
    useAllDevices: false
    config:
      databaseSizeMB: "30720"
      walSizeMB: "10240"
    nodes:
      - name: "node-01.storage.internal"
        devices:
          - name: "/dev/nvme0n1"
      - name: "node-02.storage.internal"
        devices:
          - name: "/dev/nvme0n1"
      - name: "node-03.storage.internal"
        devices:
          - name: "/dev/nvme0n1"
---
apiVersion: ceph.rook.io/v1
kind: CephBlockPool
metadata:
  name: replicapool-fast
  namespace: rook-ceph
spec:
  failureDomain: host
  replicated:
    size: 3
    requireSafeReplicaSize: true
  parameters:
    compression_mode: passive
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: rook-ceph-block
provisioner: rook-ceph.rbd.csi.ceph.com
parameters:
  clusterID: rook-ceph
  pool: replicapool-fast
  imageFormat: "2"
  imageFeatures: layering
  csi.storage.k8s.io/provisioner-secret-name: rook-csi-rbd-provisioner
  csi.storage.k8s.io/provisioner-secret-namespace: rook-ceph
  csi.storage.k8s.io/controller-expand-secret-name: rook-csi-rbd-provisioner
  csi.storage.k8s.io/controller-expand-secret-namespace: rook-ceph
  csi.storage.k8s.io/node-stage-secret-name: rook-csi-rbd-node
  csi.storage.k8s.io/node-stage-secret-namespace: rook-ceph
reclaimPolicy: Delete
allowVolumeExpansion: true
volumeBindingMode: Immediate
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: production-db-pvc
  namespace: default
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: rook-ceph-block
  resources:
    requests:
      storage: 250Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: stateful-app-server
  namespace: default
  labels:
    app: stateful-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: stateful-app
  template:
    metadata:
      labels:
        app: stateful-app
    spec:
      containers:
        - name: database
          image: postgres:15.3-alpine
          env:
            - name: POSTGRES_PASSWORD
              value: "ProductionSecurePassword123!"
            - name: PGDATA
              value: "/var/lib/postgresql/data/pgdata"
          ports:
            - containerPort: 5432
          volumeMounts:
            - name: db-persistent-storage
              mountPath: /var/lib/postgresql/data
      volumes:
        - name: db-persistent-storage
          persistentVolumeClaim:
            claimName: production-db-pvc
```

---

## 4. Comandos CLI Reales y Salidas de Terminal ($)

### 4.1 Administración Operativa de Ceph

#### Inspeccionando el Estado de Salud del Cluster
```console
$ sudo ceph status
```
```text
  cluster:
    id:     a7f5892c-63e8-4982-a0e2-89241bda207e
    health: HEALTH_OK

  services:
    mon: 3 daemons, quorum ceph-mon01,ceph-mon02,ceph-mon03 (age 4w)
    mgr: ceph-node01(active, since 2w), standbys: ceph-node02
    osd: 6 osds: 6 up, 6 in (since 5d)

  data:
    pools:   3 pools, 128 pgs
    objects: 1.24M objects, 4.8 TiB
    usage:   14.4 TiB used, 18.0 TiB / 32.4 TiB avail
    pgs:     128 active+clean

  io:
    client:  12.4 MiB/s rd, 45.2 MiB/s wr, 3.45k op/s rd, 1.21k op/s wr
```

#### Verificación Detallada de la Disposición del Árbol de OSDs
```console
$ sudo ceph osd tree
```
```text
ID  CLASS  WEIGHT    TYPE NAME               STATUS  REWEIGHT  PRI-AFF
-1         10.80000  root default
-12         7.20000      datacenter dc-primary
-8          3.60000          rack rack01
-2          1.80000              host ceph-node01
 0   nvme   0.90000                  osd.0       up   1.00000  1.00000
 1   nvme   0.90000                  osd.1       up   1.00000  1.00000
-4          1.80000              host ceph-node02
 2   nvme   0.90000                  osd.2       up   1.00000  1.00000
 3   nvme   0.90000                  osd.3       up   1.00000  1.00000
-10         3.60000          rack rack02
-6          1.80000              host ceph-node03
 4   nvme   0.90000                  osd.4       up   1.00000  1.00000
 5   nvme   0.90000                  osd.5       up   1.00000  1.00000
```

#### Aprovisionamiento de un Pool RADOS Replicado e Imagen de Bloques RBD
```console
$ sudo ceph osd pool create rbd_production 64 64 replicated
```
```text
pool 'rbd_production' created
```

```console
$ sudo rbd pool init rbd_production
$ sudo rbd create --size 102400 --pool rbd_production sys-disk-01.img
$ sudo rbd info rbd_production/sys-disk-01.img
```
```text
rbd image 'sys-disk-01.img':
	size 100 GiB in 25600 objects
	order 22 (4 MiB objects)
	snapshot_count: 0
	id: 4b88491d9047
	block_name_prefix: rbd_data.4b88491d9047
	format: 2
	features: layering, exclusive-lock, object-map, fast-diff, deep-flatten
	op_features: 
	flags: 
	create_timestamp: Thu Aug  6 14:22:01 2026
	access_timestamp: Thu Aug  6 14:22:01 2026
	modify_timestamp: Thu Aug  6 14:22:01 2026
```

#### Mapeo de una Imagen RBD a un Dispositivo de Bloques Local de Linux
```console
$ sudo rbd device map rbd_production/sys-disk-01.img --name client.admin
```
```text
/dev/rbd0
```

```console
$ lsblk /dev/rbd0
```
```text
NAME BASE-DEF MAJ:MIN RM  SIZE RO TYPE MOUNTPOINTS
rbd0          252:0    0  100G  0 rbd  
```

---

### 4.2 Administración de Clusters GlusterFS

#### Aprovisionamiento de Pares de Almacenamiento de Confianza (Trusted Storage Peers)
```console
$ sudo gluster peer probe 192.168.10.22
```
```text
peer probe: success.
```

```console
$ sudo gluster peer status
```
```text
Number of Peers: 2

Hostname: 192.168.10.22
Uuid: 5e617d12-1a13-432d-944f-c4f4a3d44111
State: Peer in Cluster (Connected)

Hostname: 192.168.10.23
Uuid: a11b22c3-33d4-45e5-66f7-889900aabbcc
State: Peer in Cluster (Connected)
```

#### Creación e Inicio de un Volumen Arbiter Distribuido-Replicado de Alta Disponibilidad
```console
$ sudo gluster volume create gv_production replica 3 arbiter 1 \
  192.168.10.21:/data/brick1/b1 \
  192.168.10.22:/data/brick1/b1 \
  192.168.10.23:/data/arbiter/b1 force
```
```text
volume create: gv_production: success: please start the volume to access data
```

```console
$ sudo gluster volume start gv_production
```
```text
volume start: gv_production: success
```

```console
$ sudo gluster volume info gv_production
```
```text
Volume Name: gv_production
Type: Distributed-Replication
Volume ID: c181e194-e349-410a-8bf8-0955376da6c8
Status: Started
Snapshot Count: 0
Number of Bricks: 1 x (2 + 1) = 3
Transport-type: tcp
Bricks:
Brick1: 192.168.10.21:/data/brick1/b1
Brick2: 192.168.10.22:/data/brick1/b1
Brick3: 192.168.10.23:/data/arbiter/b1 (arbiter)
Options Reconfigured:
cluster.arbiter-prune: on
transport.address-family: inet
nfs.disable: on
performance.client-io-threads: off
```

---

## 5. Guía de Verificación, Depuración y Resolución de Problemas

### 5.1 Matriz de Árbol de Decisión de Diagnóstico

```
                      INCOMING STORAGE DEGRADATION ALERT
                                      |
         +----------------------------+----------------------------+
         |                                                         |
         v                                                         v
   [ Ceph Cluster Alert ]                                [ GlusterFS Alert ]
         |                                                         |
         v                                                         v
Execute `ceph health detail`                            Execute `gluster volume status`
         |                                                         |
  +------+------+                                           +------+------+
  |             |                                           |             |
  v             v                                           v             v
[OSD DOWN]  [PG Inconsistent]                         [Brick Offline] [Split-Brain]
  |             |                                           |             |
  v             v                                           v             v
1. Check OSD   1. Run `ceph pg map <id>`                 1. Verify Systemd 1. Run heal info
   Systemd &      to locate primary OSD.                    `glusterd`     2. Inspect POSIX
   dmesg.      2. Trigger `ceph pg deep-scrub <id>`.        2. Check network  extended attributes
2. Check disk  3. Run `ceph osd repair <osd_id>`            connectivity   `getfattr -d -m .`
   health via     if corrupt objects exist.                 on port 24007. 3. Resolve using
   smartctl.                                                               `gluster volume heal
                                                                           <vol> split-brain`
```

---

### 5.2 Escenario de Fallo 1: Flapping de OSD de Ceph y PG Degradado / Inconsistente

#### Síntoma e Información Inicial de Diagnóstico
Las alertas de monitoreo activan un estado `HEALTH_WARN` con grupos de colocación (placement groups) degradados.

```console
$ sudo ceph health detail
```
```text
HEALTH_WARN 1 pgs degraded; 1 pgs inconsistent; 1 osds down; 1 scrub errors
[NXERROR] PG_DEGRADED: PG 2.1f is degraded (2 copies out of 3 expected)
[NXERROR] OSD_DOWN: osd.2 on host 'ceph-node02' is down
[NXERROR] OSD_SCRUB_ERRORS: 1 scrub errors, use 'ceph health detail' or 'ceph pg query'
```

#### Procedimiento de Diagnóstico y Resolución Paso a Paso

##### Paso 1: Aislar el Grupo de Colocación Degradado e Identificar el Mapeo de Componentes
```console
$ sudo ceph pg map 2.1f
```
```text
osdmap e142 pg 2.1f (2.1f) -> up [2,0,4] acting [0,4]
```
*Análisis:* `osd.2` no está presente en el conjunto de OSDs `acting`.

##### Paso 2: Rastrear Logs del Sistema en Busca de Fallos de Disco o Kills por OOM de Memoria
```console
$ ssh ceph-node02 "journalctl -u ceph-osd@2.service -n 50 --no-pager"
```
```text
Aug 06 15:10:12 ceph-node02 ceph-osd[4102]: BlueStore::_verify_csum bad crc32c/0x1000 at offset 0x40000000
Aug 06 15:10:12 ceph-node02 ceph-osd[4102]: osd.2 142 err -5 (Input/output error) read block 0x40000000
Aug 06 15:10:13 ceph-node02 systemd[1]: ceph-osd@2.service: Main process exited, code=exited, status=1/FAILURE
```

##### Paso 3: Ejecutar Diagnóstico SMART a Nivel de Hardware
```console
$ ssh ceph-node02 "sudo smartctl -H /dev/nvme1n1"
```
```text
smartctl 7.3 2022-02-28 r5338 [x86_64-linux-5.15.0-76-generic] (local build)
Copyright (C) 2002-22, Bruce Allen, Christian Franke, www.smartmontools.org

=== START OF READ SMART DATA SECTION ===
SMART overall-health self-assessment test result: FAILED!
Drive failure expected in less than 24 hours. SAVE ALL DATA.
```

##### Paso 4: Eliminar de Forma Segura el OSD Corrupto del Mapa CRUSH y Rebalancear Datos
```console
$ sudo ceph osd out osd.2
```
```text
marked out osd.2.
```
```console
$ sudo ceph osd down osd.2
```
```text
marked down osd.2.
```

Espere a que el relleno de datos (backfilling) alcance un estado 100% limpio en los nodos restantes (`osd.0`, `osd.4`):
```console
$ sudo ceph pg query 2.1f | grep -E "state|acting"
```
```text
    "state": "active+clean",
    "acting": [0,4,5],
```

##### Paso 5: Ejecutar Comando de Reparación de Inconsistencias
```console
$ sudo ceph osd repair osd.0
```
```text
instruction sent to osd.0
```
```console
$ sudo ceph health
```
```text
HEALTH_OK
```

---

### 5.3 Escenario de Fallo 2: Resolución de Split-Brain en GlusterFS

#### Síntoma e Información Inicial de Diagnóstico
Las aplicaciones que acceden a `/mnt/gluster_ha/app_data.db` devuelven un `Input/output error` (EIO).

```console
$ ls -l /mnt/gluster_ha/app_data.db
```
```text
ls: cannot access '/mnt/gluster_ha/app_data.db': Input/output error
```

#### Procedimiento de Diagnóstico y Resolución Paso a Paso

##### Paso 1: Identificar Archivos en Split-Brain a Través de la CLI de Gluster
```console
$ sudo gluster volume heal gv_production info split-brain
```
```text
Brick 192.168.10.21:/data/brick1/b1
/app_data.db
Number of entries in split-brain: 1

Brick 192.168.10.22:/data/brick1/b1
/app_data.db
Number of entries in split-brain: 1

Brick 192.168.10.23:/data/arbiter/b1
Number of entries in split-brain: 0
```

##### Paso 2: Inspeccionar Atributos Extendidos POSIX (`xattr`) en los Bricks
Verifique los atributos extendidos AFR (`trusted.afr.<volname>-client-*`) en los nodos de almacenamiento.

```console
$ ssh 192.168.10.21 "getfattr -d -m . -e hex /data/brick1/b1/app_data.db"
```
```text
# file: data/brick1/b1/app_data.db
trusted.afr.gv_production-client-0=0x000000000000000000000000
trusted.afr.gv_production-client-1=0x000000010000000000000000
trusted.gfid=0xa923f4c1e2904518b2c589001245781a
```

```console
$ ssh 192.168.10.22 "getfattr -d -m . -e hex /data/brick1/b1/app_data.db"
```
```text
# file: data/brick1/b1/app_data.db
trusted.afr.gv_production-client-0=0x000000020000000000000000
trusted.afr.gv_production-client-1=0x000000000000000000000000
trusted.gfid=0xa923f4c1e2904518b2c589001245781a
```
*Análisis:* Tanto el Nodo 1 (`client-0`) como el Nodo 2 (`client-1`) modificaron el archivo de manera independiente mientras estaban aislados entre sí.

##### Paso 3: Resolver Split-Brain Seleccionando el Nodo 1 como la Fuente de la Verdad
Fuerce el auto-reparado (self-heal) utilizando la opción de resolución por brick de origen (source-brick).

```console
$ sudo gluster volume heal gv_production split-brain source-brick 192.168.10.21:/data/brick1/b1 /app_data.db
```
```text
Healing /app_data.db on volume gv_production succeeded.
```

##### Paso 4: Verificar la Finalización del Reparado (Heal) y Limpiar Errores
```console
$ sudo gluster volume heal gv_production info split-brain
```
```text
Brick 192.168.10.21:/data/brick1/b1
Number of entries in split-brain: 0

Brick 192.168.10.22:/data/brick1/b1
Number of entries in split-brain: 0

Brick 192.168.10.23:/data/arbiter/b1
Number of entries in split-brain: 0
```

```console
$ head -n 2 /mnt/gluster_ha/app_data.db
```
```text
SQLite format 3...
```
*Resultado:* El archivo es accesible y el estado de split-brain se ha resuelto.

---

### 5.4 Hoja de Referencia (Cheat Sheet) de Diagnóstico y Observabilidad

```
+---------------------------------------------------------------------------------------------------------+
|                                    STORAGE DIAGNOSTIC CHEAT SHEET                                       |
+------------------------------------+--------------------------------------------------------------------+
| Task / Diagnostic Objective        | Execution Command Syntax                                           |
+------------------------------------+--------------------------------------------------------------------+
| Ceph Monitoring Paxos Quorum Status| ceph quorum_status --format json-pretty                            |
| Ceph PG Distribution & Autoscale   | ceph osd pool autoscale-status                                     |
| Ceph Live IOPS / Latency Metrics   | ceph osd perf                                                      |
| Ceph Deep Scrub Triggering         | ceph pg deep-scrub <pg_id>                                         |
| Ceph Extract Active MonMap Binary  | ceph-mon --extract-monmap /tmp/monmap -i <mon_name>                |
| GlusterFS Active Volume Locks      | gluster volume locks info <vol_name>                               |
| GlusterFS Active Self-Heal Status  | gluster volume heal <vol_name> statistics                          |
| GlusterFS Profile I/O Metrics      | gluster volume profile <vol_name> start                            |
|                                    | gluster volume profile <vol_name> info                             |
| GlusterFS Force Brick Re-sync      | gluster volume heal <vol_name> full                                |
+------------------------------------+--------------------------------------------------------------------+
```

---

## 6. Referencias

* **Visión General Oficial del Examen LPIC-3 306 de Linux Professional Institute (LPI):**
  `https://www.lpi.org/our-certifications/lpic-3-306-overview/`
* **LPI Wiki — Examen LPIC-3 306 Tema 363 (Almacenamiento Distribuido de Alta Disponibilidad):**
  `https://wiki.lpi.org/wiki/LPIC-3_306_Objectives`
* **Documentación Arquitectónica y Operativa Oficial de Ceph:**
  `https://docs.ceph.com/en/latest/`
* **Especificaciones de Arquitectura y Algoritmo del Mapa CRUSH de Ceph:**
  `https://docs.ceph.com/en/latest/rados/operations/crush-map/`
* **Guía Oficial de Administración y Referencia de Pila de Traductores de GlusterFS:**
  `https://docs.gluster.org/en/latest/`
* **Orquestador de Almacenamiento Cloud-Native Rook para Kubernetes:**
  `https://rook.io/docs/rook/latest/`
* **Libro Blanco de Taxonomía y Panorama de Almacenamiento Cloud Native de la CNCF:**
  `https://github.com/cncf/tag-storage/blob/main/cncf-storage-whitepaper.md`