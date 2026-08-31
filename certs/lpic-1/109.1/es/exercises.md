# LPIC-1 — 109.1 Fundamentos de los protocolos de Internet
## Ejercicios guiados

> **Alcance del objetivo:** direccionamiento IPv4/IPv6, máscaras de red y CIDR, rangos privados y reservados, la diferencia entre TCP, UDP e ICMP, y los puertos y servicios bien conocidos de `/etc/services`.
> **Lista oficial de objetivos:** <https://www.lpi.org/our-certifications/exam-101-objectives/> (el objetivo 109.1 pertenece al examen 102-500: <https://www.lpi.org/our-certifications/exam-102-objectives/>)

---

## Prerrequisitos del laboratorio

Ejecutá todo en una máquina propia — una VM o un contenedor es ideal, porque varios pasos abren sockets a la escucha y capturan tráfico.

```bash
# Debian / Ubuntu
sudo apt install -y iproute2 iputils-ping iputils-tracepath traceroute \
                    tcpdump netcat-openbsd dnsutils ipcalc

# Fedora / RHEL / openSUSE
sudo dnf install -y iproute iputils traceroute tcpdump nmap-ncat \
                    bind-utils ipcalc
```

`tcpdump` necesita `CAP_NET_RAW` (es decir, `sudo`). Nada en este laboratorio modifica configuración persistente, salvo donde se indica explícitamente y se revierte.

---

## Ejercicio 1 — Leer la configuración IPv4 e IPv6 de la propia máquina

**Objetivo:** dejar de adivinar qué significa "mi IP". Aprender a leer la longitud de prefijo, el scope, las flags de dirección y la decisión de enrutamiento que el kernel realmente toma.

### Pasos

1. Listá todas las direcciones IPv4 con su longitud de prefijo:

   ```bash
   ip -4 -brief address show
   ```

   ```
   lo               UNKNOWN        127.0.0.1/8
   enp1s0           UP             192.168.178.42/24
   ```

2. Ahora la forma completa, que es lo que tenés que poder leer en el examen y en un incidente:

   ```bash
   ip -4 address show dev enp1s0
   ```

   ```
   2: enp1s0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc fq_codel state UP group default qlen 1000
       inet 192.168.178.42/24 brd 192.168.178.255 scope global dynamic noprefixroute enp1s0
          valid_lft 84391sec preferred_lft 84391sec
   ```

3. Repetí para IPv6 y notá que una sola interfaz normalmente lleva **varias** direcciones:

   ```bash
   ip -6 address show dev enp1s0
   ```

   ```
   2: enp1s0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 state UP qlen 1000
       inet6 2001:db8:1234:5678:8b2a:44e1:9c07:3f11/64 scope global temporary dynamic
          valid_lft 6821sec preferred_lft 2621sec
       inet6 2001:db8:1234:5678:5054:ff:fe12:3456/64 scope global dynamic mngtmpaddr
          valid_lft 6821sec preferred_lft 3821sec
       inet6 fe80::5054:ff:fe12:3456/64 scope link
          valid_lft forever preferred_lft forever
   ```

4. Preguntale al kernel qué dirección de origen y qué gateway usaría para un destino dado — este es el comando de red más útil de Linux:

   ```bash
   ip route get 1.1.1.1
   ip -6 route get 2606:4700:4700::1111
   ```

   ```
   1.1.1.1 via 192.168.178.1 dev enp1s0 src 192.168.178.42 uid 1000
       cache
   2606:4700:4700::1111 from :: via fe80::1 dev enp1s0 src 2001:db8:1234:5678:8b2a:44e1:9c07:3f11 metric 1024 pref medium
   ```

5. Compará con la tabla de enrutamiento en sí:

   ```bash
   ip route show
   ip -6 route show
   ```

   ```
   default via 192.168.178.1 dev enp1s0 proto dhcp src 192.168.178.42 metric 100
   192.168.178.0/24 dev enp1s0 proto kernel scope link src 192.168.178.42 metric 100
   ```

> **Comprobá tu comprensión — Bloque 1**
> 1.1 En el paso 2, ¿qué significan `brd 192.168.178.255` y `scope global`, y cómo se derivó la dirección de broadcast?
> 1.2 En el paso 3 hay tres direcciones IPv6. Clasificá cada una (tipo y scope) y decí cuál se usa como *origen* para el tráfico a internet, y por qué.
> 1.3 `valid_lft` y `preferred_lft` aparecen en IPv6 pero dicen `forever` en la dirección link-local. ¿Qué mecanismo fija esos tiempos de vida, y qué le pasa a una dirección *deprecated* (preferred vencido, valid todavía no)?
> 1.4 En el paso 4 el siguiente salto IPv6 es `fe80::1`, una dirección link-local, mientras que el siguiente salto IPv4 es una dirección global. ¿Por qué puede una dirección link-local servir como gateway por defecto?

---

## Ejercicio 2 — Máscaras de red, CIDR y subnetting

**Objetivo:** convertir entre máscaras en decimal punteado, longitudes de prefijo y binario, y calcular red / broadcast / rango de hosts lo bastante rápido como para hacerlo bajo la presión del examen sin herramientas.

### Pasos

1. Aprendé las dos tablas que convierten todo lo demás en aritmética en lugar de adivinanza.

   | Prefijo en el octeto | Octeto de máscara | Tamaño de bloque | Binario |
   |---|---|---|---|
   | /25 | 128 | 128 | `10000000` |
   | /26 | 192 | 64 | `11000000` |
   | /27 | 224 | 32 | `11100000` |
   | /28 | 240 | 16 | `11110000` |
   | /29 | 248 | 8 | `11111000` |
   | /30 | 252 | 4 | `11111100` |

   El **tamaño de bloque** es `256 − octeto_de_máscara`. Los límites de subred son múltiplos del tamaño de bloque en el *octeto interesante* (el último octeto que la máscara no cubre por completo).

2. Hacé uno a mano antes de tocar una herramienta. Tomá `192.168.10.75/27`:

   - Máscara: `255.255.255.224`, octeto interesante = 4.º, tamaño de bloque = `256 − 224 = 32`.
   - Límites: 0, 32, 64, 96, 128, 160, 192, 224.
   - `75` cae en el bloque que empieza en `64`.
   - Red `192.168.10.64`, broadcast `192.168.10.64 + 32 − 1 = 192.168.10.95`.
   - Hosts utilizables `192.168.10.65` – `192.168.10.94`, es decir `2^(32−27) − 2 = 30`.

3. Verificá con `ipcalc` (la implementación de Jodies que distribuyen Debian/Ubuntu; la reescritura de RHEL usa `ipcalc --info`):

   ```bash
   ipcalc 192.168.10.75/27
   ```

   ```
   Address:   192.168.10.75        11000000.10101000.00001010.010 01011
   Netmask:   255.255.255.224 = 27 11111111.11111111.11111111.111 00000
   Wildcard:  0.0.0.31             00000000.00000000.00000000.000 11111
   =>
   Network:   192.168.10.64/27     11000000.10101000.00001010.010 00000
   HostMin:   192.168.10.65        11000000.10101000.00001010.010 00001
   HostMax:   192.168.10.94        11000000.10101000.00001010.010 11110
   Broadcast: 192.168.10.95        11000000.10101000.00001010.010 11111
   Hosts/Net: 30                    Class C, Private Internet
   ```

   El espacio en la columna binaria es el límite del prefijo — todo lo que está a su izquierda es la parte de red.

4. Dividí un `/24` en subredes iguales y leelas:

   ```bash
   ipcalc 192.168.10.0/24 --s 30 30 30 30 2>/dev/null | grep -E 'Network|Hosts'
   ```

   Si tu compilación de `ipcalc` no tiene `--s`, derivalo: 6 subredes de ≤30 hosts cada una necesitan `/27` (30 utilizables), lo que da 8 subredes en `.0 .32 .64 .96 .128 .160 .192 .224`.

5. Hacé lo mismo para IPv6, donde la aritmética es hexadecimal y no hay broadcast ni `−2`:

   ```bash
   ipcalc 2001:db8:acad::/48 2>/dev/null || sipcalc 2001:db8:acad::/48
   ```

   Un `/48` contiene `2^(64−48) = 65536` subredes de `/64`: `2001:db8:acad:0::/64`, `2001:db8:acad:1::/64`, … `2001:db8:acad:ffff::/64`.

> **Comprobá tu comprensión — Bloque 2**
> 2.1 Para `172.16.35.99/21`: dirección de red, dirección de broadcast, primer y último host utilizable, y cantidad de hosts utilizables.
> 2.2 ¿Están `192.168.4.130/26` y `192.168.4.190/26` en la misma subred? Mostrá el razonamiento, no solo el veredicto.
> 2.3 ¿Cuántas redes `/26` entran en un `/24`? ¿Cuántos hosts utilizables tiene cada una?
> 2.4 Un `/30` da 2 hosts utilizables. ¿Para qué se usa un `/31`, y por qué no aplica ahí la regla del "−2"?
> 2.5 Diseñá asignaciones VLSM a partir de `192.168.50.0/24` para: LAN-A 100 hosts, LAN-B 50 hosts, LAN-C 20 hosts, y dos enlaces punto a punto entre routers. Dá cada prefijo y decí qué queda libre.
> 2.6 ¿Por qué `/64` es el tamaño de subred estándar en IPv6 incluso para un enlace con dos hosts?

---

## Ejercicio 3 — Rangos privados, de loopback, link-local y otros reservados

