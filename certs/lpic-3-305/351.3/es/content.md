# 351.3 QEMU

> **LPIC-3 305-300 · Tema 351: Virtualización completa**
> Peso del objetivo: **6.67** — el objetivo más pesado del tema *Virtualización completa*. QEMU es el emulador de referencia tipo-2/híbrido-tipo-1 en Linux y el motor que hay debajo de los despliegues de libvirt, oVirt, OpenStack Nova, Proxmox, KubeVirt y cloud-hypervisor. Dominalo a nivel de CLI y las herramientas de más alto nivel se vuelven transparentes.

---

## 1. Motivación y el problema arquitectónico de producción

### 1.1 Qué es realmente QEMU

QEMU (Quick EMUlator) son dos cosas fusionadas en una sola base de código, y confundirlas es la raíz de la mayor parte de la confusión operativa:

1. **Un emulador de sistema completo.** `qemu-system-x86_64` construye una *máquina virtual completa* en espacio de usuario: una CPU virtual, un chipset (i440FX o Q35), un controlador de interrupciones, un bus PCI/PCIe, discos, NICs, un adaptador VGA, un reloj de tiempo real, firmware (SeaBIOS u OVMF), etcétera. Cada instrucción del guest y cada acceso a dispositivo pasa por un proceso en el host.

2. **Un traductor binario dinámico.** Cuando no se usa aceleración por hardware, el flujo de instrucciones del guest se compila JIT mediante el **TCG (Tiny Code Generator)** a instrucciones del host. Esto es lo que le permite a `qemu-system-aarch64` correr un guest ARM sobre un host x86 — emulación *cross-ISA*. Es correcto pero lento (a menudo 5–20× más lento).

La conclusión de producción: **casi nunca querés emulación pura para cargas de la misma arquitectura.** Querés QEMU como el *modelo de dispositivos y plano de control* mientras la CPU corre de forma nativa a través de **KVM**. QEMU + KVM es el hipervisor canónico de Linux.

```
        ┌───────────────────────────────────────────────────────────┐
        │                        Guest OS                            │
        │        (unmodified kernel + userspace, ring 0/3)           │
        └───────────────────────────────────────────────────────────┘
              │ privileged instr,      │ MMIO / PIO / virtio
              │ VM exits (VMX/SVM)      │ (device access)
              ▼                         ▼
   ┌──────────────────────┐   ┌───────────────────────────────────┐
   │   KVM (kvm.ko +      │   │   QEMU process (user space)       │
   │   kvm-intel/amd.ko)  │◄──┤   - device model (virtio, PCI)    │
   │   in-kernel:         │   │   - main loop / vCPU threads      │
   │   - vCPU scheduling  │   │   - migration, snapshots          │
   │   - EPT/NPT (MMU)    │   │   - QEMU Monitor (HMP/QMP)        │
   │   - local APIC, PIT  │   │   - block & net backends          │
   └──────────┬───────────┘   └────────────────┬──────────────────┘
              │ ioctl(/dev/kvm)                 │ syscalls, threads
              ▼                                 ▼
   ┌───────────────────────────────────────────────────────────────┐
   │         Host Linux kernel  +  Intel VT-x (VMX) / AMD-V (SVM)   │
   └───────────────────────────────────────────────────────────────┘
```

### 1.2 El problema arquitectónico que esto resuelve

Antes de las extensiones de virtualización por hardware, correr un guest OS sin modificar a velocidad nativa sobre un host compartido era imposible sin alguna de estas opciones:

- **Trap-and-emulate** cada instrucción privilegiada (inviable en x86, cuya ISA tenía ~17 instrucciones "sensibles pero no privilegiadas" que no generan trap), o
- **Traducción binaria** de todo el kernel del guest (el enfoque original de VMware — complejo y lento), o
- **Paravirtualización** — modificar el guest (el enfoque original de Xen — necesita cooperación del guest).

Intel **VT-x (VMX)** y AMD **AMD-V (SVM)** introdujeron un nuevo modo de ejecución de la CPU (modo root vs non-root / guest) más una MMU asistida por hardware (**EPT** en Intel, **NPT/RVI** en AMD) que le permite al guest ejecutar código privilegiado directamente, generando un *VM exit* de vuelta al hipervisor solo en los eventos que genuinamente necesitan mediación (I/O a un dispositivo emulado, ciertas escrituras de MSR, etc.). KVM es el fino módulo del kernel de Linux que maneja este hardware; QEMU es el proceso de espacio de usuario que posee el modelo de dispositivos y el ciclo de vida.

El **enunciado del problema de producción** que un SRE realmente enfrenta:

> "Necesito correr sistemas operativos guest sin modificar a velocidad de CPU/memoria casi nativa, con estado migrable en vivo, discos capaces de snapshot, e I/O de red/almacenamiento que no colapse bajo carga — de forma reproducible, desde una interfaz scriptable, sobre hosts Linux de uso común."

QEMU + KVM es la respuesta, y este objetivo trata de controlarlo directamente en lugar de a través de una abstracción.

---

## 2. Comparaciones técnicas y trade-offs

### 2.1 Back-ends de aceleración (`-accel` / `-machine accel=`)

| Acelerador | Requisito del host | Arch del guest vs host | Velocidad | Uso principal |
|---|---|---|---|---|
| **kvm** | Linux + VT-x/AMD-V, `/dev/kvm` | Solo misma ISA | Casi nativa | **Producción en Linux** |
| **tcg** | Ninguno (software puro) | **Cualquiera** (cross-ISA) | 5–20× más lento | Cross-arch, CI en hosts sin aceleración, desarrollo embebido |
| **hvf** | macOS Hypervisor.framework | Misma ISA | Casi nativa | QEMU en hosts macOS |
| **whpx** | Windows Hypervisor Platform | Misma ISA | Casi nativa | QEMU en hosts Windows |
| **xen** | Xen dom0 | Misma ISA | Casi nativa | QEMU como modelo de dispositivos de Xen (qemu-dm) |
| **nvmm** | NetBSD | Misma ISA | Casi nativa | QEMU en NetBSD |

> En Linux, para el examen LPIC-3 y para producción, los dos que tenés que saber al dedillo son **kvm** (acelerado por hardware, misma arch) y **tcg** (software, cross-arch). `-accel kvm:tcg` significa "usá KVM, caé a TCG si no está disponible" — útil en scripts portables y CI.

### 2.2 Tipos de máquina (chipset)

