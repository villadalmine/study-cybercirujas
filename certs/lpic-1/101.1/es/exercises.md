# 101.1 — Determinar y configurar los parámetros del hardware
## Ejercicios guiados (LPIC-1, examen 101-500, temario v5.0 — peso 3.13)

**Fuente del objetivo:** <https://www.lpi.org/our-certifications/exam-101-objectives/>

---

### Entorno de laboratorio y notas de seguridad

Estos ejercicios están escritos para una **máquina Linux descartable** — una VM o una laptop de repuesto. Varios pasos escriben en `sysfs` y van a *deshabilitar un dispositivo deliberadamente*. No los ejecutes en una estación de trabajo de la que dependas, y nunca ejecutes los pasos que deshabilitan periféricos sobre una sesión SSH que atraviese la NIC que estás por desvincular.

Instalá primero las herramientas:

```bash
# Debian / Ubuntu
sudo apt install pciutils usbutils util-linux hdparm smartmontools lsscsi \
                 nvme-cli dmidecode lshw kmod

# RHEL / Fedora / openSUSE
sudo dnf install pciutils usbutils util-linux hdparm smartmontools lsscsi \
                 nvme-cli dmidecode lshw kmod
```

Vas a necesitar: un dispositivo USB que puedas desconectar físicamente (un pendrive o un mouse), y `root` mediante `sudo`.

**Todas las salidas que se muestran abajo son ejemplos.** El hardware difiere; lo que evalúa el examen es la *forma* de la salida y el archivo del que la leés, no los IDs específicos.

---

## Ejercicio 1 — Enumerar el bus PCI y mapear dispositivos a drivers

El bus PCI (y PCI Express) es donde viven los periféricos integrados de una máquina: el controlador SATA, los controladores host USB, la NIC, la GPU, el códec de audio. `lspci` es un formateador sobre `/sys/bus/pci/`.

**Paso 1.** Listá todas las funciones PCI de la máquina:

```bash
lspci
```

```
00:00.0 Host bridge: Intel Corporation Xeon E3-1200 v6/7th Gen Core Processor Host Bridge/DRAM Registers (rev 02)
00:02.0 VGA compatible controller: Intel Corporation HD Graphics 620 (rev 02)
00:14.0 USB controller: Intel Corporation Sunrise Point-LP USB 3.0 xHCI Controller (rev 21)
00:17.0 SATA controller: Intel Corporation Sunrise Point-LP SATA Controller [AHCI mode] (rev 21)
00:1f.3 Audio device: Intel Corporation Sunrise Point-LP HD Audio (rev 21)
00:1f.6 Ethernet controller: Intel Corporation Ethernet Connection (2) I219-V (rev 21)
02:00.0 Non-Volatile memory controller: Samsung Electronics Co Ltd NVMe SSD Controller SM981/PM981/PM983
```

**Paso 2.** La columna de la izquierda es la dirección PCI. Pedí la forma completa, que incluye el dominio:

```bash
lspci -D | head -3
```

```
0000:00:00.0 Host bridge: Intel Corporation ...
0000:00:02.0 VGA compatible controller: Intel Corporation ...
0000:00:14.0 USB controller: Intel Corporation ...
```

El formato es `domain:bus:device.function` — `0000:00:14.0` es dominio 0, bus 0, dispositivo `0x14`, función 0.

**Paso 3.** Agregá los IDs numéricos de fabricante y dispositivo, más el driver vinculado a cada función:

```bash
lspci -nnk -s 00:1f.6
```

```
00:1f.6 Ethernet controller [0200]: Intel Corporation Ethernet Connection (2) I219-V [8086:15b8] (rev 21)
	Subsystem: Dell Ethernet Connection (2) I219-V [1028:07a0]
	Kernel driver in use: e1000e
	Kernel modules: e1000e
```

`[0200]` es el código de *clase* PCI (02 = controlador de red, 00 = ethernet). `[8086:15b8]` es `vendor:device`. `8086` es Intel — los números son la verdad sobre el bus; las cadenas legibles por humanos vienen de una base de datos local.

**Paso 4.** Encontrá esa base de datos y notá que puede quedar desactualizada:

```bash
ls -l /usr/share/hwdata/pci.ids 2>/dev/null || ls -l /usr/share/misc/pci.ids
# sudo update-pciids      # downloads a fresh copy from pci-ids.ucw.cz
```

**Paso 5.** Mostrá la topología del bus como un árbol, y después la vista detallada de una sola función:

```bash
lspci -t
sudo lspci -vv -s 00:1f.6 | head -25
```

```
-[0000:00]-+-00.0
           +-02.0
           +-14.0
           +-17.0
           +-1f.3
           +-1f.6
           \-1c.0-[02]----00.0
```

```
00:1f.6 Ethernet controller: Intel Corporation Ethernet Connection (2) I219-V (rev 21)
	Subsystem: Dell Ethernet Connection (2) I219-V
	Control: I/O+ Mem+ BusMaster+ SpecCycle- MemWINV- VGASnoop- ParErr- Stepping- SERR- FastB2B- DisINTx+
	Status: Cap+ 66MHz- UDF- FastB2B- ParErr- DEVSEL=fast >TAbort- <TAbort- <MAbort- >SERR- <PERR- INTx-
	Latency: 0
	Interrupt: pin A routed to IRQ 130
	Region 0: Memory at df200000 (32-bit, non-prefetchable) [size=128K]
	Capabilities: [c8] Power Management version 3
	Capabilities: [d0] MSI: Enable+ Count=1/1 Maskable- 64bit+
	Kernel driver in use: e1000e
```

Ejecutá el mismo comando **sin** `sudo` y compará — vas a ver `Capabilities: <access denied>`. Leer el espacio de configuración PCI más allá de los primeros 64 bytes requiere privilegios.

**Paso 6.** Todo lo que imprimió `lspci` vino de `sysfs`. Leelo en crudo:

```bash
cd /sys/bus/pci/devices/0000:00:1f.6
cat vendor device class irq
ls -l driver
cat resource | head -3
```

```
0x8086
0x15b8
0x020000
130
lrwxrwxrwx 1 root root 0 Aug 25 10:12 driver -> ../../../../bus/pci/drivers/e1000e
0x00000000df200000 0x00000000df21ffff 0x0000000000040200
0x0000000000000000 0x0000000000000000 0x0000000000000000
0x0000000000000000 0x0000000000000000 0x0000000000000000
```

Cada línea de `resource` es `start end flags` para un BAR (Base Address Register); las líneas todas en cero son BARs sin usar.

> ### Comprobá lo que entendiste — Ejercicio 1
>
> **Q1.** En `0000:00:1f.6`, ¿qué significa cada uno de los cuatro campos, y por qué un único chip físico a veces ocupa `1f.3` *y* `1f.6`?
>
> **Q2.** `lspci -nn` imprime `[8086:15b8]`. ¿Qué número identifica al fabricante, y de dónde salió la cadena "Intel Corporation"?
>
> **Q3.** Ejecutás `lspci -vv` como usuario normal y ves `Capabilities: <access denied>`. ¿Qué se está denegando exactamente, y cuál es la solución?
>
> **Q4.** Un dispositivo aparece en `lspci` pero la máquina no puede usarlo. ¿Qué única línea de la salida de `lspci -k` te dice por qué, y cómo se vería esa línea en el caso de falla?
>
> **Q5.** Sin ejecutar `lspci`, ¿qué archivo bajo `/sys/bus/pci/devices/<addr>/` te da la línea de interrupción asignada al dispositivo?

---

## Ejercicio 2 — La pila USB: topología, velocidades y manipulación de dispositivos

**Paso 1.** Listá los dispositivos USB conectados:

```bash
lsusb
```

```
Bus 002 Device 002: ID 0781:5567 SanDisk Corp. Cruzer Blade
Bus 002 Device 001: ID 1d6b:0003 Linux Foundation 3.0 root hub
Bus 001 Device 003: ID 046d:c52b Logitech, Inc. Unifying Receiver
Bus 001 Device 002: ID 8087:0a2b Intel Corp. Bluetooth wireless interface
Bus 001 Device 001: ID 1d6b:0002 Linux Foundation 2.0 root hub
```

Fijate en las entradas `1d6b:000x`: esos son **root hubs virtuales** exportados por el kernel, uno por cada bus de controlador host, no hardware físico. `1d6b:0002` = bus USB 2.0, `1d6b:0003` = bus USB 3.x.

**Paso 2.** Mostrá la topología física, el driver vinculado a cada interfaz, y la velocidad negociada:

```bash
lsusb -t
```

