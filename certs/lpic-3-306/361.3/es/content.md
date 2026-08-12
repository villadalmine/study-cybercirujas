# LPIC-3 306 — Tema 361.3: Failover Clusters

> Examen 306-300, versión 3.0 · Peso del objetivo: **13.34** · Enfoque: clustering de failover activo/pasivo y multi-estado con Pacemaker + Corosync, fencing (STONITH), quórum, restricciones (constraints) y diagnóstico operativo.

---

## 1. El problema en producción: qué te da realmente un failover cluster

Un *failover cluster* mantiene disponible un **servicio con estado y de escritor único (single-writer)** ante la falla de un nodo, un enlace, un disco o un rack entero — sin permitir jamás que dos nodos crean que son dueños del mismo recurso al mismo tiempo. Esa última cláusula es toda la disciplina. La disponibilidad es fácil; lo difícil es la **integridad ante una partición**.

Considerá el incidente canónico de producción. Corrés PostgreSQL como un par primary/standby con una IP de servicio flotante `10.0.10.100`. El kernel del primary sufre un soft-lock: deja de responder a la red, pero sus discos y sus backends `postgres` siguen muy vivos. Tu monitoreo asciende el standby a primary y mueve la VIP. Noventa segundos después el nodo original se recupera, todavía con su viejo alias de VIP y todavía aceptando escrituras en su directorio de datos. Ahora tenés **dos primaries escribiendo WAL divergente** sobre lo que tus aplicaciones creen que es una sola base de datos. Esto es *split-brain*, y ninguna lógica de "el standby está más sano" lo previene — el nodo enfermo nunca aceptó rendirse.

Un failover cluster resuelve esto con tres mecanismos que cooperan, y tenés que entender dónde vive cada uno:

| Preocupación | Pregunta que responde | Capa | Componente Linux |
|---|---|---|---|
| **Membresía y mensajería** | ¿Qué nodos pueden hablar, ahora mismo? | Totem / knet | **Corosync** |
| **Quórum** | ¿Es *mi* partición la autoritativa? | votequorum | **Corosync** (`votequorum`) + `qdevice` opcional |
| **Orquestación de recursos** | ¿Qué debe correr dónde, y en qué orden? | Cluster Resource Manager | **Pacemaker** |
| **Fencing** | ¿Cómo *garantizo* que el otro lado está muerto antes de tomar el control? | STONITH | **Pacemaker** `pacemaker-fenced` + fence agents / SBD |

La verdad arquitectónica no negociable de este tema: **no podés hacer failover de un recurso compartido o de escritor único hasta no haberle hecho fencing de forma confirmada al dueño anterior.** "Dejó de responder" no es evidencia de que dejó de escribir. El fencing convierte una *suposición* ("probablemente está muerto") en un *hecho* ("le corté la energía / le corté el acceso al disco"). Cada decisión de diseño de aquí en adelante surge de eso.

---

## 2. Arquitectura en profundidad

### 2.1 El stack de dos capas

```
        ┌──────────────────────────────────────────────────────────┐
        │                      Pacemaker (CRM)                       │
        │  pacemakerd ── supervises ──▶ the daemons below            │
        │   ├── pacemaker-based       (CIB manager: the XML config)  │
        │   ├── pacemaker-controld    (controller / DC election)     │
        │   ├── pacemaker-schedulerd   (policy engine → transition)  │
        │   ├── pacemaker-execd        (runs resource agents)        │
        │   ├── pacemaker-fenced       (STONITH / fencing)           │
        │   └── pacemaker-attrd        (transient node attributes)   │
        └───────────────▲───────────── CPG API ─────────────────────┘
                        │ (closed process group messaging + membership + quorum)
        ┌───────────────┴──────────────────────────────────────────┐
        │                       Corosync                             │
        │   Totem SRP / Kronosnet (knet) transport                   │
        │   votequorum  ·  CPG  ·  cmap (runtime config map)         │
        └────────────────────────────────────────────────────────────┘
```

**Corosync** es el sustrato. Ejecuta el protocolo **Totem** (un protocolo de membresía/ordenamiento por paso de token) sobre el transporte **knet** (el valor por defecto en Corosync 3.x — soporta hasta 8 enlaces redundantes, cifrado por enlace, compresión y failover de enlace automático). Corosync le da a Pacemaker tres servicios: **CPG** (mensajería de grupo confiable y totalmente ordenada), **membresía** (quién está arriba) y **votequorum** (si esta partición tiene quórum).

**Pacemaker** es el cerebro. Nunca habla con la red directamente para la membresía del cluster — se *suscribe* a Corosync. Sus daemons dividen las responsabilidades:

- **`pacemaker-based`** (el gestor de la CIB) es dueño de la **Cluster Information Base**, un documento XML replicado y mantenido consistente en todos los nodos. Todo lo que configurás vive aquí.
- **`pacemaker-controld`** corre en cada nodo; el cluster elige el controld de un nodo como el **DC (Designated Controller)**. El DC es el único nodo que *computa* las decisiones.
- **`pacemaker-schedulerd`** (el policy engine) corre en el DC. Dado el CIB + estado actual, computa un **transition graph**: el conjunto ordenado de acciones de recursos necesarias para alcanzar el estado deseado. Es una función pura — misma entrada, misma salida — que es exactamente lo que hace posible `crm_simulate`.
- **`pacemaker-execd`** ejecuta los resource agents localmente (sin privilegios donde es posible). Es el único componente que toca tu servicio real.
- **`pacemaker-fenced`** ejecuta el fencing. Está deliberadamente separado para que el fencing pueda ocurrir incluso cuando la gestión de recursos está trabada.
- **`pacemaker-attrd`** gestiona los atributos de nodo (p. ej., un resource agent registrando el lag de replicación).

### 2.2 La CIB: un árbol XML para gobernarlos a todos

Todo — nodos, recursos, constraints, defaults y estado en vivo — es un solo documento. Rara vez lo editás a mano, pero tenés que poder leerlo, porque cada herramienta (`pcs`, `crmsh`) es un front-end que se renderiza a esto.

```xml
<cib crm_feature_set="3.16.2" validate-with="pacemaker-3.9" epoch="42" num_updates="7" admin_epoch="0" have-quorum="1" dc-uuid="1">
  <configuration>
    <crm_config>
      <cluster_property_set id="cib-bootstrap-options">
        <nvpair id="cib-bootstrap-options-stonith-enabled"   name="stonith-enabled"   value="true"/>
        <nvpair id="cib-bootstrap-options-no-quorum-policy"  name="no-quorum-policy"  value="stop"/>
        <nvpair id="cib-bootstrap-options-cluster-name"      name="cluster-name"      value="pgcluster"/>
      </cluster_property_set>
    </crm_config>
    <nodes>
      <node id="1" uname="node1"/>
      <node id="2" uname="node2"/>
      <node id="3" uname="node3"/>
    </nodes>
    <resources><!-- primitives, groups, clones, promotables --></resources>
    <constraints><!-- location, colocation, order --></constraints>
    <rsc_defaults>
      <meta_attributes id="rsc-options">
        <nvpair id="rsc-options-resource-stickiness"   name="resource-stickiness"   value="100"/>
        <nvpair id="rsc-options-migration-threshold"   name="migration-threshold"   value="3"/>
      </meta_attributes>
    </rsc_defaults>
    <op_defaults>
      <meta_attributes id="op-options">
        <nvpair id="op-options-timeout" name="timeout" value="60s"/>
      </meta_attributes>
    </op_defaults>
  </configuration>
  <status><!-- runtime only: never edit; regenerated by the cluster --></status>
</cib>
```

Invariantes clave para internalizar:

- **`epoch`/`num_updates`/`admin_epoch`** forman la versión de la CIB. En un merge de partición gana la versión *más alta* — así es como se descarta la config obsoleta de un nodo que se reincorpora, en lugar de que sobrescriba la que está en vivo.
- La mitad `<configuration>` es lo que gestionás. La mitad `<status>` es propiedad de la máquina; tratala como de solo lectura. `crm_verify` valida la primera contra el schema nombrado en `validate-with`.

### 2.3 Resource agents (la abstracción que hace que un servicio sea "clusterizable")

Pacemaker nunca sabe qué es "PostgreSQL". Conoce *resource agents* — ejecutables que implementan un conjunto fijo de verbos. La **clase** determina la convención de llamada:

| Clase | Ejemplo | start/stop | monitor | promote/demote | Parámetros | Notas |
|---|---|---|---|---|---|---|
| **ocf** | `ocf:heartbeat:IPaddr2` | ✅ | ✅ (rico) | ✅ | ✅ tipados, validados | La única clase totalmente cluster-aware. Usala. |
| **systemd** | `systemd:nginx` | ✅ | ✅ (active/failed) | ❌ | ❌ | Cómodo, pero sin parámetros y con chequeo de salud superficial. Cuidado si la unit también está habilitada en el arranque → doble start. |
| **lsb** | `lsb:myapp` | ✅ | ⚠️ solo status | ❌ | ❌ | `/etc/init.d` heredado; debe cumplir LSB o el monitor miente. |
| **service** | `service:foo` | ✅ | varía | ❌ | ❌ | Se resuelve automáticamente a systemd/lsb. |
| **stonith** | `stonith:fence_ipmilan` | n/a | ✅ | n/a | ✅ | Fence agents; gestionados por `pacemaker-fenced`. |

**Los códigos de retorno OCF son el contrato** — un `monitor` que devuelve el código equivocado es la causa más común de failovers fantasma:

| Código | Símbolo | Significado para el cluster |
|---|---|---|
| 0 | `OCF_SUCCESS` | En ejecución (o, para promote, ahora Promoted) |
| 1 | `OCF_ERR_GENERIC` | Error blando → reintentará/recuperará |
| 2 | `OCF_ERR_ARGS` | Invocación incorrecta |
| 5 | `OCF_ERR_INSTALLED` | Binario/paquete faltante → **ni siquiera lo intentará en otro lado de la misma forma** |
| 6 | `OCF_ERR_CONFIGURED` | Config inválida → fatal, sin failover |
| 7 | `OCF_NOT_RUNNING` | Detenido limpiamente (esperado durante el monitor de una instancia detenida) |
| 8 | `OCF_RUNNING_MASTER` | En ejecución **y promovido** |
| 9 | `OCF_FAILED_MASTER` | La instancia promovida está rota → demote/recover |

