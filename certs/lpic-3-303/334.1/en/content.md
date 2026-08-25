# 334.1 — Network Hardening

**LPIC-3 303 (Security), exam 303-300 v3.0.0 — Topic 334: Network Security**
**Weight: 6.67** — one of the heaviest single objectives in the exam. The material below is written at production depth: FreeRADIUS as an authentication plane, `nmap` as an audit instrument, `tshark`/`wireshark` as the ground truth of the wire, and Layer-2/NDP hardening against rogue router advertisements and rogue DHCP.

---

## 1. The architectural problem: an access port is an unauthenticated API

Every hardened platform eventually collapses to the same question: **what does the network grant to a device before that device has proven anything?**

In the default configuration of nearly every switch, hypervisor bridge and Linux `br0`, the answer is: *everything on that broadcast domain*. Plug in, get an L2 adjacency, ARP for the gateway, receive a router advertisement, take a DHCP lease, and you are now a peer of every production node in the VLAN. No credential was presented. The identity boundary is physical — a locked rack door — and physical boundaries do not survive contractors, IPMI ports, WiFi bridges, unmanaged switches under a desk, or a compromised container with `CAP_NET_RAW` on `hostNetwork: true`.

This objective is about moving that boundary from **physical** to **cryptographic**, and then proving it moved:

| Control | Question it answers | Failure if absent |
|---|---|---|
| 802.1X + RADIUS | *Is this device allowed on the wire at all?* | Any physical port is a production credential |
| RADIUS transport hardening (RadSec / Message-Authenticator) | *Can the authentication decision itself be forged?* | Blast-RADIUS (CVE-2024-3596): an on-path attacker turns Access-Reject into Access-Accept |
| RA Guard / DHCP Guard | *Who is allowed to define the routing and naming reality of this segment?* | Silent MITM of a "IPv4-only" network via IPv6 SLAAC |
| `nmap` baselining | *What is actually listening, versus what the runbook claims?* | The kubelet on 10250, the debug JMX port, the forgotten `jetdirect` |
| `tshark`/`wireshark` | *Is the control plane doing what the config says?* | Every other layer is an assertion; the capture is evidence |

A crucial asymmetry to internalize for the exam and for production: **802.1X authenticates the port; it does not authenticate the packets that follow.** Once the port opens, an attacker who physically taps between supplicant and switch injects frames into an authorized port. Closing that gap requires MACsec (802.1AE, §7). Know where each control stops.

### 1.1 Threat model for a single access segment

```
                 ┌──────────────────────────────────────────────┐
                 │  VLAN 30 — worker access segment             │
                 │                                              │
  [worker-01]────┤ port 1 (802.1X, RA-Guard, DHCP-Guard)        │
  [worker-02]────┤ port 2                                       │
  [ROGUE    ]────┤ port 3  ← attacker: rogue RA, rogue DHCP,    │
                 │           ARP poisoning, passive capture     │
  [uplink   ]════┤ port 48 (trusted: RA + DHCP allowed)         │
                 └──────────────────────────────────────────────┘
                              │
                     [radius-01 :1812/:2083]
                     [dhcp/radvd on the router]
```

Attack classes, in ascending order of how often they are missed in real audits:

1. **Unauthenticated port** — no 802.1X. Trivial.
2. **Rogue DHCPv4 server** — attacker answers `DHCPDISCOVER` faster than the legitimate server, hands out itself as default gateway and DNS.
3. **Rogue RA (ICMPv6 type 134)** — the highest-value and least-monitored. Even in a network you believe is IPv4-only, Linux, Windows and macOS all have IPv6 enabled and `accept_ra` on by default. A single unsolicited RA installs a default route with **higher precedence than IPv4** (RFC 6724 destination address selection prefers IPv6), silently converting the attacker into the default gateway for every dual-stack host on the segment. No ARP poisoning, no packet flood, no alarms.
4. **RA Guard evasion by fragmentation** (RFC 7113) — the RA is split so the switch ASIC never sees the ICMPv6 type field.
5. **RADIUS shared-secret / transport attacks** — offline dictionary attack on the MD5 Response Authenticator, or Blast-RADIUS collision forgery.

---

## 2. 802.1X and RADIUS: the authentication plane

### 2.1 The three roles and the two protocols

```
  SUPPLICANT              AUTHENTICATOR                AUTH SERVER
  (wpa_supplicant)        (switch / hostapd)           (FreeRADIUS)
        │                        │                          │
        │──EAPOL-Start──────────▶│                          │
        │◀─EAP-Request/Identity──│                          │
        │──EAP-Response/Identity▶│──Access-Request─────────▶│
        │                        │  (EAP-Message + Msg-Auth)│
        │◀─EAP-Request/TLS───────│◀─Access-Challenge────────│
        │        ... TLS handshake, N round trips ...       │
        │──EAP-Response/TLS─────▶│──Access-Request─────────▶│
        │◀─EAP-Success───────────│◀─Access-Accept───────────│
        │                        │   + MS-MPPE-Recv-Key     │
        │                        │   + Tunnel-Private-Group-Id (VLAN)
        │◀════ port authorized, VLAN 30 assigned ══════════▶│
```

- **EAPOL** (EAP over LAN, EtherType `0x888E`) runs supplicant ↔ authenticator, on the reserved multicast MAC `01:80:C2:00:00:03` (PAE group address).
- **RADIUS** (RFC 2865, EAP transport per RFC 3579) runs authenticator ↔ auth server, UDP/1812 (auth) and UDP/1813 (accounting), or TCP/2083 for RadSec.
- The authenticator is a **dumb relay**: it never sees inside the EAP method. This is why a switch needs no certificate knowledge for EAP-TLS.
- The `MS-MPPE-Recv-Key`/`Send-Key` attributes carry the derived MSK back to the authenticator, encrypted with the shared secret. **This is why a weak RADIUS shared secret compromises WPA2-Enterprise and MACsec key material, not just the accept/reject decision.**

### 2.2 EAP method trade-offs

| Method | Server cert | Client cert | Identity privacy | Credential exposed if server cert not validated | Password DB requirement | Verdict for production |
|---|---|---|---|---|---|---|
| **EAP-TLS** (RFC 5216, TLS 1.3 in RFC 9190) | Required | **Required** | Outer identity only (cert CN visible pre-TLS1.3) | Nothing — mutual auth | None (PKI) | **Default choice.** No passwords to phish. Cost is PKI lifecycle: issuance, renewal, CRL/OCSP |
| **PEAPv0/EAP-MSCHAPv2** | Required | No | Yes (inner tunnel) | MSCHAPv2 challenge/response → offline crack → NTLM hash | NT-hash reversible store | Acceptable only with enforced CA pinning on every client. One misconfigured laptop leaks domain credentials |
| **EAP-TTLS/PAP** | Required | No | Yes | **Cleartext password** | Any backend (LDAP bind, PAM, SQL) | Useful when the backend cannot expose hashes; catastrophic if the tunnel is not validated |
| **EAP-PWD** (RFC 5931) | No | No | Partial | Nothing (PAKE, dictionary-resistant) | Cleartext or equivalent | Elegant, no PKI, but thin client support |
| **TEAP** (RFC 7170) | Required | Optional | Yes | Depends on inner method | Varies | Enables *chaining* user + machine auth in one session. Sparse Linux support |
| **MAB** (MAC Auth Bypass — not EAP) | — | — | None | MAC is trivially spoofed | MAC list | Only for printers/IPMI, on a quarantined VLAN, never as a global fallback |

**Architectural rule:** if the client cannot be forced to validate the server certificate against a specific CA *and* a specific server name, do not deploy PEAP or TTLS. An unvalidated tunnel makes the whole EAP exchange a credential-harvesting funnel for anyone running a rogue authenticator.

### 2.3 RADIUS transport trade-offs

RADIUS was designed in 1997 and its packet protection is `MD5(Code|ID|Length|RequestAuth|Attributes|Secret)`. This has consequences.

| Transport | Port | Confidentiality | Integrity | Replay/forgery resistance | Notes |
|---|---|---|---|---|---|
| **RADIUS/UDP** (RFC 2865) | 1812/1813 | Only `User-Password` (MD5 XOR stream) | Response Authenticator = MD5 | **Broken** — CVE-2024-3596 (Blast-RADIUS) forges Access-Accept via chosen-prefix MD5 collision | Mandatory mitigation: `require_message_authenticator = yes` on every client, both ends |
| **RADIUS/UDP + Message-Authenticator** (RFC 3579) | 1812/1813 | Same | HMAC-MD5 over the whole packet | Blast-RADIUS mitigated; shared secret still dictionary-attackable offline from a capture | Minimum acceptable configuration today |
| **RadSec / RADIUS-over-TLS** (RFC 6614) | **TCP/2083** | Full TLS | TLS | Yes, with mutual certificate auth | The correct answer. Shared secret becomes the literal string `radsec` |
| **RADIUS/DTLS** (RFC 7360) | UDP/2083 | Full DTLS | DTLS | Yes | For devices that cannot hold TCP state |
| **RADIUS/UDP inside IPsec** | 1812/1813 | IPsec | IPsec | Yes | Retrofit path when NAS firmware predates RadSec |

```
$ sudo tshark -i eth0 -f 'udp port 1812' -Y 'radius' \
    -T fields -e radius.code -e radius.id -e radius.Message_Authenticator
Access-Request  215
Access-Accept   215
```
An empty third column is the audit finding: **no Message-Authenticator, therefore Blast-RADIUS exposed.**

---

## 3. FreeRADIUS in production — complete configuration

### 3.1 Layout (FreeRADIUS 3.2.x)

| Path (RHEL/Fedora) | Path (Debian/Ubuntu) | Role |
|---|---|---|
| `/etc/raddb/radiusd.conf` | `/etc/freeradius/3.0/radiusd.conf` | Global: user/group, threads, listeners, logging, `$INCLUDE` chain |
| `/etc/raddb/clients.conf` | idem | NAS registry: IP/prefix, shared secret, per-client policy |
| `/etc/raddb/mods-available/` → `mods-enabled/` | idem | Modules (`eap`, `files`, `ldap`, `sql`, `radutmp`, `pap`, `mschap`) — enable by symlink |
| `/etc/raddb/sites-available/` → `sites-enabled/` | idem | Virtual servers: `default`, `inner-tunnel`, `tls`, `control-socket` |
| `/etc/raddb/mods-config/files/authorize` | idem | The classic `users` file |
| `/etc/raddb/certs/` | idem | CA, server and client PKI + `Makefile`, `bootstrap` |
| `/etc/raddb/policy.d/` | idem | Reusable `unlang` policies (`filter_username`, etc.) |
| `/var/log/radius/radius.log` | `/var/log/freeradius/` | Daemon log |
| `/var/log/radius/radutmp` / `radwtmp` | idem | Session state consumed by `radwho` / `radlast` |

The binary is `radiusd` on RHEL and `freeradius` on Debian — **the same ELF**, and both accept `-X`.

### 3.2 `clients.conf` — hardened NAS registry

```conf
# /etc/raddb/clients.conf
#
# One stanza per authenticator. Never use a /0 or a wildcard: an unknown
# client is silently dropped, and that silence is a security property.

client localhost {
        ipaddr                        = 127.0.0.1
        proto                         = udp
        secret                        = @{ENV:RADIUS_LOCAL_SECRET}
        require_message_authenticator = yes
        nas_type                      = other
        limit {
                max_connections = 16
                lifetime        = 0
                idle_timeout    = 30
        }
}

client sw-access-pool {
        # Every access switch in the management supernet.
        ipaddr                        = 10.20.0.0/22
        proto                         = udp
        secret                        = @{ENV:RADIUS_SWITCH_SECRET}
        shortname                     = access-switches
        nas_type                      = cisco
        virtual_server                = default

        # CVE-2024-3596 (Blast-RADIUS): reject any packet lacking a valid
        # HMAC-MD5 Message-Authenticator attribute.
        require_message_authenticator = yes

        # Do not accept a Proxy-State injected by a downstream device.
        limit_proxy_state             = yes

        limit {
                max_connections = 64
                lifetime        = 0
                idle_timeout    = 60
        }
}

client wlc-01 {
        ipaddr                        = 10.20.1.40
        secret                        = @{ENV:RADIUS_WLC_SECRET}
        shortname                     = wlc-01
        nas_type                      = other
        require_message_authenticator = yes
}

# RadSec peers are matched by certificate, not by shared secret.
client radsec-peers {
        ipaddr    = 10.20.0.0/16
        proto     = tls
        secret    = radsec          # literal, mandated by RFC 6614
        shortname = radsec
}
```

Secrets come from the environment (`@{ENV:...}`), injected by systemd `EnvironmentFile=` or a Kubernetes Secret, so `clients.conf` stays in Git.

### 3.3 `mods-available/eap` — EAP-TLS first