```
/:  Bus 002.Port 001: Dev 001, Class=root_hub, Driver=xhci_hcd/4p, 5000M
    |__ Port 002: Dev 002, If 0, Class=Mass Storage, Driver=usb-storage, 5000M
/:  Bus 001.Port 001: Dev 001, Class=root_hub, Driver=xhci_hcd/12p, 480M
    |__ Port 003: Dev 002, If 0, Class=Wireless, Driver=btusb, 12M
    |__ Port 003: Dev 002, If 1, Class=Wireless, Driver=btusb, 12M
    |__ Port 005: Dev 003, If 0, Class=Human Interface Device, Driver=usbhid, 12M
    |__ Port 005: Dev 003, If 1, Class=Human Interface Device, Driver=usbhid, 12M
```

El número final es la tasa de señalización: `1.5M` low-speed, `12M` full-speed, `480M` high-speed, `5000M` SuperSpeed, `10000M` SuperSpeed+.

**Paso 3.** Volcá los descriptores de un dispositivo. Restringí el volcado — un `lsusb -v` completo son miles de líneas:

```bash
sudo lsusb -v -d 0781:5567 | head -30
```

```
Bus 002 Device 002: ID 0781:5567 SanDisk Corp. Cruzer Blade
Device Descriptor:
  bLength                18
  bDescriptorType         1
  bcdUSB               3.00
  bDeviceClass            0
  bMaxPacketSize0         9
  idVendor           0x0781 SanDisk Corp.
  idProduct          0x5567 Cruzer Blade
  iSerial                 3 4C530001120830115202
  bNumConfigurations      1
  Configuration Descriptor:
    bmAttributes         0x80
      (Bus Powered)
    MaxPower              224mA
```

**Paso 4.** Encontrá el mismo dispositivo en `sysfs` y leé los atributos directamente:

```bash
grep -l 5567 /sys/bus/usb/devices/*/idProduct
```

```
/sys/bus/usb/devices/2-2/idProduct
```

```bash
cd /sys/bus/usb/devices/2-2
cat idVendor idProduct manufacturer product serial speed bMaxPower
```

```
0781
5567
SanDisk
Cruzer Blade
4C530001120830115202
5000
224mA
```

El nombre del directorio `2-2` es `bus-port`. Un dispositivo detrás de un hub externo obtiene una ruta con puntos: `1-1.3` significa bus 1, puerto raíz 1, puerto de hub 3.

**Paso 5.** Observá el hot-plug en tiempo real. En una terminal:

```bash
sudo udevadm monitor --kernel --udev
```

En otra, desconectá y volvé a conectar el dispositivo USB. Vas a ver líneas `KERNEL[...]` y `UDEV[...]` emparejadas para el mismo evento, separadas por varios cientos de microsegundos.

**Paso 6.** Deshabilitá un dispositivo USB *por software*, sin desconectarlo:

```bash
echo 0 | sudo tee /sys/bus/usb/devices/2-2/authorized
lsusb -t          # the device is gone from the tree
echo 1 | sudo tee /sys/bus/usb/devices/2-2/authorized
```

El mismo interruptor existe por controlador host, como valor por defecto para los dispositivos recién conectados:

```bash
cat /sys/bus/usb/devices/usb2/authorized_default
```

**Paso 7.** Inspeccioná la política de gestión de energía que causa el "mi dispositivo USB desaparece cuando está inactivo":

```bash
cat /sys/bus/usb/devices/2-2/power/control            # auto | on
cat /sys/bus/usb/devices/2-2/power/autosuspend_delay_ms
echo on | sudo tee /sys/bus/usb/devices/2-2/power/control
```

> ### Comprobá lo que entendiste — Ejercicio 2
>
> **Q6.** `lsusb` lista `1d6b:0002 Linux Foundation 2.0 root hub`. ¿Hay un chip en la placa madre con ese ID? Explicá.
>
> **Q7.** Un pendrive USB 3.0 muestra `480M` en `lsusb -t`. Dá dos causas físicas plausibles.
>
> **Q8.** En `lsusb -t`, un dispositivo muestra dos líneas con `If 0` e `If 1` y el mismo número `Dev`. ¿Qué significa eso, y cuál es la consecuencia para la vinculación de drivers?
>
> **Q9.** Traducí la ruta de sysfs `/sys/bus/usb/devices/1-4.2.1` a lenguaje llano.
>
> **Q10.** Escribís `0` en el archivo `authorized` de un dispositivo. Desde el punto de vista del bus eléctrico y del kernel, ¿qué cambió, y qué *no* cambió?

---

## Ejercicio 3 — Módulos del kernel: la vinculación entre hardware y driver

**Paso 1.** Listá los módulos cargados e identificá el origen de los datos:

```bash
lsmod | head -8
head -3 /proc/modules
```

```
Module                  Size  Used by
nvme_core             172032  5 nvme
usb_storage            81920  1 uas
e1000e                311296  0
snd_hda_intel          61440  3
xhci_pci               24576  0
xhci_hcd              352256  1 xhci_pci
```

```
nvme_core 172032 5 nvme, Live 0xffffffffc0a41000
usb_storage 81920 1 uas, Live 0xffffffffc08d2000
e1000e 311296 0 - Live 0xffffffffc0b12000
```

`lsmod` es un formateador sobre `/proc/modules`. La columna 3 es el **contador de uso**, la columna 4 los módulos que dependen de él. Un módulo con contador de uso distinto de cero no se puede quitar.

**Paso 2.** Interrogá un módulo sin cargarlo:

```bash
modinfo e1000e | head -12
```

```
filename:       /lib/modules/6.8.0-45-generic/kernel/drivers/net/ethernet/intel/e1000e/e1000e.ko.zst
version:        3.8.4-NAPI
license:        GPL v2
description:    Intel(R) PRO/1000 Network Driver
alias:          pci:v00008086d000015B8sv*sd*bc*sc*i*
depends:
retpoline:      Y
parmtype:       debug:Debug level (0=none,...,16=all) (int)
parmtype:       InterruptThrottleRate:Interrupt Throttle Rate (array of int)
```

La línea `alias` es el mecanismo: `v00008086d000015B8` es exactamente el `8086:15b8` que viste en `lspci -nn`. Cuando el núcleo PCI descubre un dispositivo emite un uevent `MODALIAS` que contiene esa cadena; `udev` llama a `modprobe` con ella; `modprobe` la compara contra `/lib/modules/$(uname -r)/modules.alias`.

**Paso 3.** Mirá ese alias donde el kernel lo publica:

```bash
cat /sys/bus/pci/devices/0000:00:1f.6/modalias
```

```
pci:v00008086d000015B8sv00001028sd000007A0bc02sc00i00
```

**Paso 4.** Listá los parámetros ajustables de un módulo cargado y sus valores actuales:

```bash
modinfo -p e1000e
ls /sys/module/e1000e/parameters/
cat /sys/module/usbcore/parameters/autosuspend
```

**Paso 5.** Descargá y recargá un módulo de forma segura. Elegí algo inofensivo — el driver del parlante del PC:

```bash
sudo modprobe pcspkr
lsmod | grep pcspkr
sudo modprobe -r pcspkr
```

`modprobe -r` quita el módulo *y* cualquier dependencia que quede sin usar; `rmmod` quita exactamente un módulo y se niega si el contador de uso es distinto de cero.

**Paso 6.** Creá una configuración persistente. Dos directivas importan para este objetivo:

```bash
sudo tee /etc/modprobe.d/99-lab.conf <<'EOF'
# Prevent udev from auto-loading this driver on device discovery
blacklist pcspkr

# Pass parameters at load time
options usbcore autosuspend=-1
EOF
```

**Paso 7.** Comprobá el límite de `blacklist`:

```bash
sudo modprobe pcspkr        # this STILL loads it
lsmod | grep pcspkr
sudo modprobe -r pcspkr
```

`blacklist` solo suprime la carga automática *dirigida por alias*. Para hacer que un módulo sea genuinamente no cargable, sobrescribí el comando de instalación:

```bash
echo 'install pcspkr /bin/false' | sudo tee -a /etc/modprobe.d/99-lab.conf
sudo modprobe pcspkr ; echo "exit=$?"
```

```
exit=1
```

**Paso 8.** Si un módulo se carga desde el initramfs (almacenamiento, RAID, GPU), el archivo de configuración de arriba no alcanza — el initramfs lleva su propia copia de `/etc/modprobe.d`:

```bash
# Debian/Ubuntu
sudo update-initramfs -u
# RHEL/Fedora/SUSE
sudo dracut -f
```

**Paso 9.** Limpieza:

```bash
sudo rm /etc/modprobe.d/99-lab.conf
```