### 2.4 *Formas* de recursos

- **primitive** — una instancia de un servicio.
- **group** — un stack ordenado y colocado. Los miembros arrancan de izquierda→derecha, se detienen de derecha→izquierda, y siempre aterrizan en el mismo nodo. Azúcar sintáctico para el 90% de los casos activo/pasivo (VIP → filesystem → daemon).
- **clone** — el mismo primitive en N nodos. *Anonymous* (sin estado, p. ej. un agente de monitoreo) o *globally-unique* (cada copia distinta).
- **promotable clone** (antes *master/slave*, ahora **Promoted/Unpromoted**) — un clone cuyas instancias tienen dos roles en runtime. Así es como PostgreSQL/DRBD/GaleraArbitrator modelan "un primary, N réplicas". El RA implementa `promote`/`demote`/`notify`.

---

## 3. Comparaciones de diseño y trade-offs

### 3.1 Failover cluster vs. load-balanced cluster (por qué 361.3 ≠ 361.2)

| Dimensión | Failover cluster (este tema) | Load-balanced cluster |
|---|---|---|
| Modelo de concurrencia | **Un único dueño activo** por recurso | Todos los backends activos |
| Estado | Con estado / escritor único (DB, filesystem, VIP) | Idealmente sin estado |
| Respuesta a fallas | Migrar la propiedad después del **fencing** | Sacar un backend del pool |
| Riesgo de split-brain | **Alto** — el problema central | Bajo (sin estado de escritura compartido) |
| Stack típico | Pacemaker + Corosync + STONITH | LVS/IPVS, HAProxy, keepalived |
| Tiempo de recuperación | segundos → decenas de segundos (fence + start) | sub-segundo (expulsión por health-check) |

### 3.2 Herramientas de front-end: `pcs` vs `crmsh`

| | `pcs` | `crmsh` (`crm`) |
|---|---|---|
| Origen / por defecto en | Familia Red Hat (RHEL, Rocky, Alma), ahora también SUSE | SUSE / openSUSE históricamente |
| Dependencia de daemon | Necesita **`pcsd`** corriendo (también hace auth de nodos, sync de config, web UI en :2224) | Sin daemon; edita la CIB directamente |
| Modelo de auth | Auth de host basada en tokens (`pcs host auth`) | Depende del SSH/hacluster que configures |
| Edición por lotes | `pcs cluster cib` → editar archivo → `pcs cluster cib-push` | `crm configure edit` (shell interactiva, commit atómico) |
| Curva de aprendizaje | Verbo-sustantivo, descubrible | Más conciso, potente sub-shell `configure` |

Ambos compilan a la misma CIB; elegí el que trae tu distro y mantené la consistencia. El examen espera fluidez en **ambos** para leer, y `pcs` para operar.

### 3.3 Métodos de fencing

| Método | Agente | Mata mediante | Necesita | Mejor para | Trampa |
|---|---|---|---|---|---|
| **IPMI/BMC** | `fence_ipmilan` | Apagado/ciclo de energía vía placa out-of-band | BMC alcanzable en una red **separada** | Bare metal | Si el BMC comparte la energía/switch del nodo fallado, no puede hacer fence |
| **PDU** | `fence_apc`, `fence_apc_snmp` | Cortando la toma | PDU gestionable | Bare metal, sin BMC | Los servidores de doble cordón necesitan que se corten ambas tomas |
| **Hypervisor** | `fence_vmware_soap`, `fence_xvm`, `fence_kubevirt` | Destruyendo la VM | Acceso a la API del host | Clusters virtualizados | La API del host es un nuevo SPOF |
| **Cloud** | `fence_aws`, `fence_gce`, `fence_azure_arm` | Detener/terminar la instancia | Credenciales de cloud/IAM | Cloud IaaS | Latencia de API; alcance de IAM |
| **Storage fencing** | `fence_scsi`, `fence_mpath` | Expulsión de reserva SCSI-3 PR | LUN compartido con soporte PR | Clusters de disco compartido | *Corta la I/O, no reinicia* — el nodo puede seguir corriendo |
| **SBD (poison pill)** | `fence_sbd` (disco) / diskless | Auto-reset por watchdog disparado por mensaje en disco o pérdida de quórum | Watchdog de hardware/softdog + (opcional) dispositivo de bloque compartido | Clusters sin un fence de energía | Los timeouts del watchdog deben ajustarse con precisión |

**Regla general:** preferí un fence de *energía/aislamiento* (IPMI/PDU/hypervisor/cloud) como nivel 1. Agregá **SBD** como red de seguridad de auto-fencing (nivel de fence 2) cuando el camino primario pueda quedar inalcanzable. Dos métodos independientes = una **topología de fencing**.

### 3.4 Estrategias de quórum para un cluster de 2 nodos (la trampa clásica)

