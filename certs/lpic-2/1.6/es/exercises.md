# Certificación LPIC-2 (Exámenes 201-450 y 202-450, v4.5)
## Tema 205: Configuración de Red (Examen 201-450) — Manual de Laboratorio de Nivel de Producción y Ejercicios Guiados

**Peso:** 7  
**Referencia Oficial:** [LPI LPIC-2 Exam Objectives](https://www.lpi.org/our-certifications/lpic-2-overview/) | [Linux Foundation iproute2 Documentation](https://wiki.linuxfoundation.org/networking/iproute2) | [Linux Kernel Networking Subsystem Documentation](https://www.kernel.org/doc/Documentation/networking/)

---

### Descripción General de la Arquitectura y Mecánica del Kernel

En las arquitecturas modernas del kernel de Linux (Kernel 4.x/5.x/6.x), la configuración de red ha evolucionado desde la suite heredada `net-tools` (`ifconfig`, `route`, `arp`), que dependía de llamadas al sistema `ioctl()` heredadas, hacia la suite moderna `iproute2` (`ip`, `ss`, `tc`), la cual se comunica directamente con el kernel a través del **Protocolo de Sockets Netlink** (`AF_NETLINK`). 

Netlink proporciona una interfaz IPC basada en sockets asíncrona y full-duplex entre las utilidades del espacio de usuario y los subsistemas del kernel (específicamente `NETLINK_ROUTE`). Esta arquitectura elimina la sobrecarga de rendimiento de las llamadas `ioctl()` tradicionales, permite el monitoreo en tiempo real de eventos del kernel (por ejemplo, `ip monitor`) y expone características avanzadas de subsistemas como Enrutamiento Basado en Políticas (PBR), múltiples tablas de enrutamiento, etiquetado VLAN 802.1Q, software bridging y namespaces de red.

```
+-----------------------------------------------------------------------+
|                              USER SPACE                               |
|   +-------------------+    +--------------------+    +------------+   |
|   |  iproute2 (ip)    |    |  Systemd-networkd  |    |  Netplan   |   |
|   +---------+---------+    +---------+----------+    +-----+------+   |
+-------------|------------------------|---------------------|----------+
              | AF_NETLINK             | AF_NETLINK          | YAML Config
              v                        v                     v
+-----------------------------------------------------------------------+
|                             KERNEL SPACE                              |
|   +---------------------------------------------------------------+   |
|   |                   Netlink Interface Subsystem                 |   |
|   +---------------------------------------------------------------+   |
|   | Core Networking Stack (sk_buff management, socket buffers)    |   |
|   +-------------------+--------------------+----------------------+   |
|   | Policy Routing    | 802.1Q VLAN        | Link Aggregation     |   |
|   | (FIB / rt_tables) | Engine             | (Bonding/Bridging)   |   |
|   +-------------------+--------------------+----------------------+   |
|   |                    Network Device Drivers (NIC)               |   |
+-----------------------------------------------------------------------+
```

---

### Requisitos de Configuración del Laboratorio y Supuestos del Entorno

Todos los ejercicios están diseñados para distribuciones modernas de Linux empresarial (RHEL 8/9, AlmaLinux, Rocky Linux, Debian 11/12, Ubuntu 22.04/24.04 LTS).

**Topologías de Red Prerrequisito:**
- Interfaz Primaria: `eth0` (o `ens192` / `enp0s3`) — IP: `192.168.1.50/24`, Gateway: `192.168.1.1`
- Interfaz Secundaria: `eth1` (o `ens224` / `enp0s8`) — IP: `10.0.0.50/24`, Gateway: `10.0.0.1`
- Se requieren privilegios de Root o `sudo`.

---

### Ejercicio 1: Manipulación de Interfaz a Bajo Nivel, Resolución de Nombres y Configuración Dual-Stack

#### Contexto Teórico y Mecánica
El subsistema de resolución de nombres de dominio en Linux depende del demonio Name Service Switch (NSS) configurado en `/etc/nsswitch.conf`. Cuando un proceso emite una búsqueda de socket (por ejemplo, `getaddrinfo()`), la biblioteca de C (`glibc`) analiza la línea de la base de datos `hosts:` en `/etc/nsswitch.conf`. Si está establecida en `hosts: files dns`, la resolución local a través de `/etc/hosts` tiene prioridad estricta sobre las consultas DNS recursivas enviadas a las direcciones de los resolvers listados en `/etc/resolv.conf`.

#### Pasos de Ejecución Guiados

1. Inspeccionar los estados actuales de los enlaces de red y las estadísticas de sockets utilizando herramientas de `iproute2`.
   ```bash
   ip -stats link show dev eth0
   ```
   *Resultado Esperado:*
   ```text
   2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc fq_codel state UP mode DEFAULT group default qlen 1000
       link/ether 52:54:00:12:34:56 brd ff:ff:ff:ff:ff:ff
       RX:  bytes packets errors dropped overrun mcast
         10485760   12450      0       0       0     0
       TX:  bytes packets errors dropped carrier collsns
          2097152    8500      0       0       0     0
   ```

2. Asignar una dirección IPv4 estática secundaria (alias de IP) y una dirección de unicast global IPv6 a `eth0`.
   ```bash
   sudo ip addr add 192.168.1.75/24 dev eth0 label eth0:1
   sudo ip -6 addr add 2001:db8:1::50/64 dev eth0
   ```

3. Verificar el direccionamiento IP de la interfaz y sus flags.
   ```bash
   ip addr show dev eth0
   ```
   *Resultado Esperado:*
   ```text
   2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc fq_codel state UP group default qlen 1000
       link/ether 52:54:00:12:34:56 brd ff:ff:ff:ff:ff:ff
       inet 192.168.1.50/24 brd 192.168.1.255 scope global eth0
          valid_lft forever preferred_lft forever
       inet 192.168.1.75/24 scope global secondary eth0:1
          valid_lft forever preferred_lft forever
       inet6 2001:db8:1::50/64 scope global 
          valid_lft forever preferred_lft forever
       inet6 fe80::5054:ff:fe12:3456/64 scope link 
          valid_lft forever preferred_lft forever
   ```

4. Modificar los parámetros de la capa física usando `ethtool` para deshabilitar el Hardware Offloading (TCP Segmentation Offload - TSO, Receive Side Coalescing - GRO) para la resolución de problemas de red de baja latencia.
   ```bash
   sudo ethtool -K eth0 tso off gro off
   ethtool -k eth0 | grep -E "(tcp-segmentation|generic-receive)-offload"
   ```
   *Resultado Esperado:*
   ```text
   tcp-segmentation-offload: off
   generic-receive-offload: off
   ```

5. Configurar la persistencia mediante manifiestos canónicos de configuración del sistema:

   *Debian/Ubuntu (`/etc/network/interfaces`):*
   ```ini
   # /etc/network/interfaces
   auto eth0
   iface eth0 inet static
       address 192.168.1.50/24
       gateway 192.168.1.1
       dns-nameservers 1.1.1.1 8.8.8.8

   iface eth0 inet6 static
       address 2001:db8:1::50/64
       gateway 2001:db8:1::1

   auto eth0:1
   iface eth0:1 inet static
       address 192.168.1.75/24
   ```

   *Heredado de RHEL/CentOS/AlmaLinux (`/etc/sysconfig/network-scripts/ifcfg-eth0`):*
   ```ini
   DEVICE=eth0
   BOOTPROTO=none
   ONBOOT=yes
   TYPE=Ethernet
   IPADDR=192.168.1.50
   PREFIX=24
   GATEWAY=192.168.1.1
   DNS1=1.1.1.1
   DNS2=8.8.8.8
   IPV6INIT=yes
   IPV6ADDR=2001:db8:1::50/64
   IPV6_DEFAULTGW=2001:db8:1::1
   ```

   *Netplan (`/etc/netplan/01-netcfg.yaml`):*
   ```yaml
   network:
     version: 2
     renderer: networkd
     ethernets:
       eth0:
         dhcp4: no
         dhcp6: no
         addresses:
           - 192.168.1.50/24
           - 192.168.1.75/24
           - "2001:db8:1::50/64"
         routes:
           - to: default
             via: 192.168.1.1
           - to: default
             via: "2001:db8:1::1"
         nameservers:
           addresses: [1.1.1.1, 8.8.8.8]
   ```

6. Auditar `/etc/nsswitch.conf` y `/etc/resolv.conf` para verificar el orden de resolución de nombres del sistema.
   ```bash
   grep -E "^hosts:" /etc/nsswitch.conf
   cat /etc/resolv.conf
   ```
   *Resultado Esperado:*
   ```text
   hosts:          files dns myhostname
   # Generated by NetworkManager or systemd-resolved
   nameserver 1.1.1.1
   nameserver 8.8.8.8
   options timeout:2 attempts:3 rotate
   ```

---

#### Preguntas de Comprensión — Ejercicio 1

- **Q1.1:** ¿Cuál es la diferencia arquitectónica fundamental entre la herramienta heredada `ifconfig` (de `net-tools`) e `ip addr` (de `iproute2`) con respecto a cómo consultan y manipulan los estados de las interfaces del kernel?
- **Q1.2:** Si un administrador agrega una dirección IP secundaria mediante `ip addr add 192.168.1.75/24 dev eth0` sin proporcionar una etiqueta (`label eth0:1`), ¿cómo mostrarán las herramientas heredadas como `ifconfig` esta dirección secundaria y por qué?
- **Q1.3:** Explique el impacto operativo de la directiva `options rotate` en `/etc/resolv.conf` bajo un alto tráfico de microservicios web.

---

### Ejercicio 2: Enrutamiento Basado en Políticas (PBR) Avanzado y Arquitectura Multi-Homed

#### Contexto Teórico y Mecánica
El enrutamiento IP estándar opera puramente en direcciones de destino a través de una única Base de Información de Reenvío (FIB). En servidores multi-homed (conectados a múltiples ISP o subredes distintas), el enrutamiento predeterminado falla cuando el tráfico que llega a una interfaz secundaria intenta responder a través del gateway predeterminado de la interfaz primaria. Esto causa enrutamiento asimétrico y activa caídas de paquetes por Reverse Path Filtering (`rp_filter`) en kernels con seguridad reinforced.

El Enrutamiento Basado en Políticas (PBR) supera esto desacoplando la selección de rutas de las búsquedas basadas únicamente en el destino. Linux implementa PBR utilizando múltiples tablas de enrutamiento definidas en `/etc/iproute2/rt_tables` combinadas con reglas de la Base de Datos de Políticas de Enrutamiento (RPDB) gestionadas mediante `ip rule`.

```
                        +----------------------------+
                        |   Incoming Packet on eth1  |
                        +--------------+-------------+
                                       |
                                       v
                        +----------------------------+
                        |  RPDB Evaluation (ip rule) |
                        +--------------+-------------+
                                       |
                  +--------------------+--------------------+
                  | Match Rule:                             | Match Rule:
                  | "from 10.0.0.50 lookup T2"              | Default fallback
                  v                                         v
    +---------------------------+             +---------------------------+
    | Routing Table 102 (T2)    |             | Main Routing Table        |
    | Gateway: 10.0.0.1 (eth1)  |             | Gateway: 192.168.1.1(eth0)|
    +-------------+-------------+             +-------------+-------------+
                  |                                         |
                  v                                         v
    +---------------------------+             +---------------------------+
    | Symmetric Outbound (eth1) |             | Standard Outbound (eth0)  |
    +---------------------------+             +---------------------------+
```

#### Pasos de Ejecución Guiados

1. Ver las reglas predeterminadas de la RPDB.
   ```bash
   ip rule show
   ```
   *Resultado Esperado:*
   ```text
   0:	from all lookup local
   32766:	from all lookup main
   32767:	from all lookup default
   ```

2. Registrar tablas de enrutamiento personalizadas en `/etc/iproute2/rt_tables`.
   ```bash
   sudo sh -c 'echo "101 T1" >> /etc/iproute2/rt_tables'
   sudo sh -c 'echo "102 T2" >> /etc/iproute2/rt_tables'
   tail -n 2 /etc/iproute2/rt_tables
   ```
   *Resultado Esperado:*
   ```text
   101 T1
   102 T2
   ```

3. Poblar la tabla `T1` (para `eth0` / `192.168.1.0/24`) y la tabla `T2` (para `eth1` / `10.0.0.0/24`) con rutas de red y reglas de gateway.
   ```bash
   sudo ip route add 192.168.1.0/24 dev eth0 src 192.168.1.50 table T1
   sudo ip route add default via 192.168.1.1 dev eth0 table T1

   sudo ip route add 10.0.0.0/24 dev eth1 src 10.0.0.50 table T2
   sudo ip route add default via 10.0.0.1 dev eth1 table T2
   ```

4. Crear políticas RPDB para vincular direcciones IP de origen a sus respectivas tablas de enrutamiento.
   ```bash
   sudo ip rule add from 192.168.1.50 table T1 pref 100
   sudo ip rule add from 10.0.0.50 table T2 pref 200
   ```

5. Verificar el contenido de las tablas y la lógica de prioridad de las reglas RPDB activas.
   ```bash
   ip rule show
   ip route show table T2
   ```
   *Resultado Esperado:*
   ```text
   0:	from all lookup local
   100:	from 192.168.1.50 lookup T1
   200:	from 10.0.0.50 lookup T2
   32766:	from all lookup main
   32767:	from all lookup default

   default via 10.0.0.1 dev eth1 
   10.0.0.0/24 dev eth1 scope link src 10.0.0.50
   ```

6. Simular búsquedas de rutas desde el espacio del kernel para probar el comportamiento de PBR.
   ```bash
   ip route get 8.8.8.8 from 10.0.0.50
   ```
   *Resultado Esperado:*
   ```text
   8.8.8.8 via 10.0.0.1 dev eth1 table T2 src 10.0.0.50 uid 0
       cache
   ```

7. Auditar la configuración de Reverse Path Filtering del kernel para evitar la pérdida de paquetes asimétricos.
   ```bash
   sysctl net.ipv4.conf.all.rp_filter net.ipv4.conf.eth1.rp_filter
   ```
   *Resultado Esperado:*
   ```text
   net.ipv4.conf.all.rp_filter = 2
   net.ipv4.conf.eth1.rp_filter = 2
   ```
   *(Nota: El valor `2` habilita Loose Reverse Path Filtering, el cual acepta paquetes si la dirección de origen es alcanzable a través de CUALQUIER interfaz, necesario para enrutamiento asimétrico o PBR).*

---

#### Preguntas de Comprensión — Ejercicio 2

- **Q2.1:** ¿Cuál es la función técnica del parámetro `pref` (preferencia/prioridad) en `ip rule add` y qué sucede si dos reglas tienen prioridades idénticas?
- **Q2.2:** ¿Cuál es la diferencia crítica entre el filtrado de ruta inversa estricto (`rp_filter = 1`) y laxo (`rp_filter = 2`) en un entorno de servidor Linux multi-homed?
- **Q2.3:** En `/etc/iproute2/rt_tables`, ¿cuáles son los nombres/IDs de tablas reservados y qué rol juega la tabla `local` en el bucle de procesamiento del kernel?

---

### Ejercicio 3: Agregación Avanzada de la Capa de Enlace (Bonding/LACP), Bridging y Etiquetado VLAN 802.1Q

#### Contexto Teórico y Mecánica
Los hosts de virtualización empresariales (KVM/QEMU) requieren alta disponibilidad en la Capa 2 y segmentación de red. 
- **Bonding (LACP Modo 4 / IEEE 802.3ad):** Combina múltiples enlaces físicos en un solo enlace lógico, multiplexando tramas según políticas de hash de transmisión (Capa 2, Capa 2+3 o Capa 3+4). Requiere configuración LACP del lado del switch.
- **Etiquetado VLAN 802.1Q:** Inserta una cabecera VLAN de 4 bytes (TPID `0x8100` + ID de VLAN de 12 bits) en las tramas Ethernet.
- **Bridge por Software de Linux:** Actúa como un switch ethernet virtual IEEE 802.1D de Capa 2 dentro del kernel, reenviando tramas mediante una tabla interna de aprendizaje de direcciones MAC (FDB - Forwarding Database).

```
                      +-----------------------------------+
                      |      Virtual Bridge (br0)         |
                      |      IP: 10.200.0.10/24           |
                      +-----------------+-----------------+
                                        |
                                        v
                      +-----------------+-----------------+
                      |     VLAN Sub-interface            |
                      |     bond0.200 (VLAN ID 200)     |
                      +-----------------+-----------------+
                                        |
                                        v
                      +-----------------+-----------------+
                      |     Bonded Master Interface       |
                      |     bond0 (Mode 4 - 802.3ad)     |
                      +--------+----------------+---------+
                               |                |
             +-----------------+                +-----------------+
             v                                                    v
+------------------------+                              +------------------------+
| Slave: eth1            |                              | Slave: eth2            |
+------------------------+                              +------------------------+
```

#### Pasos de Ejecución Guiados

1. Cargar el módulo de bonding del kernel con parámetros explícitos.
   ```bash
   sudo modprobe bonding
   ```

2. Crear un Bond LACP (`bond0`), establecer la política de hash en `layer3+4` para una distribución óptima de múltiples flujos, agregar interfaces esclavas y levantar el enlace.
   ```bash
   sudo ip link add dev bond0 type bond mode 802.3ad miimon 100 xmit_hash_policy layer3+4
   sudo ip link set dev eth1 master bond0
   sudo ip link set dev eth2 master bond0
   sudo ip link set dev eth1 up
   sudo ip link set dev eth2 up
   sudo ip link set dev bond0 up
   ```

3. Consultar el estado operativo del bond a través de las interfaces del sistema de archivos `/proc`.
   ```bash
   cat /proc/net/bonding/bond0
   ```
   *Resultado Esperado:*
   ```text
   Ethernet Channel Bonding Driver: v5.15.0-89-generic

   Bonding Mode: IEEE 802.3ad Dynamic link aggregation
   Transmit Hash Policy: layer3+4 (1)
   MII Status: up
   MII Polling Interval (ms): 100
   Up Delay (ms): 0
   Down Delay (ms): 0
   Peer Encryption Key: 

   802.3ad info
   LACP rate: slow
   Min links: 0
   Aggregator selection policy (ad_select): bandwidth
   System priority: 65535
   System MAC address: 52:54:00:ab:cd:ef
   Active Aggregator Info:
   	Aggregator ID: 1
   	Number of ports: 2
   	Actor Key: 17
   	Partner Key: 1

   Slave Interface: eth1
   MII Status: up
   Speed: 10000 Mbps
   Duplex: full
   Link Failure Count: 0
   Permanent HW addr: 52:54:00:11:22:33
   Aggregator ID: 1

   Slave Interface: eth2
   MII Status: up
   Speed: 10000 Mbps
   Duplex: full
   Link Failure Count: 0
   Permanent HW addr: 52:54:00:44:55:66
   Aggregator ID: 1
   ```

4. Crear una interfaz VLAN etiquetada IEEE 802.1Q (`bond0.200`) sobre el enlace bond troncalizado.
   ```bash
   sudo ip link add link bond0 name bond0.200 type vlan id 200
   sudo ip link set dev bond0.200 up
   ```

5. Crear un bridge por software virtual (`br0`), adjuntar la interfaz VLAN `bond0.200` a él y asignar una dirección IP a la interfaz del bridge.
   ```bash
   sudo ip link add name br0 type bridge
   sudo ip link set dev bond0.200 master br0
   sudo ip addr add 10.200.0.10/24 dev br0
   sudo ip link set dev br0 up
   ```

6. Inspeccionar la Base de Datos de Reenvío del Bridge (FDB) y el estado del enlace del bridge.
   ```bash
   ip link show dev br0
   bridge fdb show dev bond0.200
   ```
   *Resultado Esperado:*
   ```text
   7: br0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP group default qlen 1000
       link/ether 52:54:00:ab:cd:ef brd ff:ff:ff:ff:ff:ff
   52:54:00:ab:cd:ef master br0 permanent
   3c:ec:ef:99:88:77 vlan 200 master br0
   ```

---

#### Preguntas de Comprensión — Ejercicio 3

- **Q3.1:** ¿Cuál es el mecanismo técnico de `miimon` en el controlador de bonding de Linux y qué sucede si `miimon` se establece en `0`?
- **Q3.2:** ¿Por qué `xmit_hash_policy layer3+4` es superior a `layer2` en un entorno LACP de alta densidad conectado a un switch core?
- **Q3.3:** En un escenario de bridge por software para redes de máquinas virtuales, ¿por qué la dirección IP debe asignarse a la interfaz del bridge (`br0`) en lugar de a las interfaces miembros (`eth0` o `bond0.200`)?

---

### Ejercicio 4: Diagnóstico de Red en Producción, Análisis de Estado de Sockets y Captura de Paquetes

#### Contexto Teórico y Mecánica
El diagnóstico moderno de red en Linux requiere comprender los estados de los sockets (`TCP_ESTABLISHED`, `TIME_WAIT`, `CLOSE_WAIT`), la asignación del búfer de sockets del kernel (`rmem`, `wmem`) y el procesamiento de tipos de ICMP (`Time Exceeded`, `Destination Unreachable`). 

Herramientas como `ss` extraen información de diagnóstico de sockets directamente de la memoria del kernel utilizando módulos de la familia netlink `sock_diag`, lo que hace que `ss` sea órdenes de magnitud más rápido que la herramienta heredada `netstat` (la cual analizaba iterativamente `/proc/net/tcp`).

#### Pasos de Ejecución Guiados

1. Analizar los sockets de escucha TCP activos, los mapeos de procesos y el mapeo numérico de puertos utilizando `ss`.
   ```bash
   sudo ss -tlpn
   ```
   *Resultado Esperado:*
   ```text
   State      Recv-Q Send-Q Local Address:Port  Peer Address:Port Process                                 
   LISTEN     0      128    0.0.0.0:22          0.0.0.0:*         users:(("sshd",pid=912,fd=3))           
   LISTEN     0      511    0.0.0.0:80          0.0.0.0:*         users:(("nginx",pid=1450,fd=6))         
   LISTEN     0      4096   127.0.0.1:6379      0.0.0.0:*         users:(("redis-server",pid=1120,fd=6))  
   ```

2. Inspeccionar la asignación interna de memoria del búfer de sockets TCP y los algoritmos de control de congestión TCP para conexiones establecidas.
   ```bash
   ss -t-i -e 'sport = :http or dport = :http'
   ```
   *Resultado Esperado:*
   ```text
   ESTAB 0 0 192.168.1.50:80 192.168.1.105:54322
        cubic wscale:7,7 rto:200 rtt:0.12/0.04 ato:40 mss:1460 rcvspace:14600 ssthresh:10 cwnd:10
   ```

3. Realizar la resolución de problemas de Descubrimiento de MTU del Camino (Path MTU Discovery) usando `tracepath` para detectar agujeros negros de PMTU (Path MTU) causados por el bloqueo de ICMP Tipo 3 Código 4 (`Fragmentation Needed`).
   ```bash
   tracepath 8.8.8.8
   ```
   *Resultado Esperado:*
   ```text
   1?: [LOCALHOST]                      pmtu 1500
   1:  192.168.1.1                                            0.852ms 
   1:  192.168.1.1                                            0.741ms pmtu 1492
   2:  10.254.0.1                                             4.120ms 
   3:  dns.google                                               9.450ms reached
       Resume: pmtu 1492 hops 3 back 56
   ```

4. Ejecutar filtrado de captura de paquetes a bajo nivel usando `tcpdump` con sintaxis BPF (Berkeley Packet Filter) pura para aislar fallos de resolución ARP y SYN floods de TCP.
   ```bash
   sudo tcpdump -i eth0 -nn -e -c 5 'arp or (tcp[tcpflags] & (tcp-syn) != 0)'
   ```
   *Resultado Esperado:*
   ```text
   10:15:30.123456 52:54:00:12:34:56 > ff:ff:ff:ff:ff:ff, ethertype ARP (0x0806), length 42: Request who-has 192.168.1.1 tell 192.168.1.50, length 28
   10:15:30.124111 52:54:00:aa:bb:cc > 52:54:00:12:34:56, ethertype ARP (0x0806), length 42: Reply 192.168.1.1 is-at 52:54:00:aa:bb:cc, length 28
   10:15:32.456789 52:54:00:12:34:56 > 52:54:00:aa:bb:cc, ethertype IPv4 (0x0800), length 74: 192.168.1.50.48912 > 1.1.1.1.53: Flags [S], seq 312458901, win 64240, options [mss 1460,sackOK,TS val 1294021 ecr 0,nop,wscale 7], length 0
   ```

5. Consultar las tablas de caché de vecinos ARP/NDP y purgar entradas ARP obsoletas.
   ```bash
   ip neighbor show
   sudo ip neighbor flush dev eth0 state stale
   ```
   *Resultado Esperado:*
   ```text
   192.168.1.1 dev eth0 lladdr 52:54:00:aa:bb:cc REACHABLE
   192.168.1.105 dev eth0 lladdr 3c:ec:ef:11:22:33 STALE
   ```

6. Inspeccionar los contadores de errores de interfaz de red del kernel y las métricas de paquetes descartados en sockets.
   ```bash
   netstat -s | grep -i "buffer errors"
   sudo nstat -az TcpExtListenDrop TcpExtListenOverflow
   ```
   *Resultado Esperado:*
   ```text
   # nstat -az TcpExtListenDrop TcpExtListenOverflow
   TcpExtListenDrop                0                  0.0
   TcpExtListenOverflow            0                  0.0
   ```

---

#### Preguntas de Comprensión — Ejercicio 4

- **Q4.1:** En la salida de `ss -tlpn`, ¿qué significan específicamente las columnas `Recv-Q` y `Send-Q` para sockets TCP en estado **LISTEN** en comparación con sockets en estado **ESTABLISHED**?
- **Q4.2:** Explique cómo un ataque TCP SYN Flood hace que `TcpExtListenOverflow` se incremente y qué parámetros del kernel se pueden ajustar para mitigar este problema.
- **Q4.3:** ¿Cómo determina `tracepath` el Path MTU sin requerir privilegios de root, a diferencia del `traceroute -I` tradicional?

---

<details>
<summary><strong>Respuestas y Explicaciones Detalladas</strong></summary>

### Soluciones del Ejercicio 1

- **A1.1:** `ifconfig` se basa en llamadas al sistema heredadas `ioctl(SIOCGIFFLAGS, SIOCGIFADDR)`, las cuales son sincrónicas, lentas y no pueden manejar construcciones modernas del kernel como múltiples direcciones IP por interfaz sin crear interfaces de pseudo-alias (`eth0:1`). `ip` utiliza sockets netlink de alto rendimiento (`AF_NETLINK`, `NETLINK_ROUTE`), que se comunican de forma asíncrona con las estructuras del kernel, soportando de forma nativa múltiples direcciones primarias/secundarias, namespaces y tablas de enrutamiento avanzadas sin hacks de alias heredados.
- **A1.2:** La herramienta heredada `ifconfig` no mostrará la dirección secundaria en absoluto a menos que se etiquete explícitamente con una etiqueta heredada (`label eth0:X`) durante su creación. `ifconfig` analiza `/proc/net/dev` y estructuras `ioctl` heredadas que solo reconocen aliases etiquetados. Sin embargo, `ip addr` consulta netlink directamente y muestra todas las direcciones IPv4/IPv6 primarias y secundarias adjuntas al dispositivo, independientemente de las etiquetas.
- **A1.3:** `options rotate` indica al resolver de la biblioteca de C (`getaddrinfo` / `res_init`) que distribuya las consultas en modo round-robin entre todas las IP de `nameserver` listadas en `/etc/resolv.conf`. En arquitecturas de microservicios, esto distribuye la carga de consultas DNS por igual entre múltiples resolvers recursivos ascendentes, evitando que un solo servidor DNS se convierta en un cuello de botella de CPU.

---

### Soluciones del Ejercicio 2

- **A2.1:** `pref` (o `priority`) define el orden de procesamiento en la Base de Datos de Políticas de Enrutamiento (RPDB), evaluado desde el valor de preferencia numérico más bajo hasta el más alto (0 a 32767). Si dos reglas tienen valores de `pref` idénticos, el comportamiento de evaluación de las reglas no es determinista (depende del orden de inserción en las listas de netlink), lo que puede causar una selección de ruta de enrutamiento aleatoria.
- **A2.2:** 
  - **Modo Estricto (`rp_filter = 1`):** El kernel verifica si la dirección IP de origen del paquete entrante es alcanzable a través de la *exactamente misma interfaz* por la que llegó el paquete, de acuerdo con la FIB principal. Si no es así, el paquete se descarta silenciosamente. Esto interrumpe el multi-homing/PBR.
  - **Modo Laxo (`rp_filter = 2`):** El kernel solo verifica si la IP de origen es alcanzable a través de *cualquier* interfaz de red activa en el host. Si es alcanzable a través de cualquier interfaz, el paquete es aceptado. El modo laxo es obligatorio cuando se utiliza asimetría o enrutamiento por políticas.
- **A2.3:** 
  - **IDs Reservados:** `255 (local)`, `254 (main)`, `253 (default)`, `0 (unspec)`.
  - **Tabla `local` (255):** Tabla de máxima prioridad evaluada en primer lugar por el kernel. Contiene rutas para direcciones de loopback del host local (`127.0.0.1`), IP de interfaces locales y direcciones de broadcast. Maneja paquetes con destino local antes de que se procese cualquier regla de enrutamiento por políticas personalizada o enrutamiento predeterminado.

---

### Soluciones del Ejercicio 3

- **A3.1:** `miimon` (Media Independent Interface Monitor) especifica la frecuencia en milisegundos a la que el controlador de bonding inspecciona el estado del enlace físico (a través de consultas MII/ethtool). Si `miimon = 0`, el monitoreo del enlace se deshabilita por completo; el controlador nunca detectará desconexiones físicas de cables o fallos de enlace, lo que impedirá la conmutación por error (failover).
- **A3.2:** El hashing por `layer2` solo utiliza las direcciones MAC de origen y destino. En un entorno de red enrutado donde todo el tráfico saliente pasa a través de la dirección MAC de un único router gateway, todo el tráfico genera el mismo hash hacia la misma interfaz esclava, haciendo que LACP sea ineficaz. `layer3+4` aplica hash a las direcciones IP de origen/destino combinadas con los puertos TCP/UDP de origen/destino, asegurando una distribución granular del flujo entre todos los esclavos físicos, incluso cuando se comunica con un solo router ascendente.
- **A3.3:** Un bridge por software (`br0`) agrega interfaces esclavas en un único dominio de broadcast de Capa 2. Las interfaces esclavas conectadas a un bridge funcionan en modo promiscuo con sus capacidades individuales de Capa 3 desactivadas. Asignar una dirección IP directamente a una interfaz esclava conectada a un bridge impide que el kernel adjunte los controladores de socket adecuados al maestro del bridge, lo que resulta en paquetes no enrutables y un procesamiento ARP roto.

---

### Soluciones del Ejercicio 4

- **A4.1:** 
  - **Estado LISTEN:** `Recv-Q` indica el número de solicitudes de conexión actualmente en la Cola de Aceptación TCP esperando a que la aplicación llame a `accept()`. `Send-Q` indica la capacidad máxima (límite de backlog) de la Cola de Aceptación.
  - **Estado ESTABLISHED:** `Recv-Q` indica los bytes recibidos en el búfer de recepción del socket esperando ser leídos por `read()`. `Send-Q` indica los bytes enviados pero aún no reconocidos (ACK) por el par TCP remoto.
- **A4.2:** Un ataque TCP SYN Flood llena la Cola de Backlog SYN con handshakes de 3 vías incompletos (`SYN_RECV`). Cuando la cola se llena, las solicitudes de conexión entrantes no se pueden encolar y se descartan, incrementando `TcpExtListenOverflow` y `TcpExtListenDrop`. La mitigación requiere establecer `net.ipv4.tcp_syncookies = 1` (habilitando SYN Cookies para evitar la asignación de estado) y aumentar `net.core.somaxconn` y `net.ipv4.tcp_max_syn_backlog`.
- **A4.3:** `tracepath` envía paquetes UDP con la flag IP `DF` (Don't Fragment) habilitada, comenzando con una MTU asumida (generalmente 1500). Cuando un router a lo largo del camino no puede reenviar el paquete debido a una MTU más pequeña, descarta el paquete y devuelve una respuesta ICMP `Destination Unreachable` (Tipo 3) con código `Fragmentation Needed and DF set` (Código 4), que contiene el valor de MTU del siguiente salto. `tracepath` analiza esta respuesta ICMP desde sockets UDP no privilegiados estándar sin requerir permisos de socket raw (`CAP_NET_RAW`) necesarios para `traceroute -I`.

</details>