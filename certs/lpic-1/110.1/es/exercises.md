# LPIC-1 · Tema 110.1 — Realizar tareas de administración de seguridad

> **Examen:** 101-500 + 102-500 (LPIC-1, versión 5.0) · **Objetivo 110.1**
> **Alcance de este objetivo:** auditar archivos SUID/SGID, gestionar contraseñas y su caducidad, descubrir puertos abiertos (`nmap`, `netstat`/`ss`), establecer límites de login/procesos/memoria, determinar quién está (o estuvo) conectado, y `sudo` básico.
> **Utilidades clave:** `find`, `passwd`, `fuser`, `lsof`, `nmap`, `chage`, `netstat`/`ss`, `sudo`, `su`, `usermod`, `ulimit`, `who`, `w`, `last`.

**Seguridad en el laboratorio.** Ejecutá cada paso destructivo en una VM o contenedor descartable de tu propiedad (una máquina Debian/Ubuntu o de la familia RHEL sirve). Donde un paso modifica cuentas o `sudoers`, se indica el comando de reversión. Los comandos con prefijo `#` requieren root; los `$` son sin privilegios. Referencia oficial del objetivo: <https://www.lpi.org/our-certifications/exam-101-objectives/> y las páginas de manual enlazadas (`man 1 find`, `man 5 sudoers`, `man 1 chage`, `man 5 limits.conf`).

---

## Ejercicio 1 — Auditar el sistema de archivos en busca de binarios SUID / SGID

El bit SUID (`u+s`) hace que un ejecutable corra con los privilegios del **propietario** del archivo en lugar de los de quien lo invoca; SGID (`g+s`) usa el grupo. Los atacantes agregan binarios SUID-root como mecanismo de persistencia/escalada, así que una auditoría de seguridad significa *conocer tu línea base* y detectar desviaciones respecto de ella.

1. Preparar un artefacto de prueba controlado y una referencia legítima:

   ```bash
   # cp /bin/cp /tmp/rogue-cp          # a copy we will deliberately mark SUID
   # chmod 4755 /tmp/rogue-cp          # 4 = setuid; 755 = rwxr-xr-x
   ```

2. Listar la cadena de permisos y confirmar que el bit está presente:

   ```bash
   $ ls -l /tmp/rogue-cp
   -rwsr-xr-x 1 root root 153976 Aug 31 12:04 /tmp/rogue-cp
   ```

   Observá la `s` donde iría la `x` del propietario.

3. Auditar todo el sistema de archivos en busca de archivos SUID **o** SGID, pero permaneciendo en discos locales (sin meterse en `/proc`, NFS, etc.):

   ```bash
   # find / -xdev \( -perm -4000 -o -perm -2000 \) -type f -printf '%m %u %g %p\n' 2>/dev/null
   4755 root root /tmp/rogue-cp
   4755 root root /usr/bin/passwd
   4755 root root /usr/bin/chsh
   4755 root root /usr/bin/sudo
   2755 root tty  /usr/bin/wall
   6755 root root /usr/bin/su
   ...
   ```

4. Distinguir los dos modos de `-perm`. Ejecutá los tres y compará los conteos resultantes:

   ```bash
   # find /usr/bin -perm -4000  -type f | wc -l   # SUID set (ignoring other bits)
   # find /usr/bin -perm /4000  -type f | wc -l   # SUID set (same as -4000 for a single bit)
   # find /usr/bin -perm 4755   -type f | wc -l   # mode EXACTLY 4755, nothing else
   ```

5. Guardar una línea base firmada y compararla más adelante:

   ```bash
   # find / -xdev -perm -4000 -type f 2>/dev/null | sort > /root/suid.baseline
   # sha256sum /root/suid.baseline
   # find / -xdev -perm -4000 -type f 2>/dev/null | sort | diff /root/suid.baseline -
   ```

6. Remediar el archivo intruso y verificar:

   ```bash
   # chmod u-s /tmp/rogue-cp
   $ ls -l /tmp/rogue-cp        # the 's' is now 'x'
   # rm /tmp/rogue-cp
   ```

**Verificación de comprensión**

