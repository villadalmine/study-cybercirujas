# Tema 362.3: Sistemas de Archivos en Clúster

> **LPIC-3 306-300 — Alta Disponibilidad y Clústeres de Almacenamiento**
> Objetivo 362.3 · Peso del examen: 6.67
> *Los candidatos deben ser capaces de instalar y administrar sistemas de archivos GFS2 y OCFS2, incluyendo el uso de la infraestructura de clúster para estos sistemas de archivos. Esto incluye el uso del Distributed Lock Manager (DLM) y un conocimiento de CephFS, GlusterFS y Lustre.*

---

## 1. El problema en producción: qué resuelve realmente un sistema de archivos en clúster

Tomemos un clúster Pacemaker/Corosync de dos nodos con una LUN de SAN, un target iSCSI o un dispositivo DRBD funcionando en modo **dual-primary**. El dispositivo de bloques es visible y escribible desde ambos nodos simultáneamente. Ahora montá un sistema de archivos local ordinario — `ext4`, `xfs` — sobre esa LUN compartida desde **ambos** nodos a la vez y escribí en él.

El resultado es determinista y catastrófico: **corrupción casi instantánea e irrecuperable.**

La razón es que un sistema de archivos local asume que es la autoridad *única* sobre el dispositivo. Cachea inodos, el bitmap de bloques, la cabeza del journal y los bloques de directorio en la page cache del nodo y los escribe de vuelta de forma perezosa. El nodo A asigna el bloque 4711 al archivo `/a.log`; el nodo B, cuyo bitmap cacheado todavía muestra 4711 como libre, asigna el *mismo* bloque a `/b.log`. Ningún nodo ve jamás los buffers sucios del otro. El journal — diseñado para proteger contra una *caída*, no contra un *segundo escritor concurrente* — lo empeora: dos nodos reproduciendo dos journals sobre un mismo árbol de metadatos garantizan la divergencia.

```
        Node A page cache            Node B page cache
        ┌───────────────┐            ┌───────────────┐
        │ bitmap: 4711=0│            │ bitmap: 4711=0│   ← both think it's free
        │ inode /a.log  │            │ inode /b.log  │
        └───────┬───────┘            └───────┬───────┘
                │ write blk 4711 → a.log      │ write blk 4711 → b.log
                └──────────────┬──────────────┘
                               ▼
                    ┌───────────────────┐
                    │   Shared LUN      │   ← block 4711 written twice, silently
                    │   (SAN / iSCSI /  │      one file's data is gone,
                    │    DRBD primary)  │      metadata tree is inconsistent
                    └───────────────────┘
```

Hay dos familias de respuestas, y elegir la equivocada es el error arquitectónico más común en esta capa:

1. **Activo/pasivo con un FS local.** Mantené `xfs`/`ext4`, pero garantizá que el dispositivo esté montado en **exactamente un nodo a la vez**, forzado por ordenamiento + colocación de Pacemaker + **STONITH**. Simple, robusto y correcto para la mayoría de los servicios HA (bases de datos, cabeceras NFS). Pero solo un nodo sirve el I/O — sin escalado horizontal de lectura/escritura, y el failover incurre en un retardo de replay del journal + montaje.

2. **Activo/activo con un sistema de archivos en clúster.** Cada nodo monta el *mismo* dispositivo *al mismo tiempo* y lee/escribe concurrentemente. Esto requiere que el sistema de archivos coordine cada mutación de metadatos a nivel de todo el clúster a través de un **Distributed Lock Manager (DLM)**. Esto es GFS2 y OCFS2. Te compra el acceso concurrente (raíces web compartidas, `maildir` a nivel de clúster, pools de imágenes de VM, scratch compartido) al costo de un stack de clúster obligatorio y correctamente fenced y un round-trip de bloqueo sobre metadatos en contención.

Una familia separada y ortogonal — **sistemas de archivos distribuidos scale-out** (CephFS, GlusterFS, Lustre) — abandona por completo el dispositivo de bloques compartido. No hay una única LUN; los datos viven en los discos locales de servidores independientes y se replican o codifican con erasure coding a través de la red. Estos resuelven *escala* y *disponibilidad* en lugar de *acceso concurrente a una LUN*, y el examen requiere un conocimiento de ellos (§7).

El objetivo 362.3 trata fundamentalmente sobre **sistemas de archivos de clúster de disco compartido y el gestor de bloqueos que los hace seguros.**

---

## 2. Taxonomía y compromisos

### 2.1 Disco compartido vs. scale-out

| Propiedad | **Disco compartido** (GFS2, OCFS2) | **Scale-out / distribuido** (CephFS, GlusterFS, Lustre) |
|---|---|---|
| Sustrato de almacenamiento | Un dispositivo de bloques visible para todos los nodos (SAN/FC, iSCSI, SAS, DRBD dual-primary) | Servidores independientes con discos locales; sin LUN compartida |
| Mecanismo de coordinación | DLM sobre la interconexión del clúster | Servidores de metadatos (Ceph MDS, Lustre MDS) o ubicación algorítmica (Gluster DHT / CRUSH) |
| Redundancia de datos | Externa — la propia LUN (RAID/replicación de SAN/DRBD) | Incorporada — replicación o erasure coding entre nodos |
| **Fencing / STONITH** | **Obligatorio.** Un escritor descontrolado corrompe la LUN | No requerido para la corrección — el quórum + la replicación toleran la pérdida de nodos |
| Cantidad práctica de nodos | ~2–16 (GFS2), hasta ~32 (OCFS2) | De cientos a miles |
| Dominio de fallo de los datos | La LUN compartida es un SPOF salvo que se replique de forma independiente | Se tolera la pérdida de N réplicas / fragmentos de erasure |
| Sensibilidad a la red | La latencia de la interconexión determina el RTT de los bloqueos | El throughput/latencia determinan la ruta de datos |
| Uso canónico | Activo/activo sobre una SAN, clústeres pequeños, imágenes de VM compartidas | Objeto+archivo en la nube a escala, scratch de HPC, media |

**Regla general:** si tenés exactamente una LUN y un puñado de nodos, usá un FS de disco compartido. Si tenés muchos servidores cada uno con discos y necesitás crecer horizontalmente, usá un FS scale-out. No intentes hacer que un FS de disco compartido escale más allá de ~16 nodos; el tráfico de bloqueos del DLM sobre metadatos calientes se convierte en el cuello de botella mucho antes de eso.

