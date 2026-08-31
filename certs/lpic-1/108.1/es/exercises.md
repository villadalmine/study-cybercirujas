# LPIC-1 · 108.1 Mantener la hora del sistema — Ejercicios guiados

> **Requisitos del laboratorio.** Una VM descartable (no un contenedor, no tu estación de trabajo) con `sudo`/root, un dispositivo RTC real (`/dev/rtc0`) y salida UDP/123. Neutral respecto de la distribución: los comandos se muestran tanto para `systemd`+`chrony` (RHEL/Fedora/openSUSE, Debian/Ubuntu server) como para el `ntpd` clásico allí donde difieren.
>
> **Vas a romper el reloj deliberadamente.** Nunca ejecutes estos pasos en un host que participe en Kerberos, en servicios que terminan TLS, en un clúster de base de datos o en un plano de control de Kubernetes: un salto del reloj de más de unos pocos minutos invalidará certificados y tickets y puede corromper el estado de Raft/etcd.
>
> Instalá primero las herramientas:
> ```bash
> # Debian/Ubuntu
> sudo apt-get install -y util-linux tzdata chrony ntpdate ntpsec-ntpdig
> # RHEL/Fedora/Rocky
> sudo dnf install -y util-linux tzdata chrony
> ```

---

## Ejercicio 1 — Identificar los dos relojes

Un host Linux mantiene **dos relojes independientes**: el *reloj del sistema* (un contador en la memoria del kernel, avanzado por una interrupción de temporizador/TSC, siempre conceptualmente en segundos UTC desde la época Unix) y el *reloj de hardware* — RTC, reloj CMOS, reloj de la BIOS — un chip alimentado por batería que sigue funcionando mientras la máquina está apagada. Sólo se relacionan en los momentos en que algo copia explícitamente uno al otro.

1. Leé el reloj del sistema en la zona horaria local, y después en UTC:

   ```bash
   date
   date -u
   ```

   ```
   Wed Aug 26 16:41:07 CEST 2026
   Wed Aug 26 14:41:07 UTC 2026
   ```

2. Leé el reloj de hardware. Esto requiere root, porque abre `/dev/rtc0`:

   ```bash
   sudo hwclock --show
   ```

   ```
   2026-08-26 16:41:08.512394+02:00
   ```

3. Pedile a `hwclock` que relate lo que está haciendo realmente:

   ```bash
   sudo hwclock --show --verbose
   ```

   ```
   hwclock from util-linux 2.39.3
   System Time: 1756219268.514902
   Trying to open: /dev/rtc0
   Using the rtc interface to the clock.
   Assuming hardware clock is kept in UTC time.
   Waiting for clock tick...
   ...got clock tick
   Time read from Hardware Clock: 2026/08/26 14:41:08
   Hw clock time : 2026/08/26 14:41:08 = 1756219268 seconds since 1969
   Time since last adjustment is 0 seconds
   Calculated Hardware Clock drift is 0.000000 seconds
   2026-08-26 16:41:08.512394+02:00
   ```

4. Obtené la vista consolidada de `systemd` de ambos relojes más la zona horaria y el estado de sincronización:

   ```bash
   timedatectl
   ```

   ```
                  Local time: Wed 2026-08-26 16:41:09 CEST
              Universal time: Wed 2026-08-26 14:41:09 UTC
                    RTC time: Wed 2026-08-26 14:41:09
                   Time zone: Europe/Madrid (CEST, +0200)
   System clock synchronized: yes
                 NTP service: active
             RTC in local TZ: no
   ```

5. Leé el reloj del sistema como valor de época crudo, y convertí un valor de época de vuelta a una fecha legible:

   ```bash
   date +%s
   date -d @1756219269
   date -u -d @1756219269
   ```

   ```
   1756219269
   Wed Aug 26 16:41:09 CEST 2026
   Wed Aug 26 14:41:09 UTC 2026
   ```

**Comprobá tu comprensión**

1. La línea 3 de la salida de `timedatectl` muestra `RTC time` *sin* sufijo de zona horaria. ¿Por qué `timedatectl` se niega a etiquetarlo, y qué te dice la línea `RTC in local TZ: no` sobre cómo debe interpretarse ese número?
2. `date` no necesitó privilegios, `hwclock --show` sí. Explicá la diferencia en términos de qué lee cada comando.
3. En el paso 5, `date +%s` y `date -u +%s` imprimirían exactamente el mismo número. ¿Por qué `-u` carece de sentido para `%s` pero sí lo tiene para `%H:%M`?
4. Tu VM estuvo apagada durante una semana. ¿Cuál de los dos relojes avanzó durante esa semana, y cuál es el autoritativo en el siguiente arranque?

---

## Ejercicio 2 — `date`: formateo, parseo y ajuste

6. Practicá los especificadores de formato que aparecen en scripts reales y en el examen:

   ```bash
   date '+%Y-%m-%d %H:%M:%S'        # sortable log stamp
   date +%Y%m%d-%H%M%S              # filename-safe stamp
   date -Is                         # ISO 8601, seconds precision
   date -R                          # RFC 5322 (email/HTTP style)
   date -u +%Y-%m-%dT%H:%M:%SZ      # the canonical UTC "Zulu" form
   date '+%j day-of-year, week %V, %A'
   ```

   ```
   2026-08-26 16:41:10
   20260826-164110
   2026-08-26T16:41:10+02:00
   Wed, 26 Aug 2026 16:41:10 +0200
   2026-08-26T14:41:10Z
   238 day-of-year, week 35, Wednesday
   ```

7. Usá el parser de fechas relativas (`-d` / `--date`), que es una extensión de GNU coreutils y extremadamente común en scripts de backup y retención:

   ```bash
   date -d 'now + 90 days' +%F
   date -d 'yesterday' +%F
   date -d '2026-03-29 01:59:59 UTC' +'%F %T %Z'
   date -d 'next friday 09:00' -Is
   ```

   ```
   2026-11-24
   2026-08-25
   2026-03-29 02:59:59 CET
   2026-08-28T09:00:00+02:00
   ```

8. Ajustá el reloj del sistema manualmente. Primero observá qué pasa en un host donde hay un servicio NTP corriendo:

   ```bash
   sudo date -s '2026-08-26 16:45:00'
   ```

   ```
   Wed Aug 26 16:45:00 CEST 2026
   ```

   ```bash
   sudo timedatectl set-time '2026-08-26 16:45:00'
   ```

   ```
   Failed to set time: Automatic time synchronization is enabled
   ```

9. Ajustá el reloj en términos absolutos de UTC, que es lo que querés en un script que no debe depender de la zona horaria de la máquina:

   ```bash
   sudo date -u -s '2026-08-26 14:45:00'
   date
   ```

**Comprobá tu comprensión**

5. `date -s` tuvo éxito mientras que `timedatectl set-time` fue rechazado en el mismísimo host, con un segundo de diferencia. ¿De qué te está protegiendo `timedatectl`, y por qué no puede protegerte de `date -s`?
6. En el paso 7, `2026-03-29 01:59:59 UTC` se imprimió como `02:59:59 CET`, pero agregar un segundo más en `Europe/Madrid` imprimiría `04:00:00 CEST`. ¿Qué pasó, y qué demuestra eso sobre la aritmética de hora de pared?
7. Escribí un único comando que imprima el segundo de época en el que un certificado TLS que expira el `2027-01-15 23:59:59 UTC` deja de ser válido.
8. ¿Por qué `date +%s` es una clave más segura para calcular un intervalo transcurrido en un script que `date +%H%M%S`?

---

## Ejercicio 3 — Zonas horarias: `/usr/share/zoneinfo`, `/etc/localtime`, `TZ`

La base de datos de zonas horarias (IANA `tzdata`) es un conjunto de archivos **binarios compilados** bajo `/usr/share/zoneinfo/`, cada uno describiendo los desplazamientos respecto de UTC y las transiciones de horario de verano de una zona a lo largo de la historia. El valor por defecto del sistema se selecciona mediante `/etc/localtime`; una anulación por proceso es la variable de entorno `TZ`.

