# Alta disponibilidad de red

**LPIC-3 306 — Examen 306-300 (v3.0) · Tema 364.4 · Peso del examen ≈ 8.33**

---

## 1. El problema arquitectónico: la red es una pila de puntos únicos de fallo

Un servidor puede tener triple redundancia en alimentación, disco (RAID) y CPU, formar parte de un clúster de failover con Pacemaker y aun así estar *offline* porque se desenchufó el único cable que alimenta su switch de acceso, o porque se reinició el default gateway al que apunta. La alta disponibilidad nunca es más fuerte que el **salto menos redundante del camino**, y el camino de red es donde en realidad viven la mayoría de los saltos no redundantes.

El error que los equipos de producción repiten es acotar la HA al *nodo* ("tenemos dos servidores de aplicación") mientras dejan singular el *camino* hacia ese nodo. La disponibilidad es multiplicativa a lo largo de un camino en serie: dos nodos al 99,9 % detrás de un único gateway al 99,9 % y un único switch dan `0.999³ ≈ 99.7 %` — el cómputo redundante no compró nada porque el dominio de fallo nunca fue el cómputo.

Mapeá cada salto y su modo de fallo antes de elegir una herramienta:

| Capa | Componente | Modo de fallo | Radio de impacto | Técnica de redundancia |
|---|---|---|---|---|
| L1 | Cable / SFP / puerto NIC | Corte, mal asentado, muerte del láser | El uplink de un host | **Link aggregation** (bonding/teaming) sobre ≥2 NICs |
| L2 | Switch de acceso / ToR | Reinicio, PSU, bug de firmware | Todos los hosts de ese switch | Bonds con doble conexión a **dos** switches (MLAG/vPC) |
| L2→L3 | Default gateway | Reinicio del router, push de configuración | Todos los hosts de la subred | Router virtual **VRRP** (keepalived) |
| L3 | Camino ascendente / tránsito | Flap de enlace, retirada de BGP | Un prefijo entero | **ECMP + enrutamiento dinámico** (OSPF/BGP) |
| L3 | IP de front-end del servicio | Nodo LB caído | El servicio | **Anycast** (/32 anunciado desde N nodos) |
| L4/L7 | Load balancer | Crash del proceso, kernel panic | Todas las conexiones que pasan por él | **Par de LB** + VRRP/conntrackd (ver 361.1) |
| — | *Estado* de conexión | El failover reinicia cada flujo TCP | Cada sesión activa | Replicación de estado con **conntrackd** |

La lección recurrente: la redundancia en la capa *N* no vale nada si la capa *N−1* que tiene debajo es única. Esta unidad construye la pila de abajo hacia arriba —enlace, gateway, camino, estado— porque ése es el orden en que se propaga un fallo y el orden en que hay que auditarlo.

Dos ejes de diseño ortogonales gobiernan cada decisión que sigue:

- **Latencia de detección de fallos frente a falsos positivos.** El failover sub-segundo (`advert_int` agresivo, `lacp_rate fast`, BFD) detecta rápido los fallos reales pero convierte cada parpadeo transitorio en un flap. Los temporizadores lentos son estables pero exponen a los usuarios a segundos de blackhole.
- **Redundancia L2 frente a redundancia L3.** L2 (VRRP, bonding) es transparente para los clientes y no requiere cambios de enrutamiento, pero está confinada a un único dominio de broadcast y depende del ARP gratuito / comportamiento de la tabla CAM del switch. L3 (ECMP, anycast, BGP) escala a través de subredes y datacenters y hace failover por *convergencia de enrutamiento*, pero requiere routers cooperantes y un manejo correcto del reverse-path.

---

## 2. Redundancia en la capa de enlace: bonding y teaming

### 2.1 Qué hace realmente el driver de bonding del kernel

El driver `bonding` presenta `bondN` como una única interfaz lógica sobre ≥2 esclavos físicos. Su comportamiento está determinado por completo por el **mode** y por el **link monitor** (cómo decide que un esclavo está muerto).

| Mode | Nombre | Requiere config del switch | Balancea TX | Tolerancia a fallos | Uso típico |
|---|---|---|---|---|---|
| 0 | `balance-rr` | LAG (estático) | Sí (por paquete) | Sí | Rara vez — el reordenamiento de paquetes perjudica a TCP |
| 1 | `active-backup` | **No** | No | Sí | Resiliencia con doble switch, cero cooperación del switch |
| 2 | `balance-xor` | LAG (estático) | Sí (hash) | Sí | Agregación estática |
| 3 | `broadcast` | — | No (duplica) | Sí | Nicho de pérdida ultrabaja |
| 4 | `802.3ad` (LACP) | **LAG + LACP** | Sí (hash) | Sí | Agregación estándar de datacenter |
| 5 | `balance-tlb` | No | Sí (solo TX) | Sí | Balanceo de salida agnóstico al switch |
| 6 | `balance-alb` | No | Sí (TX+RX) | Sí | Balanceo completo agnóstico al switch (trucos de ARP) |

