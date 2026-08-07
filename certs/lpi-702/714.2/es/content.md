# LPI 702-100: Material de Estudio para el Examen de Certificación BSD Specialist
## Tema 714.2: Configuración Básica de Red (Peso: 5)

---

### 1. Motivación de la Arquitectura de Producción y Problema Arquitectónico

#### El Paradigma de Redes BSD en el Borde y Núcleo Empresarial
En entornos empresariales de alta disponibilidad, los routers de borde, dispositivos de seguridad (p. ej., pfSense, OPNSense, firewalls OpenBSD personalizados) y matrices de almacenamiento de alto rendimiento (p. ej., TrueNAS en FreeBSD) confían en el stack de red de BSD debido a la fina granularidad del bloqueo de su kernel, el almacenamiento en búfer de sockets predecible, la arquitectura de red zero-copy (`zero-copy sockets` / `netmap`) y la secuencia de arranque determinista.

A diferencia de las distribuciones Linux modernas que abstraen la gestión de interfaces detrás de daemons que reaccionan dinámicamente (`systemd-networkd`, `NetworkManager`) con capas de IPC de DBus, los sistemas operativos BSD imponen un paradigma de configuración de red declarativo y basado en archivos que se ejecuta de forma determinista durante la inicialización del sistema a través de scripts de `rc.d`.

```
                   +---------------------------------------+
                   |           Applications /              |
                   |      Daemon Layer (bind, unbound)     |
                   +-------------------+-------------------+
                                       | Socket API (AF_INET / AF_INET6)
                   +-------------------+-------------------+
                   |         BSD Kernel Socket Layer       |
                   |        (mbuf chains, zero-copy)       |
                   +---------+-------------------+---------+
                             |                   |
            +----------------+--+             +--+----------------+
            |  IPv4 / IPv6      |             |  pf / ipfw / npf  |
            |  Routing Table    |             |  Packet Filtering |
            +--------+----------+             +--+----------------+
                     |                           |
            +--------+---------------------------+---------+
            | Link Aggregation (lagg / trunk / agr)        |
            | IEEE 802.3ad LACP / Failover                 |
            +--------------------+-------------------------+
                                 |
            +--------------------+-------------------------+
            |  VLAN Tagging (802.1Q)                       |
            +--------------------+-------------------------+
                                 |
            +--------------------+-------------------------+
            | Hardware Drivers (ixgbe, em, vioif, alc, re) |
            +----------------------------------------------+
```

#### Principales Desafíos Arquitectónicos en Despliegues BSD de Producción
1. **Heterogeneidad Multisabor**: Las flotas BSD en producción a menudo combinan FreeBSD (I/O y almacenamiento de alto rendimiento), OpenBSD (gateways de perímetro endurecidos y endpoints de VPN) y NetBSD (arquitecturas embebidas y appliances especializados). Cada variante implementa una sintaxis de configuración y abstracciones de red distintas:
   - **FreeBSD**: Declaración de red centralizada en un solo archivo en `/etc/rc.conf` evaluada por `/etc/rc.d/netif` y `/etc/rc.d/routing`.
   - **OpenBSD**: Archivos de configuración por interfaz (`/etc/hostname.<if>`) ejecutados por `/etc/netstart`.
   - **NetBSD**: Modelo dual que utiliza `/etc/rc.conf` junto con archivos por interfaz (`/etc/ifconfig.<if>`).
2. **Agregación de Enlaces y Redundancia**: Los servidores con múltiples interfaces (multi-homed) requieren LACP (IEEE 802.3ad) o failover activo/pasivo combinado con trunking VLAN 802.1Q. Diseñar interfaces requiere comprender la estratificación de interfaces (`physical` $\rightarrow$ `lagg`/`trunk`/`agr` $\rightarrow$ `vlan` $\rightarrow$ `L3 IP`).
3. **Coexistencia de Dual-Stack IPv4/IPv6**: Garantizar operaciones de bind atómicas, manejar la Autoconfiguración de Direcciones Sin Estado (SLAAC) de IPv6 junto con el direccionamiento IPv6 estático y prevenir bloqueos de Detección de Direcciones Duplicadas (DAD) durante el arranque.
4. **Persistencia vs. Ejecución Efímera**: Los cambios en caliente mediante `ifconfig` o `route` no sobreviven a los reinicios. Los Administradores de Sistemas deben garantizar la alineación exacta entre el estado de la memoria en tiempo de ejecución y los manifiestos de configuración persistentes en `/etc`.

