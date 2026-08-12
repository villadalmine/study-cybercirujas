# 363.2 Clústeres de Almacenamiento Ceph — Ejercicios Guiados

Estos ejercicios te guían en la construcción, operación y diagnóstico de un clúster Ceph pequeño pero representativo de producción con `cephadm` (el orquestador basado en contenedores usado por Ceph Octopus y posteriores). Ejecutá los pasos numerados en orden. Después de cada bloque, respondé las preguntas de verificación; la clave de respuestas completa está colapsada al final.

## Entorno de laboratorio

Necesitás **tres nodos** ejecutando una distribución reciente (RHEL/Rocky 9, Ubuntu 22.04, o similar), cada uno con:

- `podman` (o `docker`), `python3`, `systemd`, sincronización de tiempo `chrony`/`ntpd`, y `sudo` sin contraseña.
- Un disco de SO **más al menos un disco de datos en blanco, sin particionar** (`/dev/vdb`) que Ceph pueda consumir.
- Nombres de host `ceph-node1`, `ceph-node2`, `ceph-node3` resolubles por todos los pares; IPs de gestión `192.168.10.11/12/13`.
- `cephadm` instalado en `ceph-node1` (`curl -fsSL https://download.ceph.com/rpm-18.2.4/el9/noarch/cephadm -o /usr/sbin/cephadm && chmod +x /usr/sbin/cephadm`, o el paquete de tu distribución).

> Todos los comandos `ceph`/`rbd`/`rados` de abajo se ejecutan desde `ceph-node1`. Con cephadm entrás al contenedor shell (`cephadm shell`) o instalás los paquetes de cliente para que los binarios existan en el host. Cada comando asume root o `sudo`.

---

## Ejercicio 1 — Arrancar el clúster y leer su estado

1. Arrancá el primer monitor y manager en `ceph-node1`:
   ```bash
   cephadm bootstrap --mon-ip 192.168.10.11
   ```
   Anotá la URL del dashboard, la contraseña generada de `client.admin`, y la línea que informa dónde se escribieron `ceph.conf` y el keyring de admin (`/etc/ceph/`).

2. Entrá al contenedor de herramientas (o usá los clientes instalados en el host) y leé el estado general:
   ```bash
   cephadm shell -- ceph -s
   ```
   Esperado (abreviado):
   ```
     cluster:
       id:     b7f8a6d2-1c3e-11ee-9c4a-000c29a1b2c3
       health: HEALTH_WARN
               OSD count 0 < osd_pool_default_size 3

     services:
       mon: 1 daemons, quorum ceph-node1 (age 3m)
       mgr: ceph-node1.abcdef(active, since 2m)
       osd: 0 osds: 0 up, 0 in

     data:
       pools:   0 pools, 0 pgs
       objects: 0 objects, 0 B
       usage:   0 B used, 0 B / 0 B avail
       pgs:
   ```

3. Obtené la *razón* detrás de la advertencia y listá los daemons en ejecución que gestiona el orquestador:
   ```bash
   ceph health detail
   ceph orch ls
   ceph orch ps
   ceph orch host ls
   ```

**Preguntas**
- Q1.1 — ¿Qué daemons centrales de Ceph están corriendo inmediatamente después de `bootstrap`, y qué tipo de daemon esencial sigue completamente ausente?
- Q1.2 — ¿Por qué el clúster está en `HEALTH_WARN` en lugar de `HEALTH_ERR` en este punto?
- Q1.3 — ¿Cuál es la diferencia funcional entre `ceph orch ls` y `ceph orch ps`?
- Q1.4 — ¿Dónde coloca `cephadm bootstrap` el keyring de admin y el archivo de configuración en el host, y qué identidad cephx contiene ese keyring?

---

## Ejercicio 2 — Agregar hosts y aprovisionar OSDs

