# Guía de Estudio para la Certificación LPIC-2 (Examen 201-450)
## Tema 201: Arquitectura, Compilación y Gestión en Tiempo de Ejecución del Kernel de Linux
**Peso del Examen:** 7 (Tema 201 Combinado: 201.1 Componentes del Kernel [Peso 2], 201.2 Compilación de un Kernel de Linux [Peso 3], 201.3 Gestión en Tiempo de Ejecución y Solución de Problemas del Kernel [Peso 4])  
**Rol Objetivo:** Senior SRE / Principal Platform Architect  

---

## 1. Motivación Arquitectónica de Producción y Planteamiento del Problema

### 1.1 El Subsistema del Kernel en la Infraestructura Empresarial
En entornos modernos nativos de la nube —como nodos de Kubernetes bare-metal de alta densidad, plataformas financieras de baja latencia o motores de almacenamiento sensibles a microsegundos— el kernel de Linux actúa como la frontera principal entre las aplicaciones de software y el cómputo físico, la memoria, las E/S y los dispositivos de hardware. 

```
                                USER SPACE (Ring 3)
+-----------------------------------------------------------------------------------+
|  Systemd Services  |  Container Runtimes (CRI-O)  |  eBPF User Agents (Cilium)   |
+-----------------------------------------------------------------------------------+
                                   |  Syscalls (sys_enter / sys_exit)
                                   v
                                KERNEL SPACE (Ring 0)
+-----------------------------------------------------------------------------------+
| System Call Interface (SCI)                                                       |
| +-------------------------+ +-------------------------+ +-----------------------+ |
| | Virtual File System     | | Memory Management (MM)  | | Networking Stack      | |
| | (VFS / ext4 / OverlayFS)| | (SLUB / Page Cache / OOM)| | (Netfilter / eBPF/tc) | |
| +-------------------------+ +-------------------------+ +-----------------------+ |
|                                                                                   |
| Dynamic Loadable Kernel Modules (LKMs)                                             |
| +-----------------------------+ +-----------------------------------------------+ |
| | NVMe Block Driver (nvme.ko) | | Out-of-tree Driver (e1000e.ko / nvidia.ko)    | |
| +-----------------------------+ +-----------------------------------------------+ |
+-----------------------------------------------------------------------------------+
                                   |  Hardware Abstraction Layer (HAL / ACPI / PCIe)
                                   v
                                HARDWARE (CPU, RAM, NVMe, NIC)
```

El kernel de Linux es una **arquitectura monolítica con un subsistema de módulos dinámico**. Las capacidades fundamentales (tales como la planificación de procesos vía EEVDF/CFS, la abstracción del Virtual File System y la paginación de memoria) se ejecutan dentro de un área de memoria privilegiada unificada conocida como **Ring 0**. 

Ejecutarse en Ring 0 introduce compromisos (trade-offs) fundamentales:
1. **Rendimiento vs. Aislamiento de Fallos:** Cualquier fallo de página no manejado, desreferencia de puntero nulo o corrupción de memoria del kernel en Ring 0 da como resultado un **Kernel Panic** u **Oops** inmediato, deteniendo toda la instancia del Sistema Operativo.
2. **Extensibilidad Dinámica vía Loadable Kernel Modules (LKMs):** En lugar de requerir una recompilación completa del kernel para admitir nuevo hardware, el kernel carga dinámicamente archivos objeto (`.ko`) en el espacio de ejecución de Ring 0 en tiempo de ejecución.
3. **Endurecimiento de Hardware y Seguridad:** Las implementaciones empresariales modernas deben evaluar continuamente los kernels de distribución provistos por los proveedores (por ejemplo, Kernels de RHEL Enterprise o Ubuntu HWE) frente a kernels compilados a medida adaptados para sondas eBPF personalizadas, controladores heredados deshabilitados (reduciendo la superficie de ataque) o ajuste de aislamiento de tablas de páginas del kernel (KPTI).

---

## 2. Comparaciones Técnicas con Tablas de Compromisos (Trade-offs)

### 2.1 Empaquetado de Componentes del Kernel: Integrado (`=y`) vs. Modular (`=m`) vs. Distro de Proveedor

