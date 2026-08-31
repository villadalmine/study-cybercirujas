# 104.2 — Mantener la integridad de los sistemas de archivos

**Certificación:** LPIC-1 (Exámenes 101-500 / 102-500, versión 5.0)
**Tema:** 104.2 — Mantener la integridad de los sistemas de archivos
**Peso del examen:** 3.12
**Nivel:** Avanzado — Platform Architect / SRE

**Alcance del objetivo (LPI):**
- Verificar la integridad de los sistemas de archivos
- Monitorear el espacio libre y los inodos
- Reparar problemas simples de sistemas de archivos

**Términos y utilidades:** `du`, `df`, `fsck`, `e2fsck`, `mke2fs`, `tune2fs`, `xfs_repair`, `xfs_fsr`, `xfs_db`

---

## 1. Motivación: el problema arquitectónico en producción

Un sistema de archivos no es una bolsa de bytes. Es una **base de datos** en disco con su propio log de transacciones, mapas de bits de asignación, contadores de referencias e invariantes. Cada uno de los siguientes invariantes debe cumplirse, y cada uno de ellos puede ser violado por un corte de energía, un bug de firmware, una controladora RAID que se porta mal, una sesión iSCSI truncada o un bug del kernel:

1. Cada bloque asignado pertenece a **exactamente un** inodo (o a metadatos).
2. El `i_links_count` de cada inodo es igual a la cantidad de entradas de directorio que apuntan a él.
3. Cada entrada de directorio apunta a un inodo en uso.
4. Cada inodo en uso es alcanzable desde el inodo raíz (o desde `lost+found`).
5. Los contadores de bloques libres e inodos libres en el superbloque / encabezados de AG coinciden con la realidad.

El trabajo de integridad de sistemas de archivos en producción se divide en tres clases de falla que los operadores confunden habitualmente:

| Clase de falla | Causa raíz | Cómo se ve | Respuesta correcta |
|---|---|---|---|
| **Agotamiento de espacio** | Planificación de capacidad / escritor desbocado | `ENOSPC` (`No space left on device`), las escrituras fallan, la app crashea, la DB se niega a arrancar | `df`, `du`, `lsof +L1` → recuperar espacio. **Nunca** correr `fsck` |
| **Agotamiento de inodos** | Millones de archivos diminutos, geometría elegida al momento del `mkfs` | `ENOSPC` **con** bloques libres visibles en `df -h` | `df -i`, encontrar el directorio culpable, recuperar espacio o reconstruir el fs |
| **Corrupción de metadatos** | Corte de energía, bug del stack de almacenamiento, medio moribundo | `EIO`/`EUCLEAN` (`Structure needs cleaning`), fs remontado de solo lectura, errores en `dmesg` | Sacarlo de línea, hacer una imagen, `e2fsck`/`xfs_repair` |

El error arquitectónico que se comete con más frecuencia es aplicar la tercera respuesta al primer problema. **`fsck` no libera espacio y no arregla un sistema de archivos lleno.** Correr una herramienta de reparación sobre un sistema de archivos montado, o correrla "por las dudas" sobre un medio sano que simplemente está lleno, es la manera de convertir un incidente recuperable en un incidente de restore-desde-backup.

El segundo error arquitectónico es tratar la verificación de integridad como algo que ocurre en el arranque. En un volumen XFS de 40 TiB, un `xfs_repair` offline es una operación de varias horas, hambrienta de memoria, y con **downtime**. En una plataforma moderna, la integridad se *verifica continuamente en línea* (`e2scrub`, `xfs_scrub`, chequeos sobre snapshots LVM, checksums de metadatos) y se *monitorea continuamente* (espacio libre, inodos libres, contadores de error del superbloque, remontajes de solo lectura) de modo que la reparación offline sea un evento planificado, no una sorpresa.

### El invariante de los bloques reservados

`mke2fs` reserva por defecto el 5% de los bloques para el UID 0. Esto no es superstición, cumple dos propósitos distintos:

1. **Válvula de escape operativa** — cuando un sistema de archivos llega al 100% para los escritores sin privilegios, root todavía puede iniciar sesión, rotar logs, escribir en `/var/log` y correr herramientas de recuperación. En `/`, un sistema de archivos con 0% reservado que se llena por completo suele ser irrecuperable sin un arranque de rescate, porque `sshd` no puede escribir sus archivos de sesión.
2. **Margen para el asignador** — los asignadores basados en extents se degradan feo cerca del lleno. Un sistema de archivos llevado más allá de ~95% sufre una fragmentación severa del espacio libre; el asignador pasa más tiempo buscando y la cantidad de extents por archivo explota.

En un volumen de datos de 12 TiB, el 5% son 600 GiB de capacidad varada, así que bajarlo a 1% es una decisión de producción legítima — pero **solo** en un sistema de archivos que no contiene estado del sistema y que está monitoreado.

---

## 2. Comparaciones técnicas y compromisos

### 2.1 Modelo de reparación y verificación por sistema de archivos

| Propiedad | ext4 | XFS | Btrfs |
|---|---|---|---|
| Mecanismo de consistencia | journal jbd2 (metadatos; opcionalmente datos) | Log write-ahead interno (solo metadatos) | Copy-on-Write, sin journal |
| Herramienta de reparación offline | `e2fsck` (`fsck.ext4`) | `xfs_repair` | `btrfs check --repair` (último recurso) |
| `fsck` en el arranque | Sí — `fsck.ext4` vía `systemd-fsck@.service` | **No** — `/usr/sbin/fsck.xfs` es un stub que sale con 0 | No |
| Chequeo de consistencia en línea | `e2scrub` (snapshot LVM + `e2fsck -fn`) | `xfs_scrub` (scrub nativo en línea) | `btrfs scrub` (verifica checksums) |
| Checksums de metadatos | característica `metadata_csum` (por defecto desde e2fsprogs 1.43) | `crc=1` (por defecto desde xfsprogs 3.2.3) | Siempre activos |
| Checksums de **datos** | No | No | Sí (crc32c/xxhash/blake2) |
| Crecer en línea | Sí (`resize2fs`) | Sí (`xfs_growfs`) | Sí |
| Achicar | Sí, **solo offline** | **Nunca soportado** | Sí, en línea |
| Costo de memoria de la reparación | Modesto, acotado por la cantidad de inodos | Alto — `xfs_repair` puede necesitar GiB; usar `-m` / `-P` | Alto |
| Repara estando montado | Nunca | Nunca (`xfs_repair` se niega) | Nunca |
| Rol típico en la plataforma | Volúmenes raíz, propósito general, `/boot` | Volúmenes de datos grandes, raíz por defecto en RHEL, I/O altamente paralela | Cargas centradas en snapshots |

**Lectura del arquitecto sobre esta tabla:** si `fsck.xfs` es un no-op, entonces `passno` en `/etc/fstab` no significa nada para XFS y un volumen raíz XFS obtiene *cero* verificación en el arranque. La posición de diseño de XFS es que la reproducción del log al montar es el mecanismo de recuperación, y que un chequeo estructural completo es un evento explícito, iniciado por el operador. Ese es un diseño correcto — pero significa que tu monitoreo, no tu secuencia de arranque, es lo que te va a avisar que un volumen XFS está enfermo.

### 2.2 `df` vs `du` — dos preguntas distintas

| | `df` | `du` |
|---|---|---|
| Fuente de datos | Superbloque / encabezados de AG vía `statfs(2)` | Recorre el árbol de directorios, hace `stat(2)` a cada entrada |
| Pregunta que responde | "¿Cuántos bloques cree el *sistema de archivos* que están asignados?" | "¿Cuántos bloques son alcanzables a través de *esta ruta*?" |
| Costo | O(1), microsegundos | O(cantidad de archivos), minutos en árboles grandes |
| Ve archivos borrados pero abiertos | **Sí** (todavía asignados) | **No** (desenlazados, inalcanzables) |
| Ve archivos ocultos bajo un punto de montaje | Sí | No (recorre el montaje *superior*) |
| Ve otros sistemas de archivos | Una fila por cada uno | Sí, salvo que se pase `-x` |
| Archivos dispersos (sparse) | Cuenta bloques asignados | Cuenta bloques asignados — salvo con `--apparent-size` |
| Respeta los bloques reservados | Sí (`Avail` los excluye; `Use%` es relativo a los no reservados) | N/A |

Toda discrepancia entre `du` y `df` en producción se reduce a una de cinco causas:

| Síntoma | Causa | Prueba |
|---|---|---|
| `df` >> `du` | Archivos borrados mantenidos abiertos por un proceso | `lsof -nP +L1` |
| `df` >> `du` | Archivos tapados por un montaje posterior sobre un directorio poblado | `mount --bind / /mnt && du -xsh /mnt/var` |
| `df` >> `du` | `du` corrido sin root, salteando directorios ilegibles | Correr como root, revisar stderr |
| `du` >> el "tamaño" reportado por `df` | Enlaces duros contados una sola vez por `du`, o archivos dispersos | `du --apparent-size`, `find -links +1` |
| Ambos se ven bien, las escrituras siguen fallando | Inodos agotados, o cuota, o bloques reservados | `df -i`, `repquota`, `tune2fs -l` |

### 2.3 Códigos de salida de `fsck` (máscara de bits — lo evalúa el examen, y también tu automatización)

| Código | Significado |
|---|---|
| 0 | Sin errores |
| 1 | Errores del sistema de archivos corregidos |
| 2 | Errores del sistema de archivos corregidos, **se debería reiniciar el sistema** |
| 4 | Errores del sistema de archivos dejados **sin corregir** |
| 8 | Error operativo |
| 16 | Error de uso o de sintaxis |
| 32 | Chequeo cancelado a pedido del usuario |
| 128 | Error de biblioteca compartida |

`fsck` sobre múltiples sistemas de archivos devuelve el **OR bit a bit** de los códigos individuales. Un script envoltorio que prueba `if [ $? -eq 0 ]` va a tratar la salida 1 (reparado con éxito) como una falla, y la salida 5 (`1|4`, "algunos arreglados, otros no") igual que la salida 4. Probá los bits:

```bash
fsck -A -a
rc=$?
(( rc & 4 )) && echo "UNCORRECTED ERRORS — do not boot into production" >&2
(( rc & 2 )) && echo "reboot required" >&2
(( rc == 0 || rc == 1 )) && echo "clean"
```

### 2.4 Comportamiento ante errores en ext4 — el parámetro ajustable más importante de todos

| Valor de `errors=` | Comportamiento del kernel ante un error de metadatos | Cuándo usarlo |
|---|---|---|
| `continue` | Registrar el error, seguir adelante | Casi nunca — propaga la corrupción |
| `remount-ro` | Remontar inmediatamente de solo lectura, preservar el estado en disco | **La elección por defecto para todo volumen de producción** |
| `panic` | Kernel panic | Clústeres HA donde un reinicio con fencing es más seguro que un nodo degradado vivo |

