# Tema 361.3: Failover Clusters

**LPIC-3 306 · Examen 306-300 (v3.0) · High Availability and Storage Clusters**
**Peso en el examen: 13.34**

---

## 1. Motivación y el problema arquitectónico de producción

Un *failover cluster* (clúster de conmutación por error) resuelve un problema que ninguna redundancia interna de un servidor resuelve: la **indisponibilidad del nodo completo**. RAID protege del fallo de un disco; una fuente redundante protege del fallo de una PSU; pero cuando el kernel hace panic, la placa madre muere o el datacenter pierde una fase eléctrica, el servicio cae. El failover cluster convierte un conjunto de máquinas independientes en un **recurso lógico único** que sobrevive a la pérdida de nodos individuales.

La diferencia esencial con un *load-balanced cluster* (Tema 361.2) es la semántica del servicio:

- **Load-balanced (activo/activo):** N nodos sirven simultáneamente peticiones idénticas y sin estado. El objetivo es *escala* y *disponibilidad* de servicios stateless (HTTP frontend, DNS recursivo).
- **Failover (activo/pasivo):** un solo nodo posee el recurso *stateful* en un instante dado (una IP, un filesystem montado, un PostgreSQL primario). Si ese nodo muere, otro **adquiere** el recurso. El objetivo es continuidad de servicios con estado que **no toleran dos escritores simultáneos**.

### 1.1 La métrica que justifica el gasto

La disponibilidad se mide en "nueves" y se deriva de MTBF (tiempo medio entre fallos) y MTTR (tiempo medio de reparación):

```
Disponibilidad = MTBF / (MTBF + MTTR)
```

| Disponibilidad | "Nueves" | Downtime anual | Downtime mensual |
|---|---|---|---|
| 99 %      | dos nueves    | 3 d 15 h 36 m | 7 h 18 m |
| 99.9 %    | tres nueves   | 8 h 45 m 57 s | 43 m 49 s |
| 99.99 %   | cuatro nueves | 52 m 35 s     | 4 m 23 s |
| 99.999 %  | cinco nueves  | 5 m 15 s      | 26 s |

Un failover cluster ataca el **MTTR**: reduce la reparación de "un humano detecta, diagnostica y arranca en otra máquina" (decenas de minutos) a "el cluster detecta y promueve automáticamente" (segundos). No mejora el MTBF; lo compensa.

### 1.2 El enemigo: split-brain

El fallo arquitectónico más peligroso **no** es que un nodo caiga, sino que la **red de cluster se particione** mientras ambos nodos siguen vivos. Cada partición cree que la otra murió y **ambas** adquieren la IP virtual, montan el filesystem compartido y escriben. Resultado: corrupción irreversible de datos. Esto se llama *split-brain*.

Un failover cluster de producción **no es correcto** sin dos mecanismos que atacan split-brain:

1. **Quorum** — reglas de votación que determinan qué partición tiene autoridad para ejecutar recursos.
2. **Fencing / STONITH** — la capacidad de **apagar físicamente** un nodo del que se sospecha, garantizando que no pueda escribir aunque el software crea que está vivo.

> **Regla no negociable de producción:** un cluster con recursos que escriben en almacenamiento compartido y `stonith-enabled=false` es un incidente de pérdida de datos esperando a ocurrir. El fencing no es opcional.

### 1.3 El stack de Linux HA

El ecosistema canónico (RHEL/SLES/Debian/Ubuntu) se compone de dos piezas complementarias:

```
┌──────────────────────────────────────────────────────────────┐
│                     Herramientas de gestión                    │
│                 pcs (Red Hat)   /   crmsh (SUSE)               │
├──────────────────────────────────────────────────────────────┤
│                          PACEMAKER                             │
│         (Cluster Resource Manager — el "cerebro")             │
│   pacemakerd · CIB · scheduler · controld · fenced · execd   │
├──────────────────────────────────────────────────────────────┤
│                          COROSYNC                             │
│  (Messaging & Membership — el "sistema nervioso")            │
│      protocolo Totem · knet · votequorum · CPG               │
├──────────────────────────────────────────────────────────────┤
│                   Resource Agents / Fence Agents              │
│        OCF · systemd · LSB · STONITH · SBD                    │
└──────────────────────────────────────────────────────────────┘
```

**Corosync** provee la *membresía* (quién está vivo), la *mensajería ordenada y confiable* entre nodos y el *quorum*. **Pacemaker** decide *qué recurso corre dónde*, en qué *orden*, con qué *restricciones*, y ejecuta el *fencing* cuando la membresía se vuelve ambigua.

---

## 2. Arquitectura interna

### 2.1 Corosync: la capa de membresía y mensajería

Corosync implementa el **protocolo Totem** (Totem Single Ring Ordering and Membership Protocol), un protocolo de comunicación de grupo que garantiza *virtual synchrony*: todos los nodos vivos ven la misma secuencia de mensajes y los mismos cambios de membresía, en el mismo orden. Esto es lo que permite que Pacemaker tome decisiones consistentes en todos lados.

Componentes lógicos de Corosync:

- **Totem / token ring:** un token circula por un anillo lógico de nodos. Poseer el token da derecho a transmitir. Si el token no vuelve dentro de `token` ms (por defecto 1000 ms; en clusters de más de 2 nodos se recalcula), se declara pérdida de nodo y se inicia una nueva *membership*.
- **knet (kronosnet):** la capa de transporte por defecto en Corosync 3. Soporta **múltiples enlaces** (redundant ring) con failover y balanceo, cifrado y compresión nativos. Reemplaza al viejo transporte `udp` (multicast) y `udpu` (unicast).
- **votequorum:** el servicio de quorum. Cada nodo aporta votos; una partición es *quorate* (tiene quorum) si reúne `floor(votos_totales / 2) + 1` votos.
- **CPG (Closed Process Group):** la API por la que Pacemaker envía mensajes al grupo cerrado de procesos del cluster.
- **authkey:** clave simétrica de 128/256 bytes en `/etc/corosync/authkey` que autentica y cifra el tráfico Totem. Sin ella (o con una clave distinta entre nodos) los nodos no se ven.

