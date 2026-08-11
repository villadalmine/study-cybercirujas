# 351.2 Xen

> **LPIC-3 Virtualization and Containerization — Exam 305-300, v3.0**
> Peso del objetivo: **5**. Enfoque: Xen **4.x**, el toolstack `xl`/libxenlight.
> Áreas de conocimiento clave: arquitectura de Xen (redes + almacenamiento), configuración básica de Dom0/DomU, manipulación y análisis de dominios, troubleshooting.

---

## 1. Motivación: el problema arquitectónico que Xen resuelve

Todo hipervisor responde a una única pregunta: **¿quién es dueño de las instrucciones privilegiadas?** Sobre bare metal, el kernel del SO corre en el ring 0 y ejecuta `HLT`, `INVLPG`, escrituras de tablas de páginas, acceso a puertos de I/O y enmascaramiento de interrupciones directamente. Poné dos kernels en una misma máquina y ambos quieren el ring 0. Esa es la colisión que un hipervisor arbitra.

Xen es un **hipervisor de Tipo 1 (bare-metal)**: una pieza de código pequeña (~1 MB) que bootea *antes* que cualquier kernel Linux, toma el ring 0 (o el modo root VMX/SVM en las CPUs modernas) y luego bootea una primera instancia Linux privilegiada — **Dom0** — como un guest ordinario. Esto invierte el modelo mental que la mayoría trae desde KVM:

- Con **KVM**, Linux *es* el hipervisor; `kvm.ko` convierte el kernel del host en un VMM y los guests son procesos `qemu` planificados por el scheduler del host.
- Con **Xen**, el hipervisor *no* es Linux. Linux (Dom0) es un cliente del hipervisor, exactamente igual que cualquier guest, distinguido solo por su privilegio: maneja el hardware físico y corre el toolstack.

### Los problemas de producción en los que esta forma es buena

1. **Aislamiento del control plane respecto del data plane.** El scheduler, el asignador de memoria y el arbitraje de CPU viven en el hipervisor, no en un kernel Linux de 30 millones de líneas. Un kernel panic de Dom0 puede ser sobrevivible; el hipervisor sigue corriendo y (con driver domains) los guests siguen ejecutándose. Por eso Xen sustenta nubes que valoran la contención del radio de impacto (históricamente la primera década de AWS EC2; el modelo de seguridad de QubesOS; XCP-ng/Citrix Hypervisor).

2. **Paravirtualización para CPUs sin extensiones de virtualización.** Xen es anterior a Intel VT-x/AMD-V. Su modo **PV** corre un guest *modificado* que nunca emite instrucciones privilegiadas — en su lugar hace **hypercalls**. Ese legado hoy es mayormente una carga (ver §2), pero produjo la arquitectura de driver dividido (split-driver) que todavía le da a Xen su rendimiento de I/O.

3. **Planificación determinista y particionado de CPU.** Los `cpupools`, la afinidad de vCPU dura/blanda, la ubicación consciente de NUMA y los schedulers Credit2/RTDS/`null` te permiten tallar una máquina en particiones con garantías de latencia — la razón por la que Xen aparece en NFV de telcos y en embebidos de tiempo real (automoción, aviónica vía ARINC653).

4. **Driver domains y stub domains.** El device model e incluso los drivers de dispositivos físicos pueden empujarse *fuera* de Dom0 hacia dominios desprivilegiados. Un driver de NIC comprometido compromete un dominio descartable, no el host entero.

### El mecanismo que debés tener en la cabeza

Un guest nunca toca el hardware. En cambio:

```
   DomU (unprivileged guest)                 Dom0 (privileged)
  ┌───────────────────────┐               ┌───────────────────────┐
  │  frontend driver       │  XenStore     │  backend driver        │
  │  (netfront / blkfront) │◄────bus──────►│  (netback / blkback)   │
  │        │  ▲            │               │        │  ▲            │
  └────────┼──┼────────────┘               └────────┼──┼────────────┘
           │  │ event channel (virtual IRQ)         │  │
           ▼  │ grant table (shared memory pages)   ▼  │
      ┌───────────────────────── Xen hypervisor ──────────────────┐
      │  hypercalls · scheduler · MMU · event channels · grants    │
      └────────────────────────────────────────────────────────────┘
                              physical hardware
```

Cuatro primitivas hacen que esto funcione — **memorizalas, son examinables y son lo que depurás**:

| Primitiva | Qué es | Analogía |
|---|---|---|
| **Hypercall** | Llamada síncrona guest→hipervisor (vía un trap tipo `syscall`) | Un syscall, pero cruzando hacia el hipervisor |
| **Event channel** | Notificación asíncrona / interrupción virtual entre dominios y el hipervisor | Una línea de IRQ por software |
| **Grant table** | Tabla por dominio que autoriza a otro dominio a mapear o transferir páginas de memoria específicas | Un permiso de `mmap` de memoria |
| **XenStore** | Base de datos jerárquica clave/valor (`/local/domain/<id>/...`) para configuración y negociación de dispositivos | Un `/proc` compartido + D-Bus |

