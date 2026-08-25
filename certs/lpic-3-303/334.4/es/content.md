# LPIC-3 303 — Tema 334.4: Redes Privadas Virtuales (VPN)

> **Examen:** 303-300 v3.0.0 · **Peso del objetivo:** 6.67 · **Alcance:** principios de las VPN; protocolo OpenVPN, servidores y clientes (routing y bridging); IPsec e IKEv2 con strongSwan (modo tunnel y transport); servidores y clientes WireGuard; conocimiento de L2TP.
> **Archivos y utilidades que tenés que poder operar a ciegas:** `/etc/openvpn/`, `openvpn`, `/etc/ipsec.conf`, `/etc/ipsec.secrets`, `/etc/swanctl/swanctl.conf`, `ipsec`, `swanctl`, `/etc/wireguard/`, `wg`, `wg-quick`.

---

## 1. El problema de producción: qué te compra realmente una VPN, y qué te cuesta

Una VPN no es "cifrado para la red". El cifrado en tránsito es un commodity resuelto — TLS 1.3 te lo da por conexión sin un demonio privilegiado, sin módulo de kernel y sin aritmética de MTU. Lo que te compra una VPN es algo que TLS no puede: **un dominio de routing**. Toma dos espacios de direcciones que no pueden alcanzarse — porque están detrás de NAT, en proveedores distintos, en dominios de fallo distintos — y los hace mutuamente direccionables, con una verificación de identidad criptográfica atada a esa alcanzabilidad.

Ese replanteo maneja cada decisión de diseño de este objetivo:

| Lo que realmente necesitás | No construyas una VPN | Construí una VPN |
|---|---|---|
| Confidencialidad de un protocolo de aplicación | mTLS, SPIFFE/SPIRE, service mesh | — |
| Alcanzabilidad entre islas RFC1918 | — | túnel L3 site-to-site |
| Protocolo legacy que no se puede envolver (SMB, LDAP sin TLS, SCADA, protocolos de cable de bases de datos) | — | túnel L3 site-to-site o de acceso remoto |
| Un único dominio de broadcast L2 plano (sin relay DHCP, PXE, WoL, heartbeat de cluster) | — | túnel L2 (OpenVPN TAP / pseudowire L2TPv3 / GRETAP sobre IPsec) |
| Acceso de operadores a producción | Bastión + SSH CA + certificados de vida corta | VPN de acceso remoto sólo cuando la herramienta en sí es L3 (kubectl a un API server privado, RDP, iDRAC) |

### 1.1 Los cuatro modos de fallo que definen el diseño operativo

Todo incidente de VPN en producción se reduce a una de cuatro causas. Diseñá explícitamente contra ellas; cada sección de más abajo vuelve sobre el tema.

1. **El agujero negro de MTU.** El túnel agrega 52–80 bytes de cabecera. Si el path MTU discovery está roto en algún lado — un firewall descartando ICMP `fragmentation needed` (tipo 3 código 4) o ICMPv6 `Packet Too Big`, un default habitual — entonces los paquetes chicos pasan y los grandes desaparecen. Síntoma: `ping` funciona, `ssh` conecta y después se cuelga en el banner, un HTTP GET de un objeto chico funciona y uno grande se traba exactamente en el mismo offset de bytes siempre. Este es el ticket de "la VPN está inestable" más común de todos, y nunca es inestable — es determinista.

2. **La asimetría de routing.** Instalaste una ruta en el gateway pero no en los hosts, o en los hosts pero no en el camino de retorno. El tráfico sale por el túnel y vuelve por el gateway por defecto, donde o bien el NAT con estado lo descarta o bien `rp_filter` en modo estricto (`net.ipv4.conf.*.rp_filter=1`) lo descarta silenciosamente como marciano.

3. **El ciclo de vida de la identidad.** Los certificados expiran, las CRL se ponen rancias, se pierde una laptop y su clave sigue siendo válida. Una VPN sin camino de revocación es una credencial permanente entregada a un endpoint que no controlás. Por eso las secciones de PKI de más abajo no son relleno opcional.

4. **El punto único de fallo que construiste a propósito.** Un gateway VPN concentra cada sucursal, cada operador y cada llamada entre regiones en un proceso, una cola de NIC, el throughput criptográfico de una CPU y una IP pública. La capacidad, la HA y la observabilidad tienen que diseñarse antes del primer túnel, porque retroadaptar HA a un despliegue IPsec basado en políticas significa renegociar cada SA en cada peer.

### 1.2 La decisión de topología, antes de la decisión de protocolo

```
 (a) HUB-AND-SPOKE                (b) FULL MESH                 (c) HIERARCHICAL HUB
     branch ─┐                      A ────── B                    region-eu ── region-us
     branch ─┼─ hub ── DC           │ ╲    ╱ │                       │             │
     branch ─┘                      │  ╲  ╱  │                    branches      branches
                                    │   ╳    │
  n tunnels, 1 blast radius,        C ────── D              n tunnels/region, 2 hops
  hairpin latency, easy policy   n(n-1)/2 tunnels,          bounded state, RPO on the
  and easy audit                 optimal latency,           regional hub only
                                 O(n²) key distribution
```

* **Hub-and-spoke** es correcto hasta que el tráfico entre spokes se vuelve sensible a la latencia. Su verdadera virtud es que la política vive en un solo lugar, que es lo que necesitan los auditores y los que responden incidentes.
* **Full mesh** sólo es tratable cuando la distribución de claves está automatizada. Este es exactamente el nicho que ocupan los overlays basados en WireGuard (Tailscale, Netbird, Netmaker, el modo WireGuard de Cilium): WireGuard aporta el plano de datos, un orquestador aporta el plano de control que WireGuard omite deliberadamente.
* **Jerárquica** es lo que realmente se despliega a escala: mesh entre hubs regionales, estrella dentro de una región.

---

## 2. Fundamentos de protocolo

### 2.1 Los tres planos, y por qué importa la separación

| Plano | Trabajo | OpenVPN | IPsec/IKEv2 | WireGuard |
|---|---|---|---|---|
| **Control** | Autenticar peers, acordar claves, rekey | Sesión TLS 1.3 sobre el "canal de control", multiplexado en el mismo socket UDP | IKEv2 (RFC 7296) en UDP/500 o UDP/4500, un protocolo separado del plano de datos | Handshake Noise_IKpsk2, in-band, 1-RTT, sin protocolo separado |
| **Datos** | Cifrar/autenticar/encapsular paquetes | Frame propio de OpenVPN sobre UDP/TCP; espacio de usuario por defecto, kernel con DCO | ESP (RFC 4303), siempre en el kernel vía XFRM | ChaCha20-Poly1305 sobre UDP, siempre en el kernel |
| **Política/routing** | Decidir qué paquetes entran al túnel | Tabla de routing del kernel + `iroute`/`ccd` | SPD de XFRM (basado en políticas) *o* tabla de routing (basado en rutas vía interfaces XFRM/VTI) | `AllowedIPs` — "cryptokey routing", que es simultáneamente ACL y routing |

El **plano de política** es donde más divergen las arquitecturas, y es el eje que sondean las preguntas del examen. OpenVPN y WireGuard ponen el túnel detrás de una interfaz de red normal, así que decide `ip route`. El IPsec clásico pone la decisión en la Security Policy Database, *antes* del routing — por eso `ip route get` te miente en una máquina IPsec basada en políticas y por eso el IPsec basado en rutas (interfaces XFRM) es hoy el diseño preferido.

### 2.2 IPsec e IKEv2 en detalle

**IPsec son dos bases de datos y dos protocolos.**

* **SAD** (Security Association Database) — las claves negociadas, SPIs, algoritmos, contadores de secuencia. Inspeccionala con `ip xfrm state`.
* **SPD** (Security Policy Database) — "el tráfico que coincide con X debe protegerse con una SA con propiedades Y". Inspeccionala con `ip xfrm policy`.
* **ESP** (protocolo IP 50) — cifrado + integridad + anti-replay. Esto es lo que desplegás.
* **AH** (protocolo IP 51) — sólo integridad, cubre los campos inmutables de la IP externa, por lo tanto **incompatible con NAT**. Legacy; sabé que existe y por qué no se usa.

**Modo tunnel vs transport** es directamente examinable:

| | Modo transport | Modo tunnel |
|---|---|---|
| Qué se cifra | Sólo el payload; se preserva la cabecera IP original | El paquete IP original completo |
| Paquete resultante | `IP | ESP | TCP/UDP | ESP-trailer | ICV` | `newIP | ESP | IP | TCP/UDP | ESP-trailer | ICV` |
| Overhead | ~36 B (GCM) | ~56 B (GCM, +20 por la nueva cabecera IPv4) |
| Endpoints | Los dos hosts son los dos peers | Los gateways pueden proteger subredes detrás de ellos |
| Caso de uso | Host-a-host; **L2TP/IPsec**; proteger un túnel ya encapsulado (GRE, VXLAN, L2TPv3) | Site-to-site, acceso remoto — el default |

**El intercambio IKEv2** (memorizá esta secuencia; las fallas se diagnostican según qué intercambio murió):

```
Initiator                                   Responder
  ── IKE_SA_INIT ──────────────────────────────▶
     HDR, SAi1 (proposals), KEi, Ni,
     [N(NAT_DETECTION_SOURCE_IP),
      N(NAT_DETECTION_DESTINATION_IP)]
  ◀───────────────────────────── IKE_SA_INIT ──
     HDR, SAr1 (chosen proposal), KEr, Nr,
     [CERTREQ]
     ── from here everything is encrypted with SK_e/SK_a ──
  ── IKE_AUTH ─────────────────────────────────▶
     HDR, SK{ IDi, CERT, AUTH, SAi2, TSi, TSr }
  ◀────────────────────────────────  IKE_AUTH ──
     HDR, SK{ IDr, CERT, AUTH, SAr2, TSi, TSr,
              [CP(CFG_REPLY): internal IP, DNS] }
  ── CREATE_CHILD_SA ──────────────────────────▶   (rekey or additional child SA)
```

Consecuencias clave:

* **La detección de NAT** ocurre en `IKE_SA_INIT`, hasheando la IP+puerto de origen/destino y comparando. Si se detecta un NAT, ambos peers pasan a **UDP/4500 con encapsulación UDP-ESP (RFC 3948)**, lo que cuesta otros 8 bytes de overhead. Forzar esto con `encap = yes` es un workaround legítimo para middleboxes que manipulan ESP crudo.
* **Los traffic selectors** (`TSi`/`TSr`) se negocian en `IKE_AUTH`. Una discrepancia da `TS_UNACCEPTABLE` — esta es la falla clásica de "las subredes no coinciden en ambos lados", y no la arregla ninguna cantidad de reinicios.
* **MOBIKE** (RFC 4555) permite que una IKE SA establecida sobreviva un cambio de IP externa — el mecanismo que mantiene vivo el túnel IPsec de una laptop cruzando de Wi-Fi a LTE. Habilitado por defecto en strongSwan.
* **DPD / liveness checks** son intercambios informacionales de IKEv2 con payload vacío. `dpd_delay` es cada cuánto sondear un peer inactivo; `dpd_action = restart` es lo que convierte un peer muerto en un túnel restablecido en vez de un agujero negro.
* **PFS** viene de hacer un Diffie-Hellman fresco en `CREATE_CHILD_SA`. En strongSwan lo obtenés nombrando un grupo DH en `esp_proposals` (por ejemplo `aes256gcm16-ecp384`); si omitís el grupo, la child SA hace rekey a partir del material de claves existente sin forward secrecy.

### 2.3 OpenVPN en detalle

OpenVPN multiplexa dos canales lógicos sobre un socket:

* **Canal de control** — una sesión TLS completa (TLS 1.3 con OpenVPN 2.5+/OpenSSL 3). Autenticación de peers, negociación de cifrado, derivación de material de claves y el push de la configuración del cliente (`push "route ..."`, `push "dhcp-option DNS ..."`).
* **Canal de datos** — frames cifrados con AEAD (`P_DATA_V2`), con clave derivada de la sesión TLS, con rekey cada hora por defecto (`reneg-sec 3600`).

**La capa de endurecimiento previa a la autenticación** es la parte operativamente importante, porque el canal de control es un servidor TLS expuesto a internet:

| Mecanismo | Protege | Modelo de claves | Veredicto |
|---|---|---|---|
| ninguno | — | — | El canal de control le responde a cada escáner; exposición a DoS y 0-day |
| `tls-auth ta.key` | HMAC sobre los paquetes de control | una clave compartida, todos los clientes | Legacy; sigue estando bien, sin confidencialidad del handshake |
| `tls-crypt ta.key` | HMAC **+ cifrado** de los paquetes de control | una clave compartida, todos los clientes | Buen default; oculta el handshake TLS del DPI |
| `tls-crypt-v2` | Lo mismo, con una clave **por cliente** envuelta por una clave del servidor | por cliente, revocable | El mejor; una clave de cliente filtrada no desbloquea otros clientes |

**`tun` vs `tap`** — la decisión de routing-vs-bridging, nombrada explícitamente en el objetivo:

| | `dev tun` (ruteado, L3) | `dev tap` (bridgeado, L2) |
|---|---|---|
| Frames en el cable | Paquetes IP | Frames Ethernet incl. ARP, STP, DHCP, RA de IPv6 |
| Costo por cliente | 1 ruta | Replicación completa de broadcast/multicast a cada cliente |
| Dominio de broadcast | Separado por lado | Un dominio abarcando la WAN — una tormenta de broadcast ahora es global |
| Overhead | Menor | +14 B de cabecera Ethernet, más el flooding |
| DCO (offload al kernel) | Soportado | No soportado en Linux |
| Cuándo corresponde | ~99% de los despliegues | Arranque PXE, WoL, protocolos no-IP, clusters de appliances que hacen heartbeat sobre L2 |

**DCO (Data Channel Offload)** mueve el canal de datos al kernel, eliminando el viaje de ida y vuelta al espacio de usuario por paquete (típicamente una mejora de throughput de 3–5× en la misma CPU). Existen dos implementaciones: el módulo out-of-tree `ovpn-dco` distribuido junto con OpenVPN 2.6, y el driver `ovpn` incorporado upstream en Linux 6.16. DCO restringe la configuración: sólo cifrados de datos AEAD, sólo `dev tun`, sin `--compress`, sin `--fragment`, sin `--shaper`. Verificá con `modinfo ovpn` / `modinfo ovpn-dco`; deshabilitalo por instancia con `--disable-dco`.

### 2.4 WireGuard en detalle

La tesis de diseño de WireGuard es *reducir la superficie de ataque eliminando opciones*. No hay negociación de cifrado, por lo tanto no hay ataque de downgrade y no hay `NO_PROPOSAL_CHOSEN`. Las primitivas son fijas:

