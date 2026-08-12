# Topic 364.2 — RAID Avanzado

> **LPIC-3 306 (Examen 306-300, v3.0) · Topic 364: Alta Disponibilidad de Nodo Único · Peso del objetivo 3.33**
> Linux Software RAID con `mdadm` / el subsistema `md` — niveles anidados, metadatos, reshaping, write-intent bitmaps, journaling/PPL y recuperación ante fallos desde una perspectiva de SRE/Platform-Architect.

---

## 1. El problema en producción: RAID es el piso de durabilidad, no el techo de durabilidad

En un stack moderno casi siempre tenés una capa distribuida por encima del disco — Ceph, GlusterFS, DRBD, una base de datos con su propia replicación. Entonces, ¿por qué el RAID de nodo único todavía se gana un objetivo de examen completo y un lugar en todo diseño de almacenamiento serio?

Porque **RAID y la replicación distribuida resuelven dominios de fallo distintos a latencias distintas, y se componen.**

- Un **fallo de un único dispositivo** (un spindle que muere, un chip flash que se desgasta, un cable que se suelta) es la falla de almacenamiento más común en una flota. Manejarlo *localmente*, en la capa `md` del kernel, significa **cero tráfico de red, failover a escala de microsegundos y ninguna tormenta de rebuild cruzando tu fabric east-west.** Si cada fallo de disco forzara una re-replicación completa de objetos a través de la red del cluster, un cambio rutinario de disco generaría terabytes de tráfico cross-rack y competiría con el I/O de producción.
- La **capa distribuida** maneja los dominios de fallo que RAID *no puede*: un nodo entero que muere, un rack que pierde energía, una partición de datacenter. Es de grano grueso y network-bound por diseño.

La regla arquitectónica: **RAID te da un brick local durable; el sistema distribuido replica bricks.** OSDs de Ceph sobre un RAID por nodo, DRBD respaldado por un array RAID, o un primary de PostgreSQL sobre RAID-10 son todos el mismo patrón — redundancia local barata y rápida por debajo de redundancia global cara y lenta.

### 1.1 Los dos modelos de fallo que impulsan toda decisión de RAID avanzado

**(a) La ventana de rebuild vs. UBER.** Las capacidades de los discos crecieron ~1000× mientras que el **Unrecoverable Bit Error Rate (UBER)** de SATA consumer/nearline se mantuvo en ~1 en 10¹⁴ bits leídos. Un disco de 4 TB son 3,2×10¹³ bits. Para hacer el rebuild de un **RAID 5** degradado tenés que leer *cada* bloque sobreviviente; la probabilidad de toparte con un URE a mitad del rebuild — y con ello perder el array entero — ya no es despreciable. Esta es la razón matemática por la que RAID 5 se considera inseguro en discos nearline grandes y por la que **RAID 6 (doble paridad)** se convirtió en el default de producción para arrays de capacidad: sobrevive un URE *durante* el rebuild de un único disco.

**(b) El write hole de RAID 5/6.** Una escritura de stripe no es atómica entre dispositivos. Si se pierde la energía después de que se escribieron los bloques de datos pero antes de que se actualizara la paridad (o viceversa), el stripe queda ahora **internamente inconsistente**. En el siguiente resync tras un boot sucio, `md` recalcula la paridad a partir de los datos que encuentra — pero si un disco *también* falló, reconstruirá el bloque de ese disco a partir de *paridad obsoleta*, devolviendo silenciosamente datos corruptos. `md` cierra este hueco con un **journal** (dispositivo dedicado) o **PPL — Partial Parity Log** (en los metadatos, solo RAID 5).

Todo lo avanzado de `md` — bitmaps, journals, PPL, `--replace`, spare groups, reshape — existe para achicar una de estas dos ventanas o para sobrevivir a eventos dentro de ellas.

---

## 2. Análisis comparativo y trade-offs

### 2.1 Niveles de RAID — la matriz de decisión

