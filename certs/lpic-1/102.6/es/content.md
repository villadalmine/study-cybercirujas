# 102.6 — Linux como invitado de virtualización

**Certificación:** LPIC-1 (Exámenes 101-500 / 102-500), versión 5.0
**Peso del objetivo:** 1.56 (normalizado) — 1 punto en la ponderación cruda de LPI
**Alcance (paráfrasis original del objetivo de LPI):** entender qué es una máquina virtual y qué es un contenedor; conocer los bloques constructivos de una instancia de nube IaaS (cómputo, almacenamiento en bloque, red); saber qué propiedades de una instalación de Linux deben volverse únicas antes de clonarla o convertirla en plantilla; saber cómo las imágenes de sistema despliegan VMs, instancias de nube y contenedores; conocer las extensiones del lado del invitado que integran Linux con un hipervisor; estar al tanto de `cloud-init`.

> **Verificación de realidad para el día del examen.** LPI pondera este objetivo con 1 punto sobre 60 — estadísticamente ~1 pregunta por forma de examen. El material siguiente es deliberadamente más profundo que eso, porque *todo* sistema Linux de producción que un SRE toca en 2026 es invitado de algo, y los modos de falla de este objetivo (`machine-id` duplicado, claves de host SSH duplicadas, falta de `virtio` en el initramfs, `cloud-init` que silenciosamente nunca corrió) son los que te despiertan a las 03:00. Aprendé primero la superficie del examen (§13), y quedate con el resto como runbook.

---

## 1. El problema de producción: la golden image que no era única

Un equipo de plataforma construye una única imagen endurecida de Debian 12 con Packer, la publica como `base-deb12-2026.08`, y estampa 40 VMs a partir de ella en un clúster KVM/libvirt. En menos de una hora:

- Tres VMs se pelean por `10.20.4.117`. `arping -D` reporta detección de dirección duplicada. El servidor DHCP insiste en que entregó un solo lease.
- `journalctl` en el host central de logs intercala entradas de lo que parece ser una única máquina que se teletransporta entre racks.
- El `known_hosts` del bastión SSH coincide con cada host nuevo al primer intento — nadie lo nota, porque "simplemente funciona".
- El escáner de vulnerabilidades reporta 1 activo en lugar de 40.

Ninguno de estos es un bug de red. Todos son el mismo bug: **la imagen cargaba identidad que debería haberse generado por instancia.**

La colisión DHCP es la más aguda. `systemd-networkd` usa por defecto `ClientIdentifier=duid`, y su DUID por defecto es un DUID-EN derivado de `/etc/machine-id`. Cloná `/etc/machine-id`, y cada clon presenta el *mismo* identificador de cliente DHCPv4. Un servidor DHCP conforme al estándar indexa el lease por el identificador de cliente, no por la MAC — así que devuelve alegremente la misma IP a lo que cree que es una máquina cambiando de placas de red. Tres VMs, un lease, una IP, tres hilos furiosos de Slack.

La regla arquitectónica que se desprende:

> **Una imagen es una plantilla de *estado*, nunca de *identidad*.** La identidad se acuña en el primer arranque, en la instancia, por la instancia. Cualquier cosa en la imagen que nombre unívocamente a un host es un defecto, y es un defecto que herramientas gratuitas pueden detectar antes de que la imagen se publique.

Todo lo demás en este objetivo — `machine-id`, IDs de D-Bus, claves de host SSH, `cloud-init`, drivers de invitado — es maquinaria al servicio de esa única regla, más la regla de rendimiento que la sigue: un invitado que no carga drivers paravirtualizados está pagando un impuesto de emulación que no tiene por qué pagar.

---

## 2. Taxonomía: qué está ejecutando realmente tu carga de trabajo

### 2.1 El espectro de aislamiento

La virtualización no es una sola cosa. Del aislamiento más fuerte al más débil:

| Tecnología | Kernel que ve la carga de trabajo | Frontera de aislamiento | Tiempo de arranque (típico) | Densidad (por host de 64 GiB) | Sobrecarga | Uso canónico |
|---|---|---|---|---|---|---|
| Bare metal | El suyo propio | Hardware | 60–300 s | 1 | 0% | Crítico en latencia, licenciamiento, passthrough PCI |
| **Hipervisor de tipo 1** (KVM, Xen, ESXi, Hyper-V) | Kernel del invitado | Extensiones de virtualización de CPU (VT-x/AMD-V), IOMMU | 5–30 s | 20–60 | 2–10% | IaaS general, multi-tenant |
| Hipervisor de tipo 2 (VirtualBox, VMware Workstation, QEMU/TCG) | Kernel del invitado | Kernel del host + VMM en espacio de usuario | 10–40 s | 5–15 | 5–40% | Desarrollo, laboratorios |
| **microVM** (Firecracker, Cloud Hypervisor, QEMU microvm) | Kernel del invitado | Igual que tipo 1, modelo de dispositivos mínimo | 100–250 ms | 100–1000 | 3–8% | FaaS, sandboxes por tenant |
| Contenedor con sandbox (Kata, gVisor) | Kernel del invitado (Kata) / kernel en espacio de usuario (gVisor) | Frontera de VM / intercepción de syscalls con seccomp+ptrace | 200 ms–1 s | 100–400 | 5–20% | Kubernetes multi-tenant no confiable |
| **Contenedor de sistema** (LXC/LXD, `systemd-nspawn`) | **Kernel del host** | Namespaces + cgroups + LSM | 0.3–2 s | 200–800 | <2% | "Un Linux con forma de VM sin una VM" |
| **Contenedor de aplicación** (Docker/Podman, OCI) | **Kernel del host** | Namespaces + cgroups + seccomp + caps | 20–200 ms | 500–5000 | <2% | Un árbol de procesos por imagen |

La distinción que sostiene el peso, tanto para el examen como para la respuesta a incidentes:

- **Una máquina virtual ejecuta su propio kernel.** Arranca firmware, un bootloader y un kernel; tiene su propio `/proc`, su propio planificador, sus propias tablas de páginas (sombreadas o asistidas por EPT/NPT). Un kernel panic dentro de ella no toca al host.
- **Un contenedor comparte el kernel del host.** Es una *vista* del host — un conjunto de namespaces (`mnt`, `pid`, `net`, `ipc`, `uts`, `user`, `cgroup`, `time`) más límites de cgroup más una superficie de syscalls filtrada. No hay kernel de invitado, ni bootloader, ni BIOS. Un kernel panic de contenedor *es* un kernel panic del host.

### 2.2 Contenedor de sistema vs contenedor de aplicación

Ambos usan las mismas primitivas del kernel; difieren en intención y por lo tanto en contenido.

| | Contenedor de sistema | Contenedor de aplicación |
|---|---|---|
| PID 1 | `systemd` / `init` | La aplicación (`nginx`, `java`, …) |
| Sistema de archivos | Rootfs completo de la distro | Conjunto mínimo de capas, a menudo distroless |
| Duración | De vida larga, mascotas, actualizado in situ | Efímero, ganado, reemplazado por una imagen nueva |
| Mutabilidad | Mutable; hacés `apt upgrade` adentro | Inmutable; reconstruís la imagen |
| Herramientas típicas | LXD, `systemd-nspawn`, `machinectl` | Docker, Podman, containerd, CRI-O |
| Red | Habitualmente un veth en bridge con su propia IP | Mapeo de puertos / CNI / service mesh |
| ¿Cron, syslog, sshd adentro? | Sí, normal | Antipatrón |
| Formato de imagen | Tarball de rootfs de la distro, imagen LXD | Imagen OCI (por capas, direccionada por contenido) |
| Análogo | Una VM liviana | Un proceso enlazado estáticamente con un sistema de archivos |

**Compromiso:** el contenedor de sistema te da operaciones familiares (entrar por ssh, correr `systemctl`, conservar estado) a costa de deriva de configuración y un rootfs gordo. El contenedor de aplicación te da reproducibilidad y rollback rápido a costa de tener que externalizar *todo* el estado y reaprender logging, secretos y ciclo de vida.

### 2.3 Paravirtualización vs emulación completa

Un hipervisor puede presentar un dispositivo de tres maneras:

| Modelo | Cómo funciona | Driver del invitado | Salidas (exits) por E/S | Rendimiento (lectura aleatoria de 4 KiB, backend NVMe) |
|---|---|---|---|---|
| **Emulación completa** | El VMM emula silicio real (Intel e1000, IDE, AHCI) registro por registro | Driver de hardware estándar | Muy alto (un VM exit por acceso a registro MMIO) | ~40–60 kIOPS |
| **Paravirtualización** | El invitado sabe que es virtual; habla un protocolo de buffers circulares (`virtio`) | `virtio_blk`, `virtio_net`, … | Bajo (por lotes, notificación al llenarse) | ~250–400 kIOPS |
| **Passthrough / SR-IOV** | Función física o VF asignada al invitado vía IOMMU | Driver nativo de la placa real | ~0 (DMA directo a la memoria del invitado) | Velocidad de línea; ~casi bare metal |

La paravirtualización es toda la razón por la que las "extensiones de invitado" existen como tema de examen. La diferencia de rendimiento no es marginal:

| Métrica | `e1000` / IDE emulados | `virtio-net` / `virtio-blk` | `vhost-net` | VF SR-IOV |
|---|---|---|---|---|
| Rendimiento TCP en 10 GbE | 2.1–3.5 Gb/s | 7–9 Gb/s | 9.4 Gb/s | 9.9 Gb/s |
| PPS con paquetes chicos | ~180 k | ~700 k | ~1.4 M | ~14 M (DPDK) |
| CPU del host por Gb/s | Alta | Media | Baja | Casi cero |
| Migración en vivo | Sí | Sí | Sí | **No** (sin bonding de failover de VF) |
| Requiere driver en el invitado | No (estándar) | **Sí** | Sí | Sí (del fabricante) |

**El compromiso que tenés que poder enunciar:** los dispositivos paravirtualizados y de passthrough cambian *portabilidad* por *velocidad*. `virtio` necesita un driver en el invitado (fácil en Linux, requiere inyectar un driver en Windows). SR-IOV además renuncia a la migración en vivo, al overcommit de memoria y a los snapshots. Los dispositivos emulados funcionan en cualquier SO jamás escrito y te cuestan dos tercios de tu E/S.

---

## 3. Mecánica de la frontera: cómo sabe el invitado que es un invitado

Un SRE debe poder responder "¿sobre qué estoy corriendo?" con un solo comando, en una máquina sin ningún CLI de nube instalado.

### 3.1 La hoja (leaf) de hipervisor de CPUID

La arquitectura x86 reserva las hojas de CPUID `0x40000000`–`0x400000FF` para los hipervisores. El bit 31 de `ECX` de la hoja `0x1` es el **bit de hipervisor presente**; el kernel lo expone como el flag de CPU `hypervisor`.

```
$ grep -o ' hypervisor ' /proc/cpuinfo | head -1
 hypervisor 

$ lscpu | grep -Ei 'hypervisor|virtualization|model name'
Model name:                           Intel(R) Xeon(R) Platinum 8375C CPU @ 2.90GHz
Virtualization:                       VT-x
Hypervisor vendor:                    KVM
Virtualization type:                  full
```

La hoja `0x40000000` devuelve una firma de proveedor de 12 bytes en `EBX:ECX:EDX`:

```
# cpuid -1 -l 0x40000000
CPU:
   hypervisor_id (0x40000000):
      hypervisor_id = "KVMKVMKVM   "
```

| Firma | Hipervisor |
|---|---|
| `KVMKVMKVM` | KVM (QEMU/libvirt, OpenStack, Proxmox, oVirt) |
| `VMwareVMware` | VMware ESXi / Workstation / Fusion |
| `Microsoft Hv` | Hyper-V (y Azure, y WSL2) |
| `XenVMMXenVMM` | Xen HVM/PVH |
| `VBoxVBoxVBox` | VirtualBox (también reporta `KVMKVMKVM` en algunas configuraciones) |
| `bhyve bhyve` | bhyve de FreeBSD |
| `TCGTCGTCGTCG` | QEMU sin aceleración por hardware (emulación pura — estás por pasarla mal) |
| `ACRNACRNACRN` | ACRN (automotriz/embebido) |
| `prl hyperv` | Parallels |

### 3.2 El comando que hay que memorizar

```
$ systemd-detect-virt
kvm

$ systemd-detect-virt --vm
kvm

$ systemd-detect-virt --container
none

$ echo $?
1
```

El estado de salida es **0 cuando se detecta virtualización, 1 cuando se corre sobre bare metal** — lo que lo hace directamente utilizable en scripts y en `ConditionVirtualization=` en archivos de unidad. Valores de retorno representativos:

| Clase | Valores |
|---|---|
| VM | `qemu`, `kvm`, `amazon`, `zvm`, `vmware`, `microsoft`, `oracle`, `powervm`, `xen`, `bochs`, `uml`, `parallels`, `bhyve`, `qnx`, `acrn`, `apple`, `sre` |
| Contenedor | `openvz`, `lxc`, `lxc-libvirt`, `systemd-nspawn`, `docker`, `podman`, `rkt`, `wsl`, `proot`, `pouch` |
| Ninguno | `none` |

### 3.3 DMI/SMBIOS — la autodescripción del firmware

```
$ cat /sys/class/dmi/id/sys_vendor /sys/class/dmi/id/product_name
QEMU
Standard PC (Q35 + ICH9, 2009)

# dmidecode -s system-manufacturer
Amazon EC2
# dmidecode -s system-product-name
m6i.large
# cat /sys/devices/virtual/dmi/id/board_asset_tag
i-0abcd1234ef567890
```

Los archivos `/sys/class/dmi/id/*` son legibles por todo el mundo para los campos no sensibles, así que obtenés identificación de plataforma **sin root**. Dos hechos útiles en el campo: en EC2 Nitro el **ID de instancia está en `board_asset_tag`**, y en Azure el asset tag del chasis es la constante `7783-7084-3265-9085-8269-3286-77` — ambos te permiten identificar una instancia de nube cuando el servicio de metadatos está bloqueado por firewall.