10. Explorá la base de datos e inspeccioná la selección actual:

    ```bash
    ls /usr/share/zoneinfo | head
    ls /usr/share/zoneinfo/America/Argentina/
    file /usr/share/zoneinfo/Europe/Madrid
    ls -l /etc/localtime
    ```

    ```
    Africa
    America
    Antarctica
    Arctic
    Asia
    Atlantic
    Australia
    Brazil
    ...
    Buenos_Aires  Catamarca  Cordoba  Jujuy  La_Rioja  Mendoza  ...

    /usr/share/zoneinfo/Europe/Madrid: timezone data, version 2, 7 gmt time flags, ...

    lrwxrwxrwx 1 root root 33 Aug 20 09:12 /etc/localtime -> /usr/share/zoneinfo/Europe/Madrid
    ```

11. Anulá la zona horaria para un único comando usando `TZ` — sin root, sin cambio de configuración:

    ```bash
    date
    TZ='UTC' date
    TZ='America/Argentina/Buenos_Aires' date
    TZ='Asia/Tokyo' date '+%F %T %Z (%z)'
    ```

    ```
    Wed Aug 26 16:45:20 CEST 2026
    Wed Aug 26 14:45:20 UTC 2026
    Wed Aug 26 11:45:20 -03 2026
    2026-08-27 04:45:20 JST (+0900)
    ```

12. Inspeccioná las reglas de transición de horario de verano con `zdump`, la herramienta que lee un archivo zoneinfo directamente:

    ```bash
    zdump Europe/Madrid
    zdump -v Europe/Madrid | grep 2026
    ```

    ```
    Europe/Madrid  Wed Aug 26 16:45:25 2026 CEST

    Europe/Madrid  Sun Mar 29 00:59:59 2026 UT = Sun Mar 29 01:59:59 2026 CET isdst=0 gmtoff=3600
    Europe/Madrid  Sun Mar 29 01:00:00 2026 UT = Sun Mar 29 03:00:00 2026 CEST isdst=1 gmtoff=7200
    Europe/Madrid  Sun Oct 25 00:59:59 2026 UT = Sun Oct 25 02:59:59 2026 CEST isdst=1 gmtoff=7200
    Europe/Madrid  Sun Oct 25 01:00:00 2026 UT = Sun Oct 25 02:00:00 2026 CET  isdst=0 gmtoff=3600
    ```

13. Cambiá la zona horaria del sistema. La forma moderna y neutral respecto de la distribución:

    ```bash
    timedatectl list-timezones | grep -i madrid
    sudo timedatectl set-timezone America/Argentina/Buenos_Aires
    ls -l /etc/localtime
    date
    ```

    ```
    Europe/Madrid
    lrwxrwxrwx 1 root root 51 Aug 26 16:46 /etc/localtime -> ../usr/share/zoneinfo/America/Argentina/Buenos_Aires
    Wed Aug 26 11:46:02 -03 2026
    ```

14. Reproducí el mismo cambio de la forma tradicional, e inspeccioná el archivo de nombre propio de la familia Debian:

    ```bash
    sudo ln -sf /usr/share/zoneinfo/Europe/Madrid /etc/localtime
    cat /etc/timezone 2>/dev/null || echo '(no /etc/timezone on this distribution)'
    ```

    En Debian/Ubuntu también refrescarías el archivo de nombre — nunca lo edites por sí solo:

    ```bash
    sudo dpkg-reconfigure tzdata     # interactive; rewrites /etc/timezone AND /etc/localtime
    ```

    Y el asistente interactivo que sólo *sugiere* un valor:

    ```bash
    tzselect
    ```

    ```
    Please identify a location so that time zone rules can be set correctly.
    Please select a continent, ocean, "coord", "TZ", "time", or "Ctrl-D" to quit:
     1) Africa
     2) Americas
    ...
    You can make this change permanent for yourself by appending the line
            TZ='Europe/Madrid'; export TZ
    to the file '.profile' in your home directory
    ```

15. Verificá que un servicio en ejecución **no** adopta el cambio:

    ```bash
    sudo timedatectl set-timezone UTC
    journalctl -n 3 --no-pager        # journald re-reads it; long-lived daemons often do not
    ```

**Comprobá tu comprensión**

9. `/etc/localtime` y `/etc/timezone` codifican ambos "la zona horaria del sistema". ¿Qué se almacena en cada uno, cuál consultan realmente las funciones de la biblioteca C, y qué se rompe si difieren?
10. `tzselect` imprimió una sugerencia en lugar de cambiar nada. ¿Por qué es ése el comportamiento correcto, y qué dos comandos *sí* cambian el valor por defecto del sistema?
11. `TZ='Asia/Tokyo' date` imprimió una fecha un día adelantada. ¿Cambió el reloj del sistema? Explicá qué hizo la biblioteca C con `TZ`.
12. A partir de la salida de `zdump` del paso 12: ¿cuántas veces marca el reloj de pared `2026-10-25 02:30:00` en Madrid, y qué implica eso para un trabajo de `cron` programado a las `30 2 * * *`?
13. `timedatectl set-timezone` necesitó root pero `TZ=...` no. Explicá el alcance de cada cambio.

---

## Ejercicio 4 — El reloj de hardware, `/etc/adjtime` y UTC vs LOCAL

16. Leé el archivo de configuración del RTC. Este archivo de tres líneas es todo el estado persistente de `hwclock`:

    ```bash
    cat /etc/adjtime
    ```

    ```
    0.000000 1756219268 0.000000
    1756219268
    UTC
    ```

    Campo por campo:

    | Posición | Significado |
    |---|---|
    | línea 1, campo 1 | **factor de deriva** — error sistemático del RTC en segundos ganados por día |
    | línea 1, campo 2 | época de la última vez que `hwclock` ajustó o fijó el RTC |
    | línea 1, campo 3 | fracción de segundo restante aún no aplicada |
    | línea 2 | época de la última **calibración** (`--set` / `--systohc`), `0` si nunca |
    | línea 3 | `UTC` o `LOCAL` — cómo debe interpretarse el valor del RTC |

17. Copiá el reloj del sistema **al** RTC, y después el RTC **al** reloj del sistema:

    ```bash
    sudo hwclock --systohc          # equivalent: hwclock -w  ("write")
    sudo hwclock --hctosys          # equivalent: hwclock -s  ("set from hardware")
    ```

18. Fijá el RTC a un valor explícito sin tocar el reloj del sistema, y después observá la divergencia:

    ```bash
    sudo hwclock --set --date='2026-08-26 12:00:00'
    date; sudo hwclock --show
    ```

    ```
    Wed Aug 26 16:47:31 CEST 2026
    2026-08-26 12:00:04.117482+02:00
    ```

19. Cambiá la interpretación del RTC a hora local y observá cómo el mismo registro de hardware cambia de significado:

    ```bash
    sudo timedatectl set-local-rtc 1
    tail -1 /etc/adjtime
    timedatectl
    ```

    ```
    LOCAL
                   Local time: Wed 2026-08-26 16:48:03 CEST
               Universal time: Wed 2026-08-26 14:48:03 UTC
                     RTC time: Wed 2026-08-26 16:48:03
                    Time zone: Europe/Madrid (CEST, +0200)
    System clock synchronized: yes
                  NTP service: active
              RTC in local TZ: yes

    Warning: The system is configured to read the RTC time in the local time zone.
             This mode cannot be fully supported. It will create various problems
             with time zone changes and daylight saving time adjustments. ...
    ```

20. Restaurá la configuración sensata:

    ```bash
    sudo timedatectl set-local-rtc 0 --adjust-system-clock
    tail -1 /etc/adjtime
    sudo hwclock --systohc --utc
    ```

21. Inspeccioná quién más escribe el RTC. Con `chrony`, lo hace el kernel:

    ```bash
    grep -E '^(rtcsync|rtcfile|rtconutc)' /etc/chrony/chrony.conf /etc/chrony.conf 2>/dev/null
    ```

    ```
    /etc/chrony.conf:rtcsync
    ```

**Comprobá tu comprensión**