**Objetivo:** reconocer al instante si una dirección es enrutable en internet, y saber qué te está diciendo una dirección `169.254.x.x` o `fe80::` durante una caída.

### Pasos

1. Anotá los rangos IPv4 que tenés que reconocer de un vistazo (RFC 1918, RFC 3927, RFC 6890, RFC 6598):

   | Rango | CIDR | Propósito |
   |---|---|---|
   | `10.0.0.0` – `10.255.255.255` | `10.0.0.0/8` | Privado (RFC 1918) |
   | `172.16.0.0` – `172.31.255.255` | `172.16.0.0/12` | Privado (RFC 1918) |
   | `192.168.0.0` – `192.168.255.255` | `192.168.0.0/16` | Privado (RFC 1918) |
   | `127.0.0.0` – `127.255.255.255` | `127.0.0.0/8` | Loopback |
   | `169.254.0.0` – `169.254.255.255` | `169.254.0.0/16` | Link-local / APIPA (RFC 3927) |
   | `100.64.0.0` – `100.127.255.255` | `100.64.0.0/10` | NAT de operador (RFC 6598) |
   | `224.0.0.0` – `239.255.255.255` | `224.0.0.0/4` | Multicast |
   | `255.255.255.255` | — | Broadcast limitado |

2. Y los equivalentes IPv6 (RFC 4291, RFC 4193):

   | Prefijo | Nombre | Notas |
   |---|---|---|
   | `::1/128` | Loopback | una sola dirección, no un `/8` |
   | `::/128` | Sin especificar | origen durante DAD/solicitud DHCPv6 |
   | `fe80::/10` | Link-local | obligatoria en toda interfaz IPv6 |
   | `fc00::/7` (en la práctica `fd00::/8`) | Unique Local Address | RFC 4193, no enrutada globalmente |
   | `2000::/3` | Unicast global | el espacio de internet actualmente asignado |
   | `ff00::/8` | Multicast | IPv6 **no tiene broadcast** |
   | `2001:db8::/32` | Documentación | RFC 3849 — usala en todos los ejemplos |

3. Verificá la clasificación con una herramienta en vez de confiar en la memoria:

   ```bash
   for a in 10.5.4.3 172.15.0.1 172.20.0.1 192.168.1.1 169.254.9.9 100.100.1.1; do
       printf '%-15s ' "$a"; ipcalc -n -b "$a/24" 2>/dev/null | grep -i 'private\|Address' | tail -1
   done
   ```

   Fijate en la trampa de esa lista: `172.15.0.1` es **pública**, `172.20.0.1` es privada. El bloque intermedio de RFC 1918 es `172.16.0.0/12`, es decir de `172.16` a `172.31` solamente.

4. Demostrá que una dirección IPv4 link-local es un síntoma, no una configuración:

   ```bash
   ip -4 address show | grep 169.254
   journalctl -u NetworkManager -n 20 --no-pager | grep -i dhcp
   ```

   Una interfaz con `169.254.x.y/16` significa que DHCP no obtuvo respuesta y el host se autoasignó la dirección.

5. Mostrá que las direcciones IPv6 link-local requieren un **índice de zona** porque el mismo prefijo existe en todas las interfaces:

   ```bash
   ping -c2 fe80::1              # fails: "Invalid argument" / no route
   ping -c2 fe80::1%enp1s0       # works: the %zone selects the interface
   ```

> **Comprobá tu comprensión — Bloque 3**
> 3.1 ¿Cuáles de estas son direcciones privadas RFC 1918: `172.15.200.1`, `172.32.0.5`, `172.31.255.254`, `192.169.1.1`, `10.255.255.254`?
> 3.2 Un servidor muestra solo `169.254.13.201/16` en `eth0`. ¿Qué pasó, y qué es lo primero que revisás?
> 3.3 IPv4 reserva un `/8` entero para loopback pero IPv6 reserva una sola dirección. ¿Qué consecuencia práctica tiene esa diferencia para el binding de servicios (pensá en `127.0.0.1` vs `127.0.0.53`)?
> 3.4 ¿Por qué falla `ping fe80::1` sin `%enp1s0` mientras que `ping 192.168.178.1` no necesita ese sufijo?
> 3.5 Tu arquitecto quiere "IPv6 privado" para una red interna. ¿Qué prefijo usás, cómo elegís los 40 bits aleatorios, y por qué *no* es el equivalente IPv6 de NAT?

---

## Ejercicio 4 — `/etc/services`, `/etc/protocols` y los puertos bien conocidos

**Objetivo:** saber dónde vive el mapeo nombre↔puerto, cómo consultarlo programáticamente, y memorizar la lista de puertos que exige el objetivo.

### Pasos

1. Mirá el archivo en sí y entendé la disposición de campos:

   ```bash
   grep -vE '^\s*#|^\s*$' /etc/services | head -12
   ```

   ```
   tcpmux          1/tcp                           # TCP port service multiplexer
   ftp-data        20/tcp
   ftp             21/tcp
   ssh             22/tcp                          # SSH Remote Login Protocol
   telnet          23/tcp
   smtp            25/tcp          mail
   domain          53/tcp
   domain          53/udp
   http            80/tcp          www             # WorldWideWeb HTTP
   ```

   Campos: `service-name  port/protocol  [aliases…]  # comment`.

2. Consultalo a través de NSS en lugar de hacer grep — esta es la forma correcta, porque respeta `/etc/nsswitch.conf`:

   ```bash
   getent services ssh
   getent services 443/tcp
   getent services 53
   ```

   ```
   ssh                   22/tcp
   https                443/tcp
   domain                53/tcp
   ```

3. Hacé lo mismo con los números de protocolo IP, un registro aparte que la gente confunde constantemente con los puertos:

   ```bash
   getent protocols icmp tcp udp ipv6-icmp
   ```

   ```
   icmp                  1 ICMP
   tcp                   6 TCP
   udp                   17 UDP
   ipv6-icmp             58 IPv6-ICMP
   ```

4. Construí vos mismo la lista de puertos del objetivo, para que salga del sistema y no de una diapositiva:

   ```bash
   for p in 20 21 22 23 25 53 80 110 123 139 143 161 162 389 443 465 514 636 993 995; do
       printf '%-5s %s\n' "$p" "$(getent services "$p/tcp" || getent services "$p/udp")"
   done
   ```

   | Puerto | Proto | Servicio | Nota |
   |---|---|---|---|
   | 20 | TCP | ftp-data | canal de datos en modo activo |
   | 21 | TCP | ftp | canal de control |
   | 22 | TCP | ssh | también SFTP y SCP |
   | 23 | TCP | telnet | texto plano — solo legado |
   | 25 | TCP | smtp | de MTA a MTA |
   | 53 | UDP **y** TCP | domain | DNS |
   | 80 | TCP | http | |
   | 110 | TCP | pop3 | |
   | 123 | UDP | ntp | |
   | 139 | TCP | netbios-ssn | SMB sobre NetBIOS |
   | 143 | TCP | imap | |
   | 161 | UDP | snmp | consultas |
   | 162 | UDP | snmptrap | traps, dirección opuesta |
   | 389 | TCP/UDP | ldap | |
   | 443 | TCP (+UDP para QUIC/HTTP-3) | https | |
   | 465 | TCP | submissions | SMTP sobre TLS implícito |
   | 514 | UDP | syslog | TCP/514 es `shell`/rsh |
   | 636 | TCP | ldaps | |
   | 993 | TCP | imaps | |
   | 995 | TCP | pop3s | |

5. Confirmá que `/etc/services` es solo una *etiqueta*, nunca un punto de aplicación de políticas:

   ```bash
   sudo cp /etc/services /tmp/services.bak
   nc -l 8080 &                       # bind a port with no /etc/services entry
   ss -ltnp 'sport = :8080'
   kill %1
   ```

   El socket se enlaza sin importar si existe un nombre.

> **Comprobá tu comprensión — Bloque 4**
> 4.1 ¿Cuáles de los puertos listados usan UDP en lugar de TCP por defecto, y cuál usa legítimamente ambos?
> 4.2 Si borrás la línea `ssh 22/tcp` de `/etc/services`, ¿deja de funcionar `sshd`? ¿Cambia `ss -ltn`? ¿Cambia `ss -lt`?
> 4.3 Distinguí los puertos 465, 587 y 25 por su rol. ¿Cuál fue deprecado y luego reinstaurado, y para qué?
> 4.4 El puerto 514 aparece dos veces en el registro con protocolos y servicios distintos. Nombrá ambos y explicá el riesgo operativo de confundirlos.
> 4.5 ¿Cuál es la diferencia entre el número `6` en `/etc/protocols` y el número `22` en `/etc/services` — qué cabecera lleva cada uno?
> 4.6 ¿Qué rangos de puertos son "bien conocidos", "registrados" y "dinámicos/efímeros", y qué sysctl controla el último en Linux?

---

## Ejercicio 5 — TCP versus UDP, observado en el cable

**Objetivo:** ver el saludo de tres vías, la naturaleza sin conexión de UDP, y cómo señala cada protocolo un fallo.

### Pasos

1. Abrí una captura en una terminal (**terminal A**):

   ```bash
   sudo tcpdump -n -i lo -c 12 'tcp port 9000 or udp port 9001 or icmp'
   ```

2. En la **terminal B**, arrancá un listener TCP y conectate a él desde la **terminal C**:

   ```bash
   # terminal B
   nc -l 9000
   # terminal C
   printf 'hello tcp\n' | nc 127.0.0.1 9000
   ```

