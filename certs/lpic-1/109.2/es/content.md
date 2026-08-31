# 109.2 — Configuración de red persistente

*LPIC-1, Examen 102-500, v5.0 — Tema 109: Fundamentos de redes*

---

## 1. El problema arquitectónico: el estado de ejecución no es configuración

Todo host Linux mantiene **dos estados de red independientes**, y confundirlos es la causa más frecuente de los incidentes del tipo "funcionaba hasta que reiniciamos".

| Plano | Dónde vive | Tiempo de vida | Modificado por |
|---|---|---|---|
| **Plano de ejecución (runtime)** | Estructuras del kernel: lista `netdev`, `struct in_ifaddr`, tablas FIB, caché de vecinos | Hasta el reinicio, un evento de enlace o la reconciliación de un demonio | `ip`, `ifconfig`, `route`, netlink desde cualquier demonio |
| **Plano de configuración** | Archivos en disco: `/etc/network/interfaces`, `*.nmconnection`, `*.network`, `/etc/netplan/*.yaml` | Persistente | Editor, `nmcli`, `netplan`, cloud-init, Ansible |

`ip addr add 10.20.0.5/24 dev enp1s0` escribe únicamente en el plano de ejecución. No sobrevive a ningún reinicio y —peor aún— ni siquiera sobrevive a un *carrier flap* si un demonio reconciliador (NetworkManager, systemd-networkd, `wicked`) es dueño de esa interfaz, porque esos demonios vuelven a aplicar su estado declarado en cada evento `RTM_NEWLINK`. Una carrera de `netlink` con el comando `ip` manual de un operador es invisible en `dmesg` y parece que "la dirección desapareció sola".

La disciplina de producción que se desprende de esto:

> **Principio de escritor único.** Exactamente un componente puede ser dueño de la configuración de una interfaz. Dos dueños (por ejemplo, NetworkManager *y* `ifupdown`, o el `systemd-networkd` generado por netplan *y* un archivo `.network` escrito a mano) producen un comportamiento de arranque no determinista que depende del orden de las units y del timing de los eventos de udev.

La persistencia en Linux no es un problema sino **tres planos ortogonales**, cada uno con su propio conjunto de archivos, su propio demonio y su propio modo de falla:

1. **Identidad** — el hostname (`/etc/hostname`, `hostnamectl`, `systemd-hostnamed`).
2. **Topología** — nombres de interfaz, direcciones, rutas, bonds, VLANs, bridges.
3. **Resolución** — `/etc/hosts`, `/etc/nsswitch.conf`, `/etc/resolv.conf`.

Un host puede arrancar con una topología L3 perfecta y aun así estar funcionalmente muerto porque un cliente DHCP sobrescribió el plano 3. LPI evalúa los tres bajo este único objetivo.

### 1.1 Por qué esto importa más allá del examen

En un nodo de Kubernetes, los tres planos se corresponden directamente con comportamiento visible en el clúster:

- El **hostname estático** normalmente se vuelve el valor por defecto de `kubelet --hostname-override` y, por lo tanto, el nombre del objeto `Node`. Un hostname que cambia en el arranque (provisto por DHCP, no persistente) registra un *segundo* `Node` y deja huérfano al primero, con todos sus objetos `Pod`.
- El **plano de direcciones** determina `InternalIP`. Una NIC que levanta con una dirección DHCP en vez de la estática declarada desplaza la IP del nodo y rompe los SAN del mTLS entre kubelet y apiserver.
- El **plano de resolución** del host es lo que heredan los pods con `dnsPolicy: Default`, y un `options ndots:5` perdido o una dirección stub 127.0.0.53 copiada dentro de un contenedor es la causa raíz clásica del "el DNS está lento en el clúster".

---

## 2. Plano de identidad: los nombres de interfaz deben ser persistentes antes de que puedan serlo las direcciones

No se puede persistir `Address=10.20.0.5/24` en `eth0` si `eth0` es `eth1` en el próximo arranque. El orden de enumeración del kernel para dispositivos PCI no es estable: depende del orden de sondeo, que depende del orden de carga de los drivers, que depende del contenido del initrd y del timing SMP.

### 2.1 Nombres predecibles de interfaz de red

`systemd-udevd` renombra las interfaces durante el coldplug usando el builtin `net_id`. El nombre se construye con un **prefijo** más un **sufijo elegido por la política**:

| Elemento | Valores | Significado |
|---|---|---|
| Prefijo | `en`, `wl`, `ww`, `sl`, `ib`, `nl` | Ethernet, WLAN, WWAN, SLIP, InfiniBand, NetLink |
| `o<index>` | `eno1` | Índice on-board provisto por el firmware (SMBIOS / DT) |
| `s<slot>[f<fn>][d<dev>]` | `ens3`, `ens1f0` | Índice del slot PCI hotplug |
| `p<bus>s<slot>` | `enp3s0`, `enp0s31f6` | Ubicación geográfica PCI |
| `x<MAC>` | `enx001b638445e6` | Derivado de la MAC |
| `d<n>` / `i<n>` | `enp2s0d1` | Dispositivo/puerto en placas multipuerto |

El orden de la política se declara con `NamePolicy=` en archivos `.link`, por defecto desde `/usr/lib/systemd/network/99-default.link`:

```ini
[Match]
OriginalName=*

[Link]
NamePolicy=keep kernel database onboard slot path
AlternativeNamesPolicy=database onboard slot path
MACAddressPolicy=persistent
```

Inspeccioná qué deriva udev para un dispositivo — este es el comando de depuración autoritativo:

```console
$ udevadm test-builtin net_id /sys/class/net/enp1s0 2>/dev/null
ID_NET_NAMING_SCHEME=v252
ID_NET_NAME_MAC=enx525400a1b2c3
ID_OUI_FROM_DATABASE=QEMU Virtual NIC
ID_NET_NAME_PATH=enp1s0
ID_NET_NAME_SLOT=ens1
```

```console
$ udevadm info /sys/class/net/enp1s0 | grep -E 'ID_NET_NAME|ID_PATH='
E: ID_NET_NAME_MAC=enx525400a1b2c3
E: ID_NET_NAME_PATH=enp1s0
E: ID_PATH=pci-0000:01:00.0
```

### 2.2 Fijar un nombre a mano (archivo `.link`)

La forma soportada de forzar un nombre — nunca reglas `NAME=` de `udev` para dispositivos de red en hosts con systemd, y nunca ambas a la vez:

```ini
# /etc/systemd/network/10-mgmt0.link
[Match]
MACAddress=52:54:00:a1:b2:c3

[Link]
Name=mgmt0
MACAddressPolicy=none
```

```console
# udevadm control --reload
# udevadm trigger --action=add --subsystem-match=net
# ip -br link show mgmt0
mgmt0            UP             52:54:00:a1:b2:c3 <BROADCAST,MULTICAST,UP,LOWER_UP>
```

**Trampa:** si la interfaz la levanta el initramfs (root sobre NFS/iSCSI, LUKS atado a la red), el archivo `.link` también tiene que estar dentro del initrd:

```console
# dracut -f --regenerate-all          # RHEL/Fedora
# update-initramfs -u -k all          # Debian/Ubuntu
```

**Trampa:** los nombres no deben colisionar con el espacio de nombres propio del kernel durante el renombrado. Renombrar `eth0` → `eth1` mientras `eth1` existe falla con `EEXIST`; udev registra `Could not rename interface`. Usá un nombre que el kernel nunca generaría (`mgmt0`, `wan0`, `stor0`).

### 2.3 Deshabilitar los nombres predecibles (compatibilidad heredada)

| Método | Alcance | Notas |
|---|---|---|
| `net.ifnames=0` en la línea de comandos del kernel | Todas las NICs | Vuelve a `eth*`; agregá `biosdevname=0` en hardware Dell |
| `ln -s /dev/null /etc/systemd/network/99-default.link` | Todas las NICs | Enmascara la política por defecto; sobrevive mejor a las actualizaciones de systemd que editar `/usr/lib` |
| `net.naming-scheme=v247` | Todas las NICs | Congela la versión del *algoritmo* de nombrado a través de una actualización de distro — la solución correcta cuando una actualización renombra NICs |

`net.naming-scheme=` es la subutilizada. Actualizar de RHEL 8 → 9 o de Debian 11 → 12 puede cambiar `ens1f0` por `ens1f0np0` porque el esquema aprendió sobre los phys-port-names. Congelar el esquema mantiene válida toda declaración existente.

---

## 3. El panorama del plano de configuración

Cinco componentes compiten por la propiedad. Saber qué distro trae cuál — y cuál es un *frontend* en vez de un dueño — entra en el examen y es decisivo en la operación.

