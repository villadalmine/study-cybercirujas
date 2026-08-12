# Tema 364.1 — Alta disponibilidad de hardware y recursos

**LPIC-3 306 (examen 306-300, v3.0) · Tema 364: Alta disponibilidad en un solo nodo · Peso: 3.33**

---

## 1. El problema arquitectónico: el nodo bajo el clúster sigue siendo un SPOF

Cada patrón de diseño de los objetivos anteriores — clústeres de conmutación por error Pacemaker/Corosync (361.3), balanceo de carga LVS/HAProxy (361.2), DRBD y almacenamiento de disco compartido (362) — descansa sobre la suposición de que los nodos individuales **fallan de forma limpia y observable**. La realidad en producción es la opuesta. Los modos de fallo que destruyen un clúster de HA son precisamente los que ocurren *dentro de un solo nodo y son invisibles para la pila del clúster*:

- **Un kernel atascado que no libera sus recursos.** Corosync pierde el token, la partición sobreviviente intenta hacerse con la VIP y el rol primario de DRBD — pero el nodo "muerto" no está muerto, su NIC simplemente está hambrienta. Este es el generador clásico de split-brain. El fencing a nivel de clúster (STONITH) existe para resolver esto, pero STONITH necesita una ruta *fuera de banda* (IPMI) y un *mecanismo de auto-fencing de respaldo* (un watchdog de hardware + SBD) para el caso en que la ruta de red al BMC también haya desaparecido.
- **Degradación silenciosa del medio.** Un disco acumula sectores reasignados y pendientes durante semanas. En un volumen replicado con DRBD, la lectura de un sector pendiente devuelve un error de lectura que se propaga como corrupción de datos a los consumidores de *ambas* réplicas, o fuerza una tormenta de resincronización. El fallo era predecible con días de antelación a partir de la telemetría S.M.A.R.T. que nadie estaba recopilando.
- **Un fallo parcial de hardware** — una PSU averiada en un chasis de doble PSU, un ventilador a 0 RPM, errores corregibles de ECC escalando hacia incorregibles, una temperatura de entrada por encima del umbral de throttle. Ninguno de estos aparece en `top`, `dmesg` (hasta que es demasiado tarde) ni en los monitores de recursos del clúster. Viven en el repositorio de datos de sensores y el registro de eventos del BMC.

**La HA de un solo nodo es el sustrato que hace confiable a la HA multinodo.** Los tres pilares de este objetivo se corresponden directamente con tres preguntas que un SRE debe poder responder para cada nodo:

| Pilar | Pregunta que responde | Fallo que previene | Herramientas principales |
|---|---|---|---|
| **Monitorización S.M.A.R.T.** | *¿Este disco fallará pronto?* | Pérdida de datos / tormentas de resincronización por deterioro silencioso del medio | `smartctl`, `smartd` |
| **Watchdog de hardware** | *Si el kernel se cuelga, ¿el nodo se reiniciará a sí mismo de forma fiable?* | Split-brain de un nodo "medio muerto" que STONITH no puede alcanzar | `/dev/watchdog`, systemd, `watchdog`d, SBD |
| **IPMI / BMC** | *¿Puedo ver y controlar este nodo cuando el SO es inalcanzable?* | Puntos ciegos + sin ruta de fencing / recuperación fuera de banda | `ipmitool`, `ipmievd`, `fence_ipmilan` |

El watchdog no es una comodidad de monitorización — en un clúster Pacemaker **es el mecanismo de fencing de último recurso**. SBD (Storage-Based Death) arma el watchdog de hardware y requiere que el nodo siga escribiendo un heartbeat en un dispositivo de bloque compartido; si el nodo pierde el quórum o no logra atender su watchdog, el temporizador expira y el hardware reinicia la máquina *sin ninguna cooperación del SO*. Ese es el único método de fencing que aún funciona cuando la red del BMC, el anillo de corosync y el SO son simultáneamente inalcanzables.

---

## 2. Pilar 1 — S.M.A.R.T. con smartmontools

### 2.1 Qué reporta realmente SMART, y por qué los valores normalizados engañan

Cada atributo SMART de ATA tiene un ID, un **VALUE normalizado** (definido por el fabricante, típicamente empieza en 100 o 253 y decae hacia un THRESH), un **WORST** (el valor normalizado más bajo jamás visto), un **THRESH** (umbral de fallo), un **TYPE** (`Pre-fail` = predice un fallo inminente; `Old_age` = desgaste), un flag **UPDATED** (`Always` u `Offline`), una columna **WHEN_FAILED** y un **RAW_VALUE**. La trampa para un SRE novato: el valor *normalizado* aún puede leer `100` mientras el valor *raw* está gritando. Lee siempre la columna raw de los atributos que importan.

**Los atributos que predicen el fallo** (los estudios de gran población de Backblaze y el proyecto smartmontools coinciden en estos cinco como los correlatos más fuertes):

| ID | Atributo | Qué significa un valor raw en aumento |
|---|---|---|
| 5 | `Reallocated_Sector_Ct` | Sectores remapeados al conjunto de reserva — el medio está fallando físicamente. |
| 187 | `Reported_Uncorrect` | Errores que el ECC no pudo corregir y reportó al host. |
| 188 | `Command_Timeout` | Comandos abortados — a menudo cableado/alimentación, a veces un disco muriendo. |
| 197 | `Current_Pending_Sector` | Sectores inestables a la espera de reasignación — **errores de lectura inminentes**. |
| 198 | `Offline_Uncorrectable` | Incorregibles durante el escaneo offline — datos ya ilegibles. |

Dos más que siempre vigilas: `199 UDMA_CRC_Error_Count` (un valor en aumento es casi siempre un problema de **cable/backplane**, no del plato) y `194 Temperature_Celsius`.

### 2.2 Leyendo el disco

```
$ sudo smartctl -H /dev/sda
smartctl 7.4 2023-08-01 r5530 [x86_64-linux-6.8.0-45-generic] (local build)
Copyright (C) 2002-23, Bruce Allen, Christian Franke, www.smartmontools.org

=== START OF READ SMART DATA SECTION ===
SMART overall-health self-assessment test result: PASSED
```

