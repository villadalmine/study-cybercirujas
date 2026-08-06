# 2.5 Networking Fundamentals

## 1. Motivaci\u00f3n y Problema Arquitect\u00f3nico de Producci\u00f3n

En el paradigma de Cloud Computing y Kubernetes, la red no es simplemente un cable f\u00edsico; es una topolog\u00eda virtual definida por software (SDN). Como Platform Architect o SRE, comprender los fundamentos de red (IPv4/IPv6, subnets, routing, puertos) es obligatorio porque es donde ocurren el 90% de los incidentes en sistemas distribuidos.

El problema arquitect\u00f3nico m\u00e1s com\u00fan es el **agotamiento de puertos y subredes** (IP Exhaustion) o el enrutamiento asim\u00e9trico (Asymmetric Routing) en cl\u00fasteres. Por ejemplo, si asignas un CIDR `/24` (254 IPs usables) a la red de Pods de un cl\u00faster de Kubernetes, solo podr\u00e1s tener como m\u00e1ximo 254 Pods en todo el cl\u00faster. Un SRE debe saber calcular subredes, diferenciar entre tr\u00e1fico TCP (orientado a conexi\u00f3n, stateful) y UDP (stateless), entender c\u00f3mo el kernel manipula las tablas de ruteo, y diagnosticar fallas de red utilizando comandos modernos (`ip`, `ss`, `nmcli`) en lugar de herramientas obsoletas (`ifconfig`, `netstat`).

## 2. Comparativas T\u00e9cnicas y Trade-offs

### Direccionamiento IP: IPv4 vs. IPv6 en Cloud/Platform

| Caracter\u00edstica | IPv4 | IPv6 | Impacto SRE |
| :--- | :--- | :--- | :--- |
| **Espacio de Direcciones** | 32 bits (~4.3 mil millones). Agotado. | 128 bits. Pr\u00e1cticamente infinito. | **Subnetting:** En IPv4 sufres planificando CIDRs. En IPv6, puedes asignar un `/64` entero a un solo servidor sin preocuparte. |
| **NAT (Network Address Translation)** | Requerido casi obligatoriamente para acceso a internet desde LANs privadas. | Innecesario. Cada contenedor/dispositivo puede tener una IP global \u00fanica. | IPv4 NAT introduce estado (conntrack tables) en los routers, creando cuellos de botella (SNAT port exhaustion). |
| **Configuraci\u00f3n Autom\u00e1tica** | DHCP (Stateful). Requiere un servidor central. | SLAAC (Stateless). El kernel autoconfigura la IP basado en el router. | SLAAC permite aprovisionamiento de nodos *Zero-Touch* mucho m\u00e1s r\u00e1pido. |

### Herramientas de Ruteo y Redes de Kernel (Legacy vs Modernas)

| Tarea SRE | Tooling Obsoleto (net-tools) | Tooling Moderno (iproute2) | Notas de Producci\u00f3n |
| :--- | :--- | :--- | :--- |
| **Listar Interfaces e IPs** | `ifconfig` | `ip addr show` / `ip a` | `ifconfig` no muestra IPs secundarias correctamente asignadas por herramientas como Keepalived. |
| **Modificar Tabla de Ruteo** | `route -n` | `ip route show` | `ip route` interact\u00faa directamente con el subsistema netlink del kernel moderno. |
| **Monitorear Sockets/Puertos**| `netstat -tulnp` | `ss -tulnp` | `ss` es dr\u00e1sticamente m\u00e1s r\u00e1pido en servidores con 10,000+ conexiones concurrentes. |

## 3. Manifiestos, Configuraci\u00f3n e Infraestructura

En servidores de producci\u00f3n modernos (especialmente en Debian/Ubuntu), la red se declara en manifiestos YAML de **Netplan**, que luego son renderizados al backend de `systemd-networkd` o `NetworkManager`.

### Manifiesto de Red: `/etc/netplan/01-netcfg.yaml`

Este ejemplo configura un servidor de base de datos *on-premise* con una IP est\u00e1tica, agregaci\u00f3n de enlaces (bonding) para alta disponibilidad (LACP), y ruteo est\u00e1tico.

```yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    # Definimos dos interfaces f\u00edsicas crudas (sin IP, las usaremos para el bond)
    eno1:
      dhcp4: false
      dhcp6: false
    eno2:
      dhcp4: false
      dhcp6: false
  
  bonds:
    # Creamos un enlace l\u00f3gico altamente disponible (LACP - 802.3ad)
    bond0:
      interfaces: [eno1, eno2]
      parameters:
        mode: 802.3ad
        mii-monitor-interval: 100
      # Configuraci\u00f3n de IP est\u00e1tica en formato CIDR
      addresses:
        - 10.10.5.50/24
      # Ojo: 'gateway4' est\u00e1 deprecado. Se recomiendan rutas expl\u00edcitas:
      routes:
        - to: default
          via: 10.10.5.1
      nameservers:
        addresses: [1.1.1.1, 8.8.8.8]
        search: [svc.cluster.local, miempresa.internal]
```
*(Para aplicar estos cambios en caliente sin reiniciar: `sudo netplan apply`)*

## 4. Comandos CLI y Salidas de Terminal Reales

