# LPIC-3 305 (Examen 305-300) - Tema 1.1: Full Virtualization

---

## 1. Motivación de la arquitectura de producción y mecánica principal

### 1.1 El problema del subaprovechamiento y aislamiento en Bare-Metal
En las arquitecturas empresariales de producción, ejecutar cargas de trabajo únicas directamente sobre hardware físico introduce tres vulnerabilidades operativas clave:
1. **Baja eficiencia de cómputo**: Las cargas de trabajo raras veces utilizan el $100\%$ de la capacidad de CPU, RAM e I/O de forma simultánea, lo que resulta en un severo subaprovechamiento de recursos ($10\% - 15\%$ de utilización promedio de CPU en bare metal).
2. **Fallo grave en la multitenencia (Hard Multi-Tenancy Failure)**: Los sistemas operativos modernos comparten un único espacio de kernel entre los procesos de usuario. Un kernel panic provocado por un solo proceso detiene todo el host bare-metal.
3. **Acoplamiento de hardware e inflexibilidad de migración**: Las aplicaciones acopladas a hardware físico requieren stacks de drivers específicos, lo que impide la relocalización en vivo (live relocation) sin interrupciones entre nodos de hardware físico heterogéneos.

La virtualización completa (Full Virtualization) resuelve estos desafíos interponiendo un **Virtual Machine Monitor (VMM)** / Hypervisor entre el hardware y los Guest Operating Systems no modificados, creando límites de aislamiento strictly aplicados a nivel de hardware de la CPU.

```
+-----------------------------------------------------------------------+
|                         GUEST OS (Unmodified)                         |
|   +--------------------------+     +-------------------------------+  |
|   |   User Space Processes   |     |   Guest Kernel (Ring 0/1)     |  |
|   +--------------------------+     +-------------------------------+  |
+-----------------------------------------------------------------------+
                                  |
                   Hardware Emulation & Hypercalls
                                  v
+-----------------------------------------------------------------------+
|                           QEMU (Userspace)                            |
|        [Device Emulation | VirtIO Backends | QMP API | Storage]        |
+-----------------------------------------------------------------------+
                                  |  ioctl(/dev/kvm)
                                  v
+-----------------------------------------------------------------------+
|                    KVM Kernel Module (kvm.ko)                         |
|     [VCPU Execution Loop | EPT/NPT Paging | Interrupt Controller]     |
+-----------------------------------------------------------------------+
                                  |  Hardware Virtualization Extensions
                                  v
+-----------------------------------------------------------------------+
|                       PHYSICAL HARDWARE (Host)                        |
|        [Intel VT-x / AMD-V CPU | Hardware EPT | IOMMU VT-d]           |
+-----------------------------------------------------------------------+
```

---

### 1.2 Mecánica de virtualización asistida por hardware de CPU
La virtualización completa moderna en x86_64 se basa en extensiones de hardware: **Intel VT-x** (Virtualization Technology) y **AMD-V**.

#### Modos de ejecución privilegiada VMX
Intel VT-x introduce dos modos de operación al modelo de anillos de ejecución (execution ring model) de la CPU:
* **VMX Root Operation**: Modo totalmente privilegiado utilizado por el Host Kernel / Hypervisor (KVM). El host tiene acceso irrestricto a las instrucciones de hardware y a la memoria física.
* **VMX Non-Root Operation**: Modo de privilegio restringido donde se ejecutan las instancias de Guest OS. Las instrucciones privilegiadas emitidas por el Guest Kernel activan un **VM-Exit**, suspendiendo la ejecución del guest y cediendo el control de nuevo al Host Hypervisor en modo VMX Root.

```
       +-------------------------------------------------------+
       |                  VMX Root Operation                   |
       |                (Host Kernel / KVM)                    |
       +-------------------------------------------------------+
                                |             ^
                       VMXON /  |             |  VM-Exit
                      VMLAUNCH  |             |  (Page Fault, IO,
                                v             |   Hypercall)
       +-------------------------------------------------------+
       |                VMX Non-Root Operation                 |
       |                 (Guest OS Execution)                  |
       +-------------------------------------------------------+
```

#### La mecánica del bucle VCPU de KVM
Cuando se ejecuta una CPU virtual guest (vCPU), KVM ejecuta un bucle de hardware de baja sobrecarga mediante la llamada al sistema `ioctl(vcpu_fd, KVM_RUN, ...)` emitida por QEMU:

1. **Inicialización (`VMLAUNCH` / `VMRESUME`)**: El Host Kernel escribe el contexto inicial (registros, registros de control, punteros de ejecución) en la estructura **VMCS (Virtual Machine Control Structure)** en la memoria física y emite `VMRESUME`.
2. **Ejecución del Guest**: La CPU ingresa al modo **VMX Non-Root mode** y ejecuta de forma nativa las instrucciones del guest a velocidad de hardware sin traducción binaria por software.
3. **Intercepción / VM-Exit**: Cuando el Guest OS realiza una instrucción que requiere intervención del hypervisor (por ejemplo, acceder al registro CR3, ejecutar instrucciones de ensamblador `IN`/`OUT`, lecturas/escrituras MMIO, o activar una EPT Violation), el hardware intercepta la instrucción y fuerza un **VM-Exit**.
4. **Manejo del Exit**:
   * **Manejo en Kernel (In-Kernel Handling)**: Si la salida se puede manejar directamente mediante `kvm.ko` (por ejemplo, interrupción de temporizador LAPIC, asignación de páginas EPT), KVM la maneja en ring 0 y emite inmediatamente `VMRESUME`.
   * **Salida al Espacio de Usuario (Userspace Exit)**: Si la salida requiere emulación de dispositivos compleja (por ejemplo, controlador IDE heredado emulado o acceso a dispositivos PCI), `ioctl(KVM_RUN)` retorna al espacio de usuario de QEMU. QEMU procesa la operación de I/O y vuelve a invocar `ioctl(KVM_RUN)`.

---

### 1.3 Virtualización de memoria: EPT / NPT vs. Shadow Page Tables
En la virtualización completa, existen dos niveles de traducción de direcciones:
$$\text{Guest Virtual Address (GVA)} \longrightarrow \text{Guest Physical Address (GPA)} \longrightarrow \text{Host Physical Address (HPA)}$$

```
+-------------------+       +-------------------+       +-------------------+
| Guest VA (GVA)    | ----> | Guest PA (GPA)    | ----> | Host PA (HPA)     |
+-------------------+       +-------------------+       +-------------------+
  (Managed by Guest OS         (Emulated RAM         (Actual Physical 
   Page Tables)                 Address Space)        DRAM Modules)
```

#### Shadow Page Tables heredadas (Emulación por software)
* El hypervisor mantiene una única tabla de mapeo que vincula directamente GVA a HPA.
* **Sobrecarga (Overhead)**: Cualquier modificación a la Guest Page Table por parte del Guest OS debe estar protegida contra escritura. Cada modificación en la tabla de páginas causa un VM-Exit, introduciendo una enorme latencia de CPU (penalización de rendimiento del $30\% - 400\%$ durante asignaciones intensivas de memoria).

#### Paginación asistida por hardware (Intel EPT / AMD NPT)
* La Memory Management Unit (MMU) de la CPU mantiene una tabla de traducción de hardware secundaria: **Extended Page Tables (EPT)** en Intel o **Nested Page Tables (NPT)** en AMD.
* La MMU de hardware traduce GVA a GPA mediante el CR3 del guest y luego recorre automáticamente la EPT de hardware para traducir GPA a HPA.
* **EPT Violation**: Si una GPA no está mapeada en la tabla EPT del host, ocurre un VM-Exit por EPT Violation. `kvm.ko` asigna memoria física en el host, actualiza la entrada EPT y reanuda la ejecución del guest sin interrupciones.

---

### 1.4 Estrategias de virtualización de I/O de dispositivos

```
+-----------------------------------------------------------------------------------+
|                               I/O VIRTUALIZATION MODES                            |
+-----------------------+----------------------------------+------------------------+
| 1. Full Emulation     | 2. Paravirtualized (VirtIO)      | 3. Direct Pass-through |
| (e.g., Intel e1000)   | (vring / virtqueue / vhost-net)  | (VFIO / SR-IOV)        |
+-----------------------+----------------------------------+------------------------+
| High VM-Exit overhead | Shared memory ring buffer        | Zero hypervisor exit   |
| Traps every register  | Minimal traps via doorbell/irq   | Near bare-metal speed  |
| Full compatibility    | Requires virtio guest drivers    | Requires dedicated HW  |
+-----------------------+----------------------------------+------------------------+
```

1. **Emulación completa (por ejemplo, e1000, IDE, Cirrus Logic)**:
   QEMU intercepta cada acceso a registros mediante trampas de salida MMIO/PIO. Elevada sobrecarga de CPU debido a miles de VM-Exits por segundo durante ráfagas de red o almacenamiento.
2. **Paravirtualización (`VirtIO`)**:
   El Guest OS utiliza drivers VirtIO especializados. Estructuras de memoria estandarizadas (**Virtqueues** y **Available/Used Vrings**) permiten la comunicación directa mediante memoria compartida entre la RAM del Guest y el Host Kernel/QEMU, reduciendo los VM-Exits en órdenes de magnitud.
   * `vhost-net`: Desplaza el procesamiento de paquetes de red virtio fuera del espacio de usuario de QEMU directamente hacia un hilo de trabajo del kernel del host (`vhost-<pid>`), eliminando los cambios de contexto en el espacio de usuario.
