# 364.3 LVM avanzado — Ejercicios guiados

> **Objetivo de examen 364.3 — LVM avanzado (peso 5).** Estos ejercicios ejercitan las habilidades operativas que enumera el objetivo: LVM RAID (niveles 0/1/4/5/6/10), integridad de RAID y reparación automática, la relación con `mdadm`/`dmraid`, thin provisioning, thin snapshots y LVM cache — además de los reflejos de diagnóstico que necesitás cuando cualquiera de ellos se degrada.
>
> **Seguridad.** Ejecutá todo sobre **dispositivos loop**, nunca sobre un disco que contenga datos. Cada comando que muta estado lleva el prefijo `sudo`. Las salidas esperadas son **ilustrativas** — los UUID, números de loop, cantidades de extents y porcentajes diferirán en tu máquina. Confirmá la *forma* de la salida, no los dígitos exactos.
>
> **Prerrequisitos.** Un host Linux con `lvm2` instalado y los módulos de kernel `dm-raid`, `dm-integrity`, `dm-thin-pool` y `dm-cache` disponibles (se cargan bajo demanda). Verificalo con `sudo modinfo dm-raid dm-integrity >/dev/null && echo ok`.

---

## Ejercicio 0 — Construir un almacenamiento de respaldo desechable

Necesitás varios "discos" independientes. Los fabricamos a partir de archivos dispersos (sparse) asociados a dispositivos loop.

**Pasos**

1. Creá seis archivos de imagen dispersos de 1 GiB:

   ```bash
   for i in 1 2 3 4 5 6; do
     truncate -s 1G /var/tmp/lvmlab-pv$i.img
   done
   ```

2. Asociá cada uno a un dispositivo loop e imprimí el nodo asignado:

   ```bash
   for i in 1 2 3 4 5 6; do
     sudo losetup --find --show /var/tmp/lvmlab-pv$i.img
   done
   ```

   ```
   /dev/loop0
   /dev/loop1
   /dev/loop2
   /dev/loop3
   /dev/loop4
   /dev/loop5
   ```

3. Confirmá el mapeo (los números en **tu** sistema pueden diferir — siempre volvé a verificarlos acá antes de copiar y pegar comandos posteriores):

   ```bash
   losetup -a | grep lvmlab
   ```

   ```
   /dev/loop0: [...] (/var/tmp/lvmlab-pv1.img)
   /dev/loop1: [...] (/var/tmp/lvmlab-pv2.img)
   ...
   ```

> A lo largo de todo, sustituí los nodos loop que efectivamente obtuviste. El texto asume `/dev/loop0`–`/dev/loop5`.

**Verificá tu comprensión**

- **Q1.** ¿Por qué `truncate -s 1G` retorna al instante y consume casi nada de disco, y qué riesgo crea esa dispersión (sparseness) si más adelante llenás un thin pool de LVM construido encima?
- **Q2.** Un dispositivo loop es un dispositivo de bloques respaldado por un archivo. ¿Qué capa de la pila de LVM (PV, VG, LV) vas a colocar directamente sobre `/dev/loop0`?

---

## Ejercicio 1 — Las tres capas: PV → VG → LV

Antes de cualquier cosa "avanzada", afianzá el vocabulario base que la herramienta te devuelve.

**Pasos**

1. Inicializá cuatro dispositivos loop como **physical volumes**:

   ```bash
   sudo pvcreate /dev/loop0 /dev/loop1 /dev/loop2 /dev/loop3
   ```

   ```
   Physical volume "/dev/loop0" successfully created.
   ...
   ```

2. Creá un **volume group** `vg_lab` a partir de ellos:

   ```bash
   sudo vgcreate vg_lab /dev/loop0 /dev/loop1 /dev/loop2 /dev/loop3
   ```

   ```
   Volume group "vg_lab" successfully created
   ```

3. Inspeccioná las tres capas con los reporteros de resumen:

   ```bash
   sudo pvs
   sudo vgs
   sudo lvs
   ```

   ```
     PV         VG      Fmt  Attr PSize   PFree
     /dev/loop0 vg_lab  lvm2 a--  1020.00m 1020.00m
     ...
     VG      #PV #LV #SN Attr   VSize  VFree
     vg_lab    4   0   0 wz--n- <3.98g <3.98g
   ```

4. Mirá el tamaño del physical extent (PE) — el cuanto de asignación del que LVM talla todo:

   ```bash
   sudo vgdisplay vg_lab | grep -E 'PE Size|Total PE|Free  PE'
   ```

   ```
     PE Size               4.00 MiB
     Total PE              1020
     Free  PE / Size       1020 / <3.98 GiB
   ```

5. Creá un logical volume **lineal** simple para tener una base con la que contrastar RAID:

   ```bash
   sudo lvcreate -L 400M -n lv_linear vg_lab
   sudo lvs -o name,size,segtype,devices vg_lab
   ```

   ```
     LV        LSize   Type   Devices
     lv_linear 400.00m linear /dev/loop0(0)
   ```

**Verificá tu comprensión**

- **Q3.** A partir del paso 4, ¿cuántos extents de 4 MiB consume un logical volume de 400 MiB, y por qué el tamaño del LV es siempre un múltiplo del tamaño del PE?
- **Q4.** En `pvs`, el campo `Attr` muestra `a--`. ¿Qué significa la primera `a`, y qué dos condiciones deben cumplirse para que un LV sea datos utilizables?
- **Q5.** El `segtype` de `lv_linear` es `linear`, mapeado a un único PV. ¿A qué campo del reporte de un solo comando vas a volver una y otra vez en cada ejercicio posterior para ver *cómo* está dispuesto un LV a lo largo de los dispositivos?

