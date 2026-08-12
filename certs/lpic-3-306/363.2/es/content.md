# 363.2 Ceph Storage Clusters

> LPIC-3 306 · Examen 306-300 (v3.0) · Tópico 363.2 · Peso 13.33
> Los candidatos deben ser capaces de administrar y mantener un clúster Ceph. Esto incluye la arquitectura y los componentes de Ceph, la gestión de los daemons OSD, MON, MGR y MDS, los placement groups y los pools, el almacén de objetos RADOS, los RADOS Block Devices (RBD), el Ceph Filesystem (CephFS), los mapas CRUSH, y el diagnóstico y la resolución de problemas de salud del clúster.

---

## 1. Motivación y el problema arquitectónico de producción

### 1.1 El modo de fallo que Ceph está diseñado para eliminar

Toda arquitectura de almacenamiento termina enfrentándose a las mismas tres presiones acopladas: **capacidad** (petabytes que superan a cualquier chasis individual), **durabilidad** (sobrevivir a fallos de disco, host y rack sin pérdida de datos) y **disponibilidad** (sobrevivir a esos fallos sin una interrupción del servicio ni una ventana de failover manual). Las respuestas clásicas rompen cada una alguna de las otras dos:

- Una **SAN de doble controladora** (o un par DRBD, ver 362.1) te da consistencia fuerte y baja latencia, pero el escalado es *vertical*: comprás una unidad de cabecera más grande. El par de controladoras es un techo rígido para las IOPS y un radio de impacto — un bug de firmware tumba ambas rutas.
- **NFS / un único servidor de archivos** centraliza los metadatos y el namespace. Es simple, pero el servidor de metadatos es un único punto de fallo y un único punto de contención, y la reconstrucción tras la pérdida de un disco es una operación manual, atada a RAID, cuya ventana crece linealmente con el tamaño del disco.
- El **almacenamiento fragmentado (sharded) a nivel de aplicación** escala horizontalmente pero empuja la colocación (placement), el rebalanceo y la durabilidad hacia arriba, a cada equipo de aplicación — los problemas más difíciles de los sistemas distribuidos, vueltos a resolver mal N veces.

El problema arquitectónico que Ceph resuelve es: **proveer almacenamiento de objetos, de bloques y de archivos desde un único pool escalable horizontalmente, sin cuello de botella central de metadatos, sin colocación manual de datos, y con recuperación auto-reparable (self-healing) — sobre hardware commodity.** Las tres decisiones de diseño deliberadas que hacen esto posible:

1. **Ninguna tabla de búsqueda (lookup table) para la colocación de objetos.** Un servidor de metadatos que mapea `object → location` es un cuello de botella y un SPOF. Ceph lo reemplaza con **CRUSH** (Controlled Replication Under Scalable Hashing): una función de hash determinística y pseudo-aleatoria que *calcula* la colocación a partir del nombre del objeto y de la topología del clúster. Cualquier cliente que tenga el mapa del clúster puede calcular de forma independiente dónde vive cualquier objeto — sin un round-trip a un servicio de directorio.
2. **Recuperación autonómica.** Los OSDs (los daemons por disco) hacen peering entre sí, detectan fallos y re-replican los datos perdidos automáticamente según las reglas CRUSH, sin intervención del operador y sin un lock global.
3. **Un solo almacén de objetos, tres personalidades.** RADOS (el Reliable Autonomic Distributed Object Store) es el sustrato. RBD (bloque), CephFS (archivos POSIX) y RGW (objetos S3/Swift) son capas de traducción finas por encima del *mismo* pool de OSDs. Aprovisionás la capacidad una sola vez.

### 1.2 Los componentes sobre los que debés poder razonar

```
                          ┌──────────────────────────────────────────────┐
   Clients (librados,     │                   RADOS                       │
   RBD, CephFS, RGW/S3) ──┤   Reliable Autonomic Distributed Object Store │
                          └───────────────────┬──────────────────────────┘
        ┌───────────────┬────────────────┬────┴─────────┬────────────────┐
        │               │                │              │                │
   ┌────▼────┐     ┌────▼────┐      ┌────▼────┐    ┌────▼────┐      ┌────▼────┐
   │  MON    │     │  MGR    │      │  OSD    │    │  MDS    │      │  RGW    │
   │ cluster │     │ metrics │      │ per-disk│    │ CephFS  │      │ S3/Swift│
   │  maps + │     │dashboard│      │ storage │    │metadata │      │ gateway │
   │  Paxos  │     │ modules │      │ +recover│    │ (opt.)  │      │ (opt.)  │
   └─────────┘     └─────────┘      └─────────┘    └─────────┘      └─────────┘
   quorum: 3/5     active/stby      1 per device   active/stby      stateless
```

