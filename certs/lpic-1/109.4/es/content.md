# 109.4 — Configure client side DNS

**LPIC-1 · Examen 102-500 · Tema 109: Fundamentos de redes**

> **Alcance de este objetivo:** la resolución de nombres tal como la consume un host cliente — `/etc/hosts`, `/etc/resolv.conf`, `/etc/nsswitch.conf`, `systemd-resolved` y las herramientas de consulta `host`, `dig`, `getent`. La operación de servidores autoritativos (BIND, archivos de zona, firmado DNSSEC) pertenece a LPIC-2 202.x y queda fuera de alcance aquí, salvo donde un flag del lado cliente cambie lo que se le pide al servidor.

---

## 1. Motivación: el resolver es una dependencia compartida y no documentada

Todo sistema distribuido que se opera tiene una dependencia dura implícita que no aparece en ningún diagrama de arquitectura: el resolver del lado cliente. No es un servicio que se ejecuta, es una **biblioteca enlazada a cada proceso de la máquina**, configurada por un archivo que tres demonios distintos creen que les pertenece, y consultada antes de casi toda conexión saliente.

Los modos de falla en producción son consistentemente los mismos cuatro, y los cuatro son del lado cliente:

| Modo de falla | Síntoma que ve la guardia | Causa real |
|---|---|---|
| **Amplificación por lista de búsqueda** | La latencia p99 de un cliente HTTP salta de 8 ms a 200 ms; el QPS de DNS en el resolver es 6× la tasa de peticiones | `options ndots:5` más una lista `search` de 5 entradas convierte una búsqueda externa en 10 consultas (A+AAAA por sufijo) antes de probar el nombre absoluto |
| **Carrera paralela A/AAAA** | Detenciones de exactamente 5,000 s, intermitentes, ~1 de cada 200 conexiones | glibc envía A y AAAA desde el *mismo* puerto origen; una carrera en el NAT de conntrack de Netfilter descarta una respuesta y el resolver agota el `timeout:5` |
| **Fuga de split-horizon** | Un hostname interno resuelve a una IP pública (o a NXDOMAIN) tras reconectar la VPN | Un segundo stack de resolución reescribió `/etc/resolv.conf` y descartó el dominio de enrutamiento por interfaz |
| **Divergencia NSS vs. cable** | `dig` devuelve la respuesta correcta, la aplicación se conecta al host equivocado | `dig` saltea NSS por completo; la aplicación pasó por `/etc/hosts` o por `nss-myhostname` |

Esa última fila es el punto conceptual más importante de este objetivo, y el que más se malinterpreta en las revisiones de incidentes. **`dig` y `host` son clientes del protocolo DNS. Las aplicaciones no.** Las aplicaciones llaman a `getaddrinfo(3)`, que consulta el Name Service Switch, que *puede* — según `/etc/nsswitch.conf` — no enviar jamás un paquete DNS. Cualquier diagnóstico que empieza y termina con `dig` verificó la capa equivocada.

### 1.1 La ruta de resolución, con precisión

```
 application
    │  getaddrinfo("api.example.internal", "443", &hints, &res)
    ▼
 glibc NSS dispatcher                     ← reads /etc/nsswitch.conf
    │
    ├─▶ nss_files      → /etc/hosts                      (no network)
    ├─▶ nss_myhostname → local hostname, _gateway, localhost, _outbound
    ├─▶ nss_resolve    → D-Bus to systemd-resolved (org.freedesktop.resolve1)
    └─▶ nss_dns        → glibc stub resolver (libresolv)
                            │  reads /etc/resolv.conf
                            ▼
                         UDP/53 (fallback TCP/53 on TC=1 or use-vc)
                            ▼
                     recursive resolver (127.0.0.53, dnsmasq, unbound, ISP, CoreDNS…)
```

En esa ruta existen dos superficies de configuración independientes y responden preguntas distintas:

- **`/etc/nsswitch.conf` decide *qué bases de datos se consultan y en qué orden*.**
- **`/etc/resolv.conf` decide *cómo se comporta la base de datos DNS una vez alcanzada*.**

Editar la equivocada es la hora perdida clásica. Si `getent hosts foo` devuelve una respuesta obsoleta que `dig foo` no devuelve, el problema está en `nsswitch.conf`/`hosts`. Si ambos coinciden y ambos están mal, el problema está en `resolv.conf` o aguas arriba.

---

## 2. `/etc/hosts` — la base de datos estática

La base de datos de nombres más antigua del sistema, definida por `hosts(5)`. La consulta `nss_files`, en el orden del archivo, y gana la primera coincidencia. Sin TTL, sin caché negativa, sin más modo de falla que estar equivocada para siempre.

```
$ cat /etc/hosts
127.0.0.1       localhost localhost.localdomain
::1             localhost localhost.localdomain ip6-localhost ip6-loopback
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters

# Canonical hostname of this machine — required by many daemons that
# call gethostname(2) and then resolve the result.
10.42.7.31      node-a.leloir.internal node-a

# Pinned during the 2026-08 registrar migration; remove after TTL drain.
198.51.100.44   artifacts.example.com
```

Formato: `IP_address canonical_hostname [alias...]`. Los campos se separan por espacios en blanco, `#` inicia un comentario. El **primer** nombre de la línea es el nombre canónico: es lo que devuelve una búsqueda inversa por NSS (`getent hosts 10.42.7.31`) y lo que informa `gethostbyaddr`.

### 2.1 Notas de producción que la man page no enfatiza

- **Una entrada en `/etc/hosts` es una caída esperando fecha.** No tiene vencimiento. Cada entrada que se agrega debe ir acompañada de un ticket de eliminación. La 5.ª causa más común de "funciona en todos lados menos en un nodo" es un pin olvidado.
- **El orden importa dentro de una línea y entre líneas.** `nss_files` devuelve la primera línea que coincide; no fusiona varias líneas del mismo nombre salvo que `nsswitch.conf` use la acción `merge` (glibc ≥ 2.24, y solo entre módulos NSS *distintos*, no dentro de `files`).
- **La selección IPv4/IPv6 no la hace `/etc/hosts`.** La hace el ordenamiento de direcciones de destino RFC 6724 de `getaddrinfo`, ajustable en `/etc/gai.conf`. Si un host dual-stack prefiere AAAA y tu camino v6 está agujereado, `/etc/hosts` no es la palanca: lo es `precedence` de `gai.conf`.
- **`HOSTALIASES`** (una variable de entorno que apunta a un archivo de pares `alias realname`) provee una capa de alias por proceso y sin privilegios. Se aplica solo a nombres de una sola etiqueta y solo vía `nss_dns`. Útil para pruebas; un olor de seguridad en producción, ya que la controla el usuario.

---

## 3. `/etc/resolv.conf` — la configuración del stub resolver

Definido por `resolv.conf(5)`, lo parsea `res_init()`/`__res_vinit()` de glibc. Se lee **una vez por proceso** en la primera resolución y se vuelve a leer solo cuando cambia el mtime del archivo (glibc hace `stat(2)` por búsqueda desde 2.26 — glibc más viejo cacheaba indefinidamente, y por eso históricamente los demonios de larga vida necesitaban un reinicio tras un cambio de DNS).

```
$ cat /etc/resolv.conf
# Managed by systemd-resolved(8). Do not edit.
search leloir.internal svc.cluster.local
nameserver 10.42.0.10
nameserver 10.42.0.11
options edns0 trust-ad timeout:2 attempts:2 single-request-reopen rotate
```

### 3.1 Directivas