| Máquina (`-machine`) | Chipset | Bus | Firmware por defecto | PCIe / hotplug | Cuándo usarlo |
|---|---|---|---|---|---|
| **pc / pc-i440fx-\*** | Intel 440FX (1996) | PCI | SeaBIOS | Solo PCI | Guests legacy, máxima compatibilidad, Windows antiguos |
| **q35 / pc-q35-\*** | Intel Q35 (2007) | PCIe | SeaBIOS (u OVMF) | PCIe nativo, mejor hotplug, IOMMU/VT-d, passthrough PCIe | **Por defecto para guests modernos, passthrough de GPU/NIC** |
| **microvm** | mínimo, sin PCI | virtio MMIO | ninguno (kernel directo) | limitado | Sandboxes de arranque rápido, cargas estilo Firecracker |
| **virt** (aarch64) | placa ARM virt | PCIe (GICv3) | OVMF/edk2 | sí | Guests ARM64 |

Fijá la variante *versionada* (`pc-q35-8.2`) en producción, no el alias móvil `q35` — el alias cambia entre versiones de QEMU y altera de forma silenciosa el hardware visible para el guest, lo que rompe la migración en vivo entre hosts que corren distintas versiones de QEMU.

### 2.3 Interfaz de disco + formato de imagen

| Dimensión | Opciones | Trade-off |
|---|---|---|
| **Bus** | `virtio-blk`, `virtio-scsi`, `ide`, `ahci/sata`, `nvme` | virtio = paravirtualizado, el más rápido, necesita drivers en el guest. `virtio-scsi` soporta muchos discos + discard/TRIM + SCSI passthrough. `ide`/`ahci` = universal pero lento, usalo solo para medios de instalación / guests muy viejos. |
| **Formato** | `raw`, `qcow2` | `raw` = máximo rendimiento, sin funciones. `qcow2` = thin provisioning, snapshots internos, backing files, compresión, cifrado — pequeño overhead. |
| **cache** | `none`, `writeback`, `writethrough`, `directsync`, `unsafe` | `none` (O_DIRECT, bypass de la page cache del host) es el default de producción por corrección + rendimiento predecible. `writeback` es más rápido pero depende de los flush del guest. `unsafe` ignora los flush — solo benchmarks/descartables. |
| **aio** | `threads`, `native`, `io_uring` | `native` (Linux AIO) con `cache=none`; `io_uring` (QEMU 5.0+, kernel 5.1+) es lo mejor moderno para IOPS altos. `threads` es el fallback portable. |

### 2.4 Back-ends de red

| Back-end (`-netdev`) | Privilegio del host | Rendimiento | ¿Guest alcanzable desde la LAN? | Uso típico |
|---|---|---|---|---|
| **user** (SLIRP) | ninguno (sin privilegios) | Bajo (TCP/IP en espacio de usuario) | No (NAT, necesita hostfwd) | Laptops, pruebas rápidas, sin root |
| **tap** | root / CAP_NET_ADMIN | Alto (especialmente con vhost) | Sí (vía bridge del host) | **Producción** |
| **bridge** (helper) | helper setuid | Alto | Sí | tap sin root completo, vía `qemu-bridge-helper` |
| **macvtap** | root | Muy alto (evita el bridge) | Sí | Hosts densos, baja latencia; los guests no pueden hablar con el host por defecto |
| **socket / l2tpv3** | ninguno | medio | inter-QEMU | Mallas VM-a-VM, bancos de prueba |

**vhost-net** (`vhost=on`) mueve el data path de virtio-net al kernel, eliminando los exits por paquete al proceso de usuario de QEMU — obligatorio para red a velocidad de línea. **Multiqueue** (`queues=N` + `mq=on`) escala una sola NIC a través de los vCPUs.

---

## 3. Verificar la plataforma (hacé esto antes que nada)

### 3.1 ¿Están presentes y habilitadas las extensiones de virtualización?

```console
$ egrep -c '(vmx|svm)' /proc/cpuinfo
16
```

Un conteo distinto de cero significa que la CPU *soporta* VT-x (`vmx`, Intel) o AMD-V (`svm`, AMD). Cero significa o bien una CPU vieja **o** que las extensiones están deshabilitadas en el firmware/BIOS (la causa más común en servidores recién instalados).

```console
$ lscpu | grep -i virtual
Virtualization:                  VT-x
Virtualization type:             full
```

### 3.2 ¿Están cargados los módulos del kernel de KVM?

```console
$ lsmod | grep kvm
kvm_intel             389120  6
kvm                  1339392  1 kvm_intel
irqbypass              16384  1 kvm
```

El módulo genérico `kvm` es neutral respecto de la arquitectura; el módulo del fabricante es **`kvm_intel`** (se carga vía `kvm-intel`) o **`kvm_amd`** (se carga vía `kvm-amd`). Si falta:

```console
$ sudo modprobe kvm-intel
$ dmesg | tail -3
[  512.004311] kvm: Nested Virtualization enabled
[  512.004556] SVM: kvm: Nested Paging enabled
[  512.010992] kvm_intel: VMX enabled
```

Falla común — extensiones deshabilitadas en la BIOS:

```console
$ sudo modprobe kvm-intel
modprobe: ERROR: could not insert 'kvm_intel': Operation not supported
$ dmesg | tail -2
[  318.117733] kvm: disabled by bios
[  318.117740] kvm_intel: VMX not supported by CPU 0
```

→ Reiniciá, habilitá **Intel VT-x / "Intel Virtualization Technology"** o **AMD SVM / "SVM Mode"** en la configuración del firmware.

### 3.3 ¿Existe `/dev/kvm` y es accesible?

`/dev/kvm` es el dispositivo de caracteres a través del cual QEMU emite llamadas `ioctl()` para crear VMs, vCPUs y regiones de memoria. Su presencia es la prueba definitiva de que KVM es utilizable.

```console
$ ls -l /dev/kvm
crw-rw----+ 1 root kvm 10, 232 Aug 11 09:14 /dev/kvm

$ getent group kvm
kvm:x:36:libvirt-qemu,sre

$ id -nG | tr ' ' '\n' | grep -x kvm
kvm
```

Un usuario necesita pertenecer al grupo **`kvm`** (o una ACL equivalente) para correr VMs aceleradas sin root:

```console
$ sudo usermod -aG kvm "$USER"      # re-login for the group to take effect
```

### 3.4 El chequeo de sanidad de un solo comando: `kvm-ok`

