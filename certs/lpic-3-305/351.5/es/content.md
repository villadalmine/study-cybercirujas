# 351.5 Gestión de imágenes de disco de máquinas virtuales

**LPIC-3 Virtualization and Containerization — Exam 305-300 (v3.0)**
**Topic 351: Full Virtualization · Objective 351.5 · Weight: 5**

> **Alcance (según los objetivos de LPI).** Crear, copiar, convertir y manipular imágenes de disco de máquinas virtuales; entender las funciones de `qcow2` (copy-on-write, snapshots internos/externos, backing files); relacionar las imágenes de disco con el almacenamiento basado en volúmenes; acceder a los datos dentro de las imágenes con loop devices, `kpartx`, network block devices y `libguestfs`; conocimiento de `raw` y `qed`. Utilidades dentro del alcance: `qemu-img`, `qemu-nbd`, `kpartx`, `losetup`, `guestfish`, `guestmount`, `virt-cat`, `virt-copy-in`, `virt-copy-out`, `virt-diff`, `virt-df`, `virt-filesystems`, `virt-inspector`, `virt-ls`, `virt-rescue`, `virt-sparsify`.

---

## 1. El problema en producción: una imagen de disco es un subsistema de almacenamiento, no un archivo

Un SRE hereda una flota donde "el disco de la VM" se trata como un blob opaco. Ese encuadre se rompe en producción la primera vez que ocurre cualquiera de estas cosas:

- Una golden image se clona a 400 VMs y cada clon aparenta consumir 20 GiB, así que la plataforma se aprovisiona para **8 TiB** de almacenamiento que, en la práctica, contiene ~120 GiB de datos divergentes *reales*. Alguien dimensionó la LUN mal por un factor de 60.
- Se toma un "snapshot rápido antes de la actualización" en un hipervisor con snapshots internos de `qcow2`. Tres meses y 40 snapshots después, la latencia de I/O de ese guest es 10× la línea base y nadie sabe por qué.
- Un job de backup hace `cp` de un archivo `qcow2` en vivo que tiene una caché de metadatos en memoria aún no volcada. La restauración está silenciosamente corrupta; `qemu-img check` sobre la copia informa clusters filtrados (leaked) y una tabla `l2` que apunta a un refcount block.
- Una imagen base se mueve con `mv` a un nuevo datastore. Cada overlay que la referenciaba por **ruta absoluta** falla al arrancar con `Could not open backing file: No such file or directory`.

Un formato de imagen de disco es una **capa de traducción dirección-de-bloque-del-guest → dirección-de-almacenamiento-del-host** con su propio asignador (allocator), sus propios metadatos (conteos de referencias, tablas de asignación), su propio modelo de consistencia y sus propios modos de fallo. Gestionarla con competencia significa entender esa capa de traducción de la misma forma en que entenderías el formato en disco de un filesystem — porque eso es exactamente lo que es `qcow2`: un contenedor sparse, copy-on-write, algo parecido a log-structured, con una búsqueda de dos niveles tipo tabla de páginas.

El eje arquitectónico sobre el que este objetivo te obliga a razonar:

| Aspecto | Imagen basada en archivo (`qcow2`/`raw` sobre un filesystem) | Basada en volumen (LVM LV, Ceph RBD, ZFS zvol, iSCSI LUN) |
|---|---|---|
| Formato en el medio | Estructurado (`qcow2`) o `raw` | Casi siempre `raw` — el volumen *es* el block device |
| Sparse/thin provisioning | `qcow2` nativo; `raw` mediante huecos del filesystem | Thin pool de la capa de almacenamiento (LVM-thin, RBD, ZFS) |
| Snapshots | En `qcow2` (internos) o archivos overlay (externos) | Nativos del almacenamiento (LVM-thin snapshot, `rbd snap`, `zfs snapshot`) |
| Copy-on-write | COW de `qcow2` dirigido por refcount; backing files | COW nativo del almacenamiento |
| Portabilidad | Alta — un archivo que podés `scp`/`convert` | Baja — atado al sistema de almacenamiento |
| Techo de rendimiento | Indirección extra (búsqueda L2, FS del host) | Casi bare-metal; sin sobrecarga de formato |
| Radio de explosión del overcommit | Filesystem del host lleno → *todos* los guests con ENOSPC | Thin pool lleno → fallan los guests de ese pool |

El resto de este material trata la imagen como el subsistema de almacenamiento que es.

---

## 2. Internals de `qcow2` — el formato sobre el que debés poder razonar

### 2.1 Anatomía en disco

`qcow2` ("QEMU Copy-On-Write v2", con el conjunto de funciones v3 viviendo dentro de un contenedor v2 bajo `compat=1.1`) mapea una **dirección lógica de bloque del guest** a un **offset de archivo del host** a través de una tabla de dos niveles, exactamente como una tabla de páginas de una CPU:

```
guest offset ─┬─ L1 index ──► L1 table ──► L2 table offset
              ├─ L2 index ──► L2 table ──► host cluster offset
              └─ intra-cluster offset ─────────────────────────► byte in cluster
```

