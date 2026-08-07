# LPI-702 (Exam 702-100) — Tema 713.3: Mantener la hora del sistema

**Peso:** 1.67  
**Audiencia objetivo:** Arquitectos principales de plataformas, SREs líderes, Ingenieros de sistemas  
**Alcance:** Arquitectura de la hora del sistema en sistemas operativos BSD (FreeBSD, OpenBSD, NetBSD), Demonios NTP, Gestión de RTC e Ingeniería de diagnóstico.

---

## 1. Motivación y problema arquitectónico en producción

### 1.1 La física del seguimiento del tiempo en sistemas distribuidos

En la infraestructura de producción, la hora del sistema no es un campo de metadatos arbitrario; es una primitiva fundamental para la consistencia, la seguridad y el orden de los eventos. Los relojes de tiempo real (RTC) físicos en las placas base de los servidores dependen de osciladores de cristal de cuarzo. Debido a variaciones de fabricación, fluctuaciones de temperatura y el envejecimiento de los componentes, los cristales de cuarzo sufren un desvío (drift) natural a tasas de entre **10 a 50 partes por millón (ppm)**. Un desvío de $30\text{ ppm}$ se traduce en una desincronización de reloj (clock skew) de aproximadamente **2.6 segundos por día** ($2.592\text{ s/day}$).

En entornos virtualizados (por ejemplo, FreeBSD ejecutándose bajo `bhyve`, KVM o AWS EC2), el desvío de reloj se amplifica aún más. La sobreasignación (overcommit) de CPU del hipervisor, las interrupciones (preemptions) de vCPU y las migraciones en vivo provocan la pérdida de ticks de interrupción de hardware, lo que resulta en un desvío de reloj no lineal severo si no se compensa.

```
+-----------------------------------------------------------------------+
|                         Physical Hardware (RTC)                       |
|   Quartz Oscillator Drift: 10 - 50 ppm (~0.8 - 4.3 seconds/day drift)   |
+-----------------------------------------------------------------------+
                                   |
                                   v
+-----------------------------------------------------------------------+
|                    BSD Kernel Timecounter Subsystem                   |
|   Selects hardware source: TSC, HPET, ACPI-fast, i8254, LAPIC         |
|   Exposes: sysctl kern.timecounter.hardware                           |
+-----------------------------------------------------------------------+
                                   |
                                   v
+-----------------------------------------------------------------------+
|                     System Clock Discipline Loop                      |
|                                                                       |
|   Step Adjustment (Discontinuous)       Slew Adjustment (Continuous)  |
|   clock_settime(2) / settimeofday(2)    adjtime(2) / ntp_adjtime(2)   |
|   Target: Initial boot sync             Target: Continuous steady-state|
+-----------------------------------------------------------------------+
                                   |
                 +-----------------+-----------------+
                 |                                   |
                 v                                   v
+---------------------------------+ +----------------------------------+
|      Network Time Protocol      | |        Constraint Engine         |
|   NTP Client/Daemon (ntpd/chrony) | |   OpenNTPD HTTPS Constraints     |
|   UDP Port 123 (RFC 5905)       | |   TCP Port 443 (TLS Timestamp)   |
+---------------------------------+ +----------------------------------+
```

### 1.2 Fallos en producción causados por el desvío de reloj

El desvío de reloj compromete los sistemas distribuidos a través de cuatro dominios principales:

1. **Consenso distribuido y motores de almacenamiento**:
   - **Concesiones de líder (Leader Leases) en Raft / Paxos**: Los clústeres de bases de datos (por ejemplo, CockroachDB, Consul, Etcd) dependen de un desvío de reloj acotado para validar las concesiones de líder. Un desvío de reloj que supere los límites de la concesión desencadena escenarios de split-brain o lecturas obsoletas (stale reads).
   - **Conflictos de escritura en Cassandra / ScyllaDB**: Cassandra utiliza marcas de tiempo (timestamps) en microsegundos del lado del cliente o del servidor para la resolución de conflictos Last-Write-Wins (LWW). El desvío de reloj entre nodos provoca que las actualizaciones de datos más recientes se descarten silenciosamente como mutaciones "más antiguas".
