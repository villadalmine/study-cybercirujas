# 351.1 — Conceptos y teoría de la virtualización

> Examen 305-300, versión 3.0 · Peso del objetivo: 10 · Track: Virtualization

---

## 1. El problema de producción: por qué existe un hipervisor

Un servidor físico es una pobre unidad de asignación. Una máquina de doble socket con 128 CPUs lógicas, 1 TiB de RAM y NVMe medido en millones de IOPS pasa la mayor parte de su vida ociosa, porque las cargas de trabajo asignadas a ella fueron dimensionadas para el pico, no para el promedio, y porque el operador quiere **aislamiento de fallos** entre inquilinos que un solo kernel no puede dar. El clásico centro de datos previo a la virtualización funcionaba con una utilización de CPU promedio del 5–15% mientras pagaba el 100% del costo de energía, refrigeración, rack y depreciación. Esa brecha —capacidad comprada vs. capacidad usada— es el motor económico de todo el campo.

La virtualización es la técnica de interponer una capa de software (y, desde 2005–2006, asistida por hardware) que multiplexa un conjunto de recursos físicos en muchos **entornos de ejecución aislados y planificables de forma independiente**, cada uno convencido de que es dueño de la máquina. Las propiedades arquitectónicas que a un SRE realmente le importan:

| Propiedad | Qué te aporta en producción |
|---|---|
| **Consolidación** | Empaquetar N guests por host; llevar la utilización de ~10% hacia 60–80% |
| **Aislamiento** | Un kernel panic, fork bomb o CVE en un guest no tumba a sus vecinos |
| **Encapsulación** | El estado completo de la máquina es un conjunto de archivos → snapshot, clonar, plantilla, migrar |
| **Independencia del hardware** | El guest ve un chipset virtual estable; el host físico por debajo puede cambiar |
| **Migración en vivo** | Mover una carga de trabajo en ejecución fuera de un host para mantenimiento con una interrupción de menos de un segundo |
| **Programabilidad** | La máquina es ahora una llamada de API; esta es la precondición para IaaS y para la nube |

Los tres requisitos formales que una arquitectura virtualizable debe satisfacer fueron enunciados por **Popek y Goldberg (1974)**: *equivalencia* (un programa se ejecuta de forma idéntica, salvo por el timing), *control de recursos* (el VMM tiene control completo de los recursos) y *eficiencia* (una fracción estadísticamente dominante de las instrucciones se ejecuta directamente en la CPU, no emulada). Su teorema central: una máquina es virtualizable de forma eficiente si toda instrucción **sensible** (una que cambia o depende del estado privilegiado) es un subconjunto de las instrucciones **privilegiadas** (una que produce un trap al ejecutarse fuera del ring 0). x86 célebremente *violaba* esto hasta VT-x/AMD-V — 17 instrucciones (p. ej. `SGDT`, `SIDT`, `SMSW`, `POPF`) leen o escriben estado privilegiado sin producir un trap en modo usuario. Ese único hecho explica por qué la virtualización x86 temprana necesitaba traducción binaria o paravirtualización, y por qué toda la industria pivoteó hacia la asistencia por hardware.

---

## 2. Taxonomía: tipos de hipervisor y técnicas de virtualización

### 2.1 Hipervisores de Tipo 1 vs Tipo 2 (ubicación del VMM según Popek/Goldberg)

```
   TYPE 1 (bare-metal / native)              TYPE 2 (hosted)
 ┌───────┐ ┌───────┐ ┌───────┐        ┌───────┐ ┌───────┐
 │ Guest │ │ Guest │ │ Guest │        │ Guest │ │ Guest │
 └───┬───┘ └───┬───┘ └───┬───┘        └───┬───┘ └───┬───┘
     └─────────┼─────────┘                └────┬────┘
        ┌──────┴──────┐                   ┌────┴──────┐
        │  Hypervisor │                   │ Hypervisor│  (a process)
        └──────┬──────┘                   ├───────────┤
        ┌──────┴──────┐                   │  Host OS  │
        │   Hardware  │                   ├───────────┤
        └─────────────┘                   │  Hardware │
                                          └───────────┘
```

| | Tipo 1 (nativo/bare-metal) | Tipo 2 (hosted) |
|---|---|---|
| Se ejecuta sobre | Hardware desnudo, posee el ring −1/0 | Sobre un SO de propósito general |
| Ejemplos | Xen, VMware ESXi, Microsoft Hyper-V, KVM* | VMware Workstation/Fusion, VirtualBox, QEMU (solo userspace) |
| Sobrecarga | Menor; scheduler delgado | Mayor; dos schedulers apilados |
| Caso de uso | Centro de datos, IaaS en la nube | Laptops de desarrolladores, labs, pruebas anidadas |
| Dominio de fallo | El hipervisor es la TCB | El SO host + el hipervisor son la TCB |

**\*KVM es el clásico caso límite de la taxonomía.** `kvm.ko` es un módulo del kernel de Linux que convierte al *propio kernel Linux del host* en un hipervisor de Tipo 1 — el kernel se vuelve el VMM y planifica las VMs como procesos ordinarios (threads de `vhost`/vCPU). Como necesita un Linux completo ejecutándose en paralelo, algunos textos lo llaman Tipo 2. En términos de LPI: **KVM convierte el kernel de Linux en un hipervisor de Tipo 1**; cada guest es un proceso QEMU, cada vCPU un thread planificado por CFS/EEVDF como cualquier otro.

### 2.2 Técnicas de virtualización comparadas

