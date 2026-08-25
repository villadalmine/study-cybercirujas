# 334.1 — Fortalecimiento de red (Network Hardening)

**LPIC-3 303 (Security), examen 303-300 v3.0.0 — Tema 334: Seguridad de red**
**Peso: 6.67** — uno de los objetivos individuales más pesados del examen. El material que sigue está escrito a profundidad de producción: FreeRADIUS como plano de autenticación, `nmap` como instrumento de auditoría, `tshark`/`wireshark` como la verdad de fondo del cable, y fortalecimiento de Capa 2/NDP contra router advertisements maliciosos y DHCP malicioso.

---

## 1. El problema arquitectónico: un puerto de acceso es una API sin autenticar

Toda plataforma endurecida termina colapsando en la misma pregunta: **¿qué le concede la red a un dispositivo antes de que ese dispositivo haya demostrado algo?**

En la configuración por defecto de casi cualquier switch, bridge de hipervisor y `br0` de Linux, la respuesta es: *todo lo que hay en ese dominio de broadcast*. Enchufás, obtenés adyacencia L2, hacés ARP del gateway, recibís un router advertisement, tomás un lease DHCP, y ya sos par de todos los nodos de producción de la VLAN. No se presentó ninguna credencial. La frontera de identidad es física — una puerta de rack con llave — y las fronteras físicas no sobreviven a contratistas, puertos IPMI, bridges WiFi, switches no administrados debajo de un escritorio, ni a un contenedor comprometido con `CAP_NET_RAW` sobre `hostNetwork: true`.

Este objetivo trata de mover esa frontera de **física** a **criptográfica**, y luego demostrar que se movió:

| Control | Pregunta que responde | Falla si está ausente |
|---|---|---|
| 802.1X + RADIUS | *¿Se permite a este dispositivo estar en el cable, siquiera?* | Cualquier puerto físico es una credencial de producción |
| Fortalecimiento del transporte RADIUS (RadSec / Message-Authenticator) | *¿Se puede falsificar la propia decisión de autenticación?* | Blast-RADIUS (CVE-2024-3596): un atacante en el camino convierte un Access-Reject en Access-Accept |
| RA Guard / DHCP Guard | *¿Quién tiene permitido definir la realidad de ruteo y nombres de este segmento?* | MITM silencioso de una red "solo IPv4" vía SLAAC de IPv6 |
| Línea base con `nmap` | *¿Qué está escuchando realmente, frente a lo que dice el runbook?* | El kubelet en 10250, el puerto JMX de depuración, el `jetdirect` olvidado |
| `tshark`/`wireshark` | *¿El plano de control está haciendo lo que dice la configuración?* | Toda otra capa es una afirmación; la captura es la evidencia |

Una asimetría crucial para internalizar de cara al examen y a producción: **802.1X autentica el puerto; no autentica los paquetes que vienen después.** Una vez que el puerto se abre, un atacante que se intercala físicamente entre supplicant y switch inyecta tramas en un puerto autorizado. Cerrar esa brecha requiere MACsec (802.1AE, §7). Conocé dónde termina cada control.

### 1.1 Modelo de amenazas de un solo segmento de acceso

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

Clases de ataque, en orden ascendente de con qué frecuencia se pasan por alto en auditorías reales:

1. **Puerto sin autenticar** — sin 802.1X. Trivial.
2. **Servidor DHCPv4 malicioso** — el atacante responde al `DHCPDISCOVER` más rápido que el servidor legítimo y se entrega a sí mismo como gateway por defecto y DNS.
3. **RA malicioso (ICMPv6 tipo 134)** — el de mayor valor y el menos monitoreado. Incluso en una red que creés solo IPv4, Linux, Windows y macOS tienen IPv6 habilitado y `accept_ra` activo por defecto. Un único RA no solicitado instala una ruta por defecto con **mayor precedencia que IPv4** (la selección de dirección de destino de RFC 6724 prefiere IPv6), convirtiendo silenciosamente al atacante en el gateway por defecto de todos los hosts dual-stack del segmento. Sin envenenamiento ARP, sin inundación de paquetes, sin alarmas.
4. **Evasión de RA Guard por fragmentación** (RFC 7113) — el RA se parte de modo que el ASIC del switch nunca ve el campo de tipo ICMPv6.
5. **Ataques al secreto compartido / transporte de RADIUS** — ataque de diccionario offline sobre el Response Authenticator MD5, o falsificación por colisión de Blast-RADIUS.

---

## 2. 802.1X y RADIUS: el plano de autenticación

### 2.1 Los tres roles y los dos protocolos

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

- **EAPOL** (EAP over LAN, EtherType `0x888E`) corre entre supplicant ↔ authenticator, sobre la MAC multicast reservada `01:80:C2:00:00:03` (dirección de grupo PAE).
- **RADIUS** (RFC 2865, transporte de EAP según RFC 3579) corre entre authenticator ↔ servidor de autenticación, UDP/1812 (auth) y UDP/1813 (accounting), o TCP/2083 para RadSec.
- El authenticator es un **relay tonto**: nunca ve dentro del método EAP. Por eso un switch no necesita conocimiento alguno de certificados para EAP-TLS.
- Los atributos `MS-MPPE-Recv-Key`/`Send-Key` transportan la MSK derivada de vuelta al authenticator, cifrada con el secreto compartido. **Por eso un secreto compartido RADIUS débil compromete el material de claves de WPA2-Enterprise y MACsec, no solo la decisión de aceptar/rechazar.**

### 2.2 Compromisos entre métodos EAP

| Método | Cert. de servidor | Cert. de cliente | Privacidad de identidad | Credencial expuesta si no se valida el cert. de servidor | Requisito de la base de contraseñas | Veredicto para producción |
|---|---|---|---|---|---|---|
| **EAP-TLS** (RFC 5216, TLS 1.3 en RFC 9190) | Requerido | **Requerido** | Solo identidad externa (CN del cert. visible antes de TLS1.3) | Nada — autenticación mutua | Ninguno (PKI) | **Elección por defecto.** No hay contraseñas que phishear. El costo es el ciclo de vida de la PKI: emisión, renovación, CRL/OCSP |
| **PEAPv0/EAP-MSCHAPv2** | Requerido | No | Sí (túnel interno) | Desafío/respuesta MSCHAPv2 → crackeo offline → hash NTLM | Almacén de NT-hash reversible | Aceptable solo con pinning de CA forzado en cada cliente. Una sola laptop mal configurada filtra credenciales de dominio |
| **EAP-TTLS/PAP** | Requerido | No | Sí | **Contraseña en texto plano** | Cualquier backend (bind LDAP, PAM, SQL) | Útil cuando el backend no puede exponer hashes; catastrófico si el túnel no se valida |
| **EAP-PWD** (RFC 5931) | No | No | Parcial | Nada (PAKE, resistente a diccionario) | Texto plano o equivalente | Elegante, sin PKI, pero soporte de cliente escaso |
| **TEAP** (RFC 7170) | Requerido | Opcional | Sí | Depende del método interno | Varía | Permite *encadenar* autenticación de usuario + máquina en una sesión. Soporte escaso en Linux |
| **MAB** (MAC Auth Bypass — no es EAP) | — | — | Ninguna | La MAC se falsifica trivialmente | Lista de MACs | Solo para impresoras/IPMI, en una VLAN de cuarentena, nunca como fallback global |

