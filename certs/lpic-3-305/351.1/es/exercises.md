# 351.1 Conceptos y teoría de virtualización — Ejercicios guiados

> **Examen:** LPIC-3 305-300 (Virtualización y contenerización), versión 3.0 — Tema 351.1 (peso 10)
> **Fuente de objetivos:** Objetivos del examen 305 de LPI — https://www.lpi.org/our-certifications/exam-305-objectives/
>
> **Qué necesitás.** Un host Linux (Debian/Ubuntu o una distribución de la familia RHEL) con `sudo`. La mayoría de los pasos son inspección de solo lectura y son seguros de ejecutar en cualquier máquina, incluida una laptop o una VM existente. Los pasos que crean un guest, un snapshot o migran necesitan `qemu-kvm`, `libvirt` y `virtinst` instalados y están claramente marcados; ejecutalos en un host de laboratorio, no en producción.
> **Sugerencias de paquetes.** Debian/Ubuntu: `sudo apt install qemu-kvm libvirt-daemon-system virtinst libguestfs-tools cpu-checker virt-what open-vswitch-switch`. RHEL/Fedora: `sudo dnf install qemu-kvm libvirt virt-install libguestfs-tools-c virt-what openvswitch`.
> **Convención.** Los bloques de salida están etiquetados como *salida de ejemplo* — los valores exactos (cantidad de núcleos, UUID, direcciones) diferirán en tu máquina. Leelos para aprender qué *significa* un campo, no para replicarlos byte por byte.

---

## Ejercicio 1 — Detectar el soporte de virtualización por hardware con flags de CPU y `/proc/cpuinfo`

**Objetivo:** determinar si la CPU física ofrece virtualización asistida por hardware (Intel VT-x / AMD-V), y si están presentes los extras que la hacen rápida (SLAT).

1. Mirá los flags crudos por núcleo que exporta el kernel. Cada CPU lógica es una estrofa en `/proc/cpuinfo`; la línea `flags` lista los bits de características de CPUID:

   ```bash
   grep -m1 -o -E 'vmx|svm' /proc/cpuinfo
   ```

   *Salida de ejemplo (Intel):*
   ```
   vmx
   ```
   `vmx` = Intel VT-x. En una CPU AMD verías en cambio `svm` (AMD-V, "Secure Virtual Machine").

2. Contá cuántas CPU lógicas exponen la extensión (debería igualar la cantidad de hilos de tu CPU si el soporte está habilitado en el firmware):

   ```bash
   grep -c -E 'vmx|svm' /proc/cpuinfo
   ```
   *Salida de ejemplo:*
   ```
   8
   ```

3. Verificá la presencia de **Second Level Address Translation (SLAT)** — la virtualización de la MMU por hardware que elimina la sobrecarga de las shadow page tables. Intel la llama EPT, AMD la llama NPT (`npt`) / RVI:

   ```bash
   grep -m1 -o -E 'ept|npt' /proc/cpuinfo
   ```
   *Salida de ejemplo (Intel):*
   ```
   ept
   ```

4. Obtené la misma información ya digerida por `lscpu`, que lee CPUID por vos:

   ```bash
   lscpu | grep -Ei 'virtual|hypervisor|model name'
   ```
   *Salida de ejemplo en bare metal:*
   ```
   Model name:            Intel(R) Core(TM) i7-9700 CPU @ 3.00GHz
   Virtualization:        VT-x
   ```

5. En Debian/Ubuntu, confirmá directamente que KVM es utilizable (del paquete `cpu-checker`):

   ```bash
   sudo kvm-ok
   ```
   *Salida de ejemplo cuando es utilizable:*
   ```
   INFO: /dev/kvm exists
   KVM acceleration can be used
   ```
   *Salida de ejemplo cuando falta el flag o está deshabilitado en el firmware:*
   ```
   INFO: Your CPU does not support KVM extensions
   KVM acceleration can NOT be used
   ```

> **Punto de control 1**
> - **Q1.1** Un colega ejecuta `grep -c vmx /proc/cpuinfo` en un servidor AMD EPYC y obtiene `0`, y concluye que el servidor "no puede virtualizar". ¿Por qué la conclusión es incorrecta, y qué debería buscar con grep en su lugar?
> - **Q1.2** `lscpu` reporta `Virtualization: VT-x`, pero `kvm-ok` dice que KVM *no* puede usarse y `/proc/cpuinfo` **no** muestra el flag `vmx`. ¿Qué única causa, la más probable, explica las tres observaciones a la vez, y dónde la corregís?
> - **Q1.3** ¿Qué te aporta en tiempo de ejecución la presencia de `ept` (o `npt`), y qué mecanismo de software más lento reemplaza?

---

## Ejercicio 2 — Identificar si *vos* sos un guest, y bajo qué hipervisor

**Objetivo:** desde dentro de un sistema en ejecución, decidir si es bare metal o una VM, y nombrar el hipervisor. Es un paso rutinario de triage de SRE.

1. La señal más rápida: la CPU de un guest casi siempre lleva el flag de característica `hypervisor`, que las CPU de bare metal **no** activan:

   ```bash
   grep -o hypervisor /proc/cpuinfo | head -1
   ```
   *Salida de ejemplo dentro de una VM:*
   ```
   hypervisor
   ```
   Sin salida → muy probablemente bare metal.

