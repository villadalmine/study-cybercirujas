# LPI Security Essentials (020-100) — Tema 2.1: Cifrado

**Peso del tema del examen:** 20  
**Rol objetivo:** Senior SRE / Platform Architect  

---

## 1. Motivación en producción y problema arquitectónico

### 1.1 Declaración del problema en producción
Los entornos modernos nativos de la nube operan sobre infraestructura dinámica y multitenant donde los límites físicos de red ya no implican confianza. En sistemas distribuidos de alto rendimiento (high-throughput), los volúmenes de almacenamiento persistente se mueven entre nodos, las cargas de trabajo de cómputo se ejecutan en hipervisores compartidos y los microservicios de Ingress atraviesan redes no confiables entre regiones.

Sin límites criptográficos estrictos, la infraestructura está expuesta a cuatro modos principales de falla:
1. **Exfiltración de datos a través del robo de volúmenes físicos/lógicos:** Las imágenes de disco no cifradas (`/dev/sda`, cloud block stores) se pueden adjuntar a instancias de cómputo maliciosas, ignorando los permisos de directorio POSIX.
2. **Man-in-the-Middle (MitM) e intercepción de tráfico (Wiretapping):** Las comunicaciones intra-cluster en texto plano (HTTP, gRPC no cifrado, conexiones a bases de datos simples) permiten la intercepción no autorizada de paquetes y el secuestro de sesiones (session hijacking) a través de redes superpuestas (overlay networks) virtualizadas.
3. **Configuración criptográfica errónea y cifrados heredados (Legacy Ciphers):** Los sistemas que utilizan algoritmos obsoletos (RSA-1024, MD5, SHA-1, 3DES, cifrados en modo CBC sin MAC) sufren vulnerabilidades estructurales como ataques de padding oracle, ataques de extensión de longitud y riesgos de colisión por fuerza bruta.
4. **Falla en el ciclo de vida de claves y dispersión de claves (Key Sprawl):** Las credenciales hardcodeadas, las raíces de Autoridades Certificadoras (CA) sin rotar y las claves de cifrado de datos (Data Encryption Keys - DEKs) estáticas crean puntos únicos de falla sistémicos en toda la flota.

### 1.2 Principios arquitectónicos: Zero Trust y Envelope Encryption
Para lograr el cumplimiento de defensa en profundidad (NIST SP 800-53, PCI-DSS 4.0, ISO 27001), los ingenieros de plataforma aplican tres dominios respaldados criptográficamente:
* **Datos en tránsito (Data-in-Transit) (TLS 1.3 / mTLS / SSHv2):** Impone la autenticación de pares y el intercambio dinámico de claves Ephemeral Diffie-Hellman (ECDHE) para garantizar la Confidencialidad Directa Perfecta (Perfect Forward Secrecy - PFS). Si una clave privada a largo plazo se ve comprometida, el tráfico histórico permanece indescifrable.
* **Datos en reposo (Data-at-Rest) (LUKS2 / AES-256-GCM / Envelope Encryption):** Combina claves de cifrado de datos locales (DEKs) para cifrado de bloques/objetos con claves de cifrado de claves (Key Encryption Keys - KEKs) administradas por Módulos de Seguridad de Hardware (HSMs) o Servicios de Gestión de Claves (KMS) centrales.
* **Datos en uso (Data-in-Use) (Confidential Computing / Secure Enclaves):** Utiliza cifrado de memoria a nivel de hardware (AMD SEV-SNP, Intel SGX) para proteger el texto plano en memoria durante el procesamiento.

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

## 2. Comparaciones técnicas y análisis de compensaciones (Trade-Offs)

### 2.1 Clasificación de primitivas y características

