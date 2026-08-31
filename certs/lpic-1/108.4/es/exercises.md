# LPIC-1 · Examen 102-500 · Tema 108.4 — Gestionar impresoras e impresión
## Laboratorio guiado: CUPS desde el scheduler hasta el archivo de spool

**Cobertura del objetivo.** Configuración básica de CUPS para impresoras locales y remotas · gestión de las colas de impresión de usuario · agregar y quitar trabajos de las colas · resolución de problemas generales de impresión · `/etc/cups/` · la interfaz LPD heredada (`lpr`, `lprm`, `lpq`).

**Qué necesitás.** Un host Linux (Debian 12 / Ubuntu 22.04+ / Fedora / openSUSE), `sudo` y **ninguna impresora física** — cada cola de este laboratorio escribe a un archivo mediante el backend `file` de CUPS, que ejercita *exactamente* la misma maquinaria de scheduler, cadena de filtros, trabajos y spool que usa una impresora real.

**Cómo recorrerlo.** Ejecutá cada paso numerado en orden. Después de cada bloque, respondé las preguntas de control *antes* de abrir la sección plegada de respuestas al final. Los comandos que deben ejecutarse como root se muestran con `sudo`.

> ⚠️ **Nota de seguridad para producción.** Dos ajustes de este laboratorio (`FileDevice Yes` y `--debug-logging`) deliberadamente *no* son valores por defecto de producción. `FileDevice` permite que cualquier remitente autorizado haga que un backend propiedad de root escriba en una ruta arbitraria; el registro de depuración puede llenar `/var/log` en minutos en un servidor con carga. El bloque 12 revierte ambos.

---

## Bloque 0 — Preparar el entorno del laboratorio

1. Instalá el scheduler, las herramientas de cliente y la pila de filtros:

   ```bash
   # Debian / Ubuntu
   sudo apt-get install -y cups cups-client cups-filters cups-bsd file
   # Fedora / RHEL derivatives
   sudo dnf install -y cups cups-client cups-filters file
   ```

   `cups` provee `cupsd` y las herramientas de administración, `cups-client` las herramientas de usuario SysV (`lp`, `lpstat`, `cancel`, `lpadmin`), y `cups-bsd` las compatibles con Berkeley/LPD (`lpr`, `lpq`, `lprm`).

2. Confirmá qué paquete es dueño de cada familia de comandos — esta distinción es examinable:

   ```bash
   command -v lp lpr lpq lprm lpstat cancel lpadmin lpinfo lpoptions lpmove
   ```

   Esperado: herramientas de usuario en `/usr/bin`, herramientas administrativas (`lpadmin`, `lpinfo`, `cupsaccept`, `cupsenable`) en `/usr/sbin`.

3. Creá el directorio en el que las colas del laboratorio van a "imprimir" y un documento de prueba:

   ```bash
   sudo install -d -m 0755 -o root -g lp /var/spool/lab-out
   printf 'LPIC-1 108.4 lab page\nHost: %s\nDate: %s\n' "$(hostname)" "$(date)" > ~/report.txt
   file ~/report.txt
   ```

4. Verificá la versión de CUPS contra la que estás probando; la semántica de las opciones y las deprecaciones difieren entre 1.x, 2.x y 3.x:

   ```bash
   sudo cupsd --version 2>/dev/null || (dpkg -l cups 2>/dev/null || rpm -q cups)
   ```

**Preguntas de control**

- **Q0.1** — ¿Cuáles de `lp`, `lpr`, `lpq`, `lprm`, `lpstat`, `cancel` pertenecen a la familia System V y cuáles a la familia Berkeley (LPD), y por qué están presentes ambas en un sistema CUPS?
- **Q0.2** — ¿Por qué `lpadmin` y `cupsenable` están en `/usr/sbin` mientras `lp` está en `/usr/bin`?
- **Q0.3** — Instalás `cups` pero no `cups-bsd` en Debian. Falta `lpr`. ¿Eso significa que el sistema no puede imprimir mediante el protocolo LPD?

---

## Bloque 1 — El scheduler: units, activación por socket, prueba de configuración

1. Mirá *todas* las units, no solo el service:

   ```bash
   systemctl list-unit-files 'cups*'
   systemctl status cups.service --no-pager
   systemctl status cups.socket --no-pager
   ```

   La salida típica incluye `cups.service`, `cups.socket`, `cups.path` y a menudo `cups-browsed.service`.

2. Detené solo el service y acto seguido emitir una petición de cliente:

   ```bash
   sudo systemctl stop cups.service
   systemctl is-active cups.service      # inactive
   lpstat -r                             # forces a connection to /run/cups/cups.sock
   systemctl is-active cups.service      # active again
   ```

   El cliente se conectó al socket; systemd activó `cupsd` bajo demanda.

3. Confirmá qué endpoints de escucha existen:

   ```bash
   lpstat -H                             # the server the client will talk to
   sudo ss -lnptu | grep -E 'cupsd|631'
   ```

   Esperado: un socket de dominio UNIX `/run/cups/cups.sock` y, por defecto, `127.0.0.1:631`.

4. Validá la configuración *antes* de reiniciar — el hábito más valioso de este tema:

   ```bash
   sudo cupsd -t
   ```

   Esperado en caso de éxito: una línea "is OK" que nombra `/etc/cups/cupsd.conf` (el texto exacto varía según la versión). Si falla, imprime el archivo y el número de línea infractores y sale con código distinto de cero.

5. Introducí un error deliberado y volvé a probar:

   ```bash
   sudo cp /etc/cups/cupsd.conf /etc/cups/cupsd.conf.bak
   echo 'LogLevel bananas' | sudo tee -a /etc/cups/cupsd.conf >/dev/null
   sudo cupsd -t ; echo "exit=$?"
   sudo cp /etc/cups/cupsd.conf.bak /etc/cups/cupsd.conf
   sudo cupsd -t ; echo "exit=$?"
   ```

6. Reload vs restart:

   ```bash
   sudo systemctl reload cups     # cupsd re-reads cupsd.conf, keeps the job queue running
   sudo systemctl restart cups    # full restart; needed after editing cups-files.conf
   ```

**Preguntas de control**

- **Q1.1** — Ejecutaste `systemctl stop cups.service` y el demonio volvió unos segundos después. Explicá el mecanismo y dá la secuencia exacta de comandos que realmente mantiene CUPS caído hasta que vos digas lo contrario.
- **Q1.2** — ¿Cuál es el valor operativo de `cupsd -t` en un servidor de impresión remoto que administrás por SSH?
- **Q1.3** — ¿En qué circunstancias `systemctl reload cups` es insuficiente?
- **Q1.4** — `lpstat -r` imprime `scheduler is running`. ¿Qué transporte usó con más probabilidad el cliente, y cómo lo probarías?

---

## Bloque 2 — El árbol de configuración bajo `/etc/cups`

1. Inventariá el directorio y anotá propietario y modos:

   ```bash
   sudo ls -la /etc/cups
   ```

   Entradas clave: `cupsd.conf`, `cups-files.conf`, `printers.conf`, `classes.conf`, `subscriptions.conf`, `lpoptions`, `ppd/`, `ssl/`, `cupsd.conf.default`.

2. Leé solo las directivas activas, quitando comentarios y líneas en blanco:

   ```bash
   sudo grep -vE '^\s*(#|$)' /etc/cups/cupsd.conf
   ```

   Identificá: `LogLevel`, `MaxLogSize`, `Listen`, `Browsing`, `BrowseLocalProtocols`, `DefaultAuthType`, `WebInterface`, y los bloques `<Location …>` / `<Policy …>`.

3. Ahora el *otro* archivo — desde CUPS 1.6 las directivas de rutas y privilegios viven aparte:

   ```bash
   sudo grep -vE '^\s*(#|$)' /etc/cups/cups-files.conf
   ```

   Identificá: `ErrorLog`, `AccessLog`, `PageLog`, `RequestRoot`, `ServerRoot`, `TempDir`, `Printcap`, `SystemGroup`, `User`, `Group`, `FileDevice`.

4. Inspeccioná los archivos de estado mantenidos por la máquina:

   ```bash
   sudo cat /etc/cups/printers.conf
   sudo cat /etc/cups/classes.conf 2>/dev/null
   ```

   Los escribe `cupsd` mismo. Fijate en el comentario de cabecera que te advierte no editarlos a mano.

5. Consultá y cambiá ajustes en tiempo de ejecución sin tocar un editor de texto:

   ```bash
   sudo cupsctl                       # dumps current settings, e.g. _debug_logging=0
   sudo cupsctl --no-remote-admin --no-remote-any
   sudo cupsctl                       # confirm the change
   ```

6. Ubicá los valores por defecto del paquete para poder recuperarte siempre:

   ```bash
   ls -l /etc/cups/cupsd.conf.default
   ```

**Preguntas de control**

- **Q2.1** — ¿Qué archivo contiene `ErrorLog` y cuál contiene `LogLevel`? ¿Por qué se separaron, y qué propiedad de seguridad impone esa separación?
- **Q2.2** — ¿Por qué nunca debés editar `/etc/cups/printers.conf` mientras `cupsd` está corriendo, y cuál es el procedimiento correcto si realmente tenés que editarlo?
- **Q2.3** — Dá los equivalentes en `cupsctl` de "compartir mis impresoras locales en la red" y "permitir la administración desde hosts remotos", e indicá qué construcciones subyacentes de `cupsd.conf` reescribe cada uno.
- **Q2.4** — Un colega borró `/etc/cups/cupsd.conf`. ¿Cuál es la recuperación más rápida en un paquete de distribución estándar?

