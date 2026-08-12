# Tema 361.3: Failover Clusters — Ejercicios guiados

> **Certificación:** LPIC-3 306 (examen 306-300, v3.0) · **Objetivo 361.3** — Peso 13.34
> **Stack:** Corosync 3.x (kronosnet) + Pacemaker 2.x, gestionado con `pcs` (RHEL/AlmaLinux/Rocky 9) y referencias equivalentes en `crmsh` (SUSE/Debian).
> **Fuentes oficiales:**
> - LPI, *Exam 306 Objectives* — https://www.lpi.org/our-certifications/exam-306-objectives/
> - ClusterLabs, *Pacemaker — Clusters from Scratch / Configuration Explained* — https://clusterlabs.org/pacemaker/doc/
> - Corosync, *corosync.conf(5)* — https://manpages.org/corosconf/5 · proyecto: https://corosync.github.io/corosync/
> - ClusterLabs, *pcs* — https://clusterlabs.org/projects/pcs/
> - ClusterLabs, *booth (multi-site)* — https://github.com/ClusterLabs/booth

## Entorno de laboratorio

Dos nodos KVM (o físicos), red de gestión `192.168.122.0/24`, un hypervisor con `fence_virt`/`fence_xvm` disponible para STONITH real, y una VIP libre en `192.168.122.100`.

```
node1  192.168.122.11
node2  192.168.122.12
VIP    192.168.122.100   (recurso a gestionar)
```

Salvo indicación contraria, los comandos `pcs` se ejecutan desde `node1` como `root`. Todos los nodos comparten `/etc/hosts` con las tres entradas anteriores y tienen la hora sincronizada con `chrony` (requisito de membership de `totem`).

---

## Ejercicio 1 — Bootstrap: instalar, autenticar y levantar el cluster

**Objetivo:** entender la capa de messaging (Corosync/totem) y la de gestión (Pacemaker/pcsd), y cómo `pcs` genera `corosync.conf` y el `authkey`.

1. Instalá la pila y el daemon de gestión **en ambos nodos**:

   ```bash
   dnf install -y pacemaker corosync pcs fence-agents-all
   systemctl enable --now pcsd
   ```

2. Fijá la contraseña del usuario de cluster **en ambos nodos** (lo crea el paquete):

   ```bash
   echo 'S3cr3t-HA!' | passwd --stdin hacluster
   ```

3. Autenticá los nodos entre sí (esto establece el token de `pcsd`, no toca Corosync todavía):

   ```bash
   pcs host auth node1 node2 -u hacluster -p 'S3cr3t-HA!'
   ```
   ```
   node1: Authorized
   node2: Authorized
   ```

4. Creá el cluster. `pcs` escribe `/etc/corosync/corosync.conf` idéntico en ambos nodos y **genera y distribuye** `/etc/corosync/authkey`:

   ```bash
   pcs cluster setup ha_prod node1 addr=192.168.122.11 node2 addr=192.168.122.12
   pcs cluster start --all
   pcs cluster enable --all
   ```

5. Inspeccioná el `corosync.conf` generado:

   ```bash
   cat /etc/corosync/corosync.conf
   ```
   ```
   totem {
       version: 2
       cluster_name: ha_prod
       transport: knet
       crypto_cipher: aes256
       crypto_hash: sha256
   }
   nodelist {
       node { ring0_addr: 192.168.122.11  name: node1  nodeid: 1 }
       node { ring0_addr: 192.168.122.12  name: node2  nodeid: 2 }
   }
   quorum {
       provider: corosync_votequorum
       two_node: 1
   }
   logging { to_logfile: yes  logfile: /var/log/cluster/corosync.log  to_syslog: yes }
   ```

6. Verificá el anillo de comunicación y el estado de quorum a bajo nivel:

   ```bash
   corosync-cfgtool -s
   ```
   ```
   Local node ID 1, transport knet
   LINK ID 0 udp
       addr = 192.168.122.11
       status:
           nodeid:   1:  localhost
           nodeid:   2:  connected
   ```

7. Mirá el estado global con la vista de Pacemaker:

   ```bash
   pcs status
   crm_mon -1
   ```
   ```
   Cluster name: ha_prod
   Cluster Summary:
     * Stack: corosync (Pacemaker is running)
     * Current DC: node1 (version 2.1.x) - partition with quorum
     * 2 nodes configured
     * 0 resource instances configured
   Node List:
     * Online: [ node1 node2 ]
   ```

