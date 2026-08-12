# Ejercicios guiados — 364.1 Alta disponibilidad de hardware y recursos

> **Contexto del examen.** El objetivo 364.1 (peso 3.33) forma parte de *Single Node High Availability*: mantener vivo un único servidor detectando hardware que falla *antes* de que tire abajo el nodo, y forzando una recuperación limpia cuando el propio SO se cuelga. Vas a practicar el monitoreo de discos con S.M.A.R.T., la telemetría térmica/`lm-sensors`, la gestión out-of-band con IPMI, los watchdogs del kernel y de `systemd`, y la observación de recursos con la familia `sysstat`.
>
> **Requisitos del laboratorio.** Una VM Linux que puedas reiniciar sin riesgo (Debian/Ubuntu o de la familia RHEL). Root o `sudo`. Paquetes: `smartmontools`, `lm-sensors`, `ipmitool`, `watchdog`, `sysstat` y, opcionalmente, `monit`. Varios pasos arman un watchdog que **hará un hard-reset de la máquina**: nunca los ejecutes en un host que te importe.
>
> **Fuentes de referencia**
> - Objetivos del LPI 306 — https://www.lpi.org/our-certifications/exam-306-objectives/
> - smartmontools — https://www.smartmontools.org/ (`man smartctl`, `man smartd.conf`)
> - lm-sensors — https://github.com/lm-sensors/lm-sensors
> - ipmitool — https://github.com/ipmitool/ipmitool (`man ipmitool`)
> - API del watchdog del kernel de Linux — https://www.kernel.org/doc/html/latest/watchdog/watchdog-api.html
> - watchdog de systemd — https://www.freedesktop.org/software/systemd/man/systemd.service.html y https://0pointer.de/blog/projects/watchdog.html
> - sysstat — https://github.com/sysstat/sysstat
> - monit — https://mmonit.com/monit/documentation/monit.html

---

## Ejercicio 1 — Leer la salud del disco S.M.A.R.T. con `smartctl`

El objetivo es distinguir un valor *normalizado* (un puntaje de salud de 1 a 253) de un valor *crudo* (el conteo físico real), e identificar los atributos que de verdad predicen la falla.

1. Instalá el conjunto de herramientas y confirmá que el disco soporta S.M.A.R.T.:

   ```bash
   sudo apt-get install -y smartmontools     # or: sudo dnf install smartmontools
   sudo smartctl -i /dev/sda
   ```

   ```
   === START OF INFORMATION SECTION ===
   Device Model:     Samsung SSD 870 EVO 500GB
   Serial Number:    S5Y2NG0R123456A
   Firmware Version: SVT02B6Q
   User Capacity:    500,107,862,016 bytes [500 GB]
   Rotation Rate:    Solid State Device
   SMART support is: Available - device has SMART capability.
   SMART support is: Enabled
   ```

2. Si S.M.A.R.T. está *Available* pero *Disabled*, activalo para que el firmware mantenga los contadores:

   ```bash
   sudo smartctl -s on /dev/sda
   ```

3. Pedile al disco su propio veredicto general (esta es la lógica de umbrales del firmware, no la tuya):

   ```bash
   sudo smartctl -H /dev/sda
   ```

   ```
   === START OF READ SMART DATA SECTION ===
   SMART overall-health self-assessment test result: PASSED
   ```

4. Volcá la tabla completa de atributos y leé las columnas:

   ```bash
   sudo smartctl -A /dev/sda
   ```

   ```
   ID# ATTRIBUTE_NAME          FLAGS    VALUE WORST THRESH FAIL RAW_VALUE
     5 Reallocated_Sector_Ct   PO--CK   100   100   010    -    0
     9 Power_On_Hours          -O--CK   095   095   000    -    21833
   177 Wear_Leveling_Count     PO--C-   094   094   000    -    213
   187 Reported_Uncorrect      -O--CK   100   100   000    -    0
   194 Temperature_Celsius     -O---K   067   050   000    -    33
   197 Current_Pending_Sector  -O--C-   100   100   000    -    0
   198 Offline_Uncorrectable   ----CK   100   100   000    -    0
   199 UDMA_CRC_Error_Count    -OSRCK   100   100   000    -    0
   ```

5. En un dispositivo NVMe la página de salud se ve distinta; leela también:

   ```bash
   sudo smartctl -a /dev/nvme0 | sed -n '/SMART.*Health Information/,/Temperature Sensor/p'
   ```

   ```
   SMART/Health Information (NVMe Log 0x02)
   Critical Warning:                   0x00
   Temperature:                        41 Celsius
   Available Spare:                    100%
   Available Spare Threshold:          10%
   Percentage Used:                    3%
   Media and Data Integrity Errors:    0
   ```

**Verificación de comprensión**

