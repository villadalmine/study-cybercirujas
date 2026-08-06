# LPIC-3 Exam 303-300 (v3.0) — Topic 334 / 5.1: Network Security

**Nivel:** Avanzado / Arquitectura de Producción  
**Peso del Examen:** 16.67 (Peso general del Topic 334)  
**Referencia Oficial:** [LPI LPIC-3 303 Overview](https://www.lpi.org/our-certifications/lpic-3-303-overview/) | [Netfilter nftables Documentation](https://netfilter.org/projects/nftables/) | [WireGuard Technical Whitepaper](https://www.wireguard.com/papers/wireguard.pdf) | [Suricata User Guide](https://docs.suricata.io/)

---

## Visión General Técnica y Arquitectura Core

La seguridad de red (Network Security) en entornos Linux empresariales requiere defensa en profundidad (defense-in-depth) a través de la pila de red del kernel, ganchos (hooks) de filtrado de tráfico, inspección profunda de paquetes (DPI) en tiempo real y túneles de tránsito criptográficamente seguros.

```
                                  [ Incoming Packet ]
                                           │
                                           ▼
                                 ┌──────────────────┐
                                 │  NIC / Driver    │
                                 └─────────┬────────┘
                                           │ (XDP / tc ingress hook)
                                           ▼
                                 ┌──────────────────┐
                                 │  netfilter Hook  │
                                 │   (PREROUTING)   │
                                 └─────────┬────────┘
                                           │
                        ┌──────────────────┴──────────────────┐
                        │                                     │
           [ Local Destination ]                       [ Forwarding ]
                        │                                     │
                        ▼                                     ▼
             ┌─────────────────────┐               ┌─────────────────────┐
             │ netfilter (INPUT)   │               │ netfilter (FORWARD) │
             └──────────┬──────────┘               └──────────┬──────────┘
                        │                                     │
                        ▼                                     ▼
             ┌─────────────────────┐               ┌─────────────────────┐
             │ Socket Layer / BPF  │               │ netfilter (POSTROUTING)
             └──────────┬──────────┘               └──────────┬──────────┘
                        │                                     │
                        ▼                                     ▼
             ┌─────────────────────┐                       [ NIC Out ]
             │ Application (Suricata│
             │   / OpenVPN / etc.) │
             └─────────────────────┘
```

Los temas principales cubiertos en este módulo son:
1. **Network Hardening:** Ajuste del kernel (kernel tuning) mediante interfaces sysctl en `/proc/sys/net/` (Reverse Path Filtering RFC 3704, TCP SYN cookies, rechazo de ICMP redirect), defensas contra ARP poisoning y auditoría de estado de sockets con `ss`/`iproute2`.
2. **Packet Filtering:** Arquitectura netfilter de última generación con `nftables`, diseño de tablas con búsqueda dual (dual-lookup table), reemplazo atómico de reglas, seguimiento de conexiones con estado (`conntrack`) y búsquedas de sets/maps de alto rendimiento.
3. **Network Intrusion Detection & Prevention (NIDS/NIPS):** Análisis de firmas multihilo (multi-threaded signature parsing), reensamblado de flujos (stream reassembly) y registro de eventos JSON (`eve.json`) utilizando Suricata, junto con el bloqueo automático dinámico de IP mediante `fail2ban`.
4. **Virtual Private Networks (VPNs):** Tunelización Site-to-Site y Remote Access utilizando WireGuard (Cryptokey Routing, protocolo NoiseIK), IPsec strongSwan (IKEv2, modos transport/tunnel ESP/AH) y OpenVPN (autenticación TLS y adaptadores virtuales TUN/TAP).

---

## Requisitos Previos del Laboratorio

Todos los comandos en estos ejercicios asumen un sistema Enterprise Linux moderno (kernel 5.4+ / Linux 6.x) con privilegios administrativos de `root`. Paquetes requeridos en los ejercicios: `nftables`, `iproute2`, `wireguard-tools`, `suricata`, `fail2ban`, `strongswan`, `nmap`.

---

## Ejercicio 1: Advanced Kernel Network Hardening y Auditoría de Sockets

### Contexto Arquitectónico y Mecánica Interna
La pila TCP/IP de Linux implementa especificaciones RFC que pueden ajustarse para mitigar ataques de denegación de servicio (DoS), IP spoofing y man-in-the-middle (MitM).
* **TCP SYN Cookies (`net.ipv4.tcp_syncookies`):** Cuando la cola de backlog TCP SYN se desborda durante un ataque de SYN flood, el kernel omite la asignación de la cola codificando los números de secuencia iniciales ($ISN$) de forma criptográfica mediante una clave secreta, una marca de tiempo (timestamp) y un hash del payload de 5 tuplas:
  $$ISN = \text{hash}(src\_ip, src\_port, dst\_ip, dst\_port, secret, timestamp) + seq\_offset$$
  Al recibir el ACK del cliente, el kernel verifica $ISN - 1$, validando la legitimidad de la conexión con costo de memoria cero (zero-memory-cost).
* **Reverse Path Filtering (`net.ipv4.conf.*.rp_filter`):** El modo estricto (`1`) realiza una búsqueda de ruta RFC 3704 sobre las IP de origen de los paquetes entrantes. Si la mejor ruta de retorno fuera de la tabla de enrutamiento no coincide con la interfaz por la que llegó el paquete, el paquete se descarta, previniendo el IP spoofing.

---

### Ejecución Paso a Paso

#### Paso 1: Auditar Socket Listeners Activos y Vinculaciones de Procesos
Ejecutá `ss` para inspeccionar todos los sockets TCP y UDP abiertos en escucha, mostrando puertos numéricos, uso de memoria y contexto de proceso.

```bash
ss -tulpn
```

**Expected Output:**
```text
Netid  State   Recv-Q  Send-Q     Local Address:Port      Peer Address:Port  Process                                                                         
udp    UNCONN  0       0                0.0.0.0:68             0.0.0.0:*      users:(("dhclient",pid=842,fd=6))                                               
tcp    LISTEN  0       128              0.0.0.0:22             0.0.0.0:*      users:(("sshd",pid=1120,fd=3))                                                  
tcp    LISTEN  0       512            127.0.0.1:6379           0.0.0.0:*      users:(("redis-server",pid=1450,fd=6))                                          
tcp    LISTEN  0       128                 [::]:22                [::]:*      users:(("sshd",pid=1120,fd=4))
```

#### Paso 2: Implementar la Matriz de Hardening Sysctl para Producción
Creá `/etc/sysctl.d/99-network-hardening.conf` con parámetros de red del kernel endurecidos para producción.

```bash
cat << 'EOF' > /etc/sysctl.d/99-network-hardening.conf
# Enable TCP SYN Cookies to prevent SYN Flood attacks
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_synack_retries = 2

# Enforce RFC 3704 Strict Reverse Path Filtering across all interfaces
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Ignore ICMP Echo requests sent to broadcast/multicast addresses (Smurf attack prevention)
net.ipv4.icmp_echo_ignore_broadcasts = 1

# Disable ICMP Redirect acceptance (prevents MitM routing table alteration)
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

# Do not send ICMP Redirects (Host acts as strict endpoint, not router)
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# Log Source Routed, IP Spoofed, and Impossible Packets (Martians)
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1

# Disable Source Routing (Drop packets with LSRR/SSRR options)
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
EOF
```

Aplicá los parámetros de forma atómica:

```bash
sysctl --system
```

**Expected Output:**
```text
* Applying /etc/sysctl.d/99-network-hardening.conf ...
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_synack_retries = 2
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
```

#### Paso 3: Endurecimiento del Procesamiento ARP contra Cache Poisoning
Configurá el comportamiento ARP de la tabla de vecinos (neighbor table) para coincidir estrictamente las respuestas entrantes con las definiciones de direcciones locales (`arp_ignore = 1`) y restringir el modo de respuesta (`arp_announce = 2`).

```bash
sysctl -w net.ipv4.conf.all.arp_ignore=1
sysctl -w net.ipv4.conf.all.arp_announce=2
```

**Expected Output:**
```text
net.ipv4.conf.all.arp_ignore = 1
net.ipv4.conf.all.arp_announce = 2
```

---

### Preguntas de Verificación del Ejercicio 1

1. **Pregunta 1.1:** En un sistema desplegado con enrutamiento asimétrico (donde los paquetes de salida salen a través de la interfaz `eth0` y los paquetes de entrada llegan a través de `eth1`), establecer `net.ipv4.conf.all.rp_filter = 1` provoca que el tráfico entrante legítimo sea descartado silenciosamente por el kernel. ¿Por qué sucede esto y cuál es la diferencia operativa precisa entre el modo estricto (`1`) y el modo laxo (`2`) según lo definido en la RFC 3704?
2. **Pregunta 1.2:** ¿Cómo altera la activación de `net.ipv4.tcp_syncookies` el three-way handshake TCP bajo condiciones normales de funcionamiento versus bajo saturación activa de la cola (SYN flood), y qué opciones específicas de la cabecera TCP se sacrifican cuando se activan los SYN cookies?

---

## Ejercicio 2: Production Packet Filtering y Seguimiento de Estado con `nftables`

### Contexto Arquitectónico y Mecánica Interna
`nftables` reemplaza al legado `iptables` integrando el filtrado de paquetes, NAT y la modificación de paquetes (packet mangling) en una sola máquina virtual dentro del kernel (motor nft_expr).
* **Evaluation Speed:** A diferencia de `iptables`, que evalúa reglas linealmente (sobrecarga de búsqueda de $O(N)$), `nftables` utiliza sets y diccionarios nativos, proporcionando búsquedas dinámicas en tiempo constante $O(1)$ incluso con decenas de miles de direcciones IP.
* **Hook Architecture:** Los ganchos (hooks) existen en `ingress` (nivel netdev, antes del manejo de capa 3), `prerouting`, `input`, `forward`, `output` y `postrouting`.

```
           [ Ingress Hook (Netdev) ]  <-- Fast path XDP/Driver level drop
                      │
                      ▼
            [ Prerouting Hook ]
                      │
           ┌──────────┴──────────┐
           │ Route Decision      │
           └──────────┬──────────┘
                      │
           ┌──────────┴──────────┐
           ▼                     ▼
     [ Input Hook ]       [ Forward Hook ]
           │                     │
           ▼                     ▼
     [ Local System ]     [ Postrouting Hook ]
```

---

### Ejecución Paso a Paso

#### Paso 1: Purgar Construcciones Heredadas Existentes y Crear el Ruleset Core Dual-Stack
Redactá un archivo `/etc/nftables.conf` sintácticamente válido que implemente un firewall de estado empresarial con limitación de tasa (rate-limiting), gestión dinámica de sets y defensa contra port knocking/fuerza bruta.

```bash
cat << 'EOF' > /etc/nftables.conf
#!/usr/sbin/nft -f

flush ruleset

table inet filter {
    # Dynamic set for auto-banned IP addresses (TTL based)
    set dynamic_blacklist {
        type ipv4_addr
        flags timeout
    }

    # Named counter for dropped packets
    counter dropped_tcp_scans {}
    counter dropped_invalid {}

    chain input {
        type filter hook input priority filter; policy drop;

        # 1. Allow traffic on loopback interface
        iif "lo" accept

        # 2. Drop invalid connection states
        ct state invalid counter name dropped_invalid drop

        # 3. State tracking: Allow established and related connections
        ct state { established, related } accept

        # 4. Drop traffic from dynamic blacklist set
        ip saddr @dynamic_blacklist drop

        # 5. ICMP & ICMPv6 Rate Limited Acceptance
        ip protocol icmp icmp type { echo-request, router-advertisement, time-exceeded, destination-unreachable } limit rate 10/second accept
        ip6 nexthdr ipv6-icmp icmpv6 type { echo-request, nd-neighbor-solicit, nd-neighbor-advert, nd-router-advert } limit rate 10/second accept

        # 6. SSH Protection: Rate limit connections (Max 4 connections per minute per source IP)
        tcp dport 22 ct state new meter ssh_meter { ip saddr limit rate 4/minute burst 2 packets } accept \
            add @dynamic_blacklist { ip saddr timeout 1h } counter drop

        # 7. HTTPS / HTTP Public Services
        tcp dport { 80, 443 } accept

        # Log and drop everything else
        log prefix "NFT_INPUT_REJECT: " flags all counter drop
    }

    chain forward {
        type filter hook forward priority filter; policy drop;
    }

    chain output {
        type filter hook output priority filter; policy accept;
    }
}
EOF
```

#### Paso 2: Validar Sintaxis y Aplicar el Ruleset Atómico
Cargá la configuración en el kernel. `nftables` procesa el archivo de forma atómica; si existe algún error de sintaxis, no se aplica ningún cambio al estado del kernel en ejecución.

```bash
nft -c -f /etc/nftables.conf && nft -f /etc/nftables.conf
```

Verificá el ruleset en ejecución y las tablas activas:

```bash
nft list ruleset
```

**Expected Output:**
```text
table inet filter {
	set dynamic_blacklist {
		type ipv4_addr
		flags timeout
	}

	counter dropped_tcp_scans {
		packets 0 bytes 0
	}

	counter dropped_invalid {
		packets 0 bytes 0
	}

	chain input {
		type filter hook input priority filter; policy drop;
		iif "lo" accept
		ct state invalid counter name "dropped_invalid" drop
		ct state { established, related } accept
		ip saddr @dynamic_blacklist drop
		ip protocol icmp icmp type { echo-request, destination-unreachable, router-advertisement, time-exceeded } limit rate 10/second accept
		ip6 nexthdr ipv6-icmp icmpv6 type { destination-unreachable, packet-too-big, time-exceeded, echo-request, nd-router-advert, nd-neighbor-solicit, nd-neighbor-advert } limit rate 10/second accept
		tcp dport 22 ct state new meter ssh_meter { ip saddr limit rate 4/minute burst 2 packets } accept add @dynamic_blacklist { ip saddr timeout 1h } counter packets 0 bytes 0 drop
		tcp dport { 80, 443 } accept
		log prefix "NFT_INPUT_REJECT: " flags all counter packets 0 bytes 0 drop
	}

	chain forward {
		type filter hook forward priority filter; policy drop;
	}

	chain output {
		type filter hook output priority filter; policy accept;
	}
}
```

#### Paso 3: Inyección e Inspección Dinámica de Sets en Tiempo de Ejecución
Inyectá una IP maliciosa (`192.0.2.50`) en el set `dynamic_blacklist` en tiempo de ejecución con un tiempo de expiración (timeout) personalizado de 30 minutos sin recargar el archivo de configuración.

```bash
nft add element inet filter dynamic_blacklist { 192.0.2.50 timeout 30m }
nft list set inet filter dynamic_blacklist
```

**Expected Output:**
```text
table inet filter {
	set dynamic_blacklist {
		type ipv4_addr
		flags timeout
		elements = { 192.0.2.50 expires 29m58s }
	}
}
```

---

### Preguntas de Verificación del Ejercicio 2

1. **Pregunta 2.1:** ¿Qué ventajas distintas de rendimiento de memoria y CPU proporciona una estructura de diccionario/map de `nftables` sobre las cadenas legadas de `iptables` al enrutar tráfico a 5.000 microservicios backend distintos basados en puertos de destino entrantes?
2. **Pregunta 2.2:** En el fragmento de `nftables.conf` anterior, explicá el mecanismo interno de la expresión de seguimiento de estado `ct state { established, related } accept`. ¿En qué parte del modelo de memoria del kernel se almacena este estado de conexión y qué sucede cuando se alcanzan los límites de la tabla `nf_conntrack`?

---

## Ejercicio 3: Detección de Intrusiones en Red y Prevención Automatizada (Suricata y Fail2ban)

### Contexto Arquitectónico y Mecánica Interna
* **Suricata NIDS/NIPS Engine:** Funciona como una plataforma de inspección profunda de paquetes (DPI) multihilo. Procesa paquetes entrantes a través de sockets AF_PACKET o NFQUEUE utilizando modos de ejecución (el modo `workers` asigna hilos dedicados por núcleo de CPU para la captura de paquetes entrantes, decodificación, seguimiento de flujos e inspección de firmas).
* **Fail2ban Integration:** Analiza continuamente flujos de eventos estructurados (como `/var/log/suricata/eve.json` o `/var/log/auth.log`) mediante filtros de expresiones regulares. Cuando se alcanzan los umbrales de fallas dentro de una ventana determinada, invoca una `action` configurable (por ejemplo, ejecutando comandos `nft` para añadir las IP ofensoras directamente a los sets de netfilter).

---

### Ejecución Paso a Paso

#### Paso 1: Escribir Reglas de Detección NIDS Personalizadas para Suricata
Creá un archivo de reglas personalizado `/etc/suricata/rules/custom-threats.rules` que contenga reglas para detectar volcados de bases de datos no autorizados e intentos de ejecución de shellcode.

```bash
cat << 'EOF' > /etc/suricata/rules/custom-threats.rules
# Detect incoming SQL injection attempted command execution
alert tcp $EXTERNAL_NET any -> $HOME_NET 80 (msg:"EXPLOIT-NIDS Possible SQLi SELECT INTO OUTFILE"; flow:to_server,established; content:"SELECT"; nocase; content:"INTO"; distance:1; nocase; content:"OUTFILE"; distance:1; nocase; classtype:web-application-attack; sid:1000001; rev:1;)

# Detect raw SSH brute force attempts (High rate of TCP SYN without full auth)
alert tcp $EXTERNAL_NET any -> $HOME_NET 22 (msg:"SUSPICIOUS SSH Inbound Traffic High Volume"; flow:to_server; flags:S; threshold: type threshold, track by_src, count 20, seconds 10; classtype:attempted-recon; sid:1000002; rev:1;)
EOF
```

Validá la configuración de Suricata y la sintaxis de las reglas:

```bash
suricata -T -c /etc/suricata/suricata.yaml -S /etc/suricata/rules/custom-threats.rules
```

**Expected Output:**
```text
Notice: setup-analysis: Configuration provided is valid.
Info: rule-analysis: Successfully loaded 2 rules from file /etc/suricata/rules/custom-threats.rules
```

#### Paso 2: Configurar una Jail de Fail2ban Usando el Modo de Acción `nftables`
Configurá `/etc/fail2ban/jail.d/custom-sshd.conf` para monitorear fallas de autenticación SSH y actualizar automáticamente el set del firewall de `nftables`.

```bash
cat << 'EOF' > /etc/fail2ban/jail.d/custom-sshd.conf
[sshd]
enabled  = true
port     = ssh
protocol = tcp
filter   = sshd
logpath  = /var/log/auth.log
maxretry = 3
findtime = 600
bantime  = 86400
banaction = nftables-multiport
banaction_allports = nftables-allports
EOF
```

Reiniciá el servicio Fail2ban y verificá el estado operativo de la jail:

```bash
systemctl restart fail2ban
fail2ban-client status sshd
```

**Expected Output:**
```text
Status for the jail: sshd
|- Filter
|  |- Currently failed: 0
|  |- Total failed:     0
|  `- File list:        /var/log/auth.log
`- Actions
   |- Currently banned: 0
   |- Total banned:     0
   `- Banned IP list:   
```

#### Paso 3: Simular un Ataque y Verificar el Bloqueo Automatizado en Tiempo Real
Inyectá registros de prueba de fallas de SSH en `/var/log/auth.log` para activar el motor de ejecución automatizada de Fail2ban.

```bash
cat << 'EOF' >> /var/log/auth.log
2026-08-06T14:10:01.123456+00:00 server sshd[14201]: Failed password for invalid user hacker from 198.51.100.44 port 41234 ssh2
2026-08-06T14:10:03.234567+00:00 server sshd[14202]: Failed password for invalid user hacker from 198.51.100.44 port 41235 ssh2
2026-08-06T14:10:05.345678+00:00 server sshd[14203]: Failed password for invalid user hacker from 198.51.100.44 port 41236 ssh2
EOF
```

Consultá el estado de `fail2ban-client` para confirmar el bloqueo de la IP:

```bash
fail2ban-client status sshd
```

**Expected Output:**
```text
Status for the jail: sshd
|- Filter
|  |- Currently failed: 0
|  |- Total failed:     3
|  `- File list:        /var/log/auth.log
`- Actions
   |- Currently banned: 1
   |- Total banned:     1
   `- Banned IP list:   198.51.100.44
```

Verificá las reglas de descartar (drop) activas en el kernel agregadas por Fail2ban:

```bash
nft list chain inet fail2ban f2b-sshd
```

---

### Preguntas de Verificación del Ejercicio 3

1. **Pregunta 3.1:** ¿Cuál es la diferencia técnica entre Suricata ejecutándose en **modo IDS** a través de `AF_PACKET` (copiando paquetes desde sockets raw) versus **modo IPS** usando Linux `NFQUEUE`? ¿Qué compensaciones (trade-offs) arquitectónicas existen con respecto a la latencia de red y la capacidad de descarte de paquetes?
2. **Pregunta 3.2:** En un sistema de producción de alto tráfico ejecutando Suricata, se producen descartes de paquetes a nivel de ring-buffer antes de la inspección. ¿Qué configuraciones de sysctl y ring de la NIC deben ajustarse para eliminar los descartes en el ring-buffer?

---

## Ejercicio 4: Arquitectura de Infraestructura VPN Empresarial (WireGuard e IPsec strongSwan)

### Contexto Arquitectónico y Mecánica Interna
* **WireGuard Cryptokey Routing:** WireGuard elimina las complejas máquinas de estado de las VPN tradicionales asociando claves públicas criptográficas estáticas directamente con direcciones IP autorizadas del túnel (`AllowedIPs`).
  * Paquetes entrantes: Desencriptar, verificar la firma Curve25519, hacer coincidir la IP de origen interna con los `AllowedIPs` de la clave. Descartar si no coinciden.
  * Paquetes salientes: Buscar la IP de destino en la tabla de enrutamiento `AllowedIPs`, seleccionar la clave pública correspondiente, encriptar mediante ChaCha20-Poly1305 y transmitir sobre UDP.
* **IPsec strongSwan (IKEv2):** Utiliza dos fases:
  * **IKE_SA (Fase 1):** Autentica pares utilizando certificados X.509 o claves compartidas previamente (PSK), estableciendo un canal de control encriptado a través de Diffie-Hellman (ECDH).
  * **CHILD_SA (Fase 2):** Negocia Asociaciones de Seguridad (SA) operativas para ESP (Encapsulating Security Payload, protocolo 50) para encriptar el tráfico de payload IPv4/IPv6.

```
WireGuard Cryptokey Routing Table:
┌───────────────────────────────┬───────────────────────┬───────────────────────────┐
│ Remote Peer Public Key        │ Endpoint IP:Port      │ Allowed IPs (Routing)     │
├───────────────────────────────┼───────────────────────┼───────────────────────────┤
│ xTR8+...vK90= (Server/Hub)    │ 203.0.113.10:51820    │ 10.200.0.0/24, 0.0.0.0/0  │
│ 8mK2...pP11= (Branch Office)  │ 198.51.100.5:51820    │ 10.200.0.2/32             │
└───────────────────────────────┴───────────────────────┴───────────────────────────┘
```

---

### Ejecución Paso a Paso

#### Paso 1: Desplegar la Interfaz de Túnel WireGuard Secure Hub
Generá pares de claves criptográficas del servidor utilizando `wg genkey`:

```bash
mkdir -p /etc/wireguard
chmod 700 /etc/wireguard
wg genkey | tee /etc/wireguard/server_private.key | wg pubkey > /etc/wireguard/server_public.key
```

Creá el archivo de configuración `/etc/wireguard/wg0.conf`:

```bash
cat << EOF > /etc/wireguard/wg0.conf
[Interface]
Address = 10.200.0.1/24
SaveConfig = false
ListenPort = 51820
PrivateKey = $(cat /etc/wireguard/server_private.key)

# Automated NAT rules for routed VPN traffic
PostUp = nft add table inet wg_nat; nft add chain inet wg_nat postrouting { type nat hook postrouting priority srcnat\; }; nft add rule inet wg_nat postrouting oifname "eth0" masquerade
PostDown = nft delete table inet wg_nat

# Branch Office 1 Peer
[Peer]
PublicKey = 4mK2pP11xTR8+vK90mK2pP11xTR8+vK90mK2pP11xTR=
AllowedIPs = 10.200.0.2/32
EOF

chmod 600 /etc/wireguard/wg0.conf
```

Levantá la interfaz del túnel:

```bash
wg-quick up wg0
```

Verificá el estado del túnel en ejecución y los parámetros de la interfaz del kernel:

```bash
wg show wg0
```

**Expected Output:**
```text
interface: wg0
  public key: /sK8vX21Z...kR9pM0=
  private key: (hidden)
  listening port: 51820

peer: 4mK2pP11xTR8+vK90mK2pP11xTR8+vK90mK2pP11xTR=
  allowed ips: 10.200.0.2/32
```

#### Paso 2: Aprovisionar la Configuración IPsec Site-to-Site para Producción Usando strongSwan VICI/swanctl
Redactá `/etc/swanctl/swanctl.conf` para un túnel IKEv2 estricto AES-GCM-256 / ECP384 entre el Datacenter A (`203.0.113.1`) y el Datacenter B (`198.51.100.1`).

```bash
cat << 'EOF' > /etc/swanctl/swanctl.conf
connections {
    datacenter-to-datacenter {
        local_addrs  = 203.0.113.1
        remote_addrs = 198.51.100.1
        version = 2
        proposals = aes256gcm16-prfsha384-ecp384

        local {
            auth = psk
            id = dc1.example.com
        }
        remote {
            auth = psk
            id = dc2.example.com
        }

        children {
            net-to-net {
                local_ts  = 10.10.0.0/16
                remote_ts = 10.20.0.0/16
                esp_proposals = aes256gcm16-ecp384
                dpd_action = restart
                start_action = trap
            }
        }
    }
}

secrets {
    ike-1 {
        id-1 = dc1.example.com
        id-2 = dc2.example.com
        secret = "c9f8a7b6e5d4c3b2a10f9e8d7c6b5a43210fedcba987654321"
    }
}
EOF
```

Cargá la configuración en el demonio de strongSwan:

```bash
swanctl --load-all
```

**Expected Output:**
```text
successfully loaded 1 connections
successfully loaded 0 sas
successfully loaded 1 secrets
```

Iniciá el túnel IPsec manualmente e inspeccioná las SA activas:

```bash
swanctl --initiate --child net-to-net
swanctl --list-sas
```

**Expected Output:**
```text
net-to-net: #1, ESTABLISHED, IKEv2, 6f9a8b7c6d5e4f3a_i 1a2b3c4d5e6f7a8b_r*
  local  'dc1.example.com' at 203.0.113.1[500]
  remote 'dc2.example.com' at 198.51.100.1[500]
  AES_GCM_16-256/PRF_HMAC_SHA2_384/ECP_384
  active SAs: CHILD_SA #1
    net-to-net: #1, REKEYING, TUNNEL, ESP:AES_GCM_16-256
      local  10.10.0.0/16
      remote 10.20.0.0/16
```

---

### Preguntas de Verificación del Ejercicio 4

1. **Pregunta 4.1:** ¿Cómo maneja WireGuard el roaming de IP de endpoint (por ejemplo, cuando un par móvil cambia de dirección IP de Wi-Fi a LTE) sin romper el estado del túnel, y cómo contrasta esto con los requisitos de reclaveado (re-keying) de la Asociación de Seguridad en IPsec?
2. **Pregunta 4.2:** Explicá la diferencia operativa entre el **modo transporte (Transport Mode)** y el **modo túnel (Tunnel Mode)** de IPsec. ¿Qué cabeceras de payload se encriptan en cada uno y por qué el modo túnel es requerido para la interconexión de subredes sitio a sitio (site-to-site)?

---

<details>
<summary><strong>Respuestas de Comprensión de los Ejercicios y Explicaciones Detalladas</strong></summary>

### Respuestas del Ejercicio 1

* **Respuesta 1.1:** Reverse Path Filtering (`rp_filter = 1`) realiza una validación estricta: para cualquier paquete entrante en la interfaz $X$, el kernel consulta la tabla de enrutamiento para la dirección IP de origen. Si la ruta de salida óptima de regreso a esa IP de origen apunta a una interfaz *diferente* de $X$, el paquete se descarta como un intento de spoofing. En entornos de enrutamiento asimétrico, los paquetes de salida salen a través de `eth0` mientras que el tráfico de entrada de retorno llega a `eth1`. Bajo el modo estricto (`1`), cuando un paquete proveniente de `192.0.2.10` llega a `eth1`, el kernel consulta su tabla de enrutamiento, ve que el tráfico hacia `192.0.2.10` se enruta hacia afuera a través de `eth0`, nota que `eth0 != eth1` y descarta el paquete. El modo laxo (`2`, definido en la RFC 3704) solo verifica que la dirección IP de origen sea alcanzable a través de *cualquier* interfaz activa en la tabla de enrutamiento, permitiendo que pasen los paquetes asimétricos mientras sigue descartando fuentes IP completamente no enrutables (marcianas/spoofeadas).
* **Respuesta 1.2:** Bajo condiciones normales de funcionamiento, el kernel de Linux asigna un búfer en la cola de backlog TCP SYN y responde con un número de secuencia inicial ($ISN$) aleatorio estándar. Cuando la cola de backlog se llena por completo (por ejemplo, durante un ataque de SYN flood), se activa `net.ipv4.tcp_syncookies = 1`. En lugar de asignar memoria para el seguimiento de estado, el kernel construye un $ISN$ de SYN cookie que contiene un hash criptográfico de 32 bits derivado de la 5-tupla, una clave secreta, un índice MSS de 5 bits y un contador de marcas de tiempo. Cuando el cliente envía el ACK final, el kernel decrementa el número de secuencia ACK en 1, vuelve a calcular el hash criptográfico y verifica la autenticidad sin haber guardado estado previo. **Compensación/Sacrificio:** Debido a que el estado no se guarda en memoria, las capacidades TCP avanzadas negociadas durante el paquete SYN inicial —específicamente **TCP Window Scaling** (RFC 1323) y **Selective Acknowledgments (SACK)**— se deshabilitan a menos que estén codificadas en opciones explícitas de marcas de tiempo de TCP (RFC 7323).

---

### Respuestas del Ejercicio 2

* **Respuesta 2.1:** El legado `iptables` evalúa las reglas linealmente (profundidad de $O(N)$). Coincidir 5.000 puertos distintos requiere recorrer hasta 5.000 entradas de reglas independientes por paquete, consumiendo ciclos sustanciales de CPU e induciendo latencia en los paquetes. `nftables` implementa de forma nativa sets y diccionarios con nombre respaldados por **árboles radix y tablas hash** (búsquedas en tiempo constante $O(1)$). En lugar de ejecutar 5.000 instrucciones de comparación lineal, `nftables` realiza una sola búsqueda en tabla hash sobre la tupla del puerto de destino mapeando directamente a la cadena o acción objetivo, manteniendo la latencia constante independientemente de la cantidad de reglas.
* **Respuesta 2.2:** La expresión `ct state { established, related } accept` interactúa directamente con el subsistema del kernel de Linux netfilter `nf_conntrack`. El seguimiento de conexiones mantiene una tabla hash en la memoria del kernel (`/proc/net/nf_conntrack`) rastreando las 5-tuplas (`src_ip`, `src_port`, `dst_ip`, `dst_port`, `protocol`) y las transiciones de estado del protocolo.
  * `established`: Paquetes que pertenecen a una sesión TCP/UDP válida y observada bidireccionalmente.
  * `related`: Paquetes que inician una nueva conexión pero que están asociados con una sesión existente (por ejemplo, canales de datos FTP o mensajes de error ICMP).
  Si el volumen de tráfico excede `net.netfilter.nf_conntrack_max`, la tabla de seguimiento de conexiones agota las asignaciones de memoria. Cuando se llena, el kernel emite errores `nf_conntrack: table full, dropping packet` y **descarta todas las nuevas conexiones entrantes no establecidas**, lo que lleva a una Denegación de Servicio completa incluso si hay CPU y ancho de banda disponibles.

---

### Respuestas del Ejercicio 3

* **Respuesta 3.1:** 
  * **Modo IDS (`AF_PACKET`):** Suricata abre búferes circulares (ring-buffers) de sockets de paquetes raw. La tarjeta de interfaz de red (NIC) copia los paquetes entrantes tanto a la pila de protocolos del host como a Suricata simultáneamente. La inspección ocurre fuera de banda (asincrónicamente). **Pros:** Cero impacto en el rendimiento (throughput) o latencia de la red; si Suricata falla (crash), el flujo de red no se ve afectado. **Contras:** No puede bloquear ni descartar paquetes maliciosos en tránsito (solo puede generar registros de alerta o enviar paquetes TCP RST de forma retroactiva).
  * **Modo IPS (`NFQUEUE`):** El firewall `nftables` o `iptables` dirige los paquetes a un número de cola explícito manejado por Suricata mediante vinculaciones del espacio de usuario de netfilter (`NFQUEUE`). Los paquetes se pausan en la memoria del kernel hasta que Suricata los inspecciona y devuelve un veredicto explícito (`NF_ACCEPT` o `NF_DROP`). **Pros:** Prevención de intrusiones verdaderamente en línea (inline); los payloads maliciosos se bloquean antes de llegar a los sockets del host. **Contras:** Introduce latencia por paquete; si las colas de hilos de Suricata se saturan o el proceso muere sin reglas de respaldo (fallback), el tráfico de red legítimo se bloquea o sufre retrasos severos.
* **Respuesta 3.2:** Para resolver los descartes de paquetes en el ring-buffer bajo tráfico pesado:
  1. Aumentar los descriptores del ring-buffer físico de la NIC mediante `ethtool -G eth0 rx 4096 tx 4096`.
  2. Escalar los límites de memoria de recepción del socket en el sysctl del kernel: `net.core.rmem_max = 67108864` y `net.core.rmem_default = 33554432`.
  3. Habilitar la dimensión del ring-buffer en `af-packet` en `suricata.yaml` (`buffer-size: 65535`, `use-mmap: yes`, `tpacket-v3: yes`).
  4. Vincular las solicitudes de interrupción de la NIC (IRQs) a través de núcleos de CPU dedicados utilizando `irqbalance` o afinidad de CPU manual (`/proc/irq/X/smp_affinity`) para coincidir con la fijación de hilos (thread pinning) de `workers` de Suricata.

---

### Respuestas del Ejercicio 4

* **Respuesta 4.1:** WireGuard implementa el roaming de endpoints de forma nativa a través de su mecanismo **Cryptokey Routing**. Cuando un par remoto se desplaza de Wi-Fi (`192.168.1.50`) a una red LTE (`203.0.113.88`), envía un paquete UDP autenticado y encriptado con ChaCha20-Poly1305 al servidor WireGuard. Al recibir el paquete, el servidor desencripta y verifica el mensaje utilizando la clave pública estática del par. Una vez autenticado, WireGuard actualiza automáticamente su tabla de enrutamiento interna dinámica, actualizando la dirección del endpoint del par a `203.0.113.88:port` sobre la marcha. No se requiere renegociación, desmantelamiento de sesión ni nuevo handshake. En contraste, el estándar IPsec IKEv2 se basa en vinculaciones IP estáticas de la Asociación de Seguridad; el roaming requiere extensiones MOBIKE complejas (RFC 4555) o fases completas de reautenticación y reclaveado (re-keying) de IKE_SA para reconstruir el túnel encriptado.
* **Respuesta 4.2:** 
  * **Modo Transporte (Transport Mode):** Encripta únicamente el payload IP (por ejemplo, la cabecera TCP/UDP + datos de aplicación). La cabecera IP original permanece sin encriptar y visible.
    $$\text{[ Original IP Header ]} + \text{[ ESP Header ]} + \text{\{ Encrypted TCP Payload \}} + \text{[ ESP Trailer/Auth ]}$$
    *Uso:* Comunicación directa nodo a nodo (Host-to-Host) donde ambos endpoints poseen direcciones IP públicas.
  * **Modo Túnel (Tunnel Mode):** Encripta el **paquete IP original completo** (cabecera IP original interna + payload) y lo encapsula dentro de una cabecera IP externa completamente nueva.
    $$\text{[ Outer IP Header (Gateway-to-Gateway) ]} + \text{[ ESP Header ]} + \text{\{ Encrypted Inner IP Header + Payload \}} + \text{[ ESP Trailer/Auth ]}$$
    *Uso:* Interconexión de subredes sitio a sitio (Site-to-Site) (por ejemplo, conectando `10.10.0.0/16` detrás del Gateway A con `10.20.0.0/16` detrás del Gateway B). El modo túnel es estrictamente requerido porque el espacio IP interno privado (`10.x.x.x`) no se puede enrutar directamente a través de redes de tránsito públicas sin encapsulamiento.

</details>