1. Distribuí la clave pública SSH del clúster generada por cephadm a los otros dos nodos, luego registralos:
   ```bash
   ceph cephadm get-pub-key > /tmp/ceph.pub
   ssh-copy-id -f -i /tmp/ceph.pub root@ceph-node2
   ssh-copy-id -f -i /tmp/ceph.pub root@ceph-node3

   ceph orch host add ceph-node2 192.168.10.12
   ceph orch host add ceph-node3 192.168.10.13
   ceph orch host ls
   ```

2. Inspeccioná qué dispositivos de bloque considera disponibles el orquestador:
   ```bash
   ceph orch device ls
   ```
   Un dispositivo solo se ofrece cuando está sin particionar, no tiene sistema de archivos, y no es ya un OSD (`AVAILABLE = Yes`).

3. Creá OSDs. O bien apuntás a un dispositivo explícitamente o dejás que cephadm consuma cada disco libre:
   ```bash
   # Explicit:
   ceph orch daemon add osd ceph-node1:/dev/vdb

   # Or declarative, cluster-wide:
   ceph orch apply osd --all-available-devices
   ```

4. Confirmá que los OSDs se unieron a la jerarquía CRUSH y que el clúster está sano:
   ```bash
   ceph osd tree
   ceph -s
   ```
   Esperado `ceph osd tree`:
   ```
   ID  CLASS  WEIGHT   TYPE NAME            STATUS  REWEIGHT  PRI-AFF
   -1         0.29279  root default
   -3         0.09760      host ceph-node1
    0    hdd  0.09760          osd.0            up   1.00000  1.00000
   -5         0.09760      host ceph-node2
    1    hdd  0.09760          osd.1            up   1.00000  1.00000
   -7         0.09760      host ceph-node3
    2    hdd  0.09760          osd.2            up   1.00000  1.00000
   ```

**Preguntas**
- Q2.1 — ¿Qué tres condiciones debe cumplir un disco antes de que `ceph orch device ls` lo marque como `AVAILABLE`?
- Q2.2 — ¿Qué backend de almacenamiento en disco usa por defecto un OSD moderno de cephadm, y qué herramienta prepara realmente el disco (layout LVM, clave, metadatos)?
- Q2.3 — En `ceph osd tree`, ¿qué significan las columnas `STATUS` (`up`/`down`) y `REWEIGHT`, y en qué se diferencian de que un OSD esté `in`/`out`?
- Q2.4 — ¿Qué implica la diferencia entre `ceph orch daemon add osd` y `ceph orch apply osd` para los discos futuros insertados en un host?

---

## Ejercicio 3 — Quórum de monitores, managers, y el mapa CRUSH

1. Ampliá el quórum de monitores y managers a tres para que el plano de control tolere la pérdida de un nodo:
   ```bash
   ceph orch apply mon 3
   ceph orch apply mgr 3
   ceph mon stat
   ceph mon dump
   ```
   Esperado `ceph mon stat`:
   ```
   e3: 3 mons at {ceph-node1=[v2:192.168.10.11:3300/0,v1:192.168.10.11:6789/0],
   ceph-node2=[...],ceph-node3=[...]}, election epoch 12, leader 0 ceph-node1,
   quorum 0,1,2 ceph-node1,ceph-node2,ceph-node3
   ```

2. Listá e inspeccioná los módulos del manager (el dashboard, el autoscaler y las alertas viven todos acá):
   ```bash
   ceph mgr module ls
   ceph mgr services
   ```

3. Leé la topología CRUSH y exportá el mapa compilado para edición offline:
   ```bash
   ceph osd crush tree
   ceph osd crush rule ls
   ceph osd crush rule dump replicated_rule

   ceph osd getcrushmap -o /tmp/crush.bin
   crushtool -d /tmp/crush.bin -o /tmp/crush.txt
   sed -n '/^rule replicated_rule/,/^}/p' /tmp/crush.txt
   ```
   Deberías ver una regla cuyo `step chooseleaf firstn 0 type host` distribuye las réplicas entre **hosts**.