3. **Passthrough directo de hardware (VFIO / SR-IOV)**:
   Los periféricos (por ejemplo, NICs PCIe, SSDs NVMe, GPUs) se mapean directamente en el espacio de direcciones del Guest mediante IOMMU (Input-Output Memory Management Unit) **Intel VT-d** o **AMD-Vi**. El Guest OS se comunica directamente con los registros del hardware sin la intercepción del Hypervisor.

---

## 2. Matriz técnica comparativa profunda y análisis de compensaciones (Trade-Offs)

### 2.1 Comparación de paradigmas de virtualización

| Métrica / Característica | Full Virtualization asistida por hardware (KVM/QEMU) | Paravirtualización (Xen PV) | Virtualización a nivel de SO (Containers / LXC / cgroups) |
| :--- | :--- | :--- | :--- |
| **Tipo de Hypervisor / Motor** | Type-1 (vía módulo de kernel KVM) | Type-1 (interfaz Hypercall de Xen Hypervisor) | N/A (Host Kernel compartido + namespaces/cgroups) |
| **Modificación del Guest OS** | Ninguna (Ejecuta Windows, BSD, kernels propietarios sin modificar) | Requerida (Kernel guest parcheado para hypercalls) | No puede ejecutar kernels de SO distintos (solo guests Linux en host Linux) |
| **Modelo de privilegio de CPU** | VMX Root (Host) vs VMX Non-Root (Guest) | Ring 0 (Xen), Ring 1 (Guest Kernel), Ring 3 (Apps) | Ring 0 compartido (Host Kernel), Ring 3 (Container Apps) |
| **Sobrecarga (Overhead) de rendimiento de CPU** | $< 2\%$ (Acelerado por hardware vía VT-x / AMD-V) | $< 3\%$ | $0\%$ (Ejecución nativa directa) |
| **Seguridad y aislamiento de memoria** | Absoluto (Límites EPT por hardware, pools de RAM aislados) | Alto (Límites de interfaz hypercall de hypervisor) | Débil / Moderado (Límites de namespaces de kernel por software) |
| **Latencia de I/O (VirtIO / SR-IOV)**| Casi nativa ($< 5\%$ de sobrecarga con SR-IOV / `vhost`) | Casi nativa | Rendimiento de kernel directo nativo |
| **Latencia de inicio / arranque** | De segundos a minutos (POST/UEFI completo e inicialización de SO) | Segundos | Milisegundos (Fork de proceso + acoplamiento a namespace) |
| **Soporte de Live Migration** | Soporte completo (Seguimiento de dirty memory vía bit EPT) | Soporte completo | Limitado / Complejo (Checkpointing de procesos CRIU) |
| **Huella de seguridad** | Límite de seguridad extremadamente alto (Aplicado por hardware) | Límite de seguridad alto | Mayor superficie de ataque (Vulnerabilidades en Host Kernel compartido) |

---

### 2.2 Matriz de formatos de almacenamiento de respaldo y modos de caché

#### Formatos de almacenamiento de respaldo

| Formato | Asignación de espacio en disco | Capacidad de Snapshots | Rendimiento de lectura | Rendimiento de escritura | Recomendación de producción empresarial |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **`raw`** | Preasignado (imagen binaria plana) | Solo externo / a nivel de LVM | Máximo (Mapeo directo de offset de bloques LBA) | Máximo | Cargas de trabajo de BD de alto rendimiento (backends SAN/NVMe) |
| **`qcow2` (v3)** | Disperso (Sparse) / Expansión dinámica | Copy-on-Write nativo (Interno y Externo) | Alto (Sobrecarga menor por tabla de búsqueda) | Alto (con `preallocation=metadata`) | VMs empresariales estándar, Plantillas de imágenes cloud |
| **Block / LVM** | Dispositivo de bloques dedicado preasignado | Snapshot de arreglo de almacenamiento LVM / SAN | Velocidad nativa Bare-Metal | Velocidad nativa Bare-Metal | Aplicaciones de misión crítica limitadas por IOPS |

#### Modos de caché de QEMU

