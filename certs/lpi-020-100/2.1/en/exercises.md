# LPI Security Essentials (Exam 020-100, v1.0) — Topic 2.1: Encryption
**Target Level:** Advanced Production / Senior SRE & Platform Engineering  
**Weight:** 20  
**Reference Source:** [LPI Security Essentials Overview](https://www.lpi.org/our-certifications/security-essentials-overview/)

---

## Technical Fundamentals & Architecture

Cryptographic primitives form the bedrock of zero-trust architecture, secure transport networks, and data protection at rest.

### Cryptographic Categories & Mechanics

1. **Symmetric Encryption**: Uses a single shared key for encryption and decryption. High throughput, low CPU cost per byte.
   - **Block Ciphers**: Operating modes like **AES-256-CBC** require an Initialization Vector (IV) and PKCS#7 padding. Modern architectures mandate Authenticated Encryption with Associated Data (**AEAD**) modes like **AES-256-GCM** or **ChaCha20-Poly1305**, which provide confidentiality, integrity, and authenticity simultaneously without separate HMAC construction.
2. **Asymmetric Encryption & Key Exchange**: Uses mathematically linked key pairs (public/private).
   - **RSA**: Relies on prime factorization hardness. Key sizes must be $\ge 2048$ bits (3072/4096 recommended for modern workloads).
   - **ECC (Elliptic Curve Cryptography)**: Relies on elliptic curve discrete logarithm problem (ECDLP). Offers equivalent security to RSA at drastically smaller key sizes (e.g., `secp256r1`, `X25519`), reducing TLS handshake latency and payload overhead.
   - **Ephemeral Key Exchange (ECDHE)**: Ensures **Perfect Forward Secrecy (PFS)** by generating temporary key pairs per session. Competing session keys cannot be compromised even if the server's long-term private key is leaked later.
3. **Cryptographic Hashing & MACs**:
   - **Cryptographic Hashes**: One-way deterministic functions (SHA-256, SHA-3, BLAKE2). Resistant to pre-image, second pre-image, and collision attacks.
   - **HMAC (Hash-based Message Authentication Code)**: Combines a secret key with a hash function ($HMAC(K, M) = H((K' \oplus opad) \parallel H((K' \oplus ipad) \parallel M))$) to provide message authenticity.
4. **Public Key Infrastructure (PKI) & X.509**:
   - Hierarchical trust anchored on Root Certificate Authorities (Root CAs) issuing intermediate CAs, which issue end-entity leaf certificates.
   - Key extensions: `subjectAltName` (SAN) mandatory for modern TLS, `keyUsage`, `extendedKeyUsage` (serverAuth/clientAuth).

---

## Hands-On Guided Lab Exercises

### Exercise 1: Symmetric Cipher Selection & Authenticated Encryption (AES-GCM vs AES-CBC + HMAC)

#### Mechanics & Objective
Inspect the cryptographic properties of AES in Cipher Block Chaining (CBC) mode versus Galois/Counter Mode (GCM). Learn how non-authenticated ciphers are vulnerable to bit-flipping attacks unless explicitly paired with an HMAC, and why AEAD (AES-GCM) is standard in production.

#### Steps

1. Create a workspace directory and an input secret file:
   ```bash
   mkdir -p ~/crypto-lab && cd ~/crypto-lab
   echo "CONFIDENTIAL: Database Connection String postgresql://appuser:SecretPass123@db.prod.internal:5432/appdb" > payload.txt
   ```

2. Encrypt the file using **AES-256-CBC** with OpenSSL, explicit salt, and key derivation:
   ```bash
   openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -in payload.txt -out payload.cbc.enc -pass pass:SuperStrongKey2026! -p
   ```
   *Expected Output snippet:*
   ```text
   salt=...
   key=...
   iv =...
   ```

3. Encrypt the same file using **AES-256-GCM** (AEAD mode):
   ```bash
   openssl enc -aes-256-gcm -pbkdf2 -iter 100000 -in payload.txt -out payload.gcm.enc -pass pass:SuperStrongKey2026! -p
   ```