2. Preguntale a systemd, que inspecciona CPUID, DMI/SMBIOS y otras pistas e imprime un id canónico:

   ```bash
   systemd-detect-virt
   ```
   *Salidas de ejemplo:* `kvm`, `qemu`, `xen`, `microsoft` (Hyper-V), `vmware`, `oracle` (VirtualBox), o `none` en bare metal.
   Su código de salida es `0` cuando se detecta virtualización y distinto de cero cuando imprime `none`, así que se puede usar en scripts limpiamente:

   ```bash
   systemd-detect-virt -q && echo "This is virtualized" || echo "Bare metal"
   ```

3. Distinguí una VM completa de un contenedor con la misma herramienta:

   ```bash
   systemd-detect-virt --vm
   systemd-detect-virt --container
   ```
   Dentro de un guest KVM el primero imprime `kvm` y el segundo imprime `none`; dentro de un contenedor Docker/LXC es al revés.

4. Cruzá la información con `virt-what`, que puede reportar **varios** hechos verdaderos a la vez (puede imprimir tanto el hipervisor como la plataforma):

   ```bash
   sudo virt-what
   ```
   *Salida de ejemplo dentro de un guest KVM en un host Red Hat:*
   ```
   kvm
   ```

5. Mirá la identidad del firmware emulado, que delata el modelo de dispositivos del hipervisor:

   ```bash
   sudo dmidecode -s system-manufacturer
   sudo dmidecode -s system-product-name
   ```
   *Salida de ejemplo bajo QEMU/KVM:*
   ```
   QEMU
   Standard PC (Q35 + ICH9, 2009)
   ```
   VirtualBox reporta `innotek GmbH` / `VirtualBox`; VMware reporta `VMware, Inc.`.

> **Punto de control 2**
> - **Q2.1** En un host, `systemd-detect-virt` imprime `none` pero `virt-what` imprime dos líneas: `xen` y `xen-dom0`. ¿Es esta máquina un guest? Explicá qué significa `xen-dom0`.
> - **Q2.2** Estás dentro de un contenedor LXC que corre sobre una VM KVM que corre sobre un host físico. ¿Qué reportará `systemd-detect-virt` (sin flags), y por qué reporta una sola cosa?
> - **Q2.3** ¿Por qué el flag de CPU `hypervisor` es una *heurística* y no una prueba — dá un caso donde puede estar ausente dentro de una VM y uno donde confiar solo en él te dejaría igualmente con dudas.

---

## Ejercicio 3 — Taxonomía de hipervisores y el stack KVM / QEMU / libvirt

**Objetivo:** mapear la distinción Tipo 1 vs Tipo 2 sobre las herramientas de Linux, e inspeccionar los módulos que convierten un kernel Linux en un hipervisor.

1. Confirmá que los módulos del kernel de KVM están cargados. `kvm` es el núcleo neutral respecto de la arquitectura; `kvm_intel` o `kvm_amd` es el backend del fabricante:

   ```bash
   lsmod | grep -E '^kvm'
   ```
   *Salida de ejemplo:*
   ```
   kvm_intel             380928  0
   kvm                  1146880  1 kvm_intel
   ```

2. Verificá el dispositivo de control que el hipervisor expone al espacio de usuario:

   ```bash
   ls -l /dev/kvm
   ```
   *Salida de ejemplo:*
   ```
   crw-rw----+ 1 root kvm 10, 232 Aug 11 09:14 /dev/kvm
   ```
   QEMU (espacio de usuario) abre este dispositivo de caracteres y emite `ioctl()` para ejecutar las vCPU del guest en la CPU física a través de KVM (kernel). Esa división es toda la arquitectura: **QEMU provee el modelo de dispositivos y la E/S; KVM provee la virtualización de CPU/memoria.**

3. Comprobá si la **virtualización anidada** (ejecutar un hipervisor dentro de un guest) está habilitada:

   ```bash
   cat /sys/module/kvm_intel/parameters/nested   # or kvm_amd
   ```
   *Salida de ejemplo:* `Y` (o `1`). Para habilitarla de forma persistente definirías `options kvm_intel nested=1` en `/etc/modprobe.d/` y recargarías el módulo.

4. Preguntale a libvirt qué puede ejecutar este host. `virsh capabilities` devuelve una descripción XML de la arquitectura del host y de los tipos de dominio de guest soportados:

   ```bash
   sudo virsh capabilities | grep -E "<arch|domain type" | head
   ```
   *Salida de ejemplo:*
   ```
     <arch name='x86_64'>
       <domain type='qemu'/>
       <domain type='kvm'/>
   ```
   `domain type='kvm'` presente ⇒ hay aceleración por hardware disponible; solo `qemu` ⇒ recaerías en emulación pura.

5. Inspeccioná un conjunto concreto de capacidades de guest (acelerador, tipos de máquina, firmware):

   ```bash
   sudo virsh domcapabilities | grep -E "domain|machine|path" | head
   ```

> **Punto de control 3**
> - **Q3.1** KVM es un módulo del kernel dentro de un SO Linux de propósito general y, sin embargo, suele clasificarse como hipervisor *Tipo 1 (bare-metal)*, mientras que VirtualBox sobre el mismo Linux es *Tipo 2 (hosted)*. Justificá la clasificación de cada uno.
> - **Q3.2** En el modelo de KVM, ¿qué componente ejecuta las instrucciones de ring-0 del guest en la CPU física, y qué componente emula el disco y las placas de red del guest? Nombrá ambos.
> - **Q3.3** Tenés que ejecutar un guest KVM *dentro* de una VM de nube existente. ¿Qué único archivo/parámetro debe leer `Y`, en qué capa (guest o host), para que eso sea posible?