**Dos decisiones dominan:**

1. **¿Necesitás cooperación del switch?** `active-backup` (mode 1) es el único modo que sobrevive a un fallo de *switch* sin configuración del lado del switch — enchufá los dos esclavos en dos switches independientes y el bond hace failover de forma transparente. `802.3ad` (mode 4) te da ancho de banda agregado *y* redundancia pero requiere ambos esclavos en el **mismo** switch con capacidad LACP (o un par MLAG/vPC que se presente como un único peer LACP lógico).

2. **¿Cómo se hashea el tráfico TX entre los esclavos?** `xmit_hash_policy` decide qué flujo sale por qué esclavo. `layer2` (solo MACs) colapsa a un único esclavo cuando todos hablan a través de una única MAC de router; `layer3+4` (IP + puerto) reparte bien los flujos pero no cumple estrictamente 802.3ad (un flujo fragmentado puede reordenarse). Para un servidor detrás de un único gateway, usá `layer3+4`.

**El link monitoring** es lo que hace que un bond sea *de alta disponibilidad* en lugar de meramente agregado:

- `miimon=100` — sondea la portadora del driver cada 100 ms. Rápido, pero solo detecta la pérdida de portadora *local*; un switch muerto que mantiene la luz encendida es invisible.
- `arp_interval` + `arp_ip_target` — hace ARP activamente a una IP conocida; detecta la alcanzabilidad end-to-end, no solo la portadora. **No** combines el monitoreo por ARP con 802.3ad.
- `downdelay` / `updelay` — filtran (debounce) los enlaces que hacen flap (esperan N ms de estado estable antes de actuar).

### 2.2 Bonding — configuración completa (NetworkManager / RHEL 9)

```bash
$ sudo nmcli connection add type bond con-name bond0 ifname bond0 \
    ipv4.method manual ipv4.addresses 192.168.10.20/24 ipv4.gateway 192.168.10.1 \
    bond.options "mode=802.3ad,miimon=100,lacp_rate=fast,xmit_hash_policy=layer3+4,updelay=200,downdelay=200"
Connection 'bond0' (7c3e...) successfully added.

$ sudo nmcli connection add type ethernet con-name bond0-p1 ifname enp1s0 master bond0
$ sudo nmcli connection add type ethernet con-name bond0-p2 ifname enp2s0 master bond0

$ sudo nmcli connection up bond0
Connection successfully activated (master waiting for slaves)
```

Verificá que la agregación realmente se negoció (la verificación más importante de todas — un bond puede quedar "up" con LACP *sin* formarse y correr silenciosamente sobre un único enlace):

```bash
$ cat /proc/net/bonding/bond0
Ethernet Channel Bonding Driver: v6.9.9

Bonding Mode: IEEE 802.3ad Dynamic link aggregation
Transmit Hash Policy: layer3+4 (1)
MII Status: up
MII Polling Interval (ms): 100
Up Delay (ms): 200
Down Delay (ms): 200

802.3ad info
LACP active: on
LACP rate: fast
Min links: 0
Aggregator selection policy (ad_select): stable
System priority: 65535
System MAC address: 52:54:00:aa:bb:cc
Active Aggregator Info:
        Aggregator ID: 1
        Number of ports: 2
        Actor Key: 15
        Partner Key: 32773
        Partner Mac Address: 00:23:04:ee:be:cf     <-- real switch MAC = LACP formed

Slave Interface: enp1s0
MII Status: up
Speed: 10000 Mbps
Duplex: full
Aggregator ID: 1
Partner Churn State: none       <-- "monitoring" here = LACP not converging
Actor Churned Count: 0

Slave Interface: enp2s0
MII Status: up
Speed: 10000 Mbps
Duplex: full
Aggregator ID: 1                <-- both slaves share Aggregator ID = one LAG. Good.
```

Reglas prácticas de diagnóstico: **Partner MAC = `00:00:00:00:00:00`** o **Churn State ≠ `none`** significa que el lado del switch no está corriendo LACP (sin port-channel, o desajuste `passive`/`on`). Dos **Aggregator IDs distintos** significa que los dos esclavos cayeron en dos switches que *no* son un par MLAG — LACP no puede abarcarlos, así que obtenés dos medios-bonds en lugar de uno.