---

### 2. Comparativas Técnicas y Tablas de Sopesamiento (Trade-off)

#### 2.1 Matriz de Frameworks de Configuración de Red en BSD

| Característica / Aspecto | FreeBSD | OpenBSD | NetBSD |
| :--- | :--- | :--- | :--- |
| **Manifiesto de Red Principal** | `/etc/rc.conf` (y `/etc/rc.conf.d/`) | `/etc/hostname.<if>` | `/etc/rc.conf` y `/etc/ifconfig.<if>` |
| **Comando de Gestión de Interfaces** | `ifconfig` | `ifconfig` | `ifconfig` |
| **Comando de Reinicio de Red** | `service netif restart && service routing restart` | `sh /etc/netstart` | `/etc/rc.d/network restart` |
| **Manifiesto de Gateway por Defecto** | `defaultrouter` en `/etc/rc.conf` | `/etc/mygate` | `defaultroute` en `/etc/rc.conf` o `/etc/mygate` |
| **Manifiesto de Ruta Estática** | `static_routes` en `/etc/rc.conf` | `/etc/hostname.<if>` o script personalizado | `/etc/rc.conf` (`static_routes`) |
| **Módulo de Agregación de Enlaces** | `lagg(4)` | `trunk(4)` | `agr(4)` |
| **Creación de Interfaz VLAN** | `vlans_<if>` o `cloned_interfaces` en `/etc/rc.conf` | Creada vía `/etc/hostname.vlanX` | Creada vía `/etc/ifconfig.vlanX` |
| **Manifiesto de Hostname** | `hostname` en `/etc/rc.conf` | `/etc/myname` | `hostname` en `/etc/rc.conf` o `/etc/myname` |

#### 2.2 Modos del Protocolo de Agregación de Enlaces en los Sabores de BSD

| Modo de Agregación | Sintaxis de FreeBSD (`lagg`) | Sintaxis de OpenBSD (`trunk`) | Sintaxis de NetBSD (`agr`) | Comportamiento Operativo y Compromisos (Trade-offs) de Producción |
| :--- | :--- | :--- | :--- | :--- |
| **LACP (IEEE 802.3ad)** | `laggproto lacp` | `trunkproto lacp` | `lacp` (por defecto en `agr`) | **Activo-Activo**. Requiere configuración LACP del lado del switch. Negociación dinámica de enlaces, detección automática de fallos, hashing de flujo. |
| **Failover (Activo/Backup)**| `laggproto failover` | `trunkproto failover` | *N/A (Usar `carp(4)` o failover estático)* | **Activo-Pasivo**. Utiliza la interfaz primaria; conmuta a la de respaldo cuando cae el enlace. No requiere configuración en el switch. |
| **Load Balance** | `laggproto loadbalance` | `trunkproto loadbalance` | *N/A* | **Multienlace Estático**. Balancea el tráfico basándose en encabezados IP/MAC. Sin señalización LACP; sensible a fallos de enlace asimétricos. |

---

### 3. Manifiestos de Configuración Completos y Sintácticamente Válidos

Las siguientes configuraciones ilustran un escenario de borde empresarial:
- Dos interfaces físicas de 10GbE (`em0`, `em1` en OpenBSD/NetBSD; `ix0`, `ix1` en FreeBSD).
- Agregadas en un enlace LACP de alta disponibilidad (`lagg0` / `trunk0` / `agr0`).
- Trunking VLAN 802.1Q 10 (Gestión: `192.168.10.50/24`, Gateway: `192.168.10.1`, IPv6: `2001:db8:10::50/64`) y VLAN 20 (Datos: `10.20.0.50/24`).

#### 3.1 Configuración Completa de FreeBSD