`PASSED` solo significa que ningún atributo `Pre-fail` ha cruzado su umbral **ahora mismo**. Es un indicador rezagado — un disco con 300 sectores pendientes y una cuenta de reasignación en aumento aún reportará `PASSED`. Lee los atributos:

```
$ sudo smartctl -A /dev/sda
smartctl 7.4 2023-08-01 r5530 [x86_64-linux-6.8.0-45-generic] (local build)

=== START OF READ SMART DATA SECTION ===
SMART Attributes Data Structure revision number: 16
Vendor Specific SMART Attributes with Thresholds:
ID# ATTRIBUTE_NAME          FLAG     VALUE WORST THRESH TYPE      UPDATED  WHEN_FAILED RAW_VALUE
  1 Raw_Read_Error_Rate     0x000f   118   099   006    Pre-fail  Always       -       182664048
  5 Reallocated_Sector_Ct   0x0033   100   100   010    Pre-fail  Always       -       0
  9 Power_On_Hours          0x0032   071   071   000    Old_age   Always       -       25703
 12 Power_Cycle_Count       0x0032   100   100   020    Old_age   Always       -       94
187 Reported_Uncorrect      0x0032   100   100   000    Old_age   Always       -       0
188 Command_Timeout         0x0032   100   100   000    Old_age   Always       -       0
190 Airflow_Temperature_Cel 0x0022   067   052   045    Old_age   Always       -       33 (Min/Max 24/40)
194 Temperature_Celsius     0x0022   033   048   000    Old_age   Always       -       33 (0 20 0 0 0)
197 Current_Pending_Sector  0x0012   100   100   000    Old_age   Always       -       0
198 Offline_Uncorrectable   0x0010   100   100   000    Old_age   Offline      -       0
199 UDMA_CRC_Error_Count    0x003e   200   200   000    Old_age   Always       -       0
```

Un disco **fallando**, en cambio, se ve así — observa los valores raw y el marcador `WHEN_FAILED`:

```
  5 Reallocated_Sector_Ct   0x0033   089   089   010    Pre-fail  Always       -       1104
187 Reported_Uncorrect      0x0032   001   001   000    Old_age   Always       -       214
197 Current_Pending_Sector  0x0012   100   100   000    Old_age   Always   In_the_past  48
198 Offline_Uncorrectable   0x0010   100   100   000    Old_age   Offline      -       21
```

1104 sectores reasignados, 214 incorregibles reportados, 48 sectores que estuvieron pendientes. Este disco debe reemplazarse ya; en un miembro de DRBD/RAID debería sacarse de servicio (fail out) de forma proactiva antes de que dispare una resincronización.

### 2.3 Autotests: tipos y compromisos

Los atributos son contadores pasivos. **Los autotests ejercitan activamente el medio.** Los disparas tú; el disco los ejecuta en segundo plano; lees el registro después.

| Test | Comando | Duración | Cobertura | Impacto en E/S |
|---|---|---|---|---|
| **Short** | `smartctl -t short` | ~1–2 min | Electrónico + mecánico + pequeño escaneo de lectura | Insignificante |
| **Long / extended** | `smartctl -t long` | Horas (escala con la capacidad) | Escaneo de lectura de superficie completa | Se ejecuta en segundo plano, baja prioridad |
| **Conveyance** | `smartctl -t conveyance` | ~5 min | Comprobaciones de daño en tránsito | Insignificante |
| **Offline (recolección de datos)** | `smartctl -t offline` | Minutos | Refresca los atributos `Offline` (p. ej. ID 198) | Insignificante |
| **SCT selective** | `smartctl -t select,0-max` | Variable | Prueba un rango de LBA específico | Depende del rango |

```
$ sudo smartctl -t long /dev/sda
smartctl 7.4 2023-08-01 r5530 [x86_64-linux-6.8.0-45-generic] (local build)

=== START OF OFFLINE IMMEDIATE AND SELF-TEST SECTION ===
Sending command: "Execute SMART Extended self-test routine immediately in off-line mode".
Drive command "Execute SMART Extended self-test routine immediately in off-line mode" successful.
Testing has begun.
Please wait 218 minutes for test to complete.
Test will complete after Sat Aug 12 07:38:11 2026 UTC

Use smartctl -X to abort test.
```

Consulta el progreso (no bloquea), luego lee el registro:

```
$ sudo smartctl -c /dev/sda | grep -A2 'Self-test execution'
Self-test execution status:      ( 249) Self-test routine in progress...
                                        90% of test remaining.

$ sudo smartctl -l selftest /dev/sda
=== START OF READ SMART DATA SECTION ===
SMART Self-test log structure revision number 1
Num  Test_Description    Status                  Remaining  LifeTime(hours)  LBA_of_first_error
# 1  Extended offline    Completed: read failure       10%     25698         1743826512
# 2  Short offline       Completed without error       00%     25690         -
# 3  Extended offline    Completed without error       00%     25012         -
```

`Completed: read failure` con un `LBA_of_first_error` es el veredicto inequívoco: este disco tiene un sector ilegible en el plato. En un miembro de RAID/DRBD, fuerza al array a reescribir ese LBA (una resincronización o `hdparm --write-sector`) o reemplaza el disco.

### 2.4 Dispositivos NVMe

NVMe usa una estructura de registro de salud diferente. `smartctl` la traduce; el nativo `nvme-cli` da la página de registro raw 0x02:

```
$ sudo smartctl -a /dev/nvme0
=== START OF SMART DATA SECTION ===
SMART overall-health self-assessment test result: PASSED

SMART/Health Information (NVMe Log 0x02)
Critical Warning:                   0x00
Temperature:                        41 Celsius
Available Spare:                    100%
Available Spare Threshold:          10%
Percentage Used:                    7%
Data Units Written:                 84,120,551 [43.0 TB]
Media and Data Integrity Errors:    0
Error Information Log Entries:      12
Warning  Comp. Temperature Time:    0
Critical Comp. Temperature Time:    0
```