| Directiva | Significado | Límites duros (glibc) |
|---|---|---|
| `nameserver <IP>` | Resolver recursivo a consultar. IPv4 o IPv6. Se prueban en orden (salvo `rotate`). | **`MAXNS = 3`.** Las líneas adicionales se ignoran en silencio — una trampa genuina en diseños de HA. |
| `search <d1> <d2> …` | Sufijos que se agregan a nombres con menos puntos que `ndots`. | ≤ glibc 2.25: 6 dominios / 256 caracteres. **≥ glibc 2.26: ilimitado.** musl: 256 caracteres en total. |
| `domain <d>` | Forma heredada de sufijo único. **Mutuamente excluyente con `search`** — gana la última directiva del archivo. | — |
| `sortlist <addr/mask>` | Reordena las direcciones devueltas según la subred preferida. Efectivamente obsoleta; `getaddrinfo` la ignora (solo afecta a `gethostbyname`). | 10 entradas |
| `options <opt>[:v] …` | Flags de comportamiento, más abajo. | — |

### 3.2 `options` — las que importan operativamente

| Opción | Por defecto | Efecto | Cuándo cambiarla |
|---|---|---|---|
| `ndots:n` | `1` | Los nombres con **≥ n puntos** se prueban **primero** como absolutos; los que tienen menos puntos pasan primero por la lista `search`. Máximo 15. | Poner `ndots:1` en contenedores para eliminar la amplificación de búsqueda en cargas dominadas por FQDN. |
| `timeout:n` | `5` | Segundos de espera por nameserver por intento. Máximo 30. | `timeout:1`–`2` en una LAN con caché local. 5 s es una eternidad para un cliente HTTP con presupuesto de 3 s. |
| `attempts:n` | `2` | Vueltas sobre la lista completa de nameservers. Máximo 5. | Latencia de resolución en el peor caso = `timeout × attempts × nameservers`. Con los valores por defecto y 3 servidores eso son **30 segundos**. |
| `rotate` | apagada | Round-robin del nameserver inicial por proceso (`RES_ROTATE`). | Reparto de carga rudimentario del lado cliente. Ojo: es **por proceso**, no por consulta — un demonio de un solo proceso se fija a un servidor. |
| `single-request` | apagada | Envía A y AAAA **secuencialmente** en lugar de en paralelo. | Arregla middleboxes rotos; duplica la latencia de las búsquedas dual-stack. |
| `single-request-reopen` | apagada | Envía en paralelo pero usa un **socket nuevo (puerto origen nuevo)** para la segunda consulta. | El arreglo correcto para la clase de bug de la detención de 5 segundos por conntrack. Más barato que `single-request`. |
| `use-vc` | apagada | Fuerza TCP para todas las consultas. | Respuestas grandes, o redes hostiles a UDP. Cuesta un handshake por búsqueda salvo que el resolver mantenga la conexión abierta. |
| `edns0` | apagada (encendida vía `RES_OPTIONS` en la mayoría de las distros) | Anuncia EDNS(0), habilitando respuestas > 512 B sin truncamiento. | Requerida en la práctica para DNSSEC y RRsets grandes. |
| `trust-ad` | apagada (glibc ≥ 2.31) | Propaga el bit `AD` (Authenticated Data) a la aplicación en lugar de limpiarlo. | Solo cuando el camino hasta el resolver es de confianza (loopback, IPsec). Si no, es una mentira que la aplicación va a creer. |
| `no-aaaa` | apagada (glibc ≥ 2.36) | Suprime por completo las consultas AAAA en el stub. | Parques solo IPv4 que quieren reducir a la mitad el QPS de DNS sin parchear aplicaciones. |
| `inet6` | apagada | Heredada: mapea `gethostbyname` a AAAA. Evitar. | — |

### 3.3 Aritmética de `ndots` — ejemplo resuelto

Dado `search a.internal b.internal c.internal` y `options ndots:5`, al resolver `api.example.com` (2 puntos < 5):

```
1.  api.example.com.a.internal      → NXDOMAIN   (A)
2.  api.example.com.a.internal      → NXDOMAIN   (AAAA)
3.  api.example.com.b.internal      → NXDOMAIN   (A)
4.  api.example.com.b.internal      → NXDOMAIN   (AAAA)
5.  api.example.com.c.internal      → NXDOMAIN   (A)
6.  api.example.com.c.internal      → NXDOMAIN   (AAAA)
7.  api.example.com.                → 93.184.216.34
8.  api.example.com.                → 2606:2800:220:1:248:1893:25c8:1946
```

**8 consultas para un nombre, 6 de ellas fallos garantizados.** Con un punto final — `api.example.com.` — el nombre es absoluto y solo ocurren los pasos 7–8. Este es el contenido completo del género "por qué el CoreDNS de mi clúster Kubernetes está a 40k QPS".

### 3.4 Override por proceso sin tocar el archivo

```
$ RES_OPTIONS="ndots:1 timeout:1 attempts:1" getent hosts api.example.com
93.184.216.34   api.example.com

$ LOCALDOMAIN="staging.internal" getent hosts api
10.42.9.7       api.staging.internal
```

`RES_OPTIONS` sobrescribe `options`; `LOCALDOMAIN` sobrescribe `search`. Ambas las lee `res_init()`. Esta es la forma más rápida de probar una hipótesis sobre `ndots` durante un incidente sin cambiar la configuración ni reiniciar nada más.

---

## 4. `/etc/nsswitch.conf` — el Name Service Switch

Definido por `nsswitch.conf(5)`. Cada línea es `database: service [ACTION] service …`. Para este objetivo solo importa la línea `hosts:`.

```
$ grep ^hosts /etc/nsswitch.conf
hosts: files mdns4_minimal [NOTFOUND=return] resolve [!UNAVAIL=return] myhostname dns
```

Se lee de izquierda a derecha: probar `/etc/hosts`; después DNS multicast pero solo para `.local`, y detener toda la búsqueda si responde NOTFOUND; después `systemd-resolved` sobre D-Bus, y **devolver lo que diga salvo que el servicio no esté disponible**; después el módulo de hostname local; y solo como último recurso el stub DNS clásico.

### 4.1 Códigos de estado y acciones

Un módulo devuelve uno de cuatro estados, y la expresión entre corchetes dice qué hacer:

| Estado | Significado |
|---|---|
| `SUCCESS` | Entrada encontrada. Acción por defecto: `return`. |
| `NOTFOUND` | El módulo funcionó, el nombre genuinamente no existe. Acción por defecto: `continue`. |
| `UNAVAIL` | El módulo no pudo ejecutarse (demonio caído, archivo ausente). Por defecto: `continue`. |
| `TRYAGAIN` | Falla transitoria (timeout, límite de recursos). Por defecto: `continue`. |

| Acción | Significado |
|---|---|
| `return` | Detener la búsqueda y entregar el resultado actual a quien llamó. |
| `continue` | Probar el módulo siguiente. |
| `merge` | Combinar el resultado de este módulo con el del siguiente (glibc ≥ 2.24; solo `hosts` y `group`). |

`!` niega: `[!UNAVAIL=return]` significa "para cualquier estado distinto de UNAVAIL, devolver".

### 4.2 Los módulos que vas a encontrar

| Módulo | Paquete | Qué resuelve | Notas |
|---|---|---|---|
| `files` | glibc | `/etc/hosts` | Siempre primero. El más barato, el más peligroso (sin vencimiento). |
| `dns` | glibc | DNS por cable vía `/etc/resolv.conf` | El stub clásico. **Sin caché.** |
| `myhostname` | systemd | Hostname local, `localhost`, `_gateway`, `_outbound`, `_localdnsstub` | Evita que `sudo` se cuelgue cuando falta el hostname en `/etc/hosts`. |
| `resolve` | systemd | D-Bus → `systemd-resolved` | Más rico que el stub: enrutamiento por enlace, resultados DNSSEC, LLMNR/mDNS. |
| `mymachines` | systemd | Contenedores de `machinectl` | Irrelevante fuera de hosts nspawn. |
| `mdns4_minimal` | nss-mdns / Avahi | `*.local` sobre mDNS, solo IPv4 | La variante `_minimal` rechaza nombres que no sean `.local` — por eso es seguro poner `[NOTFOUND=return]` después. |
| `libvirt` / `libvirt_guest` | libvirt-nss | Nombres de invitados desde la base de leases de libvirt | Práctico en hipervisores. |