| Métrica Arquitectónica | Característica Integrada del Kernel (`=y`) | Módulo de Kernel Cargable (`=m`) | Kernel de Distribución Estándar |
| :--- | :--- | :--- | :--- |
| **Latencia de Arranque** | **Más rápida:** El código se mapea en la memoria de texto del kernel durante el init temprano. | **Moderada:** Carga retrasada hasta que `udev` o `modprobe` analiza el initramfs. | **Más lenta:** Initramfs grande que contiene cientos de módulos genéricos de almacenamiento/NIC. |
| **Huella de Memoria** | Las asignaciones estáticas permanecen bloqueadas en la memoria del kernel; no se pueden liberar. | Dinámica; la memoria se asigna al cargar y se libera mediante `rmmod`/`modprobe -r`. | Alta sobrecarga inicial debido al espacio de módulos por defecto sobrecargado. |
| **Recuperación y Intercambio en Caliente (Hot-swapping)** | **Ninguna:** Requiere un reinicio completo del nodo para actualizar o deshabilitar la característica. | **Alta:** Los módulos se pueden recargar dinámicamente con parámetros actualizados sin reiniciar. | Altas opciones de recuperación a través de actualizaciones del kernel provistas por el proveedor (`yum` / `apt`). |
| **Superficie de Ataque** | Mínima si las características no necesarias se deshabilitan durante la compilación. | Variable: Explotable si la carga dinámica de módulos no está restringida vía sysctl. | Grande: Contiene controladores para sistemas de archivos heredados (por ejemplo, `cramfs`) y hardware poco común. |
| **Costo de Mantenimiento** | Alta sobrecarga de SRE (recompilación manual ante avisos de seguridad CVEs). | Moderado (requiere DKMS para módulos de terceros fuera del árbol). | Bajo (parches de seguridad del proveedor totalmente automatizados y soporte LTS). |

---

### 2.2 Utilidades de Generación de Initramfs: `dracut` vs. `initramfs-tools` vs. `booster`

| Característica / Capacidad | `dracut` (RHEL / Fedora / Alma) | `initramfs-tools` (Debian / Ubuntu) | `booster` (Nativo de la Nube Moderno) |
| :--- | :--- | :--- | :--- |
| **Objetivo Principal de Diseño** | Generación de initramfs modular multi-objetivo empresarial. | Generación de ramdisk inicial basada en hooks estándar de Debian. | Arranque de hosts de contenedores de alta velocidad y micro-VMs. |
| **Compresión por Defecto** | `xz` o `zstd` (alta relación, menor sobrecarga de tiempo de arranque de CPU). | `gzip` o `zstd`. | `zstd` (descompresión paralela optimizada). |
| **Resolución de Dependencias** | Comprueba dinámicamente `ldd` y gráficos de dependencias para binarios. | Scripts de copia de archivos codificados de forma rígida ubicados bajo `/usr/share/initramfs-tools`. | Detección automatizada de binarios estáticos y paquete mínimo de controladores. |
| **Inclusión de Módulos Personalizados** | Controlada vía `/etc/dracut.conf.d/*.conf` (`add_drivers+=`). | Controlada vía `/etc/initramfs-tools/modules`. | Configurada vía `/etc/booster.yaml`. |
| **Shell de Emergencia** | Switch-root integrado basado en systemd y shell de emergencia de dracut. | Invocación de shell BusyBox en error de arranque. | Shell de emergencia en Go personalizada y mínima. |

---

### 2.3 Herramientas de Carga y Gestión de Módulos del Kernel

| Herramienta / Mecanismo | Nivel Bajo: `insmod` / `rmmod` | Nivel Alto: `modprobe` | Fuera del Árbol (Out-of-Tree): `dkms` |
| :--- | :--- | :--- | :--- |
| **Gestión de Dependencias** | **Manual:** Falla si los LKMs dependientes no están precargados. | **Automática:** Resuelve el gráfico `modules.dep` generado por `depmod`. | Recompilación automatizada de código fuente de terceros frente a nuevos encabezados del kernel. |
| **Ruta de Configuración** | Ruta absoluta directa al archivo `.ko` obligatoria. | Búsqueda de nombre de símbolo o alias vía `/etc/modprobe.d/`. | Repositorio fuente ubicado en `/usr/src/<module>-<version>/`. |
| **Inserción de Parámetros** | Pasados directamente como cadenas clave=valor en la CLI. | Leídos desde directivas `options` en `/etc/modprobe.d/*.conf`. | Configurados en los parámetros de compilación de `dkms.conf`. |
| **Comprobación de Firma del Módulo** | Omite verificaciones de políticas de nivel superior (a menos que el kernel exija firmas strictly). | Aplica firmas criptográficas si `CONFIG_MODULE_SIG_FORCE=y`. | Firma módulos recién compilados utilizando una MOK (Machine Owner Key) local personalizada. |

