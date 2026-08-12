# Tema 363.1: GlusterFS Storage Clusters

> **Certificación:** LPIC-3 Exam 306-300 (v3.0) · **Objetivo 363.1** · Peso 8.33
> **Perfil:** Scale-out software-defined storage POSIX sin metadata server. Este objetivo es el segundo más pesado del examen porque GlusterFS condensa tres problemas de producción en uno: distribución de datos sin punto central de metadatos, tolerancia a fallos sin split-brain, y crecimiento en caliente de la capacidad.

---

## 1. El problema arquitectónico de producción

La necesidad recurrente en SRE es un **filesystem POSIX compartido** que:

1. crezca horizontalmente a decenas de petabytes sobre **commodity hardware** (JBOD, no cabinas SAN propietarias),
2. sobreviva a la caída de nodos completos sin intervención manual,
3. no tenga un **metadata server** que se convierta en cuello de botella ni en SPOF (Single Point Of Failure).

El punto 3 es el diferenciador de diseño de GlusterFS. Sistemas como **Lustre** (MDS/MDT) o **HDFS** (NameNode) centralizan la ubicación de los ficheros; cada `open()`/`stat()` consulta primero al servidor de metadatos, que a escala se vuelve el limitante y hay que replicarlo con complejidad propia. GlusterFS elimina ese componente con el **Elastic Hashing Algorithm** (algoritmo de hashing basado en Davies-Meyer): la ubicación de un fichero se **calcula** desde su nombre en el cliente, no se **consulta**. No hay servidor de metadatos que escalar ni proteger.

El precio de este diseño —que hay que entender para el examen y para operar— es que la unidad de granularidad es el **fichero completo**, no el bloque. Un fichero individual vive entero en un subvolumen (o se replica/fragmenta entre bricks de un subvolumen), pero nunca se reparte a nivel de bloque como en Ceph RBD. Esto hace a GlusterFS excelente para **archivos medianos-grandes** (imágenes de VM, backups, media, datasets, spillover de big data) y pobre para **workloads de millones de ficheros pequeños con metadata-heavy** (`ls -lR` masivos, compilaciones), donde cada `lookup()` se abanica (fan-out) a todos los bricks.

### Casos de uso reales

| Workload | ¿GlusterFS encaja? | Razón |
|---|---|---|
| Almacén de backups / imágenes VM / media (archivos grandes, sequential I/O) | **Sí, ideal** | Elastic hashing distribuye bien, throughput agregado escala con bricks |
| Object/blob store detrás de una app | Sí (o considerar S3/MinIO) | Distribuido + replicado da durabilidad |
| Home directories / small-file (buzones, git repos, `node_modules`) | **Evitar** | fan-out de `lookup()`/`readdir()` mata la latencia |
| Base de datos transaccional (OLTP) | **No** | Latencia de FUSE + coherencia por fichero, usar block storage |
| Almacenamiento persistente para Kubernetes | Sí, con Heketi/CSI | Aprovisionamiento dinámico de PVs |

---

## 2. Arquitectura interna y componentes

### 2.1 Los tres daemons/procesos

| Componente | Rol | Puerto | Config |
|---|---|---|---|
| **`glusterd`** | Daemon de *management* (uno por nodo). Mantiene la configuración del cluster, negocia el *trusted storage pool*, arranca/para los `glusterfsd`, sirve los **volfiles** a los clientes. Persiste estado en `/var/lib/glusterd/`. | `24007/tcp` | `/etc/glusterfs/glusterd.vol` |
| **`glusterfsd`** | Daemon de **brick** (uno por brick exportado). Es el que realmente sirve el filesystem de un directorio-brick. | `49152/tcp` y siguientes (uno por brick) | volfile generado en `/var/lib/glusterd/vols/<vol>/` |
| **Cliente FUSE** (`glusterfs`) | Monta el volumen en el cliente vía **FUSE** (`mount.glusterfs`). Descarga el volfile de `glusterd`, ejecuta el *translator stack* (DHT, AFR/EC, etc.) **en el cliente**. | — | — |

> **Clave de arquitectura para el examen:** la inteligencia (distribución, replicación, cifrado) vive en el **translator stack del cliente**, no en el servidor. El cliente escribe simultáneamente a todos los réplicas; el servidor de brick es "tonto". Por eso los servidores no necesitan hablar entre sí para replicar datos de usuario (sí para management vía `glusterd`).

Además existen daemons auxiliares que `glusterd` arranca como "servicios de nodo":
- **`glustershd`** — Self-Heal Daemon: repara réplicas divergentes en segundo plano.
- **`glusterfs` (nfs)** — servidor NFSv3 gluster nativo (**deprecado**, `nfs.disable on` por defecto; se usa **NFS-Ganesha** en su lugar).
- **`quotad`**, **`bitd`/`scrub`** (bitrot), **`snapd`** (snapshots).

### 2.2 Vocabulario jerárquico (memorizarlo — cae en el examen)

```
Trusted Storage Pool  (conjunto de peers que se confían mutuamente)
 └── Node / Peer       (un host con glusterd)
      └── Brick        (un directorio exportado, p.ej. gfs1:/data/glusterfs/gv0/brick1)
           └── backend filesystem (XFS recomendado, sobre LVM thin)
Volume                 (la unidad que monta el cliente; agrupa bricks según un tipo)
 └── Subvolume         (grupo de bricks que forman una unidad de replicación/dispersión)
```

Un **brick** es la unidad básica: `host:/ruta/directorio`. Un **volume** es un conjunto de bricks organizados según un **tipo de volumen** (sección 3). Los **subvolumes** son los grupos internos: en un `Distributed-Replicated replica 3` con 6 bricks hay 2 subvolumes de 3 bricks cada uno; DHT distribuye entre los 2 subvolumes, AFR replica dentro de cada uno.