`remount-ro` convierte una corrupción silenciosa de datos en una caída ruidosa, contenida y diagnosticable. La aplicación empieza a lanzar `EROFS`, el monitoreo dispara, y el daño en disco deja de crecer. XFS tiene un equivalente: ante corrupción seria de metadatos realiza un **shutdown del sistema de archivos** (`XFS (dm-2): Corruption detected. Unmount and run xfs_repair`), tras lo cual toda la I/O devuelve `EIO` hasta que el volumen se desmonta.

### 2.5 `tune2fs` ↔ equivalentes en XFS

| Tarea | ext4 | XFS |
|---|---|---|
| Mostrar geometría / características | `tune2fs -l`, `dumpe2fs -h` | `xfs_info /mnt`, `xfs_db -r -c 'sb 0' -c p` |
| Establecer etiqueta | `tune2fs -L data` | `xfs_admin -L data` (desmontado) |
| Establecer UUID | `tune2fs -U <uuid>` | `xfs_admin -U <uuid>` |
| Forzar chequeo en el próximo arranque | `tune2fs -C 100 -c 20` | *(no aplica — no hay fsck en el arranque)* |
| Comportamiento ante errores | `tune2fs -e remount-ro` | perillas en `/sys/fs/xfs/<dev>/error/` |
| Espacio reservado | `tune2fs -m 1` | *(ninguno; usar cuotas de proyecto)* |
| Desfragmentar | `e4defrag` | `xfs_fsr` |
| Capacidad de inodos | fija al momento del `mke2fs` | dinámica, con tope según `imaxpct` |

---

## 3. Manifiestos completos de infraestructura

### 3.1 `cloud-init` — aprovisionar un volumen de datos con una geometría defendible

```yaml
#cloud-config
# Provisions a data volume for a metadata-heavy workload (maildir / object cache):
#   - 8 KiB bytes-per-inode instead of the 16 KiB default -> 2x the inodes
#   - reserved blocks cut to 1% (this volume holds no system state)
#   - errors=remount-ro so metadata corruption is contained, not propagated
#   - lazy_itable_init=0 pays the full mkfs cost up front instead of during
#     the first hours of production I/O
bootcmd:
  - [ cloud-init-per, once, mkpart, sgdisk, --new=1:0:0, --typecode=1:8e00, /dev/nvme1n1 ]

runcmd:
  - [ pvcreate, /dev/nvme1n1p1 ]
  - [ vgcreate, vg_data, /dev/nvme1n1p1 ]
  # Leave >=256 MiB free in the VG: e2scrub needs room for its snapshot.
  - [ lvcreate, --name, lv_data, --extents, 95%FREE, vg_data ]
  - |
    mke2fs -t ext4 \
      -L data \
      -m 1 \
      -i 8192 \
      -b 4096 \
      -O metadata_csum,metadata_csum_seed,64bit,dir_index,extent,dir_nlink \
      -E lazy_itable_init=0,lazy_journal_init=0,discard \
      /dev/vg_data/lv_data
  - [ tune2fs, -e, remount-ro, /dev/vg_data/lv_data ]
  - [ tune2fs, -c, "0", -i, "0", /dev/vg_data/lv_data ]
  - [ mkdir, -p, /srv/data ]

mounts:
  - [ "LABEL=data", "/srv/data", "ext4",
      "defaults,noatime,errors=remount-ro,nodev,nosuid", "0", "2" ]

write_files:
  - path: /etc/systemd/system/e2scrub_all.timer.d/override.conf
    content: |
      # Ship the distro's weekly online scrub, but move it off the
      # backup window and stop it racing other nodes in the same rack.
      [Timer]
      OnCalendar=
      OnCalendar=Sun 03:30
      RandomizedDelaySec=1800

runcmd_post:
  - [ systemctl, enable, --now, e2scrub_all.timer ]
```

### 3.2 `/etc/fstab` — el campo `passno` es una decisión de política

```
# <file system>            <mount point>  <type> <options>                                              <dump> <pass>
UUID=6b1f...  /              ext4   defaults,errors=remount-ro                             0      1
UUID=a3c9...  /boot          ext4   defaults,errors=remount-ro,nodev,nosuid,noexec         0      2
UUID=e7d2...  /var           ext4   defaults,noatime,errors=remount-ro,nodev,nosuid        0      2
LABEL=data                   /srv/data      ext4   defaults,noatime,errors=remount-ro,nodev,nosuid        0      2
LABEL=archive                /srv/archive   xfs    defaults,noatime,nodev,nosuid                          0      0
tmpfs                        /tmp           tmpfs  defaults,noatime,nodev,nosuid,noexec,size=2G,nr_inodes=200k 0 0
```

Reglas codificadas arriba:

- **`passno=1`** exactamente una vez, en `/`. Se chequea primero, solo.
- **`passno=2`** en los demás volúmenes ext4 — chequeados en paralelo entre *dispositivos físicos distintos* después de la pasada de la raíz.
- **`passno=0`** en XFS (el verificador es un no-op) y en `tmpfs`.
- `nr_inodes=200k` en `/tmp`: un `tmpfs` puede agotar los *inodos* mucho antes de agotar su `size=`, y una cantidad de inodos de `tmpfs` sin tope es un vector de agotamiento de memoria.

### 3.3 Reglas de alertas de Prometheus — espacio, inodos e integridad

```yaml
groups:
  - name: filesystem-capacity
    interval: 30s
    rules:
      # Rate of change matters more than the instantaneous level: a volume at
      # 60% that is filling at 5 GiB/h will page you at 03:00 unless you know now.
      - alert: FilesystemFillingUp
        expr: |
          (
            node_filesystem_avail_bytes{fstype=~"ext4|xfs|btrfs",mountpoint!~"/(run|var/lib/kubelet/pods).*"}
              / node_filesystem_size_bytes{fstype=~"ext4|xfs|btrfs"}
          ) < 0.25
          and
          predict_linear(
            node_filesystem_avail_bytes{fstype=~"ext4|xfs|btrfs"}[6h], 8 * 3600
          ) < 0
          and node_filesystem_readonly == 0
        for: 30m
        labels:
          severity: warning
          runbook: fs-capacity
        annotations:
          summary: "{{ $labels.mountpoint }} on {{ $labels.instance }} fills within 8h"
          description: >-
            {{ $value | humanizePercentage }} free and trending to zero.
            Run: du -x -h --max-depth=1 {{ $labels.mountpoint }} | sort -h | tail -20

      - alert: FilesystemSpaceCritical
        expr: |
          (
            node_filesystem_avail_bytes{fstype=~"ext4|xfs|btrfs"}
              / node_filesystem_size_bytes{fstype=~"ext4|xfs|btrfs"}
          ) < 0.05
          and node_filesystem_readonly == 0
        for: 5m
        labels:
          severity: critical
          runbook: fs-capacity
        annotations:
          summary: "{{ $labels.mountpoint }} on {{ $labels.instance }} below 5% free"
          description: >-
            Extent allocators degrade sharply past 95%. Check for
            deleted-but-open files first: lsof -nP +L1 | grep {{ $labels.mountpoint }}

      # Inode exhaustion is invisible to a bytes-only dashboard and produces
      # the identical ENOSPC errno. It must be a separate alert.
      - alert: FilesystemInodesCritical
        expr: |
          (
            node_filesystem_files_free{fstype=~"ext4|xfs"}
              / node_filesystem_files{fstype=~"ext4|xfs"}
          ) < 0.10
          and node_filesystem_files{fstype=~"ext4|xfs"} > 0
        for: 15m
        labels:
          severity: critical
          runbook: fs-inodes
        annotations:
          summary: "{{ $labels.mountpoint }} on {{ $labels.instance }} below 10% free inodes"
          description: >-
            ext4 inode counts are fixed at mkfs time and cannot be raised in
            place. Identify the offender:
            find {{ $labels.mountpoint }} -xdev -printf '%h\n' | sort | uniq -c | sort -rn | head

  - name: filesystem-integrity
    interval: 30s
    rules:
      # A read-only remount is the ext4 errors=remount-ro contract firing.
      # It is never routine on a volume mounted rw in fstab.
      - alert: FilesystemRemountedReadOnly
        expr: node_filesystem_readonly{fstype=~"ext4|xfs"} == 1
        for: 2m
        labels:
          severity: critical
          runbook: fs-corruption
        annotations:
          summary: "{{ $labels.mountpoint }} on {{ $labels.instance }} is read-only"
          description: >-
            Do NOT remount rw. Capture dmesg, drain the node, image the volume,
            then run e2fsck/xfs_repair offline.

      # Exported by the sentinel DaemonSet in 3.5 from the ext4 superblock
      # error counter (dumpe2fs -h). This counter is PERSISTENT: it survives
      # reboots and is only cleared by a successful e2fsck run.
      - alert: FilesystemSuperblockErrorsRecorded
        expr: increase(node_ext4_fs_error_count[24h]) > 0
        labels:
          severity: critical
          runbook: fs-corruption
        annotations:
          summary: "ext4 recorded {{ $value }} new metadata errors on {{ $labels.device }}"

      - alert: FilesystemScrubStale
        expr: |
          (time() - node_filesystem_last_scrub_timestamp_seconds) > 14 * 86400
        labels:
          severity: warning
          runbook: fs-scrub
        annotations:
          summary: "No successful scrub of {{ $labels.device }} in 14 days"

      # Correlate with the hardware layer: never "repair" dying media.
      - alert: DiskReallocatedSectorsGrowing
        expr: increase(smartmon_reallocated_sector_ct_raw_value[24h]) > 0
        labels:
          severity: critical
        annotations:
          summary: "{{ $labels.disk }} reallocated sectors growing — replace, do not repair"
```

### 3.4 systemd — verificación de integridad en línea vía snapshot LVM

`e2fsprogs` incluye `e2scrub`/`e2scrub_all` (y `xfsprogs` incluye `xfs_scrub_all`), y en una distribución soportada esas son las herramientas correctas. La unidad de abajo es el equivalente portable que cubre **tanto** ext4 como XFS en hosts donde tenés que manejar el snapshot vos mismo.

`/usr/local/sbin/fs-integrity-check`:

```bash
#!/usr/bin/env bash
# Point-in-time consistency check of a MOUNTED filesystem, with no downtime.
#
# Mechanism: take an LVM snapshot (atomic, crash-consistent), replay the
# journal/log into the snapshot by mounting it read-only once, then run the
# repair tool in dry-run mode against the now-clean snapshot. The production
# LV is never touched.
#
# Exit: 0 clean, 1 inconsistencies found, 2 could not run the check.
set -euo pipefail

VG=${1:?usage: fs-integrity-check <vg> <lv> [snapshot-size]}
LV=${2:?usage: fs-integrity-check <vg> <lv> [snapshot-size]}
SNAP_SIZE=${3:-4G}

SNAP="${LV}_scrub"
SNAP_DEV="/dev/${VG}/${SNAP}"
SRC_DEV="/dev/${VG}/${LV}"
MNT=$(mktemp -d /tmp/fs-scrub.XXXXXX)
TEXTFILE_DIR=/var/lib/node_exporter/textfile_collector

cleanup() {
    mountpoint -q "$MNT" && umount "$MNT" || true
    rmdir "$MNT" 2>/dev/null || true
    lvs "$SNAP_DEV" &>/dev/null && lvremove -f "$SNAP_DEV" >/dev/null || true
}
trap cleanup EXIT

emit_metric() {
    local status=$1
    install -d -m 0755 "$TEXTFILE_DIR"
    cat > "${TEXTFILE_DIR}/fs_scrub_${VG}_${LV}.prom.$$" <<EOF
# HELP node_filesystem_scrub_status 0=clean 1=inconsistent 2=error
# TYPE node_filesystem_scrub_status gauge
node_filesystem_scrub_status{device="${SRC_DEV}"} ${status}
# HELP node_filesystem_last_scrub_timestamp_seconds Unix time of last completed scrub
# TYPE node_filesystem_last_scrub_timestamp_seconds gauge
node_filesystem_last_scrub_timestamp_seconds{device="${SRC_DEV}"} ${EPOCHSECONDS}
EOF
    mv "${TEXTFILE_DIR}/fs_scrub_${VG}_${LV}.prom.$$" \
       "${TEXTFILE_DIR}/fs_scrub_${VG}_${LV}.prom"
}

FSTYPE=$(blkid -o value -s TYPE "$SRC_DEV")

# A snapshot that overflows its COW space is silently INVALIDATED and every
# read from it returns EIO. Refuse to start without room in the VG.
FREE_MB=$(vgs --noheadings --units m -o vg_free --nosuffix "$VG" | tr -d ' ' | cut -d. -f1)
NEED_MB=$(numfmt --from=iec "$SNAP_SIZE" | awk '{print int($1/1048576)}')
if (( FREE_MB < NEED_MB )); then
    echo "FATAL: VG ${VG} has ${FREE_MB}MiB free, need ${NEED_MB}MiB for the snapshot" >&2
    emit_metric 2; exit 2
fi

lvcreate --snapshot --size "$SNAP_SIZE" --name "$SNAP" "$SRC_DEV" >/dev/null
udevadm settle

# Replay the journal / log into the snapshot. Both ext4 and XFS perform
# recovery even on a read-only mount, which is exactly what we want: after
# this umount the snapshot is a cleanly-unmounted filesystem and the checkers
# will not refuse to run or report spurious "needs recovery" state.
case "$FSTYPE" in
    ext4|ext3|ext2) mount -o ro          "$SNAP_DEV" "$MNT" ;;
    xfs)            mount -o ro,nouuid   "$SNAP_DEV" "$MNT" ;;  # nouuid: duplicate UUID
    *) echo "FATAL: unsupported fstype ${FSTYPE}" >&2; emit_metric 2; exit 2 ;;
esac
umount "$MNT"

rc=0
case "$FSTYPE" in
    ext4|ext3|ext2)
        # -f force full check, -n answer no to everything (never writes)
        e2fsck -fn "$SNAP_DEV" || rc=$?
        # Bit 4 = errors left uncorrected; bit 1/2 cannot occur under -n.
        (( rc & 4 )) && rc=1 || rc=0
        ;;
    xfs)
        # -n = no modify. xfs_repair exits 1 when it would have made changes.
        xfs_repair -n "$SNAP_DEV" || rc=1
        ;;
esac

if (( rc == 0 )); then
    echo "CLEAN: ${SRC_DEV} (${FSTYPE})"
    emit_metric 0
else
    echo "INCONSISTENT: ${SRC_DEV} (${FSTYPE}) — schedule an offline repair window" >&2
    emit_metric 1
fi
exit "$rc"
```

`/etc/systemd/system/fs-integrity-check@.service`:

```ini
[Unit]
Description=Online integrity check of LVM volume %I (snapshot based)
Documentation=man:e2fsck(8) man:xfs_repair(8) man:lvcreate(8)
After=local-fs.target
ConditionPathExists=/usr/local/sbin/fs-integrity-check

[Service]
Type=oneshot
# %I is "vg--lv"; split it back into two arguments.
ExecStart=/bin/bash -c '/usr/local/sbin/fs-integrity-check "${0%%--*}" "${0##*--}"' %I
# The check is CPU and I/O heavy: keep it out of the way of production traffic.
Nice=19
IOSchedulingClass=idle
CPUSchedulingPolicy=idle
# e2fsck/xfs_repair on a large volume can take hours; no timeout kill.
TimeoutStartSec=infinity
# Least privilege: it needs device-mapper, mount and raw block access only.
PrivateNetwork=yes
ProtectHome=yes
ProtectKernelModules=yes
NoNewPrivileges=yes
SuccessExitStatus=0
```

`/etc/systemd/system/fs-integrity-check@.timer`:

```ini
[Unit]
Description=Weekly online integrity check of %I

[Timer]
OnCalendar=Sun 03:30
# Never let a whole rack scrub at the same instant.
RandomizedDelaySec=3600
Persistent=true
AccuracySec=1min

[Install]
WantedBy=timers.target
```

Habilitalo con el nombre de instancia escapado (`-` se escapa como `\x2d`, así que usá `--` como separador, tal como espera la unidad de arriba):

```bash
$ sudo systemctl enable --now 'fs-integrity-check@vg_data--lv_data.timer'
Created symlink /etc/systemd/system/timers.target.wants/fs-integrity-check@vg_data--lv_data.timer → /etc/systemd/system/fs-integrity-check@.timer
```

### 3.5 Kubernetes — presión de sistema de archivos a nivel de nodo y un DaemonSet centinela

El desalojo del kubelet es la expresión a nivel de clúster de "monitorear el espacio libre y los inodos". Notá que `imageGCHighThresholdPercent` debe ubicarse *por encima* del umbral de desalojo `imagefs.available`, si no el kubelet desaloja pods antes de llegar siquiera a recolectar imágenes.

```yaml
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
# Soft thresholds warn and give workloads a grace period to shed data;
# hard thresholds evict immediately. Both nodefs.available AND
# nodefs.inodesFree are required: a node can be at 20% disk usage and
# still be unable to create a single file.
evictionSoft:
  nodefs.available: "15%"
  nodefs.inodesFree: "10%"
  imagefs.available: "20%"
evictionSoftGracePeriod:
  nodefs.available: "2m"
  nodefs.inodesFree: "2m"
  imagefs.available: "2m"
evictionHard:
  nodefs.available: "10%"
  nodefs.inodesFree: "5%"
  imagefs.available: "15%"
  memory.available: "500Mi"
evictionMinimumReclaim:
  nodefs.available: "2Gi"
  nodefs.inodesFree: "50000"
  imagefs.available: "5Gi"
evictionPressureTransitionPeriod: 5m
imageGCHighThresholdPercent: 80
imageGCLowThresholdPercent: 70
imageMinimumGCAge: 2m
```

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: fs-integrity-sentinel
  namespace: monitoring
  labels:
    app.kubernetes.io/name: fs-integrity-sentinel
    app.kubernetes.io/component: node-agent
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: fs-integrity-sentinel
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 25%
  template:
    metadata:
      labels:
        app.kubernetes.io/name: fs-integrity-sentinel
    spec:
      hostPID: true
      priorityClassName: system-node-critical
      tolerations:
        - operator: Exists
      containers:
        - name: sentinel
          image: registry.example.com/platform/fs-sentinel:1.4.0
          command: ["/bin/bash", "-c"]
          args:
            - |
              set -euo pipefail
              OUT=/textfile/fs_integrity.prom
              while true; do
                : > "${OUT}.tmp"
                {
                  echo '# HELP node_ext4_fs_error_count Persistent ext4 superblock error counter'
                  echo '# TYPE node_ext4_fs_error_count counter'
                  echo '# HELP node_ext4_mount_count Mounts since last full check'
                  echo '# TYPE node_ext4_mount_count gauge'
                  echo '# HELP node_filesystem_last_check_timestamp_seconds Last e2fsck completion'
                  echo '# TYPE node_filesystem_last_check_timestamp_seconds gauge'
                } >> "${OUT}.tmp"

                # Enumerate real block-backed ext4 mounts from the host namespace.
                awk '$3 ~ /^ext[234]$/ && $1 ~ /^\/dev\// {print $1}' /host/proc/mounts \
                | sort -u | while read -r dev; do
                    hdr=$(dumpe2fs -h "$dev" 2>/dev/null) || continue
                    errs=$(awk -F: '/^FS Error count/ {gsub(/ /,"",$2); print $2}' <<<"$hdr")
                    mc=$(awk -F: '/^Mount count/ {gsub(/ /,"",$2); print $2}' <<<"$hdr")
                    lc=$(awk -F'Last checked:' '/^Last checked/ {print $2}' <<<"$hdr")
                    lc_epoch=$(date -d "${lc:-@0}" +%s 2>/dev/null || echo 0)
                    printf 'node_ext4_fs_error_count{device="%s"} %s\n' "$dev" "${errs:-0}" >> "${OUT}.tmp"
                    printf 'node_ext4_mount_count{device="%s"} %s\n' "$dev" "${mc:-0}" >> "${OUT}.tmp"
                    printf 'node_filesystem_last_check_timestamp_seconds{device="%s"} %s\n' "$dev" "$lc_epoch" >> "${OUT}.tmp"
                  done

                # Atomic publish: node_exporter must never read a half-written file.
                mv "${OUT}.tmp" "${OUT}"
                sleep 300
              done
          securityContext:
            # dumpe2fs reads the raw block device: CAP_SYS_RAWIO/root on the
            # device node is required. Everything else is dropped.
            runAsUser: 0
            privileged: false
            readOnlyRootFilesystem: true
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
              add: ["SYS_RAWIO", "DAC_READ_SEARCH"]
          resources:
            requests:
              cpu: 10m
              memory: 32Mi
            limits:
              memory: 64Mi
          volumeMounts:
            - name: proc
              mountPath: /host/proc
              readOnly: true
            - name: dev
              mountPath: /dev
            - name: textfile
              mountPath: /textfile
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: proc
          hostPath: { path: /proc, type: Directory }
        - name: dev
          hostPath: { path: /dev, type: Directory }
        - name: textfile
          hostPath: { path: /var/lib/node_exporter/textfile_collector, type: DirectoryOrCreate }
        - name: tmp
          emptyDir: { medium: Memory, sizeLimit: 16Mi }
