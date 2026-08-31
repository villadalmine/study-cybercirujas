# 101.3 — Cambiar de runlevel / boot target y apagar o reiniciar el sistema

**Examen:** LPIC-1 101-500 (v5.0) · **Peso:** 4.69
**Archivos, términos y utilidades clave:** `/etc/inittab`, `shutdown`, `init`, `/etc/init.d/`, `telinit`, `systemd`, `systemctl`, `/etc/systemd/`, `/usr/lib/systemd/`, `wall`

---

## Entorno de laboratorio y seguridad

> **Ejecutá cada ejercicio dentro de una VM descartable o de un snapshot que puedas revertir.** Varios pasos cambian el boot target por defecto, aíslan targets, matan procesos y reinician la máquina. Nunca los corras en una estación de trabajo de la que dependas, ni en un host compartido sin una ventana de mantenimiento.

Laboratorio recomendado:

| Nodo | Propósito | Imagen sugerida |
|---|---|---|
| `node01` | host con systemd y una sesión gráfica instalada | Rocky Linux 9 / Fedora / Debian 12 |
| `node02` (opcional) | segunda sesión SSH para observar los broadcasts de `wall` | cualquiera |
| contenedor | inspección de solo lectura de un `/etc/inittab` estilo SysV | `docker.io/library/debian:8` o Devuan |

Todos los comandos se ejecutan como `root` salvo que se indique lo contrario. Donde se muestra la salida, tratala como *representativa*: los timestamps, los PIDs y las rutas de inodos van a diferir en tu sistema. Lo que sí debe coincidir es la **forma** de la salida.

---

## Ejercicio 1 — Mapear el espacio de targets antes de tocarlo

**Objetivo:** describir el sistema en ejecución con el vocabulario propio de systemd (units, targets, targets aislables) en vez de adivinar a partir del folclore de los runlevels.

1. Confirmá que el PID 1 realmente es systemd, y leé su versión:

   ```console
   # ps -p 1 -o pid,comm,args --no-headers
       1 systemd /usr/lib/systemd/systemd --switched-root --system --deserialize 31
   # systemctl --version | head -n 1
   systemd 252 (252-46.el9)
   ```

2. Preguntá a qué target arranca el sistema por defecto, y dónde vive físicamente esa respuesta:

   ```console
   # systemctl get-default
   graphical.target
   # ls -l /etc/systemd/system/default.target
   lrwxrwxrwx. 1 root root 40 Aug 20 11:02 /etc/systemd/system/default.target -> /usr/lib/systemd/system/graphical.target
   ```

3. Listá cada unit de tipo target actualmente cargada y activa:

   ```console
   # systemctl list-units --type=target --state=active --no-pager
   UNIT                   LOAD   ACTIVE SUB    DESCRIPTION
   basic.target           loaded active active Basic System
   cryptsetup.target      loaded active active Local Encrypted Volumes
   getty.target           loaded active active Login Prompts
   graphical.target       loaded active active Graphical Interface
   local-fs.target        loaded active active Local File Systems
   multi-user.target      loaded active active Multi-User System
   network-online.target  loaded active active Network is Online
   ...
   ```

4. Leé la definición de `graphical.target` —incluidos los drop-ins— con `systemctl cat`:

   ```console
   # systemctl cat graphical.target
   # /usr/lib/systemd/system/graphical.target
   [Unit]
   Description=Graphical Interface
   Documentation=man:systemd.special(7)
   Requires=multi-user.target
   Wants=display-manager.service
   Conflicts=rescue.service rescue.target
   After=multi-user.target rescue.service rescue.target display-manager.service
   AllowIsolate=yes
   ```

5. Recorré el árbol de dependencias un nivel hacia abajo:

   ```console
   # systemctl list-dependencies graphical.target --type=target
   graphical.target
   ● └─multi-user.target
   ●   ├─basic.target
   ●   │ ├─paths.target
   ●   │ ├─slices.target
   ●   │ ├─sockets.target
   ●   │ ├─sysinit.target
   ●   │ └─timers.target
   ●   ├─getty.target
   ●   ├─nfs-client.target
   ●   └─remote-fs.target
   ```

6. Averiguá qué targets son argumentos legales para `isolate`:

   ```console
   # grep -l 'AllowIsolate=yes' /usr/lib/systemd/system/*.target
   /usr/lib/systemd/system/emergency.target
   /usr/lib/systemd/system/graphical.target
   /usr/lib/systemd/system/multi-user.target
   /usr/lib/systemd/system/rescue.target
   ...
   ```

**Comprobá tu comprensión**

- **Q1.1** `graphical.target` declara `Requires=multi-user.target` *y* `After=multi-user.target`. ¿Qué se rompería si la unit tuviera solo `Requires=` y no `After=`?
- **Q1.2** ¿Por qué `default.target` vive bajo `/etc/systemd/system/` y no bajo `/usr/lib/systemd/system/`, y qué te dice eso sobre cómo va a tratar tu elección una actualización de paquetes?
- **Q1.3** `graphical.target` dice `Wants=display-manager.service`. Si GDM falla al arrancar, ¿se alcanza igual `graphical.target`? Justificá con la semántica de `Wants=` frente a `Requires=`.
- **Q1.4** `basic.target` aparece por debajo de `multi-user.target`, y no al revés. ¿Qué dice ese orden sobre dónde deberías enganchar una unit que necesita la red *y* los sistemas de archivos locales?

---

## Ejercicio 2 — Cambiar el boot target por defecto y probar que surtió efecto

**Objetivo:** realizar la tarea central del examen —fijar el boot target por defecto— y verificarla inspeccionando el artefacto en vez de confiar en el estado de salida del comando.

1. Registrá el estado actual para poder restaurarlo:

   ```console
   # systemctl get-default > /root/original-default-target.txt
   # cat /root/original-default-target.txt
   graphical.target
   ```

2. Cambiá el default a un arranque en modo texto:

   ```console
   # systemctl set-default multi-user.target
   Removed "/etc/systemd/system/default.target".
   Created symlink /etc/systemd/system/default.target → /usr/lib/systemd/system/multi-user.target.
   ```

3. Verificá dos veces: una a través de la API, otra en disco:

   ```console
   # systemctl get-default
   multi-user.target
   # readlink -f /etc/systemd/system/default.target
   /usr/lib/systemd/system/multi-user.target
   ```

4. Confirmá que esto cambió **solo** el próximo arranque, no el sistema en ejecución:

   ```console
   # systemctl is-active graphical.target
   active
   ```

5. Ahora hacé el mismo cambio a mano, tal como lo harías en una shell de rescate donde `systemctl` no puede hablar con el PID 1:

   ```console
   # rm -f /etc/systemd/system/default.target
   # ln -sf /usr/lib/systemd/system/graphical.target /etc/systemd/system/default.target
   # systemctl get-default
   graphical.target
   ```

6. Intentá fijar un target que no es aislable y leé el rechazo con atención:

   ```console
   # systemctl set-default basic.target
   Removed "/etc/systemd/system/default.target".
   Created symlink /etc/systemd/system/default.target → /usr/lib/systemd/system/basic.target.
   # systemctl isolate basic.target
   Failed to isolate basic.target: Operation refused, unit basic.target may be requested by dependency only (it is configured to refuse manual start/stop).
   ```

7. Restaurá el default original antes de continuar:

   ```console
   # systemctl set-default "$(cat /root/original-default-target.txt)"
   ```

**Comprobá tu comprensión**

- **Q2.1** El paso 5 produjo el resultado idéntico con `ln -sf`. ¿En qué circunstancias el symlink manual es la *única* opción?
- **Q2.2** El paso 6 muestra que `set-default` aceptó sin problemas `basic.target` aunque no se lo puede aislar. ¿Qué pasa en el próximo arranque, y qué te enseña esto sobre la validación que hace `set-default`?
- **Q2.3** Un colega edita `/usr/lib/systemd/system/default.target` directamente. Dá dos razones independientes por las que esto está mal.
- **Q2.4** Después de `systemctl set-default multi-user.target`, ¿hace falta ejecutar `systemctl daemon-reload` para que el cambio sobreviva a un reinicio? ¿Por qué sí o por qué no?

---

## Ejercicio 3 — Cambiar de target en tiempo de ejecución, incluido el modo monousuario

**Objetivo:** cambiar el target del sistema *en ejecución* y entender qué detiene `isolate`, no solo qué arranca.

> Hacé esto desde una **consola física/virtual**, no por SSH. `systemctl isolate multi-user.target` desde una sesión gráfica mata tu escritorio; `systemctl rescue` te va a cortar la conexión SSH.

1. Anotá el target actual y el conjunto de servicios en ejecución, para poder comparar después:

   ```console
   # systemctl list-units --type=service --state=running --no-legend | wc -l
   38
   # systemctl is-active graphical.target
   active
   ```

