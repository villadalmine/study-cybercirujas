# LPIC-2 (202-450) Tema 2.6 / 212: Seguridad del Sistema — Guía de Estudio Avanzada para Producción

**Certificación Objetivo:** LPIC-2 (Examen 202-450, Versión 4.5)  
**Tema:** 212 / 2.6 — Seguridad del Sistema  
**Peso:** 9  
**Audiencia Objetivo:** SREs, Arquitectos de Plataforma y Administradores Senior de Sistemas Linux  

---

## 1. Motivación y Problema de Arquitectura en Producción

### 1.1 Seguridad de Borde Empresarial y Aislamiento de Red
En la infraestructura Linux de producción moderna, los servidores operan como gateways de perímetro, nodos de ingress multitenant o hosts bastion asegurados. La seguridad del sistema no es meramente una colección de selectores de configuración aislados; forma una frontera arquitectónica de defensa en profundidad interconectada a través del espacio de kernel, los manejadores de la pila de protocolos, los mecanismos de aislamiento de procesos y los envoltorios de tránsito criptográfico.

```
                   +-------------------------------------------------------------+
                   |                 ENTERPRISE LINUX HOST                       |
                   |                                                             |
                   |  [ USER SPACE ]                                             |
                   |  +------------+   +------------+   +---------------------+  |
                   |  | OpenSSH    |   | OpenVPN    |   | vsftpd (TLS)        |  |
                   |  | Daemon     |   | Daemon     |   | Daemon              |  |
                   |  +-----+------+   +-----+------+   +----------+----------+  |
                   |        |                |                     |             |
                   |        +--------+-------+                     |             |
                   |                 |                             |             |
                   |                 v                             |             |
                   |        +-----------------+                    |             |
                   |        | TCP Wrappers    |                    |             |
                   |        | (/etc/hosts.*)  |                    |             |
                   |        +--------+--------+                    |             |
                   |                 |                             |             |
                   |  ===============|=============================|===========  |
                   |  [ KERNEL SPACE ]                             v             |
                   |                 |               +------------------------+  |
                   |                 +-------------->| Netfilter Hooks        |  |
                   |                                 | (PREROUTING / INPUT /  |  |
                   |                                 |  FORWARD / POSTROUTING)|  |
                   |                                 +-----------+------------+  |
                   |                                             |               |
                   |                                             v               |
                   |                                 +------------------------+  |
                   |                                 | IP Forwarding Engine   |  |
                   |                                 | (net.ipv4.ip_forward)  |  |
                   |                                 +------------------------+  |
                   +-------------------------------------------------------------+
```

### 1.2 El Patrón de Vulnerabilidad de Seguridad en Producción
Al administrar clústeres híbridos cloud-native o bare-metal, los equipos de infraestructura enfrentan puntos críticos de degradación de seguridad:

1. **Reenvío de Paquetes Sin Control:** Dejar habilitado el reenvío de paquetes IPv4 (`net.ipv4.ip_forward = 1`) en hosts que abarcan interfaces de red internas y externas sin un filtrado estricto con firewall de estado expone las redes internas a traversales laterales no autenticados.
2. **Acceso Inseguro al Plano de Control:** Confiar en métodos de autenticación heredados para OpenSSH (por ejemplo, autenticación por contraseña, claves RSA de 1024 bits débiles, algoritmos obsoletos de intercambio de claves SHA-1) deja el vector de administración abierto a credential stuffing, ataques de fuerza bruta y descifrado de tipo man-in-the-middle.
3. **Datos en Tránsito Sin Protección:** Los servicios de transferencia de archivos heredados (FTP sin TLS, NFS sin cifrar, Telnet plano) filtran credenciales y cargas de datos sensibles sobre segmentos de red en texto plano.
4. **Falta de Restricciones de Acceso Por Host:** No filtrar las solicitudes de conexión entrantes tanto en el límite de la red (`netfilter`/`iptables`/`nftables`) como en las capas del envoltorio de la aplicación (`libwrap`/`TCP Wrappers`) priva a los sistemas de redundancia de defensa en profundidad cuando una capa de firewall falla o es eludida.
5. **Malas Configuraciones en la Infraestructura VPN:** Los despliegues de OpenVPN diseñados incorrectamente (falta de firmas de autenticación TLS, cipher suites débiles como BF-CBC, brechas de aislamiento cliente a cliente o mala gestión de certificados de CA) abren la superposición de red interna a compromisos de clientes maliciosos.

---

## 2. Comparativas Técnicas con Compromisos (Trade-Offs)

### 2.1 Frameworks de Control de Red y Firewall
El filtrado de seguridad del kernel de Linux se apoya en hooks de kernel proporcionados por `netfilter`. Comparar los mecanismos de control a nivel de red es crítico al diseñar políticas de seguridad en el host:

| Característica / Métrica | `iptables` (CLI Netfilter Heredado) | `nftables` (Motor Netfilter Moderno) | `TCP Wrappers` (`libwrap.so`) |
| :--- | :--- | :--- | :--- |
| **Capa de Operación** | Capa 3 / Capa 4 (Netfilter en Kernel-space) | Capa 3 / Capa 4 (Máquina Virtual de Bytecode en Kernel-space) | Envoltorio de Aplicación de Capa 7 (User-space enlazado mediante `libwrap`) |
| **Impacto de Rendimiento** | Evaluación lineal (Overhead de búsqueda de reglas $O(N)$) | Evaluación logarítmica ($O(\log N)$ mediante conjuntos, mapas y árboles de decisión) | Despreciable (Evaluado una vez durante la llamada `accept()` de TCP) |
| **Rastreo de Estado** | Sí (Módulo `conntrack`) | Sí (Motor nativo de rastreo de estado) | No (Validación de origen puramente en tiempo de conexión) |
| **Actualizaciones Atómicas** | No atómicas (requiere dump completo de tabla y reemplazo) | Actualizaciones de reglas y lotes de transacciones totalmente atómicos | Parseo instantáneo de archivo por conexión entrante |
| **Soporte de Protocolos** | Herramientas separadas por familia (`iptables`, `ip6tables`, `arptables`, `ebtables`) | Sintaxis unificada para IPv4, IPv6, ARP y Ethernet Bridges | Direcciones IPv4 / IPv6 y nombres de host |
| **Dependencia de Daemon** | Módulo de kernel independiente + servicio de persistencia | Módulo de kernel independiente + `nftables.service` | Requiere que el binario objetivo esté compilado contra `libwrap` |
| **Caso de Uso en Producción** | Despliegues empresariales LPIC-2 heredados, RHEL 7/CentOS 7 heredados | Distribuciones Linux modernas (RHEL 8+, Debian 10+, Ubuntu 20.04+) | Filtrado de acceso a host heredado (`sshd`, `vsftpd`, `xinetd`) |

### 2.2 Tecnologías de Acceso Remoto
Elegir el protocolo adecuado para la gestión remota del sistema e interconexiones de red seguras:

| Métrica / Requisito | OpenSSH (Clave Pública / Certificado) | OpenVPN TUN (Enrutamiento IP Capa 3) | OpenVPN TAP (Bridging Ethernet Capa 2) |
| :--- | :--- | :--- | :--- |
| **Capa OSI** | Capa 7 (Encapsulación de flujo de transporte sobre TCP) | Capa 3 (Túnel Punto a Punto de Red Virtual) | Capa 2 (Adaptador Ethernet Virtual / Túnel de Tramas) |
| **Protocolo de Transporte** | TCP (Puerto 22 por defecto) | UDP (Recomendado) o TCP (Puerto 1194 por defecto) | UDP (Recomendado) o TCP (Puerto 1194 por defecto) |
| **Overhead y MTU** | Overhead moderado de encapsulación TCP | Bajo overhead; MTU ajustable (`mssfix`, `fragment`) | Alto overhead debido a la encapsulación de cabeceras Ethernet puras |
| **Broadcast / Multicast** | No soportado | No soportado (Solo tráfico IP enrutado) | Totalmente Soportado (mDNS, NetBIOS, broadcast ARP sobre el túnel) |
| **Autenticación de Cliente** | Claves Ed25519 / RSA, Certificados SSH, PAM | Certificados PKI x509, TLS-Auth, Usuario/Contraseña | Certificados PKI x509, TLS-Auth, Usuario/Contraseña |
| **Caso de Uso** | Gestión por línea de comandos, shells interactivas, SFTP | Superposición de Red Segura Sitio a Sitio y Trabajadores Remotos | Protocolos heredados no IP, arranque PXE sobre VPN, emulación de LAN |

### 2.3 Protocolos de Transferencia Segura de Archivos
Evaluando opciones de transferencia de archivos para una operación empresarial segura:

| Criterio | FTP Plano (Heredado) | vsftpd con FTPS Explícito (TLS) | SFTP (Subsistema OpenSSH) |
| :--- | :--- | :--- | :--- |
| **Seguridad de Transporte** | Ninguna (Contraseñas y carga útil en texto claro) | Canales de control y datos cifrados con TLS 1.2 / TLS 1.3 | Túnel Cifrado SSHv2 |
| **Puertos de Red Requeridos** | Control: 21/TCP; Datos: 20/TCP o Rango Pasivo | Control: 21/TCP; Datos: Rango Pasivo Ajustable (ej., 40000-50000/TCP) | Puerto SSH único (Por defecto 22/TCP) |
| **Complejidad de Firewall** | Alta (Requiere el módulo `ip_conntrack_ftp` para activo/pasivo) | Alta (Requiere abrir rangos de puertos pasivos explícitos en el firewall) | Baja (Reutiliza las reglas existentes de puertos entrantes SSH) |
| **Aislamiento Chroot Jail** | Varía según la implementación | Mecanismos de aislamiento `chroot()` nativos y robustos | Nativo mediante la directiva `ChrootDirectory` en `sshd_config` |
| **Preparación para Cumplimiento** | No cumple (Falla en PCI-DSS, HIPAA, SOC2) | Cumple cuando la aplicación de SSL/TLS es obligatoria | Totalmente Cumplidor out-of-the-box |