### 2.3 Bonding con `systemd-networkd` (imágenes inmutables / mínimas)

```ini
# /etc/systemd/network/10-bond0.netdev
[NetDev]
Name=bond0
Kind=bond

[Bond]
Mode=802.3ad
TransmitHashPolicy=layer3+4
LACPTransmitRate=fast
MIIMonitorSec=100ms
UpDelaySec=200ms
DownDelaySec=200ms
```

```ini
# /etc/systemd/network/11-bond0-members.network
[Match]
Name=enp1s0 enp2s0

[Network]
Bond=bond0
```

```ini
# /etc/systemd/network/12-bond0.network
[Match]
Name=bond0

[Network]
Address=192.168.10.20/24
Gateway=192.168.10.1
```

```bash
$ sudo networkctl reload
$ networkctl status bond0
● 5: bond0
       State: routable (configured)
        Type: bond
    Hardware: 802.3ad
     Address: 192.168.10.20
     Gateway: 192.168.10.1 (Cisco Systems)
```

### 2.4 Teaming (libteam / `teamd`) — y por qué es la apuesta perdedora

El *teaming* de red implementa la misma idea en el espacio de usuario (`teamd`) con una configuración JSON y "runners" enchufables:

```json
// /etc/systemd/network is not used; via NM keyfile team.config or teamd -f
{
  "device": "team0",
  "runner": { "name": "lacp", "active": true, "fast_rate": true,
              "tx_hash": ["eth", "ipv4", "ipv6"] },
  "link_watch": { "name": "ethtool" },
  "ports": { "enp1s0": {}, "enp2s0": {} }
}
```

```bash
$ sudo teamd -g -f /etc/teamd/team0.conf -d
$ sudo teamdctl team0 state
setup:
  runner: lacp
ports:
  enp1s0
    link watches:
      link summary: up
    runner:
      aggregator ID: 5, Selected
      selected: yes
      state: current
  enp2s0
    link watches:
      link summary: up
    runner:
      aggregator ID: 5, Selected
```

| | Bonding (driver `bonding`) | Teaming (`libteam`/`teamd`) |
|---|---|---|
| Ubicación | En el kernel | Daemon en espacio de usuario + pequeño módulo de kernel |
| Configuración | sysfs / `bond.options` / netlink | JSON, API en runtime `teamdctl` |
| Runners/modes | 7 modos fijos | Runners enchufables (broadcast, roundrobin, activebackup, loadbalance, lacp) |
| Ajuste de LACP | Parámetros del kernel | JSON, introspección en runtime más rica |
| **Dirección del proveedor** | **Preferido / mantenido activamente** | **Obsoleto en RHEL 9+** |

Para el examen y para producción, **usá bonding por defecto.** La API en runtime más limpia de teaming nunca superó el hecho de que bonding está en el kernel, tiene soporte universal y es el camino al que Red Hat ahora reconduce a todo el mundo. Sabé que teaming existe y cómo leer `teamdctl`, pero no construyas infraestructura nueva sobre él.

---

## 3. Redundancia de gateway: VRRP con keepalived

### 3.1 Mecánica de VRRP sobre la que debés poder razonar

El **Virtual Router Redundancy Protocol** (RFC 3768 = v2, **RFC 5798** = v3 con IPv6) permite que N routers compartan una única **IP virtual (VIP)** y una única **MAC virtual** (`00:00:5e:00:01:{VRID}`). Los clientes apuntan su ruta por defecto a la VIP y nunca saben qué caja física la posee.