**Peligro de ordenamiento:** poner un módulo `mdns` plano (no minimal) antes de `dns` manda cada búsqueda pública primero a multicast, agregando un timeout fijo a cada fallo. Usar siempre `mdns4_minimal`/`mdns_minimal` con `[NOTFOUND=return]`.

---

## 5. Stacks de resolución: elegir quién es dueño de `/etc/resolv.conf`

En una distribución moderna, `/etc/resolv.conf` suele ser un enlace simbólico y suele no ser tuyo.

```
$ ls -l /etc/resolv.conf
lrwxrwxrwx. 1 root root 39 Aug 12 09:14 /etc/resolv.conf -> ../run/systemd/resolve/stub-resolv.conf
```

Los cuatro destinos de enlace que vas a encontrar, y qué significa cada uno:

| Destino | Contenido | Implicancia |
|---|---|---|
| `/run/systemd/resolve/stub-resolv.conf` | `nameserver 127.0.0.53` + `options edns0 trust-ad` + lista de búsqueda | Stack `systemd-resolved` completo: caché, enrutamiento por enlace, DNSSEC, DoT. |
| `/run/systemd/resolve/resolv.conf` | Los servidores de **uplink** textualmente | `resolved` sigue corriendo y NSS puede seguir usando `nss-resolve`, pero cualquier cosa que lea el archivo habla directo con el upstream — sin caché local, sin enrutamiento split-horizon. |
| `/run/NetworkManager/resolv.conf` | Configuración fusionada por NM | NM es el dueño (`dns=default`). |
| un archivo real | lo que hayas escrito | Estático. Algo va a terminar sobrescribiéndolo igual. |

### 5.1 Matriz de compromisos

| Stack | Caché | Split DNS por enlace | DNSSEC | DoT/DoH | Huella | Radio de impacto de la falla | Mejor encaje |
|---|---|---|---|---|---|---|---|
| **solo stub de glibc** (`nss_dns`) | ✗ ninguna | ✗ | ✗ (solo bit AD) | ✗ | 0 | Ninguno — no hay demonio que muera | Imágenes de contenedor inmutables, appliances mínimos |
| **systemd-resolved** | ✓ (en memoria, respeta TTL, negativa) | ✓ (dominios de enrutamiento `~example.com`) | ✓ validador | ✓ DoT (`opportunistic`/`yes`) | ~10 MB RSS | Caída del demonio → NSS `resolve` devuelve UNAVAIL, cae a `dns` **solo si nsswitch lo dice** | Hosts Linux de propósito general, laptops, usuarios de VPN |
| **dnsmasq** (vía NM `dns=dnsmasq`) | ✓ | ✓ (`server=/example.com/10.0.0.1`) | ✓ (con `dnssec`) | ✗ (requiere stubby/upstream https) | ~5 MB | Igual que arriba | Escritorios gestionados por NM, routers de borde chicos, combos DHCP+DNS |
| **unbound** | ✓ (grande, prefetch, serve-stale) | ✓ (`forward-zone`) | ✓ validador, endurecido | ✓ DoT upstream | ~30 MB+ | Demonio dedicado; se lo suele emparejar con una segunda instancia | Nodos con carga DNS pesada; flotas SRE sensibles a DNS |
| **NodeLocal DNSCache** (k8s) | ✓ por nodo, upstream TCP | ✓ (zonas del Corefile) | pasa a través | ✓ upstream | DaemonSet | Local al nodo; una caída afecta a un nodo | Clústeres Kubernetes por encima de ~50 nodos |
| **openresolv / resolvconf** | ✗ (es un *fusionador*, no un resolver) | n/a | n/a | n/a | script | Carrera entre suscriptores | Debian/Alpine sin systemd; convivencia VPN + DHCP |

**Recomendación para una flota de servidores Linux:** `systemd-resolved` con `DNSStubListener=yes`, `Cache=yes`, `DNSSEC=allow-downgrade` y `/etc/resolv.conf → stub-resolv.conf`. Te da una caché local (que elimina el precipicio de `timeout×attempts` para búsquedas repetidas), una métrica de aciertos de caché en `resolvectl statistics` que podés scrapear, y enrutamiento split-horizon que sobrevive al vaivén de la VPN. El costo es un demonio más en la ruta crítica — mitigalo con `Restart=always` (por defecto) y una línea de `nsswitch` que caiga a `dns`.

---

## 6. `systemd-resolved` en profundidad

### 6.1 Escuchas

| Dirección | Propósito |
|---|---|
| `127.0.0.53:53` | **Stub listener.** Aplica la lista de búsqueda, el enrutamiento por enlace, la caché y DNSSEC. Es a lo que apunta `stub-resolv.conf`. |
| `127.0.0.54:53` | **Proxy stub** (systemd ≥ 249). Reenvía *textualmente* al upstream actual: sin expansión de la lista de búsqueda, sin caché local, sin procesamiento DNSSEC. Usalo cuando necesites una vista cruda de lo que realmente dice el upstream. |
| D-Bus `org.freedesktop.resolve1` | La ruta de `nss-resolve` — más rica que el stub (devuelve el estado DNSSEC por registro). |

### 6.2 Configuración completa

```ini
# /etc/systemd/resolved.conf.d/10-fleet.conf
#
# Drop-in overrides for the fleet baseline. Never edit
# /etc/systemd/resolved.conf itself: package upgrades replace it.
[Resolve]
# Global fallback servers, used only when no link supplies its own.
# Format: <IP>[#<SNI hostname>]  — the #name is required for DNSOverTLS=yes.
DNS=10.42.0.10#dns.leloir.internal 10.42.0.11#dns.leloir.internal
FallbackDNS=9.9.9.9#dns.quad9.net 1.1.1.1#cloudflare-dns.com

# Suffixes appended to single-label names. A leading '~' makes the entry a
# *routing* domain (used to pick a server) without adding it to the search list.
Domains=leloir.internal ~10.in-addr.arpa ~42.10.in-addr.arpa

# allow-downgrade: validate when the upstream supports DNSSEC, tolerate
# resolvers that strip RRSIG. 'yes' is correct only when you control the
# entire resolver path — captive portals and many corporate resolvers break it.
DNSSEC=allow-downgrade

# opportunistic: use DoT when the server offers it, plaintext otherwise.
# 'yes' requires a #SNI name on every DNS= entry and fails closed.
DNSOverTLS=opportunistic

# Local caching. 'no-negative' caches positive answers only — useful when an
# upstream returns NXDOMAIN during its own outages.
Cache=yes
CacheFromLocalhost=no

DNSStubListener=yes
DNSStubListenerExtra=127.0.0.54

# Link-local protocols: disable on servers. They add multicast traffic and a
# name-collision surface with no upside in a datacentre.
MulticastDNS=no
LLMNR=no

ReadEtcHosts=yes
ResolveUnicastSingleLabel=no
```

Aplicar y confirmar:

```
$ sudo systemctl restart systemd-resolved
$ sudo resolvectl status
Global
         Protocols: -LLMNR -mDNS +DNSOverTLS DNSSEC=allow-downgrade/supported
  resolv.conf mode: stub
Current DNS Server: 10.42.0.10
       DNS Servers: 10.42.0.10 10.42.0.11
      Fallback DNS: 9.9.9.9 1.1.1.1
        DNS Domain: leloir.internal ~10.in-addr.arpa ~42.10.in-addr.arpa

Link 2 (enp1s0)
    Current Scopes: DNS
         Protocols: +DefaultRoute -LLMNR -mDNS +DNSOverTLS DNSSEC=allow-downgrade/supported
Current DNS Server: 10.42.0.10
       DNS Servers: 10.42.0.10 10.42.0.11
        DNS Domain: leloir.internal

Link 4 (wg0)
    Current Scopes: DNS
         Protocols: -DefaultRoute -LLMNR -mDNS -DNSOverTLS DNSSEC=no/unsupported
Current DNS Server: 10.99.0.1
       DNS Servers: 10.99.0.1
        DNS Domain: ~corp.example.com ~99.10.in-addr.arpa
```