Los dos campos NVMe que importan para la planificación de capacidad y las decisiones de fencing: **`Percentage Used`** (la estimación propia del disco sobre la resistencia consumida — un predictor de desgaste ausente en ATA) y **`Available Spare`** frente a su umbral (una vez que la reserva cae por debajo del umbral, se activa el bit 0 de `Critical Warning` y el disco está en fin de vida). Autotests NVMe: `nvme device-self-test /dev/nvme0 -s 1` (short) / `-s 2` (extended), se leen con `nvme self-test-log`.

### 2.5 Monitorización continua con `smartd`

El `smartctl` interactivo es para diagnóstico. La monitorización en producción es `smartd` (del mismo paquete `smartmontools`). Sondea según una programación, ejecuta autotests automáticamente y envía correos ante fallos. Este es el `/etc/smartd.conf` completo y sintácticamente válido que desplegarías en un nodo de clúster:

```conf
# /etc/smartd.conf — production cluster node
#
# Directive reference:
#   -a            monitor all attributes (equivalent to -H -f -t -l error -l selftest -C 197 -U 198)
#   -H            check SMART health status (PASS/FAIL)
#   -f            report failures of "Usage" (Old_age) attributes
#   -C ID         report if Current_Pending_Sector (197) raw != 0
#   -U ID         report if Offline_Uncorrectable (198) raw != 0
#   -l error      monitor ATA error log for new errors
#   -l selftest   monitor self-test log for new failures
#   -s REGEX      self-test schedule: T/MM/DD/DAY-OF-WEEK/HH  (T = L,S,C,O)
#   -W D,I,C      temperature: report on D-degree change; warn at I; critical at C
#   -m ADDR       email destination for warnings
#   -M exec PATH  run a custom handler instead of / in addition to mail
#   -n STANDBY    don't spin up a sleeping disk just to poll it
#   -o on/-S on   enable automatic offline data collection / attribute autosave

# Global defaults applied to every DEVICESCAN device:
#   short self-test every day at 02:00, long self-test every Saturday at 03:00
DEFAULT -a -o on -S on -n standby,q -W 4,45,55 -m root@localhost -M exec /usr/local/sbin/smartd-notify.sh

# Auto-detect all ATA/SCSI/NVMe devices and apply the DEFAULT directives above:
DEVICESCAN -s (S/../.././02|L/../../6/03)

# --- Or, pin devices explicitly (preferred on nodes where /dev/sdX can renumber) ---
# /dev/disk/by-id/ata-Samsung_SSD_870_EVO_2TB_S6PNNS0T  -a -s (S/../.././02|L/../../6/03) -W 4,50,60 -m sre-oncall@example.com
# /dev/disk/by-id/nvme-Samsung_SSD_990_PRO_2TB_S7D..... -a -s (L/../../7/04) -W 4,50,60 -m sre-oncall@example.com

# Devices behind a MegaRAID controller (LSI/Broadcom): iterate the backplane slots
# /dev/bus/0 -d megaraid,0 -a -s (S/../.././02|L/../../6/03) -m sre-oncall@example.com
# /dev/bus/0 -d megaraid,1 -a -s (S/../.././02|L/../../6/03) -m sre-oncall@example.com
```

**Decodificando el regex de programación `-s`** `(S/../.././02|L/../../6/03)`: los campos son `Tipo/Mes/DíaDelMes/DíaDeLaSemana/Hora`. `S/../.././02` = test **S**hort, cualquier mes, cualquier día del mes, cualquier día de la semana, a la hora **02**. `L/../../6/03` = test **L**ong, día de la semana **6** (sábado), a las **03**. Habilítalo y valídalo:

```
$ sudo systemctl enable --now smartd
$ sudo smartd -q onecheck        # parse config + run one check cycle, then exit
smartd 7.4 2023-08-01 r5530 [x86_64-linux-6.8.0-45-generic] (local build)
Opened configuration file /etc/smartd.conf
Configuration file /etc/smartd.conf parsed.
Device: /dev/sda, type changed from 'scsi' to 'sat'
Device: /dev/sda [SAT], opened
Device: /dev/sda [SAT], Samsung SSD 870 EVO 2TB, S/N:S6PNNS0T, WWN:5-002538-f31a1b2c3, FW:SVT02B6Q, 2.00 TB
Device: /dev/sda [SAT], is SMART capable. Adding to "monitor" list.
Monitoring 1 ATA/SATA, 0 SCSI/SAS and 0 NVMe/SMART devices
```

Envía una alerta de prueba de extremo a extremo (`-M test` dispara la ruta de correo/exec inmediatamente al arrancar, para que pruebes la cadena de notificación antes de un fallo real): añade `-M test` a una línea de dispositivo y reinicia, o ejecuta `smartctl -t short` y observa cómo el manejador se dispara al completarse.

---

## 3. Pilar 2 — El watchdog de hardware: auto-fencing determinista

### 3.1 El mecanismo

Un watchdog es un temporizador de cuenta atrás. El software abre `/dev/watchdog` (dispositivo de caracteres, major 10 minor 130), lo que **arma** el temporizador. Desde ese momento el software debe "acariciar"/"patear" (pet/kick) al watchdog (escribir cualquier byte, o emitir el ioctl `WDIOC_KEEPALIVE`) antes de que el temporizador expire. Si no lo hace — porque el kernel se colgó, un livelock dejó al daemon sin recursos, o el proceso murió — el temporizador llega a cero y el dispositivo **reinicia en caliente la máquina**. No hay apagado limpio, no hay fsync; ese es todo el propósito: un nodo colgado debe reiniciarse *sin necesitar que el software colgado coopere*.

Cerrar `/dev/watchdog` normalmente **desarma** el temporizador — a menos que se requiera el "magic close". Escribir el byte `V` antes de cerrar señala un desarme limpio e intencional. El comportamiento `nowayout` (configuración del kernel / parámetro del módulo) hace que el watchdog no se pueda desarmar una vez abierto: incluso cerrar el dispositivo mantiene el temporizador corriendo. **Para fencing quieres la semántica de `nowayout`** — un daemon que se cae y cierra su fd no debe desarmar silenciosamente la red de seguridad.