- **La elección** es por **prioridad** (0–255). `255` está reservado para el *dueño de la dirección* (un router cuya IP real de interfaz es igual a la VIP). `100` es el valor por defecto de keepalived. Gana la prioridad más alta; los empates se rompen por la IP primaria más alta. La prioridad `0` es un anuncio especial de "renuncio" que dispara un failover *inmediato*.
- El **MASTER** hace multicast de anuncios VRRP a `224.0.0.18` (IPv4) / `ff02::12` (IPv6), **protocolo IP 112**, cada `advert_int` (por defecto 1 s).
- Un BACKUP declara muerto al master tras **Master_Down_Interval = 3 × advert_int + skew**, donde `skew = (256 − priority)/256`. Menor prioridad → mayor skew → toma de control determinista y escalonada sin thundering herd.
- Al ser promovido, el nuevo master **hace broadcast de ARP gratuito** para la VIP de modo que las tablas CAM del switch y las cachés ARP de los clientes reaprendan el puerto/MAC. *Si esos GARP se descartan, la VIP se mueve pero el tráfico sigue yendo a la caja muerta* — ésta es la causa #1 de "el failover ocurrió pero nada se recuperó."
- **`preempt` vs `nopreempt`:** por defecto un nodo de mayor prioridad que regresa *recupera* el rol de master (una caída extra). `nopreempt` mantiene al master actual hasta que realmente falla — normalmente lo que querés, para evitar que un primario que hace flap haga rebotar la VIP.
- **El VRID (`virtual_router_id`)** debe coincidir entre los peers y ser **único por segmento L2** (dos clústeres con el mismo VRID en una VLAN corrompen mutuamente sus MACs virtuales).
- **La autenticación** (`auth_type PASS`) existe **solo en VRRPv2**; RFC 5798 la eliminó. Si configurás `vrrp_version 3` *y* un bloque `authentication`, keepalived avisa y lo ignora — no confíes en ello como control de seguridad (nunca lo fue; a lo sumo es una protección contra configuraciones erróneas accidentales).

### 3.2 keepalived — configuración completa MASTER/BACKUP

Ambos nodos corren keepalived; la configuración es simétrica salvo por `state`, `priority` y (para unicast) las direcciones de los peers.

```conf
# /etc/keepalived/keepalived.conf  —  NODE lb01 (MASTER)
global_defs {
    router_id lb01
    vrrp_version 3
    enable_script_security          # refuse to run tracking scripts as root if writable by others
    script_user keepalived_script
    vrrp_garp_master_delay 1        # (re)send GARP 1s after taking master, to fight lossy switches
    vrrp_garp_master_refresh 60     # periodic GARP refresh so CAM tables never age out the VIP
}

# Health check: is HAProxy actually alive? If not, shed priority so the peer wins.
vrrp_script chk_haproxy {
    script "/usr/bin/killall -0 haproxy"   # signal 0 = "does the process exist?"
    interval 2                              # run every 2s
    timeout 3
    fall 2                                  # 2 consecutive failures => DOWN
    rise 2                                  # 2 consecutive successes => UP
    weight -40                              # subtract 40 from priority while DOWN
}

vrrp_instance VI_PUBLIC {
    state MASTER
    interface enp3s0
    virtual_router_id 51
    priority 150
    advert_int 1
    nopreempt                               # don't steal mastership back on recovery

    # Cloud / firewalled fabrics block multicast — use unicast VRRP:
    unicast_src_ip 10.0.0.11
    unicast_peer {
        10.0.0.12
    }

    authentication {                        # ignored under vrrp_version 3; kept for v2 fallback
        auth_type PASS
        auth_pass s3cr3t42
    }

    virtual_ipaddress {
        203.0.113.10/24 dev enp3s0
    }
    virtual_routes {
        default via 203.0.113.1 dev enp3s0
    }

    track_script {
        chk_haproxy
    }

    # Effective priority = 150 - 40 = 110 while HAProxy is down; peer at 120 then wins.
    notify_master "/etc/keepalived/notify.sh MASTER"
    notify_backup "/etc/keepalived/notify.sh BACKUP"
    notify_fault  "/etc/keepalived/notify.sh FAULT"
}
```

El nodo BACKUP es idéntico salvo por:

```conf
    state BACKUP
    priority 120
    unicast_src_ip 10.0.0.12
    unicast_peer { 10.0.0.11 }
```

> **Nota de diseño sobre `weight`:** la matemática debe garantizar el ganador *correcto*. El master arranca en 150; un fallo de HAProxy lo baja a 110, que está por debajo del 120 del backup → failover limpio. Si hubieras puesto `weight -20`, el master bajaría solo a 130 (aún > 120) y la VIP se quedaría en la caja cuyo servicio está muerto. Verificá siempre: `master_priority + weight < backup_priority`.

Agrupar instancias para que una VIP pública y una VIP privada hagan failover **juntas** (nunca a medias):

```conf
vrrp_sync_group PUBLIC_PRIVATE {
    group {
        VI_PUBLIC
        VI_PRIVATE
    }
    notify_master "/etc/keepalived/promote.sh"
}
```

### 3.3 El script de notify — donde el failover se vuelve una *acción*, no solo un movimiento de IP

