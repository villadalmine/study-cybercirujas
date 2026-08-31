# LPIC-1 — Tema 108.2: Registro del sistema (System Logging)
## Ejercicios guiados

**Objetivo cubierto:** LPI 102-500, objetivo 108.2 — *System logging* (`journalctl`, `systemd-cat`, `/etc/systemd/journald.conf`, `/var/log/journal/`, `systemd-journald`, `/etc/rsyslog.conf`, `logger`, `/var/log/` y rotación de logs).

---

## Prerrequisitos del laboratorio

Necesitás una **VM basada en systemd con acceso root** y conectividad de red hacia un segundo host si querés completar el Ejercicio 6. Tomá un snapshot de la VM antes de empezar: varios pasos rompen el logging a propósito para que puedas repararlo.

Los ejercicios están escritos para funcionar en las dos familias principales. Donde difieren:

| | Debian / Ubuntu | RHEL / Rocky / Alma / Fedora |
|---|---|---|
| Log general (catch-all) | `/var/log/syslog` | `/var/log/messages` |
| Log de autenticación | `/var/log/auth.log` | `/var/log/secure` |
| Entrada de rsyslog desde el journal | `imuxsock` (socket de reenvío) | `imjournal` |
| Archivo de estado de logrotate | `/var/lib/logrotate/status` | `/var/lib/logrotate/logrotate.status` |

Confirmá tu punto de partida antes de empezar:

```bash
systemctl is-active systemd-journald
systemctl is-active rsyslog 2>/dev/null || echo "rsyslog not installed"
journalctl --version | head -1
```

Si `rsyslog` no está presente, instalalo (`apt install rsyslog` / `dnf install rsyslog`) — los Ejercicios 4–6 dependen de él.

---

## Ejercicio 1 — El journal como base de datos estructurada

`systemd-journald` **no** es un escritor de logs de texto. Almacena registros binarios indexados, de tipo clave-valor. Entender eso cambia la forma en que lo consultás.

### Bloque 1.1 — Dónde vive realmente el journal

1. Determiná el modo de almacenamiento actualmente en vigor, incluyendo todos los drop-in de la distribución:

   ```bash
   systemd-analyze cat-config systemd/journald.conf | grep -vE '^\s*(#|$)'
   ```

   Salida esperada en un sistema de fábrica (solo el encabezado de sección, es decir, todos los valores son los predeterminados compilados):

   ```
   [Journal]
   ```

2. Verificá cuál de los dos directorios posibles del journal existe:

   ```bash
   ls -ld /run/log/journal /var/log/journal 2>&1
   ```

   Salida típica en un sistema con journal **volátil**:

   ```
   ls: cannot access '/var/log/journal': No such file or directory
   drwxr-sr-x+ 3 root systemd-journal 60 Aug 27 08:41 /run/log/journal
   ```

3. Mirá los archivos reales del journal y su propiedad:

   ```bash
   ls -lh /run/log/journal/*/ 2>/dev/null || ls -lh /var/log/journal/*/
   ```

   ```
   -rw-r-----+ 1 root systemd-journal 8.0M Aug 27 09:03 system.journal
   -rw-r-----+ 1 root systemd-journal 8.0M Aug 27 08:41 user-1000.journal
   ```

4. Confirmá el espacio en disco que reporta el propio journald:

   ```bash
   journalctl --disk-usage
   ```

   ```
   Archived and active journals take up 40.0M in the file system.
   ```

> **Verificá tu comprensión — Bloque 1.1**
>
> **Q1.1** El directorio `/var/log/journal` no existe y `Storage=` no está definido. ¿Dónde se están escribiendo los registros de log, y qué les pasa en el próximo reinicio?
> **Q1.2** `system.journal` tiene modo `0640`, propietario `root`, grupo `systemd-journal`, y el `+` en la cadena de modo indica una ACL. ¿Qué usuarios que no sean root pueden leer el journal *del sistema*, y por qué mecanismo?
> **Q1.3** ¿Por qué `du -sh /var/log/journal` a veces reporta *menos* que `journalctl --disk-usage`?

---

### Bloque 1.2 — Filtrado: los cuatro ejes

Toda consulta al journal filtra sobre uno de cuatro ejes: **tiempo**, **unidad/identidad**, **prioridad** o **arranque (boot)**. Combinarlos es un AND.

5. Ventanas de tiempo — absolutas y relativas:

   ```bash
   journalctl --since "2026-08-27 08:00:00" --until "2026-08-27 09:00:00" | wc -l
   journalctl --since "-15min" --no-pager | tail -5
   journalctl --since yesterday --until "today 06:00" -n 20
   ```

6. Identidad — una unidad, un binario, un PID, un UID:

   ```bash
   journalctl -u sshd.service -n 20 --no-pager
   journalctl _COMM=sudo -n 10 --no-pager
   journalctl _PID=1 -n 5 --no-pager
   journalctl _UID=$(id -u nobody) -n 5 --no-pager
   ```

7. Prioridad — un umbral, o un rango explícito:

   ```bash
   journalctl -p err -b --no-pager        # err(3) and MORE severe: 3,2,1,0
   journalctl -p warning..err -b --no-pager   # exactly 4,3
   journalctl -p 2 -b --no-pager          # crit and above
   ```

8. Arranque — el arranque actual, uno anterior, el buffer circular del kernel:

   ```bash
   journalctl --list-boots
   journalctl -b -1 -p err --no-pager
   journalctl -k -b --no-pager | head
   ```

   Salida de `--list-boots`:

   ```
   IDX BOOT ID                          FIRST ENTRY                 LAST ENTRY
    -1 3f2b1c9a4d7e4f10a2b3c4d5e6f70819 Tue 2026-08-26 07:14:22 UTC Tue 2026-08-26 22:03:57 UTC
     0 a1b2c3d4e5f6470819a2b3c4d5e6f708 Wed 2026-08-27 08:41:09 UTC Wed 2026-08-27 09:12:44 UTC
   ```

9. Descubrí qué es filtrable en lugar de adivinar:

   ```bash
   journalctl -N | head -30            # all field names present
   journalctl -F _SYSTEMD_UNIT | sort  # all values seen for that field
   journalctl -F PRIORITY
   ```

> **Verificá tu comprensión — Bloque 1.2**
>
> **Q1.4** `journalctl -p warning` devuelve entradas con valores de `PRIORITY` del 0 al 4. Explicá por qué "warning y superiores" significa *numéricamente menor*.
> **Q1.5** ¿Cuál es la diferencia entre `journalctl -b -1` y `journalctl --since yesterday`? Dá un escenario donde devuelvan conjuntos completamente distintos.
> **Q1.6** `journalctl --list-boots` muestra solo el índice `0`. ¿Qué te dice eso sobre la configuración de journald del sistema?
> **Q1.7** Querés todos los mensajes del binario `sshd`, incluidos los emitidos antes de que `sshd.service` fuera la unidad propietaria (por ejemplo, durante un script de instalación). ¿Usarías `-u sshd` o `_COMM=sshd`? ¿Por qué?

---

### Bloque 1.3 — Formatos de salida y campos de confianza

10. Inspeccioná una entrada completa:

    ```bash
    journalctl -u systemd-logind.service -n 1 -o verbose --no-pager
    ```

    Salida abreviada:

    ```
    Wed 2026-08-27 08:41:11.238412 UTC [s=9c1e...;i=1a4;b=a1b2...;m=4e21;t=63a1;x=8f2c]
        _BOOT_ID=a1b2c3d4e5f6470819a2b3c4d5e6f708
        _MACHINE_ID=7d0c8e1f2a3b4c5d6e7f8091a2b3c4d5
        _HOSTNAME=lab01
        PRIORITY=6
        SYSLOG_FACILITY=4
        SYSLOG_IDENTIFIER=systemd-logind
        _TRANSPORT=journal
        _UID=0
        _GID=0
        _COMM=systemd-logind
        _EXE=/usr/lib/systemd/systemd-logind
        _CMDLINE=/usr/lib/systemd/systemd-logind
        _SYSTEMD_UNIT=systemd-logind.service
        _SYSTEMD_CGROUP=/system.slice/systemd-logind.service
        _PID=612
        MESSAGE=New session 3 of user root.
    ```

11. Compará los formatos que realmente vas a usar en scripts y durante un incidente:

    ```bash
    journalctl -u sshd -n 3 -o cat          # message text only
    journalctl -u sshd -n 3 -o short-iso    # ISO-8601 timestamps
    journalctl -u sshd -n 1 -o json-pretty  # machine-parseable
    journalctl -u sshd -n 3 -o short-precise
    ```

12. Seguí una unidad en vivo y abrí las explicaciones del catálogo:

    ```bash
    journalctl -u sshd.service -f
    # in a second terminal: systemctl restart sshd ; ssh localhost true
    # Ctrl-C to stop
    journalctl -xb -p err --no-pager
    ```

> **Verificá tu comprensión — Bloque 1.3**
>
> **Q1.8** Los campos en la salida de `-o verbose` se dividen en dos clases: los que empiezan con `_` y los que no. ¿Cuál es la diferencia relevante para la seguridad, y por qué importa cuando investigás una línea de log sospechosa?
> **Q1.9** La entrada de arriba muestra `SYSLOG_FACILITY=4` y `PRIORITY=6`. Traducí ambos a sus nombres de syslog, e indicá cómo sería un selector clásico de syslog que coincida con este mensaje.
> **Q1.10** ¿Qué agrega el `-x` en `journalctl -xb`, y de dónde viene ese texto extra?
> **Q1.11** Necesitás alimentar mensajes del journal a una tubería de procesamiento de texto que espera solo el cuerpo del mensaje. ¿Qué formato de salida elegís, y qué información perdés?

