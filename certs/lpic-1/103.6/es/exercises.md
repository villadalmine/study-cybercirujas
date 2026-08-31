# 103.6 — Modificar las prioridades de ejecución de procesos

**Certificación:** LPIC-1 (LPI 101-500 / 102-500, versión 5.0)
**Objetivo 103.6**, peso del examen **3.12**
**Conocimientos clave:** prioridad por defecto de un trabajo recién creado; ejecutar un programa con una prioridad mayor/menor que la predeterminada; cambiar la prioridad de un proceso en ejecución.
**Términos y utilidades:** `nice`, `ps`, `renice`, `top`

---

## Requisitos del laboratorio y seguridad

* Una VM o contenedor Linux descartable con un **kernel moderno (≥ 5.4)**, `sudo`, `util-linux`, `procps-ng` y `coreutils`. No ejecutes esto en un host de producción: varios pasos saturan deliberadamente una CPU.
* Al menos **2 CPU lógicas** (`nproc`). Una se dedicará a la carga, el resto mantiene tu shell con capacidad de respuesta.
* Dos terminales en la misma máquina (una segunda sesión SSH o un segundo panel de `tmux`) para los pasos de observación.
* Todo lo que hay aquí es reversible; la sección **Limpieza** al final mata todos los procesos que inicies.

### Convenciones usadas en este documento

| Símbolo | Significado |
|---|---|
| `$` | Comando ejecutado como tu usuario normal, sin privilegios |
| `#` / `sudo` | Comando que requiere root |
| `NI` | El **valor nice**: `-20` (más favorable) … `0` (por defecto) … `19` (menos favorable) |
| `PR` / `PRI` | Un número de prioridad *derivado*. Su escala y su dirección difieren según la herramienta — de eso trata el Ejercicio 2 |
| `$CPU` | La CPU a la que fijás la carga del laboratorio (se define en el Ejercicio 0) |

> Las salidas mostradas abajo fueron capturadas en Debian 12 (kernel 6.1, procps-ng 4.0.2, util-linux 2.38). **Los PID, los tiempos y la base absoluta de `PRI` van a diferir en tu sistema.** Donde un número depende de la escala, el ejercicio te indica que registres tu propio valor.

---

## Ejercicio 0 — Construir el banco de pruebas del laboratorio

Necesitás dos cosas repetidamente: un proceso que consuma exactamente una CPU con un valor nice conocido, y una forma de medir cuánta CPU obtuvo realmente.

1. Elegí la última CPU lógica de la máquina y confirmá que existe:

```
$ CPU=$(( $(nproc) - 1 )); echo "using CPU $CPU"
using CPU 3
$ uname -r
6.1.0-18-amd64
```

2. Creá el generador de carga. Escribirlo en un archivo (en lugar de una sola línea de shell) mantiene estable el PID a través de `nice` y `taskset`, que ambos hacen `exec` al comando final:

```
$ cat > /tmp/burn.sh <<'EOF'
#!/bin/bash
# usage: burn.sh <cpu> <nice> <pidfile>
# Records its own PID, then execs into a pinned, niced busy loop.
echo $$ > "$3"
exec nice -n "$2" taskset -c "$1" bash -c 'while :; do :; done'
EOF
$ chmod +x /tmp/burn.sh
```

3. Creá el asistente de contabilidad de CPU. Los campos 14 (`utime`) y 15 (`stime`) de `/proc/<pid>/stat` son el tiempo total de CPU en ticks de reloj. El `sed` elimina el prefijo `pid (comm)`, porque un nombre de proceso puede contener espacios y paréntesis y de lo contrario desplazaría todos los campos:

```
$ cpu_ticks() { sed 's/^.*) //' "/proc/$1/stat" | awk '{print $12 + $13}'; }
$ getconf CLK_TCK
100
```

4. Verificá el banco de pruebas de punta a punta y luego detenelo:

```
$ /tmp/burn.sh "$CPU" 0 /tmp/p1.pid &
[1] 4310
$ P1=$(cat /tmp/p1.pid); echo "$P1"
4310
$ sleep 2; cpu_ticks "$P1"
198
$ kill "$P1"
```

**Comprobá tu comprensión — Ejercicio 0**

* **Q0.1** — `/tmp/burn.sh` escribe `$$` en un archivo y después llama a `exec`. ¿Por qué el PID registrado sigue siendo válido después de que se ejecutaron `nice` y `taskset`?
* **Q0.2** — ¿Por qué la expresión `sed` usa un `.*)` *codicioso* en lugar de hacer coincidir el primer `)`?
* **Q0.3** — `cpu_ticks` devolvió `198` después de `sleep 2` con un tick de 100 Hz. ¿Qué te dice eso sobre cuánto consumió el proceso de una CPU, y por qué no es exactamente `200`?

---

## Ejercicio 1 — La prioridad por defecto y cómo se hereda

1. Preguntale a `nice` cuál es el valor nice actual de tu shell. Invocado sin argumentos no lanza nada; imprime la niceness que heredó:

```
$ nice
0
```

2. Confirmalo desde la propia visión del kernel. El campo 18 es `priority`, el campo 19 es `nice` (post-`sed`: `$16` y `$17`):

```
$ sed 's/^.*) //' /proc/$$/stat | awk '{print "kernel_prio="$16, "nice="$17}'
kernel_prio=20 nice=0
```

3. Mostrá que el valor nice se **hereda por los hijos en el momento del fork**:

```
$ nice -n 7 bash -c 'nice; sleep 1 & nice'
7
7
```

4. Mostrá que **sobrevive a `execve`** — el valor es una propiedad de la tarea, no de la imagen del programa:

```
$ nice -n 7 bash -c 'exec nice'
7
```

5. Mostrá que cambiar un padre después **no** cambia retroactivamente a los hijos existentes. Iniciá un hijo y luego reniceá solo al padre:

```
$ bash -c 'sleep 300 & echo "child=$!"; echo "parent=$$"'
child=4402
parent=4401
$ renice -n 5 -p 4402 >/dev/null; ps -o pid,ppid,ni,comm -p 4402
    PID    PPID  NI COMMAND
   4402       1   5 sleep
$ kill 4402
```

**Comprobá tu comprensión — Ejercicio 1**

* **Q1.1** — ¿Cuál es el valor nice por defecto de un proceso creado por un shell de login normal, y cuál es el rango legal completo?
* **Q1.2** — Un demonio es iniciado por systemd con `Nice=5`. Hace fork de un worker, que hace `exec` de `/usr/bin/python3`. ¿Cuál es el valor nice del worker, y por qué?
* **Q1.3** — Hacés `renice` de un shell en ejecución a `10`. ¿Qué procesos suyos se ven afectados: los que ya están corriendo, los iniciados después, ambos, o ninguno?

---

## Ejercicio 2 — Leer los números: `NI`, `PR`, `PRI` y `/proc`

Tres herramientas muestran "prioridad" y **ninguna de ellas usa la misma escala**. Solo `NI` es portable.

