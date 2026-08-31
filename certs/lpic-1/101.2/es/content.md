# 101.2 — Arrancar el sistema

**Certificación:** LPIC-1 (Exámenes 101-500 / 102-500, versión 5.0)
**Objetivo:** Guiar al sistema a través del proceso de arranque
**Peso en el curso:** 4.69

**Áreas de conocimiento clave cubiertas acá**

- Proveer comandos habituales al gestor de arranque y opciones al kernel en el momento del arranque
- Demostrar conocimiento de la secuencia de arranque desde BIOS/UEFI hasta el arranque completo
- Comprensión de SysVinit y systemd
- Conocimiento básico de Upstart
- Revisar eventos de arranque en los archivos de registro

**Términos y utilidades:** `dmesg`, `journalctl`, BIOS, UEFI, bootloader, kernel, initramfs, init, SysVinit, systemd

---

## 1. El problema arquitectónico: el arranque es el único camino de código al que no podés entrar por SSH

Cualquier otra falla en un parque Linux se puede depurar con las herramientas que ya usás: `kubectl`, `ssh`, Prometheus, una shell. El arranque es distinto. Entre el encendido y el momento en que `sshd` se enlaza a `:22` hay una ventana de cinco a noventa segundos en la que **la máquina está ejecutando tu configuración sin ningún canal de observabilidad salvo una consola serie que probablemente no cableaste**.

Esa asimetría es lo que convierte al arranque en un problema de SRE y no en una pregunta trivial de administración de sistemas.

### 1.1 Dónde duele esto en producción

| Escenario | Qué sale mal realmente | Radio de impacto |
|---|---|---|
| Parcheo de kernel desatendido (`kpatch`/`dnf-automatic` + ventana de reinicio) | El initramfs del kernel nuevo se construyó sin el driver de multipath o NVMe; el nodo nunca monta la raíz | 1 nodo por oleada de reinicio — hasta que la oleada abarca toda la flota |
| Autoescalado de nodos de Kubernetes | La AMI/imagen tiene una línea de comandos de kernel que referencia un `root=UUID=` que ya no coincide con el disco clonado | 100% de los nodos recién escalados; el clúster deja de escalar en silencio |
| Migración de almacenamiento (SAN → NVMe-oF) | `dracut` nunca incorporó `rd.nvmf.discover`, el dispositivo raíz no está presente tras el timeout de 180 s de `dracut-initqueue` | Rack entero |
| Edición de `/etc/fstab` vía gestión de configuración | Un dispositivo que no existe hace que systemd caiga a `emergency.target`, que **exige una contraseña de root en la consola** | Todos los hosts que tocó el playbook |
| Secure Boot forzado en toda la flota | Un módulo fuera del árbol (ZFS, NVIDIA, driver de fabricante de ipmi) no está firmado; el kernel se niega a cargarlo, la raíz o la GPU nunca aparecen | Todos los hosts con ese módulo en el initramfs |
| Tormenta de arranque tras un corte de energía | 400 nodos golpean el mismo destino DHCP/PXE/iSCSI simultáneamente; los timeouts se encadenan | Centro de datos |

El denominador común: **una falla de arranque convierte un problema de software en un problema de acceso físico.** El tiempo medio de reparación deja de ser función de tu habilidad y pasa a ser función de si funcionan IPMI/iDRAC/`aws ec2 get-console-output`.

### 1.2 El principio de diseño que hay que internalizar

> Cada etapa de la cadena de arranque le entrega a la siguiente un **conjunto de capacidades estrictamente mayor**, y cada traspaso es un lugar donde el estado puede estar equivocado. Depurar el arranque significa identificar *qué traspaso* falló, porque las herramientas disponibles difieren por completo en cada uno.

```
Power / reset vector
      │
      ▼
┌─────────────────┐  16-bit real mode (BIOS) or UEFI DXE environment
│ Firmware        │  Capability: read a block device, execute a blob
│ BIOS or UEFI    │  State handed on: pointer to bootloader
└────────┬────────┘
         ▼
┌─────────────────┐  GRUB2 / systemd-boot / syslinux / U-Boot
│ Boot loader     │  Capability: filesystem drivers, a menu, a scripting language
│                 │  State handed on: kernel image + initramfs + cmdline
└────────┬────────┘
         ▼
┌─────────────────┐  Self-decompress, set up MMU, mount initramfs on rootfs (tmpfs)
│ Kernel          │  Capability: everything compiled in; NOT modules on disk yet
│                 │  State handed on: exec /init from the initramfs
└────────┬────────┘
         ▼
┌─────────────────┐  dracut / initramfs-tools; udev, LVM, LUKS, mdraid, iSCSI, NFS
│ initramfs       │  Capability: userspace, but only what is inside the cpio archive
│ (PID 1, phase 1)│  State handed on: real root mounted at /sysroot, then switch_root
└────────┬────────┘
         ▼
┌─────────────────┐  systemd / SysVinit / Upstart
│ init (PID 1)    │  Capability: the real filesystem, all of userspace
│                 │  State handed on: default.target reached / runlevel N entered
└────────┬────────┘
         ▼
    getty, sshd, kubelet, containerd …
```

Memorizá los cuatro límites de traspaso. La sección 6 está organizada en torno a ellos, porque **la primera pregunta de diagnóstico siempre es "¿hasta dónde llegó?"**

---

## 2. Etapa 1 — Firmware: BIOS frente a UEFI

### 2.1 BIOS heredada / MBR

El firmware no sabe nada de sistemas de archivos. Lee el **LBA 0** — los primeros 512 bytes del dispositivo de arranque — a memoria en `0x7C00` y salta ahí, siempre que los últimos dos bytes sean la firma `0x55AA`.

```
MBR layout (512 bytes)
┌────────────────────────────────────┬──────────────┬──────┐
│ Bootstrap code area (446 bytes)    │ Partition    │ 0x55 │
│ = GRUB stage 1 (boot.img)          │ table 4×16 B │ 0xAA │
└────────────────────────────────────┴──────────────┴──────┘
 offset 0                          446           510    512
```

446 bytes no alcanzan para implementar ext4. Así que GRUB se divide:

| Componente | Ubicación | Tamaño | Tarea |
|---|---|---|---|
| `boot.img` (etapa 1) | Área de bootstrap del MBR | 446 B | Cargar el primer sector de `core.img` |
| `core.img` (etapa 1.5) | **Hueco del MBR** — sectores 1–2047, el espacio sin usar antes de la primera partición | ~25–30 KiB | Contiene los módulos de sistema de archivos + LVM + RAID; ya puede *leer archivos* |
| `/boot/grub2/` (etapa 2) | Sistema de archivos real | MB | Menú, configuración, módulos, fuentes |

El hueco del MBR sólo existe porque el particionado de la era DOS alineaba la partición 1 en el sector 63 (más tarde 2048). **En un disco GPT no hay hueco**, y por eso un sistema GPT + BIOS necesita una partición dedicada de ~1 MiB de tipo `21686148-6449-6E6F-744E-656564454649` (flag `bios_grub`) para `core.img`. Olvidarla es la falla clásica de "el instalador terminó bien, la máquina no arranca".

```console
$ sudo fdisk -l /dev/sda | head -12
Disk /dev/sda: 100 GiB, 107374182400 bytes, 209715200 sectors
Disk model: QEMU HARDDISK
Units: sectors of 1 * 512 = 512 bytes
Sector size (logical/physical): 512 bytes / 512 bytes
I/O size (minimum/optimal): 512 bytes / 512 bytes
Disklabel type: gpt
Disk identifier: 7C4A9B10-6F3E-4C21-9A55-1D2E8F0B3C77

Device       Start       End   Sectors  Size Type
/dev/sda1     2048      4095      2048    1M BIOS boot
/dev/sda2     4096   2101247   2097152    1G Linux filesystem
/dev/sda3  2101248 209713151 207611904   99G Linux LVM
```

```console
$ sudo dd if=/dev/sda bs=512 count=1 2>/dev/null | xxd | tail -3
000001c0: 0100 ee7f 3ac2 0100 0000 ffff ffff 0000  ....:...........
000001d0: 0000 0000 0000 0000 0000 0000 0000 0000  ................
000001e0: 0000 0000 0000 0000 0000 0000 0000 0000  ................
000001f0: 0000 0000 0000 0000 0000 0000 0000 55aa  ..............U.
```

Ese `55aa` final es la firma de arranque. Su ausencia es la causa más común de `No bootable device`.

### 2.2 UEFI

El firmware UEFI **implementa un driver FAT y un cargador PE32+**. Lee la **EFI System Partition** (ESP, tipo GPT `C12A7328-F81F-11D2-BA4B-00A0C93EC93B`, FAT32) y ejecuta un binario `.efi`. No hay hueco de MBR, ni etapa 1.5, ni blob embebido.

Las entradas de arranque viven en la **NVRAM de la placa madre**, no en el disco. Ésta es la diferencia conceptual más grande y la fuente de la mayoría de los incidentes con UEFI: *podés restaurar una imagen de disco a la perfección y aun así no arrancar, porque la entrada de NVRAM apunta a una ruta que no está.*

```console
$ ls /sys/firmware/efi
config_table  efivars  esrt  fw_platform_size  fw_vendor  runtime  runtime-map  systab
```

> **La frase canónica:** si `/sys/firmware/efi` existe, arrancaste en modo UEFI. Si no existe, arrancaste en modo legacy/CSM. Esto importa porque los instaladores y `grub2-install` se comportan de forma completamente distinta, y una imagen construida en un modo no arranca en el otro.

```console
$ cat /sys/firmware/efi/fw_platform_size
64

$ sudo efibootmgr -v
BootCurrent: 0002
Timeout: 1 seconds
BootOrder: 0002,0001,0000,0003
Boot0000* UiApp	FvVol(7cb8bdc9-f8eb-4f34-aaea-3ee4af6516a1)/FvFile(462caa21-7614-4503-836e-8ab6f4662331)
Boot0001* UEFI QEMU DVD-ROM QM00003 	PciRoot(0x0)/Pci(0x1,0x1)/Ata(1,0,0){auto_created_boot_option}
Boot0002* Fedora	HD(1,GPT,9a3b1e77-2c44-4d0a-b1f5-0c8e3d7a5b21,0x800,0x12c000)/File(\EFI\FEDORA\SHIMX64.EFI)
Boot0003* UEFI PXEv4 (MAC:525400123456)	PciRoot(0x0)/Pci(0x2,0x0)/MAC(525400123456,1)/IPv4(0.0.0.00.0.0.0,0,0)
```

Leé `Boot0002` con atención — es todo el modelo UEFI en una línea: *GUID de partición* + *ruta del archivo dentro de la ESP*.

```console
$ sudo mount | grep efi
/dev/sda1 on /boot/efi type vfat (rw,relatime,fmask=0077,dmask=0077,codepage=437,iocharset=ascii,shortname=winnt,errors=remount-ro)

$ sudo find /boot/efi -type f | sort
/boot/efi/EFI/BOOT/BOOTX64.EFI
/boot/efi/EFI/BOOT/fbx64.efi
/boot/efi/EFI/fedora/BOOTX64.CSV
/boot/efi/EFI/fedora/grub.cfg
/boot/efi/EFI/fedora/grubx64.efi
/boot/efi/EFI/fedora/mmx64.efi
/boot/efi/EFI/fedora/shim.efi
/boot/efi/EFI/fedora/shimx64.efi
```

**Crear una entrada a mano** — el comando de recuperación que querés tener en tu runbook:

```console
$ sudo efibootmgr --create \
    --disk /dev/sda --part 1 \
    --label "Fedora" \
    --loader '\EFI\fedora\shimx64.efi' --verbose
BootCurrent: 0002
Timeout: 1 seconds
BootOrder: 0004,0002,0001,0000,0003
Boot0004* Fedora	HD(1,GPT,9a3b1e77-2c44-4d0a-b1f5-0c8e3d7a5b21,0x800,0x12c000)/File(\EFI\fedora\shimx64.efi)
```

Fijate en las **contrabarras**: la ruta del cargador es una ruta EFI, no una ruta POSIX, y `--part 1` es el número de partición *dentro* de `--disk`.

`\EFI\BOOT\BOOTX64.EFI` es la **ruta de reserva para medios removibles**. El firmware la ejecuta cuando ninguna entrada de NVRAM coincide. Las imágenes de nube y los instaladores USB dependen de ella; y también debería hacerlo cualquier imagen dorada que construyas, porque no podés presembrar la NVRAM de una VM desde dentro de la imagen.

### 2.3 Secure Boot y el shim

Con Secure Boot habilitado, el firmware verifica la firma de cada binario contra las claves de la variable `db`. Las distribuciones no tienen sus claves en el firmware de todos los fabricantes, así que distribuyen **shim**: un cargador pequeño firmado por la CA UEFI de Microsoft, que a su vez verifica GRUB con la clave propia de la distribución, y soporta una base de datos **MOK** (Machine Owner Key) para módulos firmados localmente.

```
firmware db  →  shimx64.efi  →  grubx64.efi  →  vmlinuz  →  kernel modules
   (MS CA)      (distro key)     (distro key)    (MOK for out-of-tree)
```

```console
$ mokutil --sb-state
SecureBoot enabled

$ sudo bootctl status | head -14
System:
      Firmware: UEFI 2.70 (EDK II 1.00)
 Firmware Arch: x64
   Secure Boot: enabled (user)
  TPM2 Support: yes
  Measured UKI: no
  Boot into FW: supported

Current Boot Loader:
      Product: GRUB 2.06
     Features: ✗ Boot counting
               ✗ Menu timeout control
               ✓ Boot loader sets ESP information
          ESP: /dev/disk/by-partuuid/9a3b1e77-2c44-4d0a-b1f5-0c8e3d7a5b21
```

```console
$ sudo dmesg | grep -iE 'secure boot|lockdown'
[    0.000000] secureboot: Secure boot enabled
[    0.010214] Kernel is locked down from EFI Secure Boot mode; see man kernel_lockdown.7
```

**Consecuencia en producción del modo lockdown:** el `kexec` de una imagen sin firmar, el acceso a `/dev/mem`, las escrituras crudas de MSR y la carga de módulos sin firmar fallan todos. Si tu kdump o tu herramienta de parcheo en vivo se rompe el día que se fuerza Secure Boot, esta línea de `dmesg` es el motivo.

### 2.4 BIOS vs UEFI — la tabla de compromisos que deberías poder reproducir

| Dimensión | BIOS heredada | UEFI |
|---|---|---|
| Modo de CPU en el traspaso | Modo real de 16 bits | Modo largo de 64 bits (o 32 bits) |
| Esquema de particiones | MBR (GPT posible con `bios_grub`) | GPT (MBR posible, rara vez) |
| Disco máximo direccionable | 2 TiB (LBA de 32 bits × 512 B) | 8 ZiB (LBA de 64 bits) |
| Máximo de particiones primarias | 4 (+ extendida/lógicas) | 128 por omisión, definido en la cabecera |
| Ubicación del bootloader | Blob embebido en el MBR + hueco del MBR | Archivo normal en una ESP FAT32 |
| Almacenamiento de la entrada de arranque | Implícito — "el primer disco arrancable" | Explícito — variables de NVRAM |
| Conocimiento de sistemas de archivos | Ninguno | FAT12/16/32 |
| Verificación de firmas | Ninguna | Secure Boot (`db`/`dbx`/`MOK`) |
| Arranque por red | PXE vía ROM de opción | PXE integrado, HTTP Boot, iSCSI, IPv6 |
| Ergonomía de recuperación | `dd` para restaurar el MBR; el disco es autocontenido | Hay que restaurar también la entrada de NVRAM o usar `\EFI\BOOT\BOOTX64.EFI` |
| Caso de desastre | Hueco del MBR sobreescrito por un instalador ajeno | NVRAM del firmware borrada / batería CMOS |
| **Elegí para** | Hardware antiguo, algunos valores por defecto de hipervisores | Cualquier cosa ≥2 TiB, Secure Boot, arranque medido con TPM, HTTP boot a escala |

