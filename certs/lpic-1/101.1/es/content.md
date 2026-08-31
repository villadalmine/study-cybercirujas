# 101.1 — Determinar y configurar parámetros de hardware

**LPIC-1 · Examen 101-500 · Tema 101: Arquitectura del sistema · Peso 3.13**

> **Alcance de este objetivo.** Habilitar y deshabilitar periféricos integrados; diferenciar tipos de dispositivos de almacenamiento masivo; determinar los recursos de hardware de los dispositivos; usar las herramientas que listan información de hardware; manipular dispositivos USB; tener una comprensión conceptual de `sysfs`, `udev` y `dbus`.
> **Términos y utilidades:** `/sys/`, `/proc/`, `/dev/`, `modprobe`, `lsmod`, `lspci`, `lsusb`.

---

## 1. Motivación: el problema de producción que este objetivo realmente resuelve

En una laptop, los "parámetros de hardware" son una curiosidad. En una flota, son el cajón de causas raíz que nadie se adjudica.

Considerá una forma concreta de incidente que se repite en todos los equipos de plataforma:

> Un cluster de Kubernetes de 400 nodos corre una capa de ingress sensible a la latencia. Después de una actualización rolling del kernel, la latencia p99 en **11 nodos** pasa de 800 µs a 45 ms. Los pods son idénticos. Las imágenes son idénticas. El Deployment es idéntico. `kubectl describe node` no muestra nada.
>
> Esos 11 nodos se montaron en rack seis meses después que el resto y vinieron con un stepping distinto de NIC. El kernel nuevo autocarga una variante distinta del driver, la NIC cae en un **grupo IOMMU diferente**, su `numa_node` se reporta como `-1`, así que cada interrupción la atiende una CPU del socket equivocado y cada buffer DMA cruza el enlace UPI.

Nada de ese párrafo es un problema de Kubernetes. Es `lspci`, `/proc/interrupts`, `/sys/devices/system/node/` y una regla de `udev`. El punto arquitectónico:

**El hardware no es una constante en un sistema distribuido — es una entrada sin versionar y sin declarar que varía a lo largo de tu flota y que cambia debajo tuyo en cada actualización de firmware y de kernel.**

La respuesta madura es una disciplina en tres capas:

| Capa | Pregunta | Mecanismo | Falla si falta |
|---|---|---|---|
| **Descubrimiento** | ¿Qué hardware está realmente presente y cómo lo modela el kernel? | `sysfs`, `procfs`, `lspci`, `lsusb`, `dmidecode`, `lsblk` | Depuración por superstición; "en el nodo 7 funciona" |
| **Declaración** | ¿Qué configuración debe cumplirse, independientemente del orden de enumeración? | reglas de `udev`, `modprobe.d`, archivos `.link`, línea de comandos del kernel, Ansible | Nombres de dispositivo no deterministas, comportamiento dependiente del orden de arranque |
| **Exposición** | ¿Cómo *ven* los schedulers y operadores al hardware como recurso de primera clase? | Etiquetas de nodo (NFD), device plugins, Topology Manager, servicios `dbus` | Cargas de trabajo ubicadas en nodos que no pueden servirlas |

Este documento recorre la escalera desde la enumeración del firmware hasta un nodo de Kubernetes que anuncia `platform.example.com/nic=x710` y `hugepages-1Gi: 16Gi`.

---

## 2. La cadena de enumeración: firmware → kernel → `sysfs` → `/dev`

Antes que cualquier herramienta, entendé el pipeline. Cada nodo de `/dev` es la salida terminal de un proceso de cinco etapas.

```
┌──────────────────────────────────────────────────────────────────────────┐
│ 1. FIRMWARE (UEFI/BIOS + ACPI tables, or Device Tree on ARM/RISC-V)       │
│    Trains DRAM, enumerates PCI, assigns BARs/IRQ routing, publishes:      │
│      x86 : ACPI (DSDT, SSDT, MADT, SRAT, SLIT, DMAR) + SMBIOS            │
│      ARM : Flattened Device Tree (.dtb) or ACPI                          │
└───────────────────────────────┬──────────────────────────────────────────┘
                                v
┌──────────────────────────────────────────────────────────────────────────┐
│ 2. KERNEL BUS DRIVERS  (pci, usb, acpi, platform, virtio, i2c, scsi…)    │
│    Re-walks the buses, may reassign resources, creates `struct device`   │
│    objects, computes a MODALIAS string per device.                       │
└───────────────────────────────┬──────────────────────────────────────────┘
                                v
┌──────────────────────────────────────────────────────────────────────────┐
│ 3. SYSFS  (/sys)  — the in-memory export of the kernel device model      │
│    kobject tree → directories; attributes → files. THE source of truth.  │
└───────────────────────────────┬──────────────────────────────────────────┘
                                v
┌──────────────────────────────────────────────────────────────────────────┐
│ 4. UEVENT over netlink (NETLINK_KOBJECT_UEVENT)  →  systemd-udevd        │
│    Kernel says "add /devices/pci0000:00/…, MODALIAS=pci:v8086d1572…"     │
│    udevd: matches rules, calls modprobe, sets names/symlinks/perms/tags  │
└───────────────────────────────┬──────────────────────────────────────────┘
                                v
┌──────────────────────────────────────────────────────────────────────────┐
│ 5. DEVTMPFS (/dev) + D-BUS                                               │
│    Kernel creates the raw node in devtmpfs; udev fixes ownership and     │
│    adds /dev/disk/by-*, /dev/serial/by-id/* symlinks. Higher-level       │
│    daemons (udisks2, UPower, NetworkManager) re-publish on D-Bus.        │
└──────────────────────────────────────────────────────────────────────────┘
```

Dos consecuencias que deciden la mayoría de las sesiones de depuración:

1. **Si no está en `/sys`, `udev` no puede arreglarlo.** Un `/dev/sdb` faltante cuando `/sys/block/sdb` tampoco existe es un problema de *driver/firmware*, no de `udev`. Diagnosticá en la dirección opuesta a la flecha.
2. **`udev` corre de forma asincrónica.** El nodo del kernel en `devtmpfs` aparece *antes* de que udev haya procesado el evento. Los scripts que hacen `sleep 2` después de conectar un disco están tapando un `udevadm settle` faltante.

### 2.1 Los tres pseudo-sistemas de archivos — compensaciones comparadas

| Propiedad | `procfs` (`/proc`) | `sysfs` (`/sys`) | `devtmpfs` (`/dev`) |
|---|---|---|---|
| Introducido | Linux 0.98 (1992) | 2.6 (2002) | 2.6.32 (2009) |
| Modela | Procesos + un cajón histórico de estado del kernel | El **modelo de dispositivos** del kernel (buses, dispositivos, drivers, clases) | Archivos **especiales** de dispositivo (nodos char/block) |
| Estructura | Ad-hoc, formatos mezclados, archivos multivalor | Estricta: **un valor por archivo**, el árbol refleja la topología de kobjects | Espacio de nombres casi plano de nodos + jerarquías de symlinks de udev |
| ¿ABI estable? | Rutas heredadas congeladas por necesidad | Documentado en `Documentation/ABI/{stable,testing}`; **las rutas no son estables — recorré el árbol, no las hardcodees** | Los nombres vía reglas de udev son el contrato de estabilidad |
| ¿Escribible? | Algunos (`/proc/sys` = sysctl, `/proc/irq/*/smp_affinity`) | Sí, extensamente (`sriov_numvfs`, `bind`/`unbind`, `nr_hugepages`) | Solo creación de nodos |
| Uso típico | Censo de CPU/memoria/interrupciones, mapas de recursos heredados | Atributos por dispositivo, binding de drivers, perillas de tuning | Objetivos de `open()` para el espacio de usuario |
| Dónde van las nuevas funcionalidades del kernel | Casi nunca | **Siempre** | — |

**Regla práctica para automatización nueva:** leé de `sysfs`, tratá a `procfs` como heredado-pero-necesario para `/proc/interrupts`, `/proc/cpuinfo`, `/proc/iomem`, `/proc/ioports`, `/proc/dma`, `/proc/cmdline`, `/proc/modules`.

La guía del propio kernel (`Documentation/admin-guide/sysfs-rules.rst`) es contundente: nunca asumas la ruta `sysfs` de un dispositivo. Encontrá dispositivos recorriendo `/sys/subsystem/<bus>/devices/` o `/sys/class/<class>/`, y después leé los atributos que necesites.

---

## 3. Determinar recursos de hardware: IRQ, DMA, puertos de E/S, MMIO

Los cuatro "recursos" clásicos que nombra el examen. En hardware moderno tres de ellos cambiaron de significado en silencio — saber *cómo* es el diferenciador de nivel senior.

### 3.1 Interrupciones — `/proc/interrupts`

```console
$ head -12 /proc/interrupts
            CPU0       CPU1       CPU2       CPU3     ...    CPU127
   0:         17          0          0          0     ...         0   IO-APIC    2-edge      timer
   8:          0          0          1          0     ...         0   IO-APIC    8-edge      rtc0
   9:          0          0          0          0     ...         0   IO-APIC    9-fasteoi   acpi
  16:          0          0          0          0     ...         0   IO-APIC   16-fasteoi   i801_smbus
 120:          0          0          0          0     ...         0   PCI-MSI 1572864-edge   nvme0q0
 121:    8934120          0          0          0     ...         0   PCI-MSI 1572865-edge   nvme0q1
 122:          0    8801994          0          0     ...         0   PCI-MSI 1572866-edge   nvme0q2
 145:          0          0          0          0     ...         0   PCI-MSI 524288-edge    enp129s0f0-TxRx-0
 146:  411920338          0          0          0     ...         0   PCI-MSI 524289-edge    enp129s0f0-TxRx-1
 NMI:       1204       1198       1201       1199     ...      1188   Non-maskable interrupts
 LOC:  982340112  981223401  983001229  982119844     ...  980112239   Local timer interrupts
```

Leelo como cinco columnas: **número de IRQ**, contadores por CPU, **controlador** (`IO-APIC`, `PCI-MSI`, `GICv3` en ARM), **tipo de disparo**, **nombre(s) de dispositivo**.

Notas de interpretación que importan en producción:

- Las líneas `IO-APIC` son las interrupciones heredadas, compartibles, ruteadas por pin — son las únicas donde el *compartir* IRQ sigue siendo un concepto real.
- `PCI-MSI` / `PCI-MSIX` son señalizadas por mensaje: el dispositivo hace DMA de una escritura a una dirección mágica. **No se comparten**, se asignan por cola, y son la razón por la que una NIC moderna tiene una IRQ por cola RX/TX (`enp129s0f0-TxRx-N`).
- **Una única columna distinta de cero es la prueba incriminatoria.** Arriba, `nvme0q1` y `enp129s0f0-TxRx-1` están ambas fijadas a CPU0/CPU1. Eso es o bien pinning intencional, o una configuración de afinidad rota que colapsa todo el trabajo de interrupciones sobre un solo core.

**Control de afinidad** (una máscara de bits hexadecimal, o la forma de lista más amigable):

```console
$ cat /proc/irq/146/smp_affinity_list
1
$ cat /proc/irq/146/smp_affinity
00000000,00000000,00000000,00000002
$ echo 34 | sudo tee /proc/irq/146/smp_affinity_list
34
$ cat /proc/irq/146/effective_affinity_list
34
```

Tres trampas:

1. `smp_affinity` es un *pedido*; `effective_affinity` es lo que el controlador de interrupciones realmente programó. Verificá siempre el archivo `effective_`.
2. Escribir en algunas IRQ devuelve `EIO` — esas están marcadas como `IRQF_NOBALANCING` (timer, cascade) y no se pueden mover.
3. **`irqbalance` te va a sobrescribir.** O lo detenés, o le prohibís CPUs:

```ini
# /etc/sysconfig/irqbalance   (RHEL family)  |  /etc/default/irqbalance (Debian family)
IRQBALANCE_BANNED_CPULIST=0-3,64-67
IRQBALANCE_ARGS="--policyscript=/usr/local/libexec/irq-policy.sh"
```

### 3.2 DMA — `/proc/dma`

```console
$ cat /proc/dma
 4: cascade
```

Este es el estado honesto del mundo: `/proc/dma` lista **únicamente canales de DMA ISA**. Desde PCI, los dispositivos son **bus masters** — hacen DMA por sí mismos, y el arbitraje que solía hacer el controlador de DMA ISA ya no existe. Esperá una sola línea (`4: cascade`) en cualquier servidor construido después de ~2005; las placas de sonido y las controladoras de diskette fueron los últimos ocupantes reales.

