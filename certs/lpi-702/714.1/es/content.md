# LPI-702 (Exam 702-100) | Topic 714.1: Fundamentos de los Protocolos de Internet

**Ponderación:** 3.33  
**Perfil Objetivo:** Arquitecto Principal de Plataformas / Ingeniero Senior de Confiabilidad de Sitios (SRE)  
**Objetivos del Examen Cubiertos:** Arquitectura de direccionamiento IPv4/IPv6, matemática de subredes, conversiones de máscaras CIDR/Decimal Punteada/Hexadecimal, cálculos de rango de host y broadcast, mecánica de protocolos L3/L4 e integración del stack IP a nivel de sistema en FreeBSD.

---

## 1. Motivación Arquitectónica de Producción & Declaración del Problema

En la ingeniería de plataformas empresariales e infraestructura nativa de la nube, la capa IP es el sustrato fundamental para el enrutamiento de tráfico, segmentación de seguridad e aislamiento de service mesh. Los entornos de producción modernos despliegan arquitecturas híbridas donde routers de borde FreeBSD, gateways de seguridad (usando `pf`) y nodos Linux/Kubernetes interactúan sobre asignaciones IPv4 CIDR complejas y redes IPv6 Dual-Stack.

```
                     +-------------------------------------------------------+
                     |                IPv4 / IPv6 Ingress Router             |
                     |       FreeBSD 14.1 (pf / BGP / Dual-Stack IPAM)        |
                     +-------------------------------------------------------+
                                        /                 \
            IPv4: 192.168.10.0/24 (0xffffff00)      IPv6: 2001:db8:abc1::/64
           Broadcast: 192.168.10.255                Gateway: 2001:db8:abc1::1
                                      /                     \
                   +-----------------------+           +-----------------------+
                   | Kubernetes Worker 01  |           | FreeBSD Storage Node  |
                   | Calico / Cilium CNI   |           | ZFS NFS / iSCSI Host  |
                   | 192.168.10.16/28      |           | 2001:db8:abc1::50/64  |
                   +-----------------------+           +-----------------------+
```

### Alternativas Arquitectónicas y Cuellos de Botella de Producción

1. **Agotamiento de Direcciones IPv4 & Sobrecarga de NAT**
   * **El Problema:** El espacio limitado de direcciones IPv4 de 32 bits (`2^32 ≈ 4.29 mil millones` de direcciones) fuerza a las arquitecturas a una gran dependencia de los espacios privados RFC 1918 combinados con Traducción de Direcciones de Red (NAT/NAPT).
   * **Impacto en Producción:** Las tablas de firewall NAT con estado consumen buffers de memoria (las entradas de estado de BSD `pf` requieren ~400 bytes cada una). Los sistemas de borde de alta concurrencia (por ejemplo, 500,000 conexiones activas) consumen cientos de megabytes de memoria de kernel no paginable únicamente para los estados de traducción. Además, la pérdida de alcanzabilidad IP extremo a extremo inhabilita la telemetría directa peer-to-peer y complica la auditoría de microservicios.

2. **Malas Configuraciones de Subredes & Tormentas de Broadcast**
   * **El Problema:** Calcular mal las máscaras de red (por ejemplo, configurar un host `/23` en un segmento de switch físico `/24`) rompe la resolución local de Capa 2 a través de ARP (Protocolo de Resolución de Direcciones).
   * **Impacto en Producción:** Cuando un host IPv4 calcula mal su dirección de broadcast, descarta frames de un-unicast entrantes o reenvía tráfico destinado a subredes adyacentes al gateway local innecesariamente, induciendo reevaluaciones de búsqueda de enrutamiento de kernel intensivas en CPU a través de árboles `radix` (PATRICIA) de BSD.