1. En la salida de `ls -l`, ¿cuál es la diferencia entre `-rwsr-xr-x` y `-rwSr-xr-x` (`S` mayúscula)?
2. ¿Por qué `find / -perm -4000` devuelve archivos que `find / -perm 4755` se pierde?
3. ¿Qué hace `-xdev`, y por qué lo quiere un auditor?
4. `su` muestra el modo `6755`. ¿Qué bits especiales están activos, y qué significa esa cadena numéricamente?
5. ¿Por qué quitar el bit SUID es una primera respuesta más segura que borrar directamente un binario SUID inesperado?

---

## Ejercicio 2 — Averiguar quién usa un archivo, un montaje o un puerto: `fuser` y `lsof`

Antes de poder cambiar una política de contraseñas, matar un login descontrolado o desmontar un dispositivo, con frecuencia necesitás saber *qué proceso lo mantiene abierto*. `lsof` lista archivos abiertos (y sockets); `fuser` mapea un archivo/montaje/puerto a los PID que lo usan.

1. Abrí un descriptor de archivo que puedas observar. En una terminal:

   ```bash
   $ sleep 600 > /tmp/held.log &
   [1] 4821
   ```

2. Identificar los procesos que tienen ese archivo abierto:

   ```bash
   $ fuser -v /tmp/held.log
                        USER        PID ACCESS COMMAND
   /tmp/held.log:       student    4821 F....  sleep
   $ lsof /tmp/held.log
   COMMAND  PID    USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
   sleep   4821 student    1w   REG  254,1        0  131 /tmp/held.log
   ```

   En la columna `FD` de `lsof`, `1w` significa descriptor de archivo 1 (stdout) abierto para **escritura**.

3. Encontrar todos los procesos que tiene un usuario, y todos los archivos abiertos bajo un directorio:

   ```bash
   $ lsof -u student            # all files opened by user 'student'
   $ lsof +D /var/log           # recurse a directory tree
   # fuser -vm /home            # every process using the /home mount (needed before umount)
   ```

4. Mapear un puerto de red al proceso que lo posee (ambas herramientas pueden hacerlo):

   ```bash
   # lsof -i :22 -nP
   COMMAND PID USER   FD  TYPE DEVICE SIZE/OFF NODE NAME
   sshd    712 root    3u IPv4  18234      0t0  TCP *:22 (LISTEN)
   # fuser -v -n tcp 22
                        USER        PID ACCESS COMMAND
   22/tcp:              root        712 F....  sshd
   ```

5. Terminar todo lo que retiene un recurso (cuidado — esto envía señales):

   ```bash
   # fuser -k -TERM /tmp/held.log   # SIGTERM every PID using the file
   $ jobs                           # the background sleep should be gone
   ```

**Verificación de comprensión**

1. ¿Qué cambia el flag `-m` respecto del argumento de `fuser` — un archivo frente a qué?
2. En `lsof`, ¿por qué pasás `-nP` cuando investigás sockets de red?
3. Necesitás hacer `umount /home` pero informa "target is busy". ¿Qué único comando lista a los culpables, y qué flag los señalizaría a la fuerza?
4. `lsof -u student` y `fuser -u` se solapan en intención pero difieren en la salida. ¿Qué agrega realmente `fuser -u` a su listado?
5. Nombrá una razón por la que `fuser -k` sobre un montaje es peligroso en un host de producción.

---

## Ejercicio 3 — Descubrir puertos abiertos: `ss`/`netstat` localmente, `nmap` desde afuera

Dos puntos de vista complementarios: `ss` (o el más antiguo `netstat`) muestra sockets *desde dentro* del host con atribución de procesos; `nmap` sondea *desde la red* y solo ve lo que vería un atacante remoto.

1. Enumerar los sockets TCP y UDP en escucha con los procesos propietarios (ejecutar como root para ver los PID):

   ```bash
   # ss -tulpn
   Netid State  Recv-Q Send-Q Local Address:Port Peer Address:Port Process
   tcp   LISTEN 0      128          0.0.0.0:22        0.0.0.0:*     users:(("sshd",pid=712,fd=3))
   tcp   LISTEN 0      4096       127.0.0.1:5432      0.0.0.0:*     users:(("postgres",pid=980,fd=6))
   udp   UNCONN 0      0          127.0.0.1:323       0.0.0.0:*     users:(("chronyd",pid=640,fd=5))
   ```

   Flags: `-t` TCP, `-u` UDP, `-l` en escucha, `-p` proceso, `-n` numérico (sin resolución DNS ni de `/etc/services`).

