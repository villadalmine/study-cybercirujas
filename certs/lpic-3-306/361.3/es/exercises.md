# Tópico 361.3: Failover Clusters — Ejercicios guiados

> **Examen 306-300, v3.0 — Topic 361 (High Availability Cluster Management).** El objetivo 361.3 es el objetivo más pesado del examen, y es donde la teoría se convierte en un sistema en funcionamiento: una capa de membresía/quorum de Corosync, un gestor de recursos Pacemaker por encima, fencing/STONITH para hacer seguro el failover, y restricciones de recursos que deciden *dónde* y *en qué orden* se ejecutan los servicios.

**Topología de laboratorio usada a lo largo de todo el documento.** Tres nodos para que el quorum se comporte normalmente (2 de 3 votos), un dispositivo de bloque compartido para el fencing por poison-pill de SBD, y un dispositivo de bloque compartido para un sistema de archivos en cluster.

| Host | Dirección de Ring 0 | Rol |
|---|---|---|
| `node1` | 192.168.122.11 | miembro del cluster, DC inicial |
| `node2` | 192.168.122.12 | miembro del cluster |
| `node3` | 192.168.122.13 | miembro del cluster |
| — | 192.168.122.100 | VIP flotante del servicio (un recurso, no un host) |
| `/dev/disk/by-id/…-sbd` | LUN compartida | dispositivo de slot SBD (~10 MiB) |
| `/dev/disk/by-id/…-web` | LUN compartida | sistema de archivos XFS para el contenido web |

Ejecutá cada comando como `root`. Cuando un paso diga *"en todos los nodos"*, ejecutalo en `node1`, `node2` y `node3`; todo lo demás se ejecuta una sola vez en `node1` salvo que se indique, porque Pacemaker replica la CIB (Cluster Information Base) a cada nodo automáticamente.

---

## Ejercicio 1 — Arrancar el cluster Corosync/Pacemaker con `pcs`

1. Instalá el stack **en todos los nodos** (se muestran los nombres de paquete de RHEL/Alma/Rocky 9; en SUSE el metapaquete es `ha_sles`, en Debian es `pacemaker corosync pcs`):

   ```bash
   dnf install -y pacemaker corosync pcs sbd fence-agents-sbd fence-agents-all
   ```

2. El demonio `pcs` autentica los nodos con un usuario de sistema local `hacluster` creado por el paquete. Asignale una contraseña **en todos los nodos** (usá la misma contraseña en todos):

   ```bash
   echo 'S0meStr0ngP@ss' | passwd --stdin hacluster
   ```

3. Habilitá y arrancá el demonio `pcsd` **en todos los nodos** — este es el plano de control REST/CLI, distinto de Corosync/Pacemaker:

   ```bash
   systemctl enable --now pcsd
   ```

4. Desde `node1`, autenticá los tres nodos entre sí. En `pcs` ≥ 0.10 el subcomando es `host auth` (el antiguo `pcs cluster auth` es la grafía de 0.9):

   ```bash
   pcs host auth node1 node2 node3 -u hacluster -p 'S0meStr0ngP@ss'
   ```
   ```
   node1: Authorized
   node2: Authorized
   node3: Authorized
   ```

5. Generá y distribuí `/etc/corosync/corosync.conf` a los tres nodos de una sola vez. `pcs cluster setup` escribe la configuración, arma la authkey, y envía ambas a todo el cluster:

   ```bash
   pcs cluster setup hacluster node1 node2 node3
   ```

6. Arrancá Corosync + Pacemaker en todos lados, y habilitalos en el arranque:

   ```bash
   pcs cluster start --all
   pcs cluster enable --all
   ```

7. Confirmá que el cluster está levantado y con quorum:

   ```bash
   pcs status
   ```
   ```
   Cluster name: hacluster
   Cluster Summary:
     * Stack: corosync
     * Current DC: node1 (version 2.1.5-a3f44794f94) - partition with quorum
     * 3 nodes configured
     * 0 resource instances configured

   Node List:
     * Online: [ node1 node2 node3 ]

   Full List of Resources:
     * No resources

   Daemon Status:
     corosync: active/enabled
     pacemaker: active/enabled
     pcsd: active/enabled
   ```

**Verificación de comprensión 1**