### 2.2 Pacemaker: el gestor de recursos

Pacemaker 2.x corre como un conjunto de daemons lanzados por `pacemakerd`:

| Daemon (Pacemaker 2.x) | Nombre histórico | Responsabilidad |
|---|---|---|
| `pacemaker-based` | `cib` | Mantiene la **CIB** (Cluster Information Base), la base de datos XML replicada con la configuración y el estado. |
| `pacemaker-controld` | `crmd` | El *controller*. Coordina las transiciones y elige al **DC** (Designated Coordinator). |
| `pacemaker-schedulerd` | `pengine` | El *policy engine*. Dado el estado actual y el deseado, **calcula** el grafo de transición (qué arrancar/parar/mover). No ejecuta nada. |
| `pacemaker-execd` | `lrmd` | *Local Resource Management*. Ejecuta los resource agents (start/stop/monitor) en el nodo local. |
| `pacemaker-fenced` | `stonithd` | Ejecuta las operaciones de **fencing**. |
| `pacemaker-attrd` | `attrd` | Gestiona los *node attributes* transitorios (fail-counts, etc.). |

**El DC (Designated Coordinator):** un único nodo, elegido por el cluster, es responsable de invocar al `schedulerd` para calcular transiciones. El resto de nodos ejecuta las acciones que el DC les asigna. Si el DC muere, se elige otro. **No es un maestro de datos**: cualquier nodo puede ser DC; es sólo el coordinador de decisiones.

**La CIB:** todo el estado del cluster es un documento XML. `epoch`, `num_updates` y `admin_epoch` versionan la CIB; el nodo con la CIB más reciente gana en un merge. Casi nunca se edita a mano; se manipula con `pcs`, `crmsh` o `cibadmin`.

```
┌─────────┐   token Totem   ┌─────────┐   token Totem   ┌─────────┐
│  node1  │◄───────────────►│  node2  │◄───────────────►│  node3  │
│ (DC)    │                 │         │                 │         │
│ CIB ◄──────── replicación síncrona de la CIB por CPG ─────────► │
└─────────┘                 └─────────┘                 └─────────┘
     │                           │                           │
 execd/fenced              execd/fenced               execd/fenced
```

---

## 3. Comparativas técnicas y trade-offs

### 3.1 Herramienta de gestión: `pcs` vs `crmsh`

| Dimensión | `pcs` (pcsd) | `crmsh` (crm shell) |
|---|---|---|
| Origen / distro nativa | Red Hat / RHEL / CentOS / Fedora | SUSE / SLES / openSUSE |
| Modelo | Cliente-servidor: daemon `pcsd` en cada nodo, autenticación por token | CLI directa que edita la CIB local |
| Autenticación entre nodos | `pcs host auth` (usuario `hacluster`) | SSH (`crm cluster` usa SSH) |
| Configuración de Corosync | La genera `pcs cluster setup` | Se edita `corosync.conf` o vía `crm cluster init` (bootstrap con `ha-cluster-init`) |
| Modo transaccional | `pcs cluster cib <file>` → editar → `pcs cluster cib-push` | shadow CIB + `commit`/`edit` interactivo |
| Interfaz web | `pcsd` Web UI (puerto 2224) | Hawk (HA Web Konsole) |
| Curva de aprendizaje | Comandos planos, verboso | Shell jerárquica, más conciso para configs grandes |

**Trade-off:** ambos manipulan la **misma** CIB y Corosync. La elección la dicta la distribución. En la certificación se exige conocer **ambos**.

### 3.2 Transporte de Corosync

| Transporte | Versión | Direccionamiento | Multi-enlace | Cifrado | Notas |
|---|---|---|---|---|---|
| `knet` | Corosync 3+ (default) | unicast | **Sí** (hasta 8 links, failover activo) | Nativo (`crypto_cipher`) | Recomendado para todo despliegue nuevo |
| `udpu` | Corosync 2/3 | unicast | No (redundant ring RRP) | Vía RRP legacy | Cuando el multicast no está disponible en la red |
| `udp` | legacy | multicast | RRP | RRP legacy | **Desaconsejado**: depende de IGMP snooping y multicast en switches |

### 3.3 Métodos de fencing (STONITH)

| Método / agente | Mecanismo | Requisito | Latencia | Cuándo usarlo |
|---|---|---|---|---|
| `fence_ipmilan` | BMC/IPMI del hardware (power off) | BMC en red de gestión | Baja | Servidores físicos con IPMI/iLO/iDRAC |
| `fence_sbd` (SBD) | Watchdog + disco compartido (poison pill) | Disco compartido + `softdog`/HW watchdog | Media (timeout) | Sin BMC, o clusters con almacenamiento compartido |
| `fence_apc` / `fence_pdu` | PDU de rack corta la corriente | PDU gestionable | Baja | Hardware sin BMC |
| `fence_scsi` / `fence_mpath` | SCSI-3 Persistent Reservations (revoca acceso al disco) | Almacenamiento con PR | Baja | Fencing de *almacenamiento* (no apaga el nodo) |
| `fence_vmware_rest` / `fence_vmware_soap` | API del hipervisor apaga la VM | Acceso a vCenter | Baja | Nodos virtualizados en VMware |
| `fence_xvm` / `fence_virt` | libvirt/KVM apaga la VM invitada | Host KVM con `fence_virtd` | Baja | Labs y clusters sobre KVM |
| `fence_aws` / `fence_gce` / `fence_azure_arm` | API cloud detiene la instancia | Credenciales IAM | Media | Clusters en nube pública |

