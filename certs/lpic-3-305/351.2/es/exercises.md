# 351.2 Xen — Ejercicios guiados

> **Examen:** LPIC-3 305-300 (v3.0) · **Tema 351.2 Xen** · **Peso 5**
> **Enfoque:** Xen 4.x, el toolstack `xl`/libxenlight, dominios PV y HVM, dispositivos virtuales, XenStore, parámetros de arranque, y conocimiento de `xm`/XAPI.

**Prerrequisitos del laboratorio**

- Un host físico (o una VM con capacidad de virtualización anidada y soporte de `hvm`) ejecutando un hipervisor Xen 4.x con un **Dom0** Linux (en las salidas de ejemplo se asume Debian 12 + `xen-hypervisor-amd64` y `xen-utils-4.17`).
- Privilegios de root en Dom0. Todos los comandos `xl`/`xenstore-*` de abajo se ejecutan **dentro de Dom0**.
- Un bridge llamado `xenbr0` y un grupo de volúmenes LVM `vg0` para los discos de los guests.
- Las salidas mostradas son representativas; los hostnames, IDs, UUIDs y tiempos diferirán en tu sistema.

Las fuentes se citan en línea y se consolidan al final.

---

## Ejercicio 1 — Confirmar Dom0 y leer la visión que el hipervisor tiene de la máquina

Xen es un **hipervisor de tipo 1 (bare-metal)**: arranca primero, luego inicia un dominio de control privilegiado, **Domain-0 (Dom0)**, que posee los drivers y el toolstack. Los guests no privilegiados son **DomU**. Tu primer trabajo en cualquier host Xen es demostrar que estás realmente *en* Dom0 y leer el inventario del hipervisor.

1. Confirmá que el kernel en ejecución ve un hipervisor Xen debajo de él:

   ```bash
   cat /sys/hypervisor/type
   ```
   ```
   xen
   ```

2. Confirmá que este es el **dominio de control** (Dom0 siempre es el domain ID 0):

   ```bash
   ls -d /proc/xen && cat /sys/hypervisor/properties/capabilities
   ```
   ```
   /proc/xen
   control_d
   ```
   La cadena `control_d` está presente solo en Dom0.

3. Pedile al hipervisor que describa el host físico y a sí mismo:

   ```bash
   xl info
   ```
   ```
   host                   : xen-node01
   release                : 6.1.0-18-amd64
   version                : #1 SMP PREEMPT_DYNAMIC Debian 6.1.76-1
   machine                : x86_64
   nr_cpus                : 8
   cores_per_socket       : 4
   threads_per_core       : 2
   cpu_mhz                : 3600.000
   virt_caps              : hvm hvm_directio
   total_memory           : 32611
   free_memory            : 27890
   xen_major              : 4
   xen_minor              : 17
   xen_version            : 4.17.3
   xen_caps               : xen-3.0-x86_64 hvm-3.0-x86_32 hvm-3.0-x86_32p hvm-3.0-x86_64
   xen_scheduler          : credit2
   xen_commandline        : placeholder dom0_mem=4096M,max:4096M dom0_max_vcpus=4 ...
   ```

4. Listá los dominios en ejecución:

   ```bash
   xl list
   ```
   ```
   Name                            ID   Mem VCPUs      State   Time(s)
   Domain-0                         0  4096     4     r-----     124.5
   ```

5. Leé el propio ring buffer de arranque del hipervisor (distinto del `dmesg` del kernel de Dom0):

   ```bash
   xl dmesg | head -n 20
   ```
   ```
   (XEN) Xen version 4.17.3 (Debian 4.17.3+10-...) ...
   (XEN) Latest ChangeSet: ...
   (XEN) Command line: placeholder dom0_mem=4096M,max:4096M dom0_max_vcpus=4 ...
   (XEN) Xen is relinquishing VGA console.
   ```

**Verificación de comprensión**

- **Q1.1** ¿Cómo distinguís, a partir de `/sys/hypervisor/`, que estás en Dom0 y no en un DomU ordinario?
- **Q1.2** En `xl info`, ¿qué te dice la línea `xen_caps` sobre qué *tipos* de guest puede ejecutar este host, y por qué importa antes de intentar iniciar un guest HVM?
- **Q1.3** ¿Por qué `xl dmesg` es información distinta del comando `dmesg` de Linux, y cuándo recurrirías a él?
- **Q1.4** En `xl list`, decodificá la entrada `r-----` de la columna State y nombrá otros tres flags de estado que podrías ver.

---

## Ejercicio 2 — Parámetros de arranque de Xen (hipervisor vs. kernel de Dom0)

