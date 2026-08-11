# 352.1 Conceptos de Virtualización de Contenedores — Ejercicios Guiados

> **Examen:** LPIC-3 305-300, versión 3.0 · **Peso del tema:** 11.67
> **Fuente del objetivo:** <https://www.lpi.org/our-certifications/exam-305-objectives/>
>
> Estos ejercicios construyen el aislamiento de contenedores *a mano*, usando las mismas primitivas que un runtime como `runc`, `crun` o LXC usa por debajo: **namespaces**, **cgroups**, **capabilities** y los módulos de seguridad del kernel **seccomp / SELinux / AppArmor**. Acá no vas a usar Docker para *crear* el aislamiento — vas a usar las herramientas del kernel directamente para poder ver dónde vive realmente un contenedor.

## Prerrequisitos

- Un host Linux con **cgroup v2** (por defecto en Fedora, RHEL 9+, Debian 11+, Ubuntu 22.04+). Verificá con `stat -fc %T /sys/fs/cgroup` → debe imprimir `cgroup2fs`.
- Root o `sudo`.
- Paquetes: `util-linux` (`unshare`, `nsenter`, `lsns`), `iproute2` (`ip`), `libcap` / `libcap2-bin` (`capsh`, `getpcaps`) y `runc`. En Fedora: `sudo dnf install -y util-linux iproute libcap runc`.
- Un runtime de `containers` solo para exportar un sistema de archivos raíz más adelante (`docker` o `podman`).

> ⚠️ Ejecutá esto en una VM descartable o en una máquina que puedas reiniciar. Vas a crear network namespaces, cgroups y mounts. Nada de esto es destructivo si seguís los pasos de limpieza, pero los experimentos con namespaces pueden dejar procesos huérfanos.

---

## Ejercicio 1 — Un namespace es apenas un inode: demostralo

El kernel expone cada namespace al que pertenece un proceso como un symlink mágico bajo `/proc/<pid>/ns/`. Dos procesos comparten un namespace **si y solo si** esos symlinks apuntan al mismo número de inode. Esta es la verdad de base de "mismo contenedor / distinto contenedor".

1. Mirá los namespaces de tu propia shell:

   ```bash
   ls -l /proc/$$/ns
   ```

   Esperado (los números de inode van a diferir en tu host):

   ```
   lrwxrwxrwx 1 user user 0 Aug 11 10:02 cgroup -> 'cgroup:[4026531835]'
   lrwxrwxrwx 1 user user 0 Aug 11 10:02 ipc -> 'ipc:[4026531839]'
   lrwxrwxrwx 1 user user 0 Aug 11 10:02 mnt -> 'mnt:[4026531841]'
   lrwxrwxrwx 1 user user 0 Aug 11 10:02 net -> 'net:[4026531840]'
   lrwxrwxrwx 1 user user 0 Aug 11 10:02 pid -> 'pid:[4026531836]'
   lrwxrwxrwx 1 user user 0 Aug 11 10:02 time -> 'time:[4026531834]'
   lrwxrwxrwx 1 user user 0 Aug 11 10:02 user -> 'user:[4026531837]'
   lrwxrwxrwx 1 user user 0 Aug 11 10:02 uts -> 'uts:[4026531838]'
   ```

2. Fijate en los ocho tipos de namespace: `cgroup`, `ipc`, `mnt`, `net`, `pid`, `time`, `user`, `uts`. Anotá el número de inode de **`uts`**.

3. En una *segunda* terminal, ejecutá el mismo comando y compará el inode de `uts`. En un sistema normal cada proceso comparte los namespaces iniciales del host, así que los números coinciden.

4. Listá cada namespace del sistema y cuántos procesos hay en cada uno:

   ```bash
   sudo lsns --type uts
   ```

   Esperado (una sola fila — el UTS namespace del host contiene todo):

   ```
           NS TYPE NPROCS   PID USER COMMAND
   4026531838 uts     214     1 root /usr/lib/systemd/systemd ...
   ```

**Comprobación de comprensión 1**

1. ¿Cuál es el mecanismo que decide si dos procesos están "en el mismo contenedor" para una dimensión de recurso dada?
2. Hay ocho tipos de namespace en el paso 2. ¿Cuál **no** es una frontera de aislamiento en el sentido clásico, sino que cambia lo que *reporta* `/proc/self/cgroup`?
3. ¿Por qué `lsns` muestra actualmente un único UTS namespace con PID 1 como propietario?

---

## Ejercicio 2 — Crear aislamiento con `unshare`

`unshare` ejecuta un programa con namespaces nuevos. Vas a construir el aislamiento de *hostname* y *PID* de un contenedor mínimo sin ninguna herramienta de contenedores.

1. Creá un nuevo namespace **UTS** y cambiá el hostname solo dentro de él:

   ```bash
   sudo unshare --uts bash
   hostname isolated-box
   hostname
   ```

   Adentro: `isolated-box`. Ahora abrí otra terminal en el host y ejecutá `hostname` — sigue mostrando el nombre del host. El cambio quedó contenido.