### 2.2 GFS2 vs. OCFS2

| Característica | **GFS2** | **OCFS2** |
|---|---|---|
| Origen / mantenedor | Red Hat (Sistina → Red Hat) | Oracle |
| Módulo del kernel | `gfs2` | `ocfs2` |
| Gestor de bloqueos | **DLM** del kernel de Linux (`fs/dlm`) manejado por `dlm_controld` | **O2DLM** incorporado (stack O2CB) *o* DLM del kernel (stack de usuario Pacemaker/`pcmk`) |
| Stack de clúster | **Solo Corosync + Pacemaker** (obligatorio) | **O2CB** (autónomo) *o* Pacemaker |
| Fencing | STONITH vía Pacemaker (obligatorio) | O2CB **se auto-aísla (self-fence)** (kernel panic al perder el heartbeat) o STONITH vía Pacemaker |
| Unidad de concurrencia por nodo | **Journal** (`mkfs.gfs2 -j N`) | **Node slot** (`mkfs.ocfs2 -N N`) |
| Crecimiento en línea | `gfs2_grow` | `tunefs.ocfs2 -S` |
| Agregar journals/slots en línea | `gfs2_jadd -j N` | `tunefs.ocfs2 -N N` |
| Gestión de volúmenes | VG compartido vía `lvmlockd` (o CLVM heredado) | Partición cruda o CLVM |
| Heartbeat | Corosync (red) | Heartbeat de disco (local o global) + red, o Corosync (pcmk) |
| Distros principales | RHEL, SUSE (add-on Resilient Storage) | Oracle Linux (UEK), SUSE |
| Tamaño máximo práctico | ~100 TB | hasta 4 PB |
| Bloqueos POSIX (`fcntl`) | vía plock del DLM | vía plock del DLM/O2DLM |

**Modelo mental clave:** GFS2 *terceriza* todo lo relacionado con el clúster (membresía, fencing, transporte de bloqueos) al stack Pacemaker/Corosync/DLM. OCFS2 históricamente *trae su propio* stack (O2CB) y puede funcionar sin Pacemaker en absoluto — pero los despliegues modernos cada vez más lo integran en Pacemaker (`--cluster-stack=pcmk`) para que la misma política de STONITH gobierne a ambos.

### 2.3 Los tres scale-out (nivel de conocimiento — ver §7)

| | **CephFS** | **GlusterFS** | **Lustre** |
|---|---|---|---|
| Arquitectura | FS POSIX sobre RADOS; MON + OSD + **MDS** | FUSE, sin servidor de metadatos, hashing elástico (DHT) | MDS/MDT + OSS/OST, paralelo |
| Metadatos | Daemons MDS dedicados, particionado dinámico de subárboles | Distribuidos algorítmicamente (sin MDS) | Metadata Targets dedicados |
| Ubicación de datos | Mapa CRUSH | Translator DHT | Distribuido (striped) entre OSTs |
| Redundancia | Replicación / erasure coding | Volúmenes replicados / dispersed | Externa (RAID en OST) + failover |
| Punto óptimo | Bloque+objeto+archivo unificados, nube | Scale-out de archivos simple, appliances | HPC, throughput extremo, RDMA/InfiniBand |

---

## 3. El Distributed Lock Manager (DLM)

Todo en este objetivo se apoya en el DLM. Entendelo y el resto es contabilidad.

### 3.1 Herencia y modelo

El DLM en-kernel de Linux (`fs/dlm`, módulo `dlm`) es un descendiente directo del **VMS Distributed Lock Manager (VAXcluster, ~1984)**. Su tarea: permitir que nodos independientes se pongan de acuerdo sobre *quién puede hacer qué* con un recurso nombrado, de modo que como máximo un nodo mantenga un bloqueo incompatible en cualquier instante.

Conceptos centrales:

- **Lockspace** — un espacio de nombres nombrado de recursos de bloqueo. Cada sistema de archivos GFS2 montado crea un lockspace; CLVM/`lvmlockd` crea otro. Visible bajo `configfs` en `/sys/kernel/config/dlm/cluster/spaces/` y vía `dlm_tool ls`.
- **Lock resource** — un objeto nombrado (en GFS2, codificado a partir del tipo de glock + número de inodo/rgrp).
- **Lock** — una solicitud contra un recurso en uno de **seis modos**.
- **Lock Value Block (LVB)** — una pequeña porción de datos (típicamente de 32 bytes) adjunta a un recurso que el poseedor puede actualizar y que otros solicitantes pueden leer al concederse el bloqueo — GFS2 lo usa para transportar (piggyback) números de generación de metadatos.
- **Resource master / directory** — cada recurso es *masterizado* por un nodo (que lleva el registro de su cola de concesiones). Un **directorio** distribuido aparte mapea nombre de recurso → master. La masterización suele ser local al primer nodo que bloquea el recurso, minimizando los saltos de red para cargas de trabajo afines a un nodo.

### 3.2 Los seis modos de bloqueo y la matriz de compatibilidad

| Modo | Significado |
|---|---|
| **NL** | Null — sin acceso; un marcador de posición para mantener una referencia / leer el LVB |
| **CR** | Concurrent Read — lectura; permite a otros leer y escribir |
| **CW** | Concurrent Write — escritura; permite a otros escritura concurrente (el llamante hace su propia serialización) |
| **PR** | Protected Read — bloqueo de lectura compartido; sin escritores |
| **PW** | Protected Write — bloqueo de actualización; permite lectores concurrentes (CR), ningún otro escritor |
| **EX** | Exclusive — acceso exclusivo |

Compatibilidad (`Y` = los dos modos pueden mantenerse simultáneamente sobre el mismo recurso por nodos distintos):

```
         Held →
Req ↓    NL   CR   CW   PR   PW   EX
 NL      Y    Y    Y    Y    Y    Y
 CR      Y    Y    Y    Y    Y    N
 CW      Y    Y    Y    N    N    N
 PR      Y    Y    N    Y    N    N
 PW      Y    Y    N    N    N    N
 EX      Y    N    N    N    N    N
```

Leé esta matriz como la física del I/O activo/activo: muchos nodos pueden mantener **PR** (todos leyendo un archivo), pero en el instante en que uno solicita **EX** (para escribir metadatos/extender el inodo) todos los demás poseedores deben ser degradados primero — esa degradación es un round-trip de red, y es por lo que los *archivos calientes escritos de forma compartida entre nodos* son el clásico asesino del rendimiento de GFS2/OCFS2.

