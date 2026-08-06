# LPIC-3 Exam 303-300 (Version 3.0) — Topic 331: Enterprise Cryptography

## Official References & Standards
- [LPI LPIC-3 303 Exam Objectives (v3.0)](https://www.lpi.org/our-certifications/lpic-3-303-overview/)
- [RFC 5280: Internet X.509 Public Key Infrastructure Certificate and Certificate Revocation List (CRL) Profile](https://datatracker.ietf.org/doc/html/rfc5280)
- [RFC 8446: The Transport Layer Security (TLS) Protocol Version 1.3](https://datatracker.ietf.org/doc/html/rfc8446)
- [RFC 6960: X.509 Internet Public Key Infrastructure Online Certificate Status Protocol - OCSP](https://datatracker.ietf.org/doc/html/rfc6960)
- [RFC 4033: DNS Security Introduction and Requirements](https://datatracker.ietf.org/doc/html/rfc4033)
- [OpenSSL Cryptographic Library Documentation](https://www.openssl.org/docs/)
- [Linux Kernel dm-crypt / LUKS Documentation](https://gitlab.com/cryptsetup/cryptsetup/)

---

## 1. Architectural Foundations & Internal Mechanics

### 1.1 X.509v3 PKI Mechanics, Certificate Lifecycle, and Revocation
An X.509v3 certificate binds a public key to an identity (Distinguished Name or Subject Alternative Name) via a digital signature produced by a trusted Certification Authority (CA).

```
                        +---------------------------------+
                        |         Offline Root CA         |
                        | (Self-Signed, RSA 4096 / P-384) |
                        +---------------------------------+
                                         |
                                         | Signs Intermediate CSR
                                         v
                        +---------------------------------+
                        |         Intermediate CA         |
                        |  (BasicConstraints: CA:TRUE)    |
                        +---------------------------------+
                                         |
                                         | Signs End-Entity CSR
                                         v
                        +---------------------------------+
                        |      End-Entity Certificate     |
                        |   (BasicConstraints: CA:FALSE)  |
                        +---------------------------------+
```

#### X.509v3 Extension Mechanics
- `basicConstraints = critical, CA:TRUE, pathlen:0`: Specifies whether the subject is a CA. If `pathlen:0`, this Intermediate CA can sign end-entity certificates, but cannot issue subordinate CAs.
- `keyUsage = critical, digitalSignature, keyEncipherment`: Constrains raw cryptographic operations (e.g., signing packets vs. encrypting symmetric session keys).
- `extendedKeyUsage = serverAuth, clientAuth`: Specifies high-level protocol roles (TLS Server vs. TLS Client).
- `subjectAltName = DNS:example.com, IP:192.168.1.50`: The modern standard for hostname validation. Modern browsers and TLS stacks strictly ignore `CommonName` (CN) for identity verification.

#### Revocation Architectures: CRL vs. OCSP Stapling
1. **Certificate Revocation Lists (CRLs)**: A DER/PEM file signed by the CA containing serial numbers of revoked certificates.
   - *Trade-off*: High latency, bandwidth consumption, and privacy leakage (clients query the CA for every validation).
2. **OCSP Stapling (RFC 6066)**: The TLS server periodically queries the CA's OCSP responder, receives a time-stamped, CA-signed OCSP assertion, and "staples" it to the initial TLS Handshake (`ServerHello`).
   - *Trade-off*: Eliminates client-side latency and privacy leaks; requires the web server to have egress access to the CA's OCSP URI.

---

### 1.2 TLS 1.3 Mechanics, Cipher Suites, and mTLS
TLS 1.3 (RFC 8446) reduces handshake latency to **1-RTT** (or 0-RTT for resumed sessions) and deprecates insecure cryptographic primitives (RSA key exchange, CBC ciphers, SHA-1, RC4).

```
Client                                                  Server
   |                                                      |
   | ClientHello                                          |
   |  + Key_Share (ECDHE: X25519)                         |
   |  + Signature_Algorithms (ecdsa_secp256r1_sha256)     |
   |  + Supported_Versions (TLS 1.3)                      |
   | ---------------------------------------------------> |
   |                                                      |
   |                                          ServerHello |
   |                               + Key_Share (X25519)   |
   |                                 {EncryptedExtensions}|
   |                                 {CertificateRequest} |
   |                                        {Certificate} |
   |                                  {CertificateVerify} |
   |                                           {Finished} |
   | <--------------------------------------------------- |
   |                                                      |
   | {Certificate} (if mTLS requested)                    |
   | {CertificateVerify}                                  |
   | {Finished}                                           |
   | ---------------------------------------------------> |
   |                                                      |
   | [Application Data Encrypted with AES-256-GCM]         |
   | <==================================================> |
```

#### Ephemeral Diffie-Hellman (ECDHE) & Forward Secrecy
In TLS 1.3, key exchange **must** use Ephemeral Diffie-Hellman (ECDHE with curve X25519 or P-256). Even if a server's private key is compromised in the future, past recorded traffic cannot be decrypted because key exchange material is discarded from RAM immediately after session key derivation.

#### Mutual TLS (mTLS) Protocol Flow
When `CertificateRequest` is sent by the server, the client must present an X.509 certificate whose signature is validated against the server's configured `SSLCACertificateFile` trust store.

---

### 1.3 Storage Cryptography: LUKS2 & dm-crypt Architecture
`dm-crypt` is a Linux kernel subsystem providing transparent block-device encryption. `LUKS2` (Linux Unified Key Setup v2) provides the on-disk header format.

```
+-------------------------------------------------------------------------------+
|                               LUKS2 On-Disk Header                            |
| +---------------------+ +-----------------------+ +-------------------------+ |
| | JSON Metadata Area  | | Key Slot 0 (Argon2id) | | Key Slot 1 (Argon2id)   | |
| +---------------------+ +-----------------------+ +-------------------------+ |
+-------------------------------------------------------------------------------+
                                         |
                                         | Decrypts Master Key using Passphrase
                                         v
+-------------------------------------------------------------------------------+
|                       Volume Master Key (256-bit AES)                         |
+-------------------------------------------------------------------------------+
                                         |
                                         | Passed to Kernel dm-crypt Engine
                                         v
+-------------------------------------------------------------------------------+
|            Enables XTS-AES-256 Encryption on Raw Block Device                 |
+-------------------------------------------------------------------------------+
```

#### Key Components:
1. **Volume Master Key**: A random key used to encrypt the payload data. It never changes when user passphrases are updated.
2. **Key Slots**: LUKS2 supports up to 32 key slots. Each slot stores an encrypted copy of the Master Key, protected by an individual passphrase or keyfile using **Argon2id** (memory-hard Key Derivation Function resistant to GPU/ASIC brute-forcing).
3. **Anti-Forensic Information Splitter (AFSplit)**: Prevents partial key recovery by spreading the key material across multiple disk sectors.

---

### 1.4 Domain Name System Security Extensions (DNSSEC) Architecture
DNSSEC provides origin authenticity and data integrity to DNS records using asymmetric cryptography.

```
       +-----------------------------------------------------------+
       | Root Zone (.) Trust Anchor (DS for 'org')                 |
       +-----------------------------------------------------------+
                                     |
                                     v
       +-----------------------------------------------------------+
       | '.org' TLD Zone (KSK signs ZSK, DS for 'example.org')     |
       +-----------------------------------------------------------+
                                     |
                                     v
       +-----------------------------------------------------------+
       | 'example.org' Zone (KSK signs ZSK, RRSIG signs 'A' Record) |
       +-----------------------------------------------------------+
```

#### Key Record Types:
- **DNSKEY**: Contains public keys (Flags: 256 = Zone Signing Key [ZSK], 257 = Key Signing Key [KSK]).
- **RRSIG**: Holds the cryptographic signature for a specific Resource Record Set (RRset).
- **DS (Delegation Signer)**: Stored in the parent zone; contains the hash of the child zone's KSK public key, establishing the **Chain of Trust**.
- **NSEC / NSEC3**: Cryptographically proves the non-existence of a DNS record (authenticated denial of existence) to prevent spoofed NXDOMAIN responses.

---

## 2. Guided Production Labs

### Lab 1: Building a Hardened Offline Root & Online Intermediate CA Hierarchy

#### Step 1.1: Create Directory Structure and Secure File System Permissions
Execute the following commands on an administrative workstation to build isolated CA directory structures.

```bash
[root@pki-node ~]# mkdir -p /etc/pki/CA/{root,intermediate}/{certs,crl,newcerts,private}
[root@pki-node ~]# chmod 700 /etc/pki/CA/{root,intermediate}/private
[root@pki-node ~]# touch /etc/pki/CA/root/index.txt /etc/pki/CA/intermediate/index.txt
[root@pki-node ~]# echo 1000 > /etc/pki/CA/root/serial
[root@pki-node ~]# echo 1000 > /etc/pki/CA/intermediate/serial
[root@pki-node ~]# echo 1000 > /etc/pki/CA/intermediate/crlnumber
```

#### Step 1.2: Define Syntactically Valid OpenSSL Configuration (`/etc/pki/CA/openssl.cnf`)
Create the authoritative configuration file governing key extensions and policy enforcement.

```ini
[ ca ]
default_ca = CA_default

[ CA_default ]
dir               = /etc/pki/CA/intermediate
certs             = $dir/certs
crl_dir           = $dir/crl
new_certs_dir     = $dir/newcerts
database          = $dir/index.txt
serial            = $dir/serial
RANDFILE          = $dir/private/.rand

private_key       = $dir/private/intermediate.key.pem
certificate       = $dir/certs/intermediate.cert.pem

crlnumber         = $dir/crlnumber
crl               = $dir/crl/intermediate.crl.pem
crl_extensions    = crl_ext
default_crl_days  = 30

default_md        = sha256
name_opt          = ca_default
cert_opt          = ca_default
default_days      = 375
preserve          = no
policy            = policy_strict

[ policy_strict ]
countryName             = match
stateOrProvinceName     = match
organizationName        = match
organizationalUnitName  = optional
commonName              = supplied
emailAddress            = optional

[ req ]
default_bits        = 4096
distinguished_name  = req_distinguished_name
string_mask         = utf8only
default_md          = sha256
x509_extensions     = v3_ca

[ req_distinguished_name ]
countryName                     = Country Name (2 letter code)
stateOrProvinceName             = State or Province Name
localityName                    = Locality Name
0.organizationName              = Organization Name
organizationalUnitName          = Organizational Unit Name
commonName                      = Common Name

[ v3_ca ]
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints = critical, CA:true
keyUsage = critical, digitalSignature, cRLSign, keyCertSign

[ v3_intermediate_ca ]
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints = critical, CA:true, pathlen:0
keyUsage = critical, digitalSignature, cRLSign, keyCertSign

[ server_cert ]
basicConstraints = CA:FALSE
nsCertType = server
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[ client_cert ]
basicConstraints = CA:FALSE
nsCertType = client
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
keyUsage = critical, nonRepudiation, digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth

[ crl_ext ]
authorityKeyIdentifier=keyid:always
```

#### Step 1.3: Generate Encrypted Root CA Key & Self-Signed Root Certificate
Generate a 4096-bit RSA Root Key encrypted with AES-256 and issue a 10-year Root Certificate.

```bash
[root@pki-node ~]# openssl genrsa -aes256 -out /etc/pki/CA/root/private/root.key.pem 4096
Enter pass phrase for root.key.pem: TopSecretRootPassphrase123!
Verifying - Enter pass phrase for root.key.pem: TopSecretRootPassphrase123!
[root@pki-node ~]# chmod 400 /etc/pki/CA/root/private/root.key.pem

[root@pki-node ~]# openssl req -config /etc/pki/CA/openssl.cnf \
      -key /etc/pki/CA/root/private/root.key.pem \
      -new -x509 -days 3650 -sha256 -extensions v3_ca \
      -out /etc/pki/CA/root/certs/root.cert.pem \
      -subj "/C=US/ST=Texas/L=Austin/O=Production Enterprise/CN=Enterprise Root CA"
Enter pass phrase for root.key.pem: TopSecretRootPassphrase123!
```

#### Step 1.4: Generate Intermediate CA Key and Sign Request
Generate an EC P-384 key for the Intermediate CA, generate a CSR, and sign it using the Root CA with `pathlen:0`.

```bash
[root@pki-node ~]# openssl ecparam -name secp384r1 -genkey | \
  openssl ec -aes256 -out /etc/pki/CA/intermediate/private/intermediate.key.pem
Enter PEM pass phrase: IntermediatePassphrase456!
Verifying - Enter PEM pass phrase: IntermediatePassphrase456!
[root@pki-node ~]# chmod 400 /etc/pki/CA/intermediate/private/intermediate.key.pem

[root@pki-node ~]# openssl req -config /etc/pki/CA/openssl.cnf -new -sha256 \
      -key /etc/pki/CA/intermediate/private/intermediate.key.pem \
      -out /etc/pki/CA/intermediate/csr/intermediate.csr.pem \
      -subj "/C=US/ST=Texas/L=Austin/O=Production Enterprise/CN=Enterprise Issuing CA v1"
Enter pass phrase for intermediate.key.pem: IntermediatePassphrase456!

[root@pki-node ~]# openssl ca -config /etc/pki/CA/openssl.cnf -name CA_default \
      -keyfile /etc/pki/CA/root/private/root.key.pem \
      -cert /etc/pki/CA/root/certs/root.cert.pem \
      -extensions v3_intermediate_ca -days 1825 -notext -md sha256 \
      -in /etc/pki/CA/intermediate/csr/intermediate.csr.pem \
      -out /etc/pki/CA/intermediate/certs/intermediate.cert.pem
Enter pass phrase for root.key.pem: TopSecretRootPassphrase123!
Sign the certificate? [y/n]:y
1 out of 1 certificate requests certified, commit? [y/n]y
```

##### Expected Output Verification:
Verify that `basicConstraints` strictly shows `CA:TRUE, pathlen:0`.

```bash
[root@pki-node ~]# openssl x509 -noout -text -in /etc/pki/CA/intermediate/certs/intermediate.cert.pem
```
```text
Certificate:
    Data:
        Version: 3 (0x2)
        Serial Number: 4096 (0x1000)
        Signature Algorithm: ecdsa-with-SHA256
        Issuer: C = US, ST = Texas, L = Austin, O = Production Enterprise, CN = Enterprise Root CA
        Validity
            Not Before: Aug  6 13:00:00 2026 GMT
            Not After : Aug  5 13:00:00 2031 GMT
        Subject: C = US, ST = Texas, L = Austin, O = Production Enterprise, CN = Enterprise Issuing CA v1
        X509v3 extensions:
            X509v3 Basic Constraints: critical
                CA:TRUE, pathlen:0
            X509v3 Key Usage: critical
                Digital Signature, Certificate Sign, CRL Sign
```

#### Step 1.5: Issue End-Entity Server Certificate with SAN and Verify Chain
Create an end-entity CSR for `api.internal.net` and sign it using the Intermediate CA.

```bash
[root@pki-node ~]# openssl genrsa -out /etc/pki/CA/intermediate/private/api.internal.net.key.pem 2048
[root@pki-node ~]# chmod 400 /etc/pki/CA/intermediate/private/api.internal.net.key.pem

[root@pki-node ~]# openssl req -config /etc/pki/CA/openssl.cnf \
      -key /etc/pki/CA/intermediate/private/api.internal.net.key.pem \
      -new -sha256 -out /etc/pki/CA/intermediate/csr/api.internal.net.csr.pem \
      -subj "/C=US/ST=Texas/L=Austin/O=Production Enterprise/CN=api.internal.net"

[root@pki-node ~]# cat << EOF > /etc/pki/CA/intermediate/san.ext
[ server_cert ]
basicConstraints = CA:FALSE
nsCertType = server
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = api.internal.net
DNS.2 = api-backup.internal.net
IP.1 = 10.0.5.50
EOF

[root@pki-node ~]# openssl x509 -req -in /etc/pki/CA/intermediate/csr/api.internal.net.csr.pem \
      -CA /etc/pki/CA/intermediate/certs/intermediate.cert.pem \
      -CAkey /etc/pki/CA/intermediate/private/intermediate.key.pem \
      -CAcreateserial -out /etc/pki/CA/intermediate/certs/api.internal.net.cert.pem \
      -days 365 -sha256 -extfile /etc/pki/CA/intermediate/san.ext -section server_cert
Enter pass phrase for intermediate.key.pem: IntermediatePassphrase456!
```

#### Step 1.6: Concatenate Chain and Cryptographically Verify
Create a full chain bundle and verify cryptographic trust against the Root CA.

```bash
[root@pki-node ~]# cat /etc/pki/CA/intermediate/certs/intermediate.cert.pem /etc/pki/CA/root/certs/root.cert.pem > /etc/pki/CA/intermediate/certs/ca-chain.cert.pem
[root@pki-node ~]# openssl verify -CAfile /etc/pki/CA/root/certs/root.cert.pem \
      -untrusted /etc/pki/CA/intermediate/certs/intermediate.cert.pem \
      /etc/pki/CA/intermediate/certs/api.internal.net.cert.pem
```
##### Expected Output Verification:
```text
/etc/pki/CA/intermediate/certs/api.internal.net.cert.pem: OK
```

---

### Checkpoint Questions — Lab 1
1. **Why must the Root CA be kept offline, and what security risk does `pathlen:0` mitigate on an Intermediate CA certificate?**
2. **If an end-entity certificate contains `CommonName = api.internal.net` but lacks `subjectAltName`, how will modern TLS stacks (such as Chrome or Go standard library) handle connection establishment?**

---

### Lab 2: Hardening Apache HTTPD for TLS 1.3, mTLS, and Diagnostic Analysis

#### Step 2.1: Implement Production Apache TLS Config (`/etc/httpd/conf.d/ssl.conf`)
Configure Apache HTTPD to support **only TLS 1.3 and hardened TLS 1.2 cipher suites**, enable mTLS on the `/secure` location, and enable OCSP stapling.

```apache
Listen 443 https
SSLPassPhraseDialog exec:/usr/libexec/httpd-ssl-pass-dialog
SSLSessionCache shmcb:/run/httpd/sslcache(512000)
SSLSessionCacheTimeout 300
SSLRandomSeed startup file:/dev/urandom 2048
SSLRandomSeed connect builtin
SSLCryptoDevice builtin

# Hardened Protocol and Cipher Suites
SSLProtocol -all +TLSv1.2 +TLSv1.3
SSLCipherSuite ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305
SSLHonorCipherOrder off
SSLSessionTickets off

# OCSP Stapling Configuration
SSLUseStapling On
SSLStaplingCache shmcb:/run/httpd/ssl_stapling(32768)
SSLStaplingResponseMaxAge 7200
SSLStaplingStandardCacheTimeout 3600

<VirtualHost *:443>
    ServerName api.internal.net:443
    DocumentRoot "/var/www/html"

    SSLEngine on
    SSLCertificateFile "/etc/pki/CA/intermediate/certs/api.internal.net.cert.pem"
    SSLCertificateKeyFile "/etc/pki/CA/intermediate/private/api.internal.net.key.pem"
    SSLCertificateChainFile "/etc/pki/CA/intermediate/certs/ca-chain.cert.pem"

    # Security Headers
    Header always set Strict-Transport-Security "max-age=63072000; includeSubDomains; preload"
    Header always set X-Content-Type-Options "nosniff"

    # Client Authentication (mTLS) for Restricted Endpoint
    <Location /secure>
        SSLVerifyClient require
        SSLVerifyDepth 2
        SSLCACertificateFile "/etc/pki/CA/intermediate/certs/ca-chain.cert.pem"
        SSLOptions +StdEnvVars +ExportCertData
    </Location>
</VirtualHost>
```

#### Step 2.2: Test TLS Handshake, Protocol Negotiation, and Session Resumption using `openssl s_client`
Simulate client connections to inspect protocol negotiation and negotiated cipher suites.

```bash
[root@pki-node ~]# openssl s_client -connect 127.0.0.1:443 -servername api.internal.net \
      -CAfile /etc/pki/CA/intermediate/certs/ca-chain.cert.pem -tls1_3
```

##### Expected Output Verification:
```text
CONNECTED(00000003)
---
Certificate chain
 0 s:C = US, ST = Texas, L = Austin, O = Production Enterprise, CN = api.internal.net
   i:C = US, ST = Texas, L = Austin, O = Production Enterprise, CN = Enterprise Issuing CA v1
 1 s:C = US, ST = Texas, L = Austin, O = Production Enterprise, CN = Enterprise Issuing CA v1
   i:C = US, ST = Texas, L = Austin, O = Production Enterprise, CN = Enterprise Root CA
---
Server certificate
-----BEGIN CERTIFICATE-----
MIIF... (truncated)
-----END CERTIFICATE-----
subject=C = US, ST = Texas, L = Austin, O = Production Enterprise, CN = api.internal.net
issuer=C = US, ST = Texas, L = Austin, O = Production Enterprise, CN = Enterprise Issuing CA v1
---
No client certificate CA names sent
Server Temp Key: X25519, 253 bits
---
SSL handshake has read 3842 bytes and written 394 bytes
Verification: OK
---
New, TLSv1.3, Cipher is TLS_AES_256_GCM_SHA384
Server public key is 2048 bit
Secure Renegotiation IS NOT supported
Compression: NONE
Expansion: NONE
No ALPN negotiated
Early data was not sent
Verify return code: 0 (ok)
---
```

#### Step 2.3: Verify mTLS Authentication Enforcement
Attempt accessing `/secure` without a client certificate, expect a TLS alert error, then re-test presenting a valid client certificate issued by the Intermediate CA.

##### Test A: Connection Failure (Missing Client Certificate)
```bash
[root@pki-node ~]# curl --cacert /etc/pki/CA/intermediate/certs/ca-chain.cert.pem https://api.internal.net/secure
```
##### Expected Output Verification:
```text
curl: (56) OpenSSL SSL_read: error:14094412:SSL routines:ssl3_read_bytes:sslv3 alert handshake failure, errno 0
```

##### Test B: Successful Connection with Signed Client Certificate
Generate client cert, sign with Intermediate CA, and execute mTLS request:

```bash
[root@pki-node ~]# openssl genrsa -out /tmp/client.key 2048
[root@pki-node ~]# openssl req -new -key /tmp/client.key -out /tmp/client.csr \
      -subj "/C=US/ST=Texas/L=Austin/O=Production Enterprise/CN=sre-operator"
[root@pki-node ~]# openssl x509 -req -in /tmp/client.csr \
      -CA /etc/pki/CA/intermediate/certs/intermediate.cert.pem \
      -CAkey /etc/pki/CA/intermediate/private/intermediate.key.pem \
      -CAcreateserial -out /tmp/client.crt -days 30 -sha256
Enter pass phrase for intermediate.key.pem: IntermediatePassphrase456!

[root@pki-node ~]# curl --cacert /etc/pki/CA/intermediate/certs/ca-chain.cert.pem \
      --cert /tmp/client.crt --key /tmp/client.key \
      https://api.internal.net/secure
```
##### Expected Output Verification:
```text
HTTP/1.1 200 OK
Date: Thu, 06 Aug 2026 13:10:00 GMT
Server: Apache/2.4.57 (Red Hat Enterprise Linux)
Strict-Transport-Security: max-age=63072000; includeSubDomains; preload
```

---

### Checkpoint Questions — Lab 2
1. **What is the structural difference between setting `SSLHonorCipherOrder On` vs `Off` when negotiating TLS 1.3 vs TLS 1.2 connections?**
2. **If an attacker performs a Man-in-the-Middle (MitM) attack on an initial HTTP request before HSTS is cached by the client, how does HSTS Preloading mitigate this vulnerability?**

---

### Lab 3: Transparent Disk Encryption with LUKS2, Argon2id, and Key Slot Management

#### Step 3.1: Prepare Storage Loop Device
Create a 1GB sparse raw image and bind it to a loop device to simulate a new physical block device.

```bash
[root@storage-node ~]# dd if=/dev/zero of=/var/tmp/secure_volume.img bs=1M count=1024
1024+0 records in
1024+0 records out
1073741824 bytes (1.1 GB, 1.0 GiB) copied, 0.65213 s, 1.6 GB/s

[root@storage-node ~]# losetup -fP /var/tmp/secure_volume.img
[root@storage-node ~]# LOOP_DEV=$(losetup -j /var/tmp/secure_volume.img | cut -d: -f1)
[root@storage-node ~]# echo "Using device: ${LOOP_DEV}"
Using device: /dev/loop0
```

#### Step 3.2: Format Volume using LUKS2 and Argon2id KDF
Format the block device with LUKS2, specifying AES-XTS-256 cipher, a 512-bit volume key, and Argon2id memory-hard hashing.

```bash
[root@storage-node ~]# cryptsetup luksFormat --type luks2 \
      --cipher aes-xts-plain64 \
      --key-size 512 \
      --hash sha512 \
      --pbkdf argon2id \
      --pbkdf-memory 1048576 \
      --pbkdf-parallel 4 \
      --label "SECURE_DATA" \
      ${LOOP_DEV}

WARNING!
========
This will overwrite data on /dev/loop0 irrevocably.

Are you sure? (Type 'yes' in capital letters): YES
Enter passphrase for /dev/loop0: PrimaryPassphrase789!
Verify passphrase: PrimaryPassphrase789!
Command successful.
```

#### Step 3.3: Inspect LUKS2 Header Metadata
Dump header details to verify key slots and cryptographic specifications.

```bash
[root@storage-node ~]# cryptsetup luksDump ${LOOP_DEV}
```
##### Expected Output Verification:
```text
LUKS header information
Version:        2
Epoch:          3
Metadata area:  16384 [bytes]
Keyslots area:  16744448 [bytes]
UUID:           a1b2c3d4-e5f6-7890-abcd-1234567890ab
Label:          SECURE_DATA
Subsystem:      (no subsystem)

Data segments:
  0: crypt
	offset: 16777216 [bytes]
	length: (default)
	cipher: aes-xts-plain64
	sector: 512 [bytes]

Keyslots:
  0: luks2
	Cipher:          aes-xts-plain64
	PBKDF:           argon2id
	Time cost:       4
	Memory cost:     1048576
	Threads:         4
	Salt:            b2 8c ...
	AF striping:     4000 stripes
	Area offset:     32768 [bytes]
	Area length:     258048 [bytes]
	Digest:          0
```

#### Step 3.4: Add Keyfile Key Slot and Backup Header
Add a second key slot using a 4096-bit keyfile (ideal for automated headless mounting) and export the LUKS header for disaster recovery.

```bash
[root@storage-node ~]# mkdir -p /etc/keys
[root@storage-node ~]# dd if=/dev/urandom of=/etc/keys/vault.key bs=512 count=1
1+0 records in
1+0 records out
512 bytes copied, 0.00012 s, 4.3 MB/s
[root@storage-node ~]# chmod 400 /etc/keys/vault.key

[root@storage-node ~]# cryptsetup luksAddKey ${LOOP_DEV} /etc/keys/vault.key \
      --key-slot 1
Enter any existing passphrase: PrimaryPassphrase789!

[root@storage-node ~]# cryptsetup luksHeaderBackup ${LOOP_DEV} \
      --header-backup-file /etc/keys/secure_volume_header.bak
```

#### Step 3.5: Open Volume, Create File System, and Configure Persistent Mounts
Open the encrypted mapping using `cryptsetup`, build an XFS file system, and update `/etc/crypttab` and `/etc/fstab`.

```bash
[root@storage-node ~]# cryptsetup open --key-file /etc/keys/vault.key ${LOOP_DEV} secure_vault
[root@storage-node ~]# ls -l /dev/mapper/secure_vault
lrwxrwxrwx 1 root root 7 Aug  6 13:15 /dev/mapper/secure_vault -> ../dm-0

[root@storage-node ~]# mkfs.xfs /dev/mapper/secure_vault
meta-data=/dev/mapper/secure_vault isize=512    agcount=4, agsize=65408 blks
         =                       sectsz=512   attr=2, projid32bit=1
         =                       crc=1        finobt=1, sparse=1, rmapbt=0
         =                       reflink=1    bigtime=1 inobtcount=1
data     =                       bsize=4096   blocks=261632, imaxpct=25
         =                       sunit=0      swidth=0 blks
naming   =version 2              bsize=4096   ascii-ci=0, ftype=1
log      =internal log           bsize=4096   blocks=2560, version=2
blocks   =2560                   sectsz=512   sunit=0 blks, lazy-count=1
realtime =none                   extsz=4096   blocks=0, rtextents=0

[root@storage-node ~]# mkdir -p /mnt/secure_vault
[root@storage-node ~]# mount /dev/mapper/secure_vault /mnt/secure_vault

[root@storage-node ~]# UUID_VAL=$(cryptsetup luksUUID ${LOOP_DEV})
[root@storage-node ~]# echo "secure_vault UUID=${UUID_VAL} /etc/keys/vault.key luks,key-slot=1" >> /etc/crypttab
[root@storage-node ~]# echo "/dev/mapper/secure_vault /mnt/secure_vault xfs defaults,nofail 0 2" >> /etc/fstab
```

---

### Checkpoint Questions — Lab 3
1. **If Key Slot 0's passphrase is forgotten, can a system administrator access data using Key Slot 1? What happens if the LUKS2 header is damaged by raw sector corruption?**
2. **Why is AES-XTS mode used for block storage encryption instead of streaming AEAD modes like AES-GCM?**

---

### Lab 4: Authoritative DNSSEC Zone Signing and Trust Anchor Verification

#### Step 4.1: Configure BIND9 Authoritative Zone (`/etc/named.conf`)
Define a primary zone for `example.lab` with DNSSEC validation and inline signing enabled.

```named
options {
    directory "/var/named";
    dump-file "/var/named/data/cache_dump.db";
    statistics-file "/var/named/data/named_stats.txt";
    memstatistics-file "/var/named/data/named_mem_stats.txt";
    secroots-file "/var/named/data/named.secroots";
    recursing-file "/var/named/data/named.recursing";

    dnssec-validation auto;
    listen-on port 53 { 127.0.0.1; 10.0.5.10; };
    allow-query { any; };
};

zone "example.lab" IN {
    type primary;
    file "dynamic/example.lab.zone";
    key-directory "/var/named/keys";
    inline-signing yes;
    dnssec-policy default;
};
```

#### Step 4.2: Construct Raw Unsigned Zone File (`/var/named/dynamic/example.lab.zone`)
Create standard SOA, NS, and A records.

```zone
$TTL 86400
@   IN  SOA ns1.example.lab. admin.example.lab. (
            2026080601 ; Serial
            3600       ; Refresh
            1800       ; Retry
            604800     ; Expire
            86400 )    ; Minimum TTL

        IN  NS      ns1.example.lab.
        IN  A       10.0.5.10
ns1     IN  A       10.0.5.10
app     IN  A       10.0.5.50
db      IN  A       10.0.5.60
```

#### Step 4.3: Manual Key Generation and Zone Signing using CLI Tools
Generate RSASHA256 KSK and ZSK keys explicitly using `dnssec-keygen`, and sign the zone using `dnssec-signzone`.

```bash
[root@dns-node ~]# mkdir -p /var/named/keys
[root@dns-node ~]# cd /var/named/keys

# Generate Key Signing Key (KSK) - Flag 257
[root@dns-node keys]# dnssec-keygen -a RSASHA256 -b 2048 -f KSK -n ZONE example.lab
Kexample.lab.+008+12345

# Generate Zone Signing Key (ZSK) - Flag 256
[root@dns-node keys]# dnssec-keygen -a RSASHA256 -b 1024 -n ZONE example.lab
Kexample.lab.+008+67890

[root@dns-node keys]# chown -R named:named /var/named/keys

# Include Keys into Zone File
[root@dns-node keys]# cat << EOF >> /var/named/dynamic/example.lab.zone
\$INCLUDE /var/named/keys/Kexample.lab.+008+12345.key
\$INCLUDE /var/named/keys/Kexample.lab.+008+67890.key
EOF

# Sign the Zone File manually
[root@dns-node keys]# dnssec-signzone -A -3 $(head -c 1000 /dev/urandom | sha1sum | cut -b 1-16) \
      -N INCREMENT -o example.lab -t /var/named/dynamic/example.lab.zone
```

##### Expected Output Verification:
```text
Verifying the zone using the following algorithms: RSASHA256.
Zone signing complete:
Algorithm: RSASHA256: KSKs: 1 active, 0 stand-by, 0 revoked
                      ZSKs: 1 active, 0 stand-by, 0 revoked
/var/named/dynamic/example.lab.zone.signed created successfully.
```

#### Step 4.4: Extract DS Record for Parent Delegation
Extract the Delegation Signer (DS) record digest to submit to the parent registry.

```bash
[root@dns-node keys]# dnssec-dsfromkey Kexample.lab.+008+12345.key
```
##### Expected Output Verification:
```text
example.lab. IN DS 12345 8 1 9abcdef0123456789abcdef0123456789abcdef0
example.lab. IN DS 12345 8 2 A1B2C3D4E5F67890123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0
```

#### Step 4.5: Diagnose and Verify DNSSEC Records with `dig` and `delv`
Query DNSSEC records (`RRSIG`, `DNSKEY`) and trace cryptographic validation chains.

```bash
[root@dns-node ~]# dig @127.0.0.1 app.example.lab +dnssec +multiline
```

##### Expected Output Verification:
```text
;; ;; ANSWER SECTION:
app.example.lab.	86400 IN A 10.0.5.50
app.example.lab.	86400 IN RRSIG A 8 3 86400 (
				20260905130000 20260806130000 67890 example.lab.
				mK39s8... (truncated signature data) ...
				+a9Dq= )

;; Authority Section:
example.lab.		86400 IN NS ns1.example.lab.
example.lab.		86400 IN RRSIG NS 8 2 86400 (
				20260905130000 20260806130000 67890 example.lab.
				xP82L1... == )
```

##### Tracing Trust Anchor Chain with `delv`:
```bash
[root@dns-node ~]# delv @127.0.0.1 -a /var/named/keys/Kexample.lab.+008+12345.key +rtrace app.example.lab
```
##### Expected Output Verification:
```text
;; fetch: app.example.lab/A
;; root key trust status: trusted
;; fully validated
app.example.lab.	86400 IN A 10.0.5.50
app.example.lab.	86400 IN RRSIG A 8 3 86400 20260905130000 20260806130000 67890 example.lab. ...
```

---

### Checkpoint Questions — Lab 4
1. **What is the operational purpose of maintaining separate Key Signing Keys (KSK) and Zone Signing Keys (ZSK), rather than using a single key for all signatures?**
2. **If an authoritative server responds with an NSEC3 record upon querying a non-existent host `missing.example.lab`, how does NSEC3 prevent zone walking / enumeration compared to standard NSEC?**

---

<details>
<summary><strong>Click to Expand: Comprehension Verification Answers & Explanations</strong></summary>

### Answers to Lab 1 Checkpoint Questions
1. **Root CA Offline Rationale & Path Length Constraints**:
   - The Root CA key is the absolute trust anchor of the entire PKI ecosystem. If compromised, every certificate in the chain becomes invalid, requiring expensive re-issuance and deployment of new trust stores to all endpoints. Keeping the Root CA strictly offline (air-gapped) prevents network-based attacks.
   - `pathlen:0` strictly restricts the Intermediate CA from signing subordinate CAs. It can *only* issue end-entity certificates. If an attacker compromises the Intermediate CA's key, they cannot generate rogue sub-CAs to build deep, untracked sub-hierarchies.

2. **CommonName vs. Subject Alternative Name (SAN)**:
   - RFC 5280 and modern web security policies (RFC 6125) mandate `subjectAltName` for identity validation.
   - If `subjectAltName` is missing, modern implementations (such as Chrome, Go `crypto/tls`, and OpenSSL 3.x) will immediately reject the connection with an `x509: certificate relies on legacy Common Name field` error, regardless of whether `CommonName` matches the hostname.

---

### Answers to Lab 2 Checkpoint Questions
1. **Cipher Order Negotiation Mechanics**:
   - In **TLS 1.2**, `SSLHonorCipherOrder On` forces the server to choose the cipher suite based on its own preference list, overriding the client's preferred list. This prevents clients from choosing weaker fallback ciphers.
   - In **TLS 1.3**, `SSLHonorCipherOrder` is ignored by design. TLS 1.3 limits symmetric ciphers to five highly secure AEAD algorithms (e.g., `TLS_AES_256_GCM_SHA384`, `TLS_CHACHA20_POLY1305_SHA256`). All acceptable suites are equally secure, so client preference selection introduces no cryptographic downgrade risk.

2. **HSTS Preloading Architecture**:
   - Standard HSTS relies on "Trust on First Use" (TOFU). The client receives the `Strict-Transport-Security` HTTP header on its initial HTTPS response and caches it. However, the *very first* unencrypted HTTP request remains vulnerable to MitM interception and strip attacks (e.g., SSLstrip).
   - **HSTS Preloading** hardcodes the domain directly into browser source code distributions. Browsers automatically enforce `https://` prior to issuing any network packet, completely eliminating the initial HTTP bootstrap vulnerability.

---

### Answers to Lab 3 Checkpoint Questions
1. **LUKS2 Multi-Slot Decryption & Header Protection**:
   - Yes, any valid key slot can independently decrypt the Volume Master Key. Losing the passphrase for Key Slot 0 has zero effect on access via Key Slot 1.
   - If the on-disk LUKS2 header sectors are physically corrupted or overwritten, the Master Key is permanently lost, making payload data recovery mathematically impossible. This highlights why preserving off-host header backups (`cryptsetup luksHeaderBackup`) is essential for SRE disaster recovery.

2. **XTS-AES Mode vs. AEAD (GCM) in Block Storage**:
   - Disk sector storage requires **fixed-size read/write operations** (e.g., matching 512-byte or 4096-byte sector bounds directly).
   - Authenticated Encryption modes like AES-GCM append an Authentication Tag (typically 16 bytes per block) and require initialization vectors (IVs). This introduces data expansion, causing physical sector misalignment. **AES-XTS** is a narrow-block tweakable cipher that encrypts blocks in-place without altering data size.

---

### Answers to Lab 4 Checkpoint Questions
1. **KSK vs. ZSK Key Rollover Operational Mechanics**:
   - **Zone Signing Keys (ZSK)** are used frequently to sign dynamic record updates within the zone. Because they are used often, they should be rotated frequently (e.g., every 30–90 days). Using a smaller key size (1024/2048-bit) keeps `RRSIG` packet sizes small and reduces DNS amplification vectors.
   - **Key Signing Keys (KSK)** sign *only* the `DNSKEY` RRset. Because rotating a KSK requires updating the parent zone's `DS` record via external registrar APIs or registry coordination, KSK rotations are complex and infrequent (e.g., yearly). Separating keys allows administrators to rotate ZSKs locally without involving the parent zone registry.

2. **NSEC vs. NSEC3 Zone Enumeration Mitigation**:
   - Standard **NSEC** records point directly to the *next* existing record name in canonical order (e.g., `app.example.lab IN NSEC db.example.lab`), which allows attackers to walk the zone by repeatedly querying non-existent records to enumerate all valid hostnames.
   - **NSEC3** mitigates this by replacing plain text record names with salted, iterated cryptographic hashes (e.g., `35MQ... IN NSEC3 1 0 10 AABB CCDD...`). This proves non-existence without revealing plain text hostnames, preventing zone walking.

</details>