| Función | Primitiva |
|---|---|
| Acuerdo de claves | Curve25519 (ECDH) |
| AEAD | ChaCha20-Poly1305 |
| Hashing / KDF | BLAKE2s, HKDF |
| Patrón de handshake | Noise_IKpsk2 (1-RTT, autenticación mutua, ocultamiento de identidad para el responder) |
| Protección contra replay | Ventana deslizante sobre un contador de 64 bits |
| Anti-DoS | Cookie reply (HMAC sobre la dirección de origen) bajo carga |

**Cryptokey routing** es el concepto central: la clave pública de un peer *es* su identidad, y `AllowedIPs` liga direcciones de origen a esa clave en ambas direcciones.

* **Salida:** la dirección de destino del paquete selecciona el peer cuyos `AllowedIPs` la contienen (coincidencia de prefijo más largo). Si ningún peer coincide ⇒ el paquete se descarta con `ENETUNREACH`.
* **Entrada:** después de descifrar, si la dirección *de origen* del paquete interno no está en los `AllowedIPs` de ese peer, el paquete se descarta. Esto es validación infalsificable de la dirección de origen, aplicada antes de que el paquete llegue al stack.

Dos peers nunca pueden ser dueños de `AllowedIPs` solapados en la misma interfaz — el segundo gana y roba el prefijo silenciosamente. Esta es la configuración errónea número uno de WireGuard.

**El roaming es una consecuencia, no una funcionalidad:** el `Endpoint` se actualiza a la dirección de origen de cualquier paquete correctamente autenticado. Un cliente que cambia de red no necesita reconexión, ni MOBIKE, ni máquina de estados.

**Timers** (constantes fijas del protocolo, no ajustables) — con esto razonás al diagnosticar:

| Constante | Valor | Significado |
|---|---|---|
| `REKEY_AFTER_TIME` | 120 s | El initiator arranca un nuevo handshake después de este tiempo en una sesión |
| `REJECT_AFTER_TIME` | 180 s | La clave de sesión se rechaza; no pasa tráfico hasta un nuevo handshake |
| `REKEY_ATTEMPT_TIME` | 90 s | Deja de reintentar un handshake para este intento disparado por datos |
| `KEEPALIVE_TIMEOUT` | 10 s | Envía un keepalive si se recibieron datos pero no se devolvió nada |
| `PersistentKeepalive` | definido por el usuario, típicamente 25 s | Mantiene viva una asociación de NAT/firewall con estado desde detrás de NAT |

Por lo tanto: **un `latest handshake` de más de 180 segundos en una interfaz que debería estar transportando tráfico significa que el túnel está caído**, y ese único número es tu mejor métrica de salud.

**Lo que WireGuard deliberadamente no tiene**, y que tenés que aportar vos:

* Sin PKI, sin CRL, sin expiración — la rotación y revocación de claves son tu problema de orquestación.
* Sin asignación de direcciones IP — sin DHCP, sin payload CFG. Las direcciones son estáticas, salidas de tu IPAM.
* Sin routing dinámico sobre el túnel — aunque podés correr BGP/OSPF *dentro* de él y poner `AllowedIPs` amplios.
* Sin usuario/contraseña, sin RADIUS, sin MFA — combinalo con un overlay consciente de identidad si lo necesitás.
* Sin descubrimiento de PMTU en el camino externo — o configurás bien la MTU o depurás un agujero negro.

### 2.5 Aritmética de MTU — hacé esto una vez, en papel

Asumí un camino de 1500 bytes. Overheads para transporte externo IPv4:

```
OpenVPN, UDP, AES-256-GCM, P_DATA_V2:
   outer IPv4 header ........ 20
   UDP header ...............  8
   opcode + peer-id .........  4
   packet-id (GCM nonce) ....  4
   Poly/GCM auth tag ........ 16
                              ──
                              52   →  payload MTU 1448

WireGuard, IPv4 outer:
   outer IPv4 header ........ 20
   UDP header ...............  8
   WG type+reserved .........  4
   receiver index ...........  4
   counter ..................  8
   Poly1305 tag ............. 16
                              ──
                              60   →  payload MTU 1440
   (wg-quick defaults to 1420 = route MTU − 80, sized for an IPv6 outer header)

IPsec ESP tunnel mode, AES-256-GCM, no NAT-T:
   outer IPv4 header ........ 20
   ESP header (SPI+seq) .....  8
   GCM IV ...................  8
   ESP trailer (pad+len+nh) . 2..17
   ICV ...................... 16
                              ──
                            54..69  →  payload MTU ≈ 1438 (round to 1400 with NAT-T)
   +8 more bytes if UDP-encapsulated on port 4500
```

**Regla de práctica:** fijá la MTU del túnel con esta aritmética, y después *además* recortá el MSS de TCP en el gateway, porque el clamping arregla TCP incluso cuando PMTUD está roto, y PMTUD está roto más veces de las que no.

```bash
# nftables: clamp MSS on every SYN crossing a tunnel interface
$ sudo nft add rule inet filter forward tcp flags syn tcp option maxseg size set rt mtu
```

---

## 3. Compromisos comparativos

### 3.1 Comparación de protocolos

| Dimensión | OpenVPN 2.6 | IPsec/IKEv2 (strongSwan) | WireGuard | L2TP/IPsec |
|---|---|---|---|---|
| Estándar | Protocolo comunitario, sin RFC | RFC 7296 / 4303 / 3948 | Whitepaper + upstream de Linux | RFC 2661 + RFC 3193 |
| Plano de datos | Espacio de usuario (kernel con DCO) | Kernel XFRM, siempre | Kernel, siempre | ESP en kernel + demonio PPP |
| Líneas de código central | ~100 k | ~400 k (charon + kernel) | ~4 k (módulo de kernel) | PPP + xl2tpd + IPsec |
| Transporte | UDP **o TCP** | UDP/500, UDP/4500, ESP proto 50 | Sólo UDP | UDP/1701 dentro de ESP |
| Atraviesa un proxy sólo-TCP | **Sí** (`proto tcp`, puerto 443) | No | No | No |
| Traversal de NAT | Nativo (UDP/TCP) | NAT-T en 4500, autodetectado | Nativo, más keepalive | Requiere NAT-T + a menudo roto por CG-NAT |
| Roaming / cambio de IP | Reconexión (rápida, pero una reconexión) | MOBIKE, transparente | Transparente, inherente | Reconexión |
| Agilidad de cifrado | Negociada, configurable | Totalmente negociada, capaz de FIPS | **Ninguna** — suite fija |Negociada (ESP) |
| Cobertura post-cuántica | No (2.6) | IKEv2 con intercambios de claves adicionales (plugins ML-KEM) | PSK de 256 bits por peer | No |
| Modelos de autenticación | X.509, PSK, usuario/contraseña, PAM, LDAP, TOTP, plugins | X.509, PSK, EAP-TLS/MSCHAPv2/RADIUS, smartcards | Sólo claves públicas crudas |PPP: PAP/CHAP/MSCHAPv2 + RADIUS |
| Revocación | CRL, OCSP | CRL, OCSP | Sólo orquestación externa |vía la capa IPsec |
| Asignación de direcciones por usuario | `push`, `ifconfig-pool`, `ccd` | Payload CFG + `pools` | Estática, fuera de banda | IPCP sobre PPP |
| Bridging L2 | `dev tap` | GRETAP/L2TPv3 dentro de modo transport | No | **Sí**, nativamente (PPP/L2TPv3) |
| Interoperabilidad con firewalls comerciales | Pobre | **Universal** (este es el factor decisivo para site-to-site con terceros) | Cada vez mejor, no universal | Buena en equipos legacy |
| Cliente nativo del SO | No (requiere app) | **Sí** (Windows, macOS, iOS, Android, systemd) | Requiere app, pero ubicua | **Sí**, en todos lados por legado |
| Complejidad de configuración | Media | **Alta** | **Baja** |Alta |
| Throughput relativo, misma CPU¹ | 1.0× (espacio de usuario) / ~3–5× (DCO) | ~3–6× | ~4–7× |~3× |
| Observabilidad operativa | archivo de status, socket de management | `swanctl --list-sas`, contadores XFRM, vici | sólo `wg show` |repartida entre dos demonios |

¹ Sólo orden de magnitud. El throughput está dominado por la presencia de AES-NI, el tamaño de paquete, el offload GRO/GSO y la afinidad de IRQ. **Medí el tuyo** — ver §9.6.

### 3.2 Matriz de decisión

| Situación | Elegí | Por qué |
|---|---|---|
| Site-to-site con el Cisco/Fortinet/Palo Alto de un tercero | **IPsec/IKEv2** | El único protocolo que todos van a hablar; los selectores basados en políticas son la lingua franca |
| Site-to-site entre máquinas que controlás | **WireGuard** | Menos estado, menos CPU, hace roaming, configuración trivialmente auditable |
| Acceso remoto, laptops corporativas, gestionadas por MDM | **IPsec/IKEv2** | Cliente nativo en todos los SO, EAP → RADIUS → IdP existente, MOBIKE |
| Acceso remoto en redes hostiles (portales cautivos, proxies de salida) | **OpenVPN sobre TCP/443** | El único stack que sobrevive a un camino sólo-TCP |
| Acceso remoto, ingenieros, autoservicio | **WireGuard** + un overlay de identidad | Lo más rápido de operar; aportá el plano de control faltante |
| Cifrado nodo-a-nodo en Kubernetes | **WireGuard** (modo nativo de Cilium/Calico) o IPsec | Plano de datos en el kernel, sin sidecar por pod |
| Debe estar validado FIPS 140-3 | **IPsec/IKEv2** | API de cripto del kernel en modo FIPS; la suite de WireGuard no está aprobada por FIPS |
| Windows/appliance legacy sin cliente instalable | **L2TP/IPsec** | Marcador nativo; aceptá el costo operativo |
| Extensión L2 (PXE, WoL, heartbeat de cluster) | **OpenVPN TAP** o **L2TPv3-sobre-IPsec** | Los únicos dos dentro del alcance que transportan Ethernet |

---

## 4. OpenVPN en producción

Topología de referencia usada a lo largo de §4–§6:

```
  DC / core site                                      branch site
  10.20.0.0/16                                        10.30.0.0/16
        │                                                   │
   ┌────┴─────┐  198.51.100.10            203.0.113.24  ┌────┴─────┐
   │ gw-core  │◀════════ public internet ═══════════════▶│ gw-branch│
   └──────────┘                                          └──────────┘
        ▲
        │ remote-access pool 10.20.200.0/24
   road warriors (laptops, behind CG-NAT)
```

### 4.1 PKI con Easy-RSA 3

Construí la CA en una máquina que **no** sea el gateway VPN. La clave privada de la CA nunca la abandona.

```bash
$ sudo apt-get install -y openvpn easy-rsa
$ make-cadir ~/pki-vpn && cd ~/pki-vpn

$ cat > vars <<'EOF'
set_var EASYRSA_ALGO            ec
set_var EASYRSA_CURVE           secp384r1
set_var EASYRSA_DIGEST          "sha384"
set_var EASYRSA_CA_EXPIRE       3650
set_var EASYRSA_CERT_EXPIRE     398
set_var EASYRSA_CRL_DAYS        30
set_var EASYRSA_REQ_CN          "Example VPN CA"
set_var EASYRSA_REQ_ORG         "Example Inc"
set_var EASYRSA_REQ_COUNTRY     "AR"
EOF

$ ./easyrsa init-pki
Notice
------
'init-pki' complete; you may now create a CA or requests.
Your newly created PKI dir is:
* /home/ops/pki-vpn/pki

$ ./easyrsa build-ca nopass
Notice
------
CA creation complete. Your new CA certificate is at:
* /home/ops/pki-vpn/pki/ca.crt

$ ./easyrsa build-server-full vpn.example.net nopass
$ ./easyrsa build-client-full alice@example.net nopass
$ ./easyrsa gen-crl
Notice
------
An updated CRL has been created.
CRL file: /home/ops/pki-vpn/pki/crl.pem
```

Las claves de curva elíptica implican que **no hace falta ningún `dh.pem`** — declará `dh none` y dejá que TLS 1.3 haga ECDHE. Verificá lo que construiste antes de mandarlo a producción:

```bash
$ openssl x509 -in pki/issued/vpn.example.net.crt -noout -subject -dates -ext extendedKeyUsage
subject=CN=vpn.example.net
notBefore=Aug 25 12:04:11 2026 GMT
notAfter=Sep 27 12:04:11 2027 GMT
X509v3 Extended Key Usage:
    TLS Web Server Authentication
```

Ese EKU `TLS Web Server Authentication` es lo que hace significativa la verificación `remote-cert-tls server` del cliente: sin él, un certificado *de cliente* robado podría usarse para suplantar al *servidor*.

Generá las claves previas a la autenticación:

```bash
$ sudo openvpn --genkey tls-crypt-v2-server /etc/openvpn/server/tc2-server.key
$ sudo openvpn --tls-crypt-v2 /etc/openvpn/server/tc2-server.key \
      --genkey tls-crypt-v2-client /tmp/tc2-alice.key
```

### 4.2 Configuración del servidor — `/etc/openvpn/server/core.conf`

```conf
# ── /etc/openvpn/server/core.conf ─────────────────────────────────────────
# Started by: systemctl enable --now openvpn-server@core.service

# ── Transport ────────────────────────────────────────────────────────────
port                1194
proto               udp4
dev                 tun0
dev-type            tun
topology            subnet          # default since 2.6; declare it anyway
local               198.51.100.10

# ── Identity / PKI ───────────────────────────────────────────────────────
ca                  /etc/openvpn/server/pki/ca.crt
cert                /etc/openvpn/server/pki/vpn.example.net.crt
key                 /etc/openvpn/server/pki/vpn.example.net.key
dh                  none
crl-verify          /etc/openvpn/server/pki/crl.pem
tls-crypt-v2        /etc/openvpn/server/tc2-server.key
remote-cert-tls     client
verify-client-cert  require

# ── Cryptography (2.6 syntax; --cipher is deprecated) ─────────────────────
data-ciphers        AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
auth                SHA384
tls-version-min     1.3
tls-groups          secp384r1:secp256r1:X25519
reneg-sec           3600

# ── Addressing and pushed policy ─────────────────────────────────────────
server              10.20.200.0 255.255.255.0
ifconfig-pool-persist /var/lib/openvpn/ipp-core.txt 3600
client-config-dir   /etc/openvpn/server/ccd
ccd-exclusive                       # no ccd file ⇒ connection refused

push "route 10.20.0.0 255.255.0.0"
push "route 10.30.0.0 255.255.0.0"
push "dhcp-option DNS 10.20.0.53"
push "dhcp-option DOMAIN corp.example.net"
push "block-outside-dns"            # Windows clients: prevents DNS leak
# Full-tunnel instead of split-tunnel would be:
#   push "redirect-gateway def1 bypass-dhcp"

# ── Site-to-site: the branch LAN lives behind one client ──────────────────
route               10.30.0.0 255.255.0.0     # kernel route: tun0 owns it
# and /etc/openvpn/server/ccd/gw-branch.example.net contains the iroute

# ── Client isolation ─────────────────────────────────────────────────────
# client-to-client                   # DISABLED: forces traffic through the
                                     # firewall so policy is enforceable

# ── MTU / fragmentation ──────────────────────────────────────────────────
tun-mtu             1400
mssfix              1340 mtu

# ── Liveness ─────────────────────────────────────────────────────────────
keepalive           10 60           # ping every 10 s, restart after 60 s
persist-key
persist-tun
explicit-exit-notify 1

# ── Privilege drop and hardening ─────────────────────────────────────────
user                openvpn
group               openvpn
# chroot            /var/lib/openvpn/chroot    # enable once scripts are gone

# ── Observability ────────────────────────────────────────────────────────
status              /run/openvpn-server/status-core.log 10
status-version      3
management          /run/openvpn-server/mgmt-core.sock unix
log-append          /var/log/openvpn/core.log
verb                3
mute                20
```

