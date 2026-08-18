# 331.2 — X.509 Certificates for Encryption, Signing and Authentication

**Certification:** LPIC-3 Security — exam 303-300, version 3.0.0
**Topic weight:** 6.67
**Prerequisite:** 331.1 (X.509, PKI, CA operation, CRL/OCSP issuance)

---

## 0. Objective map

331.1 taught you how to *make* certificates. 331.2 is about *consuming* them inside a live protocol — TLS — and the only server the exam examines is Apache HTTPD with `mod_ssl`. This table is the contract between the LPI objective text and what you actually have to be able to type.

| Knowledge area (LPI) | Where it lives in production | Primary tooling |
|---|---|---|
| SSL, TLS and protocol versions | `SSLProtocol`, OpenSSL `MinProtocol` | `openssl s_client -tls1_2`, `nmap --script ssl-enum-ciphers` |
| Transport-layer threats (MITM) | HSTS, chain validation, CT, CAA, pinning | `openssl s_client`, `curl -v` |
| Intermediate certificate authorities | chain served by the server, not by the client | `openssl verify -untrusted` |
| Cipher configuration | `SSLCipherSuite`, `SSLHonorCipherOrder`, `SSLOpenSSLConfCmd` | `openssl ciphers -v` |
| HTTPS with `mod_ssl`, incl. SNI and HSTS | `<VirtualHost *:443>`, `Header always set` | `apachectl -S`, `-t` |
| Client certificate authentication | `SSLVerifyClient`, `SSLVerifyDepth`, `SSLCACertificateFile` | `openssl s_client -cert/-key` |
| OCSP stapling | `SSLUseStapling`, `SSLStaplingCache` | `openssl s_client -status` |
| OpenSSL client/server tests | `s_client`, `s_server`, `x509`, `verify`, `ocsp` | — |

**Terms and utilities you are expected to recognise:** `httpd.conf`, `mod_ssl`, `openssl`, intermediate CAs, cipher configuration (no cipher-internal detail required).

---

## 1. The architectural problem

You run a platform with ~200 HTTP services. Three requirements arrive in the same quarter:

1. **Regulatory:** all traffic encrypted in transit, including east-west inside the cluster, with auditable proof of *which* service talked to which.
2. **Operational:** a wildcard certificate was compromised last year; the incident response took 9 hours because nobody knew which of 200 services carried it. Never again.
3. **Availability:** a certificate expiry at 03:00 UTC took down checkout for 40 minutes. The monitoring watched HTTP 200s, and the LB kept returning 200 on a stale cached page while every fresh TLS handshake failed.

Every one of those is an X.509 problem, and each maps to a different *use* of the certificate — which is exactly what the objective title enumerates:

| Use | What the certificate does | Where in TLS |
|---|---|---|
| **Encryption** | its public key encrypts a secret in transit | *only* TLS ≤ 1.2 with static RSA key transport (`TLS_RSA_WITH_*`) — removed in TLS 1.3 |
| **Signing** | its private key signs handshake material, proving liveness | `ServerKeyExchange` (TLS 1.2 ECDHE/DHE), `CertificateVerify` (TLS 1.3) |
| **Authentication** | the chain binds the key to a name a relying party trusts | path validation (RFC 5280) + name check (RFC 6125) |

The single most common misconception in this topic: *"the certificate encrypts the traffic."* In a modern TLS 1.3 handshake the certificate **never encrypts anything**. Key agreement is (EC)DHE; the certificate exists solely so the client can prove that the party doing the Diffie–Hellman is the one that owns the name. If you remember one sentence from 331.2, make it that one — it explains why RSA vs ECDSA key size affects *handshake CPU*, not *bulk cipher strength*, and why forward secrecy is possible at all.

### 1.1 Where you terminate TLS is an architecture decision

| Termination point | mTLS possible end-to-end? | Cert count | Blast radius | Observability | Typical failure |
|---|---|---|---|---|---|
| Edge LB / CDN only | No — client identity dies at the edge | 1 (wildcard) | Enormous: one key, whole estate | Full L7 logs at edge | Wildcard compromise = fleet-wide rotation |
| Ingress controller, re-encrypt to backend | Partial (LB identity, not client) | 1 edge + N internal | Medium | L7 at ingress | Two trust stores to keep in sync |
| **Ingress SSL passthrough → `mod_ssl` in the pod** | **Yes** | N leaf certs | Small, per-service | L4 at ingress, L7 in pod | Ingress cannot route by path, only by SNI |
| Service mesh sidecar (SPIFFE) | Yes, automatic | N (short-lived) | Tiny (1 h certs) | Mesh telemetry | Mesh is a whole other control plane |
| In-process TLS in the app | Yes | N | Small | App-dependent | Every language reimplements verification badly |

For the exam, and for the lab in §12, the interesting row is the third: SNI-routed passthrough with `mod_ssl` doing both server authentication and client authentication. It is the only shape where all of 331.2's directives are simultaneously load-bearing.

---

## 2. Protocol mechanics

### 2.1 Versions

| Version | RFC | Year | Status today | Notes for the exam |
|---|---|---|---|---|
| SSL 2.0 | — | 1995 | Prohibited (RFC 6176) | No handshake integrity; not compiled into modern OpenSSL |
| SSL 3.0 | RFC 6101 | 1996 | Prohibited (RFC 7568) | POODLE; the origin of the `SSLv3` token in configs |
| TLS 1.0 | RFC 2246 | 1999 | Deprecated (RFC 8996) | BEAST; PCI DSS removed it in 2018 |
| TLS 1.1 | RFC 4346 | 2006 | Deprecated (RFC 8996) | Explicit IV; no other reason to exist |
| **TLS 1.2** | RFC 5246 | 2008 | Supported | AEAD, SHA-256 PRF, `signature_algorithms` |
| **TLS 1.3** | RFC 8446 | 2018 | Preferred | 1-RTT, encrypted handshake, PFS mandatory |

`SSLProtocol` uses the historical token names regardless of what the wire calls them. `SSLv23` is not a version — it is OpenSSL's "negotiate the best mutually supported version" method, which is why `all` behaves the way it does.

```apache
# Both forms are legal; the subtractive form is the idiomatic one.
SSLProtocol all -SSLv3 -TLSv1 -TLSv1.1
# Equivalent, and much harder to get wrong when a new version ships:
SSLProtocol -all +TLSv1.2 +TLSv1.3
```

> Trap: `SSLProtocol` in a `<VirtualHost>` applies to the whole *connection*, and the connection's protocol is chosen before SNI has selected a vhost in some code paths. Per-vhost `SSLProtocol` differences on the same IP:port are unreliable. Set protocol policy globally; vary certificates per vhost, not protocol versions.

### 2.2 Handshake flow, and exactly where the certificate appears

**TLS 1.2, `ECDHE_RSA_WITH_AES_128_GCM_SHA256`:**

```
Client                                               Server
ClientHello (versions, cipher list, SNI, sig_algs)  →
                                     ← ServerHello (chosen suite)
                                     ← Certificate      [leaf + intermediates]
                                     ← ServerKeyExchange[EC params, SIGNED with cert key]
                                     ← CertificateRequest    (only if client auth)
                                     ← ServerHelloDone
Certificate            (only if client auth)        →
ClientKeyExchange      [client EC pubkey]           →
CertificateVerify      [SIGNED with client key]     →
ChangeCipherSpec, Finished                          →
                                     ← ChangeCipherSpec, Finished
        ---- application data ----     2 RTT
```

**TLS 1.3:**

```
Client                                               Server
ClientHello (key_share, sig_algs, SNI, ALPN)        →
                                     ← ServerHello (key_share)
                            {EncryptedExtensions}
                            {CertificateRequest}      (only if client auth)
                            {Certificate}             ← ENCRYPTED
                            {CertificateVerify}       ← signature over transcript
                            {Finished}
{Certificate}, {CertificateVerify}   (client auth)  →
{Finished}                                          →
        ---- application data ----     1 RTT
```

Three consequences you will be asked about, directly or indirectly:

- **The server certificate is encrypted in TLS 1.3.** A passive observer sees the SNI in the ClientHello but not the certificate. Any monitoring or IDS that identified services by scraping the certificate off the wire broke the day you enabled TLS 1.3. (Encrypted Client Hello, RFC 9540 / draft-ietf-tls-esni, closes the SNI hole too — not on the 303-300 objectives, but it is the reason SNI-based routing has a shelf life.)
- **Renegotiation does not exist in TLS 1.3.** `openssl s_client` printing `Secure Renegotiation IS NOT supported` against a TLS 1.3 server is *correct output*, not a finding. This is the single most frequent false positive in vulnerability-scanner reports.
- **Per-directory client authentication cannot use renegotiation.** See §9.3.

### 2.3 Cipher suite anatomy

```
TLS 1.2:  ECDHE - ECDSA - WITH - AES_128_GCM - SHA256
          │       │             │              └── PRF hash / MAC
          │       │             └── bulk AEAD
          │       └── certificate/authentication algorithm
          └── key exchange

TLS 1.3:  TLS_AES_128_GCM_SHA256
          └── AEAD + hash ONLY. Key exchange and authentication
              are negotiated separately (supported_groups, signature_algorithms).
```

That split is why `SSLCipherSuite` grew a protocol argument in httpd 2.4.36:

```apache
SSLCipherSuite       ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:...
SSLCipherSuite TLSv1.3 TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:TLS_AES_128_GCM_SHA256
```

The first line cannot restrict TLS 1.3 and the second cannot restrict TLS 1.2. Configuring one and expecting it to cover both is a classic misconfiguration.

| Policy | `SSLProtocol` | Suites | Client floor | Use when |
|---|---|---|---|---|
| Modern | `-all +TLSv1.3` | TLS 1.3 defaults only | Firefox 63, Chrome 70, OpenSSL 1.1.1 | Internal APIs, new products |
| Intermediate | `all -SSLv3 -TLSv1 -TLSv1.1` | ECDHE+AEAD, no RSA kx | Firefox 27, Android 4.4.2, Java 8u31 | Public web, default choice |
| Old | `all -SSLv3` | + CBC, + RSA kx | IE8/XP, Java 6 | Only with a documented expiry date |

`SSLHonorCipherOrder on` makes the server's list authoritative. Mozilla's current guidance is `off` for Intermediate, because every remaining suite is safe and letting the client pick lets a phone choose ChaCha20 (fast without AES-NI) over AES-GCM. Turn it `on` only when your list is deliberately ordered for a reason you can articulate.

### 2.4 Groups and signature algorithms

`mod_ssl` exposes OpenSSL's config commands directly:

```apache
SSLOpenSSLConfCmd Groups           X25519:secp256r1:secp384r1
SSLOpenSSLConfCmd SignatureAlgorithms ECDSA+SHA256:ECDSA+SHA384:RSA-PSS+SHA256:RSA+SHA256
SSLOpenSSLConfCmd MinProtocol      TLSv1.2
SSLOpenSSLConfCmd Options          -SessionTicket
```

`Curves` is the pre-1.1.1 spelling of `Groups`; both are accepted. Note that removing `secp256r1` from `Groups` breaks *every* client that only offers P-256 in its `key_share`, and the failure is `no shared group` — an alert 40, not a certificate error. Group misconfiguration masquerades as a cipher problem.

---

## 3. Threat model of the transport layer

| Threat | Mechanism | What actually stops it | Config knob |
|---|---|---|---|
| **On-path MITM (active)** | Attacker terminates TLS with their own cert | Chain validation + name check on the client | client trust store; `SSLProxyVerify` when *you* are the client |
| **Rogue / coerced CA** | Valid chain to a CA you trust, wrong subject | Certificate Transparency, CAA records, name constraints on private CAs | DNS `CAA`, `nameConstraints` in the intermediate |
| **SSL stripping** | Downgrade `https://` to `http://` before TLS starts | **HSTS**, ideally preloaded | `Strict-Transport-Security` |
| **Version downgrade** | Forced retry at a lower version | `TLS_FALLBACK_SCSV` (RFC 7507); TLS 1.3 downgrade sentinel in the server random | automatic in OpenSSL ≥ 1.0.1j |
| **Insecure renegotiation** | Prefix injection (CVE-2009-3555) | RFC 5746 secure renegotiation | `SSLInsecureRenegotiation off` (default) |
| **Compression oracle (CRIME)** | TLS-level compression leaks secrets | Disable TLS compression | `SSLCompression off` (default since 2.4.3) |
| **BREACH** | HTTP-level gzip + reflected secret | Mask CSRF tokens; do not gzip secret-bearing responses | application-level |
| **POODLE / Lucky13** | CBC padding oracle | Drop SSLv3, prefer AEAD | `SSLProtocol`, `SSLCipherSuite` |
| **SWEET32** | 64-bit block cipher birthday bound | Remove 3DES | cipher string `!3DES` |
| **FREAK / Logjam** | Export-grade RSA/DH forced | Remove EXPORT, DH ≥ 2048 | `!EXP`, `SSLOpenSSLConfCmd DHParameters` |
| **ROBOT** | RSA PKCS#1 v1.5 padding oracle | Remove static-RSA key exchange | `!kRSA` |
| **Heartbleed** | OpenSSL heartbeat OOB read | Patch; **rotate the key**, not just the cert | package hygiene |
| **Expired / revoked cert accepted** | Client skips revocation check (soft-fail) | **OCSP stapling** + `status_request` must-staple | `SSLUseStapling` |
| **Stolen server key** | Attacker decrypts recorded traffic | Forward secrecy: ECDHE only | `!kRSA` |

Two of these deserve their own sections because they *are* explicit objective bullets: HSTS (§8) and OCSP stapling (§10).

### 3.1 Why revocation is the weak link

The chain of custody for "this certificate is no longer valid" is genuinely broken in the public web PKI:

| Mechanism | Who fetches | Privacy | Latency cost | Failure mode |
|---|---|---|---|---|
| CRL | client → CA | leaks nothing per-cert | large download, cached | browsers largely stopped |
| OCSP (client-driven) | client → CA responder | **CA learns every site you visit** | +1 RTT + DNS on first visit | soft-fail: responder down ⇒ accept |
| **OCSP stapling** | **server → CA, periodically** | none | zero for the client | server has a stale/absent staple |
| Must-staple (RFC 7633) | server, enforced | none | zero | **hard-fail**: no staple ⇒ site down |
| CRLite / CRLSets | browser vendor push | none | zero | vendor-specific, not yours to operate |

Stapling moves the fetch from N clients to 1 server, which is why it is on the objectives. Must-staple converts a security soft-fail into an availability hard-fail; deploy it only with monitoring that alerts on staple age.

---

## 4. The chain of trust and intermediate CAs

### 4.1 Why intermediates exist

A root CA's private key is the crown jewel: it lives in an HSM, in a safe, powered off, with ceremony logs. It cannot be online signing 40 000 certificates a day. So it signs exactly one thing — an **intermediate CA** — and the intermediate does the daily work.

Operational consequences, all of which show up in incidents:

- If the intermediate is compromised, you revoke *it*, not the root. Clients keep trusting the root; you issue a new intermediate. The blast radius is bounded by the intermediate's issuance, not by the whole trust store.
- Root certificates propagate into client trust stores over *years*. Intermediates propagate in a single server reload. That asymmetry is the entire design.
- `pathlen:0` on the intermediate means it can issue end-entity certificates but not further CAs. Always set it.
- `nameConstraints` on a private intermediate is the highest-leverage control in this whole topic: an intermediate constrained to `permitted;DNS:example.internal` cannot mint a valid `google.com`, even if its key is stolen — provided the validating client enforces name constraints (OpenSSL, NSS, and Go do; some embedded stacks do not).

### 4.2 Chain building and path validation

Validation (RFC 5280 §6) walks from the leaf to a trust anchor, checking at each link:

1. `Issuer` of child == `Subject` of parent (byte-comparable DN).
2. Signature on child verifies with parent's public key.
3. `Authority Key Identifier` of child matches `Subject Key Identifier` of parent (the fast path; the DN match is the normative one).
4. Parent has `basicConstraints: CA:TRUE` and `keyUsage: keyCertSign`.
5. `pathlen` not exceeded; validity windows nested; name constraints satisfied.
6. Leaf's `extendedKeyUsage` includes `serverAuth`; the requested hostname matches a `subjectAltName` **dNSName** (RFC 6125 — the `CN` fallback was removed by Chrome in 58 and by OpenSSL's default host check policy).

**The server's job is to send the leaf plus every intermediate, in order, and *not* the root.** Sending the root wastes bytes on every handshake; omitting an intermediate produces the single most common TLS failure in the world:

```
verify error:num=20:unable to get local issuer certificate
```