En un sistema Xen el bootloader carga **dos** cosas: `xen.gz` (el hipervisor) y el `vmlinuz` de Dom0 (un kernel Linux normal). Cada uno toma líneas de comandos **separadas**. Confundirlas es una trampa clásica del examen: `dom0_mem` es un argumento del *hipervisor*, no un argumento del kernel.

1. Inspeccioná cómo GRUB ensambla las dos líneas de comandos en Debian/Ubuntu:

   ```bash
   grep -R "GRUB_CMDLINE_XEN\|GRUB_CMDLINE_LINUX" /etc/default/grub /etc/default/grub.d/ 2>/dev/null
   ```
   ```
   /etc/default/grub.d/xen.cfg:GRUB_CMDLINE_XEN_DEFAULT="dom0_mem=4096M,max:4096M dom0_max_vcpus=4 dom0_vcpus_pin"
   /etc/default/grub:GRUB_CMDLINE_LINUX_DEFAULT="quiet"
   ```
   - `GRUB_CMDLINE_XEN*` → argumentos para **`xen.gz`** (el hipervisor).
   - `GRUB_CMDLINE_LINUX*` → argumentos para el **kernel de Dom0**.

2. Fijá Dom0 a un tamaño de memoria y una cantidad de CPUs fijos (evita que la memoria de Dom0 haga ballooning, lo cual es una buena práctica en un hipervisor). Editá `/etc/default/grub.d/xen.cfg`:

   ```
   GRUB_CMDLINE_XEN_DEFAULT="dom0_mem=4096M,max:4096M dom0_max_vcpus=4 dom0_vcpus_pin loglvl=all guest_loglvl=all"
   ```

3. Regenerá la configuración de arranque e inspeccioná la estrofa `multiboot` generada:

   ```bash
   update-grub
   grep -A3 "multiboot" /boot/grub/grub.cfg | head -n 8
   ```
   ```
   multiboot   /boot/xen-4.17.gz placeholder dom0_mem=4096M,max:4096M dom0_max_vcpus=4 dom0_vcpus_pin loglvl=all guest_loglvl=all
   module      /boot/vmlinuz-6.1.0-18-amd64 placeholder root=/dev/mapper/vg0-root ro quiet
   module      /boot/initrd.img-6.1.0-18-amd64
   ```
   Notá la disposición: `multiboot` = hipervisor, primer `module` = kernel de Dom0, segundo `module` = initrd.

4. Después de un reinicio, verificá que el hipervisor realmente recibió tus argumentos (sin confiar en el archivo de configuración):

   ```bash
   xl info -n | grep xen_commandline
   grep -i "command line\|dom0_max_vcpus\|NR_CPUS" /var/log/xen/*.log 2>/dev/null
   ```
   ```
   xen_commandline        : placeholder dom0_mem=4096M,max:4096M dom0_max_vcpus=4 dom0_vcpus_pin loglvl=all guest_loglvl=all
   ```

**Verificación de comprensión**

- **Q2.1** Un colega agrega `dom0_mem=2G` a `GRUB_CMDLINE_LINUX_DEFAULT` y reinicia, pero Dom0 sigue haciendo ballooning. Explicá el error.
- **Q2.2** ¿Cuál es el propósito práctico de fijar Dom0 con `dom0_mem=…,max:…` y `dom0_max_vcpus` + `dom0_vcpus_pin` en un hipervisor de producción?
- **Q2.3** ¿Qué único comando prueba, en tiempo de ejecución, exactamente con qué parámetros arrancó el *hipervisor*?
- **Q2.4** En las líneas `multiboot`/`module`, ¿qué entrada es el hipervisor y cuál el kernel de Dom0?

---

## Ejercicio 3 — Definir y arrancar un DomU PV con `xl.cfg`

Un **DomU PV (paravirtualizado)** no tiene BIOS ni hardware emulados: el kernel del guest es consciente de Xen y se comunica con el hipervisor mediante hypercalls y drivers divididos (front-end/back-end). Sus discos aparecen como `xvdX` y su consola es `hvc0`.

1. Creá un disco de respaldo LVM para el guest:

   ```bash
   lvcreate -L 8G -n pv-guest01 vg0
   ```
   ```
   Logical volume "pv-guest01" created.
   ```

