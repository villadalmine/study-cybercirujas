# LPIC-1 · Tema 107.1 — Gestionar cuentas de usuario y de grupo y los archivos de sistema relacionados
## Ejercicios guiados (101-500 / 102-500, versión 5.0)

> **Ejecutá esto en un sistema descartable.** Cada paso de abajo modifica las bases de datos reales de cuentas. Usá un snapshot de VM al que puedas volver, o un contenedor desechable:
> ```
> docker run --rm -it --name lpic107 debian:12 bash
> ```
> Todos los comandos asumen que sos `root`. Cuando importa una diferencia entre distribuciones, se aclara en línea (Debian/Ubuntu vs. RHEL/Fedora/SUSE).

---

## Ejercicio 0 — Red de seguridad y línea base

**Pasos**

1. Confirmá tu nivel de privilegio y la distribución en la que estás:
   ```bash
   id -u
   cat /etc/os-release | head -2
   ```
   ```
   0
   PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"
   NAME="Debian GNU/Linux"
   ```

2. Respaldá las cuatro bases de datos de cuentas *preservando modo, propietario y marcas de tiempo*:
   ```bash
   mkdir -p /root/acct-backup
   cp -a /etc/passwd /etc/shadow /etc/group /etc/gshadow /root/acct-backup/
   ```

3. Inspeccioná los permisos de los originales:
   ```bash
   ls -l /etc/passwd /etc/shadow /etc/group /etc/gshadow
   ```
   ```
   -rw-r--r-- 1 root root   1042 Aug 27 09:12 /etc/passwd
   -rw-r----- 1 root shadow  621 Aug 27 09:12 /etc/shadow
   -rw-r--r-- 1 root root    527 Aug 27 09:12 /etc/group
   -rw-r----- 1 root shadow  447 Aug 27 09:12 /etc/gshadow
   ```

4. Registrá los "días desde el Epoch" de hoy — la unidad que `/etc/shadow` usa en cada campo de fecha:
   ```bash
   echo $(( $(date +%s) / 86400 ))
   date -u -d "1970-01-01 UTC +$(( $(date +%s) / 86400 )) days" +%F
   ```
   ```
   20692
   2026-08-27
   ```

**Preguntas**

- **Q1.** ¿Por qué `cp -a` en lugar de un `cp` simple al respaldar estos cuatro archivos?
- **Q2.** Dos de los cuatro archivos son legibles por todo el mundo y dos no. ¿Cuál es la razón de seguridad de esa división, y cuál es el nombre histórico del mecanismo que la produjo?
- **Q3.** `/etc/shadow` tiene modo `0640` y pertenece a `root:shadow`. ¿Qué programa necesita leerlo como usuario no root, y cómo se las arregla para hacerlo?

---

## Ejercicio 1 — Anatomía de las cuatro bases de datos

**Pasos**

1. Dividí la línea de `root` de `/etc/passwd` en sus siete campos:
   ```bash
   getent passwd root | awk -F: '{printf "1 login=%s\n2 passwd=%s\n3 uid=%s\n4 gid=%s\n5 gecos=%s\n6 home=%s\n7 shell=%s\n",$1,$2,$3,$4,$5,$6,$7}'
   ```
   ```
   1 login=root
   2 passwd=x
   3 uid=0
   4 gid=0
   5 gecos=root
   6 home=/root
   7 shell=/bin/bash
   ```

2. Ahora los nueve campos de la línea correspondiente de `/etc/shadow`:
   ```bash
   getent shadow root | awk -F: '{printf "1 login=%s\n2 hash=%.16s...\n3 lastchg=%s\n4 min=%s\n5 max=%s\n6 warn=%s\n7 inactive=%s\n8 expire=%s\n9 reserved=%s\n",$1,$2,$3,$4,$5,$6,$7,$8,$9}'
   ```
   ```
   1 login=root
   2 hash=$y$j9T$e8Kq3Vt2...
   3 lastchg=20441
   4 min=0
   5 max=99999
   6 warn=7
   7 inactive=
   8 expire=
   9 reserved=
   ```

3. Identificá el esquema de hashing a partir del prefijo `$id$`:
   ```bash
   getent shadow root | cut -d: -f2 | cut -d'$' -f2
   grep -E '^ENCRYPT_METHOD' /etc/login.defs
   ```
   ```
   y
   ENCRYPT_METHOD YESCRYPT
   ```
   Tabla de referencia: `$1$` MD5 · `$2b$` bcrypt · `$5$` SHA-256 · `$6$` SHA-512 · `$y$` yescrypt · `$7$` scrypt.

4. Mirá las cuentas que nunca pueden autenticarse con contraseña, y las bases de datos de grupos:
   ```bash
   awk -F: '$2=="*" {print $1}' /etc/shadow | head -5
   getent group sudo
   getent gshadow sudo
   ```
   ```
   daemon
   bin
   sys
   sync
   games
   sudo:x:27:
   sudo:*::
   ```

5. Demostrá la diferencia entre una pertenencia de grupo *primario* y una *suplementaria*:
   ```bash
   getent passwd root | cut -d: -f4      # primary GID of root
   getent group root                     # is root listed as a member of group root?
   id root
   ```
   ```
   0
   root:x:0:
   uid=0(root) gid=0(root) groups=0(root)
   ```

**Preguntas**

- **Q4.** El campo 2 de `/etc/passwd` contiene `x`. ¿Qué significa eso, y qué pasa si lo reemplazás por una cadena vacía?
- **Q5.** En el campo 2 de `/etc/shadow`, distinguí `*`, `!`, `!!`, `!$y$j9T$...` y un campo **vacío**. ¿Cuál de estos todavía permite un login con contraseña?
- **Q6.** `getent group root` muestra una lista de miembros vacía, y sin embargo `id root` informa `groups=0(root)`. Explicá la aparente contradicción.
- **Q7.** ¿Qué contiene el campo 3 de `/etc/gshadow`, y qué comando lo escribe?
- **Q8.** El `lastchg` de `root` es `20441`. Convertilo a una fecha de calendario con un solo comando, y decí qué significaría un valor de `0` en ese campo.

---

## Ejercicio 2 — Valores por defecto consultados *antes* de que exista una cuenta

**Pasos**

1. Leé el archivo de política de todo el sitio:
   ```bash
   grep -E '^(UID_MIN|UID_MAX|GID_MIN|GID_MAX|SYS_UID_MIN|SYS_UID_MAX|PASS_MAX_DAYS|PASS_MIN_DAYS|PASS_WARN_AGE|CREATE_HOME|USERGROUPS_ENAB|UMASK|ENCRYPT_METHOD)' /etc/login.defs
   ```
   ```
   PASS_MAX_DAYS	99999
   PASS_MIN_DAYS	0
   PASS_WARN_AGE	7
   UID_MIN			 1000
   UID_MAX			60000
   SYS_UID_MIN		  100
   SYS_UID_MAX		  999
   GID_MIN			 1000
   GID_MAX			60000
   UMASK			022
   ENCRYPT_METHOD YESCRYPT
   USERGROUPS_ENAB yes
   ```

2. Leé los valores por defecto específicos de `useradd` — notá que este es un **archivo distinto**, y tiene un front end de CLI:
   ```bash
   useradd -D
   cat /etc/default/useradd
   ```
   ```
   GROUP=100
   HOME=/home
   INACTIVE=-1
   EXPIRE=
   SHELL=/bin/sh
   SKEL=/etc/skel
   CREATE_MAIL_SPOOL=no
   ```

3. Cambiá un valor por defecto a través de la herramienta en vez del editor, y verificá que quedó en el archivo:
   ```bash
   useradd -D -s /bin/bash
   grep ^SHELL /etc/default/useradd
   ```
   ```
   SHELL=/bin/bash
   ```