### 3.3 `dlm_controld` y la dependencia dura del fencing

`dlm_controld` (paquete `dlm`, RHEL/SUSE) es el daemon de espacio de usuario que:

1. Se une al closed process group (CPG) de Corosync para conocer la membresía del clúster.
2. Gestiona la entrada/salida de lockspaces e impulsa la **recuperación** cuando cambia la membresía.
3. **Bloquea la recuperación de bloqueos hasta que se confirme el fencing de un nodo caído.**

El punto 3 es el hecho operativo más importante de todo este tema. Cuando un nodo se cae, el DLM no debe conceder los bloqueos que ese nodo mantenía a nadie más hasta estar *seguro* de que el nodo muerto ya no puede tocar el almacenamiento compartido. Esa certeza proviene únicamente de una **operación de STONITH (fence) exitosa.** Por lo tanto:

> **Si el fencing no está configurado, o está configurado pero falla, todo el I/O del clúster hacia el sistema de archivos GFS2/OCFS2 se cuelga indefinidamente — en todos los nodos supervivientes — tras cualquier fallo de nodo.** Esto no es un bug; es el DLM negándose a arriesgar corrupción. Un "FS de clúster colgado después de que murió un nodo" casi siempre significa "el fencing no se completó."

`configfs` y herramientas relevantes:

```
/sys/kernel/config/dlm/cluster/          # tunables: comms, timers, protocol
/sys/kernel/config/dlm/cluster/spaces/   # active lockspaces
/sys/kernel/config/dlm/cluster/comms/    # node comms endpoints
```

```
dlm_tool ls               # list lockspaces + membership
dlm_tool status           # daemon + node status
dlm_tool lockdebug <ls>   # full lock dump for a lockspace
dlm_tool plocks <ls>      # POSIX (fcntl) locks held in a lockspace
dlm_tool dump             # in-kernel debug log
dlm_tool fence_ack <nid>  # (advanced) manual fence acknowledgement
```

---

## 4. GFS2 — Red Hat Global File System 2

### 4.1 Arquitectura interna

- **FS de disco compartido de 64 bits, con journaling y simétrico.** Sin nodo maestro de metadatos — cada nodo es un par que bloquea vía DLM.
- **Los journals son por nodo.** Un nodo necesita un journal privado para montar. `N` journals ⇒ hasta `N` montajes concurrentes. Quedarse sin journals es un fallo duro de montaje (se corrige en línea con `gfs2_jadd`).
- **Resource groups (rgrps).** El disco se divide en resource groups, cada uno con su propio bitmap de bloques. Un rgrp está protegido por un glock, así que más rgrps / de tamaño apropiado reducen la contención de asignación.
- **Glocks (global locks).** La abstracción de GFS2 sobre los bloqueos del DLM; un glock por objeto protegido. *Tipos* de glock que verás en la salida de depuración: `2` = inodo, `3` = resource group (rgrp), `5` = `iopen` (rastrea open/unlink entre nodos), `1` = trans, `4` = non-disk, `6` = flock, `9` = quota. El número de glock es el bloque de disco del objeto.
- **El mecanismo `withdraw`.** Al detectar una inconsistencia interna o un error de I/O, GFS2 **no** hace panic del nodo ni (peor) sigue escribiendo basura — se **retira (withdraw)** del clúster: deja de tocar ese sistema de archivos, libera su journal para que otro nodo lo recupere, y registra `withdrawing from cluster`. La recuperación requiere desmontar en ese nodo (a menudo un reinicio). La opción de montaje `errors=panic` fuerza un panic en su lugar — útil cuando preferís hacer fence-y-reiniciar antes que dejar un montaje retirado.

### 4.2 Stack de clúster completo — RHEL 8/9 con VG compartido `lvmlockd`

Este es el procedimiento canónico y actual (RHEL Resilient Storage; SUSE es análogo con `crmsh`). Asume un clúster Pacemaker de 2 nodos en funcionamiento con **STONITH ya configurado y probado**.

**Paquetes (todos los nodos):**

```bash
$ sudo dnf install -y dlm lvm2-lockd gfs2-utils
```

**Habilitá el daemon de bloqueo de VG compartido en LVM (todos los nodos) — `/etc/lvm/lvm.conf`:**

```
    # Type 1 = sanlock, 2 = dlm.  For a Pacemaker/Corosync cluster use dlm.
    use_lvmlockd = 1
```

**Política de Pacemaker — congelar (freeze) ante pérdida de quórum para que el DLM se recupere correctamente:**

```bash
$ sudo pcs property set no-quorum-policy=freeze
```

**Recursos de bloqueo (DLM + lvmlockd), clonados y ordenados `dlm → lvmlockd`:**

```bash
# Both resources live in a group so they start/stop as a unit, then clone it.
$ sudo pcs resource create dlm ocf:pacemaker:controld \
      op monitor interval=30s on-fail=fence \
      --group locking

$ sudo pcs resource create lvmlockd ocf:heartbeat:lvmlockd \
      op monitor interval=30s on-fail=fence \
      --group locking

$ sudo pcs resource clone locking interleave=true
```

**Creá el VG compartido y un volumen lógico (en UN nodo):**

```bash
$ sudo vgcreate --shared shared_vg1 /dev/sdb1
  Physical volume "/dev/sdb1" successfully created.
  Logical volume lock manager (lvmlockd) started.
  Volume group "shared_vg1" successfully created
  VG shared_vg1 starting dlm lockspace
  Starting locking.  Waiting until locks are ready...

$ sudo lvcreate -l 100%FREE -n shared_lv1 shared_vg1
  Logical volume "shared_lv1" created.
```

**En el OTRO nodo, iniciá el lockspace para que el VG compartido sea visible:**

```bash
$ sudo vgchange --lockstart shared_vg1
  VG shared_vg1 starting dlm lockspace
  Starting locking.  Waiting until locks are ready...
```

**Activación del LV en modo compartido como recurso Pacemaker clonado:**

```bash
$ sudo pcs resource create sharedlv1 ocf:heartbeat:LVM-activate \
      lvname=shared_lv1 vgname=shared_vg1 \
      activation_mode=shared vg_access_mode=lvmlockd \
      --group shared_vg1

$ sudo pcs resource clone shared_vg1 interleave=true
```

**Orden + colocación: el almacenamiento debe iniciarse después del bloqueo en cada nodo:**