| Plataforma | `sys_vendor` | `product_name` |
|---|---|---|
| KVM/QEMU | `QEMU` | `Standard PC (Q35 + ICH9, 2009)` |
| VMware | `VMware, Inc.` | `VMware Virtual Platform` / `VMware20,1` |
| Hyper-V / Azure | `Microsoft Corporation` | `Virtual Machine` |
| VirtualBox | `innotek GmbH` | `VirtualBox` |
| Xen HVM | `Xen` | `HVM domU` |
| AWS Nitro | `Amazon EC2` | tipo de instancia, p. ej. `m6i.large` |
| Google Compute Engine | `Google` | `Google Compute Engine` |

### 3.4 `virt-what` y rutas específicas de Xen

```
# virt-what
kvm

# for Xen PV:
$ cat /sys/hypervisor/type /sys/hypervisor/version/major
xen
4
$ ls /proc/xen
capabilities  privcmd  xenbus  xsd_kva  xsd_port
```

`virt-what` (de `libguestfs`) es un script de shell que apila heurísticas de CPUID, DMI, `/proc` y módulos; puede imprimir **más de una línea** (p. ej. `xen` y `xen-hvm`, o `kvm` y `openstack`). `systemd-detect-virt` imprime exactamente una y prefiere la tecnología más interna — relevante cuando tenés contenedores dentro de VMs.

### 3.5 Huella de plataforma en un solo tiro

```bash
#!/usr/bin/env bash
# /usr/local/sbin/whereami — identify the virtualization substrate. No root required.
set -euo pipefail

printf '%-22s %s\n' 'hostname:'    "$(hostnamectl --static 2>/dev/null || cat /etc/hostname)"
printf '%-22s %s\n' 'virt (systemd):' "$(systemd-detect-virt || true)"
printf '%-22s %s\n' 'container:'   "$(systemd-detect-virt --container || true)"
printf '%-22s %s\n' 'dmi vendor:'  "$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo n/a)"
printf '%-22s %s\n' 'dmi product:' "$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo n/a)"
printf '%-22s %s\n' 'asset tag:'   "$(cat /sys/class/dmi/id/board_asset_tag 2>/dev/null || echo n/a)"
printf '%-22s %s\n' 'cpu hypervisor:' "$(grep -qw hypervisor /proc/cpuinfo && echo present || echo absent)"
printf '%-22s %s\n' 'clocksource:' "$(cat /sys/devices/system/clocksource/clocksource0/current_clocksource)"
printf '%-22s %s\n' 'machine-id:'  "$(cat /etc/machine-id)"
printf '%-22s %s\n' 'virtio mods:' "$(lsmod | awk '/^virtio/{printf "%s ", $1}')"
printf '%-22s %s\n' 'guest agent:' "$(systemctl is-active qemu-guest-agent vmtoolsd hv_kvp_daemon 2>/dev/null | tr '\n' ' ')"
```

```
$ whereami
hostname:              web-01
virt (systemd):        kvm
container:             none
dmi vendor:            QEMU
dmi product:           Standard PC (Q35 + ICH9, 2009)
asset tag:             n/a
cpu hypervisor:        present
clocksource:           kvm-clock
machine-id:            5a5b0d3f1f9c4a1f8e2b7c6d4e3f2a10
virtio mods:           virtio_net virtio_blk virtio_console virtio_balloon virtio_rng virtio_pci virtio_ring virtio 
guest agent:           active inactive inactive
```

---

## 4. Drivers de invitado y extensiones de integración

### 4.1 La familia `virtio` (KVM, y cada vez más todo lo demás)

`virtio` es un **transporte paravirtual estandarizado de dispositivos** (especificación OASIS). El driver del invitado y el dispositivo del host comparten un conjunto de *virtqueues* — buffers circulares en la memoria del invitado — de modo que un lote de E/S cuesta una notificación en lugar de decenas de escrituras MMIO atrapadas.

| Módulo | Dispositivo | Qué te da | Falla si falta |
|---|---|---|---|
| `virtio_pci` | Transporte | Vincula dispositivos virtio en el bus PCI | Nada más funciona |
| `virtio_blk` | `/dev/vda` | E/S de bloque rápida | No se encuentra el dispositivo raíz → kernel panic |
| `virtio_scsi` | `/dev/sda` vía `virtio-scsi` | Semántica SCSI, `DISCARD`/UNMAP, >28 discos, multipath | El mismo panic |
| `virtio_net` | `eth0`/`ens3` | Red rápida, offloads, multiqueue | Sin red en absoluto |
| `virtio_balloon` | — | El host recupera RAM del invitado a demanda | Sin overcommit de memoria |
| `virtio_rng` | `/dev/hwrng` | Entropía desde el host | El arranque se traba por entropía, generación lenta de claves TLS |
| `virtio_console` | `/dev/hvc0`, `/dev/virtio-ports/*` | Consola serie, canal del agente de invitado | Agente de invitado muerto |
| `virtio_gpu` | Dispositivo DRM | Framebuffer acelerado | Solo consola de texto |
| `virtiofs` | Tipo de montaje `virtiofs` | Directorio del host compartido con semántica casi nativa | Sin FS compartido |
| `net_failover` | — | Empareja una VF con `virtio-net` para SR-IOV migrable | Sin migración en vivo con SR-IOV |

```
$ lspci -k
00:01.1 IDE interface: Intel Corporation 82371SB PIIX3 IDE [Natoma/Triton II]
	Kernel driver in use: ata_piix
00:03.0 Ethernet controller: Red Hat, Inc. Virtio network device
	Subsystem: Red Hat, Inc. Device 0001
	Kernel driver in use: virtio-pci
00:04.0 SCSI storage controller: Red Hat, Inc. Virtio block device
	Subsystem: Red Hat, Inc. Device 0002
	Kernel driver in use: virtio-pci

$ ls -l /sys/bus/virtio/devices/*/driver
lrwxrwxrwx 1 root root 0 Aug 26 09:12 /sys/bus/virtio/devices/virtio0/driver -> ../../../../bus/virtio/drivers/virtio_net
lrwxrwxrwx 1 root root 0 Aug 26 09:12 /sys/bus/virtio/devices/virtio1/driver -> ../../../../bus/virtio/drivers/virtio_blk
lrwxrwxrwx 1 root root 0 Aug 26 09:12 /sys/bus/virtio/devices/virtio2/driver -> ../../../../bus/virtio/drivers/virtio_balloon
```

Notá el vínculo de dos niveles: el driver **PCI** es `virtio-pci`; el driver de **función** (`virtio_net`, `virtio_blk`) se vincula en el bus sintético `virtio`. Leer solo `lspci -k` y concluir "falta el driver virtio_net" es un diagnóstico errado clásico.

IDs PCI que vale la pena reconocer: el proveedor `1af4` es "Red Hat, Inc." (el ID de proveedor de virtio); `1af4:1000` red legacy, `1af4:1001` bloque legacy, `1af4:1041`–`1af4:1049` dispositivos modernos (virtio 1.0).

### 4.2 Paquetes de integración por plataforma

Todo hipervisor incluye un paquete del lado del invitado que va más allá de los drivers: provee un canal de control fuera de banda para apagado ordenado, reporte de IP, congelamiento del sistema de archivos para snapshots consistentes, sincronización de hora e integración de portapapeles/pantalla.

| Plataforma | Paquete (RHEL / Debian) | Demonio(s) | Módulos del kernel | Qué se rompe sin él |
|---|---|---|---|---|
| **KVM/QEMU/libvirt** | `qemu-guest-agent` | `qemu-ga` | `virtio_console` | `virsh shutdown` cae de nuevo a ACPI; sin `domifaddr --source agent`; **los snapshots son consistentes ante caída, no consistentes a nivel de sistema de archivos** |
| **VMware ESXi** | `open-vm-tools` / `open-vm-tools` | `vmtoolsd` | `vmxnet3`, `vmw_pvscsi`, `vmw_balloon`, `vmwgfx`, `vmw_vsock_vmci_transport` | Sin apagado ordenado, sin IP en vCenter, sin snapshots en reposo (quiesced), NIC/HBA lentos |
| **Hyper-V / Azure** | `hyperv-daemons` / `linux-cloud-tools-virtual` | `hv_kvp_daemon`, `hv_vss_daemon`, `hv_fcopy_daemon` | `hv_vmbus`, `hv_netvsc`, `hv_storvsc`, `hv_utils`, `hv_balloon` | Sin inyección de IP, sin backups consistentes con VSS, sin copia de archivos host→invitado |
| **Xen (PV/PVHVM)** | in-kernel + `xe-guest-utilities` (XenServer) | `xe-daemon` | `xen_blkfront`, `xen_netfront`, `xen-pcifront`, `xenbus` | Sin métricas del invitado en XenCenter |
| **VirtualBox** | Guest Additions (fuera del árbol) | `VBoxService`, `VBoxClient` | `vboxguest`, `vboxsf`, `vboxvideo` | Sin carpetas compartidas, sin pantalla seamless, sin sincronización de hora |
| **AWS Nitro** | (in-kernel) `ena`, `nvme` | — | `ena`, `nvme` | La instancia no arrancará en los tipos de instancia modernos |

El agente de invitado de QEMU en la práctica — esta es la pieza que convierte un snapshot de "equivalente a tirar del cable de alimentación" en un backup consistente:

```
# guest side
$ systemctl enable --now qemu-guest-agent
$ ls -l /dev/virtio-ports/
lrwxrwxrwx 1 root root 12 Aug 26 09:12 org.qemu.guest_agent.0 -> ../vport1p1
```

```
# host side
# virsh domifaddr web-01 --source agent
 Name       MAC address          Protocol     Address
-------------------------------------------------------------------------------
 lo         00:00:00:00:00:00    ipv4         127.0.0.1/8
 enp1s0     52:54:00:6f:2a:11    ipv4         10.20.4.117/24

# virsh qemu-agent-command web-01 '{"execute":"guest-fsfreeze-freeze"}'
{"return":3}
# virsh snapshot-create-as web-01 --disk-only --atomic pre-upgrade
Domain snapshot pre-upgrade created
# virsh qemu-agent-command web-01 '{"execute":"guest-fsfreeze-thaw"}'
{"return":3}
```

`{"return":3}` es la cantidad de sistemas de archivos congelados, no un código de error.

### 4.3 Hora, entropía y memoria — los tres problemas silenciosos del invitado

**Hora.** El TSC de un invitado no es confiable a través de migraciones de host y de la desprogramación de vCPUs. KVM expone una fuente de reloj paravirtual:

```
$ cat /sys/devices/system/clocksource/clocksource0/available_clocksource
kvm-clock tsc acpi_pm
$ cat /sys/devices/system/clocksource/clocksource0/current_clocksource
kvm-clock
```

Para precisión sub-microsegundo, cargá `ptp_kvm` y alimentá a `chrony` con una referencia de reloj de hardware PTP atada al host — sin NTP de red de por medio:

```ini
# /etc/chrony/conf.d/ptp-kvm.conf
refclock PHC /dev/ptp0 poll 2 dpoll -2 offset 0 stratum 2
makestep 1.0 3
```

```
$ chronyc sources -v
MS Name/IP address         Stratum Poll Reach LastRx Last sample               
===============================================================================
#* PHC0                          2   2   377     3    -12ns[  -18ns] +/-  103ns
```

**Entropía.** Los invitados casi no tienen jitter de interrupciones de hardware. Sin `virtio_rng`, el primer arranque puede trabarse por minutos generando claves de host SSH.

```
$ cat /sys/class/misc/hw_random/rng_available
virtio_rng.0
$ cat /proc/sys/kernel/random/entropy_avail
256
```

(Desde Linux 5.6 `getrandom(2)` bloquea solo hasta que el CRNG esté sembrado, y 5.18+ reporta `entropy_avail` como 256 una vez listo — un runbook viejo que te dice que entres en pánico por debajo de 1000 es obsoleto.)

**Memoria.** `virtio_balloon` le permite al host recuperar RAM del invitado. Desde la perspectiva del invitado, la memoria desaparece silenciosamente:

```
# host
# virsh setmem web-01 2G --live
# guest
$ free -m
               total        used        free      shared  buff/cache   available
Mem:            1987         412        1103           4         471        1421
```

El compromiso: el ballooning habilita overcommit y mayor densidad, pero un invitado bajo ballooning puede ser matado por OOM por razones enteramente fuera de su propio control, y el `total` del invitado ya no coincide con el tamaño configurado de la VM — lo que rompe cualquier autoescalador o dimensionamiento de heap de JVM que lea `MemTotal`. En Kubernetes-sobre-VMs, deshabilitá el ballooning en los nodos worker o fijá `--reserve`.

---

## 5. Bloques constructivos de IaaS: cómputo, almacenamiento en bloque, red

Una "instancia" en cualquier IaaS es una composición de tres recursos con ciclos de vida independientes más un canal de identidad.

| Elemento | Qué es | Ciclo de vida | Artefacto del lado de Linux | Modo de falla |
|---|---|---|---|---|
| **Instancia de cómputo** | vCPU + RAM + un flavor/tipo de instancia, planificada sobre un hipervisor | Efímera; se puede detener, redimensionar, destruir | El kernel en ejecución; `lscpu`, `/proc/meminfo` | Falla del host = pérdida de la instancia salvo que la carga esté replicada |
| **Almacenamiento efímero / instance store** | Disco local al host hipervisor | Muere con la instancia (incluso al detener/arrancar) | `/dev/nvme1n1`, montado en `/mnt` | Pérdida de datos al detener; nunca pongas una base de datos acá |
| **Volumen de almacenamiento en bloque** | Disco virtual adjunto por red (Cinder, EBS, PD, VMDK sobre SAN) | Independiente de la instancia; snapshotable, re-adjuntable | `/dev/vdb`, `/dev/nvme1n1` | Desconectar sin desmontar = corrupción del sistema de archivos |
| **Almacenamiento de objetos** | Almacén clave/valor por HTTP | Independiente, efectivamente infinito | `s3fs`, `rclone`, o el SDK — **no es un sistema de archivos** | Tratarlo como POSIX; sin rename atómico, sin locks |
| **Red** | L2/L3 virtual: red VPC/tenant, subred, puerto, security group, IP flotante/elástica, balanceador de carga | Independiente | `ens3`, rutas, `nftables` | Confusión entre security group y firewall del host |
| **Servicio de metadatos** | Endpoint HTTP link-local en `169.254.169.254` que sirve identidad de la instancia y user-data | Por instancia | Consumido por `cloud-init` | Exposición a SSRF; bloqueado por un firewall demasiado celoso → sin `cloud-init` |
| **Imagen** | La plantilla arrancable | Artefacto versionado | `/` en el primer arranque | El tema de la §6 |

