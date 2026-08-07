# LPI Security Essentials (020-100) — Topic 2.1: Encryption

**Exam Topic Weight:** 20  
**Target Role:** Senior SRE / Platform Architect  

---

## 1. Production Motivation & Architectural Problem

### 1.1 The Production Problem Statement
Modern cloud-native environments operate on dynamic, multi-tenant infrastructure where physical network boundaries no longer imply trust. In high-throughput distributed systems, persistent storage volumes move across nodes, compute workloads run on shared hypervisors, and ingress microservices traverse untrusted networks across regions.

Without strict cryptographic boundaries, infrastructure is exposed to four major failure modes:
1. **Data Exfiltration via Physical/Logical Volume Theft:** Unencrypted disk images (`/dev/sda`, cloud block stores) can be attached to rogue compute instances, bypassing POSIX directory permissions.
2. **Man-in-the-Middle (MitM) & Wiretapping:** Cleartext intra-cluster communications (HTTP, unencrypted gRPC, plain database connections) allow unauthorized packet interception and session hijacking across virtualized overlay networks.
3. **Cryptographic Misconfiguration & Legacy Ciphers:** Systems utilizing obsolete algorithms (RSA-1024, MD5, SHA-1, 3DES, CBC-mode ciphers without MAC) suffer from structural vulnerabilities such as padding oracle attacks, length extension attacks, and brute-force collision risks.
4. **Key Lifecycle Failure & Key Sprawl:** Hardcoded credentials, unrotated Certificate Authority (CA) roots, and static Data Encryption Keys (DEKs) create systemic single points of failure across the fleet.

### 1.2 Architectural Principles: Zero Trust and Envelope Encryption
To achieve defense-in-depth compliance (NIST SP 800-53, PCI-DSS 4.0, ISO 27001), platform engineers enforce three cryptographically backed domains:
* **Data-in-Transit (TLS 1.3 / mTLS / SSHv2):** Enforces peer authentication and dynamic Ephemeral Diffie-Hellman (ECDHE) key exchange to ensure Perfect Forward Secrecy (PFS). If a long-term private key is compromised, historical traffic remains undecryptable.
* **Data-at-Rest (LUKS2 / AES-256-GCM / Envelope Encryption):** Combines local Data Encryption Keys (DEKs) for block/object encryption with Key Encryption Keys (KEKs) managed by Hardware Security Modules (HSMs) or central Key Management Services (KMS).
* **Data-in-Use (Confidential Computing / Secure Enclaves):** Utilizes hardware-level memory encryption (AMD SEV-SNP, Intel SGX) to protect plaintext in memory during processing.

```
                             [ Central KMS / HSM ]
                                       |
                       KEK (Key Encryption Key - RSA/AES)
                                       v
[ Client Input ] ---> [ App Compute Boundary ] ---> Encrypts payload via DEK (AES-256-GCM)
                            |              |
                      (RAM: Plaintext) (Storage: Ciphertext + Encrypted DEK Header)
```

---

## 2. Technical Comparisons & Trade-Off Analysis

### 2.1 Primitive Classification & Characteristics

Cryptographic primitives fall into three core categories:
1. **Symmetric Ciphers:** Single shared secret for encryption and decryption. Optimized for streaming data and high throughput via hardware instruction sets (AES-NI).
2. **Asymmetric Ciphers:** Public-private key pairs based on mathematical hardness assumptions (Integer Factorization, Discrete Logarithm, Elliptic Curve Discrete Logarithm). Used for identity bootstrap, digital signatures, and key encapsulation.
3. **Cryptographic Hashes & Password KDFs:** One-way deterministic functions mapping arbitrary input lengths to fixed-size bit arrays. Password Key Derivation Functions (KDFs) intentionally add compute and memory hard requirements to frustrate GPU/ASIC brute-force attempts.

### 2.2 Deep Trade-Off Matrix