El equivalente moderno de "qué dispositivo puede hacer DMA a dónde" es la **IOMMU**:

```console
$ ls /sys/kernel/iommu_groups/ | wc -l
143
$ for d in /sys/kernel/iommu_groups/47/devices/*; do echo "grp47: $(basename $d)"; done
grp47: 0000:81:00.0
grp47: 0000:81:00.1
$ lspci -s 81:00.0
81:00.0 Ethernet controller: Intel Corporation Ethernet Controller X710 for 10GbE SFP+ (rev 02)
```

El grupo IOMMU es la **granularidad de asignación de dispositivos**. Ambos puertos X710 comparten el grupo 47, así que no podés pasar uno a una VM y mantener el otro en el host — pasás el grupo entero o nada. Esta es una restricción arquitectónica dura en cualquier diseño de VFIO/PCI passthrough.

### 3.3 Puertos de E/S y MMIO — `/proc/ioports`, `/proc/iomem`

```console
$ sudo cat /proc/ioports | head -8
0000-0cf7 : PCI Bus 0000:00
  0000-001f : dma1
  0020-0021 : pic1
  0040-0043 : timer0
  0060-0060 : keyboard
  0064-0064 : keyboard
  0070-0071 : rtc0
  02f8-02ff : serial

$ sudo cat /proc/iomem | grep -A2 '81:00.0'
  38fff8000000-38fff8ffffff : 0000:81:00.0
    38fff8000000-38fff8ffffff : i40e
  38fff9000000-38fff900ffff : 0000:81:00.0
    38fff9000000-38fff900ffff : i40e
```

Dos puntos didácticos:

- Sin `sudo`, ambos archivos muestran direcciones todas en cero. Eso es **endurecimiento de direcciones del kernel** (`kptr_restrict`), no un sistema roto. Una falsa alarma muy común.
- El anidamiento muestra la *propiedad* de los recursos: `0000:81:00.0` es dueño de la región BAR, y el driver `i40e` la reclamó. Un BAR **sin línea de driver anidada** es un dispositivo sin reclamar — la forma más rápida de detectar un driver faltante.

### 3.4 Resumen de recursos por dispositivo, directo desde `sysfs`

```console
$ cat /sys/bus/pci/devices/0000:81:00.0/resource | head -4
0x000038fff8000000 0x000038fff8ffffff 0x000000000014220c
0x0000000000000000 0x0000000000000000 0x0000000000000000
0x000038fff9000000 0x000038fff900ffff 0x000000000014220c
0x0000000000000000 0x0000000000000000 0x0000000000000000

$ cat /sys/bus/pci/devices/0000:81:00.0/{numa_node,irq,local_cpulist,current_link_speed,current_link_width}
1
0
32-63,96-127
16.0 GT/s PCIe
8
```

`numa_node: 1` y `local_cpulist: 32-63,96-127` son los dos valores que deciden el incidente de la §1. `current_link_speed`/`current_link_width` atrapan al otro clásico: una placa x8 negociada a la baja hasta x4 porque está en el slot equivocado.

---

## 4. El subsistema PCI en profundidad — `lspci`

### 4.1 Direccionamiento: el BDF (Bus:Device.Function) y el dominio

`0000:81:00.1` = `domain:bus:device.function`. El dominio (segmento) casi siempre es `0000` en x86 de commodity; los sistemas grandes y algunos SoC ARM usan múltiples segmentos.

### 4.2 La invocación que hay que memorizar

```console
$ lspci -nnk -s 81:00.
81:00.0 Ethernet controller [0200]: Intel Corporation Ethernet Controller X710 for 10GbE SFP+ [8086:1572] (rev 02)
	Subsystem: Intel Corporation Ethernet Converged Network Adapter X710-DA2 [8086:0000]
	Kernel driver in use: i40e
	Kernel modules: i40e
81:00.1 Ethernet controller [0200]: Intel Corporation Ethernet Controller X710 for 10GbE SFP+ [8086:1572] (rev 02)
	Subsystem: Intel Corporation Ethernet Converged Network Adapter X710-DA2 [8086:0000]
	Kernel driver in use: vfio-pci
	Kernel modules: i40e
```

- `-n` imprime los IDs numéricos **vendor:device** — `[8086:1572]`. **Automatizá sobre estos, nunca sobre el nombre comercial**, que cambia con la versión de tu base de datos `pci.ids`.
- `-k` imprime el driver enlazado. La distinción entre las dos líneas es doctrina:
  - **`Kernel driver in use:`** — lo que está enlazado *ahora mismo*.
  - **`Kernel modules:`** — lo que *podría* enlazarse, según `modules.alias`.
  - La función `.1` de arriba está enlazada a `vfio-pci`, es decir, fue entregada a una VM o a una aplicación DPDK.
  - **Un dispositivo con línea `Kernel modules:` pero sin línea `Kernel driver in use:` es tu bug.** El módulo existe pero no enlazó — revisá `dmesg` buscando fallo de probe, fallo de carga de firmware, o un `blacklist`.

### 4.3 Topología y detalle

```console
$ lspci -tv | head -12
-+-[0000:80]-+-00.0  Intel Corporation Device 0998
 |           +-01.0-[81]--+-00.0  Intel Corporation Ethernet Controller X710 for 10GbE SFP+
 |           |            \-00.1  Intel Corporation Ethernet Controller X710 for 10GbE SFP+
 |           \-04.0-[82]----00.0  Samsung Electronics Co Ltd NVMe SSD Controller PM9A3
 \-[0000:00]-+-00.0  Intel Corporation Device 0998
             +-1f.0  Intel Corporation C620 Series Chipset LPC Controller
             \-1f.4  Intel Corporation C620 Series Chipset SMBus

$ sudo lspci -vvv -s 81:00.0 | grep -E 'LnkCap|LnkSta|MaxPayload|NUMA|SR-IOV|Capabilities: .*(MSI|Vital)'
	Capabilities: [70] MSI-X: Enable+ Count=129 Masked-
		LnkCap:	Port #0, Speed 16GT/s, Width x8, ASPM not supported
		LnkSta:	Speed 16GT/s, Width x8
			MaxPayload 256 bytes, MaxReadReq 512 bytes
	Capabilities: [160] Single Root I/O Virtualization (SR-IOV)
```

El root complex `[80]` que hospeda al bus `81` te dice que esta placa está detrás del root PCIe del **segundo socket** — consistente con `numa_node: 1`.

### 4.4 Habilitar y deshabilitar periféricos integrados — el toolkit del lado Linux

La frase del examen "habilitar y deshabilitar periféricos integrados" se suele enseñar como "entrá al BIOS". A escala de flota no podés rebootear 400 nodos hacia un menú de firmware. Los equivalentes en tiempo de ejecución:

| Objetivo | Mecanismo | Comando | Persistencia |
|---|---|---|---|
| Desenlazar el driver, conservar el dispositivo | `unbind` del driver | `echo 0000:81:00.1 > /sys/bus/pci/drivers/i40e/unbind` | Solo en runtime |
| Enlazar un driver específico | `bind` del driver + `driver_override` | ver abajo | Solo en runtime |
| Quitar el dispositivo del bus | Hot-remove de PCI | `echo 1 > /sys/bus/pci/devices/0000:81:00.1/remove` | Hasta el `rescan` |
| Traer los dispositivos de vuelta | Rescan del bus | `echo 1 > /sys/bus/pci/rescan` | — |
| Impedir el driver en el arranque | blacklist / `install` en `modprobe.d` | `/etc/modprobe.d/*.conf` | **Persistente** |
| Impedir el driver desde la cmdline | `module_blacklist=` | Línea del kernel en GRUB | **Persistente** |
| Override persistente de driver | `driverctl` | `driverctl set-override 0000:81:00.1 vfio-pci` | **Persistente (respaldado por udev)** |
| Conmutar un dispositivo a nivel firmware | Variable UEFI / herramienta del fabricante | `fwupdmgr`, `efivar`, driver `smbios` del fabricante | **Persistente** |
| Autorización de puerto/dispositivo USB | Atributo `authorized` / USBGuard | `echo 0 > .../authorized` | Runtime (la política = persistente) |

```console
$ echo vfio-pci | sudo tee /sys/bus/pci/devices/0000:81:00.1/driver_override
vfio-pci
$ echo 0000:81:00.1 | sudo tee /sys/bus/pci/drivers/i40e/unbind
0000:81:00.1
$ echo 0000:81:00.1 | sudo tee /sys/bus/pci/drivers_probe
0000:81:00.1
$ lspci -nnk -s 81:00.1 | grep 'driver in use'
	Kernel driver in use: vfio-pci
```

`driverctl` envuelve exactamente esta secuencia y escribe una regla de udev en `/etc/udev/rules.d/80-driverctl.rules`, así que el override sobrevive al reboot. Preferilo por sobre los parches artesanales en `rc.local`.

### 4.5 SR-IOV: convertir una NIC en muchas

```console
$ cat /sys/class/net/enp129s0f0/device/sriov_totalvfs
64
$ cat /sys/class/net/enp129s0f0/device/sriov_numvfs
0
$ echo 8 | sudo tee /sys/class/net/enp129s0f0/device/sriov_numvfs
8
$ lspci -nn | grep -c 'Virtual Function'
8
$ ip link show enp129s0f0
6: enp129s0f0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 9000 qdisc mq state UP mode DEFAULT group default qlen 1000
    link/ether 3c:fd:fe:a1:b2:c0 brd ff:ff:ff:ff:ff:ff
    vf 0     link/ether 00:00:00:00:00:00, spoof checking on, link-state auto, trust off
    vf 1     link/ether 00:00:00:00:00:00, spoof checking on, link-state auto, trust off
```

Reglas duras: `sriov_numvfs` solo puede ir `N → 0 → M`, nunca `N → M` directamente (`EBUSY`); la plataforma debe tener `intel_iommu=on` (o `amd_iommu=on`) más SR-IOV habilitado en el firmware; y las direcciones MAC de las VF iguales a `00:00:00:00:00:00` se aleatorizan en cada arranque del guest, salvo que la PF se las asigne explícitamente (`ip link set enp129s0f0 vf 0 mac 52:54:00:aa:00:01`).

---

## 5. El subsistema USB — `lsusb` y manipulación de dispositivos

### 5.1 Primero la topología

```console
$ lsusb -t
/:  Bus 04.Port 1: Dev 1, Class=root_hub, Driver=xhci_hcd/2p, 10000M
/:  Bus 03.Port 1: Dev 1, Class=root_hub, Driver=xhci_hcd/4p, 5000M
    |__ Port 2: Dev 3, If 0, Class=Mass Storage, Driver=uas, 5000M
/:  Bus 02.Port 1: Dev 1, Class=root_hub, Driver=ehci-pci/2p, 480M
/:  Bus 01.Port 1: Dev 1, Class=root_hub, Driver=xhci_hcd/12p, 480M
    |__ Port 5: Dev 2, If 0, Class=Human Interface Device, Driver=usbhid, 12M
    |__ Port 7: Dev 4, If 0, Class=Vendor Specific Class, Driver=ftdi_sio, 12M
```

- El `5000M` / `480M` / `12M` del final es la velocidad **negociada**, no la capacidad del puerto. Un `480M` en un dispositivo que compraste como USB 3.x significa que enumeró en el controlador USB 2 acompañante — un cable malo, o el puerto físico está cableado al root hub EHCI.
- `Driver=uas` vs `Driver=usb-storage`: UAS (USB Attached SCSI) soporta encolado de comandos y es mucho más rápido, pero una lista bien conocida de chipsets puente corrompe datos bajo UAS. La mitigación es un **quirk**, cubierto en la §6.4.

### 5.2 Identidad y detalle

```console
$ lsusb
Bus 003 Device 003: ID 0781:5583 SanDisk Corp. Ultra Fit
Bus 001 Device 004: ID 0403:6001 Future Technology Devices International, Ltd FT232 Serial (UART) IC
Bus 001 Device 002: ID 046d:c52b Logitech, Inc. Unifying Receiver

$ lsusb -v -d 0781:5583 2>/dev/null | grep -E 'idVendor|idProduct|iSerial|bcdUSB|bMaxPower'
  bcdUSB               3.00
  idVendor           0x0781 SanDisk Corp.
  idProduct          0x5583 Ultra Fit
  iSerial                 3 4C530001180919103454
  bMaxPower             504mA
```

`ID vvvv:pppp` es el análogo USB del `[8086:1572]` de PCI. `iSerial` es lo que hace posible una regla de udev **por dispositivo** (§7).