2. **Autenticación y protocolos criptográficos**:
   - **Kerberos y Active Directory**: La autenticación Kerberos rechaza las autenticaciones si el desfase (offset) de reloj entre cliente y servidor supera los $300\text{ segundos}$ (`KRB_AP_ERR_SKEW`).
   - **Validación de certificados TLS**: Si la hora del sistema se desvía por detrás del límite `notBefore` o por delante del límite `notAfter` de un certificado, los handshakes de TLS fallan a través de las mallas de servicios (service meshes) internas.
   - **Tokens TOTP / OAuth2 / OIDC**: La autenticación de dos factores (TOTP) y las aserciones sujetas a tiempo de JWT (`iat`, `exp`, `nbf`) invalidan sesiones de usuario válidas durante picos de desfase.
3. **Observabilidad y telemetría**:
   - Las plataformas de agregación de logs (Elasticsearch, ClickHouse, Grafana Loki) ordenan los logs según las marcas de tiempo entrantes o registradas. Los relojes no sincronizados resultan en trazas de pila (stack traces) invertidas y falsas anomalías métricas en el rastreo distribuido (OpenTelemetry).
4. **Cumplimiento normativo**:
   - Estándares regulatorios como **MiFID II RTS 25** imponen tolerancias de sincronización sub-milisegundo a $100\text{ microsegundos}$ respecto a UTC para servidores de ejecución de transacciones financieras.

---

## 2. Comparativas técnicas y compensaciones

### 2.1 Arquitecturas de demonios de tiempo: `ntpd` de referencia vs OpenNTPD vs Chrony

Diferentes sistemas operativos BSD incluyen o soportan diferentes implementaciones de NTP según la filosofía de seguridad y los requisitos de rendimiento.

| Característica / Métrica | NTP de referencia (`ntpd`) | OpenNTPD (`openntpd`) | Chrony (`chronyd`) |
| :--- | :--- | :--- | :--- |
| **Mantenedor principal** | Network Time Foundation / ISC | Proyecto OpenBSD | Red Hat / Comunidad |
| **SO BSD predeterminado** | FreeBSD, NetBSD | OpenBSD | Paquete de terceros (`ports`/`pkg`) |
| **Modelo de seguridad** | Proceso único (históricamente vulnerable) | Separación estricta de privilegios, `chroot`, `pledge`, `unveil` | Separación de privilegios, abandono de usuario root |
| **Sincronización de restricción HTTPS** | No | Sí (`constraint from` sobre TLS) | No (Requiere helper externo) |
| **Manejo de red intermitente** | Deficiente (Asume conectividad continua) | Aceptable | Superior (Algoritmos de sondeo agresivos) |
| **Adaptación a máquinas virtuales** | Convergencia lenta ante detención de vCPU | Moderada | Superior (Compensación dinámica del desvío de frecuencia) |
| **Precisión / Tolerancia a Jitter** | Nivel de microsegundos (estado estable) | Nivel de milisegundos | Nivel sub-microsegundo |
| **Marcado de tiempo por hardware** | Soportado | No soportado | Soportado |
| **Huella de memoria** | ~8 MB | ~2 MB | ~4 MB |

### 2.2 Estrategias de ajuste de reloj: Step vs Slew

El bucle disciplinado de reloj del kernel modifica la hora del sistema utilizando dos técnicas distintas:

```
Step Adjustment (Discontinuous Jump)
Time ^
     |            / (New System Time)
     |           /
     |          |  <- Time skipped forward or backward instantly
     |         /
     |______-- (Old System Time)
     +-----------------------------------> Real Time

Slew Adjustment (Continuous Frequency Modification)
Time ^
     |               / (Accelerated clock gradually catches up)
     |              /  (Maximum rate: 500 ppm or 0.5 ms/s skew correction)
     |          _.-'
     |     _.-'
     |____--
     +-----------------------------------> Real Time
```

