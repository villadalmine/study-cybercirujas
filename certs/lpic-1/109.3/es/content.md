# LPIC-1 · Tema 109.3 — Resolución básica de problemas de red

**Examen:** 102-500 · **Bloque temático:** 109 Fundamentos de redes · **Versión:** 5.0
**Perfil:** Principal Platform Architect / Senior SRE

---

## 1. Motivación: el problema arquitectónico

En una plataforma en producción, «la red está rota» casi nunca es una afirmación sobre la red. Es una afirmación sobre una *ambigüedad no resuelta*: alguna petición no se completó, y quien opera todavía no sabe **qué capa del stack se la consumió**. El mismo síntoma visible para el usuario —30 segundos colgado seguidos de un 504— lo producen al menos siete causas raíz mutuamente excluyentes:

| Causa raíz | Capa | Quién es responsable | Tiempo de detección si adivinás |
|---|---|---|---|
| La NIC negoció 100 Mb/s half-duplex en un puerto de 10 G | L1/L2 | Datacenter / cableado | horas |
| Caché ARP envenenada por una IP duplicada después de un failover | L2 | Orquestador / IPAM | horas |
| Falta la ruta por defecto en una de tres interfaces | L3 | Gestión de configuración | minutos |
| `rp_filter=1` descartando respuestas ruteadas asimétricamente | L3 | Ajuste del kernel | días |
| Agujero negro de PMTU: ICMP `frag-needed` filtrado por un firewall | L3/L4 | Seguridad | días |
| Desbordamiento del backlog de `somaxconn`, SYNs descartados en silencio | L4 | Aplicación | horas |
| Expansión de dominios `search` que produce 5 round-trips NXDOMAIN por consulta | L7 | Configuración del resolver | días |

La respuesta de ingeniería **no** es más herramientas. Es una *bisección disciplinada sobre el stack de capas*, donde cada comando se elige porque aísla exactamente una capa y produce un resultado falsable. Esa disciplina es lo que codifica LPIC-1 109.3, y es idéntica ya sea que el host sea un hipervisor bare-metal, una instancia EC2 o un contenedor que comparte un network namespace con el sandbox de un Pod de Kubernetes.

La regla que organiza todo lo que sigue:

> **Nunca pruebes una capa cuya capa inferior no hayas probado.**
> Un fallo de `curl` no te dice nada hasta que `ip route get` haya probado L3 y `ss -lnt` haya probado que el listener existe.

---

## 2. El modelo de bisección

```
                    ┌───────────────────────────────────┐
                    │  Symptom: request does not complete│
                    └──────────────┬────────────────────┘
                                   │
        ┌──────────────────────────▼──────────────────────────┐
        │ L1/L2  Is the link up and is the peer reachable      │
        │        on the wire?                                  │
        │        ip -s link · ethtool · ip neigh · arping      │
        └──────────────────────────┬──────────────────────────┘
                                   │ proven
        ┌──────────────────────────▼──────────────────────────┐
        │ L3     Do I have an address, and which route/source  │
        │        will the kernel pick for this destination?    │
        │        ip addr · ip route get · ping · traceroute    │
        └──────────────────────────┬──────────────────────────┘
                                   │ proven
        ┌──────────────────────────▼──────────────────────────┐
        │ L4     Is a socket listening, is the handshake       │
        │        completing, is the queue overflowing?         │
        │        ss -tulpn · ss -ti · nc -zv · nstat           │
        └──────────────────────────┬──────────────────────────┘
                                   │ proven
        ┌──────────────────────────▼──────────────────────────┐
        │ L7-name Does the *name* resolve, and through which   │
        │        resolution path (NSS, not just DNS)?          │
        │        getent hosts · resolvectl · dig · host        │
        └──────────────────────────┬──────────────────────────┘
                                   │ proven
        ┌──────────────────────────▼──────────────────────────┐
        │ Ground truth: capture the packets. tcpdump           │
        └─────────────────────────────────────────────────────┘
```

Cada paso hacia abajo se da solo después de que el paso de arriba devuelva un resultado *positivo*. Cada paso tiene un comando que produce evidencia, no una impresión.

---

## 3. Toolchain: `net-tools` versus `iproute2`

El paquete `net-tools` (`ifconfig`, `route`, `netstat`, `arp`, `iwconfig`) parsea archivos de texto de `/proc/net/*`. Está sin mantenimiento en la mayoría de las distribuciones desde ~2001, no puede representar correctamente múltiples direcciones por interfaz, y es ciego al policy routing, a los network namespaces y a la mayor parte del estado moderno del kernel. LPIC-1 v5.0 todavía lista los comandos legacy como *deprecados pero reconocibles*; los runbooks de producción deben usar `iproute2`.

| Legacy (`net-tools`) | Moderno (`iproute2` / otro) | Por qué la herramienta legacy está mal |
|---|---|---|
| `ifconfig` | `ip addr` / `ip link` | Muestra solo la primera dirección por interfaz; oculta secundarias, scopes y el lifetime de IPv6 |
| `ifconfig eth0 up` | `ip link set dev eth0 up` | — |
| `route -n` | `ip route show` | No puede mostrar tablas distintas de `main`, reglas de política ni grupos de nexthop |
| `route add default gw …` | `ip route add default via …` | — |
| `arp -an` | `ip neigh show` | Sin NDP de IPv6; sin máquina de estados (`REACHABLE`/`STALE`/`FAILED`) |
| `netstat -tulpn` | `ss -tulpn` | Lee `/proc` línea por línea; O(n²) en hosts con >10 k sockets, puede tardar minutos |
| `netstat -rn` | `ip route show` | La misma limitación de tablas |
| `netstat -i` | `ip -s link` | Menos contadores, sin detalle por cola |
| `hostname -i` | `getent hosts $(hostname)` | `hostname -i` resuelve mediante una única consulta y miente en hosts multi-homed |
| `iwconfig` | `iw dev` | API legacy de Wireless Extensions, eliminada para los drivers `cfg80211` |

El rendimiento no es un punto teórico. En un nodo de ingress con carga:

```
$ time netstat -tan | wc -l
118472

real    1m47.310s
user    0m9.884s
sys     1m36.021s

$ time ss -tan | wc -l
118468

real    0m0.412s
user    0m0.121s
sys     0m0.288s
```

`ss` usa la familia netlink `NETLINK_SOCK_DIAG` y le pide al kernel la tabla de sockets en un solo round trip. Esa es la diferencia entre una herramienta de diagnóstico y un amplificador de incidentes.

---

## 4. Capa 1–2: ¿el cable es real?

### 4.1 Estado del enlace y contadores de error

```
$ ip -s link show dev eth0
2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc mq state UP mode DEFAULT group default qlen 1000
    link/ether 06:3f:1a:9c:2e:44 brd ff:ff:ff:ff:ff:ff
    RX:  bytes packets errors dropped  missed   mcast
    482913772934 391827441      0    1204       0  118293
    TX:  bytes packets errors dropped carrier collsns
    318402993110 288109334      0       0       0       0
```

Leé esto en un orden fijo:

1. **`UP`** — estado administrativo. Lo fijás vos o el network manager.
2. **`LOWER_UP`** — carrier detectado por el driver. *Este es el enlace físico.* `UP` sin `LOWER_UP` significa cable desenchufado, SFP muerto o puerto de switch deshabilitado.
3. **`state UP`** — el estado operativo (`operstate`), la combinación resuelta.
4. **`errors`** — errores de CRC/frame ⇒ cableado, óptica o duplex mismatch.
5. **`dropped`** en RX ⇒ típicamente el kernel no tenía buffer (agotamiento del ring) o el paquete era para un grupo multicast al que no se está unido.
6. **`carrier`** en TX ⇒ el enlace flapeando durante la transmisión.

Una forma más barata cuando solo necesitás el estado administrativo/de carrier:

```
$ cat /sys/class/net/eth0/operstate
up
$ cat /sys/class/net/eth0/carrier
1
```

### 4.2 Negociación, duplex y la clásica trampa de los 100 Mb/s

```
$ sudo ethtool eth0
Settings for eth0:
	Supported ports: [ FIBRE ]
	Supported link modes:   1000baseT/Full
	                        10000baseT/Full
	Supported pause frame use: Symmetric
	Supports auto-negotiation: Yes
	Advertised link modes:  1000baseT/Full
	                        10000baseT/Full
	Advertised auto-negotiation: Yes
	Speed: 10000Mb/s
	Duplex: Full
	Port: FIBRE
	PHYAD: 0
	Transceiver: internal
	Auto-negotiation: on
	Current message level: 0x00000007 (7)
			       drv probe link
	Link detected: yes
```

`Speed: 100Mb/s` o `Duplex: Half` en un puerto de servidor es un incidente, no una configuración. El half duplex produce late collisions que se manifiestan en L7 como demoras *intermitentes y dependientes del tamaño*: las respuestas chicas funcionan, las grandes no.

Las estadísticas a nivel de driver exponen lo que `ip -s link` agrega y esconde:

```
$ sudo ethtool -S eth0 | grep -Ei 'drop|err|miss|no_buf|discard' | grep -v ': 0$'
     rx_missed_errors: 4471
     rx_no_buffer_count: 1204
     tx_deferred_ok: 32
```

Un `rx_missed_errors` que sube es un problema de **ring de recepción o saturación de CPU**, no un problema de red. El arreglo es `ethtool -G eth0 rx 4096` o afinidad de IRQ, no un cambio de firewall.

### 4.3 La tabla de vecinos (ARP / NDP)

```
$ ip neigh show
192.168.178.1 dev eth0 lladdr 3c:37:86:1f:22:9d REACHABLE
192.168.178.42 dev eth0 lladdr 06:3f:1a:9c:2e:44 STALE
192.168.178.77 dev eth0  FAILED
fe80::3e37:86ff:fe1f:229d dev eth0 lladdr 3c:37:86:1f:22:9d router REACHABLE
```

| Estado | Significado | Lectura operativa |
|---|---|---|
| `REACHABLE` | Confirmado dentro de `base_reachable_time` | Sano |
| `STALE` | Entrada válida pero sin confirmar | Normal; se sondeará en el próximo uso |
| `DELAY` / `PROBE` | Revalidando activamente | Transitorio |
| `FAILED` | La resolución ARP/NDP no obtuvo respuesta | **Inalcanzable en L2** — VLAN equivocada, máscara de subred equivocada, host caído o descarte por port-security |
| `INCOMPLETE` | Resolución en curso, todavía sin respuesta | Igual que el anterior, más temprano en la línea de tiempo |
| `PERMANENT` | Entrada estática | Alguien la fijó; auditá por qué |

`FAILED` es la señal temprana más decisiva: prueba que se cree que el destino está **on-link** y no respondió en capa 2. Eso elimina toda hipótesis de ruteo, firewall y DNS con un solo comando.

Detección de IP duplicada — el modo de falla que sobrevive a todos los tests de L3 porque ambos hosts *sí* son alcanzables, alternadamente:

```
$ sudo arping -D -I eth0 -c 3 192.168.178.42
ARPING 192.168.178.42 from 0.0.0.0 eth0
Unicast reply from 192.168.178.42 [06:3F:1A:9C:2E:44]  0.712ms
Unicast reply from 192.168.178.42 [AA:BB:CC:11:22:33]  0.844ms
Sent 3 probes (3 broadcast(s))
Received 2 response(s)
```