> **Preguntas de comprensión (P1)**
> 1. ¿Qué dos "capas" distintas gestionás en los pasos 3 y 4, y por qué la autenticación de `pcsd` es independiente de que Corosync arranque?
> 2. En el paso 4 `pcs` crea `/etc/corosync/authkey`. ¿Qué protege ese archivo y qué campos de `totem` lo activan? ¿Qué pasa si un nodo tiene un `authkey` distinto?
> 3. El `pcs status` reporta un **Current DC**. ¿Qué es el DC, qué componente de Pacemaker corre en él y qué ocurre si ese nodo cae?
> 4. Diferenciá `transport: knet` de `udpu`. ¿Por qué `knet` permite `crypto_cipher`/`crypto_hash` y múltiples links de forma nativa?

---

## Ejercicio 2 — Quorum, votequorum y el problema del cluster de dos nodos

**Objetivo:** comprender por qué un cluster de 2 nodos es un caso especial y cómo `two_node`, `wait_for_all` y `no-quorum-policy` interactúan para evitar split-brain.

1. Consultá el estado de quorum desde Corosync:

   ```bash
   corosync-quorumtool -s
   ```
   ```
   Quorum information
   ------------------
   Nodes:             2
   Node ID:           1
   Ring ID:           1.1a
   Quorate:           Yes
   Votequorum information
   ----------------------
   Expected votes:    2
   Highest expected:  2
   Total votes:       2
   Quorum:            1
   Flags:             2Node Quorate WaitForAll
   ```

2. Observá que con `two_node: 1`, Corosync fija `Quorum: 1` y activa `WaitForAll`. Revisá la política de Pacemaker ante pérdida de quorum:

   ```bash
   pcs property config no-quorum-policy
   ```
   ```
   Cluster Properties: no-quorum-policy
     no-quorum-policy: stop   (default)
   ```

3. Simulá la pérdida de un nodo y observá que el superviviente **mantiene** quorum (gracias a `two_node`):

   ```bash
   # En node2:
   pcs cluster stop
   # En node1:
   corosync-quorumtool -s | grep -E 'Quorate|Total'
   ```
   ```
   Total votes:       1
   Quorate:           Yes
   ```

4. Volvé a levantar `node2` y confirmá que `WaitForAll` obliga a ver a **ambos** nodos tras un arranque en frío antes de otorgar quorum:

   ```bash
   pcs cluster start   # en node2
   corosync-quorumtool -s | grep Flags
   ```

5. (Concepto de escala) En clusters de 3+ nodos, en vez de `two_node` se usa un árbitro de votos. Mostrá cómo se declararía un **qdevice**:

   ```bash
   pcs quorum config
   # Configuración típica con árbitro externo:
   #   pcs quorum device add model net host=qnetd.example.com algorithm=ffsplit
   ```

> **Preguntas de comprensión (P2)**
> 1. Con `two_node: 1` el quorum efectivo es 1. ¿Qué peligro reintroduce esto y qué mecanismo (obligatorio en 361.3) es el que realmente evita el split-brain en un cluster de 2 nodos?
> 2. ¿Qué hace la flag `WaitForAll` y qué escenario concreto de "doble arranque" previene?
> 3. Explicá las tres opciones de `no-quorum-policy` (`stop`, `ignore`, `freeze`) y en qué situación elegirías cada una.
> 4. ¿Para qué sirve un `qdevice`/`qnetd` y en qué se diferencia del algoritmo `ffsplit` vs `lms`?

---

## Ejercicio 3 — El primer recurso: VIP con el resource agent `IPaddr2`

**Objetivo:** entender las **clases de recursos** (OCF, systemd, lsb, service, stonith), providers, agentes, operaciones (`monitor`/`start`/`stop`) y meta-atributos.

1. Enumerá las clases de recursos, los providers OCF y los agentes de un provider:

   ```bash
   pcs resource standards
   ```
   ```
   lsb
   ocf
   service
   systemd
   ```
   ```bash
   pcs resource providers
   ```
   ```
   heartbeat
   openstack
   pacemaker
   ```
   ```bash
   pcs resource agents ocf:heartbeat | head
   ```
   ```
   IPaddr2
   Filesystem
   apache
   nfsserver
   ...
   ```

