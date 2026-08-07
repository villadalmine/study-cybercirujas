# Guía de Estudio de LPI BSD Specialist (702-100)
## Tema 711.1: Instalación del Sistema Operativo BSD
**Peso del Examen:** 5  
**Rol Objetivo:** Arquitecto Principal de Plataforma / Senior SRE  

---

## 1. Motivación y Problema Arquitectural de Producción

### 1.1 Contexto de Producción: Aprovisionamiento Automatizado de Infraestructura a Escala
En los entornos empresariales modernos nativos de la nube y bare-metal, aprovisionar sistemas operativos manualmente mediante asistentes de instalación interactivos es inaceptable. La Ingeniería de Confiabilidad del Sitio (Site Reliability Engineering - SRE) exige pipelines de despliegue idempotentes, reproducibles y completamente automatizados capaces de realizar el bootstrapping de cientos de nodos físicos o hipervisores mediante Preboot Execution Environment (PXE) o medios de instalación personalizados.

La instalación del sistema operativo a través de los principales sabores de BSD—**FreeBSD**, **OpenBSD** y **NetBSD**—presenta desafíos arquitecturales únicos que difieren significativamente de las distribuciones GNU/Linux (por ejemplo, Anaconda, Cloud-Init o Preseed):

1. **Topología de Bootloader & Consola**: Los servidores empresariales bare-metal en centros de datos modernos se ejecutan de forma headless sin consolas VGA. El bootstrapping requiere redirección de consola serie (`comconsole` / `tty00` / `ttyC0`) sobre IPMI/iDRAC/iLO Serial-over-LAN (SoL) combinada con configuraciones de fallback UEFI/BIOS.
2. **Inicialización del Subsistema de Almacenamiento**: Los arquitectos SRE deben decidir entre esquemas legacy FFS/UFS2 y pools de almacenamiento avanzados como FreeBSD ZFS en Root (`zroot`). El almacenamiento de nivel empresarial requiere particionamiento programático (GPT vs. BSD Disklabel), cifrado de almacenamiento (GELI / `softraid`) y topología de layout RAID (mirror vs. raidz2) durante la fase inicial de instalación.
3. **Mecánica del Instalador desatendido**: Cada variante de BSD expone una interfaz de automatización desatendida distinta:
   - **FreeBSD**: `bsdinstall` impulsado por scripts shell `installerconfig` ejecutados dentro de un hook post-instalación en chroot.
   - **OpenBSD**: `autoinstall(8)` impulsado por un archivo de respuesta en texto plano (`install.conf`) servido mediante HTTP/TFTP durante la ejecución del RAM disk `bsd.rd`.
   - **NetBSD**: `sysinst(8)` automatizado utilizando manifiestos de configuración scripteados u opciones de flags no interactivas.

```
                      +------------------------------------------+
                      |         Enterprise PXE / DHCP Server     |
                      |  DHCP Opt 66 (Next-Server) / Opt 67    |
                      +--------------------+---------------------+
                                           |
                                 iPXE / PXE Boot Request
                                           |
    +--------------------------------------+--------------------------------------+
    |                                      |                                      |
    v                                      v                                      v
+-----------------------+      +-----------------------+      +-----------------------+
|  FreeBSD boot/loader  |      |   OpenBSD bsd.rd      |      |   NetBSD pxeboot      |
| Downloads kernel      |      | Mounts RAM Disk       |      | Mounts NFS / HTTP     |
| Reads installerconfig |      | Fetches install.conf  |      | Runs sysinst script   |
+-----------+-----------+      +-----------+-----------+      +-----------+-----------+
            |                              |                              |
            v                              v                              v
+-----------------------+      +-----------------------+      +-----------------------+
| ZFS Root Pool (zroot) |      | FFS2 + softraid Encrypt|     | FFSv2 / LFS Partition |
| GPT + EFI System Part |      | MBR/GPT + Disklabel   |      | GPT + Wedge Layout    |
+-----------------------+      +-----------------------+      +-----------------------+
```

---

## 2. Comparaciones Técnicas & Matrices de Trade-offs

### 2.1 Arquitectura de Herramientas de Instalación