4. Inspeccioná la plantilla del directorio home y agregale un marcador:
   ```bash
   ls -A /etc/skel
   echo '# managed by platform team' >> /etc/skel/.bashrc
   install -d -m 0700 /etc/skel/.ssh
   ```
   ```
   .bash_logout  .bashrc  .profile
   ```

**Preguntas**

- **Q9.** `UID_MIN` vive en `/etc/login.defs`, `HOME` vive en `/etc/default/useradd`. ¿Cuál es la división conceptual de tareas entre los dos archivos?
- **Q10.** En Debian, `useradd bob` (sin opciones) **no** crea `/home/bob`; en RHEL sí. ¿Qué configuración lo explica, y qué única opción hace el comportamiento determinista en ambos?
- **Q11.** Está puesto `USERGROUPS_ENAB yes`. Describí sus dos efectos distintos — uno en el momento de la creación, otro en el del borrado.
- **Q12.** Agregás `/etc/skel/.ssh` *después* de crear un usuario. ¿Ese usuario obtiene el directorio? ¿Qué opción de `useradd` sobrescribe el origen del esqueleto para una sola invocación?

---

## Ejercicio 3 — Crear cuentas humanas y de servicio

**Pasos**

1. Creá una cuenta regular e interactiva de forma explícita — nunca confíes en los valores por defecto en producción:
   ```bash
   useradd -m -c "Ana Nova,SRE,,," -s /bin/bash ana
   id ana
   ls -ld /home/ana
   ```
   ```
   uid=1000(ana) gid=1000(ana) groups=1000(ana)
   drwx------ 2 ana ana 4096 Aug 27 09:20 /home/ana
   ```
   *(El UID/GID puede diferir si tu sistema ya tiene usuarios regulares.)*

2. Inspeccioná lo que las tres bases de datos contienen ahora para `ana`:
   ```bash
   getent passwd ana; getent shadow ana; getent group ana
   ```
   ```
   ana:x:1000:1000:Ana Nova,SRE,,,:/home/ana:/bin/bash
   ana:!:20692:0:99999:7:::
   ana:x:1000:
   ```

3. Establecé una contraseña de forma no interactiva y volvé a leer la entrada de shadow:
   ```bash
   echo 'ana:Str0ng-Transit!' | chpasswd
   getent shadow ana | cut -c1-40
   passwd -S ana
   ```
   ```
   ana:$y$j9T$Rk1pZ8QmA2Vn7Hs0kX...
   ana P 08/27/2026 0 99999 7 -1
   ```

4. Creá una cuenta **de sistema** para un demonio — sin shell de login, sin home, sin envejecimiento:
   ```bash
   useradd -r -s /usr/sbin/nologin -d /var/lib/metrics -M svc_metrics
   install -d -o svc_metrics -g svc_metrics -m 0750 /var/lib/metrics
   getent passwd svc_metrics
   passwd -S svc_metrics
   ```
   ```
   svc_metrics:x:999:999::/var/lib/metrics:/usr/sbin/nologin
   svc_metrics L 08/27/2026 0 99999 7 -1
   ```

5. Intentá un cambio interactivo a la cuenta de servicio:
   ```bash
   su -s /usr/sbin/nologin - svc_metrics
   ```
   ```
   This account is currently not available.
   ```

**Preguntas**

- **Q13.** `useradd -r` eligió el UID `999` mientras que `ana` obtuvo `1000`. ¿Qué dos variables de `login.defs` produjeron cada número, y en qué dirección busca `useradd` en cada rango?
- **Q14.** Un colega ejecuta `useradd -p 'Str0ng-Transit!' bob` y la cuenta no puede iniciar sesión. ¿Qué está mal, y cuál es la forma correcta de usar `-p`?
- **Q15.** El campo 2 de shadow de `ana` era `!` inmediatamente después de `useradd` (`!!` en RHEL). ¿Estaba la cuenta *bloqueada*, o era otra cosa? ¿Cuál es la diferencia práctica?
- **Q16.** Nombrá dos desventajas operativas de `echo 'user:pass' | chpasswd` en un host administrativo compartido.
- **Q17.** Poner el shell en `/usr/sbin/nologin` bloquea las sesiones de shell de `su` y `ssh`. Nombrá una vía de acceso que **no** bloquea por sí sola.

---

## Ejercicio 4 — Grupos, primario vs. suplementario

**Pasos**

1. Creá dos grupos — uno común, uno de sistema:
   ```bash
   groupadd ops
   groupadd -r -g 940 deployers
   getent group ops deployers
   ```
   ```
   ops:x:1001:
   deployers:x:940:
   ```

2. Agregá `ana` a ambos, **anexando**:
   ```bash
   usermod -aG ops,deployers ana
   id ana
   getent group ops
   ```
   ```
   uid=1000(ana) gid=1000(ana) groups=1000(ana),940(deployers),1001(ops)
   ops:x:1001:ana
   ```

3. Observá que una sesión en curso no toma esto:
   ```bash
   su - ana -c 'id -nG'
   ```
   ```
   ana deployers ops
   ```
   ```bash
   # inside an already-open session of ana, `id -nG` would still print only: ana
   ```

4. Usá la herramienta de administración de grupos (`gpasswd`) — la forma canónica de delegar la pertenencia:
   ```bash
   useradd -m -s /bin/bash carla
   gpasswd -a carla ops
   gpasswd -A ana ops          # make ana the group administrator
   getent group ops
   getent gshadow ops
   ```
   ```
   Adding user carla to group ops
   ops:x:1001:ana,carla
   ops:!:ana:ana,carla
   ```

5. Cambiá el grupo primario para un solo comando y para todo un shell:
   ```bash
   su - carla -c 'id -gn'
   su - carla -c 'sg ops -c "id -gn"'
   su - carla -c 'umask; touch /tmp/f1; ls -l /tmp/f1'
   ```
   ```
   carla
   ops
   0022
   -rw-r--r-- 1 carla carla 0 Aug 27 09:31 /tmp/f1
   ```

6. Renombrá un grupo y observá qué sigue — y qué no — al cambio:
   ```bash
   groupmod -n platform ops
   getent group platform
   id ana
   ```
   ```
   platform:x:1001:ana,carla
   uid=1000(ana) gid=1000(ana) groups=1000(ana),940(deployers),1001(platform)
   ```

**Preguntas**

- **Q18.** ¿Qué hace exactamente `usermod -G ops ana` que `usermod -aG ops ana` no hace? Describí la falla que provoca en producción.
- **Q19.** `groupmod -n platform ops` actualizó `id ana` al instante, sin ejecutar ningún `usermod`. ¿Por qué? ¿Qué te dice esto sobre cómo se almacenan las pertenencias?
- **Q20.** Compará `newgrp platform` y `sg platform -c "cmd"`. ¿Cuándo pide contraseña cualquiera de los dos, y dónde está almacenada esa contraseña?
- **Q21.** Dá los dos comandos que quitan a `carla` de `platform`, y explicá por qué uno de ellos es peligroso.
- **Q22.** `getent gshadow platform` muestra los campos `ops:!:ana:ana,carla`. ¿Qué campo hace que `ana` pueda ejecutar `gpasswd -a` sobre ese grupo sin ser root?

---

## Ejercicio 5 — Envejecimiento de contraseñas, bloqueo y expiración

**Pasos**

1. Leé el registro completo de envejecimiento:
   ```bash
   chage -l ana
   ```
   ```
   Last password change					: Aug 27, 2026
   Password expires					: never
   Password inactive					: never
   Account expires						: never
   Minimum number of days between password change		: 0
   Maximum number of days between password change		: 99999
   Number of days of warning before password expires	: 7
   ```

