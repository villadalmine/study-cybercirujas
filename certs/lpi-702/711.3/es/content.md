# Guía de Estudio: LPI BSD Specialist (Examen 702-100, Versión 1.0)
## Tema 711.3: Configuración del Inicio del Sistema BSD
**Peso:** 5  
**Nivel Objetivo:** Senior SRE / Principal Platform Architect

---

## 1. Motivación Arquitectónica y Contexto de Producción

En despliegues empresariales de misión crítica, la inicialización determinista y predecible del ciclo de vida del sistema operativo es esencial. A diferencia de las distribuciones modernas de Linux que se basan en gran medida en `systemd` (un daemon de inicialización monolítico basado en objetivos que utiliza activación por socket y ejecución paralela con motores de estado complejos), los sistemas BSD se adhieren estrictamente a la filosofía Unix de separación clara de responsabilidades, predictibilidad lineal e inicialización modular mediante scripts de shell a través del framework `rc.subr(8)` y `rcorder(8)`.

```
+-----------------------------------------------------------------------------------+
|                                 BOOT LIFECYCLE                                    |
+-----------------------------------------------------------------------------------+
|  [Hardware / UEFI]                                                                |
|         |                                                                         |
|         v                                                                         |
|  [Stage 1/2 Bootloader: /boot/loader] ---> Reads /boot/loader.conf                |
|         |                                   (Loads kernel & early drivers/tunables)|
|         v                                                                         |
|  [Kernel Initialization: /boot/kernel/kernel]                                     |
|         |                                   (Mounts root filesystem, initializes  |
|         v                                    devices, creates init PID 1)         |
|  [Process 1: /sbin/init]                                                          |
|         |                                   (Executes /etc/rc script)             |
|         v                                                                         |
|  [Initialization Framework: /etc/rc]                                             |
|         |                                                                         |
|         +---> Evaluates /etc/defaults/rc.conf + /etc/rc.conf                      |
|         |                                                                         |
|         +---> Invokes rcorder(8) over /etc/rc.d/* & /usr/local/etc/rc.d/*        |
|         |                                                                         |
|         v                                                                         |
|  [Service Execution Flow] (Ordered by PROVIDE, REQUIRE, BEFORE, KEYWORD)          |
+-----------------------------------------------------------------------------------+
```

Desde la perspectiva de SRE y Platform Engineering, dominar la secuencia de inicio de BSD garantiza:
- **Determinismo de Estado**: Las dependencias entre interfaces de red, pools de almacenamiento (ZFS), daemons de enrutamiento y servicios de aplicaciones se aplican estrictamente mediante Grafos Acíclicos Dirigidos (DAGs) generados en tiempo de arranque.
- **División de Configuración a Prueba de Fallos**: Los valores predeterminados del sistema base (`/etc/defaults/rc.conf`) están limpiamente desacoplados de las anulaciones del administrador (`/etc/rc.conf` o `/etc/rc.conf.d/*`), minimizando la deriva de configuración durante las actualizaciones del sistema operativo.
- **Herramientas Core sin Dependencias**: Los scripts de recuperación del arranque inicial dependen exclusivamente de `/bin/sh` y primitivas compatibles con POSIX, lo que previene fallos de arranque circulares causados por bibliotecas de tiempo de ejecución enlazadas dinámicamente.

---

## 2. Mecánica Detallada y Comparación Técnica

### 2.1 La Mecánica de la Cadena de Inicio