2. El equivalente histórico (de `net-tools`), para el examen y para sistemas antiguos:

   ```bash
   # netstat -tulpn
   Proto Recv-Q Send-Q Local Address   Foreign Address State   PID/Program name
   tcp        0      0 0.0.0.0:22       0.0.0.0:*       LISTEN  712/sshd
   tcp        0      0 127.0.0.1:5432   0.0.0.0:*       LISTEN  980/postgres
   ```

3. Fijate *a qué interfaz* se enlaza cada servicio. `0.0.0.0:22` es alcanzable desde cualquier red; `127.0.0.1:5432` es solo loopback. Esta distinción es el objetivo entero de la auditoría.

4. Ahora escaneá el mismo host desde la perspectiva de la red. Desde una **segunda** máquina (o usando la IP enrutable del propio host):

   ```bash
   $ nmap -sT 192.0.2.10
   PORT   STATE SERVICE
   22/tcp open  ssh
   Nmap done: 1 IP address (1 host up) scanned in 0.24 seconds
   ```

   `postgres` en `127.0.0.1` **no** aparece — nmap confirma que no está expuesto externamente.

5. Profundizar el escaneo: detección de versiones y un rango de puertos específico:

   ```bash
   $ nmap -sV -p 1-1000 192.0.2.10
   PORT   STATE SERVICE VERSION
   22/tcp open  ssh     OpenSSH 9.6p1 Ubuntu 3ubuntu13 (Ubuntu Linux; protocol 2.0)
   ```

6. Comparar un escaneo TCP connect (`-sT`, sin privilegios) con un escaneo SYN "half-open" (`-sS`, requiere root):

   ```bash
   # nmap -sS -p 22,80,443 192.0.2.10
   ```

**Verificación de comprensión**

1. Explicá, en una oración cada uno, por qué usarías `ss -tulpn` *y* `nmap` en lugar de solo uno de los dos.
2. ¿Cuál es la diferencia práctica de seguridad entre un servicio enlazado a `0.0.0.0:5432` y otro enlazado a `127.0.0.1:5432`?
3. ¿Qué flag de `ss`/`netstat` suprime la resolución de nombres, y por qué un auditor lo quiere activado?
4. ¿Por qué `nmap -sS` requiere root mientras que `nmap -sT` no?
5. Un puerto muestra `STATE filtered` en la salida de nmap. ¿Qué te dice eso que `closed` no te dice?

---

## Ejercicio 4 — Contraseñas y caducidad de contraseñas: `passwd`, `chage`, `usermod`

La política de caducidad vive en los campos de `/etc/shadow`; `chage` es la interfaz para manipularlos, `passwd` establece el secreto y también puede alternar algunos atributos de caducidad.

1. Crear un usuario descartable e inspeccionar su entrada en shadow:

   ```bash
   # useradd -m -s /bin/bash alice
   # passwd alice
   New password: ********
   Retype new password: ********
   passwd: password updated successfully
   # getent shadow alice
   alice:$y$j9T$....hash....:20000:0:99999:7:::
   ```

   Los campos separados por dos puntos son: `nombre : hash : último-cambio : mín : máx : aviso : inactivo : caducidad :`. Las fechas son **días desde 1970-01-01**.

2. Leer los mismos datos en forma legible para humanos:

   ```bash
   # chage -l alice
   Last password change                                    : Aug 31, 2026
   Password expires                                        : never
   Password inactive                                       : never
   Account expires                                         : never
   Minimum number of days between password change          : 0
   Maximum number of days between password change          : 99999
   Number of days of warning before password expires       : 7
   ```

3. Aplicar una política real: al menos 1 día entre cambios, forzar el cambio cada 90 días, avisar 7 días antes, bloquear la cuenta 14 días después de la caducidad, y establecer una fecha dura de expiración de la cuenta:

   ```bash
   # chage -m 1 -M 90 -W 7 -I 14 -E 2026-12-31 alice
   # chage -l alice
   Maximum number of days between password change          : 90
   Password expires                                        : Nov 29, 2026
   Account expires                                         : Dec 31, 2026
   ```

4. Forzar un cambio de contraseña en el próximo inicio de sesión sin esperar a la caducidad:

   ```bash
   # chage -d 0 alice          # sets "last change" to epoch day 0 → expired now
   # passwd --expire alice     # equivalent effect via passwd
   ```

