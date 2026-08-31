# 109.3 — Resolución básica de problemas de red

## Ejercicios guiados

> **Correspondencia con los objetivos.** El tema 109 (*Fundamentos de redes*) se examina en **102-500**; el objetivo 109.3 cubre pruebas de alcanzabilidad, inspección de sockets, resolución de nombres y los archivos de configuración que están detrás de todo eso. Listas oficiales de objetivos: [examen 101-500](https://www.lpi.org/our-certifications/exam-101-objectives/) y [examen 102-500](https://www.lpi.org/our-certifications/exam-102-objectives/).

---

## Cómo usar este documento

Cada bloque es una secuencia de comandos que ejecutás de verdad, seguida de preguntas que respondés **antes** de abrir la sección de respuestas plegada al final. Las salidas que se muestran son representativas — tus direcciones, direcciones MAC y latencias van a ser distintas. Lo que sí tiene que coincidir es la *forma* de la salida y el *significado* de cada campo.

### Requisitos previos del laboratorio

Alcanza con un único host Linux con un enlace ascendente funcionando. Dos hosts en el mismo segmento L2 hacen que los ejercicios 2, 7 y 10 sean bastante más ricos.

```bash
# Debian / Ubuntu
sudo apt install -y iproute2 iputils-ping iputils-tracepath traceroute \
                    dnsutils netcat-openbsd net-tools mtr-tiny

# RHEL / Rocky / Fedora
sudo dnf install -y iproute iputils traceroute bind-utils nmap-ncat \
                    net-tools mtr
```

> **Seguridad.** Los ejercicios 8 y 10 rompen deliberadamente el enrutamiento y la resolución de nombres. **No los ejecutes por SSH en una máquina a la que no puedas llegar por consola.** Eliminar una ruta por defecto te tira tu propia sesión. Usá una VM, un contenedor con `NET_ADMIN`, o una máquina con acceso físico/serie.

### La escalera de diagnóstico

Cada ejercicio de abajo es un peldaño de la misma escalera. Recorrela de abajo hacia arriba, y nunca te saltees un peldaño porque "esa parte obviamente funciona":

| Peldaño | Pregunta | Herramienta principal |
|---|---|---|
| 1. Enlace | ¿Está levantado el cable/la radio? ¿El driver ve portadora? | `ip link`, `ip -s link` |
| 2. Dirección | ¿La interfaz tiene dirección y el prefijo correcto? | `ip addr` |
| 3. L2 local | ¿Podemos resolver la MAC del siguiente salto? | `ip neigh`, `ping` |
| 4. Ruta | ¿Qué ruta elige el kernel para este destino? | `ip route get` |
| 5. Camino | ¿Dónde muere el paquete? | `traceroute`, `tracepath`, `mtr` |
| 6. Nombre | ¿El nombre resuelve, y a través de qué fuente? | `getent hosts`, `dig`, `host` |
| 7. Transporte | ¿El puerto está abierto, cerrado o filtrado? | `nc`, `ss` |
| 8. Servicio | ¿Hay algo escuchando, y en qué dirección? | `ss -tulpn` |

---

## Ejercicio 1 — Establecer una línea base con `ip`

**Objetivo.** Leer las tres tablas de estado que expone el kernel — enlaces, direcciones, rutas — y aprender las formas compactas a las que vas a recurrir bajo presión.

1. Listá cada enlace con su estado operativo:

   ```bash
   ip -br link show
   ```

   ```
   lo               UNKNOWN        00:00:00:00:00:00 <LOOPBACK,UP,LOWER_UP>
   enp1s0           UP             52:54:00:12:34:56 <BROADCAST,MULTICAST,UP,LOWER_UP>
   docker0          DOWN           02:42:1f:8c:9a:01 <NO-CARRIER,BROADCAST,MULTICAST,UP>
   ```

2. Ahora la misma vista para las direcciones:

   ```bash
   ip -br -c addr show
   ```

   ```
   lo               UNKNOWN        127.0.0.1/8 ::1/128
   enp1s0           UP             192.168.178.42/24 fe80::5054:ff:fe12:3456/64
   docker0          DOWN           172.17.0.1/16
   ```

3. Mirá el registro completo del enlace ascendente, incluidos los contadores:

   ```bash
   ip -s link show enp1s0
   ```

   ```
   2: enp1s0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc fq_codel state UP mode DEFAULT group default qlen 1000
       link/ether 52:54:00:12:34:56 brd ff:ff:ff:ff:ff:ff
       RX:  bytes packets errors dropped  missed   mcast
       412398821 1204331      0       0       0    18422
       TX:  bytes packets errors dropped carrier collsns
        88213394  642119      0       0       0        0
   ```

4. Imprimí la tabla de enrutamiento principal:

   ```bash
   ip route show
   ```

   ```
   default via 192.168.178.1 dev enp1s0 proto dhcp src 192.168.178.42 metric 100
   172.17.0.0/16 dev docker0 proto kernel scope link src 172.17.0.1 linkdown
   192.168.178.0/24 dev enp1s0 proto kernel scope link src 192.168.178.42 metric 100
   ```

5. Preguntale al kernel qué ruta usaría *realmente* — este es el comando de enrutamiento más útil del objetivo:

   ```bash
   ip route get 1.1.1.1
   ip route get 192.168.178.99
   ```

   ```
   1.1.1.1 via 192.168.178.1 dev enp1s0 src 192.168.178.42 uid 1000
       cache
   192.168.178.99 dev enp1s0 src 192.168.178.42 uid 1000
       cache
   ```

**Comprobá tu comprensión**

- **P1.1** En el paso 1, `docker0` muestra estado `DOWN` y sin embargo sus banderas incluyen `UP`. Explicá la contradicción.
- **P1.2** En el paso 3, ¿qué significa `LOWER_UP`, y en qué se diferencia de la bandera `UP`?
- **P1.3** La ruta a `192.168.178.0/24` tiene `proto kernel scope link`. ¿Quién la creó, y qué afirma `scope link` sobre esos destinos?
- **P1.4** `ip route get 192.168.178.99` no imprimió ningún `via`. ¿Qué te dice la ausencia de `via` sobre cómo se va a entregar el paquete?
- **P1.5** ¿Por qué `ip route get` es más confiable que leer `ip route show` a ojo cuando un host tiene varias interfaces?

---

## Ejercicio 2 — Capa 2: la tabla de vecinos (ARP/NDP)

**Objetivo.** Demostrar que la alcanzabilidad L3 en una subred local es en realidad un problema de L2, y aprender a leer los estados de vecino.

1. Volcá la caché de vecinos actual:

   ```bash
   ip neigh show
   ```

   ```
   192.168.178.1 dev enp1s0 lladdr 3c:a6:2f:0b:11:22 REACHABLE
   192.168.178.77 dev enp1s0  FAILED
   fe80::3ea6:2fff:fe0b:1122 dev enp1s0 lladdr 3c:a6:2f:0b:11:22 router STALE
   ```

2. Vaciá la entrada de tu gateway por defecto, y después forzá que se reconstruya:

   ```bash
   GW=$(ip -4 route show default | awk '{print $3}')
   echo "gateway is $GW"
   sudo ip neigh del "$GW" dev enp1s0
   ip neigh show "$GW"          # expect: nothing, or INCOMPLETE
   ping -c 1 "$GW" >/dev/null
   ip neigh show "$GW"
   ```

   ```
   192.168.178.1 dev enp1s0 lladdr 3c:a6:2f:0b:11:22 REACHABLE
   ```

3. Hacé ping a una dirección dentro de tu subred que con seguridad no existe:

   ```bash
   ping -c 2 -W 1 192.168.178.253
   ```

   ```
   PING 192.168.178.253 (192.168.178.253) 56(84) bytes of data.
   From 192.168.178.42 icmp_seq=1 Destination Host Unreachable
   From 192.168.178.42 icmp_seq=2 Destination Host Unreachable

   --- 192.168.178.253 ping statistics ---
   2 packets transmitted, 0 received, +2 errors, 100% packet loss, time 1029ms
   pipe 2
   ```

4. Inspeccioná lo que eso dejó atrás, y después compará con la vista heredada:

   ```bash
   ip neigh show 192.168.178.253
   arp -n | head
   ```

   ```
   192.168.178.253 dev enp1s0  FAILED
   ```

**Comprobá tu comprensión**

- **P2.1** En el paso 3, el mensaje `Destination Host Unreachable` vino *de tu propia dirección*, `192.168.178.42`. ¿Por qué el host local emite un error ICMP sobre un destino que nunca alcanzó?
- **P2.2** Contrastá eso con hacer ping a una dirección fuera de la subred que sea inalcanzable. ¿Qué host generaría el error ICMP entonces, y qué imprimiría `ping`?
- **P2.3** ¿Cuál es la diferencia práctica entre los estados de vecino `REACHABLE`, `STALE` y `FAILED`? ¿`STALE` es una falla?
- **P2.4** La entrada IPv6 es una dirección link-local `fe80::` marcada como `router`. ¿Qué protocolo la pobló, y por qué no es ARP?
- **P2.5** Un host tiene la dirección correcta, la ruta correcta, y `ip neigh` muestra el gateway como `INCOMPLETE` y nunca sale de ese estado. Nombrá tres causas plausibles.

---

## Ejercicio 3 — Alcanzabilidad de capa 3 con `ping` / `ping6`

**Objetivo.** Leer cada campo que imprime `ping`, y usar sus opciones como instrumentos y no como un oráculo de sí/no.

1. Ping de referencia al gateway, y después leé el resumen con atención:

   ```bash
   ping -c 4 "$GW"
   ```

   ```
   PING 192.168.178.1 (192.168.178.1) 56(84) bytes of data.
   64 bytes from 192.168.178.1: icmp_seq=1 ttl=64 time=0.412 ms
   64 bytes from 192.168.178.1: icmp_seq=2 ttl=64 time=0.398 ms
   64 bytes from 192.168.178.1: icmp_seq=3 ttl=64 time=0.489 ms
   64 bytes from 192.168.178.1: icmp_seq=4 ttl=64 time=0.451 ms

   --- 192.168.178.1 ping statistics ---
   4 packets transmitted, 4 received, 0% packet loss, time 3053ms
   rtt min/avg/max/mdev = 0.398/0.437/0.489/0.035 ms
   ```

2. Hacé ping a un host público y compará el TTL:

   ```bash
   ping -c 3 1.1.1.1
   ```

   ```
   64 bytes from 1.1.1.1: icmp_seq=1 ttl=57 time=12.8 ms
   ```

3. Fijá el ping a una interfaz de origen específica y a una dirección de origen específica:

   ```bash
   ping -c 2 -I enp1s0 1.1.1.1
   ping -c 2 -I 192.168.178.42 1.1.1.1
   ```

4. Sondeá la MTU del camino prohibiendo la fragmentación:

   ```bash
   ping -c 1 -M do -s 1472 1.1.1.1     # 1472 + 8 + 20 = 1500
   ping -c 1 -M do -s 1473 1.1.1.1
   ```

   ```
   PING 1.1.1.1 (1.1.1.1) 1472(1500) bytes of data.
   1480 bytes from 1.1.1.1: icmp_seq=1 ttl=57 time=13.1 ms

   PING 1.1.1.1 (1.1.1.1) 1473(1501) bytes of data.
   ping: local error: message too long, mtu=1500
   ```

5. Ahora IPv6, incluido un destino link-local que necesita un índice de zona:

   ```bash
   ping -6 -c 3 2606:4700:4700::1111
   ping -6 -c 2 fe80::3ea6:2fff:fe0b:1122%enp1s0
   ```

6. Prueba de carga sin flood y control del intervalo (se requiere root para intervalos por debajo de 0,2 s):

   ```bash
   sudo ping -c 100 -i 0.05 -q "$GW"
   ```

   ```
   --- 192.168.178.1 ping statistics ---
   100 packets transmitted, 100 received, 0% packet loss, time 5012ms
   rtt min/avg/max/mdev = 0.331/0.442/1.902/0.161 ms
   ```

**Comprobá tu comprensión**

- **P3.1** El encabezado dice `56(84) bytes`. Descomponé esos dos números.
- **P3.2** El gateway respondió con `ttl=64`, y `1.1.1.1` con `ttl=57`. ¿Qué inferís, y cuál es el razonamiento estándar?
- **P3.3** ¿Qué mide exactamente `mdev`, y por qué un `avg` bajo con un `mdev` alto merece que lo investigues?
- **P3.4** En el paso 4, el sondeo de 1473 bytes falló con `local error: message too long`. ¿Qué host produjo ese error? ¿En qué se diferenciaría la salida si el cuello de botella de MTU estuviera a tres saltos de distancia en lugar de en tu propia NIC?
- **P3.5** ¿Por qué `ping fe80::…` requiere el sufijo `%enp1s0` mientras que `ping 2606:4700:4700::1111` no?
- **P3.6** Un colega concluye "el servidor está caído" porque el echo ICMP expira, y sin embargo `https://` a ese servidor funciona. Explicá la falla en la conclusión.

---

## Ejercicio 4 — Dónde muere el paquete: `traceroute`, `tracepath`, `mtr`

**Objetivo.** Distinguir las tres herramientas por transporte, requisito de privilegios y qué es lo que miden.

1. Ejecutá `tracepath` (sin privilegios, UDP, descubre la PMTU):

   ```bash
   tracepath -n 1.1.1.1
   ```

   ```
    1?: [LOCALHOST]                      pmtu 1500
    1:  192.168.178.1                                         0.503ms
    1:  192.168.178.1                                         0.421ms
    2:  100.64.0.1                                            8.114ms
    3:  no reply
    4:  62.53.16.9                                           11.902ms asymm  5
    5:  1.1.1.1                                              12.744ms reached
        Resume: pmtu 1500 hops 5 back 5
   ```

2. Ejecutá el `traceroute` clásico (por defecto UDP a puertos altos):

   ```bash
   traceroute -n 1.1.1.1
   ```

   ```
   traceroute to 1.1.1.1 (1.1.1.1), 30 hops max, 60 byte packets
    1  192.168.178.1  0.482 ms  0.463 ms  0.451 ms
    2  100.64.0.1  8.221 ms  8.905 ms  9.114 ms
    3  * * *
    4  62.53.16.9  11.9 ms  12.1 ms  12.0 ms
    5  1.1.1.1  12.7 ms  12.6 ms  12.8 ms
   ```

3. Cambiá los transportes de sondeo y compará qué saltos responden:

   ```bash
   sudo traceroute -n -I 1.1.1.1      # ICMP echo probes
   sudo traceroute -n -T -p 443 1.1.1.1   # TCP SYN probes to 443
   ```

4. Ejecutá un monitor continuo del camino para separar la pérdida de la latencia:

   ```bash
   mtr -n --report --report-cycles 20 1.1.1.1
   ```

   ```
   Start: 2026-08-27T10:14:22+0200
   HOST: workstation           Loss%   Snt   Last   Avg  Best  Wrst StDev
     1.|-- 192.168.178.1        0.0%    20    0.4   0.5   0.4   0.9   0.1
     2.|-- 100.64.0.1           0.0%    20    8.2   8.6   7.9  10.1   0.6
     3.|-- ???                 100.0%    20    0.0   0.0   0.0   0.0   0.0
     4.|-- 62.53.16.9           0.0%    20   11.9  12.1  11.7  13.4   0.4
     5.|-- 1.1.1.1              0.0%    20   12.7  12.8  12.5  13.9   0.3
   ```

5. Equivalentes IPv6:

   ```bash
   tracepath6 -n 2606:4700:4700::1111
   traceroute6 -n 2606:4700:4700::1111
   ```

**Comprobá tu comprensión**

- **P4.1** Explicá el mecanismo común a las tres herramientas: ¿cómo revela los routers intermedios el incremento del TTL de IP?
- **P4.2** El salto 3 muestra `* * *` en `traceroute` y 100 % de pérdida en `mtr`, y sin embargo los saltos 4 y 5 responden normalmente. ¿Se está perdiendo tráfico? Justificá.
- **P4.3** ¿Por qué `traceroute -T` requiere root mientras que el `traceroute` común y `tracepath` no?
- **P4.4** `tracepath` imprimió `pmtu 1500` y `asymm 5` en el salto 4. ¿Qué te dice cada uno?
- **P4.5** Tenés que demostrar que un firewall entre vos y un servidor web permite el puerto 443 pero bloquea el puerto 8080, y solo podés usar herramientas de este objetivo. ¿Qué comandos exactos ejecutás?
- **P4.6** Ante una queja de un usuario del tipo "la conexión está lenta y se corta de vez en cuando", ¿a cuál de las tres herramientas recurrís primero, y por qué?

---

## Ejercicio 5 — Resolución de nombres: NSS, `/etc/hosts`, `/etc/resolv.conf`

**Objetivo.** Entender que "resolver un nombre" significa dos cosas distintas según qué herramienta pregunte, y aprender a probar cada camino por separado.

1. Inspeccioná el orden del resolutor y la configuración del resolutor:

   ```bash
   grep -E '^hosts:' /etc/nsswitch.conf
   cat /etc/resolv.conf
   ls -l /etc/resolv.conf
   ```

   ```
   hosts:          files mdns4_minimal [NOTFOUND=return] dns

   # Generated by NetworkManager
   search home.arpa
   nameserver 192.168.178.1
   options edns0
   ```

2. Agregá una entrada deliberadamente falsa a `/etc/hosts` y probá tres resolutores distintos:

   ```bash
   echo '203.0.113.99  lab.example.test' | sudo tee -a /etc/hosts
   getent hosts lab.example.test
   ping -c 1 lab.example.test
   dig +short lab.example.test
   host lab.example.test
   ```

   ```
   203.0.113.99    lab.example.test

   PING lab.example.test (203.0.113.99) 56(84) bytes of data.

   (dig prints nothing)
   Host lab.example.test not found: 3(NXDOMAIN)
   ```

3. Consultá DNS directamente y leé el encabezado:

   ```bash
   dig www.lpi.org A
   ```

   ```
   ; <<>> DiG 9.18.24-1-Debian <<>> www.lpi.org A
   ;; global options: +cmd
   ;; Got answer:
   ;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 51224
   ;; flags: qr rd ra; QUERY: 1, ANSWER: 1, AUTHORITY: 0, ADDITIONAL: 1

   ;; QUESTION SECTION:
   ;www.lpi.org.                   IN      A

   ;; ANSWER SECTION:
   www.lpi.org.            300     IN      A       208.94.116.9

   ;; Query time: 24 msec
   ;; SERVER: 192.168.178.1#53(192.168.178.1) (UDP)
   ;; WHEN: Thu Aug 27 10:22:41 CEST 2026
   ;; MSG SIZE  rcvd: 56
   ```

4. Salteá el resolutor configurado para aislar una falla del lado del servidor:

   ```bash
   dig @1.1.1.1 www.lpi.org +short
   dig @9.9.9.9 www.lpi.org +short
   dig @192.168.178.1 www.lpi.org +short
   ```

5. Búsquedas inversas y tipos de registro:

   ```bash
   dig -x 208.94.116.9 +short
   dig lpi.org MX +short
   dig lpi.org NS +short
   dig lpi.org SOA +short
   host -t MX lpi.org
   ```

6. Observá el dominio de `search` y el comportamiento de `ndots`:

   ```bash
   dig +search +short www          # tries www.home.arpa.
   dig +noall +answer www.lpi.org.  # note the trailing dot: no search applied
   ```

7. Limpieza:

   ```bash
   sudo sed -i '/lab.example.test/d' /etc/hosts
   getent hosts lab.example.test; echo "exit=$?"
   ```

**Comprobá tu comprensión**

- **P5.1** En el paso 2, `ping` y `getent` encontraron el host pero `dig` y `host` no. Explicá con precisión por qué, en términos de qué biblioteca usa cada herramienta.
- **P5.2** Dado `hosts: files mdns4_minimal [NOTFOUND=return] dns`, ¿qué pasa con una consulta por `printer.local` que mDNS responde con NOTFOUND? ¿Se consultaría igual `dns`?
- **P5.3** Distinguí `NXDOMAIN`, `SERVFAIL` y `REFUSED` en un encabezado de `dig`. ¿Cuál apunta a tu *propio* resolutor y no a la zona?
- **P5.4** En el encabezado del paso 3, ¿qué significan las banderas `qr`, `rd` y `ra`? ¿Cuál faltaría si el servidor no ofreciera recursión?
- **P5.5** `dig @1.1.1.1 example.com` funciona pero `dig example.com` expira. ¿Dónde está la falla, y cuál es tu siguiente comando?
- **P5.6** En un host con systemd, `/etc/resolv.conf` es un enlace simbólico a `/run/systemd/resolve/stub-resolv.conf` que contiene `nameserver 127.0.0.53`. ¿Por qué editar ese archivo rara vez arregla algo, y qué comando muestra los servidores upstream *reales*?
- **P5.7** La biblioteca del resolutor ignora toda línea `nameserver` posterior a la tercera. ¿Qué consecuencia tiene eso para alguien que "agrega más servidores DNS por las dudas"?

---

## Ejercicio 6 — Sockets y escuchas: `ss`, `netstat`, `/etc/services`

**Objetivo.** Responder "¿hay algo escuchando, en qué dirección, propiedad de qué proceso?" sin adivinar.

1. Listá cada socket TCP y UDP en escucha con su proceso propietario:

   ```bash
   sudo ss -tulpn
   ```

   ```
   Netid State  Recv-Q Send-Q Local Address:Port Peer Address:Port Process
   udp   UNCONN 0      0      127.0.0.53%lo:53        0.0.0.0:*    users:(("systemd-resolve",pid=612,fd=14))
   udp   UNCONN 0      0      0.0.0.0:68              0.0.0.0:*    users:(("dhclient",pid=744,fd=6))
   tcp   LISTEN 0      4096   127.0.0.53%lo:53        0.0.0.0:*    users:(("systemd-resolve",pid=612,fd=15))
   tcp   LISTEN 0      128            0.0.0.0:22      0.0.0.0:*    users:(("sshd",pid=921,fd=3))
   tcp   LISTEN 0      511          127.0.0.1:8080    0.0.0.0:*    users:(("gunicorn",pid=1503,fd=5))
   tcp   LISTEN 0      128               [::]:22         [::]:*    users:(("sshd",pid=921,fd=4))
   ```

2. Mirá las conexiones establecidas y el estado por socket:

   ```bash
   ss -tan state established
   ss -tanp '( dport = :443 or sport = :443 )'
   ss -s
   ```

   ```
   Total: 431
   TCP:   18 (estab 6, closed 4, orphaned 0, timewait 3)

   Transport Total     IP        IPv6
   RAW       1         0         1
   UDP       6         4         2
   TCP       14        11        3
   INET      21        15        6
   FRAG      0         0         0
   ```

3. Inspeccioná los temporizadores y el estado de congestión de una conexión viva:

   ```bash
   ss -tio state established '( dport = :443 )'
   ```

   ```
   ESTAB 0 0 192.168.178.42:51422 208.94.116.9:443 timer:(keepalive,18min,0)
        cubic wscale:7,7 rto:220 rtt:18.4/2.1 mss:1448 cwnd:10 bytes_sent:4211 bytes_acked:4211 ...
   ```

4. Traducí puertos a nombres de servicio mediante `/etc/services`:

   ```bash
   grep -E '^(ssh|https|domain)\s' /etc/services
   getent services 22/tcp
   getent services https
   ```

   ```
   ssh             22/tcp
   domain          53/tcp
   domain          53/udp
   https           443/tcp

   ssh                   22/tcp
   https                 443/tcp
   ```

5. Compará con la vista obsoleta de `net-tools`:

   ```bash
   sudo netstat -tulpn
   sudo netstat -i
   netstat -rn
   ```

**Comprobá tu comprensión**

- **P6.1** `sshd` escucha en `0.0.0.0:22` mientras que `gunicorn` escucha en `127.0.0.1:8080`. Un cliente remoto no puede alcanzar el puerto 8080 y el firewall está vacío. Explicá, e indicá la solución.
- **P6.2** ¿Qué muestra la columna `Send-Q` para un socket en estado `LISTEN`, y cómo cambia su significado para un socket `ESTAB`?
- **P6.3** `ss -tulpn` muestra `[::]:22` pero, en algunos sistemas, ningún `0.0.0.0:22` aparte. ¿Qué parámetro del kernel explica que un solo socket sirva a ambas familias?
- **P6.4** ¿`/etc/services` controla a qué puerto se enlaza un demonio? Justificá tu respuesta con lo que pasó en el paso 4.
- **P6.5** Dá dos razones concretas para preferir `ss` sobre `netstat` en un host de producción cargado.
- **P6.6** Un socket queda atascado en `TIME-WAIT`. ¿Qué lado de la conexión cerró primero, y por qué existe siquiera ese estado?

---

## Ejercicio 7 — Sondeo a nivel de transporte con `netcat`

**Objetivo.** Separar *cerrado* de *filtrado*, y probar un servicio sin su cliente.

1. Probá un puerto abierto, uno cerrado y (si hay disponible) uno filtrado:

   ```bash
   nc -vz -w 3 www.lpi.org 443
   nc -vz -w 3 www.lpi.org 4242
   nc -vz -w 3 192.0.2.1 443
   ```

   ```
   Connection to www.lpi.org (208.94.116.9) 443 port [tcp/https] succeeded!

   nc: connect to www.lpi.org (208.94.116.9) port 4242 (tcp) failed: Connection refused

   nc: connect to 192.0.2.1 port 443 (tcp) timed out: Operation now in progress
   ```

2. Levantá un listener local y conectate a él desde una segunda terminal:

   ```bash
   # terminal A
   nc -l -p 4242 -k          # OpenBSD nc: -l 4242 also works; -k keeps listening

   # terminal B
   ss -tlnp '( sport = :4242 )'
   printf 'hello from B\n' | nc -w 2 127.0.0.1 4242
   ```

3. Hablá un protocolo real a mano:

   ```bash
   printf 'GET / HTTP/1.1\r\nHost: www.lpi.org\r\nConnection: close\r\n\r\n' \
     | nc -w 5 www.lpi.org 80 | head -n 8
   ```

   ```
   HTTP/1.1 301 Moved Permanently
   Server: nginx
   Date: Thu, 27 Aug 2026 08:31:07 GMT
   Content-Type: text/html
   Content-Length: 162
   Connection: close
   Location: https://www.lpi.org/
   ```

4. Escaneá un rango pequeño de puertos y probá UDP:

   ```bash
   nc -vz -w 1 127.0.0.1 20-25 2>&1 | grep -v refused
   nc -vzu -w 2 "$GW" 53
   ```

**Comprobá tu comprensión**

- **P7.1** Distinguí los tres resultados del paso 1 a nivel de paquete: ¿qué banderas TCP (o ausencia de paquetes) producen *succeeded*, *Connection refused* y *timed out*?
- **P7.2** ¿Por qué *Connection refused* es en realidad una buena noticia cuando estás diagnosticando un firewall?
- **P7.3** ¿Por qué `nc -zu` (UDP) es una prueba de abierto/cerrado poco confiable, mientras que `nc -z` (TCP) sí es confiable?
- **P7.4** En el paso 3, ¿por qué `\r\n` es obligatorio en lugar de un `\n` simple, y por qué la petición incluye una cabecera `Host:`?
- **P7.5** Podés hacer `ping` a un servidor y `nc -z` a su puerto 22 funciona, pero `ssh` se cuelga después del banner. ¿Qué peldaño de la escalera queda ahora bajo sospecha, y qué probarías?

---

## Ejercicio 8 — Romper y reparar: rutas, direcciones, DNS

> **Se requiere acceso por consola.** No hagas esto por SSH.

**Objetivo.** Producir a propósito cada firma clásica de falla para reconocerla después.

1. Registrá el estado actual para poder restaurarlo:

   ```bash
   ip addr show enp1s0 > /tmp/before-addr.txt
   ip route show > /tmp/before-route.txt
   sudo cp /etc/resolv.conf /tmp/resolv.conf.bak
   cat /tmp/before-route.txt
   ```

2. **Rompé la ruta por defecto.** Eliminala y observá la diferencia entre fallas locales y remotas:

   ```bash
   sudo ip route del default
   ping -c 1 -W 2 "$GW"      # still works: on-link
   ping -c 1 -W 2 1.1.1.1
   ip route get 1.1.1.1
   ```

   ```
   ping: connect: Network is unreachable
   RTNETLINK answers: Network is unreachable
   ```

3. Restaurala:

   ```bash
   sudo ip route add default via "$GW" dev enp1s0
   ping -c 1 1.1.1.1 && echo OK
   ```

4. **Rompé la longitud del prefijo.** Reemplazá el /24 por un /28 y mirá quién queda inalcanzable:

   ```bash
   sudo ip addr add 192.168.178.42/28 dev enp1s0
   sudo ip addr del 192.168.178.42/24 dev enp1s0
   ip route get 192.168.178.1
   ip route get 192.168.178.200
   ```

5. Restaurá el prefijo correcto:

   ```bash
   sudo ip addr add 192.168.178.42/24 dev enp1s0
   sudo ip addr del 192.168.178.42/28 dev enp1s0
   sudo ip route add default via "$GW" dev enp1s0 2>/dev/null
   ip -br addr show enp1s0
   ```

6. **Rompé solo el DNS.** Apuntá el resolutor a un agujero negro y caracterizá el síntoma:

   ```bash
   printf 'nameserver 203.0.113.53\noptions timeout:1 attempts:1\n' \
     | sudo tee /etc/resolv.conf >/dev/null
   time getent hosts www.lpi.org; echo "exit=$?"
   ping -c 1 1.1.1.1 && echo "raw IP still fine"
   dig @1.1.1.1 www.lpi.org +short
   ```

7. Restaurá el DNS y verificá la escalera completa:

   ```bash
   sudo cp /tmp/resolv.conf.bak /etc/resolv.conf
   getent hosts www.lpi.org
   diff <(ip route show) /tmp/before-route.txt && echo "routes restored"
   ```

**Comprobá tu comprensión**

- **P8.1** En el paso 2, `ping 1.1.1.1` falló con `Network is unreachable` en lugar de expirar. ¿Qué componente produjo ese mensaje, y en qué punto del camino de envío?
- **P8.2** Contrastá `Network is unreachable`, `Destination Host Unreachable` y un timeout silencioso: ¿qué capa está rota en cada caso?
- **P8.3** En el paso 4, con una máscara /28, `192.168.178.200` ya no está on-link. Rastreá qué hace el kernel con un paquete dirigido a esa dirección, suponiendo que existe una ruta por defecto.
- **P8.4** Explicá el perfil exacto de síntomas del paso 6 tal como lo reportaría un usuario, y por qué el hecho de que `ping 1.1.1.1` funcione es el discriminador clave.
- **P8.5** ¿Por qué el ejercicio agregó la dirección nueva *antes* de eliminar la vieja en el paso 4, y por qué el orden importa más en un host remoto?
- **P8.6** Todos los cambios de arriba se pierden al reiniciar. Nombrá el mecanismo de persistencia en un sistema con NetworkManager y en un sistema Debian con `ifupdown`.

---

## Ejercicio 9 — Identidad del host: `hostname`, `/etc/hosts`, `/etc/hostname`

**Objetivo.** Entender los tres nombres distintos que lleva un host y cómo se resuelve cada uno.

1. Consultá la identidad actual:

   ```bash
   hostname
   hostname -s
   hostname -f
   hostname -I
   cat /etc/hostname
   ```

   ```
   workstation
   workstation
   workstation.home.arpa
   192.168.178.42 fe80::5054:ff:fe12:3456
   workstation
   ```

2. Inspeccioná el mapeo de loopback que hace que `hostname -f` funcione:

   ```bash
   grep -n workstation /etc/hosts
   getent hosts workstation
   ```

   ```
   2:127.0.1.1      workstation.home.arpa workstation
   127.0.1.1       workstation.home.arpa workstation
   ```

3. Cambiá el hostname transitorio y observá qué cambió y qué no:

   ```bash
   sudo hostname lab-node
   hostname
   cat /etc/hostname
   hostname -f
   ```

4. Restauralo, y fijalo de forma persistente al estilo systemd:

   ```bash
   sudo hostname "$(cat /etc/hostname)"
   hostnamectl status
   # persistent change would be:  sudo hostnamectl set-hostname workstation
   ```

**Comprobá tu comprensión**

- **P9.1** ¿Por qué `hostname -f` falla con `Name or service not known` en un host cuyo `/etc/hosts` carece de un mapeo para su propio nombre, incluso cuando el DNS está sano?
- **P9.2** Debian mapea el hostname a `127.0.1.1` y no a `127.0.0.1`. ¿Qué problema evita esa convención?
- **P9.3** ¿Cuál de estos sobrevive a un reinicio: `hostname lab-node`, editar `/etc/hostname`, `hostnamectl set-hostname lab-node`?
- **P9.4** `hostname -I` e `ip -br addr` no coinciden — el primero omite una dirección que sí ves en el segundo. Dá una razón plausible.

---

## Ejercicio 10 — Simulacro de triaje completo

**Objetivo.** Recorrer la escalera de punta a punta frente a una falla desconocida, produciendo evidencia en cada peldaño.

1. Tomá una instantánea de cada peldaño de una sola vez:

   ```bash
   {
     echo "=== links ==="   ; ip -br link
     echo "=== addrs ==="   ; ip -br addr
     echo "=== routes ==="  ; ip route show
     echo "=== neigh ==="   ; ip neigh show
     echo "=== resolv ==="  ; cat /etc/resolv.conf
     echo "=== nsswitch ==="; grep '^hosts:' /etc/nsswitch.conf
     echo "=== listeners ==="; ss -tulpn
   } > /tmp/net-snapshot.txt
   wc -l /tmp/net-snapshot.txt
   ```

2. Recorré la escalera contra un destino de tu elección, deteniéndote en la primera falla:

   ```bash
   TARGET=www.lpi.org
   ip link show enp1s0 | grep -o 'LOWER_UP'           # rung 1
   ip -4 -br addr show enp1s0                          # rung 2
   ping -c 2 -W 1 "$GW"                                # rung 3
   ip route get 1.1.1.1                                # rung 4
   ping -c 2 -W 1 1.1.1.1                              # rung 4
   tracepath -n 1.1.1.1 | tail -3                      # rung 5
   getent hosts "$TARGET"                              # rung 6
   dig @1.1.1.1 +short "$TARGET"                       # rung 6
   nc -vz -w 3 "$TARGET" 443                           # rung 7
   ```

3. Registrá el hallazgo en una forma sobre la que otro ingeniero pueda actuar:

   ```
   Symptom:   HTTPS to www.lpi.org fails from workstation
   Rung 1-4:  OK   (LOWER_UP, 192.168.178.42/24, gw REACHABLE, 1.1.1.1 rtt 12.8 ms)
   Rung 5:    OK   (tracepath reaches, pmtu 1500)
   Rung 6:    FAIL (getent: no result; dig @1.1.1.1 returns 208.94.116.9)
   Rung 7:    OK   (nc -z 208.94.116.9 443 succeeded)
   Conclusion: local resolver path broken, upstream DNS and transport healthy
   Next:      inspect /etc/resolv.conf and resolvectl status
   ```

**Comprobá tu comprensión**

- **P10.1** ¿Por qué el simulacro prueba `ping 1.1.1.1` antes que `getent hosts www.lpi.org`, y no al revés?
- **P10.2** En el informe de ejemplo, el peldaño 6 falla pero el 7 tiene éxito. ¿Cómo se pudo probar siquiera el peldaño 7, dado que el nombre no resolvió?
- **P10.3** Dos hosts en el mismo switch no pueden alcanzarse; ambos muestran `LOWER_UP`, ambos tienen direcciones, `ip neigh` muestra `FAILED` en ambas direcciones. Nombrá las dos causas más probables y un comando que discrimine entre ellas.
- **P10.4** Una aplicación web se traba de forma intermitente en subidas grandes pero las peticiones chicas andan bien, y ping y traceroute están limpios. ¿Qué peldaño está implicado, y qué comando exacto de este documento produce la evidencia?
- **P10.5** ¿Por qué capturar `/tmp/net-snapshot.txt` *antes* de cambiar nada es un hábito profesional y no burocracia?

---

<details>
<summary><strong>Respuestas</strong> — abrí solo después de intentar cada bloque</summary>

### Ejercicio 1

**R1.1** Las dos palabras describen cosas distintas. La bandera `UP` es el estado *administrativo*: el operador (o el sistema de init) le pidió al kernel que habilitara la interfaz — `IFF_UP` está activo. La palabra `DOWN` en `ip -br link` es el estado *operativo* (`operstate`), que el driver deriva de la detección de portadora. `docker0` está administrativamente habilitada pero tiene `NO-CARRIER` porque no hay ningún contenedor conectado al bridge, así que ningún puerto está reenviando. El mismo patrón aparece en una NIC física que está `UP` con el cable desenchufado.

**R1.2** `UP` es `IFF_UP`, que activa `ip link set dev X up`. `LOWER_UP` es `IFF_LOWER_UP`, y significa que el driver reporta portadora a nivel físico — pulsos de enlace en cobre, asociación en Wi-Fi, un par conectado en un veth. Diagnósticamente: `UP` sin `LOWER_UP` significa "yo lo pedí, el cable no está de acuerdo" — un problema de cable, puerto, o dúplex/autonegociación, no un problema de configuración.

**R1.3** `proto kernel` significa que el kernel la instaló automáticamente en el momento en que se configuró una dirección con prefijo en la interfaz; no la creó ningún demonio de enrutamiento ni administrador. `scope link` afirma que todo destino dentro de `192.168.178.0/24` es alcanzable *directamente en este segmento L2* — el kernel va a hacer ARP/ND por el destino mismo en lugar de entregarle la trama a un router. Borrar esta ruta a mano es una de las formas más rápidas de romper una subred.

**R1.4** Que no haya `via` significa que no hay gateway de siguiente salto: el destino está on-link. El kernel va a resolver por ARP la MAC propia de `192.168.178.99` y poner esa MAC en el campo de destino Ethernet. Si `via` estuviera presente, la trama llevaría la MAC *del gateway* mientras que la cabecera IP seguiría llevando el destino final.

**R1.5** `ip route show` imprime reglas; `ip route get` imprime la *decisión*. En un host multi-homed la decisión depende de la coincidencia de prefijo más largo, la métrica, las reglas de enrutamiento por políticas (`ip rule`) y múltiples tablas de enrutamiento — `ip route show` sin `table all` muestra solo la tabla main y esconde todo eso. `ip route get` además revela la **dirección de origen** que va a seleccionar el kernel, que es el campo más frecuentemente responsable de "el paquete sale pero no vuelve nada".

### Ejercicio 2

**R2.1** El destino está on-link, así que el kernel tiene que aprender su MAC antes de poder armar una trama. Difundió peticiones ARP, nadie respondió, la entrada de vecino pasó a `FAILED`, y la pila IP *local* generó `ICMP Destination Unreachable / Host Unreachable` para su propio paquete encolado y se lo entregó hacia arriba a `ping`. Ningún paquete salió jamás del host más allá de los broadcasts ARP. Por eso la dirección de origen del error es la tuya.

**R2.2** Para un destino fuera de la subred el host local tiene un siguiente salto válido, así que el paquete se reenvía. El error ICMP, si lo hay, lo genera un *router upstream* — típicamente el último router que tiene ruta a la red pero no recibe respuesta ARP del host, o uno que directamente no tiene ruta (`Destination Net Unreachable`). `ping` imprime `From <router-ip> icmp_seq=N Destination Host Unreachable`, y la dirección es la del router, no la tuya. Si en cambio un firewall descarta el paquete en silencio, no obtenés error alguno — solo `100% packet loss` sin conteo de `+errors`.

**R2.3**
- `REACHABLE` — el mapeo se confirmó hace poco (por defecto ~30 s de base, aleatorizado); el tráfico fluye sin más sondeos.
- `STALE` — la entrada sigue en caché y *se va a usar*, pero venció el temporizador de confirmación. El kernel envía el siguiente paquete con esa MAC y simultáneamente inicia un sondeo unicast (`DELAY` → `PROBE`). **`STALE` no es una falla**; es el estado de reposo normal de un vecino tranquilo. Tratarlo como falla es un malentendido común.
- `FAILED` — se intentó la resolución y no llegó respuesta. Esto *sí* es una falla: el vecino está ausente, en otra VLAN, o ARP/ND está siendo filtrado.

**R2.4** IPv6 no usa ARP. Neighbour Discovery (NDP, RFC 4861) puebla esa entrada usando mensajes ICMPv6 Neighbor Solicitation / Neighbor Advertisement enviados a direcciones multicast de nodo solicitado. La palabra clave `router` significa que el vecino se anunció como router (mediante Router Advertisement), que es como el host aprendió su gateway por defecto — notá que el gateway se identifica por su dirección **link-local**, que es la razón por la que las rutas por defecto de IPv6 apuntan a `fe80::…` y no a una dirección global.

**R2.5** Tres cualesquiera de estas:
1. El gateway está en una VLAN distinta de la que otorga el puerto del switch (desajuste de VLAN nativa/de acceso).
2. Longitud de prefijo incorrecta en la dirección local, de modo que el "gateway" en realidad no está on-link y el ARP sale a un segmento donde nadie es dueño de esa dirección.
3. Un puerto de switch en estado de bloqueo (spanning tree), una violación de port security, o un par de cable muerto — hay portadora pero las tramas no atraviesan.
4. Filtrado ARP / aislamiento de clientes en el AP o el switch.
5. IP duplicada, o un firewall con filtrado por MAC descartando la respuesta.

### Ejercicio 3

**R3.1** `56` es el tamaño de la *carga útil* ICMP que pidió `ping` (su valor por defecto `-s 56`). `84` es el datagrama IP completo: 56 bytes de carga útil + 8 bytes de cabecera ICMP + 20 bytes de cabecera IPv4. Las líneas de respuesta reportan después `64 bytes`, que es el mensaje ICMP tal como se ve por encima de la capa IP (56 + 8), porque la cabecera IP se quita antes de que `ping` cuente.

**R3.2** El TTL se decrementa en uno por cada router atravesado. Los valores iniciales comunes son 64 (Linux, macOS), 128 (Windows), 255 (muchos equipos de red). Que llegue `ttl=64` intacto significa que se cruzaron **cero** routers — el gateway está on-link, como se esperaba. `ttl=57` desde un valor inicial de 64 implica **7** saltos. El razonamiento es inferencia, no prueba: asumís el valor inicial, y algunos equipos reinician o reescriben el TTL. Usalo como corroboración barata de `traceroute`, no como sustituto.

**R3.3** `mdev` es la desviación media de los tiempos de ida y vuelta — una medida de jitter, calculada como la media de las desviaciones absolutas respecto del RTT medio. Un `avg` bajo con un `mdev` alto significa que la mayoría de los paquetes son rápidos pero algunos se demoran dramáticamente: bufferbloat, una CPU sobrecargada en un dispositivo intermedio, un enlace ascendente saturado, un enlace inalámbrico inestable, o una ruta oscilando entre dos caminos. Los protocolos interactivos (SSH, VoIP, RDP) se degradan con el jitter mucho más que con una latencia uniformemente más alta, así que `mdev` frecuentemente explica una queja que `avg` no puede.

**R3.4** Lo produjo *tu propio kernel*. `-M do` activa el bit `Don't Fragment` de IP; el kernel comparó el datagrama de 1501 bytes contra la MTU de 1500 de la interfaz de salida y lo rechazó localmente con `EMSGSIZE` — la frase `local error` es la pista, y `mtu=1500` nombra el límite local. Si el cuello de botella estuviera a tres saltos, el paquete saldría normalmente y el *router remoto* devolvería `ICMP Fragmentation Needed (Type 3, Code 4)` con su MTU; `ping` imprimiría entonces algo como `From 62.53.16.9 icmp_seq=1 Frag needed and DF set (mtu = 1400)`. La diferencia entre los dos mensajes es exactamente la diferencia entre "NIC mal configurada" y "agujero negro de PMTU".

**R3.5** `fe80::/10` es link-local: la *misma* dirección puede existir legítimamente en cada interfaz del host, así que la dirección por sí sola no identifica un destino. El índice de zona (`%enp1s0`, scope-id de RFC 4007) le dice a la pila por qué interfaz transmitir. Las direcciones globales como `2606:4700:4700::1111` son globalmente únicas y la tabla de enrutamiento sola selecciona la interfaz de salida, así que no hace falta zona. La misma regla aplica a `ssh`, `curl` y cualquier otro cliente con soporte IPv6.

**R3.6** El echo ICMP es un protocolo *distinto* del servicio bajo prueba, y rutinariamente lo limitan por tasa o lo descartan firewalls, grupos de seguridad en la nube y hosts endurecidos, por política y no por falla. "No hay respuesta de echo" por lo tanto no prueba nada sobre TCP/443. La conclusión correcta es "el echo ICMP no se responde"; la siguiente prueba correcta es un sondeo a nivel de transporte — `nc -vz host 443`, `traceroute -T -p 443 host`, o simplemente el cliente de la aplicación.

### Ejercicio 4

**R4.1** Cada sondeo se envía con un TTL de IP deliberadamente pequeño (en IPv6: Hop Limit). Un router que decrementa el TTL a cero debe descartar el paquete y devolver `ICMP Time Exceeded` (Type 11) al origen, y ese error lleva la propia dirección del router como origen. Así que TTL=1 provoca una respuesta del primer router, TTL=2 del segundo, y así sucesivamente. El recorrido termina cuando el sondeo finalmente llega al destino, que responde de forma distinta — `ICMP Port Unreachable` para la variante UDP, `Echo Reply` para `-I`, `SYN/ACK` o `RST` para `-T`.

**R4.2** Casi con seguridad **no**. La pérdida reportada en un salto intermedio refleja solo la disposición de ese router a generar `ICMP Time Exceeded` *por sí mismo* — muchos routers despriorizan o limitan por tasa la generación de ICMP desde el plano de control, y muchos operadores directamente lo filtran. Como los saltos 4 y 5 responden, los paquetes claramente *transitan* el salto 3 intactos. La regla para leer `mtr`: la pérdida es real solo cuando empieza en algún salto **y persiste hasta el destino**. La pérdida en un salto que desaparece después es un artefacto de reporte.

**R4.3** El `traceroute` común envía datagramas UDP a puertos altos e improbables — una operación de socket sin privilegios. `tracepath` de forma similar usa UDP con `IP_MTU_DISCOVER`, y los `ping`/`tracepath` modernos usan sockets ICMP de datagrama sin privilegios donde `net.ipv4.ping_group_range` lo permite. `traceroute -T` tiene que fabricar paquetes TCP SYN crudos con un TTL arbitrario y leer las respuestas crudas, lo que requiere `CAP_NET_RAW` — de ahí root o una capacidad de archivo. `traceroute -I` necesita ICMP crudo por la misma razón.

**R4.4** `pmtu 1500` es la MTU más chica descubierta a lo largo del camino hasta ahora — la característica distintiva de `tracepath` frente a `traceroute`; un valor por debajo de 1500 anticipa problemas para protocolos que activan DF. `asymm 5` significa que el camino de *retorno* desde ese salto parece tener 5 saltos de largo mientras que el de ida tiene 4: el enrutamiento es asimétrico. La asimetría es normal en Internet, pero importa cuando un firewall con estado se sienta en solo uno de los dos caminos, o cuando estás interpretando latencia unidireccional.

**R4.5**
```bash
nc -vz -w 3 <server> 443     # expect: succeeded
nc -vz -w 3 <server> 8080    # expect: timed out  -> filtered (not refused)
sudo traceroute -n -T -p 8080 <server>   # shows the last hop before the silence
sudo traceroute -n -T -p 443  <server>   # reaches the server, for contrast
```
La evidencia decisiva es el *par*: 443 tiene éxito y 8080 **expira** en lugar de ser rechazado. Un rechazo probaría que el paquete llegó al servidor y que no había ningún proceso escuchando; el silencio en un salto que sí responde para 443 localiza el descarte en un dispositivo de filtrado en el camino.

**R4.6** `mtr`. `ping` da pérdida y jitter pero ninguna idea de *dónde*; `traceroute` da un camino pero solo tres sondeos por salto, muy pocos para caracterizar pérdida intermitente. `mtr` envía sondeos continuos a cada salto simultáneamente, así que después de unos cientos de ciclos muestra pérdida y latencia **por salto a lo largo del tiempo** — exactamente la forma de evidencia que necesita una queja intermitente. Ejecutalo largo (`--report-cycles 100+`) y leelo con la regla de R4.2.

### Ejercicio 5

**R5.1** `ping`, `getent`, `ssh`, los navegadores y prácticamente todas las aplicaciones resuelven nombres a través del **Name Service Switch de glibc**, llamando a `getaddrinfo(3)`, que consulta las fuentes listadas en `/etc/nsswitch.conf` — acá `files` (es decir, `/etc/hosts`) primero. `dig` y `host` son **herramientas de diagnóstico de DNS**: saltean NSS por completo y hablan el protocolo DNS directamente con un servidor de nombres. Por lo tanto nunca ven `/etc/hosts`, nunca respetan `nsswitch.conf`, y nunca usan fuentes mDNS ni LDAP. Esta es la distinción más valiosa de todo el objetivo: **`getent hosts` te dice lo que va a ver la aplicación; `dig` te dice lo que el DNS realmente dice.** Cuando los dos discrepan, la falla está en la configuración de NSS, no en el DNS.

**R5.2** `dns` **no** se consultaría. La acción `[NOTFOUND=return]` le indica a NSS que detenga toda la búsqueda y devuelva un fallo en cuanto `mdns4_minimal` reporte "autoritativamente, este nombre no existe", en lugar de caer a la siguiente fuente. Esto es deliberado: el módulo `mdns4_minimal` solo reclama el pseudo-TLD `.local`, así que la construcción significa "`.local` es territorio de mDNS; no filtres consultas `.local` al DNS público". Un nombre como `printer.local` por lo tanto falla inmediatamente si ningún respondedor mDNS contesta.

**R5.3**
- `NXDOMAIN` — el servidor autoritativo de la zona declara que el nombre no existe. Autoritativo, cacheable, y significa que faltan los *datos*. Se arregla en la zona.
- `SERVFAIL` — el servidor al que preguntaste no pudo producir una respuesta: falló la recursión, el upstream expiró, la validación DNSSEC falló, o la zona está rota o lame. Esto apunta a **tu propio resolutor o al camino desde él**, y es el que te pertenece.
- `REFUSED` — el servidor entendió la consulta y se niega a atenderte por política: estás fuera de su ACL permitida, o es solo autoritativo y pediste recursión.

**R5.4** `qr` = este mensaje es una *respuesta*, no una consulta. `rd` = *recursion desired*, activada por el cliente, pidiéndole al servidor que persiga la respuesta a través de la cadena de delegación. `ra` = *recursion available*, activada por el servidor, confirmando que está dispuesto a hacerlo. **`ra` faltaría** en un servidor solo autoritativo; pedirle a un servidor así un nombre fuera de sus zonas típicamente devuelve una referencia o `REFUSED`, no una respuesta — causa frecuente de "funciona con `dig @8.8.8.8` pero no con nuestro servidor interno".

**R5.5** El DNS en sí y todo el camino por debajo están sanos — 1.1.1.1 respondió, lo que requirió enlace, dirección, ruta y UDP/53 hacia Internet funcionando. La falla está en el **camino del resolutor configurado localmente**: o la línea `nameserver` de `/etc/resolv.conf` apunta a algo inalcanzable, o el servidor local está caído o filtrando. Siguientes comandos, en orden:
```bash
cat /etc/resolv.conf                       # which server is configured?
dig @<that-server> example.com             # is it that specific server?
resolvectl status                          # if systemd-resolved is in play
ss -ulnp '( sport = :53 )'                 # is a local stub listening at all?
```

**R5.6** En un host así, `systemd-resolved` es dueño de la resolución: `/etc/resolv.conf` es un enlace simbólico *generado* que apunta a un stub cuyo único servidor de nombres es el listener local `127.0.0.53`. Editarlo o bien edita el archivo generado (que se sobrescribe en el siguiente evento de red) o bien reemplaza el enlace simbólico (deshabilitando silenciosamente el stub y divergiendo de lo que `resolved` cree). Los servidores upstream reales, los dominios de búsqueda por enlace, el estado de DNSSEC y el modo DNS-over-TLS se muestran con:
```bash
resolvectl status
resolvectl query www.lpi.org      # resolve through NSS/resolved, showing which link answered
```
La configuración va en `/etc/systemd/resolved.conf`, en un perfil de conexión de NetworkManager, o en el lease de DHCP — no en `/etc/resolv.conf`.

**R5.7** El resolutor de glibc compila `MAXNS 3` y silenciosamente ignora toda línea `nameserver` más allá de la tercera. Agregar una cuarta "por las dudas" es configuración muerta que crea una falsa sensación de redundancia — y peor todavía, si las tres primeras son las rotas, la entrada que funciona nunca se usa. Notá también que el comportamiento por defecto es *secuencial con timeout*, no paralelo: con `options timeout:5 attempts:2` y tres servidores, un primer servidor completamente muerto puede agregar decenas de segundos a cada búsqueda. Reducir `timeout` y `attempts`, o arreglar la lista, es el remedio real.

### Ejercicio 6

**R6.1** `0.0.0.0:22` es el comodín IPv4: el socket acepta conexiones que lleguen a **cualquier** dirección local, incluida `192.168.178.42`. `127.0.0.1:8080` se enlaza solo a la dirección de loopback, así que el kernel solo va a entregar conexiones cuya IP de destino sea `127.0.0.1` — el tráfico desde otro host nunca puede llevar ese destino. No hay firewall involucrado; el paquete lo rechaza la demultiplexación de sockets. Soluciones, en orden de preferencia: enlazar el servicio a `0.0.0.0` (o a una dirección LAN específica) en su propia configuración, o, cuando el enlace a loopback es deliberado, poner un proxy inverso delante, o tunelizar con `ssh -L`.

**R6.2** Para un socket en `LISTEN`, `Send-Q` es el **límite del backlog de la cola de accept** — el valor pasado a `listen(2)`, acotado por `net.core.somaxconn` (4096 para `systemd-resolve`, 128 para `sshd`, 511 para `gunicorn` arriba), y `Recv-Q` es la cantidad de conexiones establecidas *esperando ser aceptadas*. Un `Recv-Q` no nulo y persistente en un listener significa que la aplicación no está llamando a `accept()` con suficiente rapidez — una señal real de capacidad. Para un socket `ESTAB` las columnas vuelven a su significado obvio: bytes recibidos pero todavía no leídos por la aplicación, y bytes escritos por la aplicación pero todavía no reconocidos por el par.

**R6.3** `net.ipv6.bindv6only`. Cuando vale `0` (el valor por defecto en Linux), un socket enlazado al comodín IPv6 `::` también acepta conexiones IPv4, que llegan como direcciones IPv4 mapeadas (`::ffff:192.0.2.1`) — un socket, ambas familias, de ahí la única línea `[::]:22`. Cuando vale `1`, o cuando el demonio activa `IPV6_V6ONLY` en el socket mismo (OpenSSH lo hace, que es por lo que el ejemplo muestra dos líneas separadas), cada familia necesita su propio socket. Esto explica el por lo demás desconcertante "IPv6 funciona, IPv4 no" después de cambiar un parámetro del kernel.

**R6.4** **No.** `/etc/services` es puramente un *registro nombre↔número* consultado por `getservbyname(3)`/`getaddrinfo(3)` y por herramientas de visualización como `ss`, `netstat` y `nc` cuando muestran `443` como `https`. A qué puerto se enlaza un demonio lo decide la propia configuración de ese demonio (`Port` en `sshd_config`, `listen` en nginx, etc.) o un valor por defecto en el código. Borrar la línea `ssh` de `/etc/services` cambiaría cómo `ss` *etiqueta* el puerto 22 y rompería `nc host ssh`, pero `sshd` seguiría escuchando exactamente donde estaba. Editar `/etc/services` para "mover un servicio" es una trampa clásica de examen.

**R6.5** Dos cualesquiera de estas:
1. **Velocidad y escala.** `ss` lee sockets netlink `sock_diag`, obteniendo las tablas de sockets del kernel en unos pocos mensajes estructurados. `netstat` parsea `/proc/net/*` línea por línea y, para `-p`, recorre cada `/proc/<pid>/fd/` del sistema — en un host con 100 000 sockets eso son minutos contra milisegundos, y consume CPU cuando ya estás en medio de un incidente.
2. **Filtrado del lado del kernel.** `ss` acepta un verdadero lenguaje de filtros — `ss -tan state established '( dport = :443 or sport = :443 )'` — evaluado por el kernel, en vez de canalizar todo a través de `grep`.
3. **Datos más ricos.** `ss -i` expone internos de TCP por socket (algoritmo de congestión, `cwnd`, `rtt`, `retrans`, `mss`, pacing) que `netstat` directamente no puede mostrar; `ss -o` muestra temporizadores; `ss -e` muestra el inodo y el cgroup.
4. **Mantenimiento.** `net-tools` está efectivamente congelado y ausente por defecto en muchas distribuciones modernas; `iproute2` es la interfaz mantenida a las características actuales del kernel (namespaces, enrutamiento por políticas, conocimiento de netns con `-N`).

**R6.6** `TIME-WAIT` lo mantiene el lado que realizó el **cierre activo** — el que envió el primer `FIN`. Dura 2×MSL (60 s en Linux) y existe por dos razones: para absorber segmentos duplicados demorados de la conexión cerrada de modo que no puedan entregarse por error a una conexión nueva que reutilice la misma cuádrupla, y para garantizar que el ACK final pueda retransmitirse si el `FIN` del par se repite. Miles de sockets `TIME-WAIT` en un *servidor* son una señal de diseño — significa que el servidor está cerrando las conexiones primero, típicamente porque keep-alive está apagado o porque un proxy abre una conexión nueva por petición. Es un síntoma a interpretar, no una fuga a "arreglar" deshabilitando el estado.

### Ejercicio 7

**R7.1**
- **succeeded** — `nc` envió `SYN`, el par respondió `SYN/ACK`, `nc` completó el handshake con `ACK` (y cerró inmediatamente, por el `-z`). Hay un proceso escuchando y el camino permite el tráfico.
- **Connection refused** — el par respondió con `RST/ACK`. El paquete *llegó a un host* que es dueño de esa dirección, y su kernel no encontró ningún socket escuchando en ese puerto. El camino está abierto de punta a punta; el servicio está ausente o enlazado en otro lado.
- **timed out** — **no volvió ningún paquete en absoluto**. Un firewall descartó el SYN en silencio (`DROP` en lugar de `REJECT`), el host no existe, o el camino de retorno está roto. `nc` se rindió después del plazo de `-w 3`.

**R7.2** Porque un rechazo es *prueba de alcanzabilidad de punta a punta*. Un `RST` solo lo puede generar el host que es dueño de la dirección de destino, así que prueba que el SYN atravesó cada router y cada firewall del camino de ida y que la respuesta los atravesó de vuelta. El problema por lo tanto no es la red: es el servicio — no iniciado, caído, enlazado a `127.0.0.1`, o escuchando en otro puerto. Esa sola distinción rutinariamente ahorra una ronda entera de echarle la culpa al equipo de firewall.

**R7.3** TCP obliga a una respuesta ante un SYN: o `SYN/ACK` o `RST`. UDP no obliga a nada. Un sondeo UDP a un puerto cerrado *debería* provocar `ICMP Port Unreachable` (Type 3, Code 3), pero Linux limita fuertemente ese ICMP por tasa (`net.ipv4.icmp_ratelimit`) y muy comúnmente está filtrado, y un sondeo UDP a un puerto *abierto* no produce respuesta alguna a menos que la aplicación decida contestar una carga útil que entienda. Así que tanto "abierto" como "filtrado" se ven idénticos — silencio — y `nc -zu` reporta éxito para cualquier cosa que no rechace explícitamente. La prueba UDP confiable es específica de cada protocolo: `dig @host name` para DNS, `ntpdate -q` para NTP, `snmpget` para SNMP.

**R7.4** HTTP/1.1 (RFC 9112) define el terminador de línea para la línea de petición y las cabeceras como `CRLF`, y el fin del bloque de cabeceras como un `CRLF` solo en su propia línea; un servidor puede rechazar o colgarse ante un `LF` suelto. `printf` emite `\r\n` literalmente, mientras que `echo` no. La cabecera `Host:` es **obligatoria** en HTTP/1.1 — es lo que permite el hosting virtual basado en nombres, ya que la conexión TCP solo transporta una dirección IP. Omitirla produce `400 Bad Request` en la mayoría de los servidores, algo que los estudiantes suelen malinterpretar como una falla de red.

**R7.5** Los peldaños 1–7 están probados buenos: la conexión TCP se establece y el servidor envía su banner, así que enlace, dirección, ruta, camino, nombre y transporte están todos bien. La sospecha se mueve a la **capa de aplicación / autenticación** — y, notablemente, a algo que ocurre *después* del banner: la búsqueda de DNS inverso de la dirección de tu cliente por parte de `sshd` (`UseDNS yes` con un resolutor inalcanzable produce exactamente una traba post-banner de decenas de segundos), un módulo PAM colgado (LDAP, SSSD, `pam_systemd`), un pool de entropía agotado en kernels viejos, o un `/` lleno que impide escribir `utmp`. Diagnosticá con `ssh -vvv host` para ver la etapa exacta, y en el servidor `journalctl -u ssh -f`, `ss -tanp '( sport = :22 )'` y `resolvectl query <client-ip>`. Un agujero negro de MTU de camino es el otro candidato clásico — se traba precisamente cuando se envía el primer paquete de tamaño completo (el intercambio de claves); probalo con `ping -M do -s 1400`.

### Ejercicio 8

**R8.1** Lo produjo el **kernel local**, en el momento de la búsqueda de ruta, antes de construir paquete alguno. Sin ruta por defecto y sin coincidencia más específica, la búsqueda en la FIB para `1.1.1.1` falló y la llamada al sistema `connect()`/`sendto()` devolvió `ENETUNREACH`, que `ping` imprimió como `connect: Network is unreachable`. No se transmitió nada. `ip route get` reportó la misma falla directamente desde netlink: `RTNETLINK answers: Network is unreachable`. El rasgo distintivo de esta clase de falla es que es *instantánea* — no hay timeout, porque no hay nada que esperar.

**R8.2**
- **`Network is unreachable`** — *configuración* de capa 3 en el host local: no existe ruta. Falla instantánea, no se envían paquetes. Arreglá la tabla de enrutamiento.
- **`Destination Host Unreachable` desde tu propia dirección** — capa 2: la ruta existe y dice on-link, pero ARP/ND no encontró a nadie. Arreglá la dirección/el prefijo, la VLAN, o el vecino mismo. (El mismo mensaje *desde la dirección de un router* significa lo mismo un salto más afuera.)
- **Timeout silencioso** — los paquetes salieron y no volvió nada. O un firewall está descartando (en vez de rechazar), o el camino de retorno está roto, o el destino está apagado. Este es el único de los tres donde el problema puede estar enteramente fuera de tu host.

**R8.3** Con `192.168.178.42/28`, el prefijo on-link es `192.168.178.32/28`, es decir `.33`–`.46`. `192.168.178.200` ya no coincide con la ruta `scope link` (que el kernel reescribió silenciosamente cuando cambió la dirección), así que la FIB cae a la ruta por defecto y el paquete se envía **a la dirección MAC del gateway** con `192.168.178.200` todavía en el campo de destino IP. El gateway, que cree que todo el `/24` está on-link, hace ARP por `.200`, recibe respuesta, reenvía la trama — y típicamente también devuelve un `ICMP Redirect` diciéndote que uses el camino on-link. El tráfico puede muy bien funcionar, mal y de forma asimétrica, vía un salto de router innecesario; mientras tanto las respuestas de `.200` vuelven directamente, lo que rompe cualquier firewall con estado que haya en el medio. Los desajustes de máscara producen fallas *parciales*, que es por lo que son mucho más difíciles de detectar que una falla total.

**R8.4** El usuario reporta "se cayó Internet" o "no carga la página", mientras que cualquier cosa direccionada numéricamente o ya cacheada sigue funcionando: una sesión SSH a una IP se mantiene viva, `ping 1.1.1.1` está limpio, un host en favoritos con una entrada fresca en la caché DNS carga. Todo por nombre se cuelga uno o dos segundos y después falla. `getent hosts` devuelve un código no nulo después del timeout del resolutor; `dig @1.1.1.1` funciona. **Que `ping 1.1.1.1` funcione es el discriminador** porque prueba que los peldaños 1–5 — enlace, dirección, vecino, ruta y camino — están todos sanos, lo que excluye toda capa por debajo de la resolución de nombres con un solo comando. Combinalo con `getent` fallando y `dig @<público>` funcionando y la falla queda localizada con certeza en `/etc/resolv.conf` o `nsswitch.conf`.

**R8.5** Agregar antes de eliminar mantiene la interfaz continuamente direccionada, así que no se corta ninguna conexión ni se pierde estado de enrutamiento en el intervalo. Eliminar primero deja la interfaz sin dirección durante todo el tiempo que tardes en tipear: el kernel elimina inmediatamente la ruta `scope link` asociada **y la ruta por defecto que dependía de ella**, cada conexión TCP establecida a través de esa interfaz se rompe, y — en un host remoto — tu propia sesión SSH muere antes de que puedas emitir el `add`, dejando la máquina inalcanzable y requiriendo intervención por consola. Para cambios remotos genuinamente riesgosos, los hábitos profesionales son `ip addr replace`, envolver el cambio en un script con un `sleep 60 && <rollback>` programado de antemano, o usar `at`/`systemd-run --on-active` para auto-revertir.

**R8.6** Cada comando `ip` escribe solo en el kernel en ejecución; nada toca el disco.
- **NetworkManager** (Fedora/RHEL/Rocky/Ubuntu de escritorio): perfiles de conexión en `/etc/NetworkManager/system-connections/*.nmconnection`, editados con `nmcli connection modify <name> ipv4.addresses … ipv4.gateway … ipv4.dns …` seguido de `nmcli connection up <name>`. RHEL 9 abandonó los archivos heredados `/etc/sysconfig/network-scripts/ifcfg-*` en favor de estos.
- **Debian `ifupdown`**: `/etc/network/interfaces` y `/etc/network/interfaces.d/*`, aplicados con `ifdown`/`ifup` o `systemctl restart networking`.
- También comunes: **`systemd-networkd`** (`/etc/systemd/network/*.network`) en servidores y contenedores, y **Netplan** (`/etc/netplan/*.yaml`, `netplan apply`) en Ubuntu Server, que es un front-end que renderiza a alguno de los otros dos.

### Ejercicio 9

**R9.1** `hostname -f` llama a `getaddrinfo()` sobre el hostname corto con `AI_CANONNAME` y devuelve el nombre canónico que vuelve. Esa búsqueda pasa por NSS: `files` primero, después `dns`. Si `/etc/hosts` no tiene entrada para `workstation` **y** la zona DNS no tiene registro `A`/`AAAA` para esa etiqueta desnuda con el dominio de `search` configurado agregado, no hay nombre canónico que devolver, y la llamada falla con `Name or service not known` — sin importar cuán sano esté el DNS para *otros* nombres. La lección: el FQDN de un host no es una propiedad intrínseca que "sabe"; es el resultado de resolver su propio nombre, y falla exactamente igual que cualquier otra resolución.

**R9.2** `127.0.1.1` permite que el hostname resuelva a una dirección de loopback **sin** colisionar con la entrada `127.0.0.1 localhost`, que muchos programas esperan que mapee al nombre literal `localhost` y nada más. La Política de Debian §11.9 lo exige para máquinas con dirección dinámica (DHCP), de modo que `hostname -f` funcione antes de e independientemente de que se arriende dirección alguna. La alternativa — apuntar el hostname a la dirección LAN real de la máquina — se rompe en cuanto DHCP entrega una distinta, y apuntarlo a `127.0.0.1` junto con `localhost` hace que los servicios que se enlazan a "el hostname" se enlacen a loopback y que los servicios que resuelven inversamente `127.0.0.1` obtengan el nombre equivocado.

**R9.3**
- `hostname lab-node` — **solo transitorio**. Llama a `sethostname(2)`; el kernel lo olvida al reiniciar. Útil para una prueba rápida, nunca para configuración.
- Editar `/etc/hostname` — **persistente**, pero *no* cambia el hostname en ejecución; toma efecto en el siguiente arranque (o cuando `systemd-hostnamed`/el script de init lo lee).
- `hostnamectl set-hostname lab-node` — **ambos**: escribe `/etc/hostname` *y* llama a `sethostname(2)` inmediatamente, y notifica a los servicios interesados por D-Bus. Este es el comando único correcto en cualquier distribución con systemd. Notá que ninguno de los tres actualiza `/etc/hosts`, así que `hostname -f` puede romperse después de un renombrado hasta que arregles ese archivo también.

**R9.4** `hostname -I` filtra deliberadamente: omite las direcciones de loopback, y omite las direcciones IPv6 **link-local**. Así que un host cuya única dirección IPv6 es `fe80::…` no muestra nada para IPv6 en `hostname -I` mientras que `ip -br addr` la muestra sin más. Otras razones de divergencia: direcciones en interfaces administrativamente caídas, direcciones en un namespace de red distinto, y (en compilaciones más viejas de `net-tools`) direcciones marcadas como `deprecated` o `tentative` durante la Detección de Direcciones Duplicadas. El principio general aplica mucho más allá de este comando — `hostname -I` e `ifconfig` son *resúmenes*; `ip` es la fuente de verdad.

### Ejercicio 10

**R10.1** Porque la escalera hay que subirla desde abajo, y cada peldaño solo tiene sentido si se sostienen los de abajo. `ping 1.1.1.1` ejercita enlace, dirección, vecino, ruta y camino *sin* involucrar al DNS en absoluto. Si falla, probar `getent hosts` es esfuerzo desperdiciado — la consulta del resolutor viaja ella misma por la misma red que está rota, así que fallaría por razones que no te dicen nada nuevo. Probar de arriba hacia abajo invierte causa y síntoma y es la forma más común en que un ingeniero se pasa veinte minutos con el DNS cuando hay un cable desenchufado.

**R10.2** Usando la dirección que devolvió `dig @1.1.1.1`. El simulacro deliberadamente mantiene separadas las dos mitades del peldaño 6: `getent hosts` (lo que ve la aplicación) y `dig @<resolutor público>` (lo que el DNS realmente dice). Cuando discrepan, `dig` de todos modos te entregó una dirección usable, así que el peldaño 7 puede proceder directamente contra `208.94.116.9`:
```bash
nc -vz -w 3 208.94.116.9 443
```
Esta es la técnica general para probar *por debajo* de una capa rota — sustituís el artefacto que la capa rota habría producido, y los peldaños de arriba vuelven a ser probables. Convierte "todo está roto" en "exactamente una cosa está rota", que es todo el objetivo.

**R10.3** Causas más probables:
1. **Desajuste de VLAN** — los dos puertos del switch están en VLANs distintas, así que los broadcasts ARP nunca llegan al otro host. Ambos hosts se ven perfectos localmente.
2. **Firewall de host descartando ARP o ICMP entrante** en una o ambas máquinas — menos común para ARP (se maneja por debajo de los hooks de IP de netfilter y necesita reglas `arptables`/`ebtables`/`nft` de bridge), pero muy común para el echo ICMP, que daría `FAILED` solo si estuvieras dependiendo de `ping` para disparar la resolución.
   Un tercer candidato fuerte son las **longitudes de prefijo desparejas**, donde cada host cree que el otro está fuera del enlace.

Comando discriminador:
```bash
sudo ip neigh flush all && ping -c 2 -W 1 <other-host> ; ip neigh show <other-host>
sudo tcpdump -ni enp1s0 arp        # on the other host, while the first pings
```
Si el `tcpdump` del segundo host muestra que llegan las *peticiones* ARP, la entrega L2 funciona y la falla es un filtro o un problema de pila en ese host; si no llega ningún ARP, el segmento mismo los está separando — VLAN, aislamiento de puertos, o prefijo equivocado. Confirmar el prefijo cuesta un comando: `ip -br -4 addr` en ambos.

**R10.4** Peldaño 5 — **MTU del camino**. La firma es inconfundible: los paquetes chicos (que entran en cualquier MTU) tienen éxito, así que ping, traceroute y el handshake TLS están todos limpios; la falla empieza exactamente cuando se envía el primer segmento de tamaño completo, que en una subida es el momento en que empiezan a fluir los datos reales. La causa suele ser un túnel (PPPoE, IPsec, WireGuard, GRE) reduciendo la MTU en algún punto del camino, combinado con un dispositivo que bloquea `ICMP Fragmentation Needed`, con lo que el descubrimiento de MTU del camino cae en un agujero negro silencioso.

Evidencia:
```bash
ping -c 1 -M do -s 1472 <server>    # 1500-byte datagram
ping -c 1 -M do -s 1400 <server>    # 1428-byte datagram
tracepath -n <server>               # Resume: pmtu <n>
```
Si 1400 tiene éxito y 1472 falla con `Frag needed and DF set (mtu = …)` — o peor, falla *en silencio* — lo localizaste, y la línea `pmtu` de `tracepath` nombra el valor. El remedio es bajar la MTU de la interfaz al valor descubierto o hacer clamping del MSS de TCP en el router.

**R10.5** Tres razones concretas, ninguna de ellas ceremonial:
1. **No podés comparar contra un estado que no registraste.** La pregunta diagnóstica más común es "¿qué cambió?", y sin una imagen previa la respuesta es adivinanza. Un `diff` contra la instantánea la responde con un solo comando.
2. **Diagnosticar muta la evidencia.** Vaciar una tabla de vecinos, reiniciar NetworkManager, o rebotar una interfaz destruye exactamente el estado que habría identificado la falla. La instantánea es la única copia de la escena del crimen.
3. **Necesitás un camino de rollback.** Cada cambio del Ejercicio 8 fue seguro solo porque el paso 1 registró qué restaurar. En un host de producción, "me voy a acordar" falla justo en el momento en que más lo necesitás — veinte minutos dentro de un incidente, bajo presión, en una máquina a la que ya no podés llegar.

Una cuarta razón, organizacional: la instantánea es lo que le pasás al siguiente ingeniero, o adjuntás al ticket. Es la diferencia entre un informe sobre el que alguien puede actuar y un informe que arranca otra investigación desde cero.

</details>

---

## Fuentes

- **Objetivos del examen LPI** — Tema 109, *Networking Fundamentals*: [objetivos 102-500](https://www.lpi.org/our-certifications/exam-102-objectives/); lista complementaria [objetivos 101-500](https://www.lpi.org/our-certifications/exam-101-objectives/)
- **iproute2** (`ip`, `ss`, `bridge`) — upstream: <https://wiki.linuxfoundation.org/networking/iproute2>; páginas de manual: [`ip-address(8)`](https://man7.org/linux/man-pages/man8/ip-address.8.html), [`ip-route(8)`](https://man7.org/linux/man-pages/man8/ip-route.8.html), [`ip-neighbour(8)`](https://man7.org/linux/man-pages/man8/ip-neighbour.8.html), [`ss(8)`](https://man7.org/linux/man-pages/man8/ss.8.html)
- **iputils** (`ping`, `tracepath`, `arping`) — <https://github.com/iputils/iputils>; [`ping(8)`](https://man7.org/linux/man-pages/man8/ping.8.html), [`tracepath(8)`](https://man7.org/linux/man-pages/man8/tracepath.8.html)
- **traceroute** — <https://traceroute.sourceforge.net/>; [`traceroute(8)`](https://man7.org/linux/man-pages/man8/traceroute.8.html)
- **Herramientas de diagnóstico de BIND** (`dig`, `host`) — documentación de ISC: <https://bind9.readthedocs.io/en/latest/manpages.html>
- **Resolución de nombres de glibc** — NSS y el resolutor: [`nsswitch.conf(5)`](https://man7.org/linux/man-pages/man5/nsswitch.conf.5.html), [`resolv.conf(5)`](https://man7.org/linux/man-pages/man5/resolv.conf.5.html), [`getaddrinfo(3)`](https://man7.org/linux/man-pages/man3/getaddrinfo.3.html), [`hosts(5)`](https://man7.org/linux/man-pages/man5/hosts.5.html), [`services(5)`](https://man7.org/linux/man-pages/man5/services.5.html)
- **systemd-resolved** — <https://www.freedesktop.org/software/systemd/man/latest/systemd-resolved.service.html>, [`resolvectl(1)`](https://www.freedesktop.org/software/systemd/man/latest/resolvectl.html), [`hostnamectl(1)`](https://www.freedesktop.org/software/systemd/man/latest/hostnamectl.html)
- **netcat de OpenBSD** — [`nc(1)`](https://man.openbsd.org/nc.1)
- **mtr** — <https://www.bitwizard.nl/mtr/>
- **RFCs** — [RFC 792](https://www.rfc-editor.org/rfc/rfc792) (ICMP), [RFC 826](https://www.rfc-editor.org/rfc/rfc826) (ARP), [RFC 1191](https://www.rfc-editor.org/rfc/rfc1191) (Path MTU Discovery), [RFC 4007](https://www.rfc-editor.org/rfc/rfc4007) (direcciones con ámbito IPv6), [RFC 4861](https://www.rfc-editor.org/rfc/rfc4861) (IPv6 Neighbor Discovery), [RFC 9293](https://www.rfc-editor.org/rfc/rfc9293) (TCP), [RFC 9112](https://www.rfc-editor.org/rfc/rfc9112) (HTTP/1.1)
- **Política de Debian §11.9**, sobre la convención `127.0.1.1` — <https://www.debian.org/doc/debian-policy/ch-customized-programs.html>