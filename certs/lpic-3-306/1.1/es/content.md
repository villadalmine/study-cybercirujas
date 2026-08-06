# Examen LPIC-3 306-300 (v3.0) — Tema 361: High Availability Cluster Management

---

## 1. Motivación y problema arquitectónico de producción

### 1.1 El problema de High Availability en producción
En las plataformas empresariales modernas, las arquitecturas de un solo nodo introducen Single Points of Failure (SPOFs). El tiempo de inactividad no planificado viola directamente los Service Level Agreements (SLAs), incurre en pérdidas financieras y degrada la confianza del usuario. Lograr High Availability (HA) requiere pasar de la confiabilidad de un solo sistema a la tolerancia a fallas distribuida, donde los servicios sobreviven a fallas de hardware, particiones de red, kernel panics y caídas del hipervisor sin intervención manual del operador.

```
+-----------------------------------------------------------------------+
|                         UNPLANNED DOWNTIME COST                       |
+-----------------------------------------------------------------------+
|  Availability Target  | Allowed Downtime/Year | Allowed Downtime/Day  |
+-----------------------+-----------------------+-----------------------+
|  99.9%   (Three Nines)| 8 hours, 45 minutes   | 1 minute, 26 seconds  |
|  99.99%  (Four Nines) | 52 minutes, 35 sec    | 8.64 seconds          |
|  99.999% (Five Nines) | 5 minutes, 15 sec     | 0.86 seconds          |
+-----------------------------------------------------------------------+
```

Para ofrecer una disponibilidad del 99.999%, los arquitectos de sistemas deben calcular:

$$\text{Availability} (A) = \frac{\text{MTBF}}{\text{MTBF} + \text{MTTR}}$$

Donde:
*   **MTBF (Mean Time Between Failures)**: Tiempo promedio de operación entre fallas inherentes del sistema.
*   **MTTR (Mean Time To Repair)**: Tiempo promedio requerido para diagnosticar, aislar, realizar failover y restaurar las operaciones normales.

Minimizar el MTTR requiere detección automatizada de fallas, fencing automatizado y migración instantánea de estado o IP.

---

### 1.2 Fundamentos teóricos del consenso distribuido en clústeres

#### El teorema de imposibilidad FLP (Fischer, Lynch, Paterson, 1985)
En un modelo de red asíncrono, ningún protocolo de consenso determinista puede garantizar tanto **Safety** (nunca alcanzar un acuerdo incorrecto) como **Liveness** (alcanzar eventualmente un acuerdo) en presencia de incluso una sola caída no anunciada de un proceso. El software de clúster de alta disponibilidad debe hacer compromisos explícitos, favoreciendo Safety sobre Liveness durante las divisiones de red para evitar la corrupción de datos.

#### Quorum y prevención de Split-Brain
Cuando el particionamiento de red divide un clúster de $N$ nodos en segmentos aislados, múltiples segmentos podrían intentar asumir la propiedad del almacenamiento compartido o de los recursos IP de forma simultánea. Este estado se conoce como **Split-Brain**.

```
                   +------------------+
                   |  Original Node 1 | (Node crashes or link severs)
                   +--------+---------+
                            |
                 [Network Partitioning]
                            |
           +----------------+----------------+
           |                                 |
           v                                 v
+--------------------+            +--------------------+
| Cluster Segment A  |            | Cluster Segment B  |
|   (Node 1, Node 2) |            |      (Node 3)      |
|    2/3 Votes       |            |     1/3 Votes      |
|   QUORATE (Active) |            |  INQUORATE (Halt)  |
+--------------------+            +--------------------+
```

Para prevenir modificaciones concurrentes a componentes con estado (stateful), los motores de clúster implementan **Quorum**:

$$Q = \left\lfloor \frac{N}{2} \right\rfloor + 1$$

*   Un segmento de clúster es **Quorate** si contiene estrictamente más de $N/2$ votos.
*   Una partición **Inquorate** debe cesar inmediatamente toda ejecución de recursos, desmontar el almacenamiento compartido y liberar las direcciones IP flotantes.
*   **Dilema del Quorum en dos nodos**: En un clúster de 2 nodos ($N=2$), $Q = 2$. Si un nodo falla, el nodo restante tiene 1 voto de 2 ($50\%$), perdiendo el quorum. Para resolver esto, los motores utilizan dispositivos de desempate (por ejemplo, `qdevice` en Corosync) o reglas explícitas de dos nodos (`two_node: 1` con votequorum).

