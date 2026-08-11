# LPIC-3 305-300 · Tema 352.2: LXC — Ejercicios Guiados

> **Objetivo de examen 352.2 (peso 10).** Los candidatos deben ser capaces de usar contenedores de sistema mediante LXC y LXD. La versión de LXD cubierta es la 3.0 o posterior.
> Áreas de conocimiento clave ejercitadas a continuación: la arquitectura de LXC/LXD y su relación, la gestión de contenedores a partir de imágenes existentes (networking y storage), la configuración de propiedades de contenedores, la limitación del uso de recursos, los perfiles de LXD, las imágenes de LXC y el modelo de id-mapping de `/etc/subuid` · `/etc/subgid`.
> **Términos y utilidades:** `lxd`, `lxc`, `/etc/subuid`, `/etc/subgid`.
> Fuente: LPI, *Exam 305 Objectives*, objetivo 352.2 — https://www.lpi.org/our-certifications/exam-305-objectives/

**Prerrequisitos del laboratorio.** Un único host Linux con un kernel moderno (user namespaces, cgroup v2 y overlay/ZFS disponibles), `sudo`/root, y HTTPS de salida para descargar imágenes. Los ejemplos usan el **snap** de LXD (`sudo snap install lxd`) o un paquete de la distribución. Agregá tu usuario al grupo `lxd` y volvé a iniciar sesión para poder ejecutar `lxc` sin `sudo`:

```bash
sudo usermod -aG lxd "$USER"
newgrp lxd    # or log out/in
```

> **Advertencia de nomenclatura que el examen evalúa.** El cliente con el que manejás LXD se llama `lxc` (sin guion). Las herramientas de espacio de usuario *originales* y de bajo nivel de LXC son los comandos con guion `lxc-*` (`lxc-create`, `lxc-start`, `lxc-ls`…). `lxc list` habla con el daemon de LXD; `lxc-ls` lee `/var/lib/lxc`. Son programas distintos.

---

## Ejercicio 1 — Arquitectura: el daemon, el cliente y liblxc

**Objetivo:** distinguir `lxd` (el daemon) de `lxc` (el cliente) y ubicar a liblxc por debajo de ambos.

1. Confirmá que el daemon está corriendo e inspeccioná el servidor que expone:

   ```bash
   lxc info | head -n 20
   ```

   Esperado (abreviado):

   ```
   config: {}
   api_extensions:
   - storage_zfs_remove_snapshots
   - container_host_shutdown_timeout
   ...
   environment:
     addresses: []
     architectures:
     - x86_64
     - i686
     driver: lxc | qemu
     driver_version: 6.0.0 | ...
     kernel: Linux
     server: lxd
     server_version: "5.21"
   ```

2. Preguntale al cliente hacia dónde apunta — esto es un *remote*, y por defecto es el socket Unix local:

   ```bash
   lxc remote get-default
   lxc remote list
   ```

   Esperado (abreviado):

   ```
   local
   +-----------------+------------------------------------------+---------------+-------------+--------+--------+
   |      NAME       |                   URL                    |   PROTOCOL    |  AUTH TYPE  | PUBLIC | GLOBAL |
   +-----------------+------------------------------------------+---------------+-------------+--------+--------+
   | images          | https://images.linuxcontainers.org      | simplestreams |             | YES    | NO     |
   +-----------------+------------------------------------------+---------------+-------------+--------+--------+
   | local (current) | unix://                                  | lxd           | file access | NO     | NO     |
   +-----------------+------------------------------------------+---------------+-------------+--------+--------+
   ```

3. Mostrá que LXD maneja las mismas primitivas del kernel que LXC puro. Mirá los backends de storage/driver y fijate en el `driver: lxc`:

   ```bash
   lxc info | grep -A1 "driver:"
   ```

4. (Si las herramientas clásicas están instaladas — `apt install lxc` en Debian/Ubuntu) contrastá los dos stacks. Las herramientas de bajo nivel guardan el estado por contenedor como archivos de configuración planos:

   ```bash
   ls /usr/share/lxc/templates/     # download, oci, busybox, local, ...
   sudo lxc-ls --fancy 2>/dev/null  # empty unless you created lxc-* containers
   cat /etc/lxc/default.conf        # default network + idmap for lxc-* tooling
   ```