2. Confirmá que la shell está en un namespace UTS *distinto* del host comparando inodes:

   ```bash
   # inside the unshared shell
   readlink /proc/$$/ns/uts
   ```

   El inode difiere del que anotaste en el Ejercicio 1. Salí de esta shell (`exit`) antes de continuar.

3. Ahora creá un namespace **PID + mount** para que la shell aislada vea su propio árbol de procesos. `--fork` y `--mount-proc` son necesarios para que la semántica de PID 1 funcione y `/proc` refleje el nuevo namespace de PID:

   ```bash
   sudo unshare --pid --fork --mount-proc bash
   ps -ef
   ```

   Esperado — la shell es **PID 1** y casi no ve nada más:

   ```
   UID          PID    PPID  C STIME TTY          TIME CMD
   root           1       0  0 10:10 pts/0    00:00:00 bash
   root          10       1  0 10:10 pts/0    00:00:00 ps -ef
   ```

4. Desde una terminal del host, encontrá esa misma `bash` y observá que tiene un PID grande y común:

   ```bash
   ps -ef | grep '[b]ash' | tail -1
   ```

   El mismo proceso, dos PID distintos. Salí de la shell no compartida después.

5. Construí un **user namespace** como usuario *sin privilegios* y convertite en root dentro de él — sin `sudo`:

   ```bash
   unshare --user --map-root-user --uts bash
   id
   ```

   Esperado: `uid=0(root) gid=0(root) groups=0(root)`. Sos "root" — pero solo dentro de este namespace.

6. Probá la frontera. Intentá algo que requiera privilegio real del host:

   ```bash
   hostname newname     # succeeds: you also unshared UTS
   cat /etc/shadow      # fails: Permission denied
   ```

**Comprobación de comprensión 2**

1. ¿Por qué se necesitan tanto `--fork` como `--mount-proc` para que el aislamiento del namespace de PID se vea correcto en `ps`?
2. En el paso 5 te convertiste en UID 0 sin `sudo`. ¿Qué privilegios reales, a nivel del host, *no* tiene ese root, y qué funcionalidad mapea tu UID externo al UID 0 interno?
3. Un user namespace es el único namespace que un usuario sin privilegios puede crear en la mayoría de las distros. ¿Por qué es esto a la vez la funcionalidad que habilita los **contenedores rootless** e, históricamente, una gran superficie de ataque del kernel?

---

## Ejercicio 3 — Unirse a un contenedor existente con `nsenter`

`nsenter` es la herramienta de depuración para contenedores: entra en los namespaces de un proceso *en ejecución*. Así es como se "obtiene una shell dentro de un contenedor" sin el runtime del contenedor.

1. Iniciá un proceso aislado de larga duración y guardá su PID. En la terminal A:

   ```bash
   sudo unshare --uts --net --pid --fork --mount-proc sleep 3000 &
   echo $!        # note this PID (the unshare wrapper); find the child sleep:
   sudo lsns --type net | tail -1
   ```

   Encontrá el PID del proceso que sostiene el *nuevo* net namespace (el árbol `sleep`/`unshare`).

2. Desde la terminal B, entrá en los namespaces UTS + NET + PID de ese proceso y ejecutá una shell como si estuvieras dentro del "contenedor":

   ```bash
   TARGET=<pid-from-step-1>
   sudo nsenter --target "$TARGET" --uts --net --pid ip addr
   ```

   Esperado — ves la vista de red del *contenedor*, que es apenas un loopback sin direcciones configuradas:

   ```
   1: lo: <LOOPBACK> mtu 65536 qdisc noop state DOWN group default qlen 1000
       link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
   ```

   Contraste: el mismo `ip addr` en el host muestra todas tus interfaces reales.

3. Entrá a *todos* los namespaces del destino a la vez (el patrón común "exec into container"):

   ```bash
   sudo nsenter --target "$TARGET" --all bash
   ```

4. Limpieza: `sudo kill "$TARGET"` (o `kill %1` en la terminal A).

**Comprobación de comprensión 3**

1. `docker exec -it <c> sh` y `sudo nsenter -t <pid> -a sh` producen casi el mismo resultado. En términos de las primitivas del objetivo, ¿qué está haciendo realmente `docker exec`?
2. En el paso 2 el contenedor tenía solo una interfaz `lo` caída. ¿Qué tendrías que construir para que alcance la red, y qué tipo de namespace es dueño de esa vista?
3. ¿Por qué `nsenter` puede requerir unirse al namespace de **mount** *antes* de poder ejecutar un binario que solo existe dentro del sistema de archivos raíz del contenedor?

---

## Ejercicio 4 — Network namespaces con `ip netns` y un par `veth`

El subcomando `ip netns` gestiona network namespaces *con nombre* (persistidos como bind-mounts bajo `/var/run/netns/`). Vas a cablear un namespace al host con un par de ethernet virtual — el mecanismo exacto detrás de un bridge de contenedores.

1. Creá un network namespace con nombre e inspeccionalo:

   ```bash
   sudo ip netns add ctr1
   sudo ip netns list
   sudo ip netns exec ctr1 ip addr
   ```

   Dentro de `ctr1` solo hay `lo`, y está `DOWN`.