- **1a.** Ahora hay tres demonios corriendo por nodo: `pcsd`, `corosync` y `pacemaker`. ¿Cuál es la tarea propia de cada uno, y cuál *no* necesitarías estrictamente en ejecución para que el cluster siga dando servicio después de la configuración?
- **1b.** El paso 4 (`pcs host auth`) y el paso 5 (`pcs cluster setup`) tocan ambos todos los nodos. ¿Por qué no podés saltarte el paso 4 e ir directo a `setup`?
- **1c.** `pcs status` informa "partition with quorum". Con tres nodos en línea, ¿cuántos votos hay presentes y cuántos se requieren para el quorum? ¿A qué se refiere "partition" acá?

---

## Ejercicio 2 — Inspeccionar la capa de membresía y quorum (Corosync)

Pacemaker está tan sano como la capa Corosync que le alimenta los eventos de membresía. Estas herramientas consultan Corosync directamente.

1. Mirá el estado del anillo totem y el transporte en uso (Corosync 3 usa por defecto el transporte `knet`):

   ```bash
   corosync-cfgtool -s
   ```
   ```
   Local node ID 1, transport knet
   LINK ID 0 udp
       addr    = 192.168.122.11
       status:
           nodeid:   1:    localhost
           nodeid:   2:    connected
           nodeid:   3:    connected
   ```

2. Consultá el servicio votequorum — esta es la vista autoritativa del quorum:

   ```bash
   corosync-quorumtool -s
   ```
   ```
   Quorum information
   ------------------
   Quorum provider:  corosync_votequorum
   Nodes:            3
   Node ID:          1
   Ring ID:          1.1a
   Quorate:          Yes

   Votequorum information
   ----------------------
   Expected votes:   3
   Highest expected: 3
   Total votes:      3
   Quorum:           2
   Flags:            Quorate

   Membership information
   ----------------------
       Nodeid      Votes Name
            1          1 node1 (local)
            2          1 node2
            3          1 node3
   ```

3. Volcá y filtrá con grep el mapa de configuración en memoria (CMAP), donde Corosync guarda las claves de runtime:

   ```bash
   corosync-cmapctl | grep -E 'quorum|two_node|members'
   ```
   ```
   quorum.provider (str) = corosync_votequorum
   runtime.members.1.status (str) = joined
   runtime.members.2.status (str) = joined
   runtime.members.3.status (str) = joined
   ```

4. Leé la configuración que generó `pcs cluster setup`:

   ```bash
   cat /etc/corosync/corosync.conf
   ```
   ```
   totem {
       version: 2
       cluster_name: hacluster
       transport: knet
       crypto_cipher: aes256
       crypto_hash: sha256
   }

   nodelist {
       node { ring0_addr: node1  name: node1  nodeid: 1 }
       node { ring0_addr: node2  name: node2  nodeid: 2 }
       node { ring0_addr: node3  name: node3  nodeid: 3 }
   }

   quorum {
       provider: corosync_votequorum
   }

   logging {
       to_logfile: yes
       logfile: /var/log/cluster/corosync.log
       to_syslog: yes
       timestamp: on
   }
   ```

**Verificación de comprensión 2**

- **2a.** En la salida de `corosync-quorumtool`, `Quorum: 2`. Derivá ese número a partir de `Expected votes`. Si más adelante agregás un cuarto nodo, ¿en cuánto quedará `Quorum`, y por qué un cluster de 4 nodos puede ser *más* frágil que uno de 3 ante una partición limpia 50/50?
- **2b.** El `corosync.conf` generado **no** tiene línea `two_node: 1`. ¿Cuándo agregaría `pcs` una, y qué dos efectos secundarios habilita `two_node` en el proveedor `votequorum`?
- **2c.** `corosync-cfgtool -s` muestra `nodeid: 2: connected`, pero `corosync-quorumtool` muestra `Nodeid 2 … joined`. Uno es un estado de *link* y el otro un estado de *membresía*. ¿Qué herramienta revelaría primero un anillo de red roto mientras el nodo por lo demás sigue arriba?

---

## Ejercicio 3 — Hacer seguro el failover: fencing / STONITH con SBD

Un cluster de failover que no puede hacer fencing no debe hacer failover — de lo contrario un nodo particionado que Pacemaker *cree* muerto podría seguir escribiendo en el almacenamiento compartido (split-brain → corrupción). Configuramos **SBD (Storage-Based Death)**: una poison-pill escrita en un dispositivo de slot compartido, respaldada por un watchdog de hardware/software.