---

## Ejercicio 2 — Hacer el journal persistente y acotado

Un journal volátil es un incidente de producción esperando a ocurrir: la evidencia del crash muere con el crash.

### Bloque 2.1 — Cambiar a almacenamiento persistente

1. Creá el directorio persistente y entregáselo a journald. **Los dos métodos de abajo son correctos; usá exactamente uno.**

   Método A — crear el directorio (funciona porque el `Storage=auto` predeterminado significa "persistente *si* existe `/var/log/journal`"):

   ```bash
   mkdir -p /var/log/journal
   systemd-tmpfiles --create --prefix /var/log/journal
   ```

   Método B — declararlo explícitamente con un drop-in:

   ```bash
   mkdir -p /etc/systemd/journald.conf.d
   cat > /etc/systemd/journald.conf.d/10-persistent.conf <<'EOF'
   [Journal]
   Storage=persistent
   EOF
   ```

2. Aplicalo y forzá la migración del journal de runtime a disco:

   ```bash
   systemctl restart systemd-journald
   journalctl --flush
   ls -ld /var/log/journal/$(cat /etc/machine-id)
   ```

   ```
   drwxr-sr-x+ 2 root systemd-journal 4096 Aug 27 09:20 /var/log/journal/7d0c8e1f2a3b4c5d6e7f8091a2b3c4d5
   ```

3. Verificá que `systemd-tmpfiles` haya establecido los permisos correctamente (este es el paso que la gente se saltea, y después journald se niega silenciosamente a escribir):

   ```bash
   getfacl /var/log/journal/$(cat /etc/machine-id) | grep -E 'group:(adm|wheel)'
   ```

   ```
   group:adm:r-x
   default:group:adm:r-x
   ```

4. Reiniciá y demostrá la persistencia:

   ```bash
   systemctl reboot
   # after login:
   journalctl --list-boots
   ```

> **Verificá tu comprensión — Bloque 2.1**
>
> **Q2.1** `Storage=` acepta `volatile`, `persistent`, `auto` y `none`. Describí el comportamiento de cada uno, e indicá cuál hace que `/var/log/journal` sea obligatorio en lugar de opcional.
> **Q2.2** Creaste `/var/log/journal` con un `mkdir` simple y reiniciaste journald, pero `journalctl --list-boots` sigue mostrando solo el arranque actual después de un reinicio. Nombrá dos causas independientes y el comando que las distingue.
> **Q2.3** ¿Cuál es la diferencia funcional entre `journalctl --flush`, `journalctl --sync` y `journalctl --rotate`?
> **Q2.4** ¿Por qué `Storage=none` igual deja que `journalctl -f` produzca salida para algunos mensajes?

---

### Bloque 2.2 — Acotar el journal para que no pueda llenar `/var`

5. Establecé límites explícitos. Notá que **los límites de tamaño y los de tiempo son techos independientes: gana el que se dispare primero**:

   ```bash
   cat > /etc/systemd/journald.conf.d/20-limits.conf <<'EOF'
   [Journal]
   SystemMaxUse=500M
   SystemKeepFree=1G
   SystemMaxFileSize=50M
   SystemMaxFiles=20
   MaxRetentionSec=1month
   MaxFileSec=1day
   Compress=yes
   EOF
   systemctl restart systemd-journald
   ```

6. Observá cómo journald reporta el techo efectivo que calculó:

   ```bash
   journalctl -u systemd-journald -b -n 20 --no-pager | grep -i 'journal.*limit\|space'
   ```

   ```
   systemd-journald[318]: System journal (/var/log/journal/7d0c…) is currently using 48.0M.
   Maximum allowed usage is set to 500.0M.
   Leaving at least 1.0G free (of currently available 12.4G of disk space).
   Enforced usage limit is 500.0M, of which 452.0M are still available.
   ```

7. Recuperá espacio manualmente — los tres modos de vacuum:

   ```bash
   journalctl --vacuum-size=200M
   journalctl --vacuum-time=7d
   journalctl --vacuum-files=5
   ```

   ```
   Deleted archived journal /var/log/journal/7d0c…/system@0005e1….journal (8.0M).
   Vacuuming done, freed 24.0M of archived journals from /var/log/journal/7d0c….
   ```

8. Controlá el rate limiting, que es una causa muy común de "faltan mis líneas de log":

   ```bash
   journalctl -b | grep -i 'suppressed'
   ```

   ```
   systemd-journald[318]: Suppressed 4213 messages from /system.slice/noisy-app.service
   ```

   ```bash
   cat > /etc/systemd/journald.conf.d/30-ratelimit.conf <<'EOF'
   [Journal]
   RateLimitIntervalSec=30s
   RateLimitBurst=20000
   EOF
   systemctl restart systemd-journald
   ```

9. Verificá la integridad de los journals almacenados:

   ```bash
   journalctl --verify
   ```

   ```
   PASS: /var/log/journal/7d0c…/user-1000.journal
   PASS: /var/log/journal/7d0c…/system.journal
   ```

> **Verificá tu comprensión — Bloque 2.2**
>
> **Q2.5** Están definidos tanto `SystemMaxUse=500M` como `SystemKeepFree=1G`, y `/var` tiene 800 MB libres. ¿Cuántos datos de journal va a retener journald?
> **Q2.6** ¿Por qué journald nunca trunca un archivo de journal existente para recuperar espacio? ¿Qué hace en su lugar, y qué implica eso sobre `SystemMaxFileSize` en relación con `SystemMaxUse`?
> **Q2.7** Un servicio registra 50 000 líneas en 10 segundos y la mayoría nunca aparece. ¿Qué dos parámetros cambiarías, y cuál es el riesgo de deshabilitar el mecanismo por completo?
> **Q2.8** `journalctl --vacuum-time=7d` no borra nada aunque tenés 30 días de logs. ¿Cuál es la explicación más probable?

---

## Ejercicio 3 — Inyectar mensajes: `logger` y `systemd-cat`

### Bloque 3.1 — `logger`, el cliente de syslog

1. El par facility/priority predeterminado cuando no especificás ninguno:

   ```bash
   logger "plain test message from $USER"
   journalctl -n 1 -o verbose --no-pager | grep -E 'PRIORITY|SYSLOG_FACILITY|SYSLOG_IDENTIFIER|MESSAGE='
   ```

   ```
   PRIORITY=5
   SYSLOG_FACILITY=1
   SYSLOG_IDENTIFIER=root
   MESSAGE=plain test message from root
   ```

2. Establecé facility, priority y tag explícitamente, y hacé eco a stderr:

   ```bash
   logger -p local3.err -t backup-job -s "snapshot failed: rc=17"
   ```

   ```
   backup-job: snapshot failed: rc=17
   ```

   ```bash
   journalctl -t backup-job -n 1 -o verbose --no-pager | grep -E 'PRIORITY|SYSLOG_FACILITY|MESSAGE='
   ```

   ```
   PRIORITY=3
   SYSLOG_FACILITY=19
   MESSAGE=snapshot failed: rc=17
   ```

3. Cubrí las flags restantes que aparecen en scripts reales:

   ```bash
   logger -p cron.info --id=$$ -t healthcheck "started"
   echo -e "line one\nline two" | logger -t multiline -p local0.notice
   logger -p local0.debug -t sizetest "$(head -c 300 /dev/zero | tr '\0' 'x')"
   journalctl -t multiline -n 2 -o cat --no-pager
   ```

4. Emití un mensaje en cada prioridad y observá el comportamiento del umbral:

   ```bash
   for p in emerg alert crit err warning notice info debug; do
     logger -p local5."$p" -t priotest "message at priority $p"
   done
   journalctl -t priotest -p err --no-pager -o short-iso
   ```

   Solo vuelven cuatro líneas — `emerg`, `alert`, `crit` y `err`.

> **Verificá tu comprensión — Bloque 3.1**
>
> **Q3.1** `logger` escribió `SYSLOG_FACILITY=19`. ¿Qué facility es esa, y cuál es el rango numérico de las facilities `localN`?
> **Q3.2** ¿Por qué `local0`–`local7` es la elección correcta para tus propias aplicaciones en lugar de reutilizar `daemon` o `user`?
> **Q3.3** En el paso 1, `SYSLOG_IDENTIFIER` fue `root` aunque no se dio ningún `-t`. ¿De dónde salió ese valor, y por qué confiar en él es frágil en un trabajo de cron?
> **Q3.4** ¿Qué hace `-s`, y por qué lo usarías dentro del script de `ExecStart` de una unidad systemd?

---

### Bloque 3.2 — `systemd-cat` y la distinción de transporte

5. Ejecutá un comando con toda su salida capturada dentro del journal:

   ```bash
   systemd-cat -t diskcheck -p warning df -h /
   journalctl -t diskcheck -n 5 -o cat --no-pager
   ```

   ```
   Filesystem      Size  Used Avail Use% Mounted on
   /dev/vda2        14G  2.1G   12G  16% /
   ```

6. Canalizá (pipe) hacia él en cambio:

   ```bash
   echo "config reload requested" | systemd-cat -t reloader -p notice
   ```