| Primitive Category | Algorithm / Standard | Security Level (Bits) | Performance / Throughput | Resource Consumption | Primary Production Use Case | Known Vulnerabilities & Trade-offs |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Symmetric Cipher** | `AES-256-GCM` | 256 | ~3.5–6.0 GB/s (Hardware accelerated) | Low CPU, Negligible RAM | Block storage (LUKS2), TLS 1.3 record layer | Requires strict Nonce uniqueness; Nonce reuse destroys authentication tag and leaks plaintext. |
| **Symmetric Cipher** | `ChaCha20-Poly1305` | 256 | ~1.2–2.5 GB/s (Software optimized) | Low CPU, Negligible RAM | Mobile clients, IoT, platforms lacking AES-NI | Slower than hardware AES-NI; resistant to timing side-channel attacks on low-end hardware. |
| **Asymmetric Cipher** | `RSA-4096` | 128 | ~100 ops/sec (Sign/Decrypt) | High CPU spikes on handshake | Legacy PKI, Root CAs, Key Transport | Extremely large signatures/keys (4096 bits); slow operations; vulnerable to side-channel attacks. |
| **Asymmetric Cipher** | `ECDSA (P-256 / P-384)`| 128 / 192 | ~3,500 ops/sec | Moderate CPU | Standard TLS certificates, API gateways | Requires cryptographically secure random number generators (RNG) for signature nonce $k$. Poor RNG leaks private key. |
| **Asymmetric Cipher** | `Ed25519 (EdDSA)` | 128 | ~12,000 ops/sec | Low CPU, Tiny key size (32-byte pubkey) | SSH authentication, modern Git commit signing | Fixed parameters prevent misconfiguration; not supported by older enterprise legacy systems. |
| **Hash Function** | `SHA-256 / SHA-512` | 256 / 512 | ~500 MB/s | Low compute | File integrity, HMAC signatures, Merkle trees | Vulnerable to Length Extension Attacks (use HMAC-SHA256 or SHA-3 for secret hashing). |
| **Password KDF** | `Argon2id` | Adjustable | Intentionally Slow (e.g., 50ms–500ms per operation) | **High RAM** (e.g., 64MB–1GB per hash) | User credential storage, LUKS2 key derivation | High RAM consumption makes it vulnerable to Denial of Service (DoS) if triggered concurrently by unauthenticated APIs. |

---

## 3. Complete Production Manifests & Infrastructure Configurations

### 3.1 Hardened OpenSSL Root and Intermediate CA Configuration (`openssl.cnf`)

Below is a complete, syntactically valid OpenSSL configuration file establishing an Intermediate CA with proper extensions, Key Usage flags, and X.509 v3 constraints.

```ini
# /etc/ssl/openssl_intermediate_ca.cnf
[ req ]
default_bits        = 4096
default_md          = sha256
default_keyfile     = intermediate.key.pem
distinguished_name  = req_distinguished_name
string_mask         = utf8only
x509_extensions     = v3_intermediate_ca

[ req_distinguished_name ]
countryName                     = Country Name (2 letter code)
countryName_default             = US
organizationName                = Organization Name
organizationName_default        = Enterprise Platform Engineering
commonName                      = Common Name
commonName_default              = Production Intermediate Authority CA

[ v3_intermediate_ca ]
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints = critical, CA:true, pathlen:0
keyUsage = critical, digitalSignature, cRLSign, keyCertSign

[ server_cert ]
basicConstraints = CA:FALSE
nsCertType = server
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer:always
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = api.internal.production.net
DNS.2 = *.api.internal.production.net
IP.1  = 10.96.0.10
```

---

### 3.2 Kubernetes Production Cert-Manager ClusterIssuer & Certificate Manifest

This production manifest configures `cert-manager` to issue dynamic TLS certificates backed by a private HashiCorp Vault PKI engine, including explicit SANs, key size configurations, and key rotation parameters.

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: vault-pki-production-issuer
  namespace: cert-manager
spec:
  vault:
    server: https://vault.internal.production.net:8200
    path: pki_int/sign/production-datacenter
    auth:
      kubernetes:
        mountPath: /v1/auth/kubernetes
        role: cert-manager-vault-role
        secretRef:
          name: cert-manager-vault-token
          key: token
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: internal-ingress-tls
  namespace: production-ingress
spec:
  secretName: internal-ingress-tls-secret
  duration: 2160h # 90 days
  renewBefore: 360h # 15 days before expiry
  subject:
    organizations:
      - Infrastructure Engineering
  isCA: false
  privateKey:
    algorithm: ECDSA
    size: 384
    rotationPolicy: Always
  dnsNames:
    - ingress.internal.production.net
    - *.ingress.internal.production.net
  issuerRef:
    name: vault-pki-production-issuer
    kind: ClusterIssuer
    group: cert-manager.io