Dos nodos no pueden votar una mayoría cuando se separan — cada lado ve 1 de 2. Opciones:

| Estrategia | Config | Comportamiento ante partición | Trade-off |
|---|---|---|---|
| `two_node: 1` | corosync votequorum | Ambos lados siguen "con quórum"; **depende enteramente del fencing + `pcmk_delay`** para romper el empate | Simple, pero es posible una fence race sin ajustar los delays |
| **QDevice** (`corosync-qnetd`) | Un tercer host árbitro corre `qnetd`; los nodos corren `qdevice` | El árbitro emite el voto decisivo → mayoría real | La mejor respuesta; necesita un host pequeño siempre encendido |
| **Diskless SBD** | `stonith-watchdog-timeout` | Perder el quórum → el nodo se auto-fencea vía watchdog | Sin host extra, pero un corte total de red puede fencear a *ambos* |
| **Shared-disk SBD** | `fence_sbd` + LUN compartido | Poison pill en almacenamiento compartido | Necesita almacenamiento compartido alcanzable por ambos |

`two_node: 1` **habilita implícitamente** `wait_for_all: 1`: después de un arranque en frío el cluster se niega a tener quórum hasta haber visto *ambos* nodos al menos una vez — evitando que un único superviviente fencee a un peer que nunca conoció.

---

## 4. Infraestructura completa, sin recortes

El escenario de abajo es un **cluster de 3 nodos** (`node1`, `node2`, `node3`) que provee:
1. Un **web stack activo/pasivo** — VIP flotante + Apache en un group.
2. Un **PostgreSQL promotable** (vía PAF `pgsqlms`) que demuestra el failover multi-estado.
3. **Fencing IPMI** con escalonamiento por nodo, más **SBD diskless** como red de seguridad por watchdog.
4. **QDevice no es necesario con 3 nodos** (mayoría natural), pero se muestra la variante de 2 nodos como contraste.

Redes: `10.0.10.0/24` (servicio/ring0), `10.0.20.0/24` (ring1 dedicado para la redundancia de Corosync), BMCs en `10.0.30.0/24`.

### 4.1 `/etc/corosync/corosync.conf` — knet, dos enlaces, cifrado

```ini
# /etc/corosync/corosync.conf  — Corosync 3.x (knet transport)
totem {
    version:        2
    cluster_name:   pgcluster
    transport:      knet          # default in Corosync 3; enables multi-link + crypto
    crypto_cipher:  aes256        # encrypt on-wire cluster traffic
    crypto_hash:    sha256        # authenticate (replaces the old plain authkey-only model)

    # token loss detection. Default is 1000 ms. On virtualized / busy nodes,
    # raise it to avoid spurious membership churn. Effective token for knet =
    # token + (nodes - 2) * token_coefficient (token_coefficient default 650 ms).
    token:              3000
    token_coefficient:  650
    # Number of consecutive token losses before declaring the ring faulty.
    token_retransmits_before_loss_const: 10
}

nodelist {
    node {
        ring0_addr: 10.0.10.11    # LINK 0
        ring1_addr: 10.0.20.11    # LINK 1 (independent NIC + switch)
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

quorum {
    provider: corosync_votequorum
    # For the 2-node variant instead of 3 nodes, you would set:
    #   two_node: 1          # implies wait_for_all: 1
    # and add a qdevice{} block pointing at a corosync-qnetd arbiter.
}

logging {
    to_logfile:   yes
    logfile:      /var/log/cluster/corosync.log
    to_syslog:    yes
    timestamp:    on
    debug:        off
}
```

El secreto compartido para `crypto_*` vive en `/etc/corosync/authkey` (modo `0400`, solo root), generado una vez y copiado a cada nodo:

```bash
$ corosync-keygen                 # writes /etc/corosync/authkey (2048 bits from /dev/urandom)
Corosync Cluster Engine Authentication key generator.
Gathering 2048 bits for key from /dev/urandom.
Writing corosync key to /etc/corosync/authkey.
$ scp /etc/corosync/authkey node2:/etc/corosync/authkey
$ scp /etc/corosync/authkey node3:/etc/corosync/authkey
```

### 4.2 El script de build con `pcs` (idempotente, de punta a punta)