**Preguntas**
- Q3.1 — Con tres monitores, ¿cuántos deben estar accesibles para formar quórum, y por qué se desaconseja un número par de monitores?
- Q3.2 — ¿Qué algoritmo de consenso/replicación mantiene consistente el mapa del clúster de los monitores?
- Q3.3 — En la `replicated_rule` por defecto, ¿qué garantiza `step chooseleaf firstn 0 type host` sobre dónde aterrizan las réplicas de un objeto, y qué cambiaría si `type` fuera `osd`?
- Q3.4 — ¿Por qué Ceph documenta CRUSH como un algoritmo en lugar de una tabla de búsqueda — qué evita contactar un cliente al localizar un objeto?

---

## Ejercicio 4 — Pools y placement groups

1. Creá un pool replicado e inspeccioná sus parámetros:
   ```bash
   ceph osd pool create appdata 64 64 replicated
   ceph osd pool get appdata size
   ceph osd pool get appdata min_size
   ceph osd pool get appdata pg_num
   ```

2. Ajustá la redundancia y observá el efecto sobre la semántica de disponibilidad:
   ```bash
   ceph osd pool set appdata size 3
   ceph osd pool set appdata min_size 2
   ```

3. Mirá cómo el PG autoscaler dimensiona los pools, luego leé la capacidad por pool:
   ```bash
   ceph osd pool autoscale-status
   ceph df
   ceph pg stat
   ```
   Esperado `ceph df` (abreviado):
   ```
   --- RAW STORAGE ---
   CLASS    SIZE    AVAIL    USED  RAW USED  %RAW USED
   hdd    300 GiB  297 GiB  3 GiB     3 GiB       1.00
   TOTAL  300 GiB  297 GiB  3 GiB     3 GiB       1.00

   --- POOLS ---
   POOL      ID  PGS  STORED  OBJECTS  USED   %USED  MAX AVAIL
   appdata    2   64     0 B        0    0 B      0     94 GiB
   ```

4. Creá un pool con codificación de borrado (erasure-coded) y compará su costo de espacio bruto con la replicación:
   ```bash
   ceph osd erasure-code-profile get default        # k=2, m=1 in a fresh cluster
   ceph osd pool create ecpool erasure default
   ceph osd pool get ecpool erasure_code_profile
   ```

**Preguntas**
- Q4.1 — ¿Qué es un Placement Group, y por qué Ceph fragmenta un pool en muchos PGs en lugar de mapear cada objeto directamente a los OSDs?
- Q4.2 — Con `size 3` y `min_size 2`, ¿cuántas réplicas pueden perderse mientras el pool sigue aceptando escrituras, y qué pasa una vez que la disponibilidad cae por debajo de `min_size`?
- Q4.3 — Para el perfil de erasure `k=2, m=1`, ¿cuál es la relación utilizable-a-bruto, y cuántos fallos de OSD puede sobrevivir un PG?
- Q4.4 — ¿Qué ajusta automáticamente el PG autoscaler, y qué propiedad del pool le indica que un pool contendrá la mayor parte de los datos?

---

## Ejercicio 5 — Autenticación cephx y capacidades

1. Listá las identidades existentes y sus capacidades:
   ```bash
   ceph auth ls
   ceph auth get client.admin
   ```

2. Creá un cliente de mínimo privilegio restringido a un solo pool y exportá su keyring:
   ```bash
   ceph auth get-or-create client.app \
     mon 'allow r' \
     osd 'allow rwx pool=appdata' \
     -o /etc/ceph/ceph.client.app.keyring
   cat /etc/ceph/ceph.client.app.keyring
   ```
   Esperado:
   ```
   [client.app]
       key = AQDb1n1mF3k8AhAA9v6c0Xq2R6b3Yk1pQd0Zpg==
       caps mon = "allow r"
       caps osd = "allow rwx pool=appdata"
   ```