### 3.2 Hardware vs software vs las capas superiores

| Capa | Dispositivo / mecanismo | ¿Sobrevive a un kernel panic? | ¿Sobrevive a un SO completamente muerto? | Caso de uso |
|---|---|---|---|---|
| **Watchdog de hardware** | `iTCO_wdt`, `sp5100_tco`, `hpwdt`, `ipmi_watchdog` | **Sí** (silicio / BMC independiente) | **Sí** | Sustrato de fencing en producción |
| **softdog** | temporizador de software del kernel | Parcialmente (un panic puede congelar el contexto del propio temporizador) | No | Solo respaldo en dev/VM |
| **watchdog de systemd** | PID 1 abre `/dev/watchdog`, acaricia a ½ del intervalo | Sí (usa el dispositivo HW) | Sí | Auto-reinicio básico del nodo |
| **daemon `watchdog`** | userspace, abre `/dev/watchdog`, ejecuta comprobaciones de salud | Sí (usa el dispositivo HW) | Sí | Reinicio impulsado por condiciones de salud |
| **SBD** | watchdog + poison pill en disco compartido | Sí | Sí | STONITH de último recurso en Pacemaker |

**Advertencia sobre softdog que aparece en el examen y en la realidad:** como softdog es solo un temporizador del kernel, un bloqueo total del kernel que detenga la ruta de interrupción del temporizador puede impedir que dispare. Un watchdog de hardware real (iTCO en el PCH de Intel, sp5100 en AMD, o el watchdog IPMI del BMC) es silicio independiente y dispara sin importar qué. Prefiere hardware; usa softdog solo cuando no haya ningún watchdog de hardware expuesto (muchas VMs).

Identifica lo que tienes:

```
$ ls -l /dev/watchdog*
crw------- 1 root root 10, 130 Aug 12 03:11 /dev/watchdog
crw------- 1 root root 244,  0 Aug 12 03:11 /dev/watchdog0

$ sudo wdctl /dev/watchdog0
Device:        /dev/watchdog0
Identity:      iTCO_wdt [version 0]
Timeout:       30 seconds
Pre-timeout:    0 seconds
Timeleft:      28 seconds
FLAG           DESCRIPTION               STATUS BOOT-STATUS
KEEPALIVEPING  Keep alive ping reply          1           0
MAGICCLOSE     Supports magic close char      0           0
SETTIMEOUT     Set timeout (in seconds)       0           0

$ dmesg | grep -i -E 'watchdog|wdt'
[    3.882110] iTCO_wdt iTCO_wdt.1.auto: Found a Intel PCH TCO device (Version=6, TCOBASE=0x0400)
[    3.882471] iTCO_wdt iTCO_wdt.1.auto: initialized. heartbeat=30 sec (nowayout=0)
```

Si no existe ningún dispositivo de hardware, carga softdog explícitamente:

```
$ sudo modprobe softdog soft_margin=60 nowayout=1
$ dmesg | tail -2
[  512.774193] softdog: initialized. soft_noboot=0 soft_margin=60 sec soft_panic=0 (nowayout=1)
[  512.774196] softdog: soft_reboot_cmd=<not set> soft_active_on_boot=0
```

### 3.3 Opción A — el watchdog de systemd

La línea base de producción más simple: deja que PID 1 sea dueño del watchdog. systemd abre `/dev/watchdog`, lo arma con `RuntimeWatchdogSec` y lo acaricia a **la mitad** de ese intervalo. Configúralo en `/etc/systemd/system.conf` (o en un drop-in `/etc/systemd/system.conf.d/watchdog.conf`):

```ini
# /etc/systemd/system.conf.d/10-watchdog.conf
[Manager]
# Arm the hardware watchdog with a 30 s timeout; PID 1 pets it every 15 s.
# If systemd itself hangs, the board resets the node after 30 s.
RuntimeWatchdogSec=30

# On reboot/shutdown, re-arm the watchdog with this timeout so that a hang
# DURING shutdown (a stuck unmount, a wedged driver) still forces a reset.
# (Named ShutdownWatchdogSec before systemd v243; RebootWatchdogSec since.)
RebootWatchdogSec=10min

# Optionally pick a specific device when several exist:
WatchdogDevice=/dev/watchdog0

# Pre-timeout: fire a governor action (e.g. dump) before the hard reset.
RuntimeWatchdogPreSec=0
RuntimeWatchdogPreGovernor=none
```

Aplícalo y verifícalo (un cambio en `RuntimeWatchdogSec` surte efecto en un `daemon-reexec`, no en un simple reload):

```
$ sudo systemctl daemon-reexec
$ systemctl show --property=RuntimeWatchdogUSec --property=RebootWatchdogUSec
RuntimeWatchdogUSec=30s
RebootWatchdogUSec=10min

$ journalctl -b -u init.scope | grep -i watchdog
Aug 12 03:11:04 node1 systemd[1]: Watchdog running with a timeout of 30s.
```

**Conflicto importante:** solo un proceso puede mantener `/dev/watchdog`. Si systemd lo mantiene, el daemon `watchdog` independiente y SBD no pueden. En un nodo Pacemaker casi siempre quieres que **SBD** sea dueño del watchdog (§3.5), así que ahí dejas `RuntimeWatchdogSec=0`. En un nodo independiente, el watchdog de systemd es la opción correcta y sin daemon extra.

### 3.4 Opción B — el daemon `watchdog` (impulsado por condiciones de salud)

El watchdog de systemd solo demuestra que *systemd está planificando*. El daemon `watchdog` independiente (paquete `watchdog`) además **deja de acariciar el temporizador cuando falla una condición de salud** — carga alta, agotamiento de memoria, un proceso que no responde, un fichero de heartbeat obsoleto, una gateway que no responde al ping, un chasis sobrecalentado, o un binario de test personalizado que falla. Cuando deja de acariciar, el hardware reinicia el nodo. `wd_keepalive` es la variante reducida que solo hace ping (se usa durante el apagado para que el temporizador siga armado mientras se detiene el daemon completo).

`/etc/watchdog.conf` completo:

```conf
# /etc/watchdog.conf — health-driven hardware watchdog
# The daemon pings /dev/watchdog every `interval` seconds AS LONG AS every
# enabled test passes. Any failing test stops the ping -> board resets node.

watchdog-device = /dev/watchdog0
watchdog-timeout = 60          # board's hard-reset timeout (>= 2*interval)
interval        = 10           # how often the daemon runs tests + pings
logtick         = 6            # log every 6th tick to avoid log spam
realtime        = yes          # mlockall() so the daemon can't be swapped out
priority        = 1

# --- System resource guards ---
max-load-1  = 24               # reset if 1-min load avg exceeds this
max-load-5  = 18
max-load-15 = 12
min-memory  = 1                # reset if free pages (in pages) drop below this
allocatable-memory = 1

# --- Thermal guard (uses hwmon/ACPI thermal zone) ---
temperature-sensor = /sys/class/hwmon/hwmon0/temp1_input
max-temperature = 90           # in the unit the sensor reports (here: milli-°C? see note)

# --- Liveness of a critical file (e.g. app heartbeat updated by cron/app) ---
file = /run/myapp/heartbeat
change = 300                   # reset if that file is not modified within 300 s

# --- Network reachability of the default gateway / a peer ---
ping = 192.168.10.1
ping-count = 3

# --- PID liveness: reset if this process dies ---
pidfile = /run/corosync.pid

# --- Custom test/repair binaries in these dirs (exit non-zero = failure) ---
test-directory = /etc/watchdog.d
test-timeout = 30
repair-binary = /usr/sbin/repair.sh
repair-timeout = 60

# On a clean daemon stop, DISARM the watchdog (write magic 'V'). Set to 'no'
# to keep nowayout semantics even across a daemon restart.
watchdog-refresh-use-settimeout = yes
```

Habilítalo y confirma que se hizo con el dispositivo:

```
$ sudo systemctl enable --now watchdog
$ journalctl -u watchdog -b --no-pager | tail
Aug 12 03:20:01 node1 watchdog[2411]: watchdog now set to 60 seconds
Aug 12 03:20:01 node1 watchdog[2411]: hardware watchdog identity: iTCO_wdt
Aug 12 03:20:01 node1 watchdog[2411]: interface: eth0 monitored via ping 192.168.10.1
Aug 12 03:20:01 node1 watchdog[2411]: file /run/myapp/heartbeat: changed every 300 seconds
Aug 12 03:20:01 node1 watchdog[2411]: currently monitoring load average, temperature, ...
```

### 3.5 Opción C — SBD: el watchdog como dispositivo de fencing de Pacemaker

En un clúster Corosync/Pacemaker (Tema 361), SBD vincula el watchdog al estado del clúster. Cada nodo ejecuta `sbd`, que (a) escribe un heartbeat en un slot de uno o más **dispositivos de bloque compartidos** y lee en busca de mensajes de "poison pill", y (b) **alimenta el watchdog de hardware**. Si un nodo pierde el quórum, se le ordena auto-fencing vía el disco compartido, o su daemon `sbd` ya no puede confirmar que debe seguir vivo, `sbd` **deja de acariciar el watchdog** y la placa reinicia el nodo en `watchdog-timeout` segundos. Esto es fencing que *no* necesita un BMC alcanzable *ni* corosync — el reinicio lo impone el silicio.

`/etc/sysconfig/sbd`:

```sh
# /etc/sysconfig/sbd
# Shared block device(s) holding the SBD slots (up to 3 for redundancy).
# Use stable /dev/disk/by-id paths, NOT /dev/sdX.
SBD_DEVICE="/dev/disk/by-id/wwn-0x6001405abcdef01234567890abcdef01"

# The watchdog device SBD must feed. SBD REQUIRES a watchdog to be safe.
SBD_WATCHDOG_DEV="/dev/watchdog0"

# Watchdog timeout SBD asks the kernel to set (must be < msgwait; see below).
SBD_WATCHDOG_TIMEOUT="5"

# Behaviour when SBD fails to start: 'always' (only reboot on config error) or
# 'clean' (reboot only after a clean shutdown was requested). Keep default.
SBD_STARTMODE="always"

# Diskless SBD: leave SBD_DEVICE empty to fence purely on quorum loss +
# watchdog (no shared disk). Requires a real hardware watchdog on every node.
SBD_PACEMAKER="yes"
SBD_DELAY_START="no"
SBD_TIMEOUT_ACTION="flush,reboot"
```

Crea los metadatos de slot en el dispositivo compartido (los temporizadores watchdog/msgwait viven en la cabecera) e inspecciónalo:

```
$ sudo sbd -d /dev/disk/by-id/wwn-0x6001405abc...  -1 15 -4 30 create
Initializing device /dev/disk/by-id/wwn-0x6001405abc...
Creating version 2.1 header on device 3 (uuid: 7f0c...e2)
Initializing 255 slots on device 3
Device /dev/disk/by-id/wwn-0x6001405abc... is initialized.

$ sudo sbd -d /dev/disk/by-id/wwn-0x6001405abc... dump
==Dumping header on disk /dev/disk/by-id/wwn-0x6001405abc...
Header version     : 2.1
Number of slots    : 255
Sector size        : 512
Timeout (watchdog)  : 15
Timeout (allocate)  : 2
Timeout (loop)      : 1
Timeout (msgwait)   : 30
==Header on disk /dev/disk/by-id/wwn-0x6001405abc... is dumped
```

Registra SBD como dispositivo de fencing de Pacemaker (ver también `fence_ipmilan` en §4.5 — los clústeres de producción ejecutan **ambos**, IPMI como primario y SBD como respaldo de último recurso vía una `fencing-topology`):

```
$ sudo pcs stonith create fence-sbd fence_sbd \
        devices=/dev/disk/by-id/wwn-0x6001405abc... \
        pcmk_delay_max=10 \
        meta provides=unfencing

$ sudo pcs property set stonith-watchdog-timeout=10   # >= 2 * SBD_WATCHDOG_TIMEOUT
$ sudo pcs stonith status
  * fence-sbd    (stonith:fence_sbd):     Started node1
```

### 3.6 Demostrar que el watchdog realmente dispara