| Stack | Ubicación de la configuración | Demonio | Modelo | Distro típica | Reconcilia ante eventos de enlace | Rollback |
|---|---|---|---|---|---|---|
| **ifupdown** | `/etc/network/interfaces`, `interfaces.d/` | ninguno (scripts + `ifup@.service`) | Imperativo, de una sola pasada en el arranque | Debian (instalaciones mínimas/servidor) | ❌ no | ninguno |
| **NetworkManager** | `/etc/NetworkManager/system-connections/*.nmconnection` | `NetworkManager.service` | Declarativo, con estado, orientado a eventos | RHEL/Fedora/CentOS Stream, Ubuntu Desktop | ✅ sí | manual (`nmcli con up`) |
| **systemd-networkd** | `/etc/systemd/network/*.{link,netdev,network}` | `systemd-networkd.service` | Declarativo, demonio sin estado | Ubuntu Server (vía netplan), contenedores, imágenes mínimas | ✅ sí | ninguno incorporado |
| **netplan** | `/etc/netplan/*.yaml` | *renderiza a* NM o networkd | Frontend declarativo, sin runtime | Ubuntu 18.04+ | vía backend | ✅ `netplan try` |
| **wicked** | `/etc/sysconfig/network/ifcfg-*` | `wicked.service` | Declarativo | SLES/openSUSE ≤15 | ✅ sí | ninguno |
| **cloud-init** | `/etc/cloud/cloud.cfg.d/`, datasource | una sola pasada en el primer arranque | Bootstrapper que *escribe* alguno de los anteriores | Todas las imágenes cloud | ❌ (escribe y termina) | n/a |

### 3.1 Elegir un dueño — compromisos

| Criterio | ifupdown | NetworkManager | systemd-networkd |
|---|---|---|---|
| Footprint | ~200 KB de shell | ~30 MB, D-Bus, polkit | dentro de systemd, ~2 MB |
| Roaming / WiFi / WWAN | pobre | excelente | ninguno (requiere pegamento con `wpa_supplicant`) |
| Maneja NIC hotplug | solo `allow-hotplug` | nativo | nativo |
| Aplicación parcial idempotente | ❌ | ✅ `device reapply` | ⚠️ `networkctl reload` (sin cambios de L2) |
| Gestión de DNS | delega en `resolvconf` | sistema de plugins incorporado | solo vía `systemd-resolved` |
| API para automatización | ninguna | D-Bus, `nmstate`, Ansible `nmcli` | solo archivos |
| Validación de la configuración | ninguna | `nmcli` rechaza valores inválidos al momento de fijarlos | algo parecido a `systemd-analyze verify`, débil |
| Encaja en imágenes inmutables/golden | ✅ | ⚠️ estado mutable en `/etc` | ✅ (los archivos pueden vivir en `/usr/lib`) |
| Encaja en escritorio/laptop | ❌ | ✅ | ❌ |
| Recomendado para | flotas Debian heredadas | servidores de la familia RHEL, cualquier host con wireless | servidores Ubuntu, hosts de contenedores mínimos, appliances |

**Heurística de producción:** en la familia RHEL, no pelees con NetworkManager — es el único camino soportado desde RHEL 8 y `network-scripts` fue eliminado por completo en RHEL 9. En Ubuntu Server, no esquives netplan; escribí YAML de netplan y dejá que renderice `systemd-networkd`. En una imagen mínima armada a mano, `systemd-networkd` da la menor superficie de reconciliación.

---

## 4. Persistencia del hostname

### 4.1 Tres hostnames, no uno

`systemd-hostnamed` expone tres valores por D-Bus:

| Tipo | Almacenamiento | Restricciones de formato | Fijado por |
|---|---|---|---|
| **estático** | `/etc/hostname` | Etiqueta(s) RFC 1123, ≤ 64 bytes (`HOST_NAME_MAX`), `[a-zA-Z0-9-.]` | administrador, cloud-init |
| **transitorio** | kernel, vía `sethostname(2)` | las mismas | cliente DHCP, runtime de contenedores, comando `hostname` |
| **pretty** | `/etc/machine-info` → `PRETTY_HOSTNAME=` | UTF-8 de forma libre | administrador |

Precedencia en el arranque: `systemd-hostnamed` fija el hostname del kernel desde `/etc/hostname`; si ese archivo falta o contiene `localhost`, gana el nombre transitorio provisto por DHCP (opción 12 / opción 81).

Formato de `/etc/hostname`: **una línea, un nombre, sin comentarios en las implementaciones clásicas, sin espacios al final**. systemd acepta comentarios con `#` e ignora las líneas en blanco, pero el init `hostname.sh` de Debian históricamente no lo hacía — no te apoyes en eso.

```console
$ cat /etc/hostname
node01.prod.example.net

$ hostnamectl
 Static hostname: node01.prod.example.net
       Icon name: computer-vm
         Chassis: vm 🖴
      Machine ID: 4f3c1a9be6f24d0a8a7e2c5d11b0e9aa
         Boot ID: 9a1f0c73b2ee4c1e9f6d55a2c48b3d10
  Virtualization: kvm
Operating System: Debian GNU/Linux 12 (bookworm)
          Kernel: Linux 6.1.0-18-amd64
    Architecture: x86-64
 Hardware Vendor: QEMU
  Hardware Model: Standard PC _Q35 + ICH9, 2009_
```

```console
# hostnamectl set-hostname node01.prod.example.net
# hostnamectl set-hostname "Prod Node 01 — Rack B14" --pretty
# hostnamectl hostname --static
node01.prod.example.net
```

`hostnamectl set-hostname NAME` sin calificador fija **estático + transitorio** (y el pretty, si la cadena no es una etiqueta DNS válida). `hostname NAME` fija **solo el nombre transitorio** y se pierde al reiniciar — esta distinción es una de las favoritas del examen.

```console
$ hostname                 # transient (kernel)
node01
$ hostname -f              # FQDN via resolver — requires /etc/hosts or DNS to answer
node01.prod.example.net
$ hostname -d              # domain part as resolved
prod.example.net
$ hostname -I              # all configured addresses, no DNS lookup
10.20.0.5 fd00:20::5
```

**`hostname -f` hace una búsqueda de nombre.** Si `/etc/hosts` no tiene una entrada coincidente y el DNS está caído, falla o se cuelga — por eso todo host de producción lleva una entrada estática de sí mismo en `/etc/hosts`.

### 4.2 Impedir que DHCP renombre el host

| Stack | Directiva |
|---|---|
| NetworkManager | `nmcli con mod <name> ipv4.dhcp-send-hostname no` y, global, `hostname-mode=none` en `[main]` de `NetworkManager.conf` |
| systemd-networkd | `[DHCPv4] UseHostname=false` y `SendHostname=false` |
| dhclient | quitar `host-name` de la lista `request` en `/etc/dhcp/dhclient.conf` |
| cloud-init | `preserve_hostname: true` en `/etc/cloud/cloud.cfg` |

```ini
# /etc/NetworkManager/conf.d/00-hostname.conf
[main]
hostname-mode=none
```

### 4.3 La convención de la entrada propia en `/etc/hosts`

Debian escribe una línea **`127.0.1.1`** para que el FQDN resuelva incluso sin red; RHEL pone la dirección real en la línea de la interfaz. Ambas son válidas; el problema empieza al mezclarlas.

```
# /etc/hosts — Debian convention
127.0.0.1       localhost
127.0.1.1       node01.prod.example.net node01

::1             localhost ip6-localhost ip6-loopback
fe00::0         ip6-localnet
ff00::0         ip6-mcastprefix
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters
```

```
# /etc/hosts — RHEL/production-cluster convention
127.0.0.1       localhost localhost.localdomain localhost4
::1             localhost localhost.localdomain localhost6

10.20.0.5       node01.prod.example.net node01
10.20.0.6       node02.prod.example.net node02
10.20.0.7       node03.prod.example.net node03
```

> **Regla de producción para software en clúster** (etcd, Kubernetes, Ceph, RabbitMQ, Pacemaker): el FQDN del nodo **debe** resolver a su dirección enrutable, no a `127.0.1.1`. Una entrada propia `127.0.1.1` hace que los pares anuncien loopback y el clúster forma un conjunto de particiones de un solo nodo. Este es el ticket clásico de "los nodos de etcd no se ven entre sí aunque el ping funcione".

---

## 5. Plano de resolución 1 — `/etc/hosts` y `/etc/nsswitch.conf`

### 5.1 Formato de `/etc/hosts`

```
IP_address    canonical_hostname    [aliases...]
```

Reglas que importan en la práctica:

- Se analiza **de arriba hacia abajo**; gana la primera coincidencia por familia de direcciones.
- Los campos se separan con cualquier espacio en blanco; `#` inicia un comentario.
- Una misma dirección puede aparecer en varias líneas; un nombre que resuelve a varias direcciones las devuelve en el orden del archivo (sin round-robin, sin mezcla — a diferencia del DNS).
- El máximo de alias por línea está limitado por la implementación (glibc: en la práctica un búfer acotado por `_SC_HOST_NAME_MAX`, o sea decenas).
- Las entradas IPv4 e IPv6 son independientes; `getaddrinfo()` las combina según la selección de dirección de destino del RFC 6724.

### 5.2 `/etc/nsswitch.conf` — el despachador

Este archivo decide **qué mecanismo de resolución se consulta, en qué orden y qué pasa después de cada resultado**. Gobierna mucho más que los hosts.

```
# /etc/nsswitch.conf
passwd:         files systemd
group:          files [SUCCESS=merge] systemd
shadow:         files
gshadow:        files

hosts:          files resolve [!UNAVAIL=return] myhostname dns
networks:       files

protocols:      db files
services:       db files
ethers:         db files
rpc:            db files

netgroup:       nis
automount:      files
```

Sintaxis: `database: service1 [STATUS=ACTION] service2 ...`

| Estado | Significado |
|---|---|
| `SUCCESS` | Entrada encontrada, sin error |
| `NOTFOUND` | La búsqueda tuvo éxito, la entrada no está |
| `UNAVAIL` | Servicio permanentemente no disponible (demonio ausente, archivo faltante) |
| `TRYAGAIN` | Servicio temporalmente no disponible (timeout, EAGAIN) |

| Acción | Significado |
|---|---|
| `return` | Detenerse y devolver el resultado actual al llamador |
| `continue` | Probar el siguiente servicio |
| `merge` | Combinar resultados (glibc ≥ 2.24, solo `group`) |

Acciones implícitas por defecto: `[SUCCESS=return NOTFOUND=continue UNAVAIL=continue TRYAGAIN=continue]`. `!` niega un estado: `[!UNAVAIL=return]` significa "para cualquier cosa **distinta de** UNAVAIL, devolver" — es decir, confiar en `systemd-resolved` salvo que directamente no esté corriendo, en cuyo caso se sigue de largo.

Módulos NSS relevantes para `hosts:`:

| Módulo | Biblioteca | Función |
|---|---|---|
| `files` | incorporado en glibc | `/etc/hosts` |
| `dns` | `libnss_dns.so` | resolver clásico, dirigido por `/etc/resolv.conf` |
| `resolve` | `libnss_resolve.so` | `systemd-resolved` por D-Bus/varlink — evita `/etc/resolv.conf` por completo |
| `myhostname` | `libnss_myhostname.so` | sintetiza el hostname local, `localhost`, `_gateway`, `_outbound` |
| `mymachines` | `libnss_mymachines.so` | contenedores de `systemd-nspawn`/machinectl |
| `mdns4_minimal` | `libnss_mdns4_minimal.so` | Avahi, solo `.local` |

**Trampa de orden.** `mdns4_minimal [NOTFOUND=return]` puesto antes de `dns` (el valor por defecto de Ubuntu) implica que ningún nombre `.local` llega jamás al DNS. Los sitios que usan `.local` como sufijo interno de AD deben quitarlo.

**Verificación — cada herramienta toma un camino de código distinto:**

```console
$ getent hosts node02              # full NSS stack, exactly what applications see
10.20.0.6       node02.prod.example.net node02

$ getent ahostsv4 node02           # getaddrinfo() path incl. address selection
10.20.0.6       STREAM node02.prod.example.net
10.20.0.6       DGRAM
10.20.0.6       RAW

$ dig +short node02.prod.example.net    # DNS ONLY — ignores /etc/hosts and nsswitch
10.20.0.6
```

> `dig` y `nslookup` hablan DNS directamente. **Nunca** leen `/etc/hosts` ni `/etc/nsswitch.conf`. Si `ping node02` funciona pero `dig node02` devuelve NXDOMAIN, la respuesta vino de `files` — eso no es un bug, y es una pregunta garantizada del examen. A la inversa, si `dig` funciona y la aplicación no, la falla está en `nsswitch.conf`, no en el DNS.

---

## 6. Plano de resolución 2 — `/etc/resolv.conf` y la guerra por la propiedad

### 6.1 Formato

```
# /etc/resolv.conf
nameserver 10.20.0.53
nameserver 10.20.1.53
search prod.example.net example.net
options ndots:1 timeout:2 attempts:2 rotate single-request-reopen edns0 trust-ad
```

| Directiva | Semántica | Límites duros |
|---|---|---|
| `nameserver` | IP del resolver upstream (v4 o v6) | **`MAXNS` = 3**; las líneas extra se ignoran silenciosamente |
| `search` | Lista de sufijos que se agregan a los nombres cortos | `MAXDNSRCH` = 6 dominios, 256 caracteres en total |
| `domain` | Un único sufijo; **mutuamente excluyente con `search`** — gana la última directiva del archivo | 1 |
| `sortlist` | Lista de máscaras de preferencia de direcciones | 10 |
| `options ndots:n` | Probar el nombre tal cual primero solo si tiene ≥ *n* puntos | por defecto 1 |
| `options timeout:n` | Segundos por servidor por intento | por defecto 5, máx. 30 |
| `options attempts:n` | Rondas sobre la lista de servidores | por defecto 2, máx. 5 |
| `options rotate` | Rota los servidores en round-robin en vez de empezar siempre por el primero | — |
| `options single-request-reopen` | Sockets separados para A y AAAA — workaround para firewalls rotos que descartan una de las consultas paralelas | — |
| `options trust-ad` | Propaga el bit AD de DNSSEC a las aplicaciones | glibc ≥ 2.31 |
| `options use-vc` | Fuerza TCP | — |

**Aritmética de latencia en el peor caso** — la razón por la que `timeout:5 attempts:2` con 3 nameservers es un peligro en producción: un primer resolver muerto cuesta `attempts × timeout` por servidor antes del failover, es decir hasta `3 × 2 × 5 = 30 s` para un solo `getaddrinfo()`. Cada manejador de peticiones síncrono bloqueado 30 s es una caída de servicio. Valor por defecto de producción: `timeout:1 attempts:2` más `rotate`.

**Aritmética de `ndots`** — con `ndots:5` y `search a.svc.cluster.local svc.cluster.local cluster.local`, resolver `api.example.com` (2 puntos < 5) emite 3 consultas calificadas inútiles (A + AAAA cada una = 6 paquetes) antes de la absoluta. Esta es la patología estándar de amplificación de DNS en Kubernetes; en el resolver del *host*, mantené `ndots:1`.

### 6.2 Quién escribe `/etc/resolv.conf`

Esta es la falla de persistencia más frecuente en servidores Linux: un administrador edita el archivo, funciona, y 30 minutos después la renovación de un lease DHCP lo revierte.

| Dueño | Disparador | Neutralizar con |
|---|---|---|
| `dhclient` | bind/renovación del lease, vía `/etc/dhcp/dhclient-enter-hooks.d/resolvconf` | `supersede domain-name-servers ...;` en `dhclient.conf` |
| NetworkManager | activación de la conexión | `dns=none` en `NetworkManager.conf`, o `ipv4.ignore-auto-dns yes` por conexión |
| `systemd-resolved` | cambio del DNS del uplink | gestionarlo vía `resolvectl` / archivos `.network`, no el archivo |
| `resolvconf` / `openresolv` | cualquier suscriptor | `/etc/resolvconf/resolv.conf.d/{head,base,tail}` |
| netplan | `netplan apply` | la sección `nameservers:` del YAML |
| cloud-init | primer arranque | `manage_resolv_conf: false` |

**Determiná el dueño actual antes de editar nada:**

```console
$ ls -l /etc/resolv.conf
lrwxrwxrwx 1 root root 39 Aug 12 09:14 /etc/resolv.conf -> ../run/systemd/resolve/stub-resolv.conf

$ head -3 /etc/resolv.conf
# This is /run/systemd/resolve/stub-resolv.conf managed by man:systemd-resolved(8).
# Do not edit.
#
```

El destino del enlace simbólico *es* la respuesta:

| Destino | Significado | Valor de `nameserver` |
|---|---|---|
| `/run/systemd/resolve/stub-resolv.conf` | Conjunto completo de funciones de resolved: split-DNS, DNSSEC, DNS por enlace | `127.0.0.53` |
| `/run/systemd/resolve/resolv.conf` | resolved escribe los servidores upstream tal cual; sin split-DNS | IPs reales del upstream |
| `/run/NetworkManager/resolv.conf` | NM es el dueño | IPs reales del upstream |
| `/usr/lib/systemd/resolv.conf` | puntero estático al stub, para imágenes | `127.0.0.53` |
| archivo regular | ifupdown/`resolvconf`/manual | varía |