```bash
$ sudo pcs constraint order start locking-clone then shared_vg1-clone
Adding locking-clone shared_vg1-clone (kind: Mandatory)

$ sudo pcs constraint colocation add shared_vg1-clone with locking-clone
```

### 4.3 Creando el sistema de archivos — `mkfs.gfs2`

La tabla de bloqueo `-t` es **`<clustername>:<fsname>`**. `<clustername>` **debe** coincidir exactamente con el nombre de tu clúster de Corosync, o el montaje será rechazado. `-p lock_dlm` selecciona el bloqueo en clúster; `-p lock_nolock` crea un FS solo de un nodo (sin clúster) — nunca montes un FS `lock_nolock` en dos nodos.

```bash
$ sudo mkfs.gfs2 -p lock_dlm -t my_cluster:gfs2demo1 -j 2 /dev/shared_vg1/shared_lv1
It appears to contain an existing filesystem (lvm2)
This will destroy any data on /dev/shared_vg1/shared_lv1
Are you sure you want to proceed? [y/n] y
Discarding device contents (may take a while on large devices): Done
Adding journals: Done
Building resource groups: Done
Creating quota file: Done
Writing superblock and syncing: Done
Device:                    /dev/shared_vg1/shared_lv1
Block size:                4096
Device size:               10.00 GB (2621440 blocks)
Filesystem size:           10.00 GB (2621438 blocks)
Journals:                  2
Journal size:              32MB
Resource groups:           41
Locking protocol:          "lock_dlm"
Lock table:                "my_cluster:gfs2demo1"
UUID:                      7f3d2c1b-9a84-4e6f-b210-8c5e4d9a1f77
```

Opciones clave de `mkfs.gfs2`:

| Opción | Significado |
|---|---|
| `-p lock_dlm` \| `lock_nolock` | Protocolo de bloqueo (en clúster vs. autónomo) |
| `-t clus:fs` | Nombre de la tabla de bloqueo — el nombre del clúster **debe** coincidir con Corosync |
| `-j N` | Número de journals (⇒ máx. montajes simultáneos). Regla: `journals ≥ nodes` |
| `-J size` | Tamaño del journal en MB (por defecto 128, mín. 8; más grande ayuda en escrituras intensivas en metadatos) |
| `-r MB` | Tamaño del resource group (auto por defecto; ajustá para FS muy grandes o con contención) |
| `-b bytes` | Tamaño de bloque (por defecto 4096; mantené 4096 salvo que sepas por qué) |
| `-o align=…` | Alinear los rgrps a la geometría de stripe del almacenamiento |
| `-O` | Omitir el prompt de "¿estás seguro?" (scripting) |

### 4.4 Recurso de sistema de archivos y montaje

Dejá que Pacemaker lo monte como un clon (un montaje por nodo), ordenado después del VG compartido:

```bash
$ sudo pcs resource create sharedfs1 ocf:heartbeat:Filesystem \
      device="/dev/shared_vg1/shared_lv1" \
      directory="/mnt/gfs2demo1" \
      fstype="gfs2" options="noatime,nodiratime" \
      op monitor interval=10s on-fail=fence \
      --group shared_vg1
```

Como `sharedfs1` está en el grupo `shared_vg1` ya clonado, hereda el clon y se monta en cada nodo. Verificá:

```bash
$ sudo pcs status --full | grep -A6 'Clone Set: shared_vg1-clone'
  * Clone Set: shared_vg1-clone [shared_vg1]:
    * Started: [ node1 node2 ]

$ cat /proc/mounts | grep gfs2
/dev/mapper/shared_vg1-shared_lv1 /mnt/gfs2demo1 gfs2 rw,noatime,nodiratime 0 0
```

El montaje manual (para pruebas fuera de Pacemaker) usa el helper `mount.gfs2` de forma implícita:

```bash
$ sudo mount -t gfs2 -o noatime /dev/shared_vg1/shared_lv1 /mnt/gfs2demo1
```

Opciones de montaje importantes de GFS2:

| Opción | Efecto |
|---|---|
| `lockproto=lock_dlm` | Sobrescribe el protocolo de bloqueo en disco (rara vez necesario) |
| `locktable=clus:fs` | Sobrescribe la tabla de bloqueo en disco (p. ej. clúster renombrado) |
| `noatime,nodiratime` | Evita una escritura de glock de metadatos en cada lectura — **muy recomendado** |
| `data=ordered` \| `writeback` | Ordenamiento de datos del journal (ordered es más seguro, el valor por defecto) |
| `errors=withdraw` \| `panic` | Ante un error, retirarse (withdraw, por defecto) o hacer panic del nodo |
| `quota=on\|off\|account` | Habilitar/contabilizar cuotas |
| `statfs_percent=N` | Acota la inexactitud de `df` frente al costo de sincronización para un `statfs` rápido |

### 4.5 Crecer, agregar journals, ajustar, reparar

**Crecer en línea** (después de extender primero el LV):

```bash
$ sudo lvextend -L +5G /dev/shared_vg1/shared_lv1
  Size of logical volume shared_vg1/shared_lv1 changed from 10.00 GiB to 15.00 GiB.

$ sudo gfs2_grow /mnt/gfs2demo1
FS: Mount point:             /mnt/gfs2demo1
FS: Device:                  /dev/mapper/shared_vg1-shared_lv1
FS: Size:                    2621438 (0x27fffe)
DEV: Length:                 3932160 (0x3c0000)
The file system will grow by 5120MB.
gfs2_grow complete.
```

**Agregar un journal en línea** (antes de agregar un tercer nodo, para que pueda montar):

```bash
$ sudo gfs2_jadd -j 1 /mnt/gfs2demo1
Filesystem: /mnt/gfs2demo1
Old journals: 2
New journals: 3
```

**Inspeccionar / ajustar el superbloque** con `tunegfs2` (el reemplazo moderno del viejo `gfs2_tool`):

```bash
$ sudo tunegfs2 -l /dev/shared_vg1/shared_lv1
tunegfs2 (device /dev/shared_vg1/shared_lv1)
Filesystem volume name:   my_cluster:gfs2demo1
Filesystem UUID:          7f3d2c1b-9a84-4e6f-b210-8c5e4d9a1f77
Filesystem magic number:  0x1161970
Block size:               4096
Filesystem size:          15.00 GB
Journals:                 3
Resource groups:          61
Locking protocol:         lock_dlm
Lock table:               my_cluster:gfs2demo1

# Re-point a filesystem at a renamed cluster (UNMOUNTED everywhere first):
$ sudo tunegfs2 -o locktable=new_cluster:gfs2demo1 /dev/shared_vg1/shared_lv1
```