**Trade-off clave — power fencing vs storage fencing:** `fence_ipmilan` garantiza que el nodo está *apagado* (no puede hacer nada). `fence_scsi` sólo garantiza que el nodo *no puede escribir en el disco compartido*, pero el nodo sigue vivo (puede seguir sirviendo una IP obsoleta). Para servicios con IP virtual y datos, **power fencing es la opción segura**; el storage fencing se combina como nivel adicional.

### 3.4 Clases de resource agents

| Clase | Ubicación / origen | Operaciones estándar | Ventaja |
|---|---|---|---|
| **OCF** | `/usr/lib/ocf/resource.d/<provider>/<type>` | `start` `stop` `monitor` `meta-data` `validate-all` (+ `promote`/`demote`) | Parametrizable, con monitor real y semántica rica; **preferida** |
| **systemd** | Units de systemd | start/stop/monitor vía systemd | Reusa units existentes; sin monitor profundo |
| **LSB** | `/etc/init.d/*` | Debe cumplir LSB (status correcto) | Legacy; muchos scripts LSB no reportan `status` bien |
| **service** | Autodetecta LSB o systemd | — | Portabilidad |
| **STONITH** | Fence agents | Fencing | Sólo para recursos de fencing |

**Regla:** preferir OCF por su operación `monitor` (health check periódico) y su parametrización. Un agente LSB que miente en `status` rompe el cluster silenciosamente.

---

## 4. Configuración de Corosync (completa)

### 4.1 Generar la clave de autenticación

`corosync-keygen` lee entropía de `/dev/urandom` y escribe `/etc/corosync/authkey` (256 bytes en Corosync 3). Debe copiarse **idéntica** a todos los nodos con permisos `0400 root:root`.

```
$ sudo corosync-keygen
Corosync Cluster Engine Authentication key generator.
Gathering 2048 bits for key from /dev/urandom.
Writing corosync key to /etc/corosync/authkey.

$ sudo ls -l /etc/corosync/authkey
-r-------- 1 root root 256 Aug 12 09:14 /etc/corosync/authkey

# Distribuir a los otros nodos preservando permisos
$ sudo scp -p /etc/corosync/authkey root@node2:/etc/corosync/authkey
$ sudo scp -p /etc/corosync/authkey root@node3:/etc/corosync/authkey
```

### 4.2 `/etc/corosync/corosync.conf` — clúster de 3 nodos, knet, doble enlace

```
totem {
    version:        2
    cluster_name:   prod-cluster
    transport:      knet
    crypto_cipher:  aes256
    crypto_hash:    sha256
    token:          3000
    token_retransmits_before_loss_const: 10
    join:           60
    consensus:      3600
    max_messages:   20
}

logging {
    to_logfile:  yes
    logfile:     /var/log/corosync/corosync.log
    to_syslog:   yes
    timestamp:   on
    debug:       off
    logger_subsys {
        subsys: QUORUM
        debug:  off
    }
}

quorum {
    provider:                 corosync_votequorum
    expected_votes:           3
    wait_for_all:             1
    last_man_standing:        1
    last_man_standing_window: 10000
    # two_node: 1   # descomentar SÓLO en clusters de exactamente 2 nodos
}

nodelist {
    node {
        ring0_addr: 10.0.10.11
        ring1_addr: 10.0.20.11
        name:       node1
        nodeid:     1
    }
    node {
        ring0_addr: 10.0.10.12
        ring1_addr: 10.0.20.12
        name:       node2
        nodeid:     2
    }
    node {
        ring0_addr: 10.0.10.13
        ring1_addr: 10.0.20.13
        name:       node3
        nodeid:     3
    }
}
```

**Notas de producción:**

- `ring0_addr` y `ring1_addr` en **redes físicas separadas** (dos switches, dos NICs) evitan que un solo switch caído particione el cluster. knet failover entre ellas es transparente.
- `crypto_cipher`/`crypto_hash` cifran y autentican el tráfico usando `authkey`. En redes de gestión aisladas se puede poner `none` por rendimiento, pero por defecto se cifra.
- `wait_for_all: 1` obliga a que **todos** los nodos hayan sido vistos al menos una vez tras un arranque en frío antes de otorgar quorum. Previene que un solo nodo que arranca aislado se crea autoritativo.
- `last_man_standing` permite que `expected_votes` baje dinámicamente cuando los nodos se pierden de forma controlada, permitiendo que el último nodo sobreviviente mantenga quorum.

Validar la sintaxis y aplicar:

```
$ sudo corosync -t
Aug 12 09:20:11 notice  [MAIN  ] Corosync Cluster Engine 3.1.7 starting up
...
Aug 12 09:20:11 notice  [MAIN  ] Config file /etc/corosync/corosync.conf validated. Exiting.

$ sudo systemctl restart corosync
```

---

## 5. Levantar el cluster con `pcs` (Red Hat / RHEL)

### 5.1 Preparación en TODOS los nodos

```
$ sudo dnf install -y pacemaker corosync pcs fence-agents-all
$ sudo systemctl enable --now pcsd
$ echo 'S3cureHAcluster!' | sudo passwd --stdin hacluster
Changing password for user hacluster.
passwd: all authentication tokens updated successfully.

# Abrir el firewall para el servicio HA
$ sudo firewall-cmd --permanent --add-service=high-availability
success
$ sudo firewall-cmd --reload
success
```

### 5.2 Autenticar y crear el cluster (desde un nodo)