---

### 1.3 Mecánica de Fencing y STONITH
El quorum por sí solo es insuficiente si un nodo que no responde está congelado (por ejemplo, experimentando bloqueos de DMA, cuelgues de kernel o bucles de enrutamiento de red asíncronos) y todavía está escribiendo en el almacenamiento compartido. 

**STONITH (Shoot The Other Node In The Head)** garantiza la integridad de los datos reiniciando o cortando la alimentación por la fuerza a un nodo incommunicado antes de que otro nodo importe sus recursos.

```
+-----------------------------------------------------------------------------------+
|                            STONITH EXECUTION SEQUENCE                             |
+-----------------------------------------------------------------------------------+
| 1. DC (Designated Controller) detects node failure via Corosync heartbeat timeout.|
| 2. Cluster freezes all resource migrations pending STONITH execution.             |
| 3. DC dispatches fencing request to fence_ipmilan agent targeting node2.           |
| 4. Out-of-Band (OOB) management controller (IPMI/iLO/iDRAC) cuts hardware power.  |
| 5. IPMI agent returns success (power state = off) to DC.                         |
| 6. DC releases resource locks and safely recovers services onto node1.            |
+-----------------------------------------------------------------------------------+
```

El fencing opera en dos niveles arquitectónicos principales:
1.  **Node-Level Fencing (Hardware Power Fencing)**: Utiliza IPMI, HPE iLO, Dell iDRAC o switches PDU para forzar operaciones físicas de apagado/ciclo de energía.
2.  **Storage-Level Fencing (SBD - Storage-Based Death)**: Emplea watchdogs por hardware (`/dev/watchdog`) y dispositivos de bloques compartidos (LUNs SAN/iSCSI). Los nodos limpian regularmente un temporizador de watchdog por hardware; si Corosync pierde el quorum o pierde slots de heartbeat en el disco compartido, el watchdog por hardware desencadena un reinicio abrupto por hardware (`sysrq-trigger` kernel panic/reset).

---

## 2. Comparativas técnicas y tablas de balance (Trade-offs)

### 2.1 Arquitecturas de topología de clúster

| Topología de arquitectura | Sincronización de estado | Velocidad de recuperación (RTO) | Requerimientos de almacenamiento | Límite de escalabilidad | Riesgo principal / Modo de falla |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Active / Passive (Hot Standby)** | Replicación a nivel de bloques asíncrona o síncrona (DRBD) | Rápida (5s - 30s) | Almacenamiento replicado por nodo o SAN compartida | Bajo (2 - 4 nodos) | Costo de recursos ociosos; retraso de failover durante la recuperación de la base de datos |
| **Active / Active (Stateful)** | Distributed Lock Manager (DLM) + Clustered FS (GFS2/OCFS2) | Cero / Casi instantánea | Almacenamiento compartido (Fibre Channel SAN / iSCSI) | Medio (4 - 16 nodos) | Sobrecarga por contención de bloqueos; deadlocks de DLM durante la partición de red |
| **Shared-Nothing (Stateless)** | Sin estado en los nodos del clúster; DB delegada | Menor a un segundo | Almacenamiento local solo para el SO | Extremadamente alto (100+ nodos) | Falla de dependencia externa (sobrecarga de DB de backend) |

---

### 2.2 Tecnologías de balanceo de carga y High Availability