Nunca confíes en una red de seguridad no armada. El test destructivo canónico — **solo en un nodo de laboratorio** — fuerza un kernel panic y confirma que la placa reinicia dentro del timeout:

```
# Confirm what SHOULD happen, then trigger it:
$ sudo wdctl /dev/watchdog0 | grep Timeout
Timeout:       30 seconds

# Non-destructive first: verify systemd's petting keeps Timeleft topped up
$ for i in 1 2 3; do sudo wdctl /dev/watchdog0 | grep Timeleft; sleep 5; done
Timeleft:      27 seconds
Timeleft:      29 seconds
Timeleft:      28 seconds          # <- being reset ~every 15 s: petting works

# Destructive: hang the kernel. If the watchdog is real, the node hard-resets
# ~30 s later. If it does NOT reset, your fencing is a lie.
$ echo 1 | sudo tee /proc/sys/kernel/sysrq
$ echo c | sudo tee /proc/sysrq-trigger      # forces a kernel panic
```

Después de que la máquina vuelva, confirma que el reinicio fue de origen watchdog. Muchos drivers de watchdog activan un bit `BOOT-STATUS`, y el BMC lo registra en el SEL:

```
$ sudo wdctl /dev/watchdog0
...
FLAG           DESCRIPTION               STATUS BOOT-STATUS
CARDRESET      Card previously reset          0           1   # <- last boot was a WDT reset

$ sudo ipmitool sel elist | grep -i watchdog
  4 | 08/12/2026 | 03:41:22 UTC | Watchdog2 #0x71 | Hard reset | Asserted
```

---

## 4. Pilar 3 — IPMI / BMC: ojos y manos fuera de banda

### 4.1 Dónde se sitúa el BMC

El Baseboard Management Controller es un pequeño procesador independiente en la placa base con su propia NIC (o un puerto compartido/sideband), su propio dominio de alimentación y su propio firmware. Funciona esté el host encendido, apagado o colgado. IPMI es el protocolo para hablar con él. Dos planos de acceso:

| Acceso | Interfaz de ipmitool | Transporte | ¿Funciona con el SO del host muerto? | Nota de seguridad |
|---|---|---|---|---|
| **In-band** | `-I open` (por defecto) | `/dev/ipmi0` vía los módulos del kernel `ipmi_si`+`ipmi_devintf` | No (necesita un kernel del host en ejecución) | Solo root local |
| **Out-of-band** | `-I lanplus` | RMCP+ sobre **UDP 623** a la IP del BMC | **Sí** | Cifrado (IPMI 2.0); aíslalo en una VLAN de gestión |

Carga los módulos in-band:

```
$ sudo modprobe ipmi_si ipmi_devintf
$ ls -l /dev/ipmi0
crw------- 1 root root 240, 0 Aug 12 03:11 /dev/ipmi0
$ sudo ipmitool mc info
Device ID                 : 32
Device Revision           : 1
Firmware Revision         : 4.71
IPMI Version              : 2.0
Manufacturer ID           : 674
Manufacturer Name         : Dell Inc.
Product Name              : PowerEdge R650 (iDRAC9)
```

### 4.2 Sensores y el SDR (el plano de monitorización)

```
$ sudo ipmitool sensor list
Inlet Temp       | 22.000     | degrees C  | ok    | -7.000  | 3.000   | 42.000  | 47.000
Exhaust Temp     | 35.000     | degrees C  | ok    | 3.000   | 8.000   | 70.000  | 75.000
CPU1 Temp        | 48.000     | degrees C  | ok    | na      | na      | 91.000  | 95.000
Fan1A            | 8280.000   | RPM        | ok    | 840.000 | 1080.00 | na      | na
Fan2A            | 0.000      | RPM        | nc    | 840.000 | 1080.00 | na      | na
PS1 Status       | 0x1        | discrete   | 0x0100| na      | na      | na      | na
PS2 Status       | 0x1        | discrete   | 0x0300| na      | na      | na      | na
Pwr Consumption  | 168.000    | Watts      | ok    | na      | na      | 588.00  | 675.00
```

Leyendo esto como un SRE: `Fan2A` a **0 RPM / estado `nc` (non-critical)** y `PS2 Status : 0x0300` (un bit de fallo frente al saludable `0x0100` de PS1) significan que este chasis tiene un ventilador muerto y una segunda PSU averiada — está funcionando sobre una redundancia que ahora está agotada. Nada de esto es visible desde dentro del SO. La forma compacta es `ipmitool sdr` (lee el Sensor Data Repository); `ipmitool sdr type Temperature` / `type Fan` filtran por tipo.

### 4.3 El System Event Log (el plano forense)

El SEL es el registro de eventos persistente e independiente del host del BMC — el primer sitio donde mirar tras cualquier reinicio inexplicable:

```
$ sudo ipmitool sel elist
  1 | 07/29/2026 | 11:02:14 UTC | Power Supply PS2 Status | Failure detected | Asserted
  2 | 07/29/2026 | 11:02:15 UTC | Power Supply PS2 Status | Predictive failure | Asserted
  3 | 08/02/2026 | 04:18:51 UTC | Fan Fan2A | Lower Non-critical going low | Asserted
  4 | 08/12/2026 | 03:41:22 UTC | Watchdog2 | Hard reset | Asserted
  5 | 08/12/2026 | 03:41:55 UTC | System ACPI Power State | S0/G0: working | Asserted

$ sudo ipmitool sel info
SEL Information
Version          : 1.5 (v1.5, v2 compliant)
Entries          : 5
Free Space       : 14848 bytes
Percent Used     : 1%
Last Add Time    : 08/12/2026 03:41:55 UTC
Overflow         : false
```

El evento 4 confirma el test de §3.6: el reinicio fue un **watchdog hard reset**, correlacionando exactamente con el bit de boot-status `CARDRESET` de `wdctl` del lado del SO. Limpia el SEL tras el triaje (`ipmitool sel clear`) para que el siguiente incidente sea inequívoco.

### 4.4 Control de energía del chasis y Serial-over-LAN (las "manos")