### 5.1 El servicio de metadatos, por nube

```
# AWS — IMDSv2 (session-oriented, mandatory on hardened accounts)
$ TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
      -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
$ curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
      http://169.254.169.254/latest/meta-data/instance-id
i-0abcd1234ef567890

# OpenStack
$ curl -s http://169.254.169.254/openstack/latest/meta_data.json | jq -r .uuid
c0ffee00-dead-4bee-9001-0123456789ab

# Google Compute Engine (header is mandatory — that is the SSRF defence)
$ curl -s -H 'Metadata-Flavor: Google' \
      http://metadata.google.internal/computeMetadata/v1/instance/id
4098723641098345670

# Azure
$ curl -s -H 'Metadata: true' \
      'http://169.254.169.254/metadata/instance?api-version=2021-02-01' | jq -r .compute.vmId
6a1b2c3d-4e5f-4a6b-8c9d-0e1f2a3b4c5d
```

| | AWS IMDSv1 | AWS IMDSv2 | GCP | Azure | OpenStack |
|---|---|---|---|---|---|
| Autenticación | ninguna | token emitido por PUT | cabecera obligatoria | cabecera obligatoria | ninguna |
| Límite de saltos | n/a | configurable (por defecto 1) | n/a | n/a | n/a |
| Seguro ante SSRF | **No** | Sí | Sí | Sí | No |
| ¿Alcanzable desde un contenedor? | Sí (red del host) | Solo si el límite de saltos ≥ 2 | Sí | Sí | Sí |

**Nota arquitectónica para ingenieros de plataforma:** el servicio de metadatos es la *credencial ambiental* de la instancia. En nodos de Kubernetes, bloqueá el egreso de los pods hacia `169.254.169.254` (NetworkPolicy, o `iptables`/`nftables` en el nodo) salvo que estés usando IRSA/Workload Identity — de lo contrario, cualquier pod que pueda hacer una petición HTTP hereda el rol IAM del nodo. Esta es la desconfiguración de nube más explotada de todas, y vive exactamente en la frontera que describe este objetivo.

### 5.2 Agrandar un disco raíz después de un redimensionamiento

Redimensionar el volumen en la API del IaaS no hace nada dentro del invitado. Hay que avisarle a cada una de las tres capas:

```
# 1. The kernel must see the new size (usually automatic for virtio-blk)
# echo 1 > /sys/class/block/vda/device/rescan   # for SCSI: .../device/rescan

# 2. The partition table
# growpart /dev/vda 1
CHANGED: partition=1 start=2048 old: size=41940992 end=41943040 new: size=209713119 end=209715167

# 3. The filesystem
# resize2fs /dev/vda1        # ext4
# xfs_growfs /                # XFS (mount point, not device)
meta-data=/dev/vda1              isize=512    agcount=4, agsize=1310720 blks
data     =                       bsize=4096   blocks=5242880, imaxpct=25
...
data blocks changed from 5242880 to 26214139
```

`cloud-init` automatiza los pasos 2 y 3 mediante los módulos `growpart` y `resizefs` — que es la razón por la que corren en la etapa de *red*, antes de que algo intente escribir en un disco lleno.

---

## 6. Imágenes, plantillas y el problema de la des-identificación

### 6.1 Formatos de imagen

| Formato | Plataforma | Sparse | Snapshots | Compresión | Notas |
|---|---|---|---|---|---|
| `raw` | cualquiera | vía agujeros del sistema de archivos | no | no | El más rápido; la línea base |
| `qcow2` | QEMU/KVM | sí | internos + externos | sí (zlib/zstd) | Los archivos de respaldo (backing files) habilitan plantillas copy-on-write |
| `vmdk` | VMware | sí | sí | sí | Muchos subformatos; `monolithicSparse` vs `streamOptimized` |
| `vhd` / `vhdx` | Hyper-V, Azure | sí | sí | sí | **Azure exige VHD de tamaño fijo con un tamaño alineado a 1 MiB** |
| `AMI` (respaldada por EBS) | AWS | sí | sí (snapshot de EBS) | n/a | Un snapshot + metadatos, no un archivo que descargues |
| Imagen OCI | contenedores | n/a | las capas son los snapshots | gzip/zstd | Direccionada por contenido, manifest + config + tarballs de capas |

```
$ qemu-img info base-deb12-2026.08.qcow2
image: base-deb12-2026.08.qcow2
file format: qcow2
virtual size: 20 GiB (21474836480 bytes)
disk size: 1.21 GiB
cluster_size: 65536
Format specific information:
    compat: 1.1
    compression type: zlib
    lazy refcounts: false
    refcount bits: 16
    corrupt: false
    extended l2: false

# Copy-on-write clone: 200 KiB on disk, not 1.2 GiB
$ qemu-img create -f qcow2 -F qcow2 -b base-deb12-2026.08.qcow2 web-01.qcow2 40G
Formatting 'web-01.qcow2', fmt=qcow2 cluster_size=65536 extended_l2=off
  compression_type=zlib size=42949672960 backing_file=base-deb12-2026.08.qcow2
  backing_fmt=qcow2 lazy_refcounts=off refcount_bits=16
```

### 6.2 Qué debe ser único — la tabla de des-identificación

Este es el corazón del objetivo. Todo lo de abajo es identidad de host que un clon ingenuo por `dd`/`qemu-img convert` va a duplicar.

| Artefacto | Ruta | Consecuencia de la duplicación | Reinicio correcto |
|---|---|---|---|
| **ID de máquina de systemd** | `/etc/machine-id` | Client-ID DHCP duplicado → **leases de IP duplicados**; namespaces de journal fusionados; inventario de activos duplicado | `rm /etc/machine-id && systemd-machine-id-setup` (o truncarlo a vacío) |
| **ID de máquina de D-Bus** | `/var/lib/dbus/machine-id` | Las apps indexadas por el UUID de D-Bus colisionan; ante un split-brain contra `/etc/machine-id`, algunos servicios no arrancan | Enlace simbólico a `/etc/machine-id`, o `rm` + `dbus-uuidgen --ensure` |
| **Claves de host SSH** | `/etc/ssh/ssh_host_{rsa,ecdsa,ed25519}_key[.pub]` | Cualquier clon puede suplantar a cualquier otro; `known_hosts` da una falsa sensación de autenticidad — **un MITM es indistinguible de un host legítimo** | `rm -f /etc/ssh/ssh_host_*` (regeneradas por `ssh-keygen -A` o por la unidad en el arranque) |
| Hostname | `/etc/hostname`, `/etc/hosts` | Atribución de logs, Kerberos, SANs de TLS | Definirlo por instancia (`set_hostname` de `cloud-init`) |
| Clave secreta de NetworkManager | `/var/lib/NetworkManager/secret_key` | IDs de interfaz IPv6 stable-privacy idénticos | `rm` (se regenera) |
| Leases DHCP y DUIDs | `/var/lib/dhclient/*`, `/var/lib/NetworkManager/*.lease`, DUID derivado de `/etc/machine-id` | Reclamos de lease obsoletos/duplicados | `rm` de los archivos de lease; ver §7.3 |
| Semilla aleatoria | `/var/lib/systemd/random-seed`, `/var/lib/urandom/random-seed` | Cada clon siembra su CRNG de forma idéntica en el primer arranque | `rm` |
| Nombre de iniciador iSCSI | `/etc/iscsi/initiatorname.iscsi` | Dos hosts reclaman el mismo IQN → **corrupción de LUN** | `echo "InitiatorName=$(iscsi-iname)" > /etc/iscsi/initiatorname.iscsi` |
| Reglas persistentes de NIC | `/etc/udev/rules.d/70-persistent-net.rules` | MAC grabada; la placa nueva pasa a ser `eth1`, red muerta | `rm` |
| UUIDs de sistema de archivos / LVM | `blkid`, `pvs -o+uuid` | Si adjuntás dos clones a un host puede montarse la raíz equivocada; hace falta `vgimportclone` | `tune2fs -U random` / `xfs_admin -U generate` / `vgimportclone` |
| Estado de `cloud-init` | `/var/lib/cloud/` | `cloud-init` cree que ya corrió; **user-data ignorado** | `cloud-init clean --logs --seed` |
| Identidad de suscripción / agentes | `/etc/rhsm/`, `/var/lib/rhsm/`, `/etc/salt/minion_id`, `/etc/puppetlabs/puppet/ssl/`, `/var/lib/zabbix/`, `/etc/telegraf/` | Los agentes de gestión de configuración y monitoreo se pelean por una sola identidad; gana el último en registrarse | Desregistro/limpieza por agente |
| Keytab de Kerberos | `/etc/krb5.keytab` | El clon puede descifrar los tickets de servicio del original | `rm` |
| Material SSH e historial de usuarios | `/root/.ssh/`, `/home/*/.ssh/`, `~/.bash_history` | Fuga de credenciales en la imagen publicada | `rm` |
| Logs | `/var/log/**` | Fuga de secretos del build y de identidad del host anterior | Truncar |

### 6.3 Automatizarlo: `virt-sysprep` (offline) y una unidad de primer arranque (online)

`virt-sysprep` opera sobre el archivo de imagen **con el invitado apagado**, usando `libguestfs` — sin necesidad de arrancarlo.

```
# virt-sysprep --list-operations | head -20
abrt-data * Remove the crash data generated by ABRT
backup-files * Remove editor backup files from the guest
bash-history * Remove the bash history in the guest
blkid-tab * Remove blkid tab in the guest
ca-certificates Remove CA certificates in the guest
crash-data * Remove the crash data generated by kexec-tools
cron-spool * Remove user at-jobs and cron-jobs
customize * Customize the guest
dhcp-client-state * Remove DHCP client leases
dhcp-server-state * Remove DHCP server leases
dovecot-data * Remove Dovecot (mail server) data
firewall-rules Remove the firewall rules
flag-reconfiguration Flag the system for reconfiguration
fs-uuids Change filesystem UUIDs
ipa-client * Remove the IPA files
kerberos-data Remove Kerberos data in the guest
kerberos-hostkeytab * Remove the Kerberos host keytab file in guest
logfiles * Remove many log files from the guest
machine-id * Remove the local machine ID
mail-spool * Remove email from the local mail spool directory

# virt-sysprep -a base-deb12-2026.08.qcow2 \
    --enable machine-id,ssh-hostkeys,ssh-userdir,logfiles,bash-history,\
dhcp-client-state,udev-persistent-net,random-seed,net-hostname,tmp-files \
    --firstboot-command 'systemctl enable --now qemu-guest-agent'
[   0.0] Examining the guest ...
[   4.3] Performing "machine-id" ...
[   4.3] Performing "ssh-hostkeys" ...
[   4.3] Performing "ssh-userdir" ...
[   4.4] Performing "logfiles" ...
[   4.6] Performing "bash-history" ...
[   4.6] Performing "dhcp-client-state" ...
[   4.6] Performing "udev-persistent-net" ...
[   4.6] Performing "random-seed" ...
[   4.6] Performing "net-hostname" ...
[   4.7] Performing "tmp-files" ...
[   4.9] Performing "firstboot-command" ...
[   5.1] SELinux relabelling
```

Las operaciones marcadas con `*` están habilitadas por defecto; `virt-sysprep -a img.qcow2` sin ninguna opción ya elimina `machine-id` y `ssh-hostkeys`. **Trabajá siempre sobre una copia** — `virt-sysprep` modifica la imagen in situ y no hay deshacer.

El complemento por si acaso: una unidad de primer arranque que regenera la identidad incluso si la imagen fue clonada por alguien que nunca oyó hablar de `virt-sysprep`.

```ini
# /etc/systemd/system/regenerate-host-identity.service
[Unit]
Description=Regenerate per-host identity after cloning
Documentation=man:machine-id(5) man:ssh-keygen(1)
DefaultDependencies=no
After=systemd-remount-fs.service
Before=network-pre.target sshd.service cloud-init-local.service
Wants=network-pre.target
ConditionPathExists=/var/lib/host-identity-stale
ConditionVirtualization=vm

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/regenerate-host-identity
ExecStartPost=/bin/rm -f /var/lib/host-identity-stale
StandardOutput=journal+console

[Install]
WantedBy=sysinit.target
```

```bash
#!/usr/bin/env bash
# /usr/local/sbin/regenerate-host-identity
# Mint fresh per-host identity. Idempotent: guarded by /var/lib/host-identity-stale.
set -euo pipefail
log() { printf '[identity] %s\n' "$*"; }

# 1. systemd machine ID -----------------------------------------------------
log "resetting /etc/machine-id"
rm -f /etc/machine-id
systemd-machine-id-setup            # writes a fresh 32-hex-digit ID

# 2. D-Bus machine ID -------------------------------------------------------
log "aligning D-Bus machine ID with /etc/machine-id"
rm -f /var/lib/dbus/machine-id
install -d -m 0755 /var/lib/dbus
ln -sf /etc/machine-id /var/lib/dbus/machine-id

# 3. SSH host keys ----------------------------------------------------------
log "regenerating SSH host keys"
rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub
ssh-keygen -A                       # one key per supported algorithm

# 4. Entropy seed -----------------------------------------------------------
rm -f /var/lib/systemd/random-seed /var/lib/urandom/random-seed

# 5. Network identity -------------------------------------------------------
rm -f /var/lib/NetworkManager/secret_key
rm -f /var/lib/NetworkManager/*.lease /var/lib/NetworkManager/*.state
rm -rf /var/lib/dhclient/* /var/lib/dhcp/*
rm -f /etc/udev/rules.d/70-persistent-net.rules

# 6. Storage identity -------------------------------------------------------
if [ -w /etc/iscsi/initiatorname.iscsi ] && command -v iscsi-iname >/dev/null; then
    echo "InitiatorName=$(iscsi-iname)" > /etc/iscsi/initiatorname.iscsi
fi

# 7. Provisioning state -----------------------------------------------------
command -v cloud-init >/dev/null && cloud-init clean --logs --seed || true

log "done; new machine-id=$(cat /etc/machine-id)"
```

---

## 7. `/etc/machine-id` en profundidad

### 7.1 Qué es