##### Archivo: `/etc/rc.conf`
```sh
# System Identity
hostname="freebsd-node01.prod.enterprise.internal"

# Base Network Interfaces Initialization
ifconfig_ix0="up"
ifconfig_ix1="up"

# Link Aggregation (LACP) Configuration
cloned_interfaces="lagg0 vlan10 vlan20"
ifconfig_lagg0="laggproto lacp laggport ix0 laggport ix1 up"

# 802.1Q VLAN Sub-Interfaces
ifconfig_vlan10="vlan 10 vlandev lagg0 inet 192.168.10.50 netmask 255.255.255.0 up"
ifconfig_vlan10_ipv6="inet6 2001:db8:10::50 prefixlen 64"
ifconfig_vlan20="vlan 20 vlandev lagg0 inet 10.20.0.50 netmask 255.255.255.0 up"

# Routing Configuration
defaultrouter="192.168.10.1"
ipv6_defaultrouter="2001:db8:10::1"

# Static Route Configuration (Routing 172.16.0.0/12 traffic via Data VLAN Gateway)
static_routes="internal_app"
route_internal_app="-net 172.16.0.0/12 10.20.0.1"
```

##### Archivo: `/etc/resolv.conf`
```conf
search prod.enterprise.internal enterprise.internal
nameserver 192.168.10.2
nameserver 192.168.10.3
options timeout:2 attempts:3 rotate
```

##### Archivo: `/etc/hosts`
```etc
127.0.0.1       localhost localhost.prod.enterprise.internal
::1             localhost localhost.prod.enterprise.internal
192.168.10.50   freebsd-node01.prod.enterprise.internal freebsd-node01
2001:db8:10::50 freebsd-node01.prod.enterprise.internal freebsd-node01
```

---

#### 3.2 Configuración Completa de OpenBSD

##### Archivo: `/etc/myname`
```text
openbsd-gw01.prod.enterprise.internal
```

##### Archivo: `/etc/hostname.em0`
```text
up
```

##### Archivo: `/etc/hostname.em1`
```text
up
```

##### Archivo: `/etc/hostname.trunk0`
```text
trunkproto lacp trunkport em0 trunkport em1 up
```

##### Archivo: `/etc/hostname.vlan10`
```text
vlan 10 vlandev trunk0
inet 192.168.10.50 255.255.255.0
inet6 2001:db8:10::50 64
up
```

##### Archivo: `/etc/hostname.vlan20`
```text
vlan 20 vlandev trunk0
inet 10.20.0.50 255.255.255.0
!route add -net 172.16.0.0/12 10.20.0.1
up
```

##### Archivo: `/etc/mygate`
```text
192.168.10.1
2001:db8:10::1
```

##### Archivo: `/etc/resolv.conf`
```conf
search prod.enterprise.internal
nameserver 192.168.10.2
nameserver 192.168.10.3
lookup bind file
```

---

#### 3.3 Configuración Completa de NetBSD

##### Archivo: `/etc/rc.conf`
```sh
# System Identity
hostname=netbsd-node01.prod.enterprise.internal

# Enable Network Functionality
auto_ifconfig=YES
net_interfaces="wm0 wm1 agr0 vlan10 vlan20"

# Default IPv4 and IPv6 Routing
defaultroute="192.168.10.1"
defaultroute6="2001:db8:10::1"

# Static Routing
static_routes="corp"
route_corp="-net 172.16.0.0/12 10.20.0.1"
```

##### Archivo: `/etc/ifconfig.wm0`
```text
up
```

##### Archivo: `/etc/ifconfig.wm1`
```text
up
```

##### Archivo: `/etc/ifconfig.agr0`
```text
create
agrport wm0
agrport wm1
up
```

##### Archivo: `/etc/ifconfig.vlan10`
```text
create
vlan 10 vlandev agr0
inet 192.168.10.50 netmask 255.255.255.0
inet6 2001:db8:10::50 prefixlen 64
up
```

##### Archivo: `/etc/ifconfig.vlan20`
```text
create
vlan 20 vlandev agr0
inet 10.20.0.50 netmask 255.255.255.0
up
```

---

### 4. Comandos de CLI Reales y Salidas Esperadas de la Terminal