| Técnica | ¿Kernel del guest modificado? | Mecanismo | Soporte de CPU necesario | Rend. | Aislamiento | Impl. canónica |
|---|---|---|---|---|---|---|
| **Emulación** | No | Interpretar/JIT de cada instrucción (traducción binaria dinámica) | Ninguno (cross-ISA OK) | Muy bajo | Completo | QEMU **TCG**, Bochs |
| **Virtualización completa (BT)** | No | Trap-and-emulate + traducción binaria de instrucciones sensibles en modo usuario | Ninguno (era pre-VT) | Medio | Completo | VMware ESX (pre-2006) |
| **Virt. completa asistida por hardware (HVM)** | No | La CPU añade VMX root/non-root (ring −1); las ops sensibles hacen VM-exit al hipervisor | Intel **VT-x** / AMD **AMD-V (SVM)** | Alto | Completo | KVM, Xen HVM, ESXi, Hyper-V |
| **Paravirtualización (PV)** | **Sí** | El guest reemplaza las ops privilegiadas con **hypercalls** al VMM | Ninguno (ese es el punto) | Alto | Completo | Xen PV, drivers virtio |
| **PVHVM / PVH** | Parcial | Contenedor HVM + drivers PV (disco/red) y boot/IRQ PV | VT-x/AMD-V | El más alto | Completo | Xen PVH, guests Xen modernos |
| **Nivel de SO / contenedores** | Kernel compartido | Namespaces + cgroups particionan un único kernel | Ninguno | Nativo | Más débil (kernel compartido) | LXC, Docker/runc, systemd-nspawn |

Dos distinciones que el examen indaga:

- **Emulación vs. Virtualización.** La emulación *reproduce el comportamiento* de un hardware que el host puede no tener físicamente (ejecutar ARM sobre x86 vía QEMU TCG); es lenta porque cada instrucción se traduce. La virtualización *ejecuta las instrucciones del guest de forma nativa en la CPU física* y solo hace trap de las sensibles. QEMU puede hacer ambas cosas: `-accel tcg` (emulación) vs. `-accel kvm` (virtualización por hardware). La **simulación** va todavía más allá — modela el comportamiento para análisis (p. ej. un simulador de red) sin ninguna promesa de ejecución fiel.

- **Virt. completa vs. Paravirt.** La virt. completa le da a un guest **sin modificar** una ilusión completa (BIOS, chipset virtual, todo) — el guest no sabe que es virtual. La paravirt. requiere un kernel del guest **modificado y consciente de la virtualización** que coopera con el hipervisor vía hypercalls; cambia transparencia por velocidad. El punto medio moderno —**virtio**— mantiene un guest HVM sin modificar pero instala *drivers* paravirtualizados para las rutas calientes (disco, red), obteniendo I/O casi nativo sin un kernel completamente modificado.

### 2.3 El modelo de rings de x86 y dónde se inserta VMX

```
Classic protection rings          With VT-x / AMD-V
┌─────────────────────┐           ┌─────────────────────┐  VMX non-root
│ Ring 3  user apps    │          │ Ring 3 user apps     │  (guest world)
│ Ring 2  (unused)     │          │ Ring 0 guest kernel  │  ← runs "as if" ring 0
│ Ring 1  (unused)     │          └──────────┬──────────┘
│ Ring 0  kernel/VMM   │              VM-exit │ VM-entry
└─────────────────────┘           ┌──────────┴──────────┐  VMX root
                                   │ Ring 0 hypervisor    │  (host world, "ring −1")
                                   └─────────────────────┘
```

La asistencia por hardware añade un eje **root/non-root** ortogonal a los rings. El kernel del guest se ejecuta realmente en el ring 0 *del modo non-root*; los eventos sensibles provocan un **VM-exit** hacia el hipervisor (modo root), que los maneja y emite un **VM-entry** para reanudar. El bloque de control por vCPU es la **VMCS** (Intel) / **VMCB** (AMD). Dos características de hardware importan enormemente para el rendimiento:

- **SLAT / paginación anidada** — Intel **EPT** (Extended Page Tables) / AMD **NPT/RVI** (Nested/Rapid Virtualization Indexing). Sin esto, el hipervisor mantiene **shadow page tables** y toma un VM-exit en cada edición de la tabla de páginas del guest — brutal para cargas de trabajo con mucho fork. SLAT permite que la MMU recorra guest-virtual → guest-physical → host-physical en hardware.
- **TLBs etiquetadas** — **VPID** (Intel) / **ASID** (AMD) etiquetan las entradas de la TLB por VM para que un cambio de mundo (world switch) no vacíe toda la TLB.

---

## 3. Los stacks concretos: Xen, QEMU, KVM, libvirt

### 3.1 Arquitectura de Xen

Xen es un **hipervisor de Tipo 1 al estilo microkernel** que arranca *antes* que Linux. Ejecuta un dominio de control privilegiado, **Dom0**, que posee los drivers de dispositivos físicos y el toolstack; los guests no privilegiados son **DomU**. El I/O fluye a través de un **modelo de driver dividido** (split driver model): un *backend* (`netback`, `blkback`) en Dom0 habla con un *frontend* (`netfront`, `blkfront`) en el guest sobre **ring buffers de memoria compartida** y **event channels** (las IRQs virtuales de Xen), coordinados a través del **XenStore** y las **grant tables** (compartición controlada de memoria).

```
        ┌──────────┐   ┌──────────┐   ┌──────────┐
        │  Dom0    │   │  DomU    │   │  DomU    │
        │ (Linux)  │   │ PV/HVM   │   │ PVH      │
        │ drivers, │   │ guest    │   │ guest    │
        │ toolstack│   │          │   │          │
        └────┬─────┘   └────┬─────┘   └────┬─────┘
             └───────event channels / grant tables───────┐
        ┌──────────────────────────────────────────────┐ │
        │                 Xen Hypervisor                │◄┘
        └──────────────────────────────────────────────┘
        ┌──────────────────────────────────────────────┐
        │  CPU · RAM · NICs · storage (owned via Dom0)  │
        └──────────────────────────────────────────────┘
```

