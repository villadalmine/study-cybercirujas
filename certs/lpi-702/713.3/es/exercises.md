# LPI BSD Specialist (Exam 702-100) — Topic 713.3: Maintain System Time

**Peso:** 1.67  
**Certificación objetivo:** LPI BSD Specialist (Versión 1.0)  
**Nivel:** Advanced SRE / Production Platform Engineering  

---

## 1. Arquitectura técnica profunda y mecánica interna

### 1.1 Arquitectura de Hardware Clock (RTC) vs. System Clock

Los sistemas operativos BSD mantienen dos relojes distintos: el **Real-Time Clock (RTC / CMOS Clock)** y el **System Clock (Kernel Timekeeper)**.

```
+-------------------------------------------------------------------+
|                        Hardware Layer                             |
|  Real-Time Clock (RTC / CMOS) [Battery Backed, Persists on Off]   |
+-------------------------------------------------------------------+
                                  |
               Boot Initialization / Shutdown Sync
               (FreeBSD: adjkerntz(8) / init)
                                  v
+-------------------------------------------------------------------+
|                        Kernel Subsystem                           |
|  System Clock (Monotonic & Realtime Epoch via Timecounter API)    |
+-------------------------------------------------------------------+
       ^                                                    ^
       | Slewing (adjtime(2))                               | Stepping (settimeofday(2))
       | max ~500 PPM rate adj                              | hard jump (large offsets)
+-------------------------------+  +--------------------------------+
|       NTP Daemon (ntpd)       |  |  Manual / One-shot Utilities   |
| (FreeBSD ntpd / OpenBSD ntpd) |  |   (date, sntp, ntpdate -b)    |
+-------------------------------+  +--------------------------------+
```

1. **Hardware Clock (RTC / CMOS)**:
   - Alimentado por una batería en la placa base (motherboard). Mantiene el seguimiento del tiempo mientras la máquina está apagada.
   - Típicamente opera en **Coordinated Universal Time (UTC)** en sistemas Unix. 
   - En sistemas FreeBSD con arranque dual (dual-boot) o que requieren tiempo RTC local, `adjkerntz(8)` mantiene el offset entre la hora local y UTC almacenada en el reloj CMOS, actualizando las variables del kernel mediante llamadas al sistema.

2. **System Clock (Kernel Clock)**:
   - Representado como segundos fraccionarios transcurridos desde el Unix Epoch (`1970-01-01 00:00:00 UTC`).
   - Impulsado continuamente durante el uptime por temporizadores de hardware de alta frecuencia (HPET, TSC, ACPI-fast) monitoreados por el **Timecounter framework** del kernel.

3. **Timezone Resolution**:
   - Las zonas horarias (timezones) no alteran el System Clock; solo alteran las conversiones legibles por humanos.
   - Gestionado a través de `/etc/localtime`, el cual es una copia o enlace simbólico que apunta a un archivo zoneinfo compilado dentro de `/usr/share/zoneinfo/` (por ejemplo, `/usr/share/zoneinfo/UTC` o `/usr/share/zoneinfo/America/New_York`).
   - Administrado de forma nativa en FreeBSD utilizando `tzsetup(8)`.

---

### 1.2 Kernel Timecounters y dinámica de Clock Drift

FreeBSD se apoya en la capa de abstracción `timecounter(9)` para medir intervalos de tiempo. El kernel consulta los temporizadores de hardware disponibles y selecciona la fuente más confiable según la puntuación de calidad (quality scoring) del hardware.

```
$ sysctl kern.timecounter
kern.timecounter.tc.i8254.mask: 65535
kern.timecounter.tc.i8254.counter: 41208
kern.timecounter.tc.i8254.frequency: 1193182
kern.timecounter.tc.i8254.quality: 0
kern.timecounter.tc.ACPI-fast.mask: 16777215
kern.timecounter.tc.ACPI-fast.counter: 12401831
kern.timecounter.tc.ACPI-fast.frequency: 3579545
kern.timecounter.tc.ACPI-fast.quality: 1000
kern.timecounter.tc.HPET.mask: 4294967295
kern.timecounter.tc.HPET.counter: 284104812
kern.timecounter.tc.HPET.frequency: 14318180
kern.timecounter.tc.HPET.quality: 950
kern.timecounter.tc.TSC-low.mask: 4294967295
kern.timecounter.tc.TSC-low.counter: 1984019284
kern.timecounter.tc.TSC-low.frequency: 2394410180
kern.timecounter.tc.TSC-low.quality: 1000
kern.timecounter.hardware: TSC-low
kern.timecounter.choice: TSC-low(1000) ACPI-fast(1000) HPET(950) i8254(0) dummy(-1000000)
```

