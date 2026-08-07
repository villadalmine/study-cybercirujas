# LPI Security Essentials (020-100) — Tema 4.1: Network and Service Security

**Exam Code:** 020-100 (Versión 1.0)  
**Topic Reference:** Topic 4.1 (Objetivo 024: Network and Service Security)  
**Weight:** 20  
**Target Role:** Senior SRE / Principal Platform Architect  

---

## 1. Motivación de Arquitectura de Producción y Modelado de Amenazas

### 1.1 El Problema de Producción: Defense-in-Depth vs. Colapso del Perímetro
Los modelos tradicionales de infraestructura se basaban en un modelo de seguridad perimetral ("Castle-and-Moat"), asumiendo que el tráfico dentro de la subred de la red interna era confiable. Los entornos cloud-native modernos hacen que esta suposición sea inválida debido a workloads dinámicos, container hosts multi-tenant, inyección de sidecar proxies y edge endpoints distribuidos.

Un solo contenedor comprometido o un daemon no protegido (unhardened) expuesto en `0.0.0.0:8080` permite a un atacante pivotar lateralmente a través de subredes VPC planas, ejecutar remote code execution (RCE), realizar ARP spoofing o exfiltrar credenciales del entorno a través de endpoints de metadatos (por ejemplo, `169.254.169.254`). 

```
                                  [ PUBLIC INTERNET ]
                                           |
                                  ( Untrusted Traffic )
                                           |
                                           v
                             +---------------------------+
                             | Hardened Border Firewall  |
                             | (nftables / Edge Ingress) |
                             +---------------------------+
                                           |
                                           v
                             +---------------------------+
                             |   L7 Reverse Proxy / TLS  |
                             |   (NGINX / Rate Limit)    |
                             +---------------------------+
                                           |
                                 (Encrypted Transit)
                                           |
     +-------------------------------------+-------------------------------------+
     |                                                                           |
     v                                                                           v
+------------------------------------+                      +------------------------------------+
| Workload Namespace A               |                      | Workload Namespace B               |
| (Isolated netns / Systemd Sandbox) |                      | (Isolated netns / Systemd Sandbox) |
| - Localhost socket binding only    | <=== Isolated =====> | - Restricted IP family egress      |
| - Strictly enforced nftables rules |     (No Lateral)     | - WireGuard VPN Tunnel Endpoints   |
+------------------------------------+                      +------------------------------------+
```

### 1.2 Modelado de Amenazas y Vectores de Ataque
El despliegue de servicios en producción requiere protección contra vectores de amenaza específicos que apuntan a Layer 3, Layer 4 y Layer 7:

1. **Unencrypted Data-in-Transit & Interception (MitM):** Los protocolos en texto plano no autenticados (HTTP, FTP, Telnet, conexiones de bases de datos no cifradas) permiten la captura pasiva (passive sniffing) utilizando motores de captura de paquetes (`tcpdump`/`libpcap`) o ARP cache poisoning activo.
2. **Resource Exhaustion & Denial of Service (DoS/DDoS):** Los TCP SYN floods consumen las tablas de estado de conexión del kernel (`conntrack`), agotando file descriptors y asignaciones de memoria antes de que las aplicaciones puedan procesar las conexiones.
3. **Improper Socket Binding & Unauthorized Surface Exposure:** Los servicios que se vinculan implícitamente a direcciones wildcard (`0.0.0.0` o `::`) eluden los controles de acceso destinados solo a ámbito local, exponiendo interfaces administrativas internas (por ejemplo, Redis, JMX, métricas de Prometheus) a adaptadores de red externos.
4. **Lateral Movement via Flat Subnets:** La falta de filtrado de paquetes stateful de egress/ingress interno permite que workloads maliciosos escaneen CIDRs locales usando SYN stealth scans (`nmap`) para descubrir y explotar servicios adyacentes.

### 1.3 Mecánica de Redes del Kernel de Linux
La aplicación de la seguridad de red opera dentro de la arquitectura del kernel de Linux a través de distintos subsistemas:

* **Netfilter Framework:** Proporciona hooks dentro del stack de red del kernel de Linux (`PREROUTING`, `INPUT`, `FORWARD`, `OUTPUT`, `POSTROUTING`) permitiendo la intercepción de paquetes, Network Address Translation (NAT) y seguimiento de conexiones stateful (`nf_conntrack`).
* **Linux Network Namespaces (`netns`):** Proporciona una virtualización completa del stack de red, aislando interfaces de red, tablas de enrutamiento, tablas ARP y listas de sockets por grupo de procesos.
* **Control Groups (`cgroups v2`) & Socket Filtering:** Aplica la asignación de ancho de banda de red y restricciones de system calls/familias de sockets (`AF_INET`, `AF_INET6`, `AF_UNIX`) a través de eBPF o unidades de systemd.

---

## 2. Análisis Comparativo Técnico y Análisis de Trade-offs

### 2.1 Filtrado de Paquetes en el Kernel: `iptables` vs. `nftables` vs. `eBPF (XDP)`

| Métrica / Dimensión | `iptables` (legacy `ip_tables`) | `nftables` (`nf_tables`) | eBPF / XDP (`Express Data Path`) |
| :--- | :--- | :--- | :--- |
| **Subsistema del Kernel** | Módulos separados (`iptables`, `ip6tables`, `arptables`, `ebtables`). | Motor unificado `nf_tables` con intérprete de bytecode genérico. | Máquina virtual programable en el kernel adjunta a hooks del driver de red. |
| **Rendimiento (Altas Tasas de Paquetes)** | Evaluación lineal de reglas (overhead de $O(N)$ por coincidencia de paquete). | Tablas de búsqueda y conjuntos (evaluación amortizada de $O(1)$). | Descarte temprano de paquetes a nivel de driver NIC ($O(1)$ antes de la asignación de `sk_buff`). |
| **Actualizaciones de Reglas y Atomicidad** | Reemplazo completo de tablas no atómico; causa caídas de paquetes transitorias bajo actualizaciones de alta frecuencia. | Reemplazo de ruleset completamente atómico y actualizaciones diferenciales a través de API de transacciones. | Actualizaciones de estado atómicas en eBPF maps sin re-compilar o recargar filtros de red. |
| **Dual-Stack (IPv4/IPv6)** | Requiere configuraciones duplicadas en `iptables` e `ip6tables`. | Familia de direcciones `inet` unificada que maneja IPv4 e IPv6 simultáneamente. | Lógica personalizada que maneja el parsing de encabezados IP nativamente dentro del programa C de eBPF. |
| **Caso de Uso Recomendado** | Mantenimiento de infraestructura legacy. | Firewalls de servidores Linux estándar, edge nodes y protección de hosts. | Microsegmentación de ultra-alto rendimiento (por ejemplo, Cilium, filtros de edge de Cloudflare). |

### 2.2 Abstracciones de Gestión de Firewalls de Host: `ufw` vs. `firewalld`

| Característica | `ufw` (Uncomplicated Firewall) | `firewalld` |
| :--- | :--- | :--- |
| **Distribución Principal** | Ecosistema Ubuntu / Debian. | Ecosistema RHEL / Fedora / CentOS / Rocky Linux. |
| **Integración Backend** | Traduce comandos CLI a rulesets de `iptables` / `nftables`. | Utiliza la API D-Bus para manipular dinámicamente rulesets de `nftables`. |
| **Modelo de Estado y Zonas** | Modelo de perfil estático (valores por defecto simples de Ingress/Egress + listas de reglas). | Modelo de zonas dinámicas (`public`, `internal`, `dmz`, `trusted`) asignadas por interfaz/IP de origen. |
| **Configuración Dinámica** | Modificar reglas requiere aplicar actualizaciones que recargan las chains. | Admite actualizaciones de estado en runtime vs. permanentes sin interrumpir conexiones establecidas. |
| **Audiencia Objetivo** | Estaciones de trabajo de escritorio y despliegues de servidores estáticos y simples. | Servidores dinámicos multi-interfaz, virtualización empresarial y entornos de enrutamiento complejos. |

### 2.3 Protocolos VPN Sitio a Sitio y de Acceso Remoto