| Daemon | Binario | Rol | Cardinalidad (producción) | Estado que posee |
|---|---|---|---|---|
| Monitor | `ceph-mon` | Mantiene los **mapas del clúster** autoritativos (MonMap, OSDMap, PGMap, CRUSHMap, MDSMap), forma el **quórum** Paxos, autentica clientes (CephX) | **Impar**, 3 (pequeño) o 5 (grande). Nunca 2 ni 4. | La única fuente de verdad; pequeño, crítico para el consenso |
| Manager | `ceph-mgr` | Métricas, `ceph orch`, dashboard, exportador Prometheus, `pg_autoscaler`, `balancer`, `devicehealth` | 2 (activo + standby), co-ubicado con los MONs | Estado de runtime/derivado; sin datos |
| OSD | `ceph-osd` | Almacena objetos en **un** dispositivo de bloques vía BlueStore; maneja replicación, recuperación, backfill, scrubbing | **1 por dispositivo de datos** (docenas–miles) | Los datos reales + membresía de PG |
| MDS | `ceph-mds` | Metadatos POSIX (inodes, dentries, capabilities) solo para **CephFS** | ≥1 activo + ≥1 standby *por filesystem* | Metadatos, cacheados en RAM, con journal a un pool de RADOS |
| RGW | `radosgw` | Gateway REST S3 / Swift | ≥2 detrás de un balanceador de carga | Sin estado (stateless); datos + índice en pools |

**El modelo mental que el examen premia:** los MONs son un plano de control pequeño y fuertemente consistente (Paxos, quórum, mapas del clúster). Los OSDs son un plano de datos grande y eventualmente peereado. CRUSH es la función que permite que el plano de datos opere sin preguntarle al plano de control dónde va cada cosa. Todo lo demás (RBD, CephFS, RGW) es un cliente de RADOS.

---

## 2. Comparaciones técnicas y trade-offs

### 2.1 Protección de datos: Replicación vs Erasure Coding

La decisión a nivel de pool de mayor consecuencia. Intercambia eficiencia de capacidad bruta contra CPU, latencia y costo de recuperación.

| Dimensión | Replicación (`size=3`) | Erasure Coding (`k=4, m=2`) |
|---|---|---|
| Capacidad utilizable | 33% (3× de overhead) | 67% (1.5× de overhead) |
| Tolerancia a fallos | `size − 1` = 2 OSDs/hosts | `m` = 2 chunks |
| Ruta de escritura | Escribe el objeto completo en 3 OSDs | Codifica en `k+m` chunks, escribe en 6 OSDs |
| Latencia de lectura | Baja — lee desde el primario | Más alta — puede necesitar reconstruir desde `k` chunks |
| Objetos pequeños / I/O aleatoria | Excelente | Pobre (amplificación read-modify-write) |
| Costo de CPU | Despreciable | Significativo (codificación/decodificación Reed-Solomon) |
| Tráfico de recuperación ante fallo | Copia objetos enteros | Recalcula chunks — lee `k` para reconstruir 1 |
| Sobrescrituras parciales | Nativas | **No soportadas** en pools EC sin `allow_ec_overwrites` (e incluso así, costosas); RBD/CephFS sobre EC lo necesita |
| Uso típico | RBD, metadatos de CephFS, datos calientes, pools críticos de MON | Objetos masivos de RGW, datos fríos, backups, media |

**Regla general para producción:** replicación (`size=3`, `min_size=2`) para cualquier cosa sensible a la latencia o sobrescrita aleatoriamente (volúmenes RBD, pool de metadatos de CephFS); erasure coding para cargas de trabajo de objetos grandes y mayormente de append (almacenamiento de objetos, archivos). `min_size=2` en un pool 3× es deliberado: significa que la I/O se bloquea (en lugar de arriesgarse a aceptar una escritura sobre una única copia) cuando solo sobrevive una réplica — la disponibilidad cede ante la durabilidad.

### 2.2 Backend de OSD: BlueStore vs FileStore

| Dimensión | BlueStore (por defecto desde Luminous) | FileStore (eliminado en Reef) |
|---|---|---|
| Modelo de almacenamiento | Dispositivo de bloques crudo, sin filesystem | Objetos como archivos sobre XFS |
| Metadatos | RocksDB embebido | LevelDB + atributos extendidos de XFS |
| Amplificación de escritura | ~1× (sin doble escritura para I/O grande) | ~2× (journal + journal del filesystem) |
| Journal / WAL | WAL interno + dispositivo DB/WAL separado opcional | Partición de journal separada obligatoria |
| Checksums | CRC32C de datos completos en cada lectura | Ninguno (depende de XFS) |
| Compresión | Nativa (inline, por pool) | Ninguna |
| Estado | **El único backend soportado** | Deprecado; **no desplegar** |

**Conclusión para el examen y para producción:** BlueStore es obligatorio en cualquier clúster moderno. Su única perilla de tuning que debés conocer es la separación de dispositivos — poner los metadatos de RocksDB (`block.db`) y el WAL en NVMe rápido mientras los datos residen en HDD mejora drásticamente el rendimiento de escrituras pequeñas y de metadatos. Dimensionamiento: presupuestá el `block.db` en aproximadamente **1–4% del dispositivo de datos** (la guía histórica de Ceph era ~4% para RBD, menos para RGW); una DB subdimensionada *desborda (spills over)* hacia el dispositivo de datos lento de forma silenciosa y mata el rendimiento.

### 2.3 Herramientas de despliegue: cephadm vs ceph-deploy vs Rook vs manual

| Herramienta | Modelo | Estado | Cuándo |
|---|---|---|---|
| **cephadm** | Contenedor (Podman/Docker) + systemd, dirigido por `ceph orch` sobre SSH | **Actual, recomendado** (desde Octopus) | Producción en bare-metal / VM |
| `ceph-deploy` | Push por SSH con Python, paquetes en el host | **Deprecado / eliminado** | Solo legacy — histórico del examen |
| **Rook** | Operador de Kubernetes | Actual | Ceph en/para Kubernetes |
| Manual / `ceph-volume` | Unidades de systemd colocadas a mano | Soportado pero laborioso | Air-gapped, a medida |