Leé con atención ese bloque de `wg0` — es toda la propuesta de valor de `resolved` en un host con VPN. `-DefaultRoute` significa que el enlace nunca recibe consultas generales; `~corp.example.com` significa que solo los nombres bajo ese sufijo se enrutan a `10.99.0.1`. Split-horizon sin una sola línea en `/etc/resolv.conf`.

### 6.3 Manipulación en tiempo de ejecución (no sobrevive a la caída de un enlace)

```
$ sudo resolvectl dns wg0 10.99.0.1
$ sudo resolvectl domain wg0 '~corp.example.com' '~99.10.in-addr.arpa'
$ sudo resolvectl default-route wg0 false
$ sudo resolvectl dnssec wg0 no
$ sudo resolvectl flush-caches
$ resolvectl statistics
DNSSEC verdicts
Secure: 0
Insecure: 4812
Bogus: 0
Indeterminate: 0

Cache
  Current Cache Size: 214
          Cache Hits: 18944
        Cache Misses: 5027
```

`Cache Hits / (Hits + Misses)` es la métrica sobre la que hay que alarmar. Un ratio de aciertos que se derrumba hacia cero significa o bien un upstream con TTL 0, o bien una aplicación que derrota a la caché con nombres únicos.

### 6.4 Consultar a través de `resolved`

```
$ resolvectl query artifacts.leloir.internal
artifacts.leloir.internal: 10.42.7.90                  -- link: enp1s0

-- Information acquired via protocol DNS in 2.1ms.
-- Data is authenticated: no; Data was acquired via local or encrypted transport: yes
-- Data from: network

$ resolvectl query --type=MX example.com
example.com IN MX 0 .                          -- link: enp1s0

-- Information acquired via protocol DNS in 41.7ms.
-- Data is authenticated: yes; Data was acquired via local or encrypted transport: yes
-- Data from: network
```

La línea `Data is authenticated` es el estado de validación DNSSEC — información que `dig` solo puede darte si pedís `+dnssec` *y además* validás por tu cuenta.

---

## 7. NetworkManager como dueño de la configuración

```ini
# /etc/NetworkManager/conf.d/10-dns.conf
[main]
# default          — NM writes /run/NetworkManager/resolv.conf itself
# systemd-resolved — NM pushes per-link DNS into resolved via D-Bus (recommended)
# dnsmasq          — NM spawns a local dnsmasq on 127.0.0.1 with split zones
# none             — NM does not touch DNS at all; you own the file
dns=systemd-resolved

# symlink | file | resolvconf | unmanaged
rc-manager=symlink

[global-dns-domain-*]
servers=10.42.0.10,10.42.0.11
```

Overrides por conexión — el lugar correcto para un servidor estático en una NIC específica:

```
$ sudo nmcli connection modify enp1s0 ipv4.dns "10.42.0.10 10.42.0.11"
$ sudo nmcli connection modify enp1s0 ipv4.dns-search "leloir.internal"
$ sudo nmcli connection modify enp1s0 ipv4.dns-options "ndots:1,timeout:2,attempts:2,single-request-reopen"
$ sudo nmcli connection modify enp1s0 ipv4.ignore-auto-dns yes
$ sudo nmcli connection modify enp1s0 ipv4.dns-priority 10
$ sudo nmcli connection up enp1s0
Connection successfully activated (D-Bus active path: /org/freedesktop/NetworkManager/ActiveConnection/7)

$ nmcli device show enp1s0 | grep -E 'IP4.DNS|IP4.SEARCH'
IP4.DNS[1]:                             10.42.0.10
IP4.DNS[2]:                             10.42.0.11
IP4.SEARCHES[1]:                        leloir.internal
```

`ipv4.dns-priority`: gana el más bajo. Los valores negativos son **exclusivos** — un enlace con prioridad `-42` suprime los servidores de todos los demás enlaces para la ruta por defecto. Esa es la forma soportada de forzar DNS solo por VPN.

### 7.1 Equivalente en `systemd-networkd`

```ini
# /etc/systemd/network/10-uplink.network
[Match]
Name=enp1s0

[Network]
Address=10.42.7.31/24
Gateway=10.42.7.1
DNS=10.42.0.10
DNS=10.42.0.11
Domains=leloir.internal ~10.in-addr.arpa
DNSSEC=allow-downgrade
DNSOverTLS=opportunistic
DNSDefaultRoute=yes

[DHCPv4]
UseDNS=false
UseDomains=false
```

`UseDNS=false` es la contraparte en networkd de `ipv4.ignore-auto-dns yes`: aceptar el direccionamiento del lease DHCP pero rechazar sus resolvers.

### 7.2 `resolvconf` / `openresolv` (Debian, Alpine, sin systemd)

Un fusionador de suscriptores/publicadores, no un resolver. Las interfaces registran sus datos de DNS bajo una clave; `resolvconf` fusiona según una regla de ordenamiento y regenera el archivo.

```
$ sudo tee /etc/resolvconf/resolv.conf.d/head >/dev/null <<'EOF'
# Prepended verbatim to the generated /etc/resolv.conf.
options ndots:1 timeout:2 attempts:2 single-request-reopen edns0
EOF

$ sudo tee /etc/resolvconf/resolv.conf.d/base >/dev/null <<'EOF'
search leloir.internal
EOF

$ sudo resolvconf -u
$ cat /etc/resolv.conf
# Generated by resolvconf
options ndots:1 timeout:2 attempts:2 single-request-reopen edns0
search leloir.internal
nameserver 10.42.0.10
nameserver 10.42.0.11
```

`head` / `base` / `tail` se anteponen/fusionan/anexan. `resolvconf -u` regenera. Los datos por interfaz viven en `/run/resolvconf/interface/`.

---

## 8. Herramientas de consulta — qué prueba realmente cada una

| Herramienta | Ruta que ejercita | ¿Lee `/etc/hosts`? | ¿Lee `nsswitch`? | ¿Lee `resolv.conf`? | Sirve para responder |
|---|---|---|---|---|---|
| `getent hosts` / `getent ahosts` | **NSS completo** (`gethostbyname` / `getaddrinfo`) | ✓ | ✓ | ✓ (vía `nss_dns`) | "¿Qué va a ver mi aplicación?" |
| `resolvectl query` | `systemd-resolved` (D-Bus) | ✓ (`ReadEtcHosts=yes`) | ✗ | ✗ (usa la configuración propia de resolved) | "¿Qué decide resolved, y está autenticado?" |
| `host` | DNS crudo (`libresolv` de BIND) | ✗ | ✗ | ✓ | "¿DNS tiene este registro?" — forma rápida |
| `dig` | DNS crudo (BIND) | ✗ | ✗ | ✓ (salvo `@server`) | "¿Qué hay exactamente en el cable?" |
| `nslookup` | DNS crudo (BIND) | ✗ | ✗ | ✓ | Heredada; sigue distribuyéndose. El modo interactivo es su única ventaja. |
| `ping` | NSS completo | ✓ | ✓ | ✓ | Nada sobre DNS. No diagnostiques DNS con `ping`. |

**Regla:** todo incidente de DNS se diagnostica con *dos* comandos — `getent ahosts <name>` y `dig <name>`. La divergencia localiza la falla en NSS; la coincidencia la empuja aguas arriba.

### 8.1 `getent`

```
$ getent hosts artifacts.leloir.internal
10.42.7.90      artifacts.leloir.internal

$ getent ahosts artifacts.leloir.internal
10.42.7.90      STREAM artifacts.leloir.internal
10.42.7.90      DGRAM
10.42.7.90      RAW
2001:db8:42:7::90 STREAM
2001:db8:42:7::90 DGRAM
2001:db8:42:7::90 RAW

$ getent ahostsv4 artifacts.leloir.internal
10.42.7.90      STREAM artifacts.leloir.internal
10.42.7.90      DGRAM
10.42.7.90      RAW

$ getent hosts 10.42.7.90
10.42.7.90      artifacts.leloir.internal
```

