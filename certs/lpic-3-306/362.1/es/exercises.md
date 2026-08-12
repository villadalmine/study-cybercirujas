# Ejercicios guiados — Tema 362.1: DRBD

> **Entorno de laboratorio.** Todos los ejercicios asumen dos nodos idénticos con un disco de datos vacío dedicado a DRBD:
>
> | Nodo | Hostname | IP replicación | Backing device |
> |---|---|---|---|
> | 1 | `alice` | `10.0.0.1` | `/dev/sdb` |
> | 2 | `bob` | `10.0.0.2` | `/dev/sdb` |
>
> Trabajamos con **DRBD 9** (kernel module `drbd` + `drbd-utils` 9.x), señalando las diferencias con **DRBD 8.4** donde el examen las exige. Ejecutá como `root`. Cada comando marcado `[ambos]` se ejecuta en los dos nodos; `[alice]` / `[bob]` solo en el nodo indicado.
>
> Documentación de referencia usada en todo el material:
> - LINBIT — *The DRBD9 User's Guide*: https://linbit.com/drbd-user-guide/drbd-guide-9_0-en/
> - LINBIT — *The DRBD8.4 User's Guide*: https://linbit.com/drbd-user-guide/drbd-guide-8_4-en/
> - `man 5 drbd.conf`, `man 8 drbdadm`, `man 8 drbdsetup`, `man 8 drbdmeta`
> - LPI — *Exam 306 Objectives*: https://www.lpi.org/our-certifications/exam-306-objectives/

---

## Ejercicio 1 — Preparación de nodos, backing devices y metadata

**Objetivo:** entender la pila de bloques de DRBD (device virtual `/dev/drbdX` → backing device → metadata) antes de configurar nada.

1. `[ambos]` Verificá que el módulo del kernel está disponible y cargalo:

   ```bash
   modinfo drbd | head -n 3
   modprobe drbd
   lsmod | grep drbd
   ```

   Salida esperada de `lsmod`:

   ```
   drbd                  647168  0
   lru_cache              16384  1 drbd
   libcrc32c              16384  2 nf_conntrack,drbd
   ```

2. `[ambos]` Instalá las herramientas de usuario y comprobá la versión:

   ```bash
   # RHEL/Rocky con repo ELRepo:  dnf install drbd9x-utils kmod-drbd9x
   # Debian/Ubuntu:               apt install drbd-utils
   drbdadm --version
   ```

   Salida esperada:

   ```
   DRBDADM_BUILDTAG=GIT-hash:...
   DRBDADM_API_VERSION=2
   DRBD_KERNEL_VERSION_CODE=0x090201
   DRBD_KERNEL_VERSION=9.2.1
   DRBDADM_VERSION_CODE=0x091b00
   DRBDADM_VERSION=9.27.0
   ```

3. `[ambos]` Confirmá que el backing device existe, está **vacío y sin montar** (DRBD escribe metadata en él y una sincronización inicial pisa su contenido):

   ```bash
   lsblk /dev/sdb
   wipefs -a /dev/sdb        # limpia firmas de FS/particiones previas
   ```

4. `[ambos]` Asegurá la resolución de nombres — DRBD identifica peers por hostname, que debe coincidir con `uname -n`:

   ```bash
   uname -n
   grep -E 'alice|bob' /etc/hosts
   ```

   Debe verse:

   ```
   10.0.0.1   alice
   10.0.0.2   bob
   ```

> **Preguntas de verificación (1):**
> 1. ¿Qué tres tipos de objeto forman la pila de un recurso DRBD y en qué orden los atraviesa un `write(2)` de la aplicación?
> 2. La metadata *internal* de DRBD, ¿dónde se almacena físicamente y por qué el backing device debe estar vacío antes de `create-md`?
> 3. ¿Por qué DRBD necesita que el `hostname` del nodo coincida exactamente con el nombre usado en la sección `on` del recurso?

---

## Ejercicio 2 — Configuración global y del recurso `r0`