```bash
#!/usr/bin/env bash
# build-cluster.sh — run from node1. Idempotent: re-running only reconciles drift.
set -euo pipefail

# --- 0. Prereqs on every node (packages + hacluster password + daemons) -------
for n in node1 node2 node3; do
  ssh "$n" 'dnf install -y pacemaker corosync pcs fence-agents-ipmilan sbd resource-agents'
  ssh "$n" 'echo "hacluster:S3cureCluster!" | chpasswd'
  ssh "$n" 'systemctl enable --now pcsd'
done

# --- 1. Authenticate the pcsd nodes to each other ------------------------------
pcs host auth node1 node2 node3 -u hacluster -p 'S3cureCluster!'

# --- 2. Create the cluster (writes corosync.conf + authkey to all nodes) --------
pcs cluster setup pgcluster \
    node1 addr=10.0.10.11 addr=10.0.20.11 \
    node2 addr=10.0.10.12 addr=10.0.20.12 \
    node3 addr=10.0.10.13 addr=10.0.20.13 \
    transport knet crypto_cipher=aes256 crypto_hash=sha256 \
    totem token=3000

# --- 3. Start + enable on boot -------------------------------------------------
pcs cluster start --all
pcs cluster enable --all

# --- 4. Cluster-wide properties -------------------------------------------------
pcs property set stonith-enabled=true
pcs property set no-quorum-policy=stop           # safest default for stateful data
pcs resource defaults update resource-stickiness=100
pcs resource defaults update migration-threshold=3

# --- 5. Fencing level 1: IPMI, one stonith device per target -------------------
# pcmk_delay_base staggers simultaneous fence attempts so a 2-way race can't
# power both nodes off. (Not strictly needed at 3 nodes, shown for completeness.)
pcs stonith create fence-node1 fence_ipmilan \
    pcmk_host_list="node1" ip=10.0.30.11 username=fenceadm password=REDACTED \
    lanplus=1 pcmk_delay_base=0s   op monitor interval=60s
pcs stonith create fence-node2 fence_ipmilan \
    pcmk_host_list="node2" ip=10.0.30.12 username=fenceadm password=REDACTED \
    lanplus=1 pcmk_delay_base=5s   op monitor interval=60s
pcs stonith create fence-node3 fence_ipmilan \
    pcmk_host_list="node3" ip=10.0.30.13 username=fenceadm password=REDACTED \
    lanplus=1 pcmk_delay_base=10s  op monitor interval=60s

# Never let a node fence its own IPMI board:
pcs constraint location fence-node1 avoids node1=INFINITY
pcs constraint location fence-node2 avoids node2=INFINITY
pcs constraint location fence-node3 avoids node3=INFINITY

# --- 6. Web stack: VIP + Apache as an ordered, colocated group -----------------
pcs resource create web-vip ocf:heartbeat:IPaddr2 \
    ip=10.0.10.100 cidr_netmask=24 nic=eth0 \
    op monitor interval=10s timeout=20s

pcs resource create web-srv ocf:heartbeat:apache \
    configfile=/etc/httpd/conf/httpd.conf \
    statusurl="http://127.0.0.1/server-status" \
    op monitor interval=20s timeout=30s

pcs resource group add web web-vip web-srv       # start vip→srv, stop srv→vip, colocated

# --- 7. Promotable PostgreSQL (PAF) --------------------------------------------
pcs resource create pgsqld ocf:heartbeat:pgsqlms \
    bindir=/usr/pgsql-15/bin pgdata=/var/lib/pgsql/15/data \
    recovery_template=/etc/postgresql/pg_replica.conf.pcmk \
    op start   timeout=60s  interval=0s \
    op stop    timeout=60s  interval=0s \
    op promote timeout=30s  interval=0s \
    op demote  timeout=120s interval=0s \
    op monitor interval=15s timeout=10s role="Promoted" \
    op monitor interval=16s timeout=10s role="Unpromoted" \
    meta notify=true \
    promotable notify=true promoted-max=1 promoted-node-max=1 clone-max=3 clone-node-max=1

# The DB VIP must live where PostgreSQL is *promoted*:
pcs resource create pg-vip ocf:heartbeat:IPaddr2 \
    ip=10.0.10.101 cidr_netmask=24 nic=eth0 op monitor interval=10s
pcs constraint colocation add pg-vip with promoted pgsqld-clone INFINITY
pcs constraint order promote pgsqld-clone then start pg-vip symmetrical=false kind=Mandatory

# --- 8. Push and verify --------------------------------------------------------
crm_verify -L -V && echo "CIB OK"
pcs status
```

### 4.3 SBD diskless como nivel de fence 2 (auto-reset por watchdog)

```bash
# /etc/sysconfig/sbd  (on every node)
SBD_WATCHDOG_DEV=/dev/watchdog          # hardware watchdog; softdog only as last resort
SBD_WATCHDOG_TIMEOUT=5                   # seconds; the CPU must pet the dog within this
SBD_STARTMODE=always
SBD_PACEMAKER=yes                        # tie SBD liveness to Pacemaker health
SBD_DELAY_START=no
# No SBD_DEVICE line ⇒ diskless mode (watchdog + quorum only).
```

Conectalo a Pacemaker y ponelo por debajo de IPMI:

```bash
$ pcs stonith sbd enable                 # regenerates config across nodes, needs a restart
$ pcs cluster stop --all && pcs cluster start --all
$ pcs property set stonith-watchdog-timeout=10   # must be >= 2 * SBD_WATCHDOG_TIMEOUT

# Fencing topology: try IPMI first, fall back to watchdog self-fence.
$ pcs stonith level add 1 node1 fence-node1
$ pcs stonith level add 2 node1 watchdog
$ pcs stonith level add 1 node2 fence-node2
$ pcs stonith level add 2 node2 watchdog
$ pcs stonith level add 1 node3 fence-node3
$ pcs stonith level add 2 node3 watchdog
```

### 4.4 Aprovisionamiento con Ansible (YAML) — el mismo build, de forma declarativa