2. Creá un par `veth` — un extremo queda en el host, el otro se mueve a `ctr1`:

   ```bash
   sudo ip link add veth-host type veth peer name veth-ctr
   sudo ip link set veth-ctr netns ctr1
   ```

3. Asigná direcciones y levantá ambos extremos:

   ```bash
   sudo ip addr add 10.10.0.1/24 dev veth-host
   sudo ip link set veth-host up

   sudo ip netns exec ctr1 ip addr add 10.10.0.2/24 dev veth-ctr
   sudo ip netns exec ctr1 ip link set veth-ctr up
   sudo ip netns exec ctr1 ip link set lo up
   ```

4. Demostrá la conectividad a través de la frontera del namespace:

   ```bash
   sudo ip netns exec ctr1 ping -c2 10.10.0.1
   ```

   Esperado:

   ```
   64 bytes from 10.10.0.1: icmp_seq=1 ttl=64 time=0.045 ms
   64 bytes from 10.10.0.1: icmp_seq=2 ttl=64 time=0.039 ms
   ```

5. Confirmá que el aislamiento es real — el namespace tiene su propia tabla de ruteo y firewall:

   ```bash
   sudo ip netns exec ctr1 ip route
   # 10.10.0.0/24 dev veth-ctr proto kernel scope link src 10.10.0.2
   ```

6. Limpieza:

   ```bash
   sudo ip netns del ctr1        # deleting the netns also destroys veth-ctr
   sudo ip link del veth-host 2>/dev/null || true
   ```

**Comprobación de comprensión 4**

1. Cuando moviste `veth-ctr` a `ctr1`, su par `veth-host` quedó atrás. ¿Por qué un par `veth` es el bloque de construcción natural para conectar un contenedor a un bridge del host?
2. Los namespaces de `ip netns` persisten incluso sin ningún proceso adentro. ¿Dónde los mantiene vivos el kernel, y en qué se diferencia eso de los namespaces *anónimos* creados por `unshare`?
3. Tu contenedor podía hacer ping a `10.10.0.1` pero no podía alcanzar internet. ¿Qué dos piezas del lado del host (una de ruteo, una de reescritura de paquetes) agregaría un plugin CNI real para arreglar eso?

---

## Ejercicio 5 — Control groups v2: limitar memoria y CPU

Los namespaces controlan *lo que un proceso ve*; los cgroups controlan *cuánto puede consumir*. Vas a colocar un proceso en un cgroup, limitar su memoria y observar cómo el kernel lo mata por OOM dentro de ese cgroup solamente.

1. Confirmá la jerarquía y habilitá los controllers que necesitás en el subárbol de la raíz:

   ```bash
   stat -fc %T /sys/fs/cgroup            # -> cgroup2fs
   cat /sys/fs/cgroup/cgroup.controllers # available controllers
   echo "+memory +cpu" | sudo tee /sys/fs/cgroup/cgroup.subtree_control
   ```

2. Creá un cgroup hoja y limitá su memoria a 20 MiB:

   ```bash
   sudo mkdir /sys/fs/cgroup/demo
   echo "20M" | sudo tee /sys/fs/cgroup/demo/memory.max
   ```

3. Limitá la CPU al 20% de un core (`quota period`; 20000 µs de cada 100000 µs):

   ```bash
   echo "20000 100000" | sudo tee /sys/fs/cgroup/demo/cpu.max
   ```

4. Lanzá una shell y movela al cgroup escribiendo su PID:

   ```bash
   sudo bash -c 'echo $$ > /sys/fs/cgroup/demo/cgroup.procs; exec bash'
   cat /sys/fs/cgroup/demo/cgroup.procs   # your shell PID is listed
   ```

5. Desde otra terminal, observá el cgroup mientras disparás el límite de memoria. En la shell **limitada**, reservá más de 20 MiB:

   ```bash
   python3 -c 'a = bytearray(50 * 1024 * 1024); print("allocated"); input()'
   ```

   Esperado: el proceso es **Killed** antes de imprimir `allocated`.

6. Leé la contabilidad que el kernel guardó para ese cgroup:

   ```bash
   cat /sys/fs/cgroup/demo/memory.current   # current usage in bytes
   cat /sys/fs/cgroup/demo/memory.events    # look for oom_kill 1
   ```

   Se espera que `memory.events` incluya:

   ```
   oom 1
   oom_kill 1
   ```

7. Limpieza (un directorio de cgroup solo puede eliminarse cuando está vacío de procesos):

   ```bash
   exit                                     # leave the capped shell
   sudo rmdir /sys/fs/cgroup/demo
   ```

**Comprobación de comprensión 5**

1. ¿Cuál es la regla de "no procesos internos" de cgroup v2, y por qué tuviste que habilitar los controllers vía `cgroup.subtree_control` en el *padre* en lugar de en `demo` mismo?
2. El límite de memoria se aplicó mediante un OOM kill *acotado al cgroup*. ¿En qué se diferencia eso de un OOM global del sistema, y por qué importa para nodos multi-tenant?
3. Un `cpu.max` de `20000 100000` limita pero no "reserva". ¿Qué archivo de cgroup usarías para darle a una carga de trabajo un *peso garantizado* bajo contención, y cómo se mapea eso a los **requests** vs **limits** de CPU de Kubernetes?