```
$ sudo pcs host auth node1 node2 node3 -u hacluster -p 'S3cureHAcluster!'
node1: Authorized
node2: Authorized
node3: Authorized

$ sudo pcs cluster setup prod-cluster \
      node1 addr=10.0.10.11 addr=10.0.20.11 \
      node2 addr=10.0.10.12 addr=10.0.20.12 \
      node3 addr=10.0.10.13 addr=10.0.20.13 \
      --transport knet crypto_cipher=aes256 crypto_hash=sha256
No addresses specified for host 'node1', using 'node1'
Destroying cluster on hosts: 'node1', 'node2', 'node3'...
node1: Successfully destroyed cluster
node2: Successfully destroyed cluster
node3: Successfully destroyed cluster
Sending 'pacemaker authkey' and 'corosync authkey' to hosts: 'node1', 'node2', 'node3'
node1: successful distribution of the file 'corosync authkey'
...
Sending 'corosync.conf' to hosts: 'node1', 'node2', 'node3'
node1: successful distribution of the file 'corosync.conf'
...
Cluster has been successfully set up.

$ sudo pcs cluster start --all
node1: Starting Cluster...
node2: Starting Cluster...
node3: Starting Cluster...

$ sudo pcs cluster enable --all
node1: Cluster Enabled
node2: Cluster Enabled
node3: Cluster Enabled
```

### 5.3 Verificar el estado inicial

```
$ sudo pcs status
Cluster name: prod-cluster

WARNINGS:
No stonith devices and stonith-enabled is not false

Cluster Summary:
  * Stack: corosync (Pacemaker is running)
  * Current DC: node1 (version 2.1.7-5.el9-...) - partition with quorum
  * Last updated: Wed Aug 12 09:31:02 2026 on node1
  * Last change:  Wed Aug 12 09:30:41 2026 by hacluster via hacluster on node1
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

El `WARNING` es correcto y **deseado**: el cluster nos recuerda que aún no hay fencing. Lo configuramos antes de poner recursos con datos (sección 7).

---

## 6. Recursos, grupos, restricciones y clones

### 6.1 Recursos primitivos y un grupo de failover

Escenario clásico activo/pasivo: una **IP virtual** + un **filesystem** sobre DRBD + un **Apache**, que deben vivir juntos, en el mismo nodo, y arrancar en orden.

```
# IP virtual (OCF IPaddr2)
$ sudo pcs resource create vip_web ocf:heartbeat:IPaddr2 \
      ip=10.0.10.100 cidr_netmask=24 nic=eth0 \
      op monitor interval=10s timeout=20s
Assumed agent name 'ocf:heartbeat:IPaddr2' (deduced from 'IPaddr2')

# Filesystem sobre el dispositivo DRBD
$ sudo pcs resource create web_fs ocf:heartbeat:Filesystem \
      device=/dev/drbd0 directory=/var/www/html fstype=xfs \
      op monitor interval=20s timeout=40s \
      op start timeout=60s op stop timeout=60s

# Servicio Apache con status URL para el monitor
$ sudo pcs resource create webserver ocf:heartbeat:apache \
      configfile=/etc/httpd/conf/httpd.conf \
      statusurl="http://127.0.0.1/server-status" \
      op monitor interval=1min timeout=30s
```

Agruparlos crea **orden implícito** (arrancan en el orden listado, paran en reverso) y **colocación implícita** (siempre en el mismo nodo):

```
$ sudo pcs resource group add web_stack web_fs vip_web webserver

$ sudo pcs status resources
  * Resource Group: web_stack:
    * web_fs      (ocf:heartbeat:Filesystem):   Started node1
    * vip_web     (ocf:heartbeat:IPaddr2):      Started node1
    * webserver   (ocf:heartbeat:apache):       Started node1
```

### 6.2 Restricciones explícitas (location, order, colocation)

Cuando el grupo no basta y hay que expresar preferencias finas:

```
# Preferencia de ubicación (score 100): prefiere node1 pero no lo exige
$ sudo pcs constraint location web_stack prefers node1=100

# Regla anti-ubicación: nunca en el nodo de backup salvo emergencia
$ sudo pcs constraint location web_stack avoids node3=50

# Orden explícito (por si no se usara grupo)
$ sudo pcs constraint order start web_fs then start webserver
Adding web_fs webserver (kind: Mandatory) (Options: first-action=start then-action=start)

# Colocación INFINITY: webserver DEBE estar donde está vip_web
$ sudo pcs constraint colocation add webserver with vip_web INFINITY

$ sudo pcs constraint
Location Constraints:
  Resource: web_stack
    Enabled on:
      Node: node1 (score:100)
    Disabled on:
      Node: node3 (score:-50)
Ordering Constraints:
  start web_fs then start webserver (kind:Mandatory)
Colocation Constraints:
  webserver with vip_web (score:INFINITY)
```

**Semántica de los scores:**

| Score | Significado |
|---|---|
| `INFINITY` (1.000.000) | Obligatorio: si no se puede cumplir, el recurso no corre. |
| `-INFINITY` | Prohibición absoluta. |
| Valor positivo finito | Preferencia; se puede violar si la suma de scores lo justifica. |
| Valor negativo finito | Aversión; se evita si es posible. |

### 6.3 Parámetros de estabilidad: `resource-stickiness` y `migration-threshold`

```
# Evita que un recurso "vuelva" al nodo original tras recuperarse (evita
# un segundo outage innecesario). Valor por defecto recomendado: > 0.
$ sudo pcs resource defaults update resource-stickiness=100

# Tras 3 fallos de monitor en un nodo, migrar el recurso a otro nodo
$ sudo pcs resource update webserver meta migration-threshold=3 failure-timeout=60s
```

`resource-stickiness=100` significa que un recurso "cuesta" 100 puntos moverlo; sólo se moverá si un constraint supera esa fuerza. Esto evita el *ping-pong* de recursos.

### 6.4 Clones y clones promotables (DRBD como ejemplo)

Un **clone** corre la misma instancia en varios nodos. Un **promotable clone** (antes *master/slave*) tiene dos roles: `Promoted` (Master) y `Unpromoted` (Slave). DRBD es el caso canónico: réplica en 2 nodos, uno primario.

```
$ sudo pcs resource create drbd_web ocf:linbit:drbd \
      drbd_resource=web \
      op monitor interval=29s role=Promoted \
      op monitor interval=31s role=Unpromoted \
      op start timeout=240s op stop timeout=100s