Dos MACs distintas para una IP ⇒ dirección duplicada. Esperá ~50 % de pérdida de paquetes y resets de TCP que parecen un bug del balanceador de carga.

Para forzar la revalidación después de un failover (la acción correcta cuando una VIP se mueve):

```
$ sudo ip neigh flush dev eth0
$ sudo arping -U -I eth0 -c 3 192.168.178.10      # gratuitous ARP, announce the new owner
```

---

## 5. Capa 3: direccionamiento y ruteo

### 5.1 Direcciones

```
$ ip -brief addr show
lo               UNKNOWN        127.0.0.1/8 ::1/128
eth0             UP             192.168.178.24/24 fe80::43f:1aff:fe9c:2e44/64
eth1             UP             10.20.0.24/16 fe80::43f:1aff:fe9c:2e45/64
cni0             UP             10.42.0.1/24 fe80::e8a3:2fff:fe11:9b02/64
docker0          DOWN           172.17.0.1/16
```

`ip -brief` es la forma a usar en runbooks: una línea por interfaz, grepeable, estable entre versiones. La forma completa importa cuando los lifetimes son relevantes:

```
$ ip addr show dev eth0
2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc mq state UP group default qlen 1000
    link/ether 06:3f:1a:9c:2e:44 brd ff:ff:ff:ff:ff:ff
    inet 192.168.178.24/24 brd 192.168.178.255 scope global dynamic noprefixroute eth0
       valid_lft 41893sec preferred_lft 41893sec
    inet6 fe80::43f:1aff:fe9c:2e44/64 scope link noprefixroute
       valid_lft forever preferred_lft forever
```

Un `valid_lft` que cuenta hacia cero en un host que pierde conectividad cada ~12 horas es un fallo de renovación de DHCP, y ninguna cantidad de análisis de ruteo lo va a encontrar.

**La máscara de red es la segunda falla de L3 más común.** Un `/24` donde la red es `/22` significa que el host cree que cuatro quintos de su propia subred están off-link y manda ese tráfico al gateway — que puede o no hacerle hairpin. Síntoma: algunos peers de «la misma subred» funcionan, otros no, y el conjunto que funciona correlaciona con el tercer octeto.

### 5.2 Ruteo, y el único comando de ruteo que importa

```
$ ip route show
default via 192.168.178.1 dev eth0 proto dhcp src 192.168.178.24 metric 100
10.20.0.0/16 dev eth1 proto kernel scope link src 10.20.0.24 metric 101
10.42.0.0/24 dev cni0 proto kernel scope link src 10.42.0.1
169.254.0.0/16 dev eth0 scope link metric 1000
192.168.178.0/24 dev eth0 proto kernel scope link src 192.168.178.24 metric 100
```

Leer una tabla de ruteo a ojo es una simulación propensa a errores de longest-prefix match combinada con comparación de métricas combinada con reglas de política. No lo hagas. Preguntale al kernel:

```
$ ip route get 10.42.7.19
10.42.7.19 dev cni0 src 10.42.0.1 uid 1000
    cache

$ ip route get 8.8.8.8
8.8.8.8 via 192.168.178.1 dev eth0 src 192.168.178.24 uid 1000
    cache

$ ip route get 10.99.0.5
RTNETLINK answers: Network is unreachable
```

`ip route get` es el comando de mayor valor de todo este tema. Devuelve la interfaz de salida **exacta**, el nexthop y —crítico— la **dirección de origen** que el kernel va a estampar en el paquete. Una dirección de origen equivocada es la causa de la mayoría de los incidentes de «ruteo asimétrico»: la respuesta vuelve por otra interfaz y `rp_filter` se la come.

Para comprobar si el policy routing está redirigiendo tu tráfico:

```
$ ip rule show
0:	from all lookup local
32764:	from all fwmark 0x2000/0x2000 lookup 200
32765:	from 10.20.0.24 lookup vpn
32766:	from all lookup main
32767:	from all lookup default

$ ip route show table vpn
default via 10.20.0.1 dev eth1
```

Los hosts multi-homed, WireGuard, Cilium, Calico y cualquier service mesh con redirección transparente instalan reglas acá. `ip route show` por sí solo muestra únicamente `main` y te va a desorientar con total confianza.

### 5.3 Filtrado de camino inverso (reverse-path filtering)

```
$ sysctl net.ipv4.conf.all.rp_filter net.ipv4.conf.eth1.rp_filter
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.eth1.rp_filter = 1
```

| Valor | Comportamiento | Cuándo rompe producción |
|---|---|---|
| `0` | Sin verificación | Nunca; pero permite spoofing |
| `1` | **Estricto** (RFC 3704): descarta si la ruta inversa hacia el origen no usa la *misma* interfaz | Cualquier camino asimétrico — servidores dual-homed, balanceadores DSR, VRRP, nodos de Kubernetes multi-NIC |
| `2` | **Laxo**: descarta solo si el origen es inalcanzable por *cualquier* interfaz | Valor por defecto seguro para hosts multi-homed |

El kernel toma `max(all, <iface>)`, así que poner `net.ipv4.conf.eth1.rp_filter=2` por sí solo no hace nada mientras `all` valga `1`. Los descartes se cuentan, no se loguean:

```
$ nstat -az | grep -i martian
IpExtInNoRoutes                 0                  0.0
IpReversePathFilter             38412              0.0
```

Un `IpReversePathFilter` distinto de cero y *creciente* es prueba, no inferencia.

### 5.4 Alcanzabilidad: `ping`

```
$ ping -c 4 -i 0.2 192.168.178.1
PING 192.168.178.1 (192.168.178.1) 56(84) bytes of data.
64 bytes from 192.168.178.1: icmp_seq=1 ttl=64 time=0.681 ms
64 bytes from 192.168.178.1: icmp_seq=2 ttl=64 time=0.594 ms
64 bytes from 192.168.178.1: icmp_seq=3 ttl=64 time=0.612 ms
64 bytes from 192.168.178.1: icmp_seq=4 ttl=64 time=0.577 ms

--- 192.168.178.1 ping statistics ---
4 packets transmitted, 4 received, 0% packet loss, time 604ms
rtt min/avg/max/mdev = 0.577/0.616/0.681/0.039 ms
```

Opciones con peso diagnóstico:

| Opción | Propósito | Uso diagnóstico |
|---|---|---|
| `-c N` | Detenerse tras N | Nunca ejecutes un `ping` sin límite en un script |
| `-i S` | Intervalo (sub-segundo requiere root) | Tasa de muestreo para estimar pérdida |
| `-W S` | Timeout por respuesta | Distinguir «lento» de «perdido» |
| `-I <if\|addr>` | Forzar interfaz/dirección de origen | **Probar el comportamiento multi-homing** |
| `-s N` | Tamaño del payload | Sondeo de MTU (ver §7) |
| `-M do` | Fijar DF, nunca fragmentar | Detección de agujero negro de PMTU |
| `-n` | Sin DNS inverso | Elimina una dependencia de DNS de un test de L3 |
| `-f` | Flood | Solo para pruebas de carga; requiere root |
| `-4` / `-6` | Forzar familia | Desambiguación dual-stack |

Interpretar las respuestas de *error* es donde está el valor:

| Respuesta | Tipo/código ICMP | Significado |
|---|---|---|
| `Destination Host Unreachable` **desde el propio origen** | 3/1 generado localmente | Falló ARP — L2, on-link |
| `Destination Host Unreachable` **desde un router** | 3/1 | El router de último salto no pudo hacer ARP al destino |
| `Destination Net Unreachable` | 3/0 | Un router no tiene ruta |
| `Destination Port Unreachable` | 3/3 | Solo desde sondas UDP; significa que el host está vivo |
| `Communication prohibited by filter` | 3/13 | Un reject **administrativo** del firewall — encontraste la política |
| `Frag needed and DF set (mtu = 1400)` | 3/4 | Señal de PMTU; ver §7 |
| `Time to live exceeded` | 11/0 | Bucle de ruteo |
| Nada en absoluto | — | `DROP` silencioso, o el host está apagado |

La distinción entre **silencio** y **`prohibited by filter`** es la distinción entre `DROP` y `REJECT` en el firewall. `DROP` es lo que te vas a encontrar en los security groups de la nube; también es lo que hace que un problema de firewall parezca un host muerto.

**Que `ping` falle no significa inalcanzable.** El echo de ICMP se bloquea rutinariamente mientras TCP/443 está abierto. Nunca concluyas «host caído» solo por `ping` — escalá a §6.4.

IPv6 usa el mismo binario en las distribuciones modernas (`ping -6`); `ping6` permanece como symlink de compatibilidad y es el que nombran los objetivos del examen. Las direcciones link-local **requieren** un índice de zona:

```
$ ping -6 -c 2 fe80::3e37:86ff:fe1f:229d%eth0
PING fe80::3e37:86ff:fe1f:229d%eth0 (fe80::3e37:86ff:fe1f:229d%eth0) 56 data bytes
64 bytes from fe80::3e37:86ff:fe1f:229d%eth0: icmp_seq=1 ttl=64 time=0.489 ms
64 bytes from fe80::3e37:86ff:fe1f:229d%eth0: icmp_seq=2 ttl=64 time=0.451 ms
```

---

## 6. Camino y transporte

### 6.1 `traceroute`, `tracepath`, `mtr` — elegir la sonda

Las tres explotan la expiración del TTL: enviar con TTL=1, recolectar el ICMP `time exceeded` del salto 1, incrementar, repetir. Difieren en el protocolo de la sonda, que determina **qué le van a hacer los firewalls del camino**.

| Herramienta | Sonda por defecto | Requiere root | Descubrimiento de PMTU | Continuo | Mejor para |
|---|---|---|---|---|---|
| `traceroute` | UDP, puertos destino 33434+ | No (Linux, UDP sin privilegios) | No | No | Mapeo genérico del camino |
| `traceroute -I` | ICMP echo | Sí (raw socket) | No | No | Caminos donde UDP está filtrado |
| `traceroute -T -p 443` | **TCP SYN** | Sí | No | No | **Caminos donde solo el puerto del servicio está permitido** |
| `traceroute -U -p 53` | UDP a un puerto elegido | No | No | No | Apuntar a un servicio UDP específico |
| `tracepath` | UDP, sin privilegios | **No** | **Sí** | No | Caza de agujeros negros de MTU, hosts sin privilegios |
| `mtr` | ICMP (`-T` para TCP, `-u` para UDP) | Sí para ICMP | No | **Sí** | **Pérdida intermitente y jitter** |

```
$ traceroute -n -q 1 -w 2 1.1.1.1
traceroute to 1.1.1.1 (1.1.1.1), 30 hops max, 60 byte packets
 1  192.168.178.1  0.694 ms
 2  100.64.12.1  8.112 ms
 3  10.250.4.9  8.884 ms
 4  * 
 5  62.115.120.14  11.203 ms
 6  62.115.136.207  11.917 ms
 7  1.1.1.1  11.402 ms
```

**Que el salto 4 muestre `*` casi nunca es la falla.** A los routers se les permite limitar la tasa o suprimir el ICMP `time exceeded` mientras reenvían el tráfico de tránsito perfectamente. La única lectura significativa de un traceroute es:

- Pérdida que **empieza en el salto N y persiste hasta el salto final** ⇒ un problema real en o después del salto N.
- Pérdida en el salto N que **desaparece en el salto N+1** ⇒ rate limiting de ICMP en el salto N. Ignoralo.
- El trace **se detiene por completo** y nunca llega al destino ⇒ real; el último salto que responde es la frontera.
- Los **saltos asimétricos de latencia** son con frecuencia el camino de vuelta, que traceroute no puede ver.

`mtr` es lo que convierte una sospecha en un número, porque sigue sondeando:

```
$ mtr --report --report-cycles 100 --no-dns 1.1.1.1
Start: 2026-08-27T14:02:11+0000
HOST: ingress-03                  Loss%   Snt   Last   Avg  Best  Wrst StDev
  1.|-- 192.168.178.1              0.0%   100    0.7   0.7   0.6   1.9   0.2
  2.|-- 100.64.12.1                0.0%   100    8.1   8.4   7.9  22.4   1.6
  3.|-- 10.250.4.9                42.0%   100    8.9   9.1   8.6  19.8   1.4
  4.|-- ???                       100.0%   100    0.0   0.0   0.0   0.0   0.0
  5.|-- 62.115.120.14              0.0%   100   11.2  11.6  11.0  28.7   2.1
  6.|-- 62.115.136.207             0.0%   100   11.9  12.1  11.6  24.0   1.3
  7.|-- 1.1.1.1                    0.0%   100   11.4  11.7  11.2  25.9   1.5
```

Lectura de manual: los saltos 3 y 4 muestran pérdida, el salto 7 muestra **0.0 %**. Por lo tanto el tránsito está limpio y ambos son rate limiting de ICMP en el plano de control. No corresponde escalar. Si el salto 7 hubiera mostrado 42 %, el salto 3 sería la frontera a escalar.

### 6.2 `ss` — la tabla de sockets

```
$ ss -tulpn
Netid State  Recv-Q Send-Q     Local Address:Port    Peer Address:Port Process
udp   UNCONN 0      0          127.0.0.53%lo:53           0.0.0.0:*     users:(("systemd-resolve",pid=812,fd=13))
udp   UNCONN 0      0                0.0.0.0:68           0.0.0.0:*     users:(("dhclient",pid=1104,fd=7))
tcp   LISTEN 0      4096       127.0.0.53%lo:53           0.0.0.0:*     users:(("systemd-resolve",pid=812,fd=14))
tcp   LISTEN 0      128              0.0.0.0:22           0.0.0.0:*     users:(("sshd",pid=1391,fd=3))
tcp   LISTEN 0      511            127.0.0.1:8080         0.0.0.0:*     users:(("gunicorn",pid=2244,fd=5))
tcp   LISTEN 0      4096                   *:443                *:*     users:(("envoy",pid=3018,fd=41))
```

Descomposición de flags: `-t` TCP, `-u` UDP, `-l` en escucha, `-p` proceso propietario (requiere privilegios), `-n` numérico, `-a` todos, `-4`/`-6` familia, `-s` resumen, `-i` información interna de TCP, `-e` extendido, `-m` memoria, `-o` timers.

Dos lecturas que tenés que internalizar:

1. **`127.0.0.1:8080` versus `0.0.0.0:8080`.** Un servicio ligado a loopback es inalcanzable desde cualquier otro host, y ningún cambio de firewall lo va a arreglar. Esta es la causa más común de «el puerto está abierto pero no me puedo conectar». `*:443` / `[::]:443` significa todas las direcciones, ambas familias (cuando `net.ipv6.bindv6only=0`).

2. **En un socket `LISTEN`, `Recv-Q` y `Send-Q` no significan lo que significan en otros lados.** `Recv-Q` es la cantidad actual de conexiones establecidas pero todavía no `accept()`adas; `Send-Q` es el máximo de backlog configurado. Un `Recv-Q` acercándose a `Send-Q` significa que la aplicación no está llamando a `accept()` lo bastante rápido y el kernel está descartando SYNs — lo que el cliente experimenta como un timeout de conexión inexplicable.

```
$ ss -lnt 'sport = :8080'
State  Recv-Q Send-Q  Local Address:Port  Peer Address:Port
LISTEN 511    511         127.0.0.1:8080        0.0.0.0:*
```

Confirmá los descartes en lugar de adivinar:

```
$ nstat -az | grep -E 'ListenDrops|ListenOverflows|SynRetrans'
TcpExtListenOverflows           14822              0.0
TcpExtListenDrops               14822              0.0
TcpExtTCPSynRetrans             983                0.0
```

`ListenOverflows` == `ListenDrops` y ambos subiendo ⇒ agotamiento del backlog, definitivamente. El arreglo es `net.core.somaxconn` **y** el argumento de backlog del `listen()` de la aplicación — subir solo el sysctl no cambia nada.

Resumen y filtrado por estado:

```
$ ss -s
Total: 1892
TCP:   1204 (estab 618, closed 402, orphaned 3, timewait 398)

Transport Total     IP        IPv6
RAW	  1         0         1
UDP	  14        9         5
TCP	  802       688       114
INET	  817       697       120
FRAG	  0         0         0

$ ss -tan state time-wait | wc -l
399

$ ss -tan state syn-sent
State   Recv-Q Send-Q  Local Address:Port    Peer Address:Port
SYN-SENT 0     1      192.168.178.24:52104   10.20.7.9:5432
```

Un socket trabado en `SYN-SENT` es inequívoco: **el SYN salió y no volvió nada.** Eso es un firewall descartando en silencio, una ruta agujero negro o un host muerto — nunca un problema de TLS, de autenticación o de aplicación.

Telemetría de transporte por conexión, para la clase de ticket «está lento»:

```
$ ss -tin dst 10.20.7.9
State Recv-Q Send-Q    Local Address:Port     Peer Address:Port
ESTAB 0      0        192.168.178.24:52180      10.20.7.9:5432
	 cubic wscale:7,7 rto:236 rtt:34.812/2.104 ato:40 mss:1348 pmtu:1400
	 rcvmss:536 advmss:1448 cwnd:10 ssthresh:7 bytes_sent:184219
	 bytes_retrans:29104 bytes_acked:155115 segs_out:412 segs_in:388
	 send 3.1Mbps lastsnd:12 lastrcv:8 pacing_rate 6.2Mbps
	 delivery_rate 2.9Mbps retrans:0/61 rcv_rtt:36 rcv_space:14480 minrtt:33.9
```

Tres campos deciden el caso: `retrans:0/61` (61 retransmisiones acumuladas en una conexión de vida corta = camino con pérdida), `cwnd:10` clavado en la ventana inicial con `ssthresh:7` (el control de congestión colapsó), y `mss:1348` contra `advmss:1448` (**la MTU del camino es 1400, no 1500** — pasá a §7).

### 6.3 `netcat` — la sonda de capa de transporte

`nc` establece si un handshake TCP se completa o si un datagrama UDP provoca una respuesta, sin involucrar el protocolo de aplicación. Es la contraparte de L4 de `ping`.

```
$ nc -zv -w 3 10.20.7.9 5432
Connection to 10.20.7.9 5432 port [tcp/postgresql] succeeded!

$ nc -zv -w 3 10.20.7.9 6379
nc: connect to 10.20.7.9 port 6379 (tcp) failed: Connection refused

$ nc -zv -w 3 10.20.7.9 9200
nc: connect to 10.20.7.9 port 9200 (tcp) timed out: Operation now in progress
```

Los tres resultados son tres causas raíz diferentes y nunca deben confundirse:

| Resultado | Evento en el cable | Causa raíz | Siguiente acción |
|---|---|---|---|
| `succeeded` | SYN → SYN/ACK | L3 + L4 + listener todos probados | Pasar a L7 |
| `Connection refused` (`ECONNREFUSED`) | SYN → RST | **Llegó al host**; nada escuchando, o una regla `REJECT` | `ss -lnt` en el destino |
| `timed out` (`ETIMEDOUT`) | SYN → silencio | `DROP` de firewall, ruta agujero negro, host equivocado | `tcpdump` en ambas puntas |
| `No route to host` (`EHOSTUNREACH`) | Falló ARP / ICMP 3/1 | L2 o ruteo del último salto | `ip neigh`, §4.3 |
| `Network is unreachable` (`ENETUNREACH`) | Sin ruta en la FIB | Tabla de ruteo **local** | `ip route get` |

`Connection refused` es un *buen* resultado durante un incidente: prueba todas las capas por debajo de la aplicación. Quienes recién empiezan lo leen como falla; es la señal positiva más fuerte después del éxito.

Flags portables: `-z` escanear sin enviar datos, `-v` verbose, `-w N` timeout, `-u` UDP, `-l` escuchar, `-p` puerto de origen, `-n` sin DNS, `-4`/`-6` familia.

Validación bidireccional del camino — corré el listener en el destino, la sonda en el cliente:

```
# on 10.20.7.9
$ nc -l 9999
hello from ingress-03

# on the client
$ echo "hello from ingress-03" | nc -N 10.20.7.9 9999
```

Este es el test definitivo de «¿está permitido este puerto de punta a punta?», independiente de cualquier aplicación.

El sondeo UDP es fundamentalmente más débil y hay que entenderlo así: sin handshake, `nc -zu` reporta éxito cada vez que el datagrama fue *enviado*, y solo reporta falla si llega un ICMP port-unreachable — que los firewalls habitualmente suprimen.

```
$ nc -zvu -w 3 10.20.7.9 53
Connection to 10.20.7.9 53 port [udp/domain] succeeded!
```

Esa salida es casi carente de significado para UDP. Para un servicio UDP, sondeá con el protocolo real: `dig @10.20.7.9`, `ntpdate -q`, `snmpget`.

Transferir un archivo, la demostración canónica de `nc` (primero el receptor):

```
# receiver
$ nc -l 9000 > payload.tar.gz

# sender
$ nc -N 10.20.7.9 9000 < payload.tar.gz
```

`-N` (variante openbsd) cierra el socket al llegar EOF; sin eso el receptor queda colgado para siempre esperando un cierre. Notá lo obvio: esto es texto plano sin autenticación ni verificación de integridad. Es una herramienta de diagnóstico, no un transporte.

### 6.4 Verdad de terreno a nivel de paquete: `tcpdump`

Cuando las capas se contradicen, capturá. `tcpdump` responde «¿llegó el paquete?» y «¿salió algo?», lo que ningún contador puede discutir.

```
$ sudo tcpdump -ni eth0 -c 20 'tcp port 5432 and host 10.20.7.9'
tcpdump: verbose output suppressed, use -v[v]... for full protocol decode
listening on eth0, link-type EN10MB (Ethernet), snapshot length 262144 bytes
14:11:02.418822 IP 192.168.178.24.52190 > 10.20.7.9.5432: Flags [S], seq 2841932011, win 62727, options [mss 1460,sackOK,TS val 1029384 ecr 0,nop,wscale 7], length 0
14:11:03.441093 IP 192.168.178.24.52190 > 10.20.7.9.5432: Flags [S], seq 2841932011, win 62727, options [mss 1460,sackOK,TS val 1030407 ecr 0,nop,wscale 7], length 0
14:11:05.489100 IP 192.168.178.24.52190 > 10.20.7.9.5432: Flags [S], seq 2841932011, win 62727, options [mss 1460,sackOK,TS val 1032455 ecr 0,nop,wscale 7], length 0
^C
3 packets captured
```

