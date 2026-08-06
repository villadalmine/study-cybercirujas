# LPIC-2 Tema 202: System Startup — Guía de Estudio Avanzada para SRE

## Peso: 7 | Examen: 201-450 + 202-450 (v4.5)

---

## 1. Motivación y Problema Arquitectural en Producción

En entornos Linux de producción, **System Startup** es la secuencia individual más crítica que determina la disponibilidad del servicio después de cualquier reinicio, fallo de energía, actualización del kernel o evento de disaster recovery. Un SRE debe dominar cada fase:

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    PRODUCTION BOOT SEQUENCE                            │
│                                                                        │
│  ┌──────────┐   ┌────────────┐   ┌──────────┐   ┌─────────────────┐  │
│  │ Firmware  │──▶│ Bootloader │──▶│  Kernel  │──▶│   Init System   │  │
│  │BIOS/UEFI │   │GRUB2/Other │   │+initramfs│   │systemd/SysVinit │  │
│  └──────────┘   └────────────┘   └──────────┘   └─────────────────┘  │
│       │               │               │                 │              │
│   POST/NVRAM    Stage1→Stage2    decompress        PID 1              │
│   boot device   load kernel     mount rootfs     service mgmt         │
│   selection     + initramfs     pivot_root       target/runlevel      │
│                                                                        │
│  ◀── FAILURE DOMAINS ──▶                                               │
│  Each transition is a potential point of boot failure                  │
│  that requires distinct recovery techniques                           │
└─────────────────────────────────────────────────────────────────────────┘
```

**Escenarios de producción que requieren un dominio profundo del boot:**

- Kernel panic tras una actualización → entrada de fallback en GRUB, rescue boot
- `/etc/fstab` corrupto → emergency.target, recuperación de montaje
- Unit de systemd fallida bloqueando el boot → análisis de dependencias, masking
- DR en Data center → cadena de netboot PXE/SYSLINUX para aprovisionamiento bare-metal
- Requerimientos de cumplimiento (compliance) → hardening del boot, contraseña de GRUB, Secure Boot
- Bare-metal Multi-OS → bootloaders encadenados (chained), entradas personalizadas de GRUB

---

## 2. Desglose de Objetivos de LPIC-2 (202.1, 202.2, 202.3)

### 2.1 Objetivos Cubiertos y Áreas Clave de Conocimiento

| Subtema | Peso | Áreas Clave de Conocimiento |
|---|---|---|
| **202.1** Personalización del System Startup | 3 | systemd units, scripts de SysVinit, LSB init, runlevels, targets, chkconfig, systemctl, update-rc.d |
| **202.2** Recuperación del Sistema (System Recovery) | 4 | Interacción entre GRUB2 y GRUB Legacy, boot en modo recovery, initramfs, reparación con chroot, reinstalación del bootloader |
| **202.3** Bootloaders Alternativos | 2 | SYSLINUX, ISOLINUX, PXELINUX, EXTLINUX, systemd-boot (EFI stub) |

### 2.2 Archivos, Términos y Utilidades Clave

```
/etc/inittab                    /usr/lib/systemd/system/
/etc/init.d/                    /etc/systemd/system/
/etc/rc.d/ (/etc/rc*.d/)       /run/systemd/system/
/etc/default/grub               /boot/grub/grub.cfg
/boot/grub2/grub.cfg            /etc/grub.d/
/boot/                          /boot/efi/
grub-install                    grub-mkconfig
grub2-install                   grub2-mkconfig
update-grub                     dracut
mkinitrd                        mkinitramfs / update-initramfs
systemctl                       journalctl
chkconfig                       update-rc.d
insserv                         telinit
init                            /proc/cmdline
syslinux                        extlinux
isolinux.cfg                    pxelinux.0
```

---

## 3. La Secuencia de Boot en Linux: Recorrido Técnico Completo

### 3.1 Fase 1: Firmware (BIOS/UEFI)

```
┌─────────────────────────────────────────────────────────┐
│                  BIOS (Legacy)                          │
│  POST → enumerate hardware → read MBR (sector 0,      │
│  512 bytes) from boot device → execute Stage 1         │
│  bootloader at bytes 0-445                             │
│                                                         │
│  Partition table: bytes 446-509 (4 × 16-byte entries)  │
│  Boot signature: bytes 510-511 (0x55AA)                │
└─────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│                   UEFI                                  │
│  POST → read GPT → locate EFI System Partition (ESP)   │
│  (FAT32, typically /boot/efi, ~200-512 MB) →           │
│  read boot entries from NVRAM → execute                 │
│  EFI/fedora/shimx64.efi or EFI/ubuntu/grubx64.efi     │
│                                                         │
│  No MBR limitation. Supports Secure Boot chain.        │
│  EFI variables managed via efibootmgr.                 │
└─────────────────────────────────────────────────────────┘
```

**Gestión de entradas de boot en UEFI:**

```bash
$ efibootmgr -v
BootCurrent: 0003
Timeout: 5 seconds
BootOrder: 0003,0001,0000
Boot0000* EFI Network	PciRoot(0x0)/Pci(0x1c,0x0)/Pci(0x0,0x0)/MAC(001122334455,1)/IPv4(0.0.0.0)
Boot0001* EFI DVD/CDROM	PciRoot(0x0)/Pci(0x1f,0x2)/Sata(1,0,0)
Boot0003* ubuntu	HD(1,GPT,a1b2c3d4-...)/File(\EFI\ubuntu\shimx64.efi)
```

```bash
# Add a new UEFI boot entry
$ efibootmgr --create --disk /dev/sda --part 1 \
    --label "Custom Linux" \
    --loader '\EFI\custom\grubx64.efi'
```

### 3.2 Fase 2: Bootloader GRUB2 (Enfoque Principal)

#### 3.2.1 Arquitectura de GRUB2

```
BIOS boot:
┌──────────────────────────────────────────────────────────────────┐
│  Stage 1 (boot.img)     → MBR, 446 bytes                       │
│  Stage 1.5 (core.img)   → MBR gap (sectors 1-62) or BIOS Boot  │
│                            Partition (GPT), contains filesystem │
│                            drivers (ext2, xfs, etc.)            │
│  Stage 2 (/boot/grub/)  → Full GRUB environment, grub.cfg,     │
│                            modules, themes, fonts               │
└──────────────────────────────────────────────────────────────────┘

UEFI boot:
┌──────────────────────────────────────────────────────────────────┐
│  grubx64.efi (or shimx64.efi → grubx64.efi for Secure Boot)   │
│  Located on ESP: /boot/efi/EFI/<distro>/                       │
│  Loads grub.cfg from ESP or /boot/grub/                         │
└──────────────────────────────────────────────────────────────────┘
```

#### 3.2.2 Archivos de Configuración de GRUB2

**`/etc/default/grub` — Parámetros principales de configuración:**

```bash
# /etc/default/grub — COMPLETE PRODUCTION CONFIGURATION
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_TIMEOUT_STYLE=menu
GRUB_DISTRIBUTOR="$(sed 's, release .*$,,g' /etc/system-release)"
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"
GRUB_CMDLINE_LINUX="crashkernel=auto rd.lvm.lv=vg0/root rd.lvm.lv=vg0/swap rhgb"
GRUB_DISABLE_RECOVERY="false"
GRUB_DISABLE_OS_PROBER=false
GRUB_TERMINAL_OUTPUT="console"
# GRUB_TERMINAL_INPUT="serial console"
# GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"
GRUB_ENABLE_CRYPTODISK=n
# GRUB_PRELOAD_MODULES="lvm"
```

**Explicación de parámetros clave:**

| Parámetro | Propósito | Notas de Producción |
|---|---|---|
| `GRUB_DEFAULT` | Entrada de boot por defecto (número o `saved`) | Usar `saved` con `grub-set-default` para realizar rollbacks |
| `GRUB_TIMEOUT` | Segundos antes del auto-boot | Ajustar a 3-5 para servidores; 0 para headless si hay certeza |
| `GRUB_TIMEOUT_STYLE` | `menu`, `hidden`, `countdown` | `menu` para producción — nunca `hidden` en servidores |
| `GRUB_CMDLINE_LINUX` | Parámetros del kernel para TODAS las entradas | Crítico: `crashkernel`, `console=`, activación de LVM |
| `GRUB_CMDLINE_LINUX_DEFAULT` | Parámetros solo para entradas que no sean de recovery | `quiet splash` para desktop; remover en servidores |
| `GRUB_DISABLE_RECOVERY` | Generar entradas de recovery | **Siempre `false`** en producción |
| `GRUB_TERMINAL_OUTPUT` | Dispositivo de salida | `serial console` para acceso remoto por IPMI/iLO |
| `GRUB_PRELOAD_MODULES` | Módulos cargados tempranamente | `lvm` si `/boot` está sobre LVM |

**`/etc/grub.d/` — Directorio de scripts que generan `grub.cfg`:**

```bash
$ ls -la /etc/grub.d/
total 84
-rwxr-xr-x 1 root root 10627 00_header
-rwxr-xr-x 1 root root  6258 05_debian_theme
-rwxr-xr-x 1 root root 18683 10_linux
-rwxr-xr-x 1 root root 43202 10_linux_zfs
-rwxr-xr-x 1 root root 14180 20_linux_xen
-rwxr-xr-x 1 root root 13369 30_os-prober
-rwxr-xr-x 1 root root  1372 30_uefi-firmware
-rwxr-xr-x 1 root root   214 40_custom
-rwxr-xr-x 1 root root   215 41_custom
```

| Script | Función | ¿Modificable? |
|---|---|---|
| `00_header` | Establece valores por defecto, timeout y ajustes de terminal desde `/etc/default/grub` | No — autogenerado |
| `10_linux` | Detecta los kernels instalados, crea las entradas de boot | No — autogenerado |
| `20_linux_xen` | Entradas para el hipervisor Xen | No |
| `30_os-prober` | Detecta otros sistemas operativos (Windows, etc.) | No |
| `40_custom` | **Entradas personalizadas — punto de edición principal** | **Sí** |
| `41_custom` | Carga (sources) un archivo externo para entradas personalizadas | Sí |

#### 3.2.3 Entrada Personalizada de GRUB2 (40_custom)

```bash
#!/bin/sh
exec tail -n +3 $0
# This file provides an easy way to add custom menu entries.