| Tecnología | Capa | Mecanismo de Heartbeat | Control de VIP | Persistencia de estado | Caso de uso ideal |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Keepalived (VRRP)** | Capa 3 / 4 | VRRP Multicast (`224.0.0.18`) o Unicast UDP | Broadcasts ARP gratuitous del kernel | Ninguna (failover stateless) | Failover simple de Floating IP para routers de ingress y pares de proxies |
| **Pacemaker / Corosync** | Capa 3 - 7 | Totem Single Ring Protocol (UDP Unicast/Multicast) | Agentes de recursos OCF (`IPaddr2`) | Máquina de estado completa (árbol XML CIB) | Orquestación multirrecurso (IP + FS + Base de datos + STONITH) |
| **HAProxy** | Capa 4 / 7 | Health checking (polling HTTP, TCP, SMTP, MySQL) | Externo (requiere Keepalived/Pacemaker para VIP) | Stick tables, sesiones SSL, seguimiento de conexiones | Enrutamiento de tráfico L4/L7, terminación TLS, reescritura de encabezados HTTP |
| **Linux Virtual Server (IPVS)** | Capa 4 | Externo (gestionado vía Keepalived o `ldirectord`) | Tabla netfilter IPVS del kernel | Daemon de sincronización de conexiones (`ipvsadm --start-daemon`) | Enrutamiento de paquetes en espacio de kernel de alto rendimiento (LVS-DR / LVS-NAT) |

---

### 2.3 Mecanismos de fencing: IPMI vs. SBD vs. Fencing por red

| Método de fencing | Ruta de transporte | Requerimiento de hardware | Dependencia | Riesgo de falso fencing | Impacto en RTO |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Hardware OOB (IPMI / iLO)** | LAN de gestión dedicada | Controlador BMC / IPMI en el host | Infraestructura de red fuera de banda (out-of-band) | Bajo | Moderado (~15s - 45s ciclo de energía) |
| **Storage-Based Death (SBD)** | LUN SAN compartida + Dispositivo Watchdog | Hardware Watchdog (`/dev/watchdog`) | Almacenamiento de bloques compartido | Extremadamente bajo | Rápido (Timeout de watchdog, p. ej., reinicio en 10s) |
| **Managed PDU Fencing** | Ethernet a PDU inteligente | Unidad de Distribución de Energía (PDU) administrable por red | Capacidad de respuesta y mapeo de la PDU | Bajo | Moderado (~30s) |
| **Network Switch Fencing (SNMP)** | IP de gestión al Switch | Switch de red L2/L3 administrado | Capacidad de respuesta de la API del switch / SNMP | Alto (deja el nodo encendido) | Rápido (Cierre inmediato de interfaz) |

---

## 3. Manifiestos de configuración de producción

Las siguientes configuraciones establecen un clúster HA de 2 nodos (`node1`: `192.168.10.11`, `node2`: `192.168.10.12`) ejecutando Keepalived, HAProxy, Corosync y Pacemaker.

```
                      +----------------------------------+
                      |       Virtual IP (VIP)           |
                      |         192.168.10.100           |
                      +----------------+-----------------+
                                       |
                     +-----------------+-----------------+
                     |                                   |
                     v                                   v
         +-----------------------+           +-----------------------+
         |        NODE 1         |           |        NODE 2         |
         |     192.168.10.11     |           |     192.168.10.12     |
         |-----------------------|           |-----------------------|
         | Corosync / Pacemaker  | <=======> | Corosync / Pacemaker  |
         | Keepalived (Master)   |  UDP 5405 | Keepalived (Backup)   |
         | HAProxy (Active)      |  VRRP 112 | HAProxy (Active)      |
         +-----------------------+           +-----------------------+
```

---

### 3.1 `/etc/corosync/corosync.conf`
Configuración de Corosync de nivel de producción utilizando Totem Single Ring Protocol sobre Unicast (`udpu`) con autenticación criptográfica y votequorum.

```ini
totem {
    version: 2
    cluster_name: production_ha_cluster
    crypto_cipher: aes256
    crypto_hash: sha256
    transport: udpu
    token: 10000
    token_retransmits_before_loss_const: 10
    join: 60
    consensus: 12000
    max_messages: 20
    miss_count_const: 5
    interface {
        ringnumber: 0
        bindnetaddr: 192.168.10.0
        mcastport: 5405
        ttl: 1
    }
}

logging {
    to_logfile: yes
    logfile: /var/log/cluster/corosync.log
    to_syslog: yes
    syslog_facility: daemon
    debug: off
    logger_subsys {
        subsys: QUORUM
        debug: off
    }
}

quorum {
    provider: corosync_votequorum
    two_node: 1
    expected_votes: 2
    wait_for_all: 1
    last_man_standing: 1
    last_man_standing_window: 10000
}

nodelist {
    node {
        ring0_addr: 192.168.10.11
        nodeid: 1
        name: node1
    }
    node {
        ring0_addr: 192.168.10.12
        nodeid: 2
        name: node2
    }
}
```