14. La línea 3 de `/etc/adjtime` dice `UTC`, y el registro del RTC contiene `14:48:03` mientras que `date` dice `16:48:03`. ¿Están de acuerdo los relojes? Mostrá el razonamiento.
15. Una máquina con arranque dual con Windows muestra la hora correcta en Windows y una hora desplazada dos horas en Linux en cada arranque. ¿Qué línea de `/etc/adjtime` explica esto, y cuáles son las dos soluciones posibles (una en cada sistema operativo)?
16. ¿Cuál es la diferencia entre `hwclock --systohc` y `hwclock --hctosys`? ¿Cuál se ejecuta implícitamente al apagar en un host con systemd, y cuál es en gran medida obsoleto en el arranque, y por qué?
17. `hwclock --adjust` existe pero no lo ejecutaste. ¿Para qué usa el factor de deriva, y por qué se vuelve activamente dañino en un host que ejecuta `chronyd` con `rtcsync`?
18. Explicá por qué `RTC in local TZ: yes` "no puede ser soportado plenamente", usando la transición de octubre del Ejercicio 3 como ejemplo.

---

## Ejercicio 5 — `systemd-timesyncd`: el cliente SNTP mínimo

`systemd-timesyncd` es **sólo un cliente SNTP** — consulta un servidor a la vez, no tiene modo servidor, y no implementa ninguno de los algoritmos de selección de reloj de NTP. Es el valor por defecto en las imágenes de escritorio de Debian/Ubuntu. No puede coexistir con `chronyd` ni con `ntpd`.

22. Determiná qué demonio de hora está realmente a cargo:

    ```bash
    timedatectl show --property=NTP --property=NTPSynchronized
    systemctl is-active systemd-timesyncd chronyd chrony ntpd ntpsec 2>/dev/null
    ```

    ```
    NTP=yes
    NTPSynchronized=yes
    active
    inactive
    inactive
    inactive
    inactive
    ```

23. Leé su configuración y los valores por defecto compilados:

    ```bash
    grep -vE '^\s*(#|$)' /etc/systemd/timesyncd.conf
    systemd-analyze cat-config systemd/timesyncd.conf | grep -E '^(NTP|FallbackNTP|RootDistanceMaxSec|PollInterval)'
    ```

    ```
    [Time]
    NTP=time.cloudflare.com
    FallbackNTP=0.debian.pool.ntp.org 1.debian.pool.ntp.org
    ```

24. Inspeccioná el estado de sincronización en vivo:

    ```bash
    timedatectl timesync-status
    ```

    ```
           Server: 162.159.200.1 (time.cloudflare.com)
    Poll interval: 34min 8s (min: 32s; max 34min 8s)
             Leap: normal
          Version: 4
          Stratum: 3
        Reference: A29FC87B
    Precision: 1us (-20)
    Root distance: 12.345ms (max: 5s)
           Offset: +291us
            Delay: 11.204ms
           Jitter: 1.417ms
     Packet count: 9
        Frequency: -13.483ppm
    ```

25. Activá y desactivá la sincronización, y confirmá el efecto:

    ```bash
    sudo timedatectl set-ntp false
    timedatectl | grep -E 'synchronized|NTP service'
    sudo timedatectl set-ntp true
    systemctl is-active systemd-timesyncd
    ```

26. Reemplazalo por `chrony` — notá que la instalación normalmente enmascara `timesyncd` automáticamente:

    ```bash
    sudo systemctl disable --now systemd-timesyncd
    sudo systemctl enable --now chronyd 2>/dev/null || sudo systemctl enable --now chrony
    timedatectl | grep 'NTP service'
    ```

**Comprobá tu comprensión**

19. `timedatectl set-ntp true` no nombró ningún demonio, y sin embargo se inició una unidad específica. ¿Cómo decide `systemd-timedated` cuál habilitar?
20. `timesync-status` informa `Root distance: 12.345ms (max: 5s)`. ¿Qué mide la distancia a la raíz, y qué hace `systemd-timesyncd` si supera `RootDistanceMaxSec`?
21. Dá dos requisitos concretos de producción que `systemd-timesyncd` no puede satisfacer pero `chrony` sí.
22. ¿Por qué `chronyd` y `systemd-timesyncd` se niegan a ejecutarse simultáneamente? Nombrá el recurso por el que compiten tanto a nivel de red como a nivel de kernel.

---

## Ejercicio 6 — `chrony`: `chronyd`, `chrony.conf`, `chronyc`

27. Localizá y leé la configuración (la ruta es `/etc/chrony.conf` en la familia RHEL, `/etc/chrony/chrony.conf` en la familia Debian):

    ```bash
    CHRONY_CONF=$(ls /etc/chrony.conf /etc/chrony/chrony.conf 2>/dev/null | head -1)
    grep -vE '^\s*(#|$)' "$CHRONY_CONF"
    ```

    ```
    pool 2.debian.pool.ntp.org iburst
    driftfile /var/lib/chrony/chrony.drift
    makestep 1.0 3
    rtcsync
    keyfile /etc/chrony/chrony.keys
    ntsdumpdir /var/lib/chrony
    leapsectz right/UTC
    logdir /var/log/chrony
    ```

    | Directiva | Efecto |
    |---|---|
    | `server HOST iburst` | una fuente específica; `iburst` envía 4 paquetes rápidos al inicio para converger en segundos en vez de minutos |
    | `pool NAME iburst` | resuelve a muchas direcciones, mantiene un conjunto de trabajo, reemplaza a los miembros inalcanzables |
    | `driftfile PATH` | persiste el error medido del oscilador (ppm) para que el siguiente arranque ya sea preciso |
    | `makestep THRESHOLD LIMIT` | **saltar** (step) en lugar de deslizar si el desvío supera `THRESHOLD` segundos, sólo durante las primeras `LIMIT` actualizaciones |
    | `rtcsync` | habilita el "modo de 11 minutos" del kernel, que copia el reloj del sistema al RTC |
    | `allow SUBNET` | actuar como servidor para esa subred (por defecto: no servir a nadie) |
    | `local stratum 10` | seguir sirviendo con un estrato sintético cuando se pierden todos los servidores superiores — un repliegue de isla aislada |

28. Consultá la visión que el propio demonio tiene de su disciplina:

    ```bash
    chronyc tracking
    ```

    ```
    Reference ID    : A29FC87B (time.cloudflare.com)
    Stratum         : 4
    Ref time (UTC)  : Wed Aug 26 14:52:11 2026
    System time     : 0.000023145 seconds fast of NTP time
    Last offset     : +0.000012345 seconds
    RMS offset      : 0.000103456 seconds
    Frequency       : 13.483 ppm slow
    Residual freq   : +0.001 ppm
    Skew            : 0.123 ppm
    Root delay      : 0.012345678 seconds
    Root dispersion : 0.001234567 seconds
    Update interval : 64.2 seconds
    Leap status     : Normal
    ```

29. Listá las fuentes y leé el estado de selección:

    ```bash
    chronyc sources -v
    ```

    ```
      .-- Source mode  '^' = server, '=' = peer, '#' = local clock.
     / .- Source state '*' = current best, '+' = combined, '-' = not combined,
    | /             'x' = may be in error, '~' = too variable, '?' = unusable.
    ||                                                 .- xxxx [ yyyy ] +/- zzzz
    ||      Reachability register (octal) -.           |  xxxx = adjusted offset,
    ||      Log2(Polling interval) --.      |          |  yyyy = measured offset,
    ||                                \     |          |  zzzz = estimated error.
    ||                                 |    |           \
    MS Name/IP address         Stratum Poll Reach LastRx Last sample
    ===============================================================================
    ^* 162.159.200.1                 3   6   377    21    +12us[  +14us] +/-   11ms
    ^+ 51.15.191.239                 2   6   377    23  -1234us[-1232us] +/-   28ms
    ^- 194.58.204.148                2   6   377    19  +8901us[+8903us] +/-   41ms
    ^? 185.125.190.56               16   6     0     -     +0ns[   +0ns] +/-    0ns
    ```

30. Mirá las estadísticas por fuente usadas para estimar la frecuencia:

    ```bash
    chronyc sourcestats -v
    ```

    ```
    Name/IP Address            NP  NR  Span  Frequency  Freq Skew  Offset  Std Dev
    ==============================================================================
    162.159.200.1              18   9   17m     +0.021      0.187    +14us    98us
    51.15.191.239              17  10   16m     -0.104      0.412  -1232us   331us
    ```