menuentry 'Emergency Recovery Shell' --class gnu-linux --class os {
    set root='hd0,msdos1'
    linux /vmlinuz-5.4.0-generic root=/dev/mapper/vg0-root ro init=/bin/bash
    initrd /initrd.img-5.4.0-generic
}

menuentry 'Previous Kernel (Rollback)' --class gnu-linux --class os {
    set root='hd0,gpt2'
    linux /vmlinuz-5.4.0-148-generic root=UUID=a1b2c3d4-e5f6-7890-abcd-ef1234567890 ro
    initrd /initrd.img-5.4.0-148-generic
}

menuentry 'Netboot via iPXE' {
    set root='hd0,gpt1'
    chainloader /EFI/boot/ipxe.efi
}

menuentry 'Chainload Windows Boot Manager' {
    insmod chain
    set root='hd0,gpt1'
    chainloader /EFI/Microsoft/Boot/bootmgfw.efi
}
```

#### 3.2.4 Regeneración de grub.cfg

```bash
# Debian/Ubuntu
$ update-grub
Sourcing file `/etc/default/grub'
Sourcing file `/etc/default/grub.d/init-select.cfg'
Generating grub configuration file ...
Found linux image: /boot/vmlinuz-5.15.0-91-generic
Found initrd image: /boot/initrd.img-5.15.0-91-generic
Found linux image: /boot/vmlinuz-5.15.0-88-generic
Found initrd image: /boot/initrd.img-5.15.0-88-generic
Warning: os-prober will not be executed to detect other bootable partitions.
done

# RHEL/CentOS/Fedora (BIOS)
$ grub2-mkconfig -o /boot/grub2/grub.cfg
Generating grub configuration file ...
Found linux image: /boot/vmlinuz-4.18.0-513.el8.x86_64
Found initrd image: /boot/initramfs-4.18.0-513.el8.x86_64.img
Found linux image: /boot/vmlinuz-0-rescue-abc123
Found initrd image: /boot/initramfs-0-rescue-abc123.img
done

# RHEL/CentOS/Fedora (UEFI)
$ grub2-mkconfig -o /boot/efi/EFI/centos/grub.cfg
```

#### 3.2.5 Instalación de GRUB2 en el Disco

```bash
# BIOS — install to MBR of /dev/sda
$ grub-install /dev/sda
Installing for i386-pc platform.
Installation finished. No error reported.

# Verify MBR was written
$ dd if=/dev/sda bs=512 count=1 2>/dev/null | hexdump -C | tail -3
000001e0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|
000001f0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 55 aa  |..............U.|
00000200

# UEFI — install to ESP
$ grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu
Installing for x86_64-efi platform.
Installation finished. No error reported.

# RHEL/CentOS
$ grub2-install /dev/sda
```

#### 3.2.6 Shell Interactivo de GRUB2 (Emergencia)

Cuando GRUB no logra cargar `grub.cfg`, cae a un shell. Existen dos modos:

```
grub>               ← Full shell (modules loaded)
grub rescue>         ← Minimal shell (modules missing)
```

**Recuperación en Full shell:**

```
grub> ls
(hd0) (hd0,msdos1) (hd0,msdos2) (hd0,msdos5)

grub> ls (hd0,msdos1)/
vmlinuz-5.15.0-91-generic initrd.img-5.15.0-91-generic grub/ lost+found/

grub> set root=(hd0,msdos1)
grub> linux /vmlinuz-5.15.0-91-generic root=/dev/sda2 ro
grub> initrd /initrd.img-5.15.0-91-generic
grub> boot
```

**Recuperación en Rescue shell:**

```
grub rescue> ls
(hd0) (hd0,gpt1) (hd0,gpt2) (hd0,gpt3)

grub rescue> ls (hd0,gpt2)/grub
unicode.pf2 grubenv grub.cfg fonts/ i386-pc/

grub rescue> set prefix=(hd0,gpt2)/grub
grub rescue> set root=(hd0,gpt2)
grub rescue> insmod normal
grub rescue> normal
```

#### 3.2.7 Protección con Contraseña en GRUB2

```bash
# Generate password hash
$ grub-mkpasswd-pbkdf2
Enter password: ********
Reenter password: ********
PBKDF2 hash of your password is grub.pbkdf2.sha512.10000.ABC123...DEF456

# Add to /etc/grub.d/01_password (create this file)
$ cat /etc/grub.d/01_password
#!/bin/sh
set -e
cat << 'EOF'
set superusers="admin"
password_pbkdf2 admin grub.pbkdf2.sha512.10000.ABC123...DEF456
EOF

$ chmod 755 /etc/grub.d/01_password
$ update-grub
```

Para permitir el boot sin contraseña pero requerirla para la edición:

```bash
# In 10_linux, entries have --unrestricted by default on some distros
# Or add CLASS="--class gnu-linux --class os --unrestricted" in /etc/grub.d/10_linux
```

---

### 3.3 Fase 3: Kernel e initramfs

```
┌──────────────────────────────────────────────────────────────────────┐
│  GRUB loads vmlinuz + initramfs/initrd into memory                  │
│       │                                                              │
│       ▼                                                              │
│  Kernel decompresses itself, initializes core subsystems            │
│  (memory management, scheduler, drivers compiled-in)                │
│       │                                                              │
│       ▼                                                              │
│  Kernel mounts initramfs as temporary root (tmpfs at /)             │
│       │                                                              │
│       ▼                                                              │
│  initramfs runs /init script (systemd or busybox-based):            │
│  - Loads required kernel modules (storage drivers, dm, lvm, raid)   │
│  - Activates LVM VGs, assembles MD arrays                           │
│  - Unlocks LUKS encrypted volumes                                   │
│  - Mounts real root filesystem                                      │
│       │                                                              │
│       ▼                                                              │
│  pivot_root (or switch_root) → new root mounted                     │
│  exec /sbin/init (PID 1) → systemd or SysVinit                     │
└──────────────────────────────────────────────────────────────────────┘
```

**Gestión de initramfs:**

```bash
# Debian/Ubuntu — create/update initramfs
$ update-initramfs -u -k 5.15.0-91-generic
update-initramfs: Generating /boot/initrd.img-5.15.0-91-generic

$ update-initramfs -u -k all    # Update ALL installed kernels

# RHEL/CentOS — dracut
$ dracut --force /boot/initramfs-4.18.0-513.el8.x86_64.img 4.18.0-513.el8.x86_64
$ dracut --force --regenerate-all