```yaml
---
# playbooks/failover-cluster.yml — provisions the Pacemaker/Corosync stack.
- name: Provision Pacemaker failover cluster
  hosts: cluster_nodes            # node1, node2, node3 in inventory
  become: true
  vars:
    cluster_name: pgcluster
    hacluster_password: "S3cureCluster!"
    fence_user: fenceadm
    fence_password: "REDACTED"
  tasks:
    - name: Install HA packages
      ansible.builtin.dnf:
        name:
          - pacemaker
          - corosync
          - pcs
          - fence-agents-ipmilan
          - sbd
          - resource-agents
        state: present

    - name: Set the hacluster password
      ansible.builtin.user:
        name: hacluster
        password: "{{ hacluster_password | password_hash('sha512') }}"

    - name: Enable and start pcsd
      ansible.builtin.systemd:
        name: pcsd
        enabled: true
        state: started

- name: Form the cluster (run once, on the primary)
  hosts: node1
  become: true
  vars:
    cluster_name: pgcluster
    hacluster_password: "S3cureCluster!"
  tasks:
    - name: Authenticate pcsd hosts
      ansible.builtin.command: >
        pcs host auth node1 node2 node3
        -u hacluster -p {{ hacluster_password }}
      register: auth
      changed_when: "'Authorized' in auth.stdout"

    - name: Create the cluster if it does not exist
      ansible.builtin.command: >
        pcs cluster setup {{ cluster_name }}
        node1 addr=10.0.10.11 addr=10.0.20.11
        node2 addr=10.0.10.12 addr=10.0.20.12
        node3 addr=10.0.10.13 addr=10.0.20.13
        transport knet crypto_cipher=aes256 crypto_hash=sha256
      args:
        creates: /etc/corosync/corosync.conf   # idempotency guard

    - name: Start and enable the whole cluster
      ansible.builtin.command: "pcs cluster {{ item }} --all"
      loop: [start, enable]

    - name: Baseline cluster properties
      ansible.builtin.command: "pcs property set {{ item }}"
      loop:
        - stonith-enabled=true
        - no-quorum-policy=stop
```

---

## 5. Operar y observar el cluster (sesiones reales de terminal)

### 5.1 Salud de un vistazo

```console
$ pcs status
Cluster name: pgcluster
Cluster Summary:
  * Stack: corosync (Pacemaker is running)
  * Current DC: node1 (version 2.1.6-9.1.el9-6fdc9deea29) - partition with quorum
  * Last updated: Wed Aug 12 14:22:07 2026 on node1
  * Last change:  Wed Aug 12 14:20:43 2026 by root via cibadmin on node1
  * 3 nodes configured
  * 9 resource instances configured

Node List:
  * Online: [ node1 node2 node3 ]

Full List of Resources:
  * fence-node1        (stonith:fence_ipmilan):  Started node2
  * fence-node2        (stonith:fence_ipmilan):  Started node3
  * fence-node3        (stonith:fence_ipmilan):  Started node1
  * Resource Group: web:
    * web-vip          (ocf:heartbeat:IPaddr2):  Started node1
    * web-srv          (ocf:heartbeat:apache):   Started node1
  * pg-vip             (ocf:heartbeat:IPaddr2):  Started node2
  * Clone Set: pgsqld-clone [pgsqld] (promotable):
    * pgsqld           (ocf:heartbeat:pgsqlms):  Promoted node2
    * pgsqld           (ocf:heartbeat:pgsqlms):  Unpromoted node1
    * pgsqld           (ocf:heartbeat:pgsqlms):  Unpromoted node3

Daemon Status:
  corosync: active/enabled
  pacemaker: active/enabled
  pcsd: active/enabled
```

### 5.2 Membresía y quórum (lado Corosync)

```console
$ corosync-quorumtool -s
Quorum information
------------------
Date:             Wed Aug 12 14:25:31 2026
Quorum provider:  corosync_votequorum
Nodes:            3
Node ID:          1
Ring ID:          1.1a3
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

Salud de enlaces (rings), por nodo, por enlace:

```console
$ corosync-cfgtool -s
Local node ID 1, transport knet
LINK ID 0 udp
	addr	= 10.0.10.11
	status:
		nodeid:   1:	localhost
		nodeid:   2:	connected
		nodeid:   3:	connected
LINK ID 1 udp
	addr	= 10.0.20.11
	status:
		nodeid:   1:	localhost
		nodeid:   2:	connected
		nodeid:   3:	connected
```

### 5.3 Observar un failover en vivo

`crm_mon` es el dashboard del operador. En un panel corré `crm_mon -rfA` (mostrar inactivos `-r`, failcounts `-f`, atributos de nodo `-A`), luego matá de golpe a `node2`:

```console
$ crm_mon -rfA
Cluster Summary:
  * Stack: corosync
  * Current DC: node1 (version 2.1.6) - partition with quorum
  * 3 nodes configured
  * 9 resource instances configured

Node List:
  * Online: [ node1 node3 ]
  * OFFLINE: [ node2 ]

