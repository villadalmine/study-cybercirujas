# Guía de Estudio de Certificación LPIC-2: Tema 205 (Examen 201-450) — Configuración de Red

## 1. Motivación Arquitectónica y Planteamiento del Problema en Producción

En entornos empresariales de misión crítica e infraestructura cloud-native, la arquitectura de red del host sustenta la confiabilidad del sistema, la alta disponibilidad (HA), la escalabilidad de throughput y la segmentación de seguridad. Un solo fallo en una tarjeta de interfaz de red (NIC), una caída de puerto de switch o una política de enrutamiento de paquetes inadecuada puede causar escenarios de split-brain en aplicaciones en cluster (por ejemplo, control planes de Kubernetes, Etcd, Corosync/Pacemaker, PostgreSQL Patroni) o dar lugar a que el enrutamiento asimétrico descarte tráfico de firewalls con estado (stateful).

### 1.1 Los Requisitos de Red Empresarial
Los nodos empresariales modernos, tanto bare-metal como virtualizados, deben cumplir cuatro imperativos arquitectónicos clave:
1. **Redundancia y Agregación de Enlaces (L2/L3)**: Protección contra fallos en el medio físico o en switches TOR (Top-of-Rack) al tiempo que se multiplexa el ancho de banda a través de múltiples interfaces físicas (IEEE 802.3ad / LACP).
2. **Segmentación de Tráfico (VLANs IEEE 802.1Q)**: Aislamiento de flujos sensibles de tráfico del control plane, almacenamiento (iSCSI/NFS), administración y data-plane sobre trunks físicos unificados.
3. **Enrutamiento Basado en Políticas (PBR)**: Redes multi-homed donde la selección de tráfico se rige por criterios más allá de la IP de destino del paquete —como la IP de origen, la interfaz de entrada o los bits TOS (Type of Service)— evitando descartes por enrutamiento asimétrico causados por Reverse Path Filtering (`rp_filter`).
4. **Stack de Resolución de Host Resiliente**: Garantizar un orden determinista en Name Service Switch (`nsswitch.conf`), almacenamiento en caché DNS local a nivel de todo el sistema (`systemd-resolved`) y comportamientos de fallback dual-stack IPv4/IPv6.

```
                   +------------------------------------+
                   |     Linux Kernel Network Stack     |
                   |                                    |
                   | +--------------------------------+ |
                   | |    Policy Routing Engine       | |
                   | |   (rt_tables & ip rule DB)     | |
                   | +--------------------------------+ |
                   |                 |                  |
                   | +--------------------------------+ |
                   | | 802.1Q VLAN Interface Processor| |
                   | |   (bond0.100  /  bond0.200)    | |
                   | +--------------------------------+ |
                   |                 |                  |
                   | +--------------------------------+ |
                   | | Linux Ethernet Bonding Subsystem| |
                   | |      (bond0 / Mode 4 LACP)     | |
                   | +--------------------------------+ |
                   +--------/------------------\--------+
                           /                    \
            +--------------------+        +--------------------+
            | Slave Interface 1  |        | Slave Interface 2  |
            |      (eth0)        |        |      (eth1)        |
            +---------+----------+        +---------+----------+
                      |                             |
                      |   LACP IEEE 802.3ad Trunk   |
                      v                             v
            +--------------------+        +--------------------+
            | Top-of-Rack Switch |<----->| Top-of-Rack Switch |
            |      (TOR-A)       |  mLAG  |      (TOR-B)       |
            +--------------------+        +--------------------+
```

### 1.2 Mecánica del Subsistema del Kernel de Linux
A nivel del kernel de Linux, el procesamiento de paquetes atraviesa varios subsistemas distintos:
- **Netfilter / Capa de Socket**: Filtra datagramas entrantes/salientes a través de hooks antes de que lleguen a los buffers de socket de la aplicación.
- **FIB (Forwarding Information Base)**: El mecanismo de búsqueda del kernel para el enrutamiento IP de destino. Las configuraciones tradicionales consultan la `table main` (ID 254) o la `table local` (ID 255). Los sistemas multi-homed utilizan tablas adicionales definidas por el usuario (`table 100`, `table 200`) gestionadas mediante `ip rule`.
- **Subsistema IP Neighbor / ARP**: Mantiene tablas de mapeo de L3 a L2 (`ip neigh`). Las tramas salientes se encolan en `dev_queue` antes de los anillos de transmisión de hardware (`tx_ring`).
- **Capa de Abstracción de Drivers**: Expone dispositivos de red físicos (`ethX`, `enpXsY`) y virtuales (`bondX`, `teamX`, `vlanX`, `vethX`) al user space a través de sockets `rtnetlink`.

