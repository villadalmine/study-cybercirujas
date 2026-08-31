# 102.1 — Design Hard Disk Layout

**LPIC-1 v5.0 · Examen 102-500 · Peso 3.13**
**Perfil: Principal Platform Architect / SRE — profundidad de producción**

---

## 1. El problema arquitectónico

El layout de disco es la única decisión de diseño de un sistema Linux que es **efectivamente inmutable después de la instalación** y cuyo radio de impacto es **global**. Todo lo demás — paquetes, kernels, red, cargas de trabajo — se puede rehacer en tiempo de ejecución. La tabla de particiones y la topología de puntos de montaje no, no sin downtime, no sin una ventana de mantenimiento, y en XFS directamente no en la dirección de achicar.

Tres clases de fallo gobiernan toda la disciplina:

**1.1 — El agotamiento del espacio de nombres es una denegación de servicio de un solo escritor.**
En un sistema con raíz única todos los escritores comparten un mismo pool de espacio libre. Un log de aplicación desbocado, un anillo de `journald` sin rotar, el pull de una imagen de contenedor, un core dump o un `mysqldump` a `/tmp` consumen *los mismos* extents que `sshd` necesita para escribir su archivo PID, que `systemd` necesita para el overflow de `/run`, y que el gestor de paquetes necesita para preparar un parche de emergencia. Cuando `/` llega al 100 %:

- `sshd` puede seguir aceptando conexiones, pero `pam_systemd` de PAM falla al crear el slice de sesión;
- `journald` pasa a almacenamiento volátil y se pierde el rastro forense del incidente mismo;
- `dnf`/`apt` no puede descargar el fix;
- SELinux/AppArmor no puede escribir registros de auditoría y, con la configuración de pánico `-f`, la máquina se detiene.

Se perdió la máquina *y* la capacidad de repararla remotamente. La mitigación no es el monitoreo. El monitoreo avisa que ya pasó. La mitigación es **estructural**: poner los directorios de crecimiento no acotado en sus propios dispositivos de bloque para que el agotamiento quede contenido al inquilino que lo causó.

**1.2 — Las opciones de montaje son una superficie de control de seguridad, y son por sistema de archivos.**
`nosuid`, `nodev`, `noexec`, `ro` son propiedades de un *montaje*, no de un directorio. Si `/tmp`, `/var/tmp`, `/home` y `/dev/shm` viven dentro de `/`, no se les puede aplicar `noexec` sin aplicárselo también a `/usr/bin`. Por eso toda línea base de hardening (CIS, DISA STIG, PCI-DSS §2.2) exige sistemas de archivos separados para esas rutas — el control es inimplementable de otro modo. Esta es la razón individual más común por la que un diseño de servidor "simple" se rechaza en una revisión de cumplimiento.

**1.3 — La cadena de arranque tiene restricciones duras, específicas de la arquitectura, a las que el resto del layout debe ceder.**
El firmware puede leer un subconjunto muy pequeño de lo que puede leer el kernel. Si `/boot` (o la ESP) queda en un lugar que el firmware o la etapa pre-kernel del bootloader no puede interpretar, el sistema no arranca y ninguna cantidad de diseño correcto en otro lado importa. Los requisitos de arranque se calculan **primero**; todo lo demás se acomoda alrededor.

> **Encuadre del examen.** LPI 102.1 pide (a) asignar sistemas de archivos y swap a particiones o discos separados, (b) adaptar el diseño al uso previsto del sistema, (c) asegurar que `/boot` cumpla los requisitos de arranque de la arquitectura del hardware, y (d) conocer las funciones básicas de LVM. Todo lo que sigue es eso, a profundidad de producción.

---

## 2. Los requisitos de arranque van primero

### 2.1 Los dos regímenes de firmware

| Aspecto | BIOS / CSM (legacy) | UEFI |
|---|---|---|
| El firmware lee | Solo sectores crudos (bootstrap del MBR, 440 bytes) | FAT12/16/32 de forma nativa |
| Tabla de particiones | MBR (msdos) normalmente; GPT posible con una partición auxiliar | GPT (MBR está fuera de spec pero suele tolerarse) |
| Staging del bootloader | Bootstrap del MBR → `core.img` → `/boot/grub2` | `\EFI\<vendor>\grubx64.efi` (o `shimx64.efi`) en la ESP |
| Partición auxiliar requerida | **BIOS boot partition** (~1 MiB, tipo `ef02`) *solo si la tabla es GPT* | **EFI System Partition (ESP)**, FAT32, tipo `ef00` |
| Almacenamiento de entradas de arranque | Ninguno — el orden es el orden de discos del firmware | Variables NVRAM (`efibootmgr`), fallback `\EFI\BOOT\BOOTX64.EFI` |
| Secure Boot | No disponible | `shim` → GRUB → kernel firmado; afecta la carga de módulos y la hibernación |
| Disco arrancable máximo | 2 TiB con sectores de 512 B | 8 ZiB (GPT, LBA de 64 bits) |
| Layout típico de `/boot` | `/boot` ext4/xfs separado, o dentro de `/` | ESP en `/boot/efi` + `/boot` separado |

**Por qué existe la BIOS boot partition.** En MBR, GRUB guarda `core.img` en el "MBR gap" de ~31 KiB entre el sector 0 y la primera partición en el sector 2048. GPT no tiene ese hueco: la cabecera GPT primaria y el arreglo de particiones ocupan los LBA 1–33. Por eso GPT+BIOS requiere una partición explícita, sin formatear, de 1 MiB con GUID `21686148-6449-6E6F-744E-656564454649` para `core.img`. **Nunca se monta** y **nunca se formatea**. Olvidarla es el fallo clásico de "instaló bien, arranca a `grub rescue>`".

**Dimensionado de la ESP.** El mínimo de la especificación UEFI es 100 MiB, pero ese número está obsoleto en la práctica:

- Un volumen FAT32 necesita suficientes clusters para ser FAT32 válido — en medios 4Kn el piso práctico son **260 MiB**.
- `shim` + `grub` + cápsulas de `fwupd` + actualizaciones de firmware del fabricante + (en layouts Fedora/`systemd-boot`/UKI) **los kernels mismos como Unified Kernel Images** viven ahí. Cada UKI pesa 40–120 MiB.
- **Recomendación: 512 MiB mínimo, 1 GiB para cualquier sistema que vaya a usar UKIs, enrolamiento de Secure Boot o `fwupd`.**

**Dimensionado de `/boot`.** Cada kernel cuesta aproximadamente:

| Componente | Tamaño típico |
|---|---|
| `vmlinuz` | 12–15 MiB |
| `initramfs` (host-only, `dracut`) | 30–50 MiB |
| `initramfs` (genérico / `dracut --no-hostonly`) | 90–140 MiB |
| `System.map`, `config`, `symvers` | 8–12 MiB |
| **Total por kernel** | **~60 MiB host-only, ~180 MiB genérico** |

RHEL retiene 3 kernels (`installonly_limit=3` en `/etc/dnf/dnf.conf`); Debian/Ubuntu retienen 2 más el actual. Con imágenes de rescate y un initramfs genérico, 500 MiB se desborda en menos de un año.

> **Recomendación: `/boot` = 1 GiB.** Los instaladores de RHEL 9 y Ubuntu 22.04+ usan ese valor por defecto exactamente por esta razón. Un `/boot` lleno durante una actualización de kernel produce un **initramfs truncado** — la transacción del paquete "tiene éxito", el siguiente reinicio cae en la shell de emergencia de `dracut`, y la causa raíz quedó tres semanas atrás.

### 2.2 Qué puede leer realmente el bootloader

Esta es la restricción que mata los layouts ingeniosos.

| Ubicación de `/boot` | GRUB2 (BIOS o UEFI) | `systemd-boot` | Veredicto |
|---|---|---|---|
| Partición plana, ext4 / xfs / btrfs | ✅ | ❌ (necesita ESP FAT) | Seguro |
| LV LVM **linear** o **mirror** | ✅ (`insmod lvm`) | ❌ | Funciona, agrega fragilidad |
| LV LVM **thin** | ❌ | ❌ | **No arranca** |
| Subvolumen Btrfs | ✅ | ❌ | Funciona; perfiles RAID5/6 no soportados |
| MD RAID **1** (metadata 1.0 o 0.90) | ✅ | ❌ | Funciona — 1.0 pone la metadata al *final*, así cada pata es legible como un FS plano |
| MD RAID 1 (metadata **1.2**, por defecto) | ✅ (`insmod mdraid1x`) | ❌ | Funciona vía módulo de GRUB; el firmware sigue sin poder |
| MD RAID **5/6/10** | ⚠️ parcial | ❌ | Evitar |
| LUKS**1** | ✅ | ❌ | Funciona |
| LUKS**2**, PBKDF2 | ✅ (GRUB ≥ 2.06) | ❌ | Funciona |
| LUKS2, **Argon2id** (default de cryptsetup) | ❌ | ❌ | **No arranca** — el clásico |
| Pool ZFS | ⚠️ depende de feature flags | ❌ | Frágil entre actualizaciones |

**Dos reglas de producción que se desprenden de esta tabla:**

1. **Mantener `/boot` como una partición plana, sin cifrar, no thin, sobre un sistema de archivos simple.** El 1 GiB que se "ahorra" metiéndolo dentro de LVM compra toda una clase de bricking en tiempo de actualización.
2. Si hay que cifrar root, o bien dejar `/boot` en claro o, al convertir un volumen LUKS2 existente, forzar la KDF compatible con el bootloader:

```bash
$ sudo cryptsetup luksConvertKey --pbkdf pbkdf2 /dev/nvme0n1p3
Enter passphrase for keyslot to be converted:
```

### 2.3 Deriva de features del sistema de archivos — una caída real y recurrente

`mkfs.xfs` habilita por defecto nuevas features on-disk a medida que avanza `xfsprogs` (`bigtime`, `inobtcount`, `nrext64`). El driver XFS de GRUB es una reimplementación y va atrasado. Crear `/boot` con un `mkfs.xfs` más nuevo que el GRUB instalado produce `error: unknown filesystem` al arrancar — *después* de que la instalación tuvo éxito.

`mkfs` defensivo para `/boot`, fijando el conjunto de features:

```bash
$ sudo mkfs.xfs -m bigtime=0,inobtcount=0 -i nrext64=0 -L boot /dev/nvme0n1p3
```

O esquivar toda la clase de problema — **ext4 para `/boot`** es la elección más conservadora en cualquier distribución, y `/boot` no gana nada con la escalabilidad de XFS.

---

## 3. Tablas de particiones: MBR vs GPT

| Propiedad | MBR (`msdos`) | GPT |
|---|---|---|
| Direccionamiento | LBA de 32 bits | LBA de 64 bits |
| Disco máximo (sectores de 512 B) | **2 TiB** | 8 ZiB |
| Disco máximo (sectores de 4 KiB) | 16 TiB | — |
| Cantidad de particiones | 4 primarias; más vía cadena extendida + lógicas | 128 entradas por defecto (el arreglo es redimensionable) |
| Redundancia | Ninguna — el sector 0 es un punto único de fallo | Cabecera primaria en LBA 1 + **backup en el último LBA** |
| Integridad | Ninguna | CRC32 sobre la cabecera y el arreglo de particiones |
| Identidad de partición | Código de tipo de 1 byte (`0x83`, `0x82`, `0x8e`) | **GUID** de tipo de 16 bytes + GUID único por partición + nombre UTF-16 de 36 caracteres |
| Metadata de alineación | Lastre CHS heredado | LBA limpio |
| Interoperabilidad legacy | Universal | MBR protectivo (`0xEE`) impide que herramientas viejas lo pisen |