5. Bloquear y desbloquear la contraseña (ojo: bloquear ≠ expirar la cuenta):

   ```bash
   # passwd -l alice           # prepends '!' to the hash — login by password refused
   # getent shadow alice       # observe the leading '!'
   # passwd -u alice           # unlock
   # usermod -L alice / -U alice   # usermod's equivalent lock/unlock
   ```

6. Limpieza:

   ```bash
   # userdel -r alice
   ```

**Verificación de comprensión**

1. En `/etc/shadow`, ¿en qué unidad se miden los campos *último cambio*, *máx* y *caducidad*?
2. ¿Cuál es la diferencia de efecto entre `chage -E 2026-12-31 alice` y `chage -M 90 alice`?
3. `chage -d 0 alice` fuerza un cambio en el próximo inicio de sesión. Mecánicamente, ¿*por qué* establecer último-cambio en 0 provoca eso?
4. ¿Cuál es la diferencia entre `passwd -l` (bloquear) y `chage -E 0` (expirar) para un usuario que inicia sesión únicamente por SSH con **clave pública**?
5. ¿Qué comando muestra los campos de caducidad en lenguaje claro sin editar `/etc/shadow` a mano?

---

## Ejercicio 5 — Limitar inicios de sesión, procesos y memoria: `ulimit` y `limits.conf`

`ulimit` establece límites de recursos por shell aplicados por el kernel; `/etc/security/limits.conf` (a través del módulo PAM `pam_limits.so`) los establece por usuario/grupo en el inicio de sesión. Los límites blandos (soft) pueden ser elevados por el usuario hasta el límite duro (hard); los límites duros necesitan root para elevarse.

1. Inspeccionar los límites del shell actual:

   ```bash
   $ ulimit -a
   open files                          (-n) 1024
   max user processes                  (-u) 15122
   virtual memory              (kbytes, -v) unlimited
   core file size              (blocks, -c) 0
   $ ulimit -Sn        # soft open-files limit
   1024
   $ ulimit -Hn        # hard open-files limit
   524288
   ```

2. Elevar un límite blando dentro del techo duro (afecta solo a este shell y sus hijos):

   ```bash
   $ ulimit -Sn 4096
   $ ulimit -Sn        # 4096
   $ ulimit -Sn 600000 # fails: exceeds hard limit
   bash: ulimit: open files: cannot modify limit: Operation not permitted
   ```

3. Demostrar un límite actuando. Establecé un tope de procesos minúsculo en una subshell y probalo de forma segura (sin fork bomb real):

   ```bash
   $ bash -c 'ulimit -u 20; for i in $(seq 1 40); do sleep 5 & done; wait' 2>&1 | tail -3
   bash: fork: retry: Resource temporarily unavailable
   ```

4. Hacer que un límite sea persistente y aplicado por el sistema. Editá `/etc/security/limits.conf` (o un drop-in bajo `/etc/security/limits.d/`):

   ```bash
   # cat >> /etc/security/limits.d/90-lab.conf <<'EOF'
   @developers   soft   nproc    200
   @developers   hard   nproc    400
   alice         hard   nofile   8192
   *             hard   core     0
   EOF
   ```

   Las columnas son `<domain> <type> <item> <value>`: domain = usuario, `@grupo` o `*`; type = `soft`/`hard`; item = `nproc`, `nofile`, `core`, `as` (espacio de direcciones / memoria), etc.

5. Verificar la aplicación en el inicio de sesión (requiere una sesión de login nueva para que PAM lo relea):

   ```bash
   $ su - alice -c 'ulimit -Hn'
   8192
   ```

6. Tomá nota del item `maxlogins` para topear las sesiones concurrentes:

   ```bash
   # echo 'alice   -   maxlogins   2' >> /etc/security/limits.d/90-lab.conf
   ```

**Verificación de comprensión**

1. ¿Cuál es la relación entre un `ulimit` *blando* y uno *duro*, y quién puede elevar cada uno?
2. ¿Por qué un cambio de `ulimit` en una terminal no afecta a un programa que ya está corriendo en otra terminal?
3. ¿Qué archivo hace que los límites se apliquen automáticamente en el inicio de sesión, y qué módulo PAM lo hace cumplir?
4. En `limits.conf`, ¿qué topea el item `nproc`, y qué topea `as`?
5. Un desarrollador dice: "puse `ulimit -n 100000` y sigue fallando a los 30000 archivos abiertos". Dá dos causas distintas.

---