```console
$ sudo kvm-ok
INFO: /dev/kvm exists
KVM acceleration can be used
```

Forma de falla:

```console
$ sudo kvm-ok
INFO: Your CPU does not support KVM extensions
INFO: For more detailed results, you should run this as root
HINT:   sudo /usr/sbin/kvm-ok
KVM acceleration can NOT be used
```

`kvm-ok` viene en el paquete `cpu-checker` (Debian/Ubuntu). En hosts de la familia RHEL, usá `virt-host-validate`:

```console
$ virt-host-validate qemu
  QEMU: Checking for hardware virtualization                                 : PASS
  QEMU: Checking if device /dev/kvm exists                                   : PASS
  QEMU: Checking if device /dev/kvm is accessible                            : PASS
  QEMU: Checking if device /dev/vhost-net exists                             : PASS
  QEMU: Checking if IOMMU is enabled by kernel                               : PASS
  QEMU: Checking for cgroup 'cpu' controller support                         : PASS
  QEMU: Checking for cgroup 'memory' controller support                      : PASS
```

### 3.5 Comprobar que el propio QEMU ve KVM

```console
$ qemu-system-x86_64 --version
QEMU emulator version 8.2.2 (Debian 1:8.2.2+ds-0ubuntu1)
Copyright (c) 2003-2023 Fabrice Bellard and the QEMU Project developers

$ qemu-system-x86_64 -accel help
Accelerators supported in QEMU binary:
tcg
kvm

$ qemu-system-x86_64 -M q35 -accel kvm -cpu host -display none -monitor stdio \
    -S -m 256 <<< 'info kvm'
QEMU 8.2.2 monitor - type 'help' for more information
(qemu) info kvm
kvm support: enabled
(qemu) quit
```

`kvm support: enabled` dentro del monitor es la confirmación definitiva. Si dice `disabled`, QEMU cayó a TCG.

---

## 4. Iniciar máquinas virtuales desde la línea de comandos

### 4.1 El mínimo absoluto, y después una invocación de producción

**Mínimo, entendelo primero:**

```console
$ qemu-system-x86_64 -accel kvm -m 2048 -cdrom debian-12-netinst.iso
```

Eso arranca la ISO con los valores por defecto (i440FX, un vCPU, una NIC e1000 emulada sobre red de usuario, VGA Cirrus). Está bien para aprender; está mal para producción. Abajo hay un comando **completo, con forma de producción** que podés pegar, comentado línea por línea.

```console
$ qemu-system-x86_64 \
    -name guest=web01,debug-threads=on \
    -machine type=q35,accel=kvm \
    -cpu host,migratable=on \
    -smp cpus=4,sockets=1,cores=4,threads=1 \
    -m size=4096,slots=4,maxmem=16384 \
    -object memory-backend-memfd,id=mem0,size=4096M,hugetlb=on,hugetlbsize=2M,share=on \
    -numa node,memdev=mem0 \
    -drive if=none,id=root,file=/var/lib/vm/web01.qcow2,format=qcow2,cache=none,aio=io_uring,discard=unmap \
    -device virtio-blk-pci,drive=root,bootindex=1,iommu_platform=on \
    -blockdev '{"driver":"file","filename":"/isos/seed.iso","node-name":"seed"}' \
    -device virtio-scsi-pci,id=scsi0 \
    -device scsi-cd,drive=seed \
    -netdev tap,id=net0,ifname=tap-web01,script=no,downscript=no,vhost=on,queues=4 \
    -device virtio-net-pci,netdev=net0,mac=52:54:00:12:34:56,mq=on,vectors=10 \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE.fd \
    -drive if=pflash,format=raw,file=/var/lib/vm/web01_VARS.fd \
    -rtc base=utc,driftfix=slew \
    -boot order=c,menu=on,strict=on \
    -serial mon:stdio \
    -qmp unix:/var/run/qemu/web01.qmp,server=on,wait=off \
    -device virtio-balloon-pci \
    -device virtio-rng-pci,rng=rng0 \
    -object rng-random,id=rng0,filename=/dev/urandom \
    -display none \
    -daemonize
```

**Familias de parámetros clave que tenés que saber para el examen** (`-boot`, `-drive`, `-cdrom`, `-smp`, `-m`, `-net`/`-nic`/`-netdev`/`-device`):

| Parámetro | Propósito | Detalle crítico para el examen |
|---|---|---|
| `-m size,slots,maxmem` | RAM del guest + envoltura de hotplug | `-m 4096` = 4 GiB; `slots`/`maxmem` habilitan hotplug de memoria |
| `-smp cpus,sockets,cores,threads` | Topología de vCPU | `-smp 4` ≡ `cpus=4`; la topología explícita importa para NUMA/licenciamiento |
| `-cpu` | Modelo de CPU expuesto al guest | `host` = pasa todas las funciones del host (el más rápido, no portable); modelos con nombre (`Skylake-Server`, `EPYC`) para compatibilidad de migración |
| `-drive` / `-blockdev` | Back-end de bloques | `if=none`+`-device` es la separación moderna; `if=virtio` el atajo legacy |
| `-cdrom file.iso` | Atajo para un CD-ROM IDE de solo lectura | Equivalente a `-drive file=file.iso,media=cdrom` |
| `-boot order=,menu=,once=` | Orden de dispositivos de arranque | `order=dc` = CD y después disco; `once=d` = CD solo en este arranque |
| `-netdev` + `-device` | NIC moderna (separación back-end + front-end) | Preferido; desacopla la infraestructura del host del modelo de NIC del guest |
| `-nic` | Conveniencia: netdev+device en uno | `-nic user,model=virtio-net-pci,hostfwd=tcp::2222-:22` |
| `-net` | Sintaxis **legacy** basada en hub | Obsoleta; sabé que existe (`-net nic`/`-net tap`/`-net user`) pero preferí `-netdev`/`-nic` |

### 4.2 `-drive` vs `-blockdev` vs `-device` — la separación moderna

El viejo `-drive if=virtio` acopla *qué es el disco* con *cómo lo ve el guest*. El QEMU moderno los separa:

- **Back-end** (`-blockdev` / `-drive if=none`): la imagen, formato, cache, aio, backing file.
- **Front-end** (`-device virtio-blk-pci,drive=...`): el controlador virtual al que se enlaza el driver del guest.

Esta separación es lo que hace posibles el **hotplug de bloques, los snapshots en vivo y el mirroring de discos** (`blockdev-mirror`, usado para la migración en vivo de almacenamiento).