#### 4.1 Inspección y Manipulación de Interfaces (`ifconfig`)

##### Comando: Mostrar el Estado Detallado de la Interfaz y Agregación
```console
$ ifconfig lagg0
```
##### Salida Esperada (FreeBSD):
```text
lagg0: flags=8843<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST> metric 0 mtu 1500
	options=80000<LINKSTATE>
	ether 52:54:00:fa:9b:11
	laggproto lacp lagghash l2,l3,l4
	laggport: ix0 flags=1c<ACTIVE,COLLECTING,DISTRIBUTING>
	laggport: ix1 flags=1c<ACTIVE,COLLECTING,DISTRIBUTING>
	groups: lagg
	media: Ethernet autoselect
	status: active
```

##### Comando: Asignar Dirección IPv4 y Alias de Forma Efímera
```console
# ifconfig vlan10 inet 192.168.10.75 netmask 255.255.255.0 alias
$ ifconfig vlan10
```
##### Salida Esperada:
```text
vlan10: flags=8843<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST> metric 0 mtu 1500
	options=3<RXCSUM,TXCSUM>
	ether 52:54:00:fa:9b:11
	inet 192.168.10.50 netmask 0ffffff00 broadcast 192.168.10.255
	inet 192.168.10.75 netmask 0ffffff00 broadcast 192.168.10.255
	inet6 fe80::5054:ff:fefa:9b11%vlan10 prefixlen 64 scopeid 0x5
	inet6 2001:db8:10::50 prefixlen 64
	vlan: 10 vlandev: lagg0
	groups: vlan
	media: Ethernet autoselect
	status: active
```

##### Comando: Eliminar Alias de Forma Efímera
```console
# ifconfig vlan10 inet 192.168.10.75 -alias
```

---

#### 4.2 Operaciones de la Tabla de Enrutamiento (`route` & `netstat`)

##### Comando: Consultar Tabla de Enrutamiento IPv4 Activa
```console
$ netstat -rn -f inet
```
##### Salida Esperada:
```text
Routing tables

Internet:
Destination        Gateway            Flags     Netif Expire
default            192.168.10.1       UGS      vlan10
10.20.0.0/24       link#6             UC       vlan20      -
10.20.0.1          52:54:00:12:34:56  UHLW     vlan20   1198
127.0.0.1          link#1             UH          lo0
172.16.0.0/12      10.20.0.1          UGS      vlan20
192.168.10.0/24    link#5             UC       vlan10      -
192.168.10.50      link#5             UHS         lo0
```

##### Comando: Consultar Tabla de Enrutamiento IPv6 Activa
```console
$ netstat -rn -f inet6
```
##### Salida Esperada:
```text
Routing tables (IPv6):
Destination                       Gateway                         Flags     Netif Expire
::/0                              2001:db8:10::1                  UGS      vlan10
::1                               link#1                          UHS         lo0
2001:db8:10::/64                  link#5                          U        vlan10
2001:db8:10::50                   link#5                          UHS         lo0
fe80::%lo0/64                     link#1                          U           lo0
```

##### Comando: Agregar Ruta Efímera Estática y Verificar Trayectoria
```console
# route add -net 10.50.0.0/16 10.20.0.1
```
##### Salida Esperada:
```text
add net 10.50.0.0: gateway 10.20.0.1
```

##### Comando: Realizar Búsqueda de Ruta para un Objetivo IP Específico
```console
$ route -n get 10.50.4.12
```
##### Salida Esperada:
```text
   route to: 10.50.4.12
destination: 10.50.0.0
    mask: 255.255.0.0
    gateway: 10.20.0.1
    fib: 0
  interface: vlan20
  flags: <UP,GATEWAY,DONE,STATIC>
 recvpipe  sendpipe  ssthresh  rtt,msec    mtu        weight    expire
       0         0         0         0      1500         0         0
```

##### Comando: Eliminar Ruta Efímera
```console
# route delete -net 10.50.0.0/16
```
##### Salida Esperada:
```text
delete net 10.50.0.0
```

---

#### 4.3 Inspección de Sockets y Conexiones Abiertas (`sockstat` / `netstat`)