`hosts` usa la ruta heredada `gethostbyname` (sesgada a IPv4). **`ahosts` usa `getaddrinfo`, que es lo que llaman las aplicaciones modernas** — incluido el ordenamiento de direcciones de RFC 6724. Cuando necesites predecir el comportamiento de conexión, usá `ahosts`; el orden de salida es el orden en que la aplicación va a probar.

El estado de salida importa en los scripts: `getent` devuelve `2` cuando no encuentra la clave.

```
$ getent hosts does-not-exist.leloir.internal; echo "exit=$?"
exit=2
```

### 8.2 `host`

```
$ host artifacts.leloir.internal
artifacts.leloir.internal has address 10.42.7.90
artifacts.leloir.internal has IPv6 address 2001:db8:42:7::90

$ host -t MX example.com
example.com mail is handled by 0 .

$ host -t NS example.com
example.com name server a.iana-servers.net.
example.com name server b.iana-servers.net.

$ host 10.42.7.90
90.7.42.10.in-addr.arpa domain name pointer artifacts.leloir.internal.

$ host -a artifacts.leloir.internal 10.42.0.10
Trying "artifacts.leloir.internal"
Using domain server:
Name: 10.42.0.10
Address: 10.42.0.10#53
Aliases:

;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 20544
;; flags: qr aa rd ra; QUERY: 1, ANSWER: 2, AUTHORITY: 1, ADDITIONAL: 1

;; QUESTION SECTION:
;artifacts.leloir.internal.     IN      ANY

;; ANSWER SECTION:
artifacts.leloir.internal. 300  IN      A       10.42.7.90
artifacts.leloir.internal. 300  IN      AAAA    2001:db8:42:7::90

;; AUTHORITY SECTION:
leloir.internal.        3600    IN      NS      ns1.leloir.internal.

Received 118 bytes from 10.42.0.10#53 in 1 ms
```

Flags útiles: `-t <TYPE>` (tipo de registro), `-a` (equivalente a `-t ANY -v`), `-v` (verboso), `-4`/`-6` (familia de transporte), `-T` (TCP), `-W <sec>` (timeout), `-R <n>` (reintentos), `-C` (comparar el SOA en todos los servidores autoritativos — un chequeo rápido de consistencia de zona).

### 8.3 `dig`

La herramienta de referencia. Sintaxis: `dig [@server] [name] [type] [+options] [-flags]`.

```
$ dig artifacts.leloir.internal

; <<>> DiG 9.18.24 <<>> artifacts.leloir.internal
;; global options: +cmd
;; Got answer:
;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 51422
;; flags: qr rd ra; QUERY: 1, ANSWER: 1, AUTHORITY: 0, ADDITIONAL: 1

;; OPT PSEUDOSECTION:
; EDNS: version: 0, flags:; udp: 1232
;; QUESTION SECTION:
;artifacts.leloir.internal.     IN      A

;; ANSWER SECTION:
artifacts.leloir.internal. 300  IN      A       10.42.7.90

;; Query time: 2 msec
;; SERVER: 127.0.0.53#53(127.0.0.53) (UDP)
;; WHEN: Thu Aug 27 11:04:18 -03 2026
;; MSG SIZE  rcvd: 70
```

Cada campo de esa cabecera es diagnóstico:

| Campo | Cómo leerlo |
|---|---|
| `status: NOERROR` | También se ven: `NXDOMAIN` (el nombre no existe), `SERVFAIL` (el resolver se rompió — a menudo **falla de validación DNSSEC**), `REFUSED` (ACL), `NOTIMP`. |
| `flags: qr rd ra` | `aa` = respuesta autoritativa; `ra` = recursión disponible (si falta ⇒ estás hablando con un servidor solo autoritativo); `tc` = truncada, reintentar sobre TCP; `ad` = autenticada por DNSSEC. |
| `OPT PSEUDOSECTION … udp: 1232` | Tamaño de búfer EDNS(0) negociado. `1232` es el valor por defecto posterior al DNS flag day. |
| `SERVER:` | **Qué resolver respondió.** Lo primero que hay que mirar cuando la respuesta sorprende. |
| `Query time` | > 100 ms hacia un resolver de LAN significa que el primer nameserver de la lista está agotando el timeout. |

Invocaciones operativas:

```
# One-line answers — the form for scripts.
$ dig +short artifacts.leloir.internal
10.42.7.90

# Answer section only, no noise.
$ dig +noall +answer example.com A example.com AAAA
example.com.            300     IN      A       93.184.216.34
example.com.            300     IN      AAAA    2606:2800:220:1:248:1893:25c8:1946

# Bypass the local stack entirely — ask a specific server.
$ dig @10.42.0.11 +norecurse artifacts.leloir.internal

# Reverse lookup.
$ dig -x 10.42.7.90 +short
artifacts.leloir.internal.

# Walk the delegation from the root — proves whether the fault is local or in
# the delegation chain. Requires a working root hint path.
$ dig +trace example.com | tail -n 12
example.com.            172800  IN      NS      a.iana-servers.net.
example.com.            172800  IN      NS      b.iana-servers.net.
;; Received 1174 bytes from 192.5.6.30#53(a.gtld-servers.net) in 24 ms

example.com.            300     IN      A       93.184.216.34
;; Received 56 bytes from 199.43.135.53#53(a.iana-servers.net) in 18 ms

# DNSSEC records, and whether validation succeeds locally.
$ dig +dnssec +multi example.com SOA | grep -E 'flags|RRSIG'
;; flags: qr rd ra ad; QUERY: 1, ANSWER: 2, AUTHORITY: 0, ADDITIONAL: 1
example.com.  3600 IN RRSIG SOA 13 2 3600 (

# Force TCP (verifies TCP/53 is not firewalled — a real and frequent cause of
# large-response failures).
$ dig +tcp example.com DNSKEY +short | head -n 1
257 3 13 mdsswUyr3DPW132mOi8V9xESWE8jTo0d...

# Query the raw upstream through resolved's proxy stub, no cache, no search list.
$ dig @127.0.0.54 example.com +short
93.184.216.34
```

Los valores por defecto persistentes viven en `~/.digrc`:

```
$ cat ~/.digrc
+noall +answer +nocmd
```

---

## 9. Contenedores y Kubernetes: el mismo objetivo, más en juego

Un contenedor recibe `/etc/resolv.conf` **inyectado en la creación** por el runtime; es un bind mount, no un archivo gestionado, y editarlo dentro del contenedor no sobrevive a un reinicio.

### 9.1 El `ndots:5` por defecto y su costo

```
$ kubectl exec -it deploy/api -- cat /etc/resolv.conf
search prod.svc.cluster.local svc.cluster.local cluster.local leloir.internal
nameserver 10.96.0.10
options ndots:5
```

Cada llamada a `s3.amazonaws.com` (2 puntos) genera 8 consultas. Anular por carga de trabajo:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
  namespace: prod