1. En la terminal A, iniciá una carga con nice y mantenela corriendo:

```
$ /tmp/burn.sh "$CPU" 0 /tmp/p1.pid & P1=$(cat /tmp/p1.pid)
[1] 4507
```

2. Leelo con `top` en modo batch (`-b` no interactivo, `-n 1` una iteración, `-p` restringe a un PID). Registrá las columnas `PR` y `NI`:

```
$ top -b -n 1 -p "$P1" | tail -n 3

    PID USER      PR  NI    VIRT    RES    SHR S  %CPU  %MEM     TIME+ COMMAND
   4507 student   20   0    8192   3456   3200 R  99.7   0.0   0:12.44 burn.sh
```

3. Leé el mismo proceso con `ps`, dos veces, en dos formatos diferentes. **Registrá ambos valores de `PRI` — la base de tu compilación puede diferir de la del ejemplo:**

```
$ ps -o pid,ni,pri,psr,pcpu,comm -p "$P1"
    PID  NI PRI PSR %CPU COMMAND
   4507   0  19   3 99.7 burn.sh
$ ps -l -p "$P1"
F S   UID   PID  PPID  C PRI  NI ADDR SZ WCHAN  TTY          TIME CMD
0 R  1000  4507  4310 99  80   0 -  2048 -      pts/0    00:00:20 burn.sh
```

4. Ahora cambiá el valor nice y volvé a leer **las tres** vistas, observando la *dirección* en que se mueve cada número:

```
$ renice -n 5 -p "$P1"
4507 (process ID) old priority 0, new priority 5
$ top -b -n 1 -p "$P1" | tail -n 2
   4507 student   25   5    8192   3456   3200 R  99.3   0.0   0:31.02 burn.sh
$ ps -o pid,ni,pri -p "$P1"; ps -l -p "$P1" | tail -n 1
    PID  NI PRI
   4507   5  14
0 R  1000  4507  4310 99  85   5 -  2048 -      pts/0    00:00:31 burn.sh
$ sed 's/^.*) //' /proc/$P1/stat | awk '{print "kernel_prio="$16, "nice="$17}'
kernel_prio=25 nice=5
```

5. Dejá el proceso corriendo para el próximo ejercicio, o matalo con `kill "$P1"`.

**Comprobá tu comprensión — Ejercicio 2**

* **Q2.1** — A partir de tus propias mediciones, escribí la fórmula que relaciona la columna `PR` de `top` con `NI` para una tarea normal (`SCHED_OTHER`). ¿Qué imprime `top` en `PR` para una tarea de tiempo real en su lugar?
* **Q2.2** — En tu captura, `ps -o pri` se movió *hacia abajo* cuando `NI` subió, mientras que el `PRI` de `ps -l` se movió *hacia arriba*. ¿Cuál de los dos sigue la convención "número más alto = mejor prioridad"? ¿Qué única columna es segura para usar en un script?
* **Q2.3** — `%CPU` se mantuvo en ~99% después de que el proceso fue reniceado de 0 a 5. ¿Significa eso que `renice` no tuvo efecto? Explicá.

---

## Ejercicio 3 — `nice(1)`: sintaxis, la trampa de la forma obsoleta y el recorte

1. Empezá por el valor por defecto documentado. Sin ajuste, `nice` suma **10**:

```
$ nice nice
10
```

2. Usá la forma moderna y no ambigua. `-n` toma el **incremento**, relativo al valor nice actual del invocador:

```
$ nice -n 5 nice
5
```

3. Disparás la trampa clásica del examen. La forma obsoleta `nice -10` **no** significa "valor nice −10"; la sintaxis histórica trata los dígitos como el incremento:

```
$ nice -10 nice
10
```

4. Demostrá que los incrementos **se componen** — cada `nice` es relativo a lo que heredó, no absoluto:

```
$ nice -n 5 nice -n 5 nice
10
$ nice -n 5 nice -n 5 nice -n 19 nice
19
```

5. Observá el **recorte (clamping)**. Los valores fuera de rango se saturan silenciosamente, no se rechazan:

```
$ nice -n 100 nice
19
$ sudo nice -n -100 nice
-20
```

6. Intentá elevar la prioridad como usuario sin privilegios, y leé el comportamiento con atención:

```
$ nice -n -5 nice
nice: cannot set niceness: Permission denied
0
$ nice -n -5 sh -c 'echo command ran anyway'; echo "exit=$?"
nice: cannot set niceness: Permission denied
command ran anyway
exit=0
```

7. Compará con root, donde la solicitud tiene éxito:

```
$ sudo nice -n -5 nice
-5
```

**Comprobá tu comprensión — Ejercicio 3**

* **Q3.1** — Un trabajo por lotes se lanza desde una entrada de cron como `nice -5 /usr/local/bin/reindex`. El autor pretendía "ejecutar con más CPU de lo normal". ¿Qué valor nice obtiene realmente el trabajo, y cómo debería escribirse la línea para expresar la intención original?
* **Q3.2** — En el paso 6 el comando igualmente se ejecutó y el estado de salida fue `0`. ¿Por qué es peligroso eso en un script que asume que `nice` impone una prioridad, y cómo detectarías la falla?
* **Q3.3** — Tu shell ya está en nice 5. ¿Qué imprime `nice -n 3 nice`, y qué habría producido `renice -n 3 -p $$` en su lugar?

---

## Ejercicio 4 — Medir lo que nice realmente te da

El kernel no planifica "10% más lento". Le asigna a cada nivel nice un **peso**, y la CPU se reparte en proporción al peso. Nice 0 tiene peso 1024, y cada paso de un nivel nice multiplica el peso por aproximadamente **1.25**.

| NI | −20 | −10 | −5 | 0 | 1 | 5 | 10 | 15 | 19 |
|---|---|---|---|---|---|---|---|---|---|
| peso | 88761 | 9548 | 3121 | **1024** | 820 | 335 | 110 | 36 | 15 |

1. Hacé el experimento determinista: ambos procesos deben competir por **una CPU**, desde la **misma sesión de shell** (el Ejercicio 7 explica por qué importa la sesión). Iniciálos en nice 0 y nice 5:

```
$ /tmp/burn.sh "$CPU" 0 /tmp/p1.pid & /tmp/burn.sh "$CPU" 5 /tmp/p2.pid &
[1] 4611
[2] 4612
$ P1=$(cat /tmp/p1.pid); P2=$(cat /tmp/p2.pid)
$ ps -o pid,ni,psr,comm -p "$P1","$P2"
    PID  NI PSR COMMAND
   4611   0   3 burn.sh
   4612   5   3 burn.sh
```

2. Tomá un delta de 20 segundos de ticks de CPU consumidos y convertilo en una participación:

```
$ a1=$(cpu_ticks $P1); a2=$(cpu_ticks $P2); sleep 20
$ b1=$(cpu_ticks $P1); b2=$(cpu_ticks $P2)
$ d1=$((b1-a1)); d2=$((b2-a2))
$ echo "nice0=$d1 ticks  nice5=$d2 ticks"; awk -v a=$d1 -v b=$d2 \
    'BEGIN{printf "share: %.1f%% / %.1f%%\n", 100*a/(a+b), 100*b/(a+b)}'
nice0=1497 ticks  nice5=494 ticks
share: 75.2% / 24.8%
```

3. Compará contra la tabla de pesos: `1024 / (1024 + 335) = 75.4 %`. Tu resultado debería quedar dentro de un par de puntos porcentuales.

4. Ampliá la brecha a nice 10 y predecí **antes** de medir:

```
$ renice -n 10 -p "$P2"
4612 (process ID) old priority 5, new priority 10
$ a1=$(cpu_ticks $P1); a2=$(cpu_ticks $P2); sleep 20
$ b1=$(cpu_ticks $P1); b2=$(cpu_ticks $P2)
$ awk -v a=$((b1-a1)) -v b=$((b2-a2)) \
    'BEGIN{printf "share: %.1f%% / %.1f%%\n", 100*a/(a+b), 100*b/(a+b)}'
share: 90.1% / 9.9%
```

5. Ahora eliminá la competencia y mirá cómo el proceso con nice 19 se queda con toda la CPU:

```
$ renice -n 19 -p "$P2" >/dev/null
$ kill "$P1"
$ sleep 5; top -b -n 1 -p "$P2" | tail -n 2
   4612 student   39  19    8192   3456   3200 R  99.7   0.0   1:22.10 burn.sh
$ kill "$P2"
```

**Comprobá tu comprensión — Ejercicio 4**

* **Q4.1** — Usando la tabla de pesos, predecí el reparto de CPU entre un proceso con nice 0 y uno con nice −5 compitiendo por una CPU. Mostrá la aritmética.
* **Q4.2** — El paso 5 muestra un proceso con nice 19 al 99.7% de CPU. Reformulá con precisión qué garantiza un valor nice y qué no.
* **Q4.3** — Tu host tiene 8 CPU y un proceso con nice 0 compitiendo con uno con nice 19. ¿Por qué este experimento mostraría ~100% / ~100% en lugar de 98.6% / 1.4%, y qué hizo el laboratorio para evitarlo?
* **Q4.4** — Un colega afirma que "cada nivel nice es el 10% de la CPU". ¿En qué sentido es cierto, y en qué sentido está equivocado?

---

## Ejercicio 5 — `renice`: la calle de sentido único y `RLIMIT_NICE`

1. Iniciá un proceso de tu propiedad con la prioridad por defecto:

```
$ /tmp/burn.sh "$CPU" 0 /tmp/p1.pid & P1=$(cat /tmp/p1.pid)
[1] 4703
```

2. Bajá su prioridad (aumentá el valor nice). Los usuarios sin privilegios siempre pueden hacer esto con sus propios procesos:

```
$ renice -n 12 -p "$P1"
4703 (process ID) old priority 0, new priority 12
```

3. Intentá deshacerlo — **sigue siendo el mismo usuario, sobre tu propio proceso, volviendo a un valor del que partiste**:

```
$ renice -n 0 -p "$P1"
renice: failed to set priority for 4703 (process ID): Permission denied
```

4. Inspeccioná el límite de recursos que gobierna esto. `RLIMIT_NICE` expresa un *techo* como `20 − limit`; el valor por defecto `0` significa "nunca puede bajar de nice 20", es decir, nunca negativo:

```
$ ulimit -e
0
$ prlimit --nice --pid $$
RESOURCE DESCRIPTION                             SOFT HARD UNITS
NICE     max nice prio allowed to raise             0    0
```

5. Elevá el límite duro de tu shell en ejecución desde afuera (elevar un límite duro requiere `CAP_SYS_RESOURCE`), y luego reintentá como tu usuario sin privilegios:

```
$ sudo prlimit --pid $$ --nice=30:30
$ ulimit -e
30
$ nice -n -10 nice
-10
$ nice -n -11 nice
nice: cannot set niceness: Permission denied
0
```

6. Confirmá que root no tiene restricciones, y limpiá:

```
$ sudo renice -n -5 -p "$P1"
4703 (process ID) old priority 12, new priority -5
$ kill "$P1"
```

7. Hacé el permiso persistente de la forma correcta, en lugar de repartir `sudo`. Este archivo le concede a un grupo el derecho a bajar hasta nice −10:

```
# /etc/security/limits.d/90-lab-nice.conf
# <domain>  <type>  <item>     <value>
@rt-operators   -    nice       -10
@rt-operators   -    priority   -10
```

`nice` establece el piso al que un miembro puede bajar; `priority` establece el valor nice con el que arranca su shell de login. El archivo lo lee `pam_limits.so`, así que se aplica en el **próximo login**, no a las sesiones existentes.

**Comprobá tu comprensión — Ejercicio 5**

* **Q5.1** — Enunciá la regla de permisos de `renice` en una sola oración que cubra ambas direcciones y ambos niveles de privilegio.
* **Q5.2** — `ulimit -e` imprime `30`. ¿Cuál es el valor nice más bajo que este usuario puede solicitar, y cuál es la fórmula?
* **Q5.3** — En el paso 3 el usuario no pudo restaurar nice 0 en un proceso propio que él mismo inició. ¿Qué clase de ataque previene esa regla?
* **Q5.4** — Después de editar `/etc/security/limits.d/90-lab-nice.conf`, un miembro de `rt-operators` sigue recibiendo `Permission denied` en su sesión SSH actual. ¿Cuál es la razón más probable?

---

## Ejercicio 6 — Operaciones masivas: por grupo de procesos y por usuario, y su radio de impacto

`renice` acepta tres tipos de identificador: `-p` PID (por defecto), `-g` ID de **grupo** de procesos, `-u` nombre de usuario o UID.

1. Iniciá un pequeño grupo de procesos. En un shell interactivo, cada trabajo es su propio grupo de procesos, y el ID del grupo es igual al PID del líder:

```
$ (sleep 300 & sleep 300 & sleep 300 & wait) &
[1] 4801
$ ps -o pid,pgid,ni,comm --ppid 4801
    PID    PGID  NI COMMAND
   4802    4801   0 sleep
   4803    4801   0 sleep
   4804    4801   0 sleep
```

2. Reniceá todo el grupo con una sola llamada:

```
$ renice -n 8 -g 4801
4801 (process group ID) old priority 0, new priority 8
$ ps -o pid,pgid,ni,comm --ppid 4801
    PID    PGID  NI COMMAND
   4802    4801   8 sleep
   4803    4801   8 sleep
   4804    4801   8 sleep
```

3. Ahora el radio de impacto. `-u` alcanza a **todos los procesos que pertenecen a ese usuario**, incluyendo su shell de login, su editor y su sesión SSH — y, si el usuario es una cuenta de servicio, el servicio mismo:

```
$ ps -u "$USER" -o pid,ni,comm --no-headers | wc -l
27
$ renice -n 3 -u "$USER"
1000 (user ID) old priority 0, new priority 3
$ ps -u "$USER" -o ni --no-headers | sort | uniq -c
     27 3
```

4. Notá el problema de dirección que esto crea. Cada uno de esos 27 procesos está ahora en nice 3 y, como usuario sin privilegios, **no podés devolverlos**:

```
$ renice -n 0 -u "$USER"
renice: failed to set priority for 1000 (user ID): Permission denied
$ sudo renice -n 0 -u "$USER"
1000 (user ID) old priority 3, new priority 0
```

5. Matá el grupo y confirmá que no queda nada:

```
$ kill -- -4801 2>/dev/null; ps -o pid,ni,comm --ppid 4801
    PID  NI COMMAND
```

6. La alternativa quirúrgica — seleccionar procesos por nombre y renicear solo esos:

```
$ pgrep -d, -f 'sleep 300'
4901,4902
$ renice -n 10 -p $(pgrep -d' ' -f 'sleep 300')
```

**Comprobá tu comprensión — Ejercicio 6**

* **Q6.1** — Se ejecuta `renice -n 19 -u postgres` en un servidor de base de datos para "liberar CPU para la capa web". Describí dos formas concretas en que esto puede empeorar la latencia general en lugar de mejorarla.
* **Q6.2** — ¿Qué tipo de identificador asume `renice` cuando le das un número suelto sin `-p`, `-g` ni `-u`?
* **Q6.3** — ¿Por qué `renice -n 5 -g <PGID>` suele ser más seguro que `-u <user>` para domar un trabajo por lotes desbocado lanzado desde un shell?

---

## Ejercicio 7 — Por qué `nice` a veces parece no hacer nada: autogroups y cgroups

Esta es la sorpresa de producción más común con `nice`, y es invisible desde las columnas de `ps`/`top`.

1. Verificá si el **autogrouping** está habilitado y mirá el autogroup de tu shell:

```
$ cat /proc/sys/kernel/sched_autogroup_enabled
1
$ cat /proc/$$/autogroup
/autogroup-231 nice 0
```

2. Reproducí la sorpresa. Iniciá los dos quemadores en **sesiones diferentes** (`setsid` crea una nueva sesión, y por lo tanto un nuevo autogroup), con una diferencia extrema de nice:

```
$ setsid /tmp/burn.sh "$CPU" 0  /tmp/p1.pid
$ setsid /tmp/burn.sh "$CPU" 19 /tmp/p2.pid
$ P1=$(cat /tmp/p1.pid); P2=$(cat /tmp/p2.pid)
$ ps -o pid,ni,sid,psr,comm -p "$P1","$P2"
    PID  NI   SID PSR COMMAND
   5011   0  5011   3 burn.sh
   5012  19  5012   3 burn.sh
```

3. Medí el reparto. Nice 0 contra nice 19 debería ser ~98.6% / ~1.4% según la tabla de pesos:

```
$ a1=$(cpu_ticks $P1); a2=$(cpu_ticks $P2); sleep 20
$ b1=$(cpu_ticks $P1); b2=$(cpu_ticks $P2)
$ awk -v a=$((b1-a1)) -v b=$((b2-a2)) \
    'BEGIN{printf "share: %.1f%% / %.1f%%\n", 100*a/(a+b), 100*b/(a+b)}'
share: 50.2% / 49.8%
```

4. Arreglalo en el nivel que realmente aplica — el propio valor nice del autogroup, escrito a través de `/proc/<pid>/autogroup`:

```
$ cat /proc/$P2/autogroup
/autogroup-244 nice 0
$ echo 19 | sudo tee /proc/$P2/autogroup
19
$ cat /proc/$P2/autogroup
/autogroup-244 nice 19
$ a1=$(cpu_ticks $P1); a2=$(cpu_ticks $P2); sleep 20
$ b1=$(cpu_ticks $P1); b2=$(cpu_ticks $P2)
$ awk -v a=$((b1-a1)) -v b=$((b2-a2)) \
    'BEGIN{printf "share: %.1f%% / %.1f%%\n", 100*a/(a+b), 100*b/(a+b)}'
share: 98.4% / 1.6%
$ kill "$P1" "$P2"
```

5. Inspeccioná la otra capa de agrupamiento que está por encima de `nice` — **cgroup v2**. Cada unidad de systemd y cada sesión de login es su propio cgroup, y la CPU se divide entre cgroups según `cpu.weight` *antes* de que se consulte nice dentro de ellos:

```
$ cat /proc/$$/cgroup
0::/user.slice/user-1000.slice/session-42.scope
$ CG=/sys/fs/cgroup$(cut -d: -f3 /proc/$$/cgroup)
$ cat "$CG/cgroup.controllers"
cpuset cpu io memory pids
$ cat "$CG/cpu.weight" 2>/dev/null || echo "cpu controller not enabled here"
100
```

6. Compará las dos perillas en una unidad real. `Nice=` actúa *dentro* del cgroup de la unidad; `CPUWeight=` decide cuánto obtiene la unidad *frente a otras unidades*:

```
$ systemctl show -p Nice -p CPUWeight -p IOWeight sshd.service
Nice=0
CPUWeight=[not set]
IOWeight=[not set]
```

7. Expresá la versión correcta para producción de "este trabajo por lotes debe ceder ante todo lo demás" como un drop-in:

```ini
# /etc/systemd/system/batch-indexer.service.d/10-priority.conf
[Service]
# Within its own cgroup: deprioritise the threads.
Nice=10
# Versus every other unit on the box: take ~1/5 of a fair share.
CPUWeight=20
IOWeight=20
CPUAccounting=yes
IOAccounting=yes
```

```
$ sudo systemctl daemon-reload
$ sudo systemctl restart batch-indexer.service
$ systemctl show -p Nice -p CPUWeight batch-indexer.service
Nice=10
CPUWeight=20
```

8. Para un comando ad-hoc, obtené la misma contención sin editar unidades:

```
$ sudo systemd-run --scope -p Nice=10 -p CPUWeight=20 /usr/local/bin/reindex
Running scope as unit: run-r3f2c1.scope
```

**Comprobá tu comprensión — Ejercicio 7**

* **Q7.1** — Dos trabajos limitados por CPU, uno en nice 0 y otro en nice 19, obtienen 50/50 de una CPU. Nombrá dos mecanismos de agrupamiento distintos que puedan causar esto, y un comando que revele cada uno.
* **Q7.2** — ¿Cuál es el alcance de planificación de un autogroup, y qué llamada al sistema crea uno nuevo?
* **Q7.3** — Una unidad tiene `Nice=19` y `CPUWeight=10000`. Bajo contención con otras unidades, ¿es una carga de trabajo de baja o de alta prioridad? Explicá las dos capas.
* **Q7.4** — ¿Por qué el `cpu.weight` por defecto de `100` corresponde a nice `0`, y cuál es la conversión aproximada para un paso de nice?

---