**Usar GPT incondicionalmente en builds nuevos**, incluidos discos de menos de 2 TiB e incluidas máquinas BIOS (agregando la partición `ef02`). Las razones son la cabecera de backup, el CRC y los GUID de tipo estables — no la capacidad.

### GUIDs de tipo de partición que vale la pena memorizar

| Propósito | Código `sgdisk` | GUID de tipo |
|---|---|---|
| EFI System Partition | `ef00` | `C12A7328-F81F-11D2-BA4B-00A0C93EC93B` |
| BIOS boot partition | `ef02` | `21686148-6449-6E6F-744E-656564454649` |
| Sistema de archivos Linux | `8300` | `0FC63DAF-8483-4772-8E79-3D69D8477DE4` |
| Swap de Linux | `8200` | `0657FD6D-A4AB-43C4-84E5-0933C84B4F4F` |
| LVM de Linux | `8e00` | `E6D6D379-F507-44C2-A23C-238F2A3DF928` |
| LUKS de Linux | `8309` | `CA7D7CCB-63ED-4C53-861C-1742536059CC` |
| Root, x86-64 (DPS) | `8304` | `4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709` |
| `/home` (DPS) | `8302` | `933AC7E1-2EB4-4F13-B844-0E14E2AEF915` |

Los últimos dos pertenecen a la **Discoverable Partitions Specification**. Cuando se usan esos GUIDs, `systemd-gpt-auto-generator` monta `/`, `/home`, `/srv`, `/var` y activa swap **sin ninguna entrada en `/etc/fstab`** — la tabla de particiones *es* la configuración de montaje. Así es como los sistemas modernos basados en imágenes (Fedora CoreOS, appliances `systemd`-nativos) evitan por completo la deriva de `fstab`.

---

## 4. Taxonomía de puntos de montaje: qué separar y por qué

El FHS define la semántica; producción define la separación. La regla de decisión es: **separar una ruta cuando tenga un perfil de crecimiento independiente, una postura de seguridad independiente o un requisito de durabilidad independiente.**

| Punto de montaje | Motor del crecimiento | ¿Acotado? | ¿Separar? | Opciones recomendadas |
|---|---|---|---|---|
| `/` | Solo paquetes | Sí (~10–20 GiB) | — | `defaults` |
| `/boot` | Retención de kernels | Sí (~1 GiB) | **Siempre** | `nodev,nosuid,noexec` |
| `/boot/efi` | Firmware + UKIs | Sí | **UEFI: siempre** | `umask=0077,shortname=winnt` |
| `/home` | Usuarios | **No** | Multiusuario: sí | `nodev,nosuid` |
| `/var` | Logs, spool, bases de datos, contenedores | **No** | **Siempre en servidores** | `nodev,nosuid` |
| `/var/log` | Logging de aplicación y sistema | **No** | Siempre en servidores | `nodev,nosuid,noexec` |
| `/var/log/audit` | auditd — puede configurarse para **entrar en pánico al llenarse** | No | Builds endurecidos | `nodev,nosuid,noexec` |
| `/var/tmp` | Temporales persistentes | No | Builds endurecidos | `nodev,nosuid,noexec` |
| `/tmp` | Temporales transitorios | No | Siempre | `nodev,nosuid,noexec` (o `tmpfs`) |
| `/srv`, `/opt`, `/data` | Carga útil | No | Según la carga de trabajo | Específicas de la carga |
| `/usr` | Paquetes | Sí | Rara vez (los sistemas basados en imágenes lo montan `ro`) | `ro` donde se soporte |

### Por qué `/var/log/audit` tiene su propio sistema de archivos

`auditd` puede configurarse con `disk_full_action = halt` (un requisito de STIG). Si `/var/log/audit` comparte sistema de archivos con los logs de aplicación, **cualquier** inundación de logs detiene la máquina. Aislar la auditoría significa que la garantía propia del subsistema de auditoría no puede ser disparada por un inquilino ajeno.

### `noexec` en `/tmp`: qué compra y qué no

Bloquea `execve()` de archivos en ese sistema de archivos. **No** bloquea `bash /tmp/x.sh` (el intérprete lee, no ejecuta) ni `ld.so /tmp/x`. Es un obstáculo real contra payloads tipo dropper y un requisito de cumplimiento, no una frontera. Tener en cuenta que algunos scripts post-instalación de paquetes e instaladores viejos (Oracle, ciertas extracciones de librerías nativas de la JVM) se rompen con él; esos necesitan redirigir `TMPDIR` en lugar de quitar la opción.

### El trade-off de `tmpfs` para `/tmp`

| | `/tmp` respaldado por disco | `/tmp` en `tmpfs` |
|---|---|---|
| Velocidad | Limitado por el dispositivo | Velocidad de RAM |
| Capacidad | Tamaño de la partición | 50 % de la RAM por defecto, respaldado por swap |
| Semántica al reiniciar | Necesita limpieza con `systemd-tmpfiles` | Vacío por definición |
| Riesgo | Llena el disco | **Consume RAM y empuja al sistema hacia OOM** |
| Cargas con archivos grandes | Bien | Un artefacto de build de 20 GiB en `/tmp` se convierte en 20 GiB de presión de memoria |

Habilitar `tmpfs` para `/tmp` (`systemctl enable tmp.mount`) en nodos sin estado; mantenerlo respaldado por disco en agentes de build, hosts de base de datos y cualquier cosa que prepare archivos grandes.

---

## 5. Estrategias de asignación comparadas

| Estrategia | Aislamiento | Flexibilidad | Complejidad | Riesgo de arranque | Mejor encaje |
|---|---|---|---|---|---|
| **Raíz única** | Ninguno | Ninguna (solo crece la última partición) | Mínima | El más bajo | Contenedores, imágenes inmutables, VMs descartables |
| **Multipartición fija** | Fuerte | **Pobre** — redimensionar implica downtime y reparticionar | Baja | Bajo | Appliances con un perfil conocido y fijo |
| **LVM sobre un PV** | Fuerte | **Alta** — crecimiento en línea, snapshots, agregar LVs | Media | Bajo si `/boot` queda afuera | **Default para físicos y VMs de larga vida** |
| **Thin pool LVM** | Fuerte | La más alta — sobresuscripción, snapshots baratos | Alta | Medio — el agotamiento del pool es un fallo duro | Virtualización densa, efímeros de CI |
| **Subvolúmenes Btrfs** | Basado en cuotas (qgroups) | Alta — sin tamaños fijos, shrink en línea, snapshots | Media | Medio | Estaciones de trabajo, rollback con `snapper`, SUSE |
| **Datasets ZFS** | Fuerte (cuota/reserva por dataset) | Alta | Alta (fuera del árbol del kernel) | Alto | Servidores de almacenamiento donde ZFS es el punto |
| **Basado en imágenes / OSTree** | Estructural — `/usr` es de solo lectura | N/A por diseño | Baja de operar | El más bajo | Nodos gestionados en flota, CoreOS, RHEL Image Mode |

### LVM vs Btrfs: la comparación honesta

| Dimensión | LVM + XFS/ext4 | Subvolúmenes Btrfs |
|---|---|---|
| Modelo de espacio | **Fijo** por LV; el espacio libre está ocioso hasta ser asignado | Pool **compartido**; no hay decisión de preasignación |
| Crecer | En línea, en ambas capas | N/A (sin tamaño fijo) |
| **Achicar** | ext4: solo offline. **XFS: imposible.** | En línea |
| Snapshots | CoW a nivel de bloque, con tamaño tope, **se invalidan al llenarse** | Nativos, baratos, sin precipicio de capacidad |
| Checksums | Ninguno (depende del dispositivo) | Checksums de datos y metadata |
| Imponer un límite por ruta | Gratis — es el tamaño del LV | Requiere qgroups (históricamente costosos) |
| Cargas de base de datos | XFS es la plataforma de referencia | Necesita `nodatacow` — lo que deshabilita los checksums para esos archivos |
| Familiaridad operativa | Universal | Depende de la distribución |

**Guía práctica:** LVM + XFS para servidores y bases de datos; Btrfs donde el requisito sea el rollback del propio sistema operativo.

### La regla de que XFS no puede achicarse

Es la asimetría más consecuente en el diseño de almacenamiento en Linux y moldea directamente cómo se asigna.

```
                grow            shrink
ext4      online (resize2fs)    offline only (umount, e2fsck, resize2fs)
XFS       online (xfs_growfs)   NOT SUPPORTED — ever
Btrfs     online                online
```

**Corolario: en XFS, la sobreasignación es permanente.** Por lo tanto, bajo LVM, **asignar de forma conservadora y dejar extents libres en el VG.** Crecer es una operación en línea de 10 segundos; recuperar es un backup/restore.

```
VG capacity 400 GiB
  ├── assigned to LVs        ~150 GiB   ← conservative
  └── unassigned free extents ~250 GiB  ← your entire flexibility budget
```

---

## 6. LVM: el modelo

```
   /dev/nvme0n1p4   /dev/nvme1n1        ← block devices
        │                │
    ┌───▼────────────────▼───┐
    │  Physical Volumes (PV) │   pvcreate — writes an LVM2 label at sector 1
    └───────────┬────────────┘             + metadata area, data starts at 1 MiB
                │
    ┌───────────▼────────────┐
    │   Volume Group (VG)    │   vgcreate — a pool of Physical Extents (PE, 4 MiB default)
    └───────────┬────────────┘
                │
    ┌───────────▼────────────┐
    │  Logical Volumes (LV)  │   lvcreate — a mapping of Logical Extents → Physical Extents
    └───────────┬────────────┘             exposed as /dev/<vg>/<lv> via device-mapper
                │
    ┌───────────▼────────────┐
    │      Filesystem        │   mkfs.xfs / mkfs.ext4
    └────────────────────────┘
```

| Término | Significado | Nota operativa |
|---|---|---|
| **PV** | Un dispositivo de bloque (disco entero o partición) entregado a LVM | `pvcreate`. La metadata es redundante dentro del PV. |
| **PE** | Physical Extent — el cuanto de asignación | 4 MiB por defecto. `vgcreate -s 16M` para VGs muy grandes (la cantidad de extents determina el tamaño de la metadata y la latencia de los comandos). |
| **VG** | Pool nombrado de PVs | Los extents pueden asignarse desde cualquier PV miembro. |
| **LV** | Mapeo de extents presentado como dispositivo | Tipos: `linear`, `striped`, `mirror`, `raid1/5/6/10`, `thin`, `cache`, `snapshot`. |
| **Política de asignación** | `normal`, `contiguous`, `cling`, `anywhere` | `cling` mantiene una extensión en el mismo PV — crítico para LVs con striping. |

### Capacidades que justifican la complejidad

- **Crecimiento en línea** — `lvextend -r` redimensiona el LV *y* el sistema de archivos en un solo paso.
- **Volúmenes que cruzan dispositivos** — un LV puede superar cualquier disco individual.
- **Snapshots** — una vista CoW en un punto en el tiempo para backups consistentes.
- **Striping** — `lvcreate -i 4 -I 256k` para throughput paralelo entre dispositivos.
- **Migración de PV en línea** — `pvmove` reubica extents fuera de un disco que está fallando, con el sistema de archivos montado.
- **Dispositivos nombrados y estables** — `/dev/sysvg/var` nunca cambia porque la SAN hizo un rescan.

### Snapshots: el precipicio de capacidad

Un snapshot LVM (thick) es un área CoW de tamaño fijo. Cada escritura al origen copia el extent original al snapshot. **Cuando el snapshot se llena, se descarta y queda ilegible** — silenciosamente, desde el punto de vista de la aplicación.

```bash
$ sudo lvcreate -L 20G -s -n var_snap /dev/sysvg/var
  Logical volume "var_snap" created.

$ sudo lvs -o lv_name,lv_size,data_percent,snap_percent sysvg
  LV        LSize   Data%  Snap%
  var        40.00g
  var_snap   20.00g        6.14
```

