# 108.1 — Mantener la hora del sistema

**LPIC-1 (101-500 / 102-500, v5.0) — Tema 108: Servicios esenciales del sistema**

---

## 1. El problema arquitectónico: la hora es estado mutable compartido en toda tu flota

Cualquier otro subsistema que operes tiene un dueño. La hora no. `CLOCK_REALTIME` es una variable global, no sincronizada y silenciosamente mutable que todo proceso de todo nodo lee, que ninguna aplicación controla y que no tiene semántica transaccional. Cuando está mal, nada se cae: las cosas se vuelven *sutil y costosamente incorrectas*, y el fallo aflora tres capas más allá de la causa.

### 1.1 Los tres relojes que realmente tiene un sistema Linux

Un ingeniero de producción debe dejar de decir "el reloj" y empezar a nombrar a cuál de tres cosas independientes se refiere:

| Reloj | Fuente | Sobrevive al reinicio | Monótono | Ajustado por NTP | Se lee con |
|---|---|---|---|---|---|
| **Reloj de hardware (RTC)** | Oscilador CMOS con batería en la placa base, `/dev/rtc0` | Sí | No | Solo indirectamente (modo de 11 minutos / `hwclock -w`) | `hwclock`, `/sys/class/rtc/rtc0/time` |
| **Reloj del sistema — `CLOCK_REALTIME`** | Contador del kernel inicializado al arranque desde el RTC, avanzado por la *clocksource* | No | **No — puede saltar hacia atrás** | Sí (salto y deriva controlada) | `clock_gettime(2)`, `date` |
| **Reloj del sistema — `CLOCK_MONOTONIC` / `CLOCK_BOOTTIME`** | La misma clocksource, con origen cero en el arranque | No | **Sí — nunca salta** | Solo en frecuencia (slew), nunca por salto | `clock_gettime(2)` |

La consecuencia más importante de todas, y la que separa un sistema distribuido correcto de uno roto:

> **`CLOCK_REALTIME` no es un reloj; es un valor de consenso distribuido sobre qué hora UTC es ahora mismo.** Nunca midas una duración con él. Nunca lo uses como secuencia monótona. Timeouts, histogramas de latencia, rate limiters, backoff de reintentos, expiración de leases y aritmética de TTL pertenecen todos a `CLOCK_MONOTONIC`.

```console
$ cat > /tmp/clocks.c <<'EOF'
#include <stdio.h>
#include <time.h>
int main(void) {
    struct timespec r, m, b;
    clock_gettime(CLOCK_REALTIME,  &r);
    clock_gettime(CLOCK_MONOTONIC, &m);
    clock_gettime(CLOCK_BOOTTIME,  &b);
    printf("REALTIME  %ld.%09ld\n", r.tv_sec, r.tv_nsec);
    printf("MONOTONIC %ld.%09ld\n", m.tv_sec, m.tv_nsec);
    printf("BOOTTIME  %ld.%09ld\n", b.tv_sec, b.tv_nsec);
    return 0;
}
EOF
$ gcc -O2 -o /tmp/clocks /tmp/clocks.c && /tmp/clocks
REALTIME  1787841125.123456789
MONOTONIC 942317.884512003
BOOTTIME  951204.117338442
```

`BOOTTIME - MONOTONIC` da 8887 s: el tiempo que esta máquina pasó suspendida. Esa diferencia es la razón por la que `CLOCK_MONOTONIC` es el reloj equivocado para cualquier cosa que deba sobrevivir a la tapa de un portátil, y `CLOCK_BOOTTIME` es el correcto.

### 1.2 El catálogo de fallos en producción

La desviación de reloj no produce un stack trace. Produce lo siguiente, y cada entrada ha costado incidentes reales:

| Magnitud de la desviación | Sistemas que se rompen | Síntoma por el que realmente te van a avisar |
|---|---|---|
| **> 30 s** | TOTP / MFA (RFC 6238, paso de 30 s, ±1 ventana) | "MFA rechaza todos los códigos" para los usuarios de un único nodo |
| **> 300 s** | Kerberos / AD (`clockskew = 300` en `krb5.conf`) | `KRB_AP_ERR_SKEW: Clock skew too great`; fallos de autenticación de SSSD en toda la flota |
| **> 900 s** | AWS SigV4, la mayoría de las APIs cloud | `RequestTimeTooSkewed: The difference between the request time and the current time is too large` |
| **Cualquiera, si es hacia atrás** | `nbf`/`iat` de JWT, `notBefore` de TLS | Un certificado o token recién emitido es rechazado como "todavía no válido" por los propios pares *del emisor* |
| **~1 s entre pares** | etcd / Raft | `the clock difference against peer 8211f1d0f64f3269 is too high [1.523s > 1s]` — y luego elección de líder oscilando |
| **Subsegundo, entre nodos** | LWW de Cassandra / DynamoDB, retención de logs de Kafka, trazado distribuido | Pérdida silenciosa de escrituras (last-write-wins elige la escritura *más vieja*), spans con duración negativa, retención borrando los segmentos equivocados |
| **Cualquiera** | `at`, `cron`, correlación de logs, SIEM, facturación | Trabajos omitidos o ejecutados dos veces; cronologías de incidentes que no se pueden reconstruir |
| **Salto hacia atrás de cualquier tamaño** | Cualquier cosa que use `CLOCK_REALTIME` para timeouts | Hilos colgados con un timeout efectivamente infinito |

La última fila es la razón por la que `ntpd` tiene un *umbral de pánico*: corregir un error grande mediante un salto es en sí mismo un riesgo. Ver §6.2.

### 1.3 Por qué la solución no es "ejecutar `ntpdate` al arrancar"

El diseño ingenuo —leer un servidor una vez al arrancar, `settimeofday()`, listo— falla de tres maneras que importan a escala:

1. **La deriva del cristal es continua.** Un cristal RTC/TSC comercial está especificado a ±20–50 ppm. A 50 ppm un nodo gana o pierde **4,3 s/día**: rompe Kerberos en 70 horas desde un arranque limpio.
2. **Saltar es destructivo.** Una corrección única al arrancar es una discontinuidad de `CLOCK_REALTIME` en medio de un sistema en marcha.
3. **Una única fuente es un único punto *de estar equivocado*.** Basta un servidor mal configurado para que todos los clientes se sincronicen fielmente a la hora equivocada. El valor de NTP no es "preguntarle a un servidor"; son los *algoritmos de selección y clustering* que descartan falsetickers (§6.1).

El modelo correcto es un **lazo de control**: medir continuamente el error del oscilador local contra múltiples referencias independientes, estimar su error de *frecuencia* y corregir la frecuencia para que el reloj se mantenga correcto por sí solo entre sondeos. Eso es lo que son `ntpd` y `chronyd`: disciplinadores PLL/FLL, no ajustadores de hora.

---

## 2. Mecánica del cronometraje en el kernel

### 2.1 La clocksource

El kernel no lee el RTC para avanzar el tiempo. Lee un contador de marcha libre, la **clocksource**, y convierte ciclos a nanosegundos.

```console
$ cat /sys/devices/system/clocksource/clocksource0/available_clocksource
kvm-clock tsc acpi_pm
$ cat /sys/devices/system/clocksource/clocksource0/current_clocksource
kvm-clock
```

| Clocksource | Resolución típica | Coste de lectura | Compatible con vDSO | Notas |
|---|---|---|---|---|
| `tsc` | ~0,3 ns | ~15–25 ns (lectura de registro) | **Sí** | Requiere `constant_tsc` + `nonstop_tsc`; la única fuente con rendimiento aceptable |
| `kvm-clock` | ns | ~20–30 ns | Sí | Paravirtualizada; el host propaga su propia disciplina al huésped |
| `hpet` | ~70 ns | **~500–1000 ns (MMIO)** | No | Alternativa de reserva. Una regresión silenciosa de 30× en `clock_gettime()` |
| `acpi_pm` | ~280 ns | **~1000+ ns (E/S por puertos)** | No | Último recurso. Catastrófica para cargas intensivas en llamadas al sistema |
| `arch_sys_counter` | ns | ~20 ns | Sí | Temporizador genérico de ARM64 |

**La trampa de producción.** El kernel ejecuta un *watchdog* que verifica el TSC de forma cruzada. Si encuentra que el TSC de una CPU es inestable, lo degrada en tiempo de ejecución:

```console
$ dmesg -T | grep -iE 'tsc|clocksource'
[Thu Aug 27 03:14:22 2026] clocksource: timekeeping watchdog on CPU3: Marking clocksource 'tsc' as unstable because the skew is too large:
[Thu Aug 27 03:14:22 2026] clocksource:                       'hpet' wd_nsec: 498776745 wd_now: 6d3a91f2
[Thu Aug 27 03:14:22 2026] clocksource:                       'tsc' cs_nsec: 499115281 cs_now: 3f2a8b71c992
[Thu Aug 27 03:14:22 2026] clocksource: Switched to clocksource hpet
```

Como `hpet` no puede servirse desde el vDSO, cada `clock_gettime()` pasa a ser una llamada al sistema real. Un servicio en Go o Java que hace millones de llamadas de marca de tiempo por segundo mostrará un precipicio en la latencia p99 sin ningún cambio a nivel de aplicación. **Añade `dmesg | grep 'Switched to clocksource'` a tu runbook de triaje de nodos.** Este es el diagnóstico de mayor valor de este tema, y no tiene nada que ver con la corrección.

### 2.2 Cómo mueve NTP el reloj en realidad: `adjtimex(2)`

Ni `ntpd` ni `chronyd` llaman a `settimeofday()` en régimen estacionario. Llaman a `adjtimex(2)`, entregando al kernel una corrección de frecuencia y dejando que la propia disciplina NTP del kernel la aplique suavemente.

```console
$ adjtimex --print
         mode: 0
       offset: -12
    frequency: 807567
     maxerror: 16000
     esterror: 254
       status: 8193
time_constant: 7
    precision: 1
    tolerance: 32768000
         tick: 10000
     raw time:  1787841125s 419834112us = 1787841125.419834112
   return value = 0 (clock synchronized)
```

Decodificación de los campos, que es lo que las métricas `node_timex_*` de Prometheus exponen literalmente:

- `frequency` está en unidades de 2⁻¹⁶ ppm. `807567 / 65536 = 12,32 ppm`: este cristal va 12,32 partes por millón lento, y el kernel lo está compensando.
- `status: 8193` = `0x2001` = `STA_PLL (0x0001) | STA_NANO (0x2000)`. **`STA_UNSYNC` es `0x0040`; su ausencia significa que el reloj está disciplinado.**
- `maxerror` crece monótonamente entre actualizaciones a la velocidad de `tolerance`. Cuando supera los 16 s el kernel se declara no sincronizado: esta es la base de la alerta `NodeClockNotSynchronising`.
- `return value = 0` es `TIME_OK`. `5` es `TIME_ERROR` (no sincronizado).

### 2.3 El modo de 11 minutos

Cuando el kernel está disciplinado por NTP (`STA_UNSYNC` a cero), **escribe automáticamente `CLOCK_REALTIME` de vuelta al RTC cada 11 minutos**. Es un comportamiento heredado del diseño original de `ntpd`, y tiene dos consecuencias operativas:

1. Casi nunca necesitas `hwclock --systohc` en una máquina sincronizada. El kernel ya lo está haciendo.
2. La corrección de deriva de `hwclock --adjust` carece de sentido mientras el modo de 11 minutos está activo: el RTC se sobrescribe más rápido de lo que cualquier fichero de deriva puede modelar. El `util-linux` moderno es explícito al respecto, y la mayoría de distribuciones ya no ejecutan corrección de deriva al arrancar.

```console
$ awk '{ printf "status=0x%x  UNSYNC=%s\n", $1, and($1,0x40)?"set":"clear" }' \
    <(adjtimex --print | awk '/status:/{print $2}')
status=0x2001  UNSYNC=clear
```

---

## 3. El reloj de hardware (RTC)

### 3.1 UTC u hora local — una decisión arquitectónica, no una preferencia

El RTC almacena una hora desglosada desnuda, **sin ninguna información de zona horaria**. Que esos dígitos signifiquen UTC u hora local es una convención registrada en `/etc/adjtime`, y el kernel/`hwclock` aplica el `TZ` actual para interpretarlos.