| Dimensión | FreeBSD (`bsdinstall`) | OpenBSD (`autoinstall`) | NetBSD (`sysinst`) |
| :--- | :--- | :--- | :--- |
| **Entorno de Ejecución** | LiveCD de FreeBSD / ISO del Instalador | `bsd.rd` (Kernel en RAM Disk) | `netbsd-INSTALL` / Imagen Booteable |
| **Archivo de Automatización** | `/etc/installerconfig` (Script de Shell) | `install.conf` (Respuestas Clave-Valor) | `sysinst.cfg` / Respuestas de menú |
| **Obtención de Automatización por Red**| Pre-fetch por TFTP / HTTP a memoria | HTTP / TFTP (opción DHCP `bootfile`) | HTTP / NFS / Archivo Local |
| **Sistema de Archivos Root por Defecto**| ZFS (zroot) o UFS2 + SU/SUJ | FFS / FFS2 (Soft updates deshabilitados por defecto)| FFSv2 (Fast File System v2) |
| **Hooks Post-Instalación** | Ejecución de código shell nativo en script | Ejecución de archivo `siteXX.tgz` | Ejecución de script shell personalizado |

### 2.2 Trade-offs de Particionamiento de Almacenamiento & Sistemas de Archivos

| Característica / Arquitectura | ZFS en Root (`zroot`) | UFS2 + Soft Updates (SU/SUJ) | OpenBSD FFS2 + `softraid` | NetBSD FFSv2 + Wedges |
| :--- | :--- | :--- | :--- | :--- |
| **SO Principal** | FreeBSD | FreeBSD / NetBSD | OpenBSD | NetBSD |
| **Gestión de Volúmenes** | Integrada (Pool/Datasets) | Externa (GEOM / `gpart`) | Integrada (`bioctl` / `softraid`) | Integrada (wedges `dk`) |
| **Verificación de Integridad de Datos**| Checksums de 256 bits end-to-end | Journaling de metadatos | Verificación del sistema de archivos basada en FSCK | FSCK / WAPBL (Journaling) |
| **Cifrado Nativo** | ZFS Nativo (AES-256-GCM) | GELI (`geli(8)`) | `softraid` (`crypto`) | `cgd(4)` (Crypto Graphic Disk) |
| **Overhead de Memoria** | Alto (Requiere 4GB+ RAM) | Bajo (< 512MB RAM) | Bajo (< 512MB RAM) | Bajo (< 512MB RAM) |
| **Esquema de Particionamiento** | GPT (GUID Partition Table) | GPT o MBR | MBR/GPT + BSD Disklabel | GPT / BSD Disklabel / Wedges |

### 2.3 Mantenimiento de Release del SO & Upgrades

| Variante de SO | Herramienta de Upgrade Binario | Método de Upgrade desde Código Fuente | Cadencia de Rolling/Release |
| :--- | :--- | :--- | :--- |
| **FreeBSD** | `freebsd-update(8)` / `pkg(8)` | `make buildworld && make installworld` | Releases de punto cada 6 meses, STABLE de 5 años |
| **OpenBSD** | `sysupgrade(8)` / `pkg_add(8)` | Checkout de código fuente con `cvs` / `got` & `make` | Ciclo de vida de release de 6 meses (2 releases soportadas) |
| **NetBSD** | `sysinst(8)` / `pkgin(1)` | Pipeline `./build.sh release` | Ciclo de vida de release mayor de 1-2 años |

---

## 3. Manifiestos de Producción Completos & Configuraciones de Infraestructura

### 3.1 Script `installerconfig` desatendido de FreeBSD
Este script completamente automatizado configura un sistema FreeBSD headless con ZFS Mirror, boot UEFI GPT, Consola Serie y acceso SSH.