3. **Eficiencia del Encabezado IPv4 vs IPv6 & Sobrecarga de Procesamiento**
   * **Encabezado IPv4:** Longitud variable (20 a 60 bytes) debido a campos opcionales. Requiere que los routers recalculen el Checksum del Encabezado IPv4 en cada salto debido al decremento del TTL, agregando latencia de CPU.
   * **Encabezado IPv6:** Longitud fija de 40 bytes. El checksum se elimina en la Capa 3 (confiando en los checksums de Capa 2 y Capa 4). Hop Limit reemplaza a TTL. Las características opcionales se mueven a encadenamiento de *Extension Headers* (por ejemplo, Hop-by-Hop, Enrutamiento, Fragmento, ESP), lo que permite a los routers de tránsito intermedios procesar paquetes enteramente en hardware (ASIC/eBPF/DPDK) sin analizar campos opcionales.

4. **Cambio en Protocolos de Capa 2: ARP vs ICMPv6 Neighbor Discovery (NDP)**
   * **IPv4 ARP:** Se apoya en frames de broadcast (`ff:ff:ff:ff:ff:ff`). En segmentos L2 grandes (por ejemplo, `/22` con 1,022 hosts), las solicitudes ARP generan un ruido severo, despertando la tarjeta de interfaz de red (NIC) de cada host para procesar filtros de paquetes.
   * **IPv6 NDP:** Reemplaza los broadcasts ARP con **Solicited-Node Multicast** (`ff02::1:ffxx:xxxx`), calculado a partir de los últimos 24 bits de la dirección IPv6 de destino. Solo los hosts que coinciden con el filtro del grupo de multicast de los 24 bits inferiores reciben y decodifican el frame a nivel de hardware de la NIC.

---

## 2. Comparaciones Técnicas & Matrices Exhaustivas de Alternativas

### Tabla 2.1: Comparación de Arquitectura de Protocolos (IPv4 vs. IPv6)

| Característica / Métrica | Arquitectura IPv4 | Arquitectura IPv6 | Alternativa & Impacto SRE en Producción |
| :--- | :--- | :--- | :--- |
| **Espacio de Direcciones** | 32 bits (`4.29 x 10^9`) | 128 bits (`3.4 x 10^38`) | IPv6 elimina CGNAT con estado; restaura la verdadera trazabilidad IP extremo a extremo. |
| **Tamaño del Encabezado** | Dinámico: 20–60 Bytes | Fijo: 40 Bytes | El encabezado fijo permite optimizar la velocidad de enrutamiento por hardware en dispositivos de tránsito de borde. |
| **Checksum L3** | Presente (Recalculado por salto) | Ninguno | Elimina el cálculo de checksum por salto; reduce la latencia de CPU en routers con kernel BSD. |
| **Fragmentación** | Realizada por Routers y Hosts | Realizada ÚNICAMENTE por el Host Origen | Los routers descartan paquetes IPv6 sobredimensionados y devuelven ICMPv6 *Packet Too Big* (Tipo 2). |
| **Resolución L2** | ARP (Broadcasts de Capa 2) | NDP / ICMPv6 Multicast | NDP reduce drásticamente las interrupciones de CPU en grandes clusters de cómputo. |
| **Autoconfiguración**| DHCPv4 o Estática Manual | SLAAC (RFC 4862) / DHCPv6 | SLAAC permite el arranque (bootstrapping) de nodos sin intervención (zero-touch) sin servidores DHCP centrales con estado. |
| **Dirección de Broadcast**| Presente (Última IP de la subred) | Ninguna (Reemplazada por Multicast) | Elimina el ruido de broadcast en todo el subsegmento y vectores de ataque de amplificación. |

---

### Tabla 2.2: Matriz de Conversión de Notación y Subredes

Comprender las conversiones entre la **Notación CIDR**, **Máscaras de Subred Decimales Punteadas**, **Máscaras Hexadecimales** (frecuentemente vistas en la salida de `ifconfig` en BSD), **Máscaras Wildcard** y la capacidad IP usable es obligatorio para LPI-702.