- **Q1.** En la tabla ATA, `Reallocated_Sector_Ct` muestra `VALUE 100`, `THRESH 010`, `RAW_VALUE 0`. ¿Cuál de esos tres números es el conteo de sectores reasignados, y cómo deciden `VALUE` y `THRESH` una falla?
- **Q2.** El atributo 194 muestra `VALUE 067` con `RAW_VALUE 33`. ¿Por qué el "puntaje de salud" es *más bajo* aunque 33 °C sea una temperatura perfectamente buena?
- **Q3.** ¿Cuáles son los cinco atributos clásicos que predicen una falla en un disco ATA giratorio, y cómo se ve el equivalente NVMe de "el disco se está gastando / se está quedando sin repuestos"?

---

## Ejercicio 2 — Autotests y monitoreo desatendido con `smartd`

`smartctl -H` solo confía en el propio flag del firmware; un nodo de HA proactivo corre autotests periódicos y te envía un correo apenas aparece el primer sector reasignado.

1. Lanzá un autotest **corto** en línea y consultá hasta que termine:

   ```bash
   sudo smartctl -t short /dev/sda
   # ... wait the estimated time, then:
   sudo smartctl -l selftest /dev/sda
   ```

   ```
   Num  Test_Description  Status                  Remaining  LifeTime(hours)  LBA_of_first_error
   # 1  Short offline     Completed without error       00%          21834             -
   # 2  Extended offline  Completed without error       00%          21789             -
   ```

2. Inspeccioná el registro de errores del disco (se llena solo cuando el disco registró un error interno):

   ```bash
   sudo smartctl -l error /dev/sda
   ```

   ```
   SMART Error Log Version: 1
   No Errors Logged
   ```

3. Configurá el demonio `smartd`. Editá `/etc/smartd.conf`, comentá cualquier `DEVICESCAN` existente y agregá una línea explícita, completamente monitoreada:

   ```conf
   # /etc/smartd.conf
   # -a           : monitor all standard attributes (health, error log, selftest log, usage, temp)
   # -o on        : enable automatic offline data collection
   # -S on        : enable attribute autosave
   # -n standby   : do not spin up a sleeping disk just to poll it
   # -H           : monitor overall SMART health
   # -l error     : monitor the ATA error log
   # -l selftest  : monitor the self-test log
   # -f           : report failures of usage (prefail) attributes
   # -I 194       : ignore raw temperature changes (avoid noise), but...
   # -W 5,45,55   : warn on +5 °C swings, INFO at 45 °C, CRITICAL at 55 °C
   # -s (S/../.././02|L/../../6/03) : short test daily 02:00, long test Saturday 03:00
   # -m root -M exec /usr/share/smartmontools/smartd_warning.sh : how to alert
   /dev/sda -a -o on -S on -n standby -H -l error -l selftest -f \
            -I 194 -W 5,45,55 \
            -s (S/../.././02|L/../../6/03) \
            -m root -M exec /usr/share/smartmontools/smartd_warning.sh
   ```

4. Validá la configuración en primer plano con salida de depuración antes de habilitar el servicio:

   ```bash
   sudo smartd -q onecheck -d
   ```

   ```
   Device: /dev/sda, opened
   Device: /dev/sda, is SMART capable. Adding to "monitor" list.
   Monitoring 1 ATA/SATA, 0 SCSI, 0 NVMe devices
   Executed test suite for /dev/sda; next test schedule ...
   ```

5. Habilitá y arrancá el demonio, y luego confirmá que está vigilando:

   ```bash
   sudo systemctl enable --now smartd
   systemctl status smartd --no-pager
   journalctl -u smartd -b | tail -n 5
   ```

**Verificación de comprensión**

- **Q4.** En el token de agenda `-s (S/../.././02|L/../../6/03)`, ¿qué significan `S`/`L` y qué codifican los cinco campos separados por barras? Decodificá la expresión completa.
- **Q5.** ¿Cuál es la diferencia entre `smartctl -t offline` / `-o on` (recolección de datos offline) y `smartctl -t short` (un autotest)? ¿Por qué importa `-n standby` en un nodo con discos inactivos?
- **Q6.** `smartd` encontró un problema a las 03:00. ¿A dónde va físicamente la notificación, y cuál es el rol de `smartd_warning.sh` frente a `-m root`?

---

## Ejercicio 3 — Telemetría térmica y de ventiladores con `lm-sensors`

El sobrecalentamiento es una caída en cámara lenta. `lm-sensors` expone los chips de monitoreo de hardware de la placa (Super I/O, `coretemp` de la CPU, etc.).

1. Instalá y ejecutá el probador interactivo. Aceptá los valores por defecto seguros (respondé `YES` al resumen que ofrece cargar los módulos detectados):

   ```bash
   sudo apt-get install -y lm-sensors
   sudo sensors-detect
   ```

   ```
   Now follows a summary of the probes I have just done.
   Driver `coretemp':
     * Chip `Intel digital thermal sensor' (confidence: 9)
   Driver `nct6775':
     * ISA bus, address 0x290
       Chip `Nuvoton NCT6779D Super IO Sensors' (confidence: 9)
   Do you want to add these lines automatically to /etc/modules? (yes/NO): yes
   ```