---

## Bloque 3 — Dispositivos, drivers y creación de colas con `lpadmin`

1. Listá los backends y los dispositivos descubiertos:

   ```bash
   sudo lpinfo -v
   ```

   Ejemplo:

   ```
   network beh
   direct usb://HP/LaserJet%20P2055dn?serial=VNB3S12345
   network lpd
   network socket
   network ipp
   network ipps
   network https
   ```

   La primera columna es la *clase* de dispositivo; la segunda es un URI de dispositivo. Los backends viven en `/usr/lib/cups/backend/`:

   ```bash
   ls -l /usr/lib/cups/backend/
   ```

2. Listá los drivers/modelos disponibles (esto consulta a `cups-driverd`):

   ```bash
   sudo lpinfo -m | wc -l
   sudo lpinfo -m | grep -iE 'generic|everywhere|raw' | head
   ```

3. Habilitá el pseudo-dispositivo de archivo para el laboratorio y reiniciá (se lee al arrancar):

   ```bash
   sudo sed -i 's/^#\?FileDevice .*/FileDevice Yes/' /etc/cups/cups-files.conf
   grep -n '^FileDevice' /etc/cups/cups-files.conf || echo 'FileDevice Yes' | sudo tee -a /etc/cups/cups-files.conf
   sudo cupsd -t && sudo systemctl restart cups
   ```

4. Creá la primera cola. Elegí una cadena de modelo que `lpinfo -m` haya listado realmente en tu sistema:

   ```bash
   sudo lpadmin -p labps \
     -v file:/var/spool/lab-out/labps.ps \
     -m drv:///sample.drv/generic.ppd \
     -D "Lab PostScript queue (writes to a file)" \
     -L "Rack 4 / lab" \
     -o printer-is-shared=false \
     -E
   ```

   Si `drv:///sample.drv/generic.ppd` no está ofrecido, sustituilo por cualquier entrada PostScript genérica del paso 2. Omitir `-m`/`-P` por completo crea una cola **raw** (sin PPD, sin filtrado); CUPS moderno imprime un aviso de deprecación cuando lo hacés.

5. Verificá lo que se creó, en tres lugares independientes:

   ```bash
   lpstat -v labps
   lpstat -l -p labps
   sudo ls -l /etc/cups/ppd/
   sudo grep -A12 '<Printer labps>' /etc/cups/printers.conf
   ```

6. Creá una segunda cola para usar más adelante en los movimientos de trabajos:

   ```bash
   sudo lpadmin -p labps2 -v file:/var/spool/lab-out/labps2.ps \
     -m drv:///sample.drv/generic.ppd -D "Second lab queue" -E
   lpstat -a
   ```

7. Inspeccioná y cambiá opciones a nivel de driver:

   ```bash
   lpoptions -p labps -l | head -20        # PPD options: key/Choices, * marks the default
   sudo lpadmin -p labps -o PageSize=A4
   lpoptions -p labps -l | grep -i pagesize
   ```

> **Advertencia sobre AppArmor (Ubuntu).** Si nunca se escribe nada en `/var/spool/lab-out/`, revisá `journalctl -k | grep -i apparmor` buscando líneas `DENIED` que nombren al backend `file`, y o bien elegí una ruta que el perfil permita o ejecutá `sudo aa-complain /usr/sbin/cupsd` mientras dure el laboratorio.

**Preguntas de control**

- **Q3.1** — `lpadmin -E -p labps -v …` y `lpadmin -p labps -v … -E` *no* son equivalentes. Explicá con precisión qué significa `-E` en cada posición.
- **Q3.2** — Después del paso 4, ¿dónde guarda exactamente CUPS el PPD de `labps`, y qué le pasa a ese archivo cuando ejecutás `lpadmin -x labps`?
- **Q3.3** — ¿Qué es una cola *raw*, cuándo es la elección correcta, y cuál es la consecuencia práctica de mandarle un PDF?
- **Q3.4** — Explicá la diferencia entre `lpadmin -m <model>` y `lpadmin -P <file.ppd>`.
- **Q3.5** — Descomponé los URI de dispositivo `socket://192.0.2.40:9100` e `ipp://printer.example.com/ipp/print`: ¿qué backend maneja cada uno, y qué puerto TCP usa cada uno?

---

## Bloque 4 — Enviar trabajos: las dos familias de comandos

1. Enviá con el cliente System V y leé el ID de trabajo que devuelve:

   ```bash
   lp -d labps ~/report.txt
   ```

   ```
   request id is labps-1 (1 file(s))
   ```

2. Enviá con el cliente Berkeley, pidiendo dos copias y un título de trabajo:

   ```bash
   lpr -P labps -#2 -T "berkeley-test" ~/report.txt
   ```

   Notá que `lpr` no imprime nada cuando tiene éxito.

3. Observá la cola con ambas herramientas mientras hay trabajos pendientes:

   ```bash
   lpstat -o                 # jobs on all destinations
   lpstat -o labps -l        # long form: size, priority, user, time
   lpq -P labps              # Berkeley view
   lpq -a                    # all queues
   ```

   Ejemplo de `lpq`:

   ```
   labps is ready and printing
   Rank    Owner   Job     File(s)                         Total Size
   active  student 1       report.txt                      1024 bytes
   ```

4. Confirmá que el trabajo llegó realmente a la "impresora":

   ```bash
   ls -l /var/spool/lab-out/
   head -5 /var/spool/lab-out/labps.ps
   ```

5. Enviá tres trabajos seguidos y volvé a revisar el tamaño del archivo de salida:

   ```bash
   for i in 1 2 3; do lp -d labps -t "job-$i" ~/report.txt; done
   sleep 3; ls -l /var/spool/lab-out/labps.ps
   ```

6. Ejercitá el conjunto de opciones más común (misma escritura para `lp` y `lpr` cuando se usa `-o`):

   ```bash
   lp -d labps -n 3 -o media=A4 -o sides=two-sided-long-edge -o number-up=2 ~/report.txt
   lpr -P labps -o fit-to-page -o page-ranges=1-2 ~/report.txt
   ```

7. Cancelá trabajos de las dos formas:

   ```bash
   lp -d labps -H hold ~/report.txt      # keep something in the queue to cancel
   lpstat -o labps
   cancel labps-8                        # SysV: by job ID
   lprm -P labps 9                       # Berkeley: by job number
   cancel -a labps                       # everything on one queue
   lprm -                                # all of *your* jobs
   ```

8. Explorá las variables de entorno de destino por defecto:

   ```bash
   lpstat -d
   LPDEST=labps2 lp ~/report.txt ; lpstat -W completed -o labps2 | head -3
   PRINTER=labps2 lpr ~/report.txt
   ```

9. Leé el historial de completados en lugar de la cola viva:

   ```bash
   lpstat -W completed -o
   lpstat -W not-completed -o
   ```

**Preguntas de control**

- **Q4.1** — Escribí el comando para "5 copias de `manual.pdf` a la cola `hp2055`" en ambas familias.
- **Q4.2** — En el paso 5 enviaste tres trabajos a un URI de dispositivo `file:`. ¿Creció el archivo hasta tener tres documentos? Explicá el comportamiento del backend `file` y por qué eso importa cuando alguien lo propone como una "impresora PDF".
- **Q4.3** — ¿Exactamente qué fuentes determinan el destino cuando un usuario escribe `lp report.txt` sin `-d`, y en qué orden de precedencia?
- **Q4.4** — Tanto `cancel` como `lprm` eliminan trabajos. Nombrá dos diferencias de comportamiento.
- **Q4.5** — Un usuario dice "mi trabajo desapareció, `lpstat -o` no muestra nada, pero no se imprimió nada". ¿Qué único comando te dice si CUPS cree que el trabajo se completó?

---

## Bloque 5 — Los dos ejes ortogonales: accepting vs enabled

1. Establecé la línea base:

   ```bash
   lpstat -p -d
   lpstat -a
   ```

2. Cerrá la cola a *nuevos* envíos:

   ```bash
   sudo cupsreject -r "Toner order pending" labps
   lpstat -a labps
   lp -d labps ~/report.txt
   ```

   Esperado:

   ```
   labps not accepting requests since Thu 27 Aug 2026 10:31:44 AM -03 -
       Toner order pending
   lp: Destination "labps" is not accepting jobs.
   ```

3. Reabrila y confirmá que los envíos vuelven a tener éxito:

   ```bash
   sudo cupsaccept labps
   lpstat -a labps
   lp -d labps ~/report.txt
   ```

4. Ahora detené la *impresión* pero seguí aceptando trabajo:

   ```bash
   sudo cupsdisable -r "Scheduled maintenance window" labps
   lpstat -p labps
   lp -d labps ~/report.txt          # succeeds
   lpstat -o labps                   # job sits in the queue
   ```

5. Liberá la cola y mirá cómo se drena el atraso:

   ```bash
   sudo cupsenable labps
   sleep 3
   lpstat -o labps
   lpstat -W completed -o labps | head -3
   ```

6. Explorá las variantes destructivas:

   ```bash
   lp -d labps ~/report.txt
   sudo cupsdisable -c -r "Purging spool" labps     # -c cancels queued jobs
   lpstat -o labps
   sudo cupsenable labps
   sudo cupsdisable --hold labps                    # hold the job being printed instead of stopping it
   sudo cupsenable labps
   ```