Note the asymmetry that makes this so pernicious: browsers often recover via **AIA chasing** (they fetch the missing intermediate from the `caIssuers` URL in the leaf's Authority Information Access extension). `openssl s_client`, Java, Go, and most language HTTP clients do **not**. So the site "works in my browser" and fails in every service-to-service call. Always test with `openssl s_client`, never with a browser.

### 4.3 Which file goes in which directive

| Directive | Contains | Direction | Notes |
|---|---|---|---|
| `SSLCertificateFile` | leaf cert; since 2.4.8 may also hold the chain **and** the key | server → client | May be repeated for dual RSA + ECDSA certs |
| `SSLCertificateKeyFile` | the private key | never sent | Omit only if the key is inside `SSLCertificateFile` |
| `SSLCertificateChainFile` | intermediates (no leaf, no root) | server → client | **Deprecated in 2.4.8** — concatenate into `SSLCertificateFile` |
| `SSLCACertificateFile` | trust anchors for **verifying clients** | never sent as chain | A single concatenated PEM |
| `SSLCACertificatePath` | same, one cert per file | — | Requires hash symlinks: `openssl rehash <dir>` |
| `SSLCADNRequestFile` / `Path` | CA names advertised in `CertificateRequest` | server → client | Decouples "what I trust" from "what I advertise" |
| `SSLCARevocationFile` / `Path` | CRLs for client certs | — | Needs `SSLCARevocationCheck` |
| `SSLProxyCACertificateFile` | trust anchors when httpd is the **client** | — | Completely separate trust store |

Concatenation order in `SSLCertificateFile` is **leaf first, then each issuer in turn**. Reversed order makes some clients fail and others succeed, which is the worst possible debugging experience.

### 4.4 The cross-signing lesson

Two production outages that every platform engineer should know, because both are pure chain-building failures:

- **AddTrust External CA Root, 30 May 2020.** The *root* expired. Servers were still stapling a chain that terminated at it. Modern clients (which had the newer `USERTrust` root and could build an alternative path) were fine; OpenSSL 1.0.x and older stacks were not — because OpenSSL 1.0.x builds exactly one chain and fails, while OpenSSL 1.1.0+ retries alternative paths.
- **DST Root CA X3, 30 September 2021.** Let's Encrypt's cross-sign expired. Android 7.0 and earlier survived (they ignore the notAfter of the trust anchor); OpenSSL 1.0.2 died. The fix was to *shorten* the served chain, dropping the cross-sign.

Takeaway: **the chain you serve is a runtime configuration decision, not a property of your certificate.** You can and sometimes must serve a different chain than your CA hands you.

---

## 5. Building the PKI (complete, reproducible)

Everything below runs on a stock RHEL 9 / Debian 12 box with `openssl` 3.x. Paths are absolute so the configs are copy-pasteable.

### 5.1 Layout

```bash
$ sudo install -d -m 0755 /opt/pki/{root,sub}/{certs,db} \
                          /opt/pki/{root,sub}/private
$ sudo chmod 0700 /opt/pki/root/private /opt/pki/sub/private
$ for ca in root sub; do
    sudo touch /opt/pki/$ca/db/index
    sudo openssl rand -hex 16 | sudo tee /opt/pki/$ca/db/serial >/dev/null
    echo 1001 | sudo tee /opt/pki/$ca/db/crlnumber >/dev/null
  done
```

### 5.2 `/opt/pki/root/openssl.cnf` — complete

```ini
[ default ]
name                    = root-ca
domain_suffix           = example.net
aia_url                 = http://pki.$domain_suffix/$name.crt
crl_url                 = http://pki.$domain_suffix/$name.crl
default_ca              = ca_default
name_opt                = utf8,esc_ctrl,multiline,lname,align

[ ca_dn ]
countryName             = "AR"
organizationName        = "Example Networks"
commonName              = "Example Networks Root CA R1"

[ ca_default ]
home                    = /opt/pki/root
database                = $home/db/index
serial                  = $home/db/serial
crlnumber               = $home/db/crlnumber
certificate             = $home/$name.crt
private_key             = $home/private/$name.key
new_certs_dir           = $home/certs
unique_subject          = no
copy_extensions         = none
default_days            = 3652
default_crl_days        = 180
default_md              = sha256
policy                  = policy_c_o_match

[ policy_c_o_match ]
countryName             = match
stateOrProvinceName     = optional
organizationName        = match
organizationalUnitName  = optional
commonName              = supplied
emailAddress            = optional

[ req ]
default_bits            = 4096
encrypt_key             = yes
default_md              = sha256
utf8                    = yes
string_mask             = utf8only
prompt                  = no
distinguished_name      = ca_dn
req_extensions          = ca_ext

[ ca_ext ]
basicConstraints        = critical,CA:true
keyUsage                = critical,keyCertSign,cRLSign
subjectKeyIdentifier    = hash

[ sub_ca_ext ]
authorityInfoAccess     = @issuer_info
authorityKeyIdentifier  = keyid:always
basicConstraints        = critical,CA:true,pathlen:0
crlDistributionPoints   = @crl_info
extendedKeyUsage        = clientAuth,serverAuth
keyUsage                = critical,keyCertSign,cRLSign
nameConstraints         = @name_constraints
subjectKeyIdentifier    = hash

[ crl_info ]
URI.0                   = $crl_url

[ issuer_info ]
caIssuers;URI.0         = $aia_url
OCSP;URI.0              = http://ocsp.$domain_suffix

[ name_constraints ]
permitted;DNS.0         = example.net
permitted;DNS.1         = example.internal
excluded;IP.0           = 0.0.0.0/0.0.0.0
excluded;IP.1           = 0:0:0:0:0:0:0:0/0:0:0:0:0:0:0:0
```

The `excluded;IP` pair is not decoration: without it, a name-constrained CA is unconstrained for IP SANs, because an absent constraint means "anything permitted" for that name type.

### 5.3 `/opt/pki/sub/openssl.cnf` — complete

```ini
[ default ]
name                    = sub-ca
domain_suffix           = example.net
aia_url                 = http://pki.$domain_suffix/$name.crt
crl_url                 = http://pki.$domain_suffix/$name.crl
ocsp_url                = http://ocsp.$domain_suffix
default_ca              = ca_default
name_opt                = utf8,esc_ctrl,multiline,lname,align

[ ca_dn ]
countryName             = "AR"
organizationName        = "Example Networks"
commonName              = "Example Networks TLS Issuing CA I1"

[ ca_default ]
home                    = /opt/pki/sub
database                = $home/db/index
serial                  = $home/db/serial
crlnumber               = $home/db/crlnumber
certificate             = $home/$name.crt
private_key             = $home/private/$name.key
new_certs_dir           = $home/certs
unique_subject          = no
copy_extensions         = copy
default_days            = 90
default_crl_days        = 7
default_md              = sha256
policy                  = policy_c_o_match

[ policy_c_o_match ]
countryName             = match
stateOrProvinceName     = optional
organizationName        = match
organizationalUnitName  = optional
commonName              = supplied
emailAddress            = optional

[ req ]
default_bits            = 3072
encrypt_key             = yes
default_md              = sha256
utf8                    = yes
string_mask             = utf8only
prompt                  = no
distinguished_name      = ca_dn
req_extensions          = ca_ext

[ ca_ext ]
basicConstraints        = critical,CA:true
keyUsage                = critical,keyCertSign,cRLSign
subjectKeyIdentifier    = hash

[ server_ext ]
authorityInfoAccess     = @issuer_info
authorityKeyIdentifier  = keyid:always
basicConstraints        = critical,CA:false
crlDistributionPoints   = @crl_info
extendedKeyUsage        = serverAuth,clientAuth
keyUsage                = critical,digitalSignature,keyEncipherment
subjectKeyIdentifier    = hash

[ server_ec_ext ]
authorityInfoAccess     = @issuer_info
authorityKeyIdentifier  = keyid:always
basicConstraints        = critical,CA:false
crlDistributionPoints   = @crl_info
extendedKeyUsage        = serverAuth
keyUsage                = critical,digitalSignature
subjectKeyIdentifier    = hash

[ client_ext ]
authorityInfoAccess     = @issuer_info
authorityKeyIdentifier  = keyid:always
basicConstraints        = critical,CA:false
crlDistributionPoints   = @crl_info
extendedKeyUsage        = clientAuth
keyUsage                = critical,digitalSignature
subjectKeyIdentifier    = hash

[ ocsp_ext ]
authorityKeyIdentifier  = keyid:always
basicConstraints        = critical,CA:false
extendedKeyUsage        = critical,OCSPSigning
keyUsage                = critical,digitalSignature
noCheck                 = yes
subjectKeyIdentifier    = hash

[ crl_info ]
URI.0                   = $crl_url

[ issuer_info ]
caIssuers;URI.0         = $aia_url
OCSP;URI.0              = $ocsp_url
```

`copy_extensions = copy` is what lets a CSR's `subjectAltName` survive into the issued certificate. It is also a footgun — a CSR could ask for `basicConstraints:CA:true`. The `[ server_ext ]` section overrides `basicConstraints` explicitly, which is why it is safe *here*. Never enable `copy_extensions` without pinning the critical extensions in the profile.

`noCheck = yes` on the OCSP responder certificate is `id-pkix-ocsp-nocheck`: it tells clients not to try to check the responder's own revocation status, which would be an infinite regress.

### 5.4 Root CA

```bash
$ cd /opt/pki/root
$ sudo openssl req -new -config openssl.cnf -out root-ca.csr \
      -keyout private/root-ca.key
Enter PEM pass phrase:
Verifying - Enter PEM pass phrase:
-----

$ sudo openssl ca -selfsign -config openssl.cnf -in root-ca.csr \
      -out root-ca.crt -extensions ca_ext -days 3652 -batch
Using configuration from openssl.cnf
Enter pass phrase for /opt/pki/root/private/root-ca.key:
Check that the request matches the signature
Signature ok
Certificate Details:
        Serial Number:
            5c:3f:1a:9e:44:7b:20:d1:8f:6a:cc:03:19:be:77:52
        Validity
            Not Before: Aug 18 09:00:11 2026 GMT
            Not After : Aug 16 09:00:11 2036 GMT
        Subject:
            countryName               = AR
            organizationName          = Example Networks
            commonName                = Example Networks Root CA R1
        X509v3 extensions:
            X509v3 Basic Constraints: critical
                CA:TRUE
            X509v3 Key Usage: critical
                Certificate Sign, CRL Sign
            X509v3 Subject Key Identifier:
                A4:1B:0E:C7:52:9D:6F:33:8A:11:CE:04:77:B9:20:E5:6C:D1:3F:88
Certificate is to be certified until Aug 16 09:00:11 2036 GMT (3652 days)
Write out database with 1 new entries
Database updated
```

### 5.5 Intermediate CA

```bash
$ cd /opt/pki/sub
$ sudo openssl req -new -config openssl.cnf -out sub-ca.csr \
      -keyout private/sub-ca.key
Enter PEM pass phrase:
Verifying - Enter PEM pass phrase:
-----

$ sudo openssl ca -config /opt/pki/root/openssl.cnf \
      -in sub-ca.csr -out sub-ca.crt \
      -extensions sub_ca_ext -days 1826 -batch
Using configuration from /opt/pki/root/openssl.cnf
Enter pass phrase for /opt/pki/root/private/root-ca.key:
Check that the request matches the signature
Signature ok
Certificate Details:
        Serial Number:
            5c:3f:1a:9e:44:7b:20:d1:8f:6a:cc:03:19:be:77:53
        Subject:
            countryName               = AR
            organizationName          = Example Networks
            commonName                = Example Networks TLS Issuing CA I1
        X509v3 extensions:
            X509v3 Basic Constraints: critical
                CA:TRUE, pathlen:0
            X509v3 Name Constraints:
                Permitted:
                  DNS:example.net
                  DNS:example.internal
                Excluded:
                  IP:0.0.0.0/0.0.0.0
                  IP:0:0:0:0:0:0:0:0/0:0:0:0:0:0:0:0
            X509v3 Key Usage: critical
                Certificate Sign, CRL Sign
            X509v3 Extended Key Usage:
                TLS Web Client Authentication, TLS Web Server Authentication
Certificate is to be certified until Aug 17 09:03:42 2031 GMT (1826 days)
Write out database with 1 new entries
Database updated
```

### 5.6 Server certificate with SANs

```bash
$ sudo openssl genpkey -algorithm EC \
      -pkeyopt ec_paramgen_curve:P-256 \
      -out /etc/pki/example/private/www.key
$ sudo chmod 0600 /etc/pki/example/private/www.key

$ cat > /tmp/www.cnf <<'EOF'
[ req ]
prompt             = no
distinguished_name = dn
req_extensions     = san

[ dn ]
C  = AR
O  = Example Networks
CN = www.example.net

[ san ]
subjectAltName = DNS:www.example.net, DNS:example.net, DNS:static.example.net
EOF

$ sudo openssl req -new -config /tmp/www.cnf \
      -key /etc/pki/example/private/www.key -out /tmp/www.csr

$ sudo openssl ca -config /opt/pki/sub/openssl.cnf \
      -in /tmp/www.csr -out /etc/pki/example/certs/www.crt \
      -extensions server_ec_ext -days 90 -batch
Using configuration from /opt/pki/sub/openssl.cnf
Enter pass phrase for /opt/pki/sub/private/sub-ca.key:
Check that the request matches the signature
Signature ok
Certificate Details:
        Subject:
            countryName               = AR
            organizationName          = Example Networks
            commonName                = www.example.net
        X509v3 extensions:
            X509v3 Subject Alternative Name:
                DNS:www.example.net, DNS:example.net, DNS:static.example.net
            X509v3 Extended Key Usage:
                TLS Web Server Authentication
            Authority Information Access:
                CA Issuers - URI:http://pki.example.net/sub-ca.crt
                OCSP - URI:http://ocsp.example.net
Certificate is to be certified until Nov 16 09:07:55 2026 GMT (90 days)
Write out database with 1 new entries
Database updated
```

**Build the served chain — leaf first, root excluded:**

```bash
$ sudo sh -c 'cat /etc/pki/example/certs/www.crt /opt/pki/sub/sub-ca.crt \
    > /etc/pki/example/certs/www-fullchain.crt'
$ sudo cp /opt/pki/root/root-ca.crt /etc/pki/example/root-ca.crt
```

### 5.7 Client certificate

```bash
$ openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 \
      -out alice.key
$ openssl req -new -key alice.key -out alice.csr \
      -subj "/C=AR/O=Example Networks/OU=platform/CN=alice@example.net"
$ sudo openssl ca -config /opt/pki/sub/openssl.cnf \
      -in alice.csr -out alice.crt -extensions client_ext -days 30 -batch
```

Bundle as PKCS#12 for browsers and for `curl --cert-type P12`:

```bash
$ openssl pkcs12 -export -out alice.p12 \
      -inkey alice.key -in alice.crt \
      -certfile /opt/pki/sub/sub-ca.crt \
      -name "alice@example.net"
Enter Export Password:
Verifying - Enter Export Password:
```

### 5.8 Verify before you deploy

```bash
$ openssl verify -CAfile /opt/pki/root/root-ca.crt \
      -untrusted /opt/pki/sub/sub-ca.crt \
      /etc/pki/example/certs/www.crt
/etc/pki/example/certs/www.crt: OK

$ openssl verify -CAfile /opt/pki/root/root-ca.crt \
      -untrusted /opt/pki/sub/sub-ca.crt \
      -purpose sslserver -verify_hostname www.example.net \
      /etc/pki/example/certs/www.crt
/etc/pki/example/certs/www.crt: OK
```

`-purpose sslserver -verify_hostname` is the check almost everyone skips. Without it, `OK` only means "the chain builds", not "a browser will accept it".

---

## 6. Apache HTTPD + `mod_ssl`: complete production configuration

### 6.1 Module load and global policy — `/etc/httpd/conf.modules.d/00-ssl.conf` and `/etc/httpd/conf.d/ssl-global.conf`

```apache
# /etc/httpd/conf.modules.d/00-ssl.conf
LoadModule ssl_module modules/mod_ssl.so
LoadModule socache_shmcb_module modules/mod_socache_shmcb.so
LoadModule headers_module modules/mod_headers.so
```

```apache
# /etc/httpd/conf.d/ssl-global.conf
# ---------------------------------------------------------------------------
# Server-scope only. These directives are NOT per-virtual-host and mod_ssl
# will either ignore or reject them inside <VirtualHost>.
# ---------------------------------------------------------------------------

Listen 443 https

# Entropy for the PRNG. Modern OpenSSL seeds itself; this remains for
# compatibility and for platforms without a usable getrandom(2).
SSLRandomSeed startup  file:/dev/urandom 512
SSLRandomSeed connect  builtin

# ---- Session resumption ---------------------------------------------------
# Server-side session cache (TLS 1.2 session IDs, and TLS 1.3 stateful tickets).
SSLSessionCache         shmcb:/run/httpd/sslcache(512000)
SSLSessionCacheTimeout  300

# Stateless session tickets. Keys are regenerated on restart unless a key file
# is configured; a static key file across a fleet enables cross-node resumption
# but BREAKS FORWARD SECRECY if the file is never rotated.
SSLSessionTickets       on
# SSLSessionTicketKeyFile /etc/pki/example/private/ticket.key   # rotate daily!

# ---- OCSP stapling cache (MUST be server scope) ---------------------------
SSLStaplingCache        shmcb:/run/httpd/stapling-cache(256000)

# ---- Protocol and cipher policy (Mozilla "Intermediate") ------------------
SSLProtocol             all -SSLv3 -TLSv1 -TLSv1.1
SSLCipherSuite          ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:\
ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:\
ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:\
DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:DHE-RSA-CHACHA20-POLY1305
SSLCipherSuite TLSv1.3  TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:TLS_AES_128_GCM_SHA256
SSLHonorCipherOrder     off
SSLCompression          off
SSLInsecureRenegotiation off
SSLOpenSSLConfCmd       Groups X25519:secp256r1:secp384r1

# Reject connections whose SNI does not match any ServerName/ServerAlias
# instead of silently serving the first vhost's certificate.
SSLStrictSNIVHostCheck  on

# ---- Logging: make TLS auditable -----------------------------------------
LogFormat "%h %l %u %t \"%r\" %>s %b \
proto=%{SSL_PROTOCOL}x cipher=%{SSL_CIPHER}x sni=%{SSL_TLS_SNI}x \
resumed=%{SSL_SESSION_RESUMED}x cvfy=%{SSL_CLIENT_VERIFY}x \
cdn=\"%{SSL_CLIENT_S_DN}x\"" tls_combined
```

Note `SSLStaplingCache` and `SSLSessionCache` live here and *only* here. Putting `SSLStaplingCache` inside a `<VirtualHost>` produces a startup failure — a very common exam-adjacent gotcha.

### 6.2 Public HTTPS vhost with SNI, HSTS and stapling — `/etc/httpd/conf.d/www.example.net.conf`

```apache
# ---------------------------------------------------------------------------
# Port 80: redirect only. No content, no HSTS header (HSTS over plain HTTP is
# ignored by clients per RFC 6797 §7.2 — sending it there is a nop, not a fix).
# ---------------------------------------------------------------------------
<VirtualHost *:80>
    ServerName  www.example.net
    ServerAlias example.net static.example.net

    # ACME http-01 must stay reachable in cleartext.
    Alias /.well-known/acme-challenge/ /var/www/acme/.well-known/acme-challenge/
    <Directory "/var/www/acme/.well-known/acme-challenge">
        Require all granted
        Options -Indexes
    </Directory>

    RewriteEngine On
    RewriteCond %{REQUEST_URI} !^/\.well-known/acme-challenge/
    RewriteRule ^/?(.*)$ https://%{SERVER_NAME}/$1 [R=308,L]

    ErrorLog  /var/log/httpd/www.example.net-http-error.log
    CustomLog /var/log/httpd/www.example.net-http-access.log combined
</VirtualHost>

# ---------------------------------------------------------------------------
# Port 443: the real service. Selected by SNI.
# ---------------------------------------------------------------------------
<VirtualHost *:443>
    ServerName  www.example.net
    ServerAlias example.net static.example.net
    DocumentRoot /var/www/www.example.net

    Protocols h2 http/1.1

    SSLEngine on

    # Leaf + intermediates, leaf first, root omitted.
    SSLCertificateFile      /etc/pki/example/certs/www-fullchain.crt
    SSLCertificateKeyFile   /etc/pki/example/private/www.key

    # Dual-certificate deployment: an ECDSA leaf for modern clients and an RSA
    # leaf for the long tail. mod_ssl picks per handshake from the client's
    # signature_algorithms. Repeat the pair, do not use a second vhost.
    SSLCertificateFile      /etc/pki/example/certs/www-rsa-fullchain.crt
    SSLCertificateKeyFile   /etc/pki/example/private/www-rsa.key

    # ---- OCSP stapling ----------------------------------------------------
    SSLUseStapling                  on
    SSLStaplingResponderTimeout     5
    SSLStaplingReturnResponderErrors off
    SSLStaplingStandardCacheTimeout 3600
    SSLStaplingErrorCacheTimeout    120
    SSLStaplingFakeTryLater         on

    # ---- HSTS -------------------------------------------------------------
    # "always" is mandatory: without it the header is omitted on 4xx/5xx,
    # which are exactly the responses an attacker can provoke.
    Header always set Strict-Transport-Security "max-age=63072000; includeSubDomains; preload"

    # Companion hardening headers (not on the objectives, but expected of you)
    Header always set X-Content-Type-Options "nosniff"
    Header always set Referrer-Policy "strict-origin-when-cross-origin"
    Header always set Content-Security-Policy "default-src 'self'; frame-ancestors 'none'"

    <Directory "/var/www/www.example.net">
        Options -Indexes +FollowSymLinks
        AllowOverride None
        Require all granted
    </Directory>

    # Expose TLS variables to the application (CGI/FastCGI/proxy).
    <FilesMatch "\.(cgi|shtml|php)$">
        SSLOptions +StdEnvVars
    </FilesMatch>

    ErrorLog  /var/log/httpd/www.example.net-error.log
    CustomLog /var/log/httpd/www.example.net-access.log tls_combined
    LogLevel  warn ssl:info
</VirtualHost>
```

### 6.3 Directive reference

| Directive | Context | Default | What it really controls |
|---|---|---|---|
| `SSLEngine` | vhost | `off` | Whether this vhost speaks TLS at all |
| `SSLCertificateFile` | vhost | — | Leaf (+chain, +key since 2.4.8); repeatable for RSA/ECDSA |
| `SSLCertificateKeyFile` | vhost | — | Private key; must not be world-readable |
| `SSLCertificateChainFile` | vhost | — | **Deprecated 2.4.8**; use a fullchain file |
| `SSLCACertificateFile` | vhost | — | Trust anchors for *client* certificate verification |
| `SSLCACertificatePath` | vhost | — | Same, hashed directory (`openssl rehash`) |
| `SSLCADNRequestFile` | vhost | = `SSLCACertificateFile` | CA DNs advertised in `CertificateRequest` |
| `SSLVerifyClient` | server/vhost/dir/.htaccess | `none` | `none`/`optional`/`require`/`optional_no_ca` |
| `SSLVerifyDepth` | server/vhost/dir | `1` | Max intermediates **between** leaf and a trusted anchor |
| `SSLProtocol` | server/vhost | `all -SSLv3` | Enabled versions |
| `SSLCipherSuite [proto]` | server/vhost/dir | `DEFAULT` | Suite list; TLS 1.3 needs the `TLSv1.3` argument |
| `SSLHonorCipherOrder` | server/vhost | `off` | Server list wins over client preference |
| `SSLOpenSSLConfCmd` | server/vhost | — | Raw OpenSSL config commands (`Groups`, `SignatureAlgorithms`, …) |
| `SSLSessionCache` | **server only** | `none` | Server-side resumption store |
| `SSLSessionTickets` | server/vhost | `on` | RFC 5077 stateless tickets |
| `SSLStaplingCache` | **server only** | — | Required before any `SSLUseStapling on` |
| `SSLUseStapling` | server/vhost | `off` | Fetch and attach the OCSP response |
| `SSLOCSPEnable` | server/vhost | `off` | OCSP check of the **client's** certificate |
| `SSLCARevocationCheck` | server/vhost | `none` | `none`/`leaf`/`chain` [+`no_crl_for_cert_ok`] |
| `SSLStrictSNIVHostCheck` | server/vhost | `off` | Reject non-SNI or mismatched-SNI clients |
| `SSLOptions` | server/vhost/dir | — | `+StdEnvVars`, `+FakeBasicAuth`, `+ExportCertData`, `+StrictRequire`, `+OptRenegotiate`, `+LegacyDNStringFormat` |
| `SSLRequireSSL` | dir | — | Deny non-TLS access to this location |
| `SSLRequire` | dir | — | Boolean expression over SSL_* variables |
| `SSLUserName` | server/dir | — | Which SSL_* variable becomes `REMOTE_USER` |

---

## 7. SNI

### 7.1 The problem it solves

TLS starts before HTTP. The server must choose a certificate before it has seen a `Host:` header. Pre-SNI, name-based virtual hosting over HTTPS was impossible: one IP:port, one certificate. **Server Name Indication** (RFC 6066 §3) puts the requested hostname in a ClientHello extension, in cleartext, so the server can pick.

```
ClientHello
  extension: server_name (0)
    server_name_list
      server_name_type: host_name (0)
      HostName: "www.example.net"
```

### 7.2 How `mod_ssl` uses it

1. The connection arrives on `*:443`. mod_ssl reads SNI in the ClientHello.
2. It matches SNI against every `ServerName`/`ServerAlias` on that IP:port.
3. Match → that vhost's certificate. No match, or no SNI at all → **the first vhost defined for that address:port**, and its certificate.

Step 3 is the silent failure. A client with no SNI gets `www.example.net`'s certificate for a request to `api.example.net`, the name check fails, and the error the user sees is a certificate mismatch that has nothing to do with the certificate. `SSLStrictSNIVHostCheck on` converts that into an honest `unrecognized_name` (alert 112) / HTTP 403 instead.

There is a second consistency check, performed after the request line is parsed: if SNI and the HTTP `Host:` header disagree, httpd returns **400 Bad Request** and logs `AH02032: Hostname %s provided via SNI and hostname %s provided via HTTP are different`. This is not configurable and it is correct — a mismatch means the connection was routed on one name and the request on another.

### 7.3 Testing SNI

```bash
# With SNI — the expected case.
$ openssl s_client -connect 203.0.113.10:443 -servername api.example.net \
      </dev/null 2>&1 | grep -E '^(subject|issuer)'
subject=C=AR, O=Example Networks, CN=api.example.net
issuer=C=AR, O=Example Networks, CN=Example Networks TLS Issuing CA I1

# Without SNI — you get the default vhost.  -noservername is OpenSSL 1.1.1+.
$ openssl s_client -connect 203.0.113.10:443 -noservername \
      </dev/null 2>&1 | grep -E '^subject'
subject=C=AR, O=Example Networks, CN=www.example.net
```

> `openssl s_client -connect host:443` **does** send SNI derived from the `-connect` argument in OpenSSL 1.1.1 and later, but **not** in 1.0.2 and earlier. Half the "the server sends the wrong certificate" tickets on old jump boxes are this. Always pass `-servername` explicitly; it costs nothing and removes the ambiguity.

Confirm the vhost map httpd actually built:

```bash
$ apachectl -S
VirtualHost configuration:
*:80                   is a NameVirtualHost
         default server www.example.net (/etc/httpd/conf.d/www.example.net.conf:5)
         port 80 namevhost www.example.net (/etc/httpd/conf.d/www.example.net.conf:5)
                 alias example.net
                 alias static.example.net
*:443                  is a NameVirtualHost
         default server www.example.net (/etc/httpd/conf.d/www.example.net.conf:29)
         port 443 namevhost www.example.net (/etc/httpd/conf.d/www.example.net.conf:29)
                 alias example.net
                 alias static.example.net
         port 443 namevhost mtls.example.net (/etc/httpd/conf.d/mtls.example.net.conf:6)
ServerRoot: "/etc/httpd"
Main DocumentRoot: "/var/www/html"
Main ErrorLog: "/var/log/httpd/error_log"
Mutex ssl-stapling: using_defaults
Mutex ssl-cache: using_defaults
PidFile: "/run/httpd/httpd.pid"
User: name="apache" id=48
Group: name="apache" id=48
```

`default server` on `*:443` tells you exactly which certificate a non-SNI client receives.

---

## 8. HSTS

### 8.1 What it does

HTTP Strict Transport Security (RFC 6797) tells a browser: *for the next `max-age` seconds, never speak plain HTTP to this host; upgrade internally, and do not let the user click through certificate errors.* It closes the SSL-stripping window that exists on the very first navigation, and it converts a soft certificate warning into a hard failure.

```
Strict-Transport-Security: max-age=63072000; includeSubDomains; preload
```

| Directive | Meaning | Operational risk |
|---|---|---|
| `max-age=<sec>` | Lifetime of the pin, refreshed on every HTTPS response | High values are hard to undo — you must serve `max-age=0` over working HTTPS for the full old lifetime to reach every client |
| `includeSubDomains` | Applies to every subdomain, recursively | **Any** subdomain without a valid certificate becomes unreachable, including internal-only ones under the same apex |
| `preload` | Consent to inclusion in the browser-shipped list | Effectively permanent; removal takes browser release cycles |

### 8.2 Rules that trip people up

- The header is **ignored on plain HTTP responses**. Setting it on the port-80 vhost accomplishes nothing.
- The header is **ignored if the connection had any certificate error**. You cannot bootstrap HSTS from a broken deployment.
- It applies to a **host**, not a scheme+port. HSTS on `example.net` upgrades `http://example.net:8080` to `https://example.net:8080`.
- `Header set` without `always` places the header in the `onsuccess` table, so it is dropped from error responses. Use `Header always set`.

### 8.3 Rollout ladder

```apache
# Week 1 — 5 minutes. Cheap to undo.
Header always set Strict-Transport-Security "max-age=300"

# Week 2 — 1 day.
Header always set Strict-Transport-Security "max-age=86400"

# Week 4 — 1 week, after auditing every subdomain.
Header always set Strict-Transport-Security "max-age=604800; includeSubDomains"

# Week 8 — 2 years + preload submission at hstspreload.org
Header always set Strict-Transport-Security "max-age=63072000; includeSubDomains; preload"
```

```bash
$ curl -sI https://www.example.net/ | grep -i strict
strict-transport-security: max-age=63072000; includeSubDomains; preload

# Verify it survives an error response — this is what "always" buys you.
$ curl -sI https://www.example.net/does-not-exist | grep -iE '^(HTTP|strict)'
HTTP/2 404
strict-transport-security: max-age=63072000; includeSubDomains; preload
```

---

## 9. Client certificate authentication (mTLS)

### 9.1 `SSLVerifyClient` semantics

| Value | Server sends `CertificateRequest`? | Cert absent | Cert present but unverifiable | `SSL_CLIENT_VERIFY` |
|---|---|---|---|---|
| `none` | no | — | — | `NONE` |
| `optional` | yes | connection proceeds | **handshake fails** | `NONE` or `SUCCESS` |
| `require` | yes | **handshake fails** | **handshake fails** | `SUCCESS` |
| `optional_no_ca` | yes | proceeds | **proceeds** — validation deferred to the app | `GENEROUS` |

`optional_no_ca` is the one to understand: mod_ssl accepts any syntactically valid certificate and hands it to the application in `SSL_CLIENT_CERT`. It is how you build application-controlled trust (e.g. a device registry keyed by public-key fingerprint) — and it is a gaping hole if the application forgets to check.

`SSLVerifyDepth` counts **intermediate** CAs between the client leaf and a certificate in your trust store. With the two-tier PKI from §5, where `SSLCACertificateFile` holds only the root, the client chain is `alice → sub-ca → root`, so you need `SSLVerifyDepth 2`. The default of `1` rejects it with alert 48 (`unknown ca`) and the confusing log line `Certificate Verification: Error (20): unable to get local issuer certificate`. If instead you put the *intermediate* in `SSLCACertificateFile`, depth 1 suffices — but then you have delegated trust to the intermediate directly, and a replaced intermediate silently stops working.

### 9.2 Complete mTLS vhost — `/etc/httpd/conf.d/mtls.example.net.conf`

```apache
<VirtualHost *:443>
    ServerName mtls.example.net
    DocumentRoot /var/www/mtls.example.net

    # HTTP/2 forbids TLS renegotiation. Because per-directory client auth
    # historically relied on renegotiation, pin this vhost to HTTP/1.1 unless
    # every client is known to support TLS 1.3 post-handshake auth (RFC 8740).
    Protocols http/1.1

    SSLEngine on
    SSLCertificateFile    /etc/pki/example/certs/mtls-fullchain.crt
    SSLCertificateKeyFile /etc/pki/example/private/mtls.key

    # ---- Client authentication -------------------------------------------
    # Trust anchors used to verify CLIENT certificates. Distinct from the
    # chain we serve; a separate CA here would be even better hygiene.
    SSLCACertificateFile  /etc/pki/example/client-ca/root-ca.crt
    # Alternative, one file per CA + `openssl rehash`:
    # SSLCACertificatePath /etc/pki/example/client-ca/hashed

    # Advertise only ONE CA DN in the CertificateRequest even though we trust
    # several — keeps the handshake small and gives browsers a clean picker.
    SSLCADNRequestFile    /etc/pki/example/client-ca/advertised.pem

    SSLVerifyClient       require
    SSLVerifyDepth        2

    # ---- Revocation of client certificates --------------------------------
    # CRL path: files must be hashed with `openssl rehash`.
    SSLCARevocationPath   /etc/pki/example/client-ca/crl
    SSLCARevocationCheck  chain

    # OCSP path (alternative or complement). Requires the client cert to carry
    # an AIA OCSP URI, or set a default responder.
    # SSLOCSPEnable            leaf
    # SSLOCSPDefaultResponder  http://ocsp.example.net
    # SSLOCSPOverrideResponder off
    # SSLOCSPResponderTimeout  5
    # SSLOCSPUseRequestNonce   on

    # ---- Identity mapping --------------------------------------------------
    # Publish SSL_* into the CGI/proxy environment and make REMOTE_USER the
    # client certificate CN.
    SSLOptions +StdEnvVars +ExportCertData +StrictRequire
    SSLUserName SSL_CLIENT_S_DN_CN

    <Location "/">
        SSLRequireSSL
        # Fine-grained authorisation on certificate contents. Everything here
        # is evaluated AFTER a successful chain validation.
        SSLRequire %{SSL_CLIENT_VERIFY} eq "SUCCESS" \
                   and %{SSL_CLIENT_I_DN_CN} eq "Example Networks TLS Issuing CA I1" \
                   and %{SSL_CLIENT_S_DN_OU} in {"platform", "sre"}
        Require all granted
    </Location>

    # Health endpoint reachable without a client certificate is NOT possible
    # in this vhost — SSLVerifyClient require is enforced at handshake time.
    # Put the health check on a separate vhost/port. This is a real constraint.

    # ---- Pass the verified identity to the backend ------------------------
    RequestHeader set X-Client-DN     "%{SSL_CLIENT_S_DN}s"
    RequestHeader set X-Client-Serial "%{SSL_CLIENT_M_SERIAL}s"
    RequestHeader set X-Client-Verify "%{SSL_CLIENT_VERIFY}s"
    # Defensive: strip anything the client tried to inject.
    RequestHeader unset X-Client-Trusted early
    RequestHeader set   X-Client-Trusted "1"

    ProxyPreserveHost On
    ProxyPass        /api/ http://127.0.0.1:8080/
    ProxyPassReverse /api/ http://127.0.0.1:8080/

    ErrorLog  /var/log/httpd/mtls.example.net-error.log
    CustomLog /var/log/httpd/mtls.example.net-access.log tls_combined
    LogLevel  warn ssl:info
</VirtualHost>
```

`RequestHeader unset ... early` before setting it is not paranoia: without it, a client sends `X-Client-Trusted: 1` itself and your backend believes it. Header stripping at the trust boundary is mandatory whenever you convert TLS identity into HTTP identity.

### 9.3 The renegotiation problem, and why `Protocols http/1.1` is there

If `SSLVerifyClient require` appears at **vhost scope**, the `CertificateRequest` is part of the initial handshake. Simple, robust, works everywhere.

If it appears at **directory scope** (`<Location /admin>`), the server did not know a certificate would be needed when the handshake happened. Historically it solved this with **renegotiation**: a second handshake mid-connection. That mechanism has three problems:

1. It was the vector for CVE-2009-3555; RFC 5746 fixed it, but it remains disliked.
2. **HTTP/2 forbids renegotiation entirely** (RFC 9113 §9.2.1). With `Protocols h2`, directory-scoped client auth simply cannot work over an h2 connection.
3. **TLS 1.3 removed renegotiation.** Its replacement is post-handshake authentication (RFC 8446 §4.6.2), permitted with HTTP/2 by RFC 8740 only when the client advertised `post_handshake_auth`. Client support is inconsistent.

The production rule: **do client authentication at vhost scope, on a dedicated hostname or port.** Use `SSLRequire` / `Require` for finer authorisation *within* an already-authenticated connection. If you must have a mixed public/authenticated site, split it into two vhosts and link across.

### 9.4 The client-certificate SSL variables

| Variable | Example |
|---|---|
| `SSL_CLIENT_VERIFY` | `SUCCESS`, `NONE`, `GENEROUS`, `FAILED:certificate has expired` |
| `SSL_CLIENT_S_DN` | `CN=alice@example.net,OU=platform,O=Example Networks,C=AR` |
| `SSL_CLIENT_S_DN_CN` | `alice@example.net` |
| `SSL_CLIENT_S_DN_OU` | `platform` |
| `SSL_CLIENT_I_DN_CN` | `Example Networks TLS Issuing CA I1` |
| `SSL_CLIENT_M_SERIAL` | `5C3F1A9E447B20D18F6ACC0319BE7761` |
| `SSL_CLIENT_V_START` / `_V_END` | `Aug 18 09:20:00 2026 GMT` |
| `SSL_CLIENT_SAN_DNS_0`, `SSL_CLIENT_SAN_Email_0` | SAN entries by index |
| `SSL_CLIENT_CERT` | the full PEM (requires `+ExportCertData`) |
| `SSL_PROTOCOL`, `SSL_CIPHER`, `SSL_SESSION_RESUMED` | connection facts |

Since httpd 2.4, DNs are rendered in **RFC 2253** form (comma-separated, most-specific first). Legacy code that parsed the old OpenSSL `/C=AR/O=...` oneline format breaks; `SSLOptions +LegacyDNStringFormat` restores it as a migration crutch.

### 9.5 `+FakeBasicAuth`

```apache
SSLOptions +FakeBasicAuth
AuthType Basic
AuthName "Certificate DN"
AuthBasicProvider file
AuthUserFile /etc/httpd/conf/dn-users
Require valid-user
```

mod_ssl synthesises an `Authorization: Basic` header whose username is the client DN and whose password is the fixed string `password`, pre-hashed as the well-known crypt value:

```bash
$ printf '%s:xxj31ZMTZzkVA\n' \
    'CN=alice@example.net,OU=platform,O=Example Networks,C=AR' \
    | sudo tee -a /etc/httpd/conf/dn-users
```

It exists so that authorization modules written for Basic auth keep working. It is not an additional security control — anyone who can complete the mTLS handshake is already authenticated.

### 9.6 Testing mTLS

```bash
# Server rejects a connection with no client certificate.
$ openssl s_client -connect mtls.example.net:443 -servername mtls.example.net \
      -CAfile /etc/pki/example/root-ca.crt </dev/null
CONNECTED(00000003)
depth=1 C=AR, O=Example Networks, CN=Example Networks TLS Issuing CA I1
verify return:1
depth=0 C=AR, O=Example Networks, CN=mtls.example.net
verify return:1
---
Acceptable client certificate CA names
C=AR, O=Example Networks, CN=Example Networks Root CA R1
Requested Signature Algorithms: ECDSA+SHA256:RSA-PSS+SHA256:RSA+SHA256
---
40D7A1B2C47F0000:error:0A00045C:SSL routines:ssl3_read_bytes:tlsv13 alert certificate required:ssl/record/rec_layer_s3.c:1584:SSL alert number 116

# With a valid client certificate.
$ openssl s_client -connect mtls.example.net:443 -servername mtls.example.net \
      -CAfile /etc/pki/example/root-ca.crt \
      -cert alice.crt -key alice.key -tls1_3 </dev/null 2>/dev/null \
      | grep -E 'Verification|Cipher is|Protocol'
    Protocol  : TLSv1.3
    Cipher    : TLS_AES_256_GCM_SHA384
Verification: OK
New, TLSv1.3, Cipher is TLS_AES_256_GCM_SHA384

# End-to-end with curl, checking the identity the app receives.
$ curl -s --cacert /etc/pki/example/root-ca.crt \
       --cert alice.crt --key alice.key \
       https://mtls.example.net/api/whoami
{"dn":"CN=alice@example.net,OU=platform,O=Example Networks,C=AR","verify":"SUCCESS"}

# Revoke and confirm enforcement.
$ sudo openssl ca -config /opt/pki/sub/openssl.cnf -revoke alice.crt \
       -crl_reason keyCompromise
Revoking Certificate 5C3F1A9E447B20D18F6ACC0319BE7761.
Data Base Updated

$ sudo openssl ca -config /opt/pki/sub/openssl.cnf -gencrl \
       -out /etc/pki/example/client-ca/crl/sub-ca.crl
$ sudo openssl rehash /etc/pki/example/client-ca/crl
$ sudo apachectl graceful

$ curl -s --cacert /etc/pki/example/root-ca.crt \
       --cert alice.crt --key alice.key https://mtls.example.net/api/whoami
curl: (56) OpenSSL SSL_read: OpenSSL/3.0.7: error:0A000418:SSL routines:ssl3_read_bytes:tlsv1 alert unknown ca, errno 0
```

Server side:

```
[ssl:info] [pid 2214:tid 2277] [client 198.51.100.20:51512] AH02275: Certificate Verification: Error (23): certificate revoked
```

> `SSLCARevocationPath` requires hashed filenames. Dropping `sub-ca.crl` into the directory without `openssl rehash` means httpd never reads it and the revocation silently does nothing — a fail-open that is trivially missed. Prefer `SSLCARevocationFile` with a single concatenated CRL if you can, and always test with a genuinely revoked certificate.

---

## 10. OCSP stapling

### 10.1 Mechanics

The client sends a `status_request` extension in its ClientHello. The server, which has already fetched a signed OCSP response from the CA (out of band, on its own schedule), attaches that response to the handshake in a `CertificateStatus` message (TLS 1.2) or as a `status_request` extension on the `Certificate` message (TLS 1.3). The response is signed by the CA, so the server cannot forge it, and it carries `thisUpdate`/`nextUpdate` so it cannot be replayed indefinitely.

Result: revocation status with **zero** additional client latency, **zero** privacy leakage to the CA, and no dependency on the CA responder being reachable from the client's network.

### 10.2 Configuration

```apache
# server scope — MANDATORY, and must come before any SSLUseStapling
SSLStaplingCache shmcb:/run/httpd/stapling-cache(256000)

# vhost scope
SSLUseStapling                   on
SSLStaplingResponderTimeout      5      # seconds before giving up on the CA
SSLStaplingReturnResponderErrors off    # never forward "unknown"/errors to clients
SSLStaplingStandardCacheTimeout  3600   # cap on caching a good response
SSLStaplingErrorCacheTimeout     120    # retry sooner after a failure
SSLStaplingFakeTryLater          on     # send tryLater instead of nothing on timeout
SSLStaplingResponseMaxAge        -1     # -1 = accept whatever nextUpdate says
SSLStaplingResponseTimeSkew      300
# SSLStaplingForceURL http://ocsp.example.net   # override the AIA OCSP URI
```

| Directive | Default | When you change it |
|---|---|---|
| `SSLStaplingCache` | none | Always — omitting it is a startup error |
| `SSLUseStapling` | `off` | Always on for public certs |
| `SSLStaplingReturnResponderErrors` | `on` | Set `off`: an `unknown` status forwarded to a must-staple client is an outage |
| `SSLStaplingResponderTimeout` | `10` | Lower it; a 10 s stall on first handshake after cache expiry is user-visible |
| `SSLStaplingErrorCacheTimeout` | `600` | Lower when the CA responder is flaky |
| `SSLStaplingForceURL` | — | CA's AIA URI is unreachable from your network; you run an OCSP proxy |
| `SSLStaplingFakeTryLater` | `on` | Leave on |

Three hard requirements that cause most stapling failures:

1. The **leaf must carry an AIA OCSP URI**. Certificates from a private CA without `OCSP;URI` in `authorityInfoAccess` cannot be stapled — no URL to fetch from.
2. httpd must be able to **build the issuer chain in memory**, because the OCSP request identifies the certificate by hashes of the *issuer* name and key. If `SSLCertificateFile` holds only the leaf, you get `AH02217: ssl_stapling_init_cert: Can't retrieve issuer certificate!` at startup and stapling is silently disabled for that certificate.
3. httpd must have **outbound network access** to the responder, including any proxy (`SSLOCSPProxyURL` covers client-cert OCSP; stapling honours the standard proxy configuration of the OpenSSL HTTP client).

### 10.3 Verifying the staple

```bash
$ openssl s_client -connect www.example.net:443 -servername www.example.net \
      -status -CAfile /etc/pki/example/root-ca.crt </dev/null 2>/dev/null \
      | sed -n '/OCSP response/,/Next Update/p'
OCSP response:
======================================
OCSP Response Data:
    OCSP Response Status: successful (0x0)
    Response Type: Basic OCSP Response
    Version: 1 (0x0)
    Responder Id: C = AR, O = Example Networks, CN = Example Networks OCSP Responder
    Produced At: Aug 18 06:00:00 2026 GMT
    Responses:
    Certificate ID:
      Hash Algorithm: sha1
      Issuer Name Hash: 7B5B45CFAFCECB7B0353A55B99A2E3E2E1F4C0AA
      Issuer Key Hash: 0F80611C823161D52F28E78D4638B42CE1C6D9E2
      Serial Number: 5C3F1A9E447B20D18F6ACC0319BE7754
    Cert Status: good
    This Update: Aug 18 06:00:00 2026 GMT
    Next Update: Aug 25 06:00:00 2026 GMT
```

**Not stapled** looks like this — and it is easy to miss because the handshake still succeeds:

```bash
$ openssl s_client -connect www.example.net:443 -servername www.example.net \
      -status </dev/null 2>/dev/null | grep -A2 'OCSP response'
OCSP response: no response sent
```

A monitoring check that only greps for `Cert Status: good` will pass on a *revoked* certificate whose staple is absent, because there is nothing to grep. Assert on **both** presence and status:

```bash
#!/bin/bash
# /usr/local/bin/check-staple — exit 2 if absent, 1 if stale, 0 if fresh+good
set -euo pipefail
host="$1"
out=$(openssl s_client -connect "${host}:443" -servername "$host" \
        -status </dev/null 2>/dev/null)

grep -q 'OCSP Response Status: successful' <<<"$out" || {
    echo "CRITICAL: no OCSP staple from $host"; exit 2; }
grep -q 'Cert Status: good'                 <<<"$out" || {
    echo "CRITICAL: staple reports non-good status for $host"; exit 2; }

next=$(sed -n 's/^ *Next Update: //p' <<<"$out" | head -1)
secs=$(( $(date -u -d "$next" +%s) - $(date -u +%s) ))
(( secs < 86400 )) && { echo "WARNING: staple expires in $((secs/3600))h"; exit 1; }
echo "OK: staple good, valid for $((secs/3600))h"
```

### 10.4 Fetching an OCSP response by hand

Essential when stapling does not work and you need to know whether the problem is httpd or the CA:

```bash
$ openssl ocsp \
      -issuer /opt/pki/sub/sub-ca.crt \
      -cert   /etc/pki/example/certs/www.crt \
      -url    http://ocsp.example.net \
      -header "Host=ocsp.example.net" \
      -no_nonce -text
OCSP Request Data:
    Version: 1 (0x0)
    Requestor List:
        Certificate ID:
          Hash Algorithm: sha1
          Issuer Name Hash: 7B5B45CFAFCECB7B0353A55B99A2E3E2E1F4C0AA
          Issuer Key Hash: 0F80611C823161D52F28E78D4638B42CE1C6D9E2
          Serial Number: 5C3F1A9E447B20D18F6ACC0319BE7754
...
/etc/pki/example/certs/www.crt: good
	This Update: Aug 18 06:00:00 2026 GMT
	Next Update: Aug 25 06:00:00 2026 GMT
```

`-header "Host=..."` is needed whenever the responder is behind a name-based virtual host; without it OpenSSL sends no `Host:` header on some versions and the responder returns HTTP 400. `-no_nonce` matches what most public CAs actually support (they pre-sign responses and cannot include a nonce).

### 10.5 Must-staple

```ini
# add to [ server_ext ] to make stapling mandatory
tlsfeature = status_request
```

```bash
$ openssl x509 -in www.crt -noout -text | grep -A1 'TLS Feature'
            TLS Feature:
                status_request
```

A conforming client that receives no staple for a must-staple certificate **hard-fails**. That is the security win and the availability risk in one sentence. Prerequisites before enabling it: staple-age alerting (§10.3), an `SSLStaplingErrorCacheTimeout` short enough to recover quickly, and a documented rollback that does not require reissuing the certificate — which, since `tlsfeature` is baked into the certificate, means **keeping a non-must-staple certificate ready to swap in**.

---

## 11. `openssl s_client` / `s_server` cookbook

### 11.1 The canonical inspection

```bash
$ openssl s_client -connect www.example.net:443 -servername www.example.net \
      -CAfile /etc/pki/example/root-ca.crt -showcerts </dev/null 2>/dev/null
CONNECTED(00000003)
depth=2 C=AR, O=Example Networks, CN=Example Networks Root CA R1
verify return:1
depth=1 C=AR, O=Example Networks, CN=Example Networks TLS Issuing CA I1
verify return:1
depth=0 C=AR, O=Example Networks, CN=www.example.net
verify return:1
---
Certificate chain
 0 s:C=AR, O=Example Networks, CN=www.example.net
   i:C=AR, O=Example Networks, CN=Example Networks TLS Issuing CA I1
   a:PKEY: id-ecPublicKey, 256 (bit); sigalg: ecdsa-with-SHA256
   v:NotBefore: Aug 18 09:07:55 2026 GMT; NotAfter: Nov 16 09:07:55 2026 GMT
-----BEGIN CERTIFICATE-----
MIIC4zCCAougAwIBAgIQXD8ankR7INGPasw...
-----END CERTIFICATE-----
 1 s:C=AR, O=Example Networks, CN=Example Networks TLS Issuing CA I1
   i:C=AR, O=Example Networks, CN=Example Networks Root CA R1
   a:PKEY: rsaEncryption, 3072 (bit); sigalg: RSA-SHA256
   v:NotBefore: Aug 18 09:03:42 2026 GMT; NotAfter: Aug 17 09:03:42 2031 GMT
-----BEGIN CERTIFICATE-----
MIIFXzCCA0egAwIBAgIQXD8ankR7INGPasw...
-----END CERTIFICATE-----
---
Server certificate
subject=C=AR, O=Example Networks, CN=www.example.net
issuer=C=AR, O=Example Networks, CN=Example Networks TLS Issuing CA I1
---
No client certificate CA names sent
Peer signing digest: SHA256
Peer signature type: ECDSA
Negotiated TLS1.3 group: X25519
---
SSL handshake has read 2841 bytes and written 383 bytes
Verification: OK
---
New, TLSv1.3, Cipher is TLS_AES_256_GCM_SHA384
Server public key is 256 bit
Secure Renegotiation IS NOT supported
Compression: NONE
Expansion: NONE
No ALPN negotiated
Early data was not sent
Verify return code: 0 (ok)
---
```

Read it in this order: `depth=` lines (chain built and trusted), `Certificate chain` (**exactly what the server sent** — note there are two entries and no root: correct), `Verify return code: 0 (ok)`, then protocol and cipher.

`</dev/null` is not cosmetic: without it `s_client` waits on stdin forever and your script hangs.

### 11.2 The flags that matter

| Flag | Purpose |
|---|---|
| `-servername <n>` | Send SNI explicitly. Always. |
| `-noservername` | Suppress SNI, to test default-vhost behaviour |
| `-showcerts` | Print the full chain as sent by the server |
| `-status` | Request and print the OCSP staple |
| `-CAfile` / `-CApath` | Trust anchors for verification |
| `-verify_return_error` | **Abort** on verification failure instead of continuing |
| `-verify_hostname <n>` | Enforce RFC 6125 name checking |
| `-cert` / `-key` | Client certificate for mTLS |
| `-tls1_2` / `-tls1_3` / `-no_tls1_3` | Force or exclude a version |
| `-cipher <list>` | TLS ≤ 1.2 suite list |
| `-ciphersuites <list>` | TLS 1.3 suite list |
| `-groups <list>` | Offer only these key-exchange groups |
| `-sigalgs <list>` | Offer only these signature algorithms |
| `-alpn h2,http/1.1` | Negotiate ALPN |
| `-reconnect` | Reconnect 5× to test session resumption |
| `-sess_out` / `-sess_in` | Persist and reuse a session across invocations |
| `-starttls smtp\|imap\|ftp\|xmpp\|postgres\|ldap` | Opportunistic TLS upgrade |
| `-brief` | Condensed summary |
| `-msg` / `-trace` / `-state` / `-debug` | Handshake-level tracing |

### 11.3 Targeted probes

```bash
# Is TLS 1.0 still accepted? (Expect failure.)
$ openssl s_client -connect www.example.net:443 -servername www.example.net \
      -tls1 </dev/null 2>&1 | tail -3
40E7B21C7F000000:error:0A0000BF:SSL routines:tls_setup_handshake:no protocols available:ssl/statem/statem_lib.c:104:

# Does the server still offer 3DES? (Expect failure.)
$ openssl s_client -connect www.example.net:443 -servername www.example.net \
      -cipher '3DES' -no_tls1_3 </dev/null 2>&1 | grep -m1 error
40F7C31D7F000000:error:0A000410:SSL routines:ssl3_read_bytes:sslv3 alert handshake failure:ssl/record/rec_layer_s3.c:1584:SSL alert number 40

# Which named group actually got used?
$ openssl s_client -connect www.example.net:443 -servername www.example.net \
      </dev/null 2>/dev/null | grep 'Negotiated TLS1.3 group'
Negotiated TLS1.3 group: X25519

# Session resumption working? "Reused" on connections 2..5 is the goal.
$ openssl s_client -connect www.example.net:443 -servername www.example.net \
      -reconnect </dev/null 2>/dev/null | grep -E '^(New|Reused)'
New, TLSv1.3, Cipher is TLS_AES_256_GCM_SHA384
Reused, TLSv1.3, Cipher is TLS_AES_256_GCM_SHA384
Reused, TLSv1.3, Cipher is TLS_AES_256_GCM_SHA384
Reused, TLSv1.3, Cipher is TLS_AES_256_GCM_SHA384
Reused, TLSv1.3, Cipher is TLS_AES_256_GCM_SHA384

# ALPN — confirm h2 is really on.
$ openssl s_client -connect www.example.net:443 -servername www.example.net \
      -alpn h2,http/1.1 </dev/null 2>/dev/null | grep ALPN
ALPN protocol: h2

# Days until expiry, scriptable.
$ openssl s_client -connect www.example.net:443 -servername www.example.net \
      </dev/null 2>/dev/null | openssl x509 -noout -enddate
notAfter=Nov 16 09:07:55 2026 GMT

# Hard fail on any verification problem — use THIS in monitoring.
$ openssl s_client -connect www.example.net:443 -servername www.example.net \
      -verify_return_error -verify_hostname www.example.net \
      -CAfile /etc/pki/example/root-ca.crt </dev/null >/dev/null 2>&1
$ echo $?
0
```

### 11.4 `s_server` as a reference implementation

When you need to prove that the *client* is wrong, stand up a server whose configuration you fully control:

```bash
# Plain TLS server with a web page showing the connection details.
$ openssl s_server -accept 4433 \
      -cert /etc/pki/example/certs/www-fullchain.crt \
      -key  /etc/pki/example/private/www.key \
      -www
Using default temp DH parameters
ACCEPT

# Demand and verify a client certificate. -Verify (capital V) = require;
# -verify (lowercase) = request but continue if absent.
$ openssl s_server -accept 4433 \
      -cert  /etc/pki/example/certs/mtls-fullchain.crt \
      -key   /etc/pki/example/private/mtls.key \
      -CAfile /etc/pki/example/root-ca.crt \
      -Verify 2 -www
verify depth is 2, must return a certificate
Using default temp DH parameters
ACCEPT
depth=1 C=AR, O=Example Networks, CN=Example Networks TLS Issuing CA I1
verify return:1
depth=0 C=AR, O=Example Networks, CN=alice@example.net
verify return:1
```

```bash
$ curl -sk --cert alice.crt --key alice.key https://127.0.0.1:4433/ | head -12
<HTML><BODY BGCOLOR="#ffffff">
<pre>

s_server -accept 4433 -cert ... -Verify 2 -www
Ciphers supported in s_server binary
TLSv1.3    :TLS_AES_256_GCM_SHA384    TLSv1.3    :TLS_CHACHA20_POLY1305_SHA256
...
Client certificate
Certificate:
    Data:
        Version: 3 (0x2)
        Serial Number:
            5c:3f:1a:9e:44:7b:20:d1:8f:6a:cc:03:19:be:77:61
```

### 11.5 Reading the local cipher list

```bash
$ openssl ciphers -v 'ECDHE+AESGCM:ECDHE+CHACHA20:!aNULL' | column -t
TLS_AES_256_GCM_SHA384         TLSv1.3  Kx=any    Au=any    Enc=AESGCM(256)      Mac=AEAD
TLS_CHACHA20_POLY1305_SHA256   TLSv1.3  Kx=any    Au=any    Enc=CHACHA20/POLY1305(256) Mac=AEAD
TLS_AES_128_GCM_SHA256         TLSv1.3  Kx=any    Au=any    Enc=AESGCM(128)      Mac=AEAD
ECDHE-ECDSA-AES256-GCM-SHA384  TLSv1.2  Kx=ECDH   Au=ECDSA  Enc=AESGCM(256)      Mac=AEAD
ECDHE-RSA-AES256-GCM-SHA384    TLSv1.2  Kx=ECDH   Au=RSA    Enc=AESGCM(256)      Mac=AEAD
ECDHE-ECDSA-CHACHA20-POLY1305  TLSv1.2  Kx=ECDH   Au=ECDSA  Enc=CHACHA20/POLY1305(256) Mac=AEAD
ECDHE-RSA-CHACHA20-POLY1305    TLSv1.2  Kx=ECDH   Au=RSA    Enc=CHACHA20/POLY1305(256) Mac=AEAD
ECDHE-ECDSA-AES128-GCM-SHA256  TLSv1.2  Kx=ECDH   Au=ECDSA  Enc=AESGCM(128)      Mac=AEAD
ECDHE-RSA-AES128-GCM-SHA256    TLSv1.2  Kx=ECDH   Au=RSA    Enc=AESGCM(128)      Mac=AEAD
```

Note the TLS 1.3 suites appear regardless of the filter string: they are not selectable through the TLS ≤ 1.2 cipher-list grammar. That is the same asymmetry as `SSLCipherSuite` vs `SSLCipherSuite TLSv1.3`.

---

## 12. Container and Kubernetes infrastructure

The manifests below deploy the §6 configuration as an SNI-routed, passthrough-terminated `mod_ssl` service with mTLS, certificates issued by cert-manager from the same two-tier CA.

### 12.1 `Dockerfile`

```dockerfile
FROM registry.access.redhat.com/ubi9/ubi-minimal:9.4

RUN microdnf install -y httpd mod_ssl openssl shadow-utils \
    && microdnf clean all \
    && rm -f /etc/httpd/conf.d/ssl.conf /etc/httpd/conf.d/welcome.conf \
    && sed -i 's/^Listen 80$/Listen 8080/' /etc/httpd/conf/httpd.conf \
    && install -d -o apache -g apache -m 0755 /run/httpd /var/log/httpd

# Run unprivileged: ports are 8080/8443, not 80/443.
USER 1001

EXPOSE 8080 8443
STOPSIGNAL SIGWINCH

HEALTHCHECK --interval=15s --timeout=5s --start-period=10s --retries=3 \
  CMD /usr/bin/openssl s_client -connect 127.0.0.1:8443 \
        -servername mtls.example.net -verify_return_error \
        -CAfile /etc/pki/example/root-ca.crt \
        -cert /etc/pki/example/probe/tls.crt \
        -key  /etc/pki/example/probe/tls.key </dev/null >/dev/null 2>&1

CMD ["/usr/sbin/httpd", "-DFOREGROUND"]
```

### 12.2 Full Kubernetes bundle

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: edge
  labels:
    pod-security.kubernetes.io/enforce: restricted
---
# ---------------------------------------------------------------------------
# PKI: bootstrap self-signed -> root CA -> issuing CA -> leaf certificates.
# Mirrors the openssl two-tier hierarchy from section 5.
# ---------------------------------------------------------------------------
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-bootstrap
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: example-root-ca
  namespace: cert-manager
spec:
  isCA: true
  commonName: Example Networks Root CA R1
  subject:
    countries: ["AR"]
    organizations: ["Example Networks"]
  secretName: example-root-ca
  duration: 87600h    # 10 years
  renewBefore: 8760h  # 1 year
  privateKey:
    algorithm: RSA
    size: 4096
    encoding: PKCS8
    rotationPolicy: Never
  usages:
    - cert sign
    - crl sign
  issuerRef:
    name: selfsigned-bootstrap
    kind: ClusterIssuer
    group: cert-manager.io
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: example-root-ca
spec:
  ca:
    secretName: example-root-ca
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: example-issuing-ca
  namespace: cert-manager
spec:
  isCA: true
  commonName: Example Networks TLS Issuing CA I1
  subject:
    countries: ["AR"]
    organizations: ["Example Networks"]
  secretName: example-issuing-ca
  duration: 43800h    # 5 years
  renewBefore: 4380h
  privateKey:
    algorithm: RSA
    size: 3072
    encoding: PKCS8
    rotationPolicy: Never
  usages:
    - cert sign
    - crl sign
  issuerRef:
    name: example-root-ca
    kind: ClusterIssuer
    group: cert-manager.io
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: example-issuing-ca
spec:
  ca:
    secretName: example-issuing-ca
---
# ---------------------------------------------------------------------------
# Leaf certificates. tls.crt from a CA issuer already contains leaf+intermediate
# (cert-manager appends the issuer chain), which is exactly what
# SSLCertificateFile wants. ca.crt holds the root — the CLIENT trust anchor.
# ---------------------------------------------------------------------------
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: www-tls
  namespace: edge
spec:
  secretName: www-tls
  commonName: www.example.net
  dnsNames:
    - www.example.net
    - example.net
    - static.example.net
  duration: 2160h      # 90 days
  renewBefore: 720h    # 30 days
  privateKey:
    algorithm: ECDSA
    size: 256
    rotationPolicy: Always
  usages:
    - digital signature
    - server auth
  issuerRef:
    name: example-issuing-ca
    kind: ClusterIssuer
    group: cert-manager.io
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: mtls-tls
  namespace: edge
spec:
  secretName: mtls-tls
  commonName: mtls.example.net
  dnsNames:
    - mtls.example.net
  duration: 2160h
  renewBefore: 720h
  privateKey:
    algorithm: ECDSA
    size: 256
    rotationPolicy: Always
  usages:
    - digital signature
    - server auth
  issuerRef:
    name: example-issuing-ca
    kind: ClusterIssuer
    group: cert-manager.io
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: probe-client
  namespace: edge
spec:
  secretName: probe-client
  commonName: probe@example.net
  subject:
    organizationalUnits: ["platform"]
  duration: 2160h
  renewBefore: 720h
  privateKey:
    algorithm: ECDSA
    size: 256
    rotationPolicy: Always
  usages:
    - digital signature
    - client auth
  issuerRef:
    name: example-issuing-ca
    kind: ClusterIssuer
    group: cert-manager.io
---
# ---------------------------------------------------------------------------
# httpd configuration
# ---------------------------------------------------------------------------
apiVersion: v1
kind: ConfigMap
metadata:
  name: httpd-tls-config
  namespace: edge
data:
  00-ssl-global.conf: |
    Listen 8443 https

    SSLRandomSeed startup file:/dev/urandom 512
    SSLRandomSeed connect builtin

    SSLSessionCache        shmcb:/run/httpd/sslcache(512000)
    SSLSessionCacheTimeout 300
    SSLSessionTickets      on
    SSLStaplingCache       shmcb:/run/httpd/stapling-cache(256000)

    SSLProtocol            -all +TLSv1.2 +TLSv1.3
    SSLCipherSuite         ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305
    SSLCipherSuite TLSv1.3 TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:TLS_AES_128_GCM_SHA256
    SSLHonorCipherOrder    off
    SSLCompression         off
    SSLOpenSSLConfCmd      Groups X25519:secp256r1:secp384r1
    SSLStrictSNIVHostCheck on

    LogFormat "%h %t \"%r\" %>s %b proto=%{SSL_PROTOCOL}x cipher=%{SSL_CIPHER}x sni=%{SSL_TLS_SNI}x cvfy=%{SSL_CLIENT_VERIFY}x cdn=\"%{SSL_CLIENT_S_DN}x\"" tls_combined
    ErrorLogFormat "[%{u}t] [%-m:%l] [pid %P] %F: %E: [client %a] %M"

  10-www.conf: |
    <VirtualHost *:8443>
        ServerName  www.example.net
        ServerAlias example.net static.example.net
        DocumentRoot /var/www/html
        Protocols h2 http/1.1

        SSLEngine on
        SSLCertificateFile    /etc/pki/example/www/tls.crt
        SSLCertificateKeyFile /etc/pki/example/www/tls.key

        SSLUseStapling                   on
        SSLStaplingResponderTimeout      5
        SSLStaplingReturnResponderErrors off
        SSLStaplingErrorCacheTimeout     120

        Header always set Strict-Transport-Security "max-age=63072000; includeSubDomains"
        Header always set X-Content-Type-Options "nosniff"

        <Directory "/var/www/html">
            Options -Indexes
            Require all granted
        </Directory>

        CustomLog /dev/stdout tls_combined
        ErrorLog  /dev/stderr
        LogLevel  warn ssl:info
    </VirtualHost>

  20-mtls.conf: |
    <VirtualHost *:8443>
        ServerName mtls.example.net
        DocumentRoot /var/www/html
        Protocols http/1.1

        SSLEngine on
        SSLCertificateFile    /etc/pki/example/mtls/tls.crt
        SSLCertificateKeyFile /etc/pki/example/mtls/tls.key

        SSLCACertificateFile  /etc/pki/example/mtls/ca.crt
        SSLVerifyClient       require
        SSLVerifyDepth        2
        SSLOptions            +StdEnvVars +ExportCertData +StrictRequire
        SSLUserName           SSL_CLIENT_S_DN_CN

        <Location "/">
            SSLRequireSSL
            SSLRequire %{SSL_CLIENT_VERIFY} eq "SUCCESS" \
                       and %{SSL_CLIENT_S_DN_OU} in {"platform", "sre"}
            Require all granted
        </Location>

        RequestHeader unset X-Client-DN early
        RequestHeader set   X-Client-DN "%{SSL_CLIENT_S_DN}s"

        CustomLog /dev/stdout tls_combined
        ErrorLog  /dev/stderr
        LogLevel  warn ssl:info
    </VirtualHost>
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: httpd-tls
  namespace: edge
  annotations:
    # Restart pods when any mounted Secret/ConfigMap changes. Without this,
    # kubelet updates the files on disk but httpd keeps the OLD certificate
    # in memory until the process is reloaded. This is the #1 cause of
    # "cert-manager renewed it but the server still serves the expired one".
    reloader.stakater.com/auto: "true"
spec:
  replicas: 3
  revisionHistoryLimit: 3
  selector:
    matchLabels:
      app.kubernetes.io/name: httpd-tls
  template:
    metadata:
      labels:
        app.kubernetes.io/name: httpd-tls
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1001
        fsGroup: 1001
        seccompProfile:
          type: RuntimeDefault
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: httpd-tls
      containers:
        - name: httpd
          image: registry.example.net/edge/httpd-tls:1.4.2
          imagePullPolicy: IfNotPresent
          ports:
            - name: https
              containerPort: 8443
              protocol: TCP
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          resources:
            requests: {cpu: "100m", memory: "128Mi"}
            limits:   {cpu: "1",    memory: "512Mi"}
          volumeMounts:
            - {name: httpd-config, mountPath: /etc/httpd/conf.d, readOnly: true}
            - {name: www-tls,      mountPath: /etc/pki/example/www,   readOnly: true}
            - {name: mtls-tls,     mountPath: /etc/pki/example/mtls,  readOnly: true}
            - {name: probe-client, mountPath: /etc/pki/example/probe, readOnly: true}
            - {name: root-ca,      mountPath: /etc/pki/example,       readOnly: true}
            - {name: run,          mountPath: /run/httpd}
            - {name: docroot,      mountPath: /var/www/html, readOnly: true}
          startupProbe:
            tcpSocket: {port: https}
            failureThreshold: 12
            periodSeconds: 5
          readinessProbe:
            # TCP only: an httpGet probe cannot present a client certificate,
            # and this port requires one on the mtls vhost. The real TLS check
            # is the container HEALTHCHECK / the external synthetic monitor.
            tcpSocket: {port: https}
            periodSeconds: 10
          livenessProbe:
            tcpSocket: {port: https}
            periodSeconds: 20
            failureThreshold: 3
          lifecycle:
            preStop:
              exec:
                command: ["/usr/sbin/httpd", "-k", "graceful-stop"]
      terminationGracePeriodSeconds: 45
      volumes:
        - name: httpd-config
          configMap: {name: httpd-tls-config}
        - name: www-tls
          secret: {secretName: www-tls, defaultMode: 0400}
        - name: mtls-tls
          secret: {secretName: mtls-tls, defaultMode: 0400}
        - name: probe-client
          secret: {secretName: probe-client, defaultMode: 0400}
        - name: root-ca
          secret:
            secretName: example-root-ca
            items: [{key: ca.crt, path: root-ca.crt}]
            defaultMode: 0444
        - name: run
          emptyDir: {medium: Memory}
        - name: docroot
          configMap: {name: httpd-docroot, optional: true}
---
apiVersion: v1
kind: Service
metadata:
  name: httpd-tls
  namespace: edge
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: httpd-tls
  ports:
    - name: https
      port: 443
      targetPort: https
      protocol: TCP
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: httpd-tls
  namespace: edge
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: httpd-tls
---
# ---------------------------------------------------------------------------
# SSL passthrough. The ingress routes on SNI at L4 and does NOT terminate TLS,
# which is the only way the client certificate reaches mod_ssl. The cost:
# no path-based routing, no L7 logs, no WAF at the edge for this host.
# ---------------------------------------------------------------------------
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: httpd-tls
  namespace: edge
  annotations:
    nginx.ingress.kubernetes.io/ssl-passthrough: "true"
    nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
spec:
  ingressClassName: nginx
  rules:
    - host: www.example.net
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: httpd-tls
                port: {name: https}
    - host: mtls.example.net
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: httpd-tls
                port: {name: https}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: httpd-tls
  namespace: edge
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: httpd-tls
  policyTypes: [Ingress, Egress]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels: {kubernetes.io/metadata.name: ingress-nginx}
      ports:
        - {protocol: TCP, port: 8443}
  egress:
    # DNS
    - to:
        - namespaceSelector:
            matchLabels: {kubernetes.io/metadata.name: kube-system}
      ports:
        - {protocol: UDP, port: 53}
        - {protocol: TCP, port: 53}
    # OCSP responder — WITHOUT this rule, SSLUseStapling silently fails and
    # the server serves no staple. Must-staple certs would break outright.
    - to:
        - ipBlock: {cidr: 0.0.0.0/0, except: ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]}
      ports:
        - {protocol: TCP, port: 80}