Una alternativa subvalorada que no necesita la base de datos `pci.ids`/`usb.ids` e imprime el conjunto crudo de descriptores:

```console
$ usb-devices | sed -n '/SanDisk/,+3p'
S:  Manufacturer=USB
S:  Product=SanDisk 3.2Gen1
S:  SerialNumber=4C530001180919103454
C:  #Ifs= 1 Cfg#= 1 Atr=80 MxPwr=504mA
```

### 5.3 Manipular dispositivos USB en tiempo de ejecución

```console
# Power management: stop a flaky device from autosuspending
$ echo on | sudo tee /sys/bus/usb/devices/1-7/power/control
$ cat /sys/bus/usb/devices/1-7/power/autosuspend_delay_ms
2000

# Force a re-enumeration without physically unplugging
$ echo 0 | sudo tee /sys/bus/usb/devices/1-7/authorized
$ echo 1 | sudo tee /sys/bus/usb/devices/1-7/authorized

# Deny-by-default for a hardened host: nothing enumerates unless a rule allows it
$ echo 0 | sudo tee /sys/bus/usb/devices/usb1/authorized_default

# Unbind a single interface from its driver (note the "bus-port:config.interface" form)
$ echo 1-7:1.0 | sudo tee /sys/bus/usb/drivers/ftdi_sio/unbind
```

Para un motor de políticas de verdad, en lugar de escrituras sueltas, `usbguard` consume el mismo mecanismo `authorized` y lo expresa como reglas:

```
# /etc/usbguard/rules.conf
allow id 046d:c52b serial "" name "USB Receiver" with-interface { 03:01:01 03:01:02 }
allow id 0781:5583 serial "4C530001180919103454"
reject with-interface all-of { 03:*:* 08:*:* }   # reject HID+storage combos (BadUSB shape)
block
```

---

## 6. Módulos del kernel — `lsmod`, `modinfo`, `modprobe`

### 6.1 Qué está cargado

```console
$ lsmod | head -6
Module                  Size  Used by
i40e                  569344  0
nvme                   61440  4
nvme_core             180224  5 nvme
vfio_pci               16384  1
mlx5_core            2039808  1 mlx5_ib
```

`lsmod` es un formateador de `/proc/modules`. **La columna 3 (`Used by`) es un contador de referencias** — un valor distinto de cero es exactamente por lo que `modprobe -r` se va a negar:

```console
$ sudo modprobe -r nvme_core
modprobe: FATAL: Module nvme_core is in use.
```

### 6.2 Qué *es* un módulo, antes de cargarlo

```console
$ modinfo i40e | head -14
filename:       /lib/modules/6.8.0-45-generic/kernel/drivers/net/ethernet/intel/i40e/i40e.ko.zst
version:        2.24.6
license:        GPL v2
description:    Intel(R) Ethernet Connection XL710 Network Driver
firmware:       i40e/i40e-e2-7.13.1.0.fw
srcversion:     6F3F1A9A6D5A0F1B0F0AA1C
alias:          pci:v00008086d0000158Bsv*sd*bc*sc*i*
alias:          pci:v00008086d00001572sv*sd*bc*sc*i*
depends:
retpoline:      Y
intree:         Y
name:           i40e
vermagic:       6.8.0-45-generic SMP preempt mod_unload modversions
sig_id:         PKCS#7
parm:           debug:Debug level (0=none,...,16=all), Debug mask (0x8XXXXXXX) (uint)
```

Línea por línea, los campos que lee un ingeniero de plataforma:

| Campo | Por qué importa |
|---|---|
| `filename` | `.ko.zst`/`.ko.xz` — los módulos comprimidos necesitan soporte de `kmod` acorde |
| `firmware:` | El módulo necesita un **blob de `/lib/firmware`**. Faltante → el probe falla silenciosamente en el arranque (§9.3) |
| `alias:` | Los patrones MODALIAS que disparan la autocarga. `d00001572` ↔ `lspci -n` `[8086:1572]` |
| `depends:` | Cadena de dependencias resuelta por `modules.dep` |
| `vermagic:` | Debe coincidir exactamente con `uname -r`, o `insmod` falla con `Invalid module format` |
| `sig_id` | Bajo Secure Boot, un módulo sin firmar da `Required key not available` |
| `parm:` | Los parámetros ajustables que podés fijar vía `modprobe.d` o `/sys/module/<m>/parameters/` |

### 6.3 Autocarga: cómo un ID de PCI se convierte en un driver cargado

```console
$ cat /sys/bus/pci/devices/0000:81:00.0/modalias
pci:v00008086d00001572sv00008086sd00000000bc02sc00i00

$ grep -m1 'd00001572' /lib/modules/$(uname -r)/modules.alias
alias pci:v00008086d00001572sv*sd*bc*sc*i* i40e

$ modprobe --show-depends i40e
insmod /lib/modules/6.8.0-45-generic/kernel/drivers/net/ethernet/intel/i40e/i40e.ko.zst
```

La cadena: el kernel calcula `MODALIAS` → uevent → la regla de `udev` `ENV{MODALIAS}=="?*", IMPORT{builtin}="kmod load $env{MODALIAS}"` → `modprobe` matchea con `modules.alias` → el módulo carga → el `probe()` del driver enlaza.

`modules.alias` y `modules.dep` son **archivos generados**. Después de dejar caer un `.ko` fuera del árbol:

```console
$ sudo depmod -a
$ sudo modprobe my_driver
```

### 6.4 Configuración persistente de módulos — `/etc/modprobe.d/`

```ini
# /etc/modprobe.d/10-platform-nic.conf
# Intel X710: hold interrupt coalescing constant across the fleet; the driver
# default varies by version and silently changes p99 latency after upgrades.
options i40e  debug=0

# Mellanox CX-5: pre-allocate the ODP/steering pool used by the CNI.
options mlx5_core  probe_vf=0

# Blacklist: prevents *alias-based autoload* only. It does NOT stop an
# explicit `modprobe nouveau`, nor a load pulled in as a dependency.
blacklist nouveau
blacklist nvidiafb

# The only reliable "never load this" for a module something else may depend on:
install nouveau /bin/false

# Load-order dependency: guarantee vfio_iommu_type1 has allow_unsafe_interrupts
# before vfio-pci grabs anything.
options vfio_iommu_type1 allow_unsafe_interrupts=0
softdep vfio-pci pre: vfio_iommu_type1

# UAS quirk for a known-bad USB bridge (vendor:product:flags, u = ignore UAS)
options usb-storage quirks=174c:55aa:u
```

```ini
# /etc/modules-load.d/platform.conf — load at boot even with no matching device
br_netfilter
overlay
nf_conntrack
vfio-pci
```

Dos capas más de persistencia, en orden creciente de "se aplica más temprano":

```console
# 3. Kernel command line (applies before initramfs userspace):
$ cat /proc/cmdline
BOOT_IMAGE=/vmlinuz-6.8.0-45-generic root=UUID=... ro intel_iommu=on iommu=pt \
  module_blacklist=nouveau default_hugepagesz=1G hugepagesz=1G hugepages=16 \
  isolcpus=4-31,68-95 nohz_full=4-31,68-95 rcu_nocbs=4-31,68-95

# 4. Rebuild the initramfs after ANY modprobe.d change that affects boot-time drivers:
$ sudo dracut --force                    # RHEL/Fedora/SUSE
$ sudo update-initramfs -u -k all        # Debian/Ubuntu
```

> **La causa más común de "mi cambio en `modprobe.d` no hizo nada":** el módulo se carga desde el **initramfs**, que tiene su propia copia congelada de `/etc/modprobe.d`. Cambiás el archivo, te olvidás de la reconstrucción, y la configuración solo aplica a los módulos cargados después del pivot-root.

### 6.5 Inspección de parámetros en tiempo de ejecución

```console
$ ls /sys/module/nvme_core/parameters/
admin_timeout  apst_primary_latency_tol_us  default_ps_max_latency_us  io_timeout  multipath  shutdown_timeout
$ cat /sys/module/nvme_core/parameters/io_timeout
30
$ cat /sys/module/nvme_core/parameters/multipath
Y
```

Los parámetros con modo `0644` son escribibles en tiempo de ejecución; los `0444` requieren descarga/recarga o una entrada en la línea de comandos del kernel.

---

## 7. `udev` — volver determinista al hardware no determinista

### 7.1 El rol arquitectónico

`systemd-udevd` es la mitad en espacio de usuario del modelo de dispositivos. Recibe uevents del kernel por netlink y, según el conjunto de reglas, hace cinco cosas: **cargar módulos, nombrar interfaces, crear symlinks, fijar propiedad/permisos y etiquetar dispositivos** (que es cómo llegan a existir las unidades de dispositivo de systemd como `dev-disk-by\x2duuid-....device`).

Las reglas viven en tres directorios, **fusionados y procesados en orden lexicográfico de nombre de archivo a lo largo de los tres**:

| Directorio | Dueño | Precedencia |
|---|---|---|
| `/usr/lib/udev/rules.d/` | paquetes de la distribución | la más baja |
| `/run/udev/rules.d/` | runtime/volátil | intermedia |
| `/etc/udev/rules.d/` | **vos** | la más alta — un archivo con el mismo nombre acá *enmascara* por completo al del fabricante |

### 7.2 Gramática de las reglas

```
<match-key><op><value>, ... , <assign-key><op><value>, ...
```

| Operador | Significado |
|---|---|
| `==` | match, igual |
| `!=` | match, distinto |
| `=` | asignar |
| `+=` | agregar a una lista (`SYMLINK`, `TAG`, `RUN`) |
| `-=` | quitar de una lista |
| `:=` | asignar **final** — las reglas posteriores no pueden cambiarlo |

| Clave | Matchea |
|---|---|
| `ACTION` | `add`, `remove`, `change`, `bind`, `unbind` |
| `SUBSYSTEM` / `SUBSYSTEMS` | el subsistema de este dispositivo / de cualquier ancestro |
| `KERNEL` / `KERNELS` | el nombre de kernel de este dispositivo / de cualquier ancestro |
| `DRIVER` / `DRIVERS` | el driver de este dispositivo / de cualquier ancestro |
| `ATTR{x}` / `ATTRS{x}` | el atributo sysfs de este dispositivo / de cualquier ancestro |
| `ENV{x}` | variable de entorno del uevent/importada |
| `TAG` / `TAGS` | etiqueta de udev |
| `PROGRAM`, `IMPORT{program|builtin|db|file}` | ejecutar un helper, importar su salida |

| Asignación | Efecto |
|---|---|
| `NAME` | **Solo interfaces de red.** Renombrar dispositivos de bloque vía `NAME` no está soportado y rompe sistemas |
| `SYMLINK+=` | Ruta `/dev/...` adicional — la forma correcta de darle a un disco un nombre estable |
| `OWNER`, `GROUP`, `MODE` | Permisos del nodo |
| `RUN{program}+=` | Ejecutar un programa **corto y no bloqueante** (udev mata a los hijos de larga duración) |
| `TAG+=`, `ENV{x}=` | Metadatos para systemd/consumidores |

### 7.3 Un conjunto de reglas completo, con forma de producción