---

## 2. Comparativas Técnicas y Matriz de Compromisos (Trade-Offs)

### 2.1 Subsistemas de Configuración de Red: Heredados (Legacy) vs. Modernos
La gestión de redes en Linux ha evolucionado desde una configuración simple basada en scripts de shell (`ifupdown`) hasta daemons dinámicos orientados a eventos (`NetworkManager`, `systemd-networkd`, `Netplan`).

| Dimensión | `ifupdown` Heredado (`/etc/network/interfaces`) | Scripts RHEL/CentOS (`/etc/sysconfig/network-scripts`) | `NetworkManager` (`nmcli`, `keyfile`) | `systemd-networkd` | `Netplan` (Abstracción de Ubuntu) |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Arquitectura Principal** | Invocación estática de scripts de shell | Invocación estática de scripts de shell | Daemon dinámico impulsado por DBus | Daemon init ligero de systemd | Capa de abstracción declarativa en YAML |
| **Huella de Memoria del Daemon** | Ninguna (runtime efímero) | Ninguna (runtime efímero) | ~25MB - 60MB RAM | ~2MB - 5MB RAM | Efímera (genera configuraciones backend) |
| **Entorno Objetivo** | Debian embebido o heredado | RHEL 6/7 empresarial heredado | Desktop, Workstations, Laptops con múltiples NICs | Instancias Cloud, Hosts de Contenedores, Servidores Mínimos | Nodos Cloud y Edge de Ubuntu 18.04+ |
| **Convergencia / Tiempo de Arrancado** | Lento (ejecución síncrona bloqueante) | Lento (ejecución bloqueante de shell) | Medio (inicialización orientada a eventos) | Ultra-Rápido (notificación asíncrona del kernel) | Depende del backend (`networkd` vs `NM`) |
| **Soporte Hotplug** | Deficiente (requiere `allow-hotplug` manual) | Deficiente | Nativo (autodetecta eventos de hardware mediante udev) | Nativo (seguimiento de enlace integrado en udev) | Dependiente del backend |
| **Modelo de Configuración** | Sintaxis imperativa por interfaz | Pares clave-valor imperativos | CLI imperativa / keyfiles declarativos | Archivos INI declarativos `.netdev` y `.network` | Esquema declarativo YAML v2 |

---

### 2.2 Agregación de Enlaces: Bonding del Kernel vs. Network Teaming (`teamd`)

Linux proporciona dos mecanismos distintos para unificar múltiples interfaces físicas en una interfaz lógica tolerante a fallos.

```
       +-------------------------------------------------------------+
       |                  User Space Control Plane                   |
       |  (sysfs / procfs for Bonding)      (teamd daemon for Team)  |
       +------------------------------+------------------------------+
                                      |
       +------------------------------v------------------------------+
       |                  Kernel Space Execution Layer                |
       |  +------------------------+      +-----------------------+  |
       |  |  drivers/net/bonding   |      |  drivers/net/team     |  |
       |  | (Monolithic C Logic)   |      | (Modular Netlink App) |  |
       |  +------------------------+      +-----------------------+  |
       +-------------------------------------------------------------+
```

| Característica / Métrica | Bonding de Ethernet en Linux (`bonding.ko`) | Teaming de Red en Linux (`drivers/net/team` y `teamd`) |
| :--- | :--- | :--- |
| **Ubicación de la Arquitectura** | Implementación monolítica como módulo del kernel | Infraestructura mínima en kernel + Daemon en userspace (`teamd`) |
| **Extensibilidad** | Baja (requiere recompilación del kernel para nuevos algoritmos) | Alta (plugins en userspace / código personalizado cargado dinámicamente) |
| **Rendimiento (Throughput)**| Extremadamente alto (cero cambio de contexto entre userspace y kernel) | Alto (path rápido en kernel, path de control en userspace) |
| **Implementación de LACP** | Codificado rígidamente en `drivers/net/bonding/bond_3ad.c` | Módulo runner de userspace en `teamd` (`lacp`) |
| **Mecanismos de Monitoreo** | Polling MII (Media Independent Interface) y ARP | Polling MII, ARP, NS/NA (IPv6), Hooks personalizados de salud vía D-Bus |
| **Estado de Depreciación** | Totalmente soportado, estándar universal de la industria | Funcionalidades congeladas / Obsoleto en distribuciones empresariales más recientes (RHEL 9+) a favor de bonding |