1. **Fase del Bootloader (`/boot/loader`)**: Lee `/boot/loader.conf` y `/boot/defaults/loader.conf`. Carga módulos del kernel (por ejemplo, `zfs.ko`, `accf_http.ko`), inicializa variables de entorno tempranas del kernel (`kenv`) y configura la disposición de memoria de bajo nivel antes de la ejecución del kernel.
2. **Fase del Kernel (`kernel`)**: Arranca, detecta hardware por sonda, configura la Memoria Virtual (VM), inicializa nodos de dispositivos a través de `devfs`, monta la raíz (`/`) y crea (fork) el proceso de userland `init` (PID 1).
3. **Fase de Init en Userland (`/sbin/init`)**: Lee `/etc/ttys` y ejecuta `/etc/rc`.
4. **Fase del Motor RC (`/etc/rc`)**: Carga (sources) `/etc/rc.subr`. Carga la configuración global predeterminada desde `/etc/defaults/rc.conf`, seguida de `/etc/rc.conf` y las anulaciones específicas del sitio en `/etc/rc.conf.d/`.
5. **Resolución de Dependencias (`rcorder`)**: Escanea los encabezados de bloque de los scripts en `/etc/rc.d/` y `/usr/local/etc/rc.d/`. Construye un orden de ejecución topológico basado en palabras clave de dependencia (`PROVIDE`, `REQUIRE`, `BEFORE`, `KEYWORD`).

### 2.2 Matriz Comparativa del Inicio en Variantes de BSD

| Característica / Subsistema | FreeBSD | NetBSD | OpenBSD |
| :--- | :--- | :--- | :--- |
| **Motor de Init Principal** | `rc.subr(8)` + `rcorder(8)` | `rc.subr(8)` + `rcorder(8)` | Personalizado `/etc/rc` + `rcctl(8)` |
| **Archivo de Valores Predeterminados del Sistema** | `/etc/defaults/rc.conf` | `/etc/defaults/rc.conf` | `/etc/rc.conf` (valores predeterminados base) |
| **Archivo de Configuración Local** | `/etc/rc.conf`, `/etc/rc.conf.d/` | `/etc/rc.conf`, `/etc/rc.conf.d/` | `/etc/rc.conf.local` |
| **Servicios de Terceros** | `/usr/local/etc/rc.d/` | `/usr/pkg/etc/rc.d/` | `/etc/rc.d/` |
| **CLI de Control de Servicios** | `service(8)`, `sysrc(8)` | `service(8)` | `rcctl(8)` |
| **Configuración del Bootloader** | `/boot/loader.conf` | `/boot.cfg` | `/etc/boot.conf` |
| **Ajustes del Kernel (Tunables)** | `/etc/sysctl.conf` & `loader.conf` | `/etc/sysctl.conf` | `/etc/sysctl.conf` |
| **Ejecución en Primer Arranque** | `/etc/rc.local` / flag `firstboot` | `/etc/rc.local` | `/etc/rc.firsttime` |

---

## 3. Configuración de Producción y Framework de Servicios Personalizados

A continuación se presentan archivos de configuración listos para producción y completamente calificados que demuestran el ajuste del kernel, la habilitación de servicios y la envoltura de servicios personalizados con `rc.subr`.

### 3.1 Ajustes del Bootloader del Kernel: `/boot/loader.conf`

```ini
# /boot/loader.conf - Production FreeBSD Hypervisor & Storage Node Configuration

# Core Storage Driver & ZFS Memory Bounds
zfs_load="YES"
vfs.zfs.arc.max="34359738368"             # Limit ZFS ARC to 32 GB RAM

# Network Subsystem Buffer Allocation & Hardware Offload Tunables
kern.ipc.nmbclusters="1048576"            # Expand network mbuf clusters for 10GbE/40GbE
net.inet.tcp.tcbhashsize="524288"         # Increase TCP Control Block hash table size

# Asynchronous HTTP Accept Filter Kernel Module
accf_http_load="YES"
accf_data_load="YES"

# Crypto Acceleration Driver
cryptodev_load="YES"
aesni_load="YES"

# Link Aggregation & VLAN Support
if_lagg_load="YES"
if_vlan_load="YES"

# Security & Console Silence
autoboot_delay="3"
beastie_disable="YES"
loader_color="NO"
```

---

### 3.2 Valores Predeterminados del Estado del Kernel en Tiempo de Ejecución: `/etc/sysctl.conf`