### 2.3 Elastic Hashing (DHT translator)

- Cada **directorio** existe en **todos** los subvolumes (los directorios no se distribuyen, se replican como estructura).
- A cada directorio, DHT le asigna un **rango del espacio de hash 32-bit** por subvolumen (el *layout*, guardado en el xattr `trusted.glusterfs.dht` de ese directorio en cada brick).
- Al crear `archivo.dat`, el cliente calcula `hash(nombre)` (Davies-Meyer) y lo ubica en el subvolumen cuyo rango contiene ese hash. **No hay consulta a un servidor de metadatos.**
- Si el subvolumen "correcto" está lleno o el fichero se renombró, DHT crea un **linkto file** (fichero de 0 bytes con modo `----------T` (sticky) y xattr `trusted.glusterfs.dht.linkto`) que apunta al brick real. Ver estos linkto files en un brick es normal.

Este diseño explica por qué **añadir bricks requiere `rebalance`**: al cambiar el número de subvolumes cambian los rangos de hash, y los ficheros viejos quedan "en el brick equivocado" hasta que se migran.

---

## 3. Tipos de volumen — tabla de trade-offs

Este es el corazón del objetivo. Hay que dominar **cuándo** usar cada uno y **cuántos fallos tolera**.

| Tipo | Sintaxis clave | Eficiencia de capacidad | Tolerancia a fallos | Cuándo usarlo |
|---|---|---|---|---|
| **Distributed** | *(por defecto, sin keyword)* | 100 % | **Ninguna** (perder 1 brick = perder los ficheros de ese brick) | Scratch/temporal donde la durabilidad la da otra capa; máxima capacidad y throughput |
| **Replicated** | `replica N` | `1/N` (replica 3 → 33 %) | `N-1` bricks | Alta durabilidad, poca capacidad; buckets pequeños de alta disponibilidad |
| **Distributed-Replicated** | `replica N` con `M×N` bricks | `1/N` | `N-1` **por subvolumen** | **El caballo de batalla de producción**: durabilidad + escala |
| **Dispersed** (Erasure Coding) | `disperse D redundancy R` | `(D-R)/D` (ej. 4+2 → 66 %) | `R` bricks | Archivado/capacity-tier: durabilidad tipo RAID6 con menos overhead que replica 3 |
| **Distributed-Dispersed** | varios grupos disperse | `(D-R)/D` por grupo | `R` por grupo | EC a gran escala |
| ~~**Striped**~~ | ~~`stripe N`~~ | — | — | **Deprecado y eliminado**. Reemplazado por *sharding* (`features.shard on`). No usar. |

### 3.1 Replica 3 vs Arbiter vs Replica 2 — la decisión anti-split-brain

El error clásico es desplegar **`replica 2`**. Con 2 réplicas y una partición de red, **ambos** lados creen ser autoritativos y aceptan escrituras → **split-brain** (dos versiones divergentes del mismo fichero, imposible de resolver automáticamente).

Soluciones:

| Config | Costo de almacenamiento | Anti split-brain | Notas |
|---|---|---|---|
| `replica 2` | 2× | **No** (peligroso) | Solo con quorum del cliente muy estricto (sacrifica disponibilidad) |
| `replica 3` | 3× | **Sí** (quorum 2/3) | Máxima seguridad, máximo costo |
| **`replica 3 arbiter 1`** | ~2× (+ metadata) | **Sí** | El 3er brick guarda **solo metadatos** (nombres, xattrs, tamaños), **no data**. Da quorum a costo de un brick pequeño. **Recomendado por defecto** |

El **arbiter** es la respuesta de producción: obtenés el quorum de un tercer voto sin pagar el almacenamiento completo de una tercera copia. El arbiter puede negarse a servir un fichero si es la única copia "viva" que queda además de un dato sospechoso, forzando fallar en lugar de servir datos posiblemente corruptos.

### 3.2 Reglas de configuración de Dispersed (EC)

- La cuenta total = `disperse-data (D) + redundancy (R)`, tolera perder `R` bricks.
- **Rendimiento óptimo cuando `D` (data bricks) es potencia de 2**, porque el tamaño de fragmento EC se alinea. Configs recomendadas: **4+2, 8+3, 8+4, 16+4**.
- `redundancy` no puede ser ≥ mitad del total. `disperse 6 redundancy 3` sería ilegal (sería replica).
- EC gasta **CPU** (Reed-Solomon) en cada read/write → no usar para latencia baja.

```
Ejemplo:  disperse 6 redundancy 2   →  eficiencia = 4/6 = 66 %, tolera 2 fallos
Comparar: replica 3                 →  eficiencia = 33 %,       tolera 2 fallos
```
Con EC 4+2 se obtiene la misma tolerancia (2 fallos) que replica 3 pero con **el doble de capacidad útil**, a cambio de CPU y peor rendimiento en small files.

---

## 4. Comparativa técnica con otros sistemas de storage distribuido