```conf
# /etc/raddb/mods-available/eap
eap {
        default_eap_type = tls
        timer_expire     = 60
        ignore_unknown_eap_types = no
        cisco_accounting_username_bug = no
        max_sessions     = ${max_requests}

        tls-config tls-common {
                private_key_password = @{ENV:RADIUS_KEY_PASSWORD}
                private_key_file     = ${certdir}/server.key
                certificate_file     = ${certdir}/server.pem
                ca_file              = ${cadir}/ca.pem
                ca_path              = ${cadir}

                dh_file              = ${certdir}/dh
                random_file          = /dev/urandom

                # Reject anything below TLS 1.2. TLS 1.3 for EAP-TLS
                # requires RFC 9190-aware peers; validate before enabling.
                tls_min_version = "1.2"
                tls_max_version = "1.3"

                cipher_list       = "HIGH:!aNULL:!eNULL:!EXPORT:!DES:!RC4:!MD5:!PSK"
                cipher_server_preference = yes
                ecdh_curve        = "prime256v1"

                # EAP fragments must fit inside the NAS Framed-MTU. 1024 is
                # the safe value for switches that do not fragment properly.
                fragment_size     = 1024
                include_length    = yes

                # Certificate revocation. check_crl requires the CRL to be
                # concatenated into ca.pem or present in ca_path with hashes.
                check_crl         = yes
                check_all_crl     = yes
                crl_file          = ${cadir}/crl.pem

                # Reject an expired client certificate outright.
                verify_depth      = 3

                cache {
                        enable       = yes
                        lifetime     = 8            # hours
                        max_entries  = 8192
                        persist_dir  = "${logdir}/tlscache"
                }

                verify {
                        # Optional external verification hook, e.g. an
                        # inventory lookup by certificate serial.
                        skip_if_ocsp_ok = no
                }

                ocsp {
                        enable          = yes
                        override_cert_url = yes
                        url             = "http://ocsp.corp.internal/"
                        use_nonce       = yes
                        timeout         = 3
                        softfail        = no        # hard fail: no OCSP, no access
                }
        }

        tls {
                tls = tls-common

                # Bind the certificate to an inventory entry: the CN must
                # also exist in the authorization backend.
                virtual_server = check-eap-tls
        }

        ttls {
                tls                 = tls-common
                default_eap_type    = mschapv2
                copy_request_to_tunnel = no
                use_tunneled_reply  = no
                virtual_server      = "inner-tunnel"
        }

        peap {
                tls                 = tls-common
                default_eap_type    = mschapv2
                copy_request_to_tunnel = no
                use_tunneled_reply  = no
                virtual_server      = "inner-tunnel"
                require_client_cert = no
        }

        mschapv2 {
                send_error = no
        }
}
```

### 3.4 PKI: do not ship the bundled snake-oil certificates

FreeRADIUS ships self-signed test certificates that **expire 60 days after installation**. Half of all "802.1X suddenly stopped working" incidents are exactly this.

```
$ cd /etc/raddb/certs
$ cat ca.cnf
[ ca ]
default_ca              = CA_default

[ CA_default ]
dir                     = ./
certs                   = $dir
crl_dir                 = $dir/crl
database                = $dir/index.txt
new_certs_dir           = $dir
certificate             = $dir/ca.pem
serial                  = $dir/serial
crl                     = $dir/crl.pem
private_key             = $dir/ca.key
RANDFILE                = $dir/.rand
name_opt                = ca_default
cert_opt                = ca_default
default_days            = 3650
default_crl_days        = 30
default_md              = sha256
preserve                = no
policy                  = policy_match

[ policy_match ]
countryName             = match
stateOrProvinceName     = match
organizationName        = match
organizationalUnitName  = optional
commonName              = supplied
emailAddress            = optional

[ req ]
prompt                  = no
distinguished_name      = certificate_authority
default_bits            = 4096
input_password          = @@CA_PASS@@
output_password         = @@CA_PASS@@
x509_extensions         = v3_ca

[ certificate_authority ]
countryName             = AR
stateOrProvinceName     = CABA
localityName            = Buenos Aires
organizationName        = Example Platform Engineering
emailAddress            = pki@example.internal
commonName              = "Example 802.1X Root CA"

[ v3_ca ]
subjectKeyIdentifier    = hash
authorityKeyIdentifier  = keyid:always,issuer:always
basicConstraints        = critical,CA:true
keyUsage                = critical,cRLSign,keyCertSign
```

```
$ make ca.pem server.pem client.pem
openssl dhparam -out dh 2048
openssl req -new -x509 -keyout ca.key -out ca.pem -config ./ca.cnf
openssl req -new -out server.csr -keyout server.key -config ./server.cnf
openssl ca -batch -keyfile ca.key -cert ca.pem -in server.csr -key ... -out server.crt -extensions xpserver_ext -extfile xpextensions -config ./ca.cnf
...
$ openssl x509 -in server.pem -noout -dates -ext extendedKeyUsage,subjectAltName
notBefore=Aug 25 09:00:00 2026 GMT
notAfter=Aug 25 09:00:00 2028 GMT
X509v3 Extended Key Usage:
    TLS Web Server Authentication, 1.3.6.1.5.5.7.3.1
X509v3 Subject Alternative Name:
    DNS:radius.example.internal
```

Two extensions are non-negotiable:
- **Server cert must carry `extendedKeyUsage = serverAuth`** and the Microsoft OID `1.3.6.1.5.5.7.3.1`; Windows supplicants reject it otherwise.
- **Client cert must carry `clientAuth`** (`1.3.6.1.5.5.7.3.2`).

### 3.5 Authorization: `mods-config/files/authorize`

```conf
# /etc/raddb/mods-config/files/authorize
#
# EAP-TLS: authentication is proven by the certificate; this file assigns
# authorization (VLAN, session limits) keyed on the certificate CN, which
# rlm_eap exposes as TLS-Client-Cert-Common-Name.

DEFAULT  EAP-Type == TLS, TLS-Client-Cert-Common-Name =~ /^worker-[0-9]{2}\.prod\.internal$/
         Tunnel-Type = VLAN,
         Tunnel-Medium-Type = IEEE-802,
         Tunnel-Private-Group-Id = "30",
         Session-Timeout := 28800,
         Termination-Action := RADIUS-Request,
         Acct-Interim-Interval := 300

DEFAULT  EAP-Type == TLS, TLS-Client-Cert-Common-Name =~ /^ipmi-[0-9]{2}\./
         Tunnel-Type = VLAN,
         Tunnel-Medium-Type = IEEE-802,
         Tunnel-Private-Group-Id = "31",
         Session-Timeout := 3600

# Printers and appliances that cannot run a supplicant: MAB into the
# quarantine VLAN 99. Never grant a production VLAN from a MAC address.
DEFAULT  User-Name =~ /^([0-9a-f]{12})$/, NAS-Port-Type == Ethernet
         Tunnel-Type = VLAN,
         Tunnel-Medium-Type = IEEE-802,
         Tunnel-Private-Group-Id = "99"

# Explicit deny-all terminator: anything that reached here is unclassified.
DEFAULT  Auth-Type := Reject
         Reply-Message = "No authorization policy matched this identity"
```

The `:=` versus `=` distinction is examinable: `=` sets the attribute **only if not already present**; `:=` **overwrites**; `+=` appends another instance.

### 3.6 RadSec listener — `sites-available/tls`

```conf
# /etc/raddb/sites-enabled/radsec
listen {
        ipaddr = *
        port   = 2083
        type   = auth+acct
        proto  = tcp

        virtual_server = default

        clients = radsec-clients

        limit {
                max_connections = 128
                lifetime        = 0
                idle_timeout    = 300
        }

        tls {
                private_key_password = @{ENV:RADIUS_KEY_PASSWORD}
                private_key_file     = ${certdir}/server.key
                certificate_file     = ${certdir}/server.pem
                ca_file              = ${cadir}/ca.pem

                dh_file              = ${certdir}/dh
                fragment_size        = 8192

                cipher_list          = "HIGH:!aNULL:!eNULL:!EXPORT:!MD5:!RC4"
                tls_min_version      = "1.2"

                # Mutual TLS: the NAS must present a certificate.
                require_client_cert  = yes
                verify_depth         = 3
                check_crl            = yes

                cache {
                        enable      = yes
                        lifetime    = 24
                        max_entries = 512
                }
        }
}

clients radsec-clients {
        client sw-access-radsec {
                ipaddr    = 10.20.0.0/22
                proto     = tls
                secret    = radsec
                shortname = access-radsec
        }
}
```

### 3.7 Accounting and the `radutmp` module (this is what `radwho`/`radlast` read)

`radwho` and `radlast` are not magic — they parse binary session files produced by `rlm_radutmp`. If accounting is not enabled, both return nothing, and that is an extremely common exam trap.

```conf
# /etc/raddb/mods-available/radutmp
radutmp {
        filename    = ${logdir}/radutmp
        username    = "%{User-Name}"
        case_sensitive = yes
        check_with_nas = yes
        permissions = 0600
        caller_id   = "yes"
}
```

```conf
# /etc/raddb/sites-enabled/default   (accounting section, excerpt)
accounting {
        detail
        unix
        radutmp                 # <-- feeds radwho
        sradutmp                # <-- feeds radlast (radwtmp)
        exec
        attr_filter.accounting_response
        -sql
}
```

```
$ ln -s ../mods-available/radutmp /etc/raddb/mods-enabled/radutmp
```

### 3.8 systemd hardening for `radiusd`

```ini
# /etc/systemd/system/radiusd.service.d/hardening.conf
[Service]
EnvironmentFile=/etc/raddb/secrets.env

# Filesystem
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/var/log/radius /var/run/radiusd
PrivateTmp=yes
PrivateDevices=yes

# Kernel and capability surface
NoNewPrivileges=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
RestrictSUIDSGID=yes
RestrictRealtime=yes
RestrictNamespaces=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallFilter=~@privileged @resources @obsolete

# Network surface: RADIUS speaks IPv4/IPv6 UDP+TCP only
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
IPAddressDeny=any
IPAddressAllow=localhost
IPAddressAllow=10.20.0.0/16

# Binding to :1812 requires no root once the capability is granted
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

Restart=on-failure
RestartSec=5s
```

```
$ sudo systemctl daemon-reload && sudo systemctl restart radiusd
$ systemd-analyze security radiusd.service | tail -3
→ Overall exposure level for radiusd.service: 1.8 OK
```

### 3.9 Reproducible lab — `docker-compose.yml`

```yaml
# lab/334.1/docker-compose.yml
# A complete 802.1X lab: auth server, wired authenticator, supplicant,
# a rogue node, and a passive sensor. Bring it up with:
#   docker compose up -d && docker compose logs -f radius
version: "3.9"

networks:
  access:
    driver: bridge
    enable_ipv6: true
    ipam:
      config:
        - subnet: 10.20.30.0/24
          gateway: 10.20.30.1
        - subnet: "2001:db8:20:30::/64"
          gateway: "2001:db8:20:30::1"

services:
  radius:
    image: freeradius/freeradius-server:3.2.5
    container_name: radius-01
    hostname: radius.example.internal
    command: ["radiusd", "-X", "-f"]
    environment:
      RADIUS_LOCAL_SECRET: "lab-local-secret-change-me"
      RADIUS_SWITCH_SECRET: "lab-switch-secret-change-me"
      RADIUS_WLC_SECRET: "lab-wlc-secret-change-me"
      RADIUS_KEY_PASSWORD: "whatever"
    volumes:
      - ./raddb:/etc/raddb:ro
      - radius-logs:/var/log/radius
    networks:
      access:
        ipv4_address: 10.20.30.10
    ports:
      - "1812:1812/udp"
      - "1813:1813/udp"
      - "2083:2083/tcp"
    cap_drop: ["ALL"]
    cap_add: ["NET_BIND_SERVICE"]
    security_opt: ["no-new-privileges:true"]
    healthcheck:
      test: ["CMD", "radtest", "lab", "labpass", "127.0.0.1", "0", "lab-local-secret-change-me"]
      interval: 30s
      timeout: 5s
      retries: 3

  authenticator:
    image: alpine:3.20
    container_name: hostapd-wired
    command: >
      sh -c "apk add --no-cache hostapd &&
             hostapd -dd /etc/hostapd/hostapd-wired.conf"
    volumes:
      - ./hostapd:/etc/hostapd:ro
    networks:
      access:
        ipv4_address: 10.20.30.11
    cap_add: ["NET_ADMIN", "NET_RAW"]
    depends_on: [radius]

  supplicant:
    image: alpine:3.20
    container_name: worker-01
    command: >
      sh -c "apk add --no-cache wpa_supplicant &&
             wpa_supplicant -dd -D wired -i eth0 -c /etc/wpa/wired.conf"
    volumes:
      - ./supplicant:/etc/wpa:ro
      - ./raddb/certs:/etc/wpa/certs:ro
    networks:
      access:
        ipv4_address: 10.20.30.20
    cap_add: ["NET_ADMIN", "NET_RAW"]
    depends_on: [authenticator]

  sensor:
    image: alpine:3.20
    container_name: sensor-01
    command: >
      sh -c "apk add --no-cache tshark ndisc6 nmap &&
             tshark -i eth0 -w /captures/access.pcapng
               -f 'icmp6 or arp or (udp port 67 or 68) or (udp port 546 or 547) or (udp port 1812 or 1813)'
               -b filesize:65536 -b files:12"
    volumes:
      - ./captures:/captures
    networks:
      access:
        ipv4_address: 10.20.30.90
    cap_add: ["NET_RAW", "NET_ADMIN"]

  rogue:
    image: alpine:3.20
    container_name: rogue-01
    command: ["sleep", "infinity"]
    networks:
      access:
        ipv4_address: 10.20.30.66
    cap_add: ["NET_ADMIN", "NET_RAW"]

volumes:
  radius-logs: {}
```

### 3.10 Host hardening playbook — Ansible