### 6.3 Operación de `systemd-resolved`

```console
$ resolvectl status
Global
         Protocols: LLMNR=resolve -mDNS -DNSOverTLS DNSSEC=no/unsupported
  resolv.conf mode: stub

Link 2 (enp1s0)
    Current Scopes: DNS LLMNR/IPv4
         Protocols: +DefaultRoute +LLMNR -mDNS -DNSOverTLS DNSSEC=no/unsupported
Current DNS Server: 10.20.0.53
       DNS Servers: 10.20.0.53 10.20.1.53
        DNS Domain: prod.example.net

Link 3 (vpn0)
    Current Scopes: DNS
         Protocols: +DefaultRoute -LLMNR -mDNS -DNSOverTLS DNSSEC=no/unsupported
Current DNS Server: 172.16.0.53
       DNS Servers: 172.16.0.53
        DNS Domain: ~corp.internal
```

El *dominio de solo enrutamiento* `~corp.internal` es split-DNS: las consultas de `*.corp.internal` van al resolver de la VPN, todo lo demás al resolver de la LAN. Esta capacidad es la razón del stub `127.0.0.53` — un `/etc/resolv.conf` plano no puede expresar enrutamiento por dominio.

```console
$ resolvectl query node02.prod.example.net
node02.prod.example.net: 10.20.0.6                    -- link: enp1s0

-- Information acquired via protocol DNS in 1.8ms.
-- Data is authenticated: no; Data was acquired via local or encrypted transport: no
-- Data from: network

# resolvectl flush-caches
# resolvectl statistics | head -8
DNSSEC verdicts
Secure: 0
Insecure: 0
Bogus: 0
Indeterminate: 0

Cache
  Current Transactions: 0
  Cache Size: 41
```

### 6.4 La cuestión de `chattr +i`

Hacer inmutable `/etc/resolv.conf` es el consejo favorito de internet y un antipatrón en producción:

```console
# chattr +i /etc/resolv.conf
# lsattr /etc/resolv.conf
----i---------e------- /etc/resolv.conf
```

Funciona, y esconde el defecto real. El cliente DHCP va a registrar `open: Permission denied` en cada renovación, `netplan apply` va a fallar, y el próximo operador se encuentra con un `EPERM` inexplicable. En su lugar, arreglá al dueño:

```ini
# /etc/NetworkManager/conf.d/90-dns-none.conf — NM stops touching resolv.conf entirely
[main]
dns=none
rc-manager=unmanaged
```

Reservá `chattr +i` para una emergencia durante un incidente, y dejalo registrado en el change log.

---

## 7. Configuraciones persistentes completas

Todos los ejemplos apuntan a la misma topología de producción para que se puedan comparar directamente:

```
  bond0 = enp1s0 + enp2s0   (802.3ad LACP, layer3+4 hash)
    ├── bond0.100  → br-mgmt   10.20.0.5/24    gw 10.20.0.1   (default route, metric 100)
    └── bond0.200  → storage   10.30.0.5/24    MTU 9000, no gateway
  DNS: 10.20.0.53, 10.20.1.53   search prod.example.net
```

### 7.1 ifupdown — el clásico de Debian

```
# /etc/network/interfaces
source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback

# --- bond slaves -----------------------------------------------------------
auto enp1s0
iface enp1s0 inet manual
    bond-master bond0

auto enp2s0
iface enp2s0 inet manual
    bond-master bond0

# --- LACP bond -------------------------------------------------------------
auto bond0
iface bond0 inet manual
    bond-mode 802.3ad
    bond-slaves enp1s0 enp2s0
    bond-miimon 100
    bond-lacp-rate 1
    bond-xmit-hash-policy layer3+4
    bond-downdelay 200
    bond-updelay 200
    up   ip link set dev bond0 mtu 9000
    post-up ip link set dev bond0 txqueuelen 10000

# --- management VLAN on a bridge ------------------------------------------
auto bond0.100
iface bond0.100 inet manual
    vlan-raw-device bond0

auto br-mgmt
iface br-mgmt inet static
    bridge_ports bond0.100
    bridge_stp off
    bridge_fd 0
    bridge_maxwait 0
    address 10.20.0.5/24
    gateway 10.20.0.1
    dns-nameservers 10.20.0.53 10.20.1.53
    dns-search prod.example.net
    up   ip route add 10.99.0.0/16 via 10.20.0.254 dev br-mgmt
    down ip route del 10.99.0.0/16 || true

iface br-mgmt inet6 static
    address fd00:20::5/64
    gateway fd00:20::1
    accept_ra 0

# --- storage VLAN, jumbo frames, no gateway --------------------------------
auto bond0.200
iface bond0.200 inet static
    vlan-raw-device bond0
    address 10.30.0.5/24
    mtu 9000
```

Semántica que entra en el examen:

| Palabra clave | Efecto |
|---|---|
| `auto <if>` | La levanta `ifup -a` en el arranque, de forma síncrona — el arranque **se bloquea** esperándola |
| `allow-hotplug <if>` | Se levanta ante el evento `add`/`change` de udev; correcto para NICs removibles y de enlace lento |
| `iface X inet static` | IPv4 estática; `inet6` para IPv6; `inet manual` = configurar el enlace, sin asignar dirección |
| `inet dhcp` | Ejecuta el cliente DHCP configurado (`dhclient`, `udhcpc`, `dhcpcd`) |
| `pre-up` / `up` / `post-up` | Hooks; una salida distinta de cero en `pre-up`/`up` aborta la interfaz |
| `down` / `post-down` | Hooks de desmontaje |
| `source` / `source-directory` | Incluyen fragmentos; **`source-directory` ignora los archivos con puntos en el nombre** (reglas de run-parts) |

```console
# ifquery --state                       # what ifupdown believes is up
lo=lo
bond0=bond0
br-mgmt=br-mgmt

# ifquery br-mgmt                       # effective parsed stanza
address: 10.20.0.5/24
gateway: 10.20.0.1
bridge_ports: bond0.100
dns-nameservers: 10.20.0.53 10.20.1.53

# ifdown br-mgmt && ifup -v br-mgmt
Configuring interface br-mgmt=br-mgmt (inet)
ip addr add 10.20.0.5/24 broadcast 10.20.0.255 dev br-mgmt label br-mgmt
ip link set dev br-mgmt up
ip route add default via 10.20.0.1 dev br-mgmt onlink
```

> **El estado de `ifupdown` vive en `/run/network/ifstate`.** Si un host queda inconsistente (`ifup` dice "already configured" mientras la interfaz no tiene dirección), el estado de ejecución y el archivo de estado divergieron — `ip link set dev X down; rm /run/network/ifstate.X; ifup X` lo recupera. `ifupdown` nunca reconcilia: aplica una vez y se olvida.

**En RHEL 9+, `ifup`/`ifdown` son shims.** `network-scripts` fue eliminado; `/usr/sbin/ifup`, de `NetworkManager-initscripts-updown`, simplemente llama a `nmcli connection up`. Los archivos `ifcfg-*` heredados los lee el plugin obsoleto `ifcfg-rh` de NM (eliminado en RHEL 10).

### 7.2 NetworkManager — `nmcli` y el formato keyfile

Construcción imperativa completa, exactamente como correría en un runbook:

```console
# nmcli connection add type bond ifname bond0 con-name bond0 \
    bond.options "mode=802.3ad,miimon=100,lacp_rate=fast,xmit_hash_policy=layer3+4" \
    ipv4.method disabled ipv6.method disabled connection.autoconnect yes
Connection 'bond0' (2a6a7f1c-8b3e-4f22-9d61-7c0f2b5a1e44) successfully added.

# nmcli connection add type ethernet ifname enp1s0 con-name bond0-p1 master bond0 slave-type bond
Connection 'bond0-p1' (7e1d0c2b-4a55-4b9c-9e02-1f3d6a8c9b70) successfully added.

# nmcli connection add type ethernet ifname enp2s0 con-name bond0-p2 master bond0 slave-type bond
Connection 'bond0-p2' (b0c9e4a1-33d7-4a18-8f5c-2d1b7e6f4a93) successfully added.

# nmcli connection add type vlan ifname bond0.100 con-name mgmt-vlan dev bond0 id 100 \
    ipv4.method manual \
    ipv4.addresses 10.20.0.5/24 \
    ipv4.gateway 10.20.0.1 \
    ipv4.dns "10.20.0.53,10.20.1.53" \
    ipv4.dns-search "prod.example.net" \
    ipv4.dns-priority 100 \
    ipv4.routes "10.99.0.0/16 10.20.0.254" \
    ipv4.route-metric 100 \
    ipv4.may-fail no \
    ipv6.method manual \
    ipv6.addresses fd00:20::5/64 \
    ipv6.gateway fd00:20::1 \
    connection.autoconnect yes
Connection 'mgmt-vlan' (c41f9a02-77be-4d3a-b6a8-5e9c0f21d8b3) successfully added.

# nmcli connection add type vlan ifname bond0.200 con-name storage-vlan dev bond0 id 200 \
    ipv4.method manual ipv4.addresses 10.30.0.5/24 ipv4.never-default yes \
    802-3-ethernet.mtu 9000 ipv6.method disabled
Connection 'storage-vlan' (e5a7c318-2f40-4c99-8b1d-6a0e3d7f5c21) successfully added.

# nmcli connection up mgmt-vlan
Connection successfully activated (D-Bus active path: /org/freedesktop/NetworkManager/ActiveConnection/7)
```