---

## 3. Archivos Completos de Infraestructura, Configuración y Manifiestos

### 3.1 Configuración de Sysctl de Producción SRE Endurecida (`/etc/sysctl.d/99-kubernetes-sre-node.conf`)

```ini
# Production SRE Kernel Configuration Hardening & Performance Tuning
# Target: High-throughput Kubernetes Worker Node / Enterprise Database Host

# ====================================================================
# 1. KERNEL PANIC & OOPS MANAGEMENT
# ====================================================================
# Force reboot 10 seconds after a kernel panic occurs
kernel.panic = 10

# Panic immediately if a kernel Oops occurs (prevent running in compromised state)
kernel.panic_on_oops = 1

# Panic if a thread is stuck in Uninterruptible Sleep (D State) for > 120 seconds
kernel.hung_task_timeout_secs = 120
kernel.hung_task_panic = 1

# Disable SysRq key combinations except for emergency sync and reboot (16+128=144)
kernel.sysrq = 144

# Restrict dmesg buffer access to processes with CAP_SYSLOG
kernel.dmesg_restrict = 1

# Restrict kptr_restrict to prevent leaking kernel memory addresses via /proc
kernel.kptr_restrict = 2

# ====================================================================
# 2. VIRTUAL MEMORY & OOM TUNING
# ====================================================================
# Minimize swap usage without entirely disabling disk-backed page reclaim
vm.swappiness = 10

# Prevent memory overcommit under heavy container allocation (0 = Heuristic, 2 = Strict)
vm.overcommit_memory = 1
vm.overcommit_ratio = 80

# Increase maximum memory maps for eBPF, Elasticsearch, and Vector engines
vm.max_map_count = 262144

# Flush dirty pages to disk aggressively to prevent I/O stalls
vm.dirty_background_ratio = 5
vm.dirty_ratio = 10

# ====================================================================
# 3. FILE SYSTEM & SYSTEM LIMITS
# ====================================================================
# Increase global file descriptor allocation capacity
fs.file-max = 2097152

# Limit max process ID allocation space
kernel.pid_max = 4194304

# Increase inotify watchers for high pod/container density per node
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 8192

# ====================================================================
# 4. CORE NETWORKING & SOCKET BUFFERS
# ====================================================================
# Max TCP listen backlog queue depth for high-concurrency ingress
net.core.somaxconn = 32768
net.ipv4.tcp_max_syn_backlog = 16384

# Enable BBR TCP congestion control algorithm
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
```

---

### 3.2 Manifiesto de Dynamic Kernel Module Support (DKMS) (`/usr/src/sre-monitor-1.0.0/dkms.conf`)

```ini
# DKMS Configuration File for out-of-tree Kernel Module Build
PACKAGE_NAME="sre-monitor"
PACKAGE_VERSION="1.0.0"
CLEAN="make -C ${kernel_source_dir} M=${dkms_tree}/${PACKAGE_NAME}/${PACKAGE_VERSION}/build clean"
MAKE[0]="make -C ${kernel_source_dir} M=${dkms_tree}/${PACKAGE_NAME}/${PACKAGE_VERSION}/build modules"
BUILT_MODULE_NAME[0]="sre_monitor"
BUILT_MODULE_LOCATION[0]="./"
DEST_MODULE_LOCATION[0]="/extra"
AUTOINSTALL="yes"
REMAKE_INITRD="yes"
```

---

### 3.3 Archivo de Endurecimiento de Modprobe para Producción (`/etc/modprobe.d/production-hardening.conf`)

```ini
# Explicitly blacklist unused and insecure legacy filesystems
blacklist cramfs
blacklist freevxfs
blacklist hfs
blacklist hfsplus
blacklist jffs2
blacklist udf

# Disable unused network protocol modules via false installation hooks
install dccp /bin/true
install sctp /bin/true
install rds /bin/true
install tipc /bin/true

# Custom options for production virtualization drivers
options kvm_intel nested=1 ept=1
options e1000e InterruptThrottleRate=3,3,3
```

---

### 3.4 Reglas de Udev para Almacenamiento NVMe y E/S de Red (`/etc/udev/rules.d/99-sre-performance.rules`)

