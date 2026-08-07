# LPI-702 BSD Specialist: Objetivo 711.4 — Configuración de Hardware

**Certificación:** LPI BSD Specialist (Examen 702-100, Versión 1.0)  
**Tema 711.4:** Configuración de Hardware  
**Peso del examen:** 3.33 (Peso: 2 de 60 unidades de peso total del examen)  
**Referencia oficial:** [LPI BSD Specialist Overview](https://www.lpi.org/our-certifications/bsd-specialist-overview/)

---

## Arquitectura Técnica y Mecánica de Bajo Nivel

En los sistemas operativos BSD (FreeBSD, NetBSD, OpenBSD), la abstracción de hardware y el descubrimiento de dispositivos se basan en una combinación de controladores de enumeración de buses, árboles de dispositivos estáticos y dinámicos, y utilidades de gestión específicas de cada subsistema. Comprender estos mecanismos internos es crítico para los SRE empresariales que gestionan hipervisores bare-metal, nodos de almacenamiento y dispositivos de red de alto rendimiento.

```
+-------------------------------------------------------------------------+
|                          User Space Utilities                           |
|  (pciconf, camcontrol, devinfo, kldload/modload, atactl, scsictl, dmesg)|
+-------------------------------------------------------------------------+
                                    |
                                    v [ioctl() / sysctl / devfs]
+-------------------------------------------------------------------------+
|                             BSD Kernel                                  |
|  +---------------------+   +-------------------+   +-----------------+  |
|  |     Newbus / Autoconf|   |  CAM Subsystem    |   | KLD / Module    |  |
|  |     (Device Tree)   |   | (Common Access)   |   | Subsystem       |  |
|  +---------------------+   +-------------------+   +-----------------+  |
+-------------------------------------------------------------------------+
                                    |
                                    v
+-------------------------------------------------------------------------+
|                          Hardware Controller                            |
|       (PCIe Root Complex, NVMe Controller, AHCI SATA, SAS HBA)          |
+-------------------------------------------------------------------------+
```

### 1. Árbol de Dispositivos y Mecánica de Enumeración de Buses
* **Framework Newbus de FreeBSD:** FreeBSD utiliza la arquitectura `Newbus` para representar la jerarquía de hardware como un árbol de dispositivos (`device_t`). Cuando el sistema arranca, el kernel inicializa los buses raíz (tales como `nexus0` o `acpi0`), los cuales sondean recursivamente los buses hijos (PCI, ISA, USB). Los controladores coinciden los identificadores de hardware con los PCI IDs de proveedor y dispositivo expuestos por el PCIe Configuration Space.
* **Autoconf de NetBSD/OpenBSD:** NetBSD y OpenBSD utilizan un framework de coincidencia y acople (match-and-attach) `autoconf(9)` (`cfattach`). El descubrimiento de hardware ocurre a través de funciones de coincidencia del controlador que evalúan las estructuras de capacidad pasadas por los controladores de bus padre durante la inicialización del sistema.

### 2. Subsistema CAM (Common Access Method) de FreeBSD
FreeBSD enruta todas las transacciones de almacenamiento en disco y cinta a través de la arquitectura CAM (`cam(4)`). CAM desacopla las capas de transporte físico (SATA, SAS, NVMe, almacenamiento masivo USB) de los motores lógicos de ejecución SCSI. Los controladores periféricos (por ejemplo, `da` para discos de Acceso Directo, `ada` para discos ATA, `nda` para dispositivos NVM Express) se comunican con los controladores SIM (Subsystem Interface Module) a través de CCBs (CAM Control Blocks).

### 3. Subsistema de Módulos del Kernel (KLD / LKM) y Controles de Seguridad
La carga dinámica permite cargar archivos de objeto del kernel (`.ko` en FreeBSD, `.kmod` en NetBSD) sin reiniciar.
* **Subsistema `kld` de FreeBSD:** Utiliza llamadas al sistema `kldload(2)` para mapear binarios ELF directamente en el espacio del kernel, resolviendo símbolos del kernel de forma dinámica.
* **Límites de Seguridad (`kern.securelevel`):** En `securelevel = 1` o superior, la carga dinámica de módulos del kernel se deshabilita a nivel de todo el kernel para prevenir la ejecución arbitraria de código y rootkits. La carga de módulos a través de `/boot/loader.conf` ocurre durante la etapa del cargador de arranque *antes* de que el kernel inicialice el userland y aplique `securelevel`.

---

## Ejercicio Guiado 1: Descubrimiento de Hardware de Bajo Nivel y Sondeo del Bus PCI

### Escenario
Está solucionando problemas en un servidor de almacenamiento empresarial con FreeBSD 14-RELEASE recién montado en rack. El SO no logra acoplar una tarjeta de interfaz de red (NIC) de 100GbE de alto rendimiento. Debe inspeccionar el buffer circular de mensajes del sistema, inspeccionar el espacio de configuración del bus PCI, verificar los IDs de proveedor/dispositivo de hardware y determinar el estado de acople del controlador.

### Pasos de Ejecución

1. **Inspeccionar el buffer circular de mensajes del sistema y los registros de sondeo:**
   Examine los mensajes de arranque del kernel para ubicar la enumeración del bus PCI y los dispositivos de hardware no mapeados.

   ```bash
   dmesg | grep -i pci
   ```
   *Salida esperada:*
   ```text
   pci0: <PCI bus> on pcib0
   pci0: <network, ethernet> at device 0.0 (no driver attached)
   pci0: <storage, flash> at device 1.0 (driver attached as nda0)
   ```

2. **Examinar el árbol completo de dispositivos de hardware:**
   Consulte el árbol de dispositivos del kernel para analizar las relaciones bus padre-hijo.

   ```bash
   devinfo -v | head -n 25
   ```
   *Salida esperada:*
   ```text
   nexus0
     cryptosoft0
     acpi0
       pcib0 pnpinfo _HID=PNP0A08 _UID=0 on acpi0
         pci0 on pcib0
           isab0 pnpinfo vendor=0x8086 device=0x1d41 subvendor=0x15d9 subdevice=0x0600 class=0x060100 at slot 31 function 0 on pci0
           ixgbe0 pnpinfo vendor=0x8086 device=0x1572 subvendor=0x15d9 subdevice=0x0600 class=0x020000 at slot 0 function 0 on pci0
   ```

3. **Consultar el espacio de configuración PCI y los IDs de Proveedor/Dispositivo:**
   Utilice `pciconf` de FreeBSD para listar descriptores detallados de hardware, cadenas selectoras y registros de encabezado PCI.

   ```bash
   pciconf -lv
   ```
   *Salida esperada:*
   ```text
   none0@pci0:0:0:0:	class=0x020000 rev=0x00 hdr=0x00 vendor=0x15b3 device=0x101d subvendor=0x15b3 subdevice=0x0003
       vendor     = 'Mellanox Technologies'
       device     = 'MT2892 Family [ConnectX-6 Dx]'
       class      = network
       subclass   = ethernet
   ```

4. **Inspeccionar las capacidades del dispositivo PCI y el estado de gestión de energía:**
   Realice una lectura detallada de los registros de configuración PCI para el selector `pci0:0:0:0`.

   ```bash
   pciconf -bc pci0:0:0:0
   ```
   *Salida esperada:*
   ```text
   none0@pci0:0:0:0: class=0x020000 rev=0x00 hdr=0x00 vendor=0x15b3 device=0x101d subvendor=0x15b3 subdevice=0x0003
       bar   [10] type Memory 64-bit length 33554432 alloc base 0xfb000000 enabled
       cap 01[40] powerspec 3  supports D1 D2 D3  current D0
       cap 10[60] PCI-Express 2 endpoint max data 256(512) ro
       cap 11[9c] MSI-X max 64 vectors enabled
   ```

5. **Verificación multiplataforma (Alternativa en NetBSD):**
   *Nota:* Si ejecuta en NetBSD, inspeccione los dispositivos PCI utilizando `pcictl`.

   ```bash
   # NetBSD equivalent
   pcictl /dev/pci0 list
   ```

---

### Preguntas de Verificación

#### Pregunta 1.1
En la salida de `pciconf -lv`, ¿qué le indica a un Administrador de Sistemas el identificador de dispositivo `none0@pci0:0:0:0:`?
- A) El dispositivo está fallando físicamente y generando errores de paridad en el bus PCI.
- B) El dispositivo es reconocido en el dominio PCI 0, bus 0, ranura 0, función 0, pero ningún controlador de kernel cargado lo ha reclamado.
- C) El dispositivo es un marcador de posición virtual simulado asignado por `devfs`.
- D) La ranura PCI no tiene alimentación y está funcionando en el estado D3 de bajo consumo.