3. Probá que la restricción funciona, luego revocá:
   ```bash
   ceph --id app --keyring /etc/ceph/ceph.client.app.keyring -p appdata ls   # allowed
   ceph --id app --keyring /etc/ceph/ceph.client.app.keyring -s              # limited/denied
   ceph auth rm client.app
   ```

**Preguntas**
- Q5.1 — ¿Qué autentica y contra qué protege cephx — está cifrando los datos en el cable, la identidad del cliente, o ambos?
- Q5.2 — Decodificá la capacidad `osd 'allow rwx pool=appdata'`: ¿qué puede hacer `client.app`, y contra qué datos de OSD?
- Q5.3 — ¿Por qué cada daemon y cliente debe tener una clave, y qué hace especial a `client.admin`?
- Q5.4 — ¿Cuál es la diferencia práctica entre una capacidad `allow rwx pool=...` en crudo y una capacidad `profile rbd`?

---

## Ejercicio 6 — RADOS Block Device (RBD)

1. Creá e inicializá un pool dedicado a RBD, luego creá una imagen thin-provisioned:
   ```bash
   ceph osd pool create rbdpool 32 32 replicated
   rbd pool init rbdpool
   rbd create --size 1024 rbdpool/disk01
   rbd ls rbdpool
   rbd info rbdpool/disk01
   ```
   Esperado `rbd info`:
   ```
   rbd image 'disk01':
       size 1 GiB in 256 objects
       order 22 (4 MiB objects)
       snapshot_count: 0
       id: 12b3c4d5e6f7
       block_name_prefix: rbd_data.12b3c4d5e6f7
       format: 2
       features: layering, exclusive-lock, object-map, fast-diff, deep-flatten
       create_timestamp: ...
   ```

2. Mapeá la imagen vía el driver del kernel, ponele un sistema de archivos y montala:
   ```bash
   rbd device map rbdpool/disk01          # -> /dev/rbd0
   mkfs.xfs /dev/rbd0
   mkdir -p /mnt/rbd && mount /dev/rbd0 /mnt/rbd
   echo "hello ceph" > /mnt/rbd/test.txt
   rbd device list
   ```

3. Tomá un snapshot, clonalo, y confirmá el layering copy-on-write:
   ```bash
   rbd snap create rbdpool/disk01@base
   rbd snap protect rbdpool/disk01@base
   rbd clone rbdpool/disk01@base rbdpool/clone01
   rbd children rbdpool/disk01@base
   rbd info rbdpool/clone01 | grep parent
   ```

**Preguntas**
- Q6.1 — ¿Cómo se almacena físicamente una imagen RBD de 1 GiB en RADOS — como un objeto o muchos, y qué significa `order 22`?
- Q6.2 — ¿Qué significa "thin-provisioned" acá: `rbd create --size 1024` consume inmediatamente 1 GiB de espacio del clúster?
- Q6.3 — ¿Cuál es la diferencia entre mapear una imagen con el driver `rbd` del kernel y consumirla a través de `librbd` (por ejemplo desde QEMU/KVM)?
- Q6.4 — ¿Por qué un snapshot debe ser `protect`-ed antes de que pueda clonarse, y qué significa copy-on-write para el uso de espacio inicial del clon?

---

## Ejercicio 7 — CephFS, más diagnóstico en vivo y recuperación

1. Creá un volumen CephFS (esto crea pools de datos + metadatos y despliega un MDS), luego montalo:
   ```bash
   ceph fs volume create shared
   ceph fs ls
   ceph fs status shared
   ceph orch ps --daemon-type mds

   # Kernel mount using the admin secret:
   mkdir -p /mnt/cephfs
   mount -t ceph :/ /mnt/cephfs -o name=admin,secret=$(ceph auth get-key client.admin)
   df -h /mnt/cephfs
   ```