```bash
# /etc/udev/rules.d/70-platform-hardware.rules
#
# Fleet-wide deterministic hardware policy for cn-* nodes.
# Filename prefix 70 = after the distro's persistent-naming rules (60-*),
# before systemd's device-tagging rules (99-*).

# ---------------------------------------------------------------------------
# 1. Stable symlink for the dedicated etcd NVMe, identified by its serial.
#    /dev/nvme0n1 vs /dev/nvme1n1 flips with PCIe enumeration order after a
#    firmware update; the serial does not.
# ---------------------------------------------------------------------------
ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="nvme*n1", \
  ATTRS{serial}=="S6EUNJ0R500123", \
  SYMLINK+="disk/by-role/etcd-data", \
  ENV{PLATFORM_ROLE}="etcd"

# ---------------------------------------------------------------------------
# 2. I/O scheduler + read-ahead per media type. Rotational disks get bfq,
#    NVMe gets none (the device does its own queueing).
# ---------------------------------------------------------------------------
ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", \
  ATTR{queue/scheduler}="bfq", ATTR{queue/read_ahead_kb}="1024"
ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="nvme[0-9]*n[0-9]*", \
  ATTR{queue/scheduler}="none", ATTR{queue/nr_requests}="1023"

# ---------------------------------------------------------------------------
# 3. Data-plane NIC: jumbo frames + ring sizes at enumeration time, so the
#    setting exists before the CNI or DPDK app opens the interface.
#    RUN executes in udev's context: keep it fast, absolute paths only.
# ---------------------------------------------------------------------------
ACTION=="add", SUBSYSTEM=="net", ATTRS{vendor}=="0x8086", ATTRS{device}=="0x1572", \
  ENV{PLATFORM_NIC}="x710", \
  RUN+="/usr/sbin/ip link set %k mtu 9000", \
  RUN+="/usr/local/libexec/nic-ring-tune %k"

# ---------------------------------------------------------------------------
# 4. FTDI serial console adapters: stable path per physical USB port, so a
#    rack's console cabling survives a reboot. by-path, not by-serial —
#    adapters are replaced, the port is not.
# ---------------------------------------------------------------------------
SUBSYSTEM=="tty", SUBSYSTEMS=="usb", DRIVERS=="ftdi_sio", \
  ATTRS{devpath}=="7", SYMLINK+="console/rack-a-tor", \
  GROUP="dialout", MODE="0660"

# ---------------------------------------------------------------------------
# 5. Hand the second X710 port to vfio-pci as soon as it binds. Uses the
#    'bind' action so it fires on hotplug and rescan too, not just boot.
# ---------------------------------------------------------------------------
ACTION=="bind", SUBSYSTEM=="pci", KERNEL=="0000:81:00.1", \
  RUN+="/usr/bin/driverctl --nosave set-override 0000:81:00.1 vfio-pci"

# ---------------------------------------------------------------------------
# 6. Expose GPUs to the container runtime's supplementary group, no 0666.
# ---------------------------------------------------------------------------
SUBSYSTEM=="drm", KERNEL=="renderD*", GROUP="render", MODE="0660", TAG+="uaccess"

# ---------------------------------------------------------------------------
# 7. Security: any newly attached USB mass-storage device on a control-plane
#    node is left unauthorized; an operator must authorize it explicitly.
# ---------------------------------------------------------------------------
ACTION=="add", SUBSYSTEM=="usb", ENV{ID_USB_INTERFACES}=="*:08????:*", \
  ATTR{authorized}="0", \
  RUN+="/usr/bin/logger -t udev-policy -p auth.warning USB storage %k blocked: $env{ID_VENDOR_ID}:$env{ID_MODEL_ID}"
```

### 7.4 Nombres predecibles de interfaces de red — la capa `.link`

El nombrado de interfaces **ya no** es una regla de udev común; es el builtin `net_setup_link` gobernado por archivos `systemd.link`.

```console
$ udevadm info /sys/class/net/enp129s0f0 | grep -E 'ID_NET_NAME'
E: ID_NET_NAME_MAC=enx3cfdfea1b2c0
E: ID_NET_NAME_PATH=enp129s0f0
E: ID_NET_NAME_SLOT=ens2f0
```

El esquema de nombrado elige el primero disponible entre: `ID_NET_NAME_FROM_DATABASE` → `ONBOARD` → `SLOT` → `PATH` → `MAC`. Para sobrescribirlo:

```ini
# /etc/systemd/network/10-dataplane0.link
[Match]
MACAddress=3c:fd:fe:a1:b2:c0

[Link]
Name=dataplane0
MTUBytes=9000
```

> **Trampa de nombrado:** nunca asignes un nombre dentro del espacio de nombres propio del kernel (`eth0`, `wlan0`). El kernel puede crear un dispositivo con ese nombre de forma concurrente y el renombrado entra en carrera, dejando la interfaz atascada como `rename3`. Usá un prefijo que el kernel nunca genere.

Para deshabilitar por completo el nombrado predecible (solo en imágenes de appliances heredados): agregá `net.ifnames=0 biosdevname=0` a la línea de comandos del kernel.

### 7.5 El flujo de depuración con `udevadm` — el contenido real del examen

```console
# (a) What does udev believe about this device, right now?
$ udevadm info --query=all --name=/dev/nvme0n1
P: /devices/pci0000:80/0000:80:04.0/0000:82:00.0/nvme/nvme0/nvme0n1
N: nvme0n1
L: 0
S: disk/by-id/nvme-SAMSUNG_MZQL21T9HCJR-00A07_S6EUNJ0R500123
S: disk/by-role/etcd-data
E: DEVLINKS=/dev/disk/by-id/nvme-... /dev/disk/by-role/etcd-data
E: DEVNAME=/dev/nvme0n1
E: ID_SERIAL_SHORT=S6EUNJ0R500123
E: PLATFORM_ROLE=etcd

# (b) Which ATTRS{} can I match on, and at which level of the parent chain?
$ udevadm info -a -n /dev/nvme0n1 | head -22
  looking at device '/devices/pci0000:80/.../nvme/nvme0/nvme0n1':
    KERNEL=="nvme0n1"
    SUBSYSTEM=="block"
    DRIVER==""
    ATTR{queue/rotational}=="0"
    ATTR{size}=="3750748848"

  looking at parent device '/devices/pci0000:80/.../nvme/nvme0':
    KERNELS=="nvme0"
    SUBSYSTEMS=="nvme"
    ATTRS{model}=="SAMSUNG MZQL21T9HCJR-00A07"
    ATTRS{serial}=="S6EUNJ0R500123"
    ATTRS{firmware_rev}=="GDC5302Q"
```
> **La regla que atrapa a todo el mundo:** todos los `ATTRS{}` de una misma regla deben matchear **un único dispositivo padre**. No podés combinar `ATTRS{serial}` de la controladora NVMe con `ATTRS{vendor}` del puente PCI en la misma regla.

```console
# (c) Dry-run the rule set against an existing device — no reboot, no replug.
$ sudo udevadm test /sys/class/block/nvme0n1 2>&1 | grep -E '70-platform|DEVLINK'
Reading rules file: /etc/udev/rules.d/70-platform-hardware.rules
/etc/udev/rules.d/70-platform-hardware.rules:14 Adding link 'disk/by-role/etcd-data'
DEVLINKS=/dev/disk/by-id/nvme-... /dev/disk/by-role/etcd-data

# (d) Watch events live. KERNEL: = raw netlink. UDEV: = after rules ran.
#     A KERNEL line with no matching UDEV line = udevd failed or timed out.
$ udevadm monitor --udev --property --subsystem-match=block
monitor will print the received events for:
UDEV - the event which udev sends out after rule processing

UDEV  [18244.512901] add      /devices/pci0000:00/.../block/sdb (block)
ACTION=add
DEVNAME=/dev/sdb
ID_BUS=usb
ID_SERIAL=SanDisk_Ultra_Fit_4C530001180919103454-0:0

# (e) Reload rules and re-apply to devices already present (coldplug).
$ sudo udevadm control --reload
$ sudo udevadm trigger --action=change --subsystem-match=block
$ sudo udevadm settle --timeout=30

# (f) Verbose logging while reproducing a failure.
$ sudo udevadm control --log-priority=debug
$ journalctl -u systemd-udevd -f
$ sudo udevadm control --log-priority=info
```

`udevadm trigger` es la forma de reproducir el coldplug del arranque sin rebootear. `udevadm settle` es la primitiva de sincronización correcta en scripts de aprovisionamiento — nunca `sleep`.

### 7.6 `dbus` — donde el modelo de dispositivos se encuentra con las aplicaciones

`udev` habla **netlink**; no usa D-Bus. D-Bus entra una capa más arriba: los daemons consumen eventos de udev y re-publican el estado de los dispositivos en el **bus del sistema** como objetos con interfaces introspeccionables, de modo que las aplicaciones sin privilegios obtienen una vista de alto nivel mediada por políticas en lugar de acceso crudo a `/sys`.

| Capa | Transporte | Consumidor | Ejemplo |
|---|---|---|---|
| Kernel → udevd | uevent por netlink | `systemd-udevd` | `add /devices/.../block/sdb` |
| udevd → clientes de libudev | base de datos `/run/udev` + netlink | `udisksd`, `NetworkManager`, `upowerd` | `ID_FS_UUID=...` |
| Daemon → aplicaciones | **bus del sistema D-Bus** | gestores de archivos, escritorios, `virt-manager`, agentes de monitoreo | `org.freedesktop.UDisks2.Filesystem.Mount()` |

```console
$ busctl --system list | grep -E 'UDisks2|UPower|NetworkManager'
org.freedesktop.NetworkManager   1184 NetworkManager  root  :1.11  ...
org.freedesktop.UDisks2          1402 udisksd         root  :1.31  ...
org.freedesktop.UPower           1455 upowerd         root  :1.38  ...

$ busctl --system introspect org.freedesktop.UDisks2 \
    /org/freedesktop/UDisks2/block_devices/nvme0n1 org.freedesktop.UDisks2.Block \
  | grep -E 'Size|IdUUID|IdType'
.IdType         property  s   "xfs"          emits-change
.IdUUID         property  s   "8f3c...e21a"  emits-change
.Size           property  t   1920383410176  emits-change

$ gdbus call --system --dest org.freedesktop.UPower \
    --object-path /org/freedesktop/UPower \
    --method org.freedesktop.DBus.Properties.Get org.freedesktop.UPower OnBattery
(<false>,)
```

Conceptualmente para el examen: **`sysfs` es el modelo de dispositivos del kernel; `udev` es el motor de políticas en espacio de usuario que reacciona a él; `dbus` es el bus de IPC sobre el cual los servicios de más alto nivel exponen ese hardware a las aplicaciones.**

---

## 8. Tipos de dispositivos de almacenamiento masivo — diferenciarlos correctamente

```console
$ lsblk -o NAME,TYPE,SIZE,ROTA,TRAN,MODEL,SERIAL,MOUNTPOINTS
NAME        TYPE  SIZE ROTA TRAN   MODEL                     SERIAL           MOUNTPOINTS
nvme0n1     disk  1.8T    0 nvme   SAMSUNG MZQL21T9HCJR-00A07 S6EUNJ0R500123
├─nvme0n1p1 part  512M    0                                                   /boot/efi
└─nvme0n1p2 part  1.7T    0
  └─vg0-root lvm  200G    0                                                   /
sda         disk  7.3T    1 sas    ST8000NM0055-1RM112       ZA1FG7HX
sdb         disk   28G    0 usb    Ultra Fit                 4C530001180919103454
vda         disk   40G    0                                                   
```

| Tipo | Nombres de kernel | Pila de drivers | Rasgos distintivos |
|---|---|---|---|
| **PATA/IDE (heredado)** | históricamente `/dev/hd[a-d]` | `ide-*` (eliminado) → **`libata`** | Los kernels modernos presentan los discos PATA como `/dev/sd*`. Ver `/dev/hd*` en un sistema actual significa una controladora heredada emulada |
| **SATA/AHCI** | `/dev/sd[a-z]` | `ahci` → `libata` → capa media SCSI | Aparece como SCSI porque libata traduce ATA a comandos SCSI. `TRAN=sata` |
| **SAS / SCSI paralelo** | `/dev/sd*` | `mpt3sas`, `megaraid_sas`, `smartpqi` | Doble puerto, topologías con expansores; `lsscsi -t` muestra `sas:0x5000...` |
| **NVMe (PCIe)** | `/dev/nvme<ctrl>n<ns>p<part>` | `nvme` + `nvme_core` — **sin capa SCSI** | Namespaces, no LUNs. Múltiples colas, una por CPU. Nunca `/dev/sd*` |
| **NVMe over Fabrics** | mismo nombrado | `nvme_tcp`, `nvme_rdma`, `nvme_fc` | `nvme list-subsys` muestra el transporte; se comporta como NVMe local |
| **Almacenamiento masivo USB** | `/dev/sd*` | `usb-storage` (BOT) o `uas` (encolado) | `TRAN=usb`. UAS es más rápido pero propenso a quirks |
| **virtio-blk** | `/dev/vd[a-z]` | `virtio_blk` | Paravirtual; sin traducción SCSI, sobrecarga mínima |
| **virtio-scsi** | `/dev/sd*` | `virtio_scsi` | Paravirtual pero compatible con SCSI: soporta passthrough, >26 dispositivos, TRIM |
| **MMC/SD/eMMC** | `/dev/mmcblk<N>p<M>`, `/dev/mmcblk<N>boot0` | `mmc_block` | Dominante en ARM/embebidos; particiones de arranque separadas |
| **Device mapper** | `/dev/dm-<N>` + `/dev/mapper/<name>` | `dm-*` | LVM, LUKS, multipath — **virtuales**; la numeración `/dev/dm-N` es inestable, usá siempre `/dev/mapper/` |
| **MD RAID** | `/dev/md<N>` | `md` | `/proc/mdstat` es el archivo de estado |
| **Loop / zram / nbd** | `/dev/loop<N>`, `/dev/zram<N>`, `/dev/nbd<N>` | `loop`, `zram`, `nbd` | Respaldados por archivos, RAM o red |