Los drivers backend y frontend se encuentran entre sí *escribiendo en XenStore* (el handshake del "xenbus"), y luego intercambian datos sobre un **ring buffer** compartido cuyas páginas se comparten vía **grant tables** y cuya señal de "tenés correo" es un **event channel**. Cuando un `vif` no levanta o un disco no se adjunta, este handshake es exactamente donde mirás.

---

## 2. Comparaciones técnicas y trade-offs

### 2.1 Modos de virtualización — la tabla más importante de este objetivo

| | **PV** (Paravirtual) | **HVM** (Hardware VM) | **PVHVM** (PV-on-HVM) | **PVH** (PV moderno) |
|---|---|---|---|---|
| Extensiones de virt. de CPU | No requeridas | **Requeridas** (VT-x/AMD-V) | Requeridas | Requeridas |
| Kernel del guest | Debe ser Xen-aware | Sin modificar (cualquier SO) | Sin modificar + drivers PV | Debe ser PVH-aware |
| Device model emulado (QEMU) | Ninguno | **Completo** (qemu-dm) | Presente pero omitido para I/O | **Ninguno** |
| BIOS/UEFI emulado | Ninguno | SeaBIOS / OVMF | SeaBIOS / OVMF | Ninguno (boot directo de kernel/PVH) |
| Ruta de boot | pygrub / PV-GRUB / kernel directo | Firmware → bootloader | Firmware → bootloader | Kernel directo o ABI de boot de Xen |
| Operaciones privilegiadas | Hypercalls | Traps de hardware (VMEXIT) | Traps de hardware | Traps de hardware |
| Tablas de páginas | Software (mediado por hypercall, o shadow) | **HAP** (EPT/NPT) por hardware | HAP | HAP |
| Ruta de I/O | Drivers PV divididos | Emulada (lenta) → drivers PV | Drivers PV (rápida) | Drivers PV (rápida) |
| Interrupciones | Event channels | APIC emulado | vAPIC + event channels | Event channels |
| Superficie de ataque | Pequeña (sin QEMU) | **Grande** (device model de QEMU) | Grande (QEMU presente) | **Pequeña** (sin QEMU) |
| ¿Boot de Windows? | No | **Sí** | Sí | No |
| Uso típico en la década de 2020 | **Deprecado / evitar** | Windows, appliances que necesitan firmware | Linux HVM heredado | **Recomendado para Linux** |

**El trade-off en una frase:** PV evita QEMU pero paga un impuesto de syscall/pagefault y es un riesgo de seguridad en 64 bits (Meltdown/XPTI, el retirado PV32); HVM corre cualquier cosa pero arrastra una gran superficie de ataque de QEMU; **PVH es el punto justo moderno para Linux** — virtualización por hardware para la CPU y la MMU, drivers PV divididos para I/O, y *sin QEMU ni firmware en absoluto*. Desde Xen 4.10 el DomU PVH es estable; tratalo como el default para nuevos guests Linux y reservá HVM para Windows o cualquier cosa que insista en una BIOS.

> **Trampa histórica para el examen y para hosts reales:** los guests PV clásicos de 64 bits fueron el vector que forzó **XPTI (Xen Page Table Isolation)** tras Meltdown, con un costo de throughput real. Esto es gran parte de *por qué* el proyecto empujó a todos hacia PVH. Si heredás una flota de guests PV, migrarlos a PVH es una mejora de la postura de seguridad, no solo una limpieza.

### 2.2 Xen vs. KVM — eligiendo la plataforma

| Dimensión | **Xen** | **KVM** |
|---|---|---|
| Tipo | Tipo 1, el hipervisor bootea primero | Tipo 1 dentro de Linux (módulo del kernel) |
| Aislamiento del control plane | Fuerte (Dom0 separable, driver domains) | Débil (kernel del host = hipervisor) |
| Radio de impacto de un crash de Dom0/host | Los guests pueden sobrevivir con driver domains | Un crash del host mata a todos los guests |
| Device model | QEMU externo (HVM), aislamiento opcional en stub-domain | QEMU por guest como proceso del host |
| Migración en vivo | `xl migrate` (almacenamiento compartido) / `xl save`/`restore` | `virsh migrate` |
| Particionado de CPU | cpupools, schedulers RTDS/null, ARINC653 | cgroups/CFS, `isolcpus` |
| Toolstack del ecosistema | `xl` (libxl), XAPI (XCP-ng) | libvirt, oVirt, Proxmox |
| Reutilización de drivers del kernel | Necesita backends Xen-aware en Dom0 | Cualquier driver de Linux funciona al instante |
| Pedigrí en investigación de seguridad | QubesOS, AWS (histórico), embebidos/RT | Default en la nube (GCP, la mayoría de OpenStack) |

**Guía:** elegí Xen cuando el requisito sea el aislamiento del control plane, la planificación determinista o la seguridad de driver domains; elegí KVM cuando quieras todo el ecosistema de drivers y herramientas de Linux con cero fricción. Para este examen, debés conocer la forma de Xen lo bastante bien como para *justificar* esa elección.