4. Perform a 1-bit tampering attempt on the ciphertext of AES-CBC:
   ```bash
   # Flip a byte at offset 32 in the CBC payload
   python3 -c '
   with open("payload.cbc.enc", "rb") as f:
       data = bytearray(f.read())
   data[32] ^= 0xFF
   with open("payload.cbc.tampered.enc", "wb") as f:
       f.write(data)
   '
   ```

5. Attempt to decrypt the tampered CBC file:
   ```bash
   openssl enc -d -aes-256-cbc -pbkdf2 -iter 100000 -in payload.cbc.tampered.enc -out payload.cbc.dec -pass pass:SuperStrongKey2026!
   cat payload.cbc.dec
   ```
   *Expected Output snippet:* Decryption completes (or fails on padding), but corrupted plaintext is emitted without intrinsic authenticity verification.

6. Perform the same byte-flip attack on the **AES-256-GCM** ciphertext:
   ```bash
   python3 -c '
   with open("payload.gcm.enc", "rb") as f:
       data = bytearray(f.read())
   data[32] ^= 0xFF
   with open("payload.gcm.tampered.enc", "wb") as f:
       f.write(data)
   '
   openssl enc -d -aes-256-gcm -pbkdf2 -iter 100000 -in payload.gcm.tampered.enc -out payload.gcm.dec -pass pass:SuperStrongKey2026!
   ```
   *Expected Output snippet:*
   ```text
   bad decrypt
   C03058D101000000:error:1C800064:Provider routines:cipher_finalize_internal:bad decrypt:providers/implementations/ciphers/ciphercommon_gcm.c:386:
   ```

#### Verification Questions (Block 1)
1. Why does AES-256-CBC allow corrupted data output upon decryption of tampered ciphertext, while AES-256-GCM aborts immediately?
2. What role does `-pbkdf2` and `-iter 100000` play in symmetric key derivation from human passwords?

---

### Exercise 2: Asymmetric Cryptography, Key Pair Generation, and Digital Signatures (RSA vs Ed25519)

#### Mechanics & Objective
Generate RSA and Ed25519 key pairs. Calculate message hashes, sign messages, and verify digital signatures to establish authenticity and non-repudiation in automated pipeline security.

#### Steps

1. Generate a **3072-bit RSA Private Key** and extract its public key:
   ```bash
   openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out rsa_private.pem
   openssl pkey -in rsa_private.pem -pubout -out rsa_public.pem
   ```

2. Generate an **Ed25519 (Edwards-curve Digital Signature Algorithm)** key pair:
   ```bash
   openssl genpkey -algorithm Ed25519 -out ed25519_private.pem
   openssl pkey -in ed25519_private.pem -pubout -out ed25519_public.pem
   ```

3. Compare the file sizes and key structures:
   ```bash
   wc -c rsa_private.pem ed25519_private.pem
   ```
   *Expected Output snippet:* RSA key is significantly larger (~2.4 KB) compared to Ed25519 (~120 B).

4. Create an immutable deployment artifact manifest:
   ```bash
   cat << 'EOF' > release-v1.2.0.manifest
   IMAGE_SHA256=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
   DEPLOY_ENV=production
   TIMESTAMP=2026-08-07T00:00:00Z
   EOF
   ```

5. Sign the manifest using the Ed25519 private key:
   ```bash
   openssl pkeyutl -sign -inkey ed25519_private.pem -rawin -in release-v1.2.0.manifest -out manifest.sig
   ```

6. Verify the digital signature using the corresponding public key:
   ```bash
   openssl pkeyutl -verify -pubin -inkey ed25519_public.pem -rawin -in release-v1.2.0.manifest -sigfile manifest.sig
   ```
   *Expected Output snippet:*
   ```text
   Signature Verified Successfully
   ```

7. Tamper with the artifact manifest and attempt verification again:
   ```bash
   echo "EXTRA_ENV_VAR=HACKED" >> release-v1.2.0.manifest
   openssl pkeyutl -verify -pubin -inkey ed25519_public.pem -rawin -in release-v1.2.0.manifest -sigfile manifest.sig
   ```
   *Expected Output snippet:*
   ```text
   Signature Verification Failure
   ```

#### Verification Questions (Block 2)
1. Why is Ed25519 preferred over RSA-2048 or RSA-4096 in modern platform engineering for digital signatures and SSH authentication?
2. What property prevents an attacker from forging `manifest.sig` even if `ed25519_public.pem` and `release-v1.2.0.manifest` are publicly accessible?