---

## Ejercicio 2 — LVM RAID: un espejo redundante (raid1)

LVM RAID no delega en `mdadm`. Maneja el target de device-mapper del kernel **`dm-raid`**, que a su vez reutiliza las *personalidades* de MD RAID (`raid1`, `raid456`, `raid10`). El array se describe enteramente mediante metadatos de LVM, no por un superbloque de MD.

**Pasos**

1. Creá un espejo de dos copias (`-m 1` = 1 imagen de espejo adicional = 2 imágenes en total):

   ```bash
   sudo lvcreate --type raid1 -m 1 -L 300M -n lv_mirror vg_lab
   ```

   ```
     Logical volume "lv_mirror" created.
   ```

2. Revelá los sub-LV ocultos que componen el LV de RAID:

   ```bash
   sudo lvs -a -o name,segtype,sync_percent,devices vg_lab
   ```

   ```
     LV                    Type   Cpy%Sync Devices
     lv_mirror             raid1  100.00   lv_mirror_rimage_0(0),lv_mirror_rimage_1(0)
     [lv_mirror_rimage_0]  linear          /dev/loop0(100)
     [lv_mirror_rimage_1]  linear          /dev/loop1(100)
     [lv_mirror_rmeta_0]   linear          /dev/loop0(0)
     [lv_mirror_rmeta_1]   linear          /dev/loop1(0)
   ```

3. Notá los dos roles estructurales: `_rimage_N` contiene la copia de datos; `_rmeta_N` contiene los pequeños metadatos de RAID (bitmap de qué regiones están sincronizadas). Observá completarse una resincronización:

   ```bash
   sudo lvs -o name,sync_percent,raid_sync_action,lv_health_status -a vg_lab/lv_mirror
   ```

4. **Simulá un reemplazo de dispositivo.** `/dev/loop4` todavía está libre en el VG. Primero extendé el VG para que exista un repuesto, luego intercambiá una pata del espejo hacia él:

   ```bash
   sudo vgextend vg_lab /dev/loop4
   sudo lvconvert --replace /dev/loop1 vg_lab/lv_mirror /dev/loop4
   sudo lvs -a -o name,devices vg_lab/lv_mirror
   ```

   ```
     [lv_mirror_rimage_1]  ...  /dev/loop4(1)
   ```

5. **Entendé el camino de falla real.** Cuando un PV muere de verdad, la cadena de atributos del LV muestra una `p` (partial) en el campo de salud y `lvs` lo reporta bajo `lv_health_status`. El comando de recuperación es:

   ```bash
   # Only run against a genuinely failed device:
   sudo lvconvert --repair vg_lab/lv_mirror
   ```

**Verificá tu comprensión**

- **Q6.** Un LV `raid1` con `-m 1` sobre dos patas de 300 MiB — ¿cuánta capacidad *utilizable* presenta, y cuánto espacio bruto del VG consumió (ignorando los diminutos `_rmeta`)?
- **Q7.** ¿Cuál es la diferencia funcional entre `lvconvert --replace` (paso 4) y `lvconvert --repair` (paso 5)? ¿Cuándo es cada uno la herramienta correcta?
- **Q8.** ¿Por qué la línea `raid1` muestra `Cpy%Sync 100.00` mientras que los sub-LV `_rimage`/`_rmeta` no muestran nada en esa columna?

---

## Ejercicio 3 — Striping y paridad: raid0, raid5, raid6, raid10

El objetivo menciona explícitamente los niveles 0, 1, 4, 5, 6 y 10. El flag `-i` (stripes) controla la cantidad de dispositivos de **datos**; los dispositivos de paridad/espejo se agregan automáticamente según el nivel.

**Pasos**

1. Limpiá el LV anterior para que los extents queden libres:

   ```bash
   sudo lvremove -y vg_lab/lv_mirror
   ```

2. Creá un LV **raid5** con 3 stripes de datos (necesita 3 + 1 de paridad = 4 PVs):

   ```bash
   sudo lvcreate --type raid5 -i 3 -L 300M -n lv_r5 vg_lab
   sudo lvs -a -o name,segtype,stripes,devices vg_lab/lv_r5
   ```

   ```
     LV       Type  #Str Devices
     lv_r5    raid5    4  lv_r5_rimage_0(0),lv_r5_rimage_1(0),lv_r5_rimage_2(0),lv_r5_rimage_3(0)
   ```

   Notá `#Str` = 4: tres de datos + una paridad distribuida. `-i` cuenta solo los stripes de **datos**.

3. Contrastá la geometría entre niveles (ejecutá cada uno, inspeccioná, luego remové antes del siguiente para mantenerte dentro de cuatro PVs — o remové `lv_r5` primero si querés construir raid10):

   | Nivel | Comando | PVs requeridos | Sobrevive |
   |------|---------|--------------|----------|
   | raid0 | `lvcreate --type raid0 -i 3 -L 300M -n lv_r0 vg_lab` | 3 | sin redundancia (solo striping) |
   | raid5 | `lvcreate --type raid5 -i 3 -L 300M -n lv_r5 vg_lab` | 4 | 1 dispositivo |
   | raid6 | `lvcreate --type raid6 -i 3 -L 300M -n lv_r6 vg_lab` | 5 | 2 dispositivos |
   | raid10 | `lvcreate --type raid10 -i 2 -m 1 -L 300M -n lv_r10 vg_lab` | 4 | 1 por par de espejo |