2. Escribí la configuración del dominio `/etc/xen/pv-guest01.cfg`. Esta usa `pygrub` para que se arranque el kernel *propio del guest* desde dentro de su imagen de disco:

   ```python
   # /etc/xen/pv-guest01.cfg
   name        = "pv-guest01"
   type        = "pvh"                     # Xen 4.x: "pv", "pvh", or "hvm"
   memory      = 1024
   maxmem      = 2048
   vcpus       = 2

   # Boot the kernel that lives inside the guest filesystem:
   bootloader  = "pygrub"

   vif  = [ 'bridge=xenbr0, mac=00:16:3e:1a:2b:01' ]
   disk = [ 'phy:/dev/vg0/pv-guest01,xvda,w' ]

   on_poweroff = "destroy"
   on_reboot   = "restart"
   on_crash    = "restart"
   ```

   > Para un guest PV verdaderamente clásico cuyo kernel vive en **Dom0**, en su lugar usarías `kernel=`, `ramdisk=`, y `extra="root=/dev/xvda1 ro console=hvc0"` y quitarías `bootloader`.

3. Iniciá el dominio y conectate a su consola en un solo paso (`-c`):

   ```bash
   xl create -c /etc/xen/pv-guest01.cfg
   ```
   ```
   Parsing config from /etc/xen/pv-guest01.cfg
   [    0.000000] Linux version 6.1.0-18-amd64 ...
   ...
   pv-guest01 login:
   ```
   Desconectate de la consola con **`Ctrl-]`** (esto deja el guest en ejecución).

4. Confirmá que el guest está levantado e inspeccionalo desde Dom0:

   ```bash
   xl list
   xl uptime pv-guest01
   ```
   ```
   Name                            ID   Mem VCPUs      State   Time(s)
   Domain-0                         0  4096     4     r-----     210.7
   pv-guest01                       1  1024     2     -b----      14.2

   Name                                ID   Uptime
   pv-guest01                           1   0 days,  0:02:41
   ```

5. Reconectate a la consola más tarde, luego realizá un apagado limpio estilo ACPI:

   ```bash
   xl console pv-guest01      # Ctrl-] to leave again
   xl shutdown pv-guest01     # graceful; xl destroy would be the hard power-off
   ```

**Verificación de comprensión**

- **Q3.1** ¿Por qué los discos de un guest PV aparecen como `xvda` y la consola como `hvc0` en lugar de `sda`/`ttyS0`?
- **Q3.2** ¿Cuál es la diferencia entre usar `bootloader = "pygrub"` y especificar `kernel=`/`ramdisk=` directamente en la configuración? ¿De dónde proviene el kernel en cada caso?
- **Q3.3** En la línea `disk` `'phy:/dev/vg0/pv-guest01,xvda,w'`, identificá los tres campos y el significado de `w`.
- **Q3.4** ¿Cuál es la diferencia operativa entre `xl shutdown` y `xl destroy`, y cuál arriesga la corrupción del filesystem?

---

## Ejercicio 4 — Definir y arrancar un DomU HVM

Un **DomU HVM (virtualizado por hardware)** usa extensiones de virtualización de CPU (Intel VT-x / AMD-V) más una plataforma emulada (device model de QEMU) para poder ejecutar sistemas operativos **sin modificar** — un Windows de fábrica o un kernel de distro sin soporte de Xen. Ve una BIOS emulada, discos IDE/SATA (`hda`/`sda`), y una pantalla VGA a la que accedés por VNC.

1. Creá el disco y colocá una ISO de instalación en su lugar:

   ```bash
   lvcreate -L 20G -n hvm-guest01 vg0
   ```

2. Escribí `/etc/xen/hvm-guest01.cfg`:

   ```python
   # /etc/xen/hvm-guest01.cfg
   name        = "hvm-guest01"
   type        = "hvm"                     # legacy syntax: builder = "hvm"
   memory      = 2048
   vcpus       = 2

   # Emulated NIC model + PV-aware NIC both work; e1000 is broadly compatible:
   vif  = [ 'bridge=xenbr0, model=e1000, mac=00:16:3e:1a:2b:02' ]
   disk = [ 'phy:/dev/vg0/hvm-guest01,hda,w',
            'file:/srv/iso/debian-12-netinst.iso,hdc:cdrom,r' ]

   boot        = "dc"                      # try disk (d) then CD-ROM (c)
   vnc         = 1
   vnclisten   = "127.0.0.1"
   vncdisplay  = 0                         # → TCP 5900
   serial      = "pty"
   ```

3. Inicialo (sin `-c`: los guests HVM arrancan una consola gráfica, no una serial por defecto):

   ```bash
   xl create /etc/xen/hvm-guest01.cfg
   xl list
   ```
   ```
   Name                            ID   Mem VCPUs      State   Time(s)
   Domain-0                         0  4096     4     r-----     305.1
   pv-guest01                       1  1024     2     -b----      45.0
   hvm-guest01                      2  2048     2     r-----       6.4
   ```

4. Encontrá y conectate a su consola VNC. Xen también registra el puerto VNC en XenStore:

   ```bash
   xl vncviewer hvm-guest01            # or: vncviewer 127.0.0.1:0
   xenstore-read /local/domain/2/console/vnc-port
   ```
   ```
   5900
   ```