**Comprensión**

- **1.1** ¿Qué componente es un servicio en segundo plano de larga duración, y cuál es un front end de línea de comandos que también puede hablar con servidores *remotos* sobre HTTPS?
- **1.2** ¿Qué te dice la línea `driver: lxc` sobre la relación entre LXD y el proyecto LXC?
- **1.3** Un colega ejecuta `lxc-ls` y no ve nada, pero `lxc list` muestra cinco contenedores corriendo. Explicá, sin asumir un bug.
- **1.4** Nombrá dos protocolos que aparecen en `lxc remote list` y decí para qué se usa cada remote.

---

## Ejercicio 2 — Imágenes de LXC y remotes

**Objetivo:** entender los remotes de imágenes, los fingerprints y los aliases, y cachear una imagen localmente.

1. Explorá el servidor de imágenes de la comunidad (el remote `images:`) filtrado a una sola distro:

   ```bash
   lxc image list images: ubuntu/22.04 architecture=x86_64
   ```

   Esperado (abreviado):

   ```
   +-----------------------------+--------------+--------+-------------------------------------+--------------+-----------+----------+-------------------------------+
   |            ALIAS            | FINGERPRINT  | PUBLIC |             DESCRIPTION             | ARCHITECTURE |   TYPE    |   SIZE   |          UPLOAD DATE           |
   +-----------------------------+--------------+--------+-------------------------------------+--------------+-----------+----------+-------------------------------+
   | ubuntu/22.04 (3 more)       | 4d3f8e2b9c1a | yes    | Ubuntu jammy amd64 (20260810_07:42) | x86_64       | CONTAINER | 118.24MB | 2026/08/10 07:42 UTC          |
   +-----------------------------+--------------+--------+-------------------------------------+--------------+-----------+----------+-------------------------------+
   ```

2. Lanzá un contenedor desde esa imagen (esto descarga y cachea la imagen, luego crea e inicia una instancia):

   ```bash
   lxc launch images:ubuntu/22.04 web01
   ```

   Esperado:

   ```
   Creating web01
   Starting web01
   ```

3. Mirá lo que se cacheó localmente. La imagen ahora vive en el remote `local:`, indexada por su **fingerprint** (un SHA-256), no por su alias de upstream:

   ```bash
   lxc image list
   lxc image info 4d3f8e2b9c1a | head -n 15
   ```

4. Asigná a la imagen cacheada un alias local estable y demostrá que `launch` puede usarla sin conexión:

   ```bash
   lxc image alias create jammy-base 4d3f8e2b9c1a
   lxc launch local:jammy-base web02
   ```

**Comprensión**

- **2.1** ¿Qué es un *fingerprint* de imagen, y por qué LXD indexa la caché local por él en lugar de por el alias?
- **2.2** Distinguí los remotes `images:`, `ubuntu:` y `local:`.
- **2.3** Después del paso 2, nunca descargaste nada explícitamente con un comando "image import". ¿De dónde vino la imagen y dónde está ahora?
- **2.4** ¿Funcionaría `lxc launch local:jammy-base web03` con la red desconectada? ¿Por qué sí o por qué no?

---

## Ejercicio 3 — Ciclo de vida del contenedor e interacción

**Objetivo:** manejar el ciclo de vida completo y mover datos hacia adentro y hacia afuera sin SSH.

1. Listá, inspeccioná y entrá al contenedor en ejecución:

   ```bash
   lxc list
   lxc info web01 | head -n 20
   lxc exec web01 -- bash
   ```

   Dentro del contenedor ejecutá `cat /etc/os-release && exit`.

2. Ejecutá un comando de una sola vez (sin shell interactiva) y capturá su salida en el host:

   ```bash
   lxc exec web01 -- ps -eo pid,user,comm --no-headers | head
   ```

3. Empujá un archivo hacia adentro y sacá otro hacia afuera (fijate en el direccionamiento `<instance>/<path>`):

   ```bash
   echo "hello from host" > /tmp/msg.txt
   lxc file push /tmp/msg.txt web01/root/msg.txt
   lxc file pull web01/etc/hostname /tmp/web01-hostname
   cat /tmp/web01-hostname
   ```

