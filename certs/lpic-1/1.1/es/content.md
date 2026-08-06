# 1.1 System Architecture

## 1. Motivaci\u00f3n y Problema Arquitect\u00f3nico de Producci\u00f3n

En entornos de alta disponibilidad (H/A) y arquitecturas Cloud Native, la base de todo workload es el sistema operativo subyacente. Para un Site Reliability Engineer (SRE), entender la **System Architecture** a bajo nivel (desde la enumeraci\u00f3n de hardware hasta el init system) es crucial para resolver problemas de *boot loops*, *kernel panics* o degradaciones de performance (como cuellos de botella en buses PCI o conflictos de interrupciones IRQ). 

El problema cl\u00e1sico en producci\u00f3n es aprovisionar servidores f\u00edsicos (bare-metal) o instancias de m\u00e1quinas virtuales (VMs) de forma determinista. Un error en la configuraci\u00f3n del bootloader (GRUB2) o en la detecci\u00f3n de un dispositivo block storage puede resultar en que un nodo de un cl\u00faster de Kubernetes nunca reporte estado `Ready`. Entender el pipeline de booteo (BIOS/UEFI -> Bootloader -> Kernel -> Initramfs -> Init System/systemd) permite intervenir en las fases tempranas del ciclo de vida del nodo y asegurar que la plataforma base exponga los recursos de hardware adecuadamente a la capa de abstracci\u00f3n.

## 2. Comparativas T\u00e9cnicas y Trade-offs

Al dise\u00f1ar la arquitectura base de un entorno bare-metal o virtualizado, se deben tomar decisiones fundamentales sobre el firmware, particionado y el gestor de inicializaci\u00f3n (Init System).

### Firmware y Boot: BIOS vs. UEFI

| Caracter\u00edstica | BIOS / MBR | UEFI / GPT | Recomendaci\u00f3n SRE / Platform |
| :--- | :--- | :--- | :--- |
| **Arquitectura** | 16-bit, ejecuci\u00f3n secuencial, dependiente del `boot.img` en el sector 0. | 32/64-bit, entorno similar a un OS m\u00ednimo, ejecuci\u00f3n paralela. | **UEFI**: Est\u00e1ndar en la industria para plataformas modernas y Cloud. |
| **Soporte de Disco** | L\u00edmite de 2 TB (MBR). M\u00e1ximo 4 particiones primarias. | Soporta discos > 2 TB (Zettabytes te\u00f3ricos). Hasta 128 particiones por defecto. | **UEFI**: Permite bootear desde arreglos RAID/NVMe masivos en bare-metal. |
| **Seguridad** | Inexistente. Susceptible a bootkits. | Secure Boot (firmas criptogr\u00e1ficas de bootloaders y kernels). | **UEFI**: Cr\u00edtico para clusters con requerimientos de compliance (e.g., PCI-DSS). |

### Init Systems: SysVinit vs. systemd

| Caracter\u00edstica | SysVinit | systemd |
| :--- | :--- | :--- |
| **Modelo de Ejecuci\u00f3n** | Secuencial, basado en scripts de shell iterativos (`/etc/rc.d/`). | Paralelo, resoluci\u00f3n de dependencias por grafos (sockets, D-Bus, device events). |
| **Rendimiento** | Lento en el tiempo de booteo. Bloqueante si un demonio falla al iniciar. | Extremadamente r\u00e1pido. Inicializaci\u00f3n bajo demanda de servicios (socket activation). |
| **Estado y Control** | Runlevels num\u00e9ricos (0-6). Comandos fragmentados (`service`, `chkconfig`). | Targets sem\u00e1nticos (`multi-user.target`). Herramienta unificada (`systemctl`, `journalctl`). |
| **Aislamiento** | D\u00e9bil. Los procesos corren como hijos del PID 1 de forma laxa. | Fuerte (Cgroups v1/v2 nativo). Permite definir cuotas de CPU/Memoria por servicio. |

## 3. Manifiestos, Configuraci\u00f3n e Infraestructura

En la pr\u00e1ctica SRE, configuramos el hardware y el boot process mediante infraestructura como c\u00f3digo o reglas declarativas. A continuaci\u00f3n, un ejemplo de una regla **udev** completa para fijar permisos consistentes de un dispositivo NVMe custom, seguido de una unidad de **systemd** que asegura el montaje temprano y arranque de un componente de plataforma.