**Modos de guest de Xen** (la progresión histórica):

| Modo | Boot | Ops privilegiadas | I/O | Notas |
|---|---|---|---|---|
| **PV** | Bootloader PV (pygrub/pvgrub), sin BIOS | Hypercalls (kernel modificado) | front/backend PV | No requiere VT-x; no puede ejecutar Windows; preocupaciones de seguridad de la era Meltdown |
| **HVM** | BIOS emulada + modelo de dispositivos QEMU | VM-exits de VT-x/AMD-V | Emulado *o* PV (PVHVM) | Ejecuta SO sin modificar incl. Windows |
| **PVHVM** | Contenedor HVM | HVM | Drivers PV | Boot HVM, I/O PV — punto óptimo común |
| **PVH** | Boot PV ligero, sin QEMU/BIOS | HVM (hardware) | PV | Predeterminado moderno: el más delgado, con la menor superficie de ataque |

El CLI del toolstack es **`xl`** (el viejo `xm`/xend fue removido). `xl list`, `xl create domU.cfg`, `xl migrate`, `xl console`.

### 3.2 QEMU + KVM

**QEMU** es un emulador de máquinas en espacio de usuario y un *modelo de dispositivos*: emula el chipset, el bus PCI, discos, NICs, VGA, etc. Por sí solo (TCG) es un emulador lento. **KVM** es la aceleración del kernel: `/dev/kvm` expone `ioctl`s (`KVM_CREATE_VM`, `KVM_CREATE_VCPU`, `KVM_RUN`) que permiten a QEMU ejecutar el código del guest de forma nativa vía VT-x/AMD-V. **QEMU provee el hardware virtual; KVM provee la rápida virtualización de CPU/MMU.** Juntos: cómputo casi nativo, virtio para I/O casi nativo.

```
  ┌─────────────────────────────┐
  │ QEMU process (userspace)     │  device emulation, migration,
  │  ├ vCPU thread → ioctl(KVM_RUN)  live-migration dirty tracking
  │  ├ vCPU thread → ioctl(KVM_RUN)
  │  └ vhost/iothread (virtio)   │
  └──────────────┬──────────────┘
        /dev/kvm  │ ioctl
  ┌──────────────┴──────────────┐
  │ kvm.ko + kvm_intel/kvm_amd   │  VM-entry/exit, EPT/NPT, VPID
  │ (host Linux kernel = VMM)     │
  └─────────────────────────────┘
```

### 3.3 libvirt — la capa de gestión neutral respecto al proveedor

**libvirt** es una API de gestión, un daemon (`libvirtd` / los modulares `virtqemud`, `virtnetworkd`, …) y un conjunto de herramientas que abstrae *por encima de* los hipervisores (QEMU/KVM, Xen, LXC, bhyve, ESXi, Hyper-V) a través de **drivers** direccionados por una URI de conexión. Define domains, redes, storage pools y secrets como **XML**, y es con lo que hablan herramientas como `virsh`, `virt-manager`, `virt-install`, Terraform, OpenStack Nova y oVirt. Notá la división de responsabilidad que confunde a la gente: **los domains de libvirt se describen en XML, no en YAML** — el YAML aparece un nivel más arriba (cloud-init, Ansible, Kubernetes/KubeVirt), nunca en la definición del domain en sí.

URIs de conexión (el `-c/--connect` que vas a tipear constantemente):

```
qemu:///system      # system-wide QEMU/KVM (root/privileged libvirtd)
qemu:///session     # per-user session instance
xen:///system       # Xen
lxc:///             # libvirt LXC
qemu+ssh://root@host/system   # remote over SSH — the migration transport
```

---

## 4. Definiciones de infraestructura completas y válidas

### 4.1 Un domain de producción libvirt/KVM (XML completo, sin recortar nada)

Este es un guest HVM realista: CPU host-passthrough, disk/net/rng/balloon virtio, firmware UEFI (OVMF), respaldo qcow2, hugepages, pinning de NUMA y una consola serie.

```xml
<domain type='kvm'>
  <name>web-prod-01</name>
  <uuid>4f8a1c2e-9b7d-4e3a-8f21-0c9a6b5d4e3f</uuid>
  <metadata>
    <role xmlns="urn:example:tags">frontend</role>
  </metadata>
  <memory unit='GiB'>8</memory>
  <currentMemory unit='GiB'>8</currentMemory>
  <memoryBacking>
    <hugepages>
      <page size='2' unit='MiB'/>
    </hugepages>
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
    <type arch='x86_64' machine='q35'>hvm</type>
    <loader readonly='yes' type='pflash'>/usr/share/OVMF/OVMF_CODE.fd</loader>
    <nvram>/var/lib/libvirt/qemu/nvram/web-prod-01_VARS.fd</nvram>
    <boot dev='hd'/>
  </os>
  <features>
    <acpi/>
    <apic/>
    <vmport state='off'/>
  </features>
  <cpu mode='host-passthrough' check='none' migratable='on'>
    <topology sockets='1' dies='1' cores='4' threads='1'/>
    <feature policy='require' name='vmx'/>  <!-- expose VT-x for nested -->
  </cpu>
  <clock offset='utc'>
    <timer name='rtc' tickpolicy='catchup'/>
    <timer name='pit' tickpolicy='delay'/>
    <timer name='hpet' present='no'/>
  </clock>
  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>restart</on_crash>
  <pm>
    <suspend-to-mem enabled='no'/>
    <suspend-to-disk enabled='no'/>
  </pm>
  <devices>
    <emulator>/usr/bin/qemu-system-x86_64</emulator>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2' cache='none' io='native' discard='unmap'/>
      <source file='/var/lib/libvirt/images/web-prod-01.qcow2'/>
      <target dev='vda' bus='virtio'/>
      <address type='pci' domain='0x0000' bus='0x04' slot='0x00' function='0x0'/>
    </disk>
    <interface type='network'>
      <mac address='52:54:00:6b:3c:9a'/>
      <source network='ovs-prod'/>
      <model type='virtio'/>
      <driver name='vhost' queues='4'/>
      <address type='pci' domain='0x0000' bus='0x01' slot='0x00' function='0x0'/>
    </interface>
    <console type='pty'>
      <target type='serial' port='0'/>
    </console>
    <channel type='unix'>
      <target type='virtio' name='org.qemu.guest_agent.0'/>
    </channel>
    <rng model='virtio'>
      <backend model='random'>/dev/urandom</backend>
    </rng>
    <memballoon model='virtio'>
      <stats period='10'/>
    </memballoon>
  </devices>
</domain>
```

