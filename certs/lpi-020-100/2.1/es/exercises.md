# LPI Security Essentials (Exam 020-100, v1.0) — Topic 2.1: Encryption
**Nivel objetivo:** Producción Avanzada / Senior SRE & Platform Engineering  
**Peso:** 20  
**Fuente de referencia:** [LPI Security Essentials Overview](https://www.lpi.org/our-certifications/security-essentials-overview/)

---

## Technical Fundamentals & Architecture

Las primitivas criptográficas forman la base de la arquitectura zero-trust, las redes de transporte seguras y la protección de datos en reposo (data protection at rest).

### Cryptographic Categories & Mechanics

1. **Symmetric Encryption**: Utiliza una única key compartida para encryption y decryption. Alto rendimiento (high throughput), bajo costo de CPU por byte.
   - **Block Ciphers**: Los modos de operación como **AES-256-CBC** requieren un Initialization Vector (IV) y PKCS#7 padding. Las arquitecturas modernas exigen modos de Authenticated Encryption with Associated Data (**AEAD**) como **AES-256-GCM** o **ChaCha20-Poly1305**, que proporcionan confidencialidad, integridad y autenticidad simultáneamente sin una construcción HMAC separada.
2. **Asymmetric Encryption & Key Exchange**: Utiliza pares de keys vinculados matemáticamente (public/private).
   - **RSA**: Se basa en la dificultad de la factorización de números primos. Los tamaños de key deben ser $\ge 2048$ bits (3072/4096 recomendado para workloads modernos).
   - **ECC (Elliptic Curve Cryptography)**: Se basa en el problema del logaritmo discreto de curva elíptica (ECDLP). Ofrece una seguridad equivalente a RSA con tamaños de key drásticamente menores (por ejemplo, `secp256r1`, `X25519`), reduciendo la latencia del TLS handshake y la sobrecarga del payload.
   - **Ephemeral Key Exchange (ECDHE)**: Garantiza **Perfect Forward Secrecy (PFS)** mediante la generación de pares de keys temporales por sesión. Las keys de sesión no pueden verse comprometidas incluso si la private key a largo plazo del servidor se filtra posteriormente.
3. **Cryptographic Hashing & MACs**:
   - **Cryptographic Hashes**: Funciones deterministas unidireccionales (SHA-256, SHA-3, BLAKE2). Resistentes a ataques de pre-image, second pre-image y collision attacks.
   - **HMAC (Hash-based Message Authentication Code)**: Combina una secret key con una función hash ($HMAC(K, M) = H((K' \oplus opad) \parallel H((K' \oplus ipad) \parallel M))$) para proporcionar autenticidad del mensaje.
4. **Public Key Infrastructure (PKI) & X.509**:
   - Confianza jerárquica anclada en Root Certificate Authorities (Root CAs) que emiten intermediate CAs, las cuales emiten certificados leaf de entidad final (end-entity).
   - Extensiones de key: `subjectAltName` (SAN) obligatorio para TLS moderno, `keyUsage`, `extendedKeyUsage` (serverAuth/clientAuth).

---

## Hands-On Guided Lab Exercises

### Exercise 1: Symmetric Cipher Selection & Authenticated Encryption (AES-GCM vs AES-CBC + HMAC)

#### Mechanics & Objective
Inspeccionar las propiedades criptográficas de AES en modo Cipher Block Chaining (CBC) frente a Galois/Counter Mode (GCM). Aprender cómo los ciphers no autenticados son vulnerables a ataques de bit-flipping a menos que se combinen explícitamente con un HMAC, y por qué AEAD (AES-GCM) es el estándar en producción.

#### Steps

1. Crear un directorio de workspace y un archivo secreto de entrada:
   ```bash
   mkdir -p ~/crypto-lab && cd ~/crypto-lab
   echo "CONFIDENTIAL: Database Connection String postgresql://appuser:SecretPass123@db.prod.internal:5432/appdb" > payload.txt
   ```

2. Encriptar el archivo utilizando **AES-256-CBC** con OpenSSL, salt explícito y key derivation:
   ```bash
   openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -in payload.txt -out payload.cbc.enc -pass pass:SuperStrongKey2026! -p
   ```
   *Snippet de salida esperada:*
   ```text
   salt=...
   key=...
   iv =...
   ```

