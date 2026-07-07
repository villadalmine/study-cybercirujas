# 4.4 Your Computer on the Network

**Peso en el examen:** 2
**Objetivo:** Consultar y configurar los parámetros esenciales de red de un equipo Linux: direcciones IP, gateway, DNS, y verificar la conectividad.

---

## 1. Conceptos fundamentales de red

### 1.1 ¿Qué necesita una computadora para estar en red?

Para que un equipo Linux se comunique en una red TCP/IP necesita, como mínimo, cuatro parámetros:

| Parámetro | Función |
|---|---|
| **IP address** | Identifica de forma única al equipo dentro de la red. |
| **Subnet mask** (máscara de subred) | Define qué parte de la dirección identifica a la red y cuál al host. |
| **Default gateway** (router) | Equipo al que se envía el tráfico destinado a otras redes (por ejemplo, Internet). |
| **DNS server** | Traduce nombres (`www.lpi.org`) a direcciones IP y viceversa. |

Estos valores pueden configurarse **manualmente** (configuración estática) o **automáticamente** mediante **DHCP** (*Dynamic Host Configuration Protocol*), que es lo habitual en redes hogareñas y corporativas: al conectarse, el equipo solicita la configuración y un servidor DHCP le asigna IP, máscara, gateway y DNS.

### 1.2 IPv4

Una dirección **IPv4** tiene 32 bits, escritos como cuatro octetos decimales separados por puntos: `192.168.1.10`. La máscara de subred indica el tamaño de la red; puede escribirse en notación decimal (`255.255.255.0`) o **CIDR** (`/24`).

Ejemplo: en `192.168.1.10/24`, los primeros 24 bits (`192.168.1`) identifican la red y los 8 restantes (`.10`) al host. Todos los equipos de esa red comparten el prefijo `192.168.1.x`.

Hay rangos **privados** (RFC 1918) que no se enrutan por Internet y se usan en redes internas:

- `10.0.0.0/8`
- `172.16.0.0/12` (de `172.16.0.0` a `172.31.255.255`)
- `192.168.0.0/16`

Los equipos con IP privada acceden a Internet a través de **NAT** (*Network Address Translation*), que realiza el router: reemplaza la IP privada de origen por su propia IP pública.

Otras direcciones especiales:

- `127.0.0.1` — **loopback** (`localhost`): el propio equipo.
- `169.254.x.x` — **link-local** (APIPA): autoasignada cuando falla DHCP; verla suele indicar un problema de red.

### 1.3 IPv6

**IPv6** usa direcciones de 128 bits escritas en hexadecimal, en ocho grupos separados por dos puntos: `2001:0db8:0000:0000:0000:0000:0000:0001`. Se pueden abreviar: los ceros iniciales de cada grupo se omiten y una sola secuencia de grupos en cero se reemplaza por `::`, quedando `2001:db8::1`.

Puntos clave:

- Resuelve el agotamiento de direcciones IPv4 (espacio prácticamente ilimitado).
- El loopback es `::1`.
- Las direcciones **link-local** empiezan con `fe80::` y existen automáticamente en cada interfaz.
- Las direcciones globales suelen usar prefijo `/64` para la red.

### 1.4 DNS

El **DNS** (*Domain Name System*) es la "guía telefónica" de Internet: convierte nombres de dominio en direcciones IP. Cuando escribís `www.lpi.org` en el navegador, el sistema consulta al servidor DNS configurado, obtiene la IP y recién entonces se conecta.

En Linux, la resolución de nombres se controla con dos archivos:

- **`/etc/hosts`** — tabla local estática de nombres → IP. Se consulta antes que el DNS (según `/etc/nsswitch.conf`).
- **`/etc/resolv.conf`** — define los servidores DNS a consultar.

```bash
$ cat /etc/hosts
127.0.0.1   localhost
::1         localhost
192.168.1.20   servidor-interno.ejemplo.local servidor-interno

$ cat /etc/resolv.conf
search ejemplo.local
nameserver 192.168.1.1
nameserver 8.8.8.8
```

> **Nota:** en muchas distribuciones modernas `/etc/resolv.conf` es gestionado automáticamente por `systemd-resolved` o `NetworkManager`, por lo que puede contener una IP local como `127.0.0.53`.

---

## 2. Consultar la configuración de red

### 2.1 El comando `ip` (el estándar actual)

La suite `iproute2` con el comando `ip` reemplaza a las herramientas antiguas (`ifconfig`, `route`). Los subcomandos más importantes:

**Ver direcciones IP de las interfaces:**