**Regla arquitectónica:** si no se puede forzar al cliente a validar el certificado del servidor contra una CA específica *y* un nombre de servidor específico, no despliegues PEAP ni TTLS. Un túnel sin validar convierte todo el intercambio EAP en un embudo de cosecha de credenciales para cualquiera que corra un authenticator malicioso.

### 2.3 Compromisos del transporte RADIUS

RADIUS fue diseñado en 1997 y su protección de paquetes es `MD5(Code|ID|Length|RequestAuth|Attributes|Secret)`. Esto tiene consecuencias.

| Transporte | Puerto | Confidencialidad | Integridad | Resistencia a replay/falsificación | Notas |
|---|---|---|---|---|---|
| **RADIUS/UDP** (RFC 2865) | 1812/1813 | Solo `User-Password` (flujo XOR con MD5) | Response Authenticator = MD5 | **Rota** — CVE-2024-3596 (Blast-RADIUS) falsifica un Access-Accept vía colisión MD5 de prefijo elegido | Mitigación obligatoria: `require_message_authenticator = yes` en cada cliente, de ambos lados |
| **RADIUS/UDP + Message-Authenticator** (RFC 3579) | 1812/1813 | Igual | HMAC-MD5 sobre todo el paquete | Blast-RADIUS mitigado; el secreto compartido sigue siendo atacable por diccionario offline desde una captura | Configuración mínima aceptable hoy |
| **RadSec / RADIUS-over-TLS** (RFC 6614) | **TCP/2083** | TLS completo | TLS | Sí, con autenticación mutua por certificado | La respuesta correcta. El secreto compartido pasa a ser la cadena literal `radsec` |
| **RADIUS/DTLS** (RFC 7360) | UDP/2083 | DTLS completo | DTLS | Sí | Para dispositivos que no pueden mantener estado TCP |
| **RADIUS/UDP dentro de IPsec** | 1812/1813 | IPsec | IPsec | Sí | Camino de retrofit cuando el firmware del NAS es anterior a RadSec |

```
$ sudo tshark -i eth0 -f 'udp port 1812' -Y 'radius' \
    -T fields -e radius.code -e radius.id -e radius.Message_Authenticator
Access-Request  215
Access-Accept   215
```
Una tercera columna vacía es el hallazgo de auditoría: **sin Message-Authenticator, por lo tanto expuesto a Blast-RADIUS.**

---

## 3. FreeRADIUS en producción — configuración completa

### 3.1 Disposición de archivos (FreeRADIUS 3.2.x)

| Ruta (RHEL/Fedora) | Ruta (Debian/Ubuntu) | Rol |
|---|---|---|
| `/etc/raddb/radiusd.conf` | `/etc/freeradius/3.0/radiusd.conf` | Global: usuario/grupo, hilos, listeners, logging, cadena de `$INCLUDE` |
| `/etc/raddb/clients.conf` | ídem | Registro de NAS: IP/prefijo, secreto compartido, política por cliente |
| `/etc/raddb/mods-available/` → `mods-enabled/` | ídem | Módulos (`eap`, `files`, `ldap`, `sql`, `radutmp`, `pap`, `mschap`) — se habilitan por symlink |
| `/etc/raddb/sites-available/` → `sites-enabled/` | ídem | Servidores virtuales: `default`, `inner-tunnel`, `tls`, `control-socket` |
| `/etc/raddb/mods-config/files/authorize` | ídem | El clásico archivo `users` |
| `/etc/raddb/certs/` | ídem | PKI de CA, servidor y cliente + `Makefile`, `bootstrap` |
| `/etc/raddb/policy.d/` | ídem | Políticas `unlang` reutilizables (`filter_username`, etc.) |
| `/var/log/radius/radius.log` | `/var/log/freeradius/` | Log del demonio |
| `/var/log/radius/radutmp` / `radwtmp` | ídem | Estado de sesión que consumen `radwho` / `radlast` |

El binario es `radiusd` en RHEL y `freeradius` en Debian — **el mismo ELF**, y ambos aceptan `-X`.

### 3.2 `clients.conf` — registro de NAS endurecido

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

Los secretos vienen del entorno (`@{ENV:...}`), inyectados por `EnvironmentFile=` de systemd o por un Secret de Kubernetes, de modo que `clients.conf` permanece en Git.

### 3.3 `mods-available/eap` — EAP-TLS primero

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

### 3.4 PKI: no pongas en producción los certificados snake-oil incluidos

FreeRADIUS trae certificados de prueba autofirmados que **expiran 60 días después de la instalación**. La mitad de todos los incidentes de "802.1X dejó de funcionar de repente" son exactamente esto.

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

Dos extensiones no son negociables:
- **El certificado de servidor debe llevar `extendedKeyUsage = serverAuth`** y el OID de Microsoft `1.3.6.1.5.5.7.3.1`; si no, los supplicants de Windows lo rechazan.
- **El certificado de cliente debe llevar `clientAuth`** (`1.3.6.1.5.5.7.3.2`).

### 3.5 Autorización: `mods-config/files/authorize`

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

La distinción entre `:=` y `=` es examinable: `=` fija el atributo **solo si no está ya presente**; `:=` **sobrescribe**; `+=` agrega otra instancia.

### 3.6 Listener RadSec — `sites-available/tls`

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

### 3.7 Accounting y el módulo `radutmp` (esto es lo que leen `radwho`/`radlast`)

`radwho` y `radlast` no son magia — parsean archivos binarios de sesión producidos por `rlm_radutmp`. Si el accounting no está habilitado, ambos no devuelven nada, y esa es una trampa de examen extremadamente común.

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

### 3.8 Fortalecimiento con systemd para `radiusd`

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

### 3.9 Laboratorio reproducible — `docker-compose.yml`

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

### 3.10 Playbook de fortalecimiento del host — Ansible

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

### 3.11 Sensor de red en Kubernetes — DaemonSet + línea base `nmap` programada

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

`nmap` necesita `NET_RAW` para `-sS`; sin esa capability el escaneo SYN degrada silenciosamente a un escaneo connect (`-sT`) y tu línea base cambia de significado.

---

## 4. Operar FreeRADIUS: la disciplina de depuración

**Regla cero: `radiusd -X` es el único depurador real.** Los archivos de log resumen; `-X` muestra la ruta exacta de ejecución de `unlang`, cada atributo y cada código de retorno de módulo.

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

### 4.1 `radtest` — prueba de humo con credenciales en texto plano

Sintaxis: `radtest [options] user password radius-server[:port] nas-port-number secret [ppphint] [nasname]`

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

Un rechazo:

```
$ radtest bob "wrong" 127.0.0.1 0 lab-local-secret-change-me
Sent Access-Request Id 47 from 0.0.0.0:47112 to 127.0.0.1:1812 length 69
Received Access-Reject Id 47 from 127.0.0.1:1812 to 127.0.0.1:47112 length 39
	Reply-Message = "No authorization policy matched this identity"
```

`radtest` acepta `-t <proto>` para el tipo de autenticación: `pap` (por defecto), `chap`, `mschap`, `eap-md5`.

```
$ radtest -t mschap bob "S3cr3t-lab" 127.0.0.1 0 lab-local-secret-change-me
```

### 4.2 `radclient` — construcción arbitraria de atributos

`radclient` es la herramienta de bajo nivel: envía los atributos que le des por stdin, que es la forma de reproducir la petición exacta de un NAS.

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

Prueba de carga antes de una ventana de mantenimiento que va a reautenticar 4.000 puertos de golpe:

```
$ radclient -x -c 100 -p 20 -t 3 -r 2 -f /tmp/requests.txt \
    10.20.30.10:1812 auth lab-switch-secret-change-me | tail -5
Received Access-Accept Id 98 from 10.20.30.10:1812 to 10.20.30.20:52344 length 38
Received Access-Accept Id 99 from 10.20.30.10:1812 to 10.20.30.20:52344 length 38
Total approved auths:  2000
Total denied auths:    0
Total lost auths:      0
```
Flags: `-c` cantidad por entrada de entrada, `-p` paralelas en vuelo, `-t` timeout, `-r` reintentos, `-f` archivo de peticiones, `-s` estadísticas de resumen.

Accounting:

```
$ echo "User-Name=bob,Acct-Status-Type=Start,Acct-Session-Id='0000ABCD', \
NAS-IP-Address=10.20.0.5,NAS-Port=50110,Framed-IP-Address=10.20.30.20" \
  | radclient -x 10.20.30.10:1813 acct lab-switch-secret-change-me
Received Accounting-Response Id 12 from 10.20.30.10:1813 ... length 20
```

### 4.3 `eapol_test` — la única prueba honesta de EAP

`radtest` no puede probar EAP-TLS ni PEAP. `eapol_test`, distribuido con `wpa_supplicant`, emula un supplicant completo *y* un authenticator, y habla RADIUS real.

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

`MPPE keys OK: 1` demuestra que la MSK fue entregada — que es de lo que realmente depende un despliegue de WPA2-Enterprise o MACsec.

### 4.4 `radwho` y `radlast` — visibilidad de sesiones

```
$ radwho
Login      Name              What  TTY  When       From        Location
bob        Bob Smith        shell  S0   Tue 10:14  10.20.30.20 sw-access-01
worker-01  --               shell  S1   Tue 09:02  10.20.30.21 sw-access-01
```

Flags útiles: `-c` (salida corta/CLI), `-i` (imprimir IDs de sesión), `-r` (crudo, parseable por máquina), `-s` (corto), `-u` (mostrar solo la sesión de un usuario), `-f <file>` (archivo `radutmp` alternativo).

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

`radlast -f /var/log/radius/radwtmp -n 50 bob` restringe a un solo usuario. Ambas herramientas son inútiles sin `rlm_radutmp`/`rlm_sradutmp` en la sección de accounting (§3.7).

### 4.5 `radmin` — control en vivo sin reiniciar

Requiere el socket de control. Habilitalo:

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

`debug condition` + `debug file` es el superpoder de producción: trazado completo a nivel `-X` para **una sola identidad**, en un servidor vivo atendiendo miles de sesiones, sin reiniciar. Siempre devolvé `debug file` a vacío (`radmin> debug file`) después — la traza contiene credenciales.

`bad_authenticator: 12` en la salida de arriba es un hallazgo real: doce paquetes llegaron con un Message-Authenticator que no verificó. Eso es o bien una discrepancia del secreto compartido en un NAS, o un intento activo de falsificación.

---

## 5. Configuración del authenticator y del supplicant

### 5.1 `hostapd` como authenticator 802.1X cableado

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

### 5.2 `wpa_supplicant` sobre una interfaz cableada

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

`Supplicant PAE state=AUTHENTICATED` y `suppPortStatus=Authorized` son los dos campos que importan. `wpa_state=COMPLETED` por sí solo puede ser verdadero mientras el puerto sigue bloqueado.

Para hosts gestionados por NetworkManager el equivalente es una conexión keyfile:

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

## 6. MACsec — cerrando la brecha posterior a la autenticación

802.1X autoriza un puerto; las tramas que vienen después van en texto plano por el cable. MACsec (IEEE 802.1AE) cifra y autentica cada trama, con clave derivada de la MSK que EAP ya generó.

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

Notá el `mtu 1468`: MACsec agrega 32 bytes de SecTAG+ICV. Cualquier host que espere 1500 va a hacer blackhole de tramas grandes — un incidente clásico posterior al despliegue. Ajustá la MTU de extremo a extremo o habilitá jumbo frames en el switch.

---

## 7. `nmap` — auditar lo que está realmente expuesto

### 7.1 Matriz de tipos de escaneo

| Escaneo | Flag | ¿Root? | Mecanismo | `open` | `closed` | `filtered` | Cuándo usarlo |
|---|---|---|---|---|---|---|---|
| TCP SYN ("half-open") | `-sS` | Sí | SYN → SYN/ACK vs RST | SYN/ACK | RST | sin respuesta / ICMP unreach | Por defecto. Rápido, no deja entrada de log a nivel aplicación, pero llena el conntrack en firewalls con estado |
| TCP connect | `-sT` | No | `connect()` completo | éxito | ECONNREFUSED | timeout | Contextos sin privilegios, contenedores sin `NET_RAW` |
| UDP | `-sU` | Sí | payload vacío/de protocolo | respuesta de la app | ICMP port unreach | sin respuesta → `open\|filtered` | Lento y ambiguo; el rate-limiting ICMP del kernel domina el tiempo de ejecución |
| ACK | `-sA` | Sí | ACK a secas | — | — | `unfiltered` vs `filtered` | **Mapeo de reglas de firewall**: te dice qué deja pasar el filtro, no qué escucha |
| Window | `-sW` | Sí | ACK + heurística de ventana TCP | ventana≠0 | ventana=0 | — | Infiere abierto/cerrado en pilas con la vieja peculiaridad de la ventana |
| NULL / FIN / Xmas | `-sN` `-sF` `-sX` | Sí | sin flags / FIN / FIN+PSH+URG | sin respuesta | RST | ICMP unreach | Evade filtros ingenuos sin estado; inútil contra Windows, Cisco y muchos appliances (responden RST a todo) |
| Maimon | `-sM` | Sí | FIN/ACK | — | RST | — | Pilas derivadas de BSD |
| Idle | `-sI zombie` | Sí | canal lateral de IP-ID en un tercer host | inferido | inferido | inferido | Escaneo sin atribución; solo para trabajo autorizado de red team con un zombie documentado |
| Barrido ping | `-sn` | — | ARP en el enlace; ICMP echo + SYN TCP/80 + ACK TCP/443 + ICMP timestamp fuera del enlace | — | — | — | Inventario. El ARP en el enlace no se puede filtrar con firewall |
| Sin descubrimiento | `-Pn` | — | asume todos los hosts activos | — | — | — | Redes que descartan sondas; multiplica el tiempo de ejecución |
| Escaneo de protocolo | `-sO` | Sí | enumeración del campo de protocolo IP | — | — | — | Encuentra alcanzabilidad de GRE/ESP/AH/OSPF |

### 7.2 Descubrimiento de hosts e inventario

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

`10.20.30.66`, con un nombre que no resuelve y un OUI no reconocido, es el hallazgo. Cruzalo con los leases DHCP y la tabla de sesiones `radutmp`.

### 7.3 Superficie TCP completa de un nodo

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

Que `2379/tcp` sea alcanzable desde una VLAN de acceso es un hallazgo crítico: etcd es todo el estado del clúster, y un etcd sin certificado de cliente es un compromiso total.

### 7.4 Detección de servicio y versión

```
$ sudo nmap -sV --version-intensity 5 -p 22,6443,10250 10.20.30.20
PORT      STATE SERVICE  VERSION
22/tcp    open  ssh      OpenSSH 9.6 (protocol 2.0)
6443/tcp  open  ssl/http Golang net/http server
10250/tcp open  ssl/http Golang net/http server

Service detection performed. Please report any incorrect results at https://nmap.org/submit/ .
Nmap done: 1 IP address (1 host up) scanned in 12.09 seconds
```