31. Inspeccioná una asociación a nivel de paquete, y comprobá la actividad del demonio:

    ```bash
    chronyc ntpdata 162.159.200.1 | head -20
    chronyc activity
    ```

    ```
    8 sources online
    0 sources offline
    0 sources doing burst (return to online)
    0 sources doing burst (return to offline)
    0 sources with unknown address
    ```

32. Forzá una corrección inmediata y agregá una fuente en tiempo de ejecución (los comandos en tiempo de ejecución requieren autorización, de ahí `-a` o ejecutarlos como root sobre el socket Unix):

    ```bash
    sudo chronyc makestep
    sudo chronyc add server time.cloudflare.com iburst
    sudo chronyc burst 4/4
    sudo chronyc sources
    ```

    ```
    200 OK
    200 OK
    200 OK
    ```

33. Usá los modos de una sola vez, que son el reemplazo moderno de `ntpdate`:

    ```bash
    sudo systemctl stop chronyd
    sudo chronyd -Q 'pool pool.ntp.org iburst'    # measure only, do NOT touch the clock
    sudo chronyd -q  'pool pool.ntp.org iburst'   # set the clock once, then exit
    sudo systemctl start chronyd
    ```

    ```
    2026-08-26T14:53:40Z chronyd version 4.5 starting (+CMDMON +NTP ...)
    2026-08-26T14:53:44Z System clock wrong by -1.428301 seconds (ignored)
    2026-08-26T14:53:44Z chronyd exiting
    ```

**Comprobá tu comprensión**

23. En el paso 29, la fuente `194.58.204.148` está marcada con `-`. ¿Está rota? ¿Cuál es la diferencia entre `-`, `x` y `?` en esa columna?
24. `Reach` marca `377`. ¿En qué base está ese número, cuántos sondeos resume, y qué significaría `357`?
25. `makestep 1.0 3` está en la configuración, y sin embargo en el paso 33 `chronyd -Q` se negó a corregir un error de 1,4 segundos. Conciliá ambas observaciones.
26. Explicá la diferencia práctica entre **saltar** (step) y **deslizar** (slew) el reloj, y nombrá una clase de aplicación que se corrompe con un salto hacia atrás pero tolera un deslizamiento.
27. `chronyc tracking` informa `Stratum: 4` mientras que `sources` muestra el servidor seleccionado en estrato 3. ¿De dónde sale el salto extra, y qué significa `Stratum: 16` en cualquier lugar de NTP?
28. ¿Por qué el `driftfile` hace que un *arranque en frío sin red* sea más preciso de lo que sería de otro modo?

---

## Ejercicio 7 — El `ntpd` clásico, `ntpq` y `ntpdate`

La implementación de referencia `ntpd` (y su bifurcación `ntpsec`) sigue siendo la base del examen. No lo instales junto con `chrony`.

34. Leé un `/etc/ntp.conf` típico:

    ```bash
    grep -vE '^\s*(#|$)' /etc/ntp.conf
    ```

    ```
    driftfile /var/lib/ntp/ntp.drift
    restrict default kod nomodify notrap nopeer noquery limited
    restrict 127.0.0.1
    restrict ::1
    restrict 192.168.10.0 mask 255.255.255.0 nomodify notrap
    pool 0.pool.ntp.org iburst
    server 192.168.10.1 iburst prefer
    server 127.127.1.0
    fudge  127.127.1.0 stratum 10
    ```

    | Directiva | Efecto |
    |---|---|
    | `server HOST [iburst] [prefer]` | un servidor superior; `prefer` sesga la selección hacia él |
    | `pool NAME iburst` | conjunto dinámico de servidores basado en DNS |
    | `driftfile PATH` | error de frecuencia persistido, escrito aproximadamente cada hora |
    | `restrict ... noquery nomodify` | control de acceso — `noquery` bloquea `ntpq`/`ntpdc` desde ese par, `nomodify` bloquea la reconfiguración en tiempo de ejecución |
    | `server 127.127.1.0` + `fudge ... stratum 10` | el **controlador de reloj local**: seguir sirviendo en un estrato pobre cuando se está aislado |

35. Consultá la lista de pares — siempre con `-n` primero, para que los fallos de DNS no puedan hacerse pasar por fallos de NTP:

    ```bash
    ntpq -pn
    ```

    ```
         remote           refid      st t when poll reach   delay   offset  jitter
    ==============================================================================
    *162.159.200.1   10.176.6.109     3 u   35   64  377    9.123   -0.234   0.456
    +51.15.191.239   193.204.114.232  2 u   41   64  377   18.456   +0.789   1.012
    -194.58.204.148  .GPS.            1 u   12   64  377   45.678  +12.345   2.345
     185.125.190.56  .INIT.          16 u    -   64    0    0.000   +0.000   0.000
    x203.0.113.7     .STEP.          16 u   19   64  377   31.002 +998.123  15.771
    ```

    El primer carácter es el **código de recuento** (tally code):

    | Código | Significado |
    |---|---|
    | (espacio) | rechazado — inalcanzable, o falló una comprobación de sanidad |
    | `x` | falseticker — el algoritmo de intersección demostró que está equivocado |
    | `-` | valor atípico descartado por el algoritmo de agrupamiento |
    | `+` | superviviente, elegible para el algoritmo de combinación |
    | `#` | bueno, pero no entre los primeros seis por distancia de sincronización |
    | `*` | **par del sistema** — el que actualmente disciplina el reloj |
    | `o` | par del sistema, disciplinado mediante una señal PPS |

36. Leé las variables del propio demonio:

    ```bash
    ntpq -c rv
    ```

    ```
    associd=0 status=0615 leap_none, sync_ntp, 1 event, clock_sync,
    version="ntpd 4.2.8p17@1.4004-o", processor="x86_64", system="Linux/6.8.0",
    leap=00, stratum=4, precision=-24, rootdelay=21.004, rootdisp=38.112,
    refid=162.159.200.1, reftime=ec6a1f3c.9a3b1e50, clock=ec6a1f78.10c4a2f1,
    peer=41234, tc=6, mintc=3, offset=-0.234, frequency=-13.483, sys_jitter=0.456,
    clk_jitter=0.311, clk_wander=0.021
    ```

37. Consultá un servidor **sin** ajustar nada — el paso seguro de reconocimiento antes de cualquier corrección:

    ```bash
    ntpdate -q pool.ntp.org
    # or, on ntpsec:
    ntpdig -d pool.ntp.org
    ```

    ```
    server 162.159.200.1, stratum 3, offset -1.428301, delay 0.03212
    server 51.15.191.239, stratum 2, offset -1.427905, delay 0.04117
    26 Aug 16:55:02 ntpdate[4711]: adjust time server 162.159.200.1 offset -1.428301 sec
    ```

38. Corregí un desvío grande en el arranque. `ntpdate` está obsoleto; los equivalentes soportados son:

    ```bash
    sudo systemctl stop ntpd
    sudo ntpd -gq                 # -g: allow one step of any size; -q: quit after setting
    sudo sntp -sS pool.ntp.org    # ntpsec's step-if-needed one-shot
    sudo systemctl start ntpd
    ```

39. Confirmá que el demonio está escuchando donde esperás, y que el protocolo puede salir del host:

    ```bash
    sudo ss -lunp | grep ':123'
    sudo firewall-cmd --list-services 2>/dev/null | tr ' ' '\n' | grep -x ntp
    ```

    ```
    UNCONN 0 0        0.0.0.0:123       0.0.0.0:*    users:(("ntpd",pid=880,fd=20))
    UNCONN 0 0           [::]:123          [::]:*    users:(("ntpd",pid=880,fd=21))
    ```

**Comprobá tu comprensión**