**Objetivo:** escribir un recurso sintácticamente completo y entender `global_common.conf` vs. los ficheros por recurso.

1. `[ambos]` Editá los defaults comunes en `/etc/drbd.d/global_common.conf`. Este fichero fija valores que heredan **todos** los recursos:

   ```conf
   global {
       usage-count no;
       udev-always-use-vnr;
   }

   common {
       handlers {
           # split-brain "/usr/lib/drbd/notify-split-brain.sh root";
       }
       startup {
           wfc-timeout 60;
           degr-wfc-timeout 30;
       }
       options {
           auto-promote yes;      # DRBD 9: promoción automática al montar
       }
       disk {
           on-io-error detach;    # ante fallo de E/S local, desconectar el backing disk
       }
       net {
           protocol C;            # replicación síncrona (default recomendado)
           verify-alg sha256;     # algoritmo de verificación online
       }
   }
   ```

2. `[ambos]` Creá el recurso en `/etc/drbd.d/r0.res`. **Esta es la sintaxis DRBD 9** (obligatorio `node-id`, topología por `connection-mesh`):

   ```conf
   resource r0 {
       device    /dev/drbd0 minor 0;
       disk      /dev/sdb;
       meta-disk internal;

       on alice {
           node-id 0;
           address 10.0.0.1:7788;
       }
       on bob {
           node-id 1;
           address 10.0.0.2:7788;
       }

       connection-mesh {
           hosts alice bob;
       }
   }
   ```

   > En **DRBD 8.4** no existen `node-id` ni `connection-mesh`; el `protocol` se declara dentro del recurso o en `common`, y basta con las dos secciones `on`:
   >
   > ```conf
   > resource r0 {
   >     protocol C;
   >     on alice { device /dev/drbd0; disk /dev/sdb; address 10.0.0.1:7788; meta-disk internal; }
   >     on bob   { device /dev/drbd0; disk /dev/sdb; address 10.0.0.2:7788; meta-disk internal; }
   > }
   > ```

3. `[ambos]` Los ficheros `.res` deben ser **idénticos byte a byte** en ambos nodos. Copialos y validá la sintaxis sin aplicar nada:

   ```bash
   scp /etc/drbd.d/*.conf /etc/drbd.d/*.res bob:/etc/drbd.d/    # [alice]
   drbdadm dump r0                                              # [ambos]
   ```

   `drbdadm dump` parsea y reimprime la configuración expandida; si hay un error de sintaxis, falla acá antes de tocar disco.

> **Preguntas de verificación (2):**
> 1. ¿Qué diferencia hay entre `/etc/drbd.d/global_common.conf` y `/etc/drbd.d/<recurso>.res`, y qué precedencia tiene un parámetro definido en ambos?
> 2. En DRBD 9, ¿qué aporta la sección `connection-mesh` y por qué es obligatorio `node-id`?
> 3. ¿Qué hace `auto-promote yes` y en qué se diferencia del comportamiento por defecto de DRBD 8.4?
> 4. ¿Por qué `drbdadm dump` es el primer comando que conviene correr tras editar la configuración?

---

## Ejercicio 3 — Crear metadata, levantar el recurso y leer los estados

**Objetivo:** inicializar la metadata, activar el recurso y dominar el vocabulario de estados: **role**, **connection state (cstate)** y **disk state (dstate)**.

1. `[ambos]` Escribí la metadata interna en el backing device:

   ```bash
   drbdadm create-md r0
   ```

   Salida esperada:

   ```
   initializing activity log
   initializing bitmap (320 KB) to all zero
   Writing meta data...
   New drbd meta data block successfully created.
   ```

2. `[ambos]` Levantá el recurso (carga el device virtual e intenta conectar con el peer):

   ```bash
   drbdadm up r0
   ```

3. `[ambos]` Observá el estado inicial. Ambos discos están `Inconsistent` y ambos nodos `Secondary` — DRBD todavía no sabe cuál copia es la buena:

   ```bash
   drbdadm status r0
   ```

   Salida esperada:

   ```
   r0 role:Secondary
     disk:Inconsistent
     bob role:Secondary
       peer-disk:Inconsistent
   ```