- **Cluster** — la unidad de asignación (por defecto 64 KiB, `cluster_bits = 16`). Todo se asigna en clusters completos: datos, tablas L2, refcount blocks.
- **Tabla L1** — pequeña, se mantiene en memoria, apunta a las tablas L2.
- **Tablas L2** — una entrada L2 por cluster del guest; la entrada contiene el offset del host (o 0 = no asignado → se lee como ceros, o cae hacia el backing file).
- **Refcount table + refcount blocks** — cuántas veces se referencia cada cluster del host. **Este es el mecanismo que hace posibles el COW y los snapshots internos.** Un cluster con `refcount > 1` es compartido; escribir en él dispara asignar-copiar-y-decrementar.
- **Header** — el magic `QFI\xfb`, versión, `cluster_bits`, `size`, `l1_table_offset`, `refcount_table_offset`, `backing_file_offset`, `nb_snapshots`, `snapshots_offset` y (v3) las extensiones de header y los campos de bits de funciones (`incompatible/compatible/autoclear`).

La consecuencia que debés interiorizar: **el layout en bytes de un archivo `qcow2` no es el layout en bytes del guest.** No podés hacer `grep` del `/etc/hostname` de un guest desde los bytes crudos del `qcow2` en un offset predecible, y no podés hacer `dd` de forma segura sobre una región de él. Todo acceso tiene que pasar por la capa de traducción — que es por lo que existen `libguestfs`, `qemu-nbd` y `guestmount`.

### 2.2 Las perillas que deciden el comportamiento en producción

| Opción (`-o`) | Valores | Qué cambia | Guía para producción |
|---|---|---|---|
| `compat` | `0.10` / `1.1` | Conjunto de funciones. `1.1` = soporte de zero-cluster, lazy refcounts, zstd, LUKS, bitmaps persistentes | Siempre `1.1` salvo que un hipervisor de museo necesite `0.10` |
| `cluster_size` | 512 B – 2 MiB (por defecto 64 KiB) | Granularidad de asignación; tamaño de la tabla L2 | Clusters pequeños → menos desperdicio de COW, más metadatos y menor alcance de L2. Clusters grandes → menos asignaciones, peor amplificación de COW |
| `preallocation` | `off`/`metadata`/`falloc`/`full` | Cuánto espacio del host se reserva de antemano | Ver §2.3 |
| `lazy_refcounts` | on/off | Difiere las actualizaciones de refcount → menos escrituras, más rápido; requiere `qemu-img check` tras un crash | On para rendimiento, off si no podés tolerar una reparación post-crash |
| `extended_l2` | on/off | Asignación por subcluster (32 subclusters/cluster) → COW con granularidad más fina | Reduce drásticamente la amplificación de escritura de COW en clusters de 64 KiB |
| `compression_type` | `zlib`/`zstd` | Codec para clusters comprimidos (`convert -c`) | `zstd` — más rápido y mejor ratio; requiere `compat=1.1` |
| `encrypt.format` | `luks` | Cifrado LUKS de toda la imagen dentro del contenedor | El único cifrado soportado; el viejo `aes` está roto, no lo uses |
| `refcount_bits` | 1–64 (por defecto 16) | Máximo de referencias simultáneas a un cluster | 16 está bien; bajalo solo para recortar metadatos en imágenes enormes |

### 2.3 Preallocation — la perilla peor configurada de todas

```
off       → allocate nothing but the essential header; fully thin. Slowest steady-state
             (metadata clusters allocated on demand, causing fragmentation).
metadata  → allocate ALL L1/L2/refcount metadata now; data stays sparse. File shows full
             virtual size in `ls -l` but is sparse on disk. Avoids runtime metadata churn.
falloc    → posix_fallocate(): reserve host blocks without writing them. Fast, guarantees
             space (no surprise ENOSPC mid-flight), image is no longer sparse.
full      → write zeros over the whole image. Slow, guarantees space AND contiguity.
```

La trampa: `preallocation=metadata` hace que `ls -l` informe 20 GiB mientras `du` informa 4 MiB. El monitoreo que alerta sobre el tamaño aparente (`ls`) te va a despertar a las 3 de la mañana por un disco que está lleno al 0,02%. El monitoreo debe leer los bloques **asignados** (`du`, `stat -c %b`, el "disk size" de `qemu-img info`).

### 2.4 Backing files y la cadena de copy-on-write

Un **overlay** es un `qcow2` cuyos clusters *no asignados* caen hacia un **backing file**. Las lecturas golpean primero el overlay; ante un miss leen la backing image. Las escrituras siempre aterrizan en el overlay (COW). Así es como conseguís 400 clones casi gratis de una sola golden image:

```
base-fedora40.qcow2  (read-only, 1.8 GiB actual)
   ▲            ▲            ▲
   │            │            │
web-01.qcow2  web-02.qcow2  db-01.qcow2   ← overlays, ~40–800 MiB each of divergence
```

Dos hechos que causan caídas:

1. **La ruta del backing se almacena dentro del overlay** (relativa o absoluta). Mové/renombrá la base y todos los overlays se rompen. Corregí el puntero con `qemu-img rebase -u` — nunca editando bytes.
2. **Nunca se debe escribir en una base mientras los overlays la referencian.** Un solo byte cambiado en la base corrompe el contenido visible por el guest de *cada* overlay, porque sus regiones no asignadas ahora leen datos distintos de aquellos sobre los que se construyeron. Mantené las bases de solo lectura (`chmod 0444`, o inmutables mediante una política de almacenamiento).

---

## 3. `qemu-img` — la herramienta principal, subcomando por subcomando

### 3.1 Create