---

## Ejercicio 6 — Capabilities: dividir root en pedazos

Un "root" de contenedor no es root completo. El kernel divide el privilegio en ~40 **capabilities**, y los runtimes descartan la mayoría. Vas a inspeccionar y manipular los conjuntos de capabilities directamente.

1. Mirá las capabilities de tu shell actual:

   ```bash
   capsh --print
   ```

   Como usuario normal, `Current:` está vacío. Como root, `Current:` es el conjunto completo.

2. Leé los conjuntos crudos desde `/proc`:

   ```bash
   grep Cap /proc/$$/status
   ```

   Esperado (usuario sin privilegios — todos los efectivos en cero):

   ```
   CapInh: 0000000000000000
   CapPrm: 0000000000000000
   CapEff: 0000000000000000
   CapBnd: 000001ffffffffff
   CapAmb: 0000000000000000
   ```

3. Decodificá una máscara de bits en nombres de capability:

   ```bash
   capsh --decode=000001ffffffffff     # the full bounding set
   ```

4. Ahora decodificá la máscara con la que corre un **contenedor Docker por defecto** — un conjunto deliberadamente reducido de 14 capabilities:

   ```bash
   capsh --decode=00000000a80425fb
   ```

   Esperado:

   ```
   0x00000000a80425fb=cap_chown,cap_dac_override,cap_fowner,cap_fsetid,cap_kill,
   cap_setgid,cap_setuid,cap_setpcap,cap_net_bind_service,cap_net_raw,
   cap_sys_chroot,cap_mknod,cap_audit_write,cap_setfcap
   ```

5. Descartá una capability del **bounding set** y demostrá que no puede volver. Iniciá una shell root que descartó `CAP_NET_RAW`:

   ```bash
   sudo capsh --drop=cap_net_raw --print | grep -i bounding
   ```

   `cap_net_raw` está ausente del Bounding set. Un proceso acá nunca puede usar raw sockets — así es exactamente como un runtime impide el `ping`-vía-raw-socket o el ARP spoofing desde dentro de un contenedor.

6. Inspeccioná las capabilities *efectivas* de un proceso en ejecución por PID:

   ```bash
   getpcaps 1        # PID 1 / systemd
   ```

**Comprobación de comprensión 6**

1. Nombrá los cinco conjuntos de capabilities en `/proc/<pid>/status` (Inh, Prm, Eff, Bnd, Amb) y explicá, en una línea cada uno, qué controla cada uno.
2. Un contenedor corre como UID 0 pero con el conjunto reducido de Docker del paso 4. ¿Qué única capability, si se agregara de vuelta, permitiría más directamente que un proceso cargue un módulo del kernel o de otro modo escape — y por qué a `CAP_SYS_ADMIN` se la apoda "el nuevo root"?
3. El **bounding set** es un techo que un proceso no puede elevar, ni siquiera mediante execve de un archivo con file-capabilities. ¿Por qué descartar capabilities del bounding set (no solo del effective set) es la acción relevante para la seguridad de un contenedor?

---

## Ejercicio 7 — seccomp, SELinux y AppArmor: la segunda pared

Las capabilities regulan *cuáles* operaciones privilegiadas se permiten; **seccomp** regula *cuáles syscalls* son alcanzables en absoluto, y **SELinux/AppArmor** aplican etiquetas/perfiles de control de acceso obligatorio (MAC) independientemente del UID. Todo contenedor real apila estos mecanismos.

1. Verificá el modo seccomp de tu propia shell y de un proceso de contenedor:

   ```bash
   grep Seccomp /proc/$$/status
   ```

   Esperado en el host: `Seccomp:	0` (0 = deshabilitado, 1 = SECCOMP_MODE_STRICT, 2 = SECCOMP_MODE_FILTER).

2. Iniciá un contenedor e inspeccioná el filtro de syscalls que instaló el runtime:

   ```bash
   podman run --rm -d --name secdemo busybox sleep 1000   # or docker
   PID=$(podman inspect -f '{{.State.Pid}}' secdemo)
   grep -E 'Seccomp|Seccomp_filters' /proc/$PID/status
   ```

   Esperado — el runtime aplicó un filtro:

   ```
   Seccomp:	2
   Seccomp_filters:	1
   ```

3. Demostrá que el filtro bloquea syscalls peligrosos. El perfil por defecto deniega `unshare`/`mount` y similares. Desde dentro de un contenedor con *perfil por defecto*, un intento de `mount` devuelve `Operation not permitted` aunque parezcas ser root. Compará contra correr el mismo contenedor con `--security-opt seccomp=unconfined` (hacé esto solo para observar la diferencia, después detenelo).