Una **cadena hexadecimal en minúsculas de 32 caracteres** (128 bits, terminada en salto de línea, sin guiones) que identifica al sistema operativo instalado durante toda la vida de esa instalación. *No* es un UUID en forma canónica con guiones, *no* es el UUID de sistema de SMBIOS, y *no* cambia entre reinicios (a diferencia del boot ID en `/proc/sys/kernel/random/boot_id`).

```
$ cat /etc/machine-id
5a5b0d3f1f9c4a1f8e2b7c6d4e3f2a10
$ wc -c /etc/machine-id
33 /etc/machine-id
$ cat /proc/sys/kernel/random/boot_id
0f3d4b2a-9c1e-4f8a-9b2c-3d4e5f6a7b8c        # changes every boot
```

`machine-id(5)` afirma llanamente que el valor **debe considerarse confidencial y no debe exponerse en redes no confiables** — es un identificador global estable y no autenticado. Cuando un servicio necesita un identificador por aplicación, la llamada correcta es `sd_id128_get_machine_app_specific()`, que aplica HMAC al machine ID con un UUID de aplicación para que el valor crudo nunca se filtre.

### 7.2 Semántica del primer arranque (systemd ≥ 247)

El estado de `/etc/machine-id` en la imagen decide si systemd trata el arranque como un *primer arranque*:

| Estado de `/etc/machine-id` en la imagen | Arranque clasificado como | Comportamiento |
|---|---|---|
| **El archivo no existe** | **Primer arranque** | systemd escribe `uninitialized\n`, sobremonta un archivo en tmpfs con el ID real, y lo compromete a disco después de `first-boot-complete.target`. Las unidades con `ConditionFirstBoot=yes` se ejecutan (`systemd-firstboot.service` puede pedir locale/contraseña de root) |
| **Contiene `uninitialized`** | **Primer arranque** | Igual que arriba |
| **Existe pero está vacío (0 bytes)** | **No** es un primer arranque | Igualmente se genera y compromete un ID nuevo, pero las unidades con `ConditionFirstBoot=` **no** se ejecutan |
| Contiene un ID válido | No es un primer arranque | No pasa nada — este es el bug del clon |

**La consecuencia práctica para construir imágenes:** elegí deliberadamente.

- **Archivo vacío** → cada clon obtiene un ID único, silenciosamente, sin configuración interactiva de primer arranque. Esto es lo que querés para imágenes de nube aprovisionadas por `cloud-init`.
- **Archivo ausente** → cada clon obtiene un ID único *y* se disparan las unidades de primer arranque. Usá esto cuando dependas de `systemd-firstboot` o de unidades con `ConditionFirstBoot=yes`.

**No** dejes un ID válido en una imagen publicada, y no confundas "vacío" con "ausente".

```
# Build an image for cloud provisioning (no interactive first boot):
# truncate -s 0 /etc/machine-id
# ls -l /etc/machine-id
-rw-r--r-- 1 root root 0 Aug 26 09:40 /etc/machine-id

# On a running machine, mint a new one immediately:
# rm -f /etc/machine-id
# systemd-machine-id-setup
Initializing machine ID from random generator.
# cat /etc/machine-id
b71c9e04ad2f4e1c8a3d6f5b2c9e0d47
```

`systemd-machine-id-setup` deriva el ID, en orden de preferencia, de: el machine ID de D-Bus, el ID provisto por KVM/el contenedor (`/sys/class/dmi/id/product_uuid` en KVM, o el valor del gestor de contenedores), o `/dev/urandom`. `--commit` escribe a disco un ID transitorio (sobremontado) una vez que `/etc` se vuelve escribible — el camino usado cuando el rootfs estaba en solo lectura durante el arranque.

### 7.3 Qué lee realmente `/etc/machine-id`

Por esto la duplicación no es cosmética:

| Consumidor | Uso | Síntoma de la duplicación |
|---|---|---|
| `systemd-journald` | Ruta del archivo de journal `/var/log/journal/<machine-id>/system.journal` | Los journals remotos de varios hosts se fusionan en un solo namespace |
| `systemd-networkd` | DUID-EN por defecto (PEN 43793) y, con `ClientIdentifier=duid`, el **client ID de DHCPv4** | **Leases de IP duplicados** |
| `systemd-resolved` | Resolución de conflictos LLMNR/mDNS | Conflictos de nombres en el enlace local |
| D-Bus | Identidad de máquina para el direccionamiento del bus | Confusión del bus de sesión, comportamiento errático de aplicaciones |
| kubelet de Kubernetes | `node.status.nodeInfo.machineID` | Correlación de nodos, algunos drivers CSI, node-problem-detector |
| Inventario de activos / Red Hat Insights / Landscape / Salt | Clave primaria de host | 40 servidores aparecen como 1 |
| Licenciamiento y telemetría | Identidad de la instalación | Licencias subcontadas o rechazadas |

```
$ kubectl get nodes -o custom-columns='NODE:.metadata.name,MACHINE-ID:.status.nodeInfo.machineID'
NODE       MACHINE-ID
worker-1   5a5b0d3f1f9c4a1f8e2b7c6d4e3f2a10
worker-2   5a5b0d3f1f9c4a1f8e2b7c6d4e3f2a10     # <-- cloned template, not de-identified
worker-3   5a5b0d3f1f9c4a1f8e2b7c6d4e3f2a10
```

**El arreglo de `systemd-networkd`**, cuando no podés re-crear la imagen de inmediato:

```ini
# /etc/systemd/network/10-dhcp.network
[Match]
Name=en*

[Network]
DHCP=ipv4

[DHCPv4]
# Use the MAC address instead of a machine-id-derived DUID.
ClientIdentifier=mac
```

```
# networkctl reload && networkctl reconfigure enp1s0
# journalctl -u systemd-networkd -b --no-pager | tail -4
Aug 26 09:52:11 web-01 systemd-networkd[612]: enp1s0: DHCPv4 address 10.20.4.131/24 via 10.20.4.1
```

### 7.4 ID de máquina de D-Bus

Históricamente D-Bus mantenía su propio UUID en `/var/lib/dbus/machine-id`, generado por `dbus-uuidgen`. En distribuciones con systemd ahora es un **enlace simbólico a `/etc/machine-id`**, y los dos deben coincidir.

```
$ ls -l /var/lib/dbus/machine-id
lrwxrwxrwx 1 root root 15 Jul  4  2025 /var/lib/dbus/machine-id -> /etc/machine-id
$ dbus-uuidgen --get
5a5b0d3f1f9c4a1f8e2b7c6d4e3f2a10
$ [ "$(dbus-uuidgen --get)" = "$(cat /etc/machine-id)" ] && echo consistent || echo SPLIT-BRAIN
consistent
```

Si divergen (algo que pasa realmente y con regularidad en imágenes construidas con una mezcla de épocas), arreglalo con:

```
# rm -f /var/lib/dbus/machine-id
# ln -s /etc/machine-id /var/lib/dbus/machine-id
# # or, if you deliberately want a standalone file:
# dbus-uuidgen --ensure=/var/lib/dbus/machine-id
```

---

## 8. Claves de host SSH: la mitad de seguridad de la des-identificación

### 8.1 Por qué la duplicación es un incidente de seguridad, no una molestia

La clave de host SSH es lo *único* que autentica al servidor frente al cliente. Si 40 hosts comparten una sola clave de host Ed25519, entonces:

1. Cualquier operador (o atacante) con root en **uno** de ellos puede leer `/etc/ssh/ssh_host_ed25519_key` y suplantar de forma transparente a **los cuarenta**, sin que `known_hosts` ni `StrictHostKeyChecking=yes` objeten absolutamente nada.
2. Rotar la clave de host en una máquina rompe la confianza para toda la flota.
3. Si la imagen alguna vez se publicó (una AMI pública, un qcow2 compartido, una imagen Docker), la clave privada es pública.

```
$ for k in /etc/ssh/ssh_host_*_key.pub; do ssh-keygen -lf "$k"; done
3072 SHA256:9k1Uh0V6M+7NfLK2s8Q0mYq3nRPxJ2dW8cZfB1tA5vE root@web-01 (RSA)
256 SHA256:Q3nT9pR1xK7mB2vC5dF8gH0jL4nP6sU9wY2aE5iO7uM root@web-01 (ECDSA)
256 SHA256:Xy8Kd2Lm9Np4Qr6St1Uv3Wx5Yz7Ab0Cd2Ef4Gh6Ij8 root@web-01 (ED25519)
```

Corré eso en toda la flota y contá las huellas distintas. Si la cuenta es 1, tenés un incidente.

### 8.2 Regeneración

```
# rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub
# ssh-keygen -A
ssh-keygen: generating new host keys: RSA ECDSA ED25519
# systemctl restart ssh    # sshd on RHEL
```

`ssh-keygen -A` genera **solo los tipos de clave faltantes**, con parámetros por defecto y frase de paso vacía — que es exactamente el comportamiento idempotente que necesita una unidad de arranque. Las distribuciones lo integran al arranque de maneras distintas:

| Distribución | Mecanismo |
|---|---|
| Debian/Ubuntu | `ExecStartPre` de `/lib/systemd/system/ssh.service`, más el postinst de `openssh-server`; las imágenes de nube dependen del módulo `ssh` de `cloud-init` |
| RHEL/Fedora/CentOS Stream | Unidades plantilla `sshd-keygen@.service` (`sshd-keygen@rsa.service`, `@ecdsa`, `@ed25519`) traídas por `sshd-keygen.target` |
| SUSE | `ExecStartPre=/usr/sbin/sshd-gen-keys-start` de `sshd.service` |
| Imágenes de nube (cualquiera) | Módulo `ssh` de `cloud-init` — ver §9 |

### 8.3 Hacer confiable a la clave nueva

La regeneración resuelve la suplantación pero crea un problema de arranque de confianza: ¿cómo aprende el cliente la huella nueva *correcta*? Tres respuestas de producción:

**(a) Impresión de la huella en consola** — el módulo `keys_to_console` de `cloud-init` escribe las huellas de las claves de host en la consola serie, que la API del IaaS expone:

```
# openstack console log show web-01 | grep -A6 'BEGIN SSH HOST KEY'
ci-info: ++++++++Authorized keys from /home/deploy/.ssh/authorized_keys++++++++
-----BEGIN SSH HOST KEY FINGERPRINTS-----
256 SHA256:Xy8Kd2Lm9Np4Qr6St1Uv3Wx5Yz7Ab0Cd2Ef4Gh6Ij8 root@web-01 (ED25519)
3072 SHA256:9k1Uh0V6M+7NfLK2s8Q0mYq3nRPxJ2dW8cZfB1tA5vE root@web-01 (RSA)
-----END SSH HOST KEY FINGERPRINTS-----
```

**(b) Registros SSHFP en DNS** firmados con DNSSEC:

```
$ ssh-keygen -r web-01.prod.example.net -f /etc/ssh/ssh_host_ed25519_key.pub
web-01.prod.example.net IN SSHFP 4 1 9f2c1a8b7d6e5f4a3b2c1d0e9f8a7b6c5d4e3f2a
web-01.prod.example.net IN SSHFP 4 2 3b2c1d0e9f8a7b6c5d4e3f2a1b0c9d8e7f6a5b4c3d2e1f0a9b8c7d6e5f4a3b2c
```
```
$ ssh -o VerifyHostKeyDNS=yes web-01.prod.example.net
```

**(c) Una autoridad certificante de SSH** — las claves de host de la flota son firmadas por una clave de CA en la que los clientes confían una sola vez. Esta es la respuesta correcta a escala: la rotación se vuelve un no-evento.

```
# On the CA host:
# ssh-keygen -s /etc/ssh/ca_host_key -I web-01 -h -n web-01.prod.example.net \
      -V +52w /etc/ssh/ssh_host_ed25519_key.pub
Signed host key /etc/ssh/ssh_host_ed25519_key-cert.pub: id "web-01" serial 0 for web-01.prod.example.net valid from 2026-08-26T00:00:00 to 2027-08-25T00:00:00
```
```
# /etc/ssh/sshd_config.d/60-hostcert.conf
HostCertificate /etc/ssh/ssh_host_ed25519_key-cert.pub
```
```
# ~/.ssh/known_hosts on every client — one line for the whole fleet
@cert-authority *.prod.example.net ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI...
```

| Enfoque | Cambio en el cliente | Costo de rotación | ¿Necesita DNSSEC/PKI? | Veredicto |
|---|---|---|---|---|
| `known_hosts` manual | Alto | O(hosts × clientes) | no | No escala |
| Huella por consola | Lectura manual | O(hosts) | no | Sirve para un puñado de VMs |
| SSHFP + DNSSEC | `VerifyHostKeyDNS=yes` | O(hosts), automatizable | DNSSEC | Bueno si ya corrés DNSSEC |
| **CA de host SSH** | Una línea `@cert-authority` | **O(1)** | Custodia de la clave de CA | **El mejor a escala de flota** |
| `UpdateHostKeys=yes` (OpenSSH ≥ 8.5, por defecto `yes` desde 8.5 cuando la clave ya es confiable) | ninguno | automático para claves *adicionales* | no | Complemento útil, no un bootstrap |

---

## 9. `cloud-init`: el agente estándar de la industria para aprovisionar invitados

### 9.1 Arquitectura

`cloud-init` corre temprano en el arranque, descubre una **fuente de datos (datasource)**, lee **meta-data** (identidad provista por la plataforma) y **user-data** (configuración provista por vos), y ejecuta una tubería de **módulos** repartida en cuatro servicios de systemd.

| Etapa | Unidad de systemd | Comando | Lista de módulos en `cloud.cfg` | Qué corre acá |
|---|---|---|---|---|
| Generador | `cloud-init-generator` | — | — | Decide si habilitar `cloud-init.target` en absoluto |
| **Local** | `cloud-init-local.service` | `cloud-init init --local` | — | Encontrar una fuente de datos *local* (ConfigDrive, NoCloud); escribir la configuración de red. Corre **antes** de que la red esté levantada |
| **Red** | `cloud-init-network.service` (era `cloud-init.service` antes de 24.3) | `cloud-init init` | `cloud_init_modules` | La red está levantada; obtener desde IMDS; `disk_setup`, `mounts`, `growpart`, `resizefs`, `set_hostname`, `update_etc_hosts`, `ssh` |
| **Config** | `cloud-config.service` | `cloud-init modules --mode=config` | `cloud_config_modules` | `ssh_import_id`, `locale`, `set_passwords`, configuración de `apt`/`yum`, `package_update_upgrade_install`, `timezone` |
| **Final** | `cloud-final.service` | `cloud-init modules --mode=final` | `cloud_final_modules` | `runcmd`, `scripts_user`, `ssh_authkey_fingerprints`, `keys_to_console`, `phone_home`, `final_message`, `power_state_change` |