2. Asegurate de que los módulos detectados estén cargados ahora (sin reiniciar):

   ```bash
   sudo systemctl restart lm-sensors 2>/dev/null || sudo /etc/init.d/kmod start
   sudo modprobe coretemp; sudo modprobe nct6779 2>/dev/null || sudo modprobe nct6775
   ```

3. Leé los sensores:

   ```bash
   sensors
   ```

   ```
   coretemp-isa-0000
   Adapter: ISA adapter
   Package id 0:  +38.0°C  (high = +84.0°C, crit = +100.0°C)
   Core 0:        +35.0°C  (high = +84.0°C, crit = +100.0°C)

   nct6779-isa-0290
   Adapter: ISA adapter
   Vcore:         1.02 V   (min =  +0.00 V, max =  +1.74 V)
   fan1:          0 RPM    (min =    0 RPM)
   fan2:        1123 RPM   (min =  300 RPM)
   temp1:       +41.0°C    (high = +80.0°C, hyst = +75.0°C)
   ```

4. Emití salida legible por máquina (esto es lo que raspearía un agente de monitoreo):

   ```bash
   sensors -j | head -n 20     # JSON
   sensors -A                  # bare, no adapter lines
   ```

5. Reetiquetá un canal de chip críptico y definí tus propios límites de alarma en un drop-in, después releé:

   ```bash
   sudo tee /etc/sensors.d/local.conf >/dev/null <<'EOF'
   chip "nct6779-isa-0290"
       label temp1 "SystemBoard"
       set temp1_max 70
       label fan2  "CPU_FAN"
       set fan2_min 500
   EOF
   sudo sensors -s      # apply 'set' limits to the chips
   sensors nct6779-isa-0290
   ```

6. *(Opcional, solo en hardware real.)* Calibrá el control PWM de los ventiladores. `pwmconfig` acelera y desacelera cada ventilador para mapear los canales PWM a los ventiladores, y después escribe `/etc/fancontrol`:

   ```bash
   sudo pwmconfig
   sudo systemctl enable --now fancontrol
   ```

**Verificación de comprensión**

- **Q7.** ¿Qué cambia realmente `sensors-detect` en el sistema, y por qué deben estar cargados esos módulos del kernel (por ejemplo, vía `/etc/modules`) para que `sensors` muestre algo después de un reinicio?
- **Q8.** En la salida de `coretemp`, ¿cuál es la diferencia entre los umbrales `high` y `crit`, y sobre cuál actúa la CPU por sí sola sin importar tu monitoreo?
- **Q9.** Agregaste `set temp1_max 70` en un drop-in. ¿Eso cambia lo que hace el hardware a 70 °C? ¿Para qué sirve realmente `set`, y qué lo aplica?

---

## Ejercicio 4 — Monitoreo y control out-of-band con IPMI (`ipmitool`)

IPMI habla con el **BMC** (Baseboard Management Controller), que tiene alimentación y es alcanzable incluso cuando el SO está muerto: la columna vertebral de la recuperación remota de HA y, en términos de clúster, del **fencing/STONITH**.

1. Cargá los drivers IPMI in-band y confirmá que aparece el nodo de dispositivo:

   ```bash
   sudo modprobe ipmi_si
   sudo modprobe ipmi_devintf
   ls -l /dev/ipmi0
   sudo apt-get install -y ipmitool
   ```

2. Consultá el propio BMC y el estado de alimentación del chasis:

   ```bash
   sudo ipmitool mc info
   sudo ipmitool chassis status
   ```

   ```
   System Power         : on
   Power Overload       : false
   Last Power Event     :
   Main Power Fault     : false
   ```

3. Leé los sensores de hardware *a través del BMC* (independiente de `lm-sensors`) y filtrá por tipo:

   ```bash
   sudo ipmitool sdr list
   sudo ipmitool sdr type Temperature
   sudo ipmitool sdr type Fan
   ```

   ```
   CPU1 Temp        | 34 degrees C      | ok
   Inlet Temp       | 21 degrees C      | ok
   FAN1             | 4680 RPM          | ok
   PSU1 Status      | 0x01              | ok
   ```

4. Inspeccioná el **System Event Log** — el registro persistente de fallas de hardware (errores ECC, pérdida de PSU, cortes térmicos):

   ```bash
   sudo ipmitool sel info
   sudo ipmitool sel elist
   ```

   ```
   1 | 08/12/2026 | 02:14:07 | Power Supply PSU2 | Power Supply Failure detected | Asserted
   2 | 08/12/2026 | 02:14:41 | Memory ECC #0x14  | Correctable ECC | Asserted
   ```

5. Configurá **IPMI sobre LAN** para que el nodo pueda gestionarse incluso cuando sea inalcanzable in-band (el número de canal varía; a menudo 1):

   ```bash
   sudo ipmitool lan print 1
   sudo ipmitool lan set 1 ipsrc static
   sudo ipmitool lan set 1 ipaddr 192.168.50.30
   sudo ipmitool lan set 1 netmask 255.255.255.0
   sudo ipmitool lan set 1 defgw ipaddr 192.168.50.1
   sudo ipmitool lan set 1 access on
   sudo ipmitool user set name 2 hauser
   sudo ipmitool user set password 2
   sudo ipmitool channel setaccess 1 2 callin=on ipmi=on link=on privilege=4
   sudo ipmitool user enable 2
   ```

