# LPIC-1 — Tema 107.2: Automatizar tareas de administración del sistema mediante la programación de trabajos
## Ejercicios guiados

**Examen:** 102-500 (LPIC-1 v5.0), Tema 107
**Lista oficial de objetivos:** <https://www.lpi.org/our-certifications/exam-102-objectives/> (conjunto de objetivos complementario para el examen 101: <https://www.lpi.org/our-certifications/exam-101-objectives/>)

**Archivos, términos y utilidades clave que se ejercitan acá:** `/etc/cron.{d,daily,hourly,monthly,weekly}`, `/etc/at.deny`, `/etc/at.allow`, `/etc/crontab`, `/etc/cron.allow`, `/etc/cron.deny`, `/var/spool/cron/`, `crontab`, `at`, `atq`, `atrm`, `systemctl`, `systemd-run`.

---

### Entorno de laboratorio

Estos ejercicios **escriben en archivos del sistema y programan trabajos reales**. Usá una VM o contenedor descartable con systemd (Debian 12 / Ubuntu 22.04+ / Rocky 9 / openSUSE Leap funcionan todos). Necesitás `root` (vía `sudo`) y un usuario sin privilegios.

Las diferencias entre distribuciones se señalan sobre la marcha. Donde el texto dice `cron`, los sistemas de la familia RHEL usan el nombre de servicio `crond` y la implementación `cronie`; los sistemas de la familia Debian usan el servicio `cron` y el `cron` derivado de Vixie. Ambos implementan la misma sintaxis de crontab.

**Paso 0 — preparar el entorno. Ejecutá esto antes del Ejercicio 1:**

```bash
# Identify the implementation and service name
if systemctl list-unit-files | grep -qE '^crond\.service'; then CRON=crond; else CRON=cron; fi
echo "Cron unit on this host: $CRON"

# Install what the lab needs (pick your family)
sudo apt-get update && sudo apt-get install -y cron at anacron util-linux   # Debian/Ubuntu
sudo dnf install -y cronie cronie-anacron at util-linux                      # RHEL/Rocky/Alma/Fedora

sudo systemctl enable --now "$CRON" atd
systemctl is-active "$CRON" atd

# Create the lab user used from Exercise 6 onward
sudo useradd -m -s /bin/bash lpicstudent 2>/dev/null || true

# A scratch directory for job output
sudo install -d -m 0777 /srv/lab107
```

Esperado:

```
Cron unit on this host: cron
active
active
```

---

## Ejercicio 1 — El crontab de usuario: dónde vive y quién es su dueño

**Pasos**

1. Mostrá el crontab de tu usuario actual. En una cuenta nueva todavía no existe:

   ```bash
   crontab -l
   ```

   ```
   no crontab for dalmine
   ```

2. Definí un editor no interactivo y creá un crontab. Usar `crontab -e` (y no un editor sobre el archivo del spool directamente) es la única vía soportada:

   ```bash
   export EDITOR=nano   # or: export EDITOR=vim
   crontab -e
   ```

   Ingresá exactamente este contenido, después guardá y salí:

   ```crontab
   # Lab 107.2 — user crontab
   * * * * * date +\%FT\%T >> /srv/lab107/every-minute.log 2>&1
   ```

3. Confirmá el mensaje de instalación y volvé a leer el crontab:

   ```bash
   crontab -l
   ```

   ```
   # Lab 107.2 — user crontab
   * * * * * date +\%FT\%T >> /srv/lab107/every-minute.log 2>&1
   ```

4. Encontrá el archivo del spool en disco e inspeccioná sus metadatos. **No lo edites.**

   ```bash
   sudo ls -l /var/spool/cron/crontabs/"$USER"    # Debian/Ubuntu
   sudo ls -l /var/spool/cron/"$USER"             # RHEL/Rocky/Fedora
   ```

   Debian:

   ```
   -rw------- 1 dalmine crontab 226 Aug 27 18:41 /var/spool/cron/crontabs/dalmine
   ```

5. Esperá ~90 segundos y después verificá que el trabajo se haya disparado realmente:

   ```bash
   sleep 90; cat /srv/lab107/every-minute.log
   ```

   ```
   2026-08-27T18:42:01
   2026-08-27T18:43:01
   ```

**Preguntas de control — bloque A**

1. `crontab -e` no abrió `/var/spool/cron/crontabs/dalmine` directamente; abrió una copia temporal. Nombrá **dos** cosas que hace `crontab` al guardar y que editar a mano el archivo del spool se saltearía.
2. El archivo del spool tiene modo `0600`, pertenece al usuario y al grupo `crontab` (Debian). ¿Por qué el comando `crontab` se instala con setgid en lugar de hacer que el directorio del spool sea escribible por todos?
3. ¿Qué variable de entorno consulta `crontab -e` **primero**, antes de `EDITOR`?

**Pasos (continuación)**

6. Respaldá el crontab en un archivo común — este es el único patrón seguro:

   ```bash
   crontab -l > ~/crontab.bak
   wc -l ~/crontab.bak
   ```

   ```
   2 /home/dalmine/crontab.bak
   ```

7. Mirá el **par peligroso** en tu teclado. Ejecutá `crontab -r` y después restaurá:

   ```bash
   crontab -r
   crontab -l
   crontab ~/crontab.bak
   crontab -l | head -1
   ```

   ```
   no crontab for dalmine
   # Lab 107.2 — user crontab
   ```

8. Inspeccioná el crontab de otro usuario como root:

   ```bash
   sudo crontab -u lpicstudent -l
   ```

   ```
   no crontab for lpicstudent
   ```

**Preguntas de control — bloque B**

4. `crontab -r` y `crontab -e` están a una tecla de distancia y `-r` no pide confirmación. ¿Qué opción hace que la eliminación sea interactiva?
5. ¿Qué le hace `crontab ~/crontab.bak` a un crontab **existente** — agrega al final o reemplaza?
6. Escribí el comando que usa root para instalar `/root/jobs.cron` como el crontab del usuario `backup`.

---

## Ejercicio 2 — Semántica de los campos, valores de paso y la trampa día-del-mes / día-de-la-semana

**Pasos**

1. Volvé a abrir tu crontab y reemplazá su contenido por estas entradas. Leé cada comentario antes de guardar:

   ```crontab
   # min hour dom mon dow  command
   #  Every 5 minutes, all day
   */5 * * * *        echo "five" >> /srv/lab107/fields.log

   #  09:00 and 17:00, Monday to Friday
   0 9,17 * * 1-5     echo "office" >> /srv/lab107/fields.log

   #  Every 10 minutes between 22:00 and 23:59
   */10 22-23 * * *   echo "night" >> /srv/lab107/fields.log

   #  Every 2 hours on the half hour
   30 */2 * * *       echo "even-hours" >> /srv/lab107/fields.log

   #  THE TRAP: day-of-month AND day-of-week both restricted
   0 3 13 * 5         echo "trap" >> /srv/lab107/fields.log

   #  Special string form
   @reboot            echo "booted $(date)" >> /srv/lab107/boot.log
   ```

2. Verificá los rangos que acepta cada campo enviando deliberadamente uno inválido:

   ```bash
   echo '0 25 * * * /bin/true' | crontab -
   ```

   ```
   "-":1: bad hour
   errors in crontab file, can't install.
   ```

   El crontab anterior sobrevive — la instalación es atómica.

3. Probá si los nombres pueden combinarse con rangos (esto depende de la implementación y es un detalle preferido en el examen):

   ```bash
   crontab -l > /tmp/keep.cron
   echo '0 4 * * mon-fri /bin/true' | crontab -
   crontab -l | tail -1
   crontab /tmp/keep.cron
   ```

   En el cron Vixie de Debian y en cronie esto se acepta en versiones recientes; el `crontab(5)` histórico de Vixie establece que los rangos y listas de *nombres* no están permitidos. Los crontabs portables usan números.

**Preguntas de control — bloque C**

7. Dá el rango numérico de cada uno de los cinco campos de tiempo, en orden. ¿Qué valor único aparece **dos veces** con dos significados, y cuáles son?
8. La entrada `0 3 13 * 5` — ¿en qué días se ejecuta: solo el viernes 13, o todos los días 13 **y** todos los viernes? Enunciá la regla que lo decide.
9. Reescribí `0 3 13 * 5` para que se ejecute **solo** el viernes 13, usando un test de shell en el campo del comando.
10. Traducí a sintaxis de crontab: *"cada 15 minutos durante la primera hora del primer mes de cada trimestre"* — es decir, los minutos 0,15,30,45 de la hora 0 del día 1 de enero, abril, julio y octubre.
11. ¿Qué cadena especial equivale a `0 0 * * 0`? ¿Cuál no tiene ningún equivalente en campos de tiempo, y por qué?