Tres SYNs a 1 s, 2 s, 4 s con backoff exponencial y sin SYN/ACK: el paquete salió de este host. Capturá en el *destino* para bisecar más — si llega ahí, el descarte está en el camino de vuelta o en la cadena `INPUT` del destino; si no llega, el descarte está en tránsito.

Invocación esencial:

| Flag | Efecto |
|---|---|
| `-n` | Sin resolución de nombres (**siempre** — el DNS durante un incidente de red cuelga la captura) |
| `-nn` | Tampoco resolución de nombres de puerto |
| `-i <if>` / `-i any` | Interfaz; `any` es una captura cooked sobre todas |
| `-c N` | Detenerse tras N paquetes |
| `-s0` | Paquete completo (el snaplen por defecto ya es 262144 en versiones modernas) |
| `-w file.pcap` | Escribir crudo, para Wireshark |
| `-r file.pcap` | Releer |
| `-e` | Mostrar cabeceras Ethernet — necesario para preguntas de nivel MAC y de VLAN |
| `-vvv` | Decodificación completa |
| `-A` / `-X` | Payload en ASCII / hex |
| `-Q in\|out` | Filtro de dirección |

Modismos de filtros BPF que vale la pena memorizar:

```
'host 10.20.7.9'                          # either direction
'src net 10.42.0.0/16'
'tcp port 443 or tcp port 80'
'tcp[tcpflags] & (tcp-syn|tcp-rst) != 0'  # handshake starts and resets only
'icmp[icmptype] == icmp-unreach'          # every ICMP unreachable, incl. frag-needed
'arp'
'udp port 53'
'vlan and host 10.20.7.9'
'not port 22'                             # never capture your own SSH session
```

Dos reglas operativas: acotá siempre la captura (`-c`, `timeout`, o rotación `-W`/`-G`) — un `tcpdump -w` sin límite en un nodo de ingress llena el filesystem raíz y convierte un incidente de red en una caída — y agregá siempre `not port 22` cuando captures en la interfaz que transporta tu sesión, o la captura se va a grabar a sí misma recursivamente.

---

## 7. MTU y el agujero negro de PMTU

Este es el modo de falla que derrota todos los tests básicos, y es endémico de las redes overlay (VXLAN, IPsec, WireGuard, GRE) — es decir, de esencialmente todas las plataformas de contenedores.

Mecanismo: TCP negocia un MSS a partir de la MTU de la interfaz *local*. Un túnel más adelante en el camino tiene una MTU menor. Un router envía ICMP tipo 3 código 4 (`fragmentation needed, DF set`) llevando la MTU correcta. Si un firewall descarta ese ICMP, el emisor nunca se entera y retransmite el segmento sobredimensionado para siempre.

La firma es diagnóstica por sí sola: **el handshake tiene éxito, las peticiones chicas tienen éxito, las grandes se cuelgan.** `ping` funciona (84 bytes). `nc -z` funciona (solo SYN). `curl` recupera las cabeceras y después se traba.

| Encapsulación | Overhead | MTU dentro de un camino de 1500 B |
|---|---|---|
| Ninguna (Ethernet) | 0 | 1500 |
| 802.1Q VLAN | 4 | 1496 |
| PPPoE | 8 | 1492 |
| GRE | 24 | 1476 |
| VXLAN (IPv4) | 50 | 1450 |
| VXLAN (IPv6) | 70 | 1430 |
| WireGuard (IPv4) | 60 | 1440 |
| IPsec ESP (túnel, AES-GCM) | ~73 | ~1427 |
| VXLAN sobre un camino jumbo de 9001 B de AWS | 50 | 8951 |

Sondear la MTU real del camino, de arriba hacia abajo. `-M do` fija DF; `-s` es el **payload**, así que el paquete IPv4 total = payload + 8 (ICMP) + 20 (IP):

```
$ ping -M do -s 1472 -c 1 10.20.7.9
PING 10.20.7.9 (10.20.7.9) 1472(1500) bytes of data.
ping: local error: message too long, mtu=1450

$ ping -M do -s 1422 -c 1 10.20.7.9
PING 10.20.7.9 (10.20.7.9) 1422(1450) bytes of data.
1430 bytes from 10.20.7.9: icmp_seq=1 ttl=63 time=1.204 ms

--- 10.20.7.9 ping statistics ---
1 packets transmitted, 1 received, 0% packet loss, time 0ms
```

MTU del camino = 1450. `tracepath` la encuentra automáticamente e identifica el salto donde cambia:

```
$ tracepath -n 10.20.7.9
 1?: [LOCALHOST]                      pmtu 1500
 1:  192.168.178.1                     0.712ms
 2:  100.64.12.1                       8.201ms
 3:  10.250.4.9                        8.884ms asymm  4
 3:  10.250.4.9                        8.902ms pmtu 1450
 4:  10.20.7.9                         9.412ms reached
     Resume: pmtu 1450 hops 4 back 4
```

`tracepath` no requiere privilegios y reporta tanto la PMTU como la asimetría — por eso pertenece al kit de primera respuesta antes que `traceroute`.

Mitigaciones, en orden de corrección:

1. **Arreglar el filtro de ICMP.** Permitir ICMP tipo 3 código 4 entrante. Todo lo demás es un workaround.
2. **Fijar correctamente la MTU de la interfaz** en el túnel y en las cargas de trabajo que van sobre él.
3. **MSS clamping** en el borde — reescribir la opción MSS en los SYN en tránsito:
   ```
   $ sudo nft add rule inet filter forward tcp flags syn tcp option maxseg size set rt mtu
   ```
4. **`tcp_mtu_probing`** — dejar que TCP haga búsqueda binaria de la MTU cuando las retransmisiones se estancan:
   ```
   $ sudo sysctl -w net.ipv4.tcp_mtu_probing=1
   ```
   `0` apagado, `1` habilitar al detectar un agujero negro de ICMP, `2` siempre activo empezando desde `tcp_base_mss`.

---

## 8. Resolución de nombres: NSS no es DNS

El error conceptual más persistente en este tema es tratar a `dig` como un test de «¿resuelve el nombre?». `dig` y `host` hablan DNS directamente con un servidor; **las aplicaciones no**. Las aplicaciones llaman a `getaddrinfo(3)`, que consulta el Name Service Switch.

| Herramienta | Camino ejercitado | ¿Lee `/etc/hosts`? | ¿Lee `/etc/nsswitch.conf`? | ¿Usa el stub de `systemd-resolved`? | Usala para responder |
|---|---|---|---|---|---|
| `getent hosts <name>` | **NSS completo** | Sí | Sí | Sí | *«¿Qué va a obtener mi aplicación?»* |
| `getent ahostsv4` / `ahostsv6` | NSS completo, familia forzada | Sí | Sí | Sí | Orden dual-stack |
| `resolvectl query <name>` | `systemd-resolved` | Sí | Parcialmente | Sí | Ruteo de resolver por enlace |
| `host <name>` | Solo DNS | **No** | **No** | Solo vía `/etc/resolv.conf` | *«¿Qué dice el DNS?»* — rápido |
| `dig <name>` | Solo DNS | **No** | **No** | Solo vía `/etc/resolv.conf` | Forense completo de DNS |
| `nslookup` | Solo DNS | No | No | Vía `/etc/resolv.conf` | Legacy; evitalo, la salida es ambigua |

**Un `dig` que funciona con una aplicación que falla es normal y esperable** cuando `nsswitch.conf` está mal ordenado, `/etc/hosts` tiene una entrada obsoleta, o `systemd-resolved` rutea ese dominio a otro enlace.

### 8.1 `/etc/nsswitch.conf`

```
$ grep -E '^(hosts|networks):' /etc/nsswitch.conf
hosts:          files mdns4_minimal [NOTFOUND=return] dns myhostname
networks:       files
```

Las fuentes se prueban de izquierda a derecha. La sintaxis de acción `[STATUS=action]` hace cortocircuito: `[NOTFOUND=return]` después de `mdns4_minimal` significa que un «no existe ese nombre `.local`» autoritativo **detiene la consulta y nunca llega a `dns`**. Un host llamado `printer.local` en una zona DNS interna, por lo tanto, no resuelve mientras `dig printer.local` sí tiene éxito — un incidente reproducible y absolutamente no obvio.

Módulos comunes: `files` (`/etc/hosts`), `dns` (`/etc/resolv.conf`), `myhostname` (el propio hostname, `localhost`, `_gateway`), `resolve` (`systemd-resolved` vía D-Bus), `mymachines` (contenedores de `systemd-machined`), `mdns4_minimal` (Avahi).

### 8.2 `/etc/hosts`

```
$ cat /etc/hosts
127.0.0.1       localhost
::1             localhost ip6-localhost ip6-loopback
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters

192.168.178.24  ingress-03.prod.example.com ingress-03
10.20.7.9       db-primary.prod.example.com db-primary
```

Formato: `<address> <canonical-name> [aliases…]`. Se consulta antes que DNS dondequiera que `files` preceda a `dns`, que es casi siempre. Por eso exactamente una entrada obsoleta en `/etc/hosts` sobrevive a todo arreglo de DNS, a toda expiración de TTL y a todo flush de caché. **Leé `/etc/hosts` antes de creerte cualquier hipótesis de DNS.**

El FQDN debe preceder a los alias cortos en la línea; varias herramientas toman el segundo campo como el nombre canónico y, si no, devolverán un nombre corto pelado para `hostname -f`.

### 8.3 `/etc/resolv.conf`

```
$ cat /etc/resolv.conf
nameserver 10.20.0.10
nameserver 10.20.0.11
search prod.example.com example.com
options timeout:1 attempts:2 rotate ndots:2 single-request-reopen
```

| Directiva | Semántica | Consecuencia en producción |
|---|---|---|
| `nameserver` | Se honran hasta **3**; los extras se ignoran en silencio | Listar cinco te da tres |
| `search` | Sufijos que se agregan a los nombres cortos | Cada fallo es un round trip completo |
| `domain` | Sufijo único; **mutuamente excluyente** con `search` (gana el último) | Legacy; usá `search` |
| `options ndots:N` | Los nombres con ≥ N puntos se prueban primero como absolutos | El clásico de latencia de Kubernetes |
| `options timeout:N` | Segundos por servidor (por defecto 5) | El valor por defecto significa que un resolver muerto cuesta 5 s |
| `options attempts:N` | Rondas sobre la lista completa (por defecto 2) | Peor caso = `timeout × attempts × servidores` |
| `options rotate` | Round-robin en lugar de estrictamente en orden | Distribuye la carga; oculta un primer servidor muerto |
| `options single-request-reopen` | Sockets separados para las consultas A y AAAA | Sortea middleboxes rotos que descartan una de un par paralelo |

La aritmética del failover importa: con los valores por defecto y tres nameservers, la caída del primer servidor cuesta `5 s × 2 intentos` antes de que se pruebe el segundo. Las aplicaciones expiran mucho antes de que el resolver se rinda. `timeout:1 attempts:2` es el ajuste correcto para producción.