---

## 3. Manifiestos de Configuración Completos de Infraestructura y Sistema

### 3.1 Configuración de Router de Perímetro, NAT y Firewall de Estado
File: `/etc/iptables/rules.v4`  
*Proporciona reenvío IPv4 completo, NAT/Masquerading, protección de conexiones entrantes, reenvío de puertos (DNAT) y aplicación de anti-spoofing.*

```ini
*nat
:PREROUTING ACCEPT [0:0]
:INPUT ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]

# Forward public port 8443 to internal server 10.8.0.50:443 (DNAT Port Forwarding)
-A PREROUTING -i eth0 -p tcp --dport 8443 -j DNAT --to-destination 10.8.0.50:443

# IP Masquerading for outbound internal subnet 10.8.0.0/24 over public interface eth0
-A POSTROUTING -s 10.8.0.0/24 -o eth0 -j MASQUERADE

COMMIT

*filter
:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT ACCEPT [0:0]

# Custom chains for logging and connection management
:TCP-IN - [0:0]
:UDP-IN - [0:0]

# 1. Loopback Interface Enforcement
-A INPUT -i lo -j ACCEPT
-A INPUT ! -i lo -s 127.0.0.0/8 -j DROP

# 2. Stateful Inspection (Allow Established and Related Connections)
-A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
-A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT

# 3. Drop Invalid Packets Immediately
-A INPUT -m state --state INVALID -j DROP
-A FORWARD -m state --state INVALID -j DROP

# 4. Anti-Spoofing & ICMP Rate-Limiting (Max 5 ICMP echo-requests per sec)
-A INPUT -p icmp --icmp-type echo-request -m limit --limit 5/s --limit-burst 10 -j ACCEPT
-A INPUT -p icmp -j ACCEPT

# 5. Route Protocols to Custom Chains
-A INPUT -p tcp -m state --state NEW -j TCP-IN
-A INPUT -p udp -m state --state NEW -j UDP-IN

# 6. TCP Inbound Rules
# Allow SSH on custom port 2222 with rate limiting (brute-force mitigation)
-A TCP-IN -p tcp --dport 2222 -m state --state NEW -m recent --set --name SSH_CHECK
-A TCP-IN -p tcp --dport 2222 -m state --state NEW -m recent --update --seconds 60 --hitcount 4 --name SSH_CHECK -j DROP
-A TCP-IN -p tcp --dport 2222 -j ACCEPT

# Allow OpenVPN management/TLS control if running on TCP 1194
-A TCP-IN -p tcp --dport 1194 -j ACCEPT

# Allow Explicit FTPS Control Port (21) and Passive Data Range (40000:50000)
-A TCP-IN -p tcp --dport 21 -j ACCEPT
-A TCP-IN -p tcp --dport 40000:50000 -j ACCEPT

# 7. UDP Inbound Rules
# Allow OpenVPN primary daemon (1194/UDP)
-A UDP-IN -p udp --dport 1194 -j ACCEPT

# 8. Inter-Zone Forwarding Rules
# Allow internal LAN (eth1) to access External Internet (eth0)
-A FORWARD -i eth1 -o eth0 -s 10.8.0.0/24 -j ACCEPT

# Allow forwarded DNAT traffic to internal web host 10.8.0.50
-A FORWARD -i eth0 -o eth1 -p tcp -d 10.8.0.50 --dport 443 -m state --state NEW -j ACCEPT

# Default Log and Drop for unmatched packets
-A INPUT -m limit --limit 3/m -j LOG --log-prefix "IPTABLES-REJECT-IN: " --log-level 4
-A INPUT -j DROP
-A FORWARD -m limit --limit 3/m -j LOG --log-prefix "IPTABLES-REJECT-FWD: " --log-level 4
-A FORWARD -j DROP

COMMIT
```

Kernel Routing Configuration Persistence File: `/etc/sysctl.d/99-routing-security.conf`