---

## Ejercicio 4 — Virtualización completa (HVM), paravirtualización (PV) y `virtio`

**Objetivo:** entender la distinción HVM vs PV, mapear el vocabulario de Xen, y ver la E/S paravirtualizada (`virtio`) en acción desde dentro de un guest.

1. *(Ejecutar dentro de un guest KVM/QEMU.)* Listá los dispositivos PCI y fijate en los paravirtualizados. Los dispositivos `virtio` se identifican con el fabricante **Red Hat, Inc.**:

   ```bash
   lspci | grep -i virtio
   ```
   *Salida de ejemplo:*
   ```
   00:04.0 SCSI storage controller: Red Hat, Inc. Virtio block device
   00:05.0 Ethernet controller: Red Hat, Inc. Virtio network device
   00:06.0 Unclassified device: Red Hat, Inc. Virtio memory balloon
   ```

2. Confirmá que el kernel del guest enlazó los drivers paravirtuales:

   ```bash
   lsmod | grep -E 'virtio'
   ```
   *Salida de ejemplo:*
   ```
   virtio_net             57344  0
   virtio_blk             20480  3
   virtio_balloon         24576  0
   virtio_pci             28672  0
   ```
   Contrastá esto con un dispositivo **completamente emulado** como una NIC `e1000` o un disco IDE: esos imitan silicio real para que funcione un SO *sin modificar*, pero cada acceso a un registro genera un trap hacia el host. En cambio, `virtio` usa un ring buffer de memoria compartida (`virtqueue`) sobre el que cooperan el driver del guest y el host — eso es E/S paravirtualizada, y es mucho más rápida.

3. Mapeá los conceptos a la terminología de **Xen** (solo referencia; ejecutá comandos `xl` únicamente en un host Xen):

   | Concepto | Término / comando de Xen |
   |---|---|
   | Dominio de control privilegiado con hardware + toolstack | **dom0** |
   | Guest sin privilegios | **domU** |
   | Guest modificado, hypercalls, no necesita VT-x/AMD-V | **PV** (paravirtualización) |
   | Guest sin modificar, necesita VT-x/AMD-V + dispositivos emulados | **HVM** (Hardware Virtual Machine) |
   | Guest HVM que agrega drivers PV para E/S rápida | **PVHVM** |
   | Liviano: virt por HW para CPU/MMU, arranque y E/S PV, sin emulación de QEMU | **PVH** |

   En un host Xen enumerarías los dominios con:
   ```bash
   sudo xl list
   ```
   *Salida de ejemplo:*
   ```
   Name          ID   Mem VCPUs      State   Time(s)
   Domain-0       0  4096     4     r-----   1523.4
   web01          3  2048     2     -b----     87.1
   ```

4. Observá la distinción análoga dentro de la CPU del guest: un guest **PV** nunca emite instrucciones privilegiadas reales (hace *hypercalls*), mientras que un guest **HVM** las ejecuta de forma nativa y hace trap hacia el hipervisor vía VT-x/AMD-V. El flag `hypervisor` del Ejercicio 2 es lo que ve un guest HVM; el `/proc/cpuinfo` de un guest PV clásico de Xen se ve distinto porque ejecuta un kernel consciente de Xen.

> **Punto de control 4**
> - **Q4.1** Enunciá la diferencia definitoria entre *virtualización completa (HVM)* y *paravirtualización (PV)* en una oración cada una, y decí cuál puede arrancar una imagen de SO estándar sin modificar.
> - **Q4.2** `virtio-net` se usa dentro de un guest HVM/KVM que ya tiene virtualización por hardware. Si HVM puede ejecutar drivers sin modificar, ¿para qué molestarse en instalar un driver paravirtualizado `virtio`?
> - **Q4.3** Asociá cada término de Xen con su rol: `dom0`, `domU`, `PVH`. ¿Cuál tiene acceso directo al hardware físico?

---

## Ejercicio 5 — Emulación vs. virtualización vs. simulación, demostrado con QEMU

**Objetivo:** percibir la diferencia entre *ejecutar las instrucciones del guest en la CPU real* (virtualización) y *traducirlas por software* (emulación), y precisar dónde encaja la "simulación".

1. Iniciá un guest diminuto con **aceleración por hardware** y cronometrá cuán rápido llega al firmware. `-accel kvm` ejecuta las instrucciones del guest de forma nativa:

   ```bash
   qemu-system-x86_64 -accel kvm -m 512 -nographic -serial mon:stdio -kernel /boot/vmlinuz-$(uname -r) -append "console=ttyS0" 2>&1 | head
   ```
   (Presioná `Ctrl-a x` para salir.) Esto es **virtualización**: misma arquitectura, ejecución nativa en la CPU, solo las operaciones sensibles hacen trap.

2. Ahora forzá **emulación pura** con el Tiny Code Generator (sin KVM):

   ```bash
   qemu-system-x86_64 -accel tcg -m 512 -nographic ...
   ```
   El mismo guest, pero cada instrucción del guest se traduce binariamente por software. Arranca notablemente más lento. TCG no necesita VT-x/AMD-V — que es exactamente por lo que también te permite ejecutar una arquitectura *foránea*.