El contrato de estabilidad:

```console
$ ls -l /dev/disk/
by-diskseq  by-id  by-label  by-partlabel  by-partuuid  by-path  by-uuid

$ ls -l /dev/disk/by-id/ | grep nvme0n1$
lrwxrwxrwx 1 root root 13 Aug 25 09:14 nvme-SAMSUNG_MZQL21T9HCJR-00A07_S6EUNJ0R500123 -> ../../nvme0n1
lrwxrwxrwx 1 root root 13 Aug 25 09:14 nvme-eui.343550304d3001230025384500000001 -> ../../nvme0n1

$ blkid /dev/nvme0n1p2
/dev/nvme0n1p2: UUID="8f3c1c0e-1a2b-4c3d-9e8f-0a1b2c3d4e5f" TYPE="LVM2_member" PARTUUID="a1b2c3d4-02"
```

| Identificador | Estable ante | Se rompe cuando |
|---|---|---|
| `/dev/sdX` | **nada** | cualquier cambio de enumeración |
| `by-path` | reemplazo del disco (identifica el **slot**) | recableado, cambio de controladora |
| `by-id` | recableado, reboot (identifica el **disco**) | reemplazo del disco |
| `by-uuid` / `by-label` | todo lo de ese sistema de archivos | reformateo, clon con `dd` (¡UUIDs duplicados!) |
| `by-partuuid` | recreación del sistema de archivos | reparticionado |

**Usá `by-uuid` en `/etc/fstab`, `by-path` para automatización de hot-swap basada en slot, `by-id` para dispositivos fijados a un rol.** Nunca `/dev/sdX` en configuración persistente.

---

## 9. Herramientas de inventario: CPU, memoria, firmware, virtualización

### 9.1 CPU y NUMA

```console
$ lscpu
Architecture:            x86_64
  CPU op-mode(s):        32-bit, 64-bit
  Address sizes:         46 bits physical, 57 bits virtual
  Byte Order:            Little Endian
CPU(s):                  128
  On-line CPU(s) list:   0-127
Vendor ID:               GenuineIntel
  Model name:            Intel(R) Xeon(R) Gold 6338 CPU @ 2.00GHz
    CPU family:          6
    Model:               106
    Thread(s) per core:  2
    Core(s) per socket:  32
    Socket(s):           2
    Stepping:            6
    CPU max MHz:         3200.0000
    CPU min MHz:         800.0000
Caches (sum of all):
  L1d:                   3 MiB (64 instances)
  L1i:                   2 MiB (64 instances)
  L2:                    80 MiB (64 instances)
  L3:                    96 MiB (2 instances)
NUMA:
  NUMA node(s):          2
  NUMA node0 CPU(s):     0-31,64-95
  NUMA node1 CPU(s):     32-63,96-127
Vulnerabilities:
  Spectre v2:            Mitigation; Enhanced / Automatic IBRS; IBPB conditional; ...

$ numactl -H
available: 2 nodes (0-1)
node 0 cpus: 0 1 2 ... 95
node 0 size: 257698 MB
node 0 free: 198334 MB
node 1 cpus: 32 33 ... 127
node 1 size: 257981 MB
node 1 free: 201002 MB
node distances:
node   0   1
  0:  10  21
  1:  21  10
```

Una `node distance` de `21` significa que un acceso entre sockets cuesta ~2,1× uno local. Ese número es toda la justificación del pinning consciente de NUMA.

```console
$ cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
performance
$ cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver
intel_pstate
$ cat /sys/devices/system/cpu/vulnerabilities/spectre_v2
Mitigation: Enhanced / Automatic IBRS; IBPB: conditional; RSB filling; PBRSB-eIBRS: SW sequence
$ cat /sys/devices/system/cpu/smt/active
1
```

### 9.2 Inventario de firmware — SMBIOS/DMI

```console
$ sudo dmidecode -s system-manufacturer
Dell Inc.
$ sudo dmidecode -s system-product-name
PowerEdge R750
$ sudo dmidecode -s system-serial-number
7QK4XM3
$ sudo dmidecode -s bios-version
1.13.2

$ sudo dmidecode -t 17 | grep -A6 'Memory Device' | head -12
Memory Device
	Array Handle: 0x1000
	Size: 32 GB
	Form Factor: DIMM
	Locator: A1
	Bank Locator: Not Specified
	Type: DDR4
	Speed: 3200 MT/s
	Manufacturer: Samsung
	Serial Number: 4A2C81F0
	Rank: 2
	Configured Memory Speed: 3200 MT/s
```

Un `Configured Memory Speed` por debajo de `Speed` significa que el controlador de memoria bajó la frecuencia de los DIMM — una población de DIMM mezclada o un regulador de voltaje subdimensionado. Cuesta ancho de banda medible y nunca aparece en las métricas de la aplicación.

Para acceso sin privilegios a los mismos datos de identidad (seguro en contenedores y para agentes de monitoreo):

```console
$ cat /sys/class/dmi/id/{sys_vendor,product_name,board_name,bios_version,chassis_asset_tag}
Dell Inc.
PowerEdge R750
0PJ80M
1.13.2
RACK-A-U14
```

### 9.3 ¿Estoy sobre hardware real?

```console
$ systemd-detect-virt
none
$ sudo virt-what
$ # (empty output = bare metal)

# On a guest:
$ systemd-detect-virt
kvm
$ sudo virt-what
kvm
$ sudo dmidecode -s system-product-name
KVM
```

Cualquier rol de aprovisionamiento que toque afinidad de IRQ, hugepages o SR-IOV debe condicionarse a esto. Esas perillas son inútiles o dañinas dentro de un guest.

### 9.4 Vistas de la máquina completa

```console
$ sudo lshw -class network -businfo
Bus info          Device      Class          Description
========================================================
pci@0000:81:00.0  enp129s0f0  network        Ethernet Controller X710 for 10GbE SFP+
pci@0000:81:00.1              network        Ethernet Controller X710 for 10GbE SFP+
pci@0000:01:00.0  eno1        network        NetXtreme BCM5720 Gigabit Ethernet PCIe

$ sudo lshw -short -class memory -class processor
H/W path        Device  Class       Description
===============================================
/0/0                    memory      64KiB BIOS
/0/400                  processor   Intel(R) Xeon(R) Gold 6338 CPU @ 2.00GHz
/0/1000                 memory      512GiB System Memory
```

`hwinfo --short` (centrado en SUSE) e `inxi -Fxz` (centrado en escritorio) cubren el mismo terreno; `lshw` es la opción portable para scripting gracias a `lshw -json`.

---

## 10. Infraestructura como código: hacer reproducibles los parámetros de hardware

Todo lo anterior es un `echo` puntual hacia `sysfs` — que sobrevive exactamente hasta el próximo reboot. Abajo está la capa de persistencia.

### 10.1 Rol de Ansible — configuración base de hardware

```yaml
---
# roles/hardware-baseline/tasks/main.yml
# Applies the fleet's hardware contract. Idempotent; safe to re-run.

- name: Collect virtualization type
  ansible.builtin.command: systemd-detect-virt
  register: virt_type
  changed_when: false
  failed_when: false

- name: Set bare-metal fact
  ansible.builtin.set_fact:
    is_bare_metal: "{{ virt_type.stdout | trim == 'none' }}"

- name: Assert the node matches the expected hardware SKU
  ansible.builtin.assert:
    that:
      - ansible_facts['product_name'] in allowed_skus
      - ansible_facts['processor_count'] | int == expected_sockets
    fail_msg: >-
      Node {{ inventory_hostname }} reports SKU '{{ ansible_facts['product_name'] }}'
      with {{ ansible_facts['processor_count'] }} socket(s); the platform contract
      requires one of {{ allowed_skus }} with {{ expected_sockets }} socket(s).
    quiet: true

# ---------------------------------------------------------------------------
# Kernel modules
# ---------------------------------------------------------------------------
- name: Install modprobe.d policy
  ansible.builtin.copy:
    dest: /etc/modprobe.d/10-platform.conf
    owner: root
    group: root
    mode: "0644"
    content: |
      # Managed by Ansible - roles/hardware-baseline. Do not edit by hand.
      options i40e debug=0
      softdep vfio-pci pre: vfio_iommu_type1
      install nouveau /bin/false
      blacklist nvidiafb
  notify:
    - Rebuild initramfs

- name: Load platform modules at boot
  ansible.builtin.copy:
    dest: /etc/modules-load.d/platform.conf
    owner: root
    group: root
    mode: "0644"
    content: |
      br_netfilter
      overlay
      nf_conntrack
      {{ 'vfio-pci' if is_bare_metal else '' }}
  notify:
    - Reload systemd-modules-load

- name: Ensure modules are loaded now
  community.general.modprobe:
    name: "{{ item }}"
    state: present
    persistent: present
  loop:
    - br_netfilter
    - overlay
    - nf_conntrack

# ---------------------------------------------------------------------------
# udev rules
# ---------------------------------------------------------------------------
- name: Install udev hardware policy
  ansible.builtin.template:
    src: 70-platform-hardware.rules.j2
    dest: /etc/udev/rules.d/70-platform-hardware.rules
    owner: root
    group: root
    mode: "0644"
    validate: "/usr/bin/udevadm verify %s"
  notify:
    - Reload udev rules

# ---------------------------------------------------------------------------
# Kernel command line (GRUB2)
# ---------------------------------------------------------------------------
- name: Configure kernel command line
  ansible.builtin.lineinfile:
    path: /etc/default/grub
    regexp: '^GRUB_CMDLINE_LINUX='
    line: >-
      GRUB_CMDLINE_LINUX="intel_iommu=on iommu=pt
      default_hugepagesz=1G hugepagesz=1G hugepages={{ hugepages_1g }}
      module_blacklist=nouveau
      isolcpus={{ isolated_cpus }} nohz_full={{ isolated_cpus }} rcu_nocbs={{ isolated_cpus }}"
    backup: true
  when: is_bare_metal
  notify:
    - Regenerate grub config

# ---------------------------------------------------------------------------
# SR-IOV: declarative, applied at every boot by a systemd unit
# ---------------------------------------------------------------------------
- name: Install SR-IOV VF provisioning unit
  ansible.builtin.template:
    src: sriov-vfs@.service.j2
    dest: /etc/systemd/system/sriov-vfs@.service
    owner: root
    group: root
    mode: "0644"
  when: is_bare_metal and sriov_pfs | length > 0
  notify:
    - Reload systemd

- name: Enable SR-IOV provisioning per PF
  ansible.builtin.systemd_service:
    name: "sriov-vfs@{{ item.pf }}.service"
    enabled: true
    state: started
    daemon_reload: true
  loop: "{{ sriov_pfs }}"
  when: is_bare_metal

# ---------------------------------------------------------------------------
# Verification: prove the contract holds, do not assume it
# ---------------------------------------------------------------------------
- name: Verify IOMMU is active
  ansible.builtin.stat:
    path: /sys/kernel/iommu_groups/0
  register: iommu_grp
  when: is_bare_metal

- name: Fail if IOMMU is inactive despite the kernel parameter
  ansible.builtin.fail:
    msg: >-
      intel_iommu=on is on the kernel cmdline but /sys/kernel/iommu_groups is
      empty. VT-d is disabled in firmware on {{ inventory_hostname }}.
  when:
    - is_bare_metal
    - not iommu_grp.stat.exists
    - "'intel_iommu=on' in ansible_facts['cmdline'] | default({}) | string"

- name: Verify hugepage reservation actually succeeded
  ansible.builtin.slurp:
    src: /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages
  register: hp
  when: is_bare_metal

- name: Fail on partial hugepage reservation
  ansible.builtin.fail:
    msg: >-
      Requested {{ hugepages_1g }} x 1GiB hugepages, kernel reserved
      {{ hp.content | b64decode | trim }}. Memory is too fragmented, or the
      cmdline change has not been applied (reboot pending).
  when:
    - is_bare_metal
    - (hp.content | b64decode | trim | int) != (hugepages_1g | int)
```

```yaml
---
# roles/hardware-baseline/handlers/main.yml
- name: Rebuild initramfs
  ansible.builtin.command: >-
    {{ 'dracut --force --regenerate-all'
       if ansible_facts['os_family'] in ['RedHat', 'Suse']
       else 'update-initramfs -u -k all' }}
  changed_when: true

- name: Reload systemd-modules-load
  ansible.builtin.systemd_service:
    name: systemd-modules-load.service
    state: restarted

- name: Reload udev rules
  ansible.builtin.shell: |
    set -euo pipefail
    udevadm control --reload
    udevadm trigger --action=change --subsystem-match=block --subsystem-match=net
    udevadm settle --timeout=60
  args:
    executable: /bin/bash
  changed_when: true

- name: Regenerate grub config
  ansible.builtin.command: >-
    {{ 'grub2-mkconfig -o /boot/grub2/grub.cfg'
       if ansible_facts['os_family'] == 'RedHat'
       else 'update-grub' }}
  changed_when: true

- name: Reload systemd
  ansible.builtin.systemd_service:
    daemon_reload: true
```