> ### Comprobá lo que entendiste — Ejercicio 3
>
> **Q11.** Trazá la cadena completa desde "se conecta una placa PCI" hasta "su driver está en `lsmod`". Nombrá cada componente.
>
> **Q12.** `rmmod xhci_hcd` falla. `lsmod` muestra `xhci_hcd 352256 1 xhci_pci`. Explicá la falla y dá el comando que sí funcionaría.
>
> **Q13.** Agregás `blacklist nouveau` y reiniciás; `lsmod` sigue mostrando `nouveau`. Dá dos explicaciones independientes y la solución correspondiente a cada una.
>
> **Q14.** ¿Cuál es la diferencia entre `options <mod> <param>=<value>` en `/etc/modprobe.d/` y escribir en `/sys/module/<mod>/parameters/<param>`?
>
> **Q15.** ¿Qué archivo consulta `modprobe` para resolver una cadena `MODALIAS` en un nombre de módulo, y qué comando lo regenera?

---

## Ejercicio 4 — Recursos de hardware: IRQ, puertos de E/S, DMA y rangos de memoria

**Paso 1.** Leé la tabla de interrupciones:

```bash
cat /proc/interrupts
```

```
           CPU0       CPU1       CPU2       CPU3
  0:         12          0          0          0   IO-APIC    2-edge      timer
  1:          0          9          0          0   IO-APIC    1-edge      i8042
  8:          0          0          1          0   IO-APIC    8-edge      rtc0
  9:          0          0          0          0   IO-APIC    9-fasteoi   acpi
 12:          0          0        152          0   IO-APIC   12-edge      i8042
 16:          0          0          0         31   IO-APIC   16-fasteoi   i801_smbus
124:      12034          0          0          0   PCI-MSI 327680-edge      xhci_hcd
125:          0      45120          0          0   PCI-MSI 512000-edge      nvme0q0
130:          3          0          0          0   PCI-MSI 3145728-edge     enp0s31f6
NMI:         12         14         11         10   Non-maskable interrupts
LOC:    1204567    1198234    1187654    1176543   Local timer interrupts
ERR:          0
```

La columna 1 es el número de IRQ, luego un contador **por CPU**, luego el controlador de interrupciones y el tipo de disparo, y finalmente el dispositivo o driver propietario.

**Paso 2.** Comprobá que los contadores están vivos. Movés el mouse, o generás E/S de disco, y observás:

```bash
watch -n1 "grep -E 'i8042|nvme0q1|xhci' /proc/interrupts"
```

**Paso 3.** Compará una IRQ heredada con una MSI. Las interrupciones PCI heredadas (`IO-APIC`, `fasteoi`) son *compartidas* — varios dispositivos en la misma línea. Las interrupciones MSI/MSI-X están basadas en mensajes, se entregan por el propio bus PCI, y no se comparten:

```bash
awk '$NF ~ /fasteoi/ {print}' /proc/interrupts
```

Cualquier línea con dos o más nombres de dispositivo al final es una IRQ heredada compartida.

**Paso 4.** Leé el mapa de puertos de E/S — el espacio de direcciones heredado de x86, separado de la memoria:

```bash
sudo cat /proc/ioports | head -20
```

```
0000-0cf7 : PCI Bus 0000:00
  0000-001f : dma1
  0020-0021 : pic1
  0040-0043 : timer0
  0060-0060 : keyboard
  0064-0064 : keyboard
  0070-0077 : rtc0
  0080-008f : dma page reg
  00a0-00a1 : pic2
  00c0-00df : dma2
  02f8-02ff : serial
  03f8-03ff : serial
```

`03f8-03ff` es el clásico rango de `COM1` / `/dev/ttyS0`; `0060`/`0064` es el controlador PS/2 detrás del driver `i8042` que viste en IRQ 1 e IRQ 12.

**Paso 5.** Leé el mapa de E/S mapeada en memoria, y observá la diferencia de privilegios:

```bash
cat /proc/iomem | head -5          # as a normal user
sudo cat /proc/iomem | head -12    # as root
```

```
00000000-00000000 : Reserved
00000000-00000000 : System RAM
```

```
00000000-00000fff : Reserved
00001000-0009fbff : System RAM
000a0000-000bffff : PCI Bus 0000:00
00100000-bffdffff : System RAM
df200000-df21ffff : 0000:00:1f.6
  df200000-df21ffff : e1000e
fed00000-fed003ff : HPET 0
```

Las direcciones se ponen en cero para los lectores sin privilegios a propósito: son un oráculo del KASLR del kernel.

**Paso 6.** Leé la tabla de canales DMA de ISA:

```bash
cat /proc/dma
```

```
 4: cascade
```

En cualquier máquina moderna esto está casi vacío. El canal 4 es la cascada que enlaza los dos controladores 8237. Los dispositivos PCI no usan estos canales — realizan **DMA bus-master**, que es la razón por la que `lspci -vv` muestra `BusMaster+`.

**Paso 7.** Correlacioná: elegí tu NIC y confirmá que la misma IRQ aparece en tres lugares.

```bash
DEV=0000:00:1f.6
cat /sys/bus/pci/devices/$DEV/irq
grep -E "$(cat /sys/bus/pci/devices/$DEV/irq):" /proc/interrupts
sudo lspci -vv -s ${DEV#0000:} | grep -E 'Interrupt|Region'
```

> ### Comprobá lo que entendiste — Ejercicio 4
>
> **Q16.** ¿Por qué `/proc/interrupts` tiene una columna por CPU, y qué te dice un contador de interrupciones en 0 en tres de cuatro CPUs?
>
> **Q17.** `/proc/dma` muestra solo `4: cascade` en una máquina con un SSD NVMe y una NIC gigabit. ¿Esos dispositivos hacen DMA? Explicá.
>
> **Q18.** ¿Cuál es la diferencia entre `/proc/ioports` y `/proc/iomem`, y por qué las direcciones en `/proc/iomem` se ponen en cero para los usuarios que no son root?
>
> **Q19.** Dos dispositivos comparten la IRQ 16. ¿Es una mala configuración? ¿De qué depende la respuesta?
>
> **Q20.** Un driver carga, el dispositivo aparece en `lspci -k` con `Kernel driver in use`, pero el dispositivo nunca responde. `/proc/interrupts` muestra su línea de IRQ clavada en 0. ¿A qué clase de problema apunta eso?

---

## Ejercicio 5 — `sysfs` y `udev`: del objeto del kernel al nodo en `/dev`

**Paso 1.** Confirmá que los tres sistemas de archivos involucrados están montados:

```bash
findmnt -t sysfs,devtmpfs,proc -o TARGET,SOURCE,FSTYPE
```

```
TARGET  SOURCE   FSTYPE
/proc   proc     proc
/sys    sysfs    sysfs
/dev    devtmpfs devtmpfs
```

**Paso 2.** Recorré el mismo dispositivo desde tres direcciones distintas. `sysfs` es un único árbol de objetos expuesto a través de varias vistas:

```bash
ls -l /sys/class/net/                       # by function
ls -l /sys/bus/pci/devices/                 # by bus
ls -ld /sys/devices/pci0000:00/0000:00:1f.6 # by physical topology
```

```
lrwxrwxrwx 1 root root 0 Aug 25 10:12 enp0s31f6 -> ../../devices/pci0000:00/0000:00:1f.6/net/enp0s31f6
```

`/sys/class/` y `/sys/bus/` contienen **symlinks**; `/sys/devices/` alberga la jerarquía real.

**Paso 3.** Volcá todas las propiedades de udev de un dispositivo:

```bash
udevadm info --query=property --name=/dev/sda
```

```
DEVNAME=/dev/sda
DEVPATH=/devices/pci0000:00/0000:00:14.0/usb2/2-2/2-2:1.0/host4/target4:0:0/4:0:0:0/block/sda
DEVTYPE=disk
ID_BUS=usb
ID_MODEL=Cruzer_Blade
ID_SERIAL=SanDisk_Cruzer_Blade_4C530001120830115202-0:0
ID_USB_DRIVER=usb-storage
ID_VENDOR=SanDisk
MAJOR=8
MINOR=0
SUBSYSTEM=block
```

**Paso 4.** Volcá el recorrido de atributos — esto es lo que usás para *escribir* una regla:

```bash
udevadm info --attribute-walk --name=/dev/sda | head -40
```