```bash
#!/bin/bash
# /etc/keepalived/notify.sh  — owned by keepalived_script, mode 0750
STATE="$1"
logger -t keepalived-notify "transition to ${STATE}"

case "$STATE" in
  MASTER)
    # Take over the connection-tracking state so established TCP flows survive:
    /usr/sbin/conntrackd -c        # commit external cache into the kernel table
    /usr/sbin/conntrackd -f        # flush internal & external caches
    /usr/sbin/conntrackd -R        # resync internal cache with the kernel
    /usr/sbin/conntrackd -B        # push a bulk update to the peer
    systemctl start haproxy
    ;;
  BACKUP|FAULT)
    /usr/sbin/conntrackd -t        # flush the kernel conntrack table (we no longer own the VIP)
    /usr/sbin/conntrackd -n        # request a resync from the new master
    ;;
esac
```

### 3.4 Failover con estado: conntrackd

Mover una VIP mueve *paquetes*, no *conexiones*. Sin replicación de estado, cada sesión TCP establecida se reinicia en el failover — catastrófico para flujos de larga duración (conexiones de base de datos, streams, sesiones NAT en un firewall). **conntrackd** replica la tabla conntrack del kernel entre el par de modo que el nuevo master ya conoce las conexiones en curso. Corre en modo **primary-backup**, impulsado por los hooks de notify de keepalived de arriba:

```conf
# /etc/conntrackd/conntrackd.conf (primary-backup, unicast)
Sync {
    Mode FTFW { }                       # fault-tolerant, reliable resync
    UDP {
        IPv4_address 10.0.0.11
        IPv4_Destination_Address 10.0.0.12
        Port 3780
        Interface enp1s0
    }
}
General {
    Systemd on
    Filter From Userspace {
        Protocol Accept { TCP UDP ICMP }
        Address Ignore { IPv4_address 127.0.0.1 }
    }
}
```

```bash
$ sudo conntrackd -s
cache internal:   14231 entries
cache external:   14180 entries
traffic processed: ...
UDP traffic (active device=enp1s0):  sent 4.1 MB  recv 4.0 MB
message tracking:  malformed 0  lost 0     <-- "lost" climbing => sync link saturated/dropping
```

### 3.5 Verificación y diagnóstico de VRRP

```bash
# Which node owns the VIP right now?
$ ip -br addr show enp3s0
enp3s0  UP  10.0.0.11/24 203.0.113.10/24     <-- VIP present = this box is MASTER

# Watch the protocol on the wire (proto 112). One MASTER should advertise; silence from the other.
$ sudo tcpdump -ni enp3s0 vrrp
14:22:01.114 IP 10.0.0.11 > 224.0.0.18: VRRPv3, Advertisement, vrid 51, prio 150, intvl 100cs
14:22:02.114 IP 10.0.0.11 > 224.0.0.18: VRRPv3, Advertisement, vrid 51, prio 150, intvl 100cs

# State transitions and the reason for them:
$ journalctl -u keepalived -f
Aug 12 14:25:07 lb01 Keepalived_vrrp[981]: (VI_PUBLIC) Entering FAULT STATE
Aug 12 14:25:07 lb01 Keepalived_vrrp[981]: VRRP_Script(chk_haproxy) failed (exited with status 1)
Aug 12 14:25:07 lb01 Keepalived_vrrp[981]: (VI_PUBLIC) Changing effective priority from 150 to 110
```

| Síntoma | Causa raíz | Confirmar | Solución |
|---|---|---|---|
| **Ambos nodos son MASTER (split-brain)** | Los anuncios no llegan al peer | `tcpdump vrrp` no muestra nada llegando | Abrir el proto 112 en el firewall; si el multicast está bloqueado (cloud), cambiar a `unicast_peer` |
| Igual que arriba | Desajuste de VRID o `auth_pass` distinto (v2) | Comparar las configs | Alinear `virtual_router_id` y la autenticación |
| **El failover ocurre pero el tráfico sigue muerto** | ARP gratuito descartado; el switch CAM/clientes mantienen la MAC vieja | `arping`/`tcpdump arp` no muestra reaprendizaje del GARP | `vrrp_garp_master_refresh`; verificar que el port security/DAI del switch no esté descartando el GARP |
| **La VIP hace flap constantemente** | `preempt` + temporizadores agresivos + un enlace marginal | MASTER↔BACKUP repetido en el journal | `nopreempt`; subir `fall`/`rise`; agregar `downdelay` en el bond subyacente |
| **Servicio muerto pero la VIP no se mueve** | `weight` demasiado pequeño: `master_prio + weight` sigue siendo > backup | Prioridad efectiva en el journal | Reajustar `weight` para que la prioridad efectiva del master caiga por debajo del backup |
| **Las conexiones establecidas se reinician en el failover** | Sin replicación de estado | `conntrackd -s` muestra la caché externa vacía | Desplegar conntrackd + cablear los hooks de notify |
| keepalived se niega a correr el script | `enable_script_security` + script escribible por todos | Log: "script ... is insecure" | `chown keepalived_script`, modo `0750` |