4. `[alice]` Elegí `alice` como fuente de la **sincronización inicial completa**. `--force` marca su disco como `UpToDate` y lo promueve a `Primary`, arrancando la copia hacia `bob`:

   ```bash
   drbdadm primary --force r0
   ```

5. `[alice]` Observá la sincronización en curso con estadísticas:

   ```bash
   drbdsetup status r0 --verbose --statistics
   ```

   Salida esperada (durante el sync):

   ```
   r0 node-id:0 role:Primary suspended:no
       volume:0 minor:0 disk:UpToDate
       bob node-id:1 connection:Connected role:Secondary
           volume:0 replication:SyncSource peer-disk:Inconsistent done:41.87
   ```

6. `[ambos]` Esperá a que termine y confirmá el estado estable `UpToDate/UpToDate`:

   ```bash
   drbdadm wait-sync r0
   drbdadm status r0
   ```

   Estado final:

   ```
   r0 role:Primary
     disk:UpToDate
     bob role:Secondary
       peer-disk:UpToDate
   ```

7. `[ambos]` Consultá cada dimensión del estado por separado:

   ```bash
   drbdadm role r0        # Primary  |  Secondary
   drbdadm cstate r0      # Connected
   drbdadm dstate r0      # UpToDate/UpToDate  (local/peer)
   ```

   > En **DRBD 8.4** el estado se leía típicamente con `cat /proc/drbd`:
   >
   > ```
   >  0: cs:Connected ro:Primary/Secondary ds:UpToDate/UpToDate C r-----
   > ```
   >
   > En DRBD 9 `/proc/drbd` casi no trae información; usá `drbdadm status` / `drbdsetup status`.

> **Preguntas de verificación (3):**
> 1. Distinguí **role**, **cstate** y **dstate**. Nombrá un valor posible de cada uno en operación normal.
> 2. ¿Por qué es necesario `--force` en la primera promoción y qué habría pasado si lo omitías con ambos discos `Inconsistent`?
> 3. Diferenciá los disk states `Inconsistent`, `Outdated` y `UpToDate`. ¿Cuál de ellos permite montar el device de forma segura?
> 4. `SyncSource` y `SyncTarget` son valores de `replication`, no de `role`. Explicá qué indica cada uno durante el ejercicio.

---

## Ejercicio 4 — Filesystem sobre el Primary y failover manual (single-primary)

**Objetivo:** usar el device replicado y ejecutar una conmutación ordenada de rol, respetando la regla del **single-primary**.

1. `[alice]` Creá un filesystem sobre el **device DRBD** (`/dev/drbd0`), nunca sobre `/dev/sdb`:

   ```bash
   mkfs.ext4 /dev/drbd0
   mkdir -p /srv/data
   mount /dev/drbd0 /srv/data
   echo "escrito en alice $(date)" > /srv/data/testfile
   sync
   ```

2. `[alice]` Para conmutar, desmontá y degradá `alice` a `Secondary`:

   ```bash
   umount /srv/data
   drbdadm secondary r0
   drbdadm role r0        # -> Secondary
   ```

3. `[bob]` Promové `bob` a `Primary` y montá; el fichero escrito en `alice` está presente:

   ```bash
   drbdadm primary r0
   mkdir -p /srv/data
   mount /dev/drbd0 /srv/data
   cat /srv/data/testfile
   ```

   Salida esperada:

   ```
   escrito en alice Tue Aug 12 ...
   ```

4. `[bob]` Probá la regla de single-primary: intentá promover mientras el otro ya es Primary (revertí primero el paso 2–3 para dejar a `alice` Primary y luego intentá en `bob`):

   ```bash
   drbdadm primary r0
   ```

   Salida esperada del rechazo:

   ```
   r0: State change failed: (-1) Multiple primaries not allowed by config
   Command 'drbdsetup primary r0' terminated with exit code 11
   ```