| Parámetro | WireGuard | OpenVPN | IPsec (IKEv2 / ESP) |
| :--- | :--- | :--- | :--- |
| **Capa de Implementación** | Módulo criptográfico en el kernel (`wireguard.ko`). | Proceso en user-space (utilizando dispositivos `tun`/`tap` y OpenSSL). | Motor de protocolo en el kernel (subsistema `xfrm` con un daemon IKE externo como StrongSwan). |
| **Agilidad Criptográfica** | Primitivas modernas fijas (ChaCha20-Poly1305, Curve25519, BLAKE2s, HKDF). | Negociación flexible de cifrados (AES-GCM, ChaCha20, RSA, ECDSA). | Negociación empresarial (AES-CBC/GCM, SHA2, grupos Diffie-Hellman). |
| **Tamaño de la Base de Código** | ~4,000 líneas de código (Altamente auditable). | ~100,000+ líneas de código. | Alta complejidad a través de múltiples estándares RFC. |
| **Rendimiento y Latencia** | Rendimiento cercano a velocidad de línea (line-rate); bajo overhead de memoria y cero tráfico en reposo (idle). | El cambio de contexto entre user-space y kernel-space introduce overhead de CPU y latencia. | Alto rendimiento cuando la aceleración criptográfica por hardware (AES-NI) está presente. |
| **Gestión de Estado** | Estado de protocolo UDP sin conexión; handshake dinámico bajo demanda. | Estado orientado a conexión sobre UDP/TCP con re-keying TLS periódico. | Protocolos complejos de renegociación de asociaciones de seguridad (SA). |

---

## 3. Manifiestos de Infraestructura de Producción y Configuraciones de Hardening

### 3.1 Configuración de `nftables` Dual-Stack Hardened (`/etc/nftables.conf`)
Este ruleset de grado de producción aplica una política estricta de default-drop, aisla las interfaces de control plane, mitiga ataques TCP SYN flood mediante conjuntos de rate-limiting y bloquea estados de conexión inválidos tanto en IPv4 como en IPv6.

```nftables
#!/usr/sbin/nft -f

# Flush existing rulesets
flush ruleset

table inet filter {
    # Rate limiting sets for anti-bruteforce protection
    set ssh_meter {
        type ipv4_addr
        flags dynamic, timeout
        timeout 1m
    }

    chain input {
        type filter hook input priority filter; policy drop;

        # 1. Allow traffic on loopback interface
        iifname "lo" accept comment "Accept all local loopback traffic"
        iifname != "lo" ip daddr 127.0.0.0/8 drop comment "Drop spoofed loopback traffic"
        iifname != "lo" ip6 daddr ::1 drop comment "Drop spoofed IPv6 loopback traffic"

        # 2. Stateful connection tracking
        ct state established,related accept comment "Allow established/related connections"
        ct state invalid drop comment "Drop invalid packet states immediately"

        # 3. ICMP rate limiting (prevent ping sweeps and ICMP flood)
        ip protocol icmp icmp type { echo-request, router-advertisement, time-exceeded, destination-unreachable } limit rate 5/second burst 10 packets accept comment "Rate limit IPv4 ICMP"
        ip6 nexthdr ipv6-icmp icmpv6 type { echo-request, destination-unreachable, packet-too-big, time-exceeded, nd-neighbor-solicit, nd-neighbor-advert } limit rate 5/second burst 10 packets accept comment "Rate limit IPv6 ICMP"

        # 4. Anti-SYN Flood Mitigation
        tcp flags syn tcp option maxseg size 1-1460 limit rate 20/second burst 40 packets accept comment "Mitigate TCP SYN flood"

        # 5. Public Services Ingress Enforcement
        # Rate-limited SSH access on TCP/22 (max 3 connections per minute per source IP)
        tcp dport 22 ct state new update @ssh_meter { ip saddr limit rate over 3/minute } drop
        tcp dport 22 ct state new accept comment "Allow rate-limited SSH"

        # HTTPS Ingress traffic on TCP/443
        tcp dport 443 ct state new accept comment "Allow public HTTPS ingress"

        # Explicitly log rejected packets for SIEM auditing
        limit rate 3/minute log prefix "NFTABLES-INGRESS-REJECT: " level info
        reject with icmpx type admin-prohibited
    }

    chain forward {
        type filter hook forward priority filter; policy drop;
        comment "Drop all routed packet forwarding by default"
    }

    chain output {
        type filter hook output priority filter; policy accept;
        comment "Allow all egress traffic from localhost"
    }
}
```

### 3.2 Unidad de Servicio Systemd Aislada de la Red (`/etc/systemd/system/secure-api.service`)
Este archivo de unidad de systemd aplica parámetros estrictos de seguridad del kernel de Linux, restringe las familias de sockets de red que el proceso puede crear, aísla el network namespace y vincula la ejecución a un rango de direcciones IP internas.