```ini
# Enable IPv4 Packet Forwarding across interfaces
net.ipv4.ip_forward = 1

# Disable IPv6 Packet Forwarding unless explicitly routing IPv6
net.ipv6.conf.all.forwarding = 0

# Ignore ICMP Echo Requests (Optional - set to 0 to enable strict rate limiting via firewall)
net.ipv4.icmp_echo_ignore_broadcasts = 1

# Disable IP Source Routing (Prevents malicious route injection)
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0

# Ignore ICMP Redirect Messages (Mitigates Man-in-the-Middle route alteration)
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# Enable Reverse Path Filtering (Strict mode - mitigates IP spoofing)
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Log Martians (Packets with impossible source/destination addresses)
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
```

---

### 3.2 Configuración Endurecida del Daemon OpenSSH
File: `/etc/ssh/sshd_config.d/production-hardening.conf`  
*Implementa primitivas criptográficas strictly, restricciones de inicio de sesión de root, encarcelamiento de aislamiento de usuarios y aplicación de banners.*

```ini
# Port and Protocol Definition
Port 2222
Protocol 2
AddressFamily inet
ListenAddress 0.0.0.0

# Cryptographic Algorithms Hardening (Disable weak ciphers, MACs, and KEX)
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com

# Host Keys Configuration
HostKey /etc/ssh/ssh_host_ed25519_key
HostKey /etc/ssh/ssh_host_rsa_key

# Authentication Policy
PermitRootLogin no
MaxAuthTries 3
MaxSessions 5
PubkeyAuthentication yes
PasswordAuthentication no
PermitEmptyPasswords no
ChallengeResponseAuthentication no
KerberosAuthentication no
GSSAPIAuthentication no
UsePAM yes

# Session Security & Environment
X11Forwarding no
AllowTcpForwarding remote
AllowAgentForwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
LoginGraceTime 30
MaxStartups 10:30:100

# Access Restrictions & Banners
Banner /etc/issue.net
AllowGroups sysadmins devops sftpusers

# SFTP Chroot Jail Subsystem Configuration for sftpusers group
Subsystem sftp internal-sftp -l INFO -f LOCAL6

Match Group sftpusers
    ChrootDirectory /var/sftp/%u
    ForceCommand internal-sftp -d /upload
    X11Forwarding no
    AllowTcpForwarding no
    AllowAgentForwarding no
    PasswordAuthentication no
    PubkeyAuthentication yes
```

---

### 3.3 Manifiesto del Servidor OpenVPN de Grado de Producción
File: `/etc/openvpn/server/production-tun0.conf`  
*Implementa una topología VPN TUN de Capa 3 robusta, aislamiento TLS-Crypt, reducción de privilegios de usuario y envío de rutas.*

```ini
# Network Interface and Protocol Definitions
mode server
tls-server
port 1194
proto udp
dev tun0

# Cryptographic Keys and Public Key Infrastructure (PKI)
ca /etc/openvpn/server/pki/ca.crt
cert /etc/openvpn/server/pki/issued/vpn-server.crt
key /etc/openvpn/server/pki/private/vpn-server.key
dh /etc/openvpn/server/pki/dh.pem
tls-crypt /etc/openvpn/server/pki/tls-crypt.key

# Network Topology and Subnet Addressing
topology subnet
server 10.200.0.0 255.255.255.0
ifconfig-pool-persist /var/log/openvpn/ipp.txt

# Push Routes to Clients for Internal Network Access
push "route 10.8.0.0 255.255.255.0"
push "route 172.16.0.0 255.255.0.0"

# Push Security DNS Servers (Cloudflare Secure Primary/Secondary)
push "dhcp-option DNS 1.1.1.1"
push "dhcp-option DNS 1.0.0.1"

# Client Isolation & Inter-Client Policy
client-to-client

# Tunnel Maintenance and Keepalive (Ping every 10 sec, restart if missing for 120 sec)
keepalive 10 120

# Cipher and Data Channel Security (AES-256-GCM preferred)
cipher AES-256-GCM
data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
auth SHA384

# Privilege Demotion for Security Hardening
user nobody
group nogroup

# Persistence Options Across Restarts
persist-key
persist-tun

# Logging and Status Monitoring
status /var/log/openvpn/openvpn-status.log 1
log-append /var/log/openvpn/openvpn.log
verb 3
mute 20
```

---

### 3.4 Configuración Endurecida del Servidor vsftpd con TLS y Chroot Jails
File: `/etc/vsftpd/vsftpd.conf`  
*Despliegue de FTP seguro que aplica cifrado TLS Explícito, aislamiento de usuarios locales y restricciones de rango dinámico de puertos pasivos.*

