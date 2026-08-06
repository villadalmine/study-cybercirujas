# LPIC-2 (202-450) Topic 2.6 / 212: System Security — Advanced Production Study Guide

**Target Certification:** LPIC-2 (Exam 202-450, Version 4.5)  
**Topic:** 212 / 2.6 — System Security  
**Weight:** 9  
**Target Audience:** SREs, Platform Architects, and Senior Linux System Administrators  

---

## 1. Motivation and Production Architectural Problem

### 1.1 Enterprise Edge Security & Network Isolation
In modern production Linux infrastructure, servers operate as perimeter gateways, multi-tenant ingress nodes, or secured bastion hosts. System security is not merely a collection of isolated configuration toggles; it forms an interconnected defense-in-depth architectural boundary across kernel space, protocol stack handlers, process isolation mechanisms, and cryptographic transit wrappers.

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

### 1.2 The Production Security Vulnerability Pattern
When managing cloud-native or bare-metal hybrid clusters, infrastructure teams face critical security degradation points:

1. **Unchecked Packet Routing:** Leaving IPv4 packet forwarding enabled (`net.ipv4.ip_forward = 1`) on hosts spanning internal and external network interfaces without strict stateful firewall filtering exposes internal networks to unauthenticated lateral traversal.
2. **Insecure Control Plane Access:** Relying on legacy authentication methods for OpenSSH (e.g., password auth, weak RSA 1024-bit keys, obsolete SHA-1 key exchange algorithms) leaves administration vector open to credential stuffing, brute-forcing, and man-in-the-middle decryption.
3. **Unprotected Data-in-Transit:** Legacy file transfer services (FTP without TLS, unencrypted NFS, plain Telnet) leak credentials and sensitive payloads over plain-text network segments.
4. **Lack of Per-Host Access Constraints:** Failing to filter inbound connection requests at both the network boundary (`netfilter`/`iptables`/`nftables`) and application wrapper layers (`libwrap`/`TCP Wrappers`) deprives systems of defense-in-depth redundancy when one firewall layer fails or is bypassed.
5. **VPN Infrastructure Misconfigurations:** Improperly designed OpenVPN deployments (missing TLS authentication signatures, weak cipher suites like BF-CBC, client-to-client isolation gaps, or poor CA certificate management) open the inner network overlay to rogue client compromise.

---

## 2. Technical Comparisons with Trade-Offs

### 2.1 Network Control & Firewall Frameworks
Linux kernel security filtering relies on kernel hooks provided by `netfilter`. Comparing network-level control mechanisms is critical when designing host security policies:

| Feature / Metric | `iptables` (Legacy Netfilter CLI) | `nftables` (Modern Netfilter Engine) | `TCP Wrappers` (`libwrap.so`) |
| :--- | :--- | :--- | :--- |
| **Operating Layer** | Layer 3 / Layer 4 (Kernel-space Netfilter) | Layer 3 / Layer 4 (Kernel-space Bytecode Virtual Machine) | Layer 7 Application Wrapper (User-space linked via `libwrap`) |
| **Performance Impact** | Linear evaluation ($O(N)$ rule lookup overhead) | Logarithmic evaluation ($O(\log N)$ via sets, maps, and decision trees) | Negligible (Evaluated once during TCP `accept()` call) |
| **Stateful Tracking** | Yes (`conntrack` module) | Yes (Native stateful tracking engine) | No (Purely connection-time source validation) |
| **Atomic Updates** | Non-atomic (requires full table dump and replace) | Fully atomic rule updates and transaction batches | Instant file parse per incoming connection |
| **Protocol Support** | Separate tools per family (`iptables`, `ip6tables`, `arptables`, `ebtables`) | Unified syntax for IPv4, IPv6, ARP, and Ethernet Bridges | IPv4 / IPv6 addresses and hostnames |
| **Daemon Dependence** | Standalone kernel module + persistence service | Standalone kernel module + `nftables.service` | Requires target binary to be compiled against `libwrap` |
| **Production Use Case** | Legacy LPIC-2 enterprise deployments, legacy RHEL 7/CentOS 7 | Modern Linux distros (RHEL 8+, Debian 10+, Ubuntu 20.04+) | Legacy host access filtering (`sshd`, `vsftpd`, `xinetd`) |

### 2.2 Remote Access Technologies
Choosing the appropriate protocol for remote system management and secure network interconnects:

| Metric / Requirement | OpenSSH (Public Key / Certificate) | OpenVPN TUN (Layer 3 IP Routing) | OpenVPN TAP (Layer 2 Ethernet Bridging) |
| :--- | :--- | :--- | :--- |
| **OSI Layer** | Layer 7 (Transport stream encapsulation over TCP) | Layer 3 (Virtual Network Point-to-Point Tunnel) | Layer 2 (Virtual Ethernet Adapter / Frame Tunnel) |
| **Transport Protocol** | TCP (Port 22 by default) | UDP (Recommended) or TCP (Port 1194 default) | UDP (Recommended) or TCP (Port 1194 default) |
| **Overhead & MTU** | Moderate TCP encapsulation overhead | Low overhead; tunable MTU (`mssfix`, `fragment`) | High overhead due to raw Ethernet header encapsulation |
| **Broadcast / Multicast** | Unsupported | Unsupported (Routed IP traffic only) | Fully Supported (mDNS, NetBIOS, ARP broadcast over tunnel) |
| **Client Authentication** | Ed25519 / RSA Keys, SSH Certificates, PAM | x509 PKI Certificates, TLS-Auth, User/Password | x509 PKI Certificates, TLS-Auth, User/Password |
| **Use Case** | Command-line management, interactive shells, SFTP | Secure Site-to-Site & Remote Worker Network Overlay | Legacy non-IP protocols, PXE boot over VPN, LAN emulation |

### 2.3 Secure File Transfer Protocols
Evaluating file transfer options for secure enterprise operation:

| Criterion | Plain FTP (Legacy) | vsftpd with Explicit FTPS (TLS) | SFTP (OpenSSH Subsystem) |
| :--- | :--- | :--- | :--- |
| **Transport Security** | None (Cleartext passwords and payload) | TLS 1.2 / TLS 1.3 encrypted control & data channels | SSHv2 Encrypted Tunnel |
| **Network Ports Required** | Control: 21/TCP; Data: 20/TCP or Passive Range | Control: 21/TCP; Data: Tunable Passive Range (e.g., 40000-50000/TCP) | Single SSH port (Default 22/TCP) |
| **Firewall Complexity** | High (Requires `ip_conntrack_ftp` module for active/passive) | High (Requires opening explicit passive port ranges in firewall) | Low (Reuses existing SSH inbound port rules) |
| **Chroot Jail Isolation** | Varies by implementation | Native, robust `chroot()` isolation mechanisms | Native via `ChrootDirectory` directive in `sshd_config` |
| **Compliance Readiness** | Non-compliant (Fails PCI-DSS, HIPAA, SOC2) | Compliant when SSL/TLS enforcement is mandated | Fully Compliant out-of-the-box |

---

## 3. Complete Infrastructure & System Configuration Manifests

### 3.1 Perimeter Router, NAT & Stateful Firewall Configuration
File: `/etc/iptables/rules.v4`  
*Provides complete IPv4 forwarding, NAT/Masquerading, incoming connection protection, port forwarding (DNAT), and anti-spoofing enforcement.*

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

### 3.2 Hardened OpenSSH Daemon Configuration
File: `/etc/ssh/sshd_config.d/production-hardening.conf`  
*Implements strict cryptographic primitives, root login restrictions, user isolation jailing, and banner enforcement.*

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

### 3.3 Production-Grade OpenVPN Server Manifest
File: `/etc/openvpn/server/production-tun0.conf`  
*Implements robust Layer-3 TUN VPN topology, TLS-Crypt isolation, user privilege lowering, and route pushing.*

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

### 3.4 Hardened vsftpd Server Configuration with TLS & Chroot Jails
File: `/etc/vsftpd/vsftpd.conf`  
*Secure FTP deployment enforcing Explicit TLS encryption, local user isolation, and dynamic passive port range constraints.*

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

### 3.5 TCP Wrappers Access Policy Enforcement
Files: `/etc/hosts.allow` and `/etc/hosts.deny`  
*Implements host-based access control via `libwrap.so` (legacy security layer required for LPIC-2 compliance).*

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

## 5. Verification and Failure Diagnostics Guide

### 5.1 Diagnostic Flowchart: IP Routing & Firewall NAT Traversal

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

### 5.2 Common Production Failure Scenarios & Solutions

