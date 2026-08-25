# 334.4 — Virtual Private Networks
## Guided Exercises — LPIC-3 303 (Exam 303-300, v3.0.0)

**Exam weight: 6.67** · Objective source: <https://www.lpi.org/our-certifications/exam-303-objectives/>

These exercises cover the two VPN stacks the objective names explicitly — **OpenVPN** (TLS-based, userspace, `tun`/`tap`) and **strongSwan/IPsec** (IKEv2, kernel XFRM) — plus tunnel-vs-transport mode and L2TP awareness. Every step is executed; every configuration file is complete and syntactically valid. Do not skip the verification commands: the exam tests *observable state* (`swanctl --list-sas`, `ip xfrm policy`, the OpenVPN status file), not just file contents.

---

## Lab topology

Build three machines (VMs, LXC containers with `net_admin` + `/dev/net/tun`, or KVM guests). Network namespaces also work but complicate `systemd` unit testing.

```
                        transit segment 198.51.100.0/24
        ┌───────────────────────┐                    ┌───────────────────────┐
        │  gw-a                 │                    │  gw-b                 │
        │  eth0 198.51.100.10   │◄──────────────────►│  eth0 198.51.100.20   │
        │  eth1 192.168.10.1/24 │                    │  eth1 192.168.20.1/24 │
        │  OpenVPN server       │                    │  IPsec peer           │
        │  strongSwan gateway   │                    │  strongSwan gateway   │
        └───────────┬───────────┘                    └───────────┬───────────┘
                    │                                            │
           lan-a 192.168.10.0/24                        lan-b 192.168.20.0/24
           host-a1 192.168.10.50                        host-b1 192.168.20.50

        ┌───────────────────────┐
        │  rw1 (road warrior)   │  eth0 198.51.100.77 — OpenVPN client only
        └───────────────────────┘

        OpenVPN virtual subnet: 10.8.0.0/24
        DNS names used in certificates: gw-a.example.com, gw-b.example.com
```

Add to `/etc/hosts` on all three nodes:

```
198.51.100.10   gw-a gw-a.example.com
198.51.100.20   gw-b gw-b.example.com
198.51.100.77   rw1  rw1.example.com
```

Package names per family:

| Component | Debian 12 / Ubuntu 24.04 | RHEL 9 / Rocky 9 |
|---|---|---|
| OpenVPN | `openvpn easy-rsa` | `openvpn easy-rsa` (EPEL) |
| strongSwan (swanctl) | `strongswan strongswan-swanctl` | `strongswan` |
| strongSwan legacy `ipsec` | `strongswan-starter` | included (`ipsec` wrapper) |
| Diagnostics | `tcpdump iproute2 nftables` | `tcpdump iproute2 nftables` |

---

## Exercise 1 — Build a PKI with Easy-RSA 3

**Objective:** produce a CA, a server certificate with the correct Extended Key Usage, a client certificate, a CRL, and a `tls-crypt` key. Everything OpenVPN authentication depends on is created here.

### Steps

1. On `gw-a`, create a working CA directory outside the OpenVPN tree (the CA private key must never live on the VPN server in production — you are collapsing two roles for the lab, and you should know it):

```bash
sudo apt-get install -y openvpn easy-rsa
make-cadir ~/easy-rsa          # Debian helper; on RHEL: cp -r /usr/share/easy-rsa/3 ~/easy-rsa
cd ~/easy-rsa
```

2. Write `~/easy-rsa/vars`. Elliptic curve keys are smaller and faster and remove the Diffie-Hellman parameter file entirely:

```bash
cat > vars <<'EOF'
set_var EASYRSA_ALGO             ec
set_var EASYRSA_CURVE            secp384r1
set_var EASYRSA_DIGEST           "sha384"
set_var EASYRSA_CA_EXPIRE        3650
set_var EASYRSA_CERT_EXPIRE      825
set_var EASYRSA_CRL_DAYS         180
set_var EASYRSA_REQ_CN           "Example VPN CA"
set_var EASYRSA_BATCH            "1"
EOF
```

3. Initialise the PKI and build the CA:

```bash
./easyrsa init-pki
./easyrsa build-ca nopass
```

Expected tail:

```
CA creation complete and you may now import and sign cert requests.
Your new CA certificate file for publishing is at:
/home/lab/easy-rsa/pki/ca.crt
```

4. Issue the server certificate. The `server` type is what stamps `extendedKeyUsage = serverAuth` and `keyUsage = digitalSignature, keyEncipherment`:

```bash
./easyrsa build-server-full gw-a.example.com nopass
```

5. Issue a client certificate:

```bash
./easyrsa build-client-full roadwarrior1 nopass
```

6. Generate an (initially empty) CRL and inspect what it actually contains:

```bash
./easyrsa gen-crl
openssl crl -in pki/crl.pem -noout -text | head -n 12
```

```
Certificate Revocation List (CRL):
        Version 2 (0x1)
        Signature Algorithm: ecdsa-with-SHA384
        Issuer: CN = Example VPN CA
        Last Update: Aug 25 12:00:00 2026 GMT
        Next Update: Feb 21 12:00:00 2027 GMT
        CRL extensions:
            X509v3 Authority Key Identifier: ...
No Revoked Certificates.
```

7. Prove the EKU distinction between the two leaf certificates:

```bash
openssl x509 -in pki/issued/gw-a.example.com.crt -noout -ext extendedKeyUsage,keyUsage
openssl x509 -in pki/issued/roadwarrior1.crt     -noout -ext extendedKeyUsage,keyUsage
```

```
X509v3 Extended Key Usage:
    TLS Web Server Authentication
X509v3 Key Usage:
    Digital Signature, Key Encipherment
---
X509v3 Extended Key Usage:
    TLS Web Client Authentication
X509v3 Key Usage:
    Digital Signature
```

8. Generate the control-channel key. This is *not* part of the PKI — it is a static shared secret:

```bash
openvpn --genkey secret ~/easy-rsa/pki/tc.key    # OpenVPN 2.5+/2.6 syntax
# OpenVPN 2.4 and older: openvpn --genkey --secret ~/easy-rsa/pki/tc.key
head -n 3 ~/easy-rsa/pki/tc.key
```

```
#
# 2048 bit OpenVPN static key
#
```

9. Install the server-side material and lock it down:

```bash
sudo install -d -m 0700 /etc/openvpn/server
sudo install -m 0644 pki/ca.crt                          /etc/openvpn/server/
sudo install -m 0644 pki/issued/gw-a.example.com.crt     /etc/openvpn/server/
sudo install -m 0600 pki/private/gw-a.example.com.key    /etc/openvpn/server/
sudo install -m 0600 pki/tc.key                          /etc/openvpn/server/
sudo install -m 0644 pki/crl.pem                         /etc/openvpn/server/
```

### Checkpoint questions — Exercise 1

1. Why did `vars` never mention a `dh.pem`, and under what circumstance would you still need `./easyrsa gen-dh`?
2. A client certificate and a server certificate are both signed by the same CA. Without EKU checking, what attack does that enable against your VPN clients, and which OpenVPN client directive blocks it?
3. `tc.key` was generated with `openvpn --genkey`, not with `easyrsa`. What layer of the OpenVPN protocol does it protect, and what does an attacker who does *not* have it observe on the wire?
4. Step 9 installs `crl.pem` mode `0644` while the private key is `0600`. Later you will add `user nobody` to the server config. Explain why `crl.pem` in particular must stay world-readable.
5. `EASYRSA_CRL_DAYS` is 180. What happens to *every* connecting client on day 181 if you do nothing?

---

## Exercise 2 — Routed OpenVPN server (`tun`, `topology subnet`)

**Objective:** a working IPv4 routed server, started through the correct systemd template unit, with forwarding and NAT for the LAN behind it.

### Steps

1. On `gw-a`, write `/etc/openvpn/server/server.conf`:

```conf
# ---- transport ----------------------------------------------------------
port 1194
proto udp4
dev tun
topology subnet

# ---- virtual network ----------------------------------------------------
server 10.8.0.0 255.255.255.0
ifconfig-pool-persist /var/lib/openvpn/ipp.txt
push "route 192.168.10.0 255.255.255.0"
push "dhcp-option DNS 192.168.10.1"
client-config-dir /etc/openvpn/server/ccd
route 192.168.20.0 255.255.255.0            # prepared for Exercise 4

# ---- cryptography -------------------------------------------------------
ca      /etc/openvpn/server/ca.crt
cert    /etc/openvpn/server/gw-a.example.com.crt
key     /etc/openvpn/server/gw-a.example.com.key
tls-crypt /etc/openvpn/server/tc.key
crl-verify /etc/openvpn/server/crl.pem
remote-cert-tls client
tls-version-min 1.2
data-ciphers AES-256-GCM:CHACHA20-POLY1305
auth SHA256

# ---- liveness and hygiene ----------------------------------------------
keepalive 10 60
persist-key
persist-tun
user nobody
group nogroup                                # RHEL: group nobody
explicit-exit-notify 1

# ---- observability ------------------------------------------------------
status /run/openvpn-server/status-server.log 10
status-version 2
verb 3
management 127.0.0.1 7505
```

2. Create the directories the config references and validate the syntax without starting the daemon:

```bash
sudo install -d -m 0755 /etc/openvpn/server/ccd /var/lib/openvpn /run/openvpn-server
sudo openvpn --config /etc/openvpn/server/server.conf --verb 4 --mode server
```

Watch for the completion line, then press `Ctrl-C`:

```
2026-08-25 12:00:01 OpenVPN 2.6.9 x86_64-pc-linux-gnu [SSL (OpenSSL)] [LZ4] [EPOLL] [AEAD]
2026-08-25 12:00:01 library versions: OpenSSL 3.0.13 30 Jan 2024, LZ4 1.9.4
2026-08-25 12:00:01 net_iface_up: set tun0 up
2026-08-25 12:00:01 net_addr_v4_add: 10.8.0.1/24 dev tun0
2026-08-25 12:00:01 UDPv4 link local (bound): [AF_INET][undef]:1194
2026-08-25 12:00:01 GID set to nogroup
2026-08-25 12:00:01 UID set to nobody
2026-08-25 12:00:01 Initialization Sequence Completed
```

