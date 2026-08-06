# LPIC-3 Examen 303-300 (v3.0) — Tema 5.1: Seguridad de Red
**Nivel:** Producción Avanzada / Referencia para Senior Platform Architect & SRE  
**Peso del examen:** 16.67 (equivalente al Tema 334)

---

## 1. Motivación arquitectónica en producción y planteamiento del problema

La infraestructura empresarial moderna se enfrenta a desafíos de seguridad complejos: perímetros de alto rendimiento, nubes híbridas multi-tenant, arquitecturas de red zero-trust (ZTNA) y riesgos de movimiento lateral. Los modelos de seguridad tradicionales centrados únicamente en el perímetro (firewall en el perímetro, red interna de confianza) fallan cuando las cargas de trabajo (workloads) se distribuyen entre bare-metal on-premises, hipervisores virtualizados y clusters de Kubernetes multirregión.

```
       +-----------------------------------------------------------------------------------+
       |                                   INGRESS EDGE                                    |
       |  [Internet] ---> [eBPF/XDP DDoS Filter] ---> [nftables Stateful Edge Firewall]  |
       +-----------------------------------------+-----------------------------------------+
                                                 |
                                                 v
       +-----------------------------------------------------------------------------------+
       |                            ENTERPRISE CORE INFRASTRUCTURE                         |
       |                                                                                   |
       |  +---------------------------+                +--------------------------------+  |
       |  |  802.1X Network Access    |                |  Intrusion Detection/Prevention|  |
       |  |  Control (FreeRADIUS/EAP) |                |  (Snort 3 Multi-threaded NIDS) |  |
       |  +-------------+-------------+                +---------------+----------------+  |
       |                |                                              |                   |
       |                v                                              v                   |
       |  +---------------------------+                +--------------------------------+  |
       |  |  Network Packet Analysis  |                |  Vulnerability Assessment      |  |
       |  |  (tcpdump / tshark / BPF) |                |  (Greenbone GVM / OpenVAS NASL)|  |
       |  +---------------------------+                +--------------------------------+  |
       +-----------------------------------------+-----------------------------------------+
                                                 |
                                                 v
       +-----------------------------------------------------------------------------------+
       |                       CLOUD-NATIVE / KUBERNETES DATA PLANE                        |
       |  [Cilium eBPF / L3-L7 NetworkPolicies] <---> [Microsegmentation & mTLS Enforcer] |
       +-----------------------------------------------------------------------------------+
```

### La arquitectura del plano de datos del kernel de Linux

Cuando un paquete IP llega a una NIC Linux, atraviesa varios subsistemas del kernel:

```
[Physical NIC] ---> [Driver NAPI RX] ---> [eBPF / XDP Hook] ---> [tc (traffic control)]
                                                                         |
                                                                         v
[ip_forward] <--- [nftables / netfilter] <--- [ip_rcv] <--- [dev_gro_receive / sk_buff]
     |                                                                   |
     v                                                                   v
[eGPU/NIC TX]                                                   [Socket Layer (L7 Application)]
```

1. **XDP (eXtensible Data Path):** Ejecuta bytecode de eBPF directamente dentro del contexto del driver de la NIC antes de asignar un buffer de socket del kernel (`sk_buff`). Ideal para la mitigación de DDoS a velocidad de línea ($>100\text{M pps}$).
2. **Netfilter / nftables:** Evalúa hooks (`prerouting`, `input`, `forward`, `output`, `postrouting`). Mecanismo estándar de filtrado de paquetes con estado (stateful) que utiliza el seguimiento de conexiones (`conntrack`).
3. **Capa Socket:** Entrega la carga útil (payload) a procesos en espacio de usuario (por ejemplo, FreeRADIUS, Snort, el escáner OpenVAS).

### Compromisos arquitectónicos y modos de fallo
- **Saturación de conntrack:** Los floods SYN elevados pueden agotar la tabla `nf_conntrack` de Netfilter (`net.netfilter.nf_conntrack_max`), descartando conexiones legítimas antes de que se ejecuten las reglas del firewall.
- **Cuellos de botella en Deep Packet Inspection (DPI):** Pasar tráfico de alto ancho de banda a través de motores NIDS en espacio de usuario (Snort/Suricata) causa saturación de `softirq` en la CPU y paquetes descartados a menos que se configuren ring buffers (`AF_PACKET` `TPACKET_V3`) o descarga por hardware (PF_RING/DPDK).
- **Servicios de infraestructura L2 no autorizados (Rogue):** Switches o hipervisores no autenticados pueden ser comprometidos a través de servidores DHCP no autorizados (Rogue DHCP) o anuncios de router IPv6 no autorizados (Rogue IPv6 Router Advertisements / RAs), subvirtiendo las tablas de enrutamiento por defecto y permitiendo la inspección Man-In-The-Middle (MITM).