```yaml
# ansible/network-hardening.yml
# Applies the host-side half of 334.1: NDP/ICMP hardening, RA rejection,
# nftables RA-Guard/DHCP-Guard on bridges, and the NDPMon sensor.
---
- name: Network hardening for access-segment hosts
  hosts: access_segment
  become: true

  vars:
    trusted_uplink: "uplink0"
    authorized_router_lla: "fe80::5054:ff:feaa:bb01"
    authorized_router_mac: "52:54:00:aa:bb:01"
    authorized_prefix: "2001:db8:10:20::/64"

  tasks:
    - name: Install network security tooling
      ansible.builtin.package:
        name:
          - nftables
          - tcpdump
          - tshark
          - ndisc6
          - nmap
          - ndpmon
        state: present

    - name: Harden IPv4 and IPv6 stack parameters
      ansible.posix.sysctl:
        name: "{{ item.key }}"
        value: "{{ item.value }}"
        sysctl_file: /etc/sysctl.d/60-network-hardening.conf
        sysctl_set: true
        reload: true
      loop: "{{ hardening_sysctls | dict2items }}"
      vars:
        hardening_sysctls:
          # --- IPv6: refuse to let the network define our routing reality
          net.ipv6.conf.all.accept_ra: 0
          net.ipv6.conf.default.accept_ra: 0
          net.ipv6.conf.all.accept_ra_defrtr: 0
          net.ipv6.conf.all.accept_ra_pinfo: 0
          net.ipv6.conf.all.accept_ra_rtr_pref: 0
          net.ipv6.conf.all.accept_ra_rt_info_max_plen: 0
          net.ipv6.conf.all.autoconf: 0
          net.ipv6.conf.all.router_solicitations: 0
          net.ipv6.conf.all.accept_redirects: 0
          net.ipv6.conf.default.accept_redirects: 0
          net.ipv6.conf.all.accept_source_route: 0
          net.ipv6.conf.all.drop_unsolicited_na: 1
          net.ipv6.conf.all.drop_unicast_in_l2_multicast: 1
          net.ipv6.conf.all.max_addresses: 4
          # --- IPv4
          net.ipv4.conf.all.accept_redirects: 0
          net.ipv4.conf.default.accept_redirects: 0
          net.ipv4.conf.all.secure_redirects: 0
          net.ipv4.conf.all.send_redirects: 0
          net.ipv4.conf.default.send_redirects: 0
          net.ipv4.conf.all.accept_source_route: 0
          net.ipv4.conf.all.log_martians: 1
          net.ipv4.conf.all.arp_ignore: 1
          net.ipv4.conf.all.arp_announce: 2
          net.ipv4.icmp_echo_ignore_broadcasts: 1
          net.ipv4.icmp_ignore_bogus_error_responses: 1
          net.ipv4.tcp_syncookies: 1

    # rp_filter is deliberately NOT in the list above. Strict mode (1)
    # breaks asymmetric return paths in Calico/Cilium and in any host that
    # is also a router. Apply loose mode per-interface instead.
    - name: Loose reverse-path filtering on routed interfaces
      ansible.posix.sysctl:
        name: "net.ipv4.conf.{{ item }}.rp_filter"
        value: "2"
        sysctl_file: /etc/sysctl.d/60-network-hardening.conf
        sysctl_set: true
        reload: true
      loop: "{{ ansible_interfaces | difference(['lo']) }}"
      when: ansible_kernel is version('4.19', '>=')

    - name: Deploy bridge-level RA-Guard / DHCP-Guard ruleset
      ansible.builtin.template:
        src: raguard.nft.j2
        dest: /etc/nftables.d/10-raguard.nft
        owner: root
        group: root
        mode: "0640"
        validate: "/usr/sbin/nft -c -f %s"
      notify: reload nftables

    - name: Register the only authorized router with NDPMon
      ansible.builtin.template:
        src: config_ndpmon.xml.j2
        dest: /etc/ndpmon/config_ndpmon.xml
        owner: root
        group: root
        mode: "0644"
      notify: restart ndpmon

    - name: Enable and start NDPMon
      ansible.builtin.systemd:
        name: ndpmon
        enabled: true
        state: started

    - name: Verify no default IPv6 route was learned from an RA
      ansible.builtin.shell: |
        set -o pipefail
        ip -6 route show default | grep -v '^$' || true
      args: { executable: /bin/bash }
      register: v6_default
      changed_when: false
      failed_when: >
        v6_default.stdout != "" and
        authorized_router_lla not in v6_default.stdout

  handlers:
    - name: reload nftables
      ansible.builtin.systemd:
        name: nftables
        state: reloaded

    - name: restart ndpmon
      ansible.builtin.systemd:
        name: ndpmon
        state: restarted
```

### 3.11 Kubernetes network sensor — DaemonSet + scheduled `nmap` baseline

```yaml
# k8s/network-sensor.yaml
# Two artifacts:
#   1. A DaemonSet capturing NDP/DHCP/RADIUS control traffic on every node.
#   2. A CronJob that re-baselines the node fleet with nmap and diffs
#      against the committed baseline with ndiff.
---
apiVersion: v1
kind: Namespace
metadata:
  name: netsec
  labels:
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/audit: privileged
    pod-security.kubernetes.io/warn: privileged
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: network-sensor
  namespace: netsec
automountServiceAccountToken: false
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: ndp-sensor
  namespace: netsec
  labels:
    app.kubernetes.io/name: ndp-sensor
    app.kubernetes.io/component: network-security
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: ndp-sensor
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1
  template:
    metadata:
      labels:
        app.kubernetes.io/name: ndp-sensor
    spec:
      serviceAccountName: network-sensor
      hostNetwork: true
      hostPID: false
      dnsPolicy: ClusterFirstWithHostNet
      priorityClassName: system-node-critical
      tolerations:
        - operator: Exists
      nodeSelector:
        kubernetes.io/os: linux
      terminationGracePeriodSeconds: 15
      containers:
        - name: tshark
          image: ghcr.io/example/netsec-tools:1.6.0   # tshark, ndisc6, nmap
          imagePullPolicy: IfNotPresent
          command:
            - /usr/bin/dumpcap
          args:
            - -i
            - $(CAPTURE_IFACE)
            - -f
            - >-
              icmp6 or arp or (udp port 67 or udp port 68) or
              (udp port 546 or udp port 547) or
              (udp port 1812 or udp port 1813) or ether proto 0x888e
            - -b
            - filesize:65536
            - -b
            - files:12
            - -w
            - /captures/$(NODE_NAME)-ctrl.pcapng
          env:
            - name: NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
            - name: CAPTURE_IFACE
              value: "eth0"
          securityContext:
            runAsUser: 0
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
              add: ["NET_RAW", "NET_ADMIN"]
            seccompProfile:
              type: RuntimeDefault
          resources:
            requests:
              cpu: 50m
              memory: 96Mi
            limits:
              cpu: 500m
              memory: 512Mi
          volumeMounts:
            - name: captures
              mountPath: /captures
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: captures
          hostPath:
            path: /var/lib/netsec/captures
            type: DirectoryOrCreate
        - name: tmp
          emptyDir:
            medium: Memory
            sizeLimit: 32Mi
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: nmap-baseline-diff
  namespace: netsec
spec:
  schedule: "17 3 * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 5
  jobTemplate:
    spec:
      backoffLimit: 1
      activeDeadlineSeconds: 3600
      template:
        spec:
          restartPolicy: Never
          serviceAccountName: network-sensor
          containers:
            - name: nmap
              image: ghcr.io/example/netsec-tools:1.6.0
              command: ["/bin/bash", "-euo", "pipefail", "-c"]
              args:
                - |
                  TS="$(date -u +%Y%m%dT%H%M%SZ)"
                  OUT="/baselines/nodes-${TS}"
                  nmap -sS -sV --version-intensity 2 \
                       -p 22,443,2379,2380,4194,6443,9100,10250,10256,10257,10259 \
                       --max-rate 300 --max-retries 2 --host-timeout 90s \
                       -oA "${OUT}" -iL /config/targets.txt
                  if [ -f /baselines/nodes-baseline.xml ]; then
                    ndiff /baselines/nodes-baseline.xml "${OUT}.xml" \
                      | tee /baselines/diff-${TS}.txt
                    if [ -s /baselines/diff-${TS}.txt ]; then
                      echo "DRIFT DETECTED — exposed surface changed"
                      exit 2
                    fi
                  else
                    cp "${OUT}.xml" /baselines/nodes-baseline.xml
                  fi
              securityContext:
                runAsUser: 0
                allowPrivilegeEscalation: false
                readOnlyRootFilesystem: true
                capabilities:
                  drop: ["ALL"]
                  add: ["NET_RAW", "NET_ADMIN", "NET_BIND_SERVICE"]
                seccompProfile:
                  type: RuntimeDefault
              resources:
                requests: { cpu: 100m, memory: 128Mi }
                limits:   { cpu: "1",  memory: 512Mi }
              volumeMounts:
                - { name: baselines, mountPath: /baselines }
                - { name: targets,   mountPath: /config, readOnly: true }
                - { name: tmp,       mountPath: /tmp }
          volumes:
            - name: baselines
              persistentVolumeClaim:
                claimName: netsec-baselines
            - name: targets
              configMap:
                name: nmap-targets
            - name: tmp
              emptyDir: { medium: Memory, sizeLimit: 64Mi }
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: nmap-targets
  namespace: netsec
data:
  targets.txt: |
    10.20.30.0/24
    10.20.31.0/24
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: netsec-baselines
  namespace: netsec
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 5Gi
```

`nmap` needs `NET_RAW` for `-sS`; without it the SYN scan silently degrades to a connect scan (`-sT`) and your baseline changes meaning.

---

## 4. Operating FreeRADIUS: the debugging discipline

**Rule zero: `radiusd -X` is the only real debugger.** Log files summarize; `-X` shows the exact `unlang` execution path, every attribute, and every module return code.

```
$ sudo systemctl stop radiusd
$ sudo radiusd -X
Thu Aug 25 09:41:02 2026 : Info: FreeRADIUS Version 3.2.5
Thu Aug 25 09:41:02 2026 : Info: Copyright (C) 1999-2023 The FreeRADIUS server project
...
Thu Aug 25 09:41:02 2026 : Debug: including configuration file /etc/raddb/clients.conf
Thu Aug 25 09:41:02 2026 : Debug:  client sw-access-pool {
Thu Aug 25 09:41:02 2026 : Debug:   ipaddr = 10.20.0.0/22
Thu Aug 25 09:41:02 2026 : Debug:   require_message_authenticator = yes
Thu Aug 25 09:41:02 2026 : Debug:  }
Thu Aug 25 09:41:03 2026 : Debug:   tls: Using cached TLS configuration from previous invocation
Thu Aug 25 09:41:03 2026 : Debug:   tls: Loading CA certificate file "/etc/raddb/certs/ca.pem"
Thu Aug 25 09:41:03 2026 : Info: Loaded virtual server default
Thu Aug 25 09:41:03 2026 : Info: Ready to process requests
```

### 4.1 `radtest` — smoke test with cleartext credentials

Syntax: `radtest [options] user password radius-server[:port] nas-port-number secret [ppphint] [nasname]`

```
$ radtest bob "S3cr3t-lab" 127.0.0.1 0 lab-local-secret-change-me
Sent Access-Request Id 215 from 0.0.0.0:38321 to 127.0.0.1:1812 length 74
	User-Name = "bob"
	User-Password = "S3cr3t-lab"
	NAS-IP-Address = 127.0.0.1
	NAS-Port = 0
	Message-Authenticator = 0x00
	Cleartext-Password = "S3cr3t-lab"
Received Access-Accept Id 215 from 127.0.0.1:1812 to 127.0.0.1:38321 length 38
	Tunnel-Type:0 = VLAN
	Tunnel-Medium-Type:0 = IEEE-802
	Tunnel-Private-Group-Id:0 = "30"
```

A rejection:

```
$ radtest bob "wrong" 127.0.0.1 0 lab-local-secret-change-me
Sent Access-Request Id 47 from 0.0.0.0:47112 to 127.0.0.1:1812 length 69
Received Access-Reject Id 47 from 127.0.0.1:1812 to 127.0.0.1:47112 length 39
	Reply-Message = "No authorization policy matched this identity"
```

`radtest` accepts `-t <proto>` for the auth type: `pap` (default), `chap`, `mschap`, `eap-md5`.

```
$ radtest -t mschap bob "S3cr3t-lab" 127.0.0.1 0 lab-local-secret-change-me
```

### 4.2 `radclient` — arbitrary attribute crafting

`radclient` is the low-level tool: it sends whatever attributes you feed on stdin, which is how you reproduce a NAS's exact request.

```
$ echo "User-Name = bob, User-Password = S3cr3t-lab, NAS-IP-Address = 10.20.0.5, \
NAS-Port = 50110, NAS-Port-Type = Ethernet, Called-Station-Id = 'AA-BB-CC-DD-EE-FF', \
Calling-Station-Id = '52-54-00-11-22-33', Service-Type = Framed-User" \
  | radclient -x 10.20.30.10:1812 auth lab-switch-secret-change-me
Sent Access-Request Id 133 from 0.0.0.0:44551 to 10.20.30.10:1812 length 128
	User-Name = "bob"
	User-Password = "S3cr3t-lab"
	NAS-IP-Address = 10.20.0.5
	NAS-Port = 50110
	NAS-Port-Type = Ethernet
	Called-Station-Id = "AA-BB-CC-DD-EE-FF"
	Calling-Station-Id = "52-54-00-11-22-33"
	Service-Type = Framed-User
Received Access-Accept Id 133 from 10.20.30.10:1812 to 10.20.30.20:44551 length 38
	Tunnel-Type:0 = VLAN
	Tunnel-Medium-Type:0 = IEEE-802
	Tunnel-Private-Group-Id:0 = "30"
```

Load test before a maintenance window that will re-authenticate 4,000 ports at once:

```
$ radclient -x -c 100 -p 20 -t 3 -r 2 -f /tmp/requests.txt \
    10.20.30.10:1812 auth lab-switch-secret-change-me | tail -5
Received Access-Accept Id 98 from 10.20.30.10:1812 to 10.20.30.20:52344 length 38
Received Access-Accept Id 99 from 10.20.30.10:1812 to 10.20.30.20:52344 length 38
Total approved auths:  2000
Total denied auths:    0
Total lost auths:      0
```
Flags: `-c` count per input entry, `-p` parallel in flight, `-t` timeout, `-r` retries, `-f` request file, `-s` summary statistics.

Accounting:

```
$ echo "User-Name=bob,Acct-Status-Type=Start,Acct-Session-Id='0000ABCD', \
NAS-IP-Address=10.20.0.5,NAS-Port=50110,Framed-IP-Address=10.20.30.20" \
  | radclient -x 10.20.30.10:1813 acct lab-switch-secret-change-me
Received Accounting-Response Id 12 from 10.20.30.10:1813 ... length 20
```

### 4.3 `eapol_test` — the only honest EAP test