```console
$ qemu-img create -f qcow2 -o cluster_size=64k,compat=1.1,lazy_refcounts=on base.qcow2 20G
Formatting 'base.qcow2', fmt=qcow2 cluster_size=65536 extended_l2=off compression_type=zlib size=21474836480 lazy_refcounts=on refcount_bits=16

$ qemu-img create -f qcow2 -o preallocation=falloc,extended_l2=on data.qcow2 100G
Formatting 'data.qcow2', fmt=qcow2 cluster_size=65536 extended_l2=on preallocation=falloc compression_type=zlib size=107374182400 lazy_refcounts=off refcount_bits=16
```

Crear un **overlay** sobre una backing image (nota: fijá el formato del backing explícitamente — el probing de formato sobre backing files es una superficie de ataque/footgun conocida):

```console
$ qemu-img create -f qcow2 -b base.qcow2 -F qcow2 web-01.qcow2
Formatting 'web-01.qcow2', fmt=qcow2 cluster_size=65536 extended_l2=off compression_type=zlib size=21474836480 backing_file=base.qcow2 backing_fmt=qcow2 lazy_refcounts=off refcount_bits=16
```

### 3.2 Info — leer el estado de la capa de traducción

```console
$ qemu-img info web-01.qcow2
image: web-01.qcow2
file format: qcow2
virtual size: 20 GiB (21474836480 bytes)
disk size: 912 KiB
cluster_size: 65536
backing file: base.qcow2
backing file format: qcow2
Format specific information:
    compat: 1.1
    compression type: zlib
    lazy refcounts: false
    refcount bits: 16
    corrupt: false
    extended l2: false
Child node '/file':
    filename: web-01.qcow2
    protocol type: file
    file length: 960 KiB (983040 bytes)
    disk size: 912 KiB
```

Recorré toda la cadena y emití JSON legible por máquina para automatización:

```console
$ qemu-img info --backing-chain --output=json web-01.qcow2 | jq -r '.[] | "\(.filename)  virt=\(.["virtual-size"])  actual=\(.["actual-size"])  backing=\(.["backing-filename"] // "-")"'
web-01.qcow2  virt=21474836480  actual=933888  backing=base.qcow2
base.qcow2    virt=21474836480  actual=1932787712  backing=-
```

`corrupt: true` en esa salida es una señal de **detener la línea** (stop-the-line) — la imagen tiene una inconsistencia que el driver detectó; no la arranques, corré `qemu-img check` (§5).

### 3.3 Convert — cambios de formato, aplanado, compresión, sparsificación

`convert` lee la fuente a través de su driver de formato y escribe el destino a través del driver de destino. **Aplana las backing chains** (la salida es autónoma salvo que pidas lo contrario), omite los clusters cero/no asignados (`-S` controla la granularidad de los huecos sparse) y es tu primitiva de copia segura.

```console
# qcow2 (with a backing chain) → a single standalone, compressed qcow2 for archival
$ qemu-img convert -p -O qcow2 -c -o compression_type=zstd web-01.qcow2 web-01-archive.qcow2
    (100.00/100%)

# qcow2 → raw for a volume-based datastore (LVM/RBD want raw)
$ qemu-img convert -p -f qcow2 -O raw base.qcow2 /dev/vg_fast/lv_web01
    (100.00/100%)

# Import a cloud vendor image (VMware) → qcow2
$ qemu-img convert -p -O qcow2 appliance.vmdk appliance.qcow2
    (100.00/100%)

# Multithreaded, using host block-level copy offload where available
$ qemu-img convert -p -m 8 -W -O qcow2 src.qcow2 dst.qcow2
    (100.00/100%)
```

Matriz de soporte de formatos que debés recordar:

| Formato | Read | Write | Snapshots | Backing chain | Notas / origen |
|---|---|---|---|---|---|
| `qcow2` | ✅ | ✅ | ✅ internos + externos | ✅ | Nativo de QEMU; el default para basado en archivo |
| `raw` | ✅ | ✅ | ❌ (usá la capa de almacenamiento) | ❌ | El más rápido; sin metadatos; sparse solo mediante huecos del FS |
| `qed` | ✅ | ✅ | ❌ | ✅ | Formato COW de QEMU deprecado — **solo conocimiento** |
| `vmdk` | ✅ | ✅ | limitados | ✅ | VMware; muchas subvariantes (`subformat=`) |
| `vdi` | ✅ | ✅ | ❌ | ❌ | VirtualBox |
| `vhdx` | ✅ | ✅ | ❌ | ❌ | Hyper-V (moderno); `vpc` = VHD legacy |
| `luks` | ✅ | ✅ | — | — | Contenedor LUKS crudo como formato de imagen |

### 3.4 Snapshots — internos (en el archivo) vs externos (overlay)

Los snapshots **internos** viven dentro de un único `qcow2` y están dirigidos por la maquinaria de refcount:

```console
$ qemu-img snapshot -c pre-upgrade base.qcow2          # create
$ qemu-img snapshot -l base.qcow2                       # list
Snapshot list:
ID        TAG                 VM_SIZE                DATE       VM_CLOCK     ICOUNT
1         pre-upgrade             0 B  2026-08-11 09:14:22  0000:00:00.000        0
$ qemu-img snapshot -a pre-upgrade base.qcow2           # apply/revert
$ qemu-img snapshot -d pre-upgrade base.qcow2           # delete
```

