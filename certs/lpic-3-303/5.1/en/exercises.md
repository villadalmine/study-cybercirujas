# LPIC-3 Exam 303-300 (v3.0) — Topic 334 / 5.1: Network Security

**Level:** Advanced / Production Architecture  
**Exam Weight:** 16.67 (Topic 334 overall weight)  
**Official Reference:** [LPI LPIC-3 303 Overview](https://www.lpi.org/our-certifications/lpic-3-303-overview/) | [Netfilter nftables Documentation](https://netfilter.org/projects/nftables/) | [WireGuard Technical Whitepaper](https://www.wireguard.com/papers/wireguard.pdf) | [Suricata User Guide](https://docs.suricata.io/)

---

## Technical Overview & Core Architecture

Network Security in enterprise Linux environments requires defense-in-depth across the kernel networking stack, traffic filtering hooks, real-time deep packet inspection (DPI), and cryptographically secure transit tunnels. 

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

The core topics covered in this module are:
1. **Network Hardening:** Kernel tuning via `/proc/sys/net/` sysctl interfaces (RFC 3704 Reverse Path Filtering, TCP SYN cookies, ICMP redirect rejection), ARP poisoning defenses, and socket state auditing with `ss`/`iproute2`.
2. **Packet Filtering:** Next-generation netfilter architecture with `nftables`, dual-lookup table design, atomic rule replacement, stateful connection tracking (`conntrack`), and high-throughput set/map lookups.
3. **Network Intrusion Detection & Prevention (NIDS/NIPS):** Multi-threaded signature parsing, stream reassembly, and JSON event logging (`eve.json`) using Suricata, paired with dynamic automated IP banning via `fail2ban`.
4. **Virtual Private Networks (VPNs):** Site-to-Site and Remote Access tunneling using WireGuard (Cryptokey Routing, NoiseIK protocol), IPsec strongSwan (IKEv2, ESP/AH transport/tunnel modes), and OpenVPN (TLS authentication and TUN/TAP virtual adapters).

---

## Lab Prerequisites

All commands in these exercises assume a modern Enterprise Linux system (kernel 5.4+ / Linux 6.x) with `root` administrative privileges. Packages required across exercises: `nftables`, `iproute2`, `wireguard-tools`, `suricata`, `fail2ban`, `strongswan`, `nmap`.

---

## Exercise 1: Advanced Kernel Network Hardening & Socket Auditing

### Architectural Background & Internal Mechanics
The Linux TCP/IP stack implements RFC specifications that can be tuned to mitigate Denial of Service (DoS), IP spoofing, and man-in-the-middle (MitM) attacks.
* **TCP SYN Cookies (`net.ipv4.tcp_syncookies`):** When the TCP SYN backlog queue overflows during a SYN flood attack, the kernel bypasses queue allocation by encoding initial sequence numbers ($ISN$) cryptographically using a secret key, timestamp, and 5-tuple payload hash:
  $$ISN = \text{hash}(src\_ip, src\_port, dst\_ip, dst\_port, secret, timestamp) + seq\_offset$$
  Upon receiving the client's ACK, the kernel verifies $ISN - 1$, validating connection legitimacy zero-memory-cost.
* **Reverse Path Filtering (`net.ipv4.conf.*.rp_filter`):** Strict mode (`1`) performs an RFC 3704 route lookup on incoming packet source IPs. If the best return path route out of the routing table does not match the interface on which the packet arrived, the packet is dropped, preventing IP spoofing.

---

### Step-by-Step Execution

#### Step 1: Audit Active Socket Listeners and Process Bindings
Execute `ss` to inspect all open TCP and UDP listening sockets, displaying numeric ports, memory usage, and process context.

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

#### Step 2: Implement Production Sysctl Hardening Matrix
Create `/etc/sysctl.d/99-network-hardening.conf` with production-hardened kernel networking parameters.

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

Apply the parameters atomically:

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

#### Step 3: Hardening ARP Processing against Cache Poisoning
Configure neighbor table ARP behavior to strictly match incoming responses with local address definitions (`arp_ignore = 1`) and restrict reply mode (`arp_announce = 2`).

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

### Exercise 1 Verification Questions

1. **Question 1.1:** In a system deployed with asymmetric routing (where egress packets exit via interface `eth0` and ingress packets arrive via `eth1`), setting `net.ipv4.conf.all.rp_filter = 1` causes legitimate incoming traffic to be silently dropped by the kernel. Why does this happen, and what is the precise operational difference between strict mode (`1`) and loose mode (`2`) as defined in RFC 3704?
2. **Question 1.2:** How does enabling `net.ipv4.tcp_syncookies` alter the TCP three-way handshake under normal operating conditions vs. under active queue saturation (SYN flood), and what specific TCP header options are sacrificed when SYN cookies are triggered?

---

## Exercise 2: Production Packet Filtering & State Tracking with `nftables`

### Architectural Background & Internal Mechanics
`nftables` replaces legacy `iptables` by integrating packet filtering, NAT, and packet mangling into a single kernel virtual machine (nft_expr engine).
* **Evaluation Speed:** Unlike `iptables`, which evaluates rules linearly ($O(N)$ lookup overhead), `nftables` utilizes native sets and dictionaries, providing constant-time $O(1)$ dynamic lookups even with tens of thousands of IP addresses.
* **Hook Architecture:** Hooks exist at `ingress` (netdev level, before layer 3 handling), `prerouting`, `input`, `forward`, `output`, and `postrouting`.

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

### Step-by-Step Execution

#### Step 1: Flush Existing Legacy Constructs & Create Core Dual-Stack Ruleset
Draft a fully syntactically valid `/etc/nftables.conf` file implementing an enterprise stateful firewall with rate-limiting, dynamic set management, and port knocking/brute-force defense.

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

#### Step 2: Validate Syntax and Apply Atomic Ruleset
Load the configuration into the kernel. `nftables` processes the file atomically; if any syntax error exists, no changes are committed to the running kernel state.

```bash
nft -c -f /etc/nftables.conf && nft -f /etc/nftables.conf
```

Verify running ruleset and active tables:

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

#### Step 3: Runtime Dynamic Set Injection and Inspection
Inject a malicious IP (`192.0.2.50`) into the runtime `dynamic_blacklist` set with a custom 30-minute timeout without reloading the configuration file.

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

### Exercise 2 Verification Questions

1. **Question 2.1:** What distinct memory and CPU performance advantages does an `nftables` dictionary/map construct provide over legacy `iptables` chains when routing traffic to 5,000 distinct backend microservices based on incoming destination ports?
2. **Question 2.2:** In the `nftables.conf` snippet above, explain the internal mechanism of the state tracking expression `ct state { established, related } accept`. Where in the kernel memory model is this connection state stored, and what happens when the `nf_conntrack` table limits are reached?

---

## Exercise 3: Network Intrusion Detection & Automated Prevention (Suricata & Fail2ban)

### Architectural Background & Internal Mechanics
* **Suricata NIDS/NIPS Engine:** Operates as a multi-threaded deep packet inspection (DPI) platform. It processes incoming packets via AF_PACKET or NFQUEUE sockets using runmodes (`workers` mode assigns dedicated threads per CPU core for ingress packet capture, decoding, stream tracking, and signature inspection).
* **Fail2ban Integration:** Continuously parses structured event streams (such as `/var/log/suricata/eve.json` or `/var/log/auth.log`) using regular expression filters. When failure thresholds are reached within a given window, it invokes a configurable `action` (e.g., executing `nft` commands to append offending IPs directly to netfilter sets).

---

### Step-by-Step Execution

#### Step 1: Write Custom Suricata NIDS Detection Rules
Create a custom rules file `/etc/suricata/rules/custom-threats.rules` containing rules for detecting unauthorized database dumps and shell code execution attempts.

```bash
cat << 'EOF' > /etc/suricata/rules/custom-threats.rules
# Detect incoming SQL injection attempted command execution
alert tcp $EXTERNAL_NET any -> $HOME_NET 80 (msg:"EXPLOIT-NIDS Possible SQLi SELECT INTO OUTFILE"; flow:to_server,established; content:"SELECT"; nocase; content:"INTO"; distance:1; nocase; content:"OUTFILE"; distance:1; nocase; classtype:web-application-attack; sid:1000001; rev:1;)

# Detect raw SSH brute force attempts (High rate of TCP SYN without full auth)
alert tcp $EXTERNAL_NET any -> $HOME_NET 22 (msg:"SUSPICIOUS SSH Inbound Traffic High Volume"; flow:to_server; flags:S; threshold: type threshold, track by_src, count 20, seconds 10; classtype:attempted-recon; sid:1000002; rev:1;)
EOF
```

Validate Suricata configuration and rule syntax:

```bash
suricata -T -c /etc/suricata/suricata.yaml -S /etc/suricata/rules/custom-threats.rules
```

**Expected Output:**
```text
Notice: setup-analysis: Configuration provided is valid.
Info: rule-analysis: Successfully loaded 2 rules from file /etc/suricata/rules/custom-threats.rules
```

#### Step 2: Configure Fail2ban Jail using `nftables` Action Mode
Configure `/etc/fail2ban/jail.d/custom-sshd.conf` to monitor SSH authentication failures and automatically update the `nftables` firewall set.

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

Restart Fail2ban service and verify operational jail status:

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

#### Step 3: Simulate Attack and Verify Real-time Automated Ban
Inject test SSH failure logs into `/var/log/auth.log` to trigger the Fail2ban automated enforcement engine.

```bash
cat << 'EOF' >> /var/log/auth.log
2026-08-06T14:10:01.123456+00:00 server sshd[14201]: Failed password for invalid user hacker from 198.51.100.44 port 41234 ssh2
2026-08-06T14:10:03.234567+00:00 server sshd[14202]: Failed password for invalid user hacker from 198.51.100.44 port 41235 ssh2
2026-08-06T14:10:05.345678+00:00 server sshd[14203]: Failed password for invalid user hacker from 198.51.100.44 port 41236 ssh2
EOF
```

Query `fail2ban-client` status to confirm IP banning:

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

Verify active kernel drop rules added by Fail2ban:

```bash
nft list chain inet fail2ban f2b-sshd
```

---

### Exercise 3 Verification Questions

1. **Question 3.1:** What is the technical difference between Suricata running in **IDS mode** via `AF_PACKET` (copying packets from raw sockets) versus **IPS mode** using Linux `NFQUEUE`? What architectural trade-offs exist regarding network latency and packet drop capability?
2. **Question 3.2:** In a high-traffic production system running Suricata, packet drops occur at the ring-buffer level before inspection. Which sysctl and NIC ring settings should be tuned to eliminate ring-buffer drops?

---

## Exercise 4: Enterprise VPN Infrastructure Architecture (WireGuard & IPsec strongSwan)

### Architectural Background & Internal Mechanics
* **WireGuard Cryptokey Routing:** WireGuard eliminates traditional VPN complex state machines by associating public static encryption keys directly with authorized tunnel IP addresses (`AllowedIPs`).
  * Incoming packets: Decrypt, verify Curve25519 signature, match inner source IP with key's `AllowedIPs`. Drop if mismatch.
  * Outgoing packets: Look up destination IP in `AllowedIPs` routing table, select corresponding public key, encrypt via ChaCha20-Poly1305, and transmit over UDP.
* **IPsec strongSwan (IKEv2):** Utilizes two phases:
  * **IKE_SA (Phase 1):** Authenticates peers using X.509 certificates or pre-shared keys (PSK), establishing an encrypted control channel via Diffie-Hellman (ECDH).
  * **CHILD_SA (Phase 2):** Negotiates operational Security Associations (SA) for ESP (Encapsulating Security Payload, protocol 50) to encrypt IPv4/IPv6 payload traffic.

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

### Step-by-Step Execution

#### Step 1: Deploy Secure Hub WireGuard Tunnel Interface
Generate server cryptographic keypairs using `wg genkey`:

```bash
mkdir -p /etc/wireguard
chmod 700 /etc/wireguard
wg genkey | tee /etc/wireguard/server_private.key | wg pubkey > /etc/wireguard/server_public.key
```

Create `/etc/wireguard/wg0.conf` configuration file:

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

Bring up the tunnel interface:

```bash
wg-quick up wg0
```

Verify running tunnel state and kernel interface parameters:

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

#### Step 2: Provision Production Site-to-Site IPsec Configuration using strongSwan VICI/swanctl
Draft `/etc/swanctl/swanctl.conf` for a strict IKEv2 AES-GCM-256 / ECP384 tunnel between Datacenter A (`203.0.113.1`) and Datacenter B (`198.51.100.1`).

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

Load the configuration into strongSwan daemon:

```bash
swanctl --load-all
```

**Expected Output:**
```text
successfully loaded 1 connections
successfully loaded 0 sas
successfully loaded 1 secrets
```

Initiate IPsec tunnel manually and inspect active SAs:

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

### Exercise 4 Verification Questions

1. **Question 4.1:** How does WireGuard handle endpoint IP roaming (e.g., when a mobile peer changes IP addresses from Wi-Fi to LTE) without breaking tunnel state, and how does this contrast with IPsec Security Association re-keying requirements?
2. **Question 4.2:** Explain the operational difference between IPsec **Transport Mode** and **Tunnel Mode**. Which payload headers are encrypted in each, and why is Tunnel Mode required for site-to-site subnet interconnection?

---

<details>
<summary><strong>Exercise Comprehension Answers & Detailed Explanations</strong></summary>

### Exercise 1 Answers

* **Answer 1.1:** Reverse Path Filtering (`rp_filter = 1`) performs strict validation: for any incoming packet on interface $X$, the kernel queries the routing table for the source IP address. If the optimal egress route back to that source IP points to an interface *other* than $X$, the packet is dropped as a spoofing attempt. In asymmetric routing environments, egress packets leave via `eth0` while return ingress traffic arrives on `eth1`. Under strict mode (`1`), when a packet from `192.0.2.10` arrives on `eth1`, the kernel checks its routing table, sees that traffic to `192.0.2.10` is routed out via `eth0`, notices `eth0 != eth1`, and drops the packet. Loose mode (`2`, defined in RFC 3704) verifies only that the source IP address is reachable via *any* active interface in the routing table, allowing asymmetric packets to pass while still dropping completely unroutable (martian/spoofed) IP sources.
* **Answer 1.2:** Under normal operating conditions, the Linux kernel allocates a buffer in the TCP SYN backlog queue and responds with a standard random Initial Sequence Number ($ISN$). When the backlog queue fills completely (e.g., during a SYN flood attack), `net.ipv4.tcp_syncookies = 1` activates. Instead of allocating memory for state tracking, the kernel constructs a SYN cookie $ISN$ containing a 32-bit cryptographic hash derived from the 5-tuple, a secret key, a 5-bit MSS index, and a timestamp counter. When the client sends the final ACK, the kernel decrements the ACK sequence number by 1, recomputes the cryptographic hash, and verifies authenticity without having saved prior state. **Trade-off/Sacrifice:** Because state is not saved in memory, advanced TCP capabilities negotiated during the initial SYN packet—specifically **TCP Window Scaling** (RFC 1323) and **Selective Acknowledgments (SACK)**—are disabled unless encoded into explicit TCP Timestamp options (RFC 7323).

---

### Exercise 2 Answers

* **Answer 2.1:** Legacy `iptables` evaluates rules linearly ($O(N)$ depth). Matching 5,000 distinct ports requires traversing up to 5,000 separate rule entries per packet, consuming substantial CPU cycles and inducing packet latency. `nftables` natively implements named sets and dictionaries backed by **radix trees and hash tables** ($O(1)$ constant-time lookups). Rather than executing 5,000 linear comparison instructions, `nftables` performs a single hash table lookup on the destination port tuple directly mapping to the target chain or action, keeping latency constant regardless of rule count.
* **Answer 2.2:** The `ct state { established, related } accept` expression interacts directly with the Linux netfilter `nf_conntrack` kernel subsystem. Connection tracking maintains a hash table in kernel memory (`/proc/net/nf_conntrack`) tracking 5-tuples (`src_ip`, `src_port`, `dst_ip`, `dst_port`, `protocol`) and protocol state transitions.
  * `established`: Packets belonging to a bidirectionally observed, valid TCP/UDP session.
  * `related`: Packets initiating a new connection but associated with an existing session (e.g., FTP data channels or ICMP error messages).
  If traffic volume exceeds `net.netfilter.nf_conntrack_max`, the connection tracking table exhausts memory allocations. When full, the kernel emits `nf_conntrack: table full, dropping packet` errors and **drops all new incoming unestablished connections**, leading to a complete Denial of Service even if CPU and bandwidth are available.

---

### Exercise 3 Answers

* **Answer 3.1:** 
  * **IDS Mode (`AF_PACKET`):** Suricata opens raw packet socket ring-buffers. The network interface card (NIC) copies incoming packets to both the host protocol stack and Suricata simultaneously. Inspection occurs out-of-band (asynchronously). **Pros:** Zero impact on network throughput or latency; if Suricata crashes, network flow remains unaffected. **Cons:** Cannot block or drop malicious packets in transit (it can only generate alert logs or send TCP RST packets retroactively).
  * **IPS Mode (`NFQUEUE`):** The `nftables` or `iptables` firewall directs packets into an explicit queue number handled by Suricata via netfilter userspace bindings (`NFQUEUE`). Packets pause in kernel memory until Suricata inspects them and returns an explicit verdict (`NF_ACCEPT` or `NF_DROP`). **Pros:** True inline intrusion prevention; malicious payloads are blocked before reaching host sockets. **Cons:** Introduces latency per packet; if Suricata thread queues saturate or the process dies without fallback rules, legitimate network traffic is blocked or severely delayed.
* **Answer 3.2:** To resolve ring-buffer packet drops under heavy traffic:
  1. Increase physical NIC ring-buffer descriptors via `ethtool -G eth0 rx 4096 tx 4096`.
  2. Scale socket receive memory limits in kernel sysctl: `net.core.rmem_max = 67108864` and `net.core.rmem_default = 33554432`.
  3. Enable `af-packet` ring-buffer sizing in `suricata.yaml` (`buffer-size: 65535`, `use-mmap: yes`, `tpacket-v3: yes`).
  4. Bind NIC interrupt requests (IRQs) across dedicated CPU cores using `irqbalance` or manual CPU affinity (`/proc/irq/X/smp_affinity`) matching Suricata `workers` thread pinning.

---

### Exercise 4 Answers

* **Answer 4.1:** WireGuard implements endpoint roaming natively through its **Cryptokey Routing** mechanism. When a remote peer moves from Wi-Fi (`192.168.1.50`) to an LTE network (`203.0.113.88`), it sends an authenticated, ChaCha20-Poly1305 encrypted UDP packet to the WireGuard server. Upon receiving the packet, the server decrypts and verifies the message using the peer's static public key. Once authenticated, WireGuard automatically updates its dynamic internal routing table, updating the peer's endpoint address to `203.0.113.88:port` on the fly. No renegotiation, session teardown, or re-handshake is required. In contrast, standard IPsec IKEv2 relies on static Security Association IP bindings; roaming requires complex MOBIKE extensions (RFC 4555) or full IKE_SA re-authentication and re-keying phases to rebuild the encrypted tunnel.
* **Answer 4.2:** 
  * **Transport Mode:** Encrypts only the IP payload (e.g., TCP/UDP header + application data). The original IP header remains unencrypted and visible.
    $$\text{[ Original IP Header ]} + \text{[ ESP Header ]} + \text{\{ Encrypted TCP Payload \}} + \text{[ ESP Trailer/Auth ]}$$
    *Usage:* Host-to-Host direct node communication where both endpoints possess public IP addresses.
  * **Tunnel Mode:** Encrypts the **entire original IP packet** (inner original IP header + payload) and encapsulates it inside a completely new outer IP header.
    $$\text{[ Outer IP Header (Gateway-to-Gateway) ]} + \text{[ ESP Header ]} + \text{\{ Encrypted Inner IP Header + Payload \}} + \text{[ ESP Trailer/Auth ]}$$
    *Usage:* Site-to-Site subnet bridging (e.g., connecting `10.10.0.0/16` behind Gateway A to `10.20.0.0/16` behind Gateway B). Tunnel mode is strictly required because private inner IP space (`10.x.x.x`) cannot be routed directly over public transit networks without encapsulation.

</details>