| Modo de caché | Host Page Cache | Guest Cache | Manejo de Flush/Sync (`fsync`) | Seguridad de datos ante caída del Host | Caso de uso recomendado |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **`none`** | **Deshabilitado** (`O_DIRECT`) | Habilitado (Writeback) | Pasado directamente al disco físico | **Seguro** (Garantizado al escribir en almacenamiento físico) | **Estándar de producción empresarial** (SAN/Ceph/Direct NVMe) |
| **`writeback`** | **Habilitado** | Habilitado (Writeback) | Diferido hasta que el guest solicite sync explícito | Riesgo de pérdida de datos durante un kernel panic del host | Cargas de trabajo generales no críticas |
| **`writethrough`** | **Habilitado** | **Deshabilitado** | El host vacía (flush) cada escritura a disco antes de retornar | **Seguro** | Aplicaciones heredadas que carecen de lógica `fsync` adecuada |
| **`directsync`** | **Deshabilitado** (`O_DIRECT`) | **Deshabilitado** | Escritura síncrona directa en el almacenamiento del host | **Seguro** | Logs de alta confiabilidad, escrituras secuenciales sin caché |
| **`unsafe`** | **Habilitado** | Habilitado | Ignora completamente las solicitudes de flush del guest | **Catastrófico** (Corrupción garantizada si cae el host) | Nodos de compilación (build nodes), pruebas efímeras temporales |

---

### 2.3 Matriz de compensaciones (Trade-Offs) en la arquitectura de red

| Arquitectura | Complejidad de configuración | Utilización de CPU del Host | Velocidad de conmutación Inter-VM | Dependencia de hardware SR-IOV | Compatibilidad con Live Migration |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Linux Bridge + `virtio-net`** | Baja | Moderada | Alta (Conmutación por bridge de software) | No | **Sin interrupciones (Seamless)** |
| **Linux Bridge + `vhost-net`** | Baja | **Baja** (Procesamiento vring en sitio en kernel) | Muy alta | No | **Sin interrupciones (Seamless)** |
| **Macvtap (Bridge/VEPA)** | Baja | Baja | Alta (Omite el bridge del host, bridge directo de NIC) | No | Restringe la comunicación Host-a-Guest en la misma NIC |
| **Open vSwitch (OVS) + DPDK** | Alta | Baja (Poll Mode Drivers) | Extremadamente alta (Velocidad de cable 10G/40G/100G) | No | Soportado con paridad de configuración en OVS |
| **VFIO PCIe Passthrough / SR-IOV** | Alta | **Casi cero** | Velocidad de cable del Switch físico / Hardware NIC | **Sí** (Requiere NIC con SR-IOV Intel/Mellanox) | Requiere configuración compleja de conmutación por error (bond failover) |

---

## 3. Manifiestos completos listos para producción y especificaciones de infraestructura

### 3.1 Domain XML de producción empresarial (`/etc/libvirt/qemu/prod-app-vm01.xml`)
Este manifiesto XML de dominio implementa pinning de nodos NUMA, afinidad de vCPU, respaldo de Hugepages de 1GiB, `virtio-scsi` con soporte multi-queue, red `vhost-net` e integración con QEMU guest agent.