| Dimensión | **GlusterFS** | **Ceph (CephFS/RBD)** | **NFS (single)** | **Lustre** |
|---|---|---|---|---|
| Modelo de metadatos | **Sin servidor** (elastic hash, cálculo en cliente) | RADOS + MDS (CephFS) / sin MDS (RBD) | Servidor único | MDS dedicado |
| Granularidad | **Fichero** | Objeto/bloque (4 MiB) | Fichero | Objeto/stripe |
| Interfaz | POSIX (FUSE), NFS-Ganesha, SMB | Block, Object (S3), POSIX (CephFS) | POSIX | POSIX |
| Curva de operación | **Baja** (arranca en minutos) | **Alta** (mon/osd/mgr/mds) | Trivial | Alta (HPC) |
| Escala metadata-heavy | Débil (fan-out) | Fuerte | N/A | Muy fuerte (HPC) |
| Rebalance al crecer | Manual (`rebalance`) | Automático (CRUSH) | N/A | Manual |
| Sweet spot | NAS scale-out, archivos grandes | Cloud/K8s multiproto | Compartición simple | Supercómputo |

**Regla de decisión SRE:** si necesitás **block + object + POSIX** y multi-tenancy en Kubernetes, Ceph gana. Si necesitás un **scale-out NAS POSIX simple y operable** sobre discos que ya tenés, GlusterFS gana por simplicidad. LPIC-3 306 cubre **ambos** (363 Gluster, 364 Ceph) precisamente para contrastarlos.

---

## 5. Infraestructura completa: despliegue de producción

Topología de referencia: **3 nodos** con un brick cada uno, volumen `replica 3 arbiter 1` (2 réplicas de datos + 1 arbiter).

```
gfs1  10.0.20.11   brick de datos
gfs2  10.0.20.12   brick de datos
gfs3  10.0.20.13   brick arbiter (metadata-only)
```

### 5.1 Backend de brick: LVM thin + XFS (obligatorio para snapshots)

**Nunca** exportar un brick sobre el filesystem raíz ni sobre un directorio suelto sin filesystem dedicado. La receta de producción es **LVM thin provisioning → XFS con inodos de 512 bytes** (los xattrs de Gluster —`trusted.afr.*`, `trusted.gfid`, `trusted.glusterfs.dht`— necesitan espacio en el inodo; con 256 bytes se desbordan a bloques y degradan el rendimiento). El thin pool es **requisito** para `gluster snapshot`.

```bash
# En cada nodo — asumiendo disco dedicado /dev/sdb
$ sudo pvcreate /dev/sdb
  Physical volume "/dev/sdb" successfully created.

$ sudo vgcreate vg_gluster /dev/sdb
  Volume group "vg_gluster" successfully created

# Thin pool (dejar ~1% para metadata del pool; aquí pool de 200G)
$ sudo lvcreate -L 200G -T vg_gluster/tp_gluster --chunksize 256K
  Thin pool volume with chunk size 256.00 KiB can address at most 63.25 TiB of data.
  Logical volume "tp_gluster" created.

# Thin LV que será el brick (puede sobre-aprovisionarse)
$ sudo lvcreate -V 200G -T vg_gluster/tp_gluster -n lv_brick1
  Logical volume "lv_brick1" created.

# XFS con inodos de 512B y sin restricción de proyecto/inode32
$ sudo mkfs.xfs -f -i size=512 -n size=8192 /dev/vg_gluster/lv_brick1
meta-data=/dev/vg_gluster/lv_brick1 isize=512    agcount=4, agsize=13107200 blks
data     =                          bsize=4096   blocks=52428800, imaxpct=25
naming   =version 2                 bsize=8192   ascii-ci=0, ftype=1
log      =internal log              bsize=4096   blocks=25600, version=2

# Montaje persistente
$ sudo mkdir -p /data/glusterfs/gv0
$ echo '/dev/vg_gluster/lv_brick1 /data/glusterfs/gv0 xfs defaults,inode64,noatime 0 2' | sudo tee -a /etc/fstab
$ sudo mount -a
$ sudo mkdir -p /data/glusterfs/gv0/brick
```

> **Regla de oro:** el brick real es un **subdirectorio** del punto de montaje (`.../gv0/brick`), nunca el punto de montaje mismo. Si el filesystem del brick no monta, Gluster escribiría sobre el directorio raíz vacío en `/`; usar un subdirectorio hace que Gluster falle en lugar de llenar el disco de sistema.

### 5.2 Playbook Ansible de aprovisionamiento (idempotente)

```yaml
---
# provision-gluster.yml — instala y prepara nodos GlusterFS
- name: Provision GlusterFS storage nodes
  hosts: gluster_nodes
  become: true
  vars:
    gluster_brick_disk: /dev/sdb
    gluster_vg: vg_gluster
    gluster_brick_mount: /data/glusterfs/gv0
  tasks:
    - name: Install GlusterFS server and LVM tools
      ansible.builtin.package:
        name:
          - glusterfs-server
          - lvm2
          - xfsprogs
        state: present

    - name: Ensure glusterd is enabled and running
      ansible.builtin.systemd:
        name: glusterd
        enabled: true
        state: started

    - name: Open GlusterFS ports in firewalld
      ansible.posix.firewalld:
        service: glusterfs      # abre 24007-24008/tcp y 49152-49664/tcp
        permanent: true
        immediate: true
        state: enabled

    - name: Create LVM physical volume
      community.general.lvg:
        vg: "{{ gluster_vg }}"
        pvs: "{{ gluster_brick_disk }}"

    - name: Create thin pool
      community.general.lvol:
        vg: "{{ gluster_vg }}"
        thinpool: tp_gluster
        size: 200g

    - name: Create thin logical volume for the brick
      community.general.lvol:
        vg: "{{ gluster_vg }}"
        lv: lv_brick1
        thinpool: tp_gluster
        size: 200g

    - name: Create XFS filesystem with 512B inodes
      community.general.filesystem:
        fstype: xfs
        dev: "/dev/{{ gluster_vg }}/lv_brick1"
        opts: -i size=512 -n size=8192

    - name: Mount the brick filesystem
      ansible.posix.mount:
        path: "{{ gluster_brick_mount }}"
        src: "/dev/{{ gluster_vg }}/lv_brick1"
        fstype: xfs
        opts: defaults,inode64,noatime
        state: mounted

    - name: Create the brick subdirectory
      ansible.builtin.file:
        path: "{{ gluster_brick_mount }}/brick"
        state: directory
        mode: '0755'

    - name: Populate /etc/hosts for peer resolution
      ansible.builtin.blockinfile:
        path: /etc/hosts
        block: |
          10.0.20.11 gfs1
          10.0.20.12 gfs2
          10.0.20.13 gfs3
```