```sh
#!/bin/sh
# /etc/installerconfig - FreeBSD Automated Unattended Installation Script
# Target Architecture: x86_64 UEFI / Serial Console / Dual-Disk ZFS Mirror

# 1. Environment & Non-interactive Variables
export INTERACTIVE=0
export PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin

# 2. Network Configuration
hostname="bsd-node-01.production.internal"
DISTRIBUTIONS="base.txz kernel.txz src.txz"

# 3. Target Disks Setup
PRIMARY_DISK="da0"
SECONDARY_DISK="da1"

# 4. Clear existing partition tables
gpart destroy -F ${PRIMARY_DISK} || true
gpart destroy -F ${SECONDARY_DISK} || true

# 5. Automated ZFS Root Partitioning via bsdinstall zfsboot
export ZFSBOOT_VDEV_TYPE="mirror"
export ZFSBOOT_DISKS="${PRIMARY_DISK} ${SECONDARY_DISK}"
export ZFSBOOT_POOL_NAME="zroot"
export ZFSBOOT_CONFIRM_ZPOOL=1
export ZFSBOOT_SWAP_SIZE="8g"
export ZFSBOOT_SWAP_ENCRYPTION=1
export ZFSBOOT_GELI_ENCRYPTION=0
export ZFSBOOT_BOOT_TYPE="UEFI"

# Trigger automated ZFS setup
bsdinstall zfsboot

# Extract base distributions into /mnt
bsdinstall distextract

# 6. Post-Installation Configuration Hook (Inside target chroot /mnt)
cat << 'EOF' > /mnt/etc/rc.conf
# Network Configuration
hostname="bsd-node-01.production.internal"
ifconfig_vtnet0="DHCP"
ifconfig_vtnet0_ipv6="inet6 accept_rtadv"

# Base Services
sshd_enable="YES"
ntpdate_enable="YES"
ntpdate_flags="-b pool.ntp.org"
ntpd_enable="YES"
powerd_enable="YES"

# Security & Auditing
clear_tmp_enable="YES"
syslogd_flags="-s -s"
sendmail_enable="NONE"
EOF

# 7. Bootloader & Kernel Options (/boot/loader.conf)
cat << 'EOF' > /mnt/boot/loader.conf
# ZFS Module Settings
zfs_load="YES"
vfs.root.mountfrom="zfs:zroot/ROOT/default"

# Serial Console Redirection over IPMI / SoL
boot_multicons="YES"
boot_serial="YES"
comconsole_speed="115200"
console="comconsole,vidconsole"

# Performance Tuning
kern.maxproc="65536"
net.inet.tcp.soreceive_stream="1"
EOF

# 8. User Accounts & SSH Key Provisioning
chroot /mnt pw useradd -n admin -c "SRE Admin" -m -s /bin/csh -g wheel
mkdir -p /mnt/home/admin/.ssh
cat << 'EOF' > /mnt/home/admin/.ssh/authorized_keys
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGx8Z5qY7K1vN9+P3nQ0X9JmKxR3Yv8L7N2W1Q8Z0X1Y sre-deployer@production
EOF
chmod 700 /mnt/home/admin/.ssh
chmod 600 /mnt/home/admin/.ssh/authorized_keys
chown -R 1001:0 /mnt/home/admin

# 9. Sudoers Configuration
echo "admin ALL=(ALL) NOPASSWD: ALL" > /mnt/usr/local/etc/sudoers.d/admin
chmod 440 /mnt/usr/local/etc/sudoers.d/admin

# Complete Installation
bsdinstall config
```

---

### 3.2 Manifiesto `install.conf` desatendido de OpenBSD
Este archivo `install.conf` se sirve mediante HTTP (`http://pxe.internal/install.conf`) para `autoinstall(8)` de OpenBSD.

```ini
# OpenBSD autoinstall(8) Response File - install.conf
# Production Headless Bare-Metal / Hypervisor Profile

System hostname = bsd-node-02
Password for root = $6$vL8zP9xK$E5fR1T2Y3U4I5O6P7Q8R9S0T1U2V3W4X5Y6Z7a8b9c0d1e2f3g4h5i6j7k8l9m0
Change the default console to com0 = yes
Which speed should com0 use = 115200
Setup a user = sreuser
Full name for user sreuser = SRE Automation User
Password for user sreuser = $6$k8L9m0N1$P2Q3R4S5T6U7V8W9X0Y1Z2a3b4c5d6e7f8g9h0i1j2k3l4m5n6o7p8q9
Public ssh key for user sreuser = ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIL9P4K2vN8+X1mQ0R9JmKxR3Yv8L7N2W1Q8Z0X1Y sre-key
What timezone are you in = UTC
Location of sets = http
HTTP proxy = none
HTTP Server = cdn.openbsd.org
Server directory = pub/OpenBSD/7.5/amd64
Set name(s) = +* -game* -x*
Use (A)uto layout, (E)dit or use (C)ustom layout = auto
Which disk is the root disk = sd0
Encrypt the root disk = no
Perform auto-installation = yes
URL to site-specific customization notes = none
```

---