---

### Exercise 3: Production PKI Architecture — Certificate Authority (CA) Chain & SAN Certificate Issuance

#### Mechanics & Objective
Build an offline Root CA, an Intermediate CA, generate a Certificate Signing Request (CSR) with `subjectAltName` (SAN) extensions, issue a leaf certificate, and validate the full trust chain.

```
+-------------------------------------------------------+
|                    Root CA Certificate                |
|                    (Self-Signed Trust Anchor)         |
+-------------------------------------------------------+
                            |
                            v
+-------------------------------------------------------+
|                 Intermediate CA Certificate           |
|            (PathLen constraint = 0, CA:TRUE)          |
+-------------------------------------------------------+
                            |
                            v
+-------------------------------------------------------+
|              End-Entity / Leaf Certificate            |
|         (DNS: api.prod.internal, serverAuth)          |
+-------------------------------------------------------+
```

#### Steps

1. Set up directory structures for Root CA and Intermediate CA:
   ```bash
   mkdir -p ~/crypto-lab/pki/{root,intermediate}
   cd ~/crypto-lab/pki
   ```

2. Create the **Root CA configuration** (`root/root.cnf`):
   ```ini
   [ req ]
   default_bits        = 4096
   distinguished_name  = req_distinguished_name
   string_mask         = utf8only
   default_md          = sha256
   prompt              = no

   [ req_distinguished_name ]
   C  = US
   O  = Enterprise Platform Security
   CN = Production Enterprise Root CA G1

   [ v3_ca ]
   subjectKeyIdentifier   = hash
   authorityKeyIdentifier = keyid:always,issuer
   basicConstraints       = critical, CA:true
   keyUsage               = critical, digitalSignature, cCertSign, cRLSign
   ```

3. Initialize and generate the **Root CA key and self-signed certificate**:
   ```bash
   openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 -out root/root_ca.key
   openssl req -new -x509 -config root/root.cnf -days 3650 -key root/root_ca.key -out root/root_ca.crt -extensions v3_ca
   ```

4. Create the **Intermediate CA configuration** (`intermediate/intermediate.cnf`):
   ```ini
   [ req ]
   default_bits        = 4096
   distinguished_name  = req_distinguished_name
   string_mask         = utf8only
   default_md          = sha256
   prompt              = no

   [ req_distinguished_name ]
   C  = US
   O  = Enterprise Platform Security
   CN = Production Infrastructure Intermediate CA G1

   [ v3_intermediate_ca ]
   subjectKeyIdentifier   = hash
   authorityKeyIdentifier = keyid:always,issuer
   basicConstraints       = critical, CA:true, pathlen:0
   keyUsage               = critical, digitalSignature, cCertSign, cRLSign

   [ server_cert ]
   basicConstraints       = CA:FALSE
   nsCertType             = server
   keyUsage               = critical, digitalSignature, keyEncipherment
   extendedKeyUsage       = serverAuth
   subjectKeyIdentifier   = hash
   authorityKeyIdentifier = keyid,issuer
   subjectAltName         = @alt_names

   [ alt_names ]
   DNS.1 = api.prod.internal
   DNS.2 = *.api.prod.internal
   IP.1  = 10.96.0.10
   ```

5. Generate the Intermediate CA Key & CSR, then sign it with Root CA:
   ```bash
   openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 -out intermediate/intermediate.key
   openssl req -new -config intermediate/intermediate.cnf -key intermediate/intermediate.key -out intermediate/intermediate.csr

   openssl x509 -req -in intermediate/intermediate.csr -CA root/root_ca.crt -CAkey root/root_ca.key -CAcreateserial -out intermediate/intermediate.crt -days 1825 -extfile intermediate/intermediate.cnf -extensions v3_intermediate_ca
   ```

6. Generate an **End-Entity Leaf Certificate key and CSR** for `api.prod.internal`:
   ```bash
   mkdir -p leaf
   openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:prime256v1 -out leaf/server.key
   openssl req -new -key leaf/server.key -out leaf/server.csr -subj "/C=US/O=Platform Team/CN=api.prod.internal"
   ```