```

### 3.6 Ansible — imponer la política en toda la flota

```yaml
---
- name: Enforce filesystem integrity policy on data nodes
  hosts: storage_nodes
  become: true
  gather_facts: true

  vars:
    fs_policy:
      - device: /dev/mapper/vg_data-lv_data
        mount: /srv/data
        fstype: ext4
        mkfs_opts: "-m 1 -i 8192 -O metadata_csum,64bit -E lazy_itable_init=0"
        mount_opts: "defaults,noatime,errors=remount-ro,nodev,nosuid"
        passno: 2
      - device: /dev/mapper/vg_arch-lv_arch
        mount: /srv/archive
        fstype: xfs
        mkfs_opts: "-m crc=1,finobt=1 -i maxpct=5"
        mount_opts: "defaults,noatime,nodev,nosuid"
        passno: 0            # fsck.xfs is a no-op; passno must be 0

  tasks:
    - name: Install filesystem tooling
      ansible.builtin.package:
        name: [e2fsprogs, xfsprogs, lvm2, smartmontools]
        state: present

    - name: Create filesystems with the policy geometry
      community.general.filesystem:
        fstype: "{{ item.fstype }}"
        dev: "{{ item.device }}"
        opts: "{{ item.mkfs_opts }}"
        state: present
      loop: "{{ fs_policy }}"
      loop_control:
        label: "{{ item.device }}"

    - name: Contain ext4 metadata errors by remounting read-only
      ansible.builtin.command:
        cmd: "tune2fs -e remount-ro {{ item.device }}"
      register: tune_errbehav
      changed_when: "'Setting error behavior' in tune_errbehav.stdout"
      loop: "{{ fs_policy | selectattr('fstype', 'eq', 'ext4') | list }}"
      loop_control:
        label: "{{ item.device }}"

    - name: Disable mount-count and time-based boot fsck on data volumes
      # Boot-time fsck on a 12 TiB volume is an unbounded outage. Integrity is
      # verified online by the weekly snapshot scrub instead.
      ansible.builtin.command:
        cmd: "tune2fs -c 0 -i 0 {{ item.device }}"
      register: tune_sched
      changed_when: "'Setting' in tune_sched.stdout"
      loop: "{{ fs_policy | selectattr('fstype', 'eq', 'ext4') | list }}"
      loop_control:
        label: "{{ item.device }}"

    - name: Mount according to policy and persist in /etc/fstab
      ansible.posix.mount:
        path: "{{ item.mount }}"
        src: "{{ item.device }}"
        fstype: "{{ item.fstype }}"
        opts: "{{ item.mount_opts }}"
        dump: "0"
        passno: "{{ item.passno | string }}"
        state: mounted
      loop: "{{ fs_policy }}"
      loop_control:
        label: "{{ item.mount }}"

    - name: Install the online integrity checker
      ansible.builtin.copy:
        src: fs-integrity-check
        dest: /usr/local/sbin/fs-integrity-check
        mode: "0750"
        owner: root
        group: root

    - name: Install the checker units
      ansible.builtin.copy:
        src: "{{ item }}"
        dest: "/etc/systemd/system/{{ item }}"
        mode: "0644"
      loop:
        - fs-integrity-check@.service
        - fs-integrity-check@.timer
      notify: reload systemd

    - name: Schedule the weekly scrub per LVM volume
      ansible.builtin.systemd:
        name: "fs-integrity-check@{{ item.device | regex_replace('^/dev/mapper/([^-]+)-(.+)$', '\\1--\\2') }}.timer"
        enabled: true
        state: started
        daemon_reload: true
      loop: "{{ fs_policy }}"
      loop_control:
        label: "{{ item.device }}"

    - name: Assert every ext4 volume has a clean superblock error counter
      ansible.builtin.shell:
        cmd: "dumpe2fs -h {{ item.device }} 2>/dev/null | awk -F: '/^FS Error count/ {gsub(/ /,\"\",$2); print $2}'"
      register: fs_errors
      changed_when: false
      failed_when: fs_errors.stdout | default('0') | int > 0
      loop: "{{ fs_policy | selectattr('fstype', 'eq', 'ext4') | list }}"
      loop_control:
        label: "{{ item.device }}"

  handlers:
    - name: reload systemd
      ansible.builtin.systemd:
        daemon_reload: true
```

---

## 4. Referencia de CLI con salida real de terminal

### 4.1 `df` — monitorear espacio libre e inodos

```
$ df -hT -x tmpfs -x devtmpfs -x squashfs
Filesystem              Type  Size  Used Avail Use% Mounted on
/dev/nvme0n1p2          ext4   98G   71G   22G  77% /
/dev/nvme0n1p1          vfat  511M  6.1M  505M   2% /boot/efi
/dev/mapper/vg_data-lv_data ext4  1.8T  1.7T   18G  99% /srv/data
/dev/mapper/vg_arch-lv_arch xfs   9.1T  4.2T  4.9T  47% /srv/archive
```

La vista de inodos es una **pregunta separada** y debe hacerse por separado:

```
$ df -i -x tmpfs -x devtmpfs
Filesystem                   Inodes   IUsed     IFree IUse% Mounted on
/dev/nvme0n1p2              6553600  412337   6141263    7% /
/dev/mapper/vg_data-lv_data 244195328 243980112  215216  100% /srv/data
/dev/mapper/vg_arch-lv_arch 1907143104 3221844 1903921260   1% /srv/archive
```

`/srv/data` está al **100% de inodos** — las escrituras ahí ya fallan con `ENOSPC` sin importar los 18 GiB de bloques libres. Notá la fila de XFS: XFS asigna inodos dinámicamente, así que `Inodes` es una *proyección* basada en `imaxpct` y el espacio libre, no un número fijo. Se mueve a medida que el sistema de archivos se llena.

Un solo comando que responde ambas preguntas a la vez, que es lo que corresponde tener en un runbook:

```
$ df -h --output=source,fstype,size,used,avail,pcent,itotal,iused,ipcent,target \
     -x tmpfs -x devtmpfs -x overlay
Filesystem                  Type  Size  Used Avail Use% Inodes IUsed IUse% Mounted on
/dev/nvme0n1p2              ext4   98G   71G   22G  77%   6.3M  403K    7% /
/dev/mapper/vg_data-lv_data ext4  1.8T  1.7T   18G  99%   233M  233M  100% /srv/data
/dev/mapper/vg_arch-lv_arch xfs   9.1T  4.2T  4.9T  47%   1.8G  3.1M    1% /srv/archive
```

Los bloques reservados son visibles como la diferencia entre "free" y "available":

```
$ df -B1 --output=size,used,avail /srv/data | tail -1
   1976579796992  1834429874176      18874368000

$ echo "size - used - avail = reserved"
$ python3 -c "print((1976579796992-1834429874176-18874368000)/2**30, 'GiB reserved')"
115.0 GiB reserved
```

### 4.2 `du` — atribuir el consumo

```
$ sudo du -x -h --max-depth=1 /var 2>/dev/null | sort -h
1.1M	/var/spool
4.0M	/var/tmp
18M	/var/cache
392M	/var/backups
2.1G	/var/lib
41G	/var/log
44G	/var
```

Descendé hacia el culpable, un nivel por vez. `-x` no es opcional: sin él `du` cruza hacia cada sistema de archivos montado por debajo y los números pierden sentido.

```
$ sudo du -x -h --max-depth=1 /var/log | sort -h | tail -6
216M	/var/log/journal
1.4G	/var/log/nginx
2.9G	/var/log/audit
36G	/var/log/app
41G	/var/log
```

Los archivos individuales más grandes, que `du` no te va a mostrar directamente:

```
$ sudo find /var/log -xdev -type f -size +500M -printf '%s\t%TY-%Tm-%Td\t%p\n' \
    | sort -rn | numfmt --to=iec --field=1
19G	2026-08-26	/var/log/app/debug.log
8.4G	2026-08-19	/var/log/app/debug.log.1
5.1G	2026-08-24	/var/log/audit/audit.log
```

La trampa de los archivos dispersos — `du` y `ls` no coinciden, y ambos tienen razón:

```
$ ls -lh /srv/data/vm/disk0.qcow2
-rw-r--r-- 1 qemu qemu 500G Aug 26 09:14 /srv/data/vm/disk0.qcow2

$ du -h /srv/data/vm/disk0.qcow2
47G	/srv/data/vm/disk0.qcow2

$ du -h --apparent-size /srv/data/vm/disk0.qcow2
500G	/srv/data/vm/disk0.qcow2
```

`ls -l` y `du --apparent-size` reportan `i_size` (la longitud lógica). `du` a secas reporta bloques asignados. Solo lo segundo es lo que el sistema de archivos está gastando realmente.

### 4.3 El incidente clásico: `df` lleno, `du` dice otra cosa

```
$ df -h /var
Filesystem      Size  Used Avail Use% Mounted on
/dev/mapper/vg0-var  50G   49G     0 100% /var

$ sudo du -xsh /var
12G	/var
```

37 GiB sin explicación. Los bloques están asignados a inodos con `i_links_count == 0` que siguen abiertos — el archivo fue desenlazado pero todavía no liberado:

```
$ sudo lsof -nP +L1
COMMAND     PID  USER   FD   TYPE DEVICE   SIZE/OFF NLINK    NODE NAME
java      21847   app    3w   REG  253,3 21474836480     0  786434 /var/log/app/debug.log (deleted)
java      21847   app    7w   REG  253,3 16106127360     0  786441 /var/log/app/trace.log (deleted)
```

`NLINK 0` es la firma. Alguien borró los logs para "liberar espacio" mientras la JVM todavía los tenía abiertos — el espacio no se devuelve hasta que se cierra el último descriptor de archivo. Recuperalo **sin reiniciar el proceso** truncando a través de `/proc`:

```
$ sudo truncate -s 0 /proc/21847/fd/3
$ sudo truncate -s 0 /proc/21847/fd/7
$ df -h /var
Filesystem      Size  Used Avail Use% Mounted on
/dev/mapper/vg0-var  50G   12G   36G  26% /var
```

La otra forma de la misma discrepancia — archivos escondidos debajo de un punto de montaje:

```
$ sudo mkdir -p /mnt/rootcheck
$ sudo mount --bind / /mnt/rootcheck
$ sudo du -xsh /mnt/rootcheck/var
28G	/mnt/rootcheck/var          # <- 28 GiB written to /var BEFORE the LV was mounted over it
$ sudo umount /mnt/rootcheck
```

### 4.4 Agotamiento de inodos

```
$ df -i /srv/data
Filesystem                     Inodes     IUsed  IFree IUse% Mounted on
/dev/mapper/vg_data-lv_data 244195328 244195328      0  100% /srv/data

$ sudo -u app touch /srv/data/probe
touch: cannot touch '/srv/data/probe': No space left on device

$ df -h /srv/data
Filesystem                   Size  Used Avail Use% Mounted on
/dev/mapper/vg_data-lv_data  1.8T  1.7T   18G  99% /srv/data
```

`ENOSPC` con 18 GiB libres. Localizá el directorio que concentra la cantidad de archivos:

```
$ sudo find /srv/data -xdev -printf '%h\n' | sort | uniq -c | sort -rn | head -5
 8412339 /srv/data/cache/sessions
  241887 /srv/data/uploads/thumbs
   19204 /srv/data/tmp