spec:
  replicas: 3
  selector:
    matchLabels:
      app: api
  template:
    metadata:
      labels:
        app: api
    spec:
      # ClusterFirst keeps in-cluster service discovery working; dnsConfig
      # below merges on top of the generated file rather than replacing it.
      dnsPolicy: ClusterFirst
      dnsConfig:
        options:
          # Cut search-list amplification: names with >=1 dot go out absolute
          # first. In-cluster single-label lookups ("api", "postgres") still
          # traverse the search list correctly.
          - name: ndots
            value: "1"
          # Bound worst-case resolution latency to 2 x 2 x 1 = 4 s instead of
          # the glibc default 5 x 2 x N.
          - name: timeout
            value: "2"
          - name: attempts
            value: "2"
          # Defeat the conntrack A/AAAA race that produces exact 5 s stalls:
          # the AAAA query gets a fresh source port, so the NAT tuple cannot
          # collide with the in-flight A query.
          - name: single-request-reopen
          - name: edns0
        searches:
          - prod.svc.cluster.local
          - svc.cluster.local
          - cluster.local
      containers:
        - name: api
          image: registry.leloir.internal/api:2.14.0
          ports:
            - name: http
              containerPort: 8080
          env:
            # Belt and braces: overrides resolv.conf for this process tree even
            # if the injected file is regenerated by a different runtime.
            - name: RES_OPTIONS
              value: "ndots:1 timeout:2 attempts:2 single-request-reopen"
          readinessProbe:
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: 5
            periodSeconds: 10
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              memory: 512Mi
```

### 9.2 Un pod que ignora por completo el DNS del clúster

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: dns-diagnostics
  namespace: prod
spec:
  # 'None' discards the runtime-generated file completely; dnsConfig must then
  # supply nameservers itself. Use for tooling pods that must observe upstream
  # behaviour without CoreDNS in the path.
  dnsPolicy: "None"
  dnsConfig:
    nameservers:
      - 10.42.0.10
      - 10.42.0.11
    searches:
      - leloir.internal
    options:
      - name: ndots
        value: "1"
      - name: timeout
        value: "1"
  containers:
    - name: tools
      image: registry.leloir.internal/netshoot:v0.13
      command: ["sleep", "infinity"]
      securityContext:
        capabilities:
          add: ["NET_RAW", "NET_ADMIN"]
  restartPolicy: Never
```

### 9.3 El resolver del clúster: CoreDNS

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns
  namespace: kube-system
data:
  Corefile: |
    .:53 {
        errors
        health {
            lameduck 5s
        }
        ready

        # Serve the cluster zone from the Kubernetes API. 'pods insecure' is
        # the default for the a-b-c-d.ns.pod.cluster.local form; prefer
        # 'pods verified' where the extra API watch cost is acceptable.
        kubernetes cluster.local in-addr.arpa ip6.arpa {
            pods insecure
            fallthrough in-addr.arpa ip6.arpa
            ttl 30
        }

        prometheus :9153

        # Split horizon: internal names go to the corporate resolvers.
        forward leloir.internal 10.42.0.10 10.42.0.11 {
            max_concurrent 1000
        }

        # Everything else follows the node's resolv.conf. force_tcp avoids UDP
        # fragmentation and the conntrack race on the upstream leg.
        forward . /etc/resolv.conf {
            max_concurrent 1000
            policy sequential
            health_check 5s
        }

        # Positive/negative response cache. 'denial' bounds NXDOMAIN caching,
        # which matters because search-list misses are almost all NXDOMAIN.
        cache 30 {
            success 9984 30
            denial 9984 5
        }

        loop
        reload 6s
        loadbalance
    }
```

### 9.4 Caché local al nodo (elimina la ruta por conntrack por pod para los aciertos de caché)

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-local-dns
  namespace: kube-system
  labels:
    k8s-app: node-local-dns
spec:
  selector:
    matchLabels:
      k8s-app: node-local-dns
  updateStrategy:
    rollingUpdate:
      maxUnavailable: 10%
  template:
    metadata:
      labels:
        k8s-app: node-local-dns
      annotations:
        prometheus.io/port: "9253"
        prometheus.io/scrape: "true"
    spec:
      priorityClassName: system-node-critical
      serviceAccountName: node-local-dns
      hostNetwork: true
      dnsPolicy: Default   # do NOT use cluster DNS: that would be a loop
      tolerations:
        - key: CriticalAddonsOnly
          operator: Exists
        - effect: NoExecute
          operator: Exists
        - effect: NoSchedule
          operator: Exists
      containers:
        - name: node-cache
          image: registry.k8s.io/dns/k8s-dns-node-cache:1.23.1
          resources:
            requests:
              cpu: 25m
              memory: 5Mi
          args:
            - "-localip"
            - "169.254.20.10,10.96.0.10"
            - "-conf"
            - "/etc/Corefile"
            - "-upstreamsvc"
            - "kube-dns-upstream"
          securityContext:
            capabilities:
              add: ["NET_ADMIN"]
          ports:
            - containerPort: 53
              name: dns
              protocol: UDP
            - containerPort: 53
              name: dns-tcp
              protocol: TCP
            - containerPort: 9253
              name: metrics
              protocol: TCP
          livenessProbe:
            httpGet:
              host: 169.254.20.10
              path: /health
              port: 8080
            initialDelaySeconds: 60
            timeoutSeconds: 5
          volumeMounts:
            - name: config-volume
              mountPath: /etc/coredns
            - name: xtables-lock
              mountPath: /run/xtables.lock
              readOnly: false
      volumes:
        - name: config-volume
          configMap:
            name: node-local-dns
            items:
              - key: Corefile
                path: Corefile.base
        - name: xtables-lock
          hostPath:
            path: /run/xtables.lock
            type: FileOrCreate
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: node-local-dns
  namespace: kube-system
data:
  Corefile: |
    cluster.local:53 {
        errors
        cache {
            success 9984 30
            denial 9984 5
        }
        reload
        loop
        bind 169.254.20.10 10.96.0.10
        forward . __PILLAR__CLUSTER__DNS__ {
            force_tcp
        }
        prometheus :9253
        health 169.254.20.10:8080
    }
    in-addr.arpa:53 {
        errors
        cache 30
        reload
        loop
        bind 169.254.20.10 10.96.0.10
        forward . __PILLAR__CLUSTER__DNS__ {
            force_tcp
        }
        prometheus :9253
    }
    ip6.arpa:53 {
        errors
        cache 30
        reload
        loop
        bind 169.254.20.10 10.96.0.10
        forward . __PILLAR__CLUSTER__DNS__ {
            force_tcp
        }
        prometheus :9253
    }
    .:53 {
        errors
        cache 30
        reload
        loop
        bind 169.254.20.10 10.96.0.10
        forward . __PILLAR__UPSTREAM__SERVERS__ {
            force_tcp
        }
        prometheus :9253
    }
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: node-local-dns
  namespace: kube-system
```

`force_tcp` en el tramo upstream es el arreglo estructural de la carrera de conntrack sobre UDP: las tuplas TCP se rastrean con una máquina de estados de conexión completa y no colisionan como lo hacen dos datagramas UDP del mismo puerto.

### 9.5 glibc vs. musl — la trampa de Alpine

| Comportamiento | glibc | musl (Alpine) |
|---|---|---|
| `/etc/nsswitch.conf` | Respetado | **Ignorado por completo.** `/etc/hosts` y después DNS, cableado. |
| Orden de nameservers | Secuencial, `timeout`×`attempts` | **Se consulta a todos los nameservers en paralelo**, gana la primera respuesta |
| Lista `search` | Soportada | Soportada (musl ≥ 1.1.13) |
| `ndots` | Soportado, máximo 15 | Soportado |
| `timeout` / `attempts` | Soportados | Soportados (`attempts` es un contador global de reintentos) |
| `single-request-reopen`, `rotate`, `use-vc`, `trust-ad` | Soportados | **Ignorados en silencio** |
| `MAXNS` | 3 | 3 |
| Fallback a TCP con TC=1 | Sí | Sí (musl ≥ 1.2.4); musl más viejo **falla** ante respuestas truncadas |
| Módulos NSS (`myhostname`, `resolve`, `mdns`) | Disponibles | No disponibles |

Consecuencia: el workaround `single-request-reopen` no hace nada en una imagen Alpine. En musl las mitigaciones son `force_tcp` en la caché del nodo, un resolver local al nodo, o cambiar la imagen base por una con glibc.

---

## 10. Verificación y diagnóstico de fallas

### 10.1 El triage estándar de cinco comandos

