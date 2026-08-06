# LPIC-3 Security (Exam 303-300 v3.0) — Topic 331: Cryptography

---

## 1. Production Architectural Problem & System Motivation

### 1.1 The Enterprise Threat Landscape & Zero-Trust Mandate
In modern enterprise platform architecture, perimeter-only security models (such as firewall boundaries and private VLANs) fail to contain lateral movement following initial network breaches. Modern infrastructure platforms—comprising multi-region Kubernetes clusters, microservice meshes, distributed databases, and automated CI/CD pipelines—must operate under a strict **Zero-Trust Architecture (ZTA)** regime as standardized in [NIST SP 800-207](https://csrc.nist.gov/publications/detail/sp/800-207/final).

```
                      +-------------------------------------------------------------+
                      |                 UNTRUSTED EXTERNAL NETWORK                  |
                      +-------------------------------------------------------------+
                                                     |
                                                     v
                                       [ Perimeter Ingress Controller ]
                                       (TLS 1.3 / mTLS Termination)
                                                     |
             +---------------------------------------+---------------------------------------+
             |                                       |                                       |
             v                                       v                                       v
    [ Microservice A ]                      [ Microservice B ]                      [ Microservice C ]
    +----------------+                      +----------------+                      +----------------+
    | mTLS (ECDSA)   |--------------------->| mTLS (ECDSA)   |--------------------->| mTLS (ECDSA)   |
    +----------------+                      +----------------+                      +----------------+
             |                                       |                                       |
             v                                       v                                       v
+------------------------+              +------------------------+              +------------------------+
| LUKS2 Data-at-Rest     |              | LUKS2 Data-at-Rest     |              | LUKS2 Data-at-Rest     |
| (Argon2id + TPM2)      |              | (Argon2id + TPM2)      |              | (Argon2id + TPM2)      |
+------------------------+              +------------------------+              +------------------------+
             ^                                       ^                                       ^
             |                                       |                                       |
             +---------------------------------------+---------------------------------------+
                                                     |
                                       [ Internal Corporate PKI / CA ]
                                       (Offline Root + Online Sub-CA)
```

Without cryptographic identity verification, encryption in transit, and encryption at rest:
1. **Man-in-the-Middle (MitM) Attacks & Spoofing:** Plaintext internal transport exposes sensitive JWTs, API tokens, and customer PII to network eavesdropping, packet insertion, and DNS hijacking via cache poisoning.
2. **Data Exfiltration at Rest:** Stolen block storage devices, orphaned SAN volumes, or unauthorized hypervisor snapshot access leak unencrypted database records.
3. **Certificate Chain Collapses:** Misconfigured Public Key Infrastructures (PKIs) with missing X.509 v3 extensions (`basicConstraints`, `keyUsage`), weak hash algorithms (SHA-1), or broken revocation infrastructure (unreachable CRLs/OCSP) lead to service outages or fake certificate issuance.

---

## 2. Technical Architecture & Trade-Off Analysis

### 2.1 Asymmetric Cryptography: RSA vs. ECDSA vs. Ed25519

Choosing the appropriate public key cryptography scheme impacts CPU utilization, handshakes per second (HPS), memory overhead, and key storage requirements.

| Metric / Dimension | RSA (4096-bit) | ECDSA (secp256r1 / P-256) | Ed25519 (EdDSA / Curve25519) |
| :--- | :--- | :--- | :--- |
| **Security Level** | 128 bits of security | 128 bits of security | ~128 bits of security |
| **Key Size (Public/Private)** | 512 bytes / ~2.4 KB | 64 bytes / 32 bytes | 32 bytes / 32 bytes |
| **Signature Size** | 512 bytes | 64 bytes | 64 bytes |
| **Signing Performance** | Slow (~250 ops/sec) | Fast (~10,000 ops/sec) | Extremely Fast (~25,000 ops/sec) |
| **Verification Speed** | Extremely Fast (~12,000 ops/sec) | Moderate (~3,000 ops/sec) | Fast (~8,000 ops/sec) |
| **Side-Channel Protection** | Difficult to implement safely | Vulnerable to weak RNG (NIST curve) | Immune to timing attacks by design |
| **X.509/Web PKI Support** | Ubiquitous (100% legacy compatible) | Broad (All modern browsers/servers) | Growing (RFC 8410; supported in OpenSSL 1.1.1+) |

---

### 2.2 Key Derivation Functions (KDFs) for Data at Rest: PBKDF2 vs. Argon2id

When protecting encrypted block devices using LUKS2 (Linux Unified Key Setup), key derivation functions transform user passphrases into high-entropy master keys while resisting GPU/ASIC brute-force attacks.

| Characteristic | PBKDF2-HMAC-SHA256 | Argon2id (LUKS2 Default) |
| :--- | :--- | :--- |
| **Memory Hardness** | No (0 KB memory required) | High (Configurable: 32 MB – 2 GB+) |
| **CPU Hardness** | Iteration-based only | Time cost + Memory cost + Parallelism |
| **ASIC/GPU Resistance** | Extremely Low (GPUs compute billions/sec) | High (Memory bandwidth bound) |
| **Side-Channel Resistance**| Vulnerable to cache-timing attacks | Hybrid (Argon2i side-channel + Argon2d GPU resistance) |
| **NIST / Compliance Status**| NIST SP 800-132 approved | RFC 9106 / PHC Winner (Modern Standard) |

---

### 2.3 Cryptographic DNS Integrity: DNSSEC Validation vs. Plain DNS

| Feature | Standard Plain DNS | DNSSEC (Domain Name System Security Extensions) |
| :--- | :--- | :--- |
| **Authenticity Verification**| None (Trusts IP address of responder) | Cryptographic signature verification via `RRSIG` |
| **Data Integrity** | None (Susceptible to UDP injection) | Validated back to Root Anchor via `DS` and `DNSKEY` |
| **Proof of Non-Existence**| `NXDOMAIN` (Unauthenticated) | Cryptographically authenticated via `NSEC` or `NSEC3` |
| **Confidentiality** | None (Port 53 UDP/TCP plaintext) | None (Requires DoT/DoH for privacy; DNSSEC ensures integrity only) |
| **Overhead** | Minimal packet size (<512 bytes) | Increased packet size (EDNS0 needed), CPU overhead for signing/verifying |

---

## 3. Production Infrastructure Manifests & Full Configuration Files

### 3.1 Production OpenSSL Multi-Tier CA Configuration (`/etc/pki/ca/openssl.cnf`)

This complete configuration governs a 2-tier PKI infrastructure (Root CA issuing Intermediate CA, Intermediate CA issuing Server/Client Certificates) using modern X.509 v3 extensions.

```ini
# /etc/pki/ca/openssl.cnf
[ req ]
default_bits        = 4096
default_md          = sha384
default_keyfile     = privkey.pem
distinguished_name  = req_distinguished_name
attributes          = req_attributes
x509_extensions     = v3_ca
string_mask         = utf8only

[ req_distinguished_name ]
countryName                     = Country Name (2 letter code)
countryName_default             = US
countryName_min                 = 2
countryName_max                 = 2
stateOrProvinceName             = State or Province Name (full name)
stateOrProvinceName_default     = Virginia
localityName                    = Locality Name (eg, city)
localityName_default            = Reston
0.organizationName              = Organization Name (eg, company)
0.organizationName_default      = Enterprise Cloud Platform Inc
organizationalUnitName          = Organizational Unit Name (eg, section)
organizationalUnitName_default  = Security Engineering
commonName                      = Common Name (e.g. server FQDN or YOUR name)
commonName_max                  = 64
emailAddress                    = Email Address
emailAddress_default            = pki-admin@platform.internal

[ req_attributes ]

[ CA_default ]
dir             = /etc/pki/ca
certs           = $dir/certs
crl_dir         = $dir/crl
new_certs_dir   = $dir/newcerts
database        = $dir/index.txt
serial          = $dir/serial
RANDFILE        = $dir/private/.rand

private_key     = $dir/private/ca.key
certificate     = $dir/certs/ca.crt

crlnumber       = $dir/crlnumber
crl             = $dir/crl/ca.crl
crl_extensions  = crl_ext
default_crl_days= 30
default_days    = 365
default_md      = sha384
preserve        = no
policy          = policy_strict

[ policy_strict ]
countryName             = match
stateOrProvinceName     = match
organizationName        = match
organizationalUnitName  = optional
commonName              = supplied
emailAddress            = optional

[ policy_loose ]
countryName             = optional
stateOrProvinceName     = optional
localityName            = optional
organizationName        = optional
organizationalUnitName  = optional
commonName              = supplied
emailAddress            = optional

[ v3_ca ]
subjectKeyIdentifier    = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints        = critical, CA:true
keyUsage                = critical, digitalSignature, cRLSign, keyCertSign

[ v3_intermediate_ca ]
subjectKeyIdentifier    = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints        = critical, CA:true, pathlen:0
keyUsage                = critical, digitalSignature, cRLSign, keyCertSign
authorityInfoAccess     = caIssuers;URI:http://pki.platform.internal/ca.crt
crlDistributionPoints   = URI:http://pki.platform.internal/ca.crl

[ server_cert ]
basicConstraints        = CA:FALSE
nsCertType              = server
nsComment               = "Production Server Certificate"
subjectKeyIdentifier    = hash
authorityKeyIdentifier = keyid,issuer:always
keyUsage                = critical, digitalSignature, keyEncipherment
extendedKeyUsage        = serverAuth
crlDistributionPoints   = URI:http://pki.platform.internal/intermediate.crl
authorityInfoAccess     = caIssuers;URI:http://pki.platform.internal/intermediate.crt

[ client_cert ]
basicConstraints        = CA:FALSE
nsCertType              = client
nsComment               = "Production mTLS Client Certificate"
subjectKeyIdentifier    = hash
authorityKeyIdentifier = keyid,issuer:always
keyUsage                = critical, nonRepudiation, digitalSignature, keyEncipherment
extendedKeyUsage        = clientAuth
crlDistributionPoints   = URI:http://pki.platform.internal/intermediate.crl

[ crl_ext ]
authorityKeyIdentifier=keyid:always
```

---

### 3.2 CFSSL Automated PKI Configuration (`/etc/cfssl/config.json` & `/etc/cfssl/csr_server.json`)

Cloudflare's PKI toolkit (CFSSL) provides REST API-driven certificate generation for dynamic microservices.

```json
{
  "signing": {
    "default": {
      "expiry": "8760h"
    },
    "profiles": {
      "intermediate_ca": {
        "usages": ["cert sign", "crl sign"],
        "expiry": "43800h",
        "ca_constraint": {
          "is_ca": true,
          "max_path_len": 0
        }
      },
      "server": {
        "usages": [
          "signing",
          "key encipherment",
          "server auth"
        ],
        "expiry": "2160h"
      },
      "client": {
        "usages": [
          "signing",
          "key encipherment",
          "client auth"
        ],
        "expiry": "2160h"
      }
    }
  }
}
```

CSR Spec Template (`/etc/cfssl/csr_server.json`):

```json
{
  "CN": "api.platform.internal",
  "hosts": [
    "api.platform.internal",
    "10.96.0.10",
    "127.0.0.1"
  ],
  "key": {
    "algo": "ecdsa",
    "size": 256
  },
  "names": [
    {
      "C": "US",
      "ST": "Virginia",
      "L": "Reston",
      "O": "Enterprise Cloud Platform Inc",
      "OU": "Platform Infrastructure"
    }
  ]
}
```

---

### 3.3 High-Security Apache 2.4+ VirtualHost Configuration (`/etc/httpd/conf.d/secure-vhost.conf`)

Includes TLS 1.3/1.2 enforcement, ECDHE key exchange, OCSP stapling, mTLS client verification, and HSTS response headers.

```apache
# /etc/httpd/conf.d/secure-vhost.conf

# Enable OCSP Stapling cache globally
SSLStaplingCache default:shmcb:/run/httpd/ssl_stapling(3276800)

<VirtualHost *:443>
    ServerName api.platform.internal:443
    DocumentRoot /var/www/html

    SSLEngine on
    
    # Enable explicit TLS versions only
    SSLProtocol -all +TLSv1.2 +TLSv1.3

    # Hardened TLS 1.2 Ciphersuite string (TLS 1.3 ciphers suites are non-configurable in Apache and auto-enabled)
    SSLCipherSuite ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305
    SSLHonorCipherOrder off
    SSLSessionTickets off

    # Server Identity Certificates
    SSLCertificateFile /etc/pki/tls/certs/api.platform.internal.crt
    SSLCertificateKeyFile /etc/pki/tls/private/api.platform.internal.key
    SSLCertificateChainFile /etc/pki/tls/certs/intermediate-chain.crt

    # Enable OCSP Stapling
    SSLUseStapling on
    SSLStaplingResponderTimeout 5
    SSLStaplingReturnResponderErrors off

    # Mutual TLS (mTLS) Client Authentication Setup
    SSLCACertificateFile /etc/pki/tls/certs/client-ca-bundle.crt
    SSLVerifyClient require
    SSLVerifyDepth 2

    # HTTP Strict Transport Security (HSTS) - 2 years max-age with subdomains & preload
    Header always set Strict-Transport-Security "max-age=63072000; includeSubDomains; preload"
    Header always set X-Content-Type-Options "nosniff"
    Header always set X-Frame-Options "DENY"

    <Directory /var/www/html>
        Options FollowSymLinks
        AllowOverride None
        Require valid-user
    </Directory>

    ErrorLog /var/log/httpd/tls_error.log
    CustomLog /var/log/httpd/tls_access.log "%h %l %u %t \"%r\" %>s %b \"%{SSL_PROTOCOL}x\" \"%{SSL_CIPHER}x\""
</VirtualHost>
```

---

### 3.4 BIND 9 Authoritative DNSSEC Configuration (`/etc/named.conf` & Zone File)

```named
// /etc/named.conf
options {
    directory "/var/named";
    dump-file "/var/named/data/cache_dump.db";
    statistics-file "/var/named/data/named_stats.txt";
    memstatistics-file "/var/named/data/named_mem_stats.txt";
    secroots-file "/var/named/data/named.secroots";
    recursing-file "/var/named/data/named.recursing";

    listen-on port 53 { any; };
    listen-on-v6 port 53 { ::1; };

    allow-query { any; };
    
    # Enable DNSSEC Validation
    dnssec-validation auto;
    
    auth-nxdomain no;    # conform to RFC1035
};

# Automatic Inline Signing Policy
dnssec-policy "ecdsa-p256-policy" {
    keys {
        ksk lifetime unlimited algorithm ecdsap256sha256;
        zsk lifetime 60d algorithm ecdsap256sha256;
    };
};

zone "platform.internal" IN {
    type primary;
    file "dynamic/platform.internal.db";
    inline-signing yes;
    dnssec-policy "ecdsa-p256-policy";
    allow-transfer { 10.96.0.2; };
};
```

Unsigned Zone File (`/var/named/dynamic/platform.internal.db`):

```text
$TTL 86400
@   IN  SOA ns1.platform.internal. admin.platform.internal. (
            2026080601  ;Serial
            3600        ;Refresh
            1800        ;Retry
            604800      ;Expire
            86400 )     ;Minimum TTL
;
@   IN  NS  ns1.platform.internal.
ns1 IN  A   10.96.0.1
api IN  A   10.96.0.10
```

---

### 3.5 Production LUKS2 Systemd Encrypted Storage Manifest (`/etc/crypttab` & `/etc/fstab`)

`/etc/crypttab`:
```text
# <name>           <device>                                 <keyfile>                  <options>
secure_storage_db  UUID=c1482f3a-9642-498c-9b88-12d83fca2198  none                       luks,discard,key-slot=0,tpm2-device=auto,tpm2-pcrs=0+7
```

`/etc/fstab`:
```text
# <file system>            <mount point>        <type>  <options>                  <dump>  <pass>
/dev/mapper/secure_storage_db /var/lib/postgresql  xfs     defaults,noatime,nodev     0       2
```

---

## 4. Hands-On CLI Execution & Real Terminal Outputs

### 4.1 Step-by-Step PKI Initialization via OpenSSL

#### Step 1: Initialize Root CA Structure & Directory Hierarchy
```bash
$ sudo mkdir -p /etc/pki/ca/{certs,crl,newcerts,private}
$ sudo chmod 700 /etc/pki/ca/private
$ sudo touch /etc/pki/ca/index.txt
$ echo 1000 | sudo tee /etc/pki/ca/serial
$ echo 1000 | sudo tee /etc/pki/ca/crlnumber
```
*Output:*
```text
1000
1000
```

#### Step 2: Generate Offline Root CA ECDSA Key & Self-Signed Root Certificate
```bash
$ sudo openssl ecparam -name prime256v1 -genkey -noout -out /etc/pki/ca/private/root-ca.key
$ sudo chmod 400 /etc/pki/ca/private/root-ca.key
$ sudo openssl req -config /etc/pki/ca/openssl.cnf \
    -key /etc/pki/ca/private/root-ca.key \
    -new -x509 -days 7300 -sha384 -extensions v3_ca \
    -subj "/C=US/ST=Virginia/L=Reston/O=Enterprise Cloud Platform Inc/CN=Root Platform CA" \
    -out /etc/pki/ca/certs/root-ca.crt
```
*Output verification:*
```bash
$ openssl x509 -in /etc/pki/ca/certs/root-ca.crt -text -noout | grep -A 5 "X509v3 extensions"
```
*Expected Output:*
```text
        X509v3 extensions:
            X509v3 Subject Key Identifier: 
                B6:3E:92:DF:A1:4B:08:92:52:CD:71:08:21:40:91:6A:F9:8D:1C:E2
            X509v3 Authority Key Identifier: 
                keyid:B6:3E:92:DF:A1:4B:08:92:52:CD:71:08:21:40:91:6A:F9:8D:1C:E2
            X509v3 Basic Constraints: critical
                CA:TRUE
            X509v3 Key Usage: critical
                Certificate Sign, CRL Sign
```

#### Step 3: Issue Intermediate CA Signed by Root CA
```bash
# Generate Intermediate Key & CSR
$ sudo openssl ecparam -name prime256v1 -genkey -noout -out /etc/pki/ca/private/intermediate.key
$ sudo openssl req -config /etc/pki/ca/openssl.cnf -new \
    -key /etc/pki/ca/private/intermediate.key \
    -subj "/C=US/ST=Virginia/L=Reston/O=Enterprise Cloud Platform Inc/OU=Security Engineering/CN=Intermediate Issuing CA" \
    -out /etc/pki/ca/intermediate.csr

# Sign CSR with Root CA using v3_intermediate_ca extension
$ sudo openssl ca -config /etc/pki/ca/openssl.cnf -extensions v3_intermediate_ca \
    -days 3650 -notext -md sha384 \
    -in /etc/pki/ca/intermediate.csr \
    -out /etc/pki/ca/certs/intermediate.crt -batch
```
*Expected Output:*
```text
Using configuration from /etc/pki/ca/openssl.cnf
Check that the request matches the signature
Signature ok
The Subject's Distinguished Name is as follows
countryName           :PRINTABLE:'US'
stateOrProvinceName   :ASN1_STRING:'Virginia'
organizationName      :ASN1_STRING:'Enterprise Cloud Platform Inc'
organizationalUnitName:ASN1_STRING:'Security Engineering'
commonName            :ASN1_STRING:'Intermediate Issuing CA'
Certificate is to be certified until Aug  1 17:24:10 2036 GMT (3650 days)

Write out database with 1 new entries
Data Base Updated
```

#### Step 4: Issue Server Certificate with Subject Alternative Names (SANs)
```bash
# Generate Server Private Key and CSR
$ openssl ecparam -name prime256v1 -genkey -noout -out api.platform.internal.key
$ openssl req -new -key api.platform.internal.key \
    -subj "/C=US/ST=Virginia/O=Enterprise Cloud Platform Inc/CN=api.platform.internal" \
    -addext "subjectAltName = DNS:api.platform.internal, DNS:api-backup.platform.internal, IP:10.96.0.10" \
    -out api.platform.internal.csr

# Sign Server Certificate using Intermediate CA
$ sudo openssl ca -config /etc/pki/ca/openssl.cnf \
    -cert /etc/pki/ca/certs/intermediate.crt \
    -keyfile /etc/pki/ca/private/intermediate.key \
    -extensions server_cert -days 730 -notext -md sha384 \
    -in api.platform.internal.csr \
    -out api.platform.internal.crt -batch
```
*Expected Output:*
```text
Using configuration from /etc/pki/ca/openssl.cnf
Signature ok
Certificate is to be certified until Aug  6 17:24:10 2028 GMT (730 days)
Write out database with 1 new entries
Data Base Updated
```

---

### 4.2 Automated Certificate Lifecycle via Let's Encrypt / Certbot

#### Issue Sanctioned Certificate via Standalone ACME Protocol
```bash
$ sudo certbot certonly --standalone \
    --non-interactive \
    --agree-tos \
    --email admin@platform.internal \
    -d api.platform.internal \
    --key-type ecdsa \
    --elliptic-curve secp256r1 \
    --dry-run
```
*Expected Output:*
```text
Saving debug log to /var/log/letsencrypt/letsencrypt.log
Plugins selected: Authenticator standalone, Installer None
Simulating a certificate request for api.platform.internal
Performing the following challenges:
http-01 challenge for api.platform.internal
Waiting for verification...
Cleaning up challenges
The dry run was successful.
```

---

### 4.3 LUKS2 Block Device Encrypted Setup with Argon2id & Systemd-Cryptenroll (TPM2)

#### Step 1: Format Storage Partition with LUKS2 & Argon2id KDF
```bash
$ sudo cryptsetup luksFormat \
    --type luks2 \
    --cipher aes-xts-plain64 \
    --key-size 512 \
    --hash sha512 \
    --pbkdf argon2id \
    --pbkdf-memory 1048576 \
    --pbkdf-parallel 4 \
    --label "SECURE_DATA" \
    /dev/sdb1
```
*Expected Output:*
```text
WARNING!
========
This will overwrite data on /dev/sdb1 irrevocably.

Are you sure? (Type 'yes' in capital letters): YES
Enter passphrase for /dev/sdb1: 
Verify passphrase: 
Command successful.
```

#### Step 2: Bind LUKS2 Key Slot 1 to TPM2 (PCTR 0+7) for Automatic Decryption
```bash
$ sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=0+7 /dev/sdb1
```
*Expected Output:*
```text
🔐 Secret registered in TPM2 PCRs 0+7.
New key slot 1 assigned on /dev/sdb1.
```

#### Step 3: Open Device Mapping & Inspect LUKS Metadata Header
```bash
$ sudo cryptsetup open /dev/sdb1 secure_storage_db
$ sudo cryptsetup luksDump /dev/sdb1
```
*Expected Output:*
```text
LUKS header information
Version:        2
Epoch:          3
Metadata area:  16384 bytes
Keyslots size:  16744448 bytes
UUID:           c1482f3a-9642-498c-9b88-12d83fca2198
Subkeyslot:     0
Label:          SECURE_DATA

Data segments:
  0: crypt
	offset: 16777216 [bytes]
	length: (default)
	cipher: aes-xts-plain64
	sector_size: 512 [bytes]

Keyslots:
  0: luks2
	Digest:      0
	KDF:         argon2id
	Time cost:   4
	Memory:      1048576
	Threads:     4
  1: tpm2
	Digest:      1
	PCRs:        0,7
```

---

### 4.4 DNSSEC Key Generation, Zone Signing & Query Validation

#### Step 1: Query DNSSEC Records using `dig` and `delv`
```bash
$ dig +dnssec +multi SOA platform.internal @10.96.0.1
```
*Expected Output:*
```text
; <<>> DiG 9.16.23-RH <<>> +dnssec +multi SOA platform.internal @10.96.0.1
;; global options: +cmd
;; Got answer:
;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 48912
;; flags: qr aa rd ra; QUERY: 1, ANSWER: 2, AUTHORITY: 0, ADDITIONAL: 1

;; OPT PSEUDOSECTION:
; EDNS: version 0, flags: do; udp: 1220
;; QUESTION SECTION:
;platform.internal.	IN SOA

;; ANSWER SECTION:
platform.internal.	86400 IN SOA ns1.platform.internal. admin.platform.internal. (
				2026080601 ; serial
				3600       ; refresh
				1800       ; retry
				604800     ; expire
				86400      ; minimum
				)
platform.internal.	86400 IN RRSIG SOA 13 2 86400 (
				20260905120000 20260806120000 34812 platform.internal.
				+kG4x8Kz6mQ/3E0F9d8zGqL12nQ9m4A8sD7fZ0yX1cM= )

;; Query time: 1 msec
;; SERVER: 10.96.0.1#53(10.96.0.1)
;; WHEN: Thu Aug 06 13:24:05 EDT 2026
;; MSG SIZE  rcvd: 247
```

#### Step 2: Validate Trust Chain using `delv`
```bash
$ delv @10.96.0.1 -a /var/named/trusted-key.key platform.internal SOA +rtrace
```
*Expected Output:*
```text
;; fetch: platform.internal/SOA
;; Current trust anchors:
;; platform.internal. 86400 IN DS 34812 13 2 8D4B0F1A293E...
;; fully validated
; fully validated
platform.internal.	86400 IN SOA ns1.platform.internal. admin.platform.internal. 2026080601 3600 1800 604800 86400
platform.internal.	86400 IN RRSIG SOA 13 2 86400 20260905120000 20260806120000 34812 platform.internal. +kG4x8Kz...
```

---

## 5. Production Troubleshooting, Failure Diagnostics & Verification Matrix

### 5.1 X.509 PKI & TLS Troubleshooting Matrix

```
                     [ TLS Handshake Error / Connection Failure ]
                                          |
                        +-----------------+-----------------+
                        |                                   |
            (Server-Side Error Log)               (Client Connection Test)
                        |                                   |
       +----------------+----------------+         +--------+--------+
       |                                 |         |                 |
[ Bad Certificate Chain ]       [ OCSP Stapling Timeout ] [ Cipher Mismatch ]  [ mTLS Reject ]
openssl verify -CAfile        openssl s_client        openssl s_client     openssl s_client
intermediate.crt server.crt   -status -tlsextdebug    -cipher ...          -cert client.crt
```

| Symptom / Error Message | Root Cause | Diagnostic Command | Remediation Action |
| :--- | :--- | :--- | :--- |
| `SSL3_GET_SERVER_CERTIFICATE: certificate verify failed (unable to get local issuer certificate)` | Intermediate CA missing from server payload. | `openssl s_client -connect api.platform.internal:443 -showcerts` | Append `intermediate.crt` to `SSLCertificateChainFile` or bundle it in `SSLCertificateFile`. |
| `TLS error: Hostname mismatch / Certificate Subject Alternative Name missing` | Certificate lacks SAN field for requested FQDN. | `openssl x509 -in cert.crt -text -noout \| grep -A1 "Subject Alternative Name"` | Re-issue certificate with explicit `-addext "subjectAltName=DNS:..."`. |
| `OCSP response error: certificate status unknown` | OCSP responder URL specified in AIA extension is unreachable or un-updated. | `openssl ocsp -issuer intermediate.crt -cert server.crt -url http://ocsp.platform.internal` | Update CRL/OCSP responder daemon or disable `SSLUseStapling` temporarily. |
| `cryptsetup: Device /dev/sdb1 is busy` | Active dm-crypt target holds unmounted device file locks. | `sudo lsof /dev/mapper/secure_storage_db` or `sudo dmsetup info -c` | Unmount filesystem, stop downstream services, run `cryptsetup close <name>`. |
| `DNSSEC validation failure: SERVFAIL (RRSIG expired)` | System clock drift on validating resolver or zone re-signing job stalled. | `delv +rtrace platform.internal SOA` | Re-synchronize node clock via NTP (`chronyc tracking`) and force BIND re-sign (`rndc sign platform.internal`). |

---

### 5.2 Deep-Dive Diagnostic Workflows

#### 1. Verifying Complete Trust Chain Validation
```bash
$ openssl verify -show_chain -CAfile /etc/pki/ca/certs/root-ca.crt \
    -untrusted /etc/pki/ca/certs/intermediate.crt \
    api.platform.internal.crt
```
*Expected Successful Output:*
```text
api.platform.internal.crt: OK
Chain:
depth=0: CN = api.platform.internal (untrusted)
depth=1: C = US, ST = Virginia, O = Enterprise Cloud Platform Inc, OU = Security Engineering, CN = Intermediate Issuing CA (untrusted)
depth=2: C = US, ST = Virginia, L = Reston, O = Enterprise Cloud Platform Inc, CN = Root Platform CA
```

#### 2. Live TLS 1.3 Handshake Inspection & OCSP Verification
```bash
$ openssl s_client -connect api.platform.internal:443 \
    -servername api.platform.internal \
    -CAfile /etc/pki/ca/certs/root-ca.crt \
    -status -tls1_3
```
*Key Sections in Terminal Output to Inspect:*
```text
CONNECTED(00000003)
OCSP response: 
======================================
OCSP Response Data:
    OCSP Response Status: successful (0x0)
    Cert Status: good
    This Update: Aug  6 12:00:00 2026 GMT
    Next Update: Aug 13 12:00:00 2026 GMT
---
SSL handshake has read 3412 bytes and written 380 bytes
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

#### 3. Diagnosing LUKS2 Key Slot Problems & Header Verification
```bash
$ sudo cryptsetup luksDump /dev/sdb1 --debug
```
If key slot recovery fails or corruption occurs, restore header from offline backup:
```bash
$ sudo cryptsetup luksHeaderBackup /dev/sdb1 --header-backup-file /safe/location/sdb1_header.bak
$ sudo cryptsetup luksHeaderRestore /dev/sdb1 --header-backup-file /safe/location/sdb1_header.bak
```

---

## 6. References & Official Sources

1. **Linux Professional Institute (LPI) Official Objectives:**
   - [LPIC-3 Security Overview](https://www.lpi.org/our-certifications/lpic-3-303-overview/)
   - [LPI Wiki: LPIC-303 Objectives V3.0 (Topic 331 Cryptography)](https://wiki.lpi.org/wiki/LPIC-303_Objectives_V3.0)

2. **X.509 PKI & OpenSSL Standard Documentation:**
   - [OpenSSL official documentation & configuration syntax](https://www.openssl.org/docs/)
   - [RFC 5280: Internet X.509 Public Key Infrastructure Certificate and Certificate Revocation List (CRL) Profile](https://datatracker.ietf.org/doc/html/rfc5280)
   - [Cloudflare PKI (CFSSL) Manual & API Specs](https://github.com/cloudflare/cfssl)

3. **Service Security & TLS Infrastructure:**
   - [Apache HTTP Server Version 2.4 - SSL/TLS Strong Encryption How-To](https://httpd.apache.org/docs/2.4/ssl/ssl_howto.html)
   - [Mozilla TLS Configuration Generator & Server Side TLS Guidelines](https://wiki.mozilla.org/Security/Server_Side_TLS)

4. **Data at Rest Encryption (LUKS / dm-crypt):**
   - [Gitlab GitLab / LUKS2 Cryptsetup Official Documentation](https://gitlab.com/cryptsetup/cryptsetup/-/wikis/home)
   - [systemd-cryptenroll Specification & TPM2 Integration](https://www.freedesktop.org/software/systemd/man/systemd-cryptenroll.html)

5. **DNSSEC Integrity:**
   - [BIND 9 Administrator Reference Manual (ARM) - DNSSEC Security](https://bind9.readthedocs.io/en/v9_18/dnssec-guide.html)
   - [RFC 4033: DNS Security Introduction and Requirements](https://datatracker.ietf.org/doc/html/rfc4033)