`ceph-deploy` sigue apareciendo en la lista de *Terms and Utilities* de LPI porque el objetivo es anterior a su eliminación — sabé que *existió* y empujaba paquetes sobre SSH, pero que **cephadm es la ruta de despliegue** y `ceph-volume` es la primitiva de aprovisionamiento de OSD que subyace a ambos.

### 2.4 Método de acceso: RBD vs CephFS vs RGW

| | RBD | CephFS | RGW |
|---|---|---|---|
| Abstracción | Dispositivo de bloques (disco virtual) | Filesystem POSIX | Almacén de objetos (REST S3/Swift) |
| Consumidor | VMs (KVM/QEMU), `krbd`, PVs de k8s | Múltiples hosts, montaje compartido | Aplicaciones sobre HTTP |
| Daemon extra | ninguno | **MDS** requerido | **RGW** requerido |
| Concurrencia | Un único escritor (o un FS clusterizado encima) | Muchos lectores/escritores, locks POSIX | Muchos, eventual dentro de un bucket |
| Snapshots/clones | Sí (clones copy-on-write) | Sí (snapshots de subárbol) | Versionado |
| Layout típico de pools | 1 pool replicado | pools de metadata (repl) + data (repl o EC) | pools de index/data (data a menudo EC) |

---

## 3. Infraestructura completa y manifiestos

Lo siguiente es un bootstrap completo, sin abreviar, de un clúster con forma de producción usando `cephadm`: 3 nodos MON/MGR y 4 nodos OSD, cada nodo OSD con HDDs para datos y NVMe para `block.db`.

### 3.1 Inventario de hosts y prerrequisitos

```
# Topology
ceph-mon01  10.10.0.11   labels: _admin,mon,mgr
ceph-mon02  10.10.0.12   labels: mon,mgr
ceph-mon03  10.10.0.13   labels: mon,mgr
ceph-osd01  10.10.0.21   labels: osd    (sdb,sdc,sdd = HDD; nvme0n1 = DB)
ceph-osd02  10.10.0.22   labels: osd
ceph-osd03  10.10.0.23   labels: osd
ceph-osd04  10.10.0.24   labels: osd

# Networks (recommended split):
#   public network  10.10.0.0/24   client <-> daemon traffic
#   cluster network  10.20.0.0/24   OSD <-> OSD replication/recovery (isolates rebuild load)
```

Prerrequisitos en cada nodo: Podman (o Docker), `chrony` (la sincronización de tiempo **no es opcional** — el quórum de MON se rompe con la deriva del reloj), Python 3, y SSH sin contraseña para la clave de cephadm.

### 3.2 Bootstrap

```bash
# On ceph-mon01 — install the cephadm bootstrap tool for the Reef release
$ curl --silent --remote-name --location https://download.ceph.com/rpm-18.2.4/el9/noarch/cephadm
$ chmod +x cephadm
$ ./cephadm add-repo --release reef
$ ./cephadm install ceph-common

# Bootstrap the first MON + MGR, pinning the public network
$ cephadm bootstrap \
    --mon-ip 10.10.0.11 \
    --cluster-network 10.20.0.0/24 \
    --ssh-user root \
    --initial-dashboard-user admin \
    --initial-dashboard-password 'REDACTED' \
    --allow-fqdn-hostname
```

Cola esperada de la salida del bootstrap:

```
Ceph Dashboard is now available at:

             URL: https://ceph-mon01:8443/
            User: admin
        Password: REDACTED

Enabling client.admin keyring and conf on hosts with "_admin" label
Saving cluster configuration to /var/lib/ceph/a7f64266-0894-4f1e-a635-d0aeaca0e993/config directory
Enabling autotune for osd_memory_target
You can access the Ceph CLI as following in case of multi-cluster or non-default config:

        sudo /usr/sbin/cephadm shell --fsid a7f64266-0894-4f1e-a635-d0aeaca0e993 -c /etc/ceph/ceph.conf -k /etc/ceph/ceph.client.admin.keyring

Bootstrap complete.
```

### 3.3 Enrolar hosts y distribuir la clave SSH

```bash
# Copy the cluster's SSH public key to every future member
$ ceph cephadm get-pub-key > ~/ceph.pub
$ for h in mon02 mon03 osd01 osd02 osd03 osd04; do
    ssh-copy-id -f -i ~/ceph.pub root@ceph-$h
  done

# Add hosts with labels that drive placement
$ ceph orch host add ceph-mon02 10.10.0.12 --labels _no_schedule=false mon mgr
$ ceph orch host add ceph-mon03 10.10.0.13 mon mgr
$ ceph orch host add ceph-osd01 10.10.0.21 osd
$ ceph orch host add ceph-osd02 10.10.0.22 osd
$ ceph orch host add ceph-osd03 10.10.0.23 osd
$ ceph orch host add ceph-osd04 10.10.0.24 osd

$ ceph orch host ls
HOST        ADDR         LABELS          STATUS
ceph-mon01  10.10.0.11   _admin,mon,mgr
ceph-mon02  10.10.0.12   mon,mgr
ceph-mon03  10.10.0.13   mon,mgr
ceph-osd01  10.10.0.21   osd
ceph-osd02  10.10.0.22   osd
ceph-osd03  10.10.0.23   osd
ceph-osd04  10.10.0.24   osd
7 hosts in cluster
```