# Inspect contents of initramfs
$ lsinitramfs /boot/initrd.img-5.15.0-91-generic | head -20
.
kernel
kernel/x86
kernel/x86/microcode
kernel/x86/microcode/AuthenticAMD.bin
usr
usr/lib
usr/lib/modules
usr/lib/modules/5.15.0-91-generic
usr/lib/modules/5.15.0-91-generic/kernel

# RHEL: Inspect with lsinitrd
$ lsinitrd /boot/initramfs-4.18.0-513.el8.x86_64.img | head -20
Image: /boot/initramfs-4.18.0-513.el8.x86_64.img: 34M
========================================================================
Early CPIO image
========================================================================
drwxr-xr-x   3 root     root            0 Jan 15 10:30 .
-rw-r--r--   1 root     root            2 Jan 15 10:30 early_cpio
drwxr-xr-x   3 root     root            0 Jan 15 10:30 kernel
drwxr-xr-x   3 root     root            0 Jan 15 10:30 kernel/x86
drwxr-xr-x   2 root     root            0 Jan 15 10:30 kernel/x86/microcode
-rw-r--r--   1 root     root       98304 Jan 15 10:30 kernel/x86/microcode/AuthenticAMD.bin

# Manual extraction for deep inspection
$ mkdir /tmp/initrd-inspect && cd /tmp/initrd-inspect
$ unmkinitramfs /boot/initrd.img-5.15.0-91-generic .
$ ls
early  main
$ find main/usr/lib/systemd -name '*.service' | head -5
main/usr/lib/systemd/system/initrd-switch-root.service
main/usr/lib/systemd/system/initrd-cleanup.service
main/usr/lib/systemd/system/initrd-parse-etc.service
main/usr/lib/systemd/system/initrd-root-fs.target
main/usr/lib/systemd/system/sysroot.mount
```

**Command line del Kernel (parámetros críticos para el examen):**

```bash
$ cat /proc/cmdline
BOOT_IMAGE=/vmlinuz-5.15.0-91-generic root=/dev/mapper/vg0-root ro \
  crashkernel=auto rd.lvm.lv=vg0/root rd.lvm.lv=vg0/swap \
  console=tty0 console=ttyS0,115200n8 systemd.unit=multi-user.target
```

| Parámetro | Propósito |
|---|---|
| `root=` | Especifica el dispositivo del sistema de archivos root |
| `ro` | Monta root inicialmente en modo solo lectura (remontado rw por init) |
| `init=` | Sobrescribe el binario de PID 1 (`init=/bin/bash` para rescue) |
| `single`, `s`, `1` | Realiza el boot en modo single-user / rescue |
| `systemd.unit=` | Sobrescribe el target por defecto de systemd |
| `rd.break` | Interrumpe la ejecución en initramfs antes de pivot_root (RHEL) |
| `rd.lvm.lv=` | Activa LVs de LVM específicos en initramfs |
| `console=` | Especifica el dispositivo(s) de consola para acceso por serie |
| `crashkernel=` | Reserva memoria para kdump |
| `enforcing=0` | Boot con SELinux en modo permisivo (permissive) |
| `rd.shell` | Cae a un shell si initramfs falla |

---

## 4. Sistemas de Init: systemd vs SysVinit

### 4.1 Comparación Exhaustiva

| Aspecto | SysVinit | systemd |
|---|---|---|
| **Binario de PID 1** | `/sbin/init` (SysVinit) | `/usr/lib/systemd/systemd` |
| **Configuración** | `/etc/inittab` + shell scripts | Unit files (declarativos `.service`, `.target`, etc.) |
| **Paralelismo** | Inicio secuencial | Paralelismo agresivo mediante activación por socket/D-Bus |
| **Dependencias** | Implícitas (encabezados LSB, orden de nombres) | Explícitas (`After=`, `Requires=`, `Wants=`) |
| **Supervisión de servicios** | Ninguna (requiere monit, runit, etc.) | Políticas de reinicio integradas, rastreo por cgroups |
| **Logging** | syslog → archivos de texto | journald → journal binario (estructurado) |
| **Runlevel/Target** | Runlevels 0-6 | Targets (multi-user.target, graphical.target, etc.) |
| **Inicio bajo demanda** | xinetd / manual | Activación por socket, por path, por timer |
| **Velocidad de boot** | Típica de 30-120s | Típica de 5-30s |
| **Rastreo de procesos** | Archivos PID (frágiles) | cgroups (confiable, sin PID race) |
| **Control de recursos** | Ninguno integrado | Límites de CPU, Memory, IO de cgroups por servicio |
| **Soporte para contenedores** | Mínimo | Nativo (systemd-nspawn, journald namespaces) |

### 4.2 Mapeo Runlevel ↔ Target

| Runlevel | Significado en SysVinit | Target en systemd | Symlink |
|---|---|---|---|
| 0 | Halt | `poweroff.target` | `runlevel0.target` |
| 1 / S | Single-user | `rescue.target` | `runlevel1.target` |
| 2 | Multi-user (sin NFS) Debian | `multi-user.target` | `runlevel2.target` |
| 3 | Multi-user + networking | `multi-user.target` | `runlevel3.target` |
| 4 | Sin uso/personalizado | `multi-user.target` | `runlevel4.target` |
| 5 | Multi-user + GUI | `graphical.target` | `runlevel5.target` |
| 6 | Reboot | `reboot.target` | `runlevel6.target` |
| — | — | `emergency.target` | Sin equivalente en runlevel |

### 4.3 Análisis Profundo de SysVinit

#### `/etc/inittab` (Tradicional)

```bash
# /etc/inittab — SysVinit master configuration
#
# Format: id:runlevels:action:process

# Default runlevel (DO NOT set to 0 or 6)
id:3:initdefault:

# System initialization script
si::sysinit:/etc/init.d/rcS

# Runlevel scripts
l0:0:wait:/etc/init.d/rc 0
l1:1:wait:/etc/init.d/rc 1
l2:2:wait:/etc/init.d/rc 2
l3:3:wait:/etc/init.d/rc 3
l4:4:wait:/etc/init.d/rc 4
l5:5:wait:/etc/init.d/rc 5
l6:6:wait:/etc/init.d/rc 6

# Ctrl+Alt+Del handler
ca:12345:ctrlaltdel:/sbin/shutdown -t1 -a -r now

# Getty (login prompt) on virtual consoles
1:2345:respawn:/sbin/getty 38400 tty1
2:2345:respawn:/sbin/getty 38400 tty2
3:2345:respawn:/sbin/getty 38400 tty3

# Serial console
T0:23:respawn:/sbin/getty -L ttyS0 115200 vt100

# Power fail / UPS events
pf::powerwait:/etc/init.d/powerfail start
pn::powerfailnow:/etc/init.d/powerfail now
po::powerokwait:/etc/init.d/powerfail stop
```

**Valores del campo de acción en `/etc/inittab`:**

| Acción | Comportamiento |
|---|---|
| `initdefault` | Establece el runlevel por defecto durante el boot |
| `sysinit` | Se ejecuta durante el init del sistema, antes de cualquier runlevel |
| `wait` | Inicia el proceso y espera a su finalización |
| `respawn` | Reinicia el proceso cada vez que finaliza o muere |
| `once` | Inicia el proceso una sola vez al entrar al runlevel |
| `ctrlaltdel` | Maneja la combinación de teclas Ctrl+Alt+Del |
| `powerwait` | Se ejecuta al recibir una señal de fallo de energía desde el UPS |
| `powerfailnow` | Se ejecuta cuando la batería está críticamente baja |
| `powerokwait` | Se ejecuta cuando se restablece la energía |
| `boot` | Se ejecuta durante el boot (ignora el campo de runlevel) |

#### Estructura de Scripts de SysVinit (Compatible con LSB)

```bash
#!/bin/bash
### BEGIN INIT INFO
# Provides:          myapp
# Required-Start:    $remote_fs $syslog $network
# Required-Stop:     $remote_fs $syslog $network
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: My Production Application
# Description:       Full description of myapp service
#                    spanning multiple lines
### END INIT INFO

# LSB init script source
. /lib/lsb/init-functions

DAEMON=/usr/local/bin/myapp
DAEMON_ARGS="--config /etc/myapp/config.yaml"
PIDFILE=/var/run/myapp.pid
NAME=myapp
DESC="My Application"