3. Enable IPv4 forwarding persistently:

```bash
echo 'net.ipv4.ip_forward = 1' | sudo tee /etc/sysctl.d/99-vpn.conf
sudo sysctl --system | grep -m1 ip_forward
```

```
net.ipv4.ip_forward = 1
```

4. Open the port and NAT VPN clients onto the LAN. **nftables:**

```bash
sudo nft -f - <<'EOF'
table inet vpn {
  chain input {
    type filter hook input priority filter; policy accept;
    udp dport 1194 accept
    iifname "tun0" accept
  }
  chain forward {
    type filter hook forward priority filter; policy accept;
    iifname "tun0" oifname "eth1" accept
    iifname "eth1" oifname "tun0" ct state established,related accept
  }
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    ip saddr 10.8.0.0/24 oifname "eth1" masquerade
  }
}
EOF
```

**firewalld equivalent:**

```bash
sudo firewall-cmd --permanent --add-service=openvpn
sudo firewall-cmd --permanent --zone=trusted --add-interface=tun0
sudo firewall-cmd --permanent --add-masquerade
sudo firewall-cmd --reload
```

5. Start the daemon through the template unit. The instance name is the config *basename*:

```bash
sudo systemctl enable --now openvpn-server@server.service
systemctl status openvpn-server@server.service --no-pager -l | head -n 8
```

```
● openvpn-server@server.service - OpenVPN service for server
     Loaded: loaded (/lib/systemd/system/openvpn-server@.service; enabled)
     Active: active (running) since Tue 2026-08-25 12:03:11 UTC; 4s ago
```

6. Confirm the kernel-side result:

```bash
ip -4 addr show dev tun0
ip -4 route show | grep -E '10\.8\.0|192\.168\.20'
ss -lunp | grep 1194
```

```
4: tun0: <POINTOPOINT,MULTICAST,NOARP,UP,LOWER_UP> mtu 1500 ...
    inet 10.8.0.1/24 scope global tun0
10.8.0.0/24 dev tun0 proto kernel scope link src 10.8.0.1
192.168.20.0/24 dev tun0 scope link
UNCONN 0 0 0.0.0.0:1194 0.0.0.0:* users:(("openvpn",pid=1841,fd=6))
```

### Checkpoint questions — Exercise 2

6. With `topology subnet`, `tun0` on the server is `10.8.0.1/24`. What address layout would `topology net30` have produced instead for the server and for the first client, and why does the legacy mode exist at all?
7. `route 192.168.20.0 255.255.255.0` is in the server config but no client advertises that subnet yet. What did that line do to the *server's* kernel routing table (see step 6 output), and what has it **not** done?
8. The daemon runs as `nobody`, yet it created `tun0` and installed routes. Explain the ordering that makes this possible, and state precisely what `persist-tun` and `persist-key` prevent after a `SIGUSR1` restart.
9. You changed `data-ciphers` on the server but an old 2.4 client still connects successfully with AES-256-CBC. Which directive made that possible, and why is it a security decision rather than a compatibility convenience?
10. `explicit-exit-notify 1` is a server-side directive here. What does the peer do with it, and why is it meaningless when `proto tcp` is used?

---

## Exercise 3 — Client connection, live verification, and wire-level diagnostics

**Objective:** connect `rw1`, prove the tunnel carries traffic, and read the encrypted flow on the transit link.

### Steps

1. On `gw-a`, produce an inline single-file client profile (this is the format you hand to users — no loose key files):

```bash
cd ~/easy-rsa
{
  cat <<'EOF'
client
dev tun
proto udp4
remote gw-a.example.com 1194
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
verify-x509-name gw-a.example.com name
data-ciphers AES-256-GCM:CHACHA20-POLY1305
auth SHA256
verb 3
EOF
  echo '<ca>';        cat pki/ca.crt;                        echo '</ca>'
  echo '<cert>';      openssl x509 -in pki/issued/roadwarrior1.crt; echo '</cert>'
  echo '<key>';       cat pki/private/roadwarrior1.key;      echo '</key>'
  echo '<tls-crypt>'; cat pki/tc.key;                        echo '</tls-crypt>'
} > roadwarrior1.ovpn
```

2. Copy it to `rw1` as `/etc/openvpn/client/roadwarrior1.conf` and connect in the foreground first, at verbosity 4:

```bash
sudo openvpn --config /etc/openvpn/client/roadwarrior1.conf --verb 4
```

Key lines to identify:

```
2026-08-25 12:06:02 TCP/UDP: Preserving recently used remote address: [AF_INET]198.51.100.10:1194
2026-08-25 12:06:02 VERIFY OK: depth=1, CN=Example VPN CA
2026-08-25 12:06:02 VERIFY KU OK
2026-08-25 12:06:02 Validating certificate extended key usage
2026-08-25 12:06:02 ++ Certificate has EKU (str) TLS Web Server Authentication, expects TLS Web Server Authentication
2026-08-25 12:06:02 VERIFY EKU OK
2026-08-25 12:06:02 VERIFY X509NAME OK: CN=gw-a.example.com
2026-08-25 12:06:02 VERIFY OK: depth=0, CN=gw-a.example.com
2026-08-25 12:06:02 Control Channel: TLSv1.3, cipher TLSv1.3 TLS_AES_256_GCM_SHA384, peer certificate: 384 bit EC
2026-08-25 12:06:02 [gw-a.example.com] Peer Connection Initiated with [AF_INET]198.51.100.10:1194
2026-08-25 12:06:04 PUSH: Received control message: 'PUSH_REPLY,route 192.168.10.0 255.255.255.0,dhcp-option DNS 192.168.10.1,route-gateway 10.8.0.1,topology subnet,ping 10,ping-restart 60,ifconfig 10.8.0.2 255.255.255.0'
2026-08-25 12:06:04 Outgoing Data Channel: Cipher 'AES-256-GCM' initialized with 256 bit key
2026-08-25 12:06:04 net_addr_v4_add: 10.8.0.2/24 dev tun0
2026-08-25 12:06:04 net_route_v4_add: 192.168.10.0/24 via 10.8.0.1 dev [NULL] table 0
2026-08-25 12:06:04 Initialization Sequence Completed
```

3. From a second shell on `rw1`, verify reachability and the resulting routes:

```bash
ip -4 route show | grep -E '10\.8|192\.168\.10'
ping -c2 10.8.0.1
ping -c2 192.168.10.50
traceroute -n 192.168.10.50
```

```
10.8.0.0/24 dev tun0 proto kernel scope link src 10.8.0.2
192.168.10.0/24 via 10.8.0.1 dev tun0
```

4. On `gw-a`, read the live session table two ways:

```bash
sudo cat /run/openvpn-server/status-server.log
```

```
TITLE,OpenVPN 2.6.9 x86_64-pc-linux-gnu [SSL (OpenSSL)] [LZ4] [EPOLL] [AEAD]
TIME,2026-08-25 12:07:00,1787832420
HEADER,CLIENT_LIST,Common Name,Real Address,Virtual Address,Virtual IPv6 Address,Bytes Received,Bytes Sent,Connected Since,Connected Since (time_t),Username,Client ID,Peer ID,Data Channel Cipher
CLIENT_LIST,roadwarrior1,198.51.100.77:44311,10.8.0.2,,4820,4212,2026-08-25 12:06:02,1787832362,UNDEF,0,0,AES-256-GCM
HEADER,ROUTING_TABLE,Virtual Address,Common Name,Real Address,Last Ref,Last Ref (time_t)
ROUTING_TABLE,10.8.0.2,roadwarrior1,198.51.100.77:44311,2026-08-25 12:06:58,1787832418
GLOBAL_STATS,Max bcast/mcast queue length,0
END
```

```bash
printf 'status 2\nquit\n' | nc 127.0.0.1 7505
```

5. Capture the transit link on `gw-a` while pinging from `rw1`, and confirm the payload is opaque:

```bash
sudo tcpdump -n -i eth0 -c 4 -vv udp port 1194
```

```
12:08:14.220118 IP (tos 0x0, ttl 64, id 0, offset 0, flags [DF], proto UDP (17), length 133)
    198.51.100.77.44311 > 198.51.100.10.1194: UDP, length 105
12:08:14.220944 IP (tos 0x0, ttl 64, id 61553, offset 0, flags [none], proto UDP (17), length 133)
    198.51.100.10.1194 > 198.51.100.77.44311: UDP, length 105
```

Then capture on the virtual interface and see the plaintext:

```bash
sudo tcpdump -n -i tun0 -c 4 icmp
```

```
12:08:20.113400 IP 10.8.0.2 > 192.168.10.50: ICMP echo request, id 12, seq 1, length 64
12:08:20.114001 IP 192.168.10.50 > 10.8.0.2: ICMP echo reply,   id 12, seq 1, length 64
```

6. Reproduce the classic MTU failure. Send a large, unfragmentable packet through the tunnel:

```bash
ping -c1 -M do -s 1450 192.168.10.50
```

```
PING 192.168.10.50 (192.168.10.50) 1450(1478) bytes of data.
ping: local error: message too long, mtu=1500
--- 192.168.10.50 ping statistics ---
1 packets transmitted, 0 received, +1 errors, 100% packet loss
```

Now confirm the working ceiling and record it:

```bash
for s in 1500 1450 1400 1380 1360; do
  ping -c1 -W1 -M do -s $s 192.168.10.50 >/dev/null 2>&1 && echo "$s OK" || echo "$s FAIL"
done
```

7. Force a controlled failure to learn its signature. On `rw1`, remove the `<tls-crypt>` block from a copy of the profile and connect:

```bash
sudo openvpn --config /etc/openvpn/client/broken.conf --verb 3
```

```
2026-08-25 12:11:02 TLS Error: cannot locate HMAC in incoming packet from [AF_INET]198.51.100.10:1194
2026-08-25 12:12:02 TLS Error: TLS key negotiation failed to occur within 60 seconds (check your network connectivity)
2026-08-25 12:12:02 TLS Error: TLS handshake failed
```

