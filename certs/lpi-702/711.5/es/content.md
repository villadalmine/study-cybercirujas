# Topic 711.5: BSD Kernel Parameters and System Security Level (LPI-702 Exam 702-100)

**Weight:** 3.33  
**Target Certification:** LPI BSD Specialist (Exam 702-100, Version 1.0)  
**Role Context:** Principal Platform Architect & Senior SRE Instructor  

---

## 1. Motivación y problema arquitectónico en producción

En plataformas cloud multi-tenant, clusters de edge routing y entornos de ledger financiero críticos para la misión, la integridad del kernel a nivel de sistema operativo y la gestión de tunables en runtime forman la capa fundamental de la arquitectura de defensa en profundidad. 

La vulneración del usuario `root` (UID 0) en sistemas operativos estándar tipo Unix normalmente otorga privilegios no restringidos: un atacante puede inyectar módulos arbitrarios del kernel (`kldload` / `insmod`), sobrescribir punteros de memoria física a través de dispositivos de acceso a memoria raw (`/dev/mem`, `/dev/kmem`), eludir reglas de filtrado de paquetes (`pfctl`), desmontar volúmenes de almacenamiento subyacentes o alterar logs del sistema desmarcando atributos inmutables de archivos (`chflags`).

```
                              +-------------------------------------------------------+
                              |                  SUPERUSER (UID 0)                    |
                              +-------------------------------------------------------+
                                                          |
                                                          v
                                       +-------------------------------------+
                                       |      System Security Level          |
                                       |      (kern.securelevel MIB)         |
                                       +-------------------------------------+
                                                          |
                   +--------------------------------------+--------------------------------------+
                   |                                      |                                      |
                   v                                      v                                      v
        [ Securelevel = 0 ]                    [ Securelevel = 1 ]                    [ Securelevel = 2/3 ]
    (Development / Maintenance)                   (Standard Production)                 (Hardened Edge / Financial)
- Full raw disk write access            - Raw disk write blocked on mounted FS - Raw disk write blocked on ALL disks
- Module load/unload allowed            - Kernel module loading prohibited     - Time adjustments restricted
- Immutable flags modification allowed  - File system immutable flags enforced - Firewall rules (PF/IPFW) locked
```

### El problema arquitectónico
1. **Dynamic Runtime Configuration vs. Immutable Kernel Constraints:** Los sistemas deben escalar dinámicamente socket buffers, parámetros TCP, longitudes de colas de red y páginas de Virtual Memory (VM) en runtime sin requerir la recompilación del kernel. Sin embargo, las variables críticas del estado del sistema deben estar protegidas contra manipulaciones dinámicas después de completar la secuencia de boot.
2. **Post-Exploitation Containment:** Si una vulnerabilidad en una aplicación web permite la inyección de comandos como `root`, el aislamiento estándar del ring-0 del kernel resulta ineficaz si `root` puede modificar la memoria del kernel directamente o modificar los controles de seguridad del sistema.
3. **Boot-Time Initialization Sequencing:** Ciertos parámetros del kernel (tales como tunables de hardware físico, asignaciones de memoria del sistema y máscaras de topología de CPU) deben inicializarse durante la ejecución temprana del loader (*antes* de que el kernel de BSD monte el sistema de archivos root), mientras que los parámetros MIB de runtime deben configurarse después de la inicialización.

BSD aborda este desafío a través de dos subsistemas acoplados:
- **Subsistema `sysctl(3)` MIB (Management Information Base):** Un árbol estructural de variables de estado del kernel que permite la inspección dinámica en runtime, la modificación y la inicialización temprana en tiempo de boot.
- **Motor de ejecución `kern.securelevel`:** Una máquina de estados monotónica e unidireccional ejecutada por la lógica de protección ring-0 del kernel de BSD que revoca sistemáticamente capacidades del kernel al UID 0 a medida que el estado del sistema transiciona del modo de boot single-user a la ejecución en producción multi-user.

---

## 2. Mecánica técnica profunda y comparaciones de trade-offs

### 2.1 La arquitectura del subsistema `sysctl` MIB