| Contenido del RTC | Correcto para | Modo de fallo |
|---|---|---|
| **UTC** (`hwclock --utc`, el valor por defecto) | **Todo servidor, todo host de contenedores, toda VM en la nube** | Ninguno. Las transiciones de horario de verano son invisibles para el RTC. |
| **Hora local** (`hwclock --localtime`) | Solo escritorios con arranque dual con Windows | El RTC salta en el cambio de horario. Dos sistemas operativos lo "corrigen" cada uno por su lado. Arranca dentro de la hora ambigua de 01:00–02:00 en otoño y el reloj del sistema queda mal en una hora. `timedatectl` advierte de que este modo *no está totalmente soportado y creará diversos problemas*. |

**Regla: los servidores mantienen el RTC en UTC y la zona horaria del sistema en UTC.** La hora local es una cuestión de la capa de presentación que pertenece al navegador del usuario o a la variable de entorno `TZ`, nunca a la flota.

### 3.2 `/etc/adjtime`

```console
$ cat /etc/adjtime
0.000000 1787840000 0.000000
1787840000
UTC
```

| Línea | Campo | Significado |
|---|---|---|
| 1 | `0.000000` | Deriva sistemática, **segundos por día** |
| 1 | `1787840000` | Hora UNIX del último ajuste |
| 1 | `0.000000` | Resto de segundo fraccionario arrastrado |
| 2 | `1787840000` | Hora UNIX de la última calibración (`hwclock --set`/`--systohc`) |
| 3 | `UTC` \| `LOCAL` | **Cómo interpretar los registros del RTC** |

Si este fichero no existe, `hwclock` asume UTC. Si la línea 3 dice `LOCAL` en un servidor, ya encontraste tu bug.

### 3.3 `hwclock` en la práctica

```console
# hwclock --show
2026-08-27 14:32:06.482913+00:00

# hwclock --show --utc --verbose
hwclock from util-linux 2.38.1
System Time: 1787841126.123456
Trying to open: /dev/rtc0
Using the rtc interface to the clock.
Assuming hardware clock is kept in UTC time.
Waiting for clock tick...
...got clock tick
Time read from Hardware Clock: 2026/08/27 14:32:06
Hw clock time : 2026/08/27 14:32:06 = 1787841126 seconds since 1969
Time since last adjustment is 1126 seconds
Calculated Hardware Date: 2026/08/27 14:32:06
2026-08-27 14:32:06.482913+00:00
```

(`seconds since 1969` es genuinamente lo que imprime `hwclock`: un error por uno en la redacción, no en la aritmética.)

| Comando | Dirección | Uso |
|---|---|---|
| `hwclock -r` / `--show` | RTC → stdout | Leer el RTC |
| `hwclock -w` / `--systohc` | **Sistema → RTC** | Persistir un reloj de sistema corregido antes de un reinicio |
| `hwclock -s` / `--hctosys` | **RTC → Sistema** | Inicializar el reloj del sistema en un arranque sin red / aislado |
| `hwclock --set --date="2026-08-27 14:32:00"` | literal → RTC | Ajustar el RTC directamente (poco frecuente) |
| `hwclock --systz` | Aplicar TZ al reloj del sistema | Se usa al arrancar cuando el RTC es `LOCAL` |
| `hwclock --utc` / `--localtime` | — | Declarar la convención del RTC; **reescribe la línea 3 de `/etc/adjtime`** |

Regla mnemotécnica para el examen: **`s` = el sistema es el *destino*** (`--hctosys`), **`w` = escribir en el hardware** (`--systohc`).

La ruta sysfs en crudo, útil cuando `hwclock` no está disponible en una imagen mínima:

```console
$ cat /sys/class/rtc/rtc0/time /sys/class/rtc/rtc0/date /sys/class/rtc/rtc0/hctosys
14:32:06
2026-08-27
1
```

`hctosys=1` significa que este RTC fue el que se usó para inicializar el reloj del sistema al arrancar.

---

## 4. Zonas horarias

### 4.1 El modelo de datos

La base de datos de zonas horarias de IANA (`tzdata`) se compila en ficheros binarios **TZif** bajo `/usr/share/zoneinfo/`. Cada fichero contiene el historial completo de desplazamientos UTC, reglas de horario de verano y abreviaturas de una zona, más una cadena TZ POSIX al final para extrapolar más allá de la última transición registrada.

```console
$ file /usr/share/zoneinfo/Europe/Madrid
/usr/share/zoneinfo/Europe/Madrid: timezone data, version 2, 10 gmt time flags, \
10 std time flags, no leap seconds, 88 transition times, 10 abbreviation chars

$ zdump -v Europe/Madrid | grep 2026
Europe/Madrid  Sun Mar 29 00:59:59 2026 UT = Sun Mar 29 01:59:59 2026 CET isdst=0 gmtoff=3600
Europe/Madrid  Sun Mar 29 01:00:00 2026 UT = Sun Mar 29 03:00:00 2026 CEST isdst=1 gmtoff=7200
Europe/Madrid  Sun Oct 25 00:59:59 2026 UT = Sun Oct 25 02:59:59 2026 CEST isdst=1 gmtoff=7200
Europe/Madrid  Sun Oct 25 01:00:00 2026 UT = Sun Oct 25 02:00:00 2026 CET isdst=0 gmtoff=3600
```

Lee esas cuatro líneas con atención: son todo el problema del horario de verano:

- **El 29 de marzo, de 02:00 a 02:59 hora local no existe.** Un trabajo de cron a las `02:30` no se ejecuta nunca ese día.
- **El 25 de octubre, de 02:00 a 02:59 hora local ocurre dos veces.** Un trabajo de cron a las `02:30` se ejecuta *dos veces*, y dos líneas de log separadas por una hora llevan la misma marca de tiempo local.

Este es el argumento a favor de UTC en servidores, enunciado como hecho y no como preferencia: **la hora civil local no es un orden total.**

### 4.2 Orden de resolución

El kernel no sabe nada de zonas horarias. La resolución ocurre por completo en espacio de usuario, en glibc, por proceso, en este orden:

1. Variable de entorno **`$TZ`**, si está definida.
   - `TZ=Europe/Madrid` — zona con nombre, leída de `/usr/share/zoneinfo`
   - `TZ=:/usr/share/zoneinfo/Asia/Tokyo` — ruta explícita
   - `TZ=CET-1CEST,M3.5.0,M10.5.0/3` — una regla POSIX autocontenida: abreviatura estándar `CET`, **desplazamiento de −1 h expresado con el signo invertido**, abreviatura de horario de verano `CEST`, comenzando el mes 3, semana 5 (= última), día 0 (= domingo), y terminando el mes 10, semana 5, día 0 a las 03:00
   - `TZ=UTC0` o `TZ=""` — UTC
2. **`/etc/localtime`** — debe ser un *enlace simbólico* a `/usr/share/zoneinfo` para que `systemd` informe el nombre de la zona.
3. Alternativa por defecto: UTC.

`/etc/timezone` (Debian/Ubuntu) es una *etiqueta* de texto plano consumida por `dpkg-reconfigure tzdata` y por algunas herramientas. **No afecta a glibc.** Si `/etc/localtime` y `/etc/timezone` discrepan, glibc sigue a `/etc/localtime` y tu gestión de configuración informa del otro: un bug de deriva clásico.

```console
$ ls -l /etc/localtime
lrwxrwxrwx 1 root root 27 Aug 12 09:41 /etc/localtime -> /usr/share/zoneinfo/Etc/UTC

$ cat /etc/timezone
Etc/UTC

$ TZ=Asia/Tokyo date -R
Thu, 27 Aug 2026 23:32:05 +0900

$ TZ=America/Argentina/Buenos_Aires date -R
Thu, 27 Aug 2026 11:32:05 -0300

$ date -R
Thu, 27 Aug 2026 14:32:05 +0000
```

### 4.3 Fijar la zona

```console
# timedatectl list-timezones | grep -i madrid
Europe/Madrid

# timedatectl set-timezone Europe/Madrid
# ls -l /etc/localtime
lrwxrwxrwx 1 root root 33 Aug 27 14:33 /etc/localtime -> /usr/share/zoneinfo/Europe/Madrid
```

Sin systemd o de forma manual:

```console
# ln -sf /usr/share/zoneinfo/Etc/UTC /etc/localtime
# echo 'Etc/UTC' > /etc/timezone          # Debian family
```

Selector interactivo (relevante para el examen, no escribe nada: solo imprime el valor de `TZ`):

```console
$ tzselect
Please identify a location so that time zone rules can be set correctly.
Please select a continent, ocean, "coord", "TZ" or "time".
 1) Africa
 2) Americas
...
#? 8
...
The following information has been given:
        Spain
Therefore TZ='Europe/Madrid' will be used.
...
You can make this change permanent for yourself by appending the line
        TZ='Europe/Madrid'; export TZ
to the file '.profile' in your home directory.
```

**`tzdata` es un conjunto de datos en movimiento.** Los gobiernos cambian las reglas de horario de verano con semanas de preaviso. Un paquete `tzdata` desactualizado es un bug de corrección, no una cuestión de higiene: parchéalo como una actualización de seguridad.

---

## 5. `date` y `timedatectl`

### 5.1 `date`

```console
$ date
Thu Aug 27 14:32:05 UTC 2026

$ date -u
Thu Aug 27 14:32:05 UTC 2026

$ date -Is                      # ISO 8601, second precision
2026-08-27T14:32:05+00:00

$ date -u +%Y-%m-%dT%H:%M:%S.%3NZ
2026-08-27T14:32:05.123Z

$ date +%s                      # UNIX epoch seconds
1787841125

$ date -d @1787841125 -u
Thu Aug 27 14:32:05 UTC 2026

$ date -d 'now + 90 minutes' -Is
2026-08-27T16:02:05+00:00

$ date -d '2026-10-25 02:30:00 Europe/Madrid' -u --iso-8601=seconds
2026-10-25T00:30:00+00:00
```

Ese último es la hora ambigua de otoño; glibc la resuelve silenciosamente hacia la *primera* aparición (la de horario de verano). Si tu aplicación analiza marcas de tiempo locales suministradas por el usuario, ahí es donde vive el bug de pérdida de datos.

**Fijar la hora manualmente** (requiere `CAP_SYS_TIME`):

```console
# date -s "2026-08-27 14:32:00"
Thu Aug 27 14:32:00 UTC 2026
```

El formato de `date --set` (`MMDDhhmmCCYY.ss`) es una alternativa heredada:

```console
# date 082714322026.00
Thu Aug 27 14:32:00 UTC 2026
```

Salvaguardas que conviene interiorizar:

- `date -s` realiza un **salto incondicional**. En un nodo de producción en marcha esto es una discontinuidad de `CLOCK_REALTIME`: ver §6.2.
- Con `chronyd`/`ntpd` en ejecución, tu salto manual será medido como un error y corregido de vuelta dentro de un intervalo de sondeo. Detén primero el demonio, o usa sus propias herramientas.
- `date -s` **no toca el RTC.** Continúa con `hwclock --systohc` si necesitas que sobreviva a un reinicio.

### 5.2 `timedatectl`

La interfaz de systemd que unifica las tres cuestiones: reloj del sistema, RTC y zona horaria.

```console
$ timedatectl
               Local time: Thu 2026-08-27 14:32:05 UTC
           Universal time: Thu 2026-08-27 14:32:05 UTC
                 RTC time: Thu 2026-08-27 14:32:06
                Time zone: Etc/UTC (UTC, +0000)
System clock synchronized: yes
              NTP service: active
          RTC in local TZ: no
```

Las tres líneas que hay que leer como SRE, en orden: **`System clock synchronized`** (¿está `STA_UNSYNC` a cero?), **`NTP service`** (¿hay siquiera un disciplinador en marcha?), **`RTC in local TZ`** (debe ser `no` en un servidor).

```console
# timedatectl set-timezone Etc/UTC
# timedatectl set-ntp true
# timedatectl set-local-rtc 0 --adjust-system-clock
# timedatectl set-time "2026-08-27 14:32:00"
Failed to set time: Automatic time synchronization is enabled
```