2. Pasá el sistema vivo a modo texto:

   ```console
   # systemctl isolate multi-user.target
   ```

3. Desde tty2, verificá la transición y contá los servicios otra vez:

   ```console
   # systemctl is-active graphical.target
   inactive
   # systemctl is-active multi-user.target
   active
   # systemctl list-units --type=service --state=running --no-legend | wc -l
   24
   # systemctl status gdm.service | head -n 4
   ○ gdm.service - GNOME Display Manager
        Loaded: loaded (/usr/lib/systemd/system/gdm.service; enabled; preset: enabled)
        Active: inactive (dead) since Tue 2026-08-25 10:07:11 -03; 42s ago
   ```

4. Inspeccioná los jobs encolados/terminados de la transición:

   ```console
   # systemctl list-jobs
   No jobs running.
   ```

5. Volvé al modo gráfico:

   ```console
   # systemctl isolate graphical.target
   ```

6. Entrá en modo rescate (el equivalente a monousuario). Se te va a pedir la contraseña de root en la consola:

   ```console
   # systemctl rescue
   Broadcast message from root@node01 (Tue 2026-08-25 10:11:44 -03):

   The system will now be rebooted into rescue mode!
   ```

   En la consola:

   ```
   You are in rescue mode. After logging in, type "journalctl -xb" to view
   system logs, "systemctl reboot" to reboot, or "exit" to boot into default mode.
   Give root password for maintenance
   (or press Control-D to continue):
   ```

7. Dentro del modo rescate, verificá el entorno reducido:

   ```console
   # systemctl is-active rescue.target
   active
   # systemctl list-units --type=service --state=running --no-legend
     dbus-broker.service   loaded active running D-Bus System Message Bus
     systemd-journald.service loaded active running Journal Service
     systemd-udevd.service loaded active running Rule-based Manager for Device Events and Files
   # findmnt -no SOURCE,TARGET,OPTIONS /
   /dev/mapper/rl-root / rw,relatime,seclabel
   # ip -brief addr show
   lo               UNKNOWN        127.0.0.1/8 ::1/128
   enp1s0           DOWN
   ```

8. Resolvé la duda sobre el requisito de contraseña del prompt de emergencia comparando con `emergency.target` sin entrar en él:

   ```console
   # systemctl cat emergency.target | sed -n '1,20p'
   # /usr/lib/systemd/system/emergency.target
   [Unit]
   Description=Emergency Mode
   Documentation=man:systemd.special(7)
   Requires=emergency.service
   After=emergency.service
   AllowIsolate=yes
   ```

9. Volvé al target por defecto:

   ```console
   # systemctl default
   ```

**Comprobá tu comprensión**

- **Q3.1** En el paso 3, `gdm.service` está `inactive (dead)` pero sigue `enabled`. Explicá la diferencia entre esas dos palabras y por qué `isolate` no deshabilitó nada.
- **Q3.2** ¿Qué hace exactamente `isolate` que `systemctl start multi-user.target` no hace?
- **Q3.3** En modo rescate el sistema de archivos raíz está montado `rw` y la red está caída. En modo *emergency*, ¿qué cambia respecto del sistema de archivos, y qué único comando solés necesitar antes de poder editar `/etc/fstab` ahí?
- **Q3.4** ¿Por qué ejecutar `systemctl isolate multi-user.target` por SSH es una mala idea, y qué hace que `systemctl rescue` sea todavía peor por SSH?
- **Q3.5** Estás en modo rescate y presionás `Ctrl-D` en el prompt de mantenimiento. ¿Qué pasa, y de qué unit vino ese prompt?

---

## Ejercicio 4 — Compatibilidad SysV: `runlevel`, `telinit`, `/etc/inittab`, `/etc/init.d/`

**Objetivo:** leer el vocabulario clásico de init que el examen sigue evaluando, y ver con precisión cómo lo emula systemd.

1. Hacé las preguntas clásicas en un host con systemd:

   ```console
   # runlevel
   N 5
   # who -r
            run-level 5  2026-08-25 09:14
   ```

   > **Nota diagnóstica:** en versiones muy recientes de systemd el soporte de `utmp` está deprecado/deshabilitado, y `runlevel` puede imprimir `unknown`. En ese caso las respuestas autoritativas son `systemctl get-default` y `systemctl list-units --type=target`.

2. Exponé la capa de compatibilidad: los targets de runlevel son symlinks:

   ```console
   # ls -l /usr/lib/systemd/system/runlevel?.target
   lrwxrwxrwx. 1 root root 15 Jul  3 00:00 /usr/lib/systemd/system/runlevel0.target -> poweroff.target
   lrwxrwxrwx. 1 root root 13 Jul  3 00:00 /usr/lib/systemd/system/runlevel1.target -> rescue.target
   lrwxrwxrwx. 1 root root 17 Jul  3 00:00 /usr/lib/systemd/system/runlevel2.target -> multi-user.target
   lrwxrwxrwx. 1 root root 17 Jul  3 00:00 /usr/lib/systemd/system/runlevel3.target -> multi-user.target
   lrwxrwxrwx. 1 root root 17 Jul  3 00:00 /usr/lib/systemd/system/runlevel4.target -> multi-user.target
   lrwxrwxrwx. 1 root root 16 Jul  3 00:00 /usr/lib/systemd/system/runlevel5.target -> graphical.target
   lrwxrwxrwx. 1 root root 13 Jul  3 00:00 /usr/lib/systemd/system/runlevel6.target -> reboot.target
   ```

3. Confirmá que `telinit` e `init` son ellos mismos shims de compatibilidad:

   ```console
   # ls -l /sbin/telinit /sbin/init
   lrwxrwxrwx. 1 root root 22 Jul  3 00:00 /sbin/init -> ../lib/systemd/systemd
   lrwxrwxrwx. 1 root root 21 Jul  3 00:00 /sbin/telinit -> ../bin/systemctl
   ```

4. Desde una consola, cambiá de runlevel a la vieja usanza y observá qué hace realmente systemd:

   ```console
   # telinit 3
   # systemctl is-active multi-user.target
   active
   # runlevel
   5 3
   ```

5. Leé un `/etc/inittab` genuino de SysV: o desde un contenedor legacy, o desde esta copia de referencia. Guardala como `/root/inittab.sample` y estudiala:

   ```
   # /etc/inittab — SysV init (RHEL 6 style)
   id:5:initdefault:
   si::sysinit:/etc/rc.d/rc.sysinit

   l0:0:wait:/etc/rc.d/rc 0
   l1:1:wait:/etc/rc.d/rc 1
   l2:2:wait:/etc/rc.d/rc 2
   l3:3:wait:/etc/rc.d/rc 3
   l5:5:wait:/etc/rc.d/rc 5
   l6:6:wait:/etc/rc.d/rc 6

   ca::ctrlaltdel:/sbin/shutdown -t3 -r now
   pf::powerfail:/sbin/shutdown -f -h +2 "Power Failure; System Shutting Down"
   pr:12345:powerokwait:/sbin/shutdown -c "Power Restored; Shutdown Cancelled"

   1:2345:respawn:/sbin/mingetty tty1
   2:2345:respawn:/sbin/mingetty tty2
   x:5:respawn:/etc/X11/prefdm -nodaemon
   ```

6. Descomponé el formato de registro con un one-liner para que los cuatro campos queden inconfundibles:

   ```console
   # awk -F: '!/^#/ && NF>=4 {printf "id=%-3s runlevels=%-6s action=%-12s process=%s\n", $1,$2,$3,$4}' /root/inittab.sample
   id=id  runlevels=5     action=initdefault  process=
   id=si  runlevels=      action=sysinit      process=/etc/rc.d/rc.sysinit
   id=l3  runlevels=3     action=wait         process=/etc/rc.d/rc 3
   id=ca  runlevels=      action=ctrlaltdel   process=/sbin/shutdown -t3 -r now
   id=1   runlevels=2345  action=respawn      process=/sbin/mingetty tty1
   ```

7. Inspeccioná los directorios de scripts SysV que todavía existan en tu distribución:

   ```console
   # ls -l /etc/init.d/ 2>/dev/null | head
   # ls -l /etc/rc3.d/ 2>/dev/null | head
   lrwxrwxrwx 1 root root 17 Aug 20 11:02 K01apache2 -> ../init.d/apache2
   lrwxrwxrwx 1 root root 14 Aug 20 11:02 S01cron -> ../init.d/cron
   lrwxrwxrwx 1 root root 14 Aug 20 11:02 S01ssh -> ../init.d/ssh
   ```