### 2.3 Trade-offs de backend de almacenamiento

| Spec de backend | Mecanismo | Formatos | Rendimiento | Cuándo usar |
|---|---|---|---|---|
| `phy:` | Dispositivo de bloques directo (LV de LVM, partición, LUN de iSCSI, DRBD) | solo raw | **El más alto** | Producción; la elección por defecto |
| `file:` | Imagen montada por loopback | raw | Pobre (overhead de loop, doble caché) | Nunca en producción |
| `qdisk` (`format=qcow2`) | Backend de bloques de QEMU | raw, qcow2, vhd | Medio; snapshots y thin-prov | Imágenes que necesitan snapshots |
| `tap:aio` / blktap2 | `tapdisk` en espacio de usuario | raw, vhd | Alto; cadenas de snapshots (vhd) | Donde blktap esté disponible |

**Regla general:** volúmenes lógicos de LVM sobre `phy:` para todo lo que te importe; `qcow2` sobre `qdisk` solo cuando necesites snapshots copy-on-write y aceptes el costo de throughput.

### 2.4 Trade-offs de scheduler

| Scheduler | Modelo | Latencia | Equidad | Caso de uso |
|---|---|---|---|---|
| **credit** | Proporcional (proportional-share), peso+cap | Justo, no de baja latencia | Buena | Default heredado |
| **credit2** | Proporcional rediseñado | Mejor latencia + equidad | **Buena** | **Default actual** |
| **rtds** | Real-Time Deferrable Server (período/presupuesto) | **Determinista** | Reserva | Tiempo real / NFV |
| **null** | Estático 1:1 vCPU↔pCPU, sin planificación | **Mínima** | Ninguna | Máximo rendimiento, hosts particionados |
| **arinc653** | Particionado en el tiempo (aviónica) | Determinista | Ligada a partición | Crítico para la seguridad |

---

## 3. Archivos de infraestructura y configuración completos (sin abreviar)

Xen es anterior a la era YAML; `xl` usa una **sintaxis clave/valor** (`xl.cfg(5)`). Lo que sigue son archivos completos y sintácticamente válidos para un nodo de producción. Las rutas de versión asumen Debian 12 con Xen 4.17 — ajustá `xen-4.17` a tu versión instalada.

### 3.1 Boot de Dom0: entregar la máquina al hipervisor

El kernel **no** bootea primero — Xen sí, y luego encadena (chainload) el kernel de Dom0 como un módulo multiboot. En Debian, `/etc/default/grub` maneja esto:

```sh
# /etc/default/grub  — Dom0 hypervisor parameters
# The Xen *hypervisor* command line (NOT the Linux command line):
GRUB_CMDLINE_XEN_DEFAULT="dom0_mem=8192M,max:8192M \
dom0_max_vcpus=4 dom0_vcpus_pin \
gnttab_max_frames=256 \
cpufreq=xen \
com1=115200,8n1 console=com1,vga \
sched=credit2"

# The Dom0 *Linux kernel* command line:
GRUB_CMDLINE_LINUX="console=hvc0 earlyprintk=xen"

# Prefer the Xen menuentry as default:
GRUB_DEFAULT="Debian GNU/Linux, with Xen hypervisor"
```

**Por qué importan en producción (y en el examen):**

- `dom0_mem=8192M,max:8192M` — **fijá la memoria de Dom0**. Sin un `max:`, el autoballooning encoge Dom0 para hacer lugar a los guests y luego Dom0 mata por OOM tu toolstack bajo presión. Poner el valor actual == max deshabilita el ballooning de Dom0.
- `dom0_max_vcpus=4 dom0_vcpus_pin` — dale a Dom0 un conjunto fijo y pineado de pCPUs para que la carga de los guests nunca inanice el control plane (y viceversa).
- `gnttab_max_frames` — presión sobre la grant-table de muchos frontends `vif`/`vbd` de alto throughput; subilo en hosts densos (vas a ver errores de "grant table" en `xl dmesg` cuando esté demasiado bajo).
- `com1=... console=com1` — consola serie. En un host hipervisor real esto es innegociable: los gráficos de Dom0 pueden no estar y `xl` puede estar trabado; la línea serie es cómo llegás a `xl dmesg`.

Regenerar y reiniciar:

```
$ sudo update-grub
Generating grub configuration file ...
Found Xen hypervisor version: 4.17.3
...
$ sudo systemctl reboot
```

El **stanza manual de GRUB** equivalente (aprendé a leerlo):

```
menuentry 'Debian GNU/Linux, with Xen hypervisor' {
    insmod multiboot2
    multiboot2  /boot/xen-4.17.gz placeholder dom0_mem=8192M,max:8192M \
                dom0_max_vcpus=4 dom0_vcpus_pin sched=credit2 \
                com1=115200,8n1 console=com1,vga
    module2     /boot/vmlinuz-6.1.0-18-amd64 placeholder \
                root=/dev/mapper/vg0-root ro console=hvc0 earlyprintk=xen
    module2     /boot/initrd.img-6.1.0-18-amd64
}
```