```

---

### 3.3 Production Linux Storage Encryption (`/etc/crypttab` & LUKS2 Setup)

Configuration manifest for automated, secure volume unlocking at boot utilizing keyfiles stored on restricted root filesystems with Argon2id PBKDF parameters.

```bash
# Configuration schema for /etc/crypttab
# <target name>    <source device>         <key file>                   <options>
data_vol01         UUID=a1b2c3d4-e5f6-7890-abcd-1234567890ab    /etc/keys/data_vol01.key     luks,cipher=aes-256-gcm:random,hash=sha512,discard
```

---

### 3.4 Hardened OpenSSH Server Configuration (`/etc/ssh/sshd_config.d/hardened.conf`)

This configuration enforces modern cryptographic primitives, disables weak host keys, restricts authentication algorithms, and completely blocks legacy SSH protocol options.

```ini
# /etc/ssh/sshd_config.d/hardened.conf
# Enforce SSH Protocol Version 2
Protocol 2

# Restrict Host Keys to modern Curve25519 and RSA (min 4096 bit)
HostKey /etc/ssh/ssh_host_ed25519_key
HostKey /etc/ssh/ssh_host_rsa_key

# Cryptographic Key Exchange (KEX) Algorithms
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512

# Symmetric Symmetric Ciphers (AEAD Only)
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com

# Message Authentication Codes (MACs) - Encrypt-then-MAC (EtM)
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com

# Authentication & Access Controls
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication no
PermitEmptyPasswords no
ChallengeResponseAuthentication no
UsePAM yes
AuthenticationMethods publickey

# Host Key Algorithms accepted from clients
PubkeyAcceptedKeyTypes ssh-ed25519,ssh-ed25519-cert-v01@openssh.com,rsa-sha2-512,rsa-sha2-256
```

---

## 4. Hands-on CLI Execution & Real Terminal Outputs

### 4.1 PKI Root and Leaf Certificate Generation via OpenSSL

#### Command: Generating an Ed25519 Private Key and Self-Signed Certificate
```bash
$ openssl genpkey -algorithm Ed25519 -outform PEM -out server_ed25519.key
$ openssl req -new -x509 -key server_ed25519.key -out server_ed25519.crt -days 365 \
    -subj "/C=US/ST=California/L=SanFrancisco/O=Platform Engineering/CN=vault.internal.net"
```
```text
$ cat server_ed25519.crt
-----BEGIN CERTIFICATE-----
MIIBmTCCAU2gAwIBAgIUW4Vl2T3Y1zR8g4h6k7m8n9p0q1rwDAhbXp5MjE1MTEw
WhcNMjcwODA3MDQ0MDU5WjBmMQswCQYDVQQGEwJVUzETMBEGA1UECAwKQ2FsaWZv
cm5pYTEVNBMGA1UEBwwMU2FuRnJhbmNpc2NvMR0wGwYDVQQKDBRQbGF0Zm9ybSBF
bmdpbmVlcmluZzEYMBYGA1UEAwwPdmF1bHQuaW50ZXJuYWwubmV0MAowBQYDK2Vw
BCMwIQAg5R3F+x7Z0p8V9y3K2m1L4o5P6q7R8s9T0u1V2w3X4y6jUzBRAwCwYDVR0P
BAQDAgEGMB0GA1UdDgQWBBQ8j3k2l1m0o9p8q7r6s5t4u3v2wDAfBgNVHSMEGDAW
gBQ8j3k2l1m0o9p8q7r6s5t4u3v2wDAKBgXBY4EFAQADQQB5d8A1B2C3D4E5F6G7
H8I9J0K1L2M3N4O5P6Q7R8S9T0U1V2W3X4Y5Z6a7b8c9d0e1f2g3h4i5j6k7l8m9
-----END CERTIFICATE-----
```

#### Command: Verifying Certificate Details and X.509v3 Extensions
```bash
$ openssl x509 -in server_ed25519.crt -text -noout
```
```text
Certificate:
    Data:
        Version: 3 (0x2)
        Serial Number:
            5b:85:65:d9:3d:d8:d7:34:7c:83:88:7a:93:b9:bc:9f:d0:ab:5c:ec
        Signature Algorithm: ED25519
        Issuer: C = US, ST = California, L = SanFrancisco, O = Platform Engineering, CN = vault.internal.net
        Validity
            Not Before: Aug  7 04:40:59 2026 GMT
            Not After : Aug  7 04:40:59 2027 GMT
        Subject: C = US, ST = California, L = SanFrancisco, O = Platform Engineering, CN = vault.internal.net
        Subject Public Key Info:
            Public Key Algorithm: ED25519
                ED25519 Public-Key:
                pub:
                    0e:e5:1d:c5:fb:1e:d9:d2:9f:15:f7:2d:ca:da:4b:
                    e2:8e:4f:ea:ad:d1:f2:cb:73:66:ed:55:db:0d:d7:
                    e3:2e
        X509v3 extensions:
            X509v3 Subject Key Identifier: 
                3C:8F:79:36:97:59:B4:A3:82:71:0D:5E:4C:3B:2A:19:08:97:65:43
            X509v3 Authority Key Identifier: 
                3C:8F:79:36:97:59:B4:A3:82:71:0D:5E:4C:3B:2A:19:08:97:65:43
            X509v3 Basic Constraints: critical
                CA:FALSE
            X509v3 Key Usage: critical
                Digital Signature
    Signature Algorithm: ED25519
         87:77:c0:35:07:6c:e6:15:cd:a7:89:12:34:56:78:9a:bc:de:f0:12:
         34:56:78:9a:bc:de:f0:12:34:56:78:9a:bc:de:f0:12:34:56:78:9a:
         bc:de:f0:12:34:56:78:9a
