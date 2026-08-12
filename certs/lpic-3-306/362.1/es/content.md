# Tema 362.1 — DRBD (Distributed Replicated Block Device)

> LPIC-3 Exam 306-300, v3.0 · Objetivo 362.1 · Peso 10 · Dominio 362 «Storage Clusters»
> Áreas de conocimiento evaluadas: arquitectura de DRBD; recursos, estados y modos; gestión y troubleshooting; integración con Pacemaker. Utilidades: `protocol A/B/C`, `Primary/Secondary`, `single/dual-primary`, `/proc/drbd`, `drbdadm`, `drbdsetup`, `drbdmeta`, `/etc/drbd.conf`, `/etc/drbd.d/`.

---

## 1. Motivación y problema arquitectónico de producción

En un cluster de alta disponibilidad hay un dato incómodo: **el storage es el único componente que no se puede reiniciar para arreglarlo**. Un proceso se relanza, una IP virtual migra, un contenedor se reschedula — pero los bytes de una base de datos son estado único e irrecuperable si se pierden. El problema de fondo del HA de servicios con estado (stateful) es *dónde vive el disco* cuando el nodo que lo servía muere.

Existen tres respuestas clásicas, y DRBD es una de ellas:

1. **Shared storage físico** (SAN por FC/iSCSI, NAS): un LUN accesible desde ambos nodos. El disco no muere con el nodo, pero **el propio array es un SPOF** (single point of failure) y un costo de capital enorme. Además introduce el problema de *fencing*: si dos nodos escriben el mismo LUN sin coordinación, se corrompe.

2. **Replicación a nivel aplicación** (streaming replication de PostgreSQL, replica sets de MongoDB, Galera para MySQL): excelente cuando existe, pero **no es genérica** — cada servicio la reimplementa, y muchos servicios (un NFS server, un filesystem con millones de archivos pequeños, un binario legacy) no la tienen.

3. **Replicación a nivel de block device**: DRBD. Convierte dos discos locales en nodos distintos en un **RAID-1 sobre la red**. Cualquier cosa que se monte sobre un block device — ext4, XFS, LVM, una DB, un swap — queda replicada de forma síncrona y **transparente para la capa superior**, sin storage compartido y sin cooperación de la aplicación.

El *architectural sweet spot* de DRBD es el **cluster shared-nothing de 2 (o pocos) nodos** donde se quiere failover con RPO≈0 (Recovery Point Objective, cero pérdida de datos) sin comprar una SAN. El caso canónico es el par **DRBD + Pacemaker + un filesystem local** sirviendo NFS, un PostgreSQL «single instance», o un stack de correo. DRBD **no es** un filesystem distribuido (no compitas con CephFS/GlusterFS para acceso concurrente multi-nodo a escala) ni un sistema de object storage; es replicación de bloques punto a punto (o mesh en DRBD 9).

Formalmente, DRBD (proyecto de LINBIT, mainline en el kernel Linux desde 2.6.33) es un driver de block device en el kernel que intercepta cada write y lo envía, además de a su disco local, al peer por TCP/IP (o RDMA en DRBD 9). El *cuándo* se considera completado ese write es lo que definen los **protocolos de replicación**, la primera decisión de diseño que hay que entender a fondo.

---

## 2. Arquitectura interna

### 2.1 La pila de I/O

```
        ┌───────────────────────────────┐        ┌───────────────────────────────┐
        │            NODO A             │        │            NODO B             │
        │  (Primary)                    │        │  (Secondary)                  │
        │                               │        │                               │
        │  Filesystem / DB / LVM        │        │      (block device NO montado│
        │        │                      │        │       en single-primary)      │
        │        ▼                      │        │                               │
        │  /dev/drbd0  (block device)   │        │  /dev/drbd0                   │
        │        │                      │        │        ▲                      │
        │   ┌────┴─────┐  módulo drbd   │        │   ┌────┴─────┐                │
        │   │ DRBD I/O │────────────────┼──TCP───┼──▶│ DRBD I/O │                │
        │   │  layer   │  protocolo C   │  7788  │   │  layer   │                │
        │   └────┬─────┘                │        │   └────┬─────┘                │
        │        ▼                      │        │        ▼                      │
        │  disk: /dev/vg0/lv_r0         │        │  disk: /dev/vg0/lv_r0         │
        │  meta-disk: internal          │        │  meta-disk: internal          │
        └───────────────────────────────┘        └───────────────────────────────┘
```

Puntos clave que el examen y la operación exigen entender:

- El objeto que la aplicación usa es el **DRBD device** (`/dev/drbdX`, major 147). Nunca se monta el *backing device* (`/dev/vg0/lv_r0`) directamente en un nodo con DRBD arriba: eso puentea la replicación y **garantiza corrupción**.
- El **backing device** (o *lower-level device*) es storage local real: una partición, un LV, una NVMe, incluso otro dispositivo RAID. DRBD no reemplaza a mdadm/LVM; se apila **encima**.
- La **metadata** (bitmap de bloques out-of-sync + Activity Log + UUIDs de generación) vive en `internal` (al final del backing device) o en un `external` device dedicado.