2. Observá los eventos del clúster y la utilización por OSD mientras el clúster trabaja:
   ```bash
   ceph -w &          # streaming event log; Ctrl-C / kill when done
   ceph osd df
   ceph osd perf
   ```

3. Ejercitá E/S de objetos directamente contra RADOS (evitando RBD/CephFS) y leé las estadísticas del pool:
   ```bash
   rados -p appdata put greeting /etc/hostname
   rados -p appdata ls
   rados -p appdata stat greeting
   rados df
   ```

4. Cambiá la configuración de runtime de forma centralizada y confirmala, luego dispará comprobaciones de integridad:
   ```bash
   ceph config set osd osd_max_backfills 4
   ceph config get osd osd_max_backfills
   ceph config dump | grep backfill

   ceph pg dump_stuck
   ceph pg deep-scrub 2.1a          # replace 2.1a with a real PG id from `ceph pg ls`
   ```

5. Simulá y recuperate de una caída de OSD:
   ```bash
   ceph osd out osd.2
   ceph -s                          # watch remapped/backfilling PGs
   ceph osd in osd.2
   ceph osd unset noout             # (only if a maintenance flag was set)
   ```

**Preguntas**
- Q7.1 — ¿Por qué CephFS requiere un MDS mientras que RBD no, y qué se almacena en el pool de *metadatos* de CephFS versus el pool de *datos*?
- Q7.2 — En un clúster MDS, ¿cuál es la diferencia entre un MDS **activo** y uno **standby** (o standby-replay)?
- Q7.3 — ¿Dónde almacena `ceph config set osd osd_max_backfills 4` el valor, y en qué se diferencia esa base de datos de configuración centralizada de editar `/etc/ceph/ceph.conf`?
- Q7.4 — ¿Cuál es la diferencia entre un *scrub* regular y un *deep-scrub* de un placement group?
- Q7.5 — ¿Cuál es la diferencia entre marcar un OSD como `out` y marcarlo como `down`, y cuál dispara el rebalanceo de datos?

---

<details>
<summary><strong>Clave de respuestas</strong></summary>

### Ejercicio 1
- **A1.1** — Después del bootstrap tenés exactamente un **MON** (monitor) y un **MGR** (manager); cephadm además arranca contenedores de apoyo (un agente `crash`, `node-exporter`, `prometheus`, `grafana`, `alertmanager`) y un `ceph.conf` inicializado. El tipo esencial faltante es el **OSD** (Object Storage Daemon) — con cero OSDs no hay ningún lugar donde almacenar datos.
- **A1.2** — `HEALTH_WARN` significa una condición no fatal que degrada la resiliencia o la capacidad pero que (todavía) no arriesga los datos. Acá `OSD count 0 < osd_pool_default_size 3` advierte que no existen daemons que carguen datos. `HEALTH_ERR` se reserva para condiciones que bloquean la E/S o arriesgan pérdida de datos (por ejemplo PGs `inactive`/`incomplete`, un OSD lleno).
- **A1.3** — `ceph orch ls` lista **servicios** (las especificaciones declarativas que mantiene el orquestador, por ejemplo `mon`, `mgr`, `osd`, y cuántos están corriendo vs deseados). `ceph orch ps` lista las **instancias/procesos de daemon individuales** (una fila por contenedor) con su host, versión y estado.
- **A1.4** — cephadm escribe `/etc/ceph/ceph.conf` y `/etc/ceph/ceph.client.admin.keyring` en el host de bootstrap. El keyring contiene la identidad **`client.admin`**, la clave cephx de superusuario con capacidades completas `mon/osd/mgr/mds allow *`.