3. Demostrá la **emulación** entre arquitecturas: ejecutá una máquina ARM o RISC-V en tu host x86 — imposible con virtualización, rutinario con emulación:

   ```bash
   qemu-system-aarch64 -M virt -cpu cortex-a57 -m 256 -nographic 2>&1 | head
   ```
   La CPU x86 no tiene modo ARM; QEMU *emula* toda la máquina ARM para que corra software ARM real.

4. Fijá los tres términos en tu cabeza:
   - **Virtualización** — las instrucciones del guest se ejecutan directamente en la CPU física (KVM/VT-x/AMD-V); solo las operaciones privilegiadas/sensibles hacen trap. Misma ISA, velocidad casi nativa.
   - **Emulación** — el software imita el hardware (incluida una ISA de CPU posiblemente *diferente*) para que el software del guest sin modificar corra donde el hardware real está ausente. Independiente de la arquitectura, lento (QEMU + TCG).
   - **Simulación** — un modelo que *reproduce el comportamiento* de un sistema para análisis, pruebas o enseñanza, no necesariamente para ejecutar los binarios de producción con fidelidad o velocidad (por ejemplo, un modelo de CPU con precisión de ciclo, un simulador de red). La intención es el estudio/la predicción, no *ser* la máquina.

> **Punto de control 5**
> - **Q5.1** Necesitás ejecutar una imagen de distribución `ppc64le` sin modificar en tu laptop x86_64. ¿Puede KVM hacerlo? ¿La emulación? Explicá por qué en términos del conjunto de instrucciones de la CPU.
> - **Q5.2** En una oración cada una, ¿cuál es la diferencia de *propósito* entre emulación y simulación, aunque ambas "modelen" hardware?
> - **Q5.3** Dos guests corren en el mismo host x86: uno con `-accel kvm`, otro con `-accel tcg` (guest x86, sin arquitectura foránea). ¿Cuál es más rápido y por qué — y cuál seguiría funcionando si VT-x estuviera deshabilitado en el firmware?

---

## Ejercicio 6 — Características del ciclo de vida de una VM: snapshot, pausa, clon, límites de recursos

**Objetivo:** ejercitar las características operativas que lista LPI — snapshots, pausa, clonado y límites de recursos — con `libvirt`/`virsh`. *Hacé esto sobre un guest descartable.* Asumimos un guest detenido llamado `lab01` respaldado por un disco **qcow2** (los snapshots internos requieren qcow2, no raw).

1. Creá el guest de laboratorio si no tenés uno (importa un qcow2 existente, no arranca un instalador):

   ```bash
   sudo virt-install --name lab01 --memory 1024 --vcpus 2 \
     --disk /var/lib/libvirt/images/lab01.qcow2,format=qcow2 \
     --import --os-variant generic --noautoconsole
   sudo virsh list --all
   ```

2. Sacá un **snapshot** del guest en ejecución (por defecto captura el disco *y* la RAM en vivo con un snapshot interno de qcow2):

   ```bash
   sudo virsh snapshot-create-as --domain lab01 --name clean-base \
     --description "fresh install, before changes"
   sudo virsh snapshot-list lab01
   ```
   *Salida de ejemplo:*
   ```
    Name         Creation Time               State
   ------------------------------------------------------
    clean-base   2026-08-11 09:40:12 -0300   running
   ```
   Rompé algo en el guest, después revertí:
   ```bash
   sudo virsh snapshot-revert lab01 clean-base
   ```
   Inspeccioná el snapshot tal como se almacena dentro de la propia imagen de disco:
   ```bash
   sudo qemu-img snapshot -l /var/lib/libvirt/images/lab01.qcow2
   ```

3. **Pausa** vs **save**. `suspend` congela las vCPU pero mantiene todo el guest en la RAM del host (el estado pasa a `paused`); `save` serializa la RAM a un archivo y detiene el guest, liberando esa memoria:

   ```bash
   sudo virsh suspend lab01     # vCPUs frozen, RAM still resident; state = paused
   sudo virsh domstate lab01
   sudo virsh resume lab01      # continues exactly where it stopped

   sudo virsh save lab01 /var/lib/libvirt/save/lab01.save   # RAM -> disk, guest stops
   sudo virsh restore /var/lib/libvirt/save/lab01.save      # reload state
   ```

4. **Cloná** el guest — copia el disco y regenera la identidad (nuevo UUID y MAC de la NIC) para que ambos puedan coexistir:

   ```bash
   sudo virsh shutdown lab01
   sudo virt-clone --original lab01 --name lab02 --auto-clone
   sudo virsh domiflist lab02   # note the new MAC address
   ```

5. **Límites de recursos.** Ajustá la CPU y la memoria en vivo, y limitá el tiempo de CPU mediante cgroups:

   ```bash
   # vCPUs (must be <= the domain's maximum)
   sudo virsh setvcpus lab01 1 --live

   # Memory via the balloon driver (up to the configured maximum)
   sudo virsh setmem lab01 512M --live

   # CPU scheduling caps enforced by cgroups: quota/period in microseconds.
   # 50000/100000 = at most 50% of one physical CPU-second per vCPU.
   sudo virsh schedinfo lab01
   sudo virsh schedinfo lab01 --set vcpu_quota=50000 --set vcpu_period=100000 --live

   # A hard ceiling on RSS (khz/KiB); the kernel will not let the guest exceed it
   sudo virsh memtune lab01 --hard-limit 1048576 --live
   ```
   *Salida de ejemplo de `schedinfo`:*
   ```
   Scheduler      : posix
   cpu_shares     : 1024
   vcpu_period    : 100000
   vcpu_quota     : 50000
   ```