Dimensionar el snapshot según el volumen de *escritura* durante la ventana de backup, no según el tamaño del origen, y monitorear `snap_percent`. `/etc/lvm/lvm.conf` tiene `snapshot_autoextend_threshold` / `snapshot_autoextend_percent` — configurarlos:

```ini
# /etc/lvm/lvm.conf
activation {
    snapshot_autoextend_threshold = 70
    snapshot_autoextend_percent   = 20
    thin_pool_autoextend_threshold = 70
    thin_pool_autoextend_percent   = 20
}
```

### Thin provisioning: la sobresuscripción es un pasivo, no una función

Un thin pool permite que la suma de tamaños de LVs supere la capacidad física. Cuando el **pool** llega al 100 %, los LVs thin quedan de solo lectura o devuelven error, y los sistemas de archivos sobre ellos se corrompen. `df` en el huésped muestra espacio libre hasta el momento mismo del fallo. **Nunca usar thin provisioning para los sistemas de archivos del sistema operativo de un nodo de producción.** Usarlo para scratch de CI y entornos de prueba densos, siempre con `thin_pool_autoextend_*` configurado y alertas a nivel de pool.

---

## 7. Swap

### Dimensionado

La guía publicada por Red Hat, que es la referencia de facto de la industria:

| RAM instalada | Swap recomendado | Con hibernación |
|---|---|---|
| ≤ 2 GiB | 2 × RAM | 3 × RAM |
| 2 – 8 GiB | = RAM | 2 × RAM |
| 8 – 64 GiB | 4 GiB – 0.5 × RAM | 1.5 × RAM |
| > 64 GiB | ≥ 4 GiB | No recomendada |

**La hibernación requiere `swap ≥ RAM`** porque la imagen completa se escribe en swap; el kernel necesita `resume=UUID=...` en la línea de comandos para encontrarla. Los servidores no hibernan — no dimensionar para eso.

### Por qué los servidores igual quieren *algo* de swap

La afirmación común de que "los servidores no deberían tener swap" es incorrecta de una forma específica y medible. Bajo presión de memoria con `swap = 0`, el kernel solo puede recuperar page cache y páginas limpias respaldadas por archivos — incluyendo el texto ejecutable de los procesos en ejecución. El resultado es thrashing sobre lecturas de `/usr/bin` y un OOM kill duro sin aviso. Un área de swap pequeña le da al reclamador dónde poner páginas anónimas genuinamente frías, convirtiendo un precipicio en una pendiente que el monitoreo puede detectar.

**Recomendación: 4–8 GiB en servidores, `vm.swappiness=10`.** Ni cero, ni del tamaño de la RAM.

```ini
# /etc/sysctl.d/90-swap.conf
vm.swappiness = 10
vm.vfs_cache_pressure = 50
vm.min_free_kbytes = 262144
```

### Partición de swap vs archivo de swap vs zram

| | Partición de swap | Archivo de swap | zram |
|---|---|---|---|
| Redimensionar | Reparticionar / `lvextend` | `fallocate` de uno nuevo — trivial | `systemctl restart` del generador |
| Rendimiento | Línea base | Equivalente en kernels modernos (el mapa de extents está cacheado) | El más rápido — RAM, pero cuesta CPU |
| Hibernación | Soportada | Soportada (necesita `resume_offset=`) | **No soportada** |
| Sobre Btrfs | N/A | Requiere `nodatacow`, sin compresión, sin snapshots de él | N/A |
| Cifrado | Hereda LUKS si está debajo | Hereda el FS padre | N/A (ya es volátil) |
| Mejor encaje | Servidores tradicionales | Imágenes de nube, agregados a posteriori | Laptops, nodos de borde densos en memoria |

Crear un archivo de swap correctamente (`fallocate` puede producir un archivo inutilizable en algunos sistemas de archivos; `dd` es la forma segura en Btrfs):

```bash
$ sudo fallocate -l 8G /swapfile
$ sudo chmod 600 /swapfile
$ sudo mkswap /swapfile
Setting up swapspace version 1, size = 8 GiB (8589930496 bytes)
no label, UUID=6a3d1b3c-2f4e-4b7a-9c88-1f0a2b3c4d5e
$ sudo swapon /swapfile
$ swapon --show
NAME       TYPE      SIZE USED PRIO
/dev/dm-6  partition   8G   0B   -2
/swapfile  file        8G   0B   -3
```

### Salvedad para Kubernetes / contenedores

`cgroup v2` da contabilidad de swap por contenedor (`memory.swap.max`), y kubelet soporta swap vía `NodeSwap` — pero las cargas sensibles a la latencia se degradan mucho cuando hacen swap. **En nodos de Kubernetes: o se deshabilita swap por completo (el requisito tradicional) o se habilita con `memory.swap.max=0` en pods de QoS guaranteed.** Nunca dejar el nodo con un área de swap grande y sin política por pod.

---

## 8. Alineación y geometría

La desalineación causa **amplificación de lectura-modificación-escritura**: una escritura de 4 KiB del sistema de archivos que cruza dos sectores físicos de 4 KiB (o dos unidades de stripe RAID, o dos bloques de borrado de SSD) obliga al dispositivo a leer, fusionar y reescribir. El efecto es una pérdida de 20–50 % de throughput y, en flash, un desgaste acelerado en proporción.

**La regla: iniciar cada partición en un límite de 1 MiB (2048 × 512 B sectores).** 1 MiB es divisible por 512 B, 4 KiB, 8 KiB, 64 KiB, 128 KiB, 256 KiB y 512 KiB — así que satisface simultáneamente sectores 4Kn, unidades de stripe RAID y bloques de borrado de flash. Todas las herramientas modernas (`parted -a optimal`, `sgdisk`, `fdisk` ≥ 2.17) lo hacen por defecto; `sfdisk` con un offset escrito a mano, no.

Inspeccionar la geometría:

```bash
$ lsblk -o NAME,SIZE,PHY-SEC,LOG-SEC,MIN-IO,OPT-IO,ALIGNMENT,ROTA,DISC-GRAN
NAME          SIZE PHY-SEC LOG-SEC MIN-IO OPT-IO ALIGNMENT ROTA DISC-GRAN
nvme0n1     400G     512     512    512      0         0    0      512B
├─nvme0n1p1   1M     512     512    512      0         0    0      512B
├─nvme0n1p2   1G     512     512    512      0         0    0      512B
├─nvme0n1p3   1G     512     512    512      0         0    0      512B
└─nvme0n1p4 397G     512     512    512      0         0    0      512B
```

`ALIGNMENT 0` significa alineado. Un valor distinto de cero es el offset en bytes de la desalineación.

```bash
$ sudo parted /dev/nvme0n1 align-check optimal 4
4 aligned

$ sudo pvs -o pv_name,pe_start,vg_name
  PV             1st PE  VG
  /dev/nvme0n1p4   1.00m  sysvg
```

`1st PE = 1.00m` confirma que el área de datos de LVM está ella misma alineada a 1 MiB. En un arreglo RAID, alinear además el sistema de archivos al stripe:

```bash
# 4 data disks, 256 KiB chunk → su=256k, sw=4
$ sudo mkfs.xfs -d su=256k,sw=4 /dev/sysvg/data

# ext4 equivalent: stride = chunk/blocksize = 64, stripe-width = stride * data disks
$ sudo mkfs.ext4 -E stride=64,stripe-width=256 /dev/sysvg/data
```

---

## 9. Layouts de referencia

### 9.1 Servidor UEFI de propósito general — NVMe de 400 GiB, LVM

| # | Dispositivo | Tamaño | Tipo | FS | Montaje | Opciones |
|---|---|---|---|---|---|---|
| 1 | `nvme0n1p1` | 1 MiB | `ef02` | — | — | BIOS boot (seguro ante doble firmware) |
| 2 | `nvme0n1p2` | 1 GiB | `ef00` | vfat | `/boot/efi` | `umask=0077,shortname=winnt` |
| 3 | `nvme0n1p3` | 1 GiB | `8300` | ext4 | `/boot` | `nodev,nosuid,noexec` |
| 4 | `nvme0n1p4` | resto | `8e00` | — | — | PV LVM → VG `sysvg` |

| LV | Tamaño | FS | Montaje | Opciones |
|---|---|---|---|---|
| `root` | 20 GiB | xfs | `/` | `defaults` |
| `var` | 30 GiB | xfs | `/var` | `nodev,nosuid` |
| `varlog` | 20 GiB | xfs | `/var/log` | `nodev,nosuid,noexec` |
| `varlogaudit` | 10 GiB | xfs | `/var/log/audit` | `nodev,nosuid,noexec` |
| `vartmp` | 10 GiB | xfs | `/var/tmp` | `nodev,nosuid,noexec` |
| `tmp` | 10 GiB | xfs | `/tmp` | `nodev,nosuid,noexec` |
| `home` | 20 GiB | xfs | `/home` | `nodev,nosuid` |
| `swap` | 8 GiB | swap | — | `pri=10` |
| *(libre)* | **~270 GiB** | — | — | **El presupuesto de flexibilidad** |

### 9.2 Nodo worker de Kubernetes — dos dispositivos

La intención de diseño es que **la presión de imágenes y de almacenamiento efímero nunca pueda desalojar al kubelet ni al estado propio del runtime de contenedores**, y que los umbrales de eviction a nivel de nodo se correspondan con dispositivos reales y aislados.

| Dispositivo | Propósito |
|---|---|
| `nvme0n1` | SO: cadena de arranque + `sysvg` (root, var, varlog, swap) |
| `nvme1n1` | `datavg`: `/var/lib/containerd` (imagefs) y `/var/lib/kubelet` (nodefs) |

`/var/lib/containerd` **debe** ser XFS con `ftype=1` (el default desde 2016 — overlayfs se niega a montar de otro modo) y `prjquota` si se quieren límites de almacenamiento efímero por contenedor aplicados en la capa del sistema de archivos.

```bash
$ sudo mkfs.xfs -n ftype=1 -L containerd /dev/datavg/containerd
$ sudo mount -o noatime,prjquota /dev/datavg/containerd /var/lib/containerd
$ xfs_info /var/lib/containerd | grep -E 'ftype|naming'
naming   =version 2              bsize=4096   ascii-ci=0, ftype=1
```

### 9.3 Nodo de base de datos (PostgreSQL / MySQL)

| Ruta | Dispositivo | Justificación |
|---|---|---|
| `/` + `/var` | SSD del SO | Sin particularidades |
| `/var/lib/pgsql/data` | NVMe dedicado, XFS, `noatime` | I/O aleatorio, necesita toda la profundidad de cola |
| `/var/lib/pgsql/wal` (`pg_wal`) | **Dispositivo separado** | Secuencial, limitado por fsync; la contención acá es latencia, directamente |
| `/backup` | Red u otro huso separado | Nunca en el dispositivo de datos |

Separar WAL/redo no es superstición: la ruta del WAL está limitada por `fdatasync` y serializada. Compartir dispositivo con el I/O aleatorio de los archivos de datos convierte cada commit en una espera en cola. Medir con:

```bash
$ sudo fio --name=fsync --filename=/var/lib/pgsql/wal/testfile --size=1G \
      --rw=write --bs=8k --fdatasync=1 --numjobs=1 --iodepth=1 --runtime=60 \
      --time_based --group_reporting
...
  fsync/fdatasync/sync_file_range:
    sync (usec): min=112, max=8934, avg=289.44, stdev=143.21
```

Un `fdatasync` promedio por encima de ~1 ms va a acotar la tasa de commits sin importar la CPU.

### 9.4 Instancia en la nube — deliberadamente simple

