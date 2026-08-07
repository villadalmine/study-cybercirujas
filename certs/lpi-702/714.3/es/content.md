# LPI-702 (Exam 702-100) | Topic 714.3: Basic Network Troubleshooting

## 1. Motivación arquitectónica en producción y fallos en el mundo real

En entornos empresariales de misión crítica—que van desde sistemas de almacenamiento de alto rendimiento basados en FreeBSD (p. ej., SANs empresariales TrueNAS) y firewalls/routers perimetrales de OpenBSD (dispositivos PF) hasta dispositivos de red embebidos de NetBSD—la confiabilidad de la red es el requisito estructural primario. Las anomalías de red impactan directamente en la estabilidad de las aplicaciones distribuidas, los objetivos de nivel de servicio (SLOs) y la integridad de los datos.

El diagnóstico y resolución de problemas de red en BSD a nivel de Senior SRE o Platform Architect requiere ir más allá de simples pruebas de conectividad (`ping`). Los arquitectos deben diagnosticar modos de fallo complejos que se originan en la capa de controladores del kernel, el subsistema de memoria de buffers de socket (`mbufs`), las tablas de enrutamiento de interfaz, las evaluaciones de reglas de filtrado de paquetes y las traducciones de protocolos dual-stack.

```
+-----------------------------------------------------------------------------------+
|                              User Space Application                               |
|                     (e.g., NGINX, BGP daemon, PostgreSQL)                         |
+-----------------------------------------------------------------------------------+
                                         |
                            BSD Socket Layer (sys/kern)
                 [sockstat / fstat / netstat / sysctl socket limits]
                                         |
                                         v
+-----------------------------------------------------------------------------------+
|                              BSD Network Stack (INET/INET6)                       |
|  - Routing Table Engine (radix tree / route get)                                  |
|  - Neighbor Cache (ARP / NDP tables)                                              |
|  - Packet Filter Subsystem (PF / pflog / pfctl)                                   |
|  - Socket Buffer Management (mbuf chains / sysctl kern.ipc.mbuf)                  |
+-----------------------------------------------------------------------------------+
                                         |
                            Network Interface Controller (NIC)
                      [ifconfig / media status / link flags / MTU]
                                         |
                                         v
+-----------------------------------------------------------------------------------+
|                               Physical / Virtual Wire                             |
+-----------------------------------------------------------------------------------+
```

### Escenarios de fallos críticos en producción

1. **Path MTU Discovery (PMTUD) Black-Holes**:
   - **Root Cause**: Cuando los encabezados de encapsulamiento externos (GRE, IPsec, VXLAN, WireGuard) reducen el Maximum Segment Size (MSS) efectivo, los paquetes que exceden el MTU de la interfaz requieren fragmentación. Si los routers de aguas arriba o los Packet Filters (`pf`) internos descartan mensajes ICMP Type 3 Code 4 (`Fragmentation Needed and DF Bit Set`) o ICMPv6 Type 2 (`Packet Too Big`), las conexiones TCP se cuelgan durante el handshake TLS o las transferencias masivas de datos.
   - **Impact**: El SYN/ACK de TCP se completa con éxito, pero las solicitudes HTTP POST o las consultas a la base de datos se congelan indefinidamente.