| CIDR | Máscara Decimal Punteada | Máscara Hexadecimal (`ifconfig`) | Máscara Wildcard | IPs Totales | Hosts Usables (IPv4) | Topología de Producción Típica |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `/32` | `255.255.255.255` | `0xffffffff` | `0.0.0.0` | 1 | 1 (Ruta Host) | Loopback (`lo0`), BGP Router ID, Container Endpoint |
| `/30` | `255.255.255.252` | `0xfffffffc` | `0.0.0.3` | 4 | 2 | Enlaces WAN Punto a Punto heredados |
| `/29` | `255.255.255.248` | `0xfffffff8` | `0.0.0.7` | 8 | 6 | Pool ClusterVIP de Alta Disponibilidad HAProxy / VRRP |
| `/28` | `255.255.255.240` | `0xfffffff0` | `0.0.0.15` | 16 | 14 | Ingress Gateway pequeño / Subred de Pod DMZ |
| `/27` | `255.255.255.224` | `0xffe00000` -> `0xffffffe0`| `0.0.0.31` | 32 | 30 | Subred de Cluster de Nodos de Base de Datos |
| `/26` | `255.255.255.192` | `0xffffffc0` | `0.0.0.63` | 64 | 62 | Pool de Microservicios de Aplicación |
| `/25` | `255.255.255.128` | `0xffffff80` | `0.0.0.127` | 128 | 126 | Zona de Infraestructura de tamaño mediano |
| `/24` | `255.255.255.0` | `0xffffff00` | `0.0.0.255` | 256 | 254 | Segmento de Subred de Rack estándar / VPC |
| `/23` | `255.255.250.0` -> `255.255.254.0`| `0xfffffe00` | `0.0.1.255` | 512 | 510 | Subred de Nodos Agregados de Rack Doble |
| `/16` | `255.255.0.0` | `0xffff0000` | `0.0.255.255` | 65,536 | 65,534 | Bloque Regional Completo de VPC / Datacenter |
| `/8` | `255.0.0.0` | `0xff000000` | `0.7.255.255` -> `0.255.255.255`| 16,777,216| 16,777,214 | Asignación de Backbone Empresarial Clase A |

---

### Fórmulas Matemáticas & Reglas de Conversión

1. **Cálculo de Bits de Subred:**
   $$\text{Usable Hosts} = 2^{(32 - \text{CIDR})} - 2$$
   *(Nota: Restar 2 para la ID de Red y la ID de Broadcast. En IPv6, las subredes están estandarizadas a `/64` para SLAAC, proporcionando $2^{64}$ direcciones por subred sin restadores de broadcast).*

2. **Conversión Decimal Punteada a Hexadecimal:**
   Para convertir `255.255.255.224` (`/27`):
   * $255 = \text{0xFF}$
   * $255 = \text{0xFF}$
   * $255 = \text{0xFF}$
   * $224 = 128 + 64 + 32 + 0 + 0 + 0 + 0 + 0 = 11100000_2 = \text{0xE0}$
   * **Representación Hexadecimal:** `0xffffffe0`

---

### Tabla 2.3: Semántica de Protocolos de Transporte de Capa 4

| Característica | TCP (Transmission Control Protocol) | UDP (User Datagram Protocol) | ICMP / ICMPv6 |
| :--- | :--- | :--- | :--- |
| **Estado de Conexión**| Con estado (3-Way Handshake: SYN, SYN-ACK, ACK) | Sin conexión | Sin conexión (Informativo / Error) |
| **Flujo & Congestión**| Escalado de Ventana, Selective ACK (SACK), BBR/CUBIC | Ninguno (Gestionado en capa de aplicación) | Ninguno |
| **Sobrecarga del Encabezado**| 20–60 Bytes | 8 Bytes | 8 Bytes |
| **Campo Clave** | Números de Secuencia / Ack, Flags | Puerto Origen/Destino, Longitud, Checksum | Tipo, Código, Checksum, Payload de Datos |
| **Uso en Producción** | HTTP/HTTPS, SSH, gRPC, Conectividad de bases de datos | Consultas DNS, QUIC, WireGuard, Telemetría | Path MTU Discovery, Ping, NDP, Router Advertisements |