29. En el paso 35, el servidor de estrato 1 respaldado por GPS `194.58.204.148` fue rechazado con `-` mientras que se eligió como par del sistema un servidor de estrato 3. ¿Por qué "gana el estrato más bajo" es el modelo mental equivocado?
30. ¿Qué significa el `refid` `.INIT.`, y en qué se diferencia de `.STEP.`? ¿Qué te diría un refid de `.GPS.` o `.PPS.` sobre ese par?
31. `reach` del último par es `0` y `when` es `-`. ¿Qué única hipótesis explica ambos campos, y qué comando del paso 39 la pone a prueba?
32. Explicá por qué `ntpd` necesita el flag `-g` en el arranque. ¿Cuál es el umbral de pánico, y qué hace `ntpd` sin `-g` cuando se supera?
33. Un host de monitorización ejecuta `ntpq -pn <server>` contra un par y obtiene `***Server reports a permission error`. ¿Qué directiva del `/etc/ntp.conf` de ese par es la responsable, y por qué es el valor por defecto?
34. ¿Por qué `restrict default ... noquery limited` importa para la seguridad, y no sólo para la higiene? (Pensá en lo que un atacante fuera de la ruta puede hacer con una dirección de origen falsificada y una respuesta NTP grande.)

---

## Ejercicio 8 — Laboratorio de diagnóstico: rompelo, después reparalo

40. **Tomá una instantánea del estado sano** para poder demostrar la reparación:

    ```bash
    date -u -Is; sudo hwclock --show; cat /etc/adjtime; chronyc tracking | head -3
    ```

41. **Fallo A — el reloj está muy en el futuro.** Detené el demonio, saltá el reloj hacia adelante, reiniciá, observá:

    ```bash
    sudo systemctl stop chronyd
    sudo date -u -s '2026-09-05 03:00:00'
    sudo systemctl start chronyd
    sleep 20
    chronyc tracking | grep -E 'Leap|System time'
    journalctl -u chronyd -n 10 --no-pager
    ```

    ```
    Aug 26 16:57:02 lab chronyd[5122]: Selected source 162.159.200.1
    Aug 26 16:57:02 lab chronyd[5122]: System clock wrong by -777421.913 seconds
    Aug 26 16:57:02 lab chronyd[5122]: System clock was stepped by -777421.913 seconds
    ```

42. **Fallo B — el RTC está en hora local pero `/etc/adjtime` dice UTC.** Simulá un arranque dual con Windows:

    ```bash
    sudo hwclock --set --date="$(date '+%Y-%m-%d %H:%M:%S')" --utc   # write LOCAL wall time as if UTC
    sudo hwclock --hctosys
    date; timedatectl | grep -E 'Local time|RTC time'
    ```

    Diagnosticá y reparalo:

    ```bash
    tail -1 /etc/adjtime
    sudo timedatectl set-local-rtc 0 --adjust-system-clock
    sudo chronyc makestep
    sudo hwclock --systohc
    ```

43. **Fallo C — UDP/123 está bloqueado.** Bloqueá la salida y observá el síntoma, que es *silencio*, no un error:

    ```bash
    sudo nft add table inet lab 2>/dev/null
    sudo nft add chain inet lab out '{ type filter hook output priority 0; }'
    sudo nft add rule inet lab out udp dport 123 drop
    sudo systemctl restart chronyd; sleep 30
    chronyc sources
    timedatectl | grep synchronized
    ```

    ```
    MS Name/IP address         Stratum Poll Reach LastRx Last sample
    ===============================================================================
    ^? 162.159.200.1                 0   6     0     -     +0ns[   +0ns] +/-    0ns
    ^? 51.15.191.239                 0   6     0     -     +0ns[   +0ns] +/-    0ns
    System clock synchronized: no
    ```

    Demostrá que es la red y no el demonio, y después limpiá:

    ```bash
    sudo timeout 5 ntpdate -q 162.159.200.1 ; echo "exit=$?"
    sudo nft delete table inet lab
    sudo chronyc burst 4/4; sleep 20; chronyc sources
    ```

44. **Fallo D — regresión de zona horaria tras una actualización de `tzdata`.** Verificá la versión de la base de datos y refrescala:

    ```bash
    zdump -v Europe/Madrid | tail -2
    rpm -q tzdata 2>/dev/null || dpkg -l tzdata | tail -1
    sudo dnf update tzdata 2>/dev/null || sudo apt-get install --only-upgrade tzdata
    ```

45. **Restaurá y verificá toda la cadena de extremo a extremo:**

    ```bash
    sudo timedatectl set-timezone Europe/Madrid
    sudo timedatectl set-local-rtc 0
    sudo systemctl enable --now chronyd
    sleep 15
    timedatectl
    chronyc tracking | grep -E 'Stratum|Leap|System time'
    sudo hwclock --systohc
    sudo hwclock --show; date
    ```

**Comprobá tu comprensión**

35. En el Fallo A el log dice `System clock was stepped`, y sin embargo `makestep 1.0 3` limita los saltos a las primeras 3 actualizaciones. ¿Por qué se permitió un salto acá, y qué habría pasado en la *décima* actualización?
36. En el Fallo B, nombrá la cantidad exacta en la que `date` estaba equivocado, expresada en términos del desplazamiento de zona horaria. ¿Habría sido cero el error en `Etc/UTC`?
37. En el Fallo C, `chronyc sources` mostró `Stratum 0` y `Reach 0` para todas las fuentes. ¿Por qué el "estrato 0" de acá *no* es el mismo "estrato 0" que un reloj de referencia de cesio?
38. El Fallo C bloqueó únicamente el hook de **salida** (`output`). Explicá por qué bloquear la petición saliente basta para romper NTP, y qué debe permitir un cortafuegos con estado para que vuelva la respuesta.
39. Aplicaste `hwclock --systohc` al final del paso 45 aunque `rtcsync` está configurado. ¿Fue redundante? ¿Bajo qué condición exacta no lo es?
40. Escribí la secuencia mínima de comandos — tres comandos — que responde "¿es correcta la hora de este host, y quién lo dice?" en un host systemd desconocido.

---

## Fuentes

- LPI, *Exam 101 Objectives, version 5.0* — https://www.lpi.org/our-certifications/exam-101-objectives/
- LPI, *Exam 102 Objectives, version 5.0* (el objetivo 108.1 vive acá) — https://www.lpi.org/our-certifications/exam-102-objectives/
- `date(1)`, GNU coreutils — https://man7.org/linux/man-pages/man1/date.1.html
- `hwclock(8)`, util-linux — https://man7.org/linux/man-pages/man8/hwclock.8.html
- `adjtime_config(5)` — https://man7.org/linux/man-pages/man5/adjtime_config.5.html
- `timedatectl(1)`, systemd — https://www.freedesktop.org/software/systemd/man/latest/timedatectl.html
- `systemd-timesyncd.service(8)` y `timesyncd.conf(5)` — https://www.freedesktop.org/software/systemd/man/latest/systemd-timesyncd.service.html
- Documentación del proyecto chrony (`chronyd`, `chronyc`, `chrony.conf`) — https://chrony-project.org/documentation.html
- NTP Project, *ntpd / ntpq / ntpdate documentation* — https://www.ntp.org/documentation/4.2.8-series/
- NTP Pool Project — https://www.ntppool.org/
- IANA Time Zone Database — https://www.iana.org/time-zones
- RFC 5905, *Network Time Protocol Version 4: Protocol and Algorithms Specification* — https://datatracker.ietf.org/doc/html/rfc5905

---

<details>
<summary><strong>Respuestas — clic para expandir</strong></summary>

### Ejercicio 1

**1.** El RTC es un contador desnudo de seis números (año, mes, día, hora, minuto, segundo) **sin ninguna información de zona horaria** almacenada en el hardware. Su significado proviene enteramente de la línea 3 de `/etc/adjtime`. `timedatectl` lo imprime sin etiqueta porque etiquetarlo sería una afirmación que el hardware no hace; la línea separada `RTC in local TZ: no` aporta la convención que falta — acá, "leé esos dígitos como UTC". Si esa línea dijera `yes`, el valor idéntico del registro significaría en cambio hora local de pared.

**2.** `date` lee el reloj del sistema, que es memoria del kernel expuesta a través de la llamada al sistema `clock_gettime(2)` / vDSO — sin privilegios, y lo bastante barata como para llamarla millones de veces por segundo. `hwclock` lee el chip RTC físico a través del dispositivo de caracteres `/dev/rtc0` (o, en hardware antiguo, mediante puertos de E/S directos), y ese nodo de dispositivo pertenece a `root`. También es lento: `hwclock` se sincroniza con un tick del reloj, así que una lectura tarda hasta un segundo.

