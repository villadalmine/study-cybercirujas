# 109.1 — Fundamentos de los protocolos de Internet

**LPIC-1, Examen 102-500 (v5.0) · Tema 109: Fundamentos de redes**

> Áreas de conocimiento clave: máscaras de red y notación CIDR · direcciones dotted-quad privadas frente a públicas · puertos y servicios TCP y UDP comunes · diferencias y características principales de UDP, TCP e ICMP · diferencias principales entre IPv4 e IPv6 · características básicas de IPv6.
> Términos y utilidades: `/etc/services`, IPv4, IPv6, subnetting, TCP, UDP, ICMP.

---

## 1. El problema de producción que este objetivo realmente resuelve

Todo incidente que empieza con *«el servicio está caído»* se resuelve en una de cuatro preguntas, y las cuatro viven en este objetivo:

1. **¿El plan de direccionamiento es sensato?** ¿La máquina tiene una dirección en la subred que cree tener, y la máscara coincide con la máscara del router?
2. **¿Hay camino?** Alcanzabilidad de capa 3, MTU a lo largo de ese camino, y el ICMP que hace observables ambas cosas.
3. **¿El transporte hace lo que asumiste?** La semántica de conexión, el backlog y el comportamiento de retransmisión de TCP no son la misma superficie de fallo que el fire-and-forget de UDP.
4. **¿El puerto es el que creés?** Un listener enlazado a `127.0.0.1:5432` y un listener enlazado a `0.0.0.0:5432` son indistinguibles en una salida de `ps` y completamente distintos en un postmortem.

El fallo arquitectónico que más cuesta en infraestructura real es la **colisión del espacio de direcciones**. No es exótico: es la causa más común de «la VPN funciona pero medio clúster es inalcanzable». Un patrón concreto y repetido:

- La LAN corporativa usa `10.0.0.0/8` porque alguien tecleó lo más corto que funcionaba en 2014.
- Se instala un clúster de Kubernetes con el valor por defecto de Flannel `podSubnet: 10.244.0.0/16` — dentro del `/8` de la LAN.
- Una VPN site-to-site entonces anuncia `10.0.0.0/8` al nodo.
- El nodo ahora tiene dos rutas que cubren `10.244.x.x`. La coincidencia por prefijo más largo te salva *solo* mientras la ruta del pod CIDR sea la más específica. El día que la VPN anuncie `10.244.0.0/16` explícitamente, la mitad del tráfico de pods se va por el túnel y desaparece.

El arreglo no es un comando — es un **plan de direccionamiento escrito antes del primer `ip addr add`**, y la capacidad de leer un prefijo y saber al instante si dos rangos se solapan. Esa habilidad es lo que construye la sección 2.

El segundo fallo arquitectónico recurrente es **bloquear ICMP «por seguridad»**. En IPv4 esto degrada el Path MTU Discovery a un agujero negro silencioso: los handshakes TCP se completan, las peticiones pequeñas funcionan, y la primera respuesta mayor que la MTU del enlace más pequeño se cuelga para siempre. En IPv6 es peor — ICMPv6 transporta Neighbor Discovery, así que filtrarlo no degrada la red, la *elimina*. La sección 4 cubre la mecánica; la sección 6 muestra las reglas de firewall que son correctas en lugar de supersticiosas.

---

## 2. Direccionamiento IPv4: máscaras, CIDR y subnetting

### 2.1 La dirección es un entero de 32 bits con un límite marcado

Una dirección IPv4 son 32 bits, escritos convencionalmente como cuatro octetos decimales (el «dotted quad»). Una **máscara de red** marca un límite: los bits iniciales son la porción de *red*, los bits finales la porción de *host*. La notación CIDR (RFC 4632) escribe la cantidad de bits iniciales en uno después de una barra — `/26` significa 26 bits de red, 6 bits de host.

Solo las máscaras *contiguas* son legales en el enrutamiento moderno. `255.255.255.192` (`/26`) es válida; `255.255.0.255` no es representable en CIDR y la pila de Linux la rechaza.

```
10.42.7.23/26

Address    10.42.7.23        00001010.00101010.00000111.00|010111
Netmask    255.255.255.192   11111111.11111111.11111111.11|000000
Wildcard   0.0.0.63          00000000.00000000.00000000.00|111111
                                                          ^ boundary at bit 26

Network    10.42.7.0/26      ...00|000000   (host bits all 0)
First host 10.42.7.1
Last host  10.42.7.62
Broadcast  10.42.7.63        ...00|111111   (host bits all 1)
```

Los tres valores derivados salen mecánicamente:

- **Dirección de red** = dirección AND máscara (bits de host a cero).
- **Dirección de broadcast** = dirección OR wildcard (bits de host a uno).
- **Hosts utilizables** = 2^(32−prefijo) − 2, porque las direcciones de red y de broadcast no son asignables a interfaces.

Verificá con `ipcalc`, que imprime exactamente esta descomposición:

```
$ ipcalc 10.42.7.23/26
Address:   10.42.7.23           00001010.00101010.00000111.00 010111
Netmask:   255.255.255.192 = 26 11111111.11111111.11111111.11 000000
Wildcard:  0.0.0.63             00000000.00000000.00000000.00 111111
=>
Network:   10.42.7.0/26         00001010.00101010.00000111.00 000000
HostMin:   10.42.7.1            00001010.00101010.00000111.00 000001
HostMax:   10.42.7.62           00001010.00101010.00000111.00 111110
Broadcast: 10.42.7.63           00001010.00101010.00000111.00 111111
Hosts/Net: 62                    Class A, Private Internet
```

> **Trampa de examen.** `ipcalc` todavía imprime «Class A». El direccionamiento con clases (A/B/C/D/E, máscaras fijas derivadas del primer octeto) fue superado por CIDR en 1993. La etiqueta de clase no te dice nada sobre la máscara en uso; `10.42.7.23/26` es un `/26` sin importar que `10.0.0.0` alguna vez tuviera un `/8` implícito. Conocé las clases para el vocabulario del examen, nunca para una decisión de diseño.

### 2.2 La tabla de prefijos que tenés que poder reproducir de memoria

| CIDR | Máscara | Wildcard | Direcciones | Hosts utilizables | /24s cubiertos | Uso típico en producción |
|---|---|---|---|---|---|---|
| `/8`  | 255.0.0.0       | 0.255.255.255 | 16 777 216 | 16 777 214 | 65 536 | Supernet RFC 1918; nunca un dominio de broadcast |
| `/12` | 255.240.0.0     | 0.15.255.255  | 1 048 576  | 1 048 574  | 4 096  | Bloque de asignación `172.16.0.0/12` |
| `/16` | 255.255.0.0     | 0.0.255.255   | 65 536     | 65 534     | 256    | Asignación de región / VPC, pod CIDR |
| `/20` | 255.255.240.0   | 0.0.15.255    | 4 096      | 4 094      | 16     | Porción de zona de disponibilidad |
| `/21` | 255.255.248.0   | 0.0.7.255     | 2 048      | 2 046      | 8      | Subred de tenant grande |
| `/22` | 255.255.252.0   | 0.0.3.255     | 1 024      | 1 022      | 4      | Subred de nodos en un clúster grande |
| `/23` | 255.255.254.0   | 0.0.1.255     | 512        | 510        | 2      | VLAN de servidores |
| `/24` | 255.255.255.0   | 0.0.0.255     | 256        | 254        | 1      | Unidad de VLAN por defecto |
| `/25` | 255.255.255.128 | 0.0.0.127     | 128        | 126        | ½      | VLAN dividida |
| `/26` | 255.255.255.192 | 0.0.0.63      | 64         | 62         | ¼      | Segmento de rack / gestión |
| `/27` | 255.255.255.224 | 0.0.0.31      | 32         | 30         | ⅛      | DMZ pequeña, pool de balanceadores |
| `/28` | 255.255.255.240 | 0.0.0.15      | 16         | 14         | 1/16   | Segmento de appliances |
| `/29` | 255.255.255.248 | 0.0.0.7       | 8          | 6          | 1/32   | Tránsito con reservas |
| `/30` | 255.255.255.252 | 0.0.0.3       | 4          | 2          | 1/64   | Enlace punto a punto clásico |
| `/31` | 255.255.255.254 | 0.0.0.1       | 2          | **2**      | 1/128  | Punto a punto, RFC 3021 (sin red/bcast) |
| `/32` | 255.255.255.255 | 0.0.0.0       | 1          | 1          | —      | Ruta de host, VIP de loopback, IP de servicio anycast |

Dos entradas rompen la regla del «−2» y ambas importan en producción:

- **`/31` (RFC 3021)** — en un enlace punto a punto no hay a quién hacerle broadcast, así que ambas direcciones son utilizables. Esto reduce a la mitad el consumo de direcciones de enlaces de tránsito de una fábrica grande. Linux lo soporta nativamente.
- **`/32`** — una ruta de host. Cada VIP anycast, cada dirección de servicio enlazada a `lo` en un diseño BGP-hasta-el-host, y cada entrada `ip route add <ip>/32 dev ...` es una de estas.

### 2.3 Subnetting resuelto de punta a punta

**Requisito.** Te dan `192.168.40.0/24` para una fila de datacenter y tenés que repartir: 100 servidores, 50 servidores, 25 servidores, 10 servidores y dos uplinks punto a punto. Asigná de mayor a menor (VLSM) para que los bloques queden alineados.

| Necesidad | Hosts requeridos | Prefijo mínimo | Tamaño de bloque | Asignación | Rango | Broadcast |
|---|---|---|---|---|---|---|
| Compute A | 100 | `/25` (126) | 128 | `192.168.40.0/25` | .1 – .126 | .127 |
| Compute B | 50 | `/26` (62) | 64 | `192.168.40.128/26` | .129 – .190 | .191 |
| Storage | 25 | `/27` (30) | 32 | `192.168.40.192/27` | .193 – .222 | .223 |
| Gestión | 10 | `/28` (14) | 16 | `192.168.40.224/28` | .225 – .238 | .239 |
| Uplink 1 | 2 | `/30` | 4 | `192.168.40.240/30` | .241 – .242 | .243 |
| Uplink 2 | 2 | `/30` | 4 | `192.168.40.244/30` | .245 – .246 | .247 |
| *Reservado* | — | — | 8 | `192.168.40.248/29` | .249 – .254 | .255 |

La regla de alineación que hace que esto funcione: **un bloque de tamaño `N` debe empezar en un múltiplo de `N`.** `192.168.40.128/26` es legal porque 128 es múltiplo de 64. `192.168.40.100/26` no es una dirección de red en absoluto — es un host dentro de `192.168.40.64/26`.

La habilidad complementaria es el **supernetting** (agregación de rutas). Cuatro `/24` adyacentes y alineados colapsan en un `/22`:

```
192.168.40.0/24   11000000.10101000.00101000.00000000
192.168.41.0/24   11000000.10101000.00101001.00000000
192.168.42.0/24   11000000.10101000.00101010.00000000
192.168.43.0/24   11000000.10101000.00101011.00000000
                  ^--------- 22 bits identical --------^
                  => 192.168.40.0/22
```

Por esto una tabla de enrutamiento en un dispositivo de borde tiene 40 líneas en vez de 4 000 — y por esto un plan de direccionamiento que asigna bloques de forma no contigua es un impuesto operativo permanente.

### 2.4 Privadas, públicas y los rangos de propósito especial

Una dirección **pública** es globalmente única y enrutable a través de Internet; la asignación fluye IANA → RIR (LACNIC, RIPE NCC, ARIN, APNIC, AFRINIC) → LIR/ISP → vos. Una dirección **privada** tiene garantizado *nunca* ser enrutada en la Internet pública, así que puede reutilizarse dentro de cada organización de forma independiente — a cambio de requerir NAT para llegar al exterior.

| Rango | CIDR | Tamaño | RFC | Comportamiento y significado en producción |
|---|---|---|---|---|
| Bloque privado clase A | `10.0.0.0/8` | 16,7 M | 1918 | El valor por defecto para datacenter y VPCs de nube. Nunca asignes el `/8` entero a un solo dominio de enrutamiento. |
| Bloque privado clase B | `172.16.0.0/12` | 1 M | 1918 | Abarca `172.16.0.0`–`172.31.255.255`. **`172.32.0.0` es pública.** El pool del bridge por defecto de Docker vive acá. |
| Bloque privado clase C | `192.168.0.0/16` | 65 k | 1918 | Valor por defecto de hogar/SOHO y laboratorio; evitalo en un DC porque el router de casa de cada cliente VPN colisiona con él. |
| NAT de operador (CGN) | `100.64.0.0/10` | 4 M | 6598 | NAT444 del lado del ISP. Reutilizado por proveedores de nube para su fábrica interna. **No** asumas que es tuyo. |
| Link-local (APIPA) | `169.254.0.0/16` | 65 k | 3927 | Autoasignada cuando DHCP falla. También el endpoint de metadatos de la nube `169.254.169.254`. Nunca enrutada. |
| Loopback | `127.0.0.0/8` | 16,7 M | 1122 | El `/8` entero, no solo `127.0.0.1`. `127.0.0.53` es el listener stub de `systemd-resolved`. |
| Multicast | `224.0.0.0/4` | 268 M | 5771 | `224.0.0.1` todos los hosts, `224.0.0.2` todos los routers, `224.0.0.5/6` OSPF, `224.0.0.251` mDNS. |
| Reservado / futuro | `240.0.0.0/4` | 268 M | 1112 | Históricamente inutilizable; algunas pilas ahora lo aceptan internamente. No enrutable en Internet. |
| Broadcast limitado | `255.255.255.255/32` | 1 | 919 | Nunca reenviada por un router. DHCP DISCOVER la usa. |
| Documentación | `192.0.2.0/24`, `198.51.100.0/24`, `203.0.113.0/24` | 3×256 | 5737 | TEST-NET-1/2/3. Usalas en cada runbook y diagrama — nunca una dirección real de un cliente. |
| Benchmarking | `198.18.0.0/15` | 131 k | 2544 | Rango de pruebas de dispositivos. Ocasionalmente filtrado por appliances. |
| No especificada | `0.0.0.0/32` | 1 | 1122 | «Este host». Como dirección de *bind* significa **todas** las direcciones locales. |
| Ruta por defecto | `0.0.0.0/0` | todo | — | Longitud de prefijo cero coincide con todo; siempre pierde la coincidencia por prefijo más largo frente a cualquier cosa más específica. |