Full List of Resources:
  * fence-node2        (stonith:fence_ipmilan):  Started node3
  * Clone Set: pgsqld-clone [pgsqld] (promotable):
    * pgsqld           (ocf:heartbeat:pgsqlms):  Promoted node1      # promoted here now
    * pgsqld           (ocf:heartbeat:pgsqlms):  Unpromoted node3
    * pgsqld           (ocf:heartbeat:pgsqlms):  Stopped (node2 offline)
  * pg-vip             (ocf:heartbeat:IPaddr2):  Started node1

Node Attributes:
  * Node: node1:
    + master-pgsqld    : 1001
  * Node: node3:
    + master-pgsqld    : 1000

Migration Summary:
```

El log del controller correspondiente muestra la cadena exacta — **primero fence, después promote**. Este orden es el punto central:

```console
$ journalctl -u pacemaker -n 12 --no-pager
node1 pacemaker-controld  [1123] notice: State transition S_IDLE -> S_POLICY_ENGINE
node1 pacemaker-schedulerd[1120] warning: Cluster node node2 will be fenced: peer is no longer part of the cluster
node1 pacemaker-schedulerd[1120] notice: Scheduling Node node2 for STONITH
node1 pacemaker-fenced     [1117] notice: Requesting that node3 perform 'reboot' of node2
node3 pacemaker-fenced     [1119] notice: Operation 'reboot' [4451] for node2 using fence-node2 returned 0 (OK)
node1 pacemaker-fenced     [1117] notice: Peer node2 was terminated (reboot) by node3 on behalf of pacemaker-controld: OK
node1 pacemaker-controld  [1123] notice: Peer node2 was fenced: OK — promoting pgsqld on node1
node1 pacemaker-schedulerd[1120] notice: Promote pgsqld:0 ( Unpromoted -> Promoted node1 )
node1 pacemaker-controld  [1123] notice: Initiating promote operation pgsqld_promote_0 on node1
node1 pacemaker-controld  [1123] notice: Transition 47 (Complete=6, Pending=0): Complete
node1 pacemaker-controld  [1123] notice: State transition S_TRANSITION_ENGINE -> S_IDLE
```

### 5.4 Operaciones comunes de día 2

```console
# Graceful maintenance: park node3, then take the whole cluster hands-off.
$ pcs node standby node3
$ pcs property set maintenance-mode=true       # cluster stops monitoring/acting; services keep running
$ pcs property set maintenance-mode=false

# Move the web group off node1 for a reboot (adds a temporary +INF location rule):
$ pcs resource move web node3
$ pcs resource clear web                        # remove the temporary constraint afterwards

# Ban a resource from a node entirely:
$ pcs resource ban pgsqld-clone node3

# Manually promote/relocate the DB primary (controlled switchover):
$ pcs resource move pgsqld-clone --promoted node3
```

---

## 6. Verificación y diagnóstico de fallas

### 6.1 La escalera de verificación — primero los chequeos más baratos

```console
# 1) Does the configuration even validate against the schema?
$ crm_verify -L -V
$   # (silent + exit 0 means valid; errors print with -V)

# 2) What WOULD the scheduler do right now? (dry run, no changes)
$ crm_simulate -sL
Current cluster status:
  * Online: [ node1 node2 node3 ]
  ...
Allocation scores:
native_color: pgsqld:0 allocation score on node1: 1001
native_color: pgsqld:0 allocation score on node2: -INFINITY
promotion_color: pgsqld:0 promotion score on node1: 1001
...
Transition Summary:
  * (no actions required — cluster is in the desired state)

# 3) Any resource failures accumulated?
$ pcs status --full | sed -n '/Migration Summary/,$p'
Migration Summary:
  * Node: node2:
    * web-srv: migration-threshold=3 fail-count=1 last-failure='Wed Aug 12 13:58:02 2026'
```

`crm_simulate` es el diagnóstico estrella: apuntalo a una CIB *guardada* e inyectá eventos para responder "si node2 muere, ¿dónde aterriza todo?" **antes** de que pase:

```console
$ pcs cluster cib > /tmp/cib.xml
$ crm_simulate -x /tmp/cib.xml -S --node-down node2
...
Transition Summary:
  * Fence (reboot) node2 'peer is no longer part of the cluster'
  * Promote    pgsqld:0   ( Unpromoted -> Promoted node1 )
  * Move       pg-vip     ( node2 -> node1 )
  * Start      fence-node2 ( node3 )