---

## 2. Comparativas técnicas y tablas de compromisos arquitectónicos

### Tabla 2.1: Filtrado de paquetes y mecanismos de plano de datos

| Característica / Métrica | `iptables` (Legacy) | `nftables` (Estándar moderno) | `eBPF / XDP` (Plano de datos de alto rendimiento) |
| :--- | :--- | :--- | :--- |
| **Subsistema del kernel** | Hooks de Netfilter (tablas independientes por familia: ip, ip6, arp, eb) | Motor de VM de Netfilter único y unificado (evalúa bytecode) | Runtime de eBPF en el driver de red (`XDP`) o hook `tc` |
| **Contexto de ejecución** | Procesamiento secuencial de reglas por hook (`sk_buff` asignado) | AST compilado a bytecode interno de VM (`sk_buff` asignado) | Inspección directa del buffer DMA *antes* de la asignación de memoria `sk_buff` |
| **Rendimiento (100GbE)** | Bajo ($< 5\text{M pps}$ por núcleo bajo conjuntos de reglas pesados) | Moderado ($10\text{M}-20\text{M pps}$ utilizando conjuntos y mapas) | Extremo ($> 100\text{M pps}$ tasa de descarte por hardware) |
| **Seguimiento con estado (Stateful)** | Módulo `xt_conntrack` | Expresiones de estado `ct` nativas | Requiere mapas de eBPF personalizados (`BPF_MAP_TYPE_LRU_HASH`) |
| **Actualizaciones atómicas** | No atómicas (reemplazo completo de la tabla mediante `iptables-restore`) | Actualizaciones de reglas atómicas nativas mediante una API de transacción única | Actualizaciones de mapas atómicas y reemplazo del programa eBPF en vivo mediante `bpf_prog_attach` |
| **Inspección L7** | Limitada (coincidencia de cadenas, frágil) | Coincidencia por offset del payload | eBPF + sockmap / Uretprobes (requiere lógica helper compleja) |

### Tabla 2.2: Motores de detección y prevención de intrusiones (NIDS / NIPS)

| Métrica | Snort 3 | Suricata | Zeek (anteriormente Bro) |
| :--- | :--- | :--- | :--- |
| **Arquitectura** | Proceso único, multihilo (configuración `snort.lua`) | Multihilo nativo (modelos de hilos pipeline / auto-fp) | Núcleo monohilo orientado a eventos con modo cluster multiproceso |
| **Método de detección** | Motor de reglas basado en firmas + plugins de inspección | Basado en firmas + PCRE2 + scripting en Lua | Motor de registro de protocolos y análisis de comportamiento mediante scripts |
| **Adquisición de paquetes** | `DAQ` (Data Acquisition Library: pcap, afpacket, dump, dpdk) | `AF_PACKET`, `PF_RING`, `NFQ`, `DPDK` | `libpcap`, `AF_PACKET`, `Myricom`, `PF_RING` |
| **Extracción de archivos** | Inspección de archivos y hashing nativo para MIME / HTTP / SMB | Extracción de archivos nativa + integración con motor YARA | Motor de extracción de archivos y hashing nativo impulsado por scripts |
| **Descarga por hardware (Hardware Offload)** | Motor de regex Hyperscan (aceleración SIMD por CPU) | Regex Hyperscan + soporte para descarga por GPU | Soporte Hyperscan a través de plugins |

### Tabla 2.3: Control de acceso a la red (NAC) y paradigmas de autenticación

| Dimensión | 802.1X / FreeRADIUS (EAP-TLS) | WireGuard / IPsec SASE | Service Mesh mTLS (SPIFFE/SPIRE) |
| :--- | :--- | :--- | :--- |
| **Capa OSI** | Capa 2 (Enlace de datos - Autenticación basada en puerto) | Capa 3 (Superposición de red / Tunelización) | Capa 7 (Transporte de aplicación - Proxy TLS) |
| **Ancla de identidad** | Certificado de cliente de dispositivo/usuario X.509 | Par de claves estáticas del protocolo Noise | Certificado X.509 SVID de corta duración |
| **Dominio principal** | LAN de campus, Wi-Fi empresarial, Top-of-Rack de centro de datos | Acceso remoto, túneles sitio a sitio en WAN | Tráfico este-oeste de microservicio a microservicio |
| **Punto de aplicación (Enforcement Point)** | Puerto de switch administrado / Punto de acceso inalámbrico | Interfaz de red del kernel (`wg0`, `ipsec0`) | Envoy / Sidecar Proxy / bypass del kernel para sockets eBPF |

---

## 3. Infraestructura de producción y configuraciones de manifiestos

### Listado 3.1: Firewall perimetral dual-stack `nftables.conf` en producción
`/etc/nftables.conf`