```xml
<domain type='kvm'>
  <name>prod-app-vm01</name>
  <uuid>c7a5a8e2-893d-4c31-b6d8-912f2c8d76e4</uuid>
  <metadata>
    <app:metadata xmlns:app="https://schemas.enterprise.io/libvirt/app/1.0">
      <app:environment>production</app:environment>
      <app:owner>sre-platform-team</app:owner>
    </app:metadata>
  </metadata>
  <memory unit='GiB'>16</memory>
  <currentMemory unit='GiB'>16</currentMemory>
  <memoryBacking>
    <hugepages>
      <page size='1048576' unit='KiB' nodeset='0'/>
    </hugepages>
    <nosharepages/>
    <locked/>
  </memoryBacking>
  <vcpu placement='static'>8</vcpu>
  <iothreads>2</iothreads>
  <cputune>
    <vcpupin vcpu='0' cpuset='2'/>
    <vcpupin vcpu='1' cpuset='3'/>
    <vcpupin vcpu='2' cpuset='4'/>
    <vcpupin vcpu='3' cpuset='5'/>
    <vcpupin vcpu='4' cpuset='6'/>
    <vcpupin vcpu='5' cpuset='7'/>
    <vcpupin vcpu='6' cpuset='8'/>
    <vcpupin vcpu='7' cpuset='9'/>
    <iothreadpin iothread='1' cpuset='0'/>
    <iothreadpin iothread='2' cpuset='1'/>
    <emulatorpin cpuset='0-1'/>
  </cputune>
  <numatune>
    <memory mode='strict' nodeset='0'/>
  </numatune>
  <sysinfo type='smbios'>
    <system>
      <entry name='manufacturer'>Enterprise SRE Cloud</entry>
      <entry name='product'>Virtual Production Node</entry>
    </system>
  </sysinfo>
  <os>
    <type arch='x86_64' machine='pc-q35-8.1'>hvm</type>
    <boot dev='hd'/>
    <bootmenu enable='no'/>
  </os>
  <features>
    <acpi/>
    <apic/>
    <pae/>
  </features>
  <cpu mode='host-passthrough' check='none' migratable='on'>
    <topology sockets='1' dies='1' cores='8' threads='1'/>
    <cache mode='passthrough'/>
    <feature policy='require' name='topoext'/>
  </cpu>
  <clock offset='utc'>
    <timer name='rtc' tickpolicy='catchup'/>
    <timer name='pit' tickpolicy='delay'/>
    <timer name='hpet' present='no'/>
    <timer name='kvmclock' present='yes'/>
  </clock>
  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>destroy</on_crash>
  <devices>
    <emulator>/usr/bin/qemu-system-x86_64</emulator>

    <!-- Storage Controller: VirtIO SCSI with IOThread -->
    <controller type='scsi' index='0' model='virtio-scsi'>
      <driver queues='8' iothread='1'/>
      <address type='pci' domain='0x0000' bus='0x03' slot='0x00' function='0x0'/>
    </controller>

    <!-- Operating System Disk: Raw or QCow2 using VirtIO SCSI -->
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2' cache='none' io='native' discard='unmap' error_policy='stop'/>
      <source file='/var/lib/libvirt/images/prod-app-vm01-root.qcow2'/>
      <target dev='sda' bus='scsi'/>
      <address type='drive' controller='0' bus='0' target='0' unit='0'/>
    </disk>

    <!-- Network Interface: VirtIO with vhost-net multi-queue -->
    <interface type='bridge'>
      <mac address='52:54:00:1a:3b:4c'/>
      <source bridge='br0'/>
      <target dev='vnet0'/>
      <model type='virtio'/>
      <driver name='vhost' queues='8' rx_queue_size='1024' tx_queue_size='1024'/>
      <address type='pci' domain='0x0000' bus='0x01' slot='0x00' function='0x0'/>
    </interface>

    <!-- QEMU Guest Agent Channel -->
    <channel type='unix'>
      <source mode='bind' path='/var/lib/libvirt/qemu/channel/target/domain-prod-app-vm01/org.qemu.guest_agent.0'/>
      <target type='virtio' name='org.qemu.guest_agent.0'/>
      <address type='pci' domain='0x0000' bus='0x02' slot='0x00' function='0x0'/>
    </channel>

    <!-- Serial Console for Headless Management -->
    <serial type='pty'>
      <target port='0'/>
    </serial>
    <console type='pty'>
      <target type='serial' port='0'/>
    </console>

    <memballoon model='virtio'>
      <stats period='10'/>
      <address type='pci' domain='0x0000' bus='0x04' slot='0x00' function='0x0'/>
    </memballoon>
    <rng model='virtio'>
      <backend model='random'>/dev/urandom</backend>
    </rng>
  </devices>
</domain>
```

---

### 3.2 XMLs de Storage Pool y Network Pool empresarial de Libvirt

#### XML de Storage Pool (`/etc/libvirt/storage/production-pool.xml`)
```xml
<pool type='dir'>
  <name>production-pool</name>
  <uuid>a8e2b1c4-3d91-4e78-bc02-123456789abc</uuid>
  <capacity unit='GiB'>2000</capacity>
  <allocation unit='GiB'>450</allocation>
  <available unit='GiB'>1550</available>
  <source>
  </source>
  <target>
    <path>/var/lib/libvirt/images</path>
    <permissions>
      <mode>0711</mode>
      <owner>0</owner>
      <group>0</group>
      <label>system_u:object_r:virt_image_t:s0</label>
    </permissions>
  </target>
</pool>
```

#### XML de Network Pool aislado de producción (`/etc/libvirt/qemu/networks/prod-isolated-net.xml`)
```xml
<network>
  <name>prod-isolated-net</name>
  <uuid>e91a2b3c-4d5e-6f7a-8b9c-0123456789de</uuid>
  <forward mode='nat'>
    <nat>
      <port start='1024' end='65535'/>
    </nat>
  </forward>
  <bridge name='virbr1' stp='on' delay='0'/>
  <mac address='52:54:00:ee:11:22'/>
  <domain name='internal.production.local'/>
  <ip address='192.168.100.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='192.168.100.100' end='192.168.100.254'/>
      <host mac='52:54:00:1a:3b:4c' name='prod-app-vm01' ip='192.168.100.10'/>
    </dhcp>
  </ip>
</network>
```

---