Las primitivas criptográficas se dividen en tres categorías principales:
1. **Cifrados simétricos (Symmetric Ciphers):** Una única clave secreta compartida para cifrado y descifrado. Optimizados para transmisión de datos en flujo (streaming) y alto rendimiento (throughput) a través de conjuntos de instrucciones de hardware (AES-NI).
2. **Cifrados asimétricos (Asymmetric Ciphers):** Pares de claves pública-privada basados en supuestos de complejidad matemática (Factorización de enteros, Logaritmo discreto, Logaritmo discreto de curva elíptica). Utilizados para bootstrap de identidad, firmas digitales y encapsulación de claves.
3. **Hashes criptográficos y KDFs de contraseñas:** Funciones deterministas unidireccionales que mapean longitudes de entrada arbitrarias a arreglos de bits de tamaño fijo. Las funciones de derivación de claves de contraseña (Password Key Derivation Functions - KDFs) agregan intencionalmente requisitos intensivos de cómputo y memoria para frustrar los intentos de fuerza bruta por GPU/ASIC.

### 2.2 Matriz detallada de compensaciones (Trade-Offs)

| Categoría de primitiva | Algoritmo / Estándar | Nivel de seguridad (Bits) | Rendimiento / Throughput | Consumo de recursos | Caso de uso principal en producción | Vulnerabilidades conocidas y Trade-offs |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Symmetric Cipher** | `AES-256-GCM` | 256 | ~3.5–6.0 GB/s (Acelerado por hardware) | Bajo CPU, RAM despreciable | Almacenamiento en bloques (LUKS2), capa de registro TLS 1.3 | Requiere estricta unicidad del Nonce; la reutilización del Nonce destruye la etiqueta de autenticación y filtra texto plano. |
| **Symmetric Cipher** | `ChaCha20-Poly1305` | 256 | ~1.2–2.5 GB/s (Optimizado por software) | Bajo CPU, RAM despreciable | Clientes móviles, IoT, plataformas que carecen de AES-NI | Más lento que AES-NI por hardware; resistente a ataques de canal lateral de temporización en hardware de gama baja. |
| **Asymmetric Cipher** | `RSA-4096` | 128 | ~100 ops/sec (Firma/Descifrado) | Altos picos de CPU en el handshake | PKI heredada, CAs raíz, transporte de claves | Firmas/claves extremadamente grandes (4096 bits); operaciones lentas; vulnerable a ataques de canal lateral. |
| **Asymmetric Cipher** | `ECDSA (P-256 / P-384)`| 128 / 192 | ~3,500 ops/sec | CPU moderado | Certificados TLS estándar, API gateways | Requiere generadores de números aleatorios (RNG) criptográficamente seguros para el nonce de firma $k$. Un RNG deficiente filtra la clave privada. |
| **Asymmetric Cipher** | `Ed25519 (EdDSA)` | 128 | ~12,000 ops/sec | Bajo CPU, tamaño de clave muy pequeño (pubkey de 32 bytes) | Autenticación SSH, firma moderna de commits de Git | Los parámetros fijos evitan malas configuraciones; no soportado por sistemas empresariales heredados más antiguos. |
| **Hash Function** | `SHA-256 / SHA-512` | 256 / 512 | ~500 MB/s | Bajo cómputo | Integridad de archivos, firmas HMAC, árboles de Merkle | Vulnerable a ataques de extensión de longitud (utilice HMAC-SHA256 o SHA-3 para hashing secreto). |
| **Password KDF** | `Argon2id` | Ajustable | Intencionalmente lento (ej. 50ms–500ms por operación) | **RAM alta** (ej. 64MB–1GB por hash) | Almacenamiento de credenciales de usuario, derivación de claves LUKS2 | El alto consumo de RAM lo hace vulnerable a denegación de servicio (DoS) si APIs no autenticadas lo activan de forma concurrente. |

---

## 3. Manifiestos de producción completos y configuraciones de infraestructura

### 3.1 Configuración endurecida (Hardened) de CA Raíz e Intermedia de OpenSSL (`openssl.cnf`)

A continuación se presenta un archivo de configuración de OpenSSL completo y sintácticamente válido que establece una CA intermedia con las extensiones adecuadas, flags de Key Usage y restricciones X.509 v3.

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

### 3.2 Manifiesto de Certificate y ClusterIssuer de Cert-Manager para producción en Kubernetes

Este manifiesto de producción configura `cert-manager` para emitir certificados TLS dinámicos respaldados por un motor PKI privado de HashiCorp Vault, incluyendo SANs explícitos, configuraciones de tamaño de clave y parámetros de rotación de claves.

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