4. Ejercitá stop/start/restart y un borrado limpio del segundo contenedor:

   ```bash
   lxc stop web02
   lxc list web02
   lxc delete web02            # refuses if running; add --force to stop+delete
   ```

**Comprensión**

- **3.1** `lxc exec web01 -- bash` versus `lxc exec web01 bash` — ¿hay diferencia, y contra qué protege `--`?
- **3.2** En el paso 4, `lxc delete web02` tuvo éxito porque el contenedor estaba detenido. ¿Qué único flag te permitiría borrar un contenedor *en ejecución* en un solo comando?
- **3.3** `lxc file push`/`pull` no necesita ningún daemon SSH en el contenedor. ¿Qué componente realiza realmente la copia?

---

## Ejercicio 4 — Networking: el bridge gestionado y direccionamiento estático

**Objetivo:** entender `lxdbr0`, crear una segunda red gestionada y fijar una IP estática mediante un dispositivo.

1. Inspeccioná el bridge gestionado por defecto al que se conectan las nuevas instancias:

   ```bash
   lxc network list
   lxc network show lxdbr0
   ```

   Esperado (abreviado):

   ```
   config:
     ipv4.address: 10.10.10.1/24
     ipv4.nat: "true"
     ipv6.address: fd42:aaaa:bbbb:cccc::1/64
     ipv6.nat: "true"
   name: lxdbr0
   type: bridge
   managed: true
   used_by:
   - /1.0/instances/web01
   ```

2. Creá un segundo bridge gestionado aislado, solo IPv4, con NAT:

   ```bash
   lxc network create lxdbr1 ipv4.address=10.20.20.1/24 ipv4.nat=true ipv6.address=none
   ```

3. La NIC `eth0` en `web01` viene del **perfil default**, así que no está definida en la instancia. Sobreescribila a nivel de instancia para asignar una dirección fija, luego verificá:

   ```bash
   lxc config device override web01 eth0 ipv4.address=10.10.10.50
   lxc restart web01
   lxc list web01
   ```

   Esperado:

   ```
   +-------+---------+---------------------+------+-----------+-----------+
   | NAME  |  STATE  |        IPV4         | IPV6 |   TYPE    | SNAPSHOTS |
   +-------+---------+---------------------+------+-----------+-----------+
   | web01 | RUNNING | 10.10.10.50 (eth0)  | ...  | CONTAINER | 0         |
   +-------+---------+---------------------+------+-----------+-----------+
   ```

4. Conectá `web01` al segundo bridge como una *segunda* NIC:

   ```bash
   lxc network attach lxdbr1 web01 eth1
   lxc exec web01 -- ip -4 addr show
   ```

**Comprensión**

- **4.1** En el paso 3, ¿por qué se necesitó `lxc config device override` en lugar de `lxc config device set`? ¿Dónde estaba realmente definido el dispositivo `eth0`?
- **4.2** Una `ipv4.address` estática en una NIC solo funciona si el contenedor está en un bridge **gestionado** con un rango DHCP. ¿Por qué LXD requiere el bridge gestionado para que esto surta efecto?
- **4.3** `ipv4.nat=true` en `lxdbr1` — ¿qué configura en el host, y qué se rompería si lo pusieras en `false` sin routing adicional?

---

## Ejercicio 5 — Storage pools y volúmenes

**Objetivo:** entender la abstracción de storage pool y adjuntar un volumen personalizado.

1. Inspeccioná el storage pool por defecto creado por `lxd init`:

   ```bash
   lxc storage list
   lxc storage show default
   ```

   Esperado (abreviado, ejemplo ZFS):

   ```
   config:
     source: default
     zfs.pool_name: default
   driver: zfs
   name: default
   used_by:
   - /1.0/images/4d3f8e2b9c1a
   - /1.0/instances/web01
   ```

2. Creá un segundo pool usando el driver más simple (`dir` — un directorio plano), luego un volumen personalizado en él:

   ```bash
   sudo mkdir -p /srv/lxd-extra
   lxc storage create extra dir source=/srv/lxd-extra
   lxc storage volume create extra shared-data
   ```

3. Adjuntá el volumen personalizado dentro de `web01` en una ruta de montaje, escribí en él y confirmá la persistencia:

   ```bash
   lxc storage volume attach extra shared-data web01 /mnt/shared
   lxc exec web01 -- sh -c 'echo persisted > /mnt/shared/state && cat /mnt/shared/state'
   ```