---

## Ejercicio 3 — El entorno de ejecución de cron: la causa número uno del "en mi shell funciona"

**Pasos**

1. Capturá el entorno exacto que cron le da a un trabajo:

   ```bash
   ( crontab -l; echo '* * * * * { env; echo "---"; id; } > /srv/lab107/cronenv.txt 2>&1' ) | crontab -
   sleep 70
   cat /srv/lab107/cronenv.txt
   ```

   ```
   SHELL=/bin/sh
   PWD=/home/dalmine
   LOGNAME=dalmine
   HOME=/home/dalmine
   PATH=/usr/bin:/bin
   ---
   uid=1000(dalmine) gid=1000(dalmine) groups=1000(dalmine)
   ```

2. Compará con tu shell interactiva:

   ```bash
   echo "$PATH"; echo "$SHELL"
   ```

   ```
   /home/dalmine/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
   /bin/bash
   ```

3. Demostrá el modo de fallo. Creá un script en un directorio que **no** esté en el `PATH` de cron:

   ```bash
   mkdir -p ~/bin
   printf '#!/bin/sh\necho "ran at $(date)" >> /srv/lab107/mybin.log\n' > ~/bin/labjob
   chmod +x ~/bin/labjob
   labjob && echo "works interactively"
   ( crontab -l; echo '* * * * * labjob' ) | crontab -
   sleep 70
   cat /srv/lab107/mybin.log
   ```

   ```
   works interactively
   ran at Thu Aug 27 18:55:01 -03 2026     <- only the interactive run
   ```

4. Leé el fallo en el log:

   ```bash
   journalctl -t CRON --since "-3 min" | tail -5        # Debian
   journalctl -t CROND --since "-3 min" | tail -5       # RHEL
   ```

   ```
   Aug 27 18:56:01 lab CRON[4412]: (dalmine) CMD (labjob)
   Aug 27 18:56:01 lab CRON[4411]: (dalmine) MAIL (mailed 1 byte of output; but got status 0x004b...)
   ```

5. Arreglalo de tres maneras distintas. Reemplazá el crontab por:

   ```crontab
   SHELL=/bin/bash
   PATH=/usr/local/bin:/usr/bin:/bin:/home/dalmine/bin
   MAILTO=""

   # 1. PATH set above
   * * * * * labjob
   # 2. Absolute path — always correct, needs no variable
   * * * * * /home/dalmine/bin/labjob
   # 3. Explicit login shell if the job genuinely needs your profile
   * * * * * /bin/bash -lc 'labjob'
   ```

6. Demostrá el signo de porcentaje. Instalá esto y observá el resultado:

   ```bash
   ( crontab -l; echo '* * * * * date +%F > /srv/lab107/pct.log' ) | crontab -
   sleep 70; cat /srv/lab107/pct.log
   ```

   ```
   (empty file)
   ```

   Ahora escapalo:

   ```bash
   crontab -l | sed 's|date +%F|date +\\%F|' | crontab -
   sleep 70; cat /srv/lab107/pct.log
   ```

   ```
   2026-08-27
   ```

**Preguntas de control — bloque D**

12. Cron define solo un puñado de variables. ¿Cuáles cuatro define para un trabajo de usuario, y cuál de ellas proviene de `/etc/passwd`?
13. Tu trabajo ejecuta `mysqldump` y falla con `command not found`, pero funciona cuando lo escribís vos. Dá dos arreglos y decí cuál pondrías en un crontab de producción y por qué.
14. Explicá con precisión qué le hizo cron a `date +%F > /srv/lab107/pct.log`. ¿Cuál es la regla general para `%` en el campo del comando, y cómo se obtiene uno literal?
15. `MAILTO=""` frente a omitir `MAILTO` por completo frente a `MAILTO=ops@example.com` — describí el comportamiento de cada caso, y decí qué pasa con la salida del trabajo en un host sin MTA instalado.
16. Una asignación de variable en el crontab ubicada *después* de una entrada — ¿afecta a esa entrada? ¿Dónde debe aparecer `PATH=`?

---

## Ejercicio 4 — Crontabs del sistema: `/etc/crontab`, `/etc/cron.d` y los directorios de `run-parts`

**Pasos**

1. Leé el crontab del sistema y fijate en la columna extra:

   ```bash
   cat /etc/crontab
   ```

   Debian:

   ```
   SHELL=/bin/sh
   PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

   17 *    * * *   root    cd / && run-parts --report /etc/cron.hourly
   25 6    * * *   root    test -x /usr/sbin/anacron || { cd / && run-parts --report /etc/cron.daily; }
   47 6    * * 7   root    test -x /usr/sbin/anacron || { cd / && run-parts --report /etc/cron.weekly; }
   52 6    1 * *   root    test -x /usr/sbin/anacron || { cd / && run-parts --report /etc/cron.monthly; }
   ```

2. Creá un archivo drop-in en `/etc/cron.d` — el lugar correcto para trabajos gestionados por paquetes y por configuración:

   ```bash
   sudo tee /etc/cron.d/lab107-report >/dev/null <<'EOF'
   # Lab 107.2 — system drop-in; note the user field in position 6
   SHELL=/bin/bash
   PATH=/usr/local/bin:/usr/bin:/bin
   MAILTO=root

   */2 * * * *   lpicstudent   id -un >> /srv/lab107/dropin.log 2>&1
   EOF
   sudo chmod 0644 /etc/cron.d/lab107-report
   sleep 130
   cat /srv/lab107/dropin.log
   ```

   ```
   lpicstudent
   ```

3. Ahora rompelo a propósito, tal como lo rompen los despliegues reales:

   ```bash
   sudo mv /etc/cron.d/lab107-report /etc/cron.d/lab107-report.conf
   sudo truncate -s 0 /srv/lab107/dropin.log
   sleep 130
   cat /srv/lab107/dropin.log
   ```

   ```
   (empty)
   ```

   Restaurá:

   ```bash
   sudo mv /etc/cron.d/lab107-report.conf /etc/cron.d/lab107-report
   ```

4. Agregá un script a `run-parts` y observá la segunda regla de nombres:

   ```bash
   sudo tee /etc/cron.hourly/lab107-hourly.sh >/dev/null <<'EOF'
   #!/bin/sh
   echo "hourly $(date -Is)" >> /srv/lab107/hourly.log
   EOF
   sudo chmod +x /etc/cron.hourly/lab107-hourly.sh
   run-parts --test /etc/cron.hourly
   ```

   ```
   /etc/cron.hourly/0anacron
   /etc/cron.hourly/logrotate
   ```

   Tu script no aparece. Renombralo y volvé a probar:

   ```bash
   sudo mv /etc/cron.hourly/lab107-hourly.sh /etc/cron.hourly/lab107-hourly
   run-parts --test /etc/cron.hourly
   ```

   ```
   /etc/cron.hourly/0anacron
   /etc/cron.hourly/lab107-hourly
   /etc/cron.hourly/logrotate
   ```

5. Confirmá el requisito del bit de ejecución:

   ```bash
   sudo chmod -x /etc/cron.hourly/lab107-hourly
   run-parts --test /etc/cron.hourly | grep lab107 || echo "skipped: not executable"
   sudo chmod +x /etc/cron.hourly/lab107-hourly
   ```

   ```
   skipped: not executable
   ```

**Preguntas de control — bloque E**

17. Enunciá la única diferencia estructural entre una línea de `/etc/crontab` y una línea de un crontab de usuario, y explicá por qué existe esa diferencia.
18. Tu `/etc/cron.d/lab107-report.conf` nunca se ejecutó. Dá la regla sobre los nombres de archivo en `/etc/cron.d`, y dá la regla *distinta pero relacionada* que `run-parts` aplica a `/etc/cron.daily`.
19. Además del nombre, enumerá otras dos condiciones que un archivo en `/etc/cron.hourly` debe cumplir para ser ejecutado.
20. Editaste `/etc/cron.d/lab107-report`. ¿Hace falta reiniciar o recargar el demonio cron? Justificá tu respuesta en términos de cómo detecta cron los cambios en (a) `/etc/cron.d`, (b) `/etc/crontab` y (c) los archivos del spool de usuario.
21. Un trabajo debe ejecutarse como `www-data` todas las noches. Compará ponerlo en `/etc/cron.d` frente a `crontab -u www-data -e` — dá una ventaja operativa de cada uno.

---

## Ejercicio 5 — `anacron`: trabajos que sobreviven a una máquina apagada

**Pasos**