case "$1" in
  start)
    log_daemon_msg "Starting $DESC" "$NAME"
    start-stop-daemon --start --quiet --pidfile "$PIDFILE" \
        --make-pidfile --background --exec "$DAEMON" -- $DAEMON_ARGS
    log_end_msg $?
    ;;
  stop)
    log_daemon_msg "Stopping $DESC" "$NAME"
    start-stop-daemon --stop --quiet --pidfile "$PIDFILE" \
        --retry=TERM/30/KILL/5
    log_end_msg $?
    rm -f "$PIDFILE"
    ;;
  restart|force-reload)
    $0 stop
    sleep 1
    $0 start
    ;;
  status)
    status_of_proc -p "$PIDFILE" "$DAEMON" "$NAME" && exit 0 || exit $?
    ;;
  *)
    echo "Usage: $0 {start|stop|restart|force-reload|status}" >&2
    exit 3
    ;;
esac
exit 0
```

#### Gestión de Servicios SysVinit

```bash
# Debian/Ubuntu — update-rc.d
$ update-rc.d myapp defaults
 Adding system startup for /etc/init.d/myapp ...
   /etc/rc0.d/K20myapp -> ../init.d/myapp
   /etc/rc1.d/K20myapp -> ../init.d/myapp
   /etc/rc6.d/K20myapp -> ../init.d/myapp
   /etc/rc2.d/S20myapp -> ../init.d/myapp
   /etc/rc3.d/S20myapp -> ../init.d/myapp
   /etc/rc4.d/S20myapp -> ../init.d/myapp
   /etc/rc5.d/S20myapp -> ../init.d/myapp

# Custom priority
$ update-rc.d myapp defaults 90 10
# Start at priority 90 (late), Stop at priority 10 (early)

# Remove
$ update-rc.d myapp remove

# Disable (keep links but set to not start)
$ update-rc.d myapp disable

# RHEL/CentOS — chkconfig
$ chkconfig --add myapp
$ chkconfig myapp on
$ chkconfig --level 35 myapp on
$ chkconfig --list myapp
myapp          0:off  1:off  2:off  3:on  4:off  5:on  6:off

$ chkconfig --list | grep '3:on'
acpid           0:off  1:off  2:on   3:on   4:on   5:on   6:off
crond           0:off  1:off  2:on   3:on   4:on   5:on   6:off
myapp           0:off  1:off  2:off  3:on   4:off  5:on   6:off
network         0:off  1:off  2:on   3:on   4:on   5:on   6:off
sshd            0:off  1:off  2:on   3:on   4:on   5:on   6:off

# insserv (SUSE, some Debian) — dependency-based ordering
$ insserv myapp
$ insserv -r myapp     # remove

# Symlink structure
$ ls -la /etc/rc3.d/
lrwxrwxrwx 1 root root S01networking -> ../init.d/networking
lrwxrwxrwx 1 root root S02ssh -> ../init.d/ssh
lrwxrwxrwx 1 root root S90myapp -> ../init.d/myapp
# S = Start, K = Kill (stop)
# Number = execution order (lower = earlier)
```

#### Cambio de Runlevels

```bash
# Query current runlevel
$ runlevel
N 3
# N = previous runlevel (N = none/boot), 3 = current

$ who -r
         run-level 3  2024-01-15 10:30

# Switch runlevel
$ telinit 5      # Switch to runlevel 5 (GUI)
$ init 1         # Switch to single-user mode

# Reload /etc/inittab without reboot
$ telinit q
```

### 4.4 Análisis Profundo de systemd

#### 4.4.1 Anatomía de un Unit File

```bash
# /etc/systemd/system/myapp.service — COMPLETE PRODUCTION UNIT FILE
[Unit]
Description=My Production Application Service
Documentation=https://docs.myapp.io/
After=network-online.target postgresql.service redis.service
Wants=network-online.target
Requires=postgresql.service
BindsTo=redis.service
PartOf=myapp-stack.target
Conflicts=myapp-maintenance.service

# Conditions — skip silently if not met (vs Assert which fails hard)
ConditionPathExists=/etc/myapp/config.yaml
ConditionMemory=512M

[Service]
Type=notify
User=myapp
Group=myapp
WorkingDirectory=/opt/myapp

# Environment
Environment="NODE_ENV=production"
EnvironmentFile=-/etc/default/myapp
# Dash prefix means ignore if file doesn't exist

# Execution
ExecStartPre=/opt/myapp/bin/check-config --validate
ExecStart=/opt/myapp/bin/myapp-server --config /etc/myapp/config.yaml
ExecStartPost=/opt/myapp/bin/healthcheck --warm
ExecReload=/bin/kill -HUP $MAINPID
ExecStop=/bin/kill -TERM $MAINPID

# Restart policy
Restart=on-failure
RestartSec=5
StartLimitIntervalSec=300
StartLimitBurst=5

# Timeouts
TimeoutStartSec=90
TimeoutStopSec=30
WatchdogSec=60

# Security hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/myapp /var/log/myapp /run/myapp
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
SystemCallFilter=@system-service
MemoryDenyWriteExecute=true

# Resource limits
MemoryMax=2G
CPUQuota=200%
TasksMax=512
LimitNOFILE=65536

# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=myapp

[Install]
WantedBy=multi-user.target
```

**Comparación de tipos de servicio (`Type`):**

| Tipo | Comportamiento | Caso de Uso |
|---|---|---|
| `simple` (por defecto) | systemd considera iniciado el servicio inmediatamente tras el fork | Daemons modernos que no realizan fork |
| `forking` | systemd espera a que el proceso padre finalice; el hijo es el daemon | Daemons legacy (Apache prefork, etc.) |
| `oneshot` | systemd espera a que el proceso finalice completamente | Scripts de inicialización, trabajos por lotes (batch) |
| `notify` | El daemon envía `sd_notify(READY=1)` cuando está listo | Ideal para producción — estado de preparación explícito |
| `dbus` | Listo cuando se adquiere el nombre de D-Bus especificado | Servicios activados por D-Bus |
| `idle` | Similar a simple, pero retrasa la ejecución hasta procesar todos los trabajos | Servicios de baja prioridad |
| `exec` | Similar a simple, pero listo solo tras el éxito de exec() | Más seguro que simple |

#### 4.4.2 Targets de systemd (Personalizados)

```bash
# /etc/systemd/system/myapp-stack.target
[Unit]
Description=MyApp Full Stack Target
Requires=multi-user.target
After=multi-user.target
Wants=myapp.service myapp-worker@1.service myapp-worker@2.service nginx.service

[Install]
WantedBy=multi-user.target
```

#### 4.4.3 Units con Plantillas (Servicios Instanciados)

```bash
# /etc/systemd/system/myapp-worker@.service
[Unit]
Description=MyApp Worker Instance %i
After=network-online.target myapp.service
PartOf=myapp-stack.target

[Service]
Type=simple
User=myapp
ExecStart=/opt/myapp/bin/worker --id %i --queue worker-%i
Restart=always
RestartSec=3

[Install]
WantedBy=myapp-stack.target
```

```bash
# Enable instances
$ systemctl enable myapp-worker@1.service
$ systemctl enable myapp-worker@2.service
$ systemctl enable myapp-worker@3.service
$ systemctl start myapp-worker@{1..3}.service
```

#### 4.4.4 Referencia de Comandos de systemctl

```bash
# Service management
$ systemctl start myapp.service
$ systemctl stop myapp.service
$ systemctl restart myapp.service
$ systemctl reload myapp.service      # Send SIGHUP (ExecReload)
$ systemctl reload-or-restart myapp.service
$ systemctl try-restart myapp.service # Only restart if running

# Enable/Disable
$ systemctl enable myapp.service
Created symlink /etc/systemd/system/multi-user.target.wants/myapp.service → /etc/systemd/system/myapp.service.

$ systemctl disable myapp.service
Removed /etc/systemd/system/multi-user.target.wants/myapp.service.

$ systemctl is-enabled myapp.service
enabled

# Mask (absolutely prevent starting — even manually)
$ systemctl mask myapp-maintenance.service
Created symlink /etc/systemd/system/myapp-maintenance.service → /dev/null.

$ systemctl unmask myapp-maintenance.service
Removed /etc/systemd/system/myapp-maintenance.service.