4. Mostrá que el volumen es independiente del disco raíz de la instancia — el disco raíz es en sí mismo un dispositivo:

   ```bash
   lxc config device show web01
   lxc storage volume list extra
   ```

**Comprensión**

- **5.1** ¿Cuál es la diferencia entre un **pool** de storage y un **volumen** de storage?
- **5.2** El sistema de archivos raíz de un contenedor es un dispositivo `disk` respaldado por un pool. ¿Cuáles son las consecuencias prácticas de borrar el contenedor para su volumen raíz versus para el volumen personalizado `shared-data`?
- **5.3** Dá una razón operativa para preferir `zfs`/`btrfs` sobre el driver `dir` para el pool por defecto.

---

## Ejercicio 6 — Propiedades del contenedor y límites de recursos (cgroups)

**Objetivo:** configurar propiedades de instancia y limitar CPU/memoria mediante cgroups.

1. Leé la configuración completa de un contenedor, con los perfiles expandidos:

   ```bash
   lxc config show web01              # instance-only keys
   lxc config show web01 --expanded   # profiles merged in
   ```

2. Aplicá límites de recursos duros y establecé una propiedad de autostart:

   ```bash
   lxc config set web01 limits.cpu 2
   lxc config set web01 limits.memory 512MB
   lxc config set web01 limits.memory.enforce hard
   lxc config set web01 boot.autostart true
   ```

3. Aplicá los límites (los cambios de memoria pueden necesitar un reinicio) y verificá desde *dentro* del contenedor:

   ```bash
   lxc restart web01
   lxc exec web01 -- nproc
   lxc exec web01 -- sh -c 'cat /sys/fs/cgroup/memory.max 2>/dev/null || cat /sys/fs/cgroup/memory/memory.limit_in_bytes'
   ```

   Esperado:

   ```
   2
   536870912
   ```

4. Cambiá de fijar CPUs enteras a un allowance basado en tiempo y observá la diferencia:

   ```bash
   lxc config unset web01 limits.cpu
   lxc config set web01 limits.cpu.allowance 50%
   lxc config get web01 limits.cpu.allowance
   ```

**Comprensión**

- **6.1** `limits.cpu 2` versus `limits.cpu.allowance 50%` — ¿qué hace cada uno, y cuál sigue exponiendo todas las CPUs del host al scheduler del contenedor?
- **6.2** Con `limits.memory.enforce hard`, ¿qué le pasa a un proceso dentro del contenedor que excede `limits.memory`? ¿Qué cambia con `soft`?
- **6.3** En el paso 3 leíste `/sys/fs/cgroup/memory.max` **desde dentro** del contenedor y viste el límite. ¿Qué subsistema del kernel hace que el contenedor vea sus propios límites de cgroup en lugar de la RAM total del host?
- **6.4** ¿Cuál de las claves que estableciste sobrevive a un stop/start completo del contenedor, y dónde se almacena ese estado?

---

## Ejercicio 7 — Perfiles de LXD

**Objetivo:** tratar la configuración como perfiles reutilizables y componibles.

1. Leé el perfil `default` — la fuente de los dispositivos `eth0` y `root` de cada instancia:

   ```bash
   lxc profile show default
   ```

2. Creá un perfil "small" reutilizable que lleve solo límites (sin dispositivos):

   ```bash
   lxc profile create small
   lxc profile set small limits.cpu 1
   lxc profile set small limits.memory 256MB
   lxc profile show small
   ```

3. Componé perfiles sobre una instancia. `add` agrega; `assign` reemplaza toda la lista ordenada:

   ```bash
   lxc profile add web01 small           # web01 now: default, small
   lxc config show web01 --expanded | grep -A3 limits
   lxc profile assign web01 default,small
   ```

4. Lanzá un contenedor nuevo directamente con un stack de perfiles:

   ```bash
   lxc launch images:alpine/3.19 edge01 -p default -p small
   lxc config show edge01 --expanded | grep -E 'limits.(cpu|memory)'
   ```

**Comprensión**

