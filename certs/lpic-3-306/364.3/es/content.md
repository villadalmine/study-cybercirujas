# Tema 364.3: LVM avanzado

**LPIC-3 306 (examen 306-300, v3.0) — Alta disponibilidad en nodo único · Peso: 5.0**

---

## 1. El problema de producción: el almacenamiento como plano de control

Una tabla de particiones es un contrato estático. Decidís, en el momento del aprovisionamiento, que `/var` tiene 40 GiB y `/data` 200 GiB, y esa decisión queda congelada en la geometría del disco. En un contexto de HA de nodo único — un primario de base de datos, un broker con estado, un host hypervisor que debe sobrevivir a una falla de disco sin una ventana de mantenimiento — esa rigidez es el enemigo. Tres modos de falla se repiten en producción:

1. **El aviso de las 3 a.m. por sistema de archivos lleno.** `/var/lib/postgresql` se llena. Con particiones estáticas tu única jugada es migrar a un disco más grande. Con LVM hacés `lvextend` y `resize2fs`/`xfs_growfs` **en línea**, en segundos, con el servicio corriendo.
2. **El impuesto de la planificación de capacidad.** Si tenés que dimensionar cada volumen por adelantado, sobreaprovisionás cada volumen y comprás almacenamiento que nunca usás. El aprovisionamiento fino (thin provisioning) desacopla lo *asignado* de lo *consumido*, de modo que un host de 10 inquilinos puede presentar 10×500 GiB de volúmenes sobre un pool de 2 TiB, asignando extents reales solo en la primera escritura.
3. **El radio de explosión de un solo disco.** Falla un plato o un dispositivo NVMe y el nodo queda caído. El RAID por software *dentro* de LVM permite que un único volumen lógico abarque volúmenes físicos redundantes, sobreviva a la pérdida de un dispositivo y se repare en línea — sin una segunda capa de `mdadm` que coordinar.

El LVM avanzado convierte la pila de almacenamiento en un **plano de control definido por software**: una fina capa de metadatos sobre los targets de `device-mapper` (`dm`) en el kernel, donde la redundancia, los snapshots, el tiering (caché SSD delante de HDD) y la migración de datos en vivo son todas operaciones `lvconvert`/`lvextend` contra el mismo modelo de objetos — Physical Volume → Volume Group → Logical Volume — en lugar de cuatro herramientas inconexas.

El modelo mental que hay que llevar a lo largo de este tema:

```
   filesystem (xfs / ext4 / btrfs)
        │
   Logical Volume (LV)      ← what the OS mounts
        │  logical extents (LE)
   Volume Group (VG)        ← the allocation pool
        │  physical extents (PE), default 4 MiB
   Physical Volume (PV)     ← a disk, partition, mdraid, iSCSI LUN, LUKS device
        │
   device-mapper targets:  linear · thin · cache · writecache · raid · mirror
        │
   block devices (/dev/sd*, /dev/nvme*)
```

Cada funcionalidad «avanzada» es un target `dm` que los metadatos del LV cablean. Entender *qué target* respalda una funcionalidad es lo que te permite diagnosticarla — porque `dmsetup` ve la verdad que `lvs` resume.

---

## 2. Interioridades de la arquitectura sobre las que debés poder razonar

### 2.1 Extents, metadatos y la tabla de device-mapper

Un VG divide cada PV miembro en **physical extents** de tamaño fijo (PE, por defecto 4 MiB, fijado en `vgcreate --physicalextentsize`). Un LV es una lista ordenada de **logical extents** (LE) mapeados a PEs. Ese mapeo — más cada propiedad de cada PV/VG/LV — vive como **metadatos LVM2 en texto plano** en un buffer circular al inicio de cada PV (el área de metadatos), y se guarda como snapshot en cada cambio en `/etc/lvm/archive/` (historial) y `/etc/lvm/backup/` (actual). Este diseño de metadatos en texto es por lo que LVM es *recuperable*: un VG corrupto puede restaurarse desde un archivo legible por humanos con `vgcfgrestore`.

El kernel nunca lee esos metadatos. El espacio de usuario (`lvm`) los parsea y empuja una **tabla de device-mapper** al kernel. Inspeccioná la verdad:

```console
$ sudo dmsetup ls --tree
vg_data-lv_app (253:6)
 └─vg_data-tp_data-tpool (253:5)
    ├─vg_data-tp_data_tdata (253:3)
    │  └─ (8:16)
    └─vg_data-tp_data_tmeta (253:2)
       └─ (8:32)

$ sudo dmsetup table vg_data-lv_app
0 1048576000 thin 253:5 1
```

`lvs -a` muestra la misma pila con los sub-LVs ocultos entre corchetes (`[tp_data_tdata]`). **Regla: cuando `lvs` y la realidad discrepan, `dmsetup table`/`dmsetup status` es la fuente de verdad**, porque refleja lo que el kernel está corriendo realmente, no lo que los metadatos *quieren*.

### 2.2 El campo `lv_attr` es un diagnóstico de 10 caracteres