2. Aplicá una política real — rotación de 90 días, mínimo de 1 día, aviso de 14 días, gracia de 7 días tras la expiración:
   ```bash
   chage -m 1 -M 90 -W 14 -I 7 ana
   getent shadow ana | awk -F: '{print "lastchg="$3" min="$4" max="$5" warn="$6" inactive="$7" expire="$8}'
   ```
   ```
   lastchg=20692 min=1 max=90 warn=14 inactive=7 expire=
   ```

3. Forzá un cambio en el próximo login, y confirmá la representación a nivel de datos:
   ```bash
   chage -d 0 ana
   getent shadow ana | cut -d: -f3
   chage -l ana | head -2
   ```
   ```
   0
   Last password change					: password must be changed
   Password expires					: password must be changed
   ```

4. Establecé una fecha dura de expiración de cuenta (baja de un contratista), y luego leela de vuelta:
   ```bash
   chage -E 2026-09-30 ana
   getent shadow ana | cut -d: -f8
   chage -l ana | grep 'Account expires'
   ```
   ```
   20726
   Account expires						: Sep 30, 2026
   ```

5. Bloqueá y desbloqueá la *contraseña*, observando el campo del hash:
   ```bash
   getent shadow carla | cut -c1-14
   passwd -l carla ;   getent shadow carla | cut -c1-15 ; passwd -S carla
   passwd -u carla ;   getent shadow carla | cut -c1-14 ; passwd -S carla
   ```
   ```
   carla:$y$j9T$
   passwd: password expired changed.
   carla:!$y$j9T$
   carla L 08/27/2026 0 99999 7 -1
   passwd: password expired changed.
   carla:$y$j9T$
   carla P 08/27/2026 0 99999 7 -1
   ```

6. Comparalo con el bloqueo a nivel de cuenta:
   ```bash
   usermod -L carla && passwd -S carla
   usermod -e 1 carla && chage -l carla | grep 'Account expires'
   usermod -U carla; usermod -e '' carla
   ```
   ```
   carla L 08/27/2026 0 99999 7 -1
   Account expires						: Jan 02, 1970
   ```

7. Restaurá a `ana` a un estado sano:
   ```bash
   chage -d $(( $(date +%s) / 86400 )) -E -1 ana
   chage -l ana | grep -E 'Last password|Account expires'
   ```
   ```
   Last password change					: Aug 27, 2026
   Account expires						: never
   ```

**Preguntas**

- **Q23.** Distinguí `max` (campo 5) de `inactive` (campo 7) de `expire` (campo 8). Esbozá la línea de tiempo para `-M 90 -I 7`.
- **Q24.** `passwd -l`, `usermod -L`, `chage -E 1` y `usermod -s /usr/sbin/nologin` todos "deshabilitan" una cuenta. El usuario tiene una **clave pública** SSH en `~/.ssh/authorized_keys`. ¿Cuál de las cuatro efectivamente detiene ese login? ¿Cuál es la acción correcta de baja?
- **Q25.** `passwd -S` imprimió `P`, y luego `L`. ¿Qué significa `NP` y por qué es un incidente?
- **Q26.** `chage -d 0 ana` pone el campo 3 en `0`. Explicá con precisión cómo difiere eso de una contraseña expirada bajo `-M 90`, y por qué `0` *no* es lo mismo que "el Epoch".
- **Q27.** ¿Por qué aparece `chage -E 1` (y no `-E 0`) en los runbooks de baja?
- **Q28.** ¿Cuáles de las operaciones de envejecimiento de este ejercicio puede realizar `ana` sobre sí misma, y cuáles requieren estrictamente root?

---

## Ejercicio 6 — Modificar cuentas existentes de forma segura

**Pasos**

1. Renombrá el login y reubicá el directorio home en una sola operación:
   ```bash
   pkill -u carla ; sleep 1
   usermod -l carlota -d /home/carlota -m carlota
   getent passwd carlota
   ls -ld /home/carlota; ls -ld /home/carla 2>&1
   ```
   ```
   carlota:x:1001:1002::/home/carlota:/bin/bash
   drwx------ 2 carlota carlota 4096 Aug 27 09:31 /home/carlota
   ls: cannot access '/home/carla': No such file or directory
   ```

2. Notá qué **no** tocó el renombrado:
   ```bash
   getent group carla
   getent group | grep -E ':(.*,)?carla(,|$)'
   ```
   ```
   carla:x:1002:
   ```
   Arreglalo explícitamente:
   ```bash
   groupmod -n carlota carla
   id carlota
   ```
   ```
   uid=1001(carlota) gid=1002(carlota) groups=1002(carlota),1001(platform)
   ```

3. Renumerá un UID y auditá las consecuencias:
   ```bash
   touch /srv/shared-report.txt && chown carlota /srv/shared-report.txt
   usermod -u 1500 carlota
   ls -ln /home/carlota/.bashrc /srv/shared-report.txt
   ```
   ```
   -rw-r--r-- 1 1500 1002 220 Aug 27 09:31 /home/carlota/.bashrc
   -rw-r--r-- 1 1001 1002   0 Aug 27 09:40 /srv/shared-report.txt
   ```

4. Localizá y repará cada archivo que quedó atrás:
   ```bash
   find / -xdev -uid 1001 -print 2>/dev/null
   find / -xdev -uid 1001 -exec chown 1500 {} +
   ls -ln /srv/shared-report.txt
   ```
   ```
   /srv/shared-report.txt
   -rw-r--r-- 1 1500 1002 0 Aug 27 09:40 /srv/shared-report.txt
   ```

5. Cambiá el shell de dos maneras y observá la barrera de política:
   ```bash
   usermod -s /bin/dash carlota && getent passwd carlota | cut -d: -f7
   cat /etc/shells
   su - carlota -c 'chsh -s /usr/bin/zsh'
   ```
   ```
   /bin/dash
   /bin/sh
   /bin/bash
   /usr/bin/dash
   chsh: "/usr/bin/zsh" is not listed in /etc/shells.
   ```

**Preguntas**

- **Q29.** `usermod -l` cambió solo el campo 1 de `/etc/passwd` (más `/etc/shadow`). Enumerá todos los demás lugares donde un nombre de login puede seguir apareciendo y que debés arreglar a mano.
- **Q30.** Después de `usermod -u 1500`, `/home/carlota/.bashrc` cambió de dueño pero `/srv/shared-report.txt` no. Enunciá la regla que sigue `usermod`, y escribí el comando que encuentra todos los archivos huérfanos en todo el sistema.
- **Q31.** ¿Por qué el paso 1 empezó con `pkill -u carlota`? ¿Qué hace `usermod` si el usuario está logueado?
- **Q32.** `usermod -d /home/new` sin `-m` tiene éxito al instante. Describí el estado roto resultante en el siguiente login del usuario.
- **Q33.** Root puede poner cualquier shell con `usermod -s`, pero `chsh` se negó. ¿Qué archivo impone eso, y qué más lo consulta?

---

## Ejercicio 7 — Borrar cuentas y cazar huérfanos

**Pasos**

1. Borrá a `carlota` **sin** eliminar sus datos, y observá el residuo:
   ```bash
   userdel carlota
   getent passwd carlota; echo "exit=$?"
   ls -ln /home/ | grep 1500
   getent group carlota
   ```
   ```
   exit=2
   drwx------ 2 1500 1002 4096 Aug 27 09:31 carlota
   ```
   *(El grupo privado de usuario `carlota` desapareció: `USERGROUPS_ENAB yes` lo eliminó porque ningún otro usuario lo tenía como grupo primario.)*

2. Encontrá cada archivo sin usuario o grupo propietario:
   ```bash
   find / -xdev \( -nouser -o -nogroup \) -printf '%u %g %p\n' 2>/dev/null
   ```
   ```
   1500 1002 /home/carlota
   1500 1002 /home/carlota/.bashrc
   1500 1002 /home/carlota/.profile
   1500 1002 /home/carlota/.bash_logout
   ```

