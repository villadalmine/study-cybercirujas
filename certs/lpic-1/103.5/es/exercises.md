# LPIC-1 · Examen 101-500 · Objetivo 103.5 — Crear, monitorizar y matar procesos

**Ejercicios guiados.** Cada paso está pensado para escribirse en un sistema Linux real. Los bloques marcados como `# expected output` son ilustrativos: tus PIDs, tiempos y cifras de memoria van a diferir, la *forma* de la salida no debería.

> **Requisitos del laboratorio:** cualquier distribución basada en systemd (Debian 12+, Ubuntu 22.04+, Rocky/Alma 9, openSUSE Leap 15.5+), una cuenta de usuario normal sin privilegios, `bash` como shell interactivo, y el paquete `procps`/`procps-ng` (`ps`, `top`, `free`, `uptime`, `pgrep`, `pkill`, `kill`, `killall`, `watch`). Dos ejercicios necesitan además `screen` y `tmux`, y uno necesita una segunda terminal o sesión SSH.
>
> **Seguridad:** todo lo que sigue actúa sobre procesos que son tuyos. No ejecutes `kill -9 -1`, `pkill -f .` ni `killall -9 bash` en una máquina que te importe — uno de los ejercicios explica exactamente por qué.

---

## Ejercicio 0 — Montar el laboratorio

### Pasos

1. Creá un directorio de trabajo aislado:

   ```bash
   mkdir -p ~/lab-103.5 && cd ~/lab-103.5
   ```

2. Creá un worker de larga duración que imprima su propia identidad, para que puedas correlacionar lo que ves en `ps`, `top` y `jobs`:

   ```bash
   cat > worker.sh <<'EOF'
   #!/bin/bash
   # Heartbeat worker used across objective 103.5 exercises.
   name="${1:-worker}"
   beat=0
   while true; do
       beat=$((beat + 1))
       printf '%s [%s] pid=%d ppid=%d pgid=%d beat=%d\n' \
              "$(date +%T)" "$name" "$$" "$PPID" "$(ps -o pgid= -p $$ | tr -d ' ')" "$beat"
       sleep 2
   done
   EOF
   chmod +x worker.sh
   ```

3. Creá un quemador de CPU que se usará más adelante para ordenar y para `top`:

   ```bash
   cat > burner.sh <<'EOF'
   #!/bin/bash
   # Busy loop, no syscalls in the hot path: stays in state R.
   while :; do :; done
   EOF
   chmod +x burner.sh
   ```

4. Confirmá que tu shell tiene el **control de trabajos** (modo monitor) habilitado y mirá qué pulsaciones de teclas mapea el driver de la terminal a señales:

   ```bash
   echo "$-"
   stty -a | tr ';' '\n' | grep -E 'intr|susp|quit|tostop'
   ```

   ```text
   # expected output
   himBHs
   intr = ^C
   quit = ^\
   susp = ^Z
   -tostop
   ```

   La `m` de `$-` es `set -m`, el modo monitor. Está activo por defecto en shells interactivos y **apagado** en shells no interactivos y en scripts.

### Comprobá tu comprensión