```

Two notes worth internalising:

- **`reloader.stakater.com/auto`** (or an equivalent: a sidecar watching inode changes, or short-lived pods) is not optional. cert-manager renewing a `Secret` does not restart `httpd`, and `httpd` reads certificates once at startup. Every "renewal did not take effect" incident traces to this.
- The **egress rule to port 80** exists solely for OCSP. Locking egress down without it produces a stapling failure that no `apachectl configtest` will ever catch.

---

## 13. Verification and failure diagnosis

### 13.1 Order of operations

```
1. apachectl -t                     → config syntax
2. apachectl -S                     → which vhost owns which name:port
3. openssl x509 -noout -text        → is the certificate what I think it is?
4. openssl verify -untrusted        → does the chain build, locally?
5. openssl s_client -showcerts      → does the SERVER send that chain?
6. openssl s_client -status         → is there a staple, and is it good?
7. curl -v with real trust store    → does a real client accept it?
8. LogLevel ssl:trace3 + error log  → why not
```

### 13.2 Configuration and startup failures

| Symptom | Cause | Fix |
|---|---|---|
| `AH00526: Syntax error ... Invalid command 'SSLEngine'` | `mod_ssl` not loaded | `LoadModule ssl_module modules/mod_ssl.so`; on Debian `a2enmod ssl` |
| `AH02572: Failed to configure at least one certificate and key for <vhost>` | Key does not match cert, file unreadable, or unsupported key type | §13.3 |
| `AH02565: Certificate and private key ... do not match` | Wrong key file | §13.3 |
| `AH01909: server certificate does NOT include an ID which matches the server name` | `ServerName` not in SAN | Reissue with the right SANs |
| `AH01906: server certificate is a CA certificate` | You configured the CA cert as the leaf | Point `SSLCertificateFile` at the leaf |
| `AH02217: ssl_stapling_init_cert: Can't retrieve issuer certificate!` | Intermediate missing from `SSLCertificateFile` | Build a fullchain file |
| `SSLStaplingCache` error at startup | Directive placed inside `<VirtualHost>` | Move to server scope |
| `Init: Private key not found` | Encrypted key, no passphrase source | Decrypt the key, or configure `SSLPassPhraseDialog` |
| Permission denied on the key | mode/owner, or SELinux | §13.6 |