```udev
# Udev rule for NVMe I/O Queue optimization (Bypass legacy I/O scheduler)
ACTION=="add|change", KERNEL=="nvme[0-n]*", ATTR{queue/scheduler}="none", ATTR{queue/nr_requests}="1024"

# Set mq-deadline I/O scheduler for rotational magnetic disks
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="mq-deadline"

# Increase readahead memory size to 2MB for high-sequential storage reads
ACTION=="add|change", KERNEL=="sd[a-z]|nvme[0-n]*n[0-9]", ATTR{queue/read_ahead_kb}="2048"
```

---

### 3.5 Configuración Personalizada de Despliegue de Initramfs para Dracut (`/etc/dracut.conf.d/sre-initramfs.conf`)

```ini
# Add explicit storage and network modules to initramfs
add_drivers+=" nvme xhci_pci e1000e overlay "

# Omit legacy software RAID and Bluetooth modules from boot image
omit_dracutmodules+=" dmraid bluetooth "

# Compress initramfs with maximum zstd compression algorithm
compress="zstd -19"

# Include microcode updates into the early initramfs boot image
early_microcode="yes"
```

---

## 4. Comandos Reales de CLI y Salidas de Terminal

### 4.1 Consulta de Información del Kernel y Configuración de Microarquitectura

```bash
$ uname -a
Linux node-prod-k8s-01.infra.internal 6.6.43-production-sre #1 SMP PREEMPT_DYNAMIC Thu Aug 6 08:30:00 UTC 2026 x86_64 x86_64 x86_64 GNU/Linux

$ zcat /proc/config.gz | grep -E "(CONFIG_BPF_SYSCALL|CONFIG_PREEMPT_DYNAMIC|CONFIG_MODULE_SIG)"
CONFIG_BPF_SYSCALL=y
CONFIG_PREEMPT_DYNAMIC=y
CONFIG_MODULE_SIG=y
CONFIG_MODULE_SIG_FORCE=y
CONFIG_MODULE_SIG_ALL=y
CONFIG_MODULE_SIG_SHA512=y
```

---

### 4.2 Inspección de Módulos del Kernel y Rastreo de Dependencias

```bash
$ lsmod | head -n 10
Module                  Size  Used by
overlay               151552  24
e1000e                327680  0
nvme                   57344  4
nvme_core             163840  5 nvme
tpm_crb                20480  0
tpm_tis                16384  0
tpm_tis_core           28672  1 tpm_tis
crs_sre_telemetry      32768  0

$ modinfo nvme
filename:       /lib/modules/6.6.43-production-sre/kernel/drivers/nvme/host/nvme.ko.xz
version:        1.0
license:        GPL
description:    NVM Express core driver
author:         Intel Corporation
srcversion:     A1B2C3D4E5F678901234567
alias:          pci:v0000144Dd0000A808sv*sb*bc01sc08i02*
alias:          pci:v00008086d00000953sv*sb*bc01sc08i02*
depends:        nvme-core
retpoline:      Y
intree:         Y
name:           nvme
vermagic:       6.6.43-production-sre SMP preempt mod_unload modversions 
sig_id:         PKCS#7
signer:         Enterprise Infrastructure Release Authority
sig_key:        3D:C2:59:71:A4:EF
sig_hashalgo:   sha512
parm:           use_threaded_interrupts:int
parm:           io_queue_depth:int
```

---

### 4.3 Inserción de Módulos en Tiempo de Ejecución y Resolución de Dependencias vía `modprobe`

```bash
$ sudo depmod -a

$ sudo modprobe -v overlay
insmod /lib/modules/6.6.43-production-sre/kernel/fs/overlayfs/overlay.ko.xz 

$ cat /proc/modules | grep overlay
overlay 151552 24 - Live 0xffffffffc0800000 (E)
```

---

### 4.4 Flujo de Trabajo Completo (End-to-End) de Compilación del Kernel e Instalación de Módulos

```bash
# Step 1: Extract kernel source tree
$ cd /usr/src
$ sudo tar -xvf linux-6.6.43.tar.xz
$ cd linux-6.6.43

# Step 2: Import running host kernel configuration
$ sudo cp /boot/config-$(uname -r) .config
$ sudo make olddefconfig
#
# configuration written to .config
#

# Step 3: Compile kernel binary and modules across all available CPU cores
$ sudo make -j$(nproc) bzImage modules
  SYSTBL  arch/x86/entry/syscalls/syscall_32.tbl
  SYSHDR  arch/x86/include/generated/uapi/asm/unistd_32.h
  DESCEND objtool
  CALL    scripts/checksyscalls.sh
  CC      arch/x86/kernel/process.o
  LD      vmlinux.o
  MODPOST vmlinux.symvers
  CC      arch/x86/boot/bzImage
Kernel: arch/x86/boot/bzImage is ready  (#1)

# Step 4: Install compiled modules to /lib/modules/
$ sudo make modules_install
  INSTALL /lib/modules/6.6.43-production-sre/kernel/crypto/aes_generic.ko
  INSTALL /lib/modules/6.6.43-production-sre/kernel/drivers/net/ethernet/intel/e1000e/e1000e.ko
  DEPMOD  /lib/modules/6.6.43-production-sre

# Step 5: Install bootloader artifacts to /boot
$ sudo make install
sh ./arch/x86/boot/install.sh 6.6.43-production-sre \
	arch/x86/boot/bzImage System.map "/boot"
```