`/etc/openvpn/server/ccd/gw-branch.example.net` — el nombre del archivo **debe ser igual al CN del certificado**:

```conf
# Tell OpenVPN's internal routing table that 10.30.0.0/16 is reachable
# through THIS client. `iroute` is internal; the `route` in the server
# config is what puts the prefix in the kernel. You need BOTH.
iroute 10.30.0.0 255.255.0.0
ifconfig-push 10.20.200.10 255.255.255.0
```

`/etc/openvpn/server/ccd/alice@example.net`:

```conf
ifconfig-push 10.20.200.50 255.255.255.0
push "route 10.20.10.0 255.255.255.0"   # this user only reaches one subnet
```

**La distinción entre `route` e `iroute` es un ítem garantizado del examen.** `route` = "kernel, mandá este prefijo a tun0". `iroute` = "OpenVPN, dentro de tun0, este prefijo pertenece a ese cliente específico". Omitís `iroute` y los paquetes llegan a tun0 y OpenVPN los descarta con `MULTI: bad source address from client`.

### 4.3 Plomería del sistema

```bash
$ cat | sudo tee /etc/sysctl.d/90-vpn.conf <<'EOF'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.ipv4.conf.all.rp_filter = 2          # loose: tolerate asymmetric VPN paths
net.ipv4.conf.default.rp_filter = 2
EOF
$ sudo sysctl --system | grep -E 'ip_forward|rp_filter'
net.ipv4.ip_forward = 1
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
```

nftables (canónico; el equivalente en iptables está en el comentario):

```nft
#!/usr/sbin/nft -f
# /etc/nftables.d/vpn.nft
table inet vpn {
    set vpn_ifaces { type ifname; elements = { "tun0", "wg0", "ipsec0" } }

    chain input {
        type filter hook input priority filter; policy drop;
        ct state established,related accept
        iif lo accept
        udp dport 1194 accept                     # OpenVPN
        udp dport { 500, 4500 } accept            # IKEv2 + NAT-T
        meta l4proto esp accept                   # raw ESP (proto 50)
        udp dport 51820 accept                    # WireGuard
        iifname @vpn_ifaces tcp dport 22 accept
        icmp type { echo-request, destination-unreachable, time-exceeded } accept
        icmpv6 type { echo-request, packet-too-big, time-exceeded,
                      nd-neighbor-solicit, nd-neighbor-advert } accept
        counter comment "input-drop"
    }

    chain forward {
        type filter hook forward priority filter; policy drop;
        ct state established,related accept
        # MSS clamping — fixes TCP even when PMTUD is broken upstream
        iifname @vpn_ifaces tcp flags syn tcp option maxseg size set rt mtu
        oifname @vpn_ifaces tcp flags syn tcp option maxseg size set rt mtu
        iifname @vpn_ifaces oifname "eth0" ip daddr 10.20.0.0/16 accept
        iifname "eth0" oifname @vpn_ifaces ip saddr 10.20.0.0/16 accept
        iifname @vpn_ifaces oifname @vpn_ifaces accept
        counter comment "forward-drop"
    }

    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        # Only NAT road warriors going to the internet; NEVER NAT site-to-site
        ip saddr 10.20.200.0/24 oifname "eth0" masquerade
    }
}
# iptables equivalent of the NAT rule, for older systems:
#   iptables -t nat -A POSTROUTING -s 10.20.200.0/24 -o eth0 -j MASQUERADE
```

```bash
$ sudo nft -f /etc/nftables.d/vpn.nft
$ sudo nft list ruleset | head -20
$ sudo systemctl enable --now openvpn-server@core.service
$ systemctl status openvpn-server@core.service --no-pager
● openvpn-server@core.service - OpenVPN service for core
     Loaded: loaded (/lib/systemd/system/openvpn-server@.service; enabled)
     Active: active (running) since Tue 2026-08-25 13:02:44 -03; 6s ago
       Docs: man:openvpn(8)
   Main PID: 20418 (openvpn)
     Status: "Initialization Sequence Completed"
      Tasks: 1 (limit: 18985)
     Memory: 2.1M
        CPU: 41ms
     CGroup: /system.slice/system-openvpn\x2dserver.slice/openvpn-server@core.service
             └─20418 /usr/sbin/openvpn --status /run/openvpn-server/status-core.log 10 ...
```

### 4.4 Perfil de cliente — un único `.ovpn` con todo embebido

```conf
# ── alice.ovpn — one file, no side-car certificates ───────────────────────
client
dev tun
proto udp4
remote vpn.example.net 1194
remote vpn-dr.example.net 1194        # failover target
remote-random-hostname
resolv-retry infinite
nobind

persist-key
persist-tun
remote-cert-tls server
verify-x509-name vpn.example.net name
data-ciphers AES-256-GCM:CHACHA20-POLY1305
auth SHA384
tls-version-min 1.3
auth-nocache
pull-filter ignore "redirect-gateway"   # client refuses full-tunnel push
mssfix 1340 mtu
verb 3

<ca>
-----BEGIN CERTIFICATE-----
MIICBjCCAYygAwIBAgIUV1V7... (CA certificate)
-----END CERTIFICATE-----
</ca>
<cert>
-----BEGIN CERTIFICATE-----
MIICLTCCAbOgAwIBAgIRAOc... (client certificate)
-----END CERTIFICATE-----
</cert>
<key>
-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEG... (client private key)
-----END PRIVATE KEY-----
</key>
<tls-crypt-v2>
-----BEGIN OpenVPN tls-crypt-v2 client key-----
0DBFvFcJ6PGyzUZFtOQMBQTU... (per-client wrapped key)
-----END OpenVPN tls-crypt-v2 client key-----
</tls-crypt-v2>
```

Traza de conexión, del lado del cliente:

```
$ sudo openvpn --config alice.ovpn
2026-08-25 13:11:02 OpenVPN 2.6.12 x86_64-pc-linux-gnu [SSL (OpenSSL)] [LZO] [LZ4] [EPOLL] [DCO]
2026-08-25 13:11:02 library versions: OpenSSL 3.0.13 30 Jan 2024, LZO 2.10
2026-08-25 13:11:02 DCO version: N/A
2026-08-25 13:11:02 TCP/UDP: Preserving recently used remote address: [AF_INET]198.51.100.10:1194
2026-08-25 13:11:02 UDPv4 link local: (not bound)
2026-08-25 13:11:02 UDPv4 link remote: [AF_INET]198.51.100.10:1194
2026-08-25 13:11:02 TLS: Initial packet from [AF_INET]198.51.100.10:1194, sid=8a1f0c2e 5b93d417
2026-08-25 13:11:02 VERIFY OK: depth=1, CN=Example VPN CA
2026-08-25 13:11:02 VERIFY KU OK
2026-08-25 13:11:02 Validating certificate extended key usage
2026-08-25 13:11:02 ++ Certificate has EKU (str) TLS Web Server Authentication, expects TLS Web Server Authentication
2026-08-25 13:11:02 VERIFY EKU OK
2026-08-25 13:11:02 VERIFY X509NAME OK: CN=vpn.example.net
2026-08-25 13:11:02 VERIFY OK: depth=0, CN=vpn.example.net
2026-08-25 13:11:02 Control Channel: TLSv1.3, cipher TLSv1.3 TLS_AES_256_GCM_SHA384, peer certificate: 384 bits EC, curve secp384r1
2026-08-25 13:11:02 [vpn.example.net] Peer Connection Initiated with [AF_INET]198.51.100.10:1194
2026-08-25 13:11:03 PUSH: Received control message: 'PUSH_REPLY,route 10.20.0.0 255.255.0.0,route 10.30.0.0 255.255.0.0,dhcp-option DNS 10.20.0.53,dhcp-option DOMAIN corp.example.net,route-gateway 10.20.200.1,topology subnet,ping 10,ping-restart 60,ifconfig 10.20.200.50 255.255.255.0,peer-id 3,cipher AES-256-GCM'
2026-08-25 13:11:03 OPTIONS IMPORT: --ifconfig/up options modified
2026-08-25 13:11:03 Data Channel: cipher 'AES-256-GCM', peer-id 3
2026-08-25 13:11:03 net_addr_v4_add: 10.20.200.50/24 dev tun0
2026-08-25 13:11:03 net_route_v4_add: 10.20.0.0/16 via 10.20.200.1 dev [NULL] table 0 metric -1
2026-08-25 13:11:03 net_route_v4_add: 10.30.0.0/16 via 10.20.200.1 dev [NULL] table 0 metric -1
2026-08-25 13:11:03 Initialization Sequence Completed
```

`Initialization Sequence Completed` es la única cadena de éxito que importa. Todo lo anterior es una etapa que podés bisecar.

### 4.5 Modo bridging (`dev tap`) — cómo se configura, y por qué no deberías

El objetivo nombra bridging, así que conocé la mecánica.

```conf
# ── /etc/openvpn/server/bridge.conf ──────────────────────────────────────
dev tap0
dev-type tap
# The tunnel does NOT own a subnet; it joins an existing L2 segment.
# Args: gateway  netmask  pool-start  pool-end
server-bridge 10.20.10.1 255.255.255.0 10.20.10.200 10.20.10.250
push "dhcp-option DNS 10.20.0.53"
up   /etc/openvpn/server/bridge-up.sh
down /etc/openvpn/server/bridge-down.sh
script-security 2
# NOTE: tap is incompatible with DCO on Linux — this instance runs in userspace.
```

```bash
#!/bin/bash
# /etc/openvpn/server/bridge-up.sh   ($1 = tap device name)
set -euo pipefail
BR=br0; ETH=eth1; TAP="$1"
ip link add name "$BR" type bridge 2>/dev/null || true
ip link set "$BR" up
ip link set "$ETH" master "$BR"
ip link set "$TAP" up promisc on
ip link set "$TAP" master "$BR"
ip addr replace 10.20.10.1/24 dev "$BR"
```

Por qué evitarlo: cada ARP request, DHCP discover, anuncio mDNS, router advertisement de IPv6 y broadcast del explorador de Windows en la LAN ahora se replica y se cifra una vez por cada cliente conectado. Cincuenta clientes en una /24 charlatana convierten el ruido de broadcast en una carga criptográfica sostenida de varios Mbit/s que transporta cero payload útil — y una tormenta de broadcast en la oficina ahora tira abajo a todos los usuarios remotos. Usá `dev tun` y, si genuinamente necesitás L2, acotalo a una VLAN dedicada con sólo los dispositivos que lo requieran.

### 4.6 Revocación y ciclo de vida

```bash
$ cd ~/pki-vpn && ./easyrsa revoke alice@example.net
Type the word 'yes' to continue, or any other input to abort.
  Continue with revocation: yes
Notice
------
Revocation was successful. You must run gen-crl and upload a CRL to your
infrastructure in order to prevent the revoked cert from being accepted.

$ ./easyrsa gen-crl
$ scp pki/crl.pem gw-core:/tmp/crl.pem
$ ssh gw-core 'sudo install -o root -g openvpn -m 0640 /tmp/crl.pem \
      /etc/openvpn/server/pki/crl.pem'
```

OpenVPN vuelve a leer la CRL en cada intento de conexión, así que **no hace falta reiniciar** — pero la CRL tiene una expiración (`EASYRSA_CRL_DAYS`), y una CRL vencida hace que OpenVPN rechace *todas* las conexiones. Automatizá la regeneración bien dentro de esa ventana y alertá sobre eso:

```bash
$ openssl crl -in /etc/openvpn/server/pki/crl.pem -noout -lastupdate -nextupdate
lastUpdate=Aug 25 13:22:03 2026 GMT
nextUpdate=Sep 24 13:22:03 2026 GMT
```

Matá una sesión activa sin esperar a que se dé cuenta:

```bash
$ echo "kill alice@example.net" | sudo socat - UNIX-CONNECT:/run/openvpn-server/mgmt-core.sock
SUCCESS: common name 'alice@example.net' found, 1 client(s) killed
```

---

## 5. strongSwan / IPsec en producción

### 5.1 Qué interfaz de configuración — y por qué ambas son examinables

strongSwan tiene dos generaciones de configuración, y el objetivo del examen nombra archivos de ambas:

| | Legacy (`starter`/`stroke`) | Moderna (`vici`/`swanctl`) |
|---|---|---|
| Archivos de configuración | `/etc/ipsec.conf`, `/etc/ipsec.secrets` | `/etc/swanctl/swanctl.conf` (+ `conf.d/*.conf`) |
| Directorio de credenciales | `/etc/ipsec.d/{cacerts,certs,private}/` | `/etc/swanctl/{x509ca,x509,private,rsa,ecdsa}/` |
| CLI | `ipsec up|down|status|statusall|restart` | `swanctl --load-all|--list-sas|--initiate|--terminate` |
| Recarga sin tirar las SA | No (`ipsec reload` es grueso) | **Sí** (`swanctl --load-all`) |
| Interfaz para máquinas | ninguna | **VICI** (Versatile IKE Configuration Interface) — bindings de Python/Perl/Ruby |
| Estado | Deprecada, eliminada de los paquetes modernos | Actual |

**Usá `swanctl` para cualquier cosa nueva.** Conocé `ipsec.conf` porque lo vas a heredar y porque está en el examen.

### 5.2 Construyendo la PKI de IPsec con `pki`