- **7.1** Los perfiles se aplican como una lista ordenada y se fusionan. Si `default` establece `limits.memory 1GB` y `small` (aplicado después) establece `256MB`, ¿cuál es el límite efectivo y por qué?
- **7.2** ¿Cuál es el riesgo práctico de ejecutar `lxc profile assign web01 small` (nota: **no** `default,small`) en un contenedor que depende de `default` para su NIC y disco raíz?
- **7.3** Estableciste `limits.cpu 2` directamente en `web01` en el Ejercicio 6 *y* además hereda el `limits.cpu 1` de `small`. ¿Cuál gana, una clave a nivel de instancia o una clave de perfil?

---

## Ejercicio 8 — Contenedores no privilegiados, `/etc/subuid` y `/etc/subgid`

**Objetivo:** entender el mapeo de IDs del user namespace que hace que los contenedores de LXD sean no privilegiados por defecto, y cómo los archivos de IDs subordinados lo alimentan.

1. Inspeccioná los rangos de IDs subordinados que el daemon de LXD (corriendo como `root`) tiene permitido repartir:

   ```bash
   cat /etc/subuid
   cat /etc/subgid
   ```

   Esperado (default típico de LXD):

   ```
   root:1000000:1000000000
   ubuntu:100000:65536
   ```

   Leé la línea `root:` como: *el usuario `root` puede mapear IDs subordinados empezando en el UID de host `1000000`, para `1000000000` IDs consecutivos.*

2. Confirmá que un contenedor es no privilegiado (el default) y encontrá su PID del lado del host:

   ```bash
   lxc config get web01 security.privileged     # empty/false => unprivileged
   PID=$(lxc info web01 | awk '/Pid:/ {print $2}')
   echo "$PID"
   ```

3. Demostrá el mapeo: **root (UID 0) dentro** del contenedor corre como un **UID alto no privilegiado en el host**:

   ```bash
   ps -o pid,user,uid,comm -p "$PID"
   ```

   Esperado (uid mapeado dentro del rango subordinado):

   ```
     PID    USER     UID  COMMAND
   28412 1000000 1000000  systemd
   ```

4. Contrastá con un contenedor privilegiado (root-adentro equivale a root-en-el-host — evitalo en producción):

   ```bash
   lxc launch images:alpine/3.19 priv01 -c security.privileged=true
   PPID=$(lxc info priv01 | awk '/Pid:/ {print $2}')
   ps -o pid,user,uid,comm -p "$PPID"      # USER root, UID 0
   lxc delete --force priv01
   ```

**Comprensión**

- **8.1** En `/etc/subuid`, decodificá `root:1000000:1000000000` campo por campo.
- **8.2** ¿Por qué el daemon de LXD consulta específicamente la línea **`root`**, en lugar de la línea de tu usuario de login?
- **8.3** En el paso 3, el UID 0 del contenedor apareció como el UID de host 1000000. Si un proceso escapara del contenedor como "root", ¿qué privilegios de host tendría realmente, y por qué ese es el beneficio de seguridad central de los contenedores no privilegiados?
- **8.4** ¿Qué cambia `security.privileged=true` respecto del mapeo de IDs, y nombrá una razón por la que aún podrías (a regañadientes) necesitarlo.
- **8.5** Si `/etc/subuid`/`/etc/subgid` estuvieran vacíos o el rango de `root` fuera demasiado pequeño, ¿qué pasaría cuando intentás iniciar un contenedor no privilegiado?

---

## Ejercicio 9 — Snapshots y publicación de una imagen golden

**Objetivo:** capturar estado, hacer rollback y convertir un contenedor conocido-bueno en una imagen reutilizable — cerrando el círculo de vuelta al Ejercicio 2.

1. Tomá un snapshot de un contenedor limpio, luego hacé un cambio destructivo:

   ```bash
   lxc snapshot web01 clean-base
   lxc info web01 | sed -n '/Snapshots:/,$p'
   lxc exec web01 -- rm -rf /etc/nginx        # simulate breakage
   ```

2. Hacé rollback y confirmá la restauración:

   ```bash
   lxc restore web01 clean-base
   lxc exec web01 -- ls -d /etc/nginx 2>/dev/null && echo "restored"
   ```

3. Publicá el snapshot como una imagen local con un alias (el contenedor debe estar detenido para publicar, o publicá el snapshot directamente):

   ```bash
   lxc publish web01/clean-base --alias web-gold
   lxc image list web-gold
   ```