5. Confirmá que el guest usa el device model de QEMU (un proceso de espacio de usuario en Dom0, uno por cada dominio HVM):

   ```bash
   pgrep -af "qemu.*hvm-guest01"
   ```
   ```
   4821 /usr/lib/xen-4.17/bin/qemu-system-i386 -xen-domid 2 -name hvm-guest01 ...
   ```

**Verificación de comprensión**

- **Q4.1** Nombrá dos campos de `xl info` que revisarías *antes* de intentar ejecutar un guest HVM, y qué valores necesitás.
- **Q4.2** ¿Por qué un guest HVM necesita un proceso QEMU por dominio en Dom0 mientras que un guest PV puro no?
- **Q4.3** En la configuración HVM, ¿por qué el disco se expone como `hda` (no `xvda`), y qué hace `boot = "dc"`?
- **Q4.4** ¿Qué es un guest "PV-on-HVM" (o PVHVM), y por qué usualmente se prefiere sobre HVM puro para un guest Linux moderno?

---

## Ejercicio 5 — Dispositivos virtuales de red y almacenamiento (inspeccionar y hot-plug)

Xen presenta a los guests **dispositivos virtuales de red (`vif`)** y **dispositivos virtuales de bloque/almacenamiento (`vbd`)** implementados como split drivers: un back-end en Dom0 y un front-end en el guest, comunicándose a través de rings de memoria compartida anunciados en XenStore.

1. Enumerá los dispositivos virtuales de un guest en ejecución desde Dom0:

   ```bash
   xl network-list pv-guest01
   xl block-list   pv-guest01
   ```
   ```
   Idx BE Mac Addr.          handle state evt-ch   tx-/rx-ring-ref BE-path
   0   0  00:16:3e:1a:2b:01  0      4     14       768/769         /local/domain/0/backend/vif/1/0

   Vdev  BE  handle state evt-ch ring-ref BE-path
   51712 0   1      4     11     8        /local/domain/0/backend/vbd/1/51712
   ```
   `Vdev 51712` es el número codificado para `xvda` (ver Q5.2).

2. Confirmá que la interfaz back-end de Dom0 existe y está esclavizada al bridge:

   ```bash
   ip link show | grep -i "vif1\|xenbr0"
   bridge link
   ```
   ```
   7: vif1.0@if2: <BROADCAST,MULTICAST,UP,LOWER_UP> master xenbr0 state UP ...
   ```

3. **Hot-attach** de una segunda interfaz de red al guest en ejecución, verificá, luego desconectala:

   ```bash
   xl network-attach pv-guest01 'bridge=xenbr0, mac=00:16:3e:1a:2b:99'
   xl network-list  pv-guest01
   xl network-detach pv-guest01 1        # detach vif idx 1
   ```

4. **Hot-attach** de un disco extra al guest en ejecución y desconectalo:

   ```bash
   lvcreate -L 4G -n pv-guest01-data vg0
   xl block-attach pv-guest01 'phy:/dev/vg0/pv-guest01-data,xvdb,w'
   xl block-list   pv-guest01
   xl block-detach pv-guest01 xvdb
   ```

5. Ajustá en vivo los recursos del guest (balloon de memoria, agregar/quitar una vCPU) — todo online, sin reinicio:

   ```bash
   xl mem-set  pv-guest01 1536m      # within maxmem set in the config
   xl vcpu-set pv-guest01 3
   xl vcpu-list pv-guest01
   ```
   ```
   Name          ID  VCPU   CPU State   Time(s) Affinity (Hard / Soft)
   pv-guest01     1     0     4   -b-      20.1  all / all
   pv-guest01     1     1     6   -b-      18.7  all / all
   pv-guest01     1     2     0   --p       0.0  all / all
   ```

**Verificación de comprensión**

- **Q5.1** En el modelo de split-driver, ¿dónde vive el *back-end* de un `vif` y dónde vive el *front-end*?
- **Q5.2** `xl block-list` muestra `Vdev 51712` para `xvda`. Usando la codificación `(202 << 8) + minor` para el major 202 de `xvd`, verificá que 51712 corresponde a `xvda`. ¿Cuál sería `xvdb`?
- **Q5.3** ¿Por qué `xl mem-set pv-guest01 1536m` puede tener éxito mientras `xl mem-set pv-guest01 4096m` falla, dada la configuración del Ejercicio 3?
- **Q5.4** Después de `xl network-attach`, el lado de Dom0 muestra una interfaz como `vif1.1`. Decodificá ese nombre.

---

## Ejercicio 6 — XenStore: la base de datos compartida de configuración y estado