---

### 4.5 Generación de la Imagen de Arranque Initramfs Objetivo Usando `dracut`

```bash
$ sudo dracut --force --kver 6.6.43-production-sre /boot/initramfs-6.6.43-production-sre.img
Executing: /usr/bin/dracut --force --kver 6.6.43-production-sre /boot/initramfs-6.6.43-production-sre.img
*** Creating image file '/boot/initramfs-6.6.43-production-sre.img' ***
*** Creating initramfs image file '/boot/initramfs-6.6.43-production-sre.img' done ***

$ ls -lh /boot/initramfs-6.6.43-production-sre.img
-rw-r--r-- 1 root root 32M Aug 6 09:15 /boot/initramfs-6.6.43-production-sre.img
```

---

### 4.6 Aplicación y Verificación de Parámetros de Sysctl en Tiempo de Ejecución

```bash
$ sudo sysctl -p /etc/sysctl.d/99-kubernetes-sre-node.conf
kernel.panic = 10
kernel.panic_on_oops = 1
kernel.hung_task_timeout_secs = 120
kernel.hung_task_panic = 1
kernel.sysrq = 144
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
vm.swappiness = 10
vm.overcommit_memory = 1
vm.overcommit_ratio = 80
vm.max_map_count = 262144
vm.dirty_background_ratio = 5
vm.dirty_ratio = 10
fs.file-max = 2097152
kernel.pid_max = 4194304
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 8192
net.core.somaxconn = 32768
net.ipv4.tcp_max_syn_backlog = 16384
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

$ cat /proc/sys/kernel/panic
10
```

---

## 5. Verificación Avanzada y Diagnóstico / Guía de Solución de Problemas de Fallos

### 5.1 Diagrama de Flujo de Diagnóstico: Fallos en Tiempo de Ejecución del Kernel y Módulos

```
                           Kernel / LKM Runtime Failure Detected
                                             |
                   +-------------------------+-------------------------+
                   |                                                   |
        System Halts / Crash                            Module Fails to Load
                   |                                                   |
        +----------v----------+                             +----------v----------+
        | Read Kernel Ring    |                             | Execute modprobe -v |
        | Buffer (dmesg/kdump)|                             | Check dmesg logs    |
        +----------+----------+                             +----------+----------+
                   |                                                   |
         +---------+---------+                               +---------+---------+
         |                   |                               |                   |
   Kernel Panic         Soft Lockup /                  "Required key       "Exec format
     (Oops)             Hung Task                      not available"         error"
         |                   |                               |                   |
  +------v-------+    +------v-------+                +------v-------+    +------v-------+
  | Check NULL   |    | Check CPU    |                | Disable Secure|   | Recompile LKM|
  | pointer /    |    | contention,  |                | Boot or sign  |   | against exact|
  | Page Fault   |    | memory dead- |                | LKM using MOK |   | vermagic     |
  | addresses    |    | lock state   |                +--------------+    | headers      |
  +--------------+    +--------------+                                    +--------------+
```

---

### 5.2 Fallos Comunes del Kernel en Producción y Libro de Jugadas (Playbook) de Remediación

#### Escenario A: La Inserción del Módulo Falla con `Key missing or invalid` / `Required key not available`
*   **Causa Raíz:** El kernel del host tiene habilitado `CONFIG_MODULE_SIG_FORCE=y` o UEFI Secure Boot está activo. El módulo `.ko` fuera del árbol carece de una firma válida reconocida por el llavero (keyring) del sistema.
*   **Comando de Diagnóstico:**
    ```bash
    $ sudo modprobe custom_driver
    modprobe: ERROR: could not insert 'custom_driver': Required key not available
    $ dmesg | tail -n 2
    [ 1234.567890] Custom_driver: Loading module verification failed: Update key database or secure boot policy (-126)
    ```