**No los mezcles.** Un disco instalado en modo UEFI no arranca en una máquina configurada en Legacy/CSM, ni al revés. En una flota mixta, estandarizá la configuración de firmware en tus plantillas de aprovisionamiento *antes* de estandarizar la imagen.

---

## 3. Etapa 2 — El gestor de arranque

### 3.1 Panorama comparativo

| Cargador | Modelo de configuración | Soporte de sistemas de archivos | Secure Boot | Encadenar otro SO | Hogar típico | Compromiso |
|---|---|---|---|---|---|---|
| **GRUB2** | `grub.cfg` generado a partir de `/etc/default/grub` + `/etc/grub.d/`, o fragmentos BLS | Enorme (ext*, xfs, btrfs, zfs, LVM, mdraid, LUKS, NFS, iSCSI…) | Sí, vía shim | Sí | RHEL, Fedora, Debian, Ubuntu, SUSE | Potente y programable; superficie de ataque grande, lento, la configuración se genera así que las ediciones a mano se pierden |
| **systemd-boot** (`sd-boot`) | Un `.conf` drop-in por entrada en la ESP, sin generador | **Sólo ESP/FAT** — el kernel y el initramfs deben vivir en la ESP | Sí | Sólo otros binarios EFI | Arch, Pop!\_OS, Flatcar, algunos derivados de CoreOS | Diminuto, rápido, trivialmente auditable; sólo UEFI, sin `/boot` en LVM/LUKS |
| **syslinux / extlinux** | `syslinux.cfg` estático | FAT, ext2/3/4, btrfs (limitado) | Débil | Limitado | PXE, medios de rescate, embebidos | Mínimo y predecible; en la práctica, de la era BIOS |
| **U-Boot** | Variables de entorno + scripts de arranque | Muchos, más protocolos de red | Depende de la placa | n/a | SBC ARM, embebidos, appliances de red | *Es* el firmware en ARM; específico de cada placa, no portable |
| **UKI + sd-stub** | Kernel, initramfs y cmdline en **un único binario PE firmado** | n/a — autocontenido | El más fuerte (toda la cmdline está firmada) | n/a | Flotas inmutables / de computación confidencial | La mejor historia de seguridad y medición con TPM; **hay que reconstruir la imagen para cambiar un argumento del kernel** |

> **Nota del arquitecto.** El compromiso de la UKI (Unified Kernel Image) es el que importa estratégicamente. Como la línea de comandos del kernel está dentro del binario firmado, un atacante con acceso al disco no puede agregar `init=/bin/bash` — pero tampoco puede hacerlo tu ingeniero de guardia a las 03:00. Las flotas que adoptan UKI deben invertir *primero* en recuperación fuera de banda.

### 3.2 GRUB2, los dos modelos de configuración

Ésta es la fuente de confusión más común en el campo, y es materia de examen.

**Modelo A — `grub.cfg` generado clásico** (Debian, Ubuntu, SUSE, RHEL ≤ 8 en algunos esquemas)

```
/etc/default/grub          ← key=value knobs you edit
/etc/grub.d/00_header      ← executable scripts, run in name order
/etc/grub.d/10_linux
/etc/grub.d/30_os-prober
/etc/grub.d/40_custom      ← hand-written entries go here
        │
        │  grub2-mkconfig / update-grub
        ▼
/boot/grub2/grub.cfg       ← GENERATED. NEVER EDIT.
(Debian/Ubuntu: /boot/grub/grub.cfg)
```

**Modelo B — Boot Loader Specification (BLS)** (Fedora, RHEL 8+, CentOS Stream)

```
/etc/default/grub          ← still the source of GRUB_CMDLINE_LINUX
/boot/loader/entries/*.conf ← one small file PER KERNEL, edited by `grubby`
/boot/grub2/grub.cfg       ← a thin stub that just iterates the entries
```

`/etc/default/grub` — la versión completa, orientada a producción:

```bash
# /etc/default/grub — annotated production baseline
# Applied with: grub2-mkconfig -o /boot/grub2/grub.cfg  (BIOS)
#           or: grub2-mkconfig -o /boot/efi/EFI/fedora/grub.cfg  (UEFI, non-BLS)

# Which menu entry is selected by default.
#   a number (0-based), "saved" (use GRUB_SAVEDEFAULT), or an entry title
GRUB_DEFAULT=saved

# Remember the last booted entry. Requires GRUB_DEFAULT=saved.
GRUB_SAVEDEFAULT=true

# Seconds before the default entry boots. 0 = no menu (dangerous on servers:
# you lose the ability to pick an older kernel without a console keypress).
# -1 = wait forever.
GRUB_TIMEOUT=5

# "menu"   -> show the menu for GRUB_TIMEOUT
# "hidden" -> hide it, but honour a keypress (ESC/Shift)
# "countdown" -> show a counter only
GRUB_TIMEOUT_STYLE=menu

# Prefix used to build menu entry titles.
GRUB_DISTRIBUTOR="$(sed 's, release .*$,,g' /etc/system-release)"

# "console" = text on the primary console. "gfxterm" = graphical.
# Servers: keep console. It works over serial and IPMI SOL.
GRUB_TERMINAL_OUTPUT="console"
GRUB_TERMINAL_INPUT="console serial"

# Serial console for out-of-band access. THIS is what saves you at 03:00.
GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"

# Appended to EVERY entry, including the rescue entry.
GRUB_CMDLINE_LINUX="resume=/dev/mapper/vg0-swap rd.lvm.lv=vg0/root rd.lvm.lv=vg0/swap \
console=tty0 console=ttyS0,115200n8 crashkernel=1G-4G:192M,4G-64G:256M,64G-:512M \
systemd.unified_cgroup_hierarchy=1 audit=1"

# Appended only to the DEFAULT (non-recovery) entries.
# Deliberately EMPTY: no "quiet", no "rhgb". On a server you want the boot log.
GRUB_CMDLINE_LINUX_DEFAULT=""

# Do not probe for other operating systems. On a server it is pure risk:
# os-prober can mount foreign filesystems, including guest disks on a hypervisor.
GRUB_DISABLE_OS_PROBER=true

# Keep the recovery/rescue entry. Removing it to "clean up the menu" has ended
# more than one incident badly.
GRUB_DISABLE_RECOVERY=false

# Generate entries only for the running kernel? No — you want fallbacks.
GRUB_DISABLE_SUBMENU=true

# Fedora/RHEL BLS integration. true = use /boot/loader/entries, do not inline
# menu entries into grub.cfg.
GRUB_ENABLE_BLSCFG=true
```

Regenerar — **y las rutas difieren según la distribución y el modo de firmware**:

```console
# Fedora / RHEL / CentOS, BIOS
$ sudo grub2-mkconfig -o /boot/grub2/grub.cfg

# Fedora / RHEL / CentOS, UEFI
$ sudo grub2-mkconfig -o /boot/efi/EFI/fedora/grub.cfg

# Debian / Ubuntu (wrapper handles both cases)
$ sudo update-grub
Sourcing file `/etc/default/grub'
Generating grub configuration file ...
Found linux image: /boot/vmlinuz-6.8.0-45-generic
Found initrd image: /boot/initrd.img-6.8.0-45-generic
Found linux image: /boot/vmlinuz-6.8.0-41-generic
Found initrd image: /boot/initrd.img-6.8.0-41-generic
Warning: os-prober will not be executed to detect other bootable partitions.
done
```

Reinstalar el cargador en sí (después de reemplazar un disco, o después de que Windows pisara el MBR):

```console
# BIOS: write boot.img to the MBR of sda and core.img into the gap
$ sudo grub2-install /dev/sda
Installing for i386-pc platform.
Installation finished. No error reported.

# UEFI: install the EFI binaries and create the NVRAM entry
$ sudo grub2-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=fedora
Installing for x86_64-efi platform.
Installation finished. No error reported.
```

### 3.3 Entradas BLS y `grubby`

```console
$ ls -1 /boot/loader/entries/
9c8f2e1a5b3d4f6789ab0123cdef4567-0-rescue.conf
9c8f2e1a5b3d4f6789ab0123cdef4567-6.10.6-200.fc40.x86_64.conf
9c8f2e1a5b3d4f6789ab0123cdef4567-6.10.3-200.fc40.x86_64.conf

$ cat /boot/loader/entries/9c8f2e1a5b3d4f6789ab0123cdef4567-6.10.6-200.fc40.x86_64.conf
title Fedora Linux (6.10.6-200.fc40.x86_64) 40 (Server Edition)
version 6.10.6-200.fc40.x86_64
linux /vmlinuz-6.10.6-200.fc40.x86_64
initrd /initramfs-6.10.6-200.fc40.x86_64.img
options root=/dev/mapper/vg0-root ro rd.lvm.lv=vg0/root rd.lvm.lv=vg0/swap console=tty0 console=ttyS0,115200n8 crashkernel=1G-4G:192M,4G-64G:256M,64G-:512M
grub_users $grub_users
grub_arg --unrestricted
grub_class fedora
```

Ese archivo *es* la entrada del menú. Seis líneas. Comparalo con el `grub.cfg` generado de 200 líneas al que reemplaza — para esto existe BLS.

```console
$ sudo grubby --info=ALL
index=0
kernel="/boot/vmlinuz-6.10.6-200.fc40.x86_64"
args="ro rd.lvm.lv=vg0/root rd.lvm.lv=vg0/swap console=tty0 console=ttyS0,115200n8 crashkernel=1G-4G:192M,4G-64G:256M,64G-:512M"
root="/dev/mapper/vg0-root"
initrd="/boot/initramfs-6.10.6-200.fc40.x86_64.img"
title="Fedora Linux (6.10.6-200.fc40.x86_64) 40 (Server Edition)"
id="9c8f2e1a5b3d4f6789ab0123cdef4567-6.10.6-200.fc40.x86_64"

$ sudo grubby --default-kernel
/boot/vmlinuz-6.10.6-200.fc40.x86_64

$ sudo grubby --default-index
0
```

**Cambiar argumentos del kernel en todos los kernels instalados — idempotente, programable, sin paso de regeneración:**

```console
$ sudo grubby --update-kernel=ALL --args="transparent_hugepage=never intel_iommu=on iommu=pt"

$ sudo grubby --update-kernel=ALL --remove-args="quiet rhgb"

$ sudo grubby --update-kernel=/boot/vmlinuz-6.10.6-200.fc40.x86_64 --args="systemd.log_level=debug"

$ sudo grubby --set-default=/boot/vmlinuz-6.10.3-200.fc40.x86_64
The default is /boot/loader/entries/9c8f2e1a5b3d4f6789ab0123cdef4567-6.10.3-200.fc40.x86_64.conf with index 1 and kernel /boot/vmlinuz-6.10.3-200.fc40.x86_64
```

> **Patrón de flota.** `grubby --update-kernel=ALL --args=...` se puede ejecutar repetidamente sin riesgo — reemplaza un `key=value` existente en lugar de agregar un duplicado. Eso lo convierte en la primitiva correcta para gestión de configuración. Hacer `sed` sobre `/etc/default/grub` y regenerar no es idempotente y no toca las entradas BLS ya instaladas.

### 3.4 Interactuar con GRUB en el arranque — la habilidad central del examen

En el menú, presioná **`e`** para editar la entrada resaltada, **`c`** para una shell completa de GRUB, **`Esc`** para volver.

Una entrada típica en el editor:

```
        load_video
        set gfxpayload=keep
        insmod gzio
        insmod part_gpt
        insmod ext2
        set root='hd0,gpt2'
        linux ($root)/vmlinuz-6.10.6-200.fc40.x86_64 root=/dev/mapper/vg0-root ro \
              rd.lvm.lv=vg0/root console=ttyS0,115200n8
        initrd ($root)/initramfs-6.10.6-200.fc40.x86_64.img
```

Movete al final de la línea `linux`, agregá tu parámetro y después **`Ctrl-x`** (o **F10**) para arrancar. **La edición es volátil** — se aplica sólo a este arranque. Eso es exactamente lo que querés durante un incidente.

Arrancar **enteramente a mano** desde el prompt `grub>`, que es lo que hacés cuando `grub.cfg` está corrupto o falta:

```
grub> ls
(hd0) (hd0,gpt3) (hd0,gpt2) (hd0,gpt1) (lvm/vg0-root) (lvm/vg0-swap)

grub> ls (hd0,gpt2)/
efi/  grub2/  loader/  vmlinuz-6.10.6-200.fc40.x86_64  initramfs-6.10.6-200.fc40.x86_64.img
System.map-6.10.6-200.fc40.x86_64  config-6.10.6-200.fc40.x86_64

grub> ls (hd0,gpt2)
Partition hd0,gpt2: Filesystem type ext2, UUID 3f9a1c04-77b2-4e18-9c5a-2d6e8b0f1a33 - Partition start at 2048KiB - Total size 1048576KiB

grub> set root=(hd0,gpt2)

grub> linux /vmlinuz-6.10.6-200.fc40.x86_64 root=/dev/mapper/vg0-root ro rd.lvm.lv=vg0/root console=ttyS0,115200n8

grub> initrd /initramfs-6.10.6-200.fc40.x86_64.img

grub> boot
```

Detalles clave con los que la gente tropieza:

- La numeración de discos en GRUB es **base 0** (`hd0`), la de particiones es **base 1** (`gpt1`). `(hd0,gpt2)` = segunda partición del primer disco.
- Si `/boot` es una **partición separada**, las rutas son relativas a ella: `/vmlinuz-…`, no `/boot/vmlinuz-…`. Si `/boot` está en el sistema de archivos raíz, es `/boot/vmlinuz-…`. `ls` te dice cuál es el caso.
- `grub rescue>` es un prompt *más* degradado que `grub>` — significa que `core.img` cargó pero no pudo encontrar `/boot/grub2`. Se recupera con `insmod`:

```
grub rescue> set prefix=(hd0,gpt2)/grub2
grub rescue> set root=(hd0,gpt2)
grub rescue> insmod normal
grub rescue> normal
```

### 3.5 Proteger el menú con contraseña

Cualquiera con acceso a la consola y un menú de GRUB sin protección puede agregar `init=/bin/bash` y obtener una shell de root sin autenticación. En cualquier máquina que no esté físicamente bajo tu control, esto es un hallazgo real.

```console
$ grub2-mkpasswd-pbkdf2
Enter password:
Reenter password:
PBKDF2 hash of your password is grub.pbkdf2.sha512.10000.C4E08A1B7D2F...9E3A.5B7C11D2...F0A8
```

```bash
# /etc/grub.d/01_users  (chmod 755)
#!/bin/sh
cat <<'EOF'
set superusers="bootadmin"
password_pbkdf2 bootadmin grub.pbkdf2.sha512.10000.C4E08A1B7D2F...9E3A.5B7C11D2...F0A8
EOF
```

Con `grub_arg --unrestricted` en una entrada BLS (o `--unrestricted` en un `menuentry`), esa entrada sigue *arrancando* sin contraseña, pero **editarla con `e` exige autenticación**. Ése suele ser el equilibrio correcto: los reinicios desatendidos siguen funcionando, la manipulación interactiva no.

### 3.6 systemd-boot, para contrastar

```console
$ sudo bootctl install
Created "/boot/EFI/systemd".
Copied "/usr/lib/systemd/boot/efi/systemd-bootx64.efi" to "/boot/EFI/systemd/systemd-bootx64.efi".
Created EFI boot entry "Linux Boot Manager".
```

```ini
# /boot/loader/loader.conf
default  fedora-*.conf
timeout  4
console-mode keep
editor   no
```

```ini
# /boot/loader/entries/fedora-6.10.6.conf
title    Fedora Linux
version  6.10.6-200.fc40.x86_64
linux    /vmlinuz-6.10.6-200.fc40.x86_64
initrd   /initramfs-6.10.6-200.fc40.x86_64.img
options  root=UUID=8c1f0e2a-3b7d-4c95-a2e6-90f4d1b78c05 ro quiet
```

`editor no` es el equivalente en systemd-boot de la protección con contraseña de GRUB: deshabilita por completo la edición interactiva de la cmdline.

---

## 4. Etapa 3 — Kernel e initramfs

### 4.1 Qué es realmente `vmlinuz`

`vmlinuz` no es un kernel crudo. Es una **imagen autoextraíble**: una pequeña cabecera de configuración en modo real más una carga comprimida (gzip, LZ4, ZSTD, XZ). El bootloader la carga, salta al código de configuración, que descomprime el kernel real y entra en él. Lo primero que ves es el banner de versión.

```console
$ file /boot/vmlinuz-6.10.6-200.fc40.x86_64
/boot/vmlinuz-6.10.6-200.fc40.x86_64: Linux kernel x86 boot executable bzImage, version 6.10.6-200.fc40.x86_64 (mockbuild@...) #1 SMP PREEMPT_DYNAMIC, RO-rootFS, swap_dev 0x8, Normal VGA