```
  looking at device '/devices/.../block/sda':
    KERNEL=="sda"
    SUBSYSTEM=="block"
    DRIVER==""
    ATTR{removable}=="1"
    ATTR{size}=="60628992"

  looking at parent device '/devices/.../4:0:0:0':
    KERNELS=="4:0:0:0"
    SUBSYSTEMS=="scsi"
    DRIVERS=="sd"

  looking at parent device '/devices/.../usb2/2-2':
    KERNELS=="2-2"
    SUBSYSTEMS=="usb"
    DRIVERS=="usb"
    ATTRS{idVendor}=="0781"
    ATTRS{idProduct}=="5567"
    ATTRS{serial}=="4C530001120830115202"
```

Notá la distinción singular/plural: `KERNEL`/`ATTR` coinciden con el dispositivo **mismo**, `KERNELS`/`ATTRS`/`DRIVERS` coinciden con **cualquier padre** de la cadena. Una regla puede usar `ATTR{}` de exactamente un dispositivo, pero puede combinar `ATTRS{}` de varios padres.

**Paso 5.** Escribí una regla que le dé a tu pendrive USB un symlink estable. Sustituí por tus propios IDs:

```bash
sudo tee /etc/udev/rules.d/99-lab-stick.rules <<'EOF'
SUBSYSTEM=="block", KERNEL=="sd?1", ATTRS{idVendor}=="0781", \
  ATTRS{idProduct}=="5567", SYMLINK+="labstick", MODE="0660", GROUP="disk"
EOF
```

Operadores: `==` coincidencia, `!=` coincidencia negada, `=` asignación, `+=` agregar a una lista, `:=` asignar y prohibir cambios posteriores.

**Paso 6.** Recargá y volvé a disparar sin reconectar:

```bash
sudo udevadm control --reload
sudo udevadm trigger --subsystem-match=block --action=add
ls -l /dev/labstick
```

```
lrwxrwxrwx 1 root root 4 Aug 25 10:31 /dev/labstick -> sda1
```

**Paso 7.** Depurá una regla que no se dispara — `udevadm test` reproduce el conjunto de reglas contra un dispositivo e imprime cada decisión:

```bash
sudo udevadm test /sys/class/block/sda1 2>&1 | grep -i -E 'lab-stick|SYMLINK'
```

**Paso 8.** Entendé la precedencia y limpiá:

```bash
ls /usr/lib/udev/rules.d/ | head -5   # distribution-supplied
ls /etc/udev/rules.d/                 # administrator-supplied, WINS on same filename
sudo rm /etc/udev/rules.d/99-lab-stick.rules
sudo udevadm control --reload
```

Las reglas se procesan en **orden lexicográfico del nombre de archivo** sobre ambos directorios fusionados; un archivo con nombre idéntico en `/etc/udev/rules.d/` enmascara completamente al de `/usr/lib/udev/rules.d/`.

> ### Comprobá lo que entendiste — Ejercicio 5
>
> **Q21.** ¿Qué componente crea el nodo de dispositivo `/dev/sda` — el kernel o `udev`? Entonces, ¿qué aporta `udev`?
>
> **Q22.** Explicá con precisión cuándo usar `ATTR{}` y cuándo usar `ATTRS{}`.
>
> **Q23.** Tu archivo de reglas se llama `10-mystick.rules` y una regla de la distribución en `60-persistent-storage.rules` sobrescribe tu `MODE`. ¿Cuáles son dos formas de arreglarlo?
>
> **Q24.** ¿Por qué hace falta `udevadm trigger` después de `udevadm control --reload`, y qué hace realmente?
>
> **Q25.** `/sys/class/net/enp0s31f6` y `/sys/devices/pci0000:00/0000:00:1f.6/net/enp0s31f6` — ¿cuál es la relación entre estas dos rutas, y por qué `sysfs` presenta ambas?

---

## Ejercicio 6 — Diferenciar dispositivos de almacenamiento masivo

**Paso 1.** Obtené el panorama completo en un solo comando:

```bash
lsblk -o NAME,MAJ:MIN,RM,SIZE,RO,TYPE,ROTA,TRAN,MODEL
```

```
NAME        MAJ:MIN RM   SIZE RO TYPE ROTA TRAN MODEL
nvme0n1     259:0    0 476.9G  0 disk    0 nvme Samsung SSD 970 EVO Plus 500GB
├─nvme0n1p1 259:1    0   512M  0 part    0
└─nvme0n1p2 259:2    0 476.4G  0 part    0
sda           8:0    0 931.5G  0 disk    1 sata WDC WD10EZEX-08WN4A0
└─sda1        8:1    0 931.5G  0 part    1
sdb           8:16   1  28.9G  0 disk    1 usb  Cruzer Blade
└─sdb1        8:17   1  28.9G  0 part    1
sr0          11:0    1  1024M  0 rom     1 sata DVD+-RW GU90N
```

`TRAN` es el transporte — este es el campo que responde "¿qué tipo de dispositivo es?". `RM` es la bandera de extraíble. `MAJ:MIN` es el par de números de dispositivo: mayor 8 = disco SCSI, 11 = CD-ROM SCSI, 259 = block extended (NVMe y particiones de numeración alta), 179 = MMC.

**Paso 2.** Notá la trampa en la salida de arriba: `sdb` es un pendrive USB — de estado sólido — y sin embargo `ROTA` dice `1`.

```bash
cat /sys/block/sdb/queue/rotational
cat /sys/block/nvme0n1/queue/rotational
```

`rotational` es una *pista que reportan el kernel o el transporte*, no una medición. Los puentes USB rutinariamente no reportan la bandera de no rotacional.

**Paso 3.** Mirá por qué tantos dispositivos distintos se llaman `sd*`:

```bash
lsscsi
cat /proc/scsi/scsi
```

```
[0:0:0:0]    disk    ATA      WDC WD10EZEX-08W 1A01  /dev/sda
[1:0:0:0]    cd/dvd  HL-DT-ST DVD+-RW GU90N    A1C2  /dev/sr0
[4:0:0:0]    disk    SanDisk  Cruzer Blade     1.00  /dev/sdb
```

El subsistema SCSI de Linux es una *capa de conjunto de comandos*. SATA (vía `libata`), SAS, almacenamiento masivo USB (vía `usb-storage`/`uas`), FC e iSCSI hablan todos comandos SCSI, así que todos ellos obtienen nombres `sd` y direcciones `[host:channel:target:lun]`. Los nombres `hdX` de PATA/IDE genuino desaparecieron cuando los viejos drivers IDE fueron reemplazados por `libata`.

**Paso 4.** NVMe es la excepción — *no* pasa por SCSI:

```bash
sudo nvme list
ls /sys/class/nvme/
```

```
Node          SN            Model                      Namespace Usage            FW Rev
------------- ------------- -------------------------- --------- ---------------- --------
/dev/nvme0n1  S4EVNF0M12345 Samsung SSD 970 EVO Plus    1         512.11 GB        2B2QEXM7
```

La nomenclatura es `nvme<controller>n<namespace>p<partition>`: `/dev/nvme0n1p2` es controlador 0, namespace 1, partición 2. Un namespace no es una partición — es una división del flash a nivel de controlador, más cercana a un LUN.

**Paso 5.** Interrogá un dispositivo ATA real:

```bash
sudo hdparm -I /dev/sda | grep -E 'Model|Serial|Rotation|Nominal|LBA48|Transport'
```

```
	Model Number:       WDC WD10EZEX-08WN4A0
	Serial Number:      WD-WCC6Y1234567
	Transport:          Serial, ATA8-AST, SATA 1.0a, SATA II ...
	Nominal Media Rotation Rate: 7200
	LBA48  user addressable sectors:  1953525168
```

`Nominal Media Rotation Rate: 7200` es un disco giratorio; un SSD reporta `Solid State Device`.

**Paso 6.** Obtené salud e identidad independientes del fabricante vía SMART:

```bash
sudo smartctl -i /dev/sda
sudo smartctl -H /dev/nvme0n1
```

**Paso 7.** Agregá un dispositivo SCSI/SATA que fue conectado después del arranque, sin reiniciar:

```bash
ls /sys/class/scsi_host/
for h in /sys/class/scsi_host/host*; do echo "- - -" | sudo tee $h/scan; done
lsblk
```

Los tres guiones son comodines para canal, target y LUN.

**Paso 8.** Verificá la geometría de sectores — esto es lo que significan la alineación y `4Kn` frente a `512e`:

```bash
cat /sys/block/sda/queue/hw_sector_size
cat /sys/block/sda/queue/physical_block_size
cat /sys/block/sda/queue/logical_block_size
```