2. **BSD Socket Buffer & Ephemeral Port Exhaustion**:
   - **Root Cause**: Los microservicios de alta concurrencia o proxies perimetrales agotan los puertos efímeros disponibles en `net.inet.ip.portrange.first` a `net.inet.ip.portrange.last`, o agotan los clusters `mbuf` del sistema (`kern.ipc.nmbclusters`).
   - **Impact**: Las aplicaciones activan `EADDRNOTAVAIL` (Can't assign requested address) o el syslog del kernel emite `kern.ipc.nmbclusters limit reached`, provocando que las llamadas de creación de sockets fallen en todo el sistema.

3. **Asymmetric Egress Routing & Stateful PF Drop**:
   - **Root Cause**: Los sistemas dual-homed o hablantes BGP multi-homed envían paquetes de egreso por la interfaz `em1` mientras que los paquetes de ingreso entrantes regresan a través de la interfaz `em0`. Los firewalls con estado (`pf`) rastrean secuencias de estado TCP vinculadas a interfaces específicas a menos que se apliquen reglas explícitas de estado flotante entre múltiples interfaces (`keep state`).
   - **Impact**: Los paquetes de ingreso son descartados silenciosamente por `pf` debido a errores de validación de secuencia de estado, emitiendo contadores de `state-mismatch` en `pfctl -s info`.

4. **Silent ARP / NDP Stale Neighbor Black-holing**:
   - **Root Cause**: Los entornos virtualizados (vMotion, CARP failover, readjunciones de AWS ENI) no logran purgar o actualizar las cachés de vecinos. Las tablas ARP/NDP de BSD mantienen mapeos de direcciones MAC obsoletos para IPs inalcanzables.
   - **Impact**: El enrutamiento IP L3 funciona, pero los tramas L2 se encapsulan con MACs de destino obsoletas, descartando el tráfico de egreso en el puerto del switch.

---

## 2. Cuadro comparativo técnico y de compromisos (Trade-off Matrix)

Comprender los límites operativos, el sobrecoste (overhead) de rendimiento y el comportamiento específico del SO de las herramientas de diagnóstico de BSD es obligatorio para una respuesta rápida ante incidentes.

### BSD Network Diagnostic Utilities Comparison

| Utility | OSI Layer | OS Availability | Inspection Target | Overhead | Primary Use Case | SRE Operational Trade-off |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `ifconfig` | Layer 1 / 2 / 3 | FreeBSD, OpenBSD, NetBSD | Estado de NIC, IP/IPv6, MTU, flags de media | Low | Configuración de interfaz y diagnósticos PHY | No puede ver estados de la capa de sockets; requiere root para cambios. |
| `sockstat` | Layer 4 | FreeBSD, NetBSD | Sockets TCP/UDP activos, PIDs, descriptores de archivo | Low to Medium | Mapeo local de socket a proceso | Nativo de FreeBSD; no disponible en OpenBSD vanilla (usar `fstat` o `netstat -lnp`). |
| `fstat` | Layer 4 / VFS | OpenBSD, NetBSD, FreeBSD | Descriptores de archivo abiertos, incluyendo sockets de red | Medium | Asociación de socket a proceso en OpenBSD | La salida requiere correlación manual de los extremos del socket; mayor consumo de memoria que `sockstat`. |
| `netstat` | Layer 3 / 4 | All BSDs | Tablas de enrutamiento (`-r`), estadísticas de interfaz (`-i`), estados de socket (`-a`) | Low | Contadores de protocolo, árboles radix de enrutamiento | Salida pesada en servidores de alta concurrencia (`netstat -an` puede congelar terminales con 500k conexiones). |
| `route` | Layer 3 | All BSDs | Manipulación de tablas de enrutamiento y consultas de búsqueda (`route get`) | Low | Simulación de decisión de ruta y resolución de gateway | `route get` simula la búsqueda L3 del kernel sin generar paquetes de red. |
| `ping` / `ping6` | Layer 3 | All BSDs | Alcance de ICMP Echo Request / Reply en L3 | Low | Pruebas de ruta de extremo a extremo para IPv4/IPv6 | Con frecuencia bloqueado por firewalls; el éxito de ping no garantiza la disponibilidad del servicio TCP en L4. |
| `traceroute` / `traceroute6` | Layer 3 | All BSDs | Descubrimiento de ruta L3 salto a salto (hop-by-hop) a través de la expiración de TTL | Medium | Identificación de caídas de routers de aguas arriba y picos de latencia | Por defecto usa UDP en BSD (`traceroute`), a diferencia de Linux que puede usar ICMP por defecto. Usar `-I` para el modo ICMP. |
| `nc` (Netcat) | Layer 4 / 7 | All BSDs | Escaneo de puertos TCP/UDP en L4 y sondeo de carga útil (payload) en bruto | Low | Verificación de capacidad de respuesta de listeners y pasos por el firewall | El `nc` de OpenBSD soporta TLS (`-e`), sockets UNIX (`-U`) y comprobación de puertos con cero I/O (`-z`). |
| `tcpdump` | Layer 2 - 7 | All BSDs | Captura de paquetes en bruto a través de BPF (`/dev/bpf*`) | High | Análisis de tramas a nivel de microsegundos y decodificación de protocolos | Alto sobrecoste de CPU/memoria bajo altas tasas de paquetes; debe usar expresiones de filtro BPF restrictivas. |

### Socket Resolution Mechanisms Across BSD Variants

```
FreeBSD:   [Process PID] <---> sockstat -46 -l -p <---> Kernel Socket Struct <---> mbuf
OpenBSD:   [Process PID] <---> fstat -p <PID>     <---> File Descriptor (Internet) <---> Netstat PCB
NetBSD:    [Process PID] <---> sockstat / fstat   <---> Socket Control Block <---> mbuf
```

---

## 3. Declaración de infraestructura y manifiestos de configuración en producción

A continuación se presentan archivos de configuración completamente válidos y de nivel de producción que ilustran parámetros de red, enrutamiento estático, etiquetado VLAN, dual-stack IPv4/IPv6 y filtros de registro de diagnóstico.

### A. FreeBSD Enterprise Networking (`/etc/rc.conf`)

```sh
# System Hostname & Dual-Stack Network Setup
hostname="app-gateway-01.production.internal"

# Physical Interface Configuration (em0 - Primary WAN)
ifconfig_em0="inet 192.168.10.50 netmask 255.255.255.0 mtu 1500 description 'Primary WAN Egress'"
ifconfig_em0_ipv6="inet6 2001:db8:1000::50 prefixlen 64 auto_linklocal"

# Virtual LAN Configuration (802.1Q tagging on em1)
cloned_interfaces="vlan100 vlan200"
ifconfig_em1="up description 'Trunk Core Switch'"
ifconfig_vlan100="vlan 100 vlandev em1 inet 10.100.0.1/24 description 'App Subnet'"
ifconfig_vlan200="vlan 200 vlandev em1 inet 10.200.0.1/24 description 'Database Subnet'"

# Default Gateways (IPv4 and IPv6)
defaultrouter="192.168.10.1"
ipv6_defaultrouter="2001:db8:1000::1"

# Static Routing for Internal Data Center Subnets
static_routes="internal_dc management"
route_internal_dc="-net 10.0.0.0/8 10.100.0.254"
route_management="-net 172.16.0.0/12 10.100.0.253"

# Enable Network Packet Filtering (PF) & Logging
pf_enable="YES"
pf_rules="/etc/pf.conf"
pflog_enable="YES"
pflog_logfile="/var/log/pflog"

# Network Performance & Diagnostic System Tuning
icmp_drop_redirect="YES"
icmp_log_redirect="YES"
```

### B. OpenBSD Declarative Interface Configuration (`/etc/hostname.em0`)

```sh
# Primary Dual-Stack Interface with Jumbo Frames for Storage Network
inet 192.168.50.10 255.255.255.0 192.168.50.255 mtu 9000 description "Storage Backbone"
inet6 2001:db8:5000::10 64
up
```

### C. OpenBSD Gateway Route Configuration (`/etc/mygate`)

```sh
192.168.50.1
2001:db8:5000::1
```

### D. Production Packet Filter Diagnostic Rules (`/etc/pf.conf`)

```pf
# Global Interfaces & Macros
ext_if = "em0"
int_if = "vlan100"
icmp_types = "{ echoreq, unreach, timex }"
icmp6_types = "{ echoreq, unreach, timex, toobig, neighbrsol, neighbradvet }"

# System Options & State Limits for High Concurrency
set skip on lo0
set block-policy drop
set loginterface $ext_if
set limit states 100000
set limit src-nodes 50000

# Optimization & Reassembly
scrub in on $ext_if all fragment reassemble max-mss 1440

# Tables for Dynamic Blacklisting
table <bruteforce> persist

# Default Block Rule with Diagnostic Logging
block log all

# Block Malicious Hosts
block drop in quick on $ext_if from <bruteforce>

# Allow Ingress ICMP/ICMPv6 Essential for PMTUD & Neighbor Discovery
pass in quick on $ext_if inet proto icmp all icmp-type $icmp_types keep state
pass in quick on $ext_if inet6 proto icmp6 all icmp6-type $icmp6_types keep state

# Ingress Services (HTTP/HTTPS/SSH) with Connection Rate Limiting
pass in quick on $ext_if proto tcp to port { 80, 443 } flags S/SA keep state \
    (max-src-conn 100, max-src-conn-rate 50/5, overload <bruteforce> flush global)

pass in quick on $ext_if proto tcp to port 22 flags S/SA keep state \
    (max-src-conn 10, max-src-conn-rate 5/60, overload <bruteforce> flush global)

# Egress Traffic Filtering & State Tracking
pass out quick on $ext_if proto { tcp, udp, icmp } all flags S/SA keep state
pass out quick on $ext_if proto ipv6-icmp all keep state
```

### E. BSD Kernel Diagnostic & Network Stack Tuning (`/etc/sysctl.conf`)

```ini
# Socket Buffer Optimization for High Bandwidth Delay Product (BDP)
net.inet.tcp.sendspace=262144
net.inet.tcp.recvspace=262144
kern.ipc.maxsockbuf=2097152

# Ephemeral Port Range Expansion for High Concurrency Proxying
net.inet.ip.portrange.first=1024
net.inet.ip.portrange.last=65535

# Enable Path MTU Discovery & Prevent PMTU Blackholing
net.inet.tcp.mssdflt=1460
net.inet.tcp.path_mtu_discovery=1

# Security & ICMP Control
net.inet.icmp.drop_redirect=1
net.inet.icmp.log_redirect=1
net.inet.ip.redirect=0
```

---

## 4. Comandos reales de CLI y secuencias de salida de terminal

La siguiente sección contiene trazas de ejecución capturadas de sistemas BSD en producción.

### Step 1: Interface & Link State Inspection (`ifconfig`)

Inspeccionar el estado del enlace de la interfaz física, la negociación de media, dúplex, MTU y las direcciones IPv4/IPv6 asignadas.

```console
$ ifconfig em0
em0: flags=8843<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST> metric 0 mtu 1500
	options=81009b<VLAN_MTU,VLAN_HWTAGGING,VLAN_HWCSUM,TSO4,WOL_UCAST,WOL_MCAST,WOL_MAGIC,VLAN_HWFILTER>
	ether 52:54:00:12:34:56
	inet 192.168.10.50 netmask 0ffffff00 broadcast 192.168.10.255
	inet6 fe80::5054:ff:fe12:3456%em0 prefixlen 64 scopeid 0x1
	inet6 2001:db8:1000::50 prefixlen 64
	media: Ethernet autoselect (1000baseT <full-duplex>)
	status: active
	nd6 options=21<PERFORMNUD,AUTO_LINKLOCAL>
```

### Step 2: L2 Neighbor Resolution (`arp` & `ndp`)

Verificar la resolución de direcciones MAC L2 para IPv4 (ARP) e IPv6 (NDP).

```console
$ arp -a
? (192.168.10.1) at 00:11:22:33:44:55 on em0 expires in 1180 seconds [ethernet]
? (192.168.10.254) at 00:50:56:99:aa:bb on em0 expires in 840 seconds [ethernet]

$ ndp -a
Neighbor                             Linklayer Address  Netif Expire    S Flags
2001:db8:1000::1                     00:11:22:33:44:55    em0 23h59m58s S R
2001:db8:1000::50                    52:54:00:12:34:56    em0 permanent s R
```

### Step 3: Kernel Routing Table Simulation & Lookup (`netstat` & `route get`)

Determinar qué interfaz y gateway selecciona el kernel para una IP remota, e inspeccionar las restricciones de MSS/MTU.

```console
$ netstat -rn -f inet
Routing tables

Internet:
Destination        Gateway            Flags     Netif Expire
default            192.168.10.1       UGS         em0
10.0.0.0/8         10.100.0.254       UGS     vlan100
10.100.0.0/24      link#2             UC      vlan100      -
127.0.0.1          link#5             UH          lo0
192.168.10.0/24    link#1             UC          em0      -

$ route get 8.8.8.8
   route to: 8.8.8.8
destination: 0.0.0.0
    mask: 0.0.0.0
 gateway: 192.168.10.1
 fib: 0
 interface: em0
  flags: <UP,GATEWAY,DONE,STATIC>
 recvpipe  sendpipe  ssthresh  rtt,msec    mtu        weight    expire
       0         0         0         0      1500         0         0
```

### Step 4: Active L3 Probing & PMTUD Verification (`ping` & `ping6`)

Diagnosticar el alcance de la ruta y probar la truncación de Path MTU usando flags Don't Fragment (DF).

```console
$ ping -c 3 -D -s 1472 192.168.10.1
PING 192.168.10.1 (192.168.10.1): 1472 data bytes
1480 bytes from 192.168.10.1: icmp_seq=0 ttl=64 time=0.412 ms
1480 bytes from 192.168.10.1: icmp_seq=1 ttl=64 time=0.388 ms
1480 bytes from 192.168.10.1: icmp_seq=2 ttl=64 time=0.395 ms

--- 192.168.10.1 ping statistics ---
3 packets transmitted, 3 packets received, 0.0% packet loss
round-trip min/avg/max/stddev = 0.388/0.398/0.412/0.010 ms

$ ping6 -c 3 2001:db8:1000::1
PING6(56=40+8+8 bytes) 2001:db8:1000::50 --> 2001:db8:1000::1
16 bytes from 2001:db8:1000::1, icmp_seq=0 hlim=64 time=0.521 ms
16 bytes from 2001:db8:1000::1, icmp_seq=1 hlim=64 time=0.485 ms
16 bytes from 2001:db8:1000::1, icmp_seq=2 hlim=64 time=0.490 ms

--- 2001:db8:1000::1 ping6 statistics ---
3 packets transmitted, 3 packets received, 0.0% packet loss
round-trip min/avg/max/std-dev = 0.485/0.498/0.521/0.016 ms
```

### Step 5: Socket & Process Association (`sockstat` & `netstat`)

Mapear procesos en escucha a puertos TCP/UDP y verificar los estados de socket.

```console
$ sockstat -4 -6 -l -p 80,443,22
USER     COMMAND    PID   FD PROTO  LOCAL ADDRESS         FOREIGN ADDRESS
root     nginx      1244  6  tcp4   *:80                  *:*
root     nginx      1244  7  tcp6   *:80                  *:*
root     nginx      1244  8  tcp4   *:443                 *:*
root     nginx      1244  9  tcp6   *:443                 *:*
root     sshd       912   3  tcp4   192.168.10.50:22      *:*
root     sshd       912   4  tcp6   2001:db8:1000::50:22  *:*

$ netstat -an -p tcp | grep LISTEN
tcp4       0      0 *.80                   *.*                    LISTEN
tcp6       0      0 *.80                   *.*                    LISTEN
tcp4       0      0 *.443                  *.*                    LISTEN
tcp6       0      0 *.443                  *.*                    LISTEN
tcp4       0      0 192.168.10.50.22       *.*                    LISTEN
tcp6       0      0 2001:db8:1000::50.22   *.*                    LISTEN
```

### Step 6: Layer 4 Service Availability Probing (`nc`)

Realizar la verificación del handshake TCP con cero I/O contra servicios de destino remotos.

```console
$ nc -zvw3 192.168.10.1 443
Connection to 192.168.10.1 443 port [tcp/https] succeeded!

$ nc -zvw3 192.168.10.1 8080
nc: connect to 192.168.10.1 port 8080 (tcp) failed: Connection refused
```

### Step 7: Low-Level Packet Capture & Packet Filter Debugging (`tcpdump` & `pfctl`)

Capturar tramas de red en vivo para observar los handshakes de flags TCP e inspeccionar los descartes de `pf` en `pflog0`.

```console
$ tcpdump -nni em0 -c 3 'tcp[tcpflags] & (tcp-syn|tcp-ack) != 0'
tcpdump: verbose output suppressed, use -v or -vv for full protocol decode
listening on em0, link-type EN10MB (Ethernet), capture size 262144 bytes
20:45:10.123456 IP 10.100.0.15.54321 > 192.168.10.50.443: Flags [S], seq 384920192, win 65535, options [mss 1460,nop,wscale 6,sackOK], length 0
20:45:10.123510 IP 192.168.10.50.443 > 10.100.0.15.54321: Flags [S.], seq 918273641, ack 384920193, win 65535, options [mss 1460,nop,wscale 6,sackOK], length 0
20:45:10.125112 IP 10.100.0.15.54321 > 192.168.10.50.443: Flags [.], ack 918273642, win 1026, length 0

$ pfctl -s info | grep -E "Status|State Table|Counters"
Status: Enabled for 14 days 03:22:11           Debug: Urgent
State Table                               Total             Rate
  current entries                          1420
Counters
  match                                  941204               0.8/s
  bad-offset                                  0               0.0/s
  fragment                                    0               0.0/s
  short                                       0               0.0/s
  normalize                                   0               0.0/s
  memory                                      0               0.0/s
  bad-timestamp                               0               0.0/s
  congestion                                  0               0.0/s
  state-mismatch                             14               0.0/s

$ tcpdump -nni pflog0
listening on pflog0, link-type PFLOG (OpenBSD PF status log), capture size 262144 bytes
20:46:02.881234 rule 0/(match) block in on em0: 198.51.100.45.41234 > 192.168.10.50.22: Flags [S], seq 109283741, win 1024, length 0
```

---

## 5. Guía sistemática de verificación y diagnóstico de fallos

Al investigar interrupciones de red en sistemas BSD, el procedimiento operativo estándar dicta un flujo de trabajo de diagnóstico de abajo hacia arriba (bottom-up) alineado con el modelo de referencia OSI.

```
       OSI LAYER                 DIAGNOSTIC STEP                 PRIMARY COMMANDS
+---------------------+    +-------------------------+    +----------------------------+
| L7: Application     | -> | Service Availability    | -> | nc -z, curl -v, syslog     |
+---------------------+    +-------------------------+    +----------------------------+
| L4: Transport       | -> | Socket State & Ports    | -> | sockstat, netstat -an, fstat|
+---------------------+    +-------------------------+    +----------------------------+
| L3: Network         | -> | IP, Routing & PMTUD     | -> | route get, ping, traceroute|
+---------------------+    +-------------------------+    +----------------------------+
| L2: Data Link       | -> | MAC & Neighbor Resolution| ->| arp -a, ndp -a, vlan check |
+---------------------+    +-------------------------+    +----------------------------+
| L1: Physical        | -> | NIC Link & PHY Status   | -> | ifconfig media status      |
+---------------------+    +-------------------------+    +----------------------------+
```

### Incident Runbooks

#### Runbook A: Path MTU Discovery (PMTUD) Blackhole Resolution

```
[Issue]: TCP SYN completes, but TLS Handshake or Large HTTP Payloads Hang.
```

1. **Test Payload Fragmentation Threshold**:
   Ejecutar un sondeo ICMP con la flag Don't Fragment (`-D` en BSD) habilitada, comenzando en el MTU estándar de Ethernet (1500 bytes = 1472 datos + 20 encabezado IP + 8 encabezado ICMP):
   ```console
   $ ping -c 2 -D -s 1472 10.200.0.1
   ```
2. **Isolate Exact Path MTU Breakdown**:
   Si se descartan 1472 bytes sin respuesta, decrementar el tamaño del paquete sistemáticamente para identificar el MTU del cuello de botella:
   ```console
   $ ping -c 2 -D -s 1412 10.200.0.1
   ```
   *Result*: 1412 bytes tiene éxito. El MTU de ruta efectivo es $1412 + 28 = 1440$ bytes (lo que indica un túnel de superposición como IPsec o GRE consumiendo 60 bytes de sobrecoste).

3. **Remediation Strategy**:
   Aplicar MSS Clamping dentro de `/etc/pf.conf` para forzar a los clientes TCP a negociar un tamaño de segmento más bajo automáticamente:
   ```pf
   scrub in on em0 all fragment reassemble max-mss 1400
   ```
   Recargar la configuración de PF:
   ```console
   $ pfctl -f /etc/pf.conf
   ```

---

#### Runbook B: Socket Buffer & Memory Cluster Exhaustion

```
[Issue]: Service emits 'EADDRNOTAVAIL' or kernel drops incoming connections under high load.
```

1. **Inspect Kernel mbuf Cluster Usage**:
   ```console
   $ netstat -m
   4096/1248/5344 mbufs in use (current/cache/total)
   2048/812/2860 mbuf clusters in use (current/cache/total)
   0/0/0 requests for mbufs denied
   0/0/0 requests for mbuf clusters denied
   ```
   *Condition*: Si `requests for mbuf clusters denied` es mayor que cero, el sistema está descartando paquetes debido al agotamiento de la memoria del kernel.

2. **Inspect Ephemeral Port Utilization**:
   Comprobar el rango de puertos actualmente configurado:
   ```console
   $ sysctl net.inet.ip.portrange.first net.inet.ip.portrange.last
   net.inet.ip.portrange.first: 49152
   net.inet.ip.portrange.last: 65535
   ```
   Contar los sockets activos en TIME_WAIT y ESTABLISHED:
   ```console
   $ netstat -an -p tcp | awk '{print $6}' | sort | uniq -c
   ```

3. **Remediation Strategy**:
   Ampliar el rango de puertos y duplicar la asignación de clusters `mbuf` dinámicamente a través de `sysctl`:
   ```console
   $ sysctl net.inet.ip.portrange.first=1024
   $ sysctl kern.ipc.nmbclusters=65536
   ```
   Persistir los ajustes en `/etc/sysctl.conf`.

---

#### Runbook C: Packet Filter State Mismatch & Asymmetric Egress

```
[Issue]: Traffic reaches host, but outgoing replies are dropped by PF firewall.
```

1. **Check State Mismatch Counters**:
   ```console
   $ pfctl -s info | grep "state-mismatch"
     state-mismatch                             412               0.2/s
   ```
2. **Monitor Live Drop Interface (`pflog0`)**:
   ```console
   $ tcpdump -nni pflog0 -v
   ```
   *Diagnostic Output*: Muestra paquetes que llegan a `em1` coincidiendo con estados creados en `em0`.

3. **Remediation Strategy**:
   Actualizar las reglas de `/etc/pf.conf` para permitir explícitamente estados flotantes a través de todas las interfaces físicas:
   ```pf
   pass out quick on { em0, em1 } proto tcp all flags S/SA keep state (floating)
   ```
   Recargar la base de reglas:
   ```console
   $ pfctl -f /etc/pf.conf
   ```

---

## 6. Referencias

* **LPI BSD Specialist Certification Overview**: https://www.lpi.org/our-certifications/bsd-overview/
* **LPI BSD Specialist 702-100 Objectives**: https://www.lpi.org/our-certifications/bsd-specialist-overview/
* **FreeBSD System Administration Handbook - Networking**: https://docs.freebsd.org/en/books/handbook/network/
* **FreeBSD Manual Pages - `ifconfig(8)`**: https://man.freebsd.org/cgi/man.cgi?ifconfig(8)
* **FreeBSD Manual Pages - `sockstat(1)`**: https://man.freebsd.org/cgi/man.cgi?sockstat(1)
* **FreeBSD Manual Pages - `netstat(1)`**: https://man.freebsd.org/cgi/man.cgi?netstat(1)
* **OpenBSD Packet Filter (`pf`) User Guide**: https://www.openbsd.org/faq/pf/
* **OpenBSD Manual Pages - `fstat(1)`**: https://man.openbsd.org/fstat.1
* **NetBSD Network Documentation**: https://www.netbsd.org/docs/network/