6. Desde una *segunda máquina*, consultá y (con cuidado) reiniciá la alimentación del nodo de forma remota, y abrí una consola **Serial-over-LAN**:

   ```bash
   ipmitool -I lanplus -H 192.168.50.30 -U hauser -P '******' sensor list
   ipmitool -I lanplus -H 192.168.50.30 -U hauser -P '******' chassis power status
   # Recovery actions — irreversible on a live node:
   ipmitool -I lanplus -H 192.168.50.30 -U hauser -P '******' chassis power cycle
   ipmitool -I lanplus -H 192.168.50.30 -U hauser -P '******' sol activate
   ```

**Verificación de comprensión**

- **Q10.** ¿Por qué IPMI puede leer temperaturas y encender la máquina cuando el SO está completamente colgado, mientras que `lm-sensors` no puede? ¿Qué componente lo hace posible?
- **Q11.** Contrastá `chassis power off`, `chassis power cycle`, `chassis power reset` y `chassis power soft`. ¿Cuál le pide al SO que se apague limpiamente, y cuál es el fence duro que usa STONITH?
- **Q12.** ¿Cuál es el valor práctico para HA de `ipmitool sel elist` después de un reinicio inexplicable, y cuál es la diferencia entre la interfaz in-band (`-I open`, la predeterminada) y `-I lanplus`?

---

## Ejercicio 5 — Watchdogs del kernel, del demonio `watchdog` y de `systemd`

Un watchdog es un temporizador de cuenta regresiva que el software debe seguir reiniciando ("acariciando"). Si el software se traba y deja de acariciarlo, el temporizador expira y el hardware reinicia la máquina, convirtiendo un cuelgue silencioso en un reinicio automático.

> ⚠️ Cada paso de acá puede reiniciar la VM. Usá una VM descartable. `softdog` es un watchdog por software lo bastante seguro como para aprender la mecánica.

1. Cargá un driver de watchdog e inspeccioná el dispositivo resultante. En una VM, usá `softdog`:

   ```bash
   sudo modprobe softdog
   ls -l /dev/watchdog*
   sudo wdctl /dev/watchdog
   ```

   ```
   Device:        /dev/watchdog0
   Identity:      Software Watchdog [version 0]
   Timeout:       60 seconds
   Pre-timeout:   0 seconds
   FLAG           DESCRIPTION               STATUS BOOT-STATUS
   KEEPALIVEPING  Keep alive ping reply          1           0
   MAGICCLOSE     Support for magic close char   0           0
   ```

2. Entendé el contrato de "magic close". Abrir `/dev/watchdog` lo **arma**; cerrarlo normalmente lo *desarma* **solo** si primero se escribió el carácter `V`, de lo contrario el temporizador sigue corriendo:

   ```bash
   # Arms the timer. If you just Ctrl-C without writing 'V', the machine reboots ~60s later.
   echo -n 'V' | sudo tee /dev/watchdog >/dev/null   # writes magic-close, safe disarm
   ```

3. Instalá y configurá el demonio `watchdog` de espacio de usuario, que acaricia el dispositivo *y* ejecuta sus propios chequeos de salud (carga, memoria, red, temperatura, frescura de archivos):

   ```conf
   # /etc/watchdog.conf
   watchdog-device = /dev/watchdog
   watchdog-timeout = 60          # hardware timeout to program into the chip
   interval        = 10           # pet the device every 10 s (must be < timeout)

   max-load-1      = 24           # reboot if 1-min load average exceeds 24
   min-memory      = 1            # reboot if free pages fall below this (in pages)
   ping            = 192.168.50.1 # reboot if this gateway stops answering
   interface       = eth0

   temperature-sensor = /sys/class/hwmon/hwmon0/temp1_input
   max-temperature    = 90        # in the unit of the sensor (milli-°C → 90000 if raw)

   file   = /var/log/heartbeat    # a file that must keep changing...
   change = 1800                  # ...at least every 1800 s, else reboot

   repair-binary  = /usr/sbin/repair.sh   # try to fix before rebooting (must exit 0)
   ```

4. Probá la lógica del demonio *sin* armar el hardware real, después habilitalo de verdad:

   ```bash
   sudo watchdog -c /etc/watchdog.conf -v    # verbose foreground test
   sudo systemctl enable --now watchdog
   ```

5. Aprendé el rol de `wd_keepalive`: es el demonio *mínimo* de solo-acariciar que mantiene alimentado el watchdog mientras el demonio `watchdog` completo está detenido (por ejemplo, durante reinicios de servicios) para que el temporizador nunca se dispare por accidente:

   ```bash
   systemctl status wd_keepalive --no-pager
   ```