1. Confirmá que STONITH está actualmente *habilitado como política* pero que todavía no existe ningún dispositivo — el cluster está en un estado inseguro y se negará a arrancar recursos de forma limpia:

   ```bash
   pcs property config stonith-enabled
   ```
   ```
   Cluster Properties:
     stonith-enabled: true   # default; never disable this in production
   ```

2. Cargá un watchdog **en todos los nodos**. El hardware real expone `/dev/watchdog` (p. ej. `iTCO_wdt`); para un laboratorio, el watchdog por software sirve:

   ```bash
   modprobe softdog
   ls -l /dev/watchdog
   ```

3. Inicializá los metadatos de SBD en el dispositivo de slot compartido (hacé esto **una sola vez**, solo desde `node1` — escribe el encabezado en disco que todos los nodos van a compartir):

   ```bash
   sbd -d /dev/disk/by-id/scsi-360014...-sbd create
   ```

4. Habilitá SBD a nivel de todo el cluster con `pcs`. Esto escribe `/etc/sysconfig/sbd` en cada nodo, conecta el watchdog, y requiere reiniciar el cluster para tomar efecto:

   ```bash
   pcs cluster stop --all
   pcs stonith sbd enable \
       --device=/dev/disk/by-id/scsi-360014...-sbd \
       SBD_WATCHDOG_TIMEOUT=5 \
       SBD_STARTMODE=clean
   pcs cluster start --all
   ```

5. Creá el recurso de fencing que arma el mecanismo de poison-pill (el SBD con disco compartido necesita un primitive STONITH `fence_sbd`; el SBD sin disco no):

   ```bash
   pcs stonith create sbd-fence fence_sbd \
       devices=/dev/disk/by-id/scsi-360014...-sbd \
       pcmk_delay_base=5s
   ```

6. Verificá el demonio SBD e inspeccioná la tabla de asignación de slots:

   ```bash
   pcs stonith sbd status --full
   sbd -d /dev/disk/by-id/scsi-360014...-sbd list
   ```
   ```
   0  node1  clear
   1  node2  clear
   2  node3  clear
   ```

7. Probá el mecanismo *sin* matar un nodo — enviá un mensaje `test` a un slot y observá cómo se limpia:

   ```bash
   sbd -d /dev/disk/by-id/scsi-360014...-sbd message node2 test
   ```

**Verificación de comprensión 3**

- **3a.** SBD depende de *dos* componentes independientes que trabajan juntos para garantizar que un nodo esté muerto. Nombrá ambos, y explicá qué garantiza cada uno por sí solo — ¿por qué es indispensable el watchdog incluso cuando el mecanismo del slot en disco funciona?
- **3b.** `pcs property config` muestra `stonith-enabled: true`. ¿Qué le hace Pacemaker a un recurso que necesita recuperación si `stonith-enabled=true` pero **no** existe un dispositivo STONITH que funcione?
- **3c.** El paso 5 fija `pcmk_delay_base=5s`. En una "fence race" simétrica de dos nodos, ¿qué problema resuelve un retardo de fencing, y por qué se aplica típicamente de forma asimétrica (retardo en un solo nodo)?
- **3d.** Contrastá el **SBD con disco compartido** (este ejercicio) con el **SBD sin disco**. ¿En qué se apoya *por completo* el SBD sin disco para su decisión de fencing, y cuál es la cantidad mínima de nodos que realistamente necesita?

---

## Ejercicio 4 — Crear recursos y restringirlos

Ahora construí el servicio real: un sistema de archivos XFS compartido, una VIP flotante y Apache, dispuestos para que siempre se ejecuten juntos, en el mismo nodo, en el orden correcto.

1. Inspeccioná los agentes de recurso OCF disponibles para el proveedor `heartbeat` (esta es la *clase de recurso* `ocf` que el examen te pide conocer, junto con `lsb`, `systemd`, `service`, `stonith` y `nagios`):

   ```bash
   pcs resource list ocf:heartbeat: | grep -E 'IPaddr2|Filesystem|apache'
   ```

2. Creá el recurso del sistema de archivos compartido (asume que la LUN ya contiene un sistema de archivos `xfs`):

   ```bash
   pcs resource create WebFS ocf:heartbeat:Filesystem \
       device="/dev/disk/by-id/scsi-360014...-web" \
       directory="/var/www/html" fstype="xfs" \
       op monitor interval=20s timeout=40s
   ```