### 3.3 Archivo de Respuesta `sysinst.cfg` desatendido de NetBSD
Esta configuración mediante scripts impulsa la utilidad `sysinst(8)` de NetBSD durante despliegues PXE automatizados.

```ini
# NetBSD sysinst(8) Unattended Installation Configuration
# File: /usr/share/sysinst/sysinst.cfg

VERSION=10.0
DISTRIBDIR=/pub/NetBSD/NetBSD-10.0/amd64
DISK=ld0
PARTITION_SCHEME=gpt

# Disk Partitioning Specifications (Megabytes)
BOOT_SIZE=512
SWAP_SIZE=4096
ROOT_SIZE=32768
VAR_SIZE=10240
USR_SIZE=0

# Filesystem Types
FS_TYPE=ffsv2
MOUNT_OPTIONS=log

# Networking Configuration
NET_INTERFACE=vioif0
NET_DHCP=yes
HOST_NAME=bsd-node-03.production.internal

# Base Distribution Sets Selection
SET_base=yes
SET_etc=yes
SET_comp=yes
SET_games=no
SET_man=yes
SET_misc=yes
SET_modules=yes
SET_tests=no
SET_text=yes
SET_xbase=no
SET_xcomp=no
SET_etcserv=yes

# Post-Install Shell Hook Commands
POST_INSTALL_CMD=/bin/sh -c "echo 'rc_configured=YES' >> /target/etc/rc.conf && echo 'sshd=YES' >> /target/etc/rc.conf && echo 'tty00 \"/usr/libexec/getty std.115200\" vt100 on secure' >> /target/etc/ttys"
```

---

## 4. Ejecución en CLI & Salidas Reales de Terminal

### 4.1 Instalación de FreeBSD y Verificación del Sistema Post-Boot

#### Comando: Consultando Arquitectura del Sistema y Metadatos del Kernel
```console
$ uname -a
FreeBSD bsd-node-01.production.internal 14.0-RELEASE FreeBSD 14.0-RELEASE releng/14.0-n265380-f3518167086d GENERIC amd64
```

#### Comando: Inspeccionando Particionamiento de Disco (Layout GPT)
```console
$ gpart show -p
=>       40  1000215136  da0  GPT  (476G)
         40        1024       - free -  (512K)
       1064      1048576  da0p1  efi  (512M)
    1049640         2048  da0p2  freebsd-boot  (1.0M)
    1051688     16777216  da0p3  freebsd-swap  (8.0G)
   17828904    982386272  da0p4  freebsd-zfs  (468G)

=>       40  1000215136  da1  GPT  (476G)
         40        1024       - free -  (512K)
       1064      1048576  da1p1  efi  (512M)
    1049640         2048  da1p2  freebsd-boot  (1.0M)
    1051688     16777216  da1p3  freebsd-swap  (8.0G)
   17828904    982386272  da1p4  freebsd-zfs  (468G)
```

#### Comando: Inspeccionando Estado de Salud del Storage Pool ZFS & Configuración de Mirror
```console
$ zpool status zroot
  pool: zroot
 state: ONLINE
  scan: scrub repaired 0B in 00:01:23 with 0 errors on Thu Aug  6 18:30:11 2026
config:

	NAME        STATE     READ WRITE CKSUM
	zroot       ONLINE       0     0     0
	  mirror-0  ONLINE       0     0     0
	    da0p4   ONLINE       0     0     0
	    da1p4   ONLINE       0     0     0

errors: No known data errors
```

#### Comando: Realizando un Upgrade del Sistema Base mediante `freebsd-update`
```console
# freebsd-update fetch
src component not installed, skipped
Looking up update.FreeBSD.org mirrors... 3 mirrors found.
Fetching public key from update.FreeBSD.org... done.
Fetching metadata signature for 14.0-RELEASE from update.FreeBSD.org... done.
Fetching metadata index... done.
Inspecting system... done.
Preparing to download files... done.
The following files will be updated as part of updating to 14.0-RELEASE-p5:
/bin/freebsd-version
/lib/libc.so.7
/usr/sbin/sshd

# freebsd-update install
Installing updates...
Kernel updates have been installed. Please reboot the system.
Completing the upgrade... done.
```

---

### 4.2 Boot, Verificación y Flujo de Trabajo de Upgrade de OpenBSD