Las imágenes de nube usan **una única raíz que puede crecer** porque la instancia es ganado: el disco lo define la imagen, el volumen lo redimensiona la API, y `growpart` + `xfs_growfs` corren en el primer arranque. Agregar LVM a una imagen de nube agrega modos de fallo sin ninguna ventaja — en su lugar se redimensiona el volumen EBS/PD. **Adjuntar volúmenes separados para los datos**, nunca tallar la raíz.

---

## 10. Infraestructura como código — manifiestos completos

### 10.1 Kickstart (RHEL 9 / Rocky / AlmaLinux) — archivo completo

```kickstart
#version=RHEL9
# Kickstart: hardened UEFI server, GPT + LVM, CIS-aligned filesystem separation.

text
lang en_US.UTF-8
keyboard us
timezone UTC --utc
rootpw --lock
user --name=sre --groups=wheel --iscrypted --password=$6$rounds=656000$REPLACEME

network --bootproto=dhcp --device=link --activate
firewall --enabled --service=ssh
selinux --enforcing

bootloader --location=mbr --timeout=5 \
           --append="crashkernel=1G-4G:192M,4G-64G:256M,64G-:512M audit=1 audit_backlog_limit=8192"

# ---------------------------------------------------------------------------
# Disk layout
# ---------------------------------------------------------------------------
ignoredisk --only-use=nvme0n1
clearpart --all --initlabel --drives=nvme0n1 --disklabel=gpt
zerombr

# Boot chain. biosboot is harmless on UEFI and saves the system if the
# platform is ever re-provisioned in CSM mode.
part biosboot  --fstype=biosboot --size=1        --ondisk=nvme0n1
part /boot/efi --fstype=efi      --size=1024     --ondisk=nvme0n1 --fsoptions="umask=0077,shortname=winnt"
part /boot     --fstype=ext4     --size=1024     --ondisk=nvme0n1 --fsoptions="nodev,nosuid,noexec" --label=boot

# Everything else is LVM. Note: --grow on the PV, NOT on the logical volumes.
# Free extents in the VG are the flexibility budget; XFS cannot shrink.
part pv.01     --fstype=lvmpv    --size=10240 --grow --ondisk=nvme0n1
volgroup sysvg --pesize=4096 pv.01

logvol /                --vgname=sysvg --name=root         --fstype=xfs  --size=20480
logvol /home            --vgname=sysvg --name=home         --fstype=xfs  --size=20480 --fsoptions="nodev,nosuid"
logvol /var             --vgname=sysvg --name=var          --fstype=xfs  --size=30720 --fsoptions="nodev,nosuid"
logvol /var/log         --vgname=sysvg --name=varlog       --fstype=xfs  --size=20480 --fsoptions="nodev,nosuid,noexec"
logvol /var/log/audit   --vgname=sysvg --name=varlogaudit  --fstype=xfs  --size=10240 --fsoptions="nodev,nosuid,noexec"
logvol /var/tmp         --vgname=sysvg --name=vartmp       --fstype=xfs  --size=10240 --fsoptions="nodev,nosuid,noexec"
logvol /tmp             --vgname=sysvg --name=tmp          --fstype=xfs  --size=10240 --fsoptions="nodev,nosuid,noexec"
logvol swap             --vgname=sysvg --name=swap         --fstype=swap --size=8192

# ---------------------------------------------------------------------------
%packages
@^minimal-environment
lvm2
xfsprogs
gdisk
parted
cloud-utils-growpart
audit
chrony
-iwl*-firmware
%end

# ---------------------------------------------------------------------------
%post --log=/root/ks-post.log
set -euo pipefail

cat > /etc/sysctl.d/90-swap.conf <<'EOF'
vm.swappiness = 10
vm.vfs_cache_pressure = 50
EOF

# /dev/shm hardening — it is a tmpfs mount, not a partition, but the same
# control surface applies.
cat >> /etc/fstab <<'EOF'
tmpfs  /dev/shm  tmpfs  defaults,nodev,nosuid,noexec  0 0
EOF

# Bound journald so /var/log cannot be filled by the journal alone.
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/00-size.conf <<'EOF'
[Journal]
Storage=persistent
SystemMaxUse=4G
SystemKeepFree=2G
SystemMaxFileSize=256M
EOF

# Retain exactly 3 kernels so a 1 GiB /boot is provably sufficient.
sed -i 's/^installonly_limit=.*/installonly_limit=3/' /etc/dnf/dnf.conf

# Prove the layout before first login.
findmnt --verify --verbose > /root/fstab-verify.txt 2>&1 || true
%end

reboot --eject
```

### 10.2 cloud-init — raíz que puede crecer más volúmenes de datos adjuntos (completo)

```yaml
#cloud-config
# cloud-init: grow the root volume, then build a dedicated LVM VG on the
# attached data disks for container and kubelet state.
#
# Ordering guarantee: cloud-init runs growpart/resizefs in cc_growpart and
# cc_resizefs (init stage), then disk_setup/fs_setup, then mounts, then
# runcmd (final stage). The LVM work therefore belongs in bootcmd/runcmd.

growpart:
  mode: auto
  devices:
    - /
    - /dev/nvme0n1p4
  ignore_growroot_disabled: false

resize_rootfs: true

# Partition the data disks with a single GPT partition covering the whole
# device. `overwrite: false` makes this idempotent across reboots.
disk_setup:
  /dev/nvme1n1:
    table_type: gpt
    layout: true
    overwrite: false
  /dev/nvme2n1:
    table_type: gpt
    layout: true
    overwrite: false

fs_setup:
  - label: pgwal
    filesystem: xfs
    device: /dev/nvme2n1
    partition: 1
    overwrite: false
    extra_opts:
      - "-n"
      - "ftype=1"

mounts:
  # Field order is the fstab order: device, mountpoint, type, options, dump, pass.
  # nofail + x-systemd.device-timeout prevent a missing volume from dropping
  # the node into the emergency shell on boot.
  - [ "LABEL=pgwal", "/var/lib/pgsql/wal", "xfs",
      "defaults,noatime,nodev,nosuid,nofail,x-systemd.device-timeout=15s", "0", "2" ]
  - [ "/dev/datavg/containerd", "/var/lib/containerd", "xfs",
      "defaults,noatime,nodev,nosuid,prjquota,nofail,x-systemd.device-timeout=15s", "0", "2" ]
  - [ "/dev/datavg/kubelet", "/var/lib/kubelet", "xfs",
      "defaults,noatime,nodev,nosuid,nofail,x-systemd.device-timeout=15s", "0", "2" ]
  - [ "tmpfs", "/dev/shm", "tmpfs", "defaults,nodev,nosuid,noexec", "0", "0" ]

mount_default_fields: [ None, None, "auto", "defaults,nofail", "0", "2" ]

swap:
  filename: /swapfile
  size: 8589934592          # 8 GiB, in bytes
  maxsize: 8589934592

packages:
  - lvm2
  - xfsprogs
  - gdisk
  - cloud-utils-growpart

write_files:
  - path: /etc/sysctl.d/90-swap.conf
    permissions: "0644"
    content: |
      vm.swappiness = 10
      vm.vfs_cache_pressure = 50

  - path: /etc/systemd/journald.conf.d/00-size.conf
    permissions: "0644"
    content: |
      [Journal]
      Storage=persistent
      SystemMaxUse=4G
      SystemKeepFree=2G

  - path: /usr/local/sbin/setup-datavg.sh
    permissions: "0755"
    content: |
      #!/usr/bin/env bash
      # Idempotent construction of the container/kubelet volume group.
      set -euo pipefail

      DISK=/dev/nvme1n1p1
      VG=datavg

      # Bail out cleanly if the VG already exists — this script runs on every
      # boot via runcmd and must be safe to repeat.
      if vgs "${VG}" >/dev/null 2>&1; then
        echo "VG ${VG} already present; nothing to do."
        exit 0
      fi

      [ -b "${DISK}" ] || { echo "FATAL: ${DISK} is not a block device"; exit 1; }

      # 1 MiB data alignment; explicit, not inherited from defaults.
      pvcreate --dataalignment 1m "${DISK}"
      vgcreate --physicalextentsize 4m "${VG}" "${DISK}"

      # Allocate conservatively: 40 % containerd, 20 % kubelet, 40 % held back.
      lvcreate --name containerd --extents 40%VG "${VG}"
      lvcreate --name kubelet    --extents 20%VG "${VG}"

      # ftype=1 is mandatory for overlayfs; prjquota enables per-container
      # ephemeral-storage enforcement.
      mkfs.xfs -n ftype=1 -L containerd "/dev/${VG}/containerd"
      mkfs.xfs -n ftype=1 -L kubelet    "/dev/${VG}/kubelet"

      echo "Volume group ${VG} created:"
      vgs "${VG}"
      lvs "${VG}"

bootcmd:
  # Ensure device-mapper nodes exist before anything references them.
  - [ modprobe, dm_mod ]

runcmd:
  - [ /usr/local/sbin/setup-datavg.sh ]
  - [ systemctl, daemon-reload ]
  - [ mkdir, -p, /var/lib/containerd, /var/lib/kubelet, /var/lib/pgsql/wal ]
  - [ mount, -a ]
  - [ sysctl, --system ]
  # Fail the boot loudly rather than silently if fstab is inconsistent.
  - [ findmnt, --verify, --verbose ]

final_message: "Disk layout converged after $UPTIME seconds."
```

### 10.3 Butane (Fedora CoreOS / RHEL CoreOS) — compilado a Ignition

Ignition corre en el initramfs, **antes** de que se monte el sistema de archivos raíz — es el único mecanismo que puede reparticionar el disco de arranque de un sistema basado en imágenes.

```yaml
variant: fcos
version: 1.5.0

storage:
  disks:
    # Repartition the boot disk: shrink the image's root partition to 20 GiB
    # and carve dedicated partitions from the remainder.
    - device: /dev/disk/by-id/coreos-boot-disk
      wipe_table: false
      partitions:
        - label: root
          number: 4
          size_mib: 20480
          resize: true
        - label: var
          size_mib: 40960
          start_mib: 0            # 0 = "immediately after the previous partition"
          type_guid: 4D21B016-B534-45C2-A9FB-5C16E091FD2D   # DPS: /var
        - label: varlog
          size_mib: 20480
          start_mib: 0
        - label: containers
          size_mib: 0             # 0 = "use all remaining space"
          start_mib: 0

  filesystems:
    - device: /dev/disk/by-partlabel/var
      format: xfs
      label: var
      wipe_filesystem: false
      with_mount_unit: true
      path: /var
      options:
        - -n
        - ftype=1

    - device: /dev/disk/by-partlabel/varlog
      format: xfs
      label: varlog
      wipe_filesystem: false
      with_mount_unit: true
      path: /var/log

    - device: /dev/disk/by-partlabel/containers
      format: xfs
      label: containers
      wipe_filesystem: false
      with_mount_unit: false      # mounted by the explicit unit below
      options:
        - -n
        - ftype=1

  files:
    - path: /etc/sysctl.d/90-swap.conf
      mode: 0644
      overwrite: true
      contents:
        inline: |
          vm.swappiness = 10
          vm.vfs_cache_pressure = 50

    - path: /etc/systemd/journald.conf.d/00-size.conf
      mode: 0644
      overwrite: true
      contents:
        inline: |
          [Journal]
          Storage=persistent
          SystemMaxUse=4G
          SystemKeepFree=2G

systemd:
  units:
    # prjquota must be set at mount time; it cannot be enabled on a
    # mounted XFS filesystem.
    - name: var-lib-containers.mount
      enabled: true
      contents: |
        [Unit]
        Description=Container storage (XFS with project quota)
        Before=local-fs.target
        Requires=systemd-fsck@dev-disk-by\x2dpartlabel-containers.service
        After=systemd-fsck@dev-disk-by\x2dpartlabel-containers.service

        [Mount]
        What=/dev/disk/by-partlabel/containers
        Where=/var/lib/containers
        Type=xfs
        Options=defaults,noatime,nodev,nosuid,prjquota

        [Install]
        WantedBy=local-fs.target

    - name: swap-on-zram.service
      enabled: true
      contents: |
        [Unit]
        Description=Enable zram-backed swap
        After=local-fs.target

        [Service]
        Type=oneshot
        RemainAfterExit=yes
        ExecStart=/usr/sbin/modprobe zram num_devices=1
        ExecStart=/usr/bin/sh -c 'echo zstd > /sys/block/zram0/comp_algorithm'
        ExecStart=/usr/bin/sh -c 'echo 8G > /sys/block/zram0/disksize'
        ExecStart=/usr/sbin/mkswap /dev/zram0
        ExecStart=/usr/sbin/swapon --priority 100 /dev/zram0
        ExecStop=/usr/sbin/swapoff /dev/zram0

        [Install]
        WantedBy=multi-user.target
```