## Ejercicio 8 — Manual de diagnóstico: elegir la perilla correcta

`nice` solo redistribuye **tiempo de ejecución de CPU**. La mitad de los problemas de "prioridad" en producción no son problemas de CPU en absoluto.

1. Encontrá los consumidores de CPU, ordenados, con sus valores nice, en un solo disparo no interactivo apto para un script o una alerta:

```
$ ps -eo pid,user,ni,pri,pcpu,pmem,stat,etimes,comm --sort=-pcpu | head -n 6
    PID USER      NI PRI %CPU %MEM STAT ETIMES COMMAND
   5210 batch      0  19 99.4  0.3 R      1841 reindex
   5233 www-data   0  19 41.2  2.1 R       620 nginx
      1 root       0  19  0.1  0.4 Ss    98211 systemd
```

2. Contrastá con `top`, que reporta CPU *instantánea* mientras que `ps -o pcpu` reporta el **promedio sobre toda la vida del proceso** — un proceso de hace horas que estuvo ocupado al inicio te va a mentir en `ps`:

```
$ top -b -n 2 -d 2 -o %CPU -p 5210 | tail -n 2
   5210 batch     20   0  412M  9.8M  3.1M R  99.0   0.3   30:41.09 reindex
```

3. Cambialo interactivamente desde dentro de `top`: presioná **`r`**, escribí el PID, presioná Enter, escribí el nuevo valor nice, presioná Enter. Después presioná **`q`**. (Solicitar un valor negativo acá falla para un usuario sin privilegios exactamente igual que con `renice`.)

4. Establecé si la CPU es siquiera la restricción. Un proceso en estado `D` está bloqueado en E/S, y ningún valor nice lo va a ayudar:

```
$ ps -eo pid,stat,wchan:24,comm --sort=stat | awk '$2 ~ /^D/'
   5301 D    folio_wait_bit_common    rsync
```

5. Para ese caso, recurrí a la perilla de E/S en su lugar — y conocé su limitación:

```
$ ionice -p 5301
none: prio 4
$ sudo ionice -c 2 -n 7 -p 5301
$ ionice -p 5301
best-effort: prio 7
$ cat /sys/block/sda/queue/scheduler
[none] mq-deadline
```

La última línea es la advertencia: las clases de E/S son respetadas por **BFQ** (e históricamente por CFQ). Con `none` o `mq-deadline` seleccionado, `ionice` fija el valor y la capa de bloques lo ignora. Notá también que cuando no se establece una clase explícitamente, la prioridad de E/S best-effort se *deriva* del valor nice de CPU como `(nice + 20) / 5` — que es la razón por la que `nice 0` muestra `prio 4`.

6. Confirmá con qué política de planificación estás tratando realmente antes de culpar a nice. Los valores nice no tienen sentido para las políticas de tiempo real:

```
$ chrt -p 5210
pid 5210's current scheduling policy: SCHED_OTHER
pid 5210's current scheduling priority: 0
$ chrt -p 1
pid 1's current scheduling policy: SCHED_OTHER
pid 1's current scheduling priority: 0
```

7. Por último, verificá si el problema es de *ubicación* en lugar de *prioridad* — un proceso fijado a una CPU saturada mientras otras están ociosas:

```
$ taskset -cp 5210
pid 5210's current affinity list: 3
$ ps -eo psr,comm --no-headers | sort | uniq -c | sort -rn | head -n 4
     12 3 reindex
      3 0 nginx
```

**Comprobá tu comprensión — Ejercicio 8**

* **Q8.1** — `ps -o pcpu` muestra 3% y `top` muestra 99% para el mismo PID. ¿Cuál está equivocado, y por qué ambos son "correctos"?
* **Q8.2** — Para cada síntoma, nombrá la herramienta: (a) el trabajo está limitado por CPU y está matando de hambre a usuarios interactivos; (b) el trabajo está saturando el disco durante los backups; (c) el trabajo nunca debe ser desalojado por trabajo normal; (d) el trabajo está en la CPU equivocada.
* **Q8.3** — Configurás `ionice -c 3` (idle) en un trabajo de backup y no ves ningún cambio. Dá la razón más probable y el comando que lo confirma.
* **Q8.4** — Explicá por qué bajar la prioridad de un proceso que sostiene un lock muy disputado puede *aumentar* la latencia total del sistema. ¿Cómo se llama este fenómeno?

---

## Limpieza

```
$ for f in /tmp/p1.pid /tmp/p2.pid; do [ -f "$f" ] && kill "$(cat "$f")" 2>/dev/null; done
$ pkill -f 'while :; do :; done' 2>/dev/null
$ pkill -f 'sleep 300' 2>/dev/null
$ rm -f /tmp/burn.sh /tmp/p1.pid /tmp/p2.pid
$ ps -eo pid,ni,comm --sort=-pcpu | head -n 3
    PID  NI COMMAND
      1   0 systemd
```

Si editaste `/etc/security/limits.d/90-lab-nice.conf` o creaste un drop-in de systemd, eliminalos y ejecutá `sudo systemctl daemon-reload`. Los límites establecidos con `prlimit` desaparecen con el shell.

---

## Resumen para el día del examen

| Hecho | Valor |
|---|---|
| Valor nice por defecto de un proceso nuevo | `0` (heredado del padre) |
| Rango legal | `-20` (más favorable) … `19` (menos favorable) |
| `nice` sin ajuste | suma **`+10`** |
| `nice -n X cmd` | X es un **incremento** relativo al invocador |
| `nice -10 cmd` | forma obsoleta → incremento **`+10`**, *no* `-10` |
| `nice` sin argumentos | imprime el valor nice actual |
| Valores fuera de rango | recortados a `-20` / `19`, no rechazados |
| `renice` en Linux (util-linux) | el argumento de prioridad es **absoluto** |
| Un usuario sin privilegios puede | solo **aumentar** el valor nice, y solo en sus propios procesos |
| Restaurar un valor nice elevado | requiere root / `CAP_SYS_NICE` |
| Selectores de `renice` | `-p` PID (por defecto), `-g` PGID, `-u` usuario |
| Columna `PR` de `top` | `20 + NI`, o `rt` para tareas de tiempo real |
| Cambiar la prioridad dentro de `top` | tecla **`r`** |
| Visión del kernel | `/proc/<pid>/stat` campo 18 = `20+nice`, campo 19 = `nice` |
| nice afecta | solo la participación en el tiempo de CPU — no la memoria, no la E/S |
| nice se hereda | a través de `fork()`, y se preserva a través de `execve()` |

---

## Fuentes