## Ejercicio 6 — Quién está conectado, y quién estuvo: `who`, `w`, `last`, `lastlog`

Estos leen tres bases de datos diferentes: `who`/`w` leen `/var/run/utmp` (sesiones actuales), `last` lee `/var/log/wtmp` (historial de inicios/cierres de sesión), y `lastlog` lee `/var/log/lastlog` (el inicio de sesión más reciente de cada cuenta).

1. Ver las sesiones actuales y qué están haciendo:

   ```bash
   $ who
   root     tty1         2026-08-31 09:12
   student  pts/0        2026-08-31 12:01 (192.0.2.55)
   $ w
    12:40:31 up  3:28,  2 users,  load average: 0.10, 0.06, 0.01
   USER     TTY      FROM        LOGIN@   IDLE   JCPU   PCPU WHAT
   student  pts/0    192.0.2.55  12:01    0.00s  0.30s  0.02s w
   ```

   `w` agrega tiempo de inactividad, uso de CPU y el comando actual, frente a la lista pelada de `who`.

2. Informar solo sobre vos mismo y el nivel de ejecución:

   ```bash
   $ whoami
   student
   $ who -r        # current runlevel / systemd target transition
   $ who -b        # last system boot time
   ```

3. Revisar el historial de inicios de sesión y reinicios:

   ```bash
   $ last -a | head
   student  pts/0        Mon Aug 31 12:01   still logged in     192.0.2.55
   reboot   system boot  Mon Aug 31 09:10   still running       6.8.0-generic
   root     tty1         Mon Aug 31 09:12 - 09:40  (00:28)       0.0.0.0
   $ last -x | grep -E 'shutdown|reboot' | head
   ```

4. Investigar una cuenta específica y los inicios de sesión fallidos:

   ```bash
   $ last student           # every session for one user
   # lastb | head           # BAD login attempts (from /var/log/btmp; root-only)
   ```

5. Ver el inicio de sesión más reciente por cuenta, y detectar cuentas que *nunca* iniciaron sesión:

   ```bash
   $ lastlog
   Username     Port     From             Latest
   root         tty1                      Mon Aug 31 09:12:00 +0000 2026
   student      pts/0    192.0.2.55       Mon Aug 31 12:01:10 +0000 2026
   backup                                 **Never logged in**
   $ lastlog -b 30          # accounts with no login in the last 30 days
   ```

**Verificación de comprensión**

1. ¿Qué archivo lee `who`, y qué archivo lee `last`? ¿Por qué eso hace que respondan preguntas distintas?
2. ¿Qué tres columnas muestra `w` que `who` (sin flags) no muestra?
3. ¿Dónde aparecen los intentos de inicio de sesión *fallidos*, y qué comando los lee?
4. ¿Qué muestra `lastlog` que `last` no puede, y viceversa?
5. Una cuenta muestra `**Never logged in**` en `lastlog` pero la ves en `last`. Dá una explicación plausible.

---

## Ejercicio 7 — Delegar privilegios de forma segura: `sudo`, `/etc/sudoers` y `su`

`su` cambia de identidad pidiendo la contraseña del *destino* (normalmente la de root). `sudo` ejecuta un comando como otro usuario según una política en `/etc/sudoers`, autenticando con la contraseña *propia* de quien llama, y registra cada invocación. Preferí `sudo` por delegación y auditabilidad.

1. Contrastar las dos herramientas de cambio de identidad:

   ```bash
   $ su -              # full login shell as root; needs ROOT's password
   $ su - alice        # become alice; needs ALICE's password (or root can skip it)
   $ sudo -i           # root login shell; needs YOUR OWN password, and a policy grant
   $ sudo -u alice id  # run one command as alice
   ```

2. Editá **siempre** la política con `visudo`, que verifica la sintaxis antes de guardar (un `sudoers` roto puede dejar a todos afuera):

   ```bash
   # visudo
   # visudo -c            # just validate the current file
   /etc/sudoers: parsed OK
   ```

3. Otorgar sudo completo a un usuario mediante un drop-in (la ubicación moderna y segura ante actualizaciones):

   ```bash
   # visudo -f /etc/sudoers.d/10-alice
   ```
   ```
   alice   ALL=(ALL:ALL) ALL
   ```

   Los campos son `usuario  HOST=(USUARIO_RUNAS:GRUPO_RUNAS)  COMANDOS`.