3. Leé la captura en la terminal A:

   ```
   IP 127.0.0.1.53712 > 127.0.0.1.9000: Flags [S],  seq 2216348918, win 65495, options [mss 65495,sackOK,TS val 3324180196 ecr 0,nop,wscale 7], length 0
   IP 127.0.0.1.9000 > 127.0.0.1.53712: Flags [S.], seq 3944281530, ack 2216348919, win 65483, options [mss 65495,sackOK,TS val 3324180196 ecr 3324180196,nop,wscale 7], length 0
   IP 127.0.0.1.53712 > 127.0.0.1.9000: Flags [.],  ack 1, win 512, length 0
   IP 127.0.0.1.53712 > 127.0.0.1.9000: Flags [P.], seq 1:11, ack 1, win 512, length 10
   IP 127.0.0.1.9000 > 127.0.0.1.53712: Flags [.],  ack 11, win 512, length 0
   IP 127.0.0.1.53712 > 127.0.0.1.9000: Flags [F.], seq 11, ack 1, win 512, length 0
   IP 127.0.0.1.9000 > 127.0.0.1.53712: Flags [F.], seq 1, ack 12, win 512, length 0
   IP 127.0.0.1.53712 > 127.0.0.1.9000: Flags [.],  ack 2, win 512, length 0
   ```

   `[S]` = SYN, `[S.]` = SYN+ACK, `[.]` = ACK simple, `[P.]` = PSH+ACK, `[F.]` = FIN+ACK, `[R]` = RST. Nueve paquetes para mover diez bytes.

4. Repetí con UDP. Reiniciá la captura y luego:

   ```bash
   # terminal B
   nc -u -l 9001
   # terminal C
   printf 'hello udp\n' | nc -u 127.0.0.1 9001
   ```

   ```
   IP 127.0.0.1.41234 > 127.0.0.1.9001: UDP, length 10
   ```

   Un paquete. Sin saludo, sin acuse de recibo, sin cierre.

5. Ahora provocá ambos modos de fallo. Reiniciá la captura y conectate a puertos *cerrados*:

   ```bash
   nc -v -w2 127.0.0.1 9000    # nothing is listening now
   nc -u -v -w2 127.0.0.1 9001
   ```

   ```
   nc: connect to 127.0.0.1 port 9000 (tcp) failed: Connection refused
   ```

   En la captura:

   ```
   IP 127.0.0.1.53788 > 127.0.0.1.9000: Flags [S], seq 118219, length 0
   IP 127.0.0.1.9000 > 127.0.0.1.53788: Flags [R.], seq 0, ack 118220, win 0, length 0
   IP 127.0.0.1 > 127.0.0.1: ICMP 127.0.0.1 udp port 9001 unreachable, length 46
   ```

   TCP rechaza con un RST que genera él mismo; **UDP no tiene ningún mecanismo de rechazo** — el rechazo es un ICMP Destination Unreachable / Port Unreachable (tipo 3, código 3) producido por la capa IP.

6. Inspeccioná el estado de los sockets y los contadores por protocolo:

   ```bash
   ss -tan state established
   ss -uan
   ss -s
   nstat -az TcpRetransSegs TcpExtTCPSynRetrans UdpNoPorts UdpInErrors
   ```

   ```
   TcpRetransSegs                  14                 0.0
   TcpExtTCPSynRetrans              3                 0.0
   UdpNoPorts                       1                 0.0
   UdpInErrors                      0                 0.0
   ```

> **Comprobá tu comprensión — Bloque 5**
> 5.1 ¿Qué paquetes exactos forman el saludo de tres vías, y qué prueba cada lado al enviar su parte?
> 5.2 ¿Por qué la transferencia del paso 3 cuesta nueve paquetes mientras que la del paso 4 cuesta uno? Nombrá tres garantías de TCP que estás pagando.
> 5.3 Un datagrama UDP enviado a un puerto cerrado produjo un mensaje ICMP en lugar de una respuesta UDP. ¿Qué implica esto para alguien que intenta escanear puertos UDP a través de un firewall que descarta ICMP en silencio?
> 5.4 Compará los tamaños mínimos de cabecera de TCP y UDP y enumerá qué compran los bytes extra.
> 5.5 El checksum de UDP es opcional en IPv4 pero obligatorio en IPv6. ¿Por qué cambió eso?
> 5.6 DNS, NTP, SNMP, syslog y VoIP usan UDP por defecto. ¿Qué propiedad comparten que hace de la retransmisión en la capa de transporte un mal negocio?
> 5.7 En la salida de tcpdump apareció `Flags [R.]` en lugar de `[R]`. ¿Cuál es la diferencia, y cuándo ves un `[R]` simple?

---

## Ejercicio 6 — ICMP e ICMPv6: diagnóstico, no "ping"

**Objetivo:** tratar a ICMP como un protocolo de control y no como un juguete, y entender por qué bloquearlo rompe IPv6 de plano.

### Pasos

1. Enviá echo requests y leé los metadatos de la respuesta:

   ```bash
   ping -c3 1.1.1.1
   ```

   ```
   PING 1.1.1.1 (1.1.1.1) 56(84) bytes of data.
   64 bytes from 1.1.1.1: icmp_seq=1 ttl=57 time=11.4 ms
   64 bytes from 1.1.1.1: icmp_seq=2 ttl=57 time=10.9 ms
   64 bytes from 1.1.1.1: icmp_seq=3 ttl=57 time=11.2 ms

   --- 1.1.1.1 ping statistics ---
   3 packets transmitted, 3 received, 0% packet loss, time 2003ms
   rtt min/avg/max/mdev = 10.912/11.183/11.436/0.214 ms
   ```

   `56(84)` = 56 bytes de payload + 8 bytes de cabecera ICMP + 20 bytes de cabecera IPv4.

2. Observá los tipos ICMP en el cable:

   ```bash
   sudo tcpdump -n -i any -c4 'icmp or icmp6'
   ```

   ```
   IP 192.168.178.42 > 1.1.1.1: ICMP echo request, id 4711, seq 1, length 64
   IP 1.1.1.1 > 192.168.178.42: ICMP echo reply,   id 4711, seq 1, length 64
   ```

   Echo request es **tipo 8**, echo reply **tipo 0** en ICMPv4; **128** y **129** en ICMPv6.

3. Usá ICMP para descubrir el MTU del camino a mano — `-M do` fija el bit Don't Fragment:

   ```bash
   ping -c1 -M do -s 1472 1.1.1.1        # 1472 + 8 + 20 = 1500, fits
   ping -c1 -M do -s 1473 1.1.1.1        # one byte too many
   ```

   ```
   ping: local error: message too long, mtu=1500
   ```

   A través de un camino con túnel obtenés en cambio la respuesta del router:

   ```
   From 10.8.0.1 icmp_seq=1 Frag needed and DF set (mtu = 1420)
   ```

   Eso es ICMP **tipo 3, código 4** — el mensaje del que depende el Path MTU Discovery.

4. Dejá que `tracepath` lo haga automáticamente, para ambas familias:

   ```bash
   tracepath -4 1.1.1.1
   tracepath -6 2606:4700:4700::1111
   ```

   ```
    1?: [LOCALHOST]                      pmtu 1500
    1:  192.168.178.1                     0.512ms
    2:  10.64.0.1                         8.114ms asymm  3
    3:  no reply
    ...
        Resume: pmtu 1500 hops 9 back 9
   ```

5. Mirá cómo `traceroute` explota el vencimiento del TTL (ICMP tipo 11):

   ```bash
   traceroute -n 1.1.1.1        # default: UDP probes to high ports
   traceroute -n -I 1.1.1.1     # ICMP echo probes
   traceroute -n -T -p 443 1.1.1.1   # TCP SYN probes — survives most filters
   ```

   Cada sonda sale con TTL 1, 2, 3…; todo router que decremente el TTL a cero devuelve **Time Exceeded**, revelándose.

6. Observá a ICMPv6 haciendo un trabajo que no tiene equivalente en IPv4 — Neighbor Discovery:

   ```bash
   ip -6 neigh show
   ping -c2 ff02::1%enp1s0            # all-nodes link-local multicast
   sudo tcpdump -n -i enp1s0 -c6 'icmp6 and (ip6[40] == 135 or ip6[40] == 136)'
   ```

   ```
   IP6 fe80::5054:ff:fe12:3456 > ff02::1:ff00:1: ICMP6, neighbor solicitation, who has 2001:db8:1234:5678::1, length 32
   IP6 2001:db8:1234:5678::1 > fe80::5054:ff:fe12:3456: ICMP6, neighbor advertisement, tgt is 2001:db8:1234:5678::1, length 32
   ```

   Los tipos 135/136 reemplazan a ARP; 133/134 (Router Solicitation / Advertisement) no reemplazan nada en IPv4 — no existe un equivalente IPv4 de la autoconfiguración por router en la capa 3.