El keyfile persistido resultante — esta es la verdad en disco, y conocerla es lo que permite revisar la configuración en Git:

```ini
# /etc/NetworkManager/system-connections/mgmt-vlan.nmconnection   (mode 0600, root:root)
[connection]
id=mgmt-vlan
uuid=c41f9a02-77be-4d3a-b6a8-5e9c0f21d8b3
type=vlan
interface-name=bond0.100
autoconnect=true
autoconnect-retries=0

[vlan]
flags=1
id=100
parent=bond0

[ipv4]
method=manual
address1=10.20.0.5/24,10.20.0.1
dns=10.20.0.53;10.20.1.53;
dns-search=prod.example.net;
dns-priority=100
route1=10.99.0.0/16,10.20.0.254
route-metric=100
may-fail=false

[ipv6]
method=manual
address1=fd00:20::5/64,fd00:20::1
addr-gen-mode=stable-privacy

[proxy]
```

> **`ipv4.may-fail no`** hace que `NetworkManager-wait-online.service` se bloquee hasta que IPv4 esté realmente configurado. Sin esto, un host con `ipv6.method=auto` se declara "online" apenas existe una dirección link-local, y toda unit con `After=network-online.target` arranca antes de que la dirección IPv4 esté levantada. Esta única propiedad arregla la mayoría de los bugs del tipo "el servicio arrancó antes de que la red estuviera lista".

Los keyfiles se pueden editar a mano, pero hay que avisarle a NM:

```console
# chmod 600 /etc/NetworkManager/system-connections/mgmt-vlan.nmconnection
# nmcli connection reload                 # re-read files, no activation
# nmcli device reapply bond0.100          # apply changed L3 settings without dropping the link
Connection successfully reapplied to device 'bond0.100'.
```

`nmcli device reapply` no puede cambiar atributos de L2 (MTU, modo del bond, esclavos). Eso requiere un `nmcli connection down && nmcli connection up` completo.

Inspección:

```console
$ nmcli -f NAME,UUID,TYPE,DEVICE connection show
NAME           UUID                                  TYPE      DEVICE
bond0          2a6a7f1c-8b3e-4f22-9d61-7c0f2b5a1e44  bond      bond0
mgmt-vlan      c41f9a02-77be-4d3a-b6a8-5e9c0f21d8b3  vlan      bond0.100
storage-vlan   e5a7c318-2f40-4c99-8b1d-6a0e3d7f5c21  vlan      bond0.200
bond0-p1       7e1d0c2b-4a55-4b9c-9e02-1f3d6a8c9b70  ethernet  enp1s0
bond0-p2       b0c9e4a1-33d7-4a18-8f5c-2d1b7e6f4a93  ethernet  enp2s0

$ nmcli device status
DEVICE     TYPE      STATE                   CONNECTION
bond0      bond      connected               bond0
bond0.100  vlan      connected               mgmt-vlan
bond0.200  vlan      connected               storage-vlan
enp1s0     ethernet  connected (externally)  bond0-p1
enp2s0     ethernet  connected (externally)  bond0-p2
lo         loopback  unmanaged               --

$ nmcli -f IP4 device show bond0.100
IP4.ADDRESS[1]:                         10.20.0.5/24
IP4.GATEWAY:                            10.20.0.1
IP4.ROUTE[1]:                           dst = 10.20.0.0/24, nh = 0.0.0.0, mt = 100
IP4.ROUTE[2]:                           dst = 0.0.0.0/0, nh = 10.20.0.1, mt = 100
IP4.ROUTE[3]:                           dst = 10.99.0.0/16, nh = 10.20.0.254, mt = 100
IP4.DNS[1]:                             10.20.0.53
IP4.DNS[2]:                             10.20.1.53
IP4.SEARCHES[1]:                        prod.example.net
```

Marcar una interfaz como no gestionada (por ejemplo, una NIC en manos de DPDK, una VF o un bridge gestionado por el CNI):

```ini
# /etc/NetworkManager/conf.d/99-unmanaged.conf
[keyfile]
unmanaged-devices=interface-name:cali*;interface-name:flannel*;interface-name:cni0;interface-name:veth*;interface-name:vxlan.calico
```

### 7.3 systemd-networkd

Los archivos se procesan en **orden lexicográfico** y gana el **primer** `.network` que coincide por interfaz — de ahí la convención del prefijo numérico `NN-`.

```ini
# /etc/systemd/network/10-bond0.netdev
[NetDev]
Name=bond0
Kind=bond
MTUBytes=9000

[Bond]
Mode=802.3ad
TransmitHashPolicy=layer3+4
MIIMonitorSec=100ms
LACPTransmitRate=fast
UpDelaySec=200ms
DownDelaySec=200ms
```

```ini
# /etc/systemd/network/11-vlan100.netdev
[NetDev]
Name=bond0.100
Kind=vlan

[VLAN]
Id=100
```

```ini
# /etc/systemd/network/12-vlan200.netdev
[NetDev]
Name=bond0.200
Kind=vlan
MTUBytes=9000

[VLAN]
Id=200
```

```ini
# /etc/systemd/network/20-bond-slaves.network
[Match]
Name=enp1s0 enp2s0

[Network]
Bond=bond0
LinkLocalAddressing=no
IPv6AcceptRA=no
```

```ini
# /etc/systemd/network/30-bond0.network
[Match]
Name=bond0

[Network]
VLAN=bond0.100
VLAN=bond0.200
LinkLocalAddressing=no
IPv6AcceptRA=no
ConfigureWithoutCarrier=no
```

```ini
# /etc/systemd/network/40-mgmt.network
[Match]
Name=bond0.100

[Link]
RequiredForOnline=routable

[Network]
Address=10.20.0.5/24
Address=fd00:20::5/64
Gateway=10.20.0.1
Gateway=fd00:20::1
DNS=10.20.0.53
DNS=10.20.1.53
Domains=prod.example.net
IPv6AcceptRA=no
IPForward=yes

[Route]
Destination=10.99.0.0/16
Gateway=10.20.0.254
Metric=100

[RoutingPolicyRule]
From=10.20.0.5/32
Table=100
Priority=1000
```

```ini
# /etc/systemd/network/41-storage.network
[Match]
Name=bond0.200

[Link]
MTUBytes=9000
RequiredForOnline=carrier

[Network]
Address=10.30.0.5/24
LinkLocalAddressing=no
IPv6AcceptRA=no
DHCP=no
```

```console
# networkctl reload            # re-read .network files, apply what can be applied live
# networkctl reconfigure bond0.100
# networkctl list
IDX LINK      TYPE     OPERATIONAL SETUP
  1 lo        loopback carrier     unmanaged
  2 enp1s0    ether    enslaved    configured
  3 enp2s0    ether    enslaved    configured
  4 bond0     bond     carrier     configured
  5 bond0.100 vlan     routable    configured
  6 bond0.200 vlan     routable    configured

6 links listed.

# networkctl status bond0.100
● 5: bond0.100
                     Link File: /usr/lib/systemd/network/99-default.link
                  Network File: /etc/systemd/network/40-mgmt.network
                          Type: vlan
                         State: routable (configured)
                  Online state: online
                        Driver: 802.1Q VLAN Support
                           MTU: 1500
                       Address: 10.20.0.5 (static)
                                fd00:20::5 (static)
                       Gateway: 10.20.0.1
                           DNS: 10.20.0.53
                                10.20.1.53
                Search Domains: prod.example.net
```

Los valores de `SETUP` son el diagnóstico: `configured` (un `.network` coincidió y se aplicó), `unmanaged` (sin coincidencia, networkd no la toca), `failed` (coincidió pero la aplicación dio error — revisá `journalctl -u systemd-networkd`), `pending` (esperando carrier).

`RequiredForOnline=` determina qué espera `systemd-networkd-wait-online.service`. Poné `no` en la NIC de almacenamiento para que un switch de storage caído no retrase el arranque 120 s.

### 7.4 netplan (Ubuntu) — YAML completo

