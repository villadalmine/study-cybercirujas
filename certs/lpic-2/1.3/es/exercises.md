# LPIC-2 Examen 201-450 (v4.5) — Tema 201.3: System Startup

**Peso:** 3  
**Público objetivo:** SREs Senior, Engineers de Plataforma y Engineers de Sistemas preparándose para la Certificación LPIC-2.  
**Fuentes de referencia oficiales:**
* [LPI LPIC-2 Objectives v4.5](https://www.lpi.org/our-certifications/lpic-2-overview/)
* [GNU GRUB Manual v2.06](https://www.gnu.org/software/grub/manual/grub/grub.html)
* [Linux Kernel Boot Protocol Documentation](https://www.kernel.org/doc/html/latest/x86/boot.html)
* [freedesktop.org systemd Boot Process & Bootup Specification](https://www.freedesktop.org/software/systemd/man/latest/bootup.html)

---

## 1. Deep Dive Mechanics: GRUB2 Architecture, Stage 1/1.5/2, & Initramfs Internals

### Visión general de la arquitectura
La secuencia de arranque de Linux x86/x86_64 transfiere la ejecución a través de límites distintos de hardware, bootloader, espacio de kernel y espacio de usuario:

```
[ BIOS / UEFI ] 
       │
       ▼
[ GRUB2 Stage 1 (MBR / EFI App) ] ──> Loads core.img (Stage 1.5 - Filesystem Drivers)
       │
       ▼
[ GRUB2 Stage 2 (`/boot/grub/grub.cfg`) ] ──> Loads VMLINUZ + INITRAMFS into Memory
       │
       ▼
[ Linux Kernel Initialization ] ──> Mounts initramfs as temporary rootfs (`/`)
       │
       ▼
[ initramfs `/init` script ] ──> Loads storage/NVMe/RAID drivers, mounts real root (`/sysroot`)
       │
       ▼
[ `pivot_root` / `switch_root` ] ──> Hands control over to systemd (`/sbin/init` PID 1)
```

1. **BIOS/MBR Legacy Boot:** El BIOS lee el Sector 0 (512 bytes) del disco de arranque en la RAM (`0x7C00`). El MBR contiene el Stage 1 (`boot.img`, 446 bytes). El Stage 1 carga `core.img` (Stage 1.5) almacenado en el espacio post-MBR gap (sectores 1–2047) o en espacio particionado, el cual contiene drivers de sistema de archivos (ej., ext4, xfs) para leer `/boot/grub`.
2. **UEFI Boot:** El firmware ejecuta `grubx64.efi` directamente desde la EFI System Partition (ESP formateada como FAT32, montada en `/boot/efi`). Se omiten los gaps de Stage 1/1.5.
3. **Stage 2:** Carga módulos visuales del menú y analiza `/boot/grub/grub.cfg` (o `/boot/grub2/grub.cfg` en sistemas basados en RHEL).
4. **Ejecución de Initramfs:** El initramfs es un archivo cpio comprimido cargado en la RAM junto con `vmlinuz`. El kernel ejecuta `/init` dentro del initramfs, el cual detecta dispositivos de bloques, ejecuta la activación del stack de almacenamiento (LVM, LUKS, RAID), monta el sistema de archivos raíz persistente en modo solo lectura en `/sysroot`, y ejecuta `switch_root` para hacer la transición a systemd (`PID 1`).

---

### Ejercicio práctico 1.1: GRUB2 Configuration Architecture and Binary Inspection

En este ejercicio, analizarás la disposición física de GRUB2 en un disco MBR/GPT, modificarás los valores predeterminados de GRUB2 a través de `/etc/default/grub` y `/etc/grub.d/`, y generarás un `/boot/grub/grub.cfg` sintácticamente válido.

#### Step 1: Inspect the MBR/Boot Sector Header
Ejecutá `dd` y `file` para verificar la ubicación de la firma del bootloader en tu disco de sistema (`/dev/sda` o `/dev/vda`).

```bash
sudo dd if=/dev/vda bs=512 count=1 2>/dev/null | hexdump -C -n 512
```

*Fragmento de salida esperada:*
```text
000001b0  00 00 00 00 00 00 00 00  5b 3f c1 2a 00 00 80 04  |........[?.*....|
000001c0  01 04 83 fe c2 ff 00 08  00 00 00 00 20 04 00 00  |............ ...|
...
000001f0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 55 aa  |..............U.|
```
*Nota:* La firma `55 aa` en el offset `0x01FE` confirma un sector MBR boteable.

#### Step 2: Edit GRUB2 Defaults `/etc/default/grub`
Abrí `/etc/default/grub` en un editor y modificá/agregá parámetros para configurar el registro serie (serial logging), los parámetros del kernel y el timeout del menú:

```bash
sudo cat << 'EOF' | sudo tee /etc/default/grub
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR="$(lsb_release -i -s 2>/dev/null || echo Debian)"
GRUB_DEFAULT=0
GRUB_DISABLE_SUBMENU=true
GRUB_TERMINAL_OUTPUT="console"
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash systemd.unified_cgroup_hierarchy=1"
GRUB_CMDLINE_LINUX="console=tty0 console=ttyS0,115200n8"
EOF
```

#### Step 3: Create a Custom GRUB Script in `/etc/grub.d/`
Creá un script personalizado ejecutable `/etc/grub.d/41_custom_rescue` para agregar una entrada de arranque personalizada o un diagnóstico de memoria dedicado.

```bash
sudo cat << 'EOF' | sudo tee /etc/grub.d/41_custom_rescue
#!/bin/sh
exec tail -n +3 $0
# Custom Boot Entry for Standalone Emergency Kernel
menuentry 'SRE Emergency Debug Kernel' --class linux --class os {
    insmod gzio
    insmod part_msdos
    insmod ext2
    set root='hd0,msdos1'
    linux /vmlinuz-custom root=/dev/vda1 ro single console=ttyS0,115200
    initrd /initrd.img-custom
}
EOF

sudo chmod +x /etc/grub.d/41_custom_rescue
```

#### Step 4: Recompile `/boot/grub/grub.cfg`
Reconstruí el archivo de configuración activo utilizando una comprobación de rutas independiente de la distribución (distro-agnostic).

```bash
# On Debian/Ubuntu systems:
sudo grub-mkconfig -o /boot/grub/grub.cfg

# On RHEL/CentOS/Rocky systems (Legacy MBR vs UEFI):
# MBR: sudo grub2-mkconfig -o /boot/grub2/grub.cfg
# UEFI: sudo grub2-mkconfig -o /boot/efi/EFI/redhat/grub.cfg
```

*Salida esperada:*
```text
Generating grub configuration file ...
Found linux image: /boot/vmlinuz-6.8.0-40-generic
Found initrd image: /boot/initrd.img-6.8.0-40-generic
Adding boot menu entry for UEFI Firmware Settings ...
done
```

---

### Ejercicio práctico 1.2: Initramfs Inspection, Extraction, and Custom Hook Injection

En este ejercicio, desempaquetarás un archivo cpio `initramfs`/`initrd` activo, inspeccionarás su sistema de archivos raíz interno, modificarás `/init` y reconstruirás la imagen manualmente usando `cpio` y `dracut` / `update-initramfs`.

#### Step 1: Locate and Determine Compression of Current Initramfs
Determiná el formato de compresión de tu imagen de arranque actual.

```bash
ls -lh /boot/initrd.img-$(uname -r) || ls -lh /boot/initramfs-$(uname -r).img
file /boot/initrd.img-$(uname -r)
```

*Salida esperada:*
```text
/boot/initrd.img-6.8.0-40-generic: ASCII cpio archive (SVR4 with no CRC)
```
*Nota:* Los archivos initramfs modernos a menudo consisten en microcódigo no comprimido inicial (CPU AMD/Intel) adjuntado antes de un archivo cpio principal comprimido (Zstandard, gzip o xz).

#### Step 2: Unpack Early Microcode and Main Archive
Creá un espacio de trabajo temporal en `/tmp/initramfs_inspect` y desempaquetá el archivo usando `lsinitramfs`, `uncompress` o `unpk`.

```bash
mkdir -p /tmp/initramfs_inspect && cd /tmp/initramfs_inspect

# Using unmkinitramfs (Debian/Ubuntu tool that extracts microcode + main tree):
unmkinitramfs /boot/initrd.img-$(uname -r) .

ls -la
```

*Salida esperada:*
```text
drwxr-xr-x 3 root root 4096 Aug  6 10:15 early
drwxr-xr-x 8 root root 4096 Aug  6 10:15 main
```

#### Step 3: Inspect `/init` and Embedded Binary Drivers inside `main/`
Explorá el sistema de archivos raíz generado del initramfs.

```bash
cd /tmp/initramfs_inspect/main
ls -la init
head -n 25 init
```

*Fragmento de salida esperada:*
```bash
#!/bin/sh
[ -d /dev ] || mkdir -p /dev
[ -d /sys ] || mkdir -p /sys
[ -d /proc ] || mkdir -p /proc
mount -t sysfs -o nosuid,noexec,nodev sysfs /sys
mount -t proc -o nosuid,noexec,nodev proc /proc
...
```

#### Step 4: Rebuild Initramfs Image using Distribution Native Tooling
Volvé a generar el archivo initramfs predeterminado para el kernel en ejecución actual.

```bash
# On Debian / Ubuntu:
sudo update-initramfs -u -k $(uname -r)

# On RHEL / Fedora / Rocky Linux:
sudo dracut --force /boot/initramfs-$(uname -r).img $(uname -r)
```

*Salida esperada:*
```text
update-initramfs: Generating /boot/initrd.img-6.8.0-40-generic
```

---

### Preguntas de verificación — Sección 1

1. **Question 1.1:** Durante un arranque MBR legacy, ¿cuál es el rol físico exacto de `core.img` (Stage 1.5), dónde se almacena cuando se utiliza un esquema de disco estándar GPT o MBR, y por qué es necesario antes de leer `/boot/grub/grub.cfg`?
2. **Question 1.2:** Si `update-initramfs` o `dracut` se ejecuta sin incluir los módulos del controlador de almacenamiento (ej., `nvme`, `ahci` o `virtio_blk`), ¿en qué fase exacta del proceso de arranque fallará el sistema y qué mensaje de error de kernel panic se imprimirá en la consola?

---

## 2. Advanced Kernel Boot Parameters & Diagnostic Recovery

### Mecánica arquitectónica de la inyección de la línea de comandos del kernel
El bootloader GRUB2 pasa opciones de la línea de comandos del kernel a través de registros de memoria especificados por el Linux Boot Protocol de x86 (`struct setup_header`). El kernel analiza estos parámetros durante `setup_arch()` y `start_kernel()` antes de inicializar los subsistemas de hardware.

```
+-----------------------------------------------------------------------------+
|                                GRUB2 Engine                                 |
+-----------------------------------------------------------------------------+
                                       |
                   Appends text parameters from grub.cfg
                                       |
                                       v
+-----------------------------------------------------------------------------+
| Linux Kernel (`vmlinuz`) Command Line Parameters                             |
| E.g.: `root=/dev/mapper/vg0-root ro init=/bin/bash systemd.unit=emergency`  |
+-----------------------------------------------------------------------------+
                                       |
                     Parsed during kernel `start_kernel()`
                                       |
            +--------------------------+--------------------------+
            |                                                     |
            v                                                     v
+-----------------------+                             +-----------------------+
|  Initramfs `/init`    |                             | Systemd (`PID 1`)     |
|  Interprets `rd.*`    |                             | Interprets `systemd.*`|
+-----------------------+                             +-----------------------+
```

Parámetros clave de diagnóstico:
* `init=/bin/bash`: Omite `systemd` por completo. El kernel ejecuta `/bin/bash` puro como PID 1 directamente desde el sistema de archivos raíz.
* `rd.break`: Detiene la ejecución dentro del entorno `initramfs` justo antes de transferir el control al sistema de archivos raíz real (`/sysroot`).
* `systemd.unit=rescue.target` / `systemd.unit=emergency.target`: Le indica a systemd que arranque en targets mínimos aislados (modos monousuario / single-user).
* `systemd.debug_shell=1`: Genera un root shell no autenticado en `tty9` (`Ctrl+Alt+F9`) durante la ejecución de la secuencia de arranque de systemd.

---

### Ejercicio práctico 2.1: Simulating Root Password Recovery via `rd.break` and `init=/bin/bash`

En este ejercicio, aprenderás los pasos exactos ejecutados durante el mantenimiento de emergencia del sistema de archivos raíz y los procedimientos de restablecimiento de contraseña.

#### Step 1: Simulate `rd.break` Execution Workflow (RHEL/Dracut Style)
1. Reiniciá el nodo de destino e interrumpí GRUB2 en el menú de selección presionando `e`.
2. Localizá la línea que comienza con `linux`, `linux16` o `linuxefi`.
3. Agregá `rd.break` al final de la línea de comandos `linux`.
4. Presioná `Ctrl+X` o `F10` para arrancar.

*Ejecución de shell simulada al alcanzar el prompt de emergencia de initramfs:*
```bash
# 1. System drops into switch_root breakpoint
switch_root:/# 

# 2. Remount /sysroot with read-write permissions
switch_root:/# mount -o remount,rw /sysroot

# 3. Chroot into the actual operating system target root
switch_root:/# chroot /sysroot

# 4. Perform administration (e.g., reset root password)
sh-5.1# passwd root
Enter new UNIX password:
Retype new UNIX password:
passwd: password updated successfully

# 5. Relabel SELinux context if SELinux is active
sh-5.1# touch /.autorelabel

# 6. Exit chroot and exit initramfs to resume normal boot
sh-5.1# exit
switch_root:/# exit
```

#### Step 2: Simulate Direct Shell Override `init=/bin/bash` (Debian/Ubuntu/SysV Style)
1. Reiniciá y presioná `e` en el menú de GRUB2.
2. Reemplazá `ro quiet splash` por `rw init=/bin/bash`.
3. Presioná `Ctrl+X` para arrancar.

*Ejecución simulada:*
```bash
# System boots directly to PID 1 bash shell without mounting secondary filesystems
root@node:(none):/# id
uid=0(root) gid=0(root) groups=0(root)

root@node:(none):/# ps -ef
UID          PID PPID  C STIME TTY          TIME CMD
root           1    0  0 10:16 ?        00:00:00 /bin/bash

# Remount / read-write if booted in ro mode:
root@node:(none):/# mount -o remount,rw /

# Update password
root@node:(none):/# passwd

# Flush changes to disk before forced powercycle
root@node:(none):/# sync
root@node:(none):/# exec /sbin/reboot -f
```

---

### Ejercicio práctico 2.2: Advanced Boot Performance Analysis and Service Failure Tracing

En este ejercicio, analizarás el rendimiento de arranque del sistema, localizarás cuellos de botella de arranque y aislarás unidades con fallas usando `systemd-analyze` y `journalctl`.

#### Step 1: Measure Boot Time Breakdown
Ejecutá `systemd-analyze` para medir el tiempo transcurrido en Firmware, Loader, Kernel, Initrd y Userspace.

```bash
systemd-analyze
```

*Salida esperada:*
```text
Startup finished in 1.412s (firmware) + 2.105s (loader) + 1.844s (kernel) + 4.120s (initrd) + 6.311s (userspace) = 15.794s 
graphical.target reached after 6.280s in userspace.
```

#### Step 2: Identify Slowest Initialization Services
Determiná qué servicios están causando retrasos en la inicialización.

```bash
systemd-analyze blame | head -n 10
```

*Salida esperada:*
```text
2.410s NetworkManager-wait-online.service
1.105s dev-vda1.device
0.844s snapd.service
0.612s systemd-logind.service
0.410s ebtables.service
```

#### Step 3: Plot the Critical Chain of Boot Services
Examiná la cadena de dependencias exacta que retrasa el estado del target final.

```bash
systemd-analyze critical-chain graphical.target
```

*Salida esperada:*
```text
graphical.target @6.280s
└─multi-user.target @6.279s
  └─docker.service @4.810s +1.468s
    └─network.target @4.801s
      └─NetworkManager.service @3.210s +1.589s
        └─dbus.service @3.190s
          └─basic.target @3.150s
```

#### Step 4: Inspect System Boot Logs for Specific Reboots
Consultá los registros de la sesión de arranque actual frente a la anterior usando `journalctl`.

```bash
# List recorded boot sessions
journalctl --list-boots

# View logs from the current boot for priority level Error or critical
journalctl -b 0 -p err..emerg

# Trace boot logs for unit failures from the prior boot session (-1)
journalctl -b -1 -u systemd-modules-load.service
```

---

### Preguntas de verificación — Sección 2

1. **Question 2.1:** ¿Cuál es la diferencia fundamental entre arrancar con `rd.break` versus arrancar con `init=/bin/bash` con respecto al entorno, la ejecución de PID 1 y la estructura del sistema de archivos?
2. **Question 2.2:** Si un servidor se cuelga indefinidamente en el arranque con `NetworkManager-wait-online.service` estancando la secuencia de inicialización, ¿qué comando de systemd se puede ejecutar para deshabilitar este comportamiento de bloqueo específico sin romper la conectividad de red estándar de `NetworkManager`?

---

## 3. Customizing Boot Loaders & Init Mechanisms Comparison (SysVinit vs. systemd vs. Upstart vs. OpenRC)

### Matriz de análisis comparativo

| Característica / Subsistema | SysVinit | Upstart | systemd | OpenRC |
| :--- | :--- | :--- | :--- | :--- |
| **Configuración principal** | `/etc/inittab`, `/etc/init.d/` | `/etc/init/` (`.conf` jobs) | `/etc/systemd/system/`, `/lib/systemd/system/` | `/etc/conf.d/`, `/etc/init.d/` |
| **Concurrencia / Paralelismo**| Secuencial (Basado en shell scripts según runlevels) | Basado en eventos (Inicio asincrónico de trabajos) | Concurrente (Activación por Socket y D-Bus, cgroups dinámicos) | Inicio paralelo basado en dependencias |
| **Rastreo de procesos** | Archivos PID (frágil, sujeto a la reutilización de PID) | Rastreo PTRACE (`expect fork/daemon`) | Control Groups (`cgroups`) | Linux cgroups / rastreo de PID |
| **Equivalente de Target / Estado**| Runlevels (`0` a `6`) | Runlevels / Señales de eventos | Targets (unidades `.target`) | Runlevels (`default`, `boot`, `nonetwork`) |
| **Consulta de estado de servicio** | `/sbin/service <name> status` | `status <job>` | `systemctl status <name>` | `rc-service <name> status` |

---

### Mapeo de Runlevel a Target de systemd

```
+-------------------+--------------------------------+----------------------------------------+
| SysVinit Runlevel | systemd Target Unit            | Description                            |
+-------------------+--------------------------------+----------------------------------------+
| Runlevel 0        | `poweroff.target`              | Shuts down and powers off the system.  |
| Runlevel 1 / S    | `rescue.target`                | Single-user mode (minimal maintenance).|
| Runlevel 2        | `multi-user.target`            | Multi-user text mode (without networking|
|                   |                                | on SysV Debian; standard on systemd).  |
| Runlevel 3        | `multi-user.target`            | Multi-user non-graphical networking mode|
| Runlevel 4        | `multi-user.target`            | User-defined / Custom.                 |
| Runlevel 5        | `graphical.target`             | Multi-user graphical UI mode (X11/Wayland)|
| Runlevel 6        | `reboot.target`                | Reboots the machine.                   |
+-------------------+--------------------------------+----------------------------------------+
```

---

### Ejercicio práctico 3.1: SysVinit Runlevel Manipulation vs. systemd Target Management

En este ejercicio, configurarás los targets de arranque predeterminados del sistema, cambiarás de target en tiempo de ejecución y escribirás un servicio nativo personalizado como boot hook para systemd.

#### Step 1: Check and Change the Default System Boot Target
Inspeccioná el enlace simbólico del target de arranque predeterminado `/etc/systemd/system/default.target`.

```bash
# Query active default target
systemctl get-default

# Change default boot mode to Multi-User Non-Graphical (Runlevel 3 equivalent)
sudo systemctl set-default multi-user.target

# Verify symlink target path
ls -l /etc/systemd/system/default.target
```

*Salida esperada:*
```text
multi-user.target
lrwxrwxrwx 1 root root 36 Aug  6 10:16 /etc/systemd/system/default.target -> /lib/systemd/system/multi-user.target
```

#### Step 2: Switch Execution Targets Dynamically
Cambia el estado del sistema en ejecución al modo rescue sin reiniciar.

```bash
# Isolate rescue target (terminates non-essential services and drops to single-user shell)
sudo systemctl isolate rescue.target
```

Para volver al modo multi-user:
```bash
sudo systemctl isolate multi-user.target
```

#### Step 3: Build a Complete Native systemd Boot Hook Service Manifest
Creá una unidad de servicio personalizada `/etc/systemd/system/sre-boot-audit.service` que se ejecute temprano durante la fase de arranque antes de la activación de la red.

```bash
sudo cat << 'EOF' | sudo tee /etc/systemd/system/sre-boot-audit.service
[Unit]
Description=SRE Boot Validation & Telemetry Collector
Documentation=https://internal.wiki.sre/boot-audit
DefaultDependencies=no
Before=sysinit.target
After=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/sre-boot-audit.sh

[Install]
WantedBy=sysinit.target
EOF
```

Creá el script ejecutable correspondiente para ExecStart:

```bash
sudo cat << 'EOF' | sudo tee /usr/local/bin/sre-boot-audit.sh
#!/bin/bash
set -euo pipefail
LOGFILE="/var/log/sre-boot-audit.log"

echo "[$(date -u +'%Y-%m-%d %H:%M:%SZ')] SRE Boot Audit Triggered" >> "$LOGFILE"
echo "Booted Kernel: $(uname -r)" >> "$LOGFILE"
echo "Root Storage State:" >> "$LOGFILE"
df -h / >> "$LOGFILE"
EOF

sudo chmod +x /usr/local/bin/sre-boot-audit.sh
```

Habilitá la unidad de servicio para la ejecución durante el arranque:

```bash
sudo systemctl daemon-reload
sudo systemctl enable sre-boot-audit.service
```

*Salida esperada:*
```text
Created symlink /etc/systemd/system/sysinit.target.wants/sre-boot-audit.service → /etc/systemd/system/sre-boot-audit.service.
```

---

### Ejercicio práctico 3.2: Bootloader Installation & Initrd Rebuilding Workflows across Distro Families

En este ejercicio, dominarás los comandos de instalación de bajo nivel requeridos para escribir binarios de GRUB2 en las estructuras del disco y reconstruir ramdisks.

#### Step 1: Re-install GRUB2 Boot Sector (MBR/GPT Legacy)
Escribí binarios de GRUB2 directamente en las estructuras de dispositivos de disco (`/dev/vda` o `/dev/sda`).

```bash
# On Debian/Ubuntu:
sudo grub-install /dev/vda

# On RHEL/Rocky Linux:
sudo grub2-install /dev/vda
```

*Salida esperada:*
```text
Installing for i386-pc platform.
Installation finished. No error reported.
```

#### Step 2: Install GRUB2 to UEFI System Partition (ESP)
Reinstalá los binarios UEFI de GRUB2 apuntando a un directorio ESP montado (`/boot/efi`).

```bash
sudo grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB --recheck
```

*Salida esperada:*
```text
Installing for x86_64-efi platform.
Installation finished. No error reported.
```

---

### Preguntas de verificación — Sección 3

1. **Question 3.1:** En SysVinit, ejecutar `init 6` activa un reinicio del sistema. ¿Qué comando exacto de systemd aísla el target de reinicio y qué archivo controla el mapeo de compatibilidad con el `/etc/inittab` heredado bajo systemd?
2. **Question 3.2:** ¿Cuál es la función técnica de `DefaultDependencies=no` en un archivo de unidad de servicio personalizado de systemd creado para la inicialización temprana del arranque?

---

## 4. Comprehensive Hands-on Troubleshooting Scenario

### Escenario de incidente de producción
Se te encomienda la tarea de recuperar un servidor Linux empresarial que no logra completar su secuencia de arranque después de una actualización del kernel y del driver de almacenamiento. La máquina se cuelga durante el inicio mostrando la siguiente salida de consola:

```text
[   4.120591] dracut-initqueue[482]: Warning: dracut-initqueue timeout - starting timeout scripts
[   4.121102] dracut-initqueue[482]: Warning: Could not boot.
[   4.122001] dracut-initqueue[482]: Warning: /dev/mapper/rhel-root does not exist
Starting Dracut Emergency Shell...
Warning: /dev/mapper/rhel-root does not exist

Generating "/run/initramfs/rdsosreport.txt"

Entering emergency mode. Exit the shell to continue.
Type "journalctl" to view system logs.
dracut:/#
```

### Tareas de diagnóstico y resolución
1. Ejecutá comandos de diagnóstico dentro del shell de emergencia de Dracut para inspeccionar los dispositivos de bloques disponibles y los grupos de volúmenes LVM.
2. Determiná por qué `/dev/mapper/rhel-root` no fue activado por el initramfs.
3. Activá manualmente el grupo de volúmenes LVM y completá la transferencia de arranque al sistema raíz real.
4. Repará el sistema de forma permanente dentro del SO en ejecución para garantizar que los futuros arranques tengan éxito automáticamente.

#### Task 1 execution steps:
```bash
# Check loaded block storage drivers and existing block devices
dracut:/# lsblk
dracut:/# lvm pvscan
dracut:/# lvm vgscan
dracut:/# lvm lvscan
```

#### Task 2 execution steps:
```bash
# If volume groups are inactive (showing 'inactive'):
dracut:/# lvm vgchange -ay rhel
  2 logical volume(s) in volume group "rhel" now active

# Verify device node creation:
dracut:/# ls -l /dev/mapper/rhel-root
lrwxrwxrwx 1 root root 7 Aug  6 10:16 /dev/mapper/rhel-root -> ../dm-0
```

#### Task 3 execution steps:
```bash
# Resume initramfs execution sequence
dracut:/# exit
```

#### Task 4 execution steps (Inside recovered OS):
Reconstruí el initramfs para incluir los módulos de almacenamiento/LVM requeridos.

```bash
sudo dracut --add "lvm" --force /boot/initramfs-$(uname -r).img $(uname -r)
```

---

<details>
<summary><b>Hacé clic para desplegar: Respuestas y explicaciones técnicas detalladas</b></summary>

### Respuestas de la Sección 1

* **Respuesta 1.1:**
  * **Rol:** `core.img` (Stage 1.5) contiene los drivers de sistema de archivos (ej., `ext4`, `xfs`, `btrfs`, `lvm`, `mdraid`) necesarios para acceder a `/boot/grub/` en la partición raíz. Stage 1 (`boot.img`) está limitado a 446 bytes en el MBR y solo puede ejecutar lecturas de sectores codificadas rígidamente (hardcoded).
  * **Ubicación de almacenamiento:** En discos particionados con MBR, `core.img` se almacena sin formato en el **post-MBR gap** (sectores no particionados entre el Sector 1 y el Sector 2047, antes de la primera partición que comienza en el Sector 2048). En discos GPT, reside dentro de una **BIOS Boot Partition** dedicada (marcada con el GUID `21686148-64C4-4665-870D-14D575017F0E` o la flag `bios_grub`, típicamente de 1MB de tamaño).
  * **Por qué es necesario:** Stage 1 carece de código de abstracción de sistema de archivos. Sin `core.img` analizando el formato de disco subyacente, GRUB no puede encontrar ni abrir `/boot/grub/grub.cfg` para renderizar el menú de arranque.

* **Respuesta 1.2:**
  * **Fase:** La falla ocurre durante la **fase de initramfs** inmediatamente después de que el kernel transfiere el control a `/init` en la RAM, cuando `/init` intenta descubrir dispositivos de bloques y montar el sistema de archivos raíz persistente real en `/sysroot`.
  * **Mensaje de error:** El kernel/initramfs emitirá:  
    `Kernel panic - not syncing: VFS: Unable to mount root fs on unknown-block(0,0)`  
    o un error en el shell de emergencia de Dracut:  
    `Warning: Could not boot. /dev/mapper/... does not exist`.

---

### Respuestas de la Sección 2

* **Respuesta 2.1:**
  * **`rd.break`:** Interrumpe la ejecución **dentro del initramfs** antes de que ocurra el cambio al sistema de archivos raíz real. El sistema de archivos raíz se encuentra en `/sysroot` y está montado en modo **solo lectura**. Debés ejecutar `mount -o remount,rw /sysroot` y `chroot /sysroot` para interactuar con los archivos del sistema. El shell de initramfs se ejecuta bajo un entorno de ramdisk efímero.
  * **`init=/bin/bash`:** Omite `systemd` por completo e instruye al kernel a lanzar `/bin/bash` directamente desde el **sistema de archivos raíz real** como **PID 1**. La ejecución de initramfs ha finalizado, `/` es la raíz real del disco (típicamente montada en modo solo lectura inicialmente) y no se inician servicios de systemd, listeners de sockets, demonios de registro (logging) ni montajes secundarios (como `/var` o `/home`).

* **Respuesta 2.2:**
  * Para evitar que `NetworkManager-wait-online.service` retrase el arranque del sistema, ejecutá:
    ```bash
    sudo systemctl disable NetworkManager-wait-online.service
    # Or mask it entirely:
    sudo systemctl mask NetworkManager-wait-online.service
    ```
    Esto lo elimina de la ruta de dependencias de `network-online.target` sin detener el demonio principal `NetworkManager.service`.

---

### Respuestas de la Sección 3

* **Respuesta 3.1:**
  * **Comando de systemd:** `systemctl isolate reboot.target` (o el alias estándar `systemctl reboot`).
  * **Archivo de mapeo de compatibilidad:** Enlaces simbólicos (symlinks) `/lib/systemd/system/runlevelX.target` (ej., `runlevel3.target` -> `multi-user.target`) junto con `/etc/systemd/system/default.target`. Los comandos heredados como `init 3` o `telinit 5` son interceptados por systemd y traducidos internamente a `systemctl isolate runlevelX.target`.

* **Respuesta 3.2:**
  * De forma predeterminada, cada unidad de systemd incluye implícitamente dependencias como `After=basic.target`, `Requires=basic.target`, `Wants=systemd-journald.socket`, etc.
  * Configurar `DefaultDependencies=no` **deshabilita estas dependencias automáticas predeterminadas de ordenamiento y requerimientos**. Esto es estrictamente requerido para servicios de arranque temprano (tales como los que se ejecutan antes de `sysinit.target` o durante el montaje de sistemas de archivos) para evitar bucles de dependencia (deadlocks) durante la inicialización del sistema.

---

### Solución del escenario de la Sección 4

* **Análisis de causa raíz:** El problema fue causado por la falta de un módulo de kernel de LVM o un driver del adaptador de bus de host (HBA) de almacenamiento dentro de la imagen cpio del initramfs tras una actualización, lo que impidió que el initramfs escaneara el almacenamiento de bloques y descubriera el Volume Group que contiene el volumen lógico `/dev/mapper/rhel-root`.
* **Verificación de la resolución:** Activar manualmente el grupo de volúmenes a través de `lvm vgchange -ay` hizo que `/dev/mapper/rhel-root` estuviera disponible en `/dev/mapper/`, permitiendo que `/init` completara el montaje de `/sysroot`. Reconstruir la imagen usando `dracut --add "lvm" --force` actualizó permanentemente el archivo cpio de arranque con los hooks de autoactivación necesarios.

</details>