### Ejercicio 2
- **A2.1** — El disco debe (1) estar sin particionar / no tener una tabla de particiones en uso, (2) no llevar ningún sistema de archivos existente ni firma LVM/otra, y (3) no estar ya reclamado como OSD. También debe ser lo suficientemente grande (≥ unos pocos GiB). Solo entonces es `AVAILABLE = Yes`.
- **A2.2** — Los OSDs modernos usan **BlueStore**, que escribe directamente al dispositivo de bloque en crudo (gestionando su propio espacio y metadatos en RocksDB), reemplazando al más antiguo FileStore-sobre-XFS. cephadm prepara el disco con **`ceph-volume`** (típicamente `ceph-volume lvm`), que crea el layout LVM, almacena la clave y los metadatos del OSD, y registra el OSD.
- **A2.3** — `STATUS up/down` refleja si el daemon OSD está actualmente **corriendo y haciendo heartbeat** con sus pares. `in/out` (expuesto vía `REWEIGHT`, donde `0` ≈ out) refleja si CRUSH debe **colocar datos** en él. `REWEIGHT` es una anulación de 0–1 sobre cuántos datos recibe el OSD relativos a su peso CRUSH. Un OSD puede estar `up` pero `out` (corriendo, sin recibir datos) o `down` pero aún `in` (caído, con datos todavía asignados, disparando recuperación).
- **A2.4** — `daemon add osd` es una acción de una sola vez sobre un dispositivo específico. `apply osd --all-available-devices` instala una **especificación/servicio de OSD persistente**: cephadm lo mantiene reconciliado, de modo que cualquier disco en blanco *nuevo* insertado luego en un host gestionado se convierte automáticamente en un OSD.

### Ejercicio 3
- **A3.1** — Con 3 monitores necesitás una **mayoría = 2** accesibles para mantener el quórum (tolerando 1 pérdida). Los números pares se desaconsejan porque elevan en cero la cantidad de fallos necesarios para perder el quórum mientras suman una máquina (4 monitores siguen tolerando solo 1 pérdida, igual que 3) y aumentan la probabilidad de empates adyacentes a split-brain — los números impares dan la mejor tolerancia a fallos por nodo.
- **A3.2** — Los monitores mantienen los mapas del clúster usando **Paxos** (un algoritmo de consenso distribuido), que garantiza una única historia consistente y ordenada de actualizaciones de mapas a través del quórum.
- **A3.3** — `step chooseleaf firstn 0 type host` selecciona los objetivos de réplica descendiendo hasta un **OSD hoja en un bucket `host` distinto** para cada réplica, de modo que las copias de cualquier objeto aterrizan en **hosts diferentes** — un host puede fallar sin perder todas las réplicas. Con `type osd`, las réplicas solo tendrían garantía de estar en OSDs diferentes, posiblemente todos en el mismo host, anulando la tolerancia a fallos a nivel de host.
- **A3.4** — CRUSH permite que cualquier cliente **calcule** la ubicación de un objeto de forma determinística a partir del nombre del objeto, el pool, y el mapa del clúster — de modo que nunca tiene que consultar un **servidor central de metadatos/búsqueda** para encontrar los datos. Esto elimina un cuello de botella y un punto único de fallo y escala la ubicación con el clúster.

### Ejercicio 4
- **A4.1** — Un **Placement Group** es un fragmento lógico de un pool: cada objeto se hashea a un PG, y el PG (no el objeto individual) es mapeado por CRUSH sobre un conjunto de OSDs. Los PGs colapsan mapeos objeto→OSD potencialmente de miles de millones en un número manejable de mapeos PG→OSD, que es lo que el clúster rastrea, empareja (peers), replica, hace scrub y rebalancea. Muy pocos PGs → distribución de datos desigual; demasiados → sobrecarga excesiva de peering/memoria.
- **A4.2** — Con `size 3` tenés 3 réplicas; `min_size 2` significa que las escrituras se aceptan mientras estén disponibles **al menos 2** réplicas, así que podés perder **1** réplica y seguir sirviendo E/S. Si la disponibilidad cae por debajo de `min_size` (queda solo 1 copia), los PGs afectados pasan a **inactive/read-restricted** para protegerse contra reconocer una escritura que existe en un único OSD posiblemente en falla.
- **A4.3** — Para `k=2, m=1`: utilizable/bruto = k/(k+m) = **2/3 (~67% de eficiencia)**, frente al 33% de la replicación 3×. Puede sobrevivir **m = 1** fallo de OSD por PG. (La codificación de borrado intercambia CPU y un `min_size`/costo de recuperación más altos por una eficiencia de espacio mucho mejor.)
- **A4.4** — El PG autoscaler ajusta **`pg_num`** (el número de placement groups por pool) según el uso real y esperado relativo a la capacidad del clúster. La propiedad **`target_size_ratio`** (o `target_size_bytes`) le indica que se espera que un pool contenga una gran parte de los datos para poder pre-dimensionarlo apropiadamente.