### 4.3 Red: las tres formas que tenés que poder escribir a mano

**(a) Red de usuario (SLIRP), sin root, con reenvío de puertos:**

```console
$ qemu-system-x86_64 -accel kvm -m 2048 \
    -nic user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:2222-:22 \
    -drive file=guest.qcow2,if=virtio,cache=none,aio=io_uring
# then from the host:  ssh -p 2222 user@127.0.0.1
```

**(b) TAP sobre un bridge de Linux (producción):** primero armá la infraestructura del host (Sección 5), luego:

```console
$ sudo qemu-system-x86_64 -accel kvm -m 4096 -cpu host -smp 4 \
    -drive if=none,id=d0,file=web01.qcow2,format=qcow2,cache=none,aio=io_uring \
    -device virtio-blk-pci,drive=d0 \
    -netdev tap,id=n0,ifname=tap0,script=no,downscript=no,vhost=on \
    -device virtio-net-pci,netdev=n0,mac=52:54:00:aa:bb:cc \
    -display none -serial mon:stdio
```

**(c) El helper de bridge sin privilegios** (evita root completo; usa el `qemu-bridge-helper` setuid gobernado por `/etc/qemu/bridge.conf`):

```console
$ cat /etc/qemu/bridge.conf
allow br0

$ qemu-system-x86_64 -accel kvm -m 2048 \
    -netdev bridge,id=n0,br=br0 \
    -device virtio-net-pci,netdev=n0 \
    -drive file=guest.qcow2,if=virtio
```

> **Regla de la dirección MAC:** el prefijo OUI `52:54:00` es el rango administrado localmente de QEMU/KVM. Fijá siempre la MAC en producción para que las leases de DHCP y la migración en vivo se mantengan estables; una MAC aleatoria por arranque rompe las reservas y confunde a la fabric.

### 4.4 Preparar imágenes de disco con `qemu-img`

```console
$ qemu-img create -f qcow2 web01.qcow2 40G
Formatting 'web01.qcow2', fmt=qcow2 cluster_size=65536 extended_l2=off compression_type=zlib size=42949672960 lazy_refcounts=off refcount_bits=16

$ qemu-img info web01.qcow2
image: web01.qcow2
file format: qcow2
virtual size: 40 GiB (42949672960 bytes)
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

Imagen *dorada* thin + overlay por VM (cadena de backing copy-on-write — cómo las imágenes de nube se fanean rápido):

```console
$ qemu-img create -f qcow2 -F qcow2 -b /golden/debian12.qcow2 web01.qcow2
Formatting 'web01.qcow2', fmt=qcow2 ... backing_file=/golden/debian12.qcow2 backing_fmt=qcow2 ...

$ qemu-img info --backing-chain web01.qcow2 | grep -E 'image|backing file:'
image: web01.qcow2
backing file: /golden/debian12.qcow2
image: /golden/debian12.qcow2
```

Convertir / comprimir / re-formatear:

```console
$ qemu-img convert -p -O qcow2 -c disk.raw disk-compressed.qcow2
    (100.00/100%)

$ qemu-img check web01.qcow2
No errors were found on the image.
655360/655360 = 100.00% allocated, 0.00% fragmented, 0.00% compressed clusters
Image end offset: 43150802944
```

---

## 5. Infraestructura de red del host — bridges, TAP y los reemplazos modernos de `ip`

El examen lista explícitamente **`ip`**, **`brctl`/`bridge`** y **`tunctl`/`ip tuntap`**. `brctl` (de `bridge-utils`) y `tunctl` (de `uml-utilities`) son las herramientas legacy; `ip` de `iproute2` es su reemplazo moderno de un solo binario. Conocé ambas — los scripts legacy todavía usan las viejas.

### 5.1 Crear un bridge — viejo vs nuevo

**Legacy (`brctl`):**

```console
$ sudo brctl addbr br0
$ sudo brctl addif br0 eno1
$ sudo brctl show
bridge name     bridge id               STP enabled     interfaces
br0             8000.3cecef1a2b3c       no              eno1
$ sudo ip link set br0 up
```

**Moderno (`ip` / `bridge`):**

```console
$ sudo ip link add name br0 type bridge
$ sudo ip link set eno1 master br0
$ sudo ip link set br0 up
$ sudo ip link set eno1 up

$ bridge link show
3: eno1: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 master br0 state forwarding priority 32 cost 4

$ ip -brief link show type bridge
br0              UP             3c:ec:ef:1a:2b:3c <BROADCAST,MULTICAST,UP,LOWER_UP>
```

### 5.2 Crear un dispositivo TAP persistente — viejo vs nuevo

**Legacy (`tunctl`):**

```console
$ sudo tunctl -t tap0 -u sre
Set 'tap0' persistent and owned by uid 1000
```

**Moderno (`ip tuntap`):**

```console
$ sudo ip tuntap add dev tap0 mode tap user sre
$ sudo ip link set tap0 master br0
$ sudo ip link set tap0 up

$ ip -details link show tap0
7: tap0: <NO-CARRIER,BROADCAST,MULTICAST,UP> mtu 1500 qdisc fq_codel master br0 state DOWN mode DEFAULT group default qlen 1000
    link/ether f2:9a:1c:44:aa:01 brd ff:ff:ff:ff:ff:ff promiscuity 1 minmtu 68 maxmtu 65521
    tun type tap pi off vnet_hdr on persist on user sre
    bridge_slave state disabled priority 32 cost 100 ...
```

> `NO-CARRIER`/`state DOWN` en un TAP recién creado es **normal** — un TAP se pone "up" (aparece la portadora) solo cuando un proceso (QEMU) abre `/dev/net/tun` y se le engancha. Diagnosticar "mi tap0 está down" como una falla es la falsa alarma clásica.

### 5.3 Una unidad systemd de red del host completa e idempotente

`/etc/systemd/system/qemu-br0.service` — bridge declarativo + pool de TAP persistentes para un host hipervisor:

```ini
[Unit]
Description=QEMU bridge br0 and TAP pool
After=network-pre.target
Wants=network-pre.target
Before=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
# --- bring up bridge (idempotent) ---
ExecStart=/bin/sh -c 'ip link show br0   >/dev/null 2>&1 || ip link add name br0 type bridge'
ExecStart=/bin/sh -c 'ip link set br0 up'
ExecStart=/bin/sh -c 'ip link show eno1 | grep -q "master br0" || ip link set eno1 master br0'
# --- pre-create a pool of TAPs owned by the qemu user ---
ExecStart=/bin/sh -c 'for i in 0 1 2 3; do \
    ip tuntap show dev tap$i >/dev/null 2>&1 || ip tuntap add dev tap$i mode tap user libvirt-qemu; \
    ip link set tap$i master br0; \
    ip link set tap$i up; \
  done'