netplan **no tiene runtime**: renderiza archivos de unit de `systemd-networkd` (o keyfiles de NM) bajo `/run/` y luego cede el control.

```yaml
# /etc/netplan/50-production.yaml     (must be mode 0600 — netplan >= 0.106 warns otherwise)
network:
  version: 2
  renderer: networkd

  ethernets:
    enp1s0:
      match:
        macaddress: "52:54:00:a1:b2:c3"
      set-name: enp1s0
      dhcp4: false
      dhcp6: false
      mtu: 9000
    enp2s0:
      match:
        macaddress: "52:54:00:a1:b2:c4"
      set-name: enp2s0
      dhcp4: false
      dhcp6: false
      mtu: 9000

  bonds:
    bond0:
      interfaces: [enp1s0, enp2s0]
      mtu: 9000
      parameters:
        mode: 802.3ad
        lacp-rate: fast
        mii-monitor-interval: 100
        transmit-hash-policy: layer3+4
        up-delay: 200
        down-delay: 200
      dhcp4: false
      dhcp6: false

  vlans:
    bond0.100:
      id: 100
      link: bond0
      dhcp4: false
      dhcp6: false
    bond0.200:
      id: 200
      link: bond0
      mtu: 9000
      dhcp4: false
      dhcp6: false
      addresses:
        - 10.30.0.5/24

  bridges:
    br-mgmt:
      interfaces: [bond0.100]
      parameters:
        stp: false
        forward-delay: 0
      addresses:
        - 10.20.0.5/24
        - "fd00:20::5/64"
      nameservers:
        addresses: [10.20.0.53, 10.20.1.53]
        search: [prod.example.net, example.net]
      routes:
        - to: default
          via: 10.20.0.1
          metric: 100
          on-link: true
        - to: "::/0"
          via: "fd00:20::1"
          metric: 100
        - to: 10.99.0.0/16
          via: 10.20.0.254
          metric: 200
        - to: 0.0.0.0/0
          via: 10.20.0.1
          table: 100
      routing-policy:
        - from: 10.20.0.5/32
          table: 100
          priority: 1000
      accept-ra: false
      link-local: []
```

```console
# netplan get bridges.br-mgmt.addresses
- 10.20.0.5/24
- fd00:20::5/64

# netplan generate                # render only; no apply. Fails loudly on schema errors
# ls /run/systemd/network/
10-netplan-bond0.netdev  10-netplan-bond0.network  10-netplan-br-mgmt.netdev
10-netplan-br-mgmt.network  10-netplan-bond0.100.netdev  10-netplan-bond0.100.network
10-netplan-enp1s0.link  10-netplan-enp1s0.network  10-netplan-enp2s0.link  10-netplan-enp2s0.network

# netplan try --timeout 90
Do you want to keep these settings?

Press ENTER before the timeout to accept the new configuration

Changes will revert in 87 seconds
```

```console
# netplan status --all
     Online state: online
    DNS Addresses: 10.20.0.53
                   10.20.1.53
       DNS Search: prod.example.net
                   example.net

●  4: bond0 bond UP (networkd: bond0)
      MAC Address: 52:54:00:a1:b2:c3
       Addresses: -
●  6: br-mgmt bridge UP (networkd: br-mgmt)
      MAC Address: 52:54:00:a1:b2:c3
        Addresses: 10.20.0.5/24
                   fd00:20::5/64
           Routes: default via 10.20.0.1 from 10.20.0.5 metric 100 (static)
                   10.20.0.0/24 from 10.20.0.5 metric 0 (link)
                   10.99.0.0/16 via 10.20.0.254 metric 200 (static)
```

**`netplan try` es el único stack con rollback incorporado**, y es la forma correcta de tocar la red de un host remoto a través del mismísimo enlace que estás cambiando. Su equivalente para los otros stacks es un dead-man's switch programado:

```console
# systemd-run --on-active=300 --timer-property=AccuracySec=1s \
    /bin/sh -c 'cp /root/net-backup/*.nmconnection /etc/NetworkManager/system-connections/ && nmcli connection reload && nmcli connection up mgmt-vlan'
Running timer as unit: run-r7d0a1.timer
Will run service as unit: run-r7d0a1.service
```

Aplicá el cambio; si seguís conectado, `systemctl stop run-r7d0a1.timer`. Si no, la máquina se restaura sola en cinco minutos.

Precedencia de archivos en netplan: los de `/run/netplan` prevalecen sobre `/etc/netplan`, que prevalece sobre `/lib/netplan`, y dentro de cada uno rige el orden lexicográfico — los archivos posteriores **fusionan y sobrescriben** las claves anteriores. `/etc/netplan/99-override.yaml` le gana a `/etc/netplan/50-cloud-init.yaml`.

### 7.5 cloud-init — el escritor del primer arranque

Las imágenes cloud generan la configuración de red en el primer arranque a partir del datasource, y esta **sobrescribe la configuración hecha a mano** salvo que se la deshabilite. Network config v2 es el esquema de netplan tal cual.

```yaml
# /etc/cloud/cloud.cfg.d/50-network.cfg
network:
  version: 2
  ethernets:
    enp1s0:
      dhcp4: false
      addresses: [10.20.0.5/24]
      routes:
        - to: default
          via: 10.20.0.1
      nameservers:
        addresses: [10.20.0.53, 10.20.1.53]
        search: [prod.example.net]
```

```yaml
# /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
# Hand control to the local stack permanently — do this once the host is provisioned.
network: {config: disabled}
```

```yaml
# /etc/cloud/cloud.cfg.d/98-hostname.cfg
preserve_hostname: true
manage_etc_hosts: false
manage_resolv_conf: false
```

```console
$ cloud-init query --format '{{ds.meta_data.hostname}}' 2>/dev/null
node01
$ cloud-init schema --system --annotate
Valid schema /var/lib/cloud/instances/i-0ab3/cloud-config.txt
$ cloud-init status --long
status: done
extended_status: done
boot_status_code: enabled-by-generator
last_update: Tue, 12 Aug 2026 09:14:22 +0000
```

### 7.6 A nivel de flota: Ansible

```yaml
# roles/network/tasks/main.yml
---
- name: Ensure static hostname is persistent
  ansible.builtin.hostname:
    name: "{{ inventory_hostname }}"
    use: systemd

- name: Ensure self-entry in /etc/hosts points at the routable address
  ansible.builtin.lineinfile:
    path: /etc/hosts
    regexp: '^\S+\s+{{ inventory_hostname }}\b'
    line: "{{ mgmt_ipv4 }} {{ inventory_hostname }} {{ inventory_hostname.split('.')[0] }}"
    state: present
    owner: root
    group: root
    mode: "0644"

- name: Remove the Debian 127.0.1.1 self-entry (breaks cluster peer discovery)
  ansible.builtin.lineinfile:
    path: /etc/hosts
    regexp: '^127\.0\.1\.1\s'
    state: absent

- name: Pin the hosts NSS order
  ansible.builtin.lineinfile:
    path: /etc/nsswitch.conf
    regexp: '^hosts:'
    line: 'hosts:          files resolve [!UNAVAIL=return] myhostname dns'

- name: Declare the management connection (NetworkManager)
  community.general.nmcli:
    conn_name: mgmt-vlan
    ifname: bond0.100
    type: vlan
    vlanid: 100
    vlandev: bond0
    ip4: "{{ mgmt_ipv4 }}/24"
    gw4: 10.20.0.1
    dns4: [10.20.0.53, 10.20.1.53]
    dns4_search: [prod.example.net]
    method4: manual
    may_fail4: false
    autoconnect: true
    state: present
  notify: reapply network

- name: Verify the config survives a cold start (offline validation)
  ansible.builtin.command: nmcli --offline connection show
  changed_when: false
  register: nm_offline
  failed_when: "'mgmt-vlan' not in nm_offline.stdout"
```

---

## 8. Semántica de aplicación y rollback — la chuleta del operador

| Operación | ifupdown | NetworkManager | systemd-networkd | netplan |
|---|---|---|---|---|
| Recargar la configuración, sin aplicar | n/a | `nmcli connection reload` | `networkctl reload` | `netplan generate` |
| Aplicar a una sola interfaz | `ifdown X && ifup X` | `nmcli device reapply X` | `networkctl reconfigure X` | `netplan apply` (global) |
| Reaplicación completa | `systemctl restart networking` | `systemctl restart NetworkManager` | `systemctl restart systemd-networkd` | `netplan apply` |
| Aplicación remota segura | — | dead-man con `systemd-run --on-active` | ídem | **`netplan try`** |
| Cambia L2 (MTU/bond) en caliente | ✅ vía hooks | ❌ requiere down/up | ⚠️ parcial | ⚠️ depende del backend |
| Validar antes de aplicar | ninguna | `nmcli --offline connection show` | ninguna | `netplan generate` |