Ese error es el comportamiento correcto y merece memorizarse: **`set-time` se rechaza mientras `set-ntp` esté activo.** Desactiva NTP primero, o no fijes la hora a mano.

`set-ntp` no codifica `systemd-timesyncd` de forma fija. Activa la unidad que esté registrada en `/usr/lib/systemd/ntp-units.d/`:

```console
$ cat /usr/lib/systemd/ntp-units.d/*.list
50-chrony.list:chronyd.service
80-systemd-timesyncd.list:systemd-timesyncd.service
```

Detalle de sincronización, cuando la implementación es `systemd-timesyncd`:

```console
$ timedatectl timesync-status
       Server: 185.125.190.56 (ntp.ubuntu.com)
Poll interval: 34min 8s (min: 32s; max 34min 8s)
         Leap: normal
      Version: 4
      Stratum: 2
    Reference: 91C57A2D
    Precision: 1us (-24)
Root distance: 8.169ms (max: 5s)
       Offset: -1.286ms
        Delay: 12.229ms
       Jitter: 2.267ms
 Packet count: 3
    Frequency: -8.203ppm
```

---

## 6. NTP: protocolo y teoría de control

### 6.1 Qué calcula un intercambio NTP

Cuatro marcas de tiempo por transacción:

- **T1** — transmisión del cliente (reloj del cliente)
- **T2** — recepción del servidor (reloj del servidor)
- **T3** — transmisión del servidor (reloj del servidor)
- **T4** — recepción del cliente (reloj del cliente)

```
offset θ = ((T2 − T1) + (T3 − T4)) / 2
delay  δ =  (T4 − T1) − (T3 − T2)
```

La suposición crítica: **δ se reparte por igual entre las dos direcciones.** La asimetría del camino se traduce directamente en error de offset por la mitad de la asimetría. Por eso NTP sobre un enlace WAN congestionado o asimétrico (o a través de una SD-WAN que enruta distinto según la dirección) se estanca en precisión de milisegundos mientras una LAN alcanza decenas de microsegundos, y por eso los requisitos submicrosegundo necesitan PTP con marcado de tiempo por hardware (§9).

Después, por cada fuente, el demonio mantiene:

| Magnitud | Significado | Dónde la ves |
|---|---|---|
| **Estrato (stratum)** | Saltos desde un reloj de referencia. Estrato 0 = la referencia física (GPS, cesio); estrato 1 = directamente conectado; **estrato 16 = no sincronizado** | `st` en `ntpq -p`, `Stratum` en `chronyc tracking` |
| **Offset** | Error estimado del reloj local frente a esta fuente | `offset`, `Last offset` |
| **Delay** | Tiempo de ida y vuelta | `delay`, `Root delay` |
| **Dispersión** | Error máximo acumulado, crece entre sondeos | `Root dispersion` |
| **Jitter** | Variación RMS de los offsets recientes | `jitter`, `RMS offset` |
| **Distancia raíz** | `root_delay/2 + root_dispersion` — la cota superior *demostrable* del error | `Root distance` |
| **Reach** | Registro de desplazamiento de 8 bits de los últimos 8 sondeos, **impreso en octal**. `377` = los 8 tuvieron éxito | `reach` |

Que `reach` sea octal es un detalle favorito de exámenes y entrevistas: `377` octal = `11111111` binario = perfecto. `376` significa que se perdió el sondeo más reciente. `0` significa que nunca se recibió respuesta.

**La selección es todo el objetivo.** `ntpd` ejecuta el algoritmo de intersección de Marzullo sobre los intervalos de corrección de las fuentes `[θ−λ, θ+λ]`, descarta los *falsetickers* cuyo intervalo no se solapa con la mayoría y luego agrupa a los supervivientes. Por eso la regla clásica es:

| Fuentes configuradas | Comportamiento |
|---|---|
| **1** | Sin verificación cruzada. Si miente, la sigues. |
| **2** | El desacuerdo es detectable pero irresoluble: no hay mayoría. |
| **3** | Un falseticker puede quedar en minoría. Mínimo defendible. |
| **4+** | Un falseticker en minoría *y además* una fuente puede estar caída simultáneamente. **El estándar de producción.** |

### 6.2 Salto frente a deriva controlada — el compromiso fundamental

| | **Salto** (`settimeofday`/`clock_settime`) | **Slew** (corrección de frecuencia con `adjtimex`) |
|---|---|---|
| Mecanismo | Salto discontinuo | Hacer correr el reloj un 1–8 % rápido/lento hasta converger |
| Monotonía de `CLOCK_REALTIME` | **Violada** | Preservada |
| Velocidad | Instantáneo | `ntpd`: 500 ppm máximo → **2000 s por cada segundo de error**. `chronyd`: `maxslewrate 83333.333` ppm por defecto → ~12 s por segundo de error |
| Seguro en un sistema en marcha | **No** — rompe timeouts en vuelo, transacciones de BD, mtimes de ficheros | Sí |
| Seguro al arrancar / antes de la carga de trabajo | Sí | Innecesariamente lento |

La regla de ingeniería: **saltar temprano y solo una vez, después derivar controladamente para siempre.**

- `ntpd` salta si el offset supera los **128 ms**; si supera los **1000 s** registra un pánico y sale, salvo que se arranque con `-g` (permitir un gran salto al inicio) o se configure con `tinker panic 0`.
- La directiva `makestep <umbral> <límite>` de `chronyd` es la forma moderna y explícita: `makestep 1.0 3` = "salta si el offset supera 1 s, pero solo durante las 3 primeras actualizaciones del reloj; después, siempre deriva controladamente".

Un nodo que ha estado apagado un mes arrancará con un offset enorme. `makestep 1.0 3` lo corrige instantáneamente *antes* de que arranque la carga de trabajo, y después no vuelve a saltar nunca. `makestep 1.0 -1` (saltar en cualquier momento) es un tiro en el pie en nodos de producción y solo debería usarse en hardware que no tenga RTC en absoluto.

### 6.3 Comparativa de implementaciones

| | **chrony** (`chronyd`/`chronyc`) | **ntpd** (impl. de referencia) | **systemd-timesyncd** | **ntpdate** / `sntp` | **linuxptp** (`ptp4l`/`phc2sys`) |
|---|---|---|---|---|---|
| Rol | Cliente + servidor | Cliente + servidor + par | **Solo cliente (SNTP)** | Cliente de una sola pasada | Cliente/servidor PTP |
| Algoritmo | Regresión lineal sobre una ventana de muestras | PLL/FLL | SNTP simple | Ninguno | BMCA + servo |
| Precisión, LAN | **decenas de µs** | ~100 µs–1 ms | ~ms | segundos | **sub-µs (marcado de tiempo por HW)** |
| Converge tras arranque en frío | **segundos** (`iburst` + `makestep`) | ~15–20 min | minutos | instantáneo (salto inseguro) | segundos |
| Tolera red intermitente | **Sí** — está diseñado para ello | Mal | Mal | N/A | No |
| Tolera máquinas virtuales / relojes inestables | **Sí** | Mal | Mal | N/A | Con `ptp_kvm` |
| Sirve la hora a otros | Sí | Sí | **No** | No | Sí (solo PTP) |
| Soporte de NTS (RFC 8915) | **Sí** | No | No | No | N/A |
| Leap smearing | **Sí** (`smoothtime`) | Solo del lado del servidor | No | No | N/A |
| Huella de memoria | ~2 MB | ~4 MB | ~1 MB | — | ~2 MB |
| Por defecto en | RHEL/Fedora/SUSE, Ubuntu Server (paquete chrony) | Instalaciones heredadas | Ubuntu Desktop, imágenes systemd mínimas | — | Telco/finanzas |
| Estado | **Opción recomendada por defecto** | Mantenido; úsalo solo si necesitas modos broadcast/multicast/autokey/simétrico intercalado | Aceptable para portátiles/appliances; **no para flotas** | **Obsoleto** — no lo uses | Necesario para <1 ms |

**Recomendación para cualquier despliegue nuevo: `chrony`.** Las propiedades decisivas son la convergencia en segundos desde arranque en frío (importa para nodos de autoescalado y VMs efímeras), el comportamiento correcto ante suspensión/migración, y NTS.

`systemd-timesyncd` se descalifica para flotas por un solo punto: es un cliente **SNTP** que habla con **un servidor a la vez**. No hay algoritmo de selección, luego no hay protección contra falsetickers. Es un valor por defecto razonable para un portátil y la elección equivocada para un nodo de base de datos.

`ntpdate` está obsoleto aguas arriba. Sus sustitutos son `sntp -s <servidor>` (salto de una sola pasada) o, mejor, `chronyd -q 'server <host> iburst'` (fijar una vez y salir) / `chronyd -Q 'server <host> iburst'` (**solo medir e imprimir, nunca fijar** — la forma segura para monitorización, ver §11.3).

### 6.4 `pool.ntp.org`

El NTP Pool es un round-robin de DNS voluntario. `0.pool.ntp.org` resuelve a un conjunto rotatorio *diferente* de direcciones en cada consulta:

```console
$ dig +short 0.pool.ntp.org
162.159.200.123
185.125.190.56
193.182.111.14
94.130.49.186

$ dig +short 0.pool.ntp.org
216.239.35.0
5.75.181.19
88.99.75.198
162.159.200.1
```

Reglas operativas que se derivan de ese diseño:

1. **Usa los subdominios numerados `0.`–`3.`**, no `pool.ntp.org` a secas cuatro veces. Cada zona numerada extrae de una porción distinta, así que obtienes cuatro servidores genuinamente independientes en lugar de cuatro posiblemente idénticos.
2. **Usa la zona de tu proveedor/país** cuando tu distribución ofrezca una: `0.debian.pool.ntp.org`, `0.rhel.pool.ntp.org`, `0.es.pool.ntp.org`. Las zonas de proveedor existen para que los operadores del pool puedan medir y gestionar la carga por distribución; usarlas es la etiqueta esperada.
3. **Prefiere `pool` sobre `server` en `chrony.conf`.** La directiva `pool` resuelve el nombre a *múltiples* direcciones y mantiene un número objetivo, reemplazando las fuentes que se degradan. `server` se ata a una única dirección durante toda la vida del demonio.
4. **Nunca apuntes un centro de datos entero al pool público.** Ejecuta 2–4 servidores internos de estrato 2 que se sincronicen hacia arriba con el pool (o con un appliance GPS), y apunta todos los demás nodos a esos. Esto acota el tráfico saliente, mantiene la hora consistente *dentro* de tu dominio de fallo y funciona durante una partición de internet.
5. **En la nube, prefiere el servicio link-local del proveedor.** Es gratis, está fuera del camino de internet y aplica leap smearing de forma consistente:

| Proveedor | Punto de acceso |
|---|---|
| AWS | `169.254.169.123` (también `fd00:ec2::123`) |
| GCP | `metadata.google.internal` / `169.254.169.254` |
| Azure | PTP vía `/dev/ptp_hyperv` (preferido), o `time.windows.com` |
| Oracle OCI | `169.254.169.254` |

### 6.5 Compromisos de topología de fuentes

| Topología | Precisión | Radio de impacto de una fuente mala | Dependencia de internet | Coste |
|---|---|---|---|---|
| Cada nodo → pool público | 1–50 ms | Bajo (por nodo) | **Total** | Gratis, antisocial a escala |
| Cada nodo → link-local de la nube | 0,1–1 ms | Bajo | Ninguna | Gratis |
| Capa interna de estrato 2 → pool/nube | 0,05–1 ms | **Medio — un servidor interno malo envenena a sus clientes** | Solo en la capa | Bajo |
| Capa interna → appliance GPS/GNSS | 10–100 µs | Medio | **Ninguna** | Hardware + antena + acceso al tejado |
| PTP con switches con marcado de tiempo por HW | **<1 µs** | Medio | Ninguna | Alto — requisitos de switch y NIC |

Elige por requisito, con honestidad: el reporte de operaciones financieras (MiFID II) y las bases de datos distribuidas con relojes de incertidumbre acotada necesitan las filas de abajo; casi todo lo demás está correcto en la segunda fila.

---

## 7. Configuración — ficheros completos, listos para producción

### 7.1 `/etc/chrony/chrony.conf` (Debian) / `/etc/chrony.conf` (RHEL)