# --- teardown ---
ExecStop=/bin/sh -c 'for i in 0 1 2 3; do ip link del tap$i 2>/dev/null || true; done'

[Install]
WantedBy=multi-user.target
```

```console
$ sudo systemctl daemon-reload && sudo systemctl enable --now qemu-br0.service
$ systemctl is-active qemu-br0.service
active
```

### 5.4 Envolver un guest QEMU manual como un servicio gestionado

`/etc/systemd/system/qemu-web01.service`:

```ini
[Unit]
Description=QEMU guest web01
After=qemu-br0.service network-online.target
Requires=qemu-br0.service

[Service]
Type=simple
Restart=on-failure
RestartSec=5
User=libvirt-qemu
Group=kvm
ExecStart=/usr/bin/qemu-system-x86_64 \
    -name web01 \
    -machine type=pc-q35-8.2,accel=kvm \
    -cpu host -smp 4 -m 4096 \
    -drive if=none,id=root,file=/var/lib/vm/web01.qcow2,format=qcow2,cache=none,aio=io_uring \
    -device virtio-blk-pci,drive=root,bootindex=1 \
    -netdev tap,id=net0,ifname=tap0,script=no,downscript=no,vhost=on \
    -device virtio-net-pci,netdev=net0,mac=52:54:00:12:34:56 \
    -qmp unix:/run/qemu/web01.qmp,server=on,wait=off \
    -serial file:/var/log/qemu/web01.console.log \
    -nographic \
    -no-shutdown
ExecStop=/usr/bin/qmp-shell -v /run/qemu/web01.qmp <<< 'system_powerdown'
TimeoutStopSec=60
RuntimeDirectory=qemu
LogsDirectory=qemu

[Install]
WantedBy=multi-user.target
```

### 5.5 Seed de cloud-init para aprovisionamiento sin intervención (el YAML sobre el que corre el mundo adyacente al examen)

QEMU arranca una imagen de nube pelada; **cloud-init** dentro del guest lee un seed ISO NoCloud para configurarse a sí mismo. `user-data`:

```yaml
#cloud-config
hostname: web01
fqdn: web01.leloir.internal
manage_etc_hosts: true

users:
  - name: sre
    groups: [sudo]
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILq...replace-me... sre@leloir

ssh_pwauth: false

packages:
  - qemu-guest-agent
  - nginx

write_files:
  - path: /etc/nginx/conf.d/health.conf
    permissions: '0644'
    content: |
      server {
        listen 8080;
        location = /healthz { return 200 "ok\n"; }
      }

runcmd:
  - [ systemctl, enable, --now, qemu-guest-agent ]
  - [ systemctl, restart, nginx ]

power_state:
  mode: reboot
  condition: true
```

`meta-data`:

```yaml
instance-id: web01-0001
local-hostname: web01
```

Construí el seed ISO y arrancá la imagen de nube contra él:

```console
$ cloud-localds seed.iso user-data meta-data
$ qemu-img create -f qcow2 -F qcow2 -b /golden/debian-12-genericcloud-amd64.qcow2 web01.qcow2
$ qemu-img resize web01.qcow2 40G
Image resized.
$ qemu-system-x86_64 -accel kvm -cpu host -smp 4 -m 4096 \
    -drive if=virtio,file=web01.qcow2,format=qcow2,cache=none,aio=io_uring \
    -drive if=virtio,file=seed.iso,format=raw \
    -netdev tap,id=n0,ifname=tap0,script=no,downscript=no,vhost=on \
    -device virtio-net-pci,netdev=n0,mac=52:54:00:12:34:56 \
    -nographic
```

### 5.6 Tarea de Ansible que renderiza la misma infraestructura del host (infra reproducible)

```yaml
- name: Configure QEMU/KVM host networking
  hosts: hypervisors
  become: true
  vars:
    bridge: br0
    uplink: eno1
    tap_count: 4
    qemu_user: libvirt-qemu
  tasks:
    - name: Ensure the bridge exists
      ansible.builtin.command:
        cmd: "ip link add name {{ bridge }} type bridge"
      register: br_add
      changed_when: br_add.rc == 0
      failed_when: br_add.rc != 0 and 'File exists' not in br_add.stderr

    - name: Bring the bridge up
      ansible.builtin.command: "ip link set {{ bridge }} up"
      changed_when: false

    - name: Enslave the uplink
      ansible.builtin.command: "ip link set {{ uplink }} master {{ bridge }}"
      changed_when: false

    - name: Create persistent TAP pool
      ansible.builtin.command:
        cmd: "ip tuntap add dev tap{{ item }} mode tap user {{ qemu_user }}"
      loop: "{{ range(0, tap_count) | list }}"
      register: tap_add
      changed_when: tap_add.rc == 0
      failed_when: tap_add.rc != 0 and 'File exists' not in tap_add.stderr

    - name: Enslave and raise each TAP
      ansible.builtin.shell: |
        ip link set tap{{ item }} master {{ bridge }}
        ip link set tap{{ item }} up
      loop: "{{ range(0, tap_count) | list }}"
      changed_when: false
```

### 5.7 El bridge de libvirt sobre la misma idea (para equipos que usan virsh)

Incluso cuando QEMU se maneja a mano, vale la pena leer la representación XML de libvirt — es la serialización canónica de un dominio QEMU. XML mínimo de dominio:

```xml
<domain type='kvm'>
  <name>web01</name>
  <memory unit='MiB'>4096</memory>
  <vcpu placement='static'>4</vcpu>
  <os>
    <type arch='x86_64' machine='pc-q35-8.2'>hvm</type>
    <boot dev='hd'/>
  </os>
  <cpu mode='host-passthrough' check='none' migratable='on'/>
  <clock offset='utc'/>
  <devices>
    <emulator>/usr/bin/qemu-system-x86_64</emulator>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2' cache='none' io='io_uring' discard='unmap'/>
      <source file='/var/lib/vm/web01.qcow2'/>
      <target dev='vda' bus='virtio'/>
    </disk>
    <interface type='bridge'>
      <mac address='52:54:00:12:34:56'/>
      <source bridge='br0'/>
      <model type='virtio'/>
      <driver name='vhost' queues='4'/>
    </interface>
    <console type='pty'/>
    <channel type='unix'>
      <target type='virtio' name='org.qemu.guest_agent.0'/>
    </channel>
    <memballoon model='virtio'/>
    <rng model='virtio'><backend model='random'>/dev/urandom</backend></rng>
  </devices>