### 3.4 Especificación declarativa de servicios (el clúster entero en un archivo)

cephadm es **declarativo**: describís el estado deseado en una spec y `ceph orch apply` lo reconcilia — el equivalente de un manifiesto de Kubernetes para los daemons de Ceph.

```yaml
# cluster-services.yaml — apply with: ceph orch apply -i cluster-services.yaml
---
service_type: mon
service_name: mon
placement:
  label: mon
  count: 3
---
service_type: mgr
service_name: mgr
placement:
  label: mgr
  count: 2
---
# OSD "drive group": every OSD host, HDDs as data, NVMe as shared block.db,
# 4 DB slots per NVMe (one per HDD) so RocksDB lands on fast media.
service_type: osd
service_id: hdd_data_nvme_db
placement:
  label: osd
spec:
  data_devices:
    rotational: 1          # spinning disks -> data
  db_devices:
    rotational: 0          # NVMe/SSD      -> RocksDB (block.db)
  db_slots: 4
  filter_logic: AND
  objectstore: bluestore
---
service_type: mds
service_id: cephfs          # MDS for the "cephfs" filesystem
placement:
  label: mon                # co-locate MDS with control-plane nodes
  count: 2
---
service_type: rgw
service_id: default
placement:
  label: mon
  count: 2
spec:
  rgw_frontend_port: 8080
```

```bash
$ ceph orch apply -i cluster-services.yaml
Scheduled mon update...
Scheduled mgr update...
Scheduled osd.hdd_data_nvme_db update...
Scheduled mds.cephfs update...
Scheduled rgw.default update...

# Watch OSDs being created device-by-device
$ ceph orch device ls
HOST        PATH          TYPE  DEVICE ID          SIZE  AVAILABLE  REJECT REASONS
ceph-osd01  /dev/sdb      hdd   WDC_WD40EFRX...     4TB  Yes
ceph-osd01  /dev/sdc      hdd   WDC_WD40EFRX...     4TB  Yes
ceph-osd01  /dev/sdd      hdd   WDC_WD40EFRX...     4TB  Yes
ceph-osd01  /dev/nvme0n1  ssd   Samsung_PM983...  960GB  Yes
...
```

### 3.5 Pools, RBD, CephFS, erasure coding

```bash
# --- Replicated RBD pool (block storage for VMs) ---
$ ceph osd pool create rbd 128 128 replicated
$ ceph osd pool set rbd size 3
$ ceph osd pool set rbd min_size 2
$ ceph osd pool application enable rbd rbd
$ rbd pool init rbd

# Create a 100 GiB image and map it
$ rbd create rbd/vm-disk-01 --size 102400
$ rbd info rbd/vm-disk-01
rbd image 'vm-disk-01':
        size 100 GiB in 25600 objects
        order 22 (4 MiB objects)
        snapshot_count: 0
        id: 3a9f2c1b4e5d
        block_name_prefix: rbd_data.3a9f2c1b4e5d
        format: 2
        features: layering, exclusive-lock, object-map, fast-diff, deep-flatten
        op_features:
        flags:

# --- CephFS: metadata pool (replicated) + data pool (replicated) ---
$ ceph osd pool create cephfs_metadata 32 32
$ ceph osd pool create cephfs_data 128 128
$ ceph fs new cephfs cephfs_metadata cephfs_data
new fs with metadata pool 5 and data pool 6

$ ceph fs status cephfs
cephfs - 0 clients
======
RANK  STATE       MDS         ACTIVITY     DNS    INOS   DIRS   CAPS
 0    active  cephfs.ceph-mon01  Reqs:    0 /s    10     13     12      0
      POOL         TYPE     USED  AVAIL
cephfs_metadata  metadata   96k   13.6T
  cephfs_data      data       0   13.6T
STANDBY MDS
cephfs.ceph-mon02

# --- Erasure-coded pool for RGW bulk data (k=4, m=2, host-level failure domain) ---
$ ceph osd erasure-code-profile set ec42 \
    k=4 m=2 crush-failure-domain=host plugin=jerasure technique=reed_sol_van
$ ceph osd erasure-code-profile get ec42
crush-device-class=
crush-failure-domain=host
crush-root=default
jerasure-per-chunk-alignment=false
k=4
m=2
plugin=jerasure
technique=reed_sol_van
w=8
$ ceph osd pool create rgw_data 128 128 erasure ec42
$ ceph osd pool set rgw_data allow_ec_overwrites true   # only if a client needs partial writes
```

### 3.6 Trabajando directamente con el mapa CRUSH

El mapa CRUSH codifica la topología física (device → host → rack → root) y las reglas de colocación. Lo extraés, lo descompilás a texto, lo editás, lo recompilás y lo inyectás.

```bash
# Extract, decompile, edit, recompile, inject
$ ceph osd getcrushmap -o crush.bin
$ crushtool -d crush.bin -o crush.txt
```

Un `crush.txt` descompilado representativo (editado para agregar un nivel `rack` y una regla SSD):