```ini
# General Server Settings
listen=YES
listen_ipv6=NO
anonymous_enable=NO
local_enable=YES
write_enable=YES
local_umask=022
dirmessage_enable=YES
use_localtime=YES
xferlog_enable=YES
xferlog_std_format=YES
xferlog_file=/var/log/vsftpd.log
connect_from_port_20=YES
ftpd_banner=Welcome to Production Secure Storage Node. Unauthorized access prohibited.

# Chroot Jail Environment Configuration
chroot_local_user=YES
chroot_list_enable=YES
chroot_list_file=/etc/vsftpd/chroot_list
allow_writeable_chroot=NO
secure_chroot_dir=/var/run/vsftpd/empty

# User Isolation Path (Maps user home directory to secure isolated path)
user_sub_token=$USER
local_root=/var/ftp_root/$USER

# Passive Mode Network Rules (Mandatory for Firewalls/NAT)
pasv_enable=YES
pasv_min_port=40000
pasv_max_port=50000
pasv_address=198.51.100.10
pasv_addr_resolve=NO

# Explicit SSL/TLS Encryption Hardening
ssl_enable=YES
allow_anon_ssl=NO
force_local_data_ssl=YES
force_local_logins_ssl=YES
ssl_tlsv1_2=YES
ssl_tlsv1_3=YES
ssl_sslv2=NO
ssl_sslv3=NO
rsa_cert_file=/etc/ssl/certs/vsftpd-production.crt
rsa_private_key_file=/etc/ssl/private/vsftpd-production.key
ssl_ciphers=ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384
require_ssl_reuse=NO

# Access Control Lists
userlist_enable=YES
userlist_file=/etc/vsftpd/user_list
userlist_deny=NO
```

---

### 3.5 Aplicación de Políticas de Acceso TCP Wrappers
Files: `/etc/hosts.allow` and `/etc/hosts.deny`  
*Implementa control de acceso basado en host mediante `libwrap.so` (capa de seguridad heredada requerida para la conformidad con LPIC-2).*

File: `/etc/hosts.allow`
```ini
# /etc/hosts.allow: Access control rules for tcpd-enabled daemons.

# Allow OpenSSH access only from internal management subnets and trusted bastion
sshd : 10.8.0.0/255.255.255.0 , 192.168.1.50 , 172.16.10.0/255.255.255.0 : ALLOW

# Allow vsftpd access from localized internal network segments
vsftpd : 10.8.0.0/255.255.255.0 : ALLOW

# Execute custom logging alert script upon successful connection to Portmap/RPC
portmap : 192.168.1.0/255.255.255.0 : spawn /usr/local/bin/log_wrapper_access.sh %a %d %p : ALLOW
```

File: `/etc/hosts.deny`
```ini
# /etc/hosts.deny: Fallback deny-all access policy.

# Deny all remaining services and hosts, log violation to syslog
ALL : ALL : spawn /usr/bin/logger -p daemon.warning "TCP-WRAPPERS-DENY: Unauthorized connection attempt from %h (%a) to daemon %d" : DENY
```

---

## 4. Real CLI Commands and Terminal Outputs ($)

### 4.1 Kernel IP Forwarding, Route Management & NAT Verification
Executing kernel parameter updates and manipulating iptables rules live.

```bash
$ sudo sysctl -w net.ipv4.ip_forward=1
net.ipv4.ip_forward = 1

$ sudo sysctl -p /etc/sysctl.d/99-routing-security.conf
net.ipv4.ip_forward = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.log_martians = 1

$ sudo iptables -t nat -A POSTROUTING -o eth0 -s 10.8.0.0/24 -j MASQUERADE
$ sudo iptables -t nat -L POSTROUTING -v -n --line-numbers
Chain POSTROUTING (policy ACCEPT 42 packets, 2856 bytes)
num   pkts bytes target     prot opt in     out     source               destination         
1      128  8412 MASQUERADE  all  --  *      eth0    10.8.0.0/24          0.0.0.0/0           

$ ip route show
default via 198.51.100.1 dev eth0 proto static metric 100 
10.8.0.0/24 dev eth1 proto kernel scope link src 10.8.0.1 
198.51.100.0/24 dev eth0 proto kernel scope link src 198.51.100.10 
```

---

### 4.2 OpenSSH Cryptographic Key Generation, Fingerprint Auditing & Port Forwarding
Generating secure Ed25519 SSH keypairs and establishing local/remote SSH tunnels.

```bash
$ ssh-keygen -t ed25519 -a 100 -C "admin-key-prod-2026" -f ~/.ssh/id_ed25519_prod
Generating public/private ed25519 key pair.
Enter passphrase (empty for no passphrase): 
Enter same passphrase again: 
Your identification has been saved in /home/sysadmin/.ssh/id_ed25519_prod
Your public key has been saved in /home/sysadmin/.ssh/id_ed25519_prod.pub
The key fingerprint is:
SHA256:d8N7xZ9v2kU4mWqL8jP1aR5tY7uI9oO0pQ3sT6uV8wX admin-key-prod-2026
The key's randomart image is:
+--[ED25519 256]--+
|    ..  .+++=.   |
|   .  .  o++o.   |
|    .  . o.o.    |
|   .    o *.     |
|    .   SB.* .   |
|     o E .B.+    |
|    . + . oo     |
|     + o..       |
|      +.+o       |
+-----------------+

$ ssh-keygen -lf ~/.ssh/id_ed25519_prod.pub
256 SHA256:d8N7xZ9v2kU4mWqL8jP1aR5tY7uI9oO0pQ3sT6uV8wX admin-key-prod-2026 (ED25519)

$ ssh -i ~/.ssh/id_ed25519_prod -p 2222 -L 8080:10.8.0.50:80 sysadmin@198.51.100.10 -N -f
$ ss -tulpn | grep 8080
tcp   LISTEN 0      128        127.0.0.1:8080      0.0.0.0:*    users:(("ssh",pid=14502,fd=4))
```