7. Fijate en los alias heredados, todavía presentes en muchos sistemas:

   ```bash
   ls -l /usr/sbin/accept /usr/sbin/reject 2>/dev/null
   ls -l /usr/sbin/enable /usr/sbin/disable 2>/dev/null
   ```

**Preguntas de control**

- **Q5.1** — Completá esta matriz: para cada combinación de *accepting/rejecting* × *enabled/disabled*, indicá qué pasa con un trabajo recién enviado.
- **Q5.2** — Una impresora se reemplaza mañana a la mañana y hay que avisar a los usuarios ahora, pero no se debe perder ningún trabajo. ¿Cuál de los cuatro comandos ejecutás, y por qué no los otros?
- **Q5.3** — ¿Por qué es peligroso escribir `enable`/`disable` en un script de shell, y qué hizo CUPS 1.4 al respecto?
- **Q5.4** — ¿Qué comando *a la vez* detiene la impresión y vacía la cola en una sola invocación?

---

## Bloque 6 — Control de trabajos: hold, release, move, priorizar, modificar

1. Llená una cola con trabajos distinguibles mientras está detenida:

   ```bash
   sudo cupsdisable labps
   for i in a b c; do lp -d labps -t "doc-$i" ~/report.txt; done
   lpstat -o labps -l
   ```

2. Retené un trabajo específico indefinidamente y después inspeccioná su estado:

   ```bash
   JOB=$(lpstat -o labps | awk 'NR==1{print $1}')
   lp -i "$JOB" -H hold
   lpstat -o labps -l | head -12
   ```

3. Liberalo:

   ```bash
   lp -i "$JOB" -H resume
   ```

4. Programá un trabajo para fuera de horario usando los valores nombrados de `hold-until`:

   ```bash
   lp -d labps -H night ~/report.txt
   lp -d labps -H 23:30 ~/report.txt
   lpstat -o labps -l | grep -i -A2 'held\|hold'
   ```

5. Cambiá los atributos de un trabajo en cola sin reenviarlo:

   ```bash
   JOB2=$(lpstat -o labps | awk 'NR==2{print $1}')
   lp -i "$JOB2" -n 4 -o media=Letter -q 90
   lpstat -o labps -l | head
   ```

6. Mové trabajo entre destinos:

   ```bash
   lpmove "$JOB2" labps2          # one job
   sudo lpmove labps labps2       # every remaining job on labps
   lpstat -o
   ```

7. Drená todo y restaurá la operación normal:

   ```bash
   sudo cupsenable labps labps2
   sleep 3
   lpstat -o
   ```

**Preguntas de control**

- **Q6.1** — ¿Qué opción de `lp` retiene un trabajo ya enviado, y qué opción identifica *a qué* trabajo se aplica?
- **Q6.2** — Listá las palabras clave simbólicas de `hold-until` que acepta CUPS, e indicá cómo se interpreta un valor `HH:MM` pelado.
- **Q6.3** — ¿Cuál es el rango válido de `lp -q`, cuál es el valor por defecto, y subirlo afecta a un trabajo que ya se está imprimiendo?
- **Q6.4** — Una impresora murió a mitad de turno con 40 trabajos en cola. Dá la secuencia de dos comandos que redirige todo el atraso a la impresora idéntica que está al lado.
- **Q6.5** — `lpmove 12 other` frente a `lpmove hp1 other` — ¿cómo decide `lpmove` a cuál de los dos te referías?

---

## Bloque 7 — Clases, destinos por defecto y `lpoptions`

1. Armá una clase con las dos colas del laboratorio (la clase se crea implícitamente):

   ```bash
   sudo lpadmin -p labps  -c labpool
   sudo lpadmin -p labps2 -c labpool
   lpstat -c
   lpstat -a
   sudo grep -A6 '<Class labpool>' /etc/cups/classes.conf
   ```

2. Imprimí a la clase y observá qué miembro toma el trabajo:

   ```bash
   for i in 1 2 3 4; do lp -d labpool -t "pool-$i" ~/report.txt; done
   sleep 3
   ls -l /var/spool/lab-out/
   lpstat -W completed -o labpool | head
   ```

3. Sacá un miembro para mantenimiento y confirmá que la clase sigue funcionando:

   ```bash
   sudo cupsdisable labps
   lp -d labpool ~/report.txt
   sleep 2; ls -l /var/spool/lab-out/labps2.ps
   sudo cupsenable labps
   ```

4. Fijá el valor por defecto **de todo el servidor** y revisalo:

   ```bash
   sudo lpadmin -d labpool
   lpstat -d
   sudo grep -i '^DefaultPrinter\|<DefaultPrinter' /etc/cups/printers.conf /etc/cups/classes.conf 2>/dev/null
   ```

5. Fijá un valor por defecto **por usuario** y opciones por defecto por usuario, y después encontrá dónde se escribieron:

   ```bash
   lpoptions -d labps2
   lpoptions -p labps2 -o sides=two-sided-long-edge -o media=A4
   cat ~/.cups/lpoptions
   lpstat -d
   ```

6. Fijá opciones de cliente por defecto **para todo el sistema** como root y comparalo:

   ```bash
   sudo lpoptions -p labps -o media=Letter
   sudo cat /etc/cups/lpoptions
   ```

7. Quitá un ajuste de nivel de usuario y un miembro de la clase:

   ```bash
   lpoptions -x labps2                 # drop this user's saved options for labps2
   sudo lpadmin -p labps2 -r labpool   # remove member from class
   lpstat -c
   ```

**Preguntas de control**

- **Q7.1** — ¿Qué es una clase de CUPS, y qué te da que no te dé una única cola compartida?
- **Q7.2** — ¿Qué le pasa a una clase cuando quitás su último miembro?
- **Q7.3** — Distinguí `lpadmin -d`, `lpoptions -d` ejecutado como usuario, y la variable `LPDEST`: ¿cuál de los tres afecta a otros usuarios, y qué archivo respalda a cada uno?
- **Q7.4** — `lpoptions -p q -o media=A4` como root frente a como usuario sin privilegios: ¿qué archivos se escriben, y cuál de los dos sobrevive a que un usuario borre su directorio home?
- **Q7.5** — ¿Por qué `lpstat -d` a veces no coincide con lo que ve un colega en la misma máquina?

---

## Bloque 8 — Control de acceso y cuotas en una cola

1. Restringí una cola a usuarios nombrados y verificá:

   ```bash
   sudo lpadmin -p labps -u allow:root,"$USER"
   lpstat -l -p labps | sed -n '/Users allowed/,+3p'
   sudo grep -A2 'AllowUser' /etc/cups/printers.conf
   ```

2. Probá la denegación con una segunda cuenta (creá una solo si te sentís cómodo haciéndolo):

   ```bash
   sudo useradd -m -s /bin/bash printtest 2>/dev/null
   sudo -u printtest lp -d labps ~/report.txt
   ```

   Esperado: un client-error indicando que el usuario no está autorizado para el destino.

3. Cambiá a una lista de denegación y después volvé a "todos":

   ```bash
   sudo lpadmin -p labps -u deny:printtest
   sudo lpadmin -p labps -u allow:all
   lpstat -l -p labps | grep -i users
   ```

4. Aplicá una cuota de páginas — 20 páginas por cada 24 horas móviles:

   ```bash
   sudo lpadmin -p labps -o job-quota-period=86400 -o job-page-limit=20
   sudo lpadmin -p labps -o job-k-limit=2048        # 2 MB of data in the same period
   sudo grep -E 'QuotaPeriod|PageLimit|KLimit' /etc/cups/printers.conf
   ```

5. Mirá los límites de todo el scheduler que hacen contrapresión al servidor entero:

   ```bash
   sudo grep -iE '^\s*(MaxJobs|MaxJobsPerPrinter|MaxJobsPerUser|MaxCopies)' /etc/cups/cupsd.conf
   ```

6. Mirá la política de operaciones IPP que gobierna *quién puede administrar*:

   ```bash
   sudo sed -n '/<Policy default>/,/<\/Policy>/p' /etc/cups/cupsd.conf | head -40
   grep -E '^SystemGroup' /etc/cups/cups-files.conf
   getent group lpadmin lpadmin sys wheel 2>/dev/null
   ```

**Preguntas de control**

- **Q8.1** — ¿Qué archivo de contabilidad de CUPS debe existir y mantenerse para que `job-page-limit` sea siquiera aplicable?
- **Q8.2** — Distinguí `lpadmin -u allow:…` de un bloque `<Location /printers/labps>` con `Require user …`. ¿Cuál bloquea el *envío* y cuál bloquea la *petición HTTP/IPP*?
- **Q8.3** — `SystemGroup` en `cups-files.conf` lista `lpadmin`. Se agrega un usuario a ese grupo pero todavía recibe "Forbidden" desde la interfaz web. Dá dos causas plausibles.
- **Q8.4** — ¿Cuál es la diferencia entre `MaxJobs 0` y `MaxJobs 1`?

---

## Bloque 9 — El directorio de spool, los archivos de control y los tres logs

1. Estacioná un trabajo para poder disecarlo:

   ```bash
   sudo cupsdisable labps
   lp -d labps -t "forensics" ~/report.txt
   JOB=$(lpstat -o labps | awk 'NR==1{print $1}' | sed 's/.*-//')
   echo "job number: $JOB"
   ```