#### Mecánica de ajuste de reloj: Slewing vs. Stepping

| Parámetro | Slewing (`adjtime(2)`) | Stepping (`settimeofday(2)` / `clock_settime(2)`) |
| :--- | :--- | :--- |
| **Ejecución** | Modifica la tasa de frecuencia del tick del sistema. | Jump brusco (hard jump) directamente al epoch objetivo. |
| **Continuidad del reloj** | Monotónica, continua. El tiempo nunca retrocede. | No monotónica. Puede causar saltos de tiempo hacia atrás. |
| **Delta máximo de drift** | Se utiliza cuando el offset es pequeño ($< 128\text{ ms}$ por defecto en NTP estándar). | Se utiliza cuando el offset es grande ($> 128\text{ ms}$ o en el inicio inicial). |
| **Tasa máxima de slew** | Usualmente limitada a 500 Parts Per Million (PPM) ($0.5\text{ ms/s}$). | Instantánea. |
| **Impacto en aplicaciones** | Seguro para bases de datos en producción (PostgreSQL, ZFS txgs, Kafka, autenticación TLS). | Alto riesgo de claves primarias duplicadas, timeouts rotos y corrupción de logs. |

#### Pipeline de filtrado NTP y jerarquía de Stratum

1. **Arquitectura de Stratum**:
   - **Stratum 0**: Dispositivos físicos de alta precisión (relojes atómicos, receptores GPS, osciladores de Rubidio).
   - **Stratum 1**: Servidores conectados directamente a dispositivos Stratum 0.
   - **Stratum 2**: Servidores sincronizándose a través de conexiones de red con servidores Stratum 1.
   - **Stratum $N$**: Servidores sincronizándose con servidores Stratum $N-1$ (máximo Stratum 15; Stratum 16 indica un estado no sincronizado).

2. **Algoritmos de selección**:
   - **Algoritmo de Marzullo / Intersection Algorithm**: Filtra los "falsetickers" (servidores que producen picos de tiempo erróneos) e aisla los "truechimers".
   - **Clock Discipline Algorithm**: Calcula el offset de frecuencia fraccionario (registrado en `/var/db/ntp/ntp.drift` o `/var/db/ntpd.drift`) para ajustar la frecuencia del oscilador del kernel de manera persistente.

---

### 1.3 Implementaciones de BSD NTP: FreeBSD `ntpd` vs. OpenBSD OpenNTPD

| Característica | FreeBSD Reference `ntpd` | OpenBSD OpenNTPD (`ntpd`) |
| :--- | :--- | :--- |
| **Codebase upstream** | Código de referencia de Network Time Foundation (NTF) `ntp.org` | Proyecto OpenBSD (reescritura clean-room) |
| **Enfoque principal** | Máxima precisión de reloj, soporte completo de la especificación RFC 5905. | Seguridad, separación de privilegios, minimalismo, facilidad de configuración. |
| **Configuración** | `/etc/ntp.conf` | `/etc/ntpd.conf` |
| **Utilidad de control** | `ntpq` (Consulta estadísticas del daemon y matriz de peers) | `ntpctl` (Consulta el estado del daemon y sensores) |
| **Modelo de privilegios** | Proceso daemon estándar | Usuario no privilegiado `_ntp` en chroot + monitor padre privilegiado |
| **Constraints HTTPS** | No incorporado nativamente | Soportado (`constraint from`), utiliza TLS para prevenir ataques MITM |

---

## 2. Configuraciones de referencia y manifiestos de producción

### 2.1 Enterprise FreeBSD `/etc/ntp.conf`

