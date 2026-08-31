# LPIC-1 · Tema 102.2 — Instalar un gestor de arranque

**Examen:** 101-500 (LPIC-1 v5.0) · **Peso:** 3.13 · **Nivel:** Producción / SRE / Arquitecto de plataforma

**Cobertura del objetivo:**
- Proveer ubicaciones de arranque alternativas y opciones de arranque de respaldo
- Instalar y configurar un gestor de arranque como GRUB Legacy
- Realizar cambios básicos de configuración en GRUB 2
- Interactuar con el gestor de arranque

**Archivos, términos y utilidades clave:** `menu.lst`, `grub.cfg`, `grub.conf`, `grub-install`, `grub-mkconfig`, MBR

---

## 1. Motivación: el problema arquitectónico

El gestor de arranque es el único componente de un sistema Linux que **no se puede arreglar por SSH**. Cualquier otro modo de fallo en una flota — un runtime de contenedores trabado, una base de datos de paquetes corrupta, un disco lleno — deja una shell disponible. Un gestor de arranque roto deja una consola serie, una sesión KVM-over-IP o un ticket al datacenter.

Esta asimetría define todo el problema de ingeniería:

| Capa | Radio de impacto del fallo | Canal de remediación | MTTR a escala de flota |
|---|---|---|---|
| Aplicación | 1 pod / 1 proceso | reinicio por el orquestador | segundos |
| Kernel / initramfs | 1 nodo | reiniciar al kernel anterior | ~1 min (si existe una entrada de respaldo) |
| Configuración del gestor de arranque (`grub.cfg`) | 1 nodo | medio de rescate, chroot | 15–60 min |
| Stage 1 / core image del gestor de arranque (MBR / ESP) | 1 nodo, **inalcanzable** | consola física u OOB | horas |
| Configuración del gestor de arranque distribuida por gestión de configuración | **flota entera, simultáneamente** | consola OOB por nodo | días |

Esa última fila es la que termina carreras. Un solo play de Ansible que ejecuta `grub-mkconfig` con un `GRUB_CMDLINE_LINUX` incorrecto sobre 800 nodos y después dispara un reinicio progresivo convierte un cambio de software en un problema de acceso físico. La lección incrustada en cada práctica que sigue: **los cambios en el gestor de arranque son puertas de un solo sentido salvo que se construya explícitamente la puerta de vuelta.**

Tres incidentes concretos de producción que este tema existe para prevenir:

1. **Las secuelas de BootHole (CVE-2020-10713, julio de 2020).** Las distribuciones publicaron paquetes `grub2` nuevos. Los *módulos* de GRUB bajo `/boot/grub/i386-pc/` se actualizaron en disco, pero la *core image* embebida en el hueco posterior al MBR **no** se reinstaló, porque `grub-install` no lo ejecuta automáticamente el hook del paquete en todas las distribuciones. En el siguiente reinicio: `error: symbol 'grub_calloc' not found` y un prompt `grub rescue>`. Miles de hosts, en todo el mundo, fuera de línea a la vez.
2. **El MBR sin espejar.** Un array RAID1 raíz sobrevive a la pérdida de `/dev/sda`. El código de arranque en el MBR de `/dev/sda` no — porque nunca se escribió en `/dev/sdb`. El array está sano; la máquina no va a arrancar en él desde el POST.
3. **El argumento de kernel que solo falla después de reiniciar.** `GRUB_CMDLINE_LINUX="... root=/dev/sda2"` horneado en una golden image. Más adelante la imagen se despliega sobre hardware NVMe donde el dispositivo es `/dev/nvme0n1p2`. `dracut` cae a una shell de emergencia en todos los nodos del rack nuevo.

Todo en este documento está organizado alrededor de hacer que estas tres clases de fallo sean *detectables antes del reinicio* y *recuperables sin acceso físico*.

---

## 2. La cadena de arranque: qué hace realmente el gestor

### 2.1 Ruta BIOS / MBR (legacy, target `i386-pc`)

```
Power on
  └─ BIOS POST
      └─ reads sector 0 (LBA 0) of the boot device — 512 bytes: the MBR
          ├─ bytes 0..445    : bootstrap code   ← GRUB boot.img / GRUB Legacy stage1
          ├─ bytes 446..509  : 4 × 16-byte partition table entries
          └─ bytes 510..511  : 0x55 0xAA signature
              └─ boot.img (446 bytes!) knows ONE thing: the LBA of core.img
                  └─ core.img lives in the "post-MBR gap" (LBA 1 .. 2047)
                     or in a BIOS Boot Partition (GPT, type EF02)
                      └─ core.img contains: diskboot + filesystem drivers
                                            + the `prefix` (e.g. (hd0,msdos1)/boot/grub)
                          └─ loads normal.mod, reads grub.cfg
                              └─ loads vmlinuz + initramfs into RAM
                                  └─ jumps to the kernel entry point
```

El presupuesto de 446 bytes es la razón por la que la cadena tiene tantas etapas: no hay espacio suficiente en el MBR para un driver de sistema de archivos. GRUB Legacy resolvió esto con **stage1 → stage1_5 (específico del sistema de archivos, en el hueco) → stage2 (en `/boot/grub`)**. GRUB 2 colapsa stage1_5 y stage2 en una única `core.img` generada, cuyo conjunto de módulos se elige en el momento de la instalación por `grub-install`.

**Consecuencia crítica:** `core.img` contiene una lista de sectores fija. Desfragmentar `/boot`, restaurarlo desde un backup o cambiar el sistema de archivos por debajo puede invalidar esa lista. Por eso hay que volver a ejecutar `grub-install` después de cualquier operación que mueva `/boot/grub`.

### 2.2 Ruta UEFI (target `x86_64-efi`)

```
Power on
  └─ UEFI firmware initialises
      └─ reads NVRAM variables: BootOrder, Boot0000..Bootxxxx, BootNext
          └─ each Bootxxxx = device path + file path, e.g.
             HD(1,GPT,<part-uuid>,...)/File(\EFI\debian\shimx64.efi)
              └─ mounts the EFI System Partition (ESP): FAT32, type EF00
                  └─ executes the PE/COFF binary directly — no MBR involved
                      ├─ Secure Boot ON : shimx64.efi → grubx64.efi → vmlinuz
                      └─ Secure Boot OFF: grubx64.efi → vmlinuz
```

En un sistema UEFI **no hay bootstrap en el MBR**. `grub-install` sobre UEFI copia un binario EFI dentro de la ESP y llama a `efibootmgr` para escribir una entrada en la NVRAM. Si el firmware no encuentra ninguna entrada `Bootxxxx` válida, recurre a la **ruta de medio extraíble**: `\EFI\BOOT\BOOTX64.EFI`.

### 2.3 La frontera que hay que saber trazar

| Responsabilidad | Dueño | ¿Se arregla sin reiniciar? |
|---|---|---|
| Encontrar el archivo del kernel | gestor de arranque | no |
| Pasar la línea de comandos del kernel | gestor de arranque | no |
| Cargar `initramfs` en memoria | gestor de arranque | no |
| Ensamblar RAID / desbloquear LUKS / activar LVM | **initramfs** (`dracut`, `initramfs-tools`) | no |
| Montar el sistema de archivos raíz real | initramfs | no |
| `switch_root` y ejecutar PID 1 | initramfs | no |
| Todo lo posterior | systemd | sí |

Una fracción grande de los tickets de "GRUB está roto" son en realidad fallos del initramfs. El diagnóstico es posicional: si se ve un menú de GRUB, GRUB funciona. Si se ve `dracut:/#` o `(initramfs)`, GRUB hizo su trabajo y entregó el control correctamente.

---

## 3. Análisis comparativo: qué gestor de arranque, y por qué

### 3.1 Matriz de características / compromisos

| | **GRUB Legacy** (0.9x) | **GRUB 2** (2.xx) | **systemd-boot** | **SYSLINUX / EXTLINUX** | **rEFInd** | **U-Boot** |
|---|---|---|---|---|---|---|
| Soporte de firmware | solo BIOS | BIOS, UEFI, coreboot, IEEE1275, ARM | **solo UEFI** | BIOS (`syslinux`/`isolinux`), UEFI (limitado) | solo UEFI | embebido/ARM |
| Lee sistemas de archivos Linux | ext2/3, ReiserFS, XFS, JFS, FAT | ext2/3/4, XFS, Btrfs, ZFS, F2FS, LVM, mdraid, LUKS1/2, HFS+, NTFS… | **solo FAT** (ESP) | ext2/3/4, Btrfs, FAT | FAT + ext (driver) | muchos |
| Formato de configuración | estático, `menu.lst` editado a mano | `grub.cfg` **generado** + lenguaje de scripting | archivos `.conf` declarativos (BLS) | `syslinux.cfg` estático | autodescubrimiento + `refind.conf` | entorno con scripts |
| Scripting (`if`, bucles, funciones) | no | **sí** | no | no | no | sí |
| Arranca desde LVM / RAID / `/boot` cifrado | no | **sí** | no | no (necesita partición plana) | no | no |
| Cadena Secure Boot (firmada por shim) | no | **sí** | sí | rara vez | sí | n/a |
| Arranque por red | limitado | `grub-mknetdir`, TFTP/HTTP | no | **PXELINUX — el clásico** | no | sí |
| Conteo de arranques / rollback automático | directiva `fallback` | `grubenv` + scripting | conteo `+N-M` en el nombre del archivo de entrada | no | no | `bootcount` |
| Complejidad de configuración | baja | **alta** | **muy baja** | baja | muy baja | alta |
| Superficie de ataque / historial de CVE | congelado (EOL) | grande (BootHole, SBAT) | pequeña | pequeña | pequeña | grande |
| Uso típico en los años 2020 | RHEL/CentOS ≤ 6, appliances legacy | **predeterminado casi en todas partes** | Arch, Pop!_OS, hosts inmutables/UKI, nube | ISOs, PXE, embebido | estaciones multiboot | SBC ARM |

### 3.2 Guía de decisión del arquitecto

| Requisito | Elegir | Fundamento |
|---|---|---|
| Flota heterogénea, BIOS + UEFI, una sola base de código de gestión de configuración | **GRUB 2** | una herramienta, un generador de configuración, ambos targets |
| `/boot` sobre LVM, mdraid, subvolumen Btrfs o LUKS | **GRUB 2** | el único gestor con los drivers de sistema de archivos |
| SO inmutable / basado en imágenes con UKIs (Unified Kernel Images) | **systemd-boot** | sin paso de generación de configuración, sin scripting, superficie de ataque mínima |
| Rack solo con consola serie, necesita edición interactiva en el arranque | **GRUB 2** | soporte maduro de `GRUB_TERMINAL=serial` y menú editable |
| Arranque por PXE de un instalador o un entorno de rescate | **PXELINUX** o **GRUB 2 netboot** | PXELINUX es más simple; GRUB 2 maneja HTTP boot de UEFI |
| Mantener RHEL 6 / appliance legacy | **GRUB Legacy** | es lo que está instalado; no migres un sistema que no podés reinstalar |
| Arranque con rollback automático ante un arranque fallido | **GRUB 2** + conteo en `grubenv`, o conteo de **systemd-boot** | requiere estado persistente y escribible por el gestor |

**La posición honesta:** en una flota Linux de propósito general en 2026, GRUB 2 es la opción predeterminada y la correcta, no porque sea elegante — no lo es; es un pequeño sistema operativo con un lenguaje de shell — sino porque es el único gestor que puede leer el stack de almacenamiento que realmente se usa.

### 3.3 GRUB Legacy vs GRUB 2 — las diferencias que le importan tanto al examen como a producción

| Aspecto | GRUB Legacy | GRUB 2 |
|---|---|---|
| Archivo de configuración | `/boot/grub/menu.lst` (Debian) · `/boot/grub/grub.conf` + symlink (Red Hat) | `/boot/grub/grub.cfg` (Debian) · `/boot/grub2/grub.cfg` (Red Hat) |
| La configuración la edita | **uno mismo, directamente** | **nunca directamente** — la regenera `grub-mkconfig` |
| Entradas de la configuración | n/a | `/etc/default/grub` + `/etc/grub.d/*` |
| **Numeración de particiones** | **desde 0** — `(hd0,0)` es la primera partición | **desde 1** — `(hd0,1)` es la primera partición |
| Tabla de particiones en el nombre del dispositivo | no | sí — `(hd0,msdos1)`, `(hd0,gpt2)` |
| Numeración de discos | desde 0 — `(hd0)` es el primer disco | desde 0 — sin cambios |
| Palabra clave del ítem de menú | `title <free text>` | `menuentry '<text>' --id <stable-id> { … }` |
| Selección predeterminada | `default 0` (índice) o `default saved` | `GRUB_DEFAULT=0` / `"menu>submenu"` / `saved` |
| Entrada de fallback | `fallback 1` | `set fallback=…` en el script generado / `grubenv` |
| Etapas en disco | stage1, stage1_5, stage2 | `boot.img`, `core.img` (generada), módulos `*.mod` |
| Módulos | compilados dentro | archivos `.mod` cargables, `insmod` en tiempo de ejecución |
| Comando de instalación | `grub-install` o `root`/`setup` interactivos | solo `grub-install` |
| Contraseña | `password --md5 <hash>` | `set superusers` + `password_pbkdf2` |
| Rescate interactivo | shell `grub>` | `grub>` (completo) y `grub rescue>` (mínimo) |

> **Trampa de examen, dicha sin rodeos:** el desfase de uno en la numeración de particiones es el dato más evaluado de este objetivo. `(hd0,0)` de GRUB Legacy y `(hd0,1)` de GRUB 2 se refieren a **la misma partición** — la primera del primer disco, convencionalmente `/dev/sda1`.

---

## 4. Inspeccionar la topología de arranque actual

Antes de tocar nada, establecé la verdad de campo. Nunca asumas el modo de firmware.

### 4.1 ¿Estoy en UEFI o en BIOS?

```console
$ [ -d /sys/firmware/efi ] && echo "UEFI" || echo "BIOS/CSM"
UEFI

$ cat /sys/firmware/efi/fw_platform_size
64
```

`/sys/firmware/efi` existe **solo** si el kernel fue arrancado por firmware UEFI. Una máquina capaz de UEFI arrancada en modo CSM/legacy va a reportar BIOS — lo cual es correcto, porque así es como hay que reinstalarla.

### 4.2 Disposición de discos y particiones