3. Creá la VIP flotante:

   ```bash
   pcs resource create ClusterVIP ocf:heartbeat:IPaddr2 \
       ip=192.168.122.100 cidr_netmask=24 \
       op monitor interval=30s
   ```

4. Creá el servidor web. Acá usamos el agente **OCF** `apache` (puede sondear `server-status`), no la unidad systemd simple, para mostrar un agente más inteligente:

   ```bash
   pcs resource create WebSite ocf:heartbeat:apache \
       configfile="/etc/httpd/conf/httpd.conf" \
       statusurl="http://127.0.0.1/server-status" \
       op monitor interval=1min
   ```

5. Uní los tres en un **grupo de recursos**. Un grupo es una abreviatura: los miembros se colocan (colocation) en el mismo nodo *y* se arrancan en el orden listado (se detienen en orden inverso):

   ```bash
   pcs resource group add WebStack WebFS ClusterVIP WebSite
   ```

6. Agregá una preferencia explícita de **location** para que el stack favorezca a `node1` cuando pueda, sin fijarlo ahí:

   ```bash
   pcs constraint location WebStack prefers node1=50
   ```

7. Revisá el grafo de restricciones y dónde terminaron realmente las cosas:

   ```bash
   pcs constraint --full
   pcs status resources
   ```
   ```
     * Resource Group: WebStack:
       * WebFS       (ocf:heartbeat:Filesystem):   Started node1
       * ClusterVIP  (ocf:heartbeat:IPaddr2):      Started node1
       * WebSite     (ocf:heartbeat:apache):       Started node1
   ```

**Verificación de comprensión 4**

- **4a.** Agrupaste `WebFS → ClusterVIP → WebSite`. Escribí las dos restricciones *explícitas* (una de colocation, una de ordering) que un grupo crea implícitamente entre `WebFS` y `WebSite`. ¿Qué score usa la colocation implícita?
- **4b.** La restricción de location usa el score `50`, pero una colocation dentro de un grupo usa `INFINITY`. ¿Qué tiene de especial el score `INFINITY` en la aritmética de Pacemaker, y por qué `prefers node1=50` *no* alcanzaría para anular una regla de location `-INFINITY`?
- **4c.** El paso 4 usa `ocf:heartbeat:apache` en lugar de `systemd:httpd`. Dá una capacidad de monitoreo concreta que tiene el agente OCF y que el recurso de clase `systemd` simple no tiene.
- **4d.** Si hubieras creado los tres recursos *sin* un grupo y *sin* restricciones, describí una ubicación válida pero inútil que Pacemaker podría elegir.

---

## Ejercicio 5 — Provocar un failover y gestionar el estado de nodos/recursos

1. Observá el cluster en vivo en una terminal (`-Arf` muestra atributos, failcounts y operaciones pendientes):

   ```bash
   crm_mon -Arf
   ```

2. En otra terminal, poné `node1` en **standby** — sigue siendo miembro del cluster y sigue votando, pero no aloja ningún recurso:

   ```bash
   pcs node standby node1
   ```
   Todo el `WebStack` debería reubicarse en `node2` (o `node3`) como una sola unidad. Confirmá:

   ```bash
   pcs status resources
   ```
   ```
     * Resource Group: WebStack:
       * WebFS       (ocf:heartbeat:Filesystem):   Started node2
       * ClusterVIP  (ocf:heartbeat:IPaddr2):      Started node2
       * WebSite     (ocf:heartbeat:apache):       Started node2
   ```

3. Traé de vuelta `node1`:

   ```bash
   pcs node unstandby node1
   ```
   Notá que el stack **se queda en node2** aunque `node1` esté preferido con score 50 — los recursos son "sticky" una vez en ejecución (`resource-stickiness` por defecto). 

4. Ahora forzá un movimiento a un nodo específico. `pcs resource move` crea una regla de location `-INFINITY` temporal:

   ```bash
   pcs resource move WebStack node3
   pcs constraint --full | grep cli-
   ```
   ```
     Location Constraints:
       Constraint: cli-prefer-WebStack
         Rule: score=INFINITY  ... #uname eq node3
   ```

5. **Limpiá la restricción que quedó** para que la planificación futura vuelva a ser libre (olvidarse de esto es una trampa clásica de examen y una causa real de caídas):

   ```bash
   pcs resource clear WebStack
   ```