```nftables
#!/usr/sbin/nft -f

# Flush existing ruleset
flush ruleset

# Define network interface variables
define WAN_IF = "eth0"
define LAN_IF = "eth1"
define MANAGEMENT_NETS = { 10.100.0.0/24, 192.168.50.0/24 }
define RADIUS_SERVERS = { 10.100.0.10, 10.100.0.11 }

table inet filter {
    # Dynamic set for auto-banned IP addresses (DDoS / Brute-force)
    set dynamic_blacklist {
        type ipv4_addr
        flags timeout
    }

    # Flowtable for hardware/software fast-path offloading
    flowtable fastpath {
        hook ingress priority 0
        devices = { $WAN_IF, $LAN_IF }
    }

    chain input {
        type filter hook input priority filter; policy drop;

        # Drop invalid connections immediately
        ct state invalid drop comment "Drop invalid conntrack states"

        # Drop packets from dynamic blacklist
        ip saddr @dynamic_blacklist drop comment "Drop blacklisted IPs"

        # Allow loopback traffic
        iifname "lo" accept comment "Allow loopback"

        # Allow established and related connections
        ct state { established, related } accept comment "Allow tracked connections"

        # Rate limit ICMP / ICMPv6 to prevent ping floods
        ip protocol icmp icmp type echo-request limit rate 10/second accept
        ip6 nexthdr icmpv6 icmpv6 type { destination-unreachable, packet-too-big, time-exceeded, parameter-problem, echo-request, nd-router-advert, nd-neighbor-solicit, nd-neighbor-advert } limit rate 20/second accept

        # Protect against TCP SYN Floods (add to blacklist if >50 conn/sec)
        tcp flags syn tcp dport { 80, 443, 22 } meter syn_limit { ip saddr limit rate over 50/second } add @dynamic_blacklist { ip saddr timeout 1h } drop

        # Allow SSH only from authorized management subnets with rate limiting
        ip saddr $MANAGEMENT_NETS tcp dport 22 ct state new limit rate 5/minute accept comment "Management SSH"

        # Allow RADIUS Authentication & Accounting from authorized NAS devices
        ip saddr $MANAGEMENT_NETS udp dport { 1812, 1813 } accept comment "RADIUS Authentication/Accounting"

        # Log and drop everything else
        log prefix "NFT_INPUT_DROP: " flags all counter drop
    }

    chain forward {
        type filter hook forward priority filter; policy drop;

        # Fastpath offload for established streams
        ip protocol { tcp, udp } flow offload @fastpath

        # Allow LAN to WAN egress forwarding
        iifname $LAN_IF oifname $WAN_IF accept comment "LAN Egress"
        iifname $WAN_IF oifname $LAN_IF ct state { established, related } accept comment "WAN Ingress Return"
    }

    chain output {
        type filter hook output priority filter; policy accept;
    }
}
```

---

### Listado 3.2: Configuración completa multihilo de Snort 3
`/etc/snort/snort.lua`

```lua
-- Snort 3 Production Configuration
HOME_NET = '10.100.0.0/16'
EXTERNAL_NET = '!$HOME_NET'

-- Define paths
RULE_PATH = '/etc/snort/rules'
BUILTIN_RULE_PATH = '/etc/snort/builtin_rules'
PLUGIN_INPUT_PATH = '/usr/local/lib/snort_extra'

-- System configurations
process =
{
    chroot = '/var/log/snort',
    set_gid = 'snort',
    set_uid = 'snort',
    daemon = false,
}

thread_config =
{
    max_threads = 8,
}

-- High-performance Packet Acquisition (DAQ) via AF_PACKET
daq =
{
    module = 'afpacket',
    mode = 'inline',
    variables =
    {
        'buffer_size_mb=1024',
    }
}

-- Network Inspection Modules
stream = { }
stream_tcp =
{
    max_window = 65535,
    overlap_limit = 10,
    session_timeout = 30,
    policy = 'linux'
}

stream_udp =
{
    session_timeout = 30
}

-- Hyperscan Regex Engine Setup
search_engine =
{
    search_method = 'hyperscan',
    split_any = true
}

-- Active response configuration for NIPS mode
active =
{
    attempts = 5,
    device = 'eth0'
}

-- Alert outputs
alert_fast =
{
    file = true,
    limit = 100,
}

alert_json =
{
    file = true,
    limit = 500,
    fields = 'timestamp pkt_num proto src_addr src_port dst_addr dst_port action msg rule'
}

-- Rules configuration
ips =
{
    enable_builtin_rules = true,
    include = RULE_PATH .. '/local.rules'
}
```