**3.** `%s` son segundos desde la época Unix, un conteo absoluto de segundos transcurridos que es independiente de la zona horaria por definición — no hay nada que `-u` pueda cambiar. `%H:%M` es una *representación* de ese conteo en un calendario humano, y representar requiere elegir un desplazamiento; `-u` fuerza ese desplazamiento a cero. Ésta es la distinción central de todo el objetivo: **un instante, muchas representaciones.**

**4.** Sólo avanzó el RTC — el reloj del sistema no existe mientras la máquina está apagada; se crea en el arranque. En el siguiente arranque el kernel inicializa el reloj del sistema a partir del RTC (mediante la opción de kernel `rtc_hctosys` o un `hwclock --hctosys` temprano), así que el RTC es autoritativo exactamente para ese momento, hasta que el demonio NTP obtiene una muestra de red y toma el control.

### Ejercicio 2

**5.** `timedatectl set-time` se niega porque hay un demonio NTP disciplinando el reloj; cualquier valor que fijes será deshecho silenciosamente dentro de un intervalo de sondeo y, peor aún, habrás peleado contra la estimación de frecuencia del demonio, degradándola. No puede protegerte de `date -s` porque `date` no es en absoluto un cliente de systemd — llama a `clock_settime(2)` directamente. El privilegio, no la política, es la única barrera ahí. En producción la secuencia correcta es siempre: detener el demonio, corregir, reiniciar el demonio (o simplemente usar `chronyc makestep`).

**6.** La transición primaveral al horario de verano de Madrid: a las `01:00:00 UTC` del 2026-03-29 el desplazamiento salta de `+01:00` (CET) a `+02:00` (CEST), de modo que la hora local de pared salta directamente de `01:59:59` a `03:00:00`. La hora `02:00:00–02:59:59` **no existe** en esa fecha. Esto demuestra que la aritmética de hora local de pared no es cerrada: "sumar una hora" y "sumar 3600 segundos" son operaciones distintas. Programá y calculá en UTC o en segundos de época; representá en hora local sólo para humanos.

**7.**
```bash
date -u -d '2027-01-15 23:59:59' +%s
```
O equivalentemente, `date -d '2027-01-15T23:59:59Z' +%s`. El sufijo `Z` / el flag `-u` es lo que hace que la respuesta sea independiente de la zona horaria del host.

**8.** `%s` es monótono en el sentido del calendario y no tiene discontinuidades salvo cuando el reloj salta; `%H%M%S` vuelve a cero a medianoche y, en los días de cambio de horario, salta hacia adelante o repite una hora. Una duración calculada a partir de `%H%M%S` puede ser negativa, estar desviada en 3600, o en 86400. (Para medir intervalos que deben sobrevivir incluso a un salto del reloj, la fuente verdaderamente correcta es `CLOCK_MONOTONIC` — en shell, `$SECONDS` o `/proc/uptime`.)

### Ejercicio 3

**9.** `/usr/share/zoneinfo/<Zone>` contiene las **reglas binarias compiladas**; `/etc/localtime` es un enlace simbólico (o una copia) a la que está actualmente en vigor; `/etc/timezone` (sólo en la familia Debian) contiene el **nombre** de la zona como texto plano. `localtime(3)`/`tzset(3)` de glibc leen `/etc/localtime` — eso es lo que determina lo que imprime `date`. `/etc/timezone` es un archivo de contabilidad de Debian consumido por `dpkg-reconfigure tzdata` y algunos instaladores. Si difieren, `date` sigue a `/etc/localtime` mientras que las herramientas de empaquetado y algunas aplicaciones informan el otro valor, y la próxima actualización de `tzdata` puede "restaurar" silenciosamente `/etc/localtime` a partir del nombre obsoleto — que es exactamente por qué nunca se edita `/etc/timezone` a mano.

**10.** `tzselect` es un *asistente puro*: te guía por continente → país → zona e imprime la cadena `TZ`. Cambiar el valor por defecto del sistema es un acto privilegiado y de alcance global, y decidirlo por vos desde un menú interactivo sería sorprendente. Los dos comandos que sí lo cambian son `timedatectl set-timezone <Zone>` y el manual `ln -sf /usr/share/zoneinfo/<Zone> /etc/localtime` (más `dpkg-reconfigure tzdata` en Debian, que hace ambos archivos).

**11.** No — el reloj del sistema (el segundo de época) fue idéntico para los cuatro comandos del paso 11. `TZ` es leída por `tzset(3)` de glibc al inicio del proceso y anula `/etc/localtime` para **ese proceso únicamente**; `date` representó entonces el mismo instante con un desplazamiento `+09:00`, que dio la casualidad de cruzar la medianoche. Alcance: un proceso, una invocación.

**12.** **Dos veces.** En la transición de otoño el reloj retrocede de `03:00 CEST` a `02:00 CET`, así que `02:30:00` ocurre una vez a las `00:30` UTC y otra vez a las `01:30` UTC. Vixie cron ejecuta **una sola vez** un trabajo programado dentro de una hora repetida, y un trabajo programado dentro de una hora *saltada* (primavera) una vez, inmediatamente después del salto — pero el comportamiento difiere entre implementaciones de cron y entre entradas de `cron.d` y del estilo `@hourly`. Para cualquier cosa que no deba ejecutarse dos veces, programá en UTC (`TZ=UTC` en el crontab, o `CRON_TZ=UTC`) o usá un temporizador de systemd, y hacé que el trabajo sea idempotente.

**13.** `TZ=` es por proceso, por invocación, sin privilegios, y desaparece cuando el comando termina. `timedatectl set-timezone` reescribe `/etc/localtime` para todos los procesos que se inicien después, necesita root (mediante polkit), y **no** cambia retroactivamente los demonios ya en ejecución — la mayoría llama a `tzset()` una vez al arrancar y cachea el resultado, así que hay que reiniciar los servicios (o éstos deben manejar `SIGHUP`) para que observen la nueva zona.

### Ejercicio 4

**14.** **Sí, coinciden perfectamente.** `/etc/adjtime` dice `UTC`, así que el valor del registro `14:48:03` *es* UTC. La zona horaria del sistema es `Europe/Madrid`, que en agosto es CEST = UTC+2, de modo que la representación local correcta de ese mismo instante es `16:48:03`. La diferencia de dos horas es el desplazamiento de zona horaria, no un error del reloj.

**15.** La línea 3 — dice `UTC` del lado de Linux mientras que Windows, por defecto, escribe y lee el RTC en **hora local**. Ambos sistemas operativos aplican su propia convención al mismo registro, así que Linux sobrecorrige por el desplazamiento. Dos soluciones:
- En Linux: `sudo timedatectl set-local-rtc 1 --adjust-system-clock` (funciona, pero es el modo sobre el que systemd advierte).
- En Windows (preferida): establecer `HKLM\SYSTEM\CurrentControlSet\Control\TimeZoneInformation\RealTimeIsUniversal` = `dword:00000001`, para que ambos sistemas coincidan en UTC.
La solución del lado de Windows es mejor porque el modo de RTC local no puede representar las transiciones de horario de verano sin ambigüedad (ver respuesta 18).

**16.** `--systohc` (`-w`) copia **sistema → hardware**; `--hctosys` (`-s`) copia **hardware → sistema**. En un host con systemd el RTC se escribe en un apagado limpio (y, con `rtcsync`, de forma continua por el kernel), así que `--systohc` es el que se ejecuta implícitamente. `--hctosys` en el arranque es en gran medida obsoleto porque el kernel mismo inicializa el reloj del sistema a partir del RTC durante el arranque temprano (`CONFIG_RTC_HCTOSYS`), antes de que exista el espacio de usuario — volver a ejecutarlo desde un script de init es redundante y, en un sistema con `local-rtc`, puede ser activamente erróneo.