```
# begin crush map
tunable choose_local_tries 0
tunable choose_local_fallback_tries 0
tunable choose_total_tries 50
tunable chooseleaf_descend_once 1
tunable chooseleaf_vary_r 1
tunable chooseleaf_stable 1
tunable straw_calc_version 1
tunable allowed_bucket_algs 54

# devices
device 0 osd.0 class hdd
device 1 osd.1 class hdd
device 2 osd.2 class hdd
device 3 osd.3 class ssd

# types
type 0 osd
type 1 host
type 2 rack
type 3 root

# buckets
host ceph-osd01 {
        id -3          # do not change unnecessarily
        alg straw2
        hash 0         # rjenkins1
        item osd.0 weight 3.638
        item osd.1 weight 3.638
        item osd.2 weight 3.638
}
rack rack-a {
        id -10
        alg straw2
        hash 0
        item ceph-osd01 weight 10.914
        item ceph-osd02 weight 10.914
}
root default {
        id -1
        alg straw2
        hash 0
        item rack-a weight 21.828
        item rack-b weight 21.828
}

# rules
rule replicated_rule {
        id 0
        type replicated
        step take default
        step chooseleaf firstn 0 type host
        step emit
}
rule ssd_rule {
        id 1
        type replicated
        step take default class ssd
        step chooseleaf firstn 0 type host
        step emit
}
# end crush map
```

```bash
$ crushtool -c crush.txt -o crush-new.bin
# Test the rule against a virtual cluster before injecting (dry-run mapping)
$ crushtool -i crush-new.bin --test --rule 0 --num-rep 3 --show-mappings | head
CRUSH rule 0 x 0 [1,4,7]
CRUSH rule 0 x 1 [8,2,5]
CRUSH rule 0 x 2 [0,6,3]
...
$ ceph osd setcrushmap -i crush-new.bin
```

La alternativa más segura y moderna a la edición a mano es la CLI, que muta el mapa CRUSH de forma transaccional:

```bash
$ ceph osd crush add-bucket rack-a rack
$ ceph osd crush move rack-a root=default
$ ceph osd crush move ceph-osd01 rack=rack-a
$ ceph osd crush rule create-replicated rack_rule default rack hdd
```

---

## 4. CLI operativa y salida real de terminal

### 4.1 El primer comando que corrés, siempre: `ceph -s`

```
$ ceph -s
  cluster:
    id:     a7f64266-0894-4f1e-a635-d0aeaca0e993
    health: HEALTH_OK

  services:
    mon: 3 daemons, quorum ceph-mon01,ceph-mon02,ceph-mon03 (age 3d)
    mgr: ceph-mon01(active, since 3d), standbys: ceph-mon02
    mds: 1/1 daemons up, 1 hot standby
    osd: 12 osds: 12 up (since 3d), 12 in (since 3d)
    rgw: 2 daemons active (2 hosts, 1 zones)

  data:
    volumes: 1/1 healthy
    pools:   8 pools, 289 pgs
    objects: 1.24M objects, 3.8 TiB
    usage:   11 TiB used, 32 TiB / 43 TiB avail
    pgs:     289 active+clean
```

Leelo de arriba hacia abajo: **quórum** (¿los MONs están de acuerdo?), **osd up/in** (`up` = alcanzable, `in` = participando en la colocación de datos — un OSD caído sigue estando `in` hasta que se lo marca como `out`), y la **línea de pgs** (cada PG debería estar `active+clean`; cualquier otra cosa es la falla).

### 4.2 Topología y utilización de OSD

```
$ ceph osd tree
ID   CLASS  WEIGHT    TYPE NAME            STATUS  REWEIGHT  PRI-AFF
 -1         43.656    root default
-10         21.828        rack rack-a
 -3         10.914            host ceph-osd01
  0    hdd   3.638                osd.0        up   1.00000  1.00000
  1    hdd   3.638                osd.1        up   1.00000  1.00000
  2    hdd   3.638                osd.2        up   1.00000  1.00000
 -5         10.914            host ceph-osd02
  3    hdd   3.638                osd.3        up   1.00000  1.00000
  ...
-11         21.828        rack rack-b
  ...

$ ceph osd df
ID  CLASS  WEIGHT   REWEIGHT  SIZE     RAW USE  DATA     OMAP    META    AVAIL    %USE   VAR   PGS  STATUS
 0    hdd  3.63869   1.00000  3.6 TiB  957 GiB  951 GiB   12 MiB  5.4 GiB  2.7 TiB  25.68  1.01   74      up
 1    hdd  3.63869   1.00000  3.6 TiB  931 GiB  925 GiB   11 MiB  5.2 GiB  2.7 TiB  24.98  0.98   71      up
 ...
                       TOTAL   43 TiB   11 TiB   11 TiB  141 MiB   65 GiB   32 TiB  25.44
MIN/MAX VAR: 0.94/1.07  STDDEV: 0.71
```

El sesgo del `%USE` entre OSDs es lo que el módulo mgr `balancer` y el `reweight` existen para corregir — CRUSH es pseudo-aleatorio, así que la utilización deriva; un `STDDEV` que trepa por encima de unos pocos por ciento es tu señal.

### 4.3 Capacidad y pools

```
$ ceph df
--- RAW STORAGE ---
CLASS     SIZE    AVAIL     USED  RAW USED  %RAW USED
hdd     43 TiB   32 TiB   11 TiB    11 TiB      25.44
TOTAL   43 TiB   32 TiB   11 TiB    11 TiB      25.44

--- POOLS ---
POOL              ID  PGS   STORED   OBJECTS     USED  %USED  MAX AVAIL
.mgr               1    1   577 KiB        2  1.7 MiB      0     10 TiB
rbd                2  128   2.9 TiB   765.4k   8.7 TiB  22.29     10 TiB
cephfs_metadata    5   32   112 MiB    2.31k   337 MiB      0     10 TiB
cephfs_data        6  128   612 GiB   156.8k   1.8 TiB   5.68     10 TiB
rgw_data           7  128   380 GiB    98.2k   570 GiB   1.83     20 TiB
```