#### Pregunta 1.2
¿Qué recurso de documentación oficial detalla la sintaxis y las flags para la inspección del espacio de configuración PCI de FreeBSD?
- A) [FreeBSD pciconf(8) Manual Page](https://man.freebsd.org/cgi/man.cgi?query=pciconf)
- B) [NetBSD devpubd(8) Manual Page](https://man.netbsd.org/devpubd.8)
- C) [OpenBSD sysctl(8) Manual Page](https://man.openbsd.org/sysctl.8)
- D) [FreeBSD camcontrol(8) Manual Page](https://man.freebsd.org/cgi/man.cgi?query=camcontrol)

---

## Ejercicio Guiado 2: Diagnóstico y Control del Bus de Almacenamiento (CAM, SCSI, ATA)

### Escenario
Un nodo de base de datos empresarial que ejecuta FreeBSD experimenta un IOPS degradado. Sospecha que una unidad SATA/SAS defectuosa conectada al subsistema CAM está fallando. Debe escanear el bus CAM, emitir comandos raw SCSI Inquiry, manipular la topología del bus en tiempo de ejecución y comparar los paradigmas de gestión de almacenamiento con las utilidades de NetBSD/OpenBSD.

### Pasos de Ejecución

1. **Listar todos los dispositivos de almacenamiento activos en el subsistema CAM de FreeBSD:**
   Muestre las vinculaciones de dispositivos, ubicaciones de bus, IDs de target, LUNs y números de serie.

   ```bash
   camcontrol devlist -v
   ```
   *Salida esperada:*
   ```text
   <SAMSUNG MZ7LH960HAJR-00005 H2040003>  at scbus0 target 0 lun 0 (ada0,pass0)
   <SAMSUNG MZ7LH960HAJR-00005 H2040003>  at scbus0 target 1 lun 0 (ada1,pass1)
   <SEAGATE ST12000NM0007 E004>           at scbus1 target 4 lun 0 (da0,pass2)
   <LSI SAS3008 06.00.00.00>              at scbus1 target 8 lun 0 (xpt0,pass3)
   ```

2. **Emitir una solicitud de página SCSI INQUIRY de bajo nivel:**
   Consulte la unidad target `da0` directamente a través de su dispositivo de paso directo (pass-through device, `pass2`).

   ```bash
   camcontrol inquiry da0 -v
   ```
   *Salida esperada:*
   ```text
   pass2: <SEAGATE ST12000NM0007 E004> Fixed Direct Access SCSI-6 device
   pass2: serial number ZVT0A1B2
   pass2: 300.000MB/s transfers, Variable Command Queueing Enabled
   protocol      SCSI-6
   device type   Direct Access
   capabilities  16-bit wide, Command Queueing
   ```

3. **Realizar un reescaneo en caliente (Hot-Rescan) del bus de almacenamiento:**
   Después de reemplazar una unidad defectuosa en la bahía de discos 1 (target 1), active un reescaneo de bus en todos los controladores CAM sin reiniciar.

   ```bash
   camcontrol rescan all
   ```
   *Salida esperada:*
   ```text
   Re-scan of bus 0 was successful
   Re-scan of bus 1 was successful
   ```

4. **Solicitar atributos SMART y de velocidad del bus:**
   Inspeccione los parámetros de transferencia de bus negociados para el disco físico `ada0`.

   ```bash
   camcontrol negotiate ada0
   ```
   *Salida esperada:*
   ```text
   Current parameters for ada0:
   SATA transfer rate: 6.0Gb/s (SATA 3.x)
   Command Queueing:   Enabled (NCQ depth 32)
   ```

5. **Diagnósticos ATA/SCSI multiplataforma (NetBSD y OpenBSD):**
   Ejecute utilidades específicas de la plataforma en NetBSD y OpenBSD para inspeccionar los registros ATA y emitir comandos SCSI.

   ```bash
   # NetBSD ATA device control
   atactl /dev/atabus0 device 0 identify

   # NetBSD SCSI bus inspection
   scsictl /dev/scsibus0 scan any any

   # OpenBSD ATA/IDE control
   atactl /dev/wd0c identify
   ```

---

### Preguntas de Verificación

#### Pregunta 2.1
¿Cuál es el rol principal del controlador `pass` (por ejemplo, `pass0`, `pass1`) en la arquitectura CAM de FreeBSD?
- A) Proporciona almacenamiento en caché de bloques asíncrono de alto rendimiento para pools de ZFS.
- B) Permite que las utilidades de userland (`camcontrol`, `smartctl`) envíen Bloques Descriptores de Comandos (CDBs) SCSI/ATA raw directamente a los targets de hardware.
- C) Comprime escrituras de bloques antes de transmitirlas a través de HBAs SAS.
- D) Maneja modos de respaldo (fallback) IDE heredados cuando ACPI está deshabilitado en `/boot/loader.conf`.