8. Encontrá el reemplazo que systemd le da a la línea `ctrlaltdel`, y enmascaralo en un servidor donde una tecla apretada por accidente no debe reiniciar la máquina:

   ```console
   # systemctl cat ctrl-alt-del.target | head -n 3
   # /usr/lib/systemd/system/reboot.target
   [Unit]
   Description=Reboot
   # systemctl mask ctrl-alt-del.target
   Created symlink /etc/systemd/system/ctrl-alt-del.target → /dev/null.
   # systemctl unmask ctrl-alt-del.target
   Removed "/etc/systemd/system/ctrl-alt-del.target".
   ```

**Comprobá tu comprensión**

- **Q4.1** En el paso 4, `runlevel` imprimió `5 3`. Nombrá cada campo.
- **Q4.2** Nombrá los cuatro campos separados por dos puntos de un registro de `/etc/inittab`, y explicá por qué el cuarto campo del registro `initdefault` está vacío.
- **Q4.3** ¿Por qué nunca se deben escribir `id:0:initdefault:` ni `id:6:initdefault:`?
- **Q4.4** En SysV clásico, ¿qué comando hace que `init` vuelva a leer `/etc/inittab` sin reiniciar, y cuál es su contraparte en systemd?
- **Q4.5** En `/etc/rc3.d/`, explicá el significado del prefijo `S`/`K` y de los dos dígitos, y decí qué acción del runlevel 3 codifica `K01apache2`.
- **Q4.6** `respawn` en las líneas de `mingetty`: ¿qué garantiza, y qué hace `init` si el proceso termina de inmediato en un bucle cerrado?
- **Q4.7** En un host con systemd, ¿cuál es el efecto concreto de editar `/etc/inittab` y poner `id:3:initdefault:`?

---

## Ejercicio 5 — Avisar a los usuarios antes de un evento disruptivo

**Objetivo:** cumplir con el objetivo "avisar a los usuarios antes de cambiar de runlevel u otros eventos importantes del sistema" con las herramientas reales, y saber qué canal llega a quién.

Abrí una segunda sesión sin privilegios (`node02` u otra tty) logueada como usuario normal; dejala a la vista.

1. Enviá un broadcast inmediato y observalo en la otra sesión:

   ```console
   # wall "Maintenance window opens in 15 minutes. Please save your work."
   ```

   En la sesión del usuario:

   ```
   Broadcast message from root@node01 (pts/0) (Tue Aug 25 10:14:31 2026):

   Maintenance window opens in 15 minutes. Please save your work.
   ```

2. Enviá un aviso más largo desde un archivo, y suprimí la línea de encabezado:

   ```console
   # cat > /root/notice.txt <<'EOF'
   Scheduled kernel upgrade — node01
   Start:  10:30  End (expected): 10:45
   Impact: all sessions terminated; NFS exports unavailable.
   EOF
   # wall -n /root/notice.txt
   ```

3. Mostrá que `mesg` controla la recepción, pero no para `root`:

   ```console
   $ tty
   /dev/pts/2
   $ mesg
   is y
   $ mesg n
   $ mesg
   is n
   ```

   Ahora volvé a hacer broadcast como root y como usuario sin privilegios, y compará quién lo ve.

4. Programá un apagado real con una ventana de aviso, y leé el broadcast automático:

   ```console
   # shutdown -h +10 "Kernel upgrade; the node returns at 10:45"
   Shutdown scheduled for Tue 2026-08-25 10:24:31 -03, use 'shutdown -c' to cancel.
   ```

   Las otras sesiones reciben:

   ```
   Broadcast message from root@node01 (Tue 2026-08-25 10:14:31 -03):

   Kernel upgrade; the node returns at 10:45

   The system is going down for poweroff at Tue 2026-08-25 10:24:31 -03!
   ```

5. Inspeccioná dónde queda registrada la acción programada:

   ```console
   # cat /run/systemd/shutdown/scheduled
   USEC=1787670271000000
   WARN_WALL=1
   MODE=poweroff
   WALL_MESSAGE=Kernel upgrade; the node returns at 10:45
   # systemctl list-jobs
   No jobs running.
   ```

6. Cancelalo antes de que dispare:

   ```console
   # shutdown -c
   ```

   ```
   Broadcast message from root@node01 (Tue 2026-08-25 10:16:02 -03):

   The system shutdown has been cancelled at Tue 2026-08-25 10:17:02 -03!
   ```

7. Avisá sin comprometerte: la forma "solo molestar":

   ```console
   # shutdown -k +5 "Rehearsal only: no shutdown will occur"
   ```

8. Probá el bloqueo de login que produce un apagado programado. Programá uno para dentro de cuatro minutos, y después intentá loguearte desde `node02`:

   ```console
   # shutdown -h +4 "lockout test"
   # sleep 90; ls -l /run/nologin
   -rw-r--r--. 1 root root 55 Aug 25 10:19 /run/nologin
   # cat /run/nologin
   System is going down. Unprivileged users are not permitted to log in anymore. For technical details, see pam_nologin(8).
   ```

   Desde `node02`:

   ```console
   $ ssh alice@node01
   alice@node01's password:
   System is going down. Unprivileged users are not permitted to log in anymore.
   Connection closed by 192.0.2.11 port 22
   ```

9. Cancelá y confirmá que el archivo de bloqueo fue eliminado:

   ```console
   # shutdown -c
   # ls -l /run/nologin
   ls: cannot access '/run/nologin': No such file or directory
   ```

**Comprobá tu comprensión**

- **Q5.1** El `wall` de `root` llegó a la sesión que había ejecutado `mesg n`. ¿Por qué, y cuál es el razonamiento de seguridad detrás de esa excepción?
- **Q5.2** Distinguí `wall`, `write` y `/etc/motd` según *cuándo* llega cada uno al usuario.
- **Q5.3** ¿Qué hace `shutdown -k`, y cuál es la razón operativa para usarlo antes de una ventana real?
- **Q5.4** ¿Qué componente crea `/run/nologin`, con cuánta anticipación respecto del plazo, y qué módulo PAM lo aplica? Nombrá la ruta tradicional de SysV para el mismo archivo.
- **Q5.5** `root` todavía podía loguearse durante el bloqueo del paso 8. ¿Es un bug? Explicá desde la semántica de `pam_nologin`.
- **Q5.6** Programaste `shutdown -h +60` ayer desde una sesión SSH que ya se desconectó. ¿Cómo averiguás si sigue pendiente, y cómo lo cancelás?

---

## Ejercicio 6 — Shutdown, reboot, halt, poweroff y sus equivalentes en systemd

**Objetivo:** dejar de confundir los cinco comandos, y saber cuáles se saltean la detención ordenada de los servicios.

1. Construí la tabla de equivalencias empíricamente. Primero, confirmá qué son realmente los nombres legacy:

   ```console
   # ls -l /sbin/shutdown /sbin/reboot /sbin/halt /sbin/poweroff
   lrwxrwxrwx. 1 root root 16 Jul  3 00:00 /sbin/halt -> ../bin/systemctl
   lrwxrwxrwx. 1 root root 16 Jul  3 00:00 /sbin/poweroff -> ../bin/systemctl
   lrwxrwxrwx. 1 root root 16 Jul  3 00:00 /sbin/reboot -> ../bin/systemctl
   lrwxrwxrwx. 1 root root 16 Jul  3 00:00 /sbin/shutdown -> ../bin/systemctl
   ```

2. Practicá las formas del argumento de tiempo sin ejecutarlas, programando y cancelando de inmediato cada una:

   ```console
   # shutdown -r +1  "reboot in one minute";      shutdown -c
   # shutdown -h 23:30 "power-off tonight";       shutdown -c
   # shutdown -P +2  "explicit power-off";        shutdown -c
   # shutdown -H +2  "halt, do not cut power";    shutdown -c
   ```

3. Compará la semántica de `halt` y `poweroff` a nivel ACPI:

   ```console
   # systemctl cat halt.target | sed -n '1,12p'
   # /usr/lib/systemd/system/halt.target
   [Unit]
   Description=Halt
   Documentation=man:systemd.special(7)
   DefaultDependencies=no
   Requires=systemd-halt.service
   After=systemd-halt.service
   AllowIsolate=yes
   JobTimeoutSec=30min
   JobTimeoutAction=poweroff-force
   ```

4. Revisá qué está bloqueando actualmente un apagado (inhibitor locks):

   ```console
   # systemd-inhibit --list
   WHO             UID USER PID  COMM            WHAT                    WHY                                              MODE
   NetworkManager  0   root 1123 NetworkManager  sleep                   NetworkManager needs to turn off networks        block
   UPower          0   root 1301 upowerd         sleep                   Pause device polling                             delay
   alice           1000 alice 4102 gnome-session shutdown:sleep:idle     User session inhibited                           block

   3 inhibitors listed.
   ```