6. Conectá el **watchdog de hardware con `systemd`** para que el propio `systemd` (PID 1) sea quien acaricie el chip: si el kernel o `systemd` entran en deadlock, la máquina se reinicia:

   ```ini
   # /etc/systemd/system.conf   (or a drop-in under /etc/systemd/system.conf.d/)
   [Manager]
   RuntimeWatchdogSec=20      # systemd pets the hw watchdog; hangs → reset after ~20s
   RebootWatchdogSec=10min    # arm watchdog during reboot so a stuck shutdown still resets
   ```

   ```bash
   sudo systemctl daemon-reexec
   systemctl show -p RuntimeWatchdogUSec -p RebootWatchdogUSec
   ```

   > Nota: `RuntimeWatchdogSec` requiere un `/dev/watchdog` **real** y entra en conflicto con el demonio `watchdog` independiente: solo un proceso puede ser dueño del dispositivo. No ejecutes ambos contra el mismo chip.

7. Mirá el **watchdog por software por servicio**: un servicio declara `WatchdogSec=` y debe llamar a `sd_notify(WATCHDOG=1)`; si deja de notificar, `systemd` reinicia *esa unidad* (no toda la máquina):

   ```ini
   # /etc/systemd/system/myapp.service  (drop-in)
   [Service]
   WatchdogSec=30
   Restart=on-watchdog
   ```

**Verificación de comprensión**

- **Q13.** Explicá el contrato de "magic close" (`V`) en `/dev/watchdog`. ¿Por qué un script descuidado que abre el dispositivo y sale puede reiniciar la máquina un timeout después?
- **Q14.** Compará el demonio `watchdog` independiente, `RuntimeWatchdogSec` en `systemd`, y el `WatchdogSec=` de un servicio. ¿Cuál recupera un *kernel* colgado, cuál recupera un *systemd* colgado, y cuál recupera una sola *aplicación* colgada?
- **Q15.** ¿Para qué sirve `wd_keepalive`, y por qué es peligroso ejecutar tanto el demonio `watchdog` como el `RuntimeWatchdogSec` de `systemd` contra el mismo `/dev/watchdog`?

---

## Ejercicio 6 — Monitoreo de recursos con `uptime`, `vmstat`, `iostat` y `sar`

El hardware que técnicamente está sano igual puede volver al nodo efectivamente indisponible por saturación. Esta es la mitad de "recursos" del objetivo.

1. Leé el load average y ponelo en contexto con la cantidad de CPUs:

   ```bash
   uptime
   nproc
   cat /proc/loadavg
   ```

   ```
    14:52:10 up 15 days,  3:11,  2 users,  load average: 7.42, 6.10, 4.88
   4
   7.42 6.10 4.88 3/842 20117
   ```

2. Muestreá el estado del sistema cada segundo y leé las columnas de CPU/IO/memoria:

   ```bash
   vmstat 1 5
   ```

   ```
   procs -----------memory----------  ---swap-- -----io---- -system-- ------cpu-----
    r  b   swpd   free   buff  cache   si   so    bi    bo   in   cs us sy id wa st
    9  1  10240 152340  88120 990112    0    4  1200  3400 5100 8900 71  9  4 15  1
   10  0  10240 149880  88120 992440    0    0   980  4100 5300 9200 74 11  2 13  0
   ```

3. Observá la E/S por dispositivo con estadísticas extendidas de `sysstat` (salteá la primera muestra desde el arranque con `-y`):

   ```bash
   sudo apt-get install -y sysstat
   iostat -xz 1 3
   ```

   ```
   Device   r/s   w/s   rkB/s   wkB/s  r_await w_await aqu-sz  %util
   sda     40.0 320.0  2560.0 12800.0     1.10   18.40   6.20   98.7
   nvme0n1  8.0  15.0   512.0   960.0     0.05    0.10   0.01    3.1
   ```

4. Habilitá la recolección histórica para poder responder "¿qué pasó a las 02:00 anoche?". Activá el colector de `sysstat` (`sadc` vía un timer de systemd / cron), después consultá los archivos:

   ```bash
   # Debian/Ubuntu: set ENABLED="true" in /etc/default/sysstat
   sudo sed -i 's/^ENABLED=.*/ENABLED="true"/' /etc/default/sysstat
   sudo systemctl enable --now sysstat            # RHEL uses the same unit name
   ```

5. Leé el historial de ayer/hoy desde los archivos `saNN` guardados:

   ```bash
   sar -u 1 3                 # live CPU (user/system/iowait/steal/idle)
   sar -r                     # memory over the day
   sar -d -p                  # per-disk activity, pretty device names
   sar -n DEV                 # per-interface network throughput
   sar -q                     # run-queue length and load averages
   sar -f /var/log/sysstat/sa12 -u   # CPU history from the 12th of the month
   ```

   ```
   12:00:01  CPU   %user  %nice  %system  %iowait  %steal  %idle
   02:10:01  all   71.20   0.00     9.10    15.30    1.10    3.30
   ```

6. Correlacioná la presión de memoria directamente desde el PSI (Pressure Stall Information) del kernel:

   ```bash
   for r in cpu memory io; do echo "== $r =="; cat /proc/pressure/$r; done
   free -h
   ```

**Verificación de comprensión**