```bash
$ sudo apt-get install -y strongswan strongswan-swanctl strongswan-pki libcharon-extra-plugins

$ pki --gen --type ecdsa --size 384 --outform pem > ca.key
$ pki --self --ca --lifetime 3650 --in ca.key --type ecdsa \
      --dn "C=AR, O=Example Inc, CN=Example IPsec CA" \
      --san "ipsec-ca.example.net" --outform pem > ca.crt

$ pki --gen --type ecdsa --size 384 --outform pem > gw-core.key
$ pki --pub --in gw-core.key --type ecdsa | \
  pki --issue --lifetime 398 --cacert ca.crt --cakey ca.key \
      --dn "C=AR, O=Example Inc, CN=gw-core.example.net" \
      --san gw-core.example.net --san 198.51.100.10 \
      --flag serverAuth --flag ikeIntermediate --outform pem > gw-core.crt

$ pki --print --in gw-core.crt
  subject:  "C=AR, O=Example Inc, CN=gw-core.example.net"
  issuer:   "C=AR, O=Example Inc, CN=Example IPsec CA"
  validity:  not before Aug 25 13:40:02 2026, ok
             not after  Sep 27 13:40:02 2027, ok (expires in 397 days)
  serial:    3a:1c:88:0f:44:2b:9e:71
  altNames:  gw-core.example.net, 198.51.100.10
  flags:     serverAuth ikeIntermediate
  authkeyId: 5f:b2:33:a1:c0:...
  subjkeyId: 91:0d:7e:44:aa:...
  pubkey:    ECDSA 384 bits
```

Instalá dentro del árbol de swanctl (los permisos importan — charon corre como root pero los directorios suelen ser legibles por el grupo):

```bash
$ sudo install -m 0644 ca.crt      /etc/swanctl/x509ca/ca.crt
$ sudo install -m 0644 gw-core.crt /etc/swanctl/x509/gw-core.crt
$ sudo install -m 0600 gw-core.key /etc/swanctl/private/gw-core.key
```

### 5.3 Site-to-site, basado en rutas con interfaces XFRM — `/etc/swanctl/conf.d/branch.conf`

El IPsec basado en rutas es el diseño moderno: la SA se liga a una interfaz `xfrm` vía `if_id`, así que el routing común (incluyendo BGP/OSPF, ECMP y firewalling por interfaz) decide qué entra al túnel. El IPsec basado en políticas, donde decide la SPD, no se puede inspeccionar con `ip route` y no puede transportar un protocolo de routing dinámico.

```conf
# ── /etc/swanctl/conf.d/branch.conf ──────────────────────────────────────
connections {

    branch {
        version       = 2
        local_addrs   = 198.51.100.10
        remote_addrs  = 203.0.113.24

        # IKE (control plane) proposal. Explicit — no defaults, no downgrade.
        proposals     = aes256gcm16-prfsha384-ecp384

        # Liveness. Without this a dead peer becomes a black hole.
        dpd_delay     = 30s
        dpd_timeout   = 120s

        # Rekey the IKE SA well before the hard lifetime, with jitter.
        rekey_time    = 4h
        over_time     = 30m
        rand_time     = 20m

        # NAT keepalives (charon global default is 20s) and MOBIKE
        mobike        = yes
        encap         = no       # set yes to force UDP/4500 through hostile NAT

        # Retransmission budget before declaring the peer unreachable
        keyingtries   = 0        # 0 = retry forever (site-to-site: correct)

        local {
            auth  = pubkey
            certs = gw-core.crt
            id    = "C=AR, O=Example Inc, CN=gw-core.example.net"
        }
        remote {
            auth  = pubkey
            id    = "C=AR, O=Example Inc, CN=gw-branch.example.net"
        }

        children {
            net {
                # Route-based: wide selectors, routing decides.
                local_ts      = 0.0.0.0/0
                remote_ts     = 0.0.0.0/0

                # Bind this CHILD_SA to XFRM interface id 42
                if_id_in      = 42
                if_id_out     = 42

                esp_proposals = aes256gcm16-ecp384   # ecp384 ⇒ PFS on rekey
                mode          = tunnel

                rekey_time    = 1h
                life_time     = 1h10m
                rand_time     = 5m
                rekey_bytes   = 500000000            # rekey on volume too
                rekey_packets = 1000000

                dpd_action    = restart
                close_action  = start
                start_action  = start                # initiate at load time
                                                     # use "trap" on the responder
                replay_window = 1024                 # multi-queue NICs reorder
            }
        }
    }
}

secrets {
    private-gw-core {
        file = gw-core.key
    }
}
```

Creá y ruteá la interfaz XFRM. Notá que `if_id` debe coincidir con `if_id_in`/`if_id_out`, y `0x2a` = 42:

```bash
$ sudo ip link add ipsec0 type xfrm dev eth0 if_id 0x2a
$ sudo ip link set ipsec0 up mtu 1400
$ sudo ip addr add 169.254.42.1/30 dev ipsec0        # optional, for BFD/BGP
$ sudo ip route add 10.30.0.0/16 dev ipsec0

# Disable policy lookup ON the xfrm interface — traffic is already
# selected by routing; leaving it on causes a double-encryption lookup.
$ sudo sysctl -w net.ipv4.conf.ipsec0.disable_policy=1
$ sudo sysctl -w net.ipv4.conf.ipsec0.rp_filter=0
```

Persistila con systemd-networkd (`.netdev` + `.network`, entregados como INI por diseño):

```ini
# /etc/systemd/network/25-ipsec0.netdev
[NetDev]
Name=ipsec0
Kind=xfrm
MTUBytes=1400

[Xfrm]
InterfaceId=42
Independent=false
```

```ini
# /etc/systemd/network/25-ipsec0.network
[Match]
Name=ipsec0

[Network]
Address=169.254.42.1/30
IPv4ProxyARP=no

[Route]
Destination=10.30.0.0/16
Scope=link
```

Cargala y levantala:

```bash
$ sudo systemctl enable --now strongswan.service
$ sudo swanctl --load-all
loaded certificate from '/etc/swanctl/x509/gw-core.crt'
loaded certificate from '/etc/swanctl/x509ca/ca.crt'
loaded ECDSA key from '/etc/swanctl/private/gw-core.key'
loaded connection 'branch'
successfully loaded 1 connections, 0 unloaded

$ sudo swanctl --initiate --child net
[IKE] initiating IKE_SA branch[1] to 203.0.113.24
[ENC] generating IKE_SA_INIT request 0 [ SA KE No N(NATD_S_IP) N(NATD_D_IP) ]
[NET] sending packet: from 198.51.100.10[500] to 203.0.113.24[500] (464 bytes)
[NET] received packet: from 203.0.113.24[500] to 198.51.100.10[500] (441 bytes)
[ENC] parsed IKE_SA_INIT response 0 [ SA KE No N(NATD_S_IP) N(NATD_D_IP) CERTREQ ]
[CFG] selected proposal: IKE:AES_GCM_16_256/PRF_HMAC_SHA2_384/ECP_384
[IKE] authentication of 'C=AR, O=Example Inc, CN=gw-core.example.net' (myself) with ECDSA_WITH_SHA384_DER successful
[IKE] establishing CHILD_SA net{1}
[ENC] generating IKE_AUTH request 1 [ IDi CERT CERTREQ AUTH SA TSi TSr N(MOBIKE_SUP) ]
[NET] sending packet: from 198.51.100.10[500] to 203.0.113.24[500] (1516 bytes)
[NET] received packet: from 203.0.113.24[500] to 198.51.100.10[500] (1264 bytes)
[ENC] parsed IKE_AUTH response 1 [ IDr CERT AUTH SA TSi TSr N(MOBIKE_SUP) ]
[IKE] received end entity cert "C=AR, O=Example Inc, CN=gw-branch.example.net"
[CFG]   using trusted ca certificate "C=AR, O=Example Inc, CN=Example IPsec CA"
[CFG]   checking certificate status of "C=AR, O=Example Inc, CN=gw-branch.example.net"
[CFG]   certificate status is not available
[CFG]   reached self-signed root ca with a path length of 0
[IKE] authentication of 'C=AR, O=Example Inc, CN=gw-branch.example.net' with ECDSA_WITH_SHA384_DER successful
[IKE] IKE_SA branch[1] established between 198.51.100.10[C=AR, O=Example Inc, CN=gw-core.example.net]...203.0.113.24[C=AR, O=Example Inc, CN=gw-branch.example.net]
[IKE] scheduling rekeying in 13847s
[CFG] selected proposal: ESP:AES_GCM_16_256/ECP_384/NO_EXT_SEQ
[IKE] CHILD_SA net{1} established with SPIs c1f3a20b_i 9a44b1c7_o and TS 0.0.0.0/0 === 0.0.0.0/0
initiate completed successfully
```

### 5.4 Acceso remoto (road warrior) con EAP y un pool de IP virtuales

```conf
# ── /etc/swanctl/conf.d/roadwarrior.conf ─────────────────────────────────
connections {

    rw-eap {
        version      = 2
        local_addrs  = 198.51.100.10
        remote_addrs = %any
        pools        = rw-pool

        proposals    = aes256gcm16-prfsha384-ecp384,aes256-sha384-prfsha384-ecp384

        # Windows/macOS native clients expect the gateway to identify by FQDN
        # matching the certificate SAN, and to send its full chain.
        send_certreq = no
        send_cert    = always
        fragmentation = yes        # IKEv2 fragmentation (RFC 7383): essential,
                                   # cert chains exceed the path MTU

        dpd_delay    = 60s
        rekey_time   = 8h

        local {
            auth  = pubkey
            certs = vpn.example.net.crt
            id    = vpn.example.net           # must equal a SAN in the cert
        }
        remote {
            auth    = eap-radius              # or eap-mschapv2 for local users
            eap_id  = %any
        }

        children {
            rw {
                # Split tunnel: only these prefixes are pushed to the client.
                # Change to 0.0.0.0/0 for a full tunnel.
                local_ts      = 10.20.0.0/16, 10.30.0.0/16
                esp_proposals = aes256gcm16-ecp384,aes256-sha256-ecp384
                mode          = tunnel
                rekey_time    = 1h
                dpd_action    = clear
                inactivity    = 30m           # reap idle laptops
            }
        }
    }
}

pools {
    rw-pool {
        addrs = 10.20.200.0/24
        dns   = 10.20.0.53, 10.20.0.54
    }
}

secrets {
    private-vpn {
        file = vpn.example.net.key
    }
    # Local EAP users, only if not using RADIUS:
    eap-alice {
        id     = alice@example.net
        secret = "REPLACE-WITH-A-GENERATED-SECRET"
    }
}
```

El cableado de RADIUS vive en `strongswan.conf`, no en `swanctl.conf`:

```conf
# ── /etc/strongswan.d/charon/eap-radius.conf (or strongswan.conf) ────────
charon {
    plugins {
        eap-radius {
            servers {
                primary {
                    address = 10.20.0.31
                    secret  = REPLACE-WITH-THE-RADIUS-SHARED-SECRET
                    auth_port = 1812
                    acct_port = 1813
                    nas_identifier = vpn.example.net
                }
            }
            accounting = yes
            class_group = yes        # map RADIUS Class → strongSwan group
        }
    }

    # Structured logging, per subsystem, at levels 0..4
    filelog {
        charon {
            path    = /var/log/charon.log
            time_format = %b %e %T
            ike_name = yes
            default = 1
            ike  = 2
            cfg  = 2
            knl  = 1
            net  = 1
            append  = yes
            flush_line = yes
        }
    }

    # Multi-core crypto and larger worker pool for a busy gateway
    threads = 32
    processor {
        priority_threads {
            high = 4
            medium = 8
        }
    }

    # Install routes into a dedicated table so they do not fight the main one
    install_routes = yes
    routing_table = 220
    routing_table_prio = 220
}
```

### 5.5 El equivalente legacy (`ipsec.conf` / `ipsec.secrets`)

Tenés que poder leer y escribir esta forma.

```conf
# ── /etc/ipsec.conf ──────────────────────────────────────────────────────
config setup
    charondebug="ike 2, cfg 2, knl 1"
    uniqueids=yes

conn %default
    keyexchange=ikev2
    ike=aes256gcm16-prfsha384-ecp384!      # trailing ! = strict, no defaults
    esp=aes256gcm16-ecp384!
    dpdaction=restart
    dpddelay=30s
    ikelifetime=4h
    lifetime=1h
    fragmentation=yes
    mobike=yes

# Site-to-site, tunnel mode
conn branch
    left=198.51.100.10
    leftid="C=AR, O=Example Inc, CN=gw-core.example.net"
    leftcert=gw-core.crt
    leftsubnet=10.20.0.0/16
    leftfirewall=yes
    right=203.0.113.24
    rightid="C=AR, O=Example Inc, CN=gw-branch.example.net"
    rightsubnet=10.30.0.0/16
    type=tunnel
    auto=start

# Host-to-host, TRANSPORT mode — note type=transport and no *subnet
conn host-to-host
    left=198.51.100.10
    leftid=@gw-core.example.net
    leftcert=gw-core.crt
    right=198.51.100.20
    rightid=@log-collector.example.net
    type=transport
    auto=route

# Remote access responder
conn rw
    left=198.51.100.10
    leftid=vpn.example.net
    leftcert=vpn.example.net.crt
    leftsubnet=10.20.0.0/16
    leftauth=pubkey
    leftsendcert=always
    right=%any
    rightauth=eap-mschapv2
    rightsourceip=10.20.200.0/24
    rightdns=10.20.0.53
    eap_identity=%identity
    auto=add
```

```conf
# ── /etc/ipsec.secrets ───────────────────────────────────────────────────
# Private key for our certificate (file lives in /etc/ipsec.d/private/)
: ECDSA gw-core.key

# Pre-shared key, scoped to a specific peer pair. Never use a PSK with
# right=%any: every client would share one secret and there is no revocation.
198.51.100.10 203.0.113.24 : PSK "REPLACE-WITH-A-LONG-RANDOM-SECRET"

# EAP credential for one user
alice@example.net : EAP "REPLACE-WITH-A-GENERATED-SECRET"

# XAuth (IKEv1 legacy)
bob@example.net : XAUTH "REPLACE-ME"
```

La semántica de `auto=` es examinable: `add` = sólo cargar (responder), `route` = instalar una política trampa para que el primer paquete coincidente dispare la negociación, `start` = negociar inmediatamente al arranque. `start_action` en `swanctl.conf` es su sucesor directo.

CLI legacy, con salida realista:

```bash
$ sudo ipsec restart
$ sudo ipsec status
Security Associations (1 up, 0 connecting):
      branch[1]: ESTABLISHED 27 minutes ago, 198.51.100.10[C=AR, O=Example Inc, CN=gw-core.example.net]...203.0.113.24[C=AR, O=Example Inc, CN=gw-branch.example.net]
      branch{1}: INSTALLED, TUNNEL, reqid 1, ESP SPIs: c1f3a20b_i 9a44b1c7_o
      branch{1}:   10.20.0.0/16 === 10.30.0.0/16

$ sudo ipsec up branch
$ sudo ipsec down branch
$ sudo ipsec statusall | sed -n '1,12p'
Status of IKE charon daemon (strongSwan 5.9.13, Linux 6.8.0-45-generic, x86_64):
  uptime: 34 minutes, since Aug 25 13:22:11 2026
  malloc: sbrk 3117056, mmap 0, used 1005104, free 2111952
  worker threads: 11 of 16 idle, 5/0/0/0 working, job queue: 0/0/0/0, scheduled: 8
  loaded plugins: charon aesni aes rc2 sha2 sha1 md5 mgf1 random nonce x509 revocation
    constraints pubkey pkcs1 pkcs7 pkcs8 pkcs12 pgp dnskey sshkey pem openssl gcm
    curve25519 xcbc cmac hmac kdf gcm drbg attr kernel-netlink resolve socket-default
    connmark stroke vici updown eap-identity eap-md5 eap-mschapv2 eap-tls eap-radius
    xauth-generic counters
Listening IP addresses:
  198.51.100.10
```