5. Tomá vos mismo un inhibitor lock y observá cómo se rechaza un intento de apagado sin privilegios:

   ```console
   # systemd-inhibit --what=shutdown --who="dbadmin" --why="pg_basebackup in progress" --mode=block sleep 300 &
   [1] 4711
   # systemd-inhibit --list | grep dbadmin
   dbadmin  0  root  4711  systemd-inhibit  shutdown  pg_basebackup in progress  block
   ```

   Como usuario normal:

   ```console
   $ systemctl poweroff
   Operation inhibited by "dbadmin" (PID 4711 "systemd-inhibit", user root), reason is "pg_basebackup in progress".
   Please retry operation after closing inhibitors and logging out other users.
   Alternatively, ignore inhibitors and users with 'systemctl poweroff -i'.
   ```

6. Matá el lock y confirmá que desapareció:

   ```console
   # kill %1
   # systemd-inhibit --list | grep -c dbadmin
   0
   ```

7. Leé —**no** ejecutes— las variantes forzadas, y sé capaz de explicar cada una:

   ```console
   # systemctl reboot            # orderly: stop all units, unmount, then reboot
   # systemctl reboot -i         # orderly, but ignore inhibitors and logged-in users
   # systemctl reboot -f         # skip the orderly stop of units; still sync/unmount
   # systemctl reboot -ff        # immediate reboot(2); no unmount, no sync — data loss risk
   ```

8. Reiniciá la máquina limpiamente y cronometrá la fase de apagado desde el journal del arranque anterior:

   ```console
   # systemctl reboot
   ```

   Cuando vuelva:

   ```console
   # journalctl -b -1 -o short-precise | tail -n 8
   Aug 25 10:41:22.118 node01 systemd[1]: Reached target Unmount All Filesystems.
   Aug 25 10:41:22.140 node01 systemd[1]: Reached target Late Shutdown Services.
   Aug 25 10:41:22.152 node01 systemd[1]: Finished System Reboot.
   Aug 25 10:41:22.160 node01 systemd[1]: Shutting down.
   Aug 25 10:41:22.310 node01 systemd-shutdown[1]: Syncing filesystems and block devices.
   Aug 25 10:41:22.480 node01 systemd-shutdown[1]: Sending SIGTERM to remaining processes...
   Aug 25 10:41:22.610 node01 systemd-shutdown[1]: Sending SIGKILL to remaining processes...
   Aug 25 10:41:23.004 node01 systemd-shutdown[1]: Rebooting.
   ```

**Comprobá tu comprensión**

- **Q6.1** Escribí el comando único para cada caso: (a) reiniciar en 5 minutos con un mensaje; (b) apagar a las 02:00; (c) reiniciar de inmediato; (d) cancelar un apagado pendiente.
- **Q6.2** `shutdown -h now`: ¿hace halt o apaga la máquina? Explicá la relación `-h`/`-H`/`-P` en la implementación de systemd.
- **Q6.3** En el paso 3, `halt.target` lleva `JobTimeoutAction=poweroff-force`. ¿Contra qué falla del mundo real está defendiendo esa línea?
- **Q6.4** Un usuario ejecuta `systemctl poweroff` y recibe "Operation inhibited". Dá dos maneras legítimas de continuar y decí cuál elegirías en un nodo de base de datos en producción.
- **Q6.5** Explicá la diferencia práctica entre `systemctl reboot -f` y `systemctl reboot -ff`, y nombrá la única situación en la que `-ff` es la elección correcta.
- **Q6.6** `shutdown` es un symlink a `systemctl`, y sin embargo `shutdown -h +5` funciona y `systemctl -h +5` no. ¿Cómo implementa un solo binario varios comportamientos?

---

## Ejercicio 7 — Terminar procesos correctamente

**Objetivo:** la segunda mitad del objetivo. Señales, la escalera de escalamiento, y los casos en los que matar no funciona.

1. Listá las señales y ubicá las cuatro que importan para este objetivo:

   ```console
   # kill -l | head -n 4
    1) SIGHUP       2) SIGINT       3) SIGQUIT      4) SIGILL       5) SIGTRAP
    6) SIGABRT      7) SIGBUS       8) SIGFPE       9) SIGKILL     10) SIGUSR1
   11) SIGSEGV     12) SIGUSR2     13) SIGPIPE     14) SIGALRM     15) SIGTERM
   16) SIGSTKFLT   17) SIGCHLD     18) SIGCONT     19) SIGSTOP     20) SIGTSTP
   ```

2. Arrancá un proceso víctima controlado y encontralo de todas las formas que pide el examen:

   ```console
   # sleep 3000 &
   [1] 5120
   # pgrep -a sleep
   5120 sleep 3000
   # pidof sleep
   5120
   # ps -o pid,ppid,stat,cmd -p 5120
       PID    PPID STAT CMD
      5120    4800 S    sleep 3000
   ```

3. Practicá la escalera de escalamiento: primero por las buenas:

   ```console
   # kill 5120                      # implicit SIGTERM (15)
   # kill -0 5120 2>&1 || echo "gone"
   bash: kill: (5120) - No such process
   gone
   ```

4. Demostrá un proceso que *ignora* SIGTERM, de modo que hace falta escalar:

   ```console
   # cat > /usr/local/sbin/stubborn.sh <<'EOF'
   #!/bin/bash
   trap '' TERM
   echo "stubborn pid $$ ignoring SIGTERM"
   while :; do sleep 5; done
   EOF
   # chmod 755 /usr/local/sbin/stubborn.sh
   # /usr/local/sbin/stubborn.sh &
   [1] 5233
   stubborn pid 5233 ignoring SIGTERM
   # kill 5233; sleep 1; kill -0 5233 && echo "still alive"
   still alive
   # kill -9 5233; sleep 1; kill -0 5233 2>/dev/null || echo "killed"
   killed
   ```

5. Usá las herramientas basadas en nombre, y notá la diferencia entre hacer match contra el comando y contra la línea de comandos completa:

   ```console
   # sleep 4000 & sleep 4001 &
   # killall sleep
   # sleep 5000 &
   # pkill -f "sleep 5000"
   # pkill -u alice                  # every process owned by alice
   # pkill -HUP -x sshd              # exact name match, reload config
   ```

6. Mostrá las dos categorías de proceso que resisten a `kill -9`:

   ```console
   # ps -eo pid,ppid,stat,cmd | awk '$3 ~ /^Z/'
      5310    5299 Z    [defunct-child] <defunct>
   # ps -eo pid,stat,wchan:24,cmd | awk '$2 ~ /D/'
      5401 D    nfs_wait_bit_killable  /usr/bin/cp /mnt/nfs/big.img /tmp/
   ```

7. Ahora la versión consciente de systemd. Matá el proceso de un *servicio* y mirá cómo la supervisión te deshace lo hecho:

   ```console
   # systemctl show sshd.service -p Restart -p KillMode -p TimeoutStopUSec
   Restart=on-failure
   KillMode=process
   TimeoutStopUSec=1min 30s
   # systemd-cgls -u sshd.service
   Unit sshd.service (/system.slice/sshd.service):
   └─1187 "sshd: /usr/sbin/sshd -D [listener] 0 of 10-100 startups"
   # kill -9 1187
   # sleep 2; systemctl is-active sshd.service
   active
   ```

8. Hacelo correctamente: a través de la unit, y con una señal dirigida:

   ```console
   # systemctl stop stubborn.service          # orderly: SIGTERM → wait → SIGKILL
   # systemctl kill --signal=SIGHUP sshd.service
   # systemctl kill --signal=SIGKILL --kill-whom=all stubborn.service
   ```

   > En systemd anterior a la v252 la opción se escribe `--kill-who`.

9. Observá cómo escala el timeout de parada, usando el proceso testarudo como unit:

   ```console
   # cat > /etc/systemd/system/stubborn.service <<'EOF'
   [Unit]
   Description=Stubborn demo daemon that ignores SIGTERM

   [Service]
   Type=simple
   ExecStart=/usr/local/sbin/stubborn.sh
   TimeoutStopSec=15
   KillMode=control-group
   EOF
   # systemctl daemon-reload
   # systemctl start stubborn.service
   # time systemctl stop stubborn.service
   real    0m15.048s
   # journalctl -u stubborn.service -n 6 --no-pager
   Aug 25 10:41:07 node01 systemd[1]: Stopping Stubborn demo daemon that ignores SIGTERM...
   Aug 25 10:41:22 node01 systemd[1]: stubborn.service: State 'stop-sigterm' timed out. Killing.
   Aug 25 10:41:22 node01 systemd[1]: stubborn.service: Killing process 5512 (stubborn.sh) with signal SIGKILL.
   Aug 25 10:41:22 node01 systemd[1]: stubborn.service: Main process exited, code=killed, status=9/KILL
   Aug 25 10:41:22 node01 systemd[1]: stubborn.service: Failed with result 'timeout'.
   Aug 25 10:41:22 node01 systemd[1]: Stopped Stubborn demo daemon that ignores SIGTERM.
   ```