| Dimensión | Ajuste por salto / Step (`clock_settime`, `settimeofday`) | Ajuste gradual / Slew (`adjtime`, `ntp_adjtime`) |
| :--- | :--- | :--- |
| **Primitiva del kernel** | Establece directamente las estructuras internas `timeval` / `timespec`. | Altera gradualmente la tasa de incremento de ticks del kernel. |
| **Monotonicidad** | **Violada**. La hora del sistema puede saltar hacia atrás o hacia adelante de forma instantánea. | **Preservada**. El tiempo avanza strictly hacia adelante sin saltos hacia atrás. |
| **Tasa de corrección** | Instantánea. | Limitada por el tope del kernel (típicamente 500 ppm, o $0.5\text{ ms}$ por segundo). |
| **Umbral predeterminado** | Se aplica si el desfase del reloj es $> 128\text{ ms}$ (o $> 1000\text{ s}$ para pánico). | Se aplica cuando el desfase del reloj es $< 128\text{ ms}$. |
| **Riesgo para las aplicaciones** | Alto riesgo de romper temporizadores (`select`, `poll`), tareas de cron y transacciones de bases de datos. | Cero riesgo para la lógica de ejecución de aplicaciones ordenada por tiempo. |

---

## 3. Archivos completos de configuración para producción

### 3.1 Configuración de `ntpd` de referencia en FreeBSD (`/etc/ntp.conf`)

Esta configuración aplica reglas estrictas de control de acceso (ACL), configura pools seguros de Stratum 1/2, establece un driftfile local para preservar la disciplina de frecuencia a través de reinicios y configura el manejo de segundos interpolares (leap seconds).

```ini
# /etc/ntp.conf - FreeBSD Production Reference NTPD Configuration

# Set default access policy: deny all incoming queries, modifications, and peering
restrict default kod nomodify nopeer noquery limited notrap
restrict -6 default kod nomodify nopeer noquery limited notrap

# Allow full management access from local loopback interfaces
restrict 127.0.0.1
restrict ::1

# Allow NTP synchronization queries from local management subnet (10.0.100.0/24)
restrict 10.0.100.0 mask 255.255.255.0 nomodify nopeer

# Upstream NTP Servers and Pools (Vendor & Public Stratum 1/2)
server 0.freebsd.pool.ntp.org iburst maxpoll 9
server 1.freebsd.pool.ntp.org iburst maxpoll 9
server 2.freebsd.pool.ntp.org iburst maxpoll 9
server 3.freebsd.pool.ntp.org iburst maxpoll 9

# Upstream Stratum 1 Reference Clocks (Example: Enterprise Local Time Servers)
server 10.0.0.51 iburst prefer
server 10.0.0.52 iburst

# Driftfile to record the frequency error of the local system clock oscillator
driftfile /var/db/ntp/ntp.drift

# Path to the IANA Leap Second definition file
leapfile "/etc/ntp/leap-seconds"

# Enable logging of NTP statistics
statsdir /var/log/ntpstats/
statistics loopstats peerstats clockstats
filegen loopstats file loopstats type day enable
filegen peerstats file peerstats type day enable
filegen clockstats file clockstats type day enable

# Fallback local clock (Undisciplined Local Clock) - Disabled in production to prevent fake Stratum 10 propagation
# server 127.127.1.0 fudge 127.127.1.0 stratum 10
```

---

### 3.2 Configuración del demonio en OpenBSD (`/etc/ntpd.conf`)

El `ntpd` de OpenBSD combina la sincronización NTP con restricciones TLS para mitigar ataques de suplantación de tiempo (time spoofing) mediante man-in-the-middle.

```ini
# /etc/ntpd.conf - OpenBSD Production NTPD Configuration

# Listen on internal network interface for downstream clients
listen on 10.0.100.1

# Listen on loopback
listen on 127.0.0.1

# Query NTP Pool servers using iburst behavior
servers pool.ntp.org

# Specific high-reliability NTP upstream servers
server time1.google.com
server time2.google.com

# HTTPS Constraints: Query secure HTTPS servers to enforce sanity boundaries on NTP responses
# Prevents attacker on local network from sending malicious NTP offsets far into past/future
constraint from "www.google.com"
constraint from "cloudflare.com"
constraints from "https://www.openbsd.org"
```

---

### 3.3 Configuración de inicialización del sistema en FreeBSD (`/etc/rc.conf`)