---

### 4.3 OpenVPN PKI Generation and Daemon Status Diagnostics
Initializing Easy-RSA PKI engine, creating server certificates, and verifying daemon state.

```bash
$ cd /etc/openvpn/server/easy-rsa
$ ./easyrsa init-pki

Notice
------
'init-pki' complete; you may now create a CA or requests.
Your newly created PKI dir is: /etc/openvpn/server/easy-rsa/pki

$ ./easyrsa build-ca nopass
Using Easy-RSA configuration from: ./vars
Notice
------
CA creation complete. Your new CA certificate is at:
/etc/openvpn/server/easy-rsa/pki/ca.crt

$ ./easyrsa gen-req vpn-server nopass
Notice
------
Keypair created. Request file is at:
/etc/openvpn/server/easy-rsa/pki/reqs/vpn-server.req

$ ./easyrsa sign-req server vpn-server
Type the word 'yes' to continue, or any other input to abort.
  Confirm request details: yes
Notice
------
Certificate created at: /etc/openvpn/server/easy-rsa/pki/issued/vpn-server.crt

$ openvpn --genkey secret /etc/openvpn/server/pki/tls-crypt.key

$ sudo systemctl status openvpn-server@production-tun0
● openvpn-server@production-tun0.service - OpenVPN service for production-tun0
     Loaded: loaded (/lib/systemd/system/openvpn-server@.service; enabled; vendor preset: enabled)
     Active: active (running) since Thu 2026-08-06 10:15:22 UTC; 25min ago
       Docs: man:openvpn(8)
             https://community.openvpn.net/openvpn/wiki/Openvpn24ManPage
   Main PID: 18920 (openvpn)
     Status: "Initialization Sequence Completed"
      Tasks: 1 (limit: 4915)
     Memory: 4.8M
        CPU: 145ms
     CGroup: /system.slice/system-openvpn\x2dserver.slice/openvpn-server@production-tun0.service
             └─18920 /usr/sbin/openvpn --status /run/openvpn-server/status-production-tun0.log 1 --status-version 2 --suppress-timestamps --config production-tun0.conf

Aug 06 10:15:22 gateway-01 openvpn[18920]: /sbin/ip link set dev tun0 up mtu 1500
Aug 06 10:15:22 gateway-01 openvpn[18920]: /sbin/ip addr add dev tun0 10.200.0.1/24
Aug 06 10:15:22 gateway-01 openvpn[18920]: Could not determine IPv6 tunnel endpoint address. Dynamic IPv6 tunnel addresses may not work.
Aug 06 10:15:22 gateway-01 openvpn[18920]: UDPv4 link socket binding on [AF_INET][UNDEF]:1194
Aug 06 10:15:22 gateway-01 openvpn[18920]: Initialization Sequence Completed
```

---

### 4.4 Port Auditing, TCP Wrappers Tracing & SUID Security Auditing
Auditing socket listeners, testing TCP wrappers libraries, and locating risky privileged binaries.

```bash
$ sudo ss -tulpn
Netid  State   Recv-Q  Send-Q     Local Address:Port      Peer Address:Port  Process                                                                         
udp    UNCONN  0       0                0.0.0.0:1194           0.0.0.0:*      users:(("openvpn",pid=18920,fd=6))                                              
tcp    LISTEN  0       32               0.0.0.0:21             0.0.0.0:*      users:(("vsftpd",pid=1204,fd=3))                                                
tcp    LISTEN  0       128              0.0.0.0:2222           0.0.0.0:*      users:(("sshd",pid=912,fd=3))                                                   

$ ldd /usr/sbin/sshd | grep libwrap
	libwrap.so.0 => /lib/x86_64-linux-gnu/libwrap.so.0 (0x00007f8b9c100000)

$ tcpdmatch sshd 192.168.1.50
client:   address  192.168.1.50
server:   process  sshd
access:   granted

$ tcpdmatch sshd 203.0.113.99
client:   address  203.0.113.99
server:   process  sshd
access:   denied

$ sudo find / -xdev \( -perm -4000 -o -perm -2000 \) -type f -ls
   131078     56 -rwsr-xr-x   1 root     root        55528 Jan 20 2026 /usr/bin/umount
   131075     84 -rwsr-xr-x   1 root     root        84968 Jan 20 2026 /usr/bin/gpasswd
   131089     68 -rwsr-xr-x   1 root     root        67816 Jan 20 2026 /usr/bin/passwd
   131082     44 -rwsr-xr-x   1 root     root        44528 Jan 20 2026 /usr/bin/newgrp
   131074    156 -rwsr-xr-x   1 root     root       158240 Jan 20 2026 /usr/bin/sudo
   131090     88 -rwsr-xr-x   1 root     root        88464 Jan 20 2026 /usr/bin/chfn
   131080     84 -rwsr-xr-x   1 root     root        85088 Jan 20 2026 /usr/bin/chsh
```