### 3.2 Configuración global del toolstack — `/etc/xen/xl.conf`

```sh
## /etc/xen/xl.conf — libxl / xl toolstack defaults (xl.conf(5))

# Do NOT autoballoon Dom0 to satisfy new domains. We pinned dom0_mem above;
# leave this off and manage memory explicitly. This is the #1 stability setting.
autoballoon="off"

# Serialize concurrent xl operations against this lock.
lockfile="/var/lock/xl"

# Default networking script + bridge for any vif that omits them.
vif.default.script="vif-bridge"
vif.default.bridge="xenbr0"

# First virtual disk letter when a config uses positional vdevs.
blkdev_start="xvda"

# Machine-readable output for scripting (xl list -l, etc.).
output_format="json"

# Keep a domain's config with the running domain so `xl migrate` / reboot
# re-reads the *effective* config, not the on-disk one.
claim_mode="1"
```

### 3.3 Redes del host Dom0 — un bridge al que se adjuntan los `vif`s

Los `vif`s de los guests son una mitad de un par tipo veth cuyo extremo en Dom0 (`vifX.Y`) queda esclavizado a un bridge de Linux. Definí ese bridge en el host. Con `ifupdown` de Debian:

```sh
# /etc/network/interfaces.d/xenbr0
auto xenbr0
iface xenbr0 inet static
    address        10.20.0.10/24
    gateway        10.20.0.1
    bridge_ports   eno1
    bridge_stp     off
    bridge_fd      0
    bridge_maxwait 0
    # Hardware offloads on the bridge port often break under high vif density:
    # up ethtool -K eno1 tx off rx off gso off tso off
```

Equivalente con `systemd-networkd` (dos archivos):

```ini
# /etc/systemd/network/10-xenbr0.netdev
[NetDev]
Name=xenbr0
Kind=bridge

[Bridge]
STP=false
```
```ini
# /etc/systemd/network/20-xenbr0.network
[Match]
Name=xenbr0
[Network]
Address=10.20.0.10/24
Gateway=10.20.0.1
```
```ini
# /etc/systemd/network/15-eno1-bind.network
[Match]
Name=eno1
[Network]
Bridge=xenbr0
```

### 3.4 Un DomU Linux **PVH** de producción — `/etc/xen/pvh-web01.cfg`

El default moderno. Sin QEMU, sin firmware, MMU por hardware, I/O PV.

```sh
# ── /etc/xen/pvh-web01.cfg ─────────────────────────────────────────
# Modern paravirtualized-with-hardware guest. No QEMU device model.

name        = "pvh-web01"
type        = "pvh"                    # PVH builder (Xen ≥ 4.10)

# Memory: current allocation and ceiling. maxmem enables in-guest ballooning
# up to 4 GiB without a reboot.
memory      = 2048                     # MiB
maxmem      = 4096                     # MiB

# CPU: 2 online now, hot-pluggable up to 4. Soft-pin to NUMA node 0.
vcpus       = 2
maxvcpus    = 4
cpus        = "8-15"                   # hard affinity mask (node 0 cores)

# Boot a Dom0-hosted kernel directly (PVH boot ABI) — no bootloader needed.
kernel      = "/var/lib/xen/kernels/vmlinuz-6.1.0-18-amd64"
ramdisk     = "/var/lib/xen/kernels/initrd.img-6.1.0-18-amd64"
cmdline     = "root=/dev/xvda1 ro console=hvc0 net.ifnames=0"

# Storage: LVM logical volumes over the fast phy backend.
disk = [
    "phy:/dev/vg_xen/pvh-web01-root,xvda,w",
    "phy:/dev/vg_xen/pvh-web01-data,xvdb,w",
]

# Networking: one bridged vif with a stable, locally-administered MAC.
# The 00:16:3e OUI is Xen's registered range — always use it.
vif = [
    "mac=00:16:3e:2a:14:01,bridge=xenbr0,vifname=vif.web01",
]

# Power-event policy: guest halt destroys, guest reboot restarts,
# a crash restarts (flip to "preserve" when you need a post-mortem).
on_poweroff = "destroy"
on_reboot   = "restart"
on_crash    = "restart"
```

### 3.5 Un DomU **PV** heredado booteando su propio kernel vía pygrub — `/etc/xen/pv-legacy01.cfg`

Todavía te vas a topar con estos; entendé cómo bootean.

```sh
# ── /etc/xen/pv-legacy01.cfg ───────────────────────────────────────
name        = "pv-legacy01"
type        = "pv"                     # older syntax: builder="linux"
memory      = 1024
maxmem      = 2048
vcpus       = 2

# pygrub reads the guest's OWN /boot/grub/grub.cfg from inside its disk
# image and extracts the kernel/initrd — the guest controls its kernel.
bootloader  = "/usr/lib/xen-4.17/bin/pygrub"
# Alternative, fully Dom0-controlled boot (comment bootloader, use these):
#   kernel  = "/var/lib/xen/kernels/vmlinuz-6.1-amd64"
#   ramdisk = "/var/lib/xen/kernels/initrd.img-6.1-amd64"
#   extra   = "root=/dev/xvda1 ro console=hvc0"

disk = [
    "phy:/dev/vg_xen/pv-legacy01-root,xvda,w",
    "phy:/dev/vg_xen/pv-legacy01-swap,xvdb,w",
]
vif = [ "mac=00:16:3e:2a:14:05,bridge=xenbr0" ]

on_poweroff = "destroy"
on_reboot   = "restart"
on_crash    = "restart"
```