7. Sign the leaf certificate using the Intermediate CA:
   ```bash
   openssl x509 -req -in leaf/server.csr -CA intermediate/intermediate.crt -CAkey intermediate/intermediate.key -CAcreateserial -out leaf/server.crt -days 365 -extfile intermediate/intermediate.cnf -extensions server_cert
   ```

8. Verify the complete trust chain using `openssl verify`:
   ```bash
   # Create CA chain bundle
   cat intermediate/intermediate.crt root/root_ca.crt > ca-chain.crt
   openssl verify -CAfile ca-chain.crt leaf/server.crt
   ```
   *Expected Output snippet:*
   ```text
   leaf/server.crt: OK
   ```

#### Verification Questions (Block 3)
1. What is the explicit technical vulnerability of omitting `subjectAltName` (SAN) on modern TLS server certificates, even if the `Common Name` (CN) matches the target domain?
2. What does `basicConstraints = critical, CA:true, pathlen:0` enforce at the cryptography layer for the Intermediate CA certificate?

---

### Exercise 4: Transport Layer Security (TLS 1.3) Diagnostics & Deep Protocol Inspection

#### Mechanics & Objective
Configure a local TLS listener using OpenSSL, simulate cipher negotiation, verify TLS 1.3 handshake parameters, and diagnose certificate validation errors using `openssl s_client`.

#### Steps

1. Start an `openssl s_server` dual-stack listener using the leaf certificate and full chain generated in Exercise 3:
   ```bash
   openssl s_server -accept 8443 -cert leaf/server.crt -key leaf/server.key -CAfile ca-chain.crt -www &
   SERVER_PID=$!
   sleep 2
   ```

2. Test client connection with **untrusted** system trust store (simulating default connection failure):
   ```bash
   openssl s_client -connect 127.0.0.1:8443 -servername api.prod.internal < /dev/null
   ```
   *Expected Output snippet:*
   ```text
   Verification error: unable to get local issuer certificate
   Verify return code: 20 (unable to get local issuer certificate)
   ```

3. Connect supplying the explicit `ca-chain.crt` for trust verification:
   ```bash
   openssl s_client -connect 127.0.0.1:8443 -servername api.prod.internal -CAfile ca-chain.crt < /dev/null
   ```
   *Expected Output snippet:*
   ```text
   Verify return code: 0 (ok)
   Protocol  : TLSv1.3
   Cipher    : TLS_AES_256_GCM_SHA384
   Peer signing digest: SHA256
   Peer signature type: ECDSA
   ```

4. Force legacy TLS 1.2 protocol and inspect cipher suite negotiation:
   ```bash
   openssl s_client -connect 127.0.0.1:8443 -tls1_2 -CAfile ca-chain.crt < /dev/null | grep -E "Protocol|Cipher"
   ```

5. Clean up the background server process:
   ```bash
   kill $SERVER_PID
   ```

#### Verification Questions (Block 4)
1. Why does TLS 1.3 remove static RSA key exchange algorithms (e.g., `TLS_RSA_WITH_AES_256_CBC_SHA`) entirely from its specification?
2. What is the role of Server Name Indication (SNI) passed via `-servername api.prod.internal` during the initial TLS ClientHello packet?

---

### Exercise 5: Data-at-Rest Encryption & Key Derivation with LUKS2 (`cryptsetup`)

#### Mechanics & Objective
Create an encrypted block storage volume using LUKS2 (Linux Unified Key Setup version 2). Inspect anti-forensics key derivation functions (Argon2id), master key slots, and volume header metadata.

#### Steps

1. Create a 100MB sparse file to simulate a raw block storage device:
   ```bash
   cd ~/crypto-lab
   dd if=/dev/zero of=disk.img bs=1M count=100
   ```

2. Format the virtual block device with **LUKS2** specifying `argon2id` PBKDF:
   ```bash
   sudo cryptsetup luksFormat --type luks2 --pbkdf argon2id --cipher aes-xts-plain64 --key-size 512 disk.img --batch-mode --key-file <(echo -n "ProductionDiskSecretPass2026!")
   ```