#### Pregunta 2.2
En OpenBSD y NetBSD, ¿qué utilidad está designada específicamente para emitir comandos de identificación ATA de bajo nivel directamente a controladores IDE/SATA?
- A) `camcontrol`
- B) `atactl`
- C) `kldload`
- D) `pciconf`

---

## Ejercicio Guiado 3: Gestión de Módulos del Kernel en Tiempo de Ejecución y Persistencia en el Arranque

### Escenario
Para habilitar la descarga de hardware de red (offloading) para NICs de alta velocidad Mellanox en FreeBSD, debe cargar dinámicamente el módulo del controlador de red `mlx5en`, analizar las dependencias de símbolos del kernel y configurar los archivos de configuración del sistema para garantizar la persistencia tras los reinicios del nodo. También aprenderá la sintaxis de gestión de módulos de NetBSD.

### Pasos de Ejecución

1. **Mostrar los módulos del kernel cargados actualmente:**
   Verifique los módulos del kernel actualmente activos, las direcciones de memoria, los tamaños y los IDs de módulo en FreeBSD.

   ```bash
   kldstat
   ```
   *Salida esperada:*
   ```text
   Id Refs Address            Size     Name
    1   18 0xffffffff80200000 1f3e000  kernel
    2    1 0xffffffff8213e000 3800     zfs.ko
    3    1 0xffffffff82142000 89a0     opensolaris.ko
   ```