```ini
[Unit]
Description=Production Hardened API Daemon
After=network-online.target nftables.service
Wants=network-online.target
Documentation=https://internal.wiki.enterprise.io/architecture/secure-api

[Service]
Type=exec
User=api-worker
Group=api-worker
WorkingDirectory=/opt/secure-api
ExecStart=/opt/secure-api/bin/api-server --bind-address=127.0.0.1 --port=8443
Restart=on-failure
RestartSec=5s

# Process Sandbox & System Call Isolation
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictRealtime=true
MemoryDenyWriteExecute=true
NoNewPrivileges=true
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

# System Call Filtering
SystemCallFilter=@default @network-io @basic-io
SystemCallFilter=~@clock @cpu-emulation @debug @keyring @module @obsolete @raw-io @reboot @swap

# Network Security Hardening Options
# Isolate process from receiving socket calls outside specified AF families
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6

# Egress/Ingress IP Filtering via cgroup v2 BPF filters
IPAddressDeny=any
IPAddressAllow=127.0.0.1/32
IPAddressAllow=10.244.0.0/16

# Socket & Port Allocation Protection
PrivateNetwork=false
ProtectClock=true

[Install]
WantedBy=multi-user.target
```

### 3.3 Manifiesto de Peer de VPN WireGuard de Producción (`/etc/wireguard/wg0.conf`)
Manifiesto de interfaz WireGuard completamente funcional que configura cifrado en kernel-space, enrutamiento estricto de IP permitidas (allowed IPs) y keepalives persistentes para atravesar firewalls NAT stateful.

```ini
[Interface]
# Device Address Definition within Private VPN Subnet
Address = 10.200.50.1/24, fd42:200:50::1/64
ListenPort = 51820
PrivateKey = uK8Z...[REDACTED_32_BYTE_BASE64_PRIVATE_KEY]...=
SaveConfig = false

# Kernel Pre/Post Execution Rules for Firewall Traversal
PreUp = sysctl -w net.ipv4.ip_forward=1
PostUp = nft add table inet wg-nat; nft add chain inet wg-nat postrouting \{ type nat hook postrouting priority srcnat\; \}; nft add rule inet wg-nat postrouting oifname "eth0" masquerade
PostDown = nft delete table inet wg-nat

[Peer]
# Remote Branch Gateway Office
PublicKey = 7bXw...[REDACTED_32_BYTE_BASE64_PUBLIC_KEY]...=
PresharedKey = pK9q...[REDACTED_32_BYTE_BASE64_PRESHARED_KEY]...=
AllowedIPs = 10.200.50.2/32, 192.168.10.0/24
Endpoint = 198.51.100.45:51820
PersistentKeepalive = 25
```

### 3.4 Reverse Proxy NGINX Edge Hardened (`/etc/nginx/sites-available/secure-service.conf`)
Reverse proxy de producción que aplica cifrado estricto TLS 1.3, HTTP Strict Transport Security (HSTS), zonas de rate-limiting y sanitización de encabezados del proxy.

```nginx
# Rate Limiting Zone Definition (10MB shared memory zone, max 10 requests/sec per IP)
limit_req_zone $binary_remote_addr zone=api_gateway_rate:10m rate=10r/s;
limit_conn_zone $binary_remote_addr zone=api_conn_limit:10m;

server {
    listen 80;
    listen [::]:80;
    server_name api.enterprise.internal;

    # Enforce global HTTP-to-HTTPS Redirection with strict 301
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name api.enterprise.internal;

    # TLS Certificate & Cryptographic Material Configuration
    ssl_certificate /etc/ssl/certs/api_enterprise_combined.crt;
    ssl_certificate_key /etc/ssl/private/api_enterprise.key;
    ssl_dhparam /etc/ssl/certs/dhparam4096.pem;

    # Strict Protocol & Cipher Suites (TLS 1.2 and TLS 1.3 only)
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;

    # TLS Session Cache Optimization
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:10m;
    ssl_session_tickets off;

    # OCSP Stapling Configuration
    ssl_stapling on;
    ssl_stapling_verify on;
    ssl_trusted_certificate /etc/ssl/certs/ca_chain.crt;
    resolver 1.1.1.1 8.8.8.8 valid=300s;
    resolver_timeout 5s;

    # Security Headers Enforcement
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
    add_header X-Frame-Options "DENY" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Content-Security-Policy "default-src 'self'; http: https: data: blob: 'unsafe-inline'" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    # Proxy Rate Limiting & Connection Limits
    limit_req zone=api_gateway_rate burst=20 nodelay;
    limit_conn api_conn_limit 20;

    location / {
        proxy_pass http://127.0.0.1:8443;
        proxy_http_version 1.1;

        # Header Sanitization & Connection Protection
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header X-Forwarded-Port $server_port;

        # Timeouts preventing Slowloris attacks
        proxy_connect_timeout 5s;
        proxy_send_timeout 10s;
        proxy_read_timeout 10s;
    }
}
```