4. **Escrubeá** (scrub) un array redundante — leé cada bloque, recalculá la paridad y contá las discrepancias sin corregirlas todavía:

   ```bash
   sudo lvchange --syncaction check vg_lab/lv_r5
   sudo lvs -o name,raid_sync_action,raid_mismatch_count vg_lab/lv_r5
   ```

   ```
     LV     SyncAction Mismatches
     lv_r5  idle                0
   ```

5. Si un scrub reporta discrepancias, ejecutá una pasada correctiva:

   ```bash
   sudo lvchange --syncaction repair vg_lab/lv_r5
   ```

**Verificá tu comprensión**

- **Q9.** Para `raid5 -i 3` proporcionaste `-L 300M`. ¿300 MiB es el tamaño *utilizable* o el tamaño *bruto*, y aproximadamente cuánto espacio bruto del VG se consume?
- **Q10.** ¿Por qué raid6 necesita al menos cinco dispositivos para `-i 3`, y qué escenario de falla justifica su bloque de paridad extra sobre raid5?
- **Q11.** ¿Cuál es la diferencia entre `--syncaction check` y `--syncaction repair`, y por qué elegirías `check` primero?

---

## Ejercicio 4 — Integridad de RAID y reparación automática (`--raidintegrity`)

El RAID simple detecta un dispositivo *ausente*, pero no la corrupción silenciosa de datos (bit rot) en un dispositivo que sigue en línea — un scrub solo te dice que existe una discrepancia, no *cuál* copia está mal. `--raidintegrity` coloca **`dm-integrity`** debajo de cada imagen de RAID, almacenando un checksum por bloque. En una lectura, un checksum fallido se trata como un error de lectura, así que la capa de RAID reconstruye el bloque a partir de una copia buena y **lo reescribe — reparación automática.**

**Pasos**

1. Remové cualquier LV residual para liberar extents, luego creá un espejo con integridad habilitada:

   ```bash
   sudo lvcreate --type raid1 -m 1 --raidintegrity y -L 200M -n lv_int vg_lab
   sudo lvs -a -o name,segtype,devices vg_lab/lv_int
   ```

   ```
     LV                       Type       Devices
     lv_int                   raid1
     [lv_int_rimage_0]        integrity  lv_int_rimage_0_iorig(0)
     [lv_int_rimage_0_imeta]  linear     /dev/loop0(...)
     [lv_int_rimage_0_iorig]  linear     /dev/loop0(...)
     [lv_int_rimage_1]        integrity  lv_int_rimage_1_iorig(0)
     ...
   ```

   Cada `_rimage_N` es ahora un dispositivo `integrity` que envuelve los datos reales (`_iorig`) más un área de checksum (`_imeta`).

2. Elegí el **modo de journaling** de integridad. El default es `bitmap` (rápido, rastrea regiones sucias); `journal` está completamente journaled a nivel de datos (más seguro ante un crash, más lento):

   ```bash
   sudo lvs -a -o name,integritymismatches,raidintegritymode vg_lab/lv_int 2>/dev/null || \
   sudo lvs -a -o name,integritymismatches vg_lab/lv_int
   ```

3. Convertí integridad **sobre un** LV de RAID **existente**, o quitala nuevamente, sin recrearlo:

   ```bash
   # Add integrity to an existing raid LV:
   #   sudo lvconvert --raidintegrity y vg_lab/<some_raid_lv>
   # Remove it:
   #   sudo lvconvert --raidintegrity n vg_lab/lv_int
   ```

4. Disparé un scrub y leé el contador de discrepancias de integridad — la cuenta de bloques cuyo checksum falló y fueron reparados desde la copia redundante:

   ```bash
   sudo lvchange --syncaction check vg_lab/lv_int
   sudo lvs -o name,integritymismatches vg_lab/lv_int
   ```

   ```
     LV      IntegMismatches
     lv_int                0
   ```

**Verificá tu comprensión**

- **Q12.** El scrub de `raid1` simple ya reporta discrepancias. ¿Qué puede hacer `--raidintegrity` que un scrub de RAID simple fundamentalmente no puede, y por qué el checksum por bloque es la clave?
- **Q13.** ¿Por qué `--raidintegrity` solo está disponible en tipos de RAID **redundantes** (raid1/4/5/6/10) y no en raid0 ni en un LV lineal?
- **Q14.** Contrastá `--raidintegritymode bitmap` vs `journal`. ¿Cuál protege datos escritos momentos antes de una pérdida de energía, y qué cuesta?

---

## Ejercicio 5 — LVM RAID vs `mdadm` vs `dmraid`

Estos tres tocan RAID pero **no** son intercambiables. Este ejercicio es observacional — vas a confirmar dónde vive realmente LVM RAID en el kernel.

**Pasos**

1. Confirmá los módulos de kernel que los LV de LVM RAID trajeron:

   ```bash
   lsmod | grep -E 'raid1|raid456|raid10|dm_raid|dm_integrity'
   ```

   ```
   dm_raid                ...
   raid456                ...
   raid1                  ...
   ...
   ```

   Las personalidades `raid1`/`raid456` son el **mismo código** que usa `mdadm`. `dm_raid` es el envoltorio de device-mapper que le permite a LVM manejarlas.

2. Ahora revisá `/proc/mdstat` — el clásico archivo de estado de `mdadm`:

   ```bash
   cat /proc/mdstat
   ```

   ```
   Personalities : [raid1] [raid6] [raid5] [raid4]
   unused devices: <none>
   ```

   Tus LV de LVM RAID están **ausentes** acá, aunque las personalidades estén cargadas. Los arrays de LVM RAID son dispositivos de device-mapper, no arrays de `md` — no tienen nodo `/dev/mdN` ni superbloque de MD.