#### Archivo de reglas personalizadas asociado: `/etc/snort/rules/local.rules`
```snort
# Rule 1: Detect Rogue RA (Router Advertisements) - ICMPv6 Type 134
drop icmp6 external_net any -> $HOME_NET any (msg:"NIDS ALERT: Rogue IPv6 Router Advertisement Detected"; ip6_hdrs:type 134; classtype:bad-traffic; sid:1000001; rev:1;)

# Rule 2: Detect Unauthorized RADIUS Access Attempt
alert udp external_net any -> $HOME_NET 1812 (msg:"NIDS ALERT: External RADIUS Authentication Attempt"; content:"|01|", depth 1; offset 0; classtype:unauthorized-login; sid:1000002; rev:1;)

# Rule 3: Detect TCP SYN Flood targeting internal microservices
drop tcp external_net any -> $HOME_NET 443 (msg:"NIPS ACTION: TCP SYN Flood Protection"; flags:S; threshold: type threshold, track by_src, count 100, seconds 1; classtype:attempted-dos; sid:1000003; rev:1;)
```

---

### Listado 3.3: Configuración del servidor 802.1X EAP-TLS FreeRADIUS 3.x para empresas

#### Configuración principal del servidor: `/etc/freeradius/3.0/radiusd.conf`
```radius
prefix = /usr
exec_prefix = ${prefix}
sysconfdir = /etc
localstatedir = /var
sbindir = ${exec_prefix}/sbin
logdir = ${localstatedir}/log/freeradius
raddbdir = ${sysconfdir}/freeradius/3.0
radacctdir = ${logdir}/radacct

name = radiusd

confdir = ${raddbdir}
modconfdir = ${confdir}/mods-config
certdir = ${confdir}/certs
cadir   = ${confdir}/certs

libdir = /usr/lib/freeradius

pidfile = ${localstatedir}/run/radiusd/radiusd.pid

correct_escapes = true
max_request_time = 30
cleanup_delay = 5
max_requests = 16384

log {
    destination = files
    colourise = yes
    file = ${logdir}/radius.log
    syslog_facility = daemon
    stripped_names = no
    auth = yes
    auth_badpass = yes
    auth_goodpass = no
}

checkrad = ${sbindir}/checkrad

security {
    user = radius
    group = radius
    allow_core_dumps = no
    max_attributes = 200
    reject_delay = 1
    status_server = yes
}

proxy_requests = no

$INCLUDE clients.conf
$INCLUDE modules/
$INCLUDE sites-enabled/
```

#### Configuración de clientes: `/etc/freeradius/3.0/clients.conf`
```radius
client enterprise_switches {
    ipaddr = 10.100.0.0/24
    secret = SharedSuperSecretKey2026!
    shortname = core-switches
    nas_type = cisco
}

client wireless_controllers {
    ipaddr = 10.100.5.10
    secret = SharedWlcSecretKey2026!
    shortname = enterprise-wlc
}
```

#### Configuración del módulo EAP: `/etc/freeradius/3.0/mods-available/eap`
```radius
eap {
    default_eap_type = tls
    timer_expire = 60
    ignore_unknown_eap_types = no
    cisco_accounting_username = no
    max_sessions = ${max_requests}

    tls-config tls-common {
        private_key_password = CertificatePassword2026
        private_key_file = ${certdir}/server.key
        certificate_file = ${certdir}/server.pem
        ca_file = ${cadir}/ca.pem
        dh_file = ${certdir}/dh
        cipher_list = "ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384"
        cipher_server_preference = yes
        ecdh_curve = "prime256v1"

        tls_min_version = "1.2"
        tls_max_version = "1.3"

        check_crl = yes
        crl_file = ${certdir}/crl.pem

        check_cert_cn = yes
    }

    tls {
        tls = tls-common
        make_cert_command = "${certdir}/bootstrap"
    }
}
```

---

### Listado 3.4: Script NASL personalizado completo para OpenVAS / Greenbone
`/var/lib/openvas/plugins/custom_tls_check.nasl`

```nasl
# Complete OpenVAS NASL Script for TLS Configuration Enforcement
if(description)
{
    script_oid("1.3.6.1.4.1.99999.1.1");
    script_version("1.0");
    script_tag(name:"last_modification", value:"2026-08-06 00:00:00 +0000");
    script_tag(name:"creation_date", value:"2026-08-06 00:00:00 +0000");
    script_tag(name:"cvss_base", value:"7.5");
    script_tag(name:"cvss_base_vector", value:"AV:N/AC:L/Au:N/C:P/I:P/A:N");
    script_name(English:"Custom Corporate Audit: Weak TLS Version Enforcement");
    script_category(ACT_GATHER_INFO);
    script_family("General");
    script_copyright(English:"Production SRE Security Team");
    script_dependencies("find_service.nasl", "ssl_supported_versions.nasl");
    script_require_ports("Services/www", 443, 8443, 1812);

    script_tag(name:"summary", value:"Checks if target endpoints enforce minimum TLS 1.2/1.3 standards.");
    script_tag(name:"solution", value:"Disable TLS 1.0, TLS 1.1, and SSLv3 in the service configuration file.");
    script_tag(name:"qod_type", value:"remote_app");

    exit(0);
}

include("ssl_funcs.inc");
include("misc_func.inc");

port = get_kb_item("Services/www");
if(!port) port = 443;

if(!get_port_state(port)) exit(0);

soc = open_sock_tcp(port);
if(!soc) exit(0);

# Attempt TLS 1.0 Handshake (Deprecated)
ssl_version = SSL_v3;
hello = ssl_hello(version:ssl_version);
send(socket:soc, data:hello);
res = recv_ssl(socket:soc);
close(soc);

if(!isnull(res) && ssl_verify_server_hello(data:res))
{
    security_message(
        port: port,
        data: "SECURITY VIOLATION: The remote service accepts deprecated TLS 1.0 / SSLv3 connections."
    );
    exit(0);
}

exit(0);
```