* LPI — Exam 101 Objectives, v5.0, objetivo 103.6: <https://www.lpi.org/our-certifications/exam-101-objectives/>
* `nice(1)`: <https://man7.org/linux/man-pages/man1/nice.1.html>
* GNU coreutils, invocación de `nice`: <https://www.gnu.org/software/coreutils/manual/html_node/nice-invocation.html>
* `renice(1)`: <https://man7.org/linux/man-pages/man1/renice.1.html>
* `top(1)`: <https://man7.org/linux/man-pages/man1/top.1.html>
* `ps(1)`: <https://man7.org/linux/man-pages/man1/ps.1.html>
* `setpriority(2)` / `getpriority(2)`: <https://man7.org/linux/man-pages/man2/setpriority.2.html>
* `getrlimit(2)` — `RLIMIT_NICE`: <https://man7.org/linux/man-pages/man2/getrlimit.2.html>
* `sched(7)` — políticas, nice, autogroup: <https://man7.org/linux/man-pages/man7/sched.7.html>
* `proc(5)` — `/proc/[pid]/stat`, `/proc/[pid]/autogroup`: <https://man7.org/linux/man-pages/man5/proc.5.html>
* Kernel de Linux — fundamentos del diseño de nice: <https://docs.kernel.org/scheduler/sched-nice-design.html>
* Kernel de Linux — diseño de CFS: <https://docs.kernel.org/scheduler/sched-design-CFS.html>
* Kernel de Linux — cgroup v2 (`cpu.weight`, `io.weight`): <https://docs.kernel.org/admin-guide/cgroup-v2.html>
* `systemd.exec(5)` — `Nice=`: <https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html>
* `systemd.resource-control(5)` — `CPUWeight=`, `IOWeight=`: <https://www.freedesktop.org/software/systemd/man/latest/systemd.resource-control.html>
* `limits.conf(5)`: <https://man7.org/linux/man-pages/man5/limits.conf.5.html>
* `ionice(1)`: <https://man7.org/linux/man-pages/man1/ionice.1.html>
* `chrt(1)`: <https://man7.org/linux/man-pages/man1/chrt.1.html>
* `taskset(1)`: <https://man7.org/linux/man-pages/man1/taskset.1.html>

---

<details>
<summary><strong>Respuestas</strong></summary>

### Ejercicio 0

**A0.1** — Tanto `nice` como `taskset` son utilidades *envoltorio*: realizan su llamada al sistema (`setpriority(2)` y `sched_setaffinity(2)` respectivamente) y luego hacen `execve()` del resto de la línea de comandos. `execve` reemplaza la imagen del proceso **sin crear un nuevo proceso**, así que el PID nunca cambia. El `$$` registrado antes del `exec` es el mismo PID que termina ejecutando el bucle ocupado. Por eso también `nice` y `taskset` se componen libremente en cualquier orden en la misma línea de comandos.

**A0.2** — El campo 2 de `/proc/<pid>/stat` es `comm`, envuelto en paréntesis, y puede contener él mismo espacios *y* paréntesis (un proceso puede llamarse `my (weird) app`). Todos los campos posteriores a `comm` son numéricos y no contienen `)`. Un `.*)` codicioso, por lo tanto, hace coincidir hasta el **último** `)` de la línea, que está garantizado que es el paréntesis de cierre de `comm`. Una coincidencia no codiciosa se detendría en el primer `)` dentro del nombre y desplazaría todos los campos siguientes, leyendo silenciosamente la columna equivocada.

**A0.3** — `CLK_TCK` es 100, así que 198 ticks = 1.98 segundos de tiempo de CPU en 2 segundos de reloj de pared — aproximadamente una CPU completa (~99%). No es exactamente 200 porque el proceso no empieza a quemar en el instante en que arranca `sleep`, y es desalojado brevemente por hilos del kernel, interrupciones del temporizador y el propio shell. La contabilidad de ticks también es muestreada, no exacta.

---

### Ejercicio 1

**A1.1** — El valor por defecto es **0**. El rango legal es **−20 a 19** inclusive: −20 es el más favorable (mayor participación de CPU), 19 el menos favorable. El valor por defecto no es una propiedad de los "shells de login" específicamente — se hereda del padre, y la cadena se remonta a PID 1, que normalmente corre en nice 0.

**A1.2** — **5.** Nice es un atributo por tarea heredado por los hijos en `fork()` y preservado a través de `execve()`. Ni hacer fork ni reemplazar la imagen del programa lo reinician. Justamente por eso `Nice=` en una unidad de systemd se propaga a todo el árbol de procesos que la unidad genera — y por eso un shell que reniceaste le pasa el nuevo valor a todo lo que lances desde él después.

**A1.3** — **Solo los que se inician después.** `renice` llama a `setpriority(2)` sobre la tarea objetivo; no hay recursión en el árbol de procesos. Los hijos que ya están corriendo conservan el valor que heredaron en el momento de su propio fork. Para alcanzar también a los existentes tenés que apuntarlos explícitamente — `renice -n 10 -g <PGID>` para el grupo de procesos del trabajo completo, o iterar sobre `pgrep -P <pid>`.

---

### Ejercicio 2

**A2.1** — Para tareas `SCHED_OTHER`, el `PR` de `top` es `20 + NI`, dando el rango 0 (en NI −20) hasta 39 (en NI 19). Como el número *sube* a medida que la prioridad *baja*, un `PR` más bajo es mejor. Para tareas de tiempo real (`SCHED_FIFO` / `SCHED_RR`), `top` imprime la cadena literal **`rt`** en la columna `PR`, ya que esas tareas se planifican por delante de toda tarea normal y el valor nice no se les aplica.

**A2.2** — `ps -o pri` sigue la convención "número más alto = prioridad más alta", por lo que se mueve *hacia abajo* a medida que `NI` sube; `ps -l` reporta una escala interna del kernel donde el número se mueve *hacia arriba* con `NI`. La base absoluta de ambos depende de la compilación de `procps-ng` y del especificador de formato usado (`pri`, `opri`, `intpri` son todos campos distintos con escalas diferentes). **`NI` es la única columna estable entre herramientas, distribuciones y versiones** — es el valor que establecés y el valor que pregunta el examen. Escribí scripts contra `NI`, nunca contra `PRI`/`PR`.

**A2.3** — No. `%CPU` mide *cuánta CPU obtuvo el proceso*, no *a cuánta tiene derecho*. Los valores nice solo importan bajo **contención**: establecen la proporción en que las tareas ejecutables dividen una CPU que no alcanza para todas. Sin competencia en esa CPU, una tarea con nice 19 obtiene el 100% igual que lo haría una con nice 0. Esta es la razón más común por la que la gente concluye que "renice no hizo nada" — la prueba correcta es la del Ejercicio 4: dos tareas compitiendo, una CPU.

---

### Ejercicio 3

**A3.1** — Obtiene nice **+10** (incremento 10, *menos* favorable), que es lo opuesto a la intención. Los dígitos después de un `-` suelto en la sintaxis obsoleta se leen como el incremento, y un `-` inicial ahí es parte del marcador de opción, no un signo menos. Para elevar realmente la prioridad necesitás tanto la forma moderna `-n` con un número negativo explícito *como* el privilegio para usarla: `nice -n -5 /usr/local/bin/reindex` ejecutado como root (o por un usuario cuyo `RLIMIT_NICE` permita −5). Cualquier valor negativo desde un usuario de cron ordinario va a ser rechazado.

