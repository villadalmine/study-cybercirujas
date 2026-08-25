# 332.3 Control de recursos — Ejercicios guiados

> **Examen:** LPIC-3 303-300 (Security), versión 3.0.0 · **Tema 332.3** · **Peso 5**
> **Fuente del objetivo:** <https://www.lpi.org/our-certifications/exam-303-objectives/>
>
> Estos ejercicios asumen una **VM descartable** con acceso root, systemd ≥ 252 y un
> kernel ≥ 5.15 corriendo la **jerarquía unificada de cgroups** (cgroup v2). Varios pasos
> provocan deliberadamente OOM kills, agotamiento de `fork()` e inanición de I/O. **No
> los ejecutes en una máquina que te importe, ni nunca en un host compartido con otros usuarios.**
>
> Documentación de referencia usada a lo largo del texto:
> - Kernel cgroup v2 — <https://docs.kernel.org/admin-guide/cgroup-v2.html>
> - Kernel cgroup v1 — <https://docs.kernel.org/admin-guide/cgroup-v1/index.html>
> - `systemd.resource-control(5)` — <https://www.freedesktop.org/software/systemd/man/latest/systemd.resource-control.html>
> - `systemd.exec(5)` (`Limit*=`) — <https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html>
> - `limits.conf(5)` — <https://man7.org/linux/man-pages/man5/limits.conf.5.html>
> - `pam_limits(8)` — <https://man7.org/linux/man-pages/man8/pam_limits.8.html>
> - `cgroup_namespaces(7)` — <https://man7.org/linux/man-pages/man7/cgroup_namespaces.7.html>
> - Contrato de delegación de cgroups de systemd — <https://systemd.io/CGROUP_DELEGATION/>
> - Pressure Stall Information — <https://docs.kernel.org/accounting/psi.html>

**Paquetes que vas a necesitar:** `systemd` (ya presente), `python3`, `util-linux`
(`prlimit`, `unshare`, `lsns`), y opcionalmente `stress-ng` y `libcgroup-tools`
(`libcgroup-tools` en RHEL/Fedora, `cgroup-tools` en Debian/Ubuntu).

---

## Ejercicio 1 — Identificar qué jerarquía de cgroups está corriendo realmente el sistema

Antes de tocar nada tenés que saber si estás en **v2 (unificada)**,
**v1 (legacy)** o **híbrida**. Todos los ejercicios posteriores dependen de la respuesta, y el
examen espera que sepas distinguirlas solo a partir del sistema de archivos.

1. Mirá el tipo de sistema de archivos montado en la raíz de cgroups:

   ```bash
   stat -fc %T /sys/fs/cgroup/
   ```

   ```
   cgroup2fs
   ```

   `cgroup2fs` significa **unificada/v2**. `tmpfs` significa v1 o híbrida — en ese caso
   `/sys/fs/cgroup/` es solo un tmpfs que contiene un punto de montaje por controlador.

2. Confirmalo con la tabla de montajes y listá lo que hay debajo:

   ```bash
   findmnt -t cgroup2,cgroup
   ```

   ```
   TARGET         SOURCE  FSTYPE  OPTIONS
   /sys/fs/cgroup cgroup2 cgroup2 rw,nosuid,nodev,noexec,relatime,nsdelegate,memory_recursive_prot
   ```

3. Preguntale al kernel qué controladores se compilaron y a cuántas jerarquías está
   asociado cada uno:

   ```bash
   cat /proc/cgroups
   ```

   ```
   #subsys_name    hierarchy       num_cgroups     enabled
   cpuset          0               108             1
   cpu             0               108             1
   cpuacct         0               108             1
   blkio           0               108             1
   memory          0               108             1
   devices         0               108             1
   freezer         0               108             1
   net_cls         0               108             1
   pids            0               108             1
   ```

   Una columna `hierarchy` con `0` en todas las filas es la firma de v2: no hay nada montado
   en una jerarquía v1 separada.

4. Mirá qué controladores están realmente *disponibles para delegación* en la raíz del
   árbol unificado, y cuáles habilitó la raíz para sus hijos:

   ```bash
   cat /sys/fs/cgroup/cgroup.controllers
   cat /sys/fs/cgroup/cgroup.subtree_control
   ```

   ```
   cpuset cpu io memory hugetlb pids rdma misc
   cpuset cpu io memory pids
   ```

5. Encontrá el cgroup de tu propia shell:

   ```bash
   cat /proc/self/cgroup
   ```

   ```
   0::/user.slice/user-1000.slice/session-3.scope
   ```

   En v2 hay exactamente una línea, siempre `0::<path>`, y la ruta es relativa a
   la raíz de cgroups (o a la raíz de tu cgroup namespace — ver Ejercicio 13).

**Verificá tu comprensión**

- **Q1.** Tu `/proc/self/cgroup` muestra varias líneas como `8:memory:/system.slice/nginx.service` y `0::/system.slice/nginx.service`. ¿Qué modo de jerarquía es este, y qué significa la línea `0::`?
- **Q2.** ¿Qué parámetro de la línea de comandos del kernel fuerza a un sistema con systemd a volver a la jerarquía legacy v1, y cuál selecciona la híbrida?
- **Q3.** `cgroup.controllers` lista `io` pero `cgroup.subtree_control` no. ¿Cuál es la consecuencia práctica para un cgroup que crees un nivel más abajo?

---

## Ejercicio 2 — Leer la jerarquía unificada con los ojos de systemd

systemd es el **único escritor** del árbol de cgroups en una distribución moderna. Sus
herramientas son más rápidas y más seguras que recorrer `/sys/fs/cgroup` a mano.

1. Imprimí el árbol completo:

   ```bash
   systemd-cgls --no-pager | head -40
   ```

   ```
   Control group /:
   -.slice
   ├─user.slice
   │ └─user-1000.slice
   │   ├─user@1000.service …
   │   │ ├─app.slice
   │   │ │ └─dbus.service
   │   │ │   └─1183 /usr/bin/dbus-daemon --session …
   │   │ └─init.scope
   │   │   ├─1170 /usr/lib/systemd/systemd --user
   │   │   └─1172 (sd-pam)
   │   └─session-3.scope
   │     ├─1301 sshd-session: student [priv]
   │     ├─1315 -bash
   │     └─1402 systemd-cgls --no-pager
   ├─init.scope
   │ └─1 /usr/lib/systemd/systemd --system --deserialize 31
   └─system.slice
     ├─sshd.service
     │ └─902 sshd: /usr/sbin/sshd -D …
     └─nginx.service
       ├─1021 nginx: master process /usr/sbin/nginx
       └─1022 nginx: worker process
   ```

2. Fijate en los tres tipos de unidad visibles arriba y asociá cada uno a su rol:

   ```bash
   systemctl list-units --type=slice --no-pager
   systemctl list-units --type=scope --no-pager
   ```

   ```
   UNIT              LOAD   ACTIVE SUB    DESCRIPTION
   -.slice           loaded active active Root Slice
   system.slice      loaded active active System Slice
   user-1000.slice   loaded active active User Slice of UID 1000
   user.slice        loaded active active User and Session Slice
   ```

3. Observá el consumo en vivo por cgroup (apretá `q` para salir; `c`/`m`/`i`/`t` reordenan por
   CPU, memoria, I/O y cantidad de tareas):

   ```bash
   systemd-cgtop --depth=3
   ```

   ```
   Control Group                  Tasks   %CPU   Memory  Input/s Output/s
   /                                214    3.1     1.2G        -        -
   system.slice                      96    2.4   712.4M        -        -
   system.slice/nginx.service         3    1.9    24.1M        -        -
   user.slice                        41    0.6   402.8M        -        -
   ```

4. Leé los contadores de accounting de una unidad a través de la interfaz de unidades en vez del
   sistema de archivos:

   ```bash
   systemctl show nginx.service \
     -p MemoryCurrent -p MemoryPeak -p CPUUsageNSec -p TasksCurrent -p ControlGroup
   ```

   ```
   MemoryCurrent=25264128
   MemoryPeak=31948800
   CPUUsageNSec=4128993000
   TasksCurrent=3
   ControlGroup=/system.slice/nginx.service
   ```

5. Verificá los mismos números en la fuente:

   ```bash
   cat /sys/fs/cgroup/system.slice/nginx.service/memory.current
   cat /sys/fs/cgroup/system.slice/nginx.service/pids.current
   ```

**Verificá tu comprensión**

- **Q4.** Definí **slice**, **scope** y **service** en una oración cada uno, y decí cuál de los tres crea systemd para procesos que *no* forkeó él mismo.
- **Q5.** Creás una unidad slice llamada `lab-db.slice`. ¿Dónde queda ubicada en el árbol, y por qué?
- **Q6.** `MemoryCurrent` devuelve `[not set]` para una unidad. ¿Cuál es la causa más probable y cómo lo arreglás?

---

## Ejercicio 3 — rlimits para sesiones interactivas: `ulimit`, `limits.conf`, `pam_limits.so`