### 7.5 UDP: la mitad que nadie escanea

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

`open|filtered` no es pereza — es la respuesta honesta. UDP no tiene acuse negativo para un puerto abierto, así que el silencio es indistinguible de un descarte. Resolvelo con `-sV` (que envía payloads específicos del protocolo) o capturando en el destino.

### 7.6 Mapeo de reglas de firewall con `-sA`

```
$ sudo nmap -sA -p 22,80,443,3306,6443 10.20.31.50
PORT     STATE      SERVICE
22/tcp   unfiltered ssh
80/tcp   unfiltered http
443/tcp  unfiltered https
3306/tcp filtered   mysql
6443/tcp filtered   sun-sr-https
```

`unfiltered` significa que el ACK atravesó el filtro y produjo un RST — el firewall permite ese puerto (si está abierto o cerrado, se desconoce). `filtered` significa descartado. Así es como se *audita un conjunto de reglas* en lugar de una lista de servicios.

### 7.7 IPv6 — por qué el barrido está muerto y qué lo reemplaza

Un `/64` son 1,8×10¹⁹ direcciones. El barrido por fuerza bruta es computacionalmente imposible, lo que regularmente se confunde con seguridad. No lo es: el descubrimiento por multicast, el DNS y la caché de vecinos enumeran hosts al instante.

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

Fuentes complementarias: `ip -6 neigh show`, bases de datos de leases DHCPv6, registros `AAAA` en la zona y la salida de `rdisc6`.

### 7.8 NSE para chequeos de postura defensiva

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

Categorías de scripts que conviene conocer: `safe`, `default`/`-sC`, `discovery`, `auth`, `vuln`, `broadcast`, `intrusive`, `dos`, `exploit`. **`intrusive`, `dos` y `exploit` nunca se corren contra producción sin un registro de cambio escrito.** `--script-updatedb` reconstruye el índice de scripts.

### 7.9 Escaneo seguro en producción

| Preocupación | Control |
|---|---|
| Agotamiento del conntrack en el firewall del destino | `--max-rate 300`, `--max-retries 2`, `-T3`; vigilá `nf_conntrack_count` en el destino |
| Dispositivos frágiles (embebidos, PLC, impresoras viejas) | `-sT` en vez de `-sS`, excluilos con `--excludefile` |
| Ruido de IDS / paginado a la guardia | Anunciá la ventana, o agregá las IPs del escáner a la allowlist del IDS |
| Escaneos largos sobre enlaces inestables | `--host-timeout 90s`, `--scan-delay` |
| Reproducibilidad | Siempre `-oA <prefix>`; commiteá el XML |
| Detección de deriva | `ndiff old.xml new.xml` |

```
$ ndiff scans/worker-01-baseline.xml scans/worker-01-20260825.xml
-Nmap 7.95 scan initiated Mon Aug 18 03:17:00 2026
+Nmap 7.95 scan initiated Tue Aug 25 03:17:00 2026
 worker-01.prod.internal (10.20.30.20):
+Not shown: 65528 closed ports
 PORT      STATE SERVICE VERSION
+2375/tcp  open  docker  Docker 26.1.4
```

`2375/tcp` — un socket Docker sin autenticar apareció de la noche a la mañana. Esa sola línea es toda la justificación del CronJob de §3.11.

---

## 8. Análisis de tráfico: `tcpdump`, `dumpcap`, `tshark`, `wireshark`

### 8.1 Selección de herramienta

| Herramienta | Dónde corre | Fortaleza | Debilidad |
|---|---|---|---|
| `tcpdump` | En cualquier lado, siempre instalado | Diminuto, nativo de libpcap, seguro en una máquina cargada | Sin disectores más allá de un puñado; sin estadísticas |
| `dumpcap` | Motor de captura de Wireshark | **Construido solo para capturar** — la menor superficie de ataque privilegiada, ring buffers nativos | No puede disecar ni filtrar con filtros de visualización |
| `tshark` | Servidores, CI, contenedores | Disección completa de Wireshark + estadísticas `-z` + extracción de campos (`-T fields`) | El motor de disección es grande y privilegiado si corre como root — capturá con `dumpcap`, disecá offline |
| `wireshark` | Estación de trabajo del analista | Follow-stream, expert info, UI de descifrado TLS, gráficos de E/S | Nunca en un host de producción: enorme superficie de ataque de parsers corriendo como usuario de escritorio |

**El patrón correcto en producción:** capturar con `dumpcap` (o `tcpdump`) en el host, analizar el `.pcapng` fuera del host con `tshark`/`wireshark`. Históricamente, los disectores de Wireshark han sido una fuente rica de ejecución remota de código a partir de paquetes maliciosos.

### 8.2 Modelo de privilegios — no corras la captura como root

```
$ sudo dpkg-reconfigure wireshark-common      # Debian: answer "Yes"
$ sudo usermod -aG wireshark "$USER"
$ sudo setcap cap_net_raw,cap_net_admin=eip /usr/bin/dumpcap
$ getcap /usr/bin/dumpcap
/usr/bin/dumpcap cap_net_raw,cap_net_admin=eip
$ ls -l /usr/bin/dumpcap
-rwxr-xr-- 1 root wireshark 121584 Mar  4 2026 /usr/bin/dumpcap
```

`0754 root:wireshark` más las capabilities de archivo significan que solo los miembros del grupo pueden capturar, y que ningún proceso corre como root.

### 8.3 Filtros de captura (BPF) versus filtros de visualización — una distinción clásica de examen

| | Filtro de captura | Filtro de visualización |
|---|---|---|
| Sintaxis | libpcap / BPF | Lenguaje de filtros de visualización de Wireshark |
| Se aplica | En el kernel, **antes** de que el paquete se almacene | Después de la disección completa, sobre paquetes almacenados |
| Flag de CLI | `-f` | `-Y` (`tshark`), `-R` (obsoleto, solo dos pasadas) |
| ¿Puede recuperar paquetes descartados? | No — los datos se perdieron para siempre | Sí, refiltrá el mismo archivo infinitas veces |
| Ejemplo | `-f "udp port 1812 or icmp6"` | `-Y "radius.code == 3 && icmpv6.type == 134"` |
| Costo | Casi gratis; la única forma de sobrevivir a 10 Gb/s | Caro; disección completa de cada paquete |

Confundir esto es la falla de captura más común: un filtro de visualización tipeado en `-f` produce `syntax error` en el mejor caso, y un filtro de captura tipeado en `-Y` no coincide con nada, en silencio.

| Objetivo | Filtro de captura (`-f`) | Filtro de visualización (`-Y`) |
|---|---|---|
| Auth RADIUS | `udp port 1812` | `radius` |
| RADIUS con EAP | `udp port 1812` | `eap` |
| RadSec | `tcp port 2083` | `tls && tcp.port == 2083` |
| Todo ICMPv6 | `icmp6` | `icmpv6` |
| Router Advertisements | `icmp6 and ip6[40] == 134` | `icmpv6.type == 134` |
| DHCPv4 | `udp port 67 or udp port 68` | `dhcp` (era `bootp` antes de 3.0) |
| DHCPv6 | `udp port 546 or udp port 547` | `dhcpv6` |
| EAPOL | `ether proto 0x888e` | `eapol` |
| ARP gratuito | `arp` | `arp.isgratuitous == 1` |
| Excluir tu propio SSH | `not port 22` | `!(tcp.port == 22)` |