> ### Comprobá lo que entendiste — Ejercicio 6
>
> **Q26.** Un disco SATA, un disco SAS y un pendrive USB aparecen todos como `/dev/sdX`. ¿Por qué? ¿Qué subsistema es responsable?
>
> **Q27.** `/sys/block/sdb/queue/rotational` reporta `1` para un pendrive USB. ¿Está equivocado el kernel? ¿Cuál es la consecuencia práctica para la planificación de E/S?
>
> **Q28.** Descomponé `/dev/nvme0n1p3`. ¿En qué se diferencia el significado de `n1` respecto de una partición?
>
> **Q29.** Conectás en caliente un disco SATA a un servidor en funcionamiento y no aparece en `lsblk`. Dá el comando que hace que el kernel lo busque, y explicá los `- - -`.
>
> **Q30.** ¿Qué dos comandos usarías para decidir, en hardware desconocido, si `/dev/sda` es un disco giratorio o un SSD — y en cuál confiás más?

---

## Ejercicio 7 — Habilitar y deshabilitar periféricos integrados

Hay cuatro capas en las que se puede apagar un periférico integrado. Recorrelas desde la más baja hasta la más alta.

**Paso 1 — Capa 1: firmware.** Leé lo que el firmware reporta sobre la placa:

```bash
sudo dmidecode -t bios -t baseboard | head -20
ls /sys/firmware/         # 'efi' present => UEFI boot; absent => legacy BIOS
```

```
BIOS Information
	Vendor: Dell Inc.
	Version: 1.27.0
	Release Date: 07/12/2023
Base Board Information
	Manufacturer: Dell Inc.
	Product Name: 0K1MDR
```

Deshabilitar un controlador en el Setup hace que el dispositivo desaparezca de `lspci` por completo — esta es la única capa que quita el hardware de la vista del sistema operativo. Nada en Linux puede volver a habilitarlo.

**Paso 2 — Capa 2: línea de comandos del kernel.** Inspeccioná qué se le dijo al kernel en ejecución:

```bash
cat /proc/cmdline
```

```
BOOT_IMAGE=/vmlinuz-6.8.0-45-generic root=UUID=... ro quiet splash
```

Para poner un driver en la lista negra durante el arranque, agregá `modprobe.blacklist=<mod>`; para deshabilitar toda una clase, opciones como `nomodeset` (sin kernel mode setting), `noapic`, `pci=noaer`, `usbcore.autosuspend=-1`. En sistemas con GRUB:

```bash
sudo sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="/&modprobe.blacklist=pcspkr /' /etc/default/grub
sudo update-grub    ||    sudo grub2-mkconfig -o /boot/grub2/grub.cfg
```

**Paso 3 — Capa 3: política de módulos.** Como en el Ejercicio 3 — `/etc/modprobe.d/*.conf` con `blacklist` más `install <mod> /bin/false`, reconstruyendo el initramfs cuando el módulo se carga temprano.

**Paso 4 — Capa 4: en tiempo de ejecución, vía sysfs.** Desvinculá un driver de un dispositivo sin descargar el módulo. **No hagas esto con el controlador de disco ni con la NIC por la que estás conectado.**

Elegí un objetivo seguro — el códec de audio:

```bash
DEV=0000:00:1f.3
basename $(readlink /sys/bus/pci/devices/$DEV/driver)
```

```
snd_hda_intel
```

```bash
echo $DEV | sudo tee /sys/bus/pci/drivers/snd_hda_intel/unbind
lspci -k -s ${DEV#0000:}          # 'Kernel driver in use' line is gone
echo $DEV | sudo tee /sys/bus/pci/drivers/snd_hda_intel/bind
```

**Paso 5.** Andá más lejos — quitá la función PCI del árbol de dispositivos del kernel, y después traela de vuelta:

```bash
echo 1 | sudo tee /sys/bus/pci/devices/$DEV/remove
lspci | grep 1f.3          # no output — the device is gone
echo 1 | sudo tee /sys/bus/pci/rescan
lspci -k | grep -A2 1f.3   # rediscovered and rebound
```

**Paso 6.** Deshabilitá un periférico por clase usando udev — por ejemplo, rechazar la activación de cualquier dispositivo USB de almacenamiento masivo:

```bash
sudo tee /etc/udev/rules.d/99-no-usb-storage.rules <<'EOF'
ACTION=="add", SUBSYSTEMS=="usb", ATTRS{bInterfaceClass}=="08", \
  RUN+="/bin/sh -c 'echo 0 > /sys%p/../authorized'"
EOF
```

Después borrala de nuevo — esto es una demostración, no una receta de endurecimiento:

```bash
sudo rm /etc/udev/rules.d/99-no-usb-storage.rules && sudo udevadm control --reload
```

**Paso 7.** Verificá el panorama completo con una única herramienta de inventario:

```bash
sudo lshw -short | head -25
```

```
H/W path            Device      Class       Description
=======================================================
                                system      Latitude 7480
/0                              bus         0K1MDR
/0/0                            memory      64KiB BIOS
/0/3a                           processor   Intel(R) Core(TM) i5-7300U CPU
/0/100/1f.3                     multimedia  Sunrise Point-LP HD Audio
/0/100/1f.6         enp0s31f6   network     Ethernet Connection (2) I219-V
```

> ### Comprobá lo que entendiste — Ejercicio 7
>
> **Q31.** Ordená las cuatro capas (firmware, línea de comandos del kernel, modprobe, sysfs) por persistencia tras el reinicio y por si el dispositivo sigue apareciendo en `lspci`.
>
> **Q32.** Desvinculás `e1000e` de la NIC por SSH a través de esa misma NIC. ¿Qué pasa, y cuál es la recuperación?
>
> **Q33.** ¿Cuál es la diferencia de efecto entre escribir en `.../driver/unbind` y escribir en `.../device/remove`?
>
> **Q34.** Un dispositivo fue deshabilitado en el Setup UEFI. ¿Qué comando de Linux revela esto, y qué comando de Linux lo vuelve a habilitar?
>
> **Q35.** ¿Por qué hay que reconstruir el initramfs después de poner en la lista negra un driver de almacenamiento, pero no después de poner en la lista negra `pcspkr`?

---

## Ejercicio 8 — D-Bus, y diagnosticar un dispositivo que no aparece

`sysfs` y `udev` miran hacia el kernel; **D-Bus** es el bus de IPC de espacio de usuario sobre el que servicios como `udisks2`, `NetworkManager` y `systemd-logind` publican eventos de hardware y aceptan solicitudes. Esta es la tercera pata de la tríada "sysfs, udev, dbus" del objetivo.

**Paso 1.** Confirmá que el bus del sistema está corriendo y listá sus nombres bien conocidos:

```bash
systemctl status dbus --no-pager | head -4
busctl list | head -12
```

```
NAME                             PID PROCESS         USER
org.freedesktop.NetworkManager   912 NetworkManager  root
org.freedesktop.UDisks2         1341 udisksd         root
org.freedesktop.login1           701 systemd-logind  root
org.freedesktop.systemd1           1 systemd         root
```

**Paso 2.** Introspeccioná un servicio orientado a hardware. `udisks2` es la abstracción de almacenamiento que usan los escritorios:

```bash
busctl tree org.freedesktop.UDisks2 | head -15
busctl introspect org.freedesktop.UDisks2 \
  /org/freedesktop/UDisks2/block_devices/sda1 \
  org.freedesktop.UDisks2.Block | head -12
```

```
NAME                       TYPE      SIGNATURE  RESULT/VALUE
.Device                    property  ay         5 47 100 101 118 ...
.IdLabel                   property  s          "DATA"
.IdType                    property  s          "ext4"
.IdUUID                    property  s          "9f3b-..."
.Size                      property  t          1000203091968
```

**Paso 3.** Usá el cliente de alto nivel y comparalo con el bus en crudo:

```bash
udisksctl status
udisksctl info -b /dev/sda1 | head -12
```

**Paso 4.** Observá el bus mientras conectás el dispositivo USB:

```bash
sudo busctl monitor org.freedesktop.UDisks2
```

Ahora rastreá el mismo evento físico a través de las tres capas ejecutando esto en tres terminales simultáneamente y reconectando el dispositivo:

```bash
sudo dmesg -w                             # kernel
sudo udevadm monitor --kernel --udev      # uevents
sudo busctl monitor org.freedesktop.UDisks2   # userspace services
```

**Paso 5.** Leé el búfer circular del kernel con marcas de tiempo humanas y un filtro de severidad:

```bash
sudo dmesg -T --level=err,warn | tail -20
sudo journalctl -k -b -p warning --no-pager | tail -20
```