### 3.6 Un DomU **HVM** (Windows / dependiente de firmware) — `/etc/xen/hvm-win01.cfg`

Emulación completa con un device model aislado y drivers PV-on-HVM.

```sh
# ── /etc/xen/hvm-win01.cfg ─────────────────────────────────────────
name        = "hvm-win01"
type        = "hvm"                    # older syntax: builder="hvm"
memory      = 8192
maxmem      = 8192                     # Windows dislikes ballooning; pin it
vcpus       = 4
maxvcpus    = 4

# Emulated platform firmware. "seabios" = legacy BIOS; "ovmf" = UEFI.
bios        = "ovmf"
boot        = "dc"                     # try disk, then cdrom (order = string)

# Device model: qemu-xen, isolated in its own stub domain so a QEMU
# compromise does not reach Dom0.
device_model_version               = "qemu-xen"
device_model_stubdomain_override   = 1

# Storage: qcow2 via the QEMU qdisk backend (snapshots), plus install ISO.
disk = [
    "format=qcow2, vdev=xvda, access=rw, target=/var/lib/xen/images/win01.qcow2",
    "file:/srv/iso/Win2022.iso, vdev=xvdc, devtype=cdrom, access=ro",
]

# PV-on-HVM: an emulated e1000 that Windows PV drivers later accelerate.
vif = [
    "mac=00:16:3e:2a:14:02,bridge=xenbr0,model=e1000",
]

# Graphical console over VNC, bound to loopback (reach it via SSH tunnel).
vnc         = 1
vnclisten   = "127.0.0.1"
vncdisplay  = 1
usbdevice   = "tablet"                 # absolute pointer, fixes VNC drift
serial      = "pty"

# PCI passthrough of a GPU (needs IOMMU/VT-d and the device stub-bound
# to xen-pciback in Dom0). Uncomment when the device is isolated:
# pci = [ "0000:04:00.0", "0000:04:00.1" ]

on_poweroff = "destroy"
on_reboot   = "restart"
on_crash    = "preserve"               # keep the corpse for forensics
```

---

## 4. Comandos CLI y salida real de terminal

### 4.1 Inspeccionar el host

```
$ sudo xl info
host                   : xen-node01
release                : 6.1.0-18-amd64
version                : #1 SMP PREEMPT_DYNAMIC Debian 6.1.76-1 (2024-02-01)
machine                : x86_64
nr_cpus                : 32
max_cpu_id             : 63
nr_nodes               : 2
cores_per_socket       : 8
threads_per_core       : 2
cpu_mhz                : 2900.000
hw_caps                : bfebfbff:77fef3ff:2c100800:00000121:...
virt_caps              : pv hvm hvm_directio pv_directio hap shadow iommu
total_memory           : 262144
free_memory            : 245760
sharing_freed_memory   : 0
outstanding_claims     : 0
free_cpus              : 0
xen_major              : 4
xen_minor              : 17
xen_extra              : .3
xen_version            : 4.17.3
xen_caps               : xen-3.0-x86_64 hvm-3.0-x86_32 hvm-3.0-x86_32p hvm-3.0-x86_64
xen_scheduler          : credit2
xen_pagesize           : 4096
platform_params        : virt_start=0xffff800000000000
xen_commandline        : placeholder dom0_mem=8192M,max:8192M dom0_max_vcpus=4 dom0_vcpus_pin sched=credit2
cc_compiler            : gcc (Debian 12.2.0-14) 12.2.0
```

> **Leé `virt_caps` primero.** `hvm` significa que VT-x/AMD-V está presente y habilitado en el firmware — sin `hvm` acá no podés correr guests HVM/PVHVM/PVH. `hvm_directio` + `iommu` significan que el PCI passthrough es posible. `hap` significa que hay tablas de páginas por hardware (EPT/NPT) disponibles. Si `iommu` está ausente, arreglá VT-d/IOMMU en la BIOS antes de intentar passthrough.

### 4.2 Listar y crear dominios

```
$ sudo xl list
Name                                        ID   Mem VCPUs      State   Time(s)
Domain-0                                     0  8192     4     r-----   18423.4
pvh-web01                                    7  2048     2     -b----     942.1
hvm-win01                                    9  8192     4     -b----    5310.7
```

Flags de estado (leyenda de `xl list` — examinable): **r**=running (corriendo), **b**=blocked (bloqueado, ocioso, esperando I/O — *normal*), **p**=paused (pausado), **s**=shutdown (apagando), **c**=crashed (colapsado), **d**=dying (muriendo).