3. Mirá dónde *sí* aparecen — la tabla de device-mapper:

   ```bash
   sudo dmsetup ls --target raid
   sudo dmsetup status vg_lab-lv_int
   ```

4. Fijá el modelo mental con una tabla:

   | Herramienta | Qué gestiona | Formato de metadatos | Fuente de estado |
   |------|-----------------|-----------------|---------------|
   | `mdadm` | Arrays nativos de Linux MD (`/dev/md*`) | Superbloque de MD en disco | `/proc/mdstat`, `mdadm --detail` |
   | **LVM RAID** | RAID *dentro* de un LV vía `dm-raid` | Metadatos de LVM (VG) | `lvs -a`, `dmsetup status` |
   | `dmraid` | **"Fake RAID" de firmware/BIOS** (Intel IMSM, etc.) | formato en disco del fabricante | `dmraid -s` (legacy; en gran medida reemplazado por `mdadm`) |

**Verificá tu comprensión**

- **Q15.** LVM RAID y `mdadm` cargan las *mismas* personalidades de kernel, y sin embargo `/proc/mdstat` no muestra nada para tu espejo de LVM. ¿Por qué — dónde almacena cada uno su definición de array?
- **Q16.** Un colega enchufa un disco de una máquina que usaba "RAID" de motherboard. ¿Cuál de las tres herramientas fue diseñada históricamente para ensamblar eso, y por qué es una categoría distinta de las otras dos?
- **Q17.** Dados los mismos dos discos, nombrá una ventaja operativa de construir un `raid1` **a través de LVM** en lugar de construir un dispositivo `md` con `mdadm` y ponerle un PV encima.

---

## Ejercicio 6 — Thin provisioning (thin pool + thin volumes)

Un thin pool asigna bloques **en la escritura**, así que la suma de los tamaños virtuales de los thin volumes puede exceder el tamaño físico del pool (over-provisioning). El pool rastrea dos recursos separados que debés monitorear: **data** y **metadata**.

**Pasos**

1. Liberá extents de LV anteriores si hace falta, luego creá un thin **pool** de 500 MiB:

   ```bash
   sudo lvcreate -L 500M --thinpool tpool vg_lab
   sudo lvs -a -o name,segtype,size,data_percent,metadata_percent vg_lab
   ```

   ```
     LV               Type       LSize   Data%  Meta%
     tpool            thin-pool  500.00m 0.00   10.02
     [tpool_tdata]    linear     500.00m
     [tpool_tmeta]    linear       ...
   ```

   Notá los sub-LV ocultos `_tdata` (almacén de bloques) y `_tmeta` (mapa de direcciones de bloques).

2. Creá dos thin volumes, cada uno con un **tamaño virtual mayor que el pool** — over-provisioning deliberado:

   ```bash
   sudo lvcreate -V 800M --thin -n thin_a vg_lab/tpool
   sudo lvcreate -V 800M --thin -n thin_b vg_lab/tpool
   sudo lvs -o name,size,pool_lv,data_percent vg_lab
   ```

   ```
     LV     LSize   Pool  Data%
     thin_a 800.00m tpool 0.00
     thin_b 800.00m tpool 0.00
     tpool  500.00m       0.00
   ```

   Dos volúmenes de 800 MiB anuncian 1.6 GiB desde un pool de 500 MiB.

3. Escribí datos reales en un thin volume y observá subir el `Data%` del **pool** (el pool se llena, no el tamaño anunciado del volumen individual):

   ```bash
   sudo mkfs.ext4 /dev/vg_lab/thin_a
   sudo mkdir -p /mnt/thin_a && sudo mount /dev/vg_lab/thin_a /mnt/thin_a
   sudo dd if=/dev/zero of=/mnt/thin_a/fill bs=1M count=200 conv=fsync
   sudo lvs -o name,data_percent,metadata_percent vg_lab/tpool
   ```

   ```
     LV    Data%  Meta%
     tpool 40.xx  10.xx
   ```

4. Inspeccioná la **válvula de seguridad de autoextensión** en la configuración — el pool puede crecer solo antes de llenarse:

   ```bash
   sudo lvmconfig --type default activation/thin_pool_autoextend_threshold \
                                 activation/thin_pool_autoextend_percent
   grep -nE 'thin_pool_autoextend' /etc/lvm/lvm.conf
   ```

   ```
   activation/thin_pool_autoextend_threshold=70
   activation/thin_pool_autoextend_percent=20
   ```

   Con un umbral de 70, una vez que el pool cruza el 70 % de ocupación, `lvm` (vía `dmeventd`) lo hace crecer un 20 %.

**Verificá tu comprensión**

- **Q18.** Tenés dos thin volumes de 800 MiB sobre un pool de 500 MiB. ¿Qué les pasa a las escrituras cuando el `Data%` del *pool* alcanza el 100 % — y qué experimenta un filesystem sobre `thin_b` aunque `thin_b` parezca 90 % vacío?
- **Q19.** El pool tiene tanto `Data%` como `Meta%`. ¿Por qué quedarse sin **metadata** es al menos tan peligroso como quedarse sin espacio de data, y cuál es el síntoma de la falla?
- **Q20.** Con `thin_pool_autoextend_threshold = 100`, la autoextensión está efectivamente deshabilitada. ¿Por qué la documentación de LVM advierte contra dejarlo en 100 en un pool over-provisioned, y qué daemon debe estar corriendo para que la autoextensión se dispare?