> **Advertencia sobre cloud:** en AWS/Azure/GCP el fabric L2 es virtual — el ARP gratuito y el multicast normalmente no funcionan. VRRP igual elige un master, pero el script *notify_master* debe llamar a la API del cloud para reasignar la IP Elastic/flotante o reescribir una entrada de la tabla de rutas que apunte el /32 a la nueva instancia. La elección es trabajo de keepalived; mover la dirección es del proveedor de cloud.

---

## 4. Redundancia de camino: enrutamiento dinámico, ECMP y anycast

VRRP es una **técnica L2** — solo funciona dentro de un dominio de broadcast y solo protege el *primer salto*. No puede sobrevivir a la pérdida de un sitio entero, no puede repartir la carga entre caminos y no puede anunciar un servicio a la red más amplia. Para eso, la HA sube al **enrutamiento L3**.

### 4.1 ECMP — muchos caminos iguales, hasheados por flujo

Equal-Cost Multi-Path instala varios next-hops para un destino; el kernel hashea cada *flujo* a uno de ellos (por flujo, de modo que una conexión TCP nunca se reordena):

```bash
$ sudo ip route add 203.0.113.0/24 \
      nexthop via 10.0.0.1 dev enp1s0 weight 1 \
      nexthop via 10.0.0.2 dev enp2s0 weight 1

$ ip route show 203.0.113.0/24
203.0.113.0/24
        nexthop via 10.0.0.1 dev enp1s0 weight 1
        nexthop via 10.0.0.2 dev enp2s0 weight 1

# Control the hash: 0 = L3 (src/dst IP), 1 = L3+L4 (adds ports), 2 = inner header for tunnels
$ sudo sysctl -w net.ipv4.fib_multipath_hash_policy=1
net.ipv4.fib_multipath_hash_policy = 1

# Show which next-hop a specific flow will actually take:
$ ip route get 203.0.113.55 from 10.0.0.20 ipproto tcp sport 34512 dport 443
203.0.113.55 from 10.0.0.20 via 10.0.0.2 dev enp2s0 ...
```

ECMP por sí solo no es HA — un next-hop muerto igual recibe su parte del hash y agujerea (blackhole) esos flujos. Necesitás algo que **retire** el camino fallido: un link monitor, un protocolo de enrutamiento dinámico o **BFD** (Bidirectional Forwarding Detection) para detección de vida del next-hop sub-segundo.

### 4.2 Anycast con FRRouting: anunciar un /32 desde muchos nodos

**Anycast** es la contraparte L3 de una VIP: cada nodo de servicio anuncia la *misma* dirección (un loopback `/32`) al fabric de enrutamiento vía BGP u OSPF. Los routers hacen ECMP hacia todos ellos; si un nodo muere, deja de anunciar y la ruta converge fuera — el failover es *convergencia de enrutamiento*, y funciona a través de subredes, racks y datacenters.

```bash
$ sudo ip address add 203.0.113.10/32 dev lo    # the anycast service address, on loopback
```

**FRRouting** (`frr`, el sucesor mantenido de Quagga) habla BGP con el router top-of-rack:

```conf
! /etc/frr/frr.conf  — anycast node #1 (AS 65001), ToR is AS 65000
frr version 8.5
frr defaults datacenter
hostname anycast-node1
log syslog informational
!
router bgp 65001
 bgp router-id 10.0.0.11
 no bgp ebgp-requires-policy
 neighbor 10.0.0.254 remote-as 65000
 neighbor 10.0.0.254 bfd                 ! sub-second failure detection via BFD
 !
 address-family ipv4 unicast
  ! Only advertise the anycast /32 when it is actually present on lo.
  ! A health script adds/removes 203.0.113.10/32 => BGP advertises/withdraws automatically.
  redistribute connected route-map ANYCAST-ONLY
 exit-address-family
!
ip prefix-list ANYCAST seq 5 permit 203.0.113.10/32
route-map ANYCAST-ONLY permit 10
 match ip address prefix-list ANYCAST
!
```

El patrón de producción crucial es el **anuncio condicionado por salud (health-gated)**: FRR no tiene un chequeo de servicio incorporado, así que combinálo con un pequeño watcher que *quite el `/32` de `lo` cuando el servicio no está sano*. `redistribute connected` entonces deja de originar la ruta y BGP la retira — el router reconverge sobre los nodos supervivientes:

```bash
#!/bin/bash
# /usr/local/bin/anycast-health.sh  (run from a systemd timer or a loop)
VIP=203.0.113.10/32
if curl -fsS --max-time 2 http://127.0.0.1:8080/healthz >/dev/null; then
    ip address show dev lo | grep -q "$VIP" || ip address add "$VIP" dev lo
else
    ip address show dev lo | grep -q "$VIP" && ip address del "$VIP" dev lo
fi
```

Verificá BGP y el comportamiento de retirada:

```bash
$ sudo vtysh -c "show bgp ipv4 unicast summary"
Neighbor        V     AS   MsgRcvd MsgSent  Up/Down  State/PfxRcd
10.0.0.254      4  65000     14201   14198  2d03h12m       417

$ sudo vtysh -c "show bgp ipv4 unicast 203.0.113.10/32"
BGP routing table entry for 203.0.113.10/32
  Local, best, valid
  10.0.0.254 from 10.0.0.254 (10.0.0.254)   <-- advertised while healthy

# Kill the service; the /32 is pulled from lo; within a BGP/BFD cycle:
$ sudo vtysh -c "show bgp ipv4 unicast 203.0.113.10/32"
% Network not in table                       <-- withdrawn; router now ECMPs to healthy nodes
```

### 4.3 La trampa del reverse-path: `rp_filter` y el enrutamiento asimétrico

El fallo que silenciosamente se come *la mitad* de un despliegue multipath es el **reverse-path filtering**. Con `net.ipv4.conf.*.rp_filter=1` (strict), el kernel descarta cualquier paquete cuyo origen no se enrutaría de vuelta por la interfaz por la que llegó. En un fabric ECMP/anycast — o un setup de LVS Direct Routing — el tráfico es legítimamente asimétrico, así que el rp_filter strict lo agujerea (blackhole) y todo diagnóstico (enlace up, BGP established, bond sano) se ve verde.

```bash
$ sysctl net.ipv4.conf.all.rp_filter
net.ipv4.conf.all.rp_filter = 1        # strict — drops asymmetric flows

# Loose mode: accept if the source is reachable via ANY interface (RFC 3704 loose):
$ sudo sysctl -w net.ipv4.conf.all.rp_filter=2
$ sudo sysctl -w net.ipv4.conf.enp1s0.rp_filter=2

# Watch the drops accumulate before you fix it:
$ nstat -az | grep -i rpfilter
IpReversePathFilter        18422    0.0
```

Para **LVS Direct Routing** y cualquier host que deba sostener una VIP en `lo` sin responder ARP por ella, los sysctls complementarios son igual de determinantes:

```bash
$ sudo sysctl -w net.ipv4.conf.all.arp_ignore=1   # only reply to ARP for IPs on the receiving iface
$ sudo sysctl -w net.ipv4.conf.all.arp_announce=2 # announce the best local source, not the VIP
```

### 4.4 Elegir la capa: VRRP vs. anycast/BGP

| | VRRP (keepalived) | Anycast + BGP/ECMP (FRR) |
|---|---|---|
| Capa OSI | L2/L3, subred única | L3, enrutado, multi-subred / multi-sitio |
| Nodos activos | 1 activo, N−1 en reposo | **Todos activos** (carga repartida por hash ECMP) |
| Mecanismo de failover | ARP gratuito + elección por prioridad | Retirada de ruta + convergencia de enrutamiento (BFD ⇒ sub-segundo) |
| Tiempo de failover | ~3 × advert_int (por defecto ~3 s; ajustable a sub-segundo) | Convergencia BGP/BFD, decenas de ms–segundos |
| Límite de alcance | Un dominio de broadcast | Hasta donde lleguen las rutas |
| Impacto en el cliente | Transparente (misma VIP, misma MAC) | Transparente (misma IP anycast) |
| Requiere | Solo los dos hosts + alcanzabilidad L2 | Routers cooperantes, un plan de AS/peering |
| Techo de capacidad | El throughput de un nodo | La suma de todos los nodos |
| Fallo clásico | Split-brain, GARP descartado | Enrutamiento asimétrico / `rp_filter`, BGP con flap |
| Encaja en | Gateway de primer salto, par de LB, VLAN on-prem | Front-ends de servicio globales, escala de DC, capacidad + HA juntas |