### 5.3 Formar el Trusted Storage Pool

Desde **gfs1** (el primer nodo no se auto-probea; se probea a los demás):

```bash
$ sudo gluster peer probe gfs2
peer probe: success

$ sudo gluster peer probe gfs3
peer probe: success

$ sudo gluster peer status
Number of Peers: 2

Hostname: gfs2
Uuid: 6f9a0c1e-2b7d-4a11-9c34-8e5b2a1f0d7c
State: Peer in Cluster (Connected)

Hostname: gfs3
Uuid: b21e7f45-9d3a-4c88-a0f2-1e6c4b9a3d55
State: Peer in Cluster (Connected)

$ sudo gluster pool list
UUID					Hostname 	State
6f9a0c1e-2b7d-4a11-9c34-8e5b2a1f0d7c	gfs2     	Connected 
b21e7f45-9d3a-4c88-a0f2-1e6c4b9a3d55	gfs3     	Connected 
a0d3c8b7-1f24-49e6-b5a1-7c9e2f6d8b41	localhost	Connected 
```

> **Gotcha de producción:** probea siempre por **hostname**, nunca por IP. El primer nodo se identifica ante los demás por la IP de origen; si mezclás IP y hostname, el peer aparece dos veces. Tras el primer probe, hacé `gluster peer probe gfs1` **desde gfs2** para que gfs1 quede registrado por su hostname y no por IP.

### 5.4 Crear el volumen (replica 3 arbiter 1)

```bash
$ sudo gluster volume create gv0 replica 3 arbiter 1 \
    gfs1:/data/glusterfs/gv0/brick \
    gfs2:/data/glusterfs/gv0/brick \
    gfs3:/data/glusterfs/gv0/brick
volume create: gv0: success: please start the volume to access data

$ sudo gluster volume start gv0
volume start: gv0: success

$ sudo gluster volume info gv0

Volume Name: gv0
Type: Replicate
Volume ID: 3c8f1a92-7e64-4b0d-9f21-5a6c8b3e1d70
Status: Started
Snapshot Count: 0
Number of Bricks: 1 x (2 + 1) = 3
Transport-type: tcp
Bricks:
Brick1: gfs1:/data/glusterfs/gv0/brick
Brick2: gfs2:/data/glusterfs/gv0/brick
Brick3: gfs3:/data/glusterfs/gv0/brick (arbiter)
Options Reconfigured:
cluster.granular-entry-heal: on
storage.fips-mode-rchecksum: on
transport.address-family: inet
nfs.disable: on
```

Fijate en `Number of Bricks: 1 x (2 + 1) = 3` → **1 subvolumen**, **2 réplicas de datos + 1 arbiter**. El `(arbiter)` junto a Brick3 confirma que ese brick es metadata-only.

### 5.5 Endurecer con quorum y tuning de producción

```bash
# Quorum de servidor: si <51% de peers están vivos, glusterd para los bricks locales
# (evita que una minoría particionada acepte escrituras)
$ sudo gluster volume set gv0 cluster.server-quorum-type server
$ sudo gluster volume set all cluster.server-quorum-ratio 51%

# Quorum de cliente: con arbiter, 'auto' exige la mayoría de la réplica para escribir
$ sudo gluster volume set gv0 cluster.quorum-type auto

# ping-timeout: cuánto espera el cliente antes de declarar muerto a un brick.
# Default 42s => el I/O se BLOQUEA 42s ante caída de un brick. Bajarlo tiene coste
# (reconexiones espurias por microcortes) => cambiarlo con criterio, no por defecto.
$ sudo gluster volume set gv0 network.ping-timeout 20

# Rendimiento de lectura para archivos grandes
$ sudo gluster volume set gv0 performance.cache-size 1GB
$ sudo gluster volume set gv0 performance.io-thread-count 32
$ sudo gluster volume set gv0 performance.read-ahead on

# Self-heal granular (heal por entrada, no por directorio completo) — ya on arriba
$ sudo gluster volume set gv0 cluster.granular-entry-heal on
```

### 5.6 Montar en el cliente (FUSE nativo)

```bash
# Instalar el cliente
$ sudo dnf install -y glusterfs-fuse

# Montaje manual
$ sudo mount -t glusterfs gfs1:/gv0 /mnt/gv0
$ mount | grep gv0
gfs1:/gv0 on /mnt/gv0 type fuse.glusterfs (rw,relatime,user_id=0,group_id=0,default_permissions,allow_other,max_read=131072)
```

**fstab de producción con failover del volfile.** El cliente descarga el volfile de `gfs1`; si `gfs1` está caído en el momento del **montaje**, el mount falla salvo que le des servidores de respaldo:

```
# /etc/fstab
gfs1:/gv0  /mnt/gv0  glusterfs  defaults,_netdev,backup-volfile-servers=gfs2:gfs3,fetch-attempts=3  0  0
```