```
# 1. Who owns the config, and what does it actually say?
$ ls -l /etc/resolv.conf && cat /etc/resolv.conf
lrwxrwxrwx. 1 root root 39 Aug 12 09:14 /etc/resolv.conf -> ../run/systemd/resolve/stub-resolv.conf
# Generated by systemd-resolved(8). Do not edit.
nameserver 127.0.0.53
options edns0 trust-ad
search leloir.internal

# 2. What order will NSS use?
$ grep ^hosts: /etc/nsswitch.conf
hosts: files resolve [!UNAVAIL=return] myhostname dns

# 3. What will the APPLICATION see?  (full NSS path)
$ getent ahosts artifacts.leloir.internal
10.42.7.90      STREAM artifacts.leloir.internal

# 4. What is on the WIRE?  (raw DNS, bypasses NSS)
$ dig +short artifacts.leloir.internal
10.42.7.90

# 5. Is the local resolver stack healthy?
$ resolvectl status --no-pager | head -n 8
$ systemctl is-active systemd-resolved
active
```

### 10.2 Árbol de decisión

| `getent` | `dig` | Conclusión | Paso siguiente |
|---|---|---|---|
| ✓ correcto | ✓ correcto | No es DNS. | Mirar el resolver propio de la aplicación (`networkaddress.cache.ttl` de la JVM, el resolver puro-Go de Go, pools de conexiones que retienen IPs obsoletas). |
| ✓ **incorrecto** | ✓ correcto | NSS está cortocircuitando el DNS. | `grep -n . /etc/hosts`; revisar `nss-myhostname`, la caché de `nss-resolve`, mDNS. |
| ✗ falla | ✓ correcto | Módulo NSS roto u orden de `nsswitch` equivocado. | `journalctl -u systemd-resolved`; revisar si `[!UNAVAIL=return]` está enmascarando un fallthrough. |
| ✓ correcto | ✗ falla | `dig` está consultando un servidor distinto al que usa NSS. | Comparar la línea `SERVER:` de `dig` con `resolvectl status`. |
| ✗ falla | ✗ falla | Upstream o transporte. | `dig +trace`, `tcpdump`, firewall. |

### 10.3 Aislar un resolver lento

```
$ for s in 10.42.0.10 10.42.0.11 127.0.0.53; do
    printf '%-14s ' "$s"
    dig @"$s" +tries=1 +time=2 example.com +noall +stats 2>/dev/null \
      | awk '/Query time/{print $4, $5}' || echo "TIMEOUT"
  done
10.42.0.10     3 msec
10.42.0.11     2001 msec
127.0.0.53     1 msec
```

`10.42.0.11` está muerto pero sigue listado. Con los valores por defecto `timeout:5 attempts:2`, cada búsqueda que rota hacia él cuesta 10 s. La mitigación inmediata es sacarlo del enlace; la sistémica es `timeout:2` más una caché local.

### 10.4 Demostrar la amplificación por `ndots`

```
$ sudo tcpdump -i any -n -s0 'udp port 53' -c 20 &
[1] 40318
$ getent hosts s3.amazonaws.com >/dev/null
11:22:04.118 IP 10.42.7.31.51923 > 10.42.0.10.53: 12043+ A? s3.amazonaws.com.prod.svc.cluster.local. (57)
11:22:04.118 IP 10.42.7.31.51923 > 10.42.0.10.53: 12044+ AAAA? s3.amazonaws.com.prod.svc.cluster.local. (57)
11:22:04.119 IP 10.42.0.10.53 > 10.42.7.31.51923: 12043 NXDomain 0/1/0 (150)
11:22:04.119 IP 10.42.0.10.53 > 10.42.7.31.51923: 12044 NXDomain 0/1/0 (150)
11:22:04.120 IP 10.42.7.31.38112 > 10.42.0.10.53: 8891+ A? s3.amazonaws.com.svc.cluster.local. (52)
11:22:04.120 IP 10.42.7.31.38112 > 10.42.0.10.53: 8892+ AAAA? s3.amazonaws.com.svc.cluster.local. (52)
...
11:22:04.126 IP 10.42.7.31.44070 > 10.42.0.10.53: 3311+ A? s3.amazonaws.com. (34)
11:22:04.131 IP 10.42.0.10.53 > 10.42.7.31.44070: 3311 4/0/0 A 52.216.xx.xx ... (118)
```

Seis consultas desperdiciadas, visibles en el cable, antes de la útil. Después, confirmar el arreglo sin cambiar ningún archivo:

```
$ RES_OPTIONS="ndots:1" getent hosts s3.amazonaws.com >/dev/null
11:24:31.002 IP 10.42.7.31.55210 > 10.42.0.10.53: 44120+ A? s3.amazonaws.com. (34)
11:24:31.002 IP 10.42.7.31.55210 > 10.42.0.10.53: 44121+ AAAA? s3.amazonaws.com. (34)
```

### 10.5 Cazar la detención de 5 segundos

```
$ for i in $(seq 1 300); do
    /usr/bin/time -f '%e' getent hosts api.leloir.internal >/dev/null
  done 2>&1 | sort -rn | head -n 5
5.01
5.01
0.02
0.01
0.01
```

Dos de 300 búsquedas tardaron exactamente 5,01 s — el `timeout:5` por defecto, no un servidor lento. Confirmar la hipótesis de la consulta paralela:

```
$ sudo conntrack -S | awk '{for(i=1;i<=NF;i++) if($i ~ /insert_failed|drop/) printf "%s ", $i; print ""}' | head -n 4
insert_failed=1842 drop=0
insert_failed=1791 drop=0
```

Un `insert_failed` distinto de cero en UDP es la firma. Remediaciones, en orden de preferencia: `single-request-reopen` (solo glibc), `force_tcp` en una caché local al nodo, o `use-vc`.

### 10.6 Distinguir SERVFAIL de una falla DNSSEC

```
$ dig secure-but-broken.example +short
;; communications error to 127.0.0.53#53: SERVFAIL

# Ask again with validation disabled at the stub. If it now answers, the fault
# is DNSSEC (expired RRSIG, missing DS, clock skew), not reachability.
$ dig @10.42.0.10 +cd secure-but-broken.example +short
203.0.113.9

$ journalctl -u systemd-resolved -n 5 --no-pager
systemd-resolved[812]: DNSSEC validation failed for question secure-but-broken.example IN A: signature-expired
```

`+cd` (Checking Disabled) es el discriminador definitivo. Si `+cd` funciona y la consulta simple falla, dejá de mirar la red — revisá las firmas de la zona y el reloj local (`timedatectl`), porque la validación DNSSEC es sensible al tiempo y un host con el reloj desviado rechaza firmas perfectamente válidas.

### 10.7 Comportamiento de la caché

```
$ resolvectl flush-caches
$ resolvectl query example.com | tail -n 3
-- Information acquired via protocol DNS in 38.4ms.
-- Data is authenticated: no; Data was acquired via local or encrypted transport: yes
-- Data from: network

$ resolvectl query example.com | tail -n 3
-- Information acquired via protocol DNS in 1.1ms.
-- Data is authenticated: no; Data was acquired via local or encrypted transport: yes
-- Data from: cache
```

`Data from: cache` frente a `network` es la verdad de campo. Cuando un cambio de DNS "no se propagó todavía", vaciá la caché y volvé a consultar antes de escalar al dueño de la zona.

### 10.8 Qué proceso resolvió qué

```
$ sudo ss -lunp 'sport = :53'
State   Recv-Q  Send-Q   Local Address:Port    Peer Address:Port  Process
UNCONN  0       0         127.0.0.53%lo:53           0.0.0.0:*      users:(("systemd-resolve",pid=812,fd=18))
UNCONN  0       0         127.0.0.54%lo:53           0.0.0.0:*      users:(("systemd-resolve",pid=812,fd=20))

$ sudo strace -f -e trace=connect,sendto,openat -p "$(pgrep -f 'api-server')" 2>&1 \
  | grep -E 'resolv.conf|nsswitch|53\)' | head -n 4
[pid  9911] openat(AT_FDCWD, "/etc/nsswitch.conf", O_RDONLY|O_CLOEXEC) = 7
[pid  9911] openat(AT_FDCWD, "/etc/resolv.conf", O_RDONLY|O_CLOEXEC) = 7
[pid  9911] connect(9, {sa_family=AF_INET, sin_port=htons(53), sin_addr=inet_addr("127.0.0.53")}, 16) = 0
```