> **Preguntas de verificación (4):**
> 1. ¿Por qué el filesystem se crea sobre `/dev/drbd0` y montar directamente `/dev/sdb` en un nodo Secondary corrompería los datos?
> 2. Enumerá en orden los pasos de un failover manual limpio entre dos nodos en modo single-primary.
> 3. ¿Qué impide, a nivel de configuración, que ambos nodos sean Primary a la vez, y qué parámetro habría que cambiar para permitirlo?
> 4. Con `auto-promote yes`, ¿qué acción del sistema promueve implícitamente el recurso a Primary y cuándo lo devuelve a Secondary?

---

## Ejercicio 5 — Protocolos de replicación A, B y C

**Objetivo:** entender el trade-off latencia vs. durabilidad de los tres protocolos y cómo cambiarlos.

1. `[ambos]` El recurso ya usa `protocol C` (heredado de `common`). Para experimentar, sobrescribí el protocolo dentro de una sección `net` del recurso `r0.res`:

   ```conf
   resource r0 {
       net {
           protocol A;        # asíncrono
       }
       # ... resto igual
   }
   ```

2. `[ambos]` Aplicá el cambio en caliente (sin bajar el recurso) y verificá:

   ```bash
   drbdadm adjust r0
   drbdsetup show r0 | grep -i protocol
   ```

   `drbdadm adjust` calcula el *delta* entre la configuración en disco y el estado en kernel, y aplica solo lo que cambió.

3. `[ambos]` Volvé a `protocol C` (el único apto para failover automático con Pacemaker) y reajustá:

   ```bash
   # dejar protocol C en r0.res
   drbdadm adjust r0
   ```

> **Preguntas de verificación (5):**
> 1. Definí en una frase el punto de confirmación (*acknowledgement*) de cada protocolo:
>    - **A** (asíncrono)
>    - **B** (semi-síncrono / *memory synchronous*)
>    - **C** (síncrono)
> 2. Con **protocol A**, si el Primary sufre una pérdida total de energía justo tras confirmar un `write`, ¿puede perderse ese dato? ¿Y con **protocol C**?
> 3. ¿Por qué **protocol C** es el requerido para un cluster de alta disponibilidad con failover automático?
> 4. ¿Qué hace `drbdadm adjust` y en qué se diferencia de bajar (`down`) y volver a levantar (`up`) el recurso?

---

## Ejercicio 6 — Split-brain: provocación, detección y recuperación

**Objetivo:** reconocer un split-brain, entender las políticas `after-sb-*` y recuperar manualmente descartando datos.

1. `[ambos]` Añadí políticas de resolución automática en la sección `net` de `r0.res` (y aplicá con `drbdadm adjust r0`):

   ```conf
   net {
       protocol C;
       after-sb-0pri discard-zero-changes;
       after-sb-1pri discard-secondary;
       after-sb-2pri disconnect;
   }
   ```

2. `[alice]` Provocá un split-brain manualmente: aislá el enlace y escribí en **ambos** nodos como Primary. Primero desconectá:

   ```bash
   drbdadm disconnect r0        # [alice] deja el recurso StandAlone respecto del peer
   drbdadm primary r0
   mount /dev/drbd0 /srv/data
   echo "cambio SOLO en alice" >> /srv/data/testfile
   ```

3. `[bob]` En paralelo, mientras `alice` está aislada, promové y escribí datos divergentes en `bob`:

   ```bash
   drbdadm primary --force r0
   mount /dev/drbd0 /srv/data
   echo "cambio SOLO en bob" >> /srv/data/testfile
   ```

4. `[ambos]` Reconectá. Como ambos tienen cambios propios y la política de 2 primaries es `disconnect`, DRBD detecta el split-brain y queda `StandAlone`:

   ```bash
   umount /srv/data ; drbdadm secondary r0      # bajá ambos a Secondary primero
   drbdadm connect r0
   drbdadm cstate r0
   dmesg | grep -i split-brain
   ```

   En el log del kernel aparece:

   ```
   drbd r0: Split-Brain detected but unresolved, dropping connection!
   ```

   Y `drbdadm cstate r0` devuelve `StandAlone`.

