# Ejercicios guiados — Tema 4.2: Understanding Computer Hardware

**Certificación:** LPI Linux Essentials (010-160, versión 1.6) · **Peso:** 2
**Fuente de referencia:** [LPI Learning Materials 4.2](https://learning.lpi.org/en/learning-materials/010-160/4/4.2/)

Para estos ejercicios necesitás una terminal en cualquier sistema Linux (una máquina virtual o WSL también sirven). Ningún comando modifica el sistema: todos son de solo lectura.

---

## Ejercicio 1 — Explorar el procesador (CPU)

El procesador es el componente que ejecuta las instrucciones de los programas. Linux expone su información a través del pseudo-filesystem `/proc` y de utilidades como `lscpu`.

1. Ejecutá:
   ```bash
   lscpu
   ```
   Observá los campos `Architecture`, `CPU(s)`, `Model name` y `CPU MHz` (o `CPU max MHz`).

2. Ahora mirá la fuente de datos "cruda" que usa el kernel:
   ```bash
   cat /proc/cpuinfo | less
   ```
   Salí con `q`. Notá que aparece un bloque de información por cada núcleo lógico.

3. Contá cuántos procesadores lógicos ve el sistema:
   ```bash
   grep -c '^processor' /proc/cpuinfo
   ```

**Preguntas:**

- **1.a)** ¿Qué diferencia hay entre un *core* físico y un procesador lógico (*thread*)? ¿Por qué `lscpu` puede mostrar más CPUs que cores físicos?
- **1.b)** `/proc/cpuinfo` parece un archivo común, pero no ocupa espacio en disco. ¿Por qué?
- **1.c)** En `lscpu`, ¿qué indica el campo `Architecture` con un valor como `x86_64`?

---

## Ejercicio 2 — Memoria RAM y swap

La memoria RAM es almacenamiento volátil de trabajo: rápida, pero su contenido se pierde al apagar el equipo. El *swap* es espacio en disco que el kernel usa como extensión de la RAM.

1. Mostrá el uso de memoria en unidades legibles:
   ```bash
   free -h
   ```
   Identificá las columnas `total`, `used`, `free` y `available`, y la fila `Swap`.

2. Mirá la fuente de datos del kernel:
   ```bash
   head -5 /proc/meminfo
   ```

3. Verificá qué dispositivos o archivos están activos como swap:
   ```bash
   cat /proc/swaps
   ```

**Preguntas:**

- **2.a)** En `free -h`, ¿por qué `available` suele ser bastante mayor que `free`? ¿Cuál de las dos columnas responde mejor a "¿cuánta memoria puedo usar para una aplicación nueva?"
- **2.b)** ¿Qué pasa con el contenido de la RAM cuando se corta la energía? ¿Y con el contenido del swap?
- **2.c)** Si un sistema usa swap intensamente, ¿el rendimiento mejora o empeora? ¿Por qué?

---

## Ejercicio 3 — Discos, particiones y almacenamiento

El almacenamiento masivo (HDD, SSD, NVMe) es persistente: conserva los datos sin energía. Los discos se dividen en **particiones**, y cada una puede contener un filesystem.

1. Listá los dispositivos de bloque del sistema:
   ```bash
   lsblk
   ```
   Observá la jerarquía: el disco (por ejemplo `sda` o `nvme0n1`) y sus particiones (`sda1`, `nvme0n1p1`, …), con sus puntos de montaje.

2. Mirá cómo el kernel registra las particiones:
   ```bash
   cat /proc/partitions
   ```

3. Consultá el espacio libre de los filesystems montados:
   ```bash
   df -h
   ```

**Preguntas:**

- **3.a)** ¿Qué diferencia física clave hay entre un HDD y un SSD, y cómo afecta eso a la velocidad y a la resistencia a golpes?
- **3.b)** Según la convención de nombres de Linux, ¿qué representa `sda2`? ¿Y `sdb`?
- **3.c)** ¿Qué diferencia hay entre los esquemas de particionado MBR y GPT respecto a la cantidad de particiones primarias y al tamaño máximo de disco?
- **3.d)** ¿Por qué `lsblk` muestra dispositivos aunque no estén montados, mientras que `df` solo muestra filesystems montados?

---

## Ejercicio 4 — Periféricos: buses PCI y USB

Los periféricos se conectan al sistema mediante buses. Los dos que más vas a consultar son **PCI** (placas de video, controladoras de red y de disco) y **USB** (teclados, mouse, pendrives, webcams).

1. Listá los dispositivos PCI:
   ```bash
   lspci
   ```
   Buscá líneas que mencionen `VGA` (video), `Ethernet` o `Network` (red) y `SATA`/`NVMe` (almacenamiento).

2. Listá los dispositivos USB:
   ```bash
   lsusb
   ```
   Si tenés un pendrive a mano, conectalo y volvé a ejecutar `lsusb` para ver la nueva entrada.