---

### Listado 3.5: NetworkPolicy de Kubernetes nativa de la nube (aplicación Cilium L3/L4/L7)
`cilium-network-policy.yaml`

```yaml
apiVersion: "cilium.io/2.2"
kind: CiliumNetworkPolicy
metadata:
  name: enforce-secure-radius-and-ingress
  namespace: production
spec:
  endpointSelector:
    matchLabels:
      app: radius-authentication-node
  ingress:
  - fromEndpoints:
    - matchLabels:
        role: network-access-server
    toPorts:
    - ports:
      - port: "1812"
        protocol: UDP
      - port: "1813"
        protocol: UDP
  egress:
  - toEndpoints:
    - matchLabels:
        app: enterprise-db
    toPorts:
    - ports:
      - port: "5432"
        protocol: TCP
      rules:
        http:
        - method: "POST"
          path: "/api/v1/auth/verify"
  - toCIDRSet:
    - cidr: 10.100.0.0/16
    toPorts:
    - ports:
      - port: "53"
        protocol: UDP
      rules:
        dns:
        - matchPattern: "*.internal.enterprise.domain"
```

---

## 4. Comandos reales de CLI y registros de salida de terminal (Prompt $)

### Comando 4.1: Inspección de tráfico en vivo con `tcpdump` (filtrado BPF)

```bash
$ sudo tcpdump -nn -vvv -i eth0 'ip proto 17 and (port 1812 or port 1813)' -c 2
```

```text
tcpdump: listening on eth0, link-type EN10MB (Ethernet), snapshot length 262144 bytes
13:42:01.102391 IP (tos 0x0, ttl 64, id 45210, offset 0, flags [DF], proto UDP (17), length 114)
    10.100.0.50.41203 > 10.100.0.10.1812: RADIUS, length 86
	Access-Request (1), id: 0x4f, Authenticator: 7e9b21a8f9104c88a1b2c3d4e5f60718
	  User-Name Attribute (1), length: 14, Value: 'sre_admin'
	  NAS-IP-Address Attribute (4), length: 6, Value: 10.100.0.50
	  NAS-Port Attribute (5), length: 6, Value: 50102
	  EAP-Message Attribute (79), length: 20, Value: \002\001\000\020\001sre_admin
	  Message-Authenticator Attribute (80), length: 18, Value: 0x9f1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c
13:42:01.105822 IP (tos 0x0, ttl 64, id 11029, offset 0, flags [DF], proto UDP (17), length 68)
    10.100.0.10.1812 > 10.100.0.50.41203: RADIUS, length 40
	Access-Challenge (11), id: 0x4f, Authenticator: a1b2c3d4e5f607187e9b21a8f9104c88
	  EAP-Message Attribute (79), length: 8, Value: \001\002\000\006\013\001
	  Message-Authenticator Attribute (80), length: 18, Value: 0x1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d

2 packets captured
2 packets received by filter
0 packets dropped by kernel
```

---

### Comando 4.2: Verificación de autenticación 802.1X en FreeRADIUS mediante `radtest`

```bash
$ radtest -t eap-md5 sre_admin SecretPassword2026 127.0.0.1 1812 SharedSuperSecretKey2026!
```

```text
Sending Access-Request of id 181 to 127.0.0.1 port 1812
	User-Name = "sre_admin"
	User-Password = "SecretPassword2026"
	NAS-IP-Address = 127.0.0.1
	NAS-Port = 1812
	Message-Authenticator = 0x00000000000000000000000000000000
	EAP-Message = 0x0200000e017372655f61646d696e
Received Access-Accept Id 181 from 127.0.0.1:1812 length 48
	Framed-IP-Address = 10.100.10.250
	Framed-IP-Netmask = 255.255.255.0
	Reply-Message = "Welcome SRE Administrator. EAP Authentication Successful."
```

---