```
$ sudo xl create /etc/xen/pvh-web01.cfg
Parsing config from /etc/xen/pvh-web01.cfg

$ sudo xl create -c /etc/xen/pvh-web01.cfg          # -c attaches the console
Parsing config from /etc/xen/pvh-web01.cfg
[    0.000000] Linux version 6.1.0-18-amd64 ...
[    0.512300] Xen: PVH environment detected
...
Debian GNU/Linux 12 pvh-web01 hvc0
pvh-web01 login:                                    # Ctrl-] to detach

$ sudo xl create /etc/xen/pvh-web01.cfg pause=1     # create but leave paused
$ sudo xl create /etc/xen/pvh-web01.cfg 'memory=4096'  # override a key inline
```

### 4.3 Consola, ciclo de vida, inspección en vivo

```
$ sudo xl console pvh-web01          # attach; Ctrl-] to exit
$ sudo xl pause pvh-web01
$ sudo xl unpause pvh-web01
$ sudo xl shutdown pvh-web01         # ACPI/PV clean shutdown (graceful)
$ sudo xl shutdown -w pvh-web01      # ...and wait for it to complete
$ sudo xl reboot pvh-web01
$ sudo xl destroy pvh-web01          # HARD kill — like pulling power
$ sudo xl uptime pvh-web01
Name                                ID Uptime
pvh-web01                            7 0 days,  3:27:41
```

### 4.4 CPU: afinidad, pineo, hot-plug

```
$ sudo xl vcpu-list pvh-web01
Name              ID  VCPU   CPU State   Time(s) Affinity (Hard / Soft)
pvh-web01          7     0    10   -b-      512.3  8-15 / all
pvh-web01          7     1    12   r--      429.8  8-15 / all

$ sudo xl vcpu-pin pvh-web01 0 8         # hard-pin vCPU0 to pCPU8
$ sudo xl vcpu-pin pvh-web01 1 9
$ sudo xl vcpu-set pvh-web01 4           # hot-add vCPUs up to maxvcpus
```

### 4.5 Ballooning de memoria

```
$ sudo xl mem-max pvh-web01 4096         # raise the ceiling (MiB)
$ sudo xl mem-set pvh-web01 1024         # balloon the guest down to 1 GiB now
```

> `mem-set` por encima de `mem-max` recorta silenciosamente. Ballonear un guest por debajo de lo que su carga de trabajo necesita induce OOM dentro del guest — el balloon driver devuelve páginas al hipervisor, y el guest las ve como *desaparecidas*, no como *swapeadas*.

### 4.6 Monitoreo en tiempo real — `xentop`

```
$ sudo xentop
xentop - 14:32:07   Xen 4.17.3
3 domains: 1 running, 2 blocked, 0 paused, 0 crashed, 0 dying, 0 shutdown
Mem: 268435456k total, 22675456k used, 245760000k free    CPUs: 32 @ 2900MHz
      NAME  STATE  CPU(sec) CPU(%)     MEM(k) MEM(%)  MAXMEM(k) MAXMEM(%) VCPUS NETS NETTX(k) NETRX(k) VBDS VBD_OO VBD_RD VBD_WR
  Domain-0 -----r    18423    3.1    8388608    3.1    8388608       3.1     4    0        0        0    0      0      0      0
 hvm-win01 --b---     5310    2.4    8388608    3.1    8388608       3.1     4    1   142033   983221    2      0 1204553  442019
 pvh-web01 --b---      942    0.6    2097152    0.8    4194304       1.6     2    1    50127   118904    2      0  330218   90441
```

Observá **VBD_OO** (eventos de bloques "out of order"/cola llena): si es distinto de cero y sube, el backend de almacenamiento está saturado. **NETTX/NETRX** localizan a los guests de red ruidosos (noisy-neighbour).

### 4.7 Save / restore (suspend-to-disk) y migración en vivo

```
$ sudo xl save pvh-web01 /var/lib/xen/save/pvh-web01.chk
Saving to /var/lib/xen/save/pvh-web01.chk new xl format (info 0x3/0x0/1274)
xc: info: Saving domain 7, type x86 PV
xc: Frames: 524288/524288  100%
xc: End of stream: 0/0    0%

$ sudo xl restore /var/lib/xen/save/pvh-web01.chk
Loading new save file /var/lib/xen/save/pvh-web01.chk (new xl fmt info 0x3/0x0/1274)
 Savefile contains xl domain config in JSON format
Parsing config from <saved>
xc: info: Restoring domain, type x86 PV
xc: Frames: 524288/524288  100%
```

```
$ sudo xl migrate --live hvm-win01 xen-node02
migration target: Ready to receive domain.
Saving to migration stream new xl format (info 0x3/0x0/1483)
Loading new save file <incoming migration stream> (new xl fmt info 0x3/0x0/1483)
 Savefile contains xl domain config in JSON format
Parsing config from <saved>
xc: info: Saving domain 9, type x86 HVM
xc: Frames: 2097152/2097152  100%
xc: End of stream: 0/0    0%
migration sender: Target reports successful startup.
Migration successful.
```