```conf
# ==============================================================================
# Enterprise Production NTP Configuration - FreeBSD
# File: /etc/ntp.conf
# Reference: ntp.conf(5)
# ==============================================================================

# Record the frequency offset of the local system clock.
driftfile /var/db/ntp/ntp.drift

# Directory for statistics files
statsdir /var/log/ntp/
filegen peerstats file peerstats type day enable
filegen loopstats file loopstats type day enable

# ==============================================================================
# Security & Access Control Matrix (Default Deny Stance)
# ==============================================================================

# Ignore all incoming packet streams by default (Security hardening)
restrict default limited kod nomodify nopeer noquery notrap
restrict -6 default limited kod nomodify nopeer noquery notrap

# Allow full management access from local loopback interfaces
restrict 127.0.0.1
restrict ::1

# ==============================================================================
# Upstream Stratum 1/2 Time Servers (Pool & Explicit Peers)
# ==============================================================================

# Pool directive fetches multiple IPs from pool.ntp.org DNS round-robin
pool 0.freebsd.pool.ntp.org iburst maxpoll 9
pool 1.freebsd.pool.ntp.org iburst maxpoll 9
pool 2.freebsd.pool.ntp.org iburst maxpoll 9

# Explicit upstream stratum 1 servers with restriction privileges allowed for sync
server time.nist.gov iburst
restrict time.nist.gov nomodify async noquery

# Disable panic threshold (allows step adjustment on boot regardless of offset magnitude)
tinker panic 0
```

---

### 2.2 Configuración de inicio del sistema FreeBSD `/etc/rc.conf`

```sh
# ==============================================================================
# Time Synchronization Daemon Settings - FreeBSD
# File: /etc/rc.conf
# Reference: rc.conf(5)
# ==============================================================================

# Enable standard FreeBSD ntpd daemon on system startup
ntpd_enable="YES"

# Perform initial step jump on boot before starting continuous slewing daemon
ntpd_sync_on_start="YES"

# Custom operational arguments for ntpd daemon process
ntpd_flags="-p /var/run/ntpd.pid -f /var/db/ntp/ntp.drift"

# Ensure CMOS clock is updated correctly upon shutdown/reboot
adjkerntz_flags="-a"
```

---

### 2.3 Configuración segura de OpenBSD OpenNTPD `/etc/ntpd.conf`

```conf
# ==============================================================================
# OpenNTPD Production Manifest with HTTPS Constraints - OpenBSD
# File: /etc/ntpd.conf
# Reference: ntpd.conf(5)
# ==============================================================================

# Listen on local interfaces for internal subnet queries
listen on 127.0.0.1
listen on ::1

# Query NTP pool servers for time synchronization
servers pool.ntp.org

# Attach hardware sensors (e.g. DCF77, GPS attached to serial port) if present
sensor *

# ==============================================================================
# Security Constraints (TLS-Anchored Time Validation against MITM Attacks)
# ==============================================================================

# Validate NTP timestamps against authenticated HTTPS Date headers
constraint from "www.google.com"
constraints from "https://www.cloudflare.com"
```

---

## 3. Ejercicios guiados prácticos de producción

### Ejercicio 1: Configuración de Timezone, ajuste de RTC e inspección de Kernel Timecounter

#### Paso 1.1: Verificar el tiempo actual del sistema y establecer la zona horaria del sistema a UTC de forma no interactiva

Ejecutá los siguientes comandos para inspeccionar el tiempo del sistema y configurar los parámetros de zona horaria en FreeBSD:

```bash
# Check current timezone link and system date
ls -l /etc/localtime
date -u
```

*Salida esperada:*
```text
-r--r--r--  1 root  wheel  3519 Aug  6 20:40 /etc/localtime
Thu Aug  6 20:40:16 UTC 2026
```

Establecé la zona horaria del sistema a UTC usando `tzsetup`:

```bash
# Non-interactively install UTC zoneinfo to /etc/localtime
tzsetup -s UTC
ls -l /etc/localtime
```

*Salida esperada:*
```text
lrwxr-xr-x  1 root  wheel  36 Aug  6 20:40 /etc/localtime -> /usr/share/zoneinfo/UTC
```