Notá que `USED` en el pool replicado `rbd` es 3× `STORED` (overhead de replicación); en el pool EC `rgw_data` es 1.5× (`k=4,m=2`). `MAX AVAIL` es lo que un pool todavía puede absorber dada su regla de replicación y el OSD más lleno — el número que realmente importa para la planificación de capacidad.

### 4.4 Placement groups y el autoscaler

```
$ ceph pg stat
289 pgs: 289 active+clean; 3.8 TiB data, 11 TiB used, 32 TiB / 43 TiB avail

$ ceph osd pool autoscale-status
POOL             SIZE  TARGET SIZE  RATE  RAW CAPACITY  RATIO  TARGET RATIO  BIAS  PG_NUM  NEW PG_NUM  AUTOSCALE  BULK
.mgr             577k                3.0        43776G  0.0000                1.0       1              on         False
rbd             2979G                3.0        43776G  0.2042                1.0     128              on         False
cephfs_data      612G                3.0        43776G  0.0419                1.0     128              on         True
rgw_data         380G                1.5        43776G  0.0130                1.0     128              on         True

# Turn the autoscaler on/off per pool, or set an expected size to pre-size PGs
$ ceph osd pool set rbd pg_autoscale_mode on
$ ceph osd pool set rgw_data target_size_ratio 0.4
```

### 4.5 RADOS a nivel de objeto (por debajo de RBD/CephFS/RGW)

```bash
# Write, list, read a raw object directly into a pool — proves RADOS independent of any gateway
$ echo "durability test" | rados -p rbd put testobj -
$ rados -p rbd ls | grep testobj
testobj
$ rados -p rbd get testobj -
durability test

# Which PG and which OSDs hold it? (CRUSH computed, no lookup table)
$ ceph osd map rbd testobj
osdmap e412 pool 'rbd' (2) object 'testobj' -> pg 2.4d7ac59f (2.1f) ->
  up ([5,1,9], p5) acting ([5,1,9], p5)

$ rados -p rbd df
POOL_NAME   USED  OBJECTS  CLONES  COPIES  MISSING_ON_PRIMARY  UNFOUND  DEGRADED  RD_OPS   RD      WR_OPS   WR
rbd      8.7 TiB   765400       0  2296200                  0        0         0  4.2M   112 GiB  9.8M    3.1 TiB
```

`up` es el conjunto deseado por CRUSH; `acting` es quién está sirviendo realmente en este momento — cuando difieren, el PG está `remapped` y los datos están migrando.

### 4.6 Inventario de orquestación

```
$ ceph orch ls
NAME                     PORTS   RUNNING  REFRESHED  AGE  PLACEMENT
mgr                                  2/2  5m ago     3d   count:2
mon                                  3/3  5m ago     3d   label:mon;count:3
osd.hdd_data_nvme_db                12/12 5m ago     3d   label:osd
mds.cephfs                           2/2  5m ago     3d   label:mon;count:2
rgw.default              ?:8080      2/2  5m ago     3d   label:mon;count:2

$ ceph orch ps ceph-osd01
NAME        HOST        PORTS  STATUS         REFRESHED  AGE  MEM USE  MEM LIM  VERSION  IMAGE ID
osd.0       ceph-osd01         running (3d)   5m ago     3d   1834M    4096M    18.2.4   2bc0b0f4375d
osd.1       ceph-osd01         running (3d)   5m ago     3d   1791M    4096M    18.2.4   2bc0b0f4375d
osd.2       ceph-osd01         running (3d)   5m ago     3d   1802M    4096M    18.2.4   2bc0b0f4375d
```

---

## 5. Guía de verificación y diagnóstico de fallos

El bucle de diagnóstico es siempre el mismo: **`ceph health detail` → identificar el subsistema → profundizar en el estado de ese subsistema → actuar → re-verificar con `ceph -s`.**

### 5.1 La escalera de salud

```
$ ceph health detail
HEALTH_WARN 1 osds down; Degraded data redundancy: 71/2296200 objects degraded (0.003%), 12 pgs degraded
[WRN] OSD_DOWN: 1 osds down
    osd.7 (root=default,rack=rack-b,host=ceph-osd03) is down
[WRN] PG_DEGRADED: Degraded data redundancy: 71/2296200 objects degraded (0.003%), 12 pgs degraded
    pg 2.a is active+undersized+degraded, acting [3,11]
    pg 6.1c is active+undersized+degraded, acting [5,2]
    ...
```

### 5.2 Diagnosticar un OSD caído

```bash
# Is it the disk, the daemon, or the host?
$ ceph osd tree down
ID  CLASS  WEIGHT   TYPE NAME          STATUS  REWEIGHT  PRI-AFF
 7    hdd  3.638         osd.7           down   1.00000  1.00000

# Inspect the daemon on its host
$ ceph orch ps --daemon-type osd --daemon-id 7
NAME   HOST        STATUS              MEM USE  VERSION  IMAGE ID
osd.7  ceph-osd03  error (5m ago)      -        18.2.4   2bc0b0f4375d

$ cephadm logs --name osd.7 --fsid a7f64266-... | tail -20
... bluestore(/var/lib/ceph/osd/ceph-7) _open_db erroring opening db:
... _txc_add_transaction error (2) No such file or directory
... ** ERROR: osd init failed: (5) Input/output error   # <-- disk-level I/O error

# Confirm at the kernel level
$ dmesg | grep -i 'sd\|I/O error' | tail
[924831.10] blk_update_request: I/O error, dev sde, sector 1902847488
```