- `_netdev` → espera a la red antes de montar (systemd `remote-fs.target`).
- `backup-volfile-servers=gfs2:gfs3` → si `gfs1` no responde al descargar el volfile, prueba gfs2, luego gfs3. **Imprescindible para HA del montaje.** (Una vez montado, el cliente ya conoce a todos los bricks y sobrevive a la caída de cualquiera.)

Alternativa de acceso **NFS-Ganesha** (para clientes sin cliente Gluster, p.ej. ESXi, Windows vía NFS/SMB) — el NFS gluster nativo está deprecado (`nfs.disable on`); se usa Ganesha con FSAL_GLUSTER. Ejemplo de export:

```
# /etc/ganesha/ganesha.conf (fragmento)
EXPORT {
    Export_Id = 10;
    Path = "/gv0";
    Pseudo = "/gv0";
    Access_Type = RW;
    Squash = No_root_squash;
    FSAL {
        Name = GLUSTER;
        Hostname = "localhost";
        Volume = "gv0";
    }
    Protocols = "3", "4";
    Transports = "TCP";
}
```

---

## 6. Alta disponibilidad: quorum, arbiter y anti-split-brain

### 6.1 Los dos quorums (distinguirlos es examen puro)

| Quorum | Opción | Qué protege | Comportamiento |
|---|---|---|---|
| **Server quorum** | `cluster.server-quorum-type server` + `cluster.server-quorum-ratio 51%` | El **management plane** (glusterd). | Si un nodo queda en minoría (<ratio de peers conectados), su `glusterd` **para los bricks locales**. Evita que una isla particionada sirva datos. |
| **Client quorum** | `cluster.quorum-type auto\|fixed` (+ `quorum-count`) | El **data plane** (writes). | El translator AFR del cliente **rechaza escrituras** si no ve la mayoría de las réplicas. `auto` = mayoría; con arbiter el voto del arbiter cuenta para el quorum pero no puede ser la única fuente de datos. |

Con `replica 3 arbiter 1` + `quorum-type auto`: si cae **una** réplica de datos, sigue habiendo 2 votos (una réplica de datos + el arbiter) → **escritura permitida**. Si caen **las dos réplicas de datos** y solo queda el arbiter → el arbiter, al no tener datos, **rechaza** la escritura → se prioriza consistencia sobre disponibilidad. Ese es exactamente el escenario que evita split-brain.

### 6.2 Anatomía de un split-brain

AFR marca las réplicas divergentes con xattrs `trusted.afr.<vol>-client-N` (contadores de operaciones pendientes: data, metadata, entry). Hay **tres tipos** de split-brain:

1. **Data split-brain** — el contenido difiere entre réplicas.
2. **Metadata split-brain** — permisos/owner/xattrs difieren.
3. **Entry split-brain (GFID mismatch)** — dos ficheros con el mismo nombre tienen **GFIDs distintos** en distintos bricks (el más difícil).