> **Punto de control 6**
> - **Q6.1** Sacás un snapshot *interno* de un guest en ejecución con el `virsh snapshot-create-as` por defecto. Se capturan dos cosas: ¿cuáles son? ¿Y por qué falla este comando si el disco es una imagen `raw`?
> - **Q6.2** Distinguí `virsh suspend` de `virsh save`. Después de cada uno, ¿qué pasó con (a) las vCPU del guest y (b) la RAM del host que el guest estaba usando?
> - **Q6.3** Después de `virt-clone`, ¿por qué la dirección MAC y el UUID deben regenerarse en lugar de copiarse? Dá la falla concreta que una copia byte por byte causaría en la red.
> - **Q6.4** `vcpu_quota=50000` con `vcpu_period=100000` — expresá el límite de CPU resultante en términos simples, y nombrá el subsistema del kernel de Linux que realmente lo impone.

---

## Ejercicio 7 — Migración: P2V y V2V, offline y en vivo

**Objetivo:** entender los aspectos principales de mover cargas de trabajo *hacia* la virtualización (P2V), *entre* hipervisores (V2V), y *entre hosts* (migración en vivo), además de sus prerrequisitos.

1. **V2V** — convertí un guest desde un hipervisor foráneo a KVM/libvirt. `virt-v2v` importa el disco y luego instala los drivers `virtio` para que el resultado corra eficientemente bajo KVM (se muestra una inspección en dry-run):

   ```bash
   # From a VMware OVA export into the local libvirt/KVM
   sudo virt-v2v -i ova exported-vm.ova -o libvirt -os default
   ```
   *Cola de ejemplo de la salida:*
   ```
   [  62.0] Converting Ubuntu 22.04 to run on KVM
   [ 140.4] Installing virtio drivers
   [ 155.9] Creating output metadata
   [ 156.2] Finishing off
   ```

2. **P2V** — una máquina *física* en ejecución no tiene archivo de exportación, así que `virt-p2v` arranca esa máquina desde una pequeña imagen live y transmite sus discos por la red a un servidor de conversión que ejecuta `virt-v2v`. Conceptualmente: **arrancá el host físico desde el ISO de virt-p2v → apuntalo a un servidor de conversión → aterriza como un guest KVM.** (No hay comando para ejecutar acá a menos que tengas hardware de sobra; conocé el flujo.)

3. **Migración en vivo entre hosts** — mové un guest *en ejecución* a otro host con un downtime mínimo. libvirt copia la RAM del guest en pasadas iterativas mientras sigue en ejecución, y luego hace una breve pausa final para transferir las últimas páginas sucias:

   ```bash
   sudo virsh migrate --live --verbose lab01 qemu+ssh://root@host-b/system
   ```
   *Salida de ejemplo:*
   ```
   Migration: [100 %]
   ```

4. Conocé los **prerrequisitos**, porque la migración falla ruidosamente sin ellos:
   - **El almacenamiento** debe ser accesible de forma idéntica en ambos hosts — almacenamiento compartido (NFS/iSCSI/Ceph). Sin él, agregá `--copy-storage-all` para transmitir también el disco (mucho más lento).
   - **Compatibilidad de CPU** — la CPU de destino debe exponer al menos las características con las que se inició el guest; de lo contrario, usá un modelo de CPU base común (por ejemplo, `host-model`/modelos con nombre de libvirt). Migrar de una microarquitectura más nueva a una más vieja sin un modelo compatible es la falla clásica.
   - **Conectividad/autenticación** entre hosts (acá `qemu+ssh`), y el mismo emulador/tipo de máquina disponible en ambos.
   - Usá `--offline` para migrar solo la *configuración* de un guest **detenido** (sin transferencia de RAM).

> **Punto de control 7**
> - **Q7.1** Definí **P2V** y **V2V** en una línea cada uno, y explicá por qué P2V necesita un paso extra (un medio de arranque) que V2V desde una OVA no necesita.
> - **Q7.2** Durante una migración `--live`, el guest sigue en ejecución mientras se copia su memoria. ¿Qué problema crea eso para las páginas que el guest sigue escribiendo, y cómo converge el algoritmo iterativo de pre-copia hacia una pausa final muy corta?
> - **Q7.3** Una migración en vivo aborta con un error de características de CPU. El guest se inició en un host Intel Ice Lake y el destino es un host Haswell más viejo. ¿Cuál es la causa raíz, y cuál es la solución estándar que permite que el guest migre entre ambos?
> - **Q7.4** No tenés almacenamiento compartido. ¿Qué único flag permite que `virsh migrate` igual tenga éxito, y cuál es el costo que aceptás al usarlo?

---

## Ejercicio 8 — Conocimiento general: oVirt, Proxmox, systemd-machined, VirtualBox, Open vSwitch

**Objetivo:** reconocer las herramientas del ecosistema que LPI espera que *conozcas* — qué es cada una, y el comando que la representa.