> **Comprobá tu comprensión — Bloque 6**
> 6.1 ICMP tiene número de protocolo pero no números de puerto. ¿Cuál es su número de protocolo, y qué campos identifican qué respuesta corresponde a qué solicitud?
> 6.2 Asociá cada comportamiento observado con un tipo/código ICMP: `Destination Host Unreachable`, `Connection timed out`, `Frag needed and DF set`, una línea de salto de `traceroute`.
> 6.3 Una política de firewall dice "descartar todo ICMP". Nombrá dos cosas que se rompen en IPv4 y dos que se rompen *catastróficamente* en IPv6.
> 6.4 `ping` devuelve `ttl=57`. ¿Cuál fue el TTL inicial probable y cuántos saltos cruzó la respuesta?
> 6.5 El `traceroute` por defecto en Linux envía UDP, no echo ICMP. ¿Cómo reconoce entonces al destino final?
> 6.6 En IPv6 un router nunca fragmenta un paquete en tránsito. ¿Qué mensaje ICMPv6 reemplaza a "fragmentation needed", y qué debe hacer el *origen* al recibirlo?

---

## Ejercicio 7 — IPv6 en la práctica: notación, SLAAC y selección de dirección

**Objetivo:** comprimir y expandir direcciones correctamente, derivar a mano un identificador de interfaz EUI-64, y entender por qué tu distro moderna probablemente *no* use uno.

### Pasos

1. Aplicá las dos reglas de compresión (RFC 4291 §2.2, RFC 5952 para la forma canónica):
   - Quitá los ceros **iniciales** dentro de cada grupo de 16 bits.
   - Reemplazá **una** secuencia de grupos consecutivos todos en cero por `::`.

   ```bash
   # sipcalc expands and normalises for you
   sipcalc 2001:0db8:0000:0000:0008:0800:200c:417a | head -6
   ```

   ```
   Expanded Address        - 2001:0db8:0000:0000:0008:0800:200c:417a
   Compressed address      - 2001:db8::8:800:200c:417a
   ```

2. Derivá a mano un identificador **EUI-64 modificado** a partir de la MAC `52:54:00:12:34:56`:

   - Partila al medio e insertá `ff:fe`: `52:54:00` + `ff:fe` + `12:34:56` → `5254:00ff:fe12:3456`
   - Invertí el bit 1 (el bit universal/local) del primer byte: `0x52 = 0101 0010` → `0101 0000 = 0x50`
   - Resultado: `5054:00ff:fe12:3456` → comprimido `5054:ff:fe12:3456`
   - Dirección link-local: `fe80::5054:ff:fe12:3456`

   Confirmá contra la máquina:

   ```bash
   ip link show enp1s0 | awk '/link\/ether/{print $2}'
   ip -6 addr show dev enp1s0 scope link
   ```

3. Mirá SLAAC en acción. Dispará una Router Solicitation y leé la Router Advertisement:

   ```bash
   sudo rdisc6 enp1s0 2>/dev/null || sudo tcpdump -n -v -i enp1s0 -c2 'icmp6 and ip6[40] == 134'
   ```

   ```
   IP6 fe80::1 > ff02::1: ICMP6, router advertisement, length 88
       hop limit 64, Flags [none], pref medium, router lifetime 1800s, reachable time 0ms
       prefix info option (3), length 32 (4): 2001:db8:1234:5678::/64, Flags [onlink, auto], valid time 7200s, pref. time 3600s
   ```

   El host toma el prefijo `/64` de la RA y le agrega su propio identificador de interfaz — sin servidor, sin lease, sin estado.

4. Inspeccioná las perillas que deciden *qué* identificador se agrega:

   ```bash
   sysctl net.ipv6.conf.enp1s0.accept_ra \
          net.ipv6.conf.enp1s0.autoconf \
          net.ipv6.conf.enp1s0.use_tempaddr \
          net.ipv6.conf.enp1s0.addr_gen_mode
   ```

   ```
   net.ipv6.conf.enp1s0.accept_ra = 1
   net.ipv6.conf.enp1s0.autoconf = 1
   net.ipv6.conf.enp1s0.use_tempaddr = 2
   net.ipv6.conf.enp1s0.addr_gen_mode = 0
   ```

   `addr_gen_mode` `0` = EUI-64, `2`/`3` = stable-privacy (RFC 7217). `use_tempaddr = 2` habilita direcciones temporales (RFC 8981) y las *prefiere* como origen.

5. Derivá la dirección multicast de nodo solicitado a la que la interfaz debe unirse para `fe80::5054:ff:fe12:3456`: tomá los 24 bits bajos (`12:3456`) y anteponé `ff02::1:ff` → `ff02::1:ff12:3456`. Verificá:

   ```bash
   ip maddr show dev enp1s0 | grep -i ff02
   netstat -g6 2>/dev/null | head
   ```

6. Confirmá empíricamente las reglas de preferencia de dirección de origen (RFC 6724):

   ```bash
   ip -6 route get 2606:4700:4700::1111 | grep -o 'src [0-9a-f:]*'
   getent ahosts www.kernel.org | head -4
   ```

> **Comprobá tu comprensión — Bloque 7**
> 7.1 Comprimí: `2001:0db8:0000:0001:0000:0000:0000:0001` y `ff02:0000:0000:0000:0000:0000:0000:0001`. Expandí: `::ffff:192.0.2.1`.
> 7.2 ¿Por qué `::` puede aparecer solo una vez en una dirección?
> 7.3 Derivá la dirección link-local EUI-64 para la MAC `00:1a:2b:3c:4d:5e`. Mostrá la inversión de bit explícitamente.
> 7.4 Fedora y Ubuntu modernos no construyen direcciones a partir de la MAC por defecto. ¿Qué usan en cambio, y qué problema de privacidad resuelve eso que EUI-64 creó?
> 7.5 Enumerá cuatro diferencias estructurales entre las cabeceras IPv4 e IPv6, y dá una consecuencia operativa de cada una.
> 7.6 SLAAC da dirección, prefijo y gateway. ¿Qué *no* da, y qué dos mecanismos cubren esa carencia?
> 7.7 Un host tiene tanto una dirección IPv6 global como una IPv4, y el destino tiene registros AAAA y A. ¿Cuál se intenta primero, y qué mecanismo evita una demora larga cuando IPv6 está roto?

---

## Ejercicio 8 — Diagnosticar desde el síntoma: refused, timeout, no route, DNS

**Objetivo:** convertir cuatro reportes indistinguibles de "no anda" en cuatro veredictos distintos y específicos por capa.

### Pasos

1. Establecé la línea base de qué está escuchando localmente:

   ```bash
   sudo ss -ltnup
   ```

   ```
   Netid State  Recv-Q Send-Q Local Address:Port Peer Address:Port Process
   udp   UNCONN 0      0          127.0.0.53:53        0.0.0.0:*     users:(("systemd-resolve",pid=612,fd=12))
   udp   UNCONN 0      0       0.0.0.0%enp1s0:68       0.0.0.0:*     users:(("NetworkManager",pid=744,fd=22))
   tcp   LISTEN 0      4096       127.0.0.53:53        0.0.0.0:*     users:(("systemd-resolve",pid=612,fd=13))
   tcp   LISTEN 0      128           0.0.0.0:22        0.0.0.0:*     users:(("sshd",pid=901,fd=3))
   tcp   LISTEN 0      128              [::]:22           [::]:*     users:(("sshd",pid=901,fd=4))
   ```

   Leé la **dirección de binding**, no solo el puerto: `127.0.0.53:53` es inalcanzable desde la red; `0.0.0.0:22` no lo es.

2. Producí el síntoma A — *connection refused*:

   ```bash
   nc -vz 127.0.0.1 9999
   ```
   ```
   nc: connect to 127.0.0.1 port 9999 (tcp) failed: Connection refused
   ```
   El host respondió con RST. Está levantado, es alcanzable, y no hay nada enlazado a ese puerto.

3. Producí el síntoma B — *timeout*:

   ```bash
   nc -vz -w3 192.0.2.10 22
   ```
   ```
   nc: connect to 192.0.2.10 port 22 (tcp) timed out: Operation now in progress
   ```
   Ninguna respuesta: un firewall haciendo DROP, o un host caído.

4. Producí el síntoma C — *no route*:

   ```bash
   ip route get 203.0.113.9 2>&1
   ```
   ```
   RTNETLINK answers: Network is unreachable
   ```
   El fallo ocurrió antes de que se emitiera un solo paquete — un problema de la tabla de enrutamiento, no de la red.

5. Producí el síntoma D — *resolución de nombres*:

   ```bash
   getent hosts does-not-exist.invalid ; echo "exit=$?"
   dig +short A example.com
   dig +short AAAA example.com
   resolvectl status | head -20
   ```

6. Confirmá qué transporte usó realmente DNS, y forzá el otro:

   ```bash
   sudo tcpdump -n -i any -c4 'port 53' &
   dig +short A www.kernel.org @1.1.1.1
   dig +tcp +short A www.kernel.org @1.1.1.1
   ```

   ```
   IP 192.168.178.42.42311 > 1.1.1.1.53: 12345+ A? www.kernel.org. (32)
   IP 1.1.1.1.53 > 192.168.178.42.42311: 12345 2/0/0 A 139.178.84.217 (64)
   IP 192.168.178.42.51022 > 1.1.1.1.53: Flags [S], seq 88112, length 0
   IP 1.1.1.1.53 > 192.168.178.42.51022: Flags [S.], seq 4413, ack 88113, length 0
   ```

7. Asociá puerto con proceso para una conexión establecida, como lo harías durante un incidente:

   ```bash
   ss -tnp state established '( dport = :443 or sport = :443 )' | head
   ```