2. Inspeccioná los parámetros que espera el agente antes de usarlo:

   ```bash
   pcs resource describe ocf:heartbeat:IPaddr2 | head -n 20
   ```

3. Creá la VIP. `op monitor interval=30s` define el chequeo periódico de salud:

   ```bash
   pcs resource create VIP ocf:heartbeat:IPaddr2 \
       ip=192.168.122.100 cidr_netmask=24 nic=eth0 \
       op monitor interval=30s timeout=20s \
       op start timeout=20s op stop timeout=20s
   ```

4. Verificá dónde quedó activa y comprobalo en el kernel:

   ```bash
   pcs status resources
   ```
   ```
   * VIP  (ocf:heartbeat:IPaddr2):   Started node1
   ```
   ```bash
   ip -o addr show eth0 | grep 192.168.122.100
   ```

5. Provocá un failover manual moviendo el recurso y observá la migración:

   ```bash
   pcs resource move VIP node2
   crm_mon -1 | grep VIP
   ```
   ```
   * VIP  (ocf:heartbeat:IPaddr2):   Started node2
   ```

6. `pcs resource move` crea una **constraint de location permanente** implícita. Limpiala para no fijar el recurso:

   ```bash
   pcs constraint location config --full   # verás la regla cli-prefer-VIP
   pcs resource clear VIP
   ```

> **Preguntas de comprensión (P3)**
> 1. Nombrá las cinco clases de recursos que reporta Pacemaker y explicá la diferencia semántica entre un agente `ocf:heartbeat:apache` y uno `systemd:httpd`. ¿Cuál puede hacer *monitor* con mayor granularidad y por qué?
> 2. Un OCF resource agent es un script que devuelve códigos estandarizados. ¿Qué significan `OCF_SUCCESS (0)`, `OCF_NOT_RUNNING (7)` y `OCF_ERR_CONFIGURED (6)`, y por qué Pacemaker trata `6` distinto de `1`?
> 3. En el paso 5, `pcs resource move` "funcionó" pero dejó un efecto colateral que corregiste en el paso 6. ¿Cuál fue y por qué es peligroso olvidarlo?
> 4. ¿Qué diferencia hay entre las operaciones `start`, `stop` y `monitor`, y qué pasa si el `timeout` de `monitor` es menor que el tiempo real de respuesta del servicio?

---

## Ejercicio 4 — Grupos y constraints: colocation, order y location

**Objetivo:** modelar una dependencia real (Filesystem → VIP → Apache) con las tres constraints fundamentales y con la abstracción de **resource group**.

1. Creá los recursos de una pila web (asumiendo un DRBD/almacenamiento ya montado en `/dev/vg_ha/lv_web`):

   ```bash
   pcs resource create WebFS ocf:heartbeat:Filesystem \
       device=/dev/vg_ha/lv_web directory=/var/www/html fstype=xfs \
       op monitor interval=20s
   pcs resource create WebSite ocf:heartbeat:apache \
       configfile=/etc/httpd/conf/httpd.conf \
       statusurl="http://127.0.0.1/server-status" \
       op monitor interval=1min
   ```

2. **Opción A — Constraints explícitas.** El sitio debe correr *con* la VIP, y el orden debe ser FS → VIP → Apache:

   ```bash
   pcs constraint colocation add WebSite with VIP INFINITY
   pcs constraint colocation add VIP with WebFS INFINITY
   pcs constraint order WebFS then VIP
   pcs constraint order VIP then WebSite
   ```

3. **Opción B — Resource group** (equivalente y más legible: colocation + order implícitos, en el orden listado):

   ```bash
   pcs resource group add WebStack WebFS VIP WebSite
   ```

4. Preferí que la pila corra en `node1` cuando sea posible, sin fijarla de forma absoluta:

   ```bash
   pcs constraint location WebStack prefers node1=200
   ```

5. Revisá el grafo de constraints y validá la CIB antes de confiar en ella:

   ```bash
   pcs constraint config
   crm_verify -LV
   ```
   ```
   (sin salida = configuración válida)
   ```

6. Consultá el efecto de los scores en la ubicación:

   ```bash
   crm_simulate -sL | grep -A2 'Allocation Scores'
   ```