### Inspecci\u00f3n R\u00e1pida de Sockets Abiertos (Qu\u00e9 escucha en mi servidor)

Para saber qu\u00e9 procesos est\u00e1n atados (bound) a qu\u00e9 puertos TCP/UDP.

```bash
# ss: Socket Statistics
# -t (TCP), -u (UDP), -l (Listening), -n (Numeric IPs/Ports), -p (Process/PID)
$ sudo ss -tulnp
Netid  State   Recv-Q  Send-Q     Local Address:Port      Peer Address:Port  Process
tcp    LISTEN  0       128        127.0.0.1:5432          0.0.0.0:*          users:(("postgres",pid=908,fd=7))
tcp    LISTEN  0       4096       *:80                    *:*                users:(("nginx",pid=1120,fd=8))
tcp    LISTEN  0       4096       *:443                   *:*                users:(("nginx",pid=1120,fd=9))
udp    UNCONN  0       0          127.0.0.53%lo:53        0.0.0.0:*          users:(("systemd-resolve",pid=705,fd=12))
```
*An\u00e1lisis SRE:* Vemos a PostgreSQL escuchando solo en `127.0.0.1` (seguro, nadie desde afuera puede atacarlo). Nginx escucha en todo (`*`) el host.

### Resoluci\u00f3n de DNS y Troubleshooting (`dig`)

`dig` (Domain Information Groper) es infinitamente superior a `ping` para diagnosticar fallos de red relacionados a nombres.

```bash
# Consultar el registro A (IPv4) de un dominio
$ dig +short google.com A
142.250.72.206

# Especificar un servidor DNS particular (ej. Cloudflare) para ignorar el DNS local
$ dig @1.1.1.1 lpi.org MX +short
10 aspmx.l.google.com.
20 alt1.aspmx.l.google.com.

# SRE: Verificar cu\u00e1l es la ruta exacta que tomar\u00e1 un paquete para salir a internet
$ ip route get 8.8.8.8
8.8.8.8 via 192.168.1.1 dev eth0 src 192.168.1.50 uid 1000
    cache
```

## 5. Gu\u00eda de Verificaci\u00f3n y Diagn\u00f3stico de Fallas

1. **Host Inalcanzable tras cambiar la IP (IP Duplicada o Falsa M\u00e1scara)**:
   Cambiaste la IP est\u00e1tica del nodo y ahora ning\u00fan ping funciona.
   *Diagn\u00f3stico:* Revisa tu CIDR. Si configuras `192.168.1.150/25` (128 IPs, rango 128 a 255), y el Gateway (Router) del centro de datos es `192.168.1.1`, est\u00e1n en redes totalmente distintas. `ip route` mostrar\u00e1 que no hay ruta al router.
   *Resoluci\u00f3n:* Ajusta el CIDR a `/24` (255.255.255.0) en tu manifiesto Netplan o ifupdown para que el host asuma correctamente el tama\u00f1o del segmento de red donde reside su router.

2. **Aplicaci\u00f3n no recibe tr\u00e1fico a pesar de que el Firewall est\u00e1 abierto**:
   Tienes un contenedor NodeJS, el firewall permite el puerto 3000, pero desde otra PC recibes `Connection Refused`.
   *Diagn\u00f3stico:* Ejecuta `sudo ss -tulnp | grep 3000`. Si la columna *Local Address* dice `127.0.0.1:3000`, la aplicaci\u00f3n se at\u00f3 (bind) exclusivamente a *localhost* (bucle invertido interno). El tr\u00e1fico del cable de red (eth0) es f\u00edsicamente descartado.
   *Resoluci\u00f3n:* Modifica la configuraci\u00f3n de tu aplicaci\u00f3n (ej. en NodeJS o Python) para escuchar en la IP global `0.0.0.0` (todas las interfaces) en lugar de `127.0.0.1`.

3. **Problemas de conectividad intermitente (Resoluci\u00f3n DNS ca\u00edda)**:
   Los pings a IPs num\u00e9ricas (ej. `8.8.8.8`) funcionan, pero `curl https://api.github.com` falla con `Could not resolve host`.
   *Diagn\u00f3stico:* Revisa `/etc/resolv.conf`. En sistemas modernos (Ubuntu), es un enlace simb\u00f3lico a `systemd-resolved` (el demonio local de DNS). Si el demonio est\u00e1 ca\u00eddo o el archivo tiene apuntado un DNS viejo que ya no existe, el nodo no puede traducir nombres.
   *Resoluci\u00f3n:* Ejecuta `resolvectl status` para diagnosticar el estado del DNS local, y reinicia el demonio si est\u00e1 atascado: `sudo systemctl restart systemd-resolved`.

## 6. Referencias

* LPIC-1 Objetivos (Topic 109): [https://www.lpi.org/our-certifications/exam-101-objectives](https://www.lpi.org/our-certifications/exam-101-objectives)
* iproute2 Cheatsheet: [https://baturin.org/docs/iproute2/](https://baturin.org/docs/iproute2/)
* Netplan Reference Documentation: [https://netplan.io/reference/](https://netplan.io/reference/)
* Systemd-resolved Manual: [https://www.freedesktop.org/software/systemd/man/systemd-resolved.service.html](https://www.freedesktop.org/software/systemd/man/systemd-resolved.service.html)