### Comando 4.3: Prueba del motor de reglas y análisis de paquetes de Snort 3

```bash
$ sudo snort -c /etc/snort/snort.lua -r /var/log/captures/malicious_ra.pcap -A alert_fast --pcap-filter "icmp6"
```

```text
--------------------------------------------------
o")~   Snort++ 3.1.72.0
--------------------------------------------------
Loading /etc/snort/snort.lua:
  Loading snort.lua...
  Loading pcap module...
  Finished snort.lua.
Appid: Loaded 3520 AppID detectors.
--------------------------------------------------
pcap DAQ configured to read-file /var/log/captures/malicious_ra.pcap
Commencing packet processing
++ [0] /var/log/captures/malicious_ra.pcap
08/06-13:45:12.802112 [**] [1000001:1] NIDS ALERT: Rogue IPv6 Router Advertisement Detected [**] [Priority: 0] {ICMP6} fe80::bad:cafe:1 -> ff02::1

===============================================================================
Run summary:
  Time:     00:00:00.031201 seconds
  Packets:  1
  Processed: 1
  Received: 1
===============================================================================
Packet statistics:
  Acquired: 1
  Analyzed: 1
  Dropped:  1 (Inline IPS Action)
===============================================================================
Snort successfully validated packet against AST rules engine.
```

---

### Comando 4.4: Inspección del conjunto de reglas de `nftables` y métricas de la lista negra dinámica

```bash
$ sudo nft list set inet filter dynamic_blacklist
```

```text
table inet filter {
	set dynamic_blacklist {
		type ipv4_addr
		flags timeout
		elements = { 198.51.100.45 expires 42m12s,
			     203.0.113.119 expires 11m05s }
	}
}
```

```bash
$ sudo nft list chain inet filter input
```

```text
table inet filter {
	chain input {
		type filter hook input priority filter; policy drop;
		ct state invalid drop comment "Drop invalid conntrack states"
		ip saddr @dynamic_blacklist drop comment "Drop blacklisted IPs"
		iifname "lo" accept comment "Allow loopback"
		ct state { established, related } accept comment "Allow tracked connections"
		ip protocol icmp icmp type echo-request limit rate 10/second accept
		ip6 nexthdr icmpv6 icmpv6 type { destination-unreachable, packet-too-big, time-exceeded, parameter-problem, echo-request, nd-router-advert, nd-neighbor-solicit, nd-neighbor-advert } limit rate 20/second accept
		tcp flags syn tcp dport { 80, 443, 22 } meter syn_limit { ip saddr limit rate over 50/second } add @dynamic_blacklist { ip saddr timeout 1h } drop packets 1420 bytes 85200
		ip saddr { 10.100.0.0/24, 192.168.50.0/24 } tcp dport 22 ct state new limit rate 5/minute accept comment "Management SSH"
		ip saddr { 10.100.0.0/24, 192.168.50.0/24 } udp dport { 1812, 1813 } accept comment "RADIUS Authentication/Accounting"
		log prefix "NFT_INPUT_DROP: " flags all counter packets 4821 bytes 289260 drop
	}
}
```

---

### Comando 4.5: Ejecución de escaneo OpenVAS/GVM mediante `gvm-cli`

```bash
$ gvm-cli --gmp-username admin --gmp-password StrongAdminPass tls --hostname 127.0.0.1 -X '<create_task name="Production Edge Security Audit" config_id="daba56c8-73ec-11df-a475-002264764cea" target_id="a1b2c3d4-e5f6-7a8b-9c0d-1e2f3a4b5c6d"/>'
```

```xml
<create_task_response status="201" status_text="OK, task created">
  <id>f81d4fae-7dec-11d0-a765-00a0c91e6bf6</id>
</create_task_response>
```

```bash
$ gvm-cli --gmp-username admin --gmp-password StrongAdminPass tls --hostname 127.0.0.1 -X '<start_task task_id="f81d4fae-7dec-11d0-a765-00a0c91e6bf6"/>'
```

```xml
<start_task_response status="202" status_text="OK, request submitted">
  <report_id>c4b3a2a1-9876-5432-10fe-dcba98765432</report_id>
</start_task_response>
```

---

## 5. Guía de diagnóstico y verificación de fallos

```
                            +-------------------------------------+
                            |    NETWORK SECURITY TROUBLESHOOTING |
                            +------------------+------------------+
                                               |
              +--------------------------------+--------------------------------+
              |                                                                 |
              v                                                                 v
+---------------------------+                                     +---------------------------+
| 802.1X / EAP-TLS FAILURE  |                                     |  SNORT 3 PACKET DROPS     |
+-------------+-------------+                                     +-------------+-------------+
              |                                                                 |
   [Check Certificate Chain]                                            [Inspect DAQ Ring Buffer]
   [Verify EAP Fragment Size]                                           [Verify CPU SoftIRQ Load]
              |                                                                 |
              v                                                                 v
+---------------------------+                                     +---------------------------+
|  Diagnose: radiusd -X     |                                     | Diagnose: ethtool -S eth0 |
+---------------------------+                                     +---------------------------+
```