### Regla udev: `/etc/udev/rules.d/99-custom-nvme.rules`

```udev
# Asignar symlink predecible y permisos restrictivos a un disco NVMe de alta performance
# ATTR{model} extrae el modelo del dispositivo, SYMLINK+= crea un alias en /dev/
ACTION=="add|change", KERNEL=="nvme[0-9]*n[0-9]*", ATTRS{model}=="Samsung SSD 980 PRO*", GROUP="storage", MODE="0660", SYMLINK+="nvme-fast-db-%n"
```

### Configuraci\u00f3n del Bootloader (GRUB2): `/etc/default/grub`

Para un nodo optimizado, donde necesitamos aislar cores de CPU (para workloads en tiempo real o DPDK) y habilitar IOMMU para SR-IOV.

```bash
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR="$(sed 's, release .*$,,g' /etc/system-release)"
GRUB_DEFAULT=saved
GRUB_DISABLE_SUBMENU=true
GRUB_TERMINAL_OUTPUT="console"
# Kernel boot parameters para performance (isolcpus) y IOMMU
GRUB_CMDLINE_LINUX="crashkernel=auto resume=/dev/mapper/vg0-swap rd.lvm.lv=vg0/root rd.lvm.lv=vg0/swap console=tty0 console=ttyS0,115200 intel_iommu=on iommu=pt isolcpus=2-15 nohz_full=2-15 rcu_nocbs=2-15"
GRUB_DISABLE_RECOVERY="true"
```

### Servicio systemd: `/etc/systemd/system/platform-init.service`

```ini
[Unit]
Description=Platform Core Initialization Service
Documentation=https://internal-docs.company.com/platform
# Asegura que la red est\u00e1 arriba y el disco NVMe custom fue inicializado por udev
After=network-online.target local-fs.target dev-nvme\x2dfast\x2ddb\x2d1.device
Wants=network-online.target
Requires=dev-nvme\x2dfast\x2ddb\x2d1.device

[Service]
Type=oneshot
RemainAfterExit=yes
User=root
Group=root
# Uso de cgroups para limitar recursos de este script
MemoryMax=512M
CPUQuota=50%
ExecStartPre=/usr/bin/echo "Iniciando tuning de hardware..."
ExecStart=/usr/local/bin/hardware-tuning.sh
ExecStop=/usr/local/bin/hardware-teardown.sh
StandardOutput=journal
StandardError=journal

[Install]
# El equivalente en systemd a los antiguos runlevels 2,3,4 (multi-user)
WantedBy=multi-user.target
```

## 4. Comandos CLI y Salidas de Terminal Reales

### Enumeraci\u00f3n de Hardware (PCI, USB, CPU)

Para descubrir dispositivos subyacentes, vital en troubleshooting bare-metal:

```bash
# Listar topolog\u00eda de buses PCI y dispositivos, en formato de \u00e1rbol
$ lspci -tv
-[0000:00]-+-00.0  Intel Corporation 440FX - 82441FX PMC [Natoma]
           +-01.0  Intel Corporation 82371SB PIIX3 ISA [Natoma/Triton II]
           +-01.1  Intel Corporation 82371SB PIIX3 IDE [Natoma/Triton II]
           +-01.2  Intel Corporation 82371SB PIIX3 USB [Natoma/Triton II]
           +-01.3  Intel Corporation 82371AB/EB/MB PIIX4 ACPI
           +-02.0  Red Hat, Inc. Virtio console
           +-03.0  Red Hat, Inc. Virtio network device
           \-04.0  Red Hat, Inc. Virtio block device

# Obtener informaci\u00f3n detallada de los m\u00f3dulos del kernel cargados para un dispositivo PCI espec\u00edfico
$ lspci -nnk -s 00:03.0
00:03.0 Ethernet controller [0200]: Red Hat, Inc. Virtio network device [1af4:1000]
        Subsystem: Red Hat, Inc. Device [1af4:0001]
        Kernel driver in use: virtio-pci
        Kernel modules: virtio_pci

# Verificaci\u00f3n r\u00e1pida de CPU (útil para detectar si flag de virtualizaci\u00f3n VT-x/AMD-V est\u00e1 activo)
$ lscpu | grep -i virtualization
Virtualization:                  VT-x
```

### Gesti\u00f3n de M\u00f3dulos del Kernel