---

## Ejercicio 7 — Thin snapshots vs snapshots clásicos

Un snapshot clásico (thick) necesita un área de copy-on-write predimensionada y se degrada a medida que se llena. Un **thin snapshot** vive en el mismo pool que su origen, comparte bloques sin modificar, no necesita argumento de tamaño, y puede a su vez ser snapshoteado.

**Pasos**

1. Tomá un **thin snapshot** de `thin_a` (sin `-L` — extrae del pool bajo demanda):

   ```bash
   sudo lvcreate --snapshot --name thin_a_snap vg_lab/thin_a
   sudo lvs -o name,origin,pool_lv,lv_attr vg_lab
   ```

   ```
     LV          Origin Pool  Attr
     thin_a      thin_a tpool Vwi-aotz--
     thin_a_snap thin_a tpool Vwi---tz-k
   ```

   Notá que el attr del snapshot termina en `k` — **skip activation**. Los thin snapshots se crean inactivos por default.

2. Activalo explícitamente, sobrescribiendo el flag de skip con `-K`:

   ```bash
   sudo lvchange -ay -K vg_lab/thin_a_snap
   sudo lvs -o name,lv_attr vg_lab/thin_a_snap
   ```

   ```
     LV          Attr
     thin_a_snap Vwi-a-tz--
   ```

3. Probá que el snapshot es independiente — montalo de solo lectura y confirmá que contiene los datos del origen al momento del snapshot, luego seguí escribiendo al origen:

   ```bash
   sudo mkdir -p /mnt/snap && sudo mount -o ro /dev/vg_lab/thin_a_snap /mnt/snap
   ls -l /mnt/snap/fill
   sudo dd if=/dev/zero of=/mnt/thin_a/more bs=1M count=50 conv=fsync
   sudo lvs -o name,data_percent vg_lab/tpool
   ```

4. Contrastá con un snapshot **clásico** sobre un LV thick. Este *requiere* un tamaño y vive fuera de cualquier pool:

   ```bash
   sudo lvcreate -L 100M -s -n lin_snap vg_lab/lv_linear
   sudo lvs -o name,origin,lv_size,data_percent vg_lab/lin_snap
   ```

   ```
     LV       Origin    LSize   Data%
     lin_snap lv_linear 100.00m 0.00
   ```

   Si las escrituras a `lv_linear` desbordan esta área CoW de 100 MiB, el snapshot clásico es **descartado (invalidado)**.

**Verificá tu comprensión**

- **Q21.** ¿Por qué un thin snapshot **no** toma argumento de tamaño mientras que un snapshot clásico exige `-L`, y de dónde vienen los bloques modificados de un thin snapshot?
- **Q22.** ¿Cuál es la consecuencia práctica del atributo `k` (skip-activation) en un thin snapshot, y qué flag lo reactiva?
- **Q23.** Un snapshot clásico se vuelve silenciosamente "Invalid" bajo escrituras intensas al origen. ¿Qué recurso del thin pool juega el rol análogo de "quedarse seco" para los thin snapshots, y cómo lo observás?

---

## Ejercicio 8 — LVM cache (dispositivo rápido al frente de un LV lento)

LVM cache coloca los bloques calientes (hot) de un LV "origen" lento sobre un dispositivo rápido (SSD/NVMe). Simulamos el dispositivo rápido con `/dev/loop5` (fingí que es un SSD).

**Pasos**

1. Asegurate de que `/dev/loop5` sea un PV en el VG (agregalo si no lo es):

   ```bash
   sudo vgextend vg_lab /dev/loop5 2>/dev/null; sudo pvs -o pv_name,vg_name /dev/loop5
   ```

2. **Cache en un solo paso con un cache volume** (`--cachevol`, la forma moderna). Adjuntá un cache rápido de 300 MiB a `lv_linear`:

   ```bash
   sudo lvcreate -L 300M -n fastcache vg_lab /dev/loop5
   sudo lvconvert --type cache --cachevol fastcache vg_lab/lv_linear
   sudo lvs -a -o name,segtype,cachemode,devices vg_lab/lv_linear
   ```

   ```
     LV        Type  CacheMode    Devices
     lv_linear cache writethrough lv_linear_corig(0)
   ```

3. Leé las estadísticas del cache en vivo (hits, misses, bloques sucios) desde device-mapper:

   ```bash
   sudo dmsetup status vg_lab-lv_linear
   ```

   ```
   0 819200 cache 8 74/1024 128 ... <read_hits> <read_misses> <write_hits> <write_misses> ... writethrough ...
   ```

4. **Cambiá el modo de cache** a `writeback` (reconoce las escrituras una vez que llegan al cache — más rápido, pero los datos están en riesgo si el dispositivo de cache muere antes de vaciarse):

   ```bash
   sudo lvchange --cachemode writeback vg_lab/lv_linear
   sudo lvs -o name,cachemode vg_lab/lv_linear
   ```

   ```
     LV        CacheMode
     lv_linear writeback
   ```

5. **Desadjuntá el cache limpiamente.** `--uncache` vacía los bloques sucios de vuelta al origen, luego remueve el cache:

   ```bash
   sudo lvconvert --uncache vg_lab/lv_linear
   sudo lvs -o name,segtype vg_lab/lv_linear
   ```

   ```
     LV        Type
     lv_linear linear
   ```