### 8.4 Capturar correctamente

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

`Packets ... dropped: 0` es la línea que valida la captura. Descartes distintos de cero significan que el análisis está construido sobre un registro incompleto — aumentá el buffer con `-B 64` (MiB) o ajustá el filtro de captura.

**Deshabilitá los offloads antes de capturar**, o la traza mostrará "tramas" imposibles de 40 KB y checksums equivocados:

```
$ sudo ethtool -K eth0 gro off gso off tso off lro off
$ ethtool -k eth0 | grep -E 'generic-receive|tcp-segmentation'
tcp-segmentation-offload: off
generic-receive-offload: off
```

### 8.5 Disecar el intercambio RADIUS/EAP

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

Códigos RADIUS: `1` Access-Request, `2` Access-Accept, `3` Access-Reject, `4` Accounting-Request, `5` Accounting-Response, `11` Access-Challenge. El tipo EAP `13` es EAP-TLS, `25` PEAP, `21` TTLS, `26` MSCHAPv2, `1` Identity.

Decodificación completa de un paquete:

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

Para que Wireshark verifique los authenticators y descifre `User-Password`, configurá el secreto compartido:

```
$ tshark -r access-ctrl.pcapng -o 'radius.shared_secret:lab-switch-secret-change-me' \
    -Y 'radius' -V | grep -E 'Message-Authenticator|Authenticator: |Malformed'
    Authenticator: 3f8a2b1c9d4e5f60718293a4b5c6d7e8 [correct]
    AVP: t=Message-Authenticator(80) l=18 val=1a2b3c... [correct]
```
La anotación `[correct]` / `[incorrect]` es exactamente el chequeo que detecta una discrepancia de secreto compartido en una flota de NAS.

Para RadSec, descifrá con un key log:

```
$ SSLKEYLOGFILE=/tmp/radsec.keys radiusd -X   # FreeRADIUS 3.2 honours this
$ tshark -r radsec.pcapng -o tls.keylog_file:/tmp/radsec.keys -Y 'radius'
```

### 8.6 Estadísticas: `-z`

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

Un radvd que envía cada 200–600 s produce 2 por minuto. Cuarenta por minuto es un anunciante malicioso o una inundación de RAs.

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

Otros taps `-z` de alto valor: `conv,ip`, `conv,tcp`, `http,tree`, `dns,tree`, `follow,tcp,ascii,0`, `flow,any`.

---

## 9. Router Advertisements maliciosos y DHCP malicioso

### 9.1 Por qué el RA es el filo más peligroso

Un RA (ICMPv6 tipo 134, RFC 4861) enviado a `ff02::1` desde cualquier dirección link-local hará, en un host Linux/Windows/macOS con configuración por defecto:

1. Instalar una **ruta por defecto** vía el emisor (`Router Lifetime > 0`).
2. Instalar un **prefijo on-link** y disparar la configuración de direcciones por SLAAC (flag `A`).
3. Opcionalmente fijar los flags `M`/`O`, redirigiendo al host a un servidor DHCPv6 malicioso para el DNS.
4. Tomar **precedencia sobre IPv4** para cualquier destino con registro AAAA, según RFC 6724.

En el NDP base no existe autenticación alguna. El campo `Router Lifetime` también puede fijarse en 0 para *eliminar* un router legítimo — una denegación de servicio que parece un aleteo de ruteo.

```
$ sudo tshark -i eth0 -Y 'icmpv6.type == 134' -T fields \
    -e frame.time -e eth.src -e ipv6.src \
    -e icmpv6.nd.ra.router_lifetime -e icmpv6.opt.prefix.prefix -e icmpv6.nd.ra.flag
Aug 25, 2026 11:03:02  52:54:00:aa:bb:01  fe80::5054:ff:feaa:bb01  1800  2001:db8:10:20::  0x00
Aug 25, 2026 11:04:12  52:54:00:99:99:99  fe80::5054:ff:fe99:9999  1800  2001:db8:dead::   0x80
```

Dos routers distintos, dos prefijos distintos, en un segmento con un solo gateway legítimo. El segundo es el ataque. `0x80` fija preferencia de router alta (RFC 4191) para que los hosts lo prefieran.

Enumerar routers activamente:

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

El estado resultante en la víctima:

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

`proto ra` marca rutas aprendidas desde un advertisement — buscalo con grep en cualquier incidente.

### 9.2 Comparación de defensas

| Control | Capa | Detiene RA malicioso | Detiene DHCPv6 malicioso | Detiene evasión por fragmentación RFC 7113 | Costo / advertencia |
|---|---|---|---|---|---|
| **RA Guard** (RFC 6105) en el switch | ASIC L2 | Sí en puertos no confiables | Con DHCPv6 Guard | **Solo si el switch descarta NDP fragmentado** (RFC 6980) | Requiere switches administrados; verificá que el firmware implemente RFC 6980 |
| **Filtro bridge de `nftables`** en el host/hipervisor | L2 (bridge de Linux) | Sí | Sí | Sí con `exthdr frag exists drop` | Corre donde controlás el bridge: hosts KVM, hosts de contenedores |
| **`sysctl accept_ra=0` en el host** | Pila L3 del host | Sí para ese host | No (el cliente DHCPv6 es aparte) | Sí | Lo más simple y portable; **no** elimina el estado ya instalado |
| **SEND** (RFC 3971, CGA) | Criptografía L3 | Sí, criptográficamente | No | Sí | Prácticamente no desplegado; sin soporte en sistemas operativos mayoritarios |
| **NDPMon / addrwatch / ramond** | Detección | Detecta; `ramond` además puede contraatacar | Detecta | Sí (ve paquetes reensamblados) | Detección, no prevención. Te compra la alerta |
| **`ip6tables`/`nft` en la tabla `inet` del host** | Filtro L3 del host | Sí | Sí | Sí | Cuidado: descartar *todo* ICMPv6 rompe PMTUD y el propio NDP |

**Superponelas.** Un switch administrado con RA Guard, más `accept_ra=0` en cada servidor, más NDPMon como el cable-trampa que te avisa que hubo un intento.

### 9.3 Fortalecimiento del lado del host

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

Tres trampas que vale la pena memorizar:

- `net.ipv6.conf.all.*` no es un fijador global para las opciones de RA. Para la mayoría de las perillas `accept_ra_*` el kernel usa el valor **por interfaz**; `all` se combina solo para algunas. Verificá siempre con `sysctl net.ipv6.conf.<iface>.accept_ra`, nunca solo con `all`.
- Fijar `net.ipv6.conf.all.forwarding = 1` (todo nodo de Kubernetes, todo router) hace que el kernel **ignore los RAs por completo** salvo que `accept_ra = 2`. Así que en un router, `accept_ra = 0` es redundante; en un router que *necesita* RAs upstream, hay que poner `2`, y eso reabre la exposición en toda interfaz a la que se aplique.
- `accept_ra = 0` impide *nuevo* aprendizaje. No borra la ruta por defecto envenenada ni la dirección SLAAC ya instaladas (ver §10.4 para el runbook de limpieza).

### 9.4 RA Guard / DHCP Guard con `nftables` en un bridge de Linux

Este es el punto de aplicación en un hipervisor KVM o host de contenedores, donde sos dueño de `br0` y de cada tap `vnetN`/`vethN`.

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