**17.** `hwclock --adjust` aplica la corrección de deriva acumulada: multiplica el factor de deriva (segundos/día) por el tiempo transcurrido desde el último ajuste y escribe el valor corregido de vuelta al RTC, luego actualiza la línea 1 de `/etc/adjtime`. Es dañino bajo `chronyd` con `rtcsync` porque el kernel *ya* está reescribiendo el RTC cada 11 minutos a partir del reloj del sistema disciplinado por NTP. `hwclock` mediría entonces una "deriva" que en realidad es la propia corrección de NTP, calcularía un factor de deriva espurio, y aplicaría una segunda corrección encima — dos controladores peleando por un mismo registro. Regla: elegí un único dueño del RTC.

**18.** En el modo de RTC local los dígitos del RTC significan "hora local de pared", pero la hora de pared no es función del instante por sí solo — durante la transición de octubre en Madrid, `02:30:00` ocurre dos veces, con una hora de diferencia. Un arranque en cualquiera de esos instantes lee el valor idéntico del registro, de modo que el sistema no puede determinar cuál de los dos instantes es. No hay ningún campo en el hardware para desambiguar, ni forma de saber en el arranque si un sistema operativo previo ya aplicó el desplazamiento de horario de verano. UTC no tiene tal ambigüedad, y por eso es el único modo plenamente soportable.

### Ejercicio 5

**19.** `systemd-timedated` consulta una lista ordenada, compilada en el binario, de unidades de implementaciones NTP conocidas, publicada como archivos `.list` en `/usr/lib/systemd/ntp-units.d/` (cada paquete deposita su propio nombre — `chrony.list`, `ntpsec.list`, `systemd-timesyncd.list`). `set-ntp true` habilita e inicia la **primera unidad disponible** de esa lista fusionada y ordenada, y deshabilita el resto; `set-ntp false` las deshabilita todas. Por eso instalar `chrony` desplaza de forma transparente a `systemd-timesyncd`.

**20.** La distancia a la raíz es la incertidumbre total acumulada hasta la referencia de estrato 0: la mitad del retardo de raíz de ida y vuelta más la dispersión de raíz, más el jitter local — una cota superior de cuán equivocada puede estar la hora del propio servidor. Si supera `RootDistanceMaxSec` (por defecto 5 s), `systemd-timesyncd` trata la muestra como no confiable, **no** la usa para disciplinar el reloj, y pasa a otro servidor; un fallo sostenido significa `NTPSynchronized=no`.

**21.** Dos cualesquiera de: (a) servir la hora a otros hosts — `timesyncd` no tiene modo servidor en absoluto; (b) combinar múltiples fuentes y rechazar falsetickers — `timesyncd` usa un servidor a la vez sin algoritmo de intersección/agrupamiento; (c) relojes de referencia por hardware (GPS/PPS mediante `refclock`); (d) hora autenticada con NTS (RFC 8915), o autenticación por clave simétrica; (e) disciplinar el RTC y manejar retardo asimétrico/marcas de tiempo por hardware para precisión submicrosegundo; (f) manejo preciso de segundos intercalares con `leapsectz`/suavizado (smearing).

**22.** Ambos necesitan enlazarse al puerto UDP 123 como puerto de origen para sus consultas, y ambos llaman a `adjtimex(2)`/`clock_adjtime(2)` para disciplinar el reloj del kernel. Dos controladores PLL independientes escribiendo los mismos registros de frecuencia y desvío del kernel oscilan uno contra el otro, produciendo peor precisión que cualquiera por separado — por eso el empaquetado y el mecanismo de `ntp-units.d` imponen exactamente uno.

### Ejercicio 6

**23.** No, `-` no significa rota. `-` significa que la fuente es alcanzable y sensata pero fue **excluida por el algoritmo de agrupamiento** como valor atípico estadístico — simplemente no está contribuyendo a la estimación combinada en este momento, y puede convertirse en superviviente más adelante. `x` es mucho más fuerte: el algoritmo de intersección ("Marzullo/falseticker") demostró que el intervalo que declara es inconsistente con la mayoría — está *mintiendo* o está gravemente equivocada. `?` significa inutilizable/inalcanzable: aún no hay muestras válidas (`Reach 0`), típicamente problemas de resolución DNS, enrutamiento o cortafuegos.

**24.** `377` es **octal**, es decir binario `11111111` — el registro de alcanzabilidad es un registro de desplazamiento de 8 bits que resume los **últimos 8 sondeos**, un bit cada uno, con el más nuevo entrando por el extremo bajo. `377` = los ocho tuvieron éxito. `357` = octal `011 101 111` → binario `11101111`, lo que significa que el cuarto sondeo más reciente se perdió y el resto llegó; un único paquete perdido, normalmente inofensivo. Un valor que decae hacia `0` (`377 → 376 → 374 → 370 …`) es una fuente que se está yendo.

**25.** `chronyd -Q` es explícitamente el modo de **sólo consulta**: mide el desvío y lo informa, pero nunca llama a `clock_settime`/`adjtimex` — la línea del log incluso dice `(ignored)`. `makestep` es una directiva de configuración para el modo *demonio*; `-Q` anula por diseño todo comportamiento de ajuste del reloj. Usá `-q` (minúscula) cuando realmente querés la corrección de una sola vez, y `-Q` cuando estás diagnosticando un host de producción y no debés perturbarlo.

**26.** Un **salto** (step) escribe un nuevo valor en el reloj instantáneamente — el tiempo puede saltar hacia adelante o, peor, hacia atrás, de modo que un instante puede repetirse y se rompe la monotonía de la hora de pared. Un **deslizamiento** (slew) deja el reloj monótono y sólo cambia su *tasa* (típicamente limitada a 500 ppm, o 0,5 ms/s), dejando que el error se disipe gradualmente; corregir un segundo por deslizamiento tarda unos 33 minutos a esa tasa. Cualquier cosa que use la hora de pared como clave de ordenación se corrompe con un salto hacia atrás: los registros de escritura anticipada (WAL) y las marcas de tiempo MVCC de las bases de datos, los arriendos (leases) de Raft/Paxos (etcd, Consul, ZooKeeper), la validez de tickets Kerberos, la resolución de conflictos "gana la última escritura" de Cassandra, y las comprobaciones de `notBefore` de los certificados TLS. Esos sistemas toleran bien el deslizamiento. De ahí la política estándar `makestep 1.0 3`: permitir un salto sólo durante las primeras actualizaciones tras el arranque, nunca durante la operación en régimen permanente.

**27.** El estrato se define como *uno más que el estrato del servidor con el que te sincronizás*: seleccionar un servidor de estrato 3 hace que este host sea de estrato 4. El estrato 0 es la referencia física (reloj atómico, receptor GPS), el estrato 1 es un host conectado directamente a uno, y la cadena se incrementa por salto hasta 15. **El estrato 16 significa no sincronizado** — un host que no tiene fuente utilizable, y en cuya hora ningún cliente debería confiar. Ver 16 en la salida de `ntpq`/`chronyc` es la señal más clara de "esta fuente es inútil".

**28.** El archivo de deriva almacena el error de frecuencia sistemático medido del oscilador local en ppm (p. ej. `-13.483`, que significa que el cristal atrasa ~13,5 microsegundos por segundo ≈ 1,16 s/día). En el siguiente inicio, `chronyd` aplica esa corrección al kernel **de inmediato**, antes de que exista ninguna muestra de red. Sin red alguna, el reloj deriva entonces con el error *residual* (una fracción de ppm) en lugar del error crudo del oscilador — potencialmente una mejora de cien veces a lo largo de horas o días de aislamiento. También hace mucho más rápida la convergencia posterior al arranque con red, ya que la frecuencia ya es correcta y sólo hay que corregir el desvío.

### Ejercicio 7

**29.** El estrato mide la **distancia al reloj de referencia en saltos**, no la **precisión en tu host**. NTP selecciona según la *distancia de sincronización* — retardo de raíz, dispersión de raíz, jitter y consistencia del desvío — de modo que un servidor de estrato 1 a 250 ms de distancia a través de una ruta congestionada y asimétrica es mucho peor que un servidor de estrato 3 a 9 ms por una ruta simétrica. El servidor de estrato 1 del ejemplo fue rechazado como valor atípico del agrupamiento con un desvío de `+12.345 ms` y un retardo de `45.678 ms`. Consecuencia práctica: preferí servidores *cercanos, bien conectados y diversos* por sobre trofeos de estrato bajo, y configurá siempre al menos cuatro fuentes para que el algoritmo de falsetickers tenga una mayoría con la que trabajar.