10. Leé el default global que gobierna a toda unit sin un `TimeoutStopSec=` explícito:

    ```console
    # grep -E '^#?Default(Timeout|Restart)' /etc/systemd/system.conf
    #DefaultTimeoutStartSec=90s
    #DefaultTimeoutStopSec=90s
    #DefaultRestartSec=100ms
    ```

11. Limpieza:

    ```console
    # systemctl disable --now stubborn.service
    # rm -f /etc/systemd/system/stubborn.service /usr/local/sbin/stubborn.sh
    # systemctl daemon-reload
    ```

**Comprobá tu comprensión**

- **Q7.1** ¿Por qué `kill -9` es el primer movimiento equivocado sobre un proceso de base de datos? Describí qué le permite hacer SIGTERM a un daemon bien escrito que SIGKILL no.
- **Q7.2** Dá el valor numérico y el significado habitual de SIGHUP, SIGTERM y SIGKILL, y nombrá las dos señales que un proceso nunca puede capturar, bloquear ni ignorar.
- **Q7.3** En el paso 6, un proceso está en `Z` y otro en `D`. Para cada uno, explicá por qué `kill -9` no tiene efecto y cuál es el remedio correcto.
- **Q7.4** En el paso 7, `kill -9 1187` no sacó a sshd del sistema. ¿Qué dos propiedades de la unit lo explican, y cuál es el comando correcto para detener realmente el servicio?
- **Q7.5** `killall sleep` frente a `pkill -f "sleep 5000"`: describí un escenario donde el primero es peligroso y el segundo es seguro.
- **Q7.6** Un apagado tarda exactamente 90 segundos más de lo que debería, siempre. Nombrá los dos parámetros que inspeccionarías primero y la línea del journal que confirmaría tu hipótesis.
- **Q7.7** Explicá `KillMode=process` frente a `KillMode=control-group`, y por qué `process` es riesgoso para un daemon que hace fork de workers.

---

## Ejercicio 8 — Selección del target en tiempo de arranque y diagnóstico del apagado

**Objetivo:** recuperar una máquina cuyo target por defecto está mal, y cuantificar el tiempo de arranque/apagado.

1. Reiniciá hasta el menú de GRUB, resaltá la entrada por defecto, presioná **`e`**, y ubicá la línea `linux`:

   ```
   linux ($root)/vmlinuz-5.14.0-427.el9.x86_64 root=/dev/mapper/rl-root ro rd.lvm.lv=rl/root rhgb quiet
   ```

2. Agregá al final de esa línea un override de target para un solo arranque, y después arrancá con **`Ctrl-X`**:

   ```
   ... rd.lvm.lv=rl/root ro systemd.unit=rescue.target
   ```

3. Una vez arrancado, probá que el override se aplicó y que no quedó persistido:

   ```console
   # systemctl is-active rescue.target
   active
   # cat /proc/cmdline
   BOOT_IMAGE=(hd0,gpt2)/vmlinuz-5.14.0-427.el9.x86_64 root=/dev/mapper/rl-root ro rd.lvm.lv=rl/root systemd.unit=rescue.target
   # systemctl get-default
   graphical.target
   ```

4. Repetí con las formas compatibles con SysV y confirmá que llegan al mismo lugar:

   ```
   ... ro single
   ... ro 1
   ... ro 3
   ```

5. Ahora la forma de último recurso. Arrancá con `init=/bin/bash`, y fijate qué tenés que hacer antes de poder escribir cualquier cosa:

   ```console
   bash-5.1# findmnt -no OPTIONS /
   ro,relatime,seclabel
   bash-5.1# mount -o remount,rw /
   bash-5.1# passwd root
   bash-5.1# touch /.autorelabel          # required on SELinux systems
   bash-5.1# exec /sbin/reboot -f
   ```

6. De vuelta en el sistema normal, medí el arranque:

   ```console
   # systemd-analyze
   Startup finished in 1.905s (kernel) + 3.114s (initrd) + 21.488s (userspace) = 26.508s
   graphical.target reached after 21.401s in userspace.
   # systemd-analyze blame | head -n 5
           9.612s NetworkManager-wait-online.service
           4.031s dnf-makecache.service
           1.882s systemd-udev-settle.service
            921ms firewalld.service
            402ms lvm2-monitor.service
   # systemd-analyze critical-chain graphical.target
   graphical.target @21.401s
   └─multi-user.target @21.400s
     └─sshd.service @2.109s +48ms
       └─network.target @2.106s
         └─NetworkManager.service @1.771s +333ms
   ```

7. Encontrá cualquier cosa que haya fallado durante la última transición:

   ```console
   # systemctl --failed
     UNIT                LOAD   ACTIVE SUB    DESCRIPTION
   ● stubborn.service    loaded failed failed Stubborn demo daemon that ignores SIGTERM

   1 loaded units listed.
   # journalctl -b -p err --no-pager | tail -n 5
   ```

8. Habilitá el logging del tiempo de apagado cuando un poweroff se cuelga y no podés ver por qué:

   ```console
   # systemd-analyze log-level debug
   # mkdir -p /run/initramfs; systemctl reboot
   ```

   Después del reinicio, leé la cola del arranque anterior:

   ```console
   # journalctl -b -1 -o short-precise | grep -E 'systemd-shutdown|Unmount|timed out' | tail
   # systemd-analyze log-level info
   ```

**Comprobá tu comprensión**

- **Q8.1** `systemd.unit=rescue.target` en la línea de comandos del kernel frente a `systemctl set-default rescue.target`: enunciá las dos diferencias que importan operativamente.
- **Q8.2** ¿Por qué el sistema de archivos raíz está en solo lectura bajo `init=/bin/bash`, y qué único comando lo hace escribible?
- **Q8.3** Bajo `init=/bin/bash`, ¿por qué tenés que usar `exec /sbin/reboot -f` en lugar de un `reboot` a secas?
- **Q8.4** `systemd-analyze blame` lista `NetworkManager-wait-online.service` con 9,6 s. ¿Esa unit es "lenta"? Explicá por qué `blame` por sí solo puede inducir a error y qué comando corrige el panorama.
- **Q8.5** Te olvidaste la contraseña de root y la máquina usa SELinux en modo enforcing. ¿Qué paso extra es obligatorio después de `passwd root` en una shell `init=/bin/bash`, y qué pasa si lo salteás?
- **Q8.6** Un poweroff se cuelga después de "Reached target Unmount All Filesystems." Esbozá el camino de diagnóstico usando las herramientas de este ejercicio.

---

## Ejercicio 9 — Ejercitación de consolidación

Hacé esto de punta a punta sin consultar las secciones anteriores. Cada línea es un comando o una pipeline corta.

1. Informá el boot target por defecto y el archivo físico que lo codifica.
2. Cambiá el default a modo texto, verificá, y restaurá el original en una única secuencia reversible.
3. Avisá a todos los usuarios logueados, y después programá un reinicio para dentro de 12 minutos con un mensaje explicativo.
4. Desde otra terminal, descubrí que hay un apagado pendiente, leé su hora programada y su modo, y cancelalo.
5. Pasá el sistema en ejecución a `multi-user.target` y volvé, desde tty2.
6. Determiná el runlevel actual y el anterior usando dos comandos diferentes.
7. Tomá un inhibitor lock llamado `backup` por 10 minutos, demostrá que un `systemctl poweroff` sin privilegios es rechazado, y después liberalo.
8. Arrancá un proceso que ignore SIGTERM, terminalo correctamente usando escalamiento, y probá que desapareció.
9. Encontrá cada unit que falló durante el arranque actual e imprimí las líneas de error de una de ellas.
10. Arrancá una sola vez en modo rescate sin cambiar ningún archivo en disco.

**Comprobá tu comprensión**

- **Q9.1** Escribí tu comando para cada uno de los diez ítems y comparalo con las respuestas.

---

<details>
<summary><b>Respuestas</b> — expandí solo después de intentar todos los ejercicios</summary>

### Ejercicio 1

**A1.1** `Requires=` es solo una relación de *dependencia*: dice que multi-user.target debe ser traído y debe tener éxito, pero no dice nada sobre *cuándo*. Sin `After=`, systemd arrancaría ambos targets en paralelo, así que el display manager podría lanzarse antes de que estuvieran arriba los sistemas de archivos locales, la red y los servicios multiusuario, produciendo un fallo de arranque intermitente y dependiente de la carga. El orden (`After=`/`Before=`) y el requisito (`Requires=`/`Wants=`) son ortogonales en systemd, y casi siempre se necesitan los dos juntos.