3. Encriptar el mismo archivo utilizando **AES-256-GCM** (modo AEAD):
   ```bash
   openssl enc -aes-256-gcm -pbkdf2 -iter 100000 -in payload.txt -out payload.gcm.enc -pass pass:SuperStrongKey2026! -p
   ```

4. Realizar un intento de alteración (tampering) de 1 bit en el ciphertext de AES-CBC:
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

5. Intentar desencriptar el archivo CBC alterado:
   ```bash
   openssl enc -d -aes-256-cbc -pbkdf2 -iter 100000 -in payload.cbc.tampered.enc -out payload.cbc.dec -pass pass:SuperStrongKey2026!
   cat payload.cbc.dec
   ```
   *Snippet de salida esperada:* La decryption se completa (o falla en el padding), pero se emite plaintext corrupto sin verificación intrínseca de autenticidad.

6. Realizar el mismo ataque de byte-flip en el ciphertext de **AES-256-GCM**:
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
   *Snippet de salida esperada:*
   ```text
   bad decrypt
   C03058D101000000:error:1C800064:Provider routines:cipher_finalize_internal:bad decrypt:providers/implementations/ciphers/ciphercommon_gcm.c:386:
   ```

#### Verification Questions (Block 1)
1. ¿Por qué AES-256-CBC permite la salida de datos corruptos al desencriptar ciphertext alterado, mientras que AES-256-GCM se interrumpe inmediatamente?
2. ¿Qué rol desempeñan `-pbkdf2` e `-iter 100000` en la derivación de key simétrica a partir de contraseñas humanas?

---

### Exercise 2: Asymmetric Cryptography, Key Pair Generation, and Digital Signatures (RSA vs Ed25519)

#### Mechanics & Objective
Generar pares de keys RSA y Ed25519. Calcular hashes de mensajes, firmar mensajes y verificar firmas digitales para establecer la autenticidad y el no repudio en la seguridad de pipelines automatizados.

#### Steps

1. Generar una **Private Key RSA de 3072 bits** y extraer su public key:
   ```bash
   openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out rsa_private.pem
   openssl pkey -in rsa_private.pem -pubout -out rsa_public.pem
   ```

2. Generar un par de keys **Ed25519 (Edwards-curve Digital Signature Algorithm)**:
   ```bash
   openssl genpkey -algorithm Ed25519 -out ed25519_private.pem
   openssl pkey -in ed25519_private.pem -pubout -out ed25519_public.pem
   ```

3. Comparar los tamaños de archivo y las estructuras de key:
   ```bash
   wc -c rsa_private.pem ed25519_private.pem
   ```
   *Snippet de salida esperada:* La key RSA es significativamente más grande (~2.4 KB) en comparación con Ed25519 (~120 B).

4. Crear un manifiesto inmutable de artefacto de deployment:
   ```bash
   cat << 'EOF' > release-v1.2.0.manifest
   IMAGE_SHA256=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
   DEPLOY_ENV=production
   TIMESTAMP=2026-08-07T00:00:00Z
   EOF
   ```

5. Firmar el manifiesto utilizando la private key Ed25519:
   ```bash
   openssl pkeyutl -sign -inkey ed25519_private.pem -rawin -in release-v1.2.0.manifest -out manifest.sig
   ```

6. Verificar la firma digital utilizando la public key correspondiente:
   ```bash
   openssl pkeyutl -verify -pubin -inkey ed25519_public.pem -rawin -in release-v1.2.0.manifest -sigfile manifest.sig
   ```
   *Snippet de salida esperada:*
   ```text
   Signature Verified Successfully
   ```

7. Alterar el manifiesto del artefacto e intentar la verificación nuevamente:
   ```bash
   echo "EXTRA_ENV_VAR=HACKED" >> release-v1.2.0.manifest
   openssl pkeyutl -verify -pubin -inkey ed25519_public.pem -rawin -in release-v1.2.0.manifest -sigfile manifest.sig
   ```
   *Snippet de salida esperada:*
   ```text
   Signature Verification Failure
   ```