> **Comprobá tu comprensión — Bloque 8**
> 8.1 Ordená estos cuatro veredictos de "más cerca de la aplicación" a "más cerca del cable": `Connection refused`, `Network is unreachable`, `Connection timed out`, `Name or service not known`.
> 8.2 Un servicio escucha en `127.0.0.1:8080` y un cliente remoto obtiene `Connection refused`. El firewall no tiene nada mal. ¿Qué está mal, y qué único cambio lo arregla?
> 8.3 ¿Por qué una regla de firewall DROP produce un timeout mientras que una regla REJECT produce `Connection refused`? ¿Qué paquete envía REJECT para TCP, y cuál para UDP?
> 8.4 `ss -ltn` muestra tanto `0.0.0.0:22` como `[::]:22`. En muchos sistemas solo aparece `[::]:22` y sin embargo los clientes IPv4 igual conectan. Explicá, y nombrá el sysctl involucrado.
> 8.5 DNS usó UDP primero y TCP solo cuando se lo forzó. Nombrá dos situaciones en las que un resolver cambia a TCP por sí mismo.
> 8.6 Podés hacer `ping 8.8.8.8` pero no `ping google.com`. ¿Qué capa está rota, y qué dos archivos (o qué servicio) inspeccionás primero?

---

## Ejercicio 9 — Integrador: documentar la postura de red de un host

**Objetivo:** producir, en una sola pasada, la evidencia que pediría un auditor o un ingeniero de guardia.

### Pasos

1. Escribí y ejecutá este recolector:

   ```bash
   #!/usr/bin/env bash
   # net-posture.sh — summarise the L3/L4 posture of this host
   set -euo pipefail

   echo "== Addresses =="
   ip -brief address show

   echo; echo "== Default routes =="
   ip -4 route show default
   ip -6 route show default

   echo; echo "== Listening TCP/UDP sockets (with binding scope) =="
   ss -ltnup | awk 'NR==1 || $5 !~ /^127\.|^\[::1\]/'

   echo; echo "== Ports exposed on non-loopback addresses =="
   ss -ltn | awk 'NR>1 {split($4,a,":"); if (a[1] != "127.0.0.1" && $4 !~ /\[::1\]/) print $4}' | sort -u

   echo; echo "== Resolvers =="
   resolvectl status 2>/dev/null | grep -E 'DNS Servers|DNS Domain' || cat /etc/resolv.conf

   echo; echo "== Path MTU to the default gateway =="
   gw=$(ip -4 route show default | awk '{print $3; exit}')
   tracepath -4 -n "$gw" 2>/dev/null | tail -1
   ```

2. Ejecutalo y reconciliá cada socket a la escucha contra `/etc/services`:

   ```bash
   chmod +x net-posture.sh && ./net-posture.sh | tee posture.txt
   ss -ltn | awk 'NR>1 {n=split($4,a,":"); print a[n]}' | sort -un |
       while read -r p; do printf '%-6s %s\n' "$p" "$(getent services "$p/tcp" | awk '{print $1}')"; done
   ```

3. Para cada puerto expuesto en una dirección que no sea de loopback, respondé por escrito: qué proceso lo posee, si el protocolo está cifrado, y si debería ser alcanzable desde fuera de la subred del host.

> **Comprobá tu comprensión — Bloque 9**
> 9.1 El reporte lista `0.0.0.0:23` en manos de `inetd`. Enunciá el riesgo en una oración y el reemplazo correcto.
> 9.2 También lista `0.0.0.0:389` pero no `0.0.0.0:636`. ¿Cuál es el hallazgo, y qué verificarías antes de recomendar un cambio?
> 9.3 `0.0.0.0:161` está presente y el host está en una red enrutada. ¿Qué dos problemas específicos de SNMP planteás?
> 9.4 El MTU del camino al gateway vuelve como 1492 en lugar de 1500. ¿Qué tecnología de enlace sugiere eso, y qué opción de TCP hace visible la diferencia?
> 9.5 Un socket aparece como `[::]:5432` sin una entrada IPv4 equivalente. ¿Es PostgreSQL alcanzable sobre IPv4? ¿Qué lo decide?

---

<details>
<summary><strong>Respuestas</strong></summary>

### Bloque 1 — Configuración IP local

**1.1** `brd 192.168.178.255` es la dirección de broadcast dirigido de la subred, obtenida poniendo todos los bits de host en 1: dirección `192.168.178.42` con máscara `/24` → red `192.168.178.0`, bits de host todos en uno → `192.168.178.255`. `scope global` significa que la dirección es válida para comunicarse con cualquier destino; comparalo con `scope host` (loopback, válida solo dentro de esta máquina) y `scope link` (válida solo en el enlace conectado). `noprefixroute` significa que NetworkManager, y no el kernel, gestiona la ruta on-link de ese prefijo.

**1.2**
- `fe80::5054:ff:fe12:3456/64` — **link-local**, `scope link`, obligatoria en toda interfaz con IPv6 habilitado, usada para NDP y como siguiente salto.
- `2001:db8:1234:5678:5054:ff:fe12:3456/64` — **unicast global**, estable, derivada acá vía EUI-64; marcada `mngtmpaddr` porque es la dirección a partir de la cual se generan las direcciones temporales.
- `2001:db8:1234:5678:8b2a:44e1:9c07:3f11/64` — **unicast global, temporal** (dirección de privacidad RFC 8981), identificador aleatorio, vida corta.

La dirección **temporal** se usa como origen para el tráfico saliente a internet, porque la selección de dirección de origen de RFC 6724 (con las enmiendas de RFC 8981 y el `use_tempaddr=2` de Linux) prefiere las temporales sobre las públicas para conexiones salientes. La estable queda disponible para servicio entrante.

**1.3** Los tiempos de vida vienen de la **opción Prefix Information en las Router Advertisements** (RFC 4862): `valid_lft` del *Valid Lifetime*, `preferred_lft` del *Preferred Lifetime*. Las direcciones link-local no se aprenden de las RA, así que son `forever`. Una dirección **deprecated** (preferred vencido, valid no) sigue siendo usable para conexiones *existentes* pero ya no se elige como origen para las *nuevas* — que es exactamente cómo IPv6 hace renumeraciones make-before-break sin cortar sesiones.

**1.4** Porque el siguiente salto solo tiene que ser alcanzable **en el enlace**, no globalmente. La dirección link-local del router está garantizada que existe, es estable frente a renumeraciones, y nunca cambia cuando cambia el prefijo global del sitio — por eso las RA anuncian al router por su dirección link-local y por eso las rutas por defecto de IPv6 normalmente apuntan a `fe80::`. Semejante ruta no tiene sentido sin la interfaz, de ahí que `dev enp1s0` siempre forme parte de ella.

---

### Bloque 2 — Máscaras de red, CIDR y subnetting

**2.1** `172.16.35.99/21` → máscara `255.255.248.0`, el octeto interesante es el tercero, tamaño de bloque `256 − 248 = 8`. Límites: 0, 8, 16, 24, **32**, 40… `35` cae en el bloque que empieza en 32.
- Red: `172.16.32.0`
- Broadcast: `172.16.39.255`
- Primer utilizable: `172.16.32.1`, último utilizable: `172.16.39.254`
- Hosts utilizables: `2^(32−21) − 2 = 2048 − 2 = 2046`

**2.2** Sí. `/26` → tamaño de bloque 64 → límites `.0 .64 .128 .192`. `130` y `190` caen ambos en `128–191`, así que ambos pertenecen a `192.168.4.128/26` (broadcast `.191`). Pueden hablarse sin un router.

**2.3** `2^(26−24) = 4` subredes: `.0/26`, `.64/26`, `.128/26`, `.192/26`. Cada una tiene `2^(32−26) − 2 = 62` hosts utilizables.

**2.4** Un `/31` se usa para **enlaces punto a punto** según RFC 3021. En un enlace punto a punto no hace falta dirección de broadcast (hay exactamente un par posible) ni identificador de red, así que ambas direcciones son asignables como hosts. Reduce a la mitad el desperdicio de direcciones del `/30` en enlaces entre routers.

**2.5** Asigná primero el más grande (ese es el sentido de VLSM):

| Segmento | Requerimiento | Prefijo | Rango | Utilizables |
|---|---|---|---|---|
| LAN-A | 100 hosts | `192.168.50.0/25` | `.0`–`.127` | 126 |
| LAN-B | 50 hosts | `192.168.50.128/26` | `.128`–`.191` | 62 |
| LAN-C | 20 hosts | `192.168.50.192/27` | `.192`–`.223` | 30 |
| p2p-1 | 2 hosts | `192.168.50.224/30` | `.224`–`.227` | 2 |
| p2p-2 | 2 hosts | `192.168.50.228/30` | `.228`–`.231` | 2 |

Sobrante: `192.168.50.232` – `192.168.50.255` (24 direcciones, es decir un `/29` + `/30` + `/31` + … libres), disponible para crecimiento.

**2.6** Porque **SLAAC requiere un identificador de interfaz de 64 bits** (RFC 4862 / RFC 4291): el ID de interfaz se genera para llenar los 64 bits bajos, así que un prefijo más largo que `/64` rompe la autoconfiguración sin estado, y varios otros mecanismos (direcciones de privacidad, direcciones generadas criptográficamente, anycast Subnet-Router) asumen la misma división. La conservación de direcciones no es una preocupación — un solo `/64` contiene `2^64` direcciones, y los ISP delegan `/56` o `/48` precisamente para que cada enlace pueda tener uno.

---

### Bloque 3 — Rangos reservados