##### Comando: Mostrar Sockets en Escucha con Asociación de Procesos (FreeBSD)
```console
$ sockstat -4 -6 -l
```
##### Salida Esperada:
```text
USER     COMMAND    PID   FD PROTO  LOCAL ADDRESS         FOREIGN ADDRESS      
root     sshd       1420  4  tcp4   *:22                  *:*
root     sshd       1420  5  tcp6   *:22                  *:*
bind     named      1105  20 tcp4   192.168.10.50:53      *:*
bind     named      1105  21 udp4   192.168.10.50:53      *:*
root     ntpd       890   16 udp4   *:123                 *:*
```

##### Comando: Inspección de Sockets Activos en OpenBSD (`netstat`)
```console
$ netstat -na -f inet | grep LISTEN
```
##### Salida Esperada:
```text
tcp          0      0  *.22                   *.*                    LISTEN
tcp          0      0  192.168.10.50.53       *.*                    LISTEN
```

---

#### 4.4 Resolución DNS y Diagnóstico (`drill` / `dig`)

##### Comando: Realizar Búsqueda DNS Directa Usando la Herramienta de Resolución del Sistema (`drill` - Estándar en FreeBSD)
```console
$ drill -TD freebsd.org
```
##### Salida Esperada:
```text
;; ->>HEADER<<- opcode: QUERY, rcode: NOERROR, id: 48291
;; flags: qr rd ra ; QUERY: 1, ANSWER: 2, AUTHORITY: 0, ADDITIONAL: 0
;; QUESTION SECTION:
;; freebsd.org.	IN	A

;; ANSWER SECTION:
freebsd.org.	300	IN	A	96.47.72.84
freebsd.org.	300	IN	A	147.28.184.45

;; Query time: 24 msec
;; SERVER: 192.168.10.2
;; WHEN: Thu Aug  6 20:51:54 2026
;; MSG SIZE rcvd: 61
```

---

### 5. Guía de Solución de Problemas y Verificación

```
                         [ Network Incident Reported ]
                                       |
                                       v
                    +------------------------------------+
                    | Layer 1 / Layer 2 Physical Check   |
                    | command: ifconfig -a               |
                    +------------------+-----------------+
                                       |
                   Is Link Status "active" & Up?
                   /                               \
               [NO]                                 [YES]
                /                                     \
    +-----------------------+              +--------------------------+
    | Check Physical Cable, |              | Check 802.1Q VLAN / LACP |
    | Transceiver, Switch   |              | status: ifconfig lagg0   |
    | Port, SFP Status      |              +------------+-------------+
    +-----------------------+                           |
                                            Are LACP ports COLLECTING?
                                            /                        \
                                        [NO]                          [YES]
                                         /                              \
                           +------------------------+      +-------------------------+
                           | Fix Switch LACP Mode   |      | Layer 3 IP Check        |
                           | (Active vs Passive)    |      | command: ping -c 3 IP   |
                           +------------------------+      +------------+------------+
                                                                        |
                                                           Can ping Local Gateway?
                                                           /                     \
                                                       [NO]                       [YES]
                                                        /                           \
                                          +--------------------------+    +-----------------------+
                                          | Verify IP, Subnet Mask,  |    | Check Routing Table   |
                                          | and VLAN Tag ID match    |    | command: netstat -rn  |
                                          +--------------------------+    +-----------+-----------+
                                                                                      |
                                                                          Is Default Route Present?
                                                                          /                       \
                                                                      [NO]                         [YES]
                                                                       /                             \
                                                         +--------------------------+   +---------------------------+
                                                         | Fix defaultrouter in     |   | Check Firewall / Pf /     |
                                                         | /etc/rc.conf or mygate   |   | DNS Resolution            |
                                                         +--------------------------+   | command: drill @DNS host  |
                                                                                        +---------------------------+
```

#### 5.1 Escenarios Comunes de Fallos en Producción y Soluciones