Cada línea de `lvs` lleva una cadena de atributos posicionales. Memorizá las posiciones primera, quinta y novena — responden «qué es, está vivo, está sano»:

| Pos | Significado | Valores que vas a ver |
|----|---------|---------------------|
| 1 | Tipo de volumen | `t` thin-pool, `T` thin-pool-data, `V` volumen thin, `r` raid, `i` imagen raid, `C` cache, `s` snapshot, `o` origen, `p` pvmove, `-` lineal |
| 2 | Permisos | `w` escribible, `r` solo lectura |
| 3 | Política de asignación | `i` heredada, `c` contigua, `n` normal (mayúscula = bloqueada) |
| 4 | Minor fijo | `m` / `-` |
| 5 | **Estado** | `a` activo, `s` suspendido, `i` inactivo, `d` sin tabla, `-` |
| 6 | Dispositivo abierto | `o` abierto (montado/en uso), `-` |
| 7 | Tipo de target | `t` thin, `r` raid, `C` cache, `s` snapshot, `-` |
| 8 | Recién asignado en ceros | `z` / `-` |
| 9 | **Salud** | `p` parcial (PV faltante), `r` necesita refresh, `m` mismatches encontrados, `F` thin-pool fallido, `D` datos thin perdidos |
| 10 | Omitir activación | `k` / `-` |

`twi-aotz--` = thin-pool, activo, abierto, target thin, con puesta en ceros activada. `Vwi-a-tz--` = volumen thin, activo. `rwi-a-r-p-` en la posición 9 = **un LV RAID con un dispositivo faltante** — esa `p` es tu aviso.

---

## 3. Aprovisionamiento fino (thin) y snapshots thin

### 3.1 Qué hace realmente el target `dm-thin`

Un **thin pool** son dos LVs ocultos presentados como un único target: `_tdata` (los bloques de datos) y `_tmeta` (un árbol B que mapea *(dispositivo-thin, bloque-lógico) → chunk-del-pool*). Un **volumen thin** es un dispositivo que reporta un tamaño virtual grande pero ocupa cero chunks de datos hasta que se escribe; en la primera escritura a un chunk, el pool asigna un **chunk** (por defecto 64 KiB, potencia de dos, 64 KiB–1 GiB) y lo registra en el árbol B de metadatos.

Los **snapshots thin** son la funcionalidad estrella: un snapshot no es más que otro dispositivo thin cuyo árbol B inicialmente *comparte* los mapeos de chunks del origen. Al escribir en el origen o en el snapshot, solo se copia el chunk tocado (redirect-on-write). El costo es O(datos modificados), no O(tamaño del volumen), y — a diferencia de los snapshots clásicos de LVM — **los snapshots de snapshots son gratis y no hay un almacén de excepciones CoW separado que se pueda desbordar**.

### 3.2 Thin vs. thick (clásico) — el compromiso que muerde en producción

| Dimensión | LV thick (lineal) | LV thin (dm-thin) |
|---|---|---|
| Asignación | Anticipada, al crear | Perezosa, en la primera escritura |
| Sobrecompromiso (overcommit) | Imposible | Posible (y peligroso) |
| Costo de snapshot | Almacén CoW dimensionado, por snapshot | Pool compartido, casi cero |
| Cadenas de snapshots | Se degrada rápido | Barato, profundidad arbitraria |
| Falla por pool lleno | N/A | **Todos los LVs thin dan error de I/O o pasan a solo lectura** |
| Ruta de lectura/escritura | Mapeo directo de PE | Búsqueda extra en árbol B + copy-on-write |
| `fstrim`/discard | ¿Libera el VG? No | Devuelve chunks al pool (si `discards=passdown`) |
| Riesgo de metadatos | Mínimo | La corrupción/agotamiento de `_tmeta` pierde todo el pool |
| Ideal para | Volúmenes únicos predecibles y críticos en latencia | Muchos volúmenes, snapshots, almacenamiento de respaldo de VM/contenedores |

**El peligro del overcommit es el hecho operativo más importante de este objetivo.** Si presentás 10×500 GiB de volúmenes thin sobre un pool de 2 TiB y el consumo cruza el 100%, el pool no tiene chunks para entregar. Según `--errorwhenfull`, las escrituras o bien **se encolan durante 60 s y luego dan error** (por defecto, `n`) o bien **fallan de inmediato** (`y`). En cualquier caso, los sistemas de archivos sobre esos LVs thin normalmente se remontan en solo lectura. **No podés hacer aprovisionamiento fino sin extensión automática del pool + monitoreo.**

### 3.3 Construyéndolo — recorrido completo por la CLI con salida real