- **Q16.** El nodo tiene 4 CPUs y un load average de 1 minuto de `7.42`. ¿Está sobrecargado? ¿Qué columna extra en `vmstat`/`sar` te dice si la presión es por *CPU* o por *E/S*?
- **Q17.** En `vmstat`, ¿qué significan las columnas de CPU `wa` y `st`, y cuál señala específicamente que un nodo de HA *virtualizado* está siendo privado de recursos por su hipervisor?
- **Q18.** `iostat -x` muestra `sda` en `%util 98.7` con `w_await 18.40` ms mientras que `nvme0n1` está en `3.1%`. ¿Qué te está diciendo el disco, y por qué `%util` por sí solo es una señal de saturación engañosa en SSD/NVMe modernos? ¿Qué debés habilitar *de antemano* para que `sar` pueda reconstruir esto después de los hechos?

---

## Ejercicio 7 — Convertir el monitoreo en reacción automática (`monit`, conciencia de `collectd`)

La observación solo ayuda si algo actúa en consecuencia. El objetivo espera *conciencia* de herramientas que vigilan una métrica y toman una acción.

1. Instalá `monit` y agregá un archivo de control que reinicie un servicio y alerte sobre umbrales de recursos:

   ```conf
   # /etc/monit/conf.d/ha.conf
   set daemon 30                      # check cycle: every 30 s
   set alert admin@example.org

   check system $HOST
       if loadavg (5min) > 8      then alert
       if memory usage    > 90%   then alert
       if cpu usage (wait) > 40%  then alert

   check filesystem rootfs with path /
       if space usage > 85% then alert

   check process sshd with pidfile /run/sshd.pid
       start program = "/bin/systemctl start ssh"
       stop  program = "/bin/systemctl stop ssh"
       if 3 restarts within 5 cycles then alert
   ```

2. Validá la sintaxis, recargá y leé el estado:

   ```bash
   sudo monit -t              # test control file syntax
   sudo systemctl enable --now monit
   sudo monit reload
   sudo monit status
   sudo monit summary
   ```

3. *(Conciencia.)* Fijate dónde encaja `collectd`: un demonio liviano cuyos plugins (`cpu`, `memory`, `df`, `disk`, `sensors`, `smart`, `thermal`, `ipmi`) recolectan las mismas métricas de los Ejercicios 1–6 y las envían a RRD, Prometheus o un colector de red — los mismos números, centralizados en lugar de leídos a mano:

   ```conf
   # /etc/collectd/collectd.conf (excerpt)
   LoadPlugin cpu
   LoadPlugin sensors
   LoadPlugin smart
   LoadPlugin thermal
   LoadPlugin write_prometheus
   <Plugin write_prometheus>
       Port "9103"
   </Plugin>
   ```

**Verificación de comprensión**

- **Q19.** ¿Qué hace `monit` que `sar`/`sensors` simples no hacen? Ilustralo con el bloque `check process sshd`.
- **Q20.** En una línea cada uno, ubicá `collectd` frente a `monit`: ¿cuál *reacciona* a un umbral en el nodo local, y cuál *recolecta y exporta* métricas para graficado/alertado centralizado?

---

<details>
<summary><strong>Respuestas</strong> (clic para expandir)</summary>

**Q1.** `RAW_VALUE = 0` es el conteo físico real de sectores reasignados. `VALUE` (100) es un *puntaje de salud normalizado* de 1 a 253 calculado por el firmware; más alto es más sano. Se considera que el disco falla para ese atributo cuando `VALUE` cae hasta `THRESH` (10) o por debajo. Así que la salud se juzga por `VALUE ≤ THRESH`, no por el número crudo directamente, aunque un `RAW_VALUE` que sube es lo que eventualmente arrastra a `VALUE` hacia abajo.

**Q2.** El `VALUE` normalizado para temperatura es un puntaje inverso: más caliente → puntaje más bajo. `067` es simplemente la normalización del fabricante de "33 °C" contra su propia escala; no es una alarma. Juzgá la temperatura por el `RAW_VALUE` (33 °C) y los límites `high`/`crit` del disco, no por la columna normalizada. Precisamente por esto la opción `-W` de `smartd` actúa sobre la temperatura cruda, no sobre el valor normalizado.

**Q3.** Predictores clásicos de falla en ATA: **5** Reallocated_Sector_Ct, **197** Current_Pending_Sector, **198** Offline_Uncorrectable, **187** Reported_Uncorrect, y **188** Command_Timeout / **10** Spin_Retry_Count (se cita comúnmente cualquiera de los dos). La guía tipo Backblaze trata los valores no nulos de 5/187/197/198 como fuertes señales de falla. Los equivalentes NVMe de "gastándose / sin repuestos" son **Percentage Used**, **Available Spare** frente a **Available Spare Threshold**, y una máscara de bits **Critical Warning** no nula / **Media and Data Integrity Errors**.