3. Mirá los últimos mensajes del kernel (útil para ver qué detectó al conectar el pendrive):
   ```bash
   sudo dmesg | tail -20
   ```

**Preguntas:**

- **4.a)** ¿Qué comando usarías para averiguar el modelo exacto de la placa de red integrada de una máquina: `lsusb` o `lspci`? ¿Por qué?
- **4.b)** En la salida de `lspci`, cada línea empieza con algo como `00:1f.2`. ¿Qué representa ese identificador?
- **4.c)** ¿Qué ventaja práctica tiene USB como bus de periféricos frente a conectar una placa interna PCI?

---

## Ejercicio 5 — Drivers y módulos del kernel

Un **driver** es el software que permite al kernel comunicarse con un dispositivo. En Linux, muchos drivers se cargan como **módulos del kernel** bajo demanda.

1. Listá los módulos cargados actualmente:
   ```bash
   lsmod | head -15
   ```

2. Elegí un módulo de la lista (por ejemplo uno relacionado con tu placa de red) y pedí información sobre él:
   ```bash
   modinfo <nombre_del_módulo>
   ```
   Observá los campos `description`, `filename` y `depends`.

3. Verificá qué driver está usando un dispositivo PCI concreto:
   ```bash
   lspci -k | less
   ```
   Buscá las líneas `Kernel driver in use:`.

**Preguntas:**

- **5.a)** ¿Qué ventaja tiene un kernel modular (drivers como módulos cargables) frente a un kernel monolítico con todos los drivers compilados adentro?
- **5.b)** Conectás un mouse USB y funciona sin instalar nada. ¿Qué hizo el sistema para lograrlo?
- **5.c)** En `lsmod`, la tercera columna (`Used by`) muestra dependencias entre módulos. ¿Por qué no se puede descargar un módulo que otro módulo está usando?

---

## Ejercicio 6 — Firmware, hora del sistema y otros componentes

La **motherboard** integra los componentes y contiene el **firmware** (BIOS o UEFI), que inicializa el hardware antes de arrancar el sistema operativo. Un reloj alimentado por pila (RTC, *real-time clock*) mantiene la hora con el equipo apagado.

1. Consultá el fabricante y versión del firmware (requiere root):
   ```bash
   sudo dmidecode -s bios-vendor
   sudo dmidecode -s bios-version
   ```
   Si `dmidecode` no está disponible, probá:
   ```bash
   cat /sys/class/dmi/id/bios_vendor /sys/class/dmi/id/bios_version
   ```

2. Verificá si tu sistema arrancó con UEFI o con BIOS legacy:
   ```bash
   ls /sys/firmware/efi 2>/dev/null && echo "UEFI" || echo "BIOS legacy"
   ```

3. Compará la hora del sistema con la del reloj de hardware:
   ```bash
   date
   sudo hwclock
   ```

**Preguntas:**

- **6.a)** ¿Cuál es la función del firmware (BIOS/UEFI) en el proceso de arranque, antes de que Linux tome el control?
- **6.b)** ¿Por qué la computadora "recuerda" la hora aunque estuvo desenchufada toda la noche?
- **6.c)** Mencioná dos diferencias entre UEFI y BIOS legacy relevantes para el arranque del sistema.
- **6.d)** ¿Qué papel cumple la fuente de alimentación (*power supply*, PSU) y qué convierte exactamente?

---

<details>
<summary><strong>Respuestas</strong></summary>

### Ejercicio 1

- **1.a)** Un *core* físico es una unidad de procesamiento completa dentro del chip. Con tecnologías como *simultaneous multithreading* (Hyper-Threading en Intel), cada core físico puede presentar dos hilos de ejecución al sistema operativo. Linux cuenta cada hilo como un procesador lógico, por eso `lscpu` puede mostrar, por ejemplo, 8 CPUs en un chip de 4 cores.
- **1.b)** `/proc` es un pseudo-filesystem: sus "archivos" no existen en disco, sino que el kernel genera su contenido en el momento en que se leen. Es una ventana en tiempo real al estado del sistema.
- **1.c)** Indica el juego de instrucciones de la CPU: `x86_64` es la arquitectura de 64 bits compatible con Intel/AMD. Determina, entre otras cosas, qué binarios y qué versión del sistema operativo se pueden ejecutar.

### Ejercicio 2

- **2.a)** Linux usa la RAM "sobrante" como caché de disco (*buffers/cache*) para acelerar el sistema, y esa memoria cuenta como usada aunque puede liberarse al instante si una aplicación la necesita. Por eso `available` (que incluye la caché recuperable) es la mejor estimación de cuánta memoria hay realmente disponible para nuevos procesos; `free` solo muestra la memoria que no se está usando para nada.
- **2.b)** La RAM es volátil: su contenido se pierde al cortarse la energía. El swap está en disco (almacenamiento persistente), así que sus datos sobreviven físicamente al apagado, aunque el sistema los descarta y no los reutiliza en el siguiente arranque (salvo en hibernación, que justamente aprovecha el swap para guardar el estado de la RAM).
- **2.c)** Empeora. El disco —incluso un SSD— es órdenes de magnitud más lento que la RAM. Un uso intenso de swap (*thrashing*) indica que falta RAM y el sistema pierde tiempo moviendo páginas entre memoria y disco.