Compilar y validar antes de desplegar — una configuración de Ignition mala deja el primer arranque inutilizable y sin shell:

```bash
$ butane --pretty --strict layout.bu --output layout.ign
$ ignition-validate layout.ign
$ echo $?
0
```

### 10.4 Ansible — converger y verificar una flota existente (playbook completo)

```yaml
---
- name: Converge disk layout on application nodes
  hosts: app_nodes
  become: true

  vars:
    sysvg_name: sysvg
    data_disk: /dev/nvme1n1
    datavg_name: datavg
    # Conservative allocations. XFS cannot shrink, so the unassigned
    # remainder of the VG is the only flexibility we will ever have.
    logical_volumes:
      - { name: containerd, size: 40%VG, fs: xfs, mount: /var/lib/containerd,
          opts: "defaults,noatime,nodev,nosuid,prjquota" }
      - { name: kubelet,    size: 20%VG, fs: xfs, mount: /var/lib/kubelet,
          opts: "defaults,noatime,nodev,nosuid" }

  tasks:
    - name: Install storage tooling
      ansible.builtin.package:
        name:
          - lvm2
          - xfsprogs
          - gdisk
          - parted
        state: present

    - name: Gather block device facts
      ansible.builtin.setup:
        gather_subset:
          - hardware

    - name: Refuse to run if the data disk is absent
      ansible.builtin.assert:
        that:
          - data_disk | basename in ansible_devices
        fail_msg: >-
          {{ data_disk }} is not present on {{ inventory_hostname }}.
          Attach the volume before running this play.

    - name: Create a single GPT partition spanning the data disk
      community.general.parted:
        device: "{{ data_disk }}"
        label: gpt
        number: 1
        part_start: 1MiB          # explicit 1 MiB alignment
        part_end: 100%
        flags: [ lvm ]
        state: present

    - name: Create the physical volume and volume group
      community.general.lvg:
        vg: "{{ datavg_name }}"
        pvs: "{{ data_disk }}1"
        pesize: 4
        state: present

    - name: Create logical volumes
      community.general.lvol:
        vg: "{{ datavg_name }}"
        lv: "{{ item.name }}"
        size: "{{ item.size }}"
        state: present
        # shrink: false is a safety interlock — never let a play shrink an LV
        # out from under a mounted XFS filesystem.
        shrink: false
      loop: "{{ logical_volumes }}"

    - name: Create filesystems
      community.general.filesystem:
        fstype: "{{ item.fs }}"
        dev: "/dev/{{ datavg_name }}/{{ item.name }}"
        # ftype=1 is required by overlayfs; it is the default but we assert it.
        opts: "{{ '-n ftype=1' if item.fs == 'xfs' else omit }}"
        resizefs: true
      loop: "{{ logical_volumes }}"

    - name: Mount filesystems and persist them in fstab
      ansible.posix.mount:
        path: "{{ item.mount }}"
        src: "/dev/{{ datavg_name }}/{{ item.name }}"
        fstype: "{{ item.fs }}"
        opts: "{{ item.opts }},nofail,x-systemd.device-timeout=15s"
        dump: "0"
        passno: "2"
        state: mounted
      loop: "{{ logical_volumes }}"

    - name: Harden /dev/shm
      ansible.posix.mount:
        path: /dev/shm
        src: tmpfs
        fstype: tmpfs
        opts: defaults,nodev,nosuid,noexec
        state: mounted

    - name: Bound the journal so /var/log cannot self-fill
      ansible.builtin.copy:
        dest: /etc/systemd/journald.conf.d/00-size.conf
        mode: "0644"
        content: |
          [Journal]
          Storage=persistent
          SystemMaxUse=4G
          SystemKeepFree=2G
      notify: Restart journald

    - name: Apply swap tuning
      ansible.posix.sysctl:
        name: "{{ item.key }}"
        value: "{{ item.value }}"
        sysctl_file: /etc/sysctl.d/90-swap.conf
        reload: true
      loop:
        - { key: vm.swappiness, value: "10" }
        - { key: vm.vfs_cache_pressure, value: "50" }

    # -----------------------------------------------------------------------
    # Verification — a converge that is not verified is a hope, not a change.
    # -----------------------------------------------------------------------
    - name: Verify fstab is internally consistent
      ansible.builtin.command: findmnt --verify --verbose
      register: fstab_verify
      changed_when: false
      failed_when: fstab_verify.rc != 0

    - name: Verify every partition is optimally aligned
      ansible.builtin.command: "parted {{ data_disk }} align-check optimal 1"
      register: align
      changed_when: false
      failed_when: "'aligned' not in align.stdout"

    - name: Verify XFS ftype is enabled on container storage
      ansible.builtin.command: xfs_info /var/lib/containerd
      register: xfsinfo
      changed_when: false
      failed_when: "'ftype=1' not in xfsinfo.stdout"

    - name: Verify /boot has headroom for at least two more kernels
      ansible.builtin.shell: >-
        set -o pipefail;
        df --output=avail -m /boot | tail -n1
      args:
        executable: /bin/bash
      register: boot_avail
      changed_when: false
      failed_when: (boot_avail.stdout | trim | int) < 400

    - name: Report the converged layout
      ansible.builtin.debug:
        msg: "{{ fstab_verify.stdout_lines }}"

  handlers:
    - name: Restart journald
      ansible.builtin.systemd:
        name: systemd-journald
        state: restarted
```

### 10.5 Kubernetes — exponer el layout al scheduler

El diseño de disco del nodo solo rinde si el plano de control lo conoce. Un dispositivo dedicado se convierte en un PersistentVolume `local` con afinidad de nodo, y los umbrales de eviction se fijan contra los sistemas de archivos reales.

```yaml
---
# The storage class that binds local volumes lazily, so the scheduler picks
# the node first and the volume second.
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-nvme
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Retain
allowVolumeExpansion: false
---
# One PV per physical device per node. The path must be a mount point, not a
# directory inside another filesystem, or capacity accounting is a fiction.
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-node01-pgdata
  labels:
    topology.kubernetes.io/zone: rack-a
spec:
  capacity:
    storage: 1600Gi
  volumeMode: Filesystem
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-nvme
  local:
    path: /mnt/disks/nvme3n1
    fsType: xfs
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - node01
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pgdata
  namespace: databases
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: local-nvme
  resources:
    requests:
      storage: 1600Gi
---
# Kubelet configuration. imagefs.* refers to the container runtime's
# filesystem (/var/lib/containerd); nodefs.* to the kubelet's
# (/var/lib/kubelet). Separating those devices is what makes these two sets
# of thresholds independently meaningful.
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
failSwapOn: true
evictionHard:
  memory.available: "500Mi"
  nodefs.available: "10%"
  nodefs.inodesFree: "5%"
  imagefs.available: "15%"
  imagefs.inodesFree: "5%"
evictionSoft:
  nodefs.available: "15%"
  imagefs.available: "20%"
evictionSoftGracePeriod:
  nodefs.available: "2m"
  imagefs.available: "2m"
evictionMinimumReclaim:
  nodefs.available: "5%"
  imagefs.available: "5%"
imageGCHighThresholdPercent: 80
imageGCLowThresholdPercent: 70
# Requires XFS with prjquota on the kubelet and containerd filesystems.
featureGates:
  LocalStorageCapacityIsolationFSQuotaMonitoring: true
```

---

## 11. Recorrido por CLI — construir el layout a mano

### 11.1 Relevar antes de tocar nada

```bash
$ lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINTS,MODEL
NAME        SIZE TYPE FSTYPE LABEL MOUNTPOINTS MODEL
nvme0n1     400G disk                          SAMSUNG MZQL2400HCJR
nvme1n1     800G disk                          SAMSUNG MZQL2800HCJR

$ sudo lsblk -f
NAME    FSTYPE FSVER LABEL UUID FSAVAIL FSUSE% MOUNTPOINTS
nvme0n1
nvme1n1

$ sudo fdisk -l /dev/nvme0n1
Disk /dev/nvme0n1: 400 GiB, 429496729600 bytes, 838860800 sectors
Disk model: SAMSUNG MZQL2400HCJR
Units: sectors of 1 * 512 = 512 bytes
Sector size (logical/physical): 512 bytes / 512 bytes
I/O size (minimum/optimal): 512 bytes / 512 bytes
```

Confirmar el modo de firmware — esto decide toda la sección de arranque:

```bash
$ [ -d /sys/firmware/efi ] && echo "UEFI" || echo "BIOS/CSM"
UEFI

$ cat /sys/firmware/efi/fw_platform_size
64
```

### 11.2 Particionar con `sgdisk` (scriptable, idempotente, exacto)

```bash
# Destroy any existing table, both primary and backup GPT headers.
$ sudo sgdisk --zap-all /dev/nvme0n1
GPT data structures destroyed! You may now partition the disk using fdisk or
other utilities.

# Clear filesystem signatures that would otherwise confuse blkid/udev.
$ sudo wipefs -a /dev/nvme0n1

# Build the table. -a 2048 sets 1 MiB alignment explicitly.
$ sudo sgdisk -a 2048 \
    -n 1:0:+1M     -t 1:ef02 -c 1:"BIOS boot"  \
    -n 2:0:+1G     -t 2:ef00 -c 2:"EFI System" \
    -n 3:0:+1G     -t 3:8300 -c 3:"boot"       \
    -n 4:0:0       -t 4:8e00 -c 4:"LVM PV"     \
    /dev/nvme0n1
Setting name!
partNum is 0
Setting name!
partNum is 1
Setting name!
partNum is 2
Setting name!
partNum is 3
The operation has completed successfully.

$ sudo partprobe /dev/nvme0n1

$ sudo sgdisk -p /dev/nvme0n1
Disk /dev/nvme0n1: 838860800 sectors, 400.0 GiB
Sector size (logical/physical): 512/512 bytes
Disk identifier (GUID): 3F2A9C41-7B8E-4D5F-A1C3-9E0B4D6F8A2C
Partition table holds up to 128 entries
Main partition table begins at sector 2 and ends at sector 33
First usable sector is 34, last usable sector is 838860766
Partitions will be aligned on 2048-sector boundaries
Total free space is 2014 sectors (1007.0 KiB)

Number  Start (sector)    End (sector)  Size       Code  Name
   1            2048            4095   1024.0 KiB  EF02  BIOS boot
   2            4096         2101247   1024.0 MiB  EF00  EFI System
   3         2101248         4198399   1024.0 MiB  8300  boot
   4         4198400       838860766   398.0 GiB   8E00  LVM PV

$ sudo parted /dev/nvme0n1 align-check optimal 4
4 aligned
```

### 11.3 Sistemas de archivos para la cadena de arranque