**Inspección / reparación offline de bajo nivel** con `gfs2_edit` (peligroso; desmontá en todos lados):

```bash
$ sudo gfs2_edit -p sb /dev/shared_vg1/shared_lv1   # dump superblock
$ sudo gfs2_edit -p rindex /dev/shared_vg1/shared_lv1   # resource index
$ sudo gfs2_edit savemeta /dev/shared_vg1/shared_lv1 /root/gfs2.meta   # metadata image for support
```

**Comprobar/reparar** con `fsck.gfs2` — **el sistema de archivos debe estar desmontado en TODOS los nodos.** Ejecutarlo contra un GFS2 montado lo corromperá:

```bash
# 1) Take the FS clone out of the cluster so nothing remounts it:
$ sudo pcs resource disable sharedfs1

# 2) Confirm unmounted everywhere (run on each node):
$ mount | grep gfs2 || echo "not mounted here"
not mounted here

# 3) Now repair:
$ sudo fsck.gfs2 -y /dev/shared_vg1/shared_lv1
Initializing fsck
Validating Resource Group index.
Level 1 rgrp check: Checking if all rgrp and rindex values are good.
(level 1 passed)
Starting pass1
Pass1 complete
...
Starting pass5
Pass5 complete
Writing changes to disk
gfs2_fsck complete

# 4) Re-enable:
$ sudo pcs resource enable sharedfs1
```

---

## 5. OCFS2 — Oracle Cluster File System 2

### 5.1 Arquitectura y los dos stacks

OCFS2 es un FS de disco compartido de 64 bits de propósito general en el kernel mainline. Su característica distintiva frente a GFS2 es que trae un **stack de clúster autónomo, O2CB**, de modo que puede funcionar activo/activo **sin** Pacemaker en absoluto — históricamente su principal atractivo para despliegues de Oracle RAC.

Dos stacks, seleccionables en el momento del formateo y del arranque:

- **`o2cb`** (por defecto, incorporado): membresía + un **heartbeat de disco** + una red TCP (puerto **7777**) + el **O2DLM** en-kernel. Configurado a través de `/etc/ocfs2/cluster.conf` y `/etc/sysconfig/o2cb`. Ante la pérdida del heartbeat más allá de un umbral, un nodo **se auto-aísla (self-fence) mediante kernel panic** — el equivalente de STONITH, hecho desde adentro.
- **`pcmk`** (stack de usuario): membresía/fencing desde **Pacemaker/Corosync**, bloqueo vía el **`fs/dlm`** del kernel (el mismo DLM que GFS2). Se elige con `--cluster-stack=pcmk` / `mount.ocfs2 -o cluster_stack=pcmk`. Usá esto cuando OCFS2 deba compartir una única política de STONITH con el resto de un clúster Pacemaker.

Unidad de concurrencia por nodo = **node slot** (`-N`), directamente análoga a un journal de GFS2.

### 5.2 Configuración del stack O2CB

Construí `/etc/ocfs2/cluster.conf` — ya sea editándolo directamente (indentado con tabuladores; **tabuladores, no espacios**) o generándolo con `o2cb`.

**Generado con `o2cb` (recomendado, ejecutá en un nodo y luego copiá el archivo a todos):**

```bash
$ sudo o2cb add-cluster ocfs2cluster
$ sudo o2cb add-node ocfs2cluster node1 --ip 192.168.100.11 --port 7777 --number 0
$ sudo o2cb add-node ocfs2cluster node2 --ip 192.168.100.12 --port 7777 --number 1
```

`/etc/ocfs2/cluster.conf` resultante:

```
cluster:
	heartbeat_mode = local
	node_count = 2
	name = ocfs2cluster

node:
	number = 0
	cluster = ocfs2cluster
	ip_port = 7777
	ip_address = 192.168.100.11
	name = node1

node:
	number = 1
	cluster = ocfs2cluster
	ip_port = 7777
	ip_address = 192.168.100.12
	name = node2
```

> El `name` de cada nodo **debe ser igual a `hostname -s`** en ese nodo, y la IP debe ser la interconexión que los nodos usan para alcanzarse entre sí.

**Heartbeat global vs. local.** El heartbeat *local* escribe una región de heartbeat en **cada** volumen OCFS2 — el I/O escala con la cantidad de volúmenes montados. El heartbeat *global* usa **un** dispositivo de heartbeat dedicado compartido por todo el clúster, desacoplando el costo del heartbeat de la cantidad de volúmenes — preferido cuando montás muchos volúmenes OCFS2:

```bash
# Format a small dedicated device for global heartbeat, then register it:
$ sudo o2cb add-heartbeat ocfs2cluster /dev/sdb1
$ sudo o2cb heartbeat-mode ocfs2cluster global
```

**Parámetros del stack — `/etc/sysconfig/o2cb`** (Debian/SUSE: `/etc/default/o2cb`). Estos gobiernan directamente qué tan agresivamente un nodo se auto-aísla:

```bash
# O2CB cluster configuration.
O2CB_ENABLED=true
O2CB_STACK=o2cb
O2CB_BOOTCLUSTER=ocfs2cluster
# Iterations before a node is considered dead (each ~2s) → (T-1)*2s:
O2CB_HEARTBEAT_THRESHOLD=31
# Network idle timeout before a connection is torn down (ms):
O2CB_IDLE_TIMEOUT_MS=30000
# Keepalive packet interval (ms):
O2CB_KEEPALIVE_DELAY_MS=2000
# Delay between reconnect attempts (ms):
O2CB_RECONNECT_DELAY_MS=2000
```

`O2CB_HEARTBEAT_THRESHOLD=31` ⇒ un nodo se aísla (fence) tras ~`(31-1)*2 = 60 s` de heartbeats de disco perdidos. Demasiado bajo → auto-aislamientos espurios ante latencia transitoria de la SAN; demasiado alto → failover lento. Ajustá a la latencia de peor caso de tu almacenamiento.

**Iniciá el stack (todos los nodos) y habilitá en el arranque:**

```bash
$ sudo o2cb register-cluster ocfs2cluster
$ sudo systemctl enable --now o2cb
$ sudo systemctl enable --now ocfs2      # mounts OCFS2 entries from /etc/fstab

$ sudo o2cb cluster-status
Cluster 'ocfs2cluster' is online

$ sudo systemctl status o2cb --no-pager
● o2cb.service - Load o2cb Modules
   Active: active (exited) since ...
```

