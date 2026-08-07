# Guía de Estudio de Arquitectura de Plataforma y SRE Avanzado: LPI 702-100
## Tema 714.2: Configuración Básica de Red (Peso del Examen: 3)

---

## 1. Visión General a Nivel de Kernel y Arquitectura

En los sistemas operativos BSD (FreeBSD, OpenBSD, NetBSD), la arquitectura de red está centrada en la kernel socket layer y la estructura de datos **`ifnet`**. Comprender cómo el kernel procesa paquetes y gestiona los estados de las interfaces es crítico para los SREs senior que operan infraestructura de producción.

```
                      +-----------------------------------+
                      |      Userland Applications        |
                      |   (dhclient, ifconfig, route)     |
                      +-----------------+-----------------+
                                        |  ioctl(2) / Routing Sockets (PF_ROUTE)
                                        v
+-----------------------------------------------------------------------------------+
| FreeBSD / OpenBSD / NetBSD Kernel                                                 |
|                                                                                   |
|  +--------------------+     +---------------------+     +----------------------+  |
|  |   Socket Layer     | <-> |   TCP/IP Stack      | <-> |  Kernel Routing Table|  |
|  |   (AF_INET / v6)   |     | (inet4 / inet6)     |     |    (radix tree)      |  |
|  +--------------------+     +----------+----------+     +----------------------+  |
|                                        |                                          |
|                                        v                                          |
|                             +--------------------+                                |
|                             |  struct ifnet      | (Interface Control Block)      |
|                             |  - if_flags        |                                |
|                             |  - if_addrhead     |                                |
|                             |  - if_ioctl        |                                |
|                             +----------+---------+                                |
+----------------------------------------|------------------------------------------+
                                         |
                                         v
                              +--------------------+
                              | Hardware Device    |
                              | Driver (em0, wm0)  |
                              +--------------------+
```

### Conceptos Técnicos Clave:
*   **`struct ifnet` del Kernel**: Cada dispositivo de red físico y virtual está representado en el kernel de BSD por una instancia de `struct ifnet`. Mantiene el estado de la interfaz, queue length, MTU, flags operacionales (`IFF_UP`, `IFF_BROADCAST`, `IFF_RUNNING`, `IFF_MULTICAST`), y punteros a funciones para operaciones de link-layer.
*   **Control de Configuración de Interfaz (`ioctl(2)`)**: Las utilidades de userland como `ifconfig` se comunican directamente con la stack de red del kernel utilizando llamadas al sistema como `ioctl(2)` con parámetros de solicitud como `SIOCSIFADDR` (set interface address), `SIOCSIFNETMASK` (set netmask), o `SIOCSIFFLAGS` (set flags como UP/DOWN).
*   **Hooks de Configuración Persistente**: Los sistemas BSD desacoplan la configuración del kernel en runtime de la persistencia de almacenamiento:
    *   **FreeBSD**: Utiliza `/etc/rc.conf` analizado por `/etc/rc.d/netif` y scripts `subr`.
    *   **OpenBSD**: Utiliza archivos declarativos de definición de interfaz llamados `/etc/hostname.<if>` analizados por `netstart(8)`.
    *   **NetBSD**: Utiliza `/etc/ifconfig.<if>` analizado por `/etc/rc.d/network`.
*   **Reglas de Subnetting de IP Alias**: En los kernels de BSD, asignar múltiples direcciones IPv4 (aliases) en el mismo broadcast domain requiere configurar la netmask del alias en **`255.255.255.255`** (`/32`). Usar un tamaño de prefijo completo (por ejemplo, `/24`) en un alias duplica la entrada de ruta de subred en la radix routing table del kernel, lo que conduce a colisiones de rutas y rutas de egreso de paquetes impredecibles.
*   **Arquitectura DHCP (`dhclient`)**: El cliente ISC DHCP (`dhclient`) opera a través de sockets BPF (Berkeley Packet Filter) para elaborar frames Ethernet/UDP raw antes de que una dirección IP sea vinculada oficialmente. El ciclo de vida de estados de ejecución sigue `SELECTING` -> `REQUESTING` -> `BOUND` -> `RENEWING` -> `REBINDING`.