2. **Cargar dinámicamente el módulo del controlador de hardware requerido:**
   Cargue el módulo del controlador Ethernet y core de Mellanox ConnectX-4/5/6 en el kernel en ejecución.

   ```bash
   kldload mlx5en
   ```
   *Verificar el éxito de la carga del módulo:*
   ```bash
   kldstat | grep mlx5
   ```
   *Salida esperada:*
   ```text
    4    2 0xffffffff8214b000 4a120    mlx5.ko
    5    1 0xffffffff82196000 1c890    mlx5en.ko
   ```

3. **Inspeccionar metadatos de módulos del kernel y capacidades exportadas:**
   Examine las dependencias del módulo y los metadatos de versión exportados.

   ```bash
   kldstat -v -i 5
   ```
   *Salida esperada:*
   ```text
   Id: 5
   Name: mlx5en.ko
   Contains modules:
   	Id Path
   	 85 pci/mlx5en
   	 86 struct/mlx5en
   ```

4. **Configurar la carga persistente de módulos en el arranque:**
   Para hacer persistentes los módulos de hardware a través de los reinicios en FreeBSD, configure `/boot/loader.conf`. Cree o actualice `/boot/loader.conf` con directivas de parámetros sintácticamente válidas.

   ```bash
   cat << 'EOF' > /boot/loader.conf
   # /boot/loader.conf - System Initialization Hardware Loader Config
   # Enable Mellanox ConnectX Core and Ethernet drivers
   mlx5_load="YES"
   mlx5en_load="YES"

   # Hardware Offloading and Memory Allocations
   hw.mlx5.num_comp_vectors="8"
   kern.ipc.nmbclusters="1048576"

   # Enable NVMe controller driver
   nvme_load="YES"
   EOF
   ```

5. **Configurar hints de dispositivos de hardware estáticos:**
   Configure recursos de hardware estáticos (IRQ, puertos de E/S) para dispositivos heredados o que no son ACPI en `/boot/device.hints`.

   ```bash
   cat << 'EOF' >> /boot/device.hints
   hint.uart.0.at="isa"
   hint.uart.0.port="0x3F8"
   hint.uart.0.flags="0x10"
   hint.uart.0.irq="4"
   EOF
   ```