**XenStore** es una pequeña base de datos clave/valor jerárquica y transaccional mantenida por el hipervisor/Dom0 (`xenstored`) y compartida con cada dominio. El toolstack, los drivers back-end y front-end, y las herramientas de gestión se encuentran todos a través de ella. *No* es un datastore general — contiene configuración de dispositivos, estado de ejecución y claves de control.

1. Listá el árbol de nivel superior y el subárbol por dominio:

   ```bash
   xenstore-ls /local/domain
   ```
   ```
   0 = ""
    name = "Domain-0"
    domid = "0"
    backend = ""
     vif = ""
      1 = ""
       0 = "..."
   1 = ""
    name = "pv-guest01"
    domid = "1"
    vm = "/vm/6f9a...-..."
    device = ""
     vbd = ""
      51712 = "..."
     vif = ""
      0 = "..."
   ```

2. Leé claves individuales (nota: las rutas usan el **ID** del dominio, no el nombre):

   ```bash
   xenstore-read /local/domain/1/name
   xenstore-read /local/domain/1/memory/target
   xenstore-list /local/domain/1/device
   ```
   ```
   pv-guest01
   1572864
   vbd
   vif
   ```
   `memory/target` está en KiB → 1572864 KiB = 1536 MiB, coincidiendo con el `xl mem-set` del Ejercicio 5.

3. Seguí el handshake front-end/back-end de un guest. La clave **state** es un entero de la máquina de estados de XenBus (`1=Initialising`, `4=Connected`, `6=Closed`):

   ```bash
   xenstore-read /local/domain/1/device/vbd/51712/state
   xenstore-read /local/domain/0/backend/vbd/1/51712/state
   ```
   ```
   4
   4
   ```
   Ambos en `4` (Connected) significa que el split driver está completamente conectado.

4. Escribí y eliminá una clave de prueba (entendé que es un plano de control en vivo, así que tené cuidado con las claves reales):

   ```bash
   xenstore-write   /local/domain/1/data/note "lab-6-marker"
   xenstore-read    /local/domain/1/data/note
   xenstore-rm      /local/domain/1/data/note
   ```

**Verificación de comprensión**

- **Q6.1** Nombrá tres *clases* distintas de información que Xen mantiene en XenStore. ¿Qué se supone que explícitamente *no* debe almacenar?
- **Q6.2** Un `vif` muestra estado front-end `4` pero estado back-end `2`. ¿Qué te dice esa discrepancia sobre el dispositivo, y cómo se llama el estado `4`?
- **Q6.3** Las rutas de XenStore están indexadas por el ID numérico del dominio. ¿Por qué eso es un peligro sutil al programar scripts contra un guest a través de un reinicio/migración?
- **Q6.4** ¿Qué daemon sirve XenStore, y cómo accede a él un DomU recién arrancado sin una red?

---

## Ejercicio 7 — Conocimiento del toolstack: `xl` vs. `xm`, XAPI/`xe`, `xl.conf`, y migración

Xen ha tenido varios toolstacks. El examen espera que **reconozcas** cada uno y sepas cuál es el predeterminado actual.

1. Inspeccioná la configuración **global** de `xl` (predeterminados aplicados a cada dominio), `/etc/xen/xl.conf`:

   ```bash
   grep -vE '^\s*#|^\s*$' /etc/xen/xl.conf
   ```
   ```
   autoballoon="auto"
   vif.default.script="vif-bridge"
   vif.default.bridge="xenbr0"
   ```
   > Contrastá las tres capas de configuración: `xl.conf` = predeterminados a nivel de todo el toolstack; `xl.cfg` = la definición de un único dominio; `xen-command-line` = los propios parámetros de arranque del hipervisor (Ejercicio 2).

2. Reconocé el toolstack **obsoleto** `xm`/`xend`. En un host moderno ya no existe; la página de manual todavía describe la migración:

   ```bash
   which xm xl xe 2>/dev/null
   ```
   ```
   /usr/sbin/xl
   ```
   `xm` (el viejo toolstack basado en `xend` y Python) fue **declarado obsoleto en Xen 4.1 y removido después de 4.4**; `xl` (libxenlight/libxl, sin daemon) es el predeterminado hoy. Los comandos se mapean casi 1:1 (`xm list` → `xl list`, `xm create` → `xl create`).

3. Reconocé el toolstack **XAPI** y su CLI `xe` (usado por XenServer / XCP-ng, *no* instalado en un host Xen Debian simple). Sus hechos a nivel de conocimiento:
   - `xapi` es un daemon con su propia base de datos de metadatos similar a PostgreSQL y un concepto de pool.
   - Gestionás las VMs con `xe`, p. ej. `xe vm-list`, `xe host-list`, `xe vm-start uuid=<uuid>`.
   - Superpone un modelo de pool de recursos + repositorio de almacenamiento sobre el mismo hipervisor Xen.