3. Archivá y recuperá el espacio:
   ```bash
   tar --numeric-owner -czf /root/carlota-home.tar.gz -C /home carlota
   rm -rf /home/carlota
   find / -xdev \( -nouser -o -nogroup \) 2>/dev/null | wc -l
   ```
   ```
   0
   ```

4. Borrá a `ana` de la forma completa y confirmá que las cuatro bases de datos quedaron limpias:
   ```bash
   userdel -r ana
   ```
   ```
   userdel: ana mail spool (/var/mail/ana) not found
   ```
   ```bash
   for f in passwd shadow group gshadow; do echo "== $f"; grep -c '^ana:' /etc/$f; done
   getent group platform
   ```
   ```
   == passwd
   0
   == shadow
   0
   == group
   0
   == gshadow
   0
   platform:x:1001:
   ```

5. Eliminá los grupos ahora vacíos:
   ```bash
   groupdel platform
   groupdel deployers
   groupdel: cannot remove the primary group of user 'svc_metrics'  # if you try groupdel svc_metrics
   ```

**Preguntas**

- **Q34.** `userdel carlota` eliminó el grupo `carlota` pero `userdel -r ana` dejó `platform` en su lugar. Enunciá la regla que gobierna esto.
- **Q35.** `userdel -r` informó un mail spool faltante pero igual terminó con éxito. ¿Qué dos árboles de directorios elimina `-r`?
- **Q36.** Tenés que borrar un usuario que tiene un proceso en ejecución. `userdel` se niega. ¿Qué hace `-f`, y por qué `-f` sobre una cuenta *de sistema* con UID bajo es especialmente peligroso?
- **Q37.** ¿Por qué archivar con `tar --numeric-owner`? ¿Qué se rompe si lo omitís y restaurás en otro host?
- **Q38.** `groupdel` se negó a eliminar `svc_metrics`. Dá la secuencia de dos pasos que haría legítima la eliminación.

---

## Ejercicio 8 — Consistencia, bloqueo y la capa NSS

**Pasos**

1. Ejecutá los verificadores de integridad en modo de solo lectura:
   ```bash
   pwck -r
   grpck -r
   echo "grpck exit=$?"
   ```
   ```
   user 'lp': directory '/var/spool/lpd' does not exist
   user 'news': directory '/var/spool/news' does not exist
   pwck: no changes
   grpck exit=0
   ```

2. Inyectá un defecto y dejá que `pwck` lo encuentre:
   ```bash
   printf 'ghost:x:1600:1600::/home/ghost:/bin/bash\n' >> /etc/passwd
   pwck -r
   ```
   ```
   user 'ghost': no group 1600
   user 'ghost': directory '/home/ghost' does not exist
   no matching password file entry in /etc/shadow
   add user 'ghost' in /etc/shadow? No
   pwck: no changes
   ```

3. Reparalo con el editor *con bloqueo* en vez de un `vi` pelado:
   ```bash
   EDITOR=/bin/ed vipw <<'EOF'
   /^ghost:/d
   w
   q
   EOF
   pwck -r && echo CLEAN
   ```
   ```
   You have modified /etc/passwd.
   You may need to modify /etc/shadow for consistency.
   Please use the command 'vipw -s' to do so.
   CLEAN
   ```
   Comandos complementarios: `vipw -s` (shadow), `vigr` (group), `vigr -s` (gshadow).

4. Observá cómo la suite shadow convierte de ida y de vuelta (**leé la pregunta antes de ejecutar esto sobre algo que te importe**):
   ```bash
   cp -a /etc/shadow /root/shadow.safe
   pwunconv
   getent passwd root | cut -c1-24
   ls /etc/shadow 2>&1
   pwconv
   getent passwd root | cut -c1-14
   ```
   ```
   root:$y$j9T$e8Kq3Vt2...
   ls: cannot access '/etc/shadow': No such file or directory
   root:x:0:0:root
   ```
   Los equivalentes para grupos son `grpconv` / `grpunconv`.

5. Demostrá que `getent` no es `cat`:
   ```bash
   grep -c '' /etc/passwd
   getent passwd | wc -l
   grep ^passwd /etc/nsswitch.conf
   getent passwd 0
   ```
   ```
   21
   21
   passwd:         files systemd
   root:x:0:0:root:/root:/bin/bash
   ```

**Preguntas**

- **Q39.** `pwck` informó `directory '/var/spool/lpd' does not exist` y aun así dijo `no changes`. ¿Cuáles son las dos clases de problema que informa `pwck`, y cuáles puede arreglar realmente?
- **Q40.** ¿Qué hace exactamente `vipw` que `vi /etc/passwd` no hace? Nombrá el archivo que crea.
- **Q41.** ¿Qué le hizo `pwunconv` a la postura de seguridad del sistema, y cuál es la única razón legítima para ejecutarlo?
- **Q42.** En un host unido a LDAP o SSSD, `grep ^alice /etc/passwd` no devuelve nada pero `id alice` funciona. Explicalo, y dá el comando correcto para búsquedas de usuarios en scripts.
- **Q43.** `getent passwd 0` aceptó una clave numérica. Dá el equivalente para grupos, y decí qué código de salida devuelve `getent` cuando la clave no se encuentra.

---

## Ejercicio 9 — Trabajo final: diagnosticar un login roto

**Pasos**

1. Construí el escenario:
   ```bash
   useradd -m -s /bin/bash -G platform dario 2>/dev/null || { groupadd platform; useradd -m -s /bin/bash -G platform dario; }
   echo 'dario:Temp-Passw0rd!' | chpasswd
   su - dario -c 'echo LOGIN OK'
   ```
   ```
   LOGIN OK
   ```

2. Inyectá cuatro fallas independientes:
   ```bash
   usermod -L dario                                   # fault A
   chage -E 1 dario                                   # fault B
   sed -i 's#^dario:\(.*\):/bin/bash$#dario:\1:/bin/zsh#' /etc/passwd   # fault C
   chown -R 4242 /home/dario                          # fault D
   ```

3. Diagnosticá **sin** mirar los comandos de arriba. Trabajá de arriba hacia abajo a través del registro de la cuenta:
   ```bash
   getent passwd dario
   passwd -S dario
   chage -l dario
   ls -ld /home/dario
   test -x "$(getent passwd dario | cut -d: -f7)" || echo "shell missing or not executable"
   ```
   ```
   dario:x:1002:1003::/home/dario:/bin/zsh
   dario L 08/27/2026 0 99999 7 -1
   Last password change					: Aug 27, 2026
   Password expires					: never
   Password inactive					: never
   Account expires						: Jan 02, 1970
   Minimum number of days between password change		: 0
   Maximum number of days between password change		: 90
   Number of days of warning before password expires	: 7
   drwx------ 2 4242 dario 4096 Aug 27 09:52 /home/dario
   shell missing or not executable
   ```

4. Reparalas, una falla por vez, verificando después de cada una:
   ```bash
   usermod -U dario           && passwd -S dario | awk '{print $2}'
   usermod -e '' dario        && chage -l dario | grep 'Account expires'
   usermod -s /bin/bash dario && getent passwd dario | cut -d: -f7
   chown -R dario:dario /home/dario && ls -ld /home/dario
   su - dario -c 'echo LOGIN OK'
   ```
   ```
   P
   Account expires						: never
   /bin/bash
   drwx------ 2 dario dario 4096 Aug 27 09:52 /home/dario
   LOGIN OK
   ```

5. Limpiá todo el laboratorio:
   ```bash
   userdel -r dario; userdel -r ana 2>/dev/null; userdel -r carlota 2>/dev/null
   userdel svc_metrics; rm -rf /var/lib/metrics
   groupdel platform 2>/dev/null; groupdel deployers 2>/dev/null
   cp -a /root/acct-backup/{passwd,shadow,group,gshadow} /etc/
   pwck -r && grpck -r && echo RESTORED
   ```