6. **Control de módulos del kernel multiplataforma (NetBSD):**
   *Nota:* NetBSD utiliza `modstat`, `modload` y `modunload` para las operaciones en tiempo de ejecución de los módulos del kernel.

   ```bash
   # NetBSD listing loaded modules
   modstat

   # NetBSD loading a driver module
   modload /usr/tests/sys/modules/kmod/kmod.kmod

   # NetBSD unloading a module
   modunload kmod
   ```

---

### Preguntas de Verificación

#### Pregunta 3.1
En FreeBSD, ¿qué sucede si un administrador ejecuta `kldload mlx5en` cuando el kernel del sistema está ejecutándose en `kern.securelevel = 1`?
- A) El módulo se carga correctamente, pero se registra una advertencia en syslog.
- B) La operación falla con "Operation not permitted" porque la carga dinámica de módulos del kernel está estrictamente prohibida en securelevel >= 1.
- C) El kernel se reinicia en modo de recuperación de usuario único (`bsd.rd`).
- D) El módulo se prepara automáticamente en `/boot/loader.conf` para su ejecución en el siguiente ciclo de arranque.

#### Pregunta 3.2
¿Qué archivo de configuración de FreeBSD es analizado por `loader(8)` antes de la inicialización del kernel para cargar controladores de dispositivos y establecer parámetros de ajuste (tunables) tempranos del kernel (hints de `sysctl`)?
- A) `/etc/rc.conf`
- B) `/etc/sysctl.conf`
- C) `/boot/loader.conf`
- D) `/etc/devd.conf`

---

## Ejercicio Guiado 4: Resolución de Problemas de Hardware Empresarial y Compensaciones de Seguridad del Kernel

### Escenario
Una auditoría de seguridad SRE exige aplicar una protección estricta de la memoria del kernel (`kern.securelevel = 2`) mientras se ajustan dinámicamente los buffers circulares de red (`sysctl`) y se previene la desvinculación no autorizada de controladores en la infraestructura FreeBSD.

### Pasos de Ejecución

1. **Consultar y modificar parámetros del kernel activos en tiempo de ejecución:**
   Lea y actualice los parámetros de ajuste (tunables) de hardware en vivo utilizando `sysctl`.

   ```bash
   # Query current PCI and ACPI power parameters
   sysctl hw.pci
   ```
   *Salida esperada:*
   ```text
   hw.pci.enable_io_modes: 1
   hw.pci.do_power_nodriver: 0
   hw.pci.enable_msix: 1
   ```

2. **Configurar parámetros del kernel persistentes en tiempo de ejecución en `/etc/sysctl.conf`:**
   Agregue variables de ajuste de hardware a `/etc/sysctl.conf`.

   ```bash
   cat << 'EOF' >> /etc/sysctl.conf
   # /etc/sysctl.conf - Runtime Kernel System Control Configuration
   # Disable automatic power-down of PCI devices without attached drivers
   hw.pci.do_power_nodriver=0

   # Expand maximum network device queue length
   net.route.netisr_maxqlen=4096
   EOF
   ```

3. **Analizar las compensaciones de seguridad entre kernels monolíticos y la carga dinámica de módulos:**
   Revise los niveles de seguridad y verifique la protección de securelevel contra modificaciones del kernel en tiempo de ejecución.

   ```bash
   sysctl kern.securelevel
   ```
   *Salida esperada:*
   ```text
   kern.securelevel: 0
   ```

   *Análisis de compensaciones arquitectónicas:*
   * **Módulos dinámicos:** Proporcionan flexibilidad operativa; los controladores se pueden cargar/descargar a demanda sin tiempo de inactividad. *Riesgo:* Expone un vector de ataque donde las cuentas de root comprometidas pueden inyectar rootkits a nivel de kernel mediante `kldload` o `modload`.
   * **Kernels monolíticos/estáticos (`securelevel >= 1`):** Compilar todos los controladores de hardware requeridos directamente en el binario del kernel (`/boot/kernel/kernel`) y establecer `kern.securelevel=1` en `/etc/sysctl.conf` garantiza la integridad del código del kernel. *Compensación:* Requiere un reinicio completo del sistema para actualizar controladores o agregar hardware.