El arbiter previene el data/metadata split-brain (mantiene el desempate), pero **no** el entry split-brain de GFID (por eso hay que operar con quorum). Ver [sección 9.4](#94-resolución-de-split-brain).

---

## 7. Scale-out y scale-up en caliente

### 7.1 Añadir capacidad (add-brick + rebalance)

Para crecer un `replica 3` a `distributed-replicated`, se añaden **múltiplos de la réplica** (aquí, de a 3 bricks):

```bash
# Añadir un segundo subvolumen replica-3-arbiter (gfs4/gfs5/gfs6 ya probeados)
$ sudo gluster volume add-brick gv0 replica 3 arbiter 1 \
    gfs4:/data/glusterfs/gv0/brick \
    gfs5:/data/glusterfs/gv0/brick \
    gfs6:/data/glusterfs/gv0/brick
volume add-brick: success

$ sudo gluster volume info gv0 | grep 'Number of Bricks'
Number of Bricks: 2 x (2 + 1) = 6
```

**Añadir bricks NO redistribuye datos automáticamente.** El layout DHT viejo sigue apuntando solo a los subvolumes antiguos. Hay que reequilibrar:

```bash
# fix-layout: recalcula los rangos de hash de los directorios (rápido, no mueve data)
$ sudo gluster volume rebalance gv0 fix-layout start
volume rebalance: gv0: success: Rebalance on gv0 has been started successfully.

# rebalance completo: recalcula layout Y migra los ficheros al brick correcto
$ sudo gluster volume rebalance gv0 start
volume rebalance: gv0: success: Rebalance on gv0 has been started successfully.
Use rebalance status command to check status of the rebalance process.

$ sudo gluster volume rebalance gv0 status
                                    Node Rebalanced-files          size       scanned      failures       skipped               status  run time in h:m:s
                               ---------      -----------   -----------   -----------   -----------   -----------         ------------     --------------
                               localhost            14203        58.2GB         41755             0            22          in progress        0:03:11
                                    gfs2             13980        57.6GB         41755             0            18          in progress        0:03:11
volume rebalance: gv0: success
```

### 7.2 Reemplazar un brick fallido (replace-brick)

```bash
# Sustituir gfs2 (disco muerto) por gfs2:/data/glusterfs/gv0/brick_new
$ sudo gluster volume replace-brick gv0 \
    gfs2:/data/glusterfs/gv0/brick \
    gfs2:/data/glusterfs/gv0/brick_new commit force
volume replace-brick: success: replace-brick commit force operation successful

# Disparar el heal para repoblar la nueva réplica desde las copias sanas
$ sudo gluster volume heal gv0 full
Launching heal operation to perform full self heal on volume gv0 has been successful
```

### 7.3 Reducir (remove-brick con drain de datos)

```bash
# Vaciar (migrar datos fuera) del subvolumen a eliminar, luego commit
$ sudo gluster volume remove-brick gv0 replica 3 \
    gfs4:/data/glusterfs/gv0/brick \
    gfs5:/data/glusterfs/gv0/brick \
    gfs6:/data/glusterfs/gv0/brick start

$ sudo gluster volume remove-brick gv0 replica 3 \
    gfs4:/... gfs5:/... gfs6:/... status     # esperar a 'completed'

$ sudo gluster volume remove-brick gv0 replica 3 \
    gfs4:/... gfs5:/... gfs6:/... commit
```

> **Nunca** hagas `remove-brick ... commit` sin `start`/`status completed` antes: `commit` directo **descarta** los datos que solo vivían en ese subvolumen.

---

## 8. Geo-replicación (DR asíncrona a otro sitio)

La replicación **síncrona** (AFR) es para HA dentro de un datacenter (latencia baja). Para **Disaster Recovery** a otra región se usa **geo-replication**: replicación **asíncrona, unidireccional (master → slave), sobre SSH**, con el daemon **`gsyncd`** que consume el **changelog** del brick (o hace un *xsync* hybrid crawl inicial).

```bash
# En el nodo master, generar y distribuir el par de claves geo-rep
$ sudo gluster-mountbroker setup ...   # (o modo root directo, más simple para lab)

# Crear la sesión master(gv0) -> slave(dr1::gv0_dr), empujando el certificado
$ sudo gluster volume geo-replication gv0 dr1::gv0_dr create push-pem
Creating geo-replication session between gv0 & dr1::gv0_dr has been successful

$ sudo gluster volume geo-replication gv0 dr1::gv0_dr start
Starting geo-replication session between gv0 & dr1::gv0_dr has been successful

$ sudo gluster volume geo-replication gv0 dr1::gv0_dr status

MASTER NODE    MASTER VOL    MASTER BRICK                   SLAVE USER    SLAVE           SLAVE NODE    STATUS     CRAWL STATUS       LAST_SYNCED
--------------------------------------------------------------------------------------------------------------------------------------------------
gfs1           gv0           /data/glusterfs/gv0/brick      root          dr1::gv0_dr     dr1           Active     Changelog Crawl    2026-08-12 14:22:07
gfs2           gv0           /data/glusterfs/gv0/brick      root          dr1::gv0_dr     dr1           Passive    N/A                N/A
```

- **Active/Passive:** dentro de cada réplica, solo un nodo empuja (Active); los demás quedan Passive listos para tomar el relevo.
- **CRAWL STATUS:** `Hybrid Crawl` (barrido inicial del filesystem) → `Changelog Crawl` (incremental, eficiente, lee el journal de cambios). Ver `Changelog Crawl` es el estado saludable de régimen.
- **LAST_SYNCED:** el RPO (Recovery Point Objective) real; el lag DR se mide aquí.

---

## 9. Verificación y diagnóstico de fallas

### 9.1 Ladder de verificación (de barato a caro)

```bash
# 1) ¿El pool está sano? Todos 'Connected'
$ sudo gluster peer status

# 2) ¿El volumen y TODOS los bricks están Online (Y con puerto y PID)?
$ sudo gluster volume status gv0
Status of volume: gv0
Gluster process                             TCP Port  RDMA Port  Online  Pid
------------------------------------------------------------------------------
Brick gfs1:/data/glusterfs/gv0/brick        49152     0          Y       2314
Brick gfs2:/data/glusterfs/gv0/brick        49152     0          Y       2287
Brick gfs3:/data/glusterfs/gv0/brick        49152     0          Y       2301
Self-heal Daemon on localhost               N/A       N/A        Y       2331
Self-heal Daemon on gfs2                    N/A       N/A        Y       2298
Self-heal Daemon on gfs3                    N/A       N/A        Y       2312

Task Status of Volume gv0
------------------------------------------------------------------------------
There are no active volume tasks

# 3) ¿Hay ficheros pendientes de heal? (idealmente 0)
$ sudo gluster volume heal gv0 info summary
Brick gfs1:/data/glusterfs/gv0/brick
Status: Connected
Total Number of entries: 0
Number of entries in heal pending: 0
Number of entries in split-brain: 0
Number of entries possibly healing: 0
...
```

Una `Online = N` en `volume status` es la señal #1 de un brick caído. Un `Pid` faltante o puerto `N/A` en un brick que debería estar arriba → el `glusterfsd` de ese brick no arrancó (revisar `/var/log/glusterfs/bricks/*.log`).

### 9.2 Localización de logs

| Log | Qué contiene |
|---|---|
| `/var/log/glusterfs/glusterd.log` | Management: probes, quorum, arranque de bricks |
| `/var/log/glusterfs/bricks/data-glusterfs-gv0-brick.log` | El `glusterfsd` de ese brick (ruta con `/`→`-`) |
| `/var/log/glusterfs/glustershd.log` | Self-heal daemon |
| `/var/log/glusterfs/<mnt-point>.log` | El cliente FUSE (nombre = punto de montaje con `-`) |
| `/var/log/glusterfs/geo-replication/` | Sesiones geo-rep / gsyncd |

### 9.3 Fallos frecuentes y su firma

**a) "Peer Rejected (Connected)"** — el peer conecta pero sus volfiles tienen un **checksum distinto** (configuración desincronizada, típico tras editar a mano o versiones distintas):

```bash
$ sudo gluster peer status
Hostname: gfs2
State: Peer Rejected (Connected)     # <-- síntoma

# Resolución en el nodo rechazado (gfs2):
$ sudo systemctl stop glusterd
$ sudo find /var/lib/glusterd -mindepth 1 -maxdepth 1 \
      ! -name glusterd.info ! -name peers -exec rm -rf {} +
$ sudo systemctl start glusterd     # resincroniza la config desde el pool
```