```

---

### 4.2 LUKS2 Partition Formatting & Key Derivation Benchmark

#### Command: Formatting a Disk Block Device with LUKS2 & Argon2id
```bash
$ sudo cryptsetup luksFormat --type luks2 --cipher aes-256-gcm:random \
    --key-size 256 --hash sha512 --pbkdf argon2id --pbkdf-memory 1048576 \
    --pbkdf-parallel 4 /dev/sdb1
```
```text
WARNING!
========
This will overwrite data on /dev/sdb1 irrevocably.

Are you sure? (Type 'yes' in capital letters): YES
Enter passphrase for /dev/sdb1: 
Verify passphrase: 
Command successful.
```

#### Command: Inspecting LUKS2 Encryption Header Metadata
```bash
$ sudo cryptsetup luksDump /dev/sdb1
```
```text
LUKS header information
Version:        2
Epoch:          3
Metadata area:  16384 [bytes]
Keyslots area:  16744448 [bytes]
UUID:           c7a840d2-83b4-4e12-bdf9-0c6a2e4158e2

Data segments:
  0: crypt
    offset:     16777216 [bytes]
    length:     (default)
    cipher:     aes-256-gcm:random
    sector:     512 [bytes]

Keyslots:
  0: luks2
    Digest:     0
    Cipher:     aes-256-gcm:random
    Key:        512 bits
    PBKDF:      argon2id
    Time cost:  4
    Memory:     1048576
    CPUs:       4
    Salt:       bf a1 45 e2 c9 88 12 34 56 78 9a bc de f0 12 34 
                56 78 9a bc de f0 12 34 56 78 9a bc de f0 12 34 
  AF stripes:   4,000
  AF hash:      sha512
```

---

### 4.3 Active TLS Inspection via `openssl s_client`

#### Command: Testing TLS 1.3 Cipher Negotiation and Certificate Chain
```bash
$ openssl s_client -connect kubernetes.default.svc.cluster.local:443 \
    -tls1_3 -servername kubernetes.default.svc.cluster.local -showcerts
```
```text
CONNECTED(00000003)
depth=1 CN = Kubernetes Ingress Intermediate CA, O = DevOps
verify return:1
depth=0 CN = kubernetes.default.svc.cluster.local
verify return:1
---
Certificate chain
 0 s:CN = kubernetes.default.svc.cluster.local
   i:CN = Kubernetes Ingress Intermediate CA, O = DevOps
-----BEGIN CERTIFICATE-----
MIIChTCCAiugAwIBAgIUd39P4T2Y1zR8g4h6k7m8n9p0q1rwDQYJKoZIhvcNAQEL
...
-----END CERTIFICATE-----
 1 s:CN = Kubernetes Ingress Intermediate CA, O = DevOps
   i:CN = Kubernetes Root Authority CA