**3.1** Privadas: `172.31.255.254` (dentro de `172.16.0.0/12`) y `10.255.255.254` (dentro de `10.0.0.0/8`).
Públicas: `172.15.200.1` (por debajo del bloque), `172.32.0.5` (por encima del bloque — el `/12` termina en `172.31`), `192.169.1.1` (el bloque privado es `192.168.0.0/16`, no `192.169`).

**3.2** DHCP no recibió respuesta, así que el host se autoasignó una dirección IPv4 link-local (APIPA, RFC 3927). Primeras verificaciones, en orden: ¿está el enlace realmente levantado (`ip link show eth0` → `LOWER_UP`, `ethtool eth0` para el carrier); hay un cliente DHCP corriendo (`systemctl status NetworkManager` / `dhcpcd` / `systemd-networkd`); y están saliendo paquetes DISCOVER y volviendo algo (`sudo tcpdump -n -i eth0 port 67 or port 68`). Recién después sospechá del servidor DHCP o de una mala configuración de VLAN/trunk.

**3.3** En IPv4 todo el `127.0.0.0/8` es loopback, así que distintos servicios locales pueden enlazarse a distintas direcciones de loopback — así es exactamente como `systemd-resolved` usa `127.0.0.53:53` mientras un servidor DNS real puede seguir usando `127.0.0.1:53`, y así se pueden correr muchas instancias locales en el mismo puerto. IPv6 tiene solo `::1`, así que este truco no tiene equivalente en IPv6; los servicios locales deben diferenciarse por puerto.

**3.4** `fe80::/10` es link-local: el *mismo* prefijo existe simultáneamente en todas las interfaces, así que la dirección sola es ambigua — el kernel no puede elegir una interfaz de salida. El sufijo `%zone` (el "scope ID") desambigua. `192.168.178.1` es una dirección de scope global y coincide con exactamente una ruta en la tabla de enrutamiento, así que no hace falta desambiguar.

**3.5** Usá una **Unique Local Address** de `fd00::/8` (RFC 4193). Los 40 bits después de `fd` deben ser **generados aleatoriamente**, no elegidos — p. ej. `head -c5 /dev/urandom | xxd -p` → `fdXX:XXXX:XXXX::/48` — que es lo que hace que las colisiones accidentales entre redes fusionadas sean extremadamente improbables. **No** es NAT de IPv6: las ULA son una decisión de *scope* (no enrutadas globalmente), y el diseño estándar corre las ULA *junto a* las direcciones globales en la misma interfaz en lugar de traducir entre ellas. La traducción de direcciones no forma parte del modelo; RFC 6724 se ocupa de qué origen usar.

---

### Bloque 4 — `/etc/services` y puertos

**4.1** UDP por defecto: **123** (NTP), **161** (SNMP), **162** (trap SNMP), **514** (syslog). Legítimamente ambos: **53** (DNS) — UDP para consultas ordinarias, TCP para transferencias de zona y respuestas sobredimensionadas. **389** está registrado para ambos pero LDAP usa TCP en la práctica (UDP/389 era CLDAP). **443** es TCP para HTTP/1.1 y HTTP/2 y UDP para QUIC/HTTP-3.

**4.2** `sshd` sigue funcionando: enlaza el puerto 22 desde la directiva `Port` de `sshd_config` (un número), no desde una búsqueda por nombre — e incluso cuando una configuración usa un nombre, la búsqueda ocurre una sola vez al arrancar. `ss -ltn` **no** cambia (`-n` significa numérico). `ss -lt` **sí** cambia: sin `-n` resuelve los números de puerto a nombres vía NSS, así que el puerto 22 se imprimiría como `22` en lugar de `ssh`.

**4.3**
- **25/tcp (smtp)** — relay de correo servidor a servidor entre MTA. Ampliamente bloqueado en saliente por los ISP domésticos.
- **587/tcp (submission)** — *envío* de correo desde un agente de usuario, autenticado, con actualización oportunista STARTTLS (RFC 6409).
- **465/tcp** — originalmente `smtps` (TLS implícito), **deprecado en 1998** en favor de STARTTLS en 587, y luego **reinstaurado en 2018 por RFC 8314** como `submissions`, porque el TLS implícito evita el ataque de degradación por stripping de STARTTLS. Hoy es el puerto de envío recomendado.

**4.4** `syslog 514/udp` (registro remoto clásico) y `shell 514/tcp` (rsh, el shell remoto de Berkeley). Riesgo operativo: una regla de firewall escrita como "permitir 514" sin especificar el protocolo abre rsh — un servicio de ejecución remota sin autenticación y en texto plano — mientras creías estar permitiendo el envío de logs. Escribí siempre las reglas como `514/udp`.

**4.5** `6` en `/etc/protocols` es el **número de protocolo IP**, transportado en el campo `Protocol` de la cabecera IPv4 (o `Next Header` en IPv6); dice qué transporte sigue. `22` en `/etc/services` es un **número de puerto**, transportado en la cabecera TCP (o UDP); identifica el extremo de la aplicación. Cabeceras distintas, capas distintas, registros distintos — ICMP (protocolo 1) tiene número de protocolo y ningún puerto.

**4.6**
- **Bien conocidos / de sistema**: 0–1023 — en Linux, enlazarlos requiere `CAP_NET_BIND_SERVICE` (históricamente root).
- **Registrados / de usuario**: 1024–49151 — asignados por IANA a pedido.
- **Dinámicos / privados / efímeros**: 49152–65535 según IANA.

Linux no usa el rango efímero de IANA por defecto; usa `net.ipv4.ip_local_port_range` (típicamente `32768 60999`), legible con `sysctl net.ipv4.ip_local_port_range`. El mismo rango gobierna IPv6.

---

### Bloque 5 — TCP vs UDP

**5.1** SYN → SYN/ACK → ACK. El SYN del cliente lleva su Initial Sequence Number (ISN); el SYN/ACK del servidor lo reconoce y lleva el ISN del servidor; el ACK del cliente reconoce el ISN del servidor. Cada lado prueba así que **recibió** el ISN del otro, lo que establece alcanzabilidad bidireccional y frustra el spoofing a ciegas (un atacante fuera del camino no puede adivinar el ISN). Opciones como MSS, window scale, SACK-permitted y timestamps se negocian solo en los dos primeros paquetes.

**5.2** Nueve paquetes = 3 del saludo + 1 de datos + 1 ACK de los datos + 4 del cierre FIN/ACK en ambas direcciones. Estás pagando por: (a) **entrega confiable** — cada byte se reconoce y se retransmite si se pierde; (b) **entrega ordenada** — los números de secuencia le permiten al receptor reensamblar; (c) **control de flujo y de congestión** — la ventana anunciada más la ventana de congestión evitan desbordar al receptor o al camino. También estado de conexión, para que los extremos coincidan en cuándo empieza y termina el flujo.

**5.3** UDP no tiene forma dentro de banda de decir "acá no hay nadie", así que la única señal negativa es **ICMP tipo 3, código 3**. Si el firewall descarta ICMP, un puerto UDP cerrado, uno filtrado y uno abierto pero silencioso se ven todos iguales — silencio. Por eso el escaneo UDP es lento y poco confiable (`nmap -sU` debe esperar timeouts y solo puede reportar `open|filtered`), y por eso también descartar ICMP de forma indiscriminada degrada la diagnosticabilidad en lugar de mejorar la seguridad.

**5.4** Cabecera UDP = **8 bytes**: puerto de origen, puerto de destino, longitud y checksum. Cabecera TCP = **20 bytes mínimo** (hasta 60 con opciones): los mismos dos puertos más número de secuencia, número de acuse, offset de datos, flags, tamaño de ventana, checksum, puntero urgente y opciones (MSS, SACK, window scale, timestamps). Los 12+ bytes extra compran secuenciación, acuse de recibo, ventaneo y estado de conexión.

**5.5** Porque **IPv6 eliminó el checksum de cabecera de la capa de red** (RFC 8200). En IPv4 una dirección o un puerto corrupto todavía podía atraparse con el checksum de la cabecera IPv4; en IPv6 nada en la capa 3 verifica integridad, así que el checksum de transporte — que cubre una pseudo-cabecera que incluye las direcciones — pasa a ser la única protección extremo a extremo y por eso es obligatorio. (La excepción acotada son ciertas encapsulaciones de túnel según RFC 6935/6936.)

**5.6** Todos son **sensibles a la latencia o idempotentes, y toleran mejor la pérdida que el retardo**. Una muestra NTP o un frame de VoIP retransmitido que llega tarde es peor que inútil — corrompe la medición o el audio. Una consulta DNS perdida es más barata de reemitir en la capa de aplicación con un nuevo ID de transacción que mantener estado de conexión por consulta en un servidor que atiende millones de consultas por segundo. El bloqueo de cabeza de línea de TCP haría que un solo paquete perdido frene todo lo que viene atrás.

**5.7** `[R.]` es **RST+ACK**: el RST reconoce el número de secuencia del paquete ofensor — se envía cuando un SYN llega a un puerto cerrado, para que el emisor sepa exactamente qué intento fue rechazado. Un `[R]` simple (RST sin ACK) se envía cuando no hay nada válido que reconocer — p. ej. un paquete que llega para una conexión de la que el receptor no tiene estado, o un cierre abortivo de una conexión establecida (`SO_LINGER` con timeout cero).

---

### Bloque 6 — ICMP e ICMPv6