### 5.6 Alta disponibilidad

| Enfoque | Mecanismo | Failover | Compromiso |
|---|---|---|---|
| **Activo/pasivo con VRRP** | keepalived es dueño de la VIP; charon liga `%any` y arranca en la transición | Renegociación completa de cada SA (segundos a minutos a escala) | Simple, sin estado compartido; una tormenta de rekey en el failover |
| **Activo/pasivo con sincronización de estado** | El plugin `ha` (ClusterIP) sincroniza las IKE/CHILD SA | Sub-segundo, las SA sobreviven | Complejo, requiere un enlace de sincronización dedicado, acoplamiento estricto de versiones |
| **Activo/activo con ECMP** | Múltiples gateways, IPs públicas distintas; peers configurados con múltiples `remote_addrs` | Manejado por el peer; depende del comportamiento del peer | Sólo funciona si el peer soporta múltiples gateways; los caminos de retorno asimétricos requieren cuidado |
| **Anycast** | La misma IP anunciada desde múltiples sitios vía BGP | Convergencia de rutas | Los flujos ESP tienen que aterrizar en la misma máquina; una reconvergencia mata la SA |

Para la mayoría de los despliegues: **activo/pasivo con VRRP más `dpd_action = restart` y `dpd_delay` corto en los peers**, y aceptar un failover de 30–60 s. Reservá la sincronización de estado para túneles cuya pérdida sea un evento de facturación.

---

## 6. WireGuard en producción

### 6.1 Material de claves

```bash
$ sudo install -d -m 0700 /etc/wireguard
$ umask 077
$ wg genkey | sudo tee /etc/wireguard/hub.key | wg pubkey | sudo tee /etc/wireguard/hub.pub
mB1sQ2v9NnCk8pR4uYw1eXhL0dTgAo7ZsFj3KqPbWnE=

$ wg genkey | tee /tmp/branch.key | wg pubkey
7Xk2rVdLp0aCmH9uJ4sQxNwTf1EoZbY6gRk8ViUcPnA=

# A per-peer pre-shared key: mixed into the Noise handshake as an additional
# symmetric layer. It hedges against a future break of Curve25519 (harvest-now,
# decrypt-later) at zero cost. Use one per peer pair.
$ wg genpsk
oQ3mZ7bK1sVxT4pRfN0uYcJgE9dLhAiW2sBnXvQrMkU=

$ sudo chmod 0600 /etc/wireguard/*.key
```

**Nunca generes claves en una máquina central y distribuyas claves privadas.** Cada peer genera la suya; sólo la clave pública viaja.

### 6.2 Hub — `/etc/wireguard/wg0.conf`

```ini
# ── /etc/wireguard/wg0.conf  (hub: gw-core, 198.51.100.10) ───────────────
# Managed by wg-quick(8): systemctl enable --now wg-quick@wg0

[Interface]
Address     = 10.99.0.1/24, fd00:99::1/64
ListenPort  = 51820
PrivateKey  = REPLACE-WITH-CONTENTS-OF-/etc/wireguard/hub.key
# Better: keep the key out of this file entirely (wg-quick 1.0.20200827+):
#   PostUp = wg set %i private-key /etc/wireguard/hub.key
MTU         = 1420
FwMark      = 0xca6c
Table       = auto
SaveConfig  = false        # true rewrites this file on down: loses comments

PostUp   = sysctl -qw net.ipv4.ip_forward=1
PostUp   = sysctl -qw net.ipv6.conf.all.forwarding=1
PostUp   = nft -f /etc/nftables.d/vpn.nft
PostDown = nft delete table inet vpn || true

# ── Peer: gw-branch (site-to-site, static endpoint) ──────────────────────
[Peer]
# gw-branch.example.net
PublicKey    = 7Xk2rVdLp0aCmH9uJ4sQxNwTf1EoZbY6gRk8ViUcPnA=
PresharedKey = oQ3mZ7bK1sVxT4pRfN0uYcJgE9dLhAiW2sBnXvQrMkU=
Endpoint     = 203.0.113.24:51820
# Cryptokey routing: this peer OWNS these prefixes, inbound and outbound.
AllowedIPs   = 10.99.0.2/32, 10.30.0.0/16, fd00:99::2/128
PersistentKeepalive = 25

# ── Peer: alice's laptop (roaming, no fixed endpoint) ────────────────────
[Peer]
# alice@example.net — thinkpad-t14, enrolled 2026-08-25
PublicKey    = kR8vNw2LqTzYd6PmEuXbA1sHf0oJcVi9GnQr3KyBWtM=
PresharedKey = uT6xLpB0nWq9EyMcZv2Rk4SdAg1IhFjX7oNbUrKmVsQ=
AllowedIPs   = 10.99.0.50/32
# No Endpoint: the hub learns it from the first authenticated packet.
# No PersistentKeepalive on the hub side: the client behind NAT sends it.
```

### 6.3 Sucursal y cliente

```ini
# ── /etc/wireguard/wg0.conf  (gw-branch, 203.0.113.24) ───────────────────
[Interface]
Address    = 10.99.0.2/24
ListenPort = 51820
PrivateKey = REPLACE-WITH-CONTENTS-OF-/etc/wireguard/branch.key
MTU        = 1420

[Peer]
# gw-core
PublicKey    = mB1sQ2v9NnCk8pR4uYw1eXhL0dTgAo7ZsFj3KqPbWnE=
PresharedKey = oQ3mZ7bK1sVxT4pRfN0uYcJgE9dLhAiW2sBnXvQrMkU=
Endpoint     = 198.51.100.10:51820
AllowedIPs   = 10.99.0.0/24, 10.20.0.0/16
PersistentKeepalive = 25
```

```ini
# ── alice's laptop: full-tunnel profile ──────────────────────────────────
[Interface]
Address    = 10.99.0.50/32
PrivateKey = REPLACE-WITH-THE-LAPTOP-PRIVATE-KEY
DNS        = 10.20.0.53, corp.example.net
MTU        = 1420

[Peer]
PublicKey    = mB1sQ2v9NnCk8pR4uYw1eXhL0dTgAo7ZsFj3KqPbWnE=
PresharedKey = uT6xLpB0nWq9EyMcZv2Rk4SdAg1IhFjX7oNbUrKmVsQ=
Endpoint     = vpn.example.net:51820
# 0.0.0.0/0 ⇒ wg-quick installs the fwmark + policy-routing dance below
AllowedIPs   = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
```

Variante split-tunnel — cambiá una línea: `AllowedIPs = 10.20.0.0/16, 10.30.0.0/16, 10.99.0.0/24`. En WireGuard, split vs full tunnel es *enteramente* ese campo. No hay push del lado del servidor ni forma de que el hub lo fuerce; los `AllowedIPs` del cliente son la política. Si necesitás política impuesta por el servidor, imponela con reglas de firewall en el hub, no confiando en la configuración del cliente.

### 6.4 Qué hace realmente `wg-quick` con una ruta por defecto

```bash
$ sudo wg-quick up wg0
[#] ip link add wg0 type wireguard
[#] wg setconf wg0 /dev/fd/63
[#] ip -4 address add 10.99.0.50/32 dev wg0
[#] ip link set mtu 1420 up dev wg0
[#] resolvconf -a wg0 -m 0 -x
[#] wg set wg0 fwmark 51820
[#] ip -6 route add ::/0 dev wg0 table 51820
[#] ip -6 rule add not fwmark 51820 table 51820
[#] ip -6 rule add table main suppress_prefixlength 0
[#] ip6tables-restore -n
[#] ip -4 route add 0.0.0.0/0 dev wg0 table 51820
[#] ip -4 rule add not fwmark 51820 table 51820
[#] ip -4 rule add table main suppress_prefixlength 0
[#] iptables-restore -n
[#] sysctl -q net.ipv4.conf.all.src_valid_mark=1
```

Vale la pena entender el truco de tres líneas porque es lo que hace que un full tunnel funcione sin un bucle de routing:

1. `wg set wg0 fwmark 51820` — los propios paquetes UDP cifrados de WireGuard quedan marcados.
2. `ip rule add not fwmark 51820 table 51820` — todo *excepto* esos paquetes usa la tabla cuya ruta por defecto es `wg0`. El tráfico propio del túnel escapa entonces hacia la internet real en vez de recursar sobre sí mismo.
3. `ip rule add table main suppress_prefixlength 0` — consultá `main` primero, pero ignorá su ruta *por defecto* (longitud de prefijo 0). Las rutas específicas (LAN, la /32 del endpoint) siguen ganando, así que conservás la conectividad local.

```bash
$ ip rule show
0:      from all lookup local
32764:  from all lookup main suppress_prefixlength 0
32765:  not from all fwmark 0xca6c lookup 51820
32766:  from all lookup main
32767:  from all lookup default

$ ip route show table 51820
default dev wg0 scope link
```

### 6.5 Cambios de configuración en vivo sin tirar sesiones

`wg setconf` reemplaza todo el conjunto de peers y resetea los handshakes. `wg syncconf` calcula un diff — este es el que hay que usar en un hub en producción:

```bash
$ sudo wg set wg0 peer 9nH4vKzR2tLqB0eXcWm7PdAy1UgTsFjNoIrVbQ3kZuE= \
      preshared-key /etc/wireguard/psk-carol \
      allowed-ips 10.99.0.51/32

$ sudo wg-quick strip wg0 | sudo wg syncconf wg0 /dev/stdin   # reload from file
$ sudo wg set wg0 peer 9nH4vKzR2tLqB0eXcWm7PdAy1UgTsFjNoIrVbQ3kZuE= remove
```

La revocación es exactamente ese `remove` — no hay CRL, así que tu automatización tiene que ser la autoridad. Guardá el inventario de peers en git, renderizá `wg0.conf` y reconciliá con `syncconf`.

### 6.6 Verificación

```bash
$ sudo wg show wg0
interface: wg0
  public key: mB1sQ2v9NnCk8pR4uYw1eXhL0dTgAo7ZsFj3KqPbWnE=
  private key: (hidden)
  listening port: 51820
  fwmark: 0xca6c

peer: 7Xk2rVdLp0aCmH9uJ4sQxNwTf1EoZbY6gRk8ViUcPnA=
  preshared key: (hidden)
  endpoint: 203.0.113.24:51820
  allowed ips: 10.99.0.2/32, 10.30.0.0/16, fd00:99::2/128
  latest handshake: 47 seconds ago
  transfer: 3.21 MiB received, 8.44 MiB sent
  persistent keepalive: every 25 seconds

peer: kR8vNw2LqTzYd6PmEuXbA1sHf0oJcVi9GnQr3KyBWtM=
  preshared key: (hidden)
  endpoint: 190.17.44.201:57312
  allowed ips: 10.99.0.50/32
  latest handshake: 1 minute, 12 seconds ago
  transfer: 412.03 KiB received, 2.19 MiB sent

$ sudo wg show wg0 latest-handshakes
7Xk2rVdLp0aCmH9uJ4sQxNwTf1EoZbY6gRk8ViUcPnA=    1787061127
kR8vNw2LqTzYd6PmEuXbA1sHf0oJcVi9GnQr3KyBWtM=    1787061062

# Machine-readable: iface line, then one tab-separated line per peer:
# pubkey  psk  endpoint  allowed-ips  last-handshake  rx  tx  keepalive
$ sudo wg show all dump
wg0  mB1s...=  (none)  51820  0xca6c
wg0  7Xk2...=  (none)  203.0.113.24:51820  10.99.0.2/32,10.30.0.0/16  1787061127  3366255  8850739  25
wg0  kR8v...=  (none)  190.17.44.201:57312  10.99.0.50/32  1787061062  421918  2296381  off
```

El chequeo de salud de una línea que todo sistema de monitoreo debería correr:

```bash
$ sudo wg show all dump | awk 'NF>5 && (systime()-$6) > 180 {print "STALE:", $1, $2}'
```

---

## 7. L2TP — nivel de conocimiento

L2TP no cifra nada. Es un protocolo de tunelización para frames PPP (L2TPv2, RFC 2661) o pseudowires L2 arbitrarios (L2TPv3, RFC 3931). La confidencialidad viene de envolverlo en **modo transport de IPsec** (RFC 3193) — de ahí "L2TP/IPsec". Sabé por qué persiste: todo dispositivo Windows, macOS, iOS y Android tiene un marcador L2TP/IPsec incorporado, así que no necesita software de cliente en hardware que no controlás.

| | L2TPv2 | L2TPv3 |
|---|---|---|
| RFC | 2661 | 3931 |
| Payload | Sólo PPP | PPP, **Ethernet**, Frame Relay, HDLC |
| Transporte | UDP/1701 | UDP/1701 o **protocolo IP 115** |
| Uso típico | Acceso remoto con el marcador nativo del SO | Pseudowire L2 entre sitios (una alternativa a OpenVPN TAP) |
| Herramientas en Linux | `xl2tpd` + `pppd` + strongSwan | `ip l2tp` (kernel, sin demonio) |

El stack de paquetes para acceso remoto tiene cuatro capas de profundidad, por eso su comportamiento de MTU es malo y su depuración está repartida entre tres demonios:

```
IP | ESP | UDP(1701) | L2TP | PPP | IP | TCP | payload
        └─ IPsec transport mode protects everything to its right ─┘
```

Pseudowire Ethernet L2TPv3 mínimo sobre una SA IPsec existente en modo transport, sin necesidad de demonio:

```bash
# On gw-core (198.51.100.10)
$ sudo ip l2tp add tunnel tunnel_id 100 peer_tunnel_id 200 \
      encap udp local 198.51.100.10 remote 203.0.113.24 \
      udp_sport 1701 udp_dport 1701
$ sudo ip l2tp add session tunnel_id 100 session_id 1000 peer_session_id 2000 \
      name l2tpeth0
$ sudo ip link set l2tpeth0 up mtu 1400
$ sudo ip link set l2tpeth0 master br0        # now it is a real L2 pseudowire

$ sudo ip l2tp show tunnel
Tunnel 100, encap UDP
  From 198.51.100.10 to 203.0.113.24
  Peer tunnel 200
  UDP source / dest ports: 1701/1701
$ sudo ip l2tp show session
Session 1000 in tunnel 100
  Peer session 2000, tunnel 200
  interface name: l2tpeth0
  offset 0, peer offset 0
```