**30.** `.INIT.` significa que la asociación existe pero nunca se recibió una respuesta válida — el par está inicializándose o es inalcanzable; siempre acompaña a `stratum 16` y `reach 0`. `.STEP.` significa que el reloj del propio par acaba de saltar, así que está temporalmente inutilizable. `.GPS.` y `.PPS.` son **identificadores de reloj de referencia** en un servidor de estrato 1: `.GPS.` = un receptor GPS que provee la hora del día, `.PPS.` = una señal de pulso por segundo que provee fase precisa (normalmente combinada con una fuente de hora gruesa). Otros comunes: `.CDMA.`, `.DCFa.`, `.LOCL.` (el controlador de reloj local no disciplinado — una señal de alarma si es tu par del sistema).

**31.** Ambos campos dicen "nunca recibimos una respuesta de este par": `reach 0` = los ocho sondeos del registro de desplazamiento fallaron, `when -` = no hay "segundos desde el último paquete recibido" porque nunca se recibió ninguno. Hipótesis única: la petición o la respuesta no está llegando — DNS resolvió a una dirección muerta, el host es inalcanzable, o UDP/123 está filtrado. El `ss -lunp | grep :123` del paso 39 más la comprobación del cortafuegos prueban el lado local; `ntpdate -q <ip>` (paso 37) prueba la ruta de extremo a extremo.

**32.** En el arranque el desvío entre el reloj inicializado desde el RTC y la hora real puede ser arbitrariamente grande — una batería CMOS muerta te da 1970 o 2000. `ntpd` tiene un **umbral de pánico de 1000 segundos** (`tinker panic`): si el desvío lo supera, `ntpd` registra un mensaje diciéndole al operador que fije el reloj manualmente y **termina**, con el razonamiento de que un error así es más probablemente un fallo que una corrección real. `-g` (`--panicgate`) permite exactamente **un** salto de cualquier tamaño, en la primera actualización, tras lo cual el umbral de pánico se aplica normalmente. Por eso los archivos de init de las distribuciones históricamente lanzaban `ntpd -g`, y por eso `ntpd -gq` reemplazó a `ntpdate`.

**33.** `restrict default kod nomodify notrap nopeer noquery limited` — específicamente el flag `noquery`, que bloquea las consultas de control de modo 6/7 (`ntpq`, `ntpdc`) sin dejar de permitir el servicio normal de hora. Es el valor por defecto porque las consultas de control exponen estado interno y, históricamente, porque el `monlist` de modo 7 habilitaba ataques masivos de amplificación (CVE-2013-5211). Para permitir la monitorización desde un host específico, agregá una regla más estrecha: `restrict 192.168.10.5 nomodify notrap` (sin `noquery`), y considerá `restrict source ...` para los pares aprendidos del pool.

**34.** Con UDP no hay handshake, así que un atacante puede falsificar la dirección de origen de la víctima y hacer que tu servidor envíe la respuesta a la víctima — un ataque de **reflexión**. Si la respuesta es mucho más grande que la petición, es además un ataque de **amplificación**; `monlist` producía factores de amplificación de cientos. `noquery` quita esas respuestas de control grandes de la superficie de ataque, y `limited`/`kod` imponen limitación de tasa con paquetes Kiss-o'-Death para que las respuestas de hora ordinarias tampoco puedan usarse como amplificador. Por eso una línea `restrict default` de denegación por defecto más excepciones explícitas `allow`/`restrict` es la única postura correcta — el equivalente en `chrony` es que servir está desactivado a menos que escribas `allow`.

### Ejercicio 8

**35.** `makestep 1.0 3` significa "saltar, en lugar de deslizar, si el desvío supera 1,0 s — pero sólo durante las primeras **3 actualizaciones del reloj** después de que `chronyd` arranca". Reiniciar `chronyd` en el paso 41 reinició ese contador, así que la primera actualización tras el arranque estuvo dentro del margen y un error de 777421 segundos (9 días) se corrigió con un salto. En la décima actualización, saltar ya no estaría permitido: `chronyd` intentaría **deslizarlo**, y a 500 ppm un error de 9 días tarda aproximadamente 49 años en eliminarse — en la práctica el demonio registraría que el reloj está equivocado y el host permanecería sin sincronizar indefinidamente. Ésa es precisamente la razón por la que los errores de reloj en régimen permanente deben corregirse con un `chronyc makestep` explícito, no esperando.

**36.** `date` estaba equivocado exactamente por **el desplazamiento local respecto de UTC** — `+02:00` en Madrid en agosto, es decir dos horas adelantado (los dígitos de la hora local de pared se escribieron en el RTC, luego se leyeron como si fueran UTC, y el desplazamiento se sumó una segunda vez). En `Etc/UTC` el desplazamiento es cero, así que sí, el error habría sido exactamente cero — que es la razón por la que esta clase de error es invisible en servidores configurados en UTC y aparece sólo en escritorios localizados y máquinas de arranque dual.

**37.** Una fuente con `Reach 0` nunca entregó una muestra válida, así que `chronyd` no tiene dato alguno — la columna de estrato muestra el valor inicial/desconocido `0` como marcador de posición, junto con el marcador de estado `?` y los desvíos `+0ns`. El estrato 0 real es un reloj de referencia físico, y un *reloj de referencia nunca aparece como una fila de fuente de red en `chronyc sources`* — aparece en `chronyc sources` sólo mediante una directiva `refclock` con un carácter de modo `#`. Leé la fila completa: `? / 0 / 0 / -` juntos significan "sin contacto", no "conectado a un patrón de cesio".

**38.** NTP es un protocolo de petición/respuesta sobre UDP: el cliente envía un paquete al puerto 123 del servidor y correlaciona la respuesta por la marca de tiempo de transmisión. Descartar la petición saliente significa que nunca puede existir una respuesta, así que bloquear sólo el hook `output` es plenamente suficiente. Para que la respuesta vuelva a través de un cortafuegos con estado, la entrada de seguimiento de conexiones de ese "flujo" UDP debe estar permitida — `nft`/`iptables` necesitan `ct state established,related accept` en la entrada (o `firewall-cmd --add-service=ntp` del lado cliente de un NAT). Notá también que `chronyd` usa por defecto un puerto de origen efímero, mientras que `ntpd` clásicamente usa el puerto de origen 123, lo cual importa para reglas escritas contra puertos en lugar de contra el estado de conntrack.

**39.** Bajo `rtcsync` *suele* ser redundante, ya que el kernel copia el reloj del sistema al RTC cada 11 minutos una vez sincronizado. **No** es redundante cuando: (a) han transcurrido menos de 11 minutos desde la sincronización — exactamente el caso tras el `sleep` de 15 segundos del paso 45; (b) `rtcsync` no está configurado, o estás en `systemd-timesyncd`, que no tiene una directiva equivalente; (c) `chronyd` está gestionando el RTC por sí mismo mediante `rtcfile`/`rtcautotrim` en lugar de delegar en el kernel; (d) estás por forzar un corte de energía y no podés confiar en que un apagado limpio escriba el RTC. Hacerlo explícito cuesta una llamada al sistema y elimina la duda.

**40.**
```bash
timedatectl                    # both clocks, timezone, synchronized yes/no, which service
chronyc tracking               # (or: ntpq -pn) — the offset, the stratum, and the reference ID
chronyc sources -v             # (or: ntpq -pn) — which sources exist, which one is selected, reachability
```
`timedatectl` responde "¿es correcta y hay algo manteniéndola?"; `tracking` responde "¿cuán equivocados estamos y contra qué referencia?"; `sources` responde "¿quién lo dice, y tenemos suficientes fuentes independientes para confiar en la respuesta?". Si `timedatectl` informa `NTP service: n/a`, saltá directamente a `systemctl list-units '*chrony*' '*ntp*' '*timesync*'` para averiguar qué hay instalado, si es que hay algo.

</details>