#### Desglose de los Modos de Bonding en Linux
1. **Mode 0 (`balance-rr`)**: Transmisión de paquetes Round-robin entre los esclavos (slaves). Proporciona balanceo de carga y tolerancia a fallos. *Requiere soporte en el switch (etherchannel estático).*
2. **Mode 1 (`active-backup`)**: Solo un esclavo está activo. Una segunda interfaz toma el control si la primaria falla. *No requiere configuración en el switch.*
3. **Mode 2 (`balance-xor`)**: Transmite basándose en la política de hash `(MAC-origen XOR MAC-destino) % slave_count`. *Requiere agregación de enlaces estática en el switch.*
4. **Mode 3 (`broadcast`)**: Transmite todo en todas las interfaces esclavas. Utilizado para redes de alta confiabilidad (por ejemplo, feeds de datos financieros).
5. **Mode 4 (`802.3ad`)**: Agregación Dinámica de Enlaces (LACP). Crea grupos de agregación que comparten ajustes de velocidad/dúplex. *Requiere soporte IEEE 802.3ad en el switch.*
6. **Mode 5 (`balance-tlb`)**: Balanceo de Carga de Transmisión Adaptativo. El tráfico saliente se distribuye según la carga actual en cada esclavo. El entrante es recibido por el esclavo actual.
7. **Mode 6 (`balance-alb`)**: Balanceo de Carga Adaptativo. Incluye `balance-tlb` más balanceo de carga de recepción (RLB) mediante la manipulación de la negociación ARP.

---

### 2.3 Herramientas de Gestión: Net-tools Heredadas vs. `iproute2` Moderno

| Funcionalidad | Utilidad Heredada (`net-tools`) | Utilidad Moderna (`iproute2`) | Interfaz de Llamada al Sistema del Kernel |
| :--- | :--- | :--- | :--- |
| **Gestión de Interfaces** | `ifconfig eth0 up` | `ip link set dev eth0 up` | Netlink socket (`RTM_NEWLINK`) |
| **Asignación de Direcciones** | `ifconfig eth0 192.168.1.2 netmask 255.255.255.0` | `ip addr add 192.168.1.2/24 dev eth0` | Netlink socket (`RTM_NEWADDR`) |
| **Consulta de Tabla de Enrutamiento** | `route -n` | `ip route show` / `ip route show table all` | Netlink socket (`RTM_GETROUTE`) |
| **Inspección de Tabla ARP** | `arp -an` | `ip neigh show` | Netlink socket (`RTM_GETNEIGH`) |
| **Lista de Grupos Multicast** | `netstat -g` | `ip maddr show` | Netlink socket (`RTM_GETMULTICAST`)|
| **Reglas de Enrutamiento por Política** | *No soportado* | `ip rule show` | Netlink socket (`RTM_GETRULE`) |

---

## 3. Manifiestos y Configuraciones de Infraestructura en Producción

Todas las configuraciones a continuación son archivos completos, sintácticamente válidos y listos para producción.

### 3.1 Debian/Ubuntu Heredado: `/etc/network/interfaces`
*Características: Bonding LACP con interfaz dual (`bond0`) con subinterfaces VLAN 100 y VLAN 200, rutas estáticas personalizadas y reglas de enrutamiento por política inline.*

```ini
# /etc/network/interfaces
# Production High-Availability Network Configuration

source /etc/network/interfaces.d/*

# Loopback Interface
auto lo
iface lo inet loopback

# Primary Physical Slave 1
auto eth0
iface eth0 inet manual
    bond-master bond0
    bond-primary eth0

# Primary Physical Slave 2
auto eth1
iface eth1 inet manual
    bond-master bond0

# LACP Aggregated Bond Interface
auto bond0
iface bond0 inet manual
    bond-slaves eth0 eth1
    bond-mode 4
    bond-miimon 100
    bond-downdelay 200
    bond-updelay 200
    bond-lacp-rate fast
    bond-xmit-hash-policy layer3+4

# VLAN 100 - Production Data Plane
auto bond0.100
iface bond0.100 inet static
    address 10.100.0.50
    netmask 255.255.255.0
    gateway 10.100.0.1
    dns-nameservers 1.1.1.1 8.8.8.8
    dns-search production.internal
    mtu 9000
    up ip rule add from 10.100.0.50/32 table 100
    up ip route add default via 10.100.0.1 dev bond0.100 table 100
    down ip route del default via 10.100.0.1 dev bond0.100 table 100
    down ip rule del from 10.100.0.50/32 table 100

# VLAN 200 - Management & Backup Plane
auto bond0.200
iface bond0.200 inet static
    address 10.200.0.50
    netmask 255.255.255.0
    mtu 1500
    up ip route add 172.16.0.0/12 via 10.200.0.1 dev bond0.200
    down ip route del 172.16.0.0/12 via 10.200.0.1 dev bond0.200
```