```conf
# /etc/chrony.conf — production node profile
# Managed by Ansible. Local edits will be overwritten.

#------------------------------------------------------------------------------
# Time sources
#------------------------------------------------------------------------------
# Internal stratum-2 tier. 'pool' maintains `maxsources` usable sources from the
# resolved address set and replaces sources that become unreachable or falsetick.
pool ntp.internal.example.net    iburst maxsources 4 maxpoll 10

# Fallback to the vendor pool zone if the internal tier is unreachable.
# 'offline' + chronyc online/offline can gate these; here we simply deprioritise
# by giving the internal tier a stratum advantage upstream.
pool 2.debian.pool.ntp.org       iburst maxsources 2 maxpoll 10

# Network Time Security (RFC 8915) — authenticated, unspoofable, over TCP/4460
# for key establishment then authenticated NTP over UDP/123.
server time.cloudflare.com       iburst nts

#------------------------------------------------------------------------------
# Clock discipline
#------------------------------------------------------------------------------
# Step (rather than slew) if the offset exceeds 1 s, but ONLY within the first
# 3 clock updates after chronyd starts. After that, always slew: a running
# workload must never observe a CLOCK_REALTIME discontinuity.
makestep 1.0 3

# Cap slew rate so a large correction cannot distort measured durations by more
# than ~1.2%. Default is 83333.333 ppm; 25000 ppm = 2.5%.
maxslewrate 25000

# Refuse to accept a sample from a source whose root distance exceeds 3 s.
maxdistance 3.0

# Reject any single sample implying a step larger than 5 s after the first hour
# of uptime — protects against a source that suddenly starts lying.
maxchange 5 1 0

# Persist the measured frequency error so a restart does not have to relearn it.
driftfile /var/lib/chrony/chrony.drift

# Persist per-source measurement history across restarts (fast reconvergence).
dumpdir /var/lib/chrony

#------------------------------------------------------------------------------
# Hardware clock
#------------------------------------------------------------------------------
# Track RTC drift and correct the RTC at shutdown. rtcsync (kernel 11-minute
# mode) and rtcfile are mutually exclusive — pick one.
rtcsync

# The RTC is UTC. Never LOCAL on a server.
# (chrony reads /etc/adjtime; this directive is for systems without one.)
# rtconutc

#------------------------------------------------------------------------------
# Leap seconds
#------------------------------------------------------------------------------
# Use the leap-second table shipped with tzdata rather than trusting the
# server's leap indicator bits, and SLEW through the leap instead of stepping.
leapsectz right/UTC
leapsecmode slew

#------------------------------------------------------------------------------
# Logging
#------------------------------------------------------------------------------
logdir /var/log/chrony
log tracking measurements statistics

# Log a syslog message whenever the system clock is corrected by more than 0.5 s.
logchange 0.5

#------------------------------------------------------------------------------
# Access control — this node is a CLIENT ONLY
#------------------------------------------------------------------------------
# No 'allow' directive at all => serve nobody. Explicit and default-deny.
# Do not log client accesses (there are none) — saves memory.
noclientlog

# Disable the command port entirely; chronyc still works over the Unix socket
# at /var/run/chrony/chronyd.sock for local root.
cmdport 0

# Bind only to the management interface if this node is multi-homed.
# bindaddress 10.20.0.15

#------------------------------------------------------------------------------
# Hardening
#------------------------------------------------------------------------------
# Drop privileges after binding.
user _chrony

# Rate-limit responses if this ever becomes a server (defence in depth).
ratelimit interval 3 burst 8
```

El perfil del **servidor interno de estrato 2** difiere únicamente en el bloque de control de acceso:

```conf
# /etc/chrony.conf — internal stratum-2 server profile

pool 0.debian.pool.ntp.org iburst maxsources 3
pool 1.debian.pool.ntp.org iburst maxsources 3
server 169.254.169.123     iburst prefer          # cloud link-local, if present

makestep 1.0 3
maxslewrate 25000
driftfile /var/lib/chrony/chrony.drift
rtcsync
leapsectz right/UTC

# Serve time to the internal networks ONLY.
allow 10.0.0.0/8
allow 172.16.0.0/12
allow 192.168.0.0/16
deny  all

# Keep serving from the local clock if all upstreams are lost, but advertise a
# high stratum so clients prefer any healthy peer. Only takes effect after the
# clock has been synchronised at least once.
local stratum 10 orphan

# Serve NTS to internal clients.
ntsservercert /etc/pki/tls/certs/ntp.internal.example.net.crt
ntsserverkey  /etc/pki/tls/private/ntp.internal.example.net.key

ratelimit interval 1 burst 16 leak 2
noclientlog
cmdport 0
```

`local stratum 10 orphan` es la directiva que evita una caída de hora en toda la flota durante una partición de internet: la capa sigue sirviendo una hora consistente (aunque sin anclaje), y `orphan` garantiza que exactamente uno de ellos gane la elección para que la capa no diverja internamente.

### 7.2 `/etc/ntp.conf` (`ntpd` de referencia)

Para flotas ya estandarizadas sobre `ntpd`, y porque el examen nombra este fichero explícitamente:

```conf
# /etc/ntp.conf — production node profile (reference ntpd 4.2.8)

#------------------------------------------------------------------------------
# Drift and statistics
#------------------------------------------------------------------------------
driftfile /var/lib/ntp/ntp.drift

statsdir /var/log/ntpstats/
statistics loopstats peerstats clockstats
filegen loopstats file loopstats type day enable
filegen peerstats file peerstats type day enable
filegen clockstats file clockstats type day enable

#------------------------------------------------------------------------------
# Time sources — 'pool' expands to multiple associations; four independent
# numbered zones so falseticker detection has a real majority to work with.
#------------------------------------------------------------------------------
pool 0.debian.pool.ntp.org iburst
pool 1.debian.pool.ntp.org iburst
pool 2.debian.pool.ntp.org iburst
pool 3.debian.pool.ntp.org iburst

# Internal tier, preferred.
server ntp1.internal.example.net iburst prefer
server ntp2.internal.example.net iburst

# Poll bounds: 2^6 = 64 s minimum, 2^10 = 1024 s maximum.
tinker panic 0          # do NOT exit on a >1000 s offset; step it instead
                        # (only safe when combined with -g and a trusted source)

#------------------------------------------------------------------------------
# Access control — RFC 5905 / CVE-2013-5211 hardening
#------------------------------------------------------------------------------
# Default: reply to time queries only. No mode 6/7 control queries, no peering,
# no trap service, rate-limited, kiss-o'-death on abuse.
restrict default kod nomodify notrap nopeer noquery limited
restrict -6 default kod nomodify notrap nopeer noquery limited

# Localhost may query and control.
restrict 127.0.0.1
restrict ::1

# Internal management subnet may query status but not modify.
restrict 10.20.0.0 mask 255.255.0.0 nomodify notrap nopeer

# Explicitly disable the monlist/mode-7 interface — the NTP reflection
# amplification vector (amplification factor up to ~550x).
disable monitor

#------------------------------------------------------------------------------
# Local clock fallback — DO NOT use the legacy 127.127.1.0 undisciplined-local
# refclock on a modern system; it announces stratum 10 unconditionally and
# will poison clients. Use 'orphan' mode instead.
#------------------------------------------------------------------------------
tos orphan 10

# Bind only where needed.
interface ignore wildcard
interface listen 10.20.0.15
interface listen 127.0.0.1
```

Dos líneas cargan con un peso de seguridad desproporcionado: **`restrict default ... noquery`** y **`disable monitor`**. Juntas cierran CVE-2013-5211, el vector de reflexión DDoS de `monlist` que convirtió a `ntpd` sin parchear en una de las mayores fuentes de amplificación de internet.

### 7.3 `/etc/systemd/timesyncd.conf`

```ini
# /etc/systemd/timesyncd.conf
# Acceptable for appliances and workstations. NOT for fleet nodes:
# timesyncd is SNTP, talks to one server at a time, and has no
# falseticker-selection algorithm.

[Time]
NTP=ntp1.internal.example.net ntp2.internal.example.net
FallbackNTP=0.debian.pool.ntp.org 1.debian.pool.ntp.org

# Poll interval bounds, seconds.
PollIntervalMinSec=32
PollIntervalMaxSec=2048

# Refuse a source whose root distance exceeds this.
RootDistanceMaxSec=5

# Save the last known good time so a machine without an RTC does not boot in 1970.
SaveIntervalSec=60

# Connection retry backoff.
ConnectionRetrySec=30
```

### 7.4 Orden de arranque: servicios que no deben arrancar antes de que la hora sea correcta

Un servicio que valida certificados y arranca antes de que el reloj esté disciplinado rechazará certificados válidos y entrará en crash-loop. systemd proporciona el punto de sincronización:

```ini
# /etc/systemd/system/my-tls-service.service.d/10-require-time-sync.conf
[Unit]
After=time-sync.target
Wants=time-sync.target
```

`time-sync.target` solo se alcanza cuando una unidad de *espera de hora* lo declara. Activa la correspondiente:

```console
# systemctl enable --now systemd-time-wait-sync.service    # with timesyncd
# systemctl enable --now chrony-wait.service               # with chrony
```

```console
$ systemctl cat chrony-wait.service
# /lib/systemd/system/chrony-wait.service
[Unit]
Description=Wait for chrony to synchronise system clock
After=chrony.service
Requires=chrony.service
Before=time-sync.target
Wants=time-sync.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/chronyc -h 127.0.0.1,/run/chrony/chronyd.sock waitsync 180 0.1
TimeoutStartSec=180

[Install]
WantedBy=sysinit.target
```

`chronyc waitsync 180 0.1` bloquea hasta que la distancia raíz baje de 0,1 s o transcurran 180 s. Inclúyelo en la construcción de tu imagen para cualquier nodo que ejecute cargas que terminen TLS o que usen Kerberos.

---

## 8. Infraestructura como código

### 8.1 Rol de Ansible — playbook completo

```yaml
---
# playbooks/time.yml
# Converge system time configuration across the fleet.
# Run: ansible-playbook -i inventories/prod playbooks/time.yml
- name: Enforce UTC, disciplined clocks and a UTC RTC on all nodes
  hosts: all
  become: true

  vars:
    time_timezone: "Etc/UTC"
    time_internal_pool: "ntp.internal.example.net"
    time_fallback_pools:
      - "2.debian.pool.ntp.org"
    time_nts_servers:
      - "time.cloudflare.com"
    time_makestep_threshold: 1.0
    time_makestep_limit: 3
    time_max_slew_ppm: 25000
    time_is_ntp_server: false
    time_server_allow_networks:
      - "10.0.0.0/8"
      - "172.16.0.0/12"
      - "192.168.0.0/16"

  handlers:
    - name: restart chronyd
      ansible.builtin.systemd:
        name: "{{ chrony_service }}"
        state: restarted
        daemon_reload: true

  tasks:
    - name: Set distribution-specific facts
      ansible.builtin.set_fact:
        chrony_service: "{{ 'chrony' if ansible_os_family == 'Debian' else 'chronyd' }}"
        chrony_conf: >-
          {{ '/etc/chrony/chrony.conf' if ansible_os_family == 'Debian'
             else '/etc/chrony.conf' }}
        chrony_user: "{{ '_chrony' if ansible_os_family == 'Debian' else 'chrony' }}"

    - name: Remove conflicting time daemons
      ansible.builtin.package:
        name:
          - ntp
          - ntpsec
          - openntpd
        state: absent

    - name: Mask systemd-timesyncd so it cannot race chronyd for the clock
      ansible.builtin.systemd:
        name: systemd-timesyncd.service
        enabled: false
        state: stopped
        masked: true
      failed_when: false

    - name: Install chrony and tzdata
      ansible.builtin.package:
        name:
          - chrony
          - tzdata
        state: present

    - name: Set the system timezone
      community.general.timezone:
        name: "{{ time_timezone }}"
      notify: restart chronyd

    - name: Assert the RTC is interpreted as UTC
      ansible.builtin.lineinfile:
        path: /etc/adjtime
        regexp: '^(UTC|LOCAL)$'
        line: 'UTC'
        create: false
      register: adjtime_fixed
      failed_when: false

    - name: Force RTC to UTC via timedatectl when /etc/adjtime disagreed
      ansible.builtin.command:
        cmd: timedatectl set-local-rtc 0 --adjust-system-clock
      when: adjtime_fixed is changed
      changed_when: true

    - name: Deploy chrony configuration
      ansible.builtin.template:
        src: chrony.conf.j2
        dest: "{{ chrony_conf }}"
        owner: root
        group: root
        mode: '0644'
        validate: '/usr/sbin/chronyd -f %s -p'
      notify: restart chronyd

    - name: Enable and start chronyd
      ansible.builtin.systemd:
        name: "{{ chrony_service }}"
        enabled: true
        state: started
        daemon_reload: true

    - name: Wait for the clock to synchronise within 100 ms
      ansible.builtin.command:
        cmd: chronyc waitsync 60 0.1
      changed_when: false
      register: waitsync
      failed_when: waitsync.rc != 0

    - name: Collect tracking data for assertion
      ansible.builtin.command:
        cmd: chronyc -c tracking
      changed_when: false
      register: tracking

    - name: Assert the residual offset is under 50 ms
      ansible.builtin.assert:
        that:
          - (tracking.stdout.split(',')[4] | float) | abs < 0.050
        fail_msg: >-
          Clock offset {{ tracking.stdout.split(',')[4] }}s exceeds 50ms
          on {{ inventory_hostname }}
        success_msg: "Clock disciplined: offset {{ tracking.stdout.split(',')[4] }}s"

    - name: Assert timedatectl reports a sane state
      ansible.builtin.command:
        cmd: timedatectl show --property=NTPSynchronized --property=LocalRTC --value
      changed_when: false
      register: tdc
      failed_when: >-
        tdc.stdout_lines[0] != 'yes' or tdc.stdout_lines[1] != 'no'
```