> **Precondición:** el disco del guest debe ser alcanzable de forma idéntica en ambos hosts (iSCSI/NFS/DRBD/Ceph compartido, o targets `phy:` idénticos). `xl migrate` mueve *el estado de memoria y CPU*, no el almacenamiento. También se requieren SSH sin contraseña a `root@xen-node02` y versiones de Xen coincidentes.

### 4.8 Ring buffer del hipervisor y logs por guest

```
$ sudo xl dmesg | tail -n 8
(XEN) [  18423.114] grant_table.c:1234: Increased maptrack size to 2048 frames
(XEN) [  18500.882] d9v2 Triple fault - invoking HVM shutdown action
(XEN) [  18501.010] HVM9 save: CPU
(XEN) [  18501.140] HVM9 restore: CPU 0

$ sudo tail -f /var/log/xen/xl-hvm-win01.log        # per-domain xl toolstack log
$ sudo tail -f /var/log/xen/qemu-dm-hvm-win01.log   # per-HVM-domain QEMU log
```

### 4.9 XenStore — la base de datos de negociación de dispositivos

```
$ sudo xenstore-ls /local/domain/7
name = "pvh-web01"
domid = "7"
device = ""
 vif = ""
  0 = ""
   backend = "/local/domain/0/backend/vif/7/0"
   backend-id = "0"
   state = "4"                    # 4 = "Connected"; anything <4 = handshake stuck
   mac = "00:16:3e:2a:14:01"
 vbd = ""
  51712 = ""                      # 51712 = xvda (major/minor encoded)
   backend = "/local/domain/0/backend/vbd/7/51712"
   state = "4"
control = ""
 shutdown = ""

$ sudo xenstore-read /local/domain/7/name
pvh-web01

$ sudo xenstore-list /local/domain/7/device
vif
vbd

$ sudo xenstore-watch /local/domain/7/control/shutdown   # block until a value change
```

> **`state`** es la máquina de estados del xenbus (`XenbusStateConnected = 4`). Un `vif` o `vbd` atascado en `state = "1"` (Initialising) o `"3"` (Connecting) es un **handshake que nunca se completó** — el driver backend no está cargado, el bridge no existe, o el backend tuvo un error. Esta es la verdad de fondo cuando `xl` reporta un dispositivo pero el guest no lo ve.

---

## 5. Guía de verificación y diagnóstico de fallas

### 5.1 Escalera de verificación post-instalación (correr de arriba hacia abajo)

```
# 1. Is the hypervisor actually running? (not just a Xen-flavoured kernel)
$ sudo xl info | grep -E 'xen_version|xen_caps|virt_caps'
xen_version : 4.17.3
xen_caps    : xen-3.0-x86_64 hvm-3.0-x86_64
virt_caps   : pv hvm hvm_directio hap iommu

# 2. Confirm you booted UNDER Xen as Dom0, not on bare metal:
$ cat /sys/hypervisor/type
xen
$ cat /sys/hypervisor/properties/capabilities
control_d                             # this string == "I am Dom0"

# 3. Are the toolstack daemons up?
$ systemctl is-active xen-qemu-dom0-disk-backend.service xenconsoled.service \
                      xen-init-dom0.service xendomains.service
active
active
active
active

# 4. Is XenStore answering?
$ sudo xenstore-read /local/domain/0/name
Domain-0

# 5. Does the guest bridge exist and carry vifs?
$ ip -br link show master xenbr0
eno1        UP  bc:24:11:aa:bb:cc
vif7.0      UP  fe:ff:ff:ff:ff:ff
```

### 5.2 Matriz modo-de-falla → diagnóstico

| Síntoma | Causa probable | Comando de diagnóstico | Arreglo |
|---|---|---|---|
| `xl create` → `libxl: error: ... unable to add disk devices` | El target `phy:` del backend falta, o ya está abierto por otro dominio | `xl dmesg`, `xenstore-read .../vbd/.../state` | Verificá la ruta del LV/LUN; asegurate de que ningún otro dominio lo tenga tomado |
| El guest HVM bootea a un VNC negro, sin SO | Orden `boot=` incorrecto, ISO faltante/ilegible, desajuste de `bios` (OVMF vs SeaBIOS) | `tail /var/log/xen/qemu-dm-<dom>.log` | Arreglá `boot=`, permisos de la ruta del ISO; hacé coincidir el firmware con el SO |
| Guest PV: `pygrub: ... no menu entries` | pygrub no puede parsear el grub.cfg del guest, u orden de disco incorrecto | `xl create -c` (observá pygrub) | Arreglá el `/boot/grub/grub.cfg` del guest; verificá que el primer `disk=` sea el root |
| El guest no tiene red | Bridge faltante, script vif falló, colisión de MAC | `ip link show master xenbr0`; `xenstore-read .../vif/0/state` | Creá `xenbr0`; verificá `vif.default.bridge`; MAC 00:16:3e única |
| Dom0 muere por OOM bajo carga | El autoballooning encogió Dom0 | `xl info \| grep free_memory`; `grep autoballoon /etc/xen/xl.conf` | Fijá `dom0_mem=X,max:X`; poné `autoballoon="off"` |
| `xl migrate` falla en el target | Desajuste de versión, sin almacenamiento compartido, auth SSH, brecha de features de CPU | Leé el stderr de ambos lados; `xl info` en cada uno | Hacé coincidir versiones de Xen; almacenamiento compartido; enmascarado con `cpuid` |
| `xl dmesg`: `grant table ... exhausted` | Demasiados frontends de alto throughput | `xl dmesg \| grep grant` | Subí `gnttab_max_frames=` en la línea de comandos de Xen |
| PCI passthrough: el guest no ve el dispositivo | IOMMU apagado, dispositivo no ligado a `xen-pciback` | `xl info \| grep iommu`; `xl pci-assignable-list` | Habilitá VT-d; `xl pci-assignable-add 0000:04:00.0` |
| `state` de vif/vbd atascado en < 4 en XenStore | Driver backend no cargado en Dom0 | `xenstore-ls /local/domain/<id>/device` | `modprobe xen-netback xen-blkback` |