6. *(Referencia)* La forma más antigua de dos objetos usa un **cache pool** (un LV de datos rápido + un LV de metadata separado) adjuntado con `--cachepool`:

   ```bash
   # sudo lvcreate --type cache-pool -L 300M -n cpool vg_lab /dev/loop5
   # sudo lvconvert --type cache --cachepool vg_lab/cpool vg_lab/lv_linear
   ```

**Verificá tu comprensión**

- **Q24.** ¿Cuál es la diferencia entre `--cachevol` y `--cachepool`, y cuál mantiene la metadata del cache en un LV oculto *separado*?
- **Q25.** Bajo `writethrough`, ¿se pierde algún dato si el dispositivo de cache falla por completo? Respondé lo mismo para `writeback`, y explicá la diferencia de reconocimiento (acknowledgement) que lo causa.
- **Q26.** ¿Por qué `lvconvert --uncache` es el desmontaje correcto para un cache `writeback` en lugar de solo un `lvremove` sobre el cache volume, y qué vacía?

---

## Ejercicio 9 — Diagnósticos, reflejos de reparación y teardown

La única cadena de reporte que deberías poder escribir de memoria, más los caminos de reparación para un thin pool corrupto — y luego limpiá todo por completo.

**Pasos**

1. El one-liner "todo sobre disposición y salud":

   ```bash
   sudo lvs -a -o +devices,segtype,sync_percent,raid_sync_action,lv_health_status,data_percent,metadata_percent vg_lab
   ```

2. Decodificá una cadena de atributos de LV. Para un thin volume `Vwi-aotz--`, recorré las posiciones: `V`=thin volume, `w`=writeable, `i`=inherited allocation, `a`=active, `o`=open (montado), `t`=target relacionado con thin-pool, `z`=zeroing:

   ```bash
   sudo lvs -o name,lv_attr vg_lab
   ```

3. **Chequeo/reparación offline de la metadata del thin-pool** (el pool debe estar inactivo). `thin_check` valida la metadata; `lvconvert --repair` reconstruye la metadata de un pool corrupto hacia espacio de reserva:

   ```bash
   # Validate (read-only):
   #   sudo thin_check /dev/mapper/vg_lab-tpool_tmeta
   # Repair a damaged pool:
   #   sudo lvconvert --repair vg_lab/tpool
   ```

4. **Teardown completo.** Desmontá, remové los LV, eliminá el VG, borrá los PV, desadjuntá los dispositivos loop, borrá las imágenes:

   ```bash
   sudo umount /mnt/thin_a /mnt/snap 2>/dev/null
   sudo vgchange -an vg_lab
   sudo vgremove -y vg_lab
   sudo pvremove -y /dev/loop0 /dev/loop1 /dev/loop2 /dev/loop3 /dev/loop4 /dev/loop5
   for d in /dev/loop0 /dev/loop1 /dev/loop2 /dev/loop3 /dev/loop4 /dev/loop5; do
     sudo losetup -d "$d" 2>/dev/null
   done
   rm -f /var/tmp/lvmlab-pv*.img
   ```

5. Confirmá que la máquina está limpia:

   ```bash
   sudo vgs; sudo pvs; losetup -a | grep lvmlab || echo "no loop images left"
   ```

**Verificá tu comprensión**

- **Q27.** En la cadena de atributos, ¿qué te dice una `p` en la posición de salud/estado sobre los dispositivos subyacentes, y qué comando del Ejercicio 2 lo aborda?
- **Q28.** ¿Por qué un thin pool debe estar **inactivo** antes de que `lvconvert --repair` o `thin_check` operen sobre él, y dónde escribe `--repair` la metadata reconstruida?
- **Q29.** El teardown hace `vgchange -an` antes de `vgremove`. ¿Por qué desactivar primero, y qué error encontrarías si un thin volume siguiera montado?

---

<details>
<summary><strong>Respuestas</strong></summary>

**Q1.** `truncate` solo establece la longitud *lógica* del archivo en el inodo; no se asignan bloques de datos hasta que algo escribe en ellos, así que es instantáneo y de costo casi nulo. El riesgo: un thin pool confía en que su almacenamiento de respaldo es real. Si las imágenes dispersas colectivamente demandan más bloques que los que tiene el filesystem subyacente, el filesystem del *host* se llena, las escrituras al pool fallan con `ENOSPC`, y el thin pool se vuelve de solo lectura o da error — pérdida de datos que LVM no puede prever porque la escasez está en una capa por debajo suyo.

**Q2.** El **PV**. `pvcreate /dev/loop0` escribe la etiqueta/metadata de LVM sobre el dispositivo de bloques loop, convirtiéndolo en un physical volume. Los VG son contenedores lógicos sobre un conjunto de PV; los LV se tallan del VG — ninguno se coloca sobre un dispositivo crudo directamente.

**Q3.** 100 extents (400 MiB ÷ 4 MiB). LVM asigna espacio solo en physical extents completos, así que cualquier tamaño de LV se redondea hacia arriba a un múltiplo del tamaño del PE; no podés asignar una fracción de un extent.

**Q4.** La primera `a` significa **allocatable** — LVM puede colocar extents en este PV. Para que un LV sirva datos debe estar (1) **activo** (`a` en su propio attr, mapeado por device-mapper) y (2) tener todos sus PV subyacentes presentes; un PV faltante lo deja parcial/inactivo.

**Q5.** `lvs -a -o +devices` (agregando `segtype`, `sync_percent`, etc. según haga falta). El `-a` expone los sub-LV ocultos y `+devices` muestra la ubicación física — el campo que consultás en cada ejercicio de RAID/thin/cache.

