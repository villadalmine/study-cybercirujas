# Examen LPIC-3 305-300 (v3.0) — Tema 351: Full Virtualization

**Tema del examen:** 351: Full Virtualization  
**Peso:** 33.33 (Cobertura exhaustiva en todos los objetivos 351.1–351.5)  
**Nivel objetivo:** Senior SRE / Principal Platform Architect  
**Documentación oficial de referencia:**
*   [LPI LPIC-3 305 Objectives](https://www.lpi.org/our-certifications/lpic-3-305-overview/)
*   [KVM Kernel Documentation](https://www.kernel.org/doc/html/latest/virt/kvm/index.html)
*   [QEMU Official Documentation](https://www.qemu.org/documentation/)
*   [Libvirt Architecture & XML Format](https://libvirt.org/formatdomain.html)
*   [Xen Project Official Documentation](https://xenproject.org/help/documentation/)
*   [Libguestfs Documentation](https://libguestfs.org/)

---

## Descripción general de la arquitectura técnica

La Full Virtualization se basa en extensiones de virtualización asistidas por hardware introducidas por los fabricantes de CPU (Intel VT-x / AMD-V) para interceptar (trap) operaciones de CPU privilegiadas sin traducción binaria.

```
+-----------------------------------------------------------------------+
|                         GUEST OS (User / Kernel)                       |
|                   Executes in Ring 0/3 (VMX Non-Root Mode)            |
+-----------------------------------------------------------------------+
                                    |
                            VM-Exit | VM-Resume
                                    v
+-----------------------------------------------------------------------+
|                            HOST KERNEL (KVM)                          |
|    Executes in Ring 0 (VMX Root Mode) - Manages EPT/NPT, vCPU Scheduling |
+-----------------------------------------------------------------------+
                                    ^
                                    | /dev/kvm ioctl()
                                    v
+-----------------------------------------------------------------------+
|                                QEMU CLI / Process                     |
|           User-space device emulation (VirtIO, ACPI, PCI Bus)         |
+-----------------------------------------------------------------------+
                                    ^
                                    | RPC / UNIX Domain Socket
                                    v
+-----------------------------------------------------------------------+
|                                LIBVIRTD                               |
|        Domain XML translation, Cgroups allocation, Network Bridges   |
+-----------------------------------------------------------------------+
```

---

## Lab Block 1: Extensiones de virtualización por hardware y teoría de hipervisores (Objetivo 351.1)

### Pasos de ejecución

1. Ejecutá una verificación de bajo nivel de las flags de la CPU del host para verificar las extensiones de virtualización asistida por hardware y las capacidades de Second Level Address Translation (SLAT / Intel EPT o AMD NPT):

```bash
lscpu | grep -E "Virtualization|Hypervisor|flags"
```

*Resultado esperado:*
```text
Virtualization:                  VT-x
Hypervisor vendor:               KVM
Virtualization type:             full
Flags:                           fpu vme de pse tsc msr pae mce cx8 apic sep mtrr pge mca cmov pat pse36 clflush dts acpi mmx fxsr sse sse2 ss ht tm pbe syscall nx pdpe1gb rdtscp lm constant_tsc arch_perfmon pebs bts rep_good nopl xtopology nonstop_tsc cpuid aperfmperf pni pclmulqdq dtes64 monitor ds_cpl vmx smx est tm2 ssse3 sdbg fma cx16 xtpr pdcm pcid sse4_1 sse4_2 x2apic movbe popcnt tsc_deadline_timer aes xsave avx f16c rdrand hypervisor lahf_lm abm 3dnowprefetch cpuid_fault epb cat_l3 cdp_l3 invpcid_single intel_pt ssbd mba ibrs ibpb stibp tpr_shadow vnmi flexpriority ept vpid ept_ad fsgsbase tsc_adjust bmi1 avx2 smep bmi2 erms invpcid rtm cqm mpx rdt_a avx512f avx512dq rdseed adx smap clflushopt clwb avx512cd avx512bw avx512vl xsaveopt xsavec xgetbv1 xsaves cqm_llc cqm_occup_llc cqm_mbm_total cqm_mbm_local dtherm ida arat pln pts md_clear flush_l1d arch_capabilities
```

2. Confirmá que el módulo del kernel `/dev/kvm` esté cargado e inspeccioná el estado de la virtualización anidada (nested virtualization):

```bash
ls -l /dev/kvm
cat /sys/module/kvm_intel/parameters/nested
```

*Resultado esperado:*
```text
crw-rw----+ 1 root kvm 10, 232 Aug  6 14:22 /dev/kvm
Y
```

3. Interrogá el subsistema de gestión de memoria del host para verificar el soporte de HugeTLB utilizado por los hipervisores para eliminar la latencia de page table walk en EPT/NPT:

```bash
grep -i Huge /proc/meminfo
```

*Resultado esperado:*
```text
AnonHugePages:         0 kB
ShmemHugePages:        0 kB
FileHugePages:         0 kB
HugePages_Total:    4096
HugePages_Free:     4096
HugePages_Rsvd:        0
HugePages_Surp:        0
Hugepagesize:       2048 kB
Hugetlb:         8388608 kB
```

---

### Preguntas de comprensión — Bloque 1

**Pregunta 1.1:** ¿Qué transición física ocurre a nivel de hardware de la CPU cuando una máquina virtual guest que opera bajo Intel VT-x ejecuta una instrucción de kernel no privilegiada que requiere la intervención del hipervisor (como modificar el Control Register `CR3` o activar una lectura de puerto de I/O)?  
**Pregunta 1.2:** En un entorno de producción de alto rendimiento (high-throughput), ¿qué balance/compromiso (architectural trade-off) ocurre al elegir entre Para-Virtualization (PV) y Full Virtualization con asistencia por hardware (HVM)?

---

## Lab Block 2: Invocación de QEMU a bajo nivel y control mediante Monitor (Objetivo 351.3)

### Pasos de ejecución

1. Iniciá un proceso de QEMU aislado directamente desde la CLI utilizando aceleración por hardware explícita, dispositivos VirtIO modernos y exponiendo una interfaz de QEMU Monitor UNIX socket:

```bash
qemu-system-x86_64 \
  -name production-node-01,process=qemu:prod-node-01 \
  -machine q35,accel=kvm \
  -cpu host \
  -m 2048 \
  -smp 2,sockets=1,cores=2,threads=1 \
  -drive file=/var/lib/libvirt/images/prod-node-01.qcow2,if=virtio,format=qcow2,aio=native,cache=none \
  -netdev tap,id=net0,ifname=tap0,script=no,downscript=no \
  -device virtio-net-pci,netdev=net0,mac=52:54:00:fa:12:34 \
  -monitor unix:/var/run/qemu-prod-node-01.sock,server,nowait \
  -nographic \
  -daemonize
```

2. Confirmá el proceso en ejecución, observando la asignación de hilos (thread allocation) y la afinidad de asignación de CPU (CPU pin affinity):

```bash
ps aux | grep qemu-system-x86_64
```

*Resultado esperado:*
```text
root     14209  3.2  4.1 3241052 684200 ?      Ssl  14:30   0:12 qemu-system-x86_64 -name production-node-01,process=qemu:prod-node-01 -machine q35,accel=kvm -cpu host -m 2048 -smp 2,sockets=1,cores=2,threads=1 -drive file=/var/lib/libvirt/images/prod-node-01.qcow2,if=virtio,format=qcow2,aio=native,cache=none -netdev tap,id=net0,ifname=tap0,script=no,downscript=no -device virtio-net-pci,netdev=net0,mac=52:54:00:fa:12:34 -monitor unix:/var/run/qemu-prod-node-01.sock,server,nowait -nographic -daemonize
```

3. Conectate a la interfaz en tiempo de ejecución QEMU Human Monitor Interface (HMP) a través de `socat` para inspeccionar el estado del hardware del guest en tiempo de ejecución:

```bash
echo "info kvm" | socat - UNIX-CONNECT:/var/run/qemu-prod-node-01.sock
echo "info cpus" | socat - UNIX-CONNECT:/var/run/qemu-prod-node-01.sock
echo "info block" | socat - UNIX-CONNECT:/var/run/qemu-prod-node-01.sock
```

*Resultado esperado:*
```text
QEMU 8.2.2 monitor - type 'help' for more information
(qemu) info kvm
kvm support: enabled
(qemu) info cpus
* CPU #0: thread_id=14211 core_id=0 smp_thread_id=0 (halted)
  CPU #1: thread_id=14212 core_id=1 smp_thread_id=0 (halted)
(qemu) info block
virtio0 (#block104): /var/lib/libvirt/images/prod-node-01.qcow2 (qcow2)
    Attached to:      /machine/peripheral-anon/device[0]
    Cache mode:       writeback, direct
```

---

### Preguntas de comprensión — Bloque 2

**Pregunta 2.1:** ¿Cuál es la implicación precisa de rendimiento al configurar `-drive cache=none,aio=native` frente a `-drive cache=writeback,aio=threads` en una carga de trabajo de base de datos en producción alojada en QEMU/KVM?  
**Pregunta 2.2:** ¿Por qué `-device virtio-net-pci` es superior en throughput y sobrecarga de CPU (CPU overhead) en comparación con `-device e1000`? Explicá la interacción entre los drivers del guest y los ring buffers del host.

---

## Lab Block 3: Arquitectura Xen, gestión de Dom0 y DomU (Objetivo 351.2)

### Pasos de ejecución

1. Inspeccioná el estado del hipervisor Xen desde el Domain 0 (Dom0) utilizando la herramienta de gestión de Xen `xl`:

```bash
xl info
```

*Resultado esperado:*
```text
host                   : xen-hypervisor-node01
release                : 6.1.0-18-amd64
version                : #1 SMP PREEMPT_DYNAMIC Debian 6.1.76-1
machine                : x86_64
nr_cpus                : 16
max_cpu_id             : 15
nr_nodes               : 1
cores_per_socket       : 8
threads_per_core       : 2
cpu_mhz                : 2994.120
hw_caps                : bfebfbff:77faf3bf:2c100800:00000001:00000001:00000000:00000000:00000000
virt_caps              : hvm hvm_directio pv
total_memory           : 65536
free_memory            : 49152
sharing_freed_memory   : 0
outstanding_claims     : 0
xen_major              : 4
xen_minor              : 17
xen_extra              : .2
xen_caps               : xen-3.0-x86_64 xen-3.0-x86_32p hvm-3.0-x86_32 hvm-3.0-x86_32p hvm-3.0-x86_64
xen_scheduler          : credit2
xen_pagesize           : 4096
platform_params        : virt_start=0xffff800000000000
xen_changeset          : 
xen_commandline        : placeholder dom0_mem=16384M,max:16384M dom0_max_vcpus=4 loglvl=all guest_loglvl=all
cc_compiler            : gcc (Debian 12.2.0-14) 12.2.0
cc_date                : Wed Feb  7 12:00:00 UTC 2024
build_by               : pkg-xen-devel@lists.alioth.debian.org
build_date             : Wed Feb  7 12:00:00 UTC 2024
```

2. Sintetizá un archivo de configuración `/etc/xen/domu-srv01.cfg` listo para producción para un Domain U (DomU) de Xen totalmente virtualizado (HVM):

```bash
cat << 'EOF' > /etc/xen/domu-srv01.cfg
# Xen DomU Configuration File — LPIC-3 Production Standard
type = "hvm"
name = "domu-srv01"
uuid = "a4c28f32-7b89-4e12-b91c-99d82e11fa02"
memory = 4096
maxmem = 8192
vcpus = 4
maxvcpus = 8

# Hardware Acceleration & Nesting Settings
builder = "hvm"
hap = 1
nestedhvm = 1

# Storage Interfaces
disk = [
    'format=qcow2, vdev=xvda, access=rw, target=/var/lib/xen/images/domu-srv01.qcow2',
    'format=raw, vdev=xvdb, access=rw, target=/dev/vg_xen/lv_domu_data'
]

# Networking Configuration
vif = [
    'mac=00:16:3e:54:1a:8b, bridge=xenbr0, script=vif-bridge, model=e1000'
]

# Boot Behavior & Console
boot = "c"
sdl = 0
vnc = 1
vnclisten = "127.0.0.1"
vncpasswd = "SecureClusterPasscode123!"

on_poweroff = "destroy"
on_reboot = "restart"
on_crash = "restart"
EOF
```

3. Aprovisioná y monitoreá la instancia activa de Xen DomU:

```bash
xl create /etc/xen/domu-srv01.cfg
xl list
xl top -b -n 1
```

*Resultado esperado:*
```text
Parsing config file /etc/xen/domu-srv01.cfg
Name                                        ID   Mem VCPUs	State	Time(s)
Domain-0                                     0 16384     4     r-----     142.5
domu-srv01                                   1  4096     4     -b----       0.8

xentop - 14:35:02 Xen 4.17.2
2 domains: 1 running, 1 blocked, 0 paused, 0 crashed, 0 dying, 0 shutdown
Mem: 67108864k total, 41943040k used, 25165824k free    CPUs: 16 @ 2994MHz
NAME      STATE   CPU(sec) CPU(%)  MEM(k) MEM(%)  MAXMEM(k) MAXMEM(%) VCPUS NETS NETCNT VBD VBD_OO   REQ-1  WR-1 RD-1
Domain-0  rb----       143    2.1 16777216   25.0   16777216      25.0     4    1      0   0      0       0     0    0
domu-srv01 --b---         1    0.2  4194304    6.2    8388608      12.5     4    1      0   2      0     120    85   35
```

---

### Preguntas de comprensión — Bloque 3

**Pregunta 3.1:** ¿Por qué es imperativo en un despliegue de producción de Xen restringir la memoria del Domain 0 a través del parámetro de línea de comandos de GRUB `dom0_mem=16384M,max:16384M`? ¿Qué sucede si se omite esta restricción?  
**Pregunta 3.2:** Diferenciá entre los drivers PV-on-HVM y la Paravirtualización (PV) pura en Xen. ¿Cómo se comunica el kernel del guest con el hipervisor Xen cuando ejecuta I/O de dispositivos de bloque bajo PV-on-HVM?

---

## Lab Block 4: Arquitectura XML de dominios Libvirt y operaciones avanzadas del ciclo de vida (Objetivo 351.4)

### Pasos de ejecución

1. Creá un manifiesto XML de Libvirt `/tmp/database-vm.xml` listo para producción especificando NUMA pinning, respaldo de memoria dedicada (dedicated memory backing) y dispositivos VirtIO:

```bash
cat << 'EOF' > /tmp/database-vm.xml
<domain type='kvm'>
  <name>database-vm</name>
  <uuid>f310bda4-1cfa-4680-9286-63d1fbb59821</uuid>
  <memory unit='KiB'>8388608</memory>
  <currentMemory unit='KiB'>8388608</currentMemory>
  <memoryBacking>
    <hugepages/>
    <locked/>
  </memoryBacking>
  <vcpu placement='static' cpuset='2-5'>4</vcpu>
  <cputune>
    <vcpupin vcpu='0' cpuset='2'/>
    <vcpupin vcpu='1' cpuset='3'/>
    <vcpupin vcpu='2' cpuset='4'/>
    <vcpupin vcpu='3' cpuset='5'/>
  </cputune>
  <os>
    <type arch='x86_64' machine='pc-q35-8.2'>hvm</type>
    <boot dev='hd'/>
  </os>
  <features>
    <acpi/>
    <apic/>
    <kvm>
      <hidden state='on'/>
    </kvm>
  </features>
  <cpu mode='host-passthrough' check='none'>
    <topology sockets='1' dies='1' cores='4' threads='1'/>
  </cpu>
  <clock offset='utc'>
    <timer name='rtc' tickpolicy='catchup'/>
    <timer name='pit' tickpolicy='delay'/>
    <timer name='hpet' present='no'/>
    <timer name='tsc' mode='native'/>
  </clock>
  <devices>
    <emulator>/usr/bin/qemu-system-x86_64</emulator>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2' cache='none' io='native'/>
      <source file='/var/lib/libvirt/images/database-vm.qcow2'/>
      <target dev='vda' bus='virtio'/>
      <address type='pci' domain='0x0000' bus='0x04' slot='0x00' function='0x0'/>
    </disk>
    <interface type='bridge'>
      <mac address='52:54:00:22:99:aa'/>
      <source bridge='br-prod'/>
      <model type='virtio'/>
      <driver name='vhost' queues='4'/>
      <address type='pci' domain='0x0000' bus='0x01' slot='0x00' function='0x0'/>
    </interface>
    <console type='pty'>
      <target type='serial' port='0'/>
    </console>
    <memballoon model='virtio'>
      <stats period='10'/>
    </memballoon>
  </devices>
</domain>
EOF
```

2. Definí, iniciá y realizá modificaciones en tiempo de ejecución (live runtime modifications) utilizando `virsh`:

```bash
virsh define /tmp/database-vm.xml
virsh start database-vm
virsh setvcpus database-vm 2 --live
virsh vcpupin database-vm
```

*Resultado esperado:*
```text
Domain 'database-vm' defined from /tmp/database-vm.xml
Domain 'database-vm' started

VCPU   CPU Affinity
-----------------------------------------------------------
   0   2
   1   3
   2   4
   3   5
```

3. Compará el estado volátil del XML en tiempo de ejecución frente al estado del archivo XML persistente:

```bash
virsh dumpxml database-vm | grep -A 5 "<vcpu"
virsh dumpxml database-vm --inactive | grep -A 5 "<vcpu"
```

*Resultado esperado:*
```text
  <vcpu placement='static' current='2' cpuset='2-5'>4</vcpu>
  <cputune>
    <vcpupin vcpu='0' cpuset='2'/>
    <vcpupin vcpu='1' cpuset='3'/>
    <vcpupin vcpu='2' cpuset='4'/>
    <vcpupin vcpu='3' cpuset='5'/>
  </cputune>
--
  <vcpu placement='static' cpuset='2-5'>4</vcpu>
  <cputune>
    <vcpupin vcpu='0' cpuset='2'/>
    <vcpupin vcpu='1' cpuset='3'/>
    <vcpupin vcpu='2' cpuset='4'/>
    <vcpupin vcpu='3' cpuset='5'/>
  </cputune>
```

---

### Preguntas de comprensión — Bloque 4

**Pregunta 4.1:** ¿Cuál es la función técnica de `<driver name='vhost' queues='4'/>` definido dentro del bloque de interfaz de red en el XML del dominio de Libvirt?  
**Pregunta 4.2:** Explicá el resultado al ejecutar `virsh edit database-vm` mientras la VM está en ejecución en comparación con aplicar `virsh attach-device database-vm device.xml --config --live`. ¿Qué sucede si el host se reinicia sin pasar `--config`?

---

## Lab Block 5: Ingeniería de imágenes de disco, cadenas de snapshots y diagnósticos con Libguestfs (Objetivo 351.5)

### Pasos de ejecución

1. Creá una imagen base (golden base image) y construí una cadena de superposición de snapshots copy-on-write utilizando `qemu-img`:

```bash
qemu-img create -f qcow2 /var/lib/libvirt/images/base-gold.qcow2 20G
qemu-img create -f qcow2 -b /var/lib/libvirt/images/base-gold.qcow2 -F qcow2 /var/lib/libvirt/images/overlay-snap1.qcow2
qemu-img info --backing-chain /var/lib/libvirt/images/overlay-snap1.qcow2
```

*Resultado esperado:*
```text
image: /var/lib/libvirt/images/overlay-snap1.qcow2
file format: qcow2
virtual size: 20 GiB (21474836480 bytes)
disk size: 196 KiB
cluster_size: 65536
backing file: /var/lib/libvirt/images/base-gold.qcow2
backing file format: qcow2
Format specific information:
    compat: 1.1
    compression type: zlib
    lazy refcounts: false
    refcount bits: 16
    corrupt: false
    extended l2: false

image: /var/lib/libvirt/images/base-gold.qcow2
file format: qcow2
virtual size: 20 GiB (21474836480 bytes)
disk size: 196 KiB
cluster_size: 65536
Format specific information:
    compat: 1.1
    compression type: zlib
    lazy refcounts: false
    refcount bits: 16
    corrupt: false
    extended l2: false
```

2. Realizá una inspección fuera de línea (offline) no destructiva de la estructura del sistema de archivos del disco de la VM utilizando utilidades de `libguestfs` (`virt-filesystems`, `virt-df`):

```bash
virt-filesystems --long -h --all -a /var/lib/libvirt/images/base-gold.qcow2
virt-df -h -a /var/lib/libvirt/images/base-gold.qcow2
```

*Resultado esperado:*
```text
Name       Type        VFS   Label  MBR  Size  Parent
/dev/sda1  filesystem  ext4  -      -    19G   -
/dev/sda2  filesystem  swap  -      -    1.0G  -
/dev/sda   device      -     -      -    20G   -

Filesystem                               Size       Used  Available  Use%
base-gold.qcow2:/dev/sda1                 19G       2.1G        16G   12%
```

3. Ejecutá modificaciones quirúrgicas offline directamente dentro del disco qcow2 sin arrancar una máquina virtual utilizando `guestfish`:

```bash
guestfish --rw -a /var/lib/libvirt/images/overlay-snap1.qcow2 << 'EOF'
run
mount /dev/sda1 /
cat /etc/hostname
touch /root/sre_audit_flag.txt
write /etc/motd "Authorized SRE System Access Only\n"
umount /
exit
EOF
```

4. Realizá un rebase en línea (online) para consolidar los almacenes de respaldo (backing stores), colapsando la superposición de snapshot en un objetivo independiente (standalone target):

```bash
qemu-img rebase -b "" /var/lib/libvirt/images/overlay-snap1.qcow2
qemu-img info /var/lib/libvirt/images/overlay-snap1.qcow2
```

*Resultado esperado:*
```text
image: /var/lib/libvirt/images/overlay-snap1.qcow2
file format: qcow2
virtual size: 20 GiB (21474836480 bytes)
disk size: 2.1 GiB
cluster_size: 65536
Format specific information:
    compat: 1.1
    compression type: zlib
    lazy refcounts: false
    refcount bits: 16
    corrupt: false
    extended l2: false
```

---

### Preguntas de comprensión — Bloque 5

**Pregunta 5.1:** ¿Qué riesgo grave de corrupción de datos se introduce al ejecutar `guestfish --rw` o `virt-customize` en un archivo de imagen de disco de QEMU/KVM mientras el dominio correspondiente está activamente en ejecución?  
**Pregunta 5.2:** Explicá la diferencia estructural entre `qemu-img rebase -b` (modo inseguro sin especificar verificación de formato de respaldo) y `qemu-img commit`. ¿Cuándo debería un SRE utilizar `commit` frente a `rebase`?

---

<details>
<summary>Soluciones y análisis arquitectónicos profundos</summary>

### Respuestas — Bloque de laboratorio 1

**Respuesta 1.1:**  
Cuando una instrucción del guest no privilegiada requiere la intervención del hipervisor, la CPU experimenta una transición a nivel de hardware conocida como **VM-Exit**. Bajo Intel VT-x:
1. El hardware guarda el estado del procesador guest (Control Registers, Instruction Pointer `RIP`, Stack Pointer `RSP`, Segment Registers) en el área Guest-State Area de la VMCS (Virtual Machine Control Structure).
2. El modo de la CPU pasa de **VMX Non-Root Mode** (donde el código guest se ejecuta directamente sobre bare metal en Ring 0/3) a **VMX Root Mode** (donde el Host Kernel / KVM se ejecuta en Ring 0).
3. El hardware carga los estados de los registros del host desde el área Host-State Area de la VMCS y transfiere la ejecución al manejador de VM-Exit de KVM definido en `kvm_intel.ko`.
4. Una vez que KVM/QEMU emula la operación (por ejemplo, actualizando el CR3 virtual o atendiendo la I/O del guest), KVM emite la instrucción `VMLAUNCH` o `VMRESUME`, activando un **VM-Entry** que conmuta la ejecución de nuevo al modo VMX Non-Root.

**Respuesta 1.2:**  
*   **Para-Virtualization (PV):** Modifica el kernel del SO guest para usar hypercalls (llamadas de software explícitas) en lugar de ejecutar instrucciones sensibles de hardware.
    *   *Trade-off:* Máxima eficiencia de I/O y menor sobrecarga de captura de instrucciones (instruction trap overhead) en hardware antiguo que carece de SLAT/VT-x; sin embargo, rompe la portabilidad del kernel (requiere kernels guest modificados conscientes del hipervisor) y no puede ejecutar sistemas operativos propietarios no modificables.
*   **Full Virtualization con asistencia por hardware (HVM):** Se basa en extensiones de hardware (VT-x/AMD-V) y tablas de páginas anidadas (EPT/NPT) para ejecutar sistemas operativos guest sin modificar.
    *   *Trade-off:* Completa compatibilidad y aislamiento del SO; sin embargo, las arquitecturas iniciales de CPU sufrieron penalizaciones de rendimiento debido a frecuentes VM-Exits. Las CPU modernas mitigan esto mediante EPT/NPT, VPID (Virtual Processor ID, evitando vaciados de TLB en VM-Exit) y SR-IOV/vhost-net.

---

### Respuestas — Bloque de laboratorio 2

**Respuesta 2.1:**  
*   `-drive cache=none,aio=native`: Omite completamente el page cache del host mediante flags de apertura `O_DIRECT` y enruta la I/O asíncrona del kernel de Linux (`io_submit`) directamente al hardware de almacenamiento del host.
    *   *Impacto en SRE:* Esencial para bases de datos en producción (PostgreSQL/MySQL/Oracle). Evita el doble almacenamiento en caché (consumir RAM del host para datos que ya están en caché en el buffer pool del guest), elimina los picos de latencia por desalojo de páginas (page eviction) en el host y garantiza la durabilidad de los datos al asegurar que las escrituras alcancen medios no volátiles cuando se emite `fsync`.
*   `-drive cache=writeback,aio=threads`: Enruta las escrituras a través del page cache del host y utiliza un pool de hilos POSIX dentro de QEMU para emular I/O asíncrona.
    *   *Impacto en SRE:* Mayor riesgo de pérdida de datos ante un fallo de energía en el host a menos que esté respaldado por cachés de escritura con batería; somete la memoria del host a presión de memoria y sobrecarga por desalojo de caché.

**Respuesta 2.2:**  
*   `-device e1000` emula un controlador Intel 82545EM Gigabit Ethernet en software. Cada paquete transmitido o recibido requiere que QEMU emule lecturas/escrituras individuales de registros PCI, líneas de interrupción y Memory Mapped I/O (MMIO), lo que causa un consumo masivo de CPU y un alto número de VM-Exits por paquete.
*   `-device virtio-net-pci` implementa el framework estandarizado de I/O paravirtualizado VirtIO. Utiliza ring buffers sin bloqueos en memoria compartida (**Virtqueues** compuestas por Available Rings y Used Rings) entre la RAM del guest y la RAM del host. Los paquetes se transfieren vía DMA sin emular registros de hardware físico, reduciendo las VM-Exits al mínimo y permitiendo el procesamiento a nivel de kernel con vhost-net.

---

### Respuestas — Bloque de laboratorio 3

**Respuesta 3.1:**  
El Domain 0 (Dom0) es el dominio de control privilegiado en Xen responsable de ejecutar los drivers de hardware, gestionar las herramientas del control stack (`xl`, `xenstore`) y enrutar la I/O para los guests no privilegiados Domain U (DomU).
*   Si `dom0_mem` no está fijado, Dom0 reclamará dinámicamente toda la RAM física del host al arrancar. Cuando posteriormente se instancien guests DomU, Xen intentará reducir la memoria de Dom0 sobre la marcha (ballooning down).
*   *Impacto en producción:* El ballooning de memoria bajo carga pesada causa el agotamiento de memoria en Dom0, lo que activa el Out-Of-Memory (OOM) Killer del kernel de Linux dentro de Dom0, matando procesos como `xenstored` o `xl`, provocando kernel panics en el host y caídas a nivel de todo el hipervisor.

**Respuesta 3.2:**  
*   **PV-on-HVM:** Utiliza aceleración por hardware (VT-x/AMD-V) para la ejecución de CPU y memoria (evitando modificaciones del kernel PV), pero instala drivers paravirtualizados de almacenamiento VirtIO/Xen-PV (`xen-blkfront`) y red (`xen-netfront`) dentro del SO guest.
*   *Mecanismo de comunicación:* Al ejecutar I/O de bloque, `xen-blkfront` en DomU escribe descriptores de solicitud en un ring buffer de memoria compartida (**Grant Tables**) asignado entre DomU y Dom0. DomU luego emite una señal al hipervisor Xen a través de un **Event Channel** (interrupción virtual liviana). El driver backend del host (`xen-blkback` en Dom0) lee la referencia de la Grant Table, realiza la I/O en el disco físico y notifica la finalización a través del Event Channel, omitiendo por completo la lenta emulación de hardware de QEMU.

---

### Respuestas — Bloque de laboratorio 4

**Respuesta 4.1:**  
`<driver name='vhost' queues='4'/>` mueve la ruta de datos (data path) de virtio-net fuera del proceso QEMU en espacio de usuario directamente al módulo del kernel del host de Linux `vhost-net.ko`.
*   Establecer `queues='4'` habilita **Multi-Queue VirtIO-Net**. Instancia 4 virtqueues separadas de transmisión/recepción mapeadas a 4 hilos de kernel vhost vinculados a 4 vCPUs dedicadas.
*   *Beneficio en producción:* Elimina los cuellos de botella de CPU de un solo hilo en interfaces de red de alta velocidad (10GbE/40GbE/100GbE), permitiendo que el procesamiento de paquetes de red escale linealmente a través de múltiples núcleos de CPU del host.

**Respuesta 4.2:**  
*   Ejecutar `virsh edit database-vm` edita el **archivo XML de configuración persistente** almacenado en disco (`/etc/libvirt/qemu/database-vm.xml`). Los cambios **no** surten efecto en la instancia del dominio actualmente en ejecución; solo se aplican después de que el dominio se apague por completo y se reinicie.
*   Aplicar `virsh attach-device ... --config --live` actualiza tanto el estado de la instancia del hipervisor en ejecución (RAM volátil) COMO el archivo XML persistente en disco.
*   *Riesgo al reiniciar:* Si se omite `--config` y solo se usa `--live`, el dispositivo se conecta en caliente (hot-plug) a la VM en ejecución de inmediato, pero el cambio se pierde tan pronto como la VM se detiene o el hipervisor del host se reinicia, causando una desviación de configuración (configuration drift).

---

### Respuestas — Bloque de laboratorio 5

**Respuesta 5.1:**  
Ejecutar `guestfish --rw` o cualquier herramienta de modificación en un archivo de imagen de disco de una máquina virtual activa y en ejecución conduce a una inmediata y catastrófica **corrupción de metadatos del sistema de archivos**.
*   *Razón:* El kernel del SO guest mantiene buffers de page cache, bloqueos de inodos (inode locks) y mapas de bits de asignación de bloques en su propia memoria. Cuando `guestfish` monta simultáneamente el mismo dispositivo de bloques subyacente, lee distribuciones de bloques desactualizadas y escribe sectores crudos directamente en el disco. El SO guest no se percata de estas modificaciones externas de bloques, lo que resulta en escrituras en el journal conflictivas, inodos huérfanos, clústeres cruzados (cross-linked clusters) y sistemas de archivos destruidos.

**Respuesta 5.2:**  
*   `qemu-img commit`: Consolida todas las modificaciones escritas en una imagen de superposición (overlay) directamente de vuelta en su archivo de respaldo designado (mueve los cambios hacia *abajo* en la cadena: `overlay-snap1.qcow2` -> `base-gold.qcow2`).
*   `qemu-img rebase -b <new_base>`: Cambia el puntero del almacén de respaldo (backing store) de un archivo qcow2 (se mueve a través de la cadena o la *aplana*).
    *   *Rebase seguro (Predeterminado):* QEMU compara los clústeres entre el archivo de respaldo anterior y el nuevo, copiando cualquier diferencia faltante en el archivo de destino para preservar la integridad de los datos.
    *   *Rebase inseguro (`-u`):* Solo actualiza la cadena del encabezado del archivo de respaldo interno sin inspeccionar los contenidos de los bloques.
*   *Regla operacional de SRE:* Utilizá `commit` al aplanar archivos de snapshot temporales de vuelta a una imagen base golden durante ventanas de mantenimiento. Utilizá `rebase` al reorientar VMs a plantillas base actualizadas o al cortar cadenas de respaldo por completo (`qemu-img rebase -b ""`) para crear imágenes independientes para migración.

</details>