### 2.2 Activity Log y bitmap — por qué existen

Dos estructuras de metadata resuelven dos fallos distintos:

- **Activity Log (AL)**: un ring de *extents* «calientes» recientemente escritos. Si el nodo Primary *crashea*, tras el reboot no hay que resincronizar todo el disco: basta con re-verificar los extents que estaban en el AL (por defecto ~4 MiB × `al-extents`). Sin AL, un crash implicaría full resync de terabytes.
- **Quick-sync bitmap**: un bit por bloque que marca qué regiones difieren entre peers mientras están *desconectados*. Cuando reconectan, solo se transfieren los bloques marcados. Esto convierte un outage de red de horas en un resync de segundos si hubo poca escritura.

### 2.3 Generation UUIDs

DRBD etiqueta el estado de datos con **UUIDs de generación** (Current, Bitmap, History). Al reconectar, ambos peers comparan UUIDs para decidir automáticamente quién es `SyncSource` y quién `SyncTarget`, y para **detectar split-brain**: si ambos escribieron independientemente como Primary, sus Current-UUID divergen y DRBD *se niega a sincronizar en silencio* — señala split-brain y espera resolución. Este es el mecanismo que impide que DRBD «pise» datos automáticamente.

---

## 3. Protocolos de replicación A / B / C

La semántica de completado de un write es el trade-off central entre **durabilidad** y **latencia**:

| Protocolo | El write se «completa» cuando… | Durabilidad ante… | Latencia | RPO típico | Uso de producción |
|---|---|---|---|---|---|
| **A** (async) | los datos están en el disco local **y** en el *TCP send buffer* local | crash del Primary → OK; pero datos in-flight **se pierden** en failover | Mínima (no espera red) | > 0 (segundos de datos en vuelo) | Replicación **long-distance** / DR sobre WAN de alta latencia |
| **B** (memory-synchronous / semi-sync) | los datos están en disco local **y** han **llegado a la RAM** (buffer cache) del peer | crash de un solo nodo → OK. Pérdida simultánea de ambos (corte de energía del datacenter) puede perder el último write | Media (1 RTT hasta ACK de recepción) | ≈ 0 salvo doble fallo | Compromiso poco usado; enlaces intermedios |
| **C** (synchronous) | los datos están **en disco en ambos nodos** | pérdida de un nodo → **RPO=0**, sin pérdida | Alta (RTT + write remoto en el disco lento) | 0 | **Default y obligatorio para HA local con failover automático** |

Reglas de arquitecto:

- **Para un cluster Pacemaker con failover automático, usá Protocol C.** Es la única forma de garantizar que el Secondary tiene *exactamente* lo que confirmó el Primary; sin eso el promote tras un fallo puede exponer datos que la aplicación creía persistidos y no lo estaban.
- **Protocol A es para DR geográfico**, donde el RTT haría inaceptable el C. Se combina con `drbd-proxy` (componente comercial de LINBIT) para buffering ante congestión de WAN.
- La latencia de escritura *observada por la aplicación* en Protocol C es `max(disco_local, red_RTT + disco_remoto)`. Por eso en producción el **disco del Secondary y la NIC de replicación importan tanto como los del Primary**: el nodo lento marca el ritmo.

Configuración (dentro de `net {}`):

```
net {
    protocol C;
}
```

---

## 4. Roles, estados y modos

DRBD expone **tres ejes de estado** ortogonales que hay que leer siempre juntos. Confundirlos es la fuente #1 de errores de diagnóstico.

### 4.1 Rol (role) — `Primary` / `Secondary` / `Unknown`

El rol es una propiedad **por nodo, por recurso**. Solo un `Primary` puede montar/escribir el `/dev/drbdX`. Un `Secondary` **recibe** replicación pero rechaza cualquier open() de escritura (y de lectura, salvo excepciones). En la salida `ro:Primary/Secondary` el **primero es el nodo local**, el segundo es el peer.

### 4.2 Disk state (dstate) — la salud de los datos locales

| Estado | Significado |
|---|---|
| `Diskless` | No hay backing device atachado (fallo de disco o detach manual) |
| `Inconsistent` | Los datos **no** son usables (durante el initial sync o un resync como Target) |
| `Outdated` | Consistentes pero **viejos**: se sabe que hubo writes más nuevos en otro lado. DRBD lo marca al perder conexión para prevenir un promote peligroso |
| `Consistent` | Consistentes pero DRBD no puede afirmar que sean los más nuevos (estado transitorio, sin peer para comparar) |
| `UpToDate` | Consistentes **y** actuales. El único estado plenamente sano |
| `DUnknown` | No se conoce el dstate del peer (desconectado) |