```bash
$ sudo mkfs.vfat -F 32 -n EFI /dev/nvme0n1p2
mkfs.fat 4.2 (2021-01-31)

$ sudo mkfs.ext4 -L boot /dev/nvme0n1p3
mke2fs 1.46.5 (30-Dec-2021)
Creating filesystem with 262144 4k blocks and 65536 inodes
Filesystem UUID: 8c1f4a2e-3b7d-4e69-9a05-2f8c1d4b6e3a
Superblock backups stored on blocks:
	32768, 98304, 163840, 229376

Allocating group tables: done
Writing inode tables: done
Creating journal (8192 blocks): done
Writing superblocks and filesystem accounting information: done
```

### 11.4 La pila LVM

```bash
$ sudo pvcreate --dataalignment 1m /dev/nvme0n1p4
  Physical volume "/dev/nvme0n1p4" successfully created.

$ sudo vgcreate --physicalextentsize 4m sysvg /dev/nvme0n1p4
  Volume group "sysvg" successfully created

$ sudo vgdisplay sysvg
  --- Volume group ---
  VG Name               sysvg
  System ID
  Format                lvm2
  Metadata Areas        1
  Metadata Sequence No  1
  VG Access             read/write
  VG Status             resizable
  MAX LV                0
  Cur LV                0
  Open LV               0
  Max PV                0
  Cur PV                1
  Act PV                1
  VG Size               <398.00 GiB
  PE Size               4.00 MiB
  Total PE              101887
  Alloc PE / Size       0 / 0
  Free  PE / Size       101887 / <398.00 GiB
  VG UUID               kTf2Yq-9dZa-Lm4X-p1Bs-7RnC-vE8H-3jQwPl
```

Crear los volúmenes lógicos — deliberadamente chicos, dejando el grueso sin asignar:

```bash
$ sudo lvcreate -L 20G  -n root        sysvg
  Logical volume "root" created.
$ sudo lvcreate -L 30G  -n var         sysvg
  Logical volume "var" created.
$ sudo lvcreate -L 20G  -n varlog      sysvg
  Logical volume "varlog" created.
$ sudo lvcreate -L 10G  -n varlogaudit sysvg
  Logical volume "varlogaudit" created.
$ sudo lvcreate -L 10G  -n vartmp      sysvg
  Logical volume "vartmp" created.
$ sudo lvcreate -L 10G  -n tmp         sysvg
  Logical volume "tmp" created.
$ sudo lvcreate -L 20G  -n home        sysvg
  Logical volume "home" created.
$ sudo lvcreate -L 8G   -n swap        sysvg
  Logical volume "swap" created.

$ sudo lvs -o lv_name,lv_size,vg_name,devices sysvg
  LV          LSize  VG    Devices
  home        20.00g sysvg /dev/nvme0n1p4(20480)
  root        20.00g sysvg /dev/nvme0n1p4(0)
  swap         8.00g sysvg /dev/nvme0n1p4(25600)
  tmp         10.00g sysvg /dev/nvme0n1p4(17920)
  var         30.00g sysvg /dev/nvme0n1p4(5120)
  varlog      20.00g sysvg /dev/nvme0n1p4(12800)
  varlogaudit 10.00g sysvg /dev/nvme0n1p4(15360)
  vartmp      10.00g sysvg /dev/nvme0n1p4(15360)

$ sudo vgs sysvg
  VG    #PV #LV #SN Attr   VSize    VFree
  sysvg   1   8   0 wz--n- <398.00g <270.00g
```

`VFree <270.00g` es el número que importa. Eso es cuánto se le puede entregar al sistema de archivos que resulte necesitarlo, en línea, sin downtime.

```bash
$ for lv in root var varlog varlogaudit vartmp tmp home; do
    sudo mkfs.xfs -f -L "$lv" "/dev/sysvg/$lv"
  done
meta-data=/dev/sysvg/root        isize=512    agcount=4, agsize=1310720 blks
         =                       sectsz=512   attr=2, projid32bit=1
         =                       crc=1        finobt=1, sparse=1, rmapbt=0
         =                       reflink=1    bigtime=1 inobtcount=1 nrext64=0
data     =                       bsize=4096   blocks=5242880, imaxpct=25
         =                       sunit=0      swidth=0 blks
naming   =version 2              bsize=4096   ascii-ci=0, ftype=1
log      =internal log           bsize=4096   blocks=16384, version=2
         =                       sectsz=512   sunit=0 blks, lazy-count=1
realtime =none                   extsz=4096   blocks=0, rtextents=0
...

$ sudo mkswap -L swap /dev/sysvg/swap
Setting up swapspace version 1, size = 8 GiB (8589930496 bytes)
LABEL=swap, UUID=b4e7d219-6c3a-4f81-9d02-7a5e1c8b3f46
```

### 11.5 El `/etc/fstab` resultante

Montar siempre por UUID o por la ruta del dispositivo LV — nunca por nombre de kernel (`/dev/sda3`), que depende del orden de enumeración y va a intercambiarse silenciosamente después de un cambio de controladora.

```bash
$ sudo blkid
/dev/nvme0n1p2: SEC_TYPE="msdos" LABEL_FATBOOT="EFI" LABEL="EFI" UUID="A1B2-C3D4" BLOCK_SIZE="512" TYPE="vfat" PARTLABEL="EFI System" PARTUUID="7d3e1f92-4a8b-4c65-9e10-2b7f5a3c8d41"
/dev/nvme0n1p3: LABEL="boot" UUID="8c1f4a2e-3b7d-4e69-9a05-2f8c1d4b6e3a" BLOCK_SIZE="4096" TYPE="ext4" PARTLABEL="boot" PARTUUID="e5a92c7b-1d64-4837-b0f2-9c3e8a1d5b60"
/dev/nvme0n1p4: UUID="P3xK9m-2Vqa-Lc7T-8sYn-4Bde-1WfR-6jHgZo" TYPE="LVM2_member" PARTLABEL="LVM PV" PARTUUID="c8f14b23-9e05-4a7d-8b36-1f2c9d5e7a04"
```

```fstab
# /etc/fstab
#
# <device>                      <mount point>      <type>  <options>                                        <dump> <pass>

/dev/mapper/sysvg-root          /                  xfs     defaults                                              0  0
UUID=8c1f4a2e-3b7d-4e69-9a05-2f8c1d4b6e3a  /boot   ext4    defaults,nodev,nosuid,noexec                          0  2
UUID=A1B2-C3D4                  /boot/efi          vfat    umask=0077,shortname=winnt,nodev,nosuid,noexec        0  2

/dev/mapper/sysvg-home          /home              xfs     defaults,nodev,nosuid                                 0  0
/dev/mapper/sysvg-var           /var               xfs     defaults,nodev,nosuid                                 0  0
/dev/mapper/sysvg-varlog        /var/log           xfs     defaults,nodev,nosuid,noexec                          0  0
/dev/mapper/sysvg-varlogaudit   /var/log/audit     xfs     defaults,nodev,nosuid,noexec                          0  0
/dev/mapper/sysvg-vartmp        /var/tmp           xfs     defaults,nodev,nosuid,noexec                          0  0
/dev/mapper/sysvg-tmp           /tmp               xfs     defaults,nodev,nosuid,noexec                          0  0

/dev/mapper/sysvg-swap          none               swap    defaults,pri=10                                       0  0
tmpfs                           /dev/shm           tmpfs   defaults,nodev,nosuid,noexec                          0  0
```

**Semántica de los campos — las dos columnas que los candidatos equivocan:**

| Campo | Significado |
|---|---|
| `<dump>` | Bandera heredada de `dump(8)`. **Siempre `0`** en sistemas modernos. |
| `<pass>` | Orden de `fsck` al arrancar: `0` = nunca chequear, `1` = solo el sistema de archivos raíz, `2` = todo lo demás, chequeado en paralelo entre dispositivos. **XFS lo ignora** (tiene journal y se repara al montar); ext4 lo respeta. Un valor distinto de cero en `/` para cualquier sistema de archivos que no sea ext es irrelevante pero inocuo. |

**El orden no importa para la corrección en `systemd`** — `systemd-fstab-generator` construye unidades `.mount` y deriva las dependencias de la jerarquía de rutas, así que `/var/log` se ordena después de `/var` automáticamente. Igual, mantener el archivo ordenado jerárquicamente; un humano lo lee durante un incidente.

### 11.6 Hacer crecer un sistema de archivos en línea — la recompensa

```bash
$ df -h /var/log
Filesystem                     Size  Used Avail Use% Mounted on
/dev/mapper/sysvg-varlog        20G   17G  3.1G  85% /var/log

# -r (--resizefs) extends the LV and then the filesystem in one atomic step.
$ sudo lvextend -L +30G -r /dev/sysvg/varlog
  Size of logical volume sysvg/varlog changed from 20.00 GiB (5120 extents) to 50.00 GiB (12800 extents).
  Logical volume sysvg/varlog successfully resized.
meta-data=/dev/mapper/sysvg-varlog isize=512    agcount=4, agsize=1310720 blks
data     =                       bsize=4096   blocks=5242880, imaxpct=25
...
data blocks changed from 5242880 to 13107200

$ df -h /var/log
Filesystem                     Size  Used Avail Use% Mounted on
/dev/mapper/sysvg-varlog        50G   17G   33G  35% /var/log
```

Cero downtime, cero desmontajes, un comando. Este es el argumento completo a favor de LVM.

Agregar un disco entero a un VG existente:

```bash
$ sudo pvcreate /dev/nvme1n1
  Physical volume "/dev/nvme1n1" successfully created.
$ sudo vgextend sysvg /dev/nvme1n1
  Volume group "sysvg" successfully extended.
$ sudo vgs sysvg
  VG    #PV #LV #SN Attr   VSize   VFree
  sysvg   2   8   0 wz--n-  <1.17t <1.01t
```

Evacuar un disco que está fallando con todo montado:

```bash
$ sudo pvmove /dev/nvme0n1p4 /dev/nvme1n1
  /dev/nvme0n1p4: Moved: 0.02%
  /dev/nvme0n1p4: Moved: 14.37%
  /dev/nvme0n1p4: Moved: 61.88%
  /dev/nvme0n1p4: Moved: 100.00%
$ sudo vgreduce sysvg /dev/nvme0n1p4
  Removed "/dev/nvme0n1p4" from volume group "sysvg"
```

### 11.7 Hacer crecer un volumen raíz en la nube después de un redimensionado por API

```bash
$ lsblk /dev/nvme0n1
NAME        MAJ:MIN RM SIZE RO TYPE MOUNTPOINTS
nvme0n1     259:0    0 200G  0 disk
├─nvme0n1p1 259:1    0   1M  0 part
├─nvme0n1p2 259:2    0 200M  0 part /boot/efi
└─nvme0n1p3 259:3    0  50G  0 part /

# The partition table still describes the old size. growpart rewrites it.
$ sudo growpart /dev/nvme0n1 3
CHANGED: partition=3 start=411648 old: size=104445952 end=104857599 new: size=418942943 end=419354590

$ sudo xfs_growfs /
meta-data=/dev/nvme0n1p3         isize=512    agcount=4, agsize=3276800 blks
data     =                       bsize=4096   blocks=13107200, imaxpct=25
data blocks changed from 13107200 to 52367867

$ df -h /
Filesystem      Size  Used Avail Use% Mounted on
/dev/nvme0n1p3  200G  4.1G  196G   3% /
```

Para ext4 el segundo paso es `sudo resize2fs /dev/nvme0n1p3`. Notar la asimetría en los nombres de las herramientas: **`xfs_growfs` toma un punto de montaje, `resize2fs` toma un dispositivo.**

---

## 12. Verificación y diagnóstico de fallos

### 12.1 La checklist previa al reinicio

**Un layout no es correcto hasta que sobrevivió un reinicio. Verificar antes de correr ese riesgo.**