1. Leé la configuración y notá que el formato **no** es formato crontab:

   ```bash
   cat /etc/anacrontab
   ```

   ```
   SHELL=/bin/sh
   PATH=/sbin:/bin:/usr/sbin:/usr/bin
   MAILTO=root
   RANDOM_DELAY=45
   START_HOURS_RANGE=3-22

   #period in days   delay in minutes   job-identifier   command
   1         5       cron.daily        nice run-parts /etc/cron.daily
   7         25      cron.weekly       nice run-parts /etc/cron.weekly
   @monthly  45      cron.monthly      nice run-parts /etc/cron.monthly
   ```

2. Inspeccioná el directorio de estado que hace funcionar a anacron:

   ```bash
   sudo ls -l /var/spool/anacron/
   sudo cat /var/spool/anacron/cron.daily
   ```

   ```
   -rw------- 1 root root 9 Aug 27 07:31 cron.daily
   -rw------- 1 root root 9 Aug 24 07:35 cron.weekly
   -rw------- 1 root root 9 Aug  1 07:12 cron.monthly
   20260827
   ```

3. Agregá tu propio trabajo de anacron y validá el archivo antes de confiar en él:

   ```bash
   sudo cp /etc/anacrontab /etc/anacrontab.bak
   echo -e '1\t10\tlab107.daily\t/bin/sh -c "echo anacron-ran $(date -Is) >> /srv/lab107/anacron.log"' \
     | sudo tee -a /etc/anacrontab >/dev/null
   sudo anacron -T && echo "anacrontab syntax OK"
   ```

   ```
   anacrontab syntax OK
   ```