### 13.3 Does the key match the certificate?

The classic recipe only works for RSA:

```bash
# RSA only
$ openssl x509 -noout -modulus -in www-rsa.crt | openssl sha256
SHA2-256(stdin)= 4b1c0e77a9f2ee1d8c33b7d5906a41f88c2e5b09ad7431f6ee20cd9a4f7b8123
$ openssl rsa  -noout -modulus -in www-rsa.key | openssl sha256
SHA2-256(stdin)= 4b1c0e77a9f2ee1d8c33b7d5906a41f88c2e5b09ad7431f6ee20cd9a4f7b8123
```

The **algorithm-agnostic** version — use this one always, it works for RSA, ECDSA and Ed25519, and it also works against a CSR:

```bash
$ openssl x509 -in www.crt -noout -pubkey | openssl pkey -pubin -outform DER | openssl sha256
SHA2-256(stdin)= 9d2f4a771c05e8b3116ae0d47f2c9b80a3e6157dc4b98021ff7e3a6c50d1b774
$ openssl pkey -in www.key -pubout -outform DER | openssl sha256
SHA2-256(stdin)= 9d2f4a771c05e8b3116ae0d47f2c9b80a3e6157dc4b98021ff7e3a6c50d1b774
$ openssl req  -in www.csr -noout -pubkey | openssl pkey -pubin -outform DER | openssl sha256
SHA2-256(stdin)= 9d2f4a771c05e8b3116ae0d47f2c9b80a3e6157dc4b98021ff7e3a6c50d1b774
```