### Ejercicio 5
- **A5.1** — cephx autentica la **identidad** de clientes y daemons usando claves secretas compartidas y tickets de sesión (estilo Kerberos), impidiendo que actores no autorizados hablen con el clúster y permitiendo que el clúster autentique mutuamente sus propios daemons. Por sí mismo **no** es cifrado en el cable del payload de datos — el cifrado en el cable es el modo seguro separado de `msgr2` (`ms_cluster_mode`/`ms_client_mode = secure`).
- **A5.2** — `osd 'allow rwx pool=appdata'` otorga a `client.app` **acceso de lectura, escritura y ejecución (métodos de clase) a los datos de objetos, pero solo en el pool `appdata`**. No puede tocar objetos en ningún otro pool. (`mon 'allow r'` le permite leer el mapa del clúster lo suficiente para localizar los OSDs de ese pool.)
- **A5.3** — Como cephx es obligatorio (auth habilitado por defecto), **cada** participante — cada MON/OSD/MGR/MDS y cada cliente — debe presentar una clave válida para unirse o usar el clúster. `client.admin` es especial porque tiene `allow *` en todos los subsistemas: es el superusuario administrativo, así que su keyring debe protegerse estrictamente y nunca enviarse a clientes de aplicación.
- **A5.4** — Un `allow rwx pool=...` en crudo es una capacidad estática, escrita a mano. Un **`profile`** (por ejemplo `profile rbd`) es una plantilla de capacidad nombrada y mantenida que se expande exactamente a los permisos que ese caso de uso necesita (bloqueo de imágenes RBD, los objetos `rbd_directory`/`rbd_children`, métodos de clase, etc.), así que es menos propensa a errores y se mantiene correcta a medida que Ceph evoluciona.

### Ejercicio 6
- **A6.1** — La imagen se almacena como **muchos objetos RADOS**, no uno. `order 22` significa que cada objeto de respaldo es 2²² = **4 MiB**; una imagen de 1 GiB son por lo tanto ~**256 objetos** (`rbd_data.<id>.*`), distribuidos (striped) entre los PGs/OSDs del pool para paralelismo. Los objetos solo se crean cuando realmente se escriben datos.
- **A6.2** — El thin provisioning significa que la imagen anuncia 1 GiB de capacidad lógica pero consume espacio real **solo a medida que se escriben bloques**. `rbd create --size 1024` reserva casi nada por adelantado; `rados df`/`ceph df` crecen a medida que escribís en `/mnt/rbd`.
- **A6.3** — El driver `rbd` del kernel expone la imagen como un dispositivo de bloque del host (`/dev/rbd0`) usando el cliente RBD dentro del kernel — bueno para montar en el host. `librbd` es la biblioteca de espacio de usuario que hipervisores como **QEMU/KVM** enlazan directamente, dando a cada VM la imagen sin un mapeo del kernel del host y habilitando funciones avanzadas (caché del lado del cliente, funciones en vivo) que pueden llegar tarde al cliente del kernel.
- **A6.4** — Un snapshot debe estar **protegido** para que no pueda eliminarse mientras haya clones que dependan de él (sus bloques son el padre para copy-on-write). **Copy-on-write** significa que el clon inicialmente no almacena **datos propios** — referencia los objetos del snapshot padre y solo asigna objetos nuevos para los bloques que modifica, así que un clon recién creado es casi gratis en espacio.