**A3.2** — GNU `nice` trata un `setpriority()` fallido como una **advertencia**, no como un error fatal: imprime el diagnóstico en stderr y luego ejecuta el comando igual, así que el estado de salida que observás es el estado del *comando*. Un script envoltorio que solo revisa `$?` va a concluir que la prioridad se aplicó. Detectalo capturando stderr (`nice -n -5 cmd 2>err.log` y probando el archivo), o — mucho mejor — verificando el resultado desde el kernel a posteriori: `ps -o ni= -p <pid>`, o hacé que el proceso imprima `nice` él mismo. Un trabajo de cron que *debe* ejecutarse con nice debería lanzarse bajo `systemd-run -p Nice=…`, que hace fallar la unidad si la propiedad no puede aplicarse.

**A3.3** — `nice -n 3 nice` imprime **8**, porque `-n` es un incremento aplicado al valor actual del invocador (5 + 3). `renice -n 3 -p $$` en cambio habría establecido el shell al valor **absoluto** **3** — en util-linux, el argumento de prioridad de `renice` no es un incremento. Esta asimetría entre los dos comandos es el detalle que más frecuentemente se pasa por alto en este objetivo. (También es una trampa de portabilidad: POSIX especifica `renice -n` como relativo, y algunas implementaciones de `renice` fuera de Linux se comportan así. Revisá `man renice` en cualquier sistema desconocido.)

---

### Ejercicio 4

**A4.1** — Nice 0 tiene peso 1024, nice −5 tiene peso 3121. Total = 4145. Nice 0 obtiene `1024 / 4145 = 24.7 %`; nice −5 obtiene `3121 / 4145 = 75.3 %`. Notá la simetría con el caso nice 0 / nice +5 del paso 2 — lo que importa es la *diferencia* de cinco niveles nice, no los valores absolutos.

**A4.2** — Un valor nice garantiza únicamente una **participación proporcional de una CPU en contención, relativa a otras tareas ejecutables en esa misma CPU y en ese mismo grupo de planificación**. No garantiza nada en términos absolutos: no limita el uso de CPU, no reserva CPU, no limita la memoria, la presión sobre la caché de páginas, el ancho de banda de E/S ni el uso de red, y no evita que el proceso sostenga locks que bloquean trabajo de mayor prioridad. En una CPU por lo demás ociosa, tanto nice 19 como nice −20 obtienen el 100%.

**A4.3** — Con 8 CPU y solo 2 tareas ejecutables, el balanceador de carga las coloca en **CPU diferentes**, así que nunca compiten y ambas corren al ~100%. Los valores nice solo hacen efecto cuando las tareas compiten por la misma cola de ejecución. El laboratorio fijó ambos procesos a una sola CPU con `taskset -c "$CPU"` precisamente para forzar la contención; podés verificar la ubicación con la columna `PSR` de `ps` o con `taskset -cp <pid>`.

**A4.4** — Es una *regla práctica* razonable para un paso: los pesos consecutivos difieren en un factor de ~1.25 (1024 → 820), así que un cambio de un nivel desplaza aproximadamente 10 puntos porcentuales de un reparto entre dos tareas (55/45 en lugar de 50/50). Es incorrecta como modelo *lineal*: la relación es geométrica, así que diez niveles no son "100%" — son `1.25^10 ≈ 9.3×`, es decir, alrededor de un reparto 90/10, y 39 niveles son una relación de ~5900×, no un absurdo 390%.

---

### Ejercicio 5

**A5.1** — Un usuario sin privilegios solo puede **aumentar** el valor nice (bajar la prioridad) de los procesos cuyo UID real o efectivo coincide con el propio, y nunca puede volver a disminuirlo — ni siquiera a un valor que el proceso tuvo antes. Un proceso con `CAP_SYS_NICE` (normalmente root) puede establecer cualquier valor en `[-20, 19]` sobre cualquier proceso. La única excepción a "nunca disminuir" es `RLIMIT_NICE`: un usuario puede bajar nice hasta el piso `20 − RLIMIT_NICE`, que por defecto es `20` (es decir, ninguna disminución en absoluto).

**A5.2** — El valor más bajo solicitable es **−10**, a partir de `20 − RLIMIT_NICE = 20 − 30 = −10`. El límite está codificado deliberadamente de esta forma — como un número positivo que se invierte hasta un piso de nice — porque los valores de `getrlimit` son sin signo. `ulimit -e 0` produce entonces un piso de 20, que está por encima del máximo 19, lo que significa "no puede bajar la prioridad en absoluto".

**A5.3** — Robo de prioridad / escalamiento de recursos en beneficio propio. Si un usuario pudiera restaurar la prioridad libremente, podría eludir cualquier despriorización administrativa: un admin renicea un trabajo por lotes desbocado a 19, y el dueño simplemente lo devolvería a 0. En términos más generales, la regla convierte a nice en un **trinquete de sentido único** para usuarios sin privilegios, de modo que una despriorización aplicada por el administrador (o por un envoltorio de lotes) es duradera, y ningún usuario puede concederse a sí mismo una participación de CPU mayor que la de sus pares.

**A5.4** — `/etc/security/limits.d/*` lo aplica el módulo PAM `pam_limits.so` **al establecerse la sesión**. La sesión SSH actual se creó antes de que el archivo existiera, así que su árbol de procesos todavía lleva el `RLIMIT_NICE` viejo. El miembro debe cerrar sesión y volver a entrar. (Verificalo con `prlimit --nice --pid $$`. Notá también que los límites de PAM no se aplican a los *servicios* de systemd — esos necesitan `LimitNICE=` en la unidad — y que el grupo debe contener realmente al usuario, lo que `id -nG <user>` confirma.)

---

### Ejercicio 6

**A6.1** — (a) **Inversión de prioridad:** un backend de PostgreSQL despriorizado que sostiene un lightweight lock, un buffer pin o el WAL insert lock es desalojado por procesos de la capa web; todos los demás backends — y por lo tanto toda solicitud web que necesite la base de datos — se bloquean detrás de él. La latencia total sube aunque se haya "liberado CPU". (b) **Procesos auxiliares críticos quedan atrapados en el radio de impacto:** `-u postgres` también alcanza al checkpointer, al WAL writer, al lanzador de autovacuum y al archiver. Un checkpointer lento alarga el tiempo de recuperación y puede detener todo el clúster cuando los segmentos de WAL se acumulan; un autovacuum hambriento lleva a bloat y, eventualmente, a que se active la protección contra wraparound del ID de transacción. El instrumento correcto para "la capa web importa más" es un `CPUWeight=` a nivel de cgroup sobre las dos unidades, no un barrido de nice por usuario.

**A6.2** — **PID** — `-p` es el valor por defecto cuando no se da ningún selector, así que `renice 5 1234` y `renice -n 5 -p 1234` son equivalentes. Como un número negativo suelto al inicio es ambiguo con una opción, preferí siempre la forma explícita `-n <value> -p <pid>` en los scripts.