2. Examiná el spool como root, incluidos los permisos:

   ```bash
   sudo ls -ld /var/spool/cups
   sudo ls -l  /var/spool/cups | head
   ```

   Forma esperada: el directorio `drwx--x---  root lp`, archivos de control `c<NNNNN>` y archivos de datos `d<NNNNN>-001`, modo `0640 root:lp`.

3. Leé el archivo de control — es un grupo de atributos IPP binario, no texto:

   ```bash
   sudo strings /var/spool/cups/c$(printf '%05d' "$JOB") | head -30
   ```

   Buscá `job-name`, `job-originating-user-name`, `job-originating-host-name`, `document-format`, `job-priority`, `time-at-creation`, `printer-uri`.

4. Identificá el tipo de contenido real del archivo de datos:

   ```bash
   sudo file /var/spool/cups/d$(printf '%05d' "$JOB")-001
   ```

5. Liberá el trabajo y ubicá los tres logs:

   ```bash
   sudo cupsenable labps ; sleep 2
   sudo ls -l /var/log/cups/
   grep -iE '^(ErrorLog|AccessLog|PageLog)' /etc/cups/cups-files.conf
   ```

   En sistemas configurados con `ErrorLog syslog` (común en Fedora/RHEL), leelos con `journalctl -u cups -n 50` en su lugar.

6. Leé el log de contabilidad y decodificá sus campos:

   ```bash
   sudo tail -3 /var/log/cups/page_log
   ```

   ```
   labps student 12 [27/Aug/2026:10:44:02 -0300] 1 1 - localhost forensics a4 one-sided
   ```

   Campos: `printer user job-id date-time page-number num-copies job-billing hostname job-name media sides`.

7. Leé el log de peticiones:

   ```bash
   sudo tail -5 /var/log/cups/access_log
   ```

   ```
   localhost - - [27/Aug/2026:10:44:01 -0300] "POST /printers/labps HTTP/1.1" 200 456 Print-Job successful-ok
   ```

   Los dos últimos campos son el **nombre de la operación IPP** y el **código de estado IPP** — esto es lo que lo distingue del log de un servidor web común.

8. Activá el registro de depuración, reproducí, y después leé la traza por trabajo:

   ```bash
   sudo cupsctl --debug-logging
   lp -d labps ~/report.txt
   sleep 2
   sudo grep "\[Job $((JOB+1))\]" /var/log/cups/error_log | head -40
   ```

   Fijate en los prefijos de severidad de una sola letra al inicio de línea: `E` error, `W` warning, `N` notice, `I` info, `D` debug, `d` debug2.

9. Volvé a apagarlo antes de que llene el disco:

   ```bash
   sudo cupsctl --no-debug-logging
   grep -iE '^(LogLevel|MaxLogSize)' /etc/cups/cupsd.conf
   ```

10. Controlá la retención del historial:

    ```bash
    grep -iE '^(PreserveJobHistory|PreserveJobFiles)' /etc/cups/cupsd.conf
    lpstat -W completed -o labps | head
    cancel -a -x labps                     # purge job history for this queue
    lpstat -W completed -o labps
    ```

**Preguntas de control**

- **Q9.1** — ¿Qué contiene el archivo `c00042` frente a `d00042-001`? ¿Cuál desaparece primero con los ajustes por defecto, y qué directiva controla cada uno?
- **Q9.2** — `/var/spool/cups` tiene modo `0710 root:lp`. Explicá qué permite ese modo y por qué el diseño lo eligió en lugar de `0755`.
- **Q9.3** — Para "quién imprimió cuántas páginas el mes pasado, y a qué impresora", ¿qué log parseás y qué campos sumás?
- **Q9.4** — Necesitás probar que un host cliente específico envió un trabajo en un momento específico, y el trabajo ya no existe hace mucho. ¿Qué log lo sobrevive, y qué campo lleva el host?
- **Q9.5** — El registro de depuración está activo, el disco se está llenando, y no debés interrumpir la impresión. Dá el comando y explicá por qué no reinicia el demonio.

---

## Bloque 10 — Diagnóstico de fallas de punta a punta

1. Rompé la cola de una forma realista — un dispositivo que el backend no puede alcanzar:

   ```bash
   sudo lpadmin -p labps -v file:/root/definitely/not/there/out.ps
   lpstat -v labps
   ```

2. Enviá y observá la falla:

   ```bash
   lp -d labps -t "will-fail" ~/report.txt
   sleep 3
   lpstat -p labps
   lpstat -l -p labps
   lpstat -o labps
   ```

   Esperado: la cola ahora está **disabled** con un `printer-state-message`, y el trabajo sigue en cola en lugar de perderse.

3. Encontrá el veredicto del backend en el log:

   ```bash
   sudo grep -iE 'Backend|status|Unable to (open|write)' /var/log/cups/error_log | tail -20
   ```

   Buscá una línea que informe el estado de salida del backend; `1` significa `CUPS_BACKEND_FAILED`.

4. Inspeccioná los códigos de razón que el scheduler está exportando por IPP:

   ```bash
   lpstat -l -p labps | sed -n '1,6p'
   ```

   Razones como `paused`, `filter-failed`, `media-empty-warning`, `toner-low` aparecen acá y gobiernan cada icono de estado en las GUI.

5. Cambiá la política de fallas para que el trabajo reintente en lugar de detener la cola:

   ```bash
   sudo lpadmin -p labps -o printer-error-policy=retry-job
   sudo grep -i 'ErrorPolicy' /etc/cups/printers.conf /etc/cups/cupsd.conf
   ```

   Valores válidos: `abort-job`, `retry-job`, `retry-current-job`, `stop-printer` (el valor por defecto). La cadencia de reintentos la gobiernan `JobRetryInterval` / `JobRetryLimit` en `cupsd.conf`.

6. Repará el URI de dispositivo, reactivá, y confirmá la recuperación:

   ```bash
   sudo lpadmin -p labps -v file:/var/spool/lab-out/labps.ps
   sudo cupsenable labps
   sleep 3
   lpstat -o labps ; lpstat -p labps ; ls -l /var/spool/lab-out/labps.ps
   ```

7. Ejercitá la cadena de filtros independientemente de cualquier cola — esto aísla "problema de driver" de "problema de dispositivo":

   ```bash
   cupsfilter --list-filters -m application/vnd.cups-postscript ~/report.txt 2>&1 | head
   cupsfilter -m application/pdf ~/report.txt > /tmp/report.pdf 2>/tmp/filter.err
   file /tmp/report.pdf ; head -3 /tmp/filter.err
   ls -l /usr/lib/cups/filter/ | head
   ```

8. Probá el transporte independientemente de CUPS, como lo harías contra hardware real:

   ```bash
   # raw JetDirect port on a real printer:
   #   nc -vz 192.0.2.40 9100
   # IPP endpoint:
   #   curl -s -o /dev/null -w '%{http_code}\n' http://192.0.2.40:631/
   ss -lnt | grep 631
   ```

**Preguntas de control**

- **Q10.1** — El comportamiento por defecto de CUPS ante una falla del backend es detener la impresora y *conservar* el trabajo. Argumentá por qué ese es el valor por defecto correcto para una impresora de oficina compartida y equivocado para un servidor de lotes desatendido de alto volumen, y dá el cambio de una línea para el segundo caso.
- **Q10.2** — Un usuario informa "no imprime nada". Escribí la secuencia diagnóstica ordenada — scheduler → estado de la cola → estado del trabajo → backend/filtro → dispositivo — como una lista de comandos concretos.
- **Q10.3** — La salida sale como páginas de código fuente PostScript en crudo. ¿Cuál es el defecto, y qué dos hechos de `lpadmin` revisás primero?
- **Q10.4** — ¿Qué te permite probar `cupsfilter` que enviar un trabajo de prueba no puede?
- **Q10.5** — `lpstat -p` dice `idle` y `enabled`, los trabajos desaparecen de `lpstat -o` inmediatamente, y no se imprime nada. ¿Dónde mirás después?

---

## Bloque 11 — Impresión remota: IPP, descubrimiento y la interfaz LPD heredada

1. Hacé que `cupsd` escuche más allá de localhost (solo laboratorio — leé la advertencia de abajo):

   ```bash
   sudo cp /etc/cups/cupsd.conf /etc/cups/cupsd.conf.lab
   sudo sed -i 's/^Listen localhost:631/Listen 0.0.0.0:631/' /etc/cups/cupsd.conf
   sudo cupsd -t && sudo systemctl restart cups
   sudo ss -lnt | grep 631
   ```

2. Compartí una cola y activá el anuncio local:

   ```bash
   sudo lpadmin -p labps -o printer-is-shared=true
   sudo cupsctl --share-printers
   grep -iE '^(Browsing|BrowseLocalProtocols)' /etc/cups/cupsd.conf
   ```

3. Confirmá el bloque de control de acceso que lo regula (en `cupsd.conf`):

   ```bash
   sudo sed -n '/<Location \/>/,/<\/Location>/p' /etc/cups/cupsd.conf
   ```

   La forma segura canónica es `Order allow,deny` + `Allow @LOCAL`, no `Allow all`.

4. Hablale a un servidor CUPS como cliente, sin configurar nada localmente:

   ```bash
   lpstat -h localhost:631 -p
   lp -h localhost:631 -d labps ~/report.txt
   ```