7. Ahora compará el **transporte** de un mensaje de `logger` y uno de `systemd-cat` — esta es la diferencia arquitectónica clave:

   ```bash
   logger -t transport-a "via syslog socket"
   echo "via native protocol" | systemd-cat -t transport-b

   journalctl -t transport-a -n 1 -o verbose --no-pager | grep _TRANSPORT
   journalctl -t transport-b -n 1 -o verbose --no-pager | grep _TRANSPORT
   ```

   ```
   _TRANSPORT=syslog
   _TRANSPORT=journal
   ```

8. Enumerá todos los transportes presentes en el sistema en ejecución:

   ```bash
   journalctl -F _TRANSPORT
   ```

   ```
   audit
   driver
   journal
   kernel
   stdout
   syslog
   ```

> **Verificá tu comprensión — Bloque 3.2**
>
> **Q3.5** Explicá el significado de cada valor devuelto en el paso 8: `kernel`, `stdout`, `syslog`, `journal`, `driver`, `audit`.
> **Q3.6** Un mensaje enviado con `systemd-cat` tiene `_TRANSPORT=journal` y ningún `SYSLOG_FACILITY` a menos que definas uno. ¿Qué consecuencia práctica tiene eso para una regla de rsyslog como `local0.* /var/log/app.log`?
> **Q3.7** Tu servicio escribe a stdout y systemd lo arranca con `StandardOutput=journal`. ¿Qué transporte llevarán esas líneas, y cómo filtrás solo el stdout de ese servicio?
> **Q3.8** Dá una situación donde `systemd-cat` es claramente la herramienta correcta y otra donde lo es `logger`.

---

## Ejercicio 4 — rsyslog: selectores, acciones y orden de las reglas

Las reglas de rsyslog son pares `SELECTOR ACTION`. Un selector es `facility.priority`; **la prioridad significa "esta severidad y todo lo más severo"** salvo que la califiques.

### Bloque 4.1 — Leer la configuración que viene de fábrica

1. Leé el archivo principal y el directorio de drop-in:

   ```bash
   grep -vE '^\s*(#|$)' /etc/rsyslog.conf
   ls /etc/rsyslog.d/
   grep -vE '^\s*(#|$)' /etc/rsyslog.d/*.conf
   ```

   Reglas representativas de Debian:

   ```
   auth,authpriv.*                 /var/log/auth.log
   *.*;auth,authpriv.none          -/var/log/syslog
   kern.*                          -/var/log/kern.log
   mail.*                          -/var/log/mail.log
   *.emerg                         :omusrmsg:*
   ```

   Reglas representativas de RHEL:

   ```
   *.info;mail.none;authpriv.none;cron.none    /var/log/messages
   authpriv.*                                  /var/log/secure
   mail.*                                      -/var/log/maillog
   cron.*                                      /var/log/cron
   *.emerg                                     :omusrmsg:*
   ```

2. Identificá qué módulos de entrada están cargados — esto determina *de dónde saca rsyslog sus mensajes*:

   ```bash
   grep -hE '^\s*(module|\$ModLoad)' /etc/rsyslog.conf /etc/rsyslog.d/*.conf
   ```

   ```
   module(load="imuxsock")
   module(load="imklog")
   ```

   o, en RHEL:

   ```
   module(load="imuxsock")
   module(load="imjournal" StateFile="imjournal.state")
   ```

3. Validá la sintaxis sin reiniciar nada:

   ```bash
   rsyslogd -N1
   ```

   ```
   rsyslogd: version 8.2302.0, config validation run (level 1), master config /etc/rsyslog.conf
   rsyslogd: End of config validation run. Bye.
   ```

> **Verificá tu comprensión — Bloque 4.1**
>
> **Q4.1** Decodificá `*.*;auth,authpriv.none    -/var/log/syslog` por completo: cada token, incluido el `-` inicial en la ruta.
> **Q4.2** ¿Por qué ambas distribuciones enrutan `authpriv` a un archivo separado con permisos restrictivos en lugar de al catch-all?
> **Q4.3** ¿Cuál es la diferencia en el origen de los mensajes entre un sistema que corre `imjournal` y otro que corre solo `imuxsock`? ¿Cuál puede perder los metadatos de confianza del journal?
> **Q4.4** `*.info` y `*.*` — ¿bajo qué circunstancias estos dos selectores producen archivos distintos?

---

### Bloque 4.2 — Escribí tus propias reglas

4. Creá un conjunto de reglas que ejercite todos los calificadores de selector:

   ```bash
   cat > /etc/rsyslog.d/60-lab.conf <<'EOF'
   # 1) local4, all priorities, into a dedicated file
   local4.*                        /var/log/lab-all.log

   # 2) exactly "err", nothing more and nothing less severe
   local4.=err                     /var/log/lab-err-only.log

   # 3) everything from local4 EXCEPT debug
   local4.!debug                   /var/log/lab-nodebug.log

   # 4) two facilities, one threshold
   local5,local6.warning           /var/log/lab-warn.log

   # 5) property-based filter: message content
   :msg, contains, "TOKEN_LEAK"    /var/log/lab-security.log

   # 6) stop processing after a match so it does not also hit the catch-all
   :programname, isequal, "chatty"  /var/log/lab-chatty.log
   & stop
   EOF

   rsyslogd -N1 && systemctl restart rsyslog
   ```

5. Generá tráfico que golpee cada regla:

   ```bash
   for p in debug info notice warning err crit; do
     logger -p local4."$p" -t labtest "local4 $p"
   done
   logger -p local5.warning -t labtest "local5 warning"
   logger -p local6.info    -t labtest "local6 info (should NOT appear in lab-warn)"
   logger -p local0.notice  -t labtest "TOKEN_LEAK detected in build output"
   logger -p local0.info    -t chatty  "noise line"
   ```

6. Inspeccioná los resultados:

   ```bash
   wc -l /var/log/lab-*.log
   cat /var/log/lab-err-only.log
   grep -c . /var/log/lab-nodebug.log
   tail -1 /var/log/lab-security.log
   grep -c chatty /var/log/syslog /var/log/messages 2>/dev/null
   ```

   ```
     6 /var/log/lab-all.log
     1 /var/log/lab-err-only.log
     5 /var/log/lab-nodebug.log
     1 /var/log/lab-security.log
     1 /var/log/lab-warn.log
   ```

7. Agregá una plantilla propia para que el formato del archivo sea tuyo, no el predeterminado:

   ```bash
   cat > /etc/rsyslog.d/61-lab-template.conf <<'EOF'
   template(name="LabFormat" type="string"
            string="%TIMESTAMP:::date-rfc3339% %HOSTNAME% %syslogfacility-text%.%syslogseverity-text% [%syslogtag%] %msg%\n")

   local7.*   action(type="omfile" file="/var/log/lab-template.log" template="LabFormat")
   EOF

   rsyslogd -N1 && systemctl restart rsyslog
   logger -p local7.notice -t formatted "templated line"
   cat /var/log/lab-template.log
   ```

   ```
   2026-08-27T09:47:12.104883+00:00 lab01 local7.notice [formatted] templated line
   ```

> **Verificá tu comprensión — Bloque 4.2**
>
> **Q4.5** `local4.*` produjo 6 líneas y `local4.!debug` produjo 5. Explicá con precisión qué hizo el `!`, y qué habría coincidido con `local4.!=err`.
> **Q4.6** En la regla 4, `local5,local6.warning` — ¿el umbral `warning` se aplica a `local5`, a `local6`, o a ambos? ¿Cuál es la regla de sintaxis?
> **Q4.7** ¿Qué logró `& stop`, y qué les habría pasado a los mensajes de `chatty` sin él?
> **Q4.8** rsyslog evalúa las reglas de arriba hacia abajo y un mensaje puede coincidir con muchas. Dado eso, ¿por qué `& stop` es también una herramienta de *rendimiento* además de una de enrutamiento?
> **Q4.9** Nombrá tres acciones distintas de "escribir a un archivo" con las que se puede emparejar un selector, y dá la sintaxis de cada una.

---

## Ejercicio 5 — journald ↔ rsyslog: quién alimenta a quién

### Bloque 5.1 — Trazar el camino del mensaje

1. Identificá los sockets involucrados:

   ```bash
   ls -l /dev/log
   systemctl list-sockets | grep -i journal
   ```

   ```
   lrwxrwxrwx 1 root root 28 Aug 27 08:41 /dev/log -> /run/systemd/journal/dev-log
   /run/systemd/journal/dev-log    systemd-journald-dev-log.socket   systemd-journald.service
   /run/systemd/journal/socket     systemd-journald.socket           systemd-journald.service
   /run/systemd/journal/stdout     systemd-journald.service          systemd-journald.service
   ```

2. Verificá si journald está reenviando hacia un demonio de syslog:

   ```bash
   systemd-analyze cat-config systemd/journald.conf | grep -i forward
   ls -l /run/systemd/journal/syslog 2>&1
   ```

3. Habilitá el reenvío explícitamente y observá el efecto:

   ```bash
   cat > /etc/systemd/journald.conf.d/40-forward.conf <<'EOF'
   [Journal]
   ForwardToSyslog=yes
   MaxLevelStore=debug
   MaxLevelSyslog=info
   EOF
   systemctl restart systemd-journald
   systemctl restart rsyslog

   logger -p local0.debug  -t fwdtest "debug line"
   logger -p local0.notice -t fwdtest "notice line"

   journalctl -t fwdtest -p debug --no-pager -o cat
   grep fwdtest /var/log/syslog /var/log/messages 2>/dev/null
   ```

   El journal guarda **ambas** líneas; el archivo de syslog guarda solo la de `notice`.