```yaml
---
# roles/hardware-baseline/defaults/main.yml
allowed_skus:
  - PowerEdge R750
  - PowerEdge R650
expected_sockets: 2
hugepages_1g: 16
isolated_cpus: "4-31,68-95"
sriov_pfs:
  - pf: enp129s0f0
    numvfs: 8
```

```ini
# roles/hardware-baseline/templates/sriov-vfs@.service.j2
# Declarative SR-IOV VF creation. Instance name = the PF interface.
[Unit]
Description=Create SR-IOV VFs on %i
After=sys-subsystem-net-devices-%i.device network-pre.target
Wants=sys-subsystem-net-devices-%i.device
Before=network.target kubelet.service
ConditionPathExists=/sys/class/net/%i/device/sriov_totalvfs

[Service]
Type=oneshot
RemainAfterExit=yes
# numvfs can only transition N -> 0 -> M; always drain first.
ExecStart=/bin/sh -c 'echo 0 > /sys/class/net/%i/device/sriov_numvfs'
ExecStart=/bin/sh -c 'echo {{ sriov_pfs | selectattr("pf", "equalto", "%i") | map(attribute="numvfs") | first | default(0) }} > /sys/class/net/%i/device/sriov_numvfs'
ExecStart=/bin/sh -c 'for i in $(seq 0 7); do /usr/sbin/ip link set %i vf $i spoofchk on trust off state auto || true; done'
ExecStop=/bin/sh -c 'echo 0 > /sys/class/net/%i/device/sriov_numvfs'

[Install]
WantedBy=multi-user.target
```

### 10.2 `cloud-init` — el mismo contrato en el primer arranque

```yaml
#cloud-config
# Applied at first boot on cn-* worker nodes.

write_files:
  - path: /etc/modprobe.d/10-platform.conf
    owner: root:root
    permissions: "0644"
    content: |
      options i40e debug=0
      softdep vfio-pci pre: vfio_iommu_type1
      install nouveau /bin/false

  - path: /etc/modules-load.d/platform.conf
    owner: root:root
    permissions: "0644"
    content: |
      br_netfilter
      overlay
      vfio-pci

  - path: /etc/udev/rules.d/70-platform-hardware.rules
    owner: root:root
    permissions: "0644"
    content: |
      ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="nvme[0-9]*n[0-9]*", \
        ATTR{queue/scheduler}="none", ATTR{queue/nr_requests}="1023"
      ACTION=="add", SUBSYSTEM=="net", ATTRS{vendor}=="0x8086", ATTRS{device}=="0x1572", \
        RUN+="/usr/sbin/ip link set %k mtu 9000"

  - path: /etc/systemd/network/10-dataplane0.link
    owner: root:root
    permissions: "0644"
    content: |
      [Match]
      Property=ID_NET_NAME_PATH=enp129s0f0

      [Link]
      Name=dataplane0
      MTUBytes=9000

bootcmd:
  # bootcmd runs on EVERY boot, before the network comes up.
  - [ sh, -c, "echo performance | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor || true" ]

runcmd:
  - [ udevadm, control, --reload ]
  - [ udevadm, trigger, --action=change ]
  - [ udevadm, settle, --timeout=60 ]
  - [ dracut, --force ]
  - [ sh, -c, "sed -i 's/^GRUB_CMDLINE_LINUX=\"/GRUB_CMDLINE_LINUX=\"intel_iommu=on iommu=pt default_hugepagesz=1G hugepagesz=1G hugepages=16 /' /etc/default/grub" ]
  - [ grub2-mkconfig, -o, /boot/grub2/grub.cfg ]

power_state:
  mode: reboot
  message: "Rebooting to apply hardware baseline (IOMMU + hugepages)"
  condition: true
```

### 10.3 Exponer el hardware a Kubernetes

Una vez configurado el nodo, el scheduler todavía no sabe nada. Tres manifiestos cierran esa brecha.

**(a) Node Feature Discovery — convertir IDs de PCI en etiquetas de nodo:**

```yaml
---
apiVersion: nfd.k8s-sigs.io/v1alpha1
kind: NodeFeatureRule
metadata:
  name: platform-hardware-baseline
spec:
  rules:
    # Label nodes carrying an Intel X710 data-plane NIC.
    - name: "intel-x710-nic"
      labels:
        platform.example.com/nic: "x710"
        platform.example.com/dataplane: "true"
      matchFeatures:
        - feature: pci.device
          matchExpressions:
            vendor: {op: In, value: ["8086"]}
            device: {op: In, value: ["1572", "1583", "1584", "1581"]}

    # Label nodes whose CPUs expose the instruction sets our runtime needs.
    - name: "avx512-capable"
      labels:
        platform.example.com/simd: "avx512"
      matchFeatures:
        - feature: cpu.cpuid
          matchExpressions:
            AVX512F: {op: Exists}
            AVX512DQ: {op: Exists}

    # Taint-driver pairing: nodes with an active IOMMU can host VFIO workloads.
    - name: "iommu-enabled"
      labels:
        platform.example.com/iommu: "enabled"
      matchFeatures:
        - feature: kernel.config
          matchExpressions:
            INTEL_IOMMU: {op: In, value: ["y"]}
        - feature: system.osrelease
          matchExpressions:
            ID: {op: In, value: ["rhel", "centos", "rocky", "ubuntu"]}

    # Composite rule: only nodes that have BOTH the NIC and 1GiB hugepages.
    - name: "dpdk-ready"
      labels:
        platform.example.com/dpdk: "ready"
      matchFeatures:
        - feature: pci.device
          matchExpressions:
            vendor: {op: In, value: ["8086"]}
            class: {op: In, value: ["0200"]}
        - feature: memory.nv
          matchExpressions:
            devtype: {op: Exists}
      matchAny:
        - matchFeatures:
            - feature: kernel.version
              matchExpressions:
                major: {op: Gt, value: ["5"]}
```

**(b) Device plugin de SR-IOV — convertir las VF en un recurso planificable:**

```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: sriovdp-config
  namespace: kube-system
data:
  config.json: |
    {
      "resourceList": [
        {
          "resourceName": "intel_sriov_netdevice",
          "resourcePrefix": "platform.example.com",
          "selectors": {
            "vendors": ["8086"],
            "devices": ["154c", "1889"],
            "drivers": ["iavf", "i40evf"],
            "pfNames": ["enp129s0f0#0-7"],
            "isRdma": false
          }
        },
        {
          "resourceName": "intel_sriov_dpdk",
          "resourcePrefix": "platform.example.com",
          "selectors": {
            "vendors": ["8086"],
            "devices": ["154c"],
            "drivers": ["vfio-pci"],
            "pfNames": ["enp129s0f1#0-7"]
          }
        }
      ]
    }
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: sriov-device-plugin
  namespace: kube-system
  labels:
    app.kubernetes.io/name: sriov-device-plugin
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: sriov-device-plugin
  updateStrategy:
    type: RollingUpdate
  template:
    metadata:
      labels:
        app.kubernetes.io/name: sriov-device-plugin
    spec:
      # Only land on nodes NFD has already confirmed carry the hardware.
      nodeSelector:
        platform.example.com/nic: "x710"
      hostNetwork: true
      priorityClassName: system-node-critical
      tolerations:
        - operator: Exists
          effect: NoSchedule
      serviceAccountName: sriov-device-plugin
      containers:
        - name: kube-sriovdp
          image: ghcr.io/k8snetworkplumbingwg/sriov-network-device-plugin:v3.7.0
          imagePullPolicy: IfNotPresent
          args:
            - --log-dir=sriovdp
            - --log-level=10
            - --resource-prefix=platform.example.com
          securityContext:
            privileged: true
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          resources:
            requests:
              cpu: "50m"
              memory: "64Mi"
            limits:
              cpu: "200m"
              memory: "256Mi"
          volumeMounts:
            - name: devicesock
              mountPath: /var/lib/kubelet/device-plugins
            - name: plugins-registry
              mountPath: /var/lib/kubelet/plugins_registry
            - name: log
              mountPath: /var/log
            - name: config-volume
              mountPath: /etc/pcidp
              readOnly: true
            - name: device-info
              mountPath: /var/run/k8s.cni.cncf.io/devinfo/dp
      volumes:
        - name: devicesock
          hostPath:
            path: /var/lib/kubelet/device-plugins
            type: Directory
        - name: plugins-registry
          hostPath:
            path: /var/lib/kubelet/plugins_registry
            type: Directory
        - name: log
          hostPath:
            path: /var/log
            type: Directory
        - name: device-info
          hostPath:
            path: /var/run/k8s.cni.cncf.io/devinfo/dp
            type: DirectoryOrCreate
        - name: config-volume
          configMap:
            name: sriovdp-config
            items:
              - key: config.json
                path: config.json
```

**(c) Configuración del kubelet + una carga de trabajo que consume el hardware:**

```yaml
---
# /var/lib/kubelet/config.yaml  (fragment)
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
# Exclusive CPUs for Guaranteed pods with integral CPU requests.
cpuManagerPolicy: static
cpuManagerPolicyOptions:
  full-pcpus-only: "true"
# Refuse to admit a pod whose CPU, memory and devices cannot all be
# satisfied from one NUMA node. Without this, the §1 incident is unfixable.
topologyManagerPolicy: single-numa-node
topologyManagerScope: pod
memoryManagerPolicy: Static
reservedSystemCPUs: "0-3,64-67"
systemReserved:
  cpu: "2"
  memory: "4Gi"
kubeReserved:
  cpu: "2"
  memory: "4Gi"
reservedMemory:
  - numaNode: 0
    limits:
      memory: 4Gi
  - numaNode: 1
    limits:
      memory: 4Gi
evictionHard:
  memory.available: "500Mi"
  nodefs.available: "10%"
featureGates:
  MemoryManager: true
```

```yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: packet-gateway
  namespace: dataplane
spec:
  replicas: 4
  selector:
    matchLabels:
      app: packet-gateway
  template:
    metadata:
      labels:
        app: packet-gateway
      annotations:
        k8s.v1.cni.cncf.io/networks: sriov-dataplane
    spec:
      nodeSelector:
        platform.example.com/dpdk: "ready"
        platform.example.com/simd: "avx512"
      runtimeClassName: runc
      containers:
        - name: gateway
          image: registry.example.com/dataplane/packet-gateway:2.14.0
          securityContext:
            capabilities:
              add: ["IPC_LOCK", "NET_RAW"]
              drop: ["ALL"]
            allowPrivilegeEscalation: false
          resources:
            # Guaranteed QoS + integral CPU => exclusive cores from CPU Manager.
            # Topology Manager then forces devices + memory onto the same NUMA node.
            requests:
              cpu: "8"
              memory: "16Gi"
              hugepages-1Gi: "8Gi"
              platform.example.com/intel_sriov_dpdk: "1"
            limits:
              cpu: "8"
              memory: "16Gi"
              hugepages-1Gi: "8Gi"
              platform.example.com/intel_sriov_dpdk: "1"
          volumeMounts:
            - name: hugepage-1gi
              mountPath: /dev/hugepages
            - name: vfio
              mountPath: /dev/vfio
      volumes:
        - name: hugepage-1gi
          emptyDir:
            medium: HugePages-1Gi
        - name: vfio
          hostPath:
            path: /dev/vfio
            type: Directory
```

```console
$ kubectl get node cn-fra1-042 -o jsonpath='{.status.allocatable}' | jq
{
  "cpu": "124",
  "ephemeral-storage": "1798451234Ki",
  "hugepages-1Gi": "16Gi",
  "memory": "519438336Ki",
  "platform.example.com/intel_sriov_dpdk": "8",
  "platform.example.com/intel_sriov_netdevice": "8",
  "pods": "250"
}
$ kubectl get node cn-fra1-042 -o jsonpath='{.metadata.labels}' | jq 'with_entries(select(.key|startswith("platform")))'
{
  "platform.example.com/dataplane": "true",
  "platform.example.com/dpdk": "ready",
  "platform.example.com/iommu": "enabled",
  "platform.example.com/nic": "x710",
  "platform.example.com/simd": "avx512"
}
```