**Preguntas**

- **Q44.** Ordená las cuatro fallas por *síntoma observable*: cuál produce "Permission denied", cuál "This account is currently not available", cuál "Your account has expired", cuál un retroceso silencioso a `/bin/sh` o una desconexión inmediata.
- **Q45.** La falla D dejó el directorio home perteneciendo al UID `4242`. El usuario todavía puede autenticarse — ¿qué falla exactamente, y en qué etapa de la secuencia de login?
- **Q46.** ¿Qué único comando habría mostrado las fallas A y B juntas, y cuál habría mostrado la C?
- **Q47.** Las fallas A y B son ambas "bloqueos". Si un auditor pregunta "¿esta cuenta fue deshabilitada o solo se le bloqueó la contraseña?", ¿qué campo de qué archivo responde la pregunta, y qué se almacena ahí?

---

## Referencia de comandos para este objetivo

| Tarea | Comando | Archivos afectados |
|---|---|---|
| Crear usuario | `useradd -m -s SHELL -c GECOS -G g1,g2 name` | passwd, shadow, group, gshadow, subuid, subgid |
| Ver/cambiar los defaults de useradd | `useradd -D [-s SHELL]` | `/etc/default/useradd` |
| Modificar usuario | `usermod -aG` / `-l` / `-d -m` / `-u` / `-s` / `-L` / `-U` / `-e` | passwd, shadow, group |
| Borrar usuario | `userdel [-r] [-f] name` | los cuatro (+ home, mail spool) |
| Crear/modificar/borrar grupo | `groupadd [-r] [-g]` · `groupmod -n -g` · `groupdel` | group, gshadow |
| Pertenencia a grupos + administradores | `gpasswd -a / -d / -A / -M / -r` | group, gshadow |
| Contraseña | `passwd [-l -u -e -d -S -n -x -w -i]` · `chpasswd` | shadow |
| Envejecimiento | `chage [-l -d -m -M -W -I -E]` | shadow |
| Consulta (con NSS) | `getent passwd|group|shadow [key]` · `id` · `groups` | — |
| Integridad | `pwck` · `grpck` | passwd/shadow, group/gshadow |
| Edición segura | `vipw` · `vipw -s` · `vigr` · `vigr -s` | con archivos de bloqueo |
| Conversión shadow | `pwconv` / `pwunconv` · `grpconv` / `grpunconv` | passwd↔shadow, group↔gshadow |

---

<details>
<summary><strong>Respuestas</strong> (clic para expandir)</summary>

### Ejercicio 0

**A1.** Un `cp` simple crea las copias con la umask del *invocante* y la hora actual, así que `/etc/shadow` quedaría como `0644 root:root` — hashes de contraseñas legibles por todo el mundo sentados en `/root` (y, peor aún, si alguna vez restaurás esa copia sobre `/etc/shadow`, propagás el modo incorrecto). `cp -a` (`--archive` = `-dR --preserve=all`) conserva modo, propiedad, marcas de tiempo y ACLs, así que el respaldo es una imagen fiel y restaurable.

**A2.** `/etc/passwd` y `/etc/group` son legibles por todo el mundo (`0644`) porque los programas comunes deben resolver UID→nombre y GID→nombre constantemente — `ls -l`, `ps`, `find` lo hacen todos, como usuarios sin privilegios. `/etc/shadow` y `/etc/gshadow` son `0640 root:shadow` porque contienen los hashes de contraseñas; dejar los hashes legibles por todo el mundo invita a la fuerza bruta offline. La división es la **suite de contraseñas shadow** (shadow-utils): el hash se movió fuera del campo 2 de `/etc/passwd`, que ahora contiene el marcador de posición `x`.

**A3.** `/usr/bin/passwd` (y `su`, `chage`, `gpasswd`, `newgrp`, `chsh`) — son **setuid root** (`-rwsr-xr-x root root`), así que corren con el UID efectivo de root y pueden leer/escribir `/etc/shadow`. Algunas distribuciones usan en cambio binarios setgid `shadow` más ayudantes de PAM (`/usr/sbin/unix_chkpwd`), que es por lo que la propiedad de grupo es `shadow`.

### Ejercicio 1

**A4.** `x` significa "el hash real está en `/etc/shadow`" — es un marcador de posición, no una contraseña. Si vaciás el campo (`root::0:0:...`) en un sistema donde `/etc/shadow` tampoco tiene entrada, la cuenta **no tiene contraseña en absoluto**: `login` y `su` conceden acceso sin preguntar. Cuando sí existe una entrada de shadow, `x` frente a cualquier otra cosa es en gran medida ignorado por el PAM moderno, pero el valor correcto y portable es `x`.

**A5.**
- `*` — una cadena de hash inválida. Ninguna contraseña puede coincidir jamás. Marcador convencional para una cuenta de sistema que nunca debe autenticarse por contraseña. **No** es un "bloqueo" en el sentido de shadow-utils.
- `!` — bloqueada *y* sin hash debajo (estado típico justo después de `useradd` en Debian).
- `!!` — el marcador de "contraseña nunca establecida" de Red Hat/Fedora; funcionalmente equivalente a `!`.
- `!$y$j9T$...` — un **hash válido prefijado con `!`**: esto es `passwd -l` / `usermod -L`. Quitar el `!` (`passwd -u`) restaura la contraseña original.
- **vacío** — no se requiere contraseña. Cualquiera que llegue al prompt de login entra. Esto es un hallazgo, siempre.

Solo el campo vacío permite un "login con contraseña" (uno sin contraseña). Ninguno de los otros lo hace.

**A6.** La lista de miembros de `/etc/group` (campo 4) registra solo pertenencias **suplementarias**. La pertenencia de `root` al grupo `0` es *primaria*, almacenada en el campo 4 de `/etc/passwd`, no en `/etc/group`. `id` fusiona ambas fuentes, que es por lo que muestra `groups=0(root)`. Lo mismo vale para todo grupo privado de usuario.

**A7.** El campo 3 de `/etc/gshadow` es la lista separada por comas de **administradores del grupo** — usuarios habilitados a ejecutar `gpasswd -a`/`-d` sobre ese grupo sin ser root. Lo escribe `gpasswd -A user1,user2 groupname`. (Los campos son: `name : encrypted-group-password : administrators : members`.)

**A8.** `date -u -d "1970-01-01 UTC +20441 days" +%F` → `2025-12-19`. Un valor de `0` en el campo 3 **no** significa el 1 de enero de 1970; es el centinela especial que significa **"la contraseña debe cambiarse en el próximo login"** (establecido por `chage -d 0` o `passwd -e`). Un campo 3 *vacío* significa que la información de envejecimiento está ausente.

### Ejercicio 2

**A9.** `/etc/login.defs` es **política de todo el sistema** consultada por muchas herramientas de la suite shadow (`useradd`, `usermod`, `userdel`, `passwd`, `su`, `login`, el `pam_unix` de PAM): rangos de ID, método de hashing, envejecimiento por defecto, umask. `/etc/default/useradd` contiene **valores por defecto de creación exclusivos de `useradd`**: el directorio HOME base, el shell y el grupo primario por defecto, la ruta del esqueleto, el comportamiento del mail spool, e `INACTIVE`/`EXPIRE`. Política vs. valores por defecto por herramienta.

**A10.** `CREATE_HOME` en `/etc/login.defs` — `yes` en RHEL, sin definir/`no` en Debian. La opción determinista es `-m` (`--create-home`); su contraparte es `-M` (`--no-create-home`). Pasá siempre una de las dos explícitamente en la automatización.