```

Conteos por subárbol, que es lo que realmente querés al inicio de un incidente:

```
$ for d in /srv/data/*/; do
>   printf '%10d  %s\n' "$(sudo find "$d" -xdev | wc -l)" "$d"
> done | sort -rn
   8412512  /srv/data/cache/
    243901  /srv/data/uploads/
     19204  /srv/data/tmp/
      1174  /srv/data/vm/
```

**Consecuencia arquitectónica:** en ext4 la cantidad de inodos queda fija al momento del `mke2fs` y **no puede aumentarse en el lugar**. `resize2fs` agrega inodos solo cuando se *agranda* el sistema de archivos (cada nuevo grupo de bloques aporta `Inodes per group` más). Si agrandar no es una opción, el arreglo es una reconstrucción con un `-i`/`-N` distinto, lo que implica una migración completa de datos. Modelá el perfil de cantidad de archivos antes del `mkfs`, no después:

```
$ sudo tune2fs -l /dev/mapper/vg_data-lv_data | grep -E 'Inode count|Block count|Block size'
Inode count:              244195328
Block count:              488390656
Block size:               4096

$ python3 -c "print(488390656*4096//244195328, 'bytes per inode')"
8192 bytes per inode
```

XFS no tiene este modo de falla de la misma manera — los inodos se asignan por demanda — pero tiene su propio techo:

```
$ xfs_info /srv/archive | head -3
meta-data=/dev/mapper/vg_arch-lv_arch isize=512    agcount=32, agsize=76288000 blks
         =                       sectsz=512   attr=2, projid32bit=1
data     =                       bsize=4096   blocks=2441216000, imaxpct=5

$ sudo xfs_growfs -m 25 /srv/archive        # raise the inode-space cap to 25%
meta-data=/dev/mapper/vg_arch-lv_arch isize=512 agcount=32, agsize=76288000 blks
...
inode max percent changed from 5 to 25
```

### 4.5 `tune2fs` y `dumpe2fs` — leer y dirigir la política de ext4

```
$ sudo tune2fs -l /dev/mapper/vg_data-lv_data
tune2fs 1.47.0 (5-Feb-2023)
Filesystem volume name:   data
Last mounted on:          /srv/data
Filesystem UUID:          6b1f9c2e-4a77-4d31-9f0b-3c8a51e2d904
Filesystem magic number:  0xEF53
Filesystem revision #:    1 (dynamic)
Filesystem features:      has_journal ext_attr resize_inode dir_index filetype extent 64bit flex_bg sparse_super large_file huge_file dir_nlink extra_isize metadata_csum
Filesystem flags:         signed_directory_hash 
Default mount options:    user_xattr acl
Filesystem state:         clean
Errors behavior:          Remount read-only
Filesystem OS type:       Linux
Inode count:              244195328
Block count:              488390656
Reserved block count:     4883906
Free blocks:              4611893
Free inodes:              0
First block:              0
Block size:               4096
Fragment size:            4096
Group descriptor size:    64
Blocks per group:         32768
Inodes per group:         16384
Inode blocks per group:   1024
Flex block group size:    16
Filesystem created:       Mon Mar  3 11:04:22 2026
Last mount time:          Tue Aug 11 07:41:09 2026
Last write time:          Wed Aug 26 09:22:41 2026
Mount count:              41
Maximum mount count:      -1
Last checked:             Mon Mar  3 11:04:22 2026
Check interval:           0 (<none>)
Lifetime writes:          14 TB
Reserved blocks uid:      0 (user root)
Reserved blocks gid:      0 (group root)
First inode:              11
Inode size:	          256
Journal inode:            8
Default directory hash:   half_md4
Checksum type:            crc32c
```

Leé esto como un SRE:

- `Filesystem state: clean` — el fs fue desmontado limpiamente o está actualmente montado y consistente. `not clean` o `clean with errors` significa que se debe un chequeo.
- `Errors behavior: Remount read-only` — la política de §2.4 está en vigencia.
- `Maximum mount count: -1` y `Check interval: 0` — sin fsck automático en el arranque. Deliberado, y significa que el scrub en línea ahora es obligatorio, no opcional.
- `Free inodes: 0` — el incidente de §4.4, visible directamente en el superbloque.
- `Lifetime writes: 14 TB` — útil para correlacionar con la resistencia de los SSD.

El contador persistente de errores (presente solo una vez que han ocurrido errores) es el campo de mayor señal de todo el sistema:

```
$ sudo dumpe2fs -h /dev/sdc1 2>/dev/null | grep -A6 'FS Error count'
FS Error count:           7
First error time:         Mon Aug 17 03:12:44 2026
First error function:     ext4_journal_check_start
First error line #:       83
First error inode #:      0
First error block #:      0
Last error time:          Sat Aug 22 19:08:03 2026
Last error function:      ext4_lookup
Last error line #:        1852
Last error inode #:       1310721
Last error block #:       0
```

Este contador vive en el superbloque, **sobrevive a los reinicios**, y solo lo limpia un `e2fsck` exitoso. Un nodo reiniciado cuyo "problema se fue solo" todavía lleva la evidencia acá. Esto es precisamente lo que exporta el DaemonSet centinela de §3.5.

Cambios de política:

```
$ sudo tune2fs -e remount-ro /dev/sdc1
tune2fs 1.47.0 (5-Feb-2023)
Setting error behavior to 2

$ sudo tune2fs -m 1 /dev/mapper/vg_data-lv_data
tune2fs 1.47.0 (5-Feb-2023)
Setting reserved blocks percentage to 1% (4883906 blocks)

$ sudo tune2fs -c 30 -i 0 /dev/sdc1
tune2fs 1.47.0 (5-Feb-2023)
Setting maximal mount count to 30
Setting interval between checks to 0 seconds

$ sudo tune2fs -C 31 /dev/sdc1        # force a check on the NEXT boot
tune2fs 1.47.0 (5-Feb-2023)
Setting current mount count to 31
```

| Flag de `tune2fs` | Efecto |
|---|---|
| `-l` | Listar el contenido del superbloque |
| `-c N` | Cantidad máxima de montajes antes de un chequeo forzado (`0`/`-1` lo desactiva) |
| `-C N` | Fijar la cantidad de montajes *actual* — el truco para forzar un chequeo en el próximo arranque |
| `-i D[d\|w\|m]` | Intervalo de chequeo por tiempo (`0` lo desactiva) |
| `-e continue\|remount-ro\|panic` | Comportamiento ante errores |
| `-m N` | Porcentaje de bloques reservados |
| `-r N` | Cantidad absoluta de bloques reservados |
| `-L label` / `-U uuid` | Etiqueta / UUID |
| `-j` | Agregar un journal a un sistema de archivos ext2 (ext2 → ext3) |
| `-o [^]opt` | Opciones de montaje por defecto almacenadas en el superbloque |
| `-O [^]feature` | Activar/desactivar una característica; la mayoría requiere el fs desmontado **y** un `e2fsck -f` posterior |

**Precaución:** `tune2fs -O` sobre un sistema de archivos montado, o sin el `e2fsck -f` obligatorio de seguimiento, es una manera documentada de corromper un volumen que por lo demás estaba sano. `tune2fs` te lo dice y después lo hace igual si insistís.

### 4.6 `mke2fs` — decisiones de geometría y el truco del superbloque de respaldo

Siempre hacé primero una corrida en seco. `-n` no crea nada e imprime exactamente lo que construiría, **incluidas las ubicaciones de los superbloques de respaldo que vas a necesitar si el primario se destruye**:

```
$ sudo mke2fs -n -t ext4 -i 8192 -m 1 /dev/sdd1
mke2fs 1.47.0 (5-Feb-2023)
Creating filesystem with 262144000 4k blocks and 131072000 inodes
Filesystem UUID: 9a3d51c7-8e12-4f6b-b0a2-77c4e91d3fa8
Superblock backups stored on blocks: 
	32768, 98304, 163840, 229376, 294912, 819200, 884736, 1605632, 2654208, 
	4096000, 7962624, 11239424, 20480000, 23887872, 71663616, 78675968, 
	102400000, 214990848

$ sudo mke2fs -n /dev/sdd1 > /root/sdd1-superblock-backups.txt
```

Registrá esa salida antes de un incidente, no durante. También es recuperable después con `dumpe2fs`, pero solo si el superbloque primario todavía es legible — que es exactamente el caso en el que no lo necesitás.

| Opción de `mke2fs` | Propósito | Guía del SRE |
|---|---|---|
| `-b 1024\|2048\|4096` | Tamaño de bloque | Dejalo en 4096 (coincide con el tamaño de página); menor solo para volúmenes diminutos |
| `-i bytes` | Bytes por inodo | La elección más consecuente de todas. Por defecto 16384; usá 8192 o 4096 para cargas de maildir/sesiones/caché |
| `-N count` | Cantidad absoluta de inodos | Usalo cuando conocés la cantidad de archivos con exactitud |
| `-m percent` | Bloques reservados | 5 por defecto; 1 o 0 solo en volúmenes de datos puros |
| `-T type` | Perfil de uso desde `/etc/mke2fs.conf` (`news`, `largefile`, `largefile4`) | `-T largefile4` = 4 MiB/inodo para almacenes de video/backup |
| `-O feature[,...]` | Conjunto de características; `^x` desactiva | Mantené `metadata_csum`, `64bit`; nunca desactives `has_journal` en producción |
| `-E lazy_itable_init=0,lazy_journal_init=0` | Escribir todas las tablas de inodos al momento del mkfs | Pagá el costo una vez en lugar de durante la I/O de producción |
| `-E stride=N,stripe_width=M` | Alineación RAID | La desalineación en RAID5/6 causa read-modify-write en cada actualización de metadatos |
| `-E discard` | Hacer TRIM del dispositivo primero | Volúmenes SSD / con aprovisionamiento fino |
| `-c` / `-cc` | Escaneo badblocks de solo lectura / lectura-escritura no destructivo | Lento; los discos modernos se auto-remapean — preferí `smartctl` |
| `-n` | Corrida en seco | Siempre, primero |

Ejemplo trabajado de alineación RAID — un RAID6 de 6 discos (4 discos de datos), chunk de 512 KiB, bloques de 4 KiB:

```
$ python3 -c "print('stride =', 512*1024//4096, ' stripe_width =', (512*1024//4096)*4)"
stride = 128  stripe_width = 512

$ sudo mke2fs -t ext4 -b 4096 -E stride=128,stripe_width=512 -m 0 /dev/md0
mke2fs 1.47.0 (5-Feb-2023)
Creating filesystem with 5859373056 4k blocks and 366210048 inodes
Filesystem UUID: c40e8a1b-...
Superblock backups stored on blocks: 
	32768, 98304, 163840, 229376, 294912, 819200, 884736, 1605632, 2654208, ...
Allocating group tables: done                            
Writing inode tables: done                            
Creating journal (262144 blocks): done
Writing superblocks and filesystem accounting information: done
```

### 4.7 `fsck` y `e2fsck` — reparar sistemas de archivos ext

`fsck` es un **despachador**. Lee el tipo desde `/etc/fstab` o `blkid` y ejecuta `fsck.<type>`; cada opción después de `--` va al backend.

```
$ sudo fsck -N /dev/sdc1
fsck from util-linux 2.38.1
[/usr/sbin/fsck.ext4 (1) -- /dev/sdc1] fsck.ext4 /dev/sdc1
```

**Regla cero: nunca corras una reparación sobre un sistema de archivos montado.** `e2fsck` avisa; si continuás, el estado en memoria del kernel y el estado en disco divergen y el sistema de archivos queda destruido.

```
$ sudo e2fsck -f /dev/mapper/vg_data-lv_data
e2fsck 1.47.0 (5-Feb-2023)
/dev/mapper/vg_data-lv_data is mounted.
e2fsck: Cannot continue, aborting.
```

La secuencia correcta en una reparación real:

```
$ sudo systemctl stop app.service
$ sudo umount /srv/data
umount: /srv/data: target is busy.

$ sudo fuser -vm /srv/data
                     USER        PID ACCESS COMMAND
/srv/data:           root     kernel mount /srv/data
                     app        3128 F..c. java

$ sudo systemctl stop app-worker.service
$ sudo umount /srv/data
$ mountpoint /srv/data
/srv/data is not a mountpoint
```

Antes de tocar nada, capturá los metadatos. `e2image` escribe una imagen dispersa de *solo* los metadatos — típicamente unos pocos cientos de MiB incluso para volúmenes de varios TiB — y es tu único deshacer:

```
$ sudo e2image -r /dev/mapper/vg_data-lv_data /var/backups/data-meta-$(date +%F).img
e2image 1.47.0 (5-Feb-2023)

$ ls -lh --apparent-size /var/backups/data-meta-2026-08-26.img
-rw------- 1 root root 1.8T Aug 26 09:41 /var/backups/data-meta-2026-08-26.img
$ du -h /var/backups/data-meta-2026-08-26.img
612M	/var/backups/data-meta-2026-08-26.img
```

Después, una pasada de evaluación **de solo lectura**. `-f` fuerza un chequeo completo aunque el superbloque diga clean; `-n` responde "no" a cada pregunta y nunca escribe:

```
$ sudo e2fsck -fn /dev/mapper/vg_data-lv_data
e2fsck 1.47.0 (5-Feb-2023)
Pass 1: Checking inodes, blocks, and sizes
Inode 1310721, i_blocks is 48, should be 40.  Fix? no

Pass 2: Checking directory structure
Entry 'session-4a91.tmp' in /cache/sessions (1310722) has deleted/unused inode 1441795.  Clear? no

Pass 3: Checking directory connectivity
Unconnected directory inode 1572865 (was in /cache)
Connect to /lost+found? no

Pass 4: Checking reference counts
Inode 1310721 ref count is 3, should be 2.  Fix? no

Pass 5: Checking group summary information
Block bitmap differences:  -(1310730--1310737)
Fix? no

Free blocks count wrong for group #40 (18234, counted=18242).
Fix? no

Free blocks count wrong (4611893, counted=4611901).
Fix? no


/dev/mapper/vg_data-lv_data: ********** WARNING: Filesystem still has errors **********

/dev/mapper/vg_data-lv_data: 244195328/244195328 files (0.3% non-contiguous), 483778763/488390656 blocks
$ echo $?
4
```

Esta es exactamente la foto de un crash durante el writeback: un puñado de desajustes de contabilidad, un directorio huérfano, una entrada de directorio colgada. Ahora reparemos de verdad:

```
$ sudo e2fsck -fy /dev/mapper/vg_data-lv_data
e2fsck 1.47.0 (5-Feb-2023)
Pass 1: Checking inodes, blocks, and sizes
Inode 1310721, i_blocks is 48, should be 40.  Fix? yes

Pass 2: Checking directory structure
Entry 'session-4a91.tmp' in /cache/sessions (1310722) has deleted/unused inode 1441795.  Clear? yes

Pass 3: Checking directory connectivity
Unconnected directory inode 1572865 (was in /cache)
Connect to /lost+found? yes

Inode 1572865 ref count is 2, should be 3.  Fix? yes

Pass 4: Checking reference counts
Inode 1310721 ref count is 3, should be 2.  Fix? yes

Pass 5: Checking group summary information
Block bitmap differences:  -(1310730--1310737)
Fix? yes

Free blocks count wrong for group #40 (18234, counted=18242).
Fix? yes

Free blocks count wrong (4611893, counted=4611901).
Fix? yes


/dev/mapper/vg_data-lv_data: ***** FILE SYSTEM WAS MODIFIED *****
/dev/mapper/vg_data-lv_data: 244195327/244195328 files (0.3% non-contiguous), 483778755/488390656 blocks
$ echo $?
1
```

Salida 1 = errores encontrados y corregidos. Verificá con una segunda pasada — una reparación limpia siempre converge a salida 0:

```
$ sudo e2fsck -fn /dev/mapper/vg_data-lv_data
e2fsck 1.47.0 (5-Feb-2023)
Pass 1: Checking inodes, blocks, and sizes
Pass 2: Checking directory structure
Pass 3: Checking directory connectivity
Pass 4: Checking reference counts
Pass 5: Checking group summary information
/dev/mapper/vg_data-lv_data: 244195327/244195328 files (0.3% non-contiguous), 483778755/488390656 blocks
$ echo $?
0
```

**Si la segunda pasada no sale limpia, pará.** La no convergencia repetida significa que el dispositivo subyacente está devolviendo datos distintos en cada lectura — un problema de hardware, no de sistema de archivos. Seguir corriendo `e2fsck` sobre un medio que falla muele los datos buenos que quedan hacia `lost+found`.

Revisá qué reubicó la reparación:

```
$ sudo mount /srv/data
$ sudo ls -la /srv/data/lost+found | head
total 132
drwx------   3 root root  16384 Mar  3 11:04 .
drwxr-xr-x  12 root root   4096 Aug 26 09:44 ..
drwxr-xr-x   2 app  app    4096 Aug 24 18:21 #1572865
```

Los archivos en `lost+found` se nombran según su número de inodo; sus entradas de directorio — y por lo tanto sus nombres y rutas — desaparecieron. Identificalos por contenido (`file`, `head`, números mágicos) y por mtime.

#### Recuperarse de un superbloque primario destruido

```
$ sudo mount /dev/sdd1 /mnt/restore
mount: /mnt/restore: wrong fs type, bad option, bad superblock on /dev/sdd1, missing codepage or helper program, or other error.
       dmesg(1) may have more information after failed mount system call.

$ sudo dmesg | tail -2
[ 8814.203117] EXT4-fs (sdd1): VFS: Can't find ext4 filesystem
```

Recuperá las ubicaciones de respaldo (esto funciona incluso sin un primario legible porque `mke2fs -n` recomputa el layout de forma determinista a partir de los mismos parámetros), y después apuntá `e2fsck` a una de ellas:

```
$ sudo mke2fs -n /dev/sdd1
mke2fs 1.47.0 (5-Feb-2023)
Creating filesystem with 262144000 4k blocks and 131072000 inodes
Superblock backups stored on blocks: 
	32768, 98304, 163840, 229376, 294912, 819200, 884736, 1605632, 2654208, ...

$ sudo e2fsck -b 32768 -B 4096 -y /dev/sdd1
e2fsck 1.47.0 (5-Feb-2023)
/dev/sdd1 was not cleanly unmounted, check forced.
Pass 1: Checking inodes, blocks, and sizes
Pass 2: Checking directory structure
Pass 3: Checking directory connectivity
Pass 4: Checking reference counts
Pass 5: Checking group summary information
Free blocks count wrong for group #0 (24576, counted=24575).
Fix? yes

/dev/sdd1: ***** FILE SYSTEM WAS MODIFIED *****
/dev/sdd1: 1247/131072000 files (0.1% non-contiguous), 8412337/262144000 blocks
```

`-b` selecciona el superbloque de respaldo; `-B` declara el tamaño de bloque explícitamente porque no puede leerse desde un primario destruido. Una corrida exitosa **reescribe el superbloque reparado en la ubicación primaria**. A `mke2fs -n` hay que darle los *mismos* parámetros con los que se creó el sistema de archivos, o los desplazamientos de respaldo calculados serán incorrectos.

| Opción de `e2fsck` | Significado | Nota de producción |
|---|---|---|
| `-n` | Responder no a todo; abrir de solo lectura | La primera pasada obligatoria |
| `-p` | Preen: arreglar solo problemas inequívocamente seguros, no interactivo | Lo que usa el `fsck -a` del arranque; sale con 4 ante cualquier cosa que requiera criterio |
| `-y` | Responder sí a todo | Solo después de `-n` y después de un respaldo con `e2image` |
| `-f` | Forzar un chequeo completo aunque esté marcado como limpio | Siempre, cuando chequeás a propósito |
| `-c` / `-cc` | Correr `badblocks` de solo lectura / lectura-escritura no destructivo | Muy lento; preferí SMART |
| `-b N` / `-B N` | Superbloque de respaldo / tamaño de bloque | Recuperación del superbloque primario |
| `-D` | Optimizar y compactar directorios | Útil después de un borrado masivo en directorios enormes |
| `-E discard` | Hacer TRIM de los bloques liberados | Aprovisionamiento fino / SSD |

### 4.8 XFS — `xfs_repair`, `xfs_db`, `xfs_fsr`

XFS no se chequea en el arranque. Confirmalo vos mismo:

```
$ cat /usr/sbin/fsck.xfs
#!/bin/sh
# Copyright (c) 2002 Silicon Graphics, Inc.  All Rights Reserved.
#
# Just for the record, XFS never needs fsck.
...
exit 0
```

Salud y geometría de un XFS montado:

```
$ xfs_info /srv/archive
meta-data=/dev/mapper/vg_arch-lv_arch isize=512    agcount=32, agsize=76288000 blks
         =                       sectsz=512   attr=2, projid32bit=1
         =                       crc=1        finobt=1, sparse=1, rmapbt=0
         =                       reflink=1    bigtime=1 inobtcount=1 nrext64=0
data     =                       bsize=4096   blocks=2441216000, imaxpct=5
         =                       sunit=0      swidth=0 blks
naming   =version 2              bsize=4096   ascii-ci=0, ftype=1
log      =internal log           bsize=4096   blocks=521728, version=2
         =                       sectsz=512   sunit=0 blks, lazy-count=1
realtime =none                   extsz=4096   blocks=0, rtextents=0
```

`crc=1` significa que los checksums de metadatos están activos — la corrupción se *detecta* en lugar de consumirse silenciosamente. `agcount=32` es la unidad de paralelismo: los grupos de asignación se bloquean de forma independiente, y también son la unidad de trabajo y de memoria de `xfs_repair`.

La evaluación de solo lectura. `xfs_repair -n` **requiere que el sistema de archivos esté desmontado** e informa sin modificar:

```
$ sudo umount /srv/archive
$ sudo xfs_repair -n /dev/mapper/vg_arch-lv_arch
Phase 1 - find and verify superblock...
Phase 2 - using internal log
        - zero log...
        - scan filesystem freespace and inode maps...
        - found root inode chunk
Phase 3 - for each AG...
        - scan (but don't clear) agi unlinked lists...
        - process known inodes and perform inode discovery...
        - agno = 0
        - agno = 1
        - agno = 2
        - agno = 3
        - process newly discovered inodes...
Phase 4 - check for duplicate blocks...
        - setting up duplicate extent list...
        - check for inodes claiming duplicate blocks...
        - agno = 0
        - agno = 1
        - agno = 2
        - agno = 3
No modify flag set, skipping phase 5
Phase 6 - check inode connectivity...
        - traversing filesystem ...
        - traversal finished ...
        - moving disconnected inodes to lost+found ...
disconnected inode 1074266112, would move to lost+found
Phase 7 - verify link counts...
would have reset inode 1074266112 nlinks from 0 to 1
No modify flag set, skipping filesystem flush and exiting.
$ echo $?
1
```

Cada mensaje bajo `-n` es condicional ("would move", "would have reset"). Salida 1 significa que hacen falta cambios.

El caso del log sucio, y el único flag genuinamente peligroso de todo este tema:

```
$ sudo xfs_repair /dev/mapper/vg_arch-lv_arch
Phase 1 - find and verify superblock...
Phase 2 - using internal log
        - zero log...
ERROR: The filesystem has valuable metadata changes in a log which needs to
be replayed.  Mount the filesystem to replay the log, and unmount it before
re-running xfs_repair.  If you are unable to mount the filesystem, then use
the -L option to destroy the log and attempt a repair.
Note that destroying the log may cause corruption -- please attempt a mount
of the filesystem before doing this.
```

La herramienta te está diciendo el procedimiento correcto. **Hacelo:**

```
$ sudo mount /dev/mapper/vg_arch-lv_arch /srv/archive
$ sudo umount /srv/archive
$ sudo xfs_repair /dev/mapper/vg_arch-lv_arch
Phase 1 - find and verify superblock...
Phase 2 - using internal log
        - zero log...
        - scan filesystem freespace and inode maps...
        - found root inode chunk
Phase 3 - for each AG...
        - scan and clear agi unlinked lists...
        - process known inodes and perform inode discovery...
        - agno = 0
        - agno = 1
        - process newly discovered inodes...
Phase 4 - check for duplicate blocks...
        - setting up duplicate extent list...
        - check for inodes claiming duplicate blocks...
Phase 5 - rebuild AG headers and trees...
        - reset superblock...
Phase 6 - check inode connectivity...
        - resetting contents of realtime bitmap and summary inodes
        - traversing filesystem ...
        - traversal finished ...
        - moving disconnected inodes to lost+found ...
disconnected inode 1074266112, moving to lost+found
Phase 7 - verify and correct link counts...
Note - stripe unit (0) and width (0) were copied from a backup superblock.
Please reset with mount -o sunit=<value>,swidth=<value> if necessary
done
```

`xfs_repair -L` **pone el log en cero**, descartando cada transacción de metadatos que todavía no había sido llevada a checkpoint. Usalo solo cuando el sistema de archivos físicamente no puede montarse, después de hacer una imagen del dispositivo, y aceptando que las operaciones de metadatos recientes desaparecieron. Es una operación de pérdida de datos con un nombre amistoso.

Control de memoria en sistemas de archivos muy grandes — `xfs_repair` construye estructuras en memoria proporcionales a la cantidad de inodos y va a ser matado por el OOM en un nodo de gestión chico:

```
$ sudo xfs_repair -m 8192 -P /dev/mapper/vg_arch-lv_arch
```

(`-m` limita la memoria a 8 GiB; `-P` desactiva la prelectura, cambiando velocidad por una huella mucho menor.)

**`xfs_db` — el inspector de metadatos.** Usá siempre `-r` (solo lectura) salvo que estés supervisado por alguien que haya escrito el sistema de archivos:

```
$ sudo xfs_db -r -c 'sb 0' -c 'print' /dev/mapper/vg_arch-lv_arch | head -20
magicnum = 0x58465342
blocksize = 4096
dblocks = 2441216000
rblocks = 0
rextents = 0
uuid = 3f8e12a4-9c07-4b5d-8e21-6a4f0d17b3c9
logstart = 1073741828
rootino = 128
rbmino = 129
rsumino = 130
rextsize = 1
agblocks = 76288000
agcount = 32
icount = 3221844
ifree = 4108
fdblocks = 1288847360
```

Evaluación de la fragmentación (`xfs_db` sobre un sistema de archivos *montado* requiere `-r`; los números son una foto y pueden ser levemente inconsistentes):

```
$ sudo xfs_db -r -c frag /dev/mapper/vg_arch-lv_arch
actual 4198234, ideal 3221844, fragmentation factor 23.26%
Note, this number is largely meaningless.
Files on this filesystem average 1.30 extents per file
```

La nota de upstream no es sarcasmo: el "factor de fragmentación" cuenta extents contra archivos, así que un sistema de archivos lleno de archivos legítimamente grandes con múltiples extents puntúa mal mientras funciona perfectamente. El número que importa es **extents por archivo** para los archivos que realmente leés secuencialmente:

```
$ sudo filefrag -v /srv/archive/2026/backup-full.tar.zst | tail -4
    412: 1048320..1049343:  8912384..  8913407:   1024:
    413: 1049344..1050367:  8913408..  8914431:   1024:  last,eof
/srv/archive/2026/backup-full.tar.zst: 414 extents found
```

**`xfs_fsr` — desfragmentación en línea.** Trabaja sobre un sistema de archivos *montado* copiando cada archivo fragmentado a un inodo temporal fresco y contiguo, e intercambiando los extents de forma atómica:

```
$ sudo xfs_fsr -v -t 600 /srv/archive
/srv/archive start inode=0
ino=1074266401
extents before:412 after:3 DONE ino=1074266401
ino=1074266580
extents before:198 after:2 DONE ino=1074266580
ino=1074266891
extents before:87 after:1 DONE ino=1074266891
/srv/archive start inode=1074267002
```

| Flag de `xfs_fsr` | Significado |
|---|---|
| `-v` | Verboso, cantidad de extents antes/después por inodo |
| `-t seconds` | Presupuesto de tiempo por invocación (por defecto 7200) |
| `-p passes` | Pasadas sobre el sistema de archivos |
| `-m mtab` | Tabla de montaje alternativa |
| *(sin argumentos)* | Reorganizar cada XFS de `/etc/mtab`, retomando desde `/var/tmp/.fsrlast_xfs` |

Restricciones que importan en producción: `xfs_fsr` necesita espacio libre (escribe una segunda copia completa de cada archivo que mueve), es intensivo en I/O, y **no puede ayudar a un sistema de archivos que está casi lleno** — que suele ser justo el que se fragmentó. También saltea archivos con extents compartidos (reflinks) en lugar de romper el compartido. La desfragmentación es un tratamiento del síntoma; la cura es no correr sistemas de archivos por encima del 85%.

Scrub nativo en línea, donde el kernel lo soporta:

```
$ sudo xfs_scrub -n /srv/archive
Info: /srv/archive: Scrubbing filesystem metadata.
Info: /srv/archive: Scanning all inodes.
Info: /srv/archive: Scrubbing filesystem summary counters.
/srv/archive: 3221844 inodes scanned, 0 errors found.
```

### 4.9 La ruta del arranque

```
$ systemctl list-units 'systemd-fsck*'
  UNIT                        LOAD   ACTIVE SUB    DESCRIPTION
  systemd-fsck-root.service   loaded active exited File System Check on Root Device
  systemd-fsck@dev-disk-by\x2duuid-a3c9....service loaded active exited File System Check on /dev/disk/by-uuid/a3c9...

$ journalctl -b -u systemd-fsck-root.service
systemd-fsck[412]: /dev/nvme0n1p2: clean, 412337/6553600 files, 18632144/25690112 blocks
```

Forzar o suprimir un chequeo se hace por la línea de comandos del kernel, no con el largamente obsoleto archivo marcador `/forcefsck`:

| Parámetro del kernel | Efecto |
|---|---|
| `fsck.mode=auto` | Por defecto: chequear cuando el fs está marcado como sucio o vencen los contadores |
| `fsck.mode=force` | Forzar un chequeo completo de cada sistema de archivos en este arranque |
| `fsck.mode=skip` | Saltear todos los chequeos (solo recuperación — estás arrancando un fs posiblemente inconsistente) |
| `fsck.repair=preen` | Por defecto: `fsck -a`, arreglar solo problemas inequívocos |
| `fsck.repair=yes` | `fsck -y`, responder sí a todo |
| `fsck.repair=no` | `fsck -n`, solo informar |

```
$ sudo grubby --update-kernel=ALL --args="fsck.mode=force fsck.repair=preen"
$ sudo reboot
# ... and afterwards, so it does not force on every boot:
$ sudo grubby --update-kernel=ALL --remove-args="fsck.mode fsck.repair"
```

---

## 5. Guía de verificación y diagnóstico de fallas

### 5.1 Triage: `ENOSPC` en un sistema de archivos que tiene espacio libre

```
                    write() -> ENOSPC
                            │
              ┌─────────────┴─────────────┐
        df -h shows                  df -h shows
        100% used                    free space
              │                            │
    ┌─────────┴─────────┐        ┌─────────┴──────────────┐
 du -xsh ≈ df      du -xsh << df │                        │
    │                   │     df -i at 100%?        df -i has room?
 Genuine full     Deleted-open   │                        │
    │             files, or a    │              ┌─────────┴─────────┐
 Reclaim /        shadowed mount │        Reserved blocks?     Quota?
 grow the LV          │      Inode exhaustion       │              │
                lsof -nP +L1     │            tune2fs -l      repquota -a
                mount --bind /   │            (writing as        xfs_quota
                                 │             non-root)       -c 'report'
                          ext4: cannot fix         │
                          in place -> grow    tune2fs -m 1
                          or rebuild with -i
                          xfs: xfs_growfs -m
```

Causa adicional exclusiva de XFS que vale la pena conocer: un sistema de archivos creado hace mucho y montado con `inode32` solo puede colocar inodos en el primer TiB del dispositivo. En un volumen de varios TiB que fue agrandado, esto produce `ENOSPC` en la *creación* de archivos con terabytes libres. Confirmalo con `grep xfs /proc/mounts` y remontá con `inode64`.

### 5.2 Triage: sospecha de corrupción

```
1. CONFIRM   dmesg -T | grep -Ei 'EXT4-fs error|XFS.*(corrupt|Internal error)|I/O error|remount'
             dumpe2fs -h <dev> | grep -A6 'FS Error count'
             grep ' ro,' /proc/mounts

2. CLASSIFY  smartctl -a /dev/nvme0n1   # Reallocated_Sector_Ct, Media_Wearout, nvme error log
             ├── media failing  -> STOP. ddrescue to healthy media, repair the COPY.
             └── media healthy  -> filesystem-level repair is appropriate.

3. PRESERVE  e2image -r <dev> /backup/meta.img          (ext4, minutes, ~0.05% of fs size)
             lvcreate --snapshot ...                    (if on LVM)
             ddrescue                                    (if media is suspect)

4. QUIESCE   systemctl stop <consumers>
             fuser -vm <mountpoint>
             umount <mountpoint>            # NEVER repair a mounted filesystem

5. ASSESS    e2fsck -fn <dev>       ; echo $?     # expect 0 or 4
             xfs_repair -n <dev>    ; echo $?     # expect 0 or 1

6. REPAIR    e2fsck -fy <dev>                     # after step 3, not before
             xfs_repair <dev>                     # mount+umount first if the log is dirty

7. VERIFY    e2fsck -fn <dev>  -> MUST exit 0     # non-convergence => hardware
             xfs_repair -n <dev> -> MUST exit 0
             mount <dev> <mp> && ls -la <mp>/lost+found

8. RECONCILE Identify lost+found contents, restore named files from backup,
             clear the superblock error counter is automatic on a clean e2fsck,
             record the incident, re-arm monitoring.
```

### 5.3 Lista de verificación — qué prueba qué

| Afirmación | Comando que la prueba | Resultado aceptable |
|---|---|---|
| El sistema de archivos es estructuralmente consistente | `e2fsck -fn <dev>` / `xfs_repair -n <dev>` | Salida 0, sin mensajes |
| Nunca se registró corrupción | `dumpe2fs -h <dev> \| grep 'FS Error count'` | Campo ausente, o `0` |
| Está montado de lectura-escritura | `findmnt -no OPTIONS <mp> \| grep -o '^rw'` | `rw` |
| Los errores serán contenidos | `tune2fs -l <dev> \| grep 'Errors behavior'` | `Remount read-only` |
| Tiene lugar para bloques | `df -h <mp>` | `Use%` < 85% |
| Tiene lugar para inodos | `df -i <mp>` | `IUse%` < 85% |
| Fue chequeado recientemente | `tune2fs -l <dev> \| grep 'Last checked'` | Dentro del intervalo de scrub |
| El medio subyacente está sano | `smartctl -H -A <disk>` | `PASSED`, cantidad de reasignados sin crecer |
| El timer del scrub realmente dispara | `systemctl list-timers 'fs-integrity-check@*'` | `NEXT` en el futuro, `LAST` reciente |
| El monitoreo lo detectaría | `curl -s localhost:9100/metrics \| grep node_filesystem_files_free` | Serie presente por cada montaje |

```
$ systemctl list-timers 'fs-integrity-check@*' --all
NEXT                         LEFT      LAST                         PASSED  UNIT                                          ACTIVATES
Sun 2026-08-30 03:47:12 UTC  3 days    Sun 2026-08-23 04:11:55 UTC  3 days  fs-integrity-check@vg_data--lv_data.timer     fs-integrity-check@vg_data--lv_data.service

$ sudo systemctl start 'fs-integrity-check@vg_data--lv_data.service'
$ journalctl -u 'fs-integrity-check@vg_data--lv_data.service' -n 5 --no-pager
systemd[1]: Starting Online integrity check of vg_data--lv_data...
fs-integrity-check[9214]: CLEAN: /dev/vg_data/lv_data (ext4)
systemd[1]: fs-integrity-check@vg_data--lv_data.service: Deactivated successfully.
systemd[1]: Finished Online integrity check of vg_data--lv_data.
```

### 5.4 Catálogo de modos de falla

| Síntoma | Causa probable | Diagnóstico | Acción |
|---|---|---|---|
| `EROFS` en cada escritura, `mount` muestra `ro` | Se disparó `errors=remount-ro` | `dmesg \| grep 'EXT4-fs error'` | **No** remontar rw. Drenar, hacer imagen, reparar offline |
| `Structure needs cleaning` (`EUCLEAN`) | Directorio o árbol de extents corrupto | `dmesg`, campos de error de `dumpe2fs -h` | Desmontar, `e2fsck -fn`, después reparar |
| `XFS (dm-2): Corruption detected. Unmount and run xfs_repair` | Shutdown de XFS por fallo de CRC de metadatos | `dmesg`, `/proc/fs/xfs/stat` | Desmontar, `xfs_repair -n`, después reparar |
| `mount: wrong fs type, bad option, bad superblock` | Superbloque primario dañado, o tipo equivocado | `blkid`, `mke2fs -n` para los respaldos | `e2fsck -b <backup> -B <blocksize>` |
| `e2fsck: Cannot continue, aborting` | El sistema de archivos está montado | `mountpoint`, `fuser -vm` | Parar los consumidores, desmontar |
| `xfs_repair` se niega: "valuable metadata changes in a log" | Log de XFS sucio | — | `mount` y después `umount` para reproducirlo; `-L` solo como último recurso |
| `e2fsck` nunca converge a salida 0 | El medio devuelve datos distintos en cada lectura | `smartctl -A`, `dmesg \| grep 'I/O error'` | Pará. `ddrescue` a un medio nuevo, reparar la copia |
| `df` lleno, `du` chico | Archivos borrados pero abiertos | `lsof -nP +L1` | `truncate -s 0 /proc/<pid>/fd/<n>` |
| `df` lleno, `du` chico, sin archivos borrados | Archivos debajo de un punto de montaje | `mount --bind / /mnt && du -xsh /mnt/<path>` | Desmontar, limpiar el directorio subyacente, remontar |
| `ENOSPC` con bloques libres | Inodos agotados | `df -i` | ext4: agrandar o reconstruir con `-i`; XFS: `xfs_growfs -m` |
| `ENOSPC` solo para usuarios no root | 5% de bloques reservados | `tune2fs -l \| grep Reserved` | `tune2fs -m 1` en volúmenes de datos puros |
| El arranque se cuelga en "File System Check on..." | Chequeo forzado en un volumen enorme | Consola, `journalctl -b -u systemd-fsck@*` | Dejalo terminar; después `tune2fs -c 0 -i 0` + scrub en línea |
| El chequeo por snapshot reporta basura | Espacio COW del snapshot agotado → snapshot invalidado | `lvs -o lv_name,snap_percent` | Dimensionar el snapshot según la tasa de escritura durante la duración del chequeo |
| Throughput de lectura secuencial degradado en XFS | Fragmentación de extents | `filefrag -v`, `xfs_db -r -c frag` | `xfs_fsr -t 600`; mantener el fs por debajo del 85% |

### 5.5 Reglas que se cumplen sin excepción

1. **Nunca repares un sistema de archivos montado.** Evaluación de solo lectura sobre un snapshot, sí. Reparación, no.
2. **Siempre corré `-n` antes de `-y`.** La pasada de solo lectura es gratis y te dice si esto es un arreglo contable de cinco segundos o un desastre estructural.
3. **Hacé una imagen de los metadatos antes de reparar.** `e2image -r` cuesta minutos y es el único deshacer que existe.
4. **Descartá el hardware primero.** Reparar un sistema de archivos sobre un medio moribundo acelera la pérdida de datos.
5. **`fsck` nunca libera espacio.** Lleno no es corrupto.
6. **Verificá la convergencia.** Una reparación está completa cuando una segunda pasada de solo lectura sale con 0, no cuando termina la primera.
7. **`xfs_repair -L` es una operación de pérdida de datos.** Agotá primero la reproducción del log con mount/umount.
8. **XFS no tiene chequeo en el arranque**, así que `passno` debe ser `0` y el monitoreo es el único detector.
9. **La cantidad de inodos en ext4 es inmutable en el lugar.** Elegí `-i`/`-N` al momento del `mkfs` contra un perfil medido de cantidad de archivos.
10. **Monitoreá bloques e inodos como dos alertas separadas.** Producen el mismo errno idéntico y solo uno de ellos está en tu dashboard por defecto.

---

## Referencias

**Objetivos de certificación**
- LPI Exam 101 Objectives (LPIC-1 version 5.0) — <https://www.lpi.org/our-certifications/exam-101-objectives/>
- LPI LPIC-1 certification overview — <https://www.lpi.org/our-certifications/lpic-1-overview/>

**ext2/3/4 y e2fsprogs**
- Linux kernel documentation, ext4 Data Structures and Algorithms — <https://docs.kernel.org/filesystems/ext4/index.html>
- Proyecto e2fsprogs — <https://e2fsprogs.sourceforge.net/>
- `e2fsck(8)` — <https://man7.org/linux/man-pages/man8/e2fsck.8.html>
- `mke2fs(8)` — <https://man7.org/linux/man-pages/man8/mke2fs.8.html>
- `mke2fs.conf(5)` — <https://man7.org/linux/man-pages/man5/mke2fs.conf.5.html>
- `tune2fs(8)` — <https://man7.org/linux/man-pages/man8/tune2fs.8.html>
- `dumpe2fs(8)` — <https://man7.org/linux/man-pages/man8/dumpe2fs.8.html>
- `e2image(8)` — <https://man7.org/linux/man-pages/man8/e2image.8.html>
- `e2scrub(8)` — <https://man7.org/linux/man-pages/man8/e2scrub.8.html>
- `resize2fs(8)` — <https://man7.org/linux/man-pages/man8/resize2fs.8.html>
- `badblocks(8)` — <https://man7.org/linux/man-pages/man8/badblocks.8.html>

**XFS**
- Linux kernel documentation, XFS — <https://docs.kernel.org/filesystems/xfs/index.html>
- Documentación del proyecto XFS — <https://xfs.wiki.kernel.org/>
- `xfs_repair(8)` — <https://man7.org/linux/man-pages/man8/xfs_repair.8.html>
- `xfs_db(8)` — <https://man7.org/linux/man-pages/man8/xfs_db.8.html>
- `xfs_fsr(8)` — <https://man7.org/linux/man-pages/man8/xfs_fsr.8.html>
- `xfs_admin(8)` — <https://man7.org/linux/man-pages/man8/xfs_admin.8.html>
- `xfs_growfs(8)` — <https://man7.org/linux/man-pages/man8/xfs_growfs.8.html>
- `xfs_scrub(8)` — <https://man7.org/linux/man-pages/man8/xfs_scrub.8.html>
- `mkfs.xfs(8)` — <https://man7.org/linux/man-pages/man8/mkfs.xfs.8.html>

**Utilidades genéricas**
- `fsck(8)` (util-linux) — <https://man7.org/linux/man-pages/man8/fsck.8.html>
- Manual de GNU coreutils, `df` — <https://www.gnu.org/software/coreutils/manual/html_node/df-invocation.html>
- Manual de GNU coreutils, `du` — <https://www.gnu.org/software/coreutils/manual/html_node/du-invocation.html>
- `fstab(5)` — <https://man7.org/linux/man-pages/man5/fstab.5.html>
- `mount(8)`, opciones de montaje independientes del sistema de archivos y de ext4/XFS — <https://man7.org/linux/man-pages/man8/mount.8.html>
- `filefrag(8)` — <https://man7.org/linux/man-pages/man8/filefrag.8.html>
- `lsof(8)` — <https://man7.org/linux/man-pages/man8/lsof.8.html>
- `lvcreate(8)`, snapshots de LVM — <https://man7.org/linux/man-pages/man8/lvcreate.8.html>

**systemd y chequeo en el arranque**
- `systemd-fsck@.service` — <https://www.freedesktop.org/software/systemd/man/latest/systemd-fsck@.service.html>
- `systemd.timer(5)` — <https://www.freedesktop.org/software/systemd/man/latest/systemd.timer.html>
- Opciones de la línea de comandos del kernel (`fsck.mode`, `fsck.repair`) — <https://www.freedesktop.org/software/systemd/man/latest/kernel-command-line.html>

**Monitoreo de plataforma**
- Prometheus node_exporter — <https://github.com/prometheus/node_exporter>
- Reglas de alertas de Prometheus — <https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/>
- Kubernetes, Node-pressure Eviction — <https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/>
- Kubernetes, `KubeletConfiguration` (v1beta1) — <https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/>
- Módulo `ansible.posix.mount` de Ansible — <https://docs.ansible.com/ansible/latest/collections/ansible/posix/mount_module.html>
- Módulo `community.general.filesystem` de Ansible — <https://docs.ansible.com/ansible/latest/collections/community/general/filesystem_module.html>
- Referencia de módulos de cloud-init — <https://cloudinit.readthedocs.io/en/latest/reference/modules.html>