> **Verificá tu comprensión — Bloque 5.1**
>
> **Q5.1** `/dev/log` es un enlace simbólico hacia `/run/systemd/journal/`. ¿Qué prueba eso sobre qué demonio recibe *primero* un mensaje de `logger` en un host con systemd?
> **Q5.2** Explicá la diferencia entre `MaxLevelStore` y `MaxLevelSyslog`, usando el resultado del paso 3 como evidencia.
> **Q5.3** En un host que usa `imjournal`, ¿hace falta `ForwardToSyslog=yes` para que rsyslog vea los mensajes del journal? Justificá tu respuesta.
> **Q5.4** Nombrá los cuatro parámetros `ForwardTo*` y dá un escenario de producción para cada uno.
> **Q5.5** Habilitás `ForwardToSyslog=yes` en un host con mucha carga y el uso de CPU sube notablemente. Explicá el mecanismo y dá una mitigación.

---

## Ejercicio 6 — Recolección centralizada de logs

### Bloque 6.1 — Receptor rsyslog

Ejecutá esto en el host **recolector** (llamalo `logsrv`, `10.0.0.10`).

1. Habilitá un listener TCP:

   ```bash
   cat > /etc/rsyslog.d/10-remote-in.conf <<'EOF'
   module(load="imtcp" MaxSessions="500")
   input(type="imtcp" port="514")

   template(name="RemoteFile" type="string"
            string="/var/log/remote/%HOSTNAME%/%PROGRAMNAME%.log")

   # Only remote traffic goes to the per-host tree, and then stops.
   if ($fromhost-ip != "127.0.0.1") then {
       action(type="omfile" dynaFile="RemoteFile" dirCreateMode="0750" fileCreateMode="0640")
       stop
   }
   EOF

   rsyslogd -N1 && systemctl restart rsyslog
   ss -ltnp | grep :514
   ```

   ```
   LISTEN 0  25  0.0.0.0:514  0.0.0.0:*  users:(("rsyslogd",pid=1442,fd=7))
   ```

2. Abrí el firewall:

   ```bash
   firewall-cmd --add-port=514/tcp --permanent && firewall-cmd --reload   # RHEL
   # or
   ufw allow 514/tcp                                                      # Debian
   ```

### Bloque 6.2 — Emisor rsyslog

Ejecutá esto en el **cliente**.

3. Reenviá todo, con una cola asistida por disco para que una caída del recolector no pierda mensajes:

   ```bash
   cat > /etc/rsyslog.d/90-remote-out.conf <<'EOF'
   *.* action(type="omfwd"
              target="10.0.0.10" port="514" protocol="tcp"
              queue.type="LinkedList"
              queue.filename="fwd_logsrv"
              queue.spoolDirectory="/var/spool/rsyslog"
              queue.maxDiskSpace="1g"
              queue.saveOnShutdown="on"
              action.resumeRetryCount="-1")
   EOF

   rsyslogd -N1 && systemctl restart rsyslog
   logger -p local0.notice -t remotetest "hello from $(hostname)"
   ```

4. El equivalente heredado (legacy) — tenés que poder leerlo en un examen y en configuraciones viejas:

   ```
   *.*    @@10.0.0.10:514      # TCP
   *.*    @10.0.0.10:514       # UDP
   ```

5. Verificá en el recolector:

   ```bash
   find /var/log/remote -type f
   tail -2 /var/log/remote/*/remotetest.log
   ```

6. Simulá una caída y confirmá que la cola funciona:

   ```bash
   # on collector:
   systemctl stop rsyslog
   # on client:
   logger -p local0.notice -t remotetest "sent while collector was down"
   ls -l /var/spool/rsyslog/
   # on collector:
   systemctl start rsyslog
   sleep 5 && tail -1 /var/log/remote/*/remotetest.log
   ```

> **Verificá tu comprensión — Bloque 6.1 / 6.2**
>
> **Q6.1** Traducí `*.* @@10.0.0.10:514` y `*.* @10.0.0.10:514` a palabras. ¿Qué único carácter los distingue, y qué cambia respecto de las garantías de entrega?
> **Q6.2** ¿Por qué `stop` es esencial dentro del bloque `if` en el recolector?
> **Q6.3** Sin `queue.filename`, ¿qué tipo de cola usa la acción, y qué pasa con los mensajes si rsyslog se reinicia mientras el recolector está inalcanzable?
> **Q6.4** `action.resumeRetryCount="-1"` — ¿qué significa `-1`, y cuál es el modo de falla de dejarlo en su valor predeterminado?
> **Q6.5** Los puertos 514/UDP y 514/TCP son ambos sin cifrar y sin autenticar. Nombrá los dos componentes nativos de systemd que proveen una alternativa basada en HTTPS, y una alternativa nativa de rsyslog.

---

## Ejercicio 7 — Rotación: `logrotate`

El journal se rota a sí mismo. **Los archivos de texto plano escritos por rsyslog no** — ese es el trabajo de `logrotate`.

### Bloque 7.1 — Leer la política existente

1. Valores predeterminados globales e inclusiones:

   ```bash
   grep -vE '^\s*(#|$)' /etc/logrotate.conf
   ls /etc/logrotate.d/
   ```

   ```
   weekly
   su root adm
   rotate 4
   create
   dateext
   include /etc/logrotate.d
   /var/log/wtmp {
       missingok
       monthly
       create 0664 root utmp
       rotate 1
   }
   ```

2. Inspeccioná el archivo de estado — así es como logrotate sabe cuándo rotó cada ruta por última vez:

   ```bash
   head -5 /var/lib/logrotate/status 2>/dev/null || head -5 /var/lib/logrotate/logrotate.status
   ```

   ```
   logrotate state -- version 2
   "/var/log/syslog" 2026-8-27-0:0:0
   "/var/log/auth.log" 2026-8-24-0:0:0
   ```

3. Averiguá *qué* lo ejecuta:

   ```bash
   systemctl list-timers logrotate.timer
   ls -l /etc/cron.daily/logrotate 2>/dev/null
   ```

### Bloque 7.2 — Escribir y probar una política

4. Creá una política que ejercite las directivas que tenés que conocer:

   ```bash
   cat > /etc/logrotate.d/lab <<'EOF'
   /var/log/lab-*.log {
       daily
       rotate 7
       maxsize 10M
       compress
       delaycompress
       missingok
       notifempty
       dateext
       dateformat -%Y%m%d
       create 0640 root adm
       sharedscripts
       postrotate
           /usr/bin/systemctl kill -s HUP --kill-whom=main rsyslog.service 2>/dev/null || true
       endscript
   }
   EOF
   ```

5. Hacé primero una corrida en seco — **`-d` implica `-v` y nunca toca el archivo de estado**:

   ```bash
   logrotate -d /etc/logrotate.d/lab
   ```

   ```
   reading config file /etc/logrotate.d/lab
   Handling 1 logs
   rotating pattern: /var/log/lab-*.log  after 1 days (7 rotations)
   empty log files are not rotated, log files >= 10485760 are rotated earlier, old logs are removed
   considering log /var/log/lab-all.log
     Now: 2026-08-27 09:58
     Last rotated at 2026-08-27 09:00
     log does not need rotating (log has already been rotated)
   ```

6. Forzá una rotación e inspeccioná el resultado:

   ```bash
   logrotate -vf /etc/logrotate.d/lab
   ls -l /var/log/lab-all.log*
   ```

   ```
   -rw-r----- 1 root adm    0 Aug 27 10:01 /var/log/lab-all.log
   -rw-r----- 1 root adm  412 Aug 27 10:01 /var/log/lab-all.log-20260827
   ```

7. Rotá una segunda vez y observá qué hizo `delaycompress`:

   ```bash
   logger -p local4.info -t labtest "post-rotation line"
   logrotate -vf /etc/logrotate.d/lab
   ls -l /var/log/lab-all.log*
   ```

   ```
   -rw-r----- 1 root adm    0 /var/log/lab-all.log
   -rw-r----- 1 root adm   58 /var/log/lab-all.log-20260827
   -rw-r----- 1 root adm  198 /var/log/lab-all.log-20260826.gz
   ```

8. Confirmá que el log se sigue escribiendo después de la rotación (el sentido del HUP en `postrotate`):

   ```bash
   logger -p local4.info -t labtest "still alive"
   sleep 1 && cat /var/log/lab-all.log
   ```

9. Probá contra un archivo de estado aislado para no corromper el del sistema:

   ```bash
   logrotate -v -s /tmp/lab.status /etc/logrotate.d/lab
   ```

> **Verificá tu comprensión — Bloque 7.2**
>
> **Q7.1** Están presentes tanto `daily` como `maxsize 10M`. ¿Bajo qué condición se dispara cada uno, y en qué se diferencia `maxsize` de `size`?
> **Q7.2** Explicá `delaycompress` usando la salida del paso 7. ¿Qué clase de problema resuelve?
> **Q7.3** ¿Qué hace exactamente `create 0640 root adm`, y en qué orden respecto del renombrado?
> **Q7.4** Contrastá `create` + HUP en `postrotate` con `copytruncate`. Dá la falla específica que cada uno evita y la falla específica que cada uno introduce.
> **Q7.5** ¿Por qué hace falta `sharedscripts` acá, y qué pasaría sin él dado el glob `lab-*.log`?
> **Q7.6** `missingok` y `notifempty` — ¿qué suprime cada uno, y por qué `missingok` es casi obligatorio en una política que viene con un paquete?
> **Q7.7** `logrotate -d` reporta "log does not need rotating" para un archivo que claramente pesa 2 GB. Nombrá tres causas distintas.
> **Q7.8** ¿Por qué `logrotate.conf` necesita `su root adm` en Debian, y qué error aparece sin él?