# Status inspection
$ systemctl status myapp.service
● myapp.service - My Production Application Service
     Loaded: loaded (/etc/systemd/system/myapp.service; enabled; vendor preset: disabled)
     Active: active (running) since Mon 2024-01-15 10:30:45 UTC; 2h 15min ago
       Docs: https://docs.myapp.io/
    Process: 1234 ExecStartPre=/opt/myapp/bin/check-config --validate (code=exited, status=0/SUCCESS)
   Main PID: 1235 (myapp-server)
     Status: "Serving 1547 connections"
      Tasks: 24 (limit: 512)
     Memory: 856.3M (max: 2.0G)
        CPU: 3min 42.156s
     CGroup: /system.slice/myapp.service
             └─1235 /opt/myapp/bin/myapp-server --config /etc/myapp/config.yaml

Jan 15 10:30:44 prod-web-01 systemd[1]: Starting My Production Application Service...
Jan 15 10:30:45 prod-web-01 myapp[1235]: Server started on port 8080
Jan 15 10:30:45 prod-web-01 systemd[1]: Started My Production Application Service.

# Default target management
$ systemctl get-default
multi-user.target

$ systemctl set-default graphical.target
Removed /etc/systemd/system/default.target.
Created symlink /etc/systemd/system/default.target → /usr/lib/systemd/system/graphical.target.

# Switch target at runtime (equivalent to changing runlevel)
$ systemctl isolate rescue.target
$ systemctl isolate multi-user.target
$ systemctl isolate graphical.target

# List units
$ systemctl list-units --type=service --state=running
  UNIT                     LOAD   ACTIVE SUB     DESCRIPTION
  crond.service            loaded active running Command Scheduler
  dbus.service             loaded active running D-Bus System Message Bus
  myapp.service            loaded active running My Production Application Service
  NetworkManager.service   loaded active running Network Manager
  sshd.service             loaded active running OpenSSH server daemon
  systemd-journald.service loaded active running Journal Service
  systemd-udevd.service    loaded active running Rule-based Manager for Device Events

# List failed units
$ systemctl list-units --failed
  UNIT                LOAD   ACTIVE SUB    DESCRIPTION
● myapp-worker@4.service loaded failed failed MyApp Worker Instance 4

LOAD   = Reflects whether the unit definition was properly loaded.
ACTIVE = The high-level unit activation state, i.e. generalization of SUB.
SUB    = The low-level unit activation state, values depend on unit type.

1 loaded units listed.

# Dependency analysis
$ systemctl list-dependencies multi-user.target --no-pager
multi-user.target
● ├─crond.service
● ├─dbus.service
● ├─myapp.service
● ├─NetworkManager.service
● ├─sshd.service
● ├─systemd-ask-password-wall.path
● ├─systemd-logind.service
● ├─systemd-user-sessions.service
● └─basic.target
●   ├─microcode.service
●   ├─rhel-dmesg.service
●   ├─selinux-policy-migrate-local-changes@targeted.service
●   ├─paths.target
●   ├─slices.target
●   │ ├─-.slice
●   │ └─system.slice
●   ├─sockets.target
●   │ ├─dbus.socket
●   │ ├─systemd-journald.socket
●   │ └─systemd-udevd-control.socket
●   ├─sysinit.target
...

# Reverse dependencies (what needs this unit)
$ systemctl list-dependencies myapp.service --reverse
myapp.service
● └─multi-user.target
●   └─graphical.target

# Reload daemon after editing unit files
$ systemctl daemon-reload
```

#### 4.4.5 Análisis del Rendimiento del Boot

```bash
$ systemd-analyze
Startup finished in 2.456s (kernel) + 4.789s (initrd) + 12.345s (userspace) = 19.590s
graphical.target reached after 12.102s in userspace

$ systemd-analyze blame | head -15
          5.234s NetworkManager-wait-online.service
          2.891s myapp.service
          1.567s systemd-udev-settle.service
          1.234s postgresql.service
           987ms nginx.service
           876ms firewalld.service
           654ms systemd-journal-flush.service
           543ms dracut-initqueue.service
           432ms systemd-udevd.service
           321ms systemd-tmpfiles-setup.service
           234ms systemd-journald.service
           198ms chronyd.service
           176ms sshd.service
           154ms rsyslog.service
           132ms systemd-logind.service

$ systemd-analyze critical-chain
The time when unit became active or started is printed after the "@" character.
The time the unit took to start is printed after the "+" character.

graphical.target @12.102s
└─multi-user.target @12.100s
  └─myapp.service @9.209s +2.891s
    └─postgresql.service @7.975s +1.234s
      └─network-online.target @7.970s
        └─NetworkManager-wait-online.service @2.736s +5.234s
          └─NetworkManager.service @2.530s +198ms
            └─network-pre.target @2.525s
              └─firewalld.service @1.649s +876ms
                └─basic.target @1.645s
                  └─sockets.target @1.644s

# Generate SVG boot chart
$ systemd-analyze plot > /tmp/boot-chart.svg
```

---

## 5. Bootloaders Alternativos (202.3)

### 5.1 Visión General de la Familia SYSLINUX

```
┌──────────────────────────────────────────────────────────────────────────┐
│                      SYSLINUX FAMILY                                    │
│                                                                          │
│  ┌──────────┐  ┌──────────┐  ┌───────────┐  ┌────────────┐            │
│  │ SYSLINUX │  │EXTLINUX  │  │ ISOLINUX  │  │ PXELINUX   │            │
│  │FAT fs    │  │ext2/3/4  │  │ ISO 9660  │  │ PXE/TFTP   │            │
│  │USB/floppy│  │btrfs,xfs │  │ CD/DVD    │  │ Network    │            │
│  └──────────┘  └──────────┘  └───────────┘  └────────────┘            │
│       │              │             │               │                    │
│       └──────────────┴─────────────┴───────────────┘                    │
│                          │                                               │
│              Shared configuration format                                │
│              Light, fast, no interactive shell                           │
│              Ideal for: rescue, PXE, embedded, live media               │
└──────────────────────────────────────────────────────────────────────────┘
```

### 5.2 Tabla Comparativa de Bootloaders

| Característica | GRUB2 | GRUB Legacy | SYSLINUX | EXTLINUX | systemd-boot |
|---|---|---|---|---|---|
| **Soporte de sistemas de archivos** | ext*, xfs, btrfs, zfs, fat, ntfs, lvm, raid | ext2/3, fat, reiserfs | Solo FAT | ext2/3/4, btrfs, xfs | Solo ESP (FAT) |
| **Arquitectura** | i386, x86_64, arm, etc. | i386, x86_64 | x86 | x86 | Solo x86_64 UEFI |
| **Soporte BIOS** | Sí | Sí | Sí | Sí | No |
| **Soporte UEFI** | Sí | No | Limitado (vía EFI SYSLINUX) | No | Sí (nativo) |
| **Shell interactivo** | Sí (completo) | Sí (limitado) | No | No | No |
| **Chainloading** | Sí | Sí | Sí (COM32) | Sí | No |
| **Archivo de configuración** | `grub.cfg` (generado) | `menu.lst`/`grub.conf` | `syslinux.cfg` | `extlinux.conf` | `loader.conf` + entradas |
| **Boot por red** | Vía módulos | Limitado | PXELINUX (excelente) | No | No |
| **Complejidad** | Alta | Media | Baja | Baja | Muy Baja |
| **Ideal para** | Propósito general, enterprise | Sistemas legacy | USB, rescue, PXE | Linux instalado | Sistemas UEFI puros |

### 5.3 Configuración de SYSLINUX

```bash
# Install SYSLINUX to a FAT USB stick
$ syslinux --install /dev/sdb1

# Install MBR
$ dd if=/usr/lib/syslinux/mbr/mbr.bin of=/dev/sdb bs=440 count=1
1+0 records in
1+0 records out
440 bytes copied, 0.000812 s, 542 kB/s

# Mount and create configuration
$ mount /dev/sdb1 /mnt/usb
$ mkdir /mnt/usb/boot

# Copy kernel and initramfs
$ cp /boot/vmlinuz-5.15.0-91-generic /mnt/usb/boot/
$ cp /boot/initrd.img-5.15.0-91-generic /mnt/usb/boot/
```

```bash
# /mnt/usb/syslinux.cfg
UI menu.c32
PROMPT 0
TIMEOUT 50
DEFAULT linux