4. Forzá la ejecución del trabajo ahora, ignorando tanto la marca de tiempo como el retardo:

   ```bash
   sudo anacron -d -f -n lab107.daily
   ```

   ```
   Anacron 2.3 started on 2026-08-27
   Will run job `lab107.daily' in 0 min.
   Jobs will be executed sequentially
   Job `lab107.daily' started
   Job `lab107.daily' terminated
   Normal exit (1 job run)
   ```

   ```bash
   cat /srv/lab107/anacron.log; sudo cat /var/spool/anacron/lab107.daily
   ```

   ```
   anacron-ran 2026-08-27T19:14:02-03:00
   20260827
   ```

5. Ejecutalo de nuevo inmediatamente y observá la idempotencia con granularidad diaria:

   ```bash
   sudo anacron -d lab107.daily
   ```

   ```
   Anacron 2.3 started on 2026-08-27
   Normal exit (0 jobs run)
   ```

6. Mirá cómo se dispara anacron en tu distribución:

   ```bash
   cat /etc/cron.hourly/0anacron 2>/dev/null | head -20
   systemctl list-timers anacron.timer 2>/dev/null
   ```

7. Limpiá:

   ```bash
   sudo cp /etc/anacrontab.bak /etc/anacrontab
   sudo rm -f /var/spool/anacron/lab107.daily
   ```

**Preguntas de control — bloque F**

22. Describí los cuatro campos de una línea de trabajo de `/etc/anacrontab`, en orden, incluyendo la unidad de los dos primeros.
23. Una laptop está apagada de 06:00 a 10:00 todos los días. La entrada `25 6 * * * root run-parts /etc/cron.daily` nunca se ejecuta. Explicá, mecánicamente, qué hace anacron de manera distinta — y nombrá el archivo exacto que consulta para decidir.
24. ¿Cuál es el período más chico que anacron puede expresar, y qué te dice eso sobre cuándo *no* usarlo?
25. ¿Qué controlan `RANDOM_DELAY` y `START_HOURS_RANGE`, y por qué a una flota de 500 VMs le importaría el primero?
26. En un sistema Debian estándar, ¿por qué `/etc/crontab` envuelve la llamada diaria a `run-parts` en `test -x /usr/sbin/anacron || { ...; }`?
27. ¿Qué opciones de anacron significan respectivamente: *probar el archivo de configuración*, *ejecutar ahora sin retardo*, *forzar sin importar la marca de tiempo* y *actualizar las marcas de tiempo sin ejecutar*?

---

## Ejercicio 6 — Control de acceso: `cron.allow` y `cron.deny`

**Pasos**

1. Establecé la línea base. En la mayoría de los sistemas no está ninguno de los dos archivos, o solo hay un `cron.deny` vacío:

   ```bash
   ls -l /etc/cron.allow /etc/cron.deny 2>&1
   ```

   Debian:

   ```
   ls: cannot access '/etc/cron.allow': No such file or directory
   ls: cannot access '/etc/cron.deny': No such file or directory
   ```

   RHEL:

   ```
   ls: cannot access '/etc/cron.allow': No such file or directory
   -rw-r--r-- 1 root root 0 Jun  9 12:44 /etc/cron.deny
   ```

2. Confirmá que el usuario del laboratorio puede programar actualmente:

   ```bash
   sudo -u lpicstudent bash -c 'echo "0 4 * * * /bin/true" | crontab -' && echo OK
   sudo -u lpicstudent crontab -l
   ```

   ```
   OK
   0 4 * * * /bin/true
   ```

3. Denegá a ese único usuario:

   ```bash
   echo lpicstudent | sudo tee -a /etc/cron.deny >/dev/null
   sudo -u lpicstudent crontab -l
   ```

   ```
   You (lpicstudent) are not allowed to use this program (crontab)
   See crontab(1) for more information
   ```

4. Ahora agregá una lista de permitidos y mirá cómo tiene precedencia:

   ```bash
   printf 'root\nlpicstudent\n' | sudo tee /etc/cron.allow >/dev/null
   sudo chmod 0600 /etc/cron.allow
   sudo -u lpicstudent crontab -l
   ```

   ```
   0 4 * * * /bin/true
   ```

   El usuario figura en **ambos** archivos y está permitido.

5. Probá un tercer usuario contra la lista de permitidos:

   ```bash
   sudo useradd -m thirduser 2>/dev/null
   sudo -u thirduser crontab -l
   ```

   ```
   You (thirduser) are not allowed to use this program (crontab)
   ```

6. Verificá que el control de acceso **no** se aplica a root:

   ```bash
   sudo crontab -l >/dev/null; echo "root exit status: $?"
   ```

7. Limpiá:

   ```bash
   sudo rm -f /etc/cron.allow
   sudo sed -i '/^lpicstudent$/d' /etc/cron.deny 2>/dev/null
   sudo -u lpicstudent crontab -r
   ```

**Preguntas de control — bloque G**

28. Enunciá el algoritmo de decisión que sigue `crontab(1)`, en orden, dada la posible presencia de `/etc/cron.allow` y `/etc/cron.deny`.
29. Ambos archivos existen y `alice` aparece en los dos. ¿Puede ejecutar `crontab -e`? ¿Por qué?
30. No existe ninguno de los dos archivos. ¿Es el mismo resultado en Debian y en RHEL? ¿Qué dice la página del manual sobre este caso?
31. Se elimina `/etc/cron.deny` de un host Debian que lo tenía. ¿El conjunto de usuarios que pueden programar trabajos crece, se reduce o queda igual?
32. ¿Agregar a `bob` a `/etc/cron.deny` detiene su crontab **ya instalado**? Explicá qué es lo que realmente controla ese archivo.
33. ¿Cuál es el par de archivos equivalente para el subsistema `at`, y se aplica la misma regla de precedencia?

---

## Ejercicio 7 — Programación de una sola vez con `at` y `batch`

**Pasos**

1. Confirmá que el demonio está corriendo — `at` sin `atd` acumula silenciosamente trabajos que nunca se disparan:

   ```bash
   systemctl is-active atd && ls -ld /var/spool/cron/atjobs 2>/dev/null || ls -ld /var/spool/at
   ```

2. Encolá un trabajo con un here-doc y leé la confirmación con atención:

   ```bash
   at now + 2 minutes <<'EOF'
   echo "at job ran at $(date -Is)" >> /srv/lab107/at.log
   EOF
   ```

   ```
   warning: commands will be executed using /bin/sh
   job 3 at Thu Aug 27 19:31:00 2026
   ```

3. Listá, inspeccioná y entendé qué guardó realmente `at`:

   ```bash
   atq
   at -c 3 | head -5
   at -c 3 | tail -5
   ```

   ```
   3	Thu Aug 27 19:31:00 2026 a dalmine
   ```

   ```
   #!/bin/sh
   # atrun uid=1000 gid=1000
   # mail dalmine 0
   umask 0022
   XDG_SESSION_ID=41; export XDG_SESSION_ID
   ...
   cd /home/dalmine || {
   	 echo 'Execution directory inaccessible' >&2
   	 exit 1
   }
   echo "at job ran at 2026-08-27T19:29:14-03:00" >> /srv/lab107/at.log
   ```

4. Encolá varios trabajos usando los distintos formatos de tiempo, y después eliminá uno:

   ```bash
   at teatime      <<< 'echo tea   >> /srv/lab107/at.log'
   at midnight     <<< 'echo mid   >> /srv/lab107/at.log'
   at 09:00 tomorrow <<< 'echo tmrw >> /srv/lab107/at.log'
   at 2026-12-24 18:30 <<< 'echo xmas >> /srv/lab107/at.log'
   atq
   ```

   ```
   4	Thu Aug 27 16:00:00 2026 a dalmine
   5	Fri Aug 28 00:00:00 2026 a dalmine
   6	Fri Aug 28 09:00:00 2026 a dalmine
   7	Thu Dec 24 18:30:00 2026 a dalmine
   ```

   ```bash
   atrm 4
   atq | wc -l
   ```

5. Usá `batch` y compará la letra de cola:

   ```bash
   batch <<< 'echo "batch ran $(date -Is)" >> /srv/lab107/at.log'
   atq
   ```

   ```
   warning: commands will be executed using /bin/sh
   job 8 at Thu Aug 27 19:30:00 2026
   8	Thu Aug 27 19:30:00 2026 b dalmine
   ```

6. Verificá el modelo de entrega de salida de `at`:

   ```bash
   at now + 1 minute <<< 'echo "this goes to mail, not to a terminal"'
   sleep 70
   journalctl -u atd --since "-3 min" | tail -3
   ```

7. Limpiá los trabajos restantes:

   ```bash
   atq | awk '{print $1}' | xargs -r atrm
   atq
   ```

**Preguntas de control — bloque H**

34. `at` imprimió *"warning: commands will be executed using /bin/sh"*. ¿Qué shell va a ejecutar realmente tu trabajo, y dónde registra `at` el entorno que va a restaurar?
35. Nombrá los tres comandos que listan, eliminan y releen un trabajo de `at`, y dá las opciones equivalentes de `at` para los dos primeros.
36. ¿Cuál es la diferencia funcional entre `at now` y `batch`? Nombrá la condición que espera `batch` y la letra de cola que usa.
37. Tu trabajo de `at` produjo salida pero nunca la viste. ¿A dónde fue? ¿Qué opción de `at` fuerza el envío de correo incluso cuando no hay salida?
38. Convertí a sintaxis de tiempo de `at`: *17:45 de hoy*, *dentro de cuatro horas*, *el próximo día 3 del mes a las 02:00*.
39. `atd` estuvo detenido durante seis horas; en ese lapso vencieron tres trabajos de `at`. ¿Qué pasa cuando `atd` vuelve a arrancar — se pierden, se ejecutan de inmediato o se reprograman?
40. Enunciá en una línea la diferencia de propósito entre `cron` y `at` que decide cuál elegís.

---

## Ejercicio 8 — Temporizadores de systemd: el equivalente moderno

**Pasos**

1. Mirá lo que ya existe en el host:

   ```bash
   systemctl list-timers --all | head -8
   ```

   ```
   NEXT                        LEFT     LAST                        PASSED  UNIT                   ACTIVATES
   Thu 2026-08-27 20:00:00 -03 22min    Thu 2026-08-27 19:00:12 -03 37min   anacron.timer          anacron.service
   Fri 2026-08-28 00:00:00 -03 4h 22min Thu 2026-08-27 00:00:11 -03 19h ago logrotate.timer        logrotate.service
   Fri 2026-08-28 06:12:41 -03 10h      Thu 2026-08-27 06:11:03 -03 13h ago man-db.timer           man-db.service
   ```

2. Construí un par temporizador + servicio. **Se requieren ambas unidades**; el temporizador solo activa otra cosa:

   ```bash
   sudo tee /etc/systemd/system/lab107.service >/dev/null <<'EOF'
   [Unit]
   Description=Lab 107.2 scheduled job

   [Service]
   Type=oneshot
   User=lpicstudent
   ExecStart=/bin/sh -c 'echo "timer ran $(date -Is)" >> /srv/lab107/timer.log'
   EOF

   sudo tee /etc/systemd/system/lab107.timer >/dev/null <<'EOF'
   [Unit]
   Description=Run lab107.service every 2 minutes

   [Timer]
   OnCalendar=*:0/2
   Persistent=true
   AccuracySec=1s
   Unit=lab107.service

   [Install]
   WantedBy=timers.target
   EOF

   sudo systemctl daemon-reload
   sudo systemctl enable --now lab107.timer
   ```

3. Verificá que esté armado y después confirmá que se dispara:

   ```bash
   systemctl list-timers lab107.timer
   ```

   ```
   NEXT                        LEFT LAST                        PASSED UNIT          ACTIVATES
   Thu 2026-08-27 19:38:00 -03 41s  Thu 2026-08-27 19:36:00 -03 1min   lab107.timer  lab107.service
   ```

   ```bash
   sleep 130; cat /srv/lab107/timer.log
   journalctl -u lab107.service --since "-5 min" -o short
   ```

4. Aprendé la sintaxis de calendario preguntándole a systemd en lugar de adivinar:

   ```bash
   systemd-analyze calendar "Mon *-*-* 04:00:00"
   ```

   ```
     Original form: Mon *-*-* 04:00:00
   Normalized form: Mon *-*-* 04:00:00
       Next elapse: Mon 2026-08-31 04:00:00 -03
          (in UTC): Mon 2026-08-31 07:00:00 UTC
          From now: 3 days left
   ```

   ```bash
   systemd-analyze calendar --iterations=3 "*-*-01 02:30"
   systemd-analyze calendar daily weekly "Mon..Fri 09,17:00"
   systemd-analyze calendar "Fri *-*-13 03:00"
   ```

5. Creá un temporizador **transitorio** sin ningún archivo de unidad — el análogo más cercano a `at` en systemd:

   ```bash
   sudo systemd-run --on-active=90s --unit=lab107-oneshot \
     /bin/sh -c 'echo "transient $(date -Is)" >> /srv/lab107/timer.log'
   systemctl list-timers lab107-oneshot.timer
   sleep 100
   tail -2 /srv/lab107/timer.log
   ```

   ```
   Running timer as unit: lab107-oneshot.timer
   Will run service as unit: lab107-oneshot.service
   ```

6. Inspeccioná el estado de persistencia que hace funcionar a `Persistent=true`:

   ```bash
   sudo ls -l /var/lib/systemd/timers/
   ```

   ```
   -rw-r--r-- 1 root root 0 Aug 27 19:38 stamp-lab107.timer
   -rw-r--r-- 1 root root 0 Aug 27 00:00 stamp-logrotate.timer
   ```

7. Limpiá:

   ```bash
   sudo systemctl disable --now lab107.timer
   sudo rm -f /etc/systemd/system/lab107.{timer,service}
   sudo systemctl daemon-reload
   ```

**Preguntas de control — bloque I**

41. ¿Cuántos archivos de unidad necesita como mínimo un temporizador de systemd, y cuál es la convención de nombres por defecto que te permite omitir `Unit=`?
42. ¿Qué directiva de `[Timer]` es el equivalente de anacron, qué requiere para ser significativa, y qué directorio contiene el estado del que depende?
43. Distinguí `OnCalendar=`, `OnBootSec=`, `OnUnitActiveSec=` y `OnActiveSec=` en una oración cada una.
44. Escribiste `OnCalendar=Fri *-*-13 03:00`. ¿Qué coincide con eso — y cómo lo confirmás sin esperar?
45. Tu temporizador nunca se dispara. Enumerá, en orden, los cuatro comandos que ejecutás para diagnosticarlo.
46. Dá el comando `systemd-run` que ejecuta `/usr/local/bin/report` una sola vez, dentro de 30 minutos.
47. Nombrá dos capacidades que tiene un temporizador de systemd y que una entrada de crontab no tiene.

---

## Ejercicio 9 — Higiene de producción: solapamiento, bloqueo y diagnóstico basado en logs

**Pasos**

1. Creá un trabajo que tarde más que su propio intervalo:

   ```bash
   printf '#!/bin/sh\necho "start $$ $(date -Is)" >> /srv/lab107/overlap.log\nsleep 150\necho "end   $$ $(date -Is)" >> /srv/lab107/overlap.log\n' | sudo tee /usr/local/bin/slowjob >/dev/null
   sudo chmod +x /usr/local/bin/slowjob
   ( crontab -l 2>/dev/null; echo '* * * * * /usr/local/bin/slowjob' ) | crontab -
   sleep 200
   cat /srv/lab107/overlap.log
   ```

   ```
   start 5120 2026-08-27T19:50:01-03:00
   start 5188 2026-08-27T19:51:01-03:00
   start 5241 2026-08-27T19:52:01-03:00
   end   5120 2026-08-27T19:52:31-03:00
   ```

   Hay tres copias corriendo en simultáneo. Cron **no** serializa.

2. Arreglalo con `flock` — la respuesta estándar e independiente de la distribución:

   ```bash
   crontab -l | sed 's|^\* \* \* \* \* /usr/local/bin/slowjob|* * * * * /usr/bin/flock -n /var/lock/slowjob.lock /usr/local/bin/slowjob|' | crontab -
   crontab -l | tail -1
   sudo truncate -s 0 /srv/lab107/overlap.log
   sleep 200
   cat /srv/lab107/overlap.log
   ```

   ```
   * * * * * /usr/bin/flock -n /var/lock/slowjob.lock /usr/local/bin/slowjob
   start 5602 2026-08-27T19:56:01-03:00
   end   5602 2026-08-27T19:58:31-03:00
   start 5771 2026-08-27T19:59:01-03:00
   ```

3. Practicá la lectura de los logs de cada subsistema:

   ```bash
   journalctl -u cron --since "-15 min" --no-pager | tail        # or -u crond
   journalctl -t CRON --since "-15 min" | tail
   journalctl -u atd --since today | tail -5
   journalctl -u lab107.service -n 20 --no-pager
   grep -iE 'cron|anacron' /var/log/syslog | tail   # systems still using rsyslog
   ```

4. Fijate qué **no** contiene el log — la *salida* del trabajo:

   ```bash
   ( crontab -l; echo '* * * * * echo "stdout line"; echo "stderr line" >&2' ) | crontab -
   sleep 70
   journalctl -t CRON --since "-2 min" | grep -c 'stdout line' || echo "0 — output is not in the journal"
   ```

5. Desmontaje completo de todo el laboratorio:

   ```bash
   crontab -r
   sudo rm -f /etc/cron.d/lab107-report /etc/cron.hourly/lab107-hourly /usr/local/bin/slowjob
   sudo rm -rf /srv/lab107 /var/lock/slowjob.lock
   atq | awk '{print $1}' | xargs -r atrm
   sudo userdel -r lpicstudent 2>/dev/null; sudo userdel -r thirduser 2>/dev/null
   ```

**Preguntas de control — bloque J**

48. Un trabajo programado como `* * * * *` tarda 150 segundos. ¿Cuántas instancias corren simultáneamente en régimen estacionario, y por qué cron lo permite?
49. Explicá qué hace `flock -n /var/lock/job.lock cmd`. ¿Qué cambia si quitás `-n`? ¿Qué agrega `-w 30`?
50. ¿Qué identificador del journal muestra las *invocaciones* de cron, y qué unidad muestra los mensajes propios del demonio? Escribí ambos comandos `journalctl`.
51. Cron registró `CMD (/usr/local/bin/backup)` pero el backup no ocurrió y no tenés ningún correo. Dá tres maneras concretas de capturar lo que imprimió el trabajo.
52. Reescribí `0 2 * * * /usr/local/bin/backup` para que stdout y stderr se agreguen ambos a `/var/log/backup.log` sin envío de correo.

---

## Tarea de síntesis

Sin mirar hacia atrás, implementá todo lo siguiente en tu host de laboratorio y verificá cada punto:

1. Un trabajo que se ejecute como `postgres` cada 20 minutos, solo de lunes a viernes, solo entre las 08:00 y las 20:00, registrando en `/var/log/pgcheck.log`, entregado como un archivo drop-in del sistema.
2. El mismo trabajo, garantizando que se ejecute una vez por día incluso si el host está apagado a la hora programada — usando `anacron`.
3. El mismo trabajo como un temporizador de systemd con semántica de recuperación y una dispersión aleatoria de 5 minutos.
4. Un trabajo de una sola vez que ejecute `/usr/local/bin/migrate` a las 03:00 del próximo domingo, expresado dos veces: una con `at`, otra con `systemd-run`.
5. Configuración que permita instalar crontabs solo a `root` y a `postgres`.

---

<details>
<summary><strong>Respuestas</strong> — expandí solo después de intentar todos los bloques</summary>

### Bloque A — el crontab de usuario

**1.** Al guardar, `crontab` (a) **valida la sintaxis** y se niega a instalar un archivo con un campo incorrecto, dejando intacto el crontab anterior; y (b) **instala el archivo atómicamente en el spool con el propietario, grupo y modo correctos**, y luego señaliza/marca el spool para que el demonio lo vuelva a leer. Editar `/var/spool/cron/crontabs/<user>` a mano puede producir un crontab sintácticamente inválido, propiedad incorrecta (lo que hace que cron rechace el archivo por completo) y — en implementaciones que se basan en el mtime del directorio del spool — un cambio que el demonio puede no notar. `crontab -e` es la única interfaz soportada.

**2.** Porque el spool debe ser escribible *únicamente* a través del programa que valida. Un spool escribible por todos permitiría que cualquier usuario dejara un archivo arbitrario con el nombre de otro usuario, o corrompiera uno existente. Hacer `crontab` setgid `crontab` (Debian) / setuid (cronie) significa que el *programa* tiene el privilegio, de modo que cada escritura pasa por la validación y la imposición de propiedad.

**3.** `VISUAL`. El orden es `VISUAL`, después `EDITOR`, y después un valor por defecto compilado (`/usr/bin/editor` en Debian, `vi` en el resto).

### Bloque B — respaldo y restauración

**4.** `crontab -i -r` pide confirmación antes de borrar. Muchos administradores definen un alias de `crontab` a `crontab -i` justamente por esta razón.

**5.** **Reemplaza**. `crontab <file>` instala `<file>` como el crontab *completo*, descartando lo que hubiera. Para agregar al final de forma segura: `crontab -l > /tmp/c && echo 'new line' >> /tmp/c && crontab /tmp/c`, o el pipeline usado a lo largo de este laboratorio: `( crontab -l; echo 'new line' ) | crontab -`.

**6.** `crontab -u backup /root/jobs.cron`

### Bloque C — campos

**7.**

| Posición | Campo | Rango |
|---|---|---|
| 1 | minuto | 0–59 |
| 2 | hora | 0–23 |
| 3 | día del mes | 1–31 |
| 4 | mes | 1–12 (o `jan`–`dec`) |
| 5 | día de la semana | 0–7 (o `sun`–`sat`) |

El valor duplicado es **`0` y `7` en el campo día de la semana: ambos significan domingo**. (Estrictamente, el *significado* repetido es domingo; `0` es el valor POSIX y `7` es una extensión de Vixie para quienes cuentan el lunes como día 1.)

**8.** Se ejecuta **todos los días 13 del mes Y todos los viernes** — aproximadamente 16 veces por mes, no una vez al año. La regla: *cuando tanto el campo día del mes como el campo día de la semana están restringidos (ninguno es `*`), cron usa un **OR** lógico — el comando se ejecuta si cualquiera de los dos campos coincide.* Cuando uno de ellos es `*`, se aplica el AND normal entre los cinco campos. Esta asimetría es el detalle más evaluado del formato crontab.

**9.**
```crontab
0 3 13 * *   [ "$(date +\%u)" = "5" ] && /path/to/command
```
El campo de fecha restringe al día 13 (el día de la semana es `*`, así que se aplica AND), y el test de shell filtra por viernes. `%u` debe escaparse como `\%u` en un crontab.

**10.** `0,15,30,45 0 1 1,4,7,10 *` — equivalentemente `*/15 0 1 */3 *`. Notá que `*/3` en el campo del mes significa los meses 1, 4, 7, 10 porque el paso arranca desde el extremo inferior del rango.

**11.** `@weekly` ≡ `0 0 * * 0`. **`@reboot`** no tiene equivalente en campos de tiempo: no es un punto en el tiempo en absoluto — significa *una vez, cuando arranca el demonio cron*, algo que la gramática de cinco campos no puede expresar. (Conjunto completo: `@reboot`, `@yearly`/`@annually` = `0 0 1 1 *`, `@monthly` = `0 0 1 * *`, `@weekly` = `0 0 * * 0`, `@daily`/`@midnight` = `0 0 * * *`, `@hourly` = `0 * * * *`.)

### Bloque D — el entorno de cron

**12.** `SHELL` (por defecto `/bin/sh`), `PATH` (por defecto `/usr/bin:/bin` para crontabs de usuario), `HOME` y `LOGNAME` (más `MAILTO` si está definida). **`HOME` y `LOGNAME` provienen de la entrada del usuario en `/etc/passwd`** y no pueden sobrescribirse de manera significativa a los efectos de ejecutar el trabajo. Fundamental: cron **no** lee `/etc/profile`, `~/.bash_profile` ni `~/.bashrc` — no es una shell de login.

**13.** Arreglos: (a) invocarlo por ruta absoluta — `/usr/bin/mysqldump`; (b) definir `PATH=` al principio del crontab; (c) envolverlo en `/bin/bash -lc '...'` para cargar los archivos de login. **Usá la ruta absoluta en producción**: no depende de estado global del crontab, no puede romperse porque alguien reordene el archivo, y documenta exactamente qué binario se ejecuta. La opción (c) es la peor — hace que el comportamiento del trabajo dependa de dotfiles interactivos que cambian sin revisión.

**14.** Cron trata el `%` en el campo del comando como un **salto de línea**: todo lo que sigue al *primer* `%` sin escapar se convierte en **entrada estándar del comando**, y los `%` siguientes son saltos de línea adicionales de esa entrada. Así que cron ejecutó `date +` (que da error) y le pasó `F > /srv/lab107/pct.log` por stdin — la redirección nunca existió, de ahí el archivo vacío creado antes por tu shell. Escapalo como `\%` para obtener un signo de porcentaje literal. Por eso `date +\%F` es el idioma canónico en crontab, y además es una característica deliberada: `0 5 * * * mail -s report ops%Line one%Line two` suministra el cuerpo por stdin.

**15.**
- `MAILTO=""` — el correo está **desactivado**; la salida del trabajo se descarta.
- `MAILTO` omitido — la salida se envía por correo al **dueño del crontab** (para `/etc/cron.d` y `/etc/crontab`, al usuario del sexto campo).
- `MAILTO=ops@example.com` — la salida se envía por correo a esa dirección.

Con **ningún MTA instalado**, cron no puede entregar: la salida se **pierde** y el journal registra un fallo de entrega como `MAIL (mailed N bytes of output but got status 0x0001)`. Nunca dependas del correo para la salida de un trabajo en un host mínimo — redirigí a un archivo o a `logger`.

**16.** Una asignación de variable afecta solo a las entradas que están **debajo** de ella; cron analiza el archivo de arriba hacia abajo. `PATH=`, `SHELL=` y `MAILTO=` deben aparecer **antes** de las entradas que deben regir — convencionalmente al principio del archivo. (`CRON_TZ=` en Vixie/cronie se comporta igual y cambia la zona horaria usada para interpretar las especificaciones de tiempo siguientes.)

### Bloque E — crontabs del sistema

**17.** Una línea de crontab del sistema tiene un **sexto campo, el nombre de usuario**, entre el campo del día de la semana y el comando: `min hour dom mon dow user command`. Existe porque `/etc/crontab` y `/etc/cron.d` son archivos únicos propiedad de root que deben poder programar trabajo para *cualquier* cuenta — no hay un usuario propietario implícito por la ubicación del archivo, como sí lo hay para un archivo del spool nombrado según su dueño.

**18.** En **`/etc/cron.d`**, cron ignora los archivos cuyos nombres contienen un **punto** (y, en Debian, cualquier cosa fuera de `[A-Za-z0-9_-]`). Por lo tanto `lab107-report.conf` nunca se analizó. La regla relacionada para los directorios de **`run-parts`** (`/etc/cron.daily`, etc.) es la misma en efecto pero distinta en mecanismo: `run-parts` por defecto solo ejecuta archivos cuyos nombres consisten en `[A-Za-z0-9_-]` — así que `.sh`, `.dpkg-dist`, `.rpmsave` y los archivos de respaldo se omiten. Esto es una *característica de seguridad*: evita que un archivo `.rpmnew`/`.dpkg-old` sobrante de un gestor de paquetes se ejecute junto al real.

**19.** Debe ser (a) **ejecutable** (`chmod +x`), y (b) un **archivo regular, no un directorio**, y legible/ejecutable por root. (Una tercera útil: `run-parts --test` lista lo que se ejecutaría sin ejecutarlo — usalo antes de confiar en un script nuevo.)

**20.** **No hace falta reiniciar en ninguno de los tres casos.** Cron se despierta una vez por minuto y verifica las marcas de modificación: (a) hace `stat` sobre **`/etc/cron.d`** y recarga los drop-ins modificados; (b) hace `stat` sobre **`/etc/crontab`** y lo vuelve a leer cuando cambia el mtime; (c) detecta los cambios en el **spool de usuario** porque `crontab(1)` actualiza el mtime del directorio del spool al instalar. La única situación que requiere `systemctl reload cron` es un crontab escrito a mano directamente en el spool, sorteando `crontab(1)` — algo que no deberías hacer.

**21.**
- `/etc/cron.d`: el archivo es **gestionable por configuración** — puede venir en un paquete, generarse por plantilla con Ansible/Puppet, versionarse, revisarse en un diff y eliminarse limpiamente desinstalando el paquete. Además sobrevive a la eliminación del spool del usuario.
- `crontab -u www-data -e`: el trabajo **pertenece a y es visible desde la cuenta a la que corresponde**, `crontab -l` muestra el panorama completo de ese usuario, y no requiere root para inspeccionarlo ni modificarlo. También viaja con una migración de usuarios que copie los spools.

En la práctica, todo lo gestionado por automatización va en `/etc/cron.d`; el trabajo puntual de usuario va en un crontab de usuario.

### Bloque F — anacron

**22.** `period  delay  job-identifier  command`

| Campo | Significado | Unidad |
|---|---|---|
| 1 | período | **días** (o `@daily`, `@weekly`, `@monthly`, `@yearly`) |
| 2 | retardo | **minutos** de espera tras el arranque de anacron antes de ejecutar este trabajo |
| 3 | job-identifier | nombre único; también el nombre del archivo de marca de tiempo en `/var/spool/anacron/` |
| 4 | comando | el comando a ejecutar (puede contener espacios) |

**23.** Cron es un **planificador de reloj de pared**: las 06:25 pasan mientras la máquina está apagada, así que el momento simplemente se pierde y nunca se revisita. Anacron es un **planificador de días transcurridos**: cuando arranca (en el boot, o cada hora vía `/etc/cron.hourly/0anacron`, o vía `anacron.timer`), compara la fecha de hoy con la marca de tiempo en **`/var/spool/anacron/<job-identifier>`** — un archivo que contiene una única fecha `YYYYMMDD`. Si `hoy − marca ≥ período`, espera `delay` minutos y ejecuta el trabajo, y después escribe la fecha de hoy en ese archivo.

**24.** **Un día.** Anacron no puede expresar nada por debajo del día, así que es la herramienta equivocada para cualquier cosa que deba ejecutarse cada hora o cada pocos minutos — usá cron o un temporizador de systemd para eso. Anacron existe para tareas de mantenimiento (`logrotate`, `updatedb`, `man-db`, limpieza de paquetes) en máquinas con tiempo de actividad impredecible: laptops, escritorios, VMs que se suspenden.

**25.** `RANDOM_DELAY` es la **cantidad máxima de minutos aleatorios adicionales** que se suman al `delay` fijo de cada trabajo; `START_HOURS_RANGE` restringe el arranque de los trabajos a un rango dado de horas (por ejemplo `3-22`), de modo que un trabajo al que le toca a las 02:00 espera hasta las 03:00. A una **flota de 500 VMs** le importa `RANDOM_DELAY` porque sin él todas las VMs arrancarían `updatedb`/`logrotate`/una actualización de paquetes en el mismo instante — una tormenta sincronizada de E/S y de red contra el almacenamiento compartido y los mirrors. La dispersión aleatoria es una mitigación del efecto de manada. (`RANDOM_DELAY` es una extensión de cronie/Fedora–Debian, no está en el anacron original.)

**26.** Para evitar la **doble ejecución**. Si anacron está instalado, él es el dueño de los directorios `run-parts` diario/semanal/mensual, así que las entradas de `/etc/crontab` deben abstenerse. `test -x /usr/sbin/anacron ||` convierte cada entrada de cron en una operación nula siempre que anacron esté presente, y en un respaldo funcional cuando no lo está (los servidores con tiempo de actividad continuo suelen omitir anacron).

**27.** `anacron -T` (probar el archivo de configuración), `anacron -n` (ejecutar ahora, ignorar los retardos), `anacron -f` (forzar, ignorar las marcas de tiempo), `anacron -u` (actualizar las marcas de tiempo sin ejecutar los trabajos). `-d` además lo mantiene en primer plano con mensajes de depuración, que es la forma de observar cualquiera de las anteriores.

### Bloque G — control de acceso de cron

**28.**
1. Si **`/etc/cron.allow` existe** → solo los usuarios listados en él pueden usar `crontab`. `cron.deny` se **ignora por completo**.
2. Si no, si **`/etc/cron.deny` existe** → todos los usuarios **excepto** los listados pueden usar `crontab`.
3. Si no (**no existe ninguno**) → depende del sitio: el manual indica que o bien solo el superusuario puede usar `crontab`, o bien todos los usuarios pueden, según cómo se haya compilado el paquete.

`root` siempre está permitido, sin importar el caso.

**29.** **Sí.** `cron.allow` tiene precedencia absoluta — una vez que existe, `cron.deny` no se consulta en absoluto, así que la presencia de alice en el archivo de denegación es irrelevante. Esta es una pregunta clásica de examen y una sorpresa clásica en producción: agregar un usuario a `cron.deny` en un host que tiene `cron.allow` no hace nada.

**30.** **No necesariamente.** El `crontab(1)` de Debian describe el caso sin ningún archivo como dependiente del sitio, y Debian se distribuye sin ninguno de los dos, permitiendo a todos los usuarios. RHEL/cronie se distribuye con un **`/etc/cron.deny` vacío**, lo que pone al sistema en el caso 2 con una lista de denegación vacía — también permitiendo a todos los usuarios, pero por una regla distinta. La redacción de la página del manual que hay que recordar es *"depending on site-dependent configuration parameters, only the super user will be allowed to use this command, or all users will be able to use this command."*

**31.** En Debian, eliminar un `/etc/cron.deny` existente mueve el sistema del caso 2 al caso 3. Como la compilación de Debian permite a todos los usuarios en el caso 3, el conjunto efectivo **crece** (los usuarios previamente denegados recuperan el acceso) o queda igual si el archivo estaba vacío. La respuesta segura para un examen: elimina todas las restricciones basadas en denegación, así que el acceso solo puede ampliarse o quedar igual — y en un sistema cronie compilado para restringir en el caso 3, la jugada correcta es dejar un `cron.deny` vacío en su lugar en vez de eliminarlo.

**32.** **No.** `cron.allow`/`cron.deny` controlan el **comando `crontab(1)`** — la capacidad de *instalar, listar, editar o eliminar* un crontab. El **demonio** no los consulta al decidir qué ejecutar. El crontab existente de bob sigue ejecutándose; simplemente no puede modificarlo. Para detener realmente los trabajos, eliminá el crontab: `crontab -u bob -r` (después de respaldarlo).

**33.** `/etc/at.allow` y `/etc/at.deny`, y **sí, se aplica la regla de precedencia idéntica**: `at.allow` gana si está presente, si no `at.deny` es una lista negra, y si no depende del sitio (RHEL se distribuye con un `/etc/at.deny` vacío).

### Bloque H — `at` y `batch`

**34.** El trabajo se ejecuta bajo **`/bin/sh`** — `at` no hereda tu shell interactiva, que es lo que anuncia la advertencia. `at` toma una instantánea de tu **entorno actual, umask y directorio de trabajo** en el momento del envío, dentro del propio script del trabajo, en `/var/spool/cron/atjobs/` (Debian) o `/var/spool/at/` (RHEL); `at -c <jobnumber>` imprime ese script incluyendo el entorno completo con `export`. Notá la consecuencia: `at` preserva más entorno que cron, pero es el entorno *del momento del envío*, congelado — no el de la ejecución.

**35.**

| Propósito | Comando | Equivalente en `at` |
|---|---|---|
| listar trabajos encolados | `atq` | `at -l` |
| eliminar un trabajo | `atrm <n>` | `at -d <n>`, también `at -r <n>` |
| mostrar el contenido de un trabajo | `at -c <n>` | — |

**36.** `at now` ejecuta el trabajo **inmediatamente, sin condiciones**. `batch` encola el trabajo para ejecutarlo **cuando la carga media del sistema baje de un umbral** — 1.5 por defecto, configurable con `atd -l <load>`. `at` usa la letra de cola **`a`**, `batch` usa la cola **`b`**; `atq` muestra la letra en la cuarta columna. Las letras de cola superiores (`c`–`z`) se ejecutan con valores de `nice` proporcionalmente más altos.

**37.** Te lo **envió por correo** `atd` (vía el MTA local); sin MTA se descartó, y el journal registra el fallo. **`at -m`** fuerza el envío de correo incluso cuando el trabajo no produce salida (útil como notificación de finalización); **`at -M`** suprime el correo por completo. Igual que con cron, redirigí a un archivo si querés estar seguro.

**38.**
- 17:45 de hoy → `at 17:45` (o `at 5:45pm`)
- dentro de cuatro horas → `at now + 4 hours`
- el próximo día 3 a las 02:00 → `at 02:00 next month` es incorrecto; usá una fecha explícita: `at 02:00 2026-09-03` (forma ISO) o `at 2:00am Sep 3`.

Otras formas aceptadas que vale la pena conocer: `noon`, `midnight`, `teatime` (16:00), `tomorrow`, `next week`, `HH:MM MMDDYY`, `now + N minutes|hours|days|weeks`.

**39.** Se **ejecutan inmediatamente** cuando `atd` arranca. `atd` recorre el spool al iniciar y ejecuta todos los trabajos cuya hora ya pasó — los trabajos de `at` no se pierden por la caída del demonio como sí pasa con las entradas de cron. (Sí se pierden, en cambio, si se elimina el archivo del spool.)

**40.** **`cron` es para trabajos recurrentes con un calendario repetitivo; `at` es para una única ejecución en un momento futuro.** Si te encontrás escribiendo un trabajo de `at` que se reenvía a sí mismo, lo que querías era cron.

### Bloque I — temporizadores de systemd

**41.** **Dos** archivos de unidad: un `.timer` y la unidad que activa (normalmente un `.service`, habitualmente `Type=oneshot`). Si comparten el nombre base — `foo.timer` y `foo.service` — la directiva `Unit=` puede omitirse; systemd activa por defecto el servicio con el mismo nombre. `Unit=` solo hace falta cuando los nombres difieren.

**42.** **`Persistent=true`**. Solo tiene sentido junto con **`OnCalendar=`**, y hace que systemd ejecute la unidad inmediatamente en el arranque si el último disparo programado se perdió mientras la máquina estaba apagada — el equivalente de anacron. El estado del que depende vive en **`/var/lib/systemd/timers/stamp-<unit>.timer`** (o `~/.local/share/systemd/timers/` para temporizadores de usuario); el **mtime** del archivo registra el último disparo.

**43.**
- **`OnCalendar=`** — calendario absoluto de reloj de pared, por ejemplo `Mon..Fri 09:00`; el análogo de crontab.
- **`OnBootSec=`** — relativo al **arranque del sistema**.
- **`OnUnitActiveSec=`** — relativo a la **última vez que se inició la unidad activada**, lo que da un espaciado real de "cada N después de que la ejecución previa comenzó" en lugar de una grilla fija.
- **`OnActiveSec=`** — relativo al momento en que se activó la **propia unidad del temporizador**; combinado con `systemd-run --on-active`, este es el análogo de `at`.

(`OnStartupSec=` — relativo al arranque de systemd — y `OnUnitInactiveSec=` — relativo a cuándo la unidad se *detuvo* por última vez — completan el conjunto.)

**44.** Coincide con las **03:00 de cualquier viernes que caiga en el día 13 del mes**. A diferencia de crontab, la sintaxis de calendario de systemd aplica **AND** entre el día de la semana y la fecha — no existe la trampa del OR. Confirmalo con:
```bash
systemd-analyze calendar --iterations=5 "Fri *-*-13 03:00"
```
que imprime los próximos cinco momentos de disparo. Validá siempre así un `OnCalendar=` nuevo antes de desplegarlo.

**45.**
1. `systemctl status foo.timer` — ¿está cargado, activo, y el archivo siquiera se analizó?
2. `systemctl list-timers --all foo.timer` — ¿está armado, y cuál es el `NEXT`? (Un `NEXT` vacío suele significar que no está habilitado o que el calendario nunca coincide.)
3. `journalctl -u foo.service -u foo.timer -n 50` — ¿se disparó y falló, o nunca se disparó?
4. `systemd-analyze verify /etc/systemd/system/foo.timer` más `systemd-analyze calendar "<your expression>"` — ¿es válida la unidad y significa la expresión lo que creés?

Las causas más comunes: olvidarse de `systemctl daemon-reload` después de editar, habilitar el `.service` en lugar del `.timer`, o no tener `[Install] WantedBy=timers.target`.

**46.**
```bash
sudo systemd-run --on-active=30min --unit=report-once /usr/local/bin/report
```
(`--on-calendar="..."` da un temporizador transitorio recurrente; agregá `--user` para uno por usuario.)

**47.** Dos cualesquiera de:
- **Control y aislamiento de recursos** — el trabajo corre como una unidad de servicio, así que `MemoryMax=`, `CPUQuota=`, `PrivateTmp=`, `ProtectSystem=`, `User=`, `Nice=`, `IOSchedulingClass=` son todas aplicables.
- **Ordenamiento por dependencias** — `After=network-online.target`, `Requires=`, `Wants=`: se puede hacer que el trabajo espere a sus prerrequisitos, algo que cron no puede expresar en absoluto.
- **Prevención de solapamiento incorporada** — systemd no inicia un servicio que ya está en ejecución, así que no hace falta un envoltorio con `flock`.
- **Registro estructurado** — la salida va automáticamente al journal, correlacionada con la unidad, sin MTA y sin redirección.
- **Dispersión aleatorizada** — `RandomizedDelaySec=`.
- **Disparadores monotónicos** — `OnBootSec=`/`OnUnitActiveSec=` no tienen equivalente en crontab.
- **Recuperación** — `Persistent=true`, que en cron requiere una herramienta aparte (anacron).

### Bloque J — higiene de producción

**48.** En régimen estacionario, **tres** (arranca una nueva cada 60 s y cada una vive 150 s: ⌈150/60⌉ = 3). El contrato de cron es *"iniciá este comando en estos momentos"* — no lleva registro de si una instancia previa sigue corriendo ni aplica exclusión mutua. La serialización es responsabilidad del autor del trabajo. Sin gestionar, así es como un backup o un rsync lento se convierte en una bomba de forks.

**49.** `flock -n /var/lock/job.lock cmd` adquiere un bloqueo exclusivo sobre el archivo y ejecuta `cmd` solo si el bloqueo estaba libre; **`-n` hace que falle inmediatamente** (estado de salida 1) en lugar de esperar, con lo que una ejecución superpuesta se *omite*. Sin `-n`, `flock` **bloquea indefinidamente** hasta que se libere el bloqueo — las ejecuciones se *encolan*, y en un trabajo que se pasa de tiempo de forma consistente acumulás una cola ilimitada de procesos durmiendo. `-w 30` espera como máximo 30 segundos y después se rinde, que suele ser el punto medio correcto. El bloqueo se libera automáticamente cuando el proceso termina, incluso ante un kill o un crash — por eso `flock` es más seguro que un archivo PID hecho a mano.

**50.**
```bash
journalctl -t CRON        # or -t CROND on RHEL — per-invocation CMD/MAIL/session lines
journalctl -u cron        # or -u crond — the daemon's own start/stop/reload/parse messages
```
Agregá `-f` para seguir, `--since "-10 min"` para acotar, `-o short-iso` para marcas de tiempo parseables. En hosts que todavía escriben logs de texto, `/var/log/syslog` (Debian) o `/var/log/cron` (RHEL) llevan las mismas líneas.

**51.**
1. **Redirigir dentro de la entrada del crontab**: `>> /var/log/backup.log 2>&1`.
2. **Canalizar a través de `logger`** para que la salida llegue al journal con un identificador consultable: `/usr/local/bin/backup 2>&1 | logger -t backup`, y después `journalctl -t backup`.
3. **Reproducir el entorno de cron a mano** — `env -i HOME=/root SHELL=/bin/sh PATH=/usr/bin:/bin /bin/sh -c /usr/local/bin/backup` — lo que saca a la luz fallos de `PATH`/entorno que nunca aparecen en tu shell interactiva. (Una cuarta: convertirlo en un servicio + temporizador de systemd, donde la salida queda capturada en el journal por construcción.)

**52.**
```crontab
MAILTO=""
0 2 * * * /usr/local/bin/backup >> /var/log/backup.log 2>&1
```
El orden importa: `>> file 2>&1` envía stderr a donde stdout apunta en ese momento. `2>&1 >> file` es el error clásico — duplica stderr hacia el stdout de la *terminal* primero, y después redirige solo stdout al archivo.

### Tarea de síntesis

**1 — drop-in del sistema:**
```bash
sudo tee /etc/cron.d/pgcheck >/dev/null <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
MAILTO=""