**A1.2** `/usr/lib/systemd/system/` es territorio del proveedor: los paquetes RPM/DEB son sus dueños y lo van a sobrescribir al actualizar. `/etc/systemd/system/` es territorio del administrador y tiene precedencia. Como `set-default` escribe el symlink bajo `/etc`, tu elección de boot target sobrevive a las actualizaciones de paquetes del propio systemd. Es la misma regla de precedencia que hace que los drop-ins bajo `/etc/systemd/system/<unit>.d/*.conf` sean la forma correcta de personalizar una unit del proveedor.

**A1.3** Sí, el target igual se alcanza. `Wants=` es un requisito *débil*: systemd intenta arrancar la dependencia, pero su fallo no hace fallar a la unit dependiente. Si hubiera sido `Requires=`, un `gdm.service` fallido habría hecho fallar también a `graphical.target`. En la práctica: con un GDM roto terminás en una consola de texto con `graphical.target` activo, que es exactamente por qué "el target está activo" no es la misma afirmación que "el escritorio funciona".

**A1.4** `basic.target` es una *dependencia de* `multi-user.target`, es decir, se alcanza antes. Marca el punto donde sockets, timers, paths, slices y `sysinit.target` están arriba, pero todavía no los servicios que dependen de la red. Una unit que necesita la red y los sistemas de archivos locales debería ordenarse `After=network-online.target local-fs.target` y ser traída por `multi-user.target`, no engancharse a `basic.target`, que es demasiado temprano.

### Ejercicio 2

**A2.1** Cuando el PID 1 no es alcanzable por D-Bus: un sistema offline montado desde un ISO de rescate o una shell de initramfs, un chroot, una imagen de contenedor que se está preparando, o una shell de emergencia `init=/bin/bash`. `systemctl set-default` necesita hablar con el manager en ejecución; `ln -sf` solo necesita un sistema de archivos escribible.

**A2.2** En el próximo arranque systemd va a intentar aislar `basic.target`, que está configurado con `AllowIsolate=no`; el arranque se traba o cae a modo emergency. La lección: `set-default` prácticamente no hace validación semántica, solo crea un symlink. Validar que el target elegido sea aislable (`AllowIsolate=yes`) es tarea *tuya*, y el rechazo de `isolate` del paso 6 es la forma barata de probarlo antes de reiniciar.

**A2.3** (a) El archivo pertenece al paquete; la próxima actualización de systemd con `dnf`/`apt` revierte el cambio en silencio, produciendo una máquina cuyo comportamiento cambia en un momento no relacionado. (b) `default.target` bajo `/usr/lib` normalmente ya es un symlink que trae la distribución; editarlo rompe el mecanismo documentado de override en `/etc` y hace la configuración invisible para cualquiera que inspeccione `/etc/systemd/system/`, que es el primer lugar donde va a mirar un colega.

**A2.4** No. `daemon-reload` vuelve a leer los *archivos* de unit hacia el manager en ejecución. `default.target` solo lo consulta el PID 1 en el arranque, momento en el cual el manager lee el sistema de archivos desde cero. `daemon-reload` hace falta después de crear o editar un archivo de unit (Ejercicio 7, paso 9), no después de `set-default`.

### Ejercicio 3

**A3.1** `enabled` describe la *persistencia*: existe un symlink en un directorio `.wants/`, así que la unit va a arrancar en el próximo boot cuando se alcance su target. `inactive (dead)` describe el estado *actual* en tiempo de ejecución. `isolate` opera puramente en tiempo de ejecución —arranca lo que el target nuevo necesita y detiene todo lo demás— y nunca toca los symlinks de habilitación. Por eso `isolate` es reversible con un segundo `isolate` y por eso no sobrevive a un reinicio.

**A3.2** `start` solo *agrega* el target y sus dependencias al conjunto en ejecución. `isolate` además *detiene toda unit que no sea requerida* por el target nuevo, lo que lo convierte en el verdadero equivalente de un cambio de runlevel de SysV. También exige que el target declare `AllowIsolate=yes`.

**A3.3** En modo emergency el sistema de archivos raíz se monta en **solo lectura** y prácticamente nada más corre, ni siquiera `sysinit.target`. Casi siempre necesitás `mount -o remount,rw /` antes de poder editar `/etc/fstab`. (Esta es la recuperación estándar de un error de tipeo en fstab que hizo fallar el arranque: el modo emergency es precisamente donde te deja un fstab malo.)

**A3.4** `isolate multi-user.target` detiene `graphical.target` y todo lo no requerido por multi-user; SSH normalmente sobrevive, pero cualquier unit fuera del conjunto de dependencias del target nuevo se detiene sin aviso, incluido, en algunos sistemas, el mismísimo servicio del que dependés. `systemctl rescue` es peor porque `rescue.target` detiene la red por completo y presenta un prompt de contraseña únicamente por consola: perdés la conexión y no podés volver a entrar remotamente. Ambos corresponden a una consola o a una interfaz de gestión fuera de banda (IPMI/serie/consola de virsh).

**A3.5** `Ctrl-D` sale de la shell de mantenimiento y deja que el arranque siga hasta el target por defecto. El prompt lo produce `rescue.service` (`systemd-sulogin-shell rescue`), que ejecuta `sulogin`, el mismo mecanismo que el modo monousuario clásico, y por eso pide la contraseña de root.

### Ejercicio 4

**A4.1** `runlevel` imprime `<anterior> <actual>`. `5 3` significa que el sistema estaba en runlevel 5 y ahora está en runlevel 3. Una `N` en el primer campo significa "none" (ninguno): no hubo runlevel anterior desde el arranque.

**A4.2** `id:runlevels:action:process`.
- `id` — un identificador único de 1 a 4 caracteres para el registro;
- `runlevels` — los runlevels en los que aplica el registro (vacío significa "todos", o "no específico de runlevel" para acciones como `sysinit`/`ctrlaltdel`);
- `action` — cómo trata `init` al proceso (`initdefault`, `sysinit`, `wait`, `once`, `respawn`, `boot`, `bootwait`, `ctrlaltdel`, `powerfail`, `powerokwait`, `off`, `ondemand`);
- `process` — el comando a ejecutar.

El cuarto campo del registro `initdefault` está vacío porque el registro no lleva ningún comando: solo declara en qué runlevel debe entrar `init` después del arranque. `init` lee el segundo campo e ignora el cuarto.

**A4.3** El runlevel 0 es halt/apagado y el runlevel 6 es reinicio. `id:0:initdefault:` produce una máquina que se apaga sola en el instante en que init termina; `id:6:initdefault:` produce un bucle infinito de reinicios. Ninguno de los dos se puede corregir desde un login normal, porque no hay login utilizable: la recuperación requiere editar el archivo desde un medio de rescate o pasar un runlevel en la línea de comandos del kernel.

**A4.4** `telinit q` (equivalentemente `init q`, o `telinit Q`) hace que `init` vuelva a examinar `/etc/inittab` sin cambiar de runlevel. La contraparte en systemd es `systemctl daemon-reload`, que hace que el PID 1 vuelva a leer los archivos de unit y reconstruya su grafo de dependencias.

**A4.5** `S` = arrancar el servicio al entrar en ese runlevel; `K` = kill (detenerlo). Los dos dígitos son la secuencia de orden: `rc` ejecuta primero los scripts `K` en orden numérico ascendente, y después los `S` en orden numérico ascendente, pasándoles `stop` y `start` respectivamente. `K01apache2` significa entonces: al entrar en runlevel 3, detener Apache, y hacerlo primero entre los scripts de kill. (Notá que el destino del symlink es el script real en `/etc/init.d/`.)

**A4.6** `respawn` garantiza que `init` reinicie el proceso cada vez que termina, mientras el runlevel actual esté en la lista de runlevels del registro: así es como reaparecen los prompts de getty después de que cerrás sesión. Si el proceso termina más de 10 veces en 2 minutos, `init` considera que está en bucle, registra `respawning too fast: disabled for 5 minutes`, y suspende ese registro durante cinco minutos antes de volver a intentarlo.

**A4.7** Ninguno. En un host con systemd, `/sbin/init` es un symlink a systemd, que no lee `/etc/inittab` en absoluto. Las distribuciones que todavía traen el archivo suelen incluir un comentario que dice exactamente eso; la acción correcta es `systemctl set-default multi-user.target`.

### Ejercicio 5

**A5.1** `wall` escribe en las terminales de los usuarios logueados; los mensajes de usuarios comunes se suprimen en las terminales cuyo dueño ejecutó `mesg n`, pero los broadcasts de `root` esquivan esa verificación. El razonamiento es que `mesg n` protege contra la molestia social entre pares, mientras que un broadcast de root es un aviso *operativo* —"esta máquina se cae en diez minutos"— del que un usuario no debe poder excluirse. (Los usuarios del grupo `tty` con permiso de escritura son el caso límite; que `wall -n` suprima el encabezado también es exclusivo de root.)