```ini
# /etc/sysctl.conf - Production Runtime Kernel State Tuning

# Network Stack Security & Performance
net.inet.tcp.rfc1323=1                    # Enable Window Scaling & Timestamps
net.inet.tcp.mssdflt=1460                 # Default Maximum Segment Size
net.inet.tcp.sendspace=262144             # 256KB TCP Send Buffer
net.inet.tcp.recvspace=262144             # 256KB TCP Receive Buffer
net.inet.tcp.drop_synfin=1                # Drop invalid SYN+FIN packets (port scan countermeasure)
net.inet.ip.redirect=0                    # Disable ICMP redirect sending

# Process & Virtual Memory Limits
kern.maxproc=65536                        # Global max processes
kern.maxfiles=2097152                     # Global file descriptor ceiling
kern.ipc.somaxconn=4096                   # Listen queue limit for sockets

# Shared Memory for Database Engines (PostgreSQL / Redis)
kern.ipc.shmmax=34359738368
kern.ipc.shmall=8388608
```

---

### 3.3 Anulaciones de Inicialización del Sistema: `/etc/rc.conf`

```sh
# /etc/rc.conf - Primary System Service Configuration

# Host identity and Network Infrastructure
hostname="edge-node-01.prod.internal"
keymap="us.iso.acc"

# Interface Addressing & Link Aggregation (LACP)
cloned_interfaces="lagg0 vlan100"
ifconfig_ix0="up"
ifconfig_ix1="up"
ifconfig_lagg0="laggproto lacp laggport ix0 laggport ix1 up"
ifconfig_vlan100="inet 192.168.100.15 netmask 255.255.255.0 vlan 100 vlandev lagg0"
defaultrouter="192.168.100.1"

# Core System Daemons
sshd_enable="YES"
ntpd_enable="YES"
ntpd_sync_on_start="YES"
syslogd_flags="-s -s"                     # Secure mode: Do not listen on UDP network ports

# Core Storage & File Systems
zfs_enable="YES"
dumpdev="AUTO"                            # Enable kernel crash dumps

# Third-Party Production Daemons
nginx_enable="YES"
postgresql_enable="YES"
node_exporter_enable="YES"

# Custom Service Settings Override via Inline Subdir Processing
rc_conf_files="/etc/rc.conf /etc/rc.conf.local"
```

---

### 3.4 Script de Unidad de Servicio Empresarial: `/usr/local/etc/rc.d/sre_app`

Este script sintácticamente válido de `rc.subr` en FreeBSD implementa declaraciones adecuadas de bloques de dependencias, seguimiento de procesos, gestión de directorios de tiempo de ejecución y comandos personalizados.

```sh
#!/bin/sh

# PROVIDE: sre_app
# REQUIRE: LOGIN DAEMON NETWORKING postgresql
# BEFORE:  nginx
# KEYWORD: shutdown

. /etc/rc.subr

name="sre_app"
rcvar="sre_app_enable"

# Load default configurations
load_rc_config ${name}

: ${sre_app_enable:="NO"}
: ${sre_app_user:="www"}
: ${sre_app_group:="www"}
: ${sre_app_config:="/usr/local/etc/sre_app/config.yaml"}
: ${sre_app_pidfile:="/var/run/sre_app/sre_app.pid"}

command="/usr/local/bin/sre_app_exporter"
command_args="-config ${sre_app_config} > /var/log/sre_app.log 2>&1 &"
pidfile="${sre_app_pidfile}"

start_precmd="sre_app_prestart"
extra_commands="reload status checkconfig"
reload_cmd="sre_app_reload"
checkconfig_cmd="sre_app_checkconfig"

sre_app_prestart()
{
    if [ ! -d "/var/run/sre_app" ]; then
        install -d -o ${sre_app_user} -g ${sre_app_group} -m 0755 /var/run/sre_app
    fi
    if [ ! -f "${sre_app_config}" ]; then
        err 1 "Configuration file ${sre_app_config} does not exist."
    fi
}

sre_app_checkconfig()
{
    echo "Verifying syntax for ${name} configuration..."
    ${command} -validate -config ${sre_app_config}
}

sre_app_reload()
{
    echo "Reloading ${name} configuration..."
    if [ -f "${pidfile}" ]; then
        kill -HUP $(cat ${pidfile})
    else
        echo "${name} is not running."
    fi
}

run_rc_command "$1"
```