#### Verification Questions (Block 2)
1. ¿Por qué se prefiere Ed25519 sobre RSA-2048 o RSA-4096 en ingeniería de plataformas moderna para firmas digitales y autenticación SSH?
2. ¿Qué propiedad impide que un atacante forje `manifest.sig` incluso si `ed25519_public.pem` y `release-v1.2.0.manifest` son accesibles públicamente?

---

### Exercise 3: Production PKI Architecture — Certificate Authority (CA) Chain & SAN Certificate Issuance

#### Mechanics & Objective
Construir una Root CA offline, una Intermediate CA, generar una Certificate Signing Request (CSR) con extensiones `subjectAltName` (SAN), emitir un certificado leaf y validar la cadena de confianza completa.

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

1. Configurar las estructuras de directorios para Root CA e Intermediate CA:
   ```bash
   mkdir -p ~/crypto-lab/pki/{root,intermediate}
   cd ~/crypto-lab/pki
   ```

2. Crear la **configuración de Root CA** (`root/root.cnf`):
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

3. Inicializar y generar la **key de Root CA y el certificado auto-firmado**:
   ```bash
   openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 -out root/root_ca.key
   openssl req -new -x509 -config root/root.cnf -days 3650 -key root/root_ca.key -out root/root_ca.crt -extensions v3_ca
   ```

4. Crear la **configuración de Intermediate CA** (`intermediate/intermediate.cnf`):
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

5. Generar la Key & CSR de Intermediate CA, luego firmarla con la Root CA:
   ```bash
   openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 -out intermediate/intermediate.key
   openssl req -new -config intermediate/intermediate.cnf -key intermediate/intermediate.key -out intermediate/intermediate.csr

   openssl x509 -req -in intermediate/intermediate.csr -CA root/root_ca.crt -CAkey root/root_ca.key -CAcreateserial -out intermediate/intermediate.crt -days 1825 -extfile intermediate/intermediate.cnf -extensions v3_intermediate_ca
   ```

6. Generar una **key de certificado leaf de entidad final y CSR** para `api.prod.internal`:
   ```bash
   mkdir -p leaf
   openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:prime256v1 -out leaf/server.key
   openssl req -new -key leaf/server.key -out leaf/server.csr -subj "/C=US/O=Platform Team/CN=api.prod.internal"
   ```

7. Firmar el certificado leaf utilizando la Intermediate CA:
   ```bash
   openssl x509 -req -in leaf/server.csr -CA intermediate/intermediate.crt -CAkey intermediate/intermediate.key -CAcreateserial -out leaf/server.crt -days 365 -extfile intermediate/intermediate.cnf -extensions server_cert
   ```

8. Verificar la cadena de confianza completa utilizando `openssl verify`:
   ```bash
   # Create CA chain bundle
   cat intermediate/intermediate.crt root/root_ca.crt > ca-chain.crt
   openssl verify -CAfile ca-chain.crt leaf/server.crt
   ```
   *Snippet de salida esperada:*
   ```text
   leaf/server.crt: OK
   ```

#### Verification Questions (Block 3)
1. ¿Cuál es la vulnerabilidad técnica explícita de omitir `subjectAltName` (SAN) en certificados de servidor TLS modernos, incluso si el `Common Name` (CN) coincide con el dominio de destino?
2. ¿Qué impone `basicConstraints = critical, CA:true, pathlen:0` a nivel de la capa criptográfica para el certificado de Intermediate CA?

---

### Exercise 4: Transport Layer Security (TLS 1.3) Diagnostics & Deep Protocol Inspection

#### Mechanics & Objective
Configurar un listener TLS local usando OpenSSL, simular la negociación de ciphers, verificar los parámetros del TLS 1.3 handshake y diagnosticar errores de validación de certificados utilizando `openssl s_client`.

#### Steps

1. Iniciar un listener dual-stack `openssl s_server` utilizando el certificado leaf y la cadena completa generados en el Ejercicio 3:
   ```bash
   openssl s_server -accept 8443 -cert leaf/server.crt -key leaf/server.key -CAfile ca-chain.crt -www &
   SERVER_PID=$!
   sleep 2
   ```