Definilo y arrancalo:

```console
$ sudo virsh define web-prod-01.xml
Domain 'web-prod-01' defined from web-prod-01.xml

$ sudo virsh start web-prod-01
Domain 'web-prod-01' started

$ sudo virsh list --all
 Id   Name          State
------------------------------
 7    web-prod-01   running
 -    db-prod-02    shut off
```

### 4.2 cloud-init — dónde vive realmente el YAML (datasource NoCloud)

**cloud-init** es el motor de aprovisionamiento en el primer arranque de facto para imágenes de nube. Lee **meta-data** (identidad/red) y **user-data** (config) desde un *datasource* (EC2 IMDS, OpenStack, Azure IMDS, o el ISO semilla **NoCloud** local usado para KVM). El user-data de abajo es un `#cloud-config` válido:

```yaml
#cloud-config
hostname: web-prod-01
fqdn: web-prod-01.prod.example.com
manage_etc_hosts: true

users:
  - name: sre
    groups: [sudo]
    shell: /bin/bash
    sudo: ['ALL=(ALL) NOPASSWD:ALL']
    ssh_authorized_keys:
      - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIByT+example+key sre@bastion

package_update: true
package_upgrade: true
packages:
  - nginx
  - qemu-guest-agent
  - chrony

write_files:
  - path: /etc/nginx/conf.d/health.conf
    content: |
      server {
        listen 8080;
        location = /healthz { return 200 "ok\n"; }
      }
    permissions: '0644'

runcmd:
  - [ systemctl, enable, --now, qemu-guest-agent ]
  - [ systemctl, restart, nginx ]

power_state:
  mode: reboot
  condition: true
```

Y el `meta-data` correspondiente:

```yaml
instance-id: web-prod-01
local-hostname: web-prod-01
```

Construí la semilla NoCloud y adjuntala, luego dejá que cloud-init aprovisione en el primer arranque:

```console
$ cloud-localds seed.iso user-data meta-data
$ virt-install --name web-prod-01 --ram 8192 --vcpus 4 \
    --disk /var/lib/libvirt/images/web-prod-01.qcow2,bus=virtio \
    --disk seed.iso,device=cdrom \
    --os-variant debian12 --import --noautoconsole

$ virsh console web-prod-01
[   6.13] cloud-init[812]: Cloud-init v. 23.4.4 running 'modules:final'
[  11.02] cloud-init[812]: Cloud-init v. 23.4.4 finished at ... Up 11.0 seconds
```

### 4.3 Vagrant (proveedor libvirt) — topología de desarrollo reproducible

```ruby
Vagrant.configure("2") do |config|
  config.vm.box = "generic/debian12"
  config.vm.define "kvm-lab" do |node|
    node.vm.hostname = "kvm-lab"
    node.vm.provider :libvirt do |lv|
      lv.driver          = "kvm"
      lv.memory          = 4096
      lv.cpus            = 2
      lv.cpu_mode        = "host-passthrough"
      lv.nested          = true          # expose vmx/svm to the guest
      lv.machine_type    = "q35"
    end
  end
end
```

### 4.4 Descriptor OVF — el formato portable de appliance

**OVF (Open Virtualization Format, DMTF)** es un estándar de empaquetado neutral respecto al hipervisor. Un *paquete* OVF es: un descriptor XML `.ovf` (hardware virtual, requisitos de recursos), un **manifiesto** `.mf` opcional (checksums SHA), un `.cert` (firma), y una o más imágenes de disco (`.vmdk`, `.vhd`, `.qcow2`). Un **OVA** es simplemente ese conjunto completo empaquetado en un único archivo **`tar`** (el `.ovf` debe ser el primer miembro). Esqueleto de descriptor mínimo y válido:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<Envelope xmlns="http://schemas.dmtf.org/ovf/envelope/1"
          xmlns:rasd="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_ResourceAllocationSettingData"
          xmlns:vssd="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_VirtualSystemSettingData">
  <References>
    <File ovf:href="web-prod-01-disk1.vmdk" ovf:id="file1" ovf:size="4294967296"
          xmlns:ovf="http://schemas.dmtf.org/ovf/envelope/1"/>
  </References>
  <DiskSection>
    <Info>Virtual disks</Info>
    <Disk ovf:diskId="vmdisk1" ovf:fileRef="file1" ovf:capacity="20"
          ovf:capacityAllocationUnits="byte * 2^30"
          ovf:format="http://www.vmware.com/interfaces/specifications/vmdk.html#streamOptimized"
          xmlns:ovf="http://schemas.dmtf.org/ovf/envelope/1"/>
  </DiskSection>
  <VirtualSystem ovf:id="web-prod-01" xmlns:ovf="http://schemas.dmtf.org/ovf/envelope/1">
    <Info>A single-VM appliance</Info>
    <VirtualHardwareSection>
      <Info>Virtual hardware requirements</Info>
      <Item>
        <rasd:Description>Number of virtual CPUs</rasd:Description>
        <rasd:ElementName>4 virtual CPU(s)</rasd:ElementName>
        <rasd:ResourceType>3</rasd:ResourceType>
        <rasd:VirtualQuantity>4</rasd:VirtualQuantity>
      </Item>
      <Item>
        <rasd:AllocationUnits>byte * 2^20</rasd:AllocationUnits>
        <rasd:Description>Memory Size</rasd:Description>
        <rasd:ElementName>8192 MB of memory</rasd:ElementName>
        <rasd:ResourceType>4</rasd:ResourceType>
        <rasd:VirtualQuantity>8192</rasd:VirtualQuantity>
      </Item>
    </VirtualHardwareSection>
  </VirtualSystem>