6. Simulá una falla real. Matá el proceso de Apache por debajo de Pacemaker en el nodo activo y observá cómo la operación de monitor lo detecta:

   ```bash
   ssh node3 'pkill -9 httpd'
   ```
   Dentro de un `monitor interval` el recurso se marca como fallado y se recupera (se reinicia en el lugar, o se reubica si sigue fallando). Inspeccioná el contador de fallas:

   ```bash
   pcs resource failcount show WebSite
   ```
   ```
   Failcounts for resource 'WebSite'
     node3: 1
   ```

7. Reiniciá el historial de fallas después de haber entendido la causa:

   ```bash
   pcs resource cleanup WebSite
   ```

**Verificación de comprensión 5**

- **5a.** En el paso 3, `node1` está preferido (score 50) pero el recurso no volvió después de `unstandby`. ¿Qué propiedad de cluster/recurso contrarresta la preferencia de location, y qué problema del mundo real previene?
- **5b.** `pcs resource move` "funcionó", pero el paso 5 igual fue necesario. Explicá *mecánicamente* qué deja atrás `move` y qué saldría mal en la próxima falla de nodo si nunca ejecutaras `pcs resource clear`.
- **5c.** Un recurso con `migration-threshold=3` alcanza un failcount de 3 en `node3`. ¿Qué hace Pacemaker a continuación, y cómo interactúa `failure-timeout` con eso?
- **5d.** Contrastá **standby** (paso 2) con **fencing** (Ejercicio 3). Ambos sacan un nodo de servicio — ¿por qué solo uno es seguro de disparar para mantenimiento planificado, y por qué standby no puede sustituir al fencing durante un split-brain real?

---

## Ejercicio 6 — El mismo cluster a través de `crmsh`

`pcs` y `crmsh` (`crm`) son dos front-ends de la *misma* CIB. SUSE trae `crmsh`; RHEL trae `pcs`; el examen espera fluidez en ambos. Nada de lo que sigue cambia el diseño — vuelve a leer y edita levemente el cluster en ejecución.

1. Estado y monitor en vivo vía `crmsh`:

   ```bash
   crm status
   crm_mon -1
   ```

2. Volcá toda la configuración en la sintaxis compacta de `crmsh`:

   ```bash
   crm configure show
   ```
   ```
   node 1: node1
   node 2: node2
   node 3: node3
   primitive ClusterVIP IPaddr2 params ip=192.168.122.100 cidr_netmask=24 \
       op monitor interval=30s
   primitive WebFS Filesystem params device="/dev/disk/by-id/...-web" \
       directory="/var/www/html" fstype=xfs op monitor interval=20s
   primitive WebSite apache params configfile="/etc/httpd/conf/httpd.conf" \
       op monitor interval=1min
   primitive sbd-fence stonith:fence_sbd params devices="/dev/...-sbd"
   group WebStack WebFS ClusterVIP WebSite
   location cli-WebStack-on-node1 WebStack 50: node1
   property cib-bootstrap-options: stonith-enabled=true ...
   ```

3. Ejecutá el planificador en seco (dry-run): preguntá "¿qué *pasaría* ahora mismo?" sin cambiar nada. `crm_simulate` lee la CIB en vivo e imprime el grafo de transición:

   ```bash
   crm_simulate -sL
   ```

4. Hacé una edición a través de `crmsh` para demostrar la paridad — subí la frecuencia de monitor de la VIP — luego verificá con `pcs` que ambos front-ends la ven:

   ```bash
   crm configure edit ClusterVIP     # opens $EDITOR on that primitive
   pcs resource config ClusterVIP    # confirm the change via the other tool
   ```

5. Poné en standby/quitá del standby un nodo a la manera de `crmsh`:

   ```bash
   crm node standby node2
   crm node online node2
   ```

**Verificación de comprensión 6**

- **6a.** Cambiaste el intervalo de monitor de la VIP con `crm configure edit` y lo confirmaste con `pcs resource config`. ¿Qué objeto compartido hace que ambas herramientas coincidan, y dónde vive físicamente y se replica?
- **6b.** `crm_simulate -sL` informó una transición aunque no cambiaste nada. ¿Para qué sirve `crm_simulate`, y cómo lo usarías *antes* de un cambio riesgoso para predecir las consecuencias?
- **6c.** Mapeá estos verbos de `crmsh` a sus equivalentes en `pcs`: `crm node standby`, `crm configure show`, `crm resource cleanup`, `crm status`.