</domain>
```

```console
$ virsh define web01.xml && virsh start web01
Domain 'web01' defined from web01.xml
Domain 'web01' started
```

---

## 6. El QEMU Monitor — HMP y QMP

El **QEMU Monitor** es el plano de control en tiempo de ejecución de una VM viva. Hay dos dialectos:

- **HMP (Human Monitor Protocol)** — el prompt interactivo `(qemu)`: `info`, `system_powerdown`, `device_add`, `savevm`.
- **QMP (QEMU Machine Protocol)** — un protocolo **JSON**, orientado a máquinas, sobre un socket. Esto es lo que hablan libvirt/OpenStack. Todo lo programático pasa por QMP.

### 6.1 Llegar al monitor

| Flag | Efecto |
|---|---|
| `-monitor stdio` | HMP en la terminal |
| `-monitor telnet:127.0.0.1:4444,server,nowait` | HMP sobre TCP (¡solo localhost!) |
| `-monitor unix:/run/qemu/mon.sock,server,nowait` | HMP sobre un socket Unix |
| `-qmp unix:/run/qemu/qmp.sock,server=on,wait=off` | QMP sobre un socket Unix (producción) |
| `-serial mon:stdio` | Multiplexa la consola serial **y** el monitor sobre stdio (`Ctrl-a c` alterna) |

### 6.2 Sesión HMP — los comandos `info` en los que te vas a apoyar

```console
$ qemu-system-x86_64 -accel kvm -m 2048 -smp 2 \
    -drive file=web01.qcow2,if=virtio -monitor stdio -display none
QEMU 8.2.2 monitor - type 'help' for more information
(qemu) info status
VM status: running

(qemu) info kvm
kvm support: enabled

(qemu) info cpus
* CPU #0: thread_id=20344
  CPU #1: thread_id=20345