---

## 4. Ejecución Real de CLI y Operaciones de Servicio

### 4.1 Inspección y Modificación Segura de `rc.conf` Usando `sysrc(8)`

`sysrc` proporciona una edición atómica de `/etc/rc.conf` y consultas seguras sin riesgo de degradación sintáctica.

```console
$ sysrc sre_app_enable
sre_app_enable: NO

$ sudo sysrc sre_app_enable="YES"
sre_app_enable: NO -> YES

$ sysrc -f /etc/rc.conf.d/sre_app sre_app_flags="--verbose --port=9090"
sre_app_flags:  -> --verbose --port=9090

$ sysrc -a | grep _enable | head -n 5
sshd_enable: YES
ntpd_enable: YES
zfs_enable: YES
nginx_enable: YES
postgresql_enable: YES
```

---

### 4.2 Consulta del Estado de Servicios del Sistema a Través de `service(8)`

La utilidad `service` abstrae las rutas de scripts `/etc/rc.d/` y `/usr/local/etc/rc.d/`.

```console
$ service -e
/etc/rc.d/hostid
/etc/rc.d/zfs
/etc/rc.d/netif
/etc/rc.d/routing
/etc/rc.d/sshd
/etc/rc.d/ntpd
/usr/local/etc/rc.d/postgresql
/usr/local/etc/rc.d/sre_app
/usr/local/etc/rc.d/nginx

$ service sre_app status
sre_app is running as pid 48291.

$ service sre_app checkconfig
Verifying syntax for sre_app configuration...
Configuration /usr/local/etc/sre_app/config.yaml is valid.
```

---

### 4.3 Resolución del Orden de Dependencias con `rcorder(8)`

`rcorder` procesa los encabezados de bloque (`PROVIDE`, `REQUIRE`, `BEFORE`) y genera el flujo preciso de resolución de dependencias utilizado por `/etc/rc`.

```console
$ rcorder /etc/rc.d/* /usr/local/etc/rc.d/* | grep -E '(postgresql|sre_app|nginx)'
/usr/local/etc/rc.d/postgresql
/usr/local/etc/rc.d/sre_app
/usr/local/etc/rc.d/nginx
```

---

### 4.4 Gestión de Servicios en OpenBSD con `rcctl(8)`

Para entornos OpenBSD, la habilitación de servicios y los flags del daemon se gestionan utilizando `rcctl`.

```console
$ rcctl get ntpd
ntpd_class=daemon
ntpd_flags=
ntpd_timeout=30
ntpd_user=root
ntpd_status=on

$ sudo rcctl set pf status on
$ sudo rcctl enable custom_daemon
$ sudo rcctl set custom_daemon flags "-d -s /var/run/custom.sock"
$ rcctl ls failed
custom_daemon
```

---

### 4.5 Gestión de Módulos del Kernel al Arrancar y en Tiempo de Ejecución

```console
$ kldstat
Id Refs Address            Size     Name
 1   29 0xffffffff80200000 1f3c500  kernel
 2    1 0xffffffff8213d000 5b6c0    zfs.ko
 3    1 0xffffffff82199000 31a8     accf_http.ko
 4    1 0xffffffff8219d000 84e0     aesni.ko

$ sudo kldload accf_data
$ kldstat | grep accf
 3    1 0xffffffff82199000 31a8     accf_http.ko
 5    1 0xffffffff821a6000 2a10     accf_data.ko
```

---

## 5. Guía de Diagnóstico y Resolución de Problemas

### 5.1 Modos de Fallo Comunes en Producción