**A11.** Con `USERGROUPS_ENAB yes`: (1) **en la creación**, `useradd` crea un *grupo privado de usuario* con el mismo nombre que el usuario y lo usa como grupo primario, en vez de recurrir a `GROUP=100` (`users`) de `/etc/default/useradd`; (2) **en el borrado**, `userdel` elimina ese grupo — pero solo si tiene el nombre del usuario y ningún otro usuario lo tiene todavía como grupo primario. También hace que una `umask 002` sea segura para directorios compartidos, ya que el grupo por defecto de cada usuario contiene solo a ese usuario.

**A12.** No. `/etc/skel` se copia **una vez**, en el momento de `useradd -m`; los agregados posteriores solo alcanzan a las cuentas creadas después. La sobrescritura por invocación es `-k /path/to/skel` (`--skel`), que solo se respeta junto con `-m`.

### Ejercicio 3

**A13.** `ana` salió de `UID_MIN`/`UID_MAX` (1000–60000) y `useradd` busca en ese rango **hacia arriba** desde el valor libre más bajo ≥ `UID_MIN`. `svc_metrics` salió de `SYS_UID_MIN`/`SYS_UID_MAX` (100–999) por el `-r`, y ahí `useradd` busca **hacia abajo** desde `SYS_UID_MAX`, que es por lo que eligió 999. Deliberado: los UID de sistema crecen hacia abajo, los UID humanos hacia arriba, así que los dos nunca colisionan.

**A14.** `useradd -p` espera un **hash ya cifrado**, exactamente como será escrito en el campo 2 de `/etc/shadow` — no una contraseña en texto plano. La cadena literal `Str0ng-Transit!` de `bob` se almacenó como si fuera un hash, no coincide con nada, y la cuenta queda efectivamente bloqueada. Uso correcto:
```bash
useradd -m -p "$(openssl passwd -6 -stdin <<< 'Str0ng-Transit!')" bob
# or: mkpasswd -m sha512crypt   (Debian: package whois)
```
En la práctica, preferí `chpasswd` o `passwd`, porque `-p` pone el hash en la tabla de procesos y en el historial del shell.

**A15.** **No estaba bloqueada en el sentido de `passwd -l`** — no había contraseña que bloquear. `!` acá significa *nunca se estableció una contraseña válida*. La diferencia práctica importa al momento del desbloqueo: `passwd -u` sobre una cuenta cuyo campo es solo `!` produce `passwd: unlocking the password would result in a passwordless account` y se niega (a menos que se fuerce con `-f`), mientras que sobre `!$y$...` simplemente restaura la contraseña anterior. `passwd -S` informa `L` para ambos casos.

**A16.** (1) El texto plano termina en el archivo de historial del shell (`~/.bash_history`) y, durante la vida del pipeline, en `/proc/<pid>/cmdline`, visible con `ps` para cualquier usuario local. (2) Queda capturado por la auditoría del shell/`auditd`/la grabación de sesión con `script` y por el scrollback de la terminal, así que la credencial queda registrada de forma duradera en algún lugar que no controlás. Más seguro: `chpasswd < file` con un archivo `0600` eliminado después, o `passwd` de forma interactiva, o alimentar un hash precalculado con `chpasswd -e`.

**A17.** Cualquier cosa que no necesite que el shell de login sea un shell real — lo más importante, **`sudo -u svc_metrics <cmd>`**, `su -s /bin/bash - svc_metrics`, y el arranque de demonios vía `User=` de systemd (systemd ejecuta el `ExecStart` de la unidad, no el shell de la cuenta). Los *comandos forzados* de SSH y el internal-sftp configurado en `sshd_config` también pueden sortearlo. `nologin` es una conveniencia, no una frontera de seguridad; la frontera es `usermod -L` más `usermod -e 1`, o eliminar la cuenta.

### Ejercicio 4

**A18.** `usermod -G ops ana` **reemplaza** toda la lista de grupos suplementarios por exactamente `ops`. Cualquier otra pertenencia — `sudo`, `docker`, `wheel`, `platform` — se descarta silenciosamente. El incidente clásico de producción es un administrador agregándose a un grupo nuevo y perdiendo `sudo`/`wheel` en el mismo comando, para descubrirlo después de cerrar sesión. `-a` (`--append`) solo es válido junto con `-G` y agrega sin quitar.

**A19.** Porque la pertenencia a grupos se almacena **por nombre**, no por ID: el campo 4 de `/etc/group` contiene la cadena literal `ana`. Renombrar el *grupo* reescribe solo el campo del nombre propio del grupo; la lista de miembros queda intacta, e `id` resuelve el GID de nuevo en cada llamada. El corolario es el caso inverso — renombrar un **usuario** con `usermod -l` *sí* reescribe las listas de miembros, porque esas almacenan el nombre de login.

**A20.** `newgrp platform` inicia un **shell nuevo** cuyo GID real y efectivo es `platform` (salí con `exit`/`Ctrl-D` para volver). `sg platform -c "cmd"` ejecuta un solo comando con ese GID primario. Ninguno pregunta si el usuario invocante ya es miembro del grupo. Si el usuario **no** es miembro, ambos piden la **contraseña del grupo**, almacenada como hash en el campo 2 de `/etc/gshadow` y establecida con `gpasswd groupname`. Un `!` o `*` ahí significa "sin contraseña de grupo" y el prompt nunca puede tener éxito — que es el estado recomendado; `gpasswd -r groupname` elimina una contraseña de grupo.

**A21.**
```bash
gpasswd -d carla platform          # correct: surgical removal from one group
usermod -G platform,otros carla    # dangerous: rewrites the whole list
```
La forma `usermod -G` te obliga a volver a enumerar *cada* grupo que el usuario debe conservar; omitir uno lo revoca silenciosamente. Usá `gpasswd -d`, o construí la lista a partir de `id -nG` antes de reescribirla.

**A22.** El campo 3, la lista de administradores (`ana`). Como `gpasswd` es setuid root, revisa esa lista y le permite a `ana` agregar/quitar miembros de `platform` sin ser root completo. Notá que `getent gshadow` requiere root para leerse.

### Ejercicio 5

**A23.**
- **`max` (campo 5, `chage -M`)** — la vida útil de la contraseña en días. Después de `lastchg + max`, la contraseña está expirada: el usuario todavía puede iniciar sesión pero se lo obliga a cambiarla inmediatamente.
- **`inactive` (campo 7, `chage -I`)** — un período de gracia *posterior* a la expiración de la contraseña. Una vez que pasa `lastchg + max + inactive`, la **cuenta** queda deshabilitada; sin login en absoluto, incluso con la contraseña correcta.
- **`expire` (campo 8, `chage -E`)** — una fecha absoluta de fin para la cuenta, independiente de cualquier actividad de contraseña.

Línea de tiempo para `-M 90 -I 7`, contando desde el último cambio de contraseña: días 0–75 normal · días 76–89 aviso (`-W 14`) · día 90 contraseña expirada, cambio forzado en el login · días 90–97 gracia · día 98 cuenta inactiva, login rechazado.

**A24.** Solo **`chage -E 1`** (equivalentemente `usermod -e`) detiene el login basado en clave: la expiración de cuenta la impone la pila de gestión de *account* de PAM (`pam_unix account`), que corre después de cualquier método de autenticación, incluida la de clave pública. `passwd -l` y `usermod -L` tocan solo el hash de la contraseña y la autenticación por clave pública los sortea por completo — el error de baja más común de todos. `usermod -s /usr/sbin/nologin` bloquea una sesión de shell pero no `ssh user@host 'command'` en toda configuración, y tampoco las sesiones de solo reenvío de puertos. Baja correcta: `usermod -L -e 1 -s /usr/sbin/nologin user`, más eliminar/renombrar `~/.ssh/authorized_keys`, más matar las sesiones vivas (`pkill -u user`).