### 5.3 Formateo — `mkfs.ocfs2`

`-N` fija los **node slots** (máx. montajes simultáneos). `-T` aplica una plantilla de características (`mail` = muchos archivos pequeños, `datafiles` = pocos archivos grandes con clusters grandes, `vmstore` = imágenes de VM).

```bash
$ sudo mkfs.ocfs2 -N 4 -L "ocfs2vol" \
      --cluster-name=ocfs2cluster --cluster-stack=o2cb \
      /dev/sdc1
mkfs.ocfs2 1.8.7
Cluster stack: o2cb
Cluster name: ocfs2cluster
Stack Flags: 0x0
NTP enabled: no
Overwriting existing ocfs2 partition.
WARNING: Cluster check disabled.
Proceed (y/N): y
Label: ocfs2vol
Features: sparse extended-slotmap backup-super unwritten inline-data strict-journal-super
Features: metaecc xattr indexed-dirs refcount discontig-bg append-dio
Block size: 4096 (12 bits)
Cluster size: 4096 (12 bits)
Volume size: 10733223936 (2620416 clusters) (2620416 blocks)
Cluster groups: 82 (tail covers 5568 clusters, rest cover 32256 clusters)
Extent allocator size: 4194304 (1 groups)
Journal size: 67108864
Node slots: 4
Creating bitmaps: done
Initializing superblock: done
Writing system files: done
Writing superblock: done
Writing backup superblock: 3 block(s)
Formatting Journals: done
Growing extent allocator: done
Formatting slot map: done
Formatting quota files: done
Writing lost+found: done
mkfs.ocfs2 successful
```

Opciones clave de `mkfs.ocfs2`:

| Opción | Significado |
|---|---|
| `-N n` | Node slots (máx. montajes concurrentes) — crecé después con `tunefs.ocfs2 -N` |
| `-J size=…` | Tamaño del journal por slot |
| `-b bytes` | Tamaño de bloque (512–4096) |
| `-C bytes` | Tamaño de cluster (asignación) (4 KB–1 MB) — grande para VM/datafiles |
| `-T mail\|datafiles\|vmstore` | Plantilla de características/geometría |
| `--fs-features=…` | Activar/desactivar características (p. ej. `+refcount`, `-inline-data`) |
| `--cluster-stack=o2cb\|pcmk` | En qué stack de clúster confía este volumen |
| `--cluster-name=NAME` | Nombre del clúster propietario |
| `-L label` | Etiqueta del volumen |

### 5.4 Montaje

```bash
$ sudo mkdir -p /mnt/ocfs2vol
$ sudo mount -t ocfs2 /dev/sdc1 /mnt/ocfs2vol

# Persistent — note _netdev so it mounts after the network + o2cb:
$ grep ocfs2 /etc/fstab
/dev/sdc1  /mnt/ocfs2vol  ocfs2  _netdev,defaults  0  0

# For the Pacemaker (pcmk) stack instead of O2CB:
$ sudo mount -t ocfs2 -o cluster_stack=pcmk /dev/sdc1 /mnt/ocfs2vol
```

### 5.5 El conjunto de herramientas de OCFS2

**`o2info` — introspección del sistema de archivos / características:**

```bash
$ o2info --volinfo /dev/sdc1
        Label: ocfs2vol
         UUID: 7B5B8F1C2D3E4F5A6B7C8D9E0F1A2B3C
   Block Size: 4096
 Cluster Size: 4096
   Node Slots: 4
     Features: backup-super strict-journal-super sparse extended-slotmap
     Features: inline-data metaecc xattr indexed-dirs refcount discontig-bg
     Features: unwritten append-dio

$ o2info --fs-features /dev/sdc1
backup-super strict-journal-super sparse extended-slotmap inline-data metaecc ...

$ o2info --freefrag /mnt/ocfs2vol      # free-space fragmentation report
```

**`mounted.ocfs2` — quién lo tiene, y dónde:**

```bash
# -d : detect OCFS2 volumes on the system (from disk labels/UUIDs)
$ sudo mounted.ocfs2 -d
Device      Stack  Cluster       F  UUID                              Label
/dev/sdc1   o2cb   ocfs2cluster     7B5B8F1C2D3E4F5A6B7C8D9E0F1A2B3C  ocfs2vol

# -f : which nodes currently have it mounted (reads the slot map)
$ sudo mounted.ocfs2 -f
Device      Stack  Cluster       F  Nodes
/dev/sdc1   o2cb   ocfs2cluster     node1, node2
```

**`tunefs.ocfs2` — redimensionar, agregar slots, reetiquetar, activar/desactivar características (mayormente en línea):**

```bash
# Grow the FS to fill an enlarged device (after extending the LUN/LV):
$ sudo tunefs.ocfs2 -S /dev/sdc1

# Add node slots so a 5th/6th node can mount:
$ sudo tunefs.ocfs2 -N 6 /dev/sdc1
Changing number of node slots from 4 to 6
Adding node slots: done
Growing extent allocator: done
Formatting Journals: done
Formatting slot map: done
Writing lost+found: done
tunefs.ocfs2 successful

# Relabel; move the volume to the pcmk stack:
$ sudo tunefs.ocfs2 -L "ocfs2prod" /dev/sdc1
$ sudo tunefs.ocfs2 --update-cluster-stack /dev/sdc1     # re-stamp owning stack
```

**`o2image` — guardar/restaurar metadatos (para soporte / forense, como `gfs2_edit savemeta`):**

```bash
$ sudo o2image /dev/sdc1 /root/ocfs2vol.image     # capture metadata only
$ sudo o2image -r /root/ocfs2vol.image /dev/sdd1  # restore metadata to a device
```

**`debugfs.ocfs2` — depurador interactivo en disco (inspección de solo lectura mientras está montado):**

```bash
$ sudo debugfs.ocfs2 /dev/sdc1
debugfs: stats            # superblock + feature flags
debugfs: slotmap          # which slot each node holds
        Slot#   Node#
            0       0
            1       1
debugfs: stat /somefile   # inode of a path
debugfs: fs_locks -B      # show DLM locks the FS holds (Blocked ones with -B)
debugfs: quit
```

**`fsck.ocfs2` — reparar (desmontá en TODOS los nodos primero):**