### 5.3 Verificación de passthrough (cuando `pci=` está en juego)

```
$ sudo xl info | grep -o iommu
iommu
$ sudo xl pci-assignable-list           # devices bound to xen-pciback, ready to pass
0000:04:00.0
$ sudo xl pci-assignable-add 0000:04:00.0    # deprivilege a device
$ sudo xl pci-attach hvm-win01 0000:04:00.0  # hot-attach to a running guest
$ sudo xl pci-list hvm-win01
Vdev Device
04.0 0000:04:00.0
```

Si `pci-assignable-add` falla, el dispositivo todavía es propiedad de un driver de Dom0 — ligalo a `xen-pciback` en el boot (`xen-pciback.hide=(04:00.0)` en la línea de comandos del Linux de Dom0) o desligá/religá a mano vía `/sys/bus/pci/drivers/`.

### 5.4 El bucle de depuración disciplinado

1. **`xl dmesg`** — verdad a nivel del hipervisor (grant tables, triple faults, fallas de IOMMU, warnings del scheduler).
2. **`/var/log/xen/xl-<domain>.log`** — qué intentó el toolstack y cómo falló.
3. **`/var/log/xen/qemu-dm-<domain>.log`** — fallas del device model de HVM (disco, NIC, firmware).
4. **`xenstore-ls /local/domain/<id>`** — ¿el handshake frontend/backend llegó a `state=4`? Esto distingue "el dispositivo nunca se ofreció" de "el dispositivo se ofreció pero falta el driver del guest".
5. **`xl create -c`** — recreá con la consola adjunta y observá bootear al guest en tiempo real; atrapa fallas de pygrub, del dispositivo root y del initrd al instante.
6. **`xentop`** — una vez corriendo, ¿un vecino está saturando CPU/disco/red? `VBD_OO` y `NETTX/NETRX` lo localizan.

---

## 6. Referencias

- **LPI — Exam 305-300 Objectives (v3.0), Topic 351.2 Xen** — https://www.lpi.org/our-certifications/exam-305-objectives/
- **Xen Project — Official Documentation Hub** — https://xenproject.org/help/documentation/
- **Xen Project Wiki — Xen Project Software Overview (architecture, PV/HVM/PVH)** — https://wiki.xenproject.org/wiki/Xen_Project_Software_Overview
- **Xen Project Wiki — `xl` (toolstack)** — https://wiki.xenproject.org/wiki/XL
- **Xen Project Wiki — PVH (DomU) design** — https://wiki.xenproject.org/wiki/PVH_(Domain_0)  and  https://wiki.xenproject.org/wiki/Understanding_the_Virtualization_Spectrum
- **Xen Project Wiki — Xen Networking (bridging, routing, NAT)** — https://wiki.xenproject.org/wiki/Xen_Networking
- **Xen Project Wiki — Storage options** — https://wiki.xenproject.org/wiki/Storage_options
- **`xl(1)` man page** — https://xenbits.xen.org/docs/unstable/man/xl.1.html
- **`xl.cfg(5)` — domain configuration syntax** — https://xenbits.xen.org/docs/unstable/man/xl.cfg.5.html
- **`xl.conf(5)` — global toolstack configuration** — https://xenbits.xen.org/docs/unstable/man/xl.conf.5.html
- **`xentop(1)`** — https://xenbits.xen.org/docs/unstable/man/xentop.1.html
- **Xen Project — Xen Hypervisor Command Line Options** — https://xenbits.xen.org/docs/unstable/misc/xen-command-line.html
- **Xen Project Wiki — PCI Passthrough (VT-d / xen-pciback)** — https://wiki.xenproject.org/wiki/Xen_PCI_Passthrough
- **Xen Project Wiki — Xen Project Schedulers (Credit2, RTDS, null)** — https://wiki.xenproject.org/wiki/Xen_Project_Schedulers
- **Xen Project Wiki — Live Migration** — https://wiki.xenproject.org/wiki/Migration
- **Xen Project Wiki — XenStore** — https://wiki.xenproject.org/wiki/XenStore
- **Debian Wiki — Xen** — https://wiki.debian.org/Xen