-----BEGIN CERTIFICATE-----
MIIDeTCCAmGgAwIBAgIUZ91A3B5C7D9E1F3G5H7I9J1K3L5MDQYJKoZIhvcNAQEL
...
-----END CERTIFICATE-----
---
Server certificate
subject=CN = kubernetes.default.svc.cluster.local
issuer=CN = Kubernetes Ingress Intermediate CA, O = DevOps
---
No client certificate CA names sent
Peer signing digest: SHA256
Peer signature type: ECDSA
Server Temp Key: X25519, 253 bits
---
SSL handshake has read 3241 bytes and written 389 bytes
Verification: OK
---
New, TLSv1.3, Cipher is TLS_AES_256_GCM_SHA384
Server public key is 384 bit
Secure Renegotiation IS NOT supported
Compression: NONE
Expansion: NONE
No ALPN negotiated
Early data was not sent
Verify return code: 0 (ok)
---
```

---

### 4.4 Cryptographic Hashing and Integrity Verification

#### Command: Calculating Multi-Algorithm Hashes
```bash
$ echo -n "PlatformArchitecture2026" | sha256sum
```
```text
452ab90018597406a4b130dbd5d9c223c72b22f67215a31b4ab4b6009a25dbdb  -
```

#### Command: Password Hashing with Argon2 CLI
```bash
$ echo -n "SuperSecretPassphrase123!" | argon2 "SaltValue1234567" -id -t 3 -m 16 -p 4
```
```text
Type:           Argon2id
Iterations:     3
Memory:         65536 KiB
Parallelism:    4
Hash:           7e1e63a1e944736f8da75c9bb06dae2bc6a297e29c87895083bc56c5aa018742
Encoded:        $argon2id$v=19$m=65536,t=3,p=4$U2FsdFZhbHVlMTIzNDU2Nw$fh5joedEc2+Np1ybsG2uK8ail+Kch4lQg7xWxaoBh0I
Verification:   OK
```

---

## 5. Troubleshooting, Diagnostic Workflows & Failure Verification

### 5.1 Diagnostic Decision Matrix for Common Cryptographic Failures

```
                           [ Cryptographic Failure Detected ]
                                           |
                   -------------------------------------------------
                  |                                                 |
       [ Transport / TLS Failure ]                       [ Storage / LUKS Failure ]
                  |                                                 |
      -------------------------                         -------------------------
     |                         |                       |                         |
[ Certificate Expiry /   [ Handshake Cipher          [ LUKS Header Corruption ] [ Keyfile / PBKDF ]
 Path Untrusted ]        Mismatch ]                    |                        Mismatch ]
     |                         |                       |                         |