`ndots:5` —el valor por defecto de Kubernetes— significa que `api.example.com` (2 puntos < 5) se trata como relativo y se prueba primero contra **cada** entrada de `search`. Con cuatro dominios de búsqueda eso son 8 consultas desperdiciadas (A + AAAA de cada una) antes de la consulta absoluta correcta. Visible de inmediato:

```
$ dig +short +search api.example.com > /dev/null
$ sudo tcpdump -ni any -c 12 'udp port 53'
14:22:31.100 IP 10.42.0.7.41522 > 10.43.0.10.53: 1+ A? api.example.com.default.svc.cluster.local. (59)
14:22:31.100 IP 10.42.0.7.41522 > 10.43.0.10.53: 2+ AAAA? api.example.com.default.svc.cluster.local. (59)
14:22:31.101 IP 10.43.0.10.53 > 10.42.0.7.41522: 1 NXDomain 0/1/0 (152)
14:22:31.101 IP 10.43.0.10.53 > 10.42.0.7.41522: 2 NXDomain 0/1/0 (152)
14:22:31.102 IP 10.42.0.7.41529 > 10.43.0.10.53: 3+ A? api.example.com.svc.cluster.local. (51)
...
```

El punto final —`dig api.example.com.`— hace el nombre absoluto y saltea por completo la expansión de search. Ese es el arreglo, aplicado en la configuración de la aplicación.

**`/etc/resolv.conf` se genera en la mayoría de los sistemas modernos.** Editarlo directamente se sobrescribe en la siguiente concesión DHCP o cambio de enlace:

```
$ ls -l /etc/resolv.conf
lrwxrwxrwx 1 root root 39 Jun  2 09:11 /etc/resolv.conf -> ../run/systemd/resolve/stub-resolv.conf
```

Un symlink hacia `/run/systemd/` significa que la autoridad es `systemd-resolved`; editá la unit o el perfil de NetworkManager, nunca el archivo.

### 8.4 `systemd-resolved`

```
$ resolvectl status
Global
       Protocols: LLMNR=resolve -mDNS -DNSOverTLS DNSSEC=no/unsupported
resolv.conf mode: stub

Link 2 (eth0)
    Current Scopes: DNS LLMNR/IPv4
         Protocols: +DefaultRoute +LLMNR -mDNS -DNSOverTLS DNSSEC=no/unsupported
Current DNS Server: 10.20.0.10
       DNS Servers: 10.20.0.10 10.20.0.11
        DNS Domain: prod.example.com

Link 3 (wg0)
    Current Scopes: DNS
         Protocols: -DefaultRoute -LLMNR -mDNS -DNSOverTLS DNSSEC=no/unsupported
Current DNS Server: 10.99.0.53
       DNS Servers: 10.99.0.53
        DNS Domain: ~corp.internal
```

`~corp.internal` es un **dominio solo de ruteo**: las consultas por `*.corp.internal` van exclusivamente al resolver de la VPN; todo lo demás va al de `eth0`. El `-DefaultRoute` en `wg0` impide que reciba consultas no relacionadas. Este comportamiento de split-horizon es invisible para `dig`, que habla con `127.0.0.53` y solo ve el resultado combinado — otra razón por la que `dig` solo no puede cerrar un incidente de resolución en un host con systemd.

```
$ resolvectl query db-primary.prod.example.com
db-primary.prod.example.com: 10.20.7.9                        -- link: eth0

-- Information acquired via protocol DNS in 4.1ms.
-- Data is authenticated: no; Data was acquired via local or encrypted transport: no
-- Data from: network

$ resolvectl statistics
DNSSEC Verdicts
Secure: 0    Insecure: 0    Bogus: 0    Indeterminate: 0

Transactions
Current Transactions: 0
  Total Transactions: 84129

Cache
  Current Cache Size: 412
          Cache Hits: 71204
        Cache Misses: 12925

$ sudo resolvectl flush-caches
```

Una tasa de aciertos alta con usuarios reportando registros obsoletos significa que la caché está honrando un TTL largo; hacé flush y arreglá el TTL de la zona.

### 8.5 `host` y `dig`

```
$ host db-primary.prod.example.com
db-primary.prod.example.com has address 10.20.7.9

$ host -t MX example.com
example.com mail is handled by 10 mail1.example.com.
example.com mail is handled by 20 mail2.example.com.

$ host 10.20.7.9
9.7.20.10.in-addr.arpa domain name pointer db-primary.prod.example.com.

$ host -v -t NS example.com 10.20.0.11        # query a specific server
```

`dig` para todo lo que requiera evidencia:

```
$ dig db-primary.prod.example.com

; <<>> DiG 9.18.24 <<>> db-primary.prod.example.com
;; global options: +cmd
;; Got answer:
;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 41207
;; flags: qr rd ra; QUERY: 1, ANSWER: 1, AUTHORITY: 0, ADDITIONAL: 1

;; OPT PSEUDOSECTION:
; EDNS: version: 0, flags:; udp: 1232
;; QUESTION SECTION:
;db-primary.prod.example.com.	IN	A

;; ANSWER SECTION:
db-primary.prod.example.com. 300 IN	A	10.20.7.9

;; Query time: 4 msec
;; SERVER: 127.0.0.53#53(127.0.0.53) (UDP)
;; WHEN: Thu Aug 27 14:31:02 UTC 2026
;; MSG SIZE  rcvd: 83
```

La cabecera es la carga forense:

| Campo | Lectura |
|---|---|
| `status: NOERROR` + `ANSWER: 0` | El nombre existe pero **no tiene registro de ese tipo** — NODATA, no NXDOMAIN |
| `status: NXDOMAIN` | El nombre no existe |
| `status: SERVFAIL` | Falla del resolver — upstream inalcanzable o falló la validación DNSSEC |
| `status: REFUSED` | El servidor se niega a responderte (ACL) |
| `flags: aa` | Respuesta autoritativa |
| `flags: ra` ausente | El servidor no ofrece recursión |
| `flags: tc` | Truncada — el cliente debe reintentar sobre TCP |
| `SERVER:` | **Qué resolver respondió realmente** — verificá esto antes que nada |

```
$ dig +short @10.20.0.11 db-primary.prod.example.com A
10.20.7.9

$ dig +trace example.com                 # full delegation chain from the root
$ dig +norecurse @ns1.example.com example.com    # is this server authoritative?
$ dig +tcp example.com                   # force TCP — proves 53/tcp is open
$ dig -x 10.20.7.9 +short                # reverse
$ dig SOA prod.example.com +short        # serial: are the secondaries in sync?
```

Confirmar la división NSS-vs-DNS en dos comandos:

```
$ dig +short db-primary.prod.example.com
10.20.7.9
$ getent hosts db-primary.prod.example.com
10.20.99.99     db-primary.prod.example.com
```

Respuestas distintas ⇒ la divergencia está en `/etc/hosts` o en `nsswitch.conf`, y el DNS no es el problema.

### 8.6 `hostname` y los archivos de apoyo

```
$ hostname
ingress-03
$ hostname -f
ingress-03.prod.example.com
$ hostname -d
prod.example.com
$ hostname -I
192.168.178.24 10.20.0.24 10.42.0.1
$ hostnamectl status
 Static hostname: ingress-03
       Icon name: computer-vm
         Chassis: vm
      Machine ID: 4a1f9c2e88b64f0d9a7b3e1c5d2f8a06
         Boot ID: 9e2c17a4b3d84f1e8c5a0b6d7f3e2914
  Virtualization: kvm
Operating System: Debian GNU/Linux 12 (bookworm)
          Kernel: Linux 6.1.0-18-amd64
    Architecture: x86-64
```

`hostname -f` requiere que el FQDN sea resoluble — vía `/etc/hosts` o DNS. Si devuelve el nombre corto, `/etc/hosts` tiene los campos en el orden equivocado. Fijá el hostname de forma persistente con `hostnamectl set-hostname`, nunca con `hostname` a secas (que se pierde al reiniciar) y nunca editando `/etc/hostname` sin actualizar también `/etc/hosts`.

`hostname -i` es una trampa en hosts multi-homed: devuelve lo que produzca una única consulta, a menudo `127.0.1.1`. `hostname -I` (mayúscula) lee las interfaces directamente y es correcto.

Dos archivos restantes de los objetivos:

```
$ grep -E '^(https|postgres|domain)' /etc/services
domain          53/tcp
domain          53/udp
https           443/tcp
https           443/udp
postgresql      5432/tcp   postgres
postgresql      5432/udp   postgres

$ cat /etc/networks
default         0.0.0.0
loopback        127.0.0.0
link-local      169.254.0.0
prod-backend    10.20.0.0
```

`/etc/services` es lo que hace que `ss` imprima `[tcp/postgresql]` y lo que usa `nc -z` para los nombres simbólicos de puertos. `/etc/networks` mapea nombres a direcciones de red para `route`/`netstat`; es en gran medida vestigial y es una causa frecuente de salidas confusas de `netstat -r` cuando contiene entradas obsoletas.

---

## 9. Configuraciones completas y desplegables

### 9.1 Netplan (Ubuntu) — host dual-homed con policy routing y MTU explícita

`/etc/netplan/01-prod.yaml`

```yaml
# Dual-homed ingress node.
#   eth0 -> public/edge network, holds the default route
#   eth1 -> backend network, reached only via table 200 to avoid asymmetry
# Applied with:  sudo netplan generate && sudo netplan apply
network:
  version: 2
  renderer: networkd
  ethernets:
    eth0:
      match:
        macaddress: "06:3f:1a:9c:2e:44"
      set-name: eth0
      addresses:
        - 192.168.178.24/24
        - "2001:db8:178::24/64"
      routes:
        - to: default
          via: 192.168.178.1
          metric: 100
          on-link: false
        - to: "::/0"
          via: "2001:db8:178::1"
          metric: 100
      nameservers:
        search:
          - prod.example.com
          - example.com
        addresses:
          - 10.20.0.10
          - 10.20.0.11
      mtu: 1500
      accept-ra: false
      dhcp4: false
      dhcp6: false
      optional: false

    eth1:
      match:
        macaddress: "06:3f:1a:9c:2e:45"
      set-name: eth1
      addresses:
        - 10.20.0.24/16
      mtu: 9000
      dhcp4: false
      dhcp6: false
      accept-ra: false
      # Backend traffic must leave and return on eth1. Without these two
      # stanzas, replies to backend-initiated flows would follow the eth0
      # default route and be discarded by rp_filter on the far side.
      routing-policy:
        - from: 10.20.0.24/32
          table: 200
          priority: 32765
      routes:
        - to: 10.20.0.0/16
          scope: link
          table: 200
        - to: default
          via: 10.20.0.1
          table: 200
          metric: 100
```

Verificación después de aplicar — nunca confíes solo en la salida de `netplan apply`:

```
$ sudo netplan generate && sudo netplan apply
$ ip -brief addr show
$ ip rule show
0:	from all lookup local
32765:	from 10.20.0.24 lookup 200
32766:	from all lookup main
32767:	from all lookup default
$ ip route show table 200
default via 10.20.0.1 dev eth1 metric 100
10.20.0.0/16 dev eth1 scope link
$ ip route get 10.20.7.9 from 10.20.0.24
10.20.7.9 from 10.20.0.24 dev eth1 table 200 uid 0
    cache
```