```console
$ sudo pvcreate /dev/sdb /dev/sdc
  Physical volume "/dev/sdb" successfully created.
  Physical volume "/dev/sdc" successfully created.

$ sudo vgcreate vg_data /dev/sdb /dev/sdc
  Volume group "vg_data" successfully created

# Create the thin pool. Put metadata on a separate PV for durability,
# size metadata deliberately (default heuristics under-size it for snapshot-heavy pools).
$ sudo lvcreate --type thin-pool -L 100G --poolmetadatasize 1G \
      --chunksize 128k --poolmetadataspare y -n tp_data vg_data
  Thin pool volume with chunk size 128.00 KiB can address at most 31.62 TiB of data.
  Logical volume "tp_data" created.

# Present a 500G virtual volume backed by the 100G pool (5x overcommit).
$ sudo lvcreate --thin --virtualsize 500G -n lv_app vg_data/tp_data
  Logical volume "lv_app" created.

$ sudo lvs -a -o name,attr,size,pool_lv,data_percent,metadata_percent,chunksize,devices vg_data
  LV               Attr       LSize   Pool    Data%  Meta%  Chunk   Devices
  lv_app           Vwi-a-tz-- 500.00g tp_data 0.00                  0
  tp_data          twi-aotz-- 100.00g               0.00   0.98    128.00k tp_data_tdata(0)
  [tp_data_tdata]  Twi-ao---- 100.00g                              0       /dev/sdb(1)
  [tp_data_tmeta]  ewi-ao----   1.00g                              0       /dev/sdc(0)
  [lvol0_pmspare]  ewi-------   1.00g                              0       /dev/sdb(0)
```

Fijate en `lvol0_pmspare`: un LV de metadatos de reserva que `thin_repair` usa para restaurar si `_tmeta` se daña. Mantené `--poolmetadataspare y`.

Ahora un **snapshot thin** — instantáneo, sin importar el tamaño del origen:

```console
$ sudo mkfs.xfs /dev/vg_data/lv_app && sudo mount /dev/vg_data/lv_app /srv/app
$ sudo lvcreate -s -n lv_app_snap_0800 vg_data/lv_app
  Logical volume "lv_app_snap_0800" created.

$ sudo lvs -o name,attr,origin,data_percent vg_data
  LV                 Attr       Origin  Data%
  lv_app             Vwi-aotz-- lv_app  1.20
  lv_app_snap_0800   Vwi---tz-k lv_app  1.20
  tp_data            twi-aotz--         1.20
```

El snapshot hereda `-k` (omitir activación en el arranque) por defecto — los snapshots thin están inactivos hasta que hacés `lvchange -ay -K`. Ambos comparten el 1.20% del pool; la divergencia es lo que consume chunks nuevos.

### 3.4 Dimensionar los metadatos — el número que la gente calcula mal

El consumo de metadatos escala con el **número de chunks y número de mapeos** (cada snapshot que diverge agrega mapeos). Un `_tmeta` subdimensionado se llena *antes* que `_tdata`, y un dispositivo de metadatos lleno es una falla más difícil que un dispositivo de datos lleno. Estimá antes de construir:

```console
$ sudo thin_metadata_size --block-size=128k --pool-size=100g --max-thins=1000 -u
thin_metadata_size - 8.14 mebibytes estimated metadata area size ...
# ...but snapshots multiply mappings. For snapshot-heavy pools, size _tmeta generously
# (1–16 GiB); 16 GiB is the hard maximum.
```

Extendé los metadatos en línea cuando se acerquen a su techo:

```console
$ sudo lvextend --poolmetadatasize +512M vg_data/tp_data
  Size of logical volume vg_data/tp_data_tmeta changed from 1.00 GiB to 1.50 GiB.
```

### 3.5 Extensión automática — la configuración que te evita el aviso nocturno

Esto es obligatorio para cualquier thin pool en producción. `dmeventd` monitorea el llenado del pool y ejecuta `lvextend --use-policies` cuando se cruza un umbral.

```ini
# /etc/lvm/lvm.conf  (only the relevant stanzas — do not paste the whole file)

activation {
    # dmeventd extends the pool by <percent> once fill crosses <threshold>%.
    # 100 = disabled. Set both data and (implicitly) metadata to extend at 70%.
    thin_pool_autoextend_threshold = 70
    thin_pool_autoextend_percent   = 20

    # Classic (non-thin) snapshots use the parallel keys:
    snapshot_autoextend_threshold  = 70
    snapshot_autoextend_percent    = 20

    # Register LVs with dmeventd automatically at activation. Without this,
    # autoextend never fires.
    monitoring = 1
}

allocation {
    # "performance" starts chunks at 512 KiB and grows with pool size,
    # trading metadata footprint for fewer CoW operations.
    thin_pool_chunk_size_policy = "generic"
    # Return freed chunks to the pool when the filesystem issues discards.
    # (Also controllable per-pool via lvcreate/lvchange --discards.)
}

global {
    # Offline metadata tooling LVM invokes at activation / repair time.
    thin_check_executable  = "/usr/sbin/thin_check"
    thin_check_options     = [ "-q", "--clear-needs-check-flag" ]
    thin_repair_executable = "/usr/sbin/thin_repair"
    use_lvmpolld = 1
}
```

Verificá que el monitoreo esté realmente activo (un pool silenciosamente no registrado es el clásico post-mortem de «el autoextend no se disparó»):