`ds:UpToDate/UpToDate` = ambos discos sanos y al día. `ds:UpToDate/DUnknown` = local sano, peer desconectado. `ds:Inconsistent/UpToDate` = local sincronizándose desde un peer sano.

### 4.3 Connection state (cstate) — la relación con el peer

`StandAlone` (sin intentar conectar) · `Disconnected` · `Unconnected`/`Connecting`/`WFConnection` (esperando al peer) · `Connected` (replicación normal) · y los estados de resync: `SyncSource`/`SyncTarget`, `PausedSyncS`/`PausedSyncT`, `VerifyS`/`VerifyT` (durante `verify`), `WFBitMapS`/`WFBitMapT`.

### 4.4 Modos: single-primary vs dual-primary

| | **Single-primary** | **Dual-primary** |
|---|---|---|
| Nodos con rol Primary a la vez | 1 | 2 |
| Filesystem sobre `/dev/drbdX` | Local (ext4/XFS) | **Obligatorio** cluster FS (OCFS2, GFS2) |
| Requiere fencing/quorum | Recomendado | **Imprescindible** + `allow-two-primaries` |
| Caso de uso | Failover HA clásico (99% de despliegues) | Live migration de VMs, acceso concurrente coordinado |
| Riesgo de split-brain destructivo | Medio (mitigable) | **Alto** (dos writers simultáneos) |

Dual-primary **no es «para ir más rápido»**: sin un cluster filesystem que coordine el acceso concurrente al block device compartido, montar el mismo ext4 desde dos Primary corrompe el filesystem en segundos. Se habilita explícitamente:

```
net {
    protocol C;
    allow-two-primaries yes;
    after-sb-0pri discard-zero-changes;
    after-sb-1pri discard-secondary;
    after-sb-2pri disconnect;
}
```

---

## 5. Metadata: internal vs external

| | **Internal** | **External** |
|---|---|---|
| Dónde vive | Al final del **mismo** backing device | En un block device **separado** |
| Ventaja | Metadata viaja atómicamente con los datos; simple | Evita seeks entre datos y metadata → mejor latencia con discos rotacionales; permite meter DRBD sobre un dispositivo ya lleno de datos |
| Desventaja | Reduce la capacidad útil del backing device; requiere espacio libre al crear | Un device más que administrar; si se pierde, hay que recrear metadata |
| Cálculo de tamaño | ≈ **32 KiB por cada 1 GiB** de datos (36 MiB/TiB aprox.) | Igual, en device aparte |

Estimación del tamaño de metadata (para dimensionar el device o el espacio libre):

```
MD_sectores ≈ ⌈ tamaño_dispositivo_sectores / 2^18 ⌉ × 8 + 72
```

En la práctica: para un LV de 1 TiB reservá ~36 MiB. Si usás `internal` sobre un LV que vas a llenar entero, **encogé el filesystem primero** o la creación de metadata pisará datos.

Declaración en el recurso:

```
    meta-disk internal;
    # o:
    meta-disk /dev/vg0/lv_r0_meta;
    # con flexible-meta-disk:
    flexible-meta-disk /dev/vg0/lv_meta;
```

---

## 6. Configuración completa — `/etc/drbd.conf` y `/etc/drbd.d/`

`/etc/drbd.conf` normalmente solo incluye:

```
# /etc/drbd.conf
include "/etc/drbd.d/global_common.conf";
include "/etc/drbd.d/*.res";
```

### 6.1 `global_common.conf` (defaults comunes a todos los recursos)

```
# /etc/drbd.d/global_common.conf
global {
    usage-count no;          # no reportar estadísticas anónimas a LINBIT
    udev-always-use-vnr;
}

common {
    handlers {
        # Scripts invocados por DRBD ante eventos críticos.
        # Integran fencing con el cluster (STONITH) para evitar split-brain.
        fence-peer       "/usr/lib/drbd/crm-fence-peer.9.sh";
        after-resync-target "/usr/lib/drbd/crm-unfence-peer.9.sh";
        split-brain      "/usr/lib/drbd/notify-split-brain.sh root";
        pri-lost-after-sb "/usr/lib/drbd/notify-pri-lost-after-sb.sh; /usr/lib/drbd/notify-emergency-reboot.sh; echo b > /proc/sysrq-trigger; reboot -f";
        out-of-sync      "/usr/lib/drbd/notify-out-of-sync.sh root";
    }

    startup {
        wfc-timeout          15;   # segundos esperando al peer al bootear
        degr-wfc-timeout     120;  # si el peer ya estaba caído (degradado)
        outdated-wfc-timeout 15;
    }

    options {
        # Fencing a nivel DRBD: si pierde el peer y no puede outdatearlo, se protege.
        auto-promote no;           # en cluster, quien promueve es Pacemaker
    }

    disk {
        on-io-error       detach;  # ante error de disco: desataChar y seguir Diskless
        fencing           resource-and-stonith;  # crítico para HA
        al-extents        1237;    # tamaño del Activity Log (hot extents)
        disk-flushes      yes;     # respetar barreras/flush (integridad)
        md-flushes        yes;
        c-plan-ahead      20;      # controlador dinámico de resync rate
        c-fill-target     1M;
        c-max-rate        720M;
        c-min-rate        20M;
    }

    net {
        protocol             C;
        cram-hmac-alg        sha256;         # autenticación mutua del peer
        shared-secret        "R3empl4za_Este_Secreto";
        verify-alg           crc32c;         # algoritmo para online verify
        csums-alg            crc32c;         # checksums para resync eficiente
        max-buffers          36864;
        rcvbuf-size          10485760;
        sndbuf-size          10485760;
        max-epoch-size       20000;

        # Política de resolución de split-brain (single-primary típico):
        after-sb-0pri        discard-zero-changes;
        after-sb-1pri        discard-secondary;
        after-sb-2pri        disconnect;
        rr-conflict          disconnect;
    }
}
```