*/20 8-19 * * 1-5   postgres   /usr/local/bin/pgcheck >> /var/log/pgcheck.log 2>&1
EOF
sudo chmod 0644 /etc/cron.d/pgcheck
```
Notá `8-19`, no `8-20`: la hora 20 incluiría 20:00–20:59. El nombre del archivo no tiene punto. El sexto campo es el usuario.

**2 — anacron:**
```
# /etc/anacrontab
1   15   pgcheck   su -s /bin/sh postgres -c '/usr/local/bin/pgcheck >> /var/log/pgcheck.log 2>&1'
```
Anacron siempre se ejecuta como root y no tiene campo de usuario, así que la reducción de privilegios es explícita. Verificá con `sudo anacron -T`, forzá con `sudo anacron -d -f -n pgcheck`, estado en `/var/spool/anacron/pgcheck`.

**3 — temporizador de systemd:**
```ini
# /etc/systemd/system/pgcheck.service
[Unit]
Description=PostgreSQL health check
After=postgresql.service

[Service]
Type=oneshot
User=postgres
ExecStart=/usr/local/bin/pgcheck
```
```ini
# /etc/systemd/system/pgcheck.timer
[Unit]
Description=Run pgcheck on schedule

[Timer]
OnCalendar=Mon..Fri 08..19:00/20
Persistent=true
RandomizedDelaySec=5min