---

## Ejercicio 8 — Diagnóstico bajo presión

### Bloque 8.1 — "El disco está lleno y es `/var/log`"

1. Establecé a dónde se fue el espacio, journal versus logs de texto:

   ```bash
   df -h /var/log
   journalctl --disk-usage
   du -xh --max-depth=1 /var/log | sort -h | tail
   du -xh --max-depth=1 /var/log --exclude=journal | sort -h | tail -5
   ```

2. Encontrá al productor más ruidoso:

   ```bash
   journalctl -b -o cat | awk '{print $1}' | sort | uniq -c | sort -rn | head
   journalctl -b -F _SYSTEMD_UNIT | while read -r u; do
     printf '%8d %s\n' "$(journalctl -b -u "$u" --no-pager -o cat | wc -l)" "$u"
   done | sort -rn | head
   ```

3. Recuperá espacio, después poné un tope para que no pueda repetirse:

   ```bash
   journalctl --vacuum-size=200M
   # then set SystemMaxUse as in Exercise 2, and restart journald
   ```

4. Encontrá archivos de log borrados pero todavía abiertos, la razón clásica por la que `df` y `du` no coinciden:

   ```bash
   lsof +L1 2>/dev/null | grep -i '/var/log'
   ```

   ```
   rsyslogd 1442 root 8w REG 253,2 4831838208 0 262151 /var/log/huge.log (deleted)
   ```

### Bloque 8.2 — "No se está registrando nada"

5. Recorré la cadena hacia abajo, en este orden:

   ```bash
   systemctl status systemd-journald --no-pager
   systemctl status rsyslog --no-pager
   ls -l /dev/log
   logger -p local0.emerg -t chaintest "chain probe"
   journalctl -t chaintest -n 1 --no-pager
   grep chaintest /var/log/syslog /var/log/messages 2>/dev/null
   rsyslogd -N1
   ```

6. Buscá un archivo de journal corrupto:

   ```bash
   journalctl --verify 2>&1 | grep -v '^PASS'
   ```

   ```
   FAIL: /var/log/journal/7d0c…/system@0006a2….journal (Bad message)
   ```

   ```bash
   journalctl --rotate
   mv /var/log/journal/*/system@0006a2*.journal /root/
   systemctl restart systemd-journald
   ```

7. Buscá denegaciones de SELinux o AppArmor que bloqueen una ruta de log personalizada:

   ```bash
   ausearch -m avc -ts recent 2>/dev/null | tail -20
   journalctl -t audit -b -p warning --no-pager | tail
   ls -Z /var/log/lab-all.log 2>/dev/null
   ```

8. Confirmá los logs binarios de contabilidad, que **no** son de journald y **no** son texto plano:

   ```bash
   last -n 5
   lastb -n 5
   lastlog | head -5
   ls -l /var/log/wtmp /var/log/btmp /var/log/lastlog
   ```

> **Verificá tu comprensión — Bloque 8.1 / 8.2**
>
> **Q8.1** `df` reporta `/var` al 100 % pero `du -sh /var/log` contabiliza solo 2 GB en un sistema de archivos de 40 GB. ¿Qué está pasando, y cuál es la remediación correcta — y la incorrecta pero tentadora?
> **Q8.2** Borraste archivos bajo `/var/log/journal/` con `rm` mientras journald estaba corriendo. ¿Por qué `journalctl --rotate` antes de eliminarlos es la secuencia más segura?
> **Q8.3** `logger -p local0.emerg` produce una entrada en el journal pero nada en `/var/log/messages`, y `rsyslogd -N1` sale limpio. Dá las dos causas más probables.
> **Q8.4** `/var/log/wtmp`, `/var/log/btmp` y `/var/log/lastlog` no se pueden leer con `less`. Nombrá la herramienta de lectura de cada uno e indicá cuál registra los inicios de sesión *fallidos*.
> **Q8.5** Un archivo de journal falla el `--verify` con "Bad message". ¿Puede `journalctl` seguir leyendo los otros archivos? ¿Qué te dice eso sobre la granularidad de los archivos del journal?

---

## Resumen de referencia

| Tarea | Comando |
|---|---|
| Últimas 50 líneas de una unidad, en seguimiento | `journalctl -u NAME -n 50 -f` |
| Errores de este arranque, con explicaciones | `journalctl -xb -p err` |
| Mensajes del kernel, arranque anterior | `journalctl -k -b -1` |
| Ventana de tiempo | `journalctl --since "-1h" --until now` |
| Legible por máquina | `journalctl -o json-pretty` |
| Uso de disco / recuperar espacio | `journalctl --disk-usage` / `--vacuum-size=1G` |
| Integridad | `journalctl --verify` |
| Hacerlo persistente | `mkdir -p /var/log/journal && systemd-tmpfiles --create --prefix /var/log/journal` |
| Enviar un mensaje de syslog | `logger -p local3.err -t TAG "text"` |
| Capturar un comando | `systemd-cat -t TAG -p warning CMD` |
| Validar la configuración de rsyslog | `rsyslogd -N1` |
| Reenviar por TCP (legacy) | `*.*  @@host:514` |
| Rotación en seco / forzada | `logrotate -d FILE` / `logrotate -vf FILE` |

**Facilities:** `kern(0) user(1) mail(2) daemon(3) auth(4) syslog(5) lpr(6) news(7) uucp(8) cron(9) authpriv(10) ftp(11)` … `local0(16)`–`local7(23)`
**Prioridades (severidad):** `emerg(0) alert(1) crit(2) err(3) warning(4) notice(5) info(6) debug(7)`

---

## Fuentes

- LPI — Objetivos del Examen 102-500 (tema 108.2): <https://www.lpi.org/our-certifications/exam-102-objectives/>
- LPI — Objetivos del Examen 101-500: <https://www.lpi.org/our-certifications/exam-101-objectives/>
- `journalctl(1)`: <https://www.freedesktop.org/software/systemd/man/latest/journalctl.html>
- `journald.conf(5)`: <https://www.freedesktop.org/software/systemd/man/latest/journald.conf.html>
- `systemd-journald.service(8)`: <https://www.freedesktop.org/software/systemd/man/latest/systemd-journald.service.html>
- `systemd-cat(1)`: <https://www.freedesktop.org/software/systemd/man/latest/systemd-cat.html>
- `systemd.journal-fields(7)`: <https://www.freedesktop.org/software/systemd/man/latest/systemd.journal-fields.html>
- Referencia de configuración de rsyslog: <https://www.rsyslog.com/doc/configuration/index.html>
- Módulo `omfwd` de rsyslog: <https://www.rsyslog.com/doc/configuration/modules/omfwd.html>
- Parámetros de cola de rsyslog: <https://www.rsyslog.com/doc/rainerscript/queue_parameters.html>
- `logger(1)`: <https://man7.org/linux/man-pages/man1/logger.1.html>
- `logrotate(8)`: <https://man7.org/linux/man-pages/man8/logrotate.8.html>
- `syslog(3)` — constantes de facility y priority: <https://man7.org/linux/man-pages/man3/syslog.3.html>
- RFC 5424, *The Syslog Protocol*: <https://datatracker.ietf.org/doc/html/rfc5424>
- RFC 3164, *The BSD syslog Protocol*: <https://datatracker.ietf.org/doc/html/rfc3164>

---

<details>
<summary><strong>Respuestas</strong></summary>

### Ejercicio 1

**Q1.1** Con `Storage=auto` (el predeterminado) y sin `/var/log/journal`, journald escribe en `/run/log/journal`, que es un **tmpfs**. Todo se pierde en el reinicio — incluidos los logs del crash que causó el reinicio. Este es precisamente el caso que arregla el Ejercicio 2.

**Q1.2** El modo `0640 root:systemd-journal` permite leerlo a los miembros de `systemd-journal`. El `+` marca una **ACL** instalada por `systemd-tmpfiles` desde `/usr/lib/tmpfiles.d/systemd.conf`, que otorga `r-x` a `adm` (Debian) o `wheel` (RHEL). Así, un administrador en `adm`/`wheel` lee el journal del sistema sin `sudo`; cualquier otro ve solo su propio journal de usuario.

**Q1.3** Dos razones. Primera, `journalctl --disk-usage` suma **ambos**, `/var/log/journal` y `/run/log/journal`, cuando los dos existen. Segunda, journald pre-asigna los archivos de journal hasta `SystemMaxFileSize` y `du` sobre un archivo disperso (sparse) reporta bloques asignados, no el tamaño nominal — así que los números pueden diferir en cualquier dirección según el sistema de archivos.

**Q1.4** El campo `PRIORITY` lleva el número de **severidad** de syslog, donde `0 = emerg` es lo más severo y `7 = debug` lo menos. "Warning y superiores" significa entonces severidad ≤ 4. `-p` fija un *valor numérico máximo*, que se lee como una *severidad mínima*.