**b) "or a prefix of it is already part of a volume"** — al reutilizar un directorio que fue brick antes; Gluster lo detecta por los xattrs `trusted.glusterfs.volume-id` / `trusted.gfid`:

```bash
$ sudo gluster volume create gv1 replica 3 gfs1:/data/glusterfs/gv1/brick ...
volume create: gv1: failed: /data/glusterfs/gv1/brick is already part of a volume

# Limpiar el brick para reutilizarlo:
$ sudo setfattr -x trusted.glusterfs.volume-id /data/glusterfs/gv1/brick
$ sudo setfattr -x trusted.gfid /data/glusterfs/gv1/brick
$ sudo rm -rf /data/glusterfs/gv1/brick/.glusterfs
```

**c) Brick offline pese a que el filesystem está montado** — casi siempre **firewall** (falta abrir el rango `49152+`) o el `glusterfsd` que crasheó. Verificá el puerto y prueba conectividad:

```bash
$ sudo gluster volume status gv0 | grep gfs2
Brick gfs2:/data/glusterfs/gv0/brick        N/A       N/A        N       N/A   # Online=N

$ sudo ss -tlnp | grep 4915          # ¿escucha el brick?
$ sudo firewall-cmd --list-services  # ¿está 'glusterfs'?
```

### 9.4 Resolución de split-brain

```bash
# 1) Identificar los ficheros en split-brain
$ sudo gluster volume heal gv0 info split-brain
Brick gfs1:/data/glusterfs/gv0/brick
/proyectos/config.yaml
Status: Connected
Number of entries in split-brain: 1

Brick gfs2:/data/glusterfs/gv0/brick
/proyectos/config.yaml
Status: Connected
Number of entries in split-brain: 1

# 2a) Resolver por política automática — quedarse con el fichero MÁS GRANDE
$ sudo gluster volume heal gv0 split-brain bigger-file /proyectos/config.yaml
Healed /proyectos/config.yaml

# 2b) ...o con la última modificación
$ sudo gluster volume heal gv0 split-brain latest-mtime /proyectos/config.yaml

# 2c) ...o eligiendo un brick como fuente de verdad (cuando sabés cuál es correcto)
$ sudo gluster volume heal gv0 split-brain source-brick \
      gfs1:/data/glusterfs/gv0/brick /proyectos/config.yaml

# 3) Confirmar que ya no hay split-brain
$ sudo gluster volume heal gv0 info split-brain
...
Number of entries in split-brain: 0
```

Para **entry split-brain (GFID mismatch)** las políticas anteriores no aplican; hay que ir al brick, comparar `getfattr -d -m . -e hex <fichero>`, y borrar manualmente la copia incorrecta **más** su hardlink en `.glusterfs/xx/yy/<gfid>` para que el heal reconstruya. **La verdadera solución es prevenirlo con quorum + arbiter** — nunca correr `replica 2` sin quorum estricto.

### 9.5 Profiling y hotspots

```bash
# Perfilado de latencia por operación (FOP) — encender, medir, apagar
$ sudo gluster volume profile gv0 start
$ sudo gluster volume profile gv0 info
Brick: gfs1:/data/glusterfs/gv0/brick
---------------------------------------
      %-latency   Avg-latency   Min-Lat   Max-Lat   No. of calls         Fop
      ---------   -----------   -------   -------   ------------        ----
        41.20      1204.55 us   112.00us   9821.00us       88213       WRITE
        22.87       412.10 us    44.00us   3310.00us      142887      LOOKUP
        18.03       980.22 us    90.00us   7734.00us       31002        READ
...

# Top: ficheros más abiertos, lecturas/escrituras más pesadas, etc.
$ sudo gluster volume top gv0 open list-cnt 5
$ sudo gluster volume top gv0 read-perf bs 4096 count 1024 list-cnt 5

# Statedump: volcado profundo del estado interno de un brick (memoria, locks, xlators)
$ sudo gluster volume statedump gv0
# -> genera /var/run/gluster/<brick>.<pid>.dump.<timestamp>
```

`volume profile` es la primera herramienta cuando "Gluster va lento": si domina `LOOKUP`, es un workload de small-file castigado por el fan-out (rediseñar); si domina `WRITE` con latencia alta y usás replica, revisá red y `network.ping-timeout`.

### 9.6 Chequeo de coherencia rápido (smoke test end-to-end)

```bash
# Escribir en el cliente y verificar que llegó a los bricks de datos (no al arbiter)
$ echo "hola-gluster" | sudo tee /mnt/gv0/prueba.txt

$ ssh gfs1 'cat /data/glusterfs/gv0/brick/prueba.txt'
hola-gluster
$ ssh gfs2 'cat /data/glusterfs/gv0/brick/prueba.txt'
hola-gluster
$ ssh gfs3 'ls -l /data/glusterfs/gv0/brick/prueba.txt'   # arbiter: existe pero 0 bytes
-rw-r--r-- 2 root root 0 Aug 12 14:40 /data/glusterfs/gv0/brick/prueba.txt

# Ver los xattrs de heal (todos en cero => réplicas coherentes)
$ ssh gfs1 'getfattr -d -m . -e hex /data/glusterfs/gv0/brick/prueba.txt'
trusted.afr.gv0-client-1=0x000000000000000000000000
trusted.gfid=0x9c1e7a4b2d3f4e5a8b6c0d1f2e3a4b5c
```

El fichero de 0 bytes en el arbiter (`gfs3`) confirma visualmente que el arbiter guarda **solo metadatos**. Los contadores `trusted.afr.*` en cero confirman que no hay heal pendiente.