> Reiniciar `NetworkManager.service` **no** tira las conexiones activas por defecto (`[main] no-auto-default`, más el hecho de que NM adopta los dispositivos existentes), mientras que reiniciar `systemd-networkd` puede vaciar brevemente las direcciones de las interfaces cuyo `.network` cambió. Ninguna de las dos es una operación remota segura sin un dead-man's switch.

---

## 9. Verificación y diagnóstico

### 9.1 La escalera de verificación — lo más barato y decisivo primero

```console
# 1. Is the config plane syntactically valid?  (before touching anything)
$ netplan generate && echo OK
OK
$ nmcli --offline connection show < /etc/NetworkManager/system-connections/mgmt-vlan.nmconnection
$ ifquery --list --allow=auto

# 2. Is L1/L2 up?  Carrier and speed come from the driver, not from your config.
$ ip -br link
lo               UNKNOWN        00:00:00:00:00:00 <LOOPBACK,UP,LOWER_UP>
enp1s0           UP             52:54:00:a1:b2:c3 <BROADCAST,MULTICAST,SLAVE,UP,LOWER_UP>
enp2s0           UP             52:54:00:a1:b2:c3 <BROADCAST,MULTICAST,SLAVE,UP,LOWER_UP>
bond0            UP             52:54:00:a1:b2:c3 <BROADCAST,MULTICAST,MASTER,UP,LOWER_UP>
bond0.100        UP             52:54:00:a1:b2:c3 <BROADCAST,MULTICAST,UP,LOWER_UP>

$ ethtool enp1s0 | grep -E 'Speed|Duplex|Link detected'
	Speed: 10000Mb/s
	Duplex: Full
	Link detected: yes

$ cat /proc/net/bonding/bond0
Ethernet Channel Bonding Driver: v6.1.0-18-amd64
Bonding Mode: IEEE 802.3ad Dynamic link aggregation
Transmit Hash Policy: layer3+4 (1)
MII Status: up
802.3ad info
LACP active: on
LACP rate: fast
Aggregator ID: 1
Number of ports: 2

# 3. Is L3 configured, and does it match the declaration?
$ ip -br -4 addr
lo               UNKNOWN        127.0.0.1/8
bond0.100        UP             10.20.0.5/24
bond0.200        UP             10.30.0.5/24

$ ip route show
default via 10.20.0.1 dev bond0.100 proto static metric 100
10.20.0.0/24 dev bond0.100 proto kernel scope link src 10.20.0.5 metric 100
10.30.0.0/24 dev bond0.200 proto kernel scope link src 10.30.0.5
10.99.0.0/16 via 10.20.0.254 dev bond0.100 proto static metric 200

$ ip route get 8.8.8.8
8.8.8.8 via 10.20.0.1 dev bond0.100 src 10.20.0.5 uid 0
    cache

# 4. Is the identity plane right?
$ hostnamectl hostname --static
node01.prod.example.net
$ getent hosts $(hostname -s)
10.20.0.5       node01.prod.example.net node01

# 5. Is the resolution plane right?  Three independent probes:
$ getent hosts node02             # NSS: what applications see
$ resolvectl query node02         # resolved: which link answered
$ dig @10.20.0.53 node02.prod.example.net +short   # the server itself
```

`proto` en `ip route` es el campo de procedencia y responde "quién puso esta ruta acá": `kernel` (implícita por una dirección), `static` (un archivo de configuración), `dhcp`, `ra`, `boot` (agregada por un script sin proto), `bird`/`bgp` (un demonio de enrutamiento).

### 9.2 La única prueba que demuestra la persistencia

Nada de lo anterior demuestra que la configuración sobreviva a un reinicio; demuestra que el estado de ejecución es correcto en este momento. La prueba real:

```console
# ip -br addr > /root/pre-reboot.txt && ip route >> /root/pre-reboot.txt
# systemctl reboot
...
$ ip -br addr > /root/post-reboot.txt && ip route >> /root/post-reboot.txt
$ diff /root/pre-reboot.txt /root/post-reboot.txt && echo "PERSISTENCE VERIFIED"
PERSISTENCE VERIFIED
```

Para un host que no podés reiniciar, la aproximación más cercana es un reinicio completo del stack más un carrier flap:

```console
# ip link set dev enp1s0 down && sleep 3 && ip link set dev enp1s0 up
# systemctl restart NetworkManager
# ip -br addr | diff - /root/pre-reboot-addr.txt
```

### 9.3 Forense del arranque

```console
$ journalctl -b -u NetworkManager --no-pager | head -20
Aug 27 08:12:03 node01 NetworkManager[812]: <info>  [1756282323.4412] NetworkManager (version 1.42.4) is starting... (boot:9a1f0c73)
Aug 27 08:12:03 node01 NetworkManager[812]: <info>  [1756282323.4589] manager[0x55c1...]: rfkill: Wi-Fi hardware radio set enabled
Aug 27 08:12:04 node01 NetworkManager[812]: <info>  [1756282324.1023] device (bond0.100): state change: config -> ip-config (reason 'none')
Aug 27 08:12:04 node01 NetworkManager[812]: <info>  [1756282324.3310] device (bond0.100): state change: ip-config -> activated

$ journalctl -b -u systemd-networkd -p warning --no-pager
Aug 27 08:12:05 node01 systemd-networkd[798]: bond0.200: Could not bring up interface: Invalid argument

$ systemd-analyze blame | grep -Ei 'network|wait-online' | head
     31.204s systemd-networkd-wait-online.service
      1.882s NetworkManager.service
      0.421s systemd-resolved.service

$ systemd-analyze critical-chain network-online.target
network-online.target @32.7s
└─systemd-networkd-wait-online.service @1.5s +31.2s
  └─systemd-networkd.service @1.2s +281ms
```

Un `wait-online` de 30 segundos es una mala configuración, no un hecho de la vida: significa que la unit está esperando una interfaz que nunca llega a `routable`. Arreglalo con `RequiredForOnline=no` en la interfaz en cuestión, o con `--interface=` / `--any` en la unit de wait-online:

```ini
# /etc/systemd/system/systemd-networkd-wait-online.service.d/override.conf
[Service]
ExecStart=
ExecStart=/usr/lib/systemd/systemd-networkd-wait-online --interface=bond0.100:routable --timeout=30
```

### 9.4 Catálogo de fallas

| Síntoma | Causa más probable | Sonda decisiva | Solución |
|---|---|---|---|
| La dirección está antes del reinicio y desaparece después | Aplicada con `ip addr add`, nunca escrita en un archivo de configuración | `grep -r <ip> /etc/{network,NetworkManager,systemd/network,netplan}` no devuelve nada | Declararla en el stack dueño |
| La dirección desaparece segundos después de un `ip addr add` manual | Un demonio reconciliador es dueño de la interfaz | `nmcli device status` muestra `managed`; `networkctl` muestra `configured` | Cambiar la declaración, no el estado de ejecución |
| `/etc/resolv.conf` se revierte a los minutos | Lo reescribió una renovación DHCP / NM / resolved | `ls -l /etc/resolv.conf`, `journalctl -u NetworkManager \| grep dns` | Fijar `dns=none` o configurar el DNS en la conexión |
| El nombre de la NIC cambió tras una actualización de distro | Salto de versión del naming-scheme de udev | `udevadm test-builtin net_id`, `cat /sys/class/net/*/uevent` | `net.naming-scheme=vNNN`, o actualizar las declaraciones |
| La interfaz existe pero no tiene configuración | Ningún `.network`/conexión coincidió | `networkctl status X` muestra `unmanaged` / `nmcli` muestra `--` | Corregir el `[Match]` / `interface-name` |
| El arranque se cuelga ~2 min en "A start job is running for Wait for Network" | `wait-online` bloqueado en una NIC sin carrier | `systemd-analyze blame` | `RequiredForOnline=no` o ajustar `ipv4.may-fail` |
| `ping host` funciona, `dig host` da NXDOMAIN | La respuesta vino de `/etc/hosts` | `getent hosts host` vs `dig host` | No es un bug — pero agregá el registro DNS si las apps usan bibliotecas DNS que evitan NSS (Go, JVM) |
| `dig` funciona, la aplicación no puede resolver | A la línea `hosts:` de `nsswitch.conf` le falta `dns`, o hay un `[NOTFOUND=return]` temprano | `getent hosts X` falla mientras `dig X` funciona | Corregir el orden de NSS |
| `hostname -f` se cuelga varios segundos | Sin entrada propia en `/etc/hosts`, el resolver agota el timeout | `strace -e trace=connect hostname -f` | Agregar la entrada propia |
| El hostname vuelve a un nombre de la nube al reiniciar | Opción 12 de DHCP / cloud-init | `hostnamectl` muestra transitorio ≠ estático | `preserve_hostname: true`, `dhcp-send-hostname no` |
| Dos rutas por defecto, el tráfico usa la equivocada | Dos conexiones con `autoconnect` y métricas iguales | `ip route show default` muestra dos entradas | `ipv4.never-default yes` en la secundaria, o `route-metric` distintos |
| Los jumbo frames fallan solo con payloads grandes | MTU persistido en la VLAN pero no en el padre/bond | `ping -M do -s 8972 <peer>` falla, `-s 1472` funciona | Fijar el MTU en el padre **y** en el hijo; MTU del padre ≥ MTU del hijo |
| `nmcli connection up` dice éxito, pero no hay dirección | `ipv4.method` quedó en `disabled`/`auto` aunque se fijaron direcciones | `nmcli -f ipv4 connection show <name>` | `ipv4.method manual` |
| El keyfile editado a mano se ignora | El modo no es 0600, o no se recargó NM | `nmcli connection show` no lo lista; `journalctl -u NetworkManager \| grep -i permission` | `chmod 600` + `nmcli connection reload` |