4. Otorgar un privilegio *acotado y sin contraseña* — el patrón de mínimo privilegio que realmente querés en producción. Dejemos que un usuario de monitoreo reinicie un solo servicio, sin contraseña:

   ```bash
   # visudo -f /etc/sudoers.d/20-monitor
   ```
   ```
   Cmnd_Alias SVC = /usr/bin/systemctl restart nginx, /usr/bin/systemctl status nginx
   monitor    ALL=(root) NOPASSWD: SVC
   ```

5. Probar como el usuario destino y leer el rastro de auditoría:

   ```bash
   $ sudo -l                      # what am I allowed to run?
   User monitor may run the following commands on host:
       (root) NOPASSWD: /usr/bin/systemctl restart nginx, /usr/bin/systemctl status nginx
   $ sudo systemctl restart nginx # allowed
   $ sudo systemctl restart sshd  # denied
   Sorry, user monitor is not allowed to execute '/usr/bin/systemctl restart sshd' as root ...
   # journalctl -t sudo | tail    # every attempt is logged (also /var/log/auth.log or /var/log/secure)
   ```

6. Entender las concesiones basadas en grupos. En Debian el grupo `sudo`, en RHEL el grupo `wheel`, recibe el permiso mediante una línea por defecto:

   ```bash
   # grep -E '%(sudo|wheel)' /etc/sudoers
   %sudo   ALL=(ALL:ALL) ALL
   # usermod -aG sudo alice       # add alice to the admin group (Debian/Ubuntu)
   ```

7. Limpiar las concesiones del laboratorio:

   ```bash
   # rm /etc/sudoers.d/10-alice /etc/sudoers.d/20-monitor
   # visudo -c
   ```

**Verificación de comprensión**

1. ¿La contraseña de quién pide `su -`, y la de quién pide `sudo`? ¿Por qué importa eso para la auditoría y para las credenciales de root compartidas?
2. ¿Por qué debés editar `sudoers` con `visudo` en lugar de un editor común?
3. Descifrá campo por campo la concesión `monitor ALL=(root) NOPASSWD: /usr/bin/systemctl restart nginx`.
4. ¿Qué informa `sudo -l`, y por qué es lo primero que hay que ejecutar cuando heredás una cuenta desconocida?
5. En un host RHEL, ¿qué pertenencia a grupo confiere sudo típicamente, y dónde está definido ese mapeo?
6. ¿Por qué un `Cmnd_Alias` que restringe `systemctl restart nginx` es más débil de lo que parece si el usuario además puede editar el archivo de unidad de nginx o ejecutar un editor como root?

---

<details>
<summary><strong>Respuestas</strong></summary>

### Ejercicio 1 — Auditoría SUID/SGID

1. La `s` minúscula significa que el bit SUID **y** el bit de ejecución del propietario están ambos activos (`rws`). La `S` mayúscula significa que el bit SUID está activo pero el bit de ejecución **no** (`rwS`) — normalmente un error, ya que un archivo SUID no ejecutable no hace nada útil y señala una mala configuración.
2. `-perm -4000` coincide con cualquier archivo donde *al menos* el bit SUID esté activo, sin importar los otros 11 bits de permisos. `-perm 4755` coincide solo con archivos cuyo modo sea **exactamente** `4755` — una prueba más estricta y rara vez lo que querés. También existe `-perm /4000` ("cualquiera de estos bits"), que para un único bit es equivalente a `-4000`.
3. `-xdev` (también conocido como `-mount`) le dice a `find` que no descienda hacia otros sistemas de archivos. Un auditor lo quiere para que el escaneo se quede en el disco local y no recorra `/proc`, `/sys`, montajes de red o bind mounts — más rápido, y evita conteos dobles y falsos positivos.
4. `6755` = SUID (4000) + SGID (2000) + `rwxr-xr-x` (0755). Así que están activos tanto el bit setuid como el setgid. (`su` legítimamente lleva ambos.)
5. Quitar el bit (`chmod u-s`) neutraliza el riesgo de escalada de inmediato y de forma reversible mientras investigás; borrar podría destruir un binario de sistema *legítimo* que juzgaste mal, o eliminar evidencia necesaria para el análisis del incidente.

### Ejercicio 2 — `fuser` / `lsof`