---

## 3. Manifiestos de Infraestructura de Producción & Configuraciones de Sistema

### 3.1 Configuración de Arquitectura de Interfaz de Red FreeBSD Dual-Stack (`/etc/rc.conf`)

Esta configuración establece un nodo de borde FreeBSD dual-stack con IPv4 estática (`192.168.10.14/26`), IPv6 Global Unicast estática (`2001:db8:1000::14/64`), rutas estáticas y reenvío a nivel de sistema.

```sh
# System Hostname Definition
hostname="edge-node-01.infra.internal"

# ------------------------------------------------------------------------------
# IPv4 Network Configuration (vtnet0)
# Subnet: 192.168.10.0/26 -> Netmask: 255.255.255.192 (Hex: 0xffffffc0)
# Broadcast: 192.168.10.63 | Usable Hosts: 192.168.10.1 - 192.168.10.62
# ------------------------------------------------------------------------------
ifconfig_vtnet0="inet 192.168.10.14 netmask 255.255.255.192 broadcast 192.168.10.63"
defaultrouter="192.168.10.1"

# ------------------------------------------------------------------------------
# IPv6 Network Configuration (vtnet0)
# Global Unicast Address (GUA): 2001:db8:1000::14/64
# Prefix: 2001:db8:1000::/64
# Link-Local automatically configured by kernel (fe80::/10)
# ------------------------------------------------------------------------------
ifconfig_vtnet0_ipv6="inet6 2001:db8:1000::14 prefixlen 64"
ipv6_defaultrouter="2001:db8:1000::1"

# Enable Dual-Stack Forwarding (Acts as Router/Gateway)
gateway_enable="YES"
ipv6_gateway_enable="YES"

# Enable Packet Filter Firewall
pf_enable="YES"
pf_rules="/etc/pf.conf"
pf_flags=""
```

---

### 3.2 Configuración de Seguridad de Packet Filter de FreeBSD (`/etc/pf.conf`)

Un conjunto de reglas `pf.conf` completo y de grado de producción que permite el tráfico crítico IPv4 ARP/ICMP y el Protocolo Neighbor Discovery (NDP) de IPv6 mientras filtra prefijos de red no autorizados.

```pf
# Interface and Subnet Definitions
ext_if = "vtnet0"
ipv4_sub = "192.168.10.0/26"
ipv6_sub = "2001:db8:1000::/64"

# Global Options
set skip on lo0
set block-policy drop
set loginterface $ext_if

# Scrub incoming packets to prevent fragmentation attacks
scrub in on $ext_if all fragment reassemble

# Default Deny Policy
block all

# Pass outbound traffic statefully
pass out quick on $ext_if all flags S/SA keep state

# ------------------------------------------------------------------------------
# IPv4 Mandatory Protocols
# Allow ICMP Type 3 (Destination Unreachable) for Path MTU Discovery
# Allow ICMP Type 8 (Echo Request) for monitoring
# ------------------------------------------------------------------------------
pass in quick on $ext_if inet proto icmp icmp-type { unreach, echoreq } keep state

# ------------------------------------------------------------------------------
# IPv6 Mandatory Protocols (RFC 4890 Compliance)
# NDP (ICMPv6 Types 135, 136) and Router Advertisements (Types 133, 134) MUST pass
# ICMPv6 Type 2 (Packet Too Big) MUST pass for Path MTU Discovery
# ------------------------------------------------------------------------------
pass in quick on $ext_if inet6 proto icmp6 icmp6-type {
    unreach, toobig, echoreq, echorep,
    routersol, routeradv, neighbrsol, neighbradv
} hoplimit 255

# Pass Inbound SSH for Management
pass in quick on $ext_if proto tcp from any to ($ext_if) port 22 flags S/SA keep state
```