**A5.2** `wall` llega a todos los que están logueados **ahora mismo**, de inmediato, en su terminal. `write <usuario> <tty>` llega a **una** terminal específica de un usuario específico, de forma interactiva, y está sujeto a `mesg`. `/etc/motd` llega a los usuarios **en su próximo login** y a nadie que ya esté logueado: es la herramienta equivocada para un evento inminente y la correcta para un aviso permanente.

**A5.3** `shutdown -k` difunde el aviso de apagado **sin apagar nada realmente** (en systemd hace una simulación de la acción programada). Operativamente te permite ensayar la redacción exacta y el timing del aviso, y molestar a los usuarios antes de una ventana sin comprometer a la máquina a un cambio de estado: útil cuando la decisión de seguir o no todavía no está tomada.

**A5.4** systemd (a través de la maquinaria de apagado programado en el PID 1/logind) crea `/run/nologin` **5 minutos antes** del plazo. `pam_nologin(8)` lo hace cumplir: si el archivo existe, se rechazan los logins que no sean de root y se muestra el contenido del archivo. La ruta tradicional de SysV para el mismo propósito es `/etc/nologin`; `pam_nologin` verifica ambas, y en muchas distribuciones `/etc/nologin` es un symlink hacia `/run`. Ambas se eliminan cuando el apagado se cancela o se completa.

**A5.5** No es un bug, es el diseño. `pam_nologin` exime explícitamente a `root` (más precisamente, a las cuentas con UID 0) para que un administrador todavía pueda loguearse y abortar o diagnosticar un apagado que está saliendo mal. Si root también quedara bloqueado, un `shutdown -h +60` mal calculado sería imposible de cancelar desde una sesión remota.

**A5.6** Verificá el job pendiente: `cat /run/systemd/shutdown/scheduled` (muestra `USEC`, `MODE` y `WALL_MESSAGE`), o `systemctl show --property=ScheduledShutdown`, o simplemente buscá `/run/nologin` una vez que estés dentro de los últimos cinco minutos. Cancelá con `shutdown -c` (equivalentemente `systemctl cancel-shutdown` en systemd reciente). El apagado programado vive en el PID 1, no en la shell que lo creó, que es exactamente por qué sobrevive a la desconexión.

### Ejercicio 6

**A6.1**
(a) `shutdown -r +5 "message"`
(b) `shutdown -h 02:00` (o `-P 02:00`)
(c) `shutdown -r now` — equivalentemente `systemctl reboot` o `reboot`
(d) `shutdown -c`

**A6.2** En la implementación de systemd, `-h` significa "halt o apagar", y se comporta como `-P` (apagar) **salvo** que también se pase `-H`. `-H` es un halt explícito: detener la CPU y dejar la máquina energizada. `-P` es un apagado explícito vía ACPI. Así que `shutdown -h now` apaga la máquina en cualquier sistema moderno. (En sysvinit clásico `-h` significaba halt, y hacía falta `halt -p` para cortar la energía: esta es la razón histórica por la que el examen lo pregunta.)

**A6.3** Un cuelgue durante el apagado. Si la transición de halt no se completa en 30 minutos —típicamente porque un sistema de archivos no se puede desmontar, un proceso está trabado en E/S ininterrumpible, o un montaje de red es inalcanzable— systemd deja de esperar y fuerza el apagado en lugar de dejar la máquina trabada para siempre con los servicios ya detenidos. Convierte un cuelgue indefinido en una caída acotada y recuperable.

**A6.4** (a) `systemctl poweroff -i` ignora los inhibitors y a los demás usuarios logueados. (b) Identificar el inhibitor con `systemd-inhibit --list`, contactar/detener el trabajo responsable, y reintentar limpiamente. En un nodo de base de datos en producción elegí (b): el inhibitor existe precisamente porque algo como un base backup o un flush de WAL está en curso, y `-i` derrotaría al mecanismo que estaba protegiendo tus datos. `-i` es para una máquina que tiene que bajar ahora sin importar nada.

**A6.5** `-f` se saltea la detención ordenada de las units —systemd va más o menos directo a la fase de apagado— pero igual sincroniza y desmonta los sistemas de archivos. `-ff` llama a `reboot(2)` de inmediato, sin desmontar ni sincronizar, así que se pierde cualquier página sucia de la caché; en un sistema de archivos con journal vas a tener un replay en el próximo arranque, y en una base de datos podés tener corrupción. El uso correcto de `-ff` es una máquina que ya está tan rota que un apagado ordenado no puede completarse —por ejemplo un apagado colgado que pasó el punto en el que alguna otra unit vaya a responder— y donde la alternativa es un corte físico de energía.

**A6.6** `systemctl` inspecciona `argv[0]`, el nombre con el que fue invocado. Cuando se lo llama como `shutdown`, `reboot`, `halt`, `poweroff` o `telinit`, parsea la sintaxis clásica de opciones de ese comando y la mapea a la operación correspondiente de systemd. Este es el patrón estándar de binario multi-call (el mismo truco que usa `busybox`), y es por eso que los symlinks de compatibilidad en `/sbin` funcionan sin ningún script wrapper.

### Ejercicio 7

**A7.1** SIGTERM es capturable, así que un daemon bien escrito instala un handler y lo usa para: terminar o revertir las transacciones en vuelo, vaciar los buffers de escritura y el WAL a disco, cerrar las conexiones de los clientes limpiamente, liberar locks, y eliminar sus archivos de PID/socket. SIGKILL lo entrega el kernel y no se puede capturar, bloquear ni ignorar: el proceso deja de ejecutarse al instante, a mitad de una escritura, sin nada de esa limpieza. En una base de datos eso significa recuperación al reiniciar en el mejor caso y corrupción en el peor. Escalá a `-9` solo después de que SIGTERM haya fallado de forma demostrable.

**A7.2** SIGHUP = 1, históricamente "la terminal de control desapareció", reutilizada convencionalmente por los daemons como "volvé a leer tu configuración". SIGTERM = 15, el pedido de terminación cortés y capturable, y el default que envía `kill`. SIGKILL = 9, terminación inmediata e incondicional. Las dos señales que nunca se pueden capturar, bloquear ni ignorar son **SIGKILL (9)** y **SIGSTOP (19)**.

**A7.3**
- **Zombie (`Z`)**: el proceso ya terminó; lo que queda es solo una entrada en la tabla de procesos que guarda su estado de salida, esperando que su padre llame a `wait()`. No queda nada a lo que señalar, así que ninguna señal tiene efecto. El remedio es hacer que el padre lo coseche: mandarle SIGCHLD al padre, o arreglar/reiniciar al padre; si el padre muere, `init`/systemd hereda al hijo y lo cosecha de inmediato.
- **Sueño ininterrumpible (`D`)**: el proceso está bloqueado dentro de una llamada al kernel que no puede interrumpirse, típicamente E/S contra un montaje NFS colgado o un disco que falla. Las señales se encolan pero no se entregan hasta que la syscall retorna. El remedio es arreglar la E/S subyacente: restaurar el servidor NFS, montar con `intr`/`soft`, o reemplazar el dispositivo defectuoso; `kill -9` va a surtir efecto en el momento en que la syscall se complete. La columna `wchan` nombra la función del kernel en la que está trabado y es la forma más rápida de identificar la causa.

**A7.4** `Restart=on-failure` —systemd trata la muerte por SIGKILL como un fallo y reinicia el servicio— combinado con el hecho de que señalaste al proceso y no a la unit, así que a la supervisión de systemd nunca se le dijo que se retirara. El comando correcto es `systemctl stop sshd.service`, que fija el estado objetivo de la unit en detenido, realiza él mismo el escalamiento SIGTERM → `TimeoutStopSec` → SIGKILL, y suprime el reinicio.

**A7.5** `killall sleep` mata **todos** los procesos llamados `sleep` del sistema, sin importar dueño ni argumentos, incluido uno lanzado por un script de backup o por la sesión de otro administrador. `pkill -f "sleep 5000"` hace match contra la línea de comandos completa, así que golpea solo la invocación específica que pretendías. En un host compartido o de producción, siempre acotá el match: agregá `-u <usuario>`, usá `-x` para nombres exactos, usá `-f` con un argumento distintivo, y verificá primero con `pgrep -a` antes de convertirlo en un `pkill`. (Notá también que en algunos sistemas UNIX `killall` significa "matar todos los procesos del sistema": otra razón para preferir `pkill`.)

**A7.6** `TimeoutStopSec=` en la unit específica, y `DefaultTimeoutStopSec=` en `/etc/systemd/system.conf` (por defecto 90 s), que aplica a cualquier unit que no fije el suyo. La línea del journal que lo confirma es `<unit>: State 'stop-sigterm' timed out. Killing.`, seguida de `Killing process <pid> (<name>) with signal SIGKILL` y `Failed with result 'timeout'`. Encontrá al culpable con `journalctl -b -1 | grep 'timed out'`.