```

### 6.2 Playbook de fallas

| Síntoma | Causa probable | Diagnóstico | Solución |
|---|---|---|---|
| Recurso trabado en `Stopped`, `stonith-enabled=true`, pero no corre nada | **No hay un dispositivo de fence funcional** — Pacemaker se niega a arrancar recursos de los que no puede hacer failover de forma segura | `pcs stonith status`; `journalctl -u pacemaker \| grep -i stonith` muestra `Requesting fencing … no device` | Configurá un dispositivo STONITH real. **No** simplemente pongas `stonith-enabled=false` en producción. |
| Un nodo fenceado repetidamente (fence loop) | Token timeout demasiado bajo para un nodo ocupado/virtual; o desfasaje de NTP; o un ring inestable | `corosync-cfgtool -s` (enlace FAULTY), `journalctl` buscando `Token has not been received` | Subí `token`; agregá/arreglá ring1; forzá chrony/NTP; revisá el offload/pause frames de la NIC. |
| Ambos nodos se fencean mutuamente (2 nodos) | Fence race simultánea, sin escalonamiento de delay | Ambos se apagan a la vez | Agregá `pcmk_delay_base`/`pcmk_delay_max` de forma asimétrica; mejor: agregá un QDevice. |
| Recurso `FAILED` que no se recupera | Config del RA incorrecta → devuelve `OCF_ERR_CONFIGURED`(6)/`OCF_ERR_INSTALLED`(5) | `pcs resource debug-start <rsc> --full` corre el RA tal cual e imprime su stderr | Arreglá el parámetro/paquete, luego limpiá la falla (abajo). |
| El cluster no actúa después de una falla | Quórum perdido, `no-quorum-policy=stop` | `corosync-quorumtool -s` → `Quorate: No` | Restaurá el nodo/enlace faltante; o agregá un QDevice; entendé que la política te está *protegiendo*. |
| Los comandos `pcs` dan timeout | `pcsd` caído o nodos sin auth | `systemctl status pcsd`; `pcs host auth …` | Iniciá pcsd; re-autenticá. |

Limpiar una falla resuelta (Pacemaker mantiene un *failcount* que, al llegar a `migration-threshold`, fija el recurso fuera de ese nodo para siempre hasta que se resetee):

```console
$ pcs resource cleanup web-srv         # deletes failcount + re-probes; lets it run there again
Cleaned up web-srv on node2
Waiting for 1 reply from the controller ... got reply (done)

# Inspect / reset a specific failcount manually:
$ crm_failcount --query -r web-srv -N node2
scope=status  name=fail-count-web-srv  value=1
$ crm_resource --refresh --resource web-srv    # force re-probe of real state across the cluster
```

### 6.3 Recuperarse de split-brain / una reincorporación obsoleta

Después de que una partición se sana, gana la CIB con el **`admin_epoch/epoch` más alto** y los cambios de la minoría se descartan — esto es por diseño. Si un nodo antes particionado se reincorpora con un estado de *datos* divergente (p. ej. un viejo primary de PostgreSQL), el trabajo del cluster era haberle hecho **fence** antes de promover al superviviente; al reiniciar vuelve como una réplica `Unpromoted` limpia (PAF lo re-clona/pg_rewind según tu `recovery_template`). Operativamente:

```console
# Confirm the survivor is authoritative and the rejoined node is subordinate:
$ pcs status | grep -E 'Promoted|Unpromoted'
    * pgsqld  (ocf:heartbeat:pgsqlms):  Promoted node1
    * pgsqld  (ocf:heartbeat:pgsqlms):  Unpromoted node2   # rejoined, now a replica

# If a fence was requested but never confirmed, the DC BLOCKS all resource actions
# ("Requesting fencing … " with no "was terminated" follow-up). Never bypass this by
# faking the fence unless you have physically confirmed the node is off:
$ stonith_admin --confirm node2        # DANGER: asserts "I verified node2 is dead" by hand
```

La regla que esto impone, y con la que hay que salir del examen: **un fence no confirmado debe detener el failover, no continuar con él.** Un cluster que mantiene la disponibilidad mientras arriesga una doble escritura ha fallado en su único trabajo real.

---

## 7. Referencias

- LPI — Objetivos del Examen 306 (306-300, v3.0): https://www.lpi.org/our-certifications/exam-306-objectives/
- Portal de documentación de Pacemaker (ClusterLabs): https://clusterlabs.org/pacemaker/doc/
- *Pacemaker Explained* (referencia de configuración): https://clusterlabs.org/pacemaker/doc/2.1/Pacemaker_Explained/html/
- *Pacemaker Administration*: https://clusterlabs.org/pacemaker/doc/2.1/Pacemaker_Administration/html/
- Proyecto Corosync y páginas de manual `corosync.conf(5)` / `votequorum(5)`: https://corosync.github.io/corosync/
- Transporte Kronosnet (knet): https://kronosnet.org/
- ClusterLabs QDevice / `corosync-qnetd`: https://clusterlabs.org/pacemaker/doc/2.1/Pacemaker_Administration/html/quorum.html
- Fencing SBD (Storage-Based Death): https://github.com/ClusterLabs/sbd
- OCF Resource Agents (`resource-agents`, proveedor `heartbeat`): https://github.com/ClusterLabs/resource-agents
- Fence agents: https://github.com/ClusterLabs/fence-agents
- Referencia de `pcs` / `pcsd`: https://clusterlabs.org/pcs/ · página de manual: https://manpages.org/pcs/8
- Documentación de `crmsh` (crm shell): https://crmsh.github.io/
- PAF — PostgreSQL Automatic Failover (agente OCF `pgsqlms`): https://clusterlabs.github.io/PAF/
- Red Hat Enterprise Linux 9 — *Configuring and managing high availability clusters*: https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/configuring_and_managing_high_availability_clusters/index
- SUSE Linux Enterprise High Availability — Administration Guide: https://documentation.suse.com/sle-ha/