4. Detectá el sistema MAC activo.

   - **SELinux** (Fedora/RHEL):

     ```bash
     getenforce                 # Enforcing
     ps -eZ | grep -i container # container_t label on container processes
     ```

     Forma de etiqueta esperada: `system_u:system_r:container_t:s0:c123,c456`. El **par de categorías MCS** único `c123,c456` es lo que impide que dos contenedores toquen los archivos del otro, incluso como root.

   - **AppArmor** (Debian/Ubuntu/SUSE):

     ```bash
     sudo aa-status
     ```

     Esperado: incluye un perfil de contenedor en modo enforce, p. ej. `containers-default-0.<version>` o `docker-default`.

5. Detené la demo: `podman rm -f secdemo`.

**Comprobación de comprensión 7**

1. Un contenedor corre como UID 0 con `CAP_SYS_ADMIN` otorgado, pero su perfil seccomp deniega el syscall `mount`. ¿Puede montar un sistema de archivos? Explicá por qué capabilities y seccomp son compuertas *independientes*.
2. SELinux etiqueta los procesos de contenedor como `container_t` con un par de categorías MCS único por contenedor. ¿Cómo evita eso que un contenedor con acceso de lectura a una ruta del host lea los archivos de *otro* contenedor, aunque ambos corran como root?
3. Los tres mecanismos — seccomp, capabilities, MAC (SELinux/AppArmor) — suelen describirse como "defensa en profundidad". Da un ataque que cada capa bloquee de forma independiente y que las otras dos no bloquearían.

---

## Ejercicio 8 — La OCI runtime spec: correr un contenedor desde un bundle con `runc`

Docker y Podman son motores de alto nivel. Por debajo, le entregan a un **OCI runtime** de bajo nivel (`runc`, `crun`) un *bundle*: un directorio que contiene un sistema de archivos raíz más un `config.json` escrito según la **OCI Runtime Specification**. Vas a ensamblar ese bundle vos mismo.

1. Creá un directorio de bundle y generá el `config.json` por defecto:

   ```bash
   mkdir -p ~/oci-bundle/rootfs
   cd ~/oci-bundle
   runc spec                 # writes ./config.json
   ls
   # config.json  rootfs
   ```

2. Poblá `rootfs` con un sistema de archivos raíz real exportando una imagen busybox:

   ```bash
   CID=$(podman create busybox)         # or: docker create busybox
   podman export "$CID" | tar -C rootfs -xf -
   podman rm "$CID"
   ls rootfs                            # bin dev etc proc sys tmp usr var ...
   ```

3. Inspeccioná la spec. Fijate cómo el aislamiento que construiste a mano ahora está *declarado* como datos:

   ```bash
   grep -A2 '"namespaces"' config.json | head
   grep -A5 'capabilities' config.json | head
   grep -A3 'linux' config.json | head
   ```

   El `config.json` lista un array `namespaces` (pid, network, ipc, uts, mount), un bloque `capabilities` reducido, una sección seccomp y `resources` de cgroup. Todo lo de los Ejercicios 1–7 está acá como un manifiesto.

4. Configurá el proceso para que sea una shell y deshabilitá la terminal para una corrida no interactiva editando `config.json` (`.process.args` → `["sh"]`, `.process.terminal` → `false`), luego ejecutalo:

   ```bash
   sudo runc run demo-oci
   ```

   Obtenés un prompt `sh` dentro del bundle. Verificá el aislamiento que `runc` configuró por vos:

   ```bash
   hostname                  # runc (the spec's default hostname)
   ps -ef                    # PID 1 is your sh
   id                        # uid=0, but reduced capabilities
   exit
   ```

5. Desde una segunda terminal, listá los contenedores OCI en ejecución y su estado:

   ```bash
   sudo runc list
   # ID         PID    STATUS    BUNDLE                  ...
   # demo-oci   12345  running   /root/oci-bundle        ...
   ```

6. Relacioná esto con la **image spec**. La capa busybox que exportaste vino de una *imagen* OCI (un manifiesto + config + tarballs de capas comprimidos con gzip, direccionados por contenido mediante digest SHA-256). El runtime no consume imágenes directamente — un motor *desempaqueta* las capas de la imagen en el `rootfs` del bundle y *sintetiza* el `config.json`.

**Comprobación de comprensión 8**

1. Distinguí la **OCI Image Specification** de la **OCI Runtime Specification**. ¿Qué artefacto describe cada una, y qué componente se ubica entre ambas?
2. En el paso 3, `config.json` declaró namespaces, capabilities, seccomp y límites de cgroup como datos. ¿Por qué esta separación — bundle declarativo vs. runtime que lo aplica — es lo que hace que los runtimes sean intercambiables (`runc` ↔ `crun` ↔ `youki`)?
3. Las imágenes OCI se direccionan por contenido mediante digest y se construyen a partir de capas apiladas. ¿Qué dos propiedades operativas (una sobre caché/transferencia, una sobre integridad) te da el direccionamiento por contenido gratis?

---

## Ejercicio 9 — Contenedores vs virtualización completa: reunir la evidencia

El objetivo te pide explicar cómo la virtualización de contenedores *se diferencia* de la virtualización completa y las implicancias de seguridad. En lugar de memorizarlo, reuní los hechos observables.