4. Practicá las operaciones que mueven o hacen checkpoint de un dominio con `xl` (requiere almacenamiento compartido para migración en vivo; save/restore es local):

   ```bash
   # Local checkpoint to a file, then restore:
   xl save    pv-guest01 /var/lib/xen/save/pv-guest01.chk
   xl list                                   # pv-guest01 no longer listed
   xl restore /var/lib/xen/save/pv-guest01.chk

   # Live migration to a peer node (shared LVM/iSCSI + xl on both ends):
   xl migrate pv-guest01 xen-node02
   ```
   ```
   Saving to /var/lib/xen/save/pv-guest01.chk new xl format (info 0x3/0x0/1300)
   ...
   migration target: Ready to receive domain.
   Loading new save file ... done
   Domain 1 has shut off, reason code 3
   Migration successful.
   ```

**Verificación de comprensión**

- **Q7.1** Ordená los tres ámbitos de configuración e indicá qué archivo controla cuál: opciones de arranque del hipervisor, definición por dominio, predeterminados a nivel de todo el toolstack.
- **Q7.2** ¿Qué reemplazó a `xm`/`xend`, y cuál es la mayor diferencia arquitectónica (pista: un daemon)?
- **Q7.3** Tanto `xe` como `xl` inician VMs en Xen. ¿A qué capa pertenece `xe`, y en qué familia de productos lo encontrarías realmente?
- **Q7.4** ¿Qué debe ser verdad del *almacenamiento* para que `xl migrate <dom> <host>` sea una migración en vivo y no un fallo?

---

## Respuestas

<details>
<summary>Hacé clic para revelar las respuestas de todos los ejercicios</summary>

### Ejercicio 1
- **A1.1** `/sys/hypervisor/type` devuelve `xen` en cualquier dominio, PV o HVM; lo que prueba que estás en **Dom0** es que `/sys/hypervisor/properties/capabilities` contenga `control_d` (y la presencia de `/proc/xen` con el toolstack). Solo el dominio de control lleva la capacidad `control_d` y puede manejar `xl`. `xl list` también siempre muestra a Dom0 como `ID 0`.
- **A1.2** `xen_caps` enumera las ABIs de guest para las que se compiló el hipervisor: `xen-3.0-x86_64` (guests PV) y las entradas `hvm-3.0-*` (guests HVM). Si no estuviera presente ninguna capacidad `hvm-*` — o `virt_caps` careciera de `hvm` — la CPU/el hipervisor no podría ejecutar guests HVM, y `xl create` sobre una configuración HVM fallaría. Por eso lo revisás antes del Ejercicio 4.
- **A1.3** `xl dmesg` imprime el ring buffer del **hipervisor** (`xen.gz`) — mensajes de CPU/microcódigo/IOMMU/scheduler emitidos antes y por debajo de Linux — con el prefijo `(XEN)`. El comando `dmesg` simple muestra solo el log del **kernel Linux de Dom0**. Recurrís a `xl dmesg` para depurar passthrough de hardware, IOMMU, el parseo de parámetros de arranque, o panics del hipervisor.
- **A1.4** `r-----` = **running** (en ejecución). Las seis posiciones de flag son `r` running, `b` blocked (inactivo/esperando I/O — normal para un guest mayormente inactivo), `p` paused, `s` shutdown, `c` crashed, `d` dying. (Cualquiera de tres entre blocked/paused/shutdown/crashed/dying es correcto.)

### Ejercicio 2
- **A2.1** `dom0_mem` es un parámetro del **hipervisor** y debe ir en `GRUB_CMDLINE_XEN*` (la línea `multiboot`/`xen.gz`). Ponerlo en `GRUB_CMDLINE_LINUX*` lo pasa al *kernel* de Dom0, que lo ignora, así que el hipervisor sigue haciendo auto-ballooning de Dom0.
- **A2.2** Le da a Dom0 una huella **fija y predecible**. `dom0_mem=X,max:X` deshabilita el auto-ballooning de Dom0 para que la presión de memoria de los guests no pueda encoger/agrandar el dominio de control (lo cual perjudica la latencia de drivers/back-end y puede provocar un deadlock). `dom0_max_vcpus` + `dom0_vcpus_pin` reservan/fijan CPUs para Dom0 para que el I/O de back-end no sea privado de recursos por guests ocupados — higiene estándar de producción.
- **A2.3** `xl info` → el campo `xen_commandline` (equivalentemente `xl dmesg | grep "Command line"`). Reporta con qué arrancó *realmente* el hipervisor, independientemente de lo que la configuración de GRUB diga ahora.
- **A2.4** `multiboot /boot/xen-4.17.gz …` = el **hipervisor**; el primer `module /boot/vmlinuz-… …` = el **kernel de Dom0**; el segundo `module /boot/initrd.img-…` = el initrd de Dom0.