**A7.7** `KillMode=control-group` (el default) envía las señales de parada a **todos** los procesos del cgroup de la unit, así que los workers forkeados, los scripts auxiliares y los hijos huérfanos son todos terminados. `KillMode=process` señala solo al proceso **principal**. Con un daemon que hace fork, `process` deja los workers corriendo después de que la unit reporta "stopped": siguen reteniendo puertos, locks de archivos y memoria, y el próximo `systemctl start` falla con "address already in use" o produce dos generaciones del daemon a la vez. `process` es apropiado solo donde los hijos supervivientes son intencionales, siendo el caso canónico `sshd.service`, que lo usa para que detener el listener no mate las sesiones de usuario establecidas.

### Ejercicio 8

**A8.1** (a) **Persistencia**: la línea de comandos del kernel aplica a exactamente un arranque y no deja rastro en disco, así que un ciclo de energía devuelve la máquina a su target normal; `set-default` escribe un symlink que aplica a todos los arranques siguientes. (b) **Alcanzabilidad**: la línea de comandos del kernel funciona en una máquina en la que no podés loguearte, que es justamente el punto, ya que un target por defecto equivocado suele ser lo que te dejó afuera en primer lugar. Usá la línea de comandos para diagnosticar, `set-default` para arreglar.

**A8.2** El bootloader pasa `ro` en la línea de comandos del kernel, y el sistema de archivos raíz normalmente lo remonta en lectura-escritura más tarde `systemd-remount-fs.service` como parte de `sysinit.target`. Con `init=/bin/bash` systemd nunca corre, así que nada hace ese remontaje y el sistema de archivos queda como lo montó el kernel. El comando es `mount -o remount,rw /`.

**A8.3** Tu shell bash **es** el PID 1. `/sbin/reboot` en un sistema con systemd es un symlink a `systemctl`, que intenta hablar con un manager de systemd en ejecución por D-Bus: no hay ninguno, así que falla. `reboot -f` esquiva eso y llama directamente a la syscall `reboot(2)`, y `exec` reemplaza al PID 1 en lugar de forkear un hijo suyo (el PID 1 no debe terminar). Alternativas equivalentes: `echo b > /proc/sysrq-trigger`, o `sync` seguido de `mount -o remount,ro /` y un ciclo de energía. Siempre hacé `sync` primero: nada más va a volcar tu cambio de `passwd`.

**A8.4** No necesariamente. `blame` ordena las units por su propio tiempo de inicialización, en aislamiento, sin considerar si algo estaba realmente esperándolas. `NetworkManager-wait-online.service` está *diseñado* para bloquear hasta unos ~30 s hasta que la red esté configurada; es lento por construcción, y solo retrasa el arranque si algo del camino crítico depende de él. `systemd-analyze critical-chain` es la vista correctiva: muestra el camino de dependencias realmente serializado hasta el target, con `@` (tiempo absoluto en que se alcanzó) y `+` (tiempo que tardó la unit en sí), así que podés ver si la unit lenta está siquiera en ese camino.

**A8.5** `touch /.autorelabel`, seguido de un reinicio. Editar `/etc/shadow` desde una shell que no tiene política SELinux cargada deja el archivo con un contexto de seguridad incorrecto; en el próximo arranque normal, a `sshd` y a `login` se les deniega el acceso y **ninguna cuenta puede loguearse** — una situación estrictamente peor que la contraseña olvidada. `/.autorelabel` dispara un reetiquetado completo del sistema de archivos en el próximo arranque (que tarda varios minutos y reinicia otra vez automáticamente) y restaura los contextos correctos. Verificá con `getenforce` / `sestatus` si el sistema está en enforcing antes de decidir.

**A8.6** (1) Reiniciá (a la fuerza si hace falta) y leé el arranque anterior: `journalctl -b -1 -o short-precise | tail -50`, buscando líneas `systemd-shutdown[1]:` y `timed out` / `Failed to unmount`. (2) Identificá qué sistema de archivos o dispositivo se niega a liberarse —típicamente un montaje de red, un target de device-mapper/LVM, o un dispositivo loop— y qué proceso lo sigue reteniendo. (3) Para un cuelgue reproducible, poné `systemd-analyze log-level debug` antes del apagado y asegurate de que `/run/initramfs` exista para que el apagado pueda pivotar de vuelta a un initramfs y registrar la fase final de desmontaje. (4) Revisá `JobTimeoutSec=`/`JobTimeoutAction=` en el target de halt/poweroff: si el cuelgue es acotado y raro, el timeout ya lo maneja; si es sistemático, arreglá el montaje (por ejemplo `_netdev`, `soft`/`intr` para NFS, orden correcto con `After=network.target`).

### Ejercicio 9

**A9.1**
1. `systemctl get-default; readlink -f /etc/systemd/system/default.target`
2. `systemctl get-default > /root/orig; systemctl set-default multi-user.target; systemctl get-default; systemctl set-default "$(cat /root/orig)"`
3. `wall "Reboot in 12 minutes"; shutdown -r +12 "Kernel upgrade — back by 10:45"`
4. `cat /run/systemd/shutdown/scheduled; shutdown -c`
5. `systemctl isolate multi-user.target` … `systemctl isolate graphical.target` (o `systemctl default`)
6. `runlevel` y `who -r` (recurrí a `systemctl list-units --type=target` donde utmp no esté disponible)
7. `systemd-inhibit --what=shutdown --who=backup --why="nightly backup" --mode=block sleep 600 &` → como usuario normal `systemctl poweroff` es rechazado → `kill %1`
8. `bash -c 'trap "" TERM; sleep 600' & kill %1; sleep 1; kill -9 %1; kill -0 <pid> 2>/dev/null || echo gone`
9. `systemctl --failed` y después `journalctl -u <unit> -b -p err --no-pager`
10. En GRUB presioná `e`, agregá `systemd.unit=rescue.target` a la línea `linux`, `Ctrl-X`

</details>

---

## Referencias

- LPI — *Exam 101 Objectives (101-500, v5.0)*, objetivo 101.3: <https://www.lpi.org/our-certifications/exam-101-objectives/>
- `systemd.special(7)` — targets especiales, incluidos `default.target`, `rescue.target`, `emergency.target`, `runlevelN.target`: <https://www.freedesktop.org/software/systemd/man/systemd.special.html>
- `systemctl(1)` — `get-default`, `set-default`, `isolate`, `rescue`, `emergency`, `kill`, flags de forzado: <https://www.freedesktop.org/software/systemd/man/systemctl.html>
- `shutdown(8)` (systemd) — argumentos de tiempo, `-c`, `-k`, `/run/nologin`: <https://www.freedesktop.org/software/systemd/man/shutdown.html>
- `systemd.kill(5)` — `KillMode=`, `KillSignal=`, `SendSIGKILL=`, `FinalKillSignal=`: <https://www.freedesktop.org/software/systemd/man/systemd.kill.html>
- `systemd.service(5)` — `TimeoutStopSec=`, `Restart=`: <https://www.freedesktop.org/software/systemd/man/systemd.service.html>
- `systemd-system.conf(5)` — `DefaultTimeoutStopSec=`: <https://www.freedesktop.org/software/systemd/man/systemd-system.conf.html>
- `kernel-command-line(7)` — `systemd.unit=`, `systemd.debug-shell`, `single`/`1`…`5` compatibles con SysV: <https://www.freedesktop.org/software/systemd/man/kernel-command-line.html>
- `systemd-inhibit(1)` — inhibitor locks: <https://www.freedesktop.org/software/systemd/man/systemd-inhibit.html>
- `systemd-analyze(1)` — `blame`, `critical-chain`, `log-level`: <https://www.freedesktop.org/software/systemd/man/systemd-analyze.html>
- `inittab(5)` (sysvinit) — formato de registro y acciones: <https://man7.org/linux/man-pages/man5/inittab.5.html>
- `init(8)` / `telinit(8)` (sysvinit): <https://man7.org/linux/man-pages/man8/init.8.html>
- `signal(7)` — números de señal y disposiciones por defecto: <https://man7.org/linux/man-pages/man7/signal.7.html>
- `kill(1)`, `killall(1)`, `pkill(1)`/`pgrep(1)`: <https://man7.org/linux/man-pages/man1/kill.1.html> · <https://man7.org/linux/man-pages/man1/killall.1.html> · <https://man7.org/linux/man-pages/man1/pgrep.1.html>
- `wall(1)`, `mesg(1)`, `write(1)`: <https://man7.org/linux/man-pages/man1/wall.1.html> · <https://man7.org/linux/man-pages/man1/mesg.1.html>
- `pam_nologin(8)`: <https://man7.org/linux/man-pages/man8/pam_nologin.8.html>
- `runlevel(8)`: <https://www.freedesktop.org/software/systemd/man/runlevel.html>