$ sudo pcs resource promotable drbd_web \
      promoted-max=1 promoted-node-max=1 \
      clone-max=2 clone-node-max=1 notify=true

# El filesystem sólo puede montar donde DRBD está Promoted
$ sudo pcs constraint colocation add web_fs with Promoted drbd_web-clone INFINITY
$ sudo pcs constraint order promote drbd_web-clone then start web_fs
```

```
$ sudo pcs status
  ...
  * Clone Set: drbd_web-clone [drbd_web] (promotable):
    * Promoted: [ node1 ]
    * Unpromoted: [ node2 ]
  * Resource Group: web_stack:
    * web_fs      (ocf:heartbeat:Filesystem):   Started node1
    * vip_web     (ocf:heartbeat:IPaddr2):      Started node1
    * webserver   (ocf:heartbeat:apache):       Started node1
```

### 6.5 Edición transaccional (evitar aplicar cambios a medias)

En producción no se editan constraints una por una sobre la CIB viva; se trabaja sobre una **copia** y se empuja atómicamente:

```
$ sudo pcs cluster cib web_cfg.xml
$ sudo pcs -f web_cfg.xml resource create db_vip ocf:heartbeat:IPaddr2 ip=10.0.10.101 cidr_netmask=24
$ sudo pcs -f web_cfg.xml constraint colocation add db_vip with vip_web -INFINITY
$ sudo pcs cluster cib-push web_cfg.xml --config
CIB updated
```

---

## 7. Fencing / STONITH (obligatorio en producción)

### 7.1 Propiedades globales del cluster

```
$ sudo pcs property set stonith-enabled=true
$ sudo pcs property set no-quorum-policy=stop

$ sudo pcs property config
Cluster Properties:
 cluster-infrastructure: corosync
 cluster-name: prod-cluster
 dc-version: 2.1.7-5.el9
 have-watchdog: false
 no-quorum-policy: stop
 stonith-enabled: true
```

`no-quorum-policy` decide qué hace una partición **sin** quorum:

| Valor | Comportamiento sin quorum |
|---|---|
| `stop` (default) | Detiene todos los recursos. La opción **segura** para datos. |
| `ignore` | Sigue ejecutando recursos. **Peligroso**: sólo con fencing SCSI o clusters de 2 nodos muy específicos. |
| `freeze` | Mantiene los recursos corriendo pero no arranca nuevos. |
| `suicide` | Se auto-fencea (apaga los nodos de la partición minoritaria). |
| `demote` | Degrada recursos promovibles y detiene el resto. |

### 7.2 Fencing por IPMI (hardware físico)

Se crea **un dispositivo de fencing por nodo**, apuntando al BMC de ese nodo:

```
$ sudo pcs stonith create fence_node1 fence_ipmilan \
      pcmk_host_list="node1" \
      ip=10.0.99.11 lanplus=1 \
      username="fenceadmin" password="Fence!Secret" \
      power_wait=4 \
      op monitor interval=60s

$ sudo pcs stonith create fence_node2 fence_ipmilan \
      pcmk_host_list="node2" \
      ip=10.0.99.12 lanplus=1 \
      username="fenceadmin" password="Fence!Secret" \
      power_wait=4 op monitor interval=60s

$ sudo pcs stonith create fence_node3 fence_ipmilan \
      pcmk_host_list="node3" \
      ip=10.0.99.13 lanplus=1 \
      username="fenceadmin" password="Fence!Secret" \
      power_wait=4 op monitor interval=60s

$ sudo pcs stonith status
  * fence_node1  (stonith:fence_ipmilan):  Started node2
  * fence_node2  (stonith:fence_ipmilan):  Started node3
  * fence_node3  (stonith:fence_ipmilan):  Started node1
```

**Importante:** Pacemaker evita, por defecto, ejecutar el fence device *del propio nodo* en ese nodo (no puede apagarse a sí mismo de forma fiable). Por eso `fence_node1` corre en otro nodo.

### 7.3 SBD (Storage-Based Death) — fencing sin BMC

Cuando no hay IPMI (o como refuerzo), **SBD** combina un **watchdog** hardware/software con un pequeño disco compartido. Un nodo condenado recibe una *poison pill* en el disco; si no puede leerla o no responde, el watchdog lo resetea por hardware.

```
# En todos los nodos: cargar un watchdog (hardware o softdog para labs)
$ sudo modprobe softdog
$ echo softdog | sudo tee /etc/modules-load.d/softdog.conf

# Crear el metadato SBD sobre el disco compartido (~10 MB bastan)
$ sudo sbd -d /dev/mapper/sbd-slot create
Initializing device /dev/mapper/sbd-slot
Creating version 2.1 header on device 3 (uuid: 6f3c...-...)
Initializing 255 slots on device 3
Device /dev/mapper/sbd-slot is initialized.
```

`/etc/sysconfig/sbd` (RHEL) o `/etc/default/sbd` (Debian/SUSE):

```
SBD_DEVICE="/dev/mapper/sbd-slot"
SBD_WATCHDOG_DEV=/dev/watchdog
SBD_WATCHDOG_TIMEOUT=5
SBD_STARTMODE=always
SBD_DELAY_START=no
SBD_OPTS="-n node1"
```

Habilitar SBD en el cluster (crea el stonith `fence_sbd` y activa `have-watchdog`):

```
$ sudo pcs stonith sbd enable \
      SBD_WATCHDOG_TIMEOUT=5 SBD_DELAY_START=no \
      --device=/dev/mapper/sbd-slot