5. Agregá una cola *remota* por URI (la forma normal de consumir la impresora de otro servidor):

   ```bash
   sudo lpadmin -p remotelab -E -v ipp://localhost:631/printers/labps -m everywhere
   lpstat -v remotelab
   lp -d remotelab ~/report.txt ; sleep 2 ; ls -l /var/spool/lab-out/labps.ps
   ```

   `-m everywhere` construye el driver a partir de los propios atributos IPP de la impresora (IPP Everywhere / driverless) y por lo tanto requiere que el URI de dispositivo sea alcanzable en el momento de la creación.

6. Herramientas de descubrimiento:

   ```bash
   ippfind 2>/dev/null | head
   driverless list 2>/dev/null | head
   systemctl status cups-browsed --no-pager 2>/dev/null | head -5
   grep -iE '^(BrowseRemoteProtocols|BrowseProtocols)' /etc/cups/cups-browsed.conf 2>/dev/null
   ```

7. La interfaz LPD heredada, en ambas direcciones:

   ```bash
   # (a) the printcap CUPS generates for LPD-era applications
   grep -i '^Printcap' /etc/cups/cups-files.conf
   cat /etc/printcap

   # (b) serving legacy LPD clients on TCP/515 (not enabled by default)
   systemctl list-unit-files 'cups-lpd*'
   ls -l /usr/lib/cups/daemon/cups-lpd 2>/dev/null

   # (c) consuming a legacy LPD queue from CUPS
   # sudo lpadmin -p oldline -E -v lpd://192.0.2.50/queuename -m drv:///sample.drv/generic.ppd
   ```

8. Firewall:

   ```bash
   sudo firewall-cmd --list-services 2>/dev/null            # look for "ipp" / "ipp-client" / "mdns"
   sudo ufw status 2>/dev/null
   ```

9. Revertí la exposición en red:

   ```bash
   sudo cp /etc/cups/cupsd.conf.lab /etc/cups/cupsd.conf
   sudo cupsd -t && sudo systemctl restart cups
   sudo ss -lnt | grep 631
   ```

**Preguntas de control**

- **Q11.1** — Dá el protocolo de transporte y el puerto TCP para: IPP, IPPS, LPD, raw/JetDirect, y descubrimiento mDNS/DNS-SD.
- **Q11.2** — ¿Cuál es la diferencia entre `Listen 631`, `Port 631` y `Listen localhost:631`?
- **Q11.3** — Dos mecanismos pueden hacer que una impresora remota aparezca en un cliente: el propio compartido IPP de `cupsd`, y `cups-browsed`. Explicá la división del trabajo y cuál de los dos crea colas locales.
- **Q11.4** — ¿Quién escribe `/etc/printcap` en un sistema CUPS, para qué sirve, y qué pasa si lo editás a mano?
- **Q11.5** — Un host AS/400 heredado tiene que enviar trabajos con `lpr` por la red a tu servidor Linux. ¿Qué tenés que habilitar, y en qué puerto?
- **Q11.6** — Contrastá `lp -h server -d q file` con crear una cola local cuyo URI de dispositivo sea `ipp://server/printers/q`. ¿Cuándo es correcta cada una?

---

## Bloque 12 — Limpieza y endurecimiento de vuelta a un estado sano

1. Quitá los objetos del laboratorio:

   ```bash
   sudo lpadmin -x labpool 2>/dev/null
   sudo lpadmin -x remotelab 2>/dev/null
   sudo lpadmin -x labps2
   sudo lpadmin -x labps
   lpstat -a ; lpstat -c
   sudo ls -l /etc/cups/ppd/
   ```

2. Revertí los dos ajustes inseguros:

   ```bash
   sudo sed -i 's/^FileDevice Yes/FileDevice No/' /etc/cups/cups-files.conf
   sudo cupsctl --no-debug-logging --no-remote-admin --no-remote-any
   sudo cupsd -t && sudo systemctl restart cups
   sudo cupsctl | grep -E '_debug_logging|_remote'
   ```

3. Eliminá los artefactos del laboratorio y la cuenta de prueba:

   ```bash
   sudo rm -rf /var/spool/lab-out /etc/cups/cupsd.conf.lab /etc/cups/cupsd.conf.bak
   rm -f ~/report.txt /tmp/report.pdf /tmp/filter.err
   sudo userdel -r printtest 2>/dev/null
   rm -f ~/.cups/lpoptions
   ```

4. Verificación final:

   ```bash
   lpstat -t
   sudo cupsd -t
   ```

**Preguntas de control**

- **Q12.1** — `lpadmin -x` quitó la cola. Nombrá tres archivos o directorios cuyo contenido cambió como consecuencia.
- **Q12.2** — ¿Por qué revertir `FileDevice` a `No` es un paso genuino de endurecimiento y no solo prolijidad?

---

## Fuentes

- LPI — *Exam 101-500 Objectives*: <https://www.lpi.org/our-certifications/exam-101-objectives/>
- LPI — *Exam 102-500 Objectives* (el tema 108.4 se examina acá): <https://www.lpi.org/our-certifications/exam-102-objectives/>
- Página principal de la documentación de OpenPrinting CUPS: <https://openprinting.github.io/cups/>
- Páginas de manual de CUPS — `cupsd.conf`: <https://openprinting.github.io/cups/doc/man-cupsd.conf.html> · `cups-files.conf`: <https://openprinting.github.io/cups/doc/man-cups-files.conf.html> · `lpadmin`: <https://openprinting.github.io/cups/doc/man-lpadmin.html> · `lp`: <https://openprinting.github.io/cups/doc/man-lp.html> · `lpr`: <https://openprinting.github.io/cups/doc/man-lpr.html> · `lpstat`: <https://openprinting.github.io/cups/doc/man-lpstat.html> · `cupsenable`/`cupsdisable`: <https://openprinting.github.io/cups/doc/man-cupsenable.html> · `cupsaccept`/`cupsreject`: <https://openprinting.github.io/cups/doc/man-cupsaccept.html> · `lpoptions`: <https://openprinting.github.io/cups/doc/man-lpoptions.html> · `cupsfilter`: <https://openprinting.github.io/cups/doc/man-cupsfilter.html>
- CUPS — *Printer Accounting Basics* (page_log): <https://openprinting.github.io/cups/doc/accounting.html>
- CUPS — *Server Security* y *Network Printers*: <https://openprinting.github.io/cups/doc/security.html> · <https://openprinting.github.io/cups/doc/network.html>
- OpenPrinting cups-filters / cups-browsed: <https://github.com/OpenPrinting/cups-filters>
- RFC 8011 — *Internet Printing Protocol/1.1: Model and Semantics*: <https://www.rfc-editor.org/rfc/rfc8011>
- RFC 1179 — *Line Printer Daemon Protocol*: <https://www.rfc-editor.org/rfc/rfc1179>

---

<details>
<summary><strong>▶ Respuestas — expandí solo después de intentar cada bloque</strong></summary>

### Bloque 0

**A0.1** — Familia System V: `lp`, `lpstat`, `cancel` (más las herramientas de administración `lpadmin`, `lpmove`, `lpinfo`, `lpoptions`, `cupsaccept`, `cupsenable`). Familia Berkeley/LPD: `lpr`, `lpq`, `lprm`. CUPS implementa *ambos* front-ends sobre su transporte nativo IPP para que décadas de scripts y aplicaciones escritos para cualquiera de los dos sistemas heredados sigan funcionando sin cambios. Ninguna de las dos familias habla localmente el histórico protocolo `lpsched` de SysV ni el `lpd` de Berkeley — son clientes de CUPS con nombres viejos puestos.

**A0.2** — `/usr/sbin` es por convención para binarios administrativos que se espera que ejecute root y no está en el `PATH` por defecto de un usuario sin privilegios en muchas distribuciones. `lpadmin`, `cupsenable`, `cupsaccept`, `lpinfo` cambian el estado del servidor; `lp`, `lpr`, `lpq`, `lpstat`, `cancel` son operaciones de usuario común. Notá que esto es una *convención*: la imposición real es la política de operaciones IPP en `cupsd.conf` más `SystemGroup`, no el directorio.

**A0.3** — No. Dos cosas independientes comparten el nombre. `lpr` es un *comando de cliente*; su ausencia solo significa que los usuarios no pueden escribir `lpr`. El soporte del *protocolo* LPD es aparte: saliente mediante el backend `lpd://` (CUPS imprimiendo a un dispositivo LPD heredado) y entrante mediante `cups-lpd`, el demonio que acepta conexiones RFC 1179 en el puerto 515. Cualquiera de los dos puede estar presente sin el binario `lpr`.

### Bloque 1

**A1.1** — `cups.socket` (y a menudo `cups.path`) seguían activos; systemd mantiene `/run/cups/cups.sock` y arranca `cups.service` en el momento en que un cliente se conecta. `lpstat -r` era ese cliente. Para mantenerlo caído:
```bash
sudo systemctl stop cups.socket cups.path cups.service
sudo systemctl disable --now cups.socket cups.path cups.service
# or, in one shot:
sudo systemctl mask cups.socket cups.path cups.service
```
Detener solo el service es el error clásico de respuesta a incidentes en esta área.