---

### Preguntas de Verificación

#### Pregunta 4.1
¿Cuál es la diferencia operativa crucial entre establecer parámetros de ajuste (tunables) de hardware en `/boot/loader.conf` versus establecer variables del kernel en `/etc/sysctl.conf`?
- A) `/etc/sysctl.conf` es evaluado por el cargador de arranque antes de la ejecución del kernel; `/boot/loader.conf` se analiza después de que `init(8)` se inicia.
- B) `/boot/loader.conf` ajusta parámetros de solo lectura del kernel antes del sondeo de dispositivos; `/etc/sysctl.conf` ajusta parámetros de lectura y escritura del kernel después de que se completa el arranque de userland.
- C) Los parámetros en `/boot/loader.conf` se aplican solo a NetBSD, mientras que `/etc/sysctl.conf` se aplica estrictamente a OpenBSD.
- D) `/etc/sysctl.conf` habilita el hot-plugging dinámico del bus PCI; `/boot/loader.conf` deshabilita la gestión de energía del sistema.

#### Pregunta 4.2
Consulte los recursos de documentación oficial de BSD. ¿Qué URL proporciona información fidedigna sobre las utilidades de módulos del kernel y archivos de configuración de FreeBSD?
- A) [FreeBSD Handbook: Kernel Configuration](https://docs.freebsd.org/en/books/handbook/kernelconfig/)
- B) [FreeBSD kldload(8) Manual Page](https://man.freebsd.org/cgi/man.cgi?query=kldload)
- C) [FreeBSD loader.conf(5) Manual Page](https://man.freebsd.org/cgi/man.cgi?query=loader.conf)
- D) Todas las anteriores.

---

## Soluciones y Clave de Explicaciones

<details>
<summary><strong>Haga clic para desplegar la clave de respuestas y las explicaciones técnicas completas</strong></summary>

### Soluciones del Ejercicio 1

* **Pregunta 1.1: Respuesta correcta: B**
  * **Explicación:** En la salida de la utilidad `pciconf -lv` de FreeBSD, `none0@pci0:0:0:0:` designa un dispositivo físico descubierto en el bus PCI (Dominio 0, Bus 0, Ranura 0, Función 0) para el cual ningún módulo de controlador de kernel cargado ha reclamado o acoplado el dispositivo (clase `none`).
  * **Análisis de opciones incorrectas:**
    * La A es incorrecta: Los errores de mal funcionamiento de hardware se registran en `dmesg` o en excepciones de comprobación de máquina (MCE), no denotados por la etiqueta de clase `none`.
    * La C es incorrecta: `devfs` gestiona nodos `/dev` virtuales para controladores acoplados; los dispositivos no acoplados no crean nodos de caracteres/bloques en `/dev`.
    * La D es incorrecta: Los estados de bajo consumo D3 son flags de gestión de energía mostrados en los registros de capacidad (`cap 01`), no indicados por `none0`.