### 3.3 Cifrado de almacenamiento en Linux de producción (Configuración de `/etc/crypttab` y LUKS2)

Manifiesto de configuración para el desbloqueo automatizado y seguro de volúmenes al arrancar (boot), utilizando archivos de clave (keyfiles) almacenados en sistemas de archivos root restringidos con parámetros PBKDF Argon2id.

```bash
# Configuration schema for /etc/crypttab
# <target name>    <source device>         <key file>                   <options>
data_vol01         UUID=a1b2c3d4-e5f6-7890-abcd-1234567890ab    /etc/keys/data_vol01.key     luks,cipher=aes-256-gcm:random,hash=sha512,discard
```

---

### 3.4 Configuración endurecida de servidor OpenSSH (`/etc/ssh/sshd_config.d/hardened.conf`)

Esta configuración impone primitivas criptográficas modernas, deshabilita claves de host débiles, restringe algoritmos de autenticación y bloquea por completo las opciones del protocolo SSH heredado.

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

## 4. Ejecución práctica de CLI y salidas reales de terminal

### 4.1 Generación de certificados Raíz y Hoja de PKI mediante OpenSSL

#### Comando: Generación de una clave privada Ed25519 y certificado autosignado
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

#### Comando: Verificación de detalles del certificado y extensiones X.509v3
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

### 4.2 Formateo de partición LUKS2 y benchmark de derivación de claves

#### Comando: Formateo de un dispositivo de bloques de disco con LUKS2 y Argon2id
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

#### Comando: Inspección de los metadatos del encabezado de cifrado LUKS2
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

### 4.3 Inspección activa de TLS mediante `openssl s_client`

#### Comando: Prueba de negociación de cifrado TLS 1.3 y cadena de certificados
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

### 4.4 Hashing criptográfico y verificación de integridad

#### Comando: Cálculo de hashes multialgoritmo
```bash
$ echo -n "PlatformArchitecture2026" | sha256sum
```
```text
452ab90018597406a4b130dbd5d9c223c72b22f67215a31b4ab4b6009a25dbdb  -
```

#### Comando: Hashing de contraseñas con CLI de Argon2
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

## 5. Resolución de problemas, flujos de trabajo de diagnóstico y verificación de fallas

### 5.1 Matriz de decisión de diagnóstico para fallas criptográficas comunes

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

| Síntoma / Salida de log | Causa raíz | Comando de verificación | Acción de remediación |
| :--- | :--- | :--- | :--- |
| `SSL3_GET_SERVER_CERTIFICATE:certificate verify failed` | Falta la CA intermedia en el bundle o certificado expirado. | `openssl verify -CAfile ca-chain.pem server.crt` | Concatenar el certificado de dominio y las CAs intermedias en un solo archivo bundle (`cat server.crt intermediate.crt > fullchain.pem`). |
| `tls: no cipher suite supported by both client and server` | Requisitos incompatibles de cipher suite (ej. el cliente impone TLS 1.3 AEAD; el servidor está configurado para TLS 1.2 CBC heredado). | `openssl s_client -connect <host>:443 -cipher 'ECDHE-RSA-AES128-GCM-SHA256'` | Actualizar la configuración del servidor (ej. NGINX/Envoy) para incluir cifrados modernos TLS 1.2/1.3 (`Ciphers` / `CipherSuites`). |
| `Host key verification failed.` | La clave de host de SSH cambió (potencial MitM o instancia reconstruida). | `ssh-keygen -R <hostname_or_ip>` | Auditar la huella digital (fingerprint) del servidor fuera de banda; eliminar la entrada antigua de `~/.ssh/known_hosts`. |
| `No key available with this passphrase.` | Frase de contraseña (passphrase) incorrecta, desajuste de slot LUKS o agotamiento de memoria durante la derivación de Argon2id. | `sudo cryptsetup luksOpen --debug /dev/sdb1 data_vol` | Comprobar la memoria RAM libre del sistema. Si la RAM del host es inferior a `pbkdf-memory` de Argon2id, la ejecución falla por OOM. |
| `Permission denied (publickey).` | Permisos de archivo incorrectos en las claves de cliente SSH (`.ssh/id_rsa` legible por grupo/mundo). | `ls -la ~/.ssh/id_ed25519` | Aplicar permisos POSIX strictly: `chmod 700 ~/.ssh && chmod 600 ~/.ssh/id_ed25519`. |