### Ejercicio 7
- **A7.1** — CephFS es un **sistema de archivos POSIX**, así que necesita árboles de directorios, inodos, permisos, y bloqueo de archivos — el **MDS (Metadata Server)** gestiona ese namespace. RBD es un dispositivo de bloque plano sin semántica de sistema de archivos dentro de Ceph, así que no necesita MDS. El **pool de metadatos** almacena los datos de inodo/dentry/journal del sistema de archivos (pequeños, sensibles a la latencia); el **pool de datos** almacena el **contenido real de los archivos** como objetos RADOS.
- **A7.2** — Un MDS **activo** está sirviendo actualmente una porción del namespace del sistema de archivos (manejando operaciones de metadatos de los clientes). Un MDS **standby** está ocioso, listo para tomar el control si uno activo falla; un MDS **standby-replay** además sigue (tails) el journal de un MDS activo específico para poder hacer failover mucho más rápido con una caché caliente.
- **A7.3** — `ceph config set osd osd_max_backfills 4` almacena el valor en la **base de datos de configuración centralizada mantenida por los monitores** (visible vía `ceph config dump`), aplicada a todo el clúster y en runtime sin reinicios. Editar `/etc/ceph/ceph.conf` solo afecta a los daemons/clientes del **host local**, se lee principalmente al arranque, y no es distribuido por el clúster — la base de datos de config de los monitores es la fuente preferida y autoritativa.
- **A7.4** — Un **scrub** regular compara los **metadatos** de objetos (existencia, tamaño, atributos) entre réplicas para detectar inconsistencias de forma barata y frecuente. Un **deep-scrub** además lee los **datos completos del objeto y compara checksums** entre réplicas, detectando bit-rot silencioso — es mucho más intensivo en E/S y corre con menos frecuencia.
- **A7.5** — Marcar un OSD como **`out`** le dice a CRUSH que deje de colocar datos en él, lo cual **dispara el rebalanceo/backfill** de sus PGs hacia otros OSDs (el daemon puede seguir corriendo). Marcarlo como **`down`** solo significa que el daemon no está haciendo heartbeat; si permanece `down` más allá de `mon_osd_down_out_interval` el clúster automáticamente lo marca `out` (a menos que `noout` esté configurado), y *esa* transición a out es la que inicia la migración de datos.

</details>

---

**Fuentes**
- LPI Exam 306 Objectives (306-300, v3.0): https://www.lpi.org/our-certifications/exam-306-objectives/
- Ceph — Intro to Ceph & Architecture: https://docs.ceph.com/en/latest/architecture/
- cephadm — Deploying a new cluster / host & OSD management: https://docs.ceph.com/en/latest/cephadm/
- CRUSH maps: https://docs.ceph.com/en/latest/rados/operations/crush-map/
- Pools & Placement Groups: https://docs.ceph.com/en/latest/rados/operations/pools/ and https://docs.ceph.com/en/latest/rados/operations/placement-groups/
- Erasure code: https://docs.ceph.com/en/latest/rados/operations/erasure-code/
- cephx authentication: https://docs.ceph.com/en/latest/rados/operations/user-management/ and https://docs.ceph.com/en/latest/rados/configuration/auth-config-ref/
- RBD — block devices: https://docs.ceph.com/en/latest/rbd/
- CephFS: https://docs.ceph.com/en/latest/cephfs/
- Monitoring & troubleshooting OSDs/PGs: https://docs.ceph.com/en/latest/rados/operations/monitoring/ and https://docs.ceph.com/en/latest/rados/troubleshooting/