El kernel de BSD expone variables de estado mediante una Management Information Base (MIB) jerárquica. Los nodos en la MIB se definen utilizando arreglos de enteros o rutas de cadenas delimitadas por puntos (`sysctlbyname`).

#### Namespaces MIB de nivel superior clave
* `kern.*`: Subsistemas core del kernel (límites de procesos, hostname, IPC, securelevel, fase de boot).
* `vm.*`: Subsistema de memoria virtual (page cache, swap, límites de zfs arc, tuning del demonio pageout).
* `net.*`: Stack de red (socket buffers, enrutamiento IP, comportamiento TCP/UDP, filtros BPF).
* `hw.*`: Atributos de hardware (conteo de CPUs, arquitectura de memoria, byte order, topología de dispositivos).
* `security.*`: Políticas de seguridad (framework MAC, ASLR, restricciones de procesos en jail).
* `vfs.*`: Tunables del Virtual File System y estadísticas del sistema de archivos.

#### Distinción entre kernel tunables y `sysctl` MIBs dinámicos
Las variables de estado del kernel en BSD se categorizan por su ciclo de vida de escritura:

1. **Boot Loader Tunables (`/boot/loader.conf`):**
   * Configurados por el stage-3 bootloader (`loader(8)`) antes de la ejecución del boot del kernel.
   * Modifican tablas de asignación de memoria, bindings de drivers de dispositivos o límites fundamentales de hardware.
   * Solo lectura en runtime a través de `sysctl` (no se pueden cambiar con `sysctl name=value`).
2. **Parámetros MIB dinámicos (`/etc/sysctl.conf`):**
   * Procesados durante la secuencia estándar de boot por `/etc/rc.d/sysctl`.
   * Se pueden leer y modificar dinámicamente en runtime utilizando la utilidad `sysctl` o la API C `sysctl(3)`, siempre que el `kern.securelevel` actual permita modificaciones.
3. **Parámetros MIB estáticos de solo lectura:**
   * Expuestos por el kernel para reflejar propiedades estáticas del sistema (ej. `hw.ncpu`, `kern.ostype`). No se pueden modificar en runtime ni en archivos de configuración.

---

### 2.2 Mecánica de los System Security Levels (`kern.securelevel`)

El nivel de seguridad del sistema se controla mediante la variable MIB dinámica `kern.securelevel`. Funciona como un trinquete irreversible de reducción de privilegios.

```
       Boot Loader Init              System Initialization                    Manual Down-Level
[ Level -1: Permanently Insecure ] ----> [ Level 0: Insecure / Single-User ] ----> [ Reboot / Init 1 ]
                                                  |
                                                  | Multi-user boot / rc script
                                                  v
                                       [ Level 1: Secure Mode ]
                                                  |
                                                  | Explicit sysctl escalation
                                                  v
                                       [ Level 2: Highly Secure ]
                                                  |
                                                  | Explicit sysctl escalation
                                                  v
                                       [ Level 3: Network Secure ]
```

#### Regla de restricción monotónica
* **Escalación ascendente:** El security level se puede incrementar en cualquier momento por el superusuario (`sysctl kern.securelevel=N`, donde $N_{new} > N_{current}$).
* **Restricción descendente:** El security level **no** se puede reducir mientras el sistema se esté ejecutando en modo multi-user. Intentar establecer `sysctl kern.securelevel=0` cuando `kern.securelevel` es `1` resultará en `Operation not permitted` (`EPERM`), incluso para `root`.
* **Reset de estado:** Reducir el securelevel requiere un reinicio del sistema o bajar a modo single-user mediante acceso por consola (`init 1`).

#### Matriz detallada de Security Levels