Meanwhile the **server log stays silent about this client**. Confirm it:

```bash
sudo journalctl -u openvpn-server@server -n 20 --no-pager
```

### Checkpoint questions — Exercise 3

11. In step 2, four separate `VERIFY` lines appear. Map each one to the client directive that requested it, and say which of the four would still fire if `remote-cert-tls server` were removed.
12. `PUSH_REPLY` contains `ifconfig 10.8.0.2 255.255.255.0` and `route-gateway 10.8.0.1`. Neither appears in the client's own configuration file. What is the security consequence of a client trusting pushed directives, and which client-side directive limits it?
13. Step 5 shows UDP length 105 for a 64-byte ICMP payload. Account for the growth, and explain why an on-path observer can still infer the *type* of traffic despite the encryption.
14. Step 6: the failure at 1450 bytes is reported by the *local* stack, not by a remote router. Explain the mechanism, then state which OpenVPN directive fixes TCP throughput without touching the client's MTU, and why that directive does nothing for UDP-based applications such as DNS-over-QUIC.
15. In step 7 the server logged nothing at all. Explain exactly what `tls-crypt` did to the client's first packet to produce that silence, and name one operational benefit and one troubleshooting cost of this behaviour.
16. `tls-crypt` versus `tls-auth`: state the two functional differences, and explain what `tls-crypt-v2` adds that neither provides.

---

## Exercise 4 — Client-config-dir, `iroute`, and certificate revocation

**Objective:** pin a client to a fixed VPN address, route a whole remote subnet through a client (the OpenVPN site-to-site pattern), and prove revocation works.

### Steps

1. On `gw-a`, pin the road warrior's address. The file name **must equal the certificate CN**:

```bash
sudo tee /etc/openvpn/server/ccd/roadwarrior1 <<'EOF'
ifconfig-push 10.8.0.50 255.255.255.0
EOF
```

2. Issue a certificate for a branch gateway that will present the 192.168.20.0/24 network, and give it the internal route:

```bash
cd ~/easy-rsa && ./easyrsa build-client-full branch-b nopass
sudo tee /etc/openvpn/server/ccd/branch-b <<'EOF'
ifconfig-push 10.8.0.60 255.255.255.0
iroute 192.168.20.0 255.255.255.0
EOF
```

3. Restart the server and reconnect `rw1`; confirm the pinned address:

```bash
sudo systemctl restart openvpn-server@server
# on rw1, reconnect, then:
ip -4 addr show dev tun0 | grep inet
```

```
    inet 10.8.0.50/24 scope global tun0
```

4. Add the missing half of the site-to-site path. `gw-a` already has `route 192.168.20.0 255.255.255.0`; other VPN clients also need it, so push it:

```bash
sudo tee -a /etc/openvpn/server/server.conf <<'EOF'
push "route 192.168.20.0 255.255.255.0"
EOF
sudo systemctl restart openvpn-server@server
```

5. Now revoke the road warrior and regenerate the CRL:

```bash
cd ~/easy-rsa
./easyrsa revoke roadwarrior1
./easyrsa gen-crl
sudo install -m 0644 pki/crl.pem /etc/openvpn/server/crl.pem
openssl crl -in pki/crl.pem -noout -text | grep -A2 'Serial Number'
```

```
    Serial Number: 5C3A1F0B9D24E6A7
        Revocation Date: Aug 25 12:20:11 2026 GMT
```

6. **Without restarting the server**, reconnect `rw1` and read both sides:

Client:

```
2026-08-25 12:21:03 VERIFY ERROR: depth=0, error=CRL signature failure: CN=roadwarrior1
2026-08-25 12:21:03 TLS_ERROR: BIO read tls_read_plaintext error
2026-08-25 12:21:03 TLS Error: TLS handshake failed
```

Server:

```
2026-08-25 12:21:03 198.51.100.77:44870 VERIFY ERROR: depth=0, error=certificate revoked: CN=roadwarrior1, serial=5C3A1F0B9D24E6A7
2026-08-25 12:21:03 198.51.100.77:44870 OpenSSL: error:0A000418:SSL routines::tlsv1 alert unknown ca
```

7. Verify the running daemon can still read the CRL after privilege drop — this is where the exercise usually breaks in the real world:

```bash
sudo -u nobody test -r /etc/openvpn/server/crl.pem && echo "readable by nobody" || echo "PRIVILEGE DROP WILL BREAK CRL"
sudo namei -l /etc/openvpn/server/crl.pem
```

8. Disconnect a client administratively without touching its certificate:

```bash
printf 'kill branch-b\nquit\n' | nc 127.0.0.1 7505
```

```
SUCCESS: common name 'branch-b' found, 1 client(s) killed
```

### Checkpoint questions — Exercise 4

17. Distinguish `route 192.168.20.0 255.255.255.0` (server config), `push "route 192.168.20.0 255.255.255.0"`, and `iroute 192.168.20.0 255.255.255.0` (ccd file). Which routing table or internal structure does each one modify, and what breaks if you omit only the `iroute`?
18. The ccd file must be named for the certificate CN. What happens if the file does not exist, and which server directive turns that silent condition into a hard rejection?
19. Revocation took effect without a service restart. Describe when OpenVPN re-reads `crl.pem`, and explain the failure mode when `chroot` is combined with `crl-verify`.
20. In step 7 you checked readability *as `nobody`*. Describe the exact symptom a working-but-misconfigured server shows when the CRL becomes unreadable after the privilege drop — and why it is arguably worse than a crash.
21. `kill branch-b` on the management interface disconnects the client, but it reconnects seconds later. Why, and what is the correct durable remedy?
22. `verify-x509-name gw-a.example.com name` is on the client. If an attacker steals a *client* key from your PKI and stands up a rogue server with it, does this directive stop the attack? Does `remote-cert-tls server`? Justify both.

---

## Exercise 5 — strongSwan IKEv2 site-to-site tunnel with `swanctl` (PSK)

**Objective:** a kernel-mode IPsec tunnel between `gw-a` and `gw-b` joining 192.168.10.0/24 and 192.168.20.0/24, configured with the modern `swanctl.conf`/VICI interface.

### Steps

1. Install on **both** gateways and confirm which daemon flavour is running:

```bash
sudo apt-get install -y strongswan strongswan-swanctl   # RHEL: dnf install -y strongswan
systemctl list-unit-files | grep -i strongswan
```

```
strongswan-starter.service   enabled     # legacy ipsec/starter/stroke
strongswan.service           enabled     # charon-systemd, driven by swanctl
```

Disable the legacy one so the two do not fight over the same SAs:

```bash
sudo systemctl disable --now strongswan-starter.service
sudo systemctl enable  --now strongswan.service
```

2. Enable forwarding on both gateways and **exclude IPsec traffic from NAT** (a masquerade rule that catches 192.168.10.0/24 → 192.168.20.0/24 will rewrite the source address before the XFRM policy matches, and the tunnel will silently carry nothing):

```bash
sudo sysctl -w net.ipv4.ip_forward=1
sudo nft insert rule inet vpn postrouting ip saddr 192.168.10.0/24 ip daddr 192.168.20.0/24 accept
```

3. On `gw-a`, write `/etc/swanctl/swanctl.conf`:

```conf
connections {
    a-to-b {
        version      = 2
        local_addrs  = 198.51.100.10
        remote_addrs = 198.51.100.20
        proposals    = aes256-sha256-modp3072,aes256gcm16-prfsha384-ecp384

        local {
            auth = psk
            id   = gw-a.example.com
        }
        remote {
            auth = psk
            id   = gw-b.example.com
        }

        children {
            net-net {
                local_ts      = 192.168.10.0/24
                remote_ts     = 192.168.20.0/24
                mode          = tunnel
                esp_proposals = aes256gcm16-ecp384,aes256-sha256-modp3072
                start_action  = trap
                close_action  = trap
                dpd_action    = restart
                rekey_time    = 1h
                life_time     = 1h20m
            }
        }

        rekey_time  = 4h
        over_time   = 10m
        dpd_delay   = 30s
        dpd_timeout = 120s
        mobike      = no
    }
}

secrets {
    ike-a-b {
        id-local  = gw-a.example.com
        id-remote = gw-b.example.com
        secret    = "3xAmpl3-Lab-PSK-Do-Not-Use-In-Production-9f2c"
    }
}
```

4. On `gw-b`, write the mirror image. Only the four address/ID/traffic-selector lines swap:

```conf
connections {
    b-to-a {
        version      = 2
        local_addrs  = 198.51.100.20
        remote_addrs = 198.51.100.10
        proposals    = aes256-sha256-modp3072,aes256gcm16-prfsha384-ecp384

        local  { auth = psk; id = gw-b.example.com }
        remote { auth = psk; id = gw-a.example.com }

        children {
            net-net {
                local_ts      = 192.168.20.0/24
                remote_ts     = 192.168.10.0/24
                mode          = tunnel
                esp_proposals = aes256gcm16-ecp384,aes256-sha256-modp3072
                start_action  = trap
                close_action  = trap
                dpd_action    = restart
            }
        }
        dpd_delay = 30s
    }
}

secrets {
    ike-a-b {
        id-local  = gw-b.example.com
        id-remote = gw-a.example.com
        secret    = "3xAmpl3-Lab-PSK-Do-Not-Use-In-Production-9f2c"
    }
}
```

5. Secure the file and load the configuration into the running daemon on both nodes:

```bash
sudo chmod 0600 /etc/swanctl/swanctl.conf
sudo swanctl --load-all
```

```
loaded ike secret 'ike-a-b'
no authorities found, 0 unloaded
no pools found, 0 unloaded
loaded connection 'a-to-b'
successfully loaded 1 connections, 0 unloaded
```

6. Inspect what the daemon believes *before* any traffic flows:

```bash
sudo swanctl --list-conns
sudo ip xfrm policy
sudo ip xfrm state
```