</Envelope>
```

Empaquetá a un OVA y validá/desplegá:

```console
$ tar -cf web-prod-01.ova web-prod-01.ovf web-prod-01.mf web-prod-01-disk1.vmdk
$ tar -tvf web-prod-01.ova         # .ovf MUST be first
-rw-r--r-- 0/0   2841 web-prod-01.ovf
-rw-r--r-- 0/0    140 web-prod-01.mf
-rw-r--r-- 0/0  ...   web-prod-01-disk1.vmdk

# Convert an OVA for KVM/libvirt with virt-v2v (see §6)
$ virt-v2v -i ova web-prod-01.ova -o libvirt -os default
```

---

## 5. Capacidad de CPU, virtualización anidada y preparación del host

### 5.1 ¿Es el host capaz de virtualizar? (`/proc/cpuinfo`, `lscpu`)

Los flags de CPU cruciales: **`vmx`** = Intel VT-x, **`svm`** = AMD-V. Su presencia (y su habilitación en el BIOS) es la precondición para KVM/Xen HVM.

```console
$ egrep -o '(vmx|svm)' /proc/cpuinfo | sort -u
vmx

$ lscpu | grep -i virtual
Virtualization:                  VT-x
Virtualization type:             full

$ grep -E -c '(vmx|svm)' /proc/cpuinfo
16                     # nonzero → CPU supports HW virtualization on 16 logical CPUs
```

La verificación de conveniencia de Debian/Ubuntu:

```console
$ kvm-ok
INFO: /dev/kvm exists
KVM acceleration can be used
```

Si reporta **"KVM acceleration can NOT be used"** con el flag presente, la virtualización está deshabilitada en el firmware — reiniciá al UEFI/BIOS y habilitá *Intel VT-x* / *AMD SVM Mode* (y IOMMU/VT-d si querés PCI passthrough).

El chequeo previo (preflight) exhaustivo y nativo de libvirt:

```console
$ virt-host-validate qemu
  QEMU: Checking for hardware virtualization                     : PASS
  QEMU: Checking if device /dev/kvm exists                       : PASS
  QEMU: Checking if device /dev/kvm is accessible                : PASS
  QEMU: Checking if device /dev/vhost-net exists                 : PASS
  QEMU: Checking for cgroup 'cpu' controller support             : PASS
  QEMU: Checking for cgroup 'memory' controller support          : PASS
  QEMU: Checking for secure guest support                        : WARN (Unknown if this platform has Secure Guest support)
```

### 5.2 Virtualización anidada

La **virtualización anidada** ejecuta un hipervisor *dentro* de un guest — el guest L1 es él mismo un host HVM para guests L2. Esencial para: CI que prueba hipervisores/KVM, ejecutar minikube/kind con un driver KVM anidado, labs de entrenamiento en virtualización, e instancias de nube que necesitan ejecutar sus propias VMs. El mecanismo: la CPU física expone **`vmx`/`svm` a L1**, y L0 (el hipervisor real) *emula* las instrucciones VMX/SVM que L1 emite, reflejando (shadowing) la VMCS de L1 en una VMCS de hardware real. Funciona pero cuesta VM-exits adicionales — L2 es, de forma medible, más lento que L1.

```
 L2 guest  (nested VM)
   ▲  vmx/svm emulated by L0
 L1 guest  (acts as a hypervisor; sees vmx via cpu mode=host-passthrough)
   ▲  real VT-x/AMD-V
 L0 host   (physical hypervisor, kvm_intel nested=1)
```

Habilitá y verificá en el **host L0** (se muestra Intel; AMD es `kvm_amd`):

```console
$ cat /sys/module/kvm_intel/parameters/nested
N

$ sudo modprobe -r kvm_intel        # free the module (all VMs must be off)
$ echo "options kvm_intel nested=1" | sudo tee /etc/modprobe.d/kvm.conf
$ sudo modprobe kvm_intel
$ cat /sys/module/kvm_intel/parameters/nested
Y
```

El domain L1 debe reenviar el flag de CPU (`<cpu mode='host-passthrough'/>` o `<feature name='vmx'/>` explícito como en §4.1). Luego, **dentro de L1**:

```console
l1$ egrep -o 'vmx' /proc/cpuinfo | head -1
vmx
l1$ virt-host-validate qemu | grep 'hardware virtualization'
  QEMU: Checking for hardware virtualization                     : PASS