#### Scenario A: OpenSSH `Permission denied (publickey)` & Chroot Failures
* **Symptom:** Client attempting SSH connection gets rejected instantly with `Permission denied (publickey)`. Server log (`/var/log/auth.log` or `journalctl -u ssh`) displays: `Authentication refused: bad ownership or modes for directory /home/sysadmin/.ssh` or `fatal: bad ownership or modes for chroot directory /var/sftp/user1`.
* **Root Cause Analysis:**
  1. OpenSSH enforces strict permission checking on user homes and `.ssh` directories (`StrictModes yes`).
  2. For SFTP Chroot functionality (`ChrootDirectory`), OpenSSH mandates that **every component directory in the path leading up to the chroot directory must be owned strictly by `root:root`** and must **not be writeable by any other user or group** (max permissions `0755`).
* **Remediation Steps:**

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

#### Scenario B: OpenVPN TLS Crypt / Certificate Handshake Timeout
* **Symptom:** OpenVPN connection hangs during client negotiation and times out with error: `TLS Error: TLS key negotiation failed to occur within 60 seconds (check your network connectivity)`.
* **Root Cause Analysis:**
  1. The firewall (`iptables` / `nftables`) on the VPN gateway is dropping incoming UDP 1194 packets.
  2. Mismatch between server and client regarding `tls-auth` vs `tls-crypt` configuration directives.
  3. System time drift on client or server causing x509 certificate validity check failure (`certificate is not yet valid` or `certificate has expired`).
* **Remediation Steps:**

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

#### Scenario C: FTP TLS Passive Mode Connection Hangs (`MLSD` or `LIST` Freeze)
* **Symptom:** User authenticates successfully via FTPS control channel (Port 21), but the client freezes when issuing command `PASV`, `LIST`, or `STOR`, eventually timing out with `425 Can't open data connection`.
* **Root Cause Analysis:**
  1. Explicit FTPS encrypts both control and data streams. Stateful firewall inspection helpers (such as `nf_conntrack_ftp`) cannot read encrypted control commands to dynamically open passive data ports.
  2. The passive port range configured in `vsftpd.conf` (`pasv_min_port` and `pasv_max_port`) is blocked by external or host firewall rules.
  3. The server sits behind a NAT device, and `vsftpd` returns its internal private IP address in response to the `PASV` command instead of its public Elastic/Public IP (`pasv_address`).
* **Remediation Steps:**

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

#### Scenario D: TCP Wrappers Access Rejection & Debugging
* **Symptom:** Client connection attempt to `sshd` or `vsftpd` gets abruptly dropped immediately after TCP handshake (`Connection closed by remote host`), while service is listening and firewalls accept the packet.
* **Root Cause Analysis:**
  The daemon binary is linked with `libwrap.so`, and the client IP address fails to match any explicit `ALLOW` rule in `/etc/hosts.allow`, triggering the wildcard block rule in `/etc/hosts.deny`.
* **Remediation Steps:**

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

## 6. References

* **Linux Professional Institute (LPI) LPIC-2 Official Objectives:**  
  [https://www.lpi.org/our-certifications/lpic-2-overview/](https://www.lpi.org/our-certifications/lpic-2-overview/)
* **Netfilter / iptables Official Documentation & Packet Filtering Architecture:**  
  [https://netfilter.org/documentation/](https://netfilter.org/documentation/)
* **OpenSSH Official Manual, Security Best Practices & Configuration Manual Pages:**  
  [https://www.openssh.com/manual.html](https://www.openssh.com/manual.html)
* **OpenVPN Community Documentation & How-To Guides:**  
  [https://openvpn.net/community-resources/](https://openvpn.net/community-resources/)
* **Linux Kernel IP Sysctl Documentation (`net.ipv4.*` parameters):**  
  [https://www.kernel.org/doc/Documentation/networking/ip-sysctl.txt](https://www.kernel.org/doc/Documentation/networking/ip-sysctl.txt)
* **vsftpd Formal Configuration Reference & TLS/SSL Guidance:**  
  [https://security.appspot.com/vsftpd/vsftpd_conf.html](https://security.appspot.com/vsftpd/vsftpd_conf.html)
* **NIST SP 800-123 (Guide to General Server Security):**  
  [https://csrc.nist.gov/publications/detail/sp/800-123/final](https://csrc.nist.gov/publications/detail/sp/800-123/final)