Three identical digests means cert, key and CSR are one triple. Anything else is `AH02572`.

### 13.4 Handshake failures, decoded

| Client-visible error | TLS alert | Root cause | Where to look |
|---|---|---|---|
| `unable to get local issuer certificate` (verify 20) | — | Server did not send the intermediate | `s_client -showcerts`: count the certs |
| `unable to verify the first certificate` (21) | — | Same, from the client's angle | Build a fullchain file |
| `self-signed certificate in certificate chain` (19) | — | Private root not in the client trust store | `-CAfile`, or install the root |
| `certificate has expired` (10) | 45 `certificate_expired` | Expiry — or client clock skew | `openssl x509 -noout -dates`; `timedatectl` |
| `Hostname mismatch` (62) | — | Name not in SAN; or SNI not sent | `-servername`, then check SANs |
| `tlsv1 alert unknown ca` | 48 | **Client** cert not verifiable by the server | `SSLVerifyDepth`, `SSLCACertificateFile`, CRL |
| `tlsv13 alert certificate required` | 116 | `SSLVerifyClient require`, no cert offered | Provide `-cert`/`-key` |
| `sslv3 alert handshake failure` | 40 | No shared cipher / group / sigalg | `SSLCipherSuite`, `Groups`, cert key type |
| `no protocols available` | — | Client-side: version excluded locally | Client `SSLProtocol`/`MinProtocol` |
| `tlsv1 alert protocol version` | 70 | No mutually enabled TLS version | `SSLProtocol` on both ends |
| `unrecognized name` | 112 | `SSLStrictSNIVHostCheck on`, SNI unknown | Add `ServerAlias`, or send correct SNI |
| `wrong version number` | — | **You spoke TLS to a plaintext port** | Check the port; check `SSLEngine on` |
| `certificate revoked` | 44 | CRL/OCSP says so | Intended — or a stale CRL |
| `decrypt_error` | 51 | `CertificateVerify` signature failed | Key/cert mismatch on the client side |