Decisión: ¿transitorio? `ceph orch daemon restart osd.7`. ¿Disco muerto? Marcalo como out, dejá que CRUSH se auto-repare, después reemplazá:

```bash
$ ceph osd out osd.7                       # trigger rebalancing away from it
$ ceph osd safe-to-destroy osd.7           # wait until this returns safe
OSD(s) 7 are safe to destroy without reducing data durability.
$ ceph orch osd rm 7 --replace --zap       # remove, keep the ID for the replacement disk
$ ceph orch osd rm status
OSD  HOST        STATE      PGS  REPLACE  FORCE  ZAP
7    ceph-osd03  draining   34   True     False  True
# insert new disk; the drive-group spec auto-provisions a new osd.7 on it
```

### 5.3 Leer los estados de PG (el vocabulario que el examen evalúa)

| Estado de PG | Significado | Causa típica | Acción |
|---|---|---|---|
| `active+clean` | Sano, todas las réplicas presentes | — | ninguna |
| `degraded` | Existen menos de `size` copias | OSD caído/out | esperar la recuperación |
| `undersized` | Menos OSDs que el `size` del pool disponibles | No hay suficientes hosts arriba | agregar capacidad / arreglar hosts |
| `remapped` | `acting` ≠ `up` — datos migrando | rebalanceo, reweight, cambio de CRUSH | esperar al backfill |
| `backfilling`/`recovering` | Datos copiándose | tras un fallo/rebalanceo | throttle si impacta a los clientes |
| `peering` | Los OSDs acordando el contenido del PG | transitorio | esperar; si se atasca, investigar |
| `stale` | Sin reporte del primario acting | el OSD primario caído o flapeando | reiniciar/reemplazar el OSD |
| `incomplete` | No hay suficientes copias sobrevivientes para ser seguro | se perdieron demasiados OSDs; `min_size` no alcanzado | recuperar OSDs o aceptar la pérdida |
| `inconsistent` | El scrub encontró un desajuste de réplica | bit-rot, disco malo | `ceph pg repair` |
| `down` | Un OSD que tiene datos necesarios está caído y sus datos son requeridos para el peering | se perdió la única copia actualizada | volver a poner ese OSD arriba |

```bash
$ ceph pg dump_stuck
PG_STAT  STATE                          UP       ACTING
2.a      active+undersized+degraded  [3,11]     [3,11]

$ ceph pg 2.a query | jq '.recovery_state[0].name'
"Started/Primary/Active"
```

### 5.4 PGs inconsistentes (corrupción silenciosa atrapada por el scrub)

Los checksums de BlueStore atrapan el bit-rot en la lectura; el **scrubbing** compara las réplicas de forma proactiva. Un PG `inconsistent` es un evento de integridad de datos:

```bash
$ ceph health detail
HEALTH_ERR 1 scrub errors; Possible data damage: 1 pg inconsistent
[ERR] PG_DAMAGED: Possible data damage: 1 pg inconsistent
    pg 6.4b is active+clean+inconsistent, acting [2,7,11]

# Find which object and which OSD disagrees
$ rados list-inconsistent-obj 6.4b --format=json-pretty | jq '.inconsistents[].shards'
[
  {"osd":2,"errors":[],"size":4194304,"data_digest":"0x2d4a1e3f"},
  {"osd":7,"errors":["data_digest_mismatch_info"],"size":4194304,"data_digest":"0x00000000"},
  {"osd":11,"errors":[],"size":4194304,"data_digest":"0x2d4a1e3f"}
]

# osd.7 is the outlier -> repair copies a good replica over the bad shard
$ ceph pg repair 6.4b
instructing pg 6.4b on osd.2 to repair
```

### 5.5 Quórum de MON y deriva de reloj (el fallo del plano de control)

Perdé el quórum y todo el clúster se detiene — los clientes ya no pueden obtener un mapa autoritativo. La causa no-hardware más común es la **deriva de reloj (clock skew)** entre los MONs.

```bash
$ ceph health detail
HEALTH_WARN clock skew detected on mon.ceph-mon03
[WRN] MON_CLOCK_SKEW: clock skew detected on mon.ceph-mon03
    mon.ceph-mon03 clock skew 0.612s > max 0.05s

$ ceph quorum_status --format json-pretty | jq '.quorum_names'
["ceph-mon01","ceph-mon02","ceph-mon03"]

# Fix: verify chrony is synced everywhere
$ chronyc tracking | grep -E 'Reference|System time'
Reference ID    : C0A80001 (ntp.internal)
System time     : 0.000031 seconds fast of NTP time
```

El crecimiento del store de MON (`mon.X is using a lot of disk space`) es la otra alerta clásica de MON — normalmente porque el clúster ha estado en un estado distinto de `HEALTH_OK` durante mucho tiempo, así que los MONs no pueden podar (trim) los mapas viejos. El arreglo es *devolver el clúster a la salud*, no borrar el store.

### 5.6 La cascada "full" — el estado de producción más peligroso