### 3.3 Manifiesto de rendimiento del sistema host y ajuste del kernel (`/etc/sysctl.d/99-kvm-sre-performance.conf`)
```ini
# Production KVM Host System Tuning Parameters

# Disable Transparent Huge Pages (THP) allocation stalling (handled via explicit hugepages)
vm.transparent_hugepage = never

# Maximize memory availability for KVM guests and prevent excessive swapping
vm.swappiness = 10
vm.dirty_background_ratio = 5
vm.dirty_ratio = 10
vm.vfs_cache_pressure = 50

# Network Core performance for high-throughput bridge & vhost handling
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.netdev_max_backlog = 10000
net.core.somaxconn = 4096

# Enable ARP filtering and bypass unnecessary bridge netfilter evaluation
net.bridge.bridge-nf-call-iptables = 0
net.bridge.bridge-nf-call-ip6tables = 0
net.bridge.bridge-nf-call-arptables = 0

# Prevent low-memory allocation deadlocks
vm.min_free_kbytes = 1048576
```

---

## 4. Comandos de la CLI en terminal real y salidas realistas ($)

### 4.1 Auditoría de capacidad de virtualización por hardware
Verifique el soporte de hardware de la CPU, el estado del módulo del kernel y las capacidades del hypervisor.

```bash
$ lscpu | grep -E "(Virtualization|Vendor ID|NUMA node\(s\))"
Vendor ID:               GenuineIntel
Virtualization:          VT-x
NUMA node(s):            2

$ egrep -c "(vmx|svm)" /proc/cpuinfo
64

$ lsmod | grep kvm
kvm_intel             368640  32
kvm                  1048576  1 kvm_intel

$ virsh domcapabilities --virttype kvm --arch x86_64 --machine pc-q35-8.1 | grep -A 8 "<domain>"
<domain>kvm</domain>
<machine>pc-q35-8.1</machine>
<arch>x86_64</arch>
<vcpu max='288'/>
<iothreads supported='yes'/>
<os supported='yes'>
  <enum name='firmware'/>
  <loader supported='yes'>
    <value>/usr/share/OVMF/OVMF_CODE.fd</value>
```

---

### 4.2 Operaciones de almacenamiento con `qemu-img`
Cree, inspeccione, rebasee y realice snapshots de imágenes de disco virtual.

#### Creación de una imagen QCow2 preasignada
```bash
$ qemu-img create -f qcow2 -o cluster_size=64k,preallocation=metadata /var/lib/libvirt/images/prod-app-vm01-root.qcow2 100G
Formatting '/var/lib/libvirt/images/prod-app-vm01-root.qcow2', fmt=qcow2 cluster_size=648576 preallocation=metadata size=107374182400 lazy_refcounts=off refcount_bits=16
```

#### Inspección detallada de la imagen
```bash
$ qemu-img info --backing-chain /var/lib/libvirt/images/prod-app-vm01-root.qcow2
image: /var/lib/libvirt/images/prod-app-vm01-root.qcow2
file format: qcow2
virtual size: 100 GiB (107374182400 bytes)
disk size: 1.25 GiB
cluster_size: 65536
Format specific information:
    compat: 1.1
    compression type: zlib
    lazy refcounts: false
    corrupt: false
    extended l2: false
```

#### Creación de snapshot externo en vivo vía `virsh`
```bash
$ virsh snapshot-create-as --domain prod-app-vm01 \
    --name "snap-pre-kernel-upgrade" \
    --description "Snapshot before Linux kernel 6.6 patch" \
    --atomic --disk-only
Domain snapshot snap-pre-kernel-upgrade created
```

---

### 4.3 Ciclo de vida del dominio y ajuste de afinidad vía `virsh`

#### Definición e inicio de la VM
```bash
$ virsh define /etc/libvirt/qemu/prod-app-vm01.xml
Domain 'prod-app-vm01' defined from /etc/libvirt/qemu/prod-app-vm01.xml

$ virsh start prod-app-vm01
Domain 'prod-app-vm01' started

$ virsh list --all
 Id   Name             State
--------------------------------
 1    prod-app-vm01    running
```

#### Verificación del pinning y afinidad de vCPU en tiempo real
```bash
$ virsh vcpupin prod-app-vm01
VCPU   CPU Affinity
----------------------
 0      2
 1      3
 2      4
 3      5
 4      6
 5      7
 6      8
 7      9
```

#### Obtención de estadísticas de la máquina virtual en tiempo real
```bash
$ virsh domstats prod-app-vm01 --cpu-total --balloon --block --net
Domain: 'prod-app-vm01'
  cpu.time=458291048291
  cpu.user=12049182390
  cpu.system=34019284102
  balloon.current=16777216
  balloon.maximum=16777216
  block.count=1
  block.0.name=sda
  block.0.path=/var/lib/libvirt/images/prod-app-vm01-root.qcow2
  block.0.rd.reqs=124091
  block.0.rd.bytes=4912048128
  block.0.wr.reqs=981240
  block.0.wr.bytes=18491024896
  net.count=1
  net.0.name=vnet0
  net.0.rx.bytes=9812490182
  net.0.rx.pkts=4192041
  net.0.tx.bytes=490128401
  net.0.tx.pkts=2094012
```