```
[Mon Aug 25 10:44:02 2026] usb 2-2: new SuperSpeed USB device number 4 using xhci_hcd
[Mon Aug 25 10:44:02 2026] usb 2-2: New USB device found, idVendor=0781, idProduct=5567
[Mon Aug 25 10:44:02 2026] usb-storage 2-2:1.0: USB Mass Storage device detected
[Mon Aug 25 10:44:03 2026] scsi 4:0:0:0: Direct-Access  SanDisk Cruzer Blade
[Mon Aug 25 10:44:03 2026] sd 4:0:0:0: [sdb] 60628992 512-byte logical blocks
```

**Paso 6.** Aplicá la escalera de diagnóstico. Un dispositivo no funciona — recorré la pila *hacia abajo*, deteniéndote en la primera capa que falle:

| Capa | Pregunta | Comando |
|---|---|---|
| 1. Eléctrica / firmware | ¿El bus lo ve siquiera? | `lspci -nn`, `lsusb`, `dmesg` |
| 2. Disponibilidad del driver | ¿Existe un driver para ese ID? | `lspci -k`, `modinfo <mod>`, `modprobe <mod>` |
| 3. Vinculación del driver | ¿Está vinculado? | `lspci -k`, `ls /sys/bus/*/devices/*/driver` |
| 4. Recursos | ¿Obtuvo una IRQ y BARs? | `/proc/interrupts`, `/proc/iomem`, `lspci -vv` |
| 5. Nodo de dispositivo | ¿Está `/dev/...` presente con el modo correcto? | `udevadm info`, `ls -l /dev/...` |
| 6. Servicio | ¿Lo levantó el espacio de usuario? | `busctl`, `udisksctl`, `journalctl -u ...` |

**Paso 7.** Practicalo. Rompé la pila deliberadamente en la capa 3 y diagnosticala como si no supieras:

```bash
DEV=0000:00:1f.3
echo $DEV | sudo tee /sys/bus/pci/drivers/snd_hda_intel/unbind
# now: lspci -nn (present), lspci -k (no driver), lsmod (module still loaded)
echo $DEV | sudo tee /sys/bus/pci/drivers/snd_hda_intel/bind
```

> ### Comprobá lo que entendiste — Ejercicio 8
>
> **Q36.** Ubicá `sysfs`, `udev` y `D-Bus` en el camino desde una interrupción de hardware hasta una notificación de escritorio que dice "unidad USB montada". ¿Cuál corre en espacio de kernel?
>
> **Q37.** Un dispositivo está listado en `lspci -nn` pero `lspci -k` no muestra `Kernel driver in use` ni `Kernel modules`. ¿Qué te dice específicamente la *ausencia de la segunda línea*?
>
> **Q38.** ¿Por qué `dmesg -T` a veces es impreciso en una máquina que estuvo suspendida, y qué deberías usar en su lugar?
>
> **Q39.** `udevadm monitor` imprime una línea `KERNEL` pero ninguna línea `UDEV` correspondiente para un dispositivo. ¿Dónde está el problema?
>
> **Q40.** Nombrá el único comando de todo este tema que ejecutarías primero en una máquina desconocida para obtener un inventario de hardware en una sola pantalla, y enunciá su principal limitación.

---

<details>
<summary><b>Respuestas — clic para expandir</b></summary>

### Ejercicio 1 — PCI

**A1.** `0000` = *dominio* PCI (un espacio de direcciones / host bridge separado; casi siempre 0 en un escritorio, distinto de cero en servidores grandes y algunos SoC ARM). `00` = número de *bus*. `1f` = número de *dispositivo* (slot) en ese bus, en hexadecimal. `6` = *función*. Un único encapsulado físico puede implementar hasta ocho funciones lógicamente independientes que comparten un slot — el PCH de Intel implementa audio en `1f.3`, LPC en `1f.0`, SMBus en `1f.4` y la NIC en `1f.6`. Cada función obtiene su propio espacio de configuración, su propio driver y sus propios recursos.

**A2.** `8086` es el ID de fabricante (Intel); `15b8` es el ID de dispositivo asignado por ese fabricante. Las cadenas vienen de la base de datos local `pci.ids` (`/usr/share/hwdata/pci.ids` o `/usr/share/misc/pci.ids`), actualizada con `update-pciids`. Si el archivo está desactualizado, `lspci` imprime `Device 15b8` — el hardware está bien, la *base de datos* es la que está vieja.

**A3.** El espacio de configuración PCI más allá de los primeros 64 bytes — listas de capacidades, capacidades extendidas, estado del enlace — solo es legible por root, porque `lspci` debe acceder a `/sys/bus/pci/devices/*/config` (o `/proc/bus/pci`) con privilegios elevados. Solución: ejecutar `sudo lspci -vv`.

**A4.** `Kernel driver in use:`. En el caso de falla esa línea está **ausente**. Si `Kernel modules:` está presente pero falta `Kernel driver in use:`, existe un módulo adecuado pero no está cargado o no está vinculado. Si faltan *ambas* líneas, el kernel en ejecución no tiene ningún driver para ese ID.

**A5.** `/sys/bus/pci/devices/<domain:bus:dev.fn>/irq`.

### Ejercicio 2 — USB

**A6.** No. `1d6b` es el ID de fabricante de la Linux Foundation y el "root hub" es una construcción de software: el núcleo USB del kernel presenta los puertos de cada controlador host como un hub virtual para que la topología tenga una raíz única. Aparece uno por bus y por generación de protocolo — `1d6b:0002` para el bus USB 2.0, `1d6b:0003` para el bus USB 3.x del mismo controlador xHCI.

**A7.** (a) Está conectado a un puerto que solo es USB 2.0 — físicamente solo están cableados los cuatro pines de USB 2.0. (b) Hay en el camino un cable o hub sin los pares diferenciales extra de SuperSpeed (un cable alargador USB 2.0, o un hub 2.0). Una tercera causa: una conexión marginal que hace que el enlace SuperSpeed falle el entrenamiento y caiga a una velocidad menor.

**A8.** El dispositivo expone dos **interfaces** en su configuración — es un dispositivo compuesto (por ejemplo, un receptor inalámbrico que presenta una interfaz de teclado y una de mouse, o Bluetooth que presenta HCI y audio isócrono). Los drivers en USB se vinculan por *interfaz*, no por dispositivo, así que dos instancias de driver separadas (o incluso dos módulos distintos) pueden estar vinculadas al mismo dispositivo físico.

**A9.** Bus 1, puerto 4 del root hub; ahí hay un hub conectado; en ese hub, puerto 2; ahí hay otro hub conectado; en *ese* hub, puerto 1 — el dispositivo. La cadena con puntos es el camino físico desde el controlador raíz.

**A10.** Eléctricamente no cambió nada: el dispositivo sigue alimentado y sigue enumerado a nivel de bus. Lo que cambió es que el kernel lo desautoriza — desarma las interfaces del dispositivo, desvincula sus drivers y lo quita de la lista de dispositivos USB, de modo que `lsusb` ya no lo muestra y ningún driver puede hablar con él. Es el equivalente por software a desconectarlo, y es el mecanismo detrás de las listas blancas de dispositivos USB.

### Ejercicio 3 — Módulos

**A11.** El núcleo PCI enumera el dispositivo y crea un `struct device`, expuesto en `sysfs` en `/sys/devices/...` con un atributo `modalias` → el kernel emite un `uevent` (netlink) que contiene `MODALIAS=pci:v0000...` → `systemd-udevd` lo recibe y coincide con la regla incorporada que llama a `modprobe $env{MODALIAS}` → `modprobe` resuelve el alias contra `/lib/modules/$(uname -r)/modules.alias`, carga las dependencias desde `modules.dep`, e inserta el `.ko` → el registro del driver PCI del módulo coincide con la tabla de IDs del dispositivo y el `probe()` del driver lo vincula → el módulo ahora aparece en `lsmod` y `Kernel driver in use` aparece en `lspci -k`.

**A12.** `xhci_hcd` tiene contador de uso 1: `xhci_pci` depende de él. `rmmod` quita exactamente un módulo y se niega cuando el contador de uso es distinto de cero. `sudo modprobe -r xhci_hcd` recorre el grafo de dependencias y quita `xhci_pci` primero. (En la práctica esto también mata todos los dispositivos USB de ese controlador.)

**A13.** (1) `blacklist` solo suprime la carga *automática basada en alias*; algo lo está cargando explícitamente — otro módulo depende de él, está listado en `/etc/modules-load.d/`, o un script llama a `modprobe`. Solución: agregar `install nouveau /bin/false`. (2) El módulo se está cargando desde el **initramfs**, que lleva su propia instantánea de `/etc/modprobe.d/`. Solución: `update-initramfs -u` o `dracut -f`, y después reiniciar. Una tercera posibilidad: está compilado dentro del kernel en lugar de ser un módulo — verificá con `grep NOUVEAU /boot/config-$(uname -r)`; `=y` no se puede poner en la lista negra en absoluto, solo deshabilitar con un parámetro del kernel.