$ sudo dmesg | head -20
[    0.000000] Linux version 6.10.6-200.fc40.x86_64 (mockbuild@d7f2...) (gcc (GCC) 14.2.1, GNU ld 2.41) #1 SMP PREEMPT_DYNAMIC Tue Aug 20 14:02:11 UTC 2026
[    0.000000] Command line: BOOT_IMAGE=(hd0,gpt2)/vmlinuz-6.10.6-200.fc40.x86_64 root=/dev/mapper/vg0-root ro rd.lvm.lv=vg0/root console=tty0 console=ttyS0,115200n8 crashkernel=1G-4G:192M
[    0.000000] BIOS-provided physical RAM map:
[    0.000000] BIOS-e820: [mem 0x0000000000000000-0x000000000009fbff] usable
[    0.000000] BIOS-e820: [mem 0x000000000009fc00-0x000000000009ffff] reserved
[    0.000000] BIOS-e820: [mem 0x00000000000f0000-0x00000000000fffff] reserved
[    0.000000] BIOS-e820: [mem 0x0000000000100000-0x00000000bffdffff] usable
[    0.000000] efi: EFI v2.70 by EDK II
[    0.000000] efi: ACPI=0xbfbfe000 ACPI 2.0=0xbfbfe014 SMBIOS=0xbf9ba000 MEMATTR=0xbe4b7018
[    0.000000] SMBIOS 2.8 present.
[    0.000000] DMI: QEMU Standard PC (Q35 + ICH9, 2009), BIOS 1.16.3-2.fc40 04/01/2014
[    0.001834] Secure boot enabled
[    0.005112] Hypervisor detected: KVM
[    0.010988] KVM setup pv remote TLB flush
[    0.021344] Booting paravirtualized kernel on KVM
[    0.033921] setup_percpu: NR_CPUS:8192 nr_cpumask_bits:4 nr_cpu_ids:4
[    0.098776] Memory: 3902144K/4193848K available (18432K kernel code, 3086K rwdata, 12288K rodata)
[    0.121403] SLUB: HWalign=64, Order=0-3, MinObjects=0, CPUs=4, Nodes=1
[    0.155210] rcu: Hierarchical RCU implementation.
```

La línea 2 de `dmesg` es `/proc/cmdline` antes de que exista `/proc`. Es **lo primero que hay que leer en cualquier incidente de arranque**: prueba qué pasó realmente el bootloader, a diferencia de lo que creés haber configurado.

### 4.2 Por qué existe el initramfs

Un kernel de distribución es **modular** — los drivers de ext4, xfs, LVM, dm-crypt, NVMe y megaraid son archivos `.ko` en el sistema de archivos raíz. Para montar el sistema de archivos raíz necesitás el driver del sistema de archivos raíz. Esa dependencia circular se rompe con el **initramfs**: un archivo cpio que el bootloader carga en RAM junto con el kernel, que el kernel desempaqueta en un tmpfs y usa como raíz temporal.

| | initrd (heredado) | initramfs (actual) |
|---|---|---|
| Formato | **Imagen de sistema de archivos** comprimida (ext2, romfs) | **Archivo cpio** comprimido |
| Se monta como | Un dispositivo de bloques (`/dev/ram0`) vía un driver de ramdisk | Se desempaqueta directamente en `rootfs` (tmpfs) |
| Tamaño fijo | Sí — asignado por adelantado | No — crece/decrece con el contenido |
| Transición a la raíz real | `pivot_root` + desmontaje | `switch_root` — borra el contenido, chroot, exec del nuevo init |
| Duplicación en la caché de páginas | Sí (doble costo de memoria) | No |
| Punto de entrada del kernel | `/linuxrc` | `/init` |

Ambos términos se siguen usando de forma intercambiable en los nombres de archivo (`initrd.img-*` en Debian es un initramfs).

El initramfs es donde vive la parte *difícil* del almacenamiento: ensamblar arreglos mdraid, activar grupos de volúmenes LVM, desbloquear LUKS, autenticarse contra destinos iSCSI, levantar una red para raíz por NFS, y reanudar desde hibernación.

### 4.3 Inspección y reconstrucción

```console
$ lsinitrd /boot/initramfs-6.10.6-200.fc40.x86_64.img | head -30
Image: /boot/initramfs-6.10.6-200.fc40.x86_64.img: 41M
========================================================================
Early CPIO image
========================================================================
drwxr-xr-x   3 root     root            0 Aug 20 14:03 .
-rw-r--r--   1 root     root            2 Aug 20 14:03 early_cpio
drwxr-xr-x   3 root     root            0 Aug 20 14:03 kernel
drwxr-xr-x   2 root     root            0 Aug 20 14:03 kernel/x86
drwxr-xr-x   2 root     root            0 Aug 20 14:03 kernel/x86/microcode
-rw-r--r--   1 root     root       126976 Aug 20 14:03 kernel/x86/microcode/AuthenticAMD.bin
========================================================================
Version: dracut-060-3.fc40

Arguments: -f

dracut modules:
bash systemd systemd-initrd i18n drm prefixdevname kernel-modules kernel-modules-extra
lvm dm rootfs-block terminfo udev-rules dracut-systemd usrmount base fs-lib shutdown
========================================================================
drwxr-xr-x  12 root     root            0 Aug 20 14:03 .
crw-r--r--   1 root     root       5,   1 Aug 20 14:03 dev/console
crw-r--r--   1 root     root       1,  11 Aug 20 14:03 dev/kmsg
crw-r--r--   1 root     root       1,   3 Aug 20 14:03 dev/null
lrwxrwxrwx   1 root     root            7 Aug 20 14:03 bin -> usr/bin
```

Fijate en la **Early CPIO image**: un cpio *sin comprimir* antepuesto al real, que contiene el microcódigo de la CPU. El kernel lo lee antes que cualquier otra cosa para que el microcódigo se aplique lo antes posible.

```console
# Which modules made it in? The single most useful initramfs query.
$ lsinitrd /boot/initramfs-6.10.6-200.fc40.x86_64.img | grep -E '\.ko' | grep -E 'nvme|megaraid|dm-|multipath'
usr/lib/modules/6.10.6-200.fc40.x86_64/kernel/drivers/md/dm-mod.ko.xz
usr/lib/modules/6.10.6-200.fc40.x86_64/kernel/drivers/md/dm-snapshot.ko.xz
usr/lib/modules/6.10.6-200.fc40.x86_64/kernel/drivers/nvme/host/nvme.ko.xz
usr/lib/modules/6.10.6-200.fc40.x86_64/kernel/drivers/nvme/host/nvme-core.ko.xz

# Extract a single file to stdout — verify what fstab the initramfs will see
$ lsinitrd -f /etc/fstab /boot/initramfs-6.10.6-200.fc40.x86_64.img

# Fully unpack for forensics
$ mkdir /tmp/initrd && cd /tmp/initrd
$ sudo lsinitrd --unpack /boot/initramfs-6.10.6-200.fc40.x86_64.img
$ ls
bin  dev  etc  init  lib  lib64  proc  root  run  sbin  shutdown  sys  sysroot  tmp  usr  var
$ readlink init
usr/lib/systemd/systemd
```

En dracut moderno, `/init` es **systemd mismo**, corriendo en el initramfs con un conjunto de unidades distinto (`initrd.target`). Por eso `journalctl -b` muestra unidades de systemd anteriores a `switch_root`.

**Reconstruir — el comando del que todo SRE necesita tener memoria muscular:**

```console
# Rebuild for the running kernel, overwrite
$ sudo dracut --force

# Rebuild for a specific kernel
$ sudo dracut --force /boot/initramfs-6.10.3-200.fc40.x86_64.img 6.10.3-200.fc40.x86_64

# Rebuild EVERY installed kernel — do this after a storage-stack change
$ sudo dracut --force --regenerate-all
dracut[I]: *** Creating initramfs image file '/boot/initramfs-6.10.6-200.fc40.x86_64.img' done ***
dracut[I]: *** Creating initramfs image file '/boot/initramfs-6.10.3-200.fc40.x86_64.img' done ***

# Force-include a driver the auto-detection missed
$ sudo dracut --force --add-drivers "megaraid_sas nvme-tcp" --regenerate-all

# Host-only (small, fast, fragile) vs generic (large, portable)
$ sudo dracut --force --no-hostonly      # generic: survives hardware/disk changes
$ sudo dracut --force --hostonly         # only this machine's drivers
```

```bash
# /etc/dracut.conf.d/50-platform.conf — persistent, config-managed
# Generic image: this fleet clones disks between hardware generations,
# so host-only would produce an image that fails on the next SKU.
hostonly="no"

# Storage stack we require in early boot
add_dracutmodules+=" lvm dm multipath nvmf "
add_drivers+=" nvme nvme-tcp nvme-fabrics megaraid_sas dm-multipath "

# ZSTD: ~2x faster decompression than XZ at similar size. Boot-time win.
compress="zstd"

# Serial console must work from the initramfs, not just from systemd
kernel_cmdline+=" console=ttyS0,115200n8 "

# Never silently omit these
omit_dracutmodules+=" plymouth "
```

Equivalente en Debian/Ubuntu:

```console
$ sudo update-initramfs -u -k all
update-initramfs: Generating /boot/initrd.img-6.8.0-45-generic
update-initramfs: Generating /boot/initrd.img-6.8.0-41-generic