`validate: '/usr/sbin/chronyd -f %s -p'` es la línea que se gana el sueldo: `chronyd -p` analiza la configuración y sale sin tocar el reloj, de modo que un error de sintaxis se detecta al renderizar la plantilla en lugar de al reiniciar el handler en 400 nodos.

### 8.2 `templates/chrony.conf.j2`

```jinja
# {{ ansible_managed }}
# Rendered for {{ inventory_hostname }} ({{ ansible_distribution }} {{ ansible_distribution_version }})

pool {{ time_internal_pool }} iburst maxsources 4 maxpoll 10
{% for p in time_fallback_pools %}
pool {{ p }} iburst maxsources 2 maxpoll 10
{% endfor %}
{% for s in time_nts_servers %}
server {{ s }} iburst nts
{% endfor %}
{% if ansible_virtualization_role == 'guest' and ansible_virtualization_type == 'kvm' %}

# PTP hardware clock exposed by the KVM host via ptp_kvm: a local, network-free
# reference two orders of magnitude better than any NTP source.
refclock PHC /dev/ptp_kvm poll 2 dpoll -2 offset 0 stratum 2
{% endif %}

makestep {{ time_makestep_threshold }} {{ time_makestep_limit }}
maxslewrate {{ time_max_slew_ppm }}
maxdistance 3.0
maxchange 5 1 0
driftfile /var/lib/chrony/chrony.drift
dumpdir /var/lib/chrony
rtcsync
leapsectz right/UTC
leapsecmode slew

logdir /var/log/chrony
log tracking measurements statistics
logchange 0.5

user {{ chrony_user }}

{% if time_is_ntp_server %}
{% for net in time_server_allow_networks %}
allow {{ net }}
{% endfor %}
deny all
local stratum 10 orphan
ratelimit interval 1 burst 16 leak 2
{% else %}
# Client only: no allow directives, serve nobody.
cmdport 0
{% endif %}
noclientlog
```

### 8.3 Reglas de alerta de Prometheus

```yaml
# /etc/prometheus/rules/time-sync.yml
# Requires node_exporter with the (default-enabled) 'timex' collector.
groups:
  - name: node-time-sync
    interval: 30s
    rules:

      # ----------------------------------------------------------------------
      # Recording rules
      # ----------------------------------------------------------------------
      - record: instance:node_clock_offset_seconds:abs
        expr: abs(node_timex_offset_seconds)

      # Worst pairwise skew across the fleet: the number that actually breaks
      # Raft, LWW and Kerberos. A fleet can be uniformly 400 ms off UTC and
      # still be internally consistent; it cannot survive nodes 400 ms apart.
      - record: fleet:node_clock_pairwise_skew_seconds:max
        expr: >
          max(node_timex_offset_seconds) - min(node_timex_offset_seconds)

      # ----------------------------------------------------------------------
      # Alerts
      # ----------------------------------------------------------------------
      - alert: NodeClockNotSynchronising
        expr: >
          min_over_time(node_timex_sync_status[5m]) == 0
          and
          node_timex_maxerror_seconds >= 16
        for: 10m
        labels:
          severity: warning
          runbook: time-sync
        annotations:
          summary: "Clock not synchronising on {{ $labels.instance }}"
          description: >-
            The kernel reports STA_UNSYNC and maxerror has reached its 16s
            ceiling. chronyd/ntpd is not disciplining the clock. The node will
            drift at its raw crystal rate (typically 2-4 s/day) from here.

      - alert: NodeClockSkewDetected
        expr: >
          (
            node_timex_offset_seconds > 0.05
            and deriv(node_timex_offset_seconds[5m]) >= 0
          )
          or
          (
            node_timex_offset_seconds < -0.05
            and deriv(node_timex_offset_seconds[5m]) <= 0
          )
        for: 10m
        labels:
          severity: warning
          runbook: time-sync
        annotations:
          summary: "Clock skew >50ms and diverging on {{ $labels.instance }}"
          description: >-
            Offset is {{ $value | humanizeDuration }} and moving further from
            zero. Distributed tracing and LWW conflict resolution are already
            affected; Kerberos fails at 300s.

      - alert: NodeClockSkewCritical
        expr: abs(node_timex_offset_seconds) > 30
        for: 2m
        labels:
          severity: critical
          runbook: time-sync
        annotations:
          summary: "Clock off by >30s on {{ $labels.instance }}"
          description: >-
            TOTP/MFA is already failing for this node. Kerberos fails at 300s
            and cloud API SigV4 at 900s.

      - alert: FleetClockDivergence
        expr: fleet:node_clock_pairwise_skew_seconds:max > 0.5
        for: 5m
        labels:
          severity: critical
          runbook: time-sync
        annotations:
          summary: "Fleet nodes disagree by >500ms"
          description: >-
            etcd warns above 1s pairwise difference and leader election starts
            flapping. Check whether a subset of nodes lost its NTP tier.

      - alert: NodeClocksourceDegraded
        expr: node_timex_frequency_adjustment_ratio < 0.9995
              or node_timex_frequency_adjustment_ratio > 1.0005
        for: 30m
        labels:
          severity: info
        annotations:
          summary: "Crystal frequency error >500ppm on {{ $labels.instance }}"
          description: >-
            The kernel is applying an unusually large frequency correction.
            Check `dmesg | grep clocksource` for a TSC demotion, which also
            costs ~30x on every clock_gettime() because the vDSO fast path is
            lost.

      - alert: NodeNTPDaemonDown
        expr: >
          node_systemd_unit_state{name=~"chronyd?\\.service",state="active"} == 0
        for: 15m
        labels:
          severity: warning
        annotations:
          summary: "chronyd is not active on {{ $labels.instance }}"
```

### 8.4 Kubernetes: un DaemonSet exportador de desviación de reloj

La hora en un nodo de Kubernetes es una cuestión **a nivel de nodo**. Un pod no puede —y no debe— fijar el reloj: `CLOCK_REALTIME` no está virtualizado por el time namespace (§9.2), y conceder `CAP_SYS_TIME` a un contenedor le permite mover el reloj *del host*. Por tanto, el patrón correcto es **medir desde un pod y fijar desde el `chronyd` del propio nodo**.

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: node-observability
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: clock-skew-exporter
  namespace: node-observability
data:
  probe.sh: |
    #!/bin/sh
    # Measure the node's clock offset against a reference WITHOUT setting it.
    # `chronyd -Q` performs the NTP exchange, prints the computed offset and
    # exits, never calling adjtimex() or clock_settime(). It therefore needs
    # no CAP_SYS_TIME, which is exactly why it is safe to run in a pod.
    set -eu
    OUT=/textfile/clock_skew.prom
    TMP="${OUT}.$$"
    while true; do
      RAW=$(chronyd -Q -t 10 \
              "server ${NTP_SERVER} iburst maxsamples 4" 2>&1 || true)
      # Expected: "2026-08-27T14:32:05Z System clock wrong by -0.000123 seconds"
      OFFSET=$(printf '%s\n' "$RAW" \
               | sed -n 's/.*System clock wrong by \(-\?[0-9.]*\) seconds.*/\1/p' \
               | head -n1)
      {
        echo '# HELP node_clock_skew_seconds Offset of CLOCK_REALTIME vs the reference NTP server.'
        echo '# TYPE node_clock_skew_seconds gauge'
        if [ -n "${OFFSET}" ]; then
          echo "node_clock_skew_seconds{server=\"${NTP_SERVER}\"} ${OFFSET}"
          echo '# HELP node_clock_probe_success Whether the last SNTP probe succeeded.'
          echo '# TYPE node_clock_probe_success gauge'
          echo "node_clock_probe_success{server=\"${NTP_SERVER}\"} 1"
        else
          echo "node_clock_probe_success{server=\"${NTP_SERVER}\"} 0"
        fi
      } > "${TMP}"
      mv "${TMP}" "${OUT}"          # atomic: the collector never reads a partial file
      sleep "${PROBE_INTERVAL:-60}"
    done
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: clock-skew-exporter
  namespace: node-observability
  labels:
    app.kubernetes.io/name: clock-skew-exporter
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: clock-skew-exporter
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 25%
  template:
    metadata:
      labels:
        app.kubernetes.io/name: clock-skew-exporter
    spec:
      # hostNetwork so the probe measures the node's own network path to the
      # NTP tier, not the CNI overlay's.
      hostNetwork: true
      dnsPolicy: ClusterFirstWithHostNet
      priorityClassName: system-node-critical
      tolerations:
        - operator: Exists          # must run on every node, including tainted ones
      securityContext:
        runAsNonRoot: true
        runAsUser: 65534
        runAsGroup: 65534
        fsGroup: 65534
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: probe
          image: cgr.dev/chainguard/chrony:latest
          command: ["/bin/sh", "/etc/probe/probe.sh"]
          env:
            - name: NTP_SERVER
              value: "ntp.internal.example.net"
            - name: PROBE_INTERVAL
              value: "60"
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
              # NOTE: no CAP_SYS_TIME. The probe measures; it never sets.
          resources:
            requests:
              cpu: 5m
              memory: 16Mi
            limits:
              memory: 32Mi
          volumeMounts:
            - name: probe-script
              mountPath: /etc/probe
              readOnly: true
            - name: textfile
              mountPath: /textfile
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: probe-script
          configMap:
            name: clock-skew-exporter
            defaultMode: 0555
        - name: textfile
          hostPath:
            # Same directory node_exporter is started with:
            #   --collector.textfile.directory=/var/lib/node_exporter/textfile_collector
            path: /var/lib/node_exporter/textfile_collector
            type: DirectoryOrCreate
        - name: tmp
          emptyDir:
            medium: Memory
            sizeLimit: 8Mi
```

Dos decisiones de diseño que conviene explicitar, porque son las que los revisores suelen malinterpretar:

- **`capabilities: drop: ["ALL"]` sin `CAP_SYS_TIME`.** Si un manifiesto pide `CAP_SYS_TIME`, está intentando fijar el reloj del host desde un contenedor. Recházalo en el control de admisión:

```yaml
---
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: disallow-sys-time
  annotations:
    policies.kyverno.io/description: >-
      CLOCK_REALTIME is not namespaced. A container holding CAP_SYS_TIME can
      move the clock for every other workload on the node. Time is set by the
      node's chronyd, never by a pod.
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    - name: block-cap-sys-time
      match:
        any:
          - resources:
              kinds: ["Pod"]
      validate:
        message: "CAP_SYS_TIME is prohibited: the node owns CLOCK_REALTIME."
        foreach:
          - list: "request.object.spec.containers[]"
            deny:
              conditions:
                any:
                  - key: "SYS_TIME"
                    operator: AnyIn
                    value: "{{ element.securityContext.capabilities.add[] || `[]` }}"