Esta configuración garantiza la persistencia del demonio a través de reinicios del sistema, impone un ajuste inicial por salto (stepping) en el arranque antes del inicio de los servicios y configura el mapeo del reloj de tiempo real (RTC) del CMOS.

```sh
# /etc/rc.conf - System Time and Service Configuration

# Hostname identification
hostname="bsd-node-01.prod.infrastructure.internal"

# Enable ntpd service on system boot
ntpd_enable="YES"

# Pass flags to ntpd: -g allows ntpd to step the clock once regardless of offset on boot
ntpd_flags="-g -c /etc/ntp.conf -p /var/run/ntpd.pid"

# Synchronize system clock prior to launching dependent network daemons
ntpd_sync_on_start="YES"

# Enable automatic adjustment of CMOS clock (Hardware RTC) relative to kernel local time
adjkerntz_enable="YES"

# Set timezone configuration file path
# Linked binary zone file resides at /etc/localtime (copied from /usr/share/zoneinfo/UTC)
```

---

### 3.4 Configuración de Chrony (`/etc/chrony.conf`)

Para instancias FreeBSD o BSD desplegadas en entornos cloud (por ejemplo, AWS EC2, Azure) donde el desvío de reloj es volátil.

```ini
# /etc/chrony.conf - FreeBSD Chrony Production Configuration

# Specify NTP servers with rapid initial sampling (iburst)
pool 0.freebsd.pool.ntp.org iburst maxpoll 8
pool 1.freebsd.pool.ntp.org iburst maxpoll 8
server 169.254.169.123 prefer iburst  # AWS Link-Local Time Source

# Allow chrony to step the clock in the first 3 updates if offset is larger than 1 second
makestep 1.0 3

# File storing clock frequency drift
driftfile /var/db/chrony/drift

# Enable kernel synchronization of the real-time clock (RTC)
rtcsync

# Log directory for tracking measurements
logdir /var/log/chrony
log measurements statistics tracking

# Access control rules for local network clients
allow 10.0.100.0/24
deny all
```

---

## 4. Comandos reales de CLI y salidas operativas

### 4.1 Inspección y selección del timecounter del sistema (`sysctl`)

Los kernels BSD abstraen el hardware de temporización utilizando el framework `timecounter`. Para inspeccionar el hardware de seguimiento de tiempo disponible y las opciones de resolución activas:

```console
$ sysctl kern.timecounter
kern.timecounter.tc.i8254.mask: 65535
kern.timecounter.tc.i8254.counter: 12480
kern.timecounter.tc.i8254.frequency: 1193182
kern.timecounter.tc.i8254.quality: 0
kern.timecounter.tc.ACPI-fast.mask: 16777215
kern.timecounter.tc.ACPI-fast.counter: 12458902
kern.timecounter.tc.ACPI-fast.frequency: 3579545
kern.timecounter.tc.ACPI-fast.quality: 900
kern.timecounter.tc.HPET.mask: 4294967295
kern.timecounter.tc.HPET.counter: 394019284
kern.timecounter.tc.HPET.frequency: 14318180
kern.timecounter.tc.HPET.quality: 950
kern.timecounter.tc.TSC-low.mask: 4294967295
kern.timecounter.tc.TSC-low.counter: 2840194810
kern.timecounter.tc.TSC-low.frequency: 2399998120
kern.timecounter.tc.TSC-low.quality: 1000
kern.timecounter.stepwarnings: 1
kern.timecounter.hardware: TSC-low
kern.timecounter.choice: i8254(0) ACPI-fast(900) HPET(950) TSC-low(1000)
kern.timecounter.invariant_tsc: 1
```

Para cambiar dinámicamente la fuente de hardware del timecounter del kernel (por ejemplo, si ocurre un desvío de TSC bajo la limitación de CPU del hipervisor):

```console
$ sudo sysctl kern.timecounter.hardware=HPET
kern.timecounter.hardware: TSC-low -> HPET
```

---

### 4.2 Configuración y mantenimiento de husos horarios (`tzsetup`, `zic`, `date`)

Mostrar la hora local actual, la hora UTC y la configuración actual del huso horario (timezone):

```console
$ date
Thu Aug  6 20:45:12 UTC 2026

$ date -u
Thu Aug  6 20:45:12 UTC 2026
```