---

## 4. Ejecución CLI en el Mundo Real y Salidas de Terminal

### 4.1 Auditoría de Sockets Vinculados y Asociaciones de Procesos
Inspeccione los sockets TCP/UDP abiertos, verifique el alcance del binding de la interfaz (`0.0.0.0` vs. `127.0.0.1`) y correlacione los sockets en escucha con los IDs de proceso usando `ss` y `lsof`.

```bash
$ sudo ss -tulpn
```
```text
Netid  State   Recv-Q  Send-Q     Local Address:Port      Peer Address:Port  Process                                                                         
udp    UNCONN  0       0                0.0.0.0:51820          0.0.0.0:*      users:(("wg-crypt-wg0",pid=1240,fd=5))                                         
tcp    LISTEN  0       511            127.0.0.1:8443          0.0.0.0:*      users:(("api-server",pid=48210,fd=3))                                           
tcp    LISTEN  0       511              0.0.0.0:80            0.0.0.0:*      users:(("nginx",pid=1102,fd=6),("nginx",pid=1103,fd=6))                         
tcp    LISTEN  0       511              0.0.0.0:443           0.0.0.0:*      users:(("nginx",pid=1102,fd=7),("nginx",pid=1103,fd=7))                         
tcp    LISTEN  0       128              0.0.0.0:22            0.0.0.0:*      users:(("sshd",pid=954,fd=3))                                                   
tcp    LISTEN  0       128                 [::]:22               [::]:*      users:(("sshd",pid=954,fd=4))                                                   
```

Inspeccione los límites de capabilities específicos del proceso y los detalles de los sockets:
```bash
$ sudo lsof -i TCP:8443 -a -p 48210
```
```text
COMMAND     PID       USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
api-serve 48210 api-worker    3u  IPv4  89412      0t0  TCP localhost:8443 (LISTEN)
```

### 4.2 Gestión y Validación del Estado de `nftables`
Inspeccione las chains activas del kernel, verifique los contadores de reglas y monitoree las caídas de paquetes en tiempo real:

```bash
$ sudo nft list ruleset
```
```text
table inet filter {
	set ssh_meter {
		type ipv4_addr
		flags dynamic,timeout
		timeout 1m
	}

	chain input {
		type filter hook input priority filter; policy drop;
		iifname "lo" accept comment "Accept all local loopback traffic"
		iifname != "lo" ip daddr 127.0.0.0/8 drop comment "Drop spoofed loopback traffic"
		iifname != "lo" ip6 daddr ::1 drop comment "Drop spoofed IPv6 loopback traffic"
		ct state established,related accept comment "Allow established/related connections"
		ct state invalid drop comment "Drop invalid packet states immediately"
		ip protocol icmp icmp type { destination-unreachable, echo-request, router-advertisement, time-exceeded } limit rate 5/second burst 10 packets accept comment "Rate limit IPv4 ICMP"
		ip6 nexthdr ipv6-icmp icmpv6 type { destination-unreachable, echo-request, packet-too-big, time-exceeded, nd-router-solicit, nd-neighbor-solicit } limit rate 5/second burst 10 packets accept comment "Rate limit IPv6 ICMP"
		tcp flags syn tcp option maxseg size 1-1460 limit rate 20/second burst 40 packets accept comment "Mitigate TCP SYN flood"
		tcp dport 22 ct state new update @ssh_meter { ip saddr limit rate over 3/minute } drop
		tcp dport 22 ct state new accept comment "Allow rate-limited SSH"
		tcp dport 443 ct state new accept comment "Allow public HTTPS ingress"
		limit rate 3/minute log prefix "NFTABLES-INGRESS-REJECT: " level info
		reject with icmpx type admin-prohibited
	}

	chain forward {
		type filter hook forward priority filter; policy drop;
	}

	chain output {
		type filter hook output priority filter; policy accept;
	}
}
```