1. Sin `-m`, el argumento es un archivo/socket. Con `-m`, `fuser` trata el argumento como un **punto de montaje (sistema de archivos)** e informa cada proceso con algún archivo abierto en ese sistema de archivos — la forma que necesitás antes de `umount`.
2. `-n` deshabilita la resolución de nombres de host (DNS) y `-P` deshabilita la resolución de nombres de puerto (`/etc/services`), de modo que `lsof` imprime IP crudas y puertos numéricos rápidamente y no se cuelga con un DNS inverso lento.
3. `fuser -vm /home` lista los procesos que retienen el montaje; `fuser -km /home` (agregá `-TERM`/`-KILL` para elegir la señal) los señaliza a la fuerza. (`lsof +D /home` o `lsof /home` es el equivalente de solo lectura para únicamente listar.)
4. `fuser -u` agrega el **nombre de usuario propietario** de cada proceso entre paréntesis al listado de PID, así ves a quién contactar/culpar sin una segunda consulta con `ps`.
5. En producción, `fuser -k` sobre un montaje señaliza a *todos* los procesos que tocan ese sistema de archivos a la vez — lo que puede incluir demonios críticos, sshd o tu propia shell — pudiendo causar una caída del servicio o cortarte el acceso. Es preferible identificar y detener los servicios de forma ordenada primero.

### Ejercicio 3 — `ss`/`netstat`/`nmap`

1. `ss`/`netstat` muestran la verdad de campo desde adentro, incluyendo lo que es solo loopback y la propiedad de los procesos; `nmap` muestra solo lo que es alcanzable a través de la red. Juntos revelan tanto qué está corriendo como qué está realmente expuesto — un servicio puede estar corriendo y aun así estar detrás del firewall, o enlazado solo a loopback.
2. `0.0.0.0:5432` es alcanzable desde cualquier interfaz/red (exposición remota); `127.0.0.1:5432` es alcanzable solo desde el propio host (loopback), así que ningún cliente remoto puede conectarse, independientemente del firewall — una superficie de ataque drásticamente menor.
3. `-n` (numérico). Los auditores lo quieren para que la salida sea inequívoca (IP:puerto crudos), rápida (sin consultas DNS ni de `/etc/services`) y no falsificable por un resolutor envenenado.
4. `-sS` construye paquetes SYN crudos directamente, lo que requiere `CAP_NET_RAW`/root. `-sT` usa la llamada al sistema `connect()` normal del SO (un handshake TCP completo), que cualquier usuario puede hacer.
5. `filtered` significa que nmap **no obtuvo respuesta** (o un ICMP unreachable) — típicamente un firewall está descartando el sondeo, así que nmap no puede saber si hay un servicio ahí. `closed` significa que el host respondió activamente (RST) que no hay nada escuchando — el puerto es alcanzable pero no tiene servicio.

### Ejercicio 4 — contraseñas y caducidad

1. **Días desde la época Unix (1970-01-01)** para último-cambio y caducidad; una **cantidad de días** para los intervalos máx/mín/aviso/inactivo.
2. `-E 2026-12-31` establece una expiración dura de la **cuenta** — después de esa fecha la cuenta queda deshabilitada por completo, sin importar la contraseña. `-M 90` establece la edad máxima de la **contraseña** — el usuario debe *cambiar* la contraseña cada 90 días, pero la cuenta sigue utilizable.
3. La caducidad de la contraseña se calcula como `último-cambio + máx`. Poner último-cambio en el día 0 (1970) hace que `0 + máx` sea una fecha de décadas atrás, así que la contraseña ya está vencida y el usuario se ve obligado a cambiarla en el próximo inicio de sesión.
4. `passwd -l` bloquea solo la *contraseña* invalidando el hash — **no** bloquea SSH basado en claves, así que un usuario con clave pública sigue entrando. `chage -E 0` expira la *cuenta* entera, lo que la fase de cuenta de PAM rechaza, bloqueando **todos** los métodos de inicio de sesión, incluidas las claves SSH.
5. `chage -l <usuario>` (modo listado).

### Ejercicio 5 — límites