Y el clásico servidor de acceso remoto, `/etc/xl2tpd/xl2tpd.conf`:

```ini
[global]
port = 1701
access control = no
ipsec saref = yes
force userspace = yes

[lns default]
ip range = 10.20.210.100-10.20.210.199
local ip = 10.20.210.1
require chap = yes
refuse pap = yes
require authentication = yes
name = vpn.example.net
ppp debug = no
pppoptfile = /etc/ppp/options.xl2tpd
length bit = yes
```

```conf
# /etc/ppp/options.xl2tpd
require-mschap-v2
refuse-pap
refuse-chap
refuse-mschap
ms-dns 10.20.0.53
noccp
auth
idle 1800
mtu 1400
mru 1400
lcp-echo-interval 30
lcp-echo-failure 4
```

Desplegá esto sólo cuando un cliente nativo sea un requisito duro. Su comportamiento con NAT es pobre (muchos caminos CG-NAT lo rompen), su stack de MTU es frágil, y fuerza a la capa IPsec a bajar a lo que sea que soporte el marcador incorporado.

---

## 8. Infraestructura como código

### 8.1 Netplan — WireGuard declarativo en Ubuntu

```yaml
# /etc/netplan/60-wireguard.yaml   (chmod 0600 — it references key files)
network:
  version: 2
  renderer: networkd
  tunnels:
    wg0:
      mode: wireguard
      addresses:
        - 10.99.0.1/24
        - "fd00:99::1/64"
      port: 51820
      mark: 51820
      # Path to a file containing ONLY the base64 private key.
      key: /etc/wireguard/hub.key
      mtu: 1420
      peers:
        - keys:
            public: "7Xk2rVdLp0aCmH9uJ4sQxNwTf1EoZbY6gRk8ViUcPnA="
            shared: /etc/wireguard/psk-branch
          allowed-ips:
            - 10.99.0.2/32
            - 10.30.0.0/16
            - "fd00:99::2/128"
          endpoint: "203.0.113.24:51820"
          keepalive: 25
        - keys:
            public: "kR8vNw2LqTzYd6PmEuXbA1sHf0oJcVi9GnQr3KyBWtM="
            shared: /etc/wireguard/psk-alice
          allowed-ips:
            - 10.99.0.50/32
      routes:
        - to: 10.30.0.0/16
          scope: link
```

```bash
$ sudo chmod 0600 /etc/netplan/60-wireguard.yaml
$ sudo netplan generate && sudo netplan apply
$ sudo wg show wg0 | head -5
interface: wg0
  public key: mB1sQ2v9NnCk8pR4uYw1eXhL0dTgAo7ZsFj3KqPbWnE=
  private key: (hidden)
  listening port: 51820
  fwmark: 0xca6c
```

### 8.2 Ansible — enrolamiento de peers como un inventario reconciliado

```yaml
# ── roles/wireguard-hub/tasks/main.yml ───────────────────────────────────
---
- name: Ensure WireGuard is installed
  ansible.builtin.package:
    name: "{{ wireguard_packages }}"
    state: present
  vars:
    wireguard_packages:
      - wireguard-tools
      - nftables

- name: Ensure the configuration directory is private
  ansible.builtin.file:
    path: /etc/wireguard
    state: directory
    owner: root
    group: root
    mode: "0700"

- name: Generate the hub private key exactly once (never overwrite)
  ansible.builtin.shell:
    cmd: 'set -o pipefail; umask 077; wg genkey > /etc/wireguard/hub.key'
    creates: /etc/wireguard/hub.key
    executable: /bin/bash

- name: Derive the hub public key
  ansible.builtin.command:
    cmd: wg pubkey
    stdin: "{{ lookup('ansible.builtin.file', '/etc/wireguard/hub.key') }}"
  register: hub_pubkey
  changed_when: false
  no_log: true

- name: Render wg0.conf from the peer inventory
  ansible.builtin.template:
    src: wg0.conf.j2
    dest: /etc/wireguard/wg0.conf
    owner: root
    group: root
    mode: "0600"
    validate: "wg-quick strip %s > /dev/null"
  register: wg_config

- name: Enable forwarding
  ansible.posix.sysctl:
    name: "{{ item }}"
    value: "1"
    sysctl_file: /etc/sysctl.d/90-vpn.conf
    state: present
    reload: true
  loop:
    - net.ipv4.ip_forward
    - net.ipv6.conf.all.forwarding

- name: Ensure the interface is up and enabled at boot
  ansible.builtin.systemd:
    name: wg-quick@wg0
    enabled: true
    state: started
    daemon_reload: true

# Hot-reload without tearing down live sessions
- name: Sync peer set into the running interface
  ansible.builtin.shell:
    cmd: 'set -o pipefail; wg-quick strip wg0 | wg syncconf wg0 /dev/stdin'
    executable: /bin/bash
  when: wg_config.changed
  changed_when: true

- name: Assert every configured peer has a recent handshake
  ansible.builtin.shell:
    cmd: |
      set -o pipefail
      stale=$(wg show all dump | awk 'NF>5 && (systime()-$6) > 300 {print $2}')
      [ -z "$stale" ] || { echo "stale peers: $stale"; exit 1; }
    executable: /bin/bash
  register: wg_health
  changed_when: false
  failed_when: wg_health.rc != 0
  when: wireguard_assert_health | default(false)
```

```jinja
{# ── roles/wireguard-hub/templates/wg0.conf.j2 ───────────────────────── #}
# MANAGED BY ANSIBLE — local edits will be overwritten.
[Interface]
Address = {{ wg_hub_addresses | join(', ') }}
ListenPort = {{ wg_listen_port | default(51820) }}
MTU = {{ wg_mtu | default(1420) }}
PostUp = wg set %i private-key /etc/wireguard/hub.key
Table = auto

{% for peer in wg_peers | sort(attribute='name') %}
[Peer]
# {{ peer.name }} — owner {{ peer.owner }} — enrolled {{ peer.enrolled }}
PublicKey = {{ peer.public_key }}
{% if peer.preshared_key_file is defined %}
PresharedKey = {{ lookup('ansible.builtin.file', peer.preshared_key_file) }}
{% endif %}
AllowedIPs = {{ peer.allowed_ips | join(', ') }}
{% if peer.endpoint is defined %}
Endpoint = {{ peer.endpoint }}
{% endif %}
{% if peer.keepalive is defined %}
PersistentKeepalive = {{ peer.keepalive }}
{% endif %}

{% endfor %}
```

```yaml
# ── group_vars/vpn_hubs.yml ──────────────────────────────────────────────
wg_hub_addresses:
  - 10.99.0.1/24
  - "fd00:99::1/64"
wg_listen_port: 51820
wg_mtu: 1420
wg_peers:
  - name: gw-branch
    owner: platform-team
    enrolled: "2026-08-25"
    public_key: "7Xk2rVdLp0aCmH9uJ4sQxNwTf1EoZbY6gRk8ViUcPnA="
    preshared_key_file: /etc/wireguard/psk-branch
    allowed_ips: ["10.99.0.2/32", "10.30.0.0/16"]
    endpoint: "203.0.113.24:51820"
    keepalive: 25
  - name: alice-thinkpad
    owner: alice@example.net
    enrolled: "2026-08-25"
    public_key: "kR8vNw2LqTzYd6PmEuXbA1sHf0oJcVi9GnQr3KyBWtM="
    preshared_key_file: /etc/wireguard/psk-alice
    allowed_ips: ["10.99.0.50/32"]
```

### 8.3 Kubernetes — un gateway de egress con WireGuard

Caso de uso legítimo: pods en un cluster deben alcanzar una red de un partner accesible sólo por un túnel site-to-site, y el partner sólo va a poner en whitelist una dirección de origen.

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: vpn-egress
  labels:
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/audit: privileged
    pod-security.kubernetes.io/warn: privileged
---
apiVersion: v1
kind: Secret
metadata:
  name: wg-gateway-keys
  namespace: vpn-egress
type: Opaque
stringData:
  # Populate from an external secret manager; never commit real keys.
  privatekey: "REPLACE-WITH-BASE64-WIREGUARD-PRIVATE-KEY"
  psk-partner: "REPLACE-WITH-BASE64-WIREGUARD-PRESHARED-KEY"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: wg-gateway-config
  namespace: vpn-egress
data:
  wg0.conf: |
    [Interface]
    Address = 10.99.1.10/24
    ListenPort = 51820
    MTU = 1380
    # Private key is injected at start-up from the mounted Secret,
    # so it never appears in a ConfigMap or in `kubectl describe`.
    PostUp = wg set %i private-key /etc/wireguard/keys/privatekey
    PostUp = sysctl -qw net.ipv4.ip_forward=1
    PostUp = iptables -t nat -A POSTROUTING -o wg0 -j MASQUERADE
    PostUp = iptables -A FORWARD -i eth0 -o wg0 -j ACCEPT
    PostUp = iptables -A FORWARD -i wg0 -o eth0 -m state \
             --state RELATED,ESTABLISHED -j ACCEPT
    PostDown = iptables -t nat -D POSTROUTING -o wg0 -j MASQUERADE || true

    [Peer]
    # partner-gw
    PublicKey = 7Xk2rVdLp0aCmH9uJ4sQxNwTf1EoZbY6gRk8ViUcPnA=
    PresharedKey = REPLACED-AT-STARTUP
    Endpoint = 203.0.113.24:51820
    AllowedIPs = 10.99.1.0/24, 172.31.0.0/16
    PersistentKeepalive = 25
  healthcheck.sh: |
    #!/bin/sh
    # Unhealthy if no peer has handshaken within 180 s (REJECT_AFTER_TIME).
    set -eu
    now=$(date +%s)
    wg show all dump | awk -v now="$now" '
      NF > 5 { if (now - $6 < 180) ok = 1 }
      END { exit(ok ? 0 : 1) }
    '
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: wg-egress-gateway
  namespace: vpn-egress
  labels:
    app.kubernetes.io/name: wg-egress-gateway
spec:
  replicas: 2
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0
      maxSurge: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: wg-egress-gateway
  template:
    metadata:
      labels:
        app.kubernetes.io/name: wg-egress-gateway
    spec:
      automountServiceAccountToken: false
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: wg-egress-gateway
      containers:
        - name: wireguard
          image: ghcr.io/example/wireguard-go-tools:1.0.20250521
          command: ["/bin/sh", "-c"]
          args:
            - |
              set -eu
              install -m 0600 /config/wg0.conf /etc/wireguard/wg0.conf
              sed -i "s|REPLACED-AT-STARTUP|$(cat /etc/wireguard/keys/psk-partner)|" \
                  /etc/wireguard/wg0.conf
              exec wg-quick up wg0 && sleep infinity
          securityContext:
            allowPrivilegeEscalation: true
            readOnlyRootFilesystem: false
            capabilities:
              drop: ["ALL"]
              add: ["NET_ADMIN", "NET_RAW", "SYS_MODULE"]
          ports:
            - name: wireguard
              containerPort: 51820
              protocol: UDP
          volumeMounts:
            - { name: config,  mountPath: /config,             readOnly: true }
            - { name: keys,    mountPath: /etc/wireguard/keys, readOnly: true }
            - { name: modules, mountPath: /lib/modules,        readOnly: true }
            - { name: wgdir,   mountPath: /etc/wireguard }
          livenessProbe:
            exec:
              command: ["/bin/sh", "/config/healthcheck.sh"]
            initialDelaySeconds: 30
            periodSeconds: 30
            timeoutSeconds: 5
            failureThreshold: 3
          readinessProbe:
            exec:
              command: ["/bin/sh", "/config/healthcheck.sh"]
            initialDelaySeconds: 10
            periodSeconds: 10
          resources:
            requests: { cpu: "250m", memory: "64Mi" }
            limits:   { cpu: "2",    memory: "256Mi" }
      volumes:
        - name: config
          configMap:
            name: wg-gateway-config
            defaultMode: 0555
        - name: keys
          secret:
            secretName: wg-gateway-keys
            defaultMode: 0400
        - name: modules
          hostPath: { path: /lib/modules, type: Directory }
        - name: wgdir
          emptyDir: { medium: Memory }
---
apiVersion: v1
kind: Service
metadata:
  name: wg-egress-gateway
  namespace: vpn-egress
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: nlb
spec:
  type: LoadBalancer
  externalTrafficPolicy: Local     # preserve the client source IP
  selector:
    app.kubernetes.io/name: wg-egress-gateway
  ports:
    - name: wireguard
      port: 51820
      targetPort: 51820
      protocol: UDP
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: wg-egress-gateway
  namespace: vpn-egress
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: wg-egress-gateway
  policyTypes: ["Ingress", "Egress"]
  ingress:
    - ports:
        - { port: 51820, protocol: UDP }
  egress:
    - to:
        - ipBlock: { cidr: 203.0.113.24/32 }
      ports:
        - { port: 51820, protocol: UDP }
    - to:
        - ipBlock: { cidr: 172.31.0.0/16 }
```

### 8.4 Reglas de alertas de Prometheus

```yaml
# /etc/prometheus/rules/vpn.yml
groups:
  - name: vpn.rules
    interval: 30s
    rules:
      - alert: WireGuardPeerHandshakeStale
        expr: |
          (time() - wireguard_latest_handshake_seconds) > 300
          and wireguard_latest_handshake_seconds > 0
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "WireGuard peer {{ $labels.public_key }} has not handshaken in 5m"
          description: >-
            REJECT_AFTER_TIME is 180 s, so this tunnel is passing no traffic.
            Check reachability of the endpoint on UDP/51820 and confirm the
            peer's AllowedIPs do not overlap another peer's.
          runbook_url: "https://runbooks.example.net/vpn/wireguard-stale-handshake"

      - alert: WireGuardPeerNeverHandshaked
        expr: wireguard_latest_handshake_seconds == 0
        for: 10m
        labels: { severity: warning }
        annotations:
          summary: "WireGuard peer {{ $labels.public_key }} has never completed a handshake"

      - alert: IPsecChildSAMissing
        expr: strongswan_child_sa_state{state="INSTALLED"} == 0
        for: 3m
        labels: { severity: critical }
        annotations:
          summary: "CHILD_SA {{ $labels.child }} is not INSTALLED"
          description: >-
            Check `swanctl --list-sas`. TS_UNACCEPTABLE means the traffic
            selectors differ between peers; NO_PROPOSAL_CHOSEN means the
            algorithm proposals do not intersect.

      - alert: IPsecReplayWindowDrops
        expr: rate(node_xfrm_state_replay_window_total[5m]) > 0
        for: 10m
        labels: { severity: warning }
        annotations:
          summary: "ESP packets dropped by the anti-replay window"
          description: >-
            Multi-queue NICs reorder packets. Raise replay_window in the child
            config (1024) or pin RX queues; see /proc/net/xfrm_stat.

      - alert: OpenVPNCertificateExpiringSoon
        expr: (openvpn_certificate_expiry_seconds - time()) < 30 * 86400
        for: 1h
        labels: { severity: warning }
        annotations:
          summary: "OpenVPN certificate {{ $labels.cn }} expires in under 30 days"

      - alert: OpenVPNCRLExpiringSoon
        expr: (openvpn_crl_next_update_seconds - time()) < 7 * 86400
        for: 1h
        labels: { severity: critical }
        annotations:
          summary: "The OpenVPN CRL expires in under 7 days"
          description: >-
            An EXPIRED CRL makes OpenVPN reject EVERY client, not just revoked
            ones. Run `easyrsa gen-crl` and redeploy crl.pem.