`radtest` cannot test EAP-TLS or PEAP. `eapol_test`, shipped with `wpa_supplicant`, emulates a full supplicant *and* authenticator and speaks real RADIUS.

```
$ cat /tmp/eap-tls.conf
network={
        key_mgmt=IEEE8021X
        eap=TLS
        identity="worker-01.prod.internal"
        ca_cert="/etc/raddb/certs/ca.pem"
        client_cert="/etc/raddb/certs/worker-01.pem"
        private_key="/etc/raddb/certs/worker-01.key"
        private_key_passwd="whatever"
}

$ eapol_test -c /tmp/eap-tls.conf -a 10.20.30.10 -p 1812 \
             -s lab-switch-secret-change-me -r 0
...
EAP: Status notification: completion (param=success)
EAP: EAP entering state SUCCESS
CTRL-EVENT-EAP-SUCCESS EAP authentication completed successfully
MPPE keys OK: 1  mismatch: 0
SUCCESS
```

`MPPE keys OK: 1` proves the MSK was delivered — that is what a WPA2-Enterprise or MACsec deployment actually depends on.

### 4.4 `radwho` and `radlast` — session visibility

```
$ radwho
Login      Name              What  TTY  When       From        Location
bob        Bob Smith        shell  S0   Tue 10:14  10.20.30.20 sw-access-01
worker-01  --               shell  S1   Tue 09:02  10.20.30.21 sw-access-01
```

Useful flags: `-c` (CLI/short output), `-i` (print session IDs), `-r` (raw, machine-parseable), `-s` (short), `-u` (show only one user session), `-f <file>` (alternate `radutmp`).

```
$ radwho -r
bob	S0	10.20.30.20	1756112040	0000ABCD	sw-access-01
```

```
$ radlast -10
bob       ttyS0        10.20.30.20      Tue Aug 25 10:14 - 11:02  (00:48)
worker-01 ttyS1        10.20.30.21      Tue Aug 25 09:02   still logged in
ipmi-04   ttyS3        10.20.31.44      Mon Aug 24 22:11 - 06:30  (08:19)

radwtmp begins Mon Aug 18 00:00:12 2026
```

`radlast -f /var/log/radius/radwtmp -n 50 bob` restricts to one user. Both tools are useless without `rlm_radutmp`/`rlm_sradutmp` in the accounting section (§3.7).

### 4.5 `radmin` — live control without a restart

Requires the control socket. Enable it:

```conf
# /etc/raddb/sites-enabled/control-socket
listen {
        type   = control
        socket = ${run_dir}/${name}.sock
        mode   = rw
        uid    = radiusd
        gid    = radiusd
        peercred = yes
}
```

```
$ sudo radmin -f /var/run/radiusd/radiusd.sock
radmin 3.2.5 - FreeRADIUS Server administration tool.
Copyright 2008-2019 The FreeRADIUS server project
radmin> show module list
	eap
	files
	pap
	mschap
	radutmp
	sql
radmin> show module status eap
alive
radmin> stats detail
requests	    41823
responses	    41821
accepts		    39902
rejects		     1919
challenges	   118406
dup		        3
invalid		        0
malformed	        0
bad_authenticator	       12
dropped		        0
unknown_types	        0
radmin> stats client auth 10.20.0.5
requests	     8102
accepts		     7998
rejects		      104
bad_authenticator	       12
radmin> debug condition '(User-Name == "worker-01.prod.internal")'
radmin> debug file /var/log/radius/worker-01-trace.log
radmin> hup files
Reloading module "files"
radmin> quit
```

`debug condition` + `debug file` is the production superpower: full `-X`-level tracing for **one identity**, on a live server serving thousands of sessions, without a restart. Always `debug file` back to empty (`radmin> debug file`) afterwards — the trace contains credentials.

`bad_authenticator: 12` in the output above is a real finding: twelve packets arrived with a Message-Authenticator that did not verify. That is either a shared-secret mismatch on one NAS, or an active forgery attempt.

---

## 5. Authenticator and supplicant configuration

### 5.1 `hostapd` as a wired 802.1X authenticator

```conf
# /etc/hostapd/hostapd-wired.conf
interface=eth1
driver=wired

# Send EAPOL to the PAE group address 01:80:C2:00:00:03 rather than the
# client unicast MAC — required on hubs/bridges where the MAC is unknown
# until after authentication.
use_pae_group_addr=1

ieee8021x=1
eapol_version=2
eap_reauth_period=3600

# RADIUS
own_ip_addr=10.20.30.11
nas_identifier=sw-access-lab-01
auth_server_addr=10.20.30.10
auth_server_port=1812
auth_server_shared_secret=lab-switch-secret-change-me
acct_server_addr=10.20.30.10
acct_server_port=1813
acct_server_shared_secret=lab-switch-secret-change-me
radius_acct_interim_interval=300

# Honour Tunnel-Private-Group-Id from Access-Accept
dynamic_vlan=2
vlan_file=/etc/hostapd/hostapd.vlan
vlan_tagged_interface=eth1

logger_syslog=-1
logger_syslog_level=2
logger_stdout=-1
logger_stdout_level=1
ctrl_interface=/var/run/hostapd
ctrl_interface_group=0
```

```
$ sudo hostapd -dd /etc/hostapd/hostapd-wired.conf
eth1: interface state UNINITIALIZED->ENABLED
eth1: IEEE 802.1X: 52:54:00:11:22:33 - start authentication
eth1: STA 52:54:00:11:22:33 IEEE 802.1X: unauthorizing port
eth1: STA 52:54:00:11:22:33 IEEE 802.1X: sending identity request
RADIUS: Sending RADIUS message to authentication server
RADIUS message: code=1 (Access-Request) identity='worker-01.prod.internal'
RADIUS: Received 64 bytes from RADIUS server (Access-Challenge)
...
RADIUS: Received 210 bytes from RADIUS server (Access-Accept)
eth1: STA 52:54:00:11:22:33 IEEE 802.1X: authorizing port
eth1: STA 52:54:00:11:22:33 RADIUS: starting accounting session 68AC1F2E00000001
```

```
$ sudo hostapd_cli -i eth1 all_sta
52:54:00:11:22:33
dot1xPaePortStatus=Authorized
dot1xAuthAuthControlledPortStatus=Authorized
AKMSuiteSelector=00-0f-ac-1
```

### 5.2 `wpa_supplicant` on a wired interface

```conf
# /etc/wpa_supplicant/wired.conf
ctrl_interface=/var/run/wpa_supplicant
ctrl_interface_group=wheel
ap_scan=0
eapol_version=2
fast_reauth=1

network={
        key_mgmt=IEEE8021X
        eap=TLS
        identity="worker-01.prod.internal"

        # Mandatory server validation. Without BOTH of these the supplicant
        # will happily authenticate to a rogue authentication server.
        ca_cert="/etc/pki/8021x/ca.pem"
        domain_suffix_match="radius.example.internal"
        altsubject_match="DNS:radius.example.internal"

        client_cert="/etc/pki/8021x/worker-01.pem"
        private_key="/etc/pki/8021x/worker-01.key"
        private_key_passwd="whatever"

        # TLS 1.2 floor
        phase1="tls_disable_tlsv1_0=1 tls_disable_tlsv1_1=1"

        eapol_flags=0        # wired: no WEP/dynamic key derivation
}
```

```
$ sudo wpa_supplicant -B -D wired -i eth0 -c /etc/wpa_supplicant/wired.conf
$ sudo wpa_cli -i eth0 status
bssid=01:80:c2:00:00:03
freq=0
ssid=
id=0
mode=station
wpa_state=COMPLETED
address=52:54:00:11:22:33
Supplicant PAE state=AUTHENTICATED
suppPortStatus=Authorized
EAP state=SUCCESS
selectedMethod=13 (EAP-TLS)
eap_tls_version=TLSv1.2
```

`Supplicant PAE state=AUTHENTICATED` and `suppPortStatus=Authorized` are the two fields that matter. `wpa_state=COMPLETED` alone can be true while the port is still blocked.

For NetworkManager-managed hosts the equivalent is a keyfile connection:

```ini
# /etc/NetworkManager/system-connections/wired-8021x.nmconnection  (chmod 600)
[connection]
id=wired-8021x
type=ethernet
interface-name=eth0

[802-1x]
eap=tls;
identity=worker-01.prod.internal
ca-cert=/etc/pki/8021x/ca.pem
client-cert=/etc/pki/8021x/worker-01.pem
private-key=/etc/pki/8021x/worker-01.key
private-key-password-flags=0
private-key-password=whatever
domain-suffix-match=radius.example.internal

[ipv4]
method=auto

[ipv6]
method=disabled
```

---

## 6. MACsec — closing the post-authentication gap

802.1X authorizes a port; the frames after that are plaintext on the wire. MACsec (IEEE 802.1AE) encrypts and authenticates each frame, keyed by the MSK that EAP already derived.

```conf
# /etc/wpa_supplicant/macsec.conf
ctrl_interface=/var/run/wpa_supplicant
eapol_version=3

network={
        key_mgmt=IEEE8021X
        eap=TLS
        identity="worker-01.prod.internal"
        ca_cert="/etc/pki/8021x/ca.pem"
        client_cert="/etc/pki/8021x/worker-01.pem"
        private_key="/etc/pki/8021x/worker-01.key"
        private_key_passwd="whatever"

        macsec_policy=1            # 1 = MKA required
        macsec_integ_only=0        # 0 = encrypt + authenticate
        macsec_replay_protect=1
        macsec_replay_window=0     # strict ordering
        eapol_flags=0
}
```

```
$ sudo wpa_supplicant -B -D macsec_linux -i eth0 -c /etc/wpa_supplicant/macsec.conf
$ ip -d link show macsec0
7: macsec0@eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1468 ...
    macsec sci 5254001122330001 protect on validate strict sc off sa off encrypt on send_sci on end_station off scb off replay off
$ ip macsec show
7: macsec0: protect on validate strict sc off sa off encrypt on send_sci on
    cipher suite: GCM-AES-128, using ICV length 16
    TXSC: 5254001122330001 on SA 0
        0: PN 8412, state on, key 4a1f...
    RXSC: 5254009900010001, state on
        0: PN 8390, state on, key 4a1f...
```

Note `mtu 1468`: MACsec adds a 32-byte SecTAG+ICV. Any host expecting 1500 will blackhole large frames — a classic post-deployment incident. Adjust MTU end to end or enable jumbo frames on the switch.

---

## 7. `nmap` — auditing what is actually exposed

### 7.1 Scan-type matrix

| Scan | Flag | Root? | Mechanism | `open` | `closed` | `filtered` | When to use |
|---|---|---|---|---|---|---|---|
| TCP SYN ("half-open") | `-sS` | Yes | SYN → SYN/ACK vs RST | SYN/ACK | RST | no reply / ICMP unreach | Default. Fast, no app-layer log entry, but fills conntrack on stateful firewalls |
| TCP connect | `-sT` | No | full `connect()` | success | ECONNREFUSED | timeout | Unprivileged contexts, containers without `NET_RAW` |
| UDP | `-sU` | Yes | empty/protocol payload | app reply | ICMP port unreach | no reply → `open\|filtered` | Slow and ambiguous; kernel ICMP rate-limiting dominates runtime |
| ACK | `-sA` | Yes | bare ACK | — | — | `unfiltered` vs `filtered` | **Firewall rule mapping**: tells you what the filter passes, not what listens |
| Window | `-sW` | Yes | ACK + TCP window heuristics | window≠0 | window=0 | — | Infers open/closed on stacks with the old window quirk |
| NULL / FIN / Xmas | `-sN` `-sF` `-sX` | Yes | no flags / FIN / FIN+PSH+URG | no reply | RST | ICMP unreach | Evades naïve stateless filters; useless against Windows, Cisco, many appliances (they RST everything) |
| Maimon | `-sM` | Yes | FIN/ACK | — | RST | — | BSD-derived stacks |
| Idle | `-sI zombie` | Yes | IP-ID side channel on a third host | inferred | inferred | inferred | Attribution-free scanning; only for authorized red-team work with a documented zombie |
| Ping sweep | `-sn` | — | ARP on-link; ICMP echo + TCP/80 SYN + TCP/443 ACK + ICMP timestamp off-link | — | — | — | Inventory. On-link ARP cannot be firewalled away |
| No discovery | `-Pn` | — | assume all hosts up | — | — | — | Networks that drop probes; multiplies runtime |
| Protocol scan | `-sO` | Yes | IP protocol field enumeration | — | — | — | Finds GRE/ESP/AH/OSPF reachability |

### 7.2 Host discovery and inventory

```
$ sudo nmap -sn 10.20.30.0/24
Starting Nmap 7.95 ( https://nmap.org ) at 2026-08-25 09:12 -03
Nmap scan report for gw.access.internal (10.20.30.1)
Host is up (0.00031s latency).
MAC Address: 52:54:00:AA:BB:01 (QEMU virtual NIC)
Nmap scan report for radius.example.internal (10.20.30.10)
Host is up (0.00027s latency).
MAC Address: 52:54:00:0A:0B:0C (QEMU virtual NIC)
Nmap scan report for worker-01.prod.internal (10.20.30.20)
Host is up (0.00029s latency).
MAC Address: 52:54:00:11:22:33 (QEMU virtual NIC)
Nmap scan report for 10.20.30.66
Host is up (0.00044s latency).
MAC Address: 52:54:00:99:99:99 (Unknown)
Nmap done: 256 IP addresses (4 hosts up) scanned in 2.31 seconds
```

`10.20.30.66` with an unresolvable name and an unrecognized OUI is the finding. Cross-reference against DHCP leases and the `radutmp` session table.

### 7.3 Full TCP surface of a node