### 9.2 `systemd-networkd` — el mismo host sin Netplan

`/etc/systemd/network/10-eth0.network`

```ini
[Match]
MACAddress=06:3f:1a:9c:2e:44

[Link]
MTUBytes=1500
RequiredForOnline=routable

[Network]
Address=192.168.178.24/24
Address=2001:db8:178::24/64
DNS=10.20.0.10
DNS=10.20.0.11
Domains=prod.example.com example.com
IPv6AcceptRA=no
LinkLocalAddressing=ipv6
IPForward=no

[Route]
Gateway=192.168.178.1
Destination=0.0.0.0/0
Metric=100

[Route]
Gateway=2001:db8:178::1
Destination=::/0
Metric=100
```

`/etc/systemd/network/20-eth1.network`

```ini
[Match]
MACAddress=06:3f:1a:9c:2e:45

[Link]
MTUBytes=9000
RequiredForOnline=routable

[Network]
Address=10.20.0.24/16
IPv6AcceptRA=no
LinkLocalAddressing=no

[Route]
Destination=10.20.0.0/16
Scope=link
Table=200

[Route]
Gateway=10.20.0.1
Destination=0.0.0.0/0
Table=200
Metric=100

[RoutingPolicyRule]
From=10.20.0.24/32
Table=200
Priority=32765
```

```
$ sudo systemctl restart systemd-networkd
$ networkctl status eth1
● 3: eth1
                   Link File: /usr/lib/systemd/network/99-default.link
                Network File: /etc/systemd/network/20-eth1.network
                       State: routable (configured)
                Online state: online
                        Type: ether
                        Path: pci-0000:00:06.0
                      Driver: virtio_net
                      Vendor: Red Hat, Inc.
                       Model: Virtio network device
                  HW Address: 06:3f:1a:9c:2e:45
                         MTU: 9000 (min: 68, max: 65535)
                       QDisc: mq
Number of Queues (Tx/Rx): 4/4
                     Address: 10.20.0.24
```

`State: routable (configured)` es la aserción a verificar. `degraded` significa que el enlace está levantado pero no tiene dirección ruteable; `configuring` significa que nunca convergió.

### 9.3 Keyfile de NetworkManager — equivalente para RHEL/Fedora

`/etc/NetworkManager/system-connections/backend-eth1.nmconnection` (modo `0600`, o NM se niega a cargarlo)

```ini
[connection]
id=backend-eth1
uuid=8f2c1a94-6b3d-4e7f-9a02-1c5d8e3b7f40
type=ethernet
interface-name=eth1
autoconnect=true
autoconnect-priority=10

[ethernet]
mtu=9000

[ipv4]
method=manual
address1=10.20.0.24/16
# never-default: this profile must not install a default route in table main
never-default=true
dns-priority=200
route-table=200
route1=0.0.0.0/0,10.20.0.1
route1_options=table=200
routing-rule1=priority 32765 from 10.20.0.24/32 table 200
may-fail=false

[ipv6]
method=disabled

[proxy]
```

```
$ sudo chmod 600 /etc/NetworkManager/system-connections/backend-eth1.nmconnection
$ sudo nmcli connection reload
$ sudo nmcli connection up backend-eth1
Connection successfully activated (D-Bus active path: /org/freedesktop/NetworkManager/ActiveConnection/7)
$ nmcli -f IP4.ADDRESS,IP4.GATEWAY,IP4.ROUTE,GENERAL.STATE connection show backend-eth1
IP4.ADDRESS[1]:                         10.20.0.24/16
IP4.GATEWAY:                            --
IP4.ROUTE[1]:                           dst = 0.0.0.0/0, nh = 10.20.0.1, mt = 0, table=200
GENERAL.STATE:                          activated
$ nmcli device status
DEVICE  TYPE      STATE                   CONNECTION
eth0    ethernet  connected               edge-eth0
eth1    ethernet  connected               backend-eth1
lo      loopback  connected (externally)  lo
```

### 9.4 `nftables` — un ruleset que no crea agujeros negros

`/etc/nftables.conf`

```
#!/usr/sbin/nft -f
# Diagnostic-safe host firewall.
# Design rules:
#   1. ICMP frag-needed (type 3 code 4) is ALWAYS accepted -> no PMTU blackhole.
#   2. Echo request is rate-limited, not dropped -> ping stays usable.
#   3. Denied TCP is REJECTed with tcp-reset on trusted networks, so operators
#      get ECONNREFUSED (fast, diagnosable) instead of a 130 s timeout.
#   4. Counters on every terminal rule, so `nft list ruleset` is evidence.

flush ruleset

table inet filter {
    set trusted_v4 {
        type ipv4_addr
        flags interval
        elements = { 10.20.0.0/16, 192.168.178.0/24 }
    }

    chain input {
        type filter hook input priority filter; policy drop;

        iif lo accept comment "loopback"

        ct state established,related accept
        ct state invalid counter drop comment "malformed / out-of-window"

        # --- ICMPv4: never break path MTU discovery ---
        ip protocol icmp icmp type destination-unreachable accept \
            comment "includes type 3 code 4 frag-needed - required for PMTUD"
        ip protocol icmp icmp type time-exceeded accept comment "traceroute replies"
        ip protocol icmp icmp type parameter-problem accept
        ip protocol icmp icmp type echo-request limit rate 10/second burst 20 packets accept
        ip protocol icmp icmp type echo-reply accept

        # --- ICMPv6: mandatory, IPv6 does not work without it ---
        icmpv6 type { destination-unreachable, packet-too-big, time-exceeded,
                      parameter-problem, echo-request, echo-reply } accept
        icmpv6 type { nd-neighbor-solicit, nd-neighbor-advert,
                      nd-router-solicit, nd-router-advert } ip6 hoplimit 255 accept

        # --- services ---
        tcp dport 22 ip saddr @trusted_v4 ct state new limit rate 6/minute burst 10 packets \
            counter accept comment "ssh, brute-force limited"
        tcp dport { 80, 443 } ct state new counter accept
        tcp dport 5432 ip saddr @trusted_v4 ct state new counter accept

        udp dport 68 accept comment "dhcp client"

        # Trusted networks get an explicit reject: fast failure beats a timeout.
        ip saddr @trusted_v4 tcp flags syn counter reject with tcp reset
        ip saddr @trusted_v4 counter reject with icmp type admin-prohibited

        # Everything else is dropped silently, with a sampled log for forensics.
        limit rate 5/minute burst 10 packets log prefix "nft-input-drop: " level info
        counter drop
    }

    chain forward {
        type filter hook forward priority filter; policy drop;
        ct state established,related accept
        # Clamp MSS to the real path MTU: protects tunnels from oversized segments
        # even when an upstream device eats the frag-needed ICMP.
        tcp flags syn tcp option maxseg size set rt mtu
        iifname "cni0" oifname "eth0" counter accept
        iifname "eth0" oifname "cni0" ct state established,related counter accept
        counter drop
    }

    chain output {
        type filter hook output priority filter; policy accept;
    }
}
```

```
$ sudo nft -c -f /etc/nftables.conf && echo "syntax OK"
syntax OK
$ sudo systemctl enable --now nftables
$ sudo nft list ruleset | grep -A2 'dport 5432'
		tcp dport 5432 ip saddr @trusted_v4 ct state new counter packets 8412 bytes 504720 accept
$ sudo nft list counters
table inet filter {
	...
}
```

Los contadores son el punto. Un `counter packets 0` en la regla que creés que está permitiendo el tráfico prueba que los paquetes nunca llegaron a esa regla — normalmente porque una regla anterior hizo match, o porque nunca llegaron.

### 9.5 Ansible — un play de verificación idempotente

`playbooks/network-verify.yml`

```yaml
---
# Fleet-wide L1->L7 assertion sweep. Read-only: changes nothing, fails loudly.
#   ansible-playbook -i inventory/prod playbooks/network-verify.yml
- name: Verify host network health from link to name resolution
  hosts: prod_linux
  gather_facts: true
  become: false
  vars:
    expected_mtu: 1500
    expected_default_gw: "192.168.178.1"
    required_resolvers:
      - "10.20.0.10"
      - "10.20.0.11"
    reachability_targets:
      - { host: "10.20.7.9", port: 5432, name: "postgres-primary" }
      - { host: "10.20.0.10", port: 53, name: "dns-primary" }
      - { host: "10.43.0.1", port: 443, name: "kube-apiserver" }
    resolve_targets:
      - "db-primary.prod.example.com"
      - "api.prod.example.com"

  tasks:
    - name: L1/L2 - primary interface carrier is up
      ansible.builtin.slurp:
        src: "/sys/class/net/{{ ansible_default_ipv4.interface }}/carrier"
      register: carrier_state

    - name: L1/L2 - assert carrier detected
      ansible.builtin.assert:
        that:
          - (carrier_state.content | b64decode | trim) == "1"
        fail_msg: >-
          No carrier on {{ ansible_default_ipv4.interface }} -
          physical link down (cable, SFP, or switch port).
        success_msg: "carrier OK on {{ ansible_default_ipv4.interface }}"

    - name: L1/L2 - assert MTU matches the design
      ansible.builtin.assert:
        that:
          - ansible_default_ipv4.mtu | int == expected_mtu | int
        fail_msg: >-
          MTU is {{ ansible_default_ipv4.mtu }}, expected {{ expected_mtu }}.
          Mismatched MTU produces size-dependent stalls, not clean failures.

    - name: L3 - assert the default gateway is the designed one
      ansible.builtin.assert:
        that:
          - ansible_default_ipv4.gateway == expected_default_gw
        fail_msg: >-
          Default gateway is {{ ansible_default_ipv4.gateway | default('ABSENT') }},
          expected {{ expected_default_gw }}.

    - name: L3 - resolve the egress decision for each target
      ansible.builtin.command:
        argv: ["ip", "route", "get", "{{ item.host }}"]
      loop: "{{ reachability_targets }}"
      loop_control:
        label: "{{ item.name }}"
      register: route_get
      changed_when: false
      failed_when: route_get.rc != 0

    - name: L3 - report the chosen source address and interface
      ansible.builtin.debug:
        msg: "{{ item.item.name }} -> {{ item.stdout_lines[0] }}"
      loop: "{{ route_get.results }}"
      loop_control:
        label: "{{ item.item.name }}"

    - name: L3 - reverse path filter must not be strict on multi-homed hosts
      ansible.builtin.command:
        argv: ["sysctl", "-n", "net.ipv4.conf.all.rp_filter"]
      register: rp_filter
      changed_when: false

    - name: L3 - assert rp_filter is loose or off when more than one NIC is routed
      ansible.builtin.assert:
        that:
          - (ansible_interfaces | reject('match', '^(lo|docker|veth|cni)') | list | length) < 2
            or rp_filter.stdout | int != 1
        fail_msg: >-
          rp_filter=1 (strict) on a multi-homed host. Asymmetric replies will be
          dropped silently; check `nstat -az IpReversePathFilter`.

    - name: L4 - TCP handshake must complete for every dependency
      ansible.builtin.wait_for:
        host: "{{ item.host }}"
        port: "{{ item.port }}"
        timeout: 5
        state: started
      loop: "{{ reachability_targets }}"
      loop_control:
        label: "{{ item.name }} ({{ item.host }}:{{ item.port }})"

    - name: L4 - listen backlog must not be saturated
      ansible.builtin.shell:
        cmd: >-
          set -o pipefail;
          ss -lnt | awk 'NR>1 && $2 > ($3 * 0.8) {print $0}'
        executable: /bin/bash
      register: backlog
      changed_when: false
      failed_when: false

    - name: L4 - assert no listener is above 80 percent of its backlog
      ansible.builtin.assert:
        that:
          - backlog.stdout | length == 0
        fail_msg: >-
          Listener accept queue near capacity; SYNs are being dropped:
          {{ backlog.stdout }}

    - name: L7 - names must resolve through the full NSS path, not just DNS
      ansible.builtin.command:
        argv: ["getent", "hosts", "{{ item }}"]
      loop: "{{ resolve_targets }}"
      register: nss_lookup
      changed_when: false
      failed_when: nss_lookup.rc != 0

    - name: L7 - every configured resolver must answer independently
      ansible.builtin.command:
        argv: ["dig", "+short", "+time=2", "+tries=1", "@{{ item.0 }}", "{{ item.1 }}"]
      loop: "{{ required_resolvers | product(resolve_targets) | list }}"
      loop_control:
        label: "{{ item.0 }} <- {{ item.1 }}"
      register: per_resolver
      changed_when: false
      failed_when: per_resolver.stdout | trim | length == 0

    - name: L7 - resolv.conf must not use the 5 second default timeout
      ansible.builtin.command:
        argv: ["grep", "-E", "^options .*timeout:[1-2]([^0-9]|$)", "/etc/resolv.conf"]
      register: resolv_timeout
      changed_when: false
      failed_when: resolv_timeout.rc != 0
```