**A14.** `options` en `/etc/modprobe.d/` se aplica **en el momento de la carga** y es persistente tras reinicios, pero no tiene efecto sobre un módulo ya cargado. Escribir en `/sys/module/<mod>/parameters/<param>` cambia un valor en vivo de inmediato pero no es persistente, y solo funciona para los parámetros que el módulo declaró como escribibles (modo `0644` en lugar de `0444`); los parámetros de solo lectura únicamente se pueden establecer en el momento de la carga.

**A15.** `/lib/modules/$(uname ‑r)/modules.alias` (con las dependencias en `modules.dep`). Ambos se regeneran con `depmod -a`.

### Ejercicio 4 — Recursos

**A16.** Porque las interrupciones se entregan a una CPU específica, y la APIC local / la afinidad de IRQ deciden a cuál. Las columnas por CPU te permiten ver la distribución. Contadores concentrados en una sola CPU significan que la IRQ tiene una afinidad fijada (ver `/proc/irq/<n>/smp_affinity`) — normal para un dispositivo de cola única, pero en una NIC de alto rendimiento o en NVMe significa que un solo núcleo está haciendo todo el trabajo de interrupciones y es un cuello de botella real; `irqbalance` o la afinidad manual lo distribuyen.

**A17.** Sí, constantemente — pero no vía el controlador DMA ISA heredado. `/proc/dma` solo rastrea los canales ISA del 8237, que ningún periférico moderno usa. Los dispositivos PCI/PCIe son **bus masters**: inician sus propias transferencias a la memoria del sistema a través del bus PCI (visible como `BusMaster+` en `lspci -vv`), coordinadas mediante la IOMMU donde la haya. Que `/proc/dma` esté casi vacío es el estado esperado y sano.

**A18.** `/proc/ioports` mapea el espacio de direcciones de **E/S por puerto** de x86 (un espacio separado de 64 KiB al que se accede con las instrucciones `IN`/`OUT`), un mecanismo heredado usado por el PIC, los temporizadores, los puertos serie y el controlador PS/2. `/proc/iomem` mapea la **E/S mapeada en memoria** y la RAM dentro del espacio de direcciones físicas — la forma en que se direccionan esencialmente todos los dispositivos modernos. Las direcciones en `/proc/iomem` se ponen en cero para quien no es root porque el mapa filtra direcciones físicas del kernel, lo que derrota a KASLR; el archivo fue endurecido deliberadamente.

**A19.** No necesariamente. Las interrupciones PCI heredadas (INTx, mostradas como `IO-APIC ... fasteoi`) son disparadas por nivel y están *diseñadas* para compartirse: el kernel llama a cada manejador registrado por turno y cada uno verifica si su propio dispositivo levantó la línea. Solo se vuelve un problema cuando un driver mal escrito reclama interrupciones que no eran suyas, o cuando la latencia importa. Las líneas MSI/MSI-X (`PCI-MSI`) nunca se comparten — cada una es un mensaje distinto.

**A20.** El dispositivo no está entregando interrupciones. Causas típicas: la IRQ fue enrutada incorrectamente por las tablas ACPI del firmware, MSI está roto en ese chipset (una solución clásica es el parámetro de kernel `pci=nomsi` o una opción específica del driver), la interrupción está enmascarada, o el dispositivo está en un estado de bajo consumo. El driver vinculó y configuró el dispositivo con éxito — la capa 3 está bien, la capa 4 está rota.

### Ejercicio 5 — sysfs y udev

**A21.** El **kernel** crea el nodo, vía `devtmpfs`: apenas se registra un dispositivo de caracteres o de bloques, el kernel puebla `/dev` con un nodo que lleva el major:minor correcto y un modo por defecto propiedad de root. `udev` hace todo lo que viene *después*: aplicar propiedad, permisos y etiquetas SELinux; crear symlinks persistentes (`/dev/disk/by-uuid/...`, `/dev/labstick`); establecer propiedades que consumen otros servicios; ejecutar programas ante eventos de dispositivo. Antes de `devtmpfs`, `udev` también creaba los nodos — por eso la documentación más vieja dice otra cosa.

**A22.** `ATTR{}` coincide con un archivo de atributo en **el dispositivo del que trata el evento** — aquel cuyo `KERNEL`/`SUBSYSTEM` coincidiste. `ATTRS{}` coincide con un atributo en el dispositivo **o en cualquiera de sus ancestros** en el árbol de `sysfs`. La identidad USB (`idVendor`, `idProduct`, `serial`) vive en el nodo del dispositivo USB, varios niveles por encima del dispositivo de `block`, así que una regla que apunte a `/dev/sdb1` debe usar `ATTRS{idVendor}`. Advertencia: todos los `ATTRS{}` de una misma regla deben coincidir en el *mismo* dispositivo padre.

**A23.** (a) Renombrá tu archivo para que ordene **después** de la regla de la distribución — por ejemplo, `99-mystick.rules`; gana la última asignación. (b) Usá el operador `:=` (`MODE:="0660"`), que hace el valor final y prohíbe que reglas posteriores lo cambien. (Renombrar es la respuesta convencional; `:=` es el instrumento contundente.)

**A24.** `udevadm control --reload` le dice al `systemd-udevd` en ejecución que vuelva a leer sus archivos de reglas — pero las reglas solo se ejecutan ante eventos, y el dispositivo fue agregado antes de que existieran las nuevas reglas. `udevadm trigger` le pide al kernel que **vuelva a emitir uevents sintéticos** para los dispositivos ya presentes en `sysfs` (escribe en el archivo `uevent` de cada dispositivo), de modo que las nuevas reglas se evalúen contra el hardware existente sin reconectarlo.

**A25.** Son el mismo objeto del kernel visto a través de dos vistas. `/sys/devices/...` es la jerarquía real, organizada por topología física (host bridge → bus PCI → función → dispositivo de red). `/sys/class/net/enp0s31f6` es un **symlink** hacia ese árbol, que organiza los dispositivos por *función* en cambio. `sysfs` provee ambas porque las dos preguntas — "¿qué está conectado a este bus?" y "¿qué interfaces de red existen?" — son ambas legítimas, y un árbol puramente topológico hace que la segunda sea imposible de responder sin un recorrido completo. `/sys/bus/` es una tercera vista, por tipo de bus.

### Ejercicio 6 — Almacenamiento masivo

**A26.** Porque el **subsistema SCSI** de Linux es una abstracción de conjunto de comandos, no un estándar de cableado. `libata` traduce ATA/SATA a comandos SCSI; SAS es nativamente SCSI; `usb-storage` y `uas` transportan comandos SCSI sobre USB (Bulk-Only Transport / UAS); iSCSI y FC hacen lo mismo sobre una red. Todos ellos se registran en la capa intermedia SCSI, así que el driver de nivel superior `sd` los nombra `sdX` y les da direcciones `[host:channel:target:lun]`. NVMe es la excepción notable — evita SCSI por completo.

**A27.** El kernel está reportando lo que le dijeron. `rotational` se deriva de lo que anuncia el transporte (ATA `Nominal Media Rotation Rate`, página VPD SCSI `B1h`); los puentes USB-a-SATA con frecuencia no lo transmiten, así que el kernel usa `1` por defecto. Consecuencia: la capa de bloques aplica supuestos rotacionales — más fusión de E/S y comportamiento de elevador que evita búsquedas, con planificadores como `bfq`/`mq-deadline` — lo que es meramente subóptimo, no dañino. Podés sobrescribirlo: `echo 0 > /sys/block/sdb/queue/rotational`.

**A28.** `nvme0` = **controlador** NVMe 0. `n1` = **namespace** 1 en ese controlador. `p3` = partición 3 de ese namespace. Un namespace es una división del flash a nivel de controlador con su propio rango de LBA, tamaño de bloque y formateo — creada y destruida por el controlador mismo (`nvme create-ns`), invisible para la tabla de particiones. Las particiones son una construcción a nivel de sistema operativo escrita *dentro* de un namespace. Un controlador puede presentar varios namespaces, cada uno de los cuales se ve como un dispositivo de bloques independiente.

**A29.** `for h in /sys/class/scsi_host/host*; do echo "- - -" | sudo tee $h/scan; done`. Los tres campos son **canal, target (ID SCSI) y LUN**; `-` es un comodín que significa "escanear todos los valores", así que `- - -` significa "reescanear todo en este adaptador host". Nombrar números específicos escanea solo esa dirección.