| Security Level | Nombre | Acciones permitidas | Restricciones forzadas y salvaguardas del kernel |
| :--- | :--- | :--- | :--- |
| **-1** | Permanently Insecure | Acceso administrativo completo al sistema; carga dinámica de módulos; acceso a memoria raw. | La ejecución del securelevel del kernel está **desactivada**. Los cambios de securelevel solicitados a través de rc.conf o sysctl son ignorados en el boot. Se utiliza en sistemas embebidos o entornos de desarrollo donde se requiere depuración continua de módulos. |
| **0** | Insecure | Valor predeterminado en modo single-user. Se permiten todas las funciones administrativas. Los flags de archivos se pueden limpiar. | Fase inicial estándar del sistema. Las tareas de configuración previas a multi-user se ejecutan aquí. Aún no se aplican restricciones de security level. |
| **1** | Secure | Valor predeterminado estándar en multi-user. Se permiten modificaciones dinámicas de sysctl (si no están restringidas por flags de level 1). | 1. Se **deniega** el acceso de escritura directa a dispositivos de bloque raw que contengan sistemas de archivos montados.<br>2. Se **prohíbe** el acceso de escritura directa a dispositivos de memoria física (`/dev/mem`, `/dev/kmem`).<br>3. **No** se pueden cargar ni descargar módulos del kernel (`kldload`, `kldunload`).<br>4. **No** se pueden eliminar ni alterar los flags de archivos system immutable (`schg`) y system append-only (`sappnd`).<br>5. Las reglas de Packet Filter (PF) no se pueden limpiar si se aplican reglas de securelevel 1. |
| **2** | Highly Secure | Todos los permisos de securelevel 1. Acceso de lectura a dispositivos de disco raw. | 1. Se aplican todas las restricciones del Level 1.<br>2. Se **deniega** el acceso de escritura directa a **todos** los dispositivos de disco raw, independientemente de si el sistema de archivos está montado o desmontado.<br>3. Los ajustes del reloj del sistema mediante `settimeofday(2)` o `adjtime(2)` están restringidos para prevenir ataques de desplazamiento de tiempo (se rechazan cambios escalonados del reloj > 1 segundo). |
| **3** | Network Secure | Todos los permisos de securelevel 2. | 1. Se aplican todas las restricciones del Level 2.<br>2. Las reglas de filtrado de paquetes (`pf`, `ipfw`) **no** se pueden alterar, limpiar ni eludir, incluso por `root`. La tabla de estado del firewall no se puede recargar. |

---

### 2.3 System File Flags vs. `kern.securelevel`

Los sistemas de archivos de BSD (UFS/ZFS) proporcionan file flags (`chflags(1)`) que operan en conjunto con los system security levels para prevenir ransomware o la destrucción maliciosa de datos:

* `schg` (`SF_IMMUTABLE`): System immutable flag. El archivo no se puede modificar, eliminar, renombrar ni vincular mediante hard-link.
* `sappnd` (`SF_APPEND`): System append-only flag. El archivo solo se puede abrir en modo append para escritura.
* `sunlnk` (`SF_NOUNLINK`): System no-unlink flag. El archivo no se puede eliminar ni renombrar.

#### Regla de interacción
Cuando `kern.securelevel >= 1`:
* El superusuario **puede** establecer flags `schg`, `sappnd` o `sunlnk` en cualquier archivo.
* El superusuario **no puede** limpiar (desmarcar) flags `schg`, `sappnd` o `sunlnk` en ningún archivo (`chflags noschg <file>` falla con `Operation not permitted`).

---

### 2.4 Matriz de análisis de trade-offs

| Enfoque de configuración | Agilidad operacional | Postura de seguridad | Complejidad de recuperación | Mejor caso de uso en SRE de producción |
| :--- | :--- | :--- | :--- | :--- |
| **Default (`securelevel = -1`)** | Alta (Se permite hot-patching, carga dinámica de drivers sin reinicios). | Extremadamente baja (El compromiso de root conduce a rootkits permanentes en el kernel). | Baja (Remediación simple a través de SSH). | Nodos de build CI/CD, estaciones de trabajo de desarrolladores, suites de prueba fuera de producción. |
| **Standard Multi-User (`securelevel = 1`)** | Balanceada (MIBs de red sintonizables; servicios del sistema reiniciables). | Alta (Protege disco raw, previene la inserción de módulos, protege la inmutabilidad de logs). | Moderada (Requiere consola fuera de banda / IPMI para depuración del kernel). | Servidores web generales, clusters de bases de datos, nodos de middleware de aplicaciones. |
| **Hardened Edge (`securelevel = 2`)** | Restringida (Particionamiento de disco y sincronización de tiempo restringidos). | Muy alta (Previene el borrado de almacenamiento de bloques raw a través de `dd` en unidades desmontadas). | Alta (Requiere reinicio del sistema a modo single-user para mantenimiento de disco). | Nodos de almacenamiento ZFS dedicados, hipervisores edge, appliances SAN aislados. |
| **Immutable Firewall (`securelevel = 3`)** | Extremadamente baja (Las actualizaciones de reglas del firewall requieren reinicio de hardware). | Máxima (Defiende contra la desactivación de firewalls durante ataques APT persistentes). | Severa (Las actualizaciones de reglas exigen un ciclo de reinicio con tiempo de inactividad programado). | Routers perimetrales de alta seguridad, módulos de seguridad de hardware criptográfico (HSMs), nodos de auditoría financiera. |