`counter packets 7` en la regla de RA es el incidente: siete advertisements maliciosos fueron descartados. Enviá esos contadores a Prometheus vía el colector textfile de `node_exporter` o `nftables_exporter`.

```
$ sudo journalctl -k -g RAGUARD --since "1 hour ago" -o short-iso | head -3
2026-08-25T11:04:12-03:00 kvm-07 kernel: RAGUARD-RA IN=vnet7 OUT=br0 MAC=33:33:00:00:00:01:52:54:00:99:99:99:86:dd SRC=fe80::5054:00ff:fe99:9999 DST=ff02::1 LEN=64 PROTO=ICMPv6 TYPE=134
2026-08-25T11:04:22-03:00 kvm-07 kernel: RAGUARD-RA IN=vnet7 OUT=br0 MAC=33:33:00:00:00:01:52:54:00:99:99:99:86:dd SRC=fe80::5054:00ff:fe99:9999 DST=ff02::1 LEN=64 PROTO=ICMPv6 TYPE=134
2026-08-25T11:04:31-03:00 kvm-07 kernel: RAGUARD-DHCPv4 IN=vnet7 OUT=br0 MAC=ff:ff:ff:ff:ff:ff:52:54:00:99:99:99:08:00 SRC=10.20.30.66 DST=255.255.255.255 PROTO=UDP SPT=67 DPT=68
```

`IN=vnet7` identifica el tap ofensor, que mapea directamente a una VM o contenedor. Ese es todo el punto de aplicar en L2 en lugar de en la víctima.

El equivalente en `ebtables` (heredado, todavía examinable):

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

Asegurate de que el bridge no esté doblemente filtrado por las tablas de IP:

```
$ sysctl net.bridge.bridge-nf-call-iptables net.bridge.bridge-nf-call-ip6tables
net.bridge.bridge-nf-call-iptables = 0
net.bridge.bridge-nf-call-ip6tables = 0
```

### 9.5 El anunciante legítimo: `radvd`

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

### 9.6 NDPMon — el cable-trampa de NDP

NDPMon observa todo el tráfico de Neighbor Discovery contra una whitelist de routers autorizados y una base de datos de vecinos aprendida, y alerta sobre once clases de anomalía.

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

La taxonomía de alertas, que conviene conocer por nombre para el examen:

| Alerta | Significado |
|---|---|
| `new station` | Un par MAC/IPv6 no visto antes |
| `new activity` | Una estación volvió tras un largo silencio |
| `changed ethernet address` | Cambió la MAC detrás de una dirección IPv6 |
| `flip flop` | Dirección oscilando entre dos MACs — spoofing activo |
| `reused old ethernet address` | Reapareció una MAC retirada |
| `wrong couple MAC/IP` | El emparejamiento anunciado contradice la base de datos |
| `ethernet mismatch` | MAC de la cabecera L2 ≠ opción de dirección de enlace de origen del NDP |
| `IP mismatch` | Origen de la cabecera IPv6 ≠ target del NDP |
| `wrong router advertisement` | RA desde una dirección que no está en `<routers>` |
| `wrong prefix` | El RA lleva un prefijo no configurado |
| `DAD DoS` | Se responde la Duplicate Address Detection para todo — impide que cualquier host configure una dirección |

El estado vive en `/var/lib/ndpmon/neighbor_list.xml`. Cuando renumerás o reemplazás un router legítimamente, actualizá `config_ndpmon.xml` **y** limpiá la lista de vecinos, o cada host generará una alerta `changed ethernet address`.

Alternativas más livianas: `addrwatch` (salida a syslog/SQL de las asociaciones MAC↔IP), `arpwatch` (solo IPv4), `ramond` (detecta y neutraliza activamente RAs maliciosos reanunciando `Router Lifetime 0`).

### 9.7 Detección de DHCPv4 malicioso

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

**Dos respuestas en un segmento con un solo servidor DHCP es el hallazgo.** El lease corto de 10 minutos y el DNS autorreferencial son típicos de una herramienta de MITM.

Confirmá en el cable e identificá la MAC ofensora:

```
$ sudo tshark -i eth0 -Y 'dhcp.type == 2' -T fields \
    -e eth.src -e ip.src -e dhcp.ip.your -e dhcp.option.dhcp_server_id -e dhcp.option.router
52:54:00:aa:bb:01  10.20.30.1     10.20.30.51    10.20.30.1     10.20.30.1
52:54:00:99:99:99  192.168.99.1   192.168.99.77  192.168.99.1   192.168.99.1
```

`dhcp.type == 2` es BOOTREPLY; los valores de `dhcp.option.dhcp` son `1` DISCOVER, `2` OFFER, `3` REQUEST, `5` ACK, `6` NAK.

`dhcpdump` da la misma evidencia en forma legible para humanos:

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

El DHCPv6 malicioso usa la misma lógica sobre 547→546:

```
$ sudo tshark -i eth0 -Y 'dhcpv6.msgtype == 7' -T fields \
    -e eth.src -e ipv6.src -e dhcpv6.iaaddr.ip
52:54:00:99:99:99  fe80::5054:ff:fe99:9999  2001:db8:dead::1000
```
(`dhcpv6.msgtype` 7 = REPLY, 2 = ADVERTISE.)

---

## 10. Verificación y diagnóstico de fallas

### 10.1 Qué demuestra realmente cada chequeo

| Afirmación | Comando que la demuestra | Lo que **no** demuestra |
|---|---|---|
| "RADIUS está arriba" | `radtest` devuelve Access-Accept | Que EAP funcione — `radtest` no puede hablar EAP-TLS |
| "802.1X funciona" | `eapol_test` imprime `SUCCESS` y `MPPE keys OK: 1` | Que el switch lo aplique — probá con un dispositivo sin autenticar |
| "El puerto está aplicando la política" | Enchufá un host sin configurar; no debe obtener **ningún** reenvío L2 | Que MACsec proteja las tramas después |
| "Los secretos compartidos son consistentes" | `radmin> stats detail` → `bad_authenticator = 0` | Que el secreto sea fuerte — chequeá longitud/entropía aparte |
| "No estamos expuestos a Blast-RADIUS" | `tshark -Y radius` muestra Message-Authenticator en cada paquete | Que el secreto no se haya filtrado ya |
| "RA Guard funciona" | Enviá un RA de prueba desde un puerto no confiable; el contador de `nft list table bridge raguard` se incrementa y el `ip -6 route` de la víctima no cambia | Que los RAs fragmentados estén bloqueados — probalo por separado |
| "IPv6 está deshabilitado" | `ip -6 addr show` muestra solo `::1` y link-local | Que la NIC ignore los RAs — una *dirección* deshabilitada no es una *pila* deshabilitada |
| "Nada inesperado escucha" | `ndiff baseline.xml today.xml` está vacío | Que lo que escucha esté *autorizado* — eso requiere una línea base revisada |
| "La captura está completa" | `dumpcap` reporta `dropped: 0/…` | Que hayas capturado la interfaz correcta — revisá bonds, bridges, subinterfaces VLAN |

### 10.2 Catálogo de fallas de FreeRADIUS