Running SBD pre-enabling checks...
node1: SBD pre-enabling checks done
...
Enabling sbd...
Restarting cluster to apply changes...

$ sudo pcs stonith sbd status
SBD STATUS
<node>: <installed> | <enabled> | <running>
node1: YES | YES | YES
node2: YES | YES | YES
node3: YES | YES | YES

Messages list on device '/dev/mapper/sbd-slot':
0	node1	clear
1	node2	clear
2	node3	clear
```

### 7.4 Fencing topology (niveles/escalonado)

Se pueden encadenar métodos: intentar IPMI, y si falla, cortar la PDU.

```
$ sudo pcs stonith create pdu_node1 fence_apc \
      ip=10.0.99.50 username=apc password=apc \
      pcmk_host_map="node1:3" op monitor interval=120s

$ sudo pcs stonith level add 1 node1 fence_node1
$ sudo pcs stonith level add 2 node1 pdu_node1

$ sudo pcs stonith level
Target: node1
  Level 1 - fence_node1
  Level 2 - pdu_node1
```

El nivel 2 sólo se intenta si el nivel 1 falla por completo.

### 7.5 Probar el fencing manualmente (sin esperar un fallo real)

```
# Verificar que el agente puede consultar el estado de energía
$ sudo pcs stonith fence node2 --off
Node: node2 fenced

# Con la herramienta de bajo nivel
$ sudo stonith_admin --list-registered
fence_node1
fence_node2
fence_node3

$ sudo stonith_admin --history node2
node2 was terminated (off) by node3 for pacemaker-controld.1234 at Wed Aug 12 10:02:14 2026: OK
```

---

## 8. Quorum, votequorum y qdevice

### 8.1 El problema del clúster de 2 nodos

Con 2 nodos, `quorum = floor(2/2)+1 = 2`. Si un nodo cae, el sobreviviente tiene 1 voto < 2 → pierde quorum → detiene recursos. Inútil. Dos soluciones:

1. **`two_node: 1`** en `corosync.conf`: activa un modo especial donde `quorum=1` y se apoya **fuertemente** en el fencing para prevenir split-brain (cada nodo intenta fencear al otro; el que gana la carrera sobrevive). Requiere `wait_for_all`.
2. **qdevice** (recomendado): un tercer árbitro externo (`corosync-qnetd`) que aporta un voto de desempate **sin** correr recursos.

### 8.2 Desplegar un qdevice (quorum device)

```
# En el host árbitro (fuera del cluster)
$ sudo dnf install -y corosync-qnetd pcs
$ sudo systemctl enable --now pcsd
$ sudo pcs qdevice setup model net --enable --start
Quorum device 'net' initialized
quorum device enabled
Starting quorum device...
quorum device started

# En un nodo del cluster
$ sudo pcs host auth qnetd-arbiter -u hacluster -p 'S3cureHAcluster!'
qnetd-arbiter: Authorized

$ sudo pcs quorum device add model net host=qnetd-arbiter algorithm=ffsplit
Setting up qdevice certificates on nodes...
node1: Succeeded
node2: Succeeded
node3: Succeeded
...
Enabling corosync-qdevice...
node1: corosync-qdevice enabled
...
```

**Algoritmos del qdevice:**

| Algoritmo | Comportamiento |
|---|---|
| `ffsplit` (fifty-fifty split) | En una partición 50/50, otorga el voto a **una sola** partición determinísticamente. |
| `lms` (last man standing) | Otorga el voto a la partición que contiene el nodo con menor nodeid superviviente; permite que quede 1 nodo. |

### 8.3 Inspeccionar el quorum

```
$ sudo corosync-quorumtool
Quorum information
------------------
Date:             Wed Aug 12 10:20:33 2026
Quorum provider:  corosync_votequorum
Nodes:            3
Node ID:          1
Ring ID:          1.2f
Quorate:          Yes

Votequorum information
----------------------
Expected votes:   4
Highest expected: 4
Total votes:      4
Quorum:           3
Flags:            Quorate Qdevice

Membership information
----------------------
    Nodeid      Votes    Qdevice Name
         1          1    A,V,NMW node1 (local)
         2          1    A,V,NMW node2
         3          1    A,V,NMW node3
         0          1            Qdevice
```

`A,V,NMW` = Alive, Vote, Not-Master-Wins. Con el qdevice, `Expected votes` sube a 4 y el quorum a 3, de modo que cualquier partición mayoritaria (2 nodos + qdevice) mantiene el servicio.

---

## 9. Equivalente con `crmsh` (SUSE / openSUSE)

La misma CIB, distinta herramienta. Bootstrap de un cluster:

```
# Primer nodo
$ sudo crm cluster init --name prod-cluster --interface eth0 --interface eth1 -y
INFO: Loading "default" profile from /etc/crm/profiles.yml
INFO: Configuring csync2
INFO: Starting pacemaker.service on node1
INFO: Configure corosync (unicast, knet)
INFO: Configuring SBD  ← ofrece configurar SBD interactivamente
INFO: Cluster is running

# Unir los otros nodos
node2$ sudo crm cluster join -c node1 -y
node3$ sudo crm cluster join -c node1 -y
```

Configurar recursos con la shell jerárquica:

```
$ sudo crm configure
crm(live)configure# primitive vip_web IPaddr2 \
   > params ip=10.0.10.100 cidr_netmask=24 nic=eth0 \
   > op monitor interval=10s timeout=20s
crm(live)configure# primitive web_fs Filesystem \
   > params device="/dev/drbd0" directory="/var/www/html" fstype=xfs \
   > op monitor interval=20s
crm(live)configure# primitive webserver apache \
   > params configfile="/etc/apache2/httpd.conf" \
   > op monitor interval=60s