3. Dump the LUKS header to inspect cryptanalysis protections and key slot parameters:
   ```bash
   sudo cryptsetup luksDump disk.img
   ```
   *Expected Output snippet:*
   ```text
   LUKS header information
   Version:        2
   Cipher name:    aes
   Cipher mode:    xts-plain64
   Hash spec:      sha256
   PBKDF:          argon2id
   Time cost:      ...
   Memory cost:    ...
   Keyslots:
     0: luks2
   ```

4. Open the encrypted device mapping:
   ```bash
   sudo cryptsetup open disk.img secure_volume --key-file <(echo -n "ProductionDiskSecretPass2026!")
   ls -l /dev/mapper/secure_volume
   ```

5. Format with ext4, mount, write data, and close the mapping:
   ```bash
   sudo mkfs.ext4 /dev/mapper/secure_volume
   mkdir -p /tmp/mnt_secure
   sudo mount /dev/mapper/secure_volume /tmp/mnt_secure
   echo "TOP_SECRET_PAYLOAD" | sudo tee /tmp/mnt_secure/confidential.dat

   # Clean up
   sudo umount /tmp/mnt_secure
   sudo cryptsetup close secure_volume
   ```

6. Attempt raw byte inspection of `disk.img` to confirm cipher text randomness:
   ```bash
   strings disk.img | grep "TOP_SECRET_PAYLOAD"
   ```
   *Expected Output:* Empty (No plaintext strings discoverable due to high-entropy AES-XTS encryption).

#### Verification Questions (Block 5)
1. Why is `AES-XTS` preferred over `AES-CBC` or `AES-GCM` for disk/sector-level data-at-rest encryption?
2. What advantage does Argon2id provide over legacy PBKDF2 in LUKS2 header key derivation?

---

<details>
<summary><strong>Answers & Comprehensive Explanations</strong></summary>

### Block 1 Answers