| Nivel | Disp. mín | Capacidad utilizable (n discos) | Sobrevive | Lectura | Escritura | Costo de rebuild | Rol en producción |
|---|---|---|---|---|---|---|---|
| **0** | 2 | n | **nada** | ⭑⭑⭑ | ⭑⭑⭑ | N/A (datos perdidos) | Solo scratch / efímero / capa de cache |
| **1** | 2 | n/2 (típ. tamaño de 1) | n−1 discos (todos menos 1) | ⭑⭑⭑ | ⭑⭑ | barato (copia completa) | Discos de boot/OS, volúmenes críticos pequeños |
| **4** | 3 | n−1 | 1 disco | ⭑⭑ | ⭑ (cuello de botella en el disco de paridad) | lectura completa | Raro; el disco de paridad dedicado es un hotspot |
| **5** | 3 | n−1 | 1 disco | ⭑⭑⭑ | ⭑ (penalización RMW) | lectura completa (**riesgo de URE**) | Legacy; evitar en discos nearline grandes |
| **6** | 4 | n−2 | **2 discos** | ⭑⭑⭑ | ⭑ (RMW de 2× paridad) | lectura completa (sobrevive URE) | **Default de capacidad** para archivo/bulk |
| **10 (1+0)** | 4 | n/2 | ≥1 por mirror set | ⭑⭑⭑ | ⭑⭑⭑ | barato (copia de mirror) | **Default de rendimiento** para DBs/latencia |

- **Penalización de escritura de RAID 5/6:** una escritura de sub-stripe es Read-Modify-Write — leer datos viejos + paridad vieja, XOR, escribir datos nuevos + paridad nueva. RAID 6 paga esto **dos veces** (síndromes P y Q). Por eso la paridad RAID es mala para escrituras pequeñas aleatorias (OLTP) y allí se prefiere RAID 10.
- **Asimetría de rebuild:** RAID 10 hace el rebuild copiando *un* mirror sobreviviente (rápido, bajo I/O en todo el array). RAID 5/6 debe leer *todos* los discos para recalcular el miembro perdido — lento, y estresa exactamente los discos con más probabilidad de co-fallar.

### 2.2 RAID anidado / híbrido — y por qué el `raid10` de Linux ≠ "RAID 1+0"

| Topología | Construcción | Notas |
|---|---|---|
| **1+0 (10)** | stripe sobre mirrors | Pierde el array solo si mueren *ambos* miembros de *un* mirror |
| **0+1** | mirror sobre stripes | Peor: la pérdida de un disco degrada toda una pierna del stripe; una segunda pérdida en la *otra* pierna lo mata |
| **md `raid10`** | driver de nivel único | No es un stack de `raid1`+`raid0`; driver nativo con **layouts** y soporte de **disco impar / réplicas arbitrarias** |

El **`raid10` de `md` de Linux es una personality de primera clase**, no dos arrays apilados. Soporta **cualquier cantidad de discos ≥ 2** (incluso 3) y ubicación de copias configurable vía `--layout`:

| Layout | Flag | Comportamiento | Usar cuando |
|---|---|---|---|
| **near** | `n2` | Copias en dispositivos adyacentes (clásico tipo 1+0) | Propósito general, default |
| **far** | `f2` | Segunda copia desplazada muy abajo en los dispositivos | **Throughput de lectura ≈ RAID 0**; las escrituras buscan más |
| **offset** | `o2` | Copia en el siguiente dispositivo, desplazada un chunk | Compromiso equilibrado lectura/escritura |

`f2` en medios giratorios da un ancho de banda de lectura cercano al striping porque las lecturas secuenciales traen la copia "far" de forma contigua — un truco común para analítica read-heavy en HDD.

### 2.3 Versiones de metadatos del superblock

| Versión | Ubicación del superblock | ¿Bootear desde él? | Máx dispositivos | Notas |
|---|---|---|---|---|
| **0.90** | Final del dispositivo | Sí (legacy) | 28 | Límites fijos; auto-detección vía tipo de partición `0xFD`; **deprecado** |
| **1.0** | Final del dispositivo | Sí | 1920+ | Datos al inicio → los bootloaders que ignoran RAID pueden leerlo |
| **1.1** | Inicio del dispositivo (offset 0) | No (sobrescribe el área de boot) | 1920+ | Previene el montaje accidental de un miembro suelto |
| **1.2** | 4 KiB desde el inicio | Sí (con GRUB RAID-aware) | 1920+ | **Default actual** |

**El default es `1.2`.** Elegí `1.0` para un array de `/boot` que un bootloader ingenuo deba leer como si fuera un disco común. Nunca dependas del auto-assembly de `0.90` para arrays nuevos.

### 2.4 Software `md` vs. LVM-RAID (dm-raid) vs. RAID por hardware vs. fakeRAID