```

- **`mv` atómico dentro del directorio de textfile.** El colector textfile de `node_exporter` lee `*.prom` en cada scrape; escribir en el sitio produce ficheros truncados y un error de scrape aproximadamente con la frecuencia con la que tu intervalo de scrape divide a tu intervalo de escritura.

---

## 9. Virtualización y contenedores

### 9.1 Huéspedes

El TSC de una VM puede saltar en una migración en vivo, en una pausa/reanudación o ante cambios de frecuencia de la CPU del host. Consecuencias y remedios:

| Situación | Remedio |
|---|---|
| Huésped KVM | Usa `kvm-clock` (por defecto). El host propaga su disciplina. Aun así, ejecuta `chronyd` en el huésped para el residual. |
| Huésped KVM, alta precisión | `refclock PHC /dev/ptp_kvm poll 2 dpoll -2 offset 0` — lee el reloj del host por un canal PTP paravirtual, sin red de por medio. Requiere el módulo `ptp_kvm`. |
| Hyper-V / Azure | `refclock PHC /dev/ptp_hyperv poll 3 dpoll -2 offset 0` |
| VMware | Desactiva la sincronización horaria de VMware Tools **o** desactiva `chronyd`, nunca ambas: pelean y el reloj oscila. La recomendación actual es preferir NTP dentro del huésped. |
| Migración en vivo | `chronyd` se recupera automáticamente; `ntpd` a menudo necesita un reinicio. |

```console
# modprobe ptp_kvm
# ls -l /dev/ptp*
crw------- 1 root root 249, 0 Aug 27 14:30 /dev/ptp0
# grep -H . /sys/class/ptp/ptp0/clock_name
/sys/class/ptp/ptp0/clock_name:KVM virtual PTP
```

### 9.2 Contenedores — el time namespace no hace lo que la gente supone

Linux 5.6 añadió `CLONE_NEWTIME`. Virtualiza **únicamente `CLOCK_MONOTONIC` y `CLOCK_BOOTTIME`** (mediante desplazamientos por namespace en `/proc/<pid>/timens_offsets`). **`CLOCK_REALTIME` está deliberadamente excluido** y es global para el host.

Por tanto:

- Un contenedor **no puede** tener su propia hora de pared. Punto.
- Un contenedor que parece tener la hora mal tiene mal la *zona horaria*, no el reloj. Arréglalo definiendo `TZ` o montando `/etc/localtime`, nunca intentando fijar el reloj.
- Ejecutar un demonio NTP dentro de un contenedor es un antipatrón: con `CAP_SYS_TIME` reconfigura silenciosamente el host; sin ella, falla.

```console
$ docker run --rm alpine date -s "2020-01-01"
date: can't set date: Operation not permitted

$ docker run --rm alpine date
Thu Aug 27 14:32:05 UTC 2026

$ docker run --rm -e TZ=Europe/Madrid alpine sh -c 'apk add -q tzdata; date'
Thu Aug 27 16:32:05 CEST 2026

$ docker run --rm -v /etc/localtime:/etc/localtime:ro alpine date
Thu Aug 27 14:32:05 UTC 2026
```

La forma idiomática en Kubernetes:

```yaml
spec:
  containers:
    - name: app
      image: registry.example.net/app:1.4.2
      env:
        - name: TZ
          value: "Etc/UTC"        # explicit; never rely on the image default
```

### 9.3 Segundos intercalares

Un segundo intercalar positivo inserta `23:59:60 UTC`. La hora UNIX no tiene representación para eso, así que el kernel debe o bien repetir un segundo o bien ralentizarse.

| Estrategia | Comportamiento | Dónde |
|---|---|---|
| **Salto (por defecto del kernel)** | `CLOCK_REALTIME` repite el último segundo: la hora va *hacia atrás* 1 s | Causó históricamente los bloqueos de Linux de 2012 y 2015 (livelock de `hrtimer`) |
| **Slew** (`leapsecmode slew`) | El cliente absorbe el segundo a lo largo de ~12 s a la máxima tasa de slew | Lado cliente de chrony |
| **Smear** (`smoothtime`) | El servidor distribuye el segundo a lo largo de 24 h (típicamente de mediodía a mediodía UTC), ~11,6 ppm de error de frecuencia | Google, AWS (`169.254.169.123`), Cloudflare |

**La única regla que importa: nunca mezclar fuentes con y sin smearing.** Durante un smear discrepan hasta en 0,5 s, lo que el algoritmo de selección lee como un falseticker y puede dejar a un nodo sin ninguna fuente utilizable. Si usas AWS Time Sync, úsalo en exclusiva: no añadas `pool.ntp.org` como alternativa en el mismo `chrony.conf`.

```conf
# Internal server that smears for its clients (server side only):
smoothtime 400 0.001 leaponly
leapsecmode slew
maxslewrate 1000
```

Nota de actualidad: la CGPM resolvió en 2022 dejar de insertar segundos intercalares para 2035 como muy tarde. Los sistemas construidos hoy sobrevivirán al menos a la transición; la configuración de smearing sigue siendo la opción segura por defecto.

---

## 10. Seguridad

### 10.1 Modelo de amenazas

El NTP sin autenticar es una **primitiva de ataque por desplazamiento temporal**. Un atacante en el camino que pueda adelantar el reloj de un objetivo puede volver válidos certificados caducados, reproducir credenciales revocadas más allá de su ventana de CRL, o hacer expirar una sesión válida. Atrasarlo bloquea TOTP y puede derrotar a HSTS.

| Control | Protege frente a | Coste |
|---|---|---|
| Múltiples fuentes independientes (≥4) | Un único servidor que miente | Gratis |
| `maxchange 5 1 0` (chrony) | Inyección de offset a fuego lento | Gratis |
| **NTS (RFC 8915)** | Modificación y suplantación en el camino | Handshake TLS en TCP/4460; casi cero en régimen estacionario |
| Claves simétricas (`keyfile`/`ntp.keys`) | Lo mismo, para capas internas | Carga de distribución de claves |
| `restrict ... noquery` + `disable monitor` (ntpd) | Ser un reflector de amplificación | Gratis |
| `cmdport 0` / `noclientlog` (chrony) | Lo mismo | Gratis |
| Cortafuegos que limita la salida UDP/123 solo a la capa interna | Nodos que puentean la capa | Gratis |

### 10.2 NTS en la práctica

```console
# chronyc -N authdata
Name/IP address             Mode KeyID Type KLen Last Atmp  NAK Cook CLen
=========================================================================
time.cloudflare.com          NTS     1   15  256   55m    0    0    8  100
ntp1.internal.example.net    NTS     1   15  256   17m    0    0    8  100
ntp2.internal.example.net     -      0    0    0     -    0    0    0    0
```

`Mode NTS`, `KLen 256`, `Cook 8` (ocho cookies sin usar en mano) es una asociación NTS sana. Un `NAK` que sube indica fallos en el establecimiento de claves, normalmente un certificado de servidor caducado o un middlebox en TCP/4460.

### 10.3 Verifica que no eres un reflector

```console
$ ntpdc -n -c monlist 203.0.113.10
203.0.113.10: timed out, nothing received
***Request timed out

$ ntpq -c "rv 0" 203.0.113.10
203.0.113.10: timed out, nothing received
***Request timed out
```

Que ambos expiren desde un host externo es el resultado deseado. Si `monlist` devuelve cientos de líneas, ese servidor es un amplificador DDoS activo: arréglalo ya.

---

## 11. Verificación y diagnóstico de fallos

### 11.1 El triaje de 60 segundos

Ejecuta este bloque en cualquier nodo sospechoso de tener un problema de hora. Está ordenado para que la primera línea que falle nombre la capa.

```bash
#!/usr/bin/env bash
# time-triage.sh — read top to bottom; the first anomaly is the cause.
set -uo pipefail

echo "=== 1. Consensus view ==="
timedatectl

echo -e "\n=== 2. Is a disciplinarian running? ==="
systemctl is-active chronyd chrony ntpd ntpsec systemd-timesyncd 2>/dev/null \
  | paste -d' ' <(echo -e "chronyd\nchrony\nntpd\nntpsec\ntimesyncd") -

echo -e "\n=== 3. Kernel discipline state (authoritative) ==="
adjtimex --print | grep -E 'status|offset|frequency|maxerror|return value'

echo -e "\n=== 4. RTC convention (must be UTC on a server) ==="
cat /etc/adjtime 2>/dev/null || echo "no /etc/adjtime (implies UTC)"

echo -e "\n=== 5. Timezone resolution ==="
ls -l /etc/localtime
cat /etc/timezone 2>/dev/null || true
echo "TZ=${TZ:-<unset>}"

echo -e "\n=== 6. Clocksource (performance, not correctness) ==="
cat /sys/devices/system/clocksource/clocksource0/current_clocksource
dmesg 2>/dev/null | grep -i 'switched to clocksource' | tail -3

echo -e "\n=== 7. Source health ==="
command -v chronyc >/dev/null && { chronyc tracking; echo; chronyc -n sources -v; }
command -v ntpq   >/dev/null && ntpq -pn

echo -e "\n=== 8. Can we even reach UDP/123? ==="
timeout 5 chronyd -Q -t 4 'server ntp.internal.example.net iburst' 2>&1 \
  || echo "PROBE FAILED"

echo -e "\n=== 9. RTC vs system delta ==="
printf 'system: %s\nrtc:    %s\n' \
  "$(date -u +%FT%TZ)" "$(hwclock --show --utc 2>/dev/null || echo 'n/a')"
```

### 11.2 Síntoma → causa → solución

| Síntoma | Causa más probable | Confirmar con | Solución |
|---|---|---|---|
| `System clock synchronized: no` | Ningún demonio en marcha, o todas las fuentes inalcanzables | `systemctl is-active chronyd`; `chronyc sources` | Arrancar el demonio; revisar la salida UDP/123 |
| `NTP service: n/a` | Ninguna unidad registrada en `/usr/lib/systemd/ntp-units.d/` | `ls /usr/lib/systemd/ntp-units.d/` | Instalar chrony |
| Dos demonios instalados | `systemd-timesyncd` y `chronyd` ambos activos, peleando por el reloj | `systemctl is-active systemd-timesyncd chronyd` | `systemctl mask --now systemd-timesyncd` |
| Todas las fuentes muestran `Reach 0` | El cortafuegos bloquea UDP/123, o falla el DNS | `chronyc -n sources`; `ss -ulpn \| grep 123`; `dig +short 0.pool.ntp.org` | Abrir la salida UDP/123; arreglar el resolutor |
| Las fuentes llegan a `377` pero el estado es `?` o `x` | Distancia raíz por encima de `maxdistance`, o falseticker | `chronyc sourcestats`; `chronyc ntpdata <src>` | Añadir más fuentes independientes; comprobar si hay mezcla de fuentes con y sin smearing |
| Offset grande y **estable** | El demonio está derivando a la máxima tasa; ten paciencia | `chronyc tracking` dos veces, con 60 s de diferencia | Esperar, o `chronyc makestep` **solo si no hay carga en ejecución** |
| Offset grande y **creciente** | No está disciplinado en absoluto; deriva bruta del cristal | `adjtimex --print` → `status` tiene `0x40` activo | Reiniciar el demonio; buscar rechazos por `maxchange`/`maxdistance` en el log |
| Hora correcta, pero las marcas de tiempo muestran la hora equivocada | Zona horaria, no reloj | `date -u` frente a `date` | Arreglar `/etc/localtime` o `TZ` |
| La hora está exactamente ±1 h desviada tras un reinicio | RTC en LOCAL durante una transición de horario de verano | `tail -1 /etc/adjtime` | `timedatectl set-local-rtc 0 --adjust-system-clock` |
| La hora está exactamente ±N h desviada en una VM | Host y huésped discrepan sobre la convención del RTC | `hwclock --show` frente a `date -u` | Poner el RTC del hipervisor en UTC |
| Reloj correcto, pero la latencia p99 se triplicó | TSC degradado a HPET | `dmesg \| grep clocksource` | Investigar el host; `tsc=reliable` solo con confirmación del fabricante |
| Correcto al reiniciar, mal a los 3 días | RTC bien, ningún NTP en marcha | `chronyc tracking` falla | Instalar y activar chrony |
| Mal inmediatamente en cada arranque, correcto tras 5 min | Batería del RTC agotada | `hwclock --show` al arrancar frente a después de sincronizar | Reemplazar la pila CMOS; añadir `chrony-wait.service` |
| Kerberos `Clock skew too great` | Offset > 300 s | `ntpq -p` / `chronyc tracking` en **ambos** extremos | Sincronizar ambos; comprobar el reloj del propio KDC |
| `RequestTimeTooSkewed` desde una API cloud | Offset > 900 s | `date -u` frente a `curl -sI https://s3.amazonaws.com \| grep -i ^date` | Sincronizar |
| Elección de líder de etcd oscilando | Desviación entre pares de nodos > 1 s | `fleet:node_clock_pairwise_skew_seconds:max` | Apuntar todos los miembros de etcd a la *misma* capa NTP |