---

## Ejercicio 7 (a nivel de conocimiento) — Failover multi-sitio con Booth

Un único cluster Pacemaker asume enlaces de baja latencia; no puede estirarse a través de sitios geográficamente separados y seguir haciendo fencing de forma segura. **Booth** coordina *entre* clusters Pacemaker independientes usando un **ticket** que una mayoría de arbitradores le otorga a exactamente un sitio a la vez.

1. Leé el esqueleto de configuración de Booth (no lo despliegues — esto es a nivel de conocimiento):

   ```bash
   cat /etc/booth/booth.conf
   ```
   ```
   transport = UDP
   port = 9929
   arbitrator = 192.0.2.50
   site = 198.51.100.10        # cluster at site A
   site = 203.0.113.10         # cluster at site B
   ticket = "web-ticket"
       expire = 600
   ```

2. Observá cómo un ticket controla un grupo de recursos para que se ejecute en **un solo sitio**:

   ```bash
   pcs constraint ticket add web-ticket WebStack loss-policy=fence
   booth ticket grant web-ticket
   ```

**Verificación de comprensión 7**

- **7a.** ¿Por qué Booth necesita un número impar de participantes (sitios + arbitradores), y cuál es la *única* tarea del arbitrador?
- **7b.** La restricción de ticket fija `loss-policy=fence`. Si el sitio A pierde el `web-ticket`, ¿qué le pasa a `WebStack` en el sitio A, y por qué es esa la opción segura para un cluster estirado?

---

<details>
<summary><strong>Respuestas</strong> (clic para expandir)</summary>

### Ejercicio 1

- **1a.** `pcsd` es el demonio de **configuración/gestión** — un plano de control REST + CLI en el puerto 2224 que autentica nodos y envía configuración; *no* es parte de la ruta de datos, así que una vez configurado el cluster podés detener `pcsd` y los recursos siguen corriendo (solo perdés la gestión cómoda). `corosync` es la capa de **mensajería/membresía/quorum** (protocolo totem + votequorum). `pacemaker` es el **gestor de recursos del cluster** que decide dónde corren los recursos e impulsa start/stop/monitor/fence. El que no necesitás estrictamente en ejecución para que continúe el servicio es **`pcsd`**.
- **1b.** `pcs cluster setup` distribuye archivos (`corosync.conf`, la authkey de Corosync) a los otros nodos por el canal de `pcsd`. Ese canal solo es de confianza después de que `pcs host auth` establece un token mutuo entre los nodos. Sin el paso 4, `setup` no tiene una ruta autenticada para escribir en `node2`/`node3` y falla.
- **1c.** Tres nodos → tres votos presentes; quorum = `floor(expected/2) + 1 = floor(3/2)+1 = 2`. "Partition" es el término de Corosync para el conjunto de nodos que en ese momento pueden verse entre sí; "partition with quorum" significa que el nodo local está en un grupo que tiene ≥ 2 votos y por lo tanto tiene permitido ejecutar recursos.

### Ejercicio 2

- **2a.** `Quorum = floor(3/2)+1 = 2`. Con cuatro nodos, `Quorum = floor(4/2)+1 = 3`. Una partición limpia 2/2 de un cluster de 4 nodos deja a **ninguno** de los lados con 3 votos, así que *ambas* particiones pierden el quorum y detienen todos los recursos — una cantidad par de nodos no te da tolerancia a fallos extra sobre la cantidad impar inmediatamente inferior, y agrega un modo de falla por empate. (Por esto se prefieren los dispositivos de quorum / las cantidades impares.)
- **2b.** `pcs` agrega `two_node: 1` automáticamente cuando el cluster se crea con exactamente **dos** nodos. Habilita (1) un quorum efectivo de 1 para que un único nodo sobreviviente siga con quorum, y (2) `wait_for_all` en el arranque para que el cluster no asuma quorum hasta que ambos nodos se hayan visto al menos una vez (evitando que un nodo solitario haga fencing a su par sano en el arranque).
- **2c.** `corosync-cfgtool -s` — informa el estado de **link/anillo** por nodo. Un anillo puede romperse (link `status: … 2: disconnected`) antes de que el nodo sea completamente expulsado de la membresía, así que la vista de link de cfgtool expone primero la falla de red.