```
$ sudo nmap -sS -p- --min-rate 2000 -T4 --reason -oA scans/worker-01 10.20.30.20
Starting Nmap 7.95 ( https://nmap.org ) at 2026-08-25 09:15 -03
Nmap scan report for worker-01.prod.internal (10.20.30.20)
Host is up, received arp-response (0.00042s latency).
Not shown: 65529 closed tcp ports (reset)
PORT      STATE SERVICE     REASON
22/tcp    open  ssh         syn-ack ttl 64
2379/tcp  open  etcd-client syn-ack ttl 64
2380/tcp  open  etcd-server syn-ack ttl 64
6443/tcp  open  sun-sr-https syn-ack ttl 64
10250/tcp open  unknown     syn-ack ttl 64
10256/tcp open  unknown     syn-ack ttl 64
MAC Address: 52:54:00:11:22:33 (QEMU virtual NIC)

Nmap done: 1 IP address (1 host up) scanned in 9.84 seconds
```

`2379/tcp` reachable from an access VLAN is a critical finding: etcd is the cluster's entire state, and a client-cert-less etcd is a full compromise.

### 7.4 Service and version detection

```
$ sudo nmap -sV --version-intensity 5 -p 22,6443,10250 10.20.30.20
PORT      STATE SERVICE  VERSION
22/tcp    open  ssh      OpenSSH 9.6 (protocol 2.0)
6443/tcp  open  ssl/http Golang net/http server
10250/tcp open  ssl/http Golang net/http server

Service detection performed. Please report any incorrect results at https://nmap.org/submit/ .
Nmap done: 1 IP address (1 host up) scanned in 12.09 seconds
```

### 7.5 UDP: the half nobody scans

```
$ sudo nmap -sU -p 53,67,68,123,161,500,546,547,1812,1813,4500 --reason 10.20.30.10
PORT     STATE         SERVICE     REASON
53/udp   closed        domain      port-unreach ttl 64
67/udp   open|filtered dhcps       no-response
68/udp   open|filtered dhcpc       no-response
123/udp  open          ntp         udp-response ttl 64
161/udp  open          snmp        udp-response ttl 64
500/udp  open|filtered isakmp      no-response
546/udp  open|filtered dhcpv6-client no-response
547/udp  open|filtered dhcpv6-server no-response
1812/udp open          radius      udp-response ttl 64
1813/udp open          radius-acct udp-response ttl 64
4500/udp open|filtered nat-t-ike   no-response

Nmap done: 1 IP address (1 host up) scanned in 8.02 seconds
```

`open|filtered` is not laziness — it is the honest answer. UDP has no negative acknowledgement for an open port, so silence is indistinguishable from a drop. Resolve it with `-sV` (which sends protocol-specific payloads) or by capturing on the target.

### 7.6 Firewall rule mapping with `-sA`

```
$ sudo nmap -sA -p 22,80,443,3306,6443 10.20.31.50
PORT     STATE      SERVICE
22/tcp   unfiltered ssh
80/tcp   unfiltered http
443/tcp  unfiltered https
3306/tcp filtered   mysql
6443/tcp filtered   sun-sr-https
```

`unfiltered` means the ACK traversed the filter and produced an RST — the firewall permits that port (open or closed is unknown). `filtered` means dropped. This is how you *audit a ruleset* rather than a service list.

### 7.7 IPv6 — why sweeping is dead and what replaces it

A `/64` is 1.8×10¹⁹ addresses. Brute-force sweeping is computationally impossible, which regularly gets mistaken for security. It is not: multicast discovery, DNS, and the neighbour cache enumerate hosts instantly.

```
$ sudo nmap -6 --script targets-ipv6-multicast-echo --script-args 'newtargets' \
            -e eth0 -sn
Pre-scan script results:
| targets-ipv6-multicast-echo:
|   IP: fe80::5054:ff:feaa:bb01  MAC: 52:54:00:aa:bb:01  IFACE: eth0
|   IP: fe80::5054:ff:fe0a:0b0c  MAC: 52:54:00:0a:0b:0c  IFACE: eth0
|   IP: fe80::5054:ff:fe11:2233  MAC: 52:54:00:11:22:33  IFACE: eth0
|   IP: fe80::5054:ff:fe99:9999  MAC: 52:54:00:99:99:99  IFACE: eth0
|_  Use --script-args=newtargets to add the results as targets
Nmap done: 4 IP addresses (4 hosts up) scanned in 4.11 seconds
```

Complementary sources: `ip -6 neigh show`, DHCPv6 lease databases, `AAAA` records in the zone, and `rdisc6` output.

### 7.8 NSE for defensive posture checks

```
$ nmap --script ssl-enum-ciphers -p 2083 radius.example.internal
PORT     STATE SERVICE
2083/tcp open  radsec
| ssl-enum-ciphers:
|   TLSv1.2:
|     ciphers:
|       TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384 (secp256r1) - A
|       TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256 (secp256r1) - A
|     cipher preference: server
|   TLSv1.3:
|     ciphers:
|       TLS_AKE_WITH_AES_256_GCM_SHA384 (secp256r1) - A
|_  least strength: A
```

```
$ nmap --script ssh2-enum-algos -p 22 10.20.30.20 | grep -A4 encryption_algorithms
|     encryption_algorithms: (6)
|         chacha20-poly1305@openssh.com
|         aes128-ctr
|         aes192-ctr
|         aes256-ctr
|         aes128-gcm@openssh.com
```

Script categories worth knowing: `safe`, `default`/`-sC`, `discovery`, `auth`, `vuln`, `broadcast`, `intrusive`, `dos`, `exploit`. **`intrusive`, `dos` and `exploit` never run against production without a written change record.** `--script-updatedb` rebuilds the script index.

### 7.9 Production-safe scanning

| Concern | Control |
|---|---|
| Conntrack exhaustion on the target's firewall | `--max-rate 300`, `--max-retries 2`, `-T3`; watch `nf_conntrack_count` on the target |
| Fragile devices (embedded, PLC, old printers) | `-sT` instead of `-sS`, exclude with `--excludefile` |
| IDS noise / on-call paging | Announce the window, or add scanner IPs to the IDS allowlist |
| Long-running scans on flaky links | `--host-timeout 90s`, `--scan-delay` |
| Reproducibility | Always `-oA <prefix>`; commit the XML |
| Drift detection | `ndiff old.xml new.xml` |

```
$ ndiff scans/worker-01-baseline.xml scans/worker-01-20260825.xml
-Nmap 7.95 scan initiated Mon Aug 18 03:17:00 2026
+Nmap 7.95 scan initiated Tue Aug 25 03:17:00 2026
 worker-01.prod.internal (10.20.30.20):
+Not shown: 65528 closed ports
 PORT      STATE SERVICE VERSION
+2375/tcp  open  docker  Docker 26.1.4
```

`2375/tcp` — an unauthenticated Docker socket appeared overnight. That single line is the entire justification for the CronJob in §3.11.

---

## 8. Traffic analysis: `tcpdump`, `dumpcap`, `tshark`, `wireshark`

### 8.1 Tool selection

| Tool | Runs where | Strength | Weakness |
|---|---|---|---|
| `tcpdump` | Anywhere, always installed | Tiny, libpcap-native, safe on a busy box | No dissectors beyond a handful; no statistics |
| `dumpcap` | Capture engine of Wireshark | **Purpose-built for capture only** — smallest privileged attack surface, native ring buffers | Cannot dissect or filter on display filters |
| `tshark` | Servers, CI, containers | Full Wireshark dissection + `-z` statistics + field extraction (`-T fields`) | Dissection engine is large and privileged if run as root — capture with `dumpcap`, dissect offline |
| `wireshark` | Analyst workstation | Follow-stream, expert info, TLS decryption UI, IO graphs | Never on a production host: huge parser attack surface running as a desktop user |

**The correct production pattern:** capture with `dumpcap` (or `tcpdump`) on the host, analyse the `.pcapng` off-host with `tshark`/`wireshark`. Historically, Wireshark dissectors have been a rich source of remote code execution from malicious packets.

### 8.2 Privilege model — do not run capture as root

```
$ sudo dpkg-reconfigure wireshark-common      # Debian: answer "Yes"
$ sudo usermod -aG wireshark "$USER"
$ sudo setcap cap_net_raw,cap_net_admin=eip /usr/bin/dumpcap
$ getcap /usr/bin/dumpcap
/usr/bin/dumpcap cap_net_raw,cap_net_admin=eip
$ ls -l /usr/bin/dumpcap
-rwxr-xr-- 1 root wireshark 121584 Mar  4 2026 /usr/bin/dumpcap
```

`0754 root:wireshark` plus file capabilities means only group members can capture, and no process runs as root.

### 8.3 Capture filters (BPF) versus display filters — a classic exam distinction

| | Capture filter | Display filter |
|---|---|---|
| Syntax | libpcap / BPF | Wireshark display-filter language |
| Applied | In the kernel, **before** the packet is stored | After full dissection, on stored packets |
| CLI flag | `-f` | `-Y` (`tshark`), `-R` (deprecated, two-pass only) |
| Can it recover discarded packets? | No — data is gone forever | Yes, re-filter the same file endlessly |
| Example | `-f "udp port 1812 or icmp6"` | `-Y "radius.code == 3 && icmpv6.type == 134"` |
| Cost | Nearly free; the only way to survive 10 Gb/s | Expensive; full dissection of every packet |

Getting this wrong is the most common capture failure: a display filter typed into `-f` produces `syntax error` at best, and a capture filter typed into `-Y` silently matches nothing.

| Goal | Capture filter (`-f`) | Display filter (`-Y`) |
|---|---|---|
| RADIUS auth | `udp port 1812` | `radius` |
| RADIUS with EAP | `udp port 1812` | `eap` |
| RadSec | `tcp port 2083` | `tls && tcp.port == 2083` |
| All ICMPv6 | `icmp6` | `icmpv6` |
| Router Advertisements | `icmp6 and ip6[40] == 134` | `icmpv6.type == 134` |
| DHCPv4 | `udp port 67 or udp port 68` | `dhcp` (was `bootp` pre-3.0) |
| DHCPv6 | `udp port 546 or udp port 547` | `dhcpv6` |
| EAPOL | `ether proto 0x888e` | `eapol` |
| Gratuitous ARP | `arp` | `arp.isgratuitous == 1` |
| Exclude your own SSH | `not port 22` | `!(tcp.port == 22)` |

### 8.4 Capturing correctly

```
$ sudo dumpcap -D
1. eth0
2. eth1
3. any
4. lo (Loopback)
5. br0

$ sudo dumpcap -i eth0 \
    -f 'icmp6 or arp or (udp port 67 or udp port 68) or (udp port 546 or udp port 547) or ether proto 0x888e' \
    -b filesize:65536 -b files:12 \
    -w /var/captures/access-ctrl.pcapng
Capturing on 'eth0'
File: /var/captures/access-ctrl_00001_20260825091500.pcapng
Packets captured: 4127
Packets received/dropped on interface 'eth0': 4127/0 (100.0%)
```

`Packets ... dropped: 0` is the line that validates the capture. Non-zero drops mean the analysis is built on an incomplete record — increase the buffer with `-B 64` (MiB) or tighten the capture filter.

**Disable offloads before capturing**, or the trace will show impossible 40 KB "frames" and wrong checksums:

```
$ sudo ethtool -K eth0 gro off gso off tso off lro off
$ ethtool -k eth0 | grep -E 'generic-receive|tcp-segmentation'
tcp-segmentation-offload: off
generic-receive-offload: off
```

### 8.5 Dissecting the RADIUS/EAP exchange

```
$ tshark -r /var/captures/access-ctrl_00001.pcapng -Y 'radius' \
    -T fields -e frame.number -e ip.src -e ip.dst \
    -e radius.code -e radius.id -e radius.User_Name -e eap.type
12   10.20.30.11  10.20.30.10  1   215  worker-01.prod.internal  1
13   10.20.30.10  10.20.30.11  11  215                            13
14   10.20.30.11  10.20.30.10  1   216  worker-01.prod.internal  13
...
38   10.20.30.10  10.20.30.11  2   224
```

RADIUS codes: `1` Access-Request, `2` Access-Accept, `3` Access-Reject, `4` Accounting-Request, `5` Accounting-Response, `11` Access-Challenge. EAP type `13` is EAP-TLS, `25` PEAP, `21` TTLS, `26` MSCHAPv2, `1` Identity.

Full decode of one packet:

```
$ tshark -r access-ctrl_00001.pcapng -Y 'radius.code == 2' -V | sed -n '1,45p'
Frame 38: 210 bytes on wire (1680 bits), 210 bytes captured
Ethernet II, Src: 52:54:00:0a:0b:0c, Dst: 52:54:00:0b:0c:0d
Internet Protocol Version 4, Src: 10.20.30.10, Dst: 10.20.30.11
User Datagram Protocol, Src Port: 1812, Dst Port: 44551
RADIUS Protocol
    Code: Access-Accept (2)
    Packet identifier: 0xe0 (224)
    Length: 168
    Authenticator: 3f8a2b1c9d4e5f60718293a4b5c6d7e8
    [This is a response to a request in frame: 37]
    [Time from request: 0.004112000 seconds]
    Attribute Value Pairs
        AVP: t=User-Name(1) l=25 val=worker-01.prod.internal
        AVP: t=Tunnel-Type(64) l=6 Tag=0x00 val=VLAN(13)
        AVP: t=Tunnel-Medium-Type(65) l=6 Tag=0x00 val=IEEE-802(6)
        AVP: t=Tunnel-Private-Group-Id(81) l=4 Tag=0x00 val=30
        AVP: t=EAP-Message(79) l=6 Last Segment[1]
            Extensible Authentication Protocol
                Code: Success (3)
                Id: 12
                Length: 4
        AVP: t=Message-Authenticator(80) l=18 val=1a2b3c4d5e6f708192a3b4c5d6e7f809
        AVP: t=Vendor-Specific(26) l=58 vnd=Microsoft(311)
            VSA: t=MS-MPPE-Recv-Key(17) l=52 val=...
```

To let Wireshark verify authenticators and decrypt `User-Password`, set the shared secret:

```
$ tshark -r access-ctrl.pcapng -o 'radius.shared_secret:lab-switch-secret-change-me' \
    -Y 'radius' -V | grep -E 'Message-Authenticator|Authenticator: |Malformed'
    Authenticator: 3f8a2b1c9d4e5f60718293a4b5c6d7e8 [correct]
    AVP: t=Message-Authenticator(80) l=18 val=1a2b3c... [correct]
```
The `[correct]` / `[incorrect]` annotation is exactly the check that catches a shared-secret mismatch across a NAS fleet.

For RadSec, decrypt with a key log:

```
$ SSLKEYLOGFILE=/tmp/radsec.keys radiusd -X   # FreeRADIUS 3.2 honours this
$ tshark -r radsec.pcapng -o tls.keylog_file:/tmp/radsec.keys -Y 'radius'
```

### 8.6 Statistics: `-z`

```
$ tshark -r access-ctrl.pcapng -q -z io,stat,60,"COUNT(icmpv6.type)icmpv6.type==134"
===================================================================
| IO Statistics                                                   |
| Interval size: 60 secs                                          |
| Col 1: COUNT(icmpv6.type)icmpv6.type==134                       |
|-----------------------------------------------------------------|
|            |1                                                   |
| Interval   | COUNT                                              |
|-----------------------------------------------------------------|
|   0 <>  60 |     2                                              |
|  60 <> 120 |     2                                              |
| 120 <> 180 |    41                                              |   <-- flood / rogue
| 180 <> 240 |    38                                              |
===================================================================
```

A radvd sending every 200–600 s produces 2 per minute. Forty per minute is a rogue advertiser or an RA flood.

```
$ tshark -r access-ctrl.pcapng -q -z endpoints,eth
================================================================================
Ethernet Endpoints
                       |  Packets  | |  Bytes  | | Tx Packets | | Rx Packets |
52:54:00:aa:bb:01           1204        141k          812            392
52:54:00:0a:0b:0c            988        118k          502            486
52:54:00:11:22:33            744         86k          371            373
52:54:00:99:99:99            412         51k          401             11     <-- talks, barely listens
================================================================================
```

```
$ tshark -r access-ctrl.pcapng -q -z expert
Errors (2)
=============
   Frequency   Group        Protocol  Summary
           2   Malformed    ICMPv6    Malformed Packet (Exception occurred)
Warns (14)
=============
          14   Sequence     ICMPv6    Router Advertisement from a link-local
                                      address not in the neighbour cache
```

Other high-value `-z` taps: `conv,ip`, `conv,tcp`, `http,tree`, `dns,tree`, `follow,tcp,ascii,0`, `flow,any`.

---

## 9. Rogue Router Advertisements and rogue DHCP

### 9.1 Why RA is the sharpest edge

An RA (ICMPv6 type 134, RFC 4861) sent to `ff02::1` from any link-local address will, on a default-configured Linux/Windows/macOS host:

1. Install a **default route** via the sender (`Router Lifetime > 0`).
2. Install an **on-link prefix** and trigger SLAAC address configuration (`A` flag).
3. Optionally set `M`/`O` flags, redirecting the host to a rogue DHCPv6 server for DNS.
4. Take **precedence over IPv4** for any destination with a AAAA record, per RFC 6724.

No authentication exists in base NDP. The `Router Lifetime` field can also be set to 0 to *remove* a legitimate router — a denial of service that looks like a routing flap.

```
$ sudo tshark -i eth0 -Y 'icmpv6.type == 134' -T fields \
    -e frame.time -e eth.src -e ipv6.src \
    -e icmpv6.nd.ra.router_lifetime -e icmpv6.opt.prefix.prefix -e icmpv6.nd.ra.flag
Aug 25, 2026 11:03:02  52:54:00:aa:bb:01  fe80::5054:ff:feaa:bb01  1800  2001:db8:10:20::  0x00
Aug 25, 2026 11:04:12  52:54:00:99:99:99  fe80::5054:ff:fe99:9999  1800  2001:db8:dead::   0x80
```

Two distinct routers, two distinct prefixes, on a segment with one legitimate gateway. The second is the attack. `0x80` sets high router preference (RFC 4191) so hosts prefer it.

Enumerate routers actively:

```
$ rdisc6 eth0
Soliciting ff02::2 (ff02::2) on eth0...

Hop limit                 :           64 (      0x40)
Stateful address conf.    :           No
Stateful other conf.      :          Yes
Router preference         :         high
Router lifetime           :         1800 (0x00000708) seconds
Reachable time            :  unspecified (0x00000000)
Retransmit time           :  unspecified (0x00000000)
 Prefix                   : 2001:db8:dead::/64
  On-link                 :          Yes
  Autonomous address conf.:          Yes
  Valid time              :        86400 (0x00015180) seconds
  Pref. time              :        14400 (0x00003840) seconds
 Recursive DNS server     : 2001:db8:dead::66
 Source link-layer address: 52:54:00:99:99:99
 from fe80::5054:ff:fe99:9999

Hop limit                 :           64 (      0x40)
Router preference         :       medium
Router lifetime           :         1800 (0x00000708) seconds
 Prefix                   : 2001:db8:10:20::/64
 Source link-layer address: 52:54:00:AA:BB:01
 from fe80::5054:ff:feaa:bb01
```

The victim's resulting state:

```
$ ip -6 route show
2001:db8:10:20::/64 dev eth0 proto ra metric 100 pref medium
2001:db8:dead::/64  dev eth0 proto ra metric 100 pref medium
default via fe80::5054:ff:fe99:9999 dev eth0 proto ra metric 100 pref high
default via fe80::5054:ff:feaa:bb01 dev eth0 proto ra metric 100 pref medium

$ ip -6 addr show dev eth0 | grep inet6
    inet6 2001:db8:dead:0:5054:ff:fe11:2233/64 scope global dynamic mngtmpaddr
    inet6 2001:db8:10:20:5054:ff:fe11:2233/64 scope global dynamic mngtmpaddr
    inet6 fe80::5054:ff:fe11:2233/64 scope link
```

`proto ra` marks routes learned from an advertisement — grep for it in any incident.

### 9.2 Defence comparison

| Control | Layer | Stops rogue RA | Stops rogue DHCPv6 | Stops RFC 7113 fragmentation evasion | Cost / caveat |
|---|---|---|---|---|---|
| **RA Guard** (RFC 6105) on the switch | L2 ASIC | Yes on untrusted ports | With DHCPv6 Guard | **Only if the switch drops fragmented NDP** (RFC 6980) | Requires managed switches; verify the firmware implements RFC 6980 |
| **`nftables` bridge filter** on the host/hypervisor | L2 (Linux bridge) | Yes | Yes | Yes with `exthdr frag exists drop` | Runs where you control the bridge: KVM hosts, container hosts |
| **Host `sysctl accept_ra=0`** | L3 host stack | Yes for that host | No (DHCPv6 client is separate) | Yes | Simplest, most portable; does **not** remove already-installed state |
| **SEND** (RFC 3971, CGA) | L3 crypto | Yes, cryptographically | No | Yes | Essentially undeployed; no mainstream OS support |
| **NDPMon / addrwatch / ramond** | Detection | Detects; `ramond` can also counter | Detects | Yes (it sees reassembled packets) | Detection, not prevention. Buys the alert |
| **`ip6tables`/`nft` on the host `inet` table** | L3 host filter | Yes | Yes | Yes | Beware: dropping *all* ICMPv6 breaks PMTUD and NDP itself |

**Layer them.** A managed switch with RA Guard, plus `accept_ra=0` on every server, plus NDPMon as the tripwire that tells you an attempt happened.

### 9.3 Host-side hardening

```
# /etc/sysctl.d/60-network-hardening.conf
# --- IPv6: this host does not learn its routing from the wire ---------------
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.default.accept_ra = 0
net.ipv6.conf.all.accept_ra_defrtr = 0
net.ipv6.conf.all.accept_ra_pinfo = 0
net.ipv6.conf.all.accept_ra_rtr_pref = 0
net.ipv6.conf.all.accept_ra_rt_info_max_plen = 0
net.ipv6.conf.all.autoconf = 0
net.ipv6.conf.all.router_solicitations = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.all.drop_unsolicited_na = 1
net.ipv6.conf.all.drop_unicast_in_l2_multicast = 1
net.ipv6.conf.all.max_addresses = 4

# --- IPv4 ------------------------------------------------------------------
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.all.arp_ignore = 1
net.ipv4.conf.all.arp_announce = 2
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.tcp_syncookies = 1
```

```
$ sudo sysctl --system
* Applying /etc/sysctl.d/60-network-hardening.conf ...
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.all.autoconf = 0
...
$ sysctl net.ipv6.conf.eth0.accept_ra net.ipv6.conf.all.forwarding
net.ipv6.conf.eth0.accept_ra = 0
net.ipv6.conf.all.forwarding = 0
```

Three traps worth memorising:

- `net.ipv6.conf.all.*` is not a broadcast setter for RA options. For most `accept_ra_*` knobs the kernel uses the **per-interface** value; `all` is combined only for some. Always verify with `sysctl net.ipv6.conf.<iface>.accept_ra`, never with `all` alone.
- Setting `net.ipv6.conf.all.forwarding = 1` (every Kubernetes node, every router) makes the kernel **ignore RAs entirely** unless `accept_ra = 2`. So on a router, `accept_ra = 0` is redundant; on a router that *needs* upstream RAs, you must set `2`, and that reopens the exposure on every interface it applies to.
- `accept_ra = 0` prevents *new* learning. It does not delete the poisoned default route or the SLAAC address already installed (see §10.4 for the cleanup runbook).

### 9.4 `nftables` RA Guard / DHCP Guard on a Linux bridge

This is the enforcement point on a KVM hypervisor or container host, where you own `br0` and every `vnetN`/`vethN` tap.

```nft
#!/usr/sbin/nft -f
# /etc/nftables.d/10-raguard.nft
#
# Only the uplink port may source Router Advertisements, ICMPv6 Redirects,
# DHCPv4 replies and DHCPv6 replies. Everything arriving on a guest tap is
# a rogue advertiser by definition.

table bridge raguard
delete table bridge raguard

table bridge raguard {
    set trusted_ports {
        type ifname
        elements = { "uplink0", "bond0" }
    }

    set authorized_routers {
        type ether_addr
        elements = { 52:54:00:aa:bb:01, 52:54:00:aa:bb:02 }
    }

    chain forward {
        type filter hook forward priority -300; policy accept;
        jump guard
    }

    chain input {
        type filter hook input priority -300; policy accept;
        jump guard
    }

    chain guard {
        # The uplink is authoritative for this segment.
        iifname @trusted_ports return

        # RFC 6980 / RFC 7113: an NDP message split across IPv6 fragments
        # is the canonical RA-Guard evasion. There is no legitimate reason
        # for a fragmented NDP packet — drop before any type match.
        meta protocol ip6 exthdr frag exists \
            counter log prefix "RAGUARD-FRAG-NDP " level warn drop

        # Rogue Router Advertisement and ICMPv6 Redirect.
        meta protocol ip6 icmpv6 type { nd-router-advert, nd-redirect } \
            counter log prefix "RAGUARD-RA " level warn drop

        # Rogue DHCPv6 server (server 547 -> client 546).
        meta protocol ip6 udp sport 547 udp dport 546 \
            counter log prefix "RAGUARD-DHCPv6 " level warn drop

        # Rogue DHCPv4 server (server 67 -> client 68).
        meta protocol ip udp sport 67 udp dport 68 \
            counter log prefix "RAGUARD-DHCPv4 " level warn drop

        # Guests must not impersonate the gateway MAC.
        ether saddr @authorized_routers \
            counter log prefix "RAGUARD-MAC-SPOOF " level warn drop

        # Gratuitous ARP claiming the gateway address.
        meta protocol arp arp operation reply arp saddr ip 10.20.30.1 \
            counter log prefix "RAGUARD-ARP-GW " level warn drop
    }
}
```

```
$ sudo nft -c -f /etc/nftables.d/10-raguard.nft && echo "syntax OK"
syntax OK
$ sudo nft -f /etc/nftables.d/10-raguard.nft
$ sudo nft list table bridge raguard
table bridge raguard {
	set trusted_ports {
		type ifname
		elements = { "uplink0", "bond0" }
	}
	...
	chain guard {
		iifname @trusted_ports return
		meta protocol ip6 exthdr frag exists counter packets 0 bytes 0 log prefix "RAGUARD-FRAG-NDP " level warn drop
		meta protocol ip6 icmpv6 type { nd-router-advert, nd-redirect } counter packets 7 bytes 574 log prefix "RAGUARD-RA " level warn drop
		meta protocol ip udp sport 67 udp dport 68 counter packets 3 bytes 1026 log prefix "RAGUARD-DHCPv4 " level warn drop
		...
	}
}
```

`counter packets 7` on the RA rule is the incident: seven rogue advertisements were dropped. Ship those counters to Prometheus via `node_exporter`'s textfile collector or `nftables_exporter`.

```
$ sudo journalctl -k -g RAGUARD --since "1 hour ago" -o short-iso | head -3
2026-08-25T11:04:12-03:00 kvm-07 kernel: RAGUARD-RA IN=vnet7 OUT=br0 MAC=33:33:00:00:00:01:52:54:00:99:99:99:86:dd SRC=fe80::5054:00ff:fe99:9999 DST=ff02::1 LEN=64 PROTO=ICMPv6 TYPE=134
2026-08-25T11:04:22-03:00 kvm-07 kernel: RAGUARD-RA IN=vnet7 OUT=br0 MAC=33:33:00:00:00:01:52:54:00:99:99:99:86:dd SRC=fe80::5054:00ff:fe99:9999 DST=ff02::1 LEN=64 PROTO=ICMPv6 TYPE=134
2026-08-25T11:04:31-03:00 kvm-07 kernel: RAGUARD-DHCPv4 IN=vnet7 OUT=br0 MAC=ff:ff:ff:ff:ff:ff:52:54:00:99:99:99:08:00 SRC=10.20.30.66 DST=255.255.255.255 PROTO=UDP SPT=67 DPT=68
```