Configurar la zona horaria del sistema de forma interactiva o no interactiva en FreeBSD:

```console
$ sudo tzsetup -s UTC
```

Verificar que `/etc/localtime` apunta o coincide con el archivo binario de zona de destino:

```console
$ ls -l /etc/localtime
-r--r--r--  1 root  wheel  3519 Aug  6 20:00 /etc/localtime

$ md5 /etc/localtime /usr/share/zoneinfo/UTC
MD5 (/etc/localtime) = c61e479a3219aa276a666e138a0f5dfb
MD5 (/usr/share/zoneinfo/UTC) = c61e479a3219aa276a666e138a0f5dfb
```

Compilar un archivo de zona horaria personalizado usando `zic` (Zone Information Compiler):

```console
$ cat << 'EOF' > custom_zone.zic
Zone Custom/Production_UTC 0 - UTC
EOF
$ sudo zic custom_zone.zic
$ ls -l /usr/share/zoneinfo/Custom/Production_UTC
-rw-r--r--  1 root  wheel  56 Aug  6 20:46 /usr/share/zoneinfo/Custom/Production_UTC
```

---

### 4.3 Monitoreo del demonio NTP de referencia (`ntpq`)

Consultar los pares (peers) activos, los desfases (offsets), el jitter y el estado de stratum desde el `ntpd` de referencia:

```console
$ ntpq -p
     remote           refid      st t when poll reach   delay   offset  jitter
==============================================================================
*time1.google.co .GOOG.           1 u   42   64  377    8.214   -0.042   0.018
+time2.google.co .GOOG.           1 u   38   64  377    8.431    0.112   0.024
+203.0.113.80    198.51.100.1     2 u   12   64  377   24.810   -0.315   0.104
 192.0.2.10      .INIT.          16 u    - 1024    0    0.000    0.000   0.000
```

**Explicación de los campos clave**:
- `*`: Par (peer) de sistema activo seleccionado para la sincronización.
- `+`: Par candidato incluido en el algoritmo de clustering.
- `-`: Par descartado (outlier) por el algoritmo de intersección.
- `st`: Nivel de Stratum ($1 = \text{Estándar primario Atómico/GPS}$, $2 = \text{Sincronizado por red}$).
- `reach`: Registro de desplazamiento octal de 8 bits que rastrea la alcanzabilidad (377 = las últimas 8 consultas consecutivas tuvieron éxito).
- `offset`: Diferencia de tiempo entre el reloj local y el reloj del par en milisegundos.
- `jitter`: Medida de dispersión de la varianza del offset entre consultas en milisegundos.

Consultar las variables del sistema y el estado del bucle de disciplina (`ntpq -crv`):

```console
$ ntpq -crv
associd=0 status=0615 leap_none, sync_ntp, 1 filter, 5 events, clock_sync,
version="ntpd 4.2.8p15@1.3728-o Mon May 10 14:20:00 UTC 2021 (1)",
processor="amd64", system="FreeBSD/14.0-RELEASE", leap=00, stratum=2,
precision=-23, rootdelay=8.214, rootdisp=10.412, refid=216.239.35.0,
reftime=eb491a21.7391a2b0  Thu, Aug  6 20:47:13 2026,
clock=eb491a35.81b28912  Thu, Aug  6 20:47:33 2026, peer=42801, tc=6,
mintc=3, offset=-0.042104, frequency=-12.481, sys_jitter=0.018412,
clk_jitter=0.003912, clk_wander=0.001
```

---

### 4.4 Monitoreo de OpenBSD `ntpctl`

Inspeccionar el estado de sincronización de la hora del sistema bajo OpenBSD OpenNTPD:

```console
$ ntpctl -s status
1/1 peers synced, valid constraint, clock is synced

$ ntpctl -s all
1/1 peers synced, valid constraint, clock is synced

peer
   status sent received have wt poll  delay offset jitter
216.239.35.0 time1.google.com
   synced   12       12    8  1   15  8.192ms -0.038ms 0.015ms

constraint
   status  received  offset
172.217.16.206 www.google.com
   valid   2026-08-06 20:48:02 -0.120ms
```

---

### 4.5 Monitoreo de Chrony (`chronyc`)