crm(live)configure# group web_stack web_fs vip_web webserver
crm(live)configure# property stonith-enabled=true no-quorum-policy=stop
crm(live)configure# verify
crm(live)configure# commit
crm(live)configure# quit
bye
```

Monitorizar:

```
$ sudo crm status
$ sudo crm_mon -Arf1
```

STONITH con crmsh:

```
crm(live)configure# primitive fence_node1 stonith:fence_ipmilan \
   > params pcmk_host_list=node1 ip=10.0.99.11 lanplus=1 \
   > username=fenceadmin password=Fence!Secret \
   > op monitor interval=60s
crm(live)configure# commit
```

---

## 10. Clusters multi-sitio con Booth

Un failover cluster local protege de fallos de nodo dentro de un sitio. Para tolerar la pérdida de un **datacenter entero** se enlazan dos (o más) clusters Pacemaker independientes con **Booth**. Booth gestiona *tickets*: un recurso sólo corre en el sitio que **posee** el ticket, y Booth garantiza que **un solo sitio** lo posee a la vez, evitando split-brain inter-sitio. Un **arbitrator** (tercer sitio, sólo Booth) rompe empates.

`/etc/booth/booth.conf` (idéntico en todos los sitios y el arbitrator):

```
transport = UDP
port      = 9929

arbitrator = 10.0.99.200

site = 10.0.10.100
site = 10.0.20.100

ticket = "ticket-web"
  expire  = 600
  timeout = 10
  retries = 5
  renewal-freq = 30
```

Integrar el ticket en cada cluster local: el recurso sólo corre si el sitio tiene el ticket.

```
# En cada cluster local, atar el grupo al ticket
$ sudo pcs constraint ticket add ticket-web web_stack loss-policy=fence

# Arrancar Booth (systemd o como recurso del cluster)
$ sudo pcs resource create booth-ip ocf:heartbeat:IPaddr2 ip=10.0.10.100 cidr_netmask=24
$ sudo pcs resource create booth-site ocf:pacemaker:booth-site config=booth
$ sudo pcs resource group add booth-group booth-ip booth-site
```

Operar tickets:

```
# Otorgar el ticket a un sitio (activa los recursos allí)
$ sudo booth ticket grant ticket-web
booth[2201]: info: grant request sent, waiting for the result ...
booth[2201]: info: grant succeeded!

$ sudo booth list
ticket: ticket-web, leader: 10.0.10.100, expires: 2026-08-12 10:52:31

# Migrar el sitio activo (failover controlado de datacenter)
$ sudo booth ticket revoke ticket-web
```

`loss-policy=fence` en el constraint significa que si el sitio **pierde** el ticket sin cederlo limpiamente, sus nodos se auto-fencean — la garantía dura de que el sitio viejo no siga escribiendo.

---

## 11. Verificación y diagnóstico de fallas

### 11.1 Panel de estado en vivo

```
$ sudo crm_mon -Arf
Cluster Summary:
  * Stack: corosync (Pacemaker is running)
  * Current DC: node1 (version 2.1.7-5.el9) - partition with quorum
  * Last updated: Wed Aug 12 11:03:47 2026
  * 3 nodes configured
  * 7 resource instances configured

Node List:
  * Online: [ node1 node2 node3 ]

Full List of Resources:
  * Clone Set: drbd_web-clone [drbd_web] (promotable):
    * Promoted: [ node1 ]
    * Unpromoted: [ node2 ]
  * Resource Group: web_stack:
    * web_fs      (ocf:heartbeat:Filesystem):  Started node1
    * vip_web     (ocf:heartbeat:IPaddr2):     Started node1
    * webserver   (ocf:heartbeat:apache):      Started node1
  * fence_node1  (stonith:fence_ipmilan):      Started node2

Node Attributes:
  * Node: node1:
    * master-drbd_web  : 10000

Migration Summary:
```

`-A` muestra node attributes, `-r` recursos inactivos, `-f` fail counts.

### 11.2 Validar la configuración ANTES de que rompa

```
# Detecta errores de sintaxis y configuración inválida en la CIB
$ sudo crm_verify -LV
   error: unpack_rsc_op:    Preventing web_fs from restarting on node2:
          operation start failed (rc=5 / not installed)
   Errors found during check: config not valid
```

`rc=5` (OCF `ERR_INSTALLED`) señala que el binario o dependencia no está en `node2` — un fallo típico: un paquete instalado sólo en el nodo activo.

### 11.3 Simular una transición sin ejecutarla (`crm_simulate`)

Herramienta clave para responder *"¿qué haría el cluster si el node1 muriera?"* sin tocar producción:

```
# Estado actual y qué acciones dispararía el scheduler
$ sudo crm_simulate -L -S

# Simular la caída de node1 usando una CIB volcada
$ sudo pcs cluster cib > /tmp/cib.xml
$ sudo crm_simulate -x /tmp/cib.xml --node-down=node1 -s

Transition Summary:
  * Fence (reboot) node1 'peer is no longer part of the cluster'
  * Move       vip_web    ( node1 -> node2 )
  * Move       web_fs     ( node1 -> node2 )
  * Move       webserver  ( node1 -> node2 )
  * Promote    drbd_web:1 ( Unpromoted -> Promoted node2 )
```

Confirma que el failover promoverá DRBD en node2 y moverá el stack completo — exactamente lo esperado.

### 11.4 Estado de Corosync (capa de red)

```
# Estado de los enlaces knet
$ sudo corosync-cfgtool -s
Local node ID 1, transport knet
LINK ID 0 udp
	addr	= 10.0.10.11
	status:
		nodeid:          1:	localhost
		nodeid:          2:	connected
		nodeid:          3:	connected
LINK ID 1 udp
	addr	= 10.0.20.11
	status:
		nodeid:          1:	localhost
		nodeid:          2:	connected
		nodeid:          3:	connected