Los snapshots **externos** crean un overlay nuevo y hacen que el archivo *anterior* sea la backing image — la ruta viva, de baja latencia, que usan `virsh`/`libvirt` para snapshots en línea:

```console
$ qemu-img create -f qcow2 -b base.qcow2 -F qcow2 base.snap1.qcow2
# writes now go to base.snap1.qcow2; base.qcow2 becomes the read-only backing point-in-time.
```

El compromiso que aparece en incidentes reales:

| Aspecto | Snapshot interno | Snapshot externo (overlay) |
|---|---|---|
| Layout de almacenamiento | Un solo archivo | Un archivo nuevo por snapshot (una cadena) |
| Estado de la VM en vivo (RAM) | Puede embeberse (`VM_SIZE`) | Solo disco salvo que se guarde la RAM por separado |
| Amplificación de lectura | Acotada, en un archivo | **Crece con la profundidad de la cadena** — cada lectura no asignada recorre la cadena |
| Costo de borrado | Actualización de refcount + liberación de cluster (puede ser lento/fragmentar) | Merge con `block-commit`/`block-stream` |
| Portabilidad | Un archivo para mover | Hay que mover toda la cadena, con las rutas intactas |
| Soporte de snapshot en vivo | Más débil | El default de libvirt para snapshots en línea |
| Radio de explosión ante fallo | La corrupción arriesga toda la imagen + todos los snapshots | Una hoja rota solo pierde las escrituras posteriores al snapshot |

**Regla general:** snapshots externos para checkpoints operativos, acotados en el tiempo (backup, ventanas de actualización) que *confirmás o descartás con prontitud*; nunca dejes que una cadena crezca sin límite. Snapshots internos para "estados etiquetados" portables y autónomos de una imagen offline.

### 3.5 Commit & rebase — colapsar y re-emparentar cadenas

`commit` fusiona un overlay **hacia abajo** dentro de su backing file, y luego el overlay queda vacío:

```console
$ qemu-img commit -p web-01.qcow2
    (100.00/100%)
Image committed.
```

`rebase` cambia el backing file de una imagen. El **modo seguro** (por defecto) lee a través de ambas cadenas, la vieja y la nueva, y copia lo que haga falta para que los datos visibles por el guest no cambien. El **modo inseguro** (`-u`) solo reescribe el puntero del backing — usalo *solo* cuando moviste/renombraste un backing file y los datos son idénticos byte a byte:

```console
# The base moved to /images/golden/. Fix the pointer without touching data:
$ qemu-img rebase -u -b /images/golden/base.qcow2 -F qcow2 web-01.qcow2

# Re-parent onto a different (but content-compatible) base, copying deltas safely:
$ qemu-img rebase -b new-base.qcow2 -F qcow2 web-01.qcow2

# Flatten to standalone (no backing file at all):
$ qemu-img rebase -b "" web-01.qcow2
```

### 3.6 Resize — y la otra mitad, del lado del guest

`qemu-img resize` solo cambia el tamaño declarado del *contenedor*. La **tabla de particiones, el PV de LVM y el filesystem dentro del guest no se mueven** — eso es una operación separada, del lado del guest.

```console
$ qemu-img resize base.qcow2 +20G
Image resized.

# Shrink is dangerous and must be forced AND preceded by an in-guest FS shrink:
$ qemu-img resize --shrink base.qcow2 15G
Image resized.
```

Procedimiento completo de crecimiento (offline, mediante `libguestfs` — ver §6):

```console
$ qemu-img resize disk.qcow2 +20G
$ virt-filesystems --long --parts --blkdevs -a disk.qcow2
# then grow partition + PV + LV + FS inside, e.g. with virt-resize into a new image:
$ qemu-img create -f qcow2 disk-new.qcow2 40G
$ virt-resize --expand /dev/sda2 disk.qcow2 disk-new.qcow2
```

### 3.7 Los subcomandos de diagnóstico y contabilidad

```console
# Allocation map — exactly which guest ranges are allocated, zero, or in the backing file
$ qemu-img map --output=json web-01.qcow2 | jq -c '.[0:3][]'
{"start":0,"length":1048576,"depth":1,"present":true,"zero":false,"data":true,"offset":327680}
{"start":1048576,"length":65536,"depth":0,"present":true,"zero":false,"data":true,"offset":983040}
{"start":1114112,"length":21473722368,"depth":0,"present":false,"zero":true,"data":false}

# Measure the host space a conversion will actually need BEFORE you run it
$ qemu-img measure -O qcow2 base.qcow2
required size: 1969225728
fully allocated size: 21476933632

# Byte-compare two images (are these two clones actually identical?)
$ qemu-img compare base.qcow2 base-restored.qcow2
Images are identical.

# Change format options in place (e.g. upgrade compat 0.10 → 1.1)
$ qemu-img amend -o compat=1.1 legacy.qcow2

# Persistent dirty bitmaps for incremental backup (compat=1.1)
$ qemu-img bitmap --add --enable backup0 base.qcow2
```

---

## 4. Manifiestos completos de producción

### 4.1 Dominio de libvirt — overlay `qcow2`, discard/TRIM, I/O con hilos, blockdev

libvirt describe el almacenamiento de la VM en XML (esta es la representación autoritativa, de producción, de "cómo una VM usa una imagen de disco"). Estrofa de disco completa, sin abreviar:

```xml
<domain type='kvm'>
  <name>web-01</name>
  <memory unit='GiB'>4</memory>
  <vcpu>2</vcpu>
  <os>
    <type arch='x86_64' machine='q35'>hvm</type>
    <boot dev='hd'/>
  </os>
  <devices>
    <!-- Overlay on a shared read-only golden image, thin + TRIM-capable -->
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'
              cache='none' io='native' discard='unmap' detect_zeroes='unmap'
              queues='4'/>
      <source file='/var/lib/libvirt/images/web-01.qcow2'>
        <backingStore type='file'>
          <format type='qcow2'/>
          <source file='/var/lib/libvirt/images/golden/base-fedora40.qcow2'/>
          <backingStore/>
        </backingStore>
      </source>
      <target dev='vda' bus='virtio'/>
      <address type='pci' domain='0x0000' bus='0x04' slot='0x00' function='0x0'/>
    </disk>

    <!-- A second, volume-based data disk living directly on an LVM LV as raw -->
    <disk type='block' device='disk'>
      <driver name='qemu' type='raw' cache='none' io='native' discard='unmap'/>
      <source dev='/dev/vg_fast/lv_web01_data'/>
      <target dev='vdb' bus='virtio'/>
    </disk>

    <controller type='scsi' model='virtio-scsi'/>
    <memballoon model='virtio'/>
  </devices>
</domain>
```

Por qué importan estos atributos en producción:

| Atributo | Valor | Efecto |
|---|---|---|
| `cache` | `none` | Evita la page cache del host → consistencia correcta ante crash, evita el doble caching |
| `io` | `native` | Linux AIO; menor latencia que el threadpool por defecto para O_DIRECT |
| `discard` | `unmap` | El `fstrim` del guest se propaga a `qemu-img` → los clusters se liberan, la imagen vuelve a adelgazar (re-thins) |
| `detect_zeroes` | `unmap` | Las escrituras de ceros se vuelven desasignaciones en vez de clusters de ceros almacenados |
| `<backingStore>` | explícito | Fijá el formato del backing para que QEMU nunca *pruebe* (probe) el formato (seguridad) |

### 4.2 Snapshot externo en línea + block-commit, mediante `virsh`

```console
# Take a disk-only external snapshot of a running guest (no downtime)
$ virsh snapshot-create-as --domain web-01 \
      --name backup-2026-08-11 --no-metadata \
      --disk-only --atomic \
      --diskspec vda,snapshot=external,file=/var/lib/libvirt/images/web-01.backup.qcow2
Domain snapshot backup-2026-08-11 created

# ... back up the now-frozen backing file safely while the guest writes to the overlay ...
$ qemu-img convert -O qcow2 -c -o compression_type=zstd \
      /var/lib/libvirt/images/web-01.qcow2 /backup/web-01-2026-08-11.qcow2

# Live-merge the overlay back down and pivot the guest onto the base (no downtime)
$ virsh blockcommit web-01 vda --active --pivot --verbose
Block commit: [100 %]
Successfully pivoted
```

### 4.3 KubeVirt / CDI DataVolume — gestión de imágenes en un clúster

En Kubernetes con KubeVirt, el ciclo de vida de la imagen de disco es declarativo. CDI (Containerized Data Importer) **importa y convierte** un `qcow2` a un PVC, autoconvirtiéndolo a `raw` en volúmenes `Block`:

```yaml
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: fedora40-golden
  namespace: vm-workloads
spec:
  source:
    http:
      url: "https://mirror.internal/images/Fedora-Cloud-Base-40.qcow2"
      # CDI verifies the checksum and converts qcow2 → the storage's native format
  storage:
    accessModes: ["ReadWriteMany"]
    volumeMode: Block          # → CDI writes a raw image directly to the block device
    resources:
      requests:
        storage: 20Gi
    storageClassName: ceph-rbd
---
# A per-VM thin clone of the golden PVC (COW at the storage layer, not qcow2)
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: web-01-rootdisk
  namespace: vm-workloads
spec:
  source:
    pvc:
      name: fedora40-golden
      namespace: vm-workloads
  storage:
    accessModes: ["ReadWriteOnce"]
    volumeMode: Block
    resources:
      requests:
        storage: 20Gi
    storageClassName: ceph-rbd     # smart-clone → rbd snapshot+clone, near-instant
```

Esta es la cara de producción de "las imágenes de disco se relacionan con el almacenamiento basado en volúmenes": dentro del clúster, las funciones de COW/backing-chain del `qcow2` son **reemplazadas** por los snapshot/clone nativos de la capa de almacenamiento (Ceph RBD aquí). El trabajo de CDI es la *conversión* en la frontera.

---

## 5. Verificación y diagnóstico de fallos

### 5.1 Comprobación de consistencia y reparación

`qemu-img check` valida las refcount tables y la consistencia de L1/L2 — el equivalente en disco de `fsck`:

```console
$ qemu-img check base.qcow2
No errors were found on the image.
Image end offset: 1969881088

# A corrupted / leaked-cluster image:
$ qemu-img check dirty.qcow2
Leaked cluster 5348 refcount=1 reference=0
Leaked cluster 5349 refcount=1 reference=0
2 leaked clusters were found on the image.
This means waste of disk space, but no harm to data.

# Repair leaks (safe) and, if needed, all errors (aggressive):
$ qemu-img check -r leaks dirty.qcow2
$ qemu-img check -r all   dirty.qcow2
```