**A30.** `lsblk -o NAME,ROTA,TRAN` para la respuesta rápida, y `sudo hdparm -I /dev/sda | grep Rotation` (o `sudo smartctl -i /dev/sda`) para la autoritativa. Confiá en `hdparm`/`smartctl`: le preguntan al *dispositivo* directamente vía un comando ATA IDENTIFY / SCSI INQUIRY, mientras que `ROTA` es una bandera del lado del kernel que un chip puente puede reportar mal (ver A27).

### Ejercicio 7 — Habilitar y deshabilitar periféricos

**A31.**

| Capa | ¿Persiste tras el reinicio? | ¿Sigue visible en `lspci`? |
|---|---|---|
| Firmware (Setup de BIOS/UEFI) | Sí | **No** — el dispositivo no se le presenta al sistema operativo en absoluto |
| Línea de comandos del kernel (GRUB) | Sí | Sí (a menos que el parámetro suprima todo el bus) |
| `/etc/modprobe.d/` | Sí | Sí, sin `Kernel driver in use` |
| unbind/remove por `sysfs` | **No** — se pierde al reiniciar | `unbind`: sí, sin driver. `remove`: no, hasta el rescan |

**A32.** La interfaz cae al instante, la conexión TCP se traba y la sesión queda muerta — no podés tipear el comando `bind`, porque el comando que tipearías tiene que viajar por la interfaz que acabás de deshabilitar. La recuperación requiere acceso fuera de banda: consola física, serie/IPMI/iDRAC, u otra NIC. Por eso el ejercicio usa el códec de audio. La costumbre profesional es envolver esas operaciones para que se reviertan solas: `sudo sh -c 'echo $DEV > .../unbind; sleep 30; echo $DEV > .../bind'`, ejecutado bajo `nohup`/`systemd-run` para que sobreviva a la sesión caída.

**A33.** `unbind` separa el **driver** del dispositivo: se ejecuta el `remove()` del driver, el dispositivo deja de funcionar, pero el `struct device` permanece en el árbol del kernel y el dispositivo sigue listado en `lspci` y bajo `/sys/bus/pci/devices/`. Podés volver a vincularlo escribiendo la dirección en el archivo `bind` del driver, o vincular un driver *distinto* (así es como se asocia `vfio-pci` para passthrough de PCI). `remove` borra el objeto de dispositivo del kernel por completo — desaparece de `lspci` y de `sysfs`, y solo un rescan del bus (`echo 1 > /sys/bus/pci/rescan`) lo trae de vuelta.

**A34.** `lspci`/`lsusb` lo revelan por **omisión**: el dispositivo simplemente está ausente, y `dmesg` nunca lo menciona. Contrastá con `dmidecode` o la lista de slots del fabricante para confirmar que el hardware existe. Ningún comando de Linux lo vuelve a habilitar — el firmware nunca le presenta el dispositivo al sistema operativo, así que no hay nada que el kernel pueda enumerar. Hay que reiniciar y entrar al Setup. (Herramientas del fabricante como `racadm` de Dell o `conrep` de HPE pueden editar los parámetros del firmware desde dentro de Linux, pero están escribiendo configuración de firmware, no habilitando el dispositivo en tiempo de ejecución.)

**A35.** Porque el initramfs debe poder montar el sistema de archivos raíz antes de que `/etc` esté disponible, así que lleva su propia copia de `/etc/modprobe.d/` y carga él mismo los drivers de almacenamiento, RAID y los críticos para la raíz. Una lista negra agregada solo en el sistema de archivos raíz real se lee demasiado tarde — el módulo ya está cargado. `pcspkr` nunca está en el initramfs; lo carga udev desde la raíz real después del `switch_root`, así que el archivo en disco se consulta a tiempo.

### Ejercicio 8 — D-Bus y diagnóstico

**A36.** Interrupción → el driver del **kernel** la maneja y actualiza su modelo de dispositivo, expuesto a través de **`sysfs`** (espacio de kernel) → el kernel emite un `uevent` sobre netlink → **`udev`** (`systemd-udevd`, espacio de *usuario*) procesa reglas, establece permisos, crea symlinks → los servicios que escuchan esos eventos (`udisks2`) publican señales en **D-Bus** (espacio de usuario) → el escritorio, suscrito a `org.freedesktop.UDisks2`, muestra la notificación. Solo `sysfs` y la generación del uevent son espacio de kernel; `udev` y D-Bus son ambos demonios de espacio de usuario comunes.

**A37.** `Kernel modules:` lista los módulos cuya tabla de alias coincide con el ID de este dispositivo, estén cargados o no. Su ausencia significa que **ningún módulo disponible para este kernel reclama este ID vendor:device** — el driver no está meramente descargado, no existe en `/lib/modules/$(uname -r)`. Los remedios son distintos: que falte solo `Kernel driver in use` significa hacerle `modprobe`; que falte `Kernel modules` significa instalar un kernel más nuevo, un driver DKMS/fuera del árbol, o un paquete de firmware/linux-firmware.

**A38.** El búfer circular del kernel almacena una marca de tiempo monotónica medida desde el arranque. `dmesg -T` la convierte restándola de la hora actual del reloj de pared — pero el reloj monotónico no avanza mientras la máquina está suspendida, así que después de cualquier ciclo de suspensión/reanudación cada marca de tiempo convertida se desvía por la duración total suspendida. Usá `journalctl -k`, que registra una marca de tiempo real de reloj de pared en el momento en que se lee cada mensaje, o `dmesg --time-format=iso` en kernels donde la fuente de reloj es confiable.

**A39.** En el espacio de usuario, entre el kernel y `udev`. El kernel emitió el uevent correctamente (la línea `KERNEL` lo prueba), pero `systemd-udevd` no terminó de procesarlo — el demonio no está corriendo o está trabado, una regla coincidió y se colgó (un programa `RUN+=` que se bloquea; `udev` los mata tras un timeout y lo registra), o un `RUN+=` falló. Verificá `systemctl status systemd-udevd`, `journalctl -u systemd-udevd -b`, y volvé a ejecutar el conjunto de reglas con `udevadm test <syspath>`.

**A40.** `sudo lshw -short` — una pantalla, todos los subsistemas, con la ruta de `sysfs`, el nodo de dispositivo y la clase de cada entrada. Limitación: es un *sintetizador*. Fusiona datos de DMI, PCI, USB, SCSI y `sysfs` en un único árbol y, por lo tanto, puede estar equivocado o desactualizado de maneras en que las herramientas primarias no lo están — las cadenas DMI en particular son lo que sea que el fabricante de la placa haya tipeado. Confirmá cualquier cosa que importe con la herramienta autoritativa de ese bus: `lspci -nnk`, `lsusb -t`, `lsblk -o …,TRAN`, `/proc/interrupts`. (`inxi -Fxz` es una alternativa más amigable con la misma advertencia.)

</details>

---

## Referencias

- LPI, *Exam 101 Objectives, version 5.0* — <https://www.lpi.org/our-certifications/exam-101-objectives/>
- Documentación del kernel de Linux, *sysfs — The filesystem for exporting kernel objects* — <https://docs.kernel.org/filesystems/sysfs.html>
- Documentación del kernel de Linux, *Rules on how to access information in sysfs* — <https://docs.kernel.org/admin-guide/sysfs-rules.html>
- Documentación del kernel de Linux, *The /proc Filesystem* — <https://docs.kernel.org/filesystems/proc.html>
- Documentación del kernel de Linux, *USB device authorization* — <https://docs.kernel.org/usb/authorization.html>
- Documentación del kernel de Linux, *NVMe subsystem* — <https://docs.kernel.org/admin-guide/nvme-multipath.html>
- `udev(7)` — <https://man7.org/linux/man-pages/man7/udev.7.html>
- `udevadm(8)` — <https://man7.org/linux/man-pages/man8/udevadm.8.html>
- `modprobe.d(5)` — <https://man7.org/linux/man-pages/man5/modprobe.d.5.html>
- `lspci(8)` — <https://man7.org/linux/man-pages/man8/lspci.8.html>
- `lsusb(8)` — <https://man7.org/linux/man-pages/man8/lsusb.8.html>
- `lsblk(8)` — <https://man7.org/linux/man-pages/man8/lsblk.8.html>
- freedesktop.org, *D-Bus Specification* — <https://dbus.freedesktop.org/doc/dbus-specification.html>
- freedesktop.org, *UDisks2 Reference Manual* — <https://storaged.org/doc/udisks2-api/latest/>
- The Linux Kernel Archives, *The USB Device Filesystem and usbutils* — <http://www.linux-usb.org/>