1. **systemd-machined** registra y hace seguimiento de las VM y contenedores locales. Listalos e inspeccionalos:

   ```bash
   machinectl list
   machinectl status <name>
   ```
   *Salida de ejemplo:*
   ```
   MACHINE   CLASS     SERVICE        OS       VERSION  ADDRESSES
   web-ct    container systemd-nspawn debian   12       10.0.0.5
   ```
   `machined` es un registro/coordinador (login, shell, estado), *no* un hipervisor — se sitúa por encima de los contenedores `systemd-nspawn` y las VM que se registran con él.

2. **Open vSwitch (OVS)** — un switch virtual multicapa programable usado para conectar VM, con VLANs, túneles (VXLAN/GRE) y OpenFlow. Construí un bridge e inspeccionalo:

   ```bash
   sudo ovs-vsctl add-br br0
   sudo ovs-vsctl add-port br0 eth1
   sudo ovs-vsctl show
   sudo ovs-ofctl dump-flows br0
   ```
   libvirt conecta un guest a OVS mediante `<virtualport type='openvswitch'/>` en el XML del dominio; OpenStack Neutron es un consumidor intensivo de OVS.

3. **Proxmox VE** — una plataforma basada en Debian que gestiona **VM KVM** con `qm` y **contenedores LXC** con `pct`, además del clustering con `pvecm` (los comandos se muestran para reconocerlos; ejecutalos solo en un nodo Proxmox):

   ```bash
   qm list            # KVM VMs
   pct list           # LXC containers
   qm migrate 100 pve-node2 --online
   ```

4. **oVirt** — una *plataforma de gestión* de virtualización de datacenter de código abierto sobre KVM/libvirt. Un **engine** central gobierna muchos hosts; cada host ejecuta el agente **VDSM** que habla con libvirt. Gestiona clusters, dominios de almacenamiento y migración en vivo de forma centralizada (el upstream de Red Hat Virtualization).

5. **VirtualBox** — un hipervisor **Tipo 2 (hosted)** para el escritorio, automatizable con `VBoxManage`:

   ```bash
   VBoxManage list vms
   VBoxManage list runningvms
   VBoxManage modifyvm "lab01" --memory 2048 --cpus 2
   ```
   `systemd-detect-virt` reporta un guest de VirtualBox como `oracle`.

> **Punto de control 8**
> - **Q8.1** Tanto oVirt como Proxmox en última instancia ejecutan guests sobre KVM/libvirt. ¿Qué capa agregan por encima, y cuál es la diferencia práctica de alcance entre `virsh` en un solo host y un engine de oVirt?
> - **Q8.2** ¿Es `systemd-machined` un hipervisor? Si no, ¿cuál es su verdadero trabajo, y nombrá un backend cuyas instancias rastrea?
> - **Q8.3** ¿Por qué recurrirías a Open vSwitch en lugar de un bridge Linux común (`brctl`/`ip link`) al cablear VM — nombrá dos capacidades que OVS agrega.
> - **Q8.4** En el eje Tipo 1 / Tipo 2, ¿dónde cae cada uno, KVM y VirtualBox, y cuál es la elección natural para la laptop de un desarrollador frente a un host de datacenter?

---

<details>
<summary><strong>Clave de respuestas — clic para expandir</strong></summary>

### Ejercicio 1
- **Q1.1** `vmx` es el flag de VT-x de *Intel*; AMD expone su equivalente como **`svm`** (AMD-V). Hacer grep solo de `vmx` en una CPU AMD devuelve 0 aunque la virtualización esté completamente soportada. La comprobación portable es `grep -E 'vmx|svm' /proc/cpuinfo`.
- **Q1.2** La extensión está **deshabilitada en el firmware (BIOS/UEFI)**. La CPU es *capaz* (por eso `lscpu`, que lee los bits de capacidad de CPUID, igual imprime `VT-x`), pero como está apagada, el kernel no expone el flag `vmx` en `/proc/cpuinfo` y `kvm-ok` la reporta como inutilizable. Solución: reiniciar entrando a la UEFI/BIOS y habilitar "Intel Virtualization Technology / VT-x" (o "SVM Mode" en AMD).
- **Q1.3** `ept`/`npt` proveen **SLAT (Second Level Address Translation)** — la CPU traduce las direcciones guest-físicas a host-físicas por hardware. Reemplaza las **shadow page tables** mantenidas por software, eliminando los costosos VM exits que el hipervisor tomaba antes en cada cambio de la tabla de páginas del guest, de modo que las cargas de trabajo intensivas en memoria corren mucho más cerca de la velocidad nativa.

### Ejercicio 2
- **Q2.1** No — es el **host**. `xen-dom0` es el dominio de control privilegiado de un hipervisor Xen. Aunque Xen (un hipervisor Tipo 1) corre por debajo, dom0 *es* el SO de gestión con acceso directo al hardware, así que `systemd-detect-virt` lo trata como "no un guest" e imprime `none`, mientras que `virt-what` reporta con más precisión el contexto Xen y el rol dom0.
- **Q2.2** Reporta **`lxc`** (la tecnología de contenedores), porque sin flag `systemd-detect-virt` reporta la capa de virtualización **más interna / más cercana**, y detecta la contenerización antes que la virtualización a nivel de VM. Para ver la capa de VM lo preguntarías explícitamente con `--vm`.
- **Q2.3** El flag `hypervisor` lo establece la emulación de CPUID del hipervisor, que es libre de no establecerlo — por ejemplo, un guest **Xen PV** clásico ejecuta un kernel consciente de Xen y no presenta un CPUID emulado estándar con el flag, y algunos hipervisores pueden configurarse para ocultarlo (para burlar las comprobaciones anti-VM). Y su *ausencia* es inconclusa por sí sola, así que lo corroborás con las cadenas de DMI, `systemd-detect-virt` y `virt-what`.