1. **AES-CBC vs AES-GCM Integrity Failure**:
   - **AES-CBC** provides confidentiality only. It relies on cipher block chaining where decryption of block $N$ depends on ciphertext block $N-1$. A bit-flip in ciphertext block $N-1$ corrupts block $N-1$ completely upon decryption, but flips the exact corresponding bit in plaintext block $N$ predictably without invalidating the algorithm itself (unless PKCS#7 padding check fails).
   - **AES-GCM** is an AEAD (Authenticated Encryption with Associated Data) mode. It appends a 128-bit authentication tag calculated via GHASH over the ciphertext and optional Additional Authenticated Data (AAD). During decryption, OpenSSL recalculates the authentication tag. If even a single bit of the ciphertext or tag is modified, validation fails immediately and output is suppressed.

2. **Role of `-pbkdf2` and Iteration Counts**:
   - Human passwords lack sufficient entropy. Password-Based Key Derivation Function 2 (**PBKDF2**) applies a pseudo-random function (like HMAC-SHA256) along with a salt to the password repeatedly ($100,000+$ iterations).
   - This drastically increases the computational complexity of offline dictionary and brute-force attacks by requiring massive CPU cycles per key candidate evaluation.

---

### Block 2 Answers

1. **Ed25519 vs RSA Advantages**:
   - **Performance & Key Size**: Ed25519 public keys are 32 bytes and signatures are 64 bytes. An equivalent RSA-4096 key is 512 bytes, causing higher storage and network payload transmission cost.
   - **Computational Efficiency**: Ed25519 key generation, signing, and verification operations are orders of magnitude faster than RSA 3072/4096, reducing CPU load during batch signature verifications.
   - **Resilience**: Ed25519 is designed to be immune to side-channel timing attacks and implementation pitfalls like weak random number generators during signing (deterministic RFC 8032 implementation).

2. **Preventing Signature Forgery**:
   - Digital signatures utilize asymmetric trapdoor functions. The signature `manifest.sig` is generated using the secret **private key** ($S = \text{Sign}(K_{private}, \text{Hash}(M))$).
   - Anyone possessing the **public key** can verify that $S$ corresponds to message $M$ using public verification math, but deriving $K_{private}$ from $K_{public}$ or forging a valid signature $S'$ for a modified message $M'$ without $K_{private}$ is computationally infeasible due to the Discrete Logarithm Problem on Twisted Edwards curves.

---

### Block 3 Answers

1. **Omitting `subjectAltName` (SAN)**:
   - Modern Web Browsers and TLS client libraries (Go `crypto/tls`, OpenSSL 1.1.1+, Chrome, Safari) completely ignore the `Common Name` (CN) field during hostname validation in accordance with **RFC 6125** and **RFC 2818**.
   - If a certificate lacks SAN entries, TLS validation fails with `ERR_CERT_COMMON_NAME_INVALID` or equivalent domain verification exceptions, rendering the certificate unusable in production environments regardless of matching CN.

2. **Implications of `basicConstraints = critical, CA:true, pathlen:0`**:
   - `CA:true` designates that the key pair may sign down-chain X.509 certificates and CRLs.
   - `pathlen:0` specifies that no additional intermediate CAs may be issued below this Intermediate CA. It can only issue end-entity leaf certificates. If an attacker steals the Intermediate CA private key, they cannot establish subordinate CAs to delegate signing rights further down a deep hierarchy.
   - `critical` instructs X.509 parsers that they MUST reject the certificate outright if they do not understand or cannot enforce the constraint extension.

---

### Block 4 Answers

1. **Removal of Static RSA Key Exchange in TLS 1.3**:
   - In static RSA key exchange (TLS 1.2 and earlier), the client encrypts a pre-master secret using the server's public key. The server decrypts it using its long-term private key.
   - If an adversary records encrypted network traffic today and steals the server's long-term RSA private key in the future (via compromise, insider threat, or court order), the adversary can decrypt ALL past recorded sessions.
   - TLS 1.3 mandates Ephemeral Diffie-Hellman (**ECDHE**) key exchange, guaranteeing **Perfect Forward Secrecy (PFS)**. Session keys are ephemeral and discarded immediately after session termination.

2. **Role of Server Name Indication (SNI)**:
   - SNI is an extension to the TLS protocol declared in the unencrypted `ClientHello` packet.
   - It allows the client to specify the target domain name (`api.prod.internal`) it intends to reach before the TLS connection is established. This enables multi-tenant reverse proxies (e.g., NGINX, Traefik, HAProxy, ingress controllers) to select and serve the correct TLS certificate for Virtual Hosts sharing a single IP address.

---

### Block 5 Answers

1. **Why `AES-XTS` for Sector/Disk Encryption**:
   - Disk sector encryption requires fixed-length mapping: encrypting a 4096-byte sector must output exactly 4096 bytes without storage expansion (no space for IVs per sector or authentication tags like GCM, nor padding like CBC).
   - **XTS** (XEX-based tweaked-codebook mode with ciphertext stealing) uses two AES keys and a sector tweak key to prevent identical plaintext blocks across different sectors from producing identical ciphertext blocks, resisting block replay and pattern analysis attacks on storage devices.

2. **Argon2id vs PBKDF2 in LUKS2**:
   - **PBKDF2** is CPU-bound only. Attackers can execute massively parallel brute-force attacks against PBKDF2 headers using custom Application-Specific Integrated Circuits (ASICs) or GPUs.
   - **Argon2id** (winner of the Password Hashing Competition) is memory-hard and time-hard. It forces the key derivation process to consume significant configured RAM (e.g., 64MB-1GB per attempt) in addition to CPU cycles. This makes GPU/ASIC parallel brute-forcing economically and physically prohibitive.

</details>

---

## Official Reference Documentation Links

- [LPI Security Essentials Objectives](https://www.lpi.org/our-certifications/security-essentials-overview/)
- [RFC 5280: Internet X.509 Public Key Infrastructure Certificate and CRL Profile](https://datatracker.ietf.org/doc/html/rfc5280)
- [RFC 8446: The Transport Layer Security (TLS) Protocol Version 1.3](https://datatracker.ietf.org/doc/html/rfc8446)
- [RFC 8032: Edwards-Curve Digital Signature Algorithm (EdDSA)](https://datatracker.ietf.org/doc/html/rfc8032)
- [OpenSSL Cryptographic Command-Line Documentation](https://www.openssl.org/docs/man3.0/man1/)
- [Linux cryptsetup / LUKS2 Wiki](https://gitlab.com/cryptsetup/cryptsetup/-/wikis/home)