Guía de decisión:

| `qemu-img check` dice | Significado | Acción |
|---|---|---|
| `No errors were found` | Limpio | Continuar |
| `N leaked clusters ... no harm to data` | Clusters asignados-pero-no-referenciados (a menudo tras un crash con `lazy_refcounts`) | `check -r leaks`; investigá por qué (apagado sucio) |
| `ERROR ... refcount ... reference` | Inconsistencia estructural | Copiá el archivo primero, luego `check -r all`; si el guest está arriba, sacá los datos con `libguestfs` antes de tocarlo |
| `corrupt: true` en `info` | El driver marcó la imagen en tiempo de ejecución | **No la arranques.** `check`, luego restaurá desde backup si la reparación falla |

### 5.2 La discrepancia entre tamaño sparse / aparente — cómo leerla correctamente

```console
$ ls -lh base.qcow2
-rw-r--r--. 1 qemu qemu 21G Aug 11 09:20 base.qcow2      # APPARENT (virtual) size — misleading

$ du -h --apparent-size base.qcow2
21G     base.qcow2

$ du -h base.qcow2                                        # ALLOCATED size — the truth
1.9G    base.qcow2

$ qemu-img info base.qcow2 | grep -E 'virtual|disk size'
virtual size: 20 GiB (21474836480 bytes)
disk size: 1.9 GiB
```

**Regla de diagnóstico:** la alertas de capacidad y la facturación deben basarse en `du` / el *disk size* de `qemu-img`, nunca en `ls`. Un guest que sigue haciendo crecer su imagen a pesar del `fstrim` interno apunta a una ruta de discard rota (falta de `discard='unmap'`, o un filesystem/cola que no emite TRIM).

### 5.3 Rotura de la backing chain

```console
$ qemu-img info web-01.qcow2
qemu-img: Could not open 'web-01.qcow2': Could not open backing file: Could not open '/old/path/base.qcow2': No such file or directory
```

Diagnosticá el puntero registrado y reparalo *sin copiar datos*:

```console
$ qemu-img info --output=json web-01.qcow2 2>/dev/null | jq -r '."full-backing-filename"'
/old/path/base.qcow2

$ qemu-img rebase -u -b /images/golden/base.qcow2 -F qcow2 web-01.qcow2
$ qemu-img info web-01.qcow2 | grep backing
backing file: /images/golden/base.qcow2
backing file format: qcow2
```

### 5.4 Creep de latencia en la cadena de snapshots

Síntoma: la latencia de lectura aleatoria de un guest se degrada a lo largo de semanas. Confirmá la profundidad de la cadena y colapsala:

```console
$ qemu-img info --backing-chain web-01.qcow2 | grep -c 'file format'
7                                   # 7-deep chain → every backing-store read walks 7 files

$ virsh blockcommit web-01 vda --active --pivot --verbose   # merge back to base
Block commit: [100 %]
Successfully pivoted
```

### 5.5 Nunca copies una imagen en vivo con `cp`

Un guest en ejecución mantiene metadatos de `qcow2` en memoria que aún no están en disco. Un `cp`/`rsync` crudo del archivo produce un snapshot inconsistente. **Siempre** o bien (a) tomá primero un snapshot externo y copiá el backing file ahora congelado, o bien (b) usá `virsh blockcopy` / `qemu-img convert` contra una fuente quiescida. Verificá una restauración con `qemu-img check` y `qemu-img compare`.

---

## 6. Acceder a los datos dentro de las imágenes — loop devices, NBD, `kpartx`, `libguestfs`

Hay dos familias de acceso. Entendé *por qué* una es peligrosa y una es segura.

| Mecanismo | Formatos | ¿Root? | ¿Corre los drivers de FS del guest en el kernel del host? | ¿Seguro en imágenes no confiables? | Usar cuando |
|---|---|---|---|---|---|
| `losetup` + `kpartx` | solo `raw` | sí | **sí** (el host lo monta) | ❌ no | Ediciones rápidas de `raw` en imágenes confiables |
| `qemu-nbd` | cualquiera (`qcow2`, `vmdk`, …) | sí | **sí** | ❌ no | Necesitás semántica de block-device para cualquier formato |
| `libguestfs` (`guestfish`, `guestmount`, `virt-*`) | cualquiera | **no** | **no** — appliance VM aislada | ✅ sí | Todo lo demás; scripting; imágenes no confiables |

El punto de seguridad (una superficie de CVE real): `losetup`/`kpartx`/`qemu-nbd` montan el filesystem del guest con el driver de filesystem del **kernel del host**. Una imagen de guest maliciosa puede llevar un filesystem manipulado que explote un bug de kernel de ext4/xfs y comprometer el host. `libguestfs` corre el mismo acceso dentro de una appliance KVM desechable — una imagen hostil solo hace crashear el sandbox. **Preferí `libguestfs` para cualquier cosa que no hayas construido vos mismo.**

### 6.1 `losetup` + `kpartx` — solo imágenes raw

```console
$ sudo losetup -fP --show disk.raw
/dev/loop3

$ lsblk /dev/loop3
NAME      MAJ:MIN RM  SIZE RO TYPE MOUNTPOINTS
loop3       7:3    0   20G  0 loop
├─loop3p1   259:0  0    1G  0 part
└─loop3p2   259:1  0   19G  0 part

$ sudo mount /dev/loop3p2 /mnt && ls /mnt
bin  boot  dev  etc  home  lib  ...
$ sudo umount /mnt && sudo losetup -d /dev/loop3
```