> **Regla de diseño.** Elegí tu espacio RFC 1918 de una región de `10.0.0.0/8` que ningún router doméstico ni valor por defecto de fabricante ocupe. `10.0.0.0/24`, `192.168.0.0/24`, `192.168.1.0/24` y `172.17.0.0/16` (el bridge por defecto de Docker) son los cuatro prefijos más propensos a colisión que existen. Asignar `10.183.0.0/16` cuesta exactamente lo mismo y no va a colisionar con la laptop de un contratista.

NAT es la consecuencia del direccionamiento privado, y vale la pena ser preciso sobre lo que cuesta: rompe el direccionamiento extremo a extremo, requiere estado de conexión en un middlebox (un dominio de fallo y una tabla que se puede llenar), complica cualquier protocolo que lleve direcciones en su payload (FTP en modo activo, SIP), y hace que las conexiones entrantes requieran port forwarding explícito. IPv6 existe para eliminar esa categoría entera de problema.

---

## 3. IPv6: los fundamentos que cambian el comportamiento operativo

### 3.1 Notación y compresión

Una dirección IPv6 son **128 bits**, escritos como ocho grupos de cuatro dígitos hexadecimales separados por dos puntos. Se aplican dos reglas de compresión, y la RFC 5952 hace obligatoria la forma canónica para el tooling:

1. Los ceros iniciales de un grupo se omiten: `0db8` → `db8`, `0000` → `0`.
2. **Una** secuencia de grupos consecutivos todos en cero se reemplaza por `::`. Solo una, si no la expansión es ambigua. Preferí la secuencia más larga; en caso de empate, la más a la izquierda.

```
2001:0db8:0042:0007:0000:0000:0000:0023
2001:db8:42:7:0:0:0:23        (rule 1)
2001:db8:42:7::23             (rule 2)   <- canonical
```

La forma canónica también requiere hexadecimal en minúsculas. `2001:DB8::23` y `2001:db8::23` son la misma dirección; solo la segunda es canónica, y comparar como cadena formas no canónicas es una fuente real de bugs en herramientas de ACL.

En una URL la dirección va entre corchetes para que los dos puntos no choquen con el separador de puerto: `https://[2001:db8:42:7::23]:8443/healthz`.

### 3.2 Estructura de la dirección y ámbito

Una dirección global típica se descompone así:

```
2001:db8:42:7:5054:ff:fe1a:2b3c
|________________|_______________|
   64-bit prefix    64-bit Interface ID
 |_______|________|
  /48 site  subnet
  from RIR   ID (16 bits => 65 536 subnets)
```

El límite del `/64` es efectivamente ley arquitectónica: SLAAC, el multicast solicited-node de Neighbor Discovery y el direccionamiento de privacidad asumen todos un Interface ID de 64 bits. Hacer subnetting *por debajo* de `/64` en una LAN rompe la autoconfiguración. Se hace subnetting cortando el /48 en /64s, no tomando prestados bits de host.

| Prefijo | Nombre | Ámbito | Notas |
|---|---|---|---|
| `2000::/3` | Global unicast (GUA) | Global | Todo lo actualmente delegado por los RIR. |
| `fc00::/7` | Unique local (ULA) | Sitio | En la práctica `fd00::/8` — el bit L está puesto para asignación local, y los 40 bits siguientes deben generarse **aleatoriamente**. El análogo IPv6 de RFC 1918, sin NAT. |
| `fe80::/10` | Link-local (LLA) | Enlace | Autoconfigurada en **cada** interfaz IPv6, siempre presente. Transporta NDP, y es el siguiente salto de esencialmente toda ruta IPv6. Requiere un índice de zona: `fe80::1%enp1s0`. |
| `ff00::/8` | Multicast | varía | Reemplaza al broadcast por completo. `ff02::1` all-nodes, `ff02::2` all-routers, `ff02::1:2` agentes de relay/servidores DHCPv6, `ff02::1:ffXX:XXXX` solicited-node. |
| `::1/128` | Loopback | Host | Una dirección, no un `/8`. |
| `::/128` | No especificada | — | Dirección de origen durante DAD. Como dirección de bind, todas las direcciones locales. |
| `::ffff:0:0/96` | IPv4-mapped | — | `::ffff:10.42.7.23` — cómo un socket `AF_INET6` de doble pila reporta un peer IPv4. |
| `2001:db8::/32` | Documentación | — | RFC 3849. Usala en todas partes en la documentación. |
| `64:ff9b::/96` | NAT64 well-known | — | Prefijo de traducción RFC 6052. |

**No hay broadcast en IPv6.** Todo lo que era broadcast es ahora un grupo multicast con ámbito, lo que significa que una NIC lo filtra en hardware y los hosts no interesados nunca despiertan su CPU. Esto es una ganancia medible de consumo y de tasa de interrupciones en un segmento L2 denso.

### 3.3 Interface ID: EUI-64, direcciones de privacidad, direcciones estables

EUI-64 modificado deriva un Interface ID de 64 bits a partir de una MAC de 48 bits:

```
MAC              52:54:00:1a:2b:3c
1) split, insert ff:fe in the middle:
                 52:54:00 : ff:fe : 1a:2b:3c
2) flip the Universal/Local bit (bit 7 of the first octet):
   0x52 = 0101 0010  ->  0101 0000 = 0x50
=> Interface ID     5054:00ff:fe1a:2b3c
=> canonical        5054:ff:fe1a:2b3c

Full address with prefix 2001:db8:42:7::/64:
   2001:db8:42:7:5054:ff:fe1a:2b3c
Its solicited-node multicast group (ff02::1:ff + low 24 bits):
   ff02::1:ff1a:2b3c
```

EUI-64 filtra la MAC — y por lo tanto la identidad del hardware — en cada paquete que el host envía a todo el mundo. Dos mitigaciones, ambas estándar en Linux moderno:

- **Extensiones de privacidad (RFC 8981)** — una dirección *temporal* aleatoria y rotada periódicamente usada para conexiones salientes, junto a una dirección estable para las entrantes. Controlada por `net.ipv6.conf.<if>.use_tempaddr` (`2` = preferir la temporal para la selección de origen).
- **Direcciones stable-privacy (RFC 7217)** — un Interface ID estable por prefijo pero no derivado de la MAC. Es lo que producen `addr-gen-mode=stable-privacy` de NetworkManager y `IPv6LinkLocalAddressGenerationMode=stable-privacy` de `systemd-networkd`, y es el valor por defecto correcto para servidores: lo bastante estable para firewallear, lo bastante opaco para no filtrar la identidad del hardware.

### 3.4 Asignación de direcciones: SLAAC, DHCPv6 y los flags del RA

IPv6 tiene tres mecanismos que coexisten, y cuál se ejecuta lo deciden **bits de flag en el Router Advertisement**, no el cliente:

| Flags del RA | Comportamiento del cliente | Origen de la dirección | De dónde viene el DNS |
|---|---|---|---|
| `M=0 A=1 O=0` | SLAAC puro | El host construye su propia dirección desde el prefijo del RA | Opción RDNSS en el RA (RFC 8106) |
| `M=0 A=1 O=1` | SLAAC + DHCPv6 sin estado | El host construye su propia dirección | DHCPv6 (solo otra configuración) |
| `M=1 A=0` | DHCPv6 con estado | El servidor DHCPv6 asigna y lleva registro | DHCPv6 |
| Sin RA alguno | Solo link-local | Solo `fe80::/64` | nada |

Consecuencias operativas críticas:

- **Un host no puede obtener una ruta por defecto desde DHCPv6.** No hay opción «router» en DHCPv6; la puerta de enlace por defecto llega *únicamente* vía Router Advertisement. Una red donde los RA están filtrados pero DHCPv6 funciona produce hosts con direcciones globales y sin manera de salir del enlace.
- **La Duplicate Address Detection (DAD)** corre antes de que cualquier dirección sea usable — el host envía un Neighbor Solicitation para su propia dirección tentativa desde `::`. Si DAD falla, la dirección se marca como `dadfailed` y nunca se usa.
- Las direcciones llevan **tiempos de vida** (`valid_lft` / `preferred_lft`). Una dirección «preferred» se usa para conexiones nuevas; una «deprecated» mantiene vivas las conexiones existentes pero ya no se elige como origen. Esto es renumeración nativa y elegante — IPv4 no tiene equivalente.

### 3.5 Neighbor Discovery reemplaza a ARP — y es ICMPv6

| Función | Mecanismo IPv4 | Mecanismo IPv6 | Tipo ICMPv6 |
|---|---|---|---|
| Resolución L3 → L2 | ARP (EtherType 0x0806, protocolo separado) | Neighbor Solicitation / Advertisement | 135 / 136 |
| Descubrimiento de routers | ICMP Router Discovery (raro) u opción DHCP 3 | Router Solicitation / Advertisement | 133 / 134 |
| Notificación de mejor camino | ICMP Redirect (tipo 5) | Redirect | 137 |
| Detección de duplicados | ARP gratuito (informativo) | DAD (obligatorio, parte de NS) | 135 |
| Autoconfiguración de direcciones | Solo DHCP | SLAAC vía prefijo del RA | 134 |

Como todo esto es ICMPv6, **un firewall que descarta ICMPv6 destruye el enlace**. La RFC 4890 especifica exactamente qué debe permitirse; la sección 6.4 lo implementa.

### 3.6 IPv4 frente a IPv6 — la tabla de comparación a memorizar

| Dimensión | IPv4 | IPv6 | Consecuencia operativa |
|---|---|---|---|
| Tamaño de dirección | 32 bits (~4,3×10⁹) | 128 bits (~3,4×10³⁸) | Direccionamiento extremo a extremo sin NAT |
| Notación | decimal con puntos `10.42.7.23` | hexadecimal con dos puntos `2001:db8:42:7::23` | Corchetes en URLs; canonicalizar antes de comparar |
| Cabecera | 20–60 bytes, **variable** (opciones, campo IHL) | **40 bytes fijos** + cadena de extension headers | La cabecera fija permite reenvío en hardware más barato |
| Checksum de cabecera | presente, recalculado en cada salto | **eliminado** | El camino de reenvío del router es más barato; la integridad se delega a L2 y L4 |
| Checksum de L4 | opcional para UDP | **obligatorio** para UDP | Un datagrama UDP/IPv6 con checksum 0 se descarta |
| Fragmentación | por el origen *y* por los routers | **solo el origen**, vía Fragment extension header | Los routers devuelven ICMPv6 tipo 2 en su lugar; PMTUD no es opcional |
| MTU mínima | 576 | **1280** | Cualquier túnel debe entregar ≥1280 o IPv6 se rompe |
| Broadcast | sí (`255.255.255.255`, bcast de subred) | **ninguno** — solo multicast | Menor carga de interrupciones de NIC en L2 grandes |
| Resolución L2 | ARP | NDP sobre ICMPv6 | No se puede filtrar ICMPv6 en bloque |
| Autoconfiguración | DHCP (o fallback APIPA) | SLAAC, DHCPv6, o ambos | Ruta por defecto solo vía RA |
| Direcciones por interfaz | típicamente una | **muchas por diseño** (LLA + GUA + ULA + temporal) | La selección de dirección de origen (RFC 6724) es un subsistema real |
| IPsec | añadido opcional | originalmente de implementación obligatoria | En la práctica: usá WireGuard/TLS en cualquiera de los dos casos |
| Campo de QoS | ToS / DSCP | Traffic Class + **Flow Label** de 20 bits | El Flow Label permite hashing ECMP sin estado en flujos cifrados |
| NAT | necesidad ubicua | existe NPTv6, desaconsejado | El firewalling reemplaza a NAT como frontera de seguridad |
| Loopback | `127.0.0.0/8` | `::1/128` | Un `/8` entero frente a exactamente una dirección |
| Espacio privado | RFC 1918 | ULA `fd00::/8` | ULA se genera aleatoriamente, no se elige |

**Doble pila** es el modo de despliegue práctico: la interfaz tiene ambas familias, DNS devuelve tanto `A` como `AAAA`, y el cliente usa **Happy Eyeballs v2 (RFC 8305)** — inicia la conexión AAAA, corre una conexión A ~250 ms después, y se queda con la que se complete primero. Esto significa que un camino IPv6 roto se manifiesta como *latencia*, no como fallo, que es precisamente por qué sigue roto durante meses. La sección 7 muestra cómo probar qué familia usó realmente una conexión.