**A1.2** — Un error de sintaxis en `cupsd.conf` hace que `cupsd` se niegue a arrancar. Si hacés `systemctl restart` a ciegas por SSH, dejás la impresión caída para todo el mundo sin forma de ver el error de antemano. `cupsd -t` parsea el archivo, informa el archivo y la línea infractores, y sale con código distinto de cero — es un chequeo previo seguro y se compone con `&&`: `sudo cupsd -t && sudo systemctl restart cups`.

**A1.3** — El reload vuelve a leer `cupsd.conf`. **No** vuelve a leer `cups-files.conf`, cuyas directivas de rutas/privilegios (`User`, `Group`, `RequestRoot`, `ErrorLog`, `FileDevice`, `SystemGroup`) se aplican al arrancar — esas necesitan un restart completo. También hace falta un restart después de cambiar direcciones/puertos de escucha en algunas versiones, y después de reemplazar material TLS.

**A1.4** — Casi con certeza el socket de dominio UNIX `/run/cups/cups.sock`, porque el `cupsd.conf` por defecto solo tiene `Listen localhost:631` más el socket de dominio, y libcups prefiere el socket de dominio para un servidor local. Probalo con `lpstat -H` (imprime el endpoint del servidor que resolvió el cliente) o trazando: `strace -f -e trace=connect lpstat -r 2>&1 | grep -i sun_path`.

### Bloque 2

**A2.1** — `ErrorLog` está en **`cups-files.conf`**; `LogLevel` está en **`cupsd.conf`**. La separación llegó en CUPS 1.6. `cupsd.conf` puede editarse por la red desde un administrador de CUPS autenticado a través de la interfaz web, mientras `cups-files.conf` no. Como directivas como `ErrorLog`, `User`, `Group`, `RequestRoot` y `FileDevice` deciden *qué escribe un demonio con privilegios de root y en nombre de quién*, permitir ediciones remotas sobre ellas sería una vía de escalada de privilegios. Moverlas a un archivo que solo root puede editar en disco cierra esa vía.

**A2.2** — `cupsd` mantiene el estado de las impresoras en memoria y **reescribe `printers.conf` él mismo** cada vez que ese estado cambia (una cola habilitada, un valor por defecto fijado, un contador de trabajos que avanza). Tus ediciones quedan sobrescritas silenciosamente en la siguiente escritura, y puede que estés editando un archivo que está a punto de ser reemplazado. Procedimiento correcto: usá `lpadmin`/`cupsenable`/`cupsaccept`/`cupsctl`. Si de verdad tenés que editar a mano: `systemctl stop cups` → editar → `cupsd -t` → `systemctl start cups`.

**A2.3** — `sudo cupsctl --share-printers` pone `Browsing On` más la semántica del flag de compartido para las colas, y `--remote-any` amplía los bloques `<Location>` para aceptar peticiones desde cualquier dirección; `sudo cupsctl --remote-admin` reescribe las líneas `Allow` de los bloques `<Location /admin>` (y `/admin/conf`) para permitir administración desde fuera de localhost. `cupsctl` es un cliente que edita `cupsd.conf` mediante IPP y recarga el servidor, así que es la forma scriptable y segura en cuanto a sintaxis de hacer estos cambios. Sus negaciones son `--no-share-printers`, `--no-remote-any`, `--no-remote-admin`.

**A2.4** — Copiar de vuelta el valor por defecto del paquete: `sudo cp /etc/cups/cupsd.conf.default /etc/cups/cupsd.conf && sudo cupsd -t && sudo systemctl restart cups`. CUPS instala esa copia de referencia precisamente para esto. (Si eso falla, hacé `dpkg -S`/`rpm -qf` sobre la ruta y reinstalá el paquete con restauración de configuración.)

### Bloque 3

**A3.1** — La posición es todo:
- `-E` **antes** de `-p`/`-d`/`-h` (es decir, antes de que se conozca el destino) significa *"forzar el cifrado en la conexión al servidor"* — el sentido de `cupsSetEncryption(HTTP_ENCRYPTION_REQUIRED)`.
- `-E` **después** de `-p <queue>` significa *"habilitar este destino y ponerlo a aceptar trabajos"* — equivalente a `cupsenable queue; cupsaccept queue`.

Una cola creada sin un `-E` al final existe pero está deshabilitada y rechazando, que es el escenario clásico de "creé la impresora y no imprime nada".

**A3.2** — `/etc/cups/ppd/labps.ppd`. CUPS copia y normaliza el modelo que seleccionaste en esa ruta; a partir de ahí es el driver autoritativo de la cola, así que editar más tarde el PPD de origen original no tiene efecto. `lpadmin -x labps` borra la estrofa de la cola en `printers.conf`, elimina `/etc/cups/ppd/labps.ppd` y cancela los trabajos de la cola.

**A3.3** — Una cola raw **no tiene PPD**, así que CUPS no hace ningún filtrado: los datos del trabajo se pasan al backend byte por byte. Es correcta cuando el cliente ya produce el lenguaje nativo de la impresora (un cliente Windows con el driver del fabricante imprimiendo a través de un relay CUPS en Linux, o una impresora de etiquetas/tickets alimentada con ZPL/ESC-POS). Mandale un PDF a una cola raw conectada a una impresora PCL y la impresora recibe código fuente PDF que no puede interpretar — obtenés páginas de basura o nada. Las colas raw están deprecadas en el CUPS actual y se están eliminando en CUPS 3.x.

**A3.4** — `-m <model>` nombra un driver del catálogo propio del scheduler, tal como lo informa `lpinfo -m` (una cadena tipo URI como `everywhere`, `drv:///sample.drv/generic.ppd`, o una ruta `.ppd.gz` relativa a `/usr/share/cups/model/`). `-P <file.ppd>` apunta a un archivo PPD arbitrario del sistema de archivos local, típicamente uno que descargaste del fabricante. Ambos terminan con una copia en `/etc/cups/ppd/<queue>.ppd`.

**A3.5** — `socket://192.0.2.40:9100` → el backend `socket`, AppSocket/JetDirect crudo sobre **TCP 9100** (el valor por defecto cuando se omite el puerto); sin negociación de protocolo, sin estado más allá de "la conexión TCP funcionó". `ipp://printer.example.com/ipp/print` → el backend `ipp`, IPP sobre HTTP en **TCP 631**, que da estado real del trabajo, atributos de medios/insumos y descubrimiento driverless de capacidades. Preferí `ipp`/`ipps` siempre que el dispositivo lo soporte.

### Bloque 4

**A4.1** — SysV: `lp -d hp2055 -n 5 manual.pdf`. Berkeley: `lpr -P hp2055 -#5 manual.pdf`. Acordate de `-n` vs `-#`, y de `-d` vs `-P`.

**A4.2** — No — el archivo contiene solo el **último** trabajo. El backend `file` de CUPS abre el destino con semántica de crear/truncar, así que cada trabajo sobrescribe al anterior. Por eso `file:` es un dispositivo de depuración, no una solución de "imprimir a PDF"; para eso último usá un backend de impresora virtual real (`cups-pdf`) que genera un archivo de salida con nombre único por trabajo en el directorio del usuario que lo envía.

**A4.3** — En orden, gana la primera coincidencia:
1. la línea de comandos (`lp -d`, `lpr -P`);
2. la variable de entorno `LPDEST`;
3. la variable de entorno `PRINTER`;
4. el valor por defecto del usuario en `~/.cups/lpoptions` (fijado con `lpoptions -d`);
5. el valor por defecto de cliente para todo el sistema en `/etc/cups/lpoptions`;
6. el valor por defecto del servidor fijado con `lpadmin -d` (registrado en `printers.conf`/`classes.conf` e informado por `lpstat -d`).

**A4.4** — (1) Sintaxis del identificador: `cancel` toma un ID de trabajo completo de CUPS `queue-NN` (o un número pelado), mientras `lprm` toma números de trabajo pelados y necesita `-P queue` para un destino que no sea el predeterminado. (2) Semántica masiva: `cancel -a [queue]` cancela todos los trabajos de un destino, `cancel -u user` todos los de un usuario; `lprm -` cancela los trabajos *del usuario que lo invoca*, y `lprm` sin argumentos cancela solo el trabajo actual/primero. `cancel` además tiene `-x` para purgar el historial de trabajos, que no tiene equivalente en `lprm`.

**A4.5** — `lpstat -W completed -o` (opcionalmente con el nombre de la cola). `lpstat -o` muestra por defecto solo los trabajos *no completados*, así que un trabajo que CUPS considera terminado es invisible ahí. Si el trabajo aparece como completado, CUPS entregó los datos al backend con éxito y el problema está aguas abajo (dispositivo, driver, bandeja de salida); si no aparece nunca, el trabajo fue cancelado, purgado, o nunca fue aceptado.

### Bloque 5

**A5.1**

| | **Enabled** (imprimiendo) | **Disabled** (`cupsdisable`) |
|---|---|---|
| **Accepting** (`cupsaccept`) | Operación normal: el trabajo se acepta y se imprime. | El trabajo se **acepta y se encola**; no se imprime nada hasta `cupsenable`. No se pierde nada. |
| **Rejecting** (`cupsreject`) | El envío falla de inmediato (`Destination "x" is not accepting jobs`); los trabajos ya encolados **siguen imprimiéndose** y la cola se drena. | El envío falla *y* no se imprime nada — el estado completamente cerrado, usado antes de borrar una cola. |