**Q1.5** `-b -1` selecciona por `_BOOT_ID` — todo el arranque anterior, haya durado 3 minutos o 3 meses. `--since yesterday` selecciona por marca de tiempo de reloj de pared y puede abarcar varios arranques o ninguno. Escenario: una máquina encendida hace 90 días, reiniciada hace una hora. `-b -1` devuelve 90 días de logs; `--since yesterday` devuelve ~24 horas cruzando el límite del arranque.

**Q1.6** El journal es volátil — no hay `/var/log/journal`, o bien `Storage=volatile`/`none`. Los registros de arranques anteriores no sobrevivieron, así que solo existe el boot ID actual en el índice.

**Q1.7** `_COMM=sshd`. `-u sshd` es una abreviatura de `_SYSTEMD_UNIT=sshd.service` más coincidencias relacionadas, así que solo devuelve mensajes atribuidos al cgroup de esa unidad. Un binario `sshd` invocado desde un script de instalación corre en un cgroup distinto y llevaría un `_SYSTEMD_UNIT` distinto, así que `-u` no lo encontraría mientras `_COMM` sí lo captura.

**Q1.8** Los campos que empiezan con `_` son **campos de confianza (trusted fields)**: journald los deriva él mismo de las credenciales del proceso emisor sobre el socket (`_PID`, `_UID`, `_COMM`, `_EXE`, `_CMDLINE`, `_SYSTEMD_UNIT`, `_SELINUX_CONTEXT`) y un cliente no puede falsificarlos. Los campos sin guion bajo (`MESSAGE`, `PRIORITY`, `SYSLOG_IDENTIFIER`) vienen del cliente y están enteramente bajo su control. Durante una investigación, un `SYSLOG_IDENTIFIER=sshd` sospechoso no prueba nada; `_EXE=/usr/sbin/sshd` y `_UID=0` sí son evidencia.

**Q1.9** `SYSLOG_FACILITY=4` es `auth`; `PRIORITY=6` es `info`. Un selector clásico que coincide es `auth.info` (que también coincide con todo lo más severo), o `auth.=info` en rsyslog para esa severidad sola.

**Q1.10** `-x` enriquece las entradas con texto explicativo del **catálogo de mensajes** (`/usr/lib/systemd/catalog/*.catalog`, indexado en `catalog` por `journalctl --update-catalog`). Las entradas que llevan un `MESSAGE_ID=` se cotejan contra el catálogo y obtienen un párrafo que explica la causa y el remedio típico.

**Q1.11** `-o cat`. Perdés la marca de tiempo, el hostname, el identificador, el PID y la prioridad — todo excepto `MESSAGE`. Usalo solo cuando la tubería circundante aporte ese contexto por sí misma.

### Ejercicio 2

**Q2.1**
- `volatile` — solo memoria, en `/run/log/journal`; nunca toca el disco.
- `persistent` — `/var/log/journal`, **creado por journald si falta**; recurre a `/run` solo mientras `/var` todavía no está montado.
- `auto` (predeterminado) — se comporta como `persistent` si `/var/log/journal` ya existe, si no, como `volatile`. **No** crea el directorio.
- `none` — no se almacena nada en absoluto; journald igual reenvía (syslog, kmsg, consola, wall) e igual sirve `journalctl -f` para el flujo en vivo, pero no se retiene nada.

`Storage=auto` es el que hace que la existencia del directorio sea el factor decisivo; `Storage=persistent` hace que el directorio sea obligatorio pero lo crea por vos.

**Q2.2** (a) El parámetro nunca tuvo efecto — journald no fue reiniciado, o un drop-in posterior lo sobrescribe. (b) El directorio existe pero tiene propiedad/permisos/ACL erróneos, así que journald no puede escribir ahí y quedó silenciosamente en volátil. Distinguilas con `systemd-analyze cat-config systemd/journald.conf` (muestra la configuración *efectiva* fusionada) y después `journalctl -u systemd-journald -b | grep -i 'permanent\|runtime\|journal'`, que registra qué directorio abrió.

**Q2.3**
- `--flush` — le pide a journald que mueva todo lo que está actualmente en `/run/log/journal` hacia `/var/log/journal` y deje de escribir en `/run`. Solo tiene sentido una vez que el almacenamiento persistente está activo.
- `--sync` — bloquea hasta que todos los mensajes en cola estén confirmados en sus archivos de respaldo (`fsync`). Usalo antes de un apagado abrupto o antes de archivar el journal.
- `--rotate` — cierra los archivos de journal activos, los marca como archivados e inicia nuevos. Usalo antes de copiar o borrar archivos de journal.

**Q2.4** `Storage=none` deshabilita el *almacenamiento*, no la *recepción*. journald sigue aceptando mensajes, aplica `ForwardTo*` y los sirve en el bus en vivo, así que `journalctl -f` muestra el flujo a medida que llega. Nada queda consultable después.

**Q2.5** Gana `SystemKeepFree` porque es el más estricto de los dos en ese momento: journald conserva el límite que deje menos datos. Con 800 MB libres y un piso de espacio libre de 1 GB, journald ya está por encima del presupuesto y va a hacer vacuum agresivamente — reteniendo efectivamente nada más allá del archivo activo hasta que haya 1 GB libre de nuevo. La regla es: el límite aplicado es `min(SystemMaxUse, disponible_actual − SystemKeepFree)`.

**Q2.6** Los archivos de journal son de solo anexado (append-only) y con hash de integridad; truncarlos rompería la cadena de hashes y el índice. journald en cambio rota (sella el archivo activo, abre uno nuevo) y después **borra archivos archivados enteros**. Consecuencia: `SystemMaxFileSize` debe ser significativamente menor que `SystemMaxUse` — los valores predeterminados usan 1/8 — si no, la unidad mínima de recuperación es una fracción grande de todo el presupuesto y la retención se vuelve gruesa e impredecible.

**Q2.7** `RateLimitBurst` (subirlo) y `RateLimitIntervalSec` (acortar la ventana). Poner `RateLimitIntervalSec=0` deshabilita el límite por completo, lo que elimina la única defensa contra un servicio en bucle que llene el disco o consuma la CPU de journald — un solo proceso mal comportado puede entonces expulsar los logs de todos los demás servicios. Preferí subir el burst, o definir `LogRateLimitBurst=`/`LogRateLimitIntervalSec=` por unidad solo en la unidad ruidosa.

**Q2.8** El vacuum solo elimina archivos de journal **archivados**, nunca el activo, y trabaja con granularidad de archivo completo. Si los 30 días viven dentro de un único `system.journal` todavía activo (porque `SystemMaxFileSize`/`MaxFileSec` nunca forzaron una rotación), no hay nada que borrar. Ejecutá `journalctl --rotate` primero, después el vacuum.

### Ejercicio 3

**Q3.1** La facility 19 es `local3`. Las facilities `localN` son la 16–23, es decir, `local0`=16 … `local7`=23.

**Q3.2** Las facilities estándar tienen significados definidos y las reglas de rsyslog que trae la distribución ya las enrutan: escribir en `daemon` mezcla tu aplicación dentro de `/var/log/syslog`/`messages` junto con los demonios del sistema, y escribir en `auth`/`authpriv` contamina el log de seguridad que leen los auditores. `local0`–`local7` están reservadas explícitamente para uso local del sitio, así que podés darle a tu aplicación su propio selector, su propio archivo, su propia política de rotación y su propia retención sin tocar ninguna regla existente.

**Q3.3** Sin `-t`, `logger` usa el nombre de login de `getlogin()`/`LOGNAME` como tag. En un trabajo de cron o en una unidad systemd puede no haber terminal controladora y `LOGNAME` puede estar sin definir o ser genérico, así que el tag se vuelve inútil para filtrar — y peor, se vuelve *inconsistente*, con lo cual una regla como `:programname, isequal, "backup"` deja de coincidir silenciosamente. Pasá siempre `-t` explícitamente en contextos no interactivos.

**Q3.4** `-s` escribe el mensaje a **stderr** además de al socket de syslog. Dentro de un envoltorio de `ExecStart` de una unidad esto es útil porque stderr lo captura systemd y aterriza en el journal atribuido a la *unidad* (`_TRANSPORT=stdout`, `_SYSTEMD_UNIT` correcto), mientras que la copia por syslog lleva la facility que elegiste para el enrutamiento de rsyslog — obtenés tanto la atribución a la unidad como el enrutamiento.

**Q3.5**
- `kernel` — leído desde `/dev/kmsg`, el buffer circular del kernel (`journalctl -k`).
- `stdout` — el stdout/stderr de un servicio capturado a través de `/run/systemd/journal/stdout`.
- `syslog` — llegó por el socket datagram clásico `/dev/log` (el que usa `logger`).
- `journal` — llegó por el protocolo **nativo** de journald en `/run/systemd/journal/socket` (`sd_journal_send`, `systemd-cat`), que es el único transporte que lleva campos estructurados arbitrarios.
- `driver` — generado por el propio journald (avisos de rotación, "Suppressed N messages").
- `audit` — leído desde el socket netlink de auditoría del kernel.