**Q6.** Utilizable: **300 MiB** (un espejo de 2 vías muestra el equivalente a una copia). Bruto consumido: **~600 MiB** (dos imágenes de datos completas), más un par de extents para los dos sub-LV `_rmeta`. Un espejo intercambia la mitad de la capacidad bruta por una segunda copia completa.

**Q7.** `--replace` intercambia un dispositivo *funcional pero no deseado* (p. ej., migrar fuera de un disco que planeás retirar) — la fuente sigue sana. `--repair` reconstruye la redundancia después de que un dispositivo *realmente falló*, asignando una imagen fresca en un PV de reserva y resincronizando desde los sobrevivientes. Usá `--replace` para movimientos planificados, `--repair` para fallas.

**Q8.** El LV `raid1` de nivel superior es el target de RAID y es dueño del estado de sincronización, así que reporta el `Cpy%Sync` agregado. Los sub-LV `_rimage`/`_rmeta` son mapeos `linear` simples que meramente proveen almacenamiento al target de RAID; no tienen concepto de sincronización independiente, así que la columna queda en blanco para ellos.

**Q9.** `-L 300M` es el tamaño **utilizable**. raid5 almacena datos utilizables a lo largo de N−1 de N dispositivos (el equivalente a un dispositivo es paridad), así que con 3 stripes de datos el consumo bruto es de aproximadamente 300 MiB × 4/3 ≈ **400 MiB** más pequeña metadata — es decir, el equivalente a un stripe extra para la paridad.

**Q10.** raid6 mantiene **dos** bloques de paridad independientes (P y Q), así que necesita dos dispositivos más allá de los stripes de datos: 3 de datos + 2 de paridad = 5. Su justificación es sobrevivir a una **segunda** falla de disco — especialmente una falla que ocurre *durante* la reconstrucción de una primera falla, cuando un array raid5 no tiene redundancia restante.

**Q11.** `check` lee todos los bloques y *cuenta* las discrepancias sin cambiar nada (seguro, diagnóstico). `repair` lee, luego *reescribe* los datos/paridad correctos para eliminar las discrepancias. Ejecutás `check` primero para saber si el array está divergiendo silenciosamente antes de decidir mutar datos, y para programar scrubs periódicos de forma barata.

**Q12.** El scrub de RAID simple puede decir que dos copias *difieren* pero no *cuál es la correcta* — no tiene verdad de referencia (ground truth), así que en raid1 típicamente solo sobrescribe una con la otra. `--raidintegrity` almacena un checksum por bloque, así que un bloque corrupto **falla su checksum en la lectura** y se reporta como un error de E/S; la capa de RAID entonces sabe que esa copia está mala y reconstruye desde la copia verificada-buena, reescribiéndola. El checksum es la verdad de referencia faltante que convierte "difieren" en "esta está mal".

**Q13.** La reparación automática depende de tener una copia *redundante* desde la cual reconstruir. raid0 y lineal no tienen redundancia — detectar un bloque malo vía checksum te dejaría *reportar* la corrupción pero nunca *repararla* — así que LVM solo ofrece `--raidintegrity` en los niveles redundantes (1/4/5/6/10).

**Q14.** `bitmap` (default) registra qué regiones están sucias y es rápido, pero un bloque que se está escribiendo durante un crash puede quedar inconsistente. `journal` escribe los datos primero a un journal y luego a la ubicación final, así que una escritura que estaba en vuelo al momento de la pérdida de energía es recuperable — al costo de escribir los datos dos veces, aproximadamente reduciendo a la mitad el throughput de escritura.

**Q15.** `mdadm` escribe un **superbloque de MD** sobre los discos miembro y el array aparece como `/dev/mdN` en `/proc/mdstat`. LVM RAID almacena la definición del array dentro de la **metadata de LVM del VG** y lo instancia como un dispositivo de **device-mapper** vía el target `dm-raid` — nunca registra un array `md`, así que `/proc/mdstat` (que solo lista arrays de MD) no muestra nada. Buscá en `dmsetup`/`lvs` en su lugar.

**Q16.** `dmraid` (y hoy usualmente `mdadm` con el manejador de metadata apropiado) ensambla **"fake RAID" de firmware/BIOS** — arrays definidos por un formato en disco del fabricante (Intel IMSM, etc.) para que el BIOS pueda bootear desde ellos. Es una categoría distinta porque la disposición del RAID está dictada por un estándar de firmware externo, no creada y poseída por Linux (`mdadm`) ni por LVM.

**Q17.** LVM RAID mantiene todo en un solo dominio de gestión: podés hacer crecer, snapshotear, cachear, agregar/quitar integridad, y mover el LV de RAID con las mismas herramientas `lvconvert`/`lvresize` y un único almacén de metadata — sin dispositivo `md` separado que ensamblar, y el RAID + la gestión de volúmenes permanecen sincronizados. (Contrapartida: `mdadm` expone algo de ajuste fino y el monitoreo de `/proc/mdstat` que LVM abstrae.)

**Q18.** Cuando el *pool* alcanza el 100 % de data, cualquier escritura que necesite un bloque nuevo falla — el thin pool da error o se vuelve de solo lectura (según su comportamiento configurado). Un filesystem sobre `thin_b` ve fallas de escritura / errores de E/S **aunque `thin_b` en sí parezca 90 % vacío**, porque "vacío" se refiere a su espacio de direcciones virtual, mientras que los bloques físicos vienen del pool compartido, ahora agotado.