---

### 3.2 `/etc/keepalived/keepalived.conf`
Configuración de Keepalived para producción para la gestión de IP flotante en `node1` (Master).

```haproxy
global_defs {
    router_id node1_vrrp
    enable_script_security
    script_user root
    max_auto_priority
}

vrrp_script check_haproxy {
    script "/usr/bin/killall -0 haproxy"
    interval 2
    weight 2
    fall 2
    rise 2
}

vrrp_instance VI_1 {
    state MASTER
    interface eth0
    virtual_router_id 112
    priority 101
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass K33pAliv3Sec2026
    }
    unicast_src_ip 192.168.10.11
    unicast_peer {
        192.168.10.12
    }
    virtual_ipaddress {
        192.168.10.100/24 dev eth0 label eth0:vip
    }
    track_script {
        check_haproxy
    }
    notify_master "/etc/keepalived/scripts/notify.sh MASTER"
    notify_backup "/etc/keepalived/scripts/notify.sh BACKUP"
    notify_fault  "/etc/keepalived/scripts/notify.sh FAULT"
}
```

---

### 3.3 `/etc/haproxy/haproxy.cfg`
Configuración de HAProxy de alto rendimiento en Capa 4 y Capa 7 con administración de socket, health checks y stick tables.

```haproxy
global
    log /dev/log local0 info
    log /dev/log local1 notice
    chroot /var/lib/haproxy
    stats socket /run/haproxy/admin.sock mode 660 level admin expose-fd listeners
    stats timeout 30s
    user haproxy
    group haproxy
    daemon
    maxconn 50000
    ssl-default-bind-ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256
    ssl-default-bind-options ssl-min-ver TLSv1.2 no-tls-tickets

defaults
    log global
    mode http
    option httplog
    option dontlognull
    option redispatch
    retries 3
    timeout queue 1m
    timeout connect 5s
    timeout client 50s
    timeout server 50s
    timeout http-request 10s
    maxconn 40000

frontend stats
    mode http
    bind 192.168.10.11:8404
    stats enable
    stats uri /
    stats refresh 5s
    stats admin if TRUE

frontend http_in
    bind 192.168.10.100:80
    mode http
    option forwardfor
    http-request set-header X-Forwarded-Proto http
    default_backend web_app_servers

backend web_app_servers
    mode http
    balance leastconn
    cookie SERVERID insert indirect nocache
    option httpchk GET /health HTTP/1.1\r\nHost:\ localhost
    http-check expect status 200
    server app1 192.168.10.21:8080 check inter 2000 fall 3 rise 2 cookie app1
    server app2 192.168.10.22:8080 check inter 2000 fall 3 rise 2 cookie app2
```

---

### 3.4 Script de aprovisionamiento de producción de CIB de Pacemaker
Secuencia de comandos utilizando `pcs` para construir la configuración del clúster, configurar el fencing STONITH vía IPMI, aplicar restricciones de recursos y gestionar los servicios del clúster.

```bash
#!/usr/bin/env bash
set -euo pipefail

# 1. Disable STONITH temporarily during initial provisioning
pcs property set stonith-enabled=false

# 2. Configure Quorum Policy and Failback Defaults
pcs property set no-quorum-policy=stop
pcs property set default-resource-stickiness=100

# 3. Create Virtual IP Resource (OCF Resource Agent)
pcs resource create Cluster_VIP ocf:heartbeat:IPaddr2 \
    ip=192.168.10.100 \
    cidr_netmask=24 \
    nic=eth0 \
    op monitor interval=10s timeout=20s

# 4. Create Systemd Service Resource for HAProxy
pcs resource create HAProxy_Service systemd:haproxy \
    op monitor interval=15s timeout=20s

# 5. Define Colocation Constraint (Run HAProxy on the same node as VIP)
pcs constraint colocation add HAProxy_Service with Cluster_VIP INFINITY

# 6. Define Order Constraint (Start VIP before HAProxy)
pcs constraint order start Cluster_VIP then start HAProxy_Service

# 7. Add Hardware IPMI STONITH Devices for Node Fencing
pcs stonith create fence_node1 fence_ipmilan \
    pcmk_host_list="node1" \
    ipaddr="192.168.10.211" \
    login="admin" \
    passwd="SecureIpmiPassword123!" \
    lanplus=1 \
    action=reboot \
    op monitor interval=60s

pcs stonith create fence_node2 fence_ipmilan \
    pcmk_host_list="node2" \
    ipaddr="192.168.10.212" \
    login="admin" \
    passwd="SecureIpmiPassword123!" \
    lanplus=1 \
    action=reboot \
    op monitor interval=60s

# 8. Re-enable STONITH for Production Readiness
pcs property set stonith-enabled=true
```