```

---

## 9. Verificación y diagnóstico de fallas

### 9.1 El método por capas — siempre bisecá, nunca adivines

Trabajá de afuera hacia adentro. Cada escalón o bien pasa o bien localiza la falla; no te saltees un escalón porque "sabés" que está bien.

```
 L0  Is the daemon running and did it parse the config?
       systemctl status / journalctl -u ; openvpn --config X --test-crypto
 L1  Does the outer UDP/ESP packet leave and arrive?
       tcpdump on BOTH ends simultaneously
 L2  Did the control plane authenticate?
       "Initialization Sequence Completed" / IKE_SA ESTABLISHED / latest handshake
 L3  Is a data-plane SA installed and are its counters moving?
       ip xfrm state ; wg show transfer ; openvpn status file
 L4  Does the kernel route the inner packet into the tunnel?
       ip route get <dst> ; ip rule ; ip xfrm policy
 L5  Does the firewall permit forwarding, and is NAT correct?
       nft list ruleset ; counters on the drop rules
 L6  Is the MTU right?
       ping -M do -s <n> ; MSS clamp present?
 L7  Is the far-side host actually listening and does IT route back?
```

### 9.2 Observación a nivel de paquete

```bash
# IPsec: watch IKE and ESP together
$ sudo tcpdump -ni eth0 -vv 'udp port 500 or udp port 4500 or ip proto 50'
13:52:14.220144 IP 198.51.100.10.500 > 203.0.113.24.500: isakmp: parent_sa ikev2_init[I]
13:52:14.281903 IP 203.0.113.24.500 > 198.51.100.10.500: isakmp: parent_sa ikev2_init[R]
13:52:14.301774 IP 198.51.100.10.500 > 203.0.113.24.500: isakmp: child_sa  ikev2_auth[I]
13:52:14.372910 IP 203.0.113.24.500 > 198.51.100.10.500: isakmp: child_sa  ikev2_auth[R]
13:52:15.104822 IP 198.51.100.10 > 203.0.113.24: ESP(spi=0x9a44b1c7,seq=0x1), length 132
13:52:15.166301 IP 203.0.113.24 > 198.51.100.10: ESP(spi=0xc1f3a20b,seq=0x1), length 132

# See the DECRYPTED inner packet: capture on the xfrm/tun/wg interface instead
$ sudo tcpdump -ni ipsec0 -c 4 icmp
13:52:15.104701 IP 10.20.0.5 > 10.30.0.9: ICMP echo request, id 4711, seq 1, length 64
13:52:15.166420 IP 10.30.0.9 > 10.20.0.5: ICMP echo reply,   id 4711, seq 1, length 64

# WireGuard: only the outer UDP is visible; there is no plaintext on the wire
$ sudo tcpdump -ni eth0 'udp port 51820' -c 4
13:55:02.118220 IP 198.51.100.10.51820 > 203.0.113.24.51820: UDP, length 148   # handshake initiation
13:55:02.181330 IP 203.0.113.24.51820 > 198.51.100.10.51820: UDP, length 92    # handshake response
13:55:02.181902 IP 198.51.100.10.51820 > 203.0.113.24.51820: UDP, length 32    # keepalive
13:55:03.204411 IP 198.51.100.10.51820 > 203.0.113.24.51820: UDP, length 128   # transport data
```

Los largos de paquete son una huella digital: la iniciación de handshake de WireGuard son 148 bytes, la respuesta 92, la cookie reply 64, el keepalive 32. Si ves 148 repetidamente sin un 92 de respuesta, el responder no está contestando — clave equivocada, puerto equivocado, o un firewall.

### 9.3 Inspección del estado del kernel (IPsec)

```bash
$ sudo ip xfrm state
src 198.51.100.10 dst 203.0.113.24
	proto esp spi 0x9a44b1c7 reqid 1 mode tunnel
	replay-window 1024 flag af-unspec esn
	aead rfc4106(gcm(aes)) 0x7c1e...4b20 128
	anti-replay esn context:
	 seq-hi 0x0, seq 0x0, oseq-hi 0x0, oseq 0x1a4f
	 replay_window 1024, bitmap-length 32
	sel src 0.0.0.0/0 dst 0.0.0.0/0
	if_id 0x2a
src 203.0.113.24 dst 198.51.100.10
	proto esp spi 0xc1f3a20b reqid 1 mode tunnel
	replay-window 1024 flag af-unspec esn
	aead rfc4106(gcm(aes)) 0x91af...3d77 128
	if_id 0x2a

# Byte/packet counters and lifetimes — this is how you prove traffic flows
$ sudo ip -s xfrm state | grep -A4 'spi 0x9a44b1c7'
	proto esp spi 0x9a44b1c7 reqid 1 mode tunnel
	lifetime current:
	  244190(bytes), 1544(packets)
	  add 2026-08-25 13:41:02 use 2026-08-25 14:09:55

$ sudo ip xfrm policy
src 0.0.0.0/0 dst 0.0.0.0/0
	dir out priority 383615
	tmpl src 198.51.100.10 dst 203.0.113.24
		proto esp spi 0x00000000 reqid 1 mode tunnel
	if_id 0x2a

# Aggregate error counters — the single most useful IPsec diagnostic
$ cat /proc/net/xfrm_stat
XfrmInError                     0
XfrmInBufferError               0
XfrmInHdrError                  0
XfrmInNoStates                  17
XfrmInStateProtoError           0
XfrmInStateModeError            0
XfrmInStateSeqError             0
XfrmInStateExpired              0
XfrmInStateMismatch             0
XfrmInStateInvalid              0
XfrmInTmplMismatch              0
XfrmInNoPols                    0
XfrmInPolBlock                  0
XfrmInPolError                  0
XfrmOutError                    0
XfrmOutBundleGenError           0
XfrmOutNoStates                 43
XfrmOutStateProtoError          0
XfrmOutStateModeError           0
XfrmOutStateSeqError            0
XfrmOutStateExpired             0
XfrmOutPolBlock                 0
XfrmOutPolDead                  0
XfrmOutPolError                 0
XfrmFwdHdrError                 0
XfrmOutStateInvalid             0
XfrmAcquireError                0
```

Leer esa tabla es la habilidad de IPsec más rápida que podés adquirir:

| Contador en aumento | Significa | Solución |
|---|---|---|
| `XfrmInNoStates` | Llegó ESP para un SPI que no tenemos | El peer hizo rekey y nosotros no; SAs desincronizadas. `swanctl --terminate --ike <name>` y reestablecer |
| `XfrmOutNoStates` | Un paquete coincidió con una política pero todavía no existe una SA | Normal al momento del trap; si persiste significa que la negociación está fallando — leé charon.log |
| `XfrmInStateSeqError` | La ventana anti-replay rechazó un paquete | Reordenamiento. Subí `replay_window`; revisá multi-queue/RPS de la NIC |
| `XfrmInTmplMismatch` | El paquete llegó protegido, pero no por la SA que exige la política | Políticas solapadas o selectores discrepantes entre peers |
| `XfrmInStateProtoError` | Falló la verificación del ICV | Discrepancia de claves o un middlebox manipulando ESP — probá `encap = yes` |
| `XfrmInPolBlock` | El tráfico coincidió con una política `block` | Hay una política de denegación explícita instalada; revisá `ip xfrm policy` |

### 9.4 Referencia de firmas de error

| Firma | Stack | Causa raíz | Acción |
|---|---|---|---|
| `TLS Error: TLS key negotiation failed to occur within 60 seconds` | OpenVPN | Ninguna respuesta del canal de control llegó al cliente | UDP/1194 bloqueado; `proto` equivocado (`udp` vs `tcp`); clave `tls-crypt` equivocada o faltante — una discrepancia de `tls-crypt` hace que el servidor ignore los paquetes silenciosamente, lo que se ve idéntico a un descarte de firewall |
| `VERIFY ERROR: depth=0, error=certificate has expired` | OpenVPN | El certificado del cliente expiró | Reemitilo; revisá también el reloj del gateway |
| `VERIFY ERROR: ... error=CRL has expired` | OpenVPN | `crl.pem` rancio | `easyrsa gen-crl`; se está rechazando a **todos** los clientes, no sólo a los revocados |
| `Cannot load inline certificate file` | OpenVPN | Bloque inline malformado | Buscá finales de línea CRLF y espacios sueltos en el `.ovpn` |
| `MULTI: bad source address from client 10.30.0.9, packet dropped` | OpenVPN | El cliente envió tráfico desde un prefijo que no le pertenece | Falta el `iroute` en `ccd/<CN>`, o falta el `route` en la configuración del servidor |
| `Options error: Unrecognized option ... cipher` | OpenVPN 2.6 | `--cipher` removido de la negociación por defecto | Usá `data-ciphers`; agregá `data-ciphers-fallback` sólo para clientes 2.3 legacy |
| `Authentication failed` justo después de `PUSH_REPLY` | OpenVPN | Discrepancia de `auth`/`data-ciphers` tras un handshake TLS exitoso | Alineá la criptografía en ambos lados |
| `received NO_PROPOSAL_CHOSEN notify` | strongSwan | Las propuestas de IKE o ESP no se intersecan | Compará `proposals`/`esp_proposals` en ambos peers; sacá el `!` de `ipsec.conf` temporalmente para permitir los defaults y ver qué se elige |
| `received TS_UNACCEPTABLE notify` | strongSwan | Los traffic selectors difieren | `local_ts` de un lado debe ser igual a `remote_ts` del otro, exactamente. Una /16 contra dos /24 es una discrepancia en muchos fabricantes |
| `received AUTHENTICATION_FAILED notify` | strongSwan | PSK equivocada, ID equivocado, CA no confiable, o desfasaje de reloj | Verificá que `id` coincida con un SAN/DN del certificado presentado; corré `swanctl --list-certs` en ambos extremos; `timedatectl` |
| `no matching peer config found` | strongSwan | El responder no puede mapear el ID del initiator a una conexión | `remote { id = ... }` demasiado estrecho, o falta `%any` |
| `constraint check failed: identity 'X' required` | strongSwan | Discrepancia de restricción de ID | El SAN del certificado no contiene el `id` configurado |
| `retransmit 5 of request with message ID 0` | strongSwan | Sin respuesta a `IKE_SA_INIT` | UDP/500 bloqueado, peer caído, o `remote_addrs` equivocado |
| `IKE_SA_INIT ok, IKE_AUTH times out` | strongSwan | IKE_AUTH está fragmentado (cadena de certificados > MTU) y los fragmentos se descartan | Habilitá `fragmentation = yes`; usá certificados ECDSA para achicar la cadena |
| `Handshake did not complete after 5 seconds, retrying` | WireGuard (log del kernel) | Sin respuesta de handshake | `PublicKey` equivocada, `Endpoint` equivocado, UDP bloqueado, discrepancia de PSK |
| `Invalid MAC of handshake, dropping packet` | WireGuard | Material de claves equivocado | La `PublicKey` del peer de este lado no coincide con su clave privada real, o un lado tiene una PSK que el otro no |
| `Packet has unallowed src IP from peer` | WireGuard | El origen interno no está en `AllowedIPs` | Agregá el prefijo, o encontrá el peer que se lo está robando |
| `Name or service not known` en `wg-quick up` | WireGuard | El DNS del `Endpoint` falla al arranque | Agregá `After=network-online.target`, o usá una IP literal |
| `RTNETLINK answers: Operation not supported` | WireGuard | Falta el módulo del kernel | `modprobe wireguard`; caé de vuelta a `wireguard-go` en kernels viejos |
| El ping funciona, SSH se cuelga después del banner | **todos** | Agujero negro de MTU | §9.5 |

### 9.5 Diagnóstico de MTU — el procedimiento determinista

```bash
# 1. Confirm the symptom shape: small OK, large lost.
$ ping -c2 -M do -s 1200 10.30.0.9
PING 10.30.0.9 (10.30.0.9) 1200(1228) bytes of data.
1208 bytes from 10.30.0.9: icmp_seq=1 ttl=63 time=18.4 ms
1208 bytes from 10.30.0.9: icmp_seq=2 ttl=63 time=18.1 ms
--- 10.30.0.9 ping statistics ---
2 packets transmitted, 2 received, 0% packet loss, time 1002ms

$ ping -c2 -M do -s 1450 10.30.0.9
PING 10.30.0.9 (10.30.0.9) 1450(1478) bytes of data.
--- 10.30.0.9 ping statistics ---
2 packets transmitted, 0 received, 100% packet loss, time 1023ms
   ← silence, not "Frag needed" ⇒ ICMP is being filtered ⇒ PMTUD is dead

# 2. Bisect for the real usable size (add 28 for IPv4+ICMP headers).
$ for s in 1400 1372 1360 1340; do
      printf '%5d: ' "$s"
      ping -c1 -W1 -M do -s "$s" 10.30.0.9 >/dev/null 2>&1 && echo OK || echo FAIL
  done
 1400: FAIL
 1372: FAIL
 1360: OK
 1340: OK
   ⇒ usable payload 1360 ⇒ interface MTU 1388

# 3. Apply on BOTH gateways, and clamp MSS regardless.
$ sudo ip link set mtu 1388 dev ipsec0
$ sudo nft add rule inet vpn forward tcp flags syn tcp option maxseg size set rt mtu

# 4. Confirm what the kernel learned per destination.
$ ip route get 10.30.0.9
10.30.0.9 dev ipsec0 src 10.20.0.5 uid 1000
    cache expires 588sec mtu 1388

# 5. OpenVPN has a built-in probe (run from the client):
$ sudo openvpn --config alice.ovpn --mtu-test
NOTE: Beginning empirical MTU test -- results should be available in 3 to 4 minutes.
NOTE: Empirical MTU test completed [Tried,Actual] local->remote=[1573,1420] remote->local=[1573,1420]
```

### 9.6 Medición de throughput — medí, no cites de memoria

```bash
# Baseline WITHOUT the tunnel, then inside it. The delta is the real cost.
$ iperf3 -c 203.0.113.24 -t 20 -P 4 --get-server-output | tail -5
[SUM]   0.00-20.00  sec  2.18 GBytes   936 Mbits/sec                  sender
[SUM]   0.00-20.00  sec  2.17 GBytes   933 Mbits/sec                  receiver