### 6.2 Recurso DRBD 8.4 (2 nodos)

```
# /etc/drbd.d/r0.res
resource r0 {
    device    /dev/drbd0 minor 0;
    disk      /dev/vg0/lv_r0;
    meta-disk internal;

    net {
        protocol C;
    }

    on node-a {
        address 10.10.0.1:7788;
    }
    on node-b {
        address 10.10.0.2:7788;
    }
}
```

### 6.3 Recurso DRBD 9 (3 nodos, connection mesh)

DRBD 9 rompe el límite de 2 nodos: hasta 32 peers por recurso, `node-id` explícito y una malla de conexiones. También soporta múltiples `volume` por recurso (para consistencia de crash entre varios discos, p.ej. data + WAL de una DB).

```
# /etc/drbd.d/r0.res   (DRBD 9)
resource r0 {
    volume 0 {
        device    /dev/drbd0;
        disk      /dev/vg0/lv_r0_data;
        meta-disk internal;
    }
    volume 1 {
        device    /dev/drbd1;
        disk      /dev/vg0/lv_r0_wal;
        meta-disk internal;
    }

    on alpha  { node-id 0; address 10.10.0.1:7788; }
    on bravo  { node-id 1; address 10.10.0.2:7788; }
    on charlie{ node-id 2; address 10.10.0.3:7788; }

    connection-mesh {
        hosts alpha bravo charlie;
    }
}
```

Los `node-id` deben ser **estables**: son la identidad del peer en la metadata. Cambiarlos requiere recrear metadata.

---

## 7. Comandos CLI: `drbdadm`, `drbdsetup`, `drbdmeta`

Los tres forman una jerarquía de abstracción:

| Herramienta | Nivel | Rol |
|---|---|---|
| `drbdadm` | Alto | **La que usás el 95% del tiempo.** Lee `/etc/drbd.d/`, traduce a llamadas de bajo nivel |
| `drbdsetup` | Bajo | Habla directo con el kernel via netlink; sin leer config. Para debugging fino y `events2` |
| `drbdmeta` | Bajo | Manipula la metadata on-disk (crear, dump, restaurar UUIDs). Peligroso; casi siempre via `drbdadm` |

### 7.1 Bring-up desde cero (ambos nodos)

```bash
# 1) Validar sintaxis de la config antes de tocar nada
$ drbdadm dump r0
# (imprime la config normalizada; falla ruidosamente si hay error)

# 2) Crear la metadata (en AMBOS nodos)
$ drbdadm create-md r0
initializing activity log
initializing bitmap (320 KB) to all zero
Writing meta data...
New drbd meta data block successfully created.
success

# 3) Cargar el módulo y levantar el recurso (en AMBOS nodos)
$ drbdadm up r0

# 4) Ver el estado — ambos arrancan Secondary/Secondary Inconsistent
$ drbdadm status r0
r0 role:Secondary
  disk:Inconsistent
  bravo role:Secondary
    peer-disk:Inconsistent
```

### 7.2 Sincronización inicial (SOLO en un nodo, el que tiene los datos «buenos»)

```bash
# Forzar a node-a como fuente de verdad e iniciar el full sync.
# --force sobreescribe: el peer se vuelve SyncTarget y se sobreescribe entero.
$ drbdadm primary --force r0

$ drbdadm status r0
r0 role:Primary
  disk:UpToDate
  bravo role:Secondary
    replication:SyncSource peer-disk:Inconsistent done:2.71
```

Vista clásica del progreso en DRBD 8.4 (`/proc/drbd`):