2. Probar la conexión del cliente con un trust store del sistema **no confiable** (simulando un fallo de conexión predeterminado):
   ```bash
   openssl s_client -connect 127.0.0.1:8443 -servername api.prod.internal < /dev/null
   ```
   *Snippet de salida esperada:*
   ```text
   Verification error: unable to get local issuer certificate
   Verify return code: 20 (unable to get local issuer certificate)
   ```

3. Conectarse suministrando el `ca-chain.crt` explícito para la verificación de confianza:
   ```bash
   openssl s_client -connect 127.0.0.1:8443 -servername api.prod.internal -CAfile ca-chain.crt < /dev/null
   ```
   *Snippet de salida esperada:*
   ```text
   Verify return code: 0 (ok)
   Protocol  : TLSv1.3
   Cipher    : TLS_AES_256_GCM_SHA384
   Peer signing digest: SHA256
   Peer signature type: ECDSA
   ```

4. Forzar el protocolo heredado TLS 1.2 e inspeccionar la negociación de cipher suites:
   ```bash
   openssl s_client -connect 127.0.0.1:8443 -tls1_2 -CAfile ca-chain.crt < /dev/null | grep -E "Protocol|Cipher"
   ```

5. Limpiar el proceso del servidor en segundo plano:
   ```bash
   kill $SERVER_PID
   ```

#### Verification Questions (Block 4)
1. ¿Por qué TLS 1.3 elimina por completo los algoritmos de intercambio de keys RSA estáticos (por ejemplo, `TLS_RSA_WITH_AES_256_CBC_SHA`) de su especificación?
2. ¿Cuál es el rol de Server Name Indication (SNI) enviado a través de `-servername api.prod.internal` durante el paquete inicial TLS ClientHello?

---

### Exercise 5: Data-at-Rest Encryption & Key Derivation with LUKS2 (`cryptsetup`)

#### Mechanics & Objective
Crear un volumen de almacenamiento en bloque encriptado utilizando LUKS2 (Linux Unified Key Setup versión 2). Inspeccionar las funciones anti-forenses de key derivation (Argon2id), master key slots y metadatos del header del volumen.

#### Steps

1. Crear un archivo sparse de 100MB para simular un dispositivo de almacenamiento en bloque raw:
   ```bash
   cd ~/crypto-lab
   dd if=/dev/zero of=disk.img bs=1M count=100
   ```

2. Formatear el dispositivo de bloque virtual con **LUKS2** especificando la PBKDF `argon2id`:
   ```bash
   sudo cryptsetup luksFormat --type luks2 --pbkdf argon2id --cipher aes-xts-plain64 --key-size 512 disk.img --batch-mode --key-file <(echo -n "ProductionDiskSecretPass2026!")
   ```

3. Realizar un dump del header de LUKS para inspeccionar las protecciones de criptoanálisis y los parámetros de los key slots:
   ```bash
   sudo cryptsetup luksDump disk.img
   ```
   *Snippet de salida esperada:*
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

4. Abrir el mapping del dispositivo encriptado:
   ```bash
   sudo cryptsetup open disk.img secure_volume --key-file <(echo -n "ProductionDiskSecretPass2026!")
   ls -l /dev/mapper/secure_volume
   ```

5. Formatear con ext4, montar, escribir datos y cerrar el mapping:
   ```bash
   sudo mkfs.ext4 /dev/mapper/secure_volume
   mkdir -p /tmp/mnt_secure
   sudo mount /dev/mapper/secure_volume /tmp/mnt_secure
   echo "TOP_SECRET_PAYLOAD" | sudo tee /tmp/mnt_secure/confidential.dat

   # Clean up
   sudo umount /tmp/mnt_secure
   sudo cryptsetup close secure_volume
   ```

6. Intentar una inspección de bytes raw en `disk.img` para confirmar la aleatoriedad del ciphertext:
   ```bash
   strings disk.img | grep "TOP_SECRET_PAYLOAD"
   ```
   *Salida esperada:* Vacío (No hay strings de plaintext descubribles debido a la encriptación AES-XTS de alta entropía).

#### Verification Questions (Block 5)
1. ¿Por qué se prefiere `AES-XTS` sobre `AES-CBC` o `AES-GCM` para la encriptación de datos en reposo a nivel de disco/sector?
2. ¿Qué ventaja ofrece Argon2id sobre el PBKDF2 heredado en la derivación de keys del header de LUKS2?