---

### 3.3 Manifiesto CNI Cilium Dual-Stack para Kubernetes (`cilium-ipam-config.yaml`)

Manifiesto de Kubernetes de producción que define las asignaciones de enrutamiento IPAM dual-stack para clusters IPv4 e IPv6.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cilium-config
  namespace: kube-system
data:
  # Enable Dual-Stack Operation
  enable-ipv4: "true"
  enable-ipv6: "true"
  
  # IPAM Pools Definition
  ipam: "cluster-pool"
  cluster-pool-ipv4-cidr: "10.244.0.0/16"
  cluster-pool-ipv4-mask-size: "24"
  cluster-pool-ipv6-cidr: "fd00:10:244::/48"
  cluster-pool-ipv6-mask-size: "64"
  
  # Tunneling vs Direct Routing
  routing-mode: "native"
  ipv4-native-routing-cidr: "10.244.0.0/16"
  ipv6-native-routing-cidr: "fd00:10:244::/48"
  
  # ICMP and PMTUD Support
  enable-ipv4-pmtu-discovery: "true"
  enable-ipv6-big-tcp: "true"
```

---

## 4. Comandos CLI Reales y Salidas de Terminal

### 4.1 Inspección de Interfaz en FreeBSD (`ifconfig`)

Ejecutando `ifconfig` en FreeBSD para verificar propiedades dual-stack, la representación de la máscara de subred hexadecimal (`0xffffffc0`), direcciones de broadcast y scopes de IPv6.

```console
$ ifconfig vtnet0
vtnet0: flags=8843<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST> metric 0 mtu 1500
	options=8000b<RXCSUM,TXCSUM,VLAN_MTU,LINKSTATE>
	ether 52:54:00:12:34:56
	inet 192.168.10.14 netmask 0xffffffc0 broadcast 192.168.10.63
	inet6 fe80::5054:ff:fe12:3456%vtnet0 prefixlen 64 scopeid 0x1
	inet6 2001:db8:1000::14 prefixlen 64
	media: Ethernet autoselect (10Gbase-T <full-duplex>)
	status: active
	nd6 options=21<PERFORMNUD,AUTO_LINKLOCAL>
```

---

### 4.2 Máscara de Bits de Subred & Cálculo de Rango de Red (`sipcalc`)

Calculando propiedades de red para IPv4 (`192.168.10.138/27`) e IPv6 (`2001:db8:abcd:0012::/64`) usando `sipcalc`.

#### Desglose de Subred IPv4:
```console
$ sipcalc 192.168.10.138/27
-[ipv4 : 192.168.10.138/27] - 0

[Usage]
Host address		- 192.168.10.138
Host address (decimal)	- 3232238218
Host address (hex)	- C0A80A8A
Network address		- 192.168.10.128
Network mask		- 255.255.255.224
Network mask (bits)	- 27
Network mask (hex)	- FFFFFFE0
Broadcast address	- 192.168.10.159
Cisco wildcard		- 0.0.0.31
Addresses in network	- 32
Network range		- 192.168.10.128 - 192.168.10.159
Usable range		- 192.168.10.129 - 192.168.10.158
```

#### Desglose de Subred IPv6:
```console
$ sipcalc 2001:db8:abcd:0012::1/64
-[ipv6 : 2001:db8:abcd:0012::1/64] - 0

[Usage]
Expanded Address	- 2001:0db8:abcd:0012:0000:0000:0000:0001
Compressed address	- 2001:db8:abcd:12::1
Subnet prefix (masked)	- 2001:db8:abcd:12:0:0:0:0/64
Address type		- Aggregable Global Unicast Addresses
Prefix length		- 64
Network range		- 2001:0db8:abcd:0012:0000:0000:0000:0000 -
			  2001:0db8:abcd:0012:ffff:ffff:ffff:ffff