#### Comando: Verificando Versión del Kernel y del SO
```console
$ uname -a
OpenBSD bsd-node-02 7.5 GENERIC.MP#82 amd64
```

#### Comando: Inspeccionando Arquitectura de Disco de OpenBSD (`disklabel`)
```console
$ disklabel sd0
# /dev/rsd0c:
type: SCSI
disk: SCSI disk
label: VBOX HARDDISK
flags:
bytes/sector: 512
sectors/track: 63
tracks/cylinder: 255
sectors/cylinder: 16065
cylinders: 10443
total sectors: 167772160

16 partitions:
#                size        offset    fstype [fsize bsize cpg]
  a:         41943040      10485760    4.2BSD   4096 32768   16 # /
  b:          8388608       2097152      swap                   # swap
  i:          2048000            64   MSDOS                     # EFI System Partition
  k:        114696192      52428800    4.2BSD   4096 32768   16 # /usr/local
```

#### Comando: Upgrade Automatizado del SO mediante `sysupgrade`
```console
# sysupgrade -r
Fetching https://cdn.openbsd.org/pub/OpenBSD/7.6/amd64/SHA256
Fetching https://cdn.openbsd.org/pub/OpenBSD/7.6/amd64/bsd.rd
Verifying SHA256.sig... Signature Verified
Upgrading system from 7.5 to 7.6...
Copying /bsd.rd to /bsd.upgrade... done.
Rebooting system into /bsd.upgrade to apply update...
```

---

### 4.3 Diagnósticos del Sistema NetBSD

#### Comando: Identificación del Sistema y Configuración del Kernel
```console
$ uname -a
NetBSD bsd-node-03 10.0 NetBSD 10.0 (GENERIC) #0: Thu Mar 28 08:33:37 UTC 2024  builduser@netbsd.org:/usr/obj/sys/arch/amd64/compile/GENERIC amd64
```

#### Comando: Inspeccionando Wedges de Almacenamiento del Kernel de NetBSD (`dk`)
```console
$ dkctl ld0 listwedges
4 wedges created for ld0:
dk0: EFI System Partition, 1048576 blocks at 2048, type: msdos
dk1: netbsd-swap, 8388608 blocks at 1050624, type: swap
dk2: netbsd-root, 67108864 blocks at 9439232, type: ffs
dk3: netbsd-usr, 91224031 blocks at 76548096, type: ffs
```

---

## 5. Diagnóstico de Fallas & Guía de Recuperación de Emergencia

```
                         [ Boot Failure Event ]
                                    |
            +-----------------------+-----------------------+
            |                                               |
            v                                               v
 [ Storage / Pool Corrupted ]                    [ Bootloader / Console Failure ]
            |                                               |
  1. Boot live installer media                     1. Intercept bootloader menu
  2. FreeBSD: zpool import -f -R /mnt zroot        2. FreeBSD: set console="comconsole"
  3. OpenBSD: fsck_ffs -y /dev/rsd0a               3. OpenBSD: boot hd0a:/bsd.rd
  4. NetBSD: fsck_ffs -y /dev/rdk2                 4. Force kernel load & boot
```

### 5.1 Escenario 1: Falla en la Importación del Pool Root de ZFS (FreeBSD)

#### Análisis de Causa Raíz
Apagados no limpios del nodo o desajustes en el ID del host durante el reemplazo de hardware impiden que `zroot` se monte automáticamente, dejando al sistema en el prompt del bootloader (`OK`).

#### Comandos de Diagnóstico en el Prompt del Loader
```console
OK lsdev
Block devices:
  disk0:   GPT Array
    disk0p1: EFI System
    disk0p2: FreeBSD Boot
    disk0p3: FreeBSD Swap
    disk0p4: FreeBSD ZFS
OK set currdev="zfs:zroot/ROOT/default:"
OK load /boot/kernel/kernel
OK load /boot/kernel/zfs.ko
OK boot
```

#### Procedimiento de Recuperación mediante Medio Live
Inicie en la Shell de Rescate de FreeBSD y fuerce la importación del pool utilizando un punto de montaje alternativo en la raíz (`-R`):