```bash
$ ip addr show
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 ...
    inet 127.0.0.1/8 scope host lo
    inet6 ::1/128 scope host
2: enp3s0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 ...
    link/ether 08:00:27:a5:9b:3c brd ff:ff:ff:ff:ff:ff
    inet 192.168.1.10/24 brd 192.168.1.255 scope global dynamic enp3s0
    inet6 fe80::a00:27ff:fea5:9b3c/64 scope link
```

Aquí se ve: la interfaz `enp3s0` está activa (`UP`), su dirección MAC (`link/ether`), su IPv4 (`192.168.1.10/24`, obtenida por DHCP: `dynamic`) y su IPv6 link-local.

Forma abreviada muy útil: `ip a`.

**Ver la tabla de rutas y el default gateway:**

```bash
$ ip route show
default via 192.168.1.1 dev enp3s0 proto dhcp metric 100
192.168.1.0/24 dev enp3s0 proto kernel scope link src 192.168.1.10
```

La línea `default via 192.168.1.1` indica que todo el tráfico hacia otras redes se envía al router `192.168.1.1`.

Para IPv6: `ip -6 route show`.

**Ver enlaces (interfaces) sin direcciones:**

```bash
$ ip link show
```

### 2.2 Herramientas legacy: `ifconfig` y `route`

Todavía aparecen en el examen y en sistemas antiguos (paquete `net-tools`):

```bash
$ ifconfig
enp3s0: flags=4163<UP,BROADCAST,RUNNING,MULTICAST>  mtu 1500
        inet 192.168.1.10  netmask 255.255.255.0  broadcast 192.168.1.255
        ether 08:00:27:a5:9b:3c

$ route -n
Kernel IP routing table
Destination     Gateway         Genmask         Flags Metric Iface
0.0.0.0         192.168.1.1     0.0.0.0         UG    100    enp3s0
192.168.1.0     0.0.0.0         255.255.255.0   U     100    enp3s0
```

Equivalencias: `ifconfig` ≈ `ip addr`, `route` ≈ `ip route`.

---

## 3. Verificar la conectividad

### 3.1 `ping` — ¿hay conexión?

Envía paquetes **ICMP echo request** y mide la respuesta. Es la primera herramienta de diagnóstico:

```bash
$ ping -c 3 www.lpi.org
PING www.lpi.org (65.39.134.165) 56(84) bytes of data.
64 bytes from 65.39.134.165: icmp_seq=1 ttl=54 time=18.3 ms
64 bytes from 65.39.134.165: icmp_seq=2 ttl=54 time=17.9 ms
64 bytes from 65.39.134.165: icmp_seq=3 ttl=54 time=18.1 ms

--- www.lpi.org ping statistics ---
3 packets transmitted, 3 received, 0% packet loss, time 2003ms
```

- `-c 3` limita a 3 paquetes (sin esta opción, `ping` continúa hasta Ctrl+C).
- Para IPv6 existe `ping6` (o `ping -6`).

**Metodología de diagnóstico típica:** hacer ping al gateway → a una IP de Internet (p. ej. `8.8.8.8`) → a un nombre (`www.lpi.org`). Si funcionan las IP pero no los nombres, el problema es el DNS.

### 3.2 `host` y `dig` — consultar el DNS

**`host`**: consulta simple, salida amigable.

```bash
$ host www.lpi.org
www.lpi.org has address 65.39.134.165
www.lpi.org has IPv6 address 2001:1978:212:e2::1:3

$ host 8.8.8.8
8.8.8.8.in-addr.arpa domain name pointer dns.google.
```

(La segunda consulta es una **resolución inversa**: IP → nombre.)

**`dig`**: consulta detallada, orientada a administradores.

```bash
$ dig www.lpi.org
;; QUESTION SECTION:
;www.lpi.org.                   IN      A

;; ANSWER SECTION:
www.lpi.org.            600     IN      A       65.39.134.165

;; Query time: 24 msec
;; SERVER: 192.168.1.1#53(192.168.1.1)
```

`dig` muestra el tipo de registro (`A` = IPv4, `AAAA` = IPv6), el **TTL** (600 segundos de caché) y qué servidor respondió. Se puede consultar un servidor específico: `dig @8.8.8.8 www.lpi.org`.

### 3.3 `traceroute` — el camino de los paquetes

Muestra cada router (*hop*) que atraviesa un paquete hasta el destino:

```bash
$ traceroute www.lpi.org
 1  _gateway (192.168.1.1)  1.2 ms
 2  10.20.0.1 (10.20.0.1)  8.4 ms
 3  ...
```

Útil para localizar en qué punto de la ruta se corta la conectividad. Variante moderna: `tracepath` (no requiere privilegios).

### 3.4 `ss` y `netstat` — conexiones y puertos

**`ss`** (*socket statistics*) muestra las conexiones activas y los puertos en escucha; reemplaza al antiguo `netstat`:

```bash
$ ss -tlpn
State   Local Address:Port   Process
LISTEN  0.0.0.0:22           sshd
LISTEN  127.0.0.1:631        cupsd
```

Opciones frecuentes: `-t` TCP, `-u` UDP, `-l` solo puertos en escucha (*listening*), `-n` mostrar números en lugar de nombres, `-p` proceso asociado.

`netstat -tlpn` produce una salida equivalente en sistemas con `net-tools`.

---

## 4. Configurar la red

### 4.1 Configuración temporal con `ip`

Los cambios con `ip` son inmediatos pero **se pierden al reiniciar**:

```bash
# Asignar una IP a la interfaz
$ sudo ip addr add 192.168.1.50/24 dev enp3s0

# Activar la interfaz
$ sudo ip link set enp3s0 up

# Agregar el default gateway
$ sudo ip route add default via 192.168.1.1
```

### 4.2 Configuración persistente

La configuración permanente depende de la distribución y del gestor de red:

- **NetworkManager** (la mayoría de los escritorios): se administra con la GUI, `nmcli` o `nmtui`.
  ```bash
  $ nmcli device status
  DEVICE   TYPE      STATE      CONNECTION
  enp3s0   ethernet  connected  Wired connection 1
  ```
- **systemd-networkd**: archivos `.network` en `/etc/systemd/network/`.
- Archivos clásicos: `/etc/network/interfaces` (Debian tradicional), `/etc/sysconfig/network-scripts/` (Red Hat tradicional), Netplan en `/etc/netplan/` (Ubuntu).

Para el examen alcanza con saber que **la configuración temporal se hace con `ip`** y que **la persistente la gestionan herramientas como NetworkManager** según la distribución.

---

## 5. Resumen de comandos

| Comando | Uso |
|---|---|
| `ip addr` / `ifconfig` | Ver direcciones IP e interfaces |
| `ip route` / `route -n` | Ver tabla de rutas y default gateway |
| `ping` / `ping6` | Probar conectividad (ICMP) |
| `host`, `dig` | Consultar resolución DNS |
| `traceroute`, `tracepath` | Ver la ruta hasta un destino |
| `ss` / `netstat` | Ver conexiones y puertos abiertos |
| `nmcli` | Administrar NetworkManager |

Archivos clave: `/etc/hosts` (nombres locales), `/etc/resolv.conf` (servidores DNS), `/etc/nsswitch.conf` (orden de resolución).

---

## 6. Preguntas de repaso

1. ¿Qué cuatro parámetros necesita un equipo para funcionar en una red TCP/IP con acceso a Internet?
2. ¿Qué comando moderno muestra el default gateway del sistema?
3. Si `ping 8.8.8.8` funciona pero `ping www.lpi.org` falla, ¿dónde está el problema?
4. ¿Qué archivo define los servidores DNS que usa el sistema?
5. ¿Cómo se abrevia la dirección IPv6 `2001:0db8:0000:0000:0000:0000:0000:0001`?
6. ¿Qué indica que una interfaz tenga asignada una dirección `169.254.x.x`?

<details>
<summary>Respuestas</summary>

1. IP address, subnet mask, default gateway y servidor DNS.
2. `ip route show` (la línea `default via ...`). Equivalente legacy: `route -n`.
3. En la resolución DNS: hay conectividad IP pero los nombres no se resuelven.
4. `/etc/resolv.conf`.
5. `2001:db8::1`.
6. Que el equipo no obtuvo dirección por DHCP y se autoasignó una link-local (APIPA); suele indicar un fallo de red o del servidor DHCP.

</details>

---

## Referencias

- LPI Learning Materials — Tema 4.4 *Your Computer on the Network*: https://learning.lpi.org/en/learning-materials/010-160/4/4.4/
- Objetivos del examen Linux Essentials 010-160 (v1.6): https://www.lpi.org/our-certifications/exam-010-objectives/
- Manual de `ip` (iproute2): https://man7.org/linux/man-pages/man8/ip.8.html
- Manual de `ping`: https://man7.org/linux/man-pages/man8/ping.8.html
- Manual de `ss`: https://man7.org/linux/man-pages/man8/ss.8.html
- Manual de `dig` (BIND 9): https://bind9.readthedocs.io/en/latest/manpages.html#dig-dns-lookup-utility
- Manual de `resolv.conf`: https://man7.org/linux/man-pages/man5/resolv.conf.5.html
- RFC 1918 — *Address Allocation for Private Internets*: https://www.rfc-editor.org/rfc/rfc1918
- Documentación de NetworkManager (`nmcli`): https://networkmanager.dev/docs/api/latest/nmcli.html