```
a-to-b: IKEv2, no reauthentication, rekeying every 14400s
  local:  198.51.100.10
  remote: 198.51.100.20
  local pre-shared key authentication:
    id: gw-a.example.com
  remote pre-shared key authentication:
    id: gw-b.example.com
  net-net: TUNNEL, rekeying every 3600s
    local:  192.168.10.0/24
    remote: 192.168.20.0/24
```

```
src 192.168.10.0/24 dst 192.168.20.0/24
	dir out priority 375423 ptype main
	tmpl src 198.51.100.10 dst 198.51.100.20
		proto esp spi 0x00000000 reqid 1 mode tunnel
```

(`ip xfrm state` prints nothing.)

7. Trigger the tunnel from the LAN side and watch it come up:

```bash
# from host-a1
ping -c3 192.168.20.50
```

```bash
# on gw-a
sudo swanctl --list-sas
```

```
a-to-b: #1, ESTABLISHED, IKEv2, 8e1c4d5f6a7b8c9d_i* 1a2b3c4d5e6f7a8b_r
  local  'gw-a.example.com' @ 198.51.100.10[500]
  remote 'gw-b.example.com' @ 198.51.100.20[500]
  AES_CBC-256/HMAC_SHA2_256_128/PRF_HMAC_SHA2_256/MODP_3072
  established 3s ago, rekeying in 13102s
  net-net: #1, reqid 1, INSTALLED, TUNNEL, ESP:AES_GCM_16-256
    installed 3s ago, rekeying in 3204s, expires in 4797s
    in  c1a2b3c4,    252 bytes,     3 packets,     1s ago
    out d4e5f6a7,    252 bytes,     3 packets,     1s ago
    local  192.168.10.0/24
    remote 192.168.20.0/24
```

8. Read the kernel's view — this is the ground truth, independent of the daemon:

```bash
sudo ip -s xfrm state
sudo ip xfrm policy | grep -c 'dir'
```

```
src 198.51.100.10 dst 198.51.100.20
	proto esp spi 0xd4e5f6a7 reqid 1 mode tunnel
	replay-window 0 flag af-unspec esn
	aead rfc4106(gcm(aes)) 0x9a3f... 128
	lifetime config:
	  limit: soft (none), hard (none)
	  expire add: soft 3204(sec), hard 4797(sec)
	stats:
	  replay-window 0 replay 0 failed 0
```

```
3
```

9. Prove on the wire that this is ESP, not UDP:

```bash
sudo tcpdump -n -i eth0 -c 4 esp
```

```
12:35:41.113221 IP 198.51.100.10 > 198.51.100.20: ESP(spi=0xd4e5f6a7,seq=0x4), length 120
12:35:41.114008 IP 198.51.100.20 > 198.51.100.10: ESP(spi=0xc1a2b3c4,seq=0x4), length 120
```

10. Note that there is **no interface** for this tunnel:

```bash
ip -br link show | grep -Ev 'lo|eth'
```

(no output — compare with `tun0` from Exercise 2.)

### Checkpoint questions — Exercise 5

23. In step 6, `ip xfrm policy` already contained an entry with `spi 0x00000000` while `ip xfrm state` was empty. Name the strongSwan setting that produced it and explain the state machine it implements.
24. `ip xfrm policy | grep -c dir` returned **3** for one tunnel. Name the three directions and say which one is required specifically because this box is a *gateway* and not an endpoint.
25. `swanctl --list-sas` shows one IKE SA and one CHILD SA, with separate `in`/`out` SPIs. Explain the relationship between IKE SA, CHILD SA and SPI, and which of those the *responder* chooses.
26. Step 10 shows no interface exists. Contrast this with OpenVPN's `tun0` and give two concrete operational consequences (one for firewalling, one for monitoring).
27. Step 2 inserted an `accept` rule ahead of masquerade. Describe the exact packet path that goes wrong without it, and name the symptom an operator would report.
28. `start_action = trap` versus `start_action = start`: state the behavioural difference and pick the correct one for (a) a branch office that must always be reachable from headquarters, (b) a metered LTE backup link.
29. Both sides declare `mobike = no`. What does MOBIKE do, on which IKE version is it available, and why is it irrelevant for a fixed-address site-to-site tunnel but essential for a laptop?

---

## Exercise 6 — Certificate authentication and transport mode

**Objective:** replace the PSK with X.509 authentication using strongSwan's own `pki` tool, then build a host-to-host **transport mode** SA and observe the difference in the kernel policy.

### Steps

1. On `gw-a`, build a separate IPsec CA (do not reuse the OpenVPN CA — different trust domain, different revocation lifecycle):

```bash
cd /tmp && umask 077
pki --gen --type ed25519 --outform pem > ipsec-ca.key
pki --self --ca --lifetime 3650 --in ipsec-ca.key --type ed25519 \
    --dn "C=AR, O=Example, CN=Example IPsec CA" --outform pem > ipsec-ca.crt

for host in gw-a gw-b; do
  pki --gen --type ed25519 --outform pem > ${host}.key
  pki --pub --in ${host}.key --type ed25519 \
   | pki --issue --lifetime 825 --cacert ipsec-ca.crt --cakey ipsec-ca.key \
         --dn "C=AR, O=Example, CN=${host}.example.com" \
         --san ${host}.example.com --flag serverAuth --flag ikeIntermediate \
         --outform pem > ${host}.crt
done
pki --print --in gw-a.crt | head -n 8
```

```
  subject:  "C=AR, O=Example, CN=gw-a.example.com"
  issuer:   "C=AR, O=Example, CN=Example IPsec CA"
  validity:  not before Aug 25 12:40:00 2026, ok
             not after  Nov 27 12:40:00 2028, ok
  serial:    3f:1a:9c:22:0e:47:b5:d8
  altNames:  gw-a.example.com
  flags:     serverAuth ikeIntermediate
  authkeyId: 5a:cc:...
  subjkeyId: 91:2e:...
```

2. Place the credentials in the directories `swanctl --load-creds` scans:

```bash
# on gw-a
sudo install -m 0644 ipsec-ca.crt /etc/swanctl/x509ca/
sudo install -m 0644 gw-a.crt     /etc/swanctl/x509/
sudo install -m 0600 gw-a.key     /etc/swanctl/private/
# copy ipsec-ca.crt, gw-b.crt, gw-b.key to gw-b's matching directories
ls -R /etc/swanctl | head -n 20
```

3. Switch `gw-a`'s connection to public-key authentication:

```conf
connections {
    a-to-b {
        version      = 2
        local_addrs  = 198.51.100.10
        remote_addrs = 198.51.100.20
        proposals    = aes256gcm16-prfsha384-ecp384

        local {
            auth  = pubkey
            certs = gw-a.crt
            id    = "C=AR, O=Example, CN=gw-a.example.com"
        }
        remote {
            auth = pubkey
            id   = "C=AR, O=Example, CN=gw-b.example.com"
        }

        children {
            net-net {
                local_ts      = 192.168.10.0/24
                remote_ts     = 192.168.20.0/24
                mode          = tunnel
                esp_proposals = aes256gcm16-ecp384
                start_action  = trap
            }
            host-host {
                local_ts      = 198.51.100.10/32
                remote_ts     = 198.51.100.20/32
                mode          = transport
                esp_proposals = aes256gcm16-ecp384
                start_action  = none
            }
        }
    }
}
```

Mirror it on `gw-b` (swap addresses, IDs, `certs`, and the two traffic selectors).

4. Reload credentials and connections on both sides, then verify what was actually loaded:

```bash
sudo swanctl --load-creds
sudo swanctl --load-conns
sudo swanctl --list-certs --subject gw-a.example.com
```

```
loaded certificate from '/etc/swanctl/x509ca/ipsec-ca.crt'
loaded certificate from '/etc/swanctl/x509/gw-a.crt'
loaded ED25519 key from '/etc/swanctl/private/gw-a.key'
successfully loaded 1 connections, 0 unloaded
```

5. Initiate the transport-mode child explicitly and compare the two policies side by side:

```bash
sudo swanctl --initiate --child host-host
sudo swanctl --list-sas --raw | head -n 3
sudo ip xfrm policy
```

```
src 198.51.100.10/32 dst 198.51.100.20/32
	dir out priority 383359 ptype main
	tmpl src 0.0.0.0 dst 0.0.0.0
		proto esp spi 0x00000000 reqid 2 mode transport
src 192.168.10.0/24 dst 192.168.20.0/24
	dir out priority 375423 ptype main
	tmpl src 198.51.100.10 dst 198.51.100.20
		proto esp reqid 1 mode tunnel
```

6. Capture both and compare the header depth:

```bash
sudo tcpdump -n -i eth0 -c 2 -e esp
```

7. Break authentication deliberately: on `gw-b`, change `remote { id = ... }` to `CN=wrong.example.com`, reload, and re-initiate from `gw-a`:

```bash
sudo swanctl --initiate --child net-net
```

```
initiating IKE_SA a-to-b[3] to 198.51.100.20
...
received AUTHENTICATION_FAILED notify error
establishing connection 'a-to-b' failed
```

`gw-b`'s journal:

```
journalctl -u strongswan -n 5 --no-pager
charon: 09[CFG] no matching peer config found for 'C=AR, O=Example, CN=gw-b.example.com'...'C=AR, O=Example, CN=gw-a.example.com'
charon: 09[ENC] generating IKE_AUTH response ... N(AUTH_FAILED)
```

Restore the correct ID and confirm recovery.

8. Force a proposal mismatch: on `gw-b` set `esp_proposals = aes128-sha1-modp1024`, reload, initiate from `gw-a`:

```
received NO_PROPOSAL_CHOSEN notify, no CHILD_SA built
```

Restore.

### Checkpoint questions — Exercise 6