**6.1** ICMPv4 es el **protocolo IP 1**; ICMPv6 es el **protocolo IP 58**. No hay puertos. Echo request/reply llevan un **Identifier** y un **Sequence Number** en la cabecera ICMP; el kernel (o `ping`) usa el identificador para asociar las respuestas al proceso y el número de secuencia para asociarlas a la sonda individual. Los mensajes de error (tipos 3, 11, …) en cambio citan los **primeros bytes del paquete ofensor**, incluida su cabecera IP y los primeros 8 bytes de la cabecera de transporte — que es exactamente lo suficiente para recuperar los puertos originales y entregar el error al socket correcto.

**6.2**
- `Destination Host Unreachable` → **tipo 3, código 1** (Destination Unreachable / Host Unreachable). ICMPv6: tipo 1, código 3.
- `Connection timed out` → **ningún ICMP en absoluto**. Es la ausencia de toda respuesta — la pila TCP local se dio por vencida. Ese es su valor diagnóstico: el silencio significa un DROP o un host muerto.
- `Frag needed and DF set` → **tipo 3, código 4** (Fragmentation Needed and DF Set). ICMPv6: **tipo 2**, Packet Too Big.
- Una línea de salto de `traceroute` → **tipo 11, código 0** (Time Exceeded / TTL exceeded in transit). ICMPv6: tipo 3, código 0.

**6.3** Rotura en IPv4: **Path MTU Discovery** deja de funcionar (se descarta el tipo 3/4, produciendo el clásico agujero negro de "las páginas chicas cargan, las grandes se cuelgan"), y el diagnóstico — `ping`, `traceroute`, y el fallo rápido vía Destination Unreachable — se apaga, convirtiendo errores instantáneos en timeouts de 2 minutos.
La rotura en IPv6 es peor e inmediata: **Neighbor Discovery** (tipos 135/136) reemplaza a ARP, así que los hosts del mismo enlace no pueden resolver sus direcciones de capa de enlace; y **Router Solicitation/Advertisement** (133/134) es cómo los hosts obtienen su prefijo y su ruta por defecto, así que SLAAC nunca se completa. Además, los routers nunca fragmentan en IPv6, así que bloquear **Packet Too Big (tipo 2)** convierte en agujero negro todo camino con MTU reducido. RFC 4890 existe precisamente para especificar qué puede y qué no puede filtrarse.

**6.4** Los valores iniciales de TTL habituales son 64 (Linux, macOS, la mayoría del equipamiento de red), 128 (Windows) y 255 (algunos routers/Solaris). `57` es `64 − 7`, así que el TTL inicial fue casi con certeza **64** y la respuesta cruzó **7** routers. Notá que esto mide el camino de *vuelta*, que puede diferir del de ida.

**6.5** Envía sondas UDP a un rango de **puertos de destino altos y deliberadamente sin uso** (desde 33434 en adelante). Los routers intermedios responden con Time Exceeded; el **destino final**, al no tener nada enlazado a ese puerto, responde en cambio con **ICMP Destination Unreachable / Port Unreachable (tipo 3, código 3)**. Ese mensaje distinto es cómo `traceroute` sabe que llegó y se detiene.

**6.6** **ICMPv6 tipo 2, Packet Too Big**, que lleva el MTU del enlace restringido. Al recibirlo, el **origen** debe reducir el tamaño del paquete — ya sea bajando su propio MSS/tamaño de segmento o, si insiste en enviar payloads más grandes, fragmentando él mismo mediante la **cabecera de extensión Fragment** de IPv6. A los routers intermedios se les prohíbe fragmentar (RFC 8200 §4.5), y por eso descartar el tipo 2 crea un agujero negro indetectable.

---

### Bloque 7 — IPv6 en la práctica

**7.1**
- `2001:0db8:0000:0001:0000:0000:0000:0001` → **`2001:db8:0:1::1`** (el `::` debe reemplazar la secuencia de ceros *más larga* — los tres grupos finales, no el grupo único de la posición 3).
- `ff02:0000:0000:0000:0000:0000:0000:0001` → **`ff02::1`** (la dirección multicast link-local de todos los nodos).
- `::ffff:192.0.2.1` → **`0000:0000:0000:0000:0000:ffff:c000:0201`** — una dirección IPv6 mapeada a IPv4 (RFC 4291 §2.5.5.2), la forma en que un socket de doble pila representa a un par IPv4.

**7.2** Porque `::` significa "tantos grupos todos en cero como haga falta para llegar a 128 bits". Con dos apariciones la expansión sería ambigua — `2001::1::5` podría ser cualquiera de varias direcciones distintas, ya que no hay forma de saber cuántos grupos de ceros corresponden a cada `::`.

**7.3** MAC `00:1a:2b:3c:4d:5e`:
1. Partir e insertar `ff:fe` → `00:1a:2b : ff:fe : 3c:4d:5e` → `001a:2bff:fe3c:4d5e`
2. Invertir el bit 1 del primer byte: `0x00 = 0000 0000` → `0000 0010 = 0x02`
3. ID de interfaz: `021a:2bff:fe3c:4d5e`
4. Dirección link-local: **`fe80::21a:2bff:fe3c:4d5e`**

Notá que la inversión va en *ambos* sentidos: una MAC globalmente única (asignada por OUI) tiene el bit U/L en **0**, y el EUI-64 modificado lo invierte a **1** para marcar el identificador como globalmente único según la convención propia de IPv6.

**7.4** Usan **direcciones stable-privacy de RFC 7217** (`addr_gen_mode=2`/`3`, expuesto por NetworkManager como `ipv6.addr-gen-mode stable-privacy` y por systemd-networkd como `IPv6LinkLocalAddressGenerationMode=stable-privacy`), más **direcciones temporales de RFC 8981** para el tráfico saliente. EUI-64 incrustaba la dirección MAC en los 64 bits bajos, así que el mismo identificador seguía al host por todas las redes a las que se unía — una cookie de rastreo por hardware permanente y visible globalmente. Stable-privacy deriva el identificador de un hash de (prefijo, interfaz, un secreto por host), así que es *estable por red* pero *distinto en cada red*, manteniendo el troubleshooting manejable sin el rastreo.

**7.5**

| Diferencia | Consecuencia |
|---|---|
| Cabecera fija de **40 bytes** vs 20–60 bytes variables; opciones movidas a **cabeceras de extensión** | Los routers parsean una disposición fija — reenvío más rápido, pero los middleboxes suelen descartar cabeceras de extensión desconocidas |
| **Sin checksum de cabecera** en IPv6 | Menos trabajo por salto; hace obligatorio el checksum de transporte (ver 5.5) |
| **Sin fragmentación en el router** — solo el origen puede fragmentar | PMTUD e ICMPv6 tipo 2 pasan a ser críticos; filtrarlos causa agujeros negros |
| **Sin broadcast**; solo multicast + anycast, y ND reemplaza a ARP | Las tormentas de broadcast son estructuralmente imposibles, pero la seguridad ahora depende de filtrar las RA (RA Guard) en lugar del snooping de DHCP |

(También son aceptables: `TTL` renombrado a `Hop Limit`; `Protocol` renombrado a `Next Header`; la incorporación del **Flow Label** de 20 bits, RFC 6437, para hashing ECMP sin inspección profunda.)

**7.6** SLAAC no provee **resolvers DNS ni dominios de búsqueda** — ni servidores NTP, ni ninguna otra opción por host. La carencia se cubre con (a) **DHCPv6 sin estado** (la flag `O` de la RA le dice a los hosts que le pidan opciones a un servidor DHCPv6, no direcciones), o (b) **opciones RDNSS/DNSSL transportadas en la propia RA** (RFC 8106), que tanto `systemd-networkd` como NetworkManager entienden. La flag `M` de la RA, en cambio, dirige a los hosts a DHCPv6 con estado completo, también para direcciones.

**7.7** **Se intenta IPv6 primero** — la selección de dirección por defecto de RFC 6724 ubica a un destino IPv6 global por encima de IPv4, y `getaddrinfo()` devuelve AAAA antes que A. El mecanismo que evita el estancamiento es **Happy Eyeballs** (RFC 6555, revisado como RFC 8305): el cliente inicia la conexión IPv6, y si ningún saludo se completa dentro de un retardo corto (~250 ms según la especificación; los navegadores usan valores similares) corre en paralelo una conexión IPv4 y usa la que tenga éxito primero. Sin eso, un IPv6 roto produce un timeout TCP completo en cada conexión.

---

### Bloque 8 — Diagnóstico

**8.1** De más cerca de la aplicación a más cerca del cable:
1. `Name or service not known` — DNS/NSS, antes de construir ningún paquete hacia el destino.
2. `Network is unreachable` — tabla de enrutamiento, el paquete nunca sale del host.
3. `Connection refused` — volvió un RST: el host es alcanzable, el puerto está cerrado.
4. `Connection timed out` — salieron paquetes y no volvió nada: filtrado o host muerto.

(1 y 2 son fallos *locales*; 3 y 4 requirieron una ida y vuelta, o el intento de una.)

**8.2** El servicio está enlazado solo a la dirección de loopback, así que es inalcanzable desde cualquier otro host por diseño; el RST viene de que la *propia vista del cliente* es respondida por… de hecho, típicamente la pila del host remoto envía el RST porque nada está escuchando en la dirección *externa*. Solución: enlazar el servicio a la dirección externa o al comodín — p. ej. `ListenAddress 0.0.0.0` / `bind-address = 0.0.0.0` / `--host 0.0.0.0`, o mejor, enlazar a la dirección específica de la interfaz. Que `ss -ltn` muestre `127.0.0.1:8080` en lugar de `0.0.0.0:8080` es la evidencia.