| Dimensión | `md` (mdadm) | LVM RAID (dm-raid) | RAID por hardware (HBA) | fakeRAID (BIOS/IMSM) |
|---|---|---|---|---|
| Motor | Kernel `md` | Mismos targets `md`/`dm` del kernel, front-end LVM | ASIC del vendor + BBU/flash cache | Metadatos de firmware, **la CPU hace el trabajo** |
| Portabilidad | Mover discos a cualquier host Linux | Igual | Atado a la familia de controladores | Atado al chipset |
| Observabilidad | `/proc/mdstat`, `sysfs` — totalmente transparente | `lvs -a -o +raid_sync_action` | Opaco; CLI del vendor (`storcli`, `ssacli`) | Pobre |
| Write cache | Page cache del OS / dispositivo journal | Igual | **Con batería** — ventaja real | Ninguno |
| Reshape/grow | Rico (`--grow`) | Rico (`lvconvert`) | Depende del vendor | Limitado |
| Recomendación | **Default para Linux** | Cuando querés RAID + thin/snapshots en una sola herramienta | Cuando el write cache con BBU es obligatorio | **Evitar**; usar `md` en modo AHCI en su lugar |

**fakeRAID** (Intel IMSM / VROC, Adaptec HostRAID) no tiene offload — la CPU calcula la paridad mientras que el formato de metadatos te ata a ese chipset. `md` soporta contenedores IMSM (`mdadm --detail-platform`, `AUTO +imsm`) precisamente para que puedas *interoperar* con él, pero para Linux greenfield, los metadatos nativos `1.2` son superiores en todo aspecto excepto en dual-boot UEFI con Windows.

### 2.5 Trade-offs del tamaño de chunk

El **chunk** (a.k.a. stripe unit) es la tira contigua escrita en un dispositivo antes de pasar al siguiente.

| Chunk | Favorece | Costo |
|---|---|---|
| Pequeño (64K) | Muchos I/Os pequeños en paralelo repartidos entre los spindles | Más seeks por I/O grande; overhead de RMW de paridad |
| Grande (512K–1M) | I/O secuencial grande, video, backups | Una escritura pequeña puede igual tocar un stripe completo (RMW) |

El default es **512 KiB**. Ajustalo a la carga de trabajo y *luego alineá el filesystem a él* (§5.4). Un chunk mal ajustado reduce silenciosamente el throughput a la mitad.

---

## 3. Manifiestos de infraestructura (completos, sin abreviar)

### 3.1 `/etc/mdadm/mdadm.conf` (ruta de Debian/Ubuntu; `/etc/mdadm.conf` en RHEL)

```conf
# /etc/mdadm/mdadm.conf  — regenerate ARRAY lines with:  mdadm --detail --scan
# --------------------------------------------------------------------------

# Which block devices mdadm may scan when assembling by UUID.
DEVICE /dev/sd[b-z] /dev/nvme[0-9]n[0-9]

# Tag arrays created on this host so foreign arrays are not auto-assembled.
HOMEHOST <system>

# Where mdmonitor sends fault events (see §5.1).
MAILADDR storage-team@example.com
MAILFROM mdadm@storage01.prod.example.net

# Auto-assembly policy: accept IMSM containers and 1.x native, refuse the rest.
AUTO +imsm +1.x -all

# --- Managed arrays (identified by UUID, never by /dev name) ---------------
ARRAY /dev/md0  metadata=1.2 name=storage01:0 UUID=3b8f6a21:9c4d0e77:1a2b3c4d:5e6f7a8b spare-group=bulk
ARRAY /dev/md1  metadata=1.2 name=storage01:1 UUID=aa11bb22:cc33dd44:ee55ff66:0011a2b3 spare-group=bulk

# --- Spare-migration policy: let a spare move to a same-slot replacement ----
POLICY domain=bulk path=pci-0000:03:00.0-* action=spare-same-slot
```

Dos arrays que comparten `spare-group=bulk` se **prestarán mutuamente un hot spare**: si `md0` se degrada y no tiene spare local, `mdmonitor` migra un spare inactivo de `md1` hacia él.

### 3.2 Unidad systemd de monitoreo de fallos (`mdmonitor.service`, incluida con mdadm)

```ini
# /usr/lib/systemd/system/mdmonitor.service
[Unit]
Description=MD array monitor
DefaultDependencies=no
Documentation=man:mdadm(8)
Conflicts=shutdown.target
Wants=local-fs.target
After=local-fs.target

[Service]
Environment= MDADM_MONITOR_ARGS=--scan
EnvironmentFile=-/run/sysconfig/mdadm
ExecStartPre=-/usr/lib/systemd/scripts/mdadm_env.sh
ExecStart=/sbin/mdadm --monitor $MDADM_MONITOR_ARGS
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

```bash
$ sudo systemctl enable --now mdmonitor.service
$ systemctl status mdmonitor.service --no-pager
● mdmonitor.service - MD array monitor
     Loaded: loaded (/usr/lib/systemd/system/mdmonitor.service; enabled)
     Active: active (running) since Wed 2026-08-12 14:30:11 UTC; 3min ago
   Main PID: 1187 (mdadm)
      Tasks: 1 (limit: 38314)
