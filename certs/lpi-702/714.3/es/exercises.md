# LPI 702-100: BSD Specialist Certification — Tema 714.3: Solución Básica de Problemas de Red

**Peso:** 5  
**Nivel:** SRE Avanzado / Arquitecto de Plataforma de Producción  
**Referencia Oficial:** [LPI BSD Specialist Objectives & Overview](https://www.lpi.org/our-certifications/bsd-specialist-overview/)

---

## Descripción Técnica y Mecánica Interna

La solución de problemas de red en las variantes de BSD (FreeBSD, OpenBSD, NetBSD) requiere un enfoque metódico y por capas basado en el modelo OSI. Comprender los aspectos internos de la pila de red del kernel de BSD es esencial para diagnosticar fallas bajo cargas de producción elevadas.

```
+-----------------------------------------------------------------------+
|                        Application Layer (L7)                         |
|                 (curl, dig, drill, host, nc, telnet)                  |
+-----------------------------------------------------------------------+
                                   |
                                   v
+-----------------------------------------------------------------------+
|                        Transport Layer (L4)                           |
|       (TCP, UDP, SCTP - Inspected via sockstat, netstat, fstat)        |
+-----------------------------------------------------------------------+
                                   |
                                   v
+-----------------------------------------------------------------------+
|                         Network Layer (L3)                            |
|    (IP Routing, ICMP, ARP/NDP - Inspected via route, ping, traceroute)|
|                    FreeBSD Radix Tree Routing Table                   |
+-----------------------------------------------------------------------+
                                   |
                                   v
+-----------------------------------------------------------------------+
|                        Data Link Layer (L2)                           |
|         (Ethernet, VLANs, LAGG - Inspected via ifconfig, arp)         |
|         Berkeley Packet Filter (BPF) tapped via tcpdump               |
+-----------------------------------------------------------------------+
                                   |
                                   v
+-----------------------------------------------------------------------+
|                        Physical Layer (L1)                            |
|             (Media status, autoneg, duplex via ifconfig)              |
+-----------------------------------------------------------------------+
```

### Conceptos Arquitectónicos Clave
1. **Estado del Enlace y Negociación de Medios (L1/L2):** El kernel de BSD expone los flags de estado de las interfaces a través de `ifconfig`. Los flags clave incluyen `UP` (habilitación administrativa), `RUNNING` (el driver asignó recursos y la capa de enlace está lista), `PROMISC` (modo promiscuo) y `OACTIVE` (desbordamiento de la cola de transmisión). Los cambios en el estado del enlace son gestionados por la capa de interfaz del kernel (estructura `ifnet`).
2. **Address Resolution Protocol (ARP / NDP):** Mapea direcciones IP de L3 a direcciones MAC de L2. En FreeBSD, las entradas ARP residen en una tabla hash en memoria gestionada por `in_arpcom`, visible con `arp -a`. Para IPv6, Neighbor Discovery Protocol (NDP) opera sobre ICMPv6 y se gestiona a través de `ndp -a`.
3. **Tabla de Enrutamiento Radix Tree (L3):** BSD utiliza una estructura de datos Patricia/Radix tree para la coincidencia de rutas de destino IP. Las búsquedas de rutas ejecutan Longest Prefix Match (LPM). Las tablas de enrutamiento de red se consultan mediante `netstat -rn` y se modifican utilizando `route(8)`.
4. **Inspección del Estado de Sockets (L4):** BSD proporciona `sockstat(1)` (un reemplazo nativo para `lsof` / Linux `ss`) que consulta las tablas de sockets del kernel (nodos `sysctl` `kern.ipc.sockets` y `net.inet.tcp.sctp_pcbinfo`) directamente para mapear procesos (PIDs, UIDs) con descriptores de archivo abiertos, endpoints IP locales/remotos y estados de sockets (por ejemplo, `LISTEN`, `ESTABLISHED`, `TIME_WAIT`).
5. **Berkeley Packet Filter (BPF):** `tcpdump` se conecta a dispositivos de kernel BPF en bruto (`/dev/bpf*`). BPF compila los filtros en instrucciones de pseudo-máquina que se ejecutan directamente dentro del contexto del kernel, eliminando los cambios de contexto usuario/kernel para los paquetes que no coinciden.

---

## Ejercicios Guiados

---

### Ejercicio 1: Diagnóstico de Capa Física y de Enlace (L1/L2)

#### Pasos
1. Mostrar la configuración y el estado detallado de todas las interfaces de red del sistema:
   ```bash
   ifconfig -a
   ```
   **Salida Esperada:**
   ```text
   vtnet0: flags=8843<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST> metric 0 mtu 1500
           options=80007<PERFORMANCE,VLAN_MTU,VLAN_HWTAGGING,LINKSTATE>
           ether 52:54:00:12:34:56
           inet 192.168.1.50 netmask 0xffffff00 broadcast 192.168.1.255
           inet6 fe80::5054:ff:fe12:3456%vtnet0 prefixlen 64 scopeid 0x1
           media: Ethernet autoselect (1000baseT <full-duplex>)
           status: active
           nd6 options=23<PERF,ACCEPT_RTADV,AUTO_LINKLOCAL>
   lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> metric 0 mtu 16384
           options=680003<RXCSUM,TXCSUM,LINKSTATE,RXCSUM_IPV6,TXCSUM_IPV6>
           inet 127.0.0.1 netmask 0xff000000
           inet6 ::1 prefixlen 128
           inet6 fe80::1%lo0 prefixlen 64 scopeid 0x2
           groups: lo
           nd6 options=21<PERF,AUTO_LINKLOCAL>
   ```

2. Inspeccionar errores de enlace, paquetes descartados y contadores de colisiones en la interfaz `vtnet0`:
   ```bash
   netstat -I vtnet0 -b
   ```
   **Salida Esperada:**
   ```text
   Name    Mtu Network       Address              Ipkts Ierrs Opkts Oerrs  Coll Drop
   vtnet0 1500 <Link#1>      52:54:00:12:34:56  142093     0 98231     0     0    0
   vtnet0 1500 192.168.1.0/2 192.168.1.50       141802     - 98110     -     -    -
   ```

3. Consultar la tabla de caché ARP L2 actual para identificar las direcciones MAC resueltas:
   ```bash
   arp -a
   ```
   **Salida Esperada:**
   ```text
   gateway (192.168.1.1) at 00:11:22:33:44:55 on vtnet0 expires in 1180 seconds [ethernet]
   host2 (192.168.1.100) at 52:54:00:ab:cd:ef on vtnet0 expires in 850 seconds [ethernet]
   ```

4. Forzar la eliminación de una entrada ARP inválida o desactualizada para la IP `192.168.1.100`:
   ```bash
   sudo arp -d 192.168.1.100
   ```
   **Salida Esperada:**
   ```text
   192.168.1.100 (192.168.1.100) deleted
   ```

#### Preguntas de Verificación (Ejercicio 1)
1. **P1.1:** ¿Cuál es la diferencia técnica entre los flags `UP` y `RUNNING` en la salida de `ifconfig`?
2. **P1.2:** Si los contadores `Ierrs` o `Coll` se incrementan de forma constante en `netstat -I <interfaz>`, ¿qué problemas subyacentes de capa física o de enlace se indican?

---

### Ejercicio 2: Diagnóstico de Ruta y Enrutamiento en Capa de Red (L3)

#### Pasos
1. Mostrar la tabla de enrutamiento IPv4 del kernel con representación numérica de IP:
   ```bash
   netstat -rn -f inet
   ```
   **Salida Esperada:**
   ```text
   Routing tables

   Internet:
   Destination        Gateway            Flags     Netif Expire
   default            192.168.1.1        UGS      vtnet0
   127.0.0.1          link#2             UH          lo0
   192.168.1.0/24     link#1             U        vtnet0
   192.168.1.50       link#1             UHS         lo0
   ```

2. Probar la alcanzabilidad L3 a un endpoint remoto alterando el tamaño del paquete y desactivando la fragmentación IP para descubrir el Path MTU (PMTU):
   ```bash
   ping -c 3 -D -s 1472 1.1.1.1
   ```
   **Salida Esperada:**
   ```text
   PING 1.1.1.1 (1.1.1.1): 1472 data bytes
   1480 bytes from 1.1.1.1: icmp_seq=0 ttl=58 time=12.341 ms
   1480 bytes from 1.1.1.1: icmp_seq=1 ttl=58 time=11.892 ms
   1480 bytes from 1.1.1.1: icmp_seq=2 ttl=58 time=12.105 ms

   --- 1.1.1.1 ping statistics ---
   3 packets transmitted, 3 packets received, 0.0% packet loss
   round-trip min/avg/max/stddev = 11.892/12.112/12.341/0.185 ms
   ```

3. Rastrear la ruta de red y la latencia por salto hacia el destino remoto `8.8.8.8` utilizando sondas ICMP ECHO (superando firewalls que bloquean las sondas UDP predeterminadas):
   ```bash
   traceroute -I 8.8.8.8
   ```
   **Salida Esperada:**
   ```text
   traceroute to 8.8.8.8 (8.8.8.8), 64 hops max, 48 byte packets
    1  192.168.1.1 (192.168.1.1)  1.102 ms  0.893 ms  0.941 ms
    2  10.0.0.1 (10.0.0.1)  4.215 ms  3.890 ms  4.112 ms
    3  172.16.32.1 (172.16.32.1)  8.450 ms  8.120 ms  8.301 ms
    4  dns.google (8.8.8.8)  11.950 ms  11.512 ms  11.780 ms
   ```

4. Agregar manualmente una ruta estática de host para enviar el tráfico destinado a `10.200.1.5` a través del gateway `192.168.1.254`:
   ```bash
   sudo route add -host 10.200.1.5 192.168.1.254
   ```
   **Salida Esperada:**
   ```text
   add host 10.200.1.5: gateway 192.168.1.254
   ```

5. Verificar la ruta de resolución seleccionada por el Radix tree de BSD para el destino `10.200.1.5`:
   ```bash
   route get 10.200.1.5
   ```
   **Salida Esperada:**
   ```text
      route to: 10.200.1.5
   destination: 10.200.1.5
       gateway: 192.168.1.254
        fib: 0
     interface: vtnet0
         flags: <UP,GATEWAY,HOST,DONE,STATIC>
    recvpipe  sendpipe  ssthresh  rtt,msec    mtu        weight    expire
           0         0         0         0      1500         0         0
   ```

#### Preguntas de Verificación (Ejercicio 2)
1. **P2.1:** En el comando `ping -c 3 -D -s 1472 1.1.1.1`, ¿por qué un tamaño de carga útil (payload) ICMP de 1472 bytes verifica un MTU de Ethernet de 1500 bytes?
2. **P2.2:** ¿Qué significa el flag `UGS` en la salida de `netstat -rn`?

---

### Ejercicio 3: Inspección de Servicios y Sockets en Capa de Transporte (L4)

#### Pasos
1. Usar la herramienta nativa de FreeBSD `sockstat` para inspeccionar todos los sockets IPv4 e IPv6 en escucha junto con los PIDs de los demonios vinculados, nombres de comandos y números de puerto:
   ```bash
   sockstat -4 -6 -l
   ```
   **Salida Esperada:**
   ```text
   USER     COMMAND    PID   FD PROTO  LOCAL ADDRESS         FOREIGN ADDRESS
   root     sshd       1204  3  tcp4   *:22                  *:*
   root     sshd       1204  4  tcp6   *:22                  *:*
   bind     named      945   20 tcp4   127.0.0.1:53          *:*
   bind     named      945   21 udp4   127.0.0.1:53          *:*
   www      nginx      1532  6  tcp4   *:80                  *:*
   www      nginx      1532  7  tcp4   *:443                 *:*
   ```

2. Identificar conexiones TCP activas establecidas en el sistema:
   ```bash
   sockstat -4 -c -c
   ```
   **Salida Esperada:**
   ```text
   USER     COMMAND    PID   FD PROTO  LOCAL ADDRESS         FOREIGN ADDRESS
   root     sshd       2041  5  tcp4   192.168.1.50:22       192.168.1.105:54322
   www      nginx      1532  8  tcp4   192.168.1.50:443      10.45.2.14:61204
   ```

3. Consultar estadísticas globales de la pila del protocolo TCP (retransmisiones, conexiones caídas, errores de checksum) a través de `netstat`:
   ```bash
   netstat -s -p tcp
   ```
   **Salida Esperada:**
   ```text
   tcp:
           241045 packets sent
                   198421 data packets (28491204 bytes)
                   114 data packets (150244 bytes) retransmitted
           310941 packets received
                   214091 acks (for 28491000 bytes)
                   0 bad connection attempt requests
                   12 connection drops in rxmt timeout
   ```

4. Realizar una prueba de conexión de puerto y captura de banner en el objetivo remoto `192.168.1.100` en el puerto `80` con un tiempo de espera (timeout) de 3 segundos utilizando `nc` (Netcat):
   ```bash
   nc -v -z -w 3 192.168.1.100 80
   ```
   **Salida Esperada:**
   ```text
   Connection to 192.168.1.100 80 port [tcp/http] succeeded!
   ```

#### Preguntas de Verificación (Ejercicio 3)
1. **P3.1:** ¿En qué se diferencia fundamentalmente `sockstat` de `netstat` al diagnosticar problemas de vinculación de servicios locales?
2. **P3.2:** ¿Qué indica un alto recuento de paquetes de datos retransmitidos en la salida de `netstat -s -p tcp` en un entorno de servidor de base de datos de producción?

---

### Ejercicio 4: Diagnóstico DNS en Capa 7 y Análisis de Captura de Paquetes (BPF / tcpdump)

#### Pasos
1. Ejecutar una consulta de resolución DNS de bajo nivel contra el resolver local `127.0.0.1` para el host `freebsd.org` utilizando `drill` (herramienta de diagnóstico DNS estándar de BSD que reemplaza a `dig`):
   ```bash
   drill freebsd.org @127.0.0.1
   ```
   **Salida Esperada:**
   ```text
   ;; ->>HEADER<<- opcode: QUERY, rcode: NOERROR, id: 41029
   ;; flags: qr rd ra ; QUERY: 1, ANSWER: 2, AUTHORITY: 0, ADDITIONAL: 0
   ;; QUESTION SECTION:
   ;; freebsd.org.  IN  A

   ;; ANSWER SECTION:
   freebsd.org. 3600 IN A 96.47.72.84
   freebsd.org. 3600 IN A 2610:1c1:1:607c::84

   ;; Query time: 14 msec
   ;; SERVER: 127.0.0.1
   ;; WHEN: Thu Aug  6 20:54:10 2026
   ;; MSG SIZE rcvd: 71
   ```

2. Interrogar el mapeo DNS inverso (registro PTR) para la IP `96.47.72.84` utilizando `host`:
   ```bash
   host 96.47.72.84
   ```
   **Salida Esperada:**
   ```text
   84.72.47.96.in-addr.arpa domain name pointer wfe0.bsdgroup.ipv4.freebsd.org.
   ```

3. Capturar tráfico de red en tiempo real en la interfaz `vtnet0`, filtrando específicamente para el tráfico DNS (puerto UDP/TCP 53) sin resolver direcciones IP ni nombres de puertos (`-nn`):
   ```bash
   sudo tcpdump -i vtnet0 -nn -c 4 'port 53'
   ```
   **Salida Esperada:**
   ```text
   tcpdump: verbose output suppressed, use -v or -vv for full protocol decode
   listening on vtnet0, link-type EN10MB (Ethernet), capture size 262144 bytes
   20:54:10.102341 IP 192.168.1.50.53412 > 127.0.0.1.53: 12415+ A? freebsd.org. (29)
   20:54:10.116812 IP 127.0.0.1.53 > 192.168.1.50.53412: 12415 1/0/0 A 96.47.72.84 (45)
   20:54:10.120101 IP 192.168.1.50.61203 > 1.1.1.1.53: 41209+ A? pkg.freebsd.org. (33)
   20:54:10.134219 IP 1.1.1.1.53 > 192.168.1.50.61203: 41209 2/0/0 A 96.47.72.71, A 96.47.72.72 (65)
   4 packets captured
   4 packets received by filter
   0 packets dropped by kernel
   ```

4. Capturar y escribir paquetes TCP SYN (intentos de establecimiento de conexión) en un archivo PCAP binario para análisis fuera de línea (offline):
   ```bash
   sudo tcpdump -i vtnet0 -nn -w /tmp/syn_capture.pcap 'tcp[tcpflags] & tcp-syn != 0'
   ```
   **Salida Esperada:**
   ```text
   tcpdump: listening on vtnet0, link-type EN10MB (Ethernet), capture size 262144 bytes
   ^C12 packets captured
   15 packets received by filter
   0 packets dropped by kernel
   ```

5. Leer y analizar la captura PCAP guardada con marcas de tiempo detalladas en los encabezados y números de secuencia:
   ```bash
   tcpdump -nn -r /tmp/syn_capture.pcap
   ```
   **Salida Esperada:**
   ```text
   reading from file /tmp/syn_capture.pcap, link-type EN10MB (Ethernet)
   20:54:30.412109 IP 192.168.1.50.49152 > 192.168.1.100.80: Flags [S], seq 312451298, win 65535, options [mss 1460,nop,wscale 6,sackOK], length 0
   20:54:31.412501 IP 192.168.1.50.49152 > 192.168.1.100.80: Flags [S], seq 312451298, win 65535, options [mss 1460,nop,wscale 6,sackOK], length 0
   ```

#### Preguntas de Verificación (Ejercicio 4)
1. **P4.1:** ¿Qué significan `rcode: NOERROR` vs `rcode: NXDOMAIN` en la salida de una consulta `drill`?
2. **P4.2:** En `tcpdump`, ¿por qué es crítico pasar `-nn` al diagnosticar problemas bajo condiciones de alto tráfico/carga en producción?
3. **P4.3:** En la salida del Paso 5 (`tcpdump -r /tmp/syn_capture.pcap`), se transmite exactamente el mismo paquete SYN dos veces con un intervalo de ~1 segundo sin recibir un `[S.]` (SYN-ACK). ¿Qué causa raíz a nivel de SRE indica esto?

---

## Soluciones y Respuestas de Verificación

<details>
<summary>Haga clic aquí para desplegar las soluciones detalladas para todas las preguntas de los ejercicios</summary>

### Soluciones del Ejercicio 1
* **R1.1:** `UP` indica el estado administrativo de la interfaz (el administrador del sistema la ha habilitado a través de `ifconfig <interfaz> up`). `RUNNING` indica el estado operativo: el driver del kernel ha asignado búferes de memoria (mbufs), ha configurado los registros de hardware y ha establecido que el hardware de la interfaz está activo y listo para transmitir/recibir tramas. Una interfaz puede estar `UP` pero no `RUNNING` si el cable de enlace está desconectado o si falló la inicialización del driver.
* **R1.2:** Un valor alto de `Ierrs` (Input Errors) típicamente indica tramas corruptas, errores de encuadre (framing errors) o CRCs erróneos causados por cableado defectuoso, transceptores SFP/SFP+ dañados o puertos de switch defectuosos. Un valor alto de `Coll` (Collisions) en Ethernet moderno indica un desajuste de dúplex (duplex mismatch, por ejemplo, un extremo forzado a `half-duplex` mientras que el otro está en `full-duplex` o `autoselect`).

### Soluciones del Ejercicio 2
* **R2.1:** El MTU estándar de Ethernet es de 1500 bytes. Un encabezado IP requiere 20 bytes y un encabezado de ICMP Echo Request estándar requiere 8 bytes ($20 + 8 = 28$ bytes de sobrecarga de protocolo). Por lo tanto:
  $$\text{Payload} (1472) + \text{IP Header} (20) + \text{ICMP Header} (8) = 1500 \text{ bytes (Exact MTU limit)}$$
  El uso de `-D` establece el bit DF (Don't Fragment). Si el tamaño del paquete excede el MTU a lo largo del camino, se devuelve un error ICMP "Fragmentation Needed and DF set".
* **R2.2:** 
  * `U`: La ruta está activa (**Up**).
  * `G`: La ruta utiliza un gateway (**Gateway**, requiere reenvío a un router L3 intermedio).
  * `S`: La ruta se agregó de forma estática (**Statically**, definida manualmente o configurada mediante rutas estáticas en `/etc/rc.conf`, no aprendida dinámicamente a través de RIP/OSPF/BGP).

### Soluciones del Ejercicio 3
* **R3.1:** `netstat` lista los handles de sockets abiertos en toda la pila de red, pero requiere la referencia cruzada de números de inodo de socket a través de herramientas externas para identificar los procesos propietarios. `sockstat` interroga directamente las estructuras del kernel de FreeBSD (Control Blocks de red de `sysctl`) para mapear las vinculaciones de sockets directamente a nombres binarios de procesos (`COMMAND`), Process IDs (`PID`), User IDs (`USER`) y File Descriptors (`FD`) en una sola llamada atómica.
* **R3.2:** Un alto número de retransmisiones TCP indica pérdida de paquetes en la red, congestión severa del enlace o desbordamiento de búfer en switches de red intermedios o anillos NIC del host remoto. Esto fuerza a TCP a activar algoritmos de control de congestión (reduciendo el tamaño de la ventana de congestión `cwnd`), lo que genera picos severos de latencia en las aplicaciones y un menor rendimiento (throughput) de la base de datos.

### Soluciones del Ejercicio 4
* **R4.1:** `NOERROR` indica que el servidor DNS procesó con éxito la consulta y encontró registros coincidentes (o un conjunto de respuestas vacío para un nodo existente). `NXDOMAIN` (Non-Existent Domain) indica que el nombre de dominio consultado no existe en la estructura de árbol raíz de DNS.
* **R4.2:** Sin `-nn`, `tcpdump` realiza búsquedas de DNS inverso síncronas para cada dirección IP capturada y búsquedas de nombres de puertos de servicio (`/etc/services`). Bajo altas tasas de paquetes, esto causa una sobrecarga masiva de CPU, bloquea el bucle de procesamiento de paquetes, llena las colas de búfer del kernel BPF y provoca un descarte severo de paquetes (`packets dropped by kernel`).
* **R4.3:** Los paquetes salientes `[S]` (SYN) consecutivos sin recibir un paquete entrante `[S.]` (SYN-ACK) indican que las solicitudes de handshake TCP están siendo descartadas silenciosamente por un firewall/filtro con estado (stateful filter) aguas arriba (PF/IPFW), o bien que el demonio de destino no está accesible / no está escuchando y las reglas de red descartan las respuestas ICMP Port Unreachable salientes.

</details>

---

## Referencias Oficiales y Enlaces Directos a la Documentación
* [FreeBSD ifconfig(8) Manual Page](https://man.freebsd.org/cgi/man.cgi?ifconfig(8))
* [FreeBSD netstat(1) Manual Page](https://man.freebsd.org/cgi/man.cgi?netstat(1))
* [FreeBSD sockstat(1) Manual Page](https://man.freebsd.org/cgi/man.cgi?sockstat(1))
* [FreeBSD route(8) Manual Page](https://man.freebsd.org/cgi/man.cgi?route(8))
* [FreeBSD tcpdump(1) Manual Page](https://man.freebsd.org/cgi/man.cgi?tcpdump(1))
* [LPI BSD Specialist 702 Objectives Overview](https://www.lpi.org/our-certifications/bsd-specialist-overview/)