---

## 5. Guía de verificación en producción y diagnóstico / resolución de fallas (Troubleshooting)

```
+-----------------------------------------------------------------------------------+
|                        SRE VM TROUBLESHOOTING FLOWCHART                           |
+-----------------------------------------------------------------------------------+
| Issue Detected: Performance degradation, high latency, or unresponsive guest     |
+-----------------------------------------------------------------------------------+
                                          |
                                          v
                         +---------------------------------+
                         | Check Host CPU & VM-Exit Rates  |
                         | Command: kvm_stat -1            |
                         +---------------------------------+
                                          |
                     +--------------------+--------------------+
                     |                                         |
                     v                                         v
        High Exit Rate (>50k/sec)                   Normal Exit Rate (<5k/sec)
         (EPT Violations / IO)                                 |
                     |                                         v
                     v                        +----------------------------------+
        +--------------------------+          | Check Storage I/O Latency        |
        | Check Memory Allocation  |          | Command: virsh domblkstat        |
        | & Hugepages Backing      |          +----------------------------------+
        +--------------------------+                           |
                                                  +------------+------------+
                                                  |                         |
                                                  v                         v
                                       High Block Wait Times      Low Block Wait Times
                                       (I/O Thread contention)              |
                                                  |                         v
                                                  v            +--------------------------+
                                     +----------------------+  | Check VirtIO Network     |
                                     | Switch cache mode to |  | Drops & Ring Starvation  |
                                     | 'none' (O_DIRECT)    |  | Command: ethtool -S vnet0|
                                     +----------------------+  +--------------------------+
```

---

### 5.1 Problema 1: Alto CPU Steal Time y tormentas de VM-Exit
* **Síntoma**: El Guest OS reporta un alto tiempo de CPU `%steal` en `top`/`htop` ($> 15\%$), y el host experimenta una elevada utilización de CPU con un bajo rendimiento en las aplicaciones del guest.
* **Causa raíz**: VM-Exits excesivos causados por fallos de página no acelerados (falta de EPT/NPT o desalineación), contención de bloqueos (locks) en el hypervisor, o planificación de vCPUs sin pinning a través de nodos NUMA.

#### Comando de diagnóstico y análisis de salida
Ejecute `kvm_stat` para aislar los eventos de salida (exit):

```bash
$ sudo kvm_stat -1
Event                                   Total      %CurAvg/s
 ept_violation                          891240        45210
 irq_exits                              412090        12040
 io_instruction                          98240          410
 kvm_entry                             1401570        57660
 kvm_exit                              1401560        57650
```

> **Análisis**: `ept_violation` a $45.210/\text{seg}$ indica que el guest está provocando continuamente salidas por fallos de página a nivel de hardware.

#### Paso de mitigación
Verifique y asigne **Hugepages explícitas de 1GiB** en el host y vincule la memoria al nodo NUMA local:

```bash
# Check current Hugepages allocation on host
$ cat /proc/meminfo | grep -i hugepages
HugePages_Total:      16
HugePages_Free:        0
Hugepagesize:    1048576 kB

# Dynamically allocate 16x 1GiB Hugepages on NUMA Node 0
$ echo 16 | sudo tee /sys/devices/system/node/node0/hugepages/hugepages-1048576kB/nr_hugepages
```

---

### 5.2 Problema 2: Latencia de I/O de almacenamiento y bloqueos por contención de hilos
* **Síntoma**: Alta espera de I/O en el guest (`iowait` $> 30\%$) durante operaciones de escritura intensivas, cuellos de botella en el rendimiento del disco y congelamientos ocasionales de la VM en QEMU.
* **Causa raíz**: Uso del almacenamiento en caché de páginas del host (`cache='writeback'`) que provoca vaciados (flushes) en el buffer de escritura del host, o ejecución del almacenamiento en un solo hilo en el bucle principal de eventos de QEMU en lugar de usar `iothreads` dedicados.

#### Comando de diagnóstico y análisis de salida
Verifique las estadísticas de ejecución del disco mediante `virsh`:

```bash
$ virsh domblkstat prod-app-vm01 sda --extended
Device: sda
  rd_req: 140912
  rd_bytes: 4912048128
  rd_total_times: 120491823
  wr_req: 981240
  wr_bytes: 18491024896
  wr_total_times: 981240918241
  flush_req: 12401
  flush_total_times: 891240182
```

Calcule la latencia de escritura:
$$\text{Latencia promedio de escritura} = \frac{\text{wr\_total\_times}}{\text{wr\_req}} = \frac{981240918241 \text{ ns}}{981240} \approx 1.0 \text{ ms (Alta para NVMe local)}$$