**8.3** **DROP** descarta el paquete en silencio y no envía nada, así que el TCP del cliente retransmite su SYN hasta que vence el timeout de conexión → *timeout*. **REJECT** envía un error explícito, así que el cliente falla de inmediato → *refused*. Para TCP, `REJECT --reject-with tcp-reset` envía un **RST de TCP**; el valor por defecto tanto para TCP como para UDP es un **ICMP Destination Unreachable** (`icmp-port-unreachable` por defecto; `icmp6-adm-prohibited` / `icmp-admin-prohibited` son las variantes corteses). Compromiso práctico: DROP oculta el host de un escaneo casual pero multiplica los timeouts del cliente; REJECT falla rápido, que casi siempre es la mejor opción en redes internas.

**8.4** Sockets de doble pila de Linux: cuando `net.ipv6.bindv6only = 0` (el valor por defecto), un socket enlazado al comodín IPv6 `::` también acepta conexiones IPv4, que llegan representadas como **direcciones mapeadas a IPv4** (`::ffff:a.b.c.d`). Así que `[::]:22` por sí solo atiende ambas familias y `ss -ltn` muestra una sola entrada. Poner `net.ipv6.bindv6only = 1` fuerza sockets separados por familia, y entonces ves tanto `0.0.0.0:22` como `[::]:22`. (OpenSSH muestra dos entradas porque deliberadamente abre un socket por familia.)

**8.5** Un resolver cambia a **TCP/53** por su cuenta cuando: (a) una respuesta UDP vuelve con el **bit TC (truncado)** activado porque excedió el límite de payload UDP — 512 bytes clásicamente, o el tamaño de buffer anunciado por EDNS0 — típico con firmas DNSSEC o RRsets grandes; y (b) para **transferencias de zona** (`AXFR`/`IXFR`), que son solo TCP por especificación. También, cada vez más, para transportes de privacidad construidos sobre TCP (DoT/853, DoH/443).

**8.6** Está rota la **resolución de nombres (capa de aplicación/DNS)**; la conectividad IP está bien. Inspeccioná, en orden: `/etc/resolv.conf` (¿hay nameservers, y es un enlace simbólico a `/run/systemd/resolve/stub-resolv.conf`?) y `/etc/nsswitch.conf` (¿está `hosts:` configurado con sensatez?); en una máquina con systemd el comando más informativo es `resolvectl status`, seguido de `resolvectl query example.com`. Después verificá que el resolver mismo responda: `dig @<nameserver> example.com`.

---

### Bloque 9 — Integrador

**9.1** Telnet transmite credenciales y datos de sesión en texto plano, así que cualquiera en el camino puede capturar el login y secuestrar la sesión; un servicio en `0.0.0.0:23` expone eso a toda red alcanzable. Reemplazalo por **SSH (22/tcp)**, deshabilitá y enmascará la unidad socket de telnet o eliminá la entrada de `inetd`/`xinetd`, y verificá con `ss -ltn 'sport = :23'` que ya no está.

**9.2** LDAP está expuesto **sin** su contraparte TLS, así que las consultas al directorio — y, según el método de bind, las credenciales — pueden cruzar la red sin protección. Antes de recomendar un cambio, verificá si el servidor exige **STARTTLS en 389** (`olcSecurity: tls=1` en OpenLDAP, o la URI `ldap` vs `ldaps` en los clientes), porque STARTTLS en 389 es el enfoque moderno y estandarizado, y entonces la ausencia del 636 es correcta y no un defecto. Confirmalo empíricamente: `openssl s_client -connect host:389 -starttls ldap`.

**9.3** (a) **Versión y credenciales** — SNMPv1/v2c autentican con una community string enviada en texto plano, y los valores por defecto `public`/`private` siguen siendo comunes; solo **SNMPv3** provee autenticación y cifrado. (b) **Exposición y amplificación** — un agente SNMP alcanzable desde una red enrutada filtra un inventario detallado del host (interfaces, rutas, procesos, a veces tablas ARP) y UDP/161 es un vector conocido de **reflexión/amplificación**, porque una pequeña petición `GetBulk` produce una respuesta grande hacia un origen falsificado. Recomendá SNMPv3, enlazar a una dirección de gestión, y restringir por origen.

**9.4** Un MTU de 1492 es la firma clásica de **PPPoE** (MTU Ethernet de 1500 menos los 8 bytes de sobrecarga de PPPoE/PPP) — DSL y muchos despliegues de fibra al hogar. Es visible porque TCP negocia la **opción MSS** en el SYN, y los extremos (o un router haciendo MSS clamping) la reducen de 1460 a 1452 en consecuencia; cuando no hay clamping y el ICMP tipo 3/4 está filtrado, obtenés el agujero negro descrito en 6.3. Confirmalo con `tracepath` y `tcpdump -v 'tcp[tcpflags] & tcp-syn != 0'` para leer el MSS anunciado.

**9.5** No necesariamente — **depende de `net.ipv6.bindv6only`** (ver 8.4). Con el valor por defecto `0`, el socket `[::]` también acepta conexiones IPv4 vía direcciones mapeadas a IPv4, así que PostgreSQL es alcanzable sobre IPv4. Con `bindv6only = 1`, o si el `listen_addresses` de PostgreSQL nombra solo direcciones IPv6, no lo es. Verificalo desde afuera y no desde la tabla de sockets: `nc -4 -vz <host> 5432`, y contrastá `listen_addresses` en `postgresql.conf`.

</details>

---

## Fuentes

- Objetivos del examen LPI 102-500, tema 109.1 — <https://www.lpi.org/our-certifications/exam-102-objectives/>
- Objetivos del examen LPI 101-500 — <https://www.lpi.org/our-certifications/exam-101-objectives/>
- RFC 791 — Internet Protocol (IPv4) — <https://www.rfc-editor.org/rfc/rfc791>
- RFC 792 — Internet Control Message Protocol — <https://www.rfc-editor.org/rfc/rfc792>
- RFC 768 — User Datagram Protocol — <https://www.rfc-editor.org/rfc/rfc768>
- RFC 9293 — Transmission Control Protocol (deja obsoleto al RFC 793) — <https://www.rfc-editor.org/rfc/rfc9293>
- RFC 1918 — Address Allocation for Private Internets — <https://www.rfc-editor.org/rfc/rfc1918>
- RFC 3021 — Using 31-Bit Prefixes on IPv4 Point-to-Point Links — <https://www.rfc-editor.org/rfc/rfc3021>
- RFC 3927 — Dynamic Configuration of IPv4 Link-Local Addresses — <https://www.rfc-editor.org/rfc/rfc3927>
- RFC 4632 — Classless Inter-domain Routing (CIDR) — <https://www.rfc-editor.org/rfc/rfc4632>
- RFC 6890 — Special-Purpose IP Address Registries — <https://www.rfc-editor.org/rfc/rfc6890>
- RFC 8200 — Internet Protocol, Version 6 (IPv6) Specification — <https://www.rfc-editor.org/rfc/rfc8200>
- RFC 4291 — IP Version 6 Addressing Architecture — <https://www.rfc-editor.org/rfc/rfc4291>
- RFC 5952 — A Recommendation for IPv6 Address Text Representation — <https://www.rfc-editor.org/rfc/rfc5952>
- RFC 4193 — Unique Local IPv6 Unicast Addresses — <https://www.rfc-editor.org/rfc/rfc4193>
- RFC 4443 — ICMPv6 — <https://www.rfc-editor.org/rfc/rfc4443>
- RFC 4861 — Neighbor Discovery for IP version 6 — <https://www.rfc-editor.org/rfc/rfc4861>
- RFC 4862 — IPv6 Stateless Address Autoconfiguration — <https://www.rfc-editor.org/rfc/rfc4862>
- RFC 4890 — Recommendations for Filtering ICMPv6 Messages in Firewalls — <https://www.rfc-editor.org/rfc/rfc4890>
- RFC 6724 — Default Address Selection for IPv6 — <https://www.rfc-editor.org/rfc/rfc6724>
- RFC 7217 — Semantically Opaque Interface Identifiers (stable privacy) — <https://www.rfc-editor.org/rfc/rfc7217>
- RFC 8981 — Temporary Address Extensions for SLAAC — <https://www.rfc-editor.org/rfc/rfc8981>
- RFC 8305 — Happy Eyeballs Version 2 — <https://www.rfc-editor.org/rfc/rfc8305>
- RFC 8314 — Use of TLS for Email Submission and Access — <https://www.rfc-editor.org/rfc/rfc8314>
- IANA Service Name and Transport Protocol Port Number Registry — <https://www.iana.org/assignments/service-names-port-numbers/service-names-port-numbers.xhtml>
- IANA Protocol Numbers — <https://www.iana.org/assignments/protocol-numbers/protocol-numbers.xhtml>
- `ip-address(8)`, `ip-route(8)` — <https://man7.org/linux/man-pages/man8/ip-address.8.html>
- `ss(8)` — <https://man7.org/linux/man-pages/man8/ss.8.html>
- `services(5)`, `protocols(5)` — <https://man7.org/linux/man-pages/man5/services.5.html>
- `tcpdump(1)`, `pcap-filter(7)` — <https://www.tcpdump.org/manpages/tcpdump.1.html>
- Referencia de sysctl IPv6 del kernel Linux — <https://docs.kernel.org/networking/ip-sysctl.html>