```

### 3.3 Timer de scrub semanal (el data-scrubbing detecta corrupción silenciosa)

```ini
# /etc/systemd/system/mdcheck.timer
[Unit]
Description=Weekly MD RAID consistency scrub

[Timer]
OnCalendar=Sun *-*-* 03:00:00
RandomizedDelaySec=1800
Persistent=true

[Install]
WantedBy=timers.target
```

```ini
# /etc/systemd/system/mdcheck.service
[Unit]
Description=Trigger MD RAID scrub (check action)
After=local-fs.target

[Service]
Type=oneshot
# Throttle so the scrub does not starve production I/O.
ExecStartPre=/usr/bin/bash -c 'echo 50000 > /proc/sys/dev/raid/speed_limit_max'
ExecStart=/usr/bin/bash -c 'for m in /sys/block/md*/md/sync_action; do echo check > "$m"; done'
```

> En Debian, el paquete `mdadm` ya incluye `/usr/share/mdadm/checkarray` más un cron/timer — preferí eso antes que armarlo a mano si está presente.

### 3.4 Aprovisionamiento declarativo — rol de Ansible (idempotente, grado producción)

```yaml
# roles/md_array/tasks/main.yml
---
- name: Ensure mdadm is installed
  ansible.builtin.package:
    name: mdadm
    state: present

- name: Create RAID 6 capacity array (idempotent — module no-ops if UUID exists)
  community.general.mdadm:                      # or ansible.posix on some collections
    name: /dev/md0
    level: 6
    devices:
      - /dev/sdb
      - /dev/sdc
      - /dev/sdd
      - /dev/sde
      - /dev/sdf
      - /dev/sdg
    chunk: 512
    metadata: "1.2"
    bitmap: internal
    state: present
  register: md0

- name: Persist array definition to mdadm.conf
  ansible.builtin.shell: |
    set -o pipefail
    mdadm --detail --scan /dev/md0 >> /etc/mdadm/mdadm.conf
  args:
    executable: /bin/bash
  when: md0.changed

- name: Rebuild initramfs so the array assembles at boot
  ansible.builtin.command: update-initramfs -u        # dracut -f on RHEL
  when: md0.changed

- name: Create XFS aligned to the RAID geometry (su=chunk, sw=data disks)
  community.general.filesystem:
    fstype: xfs
    dev: /dev/md0
    opts: "-d su=512k,sw=4"                            # RAID6 of 6 disks → 4 data disks
    state: present
```

### 3.5 cloud-init: RAID en el primer boot

```yaml
#cloud-config
# Build a mirrored root-data volume on ephemeral/attached disks at first boot.
disk_setup:
  /dev/nvme1n1: {table_type: gpt, layout: true, overwrite: true}
  /dev/nvme2n1: {table_type: gpt, layout: true, overwrite: true}

bootcmd:
  - [ cloud-init-per, once, mkmd,
      mdadm, --create, /dev/md0, --level=1, --raid-devices=2, --metadata=1.2,
      --bitmap=internal, /dev/nvme1n1, /dev/nvme2n1, --run ]

runcmd:
  - mdadm --detail --scan | tee -a /etc/mdadm/mdadm.conf
  - mkfs.ext4 -F -b 4096 -E stride=128,stripe-width=128 /dev/md0
  - mkdir -p /data && mount /dev/md0 /data
  - echo "/dev/md0 /data ext4 defaults,nofail 0 2" >> /etc/fstab
```

---

## 4. Referencia de comandos con salida real de terminal

### 4.1 Crear un array RAID 6 con un write-intent bitmap interno

```console
$ sudo mdadm --create /dev/md0 --level=6 --raid-devices=6 --chunk=512 \
    --metadata=1.2 --bitmap=internal /dev/sd{b,c,d,e,f,g}