30. In step 5 the transport-mode policy shows `tmpl src 0.0.0.0 dst 0.0.0.0` while the tunnel-mode policy shows real gateway addresses. Explain why, in terms of what each mode does to the original IP header.
31. Why can transport mode never be used to join 192.168.10.0/24 to 192.168.20.0/24?
32. `--flag ikeIntermediate` was passed to `pki --issue`. What is it for, and is it required for IKEv2?
33. `swanctl --load-creds` reads `/etc/swanctl/private`, `/etc/swanctl/x509`, `/etc/swanctl/x509ca` and `/etc/swanctl/x509crl`. Which one must be populated for the *remote* peer's identity to be validated, and why is the remote peer's own certificate not required to be present locally?
34. Contrast the two induced failures: `AUTHENTICATION_FAILED` (step 7) and `NO_PROPOSAL_CHOSEN` (step 8). At which IKEv2 exchange does each occur, and what does that tell you about which one is visible to an unauthenticated attacker?
35. The `local.id` is a full distinguished name here but was an FQDN in Exercise 5. What must the `id` correspond to when `auth = pubkey`, and what error results from a mismatch with the certificate's subject or SAN?

---

## Exercise 7 — Legacy `ipsec.conf` / `ipsec.secrets`, `strongswan.conf`, and L2TP awareness

**Objective:** read and write the older `starter`/`stroke` configuration the exam still lists, tune `charon`, and understand where L2TP fits.

### Steps

1. Stop the swanctl-driven daemon so the two do not conflict, and switch to the legacy one:

```bash
sudo systemctl stop strongswan.service
sudo systemctl start strongswan-starter.service   # RHEL: the 'ipsec' wrapper starts this
```

2. Express the Exercise 5 tunnel in `/etc/ipsec.conf`:

```conf
config setup
    charondebug = "ike 1, knl 1, cfg 0"
    uniqueids   = yes

conn %default
    keyexchange  = ikev2
    ike          = aes256-sha256-modp3072!
    esp          = aes256gcm16-ecp384!
    dpdaction    = restart
    dpddelay     = 30s
    closeaction  = restart

conn a-to-b
    left         = 198.51.100.10
    leftid       = gw-a.example.com
    leftsubnet   = 192.168.10.0/24
    leftauth     = psk
    right        = 198.51.100.20
    rightid      = gw-b.example.com
    rightsubnet  = 192.168.20.0/24
    rightauth    = psk
    type         = tunnel
    auto         = route
```

3. And `/etc/ipsec.secrets` (mode `0600`):

```
gw-a.example.com gw-b.example.com : PSK "3xAmpl3-Lab-PSK-Do-Not-Use-In-Production-9f2c"
```

```bash
sudo chmod 0600 /etc/ipsec.secrets
```

4. Load and inspect with the legacy tooling:

```bash
sudo ipsec restart
sleep 3
sudo ipsec statusall | head -n 20
```

```
Status of IKE charon daemon (strongSwan 5.9.11, Linux 6.1.0, x86_64):
  uptime: 3 seconds, since Aug 25 12:55:02 2026
  malloc: sbrk 2314240, mmap 0, used 494096, free 1820144
  worker threads: 11 of 16 idle, 5/0/0/0 working, job queue: 0/0/0/0
  loaded plugins: charon aes sha2 random nonce x509 pubkey pem openssl kernel-netlink socket-default stroke vici updown
Listening IP addresses:
  198.51.100.10
  192.168.10.1
Connections:
      a-to-b:  198.51.100.10...198.51.100.20  IKEv2
      a-to-b:   local:  [gw-a.example.com] uses pre-shared key authentication
      a-to-b:   remote: [gw-b.example.com] uses pre-shared key authentication
      a-to-b:   child:  192.168.10.0/24 === 192.168.20.0/24 TUNNEL
Routed Connections:
      a-to-b{1}:  ROUTED, TUNNEL, reqid 1
Security Associations (1 up, 0 connecting):
      a-to-b[1]: ESTABLISHED 2 seconds ago, 198.51.100.10[gw-a.example.com]...198.51.100.20[gw-b.example.com]
```

5. Compare the two front-ends against one shared daemon:

```bash
sudo ipsec status
sudo swanctl --list-sas     # same charon, different control interface
sudo ipsec up a-to-b
sudo ipsec down a-to-b
```

6. Tune the daemon itself. `/etc/strongswan.conf` is the *daemon* configuration — it does not describe connections:

```bash
sudo tee /etc/strongswan.conf <<'EOF'
charon {
    load_modular = yes
    install_routes = yes
    install_virtual_ip = yes
    retransmit_tries = 5
    retransmit_timeout = 4.0
    plugins {
        include strongswan.d/charon/*.conf
    }
    filelog {
        stderr {
            default = 1
            ike = 2
            knl = 2
        }
    }
}
include strongswan.d/*.conf
EOF
sudo ipsec restart
```

Inspect the modular plugin tree that `include` pulls in:

```bash
ls /etc/strongswan.d/charon/ | head
cat /etc/strongswan.d/charon/kernel-netlink.conf
```

7. **L2TP/IPsec awareness.** L2TP carries PPP; it provides *no* encryption of its own, so it is wrapped in an IPsec **transport-mode** SA protecting UDP/1701. Study the two halves without necessarily deploying them.

The IPsec half (IKEv1 for legacy Windows/macOS/Android clients), as a `swanctl` child:

```conf
connections {
    l2tp-rw {
        version      = 1
        local_addrs  = 198.51.100.10
        remote_addrs = %any
        local  { auth = psk; id = 198.51.100.10 }
        remote { auth = psk }
        children {
            l2tp {
                local_ts      = 198.51.100.10[udp/l2tp]
                remote_ts     = dynamic[udp/%any]
                mode          = transport
                esp_proposals = aes256-sha256,aes128-sha1
            }
        }
        proposals = aes256-sha256-modp2048,aes128-sha1-modp1024
    }
}
```

The L2TP half, `/etc/xl2tpd/xl2tpd.conf`:

```ini
[global]
port = 1701
access control = no

[lns default]
ip range = 10.9.0.10-10.9.0.100
local ip = 10.9.0.1
require chap = yes
refuse pap = yes
require authentication = yes
name = LNS-gw-a
ppp debug = no
pppoptfile = /etc/ppp/options.xl2tpd
length bit = yes
```

`/etc/ppp/options.xl2tpd`:

```
ipcp-accept-local
ipcp-accept-remote
ms-dns 192.168.10.1
noccp
auth
mtu 1400
mru 1400
lcp-echo-failure 5
lcp-echo-interval 30
connect-delay 5000
```

8. Confirm the transport-mode selector carries a port, which the tunnel-mode one did not:

```bash
sudo ip xfrm policy | grep -A2 'sport 1701\|dport 1701'
```

```
src 198.51.100.10/32 dst 0.0.0.0/0 proto udp sport 1701
	dir out priority 367231 ptype main
	tmpl src 0.0.0.0 dst 0.0.0.0
		proto esp reqid 3 mode transport
```

9. Observe NAT traversal. From a client behind NAT, the ESP packets are encapsulated in UDP/4500:

```bash
sudo tcpdump -n -i eth0 -c 4 'udp port 4500'
sudo ip xfrm state | grep -A1 encap
```

```
	encap type espinudp sport 4500 dport 4500 addr 0.0.0.0
```

### Checkpoint questions — Exercise 7

36. `ipsec.conf` and `swanctl.conf` produced the same tunnel. Name the process each one talks to, the IPC mechanism each uses, and state the current upstream status of the legacy path.
37. `/etc/ipsec.conf` and `/etc/strongswan.conf` are different files with overlapping names. State what each configures, and say which one you would edit to change retransmission behaviour versus to change a traffic selector.
38. The exclamation mark in `ike = aes256-sha256-modp3072!` is not decoration. What does it change, and what is the security argument for using it?
39. In `ipsec.conf`, `left` and `right` are not "us" and "them". State the actual rule strongSwan uses to decide which side is local, and explain why that makes the same file copyable to both peers.
40. L2TP adds no confidentiality. Given that, name the two things L2TP/IPsec provides that a bare transport-mode IPsec SA does not, and explain why the IPsec half uses transport rather than tunnel mode.
41. `ip xfrm state` shows `encap type espinudp sport 4500 dport 4500`. Explain the NAT problem this solves, and specifically why plain ESP cannot traverse a NAT device that does port translation.
42. `uniqueids = yes` is set in `config setup`. Describe its effect when the same certificate or ID connects twice, and give one scenario where you would set it to `no` and one where you would set it to `replace`.

---

## Exercise 8 — Comparative diagnosis under failure

**Objective:** build the reflex of choosing the right tool for the layer that is broken.

### Steps

1. Establish both VPNs simultaneously (OpenVPN from `rw1`, IPsec `gw-a`↔`gw-b`) and record a healthy baseline:

```bash
sudo swanctl --list-sas --raw | wc -l
sudo cat /run/openvpn-server/status-server.log | grep -c '^CLIENT_LIST'
sudo ip xfrm state | grep -c 'proto esp'
```

2. **Injection A — ESP blocked, IKE allowed.** On `gw-b`:

```bash
sudo nft add rule inet vpn input meta l4proto esp drop
sudo swanctl --terminate --ike a-to-b ; sudo swanctl --initiate --child net-net
```

Observe: `swanctl --list-sas` reports `ESTABLISHED` and `INSTALLED`, `in` counters stay at 0, and pings fail. Confirm:

```bash
sudo swanctl --list-sas | grep -E 'in |out '
```

```
    in  c1a2b3c4,      0 bytes,     0 packets
    out d4e5f6a7,    504 bytes,     6 packets,     1s ago
```

Remove the rule.

3. **Injection B — clock skew.** On `rw1`:

```bash
sudo timedatectl set-ntp false
sudo date -s '2029-01-01 00:00:00'
sudo openvpn --config /etc/openvpn/client/roadwarrior1.conf --verb 3
```

```
VERIFY ERROR: depth=0, error=certificate has expired: CN=gw-a.example.com
TLS_ERROR: BIO read tls_read_plaintext error
```

Restore: `sudo timedatectl set-ntp true`.

4. **Injection C — asymmetric MTU.** On `gw-a`:

```bash
sudo ip link set dev eth0 mtu 1400
```

From `rw1`, small pings through the OpenVPN tunnel succeed, `ssh` and `curl` of large pages hang. Confirm the signature, then fix it properly:

```bash
ping -c2 192.168.10.50                       # OK
curl -s -o /dev/null -w '%{http_code}\n' --max-time 8 http://192.168.10.50/  # hangs
# server-side remedy
echo 'mssfix 1300 mtu' | sudo tee -a /etc/openvpn/server/server.conf
sudo systemctl restart openvpn-server@server
# and for the IPsec path
sudo nft add rule inet vpn forward tcp flags syn tcp option maxseg size set rt mtu
```

Restore MTU 1500 afterwards.

5. **Injection D — overlapping selectors.** On `gw-b`, change `local_ts` to `192.168.0.0/16`, reload, and initiate from `gw-a`:

```
received TS_UNACCEPTABLE notify, no CHILD_SA built
```

Restore.

6. Build the decision table for yourself and fill in the middle column from the exercises above:

| Symptom | First command | Layer |
|---|---|---|
| `swanctl --list-sas` empty | | IKE |
| SA `INSTALLED`, `in` counter 0 | | ESP / firewall |
| OpenVPN: `TLS key negotiation failed` | | control channel |
| OpenVPN: `AUTH_FAILED` | | authentication |
| Ping works, TCP hangs | | MTU / PMTUD |
| `TS_UNACCEPTABLE` | | traffic selectors |
| `NO_PROPOSAL_CHOSEN` | | crypto negotiation |

### Checkpoint questions — Exercise 8

43. In Injection A, `swanctl` reported the SA as healthy while the tunnel carried nothing in one direction. Explain why the daemon cannot detect this by itself, and name the single configuration setting that *would* have detected it — and how long it would take.
44. Injection B produced a certificate error on the *client* even though nothing on the server changed. Beyond certificate validity windows, name one other time-sensitive element of each stack (OpenVPN and IPsec) that a skewed clock breaks.
45. Injection C: explain why `ping` succeeded and `curl` hung, why the failure appeared only after reducing the *transit* MTU rather than the tunnel MTU, and why the `nft` MSS clamp helps the IPsec path but not a UDP-based application over it.
46. Injection D returned `TS_UNACCEPTABLE` rather than `NO_PROPOSAL_CHOSEN`. Given the exchange in which each is sent, what does receiving `TS_UNACCEPTABLE` tell you about the state of authentication at that moment?
47. State two structural reasons an operator might choose OpenVPN over strongSwan for a road-warrior deployment, and two reasons to choose IPsec for a site-to-site link — using evidence you actually observed in these exercises.

---

## Answers

<details>
<summary><strong>Click to expand the answers to all 47 questions</strong></summary>

### Exercise 1 — PKI

**1.** `EASYRSA_ALGO ec` selects ECDSA keys, and OpenVPN then negotiates **ECDHE** for perfect forward secrecy, which needs no precomputed parameter file — hence `dh none` is acceptable and `gen-dh` is unnecessary. You still need `./easyrsa gen-dh` when the server certificate is RSA and you want (or the peer only supports) finite-field `DHE` key exchange, or when running OpenVPN 2.3-era peers that do not implement ECDHE.

**2.** Without EKU checking, any holder of a certificate signed by your CA — including every legitimate *client* — can impersonate the *server*. A malicious or compromised client stands up a fake OpenVPN endpoint, presents its own valid client certificate, and other clients accept it: a full man-in-the-middle inside your own trust domain. `remote-cert-tls server` on the client requires `extendedKeyUsage = serverAuth` plus the matching `keyUsage`; the server's `remote-cert-tls client` enforces the mirror. The deprecated equivalent was `ns-cert-type server`.

**3.** `tc.key` protects the **TLS control channel**, not the data channel. With `tls-crypt`, every control-channel packet — including the very first one of the handshake — is encrypted *and* authenticated with this pre-shared key before the TLS session exists. An attacker without it sees UDP datagrams to port 1194 with high-entropy payloads and cannot identify them as OpenVPN, cannot see the certificates exchanged, and cannot elicit any response from the server.

**4.** With `user nobody`, OpenVPN drops privileges after initialisation but **re-reads `crl.pem` on every incoming connection** (since 2.4). If the file is `0600 root:root`, the running daemon can no longer open it. Mode `0644` (with all parent directories traversable by others) keeps it readable. A CRL is public data by design — it contains no secrets.

**5.** On day 181 the CRL is expired, and OpenVPN treats an expired CRL as a hard failure: **every** client is rejected with `VERIFY ERROR: depth=0, error=CRL has expired`. Revocation lists must be regenerated and redistributed on a schedule shorter than `EASYRSA_CRL_DAYS`; this is one of the most common self-inflicted total outages in OpenVPN deployments.

### Exercise 2 — Routed server

**6.** With `topology net30` the server takes `10.8.0.1` peered with `10.8.0.2`, and the first client gets `10.8.0.6` peered with `10.8.0.5` — a separate /30 per client, consuming four addresses each. It exists because Windows TAP-Win32 drivers historically could not represent a subnet on a point-to-point interface. `topology subnet` is the correct modern choice: one address per client, `/24` on the interface, and it must match on both ends (the server pushes `topology subnet` in `PUSH_REPLY`).

**7.** `route` adds `192.168.20.0/24 dev tun0 scope link` to the **server's own kernel routing table**, so the host knows to hand those packets to the OpenVPN process. It has **not** told OpenVPN's *internal* client routing table which connected client owns that subnet — that requires `iroute` in a `ccd` file (Exercise 4) — and it has not told any other VPN client about the route, which requires `push "route ..."`. All three are needed for the site-to-site case.

**8.** OpenVPN performs privileged operations first — binds UDP/1194, opens `/dev/net/tun`, creates `tun0`, installs routes — and only then calls `setgid`/`setuid`. The log confirms the order: `net_iface_up` precedes `GID set to nogroup`. `persist-tun` keeps the tun device open across a `SIGUSR1` restart so it need not be recreated (which the unprivileged process could not do); `persist-key` keeps key files in memory so they need not be re-read from disk (which the unprivileged process may no longer be permitted to do). Without both, a `--ping-restart` triggers a permanent failure.

**9.** `data-ciphers AES-256-GCM:CHACHA20-POLY1305` is a *negotiated list*; a 2.4 client that cannot do NCG falls back through `data-ciphers-fallback` or the legacy `--cipher` value. It is a security decision because the fallback cipher is used **unauthenticated by negotiation** — it is whatever the config says, typically AES-256-CBC with a separate HMAC, which lacks AEAD and is subject to padding-oracle-class risks that GCM eliminates. In OpenVPN 2.6, omitting `data-ciphers-fallback` means non-negotiating clients are simply refused, which is the safe default.

**10.** `explicit-exit-notify` makes the peer send an explicit `OCC_EXIT` message on shutdown, so the other side tears the session down immediately instead of waiting out `ping-restart` (60 s here). It is meaningless over TCP because TCP already signals termination with FIN/RST, so the peer learns of the disconnect from the transport itself. OpenVPN will refuse the directive on a TCP instance.

### Exercise 3 — Client and diagnostics

**11.**
- `VERIFY OK: depth=1` — CA chain validation, requested by `ca` (always performed).
- `VERIFY KU OK` — `keyUsage` check, from `remote-cert-tls server`.
- `VERIFY EKU OK` — `extendedKeyUsage = serverAuth`, from `remote-cert-tls server`.
- `VERIFY X509NAME OK` — from `verify-x509-name gw-a.example.com name`.

Remove `remote-cert-tls server` and the KU/EKU lines disappear; chain validation and the X509NAME check still fire. Note that `verify-x509-name` alone is *not* a substitute: an attacker who can obtain a certificate with that CN from the same CA still passes it.

**12.** A client trusting `PUSH_REPLY` is letting the server rewrite its routing table, DNS resolvers and (with `redirect-gateway`) default route. A compromised or spoofed server can therefore hijack all of the client's traffic and DNS. `pull-filter ignore "..."` (or `pull-filter accept`/`reject`) restricts which pushed options are honoured — e.g. `pull-filter ignore "dhcp-option DNS"` or `pull-filter ignore "redirect-gateway"`. `route-nopull` disables pushed routes entirely.

**13.** 64 bytes ICMP payload + 8 ICMP header + 20 IP header = 92 bytes of inner packet; AES-256-GCM adds a 4-byte packet ID/opcode, a 16-byte authentication tag and the peer-id byte, landing at 105. An observer still learns source/destination endpoints, packet timing, packet sizes and total volume — enough to fingerprint interactive SSH versus bulk transfer versus video, and often enough to identify the visited service by traffic-pattern analysis. Encryption protects content, not metadata.

**14.** `-M do` sets the Don't-Fragment bit; the local stack compares 1450 + 28 = 1478 against `tun0`'s MTU of 1500 minus what OpenVPN's own encapsulation will consume, and refuses the write locally rather than emitting an unfragmentable packet. `mssfix` is the fix: it rewrites the **TCP MSS option in SYN packets** traversing the tunnel so both TCP endpoints negotiate a segment size that fits. It does nothing for UDP because UDP has no MSS negotiation — a UDP application must discover the path MTU itself or be told, which is exactly why DNS-over-QUIC, WireGuard-in-OpenVPN and large-payload UDP protocols break in ways TCP does not.

**15.** `tls-crypt` encrypts and HMACs the client's first control packet with the pre-shared `tc.key`. The server computes the HMAC over the received packet, gets a mismatch, and **drops the packet before allocating any state or writing any log entry at default verbosity** — there is no TLS session, no certificate parse, nothing to log. Benefit: the server is invisible to port scanners and immune to TLS-layer DoS from unauthenticated peers, and no OpenVPN CVE in the TLS parsing path is reachable without the key. Cost: a client with the wrong or missing `tc.key` gets zero server-side diagnostics — you must raise `verb` to 6+ on the server or capture packets to see anything.