5. **Recuperación manual.** Elegí la **víctima** (el nodo cuyos cambios se descartan; supongamos `bob`). En la víctima, desconectá, degradá y reconectá descartando sus datos:

   ```bash
   # [bob]  (víctima)
   drbdadm disconnect r0
   drbdadm secondary r0
   drbdadm connect --discard-my-data r0
   ```

   ```bash
   # [alice]  (superviviente / fuente de verdad)
   drbdadm connect r0
   ```

6. `[ambos]` DRBD resincroniza desde `alice` hacia `bob` y vuelve a `Connected` / `UpToDate`:

   ```bash
   drbdadm wait-sync r0
   drbdadm status r0
   ```

> **Preguntas de verificación (6):**
> 1. Definí *split-brain* en DRBD. ¿Por qué el resultado inmediato es que la conexión pasa a `StandAlone`?
> 2. ¿Qué evalúa cada política y en qué situación se aplica?
>    - `after-sb-0pri`
>    - `after-sb-1pri`
>    - `after-sb-2pri`
> 3. En la recuperación manual, ¿qué hace exactamente `--discard-my-data` y sobre qué nodo debe ejecutarse — la víctima o el superviviente?
> 4. Un `after-sb-0pri discard-zero-changes` resuelve automáticamente algunos split-brains sin pérdida. ¿En qué escenario concreto no descarta datos de ningún nodo?

---

## Ejercicio 7 — Dual-primary y verificación online

**Objetivo:** habilitar modo dual-primary (solo con un filesystem de cluster) y ejecutar una verificación de integridad online.

1. `[ambos]` Para dual-primary, DRBD exige `allow-two-primaries` y una política de fencing. Añadí a `net` de `r0.res`:

   ```conf
   net {
       protocol C;
       allow-two-primaries yes;
       fencing resource-and-stonith;
       after-sb-2pri disconnect;
   }
   ```

   > **Regla dura:** dual-primary **solo** es seguro montando un filesystem de cluster (GFS2, OCFS2) que coordine el acceso concurrente por nodo mediante un DLM. Montar ext4/xfs en ambos Primary a la vez corrompe el filesystem de inmediato.

2. `[ambos]` Aplicá y promové ambos nodos:

   ```bash
   drbdadm adjust r0
   drbdadm primary r0          # ahora sí, ambos pueden ser Primary
   drbdadm status r0
   ```

   Salida esperada:

   ```
   r0 role:Primary
     disk:UpToDate
     bob role:Primary
       peer-disk:UpToDate
   ```

3. `[alice]` Lanzá una **verificación online** (compara bloque a bloque local vs. peer usando `verify-alg`, sin interrumpir el servicio):

   ```bash
   drbdadm verify r0
   ```

4. `[ambos]` Al terminar, revisá el log en busca de bloques *out-of-sync*. Si aparecen, se corrigen forzando una resincronización desde el nodo bueno:

   ```bash
   dmesg | grep -i 'out-of-sync\|verify'
   # si hubo diferencias, en el nodo con datos correctos:
   drbdadm invalidate-remote r0
   ```

> **Preguntas de verificación (7):**
> 1. ¿Qué dos requisitos de configuración habilitan dual-primary y por qué el filesystem debe ser de cluster (GFS2/OCFS2)?
> 2. ¿Qué hace `drbdadm verify` y por qué se dice que es *online*? ¿Corrige por sí mismo los bloques divergentes?
> 3. Diferenciá `drbdadm invalidate r0` de `drbdadm invalidate-remote r0`: ¿qué copia marca como fuente de verdad cada uno?
> 4. ¿Qué rol cumple `fencing resource-and-stonith` en un cluster dual-primary?

---

## Ejercicio 8 — Integración con Pacemaker (recurso promotable)

**Objetivo:** delegar la promoción/degradación a Pacemaker mediante el resource agent `ocf:linbit:drbd`, dejando DRBD sin arrancar por systemd.