```
+-----------------------------------------------------------------------------------+
|                           COMMON RC FAILURE MODES                                 |
+-----------------------------------------------------------------------------------+
|  1. Circular Dependency Cycle in rc.d Block Headers                                |
|     --> rcorder detects loop and aborts or falls back to unsafe default.           |
|                                                                                   |
|  2. Hardcoded File System Paths Pre-LOGIN Stage                                    |
|     --> Script REQUIRES LOGIN, but tries to access /usr/local prior to /usr mount. |
|                                                                                   |
|  3. Missing 'rcvar' Assignment in Shell Functions                                 |
|     --> Service fails to respect ${name}_enable check in /etc/rc.conf.            |
|                                                                                   |
|  4. Silent Hanging in Background Forking                                          |
|     --> Script lacks proper daemon helper usage or pidfile dynamic locking.       |
+-----------------------------------------------------------------------------------+
```

---

### 5.2 Procedimiento Paso a Paso para la Resolución de Problemas

#### Paso 1: Habilitar el Rastro y la Depuración de RC
Si un sistema se cuelga durante el inicio, edite `/etc/rc.conf` o pase variables de depuración en el prompt de arranque:

```console
$ sudo sysrc rc_debug="YES"
rc_debug: NO -> YES

$ sudo sysrc rc_info="YES"
rc_info: NO -> YES
```

Cuando `rc_debug="YES"` está activo, `/etc/rc` imprime detalles de ejecución línea por línea y la evaluación de comandos de shell:

```console
/etc/rc.d/sre_app: DEBUG: run_rc_command: doctype sre_app start
/etc/rc.d/sre_app: DEBUG: check_pidfile: /var/run/sre_app/sre_app.pid sre_app
/etc/rc.d/sre_app: DEBUG: sre_app_enable is YES
/etc/rc.d/sre_app: DEBUG: executing /usr/local/bin/sre_app_exporter -config /usr/local/etc/sre_app/config.yaml
```

#### Paso 2: Validar la Integridad del Grafo de Dependencias de `rcorder`
Para detectar dependencias circulares o scripts aislados que rompan el flujo de arranque:

```console
$ rcorder -s nostart /etc/rc.d/* /usr/local/etc/rc.d/* > /dev/null
rcorder: circular dependency in script /usr/local/etc/rc.d/bad_script
```

#### Paso 3: Recuperación de Bloqueos de Arranque Mediante Modo Usuario Único (Single-User Mode)
Si un archivo `/etc/rc.conf` corrupto impide un inicio multiusuario exitoso:

1. Reinicie el servidor. En el menú de arranque del loader de FreeBSD, seleccione la Opción `2` para el **Single User Mode**.
2. Monte el sistema de archivos raíz en lectura-escritura:
   ```console
   # mount -o rw /
   # zfs mount -a
   ```
3. Pruebe la sintaxis de `/etc/rc.conf`:
   ```console
   # sh -n /etc/rc.conf
   # sh -n /etc/rc.conf.d/*
   ```
4. Corrija los errores de sintaxis usando `vi` o reinicie `rc.conf`:
   ```console
   # sysrc -f /etc/rc.conf sre_app_enable="NO"
   # exit
   ```

---

## 6. Referencias

- **LPI BSD Specialist Overview (Exam 702-100)**:  
  https://www.lpi.org/our-certifications/bsd-specialist-overview/
- **FreeBSD Handbook — The Booting Process**:  
  https://docs.freebsd.org/en/books/handbook/boot/
- **FreeBSD Manual Pages — `rc.subr(8)`**:  
  https://man.freebsd.org/cgi/man.cgi?query=rc.subr
- **FreeBSD Manual Pages — `rcorder(8)`**:  
  https://man.freebsd.org/cgi/man.cgi?query=rcorder
- **FreeBSD Manual Pages — `sysrc(8)`**:  
  https://man.freebsd.org/cgi/man.cgi?query=sysrc
- **OpenBSD Manual Pages — `rcctl(8)`**:  
  https://man.openbsd.org/rcctl
- **NetBSD Guide — The `rc.d` System**:  
  https://www.netbsd.org/docs/guide/en/chap-rc.html