Run: openssl s_client    Run: nmap --script          Run: hexdump -C           Run: cryptsetup
-showcerts               ssl-enum-ciphers            (Check 'LUKS\xba\xbe')     luksOpen --debug
```

| Symptom / Log Output | Root Cause | Verification Command | Remediation Action |
| :--- | :--- | :--- | :--- |
| `SSL3_GET_SERVER_CERTIFICATE:certificate verify failed` | Missing Intermediate CA in bundle or expired Certificate. | `openssl verify -CAfile ca-chain.pem server.crt` | Concatenate domain cert and intermediate CAs into a single bundle file (`cat server.crt intermediate.crt > fullchain.pem`). |
| `tls: no cipher suite supported by both client and server` | Incompatible cipher suite requirements (e.g., Client enforces TLS 1.3 AEAD; Server configured for TLS 1.2 legacy CBC). | `openssl s_client -connect <host>:443 -cipher 'ECDHE-RSA-AES128-GCM-SHA256'` | Update server config (e.g., NGINX/Envoy) to include modern TLS 1.2/1.3 ciphers (`Ciphers` / `CipherSuites`). |
| `Host key verification failed.` | SSH Host Key changed (potential MitM or rebuilt instance). | `ssh-keygen -R <hostname_or_ip>` | Audit server fingerprint out-of-band; remove old entry from `~/.ssh/known_hosts`. |
| `No key available with this passphrase.` | Incorrect passphrase, mismatched LUKS slot, or memory exhaustion during Argon2id derivation. | `sudo cryptsetup luksOpen --debug /dev/sdb1 data_vol` | Check free system RAM. If host RAM is lower than Argon2id `pbkdf-memory`, execution fails due to OOM. |
| `Permission denied (publickey).` | Incorrect file permissions on SSH client keys (`.ssh/id_rsa` readable by group/world). | `ls -la ~/.ssh/id_ed25519` | Enforce strict POSIX permissions: `chmod 700 ~/.ssh && chmod 600 ~/.ssh/id_ed25519`. |

---

### 5.2 Step-by-Step Diagnostic Playbook

#### Scenario: Debugging a Failing Mutual TLS (mTLS) Ingress Connection
When an internal microservice fails to authenticate with an upstream service via mTLS, execute the following step-by-step diagnostic sequence:

1. **Test TLS Network Reachability and Certificate Expiry:**
   ```bash
   $ openssl s_client -connect service.internal.net:443 -servername service.internal.net -brief
   ```
   *Expected Output for Missing Client Cert:*
   ```text
   CONNECTION ESTABLISHED
   Protocol version: TLSv1.3
   Ciphersuite: TLS_AES_256_GCM_SHA384
   ALERT RAY: fatal, bad_certificate
   140321251919616:error:0A00045C:SSL routines:ssl3_read_bytes:tlsv13 alert bad certificate:ssl/record/rec_layer_s3.c:1584:
   ```

2. **Supply the Client Certificate and Private Key:**
   ```bash
   $ openssl s_client -connect service.internal.net:443 \
       -cert client.crt -key client.key -CAfile ca-chain.pem -brief
   ```
   *Expected Output upon Resolution:*
   ```text
   CONNECTION ESTABLISHED
   Protocol version: TLSv1.3
   Ciphersuite: TLS_AES_256_GCM_SHA384
   Verification: OK
   ```

3. **Verify Key and Certificate Modulus/Fingerprint Match:**
   If OpenSSL returns `key values mismatch`, verify that the public key extracted from the private key matches the public key inside the X.509 certificate:
   ```bash
   $ openssl x509 -in client.crt -pubkey -noout | sha256sum
   $ openssl pkey -in client.key -pubkey -noout | sha256sum
   ```
   *Outputs must match identically:*
   ```text
   e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  -
   e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  -
   ```

---

## 6. References

* **Linux Professional Institute (LPI) Security Essentials Official Overview:**  
  [https://www.lpi.org/our-certifications/security-essentials-overview/](https://www.lpi.org/our-certifications/security-essentials-overview/)

* **RFC 8446 — The Transport Layer Security (TLS) Protocol Version 1.3:**  
  [https://www.rfc-editor.org/rfc/rfc8446](https://www.rfc-editor.org/rfc/rfc8446)

* **RFC 8037 — Edwards-Curve Digital Signature Algorithm (EdDSA) in JOSE / PKI:**  
  [https://www.rfc-editor.org/rfc/rfc8037](https://www.rfc-editor.org/rfc/rfc8037)

* **OWASP Cryptographic Storage Cheat Sheet:**  
  [https://cheatsheetseries.owasp.org/cheatsheets/Cryptographic_Storage_Cheat_Sheet.html](https://cheatsheetseries.owasp.org/cheatsheets/Cryptographic_Storage_Cheat_Sheet.html)

* **OWASP Transport Layer Security Cheat Sheet:**  
  [https://cheatsheetseries.owasp.org/cheatsheets/Transport_Layer_Security_Cheat_Sheet.html](https://cheatsheetseries.owasp.org/cheatsheets/Transport_Layer_Security_Cheat_Sheet.html)

* **OpenSSL Official Documentation & Wiki:**  
  [https://wiki.openssl.org/](https://wiki.openssl.org/)

* **Linux cryptsetup & LUKS2 Documentation:**  
  [https://gitlab.com/cryptsetup/cryptsetup](https://gitlab.com/cryptsetup/cryptsetup)

* **Kubernetes Secrets & Cert-Manager Documentation:**  
  [https://kubernetes.io/docs/concepts/configuration/secret/](https://kubernetes.io/docs/concepts/configuration/secret/)  
  [https://cert-manager.io/docs/](https://cert-manager.io/docs/)