(qemu) info block
root (#block182): web01.qcow2 (qcow2)
    Attached to:      /machine/peripheral-anon/device[0]/virtio-backend
    Cache mode:       writeback, direct

(qemu) info network
net0:
 \ #net058: index=0,type=nic,model=virtio-net-pci,macaddr=52:54:00:12:34:56
  \ hub0port0: user.0: index=0,type=user,net=10.0.2.0,restrict=off

(qemu) info registers
CPU#0
RAX=0000000000000000 RBX=ffff9b8c00c1a000 RCX=0000000000000000 ...
RIP=ffffffff8a4f27e6 RFL=00000246 [---Z-P-] ...

(qemu) info mem
0000000000000000-0000000000200000 0000000000200000 -rw
...

(qemu) info migrate
globals: store-global-state=on, only-migratable=off, send-configuration=on ...
```

Referencia completa de comandos HMP:

```console
(qemu) help info
info version  -- show the version of QEMU
info network  -- show the network state
info chardev  -- show the character devices
info block    -- show info of one block device or all block devices
info blockstats -- show block device statistics
info registers  -- show the cpu registers
info cpus     -- show info of all guest CPUs
info kvm      -- show KVM information
info numa     -- show NUMA information
info usb      -- show guest USB devices
info pci      -- show PCI info
info mtree    -- show memory tree
info qtree    -- show device tree
info snapshots -- show the currently saved VM snapshots
info migrate  -- show migration status
info balloon  -- show balloon information
...
```

### 6.3 Operaciones en vivo desde HMP

**Apagado ordenado (envía el botón de encendido ACPI) vs reset duro:**

```console
(qemu) system_powerdown        # ACPI → guest OS shuts down cleanly
(qemu) system_reset            # hard reset (like the reset button)
(qemu) stop                    # pause vCPUs (freeze)
(qemu) cont                    # resume
```

**Hotplug de dispositivos PCI** (agregar una segunda NIC a un guest en ejecución):

```console
(qemu) netdev_add tap,id=net1,ifname=tap1,script=no,downscript=no
(qemu) device_add virtio-net-pci,netdev=net1,id=nic1,mac=52:54:00:99:88:77
(qemu) info pci
  Bus  0, device   4, function 0:
    Ethernet controller: PCI device 1af4:1000
      PCI subsystem 1af4:0001
      virtio-net-pci
(qemu) device_del nic1         # requests guest-cooperative unplug
```

**Snapshots internos (estado de la VM + disco, solo qcow2):**

```console
(qemu) savevm checkpoint-preupgrade
(qemu) info snapshots
List of snapshots present on all disks:
 ID        TAG                  VM SIZE                DATE     VM CLOCK      ICOUNT
 1         checkpoint-preupgrade  198 MiB 2026-08-11 09:40:12  00:03:11.120
(qemu) loadvm checkpoint-preupgrade
(qemu) delvm checkpoint-preupgrade
```

**El screendump / captura de consola y la introspección del modelo de CPU también están acá** — pero los dos que no tenés que confundir son `system_powerdown` (educado, el guest puede negarse) y `quit`/`q` (mata el proceso QEMU de inmediato, el estado del guest se pierde).

### 6.4 QMP — la vía programática

QMP te saluda con un banner de capacidades; tenés que enviar `qmp_capabilities` antes de cualquier comando.

```console
$ socat - UNIX-CONNECT:/run/qemu/web01.qmp
{"QMP": {"version": {"qemu": {"micro": 2, "minor": 2, "major": 8}, "package": "Debian 1:8.2.2+ds-0ubuntu1"}, "capabilities": ["oob"]}}
{"execute": "qmp_capabilities"}
{"return": {}}
{"execute": "query-status"}
{"return": {"status": "running", "singlestep": false, "running": true}}
{"execute": "query-kvm"}
{"return": {"enabled": true, "present": true}}
{"execute": "query-block", "arguments": {}}
{"return": [{"device": "", "qdev": "/machine/peripheral-anon/device[0]/virtio-backend", "inserted": {"file": "web01.qcow2", "cache": {"direct": true, "writeback": true, "no-flush": false}, "node-name": "root", "drv": "qcow2", ...}}]}
{"execute": "system_powerdown"}
{"return": {}}
{"timestamp": {"seconds": 1755938495, "microseconds": 111233}, "event": "POWERDOWN"}
{"timestamp": {"seconds": 1755938499, "microseconds": 882910}, "event": "SHUTDOWN", "data": {"guest": true, "reason": "guest-shutdown"}}
```

El wrapper más amigable `qmp-shell` (viene con QEMU) traduce key=value a JSON:

```console
$ qmp-shell /run/qemu/web01.qmp
Welcome to the QMP low-level shell!
Connected to QEMU 8.2.2

(QEMU) query-name
{"return": {"name": "web01"}}
(QEMU) device_add driver=virtio-net-pci netdev=net1 id=nic1 mac=52:54:00:99:88:77
{"return": {}}
(QEMU) query-migrate
{"return": {"status": "none"}}
```

### 6.5 Migración en vivo a través de QMP (la recompensa de un modelo de dispositivos estable)

En el host de **destino**, arrancá QEMU con la definición de hardware idéntica más `-incoming`:

```console
dst$ qemu-system-x86_64 -machine pc-q35-8.2,accel=kvm -cpu host -smp 4 -m 4096 \
     -drive if=none,id=root,file=/shared/web01.qcow2,format=qcow2,cache=none \
     -device virtio-blk-pci,drive=root \
     -qmp unix:/run/qemu/web01.qmp,server=on,wait=off \
     -incoming tcp:0:4444
```

En el **origen**, dirigí la migración por QMP:

```console
src$ qmp-shell /run/qemu/web01.qmp
(QEMU) migrate_set_parameter max-bandwidth=8589934592
{"return": {}}
(QEMU) migrate uri=tcp:dst.leloir.internal:4444
{"return": {}}
(QEMU) query-migrate
{"return": {"status": "active", "ram": {"transferred": 1073741824, "remaining": 2147483648, "total": 4294967296, "dirty-pages-rate": 512, ...}, ...}}
(QEMU) query-migrate
{"return": {"status": "completed", "ram": {"transferred": 4311744512, "total": 4294967296, ...}, "total-time": 6120, "downtime": 84}}
```

`downtime: 84` ms — el guest se pausó durante 84 ms durante la sincronización final de páginas sucias. Esto solo funciona porque ambos lados declararon **hardware virtual idéntico byte por byte** — la razón por la que fijás tipos de máquina versionados y modelos de CPU con nombre/`host` con `migratable=on`.

---

## 7. Playbook de diagnóstico y troubleshooting

### 7.1 "La VM está lenta" — ¿KVM está realmente activo?

La regresión de rendimiento número uno: QEMU corrió silenciosamente sobre TCG porque `/dev/kvm` era inaccesible o se omitió `-accel kvm`.

```console
$ ps -o pid,pcpu,comm,args -C qemu-system-x86_64 | grep -o 'accel=[^ ,]*'
accel=tcg                       # ← smoking gun: emulation, not acceleration

# Confirm from inside the running guest via the monitor:
(qemu) info kvm
kvm support: disabled           # ← definitive

# Force KVM and fail loudly instead of silently degrading:
$ qemu-system-x86_64 -accel accel=kvm,kernel-irqchip=on ...
# or the hard-require form:
$ qemu-system-x86_64 -machine q35,accel=kvm -cpu host ...
qemu-system-x86_64: -machine q35,accel=kvm: could not open /dev/kvm: Permission denied
```

`Permission denied` en `/dev/kvm` → usuario no está en el grupo `kvm` (Sección 3.3). `No such file or directory` → módulo no cargado (Sección 3.2).

### 7.2 El guest se cuelga en el arranque / `-accel kvm` rechazado a mitad de ejecución

```console
$ dmesg | grep -iE 'kvm|vmx|svm' | tail
[  918.442310] kvm: disabled by bios
```

Verificá también que otro hipervisor no esté acaparando las extensiones:

```console
$ lsmod | grep -E 'kvm|vbox|vmmon'
vboxdrv               663552  3    # ← VirtualBox owns VT-x; unload it or don't run both
$ sudo modprobe -r vboxdrv
```

### 7.3 Red: el guest tiene enlace pero no hay tráfico

Verificá las capas de abajo hacia arriba. ¿El TAP está enganchado al bridge?

```console
$ bridge link
7: tap0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 master br0 state forwarding
$ ip -brief addr show br0
br0              UP             192.168.178.10/24

# Is the guest's virtio NIC even up? (from monitor)
(qemu) info network
net0: index=0,type=nic,model=virtio-net-pci,macaddr=52:54:00:12:34:56
 \ tap0: index=0,type=tap,ifname=tap0,script=no,downscript=no,vhost=on
```

Causas comunes, en orden de frecuencia:

| Síntoma | Causa probable | Chequeo / arreglo |
|---|---|---|
| Sin IP en el guest | TAP no enganchado al bridge | `bridge link` no muestra `master br0` → `ip link set tap0 master br0` |
| Sin alcanzabilidad en la LAN | La IP del host sigue en la NIC física, no en el bridge | Mové la configuración L3 al `br0`, no a `eno1` |
| Tráfico descartado | `br_netfilter` + política FORWARD de iptables | `sysctl net.bridge.bridge-nf-call-iptables=0` o abrí FORWARD |
| Throughput terrible | `vhost=off` (data path en espacio de usuario) | agregá `vhost=on`; verificá que exista `/dev/vhost-net` |
| El guest no puede alcanzar el host (macvtap) | macvtap aísla guest↔host por diseño | usá un bridge, o un segundo macvlan en el host |

```console
$ ls -l /dev/vhost-net
crw------- 1 root root 10, 238 Aug 11 09:14 /dev/vhost-net
$ cat /sys/class/net/tap0/tun_flags
0x1002                          # IFF_TAP | IFF_VNET_HDR set → vhost-capable
```

### 7.4 Corrupción de disco / imagen y pérdida de datos relacionada con la cache

```console
$ qemu-img check web01.qcow2
Leaked cluster 12934 refcount=1 reference=0
...
8 leaked clusters were found on the image.
This means waste of disk space, but no harm to data.

$ qemu-img check -r all web01.qcow2       # attempt repair
Repairing cluster 12934 refcount=1 reference=0
The following inconsistencies were found and repaired:
    8 leaked clusters
Double checking the fixed image now...
No errors were found on the image.
```

> **Regla de corrección:** `cache=unsafe` ignora los pedidos de flush del guest — un crash del host **va a** corromper la imagen. Usalo solo para descartables/CI. Producción es `cache=none` (O_DIRECT, honra los flush, evita el doble cacheo). Si un guest reporta picos de latencia en fsync, revisá `aio=` — cambiá `threads`→`native`/`io_uring`.

### 7.5 Virtualización anidada (correr QEMU/KVM dentro de un guest)

```console
$ cat /sys/module/kvm_intel/parameters/nested
Y                               # (N or 0 = disabled)

# Enable persistently:
$ echo 'options kvm_intel nested=1' | sudo tee /etc/modprobe.d/kvm.conf
$ sudo modprobe -r kvm_intel && sudo modprobe kvm_intel
# AMD equivalent: options kvm_amd nested=1
```

Para que el guest L1 exponga VMX/SVM al L2, su CPU debe pasar la flag: `-cpu host` o `-cpu <model>,vmx=on` (Intel) / `svm=on` (AMD).

### 7.6 Introspeccionar un proceso QEMU en ejecución desde el host

```console
$ pgrep -a qemu-system-x86_64
20344 /usr/bin/qemu-system-x86_64 -name web01 -machine pc-q35-8.2,accel=kvm ...

# vCPU threads and their host CPU affinity:
$ ps -T -p 20344 -o spid,comm,psr | head
   SPID COMMAND         PSR
  20344 qemu-system-x86  2
  20348 CPU 0/KVM         4
  20349 CPU 1/KVM         6
  20350 CPU 2/KVM         8
  20351 CPU 3/KVM        10

# KVM exit statistics — the single best signal for "why is my guest burning CPU":
$ sudo perf kvm stat live -p 20344
Analyze events for pgid(20344), all VCPUs:

     VM-EXIT    Samples  Samples%     Time%    Min Time    Max Time     Avg time
    HLT           41233    58.11%    92.44%      0.55us  40122.10us   1902.44us
    MSR_WRITE      9821    13.84%     0.42%      0.34us     12.09us      1.31us
    EXTERNAL_INT   7104    10.01%     0.60%      0.41us     23.88us      2.60us
    IO_INSTRUCTION 4512     6.36%     4.10%      1.02us    301.44us     27.80us
    EPT_MISCONFIG  1120     1.58%     0.90%      2.10us     88.30us     24.60us
```

Una tasa alta de exits `IO_INSTRUCTION` o `EPT_VIOLATION` suele significar un dispositivo *emulado* en un camino caliente (p. ej. `e1000` en lugar de `virtio-net`, o `ide` en lugar de `virtio-blk`) — cambiá el guest a virtio.

### 7.7 Validación estructurada del lado del host, un solo comando

```console
$ virt-host-validate qemu
  QEMU: Checking for hardware virtualization                                 : PASS
  QEMU: Checking if device /dev/kvm exists                                   : PASS
  QEMU: Checking if device /dev/kvm is accessible                            : PASS
  QEMU: Checking if device /dev/vhost-net exists                             : PASS
  QEMU: Checking if IOMMU is enabled by kernel                               : WARN (Add intel_iommu=on to kernel cmdline for PCI passthrough)
  QEMU: Checking for secure guest support                                    : WARN (Unknown if this platform has Secure Guest support)
```

`intel_iommu=on` / `amd_iommu=on` en la línea de comandos del kernel es el prerrequisito para el passthrough de dispositivos VFIO (GPUs, NICs) hacia un guest QEMU — un `WARN` acá, no un `FAIL`, salvo que necesites passthrough.

---

## 8. Referencia consolidada de comandos / parámetros

**Módulos y dispositivo:** `modprobe kvm-intel|kvm-amd`, `lsmod | grep kvm`, `/dev/kvm`, `/dev/vhost-net`, `/dev/net/tun`
**Sanidad:** `kvm-ok`, `virt-host-validate qemu`, `egrep -c '(vmx|svm)' /proc/cpuinfo`
**Lanzamiento:** `qemu-system-x86_64 -machine q35,accel=kvm -cpu host -smp -m -drive -device -netdev -boot -cdrom -serial -qmp`
**Imágenes:** `qemu-img create|info|convert|check|resize|snapshot|rebase`
**Bridges:** `brctl addbr|addif|show` ↔ `ip link add … type bridge`, `bridge link show`
**TAP:** `tunctl -t … -u …` ↔ `ip tuntap add dev … mode tap user …`
**Monitor:** HMP `info kvm|cpus|block|network|pci|qtree|migrate`, `system_powerdown`, `device_add`, `savevm/loadvm`, `migrate`; QMP `qmp_capabilities`, `query-status`, `query-kvm`, `migrate`

---

## 9. Referencias

- **LPI — Objetivos del Examen 305 (305-300), Tema 351.3 QEMU** — https://www.lpi.org/our-certifications/exam-305-objectives/
- **QEMU — System Emulation User's Guide** — https://www.qemu.org/docs/master/system/index.html
- **QEMU — Invocation & command-line options (referencia de `qemu-system`)** — https://www.qemu.org/docs/master/system/invocation.html
- **QEMU — KVM acceleration** — https://www.qemu.org/docs/master/system/i386/kvm.html
- **QEMU — QEMU Monitor (HMP)** — https://www.qemu.org/docs/master/system/monitor.html
- **QEMU — QMP (QEMU Machine Protocol) reference** — https://www.qemu.org/docs/master/interop/qemu-qmp-ref.html
- **QEMU — Network emulation (`-netdev`, tap, bridge, user)** — https://wiki.qemu.org/Documentation/Networking
- **QEMU — `qemu-img` manual** — https://www.qemu.org/docs/master/tools/qemu-img.html
- **QEMU — Live migration** — https://www.qemu.org/docs/master/devel/migration/index.html
- **Linux kernel — KVM API documentation (`/dev/kvm`, ioctls)** — https://docs.kernel.org/virt/kvm/api.html
- **Linux kernel — Nested virtualization (`kvm-intel`/`kvm-amd` `nested`)** — https://docs.kernel.org/virt/kvm/x86/nested-vmx.html
- **libvirt — Domain XML format** — https://libvirt.org/formatdomain.html
- **libvirt — `virt-host-validate`** — https://www.libvirt.org/manpages/virt-host-validate.html
- **iproute2 — `ip-link(8)`, `ip-tuntap`, `bridge(8)`** — https://man7.org/linux/man-pages/man8/ip-link.8.html · https://man7.org/linux/man-pages/man8/bridge.8.html
- **cloud-init — NoCloud datasource & modules** — https://cloudinit.readthedocs.io/en/latest/reference/datasources/nocloud.html