```bash
$ cat /proc/drbd
version: 8.4.11-1 (api:1/proto:86-101)
GIT-hash: ... build by mockbuild@, 2020-...

 0: cs:SyncSource ro:Primary/Secondary ds:UpToDate/Inconsistent C r-----
    ns:1048576 nr:0 dw:0 dr:1049240 al:0 bm:0 lo:0 pe:2 ua:0 ap:0 ep:1 wo:f oos:8340480
        [==>.................] sync'ed: 11.2% (8144/9168)M
        finish: 0:03:41 speed: 37,600 (37,600) K/sec
```

Decodificación de contadores (útil para diagnóstico):
`ns`=network send · `nr`=network receive · `dw`=disk write · `dr`=disk read · `al`=activity log updates · `bm`=bitmap updates · `lo`=local count (refs pendientes) · `pe`=pending (a peer, sin ACK) · `ua`=unacknowledged · `ap`=application pending · `oos`=**out of sync (KiB)** ← el número que querés en 0.

> En **DRBD 9** `/proc/drbd` es mínimo (solo versión); el estado se consulta con `drbdadm status` o `drbdsetup status --verbose --statistics`. No dependas de parsear `/proc/drbd` en 9.

Saltar el initial sync cuando el disco está garantizadamente vacío/idéntico (ahorra horas):

```bash
$ drbdadm new-current-uuid --clear-bitmap r0/0
```

### 7.3 Crear el filesystem y montar (solo en el Primary)

```bash
$ mkfs.xfs /dev/drbd0
meta-data=/dev/drbd0    isize=512  agcount=4, agsize=... blks
...
$ mkdir -p /srv/data
$ mount /dev/drbd0 /srv/data
$ echo "estado replicado" > /srv/data/prueba.txt
```

### 7.4 Failover manual controlado

```bash
# En node-a (Primary actual):
$ umount /srv/data
$ drbdadm secondary r0

# En node-b:
$ drbdadm primary r0
$ mount /dev/drbd0 /srv/data
$ cat /srv/data/prueba.txt
estado replicado          # ← el dato cruzó, RPO=0
```

### 7.5 `drbdsetup` y `drbdmeta` para diagnóstico

```bash
# Estado detallado con estadísticas de bajo nivel
$ drbdsetup status --verbose --statistics r0
r0 node-id:0 role:Primary suspended:no
  volume:0 minor:0 disk:UpToDate quorum:yes
      size:9437184 read:1049240 written:66 al-writes:2 bm-writes:0 ...
  bravo node-id:1 connection:Connected role:Secondary congested:no
    volume:0 replication:Established peer-disk:UpToDate resync-suspended:no
        received:0 sent:1048576 out-of-sync:0 pending:0 unacked:0

# Stream de eventos en tiempo real (lo que usan los resource agents)
$ drbdsetup events2 r0
exists resource name:r0 role:Primary suspended:no
exists connection name:r0 peer-node-id:1 conn:Connected role:Secondary
exists device name:r0 volume:0 minor:0 disk:UpToDate
exists peer-device name:r0 peer-node-id:1 volume:0 replication:Established peer-disk:UpToDate
exists -

# Dump de la metadata on-disk (UUIDs, flags) — read-only, seguro
$ drbdadm -- --force dump-md r0
# o directo:
$ drbdmeta 0 v09 /dev/vg0/lv_r0 internal dump-md
```

Subcomandos `drbdadm` de referencia rápida: `up`/`down`, `attach`/`detach`, `connect`/`disconnect`, `primary`/`secondary`, `adjust` (re-aplica cambios de config sin bajar el recurso), `status`/`cstate`/`dstate`/`role`, `verify`, `invalidate`/`invalidate-remote`, `pause-sync`/`resume-sync`, `resize`, `wait-connect`.

---

## 8. Redimensionar online (online grow)

Ventaja operativa real: crecer el volumen sin downtime, propagándolo a través de la pila LVM→DRBD→FS.

```bash
# En AMBOS nodos: crecer el backing LV
$ lvextend -L +50G /dev/vg0/lv_r0

# En el Primary: DRBD detecta el nuevo tamaño y resincroniza el delta
$ drbdadm resize r0

# Solo en el Primary: crecer el filesystem (XFS solo crece montado)
$ xfs_growfs /srv/data
```

---

## 9. Integración con Pacemaker

DRBD provee datos; **Pacemaker decide quién promueve y coordina el fencing**. Sin un cluster manager, un failover automático seguro es imposible: hace falta quórum y STONITH para evitar que dos nodos se crean Primary a la vez.

DRBD se modela como un **recurso promotable (clone master/slave)**: el estado `Master` de Pacemaker mapea a `Primary` de DRBD, `Slave` a `Secondary`. El resource agent es `ocf:linbit:drbd`.

### 9.1 Configuración con `pcs` (Pacemaker 2.x, RHEL/Rocky/Alma 8+)