#### Paso 1.2: Inspeccionar la elección de timecounter del kernel, métricas de calidad y temporizadores de hardware

Ejecutá `sysctl` para inspeccionar los candidatos de hardware para el timecounter evaluados por el kernel de BSD:

```bash
sysctl kern.timecounter.choice kern.timecounter.hardware
```

*Salida esperada:*
```text
kern.timecounter.choice: TSC-low(1000) ACPI-fast(1000) HPET(950) i8254(0) dummy(-1000000)
kern.timecounter.hardware: TSC-low
```

#### Paso 1.3: Analizar el estado del reloj de hardware CMOS y ejecutar `adjkerntz`

Consultá los ajustes de tiempo del RTC de hardware:

```bash
adjkerntz -a
```

*Salida esperada:*
```text
(Command executes silently with return code 0, syncing kernel local-time offset to RTC).
```

---

#### Preguntas de verificación (Ejercicio 1)

**Pregunta 1.1:** Un servidor de base de datos en producción con FreeBSD exhibe saltos inexplicables de marcas de tiempo (timestamps) en los logs hacia atrás de 5 horas cada vez que el sistema se reinicia. La investigación revela que `/etc/localtime` apunta a `America/New_York` (UTC-5), pero el reloj de hardware RTC CMOS se mantiene en hora local mediante la BIOS de la motherboard. ¿Qué utilidad y mecanismo de archivo de configuración se deben utilizar para garantizar que el kernel compense los offsets del RTC en hora local durante el arranque?

**Pregunta 1.2:** ¿Cuál es el principal riesgo operacional de cambiar `kern.timecounter.hardware` a `i8254` (puntuación de calidad 0) en un hipervisor multicore de alto rendimiento (high-throughput) que ejecuta FreeBSD?

---

### Ejercicio 2: Configuración de producción y gestión del `ntpd` de referencia de FreeBSD

#### Paso 2.1: Escribir `/etc/ntp.conf` y aplicar controles de acceso restringidos

Desplegá el archivo `/etc/ntp.conf` de producción:

```bash
cat << 'EOF' > /etc/ntp.conf
driftfile /var/db/ntp/ntp.drift
restrict default limited kod nomodify nopeer noquery notrap
restrict -6 default limited kod nomodify nopeer noquery notrap
restrict 127.0.0.1
restrict ::1

pool 0.freebsd.pool.ntp.org iburst
pool 1.freebsd.pool.ntp.org iburst
EOF
```

#### Paso 2.2: Realizar un step sync de disparo único (one-shot) antes del inicio del daemon

Antes de iniciar la sincronización continua, ejecutá un salto de paso (step jump) usando `ntpd -gq` (o `sntp`) para corregir un drift inicial alto del reloj:

```bash
ntpd -gq
```

*Salida esperada:*
```text
ntpd: time slew +0.001248s
```

#### Paso 2.3: Habilitar e iniciar el servicio `ntpd` en `/etc/rc.conf`

```bash
sysrc ntpd_enable="YES"
sysrc ntpd_sync_on_start="YES"
service ntpd start
```

*Salida esperada:*
```text
ntpd_enable: NO -> YES
ntpd_sync_on_start: NO -> YES
Starting ntpd.
```

#### Paso 2.4: Inspeccionar la topología de peers NTP y el estado usando `ntpq`

Consultá la matriz de estado de peers y las variables del sistema usando `ntpq`:

```bash
ntpq -p
```

*Salida esperada:*
```text
     remote           refid      st t when poll reach   delay   offset  jitter
==============================================================================
*time.nist.gov   .GPS.            1 u   24   64  377   18.241   -0.112   0.042
+0.freebsd.pool  192.168.1.1      2 u   19   64  377   24.810    0.245   0.108
+1.freebsd.pool  204.9.156.12     2 u   52   64  377   31.104   -0.089   0.095
```

Ejecutá la consulta de información del sistema:

```bash
ntpq -c sysinfo
```