---

### 3.2 Enterprise Ubuntu Netplan: `/etc/netplan/01-netplan.yaml`
*Características: Declaración Netplan YAML utilizando backend `networkd`, definiendo bonding LACP, trunking de VLAN, dual-stack IPv4/IPv6 y reglas de enrutamiento por política.*

```yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    eth0:
      dhcp4: false
      dhcp6: false
      match:
        macaddress: "52:54:00:a8:3b:01"
      set-name: eth0
    eth1:
      dhcp4: false
      dhcp6: false
      match:
        macaddress: "52:54:00:a8:3b:02"
      set-name: eth1
  bonds:
    bond0:
      interfaces:
        - eth0
        - eth1
      parameters:
        mode: 802.3ad
        mii-monitor-interval: 100
        lacp-rate: fast
        transmit-hash-policy: layer3+4
        down-delay: 200
        up-delay: 200
  vlans:
    bond0.100:
      id: 100
      link: bond0
      mtu: 9000
      addresses:
        - 10.100.0.50/24
        - "2001:db8:100::50/64"
      routes:
        - to: default
          via: 10.100.0.1
          metric: 100
          table: 100
        - to: default
          via: "2001:db8:100::1"
          metric: 100
          table: 100
      routing-policy:
        - from: 10.100.0.50/32
          table: 100
          priority: 1000
        - from: "2001:db8:100::50/128"
          table: 100
          priority: 1001
      nameservers:
        addresses:
          - 1.1.1.1
          - 8.8.8.8
          - "2606:4700:4700::1111"
        search:
          - production.internal
```

---

### 3.3 Configuraciones Nativas Modernas de Systemd-Networkd
Systemd-networkd divide las definiciones de interfaz en unidades físicas, netdev y network separadas dentro de `/etc/systemd/network/`.

#### Archivo 1: Definición de Netdev Bond (`/etc/systemd/network/10-bond0.netdev`)
```ini
[NetDev]
Name=bond0
Kind=bond
MACAddress=52:54:00:a8:3b:01

[Bond]
Mode=802.3ad
MIIMonitorSec=100ms
LACPTransmitRate=fast
TransmitHashPolicy=layer3+4
DownDelaySec=200ms
UpDelaySec=200ms
```

#### Archivo 2: Asociaciones de Esclavo Físico (`/etc/systemd/network/15-eth0.network`)
```ini
[Match]
Name=eth0

[Network]
Bond=bond0
```

#### Archivo 3: Asociaciones de Esclavo Físico (`/etc/systemd/network/15-eth1.network`)
```ini
[Match]
Name=eth1

[Network]
Bond=bond0
```

#### Archivo 4: Definición de Netdev VLAN (`/etc/systemd/network/20-vlan100.netdev`)
```ini
[NetDev]
Name=bond0.100
Kind=vlan

[VLAN]
Id=100
```

#### Archivo 5: Configuración de Red del Bond con Adjunto de VLAN (`/etc/systemd/network/10-bond0.network`)
```ini
[Match]
Name=bond0

[Network]
VLAN=bond0.100
LinkLocalAddressing=no
IPv6AcceptRA=no
```

#### Archivo 6: Configuración de Interfaz VLAN con PBR (`/etc/systemd/network/20-vlan100.network`)
```ini
[Match]
Name=bond0.100

[Network]
Address=10.100.0.50/24
Address=2001:db8:100::50/64
DNS=1.1.1.1
DNS=8.8.8.8
Domains=production.internal

[RoutingPolicyRule]
From=10.100.0.50/32
Table=100
Priority=1000

[RoutingPolicyRule]
From=2001:db8:100::50/128
Table=100
Priority=1001

[Route]
Destination=0.0.0.0/0
Gateway=10.100.0.1
Table=100

[Route]
Destination=::/0
Gateway=2001:db8:100::1
Table=100
```

---

### 3.4 Tablas de Enrutamiento Personalizadas y Stack de Resolución de Nombres

#### Archivo 1: Declaración de Tabla de Enrutamiento Personalizada (`/etc/iproute2/rt_tables`)
```text
#
# reserved values
#
255	local
254	main
253	default
0	unspec
#
# local custom tables
#
100	data_plane
200	mgmt_plane
```