Los dos ejes son independientes: `accept/reject` regula la *puerta de entrada* (nuevos envíos), `enable/disable` regula la *puerta de salida* (envío al dispositivo).

**A5.2** — `sudo cupsreject -r "Printer replaced 08:00 tomorrow — use hp-2f" hp-2e`. Impide que se acumule trabajo nuevo y, crucialmente, les da a los usuarios la cadena de razón en el mensaje de error que reciben de `lp`, mientras los trabajos ya encolados siguen saliendo en el dispositivo viejo. `cupsdisable` estaría mal — acepta trabajos en una cola que va a ser borrada. `cupsdisable -c` destruiría el trabajo pendiente. No hacer nada deja a los usuarios imprimiendo a una máquina que desaparece de un día para el otro.

**A5.3** — `enable` y `disable` colisionan con el **built-in del shell** `enable` (bash) y con los nombres de SysV, así que `enable hp1` en un script puede alternar un built-in del shell en lugar de una cola de impresión, y el resultado depende del shell y del `PATH`. CUPS 1.4 renombró los comandos a `cupsenable` y `cupsdisable` (manteniendo `/usr/sbin/enable`/`disable` como enlaces de compatibilidad en algunas distribuciones). Escribí siempre `cupsenable`/`cupsdisable` en los scripts.

**A5.4** — `cupsdisable -c <queue>` — `-c` cancela todos los trabajos del destino al detenerlo. (`cupsdisable --hold` es la variante más suave: retiene el trabajo que se está imprimiendo para que se reinicie limpiamente en lugar de perderse.)

### Bloque 6

**A6.1** — `-H hold` lo retiene (`-H resume` lo libera); `-i <job-id>` selecciona el trabajo existente a modificar. Entonces: `lp -i labps-42 -H hold`. Sin `-i`, `lp -H hold file` envía un trabajo *nuevo* en estado retenido.

**A6.2** — `no-hold` (imprimir de inmediato), `indefinite` (retener hasta liberación explícita), `day-time`, `evening`, `night`, `weekend`, `second-shift`, `third-shift`. Un `HH:MM` (o `HH:MM:SS`) pelado se interpreta en **UTC/GMT**, no en hora local — una sorpresa operativa muy común al programar lotes nocturnos.

**A6.3** — De `1` (la más baja) a `100` (la más alta); el valor por defecto es `50`. Subir la prioridad de un trabajo que **ya se está imprimiendo** no tiene efecto sobre ese trabajo — la prioridad solo ordena los trabajos *pendientes* en la cola. Para saltear la fila tenés que retener el trabajo actual o subir la prioridad del pendiente antes de que el dispositivo lo tome.

**A6.4**
```bash
sudo cupsdisable -r "Hardware failure — jobs moved to hp-2f" hp-2e
sudo lpmove hp-2e hp-2f
```
Deshabilitá primero: si movés trabajos mientras `hp-2e` sigue habilitada, el scheduler puede entregarle otro al dispositivo muerto mientras trabajás. Considerá también `cupsreject hp-2e` para que no llegue nada nuevo.

**A6.5** — Por la forma del argumento. Un número pelado o `queue-NNN` es un **trabajo**, y el comando mueve ese único trabajo. Un nombre de destino es una **cola**, y el comando mueve *todos* los trabajos pendientes de esa cola al destino. Por esto ponerle a una impresora un nombre numérico es mala idea.

### Bloque 7

**A7.1** — Una clase es un conjunto nombrado de impresoras que actúa como un único destino; CUPS enruta cada trabajo al primer miembro disponible. Te da **distribución de carga y failover automático** entre dispositivos físicamente distintos — si un miembro está deshabilitado u ocupado, el siguiente toma el trabajo — algo que una única cola apuntada a un solo dispositivo no puede ofrecer. Se respetan los estados de los miembros implícitos, así que el mantenimiento de una impresora es invisible para los usuarios. Las clases pueden incluso contener otras clases.

**A7.2** — CUPS **borra la clase automáticamente** cuando se quita su último miembro. Las clases no tienen existencia independiente; están definidas por completo por su membresía en `classes.conf`.

**A7.3**
- `lpadmin -d <dest>` — valor por defecto **de todo el servidor**, afecta a todos los que no tengan otra preferencia; lo guarda `cupsd` en `printers.conf`/`classes.conf` y lo informa `lpstat -d`.
- `lpoptions -d <dest>` como usuario — **solo ese usuario**; se guarda en `~/.cups/lpoptions`.
- `LPDEST` — **solo ese shell/proceso**, y anula el valor por defecto de `lpoptions`.

Solo el primero afecta a otros usuarios.

**A7.4** — Como root, `lpoptions` escribe `/etc/cups/lpoptions` (valores por defecto de cliente para todos los usuarios de esa máquina). Como usuario sin privilegios escribe `~/.cups/lpoptions`. El archivo del sistema sobrevive al borrado de cualquier directorio home; el archivo por usuario no. Notá que ambos son valores por defecto de opciones *del lado del cliente*, distintos de `lpadmin -o`, que guarda el valor por defecto en el **servidor** en `printers.conf` y por lo tanto aplica también a clientes remotos.

**A7.5** — Porque el valor por defecto se resuelve por usuario y por entorno: tu colega puede tener su propio valor por defecto en `~/.cups/lpoptions`, o `LPDEST`/`PRINTER` exportadas en el perfil de su shell, y cualquiera de las dos supera al valor por defecto del servidor que fijó `lpadmin -d`. Revisá los archivos que fija `lpoptions -d` y `env | grep -E 'LPDEST|PRINTER'` en su sesión.

### Bloque 8

**A8.1** — El **page log**, `/var/log/cups/page_log` (ruta fijada por `PageLog` en `cups-files.conf`). Las cuotas se calculan contando las entradas ahí para ese usuario/impresora dentro de `job-quota-period`. Si `PageLog` está desactivado o redirigido de una forma que CUPS no puede volver a leer, `job-page-limit` y `job-k-limit` dejan silenciosamente de aplicarse.

**A8.2** — `lpadmin -u allow:…` / `deny:…` fija los atributos IPP `requesting-user-name-allowed` / `-denied` en el destino: la conexión tiene éxito, el trabajo se *envía*, y el **scheduler lo rechaza** basándose en el nombre de usuario solicitante. Un bloque `<Location>` con `Require user …` (o `AuthType`) trabaja una capa más abajo, a nivel de la **petición HTTP/IPP**, y puede exigir autenticación real — la petición se rechaza con `401`/`403` antes de considerar la semántica del trabajo. Regla práctica: `-u` expresa política sobre identidades que CUPS simplemente *cree*; `<Location>` + `AuthType` es donde las identidades se *prueban*.

**A8.3** — (1) La membresía de grupo del usuario no ha tomado efecto en su sesión actual — los cambios de grupo se aplican en el siguiente login (`id` lo mostrará solo después de volver a iniciar sesión; verificalo con `id <user>` frente a `id` en su shell). (2) El bloque `<Location /admin>` sigue restringiendo por dirección (solo `Allow localhost`), así que un navegador remoto es rechazado independientemente del grupo, o el `Require user @SYSTEM` de la `<Policy>` requiere un tipo de autenticación que el cliente no está ofreciendo. Revisá también que `SystemGroup` nombre un grupo que realmente exista en este host (`getent group lpadmin`) y que la interfaz web esté habilitada (`WebInterface Yes`).

**A8.4** — `MaxJobs 0` significa trabajos encolados **ilimitados** (sin tope para todo el scheduler). `MaxJobs 1` significa que el scheduler retiene como máximo un trabajo en total — cuando llega uno nuevo, el completado más viejo se descarta para hacer lugar. `0` como "sin límite" es una convención recurrente en CUPS (`MaxLogSize 0` desactiva la rotación, `JobRetryLimit 0` significa reintentar para siempre).

### Bloque 9

**A9.1** — `c00042` es el **archivo de control**: el conjunto de atributos IPP del trabajo en codificación IPP binaria (nombre del trabajo, dueño, host de origen, prioridad, copias, opciones solicitadas, timestamps, URI de destino). `d00042-001` es el **archivo de datos**: los bytes reales del documento 1 tal como fue enviado. Por defecto `PreserveJobFiles` está desactivado o es de corta vida, así que el **archivo de datos se elimina en cuanto el trabajo se completa**, mientras `PreserveJobHistory` conserva el archivo de control (para que `lpstat -W completed` siga funcionando) hasta que expire o ejecutes `cancel -x`.

**A9.2** — `0710` = el dueño (root) tiene acceso total; el grupo (`lp`) tiene **solo ejecución/búsqueda, sin lectura**; los demás nada. Los miembros del grupo pueden por lo tanto hacer `open()` de un archivo de spool *cuyo nombre exacto ya conocen* (que es cómo lo alcanzan los propios helpers de CUPS) pero no pueden hacer `ls` del directorio para enumerar los trabajos de otros usuarios. Con `0755`, cualquier usuario local podría listar — y con archivos legibles, leer — el contenido de los trabajos de impresión de todo el mundo: recibos de sueldo, contratos, historias clínicas. El modo es un control de confidencialidad deliberado.

**A9.3** — `/var/log/cups/page_log`. Los campos son `printer user job-id [timestamp] page-number num-copies job-billing hostname job-name media sides`. Total de páginas de un trabajo = suma sobre sus líneas de (entradas de page-number) × `num-copies`; en la práctica se cuentan las líneas por trabajo y se multiplican por las copias, o se usa la forma `total N` que emiten algunos drivers. Agrupá por el campo 2 (usuario) y el campo 1 (impresora), filtrando por el timestamp del campo 4.

