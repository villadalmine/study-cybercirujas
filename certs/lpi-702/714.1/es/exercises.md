# LPI-702: BSD Specialist (Examen 702-100, v1.0)
## Tema 714.1: Fundamentos de Protocolos de Internet
**Peso:** 3.33 | **Rol Objetivo:** Senior SRE / Platform Architect

---

### Referencias Oficiales
* **Objetivo LPI BSD Specialist 714.1:** [https://www.lpi.org/our-certifications/bsd-specialist-overview/](https://www.lpi.org/our-certifications/bsd-specialist-overview/)
* **Arquitectura de Redes e Interfaces de FreeBSD:** [https://docs.freebsd.org/en/books/handbook/network/](https://docs.freebsd.org/en/books/handbook/network/)
* **Configuración de Red de OpenBSD (`hostname.if`):** [https://man.openbsd.org/hostname.if.5](https://man.openbsd.org/hostname.if.5)
* **RFC 791 - Protocolo de Internet (IPv4):** [https://datatracker.ietf.org/doc/html/rfc791](https://datatracker.ietf.org/doc/html/rfc791)
* **RFC 4291 - Arquitectura de Direccionamiento IPv6:** [https://datatracker.ietf.org/doc/html/rfc4291](https://datatracker.ietf.org/doc/html/rfc4291)
* **RFC 4861 - Descubrimiento de Vecinos para IP versión 6 (IPv6):** [https://datatracker.ietf.org/doc/html/rfc4861](https://datatracker.ietf.org/doc/html/rfc4861)

---

### Ejercicio Guiado 1: Subnetting IPv4, Máscaras de Bits Hexadecimales y Alias de Interfaces BSD

#### Contexto Arquitectónico Ejecutivo
Las direcciones IPv4 consisten en un entero sin signo de 32 bits dividido en porciones de red y de host. Los sistemas operativos BSD (FreeBSD, OpenBSD, NetBSD) manipulan las máscaras de red internamente como máscaras de bits hexadecimales de 32 bits (por ejemplo, `0xffffff00`). Las herramientas de red modernas aceptan Notación Decimal Punteada (DDN), Hexadecimal y notación de prefijo de Enrutamiento Inter-Dominio Sin Clases (CIDR). Comprender las conversiones entre estas representaciones es obligatorio para configurar interfaces de red, definiciones de tablas de filtro de paquetes (`pf`) y tablas de enrutamiento.

---

#### Guía de Ejecución Paso a Paso

1. Iniciá sesión en tu entorno de terminal BSD e identificá las configuraciones de interfaz activas usando `ifconfig`:
```bash
$ ifconfig vtnet0
```
*Salida Esperada:*
```text
vtnet0: flags=8843<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST> metric 0 mtu 1500
	options=8000b<TXCSUM,VLAN_MTU,VLAN_HWTAGGING,LINKSTATE>
	ether 52:54:00:fa:9b:12
	inet 192.168.1.50 netmask 0xffffff00 broadcast 192.168.1.255
	media: Ethernet autoselect (1000baseT <full-duplex>)
	status: active
```

2. Convertí el prefijo CIDR `/27` a Notación Decimal Punteada (DDN) y notación Hexadecimal:
   * **Desglose de bits:** Una máscara `/27` tiene 27 bits contiguos establecidos en `1` seguidos por 5 bits no establecidos en `0`.
   * **Representación binaria:** `11111111.11111111.11111111.11100000`
   * **Conversión decimal:** Octeto 4 = $128 + 64 + 32 = 224$. Resultado: `255.255.255.224`
   * **Conversión hexadecimal:** 
     * Octeto 1: `11111111` = `0xFF`
     * Octeto 2: `11111111` = `0xFF`
     * Octeto 3: `11111111` = `0xFF`
     * Octeto 4: `11100000` = `0xE0`
     * Resultado: `0xffffffe0`

3. Calculá el ID de Red, Dirección de Broadcast, Primer Host Utilizable y Último Host Utilizable para la IP de host `10.200.45.138/27`:
   * **Tamaño del Bloque:** $2^{32-27} = 2^5 = 32$ direcciones por subred.
   * **Múltiples de Intervalo de Subred:** $0, 32, 64, 96, 128, 160, 192, \dots$
   * **Dirección de Red:** El valor del octeto del host `138` cae entre `128` y `159`. Dirección de Red: `10.200.45.128`.
   * **Dirección de Broadcast:** `10.200.45.159` (Dirección de Red + Tamaño del Bloque - 1).
   * **Rango de Hosts Utilizables:** `10.200.45.129` a `10.200.45.158`.

4. Aplicá un alias IPv4 usando notación CIDR en FreeBSD de forma dinámica mediante `ifconfig`:
```bash
$ sudo ifconfig vtnet0 inet 10.200.45.138/27 alias
```

5. Verificá la configuración de la interfaz para observar cómo el kernel almacena la máscara de red en formato hexadecimal:
```bash
$ ifconfig vtnet0
```
*Salida Esperada:*
```text
vtnet0: flags=8843<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST> metric 0 mtu 1500
	options=8000b<TXCSUM,VLAN_MTU,VLAN_HWTAGGING,LINKSTATE>
	ether 52:54:00:fa:9b:12
	inet 192.168.1.50 netmask 0xffffff00 broadcast 192.168.1.255
	inet 10.200.45.138 netmask 0xffffffe0 broadcast 10.200.45.159
	media: Ethernet autoselect (1000baseT <full-duplex>)
	status: active
```

6. Para persistir esta configuración de red a través de los reinicios, editá `/etc/rc.conf` (FreeBSD) o `/etc/hostname.vtnet0` (OpenBSD):

*Fragmento de `/etc/rc.conf` sintácticamente válido para FreeBSD:*
```sh
hostname="bsd-node-01.production.internal"
ifconfig_vtnet0="inet 192.168.1.50 netmask 255.255.255.0"
ifconfig_vtnet0_alias0="inet 10.200.45.138 netmask 255.255.255.224"
defaultrouter="192.168.1.1"
```

*Fragmento de `/etc/hostname.vtnet0` sintácticamente válido para OpenBSD:*
```text
inet 192.168.1.50 255.255.255.0
inet alias 10.200.45.138 255.255.255.224
!route add default 192.168.1.1
```

---

#### Comprobación de Comprensión: Bloque 1

1. **Pregunta 1.1:** Un administrador de sistemas FreeBSD asigna una dirección IPv4 a `em0` usando el comando `ifconfig em0 inet 172.16.89.200 netmask 0xffffffc0`. ¿Cuál es la longitud de prefijo CIDR, la dirección de red y la dirección de broadcast para esta asignación?
2. **Pregunta 1.2:** Convertí el prefijo CIDR `/22` tanto a Notación Decimal Punteada (DDN) como a notación Hexadecimal de 32 bits. ¿Cuántas direcciones IP en total están contenidas dentro de una sola asignación `/22`?
3. **Pregunta 1.3:** Un SRE necesita subdividir en subredes `192.168.10.0/24` en al menos 6 subredes distintas, cada una soportando un mínimo de 25 interfaces de host utilizables. ¿Cuál es la máscara CIDR óptima requerida, cuántas subredes se crean y cuál es la dirección de broadcast de la 3.ª subred?

---

### Ejercicio Guiado 2: Arquitectura IPv6, SLAAC, Síntesis EUI-64 y Protocolo de Descubrimiento de Vecinos (NDP)

#### Contexto Arquitectónico Ejecutivo
Las direcciones IPv6 tienen 128 bits de longitud, expresadas como ocho bloques hexadecimales de 16 bits separados por dos puntos (RFC 4291). A diferencia de IPv4 ARP, IPv6 utiliza Neighbor Discovery Protocol (NDP)—construido sobre ICMPv6 (RFC 4861)—para resolución de direcciones, descubrimiento de routers y detección de direcciones duplicadas (DAD). Los tipos de direcciones IPv6 reglamentarios incluyen:
* **Link-Local (`fe80::/10`):** Configurada automáticamente en cada interfaz habilitada para IPv6; no enrutable más allá del segmento local de capa 2. Requiere la especificación de un índice de ámbito (scope index) en las utilidades BSD (`ping6 fe80::1%vtnet0`).
* **Global Unicast (`2000::/3`):** Direcciones IPv6 públicas enrutables globalmente.
* **Unique Local (`fc00::/7`):** Enrutable dentro de organizaciones locales (equivalente a IP privada).
* **Multicast (`ff00::/8`):** Reemplaza el broadcast IPv4 (`ff02::1` = Todos los Nodos, `ff02::2` = Todos los Routers).

Stateless Address Autoconfiguration (SLAAC) puede usar Modified EUI-64 para derivar un Identificador de Interfaz de 64 bits a partir de una dirección MAC IEEE de 48 bits insertando `0xfffe` en el medio e invirtiendo el bit Universal/Local ($U/L$) (bit 7 del octeto 1).

---

#### Guía de Ejecución Paso a Paso

1. Mostrá la configuración IPv6 del sistema y visualizá las direcciones Link-Local y Global Unicast asignadas:
```bash
$ ifconfig vtnet0 inet6
```
*Salida Esperada:*
```text
vtnet0: flags=8843<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST> metric 0 mtu 1500
	options=8000b<TXCSUM,VLAN_MTU,VLAN_HWTAGGING,LINKSTATE>
	inet6 fe80::5054:00ff:fefa:9b12%vtnet0 prefixlen 64 scopeid 0x1
	inet6 2001:db8:1000:abcd:5054:00ff:fefa:9b12 prefixlen 64 autoconf
```

2. Realizá una derivación manual del Identificador de Interfaz Modified EUI-64 para la dirección MAC `00:15:5d:01:2a:4b`:
   * **Paso A (Dividir MAC):** `00:15:5d` y `01:2a:4b`
   * **Paso B (Insertar `FF:FE`):** `00:15:5d:ff:fe:01:2a:4b`
   * **Paso C (Invertir el bit Universal/Local):**
     * Primer octeto: `00` (hex) = `00000000` (binario)
     * Bit 7 (índice 0 desde la izquierda: el bit 1 es el MSB, el bit 7 es el bit $U/L$): `000000`**`1`**`0` = `02` (hex)
   * **Paso D (Formatear a notación de dos puntos IPv6):** `0215:5dff:fe01:2a4b`
   * **Combinado con el prefijo `2001:db8:cafe:1::/64`:** `2001:db8:cafe:1:215:5dff:fe01:2a4b`

3. Inspeccioná la caché local de Neighbor Discovery de IPv6 usando `ndp`:
```bash
$ ndp -a
```
*Salida Esperada:*
```text
Neighbor                             Linklayer Address  Netif Expire    S Flags
fe80::1%vtnet0                       52:54:00:12:34:56 vtnet0 23m50s    S R
2001:db8:1000:abcd::1                52:54:00:12:34:56 vtnet0 23m42s    V R
```

4. Capturá el tráfico ICMPv6 Neighbor Solicitation (NS) y Neighbor Advertisement (NA) en tiempo real usando `tcpdump`:
```bash
$ sudo tcpdump -ni vtnet0 -vvv 'icmp6 and (ip6[40] == 135 or ip6[40] == 136)'
```
*Salida Esperada:*
```text
20:55:10.482019 IP6 (hlim 255, next-header ICMPv6 (58) payload length: 32) fe80::5054:00ff:fefa:9b12 > ff02::1:ff00:1:
    ICMP6, neighbor solicitation, length 32, who has 2001:db8:1000:abcd::1
	source link-address: 52:54:00:fa:9b:12
20:55:10.482811 IP6 (hlim 255, next-header ICMPv6 (58) payload length: 32) fe80::1 > fe80::5054:00ff:fefa:9b12:
    ICMP6, neighbor advertisement, length 32, tgt 2001:db8:1000:abcd::1, flags [router, solicited, override]
	target link-address: 52:54:00:12:34:56
```

5. Ejecutá una solicitud de eco ICMPv6 al router link-local local, especificando explícitamente la interfaz de ámbito de red requerida:
```bash
$ ping6 -c 3 fe80::1%vtnet0
```
*Salida Esperada:*
```text
PING6(56=40+8+8 bytes) fe80::5054:00ff:fefa:9b12%vtnet0 --> fe80::1%vtnet0
16 bytes from fe80::1%vtnet0, icmp_seq=0 hlim=64 time=0.412 ms
16 bytes from fe80::1%vtnet0, icmp_seq=1 hlim=64 time=0.389 ms
16 bytes from fe80::1%vtnet0, icmp_seq=2 hlim=64 time=0.395 ms

--- fe80::1%vtnet0 ping6 statistics ---
3 packets transmitted, 3 packets received, 0.0% packet loss
round-trip min/avg/max/std-dev = 0.389/0.398/0.412/0.010 ms
```

---

#### Comprobación de Comprensión: Bloque 2

1. **Pregunta 2.1:** Dada una interfaz de red con dirección MAC `AC:16:2D:B4:98:C1` configurada con SLAAC en el prefijo de red `2001:db8:4444:5555::/64`, calculá la dirección IPv6 global Modified EUI-64 exacta.
2. **Pregunta 2.2:** ¿Qué tipos de paquetes ICMPv6 reemplazan a IPv4 ARP Request y ARP Reply respectivamente? Indicá sus números de tipo ICMPv6 y explicá por qué se requieren IDs de ámbito (por ejemplo, `%vtnet0`) al sondear direcciones IPv6 Link-Local.
3. **Pregunta 2.3:** Comprimí la siguiente dirección IPv6 a su representación canónica válida más corta según el RFC 5952: `2001:0db8:0000:0000:0000:0000:0000:0001`. ¿Puede la dirección `fe80:0000:0000:0001:0000:0000:0000:0056` comprimirse como `fe80::1::56`? Explicá por qué o por qué no.

---

### Ejercicio Guiado 3: Mecánica de Encabezados de Protocolo, Máquinas de Estado y Herramientas de Diagnóstico (`tcpdump`, `sockstat`, `netstat`)

#### Contexto Arquitectónico Ejecutivo
La resolución de problemas de red al nivel de Arquitecto de Plataformas / SRE requiere mapear tramas de red crudas a las capas OSI/TCP-IP y a las estructuras de socket del kernel:

```
+-------------------------------------------------------------------+
| OSI Model                | TCP/IP Stack     | Protocols / Units   |
+--------------------------+------------------+---------------------+
| Layer 7: Application     |                  | HTTP, DNS, SSH, TLS |
| Layer 6: Presentation    | Application      | (Data Streams)      |
| Layer 5: Session         |                  |                     |
+--------------------------+------------------+---------------------+
| Layer 4: Transport       | Transport        | TCP, UDP (Segments) |
+--------------------------+------------------+---------------------+
| Layer 3: Network         | Internet         | IPv4, IPv6, ICMP    |
|                          |                  | (Packets / Datagrams)|
+--------------------------+------------------+---------------------+
| Layer 2: Data Link       | Link             | Ethernet, L2 Switch |
| Layer 1: Physical        | (Network Access) | (Frames / Bits)     |
+-------------------------------------------------------------------+
```

Campos Clave de Encabezado y Mecánica Operativa:
* **Encabezado IPv4:** TTL (Time to Live - decrementado por salto para prevenir bucles), campo Protocol (`6` para TCP, `17` para UDP, `1` para ICMP), Flags (Don't Fragment - DF, More Fragments - MF).
* **Encabezado IPv6:** Hop Limit (equivalente a TTL), Next Header (encabezados encadenados que reemplazan las opciones IPv4).
* **Flags TCP y Máquina de Estados de Conexión:** `SYN` $\rightarrow$ `SYN-ACK` $\rightarrow$ `ACK` (Establece la sesión); `FIN` / `RST` (Finaliza la sesión). Window Size impone el control de flujo.
* **Diagnóstico de Sockets BSD:** Los sistemas BSD proporcionan `sockstat` para inspeccionar directamente las asignaciones de sockets del kernel (`struct socket`), mapeando sockets abiertos a PIDs, cuentas de usuario y descriptores de archivo.

---

#### Guía de Ejecución Paso a Paso

1. Consultá los sockets TCP escuchando activos en IPv4 e IPv6 en un host BSD usando `sockstat`:
```bash
$ sockstat -46 -l -P tcp
```
*Salida Esperada:*
```text
USER     COMMAND    PID   FD PROTO  LOCAL ADDRESS         FOREIGN ADDRESS      
root     sshd       1048  3  tcp46  *:22                  *:*
www      nginx      1201  6  tcp4   127.0.0.1:8080        *:*
root     ntpd       842   5  tcp4   127.0.0.1:123         *:*
```

2. Inspeccioná los archivos de configuración de mapeo de protocolos en `/etc`:
```bash
$ grep -E "^(tcp|udp|icmp)\s" /etc/protocols
```
*Salida Esperada:*
```text
icmp	1	ICMP	# internet control message protocol
tcp	6	TCP	# transmission control protocol
udp	17	UDP	# user datagram protocol
```

3. Rastreá las tablas de enrutamiento activas del kernel en BSD usando `netstat -rn` (o `route -n show` en OpenBSD):
```bash
$ netstat -rn -f inet
```
*Salida Esperada:*
```text
Routing tables

Internet:
Destination        Gateway            Flags     Netif Expire
default            192.168.1.1        UGS      vtnet0
10.200.45.128/27   link#1             U        vtnet0
127.0.0.1          link#2             UH          lo0
192.168.1.0/24     link#1             U        vtnet0
192.168.1.50       link#1             UHS         lo0
```

4. Realizá una prueba de ICMP Path MTU Discovery (PMTUD) para probar cuellos de botella de MTU sin fragmentar paquetes, utilizando el bit Don't Fragment (DF):
```bash
$ ping -D -s 1472 192.168.1.1
```
*Salida Esperada:*
```text
PING 192.168.1.1 (192.168.1.1): 1472 data bytes
1480 bytes from 192.168.1.1: icmp_seq=0 ttl=64 time=0.512 ms
1480 bytes from 192.168.1.1: icmp_seq=1 ttl=64 time=0.481 ms

--- 192.168.1.1 ping statistics ---
2 packets transmitted, 2 packets received, 0.0% packet loss
round-trip min/avg/max/std-dev = 0.481/0.496/0.512/0.015 ms
```
*(Nota: Tamaño total del paquete = 1472 bytes de carga útil + 8 bytes de encabezado ICMP + 20 bytes de encabezado IPv4 = 1500 bytes, coincidiendo exactamente con el MTU estándar de Ethernet).*

5. Capturá un handshake completo de 3 vías de TCP en el puerto 80 usando análisis de número de secuencia absoluto en bruto en `tcpdump`:
```bash
$ sudo tcpdump -ni vtnet0 -S 'tcp port 80 and (tcp[tcpflags] & (tcp-syn|tcp-ack) != 0)'
```
*Salida Esperada:*
```text
21:02:14.102381 IP 192.168.1.50.49152 > 192.168.1.100.80: Flags [S], seq 3892019201, win 65535, options [mss 1460,nop,wscale 6,sackOK], length 0
21:02:14.102891 IP 192.168.1.100.80 > 192.168.1.50.49152: Flags [S.], seq 1102938401, ack 3892019202, win 65535, options [mss 1460,nop,wscale 6,sackOK], length 0
21:02:14.102944 IP 192.168.1.50.49152 > 192.168.1.100.80: Flags [.], seq 3892019202, ack 1102938402, win 1026, length 0
```

---

#### Comprobación de Comprensión: Bloque 3

1. **Pregunta 3.1:** Analizá la salida de `tcpdump` en el Paso 5 anterior. ¿Cuál es el número de secuencia inicial (ISN) generado por el cliente (`192.168.1.50`)? Explicá por qué el número de acuse de recibo (acknowledgment number) en el paquete 2 (`SYN-ACK`) está establecido en `3892019202` aunque el paquete `SYN` haya transmitido 0 bytes de carga útil de datos.
2. **Pregunta 3.2:** Si un SRE ejecuta `ping -D -s 1473 192.168.1.1` a través de un enlace Ethernet con MTU 1500, ¿qué tipo y código de error de respuesta ICMP generará la interfaz de red local o el router intermedio?
3. **Pregunta 3.3:** ¿Cuál es la diferencia principal entre `sockstat` y `netstat` en FreeBSD al inspeccionar servicios de red en escucha? ¿Qué utilidad correlaciona directamente un puerto TCP abierto con un PID de ejecutable de proceso?

---

<details>
<summary><strong>Respuestas y Soluciones Detalladas Paso a Paso</strong></summary>

### Soluciones para el Ejercicio Guiado 1

* **Respuesta 1.1:**
  * **Conversión de Máscara de Red Hexadecimal:** `0xffffffc0` = `11111111.11111111.11111111.11000000` en binario.
  * **Longitud del Prefijo CIDR:** Contar los bits establecidos da $8 + 8 + 8 + 2 = 26$. Prefijo: `/26`.
  * **Tamaño del Bloque:** $2^{32-26} = 2^6 = 64$.
  * **Múltiples de Intervalo de Subred:** $0, 64, 128, 192, 256$.
  * **Dirección de Red:** El valor del octeto del host `200` cae entre `192` y `255`. Dirección de Red = `172.16.89.192`.
  * **Dirección de Broadcast:** `172.16.89.255` ($192 + 64 - 1$).

* **Respuesta 1.2:**
  * **Bits establecidos en CIDR `/22`:** 22 unos, 10 ceros (`11111111.11111111.11111100.00000000`).
  * **Notación Decimal Punteada (DDN):** `255.255.252.0` (Octeto 3 = $128+64+32+16+8+4 = 252$).
  * **Notación Hexadecimal:** `255` = `0xFF`, `252` = `0xFC`, `0` = `0x00`. Máscara: `0xfffffc00`.
  * **Direcciones IP Totales:** $2^{32-22} = 2^{10} = 1024$ direcciones (1022 hosts utilizables).

* **Respuesta 1.3:**
  * **Requisito de Subred:** Se necesitan $\ge 6$ subredes y $\ge 25$ hosts por subred.
  * **Fórmula:** $2^s \ge 6 \implies s = 3$ bits tomados de la porción de host.
  * **Nuevo Prefijo CIDR:** $24 + 3 = /27$ (Máscara de red `255.255.255.224`).
  * **Subredes Creadas:** $2^3 = 8$ subredes.
  * **Hosts Utilizables Por Subred:** $2^{32-27} - 2 = 32 - 2 = 30$ hosts (satisface $\ge 25$).
  * **Subred 1 (Subred 0):** `192.168.10.0/27` (Broadcast: `192.168.10.31`)
  * **Subred 2 (Subred 1):** `192.168.10.32/27` (Broadcast: `192.168.10.63`)
  * **Subred 3 (Subred 2):** `192.168.10.64/27` (Broadcast: `192.168.10.95`).

---

### Soluciones para el Ejercicio Guiado 2

* **Respuesta 2.1:**
  * **Dirección MAC:** `AC:16:2D:B4:98:C1`
  * **Paso A (Dividir):** `AC:16:2D` y `B4:98:C1`
  * **Paso B (Insertar `FF:FE`):** `AC:16:2D:FF:FE:B4:98:C1`
  * **Paso C (Invertir bit $U/L$):** 
    * Primer octeto `AC` (hex) = `10101100` (binario).
    * Invirtiendo bit 7 (2.º LSB): `101011`**`1`**`0` = `AE` (hex).
  * **Paso D (Formatear Identificador de Interfaz):** `ae16:2dff:feb4:98c1`
  * **Dirección IPv6 Completa:** `2001:db8:4444:5555:ae16:2dff:feb4:98c1`

* **Respuesta 2.2:**
  * **Neighbor Solicitation (NS):** Tipo ICMPv6 `135` (reemplaza a IPv4 ARP Request).
  * **Neighbor Advertisement (NA):** Tipo ICMPv6 `136` (reemplaza a IPv4 ARP Reply).
  * **Requisito de ID de Ámbito:** Las direcciones Link-Local (`fe80::/10`) no son enrutables y pueden existir idénticamente a través de múltiples interfaces locales en el mismo host (por ejemplo, `vtnet0`, `vtnet1`). El ID de ámbito (por ejemplo, `%vtnet0`) informa explícitamente a la capa de sockets del kernel a qué interfaz física / capa de enlace dirigir la trama.

* **Respuesta 2.3:**
  * **Forma Canónica Comprimida:** `2001:db8::1`. El RFC 5952 dicta que los ceros a la izquierda dentro de un campo de 16 bits deben suprimirse, y la secuencia continua más larga de campos completamente ceros debe reemplazarse por `::`.
  * **Compresión Inválida `fe80::1::56`:** Estrictamente ilegal. El operador de doble dos puntos (`::`) solo puede aparecer **una sola vez** en una cadena de dirección IPv6. Múltiples usos de `::` crean ambigüedad al reconstruir el arreglo exacto de 128 bits porque el analizador no puede determinar cuántos campos de ceros pertenecen a cada `::`. La compresión correcta para `fe80:0000:0000:0001:0000:0000:0000:0056` es `fe80::1:0:0:0:56` (la secuencia más larga de campos ceros está al final: 3 campos frente a 2 campos).

---

### Soluciones para el Ejercicio Guiado 3

* **Respuesta 3.1:**
  * **Número de Secuencia Inicial (ISN) del Cliente:** `3892019201`.
  * **Consumo de Secuencia de SYN:** Las flags de control `SYN` y `FIN` consumen implícitamente **1 número de secuencia lógico** en la contabilidad de la ventana TCP. Esto garantiza la entrega confiable y el acuse de recibo de la transición de estado SYN misma, forzando a que el número de acuse de recibo del paquete `SYN-ACK` de retorno se incremente a `3892019202` ($3892019201 + 1$).

* **Respuesta 3.2:**
  * **Error Generado:** `ICMP Destination Unreachable` (Tipo ICMPv4 `3`).
  * **Código ICMP:** Código `4` = `Fragmentation Needed and DF Flag Set`.
  * **Explicación:** Carga útil de 1473 bytes + 8 bytes de encabezado ICMP + 20 bytes de encabezado IPv4 = 1501 bytes. Debido a que 1501 bytes excede el límite de MTU de 1500 bytes y el bit Don't Fragment (`-D` / DF) está establecido, la interfaz de red descarta el paquete y emite ICMP Tipo 3, Código 4, devolviendo el valor de MTU del siguiente salto al emisor.

* **Respuesta 3.3:**
  * **Diferencia Operativa Clave:** `sockstat` consulta directamente las tablas de sockets abiertos del kernel (estructuras de red `sysctl`), mostrando rápidamente el Nombre del Proceso propietario (`COMMAND`), ID de Proceso (`PID`) y Descriptor de Archivo (`FD`). `netstat` consulta principalmente estadísticas generales de interfaz de red y tablas de enrutamiento.
  * **Utilidad para Correlación de PID:** `sockstat` mapea directamente un puerto abierto a su PID.

</details>