#### Archivo 2: Configuración de Name Service Switch (`/etc/nsswitch.conf`)
```text
# /etc/nsswitch.conf
# System Name Service Switch Configuration

passwd:         files systemd
group:          files systemd
shadow:         files
gshadow:        files

hosts:          files resolve [NOTFOUND=return] dns myhostname
networks:       files

protocols:      db files
services:       db files
ethers:         db files
rpc:            db files

netgroup:       nis
```

#### Archivo 3: Configuración del Resolvedor Systemd (`/etc/systemd/resolved.conf`)
```ini
[Resolve]
DNS=1.1.1.1 8.8.8.8 2606:4700:4700::1111
FallbackDNS=9.9.9.9 1.0.0.1
Domains=production.internal
DNSSEC=allow-downgrade
DNSOverTLS=opportunistic
MulticastDNS=no
LLMNR=no
Cache=yes
CacheFromLocalhost=no
```

#### Archivo 4: Archivo Stub del Resolvedor del Sistema (`/etc/resolv.conf`)
```text
# Generated by systemd-resolved
nameserver 127.0.0.53
options edns0 trust-ad
search production.internal
```

---

## 4. Flujos de Trabajo de Ejecución Real en CLI y Transmisión de Salidas Esperadas

Los siguientes flujos de trabajo representan operaciones en vivo en un nodo Linux empresarial.

### 4.1 Flujo de Trabajo de Consulta de Interfaz y Diagnóstico de Hardware

```bash
$ ip -s link show dev eth0
```
```text
2: eth0: <BROADCAST,MULTICAST,SLAVE,UP,LOWER_UP> mtu 9000 qdisc mq master bond0 state UP mode DEFAULT group default qlen 1000
    link/ether 52:54:00:a8:3b:01 brd ff:ff:ff:ff:ff:ff
    RX:  bytes packets errors dropped missed mcast   
     984210492 7482910      0       0      0   1402 
    TX:  bytes packets errors dropped carrier collsns
     549102941 4920194      0       0      0      0 
```

```bash
$ ethtool eth0
```
```text
Settings for eth0:
	Supported ports: [ TP ]
	Supported link modes:   1000baseT/Full
	                        10000baseT/Full
	Supported pause frame use: Symmetric
	Supports auto-negotiation: Yes
	Supported FEC modes: Not reported
	Advertised link modes:  10000baseT/Full
	Advertised pause frame use: Symmetric
	Advertised auto-negotiation: Yes
	Speed: 10000Mb/s
	Duplex: Full
	Auto-negotiation: on
	Port: Twisted Pair
	PHYAD: 0
	Transceiver: internal
	MDI-X: Unknown
	Supports Wake-on: d
	Wake-on: d
	Current message level: 0x00000007 (7)
			       drv probe link
	Link detected: yes
```

```bash
$ ethtool -k eth0 | grep -E "offload|segmentation"
```
```text
rx-checksumming: on
tx-checksumming: on
	tx-checksum-ipv4: on
	tx-checksum-ip-generic: off [fixed]
	tx-checksum-ipv6: on
scatter-gather: on
	tx-scatter-gather: on
	tx-scatter-gather-fraglist: off [fixed]
tcp-segmentation-offload: on
	tx-tcp-segmentation: on
	tx-tcp-ecn-segmentation: on
	tx-tcp-mangleid-segmentation: off
	tx-tcp6-segmentation: on
generic-segmentation-offload: on
generic-receive-offload: on
large-receive-offload: off [fixed]
```

---

### 4.2 Creación Dinámica sobre la Marcha de Bonding LACP y VLANs 802.1Q vía `iproute2`

```bash
$ sudo ip link add name bond0 type bond mode 802.3ad miimon 100 lacp_rate fast xmit_hash_policy layer3+4
$ sudo ip link set dev eth0 down
$ sudo ip link set dev eth1 down
$ sudo ip link set dev eth0 master bond0
$ sudo ip link set dev eth1 master bond0
$ sudo ip link set dev bond0 up
$ sudo ip link set dev eth0 up
$ sudo ip link set dev eth1 up
$ sudo ip link add link bond0 name bond0.100 type vlan id 100
$ sudo ip addr add 10.100.0.50/24 dev bond0.100
$ sudo ip link set dev bond0.100 mtu 9000 up
$ ip addr show dev bond0.100
```
```text
5: bond0.100@bond0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 9000 qdisc noqueue state UP group default qlen 1000
    link/ether 52:54:00:a8:3b:01 brd ff:ff:ff:ff:ff:ff
    inet 10.100.0.50/24 brd 10.100.0.255 scope global bond0.100
       valid_lft forever preferred_lft forever
    inet6 2001:db8:100::50/64 scope global 
       valid_lft forever preferred_lft forever
    inet6 fe80::5054:ff:fea8:3b01/64 scope link 
       valid_lft forever preferred_lft forever
```

