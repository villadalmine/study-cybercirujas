# Topic 2.5: Networking Fundamentals (LPIC-1)

## 1. Motivation and Production Architectural Problem

Networking is the nervous system of any distributed architecture. In production, an SRE or Platform Architect must understand the physical and logical pathways data takes between microservices, load balancers, and external clients. If a service cannot resolve a DNS name, if a route is missing, or if an MTU mismatch causes packet fragmentation and dropped connections, the entire application stack can degrade.

The architectural problem is moving from fragile, manual network configurations to persistent, declarative networking that survives reboots and dynamically adapts to infrastructure changes (like IP mobility in Kubernetes). You must deeply understand the OSI model—specifically Layers 3 (Network) and 4 (Transport)—to effectively debug routing loops, DNS resolution timeouts (`systemd-resolved`), and socket exhaustion states (`ss`, `netstat`).

## 2. Technical Comparisons and Trade-offs

### Transport Protocols: TCP vs. UDP

| Feature | TCP (Transmission Control Protocol) | UDP (User Datagram Protocol) |
| :--- | :--- | :--- |
| **Connection State** | Connection-oriented (3-way handshake). | Connectionless (fire and forget). |
| **Reliability** | High (acknowledgments, retransmissions, ordering). | None (packets can be dropped or arrive out of order). |
| **Overhead** | Higher latency and header size (20+ bytes). | Low latency and small header (8 bytes). |
| **Production Use Cases**| HTTP/HTTPS, SSH, Database connections (PostgreSQL). | DNS queries, StatsD metrics, Video streaming, QUIC (HTTP/3). |

### Network Configuration Managers

| Tool | Architecture | Use Case |
| :--- | :--- | :--- |
| **ifupdown (Legacy)** | Parses `/etc/network/interfaces` sequentially. | Older Debian/Ubuntu systems, simple static setups. |
| **NetworkManager** | Dynamic, DBus-driven daemon (`nmcli`). | Desktops, laptops, RHEL-based servers, environments requiring Wi-Fi/VPN. |
| **systemd-networkd** | Native systemd daemon using `.network` files. | Modern servers, containers, CoreOS, flat and predictable server networking. |
| **Netplan** | YAML abstraction layer over NetworkManager or networkd. | Ubuntu servers (modern standard). |

## 3. Infrastructure as Code: Network Configuration

In modern Ubuntu/Debian server environments, Netplan provides a declarative YAML structure for defining network state.

### Netplan Configuration: `/etc/netplan/01-netcfg.yaml`

This configuration defines a static IPv4 address, an IPv6 address, custom DNS servers, and configures routing.

```yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    eth0:
      dhcp4: no
      dhcp6: no
      addresses:
        - 10.100.10.50/24
        - "2001:db8:1::50/64"
      routes:
        - to: default
          via: 10.100.10.1
        - to: default
          via: "2001:db8:1::1"
      nameservers:
        addresses:
          - 1.1.1.1
          - 8.8.8.8
          - "2001:4860:4860::8888"
        search:
          - internal.example.com
```

Apply this configuration deterministically:
```bash
$ sudo netplan apply
```

## 4. CLI Commands and Terminal Outputs

### 4.1 IP Addressing and Routing (`iproute2`)

The `ip` suite replaces legacy tools like `ifconfig` and `route`.

List all interfaces and their IP addresses:
```bash
$ ip -brief address show
lo               UNKNOWN        127.0.0.1/8 ::1/128 
eth0             UP             10.100.10.50/24 2001:db8:1::50/64 fe80::20c:29ff:fe1a:b1c2/64 
```

View the routing table (IPv4):
```bash
$ ip route show
default via 10.100.10.1 dev eth0 proto static 
10.100.10.0/24 dev eth0 proto kernel scope link src 10.100.10.50 
```

### 4.2 Socket and Connection Inspection (`ss`)

The `ss` command (socket statistics) replaces `netstat`.