Comprobar los parámetros operativos de rastreo (tracking) mediante `chronyc`:

```console
$ chronyc tracking
Reference ID    : A0000001 (time1.google.com)
Stratum         : 2
Ref time (UTC)  : Thu Aug 06 20:48:45 2026
System time     : 0.000000012 seconds slow of NTP time
Last offset     : -0.000000008 seconds
RMS offset      : 0.000000035 seconds
Frequency       : 12.481 ppm slow
Residual freq   : -0.001 ppm
Skew            : 0.012 ppm
Root delay      : 0.008214000 seconds
Root dispersion : 0.000120000 seconds
Update interval : 64.2 seconds
Leap status     : Normal
```

Inspeccionar las fuentes de tiempo activas y sus propiedades estadísticas (`chronyc sources`, `chronyc sourcestats`):

```console
$ chronyc sources -v
  .-- Source mode  '^' = server, '=' = peer, '#' = local clock.
 / .- Mode '+' = combined, '*' = chosen, '-' = dropped, 'x' = combined error.
| /   .- State 'S' = Sync'd, 'M' = Master, '?' = unreachable.
| |  /      .- Stratum
| | |      /  .- Poll interval (log2)
| | |     |  /  .- Reachability bitmask (octal)
| | |     | |  /         .- Last sample offset & delay
| | |     | | |         /
MS Name/IP address         Stratum Poll Reach LastRx Last sample               
===============================================================================
^* time1.google.com              1    6   377    14   -42us[  -50us] +/- 4100us
^+ time2.google.com              1    6   377    12  +112us[ +104us] +/- 4200us
```

---

### 4.6 Sincronización del reloj de tiempo real CMOS (`adjkerntz`)

En FreeBSD, el reloj de tiempo real (RTC) por hardware CMOS se puede configurar para ejecutarse en UTC o hora local (necesario en hardware heredado con arranque dual). La utilidad `adjkerntz` sincroniza el desfase (offset) del reloj CMOS almacenado en la memoria del kernel.

Comprobar y ajustar el desfase del reloj CMOS desde la CLI:

```console
$ sudo adjkerntz -a
```

Para configurar la variable de entorno del kernel que indica si el RTC está ajustado a la hora local o a UTC:

```console
$ sysctl machdep.adjkerntz
machdep.adjkerntz: 0
```

Si `machdep.adjkerntz` es `0`, el RTC CMOS de hardware se está ejecutando en UTC. Si no es cero, refleja el desfase del reloj en segundos con respecto a la hora local.

---

## 5. Guía de verificación y diagnóstico de fallos

### 5.1 Árbol de decisión SRE / Flujo de solución de problemas (Troubleshooting)

```
[System Time Incident Detected]
               |
               v
    Is daemon (ntpd/chronyd) running?
         /           \
       NO             YES
       /               \
Start Daemon         Is "ntpq -p" reach == 0?
Verify /etc/rc.conf    /           \
                      YES           NO
                      /               \
       Check Firewall UDP 123     Check Offset / Jitter Magnitude
       Check DNS resolution         /               \
       Check Routing             Offset > 1000s   Offset < 128ms
                                   /                 \
                          Daemon Panicked       Normal Slew Loop
                          Run manual step       Check Timecounter
                          ntpdate / ntpd -g     sysctl kern.timecounter
```

---

### 5.2 Escenarios de fallos críticos y remediaciones

#### Escenario A: Salida por pánico de `ntpd` ante un gran desfase (`time-step limit exceeded`)
* **Síntoma**: `ntpd` se cierra inmediatamente al iniciar o durante el funcionamiento con el error de log: `ntpd[12345]: 0.0.0.0 0618 08 step-mad exit: offset > 1000 s`.
* **Causa raíz**: El reloj del sistema se ha desviado más allá del umbral de pánico predeterminado de 1000 segundos. `ntpd` se niega a ajustar por salto (step) el reloj por defecto por razones de seguridad.
* **Remediación**:
  1. Forzar una sincronización manual por salto único usando `sntp` o `ntpd`:
     ```console
     $ sudo service ntpd stop
     $ sudo ntpd -gq
     ntpd: time set +1420.128491s
     $ sudo service ntpd start
     ```
  2. Asegurarse de que `/etc/rc.conf` contenga `ntpd_flags="-g"` y `ntpd_sync_on_start="YES"`.