**A9.4** — `access_log` registra cada petición IPP con la dirección del cliente en el primer campo y el nombre de la operación (`Print-Job`) más el estado IPP cerca del final; `page_log` registra el campo de **hostname** de origen para cada página impresa junto con el usuario y el timestamp. Ambos sobreviven al trabajo en sí, mientras el archivo de control del spool no. `page_log` es el registro más fuerte para "este host imprimió este documento a esta hora".

**A9.5** — `sudo cupsctl --no-debug-logging`. `cupsctl` envía una petición administrativa al estilo `CUPS-Set-Default` por IPP; `cupsd` reescribe `cupsd.conf` y realiza una **recarga interna**, no un reinicio del proceso, así que los trabajos abiertos y el documento que se está imprimiendo no se ven afectados. Complementalo con `MaxLogSize` (por ejemplo `MaxLogSize 10m`) o logrotate para acotar el crecimiento de forma estructural.

### Bloque 10

**A10.1** — Para una impresora de oficina compartida, `stop-printer` es lo correcto: la falla suele ser transitoria y física (sin papel, cable desconectado, apagada). Conservar el trabajo y detener la cola significa que el documento del usuario se imprime intacto en cuanto alguien arregla el dispositivo, y el estado ruidoso de "impresora detenida" es lo que provoca el arreglo. En un servidor de lotes desatendido el mismo comportamiento es una caída autoinfligida: un trabajo malo detiene miles de buenos y nadie está mirando la consola. Ahí, o reintentás o descartás:
```bash
sudo lpadmin -p batchq -o printer-error-policy=retry-job
```
(ajustá `JobRetryInterval`/`JobRetryLimit` en `cupsd.conf`), o `-o printer-error-policy=abort-job` si la cola nunca debe atascarse y perder un trabajo es aceptable.

**A10.2**
```bash
lpstat -r                       # 1. is the scheduler even running?
lpstat -t                       # 2. overview: default, devices, accepting, enabled
lpstat -p -l <queue>            # 3. queue state + printer-state-message/reasons
lpstat -o <queue> -l            # 4. is the job queued, held, or gone?
lpstat -W completed -o <queue>  #    ...or already "completed" (=> problem is past CUPS)
sudo tail -50 /var/log/cups/error_log        # 5. filter/backend errors + exit status
sudo cupsctl --debug-logging                 #    reproduce, then grep "[Job N]"
cupsfilter -m application/vnd.cups-raster f  # 6. filter chain in isolation
nc -vz <printer-ip> 9100                     # 7. transport/device reachability
```
Después revertí: `cupsctl --no-debug-logging`.

**A10.3** — La impresora recibió PostScript que no puede interpretar — no es un dispositivo PostScript, o los datos saltearon la conversión. Revisá primero: (a) ¿la cola es **raw** (sin PPD en `/etc/cups/ppd/<queue>.ppd`, `lpstat -l -p` no muestra driver)? (b) ¿el **PPD asignado es el driver equivocado** para el modelo (un PPD PostScript genérico puesto en una impresora que solo entiende PCL)? Arreglalo asignando el driver correcto con `-m`/`-P`, o `-m everywhere` para un dispositivo IPP Everywhere. Una causa secundaria es enviar con `lpr -l`/`-o raw`, que suprime el filtrado explícitamente.

**A10.4** — `cupsfilter` ejecuta la misma cadena de filtros que ejecutaría `cupsd`, **fuera del scheduler**, en la línea de comandos, mostrándote directamente el stderr del filtro y dejándote inspeccionar la salida producida. Eso separa limpiamente "la cadena de driver/filtros está rota o falta" de "el dispositivo o el backend es inalcanzable" — una distinción que un trabajo de prueba no puede hacer, porque desde el punto de vista del usuario las dos fallan igual. `--list-filters` además imprime la cadena que *se usaría* sin ejecutarla.

**A10.5** — El dispositivo o su ruta de datos, no CUPS: CUPS aceptó el trabajo, lo filtró, el backend informó éxito y se retiró al historial. Mirá (a) el URI del backend/dispositivo — un URI `file:` o una IP equivocada "tienen éxito" silenciosamente; (b) la impresora física (offline, bandeja equivocada, otra cola sobre el mismo dispositivo); (c) `page_log` para confirmar que CUPS cree que se produjeron páginas; (d) la propia página web/panel de la impresora para ver su registro de trabajos. Confirmá primero con `lpstat -v <queue>` — una cola apuntada al dispositivo equivocado es la causa más común de todas.

### Bloque 11

**A11.1**
| Protocolo | Transporte | Puerto |
|---|---|---|
| IPP | HTTP sobre TCP | **631** |
| IPPS | HTTPS sobre TCP | **631** (TLS; `ipps://`) |
| LPD (RFC 1179) | TCP | **515** |
| Raw / AppSocket / JetDirect | TCP | **9100** (también 9101/9102 en dispositivos multipuerto) |
| Descubrimiento mDNS / DNS-SD | UDP | **5353** |
| Impresión SMB | TCP | 445 (139 heredado) |

**A11.2** — `Port 631` es la forma abreviada de escuchar en **todas** las direcciones (IPv4 e IPv6) en el puerto 631. `Listen 631` es equivalente en efecto pero usa la sintaxis que admite direcciones. `Listen localhost:631` restringe a la interfaz de loopback — el valor por defecto en las distribuciones modernas, lo que significa que el servidor es inalcanzable desde la red hasta que lo cambies. `Listen /run/cups/cups.sock` agrega el socket de dominio UNIX. Combiná líneas `Listen` explícitas en lugar de `Port` cuando querés control por interfaz.

**A11.3** — `cupsd` **comparte**: anuncia sus propias colas compartidas vía DNS-SD y responde peticiones IPP sobre ellas. `cups-browsed` **consume**: es un demonio aparte que escucha anuncios (DNS-SD, y el browsing heredado de CUPS) y **crea colas locales** en el cliente automáticamente para las impresoras remotas que descubre, quitándolas cuando el anuncio cesa. Así que el lado servidor necesita `Browsing`/`printer-is-shared`; el lado cliente necesita `cups-browsed` (o una cola `ipp://` creada a mano). Desde CUPS 1.6, `cupsd` ya no implementa él mismo el viejo protocolo de browsing por broadcast — ese trabajo pasó a `cups-browsed` en cups-filters.

**A11.4** — **Lo escribe `cupsd`**, en la ruta que da la directiva `Printcap` en `cups-files.conf` (típicamente `/etc/printcap`), regenerándolo cada vez que cambian las colas. Existe puramente como capa de compatibilidad: las aplicaciones más viejas parsean `/etc/printcap` para armar sus menús de impresoras. Editarlo a mano no logra nada — el archivo se sobrescribe en el siguiente cambio de cola o reinicio del scheduler, y CUPS nunca lo vuelve a leer. Para cambiar lo que aparece ahí, cambiá las colas con `lpadmin`.

**A11.5** — El mini-demonio `cups-lpd`, que habla RFC 1179 y traduce a IPP. Se activa por socket, no es un servicio autónomo: habilitá `cups-lpd.socket` (systemd) o la entrada `cups-lpd` bajo xinetd, y abrí **TCP 515** en el firewall. Como RFC 1179 no tiene autenticación y transmite en claro, restringilo por dirección de origen en el firewall y tratalo como un puente heredado, no como un servicio general.

**A11.6** — `lp -h server -d q file` usa el servidor remoto **directamente, por invocación**: no se configura nada localmente, no existe cola local, y si el servidor está caído el comando simplemente falla. Sirve para uso ad-hoc y scripts en hosts que no querés configurar. Una cola local con `ipp://server/printers/q` convierte a la impresora en un **destino local de primera clase**: aparece en `lpstat -a` y en toda GUI, puede ser el valor por defecto, puede llevar opciones locales y un driver local, y puede encolar trabajos localmente cuando el servidor está brevemente no disponible. Usá la cola local para todo aquello con lo que interactúan los usuarios; usá `-h` para automatización y resolución de problemas.

### Bloque 12

**A12.1** — (1) `/etc/cups/printers.conf` — la estrofa `<Printer …>` ya no está (reescrito por `cupsd`). (2) `/etc/cups/ppd/<queue>.ppd` — borrado. (3) `/etc/printcap` — regenerado sin la cola. También: `/etc/cups/classes.conf` si la cola era miembro de una clase (y la clase misma desaparece si era el último miembro), el spool bajo `/var/spool/cups` para los trabajos de esa cola (cancelados), y `/etc/cups/lpoptions` / `~/.cups/lpoptions` pueden retener entradas ahora colgadas para ella.

**A12.2** — Con `FileDevice Yes`, cualquier usuario autorizado a crear o modificar una cola puede fijar un URI de dispositivo como `file:/etc/shadow` o `file:/etc/cron.d/anything`, y el backend `file` de CUPS — que corre con privilegios de root — escribirá ahí datos de trabajo controlados por el atacante. Eso convierte "puede administrar impresoras" en "puede escribir archivos arbitrarios propiedad de root", es decir, escalada total de privilegios locales. El valor por defecto es `No` exactamente por esta razón; habilitalo solo en una máquina aislada y volvé a apagarlo, como en este paso.

</details>