> **Preguntas de comprensión (P4)**
> 1. ¿Qué significa un score de `INFINITY` en una colocation frente a un `200`? Si `colocation add A with B INFINITY` y B no puede arrancar en ningún lado, ¿qué le pasa a A?
> 2. `colocation add WebSite with VIP` fija *dónde* corren juntos, pero no *en qué orden* arrancan. ¿Por qué necesitás además una `order` constraint, y qué desastre ocurre sin ella?
> 3. El `resource group` del paso 3 reemplaza a las cuatro constraints del paso 2. Explicá exactamente qué colocation y qué order impone un grupo, y en qué dirección se detienen los recursos ante un fallo.
> 4. La location del paso 4 usa `prefers node1=200`. ¿Es lo mismo que `INFINITY`? ¿Qué diferencia hay entre una location "opt-in" y una "opt-out", y cómo se combina el `200` con el `resource-stickiness` por defecto?

---

## Ejercicio 5 — STONITH / fencing: sin esto, no hay HA real

**Objetivo:** configurar un dispositivo de fencing, entender por qué es obligatorio y ver cómo Pacemaker "acuchilla" a un nodo perdido antes de recuperar sus recursos.

1. Confirmá el estado por defecto y por qué Pacemaker se queja si está deshabilitado:

   ```bash
   pcs property config stonith-enabled
   crm_verify -LV
   ```
   ```
   error: Resource start-up disabled since no STONITH resources have been defined
   error: Either configure some or disable STONITH with the stonith-enabled option
   ```

2. Listá los fence agents disponibles y describí el que usa el hypervisor KVM:

   ```bash
   pcs stonith list | grep -E 'fence_xvm|fence_virt|fence_ipmilan'
   pcs stonith describe fence_xvm | head -n 15
   ```

3. Creá el dispositivo STONITH. `pcmk_host_map` traduce el nombre de nodo Pacemaker al nombre de la VM en el hypervisor:

   ```bash
   pcs stonith create fence_vms fence_xvm \
       pcmk_host_map="node1:vm-node1;node2:vm-node2" \
       key_file=/etc/cluster/fence_xvm.key \
       op monitor interval=60s
   pcs property set stonith-enabled=true
   ```

4. Verificá que el fencing "ve" a ambos nodos:

   ```bash
   pcs stonith status
   fence_xvm -o list -k /etc/cluster/fence_xvm.key
   ```

5. **Prueba controlada de fencing.** Acuchillá deliberadamente a `node2` y observá cómo Pacemaker confirma la muerte y reubica sus recursos:

   ```bash
   pcs stonith fence node2
   pcs status | grep -A3 'Fencing'
   ```
   ```
   Fencing History:
     * reboot of node2 successful: delegate=node1, ... completed
   ```

6. (Doble fencing / fence race) En clusters de 2 nodos, definí un **delay** en uno de los dispositivos para que, ante un split, gane siempre el mismo nodo y no se maten mutuamente:

   ```bash
   pcs stonith update fence_vms pcmk_delay_base=node1:0s;node2:10s
   ```

> **Preguntas de comprensión (P5)**
> 1. Explicá con tus palabras por qué Pacemaker se **niega a arrancar recursos** sin STONITH configurado (paso 1). ¿Qué garantiza el fencing que ni el quorum ni el heartbeat pueden garantizar por sí solos?
> 2. Un nodo deja de responder al heartbeat pero podría seguir escribiendo en el almacenamiento compartido. ¿Cómo se llama este escenario y por qué recuperar sus recursos *sin* fencerlo corrompería los datos?
> 3. ¿Qué hace `pcmk_host_map` y por qué es necesario cuando el nombre del nodo en Pacemaker no coincide con el identificador que entiende el fence agent?
> 4. En el paso 6 agregaste un `pcmk_delay_base` asimétrico. ¿Qué problema de "fence race" resuelve en un cluster de 2 nodos y qué habría pasado sin él ante una partición de red simétrica?

---

## Ejercicio 6 — Clones, standby, y predicción con `crm_simulate`

**Objetivo:** desplegar un recurso activo/activo (clone), ejercitar failover por `standby`, limpiar fallos y **predecir** decisiones del scheduler sin aplicarlas.