Si tu `losetup` carece de `-P`, usá `kpartx` para exponer las particiones explícitamente:

```console
$ sudo losetup -f --show disk.raw
/dev/loop4
$ sudo kpartx -av /dev/loop4
add map loop4p1 (253:5): 0 2097152 linear 7:4 2048
add map loop4p2 (253:6): 0 39843840 linear 7:4 2099200
$ sudo mount /dev/mapper/loop4p2 /mnt
...
$ sudo umount /mnt
$ sudo kpartx -d /dev/loop4 && sudo losetup -d /dev/loop4
```

### 6.2 `qemu-nbd` — exponer cualquier formato como un block device

```console
$ sudo modprobe nbd max_part=16
$ sudo qemu-nbd --connect=/dev/nbd0 --format=qcow2 base.qcow2   # ALWAYS pin --format
$ sudo partprobe /dev/nbd0
$ lsblk /dev/nbd0
NAME      MAJ:MIN RM SIZE RO TYPE MOUNTPOINTS
nbd0       43:0    0  20G  0 disk
├─nbd0p1   43:1    0   1G  0 part
└─nbd0p2   43:2    0  19G  0 part

$ sudo mount -o ro /dev/nbd0p2 /mnt        # mount read-only for inspection
$ sudo umount /mnt
$ sudo qemu-nbd --disconnect /dev/nbd0
/dev/nbd0 disconnected
```

Exportación de solo lectura, o servir sobre TCP para un consumidor remoto:

```console
$ sudo qemu-nbd --read-only --connect=/dev/nbd1 --format=qcow2 base.qcow2
$ qemu-nbd --format=qcow2 --port=10809 --persistent base.qcow2   # network block device server
```

> Olvidar `--format=` deja que QEMU *pruebe* (probe) el formato; un guest puede fabricar una imagen que pruebe como un tipo distinto — fijalo cada vez.

### 6.3 `libguestfs` — la ruta segura, scriptable y agnóstica al formato

El conjunto de herramientas libguestfs arranca una appliance KVM mínima, le entrega la imagen y expone los filesystems del guest a través de una API — **sin root, sin exposición del kernel del host, funciona con `qcow2` con backing chains, LVM, LUKS, todo.**

`guestfish` — interactivo/scriptable:

```console
$ guestfish --ro -a base.qcow2 -i
Welcome to guestfish, the guest filesystem shell for
editing virtual machine filesystems and disk images.

><fs> cat /etc/os-release | head -1
NAME="Fedora Linux"
><fs> ll /etc/ssh/sshd_config
-rw-------. 1 root root 3669 Aug  1 12:04 /etc/ssh/sshd_config
><fs> exit

# One-liner form (great in CI):
$ guestfish --ro -a base.qcow2 -i cat /etc/hostname
web-golden
```

`guestmount` — montaje FUSE, sin privilegios, **siempre `--ro` salvo que realmente pretendas escribir**:

```console
$ guestmount -a base.qcow2 -i --ro /mnt/inspect
$ cat /mnt/inspect/etc/os-release | head -2
NAME="Fedora Linux"
VERSION="40 (Cloud Edition)"
$ guestunmount /mnt/inspect
```

La familia de herramientas `virt-*` — operaciones puntuales, sin ceremonia de montaje:

```console
# What partitions/filesystems/LVM does this image contain?
$ virt-filesystems --long --parts --blkdevs --logical-volumes --extra -a base.qcow2 -h
Name       Type       VFS   Label  Size  Parent
/dev/sda1  filesystem vfat  -      600M  -
/dev/sda2  filesystem xfs   root   19G   -
/dev/sda1  partition  -     -      600M  /dev/sda
/dev/sda2  partition  -     -      19G   /dev/sda
/dev/sda   device     -     -      20G   -

# Filesystem usage INSIDE the guest, without booting it
$ virt-df -h -a base.qcow2
Filesystem                    Size    Used  Available  Use%
base.qcow2:/dev/sda1          599M     14M       585M    3%
base.qcow2:/dev/sda2           19G    1.6G        17G    9%

# Full OS/inventory report as XML (drivers, apps, mountpoints)
$ virt-inspector -a base.qcow2 | xmllint --xpath '//product_name/text()' -
Fedora Linux 40 (Cloud Edition)

# Read a single file / list a directory without mounting
$ virt-cat -a base.qcow2 /etc/redhat-release
Fedora release 40 (Forty)
$ virt-ls -a base.qcow2 -l /var/log
total 40
drwxr-xr-x.  8 root   root   4096 Aug  1 12:10 .
-rw-r--r--.  1 root   root   1092 Aug  1 12:10 dnf.log

# Push files into / pull files out of an offline image (customization without boot)
$ virt-copy-in -a base.qcow2 ./resolv.conf /etc/
$ virt-copy-out -a base.qcow2 /var/log/messages ./forensics/

# What changed between two images / a golden and a drifted clone?
$ virt-diff -a base.qcow2 -A web-01-flat.qcow2 | head
- 0644       1234 /etc/motd
+ 0644       1450 /etc/motd
+ 0644        220 /etc/cron.d/telemetry-agent

# Emergency rescue shell against a broken guest (no host risk)
$ virt-rescue --ro -a broken.qcow2
><rescue> mount /dev/sda2 /sysroot && chroot /sysroot journalctl -xb --no-pager | tail
```