La cadena completa queda ahora cerrada: **firmware → `sysfs` → `udev` → etiqueta de nodo → decisión del scheduler.**

---

## 11. Verificación y diagnóstico de fallas

### 11.1 Script de verificación de la línea base

```bash
#!/usr/bin/env bash
# /usr/local/sbin/verify-hardware-baseline
# Exits non-zero on the first contract violation. Run from CI, from Ansible,
# and from the node-problem-detector.
set -euo pipefail

fail() { printf '\033[31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }
ok()   { printf '\033[32m OK \033[0m %s\n' "$*"; }

# --- 1. Every PCI device that has a driver available has it bound -----------
unbound=$(lspci -nnk | awk '
  /^[0-9a-f]{2}:/ { dev=$0; drv=""; mods="" }
  /Kernel driver in use/ { drv=$0 }
  /Kernel modules/ { mods=$0; if (drv == "") print dev }')
[[ -z "$unbound" ]] || fail "PCI devices with an available but unbound driver:
$unbound"
ok "all PCI devices with an available driver are bound"

# --- 2. No firmware load failures in the current boot -----------------------
if journalctl -kb --no-pager | grep -qE 'Direct firmware load for .* failed'; then
  journalctl -kb --no-pager | grep -E 'Direct firmware load for .* failed' | head -5
  fail "missing firmware blobs (install linux-firmware / vendor package)"
fi
ok "no firmware load failures this boot"

# --- 3. IOMMU active if the cmdline asked for it ----------------------------
if grep -qE '(intel|amd)_iommu=on' /proc/cmdline; then
  [[ -d /sys/kernel/iommu_groups/0 ]] \
    || fail "IOMMU requested on cmdline but no groups exist -> VT-d/AMD-Vi off in firmware"
  ok "IOMMU active ($(ls /sys/kernel/iommu_groups | wc -l) groups)"
fi

# --- 4. Hugepages actually reserved -----------------------------------------
want=$(sed -n 's/.*hugepages=\([0-9]*\).*/\1/p' /proc/cmdline)
if [[ -n "${want:-}" ]]; then
  got=$(cat /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages)
  [[ "$want" == "$got" ]] || fail "hugepages requested=$want reserved=$got (fragmentation)"
  ok "hugepages reserved: $got x 1GiB"
fi

# --- 5. Data-plane NICs are NUMA-local and at full link width ----------------
for pf in /sys/class/net/*/device; do
  iface=$(basename "$(dirname "$pf")")
  [[ -e "$pf/numa_node" ]] || continue
  node=$(cat "$pf/numa_node")
  [[ "$node" != "-1" ]] || fail "$iface reports numa_node=-1 (broken ACPI SRAT; check BIOS)"
  if [[ -e "$pf/current_link_width" && -e "$pf/max_link_width" ]]; then
    cur=$(cat "$pf/current_link_width"); max=$(cat "$pf/max_link_width")
    [[ "$cur" == "$max" ]] || fail "$iface negotiated x$cur of x$max (wrong slot / bad riser)"
  fi
done
ok "all NICs report a valid NUMA node and full link width"

# --- 6. No IRQ collapsed onto a single CPU ----------------------------------
hot=$(awk 'NR>1 && $NF ~ /TxRx|nvme[0-9]+q[1-9]/ {
             max=0; sum=0
             for (i=2; i<=NF-3; i++) { sum+=$i; if ($i>max) max=$i }
             if (sum > 1000000 && max > 0.95*sum) print $NF
           }' /proc/interrupts)
[[ -z "$hot" ]] || fail "IRQs with >95% of events on one CPU: $hot"
ok "interrupt distribution is spread"

# --- 7. Persistent device symlinks resolve ----------------------------------
for link in /dev/disk/by-role/*; do
  [[ -e "$link" ]] || fail "stale role symlink: $link (udev rule matched nothing)"
done
ok "all by-role symlinks resolve"

printf '\n\033[32mhardware baseline verified\033[0m on %s\n' "$(hostname -f)"
```

```console
$ sudo /usr/local/sbin/verify-hardware-baseline
 OK  all PCI devices with an available driver are bound
 OK  no firmware load failures this boot
 OK  IOMMU active (143 groups)
 OK  hugepages reserved: 16 x 1GiB
 OK  all NICs report a valid NUMA node and full link width
 OK  interrupt distribution is spread
 OK  all by-role symlinks resolve

hardware baseline verified on cn-fra1-042.example.com
```

### 11.2 Manuales de falla

#### Falla A — el dispositivo no aparece en `/dev` en absoluto

Recorré la cadena de enumeración **en orden**. Frená en la primera etapa que falle; todo lo que sigue es un síntoma.

```console
# Stage 1: does the bus see it?
$ lspci -nn | grep -i 81:00
81:00.0 Ethernet controller [0200]: Intel Corporation Ethernet Controller X710 [8086:1572]
#   -> Nothing here? Bus-level problem: disabled in firmware, dead slot,
#      unseated card, or the parent bridge did not train. Check `dmesg | grep -i pci`.

# Stage 2: is a driver bound?
$ lspci -nnk -s 81:00.0 | grep -E 'driver|modules'
	Kernel modules: i40e
#   -> "Kernel modules" present but no "Kernel driver in use" = probe failed.

# Stage 3: why did probe fail?
$ sudo dmesg | grep -iE 'i40e|firmware|8086:1572'
[   12.114553] i40e: Intel(R) Ethernet Connection XL710 Network Driver
[   12.331902] i40e 0000:81:00.0: Direct firmware load for i40e/i40e-e2-7.13.1.0.fw failed with error -2
[   12.331910] i40e 0000:81:00.0: Failed to init adminq: -19
[   12.342118] i40e: probe of 0000:81:00.0 failed with error -19

# Stage 4: is the module even loadable?
$ modinfo i40e >/dev/null && echo present || echo missing
present
$ sudo modprobe i40e; echo "exit=$?"
exit=0

# Stage 5: is it blacklisted?
$ grep -rE '^(blacklist|install).*i40e' /etc/modprobe.d/ /usr/lib/modprobe.d/
$ grep -oE 'module_blacklist=[^ ]*|modprobe.blacklist=[^ ]*' /proc/cmdline

# Stage 6: does sysfs have the class device?
$ ls -d /sys/class/net/* 2>/dev/null
#   -> Present in /sys but missing in /dev => udev problem. Go to Failure C.
```

**Resolución para el caso anterior:** falta el blob de firmware.

```console
$ ls /lib/firmware/i40e/ 2>/dev/null
$ sudo dnf install -y linux-firmware        # or: apt install firmware-misc-nonfree
$ echo 1 | sudo tee /sys/bus/pci/devices/0000:81:00.0/remove
$ echo 1 | sudo tee /sys/bus/pci/rescan
$ lspci -nnk -s 81:00.0 | grep 'driver in use'
	Kernel driver in use: i40e
```

> Si el firmware vive en la ruta del initramfs (drivers del sistema de archivos raíz), reinstalar el paquete no alcanza — hay que reconstruir el initramfs.

#### Falla B — el módulo se niega a cargar

| Mensaje de `dmesg` / `modprobe` | Causa raíz | Solución |
|---|---|---|
| `Invalid module format` | Desajuste de `vermagic`: módulo compilado para otro kernel | Recompilar contra `uname -r`; revisar el estado de DKMS |
| `Required key not available` | Secure Boot rechazando un módulo sin firmar | Firmar con la MOK, o `mokutil --disable-validation` (entendiendo el costo de seguridad) |
| `Unknown symbol X (err -2)` | Dependencia no cargada o símbolo eliminado | `modprobe` (no `insmod`); ejecutar `depmod -a` |
| `Module X is in use` en `-r` | Contador de referencias distinto de cero | `lsmod \| grep X` columna 3; detener antes a los consumidores |
| `No such device` después de una carga limpia | Módulo cargado, sin hardware coincidente, o desajuste de alias | Comparar `cat .../modalias` con `modinfo -F alias` |
| `modprobe: FATAL: Module X not found` | No compilado/instalado para este kernel | `find /lib/modules/$(uname -r) -name 'X.ko*'`; `depmod -a` |
| No hace nada en silencio | `install X /bin/false` en `modprobe.d` | `modprobe --show-depends X` revela el override |

```console
$ sudo insmod ./my_driver.ko
insmod: ERROR: could not insert module ./my_driver.ko: Invalid module format
$ modinfo -F vermagic ./my_driver.ko
6.5.0-21-generic SMP preempt mod_unload modversions
$ uname -r
6.8.0-45-generic
#   ^ Mismatch confirmed. Rebuild, or install the DKMS package.

$ dkms status
my_driver/1.4.2, 6.5.0-21-generic, x86_64: installed
$ sudo dkms install my_driver/1.4.2 -k 6.8.0-45-generic
```

#### Falla C — una regla de `udev` no se dispara

```console
# 1. Syntax. udevadm silently ignores malformed rules; verify explicitly.
$ sudo udevadm verify /etc/udev/rules.d/70-platform-hardware.rules
/etc/udev/rules.d/70-platform-hardware.rules: udev rules check failed
  :12 Invalid key 'ATTRS{seriall}'

# 2. Did you reload? Editing the file changes nothing on its own.
$ sudo udevadm control --reload

# 3. Dry-run against the real device and read which rules matched.
$ sudo udevadm test /sys/class/block/nvme0n1 2>&1 | grep -E 'Reading rules|70-platform|no matching'

# 4. Confirm the attribute you matched exists at the level you matched it.
$ udevadm info -a -n /dev/nvme0n1 | grep -n 'serial'
     19:    ATTRS{serial}=="S6EUNJ0R500123"
#   ^ This is under "looking at parent device .../nvme/nvme0". ATTRS{} is
#     correct here; ATTR{} would NOT match, because the attribute belongs to
#     the parent, not to nvme0n1 itself.

# 5. Rule ordering: an earlier :=  assignment cannot be overridden.
$ grep -rn 'SYMLINK' /usr/lib/udev/rules.d/ /etc/udev/rules.d/ | grep ':='

# 6. Was the event delivered at all?
$ udevadm monitor --kernel --udev &
$ sudo udevadm trigger --action=change --sysname-match=nvme0n1
KERNEL[19022.4] change /devices/.../nvme0n1 (block)
UDEV  [19022.5] change /devices/.../nvme0n1 (block)
#   ^ KERNEL with no UDEV counterpart = udevd crashed, is stuck, or the
#     event timed out. Check: journalctl -u systemd-udevd -b

# 7. Worker exhaustion under mass hotplug (200-disk JBOD enumeration):
$ journalctl -u systemd-udevd -b | grep -i 'timeout\|worker'
systemd-udevd[812]: nvme0n1: Worker [1093] processing SEQNUM=8241 killed
#   -> A RUN+= program is blocking. Move slow work into a systemd unit
#      triggered by TAG+="systemd", ENV{SYSTEMD_WANTS}="myjob@%k.service"
```

El patrón correcto para trabajo lento dentro de una regla:

```bash
# WRONG: udev kills the worker after event_timeout (default 180s), and blocks
#        the whole worker pool meanwhile.
ACTION=="add", SUBSYSTEM=="block", RUN+="/usr/local/bin/full-disk-scan %k"

# RIGHT: hand off to systemd, return immediately.
ACTION=="add", SUBSYSTEM=="block", KERNEL=="sd[a-z]", \
  TAG+="systemd", ENV{SYSTEMD_WANTS}="disk-scan@%k.service"
```

#### Falla D — interfaz renombrada tras un cambio de kernel o de hardware

```console
$ ip link show
3: rename3: <BROADCAST,MULTICAST> mtu 1500 qdisc noop state DOWN mode DEFAULT
#   ^ classic symptom: a rename raced with the kernel's own name

$ udevadm info /sys/class/net/rename3 | grep ID_NET_NAME
E: ID_NET_NAME_MAC=enx3cfdfea1b2c0
E: ID_NET_NAME_PATH=enp129s0f0
E: ID_NET_NAME_SLOT=ens2f0

$ journalctl -b -u systemd-udevd | grep -i 'rename\|Could not'
systemd-udevd[794]: eth0: Failed to rename network interface 3 from 'eth0' to 'eth0': File exists
```

Solución: elegí un nombre fuera del espacio de nombres del kernel y fijalo por MAC.

```ini
# /etc/systemd/network/10-dataplane0.link
[Match]
MACAddress=3c:fd:fe:a1:b2:c0

[Link]
Name=dataplane0
```