```

---

## 6. Migración: P2V, V2V y migración en vivo

### 6.1 Terminología

| Término | Significado | Herramientas |
|---|---|---|
| **P2V** | Physical-to-Virtual: convertir una máquina bare-metal en ejecución/imagen en una imagen de VM | `virt-p2v` (arranca un ISO auxiliar en el host físico), VMware vCenter Converter |
| **V2V** | Virtual-to-Virtual: convertir una VM entre formatos de hipervisor (VMDK↔qcow2, VMX/OVA→libvirt) | `virt-v2v` |
| **Migración en frío (offline)** | Mover los archivos de una VM *apagada* a otro host | `scp`/`rsync` + `virsh define`, `virsh migrate --offline` |
| **Migración en vivo (online)** | Mover una VM *en ejecución* entre hosts con un downtime despreciable | `virsh migrate --live`, `xl migrate`, vMotion |
| **Migración de almacenamiento** | Mover los discos de la VM (con o sin el estado en ejecución) | `virsh migrate --copy-storage-all`, `blockcopy` |

### 6.2 P2V / V2V en la práctica

```console
# V2V: import a VMware OVA into KVM/libvirt, converting VMDK→qcow2 and
# injecting virtio drivers so the guest boots on the new virtual hardware.
$ virt-v2v -i ova legacy-app.ova -o libvirt -os default -of qcow2
[   0.0] Setting up the source: -i ova legacy-app.ova
[   2.4] Opening the source
[  15.1] Inspecting the source
[  27.8] Converting Debian GNU/Linux to run on KVM
        virt-v2v: This guest has virtio drivers installed.
[ 148.6] Copying disk 1/1
[ 401.2] Creating output metadata
[ 402.0] Finished output to libvirt
```

El modo de fallo crítico y no obvio de P2V/V2V: el guest estaba atado a hardware *emulado* (disco IDE, NIC e1000) y a su kernel le faltan los drivers virtio o su `/etc/fstab`/GRUB referencia nombres de dispositivo viejos → **arranca a una shell de initramfs o a un timeout de `dracut`**. `virt-v2v` inyecta los drivers y reescribe las configs precisamente para prevenir esto; un `qemu-img convert` hecho a mano no lo hace.

Conversión de formato a mano:

```console
$ qemu-img convert -p -O qcow2 legacy-app-disk1.vmdk legacy-app.qcow2
    (100.00/100%)
$ qemu-img info legacy-app.qcow2
image: legacy-app.qcow2
file format: qcow2
virtual size: 40 GiB (42949672960 bytes)
disk size: 12.3 GiB
cluster_size: 65536
```

### 6.3 Migración en vivo — la mecánica

La migración en vivo funciona copiando memoria de forma iterativa mientras el guest sigue ejecutándose (**pre-copy**), rastreando las páginas que el guest ensucia (dirty), reenviándolas en cada ronda hasta que el conjunto sucio restante es lo suficientemente pequeño para transferirse durante una breve pausa de **stop-and-copy** (típicamente < 300 ms). La alternativa, **post-copy**, transfiere un estado mínimo, reanuda la VM en el destino de inmediato, y pagina bajo demanda el resto por la red (convergencia más rápida, pero un fallo de red a mitad de la migración puede perder la VM).

| | Pre-copy (predeterminado) | Post-copy |
|---|---|---|
| La VM se ejecuta en | El origen hasta el cambio final | El destino casi de inmediato |
| Riesgo de convergencia | Puede no converger si el guest ensucia memoria más rápido que el ancho de banda del enlace | Siempre converge |
| Impacto de un fallo | El origen sigue intacto → seguro de abortar | Fallo de red en el destino → VM perdida |
| Mitigaciones | `auto-converge` (frenar la vCPU), fallback a post-copy | Combinar con un precalentamiento (warm-up) pre-copy |

Prerrequisitos que el examen espera que enuncies: (1) **almacenamiento compartido o replicado** (NFS/iSCSI/Ceph) *o* `--copy-storage-all` para mover también los discos; (2) **compatibilidad de CPU** entre hosts (idéntica o un modelo base común — por esto `host-model` es más seguro que `host-passthrough` entre hosts heterogéneos); (3) tipos de máquina coincidentes y un transporte de libvirt alcanzable.

```console
# Live-migrate a running domain to another KVM host over SSH, keeping it
# defined persistently on the destination.
$ virsh migrate --live --verbose --persistent --undefinesource \
      web-prod-01 qemu+ssh://root@host-b/system
Migration: [100 %]

# For hosts WITHOUT shared storage, also stream the disks:
$ virsh migrate --live --copy-storage-all --verbose \
      web-prod-01 qemu+ssh://root@host-b/system

# Throttle the guest if it dirties memory too fast to converge:
$ virsh migrate-setmaxdowntime web-prod-01 500     # ms
$ virsh migrate --live --auto-converge web-prod-01 qemu+ssh://root@host-b/system
```

Equivalente en Xen:

```console
$ xl migrate web-prod-01 host-b
Migration successful.
```

---

## 7. Modelos de servicio en la nube y el nivel de contenedores

La virtualización es el sustrato; la nube es el modelo de negocio superpuesto encima. La escalera **XaaS** clasifica quién gestiona qué:

| Modelo | Gestionás vos | Gestiona el proveedor | Unidad entregada | Ejemplo |
|---|---|---|---|---|
| **IaaS** | SO, runtime, app, datos | Virtualización, servidores, almacenamiento, red | Máquinas virtuales, block storage, redes virtuales | EC2, OpenStack Nova, GCP Compute Engine |
| **PaaS** | App, datos | Runtime, SO y toda la infra | Plataforma de despliega-tu-código | Heroku, App Engine, Cloud Foundry |
| **SaaS** | Solo configuración/datos | Todo | Aplicación terminada | Gmail, Salesforce, Microsoft 365 |
| **CaaS** | Contenedores, imágenes | Orquestación, nodos, infra | Runtime/orquestación de contenedores | GKE, EKS, AKS, OpenShift |

```
 more control ◄─────────────────────────────────────► less to manage
 IaaS ───────────► CaaS ───────────► PaaS ───────────► SaaS
 (you run the OS)  (you ship images) (you push code)   (you just use it)