1. Cloná un recurso que debe correr en **todos** los nodos (ej. un daemon `ping`/connectivity o `clvmd`). Ejemplo con un recurso de conectividad:

   ```bash
   pcs resource create net_ping ocf:pacemaker:ping \
       dampen=5s multiplier=1000 host_list=192.168.122.1 \
       op monitor interval=10s clone
   ```
   ```bash
   pcs status resources | grep -A2 net_ping
   ```
   ```
   * Clone Set: net_ping-clone [net_ping]
     * Started: [ node1 node2 ]
   ```

2. Usá el atributo del clone en una **location rule** para desalojar la pila web de un nodo sin gateway:

   ```bash
   pcs constraint location WebStack rule score=-INFINITY \
       pingd lt 1 or not_defined pingd
   ```

3. Poné `node1` en **standby** (mantenimiento planificado) y observá la migración completa del grupo:

   ```bash
   pcs node standby node1
   crm_mon -1
   ```
   ```
   Node List:
     * Node node1: standby
     * Online: [ node2 ]
   * Resource Group: WebStack
     * WebFS   (...): Started node2
     * VIP     (...): Started node2
     * WebSite (...): Started node2
   ```

4. Devolvé `node1` al servicio:

   ```bash
   pcs node unstandby node1
   ```

5. **Predecí sin aplicar.** Antes de tocar producción, pedile al scheduler que muestre qué haría, y forzá un fallo hipotético:

   ```bash
   crm_simulate -sL                        # estado y scores actuales
   crm_simulate -S -i "WebSite_monitor_60000@node1=1"   # inyecta un fallo de monitor
   ```

6. Cuando un recurso queda en estado `FAILED` por un fallo transitorio ya resuelto, limpiá el contador de fallos para permitir su re-arranque:

   ```bash
   pcs resource failcount show WebSite
   pcs resource cleanup WebSite
   ```

> **Preguntas de comprensión (P6)**
> 1. ¿Qué diferencia hay entre un recurso normal, un `clone` y un `promotable clone` (antes *master/slave*)? Dá un ejemplo real de cada uno.
> 2. En el paso 2 usaste el atributo `pingd` en una regla de location. ¿Cómo lo produce el clone del paso 1 y qué comportamiento consigue la regla `score=-INFINITY` cuando `pingd lt 1`?
> 3. `pcs node standby` vs `pcs resource ban` vs `pcs cluster stop`: describí el efecto de cada uno sobre los recursos y sobre la membership de Corosync.
> 4. ¿Por qué `crm_simulate` es más seguro que "probar y ver"? ¿Qué es el `migration-threshold` y cómo se relaciona con el `failcount` que limpiaste en el paso 6?

---

## Ejercicio 7 — Multi-site con `booth` (tickets geográficos) y equivalencias `crmsh`

**Objetivo:** conocer la arquitectura de clusters geo-distribuidos con tickets `booth` y traducir la operación básica a `crmsh` (entornos SUSE/Debian).

1. Conceptualmente, `booth` coordina **varios clusters Pacemaker** en sitios distintos mediante un *ticket* que sólo un sitio puede poseer a la vez. Un tercer sitio actúa de **arbitrator**. Config típica `/etc/booth/booth.conf`:

   ```ini
   transport = UDP
   port = 9929
   arbitrator = 192.0.2.99
   site = 198.51.100.10
   site = 203.0.113.10
   ticket = "web-ticket"
       expire = 600
       timeout = 10
       retries = 5
   ```

2. El ticket se ata a los recursos mediante una constraint que exige poseerlo para poder correr:

   ```bash
   pcs constraint ticket add web-ticket WebStack loss-policy=fence
   ```

3. Operación del ticket (otorgar / revocar / consultar):

   ```bash
   booth ticket grant web-ticket
   booth ticket show
   booth ticket revoke web-ticket
   ```

4. **Equivalencias en `crmsh`** (mismo cluster, otra herramienta). Verificá que producen el mismo modelo:

   ```bash
   crm status
   crm configure show
   crm configure primitive VIP ocf:heartbeat:IPaddr2 \
       params ip=192.168.122.100 cidr_netmask=24 \
       op monitor interval=30s
   crm node standby node1
   crm resource move WebStack node2
   crm_mon -1
   ```

5. Exportá y respaldá la CIB completa (imprescindible antes de cambios mayores):

   ```bash
   pcs config backup ha_prod_backup     # genera ha_prod_backup.tar.bz2
   cibadmin --query > /root/cib-$(date +%F).xml
   ```