- **Q0.1** — `Ctrl-C`, `Ctrl-Z` y `Ctrl-\` los muestra `stty`, no `bash`. ¿Qué componente convierte realmente esas pulsaciones en señales, y qué conjunto de procesos las recibe?
- **Q0.2** — ¿Qué diferencia práctica implica que `set -m` esté *apagado* dentro de un script de shell para un comando que arrancás con `&`?
- **Q0.3** — `worker.sh` informa `$$` y `$PPID`. En un script arrancado como `./worker.sh alpha`, ¿a qué se refieren esas dos variables?

---

## Ejercicio 1 — Primer plano, segundo plano y la tabla de trabajos del shell

### Pasos

1. Arrancá un worker en primer plano y dejá que imprima dos o tres latidos:

   ```bash
   ./worker.sh alpha
   ```

   ```text
   # expected output
   14:02:11 [alpha] pid=4821 ppid=3970 pgid=4821 beat=1
   14:02:13 [alpha] pid=4821 ppid=3970 pgid=4821 beat=2
   ```

2. Presioná **`Ctrl-Z`**. El shell recupera el prompt:

   ```text
   # expected output
   ^Z
   [1]+  Stopped                 ./worker.sh alpha
   ```

3. Reanudalo **en segundo plano** y arrancá un segundo worker directamente en segundo plano, redirigiendo su ruido a un archivo:

   ```bash
   bg %1
   ./worker.sh beta > beta.log 2>&1 &
   echo "last background PID: $!"
   ```

   ```text
   # expected output
   [1]+ ./worker.sh alpha &
   [2] 4835
   last background PID: 4835
   ```

4. Inspeccioná la tabla de trabajos de tres maneras:

   ```bash
   jobs
   jobs -l
   jobs -p
   ```

   ```text
   # expected output
   [1]-  Running                 ./worker.sh alpha &
   [2]+  Running                 ./worker.sh beta > beta.log 2>&1 &

   [1]-  4821 Running                 ./worker.sh alpha &
   [2]+  4835 Running                 ./worker.sh beta > beta.log 2>&1 &

   4821
   4835
   ```

   Fijate en los marcadores `+` y `-`: `+` es el **trabajo actual** (`%+` o `%%`), `-` es el **trabajo anterior** (`%-`).

5. Traé el trabajo 2 a primer plano, después detenelo otra vez y dejalo detenido:

   ```bash
   fg %2
   # ...press Ctrl-Z...
   jobs -l
   ```

   ```text
   # expected output
   ./worker.sh beta > beta.log 2>&1
   ^Z
   [2]+  Stopped                 ./worker.sh beta > beta.log 2>&1
   [1]-  4821 Running                 ./worker.sh alpha &
   [2]+  4835 Stopped                 ./worker.sh beta > beta.log 2>&1
   ```

6. Demostrá que un trabajo *detenido* no consume CPU y no ejecuta nada, mientras que un trabajo en *segundo plano* sigue corriendo:

   ```bash
   wc -l beta.log
   sleep 6
   wc -l beta.log          # unchanged: job 2 is stopped
   ```

7. Demostrá que la tabla de trabajos es **por shell** y no se hereda:

   ```bash
   bash -c 'jobs; echo "exit=$?"'
   ```

   ```text
   # expected output
   exit=0
   ```

8. Direccioná trabajos por nombre en lugar de por número, y limpiá:

   ```bash
   fg %?beta        # select the job whose command line contains "beta"
   # ...Ctrl-Z again...
   kill %1 %2
   sleep 1
   jobs
   ```

   ```text
   # expected output
   [1]-  Terminated              ./worker.sh alpha
   [2]+  Terminated              ./worker.sh beta > beta.log 2>&1
   ```

   `kill %2` sobre un trabajo **detenido** es una trampa clásica de producción — mirá las preguntas.

### Comprobá tu comprensión

- **Q1.1** — `bg %1` y `fg %1` reanudan ambos un trabajo detenido. ¿Qué señal envían los dos, y qué hace `fg` *además* que `bg` no hace?
- **Q1.2** — En el paso 3, `$!` devolvió `4835`. ¿Qué PID es ese exactamente — el `bash` que interpreta `worker.sh`, o el `sleep 2` que forkea?
- **Q1.3** — `jobs` dentro de `bash -c` no imprimió nada y salió con 0. Explicá por qué ese es el comportamiento correcto y no un error.
- **Q1.4** — Enviás `kill %2` (es decir, `SIGTERM`) a un trabajo en estado `Stopped`. ¿Muere el proceso de inmediato? ¿Qué tenés que hacer para que muera?
- **Q1.5** — Tu shell sale mientras el trabajo 2 está en `Stopped`. ¿Qué hace `bash`, y por qué eso es distinto del caso `Running`?
- **Q1.6** — `%1`, `%+`, `%-`, `%?beta` y `%beta` son todas especificaciones de trabajo. ¿Cuál es la diferencia entre `%beta` y `%?beta`?

---

## Ejercicio 2 — Leer la tabla de procesos con `ps`

### Pasos

1. Compará las dos sintaxis históricas. *No* son alias:

   ```bash
   ps                # your processes on this terminal
   ps -f             # UNIX/POSIX style, full format
   ps aux | head -3  # BSD style, user-oriented, all processes
   ps -ef | head -3  # UNIX style, all processes, full format
   ```

   ```text
   # expected output (ps -ef)
   UID          PID    PPID  C STIME TTY          TIME CMD
   root           1       0  0 09:14 ?        00:00:03 /sbin/init splash
   root           2       0  0 09:14 ?        00:00:00 [kthreadd]
   ```

2. Observá qué pasa cuando las mezclás:

   ```bash
   ps -aux | head -2
   ```

   ```text
   # expected output
   Warning: bad syntax, perhaps a bogus '-'? See /usr/share/doc/procps-ng/FAQ
   USER         PID %CPU %MEM    VSZ   RSS TTY      STAT START   TIME COMMAND
   ```

3. Construí tu propio formato de salida — esto es lo que deberías usar realmente en producción:

   ```bash
   ./worker.sh alpha > /dev/null 2>&1 &
   ./burner.sh &
   sleep 3
   ps -eo pid,ppid,pgid,sid,tty,stat,ni,%cpu,%mem,rss,vsz,wchan:16,comm --sort=-%cpu | head -8
   ```

   ```text
   # expected output
       PID    PPID    PGID     SID TT       STAT  NI %CPU %MEM   RSS    VSZ WCHAN            COMMAND
      5104    3970    5104    3970 pts/1    R     0 99.4  0.0  3456   8120 -                burner.sh
      1183    1102    1183    1183 ?        Ssl   0  2.1  4.3 348912 2914772 ep_poll        gnome-shell
      5088    3970    5088    3970 pts/1    S     0  0.3  0.0  3612   8248 do_wait          worker.sh
      5121    5088    5088    3970 pts/1    S     0  0.0  0.0  2176   8100 hrtimer_nanosle  sleep
   ```

4. Decodificá la columna `STAT` contra un árbol vivo y contra `proc(5)`:

   ```bash
   ps -eo stat= | sort | uniq -c | sort -rn
   grep -E '^(Name|State|Threads|VmRSS|Voluntary)' /proc/$(pgrep -n -x worker.sh)/status
   ```

   ```text
   # expected output
       231 S
        14 I
         6 Ss
         3 Ssl
         1 R+
   Name:	worker.sh
   State:	S (sleeping)
   Threads:	1
   VmRSS:	    3612 kB
   ```

5. Mirá la jerarquía de procesos como un árbol, de tres maneras distintas:

   ```bash
   ps axjf | head -12
   ps -e --forest -o pid,ppid,comm | grep -A3 -w systemd | head
   pstree -p "$USER" | head
   ```

6. Distinguí `comm` de `args` — esta distinción decide si tu patrón de `pgrep` funciona:

   ```bash
   ps -eo pid,comm,args -p "$(pgrep -n -x worker.sh)"
   cat /proc/$(pgrep -n -x worker.sh)/comm
   tr '\0' ' ' < /proc/$(pgrep -n -x worker.sh)/cmdline; echo
   ```

   ```text
   # expected output
       PID COMMAND         COMMAND
      5088 worker.sh       /bin/bash ./worker.sh alpha
   worker.sh
   /bin/bash ./worker.sh alpha
   ```

7. Compará el `%CPU` de `ps` con el de `top`. Dejá `burner.sh` corriendo, y entonces:

   ```bash
   ps -o pid,etimes,times,%cpu -p "$(pgrep -n -x burner.sh)"
   sleep 20
   ps -o pid,etimes,times,%cpu -p "$(pgrep -n -x burner.sh)"
   ```

8. Limpiá:

   ```bash
   pkill -x burner.sh
   pkill -x worker.sh
   ```

### Comprobá tu comprensión

- **Q2.1** — ¿Por qué `ps -aux` emite una advertencia y `ps aux` no? ¿Qué dice POSIX que debería significar `-aux`?
- **Q2.2** — En el paso 3, `worker.sh` estaba en estado `S` con `WCHAN` `do_wait`, y un hijo `sleep` estaba en `S` con `hrtimer_nanosleep`. Explicá en qué está bloqueado cada proceso.
- **Q2.3** — Un proceso muestra `STAT` como `D`. ¿Qué está haciendo, y qué pasa si le enviás `SIGKILL`?
- **Q2.4** — Decodificá `Ssl` y `R+` completamente, letra por letra.
- **Q2.5** — El `RSS` de `gnome-shell` es 348 MB y el `VSZ` es 2.9 GB. ¿Qué número está más cerca de "RAM que este proceso me está costando", y por qué incluso ese es engañoso cuando lo sumás entre procesos?
- **Q2.6** — `ps` reportó un `%CPU` de 99.4 para el burner. ¿Es una medición instantánea? Derivá la fórmula a partir de las columnas `etimes` y `times` del paso 7.
- **Q2.7** — La columna `COMMAND` apareció dos veces en el paso 6 con valores distintos. ¿Cuál viene de `/proc/PID/comm`, cuál es su límite duro de longitud, y cuál puede cambiar un proceso en tiempo de ejecución?

---

## Ejercicio 3 — Padres, hijos, huérfanos y zombis

### Pasos

1. Observá un par padre/hijo y el grupo de procesos que comparten:

   ```bash
   ./worker.sh tree > /dev/null 2>&1 &
   sleep 1
   ps -eo pid,ppid,pgid,sid,stat,comm --forest | grep -E 'bash|worker|sleep' | head
   ```

2. Creá un **huérfano**: matá al padre, conservá al hijo.

   ```bash
   bash -c './worker.sh orphan > ~/lab-103.5/orphan.log 2>&1 &  sleep 60' &
   MIDDLE=$!
   sleep 2
   ps -o pid,ppid,comm -p "$(pgrep -n -x worker.sh)"
   kill "$MIDDLE"
   sleep 2
   ps -o pid,ppid,comm -p "$(pgrep -n -x worker.sh)"
   ```

   ```text
   # expected output
       PID    PPID COMMAND
      5310    5301 worker.sh
       PID    PPID COMMAND
      5310    2140 worker.sh
   ```

3. Averiguá *qué* lo adoptó — la respuesta con frecuencia no es el PID 1:

   ```bash
   ps -o pid,comm -p 2140
   ps -o pid,comm -p 1
   ```

   ```text
   # expected output
       PID COMMAND
      2140 systemd          <- systemd --user, a child subreaper
       PID COMMAND
         1 systemd
   ```

4. Verificá la regla de reparentado directamente desde la vista exportada por el kernel:

   ```bash
   grep -E '^(Name|PPid|NSpid)' /proc/$(pgrep -n -x worker.sh)/status
   pkill -x worker.sh
   ```

5. Creá un **zombi** a propósito. El hijo sale, el padre hace `exec` hacia un programa que nunca llama a `wait()`:

   ```bash
   bash -c '/bin/true & exec sleep 120' &
   sleep 2
   ps -eo pid,ppid,stat,comm,args | awk 'NR==1 || $3 ~ /^Z/'
   ```

   ```text
   # expected output
       PID    PPID STAT COMMAND         COMMAND
      5402    5401 Z    true            [true] <defunct>
   ```

6. Intentá matar al zombi, y después matalo de la única manera que funciona:

   ```bash
   kill -9 5402                          # substitute the zombie PID
   sleep 1
   ps -o pid,stat,comm -p 5402           # still there
   kill 5401                             # substitute the PARENT PID (the sleep)
   sleep 1
   ps -o pid,stat,comm -p 5402           # gone
   ```

7. Contá zombis a nivel de todo el sistema como lo haría un chequeo de monitorización:

   ```bash
   ps -eo stat= | grep -c '^Z'
   awk '/^procs_blocked|^procs_running/' /proc/stat
   ```

### Comprobá tu comprensión

- **Q3.1** — Después de que murió el shell intermedio, el `PPid` del worker cambió. ¿Qué llamada al sistema realiza ese cambio, y en qué momento?
- **Q3.2** — ¿Por qué el nuevo padre fue `systemd --user` (PID 2140) y no el PID 1? Nombrá el mecanismo.
- **Q3.3** — ¿Qué recurso retiene realmente un zombi? ¿Por qué `kill -9` no puede nada contra él?
- **Q3.4** — Tu monitorización reporta 4 000 zombis con el mismo PPID. ¿Cuál es el defecto, y qué proceso reiniciás?
- **Q3.5** — Explicá por qué `bash -c '/bin/true & exec sleep 120'` produce un zombi pero `bash -c '/bin/true & sleep 120'` normalmente no.

---

## Ejercicio 4 — Señales: enviar, capturar, y lo que no se puede capturar

### Pasos

1. Listá las señales que conocen tu kernel y tu shell:

   ```bash
   kill -l
   kill -l TERM KILL HUP INT CONT STOP TSTP
   ```

   ```text
   # expected output
   ...
   15
   9
   1
   2
   18
   19
   20
   ```

2. Escribí un programa que instale manejadores, para que puedas *ver* la entrega:

   ```bash
   cat > trapper.sh <<'EOF'
   #!/bin/bash
   cleanup() { echo "$(date +%T) SIGTERM: releasing lock"; rm -f "$LOCK"; exit 143; }
   reload()  { echo "$(date +%T) SIGHUP: re-reading configuration"; }
   nope()    { echo "$(date +%T) SIGINT: ignored, send SIGTERM to stop me"; }

   LOCK="/tmp/trapper.$$.lock"
   trap cleanup TERM
   trap reload  HUP
   trap nope    INT
   : > "$LOCK"
   echo "pid=$$ lock=$LOCK ready"
   while :; do sleep 1; done
   EOF
   chmod +x trapper.sh
   ./trapper.sh &
   TRAP=$!
   ```

3. Enviá las tres señales capturables, por nombre, por número y por especificación de trabajo:

   ```bash
   kill -HUP  "$TRAP"
   kill -1    "$TRAP"
   kill -s INT "$TRAP"
   kill -INT %+
   ```

   ```text
   # expected output
   14:31:02 SIGHUP: re-reading configuration
   14:31:02 SIGHUP: re-reading configuration
   14:31:03 SIGINT: ignored, send SIGTERM to stop me
   14:31:03 SIGINT: ignored, send SIGTERM to stop me
   ```

   Fijate en que la salida del manejador puede retrasarse hasta un segundo respecto al `kill`.

4. Terminalo educadamente y leé el estado de salida:

   ```bash
   kill -TERM "$TRAP"
   wait "$TRAP"; echo "exit status: $?"
   ls -l /tmp/trapper.$TRAP.lock 2>&1
   ```

   ```text
   # expected output
   14:31:20 SIGTERM: releasing lock
   exit status: 143
   ls: cannot access '/tmp/trapper.5511.lock': No such file or directory
   ```

5. Ahora demostrá que `SIGKILL` y `SIGSTOP` no se pueden interceptar:

   ```bash
   ./trapper.sh &
   TRAP=$!
   kill -STOP "$TRAP"; sleep 1; ps -o pid,stat,comm -p "$TRAP"
   kill -CONT "$TRAP"; sleep 1; ps -o pid,stat,comm -p "$TRAP"
   kill -KILL "$TRAP"
   wait "$TRAP"; echo "exit status: $?"
   ls -l /tmp/trapper.$TRAP.lock
   ```

   ```text
   # expected output
       PID STAT COMMAND
      5540 T    trapper.sh
       PID STAT COMMAND
      5540 S    trapper.sh
   exit status: 137
   -rw-r--r-- 1 you you 0 Aug 26 14:33 /tmp/trapper.5540.lock
   ```

   El archivo de lock sobrevivió. Ese es todo el argumento contra echar mano de `-9` primero.

6. Inspeccioná las máscaras de disposición de señales de un proceso — la forma profesional de responder "¿este daemon va a honrar `SIGHUP`?":

   ```bash
   ./trapper.sh & TRAP=$!
   grep -E '^Sig(Blk|Ign|Cgt)' /proc/$TRAP/status
   ```

   ```text
   # expected output
   SigBlk:	0000000000000000
   SigIgn:	0000000000000000
   SigCgt:	0000000000004003
   ```

   `0x4003` = bits 0, 1, 14 → señales 1 (`HUP`), 2 (`INT`), 15 (`TERM`).

7. Señalizá un **grupo de procesos** entero con un PID negativo, y después verificá:

   ```bash
   setsid ./worker.sh grp > /dev/null 2>&1 &
   sleep 1
   PG=$(ps -o pgid= -p "$(pgrep -n -x worker.sh)" | tr -d ' ')
   ps -eo pid,pgid,comm | awk -v g="$PG" '$2==g'
   kill -TERM -"$PG"
   sleep 1
   ps -eo pid,pgid,comm | awk -v g="$PG" '$2==g'
   ```

8. Leé — **no** ejecutes — las dos formas peligrosas, y después usá `/bin/kill` explícitamente para ver que es un programa distinto:

   ```bash
   type -a kill
   /bin/kill --list | head -5
   /bin/kill %1 2>&1 || echo "external kill does not understand job specs"
   ```

   ```text
   # expected output
   kill is a shell builtin
   kill is /usr/bin/kill
   ...
   /bin/kill: failed to parse argument: '%1'
   external kill does not understand job specs
   ```

9. Limpiá:

   ```bash
   pkill -x trapper.sh; pkill -x worker.sh; rm -f /tmp/trapper.*.lock
   ```

### Comprobá tu comprensión

- **Q4.1** — En el paso 3 la salida del manejador llegó hasta un segundo tarde aunque la señal se entregó de inmediato. Explicá la demora en términos de cómo `bash` ejecuta los traps.
- **Q4.2** — Aparecieron los estados de salida `143` y `137`. Derivá ambos a partir de una sola regla, e indicá dónde está definida esa regla.
- **Q4.3** — ¿Qué dos señales nunca pueden capturarse, bloquearse ni ignorarse, y qué garantía arquitectónica le da eso al operador?
- **Q4.4** — `SigCgt` era `0000000000004003`. Mostrá la aritmética que mapea esa máscara hexadecimal a las señales 1, 2 y 15.
- **Q4.5** — `kill -TERM -1234` y `kill -TERM 1234` difieren en un carácter. ¿Qué hace cada uno? ¿Y qué hace `kill -TERM 0`?
- **Q4.6** — `kill -9 -1` aparece en todos los artículos de "nunca escribas esto". ¿A qué procesos exactamente señalizaría, y le iría mejor o peor a `root` ejecutándolo que a un usuario normal?
- **Q4.7** — `kill` existe tanto como builtin del shell como `/bin/kill`. Dá una capacidad que tenga cada uno y que le falte al otro.
- **Q4.8** — Los números de señal 1, 2, 9 y 15 son idénticos en todas las arquitecturas Linux, pero `SIGSTOP` es 19 en x86-64 y 23 en MIPS. ¿Qué regla operativa se sigue de esto?

---

## Ejercicio 5 — Sobrevivir al logout: `nohup`, `disown`, `setsid`

### Pasos

1. Arrancá un trabajo con `nohup` y leé el mensaje que imprime:

   ```bash
   cd ~/lab-103.5
   nohup ./worker.sh nh &
   sleep 1
   ls -l nohup.out
   ```

   ```text
   # expected output
   nohup: ignoring input and appending output to 'nohup.out'
   -rw-r--r-- 1 you you 132 Aug 26 14:40 nohup.out
   ```

2. Verificá qué cambió `nohup` realmente — no "desacoplado", solo una señal ignorada:

   ```bash
   NH=$(pgrep -n -x worker.sh)
   grep SigIgn /proc/$NH/status
   ps -o pid,ppid,pgid,sid,tty,comm -p "$NH"
   ```

   ```text
   # expected output
   SigIgn:	0000000000000001
       PID    PPID    PGID     SID TT       COMMAND
      5711    3970    5711    3970 pts/1    worker.sh
   ```

   Bit 0 de `SigIgn` → `SIGHUP` ignorada. Pero `TT` sigue siendo `pts/1`, y `SID` sigue siendo la sesión del shell.

3. Comparalo con `disown`, que cambia la contabilidad *del shell* en lugar del proceso:

   ```bash
   ./worker.sh dis > dis.log 2>&1 &
   DIS=$!
   jobs -l
   disown -h %+          # keep in job table, but do not send SIGHUP on shell exit
   jobs -l
   disown %+             # remove from job table entirely
   jobs -l
   grep SigIgn /proc/$DIS/status
   ```

   ```text
   # expected output
   [2]+  5730 Running                 ./worker.sh dis > dis.log 2>&1 &
   [2]+  5730 Running                 ./worker.sh dis > dis.log 2>&1 &
   SigIgn:	0000000000000000
   ```

   Después del segundo `disown`, `jobs -l` no imprime nada — y notá que la máscara de señales nunca cambió.

4. Comparalo con `setsid`, el único de los tres que realmente desacopla:

   ```bash
   setsid ./worker.sh sid > sid.log 2>&1 < /dev/null
   sleep 1
   SID=$(pgrep -n -x worker.sh)
   ps -o pid,ppid,pgid,sid,tty,comm -p "$SID"
   grep SigIgn /proc/$SID/status
   ```

   ```text
   # expected output
       PID    PPID    PGID     SID TT       COMMAND
      5748       1    5748    5748 ?        worker.sh
   SigIgn:	0000000000000000
   ```

   Nueva sesión, nuevo grupo de procesos, **sin terminal de control** (`TT` es `?`), el padre es el PID 1.

5. Ahora simulá un hangup en lugar de adivinar. Abrí una **segunda terminal**, y después en la primera:

   ```bash
   bash            # nested interactive shell; note its PID
   echo "nested shell pid: $$"
   cd ~/lab-103.5
   ./worker.sh plain    > plain.log    2>&1 &
   nohup ./worker.sh nohupped > nohupped.log 2>&1 &
   ./worker.sh disowned > disowned.log 2>&1 & disown -h %+
   setsid ./worker.sh setsid_ > setsid_.log 2>&1 < /dev/null
   pgrep -a -x worker.sh
   ```

6. Desde la **segunda terminal**, colgá el shell anidado exactamente como lo haría una conexión SSH caída:

   ```bash
   kill -HUP <nested-shell-pid>
   sleep 3
   pgrep -a -x worker.sh
   ```

   ```text
   # expected output
   5811 /bin/bash ./worker.sh nohupped
   5814 /bin/bash ./worker.sh disowned
   5818 /bin/bash ./worker.sh setsid_
   ```

   `plain` desapareció; los otros tres sobrevivieron, por tres razones distintas.

7. Examiná la opción del shell que gobierna el caso del *logout limpio*, que no es lo mismo que el caso del hangup:

   ```bash
   shopt huponexit
   ```

   ```text
   # expected output
   huponexit      	off
   ```

8. Limpiá:

   ```bash
   pkill -x worker.sh
   rm -f nohup.out *.log
   ```

### Comprobá tu comprensión

- **Q5.1** — Indicá con precisión qué hace `nohup`. ¿Pone el comando en segundo plano?
- **Q5.2** — ¿A dónde envía `nohup` la salida estándar, y bajo qué condición? ¿Qué hace con la salida de error?
- **Q5.3** — `disown -h %1` y `disown %1` tuvieron efectos idénticos sobre `/proc/PID/status`. Entonces, ¿cuál *es* la diferencia entre ellos, y qué cambian ambos?
- **Q5.4** — `disown` no puede proteger a un trabajo de una fuente concreta de `SIGHUP` de la que `nohup` sí puede. ¿Cuál, y por qué?
- **Q5.5** — Después de `setsid`, `TT` era `?`. ¿Qué dos cosas cortó `setsid`, y por qué eso hace al proceso inmune a las señales generadas por la terminal en general, y no solo a `SIGHUP`?
- **Q5.6** — `huponexit` está `off` por defecto. Entonces, ¿*cuándo* envía `bash` `SIGHUP` a sus trabajos, y cómo se concilia eso con que `plain` muriera en el paso 6?
- **Q5.7** — Tenés que lanzar una migración de datos de 8 horas por SSH y poder *mirar su progreso mañana*. Ordená `nohup`, `disown`, `setsid` y `tmux` para esta tarea y justificá al ganador.

---

## Ejercicio 6 — Seleccionar procesos: `pgrep`, `pkill`, `killall`

### Pasos

1. Creá un script con un nombre deliberadamente largo — de más de 15 caracteres:

   ```bash
   cd ~/lab-103.5
   cp worker.sh collect-metrics-daemon.sh
   cp worker.sh collect-metrics-shipper.sh
   ./collect-metrics-daemon.sh  d1 > /dev/null 2>&1 &
   ./collect-metrics-shipper.sh s1 > /dev/null 2>&1 &
   sleep 1
   ```

2. Observá el truncado a 15 caracteres de `comm` que hace el kernel:

   ```bash
   ps -eo pid,comm,args | grep -E 'collect-metrics' | grep -v grep
   ```

   ```text
   # expected output
      5901 collect-metrics /bin/bash ./collect-metrics-daemon.sh d1
      5903 collect-metrics /bin/bash ./collect-metrics-shipper.sh s1
   ```

   Dos programas distintos, un `comm` indistinguible.

3. Mirá a `pgrep` fallar y después tener éxito:

   ```bash
   pgrep collect-metrics-daemon.sh    ; echo "rc=$?"
   pgrep collect-metrics              ; echo "rc=$?"
   pgrep -f collect-metrics-daemon.sh ; echo "rc=$?"
   pgrep -a -f collect-metrics
   ```

   ```text
   # expected output
   rc=1
   5901
   5903
   rc=0
   5901
   rc=0
   5901 /bin/bash ./collect-metrics-daemon.sh d1
   5903 /bin/bash ./collect-metrics-shipper.sh s1
   ```

4. Ejercitá las opciones de selección que hacen seguros a `pgrep`/`pkill`:

   ```bash
   pgrep -c -u "$USER" -f collect-metrics     # count only
   pgrep -n -f collect-metrics                # newest
   pgrep -o -f collect-metrics                # oldest
   pgrep -x bash                              # exact comm match
   pgrep -P "$$" -a                           # children of this shell
   pgrep -u root -x sshd
   ```

5. Hacé la prueba en seco antes del kill — **siempre**:

   ```bash
   pgrep -a -f 'collect-metrics-daemon\.sh'      # 1. look
   pkill -f 'collect-metrics-daemon\.sh'         # 2. then act
   sleep 1
   pgrep -a -f collect-metrics
   ```

   ```text
   # expected output
   5901 /bin/bash ./collect-metrics-daemon.sh d1
   5903 /bin/bash ./collect-metrics-shipper.sh s1
   ```

6. Ahora reproducí el peligro de truncado de `killall` sobre el superviviente:

   ```bash
   ./collect-metrics-daemon.sh d2 > /dev/null 2>&1 &
   sleep 1
   pgrep -a -f collect-metrics
   killall collect-metrics-daemon.sh
   sleep 1
   pgrep -a -f collect-metrics    ; echo "rc=$?"
   ```

   ```text
   # expected output
   5903 /bin/bash ./collect-metrics-shipper.sh s1
   5940 /bin/bash ./collect-metrics-daemon.sh d2
   rc=1
   ```

   Murieron los dos. Pediste `...daemon.sh` y `killall` se llevó también `...shipper.sh`.

7. Repetilo con la opción que lo evita:

   ```bash
   ./collect-metrics-daemon.sh  d3 > /dev/null 2>&1 &
   ./collect-metrics-shipper.sh s3 > /dev/null 2>&1 &
   sleep 1
   killall -e collect-metrics-daemon.sh ; echo "rc=$?"
   killall -r 'collect-metrics-daemon' ; echo "rc=$?"
   sleep 1
   pgrep -a -f collect-metrics
   ```

8. Enviá una señal específica, no solo `SIGTERM`, y observá la regla de auto-coincidencia de `pkill`:

   ```bash
   pkill -HUP -x sshd -u root 2>/dev/null; echo "rc=$? (1 = no match, normal as non-root)"
   pgrep -f pgrep                    ; echo "rc=$? (pgrep never matches itself)"
   ```

9. Limpiá:

   ```bash
   pkill -f collect-metrics
   rm -f collect-metrics-*.sh
   ```

### Comprobá tu comprensión

- **Q6.1** — ¿Por qué `comm` está limitado a 15 caracteres? Nombrá la constante del kernel y su valor.
- **Q6.2** — `pgrep collect-metrics-daemon.sh` no devolvió nada con `rc=1`, y sin embargo el proceso existía. ¿Contra qué campo hace coincidencia `pgrep` por defecto, y qué opción cambia eso?
- **Q6.3** — En el paso 3, el `pgrep collect-metrics` a secas coincidió con **ambos** scripts. ¿Fue una coincidencia por subcadena o una coincidencia exacta? ¿Qué opción habría forzado una coincidencia exacta, y habría ayudado acá?
- **Q6.4** — Explicá, en términos de `procps-ng`, por qué `killall collect-metrics-daemon.sh` mató también al shipper, y qué cambia `-e`.
- **Q6.5** — En un host Solaris, `killall` ejecutado como root hace algo categóricamente distinto que en Linux. ¿Qué, y qué disciplina impone eso en scripts portables?
- **Q6.6** — `pgrep` y `pkill` nunca coinciden consigo mismos. Dá un escenario realista en el que `pkill -f backup` de todos modos mate al propio script que lo ejecutó.
- **Q6.7** — Escribí el único comando más seguro que envíe `SIGHUP` exactamente al proceso maestro de `nginx` propiedad de `root`, y explicá cada opción.

---

## Ejercicio 7 — Monitorización en vivo: `top`, `uptime`, `free`

### Pasos

1. Establecé una línea base, y después creá carga:

   ```bash
   uptime
   nproc
   for i in 1 2 3; do ~/lab-103.5/burner.sh & done
   ```

   ```text
   # expected output
    14:58:03 up  5:43,  2 users,  load average: 0.31, 0.24, 0.19
   8
   ```

2. Arrancá `top` y recorré sus teclas interactivas. Presioná cada una y observá:

   ```bash
   top
   ```

   | Tecla | Efecto |
   |---|---|
   | `h` | pantalla de ayuda |
   | `1` | expande la línea de CPU en una fila por CPU lógica |
   | `P` | ordena por `%CPU` (por defecto) |
   | `M` | ordena por `%MEM` |
   | `T` | ordena por `TIME+` acumulado |
   | `R` | invierte el orden de ordenación actual |
   | `u` | filtra por usuario (escribí tu nombre de usuario) |
   | `c` | alterna `COMMAND` entre `comm` y la línea de comandos completa |
   | `V` | vista de bosque/árbol |
   | `H` | muestra hilos individuales en lugar de procesos |
   | `I` | alterna el modo Irix (escalado de `%CPU` por CPU vs. por máquina) |
   | `d` | cambia el retardo de refresco (probá con `5`) |
   | `f` | pantalla de gestión de campos: agregá `PPID`, `nTH`, `S` |
   | `k` | kill: pide el PID, y después la señal |
   | `W` | escribe la disposición actual en `~/.config/procps/toprc` |
   | `q` | salir |

3. Leé el área de resumen con atención mientras corren los burners:

   ```text
   # expected output
   top - 14:59:41 up  5:45,  2 users,  load average: 2.71, 1.06, 0.48
   Tasks: 312 total,   4 running, 308 sleeping,   0 stopped,   0 zombie
   %Cpu(s): 37.6 us,  0.4 sy,  0.0 ni, 61.9 id,  0.0 wa,  0.1 hi,  0.0 si,  0.0 st
   MiB Mem :  15884.0 total,   6301.4 free,   3211.8 used,   6370.8 buff/cache
   MiB Swap:   8192.0 total,   8192.0 free,      0.0 used.  11702.3 avail Mem

       PID USER      PR  NI    VIRT    RES    SHR S  %CPU  %MEM     TIME+ COMMAND
      6011 you       20   0    8120   3456   3072 R  99.7   0.0   1:24.11 burner.sh
      6012 you       20   0    8120   3452   3072 R  99.7   0.0   1:24.09 burner.sh
      6013 you       20   0    8120   3456   3072 R  99.3   0.0   1:24.02 burner.sh
   ```

4. Salí de `top` y usá el modo batch que realmente pondrías en un script o en un ticket:

   ```bash
   top -b -n 1 -o %CPU | head -12
   top -b -n 2 -d 1 -p "$(pgrep -d, -x burner.sh)" | tail -8
   ```

5. Correlacioná la carga media con su fuente en el kernel:

   ```bash
   cat /proc/loadavg
   ```

   ```text
   # expected output
   2.71 1.06 0.48 4/1247 6103
   ```

6. Leé la memoria de la manera correcta:

   ```bash
   free -h
   free -h -w
   free -m -s 2 -c 3
   grep -E '^(MemTotal|MemFree|MemAvailable|Buffers|Cached|SwapTotal|SwapFree)' /proc/meminfo
   ```

   ```text
   # expected output
                  total        used        free      shared  buff/cache   available
   Mem:            15Gi       3.1Gi       6.1Gi       412Mi       6.2Gi        11Gi
   Swap:          8.0Gi          0B       8.0Gi
   ```

7. Detené la carga y confirmá que la carga media decae en lugar de desplomarse:

   ```bash
   pkill -x burner.sh
   uptime; sleep 60; uptime
   ```

### Comprobá tu comprensión

- **Q7.1** — La carga media llegó a 2.71 en una máquina de 8 CPUs. ¿Está sobrecargada la máquina? Enunciá la regla que relaciona la carga media con `nproc`.
- **Q7.2** — La carga media de Linux cuenta algo que la carga media clásica de UNIX no cuenta. ¿Qué, y por qué eso hace que una carga alta en un host limitado por E/S signifique otra cosa?
- **Q7.3** — En `/proc/loadavg`, el campo `4/1247` y el `6103` final — ¿qué son?
- **Q7.4** — En el paso 7 se mataron los burners pero `uptime` seguía mostrando ~2.0 inmediatamente después. ¿Por qué eso no es un bug?
- **Q7.5** — `%Cpu(s)` mostró `61.9 id` y `0.0 wa`. Definí `us`, `sy`, `ni`, `id`, `wa`, `hi`, `si`, `st` — y decí cuál sería distinto de cero en una VM ocupada cuyo hipervisor está sobresuscrito.
- **Q7.6** — `free -h` muestra `free` 6.1 Gi pero `available` 11 Gi. Explicá la diferencia, y decí qué cifra debe usar una alerta de capacidad.
- **Q7.7** — Un proceso multihilo muestra un `%CPU` de `340.0` en `top`. ¿Es un bug? ¿Qué tecla de `top` cambia la escala de ese número, y qué muestra la otra escala en su lugar?
- **Q7.8** — Tanto `top` como `ps` imprimen una columna `%CPU` y habitualmente discrepan para el mismo PID. Explicá la diferencia de medición (esto repite la Q2.6 deliberadamente — es la columna peor interpretada del examen y de la práctica).
- **Q7.9** — Nombrá dos cosas que la tecla `k` de `top` puede hacer y que `kill <pid>` por sí solo no puede, y un riesgo de usarla.

---

## Ejercicio 8 — Observación repetida con `watch`

### Pasos

1. Observá un valor cambiante con resaltado de cambios:

   ```bash
   ~/lab-103.5/worker.sh w1 > ~/lab-103.5/w1.log 2>&1 &
   watch -n 1 -d 'tail -3 ~/lab-103.5/w1.log; echo; free -m | head -2'
   ```

   Presioná `Ctrl-C` para salir.

2. Compará los comportamientos del entrecomillado — acá es donde se rompen la mayoría de los one-liners con `watch`:

   ```bash
   watch -n 2 ps -eo pid,stat,comm --sort=-%cpu          # WRONG: shell eats --sort? no; watch eats -n? no — see Q8.2
   watch -n 2 'ps -eo pid,stat,comm --sort=-%cpu | head'
   watch -n 2 -x ps -eo pid,stat,comm --sort=-%cpu
   ```

3. Usá el modo de salida-al-cambiar como una condición de espera barata:

   ```bash
   watch -g -n 1 'pgrep -c -x worker.sh'; echo "count changed, rc=$?"
   # in another terminal: pkill -x worker.sh
   ```

4. Quitá el encabezado y fijá temporizaciones precisas:

   ```bash
   watch -t -n 0.5 'date +%T.%N; cat /proc/loadavg'
   watch -n 5 -b 'systemctl --user is-active dbus'; echo "rc=$?"
   ```

5. Entendé qué *no* es `watch`:

   ```bash
   watch -n 1 'echo $$'      # what does this print, and does it change?
   ```

### Comprobá tu comprensión

- **Q8.1** — ¿Cuál es el intervalo por defecto de `watch`, y qué agrega `-d`?
- **Q8.2** — En el paso 2, ¿por qué la forma *sin comillas* igual funciona para `ps` pero se rompe en cuanto agregás `| head`? ¿Qué opción ejecuta el comando sin un shell, y qué perdés al usarla?
- **Q8.3** — `watch -g` y `watch -e` salen ambos anticipadamente. ¿Bajo qué condición sale cada uno?
- **Q8.4** — `watch -n 1 'top'` es una mala idea. Dá dos razones independientes.
- **Q8.5** — ¿Es `watch` una herramienta de monitorización en el sentido en que lo es `top`? Enunciá la diferencia fundamental en lo que mide cada una.

---

## Ejercicio 9 — Sesiones persistentes: `screen` y `tmux`

### Pasos

1. Con `screen`, creá una sesión con nombre, ejecutá trabajo, desacoplate y volvé a acoplarte:

   ```bash
   screen -S migration
   # inside: run the long job
   ~/lab-103.5/worker.sh scr
   # detach:  Ctrl-a  then  d
   ```

   ```bash
   screen -ls
   ```

   ```text
   # expected output
   There is a screen on:
           6211.migration  (26/08/26 15:20:04)     (Detached)
   1 Socket in /run/screen/S-you.
   ```

2. Inspeccioná qué le hizo `screen` al árbol de procesos:

   ```bash
   ps -eo pid,ppid,pgid,sid,tty,comm | grep -E 'screen|worker' | grep -v grep
   ```

   ```text
   # expected output
      6211       1    6211    6211 ?        screen
      6212    6211    6212    6212 pts/3    bash
      6240    6212    6240    6212 pts/3    worker.sh
   ```

3. Volvé a acoplarte, y aprendé la opción que necesitás cuando la sesión está marcada como acoplada por error:

   ```bash
   screen -r migration
   # Ctrl-a d again
   screen -d -r migration     # detach it elsewhere, then attach here
   screen -x migration        # multi-attach: both terminals see the same screen
   ```

4. Repetí con `tmux`:

   ```bash
   tmux new -s migration
   # inside: ~/lab-103.5/worker.sh tmx
   # detach:  Ctrl-b  then  d
   tmux ls
   tmux attach -t migration
   tmux kill-session -t migration
   ```

   ```text
   # expected output
   migration: 1 windows (created Tue Aug 26 15:24:11 2026) [190x48]
   ```

5. Demostrá la propiedad de supervivencia contra el mismo hangup que usaste en el Ejercicio 5. Desde una segunda terminal:

   ```bash
   pgrep -a -x worker.sh
   kill -HUP $(pgrep -n -x bash)   # hang up an interactive shell (NOT the screen/tmux server)
   sleep 2
   pgrep -a -x worker.sh           # the screen/tmux job is still there
   ```

6. Limpiá:

   ```bash
   screen -S migration -X quit
   tmux kill-server 2>/dev/null
   pkill -x worker.sh
   rm -rf ~/lab-103.5
   ```

### Comprobá tu comprensión

- **Q9.1** — En el paso 2, el proceso `screen` tiene `PPID 1`, `TTY ?`, y su propio `SID`. ¿A qué comando del Ejercicio 5 se parece eso, y qué agrega `screen` por encima?
- **Q9.2** — Tu trabajo dentro de `screen` tiene `TTY pts/3`. Si tu conexión SSH se cae, `pts/3` no desaparece. ¿Por qué no?
- **Q9.3** — `screen -r` vs `screen -d -r` vs `screen -x`: dá el caso de uso de una frase para cada uno.
- **Q9.4** — Nombrá una ventaja concreta que `tmux` tiene sobre `screen`, y una situación en la que `screen` sigue siendo la elección pragmática.
- **Q9.5** — Estás en un host remoto que no tiene ni `screen` ni `tmux` y no hay acceso a paquetes. Dá el sustituto más cercano para un trabajo de 6 horas que tenés que poder controlar más tarde, e indicá con precisión qué resignás.

---

## Ejercicio 10 — Escenario de diagnóstico: el proceso desbocado

> Salta una alerta de monitorización: `load average: 47.2` en un servidor de aplicaciones de 8 CPUs. Los usuarios reportan que la interfaz web se cuelga. Tenés SSH y `sudo`. Resolvelo como un runbook.

### Pasos

1. Confirmá la alerta y clasificá la carga de un solo tiro:

   ```bash
   uptime; nproc; cat /proc/loadavg
   ps -eo stat= | sort | uniq -c | sort -rn | head -5
   ```

2. Decidí si es presión de CPU o presión de E/S antes de tocar nada:

   ```bash
   top -b -n 2 -d 1 | awk '/^%Cpu/{print}' 
   ps -eo pid,stat,wchan:24,comm | awk '$2 ~ /D/'
   ```

3. Si es CPU: identificá a los principales consumidores por uso *instantáneo*, no por el promedio de toda su vida:

   ```bash
   top -b -n 2 -d 1 -o %CPU | tail -20
   ```

4. Establecé la procedencia antes de matar nada — quién lo arrancó, desde dónde, desde cuándo:

   ```bash
   PID=<offender>
   ps -o pid,ppid,user,lstart,etimes,pgid,sid,tty,stat,%cpu,rss,args -p "$PID"
   ps -o pid,user,args -p "$(ps -o ppid= -p "$PID" | tr -d ' ')"
   ls -l /proc/$PID/exe /proc/$PID/cwd
   pgrep -c -P "$PID"
   ```

5. Intentá que se detenga *ordenadamente*, y dale tiempo:

   ```bash
   sudo kill -TERM "$PID"
   sleep 10
   ps -o pid,stat,comm -p "$PID" || echo "gone"
   ```

6. Si ignora `SIGTERM`, chequeá si siquiera *puede* responder:

   ```bash
   grep -E '^(State|SigBlk|SigIgn|SigCgt)' /proc/$PID/status
   ```

7. Escalá solo después de eso, y al **grupo** de procesos si generó hijos:

   ```bash
   PG=$(ps -o pgid= -p "$PID" | tr -d ' ')
   ps -eo pid,pgid,comm | awk -v g="$PG" '$2==g'
   sudo kill -TERM -"$PG"
   sleep 10
   sudo kill -KILL -"$PG"
   ```

8. Verificá la recuperación y dejá evidencia en el ticket:

   ```bash
   sleep 60; uptime
   ps -eo stat= | grep -c '^Z'
   ```

### Comprobá tu comprensión

- **Q10.1** — Carga 47 en 8 CPUs, pero `%Cpu(s)` muestra `2.1 us, 1.0 sy, 94.0 wa`. ¿Cuál es el problema real, y por qué matar al proceso con mayor `%CPU` sería la jugada equivocada?
- **Q10.2** — En el paso 4, ¿por qué `lstart`/`etimes` importan más que `TIME+` para el informe del incidente?
- **Q10.3** — El paso 6 encuentra `State: D (disk sleep)` y `SigCgt: 0000000000000000`. Predecí el resultado de `kill -9` y explicalo.
- **Q10.4** — El paso 7 señaliza el PGID negativo en lugar del PID. ¿Qué modo de fallo previene eso?
- **Q10.5** — El culpable resulta ser un servicio de `systemd`. ¿Por qué `systemctl stop` es preferible a `kill` acá, aunque ambos envíen `SIGTERM`?
- **Q10.6** — Escribí la escalera de escalado correcta más corta para un proceso que no responde, de menos a más destructiva, con la espera que deberías conceder en cada escalón.

---

<details>
<summary><strong>Respuestas</strong> — expandí solo después de intentar cada bloque</summary>

### Ejercicio 0

**A0.1** — La **disciplina de línea de la terminal** en el kernel (el driver `N_TTY`), no `bash`. Cuando el driver lee un carácter que coincide con el ajuste configurado de `intr`, `susp` o `quit`, genera la señal correspondiente (`SIGINT`, `SIGTSTP`, `SIGQUIT`) y la entrega a **todos los procesos del grupo de procesos en primer plano de la terminal de control**. Por eso `Ctrl-C` sobre una tubería de shell mata la tubería entera: todos sus miembros comparten un grupo de procesos. `bash` solo se encarga, vía `tcsetpgrp()`, de *qué* grupo está en primer plano.

**A0.2** — Con el modo monitor apagado, `bash` no crea un grupo de procesos separado por trabajo. Un comando arrancado con `&` dentro de un script se queda en el grupo de procesos del script y mantiene la misma terminal de control, así que un `Ctrl-C` en la terminal también lo alcanza. Tampoco hay maquinaria de notificación de `jobs`/`fg`/`bg`, y las especificaciones de trabajo del estilo `%1` no están disponibles. Por esto los trabajos en segundo plano lanzados desde scripts de cron/systemd se comportan distinto de la misma línea escrita interactivamente.

**A0.3** — `$$` es el PID del proceso `bash` que *interpreta el script* (el proceso que el kernel creó para `./worker.sh`), y `$PPID` es el shell interactivo que lo forkeó. `$$` deliberadamente **no** se actualiza en subshells, y por eso `(echo $$)` imprime el PID del padre — usá `$BASHPID` cuando necesites el PID actual real.

### Ejercicio 1

**A1.1** — Ambos envían **`SIGCONT`**. `fg` además llama a `tcsetpgrp()` para hacer que el grupo de procesos del trabajo sea el grupo de procesos en *primer plano* de la terminal de control, de modo que el trabajo pueda leer de la terminal y reciba las señales generadas por ella; después el shell hace `wait` por él. `bg` deja al shell en primer plano y devuelve el prompt de inmediato.

**A1.2** — `$!` es el PID del **proceso `bash` que ejecuta `worker.sh`** — el hijo directo de tu shell interactivo, es decir, el líder del grupo de procesos del trabajo. El `sleep 2` es un nieto con su propio PID; `$!` nunca se refiere a él.

**A1.3** — La tabla de trabajos es una estructura de datos privada de cada instancia de shell, mantenida en la memoria de ese shell y **no heredada a través de `fork`/`exec`**. `bash -c` es un shell completamente nuevo sin trabajos propios, así que reporta correctamente una lista vacía, lo cual no es una condición de error — de ahí el exit 0. Corolario para scripts: no podés hacer `fg` de un trabajo arrancado por otro shell; usá PIDs.

**A1.4** — No. Un proceso detenido no se planifica, así que nunca llega a un punto en el que una señal pendiente pueda entregarse y actuar. `SIGTERM` queda pendiente. Primero tenés que reanudarlo: `kill -CONT %2` (o `bg %2` / `fg %2`), tras lo cual la `SIGTERM` pendiente se entrega y el proceso muere. El one-liner idiomático es `kill -TERM %2; kill -CONT %2`. `SIGKILL` es la excepción — el kernel destruye una tarea detenida sin necesidad de planificarla.

**A1.5** — `bash` advierte `There are stopped jobs.` y **se niega a salir** en el primer intento; un segundo `exit` procede. La protección existe porque si no un trabajo detenido quedaría suspendido para siempre sin una terminal desde la que reanudarlo — a diferencia de un trabajo `Running` en segundo plano, que al menos sigue avanzando.

**A1.6** — `%beta` (equivalentemente `%beta*`) coincide con un trabajo cuya línea de comandos **empieza con** `beta`. `%?beta` coincide con un trabajo cuya línea de comandos **contiene** `beta` en cualquier lugar. En el ejercicio la línea de comandos es `./worker.sh beta`, que empieza con `.`, así que solo coincide `%?beta`.

### Ejercicio 2

**A2.1** — `ps` acepta tres estilos de opciones mutuamente incompatibles: BSD (sin guion), UNIX/POSIX (un guion) y GNU (doble guion). La semántica POSIX/UNIX exige que `ps -aux` signifique "`-a` (todos los procesos con terminal, salvo los líderes de sesión) **más** todos los procesos que pertenezcan a un usuario literalmente llamado `x`". `procps-ng` comprueba si existe un usuario `x`; cuando no existe, reinterpreta caritativamente el pedido como el `aux` de BSD e imprime la advertencia. En un sistema que casualmente tenga un usuario llamado `x`, obtenés en silencio una salida distinta — que es la verdadera razón para nunca escribir `-aux`.

**A2.2** — `WCHAN` es la función del kernel en la que la tarea está bloqueada. `worker.sh` está en `do_wait`: llamó a `wait4()` y está bloqueado hasta que su hijo `sleep` salga. El `sleep` está en `hrtimer_nanosleep`: está bloqueado en un temporizador de alta resolución. Ambos están en sueño interrumpible (`S`), así que ambos reaccionarán a una señal de inmediato.

**A2.3** — `D` es **sueño ininterrumpible**: la tarea está bloqueada dentro de una llamada al kernel que no puede interrumpirse por señales, casi siempre esperando E/S de bloques o un sistema de archivos de red que no responde (NFS, iSCSI, un dispositivo atascado). `SIGKILL` se registra como pendiente pero **no puede surtir efecto** hasta que la syscall termine; mientras tanto el proceso es inmatable. Estados `D` persistentes apuntan al almacenamiento, no al proceso. (Algunos caminos usan `D` con la variante `TASK_KILLABLE`, que *sí* honra `SIGKILL` — pero no podés distinguir cuál desde `ps`.)

**A2.4** —
- `Ssl` = `S` sueño interrumpible · `s` líder de sesión · `l` multihilo (tiene hilos clonados).
- `R+` = `R` ejecutándose o ejecutable (en una cola de ejecución) · `+` en el **grupo de procesos en primer plano** de su terminal de control.
Otros modificadores: `<` prioridad alta (nice negativo), `N` prioridad baja (nice positivo), `L` tiene páginas bloqueadas en memoria, `T` detenido por una señal de control de trabajos, `t` detenido por un depurador durante el trazado, `Z` zombi, `I` hilo del kernel ocioso, `X` muerto.

**A2.5** — `RSS` (resident set size) está más cerca: cuenta solo las páginas físicas actualmente residentes, mientras que `VSZ` cuenta todo el espacio de direcciones virtual, incluidas reservas, regiones mapeadas pero nunca tocadas y bibliotecas compartidas que quizá nunca se paginen. Pero `RSS` **cuenta las páginas compartidas completas para cada proceso que las mapea** — sumá `RSS` en todos los procesos y sobrecontás masivamente `libc`, los binarios respaldados por la caché de páginas y la memoria compartida de los workers forkeados. Para una cifra por proceso que sume honestamente, usá `PSS` (proportional set size) de `/proc/PID/smaps_rollup`.

**A2.6** — No es instantánea. `ps` calcula `%CPU = cputime / elapsed_time × 100`, donde `cputime` es el tiempo total de usuario+sistema consumido desde que el proceso arrancó (`times`) y `elapsed` es su antigüedad en tiempo de reloj (`etimes`). Es, por lo tanto, un **promedio de toda su vida**: un proceso que clavó una CPU durante su primer minuto y estuvo ocioso la última hora sigue mostrando un número pequeño que decrece lentamente. `top` recalcula a partir de deltas entre refrescos y reporta el último intervalo.

**A2.7** — El primer `COMMAND` es el especificador de formato `comm`, tomado de `/proc/PID/comm`, y está limitado a **15 caracteres** (ver A6.1). El segundo es `args` (con alias `cmd`), tomado de `/proc/PID/cmdline`, que muestra el vector de argumentos completo. `cmdline` vive en el propio espacio de direcciones del proceso, así que un proceso puede **reescribirlo** (al estilo `setproctitle`, como hacen `sshd`, `postgres` y `nginx`). `comm` también puede cambiarse, pero solo vía `prctl(PR_SET_NAME)` y solo dentro de 15 caracteres. Ninguno de los dos campos es confiable para decisiones de seguridad.

### Ejercicio 3

**A3.1** — El hijo no invoca ninguna llamada al sistema. Cuando un padre termina, **el kernel realiza el reparentado dentro de `do_exit()`**: como parte del desmantelamiento de la tarea que sale, recorre su lista de hijos y reasigna el puntero al padre de cada hijo. El hijo solo observa que su `PPid` cambió la próxima vez que lo mira.

**A3.2** — Porque `systemd --user` se marca a sí mismo como **child subreaper** vía `prctl(PR_SET_CHILD_SUBREAPER, 1)`. El kernel reparenta un huérfano al ancestro más cercano que tenga esa bandera activada, y solo recurre al PID 1 (o al init del espacio de nombres de PIDs) si no hay ninguno. Los runtimes de contenedores, `tini` y las unidades de servicio de `systemd` usan el mismo mecanismo, y por eso "los huérfanos siempre van al PID 1" es folklore que ya no se sostiene en un escritorio moderno ni dentro de un contenedor.

**A3.3** — Solo una **entrada en la tabla de procesos**: su PID y su estado de salida, retenidos para que el padre pueda recuperarlos con `wait()`. Todos los demás recursos — memoria, descriptores de archivo, el espacio de direcciones — ya se liberaron al salir. `kill -9` falla porque no queda contexto de ejecución que matar; la tarea ya está muerta. El zombi desaparece en el instante en que alguien lo recolecta. Matar al padre funciona porque el reparentado entrega el hijo a un subreaper o a init, que llama a `wait()` en bucle y lo recolecta de inmediato.

**A3.4** — El defecto está en el **padre**: forkea hijos pero nunca llama a `wait()`/`waitpid()`, o instaló `SIG_IGN`/un manejador roto para `SIGCHLD`. Reiniciá el *padre*, no los zombis. Lo que está en juego operativamente es el agotamiento de PIDs — revisá `cat /proc/sys/kernel/pid_max`; cada zombi mantiene un PID como rehén.

**A3.5** — Con `exec`, el proceso `bash` es **reemplazado en el lugar** por `sleep`. El PID y las relaciones padre/hijo sobreviven al `exec`, así que `sleep` hereda al recién salido `/bin/true` como hijo — y `sleep` nunca llama a `wait()`, con lo cual el zombi persiste durante sus 120 segundos completos. Sin `exec`, `bash` sigue siendo el padre; `bash` recolecta los hijos en segundo plano como parte de su manejo normal de `SIGCHLD` y de la contabilidad de trabajos, así que el zombi se limpia casi al instante.

### Ejercicio 4

**A4.1** — `bash` no puede interrumpir a un hijo en primer plano. Cuando la señal llega, `bash` marca el trap como pendiente, y ejecuta el manejador solo **después de que el comando en primer plano en curso termine** — acá, después de que retorne el `sleep 1` en vuelo. De ahí hasta un segundo de latencia. El arreglo estándar para un script que deba reaccionar rápido es `sleep 300 & wait $!`, porque `bash` *sí* interrumpe el builtin `wait` para ejecutar un trap.

**A4.2** — La regla es **`128 + número_de_señal`**: `128 + 15 = 143` para `SIGTERM`, `128 + 9 = 137` para `SIGKILL`. Es una convención del shell definida en la especificación POSIX Shell & Utilities para `$?` (e implementada por `bash`, `dash`, `ksh`, `zsh`), que necesita distinguir un código de salida normal de una terminación por señal en un único valor de 8 bits. Notá la ambigüedad que crea: un programa que genuinamente hace `exit(143)` es indistinguible de uno al que le mandaron `SIGTERM`. `wait -n` junto con `WIFSIGNALED` a nivel de C es la ruta sin ambigüedad.

**A4.3** — **`SIGKILL` (9)** y **`SIGSTOP` (19 en x86-64)**. Garantizan que el operador siempre conserva dos capacidades que ningún programa puede revocar: la capacidad de terminar cualquier proceso que le pertenezca, y la de congelarlo para inspeccionarlo. Sin eso, un proceso con errores u hostil podría instalar manejadores para todo y volverse genuinamente imparable. El costo es que ninguna de las dos le da al proceso la oportunidad de limpiar — de ahí `SIGTERM` primero.

**A4.4** — La máscara es un mapa de bits de 64 bits donde **el bit *n*−1 corresponde a la señal *n*** (bit 0 = señal 1). `0x4003` = binario `100 0000 0000 0011`. Bit 0 activo → señal 1 = `SIGHUP`. Bit 1 activo → señal 2 = `SIGINT`. Bit 14 activo → señal 15 = `SIGTERM`. Leer `SigIgn` y `SigCgt` de `/proc/PID/status` es la respuesta definitiva a "¿este daemon soporta recarga por `SIGHUP`?" — mucho más confiable que la documentación.

**A4.5** —
- `kill -TERM 1234` → señaliza **el único proceso** con PID 1234.
- `kill -TERM -1234` → señaliza **a todos los procesos del grupo de procesos 1234**. Un PID negativo significa "grupo de procesos".
- `kill -TERM 0` → señaliza **a todos los procesos del propio grupo de procesos del llamador**, lo que incluye al shell que llama. Escribirlo interactivamente mata tu sesión.

**A4.6** — El PID `-1` es un valor especial que significa "**todos los procesos que el llamador tiene permiso de señalizar**", excluyendo al proceso que llama y al PID 1. Como usuario normal mata todos *tus* procesos — tus shells, tu sesión de escritorio, tus conexiones SSH; quedás deslogueado. Como `root` mata esencialmente **todos los procesos del sistema salvo init**, tumbando `sshd`, la base de datos y el daemon de logging simultáneamente, sin ninguna secuencia de apagado. A root le va estrictamente peor.

**A4.7** — El **builtin** entiende las especificaciones de trabajo del shell (`kill %1`, `kill %+`) porque solo el shell conoce su tabla de trabajos; el binario externo no puede. El **`/bin/kill` externo** (util-linux) ofrece funciones que le faltan al builtin, en particular `--timeout` para el patrón de escalar-tras-N-milisegundos, `--queue`/`--value` para señales de tiempo real con `sigqueue()` y payload, y `--verbose`. También es el que obtenés desde `find -exec`, `xargs` y cualquier contexto que no sea un shell.

**A4.8** — **Señalizá siempre por nombre, nunca por número, en cualquier cosa portable.** `signal(7)` documenta la divergencia: `SIGUSR1` es 10 en x86/ARM, 30 en Alpha/SPARC, 16 en MIPS; `SIGSTOP` es 19, 17 y 23 respectivamente. Solo las señales 1–2 (`HUP`, `INT`), 3 (`QUIT`), 9 (`KILL`), 11 (`SEGV`), 13 (`PIPE`) y 15 (`TERM`) son estables en todas las arquitecturas Linux. `kill -USR1` es correcto en todos lados; `kill -10` es correcto en tu laptop.

### Ejercicio 5

**A5.1** — `nohup` hace exactamente dos cosas: fija la disposición de **`SIGHUP` a `SIG_IGN`**, y redirige la salida si la salida estándar es una terminal (ver A5.2). Después hace `exec` del comando pedido, que hereda la disposición ignorada a través de `execve()`. **No** pone nada en segundo plano — tenés que agregar `&` vos mismo. No forkea, no crea una nueva sesión y no se desacopla de la terminal de control.

**A5.2** — Si la salida estándar es una terminal, `nohup` la **anexa** a `nohup.out` en el directorio actual; si ese no es escribible, cae a `$HOME/nohup.out`. Si la salida estándar ya está redirigida, `nohup` la deja en paz. La salida de error, si es una terminal, se redirige a la **salida estándar** — así que ambos flujos terminan intercalados en el mismo archivo. También informa `ignoring input`, porque la entrada estándar queda como está y un proceso en segundo plano que lea de la terminal recibe `SIGTTIN`.

**A5.3** — Ambos eliminan la obligación del shell de enviar `SIGHUP` a ese trabajo, pero difieren en la contabilidad. `disown -h %1` **mantiene el trabajo en la tabla de trabajos** (así que `jobs`, `fg`, `bg` y `wait` siguen funcionando con él) y meramente lo marca como "no enviar `SIGHUP`". El `disown %1` a secas **elimina la entrada por completo** — ya no podés hacerle `fg`, y el seguimiento al estilo `$!` desaparece; te quedás con el PID. Ninguno toca el proceso: cambian *el comportamiento del shell*, y por eso `SigIgn` siguió en `0`.

**A5.4** — `disown` no puede proteger contra una `SIGHUP` enviada por el **kernel** cuando se cuelga la terminal de control. Al desconectarse la terminal, el kernel envía `SIGHUP` directamente al grupo de procesos en primer plano de esa sesión, saltándose por completo al shell. `nohup` la sobrevive porque *el proceso mismo* ignora la señal; `disown` solo impide que *el shell* envíe la suya. En la práctica un trabajo en segundo plano al que se le hizo `disown` normalmente sobrevive igual — no está en el grupo de procesos en primer plano — pero es una garantía más débil.

**A5.5** — `setsid` llama a `setsid(2)`, que convierte al llamador en líder de una **nueva sesión** y de un **nuevo grupo de procesos**, y lo desvincula de la **terminal de control**. Ambas rupturas importan: las señales generadas por la terminal (`SIGINT`, `SIGQUIT`, `SIGTSTP`, `SIGHUP` por hangup) se entregan a grupos de procesos dentro de la sesión de una terminal de control. Sin terminal de control y con una sesión propia, ninguna de esas puede alcanzar al proceso. Este es el paso clásico de daemonización, y la razón por la que `TT` muestra `?`.

**A5.6** — `bash` envía `SIGHUP` a sus trabajos en dos casos: (a) cuando **`bash` mismo recibe `SIGHUP`** — un shell de login interactivo entonces la reenvía a todos los trabajos; y (b) al **salir normalmente**, solo si `shopt -s huponexit` está habilitado. El paso 6 fue el caso (a): enviaste `SIGHUP` explícitamente al shell anidado, que la reenvió, y `plain` — sin disposición de ignorar y todavía en la tabla de trabajos — murió. Que `huponexit` esté apagado es la razón por la que salir de un shell normalmente suele dejar vivos los trabajos en segundo plano.

**A5.7** — **Gana `tmux` (o `screen`)**, claramente. `nohup`, `disown` y `setsid` hacen todos que el trabajo *sobreviva*, pero te dejan solo con un archivo de log — no hay terminal interactiva a la que reacoplarse, así que "mirar su progreso mañana" significa `tail -f` en el mejor de los casos, y cualquier pregunta que el trabajo emita queda sin responder. `tmux` mantiene un pty vivo propiedad de un proceso servidor fuera de tu sesión de login: te reacoplás y estás de vuelta dentro del programa en ejecución, con scrollback y todo. Ranking: `tmux` > `setsid` (desacople real, pero sin reacople) > `nohup` (sobrevive al caso común, salida a un archivo) > `disown` (solo retroactivo — es lo que usás cuando *te olvidaste* de planificar).

### Ejercicio 6

**A6.1** — Porque `comm` se almacena en un campo de tamaño fijo dentro del `task_struct` del kernel, dimensionado por **`TASK_COMM_LEN`, que vale 16 bytes** — 15 caracteres más el NUL terminador. Mantenerlo de tamaño fijo y dentro del kernel implica que `comm` siempre es legible, no puede irse a swap y no necesita bloqueos contra el propio espacio de direcciones del proceso (a diferencia de `cmdline`, que vive en memoria de usuario y puede ser ilegible o falsificado).

**A6.2** — `pgrep` hace coincidencia contra **`comm`** por defecto — el nombre truncado a 15 caracteres. `pgrep -f` hace coincidencia contra la **línea de comandos completa** (`/proc/PID/cmdline`) en su lugar. Dado que el `comm` truncado era `collect-metrics`, el patrón de 27 caracteres nunca podía coincidir.

**A6.3** — Una **coincidencia por subcadena (ERE)**: el patrón `collect-metrics` es una expresión regular extendida que se busca en cualquier parte de `comm`, así que coincidió con el nombre truncado de ambos scripts. **`-x`** fuerza a que el patrón coincida con el campo entero exactamente. **No** habría ayudado acá — `pgrep -x collect-metrics` seguiría coincidiendo con ambos, porque tras el truncado sus valores de `comm` son *idénticos*. Solo `-f` (línea de comandos completa) puede distinguirlos.

**A6.4** — El `killall` de `procps-ng` documenta que cuando el nombre pedido supera los 15 caracteres, el nombre completo puede no estar disponible en `comm`, así que recurre a **comparar solo los primeros 15 caracteres** y mata todo lo que coincida con ese prefijo. `collect-metrics-daemon.sh` y `collect-metrics-shipper.sh` comparten el prefijo `collect-metrics`, así que coincidieron ambos. **`-e` (`--exact`)** desactiva ese recurso: las entradas cuyo nombre no pueda compararse por completo se omiten en lugar de matarse. `-r` cambia a coincidencia explícita por expresión regular contra el nombre.

**A6.5** — En Solaris (e históricamente en algunos otros derivados de System V), `killall` ejecutado por root envía `SIGTERM` a **todos los procesos del sistema** — es un ayudante de la secuencia de apagado, no un buscador de patrones. Ejecutar allí el idioma de Linux `killall httpd` tumba la máquina. La disciplina: en scripts portables usá `pkill` (que tiene semántica consistente entre Linux y los BSD) o `kill` a secas con PIDs sacados de un pidfile, y nunca `killall`.

**A6.6** — `pgrep`/`pkill` excluyen solo **su propio PID**, no a su padre ni a sus hermanos. Si ejecutás un script llamado `backup.sh` y este llama internamente a `pkill -f backup`, el patrón coincide con el propio proceso `bash` del script — `/bin/bash ./backup.sh` contiene `backup` — y el script se mata a sí mismo a mitad de ejecución, dejando a medias lo que estuviera haciendo. Defensas: anclá el patrón para excluirte (`pkill -f 'backup-worker\.py'`), agregá `-x` con un `comm` preciso, o filtrá explícitamente con `pgrep -f pattern | grep -v "^$$\$"`.

**A6.7** —

```bash
sudo pkill -HUP -x -u root -o nginx
```

`-HUP` selecciona la señal por nombre (portable — ver A4.8). `-x` exige una coincidencia exacta de `comm`, así que `nginx-debug` o un script con `nginx` en el nombre no quedan atrapados. `-u root` restringe a procesos propiedad de root, excluyendo los procesos worker de `www-data`. `-o` selecciona el proceso coincidente **más viejo**, que para un daemon con pre-fork es el maestro — los workers son sus hijos y se arrancaron después. En producción, preferí el pidfile — `kill -HUP "$(cat /run/nginx.pid)"` — o `systemctl reload nginx`, ambos inequívocos por construcción.

### Ejercicio 7

**A7.1** — No. La carga media es aproximadamente comparable con **`nproc`**: una carga igual al número de CPUs significa que la máquina está totalmente utilizada sin encolamiento; por debajo hay margen; una carga sostenida *por encima* significa que hay tareas esperando. 2.71 en 8 CPUs es alrededor del 34 % de utilización — sana. El número no tiene sentido sin el conteo de núcleos, y por eso las alertas deberían expresarse como `load / nproc`.

**A7.2** — Linux cuenta las tareas en estado **`R` (ejecutándose/ejecutable) *y* `D` (sueño ininterrumpible)**; el UNIX clásico cuenta solo las tareas ejecutables. Así que en Linux un host con CPUs ociosas pero con un montaje NFS atascado o un disco saturado puede mostrar una carga de 50 mientras `%Cpu(s)` marca 95 % ocioso. Por lo tanto, la carga media en Linux mide *la presión de demanda de CPU y E/S juntas*, no la utilización de CPU — leela siempre junto con `%wa` y el conteo de tareas en estado `D`.

**A7.3** — `4/1247` es **tareas actualmente ejecutables / total de tareas** (hilos) que existen actualmente. `6103` es el **PID asignado más recientemente** por el kernel. Un último campo que sube rápido es una señal útil de comportamiento de tormenta de forks.

**A7.4** — Las cargas medias son **medias móviles amortiguadas exponencialmente** sobre ventanas nominales de 1, 5 y 15 minutos, muestreadas por el kernel cada 5 segundos. Decaen hacia el nuevo valor en lugar de saltar a él: tras quitar la carga, la cifra de 1 minuto necesita aproximadamente un minuto para caer a ~37 % de su valor anterior, y la de 15 minutos se retrasa mucho más. Una "carga media" que cayera al instante no sería una media.

**A7.5** —
- `us` — tiempo de usuario, procesos con prioridad normal
- `sy` — tiempo de kernel/sistema
- `ni` — tiempo de usuario de procesos con un **valor de nice positivo** (despriorizados); se cuenta aparte de `us`
- `id` — ocioso
- `wa` — espera de E/S: tiempo de CPU ociosa durante el cual al menos una tarea estaba bloqueada en E/S
- `hi` — atención de interrupciones de hardware
- `si` — atención de interrupciones de software (softirq), p. ej. el procesamiento de recepción de red
- `st` — **steal**: tiempo en que la CPU virtual estaba lista para ejecutar pero el hipervisor le dio la CPU física a otro invitado

`st` es el que se vuelve distinto de cero en un **hipervisor sobresuscrito** — una cifra crítica en instancias en la nube, ya que es capacidad que estás pagando pero no recibiendo. `si` es el que hay que vigilar en un host con la red saturada.

**A7.6** — `free` es memoria **completamente sin usar**, que no contiene absolutamente nada. `available` es la estimación del kernel de la memoria **obtenible por una aplicación nueva sin hacer swap**, es decir, `free` más la porción recuperable de la caché de páginas y del slab. Linux usa deliberadamente la RAM ociosa como caché, así que en un servidor sano de larga duración `free` tiende a casi cero y eso es *el comportamiento correcto*, no una fuga. Una alerta de capacidad debe usar por tanto **`available`** (`MemAvailable` en `/proc/meminfo`); alertar sobre `free` produce un falso positivo permanente en toda máquina ocupada.

**A7.7** — No es un bug. En el **modo Irix** por defecto, `top` escala `%CPU` por *CPU lógica*, así que un proceso que usa 3.4 núcleos completos muestra 340 %. Presionar **`I`** alterna al **modo Solaris**, que divide por el número de CPUs y muestra el mismo proceso como 42.5 % de la máquina entera. El modo Irix hace evidente cuántos núcleos está consumiendo un pool de hilos; el modo Solaris hace que la columna sume 100 % en toda la máquina.

**A7.8** — `ps` reporta un **promedio de toda la vida**: tiempo total de CPU consumido dividido por el tiempo total transcurrido desde que el proceso arrancó. `top` reporta el uso durante el **intervalo de refresco más reciente**, calculado a partir del delta de ticks de CPU entre dos muestras. Consecuencias: para un proceso de larga vida que está ocupado ahora mismo, `top` marca mucho más alto que `ps`; para uno que quemó CPU al arrancar y ahora está ocioso, `ps` marca más alto. Además, `top -b -n 1` no tiene muestra previa contra la cual restar, así que su primera iteración cae de vuelta a cifras de toda la vida — por eso `top -b -n 2 -d 1 | tail` es la forma correcta para scripts.

**A7.9** — Con `k`, `top` (a) te permite **elegir la señal**, preguntándotela después del PID — no está fija en `SIGTERM`; y (b) te permite actuar sobre un proceso que acabás de identificar **sin salir de la vista ordenada y en vivo** ni volver a escribir un PID, así que ves el efecto de inmediato en el siguiente refresco. El riesgo es precisamente esa inmediatez: la fila bajo tu cursor se mueve entre refrescos a medida que cambia el orden, así que es fácil confirmar un PID que ya no es el que mirabas. Leé el PID, y después confirmalo en el prompt.

### Ejercicio 8

**A8.1** — El intervalo por defecto es de **2 segundos** (`-n` lo cambia; `procps-ng` acepta valores fraccionarios como `-n 0.5`). **`-d` (`--differences`)** resalta los caracteres que cambiaron desde la ejecución anterior; `-d=cumulative`/`--differences=permanent` mantiene resaltada toda posición que *alguna vez* haya cambiado, lo que sirve para detectar un campo que parpadea rara vez.

**A8.2** — `watch` pasa su comando a **`sh -c`** — pero solo después de ensamblarlo a partir del argv restante. Sin comillas, `ps -eo pid,stat,comm --sort=-%cpu` sobrevive porque `watch` vuelve a unir los argumentos y el shell que lanza los reanaliza inofensivamente. En cuanto agregás `| head`, **tu shell interactivo** interpreta la tubería primero: canaliza la salida del propio `watch` hacia `head` en lugar de pasarle la tubería a `watch`. Entrecomillar la expresión entera es el arreglo. **`-x` (`--exec`)** pasa el vector de argumentos directamente a `execvp` sin ningún shell — perdés tuberías, redirecciones, globbing y expansión de variables, y ganás control exacto sobre la división en palabras (esencial cuando los argumentos contienen espacios o comillas).

**A8.3** — **`-g` (`--chgexit`)** sale en cuanto la *salida* del comando cambia respecto de la iteración anterior — una primitiva barata de "esperá hasta que este valor se mueva". **`-e` (`--errexit`)** sale cuando el comando devuelve un **estado de salida distinto de cero**, congelando la pantalla para que puedas leer el error (agregá `-b`/`--beep` para que te avise sonoramente).

**A8.4** — Primero, `top` ya es un programa a pantalla completa que se autorrefresca, con su propia temporización, ordenación y estado; envolverlo significa que `watch` limpia la pantalla y reinicia `top` desde cero cada segundo, descartando todo eso. Segundo, `top` en modo no batch espera una terminal que controla; bajo `watch` o bien distorsiona la pantalla o bien se niega a correr. La forma correcta para scripts es `top -b -n N -d S`, que está diseñada para salida no interactiva.

**A8.5** — No. `top` es un **monitor por muestreo**: lee contadores a intervalos y calcula tasas a partir de los deltas, con lo cual puede reportar porcentajes de CPU por intervalo con significado. `watch` es un **repetidor**: reejecuta un comando arbitrario y te muestra su salida, sin calcular nada. Cada iteración de `watch` es un proceso independiente sin memoria de la anterior — que es exactamente la razón por la que `watch -n 1 'echo $$'` imprime un PID *distinto* cada vez (un `sh -c` nuevo por iteración; el `$$` lo expande ese subshell, no tu shell, porque está entre comillas simples).

### Ejercicio 9

**A9.1** — Se parece a **`setsid`**: `screen` daemoniza su proceso servidor a una nueva sesión sin terminal de control, reparentada a init. Lo que `screen` agrega es un **par de pseudoterminales (pty) que él asigna y posee**. La terminal de control de tu trabajo es ese pty (`pts/3`), cuyo extremo maestro lo retiene el servidor `screen` de larga vida y no tu sesión SSH — así que el trabajo mantiene una terminal interactiva plenamente funcional que sobrevive a tu conexión, cosa que `setsid` a secas no puede proporcionar.

**A9.2** — Porque el lado maestro de `pts/3` lo mantiene abierto el **proceso servidor `screen`**, que no forma parte de tu sesión de login y no sale cuando SSH se desconecta. Un pty se destruye solo cuando se cierra su maestro. Tu conexión SSH posee un pty *distinto* (el que usó tu shell de login); ese se desmantela y su grupo en primer plano recibe `SIGHUP`, pero `pts/3` y todo lo que hay sobre él quedan intactos.

**A9.3** —
- `screen -r <name>` — reacoplarse a una sesión actualmente marcada como **Detached**. Falla si está marcada como Attached.
- `screen -d -r <name>` — **forzar**: desacoplarla de donde sea que esté acoplada, y después acoplarla acá. Este es el que necesitás después de que una caída de red dejó la sesión marcada como Attached por error.
- `screen -x <name>` — **multi-acople**: unirte a una sesión que ya está acoplada en otro lado, con ambas terminales compartiendo la misma vista. El modo de programación en pareja / soporte por encima del hombro.

**A9.4** — Ventajas de `tmux`: una arquitectura cliente–servidor genuina con una interfaz de comandos scriptable (`tmux send-keys`, `tmux new-window`, `tmux list-panes`), de modo que se pueden construir disposiciones enteras desde un script; divisiones verticales **y** horizontales reales como concepto de primera clase; y un desarrollo upstream mucho más activo. `screen` sigue siendo la elección pragmática cuando es **el único instalado** — viene en el conjunto de paquetes base o mínimo de muchas distribuciones empresariales y appliances donde `tmux` no está disponible y no tenés acceso a paquetes. Tener memoria muscular para `Ctrl-a d` vale la pena exactamente para ese día.

**A9.5** — Usá `setsid` (o `nohup … &`) con redirección explícita de la salida:

```bash
setsid ./migrate.sh > ~/migrate.log 2>&1 < /dev/null &
```

y después seguilo con `tail -f ~/migrate.log`. Lo que resignás es la **interactividad**: no podés reacoplarte a una terminal, así que el trabajo nunca debe preguntar nada (redirigí la entrada estándar desde `/dev/null` para que una lectura perdida falle rápido en vez de bloquearse con `SIGTTIN`), no tenés scrollback más allá del log, y no podés enviarle pulsaciones de teclas — solo señales. Diseñá el trabajo para que sea no interactivo y hable mucho al log antes de confiar en esto.

### Ejercicio 10

**A10.1** — Esto es **saturación de E/S**, no presión de CPU. En Linux la carga media cuenta las tareas en estado `D` (sueño ininterrumpible), así que decenas de procesos bloqueados en un disco atascado, una reconstrucción de RAID degradada o un montaje NFS colgado producen una carga enorme mientras las CPUs están ociosas — exactamente la firma de `94.0 wa`. Matar al proceso con mayor `%CPU` quitaría un proceso que apenas está corriendo y no tocaría la cola de tareas bloqueadas; peor aún, las tareas en estado `D` no pueden matarse en absoluto hasta que su E/S termine. Investigá el almacenamiento: `iostat -x`, `dmesg -T | tail`, el estado de los montajes, y `ps -eo stat,wchan,comm | awk '$1 ~ /D/'` para ver *en qué* están bloqueadas.

**A10.2** — `TIME+` es la **CPU acumulada consumida**, lo que te dice que el proceso estuvo ocupado pero no *cuándo* empezó a ser un problema. `lstart` da la hora absoluta de arranque en tiempo de reloj y `etimes` la antigüedad en segundos, que es lo que correlaciona el proceso con el despliegue, la entrada de cron o el login de usuario que lo causó. Un informe de incidente necesita una línea de tiempo; `TIME+` no puede aportar una. Un proceso con `TIME+ 04:12:33` y `etimes 15100` estuvo ocupado 4 de las últimas 4.2 horas — esa combinación es el hallazgo real.

**A10.3** — `kill -9` **no surtirá efecto mientras la tarea siga en `D`**. `SIGKILL` queda pendiente y el kernel actuará sobre ella en el momento en que retorne el camino ininterrumpible del kernel — lo que puede ser en segundos, o nunca si el dispositivo subyacente o el servidor NFS no responden. El proceso va a seguir apareciendo en `ps` después del `kill`, y `ps -o stat` va a seguir mostrando `D`. `SigCgt: 0` solo confirma que el proceso no captura nada; es irrelevante acá, porque `SIGKILL` nunca se captura de todas formas. El arreglo está en la capa de almacenamiento, no en la de procesos.

**A10.4** — Previene que **los hijos huérfanos sigan haciendo daño**. Si el infractor forkeó workers, matar solo al padre deja a los workers corriendo — se reparentan a init/a un subreaper y siguen consumiendo la CPU o escribiendo en los mismos archivos, mientras tu monitorización muestra al infractor como "desaparecido". Señalizar al grupo de procesos entero alcanza al padre y a todos los descendientes que se quedaron en el grupo en una sola operación atómica. Verificá primero la pertenencia al grupo (`ps -eo pid,pgid,comm | awk '$2==g'`) para no señalizar a tu propio shell — y tené en cuenta que un hijo que llamó a `setsid` o `setpgid` salió del grupo y necesita tratamiento aparte.

**A10.5** — `systemctl stop` usa el **cgroup** de la unidad como el conjunto de procesos autoritativo, así que alcanza a todos los descendientes sin importar el grupo de procesos, la sesión o el doble fork — algo que `kill` sobre un PID no puede hacer. También honra el `KillSignal`, el `TimeoutStopSec` y el `ExecStop=` configurados de la unidad, escalando a `SIGKILL` según el propio calendario de la unidad, y **actualiza el estado de systemd**: `Restart=` no te va a pelear reviviendo el proceso al instante, y `systemctl status` va a mostrar `inactive (dead)` en lugar de un servicio que systemd cree corriendo pero no lo está. Matar con `kill` un servicio gestionado deja al supervisor y a la realidad desincronizados.

**A10.6** —

1. **`SIGTERM`** — el pedido documentado de "apagate limpiamente". Esperá **10–30 s**, dimensionado según el propio timeout de apagado del servicio (para una base de datos, más: puede estar volcando a disco).
2. **`SIGHUP`** si el daemon está simplemente trabado con configuración obsoleta y documenta la recarga por HUP — chequeá `SigCgt` primero. (Escalón opcional; saltalo si no aplica.)
3. **`SIGTERM` al grupo de procesos** (`kill -TERM -$PGID`) — atrapa a los hijos que ignoraron el apagado del padre. Esperá **10 s**.
4. **`SIGKILL`** al PID, y después al grupo — incondicional, sin limpieza, locks y archivos temporales quedan atrás. Esperá **5 s** y verificá.
5. Si sigue presente, está en estado **`D`** y ninguna señal va a ayudar: el problema está por debajo de la capa de procesos (almacenamiento, sistema de archivos de red, driver). Investigá ahí; un reinicio puede ser la única palanca que quede.

Para un servicio gestionado por systemd, reemplazá los escalones 1–4 por `systemctl stop` — realiza exactamente esta escalada, sobre el conjunto de procesos correcto, con un timeout configurado.

</details>

---

## Fuentes

- LPI — Exam 101-500 Objectives (v5.0), Topic 103.5: <https://www.lpi.org/our-certifications/exam-101-objectives/>
- GNU Bash Reference Manual — Job Control: <https://www.gnu.org/software/bash/manual/html_node/Job-Control.html>
- GNU Bash Reference Manual — Signals: <https://www.gnu.org/software/bash/manual/html_node/Signals.html>
- `signal(7)` — página del manual de Linux (números de señal, disposiciones, diferencias entre arquitecturas): <https://man7.org/linux/man-pages/man7/signal.7.html>
- `ps(1)` — página del manual de Linux (estilos de sintaxis, especificadores de salida, códigos de estado de proceso): <https://man7.org/linux/man-pages/man1/ps.1.html>
- `kill(1)`: <https://man7.org/linux/man-pages/man1/kill.1.html> · `kill(2)`: <https://man7.org/linux/man-pages/man2/kill.2.html>
- `pgrep(1)` / `pkill(1)`: <https://man7.org/linux/man-pages/man1/pgrep.1.html>
- `killall(1)`: <https://man7.org/linux/man-pages/man1/killall.1.html>
- `nohup(1)`: <https://man7.org/linux/man-pages/man1/nohup.1.html> · `setsid(1)`: <https://man7.org/linux/man-pages/man1/setsid.1.html> · `setsid(2)`: <https://man7.org/linux/man-pages/man2/setsid.2.html>
- `top(1)`: <https://man7.org/linux/man-pages/man1/top.1.html> · `free(1)`: <https://man7.org/linux/man-pages/man1/free.1.html> · `uptime(1)`: <https://man7.org/linux/man-pages/man1/uptime.1.html> · `watch(1)`: <https://man7.org/linux/man-pages/man1/watch.1.html>
- `proc(5)` — `/proc/PID/status`, `/proc/PID/comm`, `/proc/loadavg`, `/proc/meminfo`: <https://man7.org/linux/man-pages/man5/proc.5.html>
- `credentials(7)` — grupos de procesos y sesiones: <https://man7.org/linux/man-pages/man7/credentials.7.html>
- `prctl(2)` — `PR_SET_NAME`, `PR_SET_CHILD_SUBREAPER`: <https://man7.org/linux/man-pages/man2/prctl.2.html>
- Documentación del kernel de Linux — el sistema de archivos `/proc`: <https://docs.kernel.org/filesystems/proc.html>
- procps-ng (upstream de `ps`, `top`, `free`, `uptime`, `watch`, `pgrep`, `kill`, `killall`): <https://gitlab.com/procps-ng/procps>
- Manual de GNU Screen: <https://www.gnu.org/software/screen/manual/screen.html>
- tmux — wiki y manual oficiales: <https://github.com/tmux/tmux/wiki>
- `systemd.kill(5)` — `KillMode`, `KillSignal`, `TimeoutStopSec`: <https://www.freedesktop.org/software/systemd/man/systemd.kill.html>