**Q3.6** Un mensaje de transporte nativo no tiene campo `SYSLOG_FACILITY`, así que no puede coincidir con un selector de rsyslog basado en facility — `local0.*` nunca lo verá. Para enrutar la salida de `systemd-cat` con rsyslog tenés que, o bien establecer la facility explícitamente (`systemd-cat` solo establece la prioridad vía `-p`, así que usá `logger` en su lugar), o filtrar por una propiedad que rsyslog *sí* pueda ver, como `:programname, isequal, "yourtag"` — e incluso entonces solo si journald está reenviando a syslog y el tag sobrevive a la conversión.

**Q3.7** `_TRANSPORT=stdout`. Filtrá con `journalctl -u myapp.service _TRANSPORT=stdout`. Notá que `journalctl` hace AND entre coincidencias de campos distintos y OR entre coincidencias del mismo campo, así que esta combinación es un AND, como se pretende.

**Q3.8** `systemd-cat` es lo correcto cuando querés capturar el stdout **y** stderr completos de un comando, verbatim, con metadatos de proceso correctos y sin escapado por línea — por ejemplo `systemd-cat -t backup /usr/local/bin/backup.sh` dentro de una unidad. `logger` es lo correcto cuando el mensaje debe llegar a una **facility clásica de syslog** para que las reglas de rsyslog puedan enrutarlo — por ejemplo, enviar eventos de aplicación a un recolector central por `local4`.

### Ejercicio 4

**Q4.1**
- `*.*` — toda facility, toda prioridad.
- `;` — separa selectores que se combinan para la misma acción.
- `auth,authpriv.none` — las facilities `auth` y `authpriv` con prioridad `none`, es decir, **excluirlas** por completo.
- En conjunto: "todo excepto `auth` y `authpriv`".
- `-/var/log/syslog` — el `-` inicial significa **no hacer `fsync()` después de cada escritura**. Cambia durabilidad ante un crash por una gran reducción de E/S.

**Q4.2** `authpriv` lleva detalle de autenticación — nombres de usuario, direcciones de origen, invocaciones de sudo, fallos de PAM. Separarlo en `/var/log/auth.log` / `/var/log/secure` con `0640 root:adm` lo mantiene fuera del catch-all casi legible por todos, le da una política de retención independiente y les da a los auditores un único archivo para leer. Mezclarlo dentro de `syslog` lo filtraría más ampliamente y además lo enterraría en el ruido.

**Q4.3** Con `imjournal`, rsyslog lee directamente de la base de datos del journal y puede acceder a los campos del journal (incluidos los de confianza con prefijo `_`) como propiedades de rsyslog, a costa de más CPU y de un archivo de estado (`imjournal.state`) que puede desincronizarse. Con solo `imuxsock`, rsyslog lee un flujo de datagramas syslog plano desde `/run/systemd/journal/syslog` — ese flujo es una representación con pérdida al estilo RFC-3164, así que los **metadatos de confianza se pierden**; obtenés tag, PID, facility y prioridad y nada más.

**Q4.4** `*.*` coincide con las ocho severidades; `*.info` coincide con las severidades 0–6 y descarta `debug`. Difieren exactamente cuando algo registra a nivel `debug` — que, una vez que activás el logging de debug de un servicio para diagnosticarlo, es justo el momento en que más lo necesitás. Esta es una sorpresa habitual: los mensajes están en el journal pero ausentes de `/var/log/messages`.

**Q4.5** `!` niega la coincidencia de prioridad: `local4.!debug` significa "todas las prioridades de `local4` **excepto** la severidad 7", así que capturó de `info` hasta `crit` — 5 de las 6 líneas generadas. `local4.!=err` significaría "todas las prioridades de `local4` excepto *exactamente* `err`" — notá que `!` y `=` se componen: `!` solo niega un umbral y `!=` niega un único nivel.

**Q4.6** La prioridad se aplica a **ambas**. La sintaxis es `facility[,facility...].priority` — una lista de facilities separadas por comas comparte una única especificación de prioridad al final. Para darle a cada facility un umbral distinto necesitás dos selectores separados unidos por `;`, por ejemplo `local5.warning;local6.err`.

**Q4.7** `&` repite el selector anterior, y `stop` (el `~` heredado) descarta el mensaje de modo que ninguna regla posterior pueda actuar sobre él. Sin eso, los mensajes de `chatty` coincidirían con `lab-chatty.log` *y después seguirían* hasta la regla catch-all `*.*` y se escribirían una segunda vez en `/var/log/syslog` / `/var/log/messages`.

**Q4.8** Cada regla posterior a una coincidencia igual tiene su selector evaluado y —más costoso aún— cada acción que coincide realiza E/S. En un host que recibe decenas de miles de mensajes por segundo, un `stop` temprano sobre tráfico de alto volumen y bien clasificado elimina tanto las evaluaciones de reglas restantes como las escrituras duplicadas. La ubicación importa: poné primero la regla con `stop` de mayor volumen.

**Q4.9**
- Reenviar a un host remoto: `*.*  @@10.0.0.10:514` (TCP) o `action(type="omfwd" target="…" protocol="tcp")`.
- Escribir en las terminales de todos los usuarios conectados: `*.emerg  :omusrmsg:*` (o una lista de usuarios, `*.emerg  root,operator`).
- Canalizar a una tubería con nombre / a un programa: `*.*  |/var/run/mypipe`, o `action(type="omprog" binary="/usr/local/bin/handler")`.
- (También válido: una base de datos vía `ommysql`, o `:omfile:` con una plantilla de nombre de archivo dinámico como en el paso 7.)

### Ejercicio 5

**Q5.1** Prueba que **journald lo recibe primero**, incondicionalmente. En un host con systemd, el socket `/dev/log` es propiedad de `systemd-journald-dev-log.socket`, así que incluso un programa que use la API `syslog(3)` simple le habla a journald. rsyslog está aguas abajo — recibe una copia solo si journald la reenvía (`ForwardToSyslog=yes` + `/run/systemd/journal/syslog`) o si la lee de vuelta (`imjournal`).

**Q5.2** `MaxLevelStore` es el umbral de severidad de lo que journald **guarda en su propia base de datos**; `MaxLevelSyslog` es el umbral de lo que **reenvía al demonio de syslog**. Con `MaxLevelStore=debug` y `MaxLevelSyslog=info`, la línea `debug` fue almacenada pero no reenviada, que es exactamente lo que mostró el paso 3: `journalctl` tiene ambas líneas, `/var/log/syslog` tiene solo la de `notice`. El mismo patrón aplica a `MaxLevelKMsg`, `MaxLevelConsole` y `MaxLevelWall`.

**Q5.3** No. `imjournal` lee la base de datos del journal directamente a través de la API del journal, sorteando por completo el socket de reenvío. `ForwardToSyslog=yes` hace falta solo para la ruta basada en `imuxsock`. Habilitar ambos en un host al estilo RHEL produce líneas de log **duplicadas**.

**Q5.4**
- `ForwardToSyslog` — un demonio de syslog debe ver los mensajes, típicamente porque rsyslog los envía a un recolector central o a un SIEM.
- `ForwardToKMsg` — escribir en el buffer circular del kernel, para que el instrumental de arranque temprano o de volcado de crash que solo lee `dmesg` capture contexto de espacio de usuario. Rara vez apropiado; el buffer circular es chico.
- `ForwardToConsole` — replicar hacia `TTYPath=` (por defecto `/dev/console`). Se usa en dispositivos sin cabeza (headless) y hardware gestionado por consola serie, donde la consola es el único canal de diagnóstico.
- `ForwardToWall` — difundir a las terminales de los usuarios conectados (por defecto `yes`, acotado por `MaxLevelWall=emerg`). Por esto los mensajes `emerg` aparecen en la terminal de todo el mundo.

**Q5.5** Ahora cada mensaje se procesa dos veces: journald lo escribe e indexa, después lo serializa al socket de reenvío, y rsyslog lo parsea otra vez, reevalúa todo su conjunto de reglas y lo escribe una segunda vez — a menudo en un segundo archivo que hace `fsync`. En un host de alto volumen esto duplica aproximadamente la CPU y la E/S de disco dedicadas al logging. Mitigaciones: subir el umbral de reenvío (`MaxLevelSyslog=notice`), acotar las reglas de rsyslog y hacer `stop` temprano, usar prefijos `-` en las acciones de archivo para saltear el `fsync`, o descartar rsyslog por completo y reenviar con `systemd-journal-upload`.

### Ejercicio 6

**Q6.1** `*.* @@10.0.0.10:514` = "enviar cada mensaje de cada facility y prioridad a 10.0.0.10 puerto 514 por **TCP**". `*.* @10.0.0.10:514` = lo mismo por **UDP**. El carácter que los distingue es el `@` duplicado. TCP da entrega orientada a conexión con retransmisión y contrapresión (back-pressure), así que un mensaje o bien es reconocido por el transporte o el emisor sabe que falló; UDP es disparar y olvidar — una pérdida silenciosa bajo carga, fragmentación por MTU o un recolector reiniciándose pierde mensajes sin indicación en ninguno de los dos extremos. Notá que incluso TCP solo garantiza la entrega al socket del recolector, no que rsyslog lo haya escrito a disco; eso requiere RELP.

**Q6.2** Sin `stop`, los mensajes remotos siguen bajando por la cadena de reglas y también coinciden con las reglas locales propias del recolector (`*.info … /var/log/messages`, `authpriv.* /var/log/secure`). El tráfico `authpriv` de cada cliente se fusionaría con el log de seguridad propio del recolector, haciendo imposible distinguir un sudo local de uno remoto — un riesgo forense en toda regla, además de duplicar el uso de disco.