**Q19.** La metadata thin mapea cada bloque lógico a su ubicación física; si el espacio de metadata se agota el pool ya no puede registrar *dónde* van los bloques nuevos (ni siquiera los remapeados), así que todo el pool se vuelve de solo lectura/faulted sin importar el espacio de data libre. Síntoma: el pool pasa a solo lectura, `Meta%` al ~100 %, logs de kernel sobre metadata llena — y la recuperación puede requerir `thin_check`/`--repair` offline.

**Q20.** En el umbral 100 el pool nunca auto-crece, así que un pool over-provisioned llegará silenciosamente al 100 % y empezará a fallar escrituras sin margen de seguridad. LVM recomienda un umbral bien por debajo de 100 (default 70) para que se extienda *antes* del agotamiento. La autoextensión está manejada por monitoreo — el daemon **`dmeventd`** (con el plugin de monitoreo thin) debe estar corriendo para que la extensión se dispare.

**Q21.** Un thin snapshot comparte los bloques del origen y solo asigna bloques *nuevos* (para datos modificados) desde el **pool compartido** bajo demanda — no hay un área CoW fija que dimensionar. Un snapshot clásico tiene una región CoW dedicada y preasignada fuera de cualquier pool, así que debés indicar su tamaño con `-L`; esa región es finita y se llena.

**Q22.** El atributo `k` (skip-activation) significa que el volumen **no** se auto-activa en `vgchange -ay` ni en el arranque — una salvaguarda para que muchos snapshots no se activen todos accidentalmente. Lo reactivás explícitamente con `lvchange -ay -K <lv>` (el `-K` sobrescribe el flag de skip).

**Q23.** El espacio de data (y metadata) del **pool thin** es el recurso compartido. Si el pool se seca, tanto los snapshots como los orígenes ya no pueden asignar bloques modificados y el pool falla (fault). Observalo con `lvs -o data_percent,metadata_percent` sobre el pool — el análogo de ver el `Data%` de un snapshot clásico acercarse al 100 %.

**Q24.** `--cachevol` usa un **único** LV rápido que contiene tanto los datos del cache como su metadata internamente (más simple, más nuevo). `--cachepool` es el modelo más antiguo: un objeto `cache-pool` compuesto por un LV de datos separado **y** un LV de metadata oculto separado. La forma cachepool es la que mantiene la metadata en un LV oculto distinto.

**Q25.** `writethrough`: **no** hay pérdida de datos si el dispositivo de cache falla — cada escritura se compromete al origen lento *antes* de ser reconocida, así que el origen siempre está actualizado; solo perdés el beneficio de rendimiento. `writeback`: las escrituras se reconocen apenas llegan al cache, así que los bloques marcados como "dirty" que no se vaciaron al origen se **pierden** si el dispositivo de cache muere. La diferencia es *cuándo* se reconoce la escritura en relación con llegar al origen.

**Q26.** `--uncache` primero **vacía todos los bloques dirty (writeback) de vuelta al origen**, garantizando que el origen es consistente, y solo entonces remueve el cache — el desmontaje seguro que preserva los datos. Hacer solo `lvremove` sobre el cache volume descartaría los bloques dirty no vaciados y corrompería el origen.

**Q27.** Una `p` significa que el LV está **partial** — uno o más PV subyacentes están faltando/fallados, así que no todos los datos del LV están presentes. Para un LV de RAID redundante el arreglo es `lvconvert --repair` (reconstruir sobre un repuesto); para un LV no redundante señala datos faltantes irrecuperables y restaurás desde backup / `vgreduce --removemissing`.

**Q28.** `--repair`/`thin_check` necesitan una vista estable e inmutable de la metadata; un pool activo tiene el target del kernel leyendo y mutando esa metadata concurrentemente, contra lo cual las herramientas offline no pueden operar de forma segura. `lvconvert --repair` escribe una **copia reconstruida** de la metadata en el espacio de metadata de reserva del pool (no sobrescribe la metadata sospechosa en el lugar), así que podés inspeccionar antes de comprometer.

**Q29.** `vgchange -an` desactiva (desmapea) todos los LV para que device-mapper los libere; `vgremove` se niega a borrar un VG cuyos LV siguen activos/abiertos. Si un thin volume siguiera montado, la desactivación (y por tanto la remoción) falla con un error "logical volume in use" / "contains a filesystem in use" — primero debés hacer `umount`.

</details>

---

### Sources

- LPI — Exam 306 Objectives (364.3 Advanced LVM): https://www.lpi.org/our-certifications/exam-306-objectives/
- `lvmraid(7)` — LVM RAID, integrity and scrubbing: https://man7.org/linux/man-pages/man7/lvmraid.7.html
- `lvmthin(7)` — thin provisioning and thin snapshots: https://man7.org/linux/man-pages/man7/lvmthin.7.html
- `lvmcache(7)` — cache volumes, cache pools and modes: https://man7.org/linux/man-pages/man7/lvmcache.7.html
- `lvcreate(8)` / `lvconvert(8)` / `lvchange(8)`: https://man7.org/linux/man-pages/man8/lvcreate.8.html · https://man7.org/linux/man-pages/man8/lvconvert.8.html · https://man7.org/linux/man-pages/man8/lvchange.8.html
- `lvm.conf(5)` — `thin_pool_autoextend_threshold`/`_percent` and activation settings: https://man7.org/linux/man-pages/man5/lvm.conf.5.html
- `dmsetup(8)` — inspecting device-mapper targets (`status`, `table`, `ls`): https://man7.org/linux/man-pages/man8/dmsetup.8.html