**A25.** El campo 2 de `passwd -S` es el estado de la contraseña: `P` = contraseña utilizable, `L` = bloqueada, `NP` = **sin contraseña** — el campo 2 de `/etc/shadow` está vacío. Cualquiera que llegue a un prompt de login (consola, `su`, o SSH con `PermitEmptyPasswords yes`) se autentica sin credencial. Auditalo con:
```bash
awk -F: '($2 == "") { print $1 }' /etc/shadow
```

**A26.** Bajo `-M 90`, la expiración se *calcula*: `lastchg + 90 < today`. `chage -d 0` pone `lastchg` en el centinela `0`, que shadow-utils interpreta incondicionalmente como "debe cambiarse ahora", sin importar `max` — `chage -l` imprime `password must be changed` en vez de una fecha. **No** es el 1 de enero de 1970: el Epoch en sí no es representable en el campo 3, y un campo *vacío* significa "sin datos de envejecimiento". `passwd -e user` es el front end equivalente.

**A27.** `-E 0` es ambiguo con la codificación "vacío/nunca expira" y las versiones viejas de shadow-utils trataban `0` como "sin expiración"; `-E 1` es un valor inequívoco y definitivamente en el pasado (2 de enero de 1970) que toda versión lee como expirado. `chage -E -1` (o `usermod -e ''`) es la forma documentada de limpiar el campo.

**A28.** Por sí misma, `ana` solo puede ejecutar `chage -l ana` (leer su propio registro de envejecimiento) y `passwd` para cambiar su propia contraseña, sujeta a la restricción de días `min` — con `-m 1` puesto, un segundo cambio el mismo día se rechaza (`You must wait longer to change your password`). Toda escritura sobre el registro de otro usuario, y todo uso de `-d -m -M -W -I -E`, requiere root.

### Ejercicio 6

**A29.** `usermod -l` reescribe el nombre de login en `/etc/passwd`, `/etc/shadow`, y las listas de miembros de `/etc/group` y `/etc/gshadow`. **No** toca: la ruta del directorio home ni su nombre (necesita `-d -m`), el **nombre del grupo privado de usuario** (necesita `groupmod -n`), el mail spool `/var/mail/<name>`, `/etc/sudoers` y `/etc/sudoers.d/*`, cron (`/var/spool/cron/crontabs/<name>`), trabajos de at, los comentarios de `~/.ssh/authorized_keys`, `/etc/subuid` y `/etc/subgid`, las unidades de usuario de systemd, las entradas de ACL (`getfacl -R` almacena nombres), los registros de cuota, y cualquier cosa en bases de datos de aplicaciones.

**A30.** La regla (de `usermod(8)`): cuando el UID cambia, `usermod` reasigna la propiedad solo de los archivos **dentro del directorio home del usuario** y el mail spool. Los archivos en otros lados conservan el UID numérico viejo y se vuelven huérfanos — o, peor, pertenecen silenciosamente a quien sea que reciba ese UID a continuación. El barrido de todo el sistema:
```bash
find / -xdev -uid 1001 -exec chown -h 1500 {} +      # before the old UID is reused
find / -xdev \( -nouser -o -nogroup \) -ls           # after the fact
```
Ejecutalo por sistema de archivos (`-xdev` más una invocación por punto de montaje) y acordate de los sistemas de archivos de red y de los backups.

**A31.** Porque `usermod` se niega a modificar una cuenta con procesos en ejecución para los campos que los romperían (`usermod: user carlota is currently used by process 812`), y porque mover un directorio home por debajo de una sesión viva deja el `$HOME` de esa sesión apuntando a una ruta que ya no existe. `pkill -u` (y luego verificar con `pgrep -u`, y `loginctl terminate-user` en hosts con systemd) hace el cambio atómico desde la perspectiva del usuario.

**A32.** El campo 6 de `/etc/passwd` apunta a un directorio que no existe. En el siguiente login, PAM/`login` no pueden hacer `chdir` ahí; la mayoría de los sistemas registran `Could not chdir to home directory /home/new: No such file or directory` y dejan al usuario en `/` con `$HOME` apuntando a la ruta inexistente. Todo lo que lee `$HOME` entonces falla o revierte silenciosamente a los valores por defecto: sin `.bashrc`, sin `~/.ssh/authorized_keys` (así que el SSH por clave deja de funcionar), sin dotfiles, y las escrituras a `~` fallan. `-m` (`--move-home`) mueve el contenido y arregla la propiedad.

**A33.** `/etc/shells` — la lista de shells de *login* válidos. `chsh` rechaza cualquier ruta que no esté listada cuando lo invoca un usuario no root. También lo consultan `vsftpd` y otros demonios FTP (un usuario cuyo shell no está en `/etc/shells` es rechazado), el manejo de `--shell` de `su`, y `getusershell(3)` en general. Root puede sortearlo con `usermod -s`, que no realiza tal validación — que es precisamente cómo un shell inutilizable llega a `/etc/passwd`.

### Ejercicio 7

**A34.** `userdel` elimina el grupo primario del usuario solo si (a) está puesto `USERGROUPS_ENAB yes`, (b) el grupo tiene el **mismo nombre que el usuario**, y (c) **ningún otro usuario** lo tiene todavía como su grupo primario. `carlota` cumplía las tres. `platform` era un grupo *suplementario*, con otro nombre y compartido con otros, así que `userdel` solo sacó a `ana` de su lista de miembros.

**A35.** `-r` (`--remove`) elimina el **directorio home y todo su contenido**, más el **mail spool** (`/var/mail/<user>` o `/var/spool/mail/<user>`). Un mail spool faltante es una advertencia, no un error. Notá lo que `-r` *no* elimina: los archivos que el usuario posee en cualquier otro lado del sistema — trabajos de cron, `/tmp`, `/srv`, árboles de proyectos compartidos.

**A36.** `-f` (`--force`) borra la cuenta incluso si el usuario está logueado, elimina el directorio home incluso cuando no pertenece al usuario, y elimina el grupo del usuario incluso si es el grupo primario de otro usuario. Sobre una cuenta de sistema con UID bajo esto puede borrar un directorio compartido (`/var/lib/<service>` puesto como home de esa cuenta) o destruir un grupo del que dependen otros demonios — una caída de servicio entregada por un comando de limpieza. Siempre `pgrep -u`, `lsof -u`, y leé `getent passwd <user>` antes de recurrir a `-f`.

**A37.** Una vez que la cuenta desapareció no queda ninguna correspondencia nombre↔UID, así que `tar` almacenaría el propietario numérico bajo una resolución de nombre *obsoleta* — o, al restaurar, mapearía el **nombre** archivado sobre el UID que lo tenga actualmente en el host destino, entregando los datos privados del viejo usuario a una cuenta no relacionada. `--numeric-owner` almacena y restaura los IDs numéricos crudos, manteniendo los datos inequívocamente huérfanos hasta que los reasignes deliberadamente.

**A38.**
```bash
userdel svc_metrics      # remove the user whose primary group it is
groupdel svc_metrics     # now the group has no dependents
```
Verificá primero que no queden dependientes:
```bash
awk -F: -v gid=999 '$4==gid {print $1}' /etc/passwd
```

### Ejercicio 8

**A39.** `pwck` informa (1) **problemas estructurales/de consistencia** — cantidad de campos incorrecta, UID/GID no numérico, nombre de login o UID duplicado, una entrada en `/etc/passwd` sin línea correspondiente en `/etc/shadow` y viceversa, valores de campo malos en `/etc/shadow`; y (2) **problemas de aviso** — un directorio home que no existe, un shell de login inválido, un GID sin grupo. Puede *arreglar* solo la primera clase, y solo interactivamente: ofrece borrar las líneas corruptas o agregar la entrada de shadow faltante (`-r` lo pone en solo lectura, respondiendo "no" a todo; `-q` informa solo errores). Los hallazgos de aviso, como `/var/spool/lpd`, son normales en un sistema sin ese servicio instalado y `pwck` nunca los "arregla". `grpck` hace lo mismo para `/etc/group` y `/etc/gshadow`, incluida la verificación de que cada miembro listado exista realmente en `/etc/passwd`.