> **Preguntas de comprensión (P7)**
> 1. ¿Por qué `booth` NO es simplemente "un cluster Pacemaker más grande estirado entre dos sitios"? ¿Qué problema de la red WAN (latencia/particiones) hace inviable un único cluster geo-distribuido y cómo lo resuelve el modelo de ticket?
> 2. ¿Qué rol cumple el **arbitrator** y por qué debe estar en un tercer sitio? ¿Cuántos votos hacen falta para otorgar un ticket con 2 sites + 1 arbitrator?
> 3. La constraint del paso 2 usa `loss-policy=fence`. ¿Qué otras `loss-policy` existen y qué le pasa a `WebStack` si el sitio pierde el ticket con cada una?
> 4. `pcs` y `crmsh` son front-ends distintos sobre el mismo backend. ¿Cuál es ese backend común y qué herramienta de bajo nivel (mencionada en el paso 5) manipula directamente la CIB en XML?

---

<details>
<summary><strong>Respuestas — comprobá tu comprensión</strong></summary>

### P1 — Bootstrap

1. En el paso 3 autenticás la **capa de gestión** (`pcsd`, daemon HTTP en el puerto 2224 que ejecuta las órdenes de `pcs`); en el paso 4 configurás y arrancás la **capa de messaging/membership** (Corosync/totem). Son independientes porque `pcsd` sólo necesita un token compartido para que un nodo acepte comandos remotos de `pcs`; podés autenticar y luego decidir *no* crear cluster, o recrear el cluster sin re-autenticar. Corosync ni siquiera tiene que estar corriendo para que `pcs host auth` funcione.
2. `/etc/corosync/authkey` es una clave simétrica que autentica y (con `crypto_hash`/`crypto_cipher`) cifra el tráfico de totem entre nodos, impidiendo que una máquina no autorizada se una a la membership o inyecte mensajes. Lo activan los campos `crypto_cipher: aes256` y `crypto_hash: sha256` de la sección `totem`. Si un nodo tiene un `authkey` distinto, sus paquetes de totem se descartan: no formará membership y quedará fuera del cluster (aparece como `OFFLINE`/no se une al anillo).
3. El **DC (Designated Coordinator)** es el nodo donde corre activamente el `pacemaker-schedulerd` (policy engine) que calcula el estado deseado del cluster; el `pacemaker-controld` de todos los nodos elige uno. Si el DC cae, los nodos supervivientes eligen un nuevo DC automáticamente (elección basada en la membership de Corosync); no hay pérdida de servicio porque el DC es sólo quien *calcula* las decisiones, no dónde corren los recursos.
4. `udpu` (UDP unicast) es transporte plano sin cifrado nativo ni multi-ring gestionado; `knet` (kronosnet, default moderno) soporta cifrado (`crypto_cipher`/`crypto_hash`), compresión y **múltiples links redundantes** con failover/balanceo entre ellos de forma nativa. Por eso el cifrado y los anillos redundantes son parámetros de primera clase sólo con `knet`.

### P2 — Quorum

1. `two_node: 1` baja el quorum a 1, así que ante una **partición de red** *ambos* nodos creen tener quorum y podrían activar los mismos recursos → split-brain con corrupción de datos. El único mecanismo que realmente lo evita en 2 nodos es el **STONITH/fencing**: el nodo que gana la carrera fencea al otro antes de tomar sus recursos.
2. `WaitForAll` obliga a que, **tras un arranque en frío**, el cluster vea a *todos* los nodos al menos una vez antes de otorgar quorum. Previene el escenario en que un solo nodo arranca aislado (el otro sigue apagado tras un corte), asume quorum y levanta recursos mientras el segundo nodo — que quizás tenía datos más nuevos — arranca por separado.
3. `stop` (default): sin quorum, detiene ordenadamente los recursos → prioriza integridad. `ignore`: sigue corriendo recursos sin quorum → sólo seguro si el fencing es 100% confiable (típico en 2 nodos con STONITH robusto). `freeze`: mantiene los recursos que ya corren pero no arranca/mueve nada nuevo → útil cuando parar causaría más daño que congelar.
4. Un `qdevice` es un demonio (`corosync-qdevice`) en cada nodo que consulta a un árbitro externo `qnetd` para conseguir un voto extra, dando quorum determinista sin necesidad de un tercer nodo completo. `ffsplit` (fifty-fifty split) otorga el voto a la partición con más nodos (o, si empatan, a una determinista) — ideal para clusters pares; `lms` (last-man-standing) permite que hasta un único nodo sobreviviente conserve quorum mientras mantenga contacto con `qnetd`.