---

### 5.2 Playbook de diagnóstico paso a paso

#### Escenario: Depuración de una conexión de Ingress con Mutual TLS (mTLS) con fallas
Cuando un microservicio interno no logra autenticarse con un servicio aguas arriba (upstream) a través de mTLS, ejecute la siguiente secuencia de diagnóstico paso a paso:

1. **Probar la alcanzabilidad de red TLS y la expiración del certificado:**
   ```bash
   $ openssl s_client -connect service.internal.net:443 -servername service.internal.net -brief
   ```
   *Salida esperada para certificado de cliente faltante:*
   ```text
   CONNECTION ESTABLISHED
   Protocol version: TLSv1.3
   Ciphersuite: TLS_AES_256_GCM_SHA384
   ALERT RAY: fatal, bad_certificate
   140321251919616:error:0A00045C:SSL routines:ssl3_read_bytes:tlsv13 alert bad certificate:ssl/record/rec_layer_s3.c:1584:
   ```

2. **Proporcionar el certificado de cliente y la clave privada:**
   ```bash
   $ openssl s_client -connect service.internal.net:443 \
       -cert client.crt -key client.key -CAfile ca-chain.pem -brief
   ```
   *Salida esperada al resolver:*
   ```text
   CONNECTION ESTABLISHED
   Protocol version: TLSv1.3
   Ciphersuite: TLS_AES_256_GCM_SHA384
   Verification: OK
   ```

3. **Verificar que el módulo/fingerprint de la clave y el certificado coincidan:**
   Si OpenSSL devuelve `key values mismatch`, verifique que la clave pública extraída de la clave privada coincida con la clave pública dentro del certificado X.509:
   ```bash
   $ openssl x509 -in client.crt -pubkey -noout | sha256sum
   $ openssl pkey -in client.key -pubkey -noout | sha256sum
   ```
   *Las salidas deben coincidir idénticamente:*
   ```text
   e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  -
   e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  -
   ```

---

## 6. Referencias

* **Visión general oficial de Linux Professional Institute (LPI) Security Essentials:**  
  [https://www.lpi.org/our-certifications/security-essentials-overview/](https://www.lpi.org/our-certifications/security-essentials-overview/)

* **RFC 8446 — El protocolo Transport Layer Security (TLS) versión 1.3:**  
  [https://www.rfc-editor.org/rfc/rfc8446](https://www.rfc-editor.org/rfc/rfc8446)

* **RFC 8037 — Algoritmo de firma digital de curva Edwards (EdDSA) en JOSE / PKI:**  
  [https://www.rfc-editor.org/rfc/rfc8037](https://www.rfc-editor.org/rfc/rfc8037)

* **Hoja de referencia de almacenamiento criptográfico de OWASP (Cryptographic Storage Cheat Sheet):**  
  [https://cheatsheetseries.owasp.org/cheatsheets/Cryptographic_Storage_Cheat_Sheet.html](https://cheatsheetseries.owasp.org/cheatsheets/Cryptographic_Storage_Cheat_Sheet.html)

* **Hoja de referencia de Transport Layer Security de OWASP (Transport Layer Security Cheat Sheet):**  
  [https://cheatsheetseries.owasp.org/cheatsheets/Transport_Layer_Security_Cheat_Sheet.html](https://cheatsheetseries.owasp.org/cheatsheets/Transport_Layer_Security_Cheat_Sheet.html)

* **Documentación oficial y Wiki de OpenSSL:**  
  [https://wiki.openssl.org/](https://wiki.openssl.org/)

* **Documentación de Linux cryptsetup y LUKS2:**  
  [https://gitlab.com/cryptsetup/cryptsetup](https://gitlab.com/cryptsetup/cryptsetup)

* **Documentación de Kubernetes Secrets y Cert-Manager:**  
  [https://kubernetes.io/docs/concepts/configuration/secret/](https://kubernetes.io/docs/concepts/configuration/secret/)  
  [https://cert-manager.io/docs/](https://cert-manager.io/docs/)