### 11.3 Medición no destructiva del offset

El truco más útil de este tema: medir sin fijar.

```console
# chronyd -Q -t 10 'server ntp.internal.example.net iburst'
2026-08-27T14:32:05Z chronyd version 4.3 starting (+CMDMON +NTP +REFCLOCK +RTC +PRIVDROP +SCFILTER +SIGND +ASYNCDNS +NTS +SECHASH +IPV6 -DEBUG)
2026-08-27T14:32:09Z System clock wrong by -0.000418 seconds (ignored)
2026-08-27T14:32:09Z chronyd exiting
```

`-Q` es de solo lectura: sin `adjtimex`, sin `clock_settime`, sin necesidad de `CAP_SYS_TIME`. `-q` es la misma medición pero **sí** fija el reloj una vez y sale: el reemplazo moderno de `ntpdate`. Aprende la distinción entre mayúscula y minúscula; usar `-q` donde querías `-Q` provoca un salto en un reloj de producción.

El equivalente en `ntpsec`/`ntpd`:

```console
$ sntp -d ntp.internal.example.net
sntp 4.2.8p15@1.3728-o Mon Feb  1 00:00:00 UTC 2021 (1)
2026-08-27 14:32:09.482913 (+0000) -0.000418 +/- 0.004121 ntp.internal.example.net 10.20.0.5 s2 no-leap
```

### 11.4 Lectura de la salida de `chronyc`

```console
$ chronyc tracking
Reference ID    : 0A140005 (ntp1.internal.example.net)
Stratum         : 3
Ref time (UTC)  : Thu Aug 27 14:29:41 2026
System time     : 0.000012345 seconds slow of NTP time
Last offset     : -0.000005678 seconds
RMS offset      : 0.000041234 seconds
Frequency       : 12.345 ppm slow
Residual freq   : -0.001 ppm
Skew            : 0.087 ppm
Root delay      : 0.012345678 seconds
Root dispersion : 0.001234567 seconds
Update interval : 64.2 seconds
Leap status     : Normal
```

- **`System time`** — error actual. Este es el número que deberían vigilar tus alertas.
- **`Frequency 12.345 ppm slow`** — el error *del cristal* que se está compensando. Estable entre reinicios (persistido en el driftfile). Un valor por encima de ~100 ppm sugiere hardware defectuoso.
- **`Residual freq`** — cuánto discrepa aún la estimación de frecuencia actual con las fuentes. Debería tender a ~0. Un valor persistentemente distinto de cero significa que el lazo no ha convergido.
- **`Skew`** — incertidumbre en la estimación de frecuencia. Skew creciente = fuentes degradándose.
- **`Root delay + Root dispersion`** — la cota de error *demostrable* de vuelta al estrato 0. `Root delay/2 + Root dispersion` es la distancia raíz.
- **`Leap status`** — `Normal`, `Insert second`, `Delete second` o **`Not synchronised`**.

```console
$ chronyc -n sources -v

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
^* 10.20.0.5                     2   6   377    23   -102us[ -119us] +/-   12ms
^+ 10.20.0.6                     2   6   377    27    +214us[ +197us] +/-   14ms
^- 162.159.200.1                 3   6   377    41    -1841us[-1858us] +/-   31ms
^x 203.0.113.44                  2   6   377    19  +48231us[+48214us] +/-   19ms
^? 198.51.100.7                 16   6     0     -     +0ns[   +0ns] +/-    0ns
```

Leyéndolo como operador:

- `^*` — la fuente **seleccionada**. Exactamente una.
- `^+` — combinada en la estimación final. Sana.
- `^-` — medida pero excluida por el algoritmo de combinación (normalmente por mayor distancia raíz). Normal.
- `^x` — **falseticker**. Su intervalo de corrección no se solapa con el de la mayoría. `203.0.113.44` está 48 ms fuera y correctamente puesto en cuarentena. Si tuvieras solo *dos* fuentes, chrony no habría podido tomar esta determinación.
- `^?` — inutilizable. Estrato 16 y `Reach 0` significan que nunca se sondeó con éxito.

```console
$ chronyc sourcestats -v
                            .- Number of sample points in measurement set.
                           /    .- Number of residual runs with same sign.
                          |    /    .- Length of measurement set (time).
                          |   |    /      .- Est. clock freq error (ppm).
                          |   |   |      /           .- Est. error in freq.
                          |   |   |     |           /         .- Est. offset.
                          |   |   |     |          |          |   On +/- of
                          |   |   |     |          |          |   sample point
                          |   |   |     |          |          |    |
                          |   |   |     |          |          |    |
Name/IP Address            NP  NR  Span  Frequency  Freq Skew  Offset  Std Dev
==============================================================================
10.20.0.5                  17   9   264     -0.007      0.288    -14us   231us
10.20.0.6                  16  10   249     +0.021      0.412    +198us  387us
162.159.200.1              14   7   198     -0.114      1.982   -1802us  1.4ms
```

Un `NR` (rachas de residuos) cercano a `NP/2` indica un buen ajuste lineal. Un `NR` cercano a 1 o cercano a `NP` significa que los residuos tienen signo sistemático: el modelo lineal es incorrecto, normalmente por retardo de red asimétrico.

```console
$ chronyc activity
200 OK
4 sources online
0 sources offline
0 sources doing burst (return to online)
0 sources doing burst (return to offline)
0 sources with unknown address

$ chronyc -n ntpdata 10.20.0.5
Remote address  : 10.20.0.5 (0A140005)
Remote port     : 123
Local address   : 10.20.0.15 (0A14000F)
Leap status     : Normal
Version         : 4
Mode            : Server
Stratum         : 2
Poll interval   : 6 (64 seconds)
Precision       : -25 (0.000000030 seconds)
Root delay      : 0.000320 seconds
Root dispersion : 0.000229 seconds
Reference ID    : A9FEA97B ()
Reference time  : Thu Aug 27 14:29:41 2026
Offset          : -0.000102345 seconds
Peer delay      : 0.000412345 seconds
Peer dispersion : 0.000000123 seconds
Response time   : 0.000041234 seconds
Jitter asymmetry: +0.00
NTP tests       : 111 111 1111
Interleaved     : No
Authenticated   : No
TX timestamping : Kernel
RX timestamping : Kernel
Total TX        : 25
Total RX        : 25
Total valid RX  : 25
```

`NTP tests : 111 111 1111` — las diez pruebas de sanidad de paquete de RFC 5905 pasan. Cualquier `0` nombra exactamente la validación que falló; este es el diagnóstico por paquete más profundo disponible.

Salida legible por máquina para scripts y exportadores:

```console
$ chronyc -c tracking
0A140005,ntp1.internal.example.net,3,1787840981.4,0.000012345,-0.000005678,0.000041234,12.345,-0.001,0.087,0.012345678,0.001234567,64.2,Normal
```

Campos en orden: refid, nombre de referencia, estrato, hora de referencia, offset de la hora del sistema, último offset, offset RMS, frecuencia, frecuencia residual, skew, retardo raíz, dispersión raíz, intervalo de actualización, estado de segundo intercalar.

Control en tiempo de ejecución:

```console
# chronyc makestep                  # step NOW — only with no workload running
200 OK

# chronyc waitsync 60 0.1           # block until root distance < 0.1s or 60s
try: 1, refid: 0A140005, correction: 0.000012, skew: 0.087

# chronyc burst 4/4                 # take 4 measurements immediately
200 OK

# chronyc offline / chronyc online  # for intermittently connected hosts
200 OK

# chronyc serverstats               # only meaningful on a server
NTP packets received       : 1245891
NTP packets dropped        : 0
Command packets received   : 421
Command packets dropped    : 0
Client log records dropped : 0
NTS-KE connections accepted: 3121
NTS-KE connections dropped : 0
Authenticated NTP packets  : 1102337
Interleaved NTP packets    : 0
NTP timestamps held        : 0
NTP timestamp span         : 0
```

### 11.5 Lectura de la salida de `ntpq`

```console
$ ntpq -pn
     remote           refid      st t when poll reach   delay   offset  jitter
==============================================================================
*10.20.0.5       192.36.143.150   2 u   37   64  377   12.345   -0.512   0.234
+10.20.0.6       193.79.237.14    2 u   41   64  377   15.678   +0.891   0.456
-162.159.200.1   130.133.1.10     3 u   30   64  377   28.901   +3.456   1.234
x203.0.113.44    17.253.34.253    2 u   35   64  377   19.204  +48.231   0.612
 198.51.100.7    .INIT.          16 u    -   64    0    0.000    0.000   0.000
```

El código de recuento (tally code) en la columna 1 — lo pregunta el examen y también todo incidente real:

| Código | Nombre | Significado |
|---|---|---|
| (espacio) | reject | Falló las comprobaciones de sanidad, o estrato 16 |
| `x` | falsetick | Rechazada por el algoritmo de intersección — **discrepa con la mayoría** |
| `.` | excess | Más allá de las 10 primeras fuentes por distancia de sincronización |
| `-` | outlier | Descartada por el algoritmo de clustering |
| `+` | candidate | Incluida en la combinación final |
| `#` | selected | Buena, pero no entre las 6 primeras |
| `*` | **sys.peer** | La referencia seleccionada. Exactamente una. |
| `o` | pps.peer | Seleccionada, con disciplina PPS (referencia de hardware) |

Semántica de las columnas: `st` = estrato, `t` = tipo (`u` unicast, `l` local, `m` multicast, `b` broadcast, `p` pool), `when` = segundos desde la última respuesta, `poll` = intervalo de sondeo actual en segundos, `reach` = registro de desplazamiento en **octal**, `delay`/`offset`/`jitter` en **milisegundos** (chrony los reporta en segundos: un desajuste de unidades que ha provocado alertas mal configuradas de verdad).

```console
$ ntpq -c 'rv 0'
associd=0 status=0615 leap_none, sync_ntp, 1 event, clock_sync,
version="ntpd 4.2.8p15@1.3728-o Mon Feb  1 00:00:00 UTC 2021 (1)",
processor="x86_64", system="Linux/6.1.0-18-amd64", leap=00, stratum=3,
precision=-24, rootdelay=25.123, rootdisp=45.678, refid=10.20.0.5,
reftime=eb3c9a45.7b2f1c04  Thu, Aug 27 2026 14:29:41.481,
clock=eb3c9ac9.1f8b3d21  Thu, Aug 27 2026 14:32:09.123, peer=34215, tc=6,
mintc=3, offset=-0.512, frequency=-8.203, sys_jitter=0.234,
clk_jitter=0.198, clk_wander=0.012

$ ntpq -c 'as'
ind assid status  conf reach auth condition  last_event cnt
===========================================================
  1 34215  963a   yes   yes  none  sys.peer    sys_peer  3
  2 34216  9324   yes   yes  none  candidate   reachable 2
  3 34217  9024   yes   yes  none  outlier     reachable 2
  4 34218  90fa   yes   yes  none  falsetick   reachable 15
```

`status=0615` se decodifica como `leap_none, sync_ntp, clock_sync`: sincronizado. `status=c016` (`leap_alarm, sync_unspec`) significa no sincronizado, y `leap_alarm` es el bit que hace que los clientes rechacen este servidor.

### 11.6 A nivel de paquete