---

## 5. Guía de Verificación y Diagnóstico de Fallos

### 5.1 Diagrama de Flujo de Diagnóstico: Enrutamiento IP y Traversal NAT en Firewall

```
                             [ PAC KET LOSS / NAT FAILURE ]
                                           |
                                           v
                       Is net.ipv4.ip_forward set to 1?
                                   /               \
                             (NO) /                 \ (YES)
                                 v                   v
                     Run: sysctl -w            Check IPTables FORWARD Chain
                     net.ipv4.ip_forward=1     (iptables -L FORWARD -v -n)
                                                     /               \
                                            (DROP)  /                 \ (ACCEPT)
                                                   v                   v
                                      Add rule: -A FORWARD       Verify MASQUERADE / DNAT
                                      -i eth1 -o eth0 -j ACCEPT  in NAT Table
                                                                 (iptables -t nat -L -v -n)
                                                                       /          \
                                                              (MISSING)            (PRESENT)
                                                                  /                    \
                                                                 v                      v
                                                    Add rule: -t nat -A          Check conntrack state
                                                    POSTROUTING -j MASQUERADE    dmesg | grep conntrack
```

---

### 5.2 Escenarios de Fallo Comunes en Producción y Soluciones

#### Escenario A: `Permission denied (publickey)` de OpenSSH y Fallos de Chroot
* **Síntoma:** El cliente al intentar una conexión SSH es rechazado instantáneamente con `Permission denied (publickey)`. El log del servidor (`/var/log/auth.log` o `journalctl -u ssh`) muestra: `Authentication refused: bad ownership or modes for directory /home/sysadmin/.ssh` o `fatal: bad ownership or modes for chroot directory /var/sftp/user1`.
* **Análisis de Causa Raíz:**
  1. OpenSSH aplica una verificación estricta de permisos en los directorios home del usuario y `.ssh` (`StrictModes yes`).
  2. Para la funcionalidad de SFTP Chroot (`ChrootDirectory`), OpenSSH exige que **cada directorio componente en la ruta que conduce al directorio chroot deba ser propiedad strictly de `root:root`** y **no debe ser escribible por ningún otro usuario o grupo** (permisos máximos `0755`).
* **Pasos de Remediación:**

```bash
# 1. Fix SSH User Home & Key Permissions
$ chmod 700 /home/sysadmin/.ssh
$ chmod 600 /home/sysadmin/.ssh/authorized_keys
$ chown -R sysadmin:sysadmin /home/sysadmin/.ssh

# 2. Fix SFTP Chroot Directory Ownership (Root mandatory for parent directory)
$ sudo chown root:root /var/sftp/user1
$ sudo chmod 755 /var/sftp/user1

# 3. Create explicit writeable subdirectory inside chroot for upload
$ sudo mkdir -p /var/sftp/user1/upload
$ sudo chown user1:sftpusers /var/sftp/user1/upload
$ sudo chmod 775 /var/sftp/user1/upload
```

---

#### Escenario B: Timeout de Handshake de Certificado / TLS Crypt de OpenVPN
* **Síntoma:** La conexión de OpenVPN se cuelga durante la negociación del cliente y expira con el error: `TLS Error: TLS key negotiation failed to occur within 60 seconds (check your network connectivity)`.
* **Análisis de Causa Raíz:**
  1. El firewall (`iptables` / `nftables`) en el gateway de VPN está descartando los paquetes UDP 1194 entrantes.
  2. Discrepancia entre servidor y cliente respecto a las directivas de configuración `tls-auth` vs `tls-crypt`.
  3. Desfase de hora del sistema en el cliente o servidor provocando el fallo en la verificación de validez del certificado x509 (`certificate is not yet valid` o `certificate has expired`).
* **Pasos de Remediación:**