MENU TITLE Production Rescue Boot Menu
MENU COLOR border       30;44   #40ffffff #a0000000 std
MENU COLOR title        1;36;44 #9033ccff #a0000000 std
MENU COLOR sel          7;37;40 #e0ffffff #20ffffff all

LABEL linux
    MENU LABEL ^Production Linux (5.15.0-91)
    KERNEL /boot/vmlinuz-5.15.0-91-generic
    APPEND initrd=/boot/initrd.img-5.15.0-91-generic root=/dev/sda2 ro

LABEL rescue
    MENU LABEL ^Rescue Mode (single user)
    KERNEL /boot/vmlinuz-5.15.0-91-generic
    APPEND initrd=/boot/initrd.img-5.15.0-91-generic root=/dev/sda2 ro single

LABEL memtest
    MENU LABEL ^Memory Test (memtest86+)
    KERNEL /boot/memtest86+.bin

LABEL local
    MENU LABEL Boot from ^local disk
    LOCALBOOT 0x80
```

### 5.4 Configuración de EXTLINUX

```bash
# Install EXTLINUX to an ext4 partition
$ extlinux --install /boot/extlinux/
/boot/extlinux is device /dev/sda1, directory /extlinux
```

```bash
# /boot/extlinux/extlinux.conf
UI menu.c32
DEFAULT linux
PROMPT 0
TIMEOUT 30

LABEL linux
    MENU LABEL CentOS 8 Production
    LINUX ../vmlinuz-4.18.0-513.el8.x86_64
    INITRD ../initramfs-4.18.0-513.el8.x86_64.img
    APPEND root=/dev/mapper/vg0-root ro rd.lvm.lv=vg0/root

LABEL previous
    MENU LABEL CentOS 8 Previous Kernel
    LINUX ../vmlinuz-4.18.0-500.el8.x86_64
    INITRD ../initramfs-4.18.0-500.el8.x86_64.img
    APPEND root=/dev/mapper/vg0-root ro rd.lvm.lv=vg0/root
```

### 5.5 PXELINUX (Boot por Red)

```
┌──────────┐    DHCP      ┌──────────┐    TFTP     ┌──────────┐
│  Client  │─────────────▶│   DHCP   │────────────▶│   TFTP   │
│  (PXE)   │  next-server │  Server  │  filename   │  Server  │
│          │◀─────────────│          │             │          │
│          │    Boot info  └──────────┘             │          │
│          │◀──────────────────────────────────────│          │
│          │  pxelinux.0 + ldlinux.c32             │          │
│          │◀──────────────────────────────────────│          │
│          │  pxelinux.cfg/default                  │          │
│          │◀──────────────────────────────────────│          │
│          │  vmlinuz + initrd                      └──────────┘
│          │                    │
│          │    HTTP/NFS        ▼
│          │◀──────────── ┌──────────┐
│          │  rootfs/     │  HTTP/   │
│          │  kickstart   │  NFS     │
└──────────┘              └──────────┘
```

```bash
# TFTP directory structure
/var/lib/tftpboot/
├── pxelinux.0                      # PXELINUX bootloader
├── ldlinux.c32                     # Required library module
├── libutil.c32
├── menu.c32                        # Menu system module
├── vesamenu.c32                    # Graphical menu module
├── libcom32.c32
├── pxelinux.cfg/
│   ├── default                     # Default config for all clients
│   ├── 01-00-11-22-33-44-55       # MAC-specific config (01-<mac>)
│   ├── C0A80164                    # IP-specific config (hex IP)
│   └── C0A801                      # Subnet-specific fallback
├── kernels/
│   ├── centos8/
│   │   ├── vmlinuz
│   │   └── initrd.img
│   └── ubuntu2204/
│       ├── vmlinuz
│       └── initrd
└── memdisk                         # For booting ISO images
```

```bash
# /var/lib/tftpboot/pxelinux.cfg/default
UI vesamenu.c32
DEFAULT local
PROMPT 0
TIMEOUT 100
ONTIMEOUT local

MENU TITLE PXE Network Boot Menu — Production DC

LABEL local
    MENU LABEL Boot from ^local disk
    MENU DEFAULT
    LOCALBOOT 0

LABEL centos8-install
    MENU LABEL Install CentOS 8 (^Kickstart)
    KERNEL kernels/centos8/vmlinuz
    APPEND initrd=kernels/centos8/initrd.img inst.ks=http://pxe.internal/ks/centos8-prod.cfg ip=dhcp

LABEL ubuntu2204-install
    MENU LABEL Install Ubuntu 22.04 (^Autoinstall)
    KERNEL kernels/ubuntu2204/vmlinuz
    APPEND initrd=kernels/ubuntu2204/initrd url=http://pxe.internal/autoinstall/user-data ip=dhcp cloud-config-url=/dev/null

LABEL rescue
    MENU LABEL ^Rescue Environment
    KERNEL kernels/centos8/vmlinuz
    APPEND initrd=kernels/centos8/initrd.img inst.rescue ip=dhcp

LABEL memtest
    MENU LABEL ^Memory Diagnostics
    KERNEL memtest86+.bin
```

### 5.6 systemd-boot (Solo UEFI)

```bash
# Install systemd-boot
$ bootctl install
Created "/boot/efi/EFI/systemd".
Created "/boot/efi/EFI/systemd/systemd-bootx64.efi".
Created "/boot/efi/EFI/BOOT".
Created "/boot/efi/EFI/BOOT/BOOTX64.EFI".
Created "/boot/efi/loader".
Created "/boot/efi/loader/entries".

$ bootctl status
System:
     Firmware: UEFI 2.70 (Dell Inc. 1.14.0)
  Secure Boot: enabled (deployed)
   Setup Mode: user
 Boot into FW: supported

Current Boot Loader:
      Product: systemd-boot 252
     Features: ✓ Boot counting
               ✓ Menu timeout control
               ✓ One-shot menu timeout control
               ✓ Default entry control
               ✓ One-shot entry control
               ✓ Support for XBOOTLDR partition
               ✓ Support for passing random seed to OS
               ✓ Load drop-in drivers
               ✓ Boot loader sets ESP information
          ESP: /dev/disk/by-partuuid/abc123-def456
         File: └─/EFI/systemd/systemd-bootx64.efi
```

```bash
# /boot/efi/loader/loader.conf
default  ubuntu-current.conf
timeout  5
console-mode max
editor   no
```

```bash
# /boot/efi/loader/entries/ubuntu-current.conf
title   Ubuntu 22.04 LTS (Production)
linux   /vmlinuz-5.15.0-91-generic
initrd  /initrd.img-5.15.0-91-generic
options root=UUID=a1b2c3d4-e5f6-7890-abcd-ef1234567890 ro quiet

# /boot/efi/loader/entries/ubuntu-previous.conf
title   Ubuntu 22.04 LTS (Previous Kernel)
linux   /vmlinuz-5.15.0-88-generic
initrd  /initrd.img-5.15.0-88-generic
options root=UUID=a1b2c3d4-e5f6-7890-abcd-ef1234567890 ro
```

### 5.7 GRUB Legacy (GRUB 0.97) — Todavía en el Examen

```bash
# /boot/grub/menu.lst (or /boot/grub/grub.conf on RHEL5/CentOS5)
# NOTE: GRUB Legacy uses 0-based disk/partition numbering
# hd0 = first disk, 0 = first partition

default=0
timeout=10
splashimage=(hd0,0)/grub/splash.xpm.gz
hiddenmenu
password --md5 $1$abc$xyz123456789

title CentOS (2.6.32-754.el6.x86_64)
    root (hd0,0)
    kernel /vmlinuz-2.6.32-754.el6.x86_64 ro root=/dev/mapper/vg0-root rd_LVM_LV=vg0/root
    initrd /initramfs-2.6.32-754.el6.x86_64.img

title CentOS (Previous Kernel)
    root (hd0,0)
    kernel /vmlinuz-2.6.32-696.el6.x86_64 ro root=/dev/mapper/vg0-root
    initrd /initramfs-2.6.32-696.el6.x86_64.img

title Windows
    rootnoverify (hd0,1)
    chainloader +1