```console
# zpool import
   pool: zroot
     id: 1478204918239012389
  state: ONLINE
 status: The pool was last accessed by another system.
 action: The pool can be imported using its name or numeric identifier.
 config:

	zroot       ONLINE
	  mirror-0  ONLINE
	    da0p4   ONLINE
	    da1p4   ONLINE

# Force import pool with alternate root
# zpool import -f -R /mnt zroot

# Verify filesystems are mounted
# df -h /mnt
Filesystem             Size    Used   Avail Capacity  Mounted on
zroot/ROOT/default     450G    4.2G    4458G     1%    /mnt

# Regenerate zpool cache file
# zpool set cachefile=/mnt/boot/zfs/zpool.cache zroot
# zpool export zroot
# reboot
```

---

### 5.2 Escenario 2: Blackout de Consola Serie / TTYs Mal Configuradas

#### Análisis de Causa Raíz
El kernel arranca, pero la salida se detiene después de `Booting...`. El sistema está configurado para video VGA (`vidconsole`), mientras que el entorno IPMI espera Serial-over-LAN (`comconsole` / `tty00` a 115200 bps).

#### Matriz de Remediación entre Variantes de BSD

##### Solución en FreeBSD (`/boot/loader.conf` & `/etc/ttys`)
```sh
# Mount root filesystem read-write
mount -u -w /

# Enforce comconsole in loader configuration
cat << 'EOF' >> /boot/loader.conf
boot_multicons="YES"
boot_serial="YES"
comconsole_speed="115200"
console="comconsole"
EOF

# Enable getty on serial port in /etc/ttys
sed -i '' 's/ttyu0.*off/ttyu0 "/usr/libexec/getty 3wire.115200" vt100 on secure/' /etc/ttys
```

##### Solución en OpenBSD (`/etc/boot.conf` & `/etc/ttys`)
```sh
# Mount root filesystem read-write
mount -u -w /

# Configure bootloader for com0
cat << 'EOF' > /etc/boot.conf
set tty com0
stty com0 115200
EOF

# Enable console getty on tty00
sed -i 's/tty00.*off/tty00 "/usr/libexec/getty std.115200" vt220 on secure/' /etc/ttys
```

---

### 5.3 Escenario 3: Recuperación de Corrupción de Metadatos en FFS / UFS

#### Análisis de Causa Raíz
Interrupciones de energía durante escrituras en disco dañan los superbloques o tablas de inodos en sistemas de archivos FFS de OpenBSD / NetBSD, lo que resulta en una shell de emergencia forzada en modo de solo lectura.

#### Diagnóstico en Terminal de Emergencia & Reparación FSCK
```console
# Identify corrupt partition via dmesg
$ dmesg | grep "bad super block"
sd0a: bad super block magic number

# Run fsck in interactive or force mode
# fsck_ffs -b 32 -y /dev/rsd0a
** /dev/rsd0a
** File System: ffs (cg 0, cgp 0x0, maxblks 16)
** Last Mounted on /
** Phase 1 - Check Blocks and Sizes
** Phase 2 - Check Pathnames
** Phase 3 - Check Connectivity
** Phase 4 - Check Reference Counts
** Phase 5 - Check Cyl groups
FREE BLK COUNT(S) INCORRECT IN SILO
FIX? yes

MARK FILE SYSTEM CLEAN? yes

***** FILE SYSTEM WAS MODIFIED *****
***** PLEASE REBOOT SYSTEM *****
```

---

## 6. Referencias

- **Resumen de Objetivos de la Certificación LPI BSD Specialist**:  
  https://www.lpi.org/our-certifications/bsd-specialist-overview/
- **Handbook de FreeBSD: Capítulo 2. Instalando FreeBSD (`bsdinstall`)**:  
  https://docs.freebsd.org/en/books/handbook/bsdinstall/
- **Páginas de Manual de FreeBSD: `installerconfig` & `bsdinstall(8)`**:  
  https://man.freebsd.org/cgi/man.cgi?query=bsdinstall
- **Páginas de Manual de OpenBSD: Instalación Automatizada del Sistema (`autoinstall(8)`)**:  
  https://man.openbsd.org/autoinstall.8
- **Handbook de OpenBSD: Instalación del Sistema (`bsd.rd`)**:  
  https://www.openbsd.org/faq/faq4.html
- **Guía de Instalación Automatizada de NetBSD (`sysinst`)**:  
  https://wiki.netbsd.org/tutorials/how_to_install_netbsd_automating/
- **Documentación de Arquitectura & Bootloaders de NetBSD**:  
  https://www.netbsd.org/docs/guide/en/chap-install.html