**Q6.3** Sin `queue.filename` la acción usa una cola solo **en memoria** (`queue.type="LinkedList"` igual significa RAM). Si rsyslog se reinicia, o la máquina se reinicia, todo lo encolado se pierde; y una vez que la cola alcanza `queue.maxSize` empieza a descartar. `queue.filename` + `queue.spoolDirectory` la promueven a una cola **asistida por disco** que se derrama a disco bajo presión, y `queue.saveOnShutdown="on"` persiste el remanente entre reinicios.

**Q6.4** `-1` significa **reintentar por siempre**. El predeterminado es `0`: ante el primer fallo la acción se marca como suspendida, y rsyslog reintentará según su propio calendario de suspensión, pero la acción puede quedar deshabilitada de forma permanente tras fallos repetidos — el efecto es que una caída del recolector que dure más que el presupuesto de reintentos detiene el reenvío en silencio, y nadie se entera hasta una auditoría. `-1` combinado con una cola asistida por disco es la configuración que realmente sobrevive una ventana de mantenimiento del recolector.

**Q6.5** Nativos de systemd: **`systemd-journal-upload`** (cliente, empuja hacia un endpoint HTTPS) y **`systemd-journal-remote`** (servidor, recibe; a menudo emparejado con `systemd-journal-gatewayd`, que sirve el journal por HTTPS para recolección tipo pull). Nativo de rsyslog: **RELP** (`omrelp`/`imrelp`) para entrega confiable, opcionalmente con TLS, o `omfwd` simple con `StreamDriver="gtls"` y `StreamDriverAuthMode="x509/name"` para syslog cifrado con TLS y autenticado por certificado.

### Ejercicio 7

**Q7.1** `daily` se dispara cuando el archivo de estado muestra que la última rotación fue en un día anterior. `maxsize 10M` se dispara cuando el archivo supera los 10 MB **y** el intervalo de tiempo todavía no transcurrió — es decir, rota *antes* de lo programado. El contraste:
- `size 10M` — rotar **solo** por tamaño, ignorando cualquier directiva de tiempo.
- `maxsize 10M` — rotar por el intervalo de tiempo **o** por tamaño, lo que ocurra primero.
- `minsize 10M` — rotar por el intervalo de tiempo, pero solo si el archivo alcanzó los 10 MB.

**Q7.2** Con `delaycompress`, el archivo rotado más recientemente se deja sin comprimir por un ciclo y solo se comprime con gzip en la *siguiente* rotación — por eso el paso 7 mostró `lab-all.log-20260827` en plano y `lab-all.log-20260826.gz` comprimido. Resuelve el caso en que el proceso escritor todavía mantiene un descriptor de archivo abierto sobre el archivo recién rotado (porque aún no fue señalizado, o reabre de forma perezosa): comprimirlo de inmediato produciría un archivo truncado y perdería las líneas escritas en el intervalo.

**Q7.3** Después de renombrar el log viejo para sacarlo del medio, logrotate crea de inmediato un archivo nuevo y vacío en la ruta original con modo `0640`, propietario `root`, grupo `adm`. El orden importa: primero renombrar, segundo crear, y el número de inodo cambia — que es exactamente por lo que a un demonio que retiene el descriptor viejo hay que decirle que reabra.

**Q7.4**
- **`create` + HUP en `postrotate`** — el archivo se renombra y se crea un inodo nuevo; se señaliza al demonio y este reabre la ruta. No se pierden datos, pero si la señal falla o el demonio la ignora, el demonio sigue escribiendo para siempre en el archivo *rotado* (ahora invisible) y el log nuevo queda en cero bytes.
- **`copytruncate`** — el archivo se copia y después se trunca en el lugar, así que el inodo nunca cambia y no hace falta ninguna señal. Funciona con demonios que no pueden ser señalizados o que retienen el descriptor con `O_APPEND` y sin lógica de reapertura. Pero hay una carrera inevitable entre la copia y el truncado: todo lo escrito en esa ventana se pierde. Además duplica la E/S y duplica brevemente el uso de disco.

Regla práctica: `create` + señal para todo lo que controlás (rsyslog, nginx, la mayoría de los demonios); `copytruncate` solo como último recurso para software de terceros que no puede reabrir.

**Q7.5** El glob `/var/log/lab-*.log` coincide con varios archivos. Sin `sharedscripts`, `prerotate`/`postrotate` se ejecutan **una vez por cada archivo coincidente** — así que a rsyslog se le enviaría HUP cinco o seis veces seguidas por un solo ciclo de rotación. `sharedscripts` colapsa eso en una única ejecución después de que todos los archivos coincidentes fueron rotados. (`nosharedscripts` es el predeterminado.)

**Q7.6** `missingok` suprime el error cuando el archivo de log no existe; `notifempty` suprime la rotación cuando el archivo existe pero tiene cero bytes. `missingok` es prácticamente obligatorio en una política que viene con un paquete porque la configuración del paquete se instala antes de que el servicio se haya ejecutado alguna vez — sin él, logrotate emite un error todos los días, que se le envía por correo a root, hasta que alguien arranque el servicio.

**Q7.7** (a) El archivo de estado ya registra una rotación para el período actual — revisá `/var/lib/logrotate/status`. (b) El archivo coincide con una estrofa de política *distinta* y anterior; logrotate aplica la primera coincidencia y avisa sobre duplicados (`error: ... duplicate log entry`). (c) La condición de tamaño tiene semántica `minsize`/`size` que malinterpretaste, o la directiva de tiempo no transcurrió y no hay `maxsize` definido — 2 GB con `weekly` y sin `maxsize` genuinamente no necesita rotarse hasta que se cumpla la semana.

**Q7.8** El `/var/log` de Debian contiene archivos cuyo grupo no es root (notablemente `adm`, y directorios escribibles por otros usuarios), y logrotate se niega a rotar archivos en un directorio que no le pertenece sin que se le indique a qué usuario/grupo hacer `setuid`/`setgid` — esto es una defensa deliberada contra enlaces simbólicos y escalada de privilegios. `su root adm` la concede. Sin ella: `error: skipping "/var/log/syslog" because parent directory has insecure permissions (It's world writable or writable by group which is not "root") Set "su" directive in config file to tell logrotate which user/group should be used for rotation.`

### Ejercicio 8

**Q8.1** Un proceso mantiene abierto un descriptor de archivo sobre un archivo de log que ya fue desenlazado (unlinked). El espacio no se libera hasta que se cierre el descriptor, así que `du` (que recorre entradas de directorio) no puede verlo mientras que `df` (que lee el superbloque) sí. `lsof +L1` lo encuentra — un archivo con contador de enlaces 0.

La remediación correcta es hacer que quien lo retiene lo suelte: `systemctl restart rsyslog`, o señalizarlo para que reabra (`systemctl kill -s HUP rsyslog`). La movida tentadora pero equivocada es reiniciar la máquina, o seguir buscando archivos grandes con `du` — y la activamente dañina es hacer `rm` de más archivos, que no logra nada porque el espacio nunca estuvo en una entrada de directorio en primer lugar. (Un paliativo seguro cuando no podés reiniciar el proceso: `: > /proc/PID/fd/N` trunca el archivo borrado a través de su descriptor y libera el espacio de inmediato.)

**Q8.2** journald mantiene los archivos de journal mapeados con mmap y sostiene un índice interno. Hacer `rm` del archivo en el que está escribiendo activamente deja a journald anexando a un inodo desenlazado — el espacio no se libera (ver Q8.1) y los registros quedan inalcanzables. `journalctl --rotate` primero hace que journald cierre el archivo activo, lo selle y abra uno nuevo; recién entonces los archivos viejos quedan inertes y es seguro eliminarlos. Mejor todavía, usá `journalctl --vacuum-*`, que hace toda la secuencia correctamente.

**Q8.3** (a) journald no está reenviando — `ForwardToSyslog` está en `no`, así que el `imuxsock` de rsyslog nunca recibe el mensaje. (b) rsyslog está corriendo pero leyendo desde la fuente equivocada, o el archivo de estado de `imjournal` está desactualizado/corrupto (`/var/lib/rsyslog/imjournal.state`) y está esperando en una posición de cursor que ya no existe. `rsyslogd -N1` valida *sintaxis* únicamente; no dice nada sobre si las entradas están entregando de verdad. Confirmá con `journalctl -u rsyslog -b` y `ss -xlp | grep journal`.

**Q8.4**
- `/var/log/wtmp` — inicios/cierres de sesión exitosos y reinicios. Se lee con **`last`**.
- `/var/log/btmp` — intentos de login **fallidos**. Se lee con **`lastb`** (solo root).
- `/var/log/lastlog` — el login más reciente por usuario, un archivo disperso indexado. Se lee con **`lastlog`**.

Los tres son registros binarios en formato `utmp` escritos directamente por PAM/login, no por journald ni rsyslog — que es por lo que sobreviven una caída de journald y por lo que necesitan su propia estrofa de logrotate.

**Q8.5** Sí. Cada archivo de journal está sellado y encadenado por hash de forma independiente, y `journalctl` abre el conjunto de archivos, salteando cualquiera que no pueda parsear (imprime el fallo y continúa). Un archivo corrupto te cuesta solo los registros de ese archivo. Este es el argumento práctico a favor de un `SystemMaxFileSize` moderado: acota el radio de impacto de un único evento de corrupción tanto como la granularidad del vacuum.

</details>