**Q4.** `S` = autotest corto, `L` = autotest largo (extendido). Los cinco campos después de la letra son `MONTH/DAY-OF-MONTH/DAY-OF-WEEK/HOUR` — en realidad el token es `T/MM/DD/d/HH`: **Type / Month / Day-of-month / Day-of-week / Hour**, cada uno una regex donde `..` significa "cualquiera". Así que `S/../.././02` = un test **corto** en cualquier mes, cualquier día del mes, cualquier día de la semana, a las **02:00**; `L/../../6/03` = un test **largo** en cualquier mes, cualquier día del mes, día de la semana **6 (sábado)**, a las **03:00**. En resumen: test corto todas las noches a las 02:00, test largo semanal el sábado a las 03:00.

**Q5.** La *recolección de datos offline* (`-o on` / `-t offline`) es el firmware actualizando continuamente los contadores de atributos en segundo plano; no verifica el medio leyéndolo de punta a punta. Un *autotest* (`-t short`/`-t long`) es un diagnóstico activo que el disco corre contra su propia electrónica y superficie (largo = escaneo de lectura completo). `-n standby` le dice a `smartd` que **no despierte un disco que está en standby/sleep** solo para consultarlo — importante en nodos con discos inactivos, tanto para evitar desgaste/consumo innecesario como para dejar que los discos realmente duerman.

**Q6.** `smartd` ejecuta el programa indicado por `-M exec` (acá `smartd_warning.sh`) y le pasa los detalles de la alerta vía variables de entorno; `-m root` establece el destinatario de correo que usa el script de advertencia por defecto (o el tuyo propio). Así que `-m` nombra *a quién* se notifica y `-M exec …` nombra *cómo* / *qué se ejecuta* para entregarla (por ejemplo, enviar correo, paginar, escribir en un webhook). El evento también se registra en syslog/journal (`journalctl -u smartd`).

**Q7.** `sensors-detect` sondea adaptadores I2C/SMBus y chips Super-I/O y, tras la confirmación, agrega los módulos de kernel correspondientes (por ejemplo, `coretemp`, `nct6775`) a `/etc/modules` (Debian) o `/etc/modules-load.d/` y configura los módulos de adaptador. `sensors` lee valores expuestos bajo `/sys/class/hwmon/` por esos **módulos de driver**; si los módulos no están cargados, no hay interfaz hwmon para leer, así que `sensors` no imprime nada. Persistirlos en `/etc/modules` asegura que se carguen en cada arranque.

**Q8.** `high` es un umbral de advertencia/suave ("se está calentando, actuá"); `crit` es el límite crítico en el que la propia CPU/firmware toma una acción protectora — throttling térmico y, si se supera, un apagado de emergencia/corte térmico — **independientemente de cualquier monitoreo que corras**. Tus herramientas deberían reaccionar en/cerca de `high`; nunca deberías *depender* de llegar a `crit`, porque eso significa que el hardware ya se está defendiendo solo.

**Q9.** `set temp1_max 70` **no** cambia el comportamiento del hardware; los propios límites del chip son los que disparan las respuestas de hardware. `set` (y `label`, `compute`) en `/etc/sensors.d/*.conf` solo afecta **cómo `libsensors`/`sensors` muestra y evalúa** la lectura — el límite mostrado y qué consideran "alarma" las herramientas de espacio de usuario. Lo aplica `sensors -s` (y se lee en cada invocación de `sensors`). Para que *pase* algo a 70 °C todavía necesitás un demonio (`watchdog`, `monit`, umbral de `collectd`, etc.) actuando sobre ese valor.

**Q10.** IPMI corre en el **BMC**, un microcontrolador dedicado en la placa madre con su propio firmware, su propio riel de alimentación (standby power) y su propia ruta de red. Lee sensores por buses laterales (side-band) y controla la alimentación del chasis directamente, así que funciona mientras la CPU/SO del host está detenida, en pánico o apagada. `lm-sensors` es solo código de espacio de usuario en el SO *principal* leyendo drivers hwmon — si ese SO está colgado, `lm-sensors` está colgado con él.

**Q11.** `chassis power soft` envía un evento ACPI de botón de encendido suave pidiéndole al SO que se apague **limpiamente**. `chassis power off` corta la alimentación de inmediato (duro, sin cooperación del SO). `chassis power cycle` = off y luego on. `chassis power reset` = un reset duro sin una caída total de alimentación. El limpio es `power soft`; el fence duro que usan los agentes de fencing/STONITH es `power off` (o `reset`/`cycle`) porque garantiza que el nodo esté muerto sin importar el estado del SO — que es todo el punto del fencing.

**Q12.** Después de un reinicio inexplicable, `ipmitool sel elist` muestra el **System Event Log** — eventos de hardware persistentes registrados por el BMC (corte térmico, falla de PSU, ECC corregible/incorregible, expiración del watchdog) con marcas de tiempo — a menudo el único registro de *por qué* la máquina se reinició, ya que los logs del SO murieron con él. `-I open` (predeterminado) habla con el BMC local vía `/dev/ipmi0` in-band; `-I lanplus` usa **IPMI v2.0 RMCP+ sobre la red** hacia un BMC remoto (`-H/-U/-P`), que es como alcanzás un nodo cuyo SO es inalcanzable.