El estado vive bajo `/var/lib/cloud`:

```
$ sudo tree -L 2 /var/lib/cloud
/var/lib/cloud
├── data
│   ├── instance-id
│   ├── previous-instance-id
│   ├── result.json
│   └── status.json
├── handlers
├── instance -> /var/lib/cloud/instances/i-0abcd1234ef567890
├── instances
│   └── i-0abcd1234ef567890
│       ├── boot-finished
│       ├── cloud-config.txt
│       ├── datasource
│       ├── obj.pkl
│       ├── sem                       # per-instance semaphores
│       ├── user-data.txt
│       ├── user-data.txt.i
│       └── vendor-data.txt
├── scripts
│   ├── per-boot
│   ├── per-instance
│   ├── per-once
│   └── vendor
├── seed
└── sem                               # per-once semaphores
```

**El `instance-id` es el disparador de re-ejecución.** `cloud-init` compara el `instance-id` de la fuente de datos contra `/var/lib/cloud/data/instance-id`. Si difieren, trata el arranque como una *instancia nueva*: los módulos `per-instance` vuelven a correr. Si coinciden, solo corren los módulos `per-boot`. Por eso clonar una VM que ya arrancó, sin `cloud-init clean`, hace que el user-data sea ignorado silenciosamente — los semáforos en `/var/lib/cloud/instances/<old-id>/sem/` dicen "ya está hecho".

| Frecuencia del módulo | Corre cuando | Ubicación del semáforo |
|---|---|---|
| `once-per-instance` (por defecto) | Cambió el `instance-id` | `/var/lib/cloud/instances/<id>/sem/` |
| `always` (por arranque) | En cada arranque | no se registra |
| `once` (una única vez) | Alguna vez, en esta máquina | `/var/lib/cloud/sem/` |

### 9.2 `/etc/cloud/cloud.cfg` — la configuración completa, anotada

```yaml
# /etc/cloud/cloud.cfg — Debian 12 cloud image, annotated.
# Drop-in overrides go in /etc/cloud/cloud.cfg.d/*.cfg (merged in lexical order).

# --- Identity and users --------------------------------------------------
users:
  - default

# Create the default user from the distro definition below; do not lock root's
# password to "!" only — disable_root is what actually blocks root SSH login.
disable_root: true
disable_root_opts: "no-port-forwarding,no-agent-forwarding,no-X11-forwarding,command=\"echo 'Please login as the user \\\"debian\\\" rather than the user \\\"root\\\".';echo;sleep 10;exit 142\""

# --- Filesystem ----------------------------------------------------------
# Grow the root partition and filesystem to fill the (possibly resized) disk.
growpart:
  mode: auto
  devices: ['/']
  ignore_growroot_disabled: false

resize_rootfs: true

mount_default_fields: [~, ~, 'auto', 'defaults,nofail,x-systemd.after=cloud-init-network.service', '0', '2']

# --- SSH -----------------------------------------------------------------
# THE de-identification switch: delete the image's host keys and regenerate.
ssh_deletekeys: true
ssh_genkeytypes: ['rsa', 'ecdsa', 'ed25519']
ssh_pwauth: false
ssh_svcname: ssh

# --- Hostname ------------------------------------------------------------
preserve_hostname: false
prefer_fqdn_over_hostname: false

# --- Network -------------------------------------------------------------
network:
  config: disabled          # set by the image builder when the platform manages
                            # networking itself; remove this to let cloud-init
                            # render /etc/netplan/50-cloud-init.yaml

# --- Datasource discovery ------------------------------------------------
# Order matters: the first datasource that self-identifies wins. Pinning this
# list on a known platform cuts 10-30 s off boot, because cloud-init stops
# probing endpoints that will never answer.
datasource_list: [ NoCloud, ConfigDrive, OpenStack, Ec2, Azure, GCE, Hetzner,
                   Oracle, Exoscale, CloudStack, OVF, LXD, None ]

datasource:
  Ec2:
    timeout: 10             # seconds per HTTP attempt against 169.254.169.254
    max_wait: 60            # give up on the IMDS after this many seconds
    metadata_urls: [ 'http://169.254.169.254' ]
  NoCloud:
    seedfrom: null
  OpenStack:
    max_wait: 60
    timeout: 10

# --- Module pipeline -----------------------------------------------------
# Stage 2: network is up. Anything that must exist before packages/services.
cloud_init_modules:
  - seed_random
  - bootcmd
  - write_files
  - growpart
  - resizefs
  - disk_setup
  - mounts
  - set_hostname
  - update_hostname
  - update_etc_hosts
  - ca_certs
  - rsyslog
  - users_groups
  - ssh

# Stage 3: configuration proper.
cloud_config_modules:
  - wireguard
  - snap
  - ssh_import_id
  - keyboard
  - locale
  - set_passwords
  - grub_dpkg
  - apt_pipelining
  - apt_configure
  - ubuntu_pro
  - ntp
  - timezone
  - disable_ec2_metadata
  - runcmd
  - byobu

# Stage 4: last, and user-visible.
cloud_final_modules:
  - package_update_upgrade_install
  - fan
  - landscape
  - lxd
  - ubuntu_drivers
  - write_files_deferred
  - puppet
  - chef
  - ansible
  - mcollective
  - salt_minion
  - reset_rmc
  - refresh_rmc_and_interface
  - rightscale_userdata
  - scripts_vendor
  - scripts_per_once
  - scripts_per_boot
  - scripts_per_instance
  - scripts_user
  - ssh_authkey_fingerprints
  - keys_to_console
  - install_hotplug
  - phone_home
  - final_message
  - power_state_change

# --- Distro definition ---------------------------------------------------
system_info:
  distro: debian
  default_user:
    name: debian
    lock_passwd: true
    gecos: Debian
    groups: [adm, audio, cdrom, dialout, dip, floppy, netdev, plugdev, sudo, video]
    sudo: ["ALL=(ALL) NOPASSWD:ALL"]
    shell: /bin/bash
  network:
    renderers: ['netplan', 'eni', 'sysconfig', 'networkd']
    activators: ['netplan', 'eni', 'network-manager', 'networkd']
  ntp_client: chrony
  paths:
    cloud_dir: /var/lib/cloud/
    templates_dir: /etc/cloud/templates/
  package_mirrors:
    - arches: [default]
      failsafe:
        primary: http://deb.debian.org/debian
        security: http://security.debian.org/debian-security
  ssh_svcname: ssh
```

### 9.3 Un `user-data` de producción completo

```yaml
#cloud-config
# ---------------------------------------------------------------------------
# Production user-data for a Kubernetes worker node on OpenStack / NoCloud.
# Validate BEFORE booting:  cloud-init schema --config-file user-data --annotate
# ---------------------------------------------------------------------------

hostname: k8s-worker-04
fqdn: k8s-worker-04.prod.example.net
prefer_fqdn_over_hostname: true
manage_etc_hosts: true

timezone: UTC
locale: en_US.UTF-8

# --- Identity: SSH keys only, never passwords ------------------------------
users:
  - name: sre
    gecos: Platform SRE
    primary_group: sre
    groups: [adm, sudo, systemd-journal]
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
      - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH8kL2mN9pQ4rS6tU1vW3xY5zA7bC0dE2fG4hI6jK8lM sre@bastion
      - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB1cD3eF5gH7iJ9kL0mN2oP4qR6sT8uV0wX2yZ4aB6cD ci@runner

# --- De-identification -----------------------------------------------------
ssh_deletekeys: true
ssh_genkeytypes: [ed25519, rsa]
ssh_pwauth: false
disable_root: true

# --- Storage ---------------------------------------------------------------
disk_setup:
  /dev/vdb:
    table_type: gpt
    layout: true
    overwrite: false

fs_setup:
  - label: containerd
    filesystem: xfs
    device: /dev/vdb
    partition: 1
    overwrite: false
    extra_opts: ['-n', 'ftype=1']

mounts:
  - [ LABEL=containerd, /var/lib/containerd, xfs,
      "defaults,noatime,nodiratime,pquota,nofail,x-systemd.device-timeout=30", "0", "2" ]

growpart:
  mode: auto
  devices: ['/']

resize_rootfs: true

# --- Packages --------------------------------------------------------------
package_update: true
package_upgrade: false          # deliberate: upgrades belong to the image build,
                                # not to instance boot; boot must be deterministic
packages:
  - qemu-guest-agent
  - chrony
  - nftables
  - jq
  - curl
  - conntrack
  - socat
  - ipvsadm

# --- Time ------------------------------------------------------------------
ntp:
  enabled: true
  ntp_client: chrony
  servers:
    - ntp1.prod.example.net
    - ntp2.prod.example.net

# --- Files -----------------------------------------------------------------
write_files:
  - path: /etc/modules-load.d/k8s.conf
    owner: root:root
    permissions: '0644'
    content: |
      overlay
      br_netfilter

  - path: /etc/sysctl.d/99-kubernetes.conf
    owner: root:root
    permissions: '0644'
    content: |
      net.bridge.bridge-nf-call-iptables  = 1
      net.bridge.bridge-nf-call-ip6tables = 1
      net.ipv4.ip_forward                 = 1
      net.ipv4.conf.all.rp_filter         = 0
      fs.inotify.max_user_instances       = 8192
      fs.inotify.max_user_watches         = 524288
      vm.max_map_count                    = 262144
      vm.overcommit_memory                = 1
      kernel.panic                        = 10
      kernel.panic_on_oops                = 1

  - path: /etc/systemd/network/10-dhcp.network
    owner: root:root
    permissions: '0644'
    content: |
      [Match]
      Name=en*

      [Network]
      DHCP=ipv4
      IPv6AcceptRA=no

      [DHCPv4]
      # Never derive the DHCP client-ID from /etc/machine-id: a cloned image
      # would then claim a lease already held by its sibling.
      ClientIdentifier=mac
      UseDomains=true

  - path: /etc/chrony/conf.d/ptp-kvm.conf
    owner: root:root
    permissions: '0644'
    content: |
      # Host-provided PTP clock; ~100 ns accuracy without touching the network.
      refclock PHC /dev/ptp0 poll 2 dpoll -2 offset 0 stratum 2 prefer

  - path: /etc/sysconfig/kubelet
    owner: root:root
    permissions: '0644'
    defer: true               # written in the FINAL stage, after packages exist
    content: |
      KUBELET_EXTRA_ARGS=--node-labels=topology.kubernetes.io/zone=az-a

# --- Early commands (run in the network stage, before packages) ------------
bootcmd:
  - [ cloud-init-per, once, disable-swap, sh, -c,
      'swapoff -a && sed -i "/\\sswap\\s/s/^/#/" /etc/fstab' ]

# --- Late commands (run last, in the final stage) --------------------------
runcmd:
  - [ systemctl, enable, --now, qemu-guest-agent ]
  - [ systemctl, enable, --now, chrony ]
  - [ modprobe, ptp_kvm ]
  - [ sysctl, --system ]
  - [ sh, -c, 'systemd-detect-virt > /etc/platform-type' ]
  - [ sh, -c, 'echo "provisioned $(date -Is) on $(systemd-detect-virt)" >> /var/log/provision.log' ]

# --- Console output: makes host keys verifiable from the IaaS console log ---
ssh_authkey_fingerprints: true
keys_to_console: true
ssh_fp_console_blacklist: []
ssh_key_console_blacklist: [ssh-dss]

# --- Completion signals ----------------------------------------------------
phone_home:
  url: https://provisioning.prod.example.net/api/v1/phone-home/$INSTANCE_ID
  post:
    - instance_id
    - hostname
    - fqdn
    - pub_key_ed25519
  tries: 5

final_message: |
  cloud-init v. $version finished at $timestamp.
  Datasource: $datasource. Up $uptime seconds.
  machine-id: this node is ready for kubeadm join.

power_state:
  mode: reboot
  message: Rebooting after first-boot provisioning
  timeout: 60
  condition: test -f /etc/sysctl.d/99-kubernetes.conf
```

### 9.4 `meta-data` y `network-config` para una semilla NoCloud

```yaml
# meta-data — identity supplied by the "platform". For NoCloud you supply it.
# instance-id is the re-run trigger: change it and per-instance modules re-run.
instance-id: iid-k8s-worker-04-20260826
local-hostname: k8s-worker-04
```

```yaml
# network-config — cloud-init network config v2. NOTE: as a standalone
# NoCloud file it starts at "version:", with NO top-level "network:" key.
# Inside /etc/cloud/cloud.cfg.d/*.cfg it MUST be nested under "network:".
version: 2
ethernets:
  id0:
    match:
      macaddress: '52:54:00:6f:2a:11'
    set-name: eth0
    addresses:
      - 10.20.4.131/24
      - 'fd00:20:4::131/64'
    routes:
      - to: default
        via: 10.20.4.1
        metric: 100
      - to: '10.99.0.0/16'
        via: 10.20.4.254
        metric: 200
    nameservers:
      addresses: [10.20.1.10, 10.20.1.11]
      search: [prod.example.net, example.net]
    mtu: 9000
bonds: {}
vlans:
  storage:
    id: 42
    link: eth0
    addresses: [172.16.42.31/24]
    mtu: 9000
```

Esa diferencia de anidamiento es uno de los errores de `cloud-init` más comunes en el campo: el mismo YAML es válido en un lugar y silenciosamente ignorado en el otro.

El resultado renderizado en una distro con netplan:

```
$ cat /etc/netplan/50-cloud-init.yaml
# This file is generated from information provided by the datasource. Changes
# to it will not persist across an instance reboot.
network:
    version: 2
    ethernets:
        id0:
            addresses:
            - 10.20.4.131/24
            - fd00:20:4::131/64
            match:
                macaddress: 52:54:00:6f:2a:11
            mtu: 9000
            nameservers:
                addresses:
                - 10.20.1.10
                - 10.20.1.11
                search:
                - prod.example.net
                - example.net
            routes:
            -   metric: 100
                to: default
                via: 10.20.4.1
            set-name: eth0
```

### 9.5 Construir la semilla y arrancar la VM