**A40.** `vipw` (y `vigr`) toman un **bloqueo** — crea `/etc/passwd.lock` (respectivamente `/etc/group.lock`, `/etc/shadow.lock`, `/etc/gshadow.lock`), el mismo bloqueo que respetan `useradd`/`usermod`/`passwd`. Sin él, un `useradd` concurrente y una edición a mano pueden escribir cada uno una copia completa del archivo y uno pierde silenciosamente el cambio del otro — una forma real de perder cuentas. `vipw` además edita una copia temporal, valida que parsee antes de instalarla, preserva el modo/propietario original, y te recuerda ejecutar `vipw -s` para el archivo shadow correspondiente. Nunca edites estos archivos con un editor pelado.

**A41.** `pwunconv` fusiona los hashes de `/etc/shadow` de vuelta al campo 2 del `/etc/passwd` **legible por todo el mundo** y borra `/etc/shadow` — el hash de contraseña de cada usuario se vuelve legible por todo usuario local y todo proceso, listo para cracking offline, y todos los campos de envejecimiento (min/max/warn/inactive/expire) se **descartan**, no solo se ocultan. Esencialmente no hay razón para ejecutarlo en un sistema moderno; el caso legítimo es migrar a o depurar una herramienta heredada o un Unix antiguo previo a la suite shadow, y el seguimiento correcto es un `pwconv` inmediato (que recrea `/etc/shadow` a partir de `/etc/passwd` + los valores por defecto de `/etc/login.defs` — los datos de envejecimiento previamente descartados no vuelven).

**A42.** Los archivos locales son solo una fuente **NSS**. `/etc/nsswitch.conf` lista la cadena de búsqueda para las bases de datos `passwd`/`group`/`shadow` (`files sss`, `files ldap`, `files systemd`, …), y a `alice` la sirve el directorio, sin aparecer nunca en `/etc/passwd`. `grep` ve solo el backend `files`. Usá las herramientas conscientes de NSS: `getent passwd alice`, `getent group ops`, `id alice`. En scripts, `getent` es la única opción correcta — y sale con `2` cuando la clave no se encuentra, lo que lo hace directamente comprobable.

**A43.** `getent group 0` (o `getent group root`). `getent` sale con `0` en caso de éxito, `1` si la base de datos es desconocida, **`2` si la clave no fue encontrada**, y `3` si la base de datos no soporta enumeración.

### Ejercicio 9

**A44.**
- **Falla C** (shell `/bin/zsh` no instalado) — `su - dario` imprime `su: failed to execute /bin/zsh: No such file or directory`; por SSH la sesión se autentica y luego se cierra inmediatamente. Algunos servicios recurren a `/bin/sh`; `login` y `su` no.
- **Falla A** (`usermod -L`) — aparece el prompt de contraseña y la contraseña correcta es rechazada: `su: Authentication failure` / `Permission denied, please try again`. El SSH por clave no se ve afectado.
- **Falla B** (`chage -E 1`) — la autenticación *tiene éxito*, y luego la gestión de account de PAM se niega: `Your account has expired; please contact your system administrator`.
- **Falla D** (home perteneciente a 4242) — el login tiene éxito, y luego `Could not chdir to home directory /home/dario: Permission denied`, y la sesión aterriza en `/` con un `$HOME` roto.

**A45.** La autenticación (PAM auth) y la validación de cuenta (PAM account) pasan ambas. La falla está en la **configuración de la sesión**: `login`/`sshd` no pueden hacer `chdir` a un directorio `0700` perteneciente a otro UID, así que no se cargan dotfiles, `~/.ssh/authorized_keys` es ilegible (lo que rompe el *siguiente* login por clave y suele ser el primer síntoma reportado), y toda escritura a `~` falla con `Permission denied`. Notá que el `StrictModes yes` de `sshd` además rechazará de plano la autenticación por clave pública cuando `~` o `~/.ssh` no pertenezcan al usuario.

**A46.** `chage -l dario` muestra tanto el estado de la contraseña como la expiración de la cuenta en una sola pantalla (la falla B explícitamente; la falla A aparece como `L` bajo `passwd -S dario`, y la combinación `passwd -S` + `chage -l` es el triaje estándar de dos comandos). La falla C es visible en el campo 7 de `getent passwd dario` — verificá que el shell sea real con `test -x` y contra `/etc/shells`.

**A47.** `/etc/shadow` responde ambas, en campos distintos. El **campo 2** empezando con `!` (o `!!`) significa que se bloqueó la *contraseña* — reversible con `passwd -u`, y sorteable por claves SSH. El **campo 8** conteniendo una cuenta de días pasada (p. ej. `1`) significa que la *cuenta* fue expirada — una deshabilitación real, impuesta para todo método de autenticación. Un auditor que pregunta "¿deshabilitada o con contraseña bloqueada?" está preguntando cuál de esos dos campos está puesto; una baja apropiada pone ambos.

</details>

---

## Fuentes

- LPI — Exam 101-500 Objectives (LPIC-1 v5.0): <https://www.lpi.org/our-certifications/exam-101-objectives/>
- LPI — Exam 102-500 Objectives, donde se examina el Tema 107.1: <https://www.lpi.org/our-certifications/exam-102-objectives/>
- shadow-utils (upstream de `useradd`, `usermod`, `userdel`, `chage`, `gpasswd`, `pwck`, `vipw`): <https://github.com/shadow-maint/shadow>
- `passwd(5)` — formato del archivo de contraseñas: <https://man7.org/linux/man-pages/man5/passwd.5.html>
- `shadow(5)` — formato del archivo de contraseñas shadow: <https://man7.org/linux/man-pages/man5/shadow.5.html>
- `group(5)` / `gshadow(5)`: <https://man7.org/linux/man-pages/man5/group.5.html> · <https://man7.org/linux/man-pages/man5/gshadow.5.html>
- `login.defs(5)` — configuración de la suite shadow: <https://man7.org/linux/man-pages/man5/login.defs.5.html>
- `useradd(8)` · `usermod(8)` · `userdel(8)`: <https://man7.org/linux/man-pages/man8/useradd.8.html> · <https://man7.org/linux/man-pages/man8/usermod.8.html> · <https://man7.org/linux/man-pages/man8/userdel.8.html>
- `chage(1)` · `passwd(1)` · `gpasswd(1)` · `newgrp(1)` · `sg(1)`: <https://man7.org/linux/man-pages/man1/chage.1.html> · <https://man7.org/linux/man-pages/man1/passwd.1.html> · <https://man7.org/linux/man-pages/man1/gpasswd.1.html>
- `pwck(8)` · `grpck(8)` · `vipw(8)` · `pwconv(8)`: <https://man7.org/linux/man-pages/man8/pwck.8.html> · <https://man7.org/linux/man-pages/man8/vipw.8.html> · <https://man7.org/linux/man-pages/man8/pwconv.8.html>
- `getent(1)` y `nsswitch.conf(5)` (GNU C Library): <https://man7.org/linux/man-pages/man1/getent.1.html> · <https://man7.org/linux/man-pages/man5/nsswitch.conf.5.html>
- `crypt(5)` — prefijos de hash de contraseña (`$1$`, `$5$`, `$6$`, `$y$`): <https://man7.org/linux/man-pages/man5/crypt.5.html>
- Debian Policy / asignación de UID y GID de `base-passwd`: <https://www.debian.org/doc/debian-policy/ch-opersys.html#uid-and-gid-classes>