Ceph rechaza escrituras antes de que un OSD se llene físicamente, porque un OSD 100%-lleno ni siquiera puede registrar su propia contabilidad de recuperación. Tres ratios controlan esto:

| Ratio | Por defecto | Efecto al cruzarlo |
|---|---|---|
| `mon_osd_nearfull_ratio` | 0.85 | `HEALTH_WARN`, planificar capacidad |
| `mon_osd_backfillfull_ratio` | 0.90 | El backfill/recuperación hacia ese OSD **se detiene** |
| `mon_osd_full_ratio` | 0.95 | **Todas las escrituras a cualquier pool que use ese OSD se bloquean** |

```bash
$ ceph health detail
HEALTH_ERR 1 full osd(s); 2 nearfull osd(s)
[ERR] OSD_FULL: 1 full osd(s)
    osd.4 is full at 95%
[WRN] OSD_NEARFULL: 2 nearfull osd(s)
    osd.1 is near full at 87%
    osd.9 is near full at 86%

# EMERGENCY relief only — nudge the ratio to unblock writes long enough to add capacity
$ ceph osd set-full-ratio 0.96
# Real fix: add OSDs, or reweight to move data off the hot OSD
$ ceph osd reweight-by-utilization 110       # reweight OSDs above 110% of average down
```

Un clúster lleno es genuinamente difícil de recuperar porque *borrar* datos también necesita escrituras. La prevención — el autoscaler, el balancer y las alertas en `nearfull` — es la estrategia completa.

### 5.7 Slow ops / regresión de rendimiento

```bash
$ ceph health detail
HEALTH_WARN 2 slow ops, oldest one blocked for 34 sec, osd.9 has slow ops
[WRN] SLOW_OPS: 2 slow ops, oldest one blocked for 34 sec, daemons [osd.9] have slow ops.

# Dump the in-flight ops on the offending OSD
$ ceph daemon osd.9 dump_historic_ops | jq '.ops[0].description'
"osd_op(client.44123.0:98213 6.1c 6:38...rbd_data... [write 0~4194304])"

# Per-OSD latency — apply/commit latency spikes point at a dying disk or spilled RocksDB
$ ceph osd perf
osd  commit_latency(ms)  apply_latency(ms)
  9                 214                214    <-- outlier, investigate the device
  3                   2                  2
  ...
```

### 5.8 Checklist de verificación estándar después de cualquier cambio

```bash
$ ceph -s                          # quorum, osd up/in, all pgs active+clean
$ ceph health detail               # zero warnings/errors
$ ceph osd tree                    # every OSD up + in, correct CRUSH placement
$ ceph df                          # MAX AVAIL sane, no pool over nearfull
$ ceph osd pool autoscale-status   # PG counts converged
$ ceph fs status <fs>              # 1 active MDS + standby per filesystem
$ ceph orch ls                     # every service RUNNING at desired count
```

El único criterio de aceptación para "el clúster está sano": **`HEALTH_OK` y cada PG `active+clean`.** Cualquier otro estado de PG significa que los datos están o en redundancia reducida o migrando, y ningún mantenimiento (reinicio, remoción de OSD, upgrade) debería proceder hasta que se despeje.

---

## 6. Referencias

- LPI — Exam 306 Objectives (306-300, v3.0), Topic 363.2 Ceph Storage Clusters: https://www.lpi.org/our-certifications/exam-306-objectives/
- Ceph Documentation — Intro & Architecture: https://docs.ceph.com/en/reef/architecture/
- Ceph — RADOS / Cluster Operations: https://docs.ceph.com/en/reef/rados/
- Ceph — CRUSH Maps: https://docs.ceph.com/en/reef/rados/operations/crush-map/
- Ceph — Pools: https://docs.ceph.com/en/reef/rados/operations/pools/
- Ceph — Placement Groups & Autoscaler: https://docs.ceph.com/en/reef/rados/operations/placement-groups/
- Ceph — Erasure Code: https://docs.ceph.com/en/reef/rados/operations/erasure-code/
- Ceph — BlueStore configuration & sizing: https://docs.ceph.com/en/reef/rados/configuration/bluestore-config-ref/
- Ceph — cephadm (install & host/service management): https://docs.ceph.com/en/reef/cephadm/
- Ceph — Service Specifications & OSD drive groups: https://docs.ceph.com/en/reef/cephadm/services/osd/
- Ceph — Monitor configuration & troubleshooting: https://docs.ceph.com/en/reef/rados/configuration/mon-config-ref/ and https://docs.ceph.com/en/reef/rados/troubleshooting/troubleshooting-mon/
- Ceph — Troubleshooting OSDs & PGs: https://docs.ceph.com/en/reef/rados/troubleshooting/troubleshooting-osd/ and https://docs.ceph.com/en/reef/rados/troubleshooting/troubleshooting-pg/
- Ceph — RBD (block device): https://docs.ceph.com/en/reef/rbd/
- Ceph — CephFS (filesystem & MDS): https://docs.ceph.com/en/reef/cephfs/
- Ceph — RADOS Gateway (RGW): https://docs.ceph.com/en/reef/radosgw/
- Ceph — Health checks reference: https://docs.ceph.com/en/reef/rados/operations/health-checks/
- CRUSH: Controlled, Scalable, Decentralized Placement of Replicated Data — Weil et al., SC '06: https://ceph.io/assets/pdfs/weil-crush-sc06.pdf