```
$ sudo ipmitool chassis status
System Power         : on
Power Restore Policy : always-on
Last Power Event     : command
Cooling/fan fault    : true
Front-panel lockout  : inactive

# Remote, over the mgmt network — power a wedged node without walking to the DC:
$ ipmitool -I lanplus -H 10.20.0.51 -U fence -P 'S3cr3t!' chassis power status
Chassis Power is on
$ ipmitool -I lanplus -H 10.20.0.51 -U fence -P 'S3cr3t!' chassis power cycle
Chassis Power Control: Cycle

# Serial-over-LAN: a full text console when SSH is dead (watch kernel panics live)
$ ipmitool -I lanplus -H 10.20.0.51 -U fence -P 'S3cr3t!' sol activate
[SOL Session operational.  Use ~? for help]
node1 login:
```

Los verbos de `chassis power`: `on`, `off` (duro, inmediato), `cycle`, `reset`, `soft` (ACPI ordenado). **`reset`/`cycle` es exactamente lo que emite un agente STONITH** — por lo que las credenciales del BMC y el dispositivo de fencing de abajo importan tanto.

### 4.5 Configurar la LAN del BMC + un usuario solo-para-fencing, luego cablear `fence_ipmilan`

Aprovisiona el canal fuera de banda y un usuario de mínimo privilegio dedicado al fencing:

```
$ sudo ipmitool lan print 1
Set in Progress         : Set Complete
IP Address Source       : Static Address
IP Address              : 10.20.0.51
Subnet Mask             : 255.255.255.0
Default Gateway IP      : 10.20.0.1
802.1q VLAN ID          : 40
Cipher Suite Priv Max   : XXXXXXXXXXXXaXX   # 'a' = ADMIN at suite 3 (HMAC-SHA1/AES)

# Set a static mgmt IP on channel 1:
$ sudo ipmitool lan set 1 ipsrc static
$ sudo ipmitool lan set 1 ipaddr 10.20.0.51
$ sudo ipmitool lan set 1 netmask 255.255.255.0
$ sudo ipmitool lan set 1 defgw ipaddr 10.20.0.1

# Create a dedicated 'fence' user (slot 4), give it ADMIN on channel 1:
$ sudo ipmitool user set name 4 fence
$ sudo ipmitool user set password 4 'S3cr3t!'
$ sudo ipmitool user priv 4 4 1          # user 4, privilege 4 (ADMIN), channel 1
$ sudo ipmitool user enable 4
$ sudo ipmitool channel setaccess 1 4 callin=on ipmi=on link=on privilege=4
$ sudo ipmitool user list 1
ID  Name        Callin  Link Auth  IPMI Msg   Channel Priv Limit
1   (Empty)     true    false      false      NO ACCESS
4   fence       true    true       true       ADMINISTRATOR

# Validate out-of-band reachability from ANOTHER host before trusting it:
$ ipmitool -I lanplus -H 10.20.0.51 -U fence -P 'S3cr3t!' -L ADMINISTRATOR mc info
```

Regístralo en Pacemaker como el dispositivo STONITH primario, con SBD como el nivel de respaldo:

```
$ sudo pcs stonith create fence-node1 fence_ipmilan \
        pcmk_host_list=node1 \
        ip=10.20.0.51 \
        username=fence \
        password='S3cr3t!' \
        lanplus=1 \
        privlvl=ADMINISTRATOR \
        power_wait=4 \
        pcmk_reboot_action=reboot \
        op monitor interval=60s

# Two-tier fencing: try IPMI first; if it fails/unreachable, fall through to SBD.
$ sudo pcs stonith level add 1 node1 fence-node1
$ sudo pcs stonith level add 2 node1 fence-sbd
$ sudo pcs stonith status
  * fence-node1  (stonith:fence_ipmilan):  Started node2
  * fence-sbd    (stonith:fence_sbd):      Started node1
```

### 4.6 `ipmievd` — reenviar eventos del SEL a syslog

`ipmievd` convierte el SEL pasivo en un flujo en vivo: vigila nuevas entradas del SEL (vía la interfaz in-band de OpenIPMI o por sondeo) y las escribe en syslog, donde tu pipeline de logs (rsyslog → Loki/Elastic → alertas) las recoge. Esto cierra el bucle para que una PSU averiada avise a alguien en lugar de quedarse silenciosa en el BMC.

```
$ sudo systemctl enable --now ipmievd
$ sudo systemctl status ipmievd --no-pager
● ipmievd.service - IPMI event daemon
     Active: active (running) since Wed 2026-08-12 03:55:10 UTC; 4s ago
   Main PID: 3120 (ipmievd)

$ logger -t test "trigger"; sudo journalctl -t ipmievd -b --no-pager | tail -3
Aug 12 03:55:10 node1 ipmievd: ipmievd: startup
Aug 12 03:55:10 node1 ipmievd: Waiting for events...
Aug 12 04:12:03 node1 ipmievd: Power Supply PS2 Status Failure detected - Asserted
```

### 4.7 Una nota sobre Redfish (contexto del sucesor)

El DMTF estandarizó **Redfish** (RESTful/JSON sobre HTTPS) como sucesor de IPMI; IPMI 2.0 está congelado (sin nuevas versiones de especificación) y varios fabricantes están deprecando el IPMI-over-LAN raw por defecto a favor de Redfish. Para fencing existe ahora `fence_redfish`. IPMI sigue siendo el mecanismo examinable en LPIC-3 y aún ubicuo, pero en diseños greenfield prefiere Redfish para el plano de gestión donde el BMC lo soporte. `fence_ipmilan` y `fence_redfish` pueden coexistir en la misma `fencing-topology`.

---

## 5. Extra: parámetros de disco con `hdparm` / `sdparm`

El objetivo aborda el ajuste de parámetros de disco de bajo nivel que afecta directamente a la durabilidad de los datos ante una pérdida de energía — crítico en nodos de clúster sin caché respaldada por batería. El más importante es la **caché de escritura volátil**: un SSD/HDD que confirma escrituras desde la DRAM antes de persistirlas perderá silenciosamente escrituras ya confirmadas ante una pérdida de energía, corrompiendo un DRBD/journal.

