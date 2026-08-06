# LPIC-3 Security (Exam 303-300 v3.0) — Topic 331: Cryptography

---

## 1. Problema de Arquitectura de Producción y Motivación del Sistema

### 1.1 El Panorama de Amenazas Empresariales y el Mandato Zero-Trust
En la arquitectura de plataformas empresariales modernas, los modelos de seguridad basados únicamente en el perímetro (como límites de firewalls y VLANs privadas) no logran contener el movimiento lateral tras brechas de red iniciales. Las plataformas de infraestructura modernas—compuestas por clusters de Kubernetes multirregión, mallas de microservicios, bases de datos distribuidas y pipelines de CI/CD automatizados—deben operar bajo un régimen estricto de **Zero-Trust Architecture (ZTA)** según lo estandarizado en [NIST SP 800-207](https://csrc.nist.gov/publications/detail/sp/800-207/final).

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

Sin verificación criptográfica de identidad, cifrado en tránsito y cifrado en reposo:
1. **Ataques Man-in-the-Middle (MitM) y Spoofing:** El transporte interno en texto plano expone JWTs sensibles, tokens de API y PII de clientes a escuchas no autorizadas en la red, inserción de paquetes y secuestro de DNS mediante envenenamiento de caché.
2. **Exfiltración de Datos en Reposo:** El robo de dispositivos de almacenamiento por bloques, volúmenes SAN huérfanos o el acceso no autorizado a snapshots de hipervisores filtran registros de bases de datos no cifrados.
3. **Colapsos en la Cadena de Certificados:** Infraestructuras de Clave Pública (PKIs) mal configuradas con extensiones X.509 v3 faltantes (`basicConstraints`, `keyUsage`), algoritmos de hash débiles (SHA-1) o infraestructura de revocación defectuosa (CRLs/OCSP inalcanzables) derivan en interrupciones del servicio o emisión de certificados falsos.

---

## 2. Arquitectura Técnica y Análisis de Compromisos (Trade-Offs)

### 2.1 Criptografía Asimétrica: RSA vs. ECDSA vs. Ed25519

La elección del esquema adecuado de criptografía de clave pública impacta en la utilización de CPU, handshakes por segundo (HPS), sobrecarga de memoria y requisitos de almacenamiento de claves.

| Métrica / Dimensión | RSA (4096 bits) | ECDSA (secp256r1 / P-256) | Ed25519 (EdDSA / Curve25519) |
| :--- | :--- | :--- | :--- |
| **Nivel de Seguridad** | 128 bits de seguridad | 128 bits de seguridad | ~128 bits de seguridad |
| **Tamaño de Clave (Pública/Privada)** | 512 bytes / ~2.4 KB | 64 bytes / 32 bytes | 32 bytes / 32 bytes |
| **Tamaño de Firma** | 512 bytes | 64 bytes | 64 bytes |
| **Rendimiento de Firma** | Lento (~250 ops/seg) | Rápido (~10.000 ops/seg) | Extremadamente Rápido (~25.000 ops/seg) |
| **Velocidad de Verificación** | Extremadamente Rápido (~12.000 ops/seg) | Moderado (~3.000 ops/seg) | Rápido (~8.000 ops/seg) |
| **Protección contra Canales Laterales (Side-Channel)** | Difícil de implementar de forma segura | Vulnerable a RNG débil (curva NIST) | Inmune a ataques de temporización por diseño |
| **Soporte X.509/Web PKI** | Ubicuo (100% compatible con sistemas heredados) | Amplio (Todos los navegadores/servidores modernos) | En crecimiento (RFC 8410; soportado en OpenSSL 1.1.1+) |

---

### 2.2 Funciones de Derivación de Claves (KDFs) para Datos en Reposo: PBKDF2 vs. Argon2id

Al proteger dispositivos de almacenamiento por bloques cifrados utilizando LUKS2 (Linux Unified Key Setup), las funciones de derivación de claves transforman frases de contraseña de usuario en claves maestras de alta entropía, resistiendo al mismo tiempo ataques de fuerza bruta basados en GPU/ASIC.

| Característica | PBKDF2-HMAC-SHA256 | Argon2id (Predeterminado en LUKS2) |
| :--- | :--- | :--- |
| **Dureza de Memoria (Memory Hardness)** | No (0 KB de memoria requeridos) | Alta (Configurable: 32 MB – 2 GB+) |
| **Dureza de CPU (CPU Hardness)** | Basada solo en iteraciones | Costo de tiempo + Costo de memoria + Paralelismo |
| **Resistencia a ASIC/GPU** | Extremadamente Baja (las GPUs calculan miles de millones/seg) | Alta (Limitada por el ancho de banda de memoria) |
| **Resistencia a Canales Laterales (Side-Channel)**| Vulnerable a ataques de temporización de caché | Híbrido (canal lateral de Argon2i + resistencia a GPU de Argon2d) |
| **Estado de Cumplimiento / NIST**| Aprobado por NIST SP 800-132 | RFC 9106 / Ganador del PHC (Estándar Moderno) |

---

### 2.3 Integridad Criptográfica de DNS: Validación DNSSEC vs. DNS Sin Cifrar (Plain DNS)

| Característica | DNS Estándar Sin Cifrar (Plain DNS) | DNSSEC (Domain Name System Security Extensions) |
| :--- | :--- | :--- |
| **Verificación de Autenticidad**| Ninguna (Confía en la dirección IP del emisor) | Verificación de firma criptográfica mediante `RRSIG` |
| **Integridad de Datos** | Ninguna (Susceptible a inyección UDP) | Validada de vuelta hasta el Anchor Raíz mediante `DS` y `DNSKEY` |
| **Prueba de Inexistencia**| `NXDOMAIN` (Sin autenticar) | Autenticada criptográficamente mediante `NSEC` o `NSEC3` |
| **Confidencialidad** | Ninguna (Puerto 53 UDP/TCP en texto plano) | Ninguna (Requiere DoT/DoH para privacidad; DNSSEC solo garantiza integridad) |
| **Sobrecarga (Overhead)** | Tamaño de paquete mínimo (<512 bytes) | Tamaño de paquete incrementado (requiere EDNS0), sobrecarga de CPU para firma/verificación |

---

## 3. Manifiestos de Infraestructura de Producción y Archivos de Configuración Completos

### 3.1 Configuración de CA Multinivel de OpenSSL en Producción (`/etc/pki/ca/openssl.cnf`)

Esta configuración completa rige una infraestructura PKI de 2 niveles (Root CA emitiendo Intermediate CA, Intermediate CA emitiendo Certificados de Servidor/Cliente) utilizando extensiones X.509 v3 modernas.

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

### 3.2 Configuración de PKI Automatizada con CFSSL (`/etc/cfssl/config.json` y `/etc/cfssl/csr_server.json`)

El kit de herramientas PKI de Cloudflare (CFSSL) proporciona generación de certificados impulsada por API REST para microservicios dinámicos.

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

Plantilla de Especificación CSR (`/etc/cfssl/csr_server.json`):

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

### 3.3 Configuración de VirtualHost de Alta Seguridad para Apache 2.4+ (`/etc/httpd/conf.d/secure-vhost.conf`)

Incluye cumplimiento obligatorio de TLS 1.3/1.2, intercambio de claves ECDHE, grapado OCSP (stapling), verificación de cliente mTLS y encabezados de respuesta HSTS.

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

### 3.4 Configuración Autoritativa de DNSSEC para BIND 9 (`/etc/named.conf` y Archivo de Zona)

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

Archivo de Zona Sin Firmar (`/var/named/dynamic/platform.internal.db`):

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

### 3.5 Manifiesto de Almacenamiento Cifrado de LUKS2 con Systemd en Producción (`/etc/crypttab` y `/etc/fstab`)

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

## 4. Ejecución Práctica en CLI y Salidas Reales de Terminal

### 4.1 Inicialización Paso a Paso de PKI mediante OpenSSL

#### Paso 1: Inicializar la Estructura de la Root CA y la Jerarquía de Directorios
```bash
$ sudo mkdir -p /etc/pki/ca/{certs,crl,newcerts,private}
$ sudo chmod 700 /etc/pki/ca/private
$ sudo touch /etc/pki/ca/index.txt
$ echo 1000 | sudo tee /etc/pki/ca/serial
$ echo 1000 | sudo tee /etc/pki/ca/crlnumber
```
*Salida:*
```text
1000
1000
```

#### Paso 2: Generar la Clave ECDSA de la Root CA Offline y el Certificado Raíz Autosignado
```bash
$ sudo openssl ecparam -name prime256v1 -genkey -noout -out /etc/pki/ca/private/root-ca.key
$ sudo chmod 400 /etc/pki/ca/private/root-ca.key
$ sudo openssl req -config /etc/pki/ca/openssl.cnf \
    -key /etc/pki/ca/private/root-ca.key \
    -new -x509 -days 7300 -sha384 -extensions v3_ca \
    -subj "/C=US/ST=Virginia/L=Reston/O=Enterprise Cloud Platform Inc/CN=Root Platform CA" \
    -out /etc/pki/ca/certs/root-ca.crt
```
*Verificación de la salida:*
```bash
$ openssl x509 -in /etc/pki/ca/certs/root-ca.crt -text -noout | grep -A 5 "X509v3 extensions"
```
*Salida Esperada:*
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

#### Paso 3: Emitir la Intermediate CA Firmada por la Root CA
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
*Salida Esperada:*
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

#### Paso 4: Emitir el Certificado de Servidor con Nombres Alternativos del Sujeto (SANs)
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
*Salida Esperada:*
```text
Using configuration from /etc/pki/ca/openssl.cnf
Signature ok
Certificate is to be certified until Aug  6 17:24:10 2028 GMT (730 days)
Write out database with 1 new entries
Data Base Updated
```

---

### 4.2 Ciclo de Vida Automatizado de Certificados mediante Let's Encrypt / Certbot

#### Emitir Certificado Aprobado mediante el Protocolo ACME Standalone
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
*Salida Esperada:*
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

### 4.3 Configuración de Dispositivo de Almacenamiento Cifrado LUKS2 con Argon2id y Systemd-Cryptenroll (TPM2)

#### Paso 1: Formatear la Partición de Almacenamiento con LUKS2 y KDF Argon2id
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
*Salida Esperada:*
```text
WARNING!
========
This will overwrite data on /dev/sdb1 irrevocably.

Are you sure? (Type 'yes' in capital letters): YES
Enter passphrase for /dev/sdb1: 
Verify passphrase: 
Command successful.
```

#### Paso 2: Vincular la Ranura de Clave 1 de LUKS2 al TPM2 (PCR 0+7) para Descrifrado Automático
```bash
$ sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=0+7 /dev/sdb1
```
*Salida Esperada:*
```text
🔐 Secret registered in TPM2 PCRs 0+7.
New key slot 1 assigned on /dev/sdb1.
```

#### Paso 3: Abrir el Mapeo del Dispositivo e Inspeccionar el Encabezado de Metadatos de LUKS
```bash
$ sudo cryptsetup open /dev/sdb1 secure_storage_db
$ sudo cryptsetup luksDump /dev/sdb1
```
*Salida Esperada:*
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

### 4.4 Generación de Claves DNSSEC, Firma de Zona y Validación de Consultas

#### Paso 1: Consultar Registros DNSSEC Usando `dig` y `delv`
```bash
$ dig +dnssec +multi SOA platform.internal @10.96.0.1
```
*Salida Esperada:*
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

#### Paso 2: Validar la Cadena de Confianza Usando `delv`
```bash
$ delv @10.96.0.1 -a /var/named/trusted-key.key platform.internal SOA +rtrace
```
*Salida Esperada:*
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

## 5. Solución de Problemas en Producción, Diagnóstico de Fallas y Matriz de Verificación

### 5.1 Matriz de Solución de Problemas de X.509 PKI y TLS

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

| Síntoma / Mensaje de Error | Causa Raíz | Comando de Diagnóstico | Acción de Remediación |
| :--- | :--- | :--- | :--- |
| `SSL3_GET_SERVER_CERTIFICATE: certificate verify failed (unable to get local issuer certificate)` | Falta la CA intermedia en la carga útil del servidor. | `openssl s_client -connect api.platform.internal:443 -showcerts` | Añadir `intermediate.crt` a `SSLCertificateChainFile` o empaquetarlo en `SSLCertificateFile`. |
| `TLS error: Hostname mismatch / Certificate Subject Alternative Name missing` | El certificado carece del campo SAN para el FQDN solicitado. | `openssl x509 -in cert.crt -text -noout \| grep -A1 "Subject Alternative Name"` | Reemitir el certificado con `-addext "subjectAltName=DNS:..."` explícito. |
| `OCSP response error: certificate status unknown` | La URL del respondedor OCSP especificada en la extensión AIA está inalcanzable o desactualizada. | `openssl ocsp -issuer intermediate.crt -cert server.crt -url http://ocsp.platform.internal` | Actualizar el demonio del respondedor CRL/OCSP o desactivar `SSLUseStapling` temporalmente. |
| `cryptsetup: Device /dev/sdb1 is busy` | El objetivo dm-crypt activo mantiene bloqueos sobre los archivos de dispositivo no desmontados. | `sudo lsof /dev/mapper/secure_storage_db` o `sudo dmsetup info -c` | Desmontar el sistema de archivos, detener servicios dependientes, ejecutar `cryptsetup close <nombre>`. |
| `DNSSEC validation failure: SERVFAIL (RRSIG expired)` | Desviación del reloj del sistema en el resolver validador o la tarea de refirma de zona está detenida. | `delv +rtrace platform.internal SOA` | Resincronizar el reloj del nodo vía NTP (`chronyc tracking`) y forzar la refirma en BIND (`rndc sign platform.internal`). |

---

### 5.2 Flujos de Trabajo de Diagnóstico en Profundidad

#### 1. Verificación de la Validación Completa de la Cadena de Confianza
```bash
$ openssl verify -show_chain -CAfile /etc/pki/ca/certs/root-ca.crt \
    -untrusted /etc/pki/ca/certs/intermediate.crt \
    api.platform.internal.crt
```
*Salida Exitosa Esperada:*
```text
api.platform.internal.crt: OK
Chain:
depth=0: CN = api.platform.internal (untrusted)
depth=1: C = US, ST = Virginia, O = Enterprise Cloud Platform Inc, OU = Security Engineering, CN = Intermediate Issuing CA (untrusted)
depth=2: C = US, ST = Virginia, L = Reston, O = Enterprise Cloud Platform Inc, CN = Root Platform CA
```

#### 2. Inspección en Vivo del Handshake TLS 1.3 y Verificación OCSP
```bash
$ openssl s_client -connect api.platform.internal:443 \
    -servername api.platform.internal \
    -CAfile /etc/pki/ca/certs/root-ca.crt \
    -status -tls1_3
```
*Secciones Clave a Inspeccionar en la Salida de Terminal:*
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

#### 3. Diagnóstico de Problemas en Ranuras de Clave LUKS2 y Verificación del Encabezado
```bash
$ sudo cryptsetup luksDump /dev/sdb1 --debug
```
Si el rescate de la ranura de clave falla o ocurre una corrupción, restaure el encabezado desde una copia de seguridad offline:
```bash
$ sudo cryptsetup luksHeaderBackup /dev/sdb1 --header-backup-file /safe/location/sdb1_header.bak
$ sudo cryptsetup luksHeaderRestore /dev/sdb1 --header-backup-file /safe/location/sdb1_header.bak
```

---

## 6. Referencias y Fuentes Oficiales

1. **Objetivos Oficiales del Linux Professional Institute (LPI):**
   - [LPIC-3 Security Overview](https://www.lpi.org/our-certifications/lpic-3-303-overview/)
   - [LPI Wiki: LPIC-303 Objectives V3.0 (Topic 331 Cryptography)](https://wiki.lpi.org/wiki/LPIC-303_Objectives_V3.0)

2. **Documentación Estándar de X.509 PKI y OpenSSL:**
   - [Documentación oficial y sintaxis de configuración de OpenSSL](https://www.openssl.org/docs/)
   - [RFC 5280: Internet X.509 Public Key Infrastructure Certificate and Certificate Revocation List (CRL) Profile](https://datatracker.ietf.org/doc/html/rfc5280)
   - [Manual y especificaciones de API de Cloudflare PKI (CFSSL)](https://github.com/cloudflare/cfssl)

3. **Seguridad de Servicios e Infraestructura TLS:**
   - [Guía de cifrado fuerte SSL/TLS de Apache HTTP Server versión 2.4](https://httpd.apache.org/docs/2.4/ssl/ssl_howto.html)
   - [Generador de configuración TLS y directrices de TLS del lado del servidor de Mozilla](https://wiki.mozilla.org/Security/Server_Side_TLS)

4. **Cifrado de Datos en Reposo (LUKS / dm-crypt):**
   - [Documentación oficial de LUKS2 Cryptsetup en GitLab](https://gitlab.com/cryptsetup/cryptsetup/-/wikis/home)
   - [Especificación de systemd-cryptenroll e integración con TPM2](https://www.freedesktop.org/software/systemd/man/systemd-cryptenroll.html)

5. **Integridad de DNSSEC:**
   - [Manual de referencia del administrador de BIND 9 (ARM) - Seguridad DNSSEC](https://bind9.readthedocs.io/en/v9_18/dnssec-guide.html)
   - [RFC 4033: DNS Security Introduction and Requirements](https://datatracker.ietf.org/doc/html/rfc4033)