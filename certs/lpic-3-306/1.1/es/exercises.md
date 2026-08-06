# Guía de Estudio de Producción y Ejercicios Guiados: Examen LPIC-3 306-300 (Tema 306.1)
**Examen:** LPIC-3 High Availability and Storage Clusters (306-300, Versión 3.0)  
**Tema:** 306.1 High Availability Cluster Management  
**Peso:** 25  
**Referencia Oficial:** [LPI LPIC-3 306 Objectives](https://www.lpi.org/our-certifications/lpic-3-306-overview/) | [ClusterLabs Documentation](https://clusterlabs.org/pacemaker/doc/)

---

## Ejercicio 1: Arquitectura de Corosync 3 & Pacemaker, Quorum y Mecánica de Split-Brain

### Descripción General de Arquitectura y Mecánica
Corosync proporciona la capa de membresía del cluster y mensajería (a través del protocolo de transporte **Kronosnet / knet** en despliegues modernos), mientras que Pacemaker actúa como el Distributed Resource Manager (CRM). 
El Quorum se mantiene utilizando el proveedor `corosync_votequorum`. En un cluster de \(N\) nodos, el quorum requiere:

$$\text{Quorum} = \left\lfloor \frac{N}{2} \right\rfloor + 1$$

En un cluster de 2 nodos (\(N=2\)), la pérdida de un solo nodo reduce los votos a 1 de 2 (50%), perdiendo el quorum a menos que se configure `two_node: 1` o `auto_tie_breaker: 1`.

```
       +---------------------------------------------+
       |             Pacemaker (crmd/pengine)        |
       +---------------------------------------------+
       |               Corosync 3 (knet)             |
       +-------------------------------+-------------+
                                       |
           +---------------------------+---------------------------+
           | Link 0 (192.168.122.10/11)  | Link 1 (10.0.10.10/11)    |
           v                           v
     [ Node-01 ] <=================================> [ Node-02 ]
                     Redundant Knet Links (Ring 0 & 1)
```

---

### Pasos de Ejecución Guiada

#### Paso 1.1: Examinar y Desplegar `corosync.conf` de Producción
Desplegá el siguiente archivo de configuración de Corosync 3 redundante con múltiples enlaces válido en ambos nodos (`node-01` y `node-02`).

Ruta de archivo: `/etc/corosync/corosync.conf`
```ini
totem {
    version: 2
    cluster_name: ha_prod_cluster
    transport: knet
    crypto_cipher: aes256
    crypto_hash: sha256
}

nodelist {
    node {
        ring0_addr: 192.168.122.10
        ring1_addr: 10.0.10.10
        nodeid: 1
        name: node-01
    }
    node {
        ring0_addr: 192.168.122.11
        ring1_addr: 10.0.10.11
        nodeid: 2
        name: node-02
    }
}

quorum {
    provider: corosync_votequorum
    two_node: 1
    wait_for_all: 1
    auto_tie_breaker: 0
}

logging {
    to_logfile: yes
    logfile: /var/log/cluster/corosync.log
    to_syslog: yes
    syslog_facility: daemon
    debug: off
    timestamp: on
    logger_subsys {
        subsys: QUORUM
        debug: off
    }
}
```

#### Paso 1.2: Iniciar Servicios e Inspeccionar el Estado de los Enlaces Knet
Ejecutá los siguientes comandos en `node-01`:

```bash
systemctl restart corosync pacemaker
corosync-cfgtool -s
```

**Salida de Comando Esperada:**
```text
Printing link status.
Ring ID 0
	nodeid: 1
	host: 192.168.122.10
	status: enabled connected
Ring ID 1
	nodeid: 1
	host: 10.0.10.10
	status: enabled connected
```

#### Paso 1.3: Inspeccionar el Quorum mediante el Mapa en Tiempo de Ejecución (`corosync-cmapctl`)
Verificá el conteo activo de votos y la membresía de nodos:

```bash
corosync-cmapctl | grep -E "quorum\.(quorate|total_votes|expected_votes)"
```

**Salida de Comando Esperada:**
```text
quorum.expected_votes (u32) = 2
quorum.quorate (u8) = 1
quorum.total_votes (u32) = 2
```

---

### Preguntas de Comprensión del Paso 1

1. En un cluster de 2 nodos con `two_node: 1` y `wait_for_all: 1`, ¿qué comportamiento específico en la secuencia de inicio ocurre si `node-01` se enciende mientras `node-02` permanece apagado?
2. Si `ring0_addr` experimenta una falla completa de switch, ¿cómo maneja Corosync 3 Knet la redirección del tráfico a `ring1_addr` y qué métrica determina la salud del enlace?

---

## Ejercicio 2: Mecanismos de STONITH / Fencing y Mecánica de Aislamiento de Nodos

### Descripción General de Arquitectura y Mecánica
STONITH (**S**hoot **T**he **O**ther **N**ode **I**n **T**he **H**ead) previene la corrupción de datos causada por escrituras concurrentes en almacenamiento compartido durante condiciones de split-brain.

Pacemaker aplica una política de **Fence-Before-Recovery**. Cuando un nodo deja de responder a los heartbeats del cluster, el Cluster Resource Manager Daemon (`crmd`) de Pacemaker inicia una acción de fencing. El Policy Engine (`pengine`) **nunca** reasignará ni reiniciará recursos asignados previamente a un nodo no confirmado hasta que el agente de fencing devuelva un estado de salida confirmado (`0`).

```
 +------------------+        Heartbeat Lost       +------------------+
 |  node-01 (Master)| <=========================X |  node-02 (Failed)|
 +------------------+                             +------------------+
          |                                                ^
          | 1. Execute fence_ipmilan / SBD                   |
          +------------------------------------------------+
                             2. Hard Power Off / NMI Watchdog Reset
```

---

### Pasos de Ejecución Guiada

#### Paso 2.1: Configurar el Mecanismo Watchdog de Storage-Based Death (SBD)
Editá la configuración del cluster SBD en ambos nodos para habilitar la integración del watchdog del kernel.

Ruta de archivo: `/etc/sysconfig/sbd` (o `/etc/default/sbd` en Debian/Ubuntu)
```bash
SBD_DEVICE="/dev/sdc1"
SBD_OPTS="-n node-01 -t 10 -4 20"
SBD_WATCHDOG_DEV="/dev/watchdog"
SBD_WATCHDOG_TIMEOUT=5
SBD_TIMEOUT_ACTION="flush,reboot"
SBD_MOVE_TO_ROOT_CGROUP=yes
```

Inicializá el encabezado del disco SBD en todos los nodos:
```bash
sbd -d /dev/sdc1 create
sbd -d /dev/sdc1 dump
```

**Salida de Comando Esperada:**
```text
Header version:     2.1
Number of slots:    255
Sector size:        512
Timeout (watchdog): 5
Timeout (allocate): 2
Timeout (loop):     1
Timeout (msgwait):  10
```

#### Paso 2.2: Registrar el Recurso IPMI STONITH en Pacemaker
Ejecutá en `node-01` usando `pcs`:

```bash
pcs property set stonith-enabled=true
pcs stonith create fence_node02 fence_ipmilan \
    ipaddr="192.168.122.250" \
    login="admin" \
    passwd="SecretPassword123" \
    lanplus=1 \
    action=reboot \
    pcmk_host_list="node-02" \
    delay=15 \
    op monitor interval=60s timeout=20s
```

#### Paso 2.3: Probar la Ejecución de STONITH y el Rastreo Diagnóstico
Simulá una solicitud de fence fuera de banda orientada a `node-02`:

```bash
stonith_admin --reboot node-02
pcs status | grep -A 5 "Fencing Devices"
```

**Salida de Comando Esperada:**
```text
Fencing Devices:
  * Resource: fence_node02 (class=stonith:fence_ipmilan)
    * fence_node02 Started node-01

Node List:
  * Node node-02: UNCLEAN (offline)
```

Inspeccioná el historial de fence de Pacemaker:
```bash
pcs stonith history show
```

**Salida de Comando Esperada:**
```text
Node: node-02
  * Action: reboot, Targeted: node-02, Requested-by: node-01, Client: stonith_admin, Result: success
```

---

### Preguntas de Comprensión del Paso 2

1. ¿Por qué se establece explícitamente el parámetro `delay=15` en `fence_node02` al configurar IPMI fencing en un cluster de dos nodos donde cada nodo tiene su propio dispositivo de agente de fence distinto?
2. ¿Qué sucede con los recursos del cluster de Pacemaker que se ejecutan en `node-02` si el agente de fence `fence_ipmilan` agota el tiempo de espera (timeout) o devuelve un código de salida distinto de cero durante un evento STONITH?

---

## Ejercicio 3: Gestión Avanzada de Recursos, Constraints y Mecánica de Scores

### Descripción General de Arquitectura y Mecánica
La lógica de decisión de ubicación de recursos de Pacemaker está estrictamente impulsada por la **matemática de scores**.
El score final de ubicación de un nodo para un recurso \(R\) dado se calcula como:

$$\text{Score}_{\text{final}}(N) = \text{Score}_{\text{base}} + \sum \text{Score}_{\text{location}} + \sum \text{Score}_{\text{colocation}} + \text{Stickiness} - (\text{FailCount} \times \text{MigrationPenalty})$$

- $\text{INFINITY} = +1,000,000$ (Debe ejecutarse en este nodo)
- $-\text{INFINITY} = -1,000,000$ (**NO** debe ejecutarse en este nodo)

---

### Pasos de Ejecución Guiada

#### Paso 3.1: Definir la VIP Flotante OCF y el Recurso de Almacenamiento DRBD Promocionable
Desplegá un recurso OCF para IP Virtual (`IPaddr2`) y un recurso de almacenamiento Promocionable (Master/Slave).

```bash
# Create Virtual IP Resource
pcs resource create Cluster_VIP ocf:heartbeat:IPaddr2 \
    ip="192.168.122.200" \
    cidr_netmask="24" \
    nic="eth0" \
    op monitor interval=10s timeout=20s

# Create DRBD Data Resource
pcs resource create DRBD_Data ocf:linbit:drbd \
    drbd_resource="r0" \
    op monitor interval=15s role="Unpromoted" \
    op monitor interval=10s role="Promoted"

# Define Promotable Clone
pcs resource promotable DRBD_Data \
    promoted-max=1 \
    promoted-node-max=1 \
    clone-max=2 \
    clone-node-max=1
```

#### Paso 3.2: Configurar Constraints de Recursos Multicapa y Stickiness
Aplicá stickiness de manera global e imponé reglas de ordenamiento y colocación:

```bash
# Set Resource Stickiness (Prevents automatic failback on node recovery)
pcs resource defaults update resource-stickiness=100

# Enforce Colocation: VIP must run where DRBD is Promoted (Master)
pcs constraint colocation add Cluster_VIP with promoted DRBD_Data-clone INFINITY

# Enforce Ordering: DRBD must be Promoted before VIP starts
pcs constraint order promote DRBD_Data-clone then start Cluster_VIP

# Enforce Location Preference for node-01
pcs constraint location Cluster_VIP prefers node-01=50
```

#### Paso 3.3: Verificar la Configuración del Gráfico de Constraints
Mostrá las reglas estructurales mediante la CLI:

```bash
pcs constraint --full
```

**Salida de Comando Esperada:**
```text
Location Constraints:
  Resource: Cluster_VIP
    Enabled on: node-01 (score:50) (id:location-Cluster_VIP-node-01-50)
Ordering Constraints:
  Promote DRBD_Data-clone then start Cluster_VIP (kind:Mandatory) (id:order-DRBD_Data-clone-Cluster_VIP-mandatory)
Colocation Constraints:
  Cluster_VIP with DRBD_Data-clone (score:INFINITY) (rsc-role:Started) (with-rsc-role:Promoted) (id:colocation-Cluster_VIP-DRBD_Data-clone-INFINITY)
```

#### Paso 3.4: Configurar Umbrales de Migración y Probar el Fallback ante Fallas
Configurá las métricas de seguimiento de fallas en `Cluster_VIP`:

```bash
pcs resource update Cluster_VIP meta migration-threshold=2 failure-timeout=60s
```

Simulá una falla de recurso desvinculando por la fuerza la dirección IP secundaria:
```bash
ip addr del 192.168.122.200/24 dev eth0
pcs resource failcount show Cluster_VIP
```

**Salida de Comando Esperada:**
```text
Name: Cluster_VIP
  node-01: 1
```

---

### Preguntas de Comprensión del Paso 3

1. Si `Cluster_VIP` tiene `resource-stickiness=100` y una constraint de ubicación `prefers node-01=50`, ¿dónde se ejecutará `Cluster_VIP` cuando `node-01` se reinicie y vuelva a unirse al cluster saludable? Mostrá el cálculo del score.
2. ¿Cuál es la diferencia operacional entre `kind=Mandatory` (por defecto) y `kind=Optional` en una Constraint de Ordenamiento (Ordering Constraint) de Pacemaker?

---

## Ejercicio 4: Modos de Mantenimiento, Solución de Problemas y Flujos de Trabajo de Diagnóstico del Cluster

### Descripción General de Arquitectura y Mecánica
Durante actualizaciones de software del cluster, parches del kernel o mantenimiento de almacenamiento SAN, los administradores deben suprimir las acciones automatizadas de monitoreo y recuperación de Pacemaker para prevenir disparos de STONITH no deseados o conmutaciones por error (failovers) por falsos positivos.

Pacemaker proporciona dos niveles de aislamiento:
1. **Unmanaged Resource State**: Los monitores y llamadas de acción están deshabilitados para un recurso específico.
2. **Cluster Maintenance Mode**: Supresión global de todas las acciones de fence y monitoreo de recursos.

---

### Pasos de Ejecución Guiada

#### Paso 4.1: Entrar en Modos de Mantenimiento

##### Opción A: Modo de Mantenimiento de un Solo Nodo
```bash
pcs node maintenance node-02
pcs status
```

**Salida de Comando Esperada:**
```text
Cluster name: ha_prod_cluster
Cluster Summary:
  * Stack: corosync
  * Current DC: node-01 (version 2.1.5) - partition with quorum
  * Last updated: Thu Aug  6 17:13:08 2026
  * Last change:  Thu Aug  6 17:10:00 2026 by root via cibadmin on node-01
  * 2 nodes configured
  * 2 resource instances configured

Node List:
  * Node node-01: online
  * Node node-02: maintenance

Full List of Resources:
  * Cluster_VIP	(ocf::heartbeat:IPaddr2):	Started node-01
  * DRBD_Data-clone	(ocf::linbit:drbd):
    * Promoted: node-01
    * Unmanaged: [ node-02 ]
```

##### Opción B: Modo de Mantenimiento Global del Cluster
```bash
pcs property set maintenance-mode=true
pcs property show maintenance-mode
```

**Salida de Comando Esperada:**
```text
Cluster Properties Settings:
  maintenance-mode: true
```

#### Paso 4.2: Realizar Análisis Diagnóstico mediante Inspección de Logs y CIB
Ejecutá las comprobaciones de cordura (sanity checks) estándar del cluster:

```bash
crm_verify -L -V
```

**Salida de Comando Esperada (Configuración Limpia):**
```text
(No output returned indicates zero syntax or structural CIB errors)
```

Extraé la configuración activa del cluster en formato XML plano para verificar los IDs de ejecución de las constraints:
```bash
pcs cluster cib | grep -i "nvpair" | head -n 5
```

Analizá el estado del motor de enlace Knet de Corosync directamente desde los logs del kernel:
```bash
journalctl -u corosync --since "10 minutes ago" | grep -E "KNET|QUORUM"
```

**Salida de Comando Esperada:**
```text
corosync[1234]: [KNET  ] link: Host 2 link 0 is online
corosync[1234]: [KNET  ] link: Host 2 link 1 is online
corosync[1234]: [QUORUM] Members[2]: 1 2
corosync[1234]: [QUORUM] Quorate status set: true
```

#### Paso 4.3: Desactivar el Modo de Mantenimiento y Limpiar Conteo de Fallas
```bash
pcs property set maintenance-mode=false
pcs node maintenance node-02 --off
pcs resource cleanup
```

**Salida de Comando Esperada:**
```text
Cleaned up all resources on all nodes
```

---

### Preguntas de Comprensión del Paso 4

1. ¿Qué ocurre si un administrador de sistemas detiene manualmente un servicio de systemd (ej. `systemctl stop apache2`) mientras el cluster de Pacemaker está en `maintenance-mode=true` versus cuando `maintenance-mode=false`?
2. Explicá la utilidad diagnóstica del comando `crm_simulate -s -v` antes de aplicar cambios de CIB en producción.

---

<details>
<summary><strong>Hacé clic para ver las Respuestas de los Ejercicios y las Explicaciones Técnicas</strong></summary>

### Respuestas al Ejercicio 1

1. **Comportamiento en la Secuencia de Inicio:**  
   Debido a que `wait_for_all: 1` está establecido explícitamente, `node-01` **no** establecerá quorum al iniciar solo, aunque `two_node: 1` esté habilitado. Corosync requiere que *ambos* nodos se unan al cluster al menos una vez tras el inicio inicial del cluster para establecer una membresía de línea base. Hasta que `node-02` se conecte, `node-01` permanece en un estado sin quorum (unquorate), lo que impide que Pacemaker inicie recursos. Esto previene escenarios de split-brain en los que un nodo se enciende tras una caída total y asume autoridad sin conocer el estado de su par.

2. **Mecánica de Redundancia de Corosync Knet:**  
   Corosync 3 Knet monitorea continuamente la latencia del enlace y la pérdida de paquetes utilizando heartbeats activos en todos los enlaces Knet configurados (`ring0` y `ring1`). Si `ring0` falla, Knet cambia sin problemas el transporte de paquetes a `ring1` sin perder la membresía del cluster ni disparar un evento de recálculo de quorum. Knet evalúa la salud del enlace en función de la `latency`, el `packet loss threshold` y los diagnósticos de MTU del enlace definidos en los parámetros de Knet.

---

### Respuestas al Ejercicio 2

1. **Demora del Fence de IPMI (`delay=15`):**  
   En un cluster de dos nodos, si ambos nodos pierden la comunicación del cluster simultáneamente (ej. falla en el ring de Knet), ambos nodos podrían intentar realizar un fence mutuamente al mismo tiempo (una carrera de fencing / fencing race). Agregar `delay=15` a la configuración de fence para `node-02` (o asignar diferentes demoras a cada nodo) introduce una asimetría intencional. Esto garantiza que `node-01` ejecute su acción de STONITH primero, reiniciando exitosamente a `node-02` y tomando el control de los recursos de manera limpia, en lugar de hacer que ambos nodos se apaguen mutuamente en el mismo instante.

2. **Mecánica de Recuperación de STONITH No Confirmado:**  
   Si `fence_ipmilan` devuelve un código de salida distinto de cero o agota el tiempo de espera, Pacemaker trata la operación de STONITH como **FALLIDA** (**FAILED**). Bajo su estricta garantía de seguridad, Pacemaker considera que `node-02` está en un estado `UNCLEAN`. **NUNCA** iniciará ni migrará los recursos de `node-02` hacia `node-01` mientras el estado de energía de `node-02` permanezca sin confirmar. El cluster detiene todas las operaciones de recuperación para esos recursos para evitar escrituras concurrentes y corrupción de datos. Se requiere la intervención manual del administrador mediante `stonith_admin --confirm` para borrar por la fuerza el estado del nodo no despejado.

---

### Respuestas al Ejercicio 3

1. **Cálculo del Score y Ubicación Pegajosa (Sticky Placement):**  
   Cuando `node-01` vuelve a unirse al cluster, el score de ubicación para `Cluster_VIP` se calcula de la siguiente manera:
   - En `node-02` (donde `Cluster_VIP` se ejecuta actualmente): Base Score + Location Score (0) + Resource Stickiness (100) = **100**.
   - En `node-01` (nodo que se vuelve a unir): Base Score + Location Preference (50) + Resource Stickiness (0, dado que actualmente no se ejecuta allí) = **50**.

   Dado que `node-02` (score 100) supera a `node-01` (score 50), `Cluster_VIP` **permanece en `node-02`**. Esto evita la alternancia/tiempo de inactividad inútil por failback automático del recurso.

2. **Constraints de Orden Obligatorias vs. Opcionales (Mandatory vs. Optional):**  
   - **Mandatory (`kind=Mandatory`):** El Recurso B *nunca* se iniciará a menos que el Recurso A se inicie/promocione con éxito primero. Si el Recurso A falla al iniciar, la ejecución del Recurso B se bloquea por completo.
   - **Optional (`kind=Optional`):** El Recurso B se iniciará después del Recurso A *si* el Recurso A se está iniciando al mismo tiempo. Sin embargo, si el Recurso A falla al iniciar, todavía se permite que el Recurso B se inicie de forma independiente.

---

### Respuestas al Ejercicio 4

1. **Comportamiento del Detenido Manual por Systemd en Modos de Mantenimiento:**  
   - Cuando `maintenance-mode=true`: Pacemaker ignora por completo los cambios de estado del sistema local. Detener `apache2` mediante `systemctl` no causa ninguna reacción por parte de Pacemaker. No se ejecutan operaciones de monitoreo, no aumentan los conteos de fallas y no ocurren acciones de fencing ni de failover.
   - Cuando `maintenance-mode=false`: Durante la siguiente operación programada de monitoreo OCF/systemd, Pacemaker detecta que `apache2` se detuvo inesperadamente. Incrementa el failcount del recurso en ese nodo, dispara intentos de reinicio local y, si se alcanza el `migration-threshold`, conmuta el servicio (failover) a otro nodo (o invoca STONITH si está configurado).

2. **Utilidad Diagnóstica de `crm_simulate`:**  
   La herramienta `crm_simulate` permite a un administrador probar escenarios hipotéticos ("what-if") sobre el CIB actual sin modificar el estado del cluster en producción. Utilizando `crm_simulate -s -v`, podés simular fallas de nodos, pérdida de enlaces o cambios de configuración (ej. agregar constraints) para previsualizar cómo el Policy Engine (`pengine`) de Pacemaker calculará los scores y realizará la transición de estados de los recursos.

</details>