```

La **virtualización a nivel de contenedor / SO** (LXC, Docker/runc, `systemd-nspawn`) es la técnica que subyace a CaaS: en lugar de virtualizar hardware, particiona un **único kernel compartido** usando **namespaces** (pid, net, mnt, uts, ipc, user, cgroup — aíslan *lo que un proceso ve*) y **cgroups** (limitan *lo que puede usar*: CPU, memoria, IO, pids). El compromiso frente a las VMs es marcado y vale la pena enunciarlo con precisión:

| | VM (virtualización por hardware) | Contenedor (nivel de SO) |
|---|---|---|
| Kernel | Uno por guest | Kernel del host compartido |
| Frontera de aislamiento | Hardware/VMX — fuerte | Namespaces del kernel — más débil (el kernel es una superficie de ataque compartida) |
| Tiempo de boot / arranque | Segundos (boot completo del SO) | Milisegundos |
| Densidad | Decenas por host | Cientos–miles por host |
| Diversidad de SO guest | Cualquier SO (Windows sobre host Linux) | Solo mismo-kernel (Linux sobre Linux) |
| Sobrecarga | Memoria + CPU por SO guest | Casi nativa |
| Migración en vivo | Madura (vMotion, `virsh migrate`) | Inmadura (checkpoint/restore con CRIU) |

El punto de convergencia que el examen menciona es **KubeVirt** — ejecutar VMs completas *como* pods de Kubernetes — y **Kata Containers / microVMs Firecracker**, que envuelven cada contenedor en una VM reducida para recuperar un aislamiento de grado hardware con un costo de arranque similar al de un contenedor. Esa es la reconciliación de las dos columnas de arriba.

---

## 8. Playbook de verificación y diagnóstico de fallos

### 8.1 Confirmar qué se está ejecutando realmente (paravirt vs. HVM vs. bare metal)

```console
# Am I inside a VM, and which hypervisor? (systemd)
$ systemd-detect-virt
kvm

# Broader detector
$ virt-what
kvm

# The CPU tells you too: hypervisor flag present ⇒ virtualized
$ grep -o hypervisor /proc/cpuinfo | head -1
hypervisor

$ lscpu | grep -E 'Hypervisor|Virtualization'
Hypervisor vendor:               KVM
Virtualization type:             full
```

### 8.2 Tabla de triaje estructurada

| Síntoma | Causa probable | Diagnóstico | Solución |
|---|---|---|---|
| `virsh start` → *"KVM: Permission denied"* / *"failed to initialize KVM: Device or resource busy"* | Otro hipervisor tiene tomado `/dev/kvm` (p. ej. VirtualBox), o el usuario no está en el grupo `kvm`/`libvirt` | `lsof /dev/kvm`; `ls -l /dev/kvm`; `groups` | Detener el otro VMM; `usermod -aG libvirt,kvm $USER` |
| VM creada pero *lentísima*, `qemu` al 100% de CPU en un thread | Cayendo a **emulación TCG**, no KVM | `virsh dumpxml NAME \| grep '<domain type'` muestra `type='qemu'` no `'kvm'` | Habilitar VT-x/AMD-V en el firmware; `domain type='kvm'`; verificar `virt-host-validate` |
| El guest anidado (L2) no obtiene virt. por hardware | L0 con `nested=0` o la CPU de L1 no expone `vmx/svm` | `cat /sys/module/kvm_intel/parameters/nested`; `grep vmx /proc/cpuinfo` en L1 | Poner `nested=1`; usar `cpu mode='host-passthrough'` en L1 |
| La migración en vivo aborta: *"Unsafe migration: Migration without shared storage is unsafe"* | Los discos son locales, no están en almacenamiento compartido | `virsh domblklist NAME` | Agregar `--copy-storage-all`, o colocar los discos en NFS/Ceph |
| Migración en vivo: *"unable to find any master var store for loader"* o error de feature de CPU | Al destino le falta el OVMF/nvram coincidente o el modelo de CPU | Comparar `virsh capabilities` / CPU en ambos hosts | Usar `cpu mode='host-model'`; instalar el OVMF coincidente |
| La migración *nunca converge*, atascada al 99% | El guest ensucia memoria más rápido que el ancho de banda del enlace | `virsh domjobinfo NAME` muestra un "Memory remaining" creciente | `--auto-converge`, subir el max downtime, o cambiar a post-copy |
| El guest post-V2V arranca a la shell de `dracut`/initramfs | Faltan drivers virtio, nombres de dispositivo obsoletos en `fstab`/GRUB | Arrancar en rescate; inspeccionar `/etc/fstab`, módulos de initramfs | Reejecutar con `virt-v2v` (inyecta drivers), reconstruir el initramfs |
| `virt-host-validate` → los chequeos de IOMMU dan WARN, el PCI passthrough falla | VT-d/AMD-Vi deshabilitado o falta `intel_iommu=on` | `dmesg \| grep -i -e DMAR -e IOMMU` | Habilitar IOMMU en el BIOS; agregar `intel_iommu=on iommu=pt` al cmdline del kernel |

### 8.3 Inspección en vivo de un domain en ejecución

```console
$ virsh dominfo web-prod-01
Id:             7
Name:           web-prod-01
UUID:           4f8a1c2e-9b7d-4e3a-8f21-0c9a6b5d4e3f
OS Type:        hvm
State:          running
CPU(s):         4
CPU time:       182.3s
Max memory:     8388608 KiB
Used memory:    8388608 KiB
Persistent:     yes
Autostart:      disable
Managed save:   no

$ virsh domblklist web-prod-01
 Target   Source
--------------------------------------------------
 vda      /var/lib/libvirt/images/web-prod-01.qcow2