4. Lanzá un contenedor completamente nuevo desde tu imagen golden — sin descarga de upstream:

   ```bash
   lxc launch local:web-gold web03
   lxc list web03
   ```

**Comprensión**

- **9.1** ¿Cuál es la diferencia entre un **snapshot** y una **imagen publicada**? ¿Cuándo recurrirías a cada uno?
- **9.2** `lxc restore web01 clean-base` — ¿es reversible? ¿Qué pasa con los cambios hechos después de que se tomó el snapshot?
- **9.3** Después de publicar, `web-gold` aparece en `lxc image list` con su propio fingerprint. Relacioná esto con el Ejercicio 2: ¿a qué remote resuelve `local:web-gold`, y por qué puede `web03` lanzarse sin acceso a la red?

---

<details>
<summary><strong>Clave de respuestas (todos los ejercicios)</strong></summary>

### Ejercicio 1 — Arquitectura

- **1.1** `lxd` es el daemon de larga duración (el servidor de API REST que posee las instancias, imágenes, storage y redes). `lxc` es el **cliente** de línea de comandos; habla el protocolo REST de LXD ya sea con el socket Unix local o, sobre HTTPS, con servidores LXD remotos.
- **1.2** `driver: lxc` significa que el daemon de LXD usa **liblxc** (la librería C del proyecto LXC) para efectivamente crear y ejecutar contenedores de sistema. LXD es una **capa de gestión** (API, imágenes, clustering, abstracciones de storage/red) construida *sobre* LXC; LXC provee el runtime de contenedores de bajo nivel. Ese es el núcleo de "la relación entre LXC y LXD".
- **1.3** No es un bug. `lxc-ls` es la herramienta clásica de **LXC** y lee `/var/lib/lxc`; `lxc list` es el cliente de **LXD** y lista las instancias que posee el daemon de LXD. Los cinco contenedores fueron creados a través de LXD, así que son invisibles para las herramientas `lxc-*`. Los dos stacks mantienen estado separado.
- **1.4** `simplestreams` — usado por servidores públicos de **imágenes** (p. ej. `images:`) para anunciar las imágenes disponibles. `lxd` (con `unix://` para el socket local, o una URL HTTPS para un remote) — usado para gestionar instancias/storage/redes en un servidor LXD. `local` es el remote por defecto actual que apunta al daemon local.

### Ejercicio 2 — Imágenes

- **2.1** Un fingerprint es el **hash SHA-256 del contenido de la imagen**. Indexar la caché por él hace que el almacenamiento sea direccionable por contenido y deduplicado: contenidos de imagen idénticos mapean a un único objeto cacheado sin importar qué alias apunten a él, y la integridad es verificable.
- **2.2** `images:` → el servidor de imágenes de la comunidad LinuxContainers (muchas distros/versiones). `ubuntu:` → las imágenes cloud oficiales de release de Ubuntu de Canonical. `local:` → imágenes cacheadas en *tu* daemon de LXD. (En despliegues reales notá que el LXD de Canonical y el fork de la comunidad **Incus** ahora usan servidores de imágenes por defecto distintos; el examen es anterior a esa división y trata `images:` como el servidor de la comunidad.)
- **2.3** `lxc launch` descargó la imagen del remote `images:` bajo demanda, la guardó en la **caché local de imágenes** (visible vía `lxc image list`), luego creó e inició la instancia a partir de ella. Launch = descargar-si-hace-falta + init + start.
- **2.4** Sí. `local:jammy-base` resuelve a la imagen local ya cacheada, así que no se requiere ninguna descarga de upstream. Solo un *cache miss* (un alias/fingerprint no presente localmente) necesita la red.

### Ejercicio 3 — Ciclo de vida

- **3.1** Funcionalmente similares acá, pero `--` marca el fin de las opciones propias de `lxc`: todo lo que le sigue se pasa textualmente al comando dentro del contenedor. Protege contra un comando del contenedor cuyos argumentos (p. ej. `-e`, `--config`) de otro modo serían parseados por el propio `lxc`.
- **3.2** `lxc delete --force web02` detiene el contenedor en ejecución y lo borra en un solo paso.
- **3.3** El **daemon de LXD** realiza la copia a través de su API (el cliente `lxc` transmite el archivo por la conexión socket/REST de LXD); lee/escribe el sistema de archivos del contenedor directamente. No se requiere ningún SSH ni agente dentro del contenedor.