---

## 2. Fuentes de Referencia Oficiales
*   **Visión General de la Certificación LPI BSD Specialist**: [https.www.lpi.org/our-certifications/bsd-specialist-overview/](https://www.lpi.org/our-certifications/bsd-specialist-overview/)
*   **Manual de FreeBSD - Basicos de Red**: [https://docs.freebsd.org/en/books/handbook/network/](https://docs.freebsd.org/en/books/handbook/network/)
*   **Página de Manual de FreeBSD `ifconfig(8)`**: [https://man.freebsd.org/cgi/man.cgi?query=ifconfig](https://man.freebsd.org/cgi/man.cgi?query=ifconfig)
*   **Página de Manual de OpenBSD `hostname.if(5)`**: [https://man.openbsd.org/hostname.if.5](https://man.openbsd.org/hostname.if.5)
*   **Guía de Configuración de Red de NetBSD**: [https://www.netbsd.org/docs/network/](https://www.netbsd.org/docs/network/)

---

## 3. Ejercicios Prácticos Guiados de Producción

### Ejercicio 1: Control de Interfaz en Runtime, Subnetting CIDR y Gestión de Aliases

En este ejercicio, manipularás interfaces de red en runtime utilizando `ifconfig`, vincularás direcciones IP primarias, calcularás límites de broadcast y agregarás de forma segura aliases de interfaz IPv4/IPv6 sin corromper la tabla de enrutamiento del kernel.

#### Paso 1.1: Inspeccionar interfaces activas y flags del kernel
Ejecutá `ifconfig` para auditar los parámetros actuales de la interfaz en un objetivo FreeBSD (interfaz `em0`):

```bash
# ifconfig em0
```

*Salida esperada:*
```text
em0: flags=8843<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST> metric 0 mtu 1500
	options=481009b<RXCSUM,TXCSUM,VLAN_MTU,VLAN_HWTAGGING,VLAN_HWCSUM,WOL_UCAST,WOL_MCAST,WOL_MAGIC,VLAN_HWFILTER>
	ether 52:54:00:12:34:56
	inet 10.0.2.15 netmask 0xffffff00 broadcast 10.0.2.255
	inet6 fe80::5054:ff:fe12:3456%em0 prefixlen 64 scopeid 0x1
	media: Ethernet autoselect (1000baseT <full-duplex>)
	status: active
	nd6 options=23<PERFORMNUD,ACCEPT_RTADV,AUTO_LINKLOCAL>
```

#### Paso 1.2: Asignar una dirección IPv4 estática primaria con netmask explícita
Asigná la IP `192.168.10.15/24` a la interfaz `em0`. Observá el uso de la notación CIDR y la representación hexadecimal en el estado del kernel de BSD.

```bash
# ifconfig em0 inet 192.168.10.15/24 up
# ifconfig em0 inet
```

*Salida esperada:*
```text
em0: flags=8843<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST> metric 0 mtu 1500
	inet 192.168.10.15 netmask 0xffffff00 broadcast 192.168.10.255
```

#### Paso 1.3: Agregar de forma segura un Alias IPv4 secundario
Para vincular una IP secundaria `192.168.10.20` en la misma subred, aplicá la regla de máscara `/32` (`255.255.255.255`) obligatoria en BSD para evitar colisiones en la tabla de enrutamiento del kernel.

```bash
# ifconfig em0 inet 192.168.10.20 netmask 255.255.255.255 alias
# ifconfig em0 inet
```

*Salida esperada:*
```text
em0: flags=8843<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST> metric 0 mtu 1500
	inet 192.168.10.15 netmask 0xffffff00 broadcast 192.168.10.255
	inet 192.168.10.20 netmask 0xffffffff broadcast 192.168.10.20
```

#### Paso 1.4: Eliminar un alias de interfaz
Eliminá el alias vinculado en el Paso 1.3:

```bash
# ifconfig em0 inet 192.168.10.20 -alias
# ifconfig em0 inet
```

*Salida esperada:*
```text
em0: flags=8843<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST> metric 0 mtu 1500
	inet 192.168.10.15 netmask 0xffffff00 broadcast 192.168.10.255
```

---

#### Preguntas de Verificación (Ejercicio 1)

1. **Pregunta 1.1**: ¿Qué sucede dentro de la radix routing table del kernel de BSD si un administrador configura un alias IPv4 en `em0` usando `192.168.10.20 netmask 255.255.255.0` en lugar de `255.255.255.255` cuando `192.168.10.15/24` ya está activo en `em0`?
2. **Pregunta 1.2**: En la salida de `ifconfig em0`, ¿qué representa el flag `SIMPLEX` desde la perspectiva de la arquitectura de la stack de red?

---

### Ejercicio 2: Sintaxis de Configuración Persistente de Red entre Distintos BSD

La configuración persistente difiere significativamente entre FreeBSD, OpenBSD y NetBSD. En este ejercicio, elaborarás manifiestos de configuración sintácticamente válidos para cada variante.

#### Paso 2.1: Configurar red persistente en FreeBSD (`/etc/rc.conf`)
Abrí `/etc/rc.conf` y anexioná configuraciones de red estáticas, incluyendo aliasing de interfaz y ajustes de gateway por defecto.

```bash
# cat << 'EOF' >> /etc/rc.conf
# Primary interface configuration (FreeBSD syntax)
hostname="bsd-node01.production.internal"
ifconfig_em0="inet 10.100.5.50 netmask 255.255.250.0"
ifconfig_em0_alias0="inet 10.100.5.51 netmask 255.255.255.255"
ifconfig_em0_alias1="inet 10.100.5.52 netmask 255.255.255.255"
defaultrouter="10.100.4.1"
EOF
```

Reiniciá los servicios de red en el runtime de FreeBSD para validar la sintaxis de parseo:

```bash
# service netif restart && service routing restart
```

*Salida esperada:*
```text
Stopping Network: em0.
Starting Network: em0.
add net default: gateway 10.100.4.1
```

#### Paso 2.2: Configurar red persistente en OpenBSD (`/etc/hostname.em0`)
En OpenBSD, la persistencia de la interfaz es impulsada por convenciones de nombres de archivos (`/etc/hostname.<if>`). Creá `/etc/hostname.em0` con IP primaria, aliases y opciones de respaldo DHCP.

```bash
# cat << 'EOF' > /etc/hostname.em0
inet 10.100.5.50 255.255.250.0 10.100.7.255
inet alias 10.100.5.51 255.255.255.255
inet alias 10.100.5.52 255.255.255.255
up
EOF

# cat << 'EOF' > /etc/mygate
10.100.4.1
EOF
```

Ejecutá el script de recarga de red de OpenBSD:

```bash
# sh /etc/netstart em0
```

*Salida esperada:*
```text
netstart: configuring em0
```

#### Paso 2.3: Configurar red persistente en NetBSD (`/etc/ifconfig.wm0`)
En NetBSD, `/etc/ifconfig.<if>` almacena parámetros pasados directamente a `ifconfig` durante el init del sistema.

```bash
# cat << 'EOF' > /etc/ifconfig.wm0
up
10.100.5.50 netmask 255.255.250.0 broadcast 10.100.7.255
alias 10.100.5.51 netmask 255.255.255.255
EOF

# cat << 'EOF' >> /etc/rc.conf
mygate="10.100.4.1"
EOF
```

Reiniciá el subsistema de red de NetBSD:

```bash
# /etc/rc.d/network restart
```

*Salida esperada:*
```text
Stopping network elements: wm0.
Starting network elements: wm0.
```

---

#### Preguntas de Verificación (Ejercicio 2)

1. **Pregunta 2.1**: En el `/etc/rc.conf` de FreeBSD, ¿qué sucede si especificás `ifconfig_em0="DHCP"` junto con `defaultrouter="10.100.4.1"`? ¿Qué componente establece la ruta por defecto al arrancar?
2. **Pregunta 2.2**: Compará el `/etc/mygate` de OpenBSD y el `defaultrouter` de FreeBSD. ¿Cómo maneja NetBSD los gateways por defecto estáticos de forma persistente?

---

### Ejercicio 3: Mecánica del Cliente DHCP, Diagnóstico de Leases y Overrides

En este ejercicio, inspeccionarás la mecánica operativa de `dhclient`, analizarás archivos de lease en `/var/db/` y configurarás `/etc/dhclient.conf` para anular (override) parámetros ofrecidos por el servidor, como los servidores de resolución DNS.

#### Paso 3.1: Ejecutar ciclos de release y request de DHCP en runtime
Liberá (release) el lease actual en `em0` e iniciá `dhclient` en modo debug en primer plano (foreground) para observar el ciclo DORA (Discover, Offer, Request, Acknowledge).

```bash
# dhclient -r em0
# dhclient -d em0
```

*Salida esperada:*
```text
DHCPRELEASE on em0 to 192.168.1.1 port 67
DHCPDISCOVER on em0 to 255.255.255.255 port 67 interval 3
DHCPOFFER from 192.168.1.1
DHCPREQUEST on em0 to 255.255.255.255 port 67
DHCPACK from 192.168.1.1 via em0
bound to 192.168.1.105 -- renewal in 43200 seconds.
^C
```

#### Paso 3.2: Inspeccionar la base de datos de estado del lease activo
Examiná el estado del lease activo registrado por `dhclient` en disco:

```bash
# cat /var/db/dhclient.leases.em0
```

*Salida esperada:*
```text
lease {
  interface "em0";
  fixed-address 192.168.1.105;
  option subnet-mask 255.255.255.0;
  option routers 192.168.1.1;
  option dhcp-lease-time 86400;
  option dhcp-message-type 5;
  option domain-name-servers 192.168.1.1;
  option dhcp-server-identifier 192.168.1.1;
  renew 4 2026/08/06 12:00:00;
  rebind 4 2026/08/06 21:00:00;
  expire 5 2026/08/07 00:00:00;
}
```

#### Paso 3.3: Configurar overrides de parámetros en `/etc/dhclient.conf`
En entornos SRE empresariales, las políticas de DNS locales a menudo requieren anular (override) o anteponer (prepend) resolvers recursivos personalizados (por ejemplo, DNS Anycast interno `10.0.0.2` y Cloudflare `1.1.1.1`) independientemente de lo que suministre el servidor DHCP no confiable.

Creá `/etc/dhclient.conf`:

```bash
# cat << 'EOF' > /etc/dhclient.conf
interface "em0" {
    # Force client to ignore DHCP server provided DNS and use production resolvers
    supersede domain-name-servers 10.0.0.2, 1.1.1.1;
    # Prepend internal domain search path
    prepend domain-name "corp.internal enterprise.local";
    # Set maximum request timeout
    timeout 15;
}
EOF
```

Reiniciá `dhclient` para aplicar los cambios:

```bash
# dhclient -r em0 && dhclient em0
# cat /etc/resolv.conf
```

*Salida esperada:*
```text
# Generated by dhclient
search corp.internal enterprise.local
nameserver 10.0.0.2
nameserver 1.1.1.1
```

---

#### Preguntas de Verificación (Ejercicio 3)

1. **Pregunta 3.1**: ¿Cuál es la diferencia estructural entre `supersede domain-name-servers` y `prepend domain-name-servers` dentro de `/etc/dhclient.conf`?
2. **Pregunta 3.2**: Si `dhclient` no logra contactar ningún servidor DHCP durante el arranque y no existe un archivo de lease activo en `/var/db/dhclient.leases`, ¿cómo se comporta `dhclient` cuando hay una declaración `fallback` definida en `/etc/dhclient.conf`?

---

### Ejercicio 4: Configuración de IPv6, Direccionamiento Link-Local, SLAAC y Privacy Extensions

Este ejercicio cubre la configuración del estado de IPv6 en BSD, diferenciando entre direcciones Link-Local, SLAAC (Stateless Address Autoconfiguration), DHCPv6 y EUI-64 vs. RFC 4941 Privacy Extensions.

#### Paso 4.1: Vinculación manual de dirección IPv6 y análisis de scope
Asigná una dirección estática IPv6 Global Unicast Address (GUA) a `em0`:

```bash
# ifconfig em0 inet6 2001:db8:abc:100::50/64
# ifconfig em0 inet6
```

*Salida esperada:*
```text
em0: flags=8843<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST> metric 0 mtu 1500
	inet6 fe80::5054:ff:fe12:3456%em0 prefixlen 64 scopeid 0x1
	inet6 2001:db8:abc:100::50 prefixlen 64
```

#### Paso 4.2: Habilitar IPv6 Stateless Address Autoconfiguration (SLAAC)
Configurá el runtime de FreeBSD para escuchar Router Advertisements (RA) ICMPv6 de IPv6 a través de `rtsold` / kernel `accept_rtadv`.

En FreeBSD (`/etc/rc.conf`):
```bash
# sysctl net.inet6.ip6.accept_rtadv=1
# ifconfig em0 inet6 accept_rtadv
```

En OpenBSD (`/etc/hostname.em0`):
```text
inet6 autoconf
```

Ejecutá `rtsol` manualmente para forzar una Router Solicitation:

```bash
# rtsol em0
# ifconfig em0 inet6
```

*Salida esperada:*
```text
em0: flags=8843<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST> metric 0 mtu 1500
	inet6 fe80::5054:ff:fe12:3456%em0 prefixlen 64 scopeid 0x1
	inet6 2001:db8:abc:100:5054:ff:fe12:3456 prefixlen 64 autoconf status autoconf
	inet6 2001:db8:abc:100::50 prefixlen 64
```

#### Paso 4.3: Configurar IPv6 Privacy Extensions (RFC 4941)
Evitá el seguimiento de direcciones MAC a través de EUI-64 habilitando direcciones de privacidad en sysctl:

```bash
# sysctl net.inet6.ip6.use_tempaddr=2
```

*Salida esperada:*
```text
net.inet6.ip6.use_tempaddr: 0 -> 2
```

---

#### Preguntas de Verificación (Ejercicio 4)

1. **Pregunta 4.1**: ¿Qué representa el sufijo `%em0` adjunto a las direcciones link-local IPv6 (`fe80::5054:ff:fe12:3456%em0`) y por qué es obligatorio para sockets/comandos ping link-local?
2. **Pregunta 4.2**: En IPv6 SLAAC, ¿qué mecanismo evita que dos nodos en el mismo segmento de Ethernet autoconfiguren direcciones IPv6 idénticas mediante EUI-64 o direcciones de privacidad?

---

### Ejercicio 5: Diagnóstico Avanzado de Red, Enrutamiento de Kernel y Flags de Interfaz

En este ejercicio, utilizarás herramientas de inspección de red del kernel (`netstat`, `route`, `arp`) para analizar decisiones de enrutamiento y solucionar desajustes de estado en las interfaces.

#### Paso 5.1: Consultar la Tabla de Enrutamiento del Kernel (Radix Tree)
Inspeccioná las tablas de enrutamiento IPv4 e IPv6 activas:

```bash
# netstat -rn -f inet
```

*Salida esperada:*
```text
Routing tables

Internet:
Destination        Gateway            Flags     Netif Expire
default            10.100.4.1         UGS         em0
10.100.4.0/21      link#1             UC          em0      -
10.100.4.1         52:54:00:12:00:01  UHLW        em0   1198
127.0.0.1          link#2             UH          lo0
```

#### Paso 5.2: Rastrear la selección de ruta para una IP de destino específica
Usá `route get` para consultar cómo el kernel enruta los paquetes a una IP de destino (`8.8.8.8`):

```bash
# route -n get 8.8.8.8
```

*Salida esperada:*
```text
   route to: 8.8.8.8
destination: 0.0.0.0
    mask: 0.0.0.0
  gateway: 10.100.4.1
  fib: 0
  interface: em0
    flags: <UP,GATEWAY,DONE,STATIC>
 recvpipe  sendpipe  ssthresh  rtt,msec    mtu        weight    expire
       0         0         0         0      1500         0         0
```

#### Paso 5.3: Inspeccionar el estado de la tabla ARP
Mostrá y manipulá las entradas de la caché de resolución de vecinos:

```bash
# arp -an
```

*Salida esperada:*
```text
? (10.100.4.1) at 52:54:00:12:00:01 on em0 expires in 1195 seconds [ethernet]
? (10.100.5.50) at 52:54:00:12:34:56 on em0 permanent [ethernet]
```

---

#### Preguntas de Verificación (Ejercicio 5)

1. **Pregunta 5.1**: En la salida de `netstat -rn`, ¿qué significan los flags de enrutamiento `UGS` y `UHLW` individualmente?
2. **Pregunta 5.2**: Un administrador ejecuta `ifconfig em0 down`. ¿`netstat -rn` purga inmediatamente las rutas asociadas con `em0` de la memoria del kernel de BSD? Explicá el impacto operativo.

---

## 4. Soluciones y Explicaciones de Arquitectura

<details>
<summary>Hacé clic para expandir las soluciones oficiales de los Ejercicios 1 al 5</summary>

### Soluciones del Ejercicio 1

*   **Respuesta 1.1**: Si un alias se configura con una netmask completa (`255.255.250.0` o `255.255.255.0`) idéntica a la IP primaria en la misma interfaz física, el kernel de BSD intenta insertar una segunda entrada de ruta de subred idéntica en su radix routing tree. Esto causa un conflicto en la tabla de rutas o un comportamiento no determinista donde el tráfico saliente destinado a broadcast local o a objetivos de la subred podría seleccionar la dirección IP del alias como IP de origen en lugar de la IP de la interfaz primaria, rompiendo reglas de firewalls stateful (PF/IPFW) y servicios sensibles a la IP de origen. Asignar `255.255.255.255` (`/32`) le indica explícitamente al kernel que el alias es una entrada de host individual y no redefine un límite de subred.
*   **Respuesta 1.2**: El flag `SIMPLEX` indica que la interfaz de hardware no puede escuchar sus propios paquetes transmitidos. En los controladores ethernet, esto significa que el driver de hardware de la interfaz maneja los canales de transmisión y recepción por separado en full-duplex, y el loopback de paquetes para el tráfico vinculado localmente debe ser manejado explícitamente por la interfaz de loopback (`lo0`) o el software loopback del kernel en lugar de reflexiones físicas del cable.

---

### Soluciones del Ejercicio 2

*   **Respuesta 2.1**: Cuando `ifconfig_em0="DHCP"` está configurado en el `/etc/rc.conf` de FreeBSD, el sistema inicia `dhclient` a través de `/etc/rc.d/dhclient`. Si un servidor DHCP proporciona una opción de router, `dhclient` invoca `/sbin/route add default <gateway>` al obtener un lease. Si `defaultrouter` TAMBIÉN se especifica estáticamente en `/etc/rc.conf`, el script de inicio `/etc/rc.d/routing` intenta establecer el default gateway estático. Sin embargo, `dhclient`, al ejecutarse más tarde, sobrescribirá o fallará al establecer la ruta según los flags de la tabla de rutas. La mejor práctica en entornos de producción BSD es dejar `defaultrouter` sin configurar cuando se utiliza DHCP.
*   **Respuesta 2.2**:
    *   **OpenBSD**: Utiliza el archivo simple `/etc/mygate` que contiene una sola dirección IPv4/IPv6 por línea. El script `/etc/netstart` lee `/etc/mygate` y ejecuta `route add default <address>`.
    *   **FreeBSD**: Utiliza `defaultrouter="x.x.x.x"` dentro de `/etc/rc.conf`.
    *   **NetBSD**: Utiliza `mygate="x.x.x.x"` dentro de `/etc/rc.conf` (analizado por `/etc/rc.d/network`). NetBSD también puede utilizar `/etc/mygate` si está habilitado.

---

### Soluciones del Ejercicio 3

*   **Respuesta 3.1**:
    *   `supersede domain-name-servers`: Reemplaza y anula completamente cualquier servidor DNS ofrecido por el servidor DHCP en el paquete DHCPACK con las direcciones IP especificadas. Las IPs de DNS suministradas por el servidor DHCP se ignoran.
    *   `prepend domain-name-servers`: Toma las direcciones IP especificadas y las inserta al *principio* de la lista de servidores DNS devuelta por el servidor DHCP. Cualquier servidor DNS recibido a través de DHCP se seguirá incluyendo en `/etc/resolv.conf`, pero listado después de las IPs antepuestas.
*   **Respuesta 3.2**: Cuando `dhclient` no puede localizar un servidor DHCP y no tiene un lease válido en caché en `/var/db/dhclient.leases`, verifica `/etc/dhclient.conf` en busca de una declaración `alias { ... }` o `fallback`. Si está definida, `dhclient` ejecuta `dhclient-script` para configurar la interfaz con la IP de fallback estática predefinida y los parámetros de default gateway, lo que permite a los sistemas de producción headless mantener un acceso de gestión fuera de banda (out-of-band) mínimo durante caídas totales de la infraestructura DHCP.

---

### Soluciones del Ejercicio 4

*   **Respuesta 4.1**: La cadena `%em0` es el **Zone Index** (o Scope Zone Identifier). Debido a que las direcciones link-local IPv6 (`fe80::/10`) no son enrutables y pueden existir espacios de direcciones idénticos de manera concurrente en múltiples interfaces físicas (por ejemplo, `em0`, `em1`, `igb0`), la tabla de enrutamiento del kernel no puede determinar hacia qué enlace físico sacar los paquetes basándose únicamente en la dirección IPv6 `fe80::1`. El zone index vincula explícitamente la operación de socket con el índice de la interfaz física específica.
*   **Respuesta 4.2**: **Duplicate Address Detection (DAD)**. Cuando se configura una dirección IPv6 a través de SLAAC (o estáticamente), el kernel de BSD coloca la dirección en un estado `tentative` (visible en `ifconfig` como `inet6 ... flags=TENTATIVE`). Antes de reclamar la dirección, el nodo envía un mensaje ICMPv6 **Neighbor Solicitation (NS)** a la dirección Solicited-Node Multicast (`ff02::1:ffXX:XXXX`). Si otro nodo responde con una Neighbor Advertisement (NA), se detecta una colisión de direcciones, el kernel marca la dirección como `DUPLICATE`, deshabilita el binding IPv6 de la interfaz y registra una alerta del kernel.

---

### Soluciones del Ejercicio 5

*   **Respuesta 5.1**:
    *   `U`: La ruta está **Up** (activa en la tabla de enrutamiento).
    *   `G`: **Gateway** (el destino requiere reenvío a través de una dirección de router/gateway intermedia).
    *   `S`: Ruta **Static** agregada manualmente a través de archivos de configuración o CLI, no aprendida dinámicamente mediante protocolos de enrutamiento (RIP/OSPF/BGP).
    *   `H`: Ruta **Host** (coincide con un solo host específico `/32` o `/128`, en lugar de una subred de red completa).
    *   `L`: **Link-layer** (contiene información de hardware para el mapeo de direcciones MAC).
    *   `W`: Ruta **Cloned** generada dinámicamente por ARP o Neighbor Discovery (Wand/Wormhole route en la terminología del kernel de BSD).
*   **Respuesta 5.2**: Desactivar una interfaz a través de `ifconfig em0 down` modifica los flags de interfaz de `struct ifnet` en el kernel, eliminando el flag `IFF_UP`. El kernel marca inmediatamente las rutas de subred conectadas a la interfaz como inactivas (eliminando el flag `U`). Sin embargo, las entradas de enrutamiento estático que hacen referencia a `em0` como gateway permanecen en la tabla de enrutamiento a menos que se eliminen explícitamente, pero el reenvío de paquetes a través de `em0` falla inmediatamente en la socket layer con `EHOSTUNREACH` (No route to host) o `ENETDOWN` (Network is down).

</details>