```console
$ sudo lvs -o name,attr,seg_monitor vg_data
  LV       Attr       Monitor
  lv_app   Vwi-aotz-- not monitored
  tp_data  twi-aotz-- monitored
$ systemctl is-active lvm2-monitor.service
active
```

Establecé el comportamiento ante fallas de forma explícita. Para una base de datos donde un solo-lectura silencioso es peor que un error rápido y ruidoso:

```console
$ sudo lvchange --errorwhenfull y vg_data/tp_data
  Logical volume vg_data/tp_data changed.
```

---

## 4. LVM RAID — redundancia dentro del gestor de volúmenes

### 4.1 El target `dm-raid` y sus sub-LVs

LVM RAID **no** invoca `mdadm`; maneja directamente la misma personalidad `md`/`dm-raid` dentro del kernel. Un LV `raid1` se construye a partir de sub-LVs ocultos emparejados: `_rimage_N` (una pata de datos) y `_rmeta_N` (el superbloque/bitmap RAID de esa pata). Un LV `raid5` tiene N+1 pares rimage/rmeta. Por eso un solo `lvs -a` muestra todo el arreglo *y* cada pata, y por eso podés ubicar las patas en PVs elegidos para controlar el dominio de fallas.

### 4.2 Compromisos de los niveles de RAID

| Nivel | Dispositivos mín. | Utilizable (n datos + p paridad) | Sobrevive | Penalización de escritura | Caso de uso |
|---|---|---|---|---|---|
| `raid0` | 2 | 100% | 0 discos | ninguna (el más rápido) | Datos temporales/reproducibles |
| `raid1` | 2 | 1/espejos | m−1 discos | 2× escritura | SO/arranque, sensible a latencia |
| `raid10` | 4 | 50% | ≥1 por espejo | 2× escritura | Datos de BD — mejor redundancia en escritura aleatoria |
| `raid5` | 3 | (n−1)/n | 1 disco | read-modify-write (4 I/O) | Orientado a capacidad, lectura intensiva |
| `raid6` | 4 | (n−2)/n | 2 discos | 6 I/O por escritura | Arreglos grandes de HDD (reconstrucciones largas) |

### 4.3 LVM RAID vs. mdraid vs. RAID por hardware

| Aspecto | LVM RAID (`dm-raid`) | `mdadm` (`md`) | RAID por hardware |
|---|---|---|---|
| Modelo de gestión | Unificado con volúmenes/snapshots/thin/cache | Capa de arreglo separada bajo LVM | BIOS/CLI opaca (`storcli`) |
| Nivel de RAID por LV | **Sí** — niveles distintos por LV en un mismo VG | No — todo el arreglo | No — todo el LUN de la controladora |
| Reshape/takeover en línea | `lvconvert` (raid1→raid5, agregar stripes) | `mdadm --grow` | Depende del fabricante |
| Scrub / consistencia | `lvchange --syncaction check/repair` | `echo check > .../sync_action` | Programado por la controladora |
| Visibilidad de la reconstrucción | `lvs` Cpy%Sync, `SyncAction` | `/proc/mdstat` | Solo fuera de banda |
| Caché de escritura con batería | No (usá `dm-writecache`) | No | **Sí** (BBU/flash) |
| Portabilidad | Los metadatos viajan con los PVs | Igual | Atado a la familia de controladoras |

**Guía arquitectónica:** para un host de HA de nodo único con discos comunes, LVM RAID te da redundancia por LV, snapshots y caché en un solo modelo de objetos — sin una capa `mdadm` que coordinar. Reservá el RAID por hardware solo donde específicamente necesitás una caché de escritura con batería y podés aceptar el lock-in de la controladora.

### 4.4 Construir y operar un LV RAID5

```console
# -i 3  → 3 data stripes; raid5 adds 1 parity → 4 PVs consumed. -L is USABLE size.
$ sudo lvcreate --type raid5 -i 3 -L 300G -n lv_r5 vg_data
  Using default stripesize 64.00 KiB.
  Logical volume "lv_r5" created.

$ sudo lvs -a -o name,attr,size,segtype,sync_percent,raid_sync_action,region_size,devices vg_data
  LV                Attr       LSize   Type   Cpy%Sync SyncAction Region  Devices
  lv_r5             rwi-a-r--- 300.00g raid5  14.06    idle       2.00m   lv_r5_rimage_0(0),lv_r5_rimage_1(0),...
  [lv_r5_rimage_0]  iwi-aor--- 100.00g linear                            /dev/sdb(1)
  [lv_r5_rmeta_0]   ewi-aor---   4.00m linear                            /dev/sdb(0)
  [lv_r5_rimage_1]  iwi-aor--- 100.00g linear                            /dev/sdc(1)
  ...
```

**Scrubbing** (detectar y, por separado, reparar corrupción silenciosa / discrepancia de paridad). Corré `check` de forma programada; corré `repair` solo cuando sabés qué copia es la autoritativa:

```console
$ sudo lvchange --syncaction check vg_data/lv_r5
$ sudo lvs -o name,raid_sync_action,raid_mismatch_count,sync_percent vg_data/lv_r5
  LV     SyncAction Mismatches Cpy%Sync
  lv_r5  check      0          100.00
# Non-zero Mismatches on raid1/10 means the legs disagree → investigate hardware.
$ sudo lvchange --syncaction repair vg_data/lv_r5
```

**Falla de dispositivo y reparación.** La posición 9 de salud cambia a `p`, `SyncAction`/`Health` muestran el problema:

```console
$ sudo lvs -o name,attr,health_status,raid_sync_action vg_data/lv_r5
  LV     Attr       Health          SyncAction
  lv_r5  rwi-a-r-p- partial         idle
# Replace the dead PV's legs onto a spare PV, rebuild online:
$ sudo lvconvert --repair vg_data/lv_r5
  Faulty devices in vg_data/lv_r5 successfully replaced.
# Or target a specific failing device without waiting for total loss:
$ sudo lvconvert --replace /dev/sdc vg_data/lv_r5 /dev/sde
```

**Takeover / reshape** — convertir un espejo a RAID con paridad, o agregar stripes, en línea:

```console
$ sudo lvconvert --type raid5 vg_data/lv_mirror      # raid1 → raid5 takeover
$ sudo lvconvert --stripes 4 vg_data/lv_r5 /dev/sdf  # reshape: add a data stripe
```

El bitmap de intención de escritura (write-intent) y las perillas de limitación de la reconstrucción importan en arreglos grandes: `--regionsize` (granularidad del bitmap; más grande = menos metadatos, resync más grueso), y `lvchange --minrecoveryrate/--maxrecoveryrate` para acotar el I/O de reconstrucción y que un resync no ahogue a producción.

---

## 5. Tiering: `dm-cache` (lvmcache) vs. `dm-writecache`

### 5.1 Dos targets distintos para dos problemas distintos

- **`dm-cache` (lvmcache):** una caché de puntos calientes. Un dispositivo rápido (NVMe/SSD) va delante de un LV de origen lento; la política `smq` promueve los bloques de acceso frecuente. Cachea **lecturas y escrituras**. Modos: `writethrough` (la escritura impacta en ambos — sobrevive a la pérdida de la caché), `writeback` (escribe en la caché, volcado perezoso — más rápido, **pérdida de caché = pérdida de datos**).
- **`dm-writecache`:** un búfer puro de **escritura**. Cachea *solo* escrituras en un dispositivo rápido, idealmente protegido contra pérdida de energía (NVMe o PMEM), fusionándolas para ocultar la latencia del almacenamiento de respaldo lento. **No** cachea lecturas y no tiene política de expulsión — es una capa para la latencia de escritura, no una caché de puntos calientes.

| Dimensión | `dm-cache` (lvmcache) | `dm-writecache` |
|---|---|---|
| Cachea | Lecturas **y** escrituras | Solo escrituras |
| Política / expulsión | `smq` (promoción de puntos calientes) | Ninguna (volcado FIFO) |
| LV de metadatos | Sí (cache pool: datos+meta) | Mínimo |
| Mejora en latencia de lectura | Sí | No |
| Dispositivo rápido ideal | SSD/NVMe | NVMe / PMEM protegido contra pérdida de energía |
| Pérdida de datos si falla el disco rápido | Solo en `writeback` | Sí (escrituras sin volcar) |
| Ideal para | Conjuntos calientes mixtos de lectura/escritura | Ráfagas de escritura, mucho fsync (WAL de BD, journals) |

### 5.2 Adjuntar una caché — flujo moderno con `--cachevol`

```console
# One fast LV holds both cache data and metadata (simpler than the legacy cache-pool).
$ sudo lvcreate -n cvol_fast -L 32G vg_data /dev/nvme0n1
$ sudo lvconvert --type cache --cachevol cvol_fast \
      --cachemode writethrough vg_data/lv_r5
  Logical volume vg_data/lv_r5 is now cached.

$ sudo lvs -a -o name,attr,size,cache_mode,cache_policy,chunksize vg_data
  LV                Attr       LSize   CacheMode    Policy Chunk
  lv_r5             Cwi-a-C--- 300.00g writethrough smq    128.00k
  [cvol_fast_cvol]  Cwi-aoC---  32.00g
  [lv_r5_corig]     owi-aoC--- 300.00g

# Monitor hit ratio via dmsetup status (read hits / read misses / write hits / write misses):
$ sudo dmsetup status vg_data-lv_r5
0 629145600 cache 8 1024/262144 128 45678/262144 20345 118 88456 3120 0 0 0 1 writethrough 2 migration_threshold 2048 smq 0 rw -

# Flip to writeback once you accept the durability trade-off; detach cleanly to flush:
$ sudo lvchange --cachemode writeback vg_data/lv_r5
$ sudo lvconvert --splitcache vg_data/lv_r5     # flush dirty blocks, keep both LVs
$ sudo lvconvert --uncache vg_data/lv_r5        # flush and DELETE the cache vol
```

### 5.3 Adjuntar un writecache (patrón de journal de BD)