---

### 4.3 Ejecución y Verificación de Enrutamiento Basado en Políticas (PBR)

```bash
$ sudo ip rule add from 10.100.0.50/32 table data_plane priority 1000
$ sudo ip route add default via 10.100.0.1 dev bond0.100 table data_plane
$ ip rule show
```
```text
0:	from all lookup local
1000:	from 10.100.0.50 lookup data_plane
32766:	from all lookup main
32767:	from all lookup default
```

```bash
$ ip route show table data_plane
```
```text
default via 10.100.0.1 dev bond0.100
```

```bash
$ ip route get 8.8.8.8 from 10.100.0.50
```
```text
8.8.8.8 from 10.100.0.50 via 10.100.0.1 dev bond0.100 table data_plane uid 1000
    cache 
```

---

### 4.4 Verificación del Estado de Bonding del Kernel vía ProcFS

```bash
$ cat /proc/net/bonding/bond0
```
```text
Ethernet Channel Bonding Driver: v5.15.0-88-generic

Bonding Mode: IEEE 802.3ad Dynamic link aggregation
Transmit Hash Policy: layer3+4 (1)
MII Status: up
MII Polling Interval (ms): 100
Up Delay (ms): 200
Down Delay (ms): 200
Peer Notification Delay (ms): 0

802.3ad info
LACP rate: fast
Min links: 0
Aggregator selection policy (ad_select): stable
System priority: 65535
System MAC address: 52:54:00:a8:3b:01
Active Aggregator Info:
	Aggregator ID: 1
	Number of ports: 2
	Actor Key: 15
	Partner Key: 32768
	Partner Mac Address: 00:2a:6a:12:99:00

Slave Interface: eth0
MII Status: up
Speed: 10000 Mbps
Duplex: full
Link Failure Count: 0
Permanent HW addr: 52:54:00:a8:3b:01
Slave queue ID: 0
Aggregator ID: 1
Actor Churn State: none
Partner Churn State: none
Actor Partner State: reg_state
LACP Actor port state: 61 (EXP_TIM,DEF,DIST,COLL,AGG,SYNC)

Slave Interface: eth1
MII Status: up
Speed: 10000 Mbps
Duplex: full
Link Failure Count: 0
Permanent HW addr: 52:54:00:a8:3b:02
Slave queue ID: 0
Aggregator ID: 1
Actor Churn State: none
Partner Churn State: none
Actor Partner State: reg_state
LACP Actor port state: 61 (EXP_TIM,DEF,DIST,COLL,AGG,SYNC)
```

---

### 4.5 Gestión de Network Teaming vía `teamdctl` y `nmcli`

```bash
$ sudo teamdctl team0 state
```
```json
{
    "setup": {
        "runner_name": "lacp"
    },
    "ports": {
        "eth0": {
            "link": {
                "up": true
            },
            "runner": {
                "aggregator": {
                    "id": 1,
                    "selected": true
                },
                "state": "current"
            }
        },
        "eth1": {
            "link": {
                "up": true
            },
            "runner": {
                "aggregator": {
                    "id": 1,
                    "selected": true
                },
                "state": "current"
            }
        }
    }
}
```

```bash
$ nmcli connection show
```
```text
NAME         UUID                                 TYPE      DEVICE    
bond0        c83a1290-7f21-432d-98e1-9018ab3c9901  bond      bond0     
bond0.100    91a82f34-1189-4d22-bdf9-0a9e71181283  vlan      bond0.100 
bond-slave-1 30b42f21-8290-482a-a912-182937192801  ethernet  eth0      
bond-slave-2 81a02931-192a-4c91-b912-192039182390  ethernet  eth1      
```

---

### 4.6 Inspección de la Tabla IP Neighbor y Sockets

```bash
$ ip neigh show
```
```text
10.100.0.1 dev bond0.100 lladdr 00:2a:6a:12:99:01 REACHABLE
10.100.0.254 dev bond0.100 lladdr 00:2a:6a:12:99:fe STALE
2001:db8:100::1 dev bond0.100 lladdr 00:2a:6a:12:99:01 router REACHABLE
```