[Install]
WantedBy=timers.target
```
```bash
sudo systemctl daemon-reload && sudo systemctl enable --now pgcheck.timer
systemd-analyze calendar --iterations=5 "Mon..Fri 08..19:00/20"
```
La salida va automáticamente al journal — `journalctl -u pgcheck.service` — así que no hace falta redirección.

**4 — de una sola vez, de las dos maneras:**
```bash
at 03:00 next sunday <<< '/usr/local/bin/migrate'
# or, if the date is known:  at 03:00 2026-08-30 -f /dev/stdin <<< '/usr/local/bin/migrate'

sudo systemd-run --on-calendar="Sun *-*-* 03:00:00" --unit=migrate-once /usr/local/bin/migrate
```
La forma con `systemd-run` es técnicamente un temporizador recurrente que se elimina después de que se dispara (`sudo systemctl stop migrate-once.timer`); para un disparo único estricto usá `--on-active=` con un desplazamiento calculado, por ejemplo `--on-active="$(( $(date -d '2026-08-30 03:00' +%s) - $(date +%s) ))s"`.

**5 — restringir el acceso a crontab:**
```bash
printf 'root\npostgres\n' | sudo tee /etc/cron.allow >/dev/null
sudo chmod 0600 /etc/cron.allow
sudo chown root:root /etc/cron.allow
```
Crear `cron.allow` vuelve irrelevante a `/etc/cron.deny` — eliminalo o dejalo, no se va a consultar. Verificá con `sudo -u nobody crontab -l`, que debe informar *"You (nobody) are not allowed to use this program (crontab)"*.

</details>

---

## Fuentes

- LPI, *LPIC-1 Exam 102 Objectives, version 5.0* — Tema 107.2: <https://www.lpi.org/our-certifications/exam-102-objectives/>
- LPI, *LPIC-1 Exam 101 Objectives, version 5.0*: <https://www.lpi.org/our-certifications/exam-101-objectives/>
- `crontab(5)` — formato del archivo crontab, rangos de campos, cadenas especiales, manejo de `%`: <https://man7.org/linux/man-pages/man5/crontab.5.html>
- `crontab(1)` — interfaz del comando, precedencia de `cron.allow`/`cron.deny`: <https://man7.org/linux/man-pages/man1/crontab.1.html>
- `cron(8)` — comportamiento del demonio, `/etc/cron.d`, recarga basada en mtime: <https://man7.org/linux/man-pages/man8/cron.8.html>
- `anacrontab(5)` y `anacron(8)` — formato período/retardo/identificador y manejo de marcas de tiempo: <https://man7.org/linux/man-pages/man5/anacrontab.5.html>, <https://man7.org/linux/man-pages/man8/anacron.8.html>
- `at(1)` / `atd(8)` — especificaciones de tiempo, colas, umbral de carga de `batch`: <https://man7.org/linux/man-pages/man1/at.1.html>
- `run-parts(8)` — reglas de nombres de archivo y permisos: <https://manpages.debian.org/stable/debianutils/run-parts.8.en.html>
- `flock(1)` — `-n`, `-w`, duración del bloqueo: <https://man7.org/linux/man-pages/man1/flock.1.html>
- systemd, `systemd.timer(5)` — `OnCalendar`, `Persistent`, temporizadores monotónicos: <https://www.freedesktop.org/software/systemd/man/latest/systemd.timer.html>
- systemd, `systemd.time(7)` — sintaxis de eventos de calendario: <https://www.freedesktop.org/software/systemd/man/latest/systemd.time.html>
- systemd, `systemd-run(1)` — servicios y temporizadores transitorios: <https://www.freedesktop.org/software/systemd/man/latest/systemd-run.html>