```bash
# Recurso DRBD como clone promotable
$ pcs resource create p_drbd_r0 ocf:linbit:drbd \
    drbd_resource=r0 \
    op monitor interval=29s role=Promoted \
    op monitor interval=31s role=Unpromoted \
    promotable promoted-max=1 promoted-node-max=1 \
               clone-max=2 clone-node-max=1 notify=true

# Filesystem que se monta SOLO donde DRBD es Primary
$ pcs resource create fs_r0 ocf:heartbeat:Filesystem \
    device=/dev/drbd0 directory=/srv/data fstype=xfs

# IP de servicio virtual
$ pcs resource create vip_r0 ocf:heartbeat:IPaddr2 \
    ip=10.10.0.100 cidr_netmask=24 op monitor interval=20s

# Agrupar FS + VIP (van juntos y en orden)
$ pcs resource group add g_r0 fs_r0 vip_r0

# ORDEN Y COLOCACIÓN — el corazón de la corrección:
# el grupo solo corre donde DRBD fue PROMOVIDO, y DESPUÉS del promote.
$ pcs constraint colocation add g_r0 with promoted p_drbd_r0-clone INFINITY
$ pcs constraint order promote p_drbd_r0-clone then start g_r0
```

### 9.2 Equivalente con `crmsh` (SUSE / sintaxis clásica)

```
primitive p_drbd_r0 ocf:linbit:drbd \
    params drbd_resource="r0" \
    op monitor interval="29s" role="Master" \
    op monitor interval="31s" role="Slave" \
    op start timeout="240s" \
    op stop  timeout="100s"

ms ms_drbd_r0 p_drbd_r0 \
    meta master-max="1" master-node-max="1" \
         clone-max="2"  clone-node-max="1" notify="true"

primitive fs_r0 ocf:heartbeat:Filesystem \
    params device="/dev/drbd0" directory="/srv/data" fstype="xfs"

primitive vip_r0 ocf:heartbeat:IPaddr2 \
    params ip="10.10.0.100" cidr_netmask="24"

group g_r0 fs_r0 vip_r0

colocation col_r0 inf: g_r0 ms_drbd_r0:Master
order ord_r0 inf: ms_drbd_r0:promote g_r0:start
```

### 9.3 Fencing DRBD ↔ Pacemaker (el nudo del split-brain)

Los `handlers` `fence-peer`/`after-resync-target` del `global_common.conf` (sección 6.1) enganchan DRBD con Pacemaker: cuando DRBD pierde la réplica, invoca `crm-fence-peer.9.sh`, que **le pide a Pacemaker que ponga una constraint bloqueando la promoción del peer sospechoso** hasta que se pruebe que está `Outdated`. Combinado con `disk { fencing resource-and-stonith; }` y un STONITH real (IPMI, iLO, `fence_ipmilan`, o SBD por watchdog), esto cierra la ventana de split-brain automático.

```bash
# STONITH via IPMI para node-b, ejecutable desde node-a
$ pcs stonith create fence_node_b fence_ipmilan \
    pcmk_host_list="node-b" ipaddr="10.20.0.2" \
    lanplus=1 username="admin" password="secret" \
    op monitor interval=60s
```

Verificación del cluster completo:

```bash
$ pcs status
Cluster name: ha-drbd
Cluster Summary:
  * Stack: corosync
  * Current DC: node-a (version 2.1.x) - partition with quorum

Node List:
  * Online: [ node-a node-b ]

Full List of Resources:
  * Clone Set: p_drbd_r0-clone [p_drbd_r0] (promotable):
    * Promoted: [ node-a ]
    * Unpromoted: [ node-b ]
  * Resource Group: g_r0:
    * fs_r0     (ocf:heartbeat:Filesystem): Started node-a
    * vip_r0    (ocf:heartbeat:IPaddr2):    Started node-a
  * fence_node_b (stonith:fence_ipmilan):   Started node-a
```

---

## 10. DRBD 9 a escala: LINSTOR y CSI en Kubernetes

DRBD 9 introduce replicación multi-nodo, diskless clients (un nodo consume el device sin tener copia local, leyendo de peers por red) y transports pluggables (`tcp`, `rdma`). Gestionar cientos de recursos a mano es inviable: **LINSTOR** es el orquestador de LINBIT que provisiona LVM/ZFS + DRBD 9 declarativamente, y expone un **CSI driver** para Kubernetes. Aquí es donde el material se cruza con manifiestos declarativos de producción:

```yaml
# StorageClass: replica cada PV en 2 nodos con DRBD 9, protocolo C
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: linstor-replica2
provisioner: linstor.csi.linbit.com
parameters:
  autoPlace: "2"                      # 2 réplicas DRBD
  storagePool: "lvm-thin"
  csi.storage.k8s.io/fstype: xfs
  DrbdOptions/Net/protocol: "C"
  DrbdOptions/Resource/on-no-quorum: "io-error"
  DrbdOptions/auto-quorum: "suspend-io"
allowVolumeExpansion: true
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
```