#### Paso de mitigación
1. Edite el XML del dominio (`virsh edit prod-app-vm01`).
2. Asegúrese de que `<driver name='qemu' type='qcow2' cache='none' io='native'/>` esté configurado para omitir la caché de páginas del host y utilizar AIO nativo de Linux (`io='native'`).
3. Vincule los controladores de disco a IOThreads aislados:

```xml
<iothreads>2</iothreads>
<cputune>
  <iothreadpin iothread='1' cpuset='0'/>
  <iothreadpin iothread='2' cpuset='1'/>
</cputune>
```

---

### 5.3 Problema 3: Degradación de latencia de memoria entre nodos NUMA cruzados
* **Síntoma**: Degradación aleatoria no explicada en el rendimiento de cómputo del $20\% - 40\%$ en hosts con sistemas multi-socket.
* **Causa raíz**: Los hilos de vCPU se planifican en el Socket de CPU 0, mientras que las asignaciones de memoria del guest se asignan a DIMMs de RAM conectados al Nodo NUMA 1 (cuello de botella de interconexión UPI/QPI).

#### Comando de diagnóstico y análisis de salida
Verifique la topología NUMA del host y la ubicación de los hilos de la VM utilizando `numactl`:

```bash
$ numactl --hardware
available: 2 nodes (0-1)
node 0 cpus: 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15
node 0 size: 128842 MB
node 1 cpus: 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31
node 1 size: 129012 MB
node distances:
node   0   1
  0:  10  21
  1:  21  10

# Check process memory allocation across nodes for QEMU PID
$ numastat -c qemu-system-x86_64

Per-node process memory usage (in MBs):
Node 0          Node 1           Total
--------------  --------------  --------------
  2048.12        14335.88        16384.00
```

> **Análisis**: La memoria está dividida entre el Nodo 0 y el Nodo 1, lo que provoca accesos remotos a memoria entre nodos a través de interconexiones UPI de alta latencia.

#### Paso de mitigación
Aplique una asignación de memoria NUMA estricta que coincida con el pinning de vCPU en libvirt:

```xml
<cputune>
  <vcpupin vcpu='0' cpuset='0'/>
  <vcpupin vcpu='1' cpuset='1'/>
  <vcpupin vcpu='2' cpuset='2'/>
  <vcpupin vcpu='3' cpuset='3'/>
  <emulatorpin cpuset='0-1'/>
</cputune>
<numatune>
  <memory mode='strict' nodeset='0'/>
</numatune>
```

---

### 5.4 Problema 4: Caída de paquetes en red VirtIO y agotamiento del buffer de anillos (Ring Buffer Starvation)
* **Síntoma**: Alta pérdida de paquetes de red bajo carga pesada, elevadas retransmisiones TCP, rendimiento degradado en interfaces de 10G/40G.
* **Causa raíz**: Agotamiento del ring buffer de VirtIO (el valor predeterminado de `rx_queue_size` de 256 es demasiado pequeño) o falta de escalado multi-queue en `vhost-net`.

#### Comando de diagnóstico y análisis de salida
Inspeccione las caídas de paquetes en la interfaz `vnet` del host:

```bash
$ ethtool -S vnet0
NIC statistics:
     rx_packets: 4192041
     rx_bytes: 9812490182
     rx_drop: 142091
     rx_errors: 0
     tx_packets: 2094012
     tx_bytes: 490128401
     tx_drop: 0
```

#### Paso de mitigación
Incremente los límites del ring buffer y habilite multi-queue coincidiendo con la cantidad de vCPUs en el XML del dominio:

```xml
<interface type='bridge'>
  <source bridge='br0'/>
  <model type='virtio'/>
  <driver name='vhost' queues='4' rx_queue_size='1024' tx_queue_size='1024'/>
</interface>
```

Dentro del Guest OS, habilite el procesamiento de paquetes multi-queue en la interfaz:
```bash
$ sudo ethtool -L eth0 combined 4
```

---

## 6. Referencias

* **Linux Professional Institute LPIC-3 305 Overview**:  
  https://www.lpi.org/our-certifications/lpic-3-305-overview/
* **QEMU Documentation & Architecture**:  
  https://www.qemu.org/documentation/
* **Libvirt Domain XML Format Reference**:  
  https://libvirt.org/formatdomain.html
* **Kernel-based Virtual Machine (KVM) Architecture Documentation**:  
  https://www.kernel.org/doc/html/latest/virt/kvm/index.html
* **Red Hat Enterprise Linux 9 Virtualization Management & Tuning Guide**:  
  https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/configuring_and_managing_virtualization/