1. `[ambos]` Deshabilitá el arranque autónomo de DRBD — el cluster debe ser el único que gestiona el rol:

   ```bash
   systemctl disable --now drbd
   drbdadm down r0     # que Pacemaker lo levante
   ```

2. `[alice]` Definí el recurso DRBD y su clon **promotable** en una copia de la CIB, y empujala atómicamente:

   ```bash
   pcs cluster cib drbd_cfg

   pcs -f drbd_cfg resource create DRBD_r0 ocf:linbit:drbd \
       drbd_resource=r0 \
       op monitor interval=29s role=Promoted \
       op monitor interval=31s role=Unpromoted

   pcs -f drbd_cfg resource promotable DRBD_r0 \
       promoted-max=1 promoted-node-max=1 \
       clone-max=2 clone-node-max=1 notify=true

   pcs cluster cib-push drbd_cfg
   ```

   > En clusters/`pcs` más antiguos el clon multiestado se creaba con `pcs resource master` y los roles se llamaban `Master`/`Slave` en lugar de `Promoted`/`Unpromoted`. El agente `ocf:linbit:drbd` es el mismo.

3. `[alice]` Colocá el filesystem *sobre* el DRBD y ordená la dependencia: el FS solo puede montar donde DRBD esté `Promoted`, y **después** de la promoción:

   ```bash
   pcs resource create FS_data ocf:heartbeat:Filesystem \
       device=/dev/drbd0 directory=/srv/data fstype=ext4

   pcs constraint colocation add FS_data with Promoted DRBD_r0-clone INFINITY
   pcs constraint order promote DRBD_r0-clone then start FS_data
   ```

4. `[ambos]` Verificá que Pacemaker promovió un nodo y montó el FS ahí:

   ```bash
   pcs status
   ```

   Salida esperada (extracto):

   ```
     * Clone Set: DRBD_r0-clone [DRBD_r0] (promotable):
       * Promoted: [ alice ]
       * Unpromoted: [ bob ]
     * FS_data   (ocf:heartbeat:Filesystem):   Started alice
   ```

> **Preguntas de verificación (8):**
> 1. ¿Por qué se deshabilita el servicio `drbd` de systemd cuando Pacemaker gestiona el recurso?
> 2. ¿Qué representa un recurso *promotable* (multiestado) y cómo mapea sus roles `Promoted`/`Unpromoted` sobre los roles `Primary`/`Secondary` de DRBD?
> 3. Explicá las dos constraints del paso 3: ¿qué garantiza la de colocación y qué la de orden?
> 4. ¿Qué haría el cluster si `alice` (nodo Promoted) cae, y qué papel juega el estado `Outdated` para que Pacemaker no promueva una copia obsoleta?

---

<details>
<summary><strong>Respuestas</strong></summary>

### Ejercicio 1
1. **Device virtual** (`/dev/drbd0`) → **backing device** (`/dev/sdb`) → **metadata**. La aplicación escribe siempre en `/dev/drbd0`; DRBD intercepta el `write`, lo envía por red al peer según el protocolo, lo persiste en el backing device local y actualiza su bitmap/activity-log en la metadata.
2. La metadata *internal* se guarda **al final del propio backing device** (últimos ~32 MB por cada 1 TB, más el área fija). Por eso el disco debe estar vacío: `create-md` sobrescribe esa cola, y si hubiera un FS que ocupa el disco entero, la metadata pisaría datos del filesystem (y viceversa la sincronización inicial destruye lo que hubiera). La metadata *external* iría en un device separado.
3. Porque DRBD hace *match* del nodo local buscando la sección `on <hostname>` cuyo nombre coincide con `uname -n`. Si no coincide, `drbdadm` no sabe qué configuración es la del nodo local y falla (`Can not find myself in configuration`).