### Ejercicio 4 — Networking

- **4.1** `eth0` **no estaba definido en la instancia** — se heredó del perfil `default`. `lxc config device set` edita un dispositivo *a nivel de instancia* existente, que todavía no existía. `lxc config device override` **copia** el dispositivo provisto por el perfil sobre la instancia y luego aplica el cambio, así que la instancia ahora posee un dispositivo `eth0` que eclipsa al del perfil.
- **4.2** Un bridge gestionado es uno que LXD controla, incluyendo su rango **dnsmasq/DHCP** integrado. Una dirección estática de NIC se impone fijando el lease DHCP/entrada DNS para esa instancia; en un bridge no gestionado LXD no tiene servidor DHCP que fijar, así que la clave `ipv4.address` no tiene sobre qué actuar.
- **4.3** `ipv4.nat=true` hace que LXD instale una **regla de firewall source-NAT (masquerade)** en el host para que el tráfico del contenedor salga usando la IP del host. Con `false` y sin routing manual, los contenedores en `10.20.20.0/24` podrían alcanzar el host pero su camino de vuelta desde el mundo exterior quedaría sin rutear, así que la conectividad externa se rompería a menos que agregues rutas/NAT vos mismo.

### Ejercicio 5 — Storage

- **5.1** Un **pool** es el almacenamiento de respaldo (un zpool de ZFS, un sistema de archivos btrfs, un VG de LVM, o un directorio plano) con un driver; un **volumen** es una asignación *dentro* de un pool (un disco raíz de instancia, una imagen, o un volumen de datos personalizado). Los pools son la capacidad; los volúmenes son las porciones.
- **5.2** Borrar el contenedor borra su volumen **raíz** (su sistema de archivos desaparece). El volumen **personalizado** `shared-data` es un objeto independiente en el pool y **sobrevive**; puede re-adjuntarse a otra instancia. Esa independencia es exactamente por qué se usan los volúmenes personalizados para datos que deben sobrevivir a una instancia.
- **5.3** `zfs`/`btrfs` proveen copy-on-write, así que la creación imagen→instancia y los **snapshots** son casi instantáneos y eficientes en espacio (y habilitan `lxc copy`/`restore` rápidos); `dir` copia bytes y guarda los snapshots como copias completas, lo cual es más lento y más grande.

### Ejercicio 6 — Límites

- **6.1** `limits.cpu 2` **fija** el contenedor a 2 núcleos de CPU (afinidad de CPU-set). `limits.cpu.allowance 50%` deja todas las CPUs del host visibles al scheduler pero limita el **tiempo** total de CPU al 50% vía cuota de CPU de cgroup. El allowance sigue exponiendo todas las CPUs del host; el pinning restringe qué núcleos son utilizables.
- **6.2** `hard`: exceder `limits.memory` dispara el controlador de memoria de cgroup — las asignaciones fallan y el **OOM killer** dentro del contenedor mata procesos; el contenedor no puede exceder el tope. `soft`: el valor se convierte en un objetivo *soft* de recuperación — bajo presión de memoria del host el contenedor es empujado de vuelta hacia él, pero puede exceder temporalmente el límite cuando hay memoria libre.
- **6.3** Los **cgroups** (v2) proveen los valores de contabilidad/límite, y LXD (vía **lxcfs**) superpone una vista por contenedor de `/proc` y `/sys/fs/cgroup` para que las herramientas dentro del contenedor vean su propio límite (`memory.max`) y conteos de CPU en lugar de los totales del host.
- **6.4** Todas las claves `limits.*` y `boot.autostart` son **configuración persistente de instancia** almacenada en la base de datos de LXD (parte de `lxc config show web01`); sobreviven a stop/start y a reinicios del daemon. Solo el estado vivo de cgroup es transitorio y se re-aplica al iniciar.

### Ejercicio 7 — Perfiles