```bash
# Read-only forced check (safe to run on a mounted FS for a quick look):
$ sudo fsck.ocfs2 -fn /dev/sdc1

# Full repair — must be unmounted everywhere:
$ sudo fsck.ocfs2 -fy /dev/sdc1
fsck.ocfs2 1.8.7
Checking OCFS2 filesystem in /dev/sdc1:
  Label:              ocfs2vol
  UUID:               7B5B8F1C2D3E4F5A6B7C8D9E0F1A2B3C
  Number of blocks:   2620416
  Block size:         4096
  Number of clusters: 2620416
  Cluster size:       4096
  Number of slots:    6
/dev/sdc1 was run with -f, check forced.
Pass 0a: Checking cluster allocation chains
Pass 0b: Checking inode allocation chains
Pass 1: Checking inodes and blocks.
Pass 2: Checking directory entries.
Pass 3: Checking directory connectivity.
Pass 4a: checking for orphaned inodes
Pass 4b: Checking inodes link counts.
All passes succeeded.
```

**`o2cluster` — leer/reparar la información del stack de clúster estampada en un dispositivo:**

```bash
$ sudo o2cluster /dev/sdc1
o2cb,ocfs2cluster,0x0
```

---

## 6. Verificación y diagnóstico de fallos

El tema recurrente: en un FS de clúster de disco compartido, **un cuelgue es el sistema de archivos negándose correctamente a corromper la LUN.** Tu trabajo en un incidente es encontrar *qué* enclavamiento de seguridad está esperando y *por qué*.

### 6.1 Lista de verificación del estado saludable

**Clúster + fencing (ruta GFS2):**

```bash
$ sudo pcs status | sed -n '1,20p'
Cluster name: my_cluster
Status of pacemakerd: 'Pacemaker is running'
...
  * Clone Set: locking-clone [locking]:
    * Started: [ node1 node2 ]
  * Clone Set: shared_vg1-clone [shared_vg1]:
    * Started: [ node1 node2 ]

$ sudo pcs property show stonith-enabled
stonith-enabled: true

$ sudo pcs stonith status
  * fence_node1  (stonith:fence_ipmilan): Started node2
  * fence_node2  (stonith:fence_ipmilan): Started node1

# Prove fencing actually works BEFORE you rely on it:
$ sudo pcs stonith history show
We failed reboot node <none> (last known: ...)   # ← empty history is fine; a FAILED here is a red flag
```

**Quórum + membresía:**

```bash
$ sudo corosync-quorumtool -s
Quorate:          Yes
Nodes:            2
Node ID           Name
         1        node1
         2        node2

$ sudo corosync-cfgtool -s
Printing link status.
Local node ID 1
LINK ID 0
        addr = 192.168.100.11
        status: 1 1        # both links 'connected'
```

**Lockspaces del DLM presentes y poblados:**

```bash
$ sudo dlm_tool ls
dlm lockspaces
name          lvm_global
id            0x4104eefa
flags         0x00000000
change        member 2 joined 1 remove 0 failed 0 seq 1,1
members       1 2

name          gfs2demo1
id            0xef7a1234
flags         0x00000008 fs_reg
change        member 2 joined 1 remove 0 failed 0 seq 2,2
members       1 2

$ sudo dlm_tool status
cluster nodeid 1 quorate 1 ring seq 44 44
daemon now 1180 fence_pid 0
node 1 M add 40 rem 0 fail 0 fence 0 at 0 0
node 2 M add 40 rem 0 fail 0 fence 0 at 0 0
```

`members 1 2` en cada lockspace y `fence_pid 0` (sin fence en progreso) es el estado estable saludable.

### 6.2 Manual de fallos

| Síntoma | Causa probable | Diagnóstico | Solución |
|---|---|---|---|
| **El I/O de todos los nodos hacia el FS se cuelga después de que murió un nodo** | Fencing no configurado o fallando → el DLM no se recupera | `dlm_tool status` muestra `fence_pid` ≠ 0 / trabado; `pcs stonith history show` muestra FAILED; `journalctl -u pacemaker` "Requesting fencing"→sin confirmación | Arreglá STONITH (credenciales IPMI, red, agente). Una vez que el fence tiene éxito, la recuperación del DLM se desbloquea y el I/O se reanuda |
| **El montaje falla: `Can not mount ... no free journals`** (GFS2) | Más nodos que journals | `tunegfs2 -l <dev>` → `Journals:` < cantidad de nodos | `gfs2_jadd -j N /mnt/...` en línea, luego reintentá el montaje |
| **El montaje falla: `no free slots`** (OCFS2) | Más nodos que node slots | `o2info --volinfo <dev>` → `Node Slots:` demasiado bajo | `tunefs.ocfs2 -N <mayor> <dev>`, reintentá |
| **`dmesg`: `gfs2: fsid=…: withdrawing from cluster`** | Error de I/O o inconsistencia de metadatos detectada | `dmesg`/`journalctl -k`; el nodo dejó de usar el FS para protegerlo | Desmontá en ese nodo (usualmente reinicio); ejecutá `fsck.gfs2` **solo después de desmontar en todos lados** |
| **Un nodo se reinicia/hace panic espontáneamente** (OCFS2, O2CB) | O2CB se auto-aisló por timeout del heartbeat | `dmesg`/consola: `o2cb: o2net ... no longer connected` / "self-fencing"; revisá la latencia de SAN/red frente a `O2CB_HEARTBEAT_THRESHOLD` | Arreglá la latencia de la interconexión/SAN; subí el umbral si el almacenamiento es legítimamente lento |
| **Montaje rechazado: discrepancia de tabla de bloqueo / nombre de clúster** | El `-t clus:fs` en disco ≠ nombre del clúster en ejecución | `tunegfs2 -l <dev>` vs. `pcs property show cluster-name` (GFS2); `o2cluster <dev>` vs. `cluster.conf` (OCFS2) | Re-estampá: `tunegfs2 -o locktable=…` / `tunefs.ocfs2 --update-cluster-stack` |
| **Lentitud severa en todo el clúster bajo carga de escritura** | Contención de escritura entre nodos sobre los mismos inodos/rgrps (rebote de glock/DLM) | GFS2: `cat /sys/kernel/debug/gfs2/<fs>/glocks` muestra muchas solicitudes de degradación; OCFS2: `debugfs.ocfs2 -R 'fs_locks -B' <dev>` muestra bloqueos bloqueados | Particioná la carga de trabajo para que los archivos/directorios calientes sean afines a un nodo; agregá rgrps; usá `noatime` |
| **VG de CLVM/`lvmlockd` no visible en un nodo** | Lockspace no iniciado en ese nodo | En `dlm_tool ls` falta el lockspace `lvm_*`; `vgs` no muestra el VG compartido | `vgchange --lockstart <vg>` (asegurate de que los clones `lvmlockd`+`dlm` estén Started) |