### Ejercicio 2
1. `global_common.conf` define la sección `global` (parámetros del daemon, uno por host) y `common` (defaults heredados por todos los recursos). Cada `.res` define un recurso concreto y **sobrescribe** los defaults: lo definido en el recurso gana sobre lo definido en `common`.
2. `connection-mesh` declara que todos los hosts listados se replican entre sí (malla completa), esencial cuando hay 3+ nodos. `node-id` es obligatorio en DRBD 9 porque el protocolo multi-nodo identifica a cada peer por un id numérico estable, no por su posición.
3. `auto-promote yes` hace que DRBD promueva el recurso a Primary automáticamente cuando algo abre el device en modo escritura (p. ej. `mount`), y lo devuelva a Secondary al cerrarlo. DRBD 8.4 no tiene esta función: la promoción es siempre manual (`drbdadm primary`).
4. `drbdadm dump` parsea toda la configuración y la reimprime expandida sin tocar el kernel ni el disco; detecta errores de sintaxis y herencias mal resueltas antes de aplicar cambios destructivos.

### Ejercicio 3
1. **role**: rol del recurso en el nodo (`Primary`/`Secondary`). **cstate**: estado de la conexión con el peer (`Connected`, `StandAlone`, `Connecting`, `WFConnection`…). **dstate**: estado del dato local/peer (`UpToDate`, `Inconsistent`, `Outdated`, `Diskless`…).
2. `--force` es necesario porque en el arranque ambos discos son `Inconsistent` y ninguno es fuente válida; `--force` declara arbitrariamente que la copia local es buena y arranca el full sync. Sin `--force`, la promoción se rechaza porque no se puede servir un dato `Inconsistent`.
3. `Inconsistent` = datos parciales/no fiables (durante sync inicial o resync), **no montable**. `Outdated` = datos consistentes pero se sabe que hay una versión más nueva en otra parte; no montable como Primary sin más. `UpToDate` = consistente y al día; **el único apto para montar/servir**.
4. `SyncSource` = este nodo está **enviando** los bloques para poner al día al peer; `SyncTarget` = este nodo está **recibiendo** y su disco está `Inconsistent` hasta terminar. Son estados de `replication`, ortogonales al `role`.

### Ejercicio 4
1. Porque DRBD intercepta la E/S en la capa `/dev/drbd0`; escribir directamente en `/dev/sdb` salta la replicación y el activity-log, y en un Secondary el backing device no puede montarse (DRBD lo tiene tomado y sus datos podrían estar mid-write). Montar `/dev/sdb` en paralelo corrompe la coherencia.
2. (1) En el Primary actual: `umount`; (2) `drbdadm secondary r0`; (3) en el otro nodo: `drbdadm primary r0`; (4) `mount /dev/drbd0`. Con `auto-promote`, los pasos 2–3 se reducen a `umount` en uno y `mount` en el otro.
3. Lo impide la ausencia de `allow-two-primaries yes`; con la configuración por defecto DRBD rechaza la segunda promoción (`Multiple primaries not allowed by config`). Para permitirlo hay que poner `allow-two-primaries yes` **y** un FS de cluster.
4. Cualquier apertura del device en escritura (típicamente `mount`, o un `mkfs`) lo promueve; al cerrar el último acceso (`umount`) DRBD lo devuelve a Secondary.

### Ejercicio 5
1. **A**: confirma al escritor local en cuanto el `write` sale al buffer TCP de envío local (no espera al peer). **B**: confirma cuando el peer **recibió** el paquete en memoria (aún no lo escribió a disco). **C**: confirma cuando el peer **persistió** el bloque en su disco.
2. Con **A** sí: el dato confirmado podía estar solo en el buffer de red local y no haber llegado al peer → se pierde. Con **C** no: la confirmación implica que el peer ya lo tiene en disco, por lo que sobrevive a la caída del Primary.
3. Porque el failover automático asume que el Secondary tiene una copia idéntica y confirmada; solo **C** garantiza que todo write confirmado está en disco del peer, evitando pérdida silenciosa al promover el Secondary.
4. `drbdadm adjust` compara la configuración en disco con el estado actual del kernel y aplica **solo el delta** en caliente, sin cortar la replicación. `down`+`up` reinicia el recurso por completo (desconecta, descarga el device) — disruptivo e innecesario para un cambio de parámetro.