```console
$ sudo lvcreate -n wcache -L 16G vg_data /dev/nvme0n1
$ sudo lvconvert --type writecache --cachevol wcache \
      --cachesettings 'high_watermark=50 low_watermark=45' vg_data/lv_wal
  Logical volume vg_data/lv_wal now has write cache.
$ sudo lvs -o name,attr,segtype vg_data/lv_wal
  LV      Attr       Type
  lv_wal  Cwi-aoC--- writecache
```

---

## 6. Migración de datos en línea: `pvmove`

`pvmove` reubica los extents de uno o más LVs fuera de un PV — para evacuar un disco que está fallando, rebalancear hacia almacenamiento más rápido o drenar un LUN antes de darlo de baja — **con el LV montado y sirviendo I/O**. Construye un espejo temporal, sincroniza y luego cambia el mapeo de forma atómica. `lvmpolld` sigue el progreso, así que sobrevive al cierre de una terminal.

```console
# Evacuate an entire PV (moves every LV segment on /dev/sdb to free space elsewhere):
$ sudo pvmove /dev/sdb
  /dev/sdb: Moved: 0.00%
  /dev/sdb: Moved: 33.41%
  /dev/sdb: Moved: 78.02%
  /dev/sdb: Moved: 100.00%

# Move just one LV, onto a specific destination PV, in the background:
$ sudo pvmove -n lv_app -b /dev/sdb /dev/sdd
$ sudo lvs -o name,move_pv,copy_percent -a vg_data     # watch progress
  LV      Move    Cpy%Sync
  lv_app  /dev/sdb 61.55

# Interrupt-safe: resume or abort a running move
$ sudo pvmove          # resume any in-flight move
$ sudo pvmove --abort  # cancel, leaving data in a consistent place

# Once empty, remove the PV from the VG and wipe its label:
$ sudo vgreduce vg_data /dev/sdb
  Removed "/dev/sdb" from volume group "vg_data"
$ sudo pvremove /dev/sdb
  Labels on physical volume "/dev/sdb" successfully wiped.
```

`pvmove` sobre sub-LVs de thin-pool o cache tiene restricciones; mové todo el pool/origen, y preferí `--atomic` para semántica de todo-o-nada en movimientos de múltiples segmentos.

---

## 7. Manifiestos de infraestructura completos (sin recortar)

### 7.1 Ansible — construcción declarativa de toda la pila

```yaml
---
# playbooks/advanced_lvm.yml — idempotent build of a thin+RAID+cache host
# Requires: community.general collection (lvg, lvol modules)
- name: Provision advanced LVM storage on a single-node HA host
  hosts: storage_nodes
  become: true
  vars:
    vg_name: vg_data
    pvs:
      - /dev/sdb
      - /dev/sdc
      - /dev/sdd
      - /dev/sde
    thin_pool_size: 100g
    thin_pool_meta_size: 1g
    thin_vol_size: 500g          # overcommitted virtual size
  tasks:
    - name: Ensure LVM userspace + dm-persistent tooling present
      ansible.builtin.package:
        name:
          - lvm2
          - device-mapper-persistent-data   # thin_check / cache_check / *_repair
        state: present

    - name: Create the volume group across all PVs
      community.general.lvg:
        vg: "{{ vg_name }}"
        pvs: "{{ pvs | join(',') }}"
        pesize: "4"                          # 4 MiB physical extents

    - name: Create the thin pool with explicit metadata + chunk size
      community.general.lvol:
        vg: "{{ vg_name }}"
        thinpool: tp_data
        size: "{{ thin_pool_size }}"
        opts: >-
          --poolmetadatasize {{ thin_pool_meta_size }}
          --chunksize 128k --poolmetadataspare y

    - name: Create the overcommitted thin volume
      community.general.lvol:
        vg: "{{ vg_name }}"
        lv: lv_app
        thinpool: tp_data
        size: "{{ thin_vol_size }}"

    - name: Fail loudly instead of blocking when the pool fills
      ansible.builtin.command:
        cmd: lvchange --errorwhenfull y {{ vg_name }}/tp_data
      changed_when: false

    - name: Format and mount the thin volume
      ansible.builtin.filesystem:
        fstype: xfs
        dev: "/dev/{{ vg_name }}/lv_app"
    - name: Mount with discard so freed chunks return to the pool
      ansible.posix.mount:
        path: /srv/app
        src: "/dev/{{ vg_name }}/lv_app"
        fstype: xfs
        opts: defaults,discard
        state: mounted

    - name: Enforce autoextend policy in lvm.conf
      ansible.builtin.blockinfile:
        path: /etc/lvm/lvm.conf
        marker: "# {mark} ANSIBLE MANAGED THIN AUTOEXTEND"
        insertafter: '^activation \{'
        block: |
          thin_pool_autoextend_threshold = 70
          thin_pool_autoextend_percent   = 20
          snapshot_autoextend_threshold  = 70
          monitoring = 1
      notify: reload lvm monitor

    - name: Ensure the monitor service is enabled and running
      ansible.builtin.systemd:
        name: lvm2-monitor.service
        enabled: true
        state: started

  handlers:
    - name: reload lvm monitor
      ansible.builtin.command: vgchange --monitor y {{ vg_name }}
      changed_when: false
```