```

---

### 4.3 Inspección de la Tabla de Enrutamiento del Kernel (`netstat -rn`)

Verificando los árboles de la tabla de enrutamiento del kernel BSD tanto para IPv4 como para IPv6.

```console
$ netstat -rn -f inet
Routing tables

Internet:
Destination        Gateway            Flags     Netif Expire
default            192.168.10.1       UGS      vtnet0
127.0.0.1          link#2             UH          lo0
192.168.10.0/26    link#1             U        vtnet0
192.168.10.14      link#1             UHS         lo0
192.168.10.63      link#1             UHS      vtnet0
```

```console
$ netstat -rn -f inet6
Routing tables

Internet6:
Destination                       Gateway            Flags     Netif Expire
::/0                              2001:db8:1000::1   UGS      vtnet0
::1                               link#2             UHS         lo0
2001:db8:1000::/64                link#1             U        vtnet0
2001:db8:1000::14                 link#1             UHS         lo0
fe80::%vtnet0/64                  link#1             U        vtnet0
fe80::5054:ff:fe12:3456%vtnet0    link#1             UHS         lo0
ff02::%vtnet0/32                  link#1             U        vtnet0
```

* **Explicación de Flags:**
  * `U`: La ruta está activa (Up).
  * `G`: El destino requiere enrutamiento a través de Gateway.
  * `S`: Ruta Estática (Static Route).
  * `H`: Ruta Host (Host Route, destino único `/32` o `/128`).
  * `S`: Alias de Loopback/Host.

---

### 4.4 Rastreo de Paquetes en Vivo (`tcpdump`)

Capturando flujos de paquetes del Protocolo Neighbor Discovery (NDP) de ICMPv6 en FreeBSD.

```console
$ sudo tcpdump -nni vtnet0 -c 4 icmp6
tcpdump: verbose output suppressed, use -v or -vv for full protocol decode
listening on vtnet0, link-type EN10MB (Ethernet), capture size 262144 bytes
20:49:55.102941 IP6 fe80::5054:ff:fe12:3456 > ff02::1:ff00:1: ICMP6, neighbor solicitation, who has 2001:db8:1000::1, length 32
20:49:55.103412 IP6 fe80::5054:ff:fe12:9999 > fe80::5054:ff:fe12:3456: ICMP6, neighbor advertisement, tgt is 2001:db8:1000::1, length 32
20:49:56.201112 IP6 2001:db8:1000::14 > 2001:db8:1000::1: ICMP6, echo request, seq 1, length 64
20:49:56.201488 IP6 2001:db8:1000::1 > 2001:db8:1000::14: ICMP6, echo reply, seq 1, length 64
4 packets captured
4 packets received by filter
0 packets dropped by kernel
```

---

## 5. Solución de Problemas, Verificación & Análisis de Fallas

### Diagrama de Flujo de Diagnóstico

```
                          [ Networking Issue Detected ]
                                        |
                   +--------------------+--------------------+
                   |                                         |
            [ IPv4 Failure ]                         [ IPv6 Failure ]
                   |                                         |
     Check IP & Mask (`ifconfig`)              Check Link-Local & GUA (`ifconfig`)
     Must match segment CIDR                   Verify scopeid (%vtnet0)
                   |                                         |
     Check ARP Table (`arp -a`)                Check NDP Table (`ndp -a`)
     Is MAC resolved?                          Is Neighbor Reachable?
                   |                                         |
     Verify ICMP (`ping -c 3`)                 Verify ICMPv6 (`ping6 -c 3`)
     Filter blocking Type 3/8?                 Filter blocking Type 135/136/2?
                   |                                         |
                   +--------------------+--------------------+
                                        |
                        [ Check Path MTU Discovery ]
                        `ping -D -s 1472 <IP>` (v4)
                        `ping6 -b 1440 <IP>`   (v6)