1. Confirmá que un contenedor comparte el **kernel del host**. Dentro de cualquier contenedor:

   ```bash
   podman run --rm busybox uname -r
   uname -r     # on the host
   ```

   Las dos versiones de kernel son **idénticas** — un contenedor no puede correr un kernel distinto.

2. Confirmá que una VM **no** comparte el kernel: un guest `libvirt`/KVM reporta su *propio* `uname -r`, independiente del host. (Conceptual — compará contra una VM si tenés una del Tema 351.)

3. Medí la frontera. El "PID 1" de un contenedor es un proceso normal del host (Ejercicio 2); los procesos de una VM son invisibles para el kernel del host — el hipervisor solo ve threads de `vCPU`. Confirmá el lado del contenedor:

   ```bash
   podman run --rm -d --name cmp busybox sleep 300
   PID=$(podman inspect -f '{{.State.Pid}}' cmp)
   ps -o pid,comm -p "$PID"      # visible on the host!
   podman rm -f cmp
   ```

4. Razoná sobre la superficie de ataque. Un contenedor habla directamente con la interfaz completa de syscalls del kernel del host (~350 syscalls), restringido solo por seccomp/capabilities/MAC. Una VM habla con una interfaz estrecha de hardware virtual (virtio) y un hipervisor pequeño. Por eso un bug de escalada de privilegios del kernel es un **escape de contenedor** pero normalmente no un **escape de VM**.

**Comprobación de comprensión 9**

1. Completá el trade-off: los contenedores ganan en **_______** y **_______**; las VMs completas ganan en **_______** (fortaleza del aislamiento) por **_______** (kernel compartido vs. separado).
2. Se divulga un zero-day en un handler de syscall de Linux. Explicá por qué todo contenedor en un nodo está potencialmente expuesto, mientras que los guests de VM en el mismo nodo probablemente no.
3. "Un contenedor es un proceso, una VM es una máquina". Usando los hechos que reuniste en los pasos 1 y 3, justificá ese lema con precisión — nombrá la funcionalidad del kernel que hace de un contenedor *un proceso con una vista restringida* en lugar de una máquina separada.

---

<details>
<summary><strong>Respuestas</strong> (clic para expandir)</summary>

### Ejercicio 1

1. El inode compartido del symlink del namespace bajo `/proc/<pid>/ns/`. Dos procesos están en el mismo namespace para una dimensión sii `/proc/<pidA>/ns/<type>` y `/proc/<pidB>/ns/<type>` resuelven al **mismo número de inode** (`ns:[<inode>]`). La "pertenencia a un contenedor" es por dimensión, no global.
2. El namespace **`cgroup`**. No aísla recursos (eso lo hacen los cgroups mismos); *virtualiza la vista de la jerarquía de cgroups* para que un proceso vea su propio cgroup como la raíz en `/proc/self/cgroup`, ocultando las rutas absolutas del host.
3. Porque en un host sin modificar cada proceso es descendiente del PID 1 (systemd/init) y hereda los namespaces *iniciales*. Nadie llamó todavía a `unshare`/`clone(CLONE_NEW*)`, así que hay exactamente un namespace de cada tipo, cuyo propietario es el PID 1.

### Ejercicio 2

1. Crear un namespace de PID no remonta, por sí solo, `/proc`. `--fork` hace que `unshare` cree un hijo que se convierte en el **PID 1** del nuevo namespace (el primer proceso colocado en un namespace de PID *es* su init); el padre queda afuera. `--mount-proc` también crea un mount namespace y monta un `procfs` nuevo, para que `/proc` refleje el *nuevo* namespace de PID en lugar del del host — de lo contrario `ps` seguiría leyendo el `/proc` del host y mostraría cada proceso.
2. Sos UID 0 **solo dentro del user namespace**. El kernel mapea el UID 0 interno a tu UID externo real (vía `/proc/<pid>/uid_map`, que `--map-root-user` escribe). Tenés capabilities completas *dentro de los recursos que ese namespace posee*, pero ninguna autoridad sobre objetos que pertenecen al host: no podés leer `/etc/shadow`, cargar módulos ni afectar procesos/archivos fuera de los namespaces que poseés. Las verificaciones de `CAP_*` contra recursos del host fallan.
3. Los user namespaces permiten que un usuario sin privilegios obtenga capabilities *dentro* de un nuevo namespace, que es exactamente lo que habilita los **contenedores rootless** (Podman rootless, runc sin privilegios). Pero ese mismo camino de código históricamente permitió que usuarios sin privilegios alcanzaran código del kernel que antes requería root, así que muchas CVE de namespace/escalada de privilegios eran alcanzables solo a través de user namespaces — de ahí que algunas distros restrinjan `unprivileged_userns_clone` / `user.max_user_namespaces`.

### Ejercicio 3