### 7.2 cloud-init — aprovisionar en el primer arranque

```yaml
#cloud-config
# First-boot LVM: thin pool on two attached data disks, autoextend on.
packages:
  - lvm2
  - device-mapper-persistent-data

bootcmd:
  - [ cloud-init-per, once, pvcreate, pvcreate, -y, /dev/vdb, /dev/vdc ]
  - [ cloud-init-per, once, vgcreate, vgcreate, vg_data, /dev/vdb, /dev/vdc ]
  - [ cloud-init-per, once, thinpool, lvcreate, --type, thin-pool, -l, "95%FREE",
      --poolmetadatasize, 1g, --chunksize, 128k, -n, tp_data, vg_data ]
  - [ cloud-init-per, once, thinlv, lvcreate, --thin, --virtualsize, 500G,
      -n, lv_app, vg_data/tp_data ]

write_files:
  - path: /etc/lvm/lvm.conf.d/99-autoextend.conf
    content: |
      activation {
          thin_pool_autoextend_threshold = 70
          thin_pool_autoextend_percent   = 20
          monitoring = 1
      }

runcmd:
  - [ mkfs.xfs, /dev/vg_data/lv_app ]
  - [ systemctl, enable, --now, lvm2-monitor.service ]
```

### 7.3 Unidad de montaje de systemd con un guardián de llenado del pool

```ini
# /etc/systemd/system/srv-app.mount
[Unit]
Description=Application data on thin LV
Requires=lvm2-monitor.service
After=lvm2-monitor.service

[Mount]
What=/dev/vg_data/lv_app
Where=/srv/app
Type=xfs
Options=defaults,discard,nofail

[Install]
WantedBy=multi-user.target
```

```ini
# /etc/systemd/system/thinpool-guard.service — page before the pool wedges
[Unit]
Description=Alert when thin pool crosses 85% data or metadata
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/thinpool_guard.sh vg_data/tp_data 85
```

```ini
# /etc/systemd/system/thinpool-guard.timer
[Unit]
Description=Run thin pool guard every 5 minutes
[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
[Install]
WantedBy=timers.target
```

```bash
#!/usr/bin/env bash
# /usr/local/sbin/thinpool_guard.sh — proportional-to-weight-5.0 vigilance.
set -euo pipefail
pool="$1"; threshold="$2"
read -r data meta < <(lvs --noheadings -o data_percent,metadata_percent "$pool" \
                        | tr -d ' ' | awk -F'|' '{print $1, $2}' OFS=' ' \
                        | awk '{printf "%d %d", $1, $2}')
if (( data >= threshold || meta >= threshold )); then
    logger -p daemon.crit "THINPOOL ${pool} at data=${data}% meta=${meta}% (>=${threshold}%)"
    exit 2
fi
```

---

## 8. Verificación y diagnóstico de fallas

### 8.1 La consulta de salud permanente

Corré esto antes de creer que algún almacenamiento está sano. Expone llenado, sincronización y salud en una línea cada uno:

```console
$ sudo lvs -a -o name,attr,size,pool_lv,data_percent,metadata_percent,\
copy_percent,raid_sync_action,health_status,seg_monitor
  LV               Attr       LSize   Pool    Data% Meta% Cpy%Sync SyncAction Health  Monitor
  lv_app           Vwi-aotz-- 500.00g tp_data 62.10                                   
  lv_r5            rwi-a-r--- 300.00g               100.00   idle              monitored
  tp_data          twi-aotz-- 100.00g         62.10 3.44                              monitored
```

Contrastá con la vista del kernel cuando algo se ve raro:

```console
$ sudo dmsetup status                # per-target live state
$ sudo dmsetup info -c               # open counts, suspended flags
$ sudo journalctl -k | grep -Ei 'dm-thin|dm-cache|dm-raid|device-mapper'
```

### 8.2 Guías de actuación ante fallas

**A) Datos del thin pool al 100%.** Síntoma: los LVs thin se remontan en solo lectura o lanzan `EIO`; `lvs` muestra `Data% 100.00`, `lv_attr` pos-9 `F` si el pool mismo falló.
```console
# 1. Fastest mitigation — extend the pool from free VG space:
$ sudo lvextend -L +50G vg_data/tp_data
# 2. No free space? Add a PV first, then extend:
$ sudo vgextend vg_data /dev/sdf && sudo lvextend -L +50G vg_data/tp_data
# 3. Reclaim from the filesystem side:
$ sudo fstrim -v /srv/app
# 4. If the pool is flagged needs_check, LVM ran thin_check at activation;
#    force-activate and inspect:
$ sudo lvchange -ay vg_data/tp_data
$ sudo journalctl -u lvm2-monitor -n 50
```