### Ejercicio 3

- **3.a)** Un HDD tiene platos magnéticos que giran y cabezales móviles (partes mecánicas); un SSD almacena en memoria flash sin partes móviles. Por eso el SSD es mucho más rápido (sobre todo en accesos aleatorios), más resistente a golpes y silencioso, aunque históricamente con mayor costo por gigabyte.
- **3.b)** `sda2` es la segunda partición del primer disco tipo SCSI/SATA/USB detectado. `sdb` es el segundo disco completo (sin referirse a ninguna partición). En discos NVMe la convención es distinta: `nvme0n1p2` sería la partición 2 del primer disco NVMe.
- **3.c)** MBR admite como máximo 4 particiones primarias (una puede ser extendida para contener lógicas) y discos de hasta 2 TB. GPT admite una cantidad de particiones mucho mayor (típicamente 128) y discos de tamaños enormemente superiores (del orden de zettabytes); es el esquema asociado a UEFI.
- **3.d)** `lsblk` lee la lista de dispositivos de bloque que el kernel detectó, estén o no en uso. `df` informa espacio libre por filesystem, y eso solo tiene sentido para filesystems montados: una partición sin montar no tiene "uso" visible para el sistema de archivos.

### Ejercicio 4

- **4.a)** `lspci`, porque la placa de red integrada está conectada al bus PCI/PCIe de la motherboard. `lsusb` solo muestra dispositivos conectados al bus USB (por ejemplo, un adaptador de red USB externo sí aparecería ahí).
- **4.b)** Es la dirección del dispositivo en el bus PCI, con formato `bus:dispositivo.función` (por ejemplo `00:1f.2` = bus 00, dispositivo 1f, función 2). Identifica de forma única la ubicación del dispositivo en el bus.
- **4.c)** USB es *hot-plug*: se conecta y desconecta con el equipo encendido, sin abrir el gabinete, y el sistema detecta el dispositivo y carga el driver automáticamente. Además provee alimentación eléctrica al periférico por el mismo cable.

### Ejercicio 5

- **5.a)** Los módulos se cargan solo cuando hacen falta: el kernel queda más chico en memoria, se pueden agregar drivers para hardware nuevo sin recompilar ni reiniciar, y un driver problemático puede descargarse. Un kernel con todo compilado adentro sería más grande y menos flexible.
- **5.b)** El kernel detectó el dispositivo nuevo en el bus USB, identificó su tipo (dispositivo HID, *Human Interface Device*) y cargó automáticamente el módulo/driver correspondiente (por ejemplo `usbhid`). Esa detección y carga automática es visible en `dmesg`.
- **5.c)** Porque el módulo dependiente invoca funciones del módulo del que depende. Si se descargara el módulo base, esas llamadas apuntarían a código inexistente y el kernel se corrompería. Por eso el kernel se niega a descargar (`rmmod` falla) mientras el contador `Used by` sea mayor que cero.

### Ejercicio 6

- **6.a)** El firmware se ejecuta al encender el equipo: inicializa y verifica el hardware básico (POST), configura componentes de la motherboard y localiza el dispositivo de arranque, cediendo luego el control al *bootloader* (por ejemplo GRUB), que a su vez carga el kernel de Linux.
- **6.b)** Porque la motherboard tiene un reloj de tiempo real (RTC, *hardware clock*) alimentado por una pila de botón (CMOS battery), que sigue funcionando con el equipo apagado y desenchufado. Al arrancar, Linux lee esa hora y luego mantiene la suya propia (*system clock*), habitualmente sincronizada por NTP.
- **6.c)** Diferencias relevantes: (1) UEFI arranca desde una partición especial (EFI System Partition, con formato FAT) donde residen los cargadores de arranque, mientras que BIOS legacy ejecuta código del primer sector del disco (el MBR); (2) UEFI trabaja nativamente con GPT y soporta discos de más de 2 TB, y agrega funciones como Secure Boot; BIOS legacy está atado a MBR y sus límites.
- **6.d)** La PSU convierte la corriente alterna (AC) del tomacorriente en corriente continua (DC) a los voltajes bajos y estables que necesitan la motherboard, la CPU, los discos y demás componentes. Una fuente de capacidad insuficiente o de mala calidad causa inestabilidad y reinicios.

</details>

---

**Fuente consultada:** [https://learning.lpi.org/en/learning-materials/010-160/4/4.2/](https://learning.lpi.org/en/learning-materials/010-160/4/4.2/)