---

## 3. Configuraciones de infraestructura en producción y manifiestos de producción

A continuación se presentan manifiestos de configuración sintácticamente válidos y de nivel de producción para un despliegue de infraestructura FreeBSD.

### 3.1 Manifiesto de boot loader tunables (`/boot/loader.conf`)

Esta configuración establece los parámetros de boot temprano antes de la inicialización del kernel.

```ini
# /boot/loader.conf - Production Kernel Boot Tunables
# Architecture: FreeBSD 13.x/14.x x86_64 High-Throughput Edge Router / Node

# ------------------------------------------------------------------------------
# 1. EARLY KERNEL / SECURITY TUNABLES
# ------------------------------------------------------------------------------
# Set initial boot securelevel state (processed early by loader)
kern.securelevel_enable="1"

# Enable kernel address space layout randomization (ASLR)
kern.elf64.aslr.enable=1
kern.elf32.aslr.enable=1

# Disable kernel core dumps to prevent sensitive data leakage to disk
kern.coredump=0

# Disable kernel debugger (DDB) execution on panic to enforce immediate reboot
debug.debugger_on_panic=0

# ------------------------------------------------------------------------------
# 2. NETWORK SUBSYSTEM EARLY BUFFER ALLOCATION
# ------------------------------------------------------------------------------
# Increase maximum network interface queue lengths and mbuf clusters
kern.ipc.nmbclusters="1048576"
kern.ipc.maxsockets="2048500"
net.isr.defaultthreads="8"
net.isr.bindthreads="1"

# Enable hardware-accelerated cryptodev modules at early boot
crypto_load="YES"
aesni_load="YES"

# ------------------------------------------------------------------------------
# 3. VIRTUAL MEMORY & ZFS TUNABLES
# ------------------------------------------------------------------------------
# Tune max kernel map size for high-density multi-tenant memory allocation
vm.kmemsizes="128G"

# Tune ZFS ARC (Adaptive Replacement Cache) early memory boundaries
vfs.zfs.arc_max="64424509440"
vfs.zfs.arc_min="8589934592"
```

---

### 3.2 Manifiesto de parámetros de runtime del sistema (`/etc/sysctl.conf`)

Esta configuración impone parámetros operacionales en runtime a través de `/etc/sysctl.conf`.