$ sudo update-initramfs -c -k 6.8.0-45-generic   # create (new kernel)
$ lsinitramfs /boot/initrd.img-6.8.0-45-generic | grep nvme
```

```
# /etc/initramfs-tools/initramfs.conf
MODULES=most          # "most" = generic; "dep" = host-only equivalent
BUSYBOX=auto
COMPRESS=zstd
DEVICE=
NFSROOT=auto
RUNSIZE=10%
```

```
# /etc/initramfs-tools/modules — one module name per line, force-included
nvme
nvme_tcp
megaraid_sas
dm_multipath
```

### 4.4 La línea de comandos del kernel — referencia de producción

```console
$ cat /proc/cmdline
BOOT_IMAGE=(hd0,gpt2)/vmlinuz-6.10.6-200.fc40.x86_64 root=/dev/mapper/vg0-root ro rd.lvm.lv=vg0/root console=tty0 console=ttyS0,115200n8 crashkernel=1G-4G:192M
```

**Raíz y arranque temprano**

| Parámetro | Significado | Nota de producción |
|---|---|---|
| `root=UUID=<uuid>` | Dispositivo raíz por UUID del sistema de archivos | **La única forma que deberías distribuir.** Sobrevive al renombrado de dispositivos |
| `root=/dev/mapper/vg-lv` | Raíz sobre LVM | Requiere un `rd.lvm.lv=` acorde |
| `root=LABEL=<label>` | Raíz por etiqueta del sistema de archivos | Las etiquetas colisionan; los UUID no |
| `ro` / `rw` | Montar la raíz inicialmente en sólo lectura/lectura-escritura | `ro` es lo correcto: `fsck` lo necesita, systemd remonta en `rw` |
| `rootflags=<opts>` | Opciones de montaje para la raíz | p. ej. `rootflags=subvol=@` para btrfs |
| `rootfstype=ext4` | Saltear el sondeo del sistema de archivos | Ganancia marginal de velocidad; una trampa si convertís el fs |
| `rd.lvm.lv=vg/lv` | Activar sólo este LV en el initramfs | Más rápido que escanear todos los VG; **debe listar raíz y swap** |
| `rd.luks.uuid=<uuid>` | Desbloquear este dispositivo LUKS temprano | Combinalo con `rd.luks.key=` o un vínculo TPM/clevis |
| `rd.md.uuid=<uuid>` | Ensamblar este arreglo mdraid temprano | |
| `rd.driver.pre=<mod>` | Cargar el módulo antes que nada | La solución para "controladora de disco no detectada" |
| `rd.driver.blacklist=<mod>` | Nunca cargar este módulo en el initramfs | Para un driver que cuelga el arranque |
| `resume=<dev>` / `noresume` | Dispositivo con la imagen de hibernación / omitirla | `noresume` arregla los bloqueos de "waiting for resume device" |

**Selección de init y modos degradados**

| Parámetro | Efecto |
|---|---|
| `init=/bin/bash` | El kernel ejecuta bash como PID 1. **Sin systemd, sin montajes, sin red.** El camino universal para resetear la contraseña |
| `systemd.unit=rescue.target` | Similar a monousuario: sistema de archivos raíz montado, servicios mínimos, hace falta la contraseña de root |
| `systemd.unit=emergency.target` | Raíz montada en **sólo lectura**, esencialmente nada más iniciado |
| `systemd.unit=multi-user.target` | Forzar un arranque sólo de texto aunque el valor por defecto sea gráfico |
| `1`, `s`, `single` | Compatibilidad con SysV — systemd los mapea a `rescue.target` |
| `3`, `5` | Mapeados a `multi-user.target` / `graphical.target` |
| `emergency` | Abreviatura de `systemd.unit=emergency.target` |
| `rd.break[=stage]` | Caer a una shell **dentro del initramfs**. Etapas: `cmdline`, `pre-udev`, `pre-trigger`, `initqueue`, `pre-mount`, `mount`, `pre-pivot`, `cleanup` |
| `rd.shell` | Dar una shell si el initramfs falla, en vez de reiniciar |
| `rd.debug` | Traza verbosa `set -x` de los scripts de dracut |

**Observabilidad**

| Parámetro | Efecto |
|---|---|
| `console=ttyS0,115200n8` | Consola serie. **Se puede repetir**; la *última* obtiene `/dev/console` |
| `console=tty0` | Consola de video |
| `quiet` | Suprime la mayoría de los mensajes del kernel. Quitalo en servidores |
| `loglevel=7` | Mostrar todo hasta debug inclusive |
| `ignore_loglevel` | Imprimir todos los mensajes sin importar el nivel |
| `earlyprintk=serial,ttyS0,115200` | Salida *antes* de que se inicialice el driver de consola real — para pánicos en el segundo 0 |
| `systemd.log_level=debug` | Traza completa de systemd |
| `systemd.log_target=console` | Enviar el log propio de systemd a la consola, no al journal |
| `systemd.show_status=1` | Líneas `[ OK ]` por unidad |
| `printk.devkmsg=on` | Permitir escrituras desde espacio de usuario a `/dev/kmsg` |
| `panic=30` | Reiniciar 30 s después de un pánico en vez de colgarse para siempre. **Configuralo en una flota** |
| `oops=panic` | Convertir cualquier oops en un pánico — para que kdump lo capture |
| `crashkernel=1G-4G:192M,4G-:256M` | Reservar memoria para el kernel de captura de kdump |

**Hardware y comportamiento**

| Parámetro | Efecto |
|---|---|
| `nomodeset` | Deshabilitar el kernel mode setting — la solución clásica de "pantalla negra después de instalar" |
| `net.ifnames=0 biosdevname=0` | Volver a nombres estilo `eth0`. **Cambia el nombre de todas las interfaces — va a romper tu configuración de red** |
| `selinux=0` | Deshabilitar SELinux por completo (requiere reetiquetar después) |
| `enforcing=0` | SELinux en permisivo para este arranque. Preferilo antes que `selinux=0` |
| `intel_iommu=on iommu=pt` | Habilitar IOMMU con passthrough — requerido para VFIO/SR-IOV |
| `mitigations=off` | Deshabilita todas las mitigaciones de ejecución especulativa de la CPU. Ganancia real de rendimiento, regresión real de seguridad — una decisión para una revisión de seguridad, no para un ingeniero |
| `transparent_hugepage=never` | Frecuentemente requerido por bases de datos (MongoDB, Redis, Oracle) |
| `isolcpus=2-7 nohz_full=2-7 rcu_nocbs=2-7` | Aislamiento de CPU para cargas de baja latencia / DPDK |
| `systemd.unified_cgroup_hierarchy=1` | Sólo cgroup v2 — requerido por los runtimes de contenedores modernos |

> **Regla para la flota:** tratá `/proc/cmdline` como **configuración declarada** y alertá ante desviaciones. Un nodo cuya cmdline diverge de la plantilla de su clase es un nodo cuyo comportamiento de arranque no podés predecir. Exportala como métrica de Prometheus vía el colector textfile de node_exporter y comparala con la plantilla.

---

## 5. Etapa 4 — init: SysVinit, Upstart, systemd

### 5.1 Tabla comparativa

| Dimensión | SysVinit | Upstart | systemd |
|---|---|---|---|
| Época / origen | 1983, AT&T System V | 2006, Canonical | 2010, Red Hat |
| Modelo | **Secuencial**, ordenado por el prefijo numérico del enlace simbólico | **Dirigido por eventos** (`started`, `stopped`, `net-device-up`) | **Grafo de dependencias**, resuelto y paralelizado |
| Configuración de PID 1 | `/etc/inittab` | `/etc/init/*.conf` | `/etc/systemd/system/*`, `/usr/lib/systemd/system/*` |
| Definición de servicio | Script de shell con cabecera LSB en `/etc/init.d/` | Archivo de job `.conf` semi-declarativo | Unidad `.service` declarativa |
| Abstracción de estado | **Runlevel** (0–6, S) | Compatible con runlevels vía eventos | **Target** (una unidad que agrupa otras unidades) |
| Paralelismo | Ninguno (limitado a trucos con `&`) | Parcial, dirigido por eventos | Total, vía activación por socket/D-Bus/path/timer |
| Supervisión de servicios | Ninguna — un demonio caído queda muerto | Sí (`respawn`) | Sí (`Restart=`), más limitación de frecuencia |
| Seguimiento de procesos | Archivos PID — **poco confiables**, los doble-fork se escapan | Adivinanza de PID (`expect fork`/`daemon`) | **cgroups** — un proceso no puede escapar de su unidad |
| Control de recursos | `ulimit` en el script | Cláusula `limit` | cgroup v2 completo: `MemoryMax=`, `CPUQuota=`, `IOWeight=` |
| Registro | Lo que el script redirija | `/var/log/upstart/*.log` | `journald`, estructurado e indexado |
| Datos de tiempos de arranque | Ninguno | Ninguno | `systemd-analyze blame` / `critical-chain` / `plot` |
| Sandboxing | Ninguno | Ninguno | `PrivateTmp=`, `ProtectSystem=`, `NoNewPrivileges=`, seccomp |
| Arranque bajo demanda | `inetd`/`xinetd`, demonio aparte | Limitado | Activación por socket, path, dispositivo, timer, D-Bus |
| Tiempo de arranque (servidor típico) | 60–120 s | 40–80 s | 5–25 s |
| Complejidad / superficie de ataque | Mínima | Moderada | Grande — PID 1 hace muchísimo |
| Depurabilidad | Leer el script de shell | Leer el archivo de job | Leer unidades + `systemctl`; opaco sin las herramientas |
| Estado **hoy** | Devuan, Slackware, Alpine (cercano a OpenRC), contenedores | **Obsoleto en todas partes** | Por omisión en RHEL 7+, Debian 8+, Ubuntu 15.04+, SUSE 12+, Arch, Fedora |
| **Expectativa del examen** | **Comprender** | **Conocer su existencia** | **Comprender** |

### 5.2 SysVinit con la profundidad que pide el examen

`/etc/inittab` — toda la configuración de PID 1, una línea por entrada, separada por dos puntos:

```
# /etc/inittab — classic SysVinit
# Format: id:runlevels:action:process

# Default runlevel. 3 = multi-user + networking, no X. 5 = with a display manager.
# NEVER set this to 0 (halt) or 6 (reboot): the machine loops forever.
id:3:initdefault:

# System initialisation, run once before anything else.
si::sysinit:/etc/rc.d/rc.sysinit

# One line per runlevel: run the rc script with the runlevel as argument.
l0:0:wait:/etc/rc.d/rc 0
l1:1:wait:/etc/rc.d/rc 1
l2:2:wait:/etc/rc.d/rc 2
l3:3:wait:/etc/rc.d/rc 3
l4:4:wait:/etc/rc.d/rc 4
l5:5:wait:/etc/rc.d/rc 5
l6:6:wait:/etc/rc.d/rc 6

# Trap Ctrl-Alt-Del. On a server, replace with a logger call: an accidental
# three-finger salute on a KVM should not reboot a production host.
ca::ctrlaltdel:/sbin/shutdown -t3 -r now

# UPS integration
pf::powerfail:/sbin/shutdown -f -h +2 "Power Failure; System Shutting Down"
pr:12345:powerokwait:/sbin/shutdown -c "Power Restored; Shutdown Cancelled"

# Six virtual consoles in runlevels 2-5. "respawn" = restart when it exits.
1:2345:respawn:/sbin/mingetty tty1
2:2345:respawn:/sbin/mingetty tty2
3:2345:respawn:/sbin/mingetty tty3
4:2345:respawn:/sbin/mingetty tty4
5:2345:respawn:/sbin/mingetty tty5
6:2345:respawn:/sbin/mingetty tty6

# Serial console — out-of-band access
s0:2345:respawn:/sbin/agetty -h -L 115200 ttyS0 vt100

# Display manager in runlevel 5 only
x:5:respawn:/etc/X11/prefdm -nodaemon
```

Los valores del campo `action` que vale la pena conocer: `initdefault`, `sysinit`, `wait`, `once`, `respawn`, `boot`, `bootwait`, `ctrlaltdel`, `powerfail`, `powerokwait`, `off`.

**Runlevels** — atención a las dos convenciones en conflicto, que es exactamente el tipo de detalle que LPI pregunta:

| Runlevel | Red Hat / Fedora / SUSE | Debian / Ubuntu (pre-systemd) |
|---|---|---|
| 0 | Halt | Halt |
| 1 / S / s | Monousuario | Monousuario |
| 2 | Multiusuario, sin NFS | **Multiusuario completo con GUI (por omisión)** |
| 3 | Multiusuario completo, texto | Igual que 2 (definido por el sitio) |
| 4 | Sin usar / definido por el sitio | Igual que 2 |
| 5 | Multiusuario + X11 (GUI) | Igual que 2 |
| 6 | Reboot | Reboot |

La estructura de directorios rc:

```console
$ ls -l /etc/rc.d/rc3.d/ | head
lrwxrwxrwx 1 root root 17 K01certmonger -> ../init.d/certmonger
lrwxrwxrwx 1 root root 16 K05wdaemon -> ../init.d/wdaemon
lrwxrwxrwx 1 root root 19 K10psacct -> ../init.d/psacct
lrwxrwxrwx 1 root root 15 S10network -> ../init.d/network
lrwxrwxrwx 1 root root 16 S12rsyslog -> ../init.d/rsyslog
lrwxrwxrwx 1 root root 16 S55sshd -> ../init.d/sshd
lrwxrwxrwx 1 root root 15 S80postfix -> ../init.d/postfix
lrwxrwxrwx 1 root root 14 S90crond -> ../init.d/crond
```

`/etc/rc.d/rc N` recorre el directorio en **orden lexicográfico**: primero cada script `K*` con `stop`, luego cada script `S*` con `start`. El número de dos dígitos *es* todo el sistema de dependencias — `S10network` antes que `S55sshd` porque 10 ordena antes que 55. No hay expresión de "sshd requiere la red"; sólo hay un número que eligió una persona.

**Ésa es la limitación arquitectónica.** El orden es implícito, global y no verificable. Agregás un servicio y tenés que adivinar un número que no colisione y que no invierta un orden que nadie documentó.

Las cabeceras LSB fueron el intento de arreglarlo:

```bash
#!/bin/bash
#
# myapp   Start/stop the myapp daemon
#
### BEGIN INIT INFO
# Provides:          myapp
# Required-Start:    $network $remote_fs $syslog
# Required-Stop:     $network $remote_fs $syslog
# Should-Start:      postgresql
# Should-Stop:       postgresql
# Default-Start:     3 4 5
# Default-Stop:      0 1 2 6
# Short-Description: myapp application server
# Description:       Starts the myapp application server, which serves the
#                    internal ordering API on port 8080.
### END INIT INFO

. /etc/rc.d/init.d/functions

prog="myapp"
exec="/usr/local/bin/myapp"
pidfile="/var/run/${prog}.pid"
lockfile="/var/lock/subsys/${prog}"
[ -e /etc/sysconfig/$prog ] && . /etc/sysconfig/$prog

start() {
    [ -x $exec ] || exit 5
    echo -n $"Starting $prog: "
    daemon --pidfile=$pidfile "$exec --daemon --pidfile=$pidfile $MYAPP_OPTS"
    retval=$?
    echo
    [ $retval -eq 0 ] && touch $lockfile
    return $retval
}

stop() {
    echo -n $"Stopping $prog: "
    killproc -p $pidfile $prog
    retval=$?
    echo
    [ $retval -eq 0 ] && rm -f $lockfile
    return $retval
}

restart()  { stop; start; }
reload()   { echo -n $"Reloading $prog: "; killproc -p $pidfile $prog -HUP; echo; }
rh_status() { status -p $pidfile $prog; }
rh_status_q() { rh_status >/dev/null 2>&1; }

case "$1" in
    start)   rh_status_q && exit 0; start ;;
    stop)    rh_status_q || exit 0; stop ;;
    restart) restart ;;
    reload)  rh_status_q || exit 7; reload ;;
    status)  rh_status ;;
    condrestart|try-restart) rh_status_q || exit 0; restart ;;
    *)
        echo $"Usage: $0 {start|stop|status|restart|condrestart|try-restart|reload}"
        exit 2
esac
exit $?
```

Comandos clásicos de SysVinit:

```console
$ runlevel
N 3
```

`N` significa "sin runlevel previo" (arrancó directamente en 3). Después de un cambio muestra el anterior:

```console
$ sudo telinit 5
$ runlevel
3 5

$ sudo init 6        # reboot
$ sudo telinit q     # re-read /etc/inittab without changing runlevel

$ sudo service sshd status
openssh-daemon (pid  1247) is running...

$ sudo chkconfig --list sshd
sshd            0:off   1:off   2:on    3:on    4:on    5:on    6:off

$ sudo chkconfig --level 345 myapp on
$ sudo chkconfig --add myapp        # reads the LSB header, creates the symlinks

# Debian equivalent
$ sudo update-rc.d myapp defaults
$ sudo update-rc.d myapp disable
```

### 5.3 Upstart — nivel de conocimiento básico

Upstart reemplazó los runlevels secuenciales por **eventos**. Un job declara a qué reacciona; Upstart no mantiene ningún orden global.

```
# /etc/init/myapp.conf
description "myapp application server"
author      "platform-team@example.com"

# Start when the filesystem is ready AND we are in a multi-user runlevel
start on (local-filesystems and net-device-up IFACE!=lo and runlevel [2345])
stop  on runlevel [016]

# Upstart's PID-tracking heuristic. Getting this wrong is the classic Upstart bug:
# it tracks the wrong PID and "stop" kills nothing.
expect fork

respawn
respawn limit 10 5          # 10 restarts in 5 seconds, then give up

console log
env MYAPP_ENV=production

pre-start script
    mkdir -p /var/run/myapp
    chown myapp:myapp /var/run/myapp
end script

exec /usr/local/bin/myapp --daemon

post-stop script
    rm -f /var/run/myapp/myapp.pid
end script
```

```console
$ initctl list | head -5
mountall-net stop/waiting
rsyslog start/running, process 682
tty4 start/running, process 1147
udev start/running, process 405
myapp start/running, process 2891

$ sudo initctl start myapp
myapp start/running, process 2891

$ sudo initctl status myapp
myapp start/running, process 2891

$ sudo initctl emit some-custom-event
```

**Por qué perdió:** `expect fork` / `expect daemon` es una *adivinanza* sobre cuántas veces se bifurca un demonio. Si adivinás mal, Upstart sigue un PID que ya terminó — el job parece corriendo cuando está muerto, o `stop` se cuelga. systemd resolvió el mismo problema de manera definitiva poniendo el servicio en un cgroup, donde la identidad del proceso no es una adivinanza. Se distribuyó en Ubuntu 6.10–14.10 y RHEL 6; reemplazado por systemd en Ubuntu 15.04 y RHEL 7. Sabé qué es; no te van a pedir que lo configures.

### 5.4 systemd

**Tipos de unidad** — el vocabulario:

| Sufijo | Propósito |
|---|---|
| `.service` | Un proceso o conjunto de procesos |
| `.target` | Un punto de sincronización que agrupa otras unidades — el reemplazo del runlevel |
| `.socket` | Un socket; activa su `.service` en la primera conexión |
| `.mount` | Un punto de montaje; **autogenerado desde `/etc/fstab`** |
| `.automount` | Montaje bajo demanda |
| `.swap` | Un dispositivo o archivo de swap |
| `.device` | Un dispositivo de udev expuesto como unidad |
| `.path` | Disparador por cambios en el sistema de archivos |
| `.timer` | Disparador basado en tiempo (reemplazo de cron) |
| `.slice` | Un nodo de cgroup para gestión de recursos |
| `.scope` | Procesos creados externamente, agrupados en un cgroup |

**Ruta de búsqueda de unidades, en prioridad ascendente** — el segundo dato más importante de systemd después de los cgroups:

| Ruta | Dueño | Propósito |
|---|---|---|
| `/usr/lib/systemd/system/` | El gestor de paquetes | Unidades del proveedor. **Nunca editar** — una actualización te las pisa |
| `/run/systemd/system/` | Tiempo de ejecución | Volátil, desaparece al reiniciar |
| `/etc/systemd/system/` | **Vos** | Sobrescrituras locales y unidades propias. Gana |

Sobrescribir sin editar el archivo del proveedor:

```console
$ sudo systemctl edit nginx.service
```

que crea `/etc/systemd/system/nginx.service.d/override.conf` — fusionado por encima de la unidad del proveedor. `systemctl edit --full nginx.service` copia la unidad entera a `/etc/` en su lugar. `systemctl revert nginx.service` borra las sobrescrituras.

**Mapeo runlevel ↔ target** — memorizá esta tabla:

| Runlevel SysV | Target de systemd | Enlace simbólico |
|---|---|---|
| 0 | `poweroff.target` | `runlevel0.target` |
| 1, s, single | `rescue.target` | `runlevel1.target` |
| 2 | `multi-user.target` | `runlevel2.target` |
| 3 | `multi-user.target` | `runlevel3.target` |
| 4 | `multi-user.target` | `runlevel4.target` |
| 5 | `graphical.target` | `runlevel5.target` |
| 6 | `reboot.target` | `runlevel6.target` |
| — | `emergency.target` | (sin equivalente de runlevel) |

```console
$ ls -l /usr/lib/systemd/system/runlevel*.target
lrwxrwxrwx 1 root root 15 runlevel0.target -> poweroff.target
lrwxrwxrwx 1 root root 13 runlevel1.target -> rescue.target
lrwxrwxrwx 1 root root 17 runlevel2.target -> multi-user.target
lrwxrwxrwx 1 root root 17 runlevel3.target -> multi-user.target
lrwxrwxrwx 1 root root 17 runlevel4.target -> multi-user.target
lrwxrwxrwx 1 root root 16 runlevel5.target -> graphical.target
lrwxrwxrwx 1 root root 13 runlevel6.target -> reboot.target
```

```console
$ systemctl get-default
multi-user.target

$ sudo systemctl set-default graphical.target
Removed /etc/systemd/system/default.target.
Created symlink /etc/systemd/system/default.target → /usr/lib/systemd/system/graphical.target.

$ sudo systemctl isolate multi-user.target     # ≈ telinit 3
$ sudo systemctl rescue                        # ≈ telinit 1
$ sudo systemctl emergency
$ sudo systemctl reboot
$ sudo systemctl poweroff
$ sudo systemctl kexec                         # reboot without firmware re-init
```

La cadena de targets del arranque:

```
                              default.target  (symlink)
                                     │
                              graphical.target
                                     │  Requires=
                             multi-user.target
                                     │  Requires=
                               basic.target
                            ┌────────┼────────┐
                    sysinit.target  sockets.target  paths.target  slices.target
                            │
          ┌─────────────────┼─────────────────┐
   local-fs.target    swap.target      cryptsetup.target
          │
   local-fs-pre.target
          │
   (systemd-fstab-generator output: *.mount units)
```

Una unidad de servicio completa, de calidad productiva:

```ini
# /etc/systemd/system/myapp.service
[Unit]
Description=myapp application server
Documentation=https://example.internal/runbooks/myapp

# Ordering: "After" is ONLY ordering. It does NOT pull the unit in.
After=network-online.target postgresql.service
# "Wants" pulls it in but tolerates failure. "Requires" fails us if it fails.
Wants=network-online.target
Requires=postgresql.service

# If postgresql is stopped or restarted, restart us too.
PartOf=postgresql.service

# Do not enter a restart storm during a dependency outage.
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=notify
NotifyAccess=main

User=myapp
Group=myapp
WorkingDirectory=/var/lib/myapp

EnvironmentFile=-/etc/sysconfig/myapp
Environment=MYAPP_ENV=production

ExecStartPre=/usr/local/bin/myapp migrate --check
ExecStart=/usr/local/bin/myapp serve --config /etc/myapp/config.yaml
ExecReload=/bin/kill -HUP $MAINPID

Restart=on-failure
RestartSec=5s
TimeoutStartSec=90s
TimeoutStopSec=30s
KillMode=mixed
KillSignal=SIGTERM

# Resource control — enforced by cgroup v2, not advisory
MemoryMax=2G
MemoryHigh=1500M
CPUQuota=200%
TasksMax=512
IOWeight=100

# Sandboxing. Each line removes a capability the service does not need.
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
ReadWritePaths=/var/lib/myapp /var/log/myapp
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictNamespaces=true
LockPersonality=true
MemoryDenyWriteExecute=true
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM
CapabilityBoundingSet=

StandardOutput=journal
StandardError=journal
SyslogIdentifier=myapp

[Install]
WantedBy=multi-user.target
```

```console
$ sudo systemd-analyze verify /etc/systemd/system/myapp.service
$ sudo systemctl daemon-reload
$ sudo systemctl enable --now myapp.service
Created symlink /etc/systemd/system/multi-user.target.wants/myapp.service → /etc/systemd/system/myapp.service.
```

Ese enlace simbólico **es** lo que significa `enable`: `WantedBy=multi-user.target` provoca un enlace dentro de `multi-user.target.wants/`. Es el descendiente directo de `S55sshd`, con el orden hecho explícito en vez de numérico.

Un target propio — el equivalente moderno de "el runlevel 4 es nuestro":

```ini
# /etc/systemd/system/platform-node.target
[Unit]
Description=Platform node fully in service
Documentation=https://example.internal/runbooks/node-lifecycle
Requires=multi-user.target
After=multi-user.target
AllowIsolate=yes
```

```ini
# /etc/systemd/system/node-ready.service — gate that fires only when the node
# is genuinely serving traffic, so the health checker has a single unit to watch.
[Unit]
Description=Mark node ready for traffic
After=kubelet.service containerd.service
Requires=kubelet.service containerd.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/node-ready --register
ExecStop=/usr/local/bin/node-ready --drain
TimeoutStartSec=300

[Install]
WantedBy=platform-node.target
```

---

## 6. Verificación y diagnóstico de fallas

### 6.1 `dmesg` — el búfer circular del kernel

```console
$ sudo dmesg --level=err,crit,alert,emerg
[    3.821004] EXT4-fs (sda2): mounted filesystem with ordered data mode. Quota mode: none.
[   12.443219] i40e 0000:3b:00.1: Error I40E_AQ_RC_EINVAL adding RX filters
[   14.902117] mpt3sas_cm0: log_info(0x31120303): originator(PL), code(0x12), sub_code(0x0303)

$ sudo dmesg -T | tail -5
[Mon Aug 25 09:14:02 2026] nvme nvme0: I/O 452 QID 3 timeout, aborting
[Mon Aug 25 09:14:02 2026] nvme nvme0: Abort status: 0x0
[Mon Aug 25 09:14:32 2026] nvme nvme0: I/O 452 QID 3 timeout, reset controller
[Mon Aug 25 09:14:33 2026] nvme nvme0: 32/0/0 default/read/poll queues
[Mon Aug 25 09:14:33 2026] EXT4-fs warning (device nvme0n1p2): ext4_end_bio:343: I/O error 10 writing to inode 262148

$ sudo dmesg -w                 # follow, like tail -f
$ sudo dmesg -H                 # human-readable pager, colour, relative times
$ sudo dmesg --facility=kern --level=warn
$ sudo dmesg -c                 # print AND CLEAR the buffer — destructive
```

Dos restricciones que importan:

- El búfer circular es **finito** (`CONFIG_LOG_BUF_SHIFT`, redimensionable con `log_buf_len=8M`). En una máquina ruidosa, los mensajes tempranos del arranque quedan **sobrescritos en minutos**. Si necesitás mensajes del kernel del arranque horas después, necesitás el journal, no `dmesg`.
- Desde el kernel 4.10, `dmesg` requiere root salvo que `kernel.dmesg_restrict=0`.

```console
$ sysctl kernel.dmesg_restrict
kernel.dmesg_restrict = 1

$ cat /proc/sys/kernel/printk
7	4	1	7
#  ^   ^   ^   ^
#  |   |   |   default console loglevel for new consoles
#  |   |   minimum console loglevel
#  |   default message loglevel (for printk without a level)
#  current console loglevel — messages below this number are shown
```

### 6.2 `journalctl` — el registro de arranque autoritativo

**La persistencia es lo primero que hay que verificar.** Por omisión, en muchos sistemas el journal está en `/run/log/journal`, que es un tmpfs — *no sobrevive al reinicio que querés investigar*.

```console
$ journalctl --list-boots
IDX BOOT ID                          FIRST ENTRY                 LAST ENTRY
 -3 4f2a91c7d8b34e0e9a15b6c2d7e3f804 Fri 2026-08-22 08:12:44 -03 Fri 2026-08-22 19:03:11 -03
 -2 a71b3e05c9f24d6b8e0a2c4f6d81b593 Sat 2026-08-23 09:01:02 -03 Sun 2026-08-24 22:40:57 -03
 -1 c05d8f1a2b674e39a8c1d0e5f7b32a46 Mon 2026-08-25 07:55:19 -03 Mon 2026-08-25 09:12:03 -03
  0 e93c4a2b1d5f48079b6e2a8c0d13f57e Mon 2026-08-25 09:14:41 -03 Mon 2026-08-25 11:38:20 -03
```

Si ese comando muestra solamente el índice `0`, el journal es volátil. Arreglalo — es un cambio de una línea que se paga solo la primera vez que un nodo reinicia inesperadamente:

```bash
# /etc/systemd/journald.conf.d/50-persistent.conf
[Journal]
Storage=persistent
Compress=yes
Seal=yes                    # FSS cryptographic sealing (needs journalctl --setup-keys)
SystemMaxUse=2G
SystemKeepFree=1G
SystemMaxFileSize=128M
MaxRetentionSec=1month
MaxFileSec=1day
RateLimitIntervalSec=30s
RateLimitBurst=10000
ForwardToSyslog=no
```

```console
$ sudo mkdir -p /var/log/journal
$ sudo systemd-tmpfiles --create --prefix /var/log/journal
$ sudo systemctl restart systemd-journald
$ journalctl --disk-usage
Archived and active journals take up 1.4G in the file system.
```

**Las consultas que realmente usás:**

```console
$ journalctl -b                       # this boot
$ journalctl -b -1                    # the PREVIOUS boot — for post-mortem
$ journalctl -b c05d8f1a2b674e39a8c1d0e5f7b32a46
$ journalctl -b -1 -p err             # errors only, previous boot
$ journalctl -k -b -1                 # kernel messages only, previous boot
$ journalctl -u kubelet -b --no-pager
$ journalctl -u myapp.service -f      # follow
$ journalctl --since "2026-08-25 09:00" --until "2026-08-25 09:30"
$ journalctl --since "-15min"
$ journalctl -o json-pretty -n 1
$ journalctl _PID=1 -b                # everything PID 1 logged
$ journalctl _TRANSPORT=kernel -b
$ journalctl -b _SYSTEMD_UNIT=sshd.service + _COMM=sshd
$ journalctl -b -g 'timeout|failed to mount'   # grep, PCRE
```

Niveles de prioridad, `-p`: `0 emerg`, `1 alert`, `2 crit`, `3 err`, `4 warning`, `5 notice`, `6 info`, `7 debug`. `-p err` significa "err **y más severos**".

```console
$ journalctl -b -p err --no-pager
Aug 25 09:14:52 node07 kernel: nvme nvme0: I/O 452 QID 3 timeout, reset controller
Aug 25 09:15:03 node07 systemd[1]: Failed to mount /srv/data.
Aug 25 09:15:03 node07 systemd[1]: Dependency failed for Local File Systems.
Aug 25 09:15:03 node07 systemd[1]: Dependency failed for Mark node ready for traffic.
```

Leé esa pila de abajo hacia arriba: una falla de montaje se propagó a `local-fs.target`, del que todo lo demás depende. **En systemd, buscá siempre la *primera* falla — el resto es consecuencia de dependencias.**

Los archivos previos a systemd siguen existiendo en muchos sistemas y son materia de examen:

| Archivo | Contenido |
|---|---|
| `/var/log/dmesg` | Una instantánea del búfer circular tomada una vez en el arranque (`rsyslog`/`bootlogd`) |
| `/var/log/boot.log` | La salida de consola `[ OK ]`/`[FAILED]` del arranque |
| `/var/log/messages` | Syslog general de Red Hat |
| `/var/log/syslog` | Syslog general de Debian |

### 6.3 Análisis del arranque con systemd

```console
$ systemd-analyze
Startup finished in 3.221s (firmware) + 2.104s (loader) + 1.842s (kernel) + 4.117s (initrd) + 12.398s (userspace) = 23.683s
multi-user.target reached after 12.301s in userspace.
```

Esa única línea **localiza el problema en un traspaso**. 3,2 s de firmware es una configuración de la BIOS; 4,1 s de initrd es un problema de almacenamiento/udev; 12,4 s de espacio de usuario es un servicio.

```console
$ systemd-analyze blame | head -12
         6.482s kdump.service
         4.117s NetworkManager-wait-online.service
         2.109s dracut-initqueue.service
         1.884s systemd-udev-settle.service
         1.203s containerd.service
          981ms lvm2-monitor.service
          702ms sssd.service
          611ms firewalld.service
          448ms systemd-logind.service
          312ms auditd.service
          204ms polkit.service
          188ms chronyd.service
```

**`blame` por sí solo es engañoso** — ordena por duración individual, ignorando el paralelismo. Un servicio de 6 s corriendo en paralelo con otros no te cuesta nada. Usá `critical-chain`, que sigue el camino real de dependencias:

```console
$ systemd-analyze critical-chain
The time when unit became active or started is printed after the "@" character.
The time the unit took to start is printed after the "+" character.

graphical.target @12.398s
└─multi-user.target @12.396s
  └─node-ready.service @12.201s +194ms
    └─kubelet.service @8.033s +4.166s
      └─containerd.service @6.822s +1.203s
        └─network-online.target @6.818s
          └─NetworkManager-wait-online.service @2.700s +4.117s
            └─NetworkManager.service @2.401s +295ms
              └─dbus-broker.service @2.388s
                └─basic.target @2.381s
                  └─sysinit.target @2.377s
                    └─systemd-udev-settle.service @493ms +1.884s
                      └─systemd-udev-trigger.service @441ms +49ms
                        └─systemd-udevd-control.socket @437ms
                          └─-.mount @420ms
                            └─system.slice @420ms
                              └─-.slice @420ms
```

Ahora el análisis es concreto: 4,1 s esperando a `NetworkManager-wait-online` más 1,9 s en `systemd-udev-settle` son 6 s de latencia puramente serial en el camino crítico. `systemd-udev-settle` está obsoleto — cualquier unidad que todavía lo arrastre es un bug que vale la pena perseguir.

```console
$ systemd-analyze critical-chain kubelet.service
$ systemd-analyze plot > /tmp/boot.svg          # full parallel timeline
$ systemd-analyze dot --to-pattern='*.target' | dot -Tsvg > /tmp/deps.svg
$ systemd-analyze security sshd.service | tail -3
→ Overall exposure level for sshd.service: 9.6 UNSAFE 😨
$ systemd-analyze dump --no-pager | less        # complete PID 1 state
```

**Práctica de flota:** exportá la salida de `systemd-analyze` como métrica y alertá ante regresiones. Un nodo cuyo tiempo de arranque se duplicó tras una actualización de imagen te está diciendo que algo cambió en el camino crítico — normalmente una nueva dependencia de `network-online.target` — antes de que te cueste una ventana de mantenimiento.

```console
$ systemctl list-units --type=target --state=active
UNIT                   LOAD   ACTIVE SUB    DESCRIPTION
basic.target           loaded active active Basic System
cryptsetup.target      loaded active active Local Encrypted Volumes
getty.target           loaded active active Login Prompts
local-fs-pre.target    loaded active active Local File Systems (Pre)
local-fs.target        loaded active active Local File Systems
multi-user.target      loaded active active Multi-User System
network-online.target  loaded active active Network is Online
network.target         loaded active active Network
paths.target           loaded active active Path Units
remote-fs.target       loaded active active Remote File Systems
slices.target          loaded active active Slice Units
sockets.target         loaded active active Socket Units
sysinit.target         loaded active active System Initialization
swap.target            loaded active active Swaps
timers.target          loaded active active Timer Units

$ systemctl --failed
  UNIT                LOAD   ACTIVE SUB    DESCRIPTION
● srv-data.mount      loaded failed failed /srv/data
● node-ready.service  loaded failed failed Mark node ready for traffic

$ systemctl list-jobs
JOB UNIT                              TYPE  STATE
142 systemd-networkd-wait-online.serv start running
 87 network-online.target             start waiting
```

`systemctl list-jobs` durante un arranque **colgado** es el comando de mayor valor de esta sección: muestra exactamente qué unidad está esperando systemd en este preciso momento.

```console
$ systemctl list-dependencies multi-user.target --before
$ systemctl show sshd.service -p After -p Before -p Requires -p Wants
After=network.target sshd-keygen.target systemd-journald.socket basic.target system.slice auditd.service
Before=multi-user.target shutdown.target
Requires=sysinit.target system.slice
Wants=sshd-keygen.target
```

### 6.4 Manual de fallas

| Síntoma en la consola | Traspaso fallido | Causa más probable | Primer comando |
|---|---|---|---|
| `No bootable device` / `Operating System not found` | Firmware → cargador | Firma del MBR perdida, orden de arranque incorrecto, entrada de NVRAM UEFI perdida | `efibootmgr -v`; arrancar medio de rescate, `grub2-install` |
| `error: unknown filesystem` → `grub rescue>` | Cargador etapa 1.5 → etapa 2 | `/boot` movido, sistema de archivos convertido, `core.img` desactualizado tras clonar un disco | `set prefix=`, `insmod normal`, `normal` |
| `error: file '/vmlinuz-…' not found` | Cargador → kernel | Kernel eliminado pero quedó la entrada de `grub.cfg`/BLS | Arrancar una entrada más vieja; `grubby --info=ALL` |
| Aparece el menú, nada después de `Loading initial ramdisk` | Descompresión del kernel | initramfs corrupto/truncado (`/boot` lleno) | `df -h /boot`; `dracut -f --regenerate-all` |
| `Kernel panic - not syncing: VFS: Unable to mount root fs on unknown-block(0,0)` | initramfs → raíz real | `root=` incorrecto, o el driver de almacenamiento no está en el initramfs | Arrancar con `rd.break`, inspeccionar `/dev`; reconstruir con `--add-drivers` |
| `dracut-initqueue[…]: Warning: dracut-initqueue timeout - starting timeout scripts` (repetido), luego `dracut:/#` | initramfs → raíz real | El dispositivo raíz nunca apareció: UUID incorrecto, LVM sin activar, iSCSI/SAN inalcanzable | En la shell de dracut: `blkid`, `lvm lvs`, `cat /proc/cmdline` |
| `You are in emergency mode … Give root password for maintenance` | init, `local-fs.target` | Una entrada mala en `/etc/fstab` — la causa número uno | `journalctl -xb -p err`; `mount -o remount,rw /`; corregir `fstab`; `systemctl daemon-reload` |
| El arranque se cuelga en `A start job is running for …` (contador subiendo) | init | Una unidad con `TimeoutStartSec` largo/infinito — normalmente un `*-wait-online` o un montaje de red | `Ctrl-Alt-Del` en la consola, luego `systemctl list-jobs` después del arranque; agregar `_netdev,nofail` a la entrada de fstab |
| Arranca, pero no hay interfaces de red | init | Se agregó/quitó `net.ifnames=0` → interfaz renombrada, la configuración ya no coincide | `ip -br link`; `dmesg \| grep -i rename` |
| Arranca a una pantalla negra después del menú de GRUB | Kernel, KMS | Falla del mode-setting del driver de GPU | Agregar `nomodeset` en el prompt `e` de GRUB |
| Todo da `Permission denied` después del arranque | init, SELinux | Hace falta reetiquetar el sistema de archivos tras haber usado `selinux=0` | Arrancar con `enforcing=0`, `touch /.autorelabel`, reiniciar |
| El nodo reinicia en bucle, sin registros | — | El journal es volátil; el kernel entra en pánico antes de volcar | `Storage=persistent`; agregar `panic=30`, `crashkernel=`, configurar kdump; capturar la consola serie |

### 6.5 Las cuatro técnicas de recuperación, con transcripciones reales

**A. `rd.break` — una shell dentro del initramfs**

El camino de recuperación más potente en una máquina con systemd: funciona incluso cuando `/etc/fstab`, la contraseña de root, SELinux y PAM están todos rotos, porque ninguno de ellos se usó todavía.

Agregá en el prompt `e` de GRUB:

```
rd.break enforcing=0
```

```
Generating "/run/initramfs/rdsosreport.txt"

Entering emergency mode. Exit the shell to continue.
Type "journalctl" to view system logs.

dracut:/# cat /proc/cmdline
BOOT_IMAGE=(hd0,gpt2)/vmlinuz-6.10.6-200.fc40.x86_64 root=/dev/mapper/vg0-root ro rd.lvm.lv=vg0/root rd.break enforcing=0

dracut:/# blkid
/dev/sda1: SEC_TYPE="msdos" UUID="A1B2-C3D4" TYPE="vfat" PARTUUID="9a3b1e77-..."
/dev/sda2: UUID="3f9a1c04-77b2-4e18-9c5a-2d6e8b0f1a33" TYPE="ext4" PARTUUID="..."
/dev/sda3: UUID="Wf3kLp-2xYt-9Bqv-Nm4R-7dSc-Ue1A-gH8jKl" TYPE="LVM2_member" PARTUUID="..."

dracut:/# lvm vgs
  VG   #PV #LV #SN Attr   VSize   VFree
  vg0    1   2   0 wz--n- <99.00g    0

dracut:/# ls /sysroot
bin  boot  dev  etc  home  lib  lib64  media  mnt  opt  proc  root  run  sbin  srv  sys  tmp  usr  var

dracut:/# mount -o remount,rw /sysroot

dracut:/# chroot /sysroot

sh-5.2# passwd root
Changing password for user root.
New password:
Retype new password:
passwd: all authentication tokens updated successfully.

sh-5.2# vi /etc/fstab            # remove the bad entry

sh-5.2# touch /.autorelabel      # MANDATORY if SELinux is enforcing:
                                 # /etc/shadow was written with the wrong context

sh-5.2# exit
dracut:/# exit
[  OK  ] Reached target Basic System.
...
```

El paso de `/.autorelabel` es el que todo el mundo olvida. Sin él, en un sistema con SELinux en enforcing, el archivo que acabás de escribir tiene el contexto del initramfs y `sshd`/`login` no pueden leerlo — "arreglaste" la máquina hacia una falla distinta.

**B. Modo de emergencia vía la línea de comandos del kernel**

```
systemd.unit=emergency.target
```

La raíz se monta en **sólo lectura**, nada más está corriendo:

```
Welcome to emergency mode! After logging in, type "journalctl -xb" to view
system logs, "systemctl reboot" to reboot, "systemctl default" or "exit"
to boot into default mode.
Give root password for maintenance
(or press Control-D to continue):

[root@node07 ~]# journalctl -xb -p err --no-pager
Aug 25 09:15:03 node07 systemd[1[]: Mounting /srv/data...
Aug 25 09:15:03 node07 mount[612]: mount: /srv/data: special device /dev/mapper/vg1-data does not exist.
Aug 25 09:15:03 node07 systemd[1]: srv-data.mount: Mount process exited, code=exited, status=32/n/a
Aug 25 09:15:03 node07 systemd[1]: Failed to mount /srv/data.

[root@node07 ~]# mount -o remount,rw /
[root@node07 ~]# vi /etc/fstab
[root@node07 ~]# systemctl daemon-reload      # re-run the fstab generator
[root@node07 ~]# systemctl default
```

`systemctl daemon-reload` después de editar `/etc/fstab` no es opcional: las unidades `.mount` son **generadas** desde `fstab` por `systemd-fstab-generator` en el arranque y quedan cacheadas. Sin una recarga, systemd sigue trabajando con la versión rota.

**El endurecimiento de fstab que previene esta clase de incidente por completo:**

```
# /etc/fstab
# <device>                                  <mount>     <type> <options>                        <dump> <pass>
UUID=3f9a1c04-77b2-4e18-9c5a-2d6e8b0f1a33   /boot       ext4   defaults                          1 2
UUID=A1B2-C3D4                              /boot/efi   vfat   umask=0077,shortname=winnt        0 2
/dev/mapper/vg0-root                        /           xfs    defaults                          0 0
/dev/mapper/vg0-swap                        none        swap   defaults                          0 0

# nofail  -> boot continues if the device is missing (no emergency mode)
# _netdev -> ordered after network-online.target
# x-systemd.device-timeout -> bounded wait instead of a 90 s stall per device
# x-systemd.mount-timeout  -> bounded mount attempt
10.20.30.40:/exports/data  /srv/data  nfs4  rw,nofail,_netdev,x-systemd.device-timeout=10,x-systemd.mount-timeout=30,noatime  0 0
```

`nofail` en cada montaje no esencial es un cambio de una palabra que convierte "toda la flota está en modo emergencia" en "un directorio está vacío y saltó una alerta". Aplicalo a todo montaje que no sea `/`, `/usr` o `/boot`.

**C. `init=/bin/bash` — la opción nuclear**

```
init=/bin/bash rw
```

El kernel ejecuta bash como PID 1. No hay systemd, ni garantías de `/proc`, ni red, ni manejo de señales, ni apagado limpio.

```
bash-5.2# mount -o remount,rw /
bash-5.2# mount -t proc proc /proc
bash-5.2# passwd root
bash-5.2# touch /.autorelabel
bash-5.2# sync
bash-5.2# exec /sbin/init          # hand over to systemd, or:
bash-5.2# echo b > /proc/sysrq-trigger   # immediate reboot, no unmount
```

**No** uses `reboot` ni `shutdown` acá — sin systemd corriendo como PID 1 no van a funcionar correctamente. `sync` y después SysRq, o `exec /sbin/init`.

Esto también demuestra por qué un menú de GRUB desprotegido en una máquina físicamente accesible equivale a repartir la contraseña de root, y por qué el cifrado de disco completo es la mitigación real — no una contraseña de GRUB.

**D. chroot desde medio de rescate — cuando el disco no arranca en absoluto**

```console
# Boot the distribution's ISO in rescue mode, then:
$ sudo vgchange -ay
  2 logical volume(s) in volume group "vg0" now active

$ sudo mount /dev/mapper/vg0-root /mnt/sysroot
$ sudo mount /dev/sda2 /mnt/sysroot/boot
$ sudo mount /dev/sda1 /mnt/sysroot/boot/efi
$ for d in /dev /dev/pts /proc /sys /run; do sudo mount --bind $d /mnt/sysroot$d; done
$ sudo chroot /mnt/sysroot /bin/bash

# Now you are on the real system. Repair:
sh-5.2# dracut --force --regenerate-all
sh-5.2# grub2-mkconfig -o /boot/efi/EFI/fedora/grub.cfg
sh-5.2# grub2-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=fedora
sh-5.2# efibootmgr -v
sh-5.2# exit

$ sudo umount -R /mnt/sysroot
$ sudo reboot
```

Los bind mounts son obligatorios: `dracut` y `grub2-install` necesitan `/dev` para los nodos de dispositivo, `/sys` para detectar el modo de firmware, y `/proc` para la información de montajes. Un chroot sin ellos produce un initramfs que parece construirse y después no funciona.

### 6.6 Lista de verificación previa al vuelo

Ejecutá esto **antes** del reinicio, no después. Cada línea es gratis.

```console
# 1. Is /boot full? A truncated initramfs is silent until it is fatal.
$ df -h /boot /boot/efi
Filesystem      Size  Used Avail Use% Mounted on
/dev/sda2       974M  412M  495M  46% /boot
/dev/sda1       599M   18M  582M   3% /boot/efi

# 2. Does an initramfs exist for every installed kernel, and is it fresh?
$ ls -la --time-style=long-iso /boot/vmlinuz-* /boot/initramfs-*
-rw-------. 1 root root 41291776 2026-08-20 14:03 /boot/initramfs-6.10.6-200.fc40.x86_64.img
-rw-------. 1 root root 41108992 2026-07-30 08:12 /boot/initramfs-6.10.3-200.fc40.x86_64.img
-rwxr-xr-x. 1 root root 14962176 2026-08-20 14:01 /boot/vmlinuz-6.10.6-200.fc40.x86_64
-rwxr-xr-x. 1 root root 14958080 2026-07-30 08:10 /boot/vmlinuz-6.10.3-200.fc40.x86_64

# 3. Does the initramfs contain the driver for the root device?
$ lsblk -no NAME,TYPE,MOUNTPOINT /dev/sda
$ lsinitrd /boot/initramfs-6.10.6-200.fc40.x86_64.img | grep -cE 'nvme|megaraid|dm-mod'
7

# 4. Do the UUIDs in fstab actually resolve?
$ sudo findmnt --verify --verbose
/
   [ ] target exists
   [ ] FS options: defaults
/boot
   [ ] target exists
   [ ] UUID=3f9a1c04-77b2-4e18-9c5a-2d6e8b0f1a33 translated to /dev/sda2
   [ ] source /dev/sda2 exists
Success, no errors or warnings detected

# 5. Is the default boot entry the one you think it is?
$ sudo grubby --default-kernel
/boot/vmlinuz-6.10.6-200.fc40.x86_64

# 6. Do all unit files parse?
$ sudo systemd-analyze verify default.target

# 7. Is anything already failed? Do not reboot into a known-broken state.
$ systemctl --failed
0 loaded units listed.

# 8. Will the journal survive the reboot?
$ journalctl --list-boots | wc -l
4

# 9. Is the serial console configured on BOTH the kernel and GRUB?
$ grep -E 'console=' /proc/cmdline /etc/default/grub

# 10. Only now:
$ sudo systemctl reboot
```

---

## 7. Artefactos de infraestructura completos

### 7.1 Butane / Ignition — argumentos del kernel en un SO inmutable

Fedora CoreOS y Flatcar ejecutan Ignition **dentro del initramfs**, antes de `switch_root`. Ésta es la respuesta moderna a "configurar el arranque sin un sistema de archivos mutable".

```yaml
# platform-node.bu — compile with:
#   butane --pretty --strict platform-node.bu -o platform-node.ign
variant: fcos
version: 1.5.0

kernel_arguments:
  should_exist:
    - console=tty0
    - console=ttyS0,115200n8
    - systemd.unified_cgroup_hierarchy=1
    - transparent_hugepage=never
    - intel_iommu=on
    - iommu=pt
    - panic=30
    - oops=panic
    - crashkernel=1G-4G:192M,4G-64G:256M,64G-:512M
    - audit=1
  should_not_exist:
    - quiet
    - rhgb
    - mitigations=off

passwd:
  users:
    - name: core
      ssh_authorized_keys:
        - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyDoNotUseInProduction platform-team

storage:
  disks:
    - device: /dev/disk/by-id/coreos-boot-disk
      wipe_table: false
      partitions:
        - number: 4
          label: root
          size_mib: 16384
          resize: true
        - label: containers
          size_mib: 0            # 0 = use the remainder of the disk
  filesystems:
    - device: /dev/disk/by-partlabel/containers
      path: /var/lib/containers
      format: xfs
      wipe_filesystem: false
      label: CONTAINERS
      with_mount_unit: true
      mount_options:
        - prjquota
        - noatime

  files:
    - path: /etc/systemd/journald.conf.d/50-persistent.conf
      mode: 0644
      overwrite: true
      contents:
        inline: |
          [Journal]
          Storage=persistent
          Compress=yes
          SystemMaxUse=2G
          MaxRetentionSec=1month
          ForwardToSyslog=no

    - path: /etc/sysctl.d/90-platform.conf
      mode: 0644
      contents:
        inline: |
          kernel.panic = 30
          kernel.panic_on_oops = 1
          vm.swappiness = 1
          net.ipv4.ip_forward = 1
          fs.inotify.max_user_instances = 8192

    - path: /usr/local/bin/boot-report
      mode: 0755
      contents:
        inline: |
          #!/usr/bin/bash
          # Emit boot timing to the node_exporter textfile collector so that a
          # boot-time regression shows up on a dashboard, not in an incident.
          set -euo pipefail
          OUT=/var/lib/node_exporter/textfile_collector/boot.prom
          TMP="${OUT}.$$"
          install -d -m 0755 "$(dirname "$OUT")"
          parse() { systemd-analyze time 2>/dev/null || systemd-analyze; }
          line="$(parse | head -1)"
          get() { grep -oP "[0-9.]+(?=s \($1\))" <<<"$line" || echo 0; }
          {
            echo "# HELP node_boot_stage_seconds Duration of each boot stage."
            echo "# TYPE node_boot_stage_seconds gauge"
            for stage in firmware loader kernel initrd userspace; do
              printf 'node_boot_stage_seconds{stage="%s"} %s\n' "$stage" "$(get "$stage")"
            done
            echo "# HELP node_boot_id_info Boot ID of the current boot."
            echo "# TYPE node_boot_id_info gauge"
            printf 'node_boot_id_info{boot_id="%s"} 1\n' "$(cat /proc/sys/kernel/random/boot_id)"
          } > "$TMP"
          mv -f "$TMP" "$OUT"

systemd:
  units:
    - name: boot-report.service
      enabled: true
      contents: |
        [Unit]
        Description=Export boot timing metrics
        After=multi-user.target
        ConditionPathExists=/usr/local/bin/boot-report

        [Service]
        Type=oneshot
        RemainAfterExit=yes
        ExecStart=/usr/local/bin/boot-report

        [Install]
        WantedBy=multi-user.target

    - name: zincati.service
      # Disable automatic reboots for updates: reboot scheduling belongs to the
      # cluster drain controller, not to the node.
      mask: true
```

```console
$ butane --pretty --strict platform-node.bu -o platform-node.ign
$ coreos-installer install /dev/sda --ignition-file platform-node.ign
Installing Fedora CoreOS 40.20260815.3.0 x86_64 (512-byte sectors)
> Read disk 1.1 GiB/1.1 GiB (100%)
Writing Ignition config
Install complete.
```

### 7.2 cloud-init — argumentos del kernel y configuración de arranque en un SO mutable

```yaml
#cloud-config
# /var/lib/cloud/seed/nocloud/user-data
hostname: node07
fqdn: node07.platform.example.internal
manage_etc_hosts: true

users:
  - name: platform
    groups: [wheel, systemd-journal]
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    shell: /bin/bash
    ssh_authorized_keys:
      - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyDoNotUseInProduction platform-team

write_files:
  - path: /etc/systemd/journald.conf.d/50-persistent.conf
    permissions: "0644"
    owner: root:root
    content: |
      [Journal]
      Storage=persistent
      Compress=yes
      SystemMaxUse=2G
      MaxRetentionSec=1month

  - path: /etc/dracut.conf.d/50-platform.conf
    permissions: "0644"
    content: |
      hostonly="no"
      compress="zstd"
      add_drivers+=" nvme nvme-tcp megaraid_sas dm-multipath "
      add_dracutmodules+=" lvm dm multipath "
      omit_dracutmodules+=" plymouth "

  - path: /etc/systemd/system/serial-getty@ttyS0.service.d/override.conf
    permissions: "0644"
    content: |
      [Service]
      ExecStart=
      ExecStart=-/sbin/agetty -o '-p -- \\u' --keep-baud 115200,57600,38400,9600 %I $TERM

bootcmd:
  # bootcmd runs on EVERY boot, very early — before write_files and runcmd.
  - [ cloud-init-per, once, disable_thp, sh, -c,
      "echo never > /sys/kernel/mm/transparent_hugepage/enabled" ]

runcmd:
  # 1. Persist the kernel command line across every installed kernel.
  - [ grubby, --update-kernel=ALL, --args=
      "console=tty0 console=ttyS0,115200n8 transparent_hugepage=never panic=30 oops=panic systemd.unified_cgroup_hierarchy=1" ]
  - [ grubby, --update-kernel=ALL, --remove-args, "quiet rhgb" ]

  # 2. Rebuild every initramfs with the platform dracut config above.
  - [ dracut, --force, --regenerate-all ]

  # 3. Make the journal persistent for THIS boot too, not just the next one.
  - [ mkdir, -p, /var/log/journal ]
  - [ systemd-tmpfiles, --create, --prefix, /var/log/journal ]
  - [ systemctl, restart, systemd-journald ]

  # 4. Verify before declaring the node ready. Fail loudly if the cmdline
  #    did not take — a silent miss here becomes a boot incident later.
  - [ sh, -c, "grubby --info=ALL | grep -q 'panic=30' || { echo 'FATAL: kernel args not applied' >&2; exit 1; }" ]
  - [ systemd-analyze, verify, default.target ]

power_state:
  mode: reboot
  message: "Rebooting to apply kernel arguments and new initramfs"
  timeout: 60
  condition: true

final_message: "Node ready after $UPTIME seconds, boot id $INSTANCE_ID"
```

### 7.3 Ansible — gestión idempotente de la cmdline del kernel entre distribuciones

```yaml
---
# playbooks/boot-baseline.yml
# Enforces the boot-time baseline. Idempotent: safe to run on every pass.
# Reboots are gated behind an explicit -e allow_reboot=true.
- name: Boot baseline
  hosts: platform_nodes
  become: true
  serial: "10%"                    # never touch the whole fleet at once
  max_fail_percentage: 0

  vars:
    allow_reboot: false
    required_kargs:
      - "console=tty0"
      - "console=ttyS0,115200n8"
      - "transparent_hugepage=never"
      - "panic=30"
      - "oops=panic"
      - "systemd.unified_cgroup_hierarchy=1"
      - "audit=1"
    forbidden_kargs:
      - "quiet"
      - "rhgb"
      - "mitigations=off"
      - "selinux=0"

  tasks:
    - name: Determine firmware mode
      ansible.builtin.stat:
        path: /sys/firmware/efi
      register: efi_dir

    - name: Record firmware mode
      ansible.builtin.set_fact:
        firmware_mode: "{{ 'uefi' if efi_dir.stat.exists else 'bios' }}"

    - name: Show current kernel command line
      ansible.builtin.slurp:
        src: /proc/cmdline
      register: current_cmdline

    - name: Report drift before changing anything
      ansible.builtin.debug:
        msg: >-
          {{ inventory_hostname }} ({{ firmware_mode }}):
          {{ (current_cmdline.content | b64decode) | trim }}

    # ---------- Red Hat family: grubby is the idempotent primitive ----------
    - name: Apply required kernel arguments (RHEL family)
      ansible.builtin.command:
        argv:
          - grubby
          - --update-kernel=ALL
          - "--args={{ required_kargs | join(' ') }}"
      when: ansible_os_family == "RedHat"
      register: grubby_add
      changed_when: true
      notify: rebuild initramfs

    - name: Remove forbidden kernel arguments (RHEL family)
      ansible.builtin.command:
        argv:
          - grubby
          - --update-kernel=ALL
          - "--remove-args={{ forbidden_kargs | join(' ') }}"
      when: ansible_os_family == "RedHat"
      changed_when: true

    # ---------- Debian family: edit /etc/default/grub, then regenerate ----------
    - name: Set GRUB_CMDLINE_LINUX_DEFAULT (Debian family)
      ansible.builtin.lineinfile:
        path: /etc/default/grub
        regexp: '^GRUB_CMDLINE_LINUX_DEFAULT='
        line: 'GRUB_CMDLINE_LINUX_DEFAULT="{{ required_kargs | join('' '') }}"'
        create: false
        backup: true
      when: ansible_os_family == "Debian"
      notify:
        - update grub
        - rebuild initramfs

    - name: Enable the serial console in GRUB itself (both families)
      ansible.builtin.blockinfile:
        path: /etc/default/grub
        marker: "# {mark} ANSIBLE MANAGED serial console"
        backup: true
        block: |
          GRUB_TERMINAL_INPUT="console serial"
          GRUB_TERMINAL_OUTPUT="console serial"
          GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"
          GRUB_TIMEOUT=5
          GRUB_TIMEOUT_STYLE=menu
          GRUB_DISABLE_OS_PROBER=true
      notify:
        - update grub
      when: ansible_os_family in ["RedHat", "Debian"]

    - name: Ship the platform dracut configuration
      ansible.builtin.copy:
        dest: /etc/dracut.conf.d/50-platform.conf
        owner: root
        group: root
        mode: "0644"
        content: |
          hostonly="no"
          compress="zstd"
          add_drivers+=" nvme nvme-tcp megaraid_sas dm-multipath "
          add_dracutmodules+=" lvm dm multipath "
          omit_dracutmodules+=" plymouth "
      when: ansible_os_family == "RedHat"
      notify: rebuild initramfs

    - name: Make the journal persistent
      ansible.builtin.copy:
        dest: /etc/systemd/journald.conf.d/50-persistent.conf
        owner: root
        group: root
        mode: "0644"
        content: |
          [Journal]
          Storage=persistent
          Compress=yes
          SystemMaxUse=2G
          MaxRetentionSec=1month
          ForwardToSyslog=no
      notify: restart journald

    - name: Ensure the journal directory exists
      ansible.builtin.file:
        path: /var/log/journal
        state: directory
        owner: root
        group: systemd-journal
        mode: "2755"
      notify: restart journald

    - name: Enable the serial getty
      ansible.builtin.systemd:
        name: serial-getty@ttyS0.service
        enabled: true
        state: started
        daemon_reload: true

    - name: Flush handlers before the verification gate
      ansible.builtin.meta: flush_handlers

    # ---------- Verification: refuse to leave a node in an unbootable state ----------
    - name: Verify an initramfs exists for every installed kernel
      ansible.builtin.shell: |
        set -euo pipefail
        rc=0
        for k in /boot/vmlinuz-*; do
          [ "$k" = "/boot/vmlinuz-*" ] && continue
          v="${k#/boot/vmlinuz-}"
          if [ ! -s "/boot/initramfs-${v}.img" ] && [ ! -s "/boot/initrd.img-${v}" ]; then
            echo "MISSING initramfs for ${v}" >&2
            rc=1
          fi
        done
        exit "$rc"
      args:
        executable: /bin/bash
      changed_when: false

    - name: Verify /boot has headroom
      ansible.builtin.shell: |
        set -euo pipefail
        avail=$(df -Pm /boot | awk 'NR==2 {print $4}')
        [ "$avail" -ge 200 ] || { echo "/boot has only ${avail}MB free" >&2; exit 1; }
      args:
        executable: /bin/bash
      changed_when: false

    - name: Verify every fstab entry resolves
      ansible.builtin.command: findmnt --verify
      changed_when: false

    - name: Verify all unit files parse
      ansible.builtin.command: systemd-analyze verify default.target
      changed_when: false

    - name: Verify no unit is currently failed
      ansible.builtin.command: systemctl is-system-running
      register: sysrun
      changed_when: false
      failed_when: sysrun.stdout not in ["running", "degraded", "starting"]

    # ---------- Reboot, explicitly opted into ----------
    - name: Reboot to apply the new command line
      ansible.builtin.reboot:
        reboot_timeout: 900
        post_reboot_delay: 30
        test_command: systemctl is-system-running --wait
      when: allow_reboot | bool

    - name: Confirm the new command line is live
      ansible.builtin.slurp:
        src: /proc/cmdline
      register: post_cmdline
      when: allow_reboot | bool

    - name: Fail if any required argument did not survive the reboot
      ansible.builtin.assert:
        that:
          - "item in (post_cmdline.content | b64decode)"
        fail_msg: "Kernel argument '{{ item }}' is missing from /proc/cmdline after reboot"
        success_msg: "Kernel argument '{{ item }}' is active"
      loop: "{{ required_kargs }}"
      when: allow_reboot | bool

    - name: Report boot timing
      ansible.builtin.command: systemd-analyze time
      register: boot_time
      changed_when: false
      when: allow_reboot | bool

    - name: Show boot timing
      ansible.builtin.debug:
        var: boot_time.stdout_lines
      when: allow_reboot | bool

  handlers:
    - name: update grub
      ansible.builtin.command: >-
        {{ 'update-grub' if ansible_os_family == 'Debian'
           else ('grub2-mkconfig -o /boot/efi/EFI/' ~ ansible_distribution | lower ~ '/grub.cfg'
                 if firmware_mode == 'uefi'
                 else 'grub2-mkconfig -o /boot/grub2/grub.cfg') }}
      listen: update grub

    - name: rebuild initramfs
      ansible.builtin.command: >-
        {{ 'update-initramfs -u -k all' if ansible_os_family == 'Debian'
           else 'dracut --force --regenerate-all' }}
      listen: rebuild initramfs

    - name: restart journald
      ansible.builtin.systemd:
        name: systemd-journald
        state: restarted
      listen: restart journald
```

### 7.4 Kickstart — la sección del bootloader completa

```
# ks/platform-node.ks — unattended install, boot-relevant sections
text
lang en_US.UTF-8
keyboard us
timezone UTC --utc
network --bootproto=dhcp --device=link --activate --onboot=on
rootpw --iscrypted --lock
sshpw --username=install --lock
selinux --enforcing
firewall --enabled --service=ssh
services --enabled=sshd,chronyd,auditd --disabled=kdump

# --- Boot loader -------------------------------------------------------------
# --location=mbr : BIOS -> MBR of the first disk. On UEFI, anaconda writes to
#                  the ESP regardless and this is effectively ignored.
# --boot-drive   : which disk gets the loader when several are present.
# --append       : appended to every generated boot entry.
# --iscrypted    : the PBKDF2 hash from grub2-mkpasswd-pbkdf2.
bootloader --location=mbr --boot-drive=sda --timeout=5 \
  --append="console=tty0 console=ttyS0,115200n8 transparent_hugepage=never panic=30 oops=panic crashkernel=1G-4G:192M,4G-64G:256M,64G-:512M audit=1 systemd.unified_cgroup_hierarchy=1" \
  --iscrypted --password=grub.pbkdf2.sha512.10000.C4E08A1B7D2F...9E3A.5B7C11D2...F0A8

# --- Partitioning ------------------------------------------------------------
zerombr
clearpart --all --initlabel --drives=sda
# biosboot is REQUIRED for GPT + legacy BIOS. Omitting it produces an
# installation that completes successfully and then does not boot.
part biosboot --fstype=biosboot --size=1  --ondisk=sda
part /boot/efi --fstype=efi     --size=600 --ondisk=sda --fsoptions="umask=0077,shortname=winnt"
part /boot     --fstype=ext4    --size=1024 --ondisk=sda --label=BOOT
part pv.01     --size=1 --grow  --ondisk=sda
volgroup vg0 pv.01
logvol /     --vgname=vg0 --name=root --fstype=xfs  --size=20480
logvol swap  --vgname=vg0 --name=swap --fstype=swap --size=8192
logvol /var  --vgname=vg0 --name=var  --fstype=xfs  --size=1 --grow --fsoptions="noatime,nodev"

reboot --eject

%packages
@^minimal-environment
dracut-config-generic
grubby
efibootmgr
-plymouth
-plymouth-scripts
%end

%post --log=/root/ks-post.log
set -euxo pipefail

# Generic (not host-only) initramfs: this image is cloned across hardware SKUs.
cat > /etc/dracut.conf.d/50-platform.conf <<'EOF'
hostonly="no"
compress="zstd"
add_drivers+=" nvme nvme-tcp megaraid_sas dm-multipath "
add_dracutmodules+=" lvm dm multipath "
omit_dracutmodules+=" plymouth "
EOF
dracut --force --regenerate-all

# Persistent journal from the very first boot.
mkdir -p /var/log/journal
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/50-persistent.conf <<'EOF'
[Journal]
Storage=persistent
Compress=yes
SystemMaxUse=2G
MaxRetentionSec=1month
EOF

# Serial console login.
systemctl enable serial-getty@ttyS0.service

# Prove the boot configuration before the machine ever reboots.
grubby --info=ALL | grep -q 'panic=30' || { echo 'FATAL: kernel args missing'; exit 1; }
%end
```

### 7.5 Kubernetes — argumentos del kernel del nodo como estado declarativo

En OpenShift / OKD, el Machine Config Operator renderiza `kernelArguments` en la configuración del bootloader de los nodos y realiza un **reinicio rotativo consciente del drenaje**. Éste es el patrón correcto a imitar en cualquier lado: un cambio de argumentos del kernel es un *evento del ciclo de vida del nodo*, no la edición de un archivo de configuración.

```yaml
---
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  name: 99-worker-boot-baseline
  labels:
    machineconfiguration.openshift.io/role: worker
spec:
  kernelArguments:
    - console=tty0
    - console=ttyS0,115200n8
    - transparent_hugepage=never
    - panic=30
    - oops=panic
    - intel_iommu=on
    - iommu=pt
    - crashkernel=1G-4G:192M,4G-64G:256M,64G-:512M
  config:
    ignition:
      version: 3.4.0
    storage:
      files:
        - path: /etc/systemd/journald.conf.d/50-persistent.conf
          mode: 420          # 0644 in decimal — Ignition uses decimal file modes
          overwrite: true
          contents:
            source: >-
              data:text/plain;charset=utf-8;base64,W0pvdXJuYWxdClN0b3JhZ2U9cGVyc2lzdGVudApDb21wcmVzcz15ZXMKU3lzdGVtTWF4VXNlPTJHCg==
        - path: /etc/sysctl.d/90-boot-baseline.conf
          mode: 420
          overwrite: true
          contents:
            source: >-
              data:text/plain;charset=utf-8;base64,a2VybmVsLnBhbmljID0gMzAKa2VybmVsLnBhbmljX29uX29vcHMgPSAxCg==
    systemd:
      units:
        - name: boot-report.service
          enabled: true
          contents: |
            [Unit]
            Description=Export boot timing metrics
            After=multi-user.target

            [Service]
            Type=oneshot
            RemainAfterExit=yes
            ExecStart=/usr/local/bin/boot-report

            [Install]
            WantedBy=multi-user.target
---
# Bound the blast radius: one node at a time, and never reboot outside the window.
apiVersion: machineconfiguration.openshift.io/v1
kind: KubeletConfig
metadata:
  name: worker-shutdown-grace
spec:
  machineConfigPoolSelector:
    matchLabels:
      pools.operator.machineconfiguration.openshift.io/worker: ""
  kubeletConfig:
    shutdownGracePeriod: 180s
    shutdownGracePeriodCriticalPods: 60s
---
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfigPool
metadata:
  name: worker
spec:
  maxUnavailable: 1
  paused: false
  machineConfigSelector:
    matchLabels:
      machineconfiguration.openshift.io/role: worker
  nodeSelector:
    matchLabels:
      node-role.kubernetes.io/worker: ""
```

```console
$ kubectl apply -f 99-worker-boot-baseline.yaml
machineconfig.machineconfiguration.openshift.io/99-worker-boot-baseline created

$ kubectl get mcp worker -w
NAME     CONFIG                        UPDATED   UPDATING   DEGRADED   MACHINECOUNT   READYMACHINECOUNT
worker   rendered-worker-a4f1c2d8b9e0  False     True       False      6              5
worker   rendered-worker-7b3e9f10c2a5  True      False      False      6              6

$ kubectl debug node/worker-03 -it --image=registry.access.redhat.com/ubi9/ubi -- chroot /host cat /proc/cmdline
BOOT_IMAGE=(hd0,gpt3)/ostree/rhcos-.../vmlinuz-5.14.0-427.el9.x86_64 root=UUID=... rw console=tty0 console=ttyS0,115200n8 transparent_hugepage=never panic=30 oops=panic intel_iommu=on iommu=pt crashkernel=1G-4G:192M
```

`maxUnavailable: 1` es todo el punto. Un argumento de kernel que deja los nodos sin arrancar es un cambio que termina con la flota si se despliega en paralelo; con un pool rotativo te cuesta exactamente un nodo, y el pool se detiene.

---

## 8. Referencia rápida orientada al examen

**La cadena de arranque en una línea, en orden:** firmware (BIOS/UEFI) → gestor de arranque (GRUB2) → kernel (`vmlinuz`) → initramfs (`/init`) → `switch_root` → init (systemd/SysVinit) → target por omisión / runlevel.

| Pregunta | Comando |
|---|---|
| ¿UEFI o BIOS? | `ls /sys/firmware/efi` |
| ¿Qué le pasó el bootloader al kernel? | `cat /proc/cmdline` |
| Mensajes del kernel, este arranque | `dmesg` / `journalctl -k -b` |
| Mensajes del kernel, arranque anterior | `journalctl -k -b -1` |
| Sólo errores, arranque anterior | `journalctl -b -1 -p err` |
| Listar todos los arranques registrados | `journalctl --list-boots` |
| ¿Cuál es el target por omisión? | `systemctl get-default` |
| Cambiar el target por omisión | `systemctl set-default multi-user.target` |
| Cambiar de target ahora | `systemctl isolate rescue.target` |
| ¿Qué unidades fallaron? | `systemctl --failed` |
| ¿Qué está esperando systemd en este momento? | `systemctl list-jobs` |
| ¿Cuánto tardó el arranque, por etapa? | `systemd-analyze` |
| ¿Qué está en el camino crítico del arranque? | `systemd-analyze critical-chain` |
| Runlevel actual (SysV) | `runlevel` |
| Cambiar de runlevel (SysV) | `telinit 3` / `init 3` |
| ¿En qué runlevels arranca este servicio? | `chkconfig --list sshd` |
| Reconstruir el initramfs | `dracut -f --regenerate-all` / `update-initramfs -u -k all` |
| Regenerar la configuración de GRUB | `grub2-mkconfig -o <path>` / `update-grub` |
| Cambiar argumentos del kernel de forma persistente | `grubby --update-kernel=ALL --args="..."` |
| Listar/crear entradas de arranque UEFI | `efibootmgr -v` |

**Parámetros del kernel que más probablemente pregunten:** `root=`, `ro`/`rw`, `init=/bin/bash`, `single`/`1`, `systemd.unit=rescue.target`, `systemd.unit=emergency.target`, `quiet`, `nomodeset`, `rd.break`, `console=ttyS0,115200n8`.

**Distinciones sobre las que conviene ser preciso:**

- `initrd` es una **imagen de dispositivo de bloques**; `initramfs` es un **archivo cpio desempaquetado en tmpfs**. El punto de entrada del kernel es `/linuxrc` frente a `/init`.
- `rescue.target` monta el sistema de archivos raíz e inicia servicios básicos; `emergency.target` te da una shell sobre una raíz en **sólo lectura** con esencialmente nada iniciado.
- **`After=` es sólo orden**; `Requires=`/`Wants=` son los que realmente traen una unidad a la transacción. Normalmente hacen falta ambos.
- `dmesg` lee el **búfer circular del kernel** — sólo mensajes del kernel, se borra al reiniciar, finito. `journalctl` lee el **journal** — kernel *y* espacio de usuario, persistente si `Storage=persistent`, consultable a través de arranques.
- **Regeneración al estilo `--lang` frente a edición:** `grub.cfg` es generado. Editarlo directamente funciona hasta el próximo `grub2-mkconfig`, actualización de paquete o instalación de kernel, que descarta tu cambio en silencio. Editá `/etc/default/grub`, `/etc/grub.d/`, o la entrada BLS vía `grubby`.

---

## 9. Referencias

**Objetivos del examen**

- LPI — Exam 101 Objectives (LPIC-1 version 5.0), objetivo 101.2 *Boot the system*: https://www.lpi.org/our-certifications/exam-101-objectives/
- LPI — LPIC-1 certification overview: https://www.lpi.org/our-certifications/lpic-1-overview/

**Gestores de arranque y firmware**

- GNU GRUB Manual 2.06: https://www.gnu.org/software/grub/manual/grub/grub.html
- GRUB — Booting and command-line interface: https://www.gnu.org/software/grub/manual/grub/grub.html#Command_002dline-and-menu-entry-commands
- UEFI Specification (UEFI Forum): https://uefi.org/specifications
- The Boot Loader Specification (systemd/UAPI Group): https://uapi-group.org/specifications/specs/boot_loader_specification/
- Discoverable Partitions Specification: https://uapi-group.org/specifications/specs/discoverable_partitions_specification/
- Proyecto `efibootmgr`: https://github.com/rhboot/efibootmgr
- `shim` — el cargador de primera etapa de Secure Boot: https://github.com/rhboot/shim
- Manual de `systemd-boot`: https://www.freedesktop.org/software/systemd/man/latest/systemd-boot.html
- Manual de `bootctl`: https://www.freedesktop.org/software/systemd/man/latest/bootctl.html

**Kernel, línea de comandos e initramfs**

- The kernel's command-line parameters (kernel.org): https://docs.kernel.org/admin-guide/kernel-parameters.html
- Documentación de initrd / initramfs (kernel.org): https://docs.kernel.org/admin-guide/initrd.html
- ramfs, rootfs and initramfs (kernel.org): https://docs.kernel.org/filesystems/ramfs-rootfs-initramfs.html
- Booting the kernel (protocolo de arranque x86): https://docs.kernel.org/arch/x86/boot.html
- Kernel lockdown y Secure Boot (`kernel_lockdown.7`): https://man7.org/linux/man-pages/man7/kernel_lockdown.7.html
- Manual de `dracut`: https://man7.org/linux/man-pages/man8/dracut.8.html
- `dracut.cmdline` — parámetros de kernel de dracut: https://man7.org/linux/man-pages/man7/dracut.cmdline.7.html
- Manual de `dracut.conf`: https://man7.org/linux/man-pages/man5/dracut.conf.5.html
- `initramfs-tools` (Debian): https://manpages.debian.org/stable/initramfs-tools-core/initramfs-tools.7.en.html
- `update-initramfs` (Debian): https://manpages.debian.org/stable/initramfs-tools-core/update-initramfs.8.en.html

**Sistemas de init**

- systemd — índice de páginas de manual: https://www.freedesktop.org/software/systemd/man/latest/
- `systemd(1)` — incluidas las opciones de la línea de comandos del kernel: https://www.freedesktop.org/software/systemd/man/latest/systemd.html
- `systemd.unit(5)`: https://www.freedesktop.org/software/systemd/man/latest/systemd.unit.html
- `systemd.service(5)`: https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html
- `systemd.target(5)`: https://www.freedesktop.org/software/systemd/man/latest/systemd.target.html
- `bootup(7)` — el proceso de arranque de systemd: https://www.freedesktop.org/software/systemd/man/latest/bootup.html
- `systemd-analyze(1)`: https://www.freedesktop.org/software/systemd/man/latest/systemd-analyze.html
- `systemd-fstab-generator(8)`: https://www.freedesktop.org/software/systemd/man/latest/systemd-fstab-generator.html
- `systemd.mount(5)` — incluidos `nofail`, `_netdev`, `x-systemd.*`: https://www.freedesktop.org/software/systemd/man/latest/systemd.mount.html
- `init(8)` / SysVinit: https://man7.org/linux/man-pages/man8/init.8.html
- `inittab(5)`: https://man7.org/linux/man-pages/man5/inittab.5.html
- `runlevel(8)`: https://man7.org/linux/man-pages/man8/runlevel.8.html
- `telinit(8)`: https://man7.org/linux/man-pages/man8/telinit.8.html
- Proyecto SysVinit: https://github.com/slicer69/sysvinit
- Upstart — Getting Started y cookbook: https://upstart.ubuntu.com/getting-started.html y https://upstart.ubuntu.com/cookbook/
- Linux Standard Base — acciones de scripts de init y cabeceras LSB: https://refspecs.linuxfoundation.org/LSB_5.0.0/LSB-Core-generic/LSB-Core-generic/iniscrptact.html

**Registro y diagnóstico**

- `dmesg(1)` (util-linux): https://man7.org/linux/man-pages/man1/dmesg.1.html
- `journalctl(1)`: https://www.freedesktop.org/software/systemd/man/latest/journalctl.html
- `systemd-journald.service(8)`: https://www.freedesktop.org/software/systemd/man/latest/systemd-journald.service.html
- `journald.conf(5)`: https://www.freedesktop.org/software/systemd/man/latest/journald.conf.html
- `systemd.journal-fields(7)`: https://www.freedesktop.org/software/systemd/man/latest/systemd.journal-fields.html
- `proc(5)` — `/proc/cmdline`, `/proc/sys/kernel/printk`: https://man7.org/linux/man-pages/man5/proc.5.html

**Documentación de distribuciones y plataformas**

- Red Hat Enterprise Linux 9 — Managing, monitoring and updating the kernel (línea de comandos del kernel, `grubby`, BLS): https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/managing_monitoring_and_updating_the_kernel/index
- `grubby(8)`: https://man7.org/linux/man-pages/man8/grubby.8.html
- Fedora — Working with the GRUB 2 Boot Loader: https://docs.fedoraproject.org/en-US/fedora/latest/system-administrators-guide/kernel-module-driver-configuration/Working_with_the_GRUB_2_Boot_Loader/
- Debian Wiki — GRUB: https://wiki.debian.org/Grub
- Ubuntu — Kernel boot parameters / GRUB2: https://help.ubuntu.com/community/Grub2
- Fedora CoreOS — Butane configuration specification v1.5.0: https://coreos.github.io/butane/config-fcos-v1_5/
- Ignition specification v3.4.0: https://coreos.github.io/ignition/configuration-v3_4/
- Fedora CoreOS — Adding kernel arguments: https://docs.fedoraproject.org/en-US/fedora-coreos/kernel-args/
- cloud-init — referencia de módulos (`bootcmd`, `runcmd`, `write_files`, `power_state`): https://cloudinit.readthedocs.io/en/latest/reference/modules.html
- Ansible — módulo `ansible.builtin.reboot`: https://docs.ansible.com/ansible/latest/collections/ansible/builtin/reboot_module.html
- Anaconda — referencia del comando `bootloader` de Kickstart: https://pykickstart.readthedocs.io/en/latest/kickstart-docs.html
- OpenShift — Adding kernel arguments to nodes with MachineConfig: https://docs.redhat.com/en/documentation/openshift_container_platform/latest/html/machine_configuration/index