##### Escenario A: Agregado LACP Atascado en `DOWN` o Estado de Enlace Parcial
- **Síntoma**: `ifconfig lagg0` muestra estado `no carrier` o al estado de `laggport` le faltan las flags `COLLECTING`/`DISTRIBUTING`.
- **Causa Raíz**: Desajuste en el temporizador de transmisión de tramas LACP (fast vs. slow) o el lado del switch está configurado en modo trunk estático en lugar de LACP dinámico (`lacpmode active`).
- **Comando de Diagnóstico**:
  ```console
  $ ifconfig -v lagg0
  ```
- **Remediación**:
  Asegurar que los puertos del lado del switch estén configurados en LACP activo. En FreeBSD, verificar que `lagghash` coincida con los requisitos de la arquitectura del sistema:
  ```console
  # ifconfig lagg0 laggproto lacp lagghash l2,l3,l4
  ```

##### Escenario B: Fallo en la Detección de Direcciones Duplicadas (DAD) de IPv6
- **Síntoma**: `ifconfig vlan10` muestra la dirección IPv6 marcada como `DUPLICATED` o `TENTATIVE`.
- **Causa Raíz**: Conflicto de dirección MAC de Ethernet en las interfaces subyacentes, o el switch está devolviendo los paquetes de Neighbor Solicitation (NS) ICMPv6 multicast a la interfaz del host.
- **Comando de Diagnóstico**:
  ```console
  $ dmesg | grep DAD
  ```
  *Salida*: `vlan10: DAD complete, duplicate address 2001:db8:10::50 found!`
- **Remediación**:
  Instanciar direcciones MAC únicas explícitas en la interfaz virtual o ajustar la asignación estática del nodo:
  ```console
  # ifconfig vlan10 link 52:54:00:ab:cd:99
  ```

##### Escenario C: Cambios Efímeros Perdidos Después del Reinicio
- **Síntoma**: Las rutas estáticas o adiciones de IP en interfaces desaparecen tras un reinicio de mantenimiento del host.
- **Causa Raíz**: Cambios ejecutados a través de `ifconfig` o `route add` directamente en la terminal sin añadir directivas a `/etc/rc.conf` (FreeBSD/NetBSD) o `/etc/hostname.<if>` (OpenBSD).
- **Regla de Verificación**:
  Validar siempre la sintaxis de los archivos persistentes.
  - **FreeBSD**: Ejecutar inspección rc en modo simulación (dry-run):
    ```console
    $ service netif restart --dryrun
    ```
  - **OpenBSD**: Comprobar sintaxis invocando `/etc/netstart` en modo depuración (debug):
    ```console
    # sh -x /etc/netstart vlan10
    ```

---

#### 5.2 Hoja de Referencia (Cheat Sheet) de Herramientas de Diagnóstico

1. **Captura de Paquetes en una Interfaz Específica**:
   ```console
   # tcpdump -nni vlan10 -c 10 'icmp or icmp6'
   ```
2. **Rastrear la Ruta hacia un Destino Remoto**:
   ```console
   $ traceroute -n 8.8.8.8
   $ traceroute6 -n 2001:4860:4860::8888
   ```
3. **Verificar Tabla ARP (Resolución MAC de IPv4)**:
   ```console
   $ arp -an
   ```
4. **Verificar Tabla NDP (Protocolo Neighbor Discovery de IPv6)**:
   ```console
   $ ndp -an
   ```

---

### 6. Referencias

- **Linux Professional Institute (LPI) BSD Specialist Official Overview**:
  https://www.lpi.org/our-certifications/bsd-specialist-overview/
- **FreeBSD Handbook - Chapter 33: Network Configuration**:
  https://docs.freebsd.org/en/books/handbook/network/
- **FreeBSD Manual Pages - `ifconfig(8)`**:
  https://man.freebsd.org/cgi/man.cgi?query=ifconfig&sektion=8
- **FreeBSD Manual Pages - `lagg(4)`**:
  https://man.freebsd.org/cgi/man.cgi?query=lagg&sektion=4
- **OpenBSD FAQ - Network Configuration**:
  https://www.openbsd.org/faq/faq6.html
- **OpenBSD Manual Pages - `hostname.if(5)`**:
  https://man.openbsd.org/hostname.if.5
- **NetBSD Documentation - Network Configuration**:
  https://www.netbsd.org/docs/guide/en/chap-netconn.html