### Ejercicio 6
1. Split-brain = ambos nodos fueron Primary (o divergieron) de forma independiente mientras estaban desconectados, generando **dos conjuntos de cambios incompatibles** sobre el mismo dato. Al reconectar, DRBD no puede fusionarlos automáticamente y, para no pisar datos, corta la conexión dejándola `StandAlone`.
2. `after-sb-0pri`: se aplica cuando, al reconectar, **ninguno** de los nodos es Primary. `after-sb-1pri`: cuando **exactamente uno** es Primary. `after-sb-2pri`: cuando **ambos** son (o fueron) Primary — el caso más peligroso; `disconnect` fuerza intervención manual.
3. `--discard-my-data` le dice a ese nodo que **abandone sus propios cambios** y acepte los del peer como fuente de verdad, disparando una resync entrante. Se ejecuta en la **víctima** (el nodo cuyos datos se sacrifican); el superviviente solo hace `connect`.
4. `discard-zero-changes` no descarta nada cuando **uno de los dos nodos no tuvo escrituras** desde la desconexión: se conserva el que sí cambió y se resincroniza al que quedó igual (cero cambios), sin pérdida real.

### Ejercicio 7
1. Requisitos: `allow-two-primaries yes` y una política de `fencing`/gestión de split-brain adecuada. El FS debe ser de cluster (GFS2/OCFS2) porque coordina el acceso concurrente entre nodos mediante un DLM (Distributed Lock Manager); un FS local (ext4/xfs) asume acceso exclusivo y se corrompe si dos nodos escriben a la vez el mismo bloque.
2. `drbdadm verify` compara **bloque a bloque** el contenido local contra el del peer usando el digest de `verify-alg`, mientras el recurso sigue en servicio (por eso *online*). **No corrige**: solo marca los bloques divergentes como out-of-sync en el log; la corrección se dispara aparte (`invalidate`/`invalidate-remote` o un resync).
3. `invalidate r0` marca la copia **local** como out-of-sync → la local se resincroniza **desde** el peer (el peer es la verdad). `invalidate-remote r0` marca la copia **del peer** como out-of-sync → el peer se resincroniza desde el nodo local (el local es la verdad).
4. `resource-and-stonith` congela la E/S del recurso (`resource`) y ejecuta un handler de fencing/STONITH para apagar o aislar al peer sospechoso antes de continuar, evitando que ambos escriban divergentemente y garantizando que solo una copia siga siendo válida.

### Ejercicio 8
1. Porque solo un gestor debe controlar el rol. Si systemd levantara DRBD y promoviera por su cuenta, competiría con Pacemaker y podría producir doble promoción o estados inconsistentes; el cluster necesita ser la única autoridad sobre `primary`/`secondary`.
2. Un recurso *promotable* (antes *master/slave*) es un clon con dos estados por instancia: `Promoted`/`Unpromoted`. El agente `ocf:linbit:drbd` traduce `Promoted`→`drbdadm primary` y `Unpromoted`→`drbdadm secondary`. `promoted-max=1` obliga a un único Primary (single-primary).
3. La **colocación** (`FS_data with Promoted DRBD_r0-clone INFINITY`) fuerza a que el filesystem se monte exactamente en el nodo donde DRBD está Promoted. La de **orden** (`promote … then start FS_data`) garantiza que la promoción a Primary ocurre **antes** de intentar montar; sin ella, el mount fallaría por device Secondary.
4. Al caer `alice`, Pacemaker promueve a `bob` (`drbdadm primary`) y arranca `FS_data` ahí. El estado `Outdated` es la salvaguarda: si `bob` supiera que sus datos quedaron desactualizados respecto de un Primary vivo, el resource agent reporta la copia como no promovible, impidiendo que Pacemaker promueva un dato viejo y provoque pérdida.

</details>