| Síntoma en `radiusd -X` | Causa raíz | Solución |
|---|---|---|
| `Ignoring request to auth address * port 1812 bound to server default from unknown client 10.20.0.9 port 51222` | La IP del NAS no está cubierta por ninguna sección `client` | Agregá el cliente / ampliá el prefijo. **El demonio deliberadamente no responde** — esto es una propiedad de seguridad |
| `Received packet from 10.20.0.5 with invalid Message-Authenticator! (Shared secret is incorrect.)` | Discrepancia del secreto compartido, o intento de falsificación | Compará los secretos en ambos extremos. `radmin> stats client auth <ip>` muestra el contador |
| `rlm_eap: SSL error error:0A000086:SSL routines::certificate verify failed` | El `ca_cert` del supplicant no encadena con el emisor del certificado del servidor | Empujá la CA correcta a los clientes; verificá con `openssl verify -CAfile ca.pem server.pem` |
| `eap_tls: TLS Alert read:fatal:unknown CA` | El **supplicant** rechazó el certificado del servidor | Almacén de confianza del supplicant, `domain_suffix_match`, o un certificado de servidor vencido |
| `eap_tls: TLS Alert write:fatal:certificate expired` | Certificados snake-oil incluidos (60 días de vida) o certificado de cliente vencido | Regenerá: `cd /etc/raddb/certs && make destroycerts && make` |
| `Certificate is not yet valid` | Desfase de reloj en cliente o servidor | `chronyc tracking`; imponé NTP antes de desplegar 802.1X |
| EAP entra en bucle infinito y nunca completa | Fragmento EAP más grande que el `Framed-MTU` del NAS | Bajá `fragment_size` a 1024 (o 512 para hardware terco) |
| `WARNING: Unresponsive child for request N` | Un módulo bloqueante (LDAP/SQL) está expirando | Aumentá el pool de hilos, agregá timeouts de módulo, revisá el backend |
| `radwho` no imprime nada | `rlm_radutmp` no está en la sección `accounting {}`, o no se recibió ningún Accounting-Start | Habilitá el módulo; verificá con `radclient ... acct` |
| La autenticación tiene éxito pero el puerto queda en la VLAN equivocada | Faltan los atributos `Tunnel-*` o el switch los ignora | Confirmá los tres atributos en el Access-Accept vía `tshark`; habilitá `dynamic_vlan` en el authenticator |
| Funciona con `radtest`, falla desde el switch | Dos caminos de código distintos: `radtest` usa PAP contra `localhost`; el switch usa EAP contra otra sección `client` | Reproducí con `eapol_test -a <server> -s <that client's secret>` |

Reproducí la petición exacta del NAS sin tocar el NAS:

```
$ sudo radmin -f /var/run/radiusd/radiusd.sock
radmin> debug condition '(NAS-IP-Address == 10.20.0.5)'
radmin> debug file /var/log/radius/nas-10.20.0.5.log
# ... reproduce the failure ...
radmin> debug file
radmin> quit
$ sudo grep -E 'Auth-Type|reject|SSL error' /var/log/radius/nas-10.20.0.5.log
```

### 10.3 Catálogo de fallas de `nmap`

| Síntoma | Causa | Solución |
|---|---|---|
| `All 1000 scanned ports are filtered` | El firewall del host descarta todo, o estás escaneando a través de uno | `--reason`, luego `-sA` para mapear el propio filtro |
| `Note: Host seems down` en un host que podés pingear | El echo ICMP y las sondas de descubrimiento por defecto están bloqueados | `-Pn`, o ajustá con `-PS22,443 -PA80` |
| El escaneo SYN se comporta como escaneo connect | Falta `CAP_NET_RAW` (contenedor, sin root) | Agregá `NET_RAW`, o aceptá `-sT` y anotalo en la línea base |
| El escaneo UDP tarda horas | Rate-limiting ICMP del kernel en el destino | `--max-retries 1 --host-timeout 60s`, escaneá menos puertos |
| Resultados distintos entre corridas | Rate limiting, balanceadores de carga, o un IPS con respuesta activa | Bajá `--min-rate`, usá `-T2`, correlacioná con el IDS |
| El escaneo `-6` no encuentra nada | Interfaz de origen equivocada / sin ruta | `-e eth0`, verificá `ip -6 route get <target>` |
| Script NSE no encontrado | Base de datos de scripts desactualizada | `sudo nmap --script-updatedb` |

Demostrá qué puso nmap realmente en el cable:

```
$ sudo nmap -sS -p 22 --packet-trace 10.20.30.20 2>&1 | head -8
SENT (0.0312s) ARP who-has 10.20.30.20 tell 10.20.30.90
RCVD (0.0318s) ARP reply 10.20.30.20 is-at 52:54:00:11:22:33
SENT (0.0431s) TCP 10.20.30.90:41525 > 10.20.30.20:22 S ttl=53 id=6431 iplen=44  seq=1852430812 win=1024 <mss 1460>
RCVD (0.0436s) TCP 10.20.30.20:22 > 10.20.30.90:41525 SA ttl=64 id=0 iplen=44  seq=2905172301 win=64240 <mss 1460>
```

### 10.4 Runbook de incidente — hay un RA malicioso activo en el segmento

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

El paso 6 es el que se saltea, y saltearlo significa que el host queda con MITM activo y `accept_ra=0` puesto con orgullo — una auditoría que pasa mientras el compromiso continúa.

---

## 11. Checklist de examen — términos y utilidades para 334.1

| Utilidad / archivo | Rol en una línea | Tenés que poder |
|---|---|---|
| `radiusd` / `freeradius` | El demonio de FreeRADIUS | Correr `-X` en primer plano y leer la traza de módulos |
| `radiusd.conf` | Configuración global, cadena de `$INCLUDE` | Ubicar `logdir`, `certdir`, el pool de hilos, los listeners |
| `/etc/raddb/*` | Árbol de configuración | Nombrar `clients.conf`, `mods-available/eap`, `sites-available/default`, `mods-config/files/authorize`, `certs/` |
| `radtest` | Prueba de humo PAP/CHAP/MSCHAP | Recitar el orden de los argumentos posicionales |
| `radclient` | Cliente RADIUS con atributos arbitrarios | Enviar paquetes de auth y acct, hacer pruebas de carga con `-c`/`-p` |
| `radwho` | Sesiones actuales desde `radutmp` | Saber que requiere `rlm_radutmp` en `accounting {}` |
| `radlast` | Sesiones históricas desde `radwtmp` | Saber que requiere `rlm_sradutmp` |
| `radmin` | Administración en vivo por el socket de control | `stats detail`, `show module status`, `hup`, `debug condition`, `debug file` |
| `nmap` | Auditor de red/puertos/servicios | `-sS -sT -sU -sA -sn -sV -O -6 -Pn -oA`, NSE, `ndiff` |
| `wireshark` | Analizador gráfico | Filtros de captura vs de visualización, Follow Stream, Expert Info, Statistics |
| `tshark` | Wireshark de línea de comandos | `-f` vs `-Y`, `-T fields -e`, `-z io,stat`, `-z conv`, `-z expert` |
| `tcpdump` | Captura mínima | Sintaxis BPF, `-nn -e -X -s0 -w -r` |
| `ndpmon` | Detector de anomalías NDP | Whitelist de routers en `config_ndpmon.xml`, taxonomía de alertas |

Utilidades relacionadas que el objetivo implica: `dumpcap`, `dhcpdump`, `rdisc6`/`ndisc6`, `radvd`, `eapol_test`, `wpa_supplicant`, `hostapd`, `nft`/`ebtables`, `ndiff`, `addrwatch`, `arpwatch`.

Diez hechos con peso desproporcionado en el examen:

1. La autenticación RADIUS es UDP **1812**, el accounting UDP **1813**; RadSec es TCP **2083**; los puertos heredados previos al estándar son 1645/1646.
2. Orden de argumentos de `radtest`: `user password server[:port] nas-port-number secret [ppphint] [nasname]`.
3. Un cliente RADIUS desconocido es **descartado en silencio**, no rechazado.
4. `radwho`/`radlast` dependen de que los módulos `radutmp`/`sradutmp` estén presentes en la sección de accounting.
5. Un filtro de captura (`-f`) es BPF y descarta paquetes permanentemente; un filtro de visualización (`-Y`) trabaja sobre paquetes ya capturados.
6. Un RA malicioso es **ICMPv6 tipo 134**; un Neighbor Advertisement es 136; un Redirect es 137.
7. `net.ipv6.conf.<if>.accept_ra` debe ser **2** si `forwarding=1` y aún querés aceptar RAs.
8. RA Guard (RFC 6105) se evade con fragmentación IPv6 (RFC 7113); la mitigación es descartar NDP fragmentado (RFC 6980).
9. `nmap -sA` distingue `filtered` de `unfiltered` — mapea el firewall, nunca el servicio que escucha.
10. Los puertos UDP sin respuesta se reportan como `open|filtered` porque UDP no tiene acuse negativo.

---

## 12. Referencias

**Certificación**
- LPI — Exam 303 Objectives (303-300, v3.0.0): https://www.lpi.org/our-certifications/exam-303-objectives/
- LPI — LPIC-3 Security overview: https://www.lpi.org/our-certifications/lpic-3-303-overview/

**FreeRADIUS**
- Índice de documentación de FreeRADIUS: https://www.freeradius.org/documentation/
- Referencia de configuración de FreeRADIUS 3.2: https://www.freeradius.org/documentation/freeradius-server/3.2.7/
- Wiki de FreeRADIUS (EAP, certificados, depuración): https://wiki.freeradius.org/
- Avisos de seguridad de FreeRADIUS (incl. CVE-2024-3596): https://www.freeradius.org/security/
- Divulgación de la vulnerabilidad Blast-RADIUS: https://www.blastradius.fail/
- NVD — CVE-2024-3596: https://nvd.nist.gov/vuln/detail/CVE-2024-3596

**Estándares de la IETF**
- RFC 2865 — Remote Authentication Dial In User Service (RADIUS): https://datatracker.ietf.org/doc/html/rfc2865
- RFC 2866 — RADIUS Accounting: https://datatracker.ietf.org/doc/html/rfc2866
- RFC 3579 — RADIUS Support for EAP: https://datatracker.ietf.org/doc/html/rfc3579
- RFC 3748 — Extensible Authentication Protocol (EAP): https://datatracker.ietf.org/doc/html/rfc3748
- RFC 5216 — The EAP-TLS Authentication Protocol: https://datatracker.ietf.org/doc/html/rfc5216
- RFC 9190 — EAP-TLS 1.3: https://datatracker.ietf.org/doc/html/rfc9190
- RFC 7170 — TEAP: https://datatracker.ietf.org/doc/html/rfc7170
- RFC 6614 — RADIUS over TLS (RadSec): https://datatracker.ietf.org/doc/html/rfc6614
- RFC 7360 — RADIUS over DTLS: https://datatracker.ietf.org/doc/html/rfc7360
- Grupo de trabajo RADEXT de la IETF (trabajo de deprecación y fortalecimiento de RADIUS): https://datatracker.ietf.org/wg/radext/documents/
- RFC 4861 — Neighbor Discovery for IPv6: https://datatracker.ietf.org/doc/html/rfc4861
- RFC 4862 — IPv6 Stateless Address Autoconfiguration: https://datatracker.ietf.org/doc/html/rfc4862
- RFC 4191 — Default Router Preferences and More-Specific Routes: https://datatracker.ietf.org/doc/html/rfc4191
- RFC 6724 — Default Address Selection for IPv6: https://datatracker.ietf.org/doc/html/rfc6724
- RFC 3971 — SEcure Neighbor Discovery (SEND): https://datatracker.ietf.org/doc/html/rfc3971
- RFC 6105 — IPv6 Router Advertisement Guard: https://datatracker.ietf.org/doc/html/rfc6105
- RFC 7113 — Implementation Advice for RA-Guard (evasión por fragmentación): https://datatracker.ietf.org/doc/html/rfc7113
- RFC 6980 — Security Implications of IPv6 Fragmentation with NDP: https://datatracker.ietf.org/doc/html/rfc6980
- RFC 8415 — DHCP for IPv6 (DHCPv6): https://datatracker.ietf.org/doc/html/rfc8415
- RFC 2131 — Dynamic Host Configuration Protocol: https://datatracker.ietf.org/doc/html/rfc2131

**IEEE**
- IEEE 802.1X-2020 — Port-Based Network Access Control: https://standards.ieee.org/ieee/802.1X/7345/
- IEEE 802.1AE — MAC Security (MACsec): https://standards.ieee.org/ieee/802.1AE/7154/

**Nmap**
- Guía de referencia de Nmap (página de manual): https://nmap.org/book/man.html
- Técnicas de escaneo de puertos: https://nmap.org/book/man-port-scanning-techniques.html
- Descubrimiento de hosts: https://nmap.org/book/man-host-discovery.html
- Documentación de scripts NSE: https://nmap.org/nsedoc/
- Ndiff: https://nmap.org/ndiff/
- Uso legal y ético de Nmap: https://nmap.org/book/legal-issues.html

**Wireshark / captura**
- Guía de usuario de Wireshark: https://www.wireshark.org/docs/wsug_html_chunked/
- Página de manual de `tshark`: https://www.wireshark.org/docs/man-pages/tshark.html
- Página de manual de `dumpcap`: https://www.wireshark.org/docs/man-pages/dumpcap.html
- Referencia de filtros de visualización: https://www.wireshark.org/docs/dfref/
- Wiki CaptureFilters (sintaxis BPF): https://wiki.wireshark.org/CaptureFilters
- `pcap-filter(7)` — gramática BPF: https://www.tcpdump.org/manpages/pcap-filter.7.html
- Página de manual de `tcpdump`: https://www.tcpdump.org/manpages/tcpdump.1.html

**Redes y filtrado en Linux**
- Documentación de sysctl de IP del kernel: https://docs.kernel.org/networking/ip-sysctl.html
- Wiki de nftables: https://wiki.nftables.org/wiki-nftables/index.php/Main_Page
- Filtrado de la familia bridge en nftables: https://wiki.nftables.org/wiki-nftables/index.php/Bridge_filtering
- Página del proyecto ebtables/nftables: https://netfilter.org/projects/ebtables/
- Documentación de `hostapd` / `wpa_supplicant`: https://w1.fi/hostapd/ y https://w1.fi/wpa_supplicant/
- Plantilla de `wpa_supplicant.conf`: https://w1.fi/cgit/hostap/plain/wpa_supplicant/wpa_supplicant.conf
- MACsec en Linux (`ip-macsec(8)`): https://man7.org/linux/man-pages/man8/ip-macsec.8.html

**Monitoreo de NDP en IPv6**
- Proyecto NDPMon: https://ndpmon.sourceforge.net/
- Kit de herramientas `ndisc6` / `rdisc6`: https://www.remlab.net/ndisc6/
- Proyecto y páginas de manual de `radvd`: https://radvd.litech.org/
- `addrwatch`: https://github.com/fln/addrwatch