* **Pregunta 1.2: Respuesta correcta: A**
  * **Explicación:** La página de manual oficial para `pciconf` se mantiene en la [FreeBSD pciconf(8) Manual Page](https://man.freebsd.org/cgi/man.cgi?query=pciconf).

---

### Soluciones del Ejercicio 2

* **Pregunta 2.1: Respuesta correcta: B**
  * **Explicación:** El controlador periférico `pass(4)` en el subsistema CAM de FreeBSD expone dispositivos de caracteres de control de paso directo raw (`/dev/passX`). Esta interfaz permite que las utilidades de userland tales como `camcontrol`, `smartctl` y `cdrecord` envíen Bloques Descriptores de Comandos (CDBs) SCSI directos y comandos ATA Pass-Through a hardware de almacenamiento sin pasar a través de capas de bloques de nivel superior.
  * **Análisis de opciones incorrectas:**
    * La A es incorrecta: ZFS gestiona su propia capa de almacenamiento en caché SPA/ARC directamente sobre dispositivos de bloques (`da`, `ada`, `nda`).
    * La C es incorrecta: Los HBAs de hardware realizan la compresión de bus, no el controlador de dispositivo de paso directo por software.
    * La D es incorrecta: Los estados de energía ACPI son manejados por `acpi(4)`, no por `pass` de CAM.

* **Pregunta 2.2: Respuesta correcta: B**
  * **Explicación:** `atactl` es la utilidad nativa en NetBSD y OpenBSD utilizada para inspeccionar canales del controlador ATA, consultar atributos SMART y emitir comandos de identificación ATA (consulte la [OpenBSD atactl(8) Manual Page](https://man.openbsd.org/atactl.8)).
  * **Análisis de opciones incorrectas:**
    * La A es incorrecta: `camcontrol` es específico del subsistema CAM de FreeBSD.
    * La C es incorrecta: `kldload` gestiona los módulos del kernel de FreeBSD.
    * La D es incorrecta: `pciconf` se utiliza para la inspección de la configuración del bus PCI en FreeBSD.

---

### Soluciones del Ejercicio 3

* **Pregunta 3.1: Respuesta correcta: B**
  * **Explicación:** FreeBSD aplica límites de seguridad a través de `kern.securelevel`. En `securelevel = 1` (modo seguro) o `securelevel = 2` (modo altamente seguro), la descarga o carga de módulos del kernel utilizando `kldload(2)` / `kldunload(2)` está explícitamente denegada por la política de seguridad del sistema para prevenir la inyección de rootkits.
  * **Análisis de opciones incorrectas:**
    * La A es incorrecta: La llamada al sistema falla rotundamente; no se ejecuta con una advertencia.
    * La C es incorrecta: El kernel no entra en pánico ni se reinicia en modo RAMDISK (`bsd.rd`).
    * La D es incorrecta: Las utilidades de userland no pueden modificar `/boot/loader.conf` automáticamente tras una ejecución fallida.

* **Pregunta 3.2: Respuesta correcta: C**
  * **Explicación:** `/boot/loader.conf` es leído por la etapa 3 del cargador de arranque de FreeBSD (`loader(8)`). Le indica al cargador de arranque que cargue módulos específicos del kernel en la memoria y establezca parámetros de ajuste (tunables) de bajo nivel del kernel antes de cargar y lanzar `/boot/kernel/kernel`.
  * **Análisis de opciones incorrectas:**
    * La A es incorrecta: `/etc/rc.conf` configura los servicios del sistema e interfaces de red después de que se inicializa userland.
    * La B es incorrecta: `/etc/sysctl.conf` es analizado por `sysctl(8)` durante el inicio de arranque de userland (`rc.sysctl`), después de que el kernel se está ejecutando.
    * La D es incorrecta: `/etc/devd.conf` configura reglas de eventos para eventos de hot-plug del demonio de dispositivos de userland (`devd`).

---

### Soluciones del Ejercicio 4

* **Pregunta 4.1: Respuesta correcta: B**
  * **Explicación:** `/boot/loader.conf` se procesa temprano en la secuencia de arranque mediante el cargador de arranque (`loader(8)`), lo que le permite establecer parámetros del kernel de solo lectura, límites de asignación de memoria y cargar controladores de almacenamiento/red necesarios para sondear dispositivos. `/etc/sysctl.conf` se procesa mucho más tarde en el ciclo de arranque mediante scripts de inicio de userland (`rc`), modificando parámetros del kernel de escritura (nodos `sysctl`) mientras el sistema está operativo.
  * **Análisis de opciones incorrectas:**
    * La A es incorrecta: Secuencia invertida; `loader.conf` se evalúa *antes* de `init(8)`.
    * La C es incorrecta: `/boot/loader.conf` y `/etc/sysctl.conf` son archivos de configuración centrales de FreeBSD (`sysctl.conf` también se comparte en NetBSD/OpenBSD).
    * La D es incorrecta: `/etc/sysctl.conf` no controla señales físicas de hardware hot-plug PCI.

* **Pregunta 4.2: Respuesta correcta: D**
  * **Explicación:** Todas las URLs citadas proporcionan documentación oficial y fidedigna que cubre la configuración del kernel de FreeBSD, utilidades de carga de módulos y parámetros del cargador de arranque:
    * [FreeBSD Handbook: Kernel Configuration](https://docs.freebsd.org/en/books/handbook/kernelconfig/)
    * [FreeBSD kldload(8) Manual Page](https://man.freebsd.org/cgi/man.cgi?query=kldload)
    * [FreeBSD loader.conf(5) Manual Page](https://man.freebsd.org/cgi/man.cgi?query=loader.conf)

</details>