### Ejercicio 3

- **3a.** Los dos componentes son el **slot de disco compartido** y el **watchdog de hardware/software**. El slot de disco le permite a un nodo sano *decirle* a un objetivo que muera escribiendo un mensaje de poison-pill; el watchdog garantiza que un nodo colgado, o que perdió el acceso al dispositivo de slot, **se reinicie a sí mismo** porque ya no puede acariciar (pet) `/dev/watchdog`. El watchdog es indispensable porque un nodo que no puede leer su poison-pill (p. ej. ruta de almacenamiento caída, cuelgue de kernel) nunca moriría voluntariamente — el watchdog hace que "ya no puedo probar que estoy sano" equivalga a "me reinicio a mí mismo", que es lo que vuelve incondicional la garantía de muerte de SBD.
- **3b.** Con `stonith-enabled=true` y sin dispositivo que funcione, Pacemaker **bloqueará la recuperación**: se niega a arrancar el recurso afectado en otro lado porque no puede confirmar que la ubicación anterior está muerta. Los recursos que necesitan recuperación condicionada por fencing quedan detenidos hasta que un fence tenga éxito — el cluster elige deliberadamente la indisponibilidad antes que arriesgar un split-brain.
- **3c.** En una partición simétrica de dos nodos, ambos nodos deciden hacer fencing al otro simultáneamente y pueden matarse mutuamente ("fence race" → ambos caídos). Un **retardo** de fencing hace que un nodo se detenga antes de disparar; el nodo sin retardo gana la carrera y sobrevive. Se aplica de forma asimétrica (retardo en un solo nodo, p. ej. vía `pcmk_delay_base`/`priority-fencing-delay`) precisamente para que haya un ganador determinista en lugar de un empate.
- **3d.** El **SBD sin disco** no tiene dispositivo de slot compartido; se apoya **por completo en el watchdog más el quorum** — un nodo que pierde el quorum simplemente deja de acariciar el watchdog y se hace fencing a sí mismo. No tiene forma de enviar una poison-pill positiva a otro nodo, así que necesita una señal de quorum confiable y realistamente **tres o más nodos** (o un dispositivo de quorum) para evitar que ambas particiones se hagan fencing a sí mismas ante un empate.

### Ejercicio 4

- **4a.** Un grupo `WebFS ClusterVIP WebSite` implica, entre los extremos `WebFS` y `WebSite`: una colocation `colocation … WebSite with WebFS INFINITY` (mismo nodo, obligatoria) y un ordering `order … WebFS then WebSite` (arrancar WebFS primero, detenerlo último). El score de la colocation implícita es **`INFINITY`**.
- **4b.** `INFINITY` (y `-INFINITY`) se tratan como absolutos, no solo como grandes: cualquier score finito sumado a `-INFINITY` sigue siendo `-INFINITY`. Así que una regla obligatoria (`INFINITY`/`-INFINITY`) siempre gana sobre cualquier preferencia finita de tipo consultivo. `prefers node1=50` es un empujón *finito*; puede perder ante la stickiness o ante cualquier regla `-INFINITY` de "nunca correr acá", que no se puede contrapesar sumando 50.
- **4c.** El agente OCF `apache` puede realizar un **sondeo de salud a nivel de aplicación** — obtiene `statusurl` (`/server-status`) y considera el recurso como fallado si el chequeo HTTP falla, atrapando un demonio colgado-pero-en-ejecución. El recurso `systemd:httpd` simple solo sabe si systemd informa la unidad como activa, así que un servidor trabado que todavía muestra "active" pasaría inadvertido.
- **4d.** Sin restricciones, Pacemaker balancea la carga por defecto y podría colocar `WebFS` en `node1`, `ClusterVIP` en `node2`, y `WebSite` en `node3` — cada pieza "corriendo", pero Apache no tiene ni sistema de archivos ni VIP en su nodo, así que el servicio es completamente no funcional.

### Ejercicio 5