```bash
$ ss -tulpn
```
```text
Netid State  Recv-Q Send-Q   Local Address:Port   Peer Address:Port Process                                                            
udp   UNCONN 0      0        127.0.0.53%lo:53          0.0.0.0:*     users:(("systemd-resolve",pid=842,fd=13))                          
tcp   LISTEN 0      4096     127.0.0.53%lo:53          0.0.0.0:*     users:(("systemd-resolve",pid=842,fd=14))                          
tcp   LISTEN 0      128            0.0.0.0:22           0.0.0.0:*     users:(("sshd",pid=1024,fd=3))                                     
tcp   LISTEN 0      512            0.0.0.0:80           0.0.0.0:*     users:(("nginx",pid=2048,fd=6),("nginx",pid=2049,fd=6))            
tcp   LISTEN 0      128               [::]:22              [::]:*     users:(("sshd",pid=1024,fd=4))                                     
```

```bash
$ lsof -i :80
```
```text
COMMAND  PID     USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
nginx   2048     root    6u  IPv4  29481      0t0  TCP *:http (LISTEN)
nginx   2049 www-data    6u  IPv4  29481      0t0  TCP *:http (LISTEN)
```

---

## 5. Guía Avanzada de Verificación, Recuperación ante Fallos y Diagnóstico

### 5.1 Playbook de Resolución de Problemas SRE del Sistema

```
                         [ Network Issue Reported ]
                                     |
                                     v
                        [ Can host ping Gateway? ]
                               /           \
                             NO             YES
                             /               \
            [ Check Link State & L1/L2 ]     [ Check L3 Routing & Policy Rules ]
                         |                                  |
            +------------+------------+            +--------+--------+
            |                         |            |                 |
     (Link Down / Drops)     (LACP Mismatch) (Path Dropped)   (RPF Filter Drop)
            |                         |            |                 |
    Check `ethtool ethX`    Check ProcFS Bonding   Check `ip route`  Check sysctl
    & Ring Buffers          / `teamdctl` state     & `ip rule`       `rp_filter`
```

---

### 5.2 Escenarios Comunes de Fallo en Producción y Causas Raíz

#### Escenario A: Descartes por Enrutamiento Asimétrico y Reverse Path Filtering
- **Síntoma**: Los paquetes llegan a la interfaz `bond0.200`, pero el host no logra retornar paquetes SYN-ACK o descarta silenciosamente el tráfico entrante a pesar de contar con entradas correctas en la tabla de rutas.
- **Causa Raíz**: Habilitado `rp_filter` del kernel (Strict Reverse Path Filtering). Cuando llega un paquete a `bond0.200`, el kernel comprueba si la ruta de regreso a la IP de origen se enrutaría a través de `bond0.200`. Si `table main` apunta el gateway por defecto hacia `bond0.100`, el kernel considera que el paquete es falsificado (spoofed) y lo descarta silenciosamente.
- **Remediación**: Configurar `rp_filter` en modo permisivo (`2`) o desactivarlo (`0`) para las interfaces objetivo a través de `sysctl`:
  ```bash
  sudo sysctl -w net.ipv4.conf.all.rp_filter=2
  sudo sysctl -w net.ipv4.conf.bond0/100.rp_filter=2
  sudo sysctl -w net.ipv4.conf.bond0/200.rp_filter=2
  ```

#### Escenario B: Descoincidencia de Agregador LACP / Enlace Split-Brain
- **Síntoma**: La interfaz bond está activa (up), pero experimenta aproximadamente un 50% de pérdida de paquetes.
- **Causa Raíz**: Los puertos del switch están mal configurados (por ejemplo, un puerto en modo LACP y el puerto compañero en modo standalone/desagrupado), o una descoincidencia en `xmit_hash_policy` provoca el reordenamiento de tramas a través de enlaces fuera de orden.
- **Remediación**: Inspeccionar `/proc/net/bonding/bond0` para verificar la consistencia de `Partner MAC Address` en todas las interfaces esclavas. Asegurar que `xmit_hash_policy` esté configurado explícitamente en `layer3+4` para la distribución a nivel de capa de transporte.