*   **Remediación:**
    Firme el módulo compilado utilizando el par de Machine Owner Key (MOK) local:
    ```bash
    $ sudo /usr/src/kernels/$(uname -r)/scripts/sign-file sha256 \
      /var/lib/shim-signed/mok/MOK.priv \
      /var/lib/shim-signed/mok/MOK.der \
      custom_driver.ko
    ```

---

#### Escenario B: La Carga del Módulo Falla con `Invalid module format` (`-1` / `ENOEXEC`)
*   **Causa Raíz:** Desajuste entre la versión en tiempo de ejecución del kernel (`uname -r`) y el árbol de encabezados del kernel (`vermagic`) utilizado para compilar el archivo objeto.
*   **Comando de Diagnóstico:**
    ```bash
    $ sudo insmod ./my_module.ko
    insmod: ERROR: could not insert module ./my_module.ko: Invalid module format
    $ dmesg | tail -n 1
    [ 2345.678901] my_module: version magic '6.6.0 SMP mod_unload' should be '6.6.43-production-sre SMP preempt mod_unload'
    ```
*   **Remediación:** Limpie el directorio de compilación, apunte `KDIR` al árbol de encabezados del kernel en tiempo de ejecución exacto y recompile:
    ```bash
    $ make -C /lib/modules/$(uname -r)/build M=$PWD clean
    $ make -C /lib/modules/$(uname -r)/build M=$PWD modules
    ```

---

#### Escenario C: Diagnóstico de Kernel Soft Lockups e Hilos en Uninterruptible Sleep (Estado D)
*   **Causa Raíz:** Un hilo del kernel o controlador LKM está atascado esperando E/S de hardware o bloqueado dentro de una sección crítica sin ceder la CPU.
*   **Comando de Diagnóstico:**
    ```bash
    $ dmesg | grep -i "soft lockup"
    [ 3456.789123] watchdog: BUG: soft lockup - CPU#4 stuck for 26s! [kworker/4:2:1892]

    # Trace active D-State tasks via SysRq trigger:
    $ echo w | sudo tee /proc/sysrq-trigger
    $ dmesg | tail -n 30
    ```
*   **Análisis de la Salida:** Inspeccione el trazo de la pila (stack trace) impreso en `dmesg` para identificar la llamada a la función con fallos (por ejemplo, `nvme_submit_user_cmd`).

---

### 5.3 Rastreo Dinámico en Vivo del Kernel vía `bpftrace`

Para rastrear la latencia de entrada de llamadas al sistema o llamadas a funciones del kernel sin modificar el código fuente del kernel ni reiniciar, aproveche los tracepoints modernos de eBPF:

```bash
# Trace kernel block I/O request latency distribution in real-time
$ sudo bpftrace -e 'kprobe:blk_mq_start_request { @start[arg0] = nsecs; } kprobe:blk_update_request /@start[arg0]/ { @us = hist((nsecs - @start[arg0]) / 1000); delete(@start[arg0]); }'
Attaching 2 probes...
^C

@us: 
[1]                  102 |@@                                      |
[2, 4)               452 |@@@@@@@@@                               |
[4, 8)              2104 |@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@|
[8, 16)              890 |@@@@@@@@@@@@@@@@                          |
[16, 32)             120 |@@                                      |
```

---

## 6. Referencias

*   **Objetivos del Examen LPIC-2 del Linux Professional Institute (LPI):**  
    [https://www.lpi.org/our-certifications/lpic-2-overview/](https://www.lpi.org/our-certifications/lpic-2-overview/)
*   **Documentación del Kernel de Linux (Árboles Oficiales del Kernel):**  
    [https://www.kernel.org/doc/html/latest/](https://www.kernel.org/doc/html/latest/)
*   **Guía de Administración del Kernel de Linux - Subsistemas de Carga de Módulos y Sysctl:**  
    [https://www.kernel.org/doc/html/latest/admin-guide/index.html](https://www.kernel.org/doc/html/latest/admin-guide/index.html)
*   **Especificaciones de Reglas de Udev y Gestión de Dispositivos de Systemd:**  
    [https://www.freedesktop.org/software/systemd/man/latest/udev.html](https://www.freedesktop.org/software/systemd/man/latest/udev.html)
*   **Wiki Oficial del Kernel y Guía de Configuración de Dracut:**  
    [https://dracut.wiki.kernel.org/](https://dracut.wiki.kernel.org/)