```bash
# Listar m\u00f3dulos cargados en el kernel actual, filtrando por 'virtio'
$ lsmod | grep virtio
virtio_net             57344  0
net_failover           20480  1 virtio_net
virtio_blk             20480  3
virtio_console         36864  1
virtio_pci             32768  0
virtio_pci_modern_dev    16384  1 virtio_pci
virtio_ring            36864  5 virtio_console,virtio_blk,virtio_net,virtio_pci
virtio                 16384  4 virtio_console,virtio_blk,virtio_net,virtio_pci

# Ver informaci\u00f3n profunda de un m\u00f3dulo espec\u00edfico
$ modinfo virtio_net
filename:       /lib/modules/5.15.0-101-generic/kernel/drivers/net/virtio_net.ko
alias:          virtio:d00000001v*
license:        GPL
description:    Virtio network driver
```

### Control de Boot Targets (Runlevels) con systemd

```bash
# Comprobar el target (runlevel) por defecto actual
$ systemctl get-default
multi-user.target

# Cambiar de manera temporal e inmediata al runlevel equivalente a rescate (single-user mode)
$ sudo systemctl isolate rescue.target

# Cambiar permanentemente el target por defecto a graphical (Runlevel 5)
$ sudo systemctl set-default graphical.target
Removed /etc/systemd/system/default.target.
Created symlink /etc/systemd/system/default.target -> /lib/systemd/system/graphical.target.
```

## 5. Gu\u00eda de Verificaci\u00f3n y Diagn\u00f3stico de Fallas

En el rol de SRE, cuando un sistema no levanta tras un reinicio (por ejemplo, despu\u00e9s de aplicar parches del kernel), se sigue este framework de diagn\u00f3stico:

1. **Revisi\u00f3n del Kernel Ring Buffer (`dmesg`)**:
   Verifica el output de los eventos tempranos del booteo buscando fallos de hardware o m\u00f3dulos.
   ```bash
   $ dmesg --level=err,warn | grep -i fail
   [    1.102345] acpi PNP0A03:00: fail to add MMCONFIG information
   ```

2. **Diagn\u00f3stico de Dispositivos USB/Block no detectados**:
   Si un disco o dispositivo conectado en caliente (hot-plug) no aparece:
   - Validar con `lsusb` o `lsblk`.
   - Releer el ring buffer (`dmesg -wH` en tiempo real).
   - Utilizar `udevadm monitor --environment` para interceptar eventos del subsistema udev en el momento en que se enchufa el hardware.
   ```bash
   $ udevadm monitor
   monitor will print the received events for:
   UDEV - the event which udev sends out after rule processing
   KERNEL - the kernel uevent
   ```

3. **Auditor\u00eda del Init System y Tiempo de Boot (`systemd-analyze`)**:
   Si el servidor tarda demasiado en arrancar, perdiendo SLIs cr\u00edticos:
   ```bash
   $ systemd-analyze
   Startup finished in 1.488s (kernel) + 2.052s (userspace) = 3.541s.
   graphical.target reached after 2.040s in userspace.

   # Identificar cuellos de botella (blame)
   $ systemd-analyze blame | head -n 3
   1.120s systemd-networkd-wait-online.service
    650ms kubelet.service
    230ms snapd.service
   ```

4. **Regenerar GRUB o Initramfs**:
   Si modificaste par\u00e1metros del kernel en `/etc/default/grub` o agregaste un m\u00f3dulo obligatorio para boot en `/etc/modules`, debes regenerar el payload para el bootloader:
   - En Debian/Ubuntu: `update-grub` y `update-initramfs -u`.
   - En RHEL/CentOS/Rocky: `grub2-mkconfig -o /boot/grub2/grub.cfg` (o `/boot/efi/EFI/redhat/grub.cfg` para UEFI) y `dracut -f`.

## 6. Referencias

* LPIC-1 Objetivos (Topic 101): [https://www.lpi.org/our-certifications/exam-101-objectives](https://www.lpi.org/our-certifications/exam-101-objectives)
* systemd Official Documentation: [https://systemd.io/](https://systemd.io/)
* udev Manual (Freedesktop): [https://www.freedesktop.org/software/systemd/man/udev.html](https://www.freedesktop.org/software/systemd/man/udev.html)
* GRUB 2 Manual (GNU): [https://www.gnu.org/software/grub/manual/grub/grub.html](https://www.gnu.org/software/grub/manual/grub/grub.html)