```

**Nomenclatura entre GRUB Legacy y GRUB2:**

| Concepto | GRUB Legacy | GRUB2 |
|---|---|---|
| Primer disco | `(hd0)` | `(hd0)` |
| Primera partición | `(hd0,0)` | `(hd0,1)` o `(hd0,msdos1)` o `(hd0,gpt1)` |
| Archivo de configuración | `menu.lst` / `grub.conf` | `grub.cfg` (autogenerado) |
| Comando de instalación | `grub-install` / `setup (hd0)` | `grub-install` / `grub2-install` |
| Instalación interactiva | `grub> setup (hd0)` | No se utiliza (todo vía `grub-install`) |
| Directiva del Kernel | `kernel` | `linux` / `linux16` |
| Contraseña | `password --md5` | `password_pbkdf2` |
| Edición de configuración | Edición directa | Editar `/etc/default/grub` + `/etc/grub.d/`, regenerar |

```bash
# GRUB Legacy interactive installation
$ grub
grub> root (hd0,0)
 Filesystem type is ext2fs, partition type 0x83
grub> setup (hd0)
 Checking if "/boot/grub/stage1" exists... yes
 Checking if "/boot/grub/stage2" exists... yes
 Checking if "/boot/grub/e2fs_stage1_5" exists... yes
 Running "embed /boot/grub/e2fs_stage1_5 (hd0)"... 27 sectors are embedded.
succeeded
 Running "install /boot/grub/stage1 (hd0) (hd0)1+27 p (hd0,0)/boot/grub/stage2 /boot/grub/menu.lst"... succeeded
Done.
grub> quit
```

---

## 6. Procedimientos de Recuperación del Sistema (System Recovery) (202.2 — Peso 4)

### 6.1 Targets / Modos de Recuperación

```
┌─────────────────────────────────────────────────────────────────┐
│                    RECOVERY MODE HIERARCHY                      │
│                                                                  │
│  ┌──────────────────┐                                           │
│  │ emergency.target │  Minimal: only root fs (ro), no services  │
│  │ init=/bin/bash    │  No networking, no logging                │
│  └────────┬─────────┘                                           │
│           │                                                      │
│  ┌────────▼─────────┐                                           │
│  │  rescue.target   │  Single-user: basic filesystems, some     │
│  │  runlevel 1 / s  │  services (sysinit.target, basic.target) │
│  └────────┬─────────┘                                           │
│           │                                                      │
│  ┌────────▼─────────┐                                           │
│  │multi-user.target │  Normal operation: all services, network  │
│  │  runlevel 3      │                                           │
│  └──────────────────┘                                           │
└─────────────────────────────────────────────────────────────────┘
```

### 6.2 Manuales de Procedimiento (Playbooks) de Escenarios de Recuperación

#### Escenario 1: Contraseña de Root Olvidada

```bash
# 1. Reboot, interrupt GRUB menu (press 'e' on desired entry)
# 2. Find the 'linux' line, append:
#    For systemd: rd.break    (breaks into initramfs before pivot_root)
#    For SysVinit: init=/bin/bash
# 3. Press Ctrl+X or F10 to boot

# === rd.break method (RHEL/CentOS) ===
# You're now in initramfs with real root at /sysroot

switch_root:/# mount -o remount,rw /sysroot
switch_root:/# chroot /sysroot

sh-4.4# passwd root
Changing password for user root.
New password: ********
Retype new password: ********
passwd: all authentication tokens updated successfully.

# If SELinux is enforcing, relabel on next boot:
sh-4.4# touch /.autorelabel

sh-4.4# exit
switch_root:/# exit
# System reboots

# === init=/bin/bash method ===
bash-5.1# mount -o remount,rw /
bash-5.1# passwd root
bash-5.1# touch /.autorelabel    # SELinux
bash-5.1# exec /sbin/init        # Or: sync; reboot -f
```

#### Escenario 2: `/etc/fstab` Corrupto que Impide el Boot

```bash
# System drops to emergency shell:
# "Welcome to emergency mode! After logging in, type "journalctl -xb" to view..."
# "Give root password for maintenance"

# Enter root password
root@(none):~# mount -o remount,rw /

root@(none):~# vi /etc/fstab
# Fix the broken entry (wrong UUID, missing filesystem, etc.)

# Verify:
root@(none):~# mount -a
# If no errors, the fstab is valid

root@(none):~# systemctl default
# Or: reboot
```

#### Escenario 3: GRUB Dañado — Reinstalación desde Live/Rescue

```bash
# Boot from live USB/CD or rescue media

# Identify root partition
$ lsblk
NAME        MAJ:MIN RM   SIZE RO TYPE MOUNTPOINT
sda           8:0    0   100G  0 disk
├─sda1        8:1    0   512M  0 part
├─sda2        8:2    0     1G  0 part
└─sda3        8:3    0  98.5G  0 part

$ vgscan
  Found volume group "vg0" using metadata type lvm2
$ vgchange -ay vg0
  2 logical volume(s) in volume group "vg0" now active

$ lvscan
  ACTIVE   '/dev/vg0/root' [90.00 GiB] inherit
  ACTIVE   '/dev/vg0/swap' [8.50 GiB] inherit

# Mount the system
$ mount /dev/vg0/root /mnt
$ mount /dev/sda2 /mnt/boot
$ mount /dev/sda1 /mnt/boot/efi   # If UEFI

# Mount pseudo-filesystems for chroot
$ mount --bind /dev /mnt/dev
$ mount --bind /dev/pts /mnt/dev/pts
$ mount --bind /proc /mnt/proc
$ mount --bind /sys /mnt/sys
$ mount --bind /run /mnt/run

# Enter chroot
$ chroot /mnt /bin/bash

# Reinstall GRUB
# BIOS:
bash-5.1# grub-install /dev/sda
Installing for i386-pc platform.
Installation finished. No error reported.

# UEFI:
bash-5.1# grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=centos
Installing for x86_64-efi platform.
Installation finished. No error reported.

# Regenerate config
bash-5.1# grub-mkconfig -o /boot/grub/grub.cfg
# Or: grub2-mkconfig -o /boot/grub2/grub.cfg (RHEL)
# Or: update-grub (Debian/Ubuntu)

# Regenerate initramfs (if needed)
bash-5.1# dracut --force --regenerate-all    # RHEL
bash-5.1# update-initramfs -u -k all          # Debian

# Exit and reboot
bash-5.1# exit
$ umount -R /mnt
$ reboot
```

#### Escenario 4: Kernel Panic — Hacer Boot del Kernel Anterior

```bash
# Option A: At GRUB menu, select "Advanced options" → choose previous kernel

# Option B: Set previous kernel as default
$ grub-set-default 'Advanced options for Ubuntu>Ubuntu, with Linux 5.15.0-88-generic'
# Or by index:
$ grub-set-default "1>2"

# Option C: One-time boot
$ grub-reboot "1>2"
$ reboot

# Option D: Edit /etc/default/grub
GRUB_DEFAULT="1>2"
$ update-grub
```

#### Escenario 5: Unit de systemd Dañada Bloqueando el Boot

```bash
# Boot with: systemd.unit=emergency.target (add at GRUB kernel line)

root@emergency:~# journalctl -xb --no-pager | grep -i fail
Jan 15 10:30:45 host systemd[1]: Failed to start Broken Service.
Jan 15 10:30:45 host systemd[1]: Dependency failed for Multi-User System.

root@emergency:~# systemctl status broken.service
● broken.service - Broken Service
     Loaded: loaded (/etc/systemd/system/broken.service; enabled; ...)
     Active: failed (Result: exit-code) since ...

# Mask the broken service
root@emergency:~# systemctl mask broken.service
Created symlink /etc/systemd/system/broken.service → /dev/null.

# Boot normally
root@emergency:~# systemctl default

# After investigation, fix and unmask
$ systemctl unmask broken.service
$ systemctl edit broken.service    # Override problematic directives
$ systemctl daemon-reload
$ systemctl start broken.service
```

---

## 7. Verificación y Runbook de Diagnóstico

### 7.1 Árbol de Decisión de Diagnóstico de Boot

```
SYSTEM FAILS TO BOOT
        │
        ▼