---

## 10. Aprovisionamiento dinámico en Kubernetes (Heketi + StorageClass)

Para PVs dinámicos, **Heketi** gestiona el ciclo de vida de volúmenes Gluster vía API REST. Manifiestos completos:

```yaml
# storageclass-glusterfs.yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: glusterfs-replica3
provisioner: kubernetes.io/glusterfs
parameters:
  resturl: "http://heketi.storage.svc:8080"
  restauthenabled: "true"
  restuser: "admin"
  secretNamespace: "storage"
  secretName: "heketi-admin-secret"
  volumetype: "replicate:3"
  volumenameprefix: "k8s"
reclaimPolicy: Delete
allowVolumeExpansion: true
```

```yaml
# pvc-datos.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: datos-app
spec:
  accessModes: ["ReadWriteMany"]        # RWX: la ventaja de Gluster sobre block storage
  storageClassName: glusterfs-replica3
  resources:
    requests:
      storage: 20Gi
```

Para montar un volumen Gluster **existente** (sin Heketi) hacen falta el `Endpoints` con las IPs de los peers y el `Service` sin selector:

```yaml
# glusterfs-endpoints.yaml
apiVersion: v1
kind: Endpoints
metadata:
  name: glusterfs-cluster
  namespace: storage
subsets:
  - addresses:
      - { ip: 10.0.20.11 }
      - { ip: 10.0.20.12 }
      - { ip: 10.0.20.13 }
    ports:
      - { port: 24007, protocol: TCP }
---
apiVersion: v1
kind: Service
metadata:
  name: glusterfs-cluster
  namespace: storage
spec:
  ports:
    - { port: 24007 }            # Service sin selector: solo referencia los Endpoints
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-gv0
spec:
  capacity: { storage: 200Gi }
  accessModes: ["ReadWriteMany"]
  glusterfs:
    endpoints: glusterfs-cluster
    path: gv0
    readOnly: false
  persistentVolumeReclaimPolicy: Retain
```

> **Nota de vigencia:** el in-tree provisioner `kubernetes.io/glusterfs` está **deprecado** en Kubernetes moderno; en clusters nuevos se usa un **CSI driver**. Para el examen LPIC-3 306 basta con entender el patrón Heketi→StorageClass→PVC y el rol de `Endpoints`/`Service` para volúmenes preexistentes.

---

## 11. Checklist operativo condensado (cheatsheet de examen)

```text
POOL      gluster peer probe <host> | peer status | pool list
VOLUMEN   gluster volume create <v> replica 3 arbiter 1 h1:/b h2:/b h3:/b
          gluster volume start|stop|info|status <v>
TIPOS     replica N | disperse D redundancy R | (distributed = sin keyword)
MONTAR    mount -t glusterfs h1:/v /mnt        (fstab: _netdev,backup-volfile-servers=)
CRECER    volume add-brick <v> [replica N] ...  →  volume rebalance <v> start
REEMPLAZAR volume replace-brick <v> old new commit force  →  volume heal <v> full
REDUCIR   volume remove-brick <v> ... start → status(completed) → commit
HA        cluster.server-quorum-type server | cluster.quorum-type auto | arbiter
HEAL      volume heal <v> info [summary|split-brain]
SPLITBRAIN volume heal <v> split-brain bigger-file|latest-mtime|source-brick <f>
GEO-REP   volume geo-replication <v> host::<slave> create push-pem | start | status
DIAG      volume status | heal info | profile info | top | statedump
LOGS      /var/log/glusterfs/{glusterd,glustershd,bricks/*,<mnt>}.log
PUERTOS   24007 glusterd · 49152+ bricks (uno por brick) · 111/2049 NFS-Ganesha
CONFIG    /etc/glusterfs/glusterd.vol · estado en /var/lib/glusterd/
```

---

## Referencias

- LPI — **Exam 306-300 Objectives** (objetivo 363.1 GlusterFS Storage Clusters): https://www.lpi.org/our-certifications/exam-306-objectives/
- Gluster — **Administrator Guide** (documentación oficial): https://docs.gluster.org/en/latest/Administrator-Guide/
- Gluster — **Setting Up Volumes** (tipos de volumen y sintaxis): https://docs.gluster.org/en/latest/Administrator-Guide/Setting-Up-Volumes/
- Gluster — **Arbiter volumes and quorum** (anti split-brain): https://docs.gluster.org/en/latest/Administrator-Guide/arbiter-volumes-and-quorum/
- Gluster — **Managing Volumes** (add/remove/replace-brick, rebalance, opciones): https://docs.gluster.org/en/latest/Administrator-Guide/Managing-Volumes/
- Gluster — **Geo Replication**: https://docs.gluster.org/en/latest/Administrator-Guide/Geo-Replication/
- Gluster — **Heal info and split-brain resolution**: https://docs.gluster.org/en/latest/Troubleshooting/resolving-splitbrain/
- Gluster — **Troubleshooting** (logs, statedump, peer rejected): https://docs.gluster.org/en/latest/Troubleshooting/
- Gluster — **Architecture** (DHT, translators, elastic hashing): https://docs.gluster.org/en/latest/Quick-Start-Guide/Architecture/
- Gluster — **Formatting and Mounting Bricks** (XFS `-i size=512`, LVM thin): https://docs.gluster.org/en/latest/Administrator-Guide/formatting-and-mounting-bricks/
- Kubernetes — **GlusterFS volumes / Endpoints** (referencia histórica in-tree): https://kubernetes.io/docs/concepts/storage/volumes/#glusterfs
- Código fuente y releases: https://github.com/gluster/glusterfs