`wrong version number` deserves emphasis because it looks like a protocol negotiation problem and never is. It means the bytes coming back were not a TLS record at all — usually an HTTP response, because you connected to port 80 or hit a vhost without `SSLEngine on`.

### 13.5 Server-side tracing

```bash
# Per-module log level; do NOT set LogLevel trace globally in production.
$ sudo sed -i 's/^LogLevel .*/LogLevel warn ssl:trace3/' /etc/httpd/conf/httpd.conf
$ sudo apachectl graceful
$ sudo tail -f /var/log/httpd/error_log
[ssl:info] [pid 2214] [client 198.51.100.20:51512] AH01964: Connection to child 0 established (server mtls.example.net:443)
[ssl:trace3] [pid 2214] ssl_engine_kernel.c(2263): [client 198.51.100.20:51512] OpenSSL: Handshake: start
[ssl:trace3] [pid 2214] ssl_engine_kernel.c(2272): [client 198.51.100.20:51512] OpenSSL: Loop: before SSL initialization
[ssl:trace3] [pid 2214] ssl_engine_kernel.c(2247): [client 198.51.100.20:51512] OpenSSL: read finished A
[ssl:info]  [pid 2214] [client 198.51.100.20:51512] AH02275: Certificate Verification: Error (20): unable to get local issuer certificate
[ssl:info]  [pid 2214] [client 198.51.100.20:51512] AH02008: SSL library error 1 in handshake (server mtls.example.net:443)
[ssl:info]  [pid 2214] SSL Library Error: error:0A000086:SSL routines::certificate verify failed
```

`Error (20)` on a *client* certificate almost always means `SSLVerifyDepth` is too small or the intermediate is absent from the server's client-CA bundle. Remember to put `LogLevel` back.

### 13.6 File permissions and SELinux