**16.** `tls-auth` provides HMAC **authentication only**: the control channel is signed but still readable, so an observer can fingerprint OpenVPN and read the certificate exchange. `tls-crypt` provides authentication **and encryption** of the control channel, hiding certificates and making the protocol unidentifiable. Second difference: `tls-auth` requires the `key-direction` (0/1) to be opposite on the two peers; `tls-crypt` derives directional keys itself and needs no such parameter. `tls-crypt-v2` adds **per-client keys**: each client gets a unique wrapped key that the server can unwrap with a metadata-bearing server key, so a single leaked client key does not compromise the whole fleet's control-channel privacy, and clients can be individually blocked via `tls-crypt-v2-verify`.

### Exercise 4 — CCD, iroute, revocation

**17.**
- `route 192.168.20.0 255.255.255.0` (server config) → the **server host's kernel routing table**: "send these packets into `tun0`."
- `push "route ..."` → the **client's** kernel routing table, delivered in `PUSH_REPLY`.
- `iroute 192.168.20.0 255.255.255.0` (ccd) → OpenVPN's **internal client routing table**: "this specific connected client owns that subnet."

Omit only the `iroute` and the packet reaches the OpenVPN process (the kernel route exists) but the daemon has no idea which of its clients to hand it to, so it is dropped. The log shows nothing at `verb 3`; at `verb 6` you see `MULTI: bad source address from client`-class messages or silent discards.

**18.** If the ccd file does not exist, OpenVPN simply uses the defaults — the client gets a pool address and no per-client options, silently. `ccd-exclusive` in the server config turns that into a hard rejection: only clients with a matching ccd file may connect. This is also the correct way to build a certificate-plus-whitelist authorisation model.

**19.** OpenVPN re-reads `crl.pem` **on each incoming client connection attempt** (behaviour since 2.4; older versions cached it at startup and needed a restart). With `chroot /var/lib/openvpn`, the daemon's filesystem root changes after initialisation, so a path like `/etc/openvpn/server/crl.pem` becomes unreachable on the second and every subsequent read. The CRL file must be placed *inside* the chroot and the path expressed relative to it.

**20.** The daemon keeps running and keeps accepting clients — including revoked ones. Depending on version and verbosity you get a per-connection warning (`CRL: cannot read CRL from file`) that scrolls past in the log, or nothing at all. It is worse than a crash because the security control has silently disappeared while every dashboard shows a healthy service; a crash would have paged someone.

**21.** `kill <CN>` terminates the current session, but the client's certificate is still valid and its `resolv-retry infinite` / `persist-tun` configuration makes it reconnect within seconds. The management interface is an operational tool, not an authorisation control. The durable remedies are `./easyrsa revoke` + `gen-crl` + `crl-verify` (cryptographic), or `ccd-exclusive` plus removal of the ccd file (configuration-based), or a `tls-verify`/`auth-user-pass-verify` script consulting an external deny list.

**22.** `verify-x509-name gw-a.example.com name` **does** stop it, provided the stolen certificate has a different CN — the client requires the exact subject name. `remote-cert-tls server` **also** stops it, and more robustly: the stolen certificate is a *client* certificate carrying `extendedKeyUsage = clientAuth`, so it fails the EKU check regardless of its CN. The two are complementary — EKU checking is structural (a client cert can never act as a server), name verification is specific (it pins one identity). Use both.

### Exercise 5 — IKEv2 site-to-site

**23.** `start_action = trap` installs a **trap policy**: the kernel gets an XFRM policy with SPI 0 whose `action` is to signal userspace when a matching packet appears. The first packet from 192.168.10.0/24 to 192.168.20.0/24 triggers an ACQUIRE message to charon, which then runs IKE_SA_INIT/IKE_AUTH, negotiates the CHILD SA, and replaces the trap with real SAs. Until then `ip xfrm state` is legitimately empty — there is a policy but no security association. Packets that trigger the acquire are typically dropped or held briefly, which is why the first ping of a `trap` tunnel often shows one lost packet.

**24.** `dir out`, `dir in`, `dir fwd`. The `fwd` policy is required specifically because this host is a **gateway**: it applies to decrypted packets that arrive from the tunnel and are then *forwarded* to another interface (toward the LAN), as opposed to `in`, which covers packets destined for the local host itself. A pure host-to-host endpoint needs only `in` and `out`.

**25.** The **IKE SA** is the control-plane association: it authenticates the peers and carries the encrypted negotiation of everything else. Each IKE SA can carry many **CHILD SAs**, which are the actual ESP data-plane associations, one pair per protected traffic-selector set. Every CHILD SA is unidirectional in the kernel, so there are always two — inbound and outbound — each identified by a 32-bit **SPI**. Crucially, **each side chooses the SPI for the SA on which it will *receive***, and communicates it to the peer; the peer puts it in the outbound packets. That is why `in` and `out` SPIs differ and why `gw-a`'s `out` SPI equals `gw-b`'s `in` SPI.

**26.** IPsec with kernel XFRM is a *policy* applied to packets on the existing interface; there is no virtual device. Consequences: **(a) firewalling** — you cannot write `iifname "ipsec0"` rules; you must match on the inner addresses in the `forward` chain plus `meta ipsec exists` / `ct` state, or use `xfrm` interfaces (`ip link add ipsec0 type xfrm if_id 42`) which strongSwan supports via `if_id_in`/`if_id_out`. **(b) monitoring** — there is no per-tunnel interface counter for tools that poll `/proc/net/dev` or SNMP `ifTable`; you must read `ip -s xfrm state` or `swanctl --list-sas` instead, which many NMS platforms do not do out of the box.

**27.** Without the `accept` rule, a packet from 192.168.10.50 to 192.168.20.50 traverses `forward`, then hits the `postrouting` masquerade rule (which matches `oifname eth1` or a broad source match) and has its source address rewritten to the gateway's own address. The XFRM outbound policy matches on `src 192.168.10.0/24` — which no longer holds — so the packet is emitted **in clear** on `eth0` instead of being encrypted. The operator's report is "the tunnel is up but the LANs cannot reach each other", with `swanctl --list-sas` showing zero packets in both directions.

**28.** `start_action = start` initiates the CHILD SA immediately on load and keeps it up; `trap` installs a policy and initiates only when matching traffic appears. **(a)** A branch office that must be reachable *from* headquarters needs `start` — with `trap`, traffic originating at HQ arrives at the branch's trap-less side and there is nothing to trigger the tunnel from the branch end; unidirectional traps produce "it only works after someone at the branch pings first." **(b)** A metered LTE backup link should use `trap`, so no keepalive or rekey traffic is billed while the link is idle.

**29.** MOBIKE (RFC 4555, **IKEv2 only**) lets an established IKE SA and its CHILD SAs survive a change of the peer's IP address or interface — the peer sends an `UPDATE_SA_ADDRESSES` and the SAs are re-anchored without re-authenticating. Irrelevant for a fixed site-to-site tunnel because neither endpoint address ever changes, and disabling it removes an unnecessary attack surface. Essential for a laptop that roams from Ethernet to Wi-Fi to LTE: without MOBIKE, every network change forces a full IKE re-negotiation and drops every TCP session.

### Exercise 6 — Certificates and transport mode

**30.** In **tunnel mode** the entire original IP packet is encapsulated and a **new outer IP header** is built with the gateway addresses as source and destination; the kernel must know those addresses in advance, so they appear literally in the template. In **transport mode** the original IP header is *kept* and only the payload is protected — there is no new outer header to construct, so the template addresses are `0.0.0.0` (meaning "use the packet's own addresses"). This is also why transport mode only works when the IPsec endpoints are the communicating hosts themselves.

**31.** Transport mode preserves the original IP header, so the addresses on the wire are the *hosts'* addresses (192.168.10.50 → 192.168.20.50) — private addresses that the transit network cannot route, and which do not identify the gateways that hold the SA. There is no outer header carrying the packet between 198.51.100.10 and 198.51.100.20. Joining two networks fundamentally requires encapsulation, hence tunnel mode.

**32.** `ikeIntermediate` sets a strongSwan-specific `nsCertType`-style extension used by **IKEv1** peers that require the certificate to be marked as suitable for IKE. It is **not required for IKEv2** and is harmless; it is included in many examples for backward compatibility with older interoperating implementations. The meaningful flags for IKEv2 are `serverAuth`/`clientAuth` (or none at all — IKEv2 does not mandate EKU).

**33.** `/etc/swanctl/x509ca` must contain the **CA certificate** — that is what validates the remote peer's certificate. The remote peer's own certificate need not be present locally because IKEv2 transmits it in the `CERT` payload during `IKE_AUTH`; the local side validates the received certificate against the trusted CA chain and then checks it against the configured `remote.id`. Pre-placing the peer certificate in `/etc/swanctl/x509` is only necessary when the peer does not send it, or when you want to pin it. `/etc/swanctl/x509crl` holds CRLs; `/etc/swanctl/private` holds your own key.

**34.** `NO_PROPOSAL_CHOSEN` for the IKE SA arrives during **`IKE_SA_INIT`**, the first, unencrypted and unauthenticated exchange. `AUTHENTICATION_FAILED` arrives during **`IKE_AUTH`**, which is encrypted under keys derived in `IKE_SA_INIT`. Therefore an unauthenticated attacker can probe your *IKE* proposal set freely and learn which algorithms you accept, but learns nothing about your identities or credentials. (In step 8 the mismatch was in the *ESP* proposals, so it was reported inside the already-encrypted `IKE_AUTH`/`CREATE_CHILD_SA` — visible only to the authenticated peer.)

**35.** With `auth = pubkey`, the `id` is the IKE identity asserted in the `IDi`/`IDr` payload and it must match the certificate's **subject DN** or one of its **subjectAltName** entries. If it does not, the peer cannot map the presented certificate to any configured connection and answers `AUTHENTICATION_FAILED`, with the log line `no matching peer config found for '<local id>'...'<remote id>'` — which names both identities as seen, making the mismatch immediately diagnosable. A constraint violation (e.g. the certificate is valid but the ID is not covered by it) logs `constraint check failed`.

### Exercise 7 — Legacy tooling and L2TP