```bash
# 1. Verify UDP 1194 Socket Binding
$ sudo ss -ulpn | grep 1194

# 2. Verify Firewall Rule for UDP 1194
$ sudo iptables -L UDP-IN -v -n
# If rule missing, insert rule at top of chain:
$ sudo iptables -I INPUT 1 -p udp --dport 1194 -j ACCEPT

# 3. Verify System Clock Synchronization (NTP/chrony)
$ timedatectl status
# Force clock sync if out of sync
$ sudo chronyc tracking

# 4. Check OpenVPN Detailed Server Logs
$ sudo tail -f -n 100 /var/log/openvpn/openvpn.log
```

---

#### Escenario C: La Conexión en Modo Pasivo de FTP TLS se Cuelga (Bloqueo de `MLSD` o `LIST`)
* **Síntoma:** El usuario se autentica con éxito a través del canal de control de FTPS (Puerto 21), pero el cliente se congela al emitir el comando `PASV`, `LIST` o `STOR`, expirando finalmente con `425 Can't open data connection`.
* **Análisis de Causa Raíz:**
  1. FTPS explícito cifra tanto el flujo de control como el de datos. Los helpers de inspección de firewall con estado (tales como `nf_conntrack_ftp`) no pueden leer comandos de control cifrados para abrir dinámicamente puertos de datos pasivos.
  2. El rango de puertos pasivos configurado en `vsftpd.conf` (`pasv_min_port` y `pasv_max_port`) está bloqueado por reglas de firewall externas o del host.
  3. El servidor se encuentra detrás de un dispositivo NAT, y `vsftpd` devuelve su dirección IP privada interna en respuesta al comando `PASV` en lugar de su IP pública/elástica (`pasv_address`).
* **Pasos de Remediación:**

```bash
# 1. Ensure passive port range is opened in iptables
$ sudo iptables -A INPUT -p tcp --dport 40000:50000 -j ACCEPT

# 2. Configure Public IP override in /etc/vsftpd/vsftpd.conf
pasv_enable=YES
pasv_min_port=40000
pasv_max_port=50000
pasv_address=198.51.100.10

# 3. Restart vsftpd daemon
$ sudo systemctl restart vsftpd
```

---

#### Escenario D: Rechazo de Acceso de TCP Wrappers y Depuración
* **Síntoma:** El intento de conexión del cliente a `sshd` o `vsftpd` se interrumpe abruptamente de inmediato tras el handshake de TCP (`Connection closed by remote host`), mientras el servicio está escuchando y los firewalls aceptan el paquete.
* **Análisis de Causa Raíz:**
  El binario del daemon está enlazado con `libwrap.so`, y la dirección IP del cliente no coincide con ninguna regla explícita de `ALLOW` en `/etc/hosts.allow`, lo que desencadena la regla de bloqueo comodín en `/etc/hosts.deny`.
* **Pasos de Remediación:**

```bash
# 1. Verify if binary supports TCP Wrappers
$ ldd /usr/sbin/vsftpd | grep libwrap

# 2. Test rule matching using tcpdmatch tool
$ tcpdmatch vsftpd 10.8.0.105
client:   address  10.8.0.105
server:   process  vsftpd
access:   denied

# 3. Add explicit subnet permit rule to /etc/hosts.allow
vsftpd : 10.8.0.0/255.255.255.0 : ALLOW

# 4. Monitor Syslog for TCP Wrappers Drop Notifications
$ sudo tail -f /var/log/syslog | grep TCP-WRAPPERS-DENY
```

---

## 6. Referencias

* **Objetivos Oficiales de LPIC-2 de Linux Professional Institute (LPI):**  
  [https://www.lpi.org/our-certifications/lpic-2-overview/](https://www.lpi.org/our-certifications/lpic-2-overview/)
* **Documentación Oficial de Netfilter / iptables y Arquitectura de Filtrado de Paquetes:**  
  [https://netfilter.org/documentation/](https://netfilter.org/documentation/)
* **Manual Oficial de OpenSSH, Mejores Prácticas de Seguridad y Páginas de Manual de Configuración:**  
  [https://www.openssh.com/manual.html](https://www.openssh.com/manual.html)
* **Documentación de la Comunidad OpenVPN y Guías Prácticas (How-To):**  
  [https://openvpn.net/community-resources/](https://openvpn.net/community-resources/)
* **Documentación del Sysctl IP del Kernel de Linux (parámetros `net.ipv4.*`):**  
  [https://www.kernel.org/doc/Documentation/networking/ip-sysctl.txt](https://www.kernel.org/doc/Documentation/networking/ip-sysctl.txt)
* **Referencia Formal de Configuración de vsftpd y Guía TLS/SSL:**  
  [https://security.appspot.com/vsftpd/vsftpd_conf.html](https://security.appspot.com/vsftpd/vsftpd_conf.html)
* **NIST SP 800-123 (Guía para la Seguridad General de Servidores):**  
  [https://csrc.nist.gov/publications/detail/sp/800-123/final](https://csrc.nist.gov/publications/detail/sp/800-123/final)