```console
$ lsblk -o NAME,SIZE,TYPE,FSTYPE,PARTTYPENAME,LABEL,MOUNTPOINTS
NAME        SIZE TYPE FSTYPE PARTTYPENAME              LABEL  MOUNTPOINTS
sda       465.8G disk
├─sda1        1M part                BIOS boot
├─sda2      512M part  vfat          EFI System                /boot/efi
├─sda3        1G part  ext4          Linux filesystem   boot   /boot
└─sda4    464.3G part  LVM2_member   Linux LVM
  ├─vg0-root  50G lvm  xfs                                     /
  └─vg0-data 400G lvm  xfs                                     /srv
sdb       465.8G disk
├─sdb1        1M part                BIOS boot
├─sdb2      512M part  vfat          EFI System
├─sdb3        1G part  ext4          Linux filesystem   boot2
└─sdb4    464.3G part  LVM2_member   Linux LVM
```

Esto es una **disposición híbrida arrancable con doble ESP** — arrancable bajo ambos modos de firmware, desde cualquiera de los dos discos. La sección 8 muestra cómo construirla y mantenerla.

```console
$ sudo parted /dev/sda print
Model: ATA Samsung SSD 870 (scsi)
Disk /dev/sda: 500GB
Sector size (logical/physical): 512B/512B
Partition Table: gpt
Disk Flags:

Number  Start   End     Size    File system  Name                  Flags
 1      1049kB  2097kB  1049kB               BIOS boot partition   bios_grub
 2      2097kB  539MB   537MB   fat32        EFI System Partition  boot, esp
 3      539MB   1613MB  1074MB  ext4         boot
 4      1613MB  500GB   498GB                data                  lvm
```

> **`bios_grub` no es opcional.** En un disco GPT arrancado vía BIOS no hay un hueco post-MBR confiable (la cabecera primaria de GPT ocupa el LBA 1 y el array de particiones los LBA 2–33). Sin una partición de ~1 MiB de tipo `EF02` marcada `bios_grub`, `grub-install --target=i386-pc` falla con:
> `grub-install: error: will not proceed with blocklists`.

### 4.3 Qué pretende arrancar el firmware actualmente

```console
$ sudo efibootmgr -v
BootCurrent: 0005
Timeout: 2 seconds
BootOrder: 0005,0006,0002,0001,0003
Boot0001  UiApp	FvVol(7cb8bdc9-f8eb-4f34-aaea-3ee4af6516a1)/FvFile(462caa21-7614-4503-836e-8ab6f4662331)
Boot0002* UEFI Shell	FvVol(7cb8bdc9-f8eb-4f34-aaea-3ee4af6516a1)/FvFile(7c04a583-9e3e-4f1c-ad65-e05268d0b4d1)
Boot0003* UEFI PXEv4 (MAC:52540012A4E7)	PciRoot(0x0)/Pci(0x3,0x0)/MAC(52540012a4e7,1)/IPv4(0.0.0.00.0.0.0,0,0)
Boot0005* debian	HD(2,GPT,9f4a1c2e-6b30-4a51-9c88-1d2e3f4a5b6c,0x800,0x100000)/File(\EFI\DEBIAN\SHIMX64.EFI)
Boot0006* debian-mirror	HD(2,GPT,c7d8e9f0-1a2b-3c4d-5e6f-708192a3b4c5,0x800,0x100000)/File(\EFI\DEBIAN\SHIMX64.EFI)
```

Leé esto con atención — codifica la política *completa* de arranque UEFI:

- `BootCurrent: 0005` — la entrada que el firmware realmente usó en este arranque.
- `BootOrder` — la lista de intentos en secuencia. `0006` (la ESP espejo en `/dev/sdb2`) va segunda: si `/dev/sda` muere, el firmware cae a ella automáticamente. **Esa es la "opción de arranque de respaldo" que pide el objetivo, implementada en NVRAM.**
- La ruta de dispositivo `HD(2,GPT,<uuid>,...)` referencia el **GUID de la partición**, no `/dev/sdX`. Clonar un disco con `dd` duplica el GUID y produce dos dispositivos que el firmware no puede distinguir — siempre hacé `sgdisk -G` sobre un clon.
- `Boot0003` PXE al final: una ruta de rescate por red cuando ambos discos fallan.

### 4.4 Qué gestor está instalado realmente

```console
$ grub-install --version
grub-install (GRUB) 2.06-13+deb12u1

$ sudo dd if=/dev/sda bs=512 count=1 status=none | strings | head -5
ZRr=
`|f
\|f1
GRUB
Geom

$ sudo grub-probe --target=device /boot
/dev/sda3
$ sudo grub-probe --target=fs /boot
ext2
$ sudo grub-probe --target=partmap /boot
gpt
$ sudo grub-probe --target=abstraction /
lvm
```

`grub-probe` es el motor de introspección que `grub-install` y `grub-mkconfig` usan internamente. Que `--target=abstraction` diga `lvm` significa que `core.img` **debe** contener el módulo `lvm` o el sistema no va a arrancar.

---

## 5. GRUB 2 — configuración e instalación

### 5.1 El pipeline de generación

```
/etc/default/grub        (shell-sourced key=value — the knobs you turn)
        +