### 4.3 Inspección de Red Activa con `tcpdump`
Capture encabezados de paquetes crudos en la interfaz `eth0` para confirmar que el tráfico HTTP al puerto 80 recibe redirecciones 301 HSTS inmediatas al puerto 443 y que los datos en el puerto 443 contienen frames de TLS Application Data cifrados.

```bash
$ sudo tcpdump -i eth0 -nn -s 0 'tcp port 80 or tcp port 443' -c 4
```
```text
tcpdump: verbose output suppressed, use -v[v]... for full protocol decode
listening on eth0, link-type EN110MB (Ethernet), snapshot length 262144 bytes
00:14:22.849102 IP 198.51.100.12.54312 > 192.0.2.10.80: Flags [S], seq 382910481, win 64240, options [mss 1460,sackOK,TS val 2819010 ecr 0,nop,wscale 7], length 0
00:14:22.849280 IP 192.0.2.10.80 > 198.51.100.12.54312: Flags [S.], seq 981240192, ack 382910482, win 65160, options [mss 1460,sackOK,TS val 3912019 ecr 2819010,nop,wscale 7], length 0
00:14:22.850110 IP 198.51.100.12.54312 > 192.0.2.10.80: Flags [.], ack 1, win 501, length 0
00:14:22.850401 IP 198.51.100.12.54312 > 192.0.2.10.80: Flags [P.], seq 1:82, ack 1, win 501: HTTP: GET / HTTP/1.1
4 packets captured
12 packets received by filter
0 packets dropped by kernel
```

### 4.4 Reconocimiento de Superficie y Verificación de Escaneo de Puertos con `nmap`
Valide la superficie de ataque externa utilizando SYN scans sigilosos (`-sS`) combinados con detección de servicios/versiones (`-sV`):

```bash
$ nmap -sS -sV -p 21,22,80,443,8443,51820 192.0.2.10
```
```text
Starting Nmap 7.94 ( https://nmap.org ) at 2026-08-07 00:48 UTC
Nmap scan report for api.enterprise.internal (192.0.2.10)
Host is up (0.00042s latency).

PORT      STATE    SERVICE    VERSION
21/tcp    filtered ftp
22/tcp    open     ssh        OpenSSH 8.9p1 Ubuntu 3ubuntu0.6 (Ubuntu Linux; protocol 2.0)
80/tcp    open     http       nginx 1.18.0 (Ubuntu)
443/tcp   open     ssl/http   nginx 1.18.0 (Ubuntu)
8443/tcp  filtered https-alt
51820/udp open|filtered wireguard

Service detection performed. Please report any incorrect results at https://nmap.org/submit/ .
Nmap done: 1 IP address (1 host up) scanned in 6.42 seconds
```

### 4.5 Gestión de Estado del Enlace y Peer de WireGuard
Inspeccione los handshakes criptográficos y las métricas de transferencia a través de túneles WireGuard activos:

```bash
$ sudo wg show wg0
```
```text
interface: wg0
  public key: 7bXw...[REDACTED_BASE64_PUBLIC_KEY]...=
  private key: (hidden)
  listening port: 51820

peer: 7bXw...[REDACTED_PEER_PUBLIC_KEY]...=
  preshared key: (hidden)
  endpoint: 198.51.100.45:51820
  allowed ips: 10.200.50.2/32, 192.168.10.0/24
  latest handshake: 1 minute, 12 seconds ago
  transfer: 4.82 MiB received, 18.94 MiB sent
  persistent keepalive: every 25 seconds
```

---

## 5. Guía de Verificación y Diagnóstico de Fallas

### 5.1 Árbol de Decisión de Diagnóstico y Escenarios de Falla

```
                          [ INCIDENT ALERT: SERVICE UNREACHABLE ]
                                             |
                                             v
                             +-------------------------------+
                             | Can host ping gateway/IP?     |
                             +-------------------------------+
                                    /                 \
                              (No) /                   \ (Yes)
                                  v                     v
                +-------------------+                 +--------------------------------+
                | Check Layer 1/2   |                 | Is port open via `ss -tulpn`?  |
                | (`ip link`, ARP)  |                 +--------------------------------+
                +-------------------+                        /                  \
                                                       (No) /                    \ (Yes)
                                                           v                      v
                                         +--------------------+        +--------------------+
                                         | Service crashed or |        | Check `nftables`   |
                                         | bound to 127.0.0.1 |        | packet drop log    |
                                         +--------------------+        +--------------------+
                                                                                  |
                                                                                  v
                                                                       +--------------------+
                                                                       | Check TLS & Proxy  |
                                                                       | logs (`journalctl`)|
                                                                       +--------------------+
```

