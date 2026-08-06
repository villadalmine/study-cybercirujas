# Examen LPIC-3 303-300 (Versión 3.0) — Tema 331: Enterprise Cryptography

## Referencias Oficiales y Estándares
- [LPI LPIC-3 303 Exam Objectives (v3.0)](https://www.lpi.org/our-certifications/lpic-3-303-overview/)
- [RFC 5280: Internet X.509 Public Key Infrastructure Certificate and Certificate Revocation List (CRL) Profile](https://datatracker.ietf.org/doc/html/rfc5280)
- [RFC 8446: The Transport Layer Security (TLS) Protocol Version 1.3](https://datatracker.ietf.org/doc/html/rfc8446)
- [RFC 6960: X.509 Internet Public Key Infrastructure Online Certificate Status Protocol - OCSP](https://datatracker.ietf.org/doc/html/rfc6960)
- [RFC 4033: DNS Security Introduction and Requirements](https://datatracker.ietf.org/doc/html/rfc4033)
- [OpenSSL Cryptographic Library Documentation](https://www.openssl.org/docs/)
- [Linux Kernel dm-crypt / LUKS Documentation](https://gitlab.com/cryptsetup/cryptsetup/)

---

## 1. Fundamentos Arquitectónicos y Mecánica Interna

### 1.1 Mecánica de PKI X.509v3, Ciclo de Vida del Certificado y Revocación
Un certificado X.509v3 vincula una clave pública a una identidad (Distinguished Name o Subject Alternative Name) mediante una firma digital producida por una Certification Authority (CA) de confianza.

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

#### Mecánica de Extensiones X.509v3
- `basicConstraints = critical, CA:TRUE, pathlen:0`: Especifica si el sujeto es una CA. Si es `pathlen:0`, esta CA intermedia puede firmar certificados end-entity, pero no puede emitir CAs subordinadas.
- `keyUsage = critical, digitalSignature, keyEncipherment`: Restringe las operaciones criptográficas simples (por ejemplo, firmar paquetes frente a cifrar claves de sesión simétricas).
- `extendedKeyUsage = serverAuth, clientAuth`: Especifica roles de protocolo de alto nivel (Servidor TLS vs. Cliente TLS).
- `subjectAltName = DNS:example.com, IP:192.168.1.50`: El estándar moderno para la validación de nombres de host. Los navegadores y pilas TLS modernos ignoran estrictamente el `CommonName` (CN) para la verificación de identidad.

#### Arquitecturas de Revocación: CRL vs. OCSP Stapling
1. **Certificate Revocation Lists (CRLs)**: Un archivo DER/PEM firmado por la CA que contiene los números de serie de los certificados revocados.
   - *Compromiso (Trade-off)*: Alta latencia, consumo de ancho de banda y filtración de privacidad (los clientes consultan a la CA para cada validación).
2. **OCSP Stapling (RFC 6066)**: El servidor TLS consulta periódicamente al responder OCSP de la CA, recibe una aseveración OCSP firmada por la CA con marca de tiempo, y la "engancha" (staples) al TLS Handshake inicial (`ServerHello`).
   - *Compromiso (Trade-off)*: Elimina la latencia y las filtraciones de privacidad del lado del cliente; requiere que el servidor web tenga acceso de salida (egress) al URI de OCSP de la CA.

---

### 1.2 Mecánica de TLS 1.3, Cipher Suites y mTLS
TLS 1.3 (RFC 8446) reduce la latencia del handshake a **1-RTT** (o 0-RTT para sesiones reanudadas) y desaprueba (deprecates) primitivas criptográficas inseguras (intercambio de claves RSA, cifrados CBC, SHA-1, RC4).

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

#### Ephemeral Diffie-Hellman (ECDHE) y Forward Secrecy
En TLS 1.3, el intercambio de claves **debe** utilizar Ephemeral Diffie-Hellman (ECDHE con curva X25519 o P-256). Incluso si la clave privada de un servidor se ve comprometida en el futuro, el tráfico pasado registrado no se puede descifrar porque el material de intercambio de claves se descarta de la RAM inmediatamente después de la derivación de la clave de sesión.

#### Flujo del Protocolo Mutual TLS (mTLS)
Cuando el servidor envía un `CertificateRequest`, el cliente debe presentar un certificado X.509 cuya firma se valida contra el trust store `SSLCACertificateFile` configurado en el servidor.

---

### 1.3 Criptografía de Almacenamiento: Arquitectura de LUKS2 y dm-crypt
`dm-crypt` es un subsistema del kernel de Linux que proporciona cifrado transparente de dispositivos de bloques. `LUKS2` (Linux Unified Key Setup v2) proporciona el formato del encabezado en disco.

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

#### Componentes Clave:
1. **Volume Master Key**: Una clave aleatoria utilizada para cifrar los datos del payload. Nunca cambia cuando se actualizan las frases de paso (passphrases) del usuario.
2. **Key Slots**: LUKS2 admite hasta 32 key slots. Cada slot almacena una copia cifrada de la Master Key, protegida por una passphrase o keyfile individual utilizando **Argon2id** (Key Derivation Function de uso intensivo de memoria resistente a ataques de fuerza bruta por GPU/ASIC).
3. **Anti-Forensic Information Splitter (AFSplit)**: Previene la recuperación parcial de la clave distribuyendo el material de la clave a través de múltiples sectores del disco.

---

### 1.4 Arquitectura de Domain Name System Security Extensions (DNSSEC)
DNSSEC proporciona autenticidad de origen e integridad de datos a los registros DNS utilizando criptografía asimétrica.

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

#### Tipos de Registros Clave:
- **DNSKEY**: Contiene claves públicas (Flags: 256 = Zone Signing Key [ZSK], 257 = Key Signing Key [KSK]).
- **RRSIG**: Contiene la firma criptográfica para un Resource Record Set (RRset) específico.
- **DS (Delegation Signer)**: Almacenado en la zona padre; contiene el hash de la clave pública KSK de la zona hija, estableciendo la **Cadena de Confianza** (Chain of Trust).
- **NSEC / NSEC3**: Demuestra criptográficamente la no existencia de un registro DNS (negación autenticada de existencia) para prevenir respuestas NXDOMAIN falsificadas (spoofed).

---

## 2. Laboratorios Guiados de Producción

### Laboratorio 1: Construcción de una Jerarquía de CA Root Offline Blindada y CA Intermediate Online

#### Paso 1.1: Crear la Estructura de Directorios y Asegurar los Permisos del Sistema de Archivos
Ejecutá los siguientes comandos en una estación de trabajo administrativa para construir estructuras de directorios de CA aisladas.

```bash
[root@pki-node ~]# mkdir -p /etc/pki/CA/{root,intermediate}/{certs,crl,newcerts,private}
[root@pki-node ~]# chmod 700 /etc/pki/CA/{root,intermediate}/private
[root@pki-node ~]# touch /etc/pki/CA/root/index.txt /etc/pki/CA/intermediate/index.txt
[root@pki-node ~]# echo 1000 > /etc/pki/CA/root/serial
[root@pki-node ~]# echo 1000 > /etc/pki/CA/intermediate/serial
[root@pki-node ~]# echo 1000 > /etc/pki/CA/intermediate/crlnumber
```

#### Paso 1.2: Definir una Configuración de OpenSSL Sintácticamente Válida (`/etc/pki/CA/openssl.cnf`)
Creá el archivo de configuración autoritativo que rige las extensiones de clave y la aplicación de políticas.

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

#### Paso 1.3: Generar la Clave Cifrada de la Root CA y el Certificado Root Autosignado
Generá una clave Root RSA de 4096 bits cifrada con AES-256 y emití un certificado Root con validez de 10 años.

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

#### Paso 1.4: Generar la Clave de la Intermediate CA y Firmar la Solicitud
Generá una clave EC P-384 para la Intermediate CA, generá una CSR y firmala utilizando la Root CA con `pathlen:0`.

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

##### Verificación de la Salida Esperada:
Verificá que `basicConstraints` muestre estrictamente `CA:TRUE, pathlen:0`.

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

#### Paso 1.5: Emitir un Certificado de Servidor End-Entity con SAN y Verificar la Cadena
Creá una CSR end-entity para `api.internal.net` y firmala utilizando la Intermediate CA.

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

#### Paso 1.6: Concatenar la Cadena y Verificar Criptográficamente
Creá un bundle de cadena completa y verificá la confianza criptográfica contra la Root CA.

```bash
[root@pki-node ~]# cat /etc/pki/CA/intermediate/certs/intermediate.cert.pem /etc/pki/CA/root/certs/root.cert.pem > /etc/pki/CA/intermediate/certs/ca-chain.cert.pem
[root@pki-node ~]# openssl verify -CAfile /etc/pki/CA/root/certs/root.cert.pem \
      -untrusted /etc/pki/CA/intermediate/certs/intermediate.cert.pem \
      /etc/pki/CA/intermediate/certs/api.internal.net.cert.pem
```
##### Verificación de la Salida Esperada:
```text
/etc/pki/CA/intermediate/certs/api.internal.net.cert.pem: OK
```

---

### Preguntas de Verificación — Laboratorio 1
1. **¿Por qué la Root CA debe mantenerse offline y qué riesgo de seguridad mitiga `pathlen:0` en un certificado de Intermediate CA?**
2. **Si un certificado end-entity contiene `CommonName = api.internal.net` pero carece de `subjectAltName`, ¿cómo manejarán el establecimiento de la conexión las pilas TLS modernas (como Chrome o la biblioteca estándar de Go)?**

---

### Laboratorio 2: Blindaje de Apache HTTPD para TLS 1.3, mTLS y Análisis de Diagnóstico

#### Paso 2.1: Implementar la Configuración TLS de Apache para Producción (`/etc/httpd/conf.d/ssl.conf`)
Configurá Apache HTTPD para admitir **únicamente TLS 1.3 y cipher suites blindados de TLS 1.2**, habilitá mTLS en la ubicación `/secure` y habilitá OCSP stapling.

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

#### Paso 2.2: Probar el TLS Handshake, la Negociación de Protocolo y la Reanudación de Sesión utilizando `openssl s_client`
Simulá conexiones de clientes para inspeccionar la negociación de protocolos y las cipher suites negociadas.

```bash
[root@pki-node ~]# openssl s_client -connect 127.0.0.1:443 -servername api.internal.net \
      -CAfile /etc/pki/CA/intermediate/certs/ca-chain.cert.pem -tls1_3
```

##### Verificación de la Salida Esperada:
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

#### Paso 2.3: Verificar la Aplicación de la Autenticación mTLS
Intentá acceder a `/secure` sin un certificado de cliente, esperá un error de alerta TLS, y luego volvé a probar presentando un certificado de cliente válido emitido por la Intermediate CA.

##### Prueba A: Fallo de Conexión (Falta el Certificado de Cliente)
```bash
[root@pki-node ~]# curl --cacert /etc/pki/CA/intermediate/certs/ca-chain.cert.pem https://api.internal.net/secure
```
##### Verificación de la Salida Esperada:
```text
curl: (56) OpenSSL SSL_read: error:14094412:SSL routines:ssl3_read_bytes:sslv3 alert handshake failure, errno 0
```

##### Prueba B: Conexión Exitosa con Certificado de Cliente Firmado
Generá el certificado de cliente, firmalo con la Intermediate CA y ejecutá la solicitud mTLS:

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
##### Verificación de la Salida Esperada:
```text
HTTP/1.1 200 OK
Date: Thu, 06 Aug 2026 13:10:00 GMT
Server: Apache/2.4.57 (Red Hat Enterprise Linux)
Strict-Transport-Security: max-age=63072000; includeSubDomains; preload
```

---

### Preguntas de Verificación — Laboratorio 2
1. **¿Cuál es la diferencia estructural entre configurar `SSLHonorCipherOrder On` frente a `Off` al negociar conexiones TLS 1.3 frente a TLS 1.2?**
2. **Si un atacante realiza un ataque Man-in-the-Middle (MitM) en una solicitud HTTP inicial antes de que el cliente almacene en caché HSTS, ¿cómo mitiga esta vulnerabilidad el HSTS Preloading?**

---

### Laboratorio 3: Cifrado Transparente de Disco con LUKS2, Argon2id y Gestión de Key Slots

#### Paso 3.1: Preparar el Dispositivo Loop de Almacenamiento
Creá una imagen raw dispersa (sparse) de 1GB y vinculala a un dispositivo loop para simular un nuevo dispositivo de bloques físico.

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

#### Paso 3.2: Formatear el Volumen utilizando LUKS2 y Argon2id KDF
Formateá el dispositivo de bloques con LUKS2, especificando el cifrado AES-XTS-256, una clave de volumen de 512 bits y un hashing Argon2id de uso intensivo de memoria.

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

#### Paso 3.3: Inspeccionar los Metadatos del Encabezado LUKS2
Volcá (dump) los detalles del encabezado para verificar los key slots y las especificaciones criptográficas.

```bash
[root@storage-node ~]# cryptsetup luksDump ${LOOP_DEV}
```
##### Verificación de la Salida Esperada:
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

#### Paso 3.4: Agregar un Key Slot para Keyfile y Realizar Backup del Encabezado
Agregá un segundo key slot utilizando un keyfile de 4096 bits (ideal para el montaje automatizado sin intervención/headless) y exportá el encabezado LUKS para recuperación ante desastres.

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

#### Paso 3.5: Abrir el Volumen, Crear el Sistema de Archivos y Configurar Montajes Persistentes
Abrí el mapeo cifrado utilizando `cryptsetup`, construí un sistema de archivos XFS y actualizá `/etc/crypttab` y `/etc/fstab`.

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

### Preguntas de Verificación — Laboratorio 3
1. **Si se olvida la passphrase del Key Slot 0, ¿puede un administrador del sistema acceder a los datos utilizando el Key Slot 1? ¿Qué sucede si el encabezado LUKS2 se daña por corrupción de sectores crudos (raw)?**
2. **¿Por qué se utiliza el modo AES-XTS para el cifrado de almacenamiento de bloques en lugar de modos AEAD de transmisión como AES-GCM?**

---

### Laboratorio 4: Firma Autoritativa de Zonas DNSSEC y Verificación de Trust Anchors

#### Paso 4.1: Configurar la Zona Autoritativa de BIND9 (`/etc/named.conf`)
Definí una zona primaria para `example.lab` con la validación DNSSEC y la firma en línea (inline signing) habilitadas.

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

#### Paso 4.2: Construir el Archivo de Zona Raw sin Firmar (`/var/named/dynamic/example.lab.zone`)
Creá los registros estándar SOA, NS y A.

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

#### Paso 4.3: Generación Manual de Claves y Firma de Zona utilizando Herramientas de CLI
Generá explícitamente claves KSK y ZSK RSASHA256 utilizando `dnssec-keygen`, y firmá la zona utilizando `dnssec-signzone`.

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

##### Verificación de la Salida Esperada:
```text
Verifying the zone using the following algorithms: RSASHA256.
Zone signing complete:
Algorithm: RSASHA256: KSKs: 1 active, 0 stand-by, 0 revoked
                      ZSKs: 1 active, 0 stand-by, 0 revoked
/var/named/dynamic/example.lab.zone.signed created successfully.
```

#### Paso 4.4: Extraer el Registro DS para la Delegación del Padre
Extraé el digest del registro Delegation Signer (DS) para enviarlo al registro padre.

```bash
[root@dns-node keys]# dnssec-dsfromkey Kexample.lab.+008+12345.key
```
##### Verificación de la Salida Esperada:
```text
example.lab. IN DS 12345 8 1 9abcdef0123456789abcdef0123456789abcdef0
example.lab. IN DS 12345 8 2 A1B2C3D4E5F67890123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0
```

#### Paso 4.5: Diagnosticar y Verificar Registros DNSSEC con `dig` y `delv`
Consultá registros DNSSEC (`RRSIG`, `DNSKEY`) y rastreá las cadenas de validación criptográfica.

```bash
[root@dns-node ~]# dig @127.0.0.1 app.example.lab +dnssec +multiline
```

##### Verificación de la Salida Esperada:
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

##### Rastreando la Cadena de Trust Anchors con `delv`:
```bash
[root@dns-node ~]# delv @127.0.0.1 -a /var/named/keys/Kexample.lab.+008+12345.key +rtrace app.example.lab
```
##### Verificación de la Salida Esperada:
```text
;; fetch: app.example.lab/A
;; root key trust status: trusted
;; fully validated
app.example.lab.	86400 IN A 10.0.5.50
app.example.lab.	86400 IN RRSIG A 8 3 86400 20260905130000 20260806130000 67890 example.lab. ...
```

---

### Preguntas de Verificación — Laboratorio 4
1. **¿Cuál es el propósito operativo de mantener separadas las Key Signing Keys (KSK) y las Zone Signing Keys (ZSK), en lugar de utilizar una sola clave para todas las firmas?**
2. **Si un servidor autoritativo responde con un registro NSEC3 al consultar un host inexistente `missing.example.lab`, ¿cómo previene NSEC3 el recorrido/enumeración de zona (zone walking) en comparación con el NSEC estándar?**

---

<details>
<summary><strong>Hacé clic para desplegar: Respuestas a las Preguntas de Verificación y Explicaciones</strong></summary>

### Respuestas a las Preguntas de Verificación del Laboratorio 1
1. **Justificación de la Root CA Offline y Restricciones de Longitud de Ruta (Path Length)**:
   - La clave de la Root CA es el trust anchor absoluto de todo el ecosistema PKI. Si se ve comprometida, cada certificado de la cadena se vuelve inválido, lo que requiere una costosa reemisión y despliegue de nuevos trust stores en todos los endpoints. Mantener la Root CA estrictamente offline (air-gapped) previene ataques basados en la red.
   - `pathlen:0` restringe estrictamente que la Intermediate CA firme CAs subordinadas. *Solo* puede emitir certificados end-entity. Si un atacante compromete la clave de la Intermediate CA, no podrá generar sub-CAs maliciosas para construir subjerarquías profundas y no rastreadas.

2. **CommonName vs. Subject Alternative Name (SAN)**:
   - El RFC 5280 y las políticas de seguridad web modernas (RFC 6125) exigen `subjectAltName` para la validación de identidad.
   - Si falta `subjectAltName`, las implementaciones modernas (como Chrome, Go `crypto/tls` y OpenSSL 3.x) rechazarán inmediatamente la conexión con un error `x509: certificate relies on legacy Common Name field`, independientemente de si `CommonName` coincide con el nombre del host.

---

### Respuestas a las Preguntas de Verificación del Laboratorio 2
1. **Mecánica de Negociación del Orden de Cifrado**:
   - En **TLS 1.2**, `SSLHonorCipherOrder On` fuerza al servidor a elegir la cipher suite en función de su propia lista de preferencias, anulando la lista preferida del cliente. Esto evita que los clientes elijan cifrados de reserva (fallback) más débiles.
   - En **TLS 1.3**, `SSLHonorCipherOrder` se ignora por diseño. TLS 1.3 limita los cifrados simétricos a cinco algoritmos AEAD altamente seguros (por ejemplo, `TLS_AES_256_GCM_SHA384`, `TLS_CHACHA20_POLY1305_SHA256`). Todas las suites aceptables son igualmente seguras, por lo que la selección de preferencia del cliente no introduce riesgos de degradación (downgrade) criptográfica.

2. **Arquitectura de HSTS Preloading**:
   - El HSTS estándar se basa en "Trust on First Use" (TOFU). El cliente recibe el encabezado HTTP `Strict-Transport-Security` en su respuesta HTTPS inicial y lo almacena en caché. Sin embargo, la *primerísima* solicitud HTTP no cifrada sigue siendo vulnerable a la intercepción MitM y a ataques de despojo (strip attacks, ej. SSLstrip).
   - El **HSTS Preloading** codifica (hardcodes) el dominio directamente en las distribuciones del código fuente del navegador. Los navegadores aplican automáticamente `https://` antes de emitir cualquier paquete de red, eliminando por completo la vulnerabilidad del arranque HTTP inicial.

---

### Respuestas a las Preguntas de Verificación del Laboratorio 3
1. **Descifrado Multislot de LUKS2 y Protección de Encabezado**:
   - Sí, cualquier key slot válido puede descifrar de manera independiente la Volume Master Key. Perder la passphrase del Key Slot 0 no tiene ningún efecto en el acceso a través del Key Slot 1.
   - Si los sectores del encabezado LUKS2 en el disco se corrompen o sobrescriben físicamente, la Master Key se pierde permanentemente, haciendo que la recuperación de los datos del payload sea matemáticamente imposible. Esto resalta por qué preservar copias de seguridad del encabezado fuera del host (`cryptsetup luksHeaderBackup`) es esencial para la recuperación ante desastres en SRE.

2. **Modo XTS-AES vs. AEAD (GCM) en Almacenamiento de Bloques**:
   - El almacenamiento por sectores de disco requiere **operaciones de lectura/escritura de tamaño fijo** (por ejemplo, haciendo coincidir directamente los límites de sectores de 512 bytes o 4096 bytes).
   - Los modos de cifrado autenticado (Authenticated Encryption) como AES-GCM adjuntan una etiqueta de autenticación (Authentication Tag, típicamente de 16 bytes por bloque) y requieren vectores de inicialización (IVs). Esto introduce expansión de datos, causando un desalineamiento físico de los sectores. **AES-XTS** es un cifrado ajustable (tweakable) de bloque estrecho que cifra los bloques in situ (in-place) sin alterar el tamaño de los datos.

---

### Respuestas a las Preguntas de Verificación del Laboratorio 4
1. **Mecánica Operativa de la Rotación de Claves KSK vs. ZSK**:
   - Las **Zone Signing Keys (ZSK)** se utilizan con frecuencia para firmar actualizaciones dinámicas de registros dentro de la zona. Debido a que se usan a menudo, deben rotarse con frecuencia (por ejemplo, cada 30–90 días). El uso de un tamaño de clave más pequeño (1024/2048 bits) mantiene pequeños los tamaños de los paquetes `RRSIG` y reduce los vectores de amplificación DNS.
   - Las **Key Signing Keys (KSK)** firman *únicamente* el RRset `DNSKEY`. Debido a que rotar una KSK requiere actualizar el registro `DS` de la zona padre a través de APIs de registradores externos o coordinación con el registro, las rotaciones de KSK son complejas y poco frecuentes (por ejemplo, anuales). Separar las claves permite a los administradores rotar las ZSKs localmente sin involucrar al registro de la zona padre.

2. **Mitigación de Enumeración de Zona NSEC vs. NSEC3**:
   - Los registros **NSEC** estándar apuntan directamente al *siguiente* nombre de registro existente en orden canónico (por ejemplo, `app.example.lab IN NSEC db.example.lab`), lo que permite a los atacantes recorrer la zona (zone walking) mediante consultas repetidas de registros inexistentes para enumerar todos los nombres de host válidos.
   - **NSEC3** mitiga esto reemplazando los nombres de registro en texto plano con hashes criptográficos iterados y con sal (salted) (por ejemplo, `35MQ... IN NSEC3 1 0 10 AABB CCDD...`). Esto demuestra la no existencia sin revelar nombres de host en texto plano, previniendo el recorrido de la zona.

</details>