### 6.3 Inspección profunda del DLM

```bash
# Blocked locks in a lockspace (who is waiting on whom):
$ sudo dlm_tool lockdebug gfs2demo1 | grep -i wait

# POSIX/fcntl locks the FS is holding across the cluster:
$ sudo dlm_tool plocks gfs2demo1

# GFS2 glock state (types: 2=inode 3=rgrp 5=iopen). 'W' waiters indicate contention:
$ sudo cat /sys/kernel/debug/gfs2/my_cluster:gfs2demo1/glocks | head
G:  s:SH n:2/1a4 f:Iqob t:SH d:EX/0 a:0 v:0 r:3 m:200
 H: s:SH f:H e:0 p:12345 [df]

# In-kernel DLM debug ring buffer (recovery events, fence waits):
$ sudo dlm_tool dump | tail -30
```

La secuencia de diagnóstico dorada para un "FS de clúster colgado": **¿quórum? → ¿miembros del DLM? → ¿hay un fence pendiente? → ¿el fencing tuvo éxito?** En ese orden. Nueve de cada diez veces el rastro termina en un fence que nunca se completó.

---

## 7. Conocimiento: CephFS, GlusterFS, Lustre

El objetivo requiere que *reconozcas* estos y sepas que pertenecen a una clase diferente — sistemas de archivos **distribuidos scale-out** — que no necesitan LUN compartida ni fencing de disco compartido al estilo DLM.

- **CephFS** — un sistema de archivos POSIX construido sobre el almacén de objetos **RADOS** de Ceph. Roles del clúster: **MON** (monitors, mantienen el mapa del clúster + quórum vía Paxos), **OSD** (object storage daemons, uno por disco, guardan los datos con replicación o erasure coding), y **MDS** (metadata servers, gestionan el espacio de nombres POSIX con particionado dinámico de subárboles). La ubicación la calcula **CRUSH**, así que no hay una búsqueda central de datos. Fortaleza: un clúster que sirve bloque (RBD), objeto (RGW) y archivo (CephFS) con redundancia auto-reparable. `ceph -s`, `ceph fs status`.

- **GlusterFS** — un FS scale-out en espacio de usuario, montado por **FUSE**, **sin servidor de metadatos**. Los archivos se ubican mediante un translator de **hashing elástico (DHT)**, así que no hay cuello de botella de metadatos ni SPOF. Tipos de volumen: **distributed** (repartido), **replicated** (espejado), **dispersed** (con erasure coding), y combinaciones. Se gestiona con `gluster volume create/info/status`. Fortaleza: simplicidad operativa y hardware commodity; debilidad: latencia con archivos pequeños e intensivos en metadatos.

- **Lustre** — el sistema de archivos paralelo de HPC detrás de la mayoría de las supercomputadoras más grandes del mundo. Roles: **MGS** (management), **MDS/MDT** (metadata targets), y **OSS/OST** (object storage targets que contienen los datos de archivo distribuidos en stripes). Un único archivo se distribuye en stripes entre muchos OSTs para obtener throughput agregado, típicamente sobre **RDMA/InfiniBand**. Fortaleza: ancho de banda paralelo extremo hacia miles de clientes; debilidad: complejidad operativa y escalado de metadatos para muchos archivos pequeños.

**Contraste de una línea para anclar el examen:** GFS2/OCFS2 = *muchos nodos, una LUN compartida, DLM + fencing*; CephFS/Gluster/Lustre = *muchos nodos, muchos discos locales, replicación por red, sin LUN compartida*.

---

## 8. Referencias

- LPI — Exam 306 Objectives (306-300, v3.0), Objetivo 362.3: <https://www.lpi.org/our-certifications/exam-306-objectives/>
- Documentación del kernel de Linux — GFS2: <https://www.kernel.org/doc/html/latest/filesystems/gfs2.html>
- Documentación del kernel de Linux — glocks de GFS2: <https://www.kernel.org/doc/html/latest/filesystems/gfs2-glocks.html>
- Documentación del kernel de Linux — OCFS2: <https://www.kernel.org/doc/html/latest/filesystems/ocfs2.html>
- Código fuente del kernel de Linux — DLM (`fs/dlm`): <https://www.kernel.org/doc/html/latest/filesystems/index.html>
- Red Hat Enterprise Linux 9 — Configuring GFS2 file systems: <https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/configuring_gfs2_file_systems/index>
- Red Hat Enterprise Linux 9 — Configuring and managing high availability clusters (DLM, fencing): <https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/configuring_and_managing_high_availability_clusters/index>
- Red Hat — Configuring and managing logical volumes (`lvmlockd`, VGs compartidos): <https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/configuring_and_managing_logical_volumes/index>
- Oracle Linux — Administering the OCFS2 File System: <https://docs.oracle.com/en/operating-systems/oracle-linux/8/fsadmin/ocfs2.html>
- Documentación del proyecto OCFS2 (o2cb, herramientas, cluster.conf): <https://oss.oracle.com/projects/ocfs2/documentation/>
- SUSE Linux Enterprise High Availability — capítulos de OCFS2 y GFS2: <https://documentation.suse.com/sle-ha/>
- Documentación de Ceph — CephFS: <https://docs.ceph.com/en/latest/cephfs/>
- Documentación de Gluster — Arquitectura y tipos de volumen: <https://docs.gluster.org/en/latest/>
- Documentación de Lustre — Lustre Manual: <https://doc.lustre.org/lustre_manual.xhtml>
- `mkfs.gfs2(8)`, `gfs2_grow(8)`, `gfs2_jadd(8)`, `fsck.gfs2(8)`, `tunegfs2(8)`, `gfs2_edit(8)`, `dlm_controld(8)`, `dlm_tool(8)`
- `mkfs.ocfs2(8)`, `tunefs.ocfs2(8)`, `fsck.ocfs2(8)`, `mounted.ocfs2(8)`, `o2info(1)`, `o2image(8)`, `o2cb(7)`, `debugfs.ocfs2(8)`, `o2cluster(8)`