`IN=vnet7` identifies the offending tap, which maps directly to a VM or container. That is the whole point of enforcing at L2 rather than on the victim.

The `ebtables` equivalent (legacy, still examinable):

```
$ sudo ebtables -A FORWARD -i vnet+ -p IPv6 --ip6-protocol ipv6-icmp \
    --ip6-icmp-type router-advertisement -j DROP
$ sudo ebtables -A FORWARD -i vnet+ -p IPv4 --ip-protocol udp \
    --ip-source-port 67 --ip-destination-port 68 -j DROP
$ sudo ebtables -L FORWARD --Lc
Bridge chain: FORWARD, entries: 2, policy: ACCEPT
-p IPv6 -i vnet+ --ip6-proto ipv6-icmp --ip6-icmp-type router-advertisement -j DROP , pcnt = 7 -- bcnt = 574
-p IPv4 -i vnet+ --ip-proto udp --ip-sport 67 --ip-dport 68 -j DROP , pcnt = 3 -- bcnt = 1026
```

Ensure the bridge is not double-filtered by the IP tables:

```
$ sysctl net.bridge.bridge-nf-call-iptables net.bridge.bridge-nf-call-ip6tables
net.bridge.bridge-nf-call-iptables = 0
net.bridge.bridge-nf-call-ip6tables = 0
```

### 9.5 The legitimate advertiser: `radvd`

```conf
# /etc/radvd.conf
interface uplink0
{
        AdvSendAdvert on;

        MinRtrAdvInterval 200;
        MaxRtrAdvInterval 600;

        # Medium is correct for the single legitimate router. Reserve
        # "high" so that a rogue cannot outrank you without being obvious.
        AdvDefaultPreference medium;
        AdvDefaultLifetime 1800;

        # Stateless: hosts autoconfigure addresses, DNS comes from RDNSS.
        AdvManagedFlag off;
        AdvOtherConfigFlag off;

        # Force the hop limit so a rogue cannot lower it to break traffic.
        AdvCurHopLimit 64;
        AdvReachableTime 30000;
        AdvRetransTimer 1000;

        prefix 2001:db8:10:20::/64
        {
                AdvOnLink on;
                AdvAutonomous on;
                AdvRouterAddr off;
                AdvValidLifetime 86400;
                AdvPreferredLifetime 14400;
        };

        RDNSS 2001:db8:10:20::53 2001:db8:10:20::54
        {
                AdvRDNSSLifetime 1200;
        };

        DNSSL prod.internal
        {
                AdvDNSSLLifetime 1200;
        };
};
```

```
$ sudo radvd -c -C /etc/radvd.conf && echo "config OK"
config OK
$ sudo systemctl enable --now radvd
$ sudo journalctl -u radvd -n 3
radvd[2091]: version 2.19 started
radvd[2091]: sending RA on uplink0
```

### 9.6 NDPMon — the NDP tripwire

NDPMon watches all Neighbor Discovery traffic against a whitelist of authorized routers and a learned neighbour database, and alerts on eleven classes of anomaly.

```xml
<?xml version="1.0" encoding="ISO-8859-1"?>
<!-- /etc/ndpmon/config_ndpmon.xml -->
<config_ndpmon>
  <settings>
    <admin_mail>netsec@example.internal</admin_mail>
    <syslog_facility>local1</syslog_facility>

    <!-- Do not auto-learn new routers: the whitelist below is the policy. -->
    <ignor_autoconf>0</ignor_autoconf>

    <!-- Send NDP countermeasures (deprecating RAs) on detection.
         Enable only after you have proven no false positives. -->
    <countermeasures>0</countermeasures>

    <!-- Alert if a neighbour is silent longer than this (seconds). -->
    <use_reverse_hostlookups>0</use_reverse_hostlookups>
  </settings>

  <probes>
    <probe name="access-vlan30" type="interface">
      <interfaces>
        <interface>eth0</interfaces>
      </interfaces>

      <!-- The ONLY routers permitted to advertise on this segment. -->
      <routers>
        <router>
          <mac>52:54:00:aa:bb:01</mac>
          <lla>fe80::5054:ff:feaa:bb01</lla>
          <param>
            <prefixes>
              <prefix>
                <address>2001:db8:10:20::</address>
                <mask>64</mask>
              </prefix>
            </prefixes>
            <addresses/>
            <volatile>
              <param_curhoplimit>64</param_curhoplimit>
              <param_flags_reserved>0</param_flags_reserved>
              <param_router_lifetime>1800</param_router_lifetime>
              <param_reachable_timer>30000</param_reachable_timer>
              <param_retrans_timer>1000</param_retrans_timer>
              <param_mtu>1500</param_mtu>
            </volatile>
          </param>
        </router>
      </routers>
    </probe>
  </probes>
</config_ndpmon>
```

```
$ sudo systemctl enable --now ndpmon
$ sudo journalctl -u ndpmon -f
Aug 25 11:03:02 sensor-01 NDPMon[2118]: [ndpmon] probe access-vlan30 started on eth0
Aug 25 11:04:12 sensor-01 NDPMon[2118]: [alert] wrong router advertisement: RA from
    fe80::5054:ff:fe99:9999 (52:54:00:99:99:99) is not in the authorized router list
Aug 25 11:04:12 sensor-01 NDPMon[2118]: [alert] wrong prefix: 2001:db8:dead::/64
    advertised by 52:54:00:99:99:99 does not match the configured prefix list
Aug 25 11:07:44 sensor-01 NDPMon[2118]: [alert] flip flop: address
    2001:db8:10:20::20 moved from 52:54:00:11:22:33 to 52:54:00:99:99:99
Aug 25 11:09:01 sensor-01 NDPMon[2118]: [alert] DAD DoS: 52:54:00:99:99:99 answered
    12 duplicate address detections in 30 seconds
```

The alert taxonomy, worth knowing by name for the exam:

| Alert | Meaning |
|---|---|
| `new station` | A MAC/IPv6 pair not previously seen |
| `new activity` | A station returned after long silence |
| `changed ethernet address` | The MAC behind an IPv6 address changed |
| `flip flop` | Address oscillating between two MACs — active spoofing |
| `reused old ethernet address` | A retired MAC reappeared |
| `wrong couple MAC/IP` | Advertised pairing contradicts the database |
| `ethernet mismatch` | L2 header MAC ≠ NDP source link-layer option |
| `IP mismatch` | IPv6 header source ≠ NDP target |
| `wrong router advertisement` | RA from an address not in `<routers>` |
| `wrong prefix` | RA carries an unconfigured prefix |
| `DAD DoS` | Duplicate Address Detection answered for everything — prevents any host configuring an address |

State lives in `/var/lib/ndpmon/neighbor_list.xml`. When you legitimately renumber or replace a router, update `config_ndpmon.xml` **and** clear the neighbour list, or every host generates a `changed ethernet address` alert.

Lighter-weight alternatives: `addrwatch` (syslog/SQL output of MAC↔IP bindings), `arpwatch` (IPv4 only), `ramond` (detects and actively neutralises rogue RAs by re-advertising `Router Lifetime 0`).

### 9.7 Rogue DHCPv4 detection

```
$ sudo nmap --script broadcast-dhcp-discover -e eth0
Starting Nmap 7.95 ( https://nmap.org ) at 2026-08-25 11:12 -03
Pre-scan script results:
| broadcast-dhcp-discover:
|   Response 1 of 2:
|     Interface: eth0
|     IP Offered: 10.20.30.51
|     DHCP Message Type: DHCPOFFER
|     Server Identifier: 10.20.30.1
|     Subnet Mask: 255.255.255.0
|     Router: 10.20.30.1
|     Domain Name Server: 10.20.30.53
|     IP Address Lease Time: 12h00m00s
|   Response 2 of 2:
|     Interface: eth0
|     IP Offered: 192.168.99.77
|     DHCP Message Type: DHCPOFFER
|     Server Identifier: 192.168.99.1
|     Subnet Mask: 255.255.255.0
|     Router: 192.168.99.1
|     Domain Name Server: 192.168.99.1
|_    IP Address Lease Time: 10m00s
WARNING: No targets were specified, so 0 hosts scanned.
Nmap done: 0 IP addresses (0 hosts up) scanned in 5.19 seconds
```

**Two responses on a segment with one DHCP server is the finding.** The short 10-minute lease and the self-referential DNS are typical of a MITM tool.

Confirm on the wire and identify the offending MAC:

```
$ sudo tshark -i eth0 -Y 'dhcp.type == 2' -T fields \
    -e eth.src -e ip.src -e dhcp.ip.your -e dhcp.option.dhcp_server_id -e dhcp.option.router
52:54:00:aa:bb:01  10.20.30.1     10.20.30.51    10.20.30.1     10.20.30.1
52:54:00:99:99:99  192.168.99.1   192.168.99.77  192.168.99.1   192.168.99.1
```

`dhcp.type == 2` is BOOTREPLY; `dhcp.option.dhcp` values are `1` DISCOVER, `2` OFFER, `3` REQUEST, `5` ACK, `6` NAK.

`dhcpdump` gives the same evidence in human-readable form:

```
$ sudo dhcpdump -i eth0
  TIME: 2026-08-25 11:12:04.331
    IP: 192.168.99.1 (52:54:00:99:99:99) > 255.255.255.255 (ff:ff:ff:ff:ff:ff)
    OP: 2 (BOOTPREPLY)
 HTYPE: 1 (Ethernet)
 YIADDR: 192.168.99.77
 SIADDR: 192.168.99.1
OPTION:  53 (  1) DHCP message type         2 (DHCPOFFER)
OPTION:  54 (  4) Server identifier         192.168.99.1
OPTION:  51 (  4) IP address leasetime      600 (10m)
OPTION:   3 (  4) Routers                   192.168.99.1
OPTION:   6 (  4) Domain name servers       192.168.99.1
```

Rogue DHCPv6 uses the same logic on 547→546:

```
$ sudo tshark -i eth0 -Y 'dhcpv6.msgtype == 7' -T fields \
    -e eth.src -e ipv6.src -e dhcpv6.iaaddr.ip
52:54:00:99:99:99  fe80::5054:ff:fe99:9999  2001:db8:dead::1000
```
(`dhcpv6.msgtype` 7 = REPLY, 2 = ADVERTISE.)

---

## 10. Verification and failure diagnosis

### 10.1 What each check actually proves

| Claim | Command that proves it | What it does **not** prove |
|---|---|---|
| "RADIUS is up" | `radtest` returns Access-Accept | That EAP works — `radtest` cannot speak EAP-TLS |
| "802.1X works" | `eapol_test` prints `SUCCESS` and `MPPE keys OK: 1` | That the switch enforces it — test with an unauthenticated device |
| "The port is enforcing" | Plug an unconfigured host in; it must get **no** L2 forwarding | That MACsec protects the frames afterwards |
| "Shared secrets are consistent" | `radmin> stats detail` → `bad_authenticator = 0` | That the secret is strong — check length/entropy separately |
| "We are not Blast-RADIUS exposed" | `tshark -Y radius` shows Message-Authenticator on every packet | That the secret has not already leaked |
| "RA Guard works" | Send a test RA from an untrusted port; `nft list table bridge raguard` counter increments and the victim's `ip -6 route` is unchanged | That fragmented RAs are blocked — test that separately |
| "IPv6 is disabled" | `ip -6 addr show` shows only `::1` and link-local | That the NIC ignores RAs — a disabled *address* is not a disabled *stack* |
| "Nothing unexpected listens" | `ndiff baseline.xml today.xml` is empty | That what listens is *authorized* — that requires a reviewed baseline |
| "The capture is complete" | `dumpcap` reports `dropped: 0/…` | That you captured the right interface — check bonds, bridges, VLAN subinterfaces |

### 10.2 FreeRADIUS failure catalogue

| Symptom in `radiusd -X` | Root cause | Fix |
|---|---|---|
| `Ignoring request to auth address * port 1812 bound to server default from unknown client 10.20.0.9 port 51222` | NAS IP not covered by any `client` stanza | Add the client / widen the prefix. **The daemon deliberately does not respond** — this is a security feature |
| `Received packet from 10.20.0.5 with invalid Message-Authenticator! (Shared secret is incorrect.)` | Shared-secret mismatch, or a forgery attempt | Compare secrets on both ends. `radmin> stats client auth <ip>` shows the counter |
| `rlm_eap: SSL error error:0A000086:SSL routines::certificate verify failed` | Supplicant's `ca_cert` does not chain to the server cert's issuer | Push the correct CA to clients; check `openssl verify -CAfile ca.pem server.pem` |
| `eap_tls: TLS Alert read:fatal:unknown CA` | The **supplicant** rejected the server cert | Supplicant's trust store, `domain_suffix_match`, or an expired server cert |
| `eap_tls: TLS Alert write:fatal:certificate expired` | Bundled snake-oil certs (60-day life) or an expired client cert | Regenerate: `cd /etc/raddb/certs && make destroycerts && make` |
| `Certificate is not yet valid` | Clock skew on client or server | `chronyc tracking`; enforce NTP before deploying 802.1X |
| EAP loops forever, never completes | EAP fragment larger than the NAS `Framed-MTU` | Lower `fragment_size` to 1024 (or 512 for stubborn hardware) |
| `WARNING: Unresponsive child for request N` | A blocking module (LDAP/SQL) is timing out | Raise thread pool, add module timeouts, check the backend |
| `radwho` prints nothing | `rlm_radutmp` not in the `accounting {}` section, or no Accounting-Start received | Enable the module; verify with `radclient ... acct` |
| Auth succeeds but the port lands in the wrong VLAN | `Tunnel-*` attributes missing or the switch ignores them | Confirm the three attributes in the Access-Accept via `tshark`; enable `dynamic_vlan` on the authenticator |
| Works with `radtest`, fails from the switch | Two different code paths: `radtest` uses PAP against `localhost`; the switch uses EAP against a different `client` stanza | Reproduce with `eapol_test -a <server> -s <that client's secret>` |