**A6.3** — Un grupo de procesos corresponde exactamente a un **trabajo**: el shell pone la tubería y todos sus hijos en un único grupo de procesos, así que `-g` alcanza precisamente el árbol de procesos del trabajo desbocado y nada más. `-u` alcanza a todos los procesos que pertenecen al usuario — su shell de login, su sesión SSH, su editor, cualquier otro trabajo, y cualquier servicio de larga vida corriendo bajo la misma cuenta — lo que pierde la precisión del objetivo y además crea un problema de permisos, ya que un usuario sin privilegios no puede deshacer el cambio.

---

### Ejercicio 7

**A7.1** — (a) **Autogroups**: el kernel agrupa las tareas por *sesión*; la CPU se divide primero entre autogroups, y nice solo ordena las tareas *dentro* de un autogroup. Revelalo con `cat /proc/<pid>/autogroup` (y verificá la característica con `cat /proc/sys/kernel/sched_autogroup_enabled`); confirmá que las dos tareas están en sesiones diferentes con `ps -o pid,sid`. (b) **cgroup v2 con el controlador `cpu`**: cada unidad de systemd y sesión de login es su propio cgroup con su propio `cpu.weight`, y se aplica la misma regla de anidamiento. Revelalo con `cat /proc/<pid>/cgroup` y compará el `cpu.weight` de los dos cgroups bajo `/sys/fs/cgroup/`. (Una tercera causa, menos común, es que las dos tareas simplemente estén en CPU diferentes — verificá con `ps -o psr`.)

**A7.2** — Se crea un autogroup por cada nueva **sesión**, es decir, mediante `setsid(2)` — que es lo que hacen un emulador de terminal, un login SSH, `screen`/`tmux` y cualquier proceso que se demoniza. Toda tarea en esa sesión comparte una única entidad de planificación. La CPU se divide de forma justa *entre* autogroups (ponderada por el propio valor nice de cada autogroup en `/proc/<pid>/autogroup`), y luego la participación de cada autogroup se divide entre sus tareas según sus valores nice individuales. La característica existe para que un `make -j64` en una terminal no pueda matar de hambre al resto de un escritorio interactivo.

**A7.3** — Bajo contención con otras unidades es una carga de trabajo de **alta prioridad**. `CPUWeight=10000` es la capa externa: frente al peso por defecto de 100, esta unidad reclama aproximadamente 100× la participación de una unidad competidora a nivel de cgroup. `Nice=19` es la capa interna, y aplica solo *entre los hilos de esa unidad* — cambia cómo se divide internamente la gran participación de la unidad, no qué tan grande es esa participación. La combinación no es necesariamente un error (puede significar "esta unidad merece mucha CPU, y dentro de ella estos hilos son los de segundo plano"), pero si las dos perillas fueron configuradas por personas distintas con intenciones distintas, es un fuerte indicio de problema.

**A7.4** — La escala `cpu.weight` de cgroup v2 es un reescalado de los mismos pesos del planificador usados para nice: el peso interno de 1024 de nice 0 se mapea al valor por defecto de cgroup de **100**, y el rango 1–10000 cubre aproximadamente el rango de nice. La conversión por paso de nice es el mismo factor de ~**1.25**: nice −1 ≈ peso 125, nice +1 ≈ peso 80, nice −5 ≈ peso ~305, nice +5 ≈ peso ~33. Por eso `CPUWeight=` y `Nice=` se sienten como la misma perilla — son el mismo mecanismo aplicado en dos niveles distintos de la jerarquía de planificación.

---

### Ejercicio 8

**A8.1** — Ninguno está equivocado; miden ventanas diferentes. `ps -o pcpu` reporta `cputime / elapsed_time` — el promedio sobre **toda la vida** del proceso. Un proceso que corrió a full durante un minuto y ahora lleva una hora ocioso muestra un porcentaje bajo de un solo dígito. `top` recalcula el uso de CPU a partir del delta entre dos muestras, así que reporta la tasa **actual**. Para el triaje, confiá siempre en una cifra basada en deltas: `top -b -n 2 -d <interval>` y leé la *segunda* iteración (la primera está promediada sobre la vida del proceso, exactamente como `ps`), o calculá el delta vos mismo desde `/proc/<pid>/stat` como en el Ejercicio 0.

**A8.2** — (a) `nice` / `renice` — o, mejor en un host con systemd, `CPUWeight=`; (b) `ionice` (con la advertencia de BFQ) o `IOWeight=` / `io.max` en cgroup v2; (c) `chrt` para establecer `SCHED_FIFO` o `SCHED_RR` — con mucho cuidado, ya que una tarea de tiempo real desbocada puede bloquear una CPU por completo, que es para lo que existe `kernel.sched_rt_runtime_us`; (d) `taskset` (o `CPUAffinity=` en la unidad) para cambiar la afinidad de CPU.

**A8.3** — El planificador de E/S activo de la capa de bloques casi con seguridad no implementa prioridades de E/S. Desde la eliminación de CFQ en el kernel 5.0, solo **BFQ** respeta las clases de `ionice`; `none` y `mq-deadline` aceptan la configuración y la ignoran. Confirmalo con `cat /sys/block/<dev>/queue/scheduler` — el activo está entre corchetes. O cambiá ese dispositivo a `bfq` (`echo bfq | sudo tee /sys/block/sda/queue/scheduler`, hecho persistente vía una regla de udev) o usá `io.weight`/`io.max` de cgroup v2 en su lugar, que funciona independientemente del elevador. Dos razones adicionales para "sin efecto": la carga de trabajo está dominada por writeback, que lo emiten los hilos flusher del kernel en lugar del proceso, y por lo tanto no se atribuye a su prioridad de E/S; y el dispositivo es NVMe con suficiente profundidad de cola como para que no haya contención que arbitrar.

**A8.4** — Cuando una tarea de baja prioridad sostiene un lock que una tarea de alta prioridad necesita, la tarea de alta prioridad no puede avanzar hasta que el lock se libere — pero el que sostiene el lock está siendo planificado rara vez precisamente porque vos lo despriorizaste. La prioridad efectiva de la tarea de alta prioridad colapsa a la del poseedor del lock, y cualquier cantidad de tareas de prioridad media puede desalojar al poseedor, extendiendo el estancamiento indefinidamente. Esto es **inversión de prioridad** (en su forma no acotada). Los kernels de tiempo real lo resuelven con **herencia de prioridad** (el poseedor hereda temporalmente la prioridad del que espera; los mutexes `PTHREAD_PRIO_INHERIT` y los rtmutexes implementan esto), pero los valores nice ordinarios de `SCHED_OTHER` no tienen tal mecanismo. La regla práctica: nunca despriorices un proceso que participa en un lock, transacción o cola compartida con trabajo sensible a la latencia — despriorizá cargas de trabajo que sean genuinamente independientes.

</details>