/etc/grub.d/*            (executable scripts, run in lexical order)
        │  00_header     ← timeout, default, gfx, serial, grubenv loading
        │  05_debian_theme
        │  10_linux      ← scans /boot for vmlinuz-* and initrd*, emits menuentries
        │  20_linux_xen
        │  30_os-prober  ← scans other partitions for foreign OSes
        │  30_uefi-firmware ← "System setup" entry (fwsetup)
        │  40_custom     ← YOUR hand-written entries go here
        │  41_custom     ← sources /boot/grub/custom.cfg if present
        ▼
   grub-mkconfig  (Debian wrapper: update-grub · Red Hat: grub2-mkconfig)
        ▼
/boot/grub/grub.cfg      ← GENERATED. Never edit. Overwritten without warning.
```

La cabecera del archivo generado lo dice explícitamente:

```console
$ head -6 /boot/grub/grub.cfg
#
# DO NOT EDIT THIS FILE
#
# It is automatically generated by grub-mkconfig using templates
# from /etc/grub.d and settings from /etc/default/grub
#
```

**La disciplina:** todo cambio persistente va en `/etc/default/grub` o en `/etc/grub.d/40_custom`, ambos versionables e idempotentes. `grub.cfg` es salida de compilación, exactamente igual que un binario compilado.

### 5.2 Un `/etc/default/grub` completo, anotado para producción

```bash
# /etc/default/grub — managed by Ansible role: platform.bootloader
# Regenerate with: update-grub  (Debian) | grub2-mkconfig -o /boot/grub2/grub.cfg (RHEL)

# --- Selection ------------------------------------------------------------
# 'saved' makes GRUB read saved_entry from /boot/grub/grubenv, which is what
# grub-reboot / grub-set-default write. This is the prerequisite for the
# one-shot-kernel-test pattern (section 8.3).
GRUB_DEFAULT=saved
GRUB_SAVEDEFAULT=false          # do NOT auto-persist the last manual choice:
                                # it silently pins a node to an old kernel.
                                # Also incompatible with /boot on mdraid/LVM
                                # ("error: diskfilter writes are not supported").

# --- Timing ---------------------------------------------------------------
GRUB_TIMEOUT=5                  # servers: never 0. 5s is the cost of being able
                                # to intervene on a console during an incident.
GRUB_TIMEOUT_STYLE=menu         # menu | countdown | hidden
GRUB_RECORDFAIL_TIMEOUT=30      # Debian/Ubuntu: timeout used after a failed boot,
                                # so a headless box does not hang forever.

# --- Identity -------------------------------------------------------------
GRUB_DISTRIBUTOR="$(lsb_release -i -s 2>/dev/null || echo Debian)"

# --- Kernel command line --------------------------------------------------
# GRUB_CMDLINE_LINUX          -> applied to ALL entries, including recovery
# GRUB_CMDLINE_LINUX_DEFAULT  -> applied to normal entries only
#
# Never put root= here. It is derived by grub-mkconfig from the running
# system via grub-probe and is emitted per-entry with a UUID.
GRUB_CMDLINE_LINUX="console=tty0 console=ttyS0,115200n8 net.ifnames=0 biosdevname=0"
GRUB_CMDLINE_LINUX_DEFAULT="quiet loglevel=3 systemd.show_status=auto \
audit=1 slub_debug=- transparent_hugepage=madvise \
crashkernel=512M-2G:64M,2G-:256M"

# Ordering note: the LAST console= wins as /dev/console for userspace.
# ttyS0 last => systemd's console output goes to serial => OOB debuggable.

# --- Console --------------------------------------------------------------
GRUB_TERMINAL="console serial"  # render the menu on BOTH VGA and serial
GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"

# --- Modules that must be inside core.img ---------------------------------
# If /boot (or the prefix path) lives on these abstractions, core.img cannot
# read grub.cfg without them. grub-install usually infers this via grub-probe;
# declaring it explicitly makes the requirement auditable.
GRUB_PRELOAD_MODULES="part_gpt part_msdos lvm mdraid1x ext2"

# --- Menu shape -----------------------------------------------------------
GRUB_DISABLE_SUBMENU=y          # flatten "Advanced options >" so that every
                                # kernel is a top-level entry. Required for
                                # GRUB_DEFAULT to be addressable by index and
                                # for serial navigation to stay sane.
GRUB_DISABLE_RECOVERY=false     # keep the single-user entries. On a server the
                                # recovery entry is the cheapest rollback there is.
GRUB_DISABLE_OS_PROBER=true     # servers: do not scan other partitions. On a
                                # SAN/iSCSI host os-prober can mount foreign
                                # filesystems and hang grub-mkconfig for minutes.

# --- Graphics -------------------------------------------------------------
GRUB_GFXMODE=1024x768x32
GRUB_GFXPAYLOAD_LINUX=keep

# --- Red Hat family only --------------------------------------------------
# GRUB_ENABLE_BLSCFG=true       # emit BootLoaderSpec entries into
                                # /boot/loader/entries/*.conf instead of
                                # inlining menuentries into grub.cfg
```

Regenerar y observar:

```console
$ sudo update-grub
Generating grub configuration file ...
Found linux image: /boot/vmlinuz-6.1.0-18-amd64
Found initrd image: /boot/initrd.img-6.1.0-18-amd64
Found linux image: /boot/vmlinuz-6.1.0-17-amd64
Found initrd image: /boot/initrd.img-6.1.0-17-amd64
Warning: os-prober will not be executed to detect other bootable partitions.
Systems on them will not be added to the GRUB boot configuration.
Check GRUB_DISABLE_OS_PROBER documentation entry.
done
```

`update-grub` es un wrapper de shell de dos líneas de Debian. La invocación portable y correcta para el examen es:

```console
$ sudo grub-mkconfig -o /boot/grub/grub.cfg          # Debian/SUSE/Arch
$ sudo grub2-mkconfig -o /boot/grub2/grub.cfg        # RHEL/Fedora/CentOS
```

> **Salvedad sobre las rutas en Red Hat.** En RHEL 8 y anteriores, la configuración de un sistema UEFI vivía en `/boot/efi/EFI/redhat/grub.cfg` y la de BIOS en `/boot/grub2/grub.cfg`. RHEL 9 / Fedora 34+ unificaron ambas en `/boot/grub2/grub.cfg`, dejando un pequeño stub en la ESP que encadena hacia ella. Confirmá siempre con `readlink -f /etc/grub2.cfg` y `readlink -f /etc/grub2-efi.cfg` en lugar de asumir.

```console
$ readlink -f /etc/grub2.cfg
/boot/grub2/grub.cfg
$ readlink -f /etc/grub2-efi.cfg
/boot/efi/EFI/redhat/grub.cfg
```

### 5.3 Leer un `menuentry` generado

```bash
menuentry 'Debian GNU/Linux, with Linux 6.1.0-18-amd64' --class debian \
          --class gnu-linux --class gnu --class os \
          $menuentry_id_option 'gnulinux-6.1.0-18-amd64-advanced-8f3c1a92-...' {
	load_video
	insmod gzio
	if [ x$grub_platform = xxen ]; then insmod xzio; insmod lzopio; fi
	insmod part_gpt
	insmod ext2
	search --no-floppy --fs-uuid --set=root 8f3c1a92-4b7e-4c31-a0f2-9d5e6b7c8a10
	echo	'Loading Linux 6.1.0-18-amd64 ...'
	linux	/vmlinuz-6.1.0-18-amd64 root=UUID=c4e2d1b0-a9f8-4e37-b6c5-2d1a0f9e8b7c ro \
		console=tty0 console=ttyS0,115200n8 net.ifnames=0 biosdevname=0 \
		quiet loglevel=3 crashkernel=512M-2G:64M,2G-:256M
	echo	'Loading initial ramdisk ...'
	initrd	/initrd.img-6.1.0-18-amd64
}
```

Línea por línea, las cuatro cosas que importan operativamente:

| Línea | Significado | Fallo si está mal |
|---|---|---|
| `insmod part_gpt` / `insmod ext2` | cargar los módulos necesarios para leer `/boot` | `error: unknown filesystem` |
| `search --fs-uuid --set=root <uuid>` | localizar el **sistema de archivos `/boot`** por UUID y asociarlo a `$root`. Independiente del nombre de dispositivo. | `error: no such partition` → rescate |
| `linux /vmlinuz-… root=UUID=…` | la ruta es **relativa a `$root`**. Si `/boot` es una partición separada, la ruta no lleva prefijo `/boot`. `root=` es la raíz del **kernel**, algo completamente distinto. | ruta incorrecta → `error: file not found`; `root=` incorrecto → shell de emergencia del initramfs |
| `initrd /initrd.img-…` | debe coincidir exactamente con la versión del kernel | desajuste → kernel panic, `VFS: Unable to mount root fs` |

> **Los dos `root`.** `$root` (una variable de GRUB) = de dónde lee GRUB los archivos. `root=` (un parámetro del kernel) = dónde monta el kernel `/`. Con frecuencia son particiones distintas. Confundirlos es el error de edición clásico en un prompt `grub>`.

### 5.4 Agregar una entrada personalizada permanente — `/etc/grub.d/40_custom`

```bash
#!/bin/sh
exec tail -n +3 $0
# Everything below this line is copied verbatim into grub.cfg.
# File must be chmod 0755 or grub-mkconfig silently ignores it.

# ---------------------------------------------------------------------------
# Pinned known-good kernel. Survives kernel package removal only if the files
# are protected; see /etc/apt/apt.conf.d/01autoremove-kernels.
# ---------------------------------------------------------------------------
menuentry 'RESCUE: known-good 6.1.0-17 (single user)' --id rescue-known-good {
	insmod part_gpt
	insmod ext2
	search --no-floppy --fs-uuid --set=root 8f3c1a92-4b7e-4c31-a0f2-9d5e6b7c8a10
	echo 'Loading known-good kernel 6.1.0-17 ...'
	linux /vmlinuz-6.1.0-17-amd64 root=UUID=c4e2d1b0-a9f8-4e37-b6c5-2d1a0f9e8b7c ro \
	      console=ttyS0,115200n8 systemd.unit=rescue.target nomodeset
	initrd /initrd.img-6.1.0-17-amd64
}

# ---------------------------------------------------------------------------
# Chainload the mirror disk's boot sector (BIOS) — "alternative boot location"
# ---------------------------------------------------------------------------
menuentry 'RECOVERY: chainload second disk (hd1)' --id chain-hd1 {
	insmod chain
	insmod part_gpt
	set root=(hd1)
	chainloader +1
}

# ---------------------------------------------------------------------------
# Chainload the mirror ESP (UEFI)
# ---------------------------------------------------------------------------
menuentry 'RECOVERY: mirror ESP on /dev/sdb2' --id chain-esp2 {
	insmod chain
	insmod part_gpt
	insmod fat
	search --no-floppy --fs-uuid --set=root A1B2-C3D4
	chainloader /EFI/debian/shimx64.efi
}

# ---------------------------------------------------------------------------
# Memory test and firmware setup — diagnostics without external media
# ---------------------------------------------------------------------------
menuentry 'DIAG: UEFI firmware setup' --id fwsetup {
	fwsetup
}

menuentry 'DIAG: iPXE network rescue' --id ipxe {
	insmod part_gpt
	insmod fat
	search --no-floppy --fs-uuid --set=root A1B2-C3D4
	chainloader /EFI/ipxe/ipxe.efi
}
```

```console
$ sudo chmod 0755 /etc/grub.d/40_custom
$ sudo update-grub && grep -c '^menuentry' /boot/grub/grub.cfg
Generating grub configuration file ...
done
6
```

### 5.5 Instalar GRUB 2 — target BIOS

```console
$ sudo grub-install --target=i386-pc --recheck --boot-directory=/boot /dev/sda
Installing for i386-pc platform.
Installation finished. No error reported.
```

| Flag | Efecto | Cuándo usarlo |
|---|---|---|
| `--target=i386-pc` | BIOS/legacy | indicarlo siempre explícitamente en automatización; nunca confiar en la autodetección |
| `--recheck` | reconstruir `/boot/grub/device.map` antes de instalar | tras agregar/quitar/reordenar discos |
| `--boot-directory=DIR` | dónde vive `grub/` (por defecto `/boot`) | chroots de rescate, `/boot` alternativo |
| `--root-directory=DIR` | alias legacy, implica `DIR/boot` | rescate desde medio live |
| `--modules="lvm mdraid1x"` | forzar estos dentro de `core.img` | cuando `grub-probe` detecta de menos |
| `--force` | instalar en el sector de arranque de una **partición**, usando blocklists | casi nunca — frágil, se rompe con cualquier escritura en `/boot` |
| `--no-nvram` | UEFI: no escribir variables NVRAM | golden images, chroots, plantillas de nube |
| `--removable` | UEFI: escribir `\EFI\BOOT\BOOTX64.EFI` | medios USB, firmware que ignora la NVRAM |

**Escribí el dispositivo destino, no una partición.** `grub-install /dev/sda` instala `boot.img` en el MBR. `grub-install /dev/sda1` requiere `--force`, usa blocklists, y se va a romper la próxima vez que se escriba en `/boot`.

Verificar los artefactos:

```console
$ ls /boot/grub/i386-pc/ | head -8
acpi.mod
adler32.mod
affs.mod
afs.mod
ahci.mod
all_video.mod
biosdisk.mod
boot.img

$ ls -l /boot/grub/i386-pc/core.img
-rw-r--r-- 1 root root 30720 Aug 25 09:41 /boot/grub/i386-pc/core.img

$ cat /boot/grub/device.map
(hd0)	/dev/disk/by-id/ata-Samsung_SSD_870_EVO_500GB_S6PXNZ0T101234A
(hd1)	/dev/disk/by-id/ata-Samsung_SSD_870_EVO_500GB_S6PXNZ0T105678B
```

> `device.map` mapea los nombres `(hdN)` de GRUB a dispositivos Linux. Usá rutas `/dev/disk/by-id/` — los nombres `sdX` del kernel no son estables entre reinicios, y un `device.map` que apunta al disco equivocado produce una `core.img` que lee el `/boot` equivocado.

### 5.6 Instalar GRUB 2 — target UEFI

```console
$ sudo grub-install --target=x86_64-efi \
                    --efi-directory=/boot/efi \
                    --bootloader-id=debian \
                    --recheck
Installing for x86_64-efi platform.
Installation finished. No error reported.

$ sudo find /boot/efi -type f | sort
/boot/efi/EFI/BOOT/BOOTX64.EFI
/boot/efi/EFI/BOOT/fbx64.efi
/boot/efi/EFI/debian/BOOTX64.CSV
/boot/efi/EFI/debian/fbx64.efi
/boot/efi/EFI/debian/grub.cfg
/boot/efi/EFI/debian/grubx64.efi
/boot/efi/EFI/debian/mmx64.efi
/boot/efi/EFI/debian/shimx64.efi
```

El stub en la ESP que encadena a la configuración real:

```console
$ cat /boot/efi/EFI/debian/grub.cfg
search.fs_uuid 8f3c1a92-4b7e-4c31-a0f2-9d5e6b7c8a10 root hd0,gpt3 
set prefix=($root)'/grub'
configfile $prefix/grub.cfg
```

`grub-install` también escribió la NVRAM. Confirmar y fijar un orden:

```console
$ sudo efibootmgr -v | grep -i debian
Boot0005* debian	HD(2,GPT,9f4a1c2e-...,0x800,0x100000)/File(\EFI\DEBIAN\SHIMX64.EFI)

$ sudo efibootmgr -o 0005,0006,0003
BootOrder: 0005,0006,0003
```

Crear una entrada NVRAM a mano (cuando se usó `grub-install --no-nvram`, o el firmware la descartó):

```console
$ sudo efibootmgr --create \
                  --disk /dev/sda --part 2 \
                  --label "debian" \
                  --loader '\EFI\debian\shimx64.efi' \
                  --verbose
```

| Operación de `efibootmgr` | Comando |
|---|---|
| listar entradas con detalle | `efibootmgr -v` |
| crear una entrada | `efibootmgr -c -d /dev/sda -p 2 -L "debian" -l '\EFI\debian\shimx64.efi'` |
| fijar el orden persistente | `efibootmgr -o 0005,0006,0003` |
| **arrancar una sola vez desde otra entrada** | `efibootmgr -n 0006` (`BootNext`) |
| cancelar el disparo único | `efibootmgr -N` |
| borrar una entrada | `efibootmgr -b 0006 -B` |
| desactivar sin borrar | `efibootmgr -b 0006 -A` |
| fijar el timeout del firmware | `efibootmgr -t 2` |

`BootNext` es el equivalente a nivel UEFI de `grub-reboot`: **un disparo único que se limpia solo**, de modo que una prueba fallida vuelve automáticamente a `BootOrder`. Es la primitiva correcta para validar un gestor nuevo de forma remota.

**Red Hat + UEFI:** **no** ejecutes `grub2-install` en un sistema UEFI. Los binarios firmados vienen de los paquetes, y ejecutar el instalador puede sobrescribir una cadena firmada por shim con una sin firmar, rompiendo Secure Boot. La reparación soportada es:

```console
$ sudo dnf reinstall grub2-efi-x64 grub2-efi-x64-modules shim-x64
$ sudo grub2-mkconfig -o /boot/grub2/grub.cfg
```

### 5.7 Secure Boot: la cadena y su verificación

```
UEFI db (Microsoft UEFI CA)
   └─ verifies shimx64.efi          ← Microsoft-signed, distro-supplied
        └─ shim's embedded vendor cert (or MOK db)
             └─ verifies grubx64.efi     ← distro-signed
                  └─ GRUB calls shim_lock verifier
                       └─ verifies vmlinuz  ← distro-signed
                            └─ kernel enters "lockdown: integrity" mode
```

```console
$ mokutil --sb-state
SecureBoot enabled

$ sudo dmesg | grep -i -E 'secure boot|lockdown'
[    0.000000] secureboot: Secure boot enabled
[    0.000000] Kernel is locked down from EFI Secure Boot mode; see man kernel_lockdown.7

$ mokutil --list-enrolled | head -12
[key 1]
SHA1 Fingerprint: 34:2a:...
Certificate:
    Data:
        Version: 3 (0x2)
        Serial Number: ...
        Issuer: CN = Debian Secure Boot CA
```

Consecuencias operativas en un nodo bajo lockdown — esto sorprende a los SRE, no a los estudiantes:
- los módulos fuera del árbol sin firmar (DKMS: NVIDIA, VirtualBox, ZFS) no cargan hasta que se firman y se inscribe la clave con `mokutil --import`;
- `/dev/mem`, `kexec` con una imagen sin firmar y la hibernación al swap quedan bloqueados;
- las adiciones a `GRUB_CMDLINE_LINUX` se siguen respetando — la línea de comandos **no** la mide shim, que es precisamente por qué Secure Boot por sí solo no es atestación. Usá arranque medido con TPM 2.0 (`systemd-pcrphase`, PCR 8/9) si necesitás cubrir la línea de comandos.

---

## 6. GRUB Legacy — instalación y configuración

Vas a encontrarte con GRUB Legacy en RHEL/CentOS 6, en appliances embebidos y en el examen. Su virtud es que es un archivo estático que se puede leer y reparar con `vi`.

### 6.1 `menu.lst` / `grub.conf` completo y anotado

```bash
# /boot/grub/grub.conf   (Red Hat; /boot/grub/menu.lst is a symlink to it)
# NOTICE: You do not have a /boot partition. This means that all kernel and
#         initrd paths are relative to /, e.g.  root (hd0,0)  /boot/vmlinuz-...

default=0                 # index of the entry to boot, counting from 0
fallback=1                # if entry 0 fails to load, try entry 1
timeout=5                 # seconds; 0 = boot immediately, -1 = wait forever
hiddenmenu                # suppress the menu unless a key is pressed
splashimage=(hd0,0)/boot/grub/splash.xpm.gz
serial --unit=0 --speed=115200 --word=8 --parity=no --stop=1
terminal --timeout=10 serial console
password --md5 $1$Kf9dQ1$8Zx6vQpLm3nR7sT2yU4wB.

title CentOS (2.6.32-754.35.1.el6.x86_64)
	root (hd0,0)
	kernel /boot/vmlinuz-2.6.32-754.35.1.el6.x86_64 ro \
	       root=UUID=c4e2d1b0-a9f8-4e37-b6c5-2d1a0f9e8b7c \
	       rd_NO_LUKS rd_NO_DM LANG=en_US.UTF-8 \
	       console=tty0 console=ttyS0,115200n8 crashkernel=auto
	initrd /boot/initramfs-2.6.32-754.35.1.el6.x86_64.img
	savedefault

title CentOS (2.6.32-696.30.1.el6.x86_64)  [KNOWN GOOD]
	root (hd0,0)
	kernel /boot/vmlinuz-2.6.32-696.30.1.el6.x86_64 ro \
	       root=UUID=c4e2d1b0-a9f8-4e37-b6c5-2d1a0f9e8b7c \
	       console=ttyS0,115200n8
	initrd /boot/initramfs-2.6.32-696.30.1.el6.x86_64.img

title CentOS single-user (rescue)
	lock                      # requires the password above
	root (hd0,0)
	kernel /boot/vmlinuz-2.6.32-754.35.1.el6.x86_64 ro \
	       root=UUID=c4e2d1b0-a9f8-4e37-b6c5-2d1a0f9e8b7c single
	initrd /boot/initramfs-2.6.32-754.35.1.el6.x86_64.img

title Windows Server 2008 R2 (second disk)
	rootnoverify (hd1,0)      # do NOT try to read the filesystem
	map (hd0) (hd1)           # lie to Windows: make it think it is the 1st disk
	map (hd1) (hd0)
	chainloader +1            # load 1 sector from the partition boot record

title Boot from mirror disk (hd1) — RECOVERY
	root (hd1,0)
	chainloader +1
	makeactive
```

### 6.2 Referencia de directivas de GRUB Legacy

| Directiva | Alcance | Significado |
|---|---|---|
| `default N` / `default saved` | global | índice de entrada (desde **0**), o el valor guardado por `savedefault` |
| `fallback N` | global | entrada a intentar si la predeterminada no logra *cargar* |
| `timeout N` | global | segundos antes del arranque automático; `-1` espera indefinidamente |
| `hiddenmenu` | global | oculta el menú; cualquier tecla lo revela |
| `password --md5 <hash>` | global | bloquea el editor interactivo y las entradas con `lock` |
| `serial` / `terminal` | global | configuración de la consola serie |
| `title <text>` | entrada | inicia una nueva entrada; texto libre |
| `root (hdD,P)` | entrada | fija el dispositivo de arranque **y sondea su sistema de archivos** |
| `rootnoverify (hdD,P)` | entrada | lo fija **sin** sondear — para sistemas de archivos que GRUB no puede leer |
| `kernel <path> <args>` | entrada | carga el kernel; ruta relativa a `root` |
| `initrd <path>` | entrada | carga el initrd |
| `chainloader +1` | entrada | carga el primer sector de `root` y salta a él |
| `makeactive` | entrada | activa la bandera "active" de DOS en la partición |
| `map (hdX) (hdY)` | entrada | intercambia números de unidad de BIOS (lo necesita Windows) |
| `savedefault` | entrada | escribe el índice de esta entrada como el nuevo `saved` predeterminado |
| `lock` | entrada | exige la contraseña global antes de arrancar esta entrada |

Generar el hash MD5 de la contraseña:

```console
$ grub-md5-crypt
Password:
Retype password:
$1$Kf9dQ1$8Zx6vQpLm3nR7sT2yU4wB.
```

### 6.3 Instalar GRUB Legacy

Dos rutas equivalentes. La no interactiva:

```console
# grub-install --root-directory=/ /dev/sda
Installation finished. No error reported.
This is the contents of the device map /boot/grub/device.map.
Check if this is correct or not. If any of the lines is incorrect,
fix it and re-run the script `grub-install'.

(fd0)	/dev/fd0
(hd0)	/dev/sda
(hd1)	/dev/sdb
```

Y la shell interactiva de GRUB, que es lo que el examen espera que reconozcas — y lo que usás desde un medio de rescate cuando `grub-install` detecta mal la geometría:

```console
# grub
    GNU GRUB  version 0.97  (640K lower / 3072K upper memory)

 [ Minimal BASH-like line editing is supported.  For the first word, TAB
   lists possible command completions.  Anywhere else TAB lists the possible
   completions of a device/filename. ]

grub> find /boot/grub/stage1
 (hd0,0)
 (hd1,0)

grub> root (hd0,0)
 Filesystem type is ext2fs, partition type 0x83

grub> setup (hd0)
 Checking if "/boot/grub/stage1" exists... yes
 Checking if "/boot/grub/stage2" exists... yes
 Checking if "/boot/grub/e2fs_stage1_5" exists... yes
 Running "embed /boot/grub/e2fs_stage1_5 (hd0)"...  27 sectors are embedded.
succeeded
 Running "install /boot/grub/stage1 (hd0) (hd0)1+27 p (hd0,0)/boot/grub/stage2 /boot/grub/menu.lst"... succeeded
Done.

grub> root (hd1,0)
 Filesystem type is ext2fs, partition type 0x83

grub> setup (hd1)
 Checking if "/boot/grub/stage1" exists... yes
 ...
Done.

grub> quit
```

Leé la semántica con precisión, porque es crítica para el examen:

- `root (hd0,0)` — la partición donde **vive** `/boot/grub/` (origen de stage2).
- `setup (hd0)` — el dispositivo cuyo **sector de arranque recibe stage1** (destino).
- `setup (hd0)` escribe en el **MBR**; `setup (hd0,0)` escribe en el registro de arranque de esa **partición**.
- Ejecutar `setup (hd1)` después de `root (hd1,0)` es exactamente cómo se espeja el bootstrap al segundo disco. Hacelo en la misma ventana de mantenimiento en que construís el array RAID, o vas a tener un sistema a medias redundante.

---

## 7. Interactuar con el gestor de arranque

### 7.1 Menú de GRUB 2 — teclas interactivas

| Tecla | Efecto |
|---|---|
| `↑` `↓` | mover la selección (pausa la cuenta regresiva) |
| `e` | **editar la entrada seleccionada** — temporal, en memoria, se pierde al reiniciar |
| `c` | caer a la shell de comandos completa `grub>` |
| `Ctrl-x` o `F10` | arrancar la entrada editada |
| `Ctrl-c` | desde el editor, ir a la shell de comandos |
| `Esc` | descartar las ediciones y volver al menú |
| `Ctrl-a` / `Ctrl-e` | inicio / fin de línea (atajos emacs en el editor) |
| `Ctrl-k` / `Ctrl-y` | cortar hasta el fin de línea / pegar |

La habilidad operativa más valiosa de este objetivo: presionar `e`, ir a la línea `linux`, agregar un parámetro, presionar `Ctrl-x`.

### 7.2 Los parámetros del kernel que vale la pena memorizar

| Parámetro | Efecto | Caso de uso |
|---|---|---|
| `systemd.unit=rescue.target` (o `1`, `s`, `single`) | monousuario, sistema de archivos raíz montado rw, se exige la contraseña de root | recuperación de rutina |
| `systemd.unit=emergency.target` (o `emergency`) | shell mínima, `/` de solo lectura, **ninguna** otra unidad | `/etc/fstab` roto |
| `init=/bin/bash` | reemplaza PID 1 por completo — sin systemd, sin pedido de contraseña | **reseteo de la contraseña de root**; remontar con `mount -o remount,rw /` |
| `rd.break` (dracut) / `break=premount` (initramfs-tools) | shell **dentro del initramfs**, antes de `switch_root` | depuración de LUKS/LVM/montaje de raíz |
| `rd.shell rd.debug` | initramfs verboso con shell al fallar | "no se encuentra el dispositivo raíz" |
| `systemd.debug-shell=1` | shell de root en tty9 durante el arranque | cuelgues a mitad del arranque |
| `nomodeset` | desactivar el kernel mode setting | pantalla negra después de GRUB |
| `console=ttyS0,115200n8` | dirigir la salida del kernel a la serie | headless / OOB |
| `selinux=0` o `enforcing=0` | desactivar / poner permisivo SELinux | sistema de archivos mal etiquetado tras una restauración |
| `systemd.mask=<unit>` | enmascarar una unidad solo para este arranque | un servicio que cuelga el arranque |
| `ro` / `rw` | montar la raíz de solo lectura / de lectura-escritura | se combina con `init=/bin/bash` |
| `panic=30` | reiniciar 30 s después de un panic | **predeterminado de flota** — convierte un cuelgue en un reintento |
| `mem=4G`, `maxcpus=1` | limitar recursos | bisección de hardware |

> **Nota de seguridad que se desprende directamente:** `init=/bin/bash` en el prompt de GRUB es un bypass completo de autenticación para cualquiera con acceso a la consola. El acceso a la consola física/OOB **es** acceso de root, salvo que configures una contraseña de GRUB *y* cifrado de disco completo. Sección 7.5.

### 7.3 La shell completa `grub>`

Se llega con `c`, o cuando falta `grub.cfg` pero `core.img` cargó correctamente.

```
grub> ls
(hd0) (hd0,gpt4) (hd0,gpt3) (hd0,gpt2) (hd0,gpt1) (hd1) (hd1,gpt4) (hd1,gpt3) (hd1,gpt2) (hd1,gpt1)

grub> ls (hd0,gpt3)/
lost+found/ vmlinuz-6.1.0-18-amd64 initrd.img-6.1.0-18-amd64 vmlinuz-6.1.0-17-amd64 initrd.img-6.1.0-17-amd64 config-6.1.0-18-amd64 System.map-6.1.0-18-amd64 grub/ efi/

grub> ls -l (hd0,gpt3)
Partition hd0,gpt3: Filesystem type ext* — Last modification time 2026-08-25 09:41:12 Tuesday, UUID 8f3c1a92-4b7e-4c31-a0f2-9d5e6b7c8a10 - Partition start at 526336KiB - Total size 1048576KiB

grub> set
prefix=(hd0,gpt3)/grub
root=hd0,gpt3
cmdpath=(hd0,gpt2)/EFI/debian

grub> search --no-floppy --fs-uuid --set=root 8f3c1a92-4b7e-4c31-a0f2-9d5e6b7c8a10

grub> linux /vmlinuz-6.1.0-18-amd64 root=UUID=c4e2d1b0-a9f8-4e37-b6c5-2d1a0f9e8b7c ro console=ttyS0,115200n8

grub> initrd /initrd.img-6.1.0-18-amd64

grub> boot
```

Comandos esenciales de la shell:

| Comando | Propósito |
|---|---|
| `ls` | lista dispositivos; `ls (hdX,Y)/` lista archivos; `ls -l (hdX,Y)` muestra tipo de fs y UUID |
| `set` / `set var=value` | muestra / fija variables (`root`, `prefix`) |
| `search --fs-uuid --set=root <uuid>` | encuentra un sistema de archivos por UUID y lo asocia |
| `search --file --set=root /vmlinuz-6.1.0-18-amd64` | encuentra por la presencia de un archivo |
| `insmod <module>` | carga un módulo de GRUB (`ext2`, `lvm`, `part_gpt`, `normal`) |
| `linux` / `initrd` | prepara el kernel y el initrd |
| `configfile (hdX,Y)/grub/grub.cfg` | carga un archivo de configuración y muestra su menú |
| `chainloader +1` / `chainloader /EFI/…/x.efi` | pasa el control a otro gestor |
| `cat (hdX,Y)/etc/fstab` | lee un archivo de texto — invaluable para encontrar UUIDs |
| `lsmod` | lista los módulos de GRUB cargados |
| `normal` | sale del modo rescate y entra al menú normal |
| `boot` | ejecuta el kernel preparado |
| `halt` / `reboot` | apaga / reinicia |

### 7.4 `grub rescue>` — el prompt mínimo

`grub rescue>` significa que **`core.img` se ejecutó pero no pudo encontrar su `prefix`** — es decir, `/boot/grub` falta, se movió o está en un sistema de archivos ilegible. Solo existen `ls`, `set`, `unset`, `insmod` y `normal`.

```
error: file '/boot/grub/i386-pc/normal.mod' not found.
Entering rescue mode...
grub rescue> ls
(hd0) (hd0,msdos1) (hd0,msdos5)

grub rescue> ls (hd0,msdos1)/
lost+found/ boot/ etc/ bin/ sbin/ usr/ var/ home/

grub rescue> set prefix=(hd0,msdos1)/boot/grub
grub rescue> set root=(hd0,msdos1)
grub rescue> insmod normal
grub rescue> normal
```

Ahora estás en un menú normal de GRUB — **solo en memoria**. Arrancá el sistema y después hacelo permanente:

```console
$ sudo grub-install /dev/sda
Installing for i386-pc platform.
Installation finished. No error reported.
$ sudo update-grub
```

### 7.5 Endurecer la ruta interactiva

```bash
$ grub-mkpasswd-pbkdf2
Enter password:
Reenter password:
PBKDF2 hash of your password is grub.pbkdf2.sha512.10000.C4A9B1F2E8...D3E1
```

`/etc/grub.d/01_password` (modo `0755`):

```bash
#!/bin/sh
exec tail -n +3 $0
# Superuser 'gadmin' may edit entries and use the GRUB shell.
set superusers="gadmin"
password_pbkdf2 gadmin grub.pbkdf2.sha512.10000.C4A9B1F2E8...D3E1
```

Después marcá las entradas ordinarias como `--unrestricted` para que un reinicio desatendido siga funcionando:

```bash
menuentry 'Debian GNU/Linux' --unrestricted --id normal { ... }
menuentry 'RESCUE: single user' --users gadmin --id rescue { ... }
```

| Ajuste | Resultado |
|---|---|
| solo `set superusers` | **todas** las entradas requieren autenticación — un reinicio necesita a una persona. Incorrecto para servidores. |
| `--unrestricted` en las entradas normales | arranque libre; editar (`e`) y la shell (`c`) requieren la contraseña. **Correcto para servidores.** |
| `--users gadmin` en las entradas de rescate | solo ese usuario puede seleccionarlas |

El modo 0600 sobre `grub.cfg` evita la divulgación del hash, pero el hash también queda en `/etc/grub.d/01_password` — protegé ambos:

```console
$ sudo chmod 0600 /boot/grub/grub.cfg /etc/grub.d/01_password
```

**Una contraseña de GRUB protege el gestor de arranque, no los datos.** Un atacante con el disco arranca su propio medio y lo lee. El conjunto completo de controles es: contraseña de GRUB + contraseña de firmware/BIOS + orden de arranque fijado al disco interno + **cifrado de disco completo con LUKS** + Secure Boot + claves selladas por TPM. Cualquier cosa menor es un lomo de burro.

---

## 8. Ubicaciones de arranque alternativas y opciones de arranque de respaldo

Este es el punto del objetivo que se corresponde directamente con la práctica de SRE.

### 8.1 Espejar el bootstrap entre discos (BIOS + mdraid)

El array sobrevive al fallo de un disco; al MBR hay que decírselo.

```console
$ sudo grub-install --target=i386-pc --recheck /dev/sda
Installing for i386-pc platform.
Installation finished. No error reported.
$ sudo grub-install --target=i386-pc --recheck /dev/sdb
Installing for i386-pc platform.
Installation finished. No error reported.
```

En Debian, hacé que esto sobreviva a las actualizaciones de paquetes registrando ambos dispositivos en debconf — de lo contrario, la próxima actualización de `grub-pc` reinstala en uno solo:

```console
$ echo 'grub-pc grub-pc/install_devices multiselect \
  /dev/disk/by-id/ata-Samsung_SSD_870_EVO_500GB_S6PXNZ0T101234A, \
  /dev/disk/by-id/ata-Samsung_SSD_870_EVO_500GB_S6PXNZ0T105678B' \
  | sudo debconf-set-selections
$ sudo dpkg-reconfigure -f noninteractive grub-pc
```

Verificar que ambos MBR llevan un bootstrap:

```console
$ for d in /dev/sda /dev/sdb; do
>   printf '%s: ' "$d"
>   sudo dd if="$d" bs=512 count=1 status=none | strings | grep -q GRUB \
>     && echo "GRUB present" || echo "NO BOOTSTRAP"
> done
/dev/sda: GRUB present
/dev/sdb: GRUB present
```

### 8.2 Espejar la ESP (UEFI)

La ESP es FAT32 y el firmware la lee directamente, así que no puede ser un miembro normal de mdraid. Dos estrategias viables:

| Estrategia | Cómo | Compromiso |
|---|---|---|
| **Dos ESP independientes + sincronización** | particiones `EF00` separadas; `grub-install --efi-directory` a cada una; `rsync` en una unidad path/timer de systemd | simple, transparente, agnóstica del firmware. Requiere un paso explícito de sincronización. **Recomendada.** |
| **RAID1 con metadatos mdraid 1.0** | el superbloque va al **final** del dispositivo, así que el firmware ve un FAT32 plano en el offset 0 | el firmware puede escribir en un miembro por fuera de banda y desincronizar el espejo en silencio; `fsck.vfat` sobre un array degradado puede corromper ambos |

Procedimiento de ESP independientes:

```console
$ sudo mkdir -p /boot/efi2
$ sudo mkfs.vfat -F32 -n ESP2 /dev/sdb2
mkfs.fat 4.2 (2021-01-31)

$ sudo blkid /dev/sdb2
/dev/sdb2: LABEL_FATBOOT="ESP2" LABEL="ESP2" UUID="A1B2-C3D4" BLOCK_SIZE="512" TYPE="vfat" PARTLABEL="EFI System Partition" PARTUUID="c7d8e9f0-..."

$ echo 'UUID=A1B2-C3D4  /boot/efi2  vfat  umask=0077,noauto  0 0' | sudo tee -a /etc/fstab
$ sudo mount /boot/efi2

$ sudo grub-install --target=x86_64-efi --efi-directory=/boot/efi2 \
                    --bootloader-id=debian-mirror --recheck
Installing for x86_64-efi platform.
Installation finished. No error reported.

$ sudo efibootmgr -v | grep -i mirror
Boot0006* debian-mirror	HD(2,GPT,c7d8e9f0-...,0x800,0x100000)/File(\EFI\DEBIAN-MIRROR\SHIMX64.EFI)

$ sudo efibootmgr -o 0005,0006,0003
BootOrder: 0005,0006,0003
```

Mantenerlas sincronizadas automáticamente:

```ini
# /etc/systemd/system/esp-sync.service
[Unit]
Description=Synchronise the backup EFI System Partition
Documentation=man:grub-install(8)
RequiresMountsFor=/boot/efi

[Service]
Type=oneshot
ExecStartPre=/usr/bin/mountpoint -q /boot/efi2 || /usr/bin/mount /boot/efi2
ExecStart=/usr/bin/rsync -a --delete --exclude 'EFI/debian-mirror/' /boot/efi/ /boot/efi2/
ExecStartPost=/usr/bin/umount /boot/efi2
```

```ini
# /etc/systemd/system/esp-sync.path
[Unit]
Description=Watch the primary ESP for changes

[Path]
PathChanged=/boot/efi/EFI
Unit=esp-sync.service

[Install]
WantedBy=multi-user.target
```

```console
$ sudo systemctl daemon-reload && sudo systemctl enable --now esp-sync.path
Created symlink /etc/systemd/system/multi-user.target.wants/esp-sync.path → /etc/systemd/system/esp-sync.path.
```

### 8.3 Arranque de disparo único: probar un kernel sin apostar el nodo

La técnica de arranque de respaldo más valiosa. Hay que tener `GRUB_DEFAULT=saved` (sección 5.2).

```console
$ sudo grub-editenv list
saved_entry=gnulinux-6.1.0-17-amd64-advanced-8f3c1a92-...
boot_success=1

$ sudo grub-reboot 'gnulinux-6.1.0-18-amd64-advanced-8f3c1a92-...'

$ sudo grub-editenv list
saved_entry=gnulinux-6.1.0-17-amd64-advanced-8f3c1a92-...
next_entry=gnulinux-6.1.0-18-amd64-advanced-8f3c1a92-...
boot_success=1

$ sudo systemctl reboot
```

GRUB consume y limpia `next_entry` en el arranque. Si el kernel nuevo entra en panic y el watchdog (`panic=30`) reinicia la máquina, el **siguiente** arranque usa `saved_entry` — el kernel conocido como bueno. Cero intervención humana.

Comparación de las tres primitivas de persistencia:

| Comando | Escribe | Persistencia | Uso |
|---|---|---|---|
| `grub-reboot <entry>` | `next_entry` en `grubenv` | **un arranque** | probar un kernel, validar un gestor nuevo |
| `grub-set-default <entry>` | `saved_entry` en `grubenv` | permanente | promover un kernel tras la validación |
| `efibootmgr -n <hex>` | `BootNext` en NVRAM | **un arranque** | probar un gestor completo / otro disco |
| `efibootmgr -o <list>` | `BootOrder` en NVRAM | permanente | promover un gestor |

Promover tras un período de prueba exitoso:

```console
$ sudo grub-set-default 'gnulinux-6.1.0-18-amd64-advanced-8f3c1a92-...'
$ sudo grub-editenv list | grep saved_entry
saved_entry=gnulinux-6.1.0-18-amd64-advanced-8f3c1a92-...
```

Los IDs de entrada vienen de `--id` o de `$menuentry_id_option`. Enumeralos de forma confiable:

```console
$ awk -F"'" '/^menuentry |^submenu /{print NR": "$2" ==> "$4}' /boot/grub/grub.cfg
6: Debian GNU/Linux ==> gnulinux-simple-c4e2d1b0-a9f8-4e37-b6c5-2d1a0f9e8b7c
17: Debian GNU/Linux, with Linux 6.1.0-18-amd64 ==> gnulinux-6.1.0-18-amd64-advanced-8f3c1a92-4b7e-4c31-a0f2-9d5e6b7c8a10
33: Debian GNU/Linux, with Linux 6.1.0-17-amd64 ==> gnulinux-6.1.0-17-amd64-advanced-8f3c1a92-4b7e-4c31-a0f2-9d5e6b7c8a10
49: RESCUE: known-good 6.1.0-17 (single user) ==> rescue-known-good
57: RECOVERY: chainload second disk (hd1) ==> chain-hd1
```

### 8.4 Rollback automático: conteo de arranques en `grubenv`

Convertí la "prueba de disparo único" en una "flota que se autorrepara". Agregá `/etc/grub.d/09_boot_counting` (modo `0755`):

```bash
#!/bin/sh
exec tail -n +3 $0
# Boot-attempt counting with automatic rollback.
# Requires: grub-boot-success.service (below) writing boot_success=1 after a
# successful multi-user boot, and GRUB_DEFAULT=saved.

if [ -s "${prefix}/grubenv" ]; then
  load_env
fi

# Normalise on first ever boot.
if [ -z "${boot_attempts}" ]; then set boot_attempts=0; fi

if [ "${boot_success}" = "1" ]; then
    # Previous boot reached multi-user.target: reset the counter.
    set boot_attempts=0
else
    # Previous boot did not confirm success: count this attempt.
    set boot_attempts=$((boot_attempts + 1))
fi

# Clear the flag; userspace must set it again to prove this boot worked.
set boot_success=0
save_env boot_success boot_attempts

if [ "${boot_attempts}" -ge 3 ]; then
    echo "*** ${boot_attempts} failed boot attempts — falling back to the known-good entry ***"
    sleep 5
    set default="rescue-known-good"
    set timeout=30
    set timeout_style=menu
fi
```

La mitad en espacio de usuario:

```ini
# /etc/systemd/system/grub-boot-success.service
[Unit]
Description=Mark this boot as successful in the GRUB environment block
Documentation=man:grub-editenv(1)
After=multi-user.target network-online.target
Requires=multi-user.target
ConditionPathExists=/boot/grub/grubenv

[Service]
Type=oneshot
RemainAfterExit=yes
# Delay so that a node that crashes shortly after multi-user is NOT marked good.
ExecStartPre=/bin/sleep 120
ExecStart=/usr/bin/grub-editenv /boot/grub/grubenv set boot_success=1
ExecStart=/usr/bin/grub-editenv /boot/grub/grubenv set boot_attempts=0

[Install]
WantedBy=multi-user.target
```

```console
$ sudo systemctl enable --now grub-boot-success.service
$ sudo grub-editenv list
saved_entry=gnulinux-6.1.0-18-amd64-advanced-8f3c1a92-...
boot_success=1
boot_attempts=0
```

> **Restricción de `grubenv`.** Es un archivo de **1024 bytes** fijos que GRUB reescribe **in situ** — no puede crecer, y GRUB no puede escribirlo a través de LVM, mdraid o Btrfs (`error: sparse file not allowed` / `error: diskfilter writes are not supported`). Por lo tanto, el conteo de arranques exige que `/boot` esté en una **partición plana**. Este es un argumento arquitectónico fuerte para mantener `/boot` simple.

### 8.5 Medio de recuperación que vive fuera del disco

```console
$ sudo grub-mkrescue -o /srv/images/grub-rescue-$(date +%F).iso /tmp/empty-root
xorriso 1.5.4 : RockRidge filesystem manipulator, libburnia project.
Drive current: -outdev 'stdio:/srv/images/grub-rescue-2026-08-25.iso'
...
ISO image produced: 25984 sectors
Written to medium : 25984 sectors at LBA 0
Writing to 'stdio:/srv/images/grub-rescue-2026-08-25.iso' completed successfully.

$ file /srv/images/grub-rescue-2026-08-25.iso
/srv/images/grub-rescue-2026-08-25.iso: ISO 9660 CD-ROM filesystem data 'GRUB2 rescue disk' (DOS/MBR boot sector) (bootable)
```

Esta ISO arranca a un prompt `grub>` tanto en BIOS como en UEFI. Montala a través del medio virtual de tu BMC y podés hacer `configfile (hd0,gpt3)/grub/grub.cfg` para volver a entrar a un sistema cuyo gestor en disco está destruido — **sin visitar el datacenter**. Mantené una copia actual en cada recurso compartido alcanzable por BMC.

Variante por red, para un respaldo a nivel de rack:

```console
$ sudo grub-mknetdir --net-directory=/srv/tftp --subdir=/boot/grub
Netboot directory for i386-pc created. Configure your DHCP server to point to /boot/grub/i386-pc/core.0
Netboot directory for x86_64-efi created. Configure your DHCP server to point to /boot/grub/x86_64-efi/core.efi
```

### 8.6 El procedimiento completo de respaldo y restauración de los metadatos de arranque

```bash
#!/usr/bin/env bash
# /usr/local/sbin/backup-boot-metadata — run before ANY bootloader change.
set -euo pipefail

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
DEST="/var/backups/boot/${STAMP}"
mkdir -p "${DEST}"

for disk in /dev/sda /dev/sdb; do
    name="$(basename "${disk}")"
    # First 2048 sectors = MBR + post-MBR gap (core.img lives here on BIOS).
    dd if="${disk}" of="${DEST}/${name}.boot-area.bin" bs=512 count=2048 status=none
    # Partition table (GPT primary + backup, or MBR).
    sgdisk --backup="${DEST}/${name}.gpt" "${disk}" >/dev/null 2>&1 \
        || sfdisk --dump "${disk}" > "${DEST}/${name}.sfdisk"
done

# ESP contents.
[ -d /boot/efi ] && tar -C /boot/efi -czf "${DEST}/esp.tar.gz" .

# NVRAM boot entries (informational — restore is manual via efibootmgr).
command -v efibootmgr >/dev/null && efibootmgr -v > "${DEST}/efibootmgr.txt"

# Generated and source configuration.
tar -czf "${DEST}/grub-config.tar.gz" \
    /etc/default/grub /etc/grub.d /boot/grub/grub.cfg /boot/grub/grubenv \
    /boot/grub2/grub.cfg /boot/loader/entries 2>/dev/null || true

# Kernel inventory, so you know what "known good" meant.
{ uname -r; ls -l /boot/vmlinuz-* /boot/init*; } > "${DEST}/kernels.txt"

sha256sum "${DEST}"/* > "${DEST}/SHA256SUMS"
echo "Boot metadata saved to ${DEST}"
```

```console
$ sudo /usr/local/sbin/backup-boot-metadata
Boot metadata saved to /var/backups/boot/20260825T121804Z

$ sudo ls -lh /var/backups/boot/20260825T121804Z/
total 3.4M
-rw-r--r-- 1 root root  512 Aug 25 12:18 SHA256SUMS
-rw-r--r-- 1 root root  17K Aug 25 12:18 esp.tar.gz
-rw-r--r-- 1 root root 1.1K Aug 25 12:18 efibootmgr.txt
-rw-r--r-- 1 root root  38K Aug 25 12:18 grub-config.tar.gz
-rw-r--r-- 1 root root  892 Aug 25 12:18 kernels.txt
-rw-r--r-- 1 root root 1.0M Aug 25 12:18 sda.boot-area.bin
-rw-r--r-- 1 root root  17K Aug 25 12:18 sda.gpt
-rw-r--r-- 1 root root 1.0M Aug 25 12:18 sdb.boot-area.bin
-rw-r--r-- 1 root root  17K Aug 25 12:18 sdb.gpt
```

**Restaurar solamente el bootstrap** (preservando la tabla de particiones actual — la diferencia entre recuperación y pérdida de datos):

```console
# Restore ONLY the 446 bytes of bootstrap code. Bytes 446..511 hold the
# partition table and the signature: overwriting them destroys the layout.
$ sudo dd if=sda.boot-area.bin of=/dev/sda bs=446 count=1 conv=notrunc
1+0 records in
1+0 records out
446 bytes copied, 0.000371 s, 1.2 MB/s

# Then the post-MBR gap where core.img lives (sectors 1..2047).
$ sudo dd if=sda.boot-area.bin of=/dev/sda bs=512 skip=1 seek=1 count=2047 conv=notrunc
2047+0 records in
2047+0 records out
1048064 bytes (1.0 MB, 1023 KiB) copied, 0.00612 s, 171 MB/s
```

---

## 9. Infraestructura como código

### 9.1 Rol de Ansible — idempotente, verificado, de doble disco

```yaml
---
# roles/bootloader/defaults/main.yml
bootloader_timeout: 5
bootloader_default: saved
bootloader_console_args: "console=tty0 console=ttyS0,115200n8"
bootloader_extra_args: "net.ifnames=0 biosdevname=0 panic=30"
bootloader_default_args: "quiet loglevel=3 crashkernel=512M-2G:64M,2G-:256M"
bootloader_disable_os_prober: true
bootloader_preload_modules: "part_gpt part_msdos lvm mdraid1x ext2"
# Explicit list of disks whose MBR must carry the bootstrap (BIOS only).
bootloader_bios_devices: []
# Explicit list of {esp_device, mountpoint, bootloader_id} (UEFI only).
bootloader_esps: []
bootloader_reboot_after: false
```

```yaml
---
# roles/bootloader/vars/Debian.yml
bootloader_pkg_bios: [grub-pc, grub-common]
bootloader_pkg_efi: [grub-efi-amd64, grub-efi-amd64-signed, shim-signed, efibootmgr]
bootloader_mkconfig: /usr/sbin/grub-mkconfig
bootloader_install: /usr/sbin/grub-install
bootloader_cfg_bios: /boot/grub/grub.cfg
bootloader_editenv: /usr/bin/grub-editenv
bootloader_grubenv: /boot/grub/grubenv
```

```yaml
---
# roles/bootloader/vars/RedHat.yml
bootloader_pkg_bios: [grub2-pc, grub2-tools]
bootloader_pkg_efi: [grub2-efi-x64, grub2-efi-x64-modules, shim-x64, efibootmgr]
bootloader_mkconfig: /usr/sbin/grub2-mkconfig
bootloader_install: /usr/sbin/grub2-install
bootloader_cfg_bios: /boot/grub2/grub.cfg
bootloader_editenv: /usr/bin/grub2-editenv
bootloader_grubenv: /boot/grub2/grubenv
```

```yaml
---
# roles/bootloader/tasks/main.yml
- name: Load distribution-specific variables
  ansible.builtin.include_vars: "{{ ansible_facts['os_family'] }}.yml"

- name: Detect firmware mode
  ansible.builtin.stat:
    path: /sys/firmware/efi
  register: efi_dir

- name: Record firmware mode as a fact
  ansible.builtin.set_fact:
    bootloader_firmware: "{{ 'uefi' if efi_dir.stat.isdir | default(false) else 'bios' }}"

- name: Refuse to run without an explicit device list
  ansible.builtin.assert:
    that:
      - (bootloader_firmware == 'bios' and bootloader_bios_devices | length > 0)
        or (bootloader_firmware == 'uefi' and bootloader_esps | length > 0)
    fail_msg: >-
      Set bootloader_bios_devices (BIOS) or bootloader_esps (UEFI) explicitly.
      Autodetecting the boot device is how fleets lose their MBR mirror.

- name: Install boot loader packages
  ansible.builtin.package:
    name: "{{ bootloader_pkg_efi if bootloader_firmware == 'uefi' else bootloader_pkg_bios }}"
    state: present

# ---- Back up before touching anything -------------------------------------
- name: Ship the boot metadata backup script
  ansible.builtin.copy:
    src: backup-boot-metadata
    dest: /usr/local/sbin/backup-boot-metadata
    owner: root
    group: root
    mode: "0750"

- name: Back up boot metadata
  ansible.builtin.command: /usr/local/sbin/backup-boot-metadata
  register: boot_backup
  changed_when: true

# ---- Configuration ---------------------------------------------------------
- name: Deploy /etc/default/grub
  ansible.builtin.template:
    src: default-grub.j2
    dest: /etc/default/grub
    owner: root
    group: root
    mode: "0644"
    backup: true
    validate: /bin/sh -n %s          # catch shell syntax errors BEFORE reboot
  notify: regenerate grub config

- name: Deploy custom menu entries
  ansible.builtin.template:
    src: 40_custom.j2
    dest: /etc/grub.d/40_custom
    owner: root
    group: root
    mode: "0755"
  notify: regenerate grub config

- name: Deploy boot-counting script
  ansible.builtin.copy:
    src: 09_boot_counting
    dest: /etc/grub.d/09_boot_counting
    owner: root
    group: root
    mode: "0755"
  notify: regenerate grub config

- name: Deploy the boot-success marker unit
  ansible.builtin.template:
    src: grub-boot-success.service.j2
    dest: /etc/systemd/system/grub-boot-success.service
    owner: root
    group: root
    mode: "0644"
  notify: reload systemd

- name: Enable the boot-success marker
  ansible.builtin.systemd_service:
    name: grub-boot-success.service
    enabled: true
    daemon_reload: true

# ---- Installation: BIOS ----------------------------------------------------
- name: Install the GRUB bootstrap to every BIOS boot device
  ansible.builtin.command:
    cmd: "{{ bootloader_install }} --target=i386-pc --recheck {{ item }}"
  loop: "{{ bootloader_bios_devices }}"
  when: bootloader_firmware == 'bios'
  register: grub_bios_install
  changed_when: "'Installation finished' in grub_bios_install.stdout"
  notify: regenerate grub config

- name: Record all BIOS boot devices in debconf (Debian, survives upgrades)
  ansible.builtin.debconf:
    name: grub-pc
    question: grub-pc/install_devices
    vtype: multiselect
    value: "{{ bootloader_bios_devices | join(', ') }}"
  when:
    - bootloader_firmware == 'bios'
    - ansible_facts['os_family'] == 'Debian'

# ---- Installation: UEFI ----------------------------------------------------
- name: Ensure every ESP mountpoint exists
  ansible.builtin.file:
    path: "{{ item.mountpoint }}"
    state: directory
    mode: "0700"
  loop: "{{ bootloader_esps }}"
  when: bootloader_firmware == 'uefi'

- name: Mount every ESP
  ansible.posix.mount:
    path: "{{ item.mountpoint }}"
    src: "UUID={{ item.uuid }}"
    fstype: vfat
    opts: "umask=0077{{ ',noauto' if item.get('backup', false) else '' }}"
    state: "{{ 'present' if item.get('backup', false) else 'mounted' }}"
  loop: "{{ bootloader_esps }}"
  when: bootloader_firmware == 'uefi'

- name: Install GRUB to every ESP
  ansible.builtin.command:
    cmd: >-
      {{ bootloader_install }} --target=x86_64-efi
      --efi-directory={{ item.mountpoint }}
      --bootloader-id={{ item.bootloader_id }}
      --recheck
  loop: "{{ bootloader_esps }}"
  when:
    - bootloader_firmware == 'uefi'
    - ansible_facts['os_family'] != 'RedHat'   # RHEL+UEFI: reinstall packages instead
  register: grub_efi_install
  changed_when: "'Installation finished' in grub_efi_install.stdout"
  notify: regenerate grub config

- name: Read the current UEFI boot order
  ansible.builtin.command: efibootmgr
  when: bootloader_firmware == 'uefi'
  changed_when: false
  register: efi_state

- name: Show the resulting UEFI boot order
  ansible.builtin.debug:
    msg: "{{ efi_state.stdout_lines | select('match', '^BootOrder') | list }}"
  when: bootloader_firmware == 'uefi'

# ---- Verification (always runs, even with no changes) ----------------------
- name: Flush handlers so verification sees the regenerated config
  ansible.builtin.meta: flush_handlers

- name: Read the generated configuration
  ansible.builtin.slurp:
    src: "{{ bootloader_cfg_bios }}"
  register: grub_cfg_raw

- name: Assert the generated configuration is sane
  vars:
    cfg: "{{ grub_cfg_raw.content | b64decode }}"
  ansible.builtin.assert:
    that:
      - cfg is search('^menuentry ', multiline=True)
      - cfg is search('\\s+linux\\s+/')
      - cfg is search('\\s+initrd\\s+/')
      - cfg is search('root=UUID=')
      - cfg is not search('root=/dev/[sh]d[a-z][0-9]')   # unstable device names
    fail_msg: >-
      Generated grub.cfg failed validation. DO NOT REBOOT this host.
      Restore from {{ boot_backup.stdout | default('the last backup') }}.
    success_msg: "grub.cfg validated: menuentry, linux, initrd and root=UUID present."

- name: Confirm the current kernel has a matching menu entry
  vars:
    cfg: "{{ grub_cfg_raw.content | b64decode }}"
  ansible.builtin.assert:
    that:
      - cfg is search(ansible_facts['kernel'] | regex_escape)
    fail_msg: "Running kernel {{ ansible_facts['kernel'] }} has no menu entry."

- name: Confirm every BIOS device carries a bootstrap
  ansible.builtin.shell:
    cmd: "set -o pipefail; dd if={{ item }} bs=512 count=1 status=none | strings | grep -q GRUB"
    executable: /bin/bash
  loop: "{{ bootloader_bios_devices }}"
  when: bootloader_firmware == 'bios'
  changed_when: false
  failed_when: false
  register: mbr_check

- name: Fail if any BIOS device lacks a bootstrap
  ansible.builtin.assert:
    that: "mbr_check.results | rejectattr('rc', 'equalto', 0) | list | length == 0"
    fail_msg: >-
      Missing GRUB bootstrap on:
      {{ mbr_check.results | rejectattr('rc','equalto',0) | map(attribute='item') | list }}
  when: bootloader_firmware == 'bios'
```

```yaml
---
# roles/bootloader/handlers/main.yml
- name: regenerate grub config
  ansible.builtin.command:
    cmd: "{{ bootloader_mkconfig }} -o {{ bootloader_cfg_bios }}"
  register: mkconfig
  changed_when: true
  failed_when: mkconfig.rc != 0 or 'error' in (mkconfig.stderr | lower)

- name: reload systemd
  ansible.builtin.systemd_service:
    daemon_reload: true
```

```jinja
{# roles/bootloader/templates/default-grub.j2 #}
# ANSIBLE MANAGED — role platform.bootloader. Local edits will be overwritten.
GRUB_DEFAULT={{ bootloader_default }}
GRUB_SAVEDEFAULT=false
GRUB_TIMEOUT={{ bootloader_timeout }}
GRUB_TIMEOUT_STYLE=menu
GRUB_DISTRIBUTOR="{{ ansible_facts['distribution'] }}"
GRUB_CMDLINE_LINUX="{{ bootloader_console_args }} {{ bootloader_extra_args }}"
GRUB_CMDLINE_LINUX_DEFAULT="{{ bootloader_default_args }}"
GRUB_TERMINAL="console serial"
GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"
GRUB_PRELOAD_MODULES="{{ bootloader_preload_modules }}"
GRUB_DISABLE_SUBMENU=y
GRUB_DISABLE_RECOVERY=false
GRUB_DISABLE_OS_PROBER={{ 'true' if bootloader_disable_os_prober else 'false' }}
{% if ansible_facts['os_family'] == 'RedHat' %}
GRUB_ENABLE_BLSCFG=true
{% endif %}
```

```yaml
---
# playbooks/bootloader.yml — serial rollout with an in-band health gate
- name: Configure the boot loader fleet-wide
  hosts: linux_servers
  become: true
  serial: "10%"                       # never touch the whole fleet at once
  max_fail_percentage: 0              # stop the entire rollout on the first failure
  roles:
    - role: bootloader
      bootloader_bios_devices:
        - /dev/disk/by-id/ata-Samsung_SSD_870_EVO_500GB_S6PXNZ0T101234A
        - /dev/disk/by-id/ata-Samsung_SSD_870_EVO_500GB_S6PXNZ0T105678B
  post_tasks:
    - name: Arm a one-shot boot into the new default
      ansible.builtin.command: "grub-reboot '{{ bootloader_target_entry }}'"
      when: bootloader_target_entry is defined

    - name: Reboot and wait for the host to come back
      ansible.builtin.reboot:
        reboot_timeout: 600
        test_command: systemctl is-system-running --wait
      when: bootloader_reboot_after | bool

    - name: Confirm the intended kernel is running
      ansible.builtin.assert:
        that: ansible_facts['kernel'] == bootloader_expected_kernel
        fail_msg: >-
          Host booted {{ ansible_facts['kernel'] }},
          expected {{ bootloader_expected_kernel }}. Rollback triggered.
      when: bootloader_expected_kernel is defined
```

### 9.2 cloud-init — argumentos de kernel en el primer arranque

```yaml
#cloud-config
# Applied by cloud-init on first boot; a reboot is required for kernel args.
write_files:
  - path: /etc/default/grub.d/99-platform.cfg
    owner: root:root
    permissions: "0644"
    content: |
      # Debian/Ubuntu source /etc/default/grub.d/*.cfg after /etc/default/grub,
      # so a drop-in composes with the distro defaults instead of replacing them.
      GRUB_TIMEOUT=5
      GRUB_TIMEOUT_STYLE=menu
      GRUB_TERMINAL="console serial"
      GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"
      GRUB_CMDLINE_LINUX_DEFAULT="console=tty0 console=ttyS0,115200n8 net.ifnames=0 panic=30 nvme_core.io_timeout=4294967295"
      GRUB_DISABLE_OS_PROBER=true
      GRUB_RECORDFAIL_TIMEOUT=30

runcmd:
  - [ update-grub ]
  # Fail loudly at provisioning time rather than silently at reboot time.
  - [ sh, -c, "grep -q 'console=ttyS0' /boot/grub/grub.cfg || { echo 'FATAL: serial console arg missing from grub.cfg'; exit 1; }" ]
  - [ sh, -c, "grep -q 'root=UUID=' /boot/grub/grub.cfg || { echo 'FATAL: no UUID-based root='; exit 1; }" ]

power_state:
  mode: reboot
  message: "Rebooting to apply boot loader configuration"
  timeout: 60
  condition: true
```

### 9.3 Butane → Ignition — hosts inmutables (Fedora CoreOS / Flatcar / OKD)

En sistemas basados en imágenes el gestor no se configura editando archivos; los argumentos del kernel son una propiedad declarativa de la máquina.

```yaml
variant: fcos
version: 1.5.0

kernel_arguments:
  should_exist:
    - console=tty0
    - console=ttyS0,115200n8
    - panic=30
    - systemd.unified_cgroup_hierarchy=1
    - mitigations=auto,nosmt
  should_not_exist:
    - quiet
    - rhgb

storage:
  files:
    # Bootloader timeout on an immutable host: still needed for console rescue.
    - path: /boot/loader/loader.conf
      mode: 0644
      overwrite: true
      contents:
        inline: |
          timeout 5
          console-mode keep
          editor no

    - path: /usr/local/bin/verify-boot-chain.sh
      mode: 0755
      contents:
        inline: |
          #!/usr/bin/bash
          set -euo pipefail
          echo "firmware: $([ -d /sys/firmware/efi ] && echo UEFI || echo BIOS)"
          echo "cmdline : $(cat /proc/cmdline)"
          echo "kernel  : $(uname -r)"
          rpm-ostree status --json | jq -r '.deployments[] | "\(.booted) \(.checksum[0:12]) \(.version)"'

systemd:
  units:
    # greenboot: health-check driven automatic rollback on rpm-ostree systems.
    - name: greenboot-healthcheck.service
      enabled: true
    - name: platform-boot-healthcheck.service
      enabled: true
      contents: |
        [Unit]
        Description=Platform boot health check for greenboot
        After=network-online.target
        Wants=network-online.target

        [Service]
        Type=oneshot
        ExecStart=/usr/bin/systemctl is-system-running --wait
        ExecStart=/usr/bin/systemctl is-active kubelet.service
        RemainAfterExit=yes

        [Install]
        RequiredBy=greenboot-healthcheck.service
```

```console
$ butane --pretty --strict node.bu --output node.ign
$ jq -r '.kernelArguments.shouldExist[]' node.ign
console=tty0
console=ttyS0,115200n8
panic=30
systemd.unified_cgroup_hierarchy=1
mitigations=auto,nosmt

$ sudo rpm-ostree kargs
console=tty0 console=ttyS0,115200n8 panic=30 systemd.unified_cgroup_hierarchy=1 mitigations=auto,nosmt

$ sudo rpm-ostree status
State: idle
Deployments:
● fedora:fedora/x86_64/coreos/stable
                  Version: 39.20260812.3.0 (2026-08-12T14:22:41Z)
                   Commit: 8f2a...c19
             GPGSignature: Valid signature by ...

  fedora:fedora/x86_64/coreos/stable
                  Version: 39.20260729.3.0 (2026-07-29T11:04:07Z)
                   Commit: 3b7e...a02
```

El segundo deployment **es** la opción de arranque de respaldo: `rpm-ostree rollback` lo promueve, y greenboot lo promueve automáticamente si la comprobación de salud falla.

### 9.4 Kickstart — política del gestor de arranque en tiempo de aprovisionamiento

```
# ks.cfg — RHEL / Rocky / AlmaLinux unattended install
text
lang en_US.UTF-8
keyboard us
timezone UTC --utc

# Wipe and lay out for hybrid BIOS/UEFI bootability
ignoredisk --only-use=sda,sdb
clearpart --all --initlabel --drives=sda,sdb
part biosboot --fstype=biosboot --size=1     --ondisk=sda
part /boot/efi --fstype=efi     --size=512   --ondisk=sda --fsoptions="umask=0077,shortname=winnt"
part raid.11   --size=1024      --ondisk=sda
part raid.12   --size=1024      --ondisk=sdb
part raid.21   --size=1         --grow --ondisk=sda
part raid.22   --size=1         --grow --ondisk=sdb
raid /boot     --level=1 --device=md0 --fstype=xfs --metadata=1.0 raid.11 raid.12
raid pv.01     --level=1 --device=md1 --metadata=1.2 raid.21 raid.22
volgroup vg0 pv.01
logvol /       --vgname=vg0 --size=51200 --name=root --fstype=xfs
logvol swap    --vgname=vg0 --size=8192  --name=swap

# Boot loader policy: MBR of the first disk, explicit arguments, GRUB password.
bootloader --location=mbr --boot-drive=sda --timeout=5 \
           --append="console=tty0 console=ttyS0,115200n8 net.ifnames=0 panic=30 crashkernel=auto" \
           --iscrypted --password=grub.pbkdf2.sha512.10000.C4A9B1F2E8...D3E1

rootpw --iscrypted $6$rounds=656000$...
authselect select sssd with-mkhomedir --force
firewall --enabled --service=ssh
selinux --enforcing
reboot

%packages
@core
efibootmgr
grub2-tools
grub2-pc
mdadm
%end

%post --log=/root/ks-post-boot.log
set -x
# /boot is mdraid metadata 1.0, so the bootstrap must be written to BOTH disks.
grub2-install --target=i386-pc --recheck /dev/sda
grub2-install --target=i386-pc --recheck /dev/sdb
grub2-mkconfig -o /boot/grub2/grub.cfg

# Persist the array so the initramfs can assemble it.
mdadm --detail --scan >> /etc/mdadm.conf
dracut --force --regenerate-all

# Provisioning-time gate: fail the build rather than ship an unbootable image.
grep -q 'root=' /boot/grub2/grub.cfg || { echo "FATAL: no root= in grub.cfg"; exit 1; }
for d in /dev/sda /dev/sdb; do
    dd if=$d bs=512 count=1 status=none | strings | grep -q GRUB \
      || { echo "FATAL: no bootstrap on $d"; exit 1; }
done
%end
```

---

## 10. Verificación y diagnóstico de fallos

### 10.1 Script de verificación previo al reinicio — ejecutalo antes de cada reinicio

```bash
#!/usr/bin/env bash
# /usr/local/sbin/verify-boot-chain — exit non-zero if this host may not boot.
set -uo pipefail

FAIL=0
ok()   { printf '  \033[32m[ OK ]\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m[FAIL]\033[0m %s\n' "$1"; FAIL=1; }
warn() { printf '  \033[33m[WARN]\033[0m %s\n' "$1"; }

if [ -d /sys/firmware/efi ]; then FW=uefi; else FW=bios; fi
echo "== Boot chain verification ($(hostname -s), firmware: ${FW}) =="

# --- 1. Generated configuration exists and is not truncated ---------------
CFG=$(ls /boot/grub/grub.cfg /boot/grub2/grub.cfg 2>/dev/null | head -1)
if [ -z "${CFG}" ]; then
    bad "no grub.cfg found"
else
    ok "config: ${CFG}"
    N=$(grep -c '^[[:space:]]*menuentry ' "${CFG}")
    [ "${N}" -ge 1 ] && ok "${N} menu entries" || bad "zero menu entries"
    grep -q 'root=UUID=\|root=/dev/mapper/\|BOOT_IMAGE' "${CFG}" \
        && ok "root= present" || bad "no root= in any entry"
    grep -qE 'root=/dev/[sh]d[a-z][0-9]' "${CFG}" \
        && warn "unstable device name in root= — will break on hardware change"
fi

# --- 2. Every referenced kernel and initrd actually exists ----------------
BOOTDIR=$(findmnt -no TARGET /boot 2>/dev/null || echo /)
MISSING=0
while read -r f; do
    [ -e "${BOOTDIR}/${f}" ] || [ -e "/boot/${f}" ] || { bad "referenced file missing: ${f}"; MISSING=1; }
done < <(grep -hoP '^\s*(linux|initrd)\s+\K\S+' "${CFG}" 2>/dev/null | sort -u)
[ "${MISSING}" -eq 0 ] && ok "all referenced kernel/initrd files present"

# --- 3. The running kernel has an entry -----------------------------------
grep -q "$(uname -r)" "${CFG}" 2>/dev/null \
    && ok "running kernel $(uname -r) has a menu entry" \
    || bad "running kernel $(uname -r) has NO menu entry"

# --- 4. At least two bootable kernels (a fallback exists) ------------------
K=$(ls /boot/vmlinuz-* 2>/dev/null | wc -l)
[ "${K}" -ge 2 ] && ok "${K} kernels installed (fallback available)" \
                 || warn "only ${K} kernel installed — no rollback target"

# --- 5. initramfs matches every kernel ------------------------------------
for k in /boot/vmlinuz-*; do
    v=${k#/boot/vmlinuz-}
    [ -e "/boot/initrd.img-${v}" ] || [ -e "/boot/initramfs-${v}.img" ] \
        && ok "initramfs present for ${v}" \
        || bad "NO initramfs for kernel ${v}"
done

# --- 6. Bootstrap present on disk -----------------------------------------
if [ "${FW}" = bios ]; then
    for d in $(lsblk -dno NAME,TYPE | awk '$2=="disk"{print "/dev/"$1}'); do
        if dd if="$d" bs=512 count=1 status=none 2>/dev/null | strings | grep -q GRUB; then
            ok "GRUB bootstrap in MBR of $d"
        else
            warn "no GRUB bootstrap on $d (intentional if it is not a boot device)"
        fi
    done
else
    for esp in $(findmnt -rno TARGET -t vfat | grep -E '/boot/efi|/efi'); do
        if find "$esp" -iname '*.efi' -print -quit | grep -q .; then
            ok "EFI binaries present in ${esp}"
        else
            bad "${esp} contains no EFI binary"
        fi
    done
    if command -v efibootmgr >/dev/null; then
        ORDER=$(efibootmgr | awk -F': ' '/^BootOrder/{print $2}')
        [ -n "${ORDER}" ] && ok "BootOrder: ${ORDER}" || bad "BootOrder is empty"
        CNT=$(efibootmgr | grep -c '^Boot[0-9A-F]\{4\}')
        [ "${CNT}" -ge 2 ] && ok "${CNT} NVRAM entries (fallback available)" \
                           || warn "only ${CNT} NVRAM entry — no firmware-level fallback"
    fi
fi

# --- 7. /boot free space (a full /boot silently breaks kernel installs) ----
USE=$(df --output=pcent /boot 2>/dev/null | tail -1 | tr -dc '0-9')
[ -n "${USE}" ] && { [ "${USE}" -lt 80 ] && ok "/boot ${USE}% used" || bad "/boot ${USE}% used — kernel updates will fail"; }

# --- 8. grubenv sanity ----------------------------------------------------
GE=$(ls /boot/grub/grubenv /boot/grub2/grubenv 2>/dev/null | head -1)
if [ -n "${GE}" ]; then
    SZ=$(stat -c %s "${GE}")
    [ "${SZ}" -eq 1024 ] && ok "grubenv is 1024 bytes" || bad "grubenv is ${SZ} bytes (must be 1024)"
fi

echo
[ "${FAIL}" -eq 0 ] && echo "RESULT: safe to reboot." || echo "RESULT: DO NOT REBOOT."
exit "${FAIL}"
```

```console
$ sudo /usr/local/sbin/verify-boot-chain
== Boot chain verification (node-a17, firmware: uefi) ==
  [ OK ] config: /boot/grub/grub.cfg
  [ OK ] 6 menu entries
  [ OK ] root= present
  [ OK ] all referenced kernel/initrd files present
  [ OK ] running kernel 6.1.0-18-amd64 has a menu entry
  [ OK ] 2 kernels installed (fallback available)
  [ OK ] initramfs present for 6.1.0-17-amd64
  [ OK ] initramfs present for 6.1.0-18-amd64
  [ OK ] EFI binaries present in /boot/efi
  [ OK ] BootOrder: 0005,0006,0003
  [ OK ] 5 NVRAM entries (fallback available)
  [ OK ] /boot 34% used
  [ OK ] grubenv is 1024 bytes

RESULT: safe to reboot.
```

### 10.2 Catálogo de fallos — síntoma → causa → solución

| Síntoma en consola | Causa raíz | Acción inmediata | Solución permanente |
|---|---|---|---|
| Nada; "No bootable device" | Sin bootstrap en el MBR / sin entrada NVRAM válida / firmware apuntando al disco equivocado | arrancar desde medio de rescate | `grub-install /dev/sda`; `efibootmgr -c …`; corregir el orden de arranque del firmware |
| `GRUB _` y se detiene | `core.img` no se puede leer — hueco sobrescrito, o blocklists invalidadas | medio de rescate | `grub-install --recheck /dev/sda` |
| `error: no such partition` → `grub rescue>` | la partición `/boot` se movió, se redimensionó, cambió de UUID, o los discos se reordenaron | `ls`, `set prefix=…`, `set root=…`, `insmod normal`, `normal` | `grub-install` + `grub-mkconfig` después de arrancar |
| `error: file '/boot/grub/i386-pc/normal.mod' not found` | el prefix apunta a una ruta que ya no contiene los módulos | la misma secuencia de rescate de arriba | `grub-install` |
| `error: symbol 'grub_calloc' not found` | **clase BootHole**: los módulos en disco se actualizaron, `core.img` no se reinstaló | arrancar desde ISO de rescate, chroot | `grub-install` en la **misma transacción** que cada actualización del paquete `grub2` |
| `error: unknown filesystem` | falta en `core.img` el módulo de fs requerido (Btrfs, LVM, mdraid) | medio de rescate | `grub-install --modules="lvm mdraid1x btrfs"` / definir `GRUB_PRELOAD_MODULES` |
| `error: diskfilter writes are not supported` | GRUB intentó escribir `grubenv` sobre LVM/mdraid | ignorar — es una advertencia en el arranque | poner `GRUB_SAVEDEFAULT=false`; llevar `/boot` a una partición plana |
| Aparece el menú, se selecciona la entrada, y luego pantalla en negro | fallo de modo de video / KMS — GRUB funcionó | presionar `e`, agregar `nomodeset`, `Ctrl-x` | driver correcto, o fijar `nomodeset` en `GRUB_CMDLINE_LINUX` |
| `Kernel panic - not syncing: VFS: Unable to mount root fs on unknown-block(0,0)` | initrd faltante/desajustado, o `root=` incorrecto | arrancar el kernel anterior desde el menú | `update-initramfs -u -k all` / `dracut -f --regenerate-all`; corregir `root=` |
| Cae a `(initramfs)` o `dracut:/#` | GRUB tuvo éxito; el initramfs no puede encontrar/ensamblar la raíz (RAID, LVM, LUKS, driver faltante) | `cat /proc/cmdline`, `blkid`, `lvm vgchange -ay` | regenerar el initramfs con los módulos correctos; corregir `/etc/mdadm.conf`, `/etc/crypttab` |
| Arranca siempre en un kernel **viejo** | `GRUB_DEFAULT=saved` + un `saved_entry` obsoleto | `grub-set-default 0` | auditar `grub-editenv list` desde el monitoreo |
| El menú no muestra kernels tras una actualización | `/boot` lleno — el paquete del kernel se instaló pero los archivos quedaron truncados | liberar espacio, reinstalar el paquete del kernel | dimensionar `/boot` ≥ 1 GiB; forzar el autoremove de kernels viejos |
| Secure Boot: `Verification failed: (0x1A) Security Violation` | `grubx64.efi`/`vmlinuz` sin firmar o mal firmado (a menudo tras un `grub-install` en RHEL UEFI) | desactivar Secure Boot para poder entrar | reinstalar los paquetes `shim-x64`/`grub2-efi-x64`; nunca hacer `grub2-install` en RHEL UEFI |
| La entrada de arranque del firmware desaparece tras cada reinicio | firmware defectuoso que poda la NVRAM, o NVRAM llena | volver a agregarla con `efibootmgr -c` | instalar en la **ruta removible** como respaldo: `grub-install --removable` |
| Pide contraseña en cada reinicio desatendido | `set superusers` sin `--unrestricted` en las entradas normales | arrancar manualmente | agregar `--unrestricted` a las entradas normales |
| Funciona en `/dev/sda`, muere cuando `sda` falla | el bootstrap nunca se espejó a `sdb` | arrancar desde `sdb` vía el menú del firmware | `grub-install /dev/sdb`; agregar el espejo a `install_devices` |

### 10.3 La reparación canónica por chroot

Aplica a casi todas las filas anteriores. Arrancá cualquier imagen live/rescue de una arquitectura compatible.

```console
# 1. Identify the layout.
$ sudo lsblk -f
NAME        FSTYPE      LABEL UUID                                 MOUNTPOINTS
sda
├─sda1
├─sda2      vfat        ESP   9F4A-1C2E
├─sda3      ext4        boot  8f3c1a92-4b7e-4c31-a0f2-9d5e6b7c8a10
└─sda4      LVM2_member       kQ2xYz-...
  ├─vg0-root xfs              c4e2d1b0-a9f8-4e37-b6c5-2d1a0f9e8b7c
  └─vg0-data xfs              e7f8a9b0-...

# 2. Activate the storage stack the initramfs would have activated.
$ sudo vgchange -ay
  2 logical volume(s) in volume group "vg0" now active
$ sudo mdadm --assemble --scan          # if mdraid is in play

# 3. Mount root, then everything below it, in order.
$ sudo mount /dev/vg0/root /mnt
$ sudo mount /dev/sda3     /mnt/boot
$ sudo mount /dev/sda2     /mnt/boot/efi        # UEFI only

# 4. Bind the kernel interfaces the tools need.
$ for d in /dev /dev/pts /proc /sys /run; do sudo mount --bind "$d" "/mnt$d"; done
$ sudo mount --bind /sys/firmware/efi/efivars /mnt/sys/firmware/efi/efivars   # UEFI only
# efivars is MANDATORY: without it, efibootmgr cannot write NVRAM and
# grub-install silently produces a system with no boot entry.

# 5. Enter.
$ sudo chroot /mnt /bin/bash

# 6. Repair.
root@rescue:/# grub-install --target=x86_64-efi --efi-directory=/boot/efi \
                            --bootloader-id=debian --recheck
Installing for x86_64-efi platform.
Installation finished. No error reported.

root@rescue:/# update-grub
Generating grub configuration file ...
Found linux image: /boot/vmlinuz-6.1.0-18-amd64
Found initrd image: /boot/initrd.img-6.1.0-18-amd64
done

root@rescue:/# update-initramfs -u -k all
update-initramfs: Generating /boot/initrd.img-6.1.0-18-amd64
update-initramfs: Generating /boot/initrd.img-6.1.0-17-amd64

root@rescue:/# efibootmgr -v | grep -i debian
Boot0005* debian	HD(2,GPT,9f4a1c2e-...,0x800,0x100000)/File(\EFI\DEBIAN\SHIMX64.EFI)

root@rescue:/# exit

# 7. Unmount in reverse and reboot.
$ sudo umount -R /mnt
$ sudo reboot
```

> **El error de chroot más común, con diferencia:** olvidarse de `--bind /sys/firmware/efi/efivars`. `grub-install` reporta "Installation finished. No error reported." y la máquina sigue sin arrancar, porque no se creó ninguna entrada en NVRAM. Verificá siempre con `efibootmgr -v` **dentro** del chroot.

### 10.4 Forense posterior al arranque

```console
$ cat /proc/cmdline
BOOT_IMAGE=/vmlinuz-6.1.0-18-amd64 root=UUID=c4e2d1b0-a9f8-4e37-b6c5-2d1a0f9e8b7c ro console=tty0 console=ttyS0,115200n8 net.ifnames=0 panic=30 quiet loglevel=3

$ systemd-analyze
Startup finished in 3.412s (firmware) + 2.187s (loader) + 1.043s (kernel) + 9.876s (userspace) = 16.519s
graphical.target reached after 9.871s in userspace.

$ systemd-analyze blame | head -5
5.812s NetworkManager-wait-online.service
1.204s systemd-udev-settle.service
 903ms dracut-initqueue.service
 441ms lvm2-monitor.service
 312ms systemd-journal-flush.service

$ journalctl -b -1 -p err --no-pager | head
-- Journal begins at Mon 2026-08-11 06:02:15 UTC, ends at Tue 2026-08-25 12:44:03 UTC. --
Aug 25 12:38:41 node-a17 kernel: EXT4-fs (sda3): mounted filesystem without journal

$ journalctl --list-boots | head -4
IDX BOOT ID                          FIRST ENTRY                 LAST ENTRY
 -2 3f9a...c1                        Mon 2026-08-11 06:02:15 UTC Fri 2026-08-22 09:14:33 UTC
 -1 7b2e...4d                        Fri 2026-08-22 09:15:02 UTC Tue 2026-08-25 12:37:58 UTC
  0 c8d1...9f                        Tue 2026-08-25 12:38:40 UTC Tue 2026-08-25 12:44:03 UTC
```

La cifra **`loader`** de `systemd-analyze` es la contribución de tiempo real del propio gestor de arranque (solo UEFI, a partir de los datos de rendimiento del firmware). Un salto ahí suele significar `os-prober` escaneando en el arranque, un intento de arranque por red que expira, o un `GRUB_TIMEOUT` muy grande.

`journalctl --list-boots` es el rastro de auditoría para el diseño de conteo de arranques de la sección 8.4: los huecos entre el `LAST ENTRY` de un arranque y el `FIRST ENTRY` del siguiente son apagados sucios — exactamente los eventos que deberían estar incrementando `boot_attempts`.

### 10.5 BootLoaderSpec (BLS) de Red Hat — una superficie de configuración distinta

En RHEL 8+/Fedora, `grub.cfg` es en su mayor parte un bucle sobre `/boot/loader/entries/*.conf`. Editar `grub.cfg` ahí no hace casi nada.

```console
$ ls /boot/loader/entries/
6b3f2a1c9d8e4f5a0b1c2d3e4f5a6b7c-5.14.0-427.13.1.el9_4.x86_64.conf
6b3f2a1c9d8e4f5a0b1c2d3e4f5a6b7c-5.14.0-362.24.1.el9_3.x86_64.conf
6b3f2a1c9d8e4f5a0b1c2d3e4f5a6b7c-0-rescue.conf

$ cat /boot/loader/entries/6b3f2a1c9d8e4f5a0b1c2d3e4f5a6b7c-5.14.0-427.13.1.el9_4.x86_64.conf
title Red Hat Enterprise Linux (5.14.0-427.13.1.el9_4.x86_64) 9.4 (Plow)
version 5.14.0-427.13.1.el9_4.x86_64
linux /vmlinuz-5.14.0-427.13.1.el9_4.x86_64
initrd /initramfs-5.14.0-427.13.1.el9_4.x86_64.img
options root=/dev/mapper/vg0-root ro crashkernel=1G-4G:192M,4G-64G:256M rd.lvm.lv=vg0/root console=ttyS0,115200n8
grub_users $grub_users
grub_arg --unrestricted
grub_class rhel

$ sudo grubby --info=DEFAULT
index=0
kernel="/boot/vmlinuz-5.14.0-427.13.1.el9_4.x86_64"
args="ro crashkernel=1G-4G:192M,4G-64G:256M rd.lvm.lv=vg0/root console=ttyS0,115200n8"
root="/dev/mapper/vg0-root"
initrd="/boot/initramfs-5.14.0-427.13.1.el9_4.x86_64.img"
title="Red Hat Enterprise Linux (5.14.0-427.13.1.el9_4.x86_64) 9.4 (Plow)"
id="6b3f2a1c9d8e4f5a0b1c2d3e4f5a6b7c-5.14.0-427.13.1.el9_4.x86_64"

# Add an argument to EVERY entry, including future kernels:
$ sudo grubby --update-kernel=ALL --args="audit=1 audit_backlog_limit=8192"
$ sudo grubby --update-kernel=ALL --remove-args="quiet rhgb"

# Change the default kernel:
$ sudo grubby --set-default /boot/vmlinuz-5.14.0-362.24.1.el9_3.x86_64
The default is /boot/loader/entries/6b3f2a1c9d8e4f5a0b1c2d3e4f5a6b7c-5.14.0-362.24.1.el9_3.x86_64.conf with index 1 and kernel /boot/vmlinuz-5.14.0-362.24.1.el9_3.x86_64
```

> **Los kernels futuros importan.** `grubby --update-kernel=ALL` escribe en las entradas existentes **y** en `/etc/kernel/cmdline`, de modo que `kernel-install` aplica los mismos argumentos a los kernels instalados más adelante. Editar los archivos `.conf` a mano no lo hace.

---

## 11. Resumen práctico de comandos

### GRUB 2

```console
$ sudo grub-mkconfig -o /boot/grub/grub.cfg     # generate config (portable form)
$ sudo update-grub                              # Debian wrapper for the above
$ sudo grub2-mkconfig -o /boot/grub2/grub.cfg   # Red Hat form
$ sudo grub-install --target=i386-pc /dev/sda   # BIOS install to the MBR
$ sudo grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=debian
$ sudo grub-install --removable --efi-directory=/boot/efi   # \EFI\BOOT\BOOTX64.EFI
$ sudo grub-mkpasswd-pbkdf2                     # generate a menu password hash
$ sudo grub-set-default 'entry-id'              # permanent default
$ sudo grub-reboot 'entry-id'                   # ONE-SHOT default
$ sudo grub-editenv list                        # read grubenv
$ sudo grub-editenv /boot/grub/grubenv unset next_entry
$ grub-probe --target=fs /boot                  # what grub-install sees
$ sudo grub-mkrescue -o rescue.iso /tmp/empty   # bootable rescue ISO
$ sudo grub-mknetdir --net-directory=/srv/tftp  # netboot tree
```

### GRUB Legacy

```console
# grub-install --root-directory=/ /dev/sda       # non-interactive install
# grub                                           # interactive shell
grub> find /boot/grub/stage1                     # which partitions hold GRUB
grub> root (hd0,0)                               # partition holding /boot/grub
grub> setup (hd0)                                # write stage1 to the MBR of hd0
grub> quit
# grub-md5-crypt                                 # menu.lst password hash
```

### UEFI

```console
$ sudo efibootmgr -v                             # list entries, order, current
$ sudo efibootmgr -c -d /dev/sda -p 2 -L "debian" -l '\EFI\debian\shimx64.efi'
$ sudo efibootmgr -o 0005,0006,0003              # persistent order
$ sudo efibootmgr -n 0006                        # BootNext — one shot
$ sudo efibootmgr -b 0006 -B                     # delete entry 0006
$ mokutil --sb-state                             # Secure Boot on/off
$ bootctl status                                 # systemd view of the ESP
```

### Diagnóstico

```console
$ [ -d /sys/firmware/efi ] && echo UEFI || echo BIOS
$ cat /proc/cmdline
$ lsblk -f
$ sudo blkid
$ findmnt /boot /boot/efi
$ sudo dd if=/dev/sda bs=512 count=1 status=none | strings | grep -c GRUB
$ awk -F"'" '/^menuentry /{print $2" ==> "$4}' /boot/grub/grub.cfg
$ sudo grubby --info=ALL            # Red Hat BLS
$ systemd-analyze
$ journalctl -b -1 -p err
```

---

## 12. Puntos enfocados al examen que la práctica de producción puede opacar

1. **Numeración de particiones.** GRUB Legacy cuenta las particiones desde **0**; GRUB 2 desde **1**. Los discos cuentan desde **0** en ambos. `(hd0,0)` ≡ `(hd0,1)` ≡ `/dev/sda1`.
2. **`menu.lst` se edita; `grub.cfg` se genera.** Las fuentes de GRUB 2 son `/etc/default/grub` y `/etc/grub.d/`; el generador es `grub-mkconfig`.
3. **`grub.conf`** es el nombre que usa Red Hat para la configuración de GRUB Legacy; `menu.lst` es un symlink hacia ella en esos sistemas.
4. **`grub-install` escribe el código de arranque; `grub-mkconfig` escribe el menú.** Son independientes, y un cambio en uno normalmente exige volver a ejecutar el otro.
5. **`setup (hdN)` escribe el MBR; `root (hdN,M)` selecciona desde dónde se lee stage2.** Origen y destino son argumentos separados.
6. **El MBR ocupa 512 bytes:** 446 de bootstrap + 64 de tabla de particiones + 2 de firma.
7. **`chainloader +1`** carga un sector del dispositivo `root` actual y salta a él — el mecanismo para arrancar otro gestor u otro disco.
8. **`fallback`** (Legacy) y `GRUB_DEFAULT=saved` + `grub-reboot` (GRUB 2) son las "opciones de arranque de respaldo" del objetivo.
9. **UEFI no tiene MBR.** `grub-install` sobre UEFI escribe un binario `.efi` en la ESP y una entrada NVRAM vía `efibootmgr`; `\EFI\BOOT\BOOTX64.EFI` es la ruta de respaldo.
10. **Editar una entrada con `e` es temporal.** Sobrevive exactamente un arranque y nunca se escribe en disco.

---

## 13. Referencias

**Objetivos de certificación**
- LPI — Objetivos del examen 101-500 (LPIC-1 v5.0): https://www.lpi.org/our-certifications/exam-101-objectives/
- LPI — Visión general de la certificación LPIC-1: https://www.lpi.org/our-certifications/lpic-1-overview/

**GNU GRUB**
- Manual de GNU GRUB 2.x (oficial): https://www.gnu.org/software/grub/manual/grub/grub.html
- GRUB 2 — Invocación de `grub-install`: https://www.gnu.org/software/grub/manual/grub/grub.html#Invoking-grub_002dinstall
- GRUB 2 — Invocación de `grub-mkconfig`: https://www.gnu.org/software/grub/manual/grub/grub.html#Invoking-grub_002dmkconfig
- GRUB 2 — Manejo de la configuración simple (`/etc/default/grub`): https://www.gnu.org/software/grub/manual/grub/grub.html#Simple-configuration
- GRUB 2 — Comandos de línea de comandos y de entrada de menú: https://www.gnu.org/software/grub/manual/grub/grub.html#Commands
- GRUB 2 — Convención de nombres (sintaxis de dispositivos): https://www.gnu.org/software/grub/manual/grub/grub.html#Naming-convention
- GRUB 2 — Autenticación y autorización: https://www.gnu.org/software/grub/manual/grub/grub.html#Security
- GRUB 2 — Bloque de entorno (`grubenv`): https://www.gnu.org/software/grub/manual/grub/grub.html#Environment-block
- Manual de GNU GRUB Legacy 0.97: https://www.gnu.org/software/grub/manual/legacy/grub.html
- GRUB Legacy — `menu.lst` y comandos específicos del menú: https://www.gnu.org/software/grub/manual/legacy/Menu_002dspecific-commands.html
- GRUB Legacy — Instalar GRUB de forma nativa (`root` / `setup`): https://www.gnu.org/software/grub/manual/legacy/Installing-GRUB-natively.html
- Sitio del proyecto GRUB: https://www.gnu.org/software/grub/

**Documentación de distribuciones**
- Debian Wiki — GRUB 2: https://wiki.debian.org/Grub2
- Debian Wiki — UEFI: https://wiki.debian.org/UEFI
- Ubuntu Community Help — Grub2: https://help.ubuntu.com/community/Grub2
- Red Hat Enterprise Linux 9 — Gestión del gestor de arranque GRUB: https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/managing_monitoring_and_updating_the_kernel/assembly_configuring-kernel-command-line-parameters_managing-monitoring-and-updating-the-kernel
- Red Hat Enterprise Linux 9 — Configuración de parámetros de la línea de comandos del kernel: https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/managing_monitoring_and_updating_the_kernel/configuring-kernel-command-line-parameters_managing-monitoring-and-updating-the-kernel
- SUSE Linux Enterprise Server — El gestor de arranque GRUB 2: https://documentation.suse.com/sles/15-SP5/html/SLES-all/cha-grub2.html
- Arch Wiki — GRUB: https://wiki.archlinux.org/title/GRUB
- Arch Wiki — Unified Extensible Firmware Interface: https://wiki.archlinux.org/title/Unified_Extensible_Firmware_Interface
- Arch Wiki — EFI system partition: https://wiki.archlinux.org/title/EFI_system_partition
- Arch Wiki — systemd-boot: https://wiki.archlinux.org/title/Systemd-boot

**Especificaciones y firmware**
- Especificación UEFI (UEFI Forum): https://uefi.org/specifications
- Boot Loader Specification (systemd / UAPI Group): https://uapi-group.org/specifications/specs/boot_loader_specification/
- Discoverable Partitions Specification: https://uapi-group.org/specifications/specs/discoverable_partitions_specification/
- systemd — `bootctl(1)`: https://www.freedesktop.org/software/systemd/man/latest/bootctl.html
- systemd — `systemd-boot(7)`: https://www.freedesktop.org/software/systemd/man/latest/systemd-boot.html
- Kernel Linux — Los parámetros de la línea de comandos del kernel: https://www.kernel.org/doc/html/latest/admin-guide/kernel-parameters.html
- Kernel Linux — Proceso de arranque (x86): https://www.kernel.org/doc/html/latest/arch/x86/boot.html

**Herramientas**
- `efibootmgr` (rhboot): https://github.com/rhboot/efibootmgr
- `shim` — el cargador de primera etapa de Secure Boot: https://github.com/rhboot/shim
- Documentación de `dracut`: https://man7.org/linux/man-pages/man8/dracut.8.html
- `grubby(8)` — manipulación de entradas BLS en Red Hat: https://man7.org/linux/man-pages/man8/grubby.8.html
- Proyecto SYSLINUX: https://wiki.syslinux.org/wiki/index.php?title=The_Syslinux_Project
- Gestor de arranque rEFInd: https://www.rodsbooks.com/refind/

**Avisos de seguridad**
- CVE-2020-10713 "BootHole" (Red Hat): https://access.redhat.com/security/cve/CVE-2020-10713
- GRUB2 SBAT (Secure Boot Advanced Targeting): https://github.com/rhboot/shim/blob/main/SBAT.md