### Problema 1: Fallo de autenticación EAP-TLS en FreeRADIUS

#### Síntomas
Los dispositivos cliente (laptops, nodos IoT) fallan en la autenticación 802.1X al conectarse a switches perimetrales o redes inalámbricas. Los registros del servidor RADIUS muestran un `Access-Reject` genérico o tiempos de espera agotados (timeouts) en el saludo EAP.

#### Análisis de causa raíz
1. **Ruptura de la cadena de certificados:** El servidor RADIUS no puede validar el certificado del cliente porque el paquete de la Entidad Certificadora (CA) intermedia falta en `ca_file`.
2. **Problema de MTU / Fragmentación EAP:** Las cargas útiles (payloads) del certificado EAP-TLS superan la MTU de la red ($1500\text{ bytes}$), provocando que los paquetes UDP de RADIUS se fragmenten. Los firewalls o switches descartan los fragmentos IP.

#### Flujo de trabajo de diagnóstico
Ejecute FreeRADIUS en modo de depuración en primer plano (`-X`):

```bash
$ sudo radiusd -X -l /dev/stdout
```

Busque trazas de error explícitas de OpenSSL:
```text
(0) tls: TLS_accept: Fail in SSLv3/TLS read client certificate
(0) tls: Certificate line 12 at depth:1 verify error:unable to get local issuer certificate
(0) ERROR: (0) EAP-TLS Handshake Failed
```

#### Comandos de remediación
Actualice `/etc/freeradius/3.0/mods-available/eap` para señalar a un archivo de cadena de CA consolidado que contenga tanto la CA raíz como las CAs intermedias:
```bash
$ cat /etc/ssl/certs/RootCA.pem /etc/ssl/certs/IntermediateCA.pem > /etc/freeradius/3.0/certs/ca_chain.pem
```

Ajuste el tamaño máximo del mensaje EAP en `/etc/freeradius/3.0/mods-available/eap`:
```radius
tls-config tls-common {
    fragment_size = 1260
}
```

---

### Problema 2: Pérdida de paquetes en Snort 3 bajo alta carga de tráfico de red

#### Síntomas
La interfaz de red reporta descartes y los registros de Snort muestran alertas no detectadas durante un alto rendimiento ($>10\text{ Gbps}$).

#### Análisis de causa raíz
1. **Desbordamiento de ring buffer:** El buffer de recepción de sockets del kernel de Linux (`rmem_default`, `rmem_max`) o el ring buffer del DAQ `afpacket` está infradimensionado para tráfico en ráfagas.
2. **Cuello de botella en un único núcleo de CPU:** Snort está limitado a un solo hilo, lo que provoca que el manejo de `softirq` en `CPU0` se sature al 100%.

#### Flujo de trabajo de diagnóstico
Verifique los contadores de descarte de la interfaz física:
```bash
$ ethtool -S eth0 | grep -E "drop|fifo|missed"
```
```text
     rx_dropped: 120492
     rx_fifo_errors: 412
     rx_missed_errors: 120080
```

Verifique la distribución de IRQ de la CPU:
```bash
$ mpstat -P ALL 1 3
```
```text
13:50:01 CPU  %usr  %nice  %sys  %iowait  %irq  %soft  %idle
13:50:02   0  2.00   0.00  5.00     0.00  0.00  93.00   0.00  <-- SOFTIRQ SATURATION
13:50:02   1  0.00   0.00  1.00     0.00  0.00   1.00  98.00
```

#### Comandos de remediación
1. Incremente los buffers de socket de red del kernel de Linux:
```bash
$ sudo sysctl -w net.core.rmem_max=134217728
$ sudo sysctl -w net.core.rmem_default=67108864
$ sudo sysctl -w net.core.netdev_max_backlog=100000
```

2. Configure Receive Side Scaling (RSS) y `afpacket` multihilo en `/etc/snort/snort.lua`:
```lua
thread_config =
{
    max_threads = 8,
}
daq =
{
    module = 'afpacket',
    mode = 'inline',
    variables =
    {
        'fanout_type=hash',
        'buffer_size_mb=2048',
    }
}
```

---

### Problema 3: El enrutamiento asimétrico causa descartes en el seguimiento de conexiones de `nftables`

#### Síntomas
El tráfico entrante legítimo es descartado por `nftables` con el mensaje de registro `NFT_INPUT_DROP: ct state invalid`.