```ini
# /etc/sysctl.conf - Production Hardened Systems Runtime MIB Configuration
# Loaded during boot sequence via /etc/rc.d/sysctl

# ------------------------------------------------------------------------------
# 1. HARDENING AND PRIVILEGE ESCALATION PREVENTION
# ------------------------------------------------------------------------------
# Hide processes running under other UIDs / GIDs from unprivileged users
security.bsd.see_other_uids=0
security.bsd.see_other_gids=0
security.bsd.see_jail_proc=0

# Prevent unprivileged users from viewing system mesg memory buffers
security.bsd.unprivileged_read_msgbuf=0

# Disable unprivileged process debugging (prevents ptrace-based credential theft)
security.bsd.unprivileged_proc_debug=0

# Randomize PID assignment to prevent process enumeration attacks
kern.randompid=3741

# Enforce strict link protection (prevent symlink / hardlink traversal exploits in /tmp)
security.bsd.hardlink_check_uid=1
security.bsd.hardlink_check_gid=1

# ------------------------------------------------------------------------------
# 2. NETWORK STACK HARDENING & TCP/IP TUNING
# ------------------------------------------------------------------------------
# Enable TCP SYN Cookies to mitigate TCP SYN Flood Denial-of-Service attacks
net.inet.tcp.syncookies=1

# Disable ICMP Redirect processing to block MITM routing attacks
net.inet.icmp.drop_redirect=1
net.inet.ip.redirect=0

# Ignore broadcast ICMP echo requests (mitigate Smurf attack vectors)
net.inet.icmp.bmcastecho=0

# Enable RFC 1323 high-performance TCP extensions (window scaling and timestamps)
net.inet.tcp.rfc1323=1

# Increase maximum pending socket connections for high-volume HTTP/gRPC ingress
kern.ipc.somaxconn=4096

# Expand TCP send/receive buffer maximum sizes (16MB buffers)
net.inet.tcp.sendbuf_max=16777216
net.inet.tcp.recvbuf_max=16777216
net.inet.tcp.sendbuf_inc=16384
net.inet.tcp.recvbuf_inc=524288

# Drop TCP packets destined for closed ports silently (stealth mode scan mitigation)
net.inet.tcp.blackhole=2
net.inet.udp.blackhole=1
```

---

### 3.3 Manifiesto del servicio de control del sistema (`/etc/rc.conf`)

Este manifiesto configura el demonio de inicialización del sistema para forzar la elevación de securelevel durante el inicio estándar multi-user.

```sh
# /etc/rc.conf - System Initialization and Securelevel Enforcement Rules

# Host Information
hostname="edge-sre-node01.prod.infrastructure.internal"

# Networking Interface Configuration
ifconfig_vtnet0="inet 192.168.100.10 netmask 255.255.255.0 status"
defaultrouter="192.168.100.1"

# Firewall Configuration
pf_enable="YES"
pf_rules="/etc/pf.conf"
pf_flags=""

# ------------------------------------------------------------------------------
# SYSTEM SECURITY LEVEL ENFORCEMENT CONFIGURATION
# ------------------------------------------------------------------------------
# Enable securelevel escalation during boot
kern_securelevel_enable="YES"

# Set target securelevel for production multi-user operation:
# Level 1: Standard Secure Mode (protects mounted raw disks, blocks kldload, protects schg flags)
# Level 2: Highly Secure Mode (protects ALL raw disks, restricts clock adjustments)
# Level 3: Network Secure Mode (locks PF firewall rules from dynamic flushing)
kern_securelevel="1"

# Disable sendmail daemon to reduce attack surface
sendmail_enable="NONE"

# Syslog daemon hardening (disable remote socket binding unless explicitly needed)
syslogd_flags="-ss"
```

---

### 3.4 Manifiesto de despliegue de automatización (Ansible Playbook)

Este playbook de Ansible aplica los security levels del sistema BSD y los parámetros sysctl a través de una flota empresarial.

```yaml
---
- name: Harden BSD Kernel Parameters and Enforce System Security Levels
  hosts: bsd_servers
  gather_facts: true
  become: true
  tasks:

    - name: Configure Early Boot Kernel Tunables in /boot/loader.conf
      ansible.builtin.blockinfile:
        path: /boot/loader.conf
        create: true
        mode: '0644'
        marker: "# {mark} ANSIBLE MANAGED BLOCK - LOADER TUNABLES"
        block: |
          kern.securelevel_enable="1"
          kern.coredump=0
          security.bsd.aslr.enable=1

    - name: Apply Runtime MIB Parameters in /etc/sysctl.conf
      ansible.builtin.blockinfile:
        path: /etc/sysctl.conf
        create: true
        mode: '0644'
        marker: "# {mark} ANSIBLE MANAGED BLOCK - SYSCTL HARDENING"
        block: |
          security.bsd.see_other_uids=0
          security.bsd.see_other_gids=0
          security.bsd.unprivileged_proc_debug=0
          net.inet.tcp.blackhole=2
          net.inet.udp.blackhole=1
          kern.ipc.somaxconn=4096

    - name: Configure Securelevel Baseline in /etc/rc.conf
      ansible.builtin.sysrc:
        path: /etc/rc.conf
        name: "{{ item.name }}"
        value: "{{ item.value }}"
      loop:
        - { name: 'kern_securelevel_enable', value: 'YES' }
        - { name: 'kern_securelevel', value: '1' }

    - name: Set Immutable Flag on Audit Log Directory
      ansible.builtin.command:
        cmd: chflags schg /var/log/messages
      register: chflags_result
      changed_when: chflags_result.rc == 0
      failed_when: false

    - name: Verify Active Securelevel State
      ansible.builtin.command:
        cmd: sysctl kern.securelevel
      register: current_securelevel
      changed_when: false

    - name: Display Active System Security Level
      ansible.builtin.debug:
        msg: "The active system security level is: {{ current_securelevel.stdout }}"
```