### 6.4 `virt-sparsify` — recuperar espacio, re-adelgazar una imagen

Con el tiempo una imagen `qcow2`/`raw` se infla: los datos borrados en el guest siguen ocupando clusters del host porque el espacio libre nunca se puso a cero/descartó. `virt-sparsify` pone a cero el espacio libre del guest y escribe una salida adelgazada (thin):

```console
$ du -h fat.qcow2
14G     fat.qcow2

$ virt-sparsify --compress fat.qcow2 slim.qcow2
[   0.0] Create overlay file in /tmp to protect source disk
[   2.1] Examine source disk
[   5.4] Fill free space in /dev/sda2 with zero
 100% ⟦▉▉▉▉▉▉▉▉▉▉▉▉▉▉▉▉▉▉▉▉⟧ --:--
[  47.9] Copy to destination and make sparse
[  71.2] Sparsify operation completed with no errors.

$ du -h slim.qcow2
2.3G    slim.qcow2

# In-place variant (careful — mutates the source):
$ virt-sparsify --in-place fat.qcow2
```

El paso de detección de ceros es lo que permite que ocurra la escritura sparse — que es exactamente por lo que `detect_zeroes=unmap` y el `fstrim` del guest importan para mantener las imágenes adelgazadas *sin* una pasada de sparsify offline.

---

## 7. Resumen de decisiones operativas

- **Elección de formato:** `qcow2` para imágenes portables, basadas en archivo, que necesitan snapshots/backing/compresión/cifrado. `raw` sobre almacenamiento basado en volúmenes (LVM/RBD/zvol), y dejá que la capa de almacenamiento sea dueña de los snapshots/clones. `qed` está muerto — solo conocimiento.
- **Thin de arriba a abajo:** `discard='unmap'` + `detect_zeroes='unmap'` en el dominio, `fstrim`/`fstrim.timer` en el guest, `virt-sparsify` para recuperación offline. Alertá sobre el tamaño **asignado**, nunca el aparente.
- **Los snapshots son deuda:** overlays externos para checkpoints operativos acotados en el tiempo, confirmalos/pivotealos con prontitud, mantené las cadenas poco profundas. Nunca hagas crecer una cadena sin límite; nunca escribas una base de la que dependen overlays.
- **Copiá de forma segura:** nunca hagas `cp` de una imagen en vivo; snapshot-y-después-copia o `qemu-img convert` sobre una fuente quiescida; verificá con `qemu-img check` + `qemu-img compare`.
- **Accedé de forma segura:** `libguestfs` (`guestfish`/`guestmount`/`virt-*`) por defecto — sin root, sin exposición del kernel del host, cualquier formato. Reservá `losetup`/`kpartx`/`qemu-nbd` para necesidades de `raw`/block-device en imágenes que confiás, y siempre fijá `--format`.

---

## Referencias

- LPI — Exam 305-300 Objectives (objective 351.5): https://www.lpi.org/our-certifications/exam-305-objectives/
- LPIC-3 Virtualization and Containerization certification overview: https://www.lpi.org/our-certifications/lpic-3-305/
- QEMU — `qemu-img` manual: https://www.qemu.org/docs/master/tools/qemu-img.html
- QEMU — `qemu-nbd` manual: https://www.qemu.org/docs/master/tools/qemu-nbd.html
- QEMU — qcow2 on-disk format specification: https://gitlab.com/qemu-project/qemu/-/blob/master/docs/interop/qcow2.txt
- QEMU — Disk image file formats: https://www.qemu.org/docs/master/system/images.html
- QEMU — Live block operations (commit, stream, mirror): https://www.qemu.org/docs/master/interop/live-block-operations.html
- QEMU — qcow2 cache / `l2-cache-size` configuration: https://www.qemu.org/docs/master/system/qemu-block-drivers.html
- libvirt — Domain XML format (disk devices): https://libvirt.org/formatdomain.html#hard-drives-floppy-disks-cdroms
- libvirt — Snapshot XML format: https://libvirt.org/formatsnapshot.html
- libvirt — `virsh` command reference: https://libvirt.org/manpages/virsh.html
- libguestfs — Tools and API home: https://libguestfs.org/
- libguestfs — `guestfish` manual: https://libguestfs.org/guestfish.1.html
- libguestfs — `guestmount` manual: https://libguestfs.org/guestmount.1.html
- libguestfs — `virt-sparsify` manual: https://libguestfs.org/virt-sparsify.1.html
- libguestfs — `virt-inspector` manual: https://libguestfs.org/virt-inspector.1.html
- libguestfs — `virt-filesystems` manual: https://libguestfs.org/virt-filesystems.1.html
- Linux — `losetup(8)`: https://man7.org/linux/man-pages/man8/losetup.8.html
- Linux — `kpartx(8)`: https://man7.org/linux/man-pages/man8/kpartx.8.html
- KubeVirt CDI — DataVolumes / disk image import: https://kubevirt.io/user-guide/storage/disks_and_volumes/
- Containerized Data Importer (CDI) documentation: https://github.com/kubevirt/containerized-data-importer/blob/main/doc/datavolumes.md