```bash
# 1. Is fstab internally consistent? Every UUID resolvable, every mount point
#    present, every option parseable? This is the single highest-value check.
$ findmnt --verify --verbose
/
   [ ] target exists
   [ ] FS options: defaults
/boot
   [ ] target exists
   [ ] UUID=8c1f4a2e-3b7d-4e69-9a05-2f8c1d4b6e3a translated to /dev/nvme0n1p3
   [ ] FS options: defaults,nodev,nosuid,noexec
...
Success, no errors or warnings detected

# 2. Do the generated systemd mount units parse?
$ systemd-analyze verify default.target
$ sudo systemctl daemon-reload && systemctl --failed
0 loaded units listed.

# 3. Are all mounts actually up right now, matching fstab?
$ findmnt --fstab --evaluate
$ mount -a && echo "mount -a clean"
mount -a clean

# 4. Is the boot chain intact?
$ bootctl status
System:
      Firmware: UEFI 2.70 (American Megatrends 5.19)
 Firmware Arch: x64
   Secure Boot: enabled (user)
  TPM2 Support: yes
  Measured UKI: no
  Boot into FW: supported

Current Boot Loader:
      Product: GRUB 2.06
     Features: ✗ Boot counting
   ESP: /dev/disk/by-partuuid/7d3e1f92-4a8b-4c65-9e10-2b7f5a3c8d41
  File: └─/EFI/rocky/shimx64.efi

$ efibootmgr -v
BootCurrent: 0000
Timeout: 5 seconds
BootOrder: 0000,0001
Boot0000* Rocky Linux	HD(2,GPT,7d3e1f92-4a8b-4c65-9e10-2b7f5a3c8d41,0x1000,0x200000)/File(\EFI\rocky\shimx64.efi)
Boot0001* UEFI: PXE IPv4	PciRoot(0x0)/Pci(0x1c,0x4)/...

# 5. Does /boot actually have the kernels it claims?
$ ls -lh /boot/vmlinuz-* /boot/initramfs-*
-rw-------. 1 root root  48M Aug 12 09:14 /boot/initramfs-5.14.0-427.el9.x86_64.img
-rw-------. 1 root root  48M Aug 19 11:02 /boot/initramfs-5.14.0-503.el9.x86_64.img
-rwxr-xr-x. 1 root root  13M Aug 12 09:11 /boot/vmlinuz-5.14.0-427.el9.x86_64
-rwxr-xr-x. 1 root root  13M Aug 19 10:58 /boot/vmlinuz-5.14.0-503.el9.x86_64

$ df -h /boot
Filesystem      Size  Used Avail Use% Mounted on
/dev/nvme0n1p3  974M  283M  624M  32% /boot
```

### 12.2 Catálogo de fallos

---

**Síntoma: el arranque se cuelga ~90 s y después cae a `emergency mode`.**

```
[  *** ] A start job is running for /dev/disk/by-uuid/8c1f4a2e-... (1min 29s / 1min 30s)
[DEPEND] Dependency failed for /var/log.
[DEPEND] Dependency failed for Local File Systems.
You are in emergency mode. After logging in, type "journalctl -xb" to view
system logs, "systemctl reboot" to reboot, or "exit" to continue to boot.
Give root password for maintenance:
```

**Causa.** Una entrada de `/etc/fstab` referencia un dispositivo que no existe — un UUID mal tipeado, un sistema de archivos recreado (`mkfs` asigna un UUID *nuevo*), o un volumen no adjunto. `systemd` espera `DefaultTimeoutStartSec` (90 s) al dispositivo y después hace fallar `local-fs.target`.

**Diagnóstico y reparación.**

```bash
# Root filesystem is mounted read-only at this point.
$ mount -o remount,rw /
$ journalctl -xb -p err
$ systemctl list-units --failed
  UNIT                  LOAD   ACTIVE SUB    DESCRIPTION
● var-log.mount         loaded failed failed /var/log

$ systemctl status var-log.mount
$ blkid | grep -i varlog      # the actual, current UUID
$ vi /etc/fstab               # correct it
$ systemctl daemon-reload
$ mount -a
$ findmnt --verify
$ systemctl default
```

**Prevención.** Agregar `nofail,x-systemd.device-timeout=15s` a todo montaje no esencial. Un volumen de datos nunca debe poder impedir que el nodo arranque y sea alcanzable por SSH — no se puede arreglar aquello a lo que no se puede entrar.

---

**Síntoma: `/boot` está lleno; una actualización de kernel "tuvo éxito" pero el sistema no arranca.**

```
$ sudo dnf install kernel
...
Error: Transaction test error:
  installing package kernel-core-5.14.0-503.el9.x86_64 needs 92MB on the /boot filesystem
```

O peor — *parece* tener éxito y `dracut` escribe un initramfs truncado. Al arrancar:

```
dracut-initqueue[521]: Warning: dracut-initqueue: timeout, still waiting for following initqueue hooks:
dracut-initqueue[521]: Warning: /lib/dracut/hooks/initqueue/finished/devexists-...sh
Generating "/run/initramfs/rdsosreport.txt"
dracut:/#
```

**Diagnóstico.**

```bash
$ df -h /boot
Filesystem      Size  Used Avail Use% Mounted on
/dev/nvme0n1p3  488M  461M   -3M 101% /boot

$ ls -1 /boot/vmlinuz-*
/boot/vmlinuz-5.14.0-284.el9.x86_64
/boot/vmlinuz-5.14.0-362.el9.x86_64
/boot/vmlinuz-5.14.0-427.el9.x86_64
/boot/vmlinuz-5.14.0-503.el9.x86_64
/boot/vmlinuz-5.14.0-570.el9.x86_64
```

**Reparación.**

```bash
# Remove old kernels — RHEL family
$ sudo dnf remove --oldinstallonly --setopt installonly_limit=2 kernel

# Debian/Ubuntu
$ sudo apt-get --purge autoremove

# Rebuild the current initramfs to be sure it is complete
$ sudo dracut --force --verbose /boot/initramfs-$(uname -r).img $(uname -r)
$ sudo grub2-mkconfig -o /boot/grub2/grub.cfg     # RHEL BIOS
$ sudo update-grub                                 # Debian/Ubuntu
```

**Prevención.** `/boot` de 1 GiB, `installonly_limit=3`, y una alerta de monitoreo al 70 % específicamente sobre `/boot` — no solo sobre `/`.

---

**Síntoma: "No space left on device" pero `df` muestra espacio libre.**

```bash
$ df -h /var/lib/kubelet
Filesystem                  Size  Used Avail Use% Mounted on
/dev/mapper/datavg-kubelet  160G   58G  103G  36% /var/lib/kubelet

$ touch /var/lib/kubelet/x
touch: cannot touch '/var/lib/kubelet/x': No space left on device
```

**Causa: agotamiento de inodos.** Millones de archivos pequeños (capas de contenedores, volúmenes emptyDir, archivos de log por pod) consumieron todos los inodos sin casi tocar el conteo de bloques.

```bash
$ df -i /var/lib/kubelet
Filesystem                    Inodes   IUsed IFree IUse% Mounted on
/dev/mapper/datavg-kubelet  83886080 83886080     0  100% /var/lib/kubelet
```

**Por qué XFS hace esto menos común pero no imposible.** XFS asigna inodos dinámicamente, así que rara vez los agota — *salvo* que `imaxpct` (25 % por defecto) limite el espacio de inodos, o que el sistema de archivos esté restringido a inodos de 32 bits. ext4 asigna inodos **estáticamente en el momento del `mkfs`** y no puede agregar más, nunca.

```bash
# ext4: choose the ratio at creation. Default bytes-per-inode is 16384.
$ sudo mkfs.ext4 -i 4096 -L manyfiles /dev/datavg/kubelet   # 4x the inodes

# XFS: raise the inode percentage cap online
$ sudo xfs_growfs -m 50 /var/lib/kubelet
```

**Prevención.** Alertar sobre `df -i` junto con `df -h`. Usar XFS para cualquier ruta que aloje capas de contenedores o spools de correo.

---

**Síntoma: `df` dice 95 % lleno; `du` da cuenta de solo el 40 %.**

```bash
$ df -h /var/log
Filesystem                Size  Used Avail Use% Mounted on
/dev/mapper/sysvg-varlog   20G   19G  1.1G  95% /var/log

$ sudo du -sh /var/log
7.8G	/var/log
```

**Causa: archivos borrados pero todavía abiertos.** Una rotación de logs eliminó un archivo que un proceso sigue teniendo abierto. La entrada de directorio ya no está (`du` no puede verla), pero el inodo y sus extents persisten hasta que se cierra el último descriptor.

```bash
$ sudo lsof +L1 /var/log
COMMAND     PID USER   FD   TYPE DEVICE   SIZE/OFF NLINK  NODE NAME
java     284917  app    3w   REG  253,3 11274289152     0 17301504 /var/log/app/application.log (deleted)

# Reclaim without a restart, if you must:
$ sudo truncate -s 0 /proc/284917/fd/3

# Correct fix: make logrotate signal the process.
```

```
# /etc/logrotate.d/app
/var/log/app/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    copytruncate      # or: postrotate <signal the process> endscript
    su root app
}
```

---

**Síntoma: "Necesito achicar `/home` y darle el espacio a `/var`". XFS.**

No existe el achicar. El procedimiento es backup → destruir → recrear → restaurar:

```bash
$ sudo systemctl isolate rescue.target
$ sudo xfsdump -l 0 -f /mnt/backup/home.dump /home
$ sudo umount /home
$ sudo lvremove /dev/sysvg/home
$ sudo lvcreate -L 10G -n home sysvg
$ sudo mkfs.xfs -L home /dev/sysvg/home
$ sudo mount /home
$ sudo xfsrestore -f /mnt/backup/home.dump /home
$ sudo lvextend -L +10G -r /dev/sysvg/var
```

Downtime para `/home`, una restauración completa y riesgo — todo para recuperar 10 GiB. **Por esto se asigna de forma conservadora y se dejan extents libres.** El error se cometió en el momento de la instalación, no hoy.

---

**Síntoma: el throughput secuencial es aproximadamente la mitad de lo que el dispositivo declara.**

```bash
$ lsblk -o NAME,ALIGNMENT,PHY-SEC,LOG-SEC,MIN-IO,OPT-IO /dev/sdb
NAME ALIGNMENT PHY-SEC LOG-SEC MIN-IO OPT-IO
sdb          0    4096     512   4096      0
└─sdb1    3584    4096     512   4096      0     ← misaligned by 3584 bytes
```

**Causa.** La partición arranca en el sector 63 (alineación CHS heredada) sobre un dispositivo 4Kn/512e. Cada bloque del sistema de archivos cruza dos sectores físicos, forzando lectura-modificación-escritura.

**Reparación.** No hay arreglo in situ — el inicio de la partición debe moverse, lo que implica mover datos. Hacer backup, reparticionar con `sgdisk -a 2048`, restaurar. En un arreglo RAID verificar además la geometría de stripe del sistema de archivos:

```bash
$ xfs_info /data | grep -E 'sunit|swidth'
data     =                       bsize=4096   blocks=524288000, imaxpct=5
         =                       sunit=64     swidth=256 blks
```

`sunit=0 swidth=0` en un arreglo RAID significa que el sistema de archivos desconoce el stripe. Corregir en el momento del montaje como mitigación parcial:

```bash
$ sudo mount -o remount,sunit=128,swidth=512 /data
```

---

**Síntoma: un thin pool de LVM llegó al 100 %.**

```
$ dmesg | tail
[92841.221] device-mapper: thin: 253:5: reached low water mark for data device: sending event.
[92903.774] device-mapper: thin: 253:5: switching pool to out-of-data-space mode
[93083.918] device-mapper: thin: 253:5: switching pool to read-only mode
[93083.921] EXT4-fs error (device dm-7): ext4_journal_check_start: Detected aborted journal
```