**Regla práctica:** VRRP para el *gateway* y pares de LB pequeños donde un standby en reposo es aceptable y todo vive en una VLAN. Anycast/BGP cuando necesitás que *todos* los nodos sirvan, alcance entre subredes o entre sitios, y failover medido por convergencia de enrutamiento en lugar de por ARP. Se componen: VRRP para el gateway norte-sur dentro de un rack, anycast para la dirección de servicio que resuelve el resto del mundo.

---

## 5. Runbook consolidado de verificación y diagnóstico

```bash
# --- Link layer ---
cat /proc/net/bonding/bond0        # mode, aggregator IDs, Partner MAC, churn state
teamdctl team0 state               # (teaming) runner + per-port aggregator selection
ethtool enp1s0                     # negotiated speed/duplex — a mode-4 slave at wrong speed drops out
ip -s link show bond0              # per-interface error/drop counters

# --- Gateway (VRRP) ---
ip -br addr show enp3s0            # is the VIP here? (who is MASTER)
tcpdump -ni enp3s0 vrrp           # exactly one advertiser; proto 112 reaching the peer?
journalctl -u keepalived -f        # transitions + WHY (script fail, priority change)
conntrackd -s                      # internal/external cache size; "lost" counter

# --- Path (routing / anycast) ---
ip route show 203.0.113.0/24       # ECMP next-hops present?
ip route get <dst> from <src> ipproto tcp sport <p> dport <p>   # which next-hop this flow takes
vtysh -c "show bgp ipv4 unicast summary"     # BGP sessions Established? PfxRcd sane?
vtysh -c "show bgp ipv4 unicast <vip>/32"    # is the anycast route advertised right now?
bfdd / vtysh -c "show bfd peers"             # sub-second liveness up?

# --- The silent killers ---
sysctl net.ipv4.conf.all.rp_filter           # 1 (strict) blackholes asymmetric/multipath
nstat -az | grep -iE 'rpfilter|drop'          # proof the kernel is dropping, and why
sysctl net.ipv4.fib_multipath_hash_policy     # 0=L3, 1=L3+L4 hashing for ECMP
```

**La prueba de fallo end-to-end que atrapa lo que los dashboards en verde pasan por alto:** no pruebes matando un *proceso* — desenchufá un *cable*. Bajá físicamente un esclavo del bond (`ip link set enp1s0 down`), confirmá que el bond se mantiene up sobre el superviviente sin pérdida de paquetes a un `ping` en marcha; después bajá el nodo master entero y confirmá que la VIP se mueve *y* que una sesión SSH/TCP preexistente sobrevive (probando conntrackd), *y* que anycast se retiró dentro de tu SLO. Un setup que sobrevive a `systemctl stop` pero no a `ip link set down` tiene HA de capa de enlace sin probar — que es exactamente de donde vienen las caídas reales.

---

## 6. Referencias

- LPI — LPIC-3 Exam 306 Objectives (306-300, v3.0): <https://www.lpi.org/our-certifications/exam-306-objectives/>
- RFC 5798 — Virtual Router Redundancy Protocol (VRRP) Version 3 for IPv4 and IPv6: <https://datatracker.ietf.org/doc/html/rfc5798>
- RFC 3768 — Virtual Router Redundancy Protocol (VRRP) v2: <https://datatracker.ietf.org/doc/html/rfc3768>
- RFC 3704 — Ingress Filtering for Multihomed Networks (reverse-path filtering): <https://datatracker.ietf.org/doc/html/rfc3704>
- keepalived — documentación oficial y página de manual `keepalived.conf(5)`: <https://keepalived.readthedocs.io/> y <https://www.keepalived.org/manpage.html>
- Linux kernel — documentación del driver de bonding (modes, `xmit_hash_policy`, `miimon`, 802.3ad): <https://www.kernel.org/doc/Documentation/networking/bonding.rst>
- libteam / teamd — documentación del proyecto y `teamd.conf(5)`: <https://github.com/jpirko/libteam/wiki>
- Red Hat — Configuring and Managing Networking (RHEL 9): bonding, y la obsolescencia del network teaming: <https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/configuring_and_managing_networking/index>
- conntrack-tools / conntrackd — documentación y página de manual (replicación de estado, primary-backup): <https://conntrack-tools.netfilter.org/manual.html>
- FRRouting — guía de usuario (BGP, OSPF, BFD, ECMP): <https://docs.frrouting.org/>
- Linux Advanced Routing & Traffic Control (LARTC) — policy routing y multipath: <https://lartc.org/howto/>
- `systemd-networkd` — `systemd.netdev(5)` (Bond/`[Bond]`) y `systemd.network(5)`: <https://www.freedesktop.org/software/systemd/man/latest/systemd.netdev.html>