- **7.1** El límite efectivo es **256MB**. Los perfiles se fusionan en el orden de la lista y **los perfiles posteriores sobreescriben a los anteriores** para la misma clave; `small` se aplica después de `default`, así que su valor gana.
- **7.2** `assign small` **reemplaza toda la lista de perfiles**, descartando `default`. El contenedor perdería la NIC `eth0` y el disco `root` que `default` proveía — dejándolo sin red y, críticamente, **sin dispositivo de sistema de archivos raíz**, así que no lograría iniciar. Usá `assign default,small` (o `profile add`) para conservar `default`.
- **7.3** La clave a **nivel de instancia** gana. La precedencia es: perfiles fusionados en orden, luego **la configuración de instancia sobreescribe a todos los perfiles**. Así que el `limits.cpu 2` establecido directamente en `web01` le gana al `limits.cpu 1` de `small`.

### Ejercicio 8 — Contenedores no privilegiados y `/etc/subuid`/`/etc/subgid`

- **8.1** `root:1000000:1000000000` = `<owner>:<start>:<count>`. Al usuario **`root`** se le permite usar IDs subordinados que empiezan en el UID de host **1000000**, para **1000000000** IDs consecutivos (UIDs de host 1000000 … 1000999999).
- **8.2** El **daemon de LXD corre como `root`**, así que cuando arma el user namespace toma de los rangos subordinados de `root`. La línea `/etc/subuid` de tu usuario de login importa solo para el tooling de contenedores *rootless*/propiedad del usuario, no para el LXD de sistema.
- **8.3** Tendría solo los privilegios de un **UID de host no privilegiado ordinario (1000000)** — no posee archivos del host, no puede actuar sobre recursos del host que no le pertenecen, y no tiene ningún `CAP_*` del host fuera de su namespace. Como el "root" del contenedor (UID 0) está mapeado a un UID de host no privilegiado vía user namespaces, un escape del contenedor **no** otorga root del host. Ese mapeo es el beneficio de seguridad central.
- **8.4** `security.privileged=true` **deshabilita el remapeo de UID/GID**: el UID 0 del contenedor equivale al UID 0 del host (root real). Aún podrías necesitarlo para cargas de trabajo que genuinamente requieren privilegios a nivel de host u operaciones no soportadas (ciertos casos anidados/de hardware o legacy) — aceptando el radio de impacto mucho mayor de un escape.
- **8.5** El inicio **fallaría**: sin un rango subordinado de `root` utilizable LXD no puede asignar el mapa de IDs para el user namespace, así que no puede crear el contenedor no privilegiado. (LXD necesita un rango lo bastante grande — típicamente 65536+ — para mapear los uids/gids del contenedor.)

### Ejercicio 9 — Snapshots y publicación

- **9.1** Un **snapshot** es una copia en un punto del tiempo de un *único* contenedor (estado + sistema de archivos) usada para el rollback de esa misma instancia. Una **imagen publicada** es una imagen reutilizable, direccionada por contenido (con un fingerprint/alias) a partir de la cual podés crear *muchos contenedores nuevos* o compartir/exportar. Snapshot = restaurar este; imagen = plantilla para nuevos.
- **9.2** `restore` **no es reversible automáticamente**: cualquier cambio hecho *después* del snapshot se descarta cuando hacés rollback. Para conservar el estado actual antes de restaurar, tomá primero un snapshot nuevo (o LXD puede configurarse para auto-snapshot en un restore con estado).
- **9.3** `local:web-gold` resuelve al **remote `local:`** — la caché de imágenes de tu propio daemon (el mismo almacén que se llenó en el Ejercicio 2). Como la imagen ya existe localmente con su propio fingerprint, `web03` se crea desde la caché **sin descarga de upstream**, de ahí que no se necesite red.

</details>

---

### Referencias (fuentes oficiales)

- LPI — *Exam 305 Objectives* (objetivo 352.2): https://www.lpi.org/our-certifications/exam-305-objectives/
- Canonical — *LXD documentation* (instancias, perfiles, storage, networking, seguridad/idmaps): https://documentation.ubuntu.com/lxd/
- LinuxContainers — *LXC documentation* (liblxc, herramientas `lxc-*`, templates): https://linuxcontainers.org/lxc/documentation/
- LinuxContainers — *Incus* (fork de la comunidad de LXD; relevante para despliegues actuales): https://linuxcontainers.org/incus/docs/main/
- páginas man: `lxc(1)` (cliente de LXD), `lxd(1)`, `subuid(5)`, `subgid(5)`, `lxc.container.conf(5)`