**Diagnóstico y acción inmediata.**

```bash
$ sudo lvs -o lv_name,lv_size,data_percent,metadata_percent,pool_lv
  LV        LSize    Data%  Meta%  Pool
  thinpool  500.00g  100.00 62.14
  vm01       200.00g  99.87        thinpool
  vm02       200.00g  98.02        thinpool
  vm03       200.00g  97.55        thinpool

# Add physical capacity to the pool NOW.
$ sudo lvextend -L +200G /dev/vg0/thinpool
$ sudo lvchange -ay vg0/vm01
$ sudo fsck -y /dev/vg0/vm01
```

Notar `Meta% 62.14` — el LV de **metadata** puede agotarse independientemente del LV de datos y es el fallo más difícil. Extenderlo por separado con `lvextend --poolmetadatasize`.

**Prevención.** `thin_pool_autoextend_threshold = 70` en `lvm.conf`, monitoreo sobre `data_percent` **y** `metadata_percent`, y nunca usar thin provisioning para un sistema de archivos del SO en producción.

---

**Síntoma: `Invalid partition table` / corrupción de la cabecera GPT.**

```bash
$ sudo gdisk /dev/sdb
GPT fdisk (gdisk) version 1.0.9

Caution: invalid main GPT header, but valid backup; regenerating main header
from backup!

Warning: Invalid CRC on main header data; loaded backup partition table.
Proceed? (Y/N):
```

Esto es la redundancia de GPT ganándose el sueldo — la cabecera de backup en el último LBA reconstruye la primaria. Reparación:

```bash
$ sudo sgdisk --verify /dev/sdb
Problem: The secondary header's self-pointer indicates that it doesn't reside
at the end of the disk. Using -e to fix.

# Move the backup header to the true end (needed after a device grows)
$ sudo sgdisk -e /dev/sdb
Warning: The kernel is still using the old partition table.
The new table will be used at the next reboot or after you run partprobe(8).
The operation has completed successfully.

$ sudo partprobe /dev/sdb
```

---

### 12.3 Referencia de comandos de diagnóstico

| Pregunta | Comando |
|---|---|
| Árbol de dispositivos, tamaños, sistemas de archivos, montajes | `lsblk -f` / `lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS` |
| Tamaños de sector, alineación, hints de I/O | `lsblk -o NAME,PHY-SEC,LOG-SEC,MIN-IO,OPT-IO,ALIGNMENT` |
| UUIDs, etiquetas, tipos de sistema de archivos | `blkid` / `lsblk -o NAME,UUID,LABEL` |
| Contenido de la tabla de particiones | `sgdisk -p <dev>` / `parted <dev> print` / `fdisk -l <dev>` |
| ¿Está alineada una partición? | `parted <dev> align-check optimal <n>` |
| Espacio usado | `df -h` (bloques) y `df -i` (inodos) — **ambos** |
| A dónde se fue el espacio | `du -xh --max-depth=1 /var \| sort -h` (`-x` se queda en un solo sistema de archivos) |
| Archivos borrados pero abiertos | `lsof +L1` |
| Montajes tal como los ve el kernel | `findmnt` / `findmnt -D` / `cat /proc/mounts` |
| ¿Es válido fstab? | `findmnt --verify --verbose` |
| Estado de LVM | `pvs` / `vgs` / `lvs` (agregar `-a` para LVs ocultos, `-o +devices`) |
| Detalle verboso de LVM | `pvdisplay` / `vgdisplay` / `lvdisplay -m` (mapa de segmentos) |
| Historial de cambios de LVM | `journalctl -u lvm2-monitor` y `/etc/lvm/archive/` |
| Geometría XFS | `xfs_info <mountpoint>` |
| Superbloque ext4 | `tune2fs -l <device>` |
| Swap en uso | `swapon --show` / `free -h` / `cat /proc/swaps` |
| Modo de firmware | `[ -d /sys/firmware/efi ] && echo UEFI \|\| echo BIOS` |
| Estado del boot loader | `bootctl status` / `efibootmgr -v` |
| Presión de I/O por dispositivo | `iostat -xz 1` / `cat /proc/pressure/io` |
| Releer una tabla de particiones modificada | `partprobe <dev>` / `partx -u <dev>` / `blockdev --rereadpt <dev>` |

---

## 13. Checklist de decisiones de diseño

Ejecutarla antes de cada instalación. Es el objetivo entero en forma operativa.

1. **¿Modo de firmware?** UEFI → GPT + ESP (≥ 512 MiB, 1 GiB con UKIs). BIOS + GPT → agregar la partición `ef02` de 1 MiB. BIOS + MBR → cuidado con el techo de 2 TiB.
2. **`/boot` separado, 1 GiB, partición plana, ext4 o XFS con features fijadas.** Ni thin, ni LUKS2/Argon2id, ni RAID5.
3. **¿Qué crece sin límite en este sistema?** Logs → `/var/log`. Contenedores → `/var/lib/containerd`. Usuarios → `/home`. Bases de datos → su propio dispositivo. Cada uno recibe un sistema de archivos.
4. **¿Qué debe ser `noexec`/`nosuid`/`nodev`?** `/tmp`, `/var/tmp`, `/home`, `/dev/shm`, `/boot`. Cada uno necesita ser un montaje separado para que la opción exista.
5. **¿Qué tiene un requisito independiente de durabilidad o latencia?** WAL/redo, etcd, logs de auditoría. Dispositivos físicos separados, no solo LVs separados.
6. **¿LVM, sí o no?** De larga vida y físico → sí. Ganado en la nube → no, usar las APIs de volúmenes.
7. **Asignar de forma conservadora.** Dejar ≥ 50 % del VG sin asignar. XFS no puede achicarse; los extents libres son la única flexibilidad que va a haber.
8. **Swap: 4–8 GiB, `vm.swappiness=10`.** Del tamaño de la RAM solo si la hibernación es un requisito genuino. Los nodos de Kubernetes necesitan una política explícita en cualquier caso.
9. **Alineación de 1 MiB en todos lados.** Verificar con `parted align-check`, no por suposición.
10. **Montar por UUID o por ruta `/dev/mapper/`.** Nunca por `/dev/sdX`.
11. **`nofail,x-systemd.device-timeout=15s` en todo montaje no esencial.** Un volumen de datos ausente nunca debe costar el acceso por SSH.
12. **`findmnt --verify` antes del primer reinicio.** Siempre.

---

## 14. Referencias

**Objetivos de la certificación**
- LPI — Objetivos del examen 101-500: https://www.lpi.org/our-certifications/exam-101-objectives/
- LPI — Objetivos del examen 102-500 (el tema 102.1 vive acá): https://www.lpi.org/our-certifications/exam-102-objectives/
- LPI — Descripción general de la certificación LPIC-1: https://www.lpi.org/our-certifications/lpic-1-overview/

**Estándares y especificaciones**
- Filesystem Hierarchy Standard 3.0 (Linux Foundation): https://refspecs.linuxfoundation.org/FHS_3.0/fhs/index.html
- UEFI Specification (UEFI Forum): https://uefi.org/specifications
- Discoverable Partitions Specification (systemd/UAPI Group): https://uapi-group.org/specifications/specs/discoverable_partitions_specification/
- Boot Loader Specification (UAPI Group): https://uapi-group.org/specifications/specs/boot_loader_specification/

**Páginas de manual y documentación de herramientas**
- `fstab(5)`: https://man7.org/linux/man-pages/man5/fstab.5.html
- `mount(8)` — opciones independientes del sistema de archivos y por sistema de archivos: https://man7.org/linux/man-pages/man8/mount.8.html
- `lsblk(8)`: https://man7.org/linux/man-pages/man8/lsblk.8.html
- `parted(8)`: https://www.gnu.org/software/parted/manual/parted.html
- `sgdisk(8)` / documentación de GPT fdisk: https://www.rodsbooks.com/gdisk/
- `mkswap(8)`: https://man7.org/linux/man-pages/man8/mkswap.8.html
- `swapon(8)`: https://man7.org/linux/man-pages/man8/swapon.8.html
- `findmnt(8)`: https://man7.org/linux/man-pages/man8/findmnt.8.html
- Documentación del proyecto util-linux: https://github.com/util-linux/util-linux

**LVM**
- Proyecto LVM2 (sourceware.org): https://sourceware.org/lvm2/
- `lvm(8)`: https://man7.org/linux/man-pages/man8/lvm.8.html
- `lvmthin(7)` — thin provisioning: https://man7.org/linux/man-pages/man7/lvmthin.7.html
- Red Hat — Configuring and managing logical volumes (RHEL 9): https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/configuring_and_managing_logical_volumes/index

**Sistemas de archivos**
- Documentación de XFS (kernel.org): https://docs.kernel.org/filesystems/xfs/index.html
- `mkfs.xfs(8)`: https://man7.org/linux/man-pages/man8/mkfs.xfs.8.html
- Documentación de ext4 (kernel.org): https://docs.kernel.org/filesystems/ext4/index.html
- Documentación de Btrfs: https://btrfs.readthedocs.io/en/latest/
- Documentación de `tmpfs` (kernel.org): https://docs.kernel.org/filesystems/tmpfs.html

**Cadena de arranque**
- Manual de GNU GRUB: https://www.gnu.org/software/grub/manual/grub/grub.html
- `systemd-boot(7)` / `bootctl(1)`: https://www.freedesktop.org/software/systemd/man/latest/bootctl.html
- `systemd-fstab-generator(8)`: https://www.freedesktop.org/software/systemd/man/latest/systemd-fstab-generator.html
- `systemd-gpt-auto-generator(8)`: https://www.freedesktop.org/software/systemd/man/latest/systemd-gpt-auto-generator.html
- `systemd.mount(5)`: https://www.freedesktop.org/software/systemd/man/latest/systemd.mount.html
- Documentación de `dracut`: https://man7.org/linux/man-pages/man8/dracut.8.html

**Guías de instalación y layout por distribución**
- Red Hat — Recommended partitioning scheme (RHEL 9): https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/performing_a_standard_rhel_9_installation/
- Red Hat — Recommended system swap space: https://access.redhat.com/solutions/15244
- Referencia de Kickstart (Anaconda / Fedora): https://pykickstart.readthedocs.io/en/latest/kickstart-docs.html
- Referencia de módulos de cloud-init (`growpart`, `disk_setup`, `mounts`, `swap`): https://cloudinit.readthedocs.io/en/latest/reference/modules.html
- Especificación de configuración de Butane (Fedora CoreOS): https://coreos.github.io/butane/config-fcos-v1_5/
- Especificación de Ignition: https://coreos.github.io/ignition/configuration-v3_4/
- Debian — Recommended partitioning scheme: https://www.debian.org/releases/stable/amd64/apcs03.en.html
- Documentación de Ubuntu Server: https://documentation.ubuntu.com/server/

**Tunables del kernel e integración con contenedores/orquestadores**
- `sysctl/vm.rst` del kernel (`swappiness`, `vfs_cache_pressure`, `min_free_kbytes`): https://docs.kernel.org/admin-guide/sysctl/vm.html
- Documentación de `zram` del kernel: https://docs.kernel.org/admin-guide/blockdev/zram.html
- Kubernetes — Node-pressure eviction: https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/
- Kubernetes — Local volumes and storage: https://kubernetes.io/docs/concepts/storage/volumes/#local
- Kubernetes — Swap memory management on nodes: https://kubernetes.io/docs/concepts/architecture/nodes/#swap-memory

**Líneas base de hardening**
- CIS Benchmarks (controles de particionado y opciones de montaje): https://www.cisecurity.org/cis-benchmarks
- DISA STIGs para Linux: https://public.cyber.mil/stigs/