---

## 4. Comandos reales de CLI y salidas reales de terminal

### 4.1 Inspección del estado del anillo y Quorum de Corosync

```console
$ sudo corosync-cfgtool -s
Plotting ring status...
Ring ID 0
	id	= 192.168.10.11
	status	= ring 0 active with no faults
```

```console
$ sudo corosync-quorumtool -s
Quorum information
------------------
Date:            Thu Aug  6 17:12:20 2026
Quorum provider: corosync_votequorum
Nodes:           2
Node ID:         1
Ring ID:         0/12
Quorate:         Yes

Votequorum information
----------------------
Expected votes:   2
Highest expected: 2
Total votes:      2
Quorum:           2
Flags:            2Node Quorate LMS 

Node information
----------------
Nodeid  Votes Name
     1      1 node1 (local)
     2      1 node2
```

---

### 4.2 Estado completo del clúster de Pacemaker (`pcs status --full`)

```console
$ sudo pcs status --full
Cluster name: production_ha_cluster
Cluster Summary:
  * Stack: corosync
  * Current DC: node1 (version 2.1.5-1.el9-a3f895f) - partition with quorum
  * Last updated: Thu Aug  6 17:12:25 2026
  * Last change:  Thu Aug  6 16:45:10 2026 by root via cibadmin on node1
  * 2 nodes configured
  * 4 resource instances configured

Node List:
  * Online: [ node1 (1) node2 (2) ]

Full List of Resources:
  * Resource Group: HA_Group:
    * Cluster_VIP	(ocf::heartbeat:IPaddr2):	Started node1
    * HAProxy_Service	(systemd:haproxy):	Started node1
  * STONITH Devices:
    * fence_node1	(stonith:fence_ipmilan):	Started node2
    * fence_node2	(stonith:fence_ipmilan):	Started node1

PCS DPD Daemon Status:
  pcsd: active/enabled on all nodes

Daemon Status:
  corosync: active/enabled
  pacemaker: active/enabled
  pcsd: active/enabled
```

---

### 4.3 Diagnósticos de tiempo de ejecución del socket de HAProxy

```console
$ echo "show info" | sudo socat stdio /run/haproxy/admin.sock
Name: HAProxy
Version: 2.8.3-2
Release_date: 2023/09/08
Nbthread: 4
Nbproc: 1
Process_num: 1
Pid: 14205
Uptime: 2d 04h12m18s
Uptime_sec: 187938
Limitconn: 50000
Maxconn: 50000
CurrConns: 142
CumConns: 891042
Tasks: 158
Run_queue: 1
Node: node1
Stopping: 0
Jobs: 144
UnstoppableJobs: 0
ConnRate: 45
MaxConnRate: 1250
SessRate: 45
MaxSessRate: 1250
```

```console
$ echo "show stat" | sudo socat stdio /run/haproxy/admin.sock | cut -d',' -f1,2,5,18,37,40
# pxname,svname,scur,state,status,check_status
stats,FRONTEND,1,OPEN,OPEN,
stats,BACKEND,0,OPEN,UP,
http_in,FRONTEND,141,OPEN,OPEN,
web_app_servers,app1,68,UP,UP,L7OK
web_app_servers,app2,73,UP,UP,L7OK
web_app_servers,BACKEND,141,UP,UP,
```

---

### 4.4 Estado en tiempo de ejecución de Keepalived y verificación de alias de IP