mdadm: layout defaults to left-symmetric
mdadm: chunk size defaults to 512K
mdadm: size set to 3906886656K
mdadm: automatically enabling write-intent bitmap on large array
mdadm: array /dev/md0 started.
```

```console
$ cat /proc/mdstat
Personalities : [raid6] [raid5] [raid4]
md0 : active raid6 sdg[5] sdf[4] sde[3] sdd[2] sdc[1] sdb[0]
      15627546624 blocks super 1.2 level 6, 512k chunk, algorithm 2 [6/6] [UUUUUU]
      [>....................]  resync =  0.4% (17821440/3906886656) finish=343.2min speed=188901K/sec
      bitmap: 30/30 pages [120KB], 65536KB chunk

unused devices: <none>
```

Leé con cuidado la línea de estado: `[6/6]` = dispositivos esperados/presentes; `[UUUUUU]` = estado por dispositivo (`U`=up, `_`=faltante). `algorithm 2` = layout de paridad left-symmetric.

### 4.2 Detalle completo y examine por dispositivo

```console
$ sudo mdadm --detail /dev/md0
/dev/md0:
           Version : 1.2
     Creation Time : Wed Aug 12 14:22:31 2026
        Raid Level : raid6
        Array Size : 15627546624 (14.55 TiB 16.00 TB)
     Used Dev Size : 3906886656 (3.64 TiB 4.00 TB)
      Raid Devices : 6
     Total Devices : 6
       Persistence : Superblock is persistent

     Intent Bitmap : Internal

             State : clean, resyncing
    Active Devices : 6
   Working Devices : 6
    Failed Devices : 0
     Spare Devices : 0

            Layout : left-symmetric
        Chunk Size : 512K
Consistency Policy : bitmap

              Name : storage01:0  (local to host storage01)
              UUID : 3b8f6a21:9c4d0e77:1a2b3c4d:5e6f7a8b
            Events : 42

    Number   Major   Minor   RaidDevice State
       0       8       16        0      active sync   /dev/sdb
       1       8       32        1      active sync   /dev/sdc
       2       8       48        2      active sync   /dev/sdd
       3       8       64        3      active sync   /dev/sde
       4       8       80        4      active sync   /dev/sdf
       5       8       96        5      active sync   /dev/sdg
```

```console
$ sudo mdadm --examine /dev/sdb          # reads the on-disk superblock of ONE member
/dev/sdb:
          Magic : a92b4efc
        Version : 1.2
    Feature Map : 0x1
     Array UUID : 3b8f6a21:9c4d0e77:1a2b3c4d:5e6f7a8b
           Name : storage01:0
  Creation Time : Wed Aug 12 14:22:31 2026
     Raid Level : raid6
   Raid Devices : 6
    Data Offset : 264192 sectors
   Super Offset : 8 sectors
   Unused Space : before=264104 sectors, after=0 sectors
          State : clean
    Device UUID : d1e2f3a4:...:...
Internal Bitmap : 8 sectors from superblock
    Update Time : Wed Aug 12 14:25:03 2026
       Checksum : 5f3a1c2e - correct
         Events : 42
         Layout : left-symmetric
     Chunk Size : 512K
   Device Role : Active device 0
   Array State : AAAAAA ('A' == active, '.' == missing, 'R' == replacing)
```

> **`--detail` inspecciona el array en ejecución vía `md`; `--examine` lee el superblock crudo de un miembro.** Cuando un array no ensambla, `--examine` es tu fuente de verdad — compará los contadores `Events` entre los miembros para encontrar el disco obsoleto.

### 4.3 Grow: convertir RAID 5 → RAID 6, y agregar capacidad por reshape

```console
$ sudo mdadm --grow /dev/md0 --level=6 --raid-devices=7 \
    --add /dev/sdh --backup-file=/root/md0-reshape.backup
mdadm: level of /dev/md0 changed to raid6
mdadm: added /dev/sdh
mdadm: Need to backup 15360K of critical section..

$ cat /proc/mdstat
md0 : active raid6 sdh[6] sdg[5] sdf[4] sde[3] sdd[2] sdc[1] sdb[0]
      15627546624 blocks super 1.2 level 6, 512k chunk, algorithm 18 [7/7] [UUUUUUU]
      [===>.................]  reshape = 18.7% (730812416/3906886656) finish=612.4min speed=86420K/sec
```

El `--backup-file` protege la **sección crítica** — los stripes que se están reubicando durante el reshape — contra un crash a mitad del reshape. Mantenelo en un dispositivo *distinto*. Después de que el reshape termine, extendé el filesystem:

```console
$ sudo mdadm --grow /dev/md0 --size=max        # if member disks were also enlarged
$ sudo xfs_growfs /data                        # or: resize2fs /dev/md0  (ext4)
```

### 4.4 Simular, quitar y reconstruir un dispositivo fallado

```console
$ sudo mdadm --manage /dev/md0 --fail /dev/sdd
mdadm: set /dev/sdd faulty in /dev/md0