$ iperf3 -c 10.30.0.9 -t 20 -P 4 | tail -5
[SUM]   0.00-20.00  sec  1.94 GBytes   833 Mbits/sec                  sender
[SUM]   0.00-20.00  sec  1.93 GBytes   830 Mbits/sec                  receiver

# Where the CPU goes
$ sudo perf top -e cycles --sort comm,dso
  38.11%  [kernel]        [k] aesni_xts_encrypt
  11.02%  [kernel]        [k] chacha20_neon
   6.74%  ksoftirqd/2     [k] __netif_receive_skb_core
   4.21%  openvpn         [.] openvpn_encrypt

# Is AES-NI actually available? Without it, prefer ChaCha20-Poly1305.
$ grep -o -m1 -E 'aes|avx2|vaes' /proc/cpuinfo | sort -u
aes
avx2

# Offload state — GRO/GSO on the tunnel interface changes throughput by 2-3x
$ ethtool -k wg0 | grep -E 'generic-(receive|segmentation)-offload'
generic-receive-offload: on
generic-segmentation-offload: on
```

Reglas prácticas que sobreviven a la medición: con AES-NI presente, preferí AES-GCM; sin él (ARM más viejo, algunos gateways embebidos), ChaCha20-Poly1305 es dramáticamente más rápido. Una instancia OpenVPN en espacio de usuario es de un solo hilo por cliente en el camino de datos — escalala con múltiples instancias de servidor en puertos distintos más un balanceador de carga, o habilitá DCO.

### 9.7 Depuración en vivo

```bash
# strongSwan: raise verbosity at runtime, no restart, no dropped SAs
$ sudo swanctl --log &            # stream the daemon log to this terminal
$ sudo swanctl --list-conns
branch: IKEv2, no reauthentication, rekeying every 14400s
  local:  198.51.100.10
  remote: 203.0.113.24
  local public key authentication:
    id: C=AR, O=Example Inc, CN=gw-core.example.net
    certs: C=AR, O=Example Inc, CN=gw-core.example.net
  remote public key authentication:
    id: C=AR, O=Example Inc, CN=gw-branch.example.net
  net: TUNNEL, rekeying every 3600s
    local:  0.0.0.0/0
    remote: 0.0.0.0/0

$ sudo swanctl --list-certs --subject gw-branch.example.net
List of X.509 End Entity Certificates
  subject:  "C=AR, O=Example Inc, CN=gw-branch.example.net"
  issuer:   "C=AR, O=Example Inc, CN=Example IPsec CA"
  validity:  not before Aug 25 13:44:19 2026, ok
             not after  Sep 27 13:44:19 2027, ok (expires in 397 days)

$ sudo swanctl --stats
uptime: 51 minutes, since Aug 25 13:22:11 2026
worker threads: 11 total, 5 idle, working: 6/0/0/0
job queues: 0/0/0/0
IKE_SAs: 1 total, 0 half-open

$ sudo swanctl --terminate --ike branch      # controlled teardown
$ sudo swanctl --load-all                    # reload config, keep live SAs

# OpenVPN: current sessions from the status file
$ sudo cat /run/openvpn-server/status-core.log
TITLE,OpenVPN 2.6.12 x86_64-pc-linux-gnu [SSL (OpenSSL)] [LZO] [LZ4] [EPOLL] [DCO]
TIME,2026-08-25 14:11:03,1787069463
HEADER,CLIENT_LIST,Common Name,Real Address,Virtual Address,Virtual IPv6 Address,Bytes Received,Bytes Sent,Connected Since,Connected Since (time_t),Username,Client ID,Peer ID,Data Channel Cipher
CLIENT_LIST,alice@example.net,190.17.44.201:57312,10.20.200.50,,1841204,9930118,2026-08-25 13:11:03,1787065863,UNDEF,0,3,AES-256-GCM
CLIENT_LIST,gw-branch.example.net,203.0.113.24:1194,10.20.200.10,,88214553,71203881,2026-08-25 09:02:11,1787051131,UNDEF,1,4,AES-256-GCM
HEADER,ROUTING_TABLE,Virtual Address,Common Name,Real Address,Last Ref,Last Ref (time_t)
ROUTING_TABLE,10.20.200.50,alice@example.net,190.17.44.201:57312,2026-08-25 14:11:01,1787069461
ROUTING_TABLE,10.30.0.0/16,gw-branch.example.net,203.0.113.24:1194,2026-08-25 14:11:02,1787069462
GLOBAL_STATS,Max bcast/mcast queue length,3
END

# OpenVPN: management interface for live control
$ sudo socat - UNIX-CONNECT:/run/openvpn-server/mgmt-core.sock
>INFO:OpenVPN Management Interface Version 5 -- type 'help' for more info
status 3
state
log 20
kill alice@example.net
quit

# WireGuard: the kernel module is the only thing that logs
$ echo module wireguard +p | sudo tee /sys/kernel/debug/dynamic_debug/control
$ sudo dmesg -w | grep -i wireguard
[ 4021.118220] wireguard: wg0: Sending handshake initiation to peer 2 (203.0.113.24:51820)
[ 4021.181330] wireguard: wg0: Receiving handshake response from peer 2 (203.0.113.24:51820)
[ 4021.181402] wireguard: wg0: Keypair 7 created for peer 2
[ 4083.402118] wireguard: wg0: Receiving handshake initiation from peer 4 (190.17.44.201:57312)
[ 4083.402551] wireguard: wg0: Sending handshake response to peer 4 (190.17.44.201:57312)
```

### 9.8 Lista de verificación posterior al cambio

Corré esto después de cada cambio de VPN, antes de cerrar el ticket:

```bash
$ set -e
# 1. Control plane is up
$ sudo swanctl --list-sas | grep -c ESTABLISHED
$ sudo wg show all dump | awk 'NF>5 && (systime()-$6)<180' | wc -l
$ sudo grep -c "Initialization Sequence Completed" /var/log/openvpn/core.log

# 2. Data plane counters are MOVING (take two samples, 10 s apart)
$ sudo ip -s xfrm state | awk '/lifetime current/{getline; print $1}'

# 3. Routing is symmetric — check from BOTH sides
$ ip route get 10.30.0.9
$ ssh gw-branch ip route get 10.20.0.5

# 4. End-to-end reachability at full MTU
$ ping -c3 -M do -s 1360 10.30.0.9

# 5. The firewall is not silently eating anything
$ sudo nft list ruleset | grep -A1 'comment "forward-drop"'

# 6. It survives a reboot
$ systemctl is-enabled strongswan wg-quick@wg0 openvpn-server@core
```

---

## 10. Alineación con el examen: archivos, comandos y puertos de un vistazo

| Archivo / ruta | Stack | Propósito |
|---|---|---|
| `/etc/openvpn/server/*.conf` | OpenVPN | Instancias de servidor; arrancadas por `openvpn-server@<name>.service` |
| `/etc/openvpn/client/*.conf` | OpenVPN | Instancias de cliente; `openvpn-client@<name>.service` |
| `/etc/openvpn/server/ccd/<CN>` | OpenVPN | Overrides por cliente: `iroute`, `ifconfig-push`, `push` |
| `/etc/ipsec.conf` | strongSwan (legacy) | Secciones `conn`; `auto=add|route|start` |
| `/etc/ipsec.secrets` | strongSwan (legacy) | PSK, referencias a claves RSA/ECDSA, credenciales EAP/XAUTH |
| `/etc/ipsec.d/{cacerts,certs,private}/` | strongSwan (legacy) | Almacén de credenciales |
| `/etc/swanctl/swanctl.conf`, `conf.d/*.conf` | strongSwan (moderno) | `connections`, `secrets`, `pools`, `authorities` |
| `/etc/swanctl/{x509ca,x509,private}/` | strongSwan (moderno) | Almacén de credenciales |
| `/etc/strongswan.conf`, `/etc/strongswan.d/` | strongSwan | Ajuste del demonio, plugins, logging |
| `/etc/wireguard/<iface>.conf` | WireGuard | Secciones `[Interface]` + `[Peer]`, consumidas por `wg-quick` |
| `/etc/xl2tpd/xl2tpd.conf`, `/etc/ppp/options.xl2tpd` | L2TP | Opciones del LNS y de PPP |

| Comando | Qué hace |
|---|---|
| `openvpn --config f.conf` | Correr en primer plano |
| `openvpn --genkey secret ta.key` | Generar una clave `tls-auth`/`tls-crypt` (sintaxis 2.6) |
| `openvpn --show-ciphers` / `--show-digests` / `--show-tls` | Enumerar algoritmos disponibles |
| `openvpn --mtu-test` | Sondeo empírico de MTU |
| `ipsec start|restart|status|statusall|up <conn>|down <conn>` | Control legacy |
| `ipsec listcerts|listcacerts|rereadsecrets` | Inspección de credenciales legacy |
| `swanctl --load-all` | Recargar configuración sin tirar las SA activas |
| `swanctl --list-sas|--list-conns|--list-certs|--list-pools|--stats|--log` | Inspeccionar |
| `swanctl --initiate --child <n>` / `--terminate --ike <n>` | Levantar/bajar un túnel |
| `pki --gen|--self|--issue|--print` | La herramienta de PKI de strongSwan |
| `wg genkey|pubkey|genpsk` | Material de claves |
| `wg show [iface] [dump\|latest-handshakes\|transfer]` | Inspeccionar |
| `wg set <iface> peer <pub> allowed-ips ... [remove]` | Cambios de peers en vivo |
| `wg setconf` / `wg syncconf` / `wg-quick strip` | Cargar configuración completa / aplicar diff / renderizar |
| `wg-quick up|down|save|strip <iface>` | Ciclo de vida de la interfaz incluyendo rutas y firewall |
| `ip xfrm state|policy` , `ip -s xfrm state` | SAD/SPD del kernel |
| `ip l2tp add tunnel|session` , `ip l2tp show` | Pseudowires L2TPv3 |

| Puerto / protocolo | Usado por |
|---|---|
| UDP 1194 (por defecto, configurable) | OpenVPN |
| TCP 443 (alternativa común) | OpenVPN sobre TCP a través de redes restrictivas |
| UDP 500 | IKEv1/IKEv2 |
| UDP 4500 | NAT-T de IKEv2 (ESP encapsulado en UDP) |
| Protocolo IP 50 | ESP |
| Protocolo IP 51 | AH (legacy, incompatible con NAT) |
| UDP 51820 (convención, sin default) | WireGuard |
| UDP 1701 | L2TP |
| Protocolo IP 115 | L2TPv3 sobre IP |

---

## Referencias

**Objetivos del examen**
- LPI Exam 303-300 Objectives (Topic 334: Network Security, incl. 334.4 Virtual Private Networks) — https://www.lpi.org/our-certifications/exam-303-objectives/
- LPIC-3 Security certification overview — https://www.lpi.org/our-certifications/lpic-3-303-overview/

**OpenVPN**
- OpenVPN 2.6 reference manual (all options: `--data-ciphers`, `--tls-crypt-v2`, `--topology`, `--server-bridge`, `--client-config-dir`) — https://openvpn.net/community-resources/reference-manual-for-openvpn-2-6/
- OpenVPN community wiki (HOWTO, bridging vs routing, DCO) — https://community.openvpn.net/openvpn/wiki
- OpenVPN change log (2.6 cipher deprecations and DCO) — https://github.com/OpenVPN/openvpn/blob/master/Changes.rst
- OpenVPN Data Channel Offload — https://community.openvpn.net/openvpn/wiki/DataChannelOffload
- Easy-RSA documentation — https://github.com/OpenVPN/easy-rsa/blob/master/doc/EasyRSA-Advanced.md

**strongSwan / IPsec**
- strongSwan documentation index — https://docs.strongswan.org/docs/latest/index.html
- `swanctl.conf` reference — https://docs.strongswan.org/docs/latest/swanctl/swanctlConf.html
- IKEv2 cipher suites and proposal syntax — https://docs.strongswan.org/docs/latest/config/proposals.html
- Route-based VPNs with XFRM interfaces — https://docs.strongswan.org/docs/latest/features/routeBasedVpn.html
- `ipsec.conf` (legacy `starter`) reference — https://docs.strongswan.org/docs/latest/config/IKEv2.html
- `pki` command reference — https://docs.strongswan.org/docs/latest/utils/pki.html
- VICI protocol and bindings — https://docs.strongswan.org/docs/latest/plugins/vici.html

**WireGuard**
- WireGuard project site — https://www.wireguard.com/
- WireGuard: Next Generation Kernel Network Tunnel (NDSS 2017 whitepaper — protocol, Noise_IKpsk2, timers) — https://www.wireguard.com/papers/wireguard.pdf
- Cryptokey routing and `AllowedIPs` — https://www.wireguard.com/#cryptokey-routing
- Known limitations — https://www.wireguard.com/known-limitations/
- `wg(8)` manual — https://git.zx2c4.com/wireguard-tools/about/src/man/wg.8
- `wg-quick(8)` manual — https://git.zx2c4.com/wireguard-tools/about/src/man/wg-quick.8

**RFCs**
- RFC 7296 — Internet Key Exchange Protocol Version 2 (IKEv2) — https://www.rfc-editor.org/rfc/rfc7296
- RFC 4303 — IP Encapsulating Security Payload (ESP) — https://www.rfc-editor.org/rfc/rfc4303
- RFC 4301 — Security Architecture for the Internet Protocol — https://www.rfc-editor.org/rfc/rfc4301
- RFC 3948 — UDP Encapsulation of IPsec ESP Packets (NAT-T) — https://www.rfc-editor.org/rfc/rfc3948
- RFC 4555 — IKEv2 Mobility and Multihoming Protocol (MOBIKE) — https://www.rfc-editor.org/rfc/rfc4555
- RFC 7383 — IKEv2 Message Fragmentation — https://www.rfc-editor.org/rfc/rfc7383
- RFC 2661 — Layer Two Tunneling Protocol "L2TP" — https://www.rfc-editor.org/rfc/rfc2661
- RFC 3931 — Layer Two Tunneling Protocol - Version 3 (L2TPv3) — https://www.rfc-editor.org/rfc/rfc3931
- RFC 3193 — Securing L2TP using IPsec — https://www.rfc-editor.org/rfc/rfc3193

**Linux kernel and tooling**
- Kernel XFRM device documentation — https://www.kernel.org/doc/html/latest/networking/xfrm_device.html
- `ip-xfrm(8)` — https://man7.org/linux/man-pages/man8/ip-xfrm.8.html
- `ip-l2tp(8)` — https://man7.org/linux/man-pages/man8/ip-l2tp.8.html
- `systemd.netdev(5)` (WireGuard and XFRM kinds) — https://www.freedesktop.org/software/systemd/man/latest/systemd.netdev.html
- Netplan YAML configuration reference (`mode: wireguard`) — https://netplan.readthedocs.io/en/stable/netplan-yaml/
- nftables wiki — https://wiki.nftables.org/wiki-nftables/index.php/Main_Page