```console
# The MTU probe worth memorising — 8972 = 9000 - 20 (IP) - 8 (ICMP)
$ ping -M do -s 8972 -c 2 10.30.0.6
PING 10.30.0.6 (10.30.0.6) 8972(9000) bytes of data.
8980 bytes from 10.30.0.6: icmp_seq=1 ttl=64 time=0.213 ms
8980 bytes from 10.30.0.6: icmp_seq=2 ttl=64 time=0.198 ms
```

---

## 10. Repaso: la superficie examinable

| Archivo / herramienta | Gobierna | Regla en una línea |
|---|---|---|
| `/etc/hostname` | El hostname estático | Una línea, un nombre; lo lee `systemd-hostnamed` en el arranque |
| `hostnamectl` | estático / transitorio / pretty | `set-hostname` escribe `/etc/hostname`; `hostname` a secas es solo transitorio |
| `/etc/hosts` | Mapeo local estático nombre→IP | Se consulta antes que el DNS *si* `files` precede a `dns` en nsswitch |
| `/etc/nsswitch.conf` | Orden de las fuentes NSS | La línea `hosts:` decide si se consulta primero `/etc/hosts` o el DNS |
| `/etc/resolv.conf` | Configuración del resolver | `nameserver` (máx. 3), `search` (máx. 6), `options ndots/timeout/attempts` |
| `/etc/network/interfaces` | Declaraciones de ifupdown | `auto` = arranque; `allow-hotplug` = evento de udev; `inet static/dhcp/manual` |
| `ifup` / `ifdown` | Aplicación de ifupdown | El estado está en `/run/network/ifstate`; en RHEL 9+ son shims de NM |
| `nmcli` | NetworkManager | `connection` = perfil persistente; `device` = estado de ejecución; `modify` persiste, `up` activa |
| `*.nmconnection` | Almacén de keyfiles de NM | `/etc/NetworkManager/system-connections/`, modo 0600, `nmcli connection reload` después de editar |
| `*.network` / `*.netdev` / `*.link` | systemd-networkd | `/etc/systemd/network/`, orden lexicográfico, gana el primer `[Match]` |
| `/etc/netplan/*.yaml` | netplan | Solo frontend — renderiza a networkd o NM; `netplan try` da rollback |

**Trampas de alto rendimiento:**

1. Los cambios de `ip`/`ifconfig` **nunca** son persistentes.
2. `hostname foo` es transitorio; `hostnamectl set-hostname foo` es persistente.
3. `dig`/`nslookup` **ignoran** `/etc/hosts` y `/etc/nsswitch.conf`; `ping`/`getent`/las aplicaciones no.
4. `domain` y `search` en `resolv.conf` son mutuamente excluyentes — gana el último del archivo.
5. Solo se usan las primeras **tres** líneas `nameserver`.
6. Editar `/etc/resolv.conf` en un host con systemd-resolved o NM suele ser una acción sin efecto que se revierte.
7. En RHEL 8+, `nmcli` es la herramienta soportada; `/etc/sysconfig/network-scripts` está obsoleto (RHEL 8) y eliminado (RHEL 9).
8. En Ubuntu, editar `/etc/systemd/network/` directamente entra en conflicto con los archivos generados por netplan en `/run/systemd/network/` — pero los archivos de `/etc` le ganan a los de `/run`, lo que deja sin efecto la salida de netplan en silencio y produce un split-brain feo.

---

## 11. Referencias

**LPI — objetivos**
- LPIC-1 Exam 101 objectives (v5.0) — https://www.lpi.org/our-certifications/exam-101-objectives/
- LPIC-1 Exam 102 objectives (v5.0), Topic 109.2 — https://www.lpi.org/our-certifications/exam-102-objectives/

**Hostname e identidad**
- `hostname(5)` — https://www.freedesktop.org/software/systemd/man/latest/hostname.html
- `hostnamectl(1)` — https://www.freedesktop.org/software/systemd/man/latest/hostnamectl.html
- `systemd-hostnamed.service(8)` — https://www.freedesktop.org/software/systemd/man/latest/systemd-hostnamed.service.html
- `machine-info(5)` — https://www.freedesktop.org/software/systemd/man/latest/machine-info.html

**Resolución de nombres**
- GNU C Library — Name Service Switch — https://www.gnu.org/software/libc/manual/html_node/Name-Service-Switch.html
- `nsswitch.conf(5)` — https://man7.org/linux/man-pages/man5/nsswitch.conf.5.html
- `hosts(5)` — https://man7.org/linux/man-pages/man5/hosts.5.html
- `resolv.conf(5)` — https://man7.org/linux/man-pages/man5/resolv.conf.5.html
- `getent(1)` — https://man7.org/linux/man-pages/man1/getent.1.html
- `systemd-resolved.service(8)` — https://www.freedesktop.org/software/systemd/man/latest/systemd-resolved.service.html
- `resolvectl(1)` — https://www.freedesktop.org/software/systemd/man/latest/resolvectl.html
- `nss-myhostname(8)` — https://www.freedesktop.org/software/systemd/man/latest/nss-myhostname.html

**Nombrado de interfaces**
- systemd — Predictable Network Interface Names — https://systemd.io/PREDICTABLE_INTERFACE_NAMES/
- `systemd.link(5)` — https://www.freedesktop.org/software/systemd/man/latest/systemd.link.html
- `systemd.net-naming-scheme(7)` — https://www.freedesktop.org/software/systemd/man/latest/systemd.net-naming-scheme.html

**NetworkManager**
- NetworkManager documentation — https://networkmanager.dev/docs/
- `nmcli(1)` — https://networkmanager.dev/docs/api/latest/nmcli.html
- `nm-settings-keyfile(5)` — https://networkmanager.dev/docs/api/latest/nm-settings-keyfile.html
- `NetworkManager.conf(5)` — https://networkmanager.dev/docs/api/latest/NetworkManager.conf.html
- Red Hat — Configuring and managing networking (RHEL 9) — https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/configuring_and_managing_networking/index

**systemd-networkd**
- `systemd.network(5)` — https://www.freedesktop.org/software/systemd/man/latest/systemd.network.html
- `systemd.netdev(5)` — https://www.freedesktop.org/software/systemd/man/latest/systemd.netdev.html
- `networkctl(1)` — https://www.freedesktop.org/software/systemd/man/latest/networkctl.html
- `systemd-networkd-wait-online.service(8)` — https://www.freedesktop.org/software/systemd/man/latest/systemd-networkd-wait-online.service.html

**Debian ifupdown**
- `interfaces(5)` — https://manpages.debian.org/stable/ifupdown/interfaces.5.en.html
- Debian Reference — Network setup — https://www.debian.org/doc/manuals/debian-reference/ch05.en.html

**netplan y cloud-init**
- Netplan documentation — https://netplan.readthedocs.io/en/stable/
- Netplan YAML configuration reference — https://netplan.readthedocs.io/en/stable/netplan-yaml/
- Ubuntu Server — Network configuration — https://documentation.ubuntu.com/server/explanation/networking/configuring-networks/
- cloud-init — Network configuration — https://cloudinit.readthedocs.io/en/latest/reference/network-config.html
- cloud-init — Network config v2 — https://cloudinit.readthedocs.io/en/latest/reference/network-config-format-v2.html

**Kernel y herramientas**
- `ip(8)` / iproute2 — https://man7.org/linux/man-pages/man8/ip.8.html
- Linux kernel — Bonding driver documentation — https://www.kernel.org/doc/Documentation/networking/bonding.txt
- `dhclient.conf(5)` — https://man.isc.org/dhclient.conf.5
- RFC 6724 — Default Address Selection for IPv6 — https://www.rfc-editor.org/rfc/rfc6724