```bash
$ sudo ls -lZ /etc/pki/example/private/
-rw-------. 1 root root system_u:object_r:cert_t:s0 241 Aug 18 09:07 www.key

$ sudo restorecon -Rv /etc/pki/example
Relabeled /etc/pki/example/private/www.key from unconfined_u:object_r:user_home_t:s0 to system_u:object_r:cert_t:s0

# Non-standard path? Label it, do not disable SELinux.
$ sudo semanage fcontext -a -t cert_t '/opt/tls(/.*)?'
$ sudo restorecon -Rv /opt/tls

# Non-standard port? Same principle.
$ sudo semanage port -a -t http_port_t -p tcp 8443

$ sudo ausearch -m avc -ts recent | audit2why
```

httpd reads the key as root before dropping privileges, so `0600 root:root` is correct. A key readable by the `apache` user is a finding, not a convenience.

### 13.7 When you must see the bytes

```bash
# Handshake only; the rest is encrypted anyway.
$ sudo tshark -i any -f 'tcp port 443' -Y 'tls.handshake' \
      -T fields -e ip.src -e tls.handshake.type \
      -e tls.handshake.extensions_server_name -e tls.handshake.version
198.51.100.20  1   www.example.net  0x0303
203.0.113.10   2                    0x0303
203.0.113.10   11
203.0.113.10   15

# Decrypt application data in a lab: point the client at a key log file and
# hand the file to Wireshark (Preferences > Protocols > TLS > Pre-Master-Secret
# log filename). Works for TLS 1.3 too, where the server key alone cannot
# decrypt anything because of forward secrecy.
$ SSLKEYLOGFILE=/tmp/keys.log curl -s https://www.example.net/ >/dev/null
$ head -2 /tmp/keys.log
SERVER_HANDSHAKE_TRAFFIC_SECRET 3f7a...  9b21...
CLIENT_HANDSHAKE_TRAFFIC_SECRET 3f7a...  4c88...
```

That last point is worth stating explicitly for the exam: with ECDHE (and therefore with all of TLS 1.3), possessing the server's private key does **not** let you decrypt captured traffic. That is forward secrecy, and it is the operational reason `!kRSA` is in every modern cipher string.

### 13.8 Fleet-wide expiry audit

```bash
#!/bin/bash
# /usr/local/bin/tls-audit — one line per endpoint, sorted by urgency
set -uo pipefail
printf '%-32s %-10s %-26s %-8s %s\n' HOST DAYS ISSUER STAPLE PROTO
while read -r host port; do
  out=$(timeout 8 openssl s_client -connect "${host}:${port}" \
          -servername "$host" -status </dev/null 2>/dev/null) || {
        printf '%-32s %-10s %s\n' "$host" "-" "CONNECT FAILED"; continue; }

  end=$(openssl x509 -noout -enddate <<<"$out" 2>/dev/null | cut -d= -f2)
  days=$(( ( $(date -u -d "$end" +%s) - $(date -u +%s) ) / 86400 ))
  iss=$(openssl x509 -noout -issuer <<<"$out" 2>/dev/null | sed 's/.*CN *= *//')
  proto=$(sed -n 's/^ *Protocol *: *//p' <<<"$out" | head -1)
  if grep -q 'Cert Status: good' <<<"$out"; then staple=good
  elif grep -q 'OCSP response: no response sent' <<<"$out"; then staple=ABSENT
  else staple=BAD; fi

  printf '%-32s %-10s %-26s %-8s %s\n' "$host" "$days" "${iss:0:26}" "$staple" "$proto"
done < /etc/tls-audit.targets | (read -r h; echo "$h"; sort -k2 -n)
```

```bash
$ tls-audit
HOST                             DAYS       ISSUER                     STAPLE   PROTO
mtls.example.net                 11         Example Networks TLS Issu  ABSENT   TLSv1.3
api.example.net                  34         Example Networks TLS Issu  good     TLSv1.3
www.example.net                  89         Example Networks TLS Issu  good     TLSv1.3
legacy.example.net               412        Example Networks Root CA   ABSENT   TLSv1.2
```

Two findings are visible at a glance: `mtls` is 11 days out with no staple, and `legacy` is signed **directly by the root** with a 412-day life — a certificate that bypasses the intermediate entirely and therefore bypasses your name constraints and your revocation process.

---

## 14. Renewal, rotation and reload

### 14.1 Reload semantics

| Command | Effect on in-flight connections | Rereads certificates |
|---|---|---|
| `apachectl graceful` / `httpd -k graceful` | Finish current requests, then children exit | **yes** |
| `apachectl restart` | Same as graceful on 2.4 for `-k restart`? No — hard restart drops connections | yes |
| `systemctl reload httpd` | maps to `graceful` | yes |
| `systemctl restart httpd` | drops connections | yes |
| `apachectl -k graceful-stop` | drain then stop, for rolling deploys | n/a |

**Always `graceful` for certificate rotation.** A hard restart during renewal turns a routine operation into a visible blip.

### 14.2 `mod_md` — ACME inside httpd

httpd 2.4.30+ ships an ACME client. No cron, no external certbot, no reload hook:

```apache
LoadModule md_module modules/mod_md.so

MDCertificateAgreement accepted
MDContactEmail         platform@example.net
MDCertificateAuthority https://acme-v02.api.letsencrypt.org/directory
MDStoreDir             /var/www/md
MDPrivateKeys          secp384r1 rsa3072      # dual-cert, automatically
MDRenewWindow          33%
MDStapling             on                    # mod_md's own stapling, replaces mod_ssl's
MDMessageCmd           /usr/local/bin/md-notify

MDomain www.example.net example.net static.example.net

<VirtualHost *:443>
    ServerName  www.example.net
    ServerAlias example.net static.example.net
    SSLEngine on
    # No SSLCertificateFile / SSLCertificateKeyFile: mod_md supplies them.
    Header always set Strict-Transport-Security "max-age=63072000; includeSubDomains"
</VirtualHost>
```

```bash
$ sudo apachectl -M | grep md_
 md_module (shared)

$ curl -s http://localhost/.httpd/certificate-status | python3 -m json.tool
{
    "valid": {"from": "2026-08-18T09:07:55Z", "until": "2026-11-16T09:07:55Z"},
    "serial": "5C3F1A9E447B20D18F6ACC0319BE7754",
    "sha256-fingerprint": "9d2f4a77...",
    "renewal": {"finished": false, "notified": false, "last-run": "2026-08-18T09:07:55Z"}
}
```

`MDStapling on` supersedes `SSLUseStapling` for `mod_md`-managed domains, with its own cache and retry policy. Do not configure both for the same vhost.

### 14.3 `certbot` with a reload hook

```bash
$ sudo certbot certonly --webroot -w /var/www/acme \
      -d www.example.net -d example.net -d static.example.net \
      --key-type ecdsa --elliptic-curve secp256r1 \
      --deploy-hook '/usr/bin/apachectl graceful'
Saving debug log to /var/log/letsencrypt/letsencrypt.log
Requesting a certificate for www.example.net and 2 more domains
Successfully received certificate.
Certificate is saved at: /etc/letsencrypt/live/www.example.net/fullchain.pem
Key is saved at:         /etc/letsencrypt/live/www.example.net/privkey.pem
This certificate expires on 2026-11-16.

$ sudo certbot renew --dry-run
Congratulations, all simulated renewals succeeded:
  /etc/letsencrypt/live/www.example.net/fullchain.pem (success)
```

`--deploy-hook` runs **only when a certificate was actually renewed**; `--post-hook` runs on every attempt. Using `--post-hook` for the reload means a graceful restart every twelve hours forever.

| Strategy | Where the private key lives | Reload trigger | Best for |
|---|---|---|---|
| `mod_md` | httpd's `MDStoreDir` | internal, no restart | single-host Apache |
| `certbot --deploy-hook` | `/etc/letsencrypt/live` | hook | classic VMs, config management |
| cert-manager + reloader | Kubernetes `Secret` | pod restart | Kubernetes |
| Vault PKI + agent template | tmpfs, short TTL | agent signals `SIGWINCH`/reload | dynamic fleets, 24 h certs |

---

## 15. Exam-focused summary

**Directives you must be able to write from memory:** `SSLEngine`, `SSLCertificateFile`, `SSLCertificateKeyFile`, `SSLCertificateChainFile` (and why it is deprecated), `SSLCACertificateFile`/`Path`, `SSLProtocol`, `SSLCipherSuite`, `SSLHonorCipherOrder`, `SSLVerifyClient`, `SSLVerifyDepth`, `SSLUseStapling`, `SSLStaplingCache`, `SSLOptions`, `SSLRequire`, `SSLStrictSNIVHostCheck`.

**The eight traps:**

1. `SSLStaplingCache` and `SSLSessionCache` are **server scope only**.
2. The served chain is **leaf → intermediates**, never the root, and order matters.
3. `SSLVerifyDepth` counts intermediates *between* leaf and anchor; the default `1` is too small for a two-tier PKI rooted at the root.
4. `SSLCipherSuite` without the `TLSv1.3` argument does not touch TLS 1.3 suites.
5. `SSLCACertificatePath` and `SSLCARevocationPath` need `openssl rehash`; without it they fail **open**.
6. No SNI, or unmatched SNI, serves the **first** vhost on that address:port — unless `SSLStrictSNIVHostCheck on`.
7. HSTS on a plain-HTTP response is ignored; `Header set` without `always` drops it from error responses.
8. `Secure Renegotiation IS NOT supported` on TLS 1.3 is correct, not a vulnerability.

**The one-line mental model:** in TLS 1.3 the X.509 certificate does not encrypt — it **signs** the handshake transcript so that the ephemeral key agreement is **authenticated**. Encryption, signing, authentication: three words in the objective title, and only two of them still describe what the certificate does on a modern connection.

---

## Referencias

**LPI**
- Exam 303-300 objectives (LPIC-3 Security): https://www.lpi.org/our-certifications/exam-303-objectives/
- LPIC-3 Security certification overview: https://www.lpi.org/our-certifications/lpic-3-security-overview/

**Apache HTTPD**
- `mod_ssl` directive reference: https://httpd.apache.org/docs/2.4/mod/mod_ssl.html
- SSL/TLS Strong Encryption: How-To: https://httpd.apache.org/docs/2.4/ssl/ssl_howto.html
- SSL/TLS Strong Encryption: FAQ: https://httpd.apache.org/docs/2.4/ssl/ssl_faq.html
- SSL/TLS Strong Encryption: Compatibility: https://httpd.apache.org/docs/2.4/ssl/ssl_compat.html
- Name-based virtual host support (SNI): https://httpd.apache.org/docs/2.4/vhosts/name-based.html
- `mod_md` (ACME / Let's Encrypt): https://httpd.apache.org/docs/2.4/mod/mod_md.html
- `mod_headers`: https://httpd.apache.org/docs/2.4/mod/mod_headers.html
- `apachectl`: https://httpd.apache.org/docs/2.4/programs/apachectl.html

**OpenSSL**
- `s_client`: https://docs.openssl.org/master/man1/openssl-s_client/
- `s_server`: https://docs.openssl.org/master/man1/openssl-s_server/
- `x509`: https://docs.openssl.org/master/man1/openssl-x509/
- `verify` and verification error codes: https://docs.openssl.org/master/man1/openssl-verify/
- `ca`: https://docs.openssl.org/master/man1/openssl-ca/
- `ocsp`: https://docs.openssl.org/master/man1/openssl-ocsp/
- `ciphers` and cipher-list grammar: https://docs.openssl.org/master/man1/openssl-ciphers/
- `x509v3_config` (extension syntax): https://docs.openssl.org/master/man5/x509v3_config/

**IETF standards**
- RFC 5280 — X.509 PKI Certificate and CRL Profile: https://www.rfc-editor.org/rfc/rfc5280
- RFC 5246 — TLS 1.2: https://www.rfc-editor.org/rfc/rfc5246
- RFC 8446 — TLS 1.3: https://www.rfc-editor.org/rfc/rfc8446
- RFC 6066 — TLS Extensions (SNI, `status_request`): https://www.rfc-editor.org/rfc/rfc6066
- RFC 6960 — OCSP: https://www.rfc-editor.org/rfc/rfc6960
- RFC 6961 — Multiple Certificate Status Extension: https://www.rfc-editor.org/rfc/rfc6961
- RFC 7633 — TLS Feature Extension (must-staple): https://www.rfc-editor.org/rfc/rfc7633
- RFC 6797 — HTTP Strict Transport Security: https://www.rfc-editor.org/rfc/rfc6797
- RFC 6125 — Service identity in X.509: https://www.rfc-editor.org/rfc/rfc6125
- RFC 5746 — TLS Renegotiation Indication: https://www.rfc-editor.org/rfc/rfc5746
- RFC 7507 — TLS Fallback SCSV: https://www.rfc-editor.org/rfc/rfc7507
- RFC 8996 — Deprecating TLS 1.0 and 1.1: https://www.rfc-editor.org/rfc/rfc8996
- RFC 7568 — Deprecating SSLv3: https://www.rfc-editor.org/rfc/rfc7568
- RFC 8740 — Using TLS 1.3 with HTTP/2: https://www.rfc-editor.org/rfc/rfc8740
- RFC 9113 — HTTP/2: https://www.rfc-editor.org/rfc/rfc9113
- RFC 6844 / 8659 — DNS CAA: https://www.rfc-editor.org/rfc/rfc8659
- RFC 6962 — Certificate Transparency: https://www.rfc-editor.org/rfc/rfc6962

**Operational references**
- Mozilla SSL Configuration Generator: https://ssl-config.mozilla.org/
- Mozilla Server Side TLS guidelines: https://wiki.mozilla.org/Security/Server_Side_TLS
- HSTS preload list submission: https://hstspreload.org/
- CA/Browser Forum Baseline Requirements: https://cabforum.org/baseline-requirements-documents/
- cert-manager documentation: https://cert-manager.io/docs/
- Certbot user guide: https://eff-certbot.readthedocs.io/en/stable/using.html
- NIST SP 800-52 Rev. 2 — TLS guidelines: https://csrc.nist.gov/pubs/sp/800/52/r2/final