---

## 4. Comandos de CLI reales y secuencias de salida de terminal

Las siguientes trazas de ejecución demuestran administración estándar, inspección en runtime, verificación de privilegios y aplicación de salvaguardas del kernel.

### 4.1 Consulta y modificación de MIBs dinámicos a través de `sysctl(8)`

#### Inspección de metadatos del MIB System Security Level
```console
$ sysctl -d kern.securelevel
kern.securelevel: System security level

$ sysctl -d security.bsd.see_other_uids
security.bsd.see_other_uids: Unprivileged processes may see other UIDs processes
```

#### Lectura del estado actual del securelevel
```console
$ sysctl kern.securelevel
kern.securelevel: 1
```

#### Consulta de todos los parámetros de blackhole del network stack
```console
$ sysctl net.inet.tcp.blackhole net.inet.udp.blackhole
net.inet.tcp.blackhole: 2
net.inet.udp.blackhole: 1
```

#### Modificación dinámica de un parámetro MIB de red permitido
```console
$ sudo sysctl net.inet.tcp.syncookies=1
net.inet.tcp.syncookies: 0 -> 1
```

---

### 4.2 Demostración de escalación de `kern.securelevel` y violaciones forzadas

#### Escalación de securelevel en runtime (transición ascendente permitida)
```console
$ sysctl kern.securelevel
kern.securelevel: 1

$ sudo sysctl kern.securelevel=2
kern.securelevel: 1 -> 2

$ sysctl kern.securelevel
kern.securelevel: 2
```

#### Intento de modificación descendente de securelevel (rechazado por el kernel)
```console
$ sudo sysctl kern.securelevel=1
sysctl: kern.securelevel: Operation not permitted

$ echo $?
1
```

#### Intento de inserción de módulo del kernel bajo `securelevel >= 1` (rechazado por el kernel)
```console
$ sudo kldload ipfw
kldload: can't load ipfw: Operation not permitted
```

#### Intento de sobrescritura directa de disco raw block bajo `securelevel >= 1`
```console
$ sudo dd if=/dev/zero of=/dev/ada0p2 bs=1M count=10
dd: /dev/ada0p2: Operation not permitted
```

---

### 4.3 Demostración de File Flags (`chflags`) bajo un securelevel alto

#### Establecimiento de System Immutable Flag en un archivo de configuración crítico
```console
$ sudo chflags schg /etc/sysctl.conf
$ ls -lo /etc/sysctl.conf
-rw-r--r--  1 root  wheel  schg 1482 Aug  6 18:30 /etc/sysctl.conf
```

#### Intento de modificación o unlink de un archivo inmutable
```console
$ sudo rm -f /etc/sysctl.conf
rm: /etc/sysctl.conf: Operation not permitted

$ sudo echo "# Malicious Injection" >> /etc/sysctl.conf
bash: /etc/sysctl.conf: Operation not permitted
```

#### Intento de borrar System Immutable Flag bajo `securelevel = 1` (rechazado por el kernel)
```console
$ sudo chflags noschg /etc/sysctl.conf
chflags: /etc/sysctl.conf: Operation not permitted
```

---

## 5. Guía de verificación, diagnóstico de fallas y troubleshooting