```console
$ sudo udevadm control --reload
$ sudo udevadm trigger --action=add --subsystem-match=net
$ ip -br link show dataplane0
dataplane0       UP             3c:fd:fe:a1:b2:c0 <BROADCAST,MULTICAST,UP,LOWER_UP>
```

> **Nota de causa raíz para contenedores/VMs:** si `ID_NET_NAME_SLOT` e `ID_NET_NAME_PATH` cambian ambos después de una migración de hipervisor, la topología PCI cambió. Fijá sobre `MACAddress` o `Property=ID_NET_NAME_MAC=`, nunca sobre el slot.

#### Falla E — `numa_node = -1`

```console
$ cat /sys/bus/pci/devices/0000:81:00.0/numa_node
-1
$ dmesg | grep -i 'SRAT\|no numa node'
[    0.000000] ACPI: SRAT not present
[    2.410332] pci 0000:81:00.0: [8086:1572] type 00 ... has invalid NUMA node -1, changing to 0
```

La tabla ACPI SRAT del firmware está ausente o mal. El scheduler va a ubicar los manejadores de interrupciones de forma arbitraria. Opciones, en orden de preferencia:

1. **Arreglar el firmware** — actualizar el BIOS; verificar que "NUMA / Node Interleaving" esté en *NUMA enabled* (node interleaving **deshabilitado**).
2. **Sobrescribir en tiempo de ejecución** — solo válido si podés probar cuál es el nodo correcto a partir del puente raíz PCI:
   ```console
   $ echo 1 | sudo tee /sys/bus/pci/devices/0000:81:00.0/numa_node
   ```
   Persistilo con una regla de udev con `ACTION=="add", SUBSYSTEM=="pci", KERNEL=="0000:81:00.0", ATTR{numa_node}="1"`.
3. **Deshabilitar `topologyManagerPolicy: single-numa-node`** — de lo contrario cada pod que pida ese dispositivo será rechazado en la admisión con `TopologyAffinityError`.

#### Falla F — dispositivo presente pero descomunalmente lento

```console
$ sudo lspci -vv -s 81:00.0 | grep -E 'LnkCap|LnkSta'
		LnkCap:	Port #0, Speed 16GT/s, Width x8, ASPM L1
		LnkSta:	Speed 2.5GT/s (downgraded), Width x4 (downgraded)
```

`(downgraded)` en cualquiera de los dos campos es concluyente. Causas, ordenadas por frecuencia: slot físico equivocado (x4 eléctrico en un conector mecánico x8), una placa riser, bifurcación mal configurada en el firmware, ASPM estacionando agresivamente el enlace, o una falla marginal de integridad de señal que fuerza el reentrenamiento.

```console
# Rule out ASPM first — it is free to test.
$ sudo lspci -vv -s 81:00.0 | grep -i 'LnkCtl'
		LnkCtl:	ASPM L1 Enabled; RCB 64 bytes, Disabled- CommClk+
# Persistent test: add pcie_aspm=off to the kernel cmdline and re-measure.

# Then check the correctable-error counters — a retraining link logs here.
$ sudo lspci -vv -s 81:00.0 | grep -A3 'Correctable Error'
$ sudo dmesg | grep -i 'aer\|corrected'
[  118.442901] pcieport 0000:80:01.0: AER: Corrected error received: 0000:81:00.0
[  118.442918] i40e 0000:81:00.0: PCIe Bus Error: severity=Corrected, type=Physical Layer
```

Las tormentas de AER corregidos significan un problema físico: reasentar la placa, reemplazar el riser, limpiar el conector.

---

## 12. Referencia de comandos y archivos — consolidación para el examen

| Comando | Lee / escribe | Usalo para |
|---|---|---|
| `lspci -nnk`, `-tv`, `-vvv` | espacio de configuración PCI | Dispositivos, IDs, drivers enlazados, estado del enlace |
| `lsusb`, `lsusb -t`, `lsusb -v` | descriptores USB | Topología USB, velocidades, números de serie |
| `lsmod` | `/proc/modules` | Módulos cargados y contadores de referencias |
| `modprobe [-r] [-v] [--show-depends]` | `modules.dep`, `modprobe.d` | Cargar/descargar con resolución de dependencias |
| `insmod` / `rmmod` | syscall directa | Carga de un solo archivo — **sin manejo de dependencias** |
| `modinfo` | secciones ELF del módulo | Parámetros, alias, firmware, vermagic, dependencias |
| `depmod -a` | `/lib/modules/$(uname -r)/` | Reconstruir `modules.dep` / `modules.alias` |
| `udevadm info \| test \| monitor \| trigger \| settle \| control` | base de datos y reglas de udev | Toda la superficie de depuración de udev |
| `lsblk`, `blkid`, `lsscsi`, `nvme list` | capa de bloques | Topología e identidad del almacenamiento |
| `lscpu`, `numactl -H` | `/sys/devices/system/{cpu,node}` | Topología de CPU/NUMA |
| `dmidecode -t <n> \| -s <str>` | tablas SMBIOS | Inventario de chasis, BIOS, DIMM |
| `lshw`, `hwinfo`, `inxi` | agregado | Instantánea de la máquina completa |
| `systemd-detect-virt`, `virt-what` | DMI/CPUID | Bare metal vs guest |
| `busctl`, `gdbus`, `dbus-send` | bus del sistema D-Bus | Estado de dispositivos expuesto por udisks2/UPower/NM |
| `setpci` | configuración PCI cruda | Manipulación de registros como último recurso — **puede colgar la máquina** |

| Ruta | Contenido |
|---|---|
| `/proc/cpuinfo`, `/proc/meminfo` | Flags de CPU; totales de memoria incluyendo `HugePages_*` |
| `/proc/interrupts`, `/proc/irq/N/smp_affinity` | Censo de interrupciones y afinidad |
| `/proc/ioports`, `/proc/iomem`, `/proc/dma` | Mapas de puertos de E/S, MMIO y DMA ISA heredado |
| `/proc/modules`, `/proc/cmdline`, `/proc/mdstat` | Módulos, parámetros de arranque, MD RAID |
| `/sys/bus/<bus>/devices/`, `/sys/bus/<bus>/drivers/*/{bind,unbind}` | Modelo de dispositivos y binding de drivers |
| `/sys/class/<class>/`, `/sys/devices/`, `/sys/module/<m>/parameters/` | Vista por clase, vista de topología, parámetros en vivo |
| `/sys/kernel/iommu_groups/`, `/sys/kernel/mm/hugepages/` | Agrupamiento IOMMU, pools de hugepages |
| `/sys/class/dmi/id/*`, `/sys/firmware/{acpi,devicetree}/` | DMI sin privilegios; tablas ACPI / Device Tree |
| `/dev/disk/by-{id,uuid,path,partuuid}/`, `/dev/mapper/` | Identificadores estables de almacenamiento |
| `/etc/modprobe.d/`, `/etc/modules-load.d/` | Opciones de módulos, blacklists, cargas en el arranque |
| `/etc/udev/rules.d/` (sobrescribe `/usr/lib/udev/rules.d/`) | Políticas de udev |
| `/etc/systemd/network/*.link` | Nombrado de interfaces y ajustes a nivel de enlace |
| `/lib/firmware/`, `/lib/modules/$(uname -r)/` | Blobs de firmware de dispositivos; módulos del kernel |

---

## 13. Referencias

**Objetivos oficiales de la certificación**
- LPI — Exam 101-500 Objectives (v5.0): https://www.lpi.org/our-certifications/exam-101-objectives/
- LPI — LPIC-1 Certification overview: https://www.lpi.org/our-certifications/lpic-1-overview/

**Kernel de Linux (documentación oficial)**
- The `sysfs` Filesystem: https://docs.kernel.org/filesystems/sysfs.html
- Rules on how to access information in sysfs: https://docs.kernel.org/admin-guide/sysfs-rules.html
- The `/proc` Filesystem: https://docs.kernel.org/filesystems/proc.html
- The kernel's command-line parameters: https://docs.kernel.org/admin-guide/kernel-parameters.html
- Linux Device Drivers / Device Model: https://docs.kernel.org/driver-api/driver-model/index.html
- PCI Bus Subsystem: https://docs.kernel.org/PCI/index.html
- PCI Express I/O Virtualization (SR-IOV) HOWTO: https://docs.kernel.org/PCI/pci-iov-howto.html
- VFIO — "Virtual Function I/O": https://docs.kernel.org/driver-api/vfio.html
- USB Device Drivers / USB core API: https://docs.kernel.org/driver-api/usb/index.html
- Firmware loading (`request_firmware` API): https://docs.kernel.org/driver-api/firmware/index.html
- HugeTLB Pages: https://docs.kernel.org/admin-guide/mm/hugetlbpage.html
- SMP IRQ affinity: https://docs.kernel.org/core-api/irq/irq-affinity.html
- Linux allocated devices (major/minor registry): https://docs.kernel.org/admin-guide/devices.html
- Kernel ABI documentation index: https://docs.kernel.org/admin-guide/abi.html

**systemd / udev / D-Bus (freedesktop.org)**
- `udev` — Dynamic device management: https://www.freedesktop.org/software/systemd/man/latest/udev.html
- `udevadm(8)`: https://www.freedesktop.org/software/systemd/man/latest/udevadm.html
- `systemd-udevd.service(8)`: https://www.freedesktop.org/software/systemd/man/latest/systemd-udevd.service.html
- `systemd.link(5)`: https://www.freedesktop.org/software/systemd/man/latest/systemd.link.html
- `modules-load.d(5)`: https://www.freedesktop.org/software/systemd/man/latest/modules-load.d.html
- Predictable Network Interface Names: https://systemd.io/PREDICTABLE_INTERFACE_NAMES/
- D-Bus Specification: https://dbus.freedesktop.org/doc/dbus-specification.html
- UDisks2 Reference Manual: https://storaged.org/doc/udisks2-api/latest/
- UPower Reference Manual: https://upower.freedesktop.org/docs/

**Páginas de manual (man7.org)**
- `modprobe(8)`: https://man7.org/linux/man-pages/man8/modprobe.8.html
- `modprobe.d(5)`: https://man7.org/linux/man-pages/man5/modprobe.d.5.html
- `modinfo(8)`: https://man7.org/linux/man-pages/man8/modinfo.8.html
- `depmod(8)`: https://man7.org/linux/man-pages/man8/depmod.8.html
- `lsmod(8)`: https://man7.org/linux/man-pages/man8/lsmod.8.html
- `lspci(8)`: https://man7.org/linux/man-pages/man8/lspci.8.html
- `lsusb(8)`: https://man7.org/linux/man-pages/man8/lsusb.8.html
- `lsblk(8)`: https://man7.org/linux/man-pages/man8/lsblk.8.html
- `dmidecode(8)`: https://man7.org/linux/man-pages/man8/dmidecode.8.html
- `udev(7)`: https://man7.org/linux/man-pages/man7/udev.7.html

**Estándares e identificadores de hardware**
- DMTF — System Management BIOS (SMBIOS) Reference Specification: https://www.dmtf.org/standards/smbios
- UEFI Forum — UEFI and ACPI Specifications: https://uefi.org/specifications
- PCI ID Repository: https://pci-ids.ucw.cz/
- Linux USB ID Repository: http://www.linux-usb.org/usb-ids.html
- devicetree.org — Devicetree Specification: https://www.devicetree.org/specifications/
- Filesystem Hierarchy Standard 3.0 (`/dev`, `/proc`, `/sys`): https://refspecs.linuxfoundation.org/FHS_3.0/fhs/index.html

**Exposición de hardware en Kubernetes**
- Device Plugins: https://kubernetes.io/docs/concepts/extend-kubernetes/compute-storage-net/device-plugins/
- Control Topology Management Policies on a node: https://kubernetes.io/docs/tasks/administer-cluster/topology-manager/
- CPU Management Policies: https://kubernetes.io/docs/tasks/administer-cluster/cpu-management-policies/
- Memory Manager: https://kubernetes.io/docs/tasks/administer-cluster/memory-manager/
- Managing HugePages: https://kubernetes.io/docs/tasks/manage-hugepages/scheduling-hugepages/
- Node Feature Discovery (SIG): https://kubernetes-sigs.github.io/node-feature-discovery/stable/get-started/
- SR-IOV Network Device Plugin: https://github.com/k8snetworkplumbingwg/sriov-network-device-plugin

**Herramientas de aprovisionamiento**
- `dracut(8)`: https://man7.org/linux/man-pages/man8/dracut.8.html
- cloud-init — Module reference: https://cloudinit.readthedocs.io/en/latest/reference/modules.html
- Ansible — `community.general.modprobe` module: https://docs.ansible.com/ansible/latest/collections/community/general/modprobe_module.html