### P3 — Recursos y VIP

1. Clases: **ocf, lsb, systemd, service, stonith** (también `nagios` en algunas builds). `ocf:heartbeat:apache` es un script OCF que acepta parámetros y hace un *monitor* semántico (ej. consulta `server-status`), devolviendo códigos OCF granulares; `systemd:httpd` sólo envuelve el unit de systemd y su monitor equivale a `systemctl is-active` (vivo/muerto). El OCF hace monitoreo más fino porque puede verificar salud aplicativa real, no sólo que el proceso exista.
2. `OCF_SUCCESS (0)`: la operación fue bien / el recurso está corriendo. `OCF_NOT_RUNNING (7)`: el recurso está limpiamente detenido (estado esperado, no un error). `OCF_ERR_CONFIGURED (6)`: la configuración es inválida de forma **permanente** — Pacemaker no reintenta en otros nodos porque fallaría igual en todos; un `OCF_ERR_GENERIC (1)` es un fallo transitorio que sí justifica reintentar/migrar.
3. `pcs resource move` inserta una **constraint de location permanente** (`cli-prefer-VIP` con score INFINITY) que fija el recurso al nodo destino para siempre. Si te olvidás de `pcs resource clear`, el recurso nunca volverá a balancearse y no fallará-back aunque el nodo original se recupere, dejando el cluster desequilibrado y sorprendiendo al próximo operador.
4. `start`/`stop` son transiciones one-shot que llevan el recurso a running/stopped; `monitor` es el chequeo periódico de salud (con `interval`). Si el `timeout` del `monitor` es menor que el tiempo real de respuesta del servicio, Pacemaker lo declara `failed` por falso positivo, incrementa el `failcount` y puede migrarlo/reiniciarlo innecesariamente (flapping).

### P4 — Constraints

1. `INFINITY` (1000000) es una restricción **mandatoria**: A *debe* correr con B, cueste lo que cueste; un `200` es una **preferencia** que se suma a otros scores y puede ser superada. Si `colocation add A with B INFINITY` y B no arranca en ningún nodo, A tampoco arranca (queda `Stopped`), porque la única ubicación válida para A es junto a B.
2. `colocation` fija el *lugar* (mismo nodo) pero no el *orden temporal* de arranque/parada. Necesitás `order` porque sin ella Apache podría arrancar antes de que el Filesystem esté montado o la VIP asignada → el servicio arranca sin su documento raíz o sin dirección donde escuchar, y falla. El order garantiza FS → VIP → Apache al arrancar y el inverso al parar.
3. Un `resource group` impone: (a) **colocation INFINITY** de todos los miembros entre sí (corren juntos en el mismo nodo) y (b) **order** en la secuencia listada (arrancan en orden, paran en orden inverso). Ante el fallo de un miembro, se detienen en orden inverso los que van *después* de él en la lista.
4. No es lo mismo: `200` es una preferencia superable; `INFINITY` fijaría el recurso obligatoriamente a ese nodo. "Opt-in" = por defecto el recurso no corre en ningún nodo salvo donde una location con score positivo lo permita; "opt-out" = corre en todos salvo donde una location lo prohíba (score negativo). El `200` se suma al `resource-stickiness` (adherencia al nodo actual): si stickiness ≥ 200, el recurso puede quedarse donde está en vez de migrar de vuelta a node1, evitando failback innecesario.

### P5 — STONITH / fencing