1. `docker exec` encuentra el PID 1 del contenedor, luego llama a `setns(2)` sobre cada uno de los descriptores de archivo de namespace de ese proceso (`/proc/<pid>/ns/*`) — precisamente lo que hace `nsenter` — y ejecuta tu comando dentro de ellos, reaplicando opcionalmente el cgroup, las capabilities y el perfil seccomp del contenedor.
2. Crearías un par `veth`, moverías un extremo al namespace **net** del contenedor, asignarías direcciones a ambos extremos y conectarías el extremo del host a un bridge con NAT/ruteo (Ejercicio 4). El namespace de **red (`net`)** es dueño de la lista de interfaces, la tabla de ruteo y las reglas de firewall.
3. Los ejecutables dentro del contenedor a menudo existen solo en el sistema de archivos raíz del namespace de **mount** del contenedor (su imagen), no en el host. Si entrás con `--pid`/`--net` pero no con `--mount`, `nsenter` sigue viendo el sistema de archivos del host y el binario que solo existe en el contenedor es `No such file or directory`. Unirse a `--mount` (o usar el rootfs del contenedor) es necesario para ejecutar herramientas que están en la imagen.

### Ejercicio 4

1. Un par `veth` es un "cable de parcheo" virtual: dos interfaces donde una trama enviada por una sale por la otra. Poné un extremo en el net namespace del contenedor y el otro en el host (conectado a un bridge), y tenés un enlace punto a punto que cruza la frontera del namespace — la conexión canónica contenedor↔host.
2. Los netns con nombre se mantienen vivos mediante un **bind-mount** del archivo de namespace bajo `/var/run/netns/<name>` (una referencia a archivo sostiene el namespace incluso sin ningún proceso). Los namespaces anónimos de `unshare` existen solo mientras un proceso (o un fd abierto / un bind-mount) los referencie; cuando el último miembro sale, el kernel recolecta el namespace.
3. (a) Una **ruta** para que el gateway por defecto del contenedor sea el host (`ip route add default via 10.10.0.1` dentro del ns) más IP forwarding en el host (`net.ipv4.ip_forward=1`); (b) **source NAT / masquerade** en el host (`iptables/nftables ... MASQUERADE`) para que el `10.10.0.2` privado del contenedor se reescriba a la dirección ruteable del host para el tráfico de retorno. Esa es la esencia de un plugin CNI como bridge+portmap.

### Ejercicio 5

1. La **regla de no-procesos-internos**: un nodo de cgroup v2 que tiene controllers habilitados para sus hijos no puede simultáneamente contener procesos *y* tener cgroups hijos compitiendo por el mismo controller — los cgroups no raíz deben ser o bien una hoja que contiene procesos o bien un nodo interno que distribuye controllers, no ambos. Los controllers se ponen a disposición de los hijos escribiendo `+<ctrl>` en el `cgroup.subtree_control` del **padre**; por eso habilitaste `+memory +cpu` en la raíz, y luego creaste `demo` como una hoja.
2. Un OOM kill acotado a un cgroup apunta solo a los procesos *dentro de ese cgroup* cuando excede `memory.max`, dejando el resto del sistema intacto. Un OOM global se dispara cuando todo el nodo se queda sin memoria y el kernel elige una víctima entre todo. Los límites por cgroup dan un fallo predecible y local al tenant en vez de matar a un vecino al azar — esencial para nodos multi-tenant.
3. **`cpu.weight`** (por defecto 100, rango 1–10000) fija una *cuota proporcional* bajo contención — una garantía relativa a los hermanos — mientras que `cpu.max` fija un *techo* duro. En Kubernetes, un **request** de CPU se mapea a `cpu.weight` (cuota garantizada / scheduling), y un **limit** de CPU se mapea a `cpu.max` (techo de throttling).

### Ejercicio 6

1. **Inheritable (Inh)** — capabilities preservadas a través de `execve` a un programa que también las marca como inheritable; **Permitted (Prm)** — el superconjunto que un proceso *puede* habilitar; **Effective (Eff)** — las capabilities usadas realmente para las verificaciones de permiso *ahora mismo*; **Bounding (Bnd)** — un techo que las capabilities nunca pueden exceder y solo pueden reducir; **Ambient (Amb)** — capabilities preservadas a través de `execve` de binarios no privilegiados (sin file-caps), sujetas a Prm∩Inh.
2. **`CAP_SYS_MODULE`** carga módulos del kernel de la forma más directa; pero el habilitador clásico de escape es **`CAP_SYS_ADMIN`**, apodado "el nuevo root" porque regula un conjunto enorme y mal definido de operaciones (mount, pivot_root, BPF, administración de namespaces/quotas/keyrings, etc.), así que otorgarla entrega efectivamente la mayor parte del poder real de root y es un vector de escape común.
3. El bounding set es un techo duro que el proceso no puede elevar — ni siquiera un binario setuid/con file-capability lanzado vía `execve` puede otorgar una capability ausente de Bnd. Descartar de Bnd por lo tanto hace que la capability sea *permanentemente inalcanzable* para ese proceso y todos sus hijos, que es la propiedad de seguridad duradera; descartar solo de Eff puede reelevarse desde Prm.

### Ejercicio 7