$ cat /proc/mdstat
md0 : active raid6 sdg[5] sdf[4] sde[3] sdd[2](F) sdc[1] sdb[0]
      15627546624 blocks super 1.2 level 6, 512k chunk, algorithm 2 [6/5] [UUU_UU]

$ sudo mdadm --manage /dev/md0 --remove /dev/sdd
mdadm: hot removed /dev/sdd from /dev/md0

$ sudo mdadm --manage /dev/md0 --add /dev/sdi
mdadm: added /dev/sdi

$ cat /proc/mdstat
md0 : active raid6 sdi[6] sdg[5] sdf[4] sde[3] sdc[1] sdb[0]
      15627546624 blocks super 1.2 level 6, 512k chunk, algorithm 2 [6/5] [UUU_UU]
      [>....................]  recovery =  0.9% (35651584/3906886656) finish=289.7min speed=222549K/sec
      bitmap: 4/30 pages [16KB], 65536KB chunk
```

**`--replace` es superior cuando el disco está *muriendo pero no muerto*:** reconstruye sobre un spare mientras mantiene el disco que falla en el array como fuente de redundancia — de modo que el array permanece *totalmente* redundante durante todo el proceso, en vez de correr degradado:

```console
$ sudo mdadm /dev/md0 --add-spare /dev/sdi
$ sudo mdadm /dev/md0 --replace /dev/sde --with /dev/sdi
mdadm: Marked /dev/sde (device 3) for replacement
mdadm: Marked /dev/sdi as replacement for device 3
```

### 4.5 Write-intent bitmap: agregar, ajustar, quitar en línea

Un **write-intent bitmap** registra qué regiones tienen escrituras en vuelo. Después de un crash o una caída transitoria de un disco, el resync toca **solo las regiones sucias** en vez del array entero — convirtiendo un resync completo de 6 horas en segundos.

```console
$ sudo mdadm --grow /dev/md0 --bitmap=internal --bitmap-chunk=128M
$ sudo mdadm --grow /dev/md0 --bitmap=none     # remove (e.g. before a reshape that forbids it)
```

Trade-off: un bitmap agrega un pequeño impuesto de latencia de escritura (cada seteo de bit sucio es un I/O extra). Usá un **`--bitmap-chunk` más grande** para reducir ese impuesto a costa de una granularidad de resync más gruesa. Para arrays muy write-heavy de baja latencia, un **bitmap externo** en un dispositivo separado rápido evita el seek de vuelta a los discos de datos.

### 4.6 Cerrar el write hole: journal (cualquier nivel de paridad) vs. PPL (RAID 5)

```console
# Dedicated write-journal on NVMe — closes the write hole for RAID 5 AND 6,
# at the cost of every write also hitting the journal device first.
$ sudo mdadm --create /dev/md1 --level=6 --raid-devices=6 \
    --write-journal=/dev/nvme0n1 /dev/sd{b,c,d,e,f,g}

$ sudo mdadm --detail /dev/md1 | grep -i journal
     Journal Device : /dev/nvme0n1
 Consistency Policy : journal
```

```console
# PPL (Partial Parity Log) — RAID 5 ONLY, stored inside the metadata area.
# Far lower overhead than a journal; closes the specific write-hole reconstruction bug.
$ sudo mdadm --create /dev/md2 --level=5 --raid-devices=4 \
    --consistency-policy=ppl /dev/sd{h,i,j,k}

$ cat /sys/block/md2/md/consistency_policy
ppl
```

| Mecanismo | Niveles | Almacenamiento | Costo de escritura | ¿Cierra el write hole? |
|---|---|---|---|---|
| `resync` (default) | 5, 6 | ninguno | ninguno | **No** — el resync asume sobrevivientes limpios |
| `bitmap` | todos | en-meta/externo | bajo | No (acelera el *resync*, no el hueco) |
| `ppl` | **solo 5** | área de metadatos | bajo | **Sí** (Partial Parity Log) |
| `journal` | 5, 6 | dispositivo dedicado | alto (doble escritura) | **Sí** (también da write-back cache) |

### 4.7 Ensamblar, escanear y persistir

```console
$ sudo mdadm --assemble --scan                 # assemble everything in mdadm.conf
$ sudo mdadm --assemble /dev/md0 --uuid=3b8f6a21:9c4d0e77:1a2b3c4d:5e6f7a8b
$ sudo mdadm --detail --scan | sudo tee -a /etc/mdadm/mdadm.conf
ARRAY /dev/md0 metadata=1.2 name=storage01:0 UUID=3b8f6a21:9c4d0e77:1a2b3c4d:5e6f7a8b
$ sudo update-initramfs -u                      # dracut -f --regenerate-all on RHEL
```

---

## 5. Playbook de verificación y diagnóstico de fallos

### 5.1 Monitoreo continuo

```console
$ sudo mdadm --monitor --scan --oneshot --test         # fire a TestMessage to MAILADDR now
$ sudo mdadm --monitor --scan --daemonise --mail=storage-team@example.com \
    --program=/usr/local/sbin/md-alert.sh