### 5.2 Fallas Comunes de Producción y Playbooks de Resolución

#### Problema A: Agotamiento de la Tabla `conntrack` Descartando Paquetes Válidos
* **Symptom:** El servidor descarta conexiones TCP entrantes de forma aleatoria durante picos de tráfico; `dmesg` reporta logs de error del kernel: `nf_conntrack: table full, dropping packet`.
* **Root Cause:** La tabla de seguimiento de conexiones de netfilter del kernel (`net.netfilter.nf_conntrack_max`) es de tamaño insuficiente para la concurrencia de conexiones actual.
* **Diagnosis Commands:**
  ```bash
  $ sysctl net.netfilter.nf_conntrack_count net.netfilter.nf_conntrack_max
  ```
  ```text
  net.netfilter.nf_conntrack_count = 262144
  net.netfilter.nf_conntrack_max = 262144
  ```
* **Resolution:** Aumente el tamaño de la tabla dinámicamente y ajuste los hash buckets en `/etc/sysctl.d/99-netfilter.conf`:
  ```bash
  $ sudo sysctl -w net.netfilter.nf_conntrack_max=1048576
  $ echo "options nf_conntrack hashsize=262144" | sudo tee /etc/modprobe.d/conntrack.conf
  ```

#### Problema B: El Servicio Falla al Vincular el Socket (`EADDRINUSE` o `EACCES`)
* **Symptom:** La aplicación no logra iniciar, lanzando `PermissionDenied` o `Address already in use`.
* **Root Cause 1 (`EACCES`):** Usuario no-root intentando vincularse a un puerto privilegiado (< 1024) sin `CAP_NET_BIND_SERVICE` o permiso en sysctl.
* **Root Cause 2 (`EADDRINUSE`):** Proceso huérfano existente que permanece en el socket.
* **Diagnosis Commands:**
  ```bash
  $ sudo journalctl -u secure-api.service -n 20 --no-pager
  ```
  ```text
  Aug 07 00:48:01 edge-node-01 api-server[48210]: Error: Failed to bind socket to 0.0.0.0:443: Permission denied (os error 13)
  ```
* **Resolution:** Reduzca el umbral de puertos no privilegiados o conceda Linux capabilities:
  ```bash
  $ sudo sysctl -w net.ipv4.ip_unprivileged_port_start=80
  # Or via binary capability assignment:
  $ sudo setcap 'cap_net_bind_service=+ep' /opt/secure-api/bin/api-server
  ```

#### Problema C: Enrutamiento Asimétrico y Caídas por Reverse Path Filtering
* **Symptom:** Los paquetes llegan a través de WireGuard (`wg0`) o la interfaz secundaria `eth1`, pero las respuestas son descartadas internamente por el kernel.
* **Root Cause:** Reverse Path Forwarding estricto (`rp_filter`) descarta paquetes cuya ruta de egress difiere de la interfaz de ingress.
* **Diagnosis Commands:**
  ```bash
  $ sudo sysctl -a | grep rp_filter
  ```
  ```text
  net.ipv4.conf.all.rp_filter = 1
  net.ipv4.conf.eth1.rp_filter = 1
  ```
* **Resolution:** Establezca `rp_filter` en modo permisivo (loose mode `2`) en interfaces asimétricas:
  ```bash
  $ sudo sysctl -w net.ipv4.conf.all.rp_filter=2
  $ sudo sysctl -w net.ipv4.conf.eth1.rp_filter=2
  ```

---

## 6. Referencias

* **LPI Security Essentials Official Overview:**  
  https://www.lpi.org/our-certifications/security-essentials-overview/
* **LPI Security Essentials Exam Objectives (020-100):**  
  https://wiki.lpi.org/wiki/Security_Essentials_Objectives_V1.0
* **Linux Kernel Netfilter & nftables Documentation:**  
  https://netfilter.org/projects/nftables/manpage.html
* **WireGuard Protocol & Architecture Specification:**  
  https://www.wireguard.com/papers/wireguard.pdf
* **Mozilla Web Security Guidelines & TLS Configuration Generator:**  
  https://wiki.mozilla.org/Security/Server_Side_TLS
* **Systemd Network & Security Capabilities (`systemd.exec`):**  
  https://www.freedesktop.org/software/systemd/man/systemd.exec.html