1. **No.** Con `CAP_SYS_ADMIN` la verificación de *capability* para `mount(2)` pasa, pero el filtro **seccomp** rechaza el syscall antes de que se ejecute, devolviendo `EPERM`/matando el thread. Capabilities y seccomp se verifican en puntos distintos: seccomp filtra la *entrada* del syscall por número/argumentos sin importar el privilegio; las capabilities se verifican *dentro* del handler del syscall. Una denegación en cualquiera de las dos compuertas detiene la operación.
2. SELinux impone **Control de Acceso Obligatorio** por etiqueta, independiente del UID. Cada contenedor recibe un par de categorías **MCS** único (p. ej. `s0:c123,c456`); un proceso etiquetado con un conjunto de categorías no puede acceder a archivos etiquetados con un conjunto distinto, así que incluso el root-en-contenedor-A (`c123,c456`) tiene denegado el acceso a los archivos del contenedor-B (`c789,c012`). Las verificaciones DAC de UID son irrelevantes para la decisión MAC.
3. Ejemplos: **seccomp** bloquea alcanzar un syscall vulnerable/oscuro (p. ej. `keyctl`, `userfaultfd`) incluso si el UID y las caps lo permiten. **Capabilities** bloquean una operación privilegiada como abrir un raw socket (`CAP_NET_RAW`) incluso si el syscall está permitido. **MAC (SELinux/AppArmor)** bloquea el acceso a un archivo/ruta/puerto específico por etiqueta/perfil incluso cuando el UID 0 y todas las caps y syscalls están permitidos — p. ej. leer un archivo del host que el tipo del contenedor no tiene permiso de tocar.

### Ejercicio 8

1. La **Image Spec** describe una *imagen de contenedor en reposo*: un manifiesto, un config (env, entrypoint, orden de capas) y blobs de capas direccionados por contenido — el artefacto distribuible y cacheable. La **Runtime Spec** describe un *bundle de sistema de archivos* (`config.json` + `rootfs`) y cómo *correrlo* (namespaces, caps, cgroups, seccomp). El componente entre ambas es el **motor de contenedores** (Docker/Podman/containerd), que desempaqueta las capas de la imagen en un `rootfs` y sintetiza el `config.json`.
2. Porque el bundle es datos puramente declarativos, cualquier runtime que implemente la Runtime Spec puede consumir el mismo `config.json`+`rootfs` y producir el mismo contenedor. Al motor no le importa si `runc` (Go), `crun` (C) o `youki` (Rust) lo aplica — son intercambiables de forma directa, que es el objetivo mismo del estándar.
3. (a) **Deduplicación y transferencia eficiente**: las capas/blobs idénticos comparten el mismo digest, así que se almacenan y descargan una sola vez y se cachean entre imágenes. (b) **Integridad / evidencia de manipulación**: el digest *es* el SHA-256 del contenido, así que cualquier cambio altera el digest — podés verificar que un blob descargado coincide con lo que el manifiesto referencia, habilitando firmado y referencias reproducibles (`@sha256:...`).

### Ejercicio 9

1. Los contenedores ganan en **velocidad de arranque / densidad (bajo overhead)** y **eficiencia de recursos (kernel compartido, sin guest OS)**; las VMs completas ganan en **fortaleza del aislamiento** por **un kernel guest separado y una frontera estrecha de hipervisor/hardware virtual** (vs. el kernel del host compartido del contenedor).
2. Todo contenedor emite syscalls directamente contra el *mismo* kernel del host; un zero-day de syscall del kernel es alcanzable desde dentro de cualquier contenedor cuyo perfil de seccomp/caps no bloquee justamente ese camino — un potencial escape de contenedor. Los guests de VM alcanzan el host solo a través de la interfaz estrecha de hardware virtual del hipervisor, así que un bug del *kernel guest* queda dentro del guest y no toca el kernel del host ni a sus vecinos.
3. Los pasos 1 (`uname -r` idéntico) y 3 (el PID 1 del contenedor es un proceso visible del host) muestran que un contenedor no es una máquina separada: corre sobre el kernel del host y su "init" es un proceso ordinario planificado por el host. Los **namespaces** (junto con cgroups + caps/seccomp/MAC) le dan a ese proceso una *vista restringida y un presupuesto de recursos*, pero sigue siendo un proceso del host — "un proceso con una vista restringida", mientras que una VM arranca su propio kernel detrás de una frontera de hardware y es "una máquina".

</details>

---

### Fuentes

- LPI Exam 305-300 Objectives (v3.0), Topic 352.1 — <https://www.lpi.org/our-certifications/exam-305-objectives/>
- `namespaces(7)`, `cgroups(7)`, `capabilities(7)`, `user_namespaces(7)`, `seccomp(2)`, `unshare(1)`, `nsenter(1)`, `ip-netns(8)` — Linux man-pages project: <https://man7.org/linux/man-pages/>
- Control Group v2 — Linux kernel documentation: <https://docs.kernel.org/admin-guide/cgroup-v2.html>
- OCI Runtime Specification — <https://github.com/opencontainers/runtime-spec/blob/main/spec.md>
- OCI Image Specification — <https://github.com/opencontainers/image-spec/blob/main/spec.md>