Reproduce the exact NAS request without touching the NAS:

```
$ sudo radmin -f /var/run/radiusd/radiusd.sock
radmin> debug condition '(NAS-IP-Address == 10.20.0.5)'
radmin> debug file /var/log/radius/nas-10.20.0.5.log
# ... reproduce the failure ...
radmin> debug file
radmin> quit
$ sudo grep -E 'Auth-Type|reject|SSL error' /var/log/radius/nas-10.20.0.5.log
```

### 10.3 `nmap` failure catalogue

| Symptom | Cause | Fix |
|---|---|---|
| `All 1000 scanned ports are filtered` | Host firewall drops everything, or you are scanning through one | `--reason`, then `-sA` to map the filter itself |
| `Note: Host seems down` on a host you can ping | ICMP echo and the default discovery probes are blocked | `-Pn`, or tune `-PS22,443 -PA80` |
| SYN scan behaves like connect scan | Missing `CAP_NET_RAW` (container, non-root) | Add `NET_RAW`, or accept `-sT` and note it in the baseline |
| UDP scan takes hours | Kernel ICMP rate-limiting on the target | `--max-retries 1 --host-timeout 60s`, scan fewer ports |
| Different results run to run | Rate limiting, load balancers, or an IPS with active response | Lower `--min-rate`, use `-T2`, correlate with the IDS |
| `-6` scan finds nothing | Wrong source interface / no route | `-e eth0`, verify `ip -6 route get <target>` |
| NSE script not found | Script DB stale | `sudo nmap --script-updatedb` |

Prove what nmap actually put on the wire:

```
$ sudo nmap -sS -p 22 --packet-trace 10.20.30.20 2>&1 | head -8
SENT (0.0312s) ARP who-has 10.20.30.20 tell 10.20.30.90
RCVD (0.0318s) ARP reply 10.20.30.20 is-at 52:54:00:11:22:33
SENT (0.0431s) TCP 10.20.30.90:41525 > 10.20.30.20:22 S ttl=53 id=6431 iplen=44  seq=1852430812 win=1024 <mss 1460>
RCVD (0.0436s) TCP 10.20.30.20:22 > 10.20.30.90:41525 SA ttl=64 id=0 iplen=44  seq=2905172301 win=64240 <mss 1460>
```

### 10.4 Incident runbook — a rogue RA is live on the segment

```
# 1. CONFIRM: enumerate every advertiser on the link.
$ rdisc6 -m eth0 | grep -E 'from |Prefix|Router preference'

# 2. SCOPE: which hosts already took the poison?
$ ansible access_segment -a "ip -6 route show default" | grep -B1 'fe80::5054:ff:fe99:9999'

# 3. IDENTIFY the source port on the switch/hypervisor.
$ sudo journalctl -k -g RAGUARD-RA --since "-30m" | grep -oP 'IN=\K\S+' | sort -u
vnet7
$ sudo virsh domiflist $(sudo virsh list --name | while read d; do \
      sudo virsh domiflist "$d" | grep -q vnet7 && echo "$d"; done)

# 4. CONTAIN at L2 — do not rely on the victims.
$ sudo nft add rule bridge raguard guard iifname "vnet7" counter drop

# 5. PRESERVE evidence before anything is restarted.
$ sudo cp /var/lib/netsec/captures/kvm-07-ctrl*.pcapng /var/incident/2026-08-25/
$ sudo tshark -r /var/incident/2026-08-25/kvm-07-ctrl_00003.pcapng \
      -Y 'icmpv6.type == 134 && eth.src == 52:54:00:99:99:99' -w /var/incident/2026-08-25/rogue-ra.pcapng

# 6. REMEDIATE the victims. accept_ra=0 stops NEW learning; it does not
#    delete state that is already installed.
$ sudo sysctl -w net.ipv6.conf.eth0.accept_ra=0
$ sudo ip -6 route del default via fe80::5054:ff:fe99:9999 dev eth0
$ sudo ip -6 route del 2001:db8:dead::/64 dev eth0
$ sudo ip -6 addr del 2001:db8:dead:0:5054:ff:fe11:2233/64 dev eth0
$ sudo ip -6 neigh flush dev eth0

# 7. VERIFY the host is clean.
$ ip -6 route show | grep -c 'proto ra'
0
$ ip -6 route show default
default via fe80::5054:ff:feaa:bb01 dev eth0 proto static metric 100 pref medium

# 8. WATCH for recurrence.
$ ip -6 monitor route &
$ sudo tshark -i eth0 -Y 'icmpv6.type == 134 && !(eth.src == 52:54:00:aa:bb:01)' \
      -T fields -e frame.time -e eth.src -e ipv6.src
```

Step 6 is the one that gets skipped, and skipping it means the host stays MITM'd with `accept_ra=0` proudly set — an audit that passes while the compromise continues.

---

## 11. Exam checklist — terms and utilities for 334.1

| Utility / file | One-line role | Must be able to |
|---|---|---|
| `radiusd` / `freeradius` | The FreeRADIUS daemon | Run `-X` in the foreground and read the module trace |
| `radiusd.conf` | Global config, `$INCLUDE` chain | Locate `logdir`, `certdir`, thread pool, listeners |
| `/etc/raddb/*` | Config tree | Name `clients.conf`, `mods-available/eap`, `sites-available/default`, `mods-config/files/authorize`, `certs/` |
| `radtest` | PAP/CHAP/MSCHAP smoke test | Recite the positional argument order |
| `radclient` | Arbitrary-attribute RADIUS client | Send auth and acct packets, load test with `-c`/`-p` |
| `radwho` | Current sessions from `radutmp` | Know it requires `rlm_radutmp` in `accounting {}` |
| `radlast` | Historical sessions from `radwtmp` | Know it requires `rlm_sradutmp` |
| `radmin` | Live admin over the control socket | `stats detail`, `show module status`, `hup`, `debug condition`, `debug file` |
| `nmap` | Network/port/service auditor | `-sS -sT -sU -sA -sn -sV -O -6 -Pn -oA`, NSE, `ndiff` |
| `wireshark` | GUI analyser | Capture vs display filters, Follow Stream, Expert Info, Statistics |
| `tshark` | CLI Wireshark | `-f` vs `-Y`, `-T fields -e`, `-z io,stat`, `-z conv`, `-z expert` |
| `tcpdump` | Minimal capture | BPF syntax, `-nn -e -X -s0 -w -r` |
| `ndpmon` | NDP anomaly detector | `config_ndpmon.xml` router whitelist, alert taxonomy |

Related utilities the objective implies: `dumpcap`, `dhcpdump`, `rdisc6`/`ndisc6`, `radvd`, `eapol_test`, `wpa_supplicant`, `hostapd`, `nft`/`ebtables`, `ndiff`, `addrwatch`, `arpwatch`.

Ten facts that carry disproportionate exam weight:

1. RADIUS auth is UDP **1812**, accounting UDP **1813**; RadSec is TCP **2083**; the pre-standard legacy ports are 1645/1646.
2. `radtest` argument order: `user password server[:port] nas-port-number secret [ppphint] [nasname]`.
3. An unknown RADIUS client is **silently dropped**, not rejected.
4. `radwho`/`radlast` depend on the `radutmp`/`sradutmp` modules being present in the accounting section.
5. A capture filter (`-f`) is BPF and discards packets permanently; a display filter (`-Y`) works on already-captured packets.
6. A rogue RA is **ICMPv6 type 134**; a Neighbor Advertisement is 136; Redirect is 137.
7. `net.ipv6.conf.<if>.accept_ra` must be **2** if `forwarding=1` and you still want to accept RAs.
8. RA Guard (RFC 6105) is evaded by IPv6 fragmentation (RFC 7113); the mitigation is dropping fragmented NDP (RFC 6980).
9. `nmap -sA` distinguishes `filtered` from `unfiltered` — it maps the firewall, never the listening service.
10. UDP ports with no reply are reported `open|filtered` because UDP has no negative acknowledgement.

---

## 12. Referencias

**Certification**
- LPI — Exam 303 Objectives (303-300, v3.0.0): https://www.lpi.org/our-certifications/exam-303-objectives/
- LPI — LPIC-3 Security overview: https://www.lpi.org/our-certifications/lpic-3-303-overview/

**FreeRADIUS**
- FreeRADIUS documentation index: https://www.freeradius.org/documentation/
- FreeRADIUS 3.2 configuration reference: https://www.freeradius.org/documentation/freeradius-server/3.2.7/
- FreeRADIUS wiki (EAP, certificates, debugging): https://wiki.freeradius.org/
- FreeRADIUS security advisories (incl. CVE-2024-3596): https://www.freeradius.org/security/
- Blast-RADIUS vulnerability disclosure: https://www.blastradius.fail/
- NVD — CVE-2024-3596: https://nvd.nist.gov/vuln/detail/CVE-2024-3596

**IETF standards**
- RFC 2865 — Remote Authentication Dial In User Service (RADIUS): https://datatracker.ietf.org/doc/html/rfc2865
- RFC 2866 — RADIUS Accounting: https://datatracker.ietf.org/doc/html/rfc2866
- RFC 3579 — RADIUS Support for EAP: https://datatracker.ietf.org/doc/html/rfc3579
- RFC 3748 — Extensible Authentication Protocol (EAP): https://datatracker.ietf.org/doc/html/rfc3748
- RFC 5216 — The EAP-TLS Authentication Protocol: https://datatracker.ietf.org/doc/html/rfc5216
- RFC 9190 — EAP-TLS 1.3: https://datatracker.ietf.org/doc/html/rfc9190
- RFC 7170 — TEAP: https://datatracker.ietf.org/doc/html/rfc7170
- RFC 6614 — RADIUS over TLS (RadSec): https://datatracker.ietf.org/doc/html/rfc6614
- RFC 7360 — RADIUS over DTLS: https://datatracker.ietf.org/doc/html/rfc7360
- IETF RADEXT working group (RADIUS deprecation and hardening work): https://datatracker.ietf.org/wg/radext/documents/
- RFC 4861 — Neighbor Discovery for IPv6: https://datatracker.ietf.org/doc/html/rfc4861
- RFC 4862 — IPv6 Stateless Address Autoconfiguration: https://datatracker.ietf.org/doc/html/rfc4862
- RFC 4191 — Default Router Preferences and More-Specific Routes: https://datatracker.ietf.org/doc/html/rfc4191
- RFC 6724 — Default Address Selection for IPv6: https://datatracker.ietf.org/doc/html/rfc6724
- RFC 3971 — SEcure Neighbor Discovery (SEND): https://datatracker.ietf.org/doc/html/rfc3971
- RFC 6105 — IPv6 Router Advertisement Guard: https://datatracker.ietf.org/doc/html/rfc6105
- RFC 7113 — Implementation Advice for RA-Guard (fragmentation evasion): https://datatracker.ietf.org/doc/html/rfc7113
- RFC 6980 — Security Implications of IPv6 Fragmentation with NDP: https://datatracker.ietf.org/doc/html/rfc6980
- RFC 8415 — DHCP for IPv6 (DHCPv6): https://datatracker.ietf.org/doc/html/rfc8415
- RFC 2131 — Dynamic Host Configuration Protocol: https://datatracker.ietf.org/doc/html/rfc2131

**IEEE**
- IEEE 802.1X-2020 — Port-Based Network Access Control: https://standards.ieee.org/ieee/802.1X/7345/
- IEEE 802.1AE — MAC Security (MACsec): https://standards.ieee.org/ieee/802.1AE/7154/

**Nmap**
- Nmap reference guide (man page): https://nmap.org/book/man.html
- Port scanning techniques: https://nmap.org/book/man-port-scanning-techniques.html
- Host discovery: https://nmap.org/book/man-host-discovery.html
- NSE script documentation: https://nmap.org/nsedoc/
- Ndiff: https://nmap.org/ndiff/
- Nmap legal and ethical usage: https://nmap.org/book/legal-issues.html

**Wireshark / capture**
- Wireshark User's Guide: https://www.wireshark.org/docs/wsug_html_chunked/
- `tshark` manual page: https://www.wireshark.org/docs/man-pages/tshark.html
- `dumpcap` manual page: https://www.wireshark.org/docs/man-pages/dumpcap.html
- Display filter reference: https://www.wireshark.org/docs/dfref/
- CaptureFilters wiki (BPF syntax): https://wiki.wireshark.org/CaptureFilters
- `pcap-filter(7)` — BPF grammar: https://www.tcpdump.org/manpages/pcap-filter.7.html
- `tcpdump` manual page: https://www.tcpdump.org/manpages/tcpdump.1.html

**Linux networking and filtering**
- Kernel IP sysctl documentation: https://docs.kernel.org/networking/ip-sysctl.html
- nftables wiki: https://wiki.nftables.org/wiki-nftables/index.php/Main_Page
- nftables bridge-family filtering: https://wiki.nftables.org/wiki-nftables/index.php/Bridge_filtering
- ebtables/nftables project page: https://netfilter.org/projects/ebtables/
- `hostapd` / `wpa_supplicant` documentation: https://w1.fi/hostapd/ and https://w1.fi/wpa_supplicant/
- `wpa_supplicant.conf` template: https://w1.fi/cgit/hostap/plain/wpa_supplicant/wpa_supplicant.conf
- Linux MACsec (`ip-macsec(8)`): https://man7.org/linux/man-pages/man8/ip-macsec.8.html

**IPv6 NDP monitoring**
- NDPMon project: https://ndpmon.sourceforge.net/
- `ndisc6` / `rdisc6` toolkit: https://www.remlab.net/ndisc6/
- `radvd` project and man pages: https://radvd.litech.org/
- `addrwatch`: https://github.com/fln/addrwatch