1. Sin STONITH, Pacemaker no puede **garantizar** que un nodo que perdió el heartbeat esté realmente apagado; podría seguir vivo accediendo a recursos compartidos. Arrancar esos recursos en otro nodo sin certeza produciría dos escritores → corrupción. El fencing es lo único que convierte "no lo veo" en "está garantizadamente fuera" (recovery seguro). Por eso `crm_verify` lo exige.
2. Es un **split-brain** (o nodo en estado desconocido/`UNCLEAN`). Recuperar sus recursos sin fencerlo significa que dos nodos podrían montar el mismo filesystem o escribir la misma VIP/almacenamiento simultáneamente, corrompiendo datos irreversiblemente. El fencing (poison pill / power off) elimina esa posibilidad antes del failover.
3. `pcmk_host_map` mapea el **nombre del nodo en Pacemaker** (`node1`) al **identificador que el fence agent entiende** (`vm-node1`, el nombre de la VM en libvirt). Es necesario porque el hypervisor no conoce los hostnames del cluster; sin el map, `fence_xvm` no sabría qué dominio KVM apagar.
4. `pcmk_delay_base` asimétrico introduce un retardo distinto por nodo, de modo que ante una partición **simétrica** (ambos deciden fencear al otro a la vez) uno espera 10 s y el otro 0 s: el de delay 0 fencea primero y gana. Sin él, en un "fence race" ambos nodos podrían apagarse mutuamente casi simultáneamente → cluster completamente caído (double fencing).

### P6 — Clones y simulación

1. **Recurso normal**: una sola instancia activa en un nodo (ej. una VIP). **Clone**: N instancias idénticas activas a la vez, una por nodo (ej. `ping`/connectivity, `clvmd`, un daemon de filesystem clusterizado). **Promotable clone** (ex master/slave): un clone donde las instancias tienen roles Promoted/Unpromoted, típicamente un master y varios réplica (ej. DRBD Primary/Secondary, PostgreSQL con replicación).
2. El clone `ocf:pacemaker:ping` escribe en cada nodo el atributo de nodo `pingd` = (nº de hosts alcanzables × `multiplier`). La regla `location ... score=-INFINITY pingd lt 1` significa "prohibí `WebStack` en cualquier nodo cuyo `pingd` sea menor que 1", es decir, desaloja la pila de un nodo que perdió conectividad con el gateway hacia uno que sí lo alcanza.
3. `pcs node standby`: marca el nodo como no elegible para recursos; **migra todo** fuera de él pero lo mantiene en la membership de Corosync (sigue votando). `pcs resource ban`: prohíbe *un recurso concreto* en un nodo (crea una location -INFINITY). `pcs cluster stop`: detiene Pacemaker **y** Corosync en el nodo → sale de la membership (deja de votar) y sus recursos se recuperan en otro lado.
4. `crm_simulate` calcula la transición que el scheduler *haría* a partir de la CIB, sin aplicarla — así ves scores y acciones antes de tocar producción. `migration-threshold` es el número de fallos (failcount) de un recurso en un nodo tras el cual Pacemaker lo prohíbe ahí y lo migra; al hacer `pcs resource cleanup` reseteás ese failcount para que el recurso vuelva a ser elegible en ese nodo.

### P7 — Multi-site y crmsh

1. Un único cluster Pacemaker asume messaging de baja latencia y fencing confiable entre todos los nodos — inviable sobre WAN, donde las particiones son frecuentes y el fencing cross-site poco fiable. `booth` mantiene **clusters independientes por sitio**, cada uno con su propio quorum y fencing local, y coordina cuál sitio está "activo" mediante un **ticket** que sólo un sitio posee a la vez; así una partición WAN no provoca doble activación.
2. El **arbitrator** es un tercer nodo (sin recursos) que rompe empates al otorgar el ticket; debe estar en un **tercer sitio** para que una partición que aísle a un site no lo aísle también a él. Con 2 sites + 1 arbitrator hay 3 votos y hacen falta **2** (mayoría) para conceder el ticket: el sitio superviviente más el arbitrator.
3. `loss-policy` posibles: `fence` (fencea los nodos del sitio que perdió el ticket — máxima seguridad), `stop` (detiene ordenadamente los recursos atados al ticket), `freeze` (mantiene los recursos en su estado actual sin arrancar nada nuevo), y `demote` (para recursos promotable, los baja a rol Unpromoted). Con `fence`, perder el ticket cuesta un reboot del nodo; con `stop`/`freeze`/`demote` la reacción es progresivamente menos drástica.
4. El backend común es **Pacemaker y su CIB (Cluster Information Base)**, un documento XML replicado; tanto `pcs` como `crmsh` generan/parchean esa misma CIB. La herramienta de bajo nivel que la manipula directamente es **`cibadmin`** (`cibadmin --query` / `--replace`), sobre la que ambos front-ends se apoyan.

</details>