---

## 4. Transporte y control: TCP, UDP, ICMP

### 4.1 El modelo por capas en una tabla

| Capa (TCP/IP) | Equivalente OSI | PDU | Direccionamiento | Artefactos de Linux |
|---|---|---|---|---|
| Aplicación | 5–7 | mensaje | URI, nombre de servicio | `/etc/services`, configuración del listener |
| Transporte | 4 | segmento (TCP) / datagrama (UDP) | puerto (16 bits) | `ss`, sysctls `net.ipv4.tcp_*` |
| Internet | 3 | paquete | dirección IP | `ip route`, `ip addr`, ICMP |
| Enlace | 1–2 | trama | MAC | `ip link`, `ip neigh`, `ethtool` |

### 4.2 TCP — fiable, ordenado, orientado a conexión

TCP (RFC 9293, que consolida la RFC 793) provee un flujo de bytes fiable: los números de secuencia ordenan y detectan pérdida, los ACK acumulativos (más SACK) confirman la entrega, la retransmisión recupera la pérdida, las ventanas deslizantes proveen control de flujo, y el control de congestión (`cubic` por defecto en Linux, `bbr` donde esté desplegado) provee equidad de red.

**Establecimiento de la conexión — el handshake de tres vías:**

```
Client                                         Server
  |  SYN   seq=x                                  |   server socket: LISTEN
  |---------------------------------------------->|   -> SYN-RECEIVED (SYN queue)
  |  SYN,ACK  seq=y ack=x+1                       |
  |<----------------------------------------------|
  |  ACK   seq=x+1 ack=y+1                        |   -> ESTABLISHED (accept queue)
  |---------------------------------------------->|
  |                  ESTABLISHED                  |
```

**Cierre — de cuatro vías, con la asimetría que importa:**

```
  |  FIN                --> |  ESTABLISHED -> CLOSE-WAIT
  |  <-- ACK                |
  |  <-- FIN                |  CLOSE-WAIT -> LAST-ACK
  |  ACK                --> |  -> CLOSED
  FIN-WAIT-1/2 -> TIME-WAIT (2×MSL, 60 s on Linux) -> CLOSED
```

Los once estados, y qué significa cada uno cuando lo ves en `ss`:

| Estado | Significado | Qué te dice una pila de ellos |
|---|---|---|
| `LISTEN` | Socket pasivo esperando conexiones | Normal. Revisá la dirección de bind, no solo el puerto. |
| `SYN-SENT` | El cliente envió SYN, sin respuesta | Firewall descartando (no rechazando), o dirección equivocada |
| `SYN-RECV` | Semiabierta en el servidor | SYN flood, o inanición de accept() |
| `ESTABLISHED` | Los datos pueden fluir | Normal |
| `FIN-WAIT-1` / `FIN-WAIT-2` | Cierre local enviado; el peer no cerró | La aplicación del peer no llama a `close()` |
| `CLOSE-WAIT` | **El peer cerró; la app local no** | Casi siempre un bug de la aplicación — un descriptor de archivo filtrado. El kernel no puede arreglarlo. |
| `LAST-ACK` | Cierre local enviado después del del peer | Transitorio |
| `TIME-WAIT` | Esperando 2×MSL para absorber segmentos extraviados | Normal en el lado que cierra primero; solo patológico en las decenas de miles |
| `CLOSING` | Cierre simultáneo | Raro |
| `CLOSED` | Sin conexión | — |

**Campos de la cabecera que aparecen en diagnósticos reales:** puerto de origen/destino (16 bits cada uno), números de secuencia y de acuse de 32 bits, data offset, flags (`SYN` `ACK` `FIN` `RST` `PSH` `URG` `ECE` `CWR`), ventana de 16 bits (escalada por la opción window-scale hasta 1 GB), checksum, puntero urgente. Opciones negociadas en el SYN: **MSS** (Maximum Segment Size), **window scale**, **SACK permitted**, **timestamps**.

**MSS frente a MTU** — la relación que causa la mitad de todos los tickets de «la red está lenta»:

```
MSS(IPv4) = MTU − 20 (IP header) − 20 (TCP header) = 1500 − 40 = 1460
MSS(IPv6) = MTU − 40 (IP header) − 20 (TCP header) = 1500 − 60 = 1440
Over a WireGuard tunnel (MTU 1420): MSS = 1380 / 1360
```

### 4.3 UDP — datagramas sin conexión

UDP (RFC 768) es una cabecera de 8 bytes sobre IP: puerto de origen, puerto de destino, longitud, checksum. Sin handshake, sin ordenación, sin retransmisión, sin control de flujo ni de congestión. Lo que te da es **la ausencia de bloqueo head-of-line y la ausencia de estado** — que es exactamente lo que quieren DNS, NTP, SNMP, syslog, VXLAN, WireGuard y QUIC.

Los dos hechos de UDP que más a menudo se entienden mal:

- **El checksum es opcional en IPv4** (un checksum en cero significa «no calculado») **y obligatorio en IPv6**, porque IPv6 eliminó el checksum de la capa de red.
- **UDP no tiene negociación de MSS**, así que un datagrama mayor que la MTU del camino se fragmenta en la capa IP. Si algún middlebox descarta fragmentos — algo extremadamente común — las respuestas DNS grandes (DNSSEC, `TXT` grandes) desaparecen mientras las pequeñas funcionan. Por esto los tamaños de buffer de EDNS0 se redujeron a 1232 bytes y por esto DNS cae de vuelta a TCP.

### 4.4 ICMP — el plano de control de IP

ICMP (RFC 792 para IPv4, RFC 4443 para ICMPv6) **no** es un protocolo de transporte: no lleva puertos ni payload de aplicación. Es el propio canal de señalización de IP — reporte de errores y diagnóstico.

| Propósito | Tipo/código ICMPv4 | Tipo/código ICMPv6 | Por qué no debés bloquearlo |
|---|---|---|---|
| Echo request / reply | 8 / 0 | 128 / 129 | Alcanzabilidad básica |
| Destination unreachable — red | 3/0 | 1/0 | El fallo de enrutamiento se reporta, no es silencioso |
| Destination unreachable — host | 3/1 | 1/3 | — |
| Destination unreachable — puerto | 3/3 | 1/4 | Cómo terminan `traceroute` y los escaneos UDP |
| **Fragmentation needed, DF set** | **3/4** | — | **Path MTU Discovery en IPv4** |
| **Packet Too Big** | — | **2** | **Path MTU Discovery en IPv6 — obligatorio** |
| Time exceeded (TTL/hop limit) | 11/0 | 3/0 | Cómo funciona `traceroute` siquiera |
| Parameter problem | 12 | 4 | Reporte de cabecera malformada |
| Redirect | 5 | 137 | Notificación de mejor primer salto |
| Neighbor/Router Discovery | *(ARP, separado)* | **133–137** | **Sin esto IPv6 no funciona** |

**El agujero negro de PMTU**, completo, porque es el diagnóstico de mayor valor en este objetivo:

1. Un host envía un segmento TCP de 1500 bytes con el bit **DF (Don't Fragment)** puesto — Linux pone DF por defecto (`net.ipv4.ip_no_pmtu_disc=0`).
2. Un enlace intermedio (túnel GRE, PPPoE, IPsec, WireGuard) tiene MTU 1400.
3. El router **debe** descartar el paquete y devolver **ICMP tipo 3 código 4** llevando la MTU del siguiente salto.
4. Un firewall bloquea ese ICMP.
5. El emisor nunca se entera. TCP retransmite el mismo segmento sobredimensionado para siempre.

Firma de los síntomas: el handshake tiene éxito, `curl -I` (respuesta pequeña) funciona, `curl` de la página completa se cuelga, `ssh` conecta y luego se congela en el banner. Diagnóstico en la sección 7.4.

### 4.5 Compromisos entre TCP, UDP e ICMP

| Propiedad | TCP | UDP | ICMP |
|---|---|---|---|
| Número de protocolo IP | 6 | 17 | 1 (v4) / 58 (v6) |
| Conexión | orientado a conexión (handshake de 3 vías) | sin conexión | sin conexión |
| Tamaño de cabecera | 20–60 bytes | **8 bytes** | 8 bytes + copia del payload |
| Puertos | sí | sí | **no** |
| Fiabilidad | entrega garantizada + ordenación | ninguna | ninguna |
| Ordenación | sí (números de secuencia) | ninguna | ninguna |
| Control de flujo | ventana deslizante | ninguno | ninguno |
| Control de congestión | sí (cubic/bbr) | ninguno — responsabilidad de la app | limitado en tasa por el kernel |
| Multicast / broadcast | **no** (solo unicast) | sí | sí (multicast v6) |
| Bloqueo head-of-line | sí (un flujo) | no | n/a |
| Latencia del handshake | 1 RTT (+2 para TLS 1.2, +1 para TLS 1.3) | 0 RTT | 0 RTT |
| Sobrecarga por mensaje pequeño | alta | mínima | mínima |
| Atravesar NAT/firewall | fácil (el estado es explícito) | más difícil (pseudoestado, timeouts cortos) | frecuentemente bloqueado |
| Estado del kernel por flujo | TCB completo, TIME-WAIT tras el cierre | ninguno | ninguno |
| Uso típico | HTTP/1.1–2, SSH, SMTP, LDAP, BD | DNS, NTP, SNMP, syslog, VXLAN, QUIC/HTTP-3, VoIP | ping, traceroute, PMTUD, NDP |
| Modo de fallo cuando el camino está mal | lento (retransmisión + backoff) | pérdida silenciosa | invisible — y rompe a los otros dos |

> **La advertencia de QUIC.** HTTP/3 corre sobre **UDP puerto 443** y reconstruye la fiabilidad, la ordenación, el control de congestión y TLS en espacio de usuario. Las reglas de firewall que permiten `tcp dport 443` y nada más fuerzan silenciosamente a cada cliente moderno de vuelta a HTTP/2 — otra vez una regresión de latencia, no una caída, y por lo tanto invisible durante meses.

---

## 5. Puertos y `/etc/services`

### 5.1 Rangos de puertos

Un puerto es un entero sin signo de 16 bits: 0–65535. IANA divide el espacio:

| Rango | Nombre | Privilegio de bind | Notas |
|---|---|---|---|
| 0–1023 | Well-known / Sistema | Requiere `CAP_NET_BIND_SERVICE` (históricamente root) | Asignados por IANA. El puerto 0 significa «kernel, elegí uno». |
| 1024–49151 | Registrados / Usuario | sin privilegios | Registrados en IANA pero no privilegiados |
| 49152–65535 | Dinámicos / Privados / Efímeros | sin privilegios | Rango efímero sugerido por IANA |

Linux **no** usa el rango efímero de IANA por defecto:

```
$ sysctl net.ipv4.ip_local_port_range
net.ipv4.ip_local_port_range = 32768	60999
```

Eso son 28 231 puertos salientes **por tupla (IP origen, IP destino, puerto destino)**. Un proxy inverso ocupado hablando con un solo upstream puede agotarlo; los síntomas son `EADDRNOTAVAIL` y fallos de conexión bajo carga. Los arreglos, en orden de preferencia: agregar direcciones upstream, habilitar reutilización de conexiones/keep-alive, ampliar el rango, y luego `net.ipv4.tcp_tw_reuse=1` (seguro para salientes con timestamps habilitados — a diferencia del hace tiempo eliminado `tcp_tw_recycle`, que nunca fue seguro detrás de NAT).

Los kernels modernos otorgan `CAP_NET_BIND_SERVICE` por servicio vía systemd (`AmbientCapabilities=`), o podés bajar el umbral globalmente:

```
$ sysctl net.ipv4.ip_unprivileged_port_start
net.ipv4.ip_unprivileged_port_start = 1024
```

### 5.2 La tabla de puertos que exige el examen

| Puerto | Proto | Servicio | Nombre en `/etc/services` | Nota de producción |
|---|---|---|---|---|
| **20** | TCP | FTP data | `ftp-data` | Modo activo: el **servidor** inicia desde :20 de vuelta hacia el cliente. Por esto el FTP activo muere detrás de NAT. |
| **21** | TCP | FTP control | `ftp` | Credenciales en texto plano. El modo pasivo usa un puerto dinámico alto para los datos. |
| **22** | TCP | SSH | `ssh` | También SFTP y SCP — un puerto, sin canal de datos separado. |
| **23** | TCP | Telnet | `telnet` | Texto plano, incluida la contraseña. No debería existir en una red de producción. |
| **25** | TCP | SMTP | `smtp` | Relay MTA a MTA. Comúnmente bloqueado en salida por proveedores de nube e ISPs residenciales. |
| **53** | **TCP + UDP** | DNS | `domain` | UDP para consultas; **TCP para transferencias de zona (AXFR) y cualquier respuesta que exceda el buffer UDP**. Bloquear TCP/53 rompe DNSSEC. |
| **80** | TCP | HTTP | `http` | Texto plano. Mantenelo solo para ACME `http-01` y un 301 a HTTPS. |
| **110** | TCP | POP3 | `pop3` | Texto plano; descarga y típicamente borra. |
| **123** | UDP | NTP | `ntp` | Sincronización de hora. Un servidor NTP abierto con `monlist` es un amplificador de DDoS — restringilo. |
| **139** | TCP | NetBIOS Session Service | `netbios-ssn` | Transporte SMB heredado. El SMB moderno es 445 (`microsoft-ds`). |
| **143** | TCP | IMAP | `imap` | Texto plano; estado del buzón del lado del servidor. |
| **161** | UDP | SNMP | `snmp` | Sondeo. Las community strings de v1/v2c van en texto plano — usá v3. |
| **162** | UDP | SNMP trap | `snmptrap` | Notificaciones agente→gestor. Dirección opuesta a la de 161. |
| **389** | TCP + UDP | LDAP | `ldap` | Texto plano, o TLS vía **STARTTLS en el mismo puerto**. |
| **443** | **TCP + UDP** | HTTPS | `https` | TCP para HTTP/1.1 y HTTP/2; **UDP para HTTP/3 (QUIC)**. |
| **465** | TCP | SMTPS / submissions | `submissions`, `urd`, `smtps` | Envío de correo con TLS implícito (RFC 8314). Históricamente deprecado, luego rehabilitado. Comparar con 587 = envío con STARTTLS. |
| **514** | **UDP** (syslog) / TCP (`shell`) | syslog / rsh | `syslog` (udp), `shell` (tcp) | El logging remoto clásico es UDP — con pérdidas por diseño. TCP/514 es el `rsh` heredado. Moderno: syslog sobre TLS en TCP/6514. |
| **636** | TCP | LDAPS | `ldaps` | LDAP con TLS implícito. |
| **993** | TCP | IMAPS | `imaps` | IMAP con TLS implícito. |
| **995** | TCP | POP3S | `pop3s` | POP3 con TLS implícito. |

Vale la pena conocerlos más allá de la lista requerida, porque aparecen en todo despliegue real:

| Puerto | Proto | Servicio | Nota |
|---|---|---|---|
| 67 / 68 | UDP | Servidor / cliente DHCP | 546/547 para DHCPv6 |
| 69 | UDP | TFTP | Arranque PXE |
| 179 | TCP | BGP | Presente en cada leaf/spine y en Calico/MetalLB |
| 445 | TCP | SMB sobre TCP | El reemplazo moderno de 139 |
| 587 | TCP | Envío de correo (STARTTLS) | Contrastar con 465 |
| 3306 / 5432 | TCP | MySQL / PostgreSQL | Nunca exponer a Internet |
| 6443 | TCP | Servidor de API de Kubernetes | |
| 2379 / 2380 | TCP | etcd cliente / peer | |
| 51820 | UDP | WireGuard | Por defecto; elegido por el usuario en la práctica |

### 5.3 Qué es `/etc/services` — y qué no es

`/etc/services` es la base de datos local que mapea **nombres de servicio a pares puerto/protocolo**. Se consulta a través de la base de datos `services` de NSS, así que un servicio de directorio puede extenderlo o reemplazarlo:

```
$ grep -E '^(services|hosts):' /etc/nsswitch.conf
hosts:          files mdns4_minimal [NOTFOUND=return] dns myhostname
services:       files
```

Formato: `nombre  puerto/protocolo  [alias...]  # comentario`

```
$ grep -E '^(ssh|domain|https|imaps|submissions|syslog|snmptrap)\b' /etc/services
ssh		22/tcp				# SSH Remote Login Protocol
domain		53/tcp
domain		53/udp
https		443/tcp
https		443/udp				# HTTP/3
imaps		993/tcp				# IMAP over SSL
submissions	465/tcp		ssmtp smtps urd	# Submission over TLS [RFC8314]
syslog		514/udp
snmptrap	162/udp		snmp-trap
```

Consultalo a través de la librería en vez de hacer grep del archivo — esto respeta NSS y acierta con el protocolo:

```
$ getent services 993/tcp
imaps                 993/tcp

$ getent services ldaps
ldaps                 636/tcp

$ getent services 514/udp
syslog                514/udp
```

**Lo que no es:** editar `/etc/services` no abre un puerto, no cierra un puerto, no arranca un demonio, ni cambia a qué está enlazado ningún proceso en ejecución. Es una tabla de *nombres*. Afecta a:

- Los nombres simbólicos que imprimen `ss`, `netstat`, `lsof` y `nmap` (por eso usás `ss -n` cuando querés la verdad).
- Los programas que llaman a `getservbyname()`/`getaddrinfo()` con una cadena de servicio — incluidos `nc host imaps` y algunas configuraciones de `xinetd`/activación por socket.

```
$ ss -tln | head -4
State   Recv-Q  Send-Q   Local Address:Port    Peer Address:Port
LISTEN  0       4096     127.0.0.53%lo:domain      0.0.0.0:*
LISTEN  0       128            0.0.0.0:ssh         0.0.0.0:*
LISTEN  0       511                  *:https             *:*

$ ss -tln -n | head -4          # -n: never resolve names, show real numbers
State   Recv-Q  Send-Q   Local Address:Port    Peer Address:Port
LISTEN  0       4096     127.0.0.53%lo:53          0.0.0.0:*
LISTEN  0       128            0.0.0.0:22          0.0.0.0:*
LISTEN  0       511                  *:443               *:*
```

> **Leé la dirección de bind, no solo el puerto.** `127.0.0.53%lo:53` es alcanzable únicamente desde el propio host. `0.0.0.0:22` es cada dirección IPv4 de la máquina. `*:443` con `*` en ambas columnas es un socket IPv6 de doble pila aceptando IPv4 vía mapeo `::ffff:` (`net.ipv6.bindv6only=0`). Confundir estos tres es el reporte falso de «el firewall está roto» más común.

---

## 6. Configuraciones de producción completas

Todo lo de abajo es desplegable tal cual está escrito. Las direcciones usan los rangos de documentación de RFC 5737 / RFC 3849.

### 6.1 Netplan — servidor de doble pila con IPv4 estática e IPv6 SLAAC más estática

`/etc/netplan/01-datacentre.yaml` (modo `0600`, o netplan avisa):

```yaml
# /etc/netplan/01-datacentre.yaml
# Dual-stack production host. Apply with:  netplan try  (auto-reverts in 120 s)
network:
  version: 2
  renderer: networkd

  ethernets:
    enp1s0:
      match:
        macaddress: "52:54:00:1a:2b:3c"
      set-name: enp1s0
      dhcp4: false
      dhcp6: false
      accept-ra: true              # default route + prefix arrive via RA, never via DHCPv6
      ipv6-privacy: false          # servers keep stable addresses; clients set true
      link-local: [ipv6]
      mtu: 1500
      addresses:
        - 198.51.100.23/26
        - "2001:db8:42:7::23/64"
      nameservers:
        addresses:
          - 198.51.100.5
          - 198.51.100.6
          - "2001:db8:42:7::5"
        search:
          - dc1.example.net
          - example.net
      routes:
        - to: default
          via: 198.51.100.1
          metric: 100
          on-link: true
        - to: "default"
          via: "2001:db8:42:7::1"
          metric: 100
        # Storage network reachable only through the ToR's secondary address
        - to: 10.183.64.0/20
          via: 198.51.100.2
          metric: 200

    enp2s0:
      dhcp4: false
      dhcp6: false
      accept-ra: false
      mtu: 9000                    # jumbo frames on the storage fabric
      addresses:
        - 10.183.64.23/24
      routes:
        - to: 10.183.0.0/16
          via: 10.183.64.1
          metric: 50

  bonds:
    bond0:
      interfaces: [enp3s0, enp4s0]
      parameters:
        mode: 802.3ad
        lacp-rate: fast
        mii-monitor-interval: 100
        transmit-hash-policy: layer3+4
      dhcp4: false
      dhcp6: false
      accept-ra: false

  vlans:
    bond0.310:
      id: 310
      link: bond0
      addresses:
        - 203.0.113.23/28
        - "2001:db8:42:310::23/64"
      accept-ra: false
      routes:
        - to: 0.0.0.0/0
          via: 203.0.113.17
          metric: 300
          table: 310
      routing-policy:
        - from: 203.0.113.23/32
          table: 310
          priority: 32000
```

```
$ sudo netplan generate && sudo netplan try
Do you want to keep these settings?

Press ENTER before the timeout to accept the new configuration

Changes will revert in 120 seconds
Configuration accepted.
```

### 6.2 systemd-networkd — el mismo host sin Netplan

```ini
# /etc/systemd/network/10-enp1s0.network
[Match]
Name=enp1s0

[Link]
MTUBytes=1500
RequiredForOnline=routable

[Network]
Description=Front-end dual-stack interface
DHCP=no
IPv6AcceptRA=yes
LinkLocalAddressing=ipv6
IPv6LinkLocalAddressGenerationMode=stable-privacy
IPv6PrivacyExtensions=no
IPForward=no
DNS=198.51.100.5
DNS=2001:db8:42:7::5
Domains=dc1.example.net example.net

[Address]
Address=198.51.100.23/26

[Address]
Address=2001:db8:42:7::23/64

[Route]
Gateway=198.51.100.1
Destination=0.0.0.0/0
Metric=100

[Route]
Gateway=2001:db8:42:7::1
Destination=::/0
Metric=100

[IPv6AcceptRA]
UseDNS=yes
UseDomains=yes
DHCPv6Client=always
```

```
$ sudo systemctl restart systemd-networkd
$ networkctl status enp1s0
● 2: enp1s0
                   Link File: /usr/lib/systemd/network/99-default.link
                Network File: /etc/systemd/network/10-enp1s0.network
                       State: routable (configured)
                Online state: online
                        Type: ether
                        Path: pci-0000:00:01.0
                      Driver: virtio_net
                      Vendor: Red Hat, Inc.
                  HW Address: 52:54:00:1a:2b:3c
                         MTU: 1500 (min: 68, max: 65535)
                     Address: 198.51.100.23
                              2001:db8:42:7::23
                              2001:db8:42:7:5054:ff:fe1a:2b3c
                              fe80::9c4e:1f7a:2b19:64d3
                     Gateway: 198.51.100.1
                              2001:db8:42:7::1 (Cisco Systems)
                         DNS: 198.51.100.5
                              2001:db8:42:7::5
              Search Domains: dc1.example.net
                              example.net
```

### 6.3 Ajuste del kernel — los sysctls que pertenecen a este objetivo

```ini
# /etc/sysctl.d/60-network-baseline.conf
# Apply: sysctl --system   Verify: sysctl -a --pattern 'net\.(ipv4|ipv6|core)'

#### Forwarding — enable ONLY on a router/NAT gateway/Kubernetes node
net.ipv4.ip_forward                     = 0
net.ipv6.conf.all.forwarding            = 0

#### Anti-spoofing: strict reverse-path filter (RFC 3704). Use 2 (loose)
#### on multihomed or asymmetric-routing hosts, never 0.
net.ipv4.conf.all.rp_filter             = 1
net.ipv4.conf.default.rp_filter         = 1

#### Never accept source routing or ICMP redirects on a server
net.ipv4.conf.all.accept_source_route   = 0
net.ipv6.conf.all.accept_source_route   = 0
net.ipv4.conf.all.accept_redirects      = 0
net.ipv6.conf.all.accept_redirects      = 0
net.ipv4.conf.all.send_redirects        = 0
net.ipv4.conf.all.log_martians          = 1

#### ICMP: answer echo (do NOT set icmp_echo_ignore_all — it blinds your NOC),
#### but ignore broadcast echo so the host cannot be a smurf amplifier.
net.ipv4.icmp_echo_ignore_all           = 0
net.ipv4.icmp_echo_ignore_broadcasts    = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

#### TCP connection setup
net.ipv4.tcp_syncookies                 = 1      # survive SYN floods
net.ipv4.tcp_max_syn_backlog            = 8192   # SYN queue (half-open)
net.core.somaxconn                      = 4096   # accept-queue ceiling; app must
                                                 # still pass a matching listen(2) backlog
net.ipv4.tcp_abort_on_overflow          = 0      # drop, let the client retry

#### Ephemeral ports and TIME-WAIT reuse (outbound-heavy proxies)
net.ipv4.ip_local_port_range            = 16384 65535
net.ipv4.tcp_tw_reuse                   = 1      # safe for OUTBOUND with timestamps
net.ipv4.tcp_fin_timeout                = 30
net.ipv4.tcp_timestamps                 = 1

#### Path MTU Discovery: probe around ICMP black holes instead of hanging
net.ipv4.tcp_mtu_probing                = 1
net.ipv4.ip_no_pmtu_disc                = 0

#### Buffers and congestion control
net.core.rmem_max                       = 16777216
net.core.wmem_max                       = 16777216
net.ipv4.tcp_rmem                       = 4096 131072 16777216
net.ipv4.tcp_wmem                       = 4096  16384 16777216
net.ipv4.tcp_congestion_control         = bbr
net.core.default_qdisc                  = fq

#### IPv6: keep it on. Disabling it is not a security control, it is a
#### guarantee that the day it is needed nothing works.
net.ipv6.conf.all.disable_ipv6          = 0
net.ipv6.conf.all.accept_ra             = 1
net.ipv6.conf.default.accept_ra         = 1
net.ipv6.conf.all.accept_ra_defrtr      = 1
net.ipv6.conf.all.use_tempaddr          = 0      # 2 on workstations
net.ipv6.conf.all.addr_gen_mode         = 3      # stable-privacy (RFC 7217)
net.ipv6.conf.all.dad_transmits         = 1
```

```
$ sudo sysctl --system
* Applying /etc/sysctl.d/60-network-baseline.conf ...
net.ipv4.ip_forward = 0
net.ipv4.conf.all.rp_filter = 1
net.ipv4.tcp_syncookies = 1
net.core.somaxconn = 4096
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_congestion_control = bbr
...
* Applying /etc/sysctl.conf ...

$ sysctl net.ipv4.tcp_congestion_control net.core.somaxconn
net.ipv4.tcp_congestion_control = bbr
net.core.somaxconn = 4096
```

### 6.4 nftables — un ruleset de doble pila correcto, incluido el ICMP que debe pasar

```nft
#!/usr/sbin/nft -f
# /etc/nftables.conf
# Load: nft -f /etc/nftables.conf     Persist: systemctl enable --now nftables

flush ruleset

table inet filter {

    # ---- named sets: edit these, not the rules -------------------------
    set admin_v4 {
        type ipv4_addr
        flags interval
        elements = { 198.51.100.0/26, 10.183.0.0/16 }
    }
    set admin_v6 {
        type ipv6_addr
        flags interval
        elements = { 2001:db8:42::/48 }
    }
    set public_tcp {
        type inet_service
        elements = { 80, 443 }          # http, https
    }
    set monitoring_v4 {
        type ipv4_addr
        flags interval
        elements = { 198.51.100.64/28 }
    }

    chain input {
        type filter hook input priority filter; policy drop;

        # 1. Fast path for known flows
        ct state established,related accept
        ct state invalid drop comment "no state, no service"

        # 2. Loopback is trusted; anything claiming to be lo from elsewhere is spoofed
        iif lo accept
        iif != lo ip  daddr 127.0.0.0/8 drop
        iif != lo ip6 daddr ::1/128     drop

        # 3. ICMPv4: keep PMTUD and diagnostics alive
        ip protocol icmp icmp type {
            echo-request,
            destination-unreachable,     # includes 3/4 frag-needed => PMTUD
            time-exceeded,
            parameter-problem
        } limit rate 20/second burst 40 packets accept

        # 4. ICMPv6 per RFC 4890. Dropping this BREAKS IPv6 — it is not optional.
        #    NDP messages must be accepted with hop limit 255 (link-local only).
        ip6 nexthdr icmpv6 icmpv6 type {
            nd-neighbor-solicit,
            nd-neighbor-advert,
            nd-router-solicit,
            nd-router-advert
        } ip6 hoplimit 255 accept

        ip6 nexthdr icmpv6 icmpv6 type {
            destination-unreachable,
            packet-too-big,             # PMTUD for IPv6 — mandatory
            time-exceeded,
            parameter-problem
        } accept

        ip6 nexthdr icmpv6 icmpv6 type echo-request \
            limit rate 20/second burst 40 packets accept

        # Multicast Listener Discovery
        ip6 nexthdr icmpv6 icmpv6 type {
            mld-listener-query,
            mld-listener-report,
            mld-listener-done
        } ip6 saddr fe80::/10 accept

        # 5. DHCPv6 client replies (server -> client)
        ip6 saddr fe80::/10 udp sport 547 udp dport 546 accept

        # 6. SSH — administrative networks only, with brute-force damping
        tcp dport 22 ip  saddr @admin_v4 ct state new \
            limit rate 6/minute burst 6 packets accept
        tcp dport 22 ip6 saddr @admin_v6 ct state new \
            limit rate 6/minute burst 6 packets accept

        # 7. Public services: HTTP/HTTPS over TCP *and* HTTP/3 over UDP/443
        tcp dport @public_tcp accept
        udp dport 443 accept comment "HTTP/3 QUIC — omit this and clients silently downgrade"

        # 8. SNMP polling and syslog, from the monitoring range only
        udp dport 161 ip saddr @monitoring_v4 accept comment "snmp"
        udp dport 514 ip saddr @monitoring_v4 accept comment "syslog"

        # 9. Log the remainder at a low rate, then the policy drops it
        limit rate 5/minute burst 10 packets \
            log prefix "nft-input-drop: " level info counter
    }

    chain forward {
        type filter hook forward priority filter; policy drop;
        ct state established,related accept
        ct state invalid drop

        # Clamp TCP MSS to the real path MTU. This is the single rule that
        # prevents "handshake works, transfer hangs" over tunnels.
        tcp flags syn tcp option maxseg size set rt mtu
    }

    chain output {
        type filter hook output priority filter; policy accept;
    }
}
```

```
$ sudo nft -f /etc/nftables.conf && sudo nft list ruleset | head -20
table inet filter {
	set admin_v4 {
		type ipv4_addr
		flags interval
		elements = { 10.183.0.0/16, 198.51.100.0/26 }
	}
	...
	chain input {
		type filter hook input priority filter; policy drop;
		ct state established,related accept
		ct state invalid drop comment "no state, no service"
		iif "lo" accept
		...
	}
}

$ sudo nft list ruleset | grep -c 'icmpv6'
4
```

### 6.5 Kubernetes — un plan de direccionamiento que no colisiona, más doble pila

```yaml
# kubeadm-dualstack.yaml
# kubeadm init --config kubeadm-dualstack.yaml --upload-certs
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: v1.31.0
clusterName: dc1-prod
controlPlaneEndpoint: "api.dc1.example.net:6443"
networking:
  # IPv4 chosen deliberately OUTSIDE 10.0.0.0/16, 172.17.0.0/16 and
  # 192.168.0.0/16 so it cannot collide with the corporate VPN,
  # Docker's default bridge, or any employee's home router.
  podSubnet: "10.183.128.0/17,fd00:dc1:244::/56"
  serviceSubnet: "10.183.96.0/20,fd00:dc1:96::/112"
  dnsDomain: cluster.local
apiServer:
  certSANs:
    - api.dc1.example.net
    - 198.51.100.10
    - "2001:db8:42:7::10"
  extraArgs:
    - name: service-cluster-ip-range
      value: "10.183.96.0/20,fd00:dc1:96::/112"
    - name: secure-port
      value: "6443"
controllerManager:
  extraArgs:
    - name: node-cidr-mask-size-ipv4
      value: "24"           # 128 pods-worth of /24 per node out of the /17
    - name: node-cidr-mask-size-ipv6
      value: "64"
    - name: allocate-node-cidrs
      value: "true"
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: "198.51.100.23"
  bindPort: 6443
nodeRegistration:
  kubeletExtraArgs:
    - name: node-ip
      value: "198.51.100.23,2001:db8:42:7::23"
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
clusterDNS:
  - "10.183.96.10"
  - "fd00:dc1:96::a"
```

Un Service que nombra sus puertos según entradas de `/etc/services`, y una NetworkPolicy que codifica las distinciones de transporte de la sección 4:

```yaml
---
apiVersion: v1
kind: Service
metadata:
  name: edge-gateway
  namespace: edge
  labels:
    app.kubernetes.io/name: edge-gateway
spec:
  type: LoadBalancer
  ipFamilyPolicy: RequireDualStack
  ipFamilies:
    - IPv4
    - IPv6
  externalTrafficPolicy: Local     # preserves the client source IP
  selector:
    app.kubernetes.io/name: edge-gateway
  ports:
    - name: http                   # 80/tcp
      protocol: TCP
      port: 80
      targetPort: http
    - name: https                  # 443/tcp  — HTTP/1.1 and HTTP/2
      protocol: TCP
      port: 443
      targetPort: https
    - name: https-quic             # 443/udp  — HTTP/3. Same number, different protocol.
      protocol: UDP
      port: 443
      targetPort: quic
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: edge-gateway-policy
  namespace: edge
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: edge-gateway
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from: []                     # from anywhere: this is the public edge
      ports:
        - protocol: TCP
          port: 80
        - protocol: TCP
          port: 443
        - protocol: UDP
          port: 443
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: monitoring
      ports:
        - protocol: TCP
          port: 9090
  egress:
    # DNS needs BOTH transports: UDP for normal queries, TCP for large
    # or DNSSEC-signed responses. Allowing only UDP is a classic outage.
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
    - to:
        - podSelector:
            matchLabels:
              app.kubernetes.io/name: backend-api
      ports:
        - protocol: TCP
          port: 8443
    # NTP to the datacentre time servers only
    - to:
        - ipBlock:
            cidr: 198.51.100.0/26
      ports:
        - protocol: UDP
          port: 123
    # Public egress, minus every RFC 1918 and special-purpose range
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except:
              - 10.0.0.0/8
              - 172.16.0.0/12
              - 192.168.0.0/16
              - 169.254.0.0/16     # blocks cloud metadata SSRF
              - 100.64.0.0/10
      ports:
        - protocol: TCP
          port: 443
```

### 6.6 Ansible — verificá el plan de direccionamiento en vez de confiar en él

```yaml
---
# playbooks/verify-network-contract.yml
# ansible-playbook -i inventories/dc1 playbooks/verify-network-contract.yml
- name: Verify the layer-3 contract on every datacentre host
  hosts: dc1
  gather_facts: true
  become: false

  vars:
    expected_v4_supernet: "198.51.100.0/24"
    expected_v6_supernet: "2001:db8:42::/48"
    forbidden_overlaps:
      - "10.0.0.0/16"
      - "172.17.0.0/16"
      - "192.168.0.0/16"
    required_listeners:
      - { port: 22,   proto: tcp, name: ssh }
      - { port: 443,  proto: tcp, name: https }
      - { port: 9100, proto: tcp, name: node_exporter }

  tasks:
    - name: Primary IPv4 address must live inside the allocated supernet
      ansible.builtin.assert:
        that:
          - ansible_default_ipv4.address | ansible.utils.ipaddr(expected_v4_supernet)
        fail_msg: >-
          {{ inventory_hostname }} holds {{ ansible_default_ipv4.address }},
          which is outside {{ expected_v4_supernet }}. The address plan is violated.
        success_msg: "{{ ansible_default_ipv4.address }} is inside {{ expected_v4_supernet }}"

    - name: Netmask must match the documented /26
      ansible.builtin.assert:
        that:
          - ansible_default_ipv4.netmask == '255.255.255.192'
        fail_msg: >-
          Mask is {{ ansible_default_ipv4.netmask }}, expected 255.255.255.192 (/26).
          A mask mismatch makes half the segment unreachable in one direction only.

    - name: A global IPv6 address must be present and inside the /48
      ansible.builtin.assert:
        that:
          - ansible_default_ipv6.address is defined
          - ansible_default_ipv6.address | ansible.utils.ipaddr(expected_v6_supernet)
        fail_msg: "No global IPv6 inside {{ expected_v6_supernet }} — dual stack is broken."

    - name: No configured route may overlap a forbidden prefix
      ansible.builtin.command:
        argv: [ip, -json, route, show]
      register: routes
      changed_when: false

    - name: Fail on address-plan collisions
      ansible.builtin.assert:
        that:
          - (routes.stdout | from_json
             | map(attribute='dst') | select('match', '^[0-9]')
             | select('ansible.utils.ipaddr', item) | list | length) == 0
        fail_msg: "Route table overlaps forbidden prefix {{ item }} — collision risk."
      loop: "{{ forbidden_overlaps }}"

    - name: Collect listening sockets
      ansible.builtin.command:
        argv: [ss, -Hltnup]
      register: sockets
      changed_when: false

    - name: Every required listener must be bound
      ansible.builtin.assert:
        that:
          - sockets.stdout is search(':' ~ item.port ~ '\\s')
        fail_msg: "{{ item.name }} is not listening on {{ item.proto }}/{{ item.port }}"
      loop: "{{ required_listeners }}"
      loop_control:
        label: "{{ item.name }} {{ item.proto }}/{{ item.port }}"

    - name: PMTU to the default gateway must be the full 1500
      ansible.builtin.command:
        argv: [ping, -M, do, -s, "1472", -c, "2", -W, "2",
               "{{ ansible_default_ipv4.gateway }}"]
      register: pmtu
      changed_when: false
      failed_when: pmtu.rc != 0
```

```
$ ansible-playbook -i inventories/dc1 playbooks/verify-network-contract.yml

PLAY [Verify the layer-3 contract on every datacentre host] ********************

TASK [Primary IPv4 address must live inside the allocated supernet] ************
ok: [node-01] => {"msg": "198.51.100.23 is inside 198.51.100.0/24"}
ok: [node-02] => {"msg": "198.51.100.24 is inside 198.51.100.0/24"}
fatal: [node-07]: FAILED! => {"msg": "node-07 holds 10.0.0.51, which is outside 198.51.100.0/24. The address plan is violated."}

PLAY RECAP *********************************************************************
node-01   : ok=7    changed=0    unreachable=0    failed=0
node-02   : ok=7    changed=0    unreachable=0    failed=0
node-07   : ok=1    changed=0    unreachable=0    failed=1
```

---

## 7. Verificación y diagnóstico de fallos

Recorré la escalera de abajo hacia arriba. Nunca te saltees un peldaño: un fallo de `curl` en el peldaño 6 no te dice nada si el peldaño 2 ya estaba roto.

### 7.1 Peldaños 1–2 — enlace y dirección

```
$ ip -brief link show
lo               UNKNOWN        00:00:00:00:00:00 <LOOPBACK,UP,LOWER_UP>
enp1s0           UP             52:54:00:1a:2b:3c <BROADCAST,MULTICAST,UP,LOWER_UP>
enp2s0           DOWN           52:54:00:1a:2b:3d <BROADCAST,MULTICAST>

$ ip -brief address show
lo               UNKNOWN        127.0.0.1/8 ::1/128
enp1s0           UP             198.51.100.23/26 2001:db8:42:7::23/64 2001:db8:42:7:5054:ff:fe1a:2b3c/64 fe80::5054:ff:fe1a:2b3c/64
enp2s0           DOWN
```

`LOWER_UP` significa que hay portadora presente; `UP` solo, sin `LOWER_UP`, es un problema de cable, SFP o puerto de switch, no de configuración.

Detalle completo de IPv6, incluidos tiempos de vida y flags:

```
$ ip -6 addr show dev enp1s0
2: enp1s0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 state UP qlen 1000
    inet6 2001:db8:42:7::23/64 scope global
       valid_lft forever preferred_lft forever
    inet6 2001:db8:42:7:5054:ff:fe1a:2b3c/64 scope global dynamic mngtmpaddr noprefixroute
       valid_lft 2591923sec preferred_lft 604723sec
    inet6 fe80::5054:ff:fe1a:2b3c/64 scope link noprefixroute
       valid_lft forever preferred_lft forever
```

Leé los flags: `dynamic` = aprendida de un RA, `mngtmpaddr` = pueden generarse direcciones temporales a partir de este prefijo, y `valid_lft`/`preferred_lft` finitos = va a expirar si los RA se detienen. Un flag `tentative` que nunca se limpia, o `dadfailed`, significa que la Duplicate Address Detection encontró un conflicto.

**La señal del 169.254.** Si `ip -br a` muestra `169.254.x.y/16` en IPv4, DHCP falló — el host se autoasignó. No depures la aplicación; depurá DHCP.

### 7.2 Peldaño 3 — enrutamiento y siguiente salto

```
$ ip route show
default via 198.51.100.1 dev enp1s0 proto static metric 100
10.183.64.0/20 via 198.51.100.2 dev enp1s0 proto static metric 200
198.51.100.0/26 dev enp1s0 proto kernel scope link src 198.51.100.23 metric 100

$ ip -6 route show
2001:db8:42:7::/64 dev enp1s0 proto ra metric 100 pref medium
fe80::/64 dev enp1s0 proto kernel metric 256 pref medium
default via fe80::1 dev enp1s0 proto ra metric 100 expires 1723sec pref medium
```

Fijate en la ruta por defecto de IPv6: el siguiente salto es una dirección **link-local**, y `expires`. Si los RA se detienen, la ruta por defecto desaparece y el host pierde conectividad IPv6 con la dirección global aún configurada — un estado que se ve bien en `ip addr` y está completamente roto.

Preguntale al kernel qué ruta y qué dirección de origen elegiría realmente — esto zanja discusiones más rápido que leer tablas:

```
$ ip route get 203.0.113.10
203.0.113.10 via 198.51.100.1 dev enp1s0 src 198.51.100.23 uid 1000
    cache

$ ip route get 2606:4700:4700::1111
2606:4700:4700::1111 via fe80::1 dev enp1s0 src 2001:db8:42:7:5054:ff:fe1a:2b3c metric 100 pref medium

$ ip route get 10.183.64.5
10.183.64.5 via 198.51.100.2 dev enp1s0 src 198.51.100.23 uid 1000
    cache
```

El campo `src` es el resultado de la selección de dirección de origen de RFC 6724 — es por lo que un firewall del otro lado a veces ve una dirección distinta de la que esperás.

Tablas de vecinos (ARP para IPv4, NDP para IPv6):

```
$ ip neigh show
198.51.100.1 dev enp1s0 lladdr 00:1a:2b:3c:4d:5e REACHABLE
198.51.100.2 dev enp1s0 lladdr 00:1a:2b:3c:4d:5f STALE
198.51.100.40 dev enp1s0  FAILED

$ ip -6 neigh show
fe80::1 dev enp1s0 lladdr 00:1a:2b:3c:4d:5e router REACHABLE
2001:db8:42:7::5 dev enp1s0 lladdr 00:1a:2b:3c:4d:60 STALE
```

`FAILED` significa que la dirección no respondió a ARP/NS — el host está apagado, o estás en la VLAN equivocada. `INCOMPLETE` significa que la resolución está en curso. `router` en una entrada IPv6 marca al vecino como un router que anuncia.

### 7.3 Peldaño 4 — alcanzabilidad, ICMP y el camino

```
$ ping -c 4 198.51.100.1
PING 198.51.100.1 (198.51.100.1) 56(84) bytes of data.
64 bytes from 198.51.100.1: icmp_seq=1 ttl=64 time=0.387 ms
64 bytes from 198.51.100.1: icmp_seq=2 ttl=64 time=0.402 ms
64 bytes from 198.51.100.1: icmp_seq=3 ttl=64 time=0.361 ms
64 bytes from 198.51.100.1: icmp_seq=4 ttl=64 time=0.398 ms

--- 198.51.100.1 ping statistics ---
4 packets transmitted, 4 received, 0% packet loss, time 3054ms
rtt min/avg/max/mdev = 0.361/0.387/0.402/0.016 ms
```

El **TTL** devuelto es una huella del número de saltos: Linux arranca en 64, Windows en 128, muchos dispositivos de red en 255. Una respuesta con `ttl=57` desde un host Linux significa siete routers en el medio.

```
$ ping -6 -c 3 2001:db8:42:7::5
PING 2001:db8:42:7::5 (2001:db8:42:7::5) 56 data bytes
64 bytes from 2001:db8:42:7::5: icmp_seq=1 ttl=64 time=0.441 ms
64 bytes from 2001:db8:42:7::5: icmp_seq=2 ttl=64 time=0.398 ms
64 bytes from 2001:db8:42:7::5: icmp_seq=3 ttl=64 time=0.412 ms

--- 2001:db8:42:7::5 ping statistics ---
3 packets transmitted, 3 received, 0% packet loss, time 2031ms
rtt min/avg/max/mdev = 0.398/0.417/0.441/0.017 ms
```

Hacer ping a una dirección link-local IPv6 **requiere** el índice de zona, porque `fe80::/10` es ambigua entre interfaces:

```
$ ping -c 2 fe80::1
ping: connect: Invalid argument

$ ping -c 2 fe80::1%enp1s0
PING fe80::1%enp1s0 (fe80::1%enp1s0) 56 data bytes
64 bytes from fe80::1%enp1s0: icmp_seq=1 ttl=64 time=0.372 ms
64 bytes from fe80::1%enp1s0: icmp_seq=2 ttl=64 time=0.351 ms
```

Distinguir un **drop** de un **reject** es la lectura de ICMP más útil que existe:

```
$ ping -c 2 -W 2 198.51.100.99
PING 198.51.100.99 (198.51.100.99) 56(84) bytes of data.

--- 198.51.100.99 ping statistics ---
2 packets transmitted, 0 received, 100% packet loss, time 1023ms
                    ^ silence: a DROP rule, or the host is down

$ ping -c 2 198.51.100.98
PING 198.51.100.98 (198.51.100.98) 56(84) bytes of data.
From 198.51.100.1 icmp_seq=1 Destination Host Unreachable
From 198.51.100.1 icmp_seq=2 Destination Host Unreachable
                    ^ ICMP 3/1: a router answered — L3 works, the target does not
```

Trazado del camino — tres herramientas, tres mecanismos:

```
$ traceroute -n 203.0.113.10
traceroute to 203.0.113.10 (203.0.113.10), 30 hops max, 60 byte packets
 1  198.51.100.1  0.412 ms  0.398 ms  0.441 ms
 2  198.51.100.254  1.204 ms  1.187 ms  1.233 ms
 3  * * *
 4  198.18.7.9  8.331 ms  8.402 ms  8.298 ms
 5  203.0.113.1  12.118 ms  12.204 ms  12.087 ms
 6  203.0.113.10  12.331 ms  12.298 ms  12.402 ms
```

`* * *` es un salto que no envía ICMP Time Exceeded (o lo limita en tasa). **No** es un salto roto: el tráfico sigue pasando por él. Solo un `* * *` que continúa hasta el destino indica una rotura real.

```
$ mtr -rwc 20 -n 203.0.113.10
Start: 2026-08-27T10:14:02+0000
HOST: node-01                     Loss%   Snt   Last   Avg  Best  Wrst StDev
  1.|-- 198.51.100.1               0.0%    20    0.4   0.4   0.3   0.6   0.1
  2.|-- 198.51.100.254             0.0%    20    1.2   1.2   1.1   1.5   0.1
  3.|-- ???                       100.0%    20    0.0   0.0   0.0   0.0   0.0
  4.|-- 198.18.7.9                 0.0%    20    8.3   8.4   8.2   9.1   0.2
  5.|-- 203.0.113.1                5.0%    20   12.1  12.3  12.0  14.8   0.6
  6.|-- 203.0.113.10               0.0%    20   12.3  12.4  12.2  13.1   0.2
```

Leé `mtr` correctamente: la pérdida en un salto intermedio que **no persiste hasta el destino** es limitación de tasa de ICMP en el plano de control de ese router, no pérdida de paquetes. Solo la pérdida que continúa hasta la línea final es real.

### 7.4 Peldaño 5 — el agujero negro de Path MTU, diagnosticado

Forzá el bit DF y bajá el tamaño progresivamente. El valor de `-s` es el **payload**; agregá 28 bytes (20 IP + 8 ICMP) para el tamaño en el cable:

```
$ ping -M do -s 1472 -c 2 203.0.113.10
PING 203.0.113.10 (203.0.113.10) 1472(1500) bytes of data.
From 198.51.100.254 icmp_seq=1 Frag needed and DF set (mtu = 1400)
From 198.51.100.254 icmp_seq=2 Frag needed and DF set (mtu = 1400)

--- 203.0.113.10 ping statistics ---
0 packets transmitted, 0 received, +2 errors

$ ping -M do -s 1372 -c 2 203.0.113.10
PING 203.0.113.10 (203.0.113.10) 1372(1400) bytes of data.
1380 bytes from 203.0.113.10: icmp_seq=1 ttl=58 time=12.4 ms
1380 bytes from 203.0.113.10: icmp_seq=2 ttl=58 time=12.3 ms
```

Ese es el caso **bueno**: el router te avisó. El agujero negro es cuando no lo hace:

```
$ ping -M do -s 1472 -c 3 -W 2 203.0.113.20
PING 203.0.113.20 (203.0.113.20) 1472(1500) bytes of data.

--- 203.0.113.20 ping statistics ---
3 packets transmitted, 0 received, 100% packet loss, time 2045ms

$ ping -M do -s 1372 -c 3 203.0.113.20
PING 203.0.113.20 (203.0.113.20) 1372(1400) bytes of data.
1380 bytes from 203.0.113.20: icmp_seq=1 ttl=57 time=14.1 ms
...
--- 203.0.113.20 ping statistics ---
3 packets transmitted, 3 received, 0% packet loss
```

Lo pequeño funciona, lo grande es silencioso, y no llega ningún ICMP: alguien está filtrando el tipo 3 código 4. `tracepath` mapea la MTU de todo el camino sin necesitar root:

```
$ tracepath -n 203.0.113.20
 1?: [LOCALHOST]                      pmtu 1500
 1:  198.51.100.1                                          0.412ms
 1:  198.51.100.1                                          0.387ms
 2:  198.51.100.254                                        1.204ms
 3:  198.18.7.1                                            4.118ms pmtu 1400
 3:  198.18.7.9                                            8.331ms
 4:  203.0.113.1                                          12.118ms
 5:  203.0.113.20                                         14.102ms reached
     Resume: pmtu 1400 hops 5 back 5
```

Y confirmá qué cacheó el kernel para ese destino:

```
$ ip route get 203.0.113.20
203.0.113.20 via 198.51.100.1 dev enp1s0 src 198.51.100.23 uid 1000
    cache expires 597sec mtu 1400
```

Remediaciones, en orden: arreglar el dispositivo que filtra (lo correcto); habilitar `net.ipv4.tcp_mtu_probing=1` para que TCP sondee hacia abajo en vez de colgarse (buena mitigación); hacer clamp del MSS en el borde del túnel con la regla `nft` de §6.4 (necesario en cualquier túnel); bajar la MTU de la interfaz (burdo, último recurso).

### 7.5 Peldaño 6 — sockets, puertos y listeners

```
$ ss -tulnp
Netid State  Recv-Q Send-Q   Local Address:Port    Peer Address:Port Process
udp   UNCONN 0      0        127.0.0.53%lo:53           0.0.0.0:*     users:(("systemd-resolve",pid=712,fd=13))
udp   UNCONN 0      0              0.0.0.0:123          0.0.0.0:*     users:(("chronyd",pid=804,fd=5))
udp   UNCONN 0      0                 [::]:123             [::]:*     users:(("chronyd",pid=804,fd=6))
udp   UNCONN 0      0              0.0.0.0:161          0.0.0.0:*     users:(("snmpd",pid=901,fd=7))
tcp   LISTEN 0      4096     127.0.0.53%lo:53           0.0.0.0:*     users:(("systemd-resolve",pid=712,fd=14))
tcp   LISTEN 0      128            0.0.0.0:22           0.0.0.0:*     users:(("sshd",pid=1043,fd=3))
tcp   LISTEN 0      128               [::]:22              [::]:*     users:(("sshd",pid=1043,fd=4))
tcp   LISTEN 0      511                  *:80                 *:*     users:(("nginx",pid=1580,fd=6),("nginx",pid=1579,fd=6))
tcp   LISTEN 0      511                  *:443                *:*     users:(("nginx",pid=1580,fd=7),("nginx",pid=1579,fd=7))
tcp   LISTEN 0      4096         127.0.0.1:5432         0.0.0.0:*     users:(("postgres",pid=1201,fd=5))
```

Todo lo que necesitás está en esa salida:

- `postgres` está en `127.0.0.1:5432` — **solo local**. Toda conexión remota va a fallar sin importar las reglas de firewall. Este es el reporte falso de «el firewall nos está bloqueando» más común.
- `sshd` tiene dos filas (`0.0.0.0` y `[::]`) — dos sockets separados, porque `net.ipv6.bindv6only` o la configuración del demonio los separó.
- `nginx` muestra `*:443` con dos PID de workers compartiendo el socket vía `SO_REUSEPORT`.
- `Send-Q` en una fila `LISTEN` es el **límite de la cola de accept** (el backlog efectivo de `listen()`). `Recv-Q` es cuántas conexiones completadas están esperando `accept()`. Un `Recv-Q` persistentemente distinto de cero en un socket LISTEN significa que la aplicación no está aceptando lo bastante rápido — eso es un problema de la aplicación, y subir `somaxconn` solo lo pospone.

Censo de estados de conexión, e internals de TCP de un flujo en vivo:

```
$ ss -s
Total: 428
TCP:   1284 (estab 312, closed 894, orphaned 4, timewait 891)

Transport Total     IP        IPv6
RAW	  1         0         1
UDP	  8         5         3
TCP	  390       341       49
INET	  399       346       53
FRAG	  0         0         0

$ ss -tan state time-wait | wc -l
892

$ ss -tin dst 203.0.113.10
State  Recv-Q Send-Q      Local Address:Port    Peer Address:Port
ESTAB  0      0          198.51.100.23:51234   203.0.113.10:443
	 cubic wscale:7,9 rto:212 rtt:11.847/0.523 ato:40 mss:1360 pmtu:1400
	 rcvmss:1360 advmss:1448 cwnd:24 bytes_sent:184320 bytes_acked:184320
	 bytes_received:1048576 segs_out:143 segs_in:812 data_segs_out:128
	 data_segs_in:790 send 22.0Mbps lastsnd:12 lastrcv:8 pacing_rate 44.1Mbps
	 delivery_rate 18.7Mbps delivered:129 busy:1408ms rcv_space:14480
	 rcv_ssthresh:64088 minrtt:11.204
```

`mss:1360` frente a `advmss:1448` es el clamp de MSS de §6.4 haciendo su trabajo; `pmtu:1400` confirma la MTU del camino descubierta. Un campo `retrans:` distinto de cero indicaría pérdida real.

Contadores que exponen el comportamiento de la cola de accept y de los SYN flood:

```
$ nstat -az | grep -E 'ListenOverflows|ListenDrops|SyncookiesSent|TCPSynRetrans|OutNoRoutes'
TcpExtSyncookiesSent            0                  0.0
TcpExtListenOverflows           14872              0.0
TcpExtListenDrops               14872              0.0
TcpExtTCPSynRetrans             203                0.0
IpExtOutNoRoutes                0                  0.0
```

Que `ListenOverflows` suba significa que se están descartando conexiones completadas porque la cola de accept está llena — los clientes ven que el handshake tiene éxito y luego la conexión se resetea o se estanca.

Probá que un puerto está abierto, sin `nmap`:

```
$ nc -zv 203.0.113.10 443
Connection to 203.0.113.10 443 port [tcp/https] succeeded!

$ nc -zv 203.0.113.10 25
nc: connect to 203.0.113.10 port 25 (tcp) failed: Connection timed out
                                              ^ DROP: the packet vanished

$ nc -zv 203.0.113.10 8080
nc: connect to 203.0.113.10 port 8080 (tcp) failed: Connection refused
                                              ^ RST: reachable, nothing listening

$ nc -zvu 198.51.100.5 123
Connection to 198.51.100.5 123 port [udp/ntp] succeeded!
```

> **Advertencia sobre UDP.** `nc -zu` reporta «succeeded» siempre que no haya vuelto un ICMP port-unreachable dentro del timeout. Como un firewall que descarta ICMP produce exactamente el mismo resultado que un puerto abierto, las comprobaciones de UDP hay que hacerlas con un cliente que conozca el protocolo (`dig`, `chronyc`, `snmpwalk`) — nunca con un sondeo de puerto pelado.

Verificación consciente del protocolo de los puertos de §5.2:

```
$ dig +short @198.51.100.5 www.example.net A
203.0.113.10

$ dig +tcp @198.51.100.5 example.net SOA +noall +answer
example.net.  3600  IN  SOA  ns1.example.net. hostmaster.example.net. 2026082701 7200 3600 1209600 3600

$ chronyc -n sources
MS Name/IP address         Stratum Poll Reach LastRx Last sample
===============================================================================
^* 198.51.100.5                  2   6   377    41   -132us[ -148us] +/-   11ms
^+ 198.51.100.6                  2   6   377    38   +204us[ +204us] +/-   13ms

$ openssl s_client -connect mail.example.net:993 -servername mail.example.net -brief
CONNECTION ESTABLISHED
Protocol version: TLSv1.3
Ciphersuite: TLS_AES_256_GCM_SHA384
Peer certificate: CN = mail.example.net
Verification: OK

$ ldapsearch -x -H ldaps://ldap.example.net:636 -b '' -s base namingContexts
# extended LDIF
#
dn:
namingContexts: dc=example,dc=net

# numResponses: 2
```

¿Qué familia de direcciones usó realmente la conexión? Happy Eyeballs lo esconde:

```
$ curl -sS -o /dev/null -w 'family=%{remote_ip}  http=%{http_version}  connect=%{time_connect}s  total=%{time_total}s\n' https://www.example.net/
family=2001:db8:42:100::10  http=3  connect=0.014s  total=0.089s

$ curl -4 -sS -o /dev/null -w 'family=%{remote_ip}  total=%{time_total}s\n' https://www.example.net/
family=203.0.113.10  total=0.093s

$ curl -6 -sS -o /dev/null -w 'family=%{remote_ip}  total=%{time_total}s\n' https://www.example.net/
family=2001:db8:42:100::10  total=0.088s
```

Si `-6` se cuelga mientras la llamada sin forzar tiene éxito al instante, IPv6 está roto y Happy Eyeballs lo ha estado enmascarando.

### 7.6 Peldaño 7 — captura de paquetes, la verdad de campo

```
$ sudo tcpdump -ni enp1s0 -c 6 'tcp port 443 and host 203.0.113.10'
tcpdump: verbose output suppressed, use -v[v]... for full protocol decode
listening on enp1s0, link-type EN10MB (Ethernet), snapshot length 262144 bytes
10:14:02.118934 IP 198.51.100.23.51234 > 203.0.113.10.443: Flags [S], seq 1829384756, win 64240, options [mss 1460,sackOK,TS val 3921847 ecr 0,nop,wscale 7], length 0
10:14:02.130712 IP 203.0.113.10.443 > 198.51.100.23.51234: Flags [S.], seq 2938475610, ack 1829384757, win 65535, options [mss 1400,sackOK,TS val 118293 ecr 3921847,nop,wscale 9], length 0
10:14:02.130791 IP 198.51.100.23.51234 > 203.0.113.10.443: Flags [.], ack 1, win 502, options [nop,nop,TS val 3921859 ecr 118293], length 0
10:14:02.131044 IP 198.51.100.23.51234 > 203.0.113.10.443: Flags [P.], seq 1:518, ack 1, win 502, options [nop,nop,TS val 3921859 ecr 118293], length 517
10:14:02.143201 IP 203.0.113.10.443 > 198.51.100.23.51234: Flags [.], ack 518, win 130, options [nop,nop,TS val 118305 ecr 3921859], length 0
10:14:02.144877 IP 203.0.113.10.443 > 198.51.100.23.51234: Flags [P.], seq 1:3841, ack 518, win 130, options [nop,nop,TS val 118305 ecr 3921859], length 3840
6 packets captured
```

Notación de flags: `[S]` SYN, `[S.]` SYN+ACK (el punto es ACK), `[.]` ACK pelado, `[P.]` PSH+ACK (datos), `[F.]` FIN+ACK, `[R]` RST. El peer anunció `mss 1400`, de donde salió el MSS con clamp de §7.5.

Una conexión rechazada se ve así — un SYN, un RST, sin reintentos:

```
$ sudo tcpdump -ni enp1s0 -c 2 'tcp port 8080 and host 203.0.113.10'
10:15:31.204118 IP 198.51.100.23.51288 > 203.0.113.10.8080: Flags [S], seq 3821094, win 64240, options [mss 1460,sackOK,TS val 4011203 ecr 0,nop,wscale 7], length 0
10:15:31.216402 IP 203.0.113.10.8080 > 198.51.100.23.51288: Flags [R.], seq 1, ack 3821095, win 0, length 0
```

Una conexión **descartada** se ve completamente distinta — SYN repetidos con backoff exponencial y ninguna respuesta:

```
$ sudo tcpdump -ni enp1s0 'tcp port 25 and host 203.0.113.10'
10:16:02.118934 IP 198.51.100.23.51301 > 203.0.113.10.25: Flags [S], seq 918273, win 64240, length 0
10:16:03.134201 IP 198.51.100.23.51301 > 203.0.113.10.25: Flags [S], seq 918273, win 64240, length 0
10:16:05.166113 IP 198.51.100.23.51301 > 203.0.113.10.25: Flags [S], seq 918273, win 64240, length 0
10:16:09.230447 IP 198.51.100.23.51301 > 203.0.113.10.25: Flags [S], seq 918273, win 64240, length 0
```

Observando ICMP y DNS específicamente:

```
$ sudo tcpdump -ni enp1s0 -v 'icmp or icmp6'
10:17:41.887201 IP (tos 0x0, ttl 63, id 0, offset 0, flags [none], proto ICMP (1), length 576)
    198.51.100.254 > 198.51.100.23: ICMP 203.0.113.20 unreachable - need to frag (mtu 1400), length 556
10:17:44.102338 IP6 (hlim 64, next-header ICMPv6 (58) payload length: 24)
    fe80::1 > ff02::1: [icmp6 sum ok] ICMP6, router advertisement, length 24
	hop limit 64, Flags [other stateful], pref medium, router lifetime 1800s, reachable time 0ms, retrans timer 0ms

$ sudo tcpdump -ni enp1s0 -c 2 'udp port 53'
10:18:03.441028 IP 198.51.100.23.44192 > 198.51.100.5.53: 32918+ [1au] A? www.example.net. (56)
10:18:03.443881 IP 198.51.100.5.53 > 198.51.100.23.44192: 32918 1/0/1 A 203.0.113.10 (74)
```

Neighbor Discovery en acción — esto es lo que destruye un firewall que bloquea ICMPv6:

```
$ sudo tcpdump -ni enp1s0 -c 4 'icmp6 and ip6[40] >= 133 and ip6[40] <= 137'
10:19:12.114208 IP6 fe80::5054:ff:fe1a:2b3c > ff02::1:ff00:5: ICMP6, neighbor solicitation, who has 2001:db8:42:7::5, length 32
10:19:12.114887 IP6 fe80::20c:29ff:fe4d:1a60 > fe80::5054:ff:fe1a:2b3c: ICMP6, neighbor advertisement, tgt is 2001:db8:42:7::5, length 32
10:19:14.220114 IP6 fe80::5054:ff:fe1a:2b3c > ff02::2: ICMP6, router solicitation, length 16
10:19:14.221008 IP6 fe80::1 > ff02::1: ICMP6, router advertisement, length 88
```

Fijate en el destino del primer paquete: `ff02::1:ff00:5` — el **grupo multicast solicited-node** derivado de los últimos 24 bits del objetivo, exactamente como se calculó en §3.3. Solo el único host que posee esa dirección procesa la trama; en IPv4, cada host del segmento habría sido interrumpido por el broadcast de ARP.

### 7.7 Catálogo de fallos

| Síntoma | Causa más probable | Comando que lo confirma | Arreglo |
|---|---|---|---|
| `169.254.x.y` en la interfaz | DHCP falló; el host se autoasignó | `ip -br a`; `journalctl -u systemd-networkd -n 50` | Arreglar la alcanzabilidad de DHCP o configurar estáticamente |
| La subred local es alcanzable, todo lo demás no | Sin ruta por defecto | `ip route show \| grep ^default` | `ip route add default via <gw>` / arreglar Netplan |
| El ping al gateway falla, otros en la VLAN responden | Máscara desalineada — el peer cree que estás fuera de la red | `ipcalc <ip>/<mask>` en ambos extremos | Alinear el prefijo en el host *y* en el switch/router |
| El handshake funciona, la transferencia se cuelga en ~1 kB | Agujero negro de PMTU (ICMP 3/4 filtrado) | `ping -M do -s 1472`; `tracepath -n` | Desbloquear ICMP; `tcp_mtu_probing=1`; clamp de MSS |
| `Connection refused` | No hay nada escuchando, o está enlazado a `127.0.0.1` | `ss -tlnp \| grep :<port>` | Enlazar a la dirección correcta; arrancar el servicio |
| `Connection timed out` | DROP silencioso, o ruta equivocada | `tcpdump` muestra SYN sin respuesta | Regla de firewall; verificar con `ip route get` |
| Miles de `CLOSE_WAIT` | La **aplicación** nunca llama a `close()` | `ss -tan state close-wait \| wc -l` | Arreglar la app / descriptores de archivo filtrados; ningún sysctl ayuda |
| Miles de `TIME_WAIT` en un proxy | Normal para el lado que cierra primero | `ss -s` | Habilitar keep-alive; `tcp_tw_reuse=1`; ampliar el rango de puertos |
| `cannot assign requested address` bajo carga | Agotamiento de puertos efímeros | `sysctl net.ipv4.ip_local_port_range`; `ss -s` | Ampliar el rango, agregar IPs upstream, reutilizar conexiones |
| Los clientes conectan y se estancan; `ListenOverflows` subiendo | Cola de accept llena | `nstat -az \| grep ListenOverflows` | Subir `somaxconn` **y** el backlog de `listen()` de la app; arreglar el bucle de accept |
| Dirección IPv6 presente, sin conectividad IPv6 | Los RA se detuvieron; la ruta por defecto expiró | `ip -6 route show \| grep default` | Restaurar el RA; revisar `accept_ra`; verificar que ICMPv6 esté permitido |
| Dirección IPv6 atascada en `tentative` / `dadfailed` | Dirección duplicada en el enlace | `ip -6 addr show \| grep -E 'tentative\|dadfailed'` | Resolver el conflicto; volver a agregar la dirección |
| IPv6 roto pero nadie lo nota | Happy Eyeballs cae de vuelta a IPv4 | `curl -6 -v https://host/` | Arreglar IPv6; no lo deshabilites |
| DNS funciona para respuestas pequeñas, falla con DNSSEC | TCP/53 bloqueado o fragmentos UDP descartados | `dig +tcp`; `dig +bufsize=1232` | Abrir TCP/53; limitar el buffer de EDNS0 |
| El sitio «más lento de lo que debería» sobre HTTP/3 | UDP/443 no permitido; degradación silenciosa a HTTP/2 | `curl -w '%{http_version}'` | Permitir `udp dport 443` |
| Tráfico asimétrico descartado silenciosamente | `rp_filter=1` en un host multihomed | `sysctl net.ipv4.conf.all.rp_filter`; salida de `log_martians` | Poner `rp_filter=2` (loose) o arreglar la simetría del enrutamiento |
| VPN levantada, medio clúster inalcanzable | CIDRs solapados | `ip route get <pod-ip>` muestra el túnel | Renumerar; el plan de direccionamiento es el arreglo real |
| `ss` muestra un nombre de servicio que no esperás | Mapeo de `/etc/services`, no el puerto real | `ss -tln -n` | Usá siempre `-n` cuando leas puertos |

---

## 8. Resumen enfocado al examen

- **CIDR es aritmética, no búsqueda en tabla.** Hosts utilizables = 2^(32−prefijo) − 2, con `/31` y `/32` como las excepciones documentadas. Tenés que poder producir red, primer host, último host y broadcast a partir de cualquier par dirección/prefijo sin herramienta.
- **Rangos privados**: `10.0.0.0/8`, `172.16.0.0/12` (hasta `172.31.255.255` — `172.32.x.x` es pública), `192.168.0.0/16`. Reconocé `169.254.0.0/16` como «DHCP falló» y `127.0.0.0/8` como el bloque de loopback entero.
- **TCP** = orientado a conexión, fiable, ordenado, con control de flujo y congestión, solo unicast, cabecera mínima de 20 bytes. **UDP** = sin conexión, no fiable, sin orden, cabecera de 8 bytes, soporta multicast/broadcast. **ICMP** = ninguno de los dos — sin puertos, señalización de control y errores para IP misma.
- **ICMP no es opcional.** El tipo 3 código 4 (IPv4) y el tipo 2 (IPv6) llevan Path MTU Discovery; los tipos ICMPv6 133–137 *son* Neighbor Discovery.
- **IPv6**: 128 bits, cabecera fija de 40 bytes, **sin checksum de cabecera**, **sin broadcast**, **sin fragmentación en routers**, MTU mínima 1280, LANs `/64`, link-local `fe80::/10` siempre presente, ruta por defecto solo desde un RA.
- **`/etc/services`** mapea nombres a `puerto/protocolo`. Documenta; no abre, cierra ni enlaza nada. Consultalo con `getent services`; leé los números de puerto reales con `ss -n`.
- **Memorizá la tabla de puertos de §5.2 a la perfección.** Los pares que más se fallan: 20/21 FTP data frente a control, 110/995 POP3 frente a POP3S, 143/993 IMAP frente a IMAPS, 389/636 LDAP frente a LDAPS, 161/162 sondeo SNMP frente a trap, 514 syslog sobre **UDP**, 465 SMTPS, y 53 sobre **ambos** TCP y UDP.

---

## 9. Referencias

**Objetivos oficiales de certificación de LPI**

- LPI — Objetivos del examen 102-500 (Tema 109, donde vive el objetivo 109.1): <https://www.lpi.org/our-certifications/exam-102-objectives/>
- LPI — Objetivos del examen 101-500: <https://www.lpi.org/our-certifications/exam-101-objectives/>
- LPI — Visión general de la certificación LPIC-1: <https://www.lpi.org/our-certifications/lpic-1-overview/>

**Estándares del IETF**

- RFC 791 — Internet Protocol (IPv4): <https://www.rfc-editor.org/rfc/rfc791.html>
- RFC 792 — Internet Control Message Protocol (ICMP): <https://www.rfc-editor.org/rfc/rfc792.html>
- RFC 768 — User Datagram Protocol: <https://www.rfc-editor.org/rfc/rfc768.html>
- RFC 9293 — Transmission Control Protocol (obsoleta a la RFC 793): <https://www.rfc-editor.org/rfc/rfc9293.html>
- RFC 1918 — Address Allocation for Private Internets: <https://www.rfc-editor.org/rfc/rfc1918.html>
- RFC 4632 — CIDR: The Internet Address Assignment and Aggregation Plan: <https://www.rfc-editor.org/rfc/rfc4632.html>
- RFC 3021 — Using 31-Bit Prefixes on IPv4 Point-to-Point Links: <https://www.rfc-editor.org/rfc/rfc3021.html>
- RFC 3927 — Dynamic Configuration of IPv4 Link-Local Addresses: <https://www.rfc-editor.org/rfc/rfc3927.html>
- RFC 5737 — IPv4 Address Blocks Reserved for Documentation: <https://www.rfc-editor.org/rfc/rfc5737.html>
- RFC 6598 — IANA-Reserved IPv4 Prefix for Shared Address Space: <https://www.rfc-editor.org/rfc/rfc6598.html>
- RFC 8200 — Internet Protocol, Version 6 (IPv6) Specification: <https://www.rfc-editor.org/rfc/rfc8200.html>
- RFC 4291 — IP Version 6 Addressing Architecture: <https://www.rfc-editor.org/rfc/rfc4291.html>
- RFC 4443 — ICMPv6 for the IPv6 Specification: <https://www.rfc-editor.org/rfc/rfc4443.html>
- RFC 4861 — Neighbor Discovery for IPv6: <https://www.rfc-editor.org/rfc/rfc4861.html>
- RFC 4862 — IPv6 Stateless Address Autoconfiguration (SLAAC): <https://www.rfc-editor.org/rfc/rfc4862.html>
- RFC 4193 — Unique Local IPv6 Unicast Addresses: <https://www.rfc-editor.org/rfc/rfc4193.html>
- RFC 5952 — A Recommendation for IPv6 Address Text Representation: <https://www.rfc-editor.org/rfc/rfc5952.html>
- RFC 6724 — Default Address Selection for IPv6: <https://www.rfc-editor.org/rfc/rfc6724.html>
- RFC 7217 — Semantically Opaque Interface Identifiers (stable-privacy): <https://www.rfc-editor.org/rfc/rfc7217.html>
- RFC 8981 — Temporary Address Extensions for SLAAC: <https://www.rfc-editor.org/rfc/rfc8981.html>
- RFC 8106 — IPv6 RA Options for DNS Configuration: <https://www.rfc-editor.org/rfc/rfc8106.html>
- RFC 8415 — DHCP for IPv6 (DHCPv6): <https://www.rfc-editor.org/rfc/rfc8415.html>
- RFC 4890 — Recommendations for Filtering ICMPv6 Messages in Firewalls: <https://www.rfc-editor.org/rfc/rfc4890.html>
- RFC 1191 — Path MTU Discovery: <https://www.rfc-editor.org/rfc/rfc1191.html>
- RFC 8201 — Path MTU Discovery for IPv6: <https://www.rfc-editor.org/rfc/rfc8201.html>
- RFC 8305 — Happy Eyeballs Version 2: <https://www.rfc-editor.org/rfc/rfc8305.html>
- RFC 9000 — QUIC: A UDP-Based Multiplexed and Secure Transport: <https://www.rfc-editor.org/rfc/rfc9000.html>
- RFC 9114 — HTTP/3: <https://www.rfc-editor.org/rfc/rfc9114.html>
- RFC 8314 — Cleartext Considered Obsolete: TLS for Email Submission and Access: <https://www.rfc-editor.org/rfc/rfc8314.html>
- RFC 6335 — IANA Procedures for Service Name and Transport Protocol Port Number Registry: <https://www.rfc-editor.org/rfc/rfc6335.html>
- RFC 3704 — Ingress Filtering for Multihomed Networks: <https://www.rfc-editor.org/rfc/rfc3704.html>

**Registros de IANA**

- Service Name and Transport Protocol Port Number Registry: <https://www.iana.org/assignments/service-names-port-numbers/service-names-port-numbers.xhtml>
- IPv4 Special-Purpose Address Registry: <https://www.iana.org/assignments/iana-ipv4-special-registry/iana-ipv4-special-registry.xhtml>
- IPv6 Special-Purpose Address Registry: <https://www.iana.org/assignments/iana-ipv6-special-registry/iana-ipv6-special-registry.xhtml>
- ICMP Type Numbers: <https://www.iana.org/assignments/icmp-parameters/icmp-parameters.xhtml>
- ICMPv6 Parameters: <https://www.iana.org/assignments/icmpv6-parameters/icmpv6-parameters.xhtml>
- Protocol Numbers: <https://www.iana.org/assignments/protocol-numbers/protocol-numbers.xhtml>

**Documentación de Linux**

- Referencia de sysctl de red del kernel (`ip-sysctl`): <https://docs.kernel.org/networking/ip-sysctl.html>
- `ip(8)` — iproute2: <https://man7.org/linux/man-pages/man8/ip.8.html>
- `ip-address(8)`: <https://man7.org/linux/man-pages/man8/ip-address.8.html>
- `ip-route(8)`: <https://man7.org/linux/man-pages/man8/ip-route.8.html>
- `ss(8)`: <https://man7.org/linux/man-pages/man8/ss.8.html>
- `services(5)`: <https://man7.org/linux/man-pages/man5/services.5.html>
- `getent(1)`: <https://man7.org/linux/man-pages/man1/getent.1.html>
- `nsswitch.conf(5)`: <https://man7.org/linux/man-pages/man5/nsswitch.conf.5.html>
- `ping(8)`: <https://man7.org/linux/man-pages/man8/ping.8.html>
- `tracepath(8)`: <https://man7.org/linux/man-pages/man8/tracepath.8.html>
- `tcpdump(8)` y `pcap-filter(7)`: <https://www.tcpdump.org/manpages/tcpdump.1.html> · <https://www.tcpdump.org/manpages/pcap-filter.7.html>
- `tcp(7)`, `udp(7)`, `ip(7)`, `ipv6(7)`: <https://man7.org/linux/man-pages/man7/tcp.7.html> · <https://man7.org/linux/man-pages/man7/udp.7.html> · <https://man7.org/linux/man-pages/man7/ip.7.html> · <https://man7.org/linux/man-pages/man7/ipv6.7.html>
- systemd `systemd.network(5)`: <https://www.freedesktop.org/software/systemd/man/latest/systemd.network.html>
- `networkctl(1)`: <https://www.freedesktop.org/software/systemd/man/latest/networkctl.html>
- Wiki de nftables: <https://wiki.nftables.org/wiki-nftables/index.php/Main_Page>
- Referencia de Netplan: <https://netplan.readthedocs.io/en/stable/netplan-yaml/>

**Kubernetes**

- Conceptos de red del clúster: <https://kubernetes.io/docs/concepts/cluster-administration/networking/>
- Doble pila IPv4/IPv6: <https://kubernetes.io/docs/concepts/services-networking/dual-stack/>
- Service: <https://kubernetes.io/docs/concepts/services-networking/service/>
- Network Policies: <https://kubernetes.io/docs/concepts/services-networking/network-policies/>
- kubeadm `ClusterConfiguration` (v1beta4): <https://kubernetes.io/docs/reference/config-api/kubeadm-config.v1beta4/>