### Ejercicio 3
- **A3.1** Un guest PV usa **drivers front-end paravirtuales** de Xen, no hardware emulado. El front-end de bloque de Xen registra los discos bajo el major de bloque `xvd` (202) → `xvda`, y el front-end de consola registra una consola virtual del hipervisor → `hvc0`. No hay controlador IDE/SATA emulado ni UART 8250 para producir `sda`/`ttyS0`.
- **A3.2** Con `kernel=`/`ramdisk=`, el kernel y el initrd son archivos en **Dom0** y el hipervisor los carga directamente — Dom0 controla el kernel del guest. Con `bootloader = "pygrub"`, Xen ejecuta una emulación de bootloader que lee el `/boot` **propio del guest** (y la configuración de grub) desde dentro de su imagen de disco y arranca el kernel encontrado ahí — el guest controla su kernel, como una máquina normal.
- **A3.3** Formato `<protocol>:<path>,<vdev>,<mode>`: `phy` = un back-end de dispositivo de bloque físico, `/dev/vg0/pv-guest01` = el dispositivo de respaldo en Dom0, `xvda` = el nombre de dispositivo virtual visto por el guest, `w` = lectura-escritura (`r` sería solo lectura).
- **A3.4** `xl shutdown` envía una solicitud de apagado ordenado (control PV / ACPI para HVM), permitiendo que el SO del guest desmonte y sincronice — seguro. `xl destroy` desasigna el dominio inmediatamente (equivalente a arrancar el cable de alimentación), lo cual **puede corromper** el filesystem del guest. Usá `destroy` solo cuando el guest está colgado.

### Ejercicio 4
- **A4.1** `virt_caps` debe contener `hvm` (VT-x/AMD-V de la CPU habilitado en el firmware y expuesto a Xen) y `xen_caps` debe listar una ABI `hvm-3.0-*`. (Para passthrough de dispositivos, adicionalmente querrías `hvm_directio` / IOMMU.)
- **A4.2** Un guest HVM ejecuta un SO **sin modificar** que espera hardware real — una BIOS/UEFI, IDE/SATA, VGA, timers, NICs. Xen emula esa plataforma con un **device model de QEMU** ejecutándose como un proceso de espacio de usuario en Dom0, uno por cada dominio HVM. Un guest PV puro es consciente de Xen y usa solo hypercalls + split drivers, así que no se requiere plataforma emulada (ni QEMU).
- **A4.3** El firmware HVM arranca como una PC física, así que los discos se presentan a través de un controlador IDE/SATA emulado → `hda`/`sda`, no el nodo PV `xvd`. `boot = "dc"` fija el orden de arranque de la BIOS para probar primero el **d**isco (disk), luego el **c**D-ROM (`"cd"` lo invertiría, útil durante la instalación del SO).
- **A4.4** Un guest **PVHVM** (PV-on-HVM) arranca como HVM (así que no necesita un kernel especial y obtiene virtualización de CPU HVM rápida) pero luego carga **drivers PV** de Xen para disco y red, evitando la lenta emulación de QEMU para el I/O. Combina la compatibilidad de HVM con un rendimiento de I/O cercano al de PV — la mejor opción usual para Linux moderno.

### Ejercicio 5
- **A5.1** El driver **back-end** vive en **Dom0** (p. ej. `xen-blkback`/`xen-netback`, exponiendo interfaces `vifX.Y` y conectándolas al bridge/almacenamiento). El driver **front-end** (`xen-blkfront`/`xen-netfront`) vive en el **guest**, presentando `xvdX`/`ethX`. Comparten rings de memoria anunciados vía XenStore.
- **A5.2** `xvd` usa el major de bloque 202. `202 << 8 = 51712`; sumá el minor `0` para el disco completo `xvda` → `51712`. Así que `Vdev 51712` = `xvda`. `xvdb` = minor 16 → `51712 + 16 = 51728`.
- **A5.3** La configuración fijó `maxmem = 2048`. `xl mem-set` puede hacer ballooning del guest **hasta `maxmem`** pero no más allá, porque las tablas de páginas del guest se dimensionaron para `maxmem` en el arranque. `1536m` ≤ 2048, así que tiene éxito; `4096m` > 2048, así que falla.
- **A5.4** `vif1.1` = la interfaz back-end de Dom0 para el **domain ID 1**, NIC virtual **índice 1** (el segundo `vif`). Forma general `vif<domid>.<devid>`.