┌─── No video/POST? ──────────── Hardware/Firmware issue
│                                  Check BIOS/UEFI, IPMI/iLO console
│
├─── GRUB prompt (grub> or grub rescue>) ──── GRUB config issue
│       │
│       ├── grub> prompt: ls, set root, linux, initrd, boot
│       └── grub rescue>: set prefix, insmod normal, normal
│
├─── Kernel panic ──── Kernel/initramfs issue
│       │
│       ├── "VFS: Unable to mount root fs" → wrong root=, missing initramfs
│       ├── "Kernel panic - not syncing" → driver issue, rebuild initramfs
│       └── Boot previous kernel from GRUB
│
├─── Drops to emergency/rescue shell ──── systemd/fstab/unit issue
│       │
│       ├── Check: journalctl -xb
│       ├── Check: systemctl --failed
│       ├── Check: mount -a (fstab validation)
│       └── Fix and: systemctl default
│
└─── Hangs during service startup ──── Service dependency issue
        │
        ├── systemd.unit=emergency.target at GRUB
        ├── systemctl list-jobs (shows waiting jobs)
        ├── systemd-analyze critical-chain
        └── systemctl mask <hanging-service>
```

### 7.2 Comandos Esenciales de Diagnóstico

```bash
# === Boot logs ===
$ journalctl -b                    # Current boot
$ journalctl -b -1                 # Previous boot
$ journalctl -b --priority=err     # Only errors
$ journalctl -b -u myapp.service   # Specific unit boot log

# === dmesg (kernel ring buffer) ===
$ dmesg -T | head -30              # With human-readable timestamps
$ dmesg --level=err,warn           # Only errors and warnings
$ dmesg | grep -i 'fail\|error\|panic\|oom'

# === Boot process state ===
$ systemctl list-jobs              # Currently processing jobs
  JOB UNIT                         TYPE  STATE
  1   multi-user.target            start waiting
  2   NetworkManager-wait-online   start running
  3   myapp.service                start waiting

$ systemctl list-units --state=activating   # Stuck units
$ systemctl list-dependencies --after myapp.service

# === Verify GRUB installation ===
$ grub-install --recheck /dev/sda 2>&1
Installing for i386-pc platform.
Installation finished. No error reported.

# === Verify initramfs has required modules ===
$ lsinitramfs /boot/initrd.img-$(uname -r) | grep -E '(xfs|ext4|dm-mod|lvm)'
usr/lib/modules/5.15.0-91-generic/kernel/fs/xfs/xfs.ko
usr/lib/modules/5.15.0-91-generic/kernel/fs/ext4/ext4.ko
usr/lib/modules/5.15.0-91-generic/kernel/drivers/md/dm-mod.ko

# === Check for missing firmware ===
$ dmesg | grep -i firmware
[    2.345] i915 0000:00:02.0: Direct firmware load for i915/kbl_dmc_ver1_04.bin: No such file
[    2.345] i915 0000:00:02.0: Failed to load DMC firmware i915/kbl_dmc_ver1_04.bin.

# === Verify filesystem consistency before reboot ===
$ findmnt --verify
   Success, no errors or warnings detected

# === Check kernel command line actually used ===
$ cat /proc/cmdline
BOOT_IMAGE=/vmlinuz-5.15.0-91-generic root=/dev/mapper/vg0-root ro quiet splash

# === Verify current target ===
$ systemctl get-default
multi-user.target

$ systemctl is-system-running
running                  # or: degraded, maintenance, initializing

# === Check for masked services interfering ===
$ systemctl list-unit-files --state=masked
UNIT FILE                     STATE
cups.service                  masked
myapp-old.service             masked

# === Verify UEFI boot entries ===
$ efibootmgr -v
BootCurrent: 0003
BootOrder: 0003,0001,0000
Boot0003* ubuntu	HD(1,GPT,...)/File(\EFI\ubuntu\shimx64.efi)
```

### 7.3 Checklist de Hardening en Producción

```bash
# 1. Verify GRUB password is set
$ grep -r superusers /boot/grub/grub.cfg
set superusers="admin"

# 2. Verify grub.cfg permissions
$ stat -c '%a %U:%G' /boot/grub/grub.cfg
600 root:root

# 3. Verify recovery entries exist
$ grep -c menuentry /boot/grub/grub.cfg
5    # At least 2 kernel entries + recovery entries

# 4. Verify serial console is configured (for remote access)
$ grep -E 'GRUB_TERMINAL|GRUB_SERIAL' /etc/default/grub
GRUB_TERMINAL_OUTPUT="serial console"
GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"

# 5. Verify crashkernel is reserved
$ cat /sys/kernel/kexec_crash_size
167772160    # 160MB reserved

# 6. Verify all critical services are enabled
$ for svc in sshd crond rsyslog myapp; do
    systemctl is-enabled ${svc}.service 2>/dev/null || echo "WARN: ${svc} not enabled"
  done
sshd.service: enabled
crond.service: enabled
rsyslog.service: enabled
myapp.service: enabled

# 7. Verify no failed services
$ systemctl is-system-running
running

# 8. Document current boot configuration
$ grub2-editenv list                # RHEL
saved_entry=0
boot_success=1
kernelopts=root=/dev/mapper/vg0-root ro crashkernel=auto

$ bootctl list                      # systemd-boot
```

---

## 8. Trampas Clave del Examen y Matices

| Trampa | Entendimiento Correcto |
|---|---|
| `update-grub` vs `grub-mkconfig` | `update-grub` es un wrapper en Debian alrededor de `grub-mkconfig -o /boot/grub/grub.cfg` |
| `grub-install` vs `grub2-install` | Es la misma herramienta; nomenclatura `grub2-*` en RHEL/CentOS/Fedora |
| Numeración de particiones en GRUB2 | Comienza en 1 (`hd0,msdos1`), a diferencia de GRUB Legacy que comienza en 0 (`hd0,0`) |
| `/etc/grub.d/40_custom` vs editar `grub.cfg` | **Nunca editar `grub.cfg` directamente** — es autogenerado |
| `systemctl enable` | Crea un symlink en `.wants/` — **no** inicia el servicio |
| `systemctl mask` vs `disable` | `mask` → symlink a `/dev/null` (impide cualquier inicio); `disable` → solo remueve el symlink en `.wants/` |
| `telinit q` | Recarga `/etc/inittab` — NO cambia el runlevel (a menudo confundido con `telinit Q`) |
| Nomenclatura de enlaces en SysVinit | `S` = Start, `K` = Kill; número = prioridad (un valor menor se ejecuta primero) |
| `rd.break` vs `init=/bin/bash` | `rd.break` se detiene en initramfs (el root real en `/sysroot`); `init=` reemplaza a PID 1 por completo |
| `emergency.target` vs `rescue.target` | emergency = solo el sistema de archivos root (ro), sin servicios; rescue = basic.target activo, prompt de sulogin |

---

## 9. Referencias

1. **LPIC-2 Objetivos del Examen 201-450 & 202-450 (v4.5)**
   https://www.lpi.org/our-certifications/lpic-2-overview/

2. **Manual de GNU GRUB (GRUB 2)**
   https://www.gnu.org/software/grub/manual/grub/

3. **Documentación Oficial de systemd**
   https://www.freedesktop.org/software/systemd/man/

4. **systemd.service(5) — Configuración de Unit de Servicio**
   https://www.freedesktop.org/software/systemd/man/systemd.service.html

5. **systemd.unit(5) — Directivas de Unit File**
   https://www.freedesktop.org/software/systemd/man/systemd.unit.html

6. **systemd.special(7) — Units Especiales de systemd (Targets)**
   https://www.freedesktop.org/software/systemd/man/systemd.special.html

7. **SYSLINUX Wiki**
   https://wiki.syslinux.org/wiki/index.php

8. **dracut(8) — Herramienta de Bajo Nivel para Generar initramfs**
   https://man7.org/linux/man-pages/man8/dracut.8.html

9. **update-initramfs(8) — Gestión de initramfs en Debian**
   https://manpages.debian.org/bookworm/initramfs-tools-core/update-initramfs.8.en.html

10. **bootctl(1) — Gestor de systemd-boot**
    https://www.freedesktop.org/software/systemd/man/bootctl.html

11. **efibootmgr(8) — Gestor de Boot en UEFI**
    https://github.com/rhboot/efibootmgr

12. **Linux From Scratch — Proceso de Boot**
    https://www.linuxfromscratch.org/lfs/view/stable/chapter09/usage.html

13. **Red Hat Enterprise Linux 8 — Configuración y Gestión del Boot Loader**
    https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/8/html/system_design_guide/assembly_configuring-and-managing-the-boot-loader_system-design-guide

14. **Arch Wiki — Proceso de Boot**
    https://wiki.archlinux.org/title/Arch_boot_process