```console
$ ip addr show dev eth0
2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc mq state UP group default qlen 1000
    inet 192.168.10.11/24 brd 192.168.10.255 scope global eth0
       valid_lft forever preferred_lft forever
    inet 192.168.10.100/24 scope global secondary eth0:vip
       valid_lft forever preferred_lft forever
    inet6 fe80::5054:ff:fe12:3456/64 scope link 
       valid_lft forever preferred_lft forever
```

```console
$ sudo systemctl status keepalived.service
● keepalived.service - LVS and VRRP High Availability Monitor
     Loaded: loaded (/usr/lib/systemd/system/keepalived.service; enabled; preset: disabled)
     Active: active (running) since Tue 2026-08-04 12:00:00 UTC; 2 days ago
   Main PID: 8912 (keepalived)
      Tasks: 2 (limit: 48800)
     Memory: 6.4M
        CPU: 12.410s
     CGroup: /system.slice/keepalived.service
             ├─8912 /usr/sbin/keepalived --dont-fork -D
             └─8913 /usr/sbin/keepalived --dont-fork -D

Aug 06 14:10:02 node1 Keepalived_vrrp[8913]: (VI_1) Entering MASTER STATE
Aug 06 14:10:03 node1 Keepalived_vrrp[8913]: (VI_1) setting VIPs.
Aug 06 14:10:03 node1 Keepalived_vrrp[8913]: (VI_1) Sending gratuitous ARP on eth0 for 192.168.10.100
Aug 06 14:10:03 node1 Keepalived_vrrp[8913]: (VI_1) Registering gratuitous ARP shared address 192.168.10.100
```

---

## 5. Guía de verificación y resolución de fallas (Troubleshooting)

### 5.1 Árbol de flujo de trabajo de diagnóstico sistémico

```
                       +-----------------------------------+
                       |      High Availability Incident    |
                       +-----------------+-----------------+
                                         |
                                         v
                     +---------------------------------------+
                     |  Is VIP (192.168.10.100) reachable?   |
                     +-------------------+-------------------+
                                         |
                       +-----------------+-----------------+
                       |                                   |
                    [ NO ]                              [ YES ]
                       |                                   |
                       v                                   v
+---------------------------------------------+ +------------------------------------+
| Check Layer 2 / VRRP                        | | Check Application Layer          |
| 1. tcpdump -i eth0 vrrp                     | | 1. curl http://192.168.10.100/   |
| 2. Check for Master collisions (Dual Master)| | 2. Inspect HAProxy Socket stats  |
| 3. Check firewall (IP Protocol 112 drop)    | | 3. Verify backend service health |
+---------------------------------------------+ +------------------------------------+
                       |
                       v
                     +---------------------------------------+
                     | Is Pacemaker/Corosync Quorate?        |
                     +-------------------+-------------------+
                                         |
                       +-----------------+-----------------+
                       |                                   |
                    [ NO ]                              [ YES ]
                       |                                   |
                       v                                   v
+---------------------------------------------+ +------------------------------------+
| Quorum & Network Partitioning Debug         | | Resource Failure / STONITH Debug   |
| 1. corosync-cfgtool -s                      | | 1. pcs status                    |
| 2. Verify UDP 5405 traffic via tcpdump      | | 2. pcs resource failcount show   |
| 3. Check /var/log/cluster/corosync.log      | | 3. Test IPMI fencing agent manually|
+---------------------------------------------+ +------------------------------------+
```

---

### 5.2 Escenarios profundos de resolución de problemas (Troubleshooting) y comandos de resolución

#### Escenario A: Condición de Dual Master (Split-Brain VRRP de Keepalived)
*   **Síntoma**: Tanto `node1` como `node2` asignan `192.168.10.100` a `eth0`, causando pérdida de paquetes y conflictos de direcciones IP.
*   **Causa raíz**: El firewall (`iptables` / `nftables`) está bloqueando el protocolo multicast VRRP 112 (`224.0.0.18`) o los paquetes unicast UDP entre nodos.
*   **Diagnóstico**:
    ```bash
    # Execute packet capture on node2 to see if VRRP advertisements arrive from node1
    $ sudo tcpdump -nn -i eth0 proto 112
    ```