Al operar en entornos de producción BSD endurecidos, los SREs encuentran con frecuencia bloqueos administrativos causados por la aplicación activa del nivel de seguridad del kernel o por variables MIB mal configuradas. Esta sección proporciona una metodología de diagnóstico sistemática.

```
                             +-----------------------------------+
                             | Administrative Action Failed      |
                             | (e.g., EPERM / Operation Denied)  |
                             +-----------------------------------+
                                               |
                                               v
                             +-----------------------------------+
                             |  Check Current Securelevel State  |
                             |  ($ sysctl kern.securelevel)      |
                             +-----------------------------------+
                                               |
                     +-------------------------+-------------------------+
                     |                                                   |
                     v                                                   v
           [ Securelevel >= 1 ]                                [ Securelevel <= 0 ]
                     |                                                   |
    +----------------+----------------+                        +---------+---------+
    |                                 |                        |                   |
    v                                 v                        v                   v
[ File Flag Operation ]    [ Module / Disk Access ]   [ Check DAC Permissions ] [ Check MAC / Jail ]
Check file attributes      Requires reboot or single- Verify file owner, UID,    Verify MAC framework
via `ls -lo <path>`        user console transition.   and POSIX ACLs.        policy constraints.
```

---

### 5.1 Workflow de diagnóstico paso a paso

#### Paso 1: Diagnosticar el código de error `EPERM` (`Operation not permitted`)
Si un comando ejecutado como `root` (UID 0) falla con `Operation not permitted`, determine si la restricción es impuesta por DAC (discretionary access control), File Flags o `kern.securelevel`.

```console
# 1. Query active security level
$ sysctl kern.securelevel
kern.securelevel: 1

# 2. Check extended file flags if the failure involves a file/directory
$ ls -lo /etc/pf.conf
-rw-------  1 root  wheel  schg 2048 Aug  6 12:00 /etc/pf.conf
```
*Diagnóstico:* Si el flag `schg` o `sappnd` está presente y `kern.securelevel >= 1`, el flag **no se puede eliminar** sin bajar el nivel de seguridad del sistema mediante un reinicio.

---

#### Paso 2: Troubleshooting de carga de módulos fallida (fallas de `kldload`)
Durante los pipelines de despliegue automatizado, los scripts de Ansible o Shell pueden intentar cargar drivers del kernel (por ejemplo, `vmm.ko` para virtualización Bhyve o `pf.ko` para filtrado de red).

```console
$ sudo kldload vmm
kldload: can't load vmm: Operation not permitted
```

*Verificación de diagnóstico:*
1. Verificar el estado del módulo: `kldstat`
2. Comprobar `kern.securelevel`: Si el valor es `1`, `2` o `3`, la carga dinámica de módulos está bloqueada de forma estricta a nivel de kernel.
3. *Remediación:* Precargar los módulos requeridos en el momento de boot temprano a través de `/boot/loader.conf`:
   ```ini
   # Add to /boot/loader.conf
   vmm_load="YES"
   ```
   Requiere un reinicio del sistema para aplicarse.

---

#### Paso 3: Troubleshooting de fallas de sincronización de tiempo (`ntpd` / `chrony`)
Bajo `kern.securelevel = 2` o `3`, los ajustes grandes de reloj mediante `settimeofday(2)` son rechazados por el kernel para prevenir ataques de desviación de tiempo en tokens criptográficos y logs de auditoría.

```console
# Error logged in /var/log/messages:
ntpd[1245]: settimeofday: Operation not permitted
```

*Verificación de diagnóstico:*
* `kern.securelevel` está configurado actualmente en `2` o superior.
* El demonio NTP está intentando un ajuste escalonado (desplazamiento del reloj > 1 segundo).

*Remediación:*
Asegúrese de que el tiempo se inicialice con precisión durante el boot temprano (antes de que `rc.conf` eleve el securelevel) mediante `ntpdate` u `openntpd` antes de la transición al modo multi-user, o configure NTP para usar exclusivamente ajustes en modo slew (`adjtime(2)`).

---

#### Paso 4: Auditar discrepancias de valores MIB dinámicos
Cuando un valor definido en `/etc/sysctl.conf` no surte efecto después del boot:

1. Compruebe si la variable es un tunable de tiempo de boot en lugar de un MIB de runtime:
   ```console
   $ sysctl kern.ipc.nmbclusters=2048500
   sysctl: oid 'kern.ipc.nmbclusters' is read only
   ```
   *Resolución:* Mueva la configuración de `/etc/sysctl.conf` a `/boot/loader.conf`.

2. Inspeccione los logs de inicio de sysctl en busca de errores de sintaxis:
   ```console
   $ grep -i sysctl /var/log/messages
   ```

---

### 5.2 Matriz de referencia de herramientas de diagnóstico

| Síntoma / Tarea | Comando de diagnóstico | Salida normal esperada | Salida de problema / falla | Acción correctiva |
| :--- | :--- | :--- | :--- | :--- |
| **Verificar securelevel activo** | `sysctl kern.securelevel` | `kern.securelevel: 1` | `kern.securelevel: -1` | Habilitar `kern_securelevel_enable="YES"` en `/etc/rc.conf`. |
| **Identificar file flags** | `ls -lo /target/file` | `-rw-r--r-- 1 root wheel - ...` | `-rw-r--r-- 1 root wheel schg ...` | No se puede desmarcar `schg` mientras securelevel $\ge 1$. Debe reiniciar en modo single-user para limpiar el flag. |
| **Verificar carga de módulos** | `kldstat` | Lista módulos del kernel `.ko` activos | `kldload: Operation not permitted` | Precargar el módulo en `/boot/loader.conf` mediante `module_load="YES"`. |
| **Verificar descripción de MIB** | `sysctl -d <oid>` | Descripción completa de la variable OID | `sysctl: unknown oid '<oid>'` | Verificar la ortografía correcta o asegurarse de que el módulo del kernel requerido que expone la OID esté cargado. |
| **Depurar ejecución de Sysctl** | `service sysctl restart` | Aplica configuraciones desde `/etc/sysctl.conf` | `sysctl: oid: Operation not permitted` | La variable no se puede cambiar en el securelevel actual o es de solo lectura. |

---

## 6. Referencias

Las especificaciones técnicas y estándares descritos en este documento se derivan de la documentación oficial de BSD y de los objetivos de la certificación BSD Specialist:

1. **LPI BSD Specialist 702 Certification Overview & Objectives:**  
   [https://www.lpi.org/our-certifications/bsd-specialist-overview/](https://www.lpi.org/our-certifications/bsd-specialist-overview/)

2. **FreeBSD System Security Levels Manual Page (`securelevel(7)`):**  
   [https://man.freebsd.org/cgi/man.cgi?query=securelevel&sektion=7](https://man.freebsd.org/cgi/man.cgi?query=securelevel&sektion=7)

3. **FreeBSD System Control Utility Manual Page (`sysctl(8)`):**  
   [https://man.freebsd.org/cgi/man.cgi?query=sysctl&sektion=8](https://man.freebsd.org/cgi/man.cgi?query=sysctl&sektion=8)

4. **FreeBSD System Kernel Tunables Interface Manual Page (`loader.conf(5)`):**  
   [https://man.freebsd.org/cgi/man.cgi?query=loader.conf&sektion=5](https://man.freebsd.org/cgi/man.cgi?query=loader.conf&sektion=5)

5. **FreeBSD System Configuration Files Manual Page (`rc.conf(5)`):**  
   [https://man.freebsd.org/cgi/man.cgi?query=rc.conf&sektion=5](https://man.freebsd.org/cgi/man.cgi?query=rc.conf&sektion=5)

6. **FreeBSD File Flags Management Manual Page (`chflags(1)`):**  
   [https://man.freebsd.org/cgi/man.cgi?query=chflags&sektion=1](https://man.freebsd.org/cgi/man.cgi?query=chflags&sektion=1)

7. **FreeBSD Handbook - Chapter 15: Security & Hardening:**  
   [https://docs.freebsd.org/en/books/handbook/security/](https://docs.freebsd.org/en/books/handbook/security/)

8. **OpenBSD System Security Levels Manual Page (`securelevel(7)`):**  
   [https://man.openbsd.org/securelevel.7](https://man.openbsd.org/securelevel.7)