```

`--monitor` emite eventos (`Fail`, `FailSpare`, `DegradedArray`, `SpareActive`, `RebuildFinished`, `TestMessage`). Conectá `--program` a tu alerting (PagerDuty/Prometheus pushgateway). **Un array degradado sobre el que nadie recibe un page es un segundo fallo esperando convertirse en pérdida de datos.**

Los usuarios de Prometheus ya exportan esto vía **`node_exporter`**:

```console
$ curl -s localhost:9100/metrics | grep node_md_
node_md_disks{device="md0",state="active"} 5
node_md_disks{device="md0",state="failed"} 1
node_md_disks_required{device="md0"} 6
node_md_state{device="md0",state="active"} 1
```
Regla de alerta: `node_md_disks{state="active"} < node_md_disks_required` → degradado.

### 5.2 Data scrubbing — cazar corrupción *silenciosa* (bit rot)

RAID protege contra el *fallo de disco*, no contra un bloque que se lee mal sin un error. Un scrub periódico lee cada stripe y verifica la paridad:

```console
$ echo check | sudo tee /sys/block/md0/md/sync_action     # verify only, no writes
$ cat /sys/block/md0/md/sync_action
check
$ watch -n5 cat /sys/block/md0/md/mismatch_cnt
$ cat /sys/block/md0/md/mismatch_cnt
0                                                          # 0 = healthy
```

Si `mismatch_cnt` es **distinto de cero después de un `check`**, un stripe es inconsistente. Forzá una reescritura de la paridad a partir de los datos:

```console
$ echo repair | sudo tee /sys/block/md0/md/sync_action
```

> **Advertencia:** en RAID 1/10, `md` no puede saber *cuál* copia de mirror es la correcta — `repair` elige la primera y sobrescribe la otra. Un contador distinto de cero que se repite apunta a un disco específico que está muriendo o a un fallo de controlador/cable; investigá `smartctl -a` y los logs del kernel antes de confiar en `repair`. En arrays respaldados por swap, los contadores transitorios distintos de cero son normales (el kernel puede escribir páginas que se liberan a mitad del flush).

### 5.3 Recuperar un array que no ensambla

**Paso 1 — comparar los contadores de eventos** entre todos los miembros:

```console
$ sudo mdadm --examine /dev/sd[b-g] | egrep 'Events|/dev/sd'
/dev/sdb:
         Events : 20418
/dev/sdc:
         Events : 20418
/dev/sdd:
         Events : 20411          # <- stale: dropped out 7 events ago
/dev/sde:
         Events : 20418
/dev/sdf:
         Events : 20418
/dev/sdg:
         Events : 20418
```

**Paso 2 — force-assemble a partir de los discos con el contador de eventos más alto y consistente.** `--force` reescribe el superblock del miembro obsoleto para que el array arranque (luego resincronizará ese miembro):

```console
$ sudo mdadm --assemble --force /dev/md0 /dev/sd{b,c,d,e,f,g}
mdadm: forcing event count in /dev/sdd(2) from 20411 up to 20418
mdadm: /dev/md0 has been started with 6 drives.
```

**Paso 3 — último recurso: re-crear con `--assume-clean`.** Solo si los superblocks están destruidos y *conocés* la geometría original exacta (nivel, chunk, orden de discos, data-offset, versión de metadatos — obtenelos de la salida de `--examine` que guardaste antes). `--assume-clean` omite el resync inicial de modo que **no** sobrescribe datos — pero un solo parámetro equivocado revuelve el array de forma permanente:

```console
$ sudo mdadm --create /dev/md0 --assume-clean --level=6 --raid-devices=6 \
    --chunk=512 --metadata=1.2 --data-offset=264192s \
    /dev/sdb /dev/sdc missing /dev/sde /dev/sdf /dev/sdg