```
$ ls -l
-rw-r--r-- 1 sre sre  4218 Aug 26 10:02 user-data
-rw-r--r-- 1 sre sre    92 Aug 26 10:02 meta-data
-rw-r--r-- 1 sre sre   712 Aug 26 10:02 network-config

# Validate before you waste a boot:
$ cloud-init schema --config-file user-data --annotate
Valid schema user-data

# Option A: cloud-localds (package: cloud-image-utils)
$ cloud-localds --network-config=network-config seed.iso user-data meta-data

# Option B: plain ISO tooling. The volume label MUST be cidata (or CIDATA).
$ genisoimage -output seed.iso -volid cidata -joliet -rock \
      user-data meta-data network-config
I: -input-charset not specified, using utf-8 (detected in locale settings)
Total translation table size: 0
Total rockridge attributes bytes: 1543
Total directory bytes: 0
Path table size(bytes): 10
Max brk space used 0
183 extents written (0 MB)

$ isoinfo -d -i seed.iso | grep -i 'volume id'
Volume id: cidata
```

```
# Provision the VM: COW disk from the golden image + the seed as a CDROM
$ qemu-img create -f qcow2 -F qcow2 -b /var/lib/libvirt/images/base-deb12-2026.08.qcow2 \
      /var/lib/libvirt/images/k8s-worker-04.qcow2 60G

$ virt-install \
    --name k8s-worker-04 \
    --memory 8192 --vcpus 4 --cpu host-passthrough \
    --disk path=/var/lib/libvirt/images/k8s-worker-04.qcow2,bus=virtio,cache=none,discard=unmap \
    --disk path=/var/lib/libvirt/images/k8s-worker-04-data.qcow2,size=200,bus=virtio,cache=none,discard=unmap \
    --disk path=seed.iso,device=cdrom,readonly=on \
    --network bridge=br-prod,model=virtio,mac=52:54:00:6f:2a:11 \
    --os-variant debian12 \
    --graphics none --console pty,target_type=serial \
    --import --noautoconsole

Starting install...
Domain creation completed.
```

### 9.6 El XML de dominio de libvirt completo

Todo lo que necesita un invitado KVM bien configurado, sin cortes:

```xml
<domain type='kvm'>
  <name>k8s-worker-04</name>
  <uuid>c0ffee00-dead-4bee-9001-0123456789ab</uuid>
  <title>Kubernetes worker, prod, az-a</title>
  <memory unit='KiB'>8388608</memory>
  <currentMemory unit='KiB'>8388608</currentMemory>
  <vcpu placement='static'>4</vcpu>

  <os firmware='efi'>
    <type arch='x86_64' machine='pc-q35-8.2'>hvm</type>
    <firmware>
      <feature enabled='yes' name='enrolled-keys'/>
      <feature enabled='yes' name='secure-boot'/>
    </firmware>
    <boot dev='hd'/>
    <!-- SMBIOS identity: makes the guest self-describing to inventory tools -->
    <smbios mode='sysinfo'/>
  </os>

  <sysinfo type='smbios'>
    <system>
      <entry name='manufacturer'>Example Platform Engineering</entry>
      <entry name='product'>k8s-worker</entry>
      <entry name='version'>base-deb12-2026.08</entry>
      <entry name='serial'>ds=nocloud-net;s=http://10.20.1.5/seed/k8s-worker-04/</entry>
      <entry name='uuid'>c0ffee00-dead-4bee-9001-0123456789ab</entry>
    </system>
  </sysinfo>

  <features>
    <acpi/>
    <apic/>
    <vmport state='off'/>
    <smm state='on'/>
  </features>

  <!-- host-passthrough: best performance; forfeits migration to dissimilar CPUs -->
  <cpu mode='host-passthrough' check='none' migratable='on'>
    <topology sockets='1' dies='1' cores='4' threads='1'/>
    <feature policy='require' name='invtsc'/>
  </cpu>

  <clock offset='utc'>
    <timer name='rtc' tickpolicy='catchup'/>
    <timer name='pit' tickpolicy='delay'/>
    <timer name='hpet' present='no'/>
    <!-- kvmclock is what makes the guest's clocksource kvm-clock -->
    <timer name='kvmclock' present='yes'/>
  </clock>

  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>destroy</on_crash>

  <pm>
    <suspend-to-mem enabled='no'/>
    <suspend-to-disk enabled='no'/>
  </pm>

  <devices>
    <emulator>/usr/bin/qemu-system-x86_64</emulator>

    <!-- Root disk: virtio-blk, host page cache bypassed, TRIM passed through -->
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2' cache='none' io='native'
              discard='unmap' detect_zeroes='unmap' queues='4'/>
      <source file='/var/lib/libvirt/images/k8s-worker-04.qcow2'/>
      <target dev='vda' bus='virtio'/>
      <address type='pci' domain='0x0000' bus='0x04' slot='0x00' function='0x0'/>
    </disk>

    <!-- Data disk for containerd -->
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2' cache='none' io='native' discard='unmap'/>
      <source file='/var/lib/libvirt/images/k8s-worker-04-data.qcow2'/>
      <target dev='vdb' bus='virtio'/>
      <address type='pci' domain='0x0000' bus='0x05' slot='0x00' function='0x0'/>
    </disk>

    <!-- cloud-init NoCloud seed, label cidata -->
    <disk type='file' device='cdrom'>
      <driver name='qemu' type='raw'/>
      <source file='/var/lib/libvirt/images/k8s-worker-04-seed.iso'/>
      <target dev='sda' bus='sata'/>
      <readonly/>
      <address type='drive' controller='0' bus='0' target='0' unit='0'/>
    </disk>

    <controller type='pci' index='0' model='pcie-root'/>
    <controller type='sata' index='0'/>
    <controller type='virtio-serial' index='0'/>

    <!-- virtio-net with vhost offload and multiqueue matching the vCPU count -->
    <interface type='bridge'>
      <mac address='52:54:00:6f:2a:11'/>
      <source bridge='br-prod'/>
      <model type='virtio'/>
      <driver name='vhost' queues='4' rx_queue_size='1024' tx_queue_size='1024'/>
      <mtu size='9000'/>
      <address type='pci' domain='0x0000' bus='0x01' slot='0x00' function='0x0'/>
    </interface>

    <!-- Serial console: the only way in when the network config is wrong -->
    <serial type='pty'>
      <target type='isa-serial' port='0'>
        <model name='isa-serial'/>
      </target>
    </serial>
    <console type='pty'>
      <target type='serial' port='0'/>
    </console>

    <!-- QEMU guest agent channel: graceful shutdown, IP reporting, fsfreeze -->
    <channel type='unix'>
      <target type='virtio' name='org.qemu.guest_agent.0'/>
      <address type='virtio-serial' controller='0' bus='0' port='1'/>
    </channel>

    <!-- Entropy from the host: without this, first-boot key generation stalls -->
    <rng model='virtio'>
      <backend model='random'>/dev/urandom</backend>
      <address type='pci' domain='0x0000' bus='0x02' slot='0x00' function='0x0'/>
    </rng>

    <!-- Ballooning: disabled on Kubernetes nodes; the kubelet must trust MemTotal -->
    <memballoon model='none'/>

    <!-- Watchdog: reset the guest if the kernel wedges -->
    <watchdog model='i6300esb' action='reset'>
      <address type='pci' domain='0x0000' bus='0x03' slot='0x00' function='0x0'/>
    </watchdog>

    <graphics type='vnc' port='-1' autoport='yes' listen='127.0.0.1'/>
    <video>
      <model type='virtio' heads='1' primary='yes'/>
    </video>
  </devices>
</domain>
```

Notá `<entry name='serial'>ds=nocloud-net;s=http://...</entry>` — la fuente de datos NoCloud de `cloud-init` lee el número de serie de sistema de SMBIOS, así que podés apuntar un invitado a una semilla HTTP **sin adjuntar ningún ISO en absoluto**. La misma cadena funciona como parámetro de línea de comandos del kernel: `ds=nocloud-net;s=http://10.20.1.5/seed/k8s-worker-04/`.

### 9.7 Packer: construir la golden image de forma reproducible

```hcl
# base-deb12.pkr.hcl — build a de-identified golden image.
packer {
  required_plugins {
    qemu = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/qemu"
    }
  }
}

variable "version" {
  type        = string
  description = "Image version tag, e.g. 2026.08"
}

source "qemu" "debian12" {
  iso_url          = "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"
  iso_checksum     = "file:https://cloud.debian.org/images/cloud/bookworm/latest/SHA512SUMS"
  disk_image       = true
  disk_size        = "20G"
  format           = "qcow2"
  accelerator      = "kvm"
  cpus             = 4
  memory           = 4096
  machine_type     = "q35"
  net_device       = "virtio-net"
  disk_interface   = "virtio"
  headless         = true
  cd_files         = ["./http/user-data", "./http/meta-data"]
  cd_label         = "cidata"
  ssh_username     = "packer"
  ssh_private_key_file = "./keys/packer_ed25519"
  ssh_timeout      = "20m"
  shutdown_command = "sudo systemctl poweroff"
  output_directory = "output/base-deb12-${var.version}"
  vm_name          = "base-deb12-${var.version}.qcow2"
}

build {
  sources = ["source.qemu.debian12"]

  provisioner "shell" {
    inline = [
      "sudo apt-get update",
      "sudo DEBIAN_FRONTEND=noninteractive apt-get -y install qemu-guest-agent chrony nftables jq",
      "sudo systemctl enable qemu-guest-agent chrony",
    ]
  }

  # De-identification MUST be the last provisioner, after every package that
  # might have generated host-unique state.
  provisioner "shell" {
    inline = [
      "set -eux",
      "sudo cloud-init clean --logs --seed",
      "sudo rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub",
      "sudo truncate -s 0 /etc/machine-id",
      "sudo rm -f /var/lib/dbus/machine-id",
      "sudo ln -sf /etc/machine-id /var/lib/dbus/machine-id",
      "sudo rm -f /var/lib/systemd/random-seed /var/lib/NetworkManager/secret_key",
      "sudo rm -rf /var/lib/dhcp/* /var/lib/dhclient/*",
      "sudo rm -f /etc/udev/rules.d/70-persistent-net.rules",
      "sudo find /var/log -type f -exec truncate -s 0 {} +",
      "sudo rm -f /root/.bash_history /home/packer/.bash_history",
      "sudo rm -rf /home/packer/.ssh",
      "sudo fstrim -av || true",
    ]
  }

  post-processor "checksum" {
    checksum_types = ["sha256"]
    output         = "output/base-deb12-${var.version}.{{.ChecksumType}}"
  }
}
```

### 9.8 Sistemas de aprovisionamiento comparados

| | `cloud-init` | Ignition | Kickstart / preseed / AutoYaST | `virt-sysprep --firstboot` | Sysprep de Windows |
|---|---|---|---|---|---|
| Lenguaje | YAML (+ shell, MIME multipart, Jinja) | JSON (autorado como Butane YAML) | Archivo de directivas específico de la distro | Shell | XML unattend |
| Cuándo corre | En cada arranque, por etapas | **Una vez, en el initramfs, antes de montar la raíz real** | Durante la instalación del SO | Primer arranque | Primer arranque |
| ¿Se re-ejecuta en arranques posteriores? | Sí (módulos `per-boot`) | **Nunca** | No | No | No |
| ¿Puede instalar paquetes? | Sí | No (por diseño — solo declarativo) | Sí | Sí | n/a |
| Idempotente | Semáforos por instancia | Trivialmente (corre una vez) | n/a | Protegido manualmente | n/a |
| Distros | Casi todo Linux, FreeBSD, NetBSD | Fedora CoreOS, RHCOS, Flatcar | RHEL / Debian / SUSE | Cualquiera (libguestfs) | Windows |
| Visibilidad de fallas | `cloud-init status --long` | Shell de emergencia en el initramfs | Log del instalador | Journal | Log de setup |
| Mejor para | IaaS general, flotas mixtas | SO inmutable, optimizado para contenedores | Instalaciones bare-metal | Retrofit de una imagen que no podés reconstruir | Invitados Windows |

La diferencia de diseño que vale la pena internalizar: **Ignition corre exactamente una vez, antes de que el SO esté levantado, y no puede instalar paquetes.** Eso hace que el nodo resultante sea predecible bit a bit y hace imposible la "deriva de configuración en el arranque" — al costo de forzar todo lo variable hacia la construcción de la imagen o hacia los contenedores. `cloud-init` es el opuesto pragmático: enormemente flexible, y correspondientemente fácil de volver no determinista.

---

## 10. Contenedores como invitados: qué cambia

### 10.1 Detección y fronteras

```
$ systemd-detect-virt --container
docker
$ cat /proc/1/cgroup
0::/
$ ls /run/.containerenv 2>/dev/null && echo "podman"
$ ls /.dockerenv 2>/dev/null && echo "docker"
/.dockerenv
docker

$ lsns
        NS TYPE   NPROCS PID USER COMMAND
4026531834 time        1   1 root /bin/bash
4026532200 mnt         1   1 root /bin/bash
4026532201 uts         1   1 root /bin/bash
4026532202 ipc         1   1 root /bin/bash
4026532203 pid         1   1 root /bin/bash
4026532205 net         1   1 root /bin/bash
4026532270 cgroup      1   1 root /bin/bash

$ capsh --print | head -2
Current: cap_chown,cap_dac_override,cap_fowner,cap_fsetid,cap_kill,cap_setgid,cap_setuid,cap_setpcap,cap_net_bind_service,cap_net_raw,cap_sys_chroot,cap_mknod,cap_audit_write,cap_setfcap=ep
Bounding set =cap_chown,cap_dac_override,...
```

Notá qué es *compartido* con el host y por lo tanto miente sobre estar contenerizado:

```
$ uname -r
6.1.0-18-amd64            # the HOST kernel — there is no container kernel
$ nproc
64                        # all host CPUs, ignoring the cgroup quota
$ free -m | head -2
               total        used        free      shared  buff/cache   available
Mem:          257842       81204      112331        2841       64307     172408
                          # host memory, NOT the container limit

# The truth is in cgroup v2:
$ cat /sys/fs/cgroup/memory.max /sys/fs/cgroup/cpu.max
2147483648
200000 100000            # 2 CPUs worth of quota
```