*Salida esperada:*
```text
associd=0 status=0615 leap_none, sync_ntp, 1 filter, condition_pass,
system peer:        time.nist.gov:123
system peer mode:   client
leap:               00
stratum:            2
log2 precision:     -23
rootdelay:          18.241
rootdisp:           11.450
reference ID:       129.6.15.28
reference time:     eb5291a0.d4e21a00  Thu, Aug  6 2026 20:40:32.831
system jitter:      0.042000 ms
clock jitter:       0.038 ms
clock wander:       0.001 PPM
broadcastdelay:     0.000
sys_choplset:       0.000
```

---

#### Preguntas de verificación (Ejercicio 2)

**Pregunta 2.1:** En la salida de `ntpq -p`, ¿qué significa el carácter marcador asterisco (`*`) antepuesto a `time.nist.gov` en comparación con el carácter signo más (`+`) antepuesto a `0.freebsd.pool`?

**Pregunta 2.2:** ¿Por qué se recomienda la opción `iburst` en las directivas pool y server en los archivos `/etc/ntp.conf` empresariales?

---

### Ejercicio 3: Diagnóstico avanzado, análisis de drift y validación de OpenBSD OpenNTPD / Constraint

#### Paso 3.1: Analizar el drift de frecuencia del reloj de hardware en `/var/db/ntp/ntp.drift`

Examiná el contenido del archivo de drift de frecuencia del reloj generado por `ntpd`:

```bash
cat /var/db/ntp/ntp.drift
```

*Salida esperada:*
```text
-12.483
```

#### Paso 3.2: Solucionar problemas de firewall y bloqueo del puerto UDP 123 de NTP

Si `ntpq -p` muestra que los valores de `reach` permanecen en `0` o no se incrementan hasta `377` octal, probá el transporte de paquetes UDP hacia servidores NTP remotos.

Inspeccioná la representación octal de alcanzabilidad actual a través de `ntpq`:

```bash
ntpq -c "rv &1 reach,offset,delay"
```

*Salida esperada (Estado de falla):*
```text
reach=000, offset=0.000, delay=0.000
```

*Salida esperada (Estado saludable después de 8 sondeos exitosos):*
```text
reach=377, offset=-0.112, delay=18.241
```

#### Paso 3.3: Verificar el estado operacional de OpenBSD OpenNTPD a través de `ntpctl`

En sistemas OpenBSD que usan `openntpd`, ejecutá la inspección del sistema usando `ntpctl`:

```bash
ntpctl -s all
```

*Salida esperada:*
```text
1/1 peers valid, clock is synced, stratum 2

peer                           not valid   cnt  interval  offset
104.131.205.158 from pool      valid       8    32s       -0.084ms

constraint                     status                          received
172.217.16.206 from www.google.com
                               valid                           1s ago
```

---

#### Preguntas de verificación (Ejercicio 3)

**Pregunta 3.1:** Un administrador nota que `/var/db/ntp/ntp.drift` contiene un valor de `500.000`. Los logs del daemon indican `frequency error 500 PPM exceeds tolerance limit`. ¿Qué indica esto sobre el hardware subyacente del sistema para el mantenimiento del tiempo, y cómo reacciona el `ntpd` estándar ante esta condición?

**Pregunta 3.2:** ¿Cómo protegen las directivas `constraint` de OpenNTPD de OpenBSD a un sistema contra ataques de suplantación de tiempo (time-spoofing) Network Time Protocol Man-In-The-Middle (MITM)?

---

## 4. Documentación oficial de referencia