- **5a.** `resource-stickiness` (un score de stickiness positivo por defecto) hace que un recurso ya en ejecución "prefiera quedarse donde está". Cuando la stickiness ≥ la preferencia de location (50), el recurso no migra de vuelta al nodo preferido después de que este regresa. Esto evita un failback innecesario y disruptivo del servicio (y el flapping) solo porque un nodo preferido volvió a unirse.
- **5b.** `pcs resource move` implementa el movimiento inyectando una restricción de location `cli-prefer-*` permanente en `INFINITY` que fija el recurso al nodo objetivo. Si nunca la limpiás (`clear`), ese nodo es ahora el *único* lugar donde el recurso está dispuesto a correr; cuando ese nodo falle más adelante, Pacemaker no puede reubicar el recurso y el servicio queda caído — el "move" deshabilitó silenciosamente el failover.
- **5c.** Alcanzar el `migration-threshold` en un nodo vuelve a ese nodo **no elegible** para el recurso (efectivamente `-INFINITY` ahí), forzando la reubicación a otro nodo. `failure-timeout` hace caducar las fallas viejas después de un intervalo fijado, decayendo el failcount para que el nodo vuelva a ser elegible automáticamente en lugar de quedar vetado para siempre.
- **5d.** **Standby** es un cambio de estado *cooperativo*: el nodo está sano y acepta ceder sus recursos, que se detienen y mueven limpiamente — seguro para mantenimiento planificado. **Fencing** es para un nodo *no cooperativo o desconocido*: no podés confiar en que se detenga limpiamente, así que le cortás la energía/lo reiniciás. Standby no puede sustituir al fencing en un split-brain porque a un nodo particionado no se le puede *pedir* que entre en standby — no tenés comunicación con él, y solo un fence forzoso puede garantizar que no siga escribiendo en el almacenamiento compartido.

### Ejercicio 6

- **6a.** Ambos front-ends leen y escriben la **CIB (Cluster Information Base)**, un documento XML gestionado por el demonio `pacemaker-based` (CIB) de Pacemaker. Vive en `/var/lib/pacemaker/cib/cib.xml` en cada nodo y se **replica automáticamente** a todos los nodos, así que un cambio hecho a través de `crmsh` es inmediatamente visible para `pcs` y viceversa.
- **6b.** `crm_simulate` ejecuta el **motor de políticas offline** contra una CIB para mostrar el grafo de transición que *ejecutaría* — qué recursos arranca/detiene/mueve/hace fencing — sin tocar el cluster. Antes de un cambio riesgoso guardás la CIB, aplicás el cambio a esa copia, y lo simulás (p. ej. `crm_simulate -Sx new.xml`) para ver las consecuencias (reinicios inesperados, un fence, una reubicación del stack) *antes* de confirmar.
- **6c.** `crm node standby` → `pcs node standby`; `crm configure show` → `pcs config` / `pcs resource config` (completo: `pcs cluster cib`); `crm resource cleanup` → `pcs resource cleanup`; `crm status` → `pcs status`.

### Ejercicio 7

- **7a.** Booth otorga un ticket por **voto mayoritario**, así que el número total de participantes (sitios + arbitradores) debe ser **impar** para garantizar una mayoría decisiva y evitar que dos sitios reclamen ambos el ticket. La única tarea del arbitrador es ser un **votante de desempate** — no ejecuta recursos; existe puramente para hacer impar el total de votos y decidir qué sitio tiene el ticket.
- **7b.** Con `loss-policy=fence`, si el sitio A pierde `web-ticket`, Pacemaker en el sitio A **hace fencing a sus propios nodos** que ejecutan `WebStack`, garantizando que se detengan antes de que al sitio B se le permita arrancar los mismos recursos. Para un cluster multi-sitio estirado esta es la opción segura: se asegura absolutamente de que la carga de trabajo (y cualquier escritura de datos compartidos) se ejecute en exactamente un sitio, eliminando el split-brain entre sitios incluso cuando el enlace inter-sitio desaparece.

</details>

---

### Fuentes

- LPI — Exam 306 Objectives, Topic 361.3 *Failover Clusters*: https://www.lpi.org/our-certifications/exam-306-objectives/
- ClusterLabs — *Pacemaker Administration* y *Pacemaker Explained*: https://clusterlabs.org/pacemaker/doc/
- ClusterLabs — páginas de manual `votequorum(5)` y `corosync.conf(5)` de Corosync: https://clusterlabs.org/corosync.html
- Manual de `pcs`(8), ClusterLabs: https://clusterlabs.org/pcs/
- Documentación de `crmsh` (SUSE/ClusterLabs): https://crmsh.github.io/
- SBD — demonio Storage-Based Death: https://github.com/ClusterLabs/sbd
- Booth — Cluster Ticket Manager: https://github.com/ClusterLabs/booth