```
# ATA/SATA via hdparm:
$ sudo hdparm -W /dev/sda            # query write-cache state
/dev/sda:
 write-caching =  1 (on)
$ sudo hdparm -W0 /dev/sda           # DISABLE volatile write cache (durability > throughput)
/dev/sda:
 setting drive write-caching to 0 (off)
 write-caching =  0 (off)

$ sudo hdparm -I /dev/sda | grep -iE 'Model|Write cache|Security'
        Model Number:       Samsung SSD 870 EVO 2TB
           *    Write cache
           *    Security Mode feature set

# SCSI/SAS/NVMe via sdparm (Caching mode page: WCE = Write Cache Enable):
$ sudo sdparm --get=WCE /dev/sdb
    /dev/sdb: SEAGATE   ST4000NM0025      N003
WCE           1  [cha: y, def:  1, sav:  1]
$ sudo sdparm --clear=WCE --save /dev/sdb   # disable + persist across power cycles
```

Persiste los ajustes de `hdparm` a través de reinicios mediante `/etc/hdparm.conf`:

```conf
# /etc/hdparm.conf
/dev/disk/by-id/ata-Samsung_SSD_870_EVO_2TB_S6PNNS0T {
    write_cache = off
    apm = 254        # disable aggressive power management / head-parking on cluster disks
}
```

---

## 6. Playbook de verificación de extremo a extremo y diagnóstico de fallos

| Síntoma | Primer comando | Qué lo confirma / refuta | Solución / siguiente paso |
|---|---|---|---|
| El nodo se reinició, sin ningún log del SO que lo explique | `ipmitool sel elist \| tail` | `Watchdog2 ... Hard reset` = el watchdog disparó; eventos de energía = pérdida de PSU/AC | Correlaciona con el boot-status de `wdctl`; encuentra *por qué* el SO dejó de acariciar (carga, panic) |
| Se sospecha de un disco muriendo | `smartctl -A /dev/sdX` luego `-t long` | Raw `5/187/197/198` en aumento, o `Completed: read failure` | Saca el disco de servicio del RAID/DRBD antes de que fuerce una resincronización |
| Watchdog "configurado" pero no te fías de él | `wdctl /dev/watchdog0` + test de panic (§3.6) | `Timeleft` contando hacia atrás + el nodo reinicia en ~timeout | Si nunca reinicia: softdog sobre un kernel colgado, o nada es dueño del dispositivo |
| `/dev/watchdog` ocupado / SBD no arranca | `sudo fuser -v /dev/watchdog*` | systemd (PID 1) o `watchdog`d ya lo mantiene | Pon `RuntimeWatchdogSec=0`; deja que SBD sea su dueño |
| Alarma en el chasis, el SO parece bien | `ipmitool sensor list \| grep -v ok` | Ventilador a 0 RPM / bits de estado de PSU / temp sobre el umbral | Despacha a alguien in situ; el SO nunca ve esto |
| No se puede hacer fencing de un nodo (STONITH fallando) | `ipmitool -I lanplus -H <bmc> ... mc info` | Timeout = red/credenciales del BMC rotas | Arregla la VLAN/credenciales de gestión; apóyate en el nivel 2 de SBD mientras tanto |
| Los correos de smartd nunca llegan | `smartd -q onecheck` + línea de dispositivo `-M test` | Errores de parseo, o el manejador nunca se ejecuta | Arregla el MTA / la ruta del manejador `-M exec` |

Dos disciplinas que un SRE impone aquí: **(1)** el watchdog y cada dispositivo de fencing se *prueban destructivamente al menos una vez* antes de que el nodo lleve producción — una ruta de fencing sin probar es peor que ninguna porque el clúster confía en ella; **(2)** los autotests SMART y el reenvío del SEL (`ipmievd`) se ejecutan continuamente y *avisan*, porque cada uno de estos subsistemas falla silenciosamente por diseño — todo su valor está en convertir un fallo invisible de un solo nodo en una alerta *antes* de que se convierta en un incidente del clúster.

---

## 7. Referencias

- LPI — Objetivos del Examen 306-300 (Tema 364.1): https://www.lpi.org/our-certifications/exam-306-objectives/
- Documentación del proyecto smartmontools (`smartctl`, `smartd`, `smartd.conf`): https://www.smartmontools.org/
- Página man `smartd.conf(5)`: https://linux.die.net/man/5/smartd.conf
- Kernel de Linux — Watchdog Support (`Documentation/watchdog/`): https://www.kernel.org/doc/html/latest/watchdog/index.html
- Kernel de Linux — Watchdog API (`watchdog-api`, ioctls de `/dev/watchdog`): https://www.kernel.org/doc/html/latest/watchdog/watchdog-api.html
- systemd — `systemd-system.conf(5)` (`RuntimeWatchdogSec`, `RebootWatchdogSec`): https://www.freedesktop.org/software/systemd/man/latest/systemd-system.conf.html
- El daemon `watchdog` — `watchdog.conf(5)` / `watchdog(8)`: https://man7.org/linux/man-pages/man5/watchdog.conf.5.html
- ClusterLabs — Fencing SBD (`sbd(8)`, storage-based death): https://github.com/ClusterLabs/sbd/blob/master/man/sbd.8.pod
- ClusterLabs — Fencing / STONITH de Pacemaker (`fence_ipmilan`, `fence_sbd`): https://clusterlabs.org/pacemaker/doc/
- Proyecto y página man de `ipmitool`: https://github.com/ipmitool/ipmitool and https://linux.die.net/man/1/ipmitool
- Especificación de Intelligent Platform Management Interface (IPMI) 2.0 (Intel/DMTF): https://www.intel.com/content/www/us/en/products/docs/servers/ipmi/ipmi-second-gen-interface-spec-v2-rev1-1.html
- Especificación de DMTF Redfish (sucesor de IPMI): https://www.dmtf.org/standards/redfish
- Página man `hdparm(8)`: https://man7.org/linux/man-pages/man8/hdparm.8.html
- Proyecto y página man de `sdparm(8)`: https://sg.danny.cz/sg/sdparm.html