**36.** Both talk to the **same `charon` daemon**. `ipsec`/`ipsec.conf` goes through the `starter` process, which parses `ipsec.conf` and speaks the **stroke** protocol over a Unix socket to charon's `stroke` plugin. `swanctl`/`swanctl.conf` speaks **VICI** (Versatile IKE Configuration Interface) over `/var/run/charon.vici` to the `vici` plugin — a documented, versioned, library-backed API. Upstream, `starter`/`stroke`/`ipsec.conf` have been **deprecated since strongSwan 5.6 and removed in strongSwan 6.0**; `swanctl` is the supported path. The exam still lists the legacy files, so you must be able to read them.

**37.** `/etc/ipsec.conf` (or `swanctl.conf`) configures **connections**: peers, identities, authentication, traffic selectors, modes, lifetimes. `/etc/strongswan.conf` configures the **daemon and its plugins**: thread pool, retransmission timers, logging, route installation, plugin behaviour — with `/etc/strongswan.d/*.conf` and `/etc/strongswan.d/charon/*.conf` included modularly. Retransmission behaviour (`retransmit_tries`, `retransmit_timeout`) → `strongswan.conf`. A traffic selector (`leftsubnet` / `local_ts`) → `ipsec.conf` / `swanctl.conf`.

**38.** Without `!`, the listed proposals are **appended to strongSwan's built-in default set**, so the daemon will also accept algorithms you did not list — including weaker ones still present in the defaults. With `!`, the list is **exclusive**: only exactly what you wrote is proposed and accepted. The security argument is that algorithm negotiation resolves to the strongest *mutually supported* option, and an attacker who can influence the peer's proposal (or a misconfigured peer) will otherwise silently land on the weakest common denominator. `!` makes the policy auditable: what the file says is what the tunnel uses. (In `swanctl.conf` this is the default behaviour — proposals are exclusive unless you write `default`.)

**39.** strongSwan decides at load time: the side whose IP address (or the interface addresses of the host) matches `left` becomes **local**; if `left` matches nothing local, it tries `right`, and swaps the two. `%any` and hostname resolution participate in this. Because the decision is made per-host at runtime, the *same* `ipsec.conf` can be copied verbatim to both peers — a deliberate design property that also explains why `leftid`/`rightid` and `leftsubnet`/`rightsubnet` must be written as a symmetric pair rather than as "mine"/"theirs".

**40.** L2TP/IPsec adds **(a) PPP-based user authentication** (CHAP/MS-CHAPv2 against a user database, RADIUS, etc.) on top of the machine-level IPsec authentication, and **(b) address, DNS and route assignment to the client via IPCP** — a PPP virtual interface with a pool-assigned address, which a bare transport-mode SA has no mechanism to provide. The IPsec half uses **transport** mode because L2TP already does the encapsulation: the packets to protect are UDP/1701 datagrams exchanged between the two real endpoint addresses, and adding an IPsec tunnel header on top would be redundant encapsulation.

**41.** ESP is IP protocol 50 — it has **no port numbers**. A NAT device performing port translation has nothing to rewrite and no way to demultiplex return traffic to the correct internal host, so a second client behind the same NAT is indistinguishable from the first. Worse, ESP's integrity check covers fields that NAT would rewrite. NAT-Traversal (RFC 3948) detects NAT during IKE (via `NAT_DETECTION_SOURCE_IP`/`DESTINATION_IP` payloads), moves IKE to **UDP/4500**, and wraps every ESP packet in a UDP/4500 header — giving the NAT device ports to translate. The kernel records this as `encap type espinudp`.

**42.** `uniqueids = yes` means that when a peer authenticates with an identity that already has an established IKE SA, the **old SA is deleted** — the newest connection wins. Set it to `no` when one identity legitimately serves many simultaneous sessions (a shared machine certificate on a NAT'd fleet, or a load-balanced pair). Set it to `replace` (or `keep`) when you need the explicit semantic: `replace` deletes the old SA only after the new one authenticates successfully; `keep` rejects the *new* connection and preserves the existing one — appropriate when a flapping client would otherwise repeatedly kill a working session.

### Exercise 8 — Comparative diagnosis

**43.** The IPsec data plane lives entirely in the kernel; charon installs the SAs and then sees no packets. It has no visibility into whether inbound ESP is arriving unless something asks. The setting that detects it is **DPD** — `dpd_delay` / `dpd_timeout` (or `dpdaction`/`dpddelay` in `ipsec.conf`), which sends IKEv2 `INFORMATIONAL` liveness probes and tears down or restarts the SA when they go unanswered. With `dpd_delay = 30s` and `dpd_timeout = 120s`, detection takes up to about two minutes. Note that DPD probes travel over **IKE (UDP/500 or 4500)**, so in this specific injection — where IKE is allowed and only ESP is blocked — DPD would still succeed and would *not* detect the problem. Detecting a black-holed ESP path requires end-to-end probing of the protected traffic itself, or watching the `in` byte counter, which is precisely why the counter exists.

**44.** OpenVPN: **TLS session and renegotiation timing** (`reneg-sec`) and certificate `notBefore`/`notAfter`, plus **CRL `Last Update`/`Next Update`** validity — a clock in the future makes an otherwise-current CRL appear expired and rejects every client. IPsec: **certificate validity and CRL/OCSP freshness** for `auth = pubkey`, and **SA lifetimes** (`rekey_time`, `life_time`) — a large skew causes SAs to be considered expired immediately after installation, producing a rekey storm. In both stacks, correct NTP is a hard dependency, not a nicety.

**45.** `ping` sent 64-byte payloads, which fit within even a 1400-byte path; `curl` triggered a full-size TCP data segment sized from the *tunnel* MTU (1500), which then had to cross a 1400-byte transit link after OpenVPN's ~50-byte encapsulation. The resulting UDP datagram exceeded the path MTU with DF set; the ICMP "fragmentation needed" was either not generated or not delivered, so the connection hung after the handshake — the classic PMTUD black hole. It appeared only when the *transit* MTU shrank because the tunnel MTU had been consistent on both sides; the mismatch is always between the encapsulated packet size and what the underlay will carry. The `nft` MSS clamp helps the IPsec path because it rewrites the TCP MSS option in SYN packets being forwarded, causing both TCP endpoints to negotiate segments that fit — but UDP has no MSS to clamp, so a UDP application over IPsec must be fixed at the application layer or by lowering the endpoint MTU.

**46.** `TS_UNACCEPTABLE` is sent in response to a CHILD SA negotiation (`IKE_AUTH` or `CREATE_CHILD_SA`), both of which occur **after** the peers have mutually authenticated and are exchanging encrypted, integrity-protected messages. Receiving it therefore proves authentication succeeded: your credentials, identities and IKE proposals are all correct, and the problem is purely a configuration mismatch in the traffic selectors. This is diagnostically valuable — it eliminates the entire PKI/PSK surface from the investigation in one step.

**47.** **OpenVPN for road warriors:** (i) it runs over a single UDP or **TCP** port and can be made to look like ordinary TLS traffic, so it traverses restrictive networks and NAT without NAT-T gymnastics — you saw plain UDP/1194 in the capture, with no ESP and no protocol-50 firewall requirement; (ii) it presents a real `tun0` interface, so per-client firewalling, `iptables`/`nft` interface matching, and interface-based monitoring work with ordinary tooling — and per-client policy via `ccd`/`ifconfig-push` needed no kernel involvement at all. **IPsec for site-to-site:** (i) encryption and encapsulation happen in the **kernel** with no userspace copy per packet and with hardware offload available, so throughput on a gateway is materially higher — the tunnel in Exercise 5 required no daemon involvement in the data path at all; (ii) it is a vendor-neutral standard, so `gw-b` could be a Cisco, Juniper, Fortinet or a cloud provider's VPN gateway, and the same `swanctl.conf` semantics apply — whereas OpenVPN requires OpenVPN at both ends.

</details>

---

## Sources

- LPI, *Exam 303 Objectives (303-300, v3.0.0)* — <https://www.lpi.org/our-certifications/exam-303-objectives/>
- OpenVPN Community, *Reference Manual for OpenVPN 2.6* — <https://openvpn.net/community-resources/reference-manual-for-openvpn-2-6/>
- OpenVPN Community, *HOWTO* — <https://openvpn.net/community-resources/how-to/>
- OpenVPN, *Easy-RSA 3 Documentation* — <https://github.com/OpenVPN/easy-rsa/blob/master/doc/EasyRSA-Advanced.md>
- strongSwan, *swanctl.conf reference* — <https://docs.strongswan.org/docs/latest/swanctl/swanctlConf.html>
- strongSwan, *strongswan.conf reference* — <https://docs.strongswan.org/docs/latest/config/strongswanConf.html>
- strongSwan, *Deprecated ipsec.conf / starter* — <https://docs.strongswan.org/docs/latest/config/ipsecConf.html>
- strongSwan, *pki — Public Key Infrastructure tool* — <https://docs.strongswan.org/docs/latest/pki/pki.html>
- strongSwan, *IKEv2 Cipher Suites / proposal syntax* — <https://docs.strongswan.org/docs/latest/config/proposals.html>
- strongSwan, *Forwarding and Split Tunneling* — <https://docs.strongswan.org/docs/latest/howtos/forwarding.html>
- RFC 7296, *Internet Key Exchange Protocol Version 2 (IKEv2)* — <https://www.rfc-editor.org/rfc/rfc7296>
- RFC 4303, *IP Encapsulating Security Payload (ESP)* — <https://www.rfc-editor.org/rfc/rfc4303>
- RFC 3948, *UDP Encapsulation of IPsec ESP Packets* — <https://www.rfc-editor.org/rfc/rfc3948>
- RFC 4555, *IKEv2 Mobility and Multihoming Protocol (MOBIKE)* — <https://www.rfc-editor.org/rfc/rfc4555>
- RFC 3193, *Securing L2TP using IPsec* — <https://www.rfc-editor.org/rfc/rfc3193>
- man-pages project, *ip-xfrm(8)* — <https://man7.org/linux/man-pages/man8/ip-xfrm.8.html>
- xl2tpd, *upstream repository and configuration* — <https://github.com/xelerance/xl2tpd>