**B) Metadatos thin llenos o corruptos** (más difícil que datos llenos). `Meta% 100.00`, o la activación se niega con una bandera `needs_check`.
```console
# Deactivate, dump/repair metadata into the spare using the persistent-data tools:
$ sudo lvchange -an vg_data/tp_data
$ sudo lvconvert --repair vg_data/tp_data        # invokes thin_repair into pmspare
# Manual inspection when you distrust the automatic repair:
$ sudo thin_dump /dev/mapper/vg_data-tp_data_tmeta | less
$ sudo thin_check /dev/mapper/vg_data-tp_data_tmeta
```

**C) LV RAID degradado / PV faltante.** `lv_attr` pos-9 `p` (parcial), `Health = partial`.
```console
$ sudo vgs -o vg_name,pv_count,vg_missing_pv_count vg_data
$ sudo lvconvert --repair vg_data/lv_r5          # rebuild onto spare PVs
$ sudo lvs -o name,copy_percent,raid_sync_action vg_data/lv_r5   # watch resync
# If a PV was only transiently absent (SAN blip), refresh instead of rebuild:
$ sudo lvchange --refresh vg_data/lv_r5
```

**D) Metadatos de todo el VG dañados.** Restaurá desde el archivo de texto que LVM escribe en cada cambio:
```console
$ sudo ls -t /etc/lvm/archive/vg_data_*.vg | head
$ sudo vgcfgrestore -l vg_data                   # list restore points
$ sudo vgcfgrestore -f /etc/lvm/archive/vg_data_00042-....vg vg_data
```

**E) Un PV reaparece con metadatos obsoletos / UUID duplicado** (disco clonado, restauración de snapshot):
```console
$ sudo pvs -o pv_name,pv_uuid,vg_name              # spot the duplicate UUID
$ sudo vgimportclone --basevgname vg_data_clone /dev/sdX   # re-stamp the clone
# Scope which devices LVM scans to avoid the ambiguity entirely:
#   /etc/lvm/lvm.conf → devices { filter = [ "a|/dev/sd[b-e]|", "r|.*|" ] }
$ sudo pvscan --cache        # refresh the udev/lvmetad-style scan cache
```

### 8.3 Verificaciones de aceptación tras un cambio

Después de cualquier `lvextend`/`lvconvert`/`pvmove`, probá el resultado — no lo asumas:

```console
$ sudo vgcfgbackup && echo "metadata backed up to /etc/lvm/backup/"
$ sudo lvs -a -o +devices vg_data          # confirm segment placement
$ df -h /srv/app                            # confirm the filesystem saw the growth
$ sudo xfs_growfs /srv/app                  # xfs: grow FS after lvextend (ext4: resize2fs)
$ sudo lvchange --syncaction check vg_data/lv_r5   # RAID: re-verify consistency
```

`lvextend -r` (`--resizefs`) hace crecer el LV **y** el sistema de archivos de forma atómica, y es el valor por defecto más seguro para la expansión en línea:

```console
$ sudo lvextend -r -L +20G vg_data/lv_app
  Size of logical volume vg_data/lv_app changed from 500.00 GiB to 520.00 GiB.
  meta-data=/dev/mapper/vg_data-lv_app ... data blocks changed ...
```

---

## 9. Referencias

- LPI — *Objetivos del examen LPIC-3 306 (306-300, v3.0)*: https://www.lpi.org/our-certifications/exam-306-objectives/
- `lvmthin(7)` — aprovisionamiento fino y snapshots thin: https://man7.org/linux/man-pages/man7/lvmthin.7.html
- `lvmraid(7)` — tipos de LVM RAID, scrubbing, reparación, reshape: https://man7.org/linux/man-pages/man7/lvmraid.7.html
- `lvmcache(7)` — adjunción de dm-cache y dm-writecache: https://man7.org/linux/man-pages/man7/lvmcache.7.html
- `lvm.conf(5)` — claves de configuración (`activation`, `allocation`, `global`): https://man7.org/linux/man-pages/man5/lvm.conf.5.html
- `pvmove(8)` — migración de extents en línea: https://man7.org/linux/man-pages/man8/pvmove.8.html
- `lvconvert(8)` / `lvcreate(8)` / `lvextend(8)`: https://man7.org/linux/man-pages/man8/lvconvert.8.html
- Kernel de Linux — target de aprovisionamiento fino de Device Mapper: https://docs.kernel.org/admin-guide/device-mapper/thin-provisioning.html
- Kernel de Linux — target dm-cache: https://docs.kernel.org/admin-guide/device-mapper/cache.html
- Kernel de Linux — target dm-writecache: https://docs.kernel.org/admin-guide/device-mapper/writecache.html
- Kernel de Linux — target dm-raid: https://docs.kernel.org/admin-guide/device-mapper/dm-raid.html
- Proyecto LVM2 (fuentes, formato de metadatos, herramientas persistent-data): https://sourceware.org/lvm2/
- Red Hat — *Configuring and managing logical volumes* (RHEL 9): https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/configuring_and_managing_logical_volumes/index
- `thin_check(8)` / `thin_repair(8)` / `cache_check(8)` (device-mapper-persistent-data): https://man7.org/linux/man-pages/man8/thin_check.8.html