```

---

### Escenario A: Desalineación de Máscara de Subred IPv4 & Agujero Negro de Enrutamiento Silencioso

* **Síntoma:** El Host `192.168.10.45` no puede alcanzar al Servidor de Base de Datos `192.168.10.70`. Los pings fallan con `No route to host`.
* **Análisis de Causa Raíz:** El Host `A` está configurado con la máscara de red `255.255.255.192` (`/26`), definiendo su rango de subred de `192.168.10.0` a `192.168.10.63`. El Servidor de Base de Datos en `192.168.10.70` se encuentra en un bloque de subred superior (`192.168.10.64/26`). Debido a que el Host `A` trata a `.70` como fuera de enlace (off-link), reenvía el tráfico a su gateway predeterminado. Si el gateway carece de una ruta hacia `.70`, el tráfico se descarta silenciosamente.

#### Protocolo de Diagnóstico:

1. Consultar parámetros de interfaz:
   ```console
   $ ifconfig vtnet0 | grep inet
   inet 192.168.10.45 netmask 0xffffffc0 broadcast 192.168.10.63
   ```
2. Rastrear la evaluación de ruta de destino:
   ```console
   $ route get 192.168.10.70
      route to: 192.168.10.70
   destination: default
       gateway: 192.168.10.1
     fib: 0
     interface: vtnet0
         flags: <UP,GATEWAY,DONE,STATIC>
   ```
3. **Remediación:** Ajustar la máscara de subred a `/25` (`255.255.255.128` / `0xffffff80`) si ambos hosts pertenecen al mismo segmento de broadcast L2:
   ```console
   $ sudo ifconfig vtnet0 inet 192.168.10.45/25
   ```

---

### Escenario B: Estancamiento de IPv6 Neighbor Discovery (NDP) debido a Filtrado de ICMPv6

* **Síntoma:** Se asigna la dirección IPv6, pero los nodos no pueden hacer ping a hosts adyacentes en el mismo enlace físico.
* **Análisis de Causa Raíz:** Una regla de firewall en `/etc/pf.conf` bloquea todo el tráfico ICMPv6 (`block in proto icmp6`). Esto bloquea Neighbor Solicitation (Tipo 135) y Neighbor Advertisement (Tipo 136), impidiendo que los nodos resuelvan direcciones MAC.

#### Protocolo de Diagnóstico:

1. Verificar la tabla NDP del kernel:
   ```console
   $ ndp -a
   Neighbor                             Linklayer Address  Netif Expire S Flags
   2001:db8:1000::1                     (incomplete)       vtnet0 3s     S 
   2001:db8:1000::14                    52:54:00:12:34:56  lo0    permanent R
   ```
   *(Nota: El estado `(incomplete)` indica una falla de resolución de dirección de Capa 2 a través de NDP).*

2. Verificar el ingreso de paquetes crudos usando `tcpdump`:
   ```console
   $ sudo tcpdump -nni vtnet0 icmp6 type 135 or icmp6 type 136
   ```

3. **Remediación:** Actualizar `/etc/pf.conf` para permitir explícitamente los tipos de NDP:
   ```pf
   pass in quick on vtnet0 inet6 proto icmp6 icmp6-type { neighbrsol, neighbradv } hoplimit 255
   ```
   Recargar la base de reglas:
   ```console
   $ sudo pfctl -f /etc/pf.conf
   ```

---

### Escenario C: Agujero Negro de Path MTU Discovery (PMTUD)

* **Síntoma:** Las sesiones SSH se congelan al ejecutar comandos grandes (por ejemplo, `cat large_file.txt`), o los handshakes HTTP/TLS se estancan indefinidamente. Los paquetes `ping` simples pasan sin problema.
* **Análisis de Causa Raíz:** Un enlace intermedio tiene un MTU más bajo (por ejemplo, 1400 bytes debido a la encapsulación VXLAN) que la NIC del host (1500 bytes). El host establece el flag DF (*Don't Fragment*) de IPv4. El router descarta paquetes que superan los 1400 bytes y envía un paquete ICMP Tipo 3 Código 4 (*Fragmentation Needed and DF set*) de vuelta al host. Un firewall descarta este paquete ICMP, provocando que la pila TCP del host retransmita frames de 1500 bytes hasta que expire el tiempo de espera de la conexión (timeout).

#### Protocolo de Diagnóstico:

1. Realizar prueba de barrido con el bit DF activo (`-D` en FreeBSD):
   ```console
   $ ping -D -s 1472 192.168.10.1
   PING 192.168.10.1 (192.168.10.1): 1472 data bytes
   1480 bytes from 192.168.10.1: icmp_seq=0 ttl=64 time=0.412 ms
   
   $ ping -D -s 1473 192.168.10.1
   PING 192.168.10.1 (192.168.10.1): 1473 data bytes
   ping: sendto: Message too long
   ```
   *(Payload de 1472 + 8 bytes de encabezado ICMP + 20 bytes de encabezado IP = 1500 bytes de MTU).*

2. Consultar el MTU de la ruta específica a través de la tabla de rutas del kernel:
   ```console
   $ route get 192.168.10.1
      route to: 192.168.10.1
   destination: 192.168.10.1
     interface: vtnet0
          flags: <UP,HOST,DONE,STATIC>
       recvpipe  sendpipe  ssthresh  rtt,msec    mtu        weight    expire
              0         0         0         0      1500         0         0
   ```

3. **Remediación:** Permitir mensajes ICMP PMTUD en los conjuntos de reglas del firewall, o ajustar (clamp) el MSS (Maximum Segment Size) de TCP en `pf.conf`:
   ```pf
   scrub in on vtnet0 max-mss 1360
   ```

---

## 6. Referencias

* **Objetivos Oficiales del Linux Professional Institute (LPI):**  
  [https://www.lpi.org/our-certifications/bsd-specialist-overview/](https://www.lpi.org/our-certifications/bsd-specialist-overview/)
* **Manual de FreeBSD - Configuración de Red:**  
  [https://docs.freebsd.org/en/books/handbook/network/](https://docs.freebsd.org/en/books/handbook/network/)
* **Páginas del Manual de FreeBSD - `ifconfig(8)`:**  
  [https://man.freebsd.org/cgi/man.cgi?query=ifconfig](https://man.freebsd.org/cgi/man.cgi?query=ifconfig)
* **Páginas del Manual de FreeBSD - `pf.conf(5)`:**  
  [https://man.freebsd.org/cgi/man.cgi?query=pf.conf](https://man.freebsd.org/cgi/man.cgi?query=pf.conf)
* **RFC 791 - Protocolo de Internet (Especificación IPv4):**  
  [https://www.rfc-editor.org/rfc/rfc791](https://www.rfc-editor.org/rfc/rfc791)
* **RFC 8200 - Protocolo de Internet, Especificación de la Versión 6 (IPv6):**  
  [https://www.rfc-editor.org/rfc/rfc8200](https://www.rfc-editor.org/rfc/rfc8200)
* **RFC 4291 - Arquitectura de Direccionamiento IP Versión 6:**  
  [https://www.rfc-editor.org/rfc/rfc4291](https://www.rfc-editor.org/rfc/rfc4291)
* **RFC 4861 - Neighbor Discovery para IP versión 6 (IPv6):**  
  [https://www.rfc-editor.org/rfc/rfc4861](https://www.rfc-editor.org/rfc/rfc4861)
* **RFC 4890 - Recomendaciones para Filtrar Mensajes ICMPv6 en Firewalls:**  
  [https://www.rfc-editor.org/rfc/rfc4890](https://www.rfc-editor.org/rfc/rfc4890)