```
$ ansible-playbook -i inventory/prod playbooks/network-verify.yml

PLAY [Verify host network health from link to name resolution] *****************

TASK [L1/L2 - assert carrier detected] *****************************************
ok: [ingress-03] => {"changed": false, "msg": "carrier OK on eth0"}

TASK [L3 - report the chosen source address and interface] *********************
ok: [ingress-03] => (item=postgres-primary) => {
    "msg": "postgres-primary -> 10.20.7.9 dev eth1 src 10.20.0.24 uid 0"
}

TASK [L3 - assert rp_filter is loose or off when more than one NIC is routed] ***
fatal: [ingress-07]: FAILED! => {"assertion": "...", "changed": false,
  "evaluated_to": false, "msg": "rp_filter=1 (strict) on a multi-homed host.
  Asymmetric replies will be dropped silently; check `nstat -az IpReversePathFilter`."}

PLAY RECAP *********************************************************************
ingress-03   : ok=12   changed=0    unreachable=0    failed=0
ingress-07   : ok=5    changed=0    unreachable=0    failed=1
```

### 9.6 Las mismas primitivas dentro del network namespace de un contenedor

Todo lo de arriba es local al namespace. Un Pod que «no puede llegar a la base de datos» es un host con sus propias interfaces, rutas, `resolv.conf` y tabla de sockets — nada de lo cual es visible desde el namespace por defecto del nodo.

`manifests/netshoot-debug.yaml`

```yaml
---
apiVersion: v1
kind: Pod
metadata:
  name: netshoot-debug
  namespace: prod
  labels:
    app.kubernetes.io/name: netshoot-debug
    app.kubernetes.io/component: diagnostics
  annotations:
    kubernetes.io/description: >-
      Ephemeral L1-L7 diagnostic shell. Delete after use; NET_RAW and NET_ADMIN
      are granted only so tcpdump and ip can operate inside the namespace.
spec:
  # hostNetwork: false is the default and is what you want first: diagnose the
  # Pod's namespace. Flip to true only to compare against the node's view.
  hostNetwork: false
  dnsPolicy: ClusterFirst
  restartPolicy: Never
  terminationGracePeriodSeconds: 5
  containers:
    - name: netshoot
      image: nicolaka/netshoot:v0.13
      imagePullPolicy: IfNotPresent
      command: ["/bin/bash", "-c", "sleep 3600"]
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: false
        runAsNonRoot: false
        runAsUser: 0
        capabilities:
          drop: ["ALL"]
          add: ["NET_RAW", "NET_ADMIN"]
      resources:
        requests:
          cpu: "50m"
          memory: "64Mi"
        limits:
          cpu: "500m"
          memory: "256Mi"
  tolerations:
    - operator: "Exists"
      effect: "NoSchedule"
```

```
$ kubectl apply -f manifests/netshoot-debug.yaml
pod/netshoot-debug created

$ kubectl exec -n prod netshoot-debug -- ip -brief addr show
lo               UNKNOWN        127.0.0.1/8 ::1/128
eth0@if142       UP             10.42.3.17/32

$ kubectl exec -n prod netshoot-debug -- ip route get 10.20.7.9
10.20.7.9 via 169.254.1.1 dev eth0 src 10.42.3.17 uid 0
    cache

$ kubectl exec -n prod netshoot-debug -- cat /etc/resolv.conf
search prod.svc.cluster.local svc.cluster.local cluster.local
nameserver 10.43.0.10
options ndots:5

$ kubectl exec -n prod netshoot-debug -- getent hosts db-primary.prod.svc.cluster.local
10.43.7.9       db-primary.prod.svc.cluster.local

$ kubectl exec -n prod netshoot-debug -- nc -zv -w3 db-primary.prod.svc.cluster.local 5432
Connection to db-primary.prod.svc.cluster.local (10.43.7.9) 5432 port [tcp/postgresql] succeeded!
```

Desde el propio nodo, para entrar al namespace de un contenedor sin ninguna herramienta dentro del contenedor:

```
$ CID=$(sudo crictl ps --name api-server -q | head -1)
$ PID=$(sudo crictl inspect "$CID" | jq -r '.info.pid')
$ sudo nsenter -t "$PID" -n ip -brief addr show
lo               UNKNOWN        127.0.0.1/8 ::1/128
eth0@if211       UP             10.42.3.22/32
$ sudo nsenter -t "$PID" -n ss -tulpn
$ sudo nsenter -t "$PID" -n tcpdump -nni eth0 -c 20 'tcp port 5432'
```

Notá que los contenedores **no** aparecen en `ip netns list` — ese comando lista únicamente los namespaces montados con bind bajo `/var/run/netns`. `nsenter -t <pid> -n` es el punto de entrada correcto. Para hacer visible el namespace de un contenedor a `ip netns`:

```
$ sudo mkdir -p /var/run/netns
$ sudo ln -sf /proc/$PID/ns/net /var/run/netns/api-server
$ sudo ip netns exec api-server ss -tan
```

---

## 10. Guía de verificación y diagnóstico de fallas

### 10.1 Síntoma → capa → primer comando

| Síntoma | Capa más probable | Primer comando | Evidencia decisiva |
|---|---|---|---|
| Nada de tráfico, hacia ningún destino | L1 | `ip -s link show` | `LOWER_UP` ausente |
| Algunos peers de «la misma subred» funcionan | L3 | `ip addr show` | Longitud de prefijo equivocada |
| `Network is unreachable` | L3 local | `ip route get <dst>` | Sin entrada coincidente en la FIB |
| `No route to host` | L2 | `ip neigh show` | `FAILED` / `INCOMPLETE` |
| `Connection refused` | L4 destino | `ss -lnt` en el destino | Ligado a `127.0.0.1` |
| `Connection timed out` | Filtro L3/L4 | `tcpdump` en ambas puntas | El SYN sale, nunca llega |
| Handshake OK, los payloads grandes se cuelgan | PMTU | `tracepath -n <dst>` | Caída de `pmtu` a mitad de camino |
| Pérdida intermitente / jitter | Camino | `mtr --report -c 100` | La pérdida persiste hasta el último salto |
| Funciona por IP, falla por nombre | NSS | `getent hosts` vs `dig +short` | Las respuestas difieren |
| Demora de ~5 s antes de cada connect | Resolver | `cat /etc/resolv.conf` | `timeout:5` por defecto, primer servidor muerto |
| Muchas peticiones de vida corta son lentas | `ndots` | `tcpdump -ni any udp port 53` | Tormenta de NXDOMAIN por expansión de search |
| Las conexiones se caen solo bajo carga | Cola L4 | `nstat -az \| grep Listen` | `ListenOverflows` subiendo |
| El tráfico funciona en un solo sentido | rp_filter | `nstat -az \| grep -i reverse` | `IpReversePathFilter` subiendo |
| Alrededor de 50 % de pérdida hacia un host | L2 | `arping -D -I eth0 <ip>` | Responden dos MACs |
| Todo se rompió tras un failover | Caché ARP | `ip neigh show` | `lladdr` obsoleto para la VIP |
| Velocidad limitada a ~94 Mb/s | L1 | `ethtool eth0` | `Speed: 100Mb/s` |

### 10.2 El runbook ordenado

```bash
#!/usr/bin/env bash
# net-triage.sh <destination-host> [port]
# Read-only L1->L7 bisection. Every step prints the evidence it used.
set -uo pipefail

DST="${1:?usage: net-triage.sh <host> [port]}"
PORT="${2:-443}"
IFACE="$(ip route show default | awk '/default/ {print $5; exit}')"

section() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }

section "L1/L2  link state on ${IFACE}"
ip -s link show dev "$IFACE"
[ -r "/sys/class/net/${IFACE}/carrier" ] && \
  echo "carrier=$(cat "/sys/class/net/${IFACE}/carrier")"
command -v ethtool >/dev/null && sudo ethtool "$IFACE" 2>/dev/null | \
  grep -E 'Speed|Duplex|Link detected'

section "L1/L2  neighbour table"
ip neigh show dev "$IFACE"

section "L3  addresses"
ip -brief addr show

section "L3  routing decision for ${DST}"
# Resolve the name first so `ip route get` receives an address, not a name.
DST_IP="$(getent ahostsv4 "$DST" 2>/dev/null | awk 'NR==1{print $1}')"
DST_IP="${DST_IP:-$DST}"
echo "resolved ${DST} -> ${DST_IP}"
ip route get "$DST_IP" || echo "!! no route: check 'ip route show' and 'ip rule show'"
ip rule show

section "L3  reverse path filter"
sysctl net.ipv4.conf.all.rp_filter net.ipv4.conf."${IFACE}".rp_filter
nstat -az 2>/dev/null | grep -Ei 'reversepath|martian|noroutes' || true

section "L3  ICMP reachability (absence proves nothing)"
ping -n -c 3 -W 2 "$DST_IP" || echo "!! no echo reply - ICMP may simply be filtered"

section "L3  path and PMTU"
command -v tracepath >/dev/null && tracepath -n -m 15 "$DST_IP"

section "L4  TCP handshake to ${DST_IP}:${PORT}"
if command -v nc >/dev/null; then
  nc -zv -w 3 "$DST_IP" "$PORT" 2>&1
else
  timeout 3 bash -c "cat < /dev/null > /dev/tcp/${DST_IP}/${PORT}" \
    && echo "open" || echo "closed or filtered"
fi

section "L4  local socket health"
ss -s
ss -tan state syn-sent
nstat -az 2>/dev/null | grep -E 'ListenDrops|ListenOverflows|SynRetrans|RetransSegs' || true

section "L7  name resolution paths"
echo "--- NSS (what the application sees) ---"
getent hosts "$DST" || echo "!! NSS lookup FAILED"
echo "--- nsswitch hosts line ---"
grep -E '^hosts:' /etc/nsswitch.conf
echo "--- /etc/hosts matches ---"
grep -F -- "$DST" /etc/hosts || echo "(none)"
echo "--- resolv.conf ---"
cat /etc/resolv.conf
echo "--- DNS directly ---"
command -v dig >/dev/null && dig +short +time=2 +tries=1 "$DST"
command -v resolvectl >/dev/null && resolvectl query "$DST" 2>&1 | head -5

section "done"
echo "If every layer above passed and the application still fails,"
echo "capture: sudo tcpdump -nni ${IFACE} -c 100 'host ${DST_IP} and port ${PORT}'"
```