#### Análisis de causa raíz
En una red dual-homed o con rutas múltiples, los paquetes de solicitud llegan a través de `eth0`, pero los paquetes de respuesta salen a través de `eth1`. Netfilter en `eth0` observa transiciones de estado TCP desordenadas, marcando los paquetes legítimos como `invalid`.

#### Flujo de trabajo de diagnóstico
Monitoree en vivo los eventos de conntrack de Netfilter:
```bash
$ sudo conntrack -E -p tcp --state INVALID
```
```text
 [UPDATE] 10.100.0.50 -> 192.168.1.100 tcp dport=443 [UNACKNOWLEDGED] [stat=INVALID]
```

Inspeccione el seguimiento estricto de la ventana TCP en el kernel:
```bash
$ sysctl net.netfilter.nf_conntrack_tcp_be_liberal
```
```text
net.netfilter.nf_conntrack_tcp_be_liberal = 0
```

#### Comandos de remediación
Habilite el seguimiento liberal de TCP en el kernel para omitir los descartes asimétricos fuera de ventana:
```bash
$ sudo sysctl -w net.netfilter.nf_conntrack_tcp_be_liberal=1
```
O actualice `nftables.conf` para manejar flujos de ruta asimétricos explícitamente sin descartar estados no válidos en interfaces internas:
```nftables
chain input {
    iifname "eth1" tcp flags != syn accept comment "Allow asymmetric mid-stream TCP traffic"
}
```

---

### Problema 4: Anuncios de router (RAs) IPv6 no autorizados que causan Man-In-The-Middle (MITM)

#### Síntomas
Los hosts de la red local reasignan dinámicamente su puerta de enlace (default gateway) IPv6 por defecto a una dirección IPv6 link-local no confiable (`fe80::bad:cafe:1`), redirigiendo todo el tráfico de salida (egress) a través de un nodo atacante.

#### Análisis de causa raíz
Un dispositivo no autorizado o comprometido en el dominio de Capa 2 está transmitiendo paquetes ICMPv6 Tipo 134 (Router Advertisement) con una puntuación alta de preferencia de router.

#### Flujo de trabajo de diagnóstico
Monitoree mensajes RA de ICMPv6 utilizando `tshark`:
```bash
$ sudo tshark -i eth0 -Y "icmpv6.type == 134" -T fields -e frame.time -e ipv6.src -e icmpv6.ra.router_lifetime
```
```text
2026-08-06 13:55:01.102931  fe80::bad:cafe:1  1800
```

#### Comandos de remediación
1. Bloquee RAs no autorizados (Rogue RAs) en el host Linux utilizando la configuración sysctl del kernel:
```bash
# Disable IPv6 RA acceptance on multi-homed routers
$ sudo sysctl -w net.ipv6.conf.all.accept_ra=0
$ sudo sysctl -w net.ipv6.conf.default.accept_ra=0
```

2. Aplique una regla de descarte en eBPF/XDP o una regla de descarte raw en `nftables` para direcciones link-local IPv6 de origen no aprobadas:
```bash
$ sudo nft add rule inet filter input ip6 nexthdr icmpv6 icmpv6 type nd-router-advert ip6 saddr != fe80::1:1 drop
```

---

## 6. Referencias

- **Objetivos oficiales de LPIC-3 303 de Linux Professional Institute (LPI) (v3.0):**  
  [https://wiki.lpi.org/wiki/LPIC-303_Objectives_V3.0](https://wiki.lpi.org/wiki/LPIC-303_Objectives_V3.0)
- **Resumen de la certificación de seguridad LPIC-3 de Linux Professional Institute:**  
  [https://www.lpi.org/our-certifications/lpic-3-303-overview/](https://www.lpi.org/our-certifications/lpic-3-303-overview/)
- **Documentación oficial y wiki de reglas de nftables:**  
  [https://wiki.nftables.org/wiki-nftables/index.php/Main_Page](https://wiki.nftables.org/wiki-nftables/index.php/Main_Page)
- **Manual de Snort 3 y arquitectura de configuración en Lua:**  
  [https://docs.snort.org/](https://docs.snort.org/)
- **Documentación de FreeRADIUS 3.0 y guía de configuración de EAP:**  
  [https://freeradius.org/documentation/](https://freeradius.org/documentation/)
- **Arquitectura de Greenbone Vulnerability Management (GVM / OpenVAS):**  
  [https://greenbone.github.io/docs/gvm-architecture/](https://greenbone.github.io/docs/gvm-architecture/)
- **Referencia de sintaxis de filtros BPF para Wireshark y tcpdump:**  
  [https://www.tcpdump.org/manpages/pcap-filter.7.html](https://www.tcpdump.org/manpages/pcap-filter.7.html)
- **Especificación de Network Policy nativa de la nube para Cilium eBPF:**  
  [https://docs.cilium.io/en/stable/policy/language/](https://docs.cilium.io/en/stable/policy/language/)