### Ejercicio 6
- **A6.1** Cualquiera de tres entre: **configuración de dispositivos** (ring refs de front/back-end, event channels, MACs, parámetros de disco), **estado de ejecución / control** (`memory/target`, `control/shutdown`, valores de la máquina de `state` de dispositivos), **metadatos del dominio** (`name`, `domid`, ruta UUID de `vm`), y **mensajería guest↔herramientas** (p. ej. objetivos de balloon, puerto VNC). **No** es un almacén de propósito general ni de grandes datos — solo pertenecen ahí pequeñas claves de control/estado.
- **A6.2** El dispositivo **no está completamente conectado**: el front-end reporta `4` (**Connected**) pero el back-end `2` (**InitWait**), así que el back-end todavía está esperando/inicializando — el handshake del split driver está incompleto, lo que se manifiesta como un dispositivo del guest que nunca aparece o se cuelga. El estado `4` se llama *Connected* en la máquina de estados de XenBus.
- **A6.3** El **ID del dominio cambia** cada vez que se crea un dominio (cada `xl create`, y tras save/restore o migración el dominio obtiene un nuevo ID). Un script que codifica de forma fija `/local/domain/1/...` leerá silenciosamente el dominio equivocado (o uno inexistente) después de un reinicio/migración; deberías resolver primero el ID actual por nombre.
- **A6.4** `xenstored` (ejecutándose en Dom0, u `oxenstored`) lo sirve. Un DomU en arranque alcanza XenStore a través de una **página de memoria compartida + event channel** configurada por el toolstack en la creación del dominio — sin red, sin filesystem necesarios; los drivers front-end la usan para descubrir sus back-ends.

### Ejercicio 7
- **A7.1** De lo más bajo/temprano a lo por-VM: **(1) opciones de arranque del hipervisor** → el `xen-command-line` en la línea `multiboot` de GRUB (`GRUB_CMDLINE_XEN`); **(2) predeterminados a nivel de todo el toolstack** → `/etc/xen/xl.conf`; **(3) definición por dominio** → el `/etc/xen/<name>.cfg` individual (formato `xl.cfg`). Los ámbitos más estrechos anulan los predeterminados más amplios.
- **A7.2** `xl` (libxenlight/`libxl`) reemplazó a `xm`. La mayor diferencia: `xm` requería un **daemon** de gestión persistente, **`xend`** (Python), mientras que `xl` es **sin daemon** — enlaza `libxl` y se comunica con el hipervisor/XenStore directamente, lo cual es más simple y robusto.
- **A7.3** `xe` es la CLI del toolstack **XAPI** (una capa de gestión de más alto nivel con un daemon, base de datos de metadatos, pools de recursos y repositorios de almacenamiento). Lo encontrás en **XenServer / Citrix Hypervisor / XCP-ng**, no en un host Xen Debian upstream simple, que trae `xl`.
- **A7.4** El/los disco(s) del guest deben estar en **almacenamiento accesible desde ambos hosts** (LVM compartido sobre iSCSI/FC, NFS, etc.) para que el destino pueda acceder exactamente al mismo dispositivo de respaldo. `xl` migra el estado de CPU/memoria, no el contenido del disco; sin almacenamiento compartido el destino no tiene disco y la migración falla (o requiere una copia de almacenamiento separada/`--live` con mirroring).

</details>

---

### Fuentes

- LPI — Objetivos del examen 305-300, Tema 351.2: <https://www.lpi.org/our-certifications/exam-305-objectives/>
- Xen Project Wiki — *Xen Project Software Overview* / arquitectura (Dom0, DomU, PV/HVM/PVH): <https://wiki.xenproject.org/wiki/Xen_Project_Software_Overview>
- manual `xl(1)` (comandos del toolstack): <https://xenbits.xen.org/docs/unstable/man/xl.1.html>
- manual `xl.cfg(5)` (sintaxis de configuración del dominio): <https://xenbits.xen.org/docs/unstable/man/xl.cfg.5.html>
- manual `xl.conf(5)` (configuración global del toolstack): <https://xenbits.xen.org/docs/unstable/man/xl.conf.5.html>
- Parámetros de arranque del hipervisor Xen (`xen-command-line`): <https://xenbits.xen.org/docs/unstable/misc/xen-command-line.html>
- Xen Project Wiki — *XenStore* (estructura y estados de dispositivo de XenBus): <https://wiki.xenproject.org/wiki/XenStore>
- Xen Project Wiki — *XL* (y la obsolescencia de `xm`/`xend`): <https://wiki.xenproject.org/wiki/XL>