`ulimit` expone los límites por proceso de `setrlimit(2)`
(<https://man7.org/linux/man-pages/man2/getrlimit.2.html>). Se **heredan
a través de `fork()`/`exec()`**, que es exactamente por lo que se establecen en el stack de login.

1. Inspeccioná los límites de la shell actual, soft y hard:

   ```bash
   ulimit -Sa
   ulimit -Ha
   ```

   ```
   core file size          (blocks, -c) 0
   data seg size           (kbytes, -d) unlimited
   max locked memory       (kbytes, -l) 8192
   open files                      (-n) 1024
   max user processes              (-u) 15043
   virtual memory          (kbytes, -v) unlimited
   ```

2. Leé los mismos valores desde `/proc`, que funciona para *cualquier* PID, no solo tu shell:

   ```bash
   cat /proc/self/limits
   ```

   ```
   Limit                     Soft Limit  Hard Limit  Units
   Max open files            1024        524288      files
   Max processes             15043       15043       processes
   Max locked memory         8388608     8388608     bytes
   ```

3. Demostrá la asimetría soft/hard. Un límite soft puede ser elevado por un proceso sin
   privilegios **hasta** el límite hard, y bajar un límite hard es irreversible para
   ese árbol de procesos:

   ```bash
   bash -c 'ulimit -Sn 512; ulimit -Sn; ulimit -Sn 2048; ulimit -Sn'
   bash -c 'ulimit -Hn 4096; ulimit -Hn 8192'
   ```

   ```
   512
   2048
   bash: line 1: ulimit: open files: cannot modify limit: Operation not permitted
   ```

4. Creá un archivo de política por usuario. Nunca edites `/etc/security/limits.conf` cuando
   alcanza con un drop-in:

   ```bash
   install -d -m 0755 /etc/security/limits.d
   cat > /etc/security/limits.d/90-lab.conf <<'EOF'
   # <domain>      <type>  <item>          <value>
   student         soft    nofile          2048
   student         hard    nofile          4096
   @developers     -       nproc           256
   *               hard    core            0
   %developers     -       maxlogins       4
   EOF
   ```

5. Confirmá que `pam_limits.so` está en el stack de PAM del servicio que estás probando:

   ```bash
   grep -R pam_limits /etc/pam.d/
   ```

   ```
   /etc/pam.d/system-auth:session     required      pam_limits.so
   /etc/pam.d/sshd:session            required      pam_limits.so
   ```

   Si falta, agregá `session required pam_limits.so` al stack correspondiente.

6. Abrí una **nueva** sesión de login (los límites los aplica PAM al establecer la sesión —
   tu shell existente no va a cambiar) y verificá:

   ```bash
   ssh student@localhost -- 'ulimit -Sn; ulimit -Hn'
   ```

   ```
   2048
   4096
   ```

7. Cambiá un límite en un proceso *ya en ejecución* sin reiniciarlo:

   ```bash
   pgrep -u student -x bash
   prlimit --pid 1315 --nofile
   prlimit --pid 1315 --nofile=3000:4096
   prlimit --pid 1315 --nofile
   ```

   ```
   RESOURCE DESCRIPTION                    SOFT HARD UNITS
   NOFILE   max number of open files       2048 4096 files
   RESOURCE DESCRIPTION                    SOFT HARD UNITS
   NOFILE   max number of open files       3000 4096 files
   ```

**Verificá tu comprensión**

- **Q7.** En `limits.conf`, ¿qué significan los prefijos de dominio `@developers` y `%developers`, y qué hace un `type` de `-`?
- **Q8.** Un usuario reporta `Too many open files` aunque configuraste `nofile` en `limits.d`. Dá tres causas distintas para revisar antes de culpar a PAM.
- **Q9.** ¿Por qué `prlimit --pid` puede elevar un límite hard mientras el proceso mismo no puede, y qué capability está involucrada?

---

## Ejercicio 4 — La trampa de `limits.conf`: rlimits para **servicios**

Este es el punto del objetivo que más frecuentemente se pasa por alto: **`pam_limits.so`
solo corre dentro de una sesión PAM.** Un daemon iniciado por systemd en el arranque nunca
atraviesa un stack de PAM, así que `/etc/security/limits.conf` le es irrelevante.

1. Comprobalo. Configurá un `nofile` deliberadamente diminuto para root en `limits.d`, y después inspeccioná un
   servicio del sistema en ejecución:

   ```bash
   echo 'root hard nofile 64' > /etc/security/limits.d/91-lab-root.conf
   systemctl restart nginx.service
   cat /proc/$(systemctl show -p MainPID --value nginx.service)/limits | grep -i 'open files'
   ```

   ```
   Max open files            1024        524288      files
   ```

   Sin cambios — el servicio ignoró el archivo por completo.

2. Configurá el límite de la manera correcta, con un drop-in de unidad:

   ```bash
   systemctl edit nginx.service
   ```

   ```ini
   [Service]
   LimitNOFILE=8192:16384
   LimitCORE=0
   LimitNPROC=512
   ```

   ```bash
   systemctl daemon-reload && systemctl restart nginx.service
   cat /proc/$(systemctl show -p MainPID --value nginx.service)/limits | grep -i 'open files'
   ```

   ```
   Max open files            8192        16384       files
   ```

3. Inspeccioná y cambiá los **valores por defecto de respaldo** aplicados a toda unidad que no
   fije su propio valor:

   ```bash
   systemd-analyze cat-config systemd/system.conf | grep -i '^#\?DefaultLimit' | head
   systemctl show -p DefaultLimitNOFILESoft -p DefaultLimitNOFILE
   ```

   ```
   DefaultLimitNOFILESoft=1024
   DefaultLimitNOFILE=524288
   ```

   Para cambiarlos, dejá un archivo en `/etc/systemd/system.conf.d/` (servicios de sistema) o
   `/etc/systemd/user.conf.d/` (servicios de usuario) y reiniciá, o hacé `systemctl
   daemon-reexec` más un restart de las unidades afectadas.

4. Limpiá el sabotaje del paso 1:

   ```bash
   rm -f /etc/security/limits.d/91-lab-root.conf
   ```

**Verificá tu comprensión**

- **Q10.** Nombrá las dos superficies de configuración que fijan rlimits y decí con precisión qué procesos gobierna cada una.
- **Q11.** `LimitNOFILE=8192:16384` — ¿cuál número es cuál, y qué pasa si escribís un solo valor?
- **Q12.** Una sesión de `systemd --user` *sí* pasa por PAM. ¿Se aplica entonces `limits.conf` a los servicios de usuario? Explicá el camino que recorre el límite.

---

## Ejercicio 5 — Control transitorio de memoria con `systemd-run`

`systemd-run` es la forma más rápida de meter un comando arbitrario dentro de un cgroup
controlado, y las propiedades que acepta son exactamente las directivas de
`systemd.resource-control(5)`.

1. Escribí un asignador de memoria predecible:

   ```bash
   cat > /root/memhog.py <<'EOF'
   import sys, time
   chunk = 8 * 1024 * 1024
   blocks = []
   for i in range(1, 1000):
       blocks.append(bytearray(chunk))          # touch it: bytearray is zero-filled
       print(f"allocated {i*8} MiB", flush=True)
       time.sleep(0.2)
   EOF
   ```

2. Ejecutalo bajo un techo de memoria estricto en un scope con nombre dentro de un slice nuevo:

   ```bash
   systemd-run --scope --unit=memhog --slice=lab.slice \
       -p MemoryMax=64M -p MemorySwapMax=0 \
       python3 /root/memhog.py
   ```

   ```
   Running scope as unit: memhog.scope
   allocated 8 MiB
   allocated 16 MiB
   …
   allocated 56 MiB
   Killed
   ```

3. Confirmá que fue el kernel, no systemd, quien mató el proceso:

   ```bash
   journalctl -k -n 15 --no-pager | grep -i -A3 'out of memory'
   ```

   ```
   kernel: memhog.scope: Memory cgroup out of memory: Killed process 5192 (python3)
           total-vm:139572kB, anon-rss:63108kB, file-rss:2216kB, shmem-rss:0kB,
           UID:0 pgtables:224kB oom_score_adj:0
   ```

4. Ahora compará `MemoryHigh=` (throttling + reclamo agresivo, **sin** kill) con
   `MemoryMax=` (muro rígido, OOM kill). Ejecutá el asignador de nuevo con solo un límite soft:

   ```bash
   systemd-run --scope --unit=memhog --slice=lab.slice \
       -p MemoryHigh=64M -p MemoryMax=infinity \
       python3 /root/memhog.py
   ```

   Sigue asignando más allá de 64 MiB pero se enlentece visiblemente a medida que el kernel reclama y
   frena la tarea que asigna.

5. Mientras corre, leé los contadores de eventos desde una segunda terminal:

   ```bash
   watch -n1 cat /sys/fs/cgroup/lab.slice/memhog.scope/memory.events
   ```

   ```
   low 0
   high 2841
   max 0
   oom 0
   oom_kill 0
   ```

6. Inspeccioná el panorama completo de memoria del cgroup:

   ```bash
   cd /sys/fs/cgroup/lab.slice/memhog.scope
   cat memory.current memory.max memory.high memory.swap.max
   head -8 memory.stat
   ```

   ```
   201326592
   max
   67108864
   0
   anon 197132288
   file 2224128
   kernel 1187840
   slab 819200
   ```

**Verificá tu comprensión**

- **Q13.** Distinguí `memory.min`, `memory.low`, `memory.high` y `memory.max`, y dá la directiva de systemd que mapea a cada uno.
- **Q14.** En el paso 3, ¿qué componente eligió a la víctima y bajo qué regla — y en qué se diferencia eso del OOM killer *global*?
- **Q15.** ¿Por qué `MemorySwapMax=0` hace determinista la demostración de `MemoryMax=` en una máquina con swap habilitado?
- **Q16.** `lab.slice` no existía antes del paso 2 y no hay ningún archivo de unidad `lab.slice` en disco. ¿Por qué funcionó?

---

## Ejercicio 6 — Control de CPU: peso versus cuota

Dos mecanismos con semánticas distintas: **`cpu.weight`** es proporcional y solo
importa bajo contención; **`cpu.max`** es un techo absoluto aplicado incluso en una
máquina ociosa.

1. Iniciá dos quemadores de CPU con una relación de pesos 4:1, en segundo plano:

   ```bash
   systemd-run --unit=cpu-a --slice=lab.slice -p CPUWeight=400 \
       bash -c 'while :; do :; done'
   systemd-run --unit=cpu-b --slice=lab.slice -p CPUWeight=100 \
       bash -c 'while :; do :; done'
   ```

2. **Fijá la contención a una sola CPU**, si no ambos simplemente reciben un core cada uno y los
   pesos nunca entran en juego:

   ```bash
   systemctl set-property --runtime cpu-a.service AllowedCPUs=0
   systemctl set-property --runtime cpu-b.service AllowedCPUs=0
   ```

3. Observá el reparto:

   ```bash
   systemd-cgtop --depth=2 -n 5 | grep -E 'cpu-[ab]'
   ```

   ```
   lab.slice/cpu-a.service    1   79.8     1.1M     -     -
   lab.slice/cpu-b.service    1   19.9     1.1M     -     -
   ```

   Aproximadamente 400:100 → 80 % / 20 % de la única CPU permitida.

4. Verificá la traducción a archivos del kernel:

   ```bash
   cat /sys/fs/cgroup/lab.slice/cpu-a.service/cpu.weight
   cat /sys/fs/cgroup/lab.slice/cpu-a.service/cpuset.cpus.effective
   ```

   ```
   400
   0
   ```

5. Reemplazá el peso por una cuota absoluta y quitá el pin:

   ```bash
   systemctl set-property --runtime cpu-a.service CPUQuota=20% AllowedCPUs=
   cat /sys/fs/cgroup/lab.slice/cpu-a.service/cpu.max
   ```

   ```
   20000 100000
   ```

   El par es `$MAX $PERIOD` en microsegundos: 20 000 µs de tiempo de ejecución por cada período de
   100 000 µs = 20 % de **una** CPU. `CPUQuota=250%` sería `250000 100000` — el equivalente a dos
   CPUs y media, solo significativo en una máquina multi-core.

6. Confirmá que el techo se sostiene con la máquina por lo demás ociosa:

   ```bash
   top -b -n 2 -d 2 | grep -m2 'while'
   ```

   ```
   5411 root  20 0  8896 4480 3200 R  20.0  0.1  0:14.22 bash
   ```

7. Detené los quemadores:

   ```bash
   systemctl stop cpu-a.service cpu-b.service
   ```

**Verificá tu comprensión**

- **Q17.** En una máquina de 8 cores por lo demás ociosa, un servicio tiene `CPUWeight=10`. ¿Cuánta CPU obtiene? Ahora el mismo servicio tiene `CPUQuota=10%`. ¿Cuánto obtiene?
- **Q18.** ¿Cuál es el rango válido y el valor por defecto de `CPUWeight=`, y a qué perilla de v1 reemplaza?
- **Q19.** `CPUAffinity=` en `[Service]` y `AllowedCPUs=` ambos restringen qué CPUs usa una unidad. ¿Cuál es la diferencia mecánica, y cuál hereda un hijo que llama a `sched_setaffinity()`?
- **Q20.** ¿Por qué el paso 2 usó `systemctl set-property --runtime` en vez de `set-property` a secas?

---

## Ejercicio 7 — Hacer persistentes los límites: drop-ins y `systemctl set-property`

1. Creá un servicio chico con el que experimentar:

   ```bash
   cat > /etc/systemd/system/lab-web.service <<'EOF'
   [Unit]
   Description=Lab HTTP service for resource control exercises

   [Service]
   ExecStart=/usr/bin/python3 -m http.server 8080 --directory /usr/share/doc
   Restart=on-failure

   [Install]
   WantedBy=multi-user.target
   EOF
   systemctl daemon-reload
   systemctl start lab-web.service
   ```

2. Aplicá límites en tiempo de ejecución y observá dónde aterrizan:

   ```bash
   systemctl set-property lab-web.service MemoryMax=128M TasksMax=64 CPUQuota=50%
   find /etc/systemd/system/lab-web.service.d/ -type f -printf '%p\n' -exec cat {} \;
   ```

   ```
   /etc/systemd/system/lab-web.service.d/50-MemoryMax.conf
   # This is a drop-in unit file extension, created via "systemctl set-property"
   [Service]
   MemoryMax=134217728
   /etc/systemd/system/lab-web.service.d/50-TasksMax.conf
   [Service]
   TasksMax=64
   /etc/systemd/system/lab-web.service.d/50-CPUQuota.conf
   [Service]
   CPUQuota=50%
   ```

   Fijate en dos cosas: `set-property` **se aplica inmediatamente y persiste**, y escribió
   un drop-in por propiedad. Con `--runtime` los mismos archivos van a
   `/run/systemd/system/…` y desaparecen al reiniciar.

3. Confirmá que los valores en ejecución y los archivos del kernel coinciden:

   ```bash
   systemctl show lab-web.service -p MemoryMax -p TasksMax -p CPUQuotaPerSecUSec
   cat /sys/fs/cgroup/system.slice/lab-web.service/{memory.max,pids.max,cpu.max}
   ```

   ```
   MemoryMax=134217728
   TasksMax=64
   CPUQuotaPerSecUSec=500ms
   134217728
   64
   50000 100000
   ```

4. Mirá la configuración efectiva completa, incluyendo cada drop-in, en orden de carga:

   ```bash
   systemctl cat lab-web.service
   systemd-analyze cat-config systemd/system/lab-web.service
   ```

5. Quitá una propiedad limpiamente — asignar el valor vacío o `infinity` la resetea:

   ```bash
   systemctl set-property lab-web.service CPUQuota=
   ls /etc/systemd/system/lab-web.service.d/
   ```

**Verificá tu comprensión**

- **Q21.** Dá las tres formas de asociar un límite de recursos a un servicio y ordenalas por persistencia.
- **Q22.** ¿Por qué fijar *cualquier* propiedad `Memory*=` o `Tasks*=` activa implícitamente el accounting de esa unidad, y cuál fue el costo histórico del accounting que lo volvió opt-in en cgroup v1?
- **Q23.** Querés un límite que sobreviva a una actualización de paquete que reemplace `/etc/systemd/system/lab-web.service`. ¿Qué mecanismo elegís y por qué?

---

## Ejercicio 8 — Slices: envolturas jerárquicas y aplicables

Un slice impone un techo sobre **todo lo que está debajo de él**, que es la forma de impedir que una
clase entera de cargas de trabajo mate de hambre al sistema — no solo un proceso desbocado.

1. Escribí una unidad slice con un presupuesto real:

   ```bash
   cat > /etc/systemd/system/lab.slice <<'EOF'
   [Unit]
   Description=Lab workloads — hard resource envelope
   Before=slices.target

   [Slice]
   MemoryAccounting=yes
   MemoryHigh=256M
   MemoryMax=512M
   CPUAccounting=yes
   CPUQuota=100%
   TasksAccounting=yes
   TasksMax=200
   IOAccounting=yes
   IOWeight=50
   EOF
   systemctl daemon-reload
   ```

2. Mové el servicio dentro del slice:

   ```bash
   systemctl set-property lab-web.service Slice=lab.slice
   systemctl restart lab-web.service
   systemctl show lab-web.service -p Slice -p ControlGroup
   ```

   ```
   Slice=lab.slice
   ControlGroup=/lab.slice/lab-web.service
   ```

3. Agregá un segundo consumidor y demostrá que lo que se limita es el total del **slice**,
   no las unidades individuales. Cada hijo pide 400 MiB; el slice permite 512 MiB:

   ```bash
   systemd-run --unit=hog1 --slice=lab.slice -p MemoryMax=400M python3 /root/memhog.py
   systemd-run --unit=hog2 --slice=lab.slice -p MemoryMax=400M python3 /root/memhog.py
   sleep 20
   cat /sys/fs/cgroup/lab.slice/memory.current
   cat /sys/fs/cgroup/lab.slice/memory.events
   ```

   ```
   536870912
   low 0
   high 5122
   max 913
   oom 4
   oom_kill 1
   ```

   Ninguno de los hijos superó individualmente sus propios 400 MiB, y sin embargo uno fue matado: el
   `memory.max` del **padre** fue la restricción vinculante.

4. Visualizá el subárbol resultante:

   ```bash
   systemd-cgls /lab.slice
   ```

   ```
   Control group /lab.slice:
   ├─lab-web.service
   │ └─6021 /usr/bin/python3 -m http.server 8080 …
   ├─hog1.service
   │ └─6103 python3 /root/memhog.py
   └─hog2.service
   ```

5. Construí un slice anidado y confirmá la regla de nombrado con guiones:

   ```bash
   systemd-run --unit=nested --slice=lab-batch.slice --slice-inherit sleep 300
   systemctl show nested.service -p ControlGroup
   ls -d /sys/fs/cgroup/lab.slice/lab-batch.slice
   ```

   ```
   ControlGroup=/lab.slice/lab-batch.slice/nested.service
   /sys/fs/cgroup/lab.slice/lab-batch.slice
   ```

6. Detené los hogs:

   ```bash
   systemctl stop hog1.service hog2.service nested.service 2>/dev/null
   ```

**Verificá tu comprensión**

- **Q24.** `lab-batch.slice` se creó implícitamente bajo `lab.slice`. Enunciá la regla general, y dá el padre de `machine-qemu\x2dvm1.slice`.
- **Q25.** Los límites son jerárquicos. Si `lab.slice` tiene `MemoryMax=512M` y `lab-web.service` tiene `MemoryMax=1G`, ¿cuál es el techo efectivo del servicio?
- **Q26.** Nombrá los cuatro slices que systemd crea por defecto y decí qué contiene cada uno.
- **Q27.** ¿Cuál es la ventaja operativa de limitar `user.slice` en vez de limitar los servicios de cada usuario individualmente?

---

## Ejercicio 9 — El controlador `pids`: conteniendo tormentas de `fork()`

`TasksMax=` es la defensa más barata contra fork bombs y fugas de hilos, y a diferencia de
`ulimit -u` es **por cgroup**, no por UID — así que no se puede evadir con un segundo
login o una transición setuid.

1. Escribí una prueba de fork **acotada y auto-terminante** (más segura e informativa que
   el clásico `:(){ :|:& };:`):

   ```bash
   cat > /root/forktest.sh <<'EOF'
   #!/bin/bash
   n=0
   while [ $n -lt 500 ]; do
       sleep 60 &
       if [ $? -ne 0 ]; then
           echo "fork() failed after $n children"
           break
       fi
       n=$((n+1))
   done
   echo "spawned $n children"
   kill $(jobs -p) 2>/dev/null
   EOF
   chmod +x /root/forktest.sh
   ```

2. Ejecutala dentro de un cgroup que permite 20 tareas:

   ```bash
   systemd-run --scope --unit=forkhog --slice=lab.slice -p TasksMax=20 \
       /root/forktest.sh
   ```

   ```
   Running scope as unit: forkhog.scope
   /root/forktest.sh: fork: retry: Resource temporarily unavailable
   fork() failed after 17 children
   spawned 17 children
   ```

3. Confirmá el contador y el límite:

   ```bash
   systemd-run --scope --unit=forkhog2 --slice=lab.slice -p TasksMax=20 \
       bash -c 'for i in $(seq 15); do sleep 30 & done;
                cat /sys/fs/cgroup/lab.slice/forkhog2.scope/pids.{current,max,events};
                wait' &
   ```

   ```
   16
   20
   max 0
   ```

4. Mostrá que `TasksMax` cuenta **hilos**, no solo procesos:

   ```bash
   systemd-run --scope --unit=threadhog -p TasksMax=5 \
       python3 -c '
   import threading, time
   def w(): time.sleep(30)
   for i in range(10):
       try:
           threading.Thread(target=w).start()
       except RuntimeError as e:
           print(f"thread {i} refused: {e}"); break
   '
   ```

   ```
   thread 4 refused: can't start new thread
   ```

5. Revisá el valor por defecto a nivel sistema que systemd aplica a toda unidad:

   ```bash
   systemctl show -p DefaultTasksMax
   cat /proc/sys/kernel/pid_max
   cat /proc/sys/kernel/threads-max
   ```

   ```
   DefaultTasksMax=38207
   4194304
   126743
   ```

**Verificá tu comprensión**

- **Q28.** Dá dos formas concretas en que un proceso hostil o con bugs derrota a `ulimit -u` pero que `TasksMax=` sigue bloqueando.
- **Q29.** `TasksMax=15%` es legal. ¿Porcentaje de qué?
- **Q30.** `pids.events` muestra `max 913`. ¿Qué cuenta exactamente ese número, y qué vio la carga de trabajo a nivel de syscall?
- **Q31.** ¿Por qué el controlador pids es el único controlador con costo de ejecución esencialmente nulo, y por qué eso es un argumento para habilitarlo en todos lados?

---

## Ejercicio 10 — Control de I/O: pesos, techos y la salvedad del writeback

1. Identificá el dispositivo de bloque y su `major:minor` — la interfaz de I/O de cgroups se
   direcciona por número de dispositivo, nunca por ruta:

   ```bash
   lsblk -o NAME,MAJ:MIN,TYPE,SIZE
   ```

   ```
   NAME   MAJ:MIN TYPE  SIZE
   vda    252:0   disk   40G
   ├─vda1 252:1   part    1G
   └─vda2 252:2   part   39G
   ```

2. Creá un archivo de prueba lo suficientemente grande como para derrotar la page cache:

   ```bash
   dd if=/dev/urandom of=/var/tmp/iotest.bin bs=1M count=512 status=none
   sync
   ```

3. Medí la línea base sin throttling con **I/O directa** para saltear la page cache:

   ```bash
   dd if=/var/tmp/iotest.bin of=/dev/null bs=1M count=512 iflag=direct
   ```

   ```
   512+0 records in
   512+0 records out
   536870912 bytes (537 MB, 512 MiB) copied, 1.41 s, 381 MB/s
   ```

4. Ahora imponé un techo de ancho de banda de lectura:

   ```bash
   systemd-run --scope --unit=iohog --slice=lab.slice \
       -p IOReadBandwidthMax='/dev/vda 20M' \
       dd if=/var/tmp/iotest.bin of=/dev/null bs=1M count=512 iflag=direct
   ```

   ```
   536870912 bytes (537 MB, 512 MiB) copied, 25.6 s, 21.0 MB/s
   ```

5. Leé la visión del kernel de esa configuración:

   ```bash
   cat /sys/fs/cgroup/lab.slice/iohog.scope/io.max
   ```

   ```
   252:0 rbps=20971520 wbps=max riops=max wiops=max
   ```

6. Inspeccioná el accounting por dispositivo:

   ```bash
   cat /sys/fs/cgroup/lab.slice/io.stat
   ```

   ```
   252:0 rbytes=536870912 wbytes=8192 rios=512 wios=2 dbytes=0 dios=0
   ```

7. Repetí el paso 4 **sin** `iflag=direct` y notá que la primera corrida puede completarse
   mucho más rápido que 20 MB/s — la lectura se sirvió desde la page cache y nunca
   llegó a la capa de bloques, así que `io.max` nunca la vio.

   ```bash
   sync; echo 3 > /proc/sys/vm/drop_caches     # required for a fair buffered test
   ```

8. (Opcional) Compará el reparto proporcional. `IOWeight=` mapea a `io.weight`, que
   requiere que esté activo el planificador **BFQ** o el modelo de costos `blk-iocost`:

   ```bash
   cat /sys/block/vda/queue/scheduler
   ```

   ```
   [none] mq-deadline kyber bfq
   ```

   ```bash
   echo bfq > /sys/block/vda/queue/scheduler
   systemctl set-property --runtime lab.slice IOWeight=50
   cat /sys/fs/cgroup/lab.slice/io.weight
   ```

   ```
   default 50
   ```

**Verificá tu comprensión**

- **Q32.** ¿Por qué el throttling de escrituras bufferizadas se comporta distinto del throttling de lecturas bajo cgroup v2, y qué dos controladores deben estar ambos habilitados para que el writeback se atribuya correctamente?
- **Q33.** Enunciá la diferencia entre `IOWeight=` e `IOReadBandwidthMax=`, y nombrá las perillas de v1 a las que reemplazan.
- **Q34.** `IOWeight=` parece no hacer nada en tu dispositivo NVMe. Dá las dos razones más probables.
- **Q35.** ¿Por qué `io.max` se indexa por `major:minor` y qué se rompe si escribís `/dev/vda` directamente en él?

---

## Ejercicio 11 — cgroup v2 crudo a mano, la regla de "no procesos internos", y delegación

Tenés que poder hacer esto sin systemd — y tenés que saber por qué hacerlo *a espaldas*
de systemd está mal.

1. Primero, la manera **incorrecta pero instructiva**. Creá un cgroup directamente bajo la raíz:

   ```bash
   mkdir /sys/fs/cgroup/manual
   ls /sys/fs/cgroup/manual/
   ```

   ```
   cgroup.controllers  cgroup.events  cgroup.freeze  cgroup.max.depth
   cgroup.max.descendants  cgroup.procs  cgroup.stat  cgroup.subtree_control
   cgroup.threads  cgroup.type  cpu.max  cpu.pressure  cpu.stat  cpu.weight
   io.max  io.pressure  io.stat  memory.current  memory.events  memory.high
   memory.max  memory.pressure  memory.stat  pids.current  pids.events  pids.max
   ```

   Los archivos `memory.*`, `cpu.*`, `io.*` y `pids.*` existen acá **solo porque el
   `cgroup.subtree_control` de la raíz ya habilita esos controladores** (Ejercicio 1,
   paso 4).

2. Fijá un límite y mové un proceso adentro:

   ```bash
   echo 32M > /sys/fs/cgroup/manual/memory.max
   echo 10  > /sys/fs/cgroup/manual/pids.max
   sleep 300 &
   echo $! > /sys/fs/cgroup/manual/cgroup.procs
   cat /proc/$!/cgroup
   ```

   ```
   0::/manual
   ```

   Nota: `cgroup.procs` acepta **un PID por escritura**, y escribir un PID mueve el
   proceso entero (todos sus hilos) — `cgroup.threads` es lo que mueve un hilo
   individual, y solo en modo threaded.

3. Demostrá la regla de **"no procesos internos"**. Intentá habilitar un controlador para
   los hijos de un cgroup que él mismo contiene procesos:

   ```bash
   mkdir /sys/fs/cgroup/manual/child
   echo "+memory" > /sys/fs/cgroup/manual/cgroup.subtree_control
   ```

   ```
   bash: echo: write error: Device or resource busy
   ```

   Bajá el proceso un nivel y volvé a intentar:

   ```bash
   echo $! > /sys/fs/cgroup/manual/child/cgroup.procs
   echo "+memory +pids" > /sys/fs/cgroup/manual/cgroup.subtree_control
   cat /sys/fs/cgroup/manual/cgroup.subtree_control
   ```

   ```
   memory pids
   ```

4. Desarmalo. Un cgroup solo se puede eliminar cuando está vacío, y solo con `rmdir`:

   ```bash
   kill %1
   rmdir /sys/fs/cgroup/manual/child /sys/fs/cgroup/manual
   ```

5. Ahora la manera **correcta** en un host con systemd: pedí un subárbol delegado, y poseelo
   en exclusiva (<https://systemd.io/CGROUP_DELEGATION/>):

   ```bash
   systemd-run --unit=deleg --slice=lab.slice \
       -p Delegate=yes -p MemoryMax=256M \
       sleep 600
   ROOT=/sys/fs/cgroup/lab.slice/deleg.service
   cat $ROOT/cgroup.controllers
   mkdir $ROOT/worker-a $ROOT/worker-b
   echo "+memory +pids" > $ROOT/cgroup.subtree_control
   echo 64M > $ROOT/worker-a/memory.max
   systemd-cgls $ROOT
   ```

   ```
   memory pids cpu io
   Control group /lab.slice/deleg.service:
   ├─ 7213 sleep 600
   ├─worker-a
   └─worker-b
   ```

   Todo lo que está bajo `deleg.service` ahora es tuyo; systemd no lo va a tocar, y el
   techo que fijaste en la unidad sigue restringiendo todo el subárbol.

6. (Opcional) El conjunto de herramientas `libcgroup`, todavía nombrado en los objetivos. En v2
   requiere libcgroup ≥ 3.0:

   ```bash
   cgcreate -g memory,pids:/lab-manual
   cgset -r memory.max=64M lab-manual
   cgget -g memory:lab-manual | head -4
   cgexec -g memory,pids:lab-manual -- sleep 60 &
   cgdelete -g memory,pids:/lab-manual
   ```

   La configuración persistente de v1 vivía en `/etc/cgconfig.conf` (definiciones) y
   `/etc/cgrules.conf` (clasificación automática por usuario/grupo/comando, aplicada por
   `cgrulesengd`); `cgclassify` mueve PIDs ya en ejecución.

**Verificá tu comprensión**

- **Q36.** Enunciá con precisión la regla de "no procesos internos" y explicá por qué el cgroup raíz está exento.
- **Q37.** ¿Por qué solo podés agregar un controlador a `cgroup.subtree_control` si aparece en el propio `cgroup.controllers` de ese cgroup?
- **Q38.** ¿Qué cambia realmente `Delegate=yes` — nombrá las dos cosas que systemd hace distinto para esa unidad.
- **Q39.** ¿Por qué crear manualmente `/sys/fs/cgroup/manual` en un host con systemd es una violación de política aunque el kernel lo permita?
- **Q40.** ¿Qué funcionalidades de cgroup v1 **no** tienen equivalente en v2 a través del sistema de archivos, y cómo se maneja una de ellas en v2?

---

## Ejercicio 12 — Pressure Stall Information y `systemd-oomd`

PSI mide *cuánto tiempo estuvieron demoradas las tareas* esperando un recurso — una señal de
alerta temprana mucho mejor que la utilización, y la entrada sobre la que actúa `systemd-oomd`.

1. Confirmá que PSI está disponible:

   ```bash
   cat /proc/pressure/memory
   cat /proc/pressure/io
   ```

   ```
   some avg10=0.00 avg60=0.00 avg300=0.00 total=1842991
   full avg10=0.00 avg60=0.00 avg300=0.00 total=402118
   ```

   Si estos archivos no existen, al kernel le falta `CONFIG_PSI` o arrancó con
   `psi=0`; agregá `psi=1` a la línea de comandos del kernel.

2. Leé los contadores por cgroup, que es lo que hace a PSI accionable por carga de trabajo:

   ```bash
   cat /sys/fs/cgroup/lab.slice/memory.pressure
   cat /sys/fs/cgroup/lab.slice/cpu.pressure
   ```

3. Generá presión real y mirá cómo trepa `avg10`:

   ```bash
   systemd-run --unit=press --slice=lab.slice -p MemoryHigh=64M \
       python3 /root/memhog.py
   watch -n1 cat /sys/fs/cgroup/lab.slice/press.service/memory.pressure
   ```

   ```
   some avg10=71.42 avg60=38.11 avg300=9.02 total=18422991
   full avg10=64.88 avg60=33.70 avg300=8.14 total=16102118
   ```

   `some` = al menos una tarea demorada; `full` = **todas** las tareas ejecutables demoradas, es decir,
   el cgroup no hizo ningún trabajo útil durante esa fracción de tiempo.

4. Configurá `systemd-oomd` para actuar sobre esa señal
   (<https://www.freedesktop.org/software/systemd/man/latest/systemd-oomd.service.html>):

   ```bash
   systemctl status systemd-oomd.service --no-pager
   systemd-analyze cat-config systemd/oomd.conf
   ```

   ```
   [OOM]
   #SwapUsedLimit=90%
   #DefaultMemoryPressureLimit=60%
   #DefaultMemoryPressureDurationSec=30s
   ```

5. Inscribí un slice — `systemd-oomd` solo monitorea cgroups que lo piden explícitamente:

   ```bash
   systemctl set-property lab.slice \
       ManagedOOMMemoryPressure=kill \
       ManagedOOMMemoryPressureLimit=50% \
       ManagedOOMSwap=kill
   systemctl show lab.slice -p ManagedOOMMemoryPressure -p ManagedOOMMemoryPressureLimit
   ```

   ```
   ManagedOOMMemoryPressure=kill
   ManagedOOMMemoryPressureLimit=50%
   ```

6. Miralo decidir:

   ```bash
   journalctl -u systemd-oomd.service -f
   ```

   ```
   systemd-oomd[721]: Memory pressure for /lab.slice is greater than 50% for
                      more than 30s with reclaim activity: 62.11% > 50% for 31s
   systemd-oomd[721]: Killed /lab.slice/press.service due to memory pressure
   ```

7. Controlá qué unidad se sacrifica y cómo se acota el kill:

   ```bash
   systemctl set-property press.service ManagedOOMPreference=avoid   # or: omit
   systemctl set-property press.service OOMPolicy=stop OOMScoreAdjust=500
   ```

**Verificá tu comprensión**

- **Q41.** Distinguí `some` de `full` en una línea de PSI, y explicá por qué `full` carece de sentido a nivel de CPU del sistema entero.
- **Q42.** Acá hay tres componentes distintos que pueden matar un proceso por razones de memoria. Nombralos y dá la señal/mecanismo que usa cada uno.
- **Q43.** `systemd-oomd` está corriendo pero nunca mata nada en tu slice sobrecargado. Dá los dos prerrequisitos de configuración que revisarías primero.
- **Q44.** ¿Qué controla `OOMPolicy=`, y en qué se diferencia de `OOMScoreAdjust=`?

---

## Ejercicio 13 — Cgroup namespaces (nociones)

El objetivo exige conocer los cgroup namespaces: virtualizan la *vista* de
la jerarquía, que es lo que permite a un contenedor verse a sí mismo en `/` en vez de en
`/system.slice/docker-abc123.scope`.

1. Anotá tu ruta real, después entrá en un cgroup namespace nuevo:

   ```bash
   cat /proc/self/cgroup
   ```

   ```
   0::/user.slice/user-1000.slice/session-3.scope
   ```

   ```bash
   unshare --cgroup --mount --pid --fork --mount-proc bash
   cat /proc/self/cgroup
   ```

   ```
   0::/
   ```

   Mismo cgroup, mismos límites — solo cambió el *nombre*. La raíz del namespace quedó fijada
   al cgroup que era el actual al momento de `unshare()`.

2. Confirmá que los límites siguen aplicando leyendo una ruta relativa dentro del namespace:

   ```bash
   mount -t cgroup2 none /sys/fs/cgroup
   ls /sys/fs/cgroup/
   cat /sys/fs/cgroup/memory.max 2>/dev/null || echo "root of namespace: no limit file"
   exit
   ```

3. Enumerá los cgroup namespaces del host:

   ```bash
   lsns -t cgroup
   ```

   ```
   NS         TYPE   NPROCS PID  USER  COMMAND
   4026531835 cgroup    214   1  root  /usr/lib/systemd/systemd --system …
   4026532741 cgroup      2 8123 root  bash
   ```

4. Entrá a un namespace existente por PID:

   ```bash
   nsenter -t 8123 -C -m -p -- cat /proc/self/cgroup
   ```

5. Observá que la opción de montaje `nsdelegate` (visible en el Ejercicio 1, paso 2) convierte
   la raíz del namespace en un **límite de delegación**: un proceso adentro no puede migrarse a sí
   mismo fuera de la raíz de su namespace, ni siquiera con acceso de escritura al `cgroup.procs`
   de un ancestro.

**Verificá tu comprensión**

- **Q45.** ¿Entrar a un cgroup namespace cambia los límites de recursos que aplican a un proceso? ¿Qué cambia exactamente?
- **Q46.** ¿Por qué `--mount` (más remontar `/sys/fs/cgroup`) suele combinarse con `--cgroup`?
- **Q47.** ¿Qué impone la opción de montaje `nsdelegate`, y por qué importa para contenedores sin privilegios?

---

## Limpieza

```bash
systemctl stop lab-web.service cpu-a.service cpu-b.service \
               hog1.service hog2.service press.service deleg.service 2>/dev/null
systemctl disable lab-web.service 2>/dev/null
rm -rf /etc/systemd/system/lab-web.service /etc/systemd/system/lab-web.service.d
rm -f  /etc/systemd/system/lab.slice
rm -f  /etc/security/limits.d/90-lab.conf /etc/security/limits.d/91-lab-root.conf
rm -f  /root/memhog.py /root/forktest.sh /var/tmp/iotest.bin
systemctl daemon-reload
systemctl reset-failed
rmdir /sys/fs/cgroup/manual 2>/dev/null
echo mq-deadline > /sys/block/vda/queue/scheduler   # only if you changed it
systemd-cgls /lab.slice 2>/dev/null || echo "lab.slice gone"
```

---

<details>
<summary><strong>Respuestas</strong></summary>

### Ejercicio 1 — identificación de la jerarquía

**A1.** Es el modo **híbrido**. `/sys/fs/cgroup/unified` lleva una jerarquía cgroup v2
junto a los montajes v1 por controlador. Las líneas numeradas (`8:memory:…`) son
jerarquías v1, cada una con su propia lista de controladores y su propia ruta. La línea `0::` es
la jerarquía v2: ID de jerarquía 0, campo de controladores vacío, una ruta para todos los
controladores. En modo híbrido systemd usa la jerarquía v2 puramente para *organización*
y seguimiento de procesos, mientras que el *control* de recursos sigue pasando por los controladores v1 —
por eso un sistema híbrido va a mostrar `0::` pero ignorar `memory.max`.

**A2.** `systemd.unified_cgroup_hierarchy=0` fuerza legacy v1;
`systemd.unified_cgroup_hierarchy=0 systemd.legacy_systemd_cgroup_controller=0`
selecciona híbrido. `systemd.unified_cgroup_hierarchy=1` (el valor por defecto desde systemd v243
en la mayoría de las distribuciones) selecciona v2 unificada. Se configuran vía el bootloader — por ejemplo
`grubby --update-kernel=ALL --args=...` o `GRUB_CMDLINE_LINUX` más
`grub2-mkconfig`.

**A3.** El cgroup hijo no va a tener **ningún archivo `io.*` en absoluto**. En v2 los archivos de
interfaz de un controlador aparecen en un cgroup solo si el **padre** habilitó ese controlador en
su `cgroup.subtree_control`. Un controlador que no podés ver es un controlador que no podés
configurar — esta es la causa número uno de "creé el cgroup pero `io.max` no
existe".

### Ejercicio 2 — la visión de systemd

**A4.**
- **Slice** — una unidad puramente organizativa que no posee procesos por sí misma; agrupa
  otras unidades en un nodo del árbol para que se puedan aplicar límites a una rama entera.
- **Service** — una unidad para procesos que systemd **inició él mismo** vía `ExecStart=`.
- **Scope** — una unidad para procesos que **ya fueron forkeados por otra cosa**
  (una sesión de login, `systemd-run --scope`, un gestor de contenedores) y que después se
  *registran* con systemd.

  El scope es el de los procesos ajenos.

**A5.** `/sys/fs/cgroup/lab.slice/lab-db.slice`. **Solo para unidades slice**, el guion es
el separador de jerarquía: `a-b-c.slice` es hijo de `a-b.slice`, que es hijo de
`a.slice`. (Esto no aplica a nombres de service o scope, donde `Slice=` por sí solo
determina la ubicación.)

**A6.** El accounting está apagado para esa unidad. Habilitalo con `systemctl set-property
<unit> MemoryAccounting=yes`, o globalmente con `DefaultMemoryAccounting=yes` en
`/etc/systemd/system.conf`. Fijar cualquier límite `Memory*=` enciende el accounting
implícitamente. En cgroup v2 con systemd moderno los valores por defecto ya son `yes` para
memoria, CPU, tasks e IO, así que `[not set]` en general significa un
`MemoryAccounting=no` explícito o un systemd muy viejo.

### Ejercicio 3 — rlimits y PAM

**A7.**
- `@developers` — el **grupo** `developers`; coincide con cualquier usuario que sea miembro.
- `%developers` — se usa **solo** con `maxlogins`; limita el número *agregado* de
  logins simultáneos de todos los miembros de ese grupo, en vez de por usuario.
- El tipo `-` fija **los límites soft y hard simultáneamente** al mismo valor.

  (Los dominios también pueden ser un nombre de usuario, `*` como comodín aplicado al final, un rango de UID/GID
  como `@1000:1999`, o rangos abiertos `:1000` / `1000:`.)

**A8.** (1) `pam_limits.so` está ausente del stack de PAM de ese servicio en particular
(`/etc/pam.d/sshd` vs `/etc/pam.d/login` vs `/etc/pam.d/su` son todos separados).
(2) El proceso es un **servicio de systemd**, no una sesión de login, así que `limits.conf` nunca se
aplicó — necesita `LimitNOFILE=` (Ejercicio 4). (3) La aplicación nunca elevó su
límite *soft* hacia el hard, o hace su propia llamada a `setrlimit()` con valores fijos. Revisá también
el techo global `fs.file-max` y el `fs.nr_open` por usuario, y si una
línea comodín `*` posterior en `limits.conf` está sobreescribiendo la específica.

**A9.** Elevar un límite hard requiere `CAP_SYS_RESOURCE`. `prlimit` corriendo como root la
tiene; el proceso destino no. `prlimit` usa la syscall `prlimit64(2)`, que
opera sobre *otro* proceso — necesita `CAP_SYS_RESOURCE` en el user namespace del destino,
además de los permisos habituales de acceso ptrace sobre el destino.

### Ejercicio 4 — la trampa de limits.conf

**A10.**
- `/etc/security/limits.conf` + `/etc/security/limits.d/*.conf`, aplicados por
  `pam_limits.so`, gobiernan **solo los procesos que arrancan dentro de una sesión PAM**:
  logins interactivos, `ssh`, `su`, `sudo`, trabajos de `cron` (vía `pam_limits` en
  `/etc/pam.d/crond`), gestores de pantalla.
- `Limit*=` en una unidad de systemd (`systemd.exec(5)`), con
  `DefaultLimit*=` en `/etc/systemd/system.conf` y `/etc/systemd/user.conf` como
  respaldos, gobiernan **las unidades que systemd inicia** — o sea, todos los daemons de la máquina.

**A11.** `soft:hard`. Un valor único fija **ambos**, soft y hard, al mismo número.
Se acepta `infinity` para cualquiera de los dos campos.

**A12.** No directamente. PAM aplica `limits.conf` al **proceso gestor `systemd --user`**
al establecer la sesión, y los rlimits del gestor son luego heredados por los servicios de
usuario que lanza — salvo que la unidad de usuario los sobreescriba con su propio `Limit*=`, o que
lo haga `DefaultLimit*=` de `/etc/systemd/user.conf`. Así que el valor llega por herencia
a través del gestor, no porque PAM evalúe cada servicio de usuario.

### Ejercicio 5 — control de memoria

**A13.**
| Archivo | systemd | Semántica |
|---|---|---|
| `memory.min` | `MemoryMin=` | **Protección estricta.** La memoria por debajo de esto nunca se reclama, ni siquiera bajo presión global; puede llevar al sistema al OOM para respetarla. |
| `memory.low` | `MemoryLow=` | **Protección de mejor esfuerzo.** El reclamo evita este cgroup hasta que se agoten los otros candidatos. |
| `memory.high` | `MemoryHigh=` | **Throttle.** Por encima, las tareas que asignan son fuertemente frenadas y se fuerza el reclamo. Nunca dispara el OOM killer. |
| `memory.max` | `MemoryMax=` | **Techo rígido.** Primero reclamo, después invoca al OOM killer del cgroup si falla. |

También `memory.swap.max` / `MemorySwapMax=`, y `memory.zswap.max` / `MemoryZSwapMax=`.

**A14.** El **OOM killer del cgroup**, invocado por el controlador de memoria cuando el cgroup
llega a `memory.max` y el reclamo no puede hacer lugar. Elige una víctima **únicamente dentro
de ese cgroup**, ordenada por `oom_score` (aproximadamente proporcional al RSS, ajustado por
`oom_score_adj`). El OOM killer *global* se dispara cuando la máquina entera se queda sin
memoria y elige entre **todos** los procesos del sistema. La diferencia práctica es la
contención: un OOM de cgroup mata al infractor y deja el resto de la máquina
intacto. Fijar `memory.oom.group=1` (systemd: interacciones con `OOMPolicy=` / atributo del
cgroup) hace que el kill se aplique atómicamente a todos los procesos del cgroup en vez de a
una sola víctima.

**A15.** Sin eso, el kernel puede satisfacer la asignación llevando páginas anónimas a swap.
El `memory.current` del cgroup se mantiene en el techo mientras la carga sigue
creciendo hacia el swap, así que el OOM kill ocurre tarde, lentamente, o nunca — el timing
pasa a depender de la velocidad del disco. `MemorySwapMax=0` elimina el swap como válvula de escape y
hace el muro rígido e inmediato.

**A16.** systemd **genera unidades slice implícitamente**. Cualquier nombre que termine en `.slice`
y que no tenga archivo de unidad en disco se instancia con propiedades por defecto (sin límites).
Eso hace barato el agrupamiento ad-hoc, pero también significa que un error de tipeo en `--slice=` crea
silenciosamente un slice nuevo y vacío en vez de fallar — verificá con `systemctl show <unit> -p
Slice`.

### Ejercicio 6 — CPU

**A17.** Con `CPUWeight=10` en una máquina ociosa: **las 8 CPUs, 800 %** si puede usarlas.
El peso es proporcional y solo restringe bajo contención — nunca es un techo.
Con `CPUQuota=10%`: **0,1 de una CPU**, siempre, esté la máquina ociosa o no.

**A18.** `CPUWeight=` acepta **1–10000**, por defecto **100**. Mapea a `cpu.weight`
y reemplaza a `cpu.shares` de cgroup v1 (cuyo rango era 2–262144, por defecto 1024).
systemd convierte entre ambos rangos automáticamente cuando corre sobre v1.

**A19.** `CPUAffinity=` llama a `sched_setaffinity(2)` sobre el proceso al momento del exec — es
un **atributo de proceso** y un hijo puede llamar a `sched_setaffinity()` para volver a ampliarse
(sujeto a permisos). `AllowedCPUs=` fija `cpuset.cpus` en el cgroup —
es un **atributo de cgroup**, aplicado por el kernel a todas las tareas del cgroup, y del
que no se puede escapar desde adentro. Para contención, usá `AllowedCPUs=`. `AllowedMemoryNodes=`
es el equivalente para nodos NUMA (`cpuset.mems`).

**A20.** `--runtime` escribe el drop-in en `/run/systemd/system/…` en vez de
`/etc/systemd/system/…`, así que el cambio se aplica inmediatamente pero **desaparece al
reiniciar**. Es la opción correcta para experimentos de laboratorio, mitigación de incidentes y cualquier cosa
que no quieras dejar atrás en el sistema de archivos.

### Ejercicio 7 — persistencia

**A21.** En orden creciente de persistencia:
1. `systemd-run -p …` — transitorio; la unidad y sus límites desaparecen cuando el proceso
   termina.
2. `systemctl set-property --runtime` — aplicado inmediatamente, vive en
   `/run/systemd/system/`, se pierde al reiniciar.
3. `systemctl set-property` (sin flag) o `systemctl edit` — drop-in bajo
   `/etc/systemd/system/<unit>.d/`, sobrevive reinicios **y** actualizaciones de paquete del
   archivo de unidad base.

**A22.** Un límite carece de sentido sin un contador: el kernel debe seguir el recurso
para saber cuándo se cruza el umbral, así que systemd habilita el correspondiente
`*Accounting=` implícitamente. Históricamente, en cgroup v1 el controlador de memoria tenía un
overhead medible por página (una jerarquía separada de contadores de páginas, aproximadamente 1 % de la
memoria más un costo en la ruta de fallos de página), así que las distribuciones dejaban `DefaultMemoryAccounting=no`.
cgroup v2 integró el accounting dentro de la ruta de la page cache y lo hizo esencialmente gratuito,
que es por lo que systemd moderno lo deja en `yes` por defecto.

**A23.** Un **drop-in** en `/etc/systemd/system/lab-web.service.d/override.conf`
(creado con `systemctl edit`). Las actualizaciones de paquete reemplazan la unidad del proveedor bajo
`/usr/lib/systemd/system/` — o, si el paquete instala en `/etc`, el gestor de paquetes
pregunta — pero los directorios de drop-in nunca se tocan, y sus valores de `[Section]` se
fusionan por encima de lo que diga el archivo del proveedor. Reemplazar el archivo de unidad entero en
`/etc` también funciona pero diverge silenciosamente de los cambios de upstream.

### Ejercicio 8 — slices

**A24.** Para unidades slice, `-` separa componentes de la ruta: `a-b-c.slice` vive en
`/a.slice/a-b.slice/a-b-c.slice`. El padre de `machine-qemu\x2dvm1.slice` es
`machine.slice` — el `\x2d` es un **guion literal escapado por systemd** dentro del nombre de la VM
`qemu-vm1`, así que no crea otro nivel. Usá `systemd-escape -u` para decodificar.

**A25.** **512 MiB.** Los límites se componen hacia abajo del árbol por intersección: un hijo solo puede
ser *más* restrictivo que lo disponible desde sus ancestros. Fijar un límite de hijo
mayor que el del padre es legal y silenciosamente inefectivo — una mala configuración
común a buscar cuando un límite "no funciona".

**A26.** `-.slice` (la raíz), `system.slice` (servicios de sistema), `user.slice`
(sesiones de usuario, subdividida en `user-<UID>.slice`), y `machine.slice`
(VMs y contenedores registrados con `systemd-machined`). `init.scope` también está en
la raíz, conteniendo al PID 1 mismo, pero es un scope, no un slice.

**A27.** Te da un techo **agregado** aplicable. Los límites por servicio no
se componen: N usuarios, cada uno dentro de sus límites individuales, igual pueden agotar la máquina
entre todos. Limitar `user.slice` garantiza una reserva fija para `system.slice` — sshd,
el agente de monitoreo, el daemon de auditoría siguen respondiendo — así que todavía podés loguearte y
diagnosticar una máquina que los usuarios interactivos sobrecargaron. Este es el patrón estándar
de "mantener la máquina alcanzable".

### Ejercicio 9 — pids

**A28.** (1) `ulimit -u` (`RLIMIT_NPROC`) cuenta procesos **por UID real en todo
el sistema**, así que una carga que baja privilegios a un segundo UID, o un helper `setuid`,
consigue un presupuesto fresco; `TasksMax` cuenta por cgroup sin importar el UID.
(2) Un proceso privilegiado con `CAP_SYS_RESOURCE` puede elevar su propio `RLIMIT_NPROC` en
tiempo de ejecución; no puede elevar `pids.max`, que se escribe desde fuera del cgroup. Además:
`RLIMIT_NPROC` no se aplica a root en absoluto en muchos kernels, mientras que `pids.max` sí.

**A29.** Porcentaje de `/proc/sys/kernel/threads-max` — el máximo de tareas a nivel sistema
del kernel. `DefaultTasksMax=15%` es el valor por defecto histórico de systemd expresado
de esa forma.

**A30.** La cantidad de veces que un `fork()`/`clone()` en ese cgroup fue **rechazado**
porque `pids.current` había alcanzado `pids.max`. La carga vio que `fork()` devolvía
`-EAGAIN`, es decir, `Resource temporarily unavailable`. (`pids.events.local` distingue
los rechazos causados por el límite propio de este cgroup de los heredados de un ancestro.)

**A31.** Mantiene un único contador entero incrementado y decrementado en
`fork()`/`exit()` — sin contabilidad por página, sin intervención del planificador, sin hooks en la ruta
de I/O. Como el costo es inmedible y la falla que previene (fork bomb, fuga de
hilos, agotamiento de PIDs que te deja completamente afuera de la máquina) es catastrófica e
irrecuperable sin reiniciar, `TasksMax=` es el único límite que vale la pena fijar en
todo por defecto.

### Ejercicio 10 — I/O

**A32.** Las lecturas y las escrituras directas/sincrónicas se emiten en el contexto de la
tarea solicitante, así que la capa de bloques sabe a qué cgroup cobrarle. Las **escrituras bufferizadas**
se emiten mucho después por hilos de writeback del kernel, en un contexto completamente distinto.
cgroup v2 lo resuelve etiquetando cada página sucia con su cgroup de memoria propietario al momento
del fallo de página y haciendo que el writeback consulte esa etiqueta — lo que requiere **tanto el controlador `memory`
como el `io` habilitados en la misma jerarquía unificada**. Esta es una de las razones
centrales por las que v2 existe: en v1 los dos controladores vivían en jerarquías separadas,
así que el throttling de escrituras bufferizadas era fundamentalmente imposible.

**A33.** `IOWeight=` (→ `io.weight`, rango 1–10000, por defecto 100) es **proporcional**:
solo divide el ancho de banda cuando los dispositivos están en contención, y nunca deja el dispositivo ocioso.
`IOReadBandwidthMax=` / `IOWriteBandwidthMax=` (→ `io.max` `rbps=`/`wbps=`) son
**techos absolutos**, aplicados incluso cuando el dispositivo está ocioso; `IOReadIOPSMax=` /
`IOWriteIOPSMax=` son sus equivalentes en tasa de operaciones. En cgroup v1 estos eran
`blkio.weight` y `blkio.throttle.read_bps_device` en el controlador `blkio`.

**A34.** (1) El planificador de I/O activo es `none` (típico para NVMe con `mq`), así que
nada implementa el reparto proporcional — necesitás **BFQ**, o el modelo de costos `blk-iocost`
configurado vía `io.cost.qos` / `io.cost.model` (systemd lo expone como el ajuste `io.cost`
adyacente a `IOReadBandwidthMax`, normalmente vía `iocost.conf`).
(2) **No hay contención**: los pesos son invisibles a menos que dos cgroups estén
compitiendo por el mismo dispositivo al mismo tiempo. Una tercera posibilidad es que el
controlador `io` no esté en el `cgroup.subtree_control` del padre.

**A35.** La capa de bloques identifica dispositivos por `dev_t` (major:minor), no por ruta — un
dispositivo puede tener muchos nombres en `/dev` vía symlinks y reglas de `udev`, y una ruta no significa
nada para el kernel en esa capa. Escribir `/dev/vda` directamente en `io.max` produce
`write error: Invalid argument`. systemd es más amable: `IOReadBandwidthMax=/dev/vda
20M` acepta una ruta (o incluso un punto de montaje de sistema de archivos) y la resuelve a
`major:minor` por vos al momento de aplicarla — que es también por lo que puede no hacer nada silenciosamente si
la ruta todavía no existe cuando la unidad arranca.

### Ejercicio 11 — cgroups crudos y delegación

**A36.** **Un cgroup no-raíz puede contener procesos, o puede distribuir recursos a
cgroups hijos, pero no ambas cosas.** Concretamente: no podés escribir en `cgroup.subtree_control`
mientras `cgroup.procs` no esté vacío, y no podés mover un proceso a un cgroup que
ya tiene controladores habilitados para sus hijos. La raíz está exenta porque debe
contener procesos que existen antes de que exista cualquier estructura de cgroups (hilos del kernel, init
temprano) y no tiene a dónde delegarlos. La regla existe para que la competencia por
recursos sea siempre **entre hermanos** — un problema de distribución bien definido —
en vez de entre las propias tareas de un padre y sus hijos, que no tiene una respuesta
coherente. (Los cgroups threaded, `cgroup.type=threaded`, son la excepción deliberada para
control a nivel de hilo solo de CPU.)

**A37.** Porque `cgroup.controllers` es exactamente el conjunto que el **padre** te concedió al
listarlo en *su* `cgroup.subtree_control`. La disponibilidad se propaga estrictamente
de arriba hacia abajo, un nivel por vez, y esto es lo que hace segura la delegación: un subárbol
delegado nunca puede habilitar un controlador que su delegante retuvo, así que un contenedor no puede
concederse a sí mismo control de I/O que el host no tenía intención de darle.

**A38.** (1) systemd **deja de administrar el interior del cgroup** — no va a crear,
eliminar ni reasignar cgroups por debajo de la unidad, y no va a resetear atributos ahí.
(2) **Otorga propiedad de escritura** al usuario de la unidad: hace `chown` del directorio del cgroup
de la unidad, de `cgroup.procs`, `cgroup.subtree_control` y `cgroup.threads` al
`User=` de la unidad, y habilita los controladores solicitados en el propio
`cgroup.subtree_control` de la unidad para que el subárbol pueda realmente usarlos. `Delegate=memory pids`
concede un subconjunto específico. También implica soporte de cgroup namespace en el sentido del
límite de delegación (`nsdelegate`).

**A39.** Rompe la **regla del escritor único** (<https://systemd.io/CGROUP_DELEGATION/>).
systemd asume que es el propietario exclusivo del árbol fuera de los subárboles delegados; puede
resetear atributos, podar cgroups "desconocidos" en un `daemon-reload`, o producir un accounting
que no coincida con la realidad. Tu cgroup también puede desaparecer bajo tus pies sin
aviso. El camino soportado es una unidad con `Delegate=yes`, que te da un subárbol que
systemd promete contractualmente no tocar.

**A40.** Eliminados en v2: **`net_cls` y `net_prio`** (etiquetado de classid/prioridad), la
interfaz de archivos del controlador **`devices`** independiente, la interfaz v1 de **`freezer`**, y
**`cpuacct`** como controlador separado. Sus reemplazos: el acceso a dispositivos ahora es un
**programa eBPF** asociado al cgroup (`BPF_PROG_TYPE_CGROUP_DEVICE`, expuesto por
systemd como `DeviceAllow=`/`DevicePolicy=`); la clasificación de red se hace con
`bpf_get_cgroup_classid()`/eBPF asociado al cgroup (systemd: `IPAddressAllow=`,
`SocketBindAllow=`, `RestrictNetworkInterfaces=`); el congelamiento ahora es el archivo core
`cgroup.freeze` (systemd: `systemctl freeze`/`thaw`); y el accounting de CPU está
integrado en `cpu.stat`.

### Ejercicio 12 — PSI y oomd

**A41.** `some` = la fracción de tiempo de reloj en la que **al menos una** tarea ejecutable estuvo
demorada esperando el recurso — una señal de *contención*. `full` = la fracción en la que
**todas** las tareas ejecutables estuvieron demoradas simultáneamente — una señal de *pérdida total de
trabajo productivo*. `full` es indefinido/siempre cero para CPU a nivel de sistema, porque si
todas las tareas estuvieran demoradas por CPU no habría, por definición, ninguna tarea que correr y
por lo tanto nada que las demore — la CPU nunca está "no disponible" globalmente, solo en contención.
*Sí* tiene sentido por cgroup (`cpu.pressure`), donde un cgroup con throttling genuinamente puede
tener todas sus tareas demoradas mientras otros cgroups corren.

**A42.**
1. **OOM killer del cgroup en el kernel** — se dispara en `memory.max` cuando el reclamo falla; envía
   `SIGKILL` a la tarea con mayor `oom_score` de ese cgroup (o a todo el cgroup con
   `memory.oom.group=1`).
2. **OOM killer global del kernel** — se dispara ante el agotamiento a nivel sistema; `SIGKILL` al
   peor infractor en cualquier lado.
3. **`systemd-oomd`** — un daemon de *espacio de usuario* que actúa sobre PSI y umbrales de swap
   *antes* de que el kernel se quede sin memoria; mata un **cgroup** entero (todos sus
   procesos) vía `SIGKILL`, eligiendo entre las unidades que se inscribieron con
   `ManagedOOM*=kill`. Ser proactivo es el punto: actúa mientras la máquina está
   trasheando pero todavía es recuperable, mientras que el kernel actúa solo ante el agotamiento real.

**A43.** (1) Ningún cgroup se inscribió — `ManagedOOMMemoryPressure=kill` (o
`ManagedOOMSwap=kill`) debe estar fijado en un **slice**, y `systemd-oomd` solo mata
*descendientes* de un slice monitoreado, nunca al slice mismo si es una hoja con
procesos. (2) Falta accounting/PSI — el slice necesita `MemoryAccounting=yes`, y
`/proc/pressure/` debe existir (`CONFIG_PSI`, no haber arrancado con `psi=0`). Después revisá que
la presión haya realmente superado `ManagedOOMMemoryPressureLimit=` durante todo el
`DefaultMemoryPressureDurationSec=` (por defecto 30 s) *con actividad de reclamo* — un pico
breve no lo va a disparar.

**A44.** `OOMPolicy=` (`continue` | `stop` | `kill`) le dice a **systemd** qué hacer con
el resto de la *unidad* después de que el kernel mata por OOM a uno de sus procesos: dejarla
corriendo, detener la unidad, o matar todos los procesos restantes de ella. `OOMScoreAdjust=`
(−1000…1000) se escribe en `/proc/PID/oom_score_adj` y sesga la elección de víctima
del **kernel** — −1000 hace a un proceso efectivamente inmune, +1000 lo hace el primero
en morir. Uno moldea las consecuencias, el otro moldea la selección.

### Ejercicio 13 — cgroup namespaces

**A45.** **No, los límites no cambian.** El proceso permanece exactamente en el mismo cgroup
y todos los `memory.max`, `cpu.max` y `pids.max` por encima siguen restringiéndolo. Lo que cambia es
la **vista**: `/proc/self/cgroup` reporta rutas relativas al cgroup raíz del namespace,
así que un proceso containerizado ve `0::/` en vez de
`0::/system.slice/docker-abc.scope`. Esto es presentación, no aplicación de límites.

**A46.** Porque `/proc/self/cgroup` es solo la mitad del panorama — el montaje de `/sys/fs/cgroup`
heredado del host sigue exponiendo la jerarquía *entera* del host, filtrando
nombres y rutas de cgroups hermanos y ancestros. Un mount namespace privado te permite
remontar `cgroup2` de modo que su raíz sea la raíz de tu namespace, haciendo la vista consistente y
previniendo la divulgación de información. Los runtimes de contenedores siempre hacen ambas cosas.

**A47.** `nsdelegate` convierte a la raíz de cada cgroup namespace en un **límite de delegación** que el
kernel hace cumplir: un proceso adentro no puede moverse a sí mismo (ni mover nada más) a un cgroup
**fuera** de la raíz de su namespace, aunque tenga permiso de escritura sobre el
`cgroup.procs` del destino, y no puede modificar archivos de control de recursos en esa raíz o por encima de ella.
Para contenedores sin privilegios esto es lo que permite que el host entregue un subárbol a un contenedor
que gestiona sus propios cgroups internos libremente, con la garantía dura de que no puede escapar
del techo que el host fijó en el cgroup del límite.

</details>