---

<details>
<summary><strong>Respuestas y Explicaciones Detalladas</strong></summary>

### Block 1 Answers

1. **Fallo de Integridad en AES-CBC vs AES-GCM**:
   - **AES-CBC** proporciona únicamente confidencialidad. Se basa en el encadenamiento de bloques de cifrado (cipher block chaining) donde la decryption del bloque $N$ depende del bloque de ciphertext $N-1$. Un bit-flip en el bloque de ciphertext $N-1$ corrompe el bloque $N-1$ por completo durante la decryption, pero invierte el bit correspondiente exacto en el bloque de plaintext $N$ de manera predecible sin invalidar el algoritmo en sí mismo (a menos que falle la comprobación de padding PKCS#7).
   - **AES-GCM** es un modo AEAD (Authenticated Encryption with Associated Data). Añade una etiqueta de autenticación de 128 bits calculada a través de GHASH sobre el ciphertext y Additional Authenticated Data (AAD) opcionales. Durante la decryption, OpenSSL recalcula la etiqueta de autenticación. Si se modifica aunque sea un solo bit del ciphertext o de la etiqueta, la validación falla de inmediato y la salida se suprime.

2. **Rol de `-pbkdf2` y los Conteos de Iteraciones**:
   - Las contraseñas humanas carecen de suficiente entropía. Password-Based Key Derivation Function 2 (**PBKDF2**) aplica una función pseudo-aleatoria (como HMAC-SHA256) junto con un salt a la contraseña de forma repetida ($100,000+$ iteraciones).
   - Esto aumenta drásticamente la complejidad computacional de los ataques fuera de línea de diccionario y de fuerza bruta (brute-force attacks) al requerir ciclos masivos de CPU por cada evaluación de candidato a key.

---

### Block 2 Answers

1. **Ventajas de Ed25519 vs RSA**:
   - **Rendimiento y Tamaño de Key**: Las public keys Ed25519 son de 32 bytes y las firmas son de 64 bytes. Una key RSA-4096 equivalente es de 512 bytes, lo que causa un mayor costo de almacenamiento y de transmisión del payload en la red.
   - **Eficiencia Computacional**: Las operaciones de generación de key, firma y verificación de Ed25519 son órdenes de magnitud más rápidas que en RSA 3072/4096, reduciendo la carga de la CPU durante las verificaciones de firma por lotes (batch signature verifications).
   - **Resiliencia**: Ed25519 está diseñado para ser inmune a ataques de temporización por canales laterales (side-channel timing attacks) y trampas de implementación como generadores de números aleatorios débiles durante la firma (implementación determinista RFC 8032).

2. **Prevención de la Falsificación de Firmas**:
   - Las firmas digitales utilizan funciones asimétricas de trampa (trapdoor functions). La firma `manifest.sig` se genera utilizando la **private key** secreta ($S = \text{Sign}(K_{private}, \text{Hash}(M))$).
   - Cualquiera que posea la **public key** puede verificar que $S$ corresponde al mensaje $M$ mediante matemáticas de verificación pública, pero derivar $K_{private}$ a partir de $K_{public}$ o falsificar una firma válida $S'$ para un mensaje modificado $M'$ sin $K_{private}$ es computacionalmente inviable debido al Problema del Logaritmo Discreto en curvas de Edwards retorcidas (Twisted Edwards curves).

---

### Block 3 Answers

1. **Omitir `subjectAltName` (SAN)**:
   - Los navegadores web modernos y las librerías cliente TLS (Go `crypto/tls`, OpenSSL 1.1.1+, Chrome, Safari) ignoran por completo el campo `Common Name` (CN) durante la validación del hostname de acuerdo con la **RFC 6125** y la **RFC 2818**.
   - Si un certificado carece de entradas SAN, la validación TLS falla con `ERR_CERT_COMMON_NAME_INVALID` o excepciones equivalentes de verificación de dominio, dejando el certificado inservible en entornos de producción independientemente de que el CN coincida.

2. **Implicaciones de `basicConstraints = critical, CA:true, pathlen:0`**:
   - `CA:true` designa que el par de keys puede firmar certificados X.509 y CRLs de menor jerarquía (down-chain).
   - `pathlen:0` especifica que no se pueden emitir CAs intermedias adicionales por debajo de esta Intermediate CA. Solo puede emitir certificados leaf de entidad final. Si un atacante roba la private key de la Intermediate CA, no puede establecer CAs subordinadas para delegar derechos de firma a lo largo de una jerarquía profunda.
   - `critical` instruye a los parsers X.509 que DEBEN rechazar el certificado rotundamente si no entienden o no pueden aplicar la extensión de restricción.

---

### Block 4 Answers

1. **Eliminación del Intercambio de Keys RSA Estático en TLS 1.3**:
   - En el intercambio de keys RSA estático (TLS 1.2 y anteriores), el cliente encripta un pre-master secret utilizando la public key del servidor. El servidor lo desencripta utilizando su private key a largo plazo.
   - Si un adversario registra hoy el tráfico de red encriptado y roba la private key RSA a largo plazo del servidor en el futuro (a través de un compromiso, amenaza interna u orden judicial), el adversario puede desencriptar TODAS las sesiones pasadas grabadas.
   - TLS 1.3 exige el intercambio de keys Ephemeral Diffie-Hellman (**ECDHE**), garantizando **Perfect Forward Secrecy (PFS)**. Las keys de sesión son efímeras y se descartan inmediatamente después de la finalización de la sesión.

2. **Rol de Server Name Indication (SNI)**:
   - SNI es una extensión del protocolo TLS declarada en el paquete no encriptado `ClientHello`.
   - Permite al cliente especificar el nombre del dominio de destino (`api.prod.internal`) al que pretende llegar antes de que se establezca la conexión TLS. Esto permite a los reverse proxies multi-inquilino (multi-tenant) (por ejemplo, NGINX, Traefik, HAProxy, ingress controllers) seleccionar y servir el certificado TLS correcto para Virtual Hosts que comparten una única dirección IP.

---

### Block 5 Answers

1. **Por qué `AES-XTS` para Encriptación de Sectores/Discos**:
   - La encriptación de sectores de disco requiere un mapeo de longitud fija: encriptar un sector de 4096 bytes debe emitir exactamente 4096 bytes sin expansión de almacenamiento (sin espacio para IVs por sector ni etiquetas de autenticación como GCM, ni padding como CBC).
   - **XTS** (modo XEX-based tweaked-codebook con ciphertext stealing) utiliza dos keys AES y una key de tweak de sector para evitar que bloques de plaintext idénticos en diferentes sectores produzcan bloques de ciphertext idénticos, resistiendo ataques de reanimación/repetición de bloques (block replay) y análisis de patrones en dispositivos de almacenamiento.

2. **Argon2id vs PBKDF2 en LUKS2**:
   - **PBKDF2** es únicamente limitado por CPU (CPU-bound). Los atacantes pueden ejecutar ataques de fuerza bruta masivamente paralelos contra headers PBKDF2 utilizando circuitos integrados de aplicación específica (ASICs) personalizados o GPUs.
   - **Argon2id** (ganador de la Password Hashing Competition) es duro en memoria (memory-hard) y duro en tiempo (time-hard). Obliga a que el proceso de key derivation consuma una cantidad significativa de RAM configurada (por ejemplo, 64MB-1GB por intento) además de ciclos de CPU. Esto hace que la fuerza bruta paralela mediante GPU/ASIC sea económica y físicamente prohibitiva.

</details>

---

## Official Reference Documentation Links

- [LPI Security Essentials Objectives](https://www.lpi.org/our-certifications/security-essentials-overview/)
- [RFC 5280: Internet X.509 Public Key Infrastructure Certificate and CRL Profile](https://datatracker.ietf.org/doc/html/rfc5280)
- [RFC 8446: The Transport Layer Security (TLS) Protocol Version 1.3](https://datatracker.ietf.org/doc/html/rfc8446)
- [RFC 8032: Edwards-Curve Digital Signature Algorithm (EdDSA)](https://datatracker.ietf.org/doc/html/rfc8032)
- [OpenSSL Cryptographic Command-Line Documentation](https://www.openssl.org/docs/man3.0/man1/)
- [Linux cryptsetup / LUKS2 Wiki](https://gitlab.com/cryptsetup/cryptsetup/-/wikis/home)