### Ejercicio 3
- **Q3.1** KVM convierte al propio kernel de Linux en el hipervisor: las vCPU del guest se planifican directamente sobre la CPU física a través de VT-x/AMD-V sin que ningún SO host medie en la ejecución de instrucciones — esa es la propiedad Tipo 1 (bare-metal), y el hecho de que el kernel sea además un SO de propósito general no lo cambia. VirtualBox es **Tipo 2 (hosted)**: corre como una aplicación/driver común *por encima* del SO host, que es dueño del hardware y lo planifica.
- **Q3.2** **KVM** (el módulo del kernel, vía VT-x/AMD-V) ejecuta las instrucciones privilegiadas de ring-0 del guest en la CPU física. **QEMU** (espacio de usuario) provee el modelo de dispositivos — emula el controlador de disco, la NIC y otros periféricos.
- **Q3.3** La virtualización anidada debe estar habilitada en el módulo hipervisor del **host**: `/sys/module/kvm_intel/parameters/nested` (o `kvm_amd`) debe leer `Y`/`1`. Solo entonces el guest externo puede usar VT-x/AMD-V para sus propios guests internos.

### Ejercicio 4
- **Q4.1** *Virtualización completa (HVM):* el SO guest corre **sin modificar**; las instrucciones sensibles/privilegiadas son atrapadas (trap) y manejadas por el hipervisor usando extensiones de hardware (VT-x/AMD-V) más dispositivos emulados. *Paravirtualización (PV):* el SO guest está **modificado/es consciente** de que está virtualizado y coopera vía **hypercalls** en lugar de hacer trap, sin necesitar extensiones de virtualización de CPU. HVM puede arrancar una imagen de SO estándar sin modificar.
- **Q4.2** Porque los dispositivos sin modificar/emulados (por ejemplo, una NIC `e1000`, un disco IDE) son correctos pero lentos — cada acceso a un registro provoca un trap hacia el host. `virtio` es una ruta de **E/S paravirtualizada**: el driver del guest y el host comparten ring buffers (`virtqueues`), agrupando la E/S y recortando drásticamente la cantidad de exits. Así, HVM te da la virtualización de CPU; `virtio` agrega por encima la virtualización rápida de *dispositivos*. (Esta combinación es PVHVM.)
- **Q4.3** `dom0` = el dominio de control privilegiado que es dueño del hardware y ejecuta el toolstack; **tiene acceso directo al hardware.** `domU` = un dominio de guest sin privilegios. `PVH` = un modo de guest liviano que usa virtualización por hardware para CPU/MMU pero interfaces paravirtuales para el arranque y la E/S, sin emulación de dispositivos de QEMU.

### Ejercicio 5
- **Q5.1** KVM **no puede** — ejecuta las instrucciones del guest directamente en la CPU física, que solo entiende x86_64; un binario `ppc64le` es un conjunto de instrucciones distinto sin ruta de ejecución nativa. **La emulación sí puede** — QEMU con TCG traduce cada instrucción `ppc64le` a instrucciones x86 en tiempo de ejecución, así que la imagen foránea corre (lentamente) sin importar la ISA del host.
- **Q5.2** *Emulación:* imitar el hardware real con suficiente fidelidad como para **ejecutar el software de producción real** en lugar de la máquina real. *Simulación:* modelar el comportamiento de un sistema para **estudiarlo, probarlo o predecirlo** — el objetivo es el análisis, no ser un reemplazo directo que ejecute los binarios reales con fidelidad/velocidad.
- **Q5.3** El guest `-accel kvm` es más rápido porque sus instrucciones corren de forma nativa en la CPU; el guest `-accel tcg` paga la traducción binaria por software de cada instrucción. Solo el guest **TCG** seguiría funcionando con VT-x deshabilitado — la emulación no necesita extensiones de virtualización por hardware, mientras que KVM se niega a iniciar sin ellas.

### Ejercicio 6
- **Q6.1** Captura el **estado del disco** *y* el **estado de RAM/CPU en vivo** (un snapshot de VM en ejecución al que podés revertir como si la máquina nunca se hubiera detenido). Falla en un disco `raw` porque **los snapshots internos son una característica de qcow2** — los datos y metadatos del snapshot viven *dentro* del archivo qcow2; raw no tiene ese contenedor (en su lugar necesitarías un snapshot *externo*).
- **Q6.2** `suspend`: las vCPU quedan **congeladas** (estado `paused`) pero la memoria del guest **sigue residente en la RAM del host** — reanudación instantánea, sin memoria liberada. `save`: las vCPU se **detienen** y la RAM del guest se **serializa a un archivo en disco**, así que la memoria del host *sí* se libera; tenés que hacer `restore` desde el archivo para continuar.
- **Q6.3** El UUID y la MAC son identificadores únicos. Dos guests en vivo con la **misma MAC** en un mismo segmento L2 causan una colisión de direcciones — confusión de ARP/switch, tramas descartadas o mal dirigidas, y (si DHCP usa la MAC como clave) ambas máquinas peleando por un mismo lease. `virt-clone` los regenera para que el clon sea una entidad de red distinta.
- **Q6.4** El guest queda limitado al **50% de una CPU física** por vCPU (50000 µs de ejecución por cada período de 100000 µs). Lo impone el controlador de CPU de **cgroups** de Linux (control de ancho de banda de CFS: `cpu.cfs_quota_us` / `cpu.cfs_period_us`), que libvirt configura.