Este es el bug de rendimiento de contenedores más común de todos: los runtimes que dimensionan pools de hilos a partir de `nproc` y heaps a partir de `MemTotal` van a sobreaprovisionar por un orden de magnitud y después ser matados por OOM. Las JVMs modernas (`UseContainerSupport`, activo por defecto), .NET y Go 1.19+ (`GOMEMLIMIT`) leen el cgroup en su lugar — el software viejo no.

### 10.2 `machine-id` dentro de contenedores

Como el `/etc/machine-id` del contenedor viene de la **imagen**, todos los contenedores de esa imagen lo comparten. Los runtimes de contenedores lo disimulan de maneras distintas:

| Runtime | Comportamiento de `/etc/machine-id` |
|---|---|
| Docker | Heredado textualmente de la imagen. Si la imagen incluye un ID válido, todos los contenedores lo tienen |
| Podman | Genera uno único por contenedor cuando la imagen no tiene ninguno |
| `systemd-nspawn` / `machinectl` | Genera un ID nuevo por máquina; se puede fijar con `--uuid` |
| LXC/LXD | Los hooks de plantilla lo limpian al clonar |
| Kubernetes | Nada; lo que tenga la imagen. Algunos charts montan por bind el `/etc/machine-id` **del host** para journald |

La regla correcta al construir imágenes es la misma que para las VMs: **enviar un `/etc/machine-id` vacío o ausente.** Concretamente, en un Containerfile:

```dockerfile
FROM debian:12-slim
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && truncate -s 0 /etc/machine-id \
 && rm -f /var/lib/dbus/machine-id \
 && ln -sf /etc/machine-id /var/lib/dbus/machine-id
```

Un DaemonSet que audita la unicidad del machine-id *del host* en todo un clúster — la versión con forma de Kubernetes del incidente de la §1:

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: machine-id-audit
  namespace: platform-audit
  labels:
    app.kubernetes.io/name: machine-id-audit
    app.kubernetes.io/component: compliance
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: machine-id-audit
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 100%
  template:
    metadata:
      labels:
        app.kubernetes.io/name: machine-id-audit
    spec:
      hostPID: false
      hostNetwork: false
      priorityClassName: system-node-critical
      tolerations:
        - operator: Exists
      securityContext:
        runAsNonRoot: true
        runAsUser: 65534
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: audit
          image: registry.example.net/platform/busybox:1.36
          command:
            - /bin/sh
            - -c
            - |
              set -eu
              MID="$(cat /host/etc/machine-id)"
              PID="$(cat /host/sys/class/dmi/id/product_uuid 2>/dev/null || echo unavailable)"
              echo "node=${NODE_NAME} machine_id=${MID} product_uuid=${PID}"
              # Expose as a Prometheus metric on a plain TCP socket
              while true; do
                printf '# HELP node_machine_id Host machine identity as a label.\n'
                printf '# TYPE node_machine_id gauge\n'
                printf 'node_machine_id{node="%s",machine_id="%s"} 1\n' "${NODE_NAME}" "${MID}"
                sleep 300
              done
          env:
            - name: NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
          resources:
            requests:
              cpu: 5m
              memory: 16Mi
            limits:
              memory: 32Mi
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: host-machine-id
              mountPath: /host/etc/machine-id
              readOnly: true
            - name: host-dmi
              mountPath: /host/sys/class/dmi/id
              readOnly: true
      volumes:
        - name: host-machine-id
          hostPath:
            path: /etc/machine-id
            type: File
        - name: host-dmi
          hostPath:
            path: /sys/class/dmi/id
            type: Directory
```

```
$ kubectl -n platform-audit logs -l app.kubernetes.io/name=machine-id-audit --tail=1 \
    | awk '{print $2}' | sort | uniq -c | sort -rn
      3 machine_id=5a5b0d3f1f9c4a1f8e2b7c6d4e3f2a10
      1 machine_id=b71c9e04ad2f4e1c8a3d6f5b2c9e0d47
```

Cualquier cuenta mayor a 1 es una falla de des-identificación en la imagen del nodo.

---

## 11. Verificación: la compuerta previa a la publicación

Toda construcción de imagen debería fallar cerrada ante este chequeo. Es gratis, es rápido, y es la diferencia entre que la §1 ocurra o no.

```bash
#!/usr/bin/env bash
# /usr/local/sbin/verify-image-identity
# Verify a mounted image root (default /) carries NO host-unique identity.
# Exit 0 = clean and publishable; exit 1 = identity leak.
set -uo pipefail
ROOT="${1:-/}"
fail=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; fail=1; }

echo "Auditing image root: ${ROOT}"

# --- 1. systemd machine ID -------------------------------------------------
mid="${ROOT%/}/etc/machine-id"
if [ ! -e "$mid" ]; then
    ok "machine-id absent (first-boot semantics will apply)"
elif [ ! -s "$mid" ]; then
    ok "machine-id present and empty (fresh ID generated at boot)"
elif [ "$(tr -d '\n' < "$mid")" = "uninitialized" ]; then
    ok "machine-id is 'uninitialized' (first-boot semantics will apply)"
else
    bad "machine-id contains a committed value: $(cat "$mid")"
fi

# --- 2. D-Bus machine ID ---------------------------------------------------
dbid="${ROOT%/}/var/lib/dbus/machine-id"
if [ -L "$dbid" ] || [ ! -e "$dbid" ] || [ ! -s "$dbid" ]; then
    ok "D-Bus machine-id is a symlink, absent or empty"
else
    bad "D-Bus machine-id is a standalone file with content: $(cat "$dbid")"
fi

# --- 3. SSH host keys ------------------------------------------------------
if compgen -G "${ROOT%/}/etc/ssh/ssh_host_*_key" > /dev/null; then
    bad "SSH host private keys present in the image:"
    ls -1 "${ROOT%/}"/etc/ssh/ssh_host_*_key | sed 's/^/          /'
else
    ok "no SSH host private keys in the image"
fi

# --- 4. cloud-init state ---------------------------------------------------
if [ -d "${ROOT%/}/var/lib/cloud/instances" ] && \
   [ -n "$(ls -A "${ROOT%/}/var/lib/cloud/instances" 2>/dev/null)" ]; then
    bad "stale cloud-init instance state (user-data will be ignored on clones)"
else
    ok "cloud-init state clean"
fi

# --- 5. Entropy and network seeds -----------------------------------------
for f in /var/lib/systemd/random-seed \
         /var/lib/urandom/random-seed \
         /var/lib/NetworkManager/secret_key \
         /etc/udev/rules.d/70-persistent-net.rules; do
    if [ -e "${ROOT%/}${f}" ]; then bad "stale unique file: ${f}"; else ok "absent: ${f}"; fi
done

# --- 6. iSCSI initiator ----------------------------------------------------
iqn="${ROOT%/}/etc/iscsi/initiatorname.iscsi"
if [ -s "$iqn" ] && ! grep -q 'GENERATE' "$iqn"; then
    bad "static iSCSI IQN: $(grep -h InitiatorName "$iqn")"
else
    ok "no static iSCSI IQN"
fi

# --- 7. Credential residue -------------------------------------------------
for f in /root/.ssh/authorized_keys /root/.bash_history /etc/krb5.keytab; do
    [ -e "${ROOT%/}${f}" ] && bad "credential residue: ${f}" || ok "absent: ${f}"
done

echo
[ "$fail" -eq 0 ] && echo "RESULT: image is de-identified and publishable." \
                  || echo "RESULT: image carries host identity — DO NOT PUBLISH."
exit "$fail"
```

Corrélo contra una imagen no montada con `guestmount`, para nunca tener que arrancar el artefacto que estás auditando:

```
# guestmount -a output/base-deb12-2026.08/base-deb12-2026.08.qcow2 -i --ro /mnt/img
# verify-image-identity /mnt/img
Auditing image root: /mnt/img
  PASS  machine-id present and empty (fresh ID generated at boot)
  PASS  D-Bus machine-id is a symlink, absent or empty
  PASS  no SSH host private keys in the image
  PASS  cloud-init state clean
  PASS  absent: /var/lib/systemd/random-seed
  PASS  absent: /var/lib/urandom/random-seed
  PASS  absent: /var/lib/NetworkManager/secret_key
  PASS  absent: /etc/udev/rules.d/70-persistent-net.rules
  PASS  no static iSCSI IQN
  PASS  absent: /root/.ssh/authorized_keys
  PASS  absent: /root/.bash_history
  PASS  absent: /etc/krb5.keytab

RESULT: image is de-identified and publishable.
# guestunmount /mnt/img
```

---

## 12. Runbooks de diagnóstico de fallas

### 12.1 Dos VMs, una IP

**Síntoma.** Reinicios intermitentes de conexión; `arping -D` encuentra un duplicado; el servidor DHCP muestra un solo lease.

```
# arping -D -I enp1s0 -c 3 10.20.4.117
ARPING 10.20.4.117 from 0.0.0.0 enp1s0
Unicast reply from 10.20.4.117 [52:54:00:6F:2A:11]  0.712ms
Unicast reply from 10.20.4.117 [52:54:00:AB:CD:EF]  0.905ms   <-- two MACs, one IP
Sent 3 probes (3 broadcast(s))
Received 2 response(s)
```

**Diagnóstico.**

```
$ for h in web-01 web-02 web-03; do
>   printf '%-8s %s\n' "$h" "$(ssh $h cat /etc/machine-id)"
> done
web-01   5a5b0d3f1f9c4a1f8e2b7c6d4e3f2a10
web-02   5a5b0d3f1f9c4a1f8e2b7c6d4e3f2a10
web-03   5a5b0d3f1f9c4a1f8e2b7c6d4e3f2a10

$ networkctl status enp1s0 | grep -i 'DHCP4 Client ID'
     DHCP4 Client ID: DUID
```

**Arreglo (por host, inmediato).**

```
# rm -f /etc/machine-id && systemd-machine-id-setup
Initializing machine ID from random generator.
# rm -f /var/lib/dbus/machine-id && ln -s /etc/machine-id /var/lib/dbus/machine-id
# rm -f /var/lib/dhcp/* /run/systemd/netif/leases/*
# printf '[Match]\nName=en*\n\n[Network]\nDHCP=ipv4\n\n[DHCPv4]\nClientIdentifier=mac\n' \
      > /etc/systemd/network/10-dhcp.network
# networkctl reload && networkctl reconfigure enp1s0
# systemctl restart systemd-journald   # journal path contains the machine-id
```

**Arreglo (permanente).** Truncar `/etc/machine-id` en la imagen y condicionar la publicación a la §11.

### 12.2 El invitado entra en panic: `unknown-block(0,0)`

**Síntoma.** Después de convertir una máquina física o de VMware a KVM, el invitado nunca llega al espacio de usuario.

```
[    2.451236] VFS: Cannot open root device "vda2" or unknown-block(0,0): error -6
[    2.451240] Please append a correct "root=" boot option; here are the available partitions:
[    2.451245] Kernel panic - not syncing: VFS: Unable to mount root fs on unknown-block(0,0)
[    2.451251] CPU: 0 PID: 1 Comm: swapper/0 Not tainted 6.1.0-18-amd64 #1
```

**Diagnóstico.** El initramfs no tiene `virtio_blk`/`virtio_pci`, así que el dispositivo raíz no existe en el momento del pivot. Chequealo offline:

```
# guestmount -a disk.qcow2 -i --ro /mnt/img
# lsinitrd /mnt/img/boot/initramfs-$(uname -r).img | grep -c virtio
0
```

**Arreglo.** Reconstruir el initramfs con los drivers forzados adentro.

```
# RHEL family:
# dracut --force --add-drivers "virtio_blk virtio_scsi virtio_net virtio_pci virtio_ring virtio" \
      /boot/initramfs-$(uname -r).img $(uname -r)
# lsinitrd /boot/initramfs-$(uname -r).img | grep virtio | head -4
-rw-r--r--   1 root     root        20480 Aug 26 10:41 usr/lib/modules/6.1.0/kernel/drivers/block/virtio_blk.ko.xz
-rw-r--r--   1 root     root        57344 Aug 26 10:41 usr/lib/modules/6.1.0/kernel/drivers/net/virtio_net.ko.xz

# Debian family:
# printf 'virtio_pci\nvirtio_blk\nvirtio_scsi\nvirtio_net\nvirtio_ring\n' \
      >> /etc/initramfs-tools/modules
# update-initramfs -u -k all
update-initramfs: Generating /boot/initrd.img-6.1.0-18-amd64
```

Para una imagen que no podés arrancar, `virt-v2v` hace todo esto — inyección de drivers, arreglos del bootloader, renombrado de dispositivos — en una sola pasada.

### 12.3 `cloud-init` no hizo nada

**Síntoma.** La instancia arranca, pero no hay usuarios, ni paquetes, ni configuración de red.

```
$ cloud-init status --long
status: error
extended_status: error
boot_status_code: enabled-by-generator
last_update: Tue, 26 Aug 2026 10:52:04 +0000
detail: DataSourceNone
errors:
  - 'Used fallback datasource'
recoverable_errors: {}
```

`DataSourceNone` es la pista: no se encontró ninguna fuente de datos. Recorré el camino hacia atrás.

```
# 1. Did the units even run?
$ systemctl list-units --all 'cloud-*' --no-pager
  UNIT                        LOAD   ACTIVE SUB    DESCRIPTION
  cloud-config.service        loaded active exited Apply the settings specified in cloud-config
  cloud-final.service         loaded active exited Execute cloud user/final scripts
  cloud-init-local.service    loaded active exited Initial cloud-init job (pre-networking)
  cloud-init-network.service  loaded active exited Initial cloud-init job (metadata service crawler)

# 2. Which datasources were tried, and why did each fail?
$ sudo grep -E 'Datasource|DataSource|not found|failed' /var/log/cloud-init.log | tail -12
2026-08-26 10:51:31,204 - handlers.py[DEBUG]: finish: init-local/search-NoCloud: FAIL: no local data found from DataSourceNoCloud
2026-08-26 10:51:48,881 - url_helper.py[DEBUG]: Calling 'http://169.254.169.254/2009-04-04/meta-data/instance-id' failed [50/60s]: request error [HTTPConnectionPool(host='169.254.169.254', port=80): Max retries exceeded]
2026-08-26 10:52:04,110 - DataSourceEc2.py[CRITICAL]: Giving up on md from ['http://169.254.169.254/2009-04-04/meta-data/instance-id'] after 60 seconds