# Estadísticas de knet (paquetes, latencia, retransmisiones)
$ sudo corosync-cfgtool -n
$ sudo corosync-cpgtool
```

Un `status` con un nodo en `disconnected` en un LINK pero `connected` en otro confirma un fallo de una sola red física — el cluster sobrevive gracias al segundo anillo.

### 11.5 Diagnóstico de un recurso que falla

```
# Ver el fail-count acumulado
$ sudo pcs resource failcount show webserver
Failcounts for resource 'webserver'
  node1: INFINITY

# Reproducir el arranque del agente OCF en primer plano, con trazas
$ sudo pcs resource debug-start webserver --full
Operation start for webserver (ocf:heartbeat:apache) returned: 'ok' (0)
 >  stderr: apache: detecting default status URL...
 >  stderr: httpd -k start -f /etc/httpd/conf/httpd.conf

# Limpiar el fail-count para reintentar en el nodo
$ sudo pcs resource cleanup webserver
Cleaned up webserver on node1
Cleaned up webserver on node2
Waiting for 1 reply from the controller ... OK
```

### 11.6 Historial de fencing

```
$ sudo pcs stonith history show
We failed reboot node node2 (call 12) on node1 at Wed Aug 12 10:41:02 2026: Timer expired
reboot node node2 (call 13) on node3 at Wed Aug 12 10:41:19 2026: OK

# Bajo nivel
$ sudo stonith_admin --history '*' --verbose
```

### 11.7 Logs y auditoría de transiciones

```
# El log central de Pacemaker
$ sudo journalctl -u pacemaker -u corosync -f

# Extraer la última transición del scheduler (pe-input) para post-mortem
$ ls -t /var/lib/pacemaker/pengine/pe-input-*.bz2 | head -1
/var/lib/pacemaker/pengine/pe-input-482.bz2

$ sudo crm_simulate -x /var/lib/pacemaker/pengine/pe-input-482.bz2 -S
# Reproduce EXACTAMENTE la decisión que tomó el cluster en ese momento.
```

### 11.8 Modos de fallo frecuentes y su causa raíz

| Síntoma | Causa raíz probable | Diagnóstico / remedio |
|---|---|---|
| Todos los recursos parados, `partition WITHOUT quorum` | Partición minoritaria, `no-quorum-policy=stop` | `corosync-quorumtool`; restaurar conectividad o añadir qdevice |
| Un recurso `Stopped` con `unmanaged` | Fallo de stop → cluster espera fencing | `pcs stonith status`; verificar que el fence device funciona |
| **Fence loop** (nodos reiniciándose en bucle) | El nodo arranca, no logra quorum, se auto-fencea; o fencing mal configurado se dispara mutuamente | Deshabilitar arranque de cluster (`pcs cluster disable`), corregir `corosync.conf`, revisar `SBD_STARTMODE` |
| Recurso `FAILED` con `rc=5 not installed` | Paquete/binario ausente en el nodo destino | `crm_verify -LV`; instalar dependencias en TODOS los nodos |
| `pcs status` muestra `pending` en fencing | El fence agent no alcanza el BMC/PDU | `fence_ipmilan -o status ...` manual; revisar red de gestión |
| Ambos nodos activos con la misma VIP (split-brain) | `stonith-enabled=false` + partición de red | **Nunca** deshabilitar STONITH; reconstruir con fencing |
| Anillo Corosync `FAULTY` | Pérdida de una red física | `corosync-cfgtool -s`; revisar NIC/switch del anillo afectado |
| Failover no ocurre al matar el nodo activo | Fencing falla → cluster espera indefinidamente (correcto y seguro) | Reparar fencing; el cluster **no** promueve hasta confirmar que el nodo viejo está muerto |

> **Principio de diagnóstico:** cuando el failover "no ocurre", en un cluster bien configurado la causa casi siempre es que **el fencing falló**. Pacemaker prefiere quedarse esperando (servicio caído) antes que arriesgar dos escritores (datos corruptos). Es la decisión correcta: reparar el fencing, no deshabilitarlo.

---

## 12. Referencias

- **LPI — Exam 306 Objectives (306-300, v3.0):** https://www.lpi.org/our-certifications/exam-306-objectives/
- **ClusterLabs — Pacemaker documentation:** https://clusterlabs.org/pacemaker/doc/
- **Pacemaker Administration & Configuration Explained:** https://clusterlabs.org/pacemaker/doc/2.1/Pacemaker_Explained/html/
- **Pacemaker — Clusters from Scratch:** https://clusterlabs.org/pacemaker/doc/2.1/Clusters_from_Scratch/html/
- **Corosync Cluster Engine:** https://corosync.github.io/corosync/
- **corosync.conf(5) man page:** https://manpages.debian.org/corosync.conf.5
- **votequorum(5):** https://manpages.debian.org/votequorum.5
- **kronosnet (knet):** https://kronosnet.org/
- **ClusterLabs — Quorum device (corosync-qdevice / qnetd):** https://manpages.debian.org/corosync-qnetd.8
- **OCF Resource Agents (ClusterLabs):** https://github.com/ClusterLabs/resource-agents
- **Fence Agents:** https://github.com/ClusterLabs/fence-agents
- **SBD (Storage-Based Death):** https://github.com/ClusterLabs/sbd
- **pcs — Pacemaker/Corosync configuration system:** https://github.com/ClusterLabs/pcs
- **crmsh — Pacemaker command line interface:** https://crmsh.github.io/
- **Booth — multi-site cluster ticket manager:** https://github.com/ClusterLabs/booth
- **Red Hat — Configuring and managing high availability clusters (RHEL 9):** https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/configuring_and_managing_high_availability_clusters/
- **SUSE Linux Enterprise High Availability — Administration Guide:** https://documentation.suse.com/sle-ha/