#### Escenario B: Alto jitter y latencia de red asimétrica
* **Síntoma**: `ntpq -p` muestra un jitter elevado ($> 100\text{ ms}$) y una conmutación frecuente de pares primarios (`*` cambiando rápidamente).
* **Causa raíz**: Rutas de red asimétricas, bufferbloat o problemas de priorización de paquetes en el puerto UDP 123 en interfaces WAN.
* **Remediación**:
  1. Capturar tráfico NTP sin procesar usando `tcpdump` para verificar la asimetría del tiempo de ida y vuelta (round-trip):
     ```console
     $ sudo tcpdump -n -v -i vtnet0 udp port 123
     20:50:10.102934 IP (tos 0x0, ttl 64, id 41201, offset 0, flags [DF], proto UDP (17), length 76)
         10.0.100.1.123 > 216.239.35.0.123: NTPv4, Client, length 48
     20:50:10.312948 IP (tos 0x0, ttl 58, id 19284, offset 0, flags [DF], proto UDP (17), length 76)
         216.239.35.0.123 > 10.0.100.1.123: NTPv4, Server, length 48
     ```
  2. Implementar dispositivos NTP Stratum 2 locales dentro del perímetro de seguridad empresarial para evitar el jitter del enrutamiento por Internet pública.

#### Escenario C: Desvío severo del reloj de VM bajo virtualización
* **Síntoma**: El SO invitado (guest OS) FreeBSD dentro de `bhyve` o KVM pierde segundos por minuto. `sysctl kern.timecounter.hardware` informa `TSC-low` o `i8254`.
* **Causa raíz**: La lectura del TSC del SO invitado no es invariante a través de los eventos de planificación de CPU del hipervisor.
* **Remediación**:
  1. Inspeccionar los contadores disponibles mediante `sysctl kern.timecounter.choice`.
  2. Forzar al kernel a utilizar el timecounter HPET o ACPI-fast:
     ```console
     $ sudo sysctl kern.timecounter.hardware=HPET
     ```
  3. Hacer que la configuración sea persistente en `/etc/sysctl.conf`:
     ```ini
     # /etc/sysctl.conf
     kern.timecounter.hardware=HPET
     ```

#### Escenario D: Desvío de RTC y desalineación de zona horaria tras los reinicios
* **Síntoma**: La hora del sistema se desplaza $+5$ o $-5$ horas (o el desfase UTC local) inmediatamente después de reiniciar.
* **Causa raíz**: Conflictos entre la representación del reloj de hardware CMOS (Local vs UTC) y el `/etc/localtime` del sistema.
* **Remediación**:
  1. Si el CMOS funciona en UTC (recomendado para servidores de producción), verificar que `/etc/wall_cmos_clock` **NO** exista:
     ```console
     $ ls -l /etc/wall_cmos_clock
     ls: /etc/wall_cmos_clock: No such file or directory
     ```
  2. Si el CMOS debe ejecutarse en hora local, crear `/etc/wall_cmos_clock` y ejecutar `adjkerntz -a`:
     ```console
     $ sudo touch /etc/wall_cmos_clock
     $ sudo adjkerntz -a
     ```

---

## 6. Referencias

- **Descripción general de la certificación LPI BSD Specialist**:  
  https://www.lpi.org/our-certifications/bsd-specialist-overview/
- **Manual de FreeBSD — Protocolo de tiempo de red (NTP)**:  
  https://docs.freebsd.org/en/books/handbook/network-servers/#network-ntp
- **Páginas del manual de OpenBSD — `ntpd.conf(5)`**:  
  https://man.openbsd.org/ntpd.conf.5
- **Páginas del manual de OpenBSD — `ntpctl(8)`**:  
  https://man.openbsd.org/ntpctl.8
- **RFC 5905 — Protocolo de tiempo de red versión 4: Especificación de protocolo y algoritmos**:  
  https://datatracker.ietf.org/doc/html/rfc5905
- **Base de datos de husos horarios de la IANA**:  
  https://www.iana.org/time-zones