```

Montá inmediatamente en **solo lectura** y hacé `fsck -n` para confirmar que el layout es correcto antes de escribir cualquier cosa.

### 5.4 Verificación de alineación del filesystem

Un filesystem correctamente alineado permite que una escritura lógica mapee a stripes completos, evitando el read-modify-write.

- **stride** = chunk ÷ bloque-fs = 512 KiB ÷ 4 KiB = **128**
- **stripe-width** = stride × discos de *datos*. RAID 6 sobre 6 discos = 4 discos de datos → 128 × 4 = **512**

```console
$ sudo mkfs.ext4 -b 4096 -E stride=128,stripe-width=512 /dev/md0
$ sudo mkfs.xfs -d su=512k,sw=4 /dev/md0        # su=chunk, sw=data-disk count

$ sudo tune2fs -l /dev/md0 | grep -iE 'stride|stripe'
RAID stride:              128
RAID stripe width:        512
```

Para el throughput de escritura de RAID 5/6, aumentá el stripe cache (se cambia RAM por menos ciclos de RMW):

```console
$ echo 8192 | sudo tee /sys/block/md0/md/stripe_cache_size    # pages; 8192 = 32 MiB/disk
```

### 5.5 Throttling y des-atascar resync/reshape

```console
$ cat /proc/sys/dev/raid/speed_limit_min      # floor even when array is busy (KB/s/disk)
1000
$ cat /proc/sys/dev/raid/speed_limit_max      # ceiling when array is idle
200000

# Slow a rebuild so it stops starving production I/O:
$ echo 30000 | sudo tee /proc/sys/dev/raid/speed_limit_max

# A resync stuck at "DELAYED" (another array holds the disks) — let it proceed:
$ echo idle  | sudo tee /sys/block/md1/md/sync_action    # pause the other array's sync
```

### 5.6 Tabla de decisión para triage rápido

| Síntoma en `/proc/mdstat` / logs | Causa probable | Primera acción |
|---|---|---|
| `[N/N-1]` con `_` en un slot | Un disco falló/cayó | Chequear `smartctl`, `--remove` el fallado, `--add` el reemplazo |
| `(F)` junto a un dispositivo | El kernel lo marcó como faulty | Inspeccionar `dmesg` por errores de I/O antes de confiar en el disco |
| El array no ensambla, `possibly out of date` | Contadores de eventos en split-brain | `--examine` todos, `--assemble --force` desde el más nuevo |
| `mismatch_cnt` > 0 tras un scrub | Corrupción silenciosa / disco muriendo | `smartctl -a`; investigar antes de `repair` |
| Rebuild extremadamente lento (`speed=`) | Throttle de `speed_limit_max` o array ocupado | Chequear `/proc/sys/dev/raid/*`, subir el techo |
| `resync=DELAYED` | Otro array retiene los mismos discos | Secuenciar los syncs vía `sync_action` |
| Array `inactive`, sin personalities | Módulo/personality de RAID no cargado | `modprobe raid456`; chequear initramfs |
| Reshape congelado tras un crash | backup-file faltante/rotado | `--assemble --update=revert-reshape --backup-file=…` |

---

## 6. Referencias

- LPI — Exam 306 Objectives (Topic 364.2, Advanced RAID): <https://www.lpi.org/our-certifications/exam-306-objectives/>
- Linux Kernel — `md` administration guide: <https://www.kernel.org/doc/html/latest/admin-guide/md.html>
- Linux RAID Wiki (kernel.org) — RAID setup, recovery, superblock formats: <https://raid.wiki.kernel.org/index.php/Linux_Raid>
- `mdadm(8)` man page: <https://man7.org/linux/man-pages/man8/mdadm.8.html>
- `md(4)` man page (personalities, `sysfs`, layouts): <https://man7.org/linux/man-pages/man4/md.4.html>
- `mdadm.conf(5)` man page: <https://man7.org/linux/man-pages/man5/mdadm.conf.5.html>
- Kernel docs — RAID 5 PPL (Partial Parity Log): <https://www.kernel.org/doc/html/latest/driver-api/md/raid5-ppl.html>
- Kernel docs — RAID 5 cache / write journal: <https://www.kernel.org/doc/html/latest/driver-api/md/raid5-cache.html>
- Linux RAID Wiki — write-intent bitmap: <https://raid.wiki.kernel.org/index.php/Write-intent_bitmap>
- Linux RAID Wiki — RAID recovery / reshaping: <https://raid.wiki.kernel.org/index.php/RAID_Recovery>