# 3. Is the seed device actually attached and labelled?
$ lsblk -o NAME,LABEL,FSTYPE,SIZE,MOUNTPOINT
NAME   LABEL      FSTYPE   SIZE MOUNTPOINT
sr0    cidata-x   iso9660  366K              <-- label is wrong: must be "cidata"
vda                         60G 
└─vda1 cloudimg-rootfs ext4  60G /

# 4. Is the metadata service reachable at all?
$ curl -s --connect-timeout 3 http://169.254.169.254/ || echo "IMDS unreachable"
IMDS unreachable
$ ip route get 169.254.169.254
RTNETLINK answers: Network is unreachable        <-- no link-local route
```

**Causas raíz, en orden descendente de frecuencia:**

| Causa | Evidencia | Arreglo |
|---|---|---|
| La etiqueta de volumen del ISO semilla no es `cidata`/`CIDATA` | `lsblk -o LABEL` | Reconstruir con `-volid cidata` |
| `/var/lib/cloud` fue clonado junto con la imagen | `/var/lib/cloud/data/instance-id` coincide con la instancia vieja | `cloud-init clean --logs --seed` y reiniciar |
| El firewall del host bloquea el link-local 169.254.0.0/16 | `ip route get 169.254.169.254` | Permitir la ruta; revisar `nftables`/security groups |
| `datasource_list` fijada a una fuente de datos que no está presente | `/etc/cloud/cloud.cfg.d/90_*.cfg` | Corregir la lista |
| `cloud-init` deshabilitado | Existe `/etc/cloud/cloud-init.disabled`, o `cloud-init=disabled` en la línea de comandos del kernel | Quitarlo |
| YAML inválido en user-data | `cloud-init schema --system --annotate` | Arreglar y volver a sembrar |
| El límite de saltos de AWS IMDSv2 es 1 y estás llamando desde un contenedor | 401/403 desde IMDS | Subir el límite de saltos, o usar IRSA |

Validar el user-data contra el esquema *antes* del arranque es el hábito de mayor valor acá:

```
$ cloud-init schema --config-file user-data --annotate
Cloud config schema errors: runcmd.0: 'systemctl enable qemu-guest-agent' is not of type 'array'

user-data:
---
...
27  runcmd:
28    - systemctl enable qemu-guest-agent		# E1
...
---
# E1: runcmd.0: 'systemctl enable qemu-guest-agent' is not of type 'array'
```

Y volver a correr el aprovisionamiento limpiamente en una instancia de prueba:

```
# cloud-init clean --logs --seed --machine-id
# reboot
```

`--machine-id` (cloud-init ≥ 23.2) reinicia `/etc/machine-id` a `uninitialized`, haciendo que el próximo arranque sea un verdadero primer arranque. `--configs` además elimina la configuración de red renderizada.

Análisis de tiempos, cuando `cloud-init` funciona pero el arranque es lento:

```
$ cloud-init analyze blame | head -12
-- Boot Record 01 --
     31.24500s (init-network/check-for-datasource)
     12.09100s (modules-final/config-package-update-upgrade-install)
      2.88400s (modules-config/config-apt-configure)
      0.94700s (init-network/config-growpart)
      0.51200s (init-network/config-resizefs)
      0.23100s (init-network/config-ssh)
      0.04300s (modules-final/config-runcmd)

1 boot records analyzed

$ cloud-init analyze show | head -8
-- Boot Record 01 --
The total time elapsed since completing an event is printed after the "@" character.
The time the event takes is printed after the "+" character.

Starting stage: init-local
|`->no cache found @00.24700s +00.00100s
|`->found local data from DataSourceNoCloud @00.25000s +00.51100s
Finished stage: (init-local) 00.79800s
```

31 segundos en `check-for-datasource` significa que el sondeo del IMDS agotó su tiempo antes de caer al siguiente — fijá `datasource_list` a la fuente de datos que realmente tenés.

### 12.4 El reloj del invitado se desvía después de una migración en vivo

```
$ chronyc tracking
Reference ID    : 50484330 (PHC0)
Stratum         : 2
System time     : 0.000000012 seconds fast of NTP time
Last offset     : -0.000000018 seconds
RMS offset      : 0.000000031 seconds
Frequency       : 12.045 ppm slow
Skew            : 0.004 ppm
Root delay      : 0.000000001 seconds
Root dispersion : 0.000001832 seconds
Update interval : 4.0 seconds
Leap status     : Normal
```

Si `current_clocksource` es `tsc` en lugar de `kvm-clock`, el invitado está confiando en un TSC que la migración en vivo puede hacer saltar. Verificá que el hipervisor exponga `kvmclock` (`<timer name='kvmclock' present='yes'/>` en el XML del dominio) y que el invitado no lo esté anulando con `clocksource=tsc` en la línea de comandos del kernel.

### 12.5 Arranque sin red y sin consola

La salida de emergencia universal es la consola serie. Configurala en la imagen antes de necesitarla:

```
# /etc/default/grub
GRUB_CMDLINE_LINUX_DEFAULT="console=tty0 console=ttyS0,115200n8 net.ifnames=0"
GRUB_TERMINAL="console serial"
GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"
```
```
# update-grub          # grub2-mkconfig -o /boot/grub2/grub.cfg on RHEL
# systemctl enable serial-getty@ttyS0.service
```
```
$ virsh console k8s-worker-04
Connected to domain 'k8s-worker-04'
Escape character is ^] (Ctrl + ])

Debian GNU/Linux 12 k8s-worker-04 ttyS0

k8s-worker-04 login:
```

El último argumento `console=` gana para `/dev/console`, así que poné `ttyS0` al final. En plataformas de nube esta misma configuración es lo que hace que `openstack console log show` / `aws ec2 get-console-output` produzcan algo en absoluto — incluidas las huellas de las claves de host SSH de la §8.3.

---

## 13. Resumen orientado al examen

Los hechos que LPI probablemente evalúe, enunciados llanamente:

- **Una VM ejecuta su propio kernel; un contenedor comparte el del host.** Esa sola oración responde la mayoría de las preguntas conceptuales de este objetivo.
- **`/etc/machine-id`** — 32 caracteres hexadecimales, definido una vez por instalación, sobrevive a los reinicios, debe ser **único por host**. Se reinicia con `rm /etc/machine-id && systemd-machine-id-setup`, o se envía **vacío** en una plantilla. Ausente o conteniendo `uninitialized` ⇒ systemd trata el arranque como un **primer arranque**; vacío ⇒ se genera un ID nuevo pero **no** es un primer arranque.
- **`/var/lib/dbus/machine-id`** — el machine ID de D-Bus; normalmente un enlace simbólico a `/etc/machine-id`; generado por `dbus-uuidgen`.
- Las **claves de host SSH** viven en `/etc/ssh/ssh_host_*_key` (+ `.pub`), deben borrarse antes de crear la plantilla, y las regenera `ssh-keygen -A`.
- **`cloud-init`** — el agente estándar de aprovisionamiento de invitados. Archivo de configuración `/etc/cloud/cloud.cfg` (+ `/etc/cloud/cloud.cfg.d/`). Consume **`meta-data`** (identidad provista por la plataforma, incluye `instance-id`) y **`user-data`** (tu configuración; un documento YAML `#cloud-config`, o un script que empieza con `#!`). Lee el servicio de metadatos en **`169.254.169.254`**. El estado vive en `/var/lib/cloud`. Etapas: local → red → config → final.
- **Drivers de invitado**: `virtio_*` para KVM/QEMU; `open-vm-tools` para VMware; `hyperv-daemons` (`hv_kvp_daemon`, `hv_vss_daemon`, `hv_fcopy_daemon`) para Hyper-V; Guest Additions para VirtualBox; `qemu-guest-agent` para la integración con libvirt.
- **Elementos de IaaS**: instancia de cómputo, almacenamiento en bloque (persistente, re-adjuntable) vs efímero/instance store (muere con la instancia), almacenamiento de objetos, y red virtual (subredes, security groups, IPs flotantes).
- **Detectar virtualización**: `systemd-detect-virt` (salida 0 = virtualizado), `virt-what`, `lscpu`, `dmidecode`, el flag `hypervisor` en `/proc/cpuinfo`.
- **También únicos por host**: hostname, claves de host SSH, `machine-id`, machine ID de D-Bus, nombre de iniciador iSCSI, semillas aleatorias, leases DHCP, reglas udev persistentes de NIC.

---

## 14. Referencias

**LPI — objetivos de certificación**
- Objetivos del examen LPIC-1 101 (versión 5.0) — <https://www.lpi.org/our-certifications/exam-101-objectives/>
- Objetivos del examen LPIC-1 102 (versión 5.0) — <https://www.lpi.org/our-certifications/exam-102-objectives/>
- Panorama de la certificación LPIC-1 — <https://www.lpi.org/our-certifications/lpic-1-overview/>

**systemd — identidad de máquina y detección de virtualización**
- `machine-id(5)` — <https://www.freedesktop.org/software/systemd/man/latest/machine-id.html>
- `systemd-machine-id-setup(1)` — <https://www.freedesktop.org/software/systemd/man/latest/systemd-machine-id-setup.html>
- `systemd-detect-virt(1)` — <https://www.freedesktop.org/software/systemd/man/latest/systemd-detect-virt.html>
- `systemd-firstboot(1)` y la semántica de primer arranque — <https://www.freedesktop.org/software/systemd/man/latest/systemd-firstboot.html>
- `systemd.network(5)` (`ClientIdentifier=`, `DUIDType=`) — <https://www.freedesktop.org/software/systemd/man/latest/systemd.network.html>
- `sd_id128_get_machine_app_specific(3)` — <https://www.freedesktop.org/software/systemd/man/latest/sd_id128_get_machine.html>
- `systemd-nspawn(1)` — <https://www.freedesktop.org/software/systemd/man/latest/systemd-nspawn.html>

**cloud-init**
- Índice de documentación — <https://cloudinit.readthedocs.io/en/latest/>
- Etapas de arranque — <https://cloudinit.readthedocs.io/en/latest/explanation/boot.html>
- Referencia de módulos — <https://cloudinit.readthedocs.io/en/latest/reference/modules.html>
- Fuentes de datos (incl. NoCloud, ConfigDrive, EC2, OpenStack) — <https://cloudinit.readthedocs.io/en/latest/reference/datasources.html>
- Fuente de datos NoCloud — <https://cloudinit.readthedocs.io/en/latest/reference/datasources/nocloud.html>
- Formatos de user-data — <https://cloudinit.readthedocs.io/en/latest/explanation/format.html>
- Configuración de red (v1 y v2) — <https://cloudinit.readthedocs.io/en/latest/reference/network-config.html>
- Referencia del CLI (`status`, `clean`, `schema`, `query`, `analyze`) — <https://cloudinit.readthedocs.io/en/latest/reference/cli.html>
- Documentos cloud-config de ejemplo — <https://cloudinit.readthedocs.io/en/latest/reference/examples.html>

**OpenSSH**
- `ssh-keygen(1)` — <https://man.openbsd.org/ssh-keygen.1>
- `sshd_config(5)` (`HostCertificate`, `TrustedUserCAKeys`) — <https://man.openbsd.org/sshd_config.5>
- `ssh_config(5)` (`VerifyHostKeyDNS`, `UpdateHostKeys`) — <https://man.openbsd.org/ssh_config.5>
- Autenticación por certificados de OpenSSH — <https://man.openbsd.org/ssh-keygen.1#CERTIFICATES>

**Plataformas de virtualización e integración de invitados**
- Especificación Virtio (OASIS) — <https://docs.oasis-open.org/virtio/virtio/v1.2/virtio-v1.2.html>
- Linux KVM — <https://linux-kvm.org/page/Main_Page>
- Documentación de QEMU — <https://www.qemu.org/docs/master/>
- Agente de invitado de QEMU — <https://qemu.readthedocs.io/en/latest/interop/qemu-ga.html>
- Formato XML de dominio de libvirt — <https://libvirt.org/formatdomain.html>
- `virt-sysprep(1)` — <https://libguestfs.org/virt-sysprep.1.html>
- `virt-v2v(1)` — <https://libguestfs.org/virt-v2v.1.html>
- `virt-what(1)` — <https://people.redhat.com/~rjones/virt-what/>
- open-vm-tools — <https://github.com/vmware/open-vm-tools>
- Linux en Hyper-V (servicios de integración) — <https://learn.microsoft.com/en-us/virtualization/hyper-v-on-windows/quick-start/enable-linux-support>
- Documentación del Xen Project — <https://xenbits.xen.org/docs/>
- Drivers PV de Xen / PVHVM — <https://wiki.xenproject.org/wiki/PV_on_HVM>
- microVM Firecracker — <https://firecracker-microvm.github.io/>
- Kata Containers — <https://katacontainers.io/docs/>

**Contenedores**
- `namespaces(7)` — <https://man7.org/linux/man-pages/man7/namespaces.7.html>
- `cgroups(7)` — <https://man7.org/linux/man-pages/man7/cgroups.7.html>
- Control Group v2 (kernel) — <https://docs.kernel.org/admin-guide/cgroup-v2.html>
- Especificación de imágenes OCI — <https://github.com/opencontainers/image-spec/blob/main/spec.md>
- Especificación de runtime OCI — <https://github.com/opencontainers/runtime-spec/blob/main/spec.md>
- Documentación de Podman — <https://docs.podman.io/en/latest/>
- Documentación de LXD — <https://documentation.ubuntu.com/lxd/en/latest/>

**Servicios de metadatos de nube**
- Metadatos de instancia de AWS (IMDSv2) — <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-instance-metadata.html>
- Metadatos de VM de Google Cloud — <https://cloud.google.com/compute/docs/metadata/overview>
- Azure Instance Metadata Service — <https://learn.microsoft.com/en-us/azure/virtual-machines/instance-metadata-service>
- Servicio de metadatos de OpenStack — <https://docs.openstack.org/nova/latest/user/metadata.html>

**Construcción de imágenes**
- HashiCorp Packer — <https://developer.hashicorp.com/packer/docs>
- Imágenes de nube oficiales de Debian — <https://cloud.debian.org/images/cloud/>
- Ignition (Fedora CoreOS) — <https://coreos.github.io/ignition/>
- Especificación de configuración Butane — <https://coreos.github.io/butane/>