1. El límite blando es el valor actualmente aplicado; el límite duro es el techo hasta el cual se puede elevar el blando. Un usuario sin privilegios puede bajar/subir el límite blando hasta el duro y solo puede *bajar* el límite duro; solo root puede elevar el límite duro.
2. Los límites de `ulimit` son por proceso y los heredan los hijos en el momento del fork/exec. Cambiar el límite de un shell afecta solo a ese shell y a los procesos que inicie después — un proceso ya en ejecución en otra terminal conserva los límites que heredó cuando arrancó.
3. `/etc/security/limits.conf` (más los drop-ins en `/etc/security/limits.d/`), aplicado en el inicio de sesión por el módulo PAM `pam_limits.so`.
4. `nproc` topea la cantidad máxima de procesos del usuario; `as` topea el **espacio de direcciones** del proceso (memoria virtual, es decir, la memoria máxima que puede mapear).
5. Dos de: (a) el valor excede el límite **duro**, así que la elevación del blando es rechazada/topeada; (b) se alcanza un límite del kernel **a nivel de todo el sistema** — `fs.file-max` (sysctl) o el `nofile` por usuario de `limits.conf`; (c) el proceso se inició **antes** del cambio y heredó el límite viejo; (d) el `LimitNOFILE=` de un servicio systemd anula por completo el `ulimit` del shell para los demonios.

### Ejercicio 6 — quién está conectado

1. `who` lee `/var/run/utmp` (la tabla de sesiones *actuales*); `last` lee `/var/log/wtmp` (el registro *histórico* de inicios/cierres de sesión). Por eso `who` responde "quién está conectado ahora" y `last` responde "quién inició sesión y cuándo, incluyendo sesiones pasadas y reinicios".
2. `w` agrega el tiempo de inactividad (**IDLE**), las columnas de CPU (**JCPU/PCPU**) y **WHAT** (el comando actual en primer plano), más un encabezado con el uptime y la carga promedio.
3. Los intentos fallidos de inicio de sesión se registran en `/var/log/btmp`, y se leen con `lastb` (solo root).
4. `lastlog` muestra la marca temporal del inicio de sesión *más reciente* de **cada** cuenta (incluidas las que nunca iniciaron sesión), leyendo `/var/log/lastlog`. `last` muestra el *historial* completo de sesiones (varias por usuario) y los reinicios, pero no enumera las cuentas que nunca iniciaron sesión.
5. `lastlog` lee `/var/log/lastlog`, que puede estar disperso (sparse) o reiniciado, puede no actualizarse para ciertos tipos de inicio de sesión (por ejemplo, algunas rutas no-PAM o de cron/su), o haber sido truncado/rotado — así que una sesión registrada en `wtmp` (vista por `last`) puede estar ausente de `lastlog`. Cambios de reloj o un método de inicio de sesión que evite `pam_lastlog` también causan esto.

### Ejercicio 7 — `sudo` / `su`

1. `su -` pide la contraseña de la cuenta **destino** (típicamente la contraseña compartida de root). `sudo` pide la contraseña **propia de quien llama**. Esto importa porque `sudo` evita compartir la contraseña de root, vincula cada acción privilegiada a una persona nombrada y registra cada comando — una rendición de cuentas muchísimo mejor.
2. `visudo` bloquea el archivo contra ediciones concurrentes y, fundamentalmente, **verifica su sintaxis** antes de guardar. Un `sudoers` malformado es rechazado por `sudo` por completo, lo que puede dejar a todos los administradores sin privilegios; `visudo` impide guardar un archivo roto.
3. `monitor` = el usuario al que aplica la regla; `ALL=` = en todos los hosts; `(root)` = puede ejecutar el comando como el usuario root; `NOPASSWD:` = sin que se le pida contraseña; `/usr/bin/systemctl restart nginx` = el *único* comando permitido (ruta y argumentos exactos).
4. `sudo -l` lista exactamente qué comandos puede ejecutar el usuario actual mediante sudo (y como quién, con o sin contraseña). Es lo primero que hay que ejecutar en una cuenta desconocida porque revela tu huella real de privilegios sin prueba y error.
5. En RHEL/Fedora el grupo **`wheel`** confiere sudo típicamente, definido por la línea `%wheel ALL=(ALL) ALL` en `/etc/sudoers`.
6. Porque la restricción solo limita *qué binario* se ejecuta, no lo que ese acceso termina otorgando. Si el usuario puede editar el archivo de unidad de nginx (o ejecutar cualquier editor o `systemctl edit` como root), puede hacer que "restart nginx" ejecute comandos arbitrarios como root vía `ExecStart`/`ExecStartPre` — así que el `Cmnd_Alias` de apariencia estrecha es efectivamente root total. El mínimo privilegio debe considerar la capacidad *transitiva*, no solo la cadena del comando.

</details>