*   **Remediación**:
    ```bash
    # Open VRRP traffic in firewalld on both nodes
    $ sudo firewall-cmd --add-protocol=vrrp --permanent
    $ sudo firewall-cmd --reload
    ```

---

#### Escenario B: Falla en el anillo de Corosync / Comunicación perdida
*   **Síntoma**: `corosync-cfgtool -s` muestra `status = FAULTY`.
*   **Causa raíz**: Parpadeo (flap) de la interfaz de red, dirección de enlace (bind address) de red mal configurada o firewall bloqueando el puerto UDP 5405.
*   **Diagnóstico**:
    ```bash
    # Check corosync systemd journal logs
    $ sudo journalctl -u corosync.service -n 50 --no-pager
    
    # Trace UDP cluster communication port
    $ sudo tcpdump -nn -i eth0 port 5405
    ```
*   **Remediación**:
    ```bash
    # Re-evaluate and reset ring interface state without restarting corosync
    $ sudo corosync-cfgtool -r
    ```

---

#### Escenario C: El recurso no logra iniciar (Atascado en estado fallido)
*   **Síntoma**: `pcs status` reporta `Failed Resource Actions: HAProxy_Service_start_0 on node1 'unknown error'`.
*   **Diagnóstico**:
    ```bash
    # Inspect detailed error logs for the specific resource
    $ sudo pcs resource debug-start HAProxy_Service
    ```
*   **Remediación**:
    ```bash
    # Fix the underlying issue (e.g., syntax error in /etc/haproxy/haproxy.cfg), then clear fail counts:
    $ sudo pcs resource cleanup HAProxy_Service
    ```

---

#### Escenario D: Bucle de fencing de STONITH / Falla de ejecución
*   **Síntoma**: El nodo se reinicia constantemente, o el DC reporta `Fence action failed`.
*   **Diagnóstico**:
    ```bash
    # Manually test fence agent connectivity to out-of-band IPMI interface
    $ fence_ipmilan -a 192.168.10.211 -l admin -p "SecureIpmiPassword123!" -L lanplus -o status
    ```
*   **Remediación**:
    Si un nodo está atascado en un bucle de fencing durante el mantenimiento, desadministre (unman) temporalmente el nodo o anule STONITH:
    ```bash
    # Put node into maintenance mode to suppress fence actions
    $ sudo pcs node maintenance node2
    
    # Unmanage specific failing resource during active recovery
    $ sudo pcs resource unmanage HAProxy_Service
    ```

---

### 5.3 Referencia rápida de comandos de recuperación de emergencia del clúster

```bash
# Force temporary quorum emergency override on a single surviving node
$ sudo corosync-quorumtool -e 1

# Export full raw Cluster Information Base (CIB) XML configuration
$ sudo cibadmin --query > /tmp/cib_backup.xml

# Force replacement of active CIB configuration from file
$ sudo cibadmin --replace --xml-file /tmp/cib_backup.xml

# Complete cluster-wide service shutdown across all nodes
$ sudo pcs cluster stop --all

# Complete cluster-wide service startup across all nodes
$ sudo pcs cluster start --all
```

---

## 6. Referencias

*   **Linux Professional Institute (LPI) Official LPIC-3 306 Objectives**:  
    [https://www.lpi.org/our-certifications/lpic-3-306-overview/](https://www.lpi.org/our-certifications/lpic-3-306-overview/)
*   **Clusterlabs Pacemaker Documentation**:  
    [https://clusterlabs.org/pacemaker/doc/](https://clusterlabs.org/pacemaker/doc/)
*   **Corosync Official Documentation**:  
    [https://corosync.github.io/corosync/](https://corosync.github.io/corosync/)
*   **Keepalived Official Documentation**:  
    [https://www.keepalived.org/documentation.html](https://www.keepalived.org/documentation.html)
*   **HAProxy Enterprise & Community Documentation**:  
    [https://www.haproxy.org/#docs](https://www.haproxy.org/#docs)
*   **Linux Virtual Server (IPVS) Project**:  
    [http://www.linuxvirtualserver.org/software/ipvs.html](http://www.linuxvirtualserver.org/software/ipvs.html)