### Ejercicio 7
- **Q7.1** **P2V** = migrar el SO/los datos de una máquina *física* a una máquina virtual. **V2V** = convertir una máquina *virtual* de un hipervisor/formato a otro (por ejemplo, VMware → KVM). P2V necesita un medio de arranque porque un host físico en ejecución no tiene archivo de exportación y no puede crear una imagen de su propio sistema de archivos raíz en vivo de forma limpia, así que `virt-p2v` lo arranca desde una imagen auxiliar para transmitir los discos hacia afuera; un V2V desde una OVA ya tiene un disco exportado autocontenido para leer.
- **Q7.2** Mientras se copia la RAM, el guest sigue **ensuciando páginas** que ya fueron enviadas, así que esas deben reenviarse. La pre-copia itera: envía todas las páginas, luego envía solo las páginas ensuciadas desde la última pasada, cada pasada más chica que la anterior. Cuando el conjunto de páginas sucias restantes es lo bastante chico como para transferirse dentro del objetivo de downtime, el guest se **pausa brevemente**, se copian las últimas páginas y el estado de la CPU, y se reanuda en el destino — una detención de menos de un segundo para una carga de trabajo que converge.
- **Q7.3** El guest se inició exponiendo características de CPU de Ice Lake que **no existen en el destino Haswell más viejo**, así que el destino no puede honrar el modelo de CPU del guest. Solución: iniciar los guests con un **modelo de CPU base común** que ambos hosts soporten (un modelo con nombre en el mínimo común denominador, o una política `custom`/`host-model` a nivel de todo el cluster) para que el conjunto de características sea portable en toda la flota.
- **Q7.4** `--copy-storage-all` (o `--copy-storage-inc`) hace que `virsh migrate` también transmita la imagen de disco al destino. El costo es una transferencia de datos mucho mayor y un tiempo de migración más largo, ya que estás moviendo todo el disco por la red además de la RAM.

### Ejercicio 8
- **Q8.1** Agregan una **capa de gestión/orquestación** (UI web, API, clustering, almacenamiento centralizado y planificación) por encima de KVM/libvirt. `virsh` gestiona guests en un **solo host**; un engine de oVirt gestiona **muchos hosts como un datacenter** — pools, dominios de almacenamiento compartido, HA, y migración en vivo gobernada de forma central.
- **Q8.2** No. `systemd-machined` es un **registro/coordinador** que rastrea y provee acceso (listar, estado, login, shell) a las máquinas virtuales y contenedores locales; no ejecuta guests. Un backend que rastrea: los contenedores **`systemd-nspawn`** (también rastrea las VM registradas).
- **Q8.3** OVS agrega programabilidad y características de las que un bridge común carece — por ejemplo: **control de flujo basado en OpenFlow**, **etiquetado/trunking de VLAN** nativo, **túneles** de overlay **(VXLAN/GRE)**, QoS por puerto, y control SDN centralizado (dos cualesquiera de estas). Un bridge Linux es, en comparación, un simple switch de aprendizaje L2.
- **Q8.4** **KVM = Tipo 1 (bare-metal)**, la elección natural para un host de datacenter; **VirtualBox = Tipo 2 (hosted)**, la elección natural para la laptop de un desarrollador, donde corre como una app por encima del SO de escritorio.

</details>

---

**Fuentes**
- LPI — Objetivos del examen 305 (351.1): https://www.lpi.org/our-certifications/exam-305-objectives/
- Documentación del proyecto KVM: https://linux-kvm.org/page/Documentation
- Documentación de QEMU (aceleradores, `virtio`, emulación de sistema): https://www.qemu.org/docs/master/
- libvirt — ciclo de vida de dominios, snapshots, migración: https://libvirt.org/docs.html y https://libvirt.org/migration.html
- Documentación de `virtio` y virtualización anidada del kernel de Linux: https://docs.kernel.org/ y https://www.kernel.org/doc/html/latest/virt/kvm/
- Xen Project — PV/HVM/PVH y dom0/domU: https://wiki.xenproject.org/wiki/Xen_Project_Software_Overview
- `systemd-detect-virt` / `systemd-machined` / `machinectl`: https://www.freedesktop.org/software/systemd/man/latest/systemd-detect-virt.html y https://www.freedesktop.org/software/systemd/man/latest/machinectl.html
- `virt-v2v` / `virt-p2v`: https://libguestfs.org/virt-v2v.1.html y https://libguestfs.org/virt-p2v.1.html
- Documentación de Open vSwitch: https://docs.openvswitch.org/
- Guía de administración de Proxmox VE: https://pve.proxmox.com/pve-docs/
- Documentación de oVirt: https://www.ovirt.org/documentation/
- Manual de Oracle VM VirtualBox (`VBoxManage`): https://www.virtualbox.org/manual/