$ virsh domjobinfo web-prod-01           # during migration
Job type:         Unbounded
Operation:        Outgoing migration
Data processed:   3.412 GiB
Data remaining:   248.512 MiB
Memory processed: 3.402 GiB
Memory remaining: 248.512 MiB
Dirty rate:       12894 pages/s

# Verify the domain is truly KVM-accelerated, not emulated:
$ virsh dumpxml web-prod-01 | head -1
<domain type='kvm' id='7'>
```

### 8.4 Verificar la CPU virtual ofrecida y confirmar la capacidad de anidamiento de extremo a extremo

```console
# What CPU models can this host offer guests?
$ virsh cpu-models x86_64 | head
Skylake-Client-IBRS
Cascadelake-Server
EPYC-Rome
host-passthrough

# Inside the L1 guest, prove nesting works by launching a throwaway L2:
l1$ qemu-system-x86_64 -accel kvm -m 512 -nographic -kernel /boot/vmlinuz-$(uname -r) \
      -append "console=ttyS0" 2>&1 | head -2
    # If this starts under KVM (not "KVM not supported"), nesting is live.
```

---

## 9. Términos clave — referencia rápida

- **Hipervisor / VMM** — la capa que crea y ejecuta VMs; Tipo 1 (bare-metal) o Tipo 2 (hosted).
- **HVM** — Hardware Virtual Machine; virtualización completa acelerada por VT-x/AMD-V, guest sin modificar.
- **PV / Paravirtualización** — guest modificado y consciente de la virtualización usando hypercalls; no requiere asistencia por HW.
- **PVH / PVHVM** — modos híbridos de Xen que combinan contenedores HVM con drivers/boot PV para una superficie mínima.
- **Emulación vs. Virtualización** — la emulación traduce instrucciones (cross-ISA, lenta, QEMU TCG); la virtualización las ejecuta de forma nativa y hace trap solo de las sensibles.
- **SLAT** — Second-Level Address Translation: Intel **EPT** / AMD **NPT/RVI**; paginación de dos etapas por hardware.
- **VMCS / VMCB** — estructuras de control por vCPU para VT-x / AMD-V.
- **Dom0 / DomU** — el dominio de control privilegiado / el guest no privilegiado de Xen.
- **virtio** — interfaz de dispositivo paravirtualizada (net/blk/scsi/rng/balloon) para I/O casi nativo en guests HVM.
- **libvirt / virsh** — API/daemon de gestión de virtualización neutral respecto al proveedor y su CLI; **los domains son XML**.
- **OVF / OVA** — formato portable de appliance de DMTF (`.ovf` XML + discos + manifiesto `.mf`); OVA = ese conjunto como un único `tar`.
- **cloud-init** — aprovisionamiento en el primer arranque desde un datasource; el **user-data** `#cloud-config` es YAML.
- **P2V / V2V** — conversión physical-to-virtual / virtual-to-virtual (`virt-p2v`, `virt-v2v`).
- **Migración en vivo** — mover una VM en ejecución entre hosts; **pre-copy** (páginas sucias iterativas) vs. **post-copy** (paginación bajo demanda).
- **Virtualización anidada** — ejecutar un hipervisor dentro de un guest (`kvm_intel nested=1`).
- **IaaS / PaaS / SaaS / CaaS** — modelos de servicio en la nube según la división de la responsabilidad de gestión.

---

## 10. Referencias

- LPI — Exam 305-300 Objectives (LPIC-3 Virtualization and Containerization): https://www.lpi.org/our-certifications/exam-305-objectives/
- Popek, G. J.; Goldberg, R. P. — "Formal Requirements for Virtualizable Third Generation Architectures" (CACM, 1974): https://dl.acm.org/doi/10.1145/361011.361073
- Xen Project — Understanding the Virtualization Spectrum (PV, HVM, PVH): https://wiki.xenproject.org/wiki/Understanding_the_Virtualization_Spectrum
- Xen Project — `xl` toolstack documentation: https://xenbits.xen.org/docs/unstable/man/xl.1.html
- Linux KVM — main site and API documentation: https://linux-kvm.org/page/Main_Page
- Linux kernel — KVM `Documentation/virt/kvm/api`: https://www.kernel.org/doc/html/latest/virt/kvm/api.html
- Linux kernel — Nested VMX: https://www.kernel.org/doc/html/latest/virt/kvm/x86/nested-vmx.html
- QEMU — System Emulation documentation: https://www.qemu.org/docs/master/system/
- libvirt — Domain XML format reference: https://libvirt.org/formatdomain.html
- libvirt — Connection URIs / remote & migration: https://libvirt.org/uri.html and https://libvirt.org/migration.html
- libvirt — `virsh` manual: https://libvirt.org/manpages/virsh.html
- Intel — 64 and IA-32 Architectures Software Developer's Manual, Vol. 3C (VMX): https://www.intel.com/content/www/us/en/developer/articles/technical/intel-sdm.html
- AMD64 Architecture Programmer's Manual, Vol. 2 (Secure Virtual Machine, SVM): https://www.amd.com/en/support/tech-docs/amd64-architecture-programmers-manual-volumes-1-5
- DMTF — Open Virtualization Format (OVF) Specification (DSP0243): https://www.dmtf.org/standards/ovf
- cloud-init — official documentation: https://cloudinit.readthedocs.io/en/latest/
- libguestfs — `virt-v2v` and `virt-p2v` manuals: https://libguestfs.org/virt-v2v.1.html and https://libguestfs.org/virt-p2v.1.html
- NIST SP 800-145 — The NIST Definition of Cloud Computing (IaaS/PaaS/SaaS): https://csrc.nist.gov/publications/detail/sp/800-145/final