```console
# tcpdump -n -i any -v 'udp port 123' -c 2
tcpdump: listening on any, link-type LINUX_SLL2 (Linux cooked v2), capture size 262144 bytes
14:32:09.482913 IP (tos 0x0, ttl 64, id 0, offset 0, flags [DF], proto UDP (17), length 76)
    10.20.0.15.35123 > 10.20.0.5.123: NTPv4, Client, length 48
        Leap indicator:  (0), Stratum 0 (unspecified), poll 6 (64s), precision -25
        Root Delay: 0.000000, Root dispersion: 0.000000, Reference-ID: (unspec)
          Reference Timestamp:  0.000000000
          Originator Timestamp: 0.000000000
          Receive Timestamp:    0.000000000
          Transmit Timestamp:   3959335929.482913000 (2026-08-27T14:32:09Z)
            Originator - Receive Timestamp:  0.000000000
            Originator - Transmit Timestamp: 3959335929.482913000 (2026-08-27T14:32:09Z)
14:32:09.495241 IP (tos 0x0, ttl 63, id 42311, offset 0, flags [none], proto UDP (17), length 76)
    10.20.0.5.123 > 10.20.0.15.35123: NTPv4, Server, length 48
        Leap indicator:  (0), Stratum 2 (secondary reference), poll 6 (64s), precision -25
        Root Delay: 0.004791, Root dispersion: 0.003448, Reference-ID: 192.36.143.150
          Reference Timestamp:  3959335781.194837000 (2026-08-27T14:29:41Z)
          Originator Timestamp: 3959335929.482913000 (2026-08-27T14:32:09Z)
          Receive Timestamp:    3959335929.489011000 (2026-08-27T14:32:09Z)
          Transmit Timestamp:   3959335929.489102000 (2026-08-27T14:32:09Z)
```

Esos son literalmente T1 (Transmit en el paquete del cliente), T2 (Receive) y T3 (Transmit en la respuesta); T4 es la marca de tiempo local de la captura. Puedes calcular el offset y el retardo a mano a partir de esta captura: un ejercicio útil cuando sospechas que un middlebox está reescribiendo marcas de tiempo.

Si no llega respuesta, distingue "bloqueado" de "no está escuchando":

```console
$ ss -ulpn | grep :123
UNCONN 0  0    0.0.0.0:123   0.0.0.0:*  users:(("chronyd",pid=821,fd=5))
UNCONN 0  0       [::]:123      [::]:*  users:(("chronyd",pid=821,fd=6))

$ nmap -sU -p 123 --script ntp-info ntp.internal.example.net
PORT    STATE SERVICE
123/udp open  ntp
```

### 11.7 Probar código dependiente de la hora sin tocar el reloj

Nunca hagas saltar un reloj compartido para probar un camino de expiración.

```console
$ faketime '2027-01-01 00:00:00' openssl s_client -connect api.example.net:443 </dev/null 2>&1 | grep -E 'Verify|verify error'
verify error:num=10:certificate has expired
    Verify return code: 10 (certificate has expired)

$ datefudge -s '2026-12-31' date -u
Thu Dec 31 00:00:00 UTC 2026
```

`libfaketime` intercepta `clock_gettime`/`gettimeofday` vía `LD_PRELOAD` solo para ese proceso. En contenedores, prefiere un namespace `CLONE_NEWTIME` mediante `unshare --time` para pruebas del reloj monótono, recordando la §9.2: no moverá `CLOCK_REALTIME`.

---

## 12. Resumen orientado al examen

**Ficheros**

| Ruta | Propósito |
|---|---|
| `/usr/share/zoneinfo/` | Base de datos de zonas horarias compilada en TZif |
| `/etc/localtime` | Enlace simbólico → la zona activa. Consumido por glibc. |
| `/etc/timezone` | *Nombre* de zona en texto plano (familia Debian). Informativo para glibc. |
| `/etc/adjtime` | Deriva del RTC + convención **`UTC` o `LOCAL`** |
| `/etc/ntp.conf` | Configuración de `ntpd` |
| `/etc/chrony.conf` (RHEL) / `/etc/chrony/chrony.conf` (Debian) | Configuración de `chronyd` |
| `/etc/systemd/timesyncd.conf` | Configuración de `systemd-timesyncd` |
| `/var/lib/ntp/ntp.drift`, `/var/lib/chrony/chrony.drift` | Error de frecuencia persistido |
| `/dev/rtc0`, `/sys/class/rtc/rtc0/` | Dispositivo del reloj de hardware |

**Comandos**

| Comando | Propósito |
|---|---|
| `date` | Mostrar/fijar el reloj del sistema; formatear con `+FMT`; analizar con `-d` |
| `hwclock` | Leer/escribir el RTC. `-r` leer, `-w`/`--systohc` sistema→RTC, `-s`/`--hctosys` RTC→sistema |
| `timedatectl` | Interfaz de systemd: `set-time`, `set-timezone`, `set-ntp`, `set-local-rtc`, `list-timezones`, `timesync-status` |
| `tzselect` | Selector interactivo de zona; imprime un valor de `TZ`, no cambia nada |
| `zdump -v <zona>` | Volcar las transiciones de horario de verano de una zona |
| `ntpd` | Demonio NTP de referencia |
| `ntpq -p` | **Consultar los pares NTP** — el objetivo exige explícitamente conocerlo |
| `ntpdate` | Sincronización de una sola pasada, obsoleta. Sustituida por `sntp -s` / `chronyd -q` |
| `sntp` | Cliente SNTP moderno de una sola pasada |
| `chronyd` | Demonio de chrony. `-q` fijar una vez y salir, **`-Q` solo medir**, `-p` comprobar configuración |
| `chronyc` | Control de chrony: `tracking`, `sources -v`, `sourcestats`, `activity`, `ntpdata`, `makestep`, `waitsync`, `authdata` |
| `adjtimex` | Leer/fijar directamente las variables de disciplina NTP del kernel |

**Conceptos que más se preguntan**

- **Estrato 16 = no sincronizado.** El estrato 0 es una referencia física, no un servidor.
- **`reach` es octal; `377` es perfecto.**
- **`*` en `ntpq -p` es el par seleccionado; `x` es un falseticker.**
- **El RTC no tiene zona horaria** — la línea 3 de `/etc/adjtime` aporta la convención.
- **`pool.ntp.org` es un round-robin de DNS**; usa `0.`–`3.` o una zona de proveedor, y cuatro o más fuentes.
- **`--systohc` escribe en el hardware; `--hctosys` escribe en el sistema.**
- **`timedatectl set-time` se rechaza mientras `set-ntp` esté activo.**

**Las tres aserciones que debe satisfacer un nodo de producción**

```console
$ timedatectl show --property=NTPSynchronized --property=LocalRTC --property=Timezone --value
yes
no
Etc/UTC
```

---

## 13. Referencias

**LPI**

- Objetivos del examen LPIC-1 101-500 — https://www.lpi.org/our-certifications/exam-101-objectives/
- Objetivos del examen LPIC-1 102-500 — https://www.lpi.org/our-certifications/exam-102-objectives/
- Visión general de la certificación LPIC-1 — https://www.lpi.org/our-certifications/lpic-1-overview/

**Estándares**

- RFC 5905 — Network Time Protocol Version 4: Protocol and Algorithms Specification — https://www.rfc-editor.org/rfc/rfc5905
- RFC 5906 — Network Time Protocol Version 4: Autokey Specification — https://www.rfc-editor.org/rfc/rfc5906
- RFC 8915 — Network Time Security for the Network Time Protocol — https://www.rfc-editor.org/rfc/rfc8915
- RFC 6238 — TOTP: Time-Based One-Time Password Algorithm — https://www.rfc-editor.org/rfc/rfc6238
- Visión general de IEEE 1588 (PTP) — https://standards.ieee.org/ieee/1588/6825/
- Variable de entorno `TZ` de POSIX, Base Definitions cap. 8 — https://pubs.opengroup.org/onlinepubs/9699919799/basedefs/V1_chap08.html

**Datos de zonas horarias**

- IANA Time Zone Database — https://www.iana.org/time-zones
- Teoría y pragmática de `tzdb` (`theory.html`) — https://data.iana.org/time-zones/theory.html

**chrony**

- Índice de documentación de chrony — https://chrony-project.org/documentation.html
- `chrony.conf(5)` — https://chrony-project.org/doc/4.6/chrony.conf.html
- `chronyc(1)` — https://chrony-project.org/doc/4.6/chronyc.html
- `chronyd(8)` — https://chrony-project.org/doc/4.6/chronyd.html
- FAQ de chrony (segundos intercalares, virtualización, contenedores) — https://chrony-project.org/faq.html

**Implementación de referencia de NTP**

- Documentación del Proyecto NTP — https://www.ntp.org/documentation/4.2.8-series/
- Restricciones de acceso de `ntp.conf` — https://www.ntp.org/documentation/4.2.8-series/accopt/
- `ntpq` — https://www.ntp.org/documentation/4.2.8-series/ntpq/
- Algoritmos de selección, clustering y combinación de reloj — https://www.ntp.org/documentation/4.2.8-series/select/
- Proyecto NTP Pool — https://www.ntppool.org/
- Guía de uso del NTP Pool para fabricantes — https://www.ntppool.org/vendors.html
- CVE-2013-5211 (amplificación de `monlist`) — https://nvd.nist.gov/vuln/detail/CVE-2013-5211

**systemd**

- `timedatectl(1)` — https://www.freedesktop.org/software/systemd/man/latest/timedatectl.html
- `systemd-timesyncd.service(8)` — https://www.freedesktop.org/software/systemd/man/latest/systemd-timesyncd.service.html
- `timesyncd.conf(5)` — https://www.freedesktop.org/software/systemd/man/latest/timesyncd.conf.html
- `systemd.special(7)` — `time-sync.target` — https://www.freedesktop.org/software/systemd/man/latest/systemd.special.html

**util-linux y el kernel**

- `hwclock(8)` — https://man7.org/linux/man-pages/man8/hwclock.8.html
- `date(1)` — https://man7.org/linux/man-pages/man1/date.1.html
- `adjtimex(2)` — https://man7.org/linux/man-pages/man2/adjtimex.2.html
- `clock_gettime(2)` — https://man7.org/linux/man-pages/man2/clock_gettime.2.html
- `time_namespaces(7)` — https://man7.org/linux/man-pages/man7/time_namespaces.7.html
- `capabilities(7)` — `CAP_SYS_TIME` — https://man7.org/linux/man-pages/man7/capabilities.7.html
- Documentación del cronometraje en el kernel — https://docs.kernel.org/timers/index.html
- Infraestructura de reloj PTP por hardware del kernel — https://docs.kernel.org/driver-api/ptp.html

**Segundos intercalares y servicios de hora en la nube**

- Anuncios de segundo intercalar del BIPM (Bulletin C) — https://www.bipm.org/en/bipm-services/timescales/leap-second.html
- Resolución 4 de la CGPM (2022), sobre el futuro del segundo intercalar — https://www.bipm.org/en/committees/cg/cgpm/27-2022/resolution-4
- Google Public NTP y leap smear — https://developers.google.com/time/smear
- Amazon Time Sync Service — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/set-time.html
- Google Cloud: configurar NTP en una VM — https://cloud.google.com/compute/docs/instances/configure-ntp
- Azure: sincronización horaria para VMs Linux — https://learn.microsoft.com/en-us/azure/virtual-machines/linux/time-sync

**Monitorización**

- Colector timex de `node_exporter` — https://github.com/prometheus/node_exporter
- Alertas del mixin node-exporter de Prometheus (`NodeClockSkewDetected`, `NodeClockNotSynchronising`) — https://github.com/prometheus/node_exporter/blob/master/docs/node-mixin/alerts/node.libsonnet

**Guías de distribuciones**

- Red Hat Enterprise Linux — Configuring basic system settings, "Configuring time synchronization" — https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/configuring_basic_system_settings/configuring-time-synchronization_configuring-basic-system-settings
- Wiki de Debian — DateTime — https://wiki.debian.org/DateTime
- Arch Wiki — System time — https://wiki.archlinux.org/title/System_time
- Arch Wiki — Time synchronization — https://wiki.archlinux.org/title/Time_synchronization