List all listening TCP sockets with the associated process (requires root):
```bash
$ sudo ss -tlnp
State    Recv-Q   Send-Q     Local Address:Port      Peer Address:Port   Process                                     
LISTEN   0        4096       127.0.0.53%lo:53             0.0.0.0:*       users:(("systemd-resolve",pid=815,fd=14))
LISTEN   0        128              0.0.0.0:22             0.0.0.0:*       users:(("sshd",pid=900,fd=3))
LISTEN   0        128                 [::]:22                [::]:*       users:(("sshd",pid=900,fd=4))
```

### 4.3 DNS Resolution Configuration

DNS configuration is typically managed by `systemd-resolved`, which dynamically generates `/etc/resolv.conf` as a stub resolver.

```bash
$ cat /etc/resolv.conf
# This is a dynamic resolv.conf file for connecting local clients to the
# internal DNS stub resolver of systemd-resolved.
nameserver 127.0.0.53
options edns0 trust-ad
search internal.example.com

$ resolvectl status
Global
       Protocols: -LLMNR -mDNS -DNSOverTLS DNSSEC=no/unsupported
resolv.conf mode: stub

Link 2 (eth0)
    Current Scopes: DNS
         Protocols: +DefaultRoute +LLMNR -mDNS -DNSOverTLS DNSSEC=no/unsupported
Current DNS Server: 1.1.1.1
       DNS Servers: 1.1.1.1 8.8.8.8
        DNS Domain: internal.example.com
```

## 5. Troubleshooting and Fault Diagnosis

### Scenario A: DNS Resolution Failing (NXDOMAIN / Timeout)
**Symptoms:** `curl https://api.github.com` hangs or returns `Could not resolve host`.
**Diagnosis:**
1. Check if the stub resolver is listening: `ss -uln | grep 53`.
2. Test resolution directly against the stub: `dig @127.0.0.53 api.github.com`.
3. Test resolution directly against an external upstream to bypass the local stub: `dig @1.1.1.1 api.github.com`.
**Resolution:** If external upstream works but local fails, restart `systemd-resolved`. If external also fails, check the routing table (`ip route`) or verify if egress port 53 (UDP/TCP) is blocked by a firewall (e.g., `iptables` or cloud security groups).

### Scenario B: Asymmetric Routing or Dropped Packets
**Symptoms:** TCP connections are established (SYN sent) but hang, eventually timing out.
**Diagnosis:**
1. Use `ping` to verify basic Layer 3 ICMP connectivity.
2. Use `tracepath` or `traceroute` to discover where packets are being dropped.
   ```bash
   $ tracepath 8.8.8.8
    1?: [LOCALHOST]                      pmtu 1500
    1:  10.100.10.1                                           0.512ms 
    2:  no reply
   ```
3. Use `nc` (netcat) to test specific TCP port connectivity without HTTP overhead:
   ```bash
   $ nc -vz 10.100.20.5 443
   nc: connect to 10.100.20.5 port 443 (tcp) failed: Connection timed out
   ```
**Resolution:** This often points to missing return routes (the target receives the packet but routes the reply to the wrong gateway) or a firewall dropping the packet silently (DROP vs. REJECT). Verify the routing table on both ends.

### Scenario C: Port Already in Use
**Symptoms:** A web server fails to start, logging `bind: address already in use`.
**Diagnosis:**
Identify the rogue process holding the port using `ss`:
```bash
$ sudo ss -tlnp | grep :80
LISTEN 0 511 0.0.0.0:80 0.0.0.0:* users:(("nginx",pid=1234,fd=6))
```
**Resolution:** Stop the conflicting process (`systemctl stop nginx`) or reconfigure the failing service to bind to a different port.

## 6. References

- iproute2 Cheatsheet: https://baturin.org/docs/iproute2/
- Netplan Documentation: https://netplan.io/
- systemd-resolved Manual: https://www.freedesktop.org/software/systemd/man/systemd-resolved.service.html
- LPIC-1 Exam Objectives: https://www.lpi.org/our-certifications/exam-101-objectives/