#### Escenario C: Blackhole de Path MTU sobre Trunks VLAN
- **Síntoma**: El ping ICMP funciona (payload pequeño), SSH conecta, pero los payloads HTTP grandes o el handshake de TLS se cuelgan indefinidamente.
- **Causa Raíz**: La interfaz física del switch tiene un MTU estándar de 1500, pero la configuración de la VLAN del host Linux define `mtu 9000` (Jumbo Frames), o un router intermedio descarta los paquetes ICMP "Fragmentation Needed".
- **Remediación**: Verificar el MTU de extremo a extremo usando pings del tamaño del payload con el bit Don't Fragment (DF) activado:
  ```bash
  ping -M do -s 8972 10.100.0.1
  ```

---

### 5.3 Comandos de Herramientas de Diagnóstico Profundo

#### 1. Captura de Paquetes de Bajo Nivel e Inspección de Tramas VLAN
Capturar tráfico etiquetado 802.1Q entrante en interfaces físicas:
```bash
sudo tcpdump -nn -e -i eth0 vlan 100 and port 80 -vvv
```
*`-e` imprime el encabezado a nivel de enlace, exponiendo las direcciones MAC de origen/destino y las etiquetas VLAN (`vlan 100, p 0`).*

#### 2. Consulta de la Ruta de Búsqueda de Rutas del Kernel
Simular cómo el FIB del kernel procesa una tupla de paquetes específica:
```bash
ip route get 172.16.10.50 from 10.100.0.50 iif bond0.100
```

#### 3. Análisis de Errores en Contadores de Buffer de Anillo Rx/Tx de Hardware
Comprobar si los anillos de hardware de la NIC están descartando tramas debido al agotamiento del buffer:
```bash
ethtool -S eth0 | grep -E "drop|error|miss|fifo|buf"
```
```text
     rx_dropped: 0
     tx_dropped: 0
     rx_errors: 0
     tx_errors: 0
     rx_missed_errors: 0
     rx_fifo_errors: 0
     rx_buf_length_errors: 0
```

#### 4. Rastreos de Diagnóstico y Descubrimiento de Path MTU
Rastrear dinámicamente las restricciones de path MTU a través de los saltos de red:
```bash
tracepath -n 10.100.0.1
```

---

### 5.4 Matriz de Optimización de Sysctl del Kernel para Redes de Alto Rendimiento (Throughput)

Guardar los siguientes parámetros ajustables de producción dentro de `/etc/sysctl.d/99-production-network.conf`:

```ini
# /etc/sysctl.d/99-production-network.conf
# SRE Production Networking Tuneables

# Enable IP Forwarding (Required for Routers, VPN gateways, K8s CNI)
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1

# Loose Reverse Path Filtering (Mitigates PBR Asymmetric Routing Drops)
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2

# Increase Maximum Network Socket Receive/Send Buffers (16MB)
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 262144
net.core.wmem_default = 262144

# Increase Maximum Connection Backlog Queue for High Concurrency
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65536

# TCP Buffer Auto-Tuning Parameters (min, default, max in bytes)
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# Enable TCP BBR Congestion Control
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# TCP TIME_WAIT Reuse for High-Frequency Load Balancers
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
```

Aplicar la configuración de sysctl inmediatamente:
```bash
sudo sysctl --system
```

---

## 6. Referencias

- **Objetivos Oficiales de LPIC-2 del Linux Professional Institute (LPI)**:  
  [https://wiki.lpi.org/wiki/LPIC-2_Objectives_V4.5](https://wiki.lpi.org/wiki/LPIC-2_Objectives_V4.5)  
  [https://www.lpi.org/our-certifications/lpic-2-overview/](https://www.lpi.org/our-certifications/lpic-2-overview/)

- **Documentación del Kernel de Linux — Driver Ethernet Bonding**:  
  [https://www.kernel.org/doc/Documentation/networking/bonding.txt](https://www.kernel.org/doc/Documentation/networking/bonding.txt)

- **Páginas de Man y Documentación Oficial de iproute2**:  
  [https://wiki.linuxfoundation.org/networking/iproute2](https://wiki.linuxfoundation.org/networking/iproute2)  
  [https://man7.org/linux/man-pages/man8/ip.8.html](https://man7.org/linux/man-pages/man8/ip.8.html)

- **Documentación Oficial de Systemd-networkd**:  
  [https://www.freedesktop.org/software/systemd/man/systemd.network.html](https://www.freedesktop.org/software/systemd/man/systemd.network.html)  
  [https://www.freedesktop.org/software/systemd/man/systemd.netdev.html](https://www.freedesktop.org/software/systemd/man/systemd.netdev.html)

- **Especificación de Referencia Central de Netplan**:  
  [https://netplan.io/reference/](https://netplan.io/reference/)

- **Guía de Administración de Red de Red Hat Enterprise Linux**:  
  [https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/](https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/)