- **LPI BSD Specialist Certification Overview**:  
  [https://www.lpi.org/our-certifications/bsd-specialist-overview/](https://www.lpi.org/our-certifications/bsd-specialist-overview/)
- **FreeBSD Handbook — Network Time Protocol (NTP)**:  
  [https://docs.freebsd.org/en/books/handbook/network-servers/#network-ntp](https://docs.freebsd.org/en/books/handbook/network-servers/#network-ntp)
- **FreeBSD Manual Pages (`ntp.conf(5)`, `ntpd(8)`, `adjkerntz(8)`, `timecounter(9)`)**:  
  [https://man.freebsd.org/](https://man.freebsd.org/)
- **OpenBSD Manual Pages (`ntpd(8)`, `ntpd.conf(5)`, `ntpctl(8)`)**:  
  [https://man.openbsd.org/](https://man.openbsd.org/)

---

## 5. Respuestas y explicaciones técnicas

<details>
<summary><strong>Hacé clic para desplegar las respuestas y el fundamento técnico</strong></summary>

### Clave de respuestas del Ejercicio 1

* **Respuesta 1.1:**
  Para manejar un reloj CMOS mantenido en hora local, FreeBSD utiliza `adjkerntz(8)`. La configuración se mantiene en `/etc/rc.conf` mediante `adjkerntz_flags="-a"` y es invocada durante el arranque y el apagado (`rc.d/adjkerntz`). Cuando se ejecuta con `-a`, `adjkerntz` calcula el offset entre UTC y el tiempo de reloj local (wall clock time) según `/etc/localtime` e instruye al kernel (`machdep.wall_cmos_clock`) sobre cómo interpretar las lecturas del RTC de hardware con precisión sin incurrir en saltos de fase de 5 horas al reiniciar.

* **Respuesta 1.2:**
  El timecounter `i8254` se basa en el antiguo Intel 8254 Programmable Interval Timer (PIT). Tiene una puntuación de calidad de `0` porque leerlo requiere lecturas costosas de puertos I/O (`0x40`/`0x43`), las cuales implican una alta latencia de CPU y contención de bus. En sistemas SMP multicore, los bloqueos concurrentes y las detenciones (stalls) en puertos I/O al obtener marcas de tiempo del sistema (`gettimeofday(2)`) degradan severamente el rendimiento (throughput) y añaden un overhead masivo de CPU en comparación con los registros contadores de hardware sin bloqueos (lockless) como `TSC-low` o `HPET`.

---

### Clave de respuestas del Ejercicio 2

* **Respuesta 2.1:**
  En la salida de `ntpq -p`:
  - El asterisco (`*`) indica el **system peer**. Esta es la única fuente upstream activa seleccionada por el algoritmo de disciplina de reloj de NTP para sincronizar el System Clock local.
  - El signo más (`+`) indica un **candidate peer** (superviviente del algoritmo de intersección de Marzullo). Los candidate peers son fuentes validadas y de alta calidad que están listas para asumir el rol de system peer si el system peer actual (`*`) falla o deja de estar accesible.

* **Respuesta 2.2:**
  La opción `iburst` (ráfaga inicial) instruye a `ntpd` a enviar una ráfaga de 8 paquetes espaciados por 2 segundos cuando un peer remoto no está accesible o al iniciar el daemon por primera vez. Esto permite a `ntpd` adquirir rápidamente múltiples muestras de tiempo, completar la sincronización y establecer una disciplina de reloj válida en cuestión de segundos tras el inicio, en lugar de esperar a lo largo de los intervalos de sondeo (polling) estándar (que pueden tomar entre 64 y 1024 segundos).

---

### Clave de respuestas del Ejercicio 3

* **Respuesta 3.1:**
  Un valor de drift de `500.000` PPM representa el límite máximo absoluto de ajuste de frecuencia soportado por la arquitectura phase-locked loop (PLL) / frequency-locked loop (FLL) del kernel de NTP ($500\text{ PPM} = 0.05\%$). Si el reloj de hardware experimenta un drift más rápido que 500 PPM, el `ntpd` estándar no puede aplicar slew al reloj lo suficientemente rápido para mantener la sincronización. El daemon registrará un error en el log y se dará por terminado (abort) para evitar mantener un System Clock inestable o impredecible.

* **Respuesta 3.2:**
  Las directivas `constraint` de OpenNTPD consultan servidores web HTTPS autenticados sobre TLS (por ejemplo, `https://www.cloudflare.com`) para extraer cabeceras de respuesta HTTP `Date:` válidas. Dado que las conexiones TLS utilizan validación de certificados X.509, un atacante que realice suplantación de paquetes UDP de NTP o ataques Man-In-The-Middle no puede falsificar la ventana de tiempo del constraint autenticado por TLS. OpenNTPD valida que los timestamps del servidor NTP se encuentren dentro de un delta razonable respecto al tiempo del constraint HTTPS; si un paquete NTP no autenticado intenta aplicar step al System Clock dejándolo muy fuera de la ventana del constraint HTTPS, se descarta como malicioso.

</details>