Si `strace` muestra que el proceso nunca abre `/etc/resolv.conf`, no está usando el resolver de glibc en absoluto — binarios de Go compilados con `CGO_ENABLED=0`, o un runtime de JVM/Node con su propia caché. La configuración de DNS del lado cliente no lo va a alcanzar, y ese es el hallazgo.

### 10.9 Lista de verificación

```
# Config sanity
[ ] readlink -f /etc/resolv.conf                  # who owns the file
[ ] grep -c '^nameserver' /etc/resolv.conf        # must be <= 3
[ ] grep '^options' /etc/resolv.conf              # ndots/timeout/attempts bounded
[ ] grep '^hosts:' /etc/nsswitch.conf             # order and actions
[ ] getent hosts "$(hostname)"                    # the local name must resolve

# Behaviour
[ ] getent ahosts <name>   ==  dig +short <name>  # NSS vs wire agree
[ ] dig +short <name> @<each nameserver>          # every listed server answers
[ ] dig +tcp <name>                               # TCP/53 is not firewalled
[ ] dig -x <ip> +short                            # reverse zone is delegated
[ ] resolvectl statistics                         # cache hit ratio is sane

# Latency budget
[ ] worst case = timeout x attempts x nameservers # compute it, write it down
```

---

## 11. Referencia de comandos y archivos

| Archivo | Dueño | Propósito |
|---|---|---|
| `/etc/hosts` | admin | Base de datos estática nombre→dirección |
| `/etc/resolv.conf` | stack de resolución | Nameservers, lista de búsqueda, opciones del resolver |
| `/etc/nsswitch.conf` | admin | Qué bases de datos de nombres, y en qué orden |
| `/etc/gai.conf` | admin | Selección/precedencia de direcciones RFC 6724 |
| `/etc/systemd/resolved.conf`, `.conf.d/*.conf` | admin | Configuración de `systemd-resolved` |
| `/run/systemd/resolve/stub-resolv.conf` | systemd-resolved | Apunta a `127.0.0.53` |
| `/run/systemd/resolve/resolv.conf` | systemd-resolved | Servidores de uplink textualmente |
| `/etc/NetworkManager/conf.d/*.conf` | admin | Backend de DNS de NM y `rc-manager` |
| `/etc/resolvconf/resolv.conf.d/{head,base,tail}` | admin | Fragmentos de fusión de `resolvconf` |
| `~/.digrc` | usuario | Opciones por defecto de `dig` |

| Comando | Propósito en una línea |
|---|---|
| `getent hosts` / `getent ahosts` | Resolver por la **ruta NSS completa** — lo que ven las aplicaciones |
| `host <name> [server]` | Búsqueda DNS rápida; `-t` para el tipo, `-a` para todo, `-C` para comparar SOAs |
| `dig [@server] <name> [type] [+opts]` | Consulta DNS de fidelidad completa; `+short`, `+trace`, `+dnssec`, `+cd`, `+tcp` |
| `nslookup <name> [server]` | Herramienta de consulta heredada, todavía presente |
| `resolvectl status\|query\|dns\|domain\|flush-caches\|statistics` | Inspeccionar y controlar `systemd-resolved` |
| `nmcli connection modify … ipv4.dns…` | Persistir DNS por conexión bajo NetworkManager |
| `resolvconf -u` | Regenerar `/etc/resolv.conf` a partir de los suscriptores registrados |
| `ss -lunp 'sport = :53'` | Qué proceso está escuchando en el puerto 53 |
| `tcpdump -i any -n 'port 53'` | Observar las consultas reales |

---

## 12. Referencias

**LPI**
- Objetivos del examen 102-500 (Tema 109.4): https://www.lpi.org/our-certifications/exam-102-objectives/
- Objetivos del examen 101-500: https://www.lpi.org/our-certifications/exam-101-objectives/
- Descripción general de la certificación LPIC-1: https://www.lpi.org/our-certifications/lpic-1-overview/

**Páginas de manual y glibc**
- `resolv.conf(5)`: https://man7.org/linux/man-pages/man5/resolv.conf.5.html
- `hosts(5)`: https://man7.org/linux/man-pages/man5/hosts.5.html
- `nsswitch.conf(5)`: https://man7.org/linux/man-pages/man5/nsswitch.conf.5.html
- `getaddrinfo(3)`: https://man7.org/linux/man-pages/man3/getaddrinfo.3.html
- `gai.conf(5)`: https://man7.org/linux/man-pages/man5/gai.conf.5.html
- `getent(1)`: https://man7.org/linux/man-pages/man1/getent.1.html
- GNU C Library — Name Service Switch: https://www.gnu.org/software/libc/manual/html_node/Name-Service-Switch.html
- NEWS de glibc (límites del resolver, `trust-ad`, `no-aaaa`): https://sourceware.org/glibc/wiki/Release

**systemd**
- `systemd-resolved.service(8)`: https://www.freedesktop.org/software/systemd/man/latest/systemd-resolved.service.html
- `resolved.conf(5)`: https://www.freedesktop.org/software/systemd/man/latest/resolved.conf.html
- `resolvectl(1)`: https://www.freedesktop.org/software/systemd/man/latest/resolvectl.html
- `nss-resolve(8)`: https://www.freedesktop.org/software/systemd/man/latest/nss-resolve.html
- `nss-myhostname(8)`: https://www.freedesktop.org/software/systemd/man/latest/nss-myhostname.html
- `systemd.network(5)`: https://www.freedesktop.org/software/systemd/man/latest/systemd.network.html

**NetworkManager y resolvconf**
- `NetworkManager.conf(5)`: https://networkmanager.dev/docs/api/latest/NetworkManager.conf.html
- `nm-settings(5)` (`ipv4.dns-options`, `ipv4.dns-priority`): https://networkmanager.dev/docs/api/latest/nm-settings-nmcli.html
- openresolv: https://roy.marples.name/projects/openresolv/

**Utilidades de BIND**
- `dig(1)`: https://bind9.readthedocs.io/en/latest/manpages.html#dig-dns-lookup-utility
- `host(1)`: https://bind9.readthedocs.io/en/latest/manpages.html#host-dns-lookup-utility
- Documentación de ISC BIND 9: https://bind9.readthedocs.io/en/latest/

**Kubernetes y contenedores**
- DNS para Services y Pods: https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/
- Personalizar el servicio de DNS: https://kubernetes.io/docs/tasks/administer-cluster/dns-custom-nameservers/
- Depurar la resolución de DNS: https://kubernetes.io/docs/tasks/administer-cluster/dns-debugging-resolution/
- Usar NodeLocal DNSCache: https://kubernetes.io/docs/tasks/administer-cluster/nodelocaldns/
- Manual de CoreDNS: https://coredns.io/manual/toc/
- DNS de contenedores en Docker: https://docs.docker.com/engine/network/#dns-services

**Estándares**
- RFC 1034 — Domain Names, Concepts and Facilities: https://www.rfc-editor.org/rfc/rfc1034
- RFC 1035 — Domain Names, Implementation and Specification: https://www.rfc-editor.org/rfc/rfc1035
- RFC 6724 — Default Address Selection for IPv6: https://www.rfc-editor.org/rfc/rfc6724
- RFC 6891 — Extension Mechanisms for DNS (EDNS(0)): https://www.rfc-editor.org/rfc/rfc6891
- RFC 4033/4034/4035 — DNS Security Introduction and Requirements: https://www.rfc-editor.org/rfc/rfc4033
- RFC 7858 — DNS over TLS: https://www.rfc-editor.org/rfc/rfc7858
- RFC 8482 — Handling of Queries for QTYPE=ANY: https://www.rfc-editor.org/rfc/rfc8482

**musl**
- Comportamiento del resolver DNS de musl y diferencias funcionales con glibc: https://wiki.musl-libc.org/functional-differences-from-glibc.html