```yaml
# PVC que consume esa clase
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pg-data
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: linstor-replica2
  resources:
    requests:
      storage: 50Gi
```

```yaml
# StatefulSet que monta el PVC replicado por DRBD; con quorum,
# si el nodo del pod muere, K8s reprograma el pod donde hay réplica UpToDate.
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: pg
spec:
  serviceName: pg
  replicas: 1
  selector: { matchLabels: { app: pg } }
  template:
    metadata: { labels: { app: pg } }
    spec:
      containers:
        - name: postgres
          image: postgres:16
          volumeMounts:
            - { name: data, mountPath: /var/lib/postgresql/data }
  volumeClaimTemplates:
    - metadata: { name: data }
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: linstor-replica2
        resources: { requests: { storage: 50Gi } }
```

Inspección del lado LINSTOR/DRBD 9:

```bash
$ linstor resource list
╭──────────────────────────────────────────────────────────────────╮
┊ ResourceName ┊ Node   ┊ Port ┊ Usage  ┊ Conns ┊    State ┊
╞══════════════════════════════════════════════════════════════════╡
┊ pvc-a1b2     ┊ worker1┊ 7000 ┊ InUse  ┊ Ok    ┊ UpToDate ┊
┊ pvc-a1b2     ┊ worker2┊ 7000 ┊ Unused ┊ Ok    ┊ UpToDate ┊
╰──────────────────────────────────────────────────────────────────╯
```

---

## 11. Verificación y diagnóstico de fallas

### 11.1 Checklist de salud (lo primero que se mira)

```bash
$ drbdadm status
# Sano = role:Primary/Secondary, disk:UpToDate, peer-disk:UpToDate, connection:Connected

$ drbdadm cstate r0      # Connected
$ drbdadm dstate r0      # UpToDate/UpToDate
$ drbdadm role r0        # Primary/Secondary
```

### 11.2 Online verify — detectar corrupción silenciosa

DRBD C garantiza que los writes llegan, pero no detecta *bit rot* posterior en el disco. La verificación online compara checksums bloque a bloque **sin downtime**:

```bash
# Lanzar desde el Primary; recorre el device comparando con el peer
$ drbdadm verify r0
$ drbdadm status r0
r0 role:Primary
  disk:UpToDate
  bravo role:Secondary
    replication:VerifyS peer-disk:UpToDate done:43.10
```

Si encuentra diferencias, las loguea vía el handler `out-of-sync` y marca esos bloques en el bitmap. Para reparar (re-sincronizar los bloques marcados) sin resync completo:

```bash
$ drbdadm disconnect r0
$ drbdadm connect r0        # el reconnect resincroniza solo lo out-of-sync
```

Programalo con `verify` semanal en cron; es una de las pocas defensas contra bit rot en un stack sin checksums de FS (ext4/XFS).

### 11.3 Split-brain — el fallo más importante del objetivo

**Síntoma en logs** (`dmesg` / `journalctl -k`):

```
kernel: drbd r0: Split-Brain detected but unresolved, dropping connection!
kernel: drbd r0: helper command: /sbin/drbdadm split-brain minor-0
```

`drbdadm status` muestra `connection:StandAlone` en uno o ambos nodos: DRBD **se desconectó adrede** para no pisar datos. Split-brain ocurre cuando ambos nodos fueron Primary de forma independiente (típicamente por una partición de red sin fencing) y ahora sus datos divergen.

**Resolución manual** (hay que decidir qué copia sobrevive — DRBD nunca lo decide por vos si `after-sb-*` no aplica):

```bash
# --- En el nodo VÍCTIMA (el que SACRIFICÁS; sus cambios se pierden) ---
$ umount /srv/data 2>/dev/null
$ drbdadm secondary r0
$ drbdadm disconnect r0
$ drbdadm connect --discard-my-data r0

# --- En el nodo SOBREVIVIENTE (fuente de verdad) ---
$ drbdadm connect r0            # (si sigue StandAlone)
```

Tras esto, el sobreviviente se vuelve `SyncSource` y la víctima resincroniza desde él. **Verificá** que converge:

```bash
$ watch -n2 'drbdadm status r0'
# esperás: connection:Connected, ambos peer-disk:UpToDate, out-of-sync:0
```

**Prevención** (más importante que la cura): `disk { fencing resource-and-stonith; }` + handlers `fence-peer` + STONITH funcional + quórum de Corosync. En DRBD 9, además, `--auto-quorum` con `on-no-quorum io-error` congela la I/O de la partición minoritaria, evitando el segundo write divergente en origen.

### 11.4 Recursos que no conectan

```bash
$ drbdadm status r0
r0 role:Secondary
  disk:UpToDate
  bravo connection:Connecting
```

`Connecting`/`WFConnection` persistente ⇒ el peer no responde. Checklist:

```bash
# 1) ¿El puerto está escuchando y la ruta abierta? (7788/7789… por recurso)
$ ss -tlnp | grep 778
$ nc -vz 10.10.0.2 7788

# 2) ¿Firewall? (firewalld/nftables suelen bloquear el puerto DRBD)
$ firewall-cmd --add-port=7788/tcp --permanent && firewall-cmd --reload

# 3) ¿Secreto compartido y algoritmo HMAC coinciden en ambos lados?
#    Un mismatch da 'cram-hmac' errors en dmesg y rechaza la conexión.
$ dmesg | grep -i drbd | tail

# 4) ¿Config idéntica? drbdadm adjust re-aplica sin bajar el recurso.
$ drbdadm adjust r0
```

### 11.5 Disco `Diskless` o `Inconsistent` inesperado

```bash
$ drbdadm status r0
r0 role:Secondary disk:Diskless
```

`Diskless` ⇒ DRBD desató el backing device, casi siempre por `on-io-error detach` tras errores reales de disco. Revisá `dmesg` por errores de I/O del block device subyacente; reemplazá el disco y re-atachá:

```bash
$ dmesg | grep -iE 'I/O error|drbd'
$ drbdadm attach r0     # tras reparar el backing device
```

Forzar resync completo de un lado que sabés inconsistente:

```bash
# En el nodo cuyos datos querés DESCARTAR (será SyncTarget):
$ drbdadm invalidate r0
# En el nodo bueno, para descartar los datos del REMOTO:
$ drbdadm invalidate-remote r0
```

### 11.6 Diagnóstico de performance (resync o writes lentos)

```bash
# Tasa de resync en vivo (DRBD 9)
$ drbdsetup status --statistics r0 | grep -E 'received|sent|out-of-sync'

# El controlador dinámico (c-plan-ahead / c-max-rate en disk{})
# gobierna la velocidad de resync; súbelo con cuidado para no saturar
# el enlace de producción:
$ drbdadm adjust r0     # tras editar c-max-rate en global_common.conf
```

Causas frecuentes de latencia alta en Protocol C: NIC de replicación compartida con tráfico de servicio (dedicá una VLAN/NIC), `disk-flushes` sobre un controlador sin BBU, o el disco del Secondary más lento que el del Primary (recordá: el nodo lento marca el ritmo).

---

## 12. Tabla resumen de decisiones de arquitectura

| Decisión | Elegí… | Cuándo |
|---|---|---|
| Protocolo | **C** | HA local con failover automático (default) |
| Protocolo | **A** | DR geográfico sobre WAN, RPO>0 aceptable |
| Modo | **single-primary** | 99% de los casos; failover con FS local |
| Modo | **dual-primary + GFS2/OCFS2** | Acceso concurrente coordinado, live migration |
| Metadata | **internal** | Simplicidad; espacio libre disponible al crear |
| Metadata | **external** | Discos rotacionales sensibles a seeks; device ya lleno |
| Orquestación | **Pacemaker + `ocf:linbit:drbd`** | Cluster de 2 nodos, failover de servicio |
| Orquestación | **LINSTOR + CSI** | Kubernetes, decenas/cientos de volúmenes DRBD 9 |
| Anti split-brain | **fencing resource-and-stonith + STONITH + quorum** | Siempre en producción |

---

## 13. Referencias

- LPI — Exam 306 Objectives (v3.0), objetivo 362.1: https://www.lpi.org/our-certifications/exam-306-objectives/
- The DRBD User's Guide 9.0 (LINBIT, documentación oficial): https://linbit.com/drbd-user-guide/drbd-guide-9_0-en/
- The DRBD User's Guide 8.4: https://linbit.com/drbd-user-guide/users-guide-drbd-8-4/
- `drbd.conf(5)` — formato del archivo de configuración: https://linbit.com/man/v9/drbd-conf-5/
- `drbdadm(8)` — herramienta de administración de alto nivel: https://linbit.com/man/v9/drbdadm-8/
- `drbdsetup(8)` — interfaz de bajo nivel con el kernel: https://linbit.com/man/v9/drbdsetup-8/
- `drbdmeta(8)` — manipulación de metadata: https://linbit.com/man/v9/drbdmeta-8/
- DRBD y Pacemaker (integración, resource agent `ocf:linbit:drbd`): https://linbit.com/drbd-user-guide/drbd-guide-9_0-en/#ch-pacemaker
- Resolución de split-brain (User's Guide): https://linbit.com/drbd-user-guide/drbd-guide-9_0-en/#s-resolve-split-brain
- LINSTOR — documentación y CSI para Kubernetes: https://linbit.com/drbd-user-guide/linstor-guide-1_0-en/
- Repositorio DRBD (código fuente kernel + utils): https://github.com/LINBIT/drbd y https://github.com/LINBIT/drbd-utils
- ClusterLabs — Pacemaker «Clusters from Scratch» (contexto STONITH/quorum): https://clusterlabs.org/pacemaker/doc/