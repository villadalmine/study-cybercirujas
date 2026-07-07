# Tema 4.2 — Understanding Computer Hardware

**Examen:** LPI Linux Essentials 010-160 (versión 1.6) · **Peso:** 2

---

## 1. Introducción

Para administrar un sistema Linux es necesario entender los componentes físicos sobre los que corre el sistema operativo. Este tema cubre los elementos principales del hardware de una computadora —**motherboard**, **CPU**, memoria, almacenamiento, periféricos y **drivers**— y las herramientas básicas que Linux ofrece para inspeccionarlos.

Áreas de conocimiento del objetivo:
- Hardware (motherboards, procesadores, fuentes de alimentación, discos y particiones, unidades ópticas, periféricos)
- Drivers

---

## 2. La motherboard y la CPU

### 2.1 Motherboard

La **motherboard** (placa madre) es el circuito principal que interconecta todos los componentes: CPU, memoria RAM, controladoras de disco, puertos USB, tarjetas de expansión (**PCI Express**), etc. Integra además el **firmware** de arranque:

- **BIOS** (*Basic Input/Output System*): firmware clásico; inicializa el hardware y busca el cargador de arranque en el **MBR** del disco.
- **UEFI** (*Unified Extensible Firmware Interface*): sucesor moderno del BIOS; soporta discos grandes con particionado **GPT**, arranque seguro (**Secure Boot**) y una partición especial llamada **ESP** (*EFI System Partition*).

### 2.2 CPU

La **CPU** (*Central Processing Unit*) ejecuta las instrucciones de los programas. Conceptos clave para el examen:

- **Arquitecturas**: `x86` (32 bits), `x86_64`/`amd64` (64 bits), `ARM` (común en móviles, Raspberry Pi y servidores modernos). Un kernel de 64 bits puede ejecutar programas de 32 bits, pero no al revés.
- **Cores**: los procesadores modernos tienen múltiples núcleos; cada uno puede ejecutar tareas en paralelo.
- La CPU incluye memoria **cache** (L1, L2, L3), mucho más rápida que la RAM.

Ver la arquitectura del sistema:

```
$ uname -m
x86_64
```

Ver información detallada de la CPU:

```
$ lscpu
Architecture:        x86_64
CPU op-mode(s):      32-bit, 64-bit
CPU(s):              8
Model name:          Intel(R) Core(TM) i7-8550U CPU @ 1.80GHz
```

También se puede consultar el pseudo-archivo `/proc/cpuinfo`:

```
$ cat /proc/cpuinfo | grep "model name" | head -1
model name : Intel(R) Core(TM) i7-8550U CPU @ 1.80GHz
```

---

## 3. Memoria

- **RAM** (*Random Access Memory*): memoria volátil de trabajo; su contenido se pierde al apagar el equipo.
- **Swap**: espacio en disco que el kernel usa como extensión de la RAM cuando esta se agota. Puede ser una partición o un archivo.

Ver la memoria disponible:

```
$ free -h
              total        used        free      shared  buff/cache   available
Mem:           15Gi       4.2Gi       6.1Gi       512Mi       5.0Gi        10Gi
Swap:         2.0Gi          0B       2.0Gi
```

> Nota: Linux usa la RAM libre como cache de disco (`buff/cache`); eso no significa que la memoria esté "ocupada", ya que se libera cuando las aplicaciones la necesitan.

---

## 4. Almacenamiento

### 4.1 Tipos de dispositivos

- **HDD** (*Hard Disk Drive*): discos magnéticos mecánicos; mayor capacidad por costo, más lentos.
- **SSD** (*Solid State Drive*): memoria flash, sin partes móviles; mucho más rápidos.
- **NVMe**: SSD conectados directamente por PCI Express; los más rápidos.
- Medios extraíbles: pendrives USB, tarjetas SD, unidades ópticas (CD/DVD/Blu-ray).

### 4.2 Nombres de dispositivos en Linux

Linux representa los dispositivos como archivos dentro de `/dev`:

| Dispositivo | Nombre en `/dev` |
|---|---|
| Discos SATA/SCSI/USB | `/dev/sda`, `/dev/sdb`, ... |
| Discos NVMe | `/dev/nvme0n1`, `/dev/nvme0n2`, ... |
| Unidades ópticas | `/dev/sr0` (con enlace `/dev/cdrom`) |
| Particiones | `/dev/sda1`, `/dev/sda2`, `/dev/nvme0n1p1`, ... |

### 4.3 Particiones

Un disco se divide en **particiones**, secciones lógicas que pueden contener un filesystem distinto cada una. Los dos esquemas de particionado son:

- **MBR** (*Master Boot Record*): esquema clásico; máximo 4 particiones primarias y discos de hasta 2 TB.
- **GPT** (*GUID Partition Table*): esquema moderno usado con UEFI; soporta discos enormes y hasta 128 particiones.

Listar discos y particiones:

```
$ lsblk
NAME        MAJ:MIN RM   SIZE RO TYPE MOUNTPOINT
sda           8:0    0 465.8G  0 disk
├─sda1        8:1    0   512M  0 part /boot/efi
├─sda2        8:2    0 460.3G  0 part /
└─sda3        8:3    0     5G  0 part [SWAP]
sr0          11:0    1  1024M  0 rom
```

Ver el espacio usado por los filesystems montados:

```
$ df -h /
Filesystem      Size  Used Avail Use% Mounted on
/dev/sda2       453G  120G  310G  28% /
```

---

## 5. Fuente de alimentación y periféricos

### 5.1 Power supply

La **PSU** (*Power Supply Unit*) convierte la corriente alterna de la red eléctrica en corriente continua de bajo voltaje para los componentes internos. En laptops la complementa la batería; en servidores es habitual tener fuentes **redundantes** para tolerar fallas.

### 5.2 Periféricos

Los **periféricos** son dispositivos externos: teclado, mouse, monitor, impresoras, cámaras, etc. La mayoría se conecta hoy por **USB**. Las placas de video (**GPU**) generan la salida hacia el monitor mediante conectores como HDMI o DisplayPort, y en Linux requieren drivers específicos (libres como `nouveau`/`amdgpu`, o propietarios como el de NVIDIA).

Listar dispositivos USB conectados:

```
$ lsusb
Bus 001 Device 003: ID 046d:c534 Logitech, Inc. Unifying Receiver
Bus 001 Device 002: ID 0781:5581 SanDisk Corp. Ultra
```

Listar dispositivos conectados al bus PCI (placas de video, red, controladoras):

```
$ lspci
00:02.0 VGA compatible controller: Intel Corporation UHD Graphics 620
00:1f.6 Ethernet controller: Intel Corporation Ethernet Connection I219-V
```

---

## 6. Drivers y módulos del kernel

Un **driver** es el software que permite al kernel comunicarse con un dispositivo de hardware. En Linux la mayoría de los drivers se implementan como **kernel modules**: fragmentos de código que se cargan y descargan dinámicamente sin reiniciar.

Comandos útiles:

```
$ lsmod | head -4
Module                  Size  Used by
snd_hda_intel          57344  4
iwlwifi               389120  1
usb_storage            77824  1
```

- `lsmod`: lista los módulos cargados.
- `modprobe <módulo>`: carga un módulo y sus dependencias (requiere `root`).
- `modprobe -r <módulo>`: descarga un módulo.

Los mensajes del kernel al detectar hardware (por ejemplo, al conectar un pendrive) se ven con `dmesg`:

```
$ sudo dmesg | tail -3
[ 1523.401] usb 1-2: new high-speed USB device number 5 using xhci_hcd
[ 1523.552] usb-storage 1-2:1.0: USB Mass Storage device detected
[ 1524.581] sd 3:0:0:0: [sdb] Attached SCSI removable disk
```

Gran parte de la información de hardware también está expuesta en los pseudo-filesystems `/proc` y `/sys` (por ejemplo `/proc/cpuinfo`, `/proc/meminfo`).

---

## 7. Resumen de comandos clave

| Comando | Qué muestra |
|---|---|
| `lscpu`, `/proc/cpuinfo` | Información de la CPU |
| `free -h`, `/proc/meminfo` | Memoria RAM y swap |
| `lsblk` | Discos y particiones |
| `df -h` | Uso de espacio en filesystems |
| `lsusb` | Dispositivos USB |
| `lspci` | Dispositivos PCI |
| `lsmod` / `modprobe` | Módulos del kernel (drivers) |
| `dmesg` | Mensajes del kernel sobre hardware |

---

## Referencias

- LPI Learning Materials — Lesson 4.2, Understanding Computer Hardware: https://learning.lpi.org/en/learning-materials/010-160/4/4.2/
- Objetivos oficiales del examen Linux Essentials 010-160: https://www.lpi.org/our-certifications/exam-010-objectives/
- Manual de `lsblk` (util-linux): https://man7.org/linux/man-pages/man8/lsblk.8.html
- Manual de `lscpu` (util-linux): https://man7.org/linux/man-pages/man1/lscpu.1.html
- Manual de `lspci`: https://man7.org/linux/man-pages/man8/lspci.8.html
- Manual de `modprobe`: https://man7.org/linux/man-pages/man8/modprobe.8.html
- Especificación UEFI (UEFI Forum): https://uefi.org/specifications