```
$ ./net-triage.sh db-primary.prod.example.com 5432

== L1/L2  link state on eth0 ==
2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc mq state UP mode DEFAULT group default qlen 1000
    link/ether 06:3f:1a:9c:2e:44 brd ff:ff:ff:ff:ff:ff
    ...
carrier=1
	Speed: 10000Mb/s
	Duplex: Full
	Link detected: yes

== L3  routing decision for db-primary.prod.example.com ==
resolved db-primary.prod.example.com -> 10.20.7.9
10.20.7.9 via 10.20.0.1 dev eth1 table 200 src 10.20.0.24 uid 1000
    cache

== L4  TCP handshake to 10.20.7.9:5432 ==
Connection to 10.20.7.9 5432 port [tcp/postgresql] succeeded!

== L7  name resolution paths ==
--- NSS (what the application sees) ---
10.20.7.9       db-primary.prod.example.com
```

### 10.3 Dos fallas trabajadas

**Caso A — «la base de datos está caída» que era una entrada obsoleta en `/etc/hosts`.**

```
$ nc -zv -w3 db-primary.prod.example.com 5432
nc: connect to db-primary.prod.example.com port 5432 (tcp) timed out: Operation now in progress

$ dig +short db-primary.prod.example.com
10.20.7.9

$ getent hosts db-primary.prod.example.com
10.20.99.14     db-primary.prod.example.com

$ grep db-primary /etc/hosts
10.20.99.14     db-primary.prod.example.com db-primary

$ nc -zv -w3 10.20.7.9 5432
Connection to 10.20.7.9 5432 port [tcp/postgresql] succeeded!
```

El DNS estuvo correcto en todo momento. Una entrada de `/etc/hosts` agregada durante una migración ocho meses antes lo sobrescribía, porque `nsswitch.conf` pone `files` antes que `dns`. Toda investigación centrada en DNS habría concluido «el DNS está bien» y se habría detenido.

**Caso B — handshake exitoso, transferencia colgada.**

```
$ curl -sS -o /dev/null -w '%{http_code} %{time_total}\n' https://api.partner.example.com/health
200 0.142

$ curl -sS -o /dev/null -w '%{http_code} %{time_total}\n' https://api.partner.example.com/v1/bulk-export
curl: (28) Operation timed out after 30001 milliseconds with 0 bytes received

$ ping -M do -s 1472 -c1 api.partner.example.com
PING api.partner.example.com (203.0.113.44) 1472(1500) bytes of data.
^C
--- api.partner.example.com ping statistics ---
3 packets transmitted, 0 received, 100% packet loss, time 2043ms

$ ping -M do -s 1372 -c1 api.partner.example.com
PING api.partner.example.com (203.0.113.44) 1372(1400) bytes of data.
1380 bytes from 203.0.113.44: icmp_seq=1 ttl=52 time=41.2 ms

$ ss -tin dst 203.0.113.44 | grep -o 'mss:[0-9]*\|pmtu:[0-9]*\|retrans:[0-9/]*'
mss:1448
pmtu:1500
retrans:0/94
```

El kernel todavía cree `pmtu:1500` y está anunciando `mss:1448` mientras la MTU real del camino es 1400 — el ICMP `frag-needed` está siendo filtrado aguas arriba. Las respuestas chicas entran; el bulk export no. Mitigación inmediata, y después el arreglo real aguas arriba:

```
$ sudo sysctl -w net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_mtu_probing = 1
$ curl -sS -o /dev/null -w '%{http_code} %{time_total}\n' https://api.partner.example.com/v1/bulk-export
200 3.884
```

---

## 11. Repaso enfocado en el examen

**Comandos (109.3, v5.0):** `ip`, `hostname`, `ss`, `ping`, `ping6`, `traceroute`, `traceroute6`, `tracepath`, `tracepath6`, `netcat`, `ifconfig`, `netstat`, `route`, `mtr`, `host`, `dig`.

**Archivos:** `/etc/resolv.conf`, `/etc/hosts`, `/etc/nsswitch.conf`, `/etc/services`, `/etc/networks`.

Hechos que se examinan literalmente y son fáciles de perder:

- `/etc/resolv.conf` honra un máximo de **tres** líneas `nameserver`; los valores por defecto son `timeout:5`, `attempts:2`, `ndots:1`.
- `domain` y `search` en `/etc/resolv.conf` son mutuamente excluyentes; gana la última directiva leída.
- `files` antes que `dns` en `nsswitch.conf` es la razón por la que `/etc/hosts` sobrescribe al DNS.
- En un socket `LISTEN`, `ss` muestra la profundidad actual de la cola de accept en `Recv-Q` y el máximo de backlog en `Send-Q`.
- `traceroute` envía **UDP** a puertos altos por defecto; `-I` para ICMP, `-T` para TCP; `tracepath` no necesita privilegios y reporta la PMTU.
- `ping -s N` fija el **payload**; el paquete IPv4 es de `N + 28` bytes.
- `nc -z` escanea sin enviar datos; `-w` fija el timeout; `-u` selecciona UDP; `-l` escucha.
- `hostname -I` (i mayúscula) lista todas las direcciones de las interfaces; `hostname -i` hace una consulta y desorienta en hosts multi-homed.
- Las direcciones link-local de IPv6 requieren un índice de zona (`fe80::1%eth0`).
- `ip route get <dst>` reporta la interfaz, el nexthop **y la dirección de origen** que el kernel va a usar realmente.

---

## 12. Referencias

**Objetivos oficiales de la certificación**

- LPI — Objetivos del examen 102-500 (LPIC-1 v5.0), Tema 109.3 *Basic network troubleshooting*: <https://www.lpi.org/our-certifications/exam-102-objectives/>
- LPI — Objetivos del examen 101-500 (LPIC-1 v5.0): <https://www.lpi.org/our-certifications/exam-101-objectives/>
- LPI — Descripción general de la certificación LPIC-1 Linux Administrator: <https://www.lpi.org/our-certifications/lpic-1-overview/>

**iproute2 y redes en el kernel**

- Página de manual `ip(8)` — iproute2: <https://man7.org/linux/man-pages/man8/ip.8.html>
- `ip-route(8)`: <https://man7.org/linux/man-pages/man8/ip-route.8.html>
- `ip-neighbour(8)`: <https://man7.org/linux/man-pages/man8/ip-neighbour.8.html>
- `ss(8)`: <https://man7.org/linux/man-pages/man8/ss.8.html>
- Documentación del kernel de Linux — parámetros sysctl de IP (`rp_filter`, `tcp_mtu_probing`, `somaxconn`): <https://www.kernel.org/doc/html/latest/networking/ip-sysctl.html>
- Página del proyecto iproute2: <https://wiki.linuxfoundation.org/networking/iproute2>

**Herramientas de diagnóstico**

- `ping(8)` — iputils: <https://man7.org/linux/man-pages/man8/ping.8.html>
- `tracepath(8)` — iputils: <https://man7.org/linux/man-pages/man8/tracepath.8.html>
- `traceroute(8)`: <https://man7.org/linux/man-pages/man8/traceroute.8.html>
- Proyecto iputils: <https://github.com/iputils/iputils>
- `mtr` — Matt's traceroute: <https://www.bitwizard.nl/mtr/>
- `nc(1)` — netcat de OpenBSD: <https://man.openbsd.org/nc.1>
- `tcpdump(1)` y `pcap-filter(7)`: <https://www.tcpdump.org/manpages/tcpdump.1.html> · <https://www.tcpdump.org/manpages/pcap-filter.7.html>
- `ethtool(8)`: <https://man7.org/linux/man-pages/man8/ethtool.8.html>
- `nsenter(1)`: <https://man7.org/linux/man-pages/man1/nsenter.1.html>

**Resolución de nombres**

- `nsswitch.conf(5)`: <https://man7.org/linux/man-pages/man5/nsswitch.conf.5.html>
- `resolv.conf(5)`: <https://man7.org/linux/man-pages/man5/resolv.conf.5.html>
- `hosts(5)`: <https://man7.org/linux/man-pages/man5/hosts.5.html>
- `getaddrinfo(3)`: <https://man7.org/linux/man-pages/man3/getaddrinfo.3.html>
- `systemd-resolved.service(8)`: <https://www.freedesktop.org/software/systemd/man/latest/systemd-resolved.service.html>
- `resolvectl(1)`: <https://www.freedesktop.org/software/systemd/man/latest/resolvectl.html>
- Documentación de `dig` de ISC BIND: <https://bind9.readthedocs.io/en/latest/manpages.html#dig-dns-lookup-utility>

**Frameworks de configuración**

- `systemd.network(5)`: <https://www.freedesktop.org/software/systemd/man/latest/systemd.network.html>
- `networkctl(1)`: <https://www.freedesktop.org/software/systemd/man/latest/networkctl.html>
- Referencia de Netplan: <https://netplan.readthedocs.io/en/stable/netplan-yaml/>
- NetworkManager `nm-settings-keyfile(5)`: <https://networkmanager.dev/docs/api/latest/nm-settings-keyfile.html>
- `nmcli(1)`: <https://networkmanager.dev/docs/api/latest/nmcli.html>
- Wiki de nftables: <https://wiki.nftables.org/wiki-nftables/index.php/Main_Page>

**Estándares**

- RFC 1122 — Requirements for Internet Hosts, Communication Layers: <https://www.rfc-editor.org/rfc/rfc1122>
- RFC 1191 — Path MTU Discovery: <https://www.rfc-editor.org/rfc/rfc1191>
- RFC 4821 — Packetization Layer Path MTU Discovery: <https://www.rfc-editor.org/rfc/rfc4821>
- RFC 3704 — Ingress Filtering for Multihomed Networks (semántica de `rp_filter`): <https://www.rfc-editor.org/rfc/rfc3704>
- RFC 4861 — Neighbor Discovery for IPv6: <https://www.rfc-editor.org/rfc/rfc4861>
- RFC 792 — Internet Control Message Protocol: <https://www.rfc-editor.org/rfc/rfc792>
- RFC 6335 — Service Name and Transport Protocol Port Number Registry: <https://www.rfc-editor.org/rfc/rfc6335>

**Contexto de redes en contenedores**

- Kubernetes — Debug Services: <https://kubernetes.io/docs/tasks/debug/debug-application/debug-service/>
- Kubernetes — DNS for Services and Pods: <https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/>
- Kubernetes — Debugging DNS Resolution: <https://kubernetes.io/docs/tasks/administer-cluster/dns-debugging-resolution/>