**Q13.** Abrir `/dev/watchdog` **arma** el temporizador. El kernel solo *desarma* al cerrar si el proceso primero escribió el carácter mágico `V` (el contrato de "magic close"); de lo contrario, un cierre se trata como un posible crash y el temporizador sigue contando, reiniciando la máquina al timeout. Así que un script que abre el dispositivo para acariciarlo y luego sale (o recibe Ctrl-C) sin escribir `V` deja un temporizador armado y no acariciado — un timeout después la máquina hace un hard-reset. Siempre `echo -n 'V' > /dev/watchdog` antes de soltarlo.

**Q14.**
- Demonio **`watchdog`** independiente: proceso de espacio de usuario que acaricia `/dev/watchdog` y corre chequeos de salud; atrapa las condiciones que prueba (carga, memoria, ping, temperatura, frescura de archivos) y un bloqueo total de espacio de usuario, pero él mismo es solo un proceso.
- **`RuntimeWatchdogSec`** (systemd/PID 1 acaricia el watchdog de hardware): recupera un **kernel o `systemd`** colgado en sí mismo — si PID 1 no puede correr, deja de acariciar y el hardware reinicia el nodo.
- **`WatchdogSec=`** de un servicio (+ `sd_notify(WATCHDOG=1)`, `Restart=on-watchdog`): recupera una sola **aplicación** colgada reiniciando *solo esa unidad*, sin reiniciar la máquina.

**Q15.** `wd_keepalive` es un demonio reducido que no hace nada más que seguir acariciando `/dev/watchdog` mientras el demonio `watchdog` completo está detenido (por ejemplo, durante su propio reinicio/actualización), para que un temporizador ya armado no se dispare durante el hueco. Ejecutar el demonio `watchdog` **y** el `RuntimeWatchdogSec` de `systemd` contra el mismo `/dev/watchdog` es peligroso porque el dispositivo generalmente permite un **único abridor/dueño**: pelean por el chip, uno falla en acariciar de forma confiable, y obtenés reinicios espurios. Elegí un solo dueño del watchdog de hardware.

**Q16.** Una carga de `7.42` en 4 CPUs significa ~7,4 tareas ejecutables/ininterrumpibles compitiendo por 4 núcleos → la run queue es ~1,85× la cantidad de CPUs, es decir, **sobrecargado** (aproximadamente, load > nproc = saturado). Pero la carga cuenta tanto las tareas ligadas a CPU *como* las de E/S ininterrumpible, así que no dice *por qué*. La columna `wa` (%iowait) en `vmstat`/`sar -u` (y las columnas de procesos `r` vs `b` en `vmstat`) distingue lo ligado a CPU (alto `us`+`sy`, alto `r`) de lo ligado a E/S (alto `wa`, alto `b`).

**Q17.** `wa` = **% de tiempo de CPU inactiva mientras espera E/S de disco/red pendiente** (la CPU no tiene nada que ejecutar porque las tareas están bloqueadas en E/S). `st` = **steal time**: % de tiempo en que la CPU (virtual) estaba *lista* para ejecutar pero el **hipervisor le dio la CPU física a otro huésped**. Un `st` alto es la señal específica de que un nodo de HA *virtualizado* está siendo privado de recursos por un host sobresuscripto — un problema de hardware/capacidad fuera del huésped.

**Q18.** `sda` en `%util 98.7%` con `w_await 18.4 ms` es un disco saturado y lento (probablemente giratorio) que es el cuello de botella, mientras que el NVMe está casi inactivo — mové la carga caliente o investigá `sda`. `%util` es engañoso en SSD/NVMe porque esos dispositivos atienden muchas solicitudes **en paralelo**; un disco moderno puede estar "el 100% del tiempo atendiendo al menos una E/S" y aun así estar lejos de su límite real de throughput/profundidad de cola, así que `%util` ya no implica saturación — mirá `aqu-sz` (profundidad promedio de cola) y `await` en su lugar. Para reconstruir esto históricamente, tenés que haber **habilitado la recolección de `sysstat` de antemano** (`ENABLED="true"` / `systemctl enable --now sysstat`) para que `sadc` escribiera los archivos `saNN` que lee `sar -d`.

**Q19.** `monit` no solo *reporta* un valor — evalúa una condición en cada ciclo y **toma una acción** (reiniciar, alertar, exec). En el bloque `check process sshd`, si el proceso falta, ejecuta el `start program` para traerlo de vuelta, y si oscila (`3 restarts within 5 cycles`) escala con una alerta en lugar de reiniciar para siempre. `sar`/`sensors` solo exponen números; un humano u otra herramienta tiene que actuar.

**Q20.** `monit` = **supervisor reactivo local**: vigila umbrales/procesos en un nodo y *actúa* (reinicia/alerta). `collectd` = **colector/exportador de métricas**: demonio liviano basado en plugins que recolecta datos de CPU/memoria/disco/sensores/SMART/IPMI/thermal y los envía a RRD, un colector de red o Prometheus para graficado y alertado centralizado — recolecta, no reinicia tus servicios.

</details>