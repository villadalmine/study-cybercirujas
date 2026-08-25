# Ejercicios guiados — Tema 331.1: Certificados X.509 e infraestructuras de clave pública

**Certificación:** LPIC-3 303 Security (examen 303-300, versión 3.0.0) · **Peso del objetivo:** 8.34

---

## 0. Entorno de laboratorio y reglas de base

Todo lo que sigue se ejecuta en un único host Linux. Nada toca una CA pública hasta el Ejercicio 9, y ese ejercicio usa un endpoint de staging.

**Paquetes requeridos**

| Distribución | Comando |
|---|---|
| Debian/Ubuntu | `apt install openssl ca-certificates nginx certbot` |
| RHEL/Rocky/Alma | `dnf install openssl ca-certificates nginx certbot` |
| openSUSE | `zypper install openssl ca-certificates nginx certbot` |

**Versión mínima:** OpenSSL 3.0 o posterior. Varios flags usados acá (`-addext`, `-CRLfile`, `-provider`, `-noenc`) se comportan de manera distinta en 1.1.1 o 1.0.2; los ejercicios señalan las diferencias donde importan.

```bash
openssl version -a
```

```
OpenSSL 3.0.13 30 Jan 2024 (Library: OpenSSL 3.0.13 30 Jan 2024)
built on: Wed Jan 31 12:00:00 2024 UTC
platform: debian-amd64
OPENSSLDIR: "/usr/lib/ssl"
ENGINESDIR: "/usr/lib/x86_64-linux-gnu/engines-3"
MODULESDIR: "/usr/lib/x86_64-linux-gnu/ossl-modules"
```

`OPENSSLDIR` es donde OpenSSL busca `openssl.cnf` y el directorio de confianza `certs/` por defecto cuando no pasás `-CAfile`/`-CApath`. En Debian es `/usr/lib/ssl` (enlazado simbólicamente dentro de `/etc/ssl`); en RHEL es `/etc/pki/tls`. Memorizalo: la mitad de los incidentes del tipo "funciona con `curl` pero no con mi programa" son una suposición equivocada sobre `OPENSSLDIR`.

> **Regla de seguridad para todo el laboratorio:** cada clave privada que generás acá es una clave de laboratorio. Nunca reutilices una clave de laboratorio en un host de producción, y nunca subas `private/` al control de versiones.

---

## Ejercicio 1 — Material de claves: generación, inspección y conversión de formatos

X.509 es un contenedor para una **clave pública** más un **conjunto firmado de afirmaciones** sobre quién la posee. Antes de tocar certificados, tenés que manejar con fluidez la capa de claves que está debajo.

### Pasos

1. Creá el árbol del laboratorio y restringí el directorio privado.

   ```bash
   sudo install -d -m 0755 /opt/pki
   sudo chown "$USER" /opt/pki
   mkdir -p /opt/pki/scratch/private
   chmod 0700 /opt/pki/scratch/private
   cd /opt/pki/scratch
   ```

2. Generá una clave privada RSA-3072 sin cifrar usando el front-end genérico moderno.

   ```bash
   openssl genpkey -algorithm RSA \
     -pkeyopt rsa_keygen_bits:3072 \
     -pkeyopt rsa_keygen_pubexp:65537 \
     -out private/rsa3072.key.pem
   chmod 0600 private/rsa3072.key.pem
   ```

3. Inspeccioná el encabezado. Fijate qué tipo de etiqueta PEM escribe OpenSSL 3.

   ```bash
   head -1 private/rsa3072.key.pem
   ```

   ```
   -----BEGIN PRIVATE KEY-----
   ```

4. Generá una clave EC cifrada sobre la curva NIST P-256, y una segunda sobre P-384.

   ```bash
   openssl genpkey -algorithm EC \
     -pkeyopt ec_paramgen_curve:P-256 \
     -pkeyopt ec_param_enc:named_curve \
     -aes-256-cbc \
     -out private/ec256.key.pem
   # Enter PEM pass phrase: LabPass331
   ```

   ```bash
   head -1 private/ec256.key.pem
   ```

   ```
   -----BEGIN ENCRYPTED PRIVATE KEY-----
   ```

5. Volcá la estructura de ambas claves. Para la cifrada tenés que suministrar la passphrase.

   ```bash
   openssl pkey -in private/rsa3072.key.pem -noout -text | head -6
   openssl pkey -in private/ec256.key.pem -passin pass:LabPass331 -noout -text
   ```

   ```
   Private-Key: (3072 bit, 2 primes)
   modulus:
       00:c1:9e:3f:...
   
   Private-Key: (256 bit)
   priv:
       3a:11:6b:...
   pub:
       04:8f:2c:...
   ASN1 OID: prime256v1
   NIST CURVE: P-256
   ```

6. Extraé las claves públicas. Esta es la única parte de un par de claves que alguna vez sale del host.

   ```bash
   openssl pkey -in private/rsa3072.key.pem -pubout -out rsa3072.pub.pem
   openssl pkey -in private/ec256.key.pem -passin pass:LabPass331 -pubout -out ec256.pub.pem
   cat ec256.pub.pem
   ```

   ```
   -----BEGIN PUBLIC KEY-----
   MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEjywsHhq0R1xM0kZBv2R9F6dHqDdX
   9M0jK8mQ2R5o1cVQ0f6R5R8b5Yp4kQ3Z0wZ8m1qN9lU2E3v6H2Q7pA==
   -----END PUBLIC KEY-----
   ```

7. Convertí PEM a DER y de vuelta, y después probá que el viaje de ida y vuelta es idéntico byte a byte.

   ```bash
   openssl pkey -in rsa3072.pub.pem -pubin -outform DER -out rsa3072.pub.der
   openssl pkey -in rsa3072.pub.der -pubin -inform DER -out rsa3072.pub.roundtrip.pem
   cmp rsa3072.pub.pem rsa3072.pub.roundtrip.pem && echo "identical"
   file rsa3072.pub.der rsa3072.pub.pem
   ```

   ```
   identical
   rsa3072.pub.der: data
   rsa3072.pub.pem: ASCII text
   ```

8. Mirá el ASN.1 crudo de la codificación DER. Esta es la verdad de fondo que PEM apenas envuelve en base64.

   ```bash
   openssl asn1parse -inform DER -in rsa3072.pub.der -i
   ```

   ```
       0:d=0  hl=4 l= 418 cons: SEQUENCE
       4:d=1  hl=2 l=  13 cons:  SEQUENCE
       6:d=2  hl=2 l=   9 prim:   OBJECT            :rsaEncryption
      17:d=2  hl=2 l=   0 prim:   NULL
      19:d=1  hl=4 l= 399 prim:  BIT STRING
   ```

9. Cambiá la passphrase de la clave EC, y después quitala por completo (lo que **nunca** debés hacerle a una clave de producción en una máquina compartida).

   ```bash
   openssl pkey -in private/ec256.key.pem -passin pass:LabPass331 \
     -aes-256-cbc -passout pass:NewLabPass331 -out private/ec256.newpass.key.pem
   openssl pkey -in private/ec256.key.pem -passin pass:LabPass331 \
     -out private/ec256.plain.key.pem
   chmod 0600 private/ec256.*.pem
   ```

10. Compará la salida tradicional (PKCS#1 / SEC1) con PKCS#8. Las herramientas legacy exigen la primera con frecuencia.

    ```bash
    openssl rsa -in private/rsa3072.key.pem -traditional -out private/rsa3072.pkcs1.key.pem
    head -1 private/rsa3072.pkcs1.key.pem
    openssl ec -in private/ec256.plain.key.pem -out private/ec256.sec1.key.pem
    head -1 private/ec256.sec1.key.pem
    ```

    ```
    -----BEGIN RSA PRIVATE KEY-----
    -----BEGIN EC PRIVATE KEY-----
    ```

### Verificá tu comprensión — Bloque 1

- **Q1.1** `-----BEGIN PRIVATE KEY-----`, `-----BEGIN RSA PRIVATE KEY-----` y `-----BEGIN ENCRYPTED PRIVATE KEY-----` son tres etiquetas PEM diferentes. ¿Qué estructura ASN.1 hay detrás de cada una, y cuál puede contener una clave EC, RSA o Ed25519 sin cambiar la etiqueta?
- **Q1.2** Un colega afirma que PEM y DER son "dos formatos de certificado diferentes". Corregí la afirmación con precisión.
- **Q1.3** ¿Por qué `openssl pkey -pubout` sobre una clave privada tiene éxito al instante, mientras que derivar una clave privada a partir de una pública es imposible?
- **Q1.4** Configuraste `ec_param_enc:named_curve`. ¿Cuál es la alternativa, y por qué la alternativa rompe la interoperabilidad con la mayoría de los stacks TLS?
- **Q1.5** Una clave RSA-3072 y una clave EC P-256 suelen describirse como de seguridad "comparable". ¿Cuál es comparable a P-256, y cuál es la diferencia de costo operativo en el momento del handshake TLS?

---

## Ejercicio 2 — Leer un certificado real hasta el ASN.1

### Pasos

1. Descargá una cadena de certificados en vivo desde un sitio público y guardala.

   ```bash
   cd /opt/pki/scratch
   openssl s_client -connect www.lpi.org:443 -servername www.lpi.org -showcerts \
     </dev/null 2>/dev/null | \
     awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/' > lpi-chain.pem
   grep -c 'BEGIN CERTIFICATE' lpi-chain.pem
   ```

   ```
   2
   ```

2. Dividí la cadena en archivos individuales.

   ```bash
   csplit -z -f lpi-cert- -b '%02d.pem' lpi-chain.pem '/BEGIN CERTIFICATE/' '{*}'
   ls lpi-cert-*
   ```

   ```
   lpi-cert-00.pem  lpi-cert-01.pem
   ```

3. Imprimí la forma legible por humanos de la hoja, suprimiendo los volcados hexadecimales ruidosos.

   ```bash
   openssl x509 -in lpi-cert-00.pem -noout -text \
     -certopt no_sigdump,no_pubkey,no_header
   ```

   ```
           Version: 3 (0x2)
           Serial Number:
               04:9a:31:2b:...:c7
           Signature Algorithm: ecdsa-with-SHA384
           Issuer: C = US, O = Let's Encrypt, CN = E6
           Validity
               Not Before: Jul 14 09:21:44 2026 GMT
               Not After : Oct 12 09:21:43 2026 GMT
           Subject: CN = www.lpi.org
           X509v3 extensions:
               X509v3 Key Usage: critical
                   Digital Signature
               X509v3 Extended Key Usage:
                   TLS Web Server Authentication, TLS Web Client Authentication
               X509v3 Basic Constraints: critical
                   CA:FALSE
               X509v3 Subject Key Identifier:
                   9C:1E:...:B2
               X509v3 Authority Key Identifier:
                   93:27:46:...:9E
               Authority Information Access:
                   OCSP - URI:http://e6.o.lencr.org
                   CA Issuers - URI:http://e6.i.lencr.org/
               X509v3 Subject Alternative Name:
                   DNS:lpi.org, DNS:www.lpi.org
               X509v3 Certificate Policies:
                   Policy: 2.23.140.1.2.1
   ```

4. Extraé campos individuales — esto es lo que se automatiza en los chequeos de monitoreo.

   ```bash
   openssl x509 -in lpi-cert-00.pem -noout \
     -subject -issuer -serial -dates -fingerprint -sha256
   ```

   ```
   subject=CN = www.lpi.org
   issuer=C = US, O = Let's Encrypt, CN = E6
   serial=049A312B...C7
   notBefore=Jul 14 09:21:44 2026 GMT
   notAfter=Oct 12 09:21:43 2026 GMT
   sha256 Fingerprint=3A:7C:...:1F
   ```

5. Planteá la pregunta del vencimiento tal como lo hace un chequeo de Nagios/Prometheus.

   ```bash
   openssl x509 -in lpi-cert-00.pem -noout -checkend $((30*24*3600)) \
     && echo "OK: valid for at least 30 more days" \
     || echo "WARN: expires within 30 days"
   ```

6. Leé el certificado como ASN.1 puro y ubicá el TBSCertificate — la región que realmente se hashea y se firma.

   ```bash
   openssl asn1parse -in lpi-cert-00.pem -i | head -20
   ```

   ```
       0:d=0  hl=4 l= 966 cons: SEQUENCE
       4:d=1  hl=4 l= 686 cons:  SEQUENCE
       8:d=2  hl=2 l=   3 cons:   cont [ 0 ]
      10:d=3  hl=2 l=   1 prim:    INTEGER           :02
      13:d=2  hl=2 l=  18 prim:   INTEGER           :049A312B...C7
      33:d=2  hl=2 l=  10 cons:   SEQUENCE
      35:d=3  hl=2 l=   8 prim:    OBJECT            :ecdsa-with-SHA384
      45:d=2  hl=2 l=  53 cons:   SEQUENCE
   ...
     694:d=1  hl=2 l=  10 cons:  SEQUENCE
     696:d=2  hl=2 l=   8 prim:   OBJECT            :ecdsa-with-SHA384
     706:d=1  hl=4 l= 105 prim:  BIT STRING
   ```

7. Calculá el pin SPKI (SHA-256 del `SubjectPublicKeyInfo` codificado en DER), el valor usado por el pinning estilo HPKP y el de aplicaciones móviles.

   ```bash
   openssl x509 -in lpi-cert-00.pem -noout -pubkey \
     | openssl pkey -pubin -outform DER \
     | openssl dgst -sha256 -binary \
     | openssl enc -base64
   ```

   ```
   Ku1c+3vTz0S9Xg7yQ2fFq0mR8bWnJ4pO1lYc6hT2sVo=
   ```

8. Verificá que una clave privada y un certificado realmente van juntos — el chequeo de cinco segundos más útil en la resolución de problemas de TLS.

   ```bash
   # Algorithm-agnostic (works for RSA, EC, Ed25519):
   openssl x509 -in lpi-cert-00.pem -noout -pubkey | openssl sha256
   # Compare against, on your own server:
   #   openssl pkey -in /etc/ssl/private/server.key -pubout | openssl sha256
   ```

### Verificá tu comprensión — Bloque 2

- **Q2.1** En el volcado ASN.1, el `SEQUENCE` exterior en el offset 0 tiene tres hijos. Nombralos, e indicá sobre qué bytes se calcula la firma de la CA.
- **Q2.2** El certificado lleva tanto `Subject: CN = www.lpi.org` como un `subjectAltName` con `DNS:www.lpi.org`. ¿Cuál de los dos usa un cliente TLS moderno para la coincidencia de hostname, y qué dice la RFC 6125 / el CA/Browser Forum sobre el otro?
- **Q2.3** `X509v3 Basic Constraints: critical / CA:FALSE`. ¿Qué es una extensión "critical", y qué debe hacer un cliente conforme si encuentra una extensión crítica que no reconoce?
- **Q2.4** La extensión Authority Information Access lista tanto URIs de `OCSP` como de `CA Issuers`. ¿Para qué sirve cada una, y cuál puede rescatar a un servidor mal configurado que envía una cadena incompleta?
- **Q2.5** ¿Por qué el pin SPKI del paso 7 es más duradero que un pin del fingerprint del certificado?

---

## Ejercicio 3 — Construir una Root CA con `openssl ca`

Ahora te convertís en la CA. El punto de este ejercicio es el *estado* que mantiene una CA, no solamente los comandos.

### Pasos

1. Creá la estructura de directorios de la root CA y sus archivos de estado.

   ```bash
   sudo install -d -m 0755 /opt/pki/root-ca
   sudo chown -R "$USER" /opt/pki/root-ca
   cd /opt/pki/root-ca
   mkdir -p certs crl newcerts private csr
   chmod 0700 private
   touch index.txt
   echo 1000 > serial
   echo 1000 > crlnumber
   ```

2. Escribí la configuración de la root CA. Guardala como `/opt/pki/root-ca/openssl-root.cnf`.

   ```ini
   # ---------------------------------------------------------------
   # openssl-root.cnf — Example Internal Root CA
   # ---------------------------------------------------------------
   [ ca ]
   default_ca              = CA_default

   [ CA_default ]
   dir                     = /opt/pki/root-ca
   certs                   = $dir/certs
   crl_dir                 = $dir/crl
   new_certs_dir           = $dir/newcerts
   database                = $dir/index.txt
   serial                  = $dir/serial

   private_key             = $dir/private/root-ca.key.pem
   certificate             = $dir/certs/root-ca.cert.pem

   crlnumber               = $dir/crlnumber
   crl                     = $dir/crl/root-ca.crl.pem
   crl_extensions          = crl_ext
   default_crl_days        = 180

   default_md              = sha256
   name_opt                = ca_default
   cert_opt                = ca_default
   default_days            = 3650
   preserve                = no
   policy                  = policy_strict
   unique_subject          = no
   copy_extensions         = none

   # The root signs ONLY intermediates, so the policy is strict:
   # the subordinate DN must match the root's organisation exactly.
   [ policy_strict ]
   countryName             = match
   stateOrProvinceName     = match
   organizationName        = match
   organizationalUnitName  = optional
   commonName              = supplied
   emailAddress            = optional

   [ req ]
   default_bits            = 4096
   default_md              = sha256
   string_mask             = utf8only
   prompt                  = no
   distinguished_name      = req_distinguished_name
   x509_extensions         = v3_root_ca

   [ req_distinguished_name ]
   countryName             = AR
   stateOrProvinceName     = Buenos Aires
   localityName            = CABA
   organizationName        = Example Internal Ltd
   organizationalUnitName  = Platform Engineering
   commonName              = Example Internal Root CA X1

   [ v3_root_ca ]
   subjectKeyIdentifier    = hash
   authorityKeyIdentifier  = keyid:always,issuer
   basicConstraints        = critical, CA:true
   keyUsage                = critical, digitalSignature, cRLSign, keyCertSign

   [ v3_intermediate_ca ]
   subjectKeyIdentifier    = hash
   authorityKeyIdentifier  = keyid:always,issuer
   basicConstraints        = critical, CA:true, pathlen:0
   keyUsage                = critical, digitalSignature, cRLSign, keyCertSign
   crlDistributionPoints   = URI:http://pki.example.internal/root-ca.crl
   authorityInfoAccess     = caIssuers;URI:http://pki.example.internal/root-ca.cer
   nameConstraints         = critical, permitted;DNS:.example.internal, permitted;email:.example.internal, excluded;IP:0.0.0.0/0.0.0.0, excluded;IP:::/::

   [ crl_ext ]
   authorityKeyIdentifier  = keyid:always
   ```

3. Generá la clave privada de la root. Está cifrada; en producción esta clave vive offline o en un HSM.

   ```bash
   openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 \
     -aes-256-cbc -pass pass:RootLabPass331 \
     -out private/root-ca.key.pem
   chmod 0400 private/root-ca.key.pem
   ```

4. Autofirmá el certificado raíz. Notá que `req -x509` produce un certificado sin tocar `index.txt` — el certificado propio de la root no es "emitido" por la base de datos de la CA.

   ```bash
   openssl req -config openssl-root.cnf \
     -key private/root-ca.key.pem -passin pass:RootLabPass331 \
     -new -x509 -days 7300 -sha256 -extensions v3_root_ca \
     -out certs/root-ca.cert.pem
   chmod 0444 certs/root-ca.cert.pem
   ```

5. Verificá el resultado y confirmá que es autofirmado.

   ```bash
   openssl x509 -in certs/root-ca.cert.pem -noout -text \
     -certopt no_sigdump,no_pubkey,no_header | sed -n '1,30p'
   openssl verify -CAfile certs/root-ca.cert.pem certs/root-ca.cert.pem
   ```

   ```
           Version: 3 (0x2)
           Serial Number:
               6b:1c:...:ad
           Signature Algorithm: sha256WithRSAEncryption
           Issuer: C = AR, ST = Buenos Aires, L = CABA, O = Example Internal Ltd, OU = Platform Engineering, CN = Example Internal Root CA X1
           Validity
               Not Before: Aug 18 11:04:12 2026 GMT
               Not After : Aug 13 11:04:12 2046 GMT
           Subject: C = AR, ST = Buenos Aires, L = CABA, O = Example Internal Ltd, OU = Platform Engineering, CN = Example Internal Root CA X1
           X509v3 extensions:
               X509v3 Subject Key Identifier:
                   4E:1D:...:C9
               X509v3 Authority Key Identifier:
                   4E:1D:...:C9
               X509v3 Basic Constraints: critical
                   CA:TRUE
               X509v3 Key Usage: critical
                   Digital Signature, Certificate Sign, CRL Sign

   certs/root-ca.cert.pem: OK
   ```

6. Confirmá que Subject == Issuer y SKI == AKI de forma programática.

   ```bash
   openssl x509 -in certs/root-ca.cert.pem -noout -subject -issuer \
     | awk -F'=' '{ $1=""; print }' | uniq -c
   ```

   ```
         2   C = AR, ST = Buenos Aires, ...
   ```

### Verificá tu comprensión — Bloque 3

- **Q3.1** El certificado raíz es autofirmado. Explicá, únicamente en términos criptográficos, por qué esa firma no prueba nada sobre su confiabilidad — y de dónde viene realmente la confianza.
- **Q3.2** ¿Para qué sirven `index.txt`, `serial` y `crlnumber`? ¿Qué se rompe si restaurás `index.txt` desde un backup de hace un día?
- **Q3.3** Se configuró `unique_subject = no`. ¿Cuál es el valor por defecto, y dá un escenario operativo concreto en el que el valor por defecto provoca una caída de servicio.
- **Q3.4** `policy_strict` establece `organizationName = match`. ¿Coincidir contra *qué*, exactamente?
- **Q3.5** La root tiene `keyUsage = critical, digitalSignature, cRLSign, keyCertSign`. ¿Cuál de esos tres es estrictamente necesario para firmar certificados subordinados, y cuál para firmar CRLs?

---

## Ejercicio 4 — CA intermedia y la cadena de confianza

### Pasos

1. Creá el árbol de la CA intermedia.

   ```bash
   sudo install -d -m 0755 /opt/pki/int-ca
   sudo chown -R "$USER" /opt/pki/int-ca
   cd /opt/pki/int-ca
   mkdir -p certs crl newcerts private csr
   chmod 0700 private
   touch index.txt
   echo 2000 > serial
   echo 2000 > crlnumber
   ```

2. Escribí `/opt/pki/int-ca/openssl-int.cnf`.

   ```ini
   # ---------------------------------------------------------------
   # openssl-int.cnf — Example Internal Issuing CA
   # ---------------------------------------------------------------
   [ ca ]
   default_ca              = CA_default

   [ CA_default ]
   dir                     = /opt/pki/int-ca
   certs                   = $dir/certs
   crl_dir                 = $dir/crl
   new_certs_dir           = $dir/newcerts
   database                = $dir/index.txt
   serial                  = $dir/serial

   private_key             = $dir/private/int-ca.key.pem
   certificate             = $dir/certs/int-ca.cert.pem

   crlnumber               = $dir/crlnumber
   crl                     = $dir/crl/int-ca.crl.pem
   crl_extensions          = crl_ext
   default_crl_days        = 7

   default_md              = sha256
   name_opt                = ca_default
   cert_opt                = ca_default
   default_days            = 90
   preserve                = no
   policy                  = policy_loose
   unique_subject          = no
   copy_extensions         = none      # see Q4.5 — do not change this casually

   [ policy_loose ]
   countryName             = optional
   stateOrProvinceName     = optional
   localityName            = optional
   organizationName        = optional
   organizationalUnitName  = optional
   commonName              = supplied
   emailAddress            = optional

   [ req ]
   default_bits            = 3072
   default_md              = sha256
   string_mask             = utf8only
   prompt                  = no
   distinguished_name      = req_distinguished_name

   [ req_distinguished_name ]
   countryName             = AR
   stateOrProvinceName     = Buenos Aires
   localityName            = CABA
   organizationName        = Example Internal Ltd
   organizationalUnitName  = Platform Engineering
   commonName              = Example Internal Issuing CA I1

   [ server_cert ]
   basicConstraints        = critical, CA:false
   keyUsage                = critical, digitalSignature, keyEncipherment
   extendedKeyUsage        = serverAuth, clientAuth
   subjectKeyIdentifier    = hash
   authorityKeyIdentifier  = keyid,issuer
   crlDistributionPoints   = URI:http://pki.example.internal/int-ca.crl
   authorityInfoAccess     = OCSP;URI:http://ocsp.example.internal:2560,caIssuers;URI:http://pki.example.internal/int-ca.cer

   [ client_cert ]
   basicConstraints        = critical, CA:false
   keyUsage                = critical, digitalSignature
   extendedKeyUsage        = clientAuth, emailProtection
   subjectKeyIdentifier    = hash
   authorityKeyIdentifier  = keyid,issuer
   crlDistributionPoints   = URI:http://pki.example.internal/int-ca.crl

   [ ocsp_signing ]
   basicConstraints        = critical, CA:false
   keyUsage                = critical, digitalSignature
   extendedKeyUsage        = critical, OCSPSigning
   subjectKeyIdentifier    = hash
   authorityKeyIdentifier  = keyid,issuer
   noCheck                 = ignored

   [ crl_ext ]
   authorityKeyIdentifier  = keyid:always
   ```

3. Generá la clave de la intermedia y su CSR.

   ```bash
   openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 \
     -aes-256-cbc -pass pass:IntLabPass331 \
     -out private/int-ca.key.pem
   chmod 0400 private/int-ca.key.pem

   openssl req -config openssl-int.cnf -new -sha256 \
     -key private/int-ca.key.pem -passin pass:IntLabPass331 \
     -out csr/int-ca.csr.pem
   ```

4. Inspeccioná el CSR y — fundamental — verificá su autofirma. Un CSR está firmado por la clave solicitante, lo que prueba la posesión de la clave privada.

   ```bash
   openssl req -in csr/int-ca.csr.pem -noout -text -verify | head -12
   ```

   ```
   Certificate request self-signature verify OK
   Certificate Request:
       Data:
           Version: 1 (0x0)
           Subject: C = AR, ST = Buenos Aires, L = CABA, O = Example Internal Ltd, OU = Platform Engineering, CN = Example Internal Issuing CA I1
           Subject Public Key Info:
               Public Key Algorithm: rsaEncryption
                   Public-Key: (3072 bit)
   ```

5. Firmá la intermedia con la CA **root**, aplicando el bloque de extensiones `v3_intermediate_ca`.

   ```bash
   cd /opt/pki/root-ca
   openssl ca -config openssl-root.cnf \
     -extensions v3_intermediate_ca -days 3650 -notext -md sha256 \
     -passin pass:RootLabPass331 \
     -in /opt/pki/int-ca/csr/int-ca.csr.pem \
     -out /opt/pki/int-ca/certs/int-ca.cert.pem
   ```

   ```
   Using configuration from openssl-root.cnf
   Check that the request matches the signature
   Signature ok
   Certificate Details:
           Serial Number: 4096 (0x1000)
           Validity
               Not Before: Aug 18 11:22:03 2026 GMT
               Not After : Aug 16 11:22:03 2036 GMT
           Subject:
               countryName               = AR
               stateOrProvinceName       = Buenos Aires
               organizationName          = Example Internal Ltd
               organizationalUnitName    = Platform Engineering
               commonName                = Example Internal Issuing CA I1
           X509v3 extensions:
               X509v3 Basic Constraints: critical
                   CA:TRUE, pathlen:0
   ...
   Certificate is to be certified until Aug 16 11:22:03 2036 GMT (3650 days)
   Sign the certificate? [y/n]:y

   1 out of 1 certificate requests certified, commit? [y/n]y
   Write out database with 1 new entries
   Data Base Updated
   ```

6. Mirá lo que registró la base de datos de la CA.

   ```bash
   cat /opt/pki/root-ca/index.txt
   ```

   ```
   V	360816112203Z		1000	unknown	/C=AR/ST=Buenos Aires/O=Example Internal Ltd/OU=Platform Engineering/CN=Example Internal Issuing CA I1
   ```

   Columnas: **status** (`V`álido / `R`evocado / `E`xpirado) · vencimiento (`YYMMDDHHMMSSZ`) · fecha de revocación[,razón] · serial · nombre de archivo · DN del subject.

7. Verificá la intermedia contra la root.

   ```bash
   openssl verify -CAfile /opt/pki/root-ca/certs/root-ca.cert.pem \
     /opt/pki/int-ca/certs/int-ca.cert.pem
   ```

   ```
   /opt/pki/int-ca/certs/int-ca.cert.pem: OK
   ```

8. Construí el archivo de cadena que presentarán los servidores. **El orden importa: primero la hoja, después cada emisor hacia arriba. Normalmente la root se omite.**

   ```bash
   cat /opt/pki/int-ca/certs/int-ca.cert.pem \
       /opt/pki/root-ca/certs/root-ca.cert.pem \
       > /opt/pki/int-ca/certs/ca-chain.cert.pem
   chmod 0444 /opt/pki/int-ca/certs/ca-chain.cert.pem
   ```

### Verificá tu comprensión — Bloque 4

- **Q4.1** La intermedia tiene `pathlen:0`. ¿Qué prohíbe exactamente, y cuenta a la intermedia misma?
- **Q4.2** La intermedia lleva `nameConstraints` restringidas a `.example.internal`. Si le robaran la clave de esta intermedia, ¿qué podría y qué no podría hacer el atacante con ella contra un cliente que aplica name constraints?
- **Q4.3** Tanto `openssl req -x509` en el Ejercicio 3 como `openssl ca` acá produjeron certificados. Enumerá tres comportamientos concretos que tiene `openssl ca` y que `req -x509` no tiene.
- **Q4.4** En el paso 4 se imprimió `Certificate request self-signature verify OK`. ¿Qué propiedad prueba eso, y qué *no* prueba?
- **Q4.5** La configuración establece `copy_extensions = none`. Describí el ataque que se vuelve posible con `copy_extensions = copy` si el operador de la CA no revisa los CSR.

---

## Ejercicio 5 — Emitir un certificado de servidor con SANs, y verificarlo correctamente

### Pasos

1. Generá la clave del servidor (EC P-256 — handshakes más baratos, certificados más chicos).

   ```bash
   cd /opt/pki/int-ca
   openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 \
     -pkeyopt ec_param_enc:named_curve \
     -out private/web01.key.pem
   chmod 0400 private/web01.key.pem
   ```

2. Creá el CSR con SANs embebidas vía `-addext` (OpenSSL ≥ 1.1.1).

   ```bash
   openssl req -new -sha256 -key private/web01.key.pem \
     -subj "/C=AR/ST=Buenos Aires/O=Example Internal Ltd/CN=web01.example.internal" \
     -addext "subjectAltName=DNS:web01.example.internal,DNS:www.example.internal,IP:10.20.30.41" \
     -out csr/web01.csr.pem
   openssl req -in csr/web01.csr.pem -noout -text | grep -A2 'Requested Extensions' 
   ```

   ```
           Requested Extensions:
               X509v3 Subject Alternative Name:
                   DNS:web01.example.internal, DNS:www.example.internal, IP Address:10.20.30.41
   ```

3. Como la configuración de la CA usa `copy_extensions = none`, las SANs del CSR se **descartan**. En su lugar, suministralas desde un archivo de extensiones controlado por la CA — este es el patrón correcto en producción.

   ```bash
   cat > /opt/pki/int-ca/ext/web01.ext <<'EOF'
   basicConstraints        = critical, CA:false
   keyUsage                = critical, digitalSignature
   extendedKeyUsage        = serverAuth, clientAuth
   subjectKeyIdentifier    = hash
   authorityKeyIdentifier  = keyid,issuer
   crlDistributionPoints   = URI:http://pki.example.internal/int-ca.crl
   authorityInfoAccess     = OCSP;URI:http://ocsp.example.internal:2560,caIssuers;URI:http://pki.example.internal/int-ca.cer
   subjectAltName          = @alt_names

   [ alt_names ]
   DNS.1 = web01.example.internal
   DNS.2 = www.example.internal
   IP.1  = 10.20.30.41
   EOF
   ```

   > Se descartó `keyEncipherment`: una clave ECDSA nunca cifra un pre-master secret de TLS. Incluirlo es un error de copiar y pegar habitual que algunos validadores estrictos marcan.

4. Firmalo.

   ```bash
   mkdir -p ext
   openssl ca -config openssl-int.cnf \
     -extfile ext/web01.ext -days 90 -notext -md sha256 \
     -passin pass:IntLabPass331 \
     -in csr/web01.csr.pem -out certs/web01.cert.pem
   chmod 0444 certs/web01.cert.pem
   ```

5. Verificá contra la cadena, mostrando la ruta que se construyó.

   ```bash
   openssl verify -CAfile /opt/pki/root-ca/certs/root-ca.cert.pem \
     -untrusted certs/int-ca.cert.pem \
     -show_chain certs/web01.cert.pem
   ```

   ```
   certs/web01.cert.pem: OK
   Chain:
   depth=0: C = AR, ST = Buenos Aires, O = Example Internal Ltd, CN = web01.example.internal (untrusted)
   depth=1: C = AR, ST = Buenos Aires, L = CABA, O = Example Internal Ltd, OU = Platform Engineering, CN = Example Internal Issuing CA I1 (untrusted)
   depth=2: C = AR, ST = Buenos Aires, L = CABA, O = Example Internal Ltd, OU = Platform Engineering, CN = Example Internal Root CA X1
   ```

6. Ahora verificá el **propósito** y el **hostname** — `openssl verify` no hace ninguno de los dos por defecto.

   ```bash
   openssl verify -CAfile /opt/pki/root-ca/certs/root-ca.cert.pem \
     -untrusted certs/int-ca.cert.pem \
     -purpose sslserver -x509_strict \
     -verify_hostname web01.example.internal \
     certs/web01.cert.pem

   # Now try a name that is NOT in the SAN list:
   openssl verify -CAfile /opt/pki/root-ca/certs/root-ca.cert.pem \
     -untrusted certs/int-ca.cert.pem \
     -verify_hostname api.example.internal \
     certs/web01.cert.pem
   ```

   ```
   certs/web01.cert.pem: OK

   C = AR, ST = Buenos Aires, O = Example Internal Ltd, CN = web01.example.internal
   error 62 at 0 depth lookup: Hostname mismatch
   error certs/web01.cert.pem: verification failed
   ```

7. Rompé deliberadamente la cadena para ver los códigos de error clásicos.

   ```bash
   # Missing intermediate:
   openssl verify -CAfile /opt/pki/root-ca/certs/root-ca.cert.pem certs/web01.cert.pem

   # No trust anchor at all:
   openssl verify -CAfile certs/int-ca.cert.pem certs/web01.cert.pem
   ```

   ```
   C = AR, ..., CN = web01.example.internal
   error 20 at 0 depth lookup: unable to get local issuer certificate
   error certs/web01.cert.pem: verification failed

   C = AR, ..., CN = web01.example.internal
   error 2 at 1 depth lookup: unable to get issuer certificate
   error certs/web01.cert.pem: verification failed
   ```

8. Servilo y probalo de punta a punta con `s_server` / `s_client`.

   ```bash
   # Terminal A:
   openssl s_server -accept 4433 \
     -cert certs/web01.cert.pem -key private/web01.key.pem \
     -cert_chain certs/int-ca.cert.pem -www

   # Terminal B:
   openssl s_client -connect 127.0.0.1:4433 \
     -servername web01.example.internal \
     -CAfile /opt/pki/root-ca/certs/root-ca.cert.pem \
     -verify_hostname web01.example.internal \
     -verify_return_error -brief </dev/null
   ```

   ```
   CONNECTION ESTABLISHED
   Protocol version: TLSv1.3
   Ciphersuite: TLS_AES_256_GCM_SHA384
   Peer certificate: C = AR, ST = Buenos Aires, O = Example Internal Ltd, CN = web01.example.internal
   Hash used: SHA256
   Signature type: ECDSA
   Verification: OK
   Server Temp Key: X25519, 253 bits
   ```

### Verificá tu comprensión — Bloque 5

- **Q5.1** `openssl verify certs/web01.cert.pem` devolvió `OK` en el paso 5, pero el mismo certificado es rechazado por un navegador. Nombrá dos chequeos que `openssl verify` omitió por defecto y que el navegador sí realiza.
- **Q5.2** ¿Cuál es la diferencia entre el error 20 y el error 2 en el paso 7, y cuál corresponde a "el servidor se olvidó de enviar la intermedia"?
- **Q5.3** La SAN incluye `IP:10.20.30.41`. ¿Por qué las CA públicas casi nunca emiten esto, y qué cambia cuando el certificado es para una PKI interna?
- **Q5.4** ¿Qué agrega `-x509_strict`, y dá un ejemplo de un certificado que pasa la verificación normal pero falla con esa opción.
- **Q5.5** En el paso 8 se pasó `-servername`. ¿Qué extensión TLS completa eso, y qué pasa en un servidor multi-tenant si el cliente la omite?

---

## Ejercicio 6 — Revocación parte 1: CRLs

### Pasos

1. Emití un segundo certificado de servidor que después vas a revocar.

   ```bash
   cd /opt/pki/int-ca
   openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 \
     -out private/web02.key.pem
   openssl req -new -sha256 -key private/web02.key.pem \
     -subj "/C=AR/O=Example Internal Ltd/CN=web02.example.internal" \
     -out csr/web02.csr.pem
   sed 's/web01/web02/g; /^DNS.2/d; /^IP.1/d' ext/web01.ext > ext/web02.ext
   openssl ca -config openssl-int.cnf -extfile ext/web02.ext -days 90 \
     -notext -md sha256 -batch -passin pass:IntLabPass331 \
     -in csr/web02.csr.pem -out certs/web02.cert.pem
   ```

2. Generá una CRL **antes** de revocar nada, para tener una línea de base.

   ```bash
   openssl ca -config openssl-int.cnf -gencrl \
     -passin pass:IntLabPass331 -out crl/int-ca.crl.pem
   openssl crl -in crl/int-ca.crl.pem -noout -text
   ```

   ```
   Certificate Revocation List (CRL):
           Version 2 (0x1)
           Signature Algorithm: sha256WithRSAEncryption
           Issuer: C = AR, ST = Buenos Aires, L = CABA, O = Example Internal Ltd, OU = Platform Engineering, CN = Example Internal Issuing CA I1
           Last Update: Aug 18 12:01:44 2026 GMT
           Next Update: Aug 25 12:01:44 2026 GMT
           CRL extensions:
               X509v3 Authority Key Identifier:
                   7B:2A:...:41
               X509v3 CRL Number:
                   8192
   No Revoked Certificates.
   ```

3. Revocá `web02` con un código de razón explícito.

   ```bash
   openssl ca -config openssl-int.cnf \
     -passin pass:IntLabPass331 \
     -revoke certs/web02.cert.pem -crl_reason keyCompromise
   ```

   ```
   Using configuration from openssl-int.cnf
   Revoking Certificate 2001.
   Data Base Updated
   ```

4. Mirá `index.txt` de nuevo — el flag de estado cambió.

   ```bash
   cat index.txt
   ```

   ```
   V	261116112203Z		2000	unknown	/C=AR/ST=Buenos Aires/O=Example Internal Ltd/CN=web01.example.internal
   R	261116114512Z	260818120730Z,keyCompromise	2001	unknown	/C=AR/O=Example Internal Ltd/CN=web02.example.internal
   ```

5. Regenerá la CRL e inspeccionala.

   ```bash
   openssl ca -config openssl-int.cnf -gencrl \
     -passin pass:IntLabPass331 -out crl/int-ca.crl.pem
   openssl crl -in crl/int-ca.crl.pem -noout -text | tail -12
   ```

   ```
   Revoked Certificates:
       Serial Number: 2001
           Revocation Date: Aug 18 12:07:30 2026 GMT
           CRL entry extensions:
               X509v3 CRL Reason Code:
                   Key Compromise
   ```

6. Verificá con el chequeo de CRL habilitado.

   ```bash
   openssl verify -CAfile /opt/pki/root-ca/certs/root-ca.cert.pem \
     -untrusted certs/int-ca.cert.pem \
     -crl_check -CRLfile crl/int-ca.crl.pem \
     certs/web02.cert.pem
   ```

   ```
   C = AR, O = Example Internal Ltd, CN = web02.example.internal
   error 23 at 0 depth lookup: certificate revoked
   error certs/web02.cert.pem: verification failed
   ```

7. Ahora exigí una CRL para **cada** nivel de la cadena y observá la falla — una sorpresa muy común.

   ```bash
   openssl verify -CAfile /opt/pki/root-ca/certs/root-ca.cert.pem \
     -untrusted certs/int-ca.cert.pem \
     -crl_check_all -CRLfile crl/int-ca.crl.pem \
     certs/web01.cert.pem
   ```

   ```
   C = AR, ST = Buenos Aires, L = CABA, O = Example Internal Ltd, OU = Platform Engineering, CN = Example Internal Issuing CA I1
   error 3 at 1 depth lookup: unable to get certificate CRL
   error certs/web01.cert.pem: verification failed
   ```

8. Arreglalo produciendo también la CRL de la root y concatenando ambas.

   ```bash
   cd /opt/pki/root-ca
   openssl ca -config openssl-root.cnf -gencrl \
     -passin pass:RootLabPass331 -out crl/root-ca.crl.pem
   cat /opt/pki/int-ca/crl/int-ca.crl.pem crl/root-ca.crl.pem > /tmp/all.crl.pem
   openssl verify -CAfile certs/root-ca.cert.pem \
     -untrusted /opt/pki/int-ca/certs/int-ca.cert.pem \
     -crl_check_all -CRLfile /tmp/all.crl.pem \
     /opt/pki/int-ca/certs/web01.cert.pem
   ```

   ```
   /opt/pki/int-ca/certs/web01.cert.pem: OK
   ```

9. Convertí la CRL a DER — la forma que realmente se publica en una URI de `crlDistributionPoints`.

   ```bash
   openssl crl -in /opt/pki/int-ca/crl/int-ca.crl.pem \
     -outform DER -out /opt/pki/int-ca/crl/int-ca.crl
   ls -l /opt/pki/int-ca/crl/
   ```

### Verificá tu comprensión — Bloque 6

- **Q6.1** Una CRL tiene `Last Update` y `Next Update`. ¿Qué debe hacer un cliente estricto cuando llega a una CRL cuyo `Next Update` ya pasó, y cuál es el compromiso de disponibilidad de ese comportamiento?
- **Q6.2** `-crl_check` versus `-crl_check_all`: ¿qué certificados de la cadena verifica cada uno?
- **Q6.3** Código de razón `keyCompromise` versus `cessationOfOperation` versus `certificateHold`. ¿Cuál es reversible, y mediante qué mecanismo?
- **Q6.4** Enunciá los dos problemas estructurales de escalabilidad que hacen que las CRLs sean poco atractivas para una CA con diez millones de certificados activos.
- **Q6.5** La CRL se publicó en DER, no en PEM. ¿Por qué importa eso para la interoperabilidad de `crlDistributionPoints`?

---

## Ejercicio 7 — Revocación parte 2: OCSP y OCSP stapling

### Pasos

1. Creá un certificado dedicado para el responder OCSP. Debe llevar el EKU `OCSPSigning` y la extensión `id-pkix-ocsp-nocheck`.

   ```bash
   cd /opt/pki/int-ca
   openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 \
     -out private/ocsp.key.pem
   chmod 0400 private/ocsp.key.pem
   openssl req -new -sha256 -key private/ocsp.key.pem \
     -subj "/C=AR/O=Example Internal Ltd/CN=ocsp.example.internal" \
     -out csr/ocsp.csr.pem
   openssl ca -config openssl-int.cnf -extensions ocsp_signing \
     -days 365 -notext -md sha256 -batch -passin pass:IntLabPass331 \
     -in csr/ocsp.csr.pem -out certs/ocsp.cert.pem
   openssl x509 -in certs/ocsp.cert.pem -noout -text \
     | grep -A2 -E 'Extended Key Usage|OCSP No Check'
   ```

   ```
               X509v3 Extended Key Usage: critical
                   OCSP Signing
               OCSP No Check:
   ```

2. Arrancá el responder en primer plano (Terminal A). Lee el estado de revocación directamente de `index.txt`.

   ```bash
   cd /opt/pki/int-ca
   openssl ocsp -port 2560 \
     -index index.txt \
     -CA certs/int-ca.cert.pem \
     -rkey private/ocsp.key.pem \
     -rsigner certs/ocsp.cert.pem \
     -nrequest 10 -text
   ```

   ```
   Waiting for OCSP client connections...
   ```

3. Consultá el estado del certificado **bueno** (Terminal B).

   ```bash
   cd /opt/pki/int-ca
   openssl ocsp -CAfile /opt/pki/root-ca/certs/root-ca.cert.pem \
     -issuer certs/int-ca.cert.pem \
     -cert certs/web01.cert.pem \
     -url http://127.0.0.1:2560 \
     -resp_text -no_nonce
   ```

   ```
   OCSP Response Data:
       OCSP Response Status: successful (0x0)
       Response Type: Basic OCSP Response
       Version: 1 (0x0)
       Responder Id: C = AR, O = Example Internal Ltd, CN = ocsp.example.internal
       Produced At: Aug 18 12:33:10 2026 GMT
       Responses:
       Certificate ID:
         Hash Algorithm: sha1
         Issuer Name Hash: 9B2C...
         Issuer Key Hash: 7B2A...
         Serial Number: 2000
       Cert Status: good
       This Update: Aug 18 12:33:10 2026 GMT
   ...
   Response verify OK
   certs/web01.cert.pem: good
   	This Update: Aug 18 12:33:10 2026 GMT
   ```

4. Consultá el certificado **revocado**.

   ```bash
   openssl ocsp -CAfile /opt/pki/root-ca/certs/root-ca.cert.pem \
     -issuer certs/int-ca.cert.pem \
     -cert certs/web02.cert.pem \
     -url http://127.0.0.1:2560 -no_nonce
   ```

   ```
   Response verify OK
   certs/web02.cert.pem: revoked
   	This Update: Aug 18 12:34:02 2026 GMT
   	Reason: keyCompromise
   	Revocation Time: Aug 18 12:07:30 2026 GMT
   ```

5. Consultá un serial desconocido para ver el tercer estado posible.

   ```bash
   openssl ocsp -CAfile /opt/pki/root-ca/certs/root-ca.cert.pem \
     -issuer certs/int-ca.cert.pem -serial 0x9999 \
     -url http://127.0.0.1:2560 -no_nonce
   ```

   ```
   Response verify OK
   0x9999: unknown
       This Update: Aug 18 12:35:11 2026 GMT
   ```

6. Configurá OCSP stapling en nginx. Agregá al bloque `server`:

   ```nginx
   server {
       listen 443 ssl;
       http2 on;
       server_name web01.example.internal;

       ssl_certificate           /opt/pki/int-ca/certs/web01-fullchain.pem;
       ssl_certificate_key       /opt/pki/int-ca/private/web01.key.pem;

       ssl_protocols             TLSv1.2 TLSv1.3;
       ssl_prefer_server_ciphers off;
       ssl_session_cache         shared:TLS:10m;
       ssl_session_tickets       off;

       # --- OCSP stapling ---
       ssl_stapling              on;
       ssl_stapling_verify       on;
       ssl_trusted_certificate   /opt/pki/int-ca/certs/ca-chain.cert.pem;
       resolver                  10.20.30.1 valid=300s ipv6=off;
       resolver_timeout          5s;

       root /var/www/html;
   }
   ```

   ```bash
   cat certs/web01.cert.pem certs/int-ca.cert.pem > certs/web01-fullchain.pem
   nginx -t && systemctl reload nginx
   ```

   El equivalente en Apache httpd:

   ```apache
   SSLUseStapling            On
   SSLStaplingCache          "shmcb:/var/run/ocsp(128000)"
   SSLStaplingResponderTimeout 5
   SSLStaplingReturnResponderErrors Off
   ```

7. Confirmá que el staple realmente se está enviando.

   ```bash
   openssl s_client -connect web01.example.internal:443 \
     -servername web01.example.internal \
     -CAfile /opt/pki/root-ca/certs/root-ca.cert.pem \
     -status </dev/null 2>/dev/null | sed -n '/OCSP response/,/^---/p'
   ```

   ```
   OCSP response:
   ======================================
   OCSP Response Data:
       OCSP Response Status: successful (0x0)
       Response Type: Basic OCSP Response
       Cert Status: good
       This Update: Aug 18 12:33:10 2026 GMT
       Next Update: Aug 19 12:33:10 2026 GMT
   ======================================
   ```

   Si el stapling está apagado o el responder es inalcanzable, en cambio obtenés:

   ```
   OCSP response: no response sent
   ```

### Verificá tu comprensión — Bloque 7

- **Q7.1** El certificado del responder lleva `id-pkix-ocsp-nocheck`. Explicá por qué existe esa extensión — ¿qué regreso al infinito ocurriría sin ella?
- **Q7.2** El cliente se invocó con `-no_nonce`. ¿Para qué sirve el nonce de OCSP, qué ataque previene, y por qué la mayoría de los responders públicos lo rechazan?
- **Q7.3** Compará las propiedades de privacidad de la descarga de CRLs frente a la consulta OCSP en vivo, desde la perspectiva del usuario final.
- **Q7.4** El OCSP stapling mueve la consulta del cliente al servidor. Nombrá los dos problemas que resuelve y el que *no* resuelve (pista: ¿qué pasa si el servidor simplemente omite el staple?).
- **Q7.5** En nginx, `ssl_stapling_verify on` requiere `ssl_trusted_certificate`. ¿Qué está verificando exactamente nginx con ese archivo, y por qué no es el mismo archivo que `ssl_certificate`?

---

## Ejercicio 8 — Formatos, bundles y almacenes de confianza del sistema

### Pasos

1. Empaquetá clave + certificado + cadena en un contenedor PKCS#12 (lo que consumen los keystores de Java, Windows y muchos appliances).

   ```bash
   cd /opt/pki/int-ca
   openssl pkcs12 -export \
     -inkey private/web01.key.pem \
     -in certs/web01.cert.pem \
     -certfile certs/ca-chain.cert.pem \
     -name "web01.example.internal" \
     -passout pass:P12LabPass331 \
     -out certs/web01.p12
   ```

2. Inspeccioná el contenedor sin extraer nada sensible al disco.

   ```bash
   openssl pkcs12 -in certs/web01.p12 -passin pass:P12LabPass331 \
     -info -nokeys -noenc | grep -E 'MAC|PKCS7|friendlyName|subject='
   ```

   ```
   MAC: sha256, Iteration 2048
   MAC length: 32, salt length: 8
   PKCS7 Encrypted data: PBES2, PBKDF2, AES-256-CBC, Iteration 2048, PRF hmacWithSHA256
   Bag Attributes
       friendlyName: web01.example.internal
   subject=C = AR, ST = Buenos Aires, O = Example Internal Ltd, CN = web01.example.internal
   ```

3. Extraé las piezas de vuelta.

   ```bash
   openssl pkcs12 -in certs/web01.p12 -passin pass:P12LabPass331 \
     -nocerts -noenc -out /tmp/web01.key.extracted.pem
   openssl pkcs12 -in certs/web01.p12 -passin pass:P12LabPass331 \
     -clcerts -nokeys -out /tmp/web01.cert.extracted.pem
   openssl pkcs12 -in certs/web01.p12 -passin pass:P12LabPass331 \
     -cacerts -nokeys -out /tmp/web01.chain.extracted.pem
   ```

   > En OpenSSL 3, `-noenc` reemplazó a `-nodes` (el nombre viejo sigue funcionando como alias). Si un consumidor antiguo tipo Java 8 o de la era Windows XP rechaza el archivo, reexportalo con `-legacy -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1`; eso requiere que el provider `legacy` se pueda cargar.

4. Convertí el certificado entre las cuatro codificaciones que vas a encontrar en la práctica.

   ```bash
   openssl x509 -in certs/web01.cert.pem -outform DER  -out /tmp/web01.der
   openssl x509 -in /tmp/web01.der -inform DER         -out /tmp/web01.back.pem
   openssl crl2pkcs7 -nocrl -certfile certs/ca-chain.cert.pem -out /tmp/chain.p7b
   openssl pkcs7 -in /tmp/chain.p7b -print_certs -noout
   ```

   ```
   subject=C = AR, ST = Buenos Aires, L = CABA, O = Example Internal Ltd, OU = Platform Engineering, CN = Example Internal Issuing CA I1
   issuer=C = AR, ST = Buenos Aires, L = CABA, O = Example Internal Ltd, OU = Platform Engineering, CN = Example Internal Root CA X1

   subject=C = AR, ST = Buenos Aires, L = CABA, O = Example Internal Ltd, OU = Platform Engineering, CN = Example Internal Root CA X1
   issuer=C = AR, ST = Buenos Aires, L = CABA, O = Example Internal Ltd, OU = Platform Engineering, CN = Example Internal Root CA X1
   ```

5. Instalá la CA raíz en el almacén de confianza del **sistema**.

   ```bash
   # Debian / Ubuntu — file MUST end in .crt and be PEM:
   sudo cp /opt/pki/root-ca/certs/root-ca.cert.pem \
        /usr/local/share/ca-certificates/example-internal-root-ca.crt
   sudo update-ca-certificates
   ```

   ```
   Updating certificates in /etc/ssl/certs...
   1 added, 0 removed; done.
   Running hooks in /etc/ca-certificates/update.d...
   done.
   ```

   ```bash
   # RHEL / Rocky / Alma / Fedora:
   sudo cp /opt/pki/root-ca/certs/root-ca.cert.pem \
        /etc/pki/ca-trust/source/anchors/example-internal-root-ca.pem
   sudo update-ca-trust extract
   ```

6. Probá que la confianza tuvo efecto verificando **sin** `-CAfile`.

   ```bash
   openssl verify -untrusted /opt/pki/int-ca/certs/int-ca.cert.pem \
     /opt/pki/int-ca/certs/web01.cert.pem
   ```

   ```
   /opt/pki/int-ca/certs/web01.cert.pem: OK
   ```

7. Construí un directorio `CApath` con hashes — la alternativa a un único `CAfile` concatenado.

   ```bash
   mkdir -p /opt/pki/capath
   cp /opt/pki/root-ca/certs/root-ca.cert.pem /opt/pki/capath/
   openssl rehash /opt/pki/capath
   ls -l /opt/pki/capath
   ```

   ```
   lrwxrwxrwx 1 user user   19 Aug 18 13:02 3f2a9c1b.0 -> root-ca.cert.pem
   -r--r--r-- 1 user user 2098 Aug 18 13:02 root-ca.cert.pem
   ```

   ```bash
   openssl verify -CApath /opt/pki/capath \
     -untrusted /opt/pki/int-ca/certs/int-ca.cert.pem \
     /opt/pki/int-ca/certs/web01.cert.pem
   ```

8. Limpiá el almacén de confianza del sistema cuando termines el laboratorio.

   ```bash
   sudo rm -f /usr/local/share/ca-certificates/example-internal-root-ca.crt \
              /etc/pki/ca-trust/source/anchors/example-internal-root-ca.pem
   sudo update-ca-certificates --fresh 2>/dev/null || sudo update-ca-trust extract
   ```

### Verificá tu comprensión — Bloque 8

- **Q8.1** Pusiste un archivo `.pem` en `/usr/local/share/ca-certificates/` y `update-ca-certificates` lo ignoró. ¿Por qué?
- **Q8.2** `-CAfile` versus `-CApath`: ¿cuál es el mecanismo de búsqueda en cada caso, y a partir de qué computa `openssl rehash` el nombre del archivo?
- **Q8.3** `update-ca-trust` en RHEL escribe varios bundles de salida. ¿Por qué produce más de un formato, y qué consumidores necesitan cuál?
- **Q8.4** Un archivo PKCS#12 protege la clave privada con una passphrase y además lleva un MAC. ¿Contra qué defiende cada una de esas dos protecciones?
- **Q8.5** Un appliance de un proveedor rechaza tu `.p12` con "unsupported algorithm". ¿Qué cambió en OpenSSL 3.0 que causa esto, y cuál es el arreglo mínimo?

---

## Ejercicio 9 — ACME y Let's Encrypt con certbot

**No ejecutes el paso 4 contra el endpoint de producción de Let's Encrypt durante la práctica.** Los límites de tasa son estrictos y el contador de fallos es por dominio.

### Pasos

1. Inspeccioná lo que certbot sabe sobre este host.

   ```bash
   certbot certificates
   certbot --version
   ```

   ```
   Saving debug log to /var/log/letsencrypt/letsencrypt.log
   No certificates found.
   certbot 2.9.0
   ```

2. Entendé los dos tipos de challenge antes de elegir uno.

   | Challenge | Qué verifica la CA | Requiere | Wildcards |
   |---|---|---|---|
   | `http-01` | `http://<domain>/.well-known/acme-challenge/<token>` devuelve la key authorization | TCP/80 entrante alcanzable desde internet | **No** |
   | `dns-01` | registro TXT en `_acme-challenge.<domain>` igual a base64url(SHA-256(key authorization)) | proveedor de DNS con API | **Sí** |
   | `tls-alpn-01` | handshake TLS en 443 con ALPN `acme-tls/1` presentando un certificado autofirmado especial | TCP/443 entrante, sin necesidad de redirección HTTP | No |

3. Ejecutá un **dry run** contra el entorno de staging usando el plugin webroot. Esto ejercita el protocolo completo sin consumir cuota de producción.

   ```bash
   sudo certbot certonly --dry-run \
     --webroot -w /var/www/html \
     -d example.com -d www.example.com \
     --agree-tos -m admin@example.com --no-eff-email
   ```

   ```
   Saving debug log to /var/log/letsencrypt/letsencrypt.log
   Simulating a certificate request for example.com and www.example.com
   Performing the following challenges:
   http-01 challenge for example.com
   http-01 challenge for www.example.com
   Using the webroot path /var/www/html for all unmatched domains.
   Waiting for verification...
   Cleaning up challenges
   The dry run was successful.
   ```

4. Emití de verdad (solo si efectivamente controlás el dominio). Notá el deploy hook — recargar el servidor es responsabilidad *tuya*, no de certbot.

   ```bash
   sudo certbot certonly \
     --webroot -w /var/www/html \
     -d example.com -d www.example.com \
     --key-type ecdsa --elliptic-curve secp256r1 \
     --agree-tos -m admin@example.com --no-eff-email \
     --deploy-hook 'systemctl reload nginx'
   ```

5. Examiná el layout resultante. Entendé que `live/` contiene **symlinks** hacia `archive/`.

   ```bash
   sudo ls -l /etc/letsencrypt/live/example.com/
   ```

   ```
   lrwxrwxrwx 1 root root  35 Aug 18 13:40 cert.pem -> ../../archive/example.com/cert1.pem
   lrwxrwxrwx 1 root root  36 Aug 18 13:40 chain.pem -> ../../archive/example.com/chain1.pem
   lrwxrwxrwx 1 root root  40 Aug 18 13:40 fullchain.pem -> ../../archive/example.com/fullchain1.pem
   lrwxrwxrwx 1 root root  38 Aug 18 13:40 privkey.pem -> ../../archive/example.com/privkey1.pem
   -rw-r--r-- 1 root root 692 Aug 18 13:40 README
   ```

   | Archivo | Contenido | Uso en nginx/httpd |
   |---|---|---|
   | `cert.pem` | solo la hoja | `SSLCertificateFile` (httpd ≥2.4.8 puede tomar fullchain) |
   | `chain.pem` | solo la(s) intermedia(s) | `SSLCertificateChainFile` (legacy), `ssl_trusted_certificate` para stapling |
   | `fullchain.pem` | hoja + intermedia(s) | `ssl_certificate` en nginx — **este es el que querés** |
   | `privkey.pem` | clave privada, modo 0600 | `ssl_certificate_key` |

6. Verificá que el timer de renovación esté activo. Los paquetes modernos traen un timer de systemd; no agregues un cron job encima.

   ```bash
   systemctl list-timers 'certbot*' --all
   systemctl cat certbot.timer | sed -n '/\[Timer\]/,$p'
   ```

   ```
   [Timer]
   OnCalendar=*-*-* 00,12:00:00
   RandomizedDelaySec=43200
   Persistent=true
   ```

7. Ejercitá la renovación sin renovar realmente.

   ```bash
   sudo certbot renew --dry-run
   ```

   ```
   Processing /etc/letsencrypt/renewal/example.com.conf
   Simulating renewal of an existing certificate for example.com and www.example.com
   Congratulations, all simulated renewals succeeded:
     /etc/letsencrypt/live/example.com/fullchain.pem (success)
   ```

8. Leé la configuración de renovación — esto es lo que `certbot renew` reproduce.

   ```bash
   sudo cat /etc/letsencrypt/renewal/example.com.conf
   ```

   ```ini
   version = 2.9.0
   archive_dir = /etc/letsencrypt/archive/example.com
   cert = /etc/letsencrypt/live/example.com/cert.pem
   privkey = /etc/letsencrypt/live/example.com/privkey.pem
   chain = /etc/letsencrypt/live/example.com/chain.pem
   fullchain = /etc/letsencrypt/live/example.com/fullchain.pem

   [renewalparams]
   account = 1a2b3c...
   authenticator = webroot
   webroot_path = /var/www/html,
   server = https://acme-v02.api.letsencrypt.org/directory
   key_type = ecdsa
   elliptic_curve = secp256r1
   renew_hook = systemctl reload nginx
   ```

9. Para un wildcard, `dns-01` es obligatorio. Con el plugin manual:

   ```bash
   sudo certbot certonly --manual --preferred-challenges dns \
     -d '*.example.com' -d example.com \
     --server https://acme-staging-v02.api.letsencrypt.org/directory
   ```

   ```
   Please deploy a DNS TXT record under the name:
   _acme-challenge.example.com.
   with the following value:
   gfj9Xq...Rg85nM

   Press Enter to Continue
   ```

   En producción usá en cambio un plugin de DNS (`certbot-dns-cloudflare`, `-route53`, `-rfc2136`) para que la renovación sea desatendida.

### Verificá tu comprensión — Bloque 9

- **Q9.1** Los certificados de Let's Encrypt son válidos por 90 días. Dá los dos argumentos — uno de seguridad, uno operativo — que el proyecto usa para justificar una vida tan corta.
- **Q9.2** Tenés que emitir para `*.internal.example.com`. ¿Qué tipo de challenge tenés que usar y por qué el otro es estructuralmente incapaz de hacerlo?
- **Q9.3** `--deploy-hook` versus `--post-hook` versus `--pre-hook`: ¿cuándo se dispara cada uno, y cuál debe llevar tu `systemctl reload`?
- **Q9.4** `live/fullchain.pem` es un symlink hacia `archive/`. ¿Qué se rompe si tu gestión de configuración copia el *contenido del archivo* a `/etc/nginx/ssl/` en el momento de la instalación?
- **Q9.5** Se presenta un certificado wildcard para `*.example.com` para el host `a.b.example.com`. ¿Coincide? Enunciá la regla.

---

## Ejercicio 10 — Diagnóstico: reproducir y leer las seis fallas clásicas

Para cada escenario, reproducilo, capturá el error exacto y enunciá el arreglo.

### Pasos

1. **Cadena incompleta.** Arrancá `s_server` presentando solo la hoja.

   ```bash
   cd /opt/pki/int-ca
   openssl s_server -accept 4433 -cert certs/web01.cert.pem \
     -key private/web01.key.pem -www &
   openssl s_client -connect 127.0.0.1:4433 \
     -CAfile /opt/pki/root-ca/certs/root-ca.cert.pem \
     -brief </dev/null 2>&1 | grep -Ei 'verif|error'
   kill %1
   ```

   ```
   Verification error: unable to get local issuer certificate
   ```

   Esta es la falla del "funciona en Chrome pero no en curl": los navegadores reparan la cadena en silencio vía la URI `caIssuers` de AIA; `openssl`, `curl` y la mayoría de los runtimes de lenguajes no lo hacen.

2. **Certificado expirado.** Emití uno que ya está muerto usando `-startdate`/`-enddate`.

   ```bash
   openssl ca -config openssl-int.cnf -extfile ext/web01.ext \
     -startdate 250101000000Z -enddate 250401000000Z \
     -notext -md sha256 -batch -passin pass:IntLabPass331 \
     -in csr/web01.csr.pem -out /tmp/expired.cert.pem
   openssl verify -CAfile /opt/pki/root-ca/certs/root-ca.cert.pem \
     -untrusted certs/int-ca.cert.pem /tmp/expired.cert.pem
   ```

   ```
   C = AR, ST = Buenos Aires, O = Example Internal Ltd, CN = web01.example.internal
   error 10 at 0 depth lookup: certificate has expired
   notAfter=Apr  1 00:00:00 2025 GMT
   error /tmp/expired.cert.pem: verification failed
   ```

3. **Propósito equivocado.** Presentá un certificado de cliente a un chequeo de server-auth.

   ```bash
   openssl ca -config openssl-int.cnf -extensions client_cert -days 30 \
     -notext -md sha256 -batch -passin pass:IntLabPass331 \
     -in csr/web02.csr.pem -out /tmp/clientonly.cert.pem
   openssl verify -CAfile /opt/pki/root-ca/certs/root-ca.cert.pem \
     -untrusted certs/int-ca.cert.pem \
     -purpose sslserver /tmp/clientonly.cert.pem
   ```

   ```
   C = AR, O = Example Internal Ltd, CN = web02.example.internal
   error 26 at 0 depth lookup: unsupported certificate purpose
   error /tmp/clientonly.cert.pem: verification failed
   ```

4. **Desajuste clave/certificado.** Compará las claves públicas.

   ```bash
   openssl x509 -in certs/web01.cert.pem -noout -pubkey | openssl sha256
   openssl pkey -in private/web02.key.pem -pubout | openssl sha256
   ```

   ```
   SHA2-256(stdin)= 5c8a1f...e3
   SHA2-256(stdin)= 91bd47...0a
   ```

   Dos digests distintos ⇒ nginx se va a negar a arrancar con `SSL_CTX_use_PrivateKey_file(...) failed ... key values mismatch`.

5. **Desajuste de hostname a través de un handshake real.**

   ```bash
   openssl s_server -accept 4433 -cert certs/web01.cert.pem \
     -key private/web01.key.pem -cert_chain certs/int-ca.cert.pem -www &
   openssl s_client -connect 127.0.0.1:4433 \
     -CAfile /opt/pki/root-ca/certs/root-ca.cert.pem \
     -verify_hostname api.example.internal -verify_return_error \
     -brief </dev/null 2>&1 | head -4
   kill %1
   ```

   ```
   Verification error: Hostname mismatch
   00A1B2C3D4E5F600:error:0A000086:SSL routines:tls_post_process_server_certificate:certificate verify failed:...
   ```

6. **Desfase de reloj.** Verificá un certificado válido en una fecha pasada simulada.

   ```bash
   openssl verify -CAfile /opt/pki/root-ca/certs/root-ca.cert.pem \
     -untrusted certs/int-ca.cert.pem \
     -attime $(date -d '2020-01-01' +%s) \
     certs/web01.cert.pem
   ```

   ```
   C = AR, ST = Buenos Aires, O = Example Internal Ltd, CN = web01.example.internal
   error 9 at 0 depth lookup: certificate is not yet valid
   notBefore=Aug 18 11:45:19 2026 GMT
   error certs/web01.cert.pem: verification failed
   ```

7. **Tabla de referencia — memorizá estos códigos.**

   | Código | Mensaje | Causa raíz habitual |
   |---|---|---|
   | 2 | unable to get issuer certificate | falta el trust anchor en `-CAfile`/almacén |
   | 3 | unable to get certificate CRL | `-crl_check_all` sin una CRL para cada nivel |
   | 9 | certificate is not yet valid | desfase de reloj, o recién emitido con `notBefore` futuro |
   | 10 | certificate has expired | la renovación falló / el hook nunca recargó el servicio |
   | 18 | self-signed certificate | hoja autofirmada ofrecida como si fuera emitida por una CA |
   | 19 | self-signed certificate in certificate chain | root privada no instalada en el almacén del cliente |
   | 20 | unable to get local issuer certificate | **el servidor envió una cadena incompleta** |
   | 21 | unable to verify the first certificate | falta la intermedia, visto desde el lado del cliente |
   | 23 | certificate revoked | listado en la CRL / OCSP dice `revoked` |
   | 24 | invalid CA certificate | `basicConstraints` dice `CA:FALSE` en un emisor |
   | 26 | unsupported certificate purpose | EKU / keyUsage no permite la operación |
   | 62 | hostname mismatch | el nombre no está en la SAN |

8. Un one-liner listo para usar en guardia: volcá todo sobre un endpoint en vivo.

   ```bash
   HOST=www.lpi.org
   openssl s_client -connect "$HOST:443" -servername "$HOST" \
     -showcerts -status </dev/null 2>/dev/null \
   | tee /tmp/$HOST.out \
   | awk '/Certificate chain/,/^---$/' 
   grep -E 'Verify return code|Protocol|Cipher' /tmp/$HOST.out
   openssl x509 -in /tmp/$HOST.out -noout -subject -dates 2>/dev/null
   ```

   ```
   Verify return code: 0 (ok)
   Protocol  : TLSv1.3
   Cipher    : TLS_AES_256_GCM_SHA384
   subject=CN = www.lpi.org
   notBefore=Jul 14 09:21:44 2026 GMT
   notAfter=Oct 12 09:21:43 2026 GMT
   ```

### Verificá tu comprensión — Bloque 10

- **Q10.1** El error 20 y el error 21 significan ambos "no se pudo encontrar el emisor". ¿Desde qué punto de vista se reporta normalmente cada uno, y qué único cambio del lado del servidor arregla ambos?
- **Q10.2** Explicá, en una oración cada uno, por qué los errores 18 y 19 son distintos.
- **Q10.3** Chrome carga la página; `curl` falla con error 20 contra el mismo servidor. Explicá el mecanismo con precisión, y dá el arreglo *del lado del servidor* (no un workaround del cliente).
- **Q10.4** Un chequeo de monitoreo basado en `notAfter` reportó el certificado como válido, y sin embargo los clientes recibieron el error 10. Nombrá dos maneras en que eso puede pasar.
- **Q10.5** ¿Qué hace `-attime`, y por qué es más confiable que cambiar el reloj del sistema para reproducir un bug de ventana de validez?

---

## Fuentes

- LPI — Objetivos del examen 303 (303-300, v3.0.0): <https://www.lpi.org/our-certifications/exam-303-objectives/>
- RFC 5280 — *Internet X.509 PKI Certificate and CRL Profile*: <https://www.rfc-editor.org/rfc/rfc5280>
- RFC 6960 — *X.509 Internet PKI Online Certificate Status Protocol (OCSP)*: <https://www.rfc-editor.org/rfc/rfc6960>
- RFC 6125 — *Representation and Verification of Domain-Based Application Service Identity*: <https://www.rfc-editor.org/rfc/rfc6125>
- RFC 8446 — *TLS 1.3* (§4.4.2.1, extensión de estado de certificado): <https://www.rfc-editor.org/rfc/rfc8446>
- RFC 8555 — *Automatic Certificate Management Environment (ACME)*: <https://www.rfc-editor.org/rfc/rfc8555>
- RFC 7292 — *PKCS #12 Personal Information Exchange Syntax v1.1*: <https://www.rfc-editor.org/rfc/rfc7292>
- Manual de OpenSSL 3.x — `openssl-ca`: <https://docs.openssl.org/3.0/man1/openssl-ca/>
- Manual de OpenSSL 3.x — `openssl-verify` y opciones de verificación: <https://docs.openssl.org/3.0/man1/openssl-verification-options/>
- Manual de OpenSSL 3.x — `x509v3_config` (sintaxis de extensiones): <https://docs.openssl.org/3.0/man5/x509v3_config/>
- Manual de OpenSSL 3.x — `openssl-ocsp`: <https://docs.openssl.org/3.0/man1/openssl-ocsp/>
- Manual de OpenSSL 3.x — `config` (sintaxis de `openssl.cnf`): <https://docs.openssl.org/3.0/man5/config/>
- CA/Browser Forum — Baseline Requirements for TLS Server Certificates: <https://cabforum.org/working-groups/server/baseline-requirements/documents/>
- Let's Encrypt — Challenge Types: <https://letsencrypt.org/docs/challenge-types/>
- Let's Encrypt — Rate Limits y el entorno de staging: <https://letsencrypt.org/docs/rate-limits/> · <https://letsencrypt.org/docs/staging-environment/>
- Guía de usuario de Certbot: <https://eff-certbot.readthedocs.io/en/stable/using.html>
- nginx — `ngx_http_ssl_module` (`ssl_stapling`): <https://nginx.org/en/docs/http/ngx_http_ssl_module.html>
- Apache httpd — `mod_ssl` (`SSLUseStapling`): <https://httpd.apache.org/docs/2.4/mod/mod_ssl.html>

---

<details>
<summary><strong>Respuestas</strong> — expandí solo después de haber intentado todos los bloques</summary>

### Bloque 1 — Material de claves

**A1.1**
- `-----BEGIN PRIVATE KEY-----` → un `PrivateKeyInfo` de PKCS#8 (RFC 5208/5958): versión, un `AlgorithmIdentifier` que nombra el algoritmo, y el blob de clave específico del algoritmo envuelto en un `OCTET STRING`. Como el algoritmo se nombra adentro, **esta etiqueta lleva RSA, EC, Ed25519, X25519, DSA — cualquier cosa — sin cambiar**. Esto es lo que `openssl genpkey` escribe por defecto y lo que deberías estandarizar.
- `-----BEGIN RSA PRIVATE KEY-----` → el `RSAPrivateKey` legacy de PKCS#1 (módulo, exponentes, primos, coeficientes CRT) sin identificador de algoritmo. La etiqueta *es* la declaración de tipo. El análogo para EC es `-----BEGIN EC PRIVATE KEY-----`, un `ECPrivateKey` de SEC1. `openssl rsa -traditional` / `openssl ec` emiten estos.
- `-----BEGIN ENCRYPTED PRIVATE KEY-----` → un `EncryptedPrivateKeyInfo` de PKCS#8: un `AlgorithmIdentifier` de KDF+cifrador (típicamente PBES2 con PBKDF2 y AES-256-CBC) más el texto cifrado del `PrivateKeyInfo`. Notá que los PEM cifrados legacy en cambio conservan la etiqueta `RSA PRIVATE KEY` y ponen cabeceras `Proc-Type:` / `DEK-Info:` en el preámbulo del PEM — un esquema mucho más débil (KDF basado en MD5, una iteración) del que deberías migrar.

**A1.2** Ninguno de los dos es un *formato* en el sentido de "qué campos existen" — eso lo fija el esquema ASN.1 (X.509 para certificados, PKCS#8 para claves, PKCS#10 para CSRs). **DER** (Distinguished Encoding Rules) es la serialización binaria canónica de ese ASN.1. **PEM** es DER, codificado en base64, envuelto en la armadura `-----BEGIN x-----`/`-----END x-----`. Entonces: PEM es un sobre alrededor de DER, y el mismo certificado en PEM y en DER es bit por bit el mismo certificado. Esto importa en la práctica: una firma se computa sobre los bytes DER, que es por lo que el viaje de ida y vuelta del paso 7 es sin pérdidas, y por lo que `openssl asn1parse` ve el mismo árbol en cualquiera de los dos.

**A1.3** La clave pública es un *componente* de la estructura de la clave privada — para RSA el archivo de clave privada contiene literalmente `n` y `e` junto a `d`, `p`, `q`; para EC contiene `d` y (usualmente) el punto codificado `Q = d·G`. Así que `-pubout` es extracción, no cómputo. Ir en la otra dirección requiere resolver el problema difícil subyacente: la factorización de enteros de `n` para RSA, o el logaritmo discreto de curva elíptica (recuperar `d` a partir de `Q = d·G`) para EC. Ambos se creen intratables con estos tamaños de clave y hardware clásico; esa asimetría *es* la seguridad del sistema.

**A1.4** La alternativa es `ec_param_enc:explicit`, que serializa la definición completa de la curva (cuerpo, `a`, `b`, generador, orden, cofactor) dentro de cada clave y certificado en lugar de un único OID de curva. Rompe la interoperabilidad porque (a) infla la codificación en cientos de bytes; (b) muchas librerías TLS — y los Baseline Requirements del CA/Browser Forum — exigen `namedCurve` y rechazan de plano los parámetros explícitos; y (c) los parámetros explícitos históricamente habilitaron ataques de curva inválida y de sustitución de parámetros, ya que se le pide al verificador que confíe en parámetros de curva suministrados por la parte no confiable. Usá siempre `named_curve`.

**A1.5** **P-256** es comparable a **RSA-3072** — ambas apuntan aproximadamente al nivel de seguridad de 128 bits. (P-384 ≈ RSA-7680; RSA-2048 ≈ ~112 bits, que es por lo que NIST fijó su fin de vida en 2030.) Operativamente, en el *servidor* la dirección que importa es la firma: firmar con ECDSA P-256 es aproximadamente un orden de magnitud más rápido que las operaciones de clave privada RSA-3072, así que un certificado EC eleva materialmente el throughput de handshakes en un terminador TLS con carga. El compromiso se invierte en el cliente: la *verificación* RSA (con exponente público pequeño 65537) es muy rápida, mientras que la verificación ECDSA es más lenta que la firma ECDSA. Dado que los servidores firman una vez por handshake y los clientes verifican una vez, EC es el default correcto para certificados de servidor. Los certificados también son mucho más chicos, lo que reduce los bytes en el primer round trip.

---

### Bloque 2 — Leer un certificado

**A2.1** Los tres hijos del `SEQUENCE` exterior (la estructura `Certificate` de la RFC 5280 §4.1) son:
1. `tbsCertificate` — un `SEQUENCE` que contiene versión, serial, algoritmo de firma, issuer, validez, subject, `SubjectPublicKeyInfo` y extensiones. En el volcado este es el hijo en el offset 4 (`hl=4 l=686`).
2. `signatureAlgorithm` — un `AlgorithmIdentifier` (offset 694), que debe ser igual al algoritmo nombrado *dentro* de `tbsCertificate`; un desajuste es una señal de alarma de sustitución de firma.
3. `signatureValue` — un `BIT STRING` (offset 706) que contiene la firma de la CA.

La firma se computa sobre la **codificación DER de `tbsCertificate` únicamente** — los bytes 4 a 689 inclusive en este volcado, es decir, incluyendo su propio tag `SEQUENCE` y su cabecera de longitud. Nada fuera de ese rango está protegido, que es exactamente por lo que `signatureAlgorithm` está duplicado dentro de la región firmada.

**A2.2** Un cliente moderno usa **`subjectAltName` exclusivamente**. La RFC 6125 dejó obsoleto el uso del CN como hostname, y los Baseline Requirements del CA/Browser Forum prohíben apoyarse en el `commonName` para identidad desde 2017; Chrome eliminó el fallback al CN en la versión 58, y Firefox, `crypto/tls` de Go y el `X509_check_host()` actual de OpenSSL se comportan igual. El CN se conserva solo como etiqueta legible por humanos — y si está presente debe duplicar un nombre que también aparezca en la SAN. Consecuencia práctica: un certificado con un CN correcto y **sin** extensión SAN falla en todo cliente moderno, que es la causa más común del "antes funcionaba" tras la actualización de un cliente.

**A2.3** El booleano `critical` de una `Extension` es la declaración del emisor de que esa extensión es esencial para interpretar el certificado de forma segura. La RFC 5280 §4.2 requiere que un cliente que encuentre una **extensión crítica cuyo OID no reconoce DEBE rechazar el certificado**. Las extensiones desconocidas no críticas pueden ignorarse. Este es el mecanismo que le permite al ecosistema desplegar semánticas nuevas de forma segura: marcar `basicConstraints` como crítica significa que un cliente viejo que no entiende la distinción CA-vs-hoja rechaza el certificado en lugar de confundir una hoja con una CA — históricamente la raíz de los ataques de "cualquier hoja puede firmar" de los años 2000.

**A2.4**
- **URI de `OCSP`** — a dónde envía un cliente una consulta OCSP para conocer el estado de revocación de *este* certificado (Ejercicio 7).
- **URI de `CA Issuers`** — dónde descargar el certificado del **emisor**, en DER.

**`CA Issuers` es el mecanismo de rescate.** Cuando un servidor envía solo su hoja, un cliente que implementa "AIA chasing" (Chrome, Safari, Windows/Schannel, macOS) descarga la intermedia desde esa URI y repara la cadena por su cuenta. `openssl s_client`, `curl`, Go, Java y el módulo `ssl` de Python **no** persiguen AIA, lo que produce exactamente la división "funciona en el navegador, falla en mi código" que reproducís en el Ejercicio 10.

**A2.5** Un fingerprint de certificado cambia en **cada renovación**, porque el serial, las fechas de validez y la firma cambian todos — así que un pin de fingerprint se rompe cada 60–90 días. Un pin SPKI es un hash únicamente del `SubjectPublicKeyInfo`, así que sobrevive a cualquier renovación que **reutilice el par de claves** (o que use una clave de respaldo pregenerada). Por eso la RFC 7469 y toda guía de pinning móvil especifican pines SPKI, y por eso se fijan al menos dos valores: la clave en producción y una clave de respaldo en frío guardada offline. Fijar el SPKI de una intermedia o de una root da aún más durabilidad, al costo de una superficie de confianza más amplia.

---

### Bloque 3 — Root CA

**A3.1** La autofirma es verificable con la clave pública contenida en ese mismísimo certificado. Cualquiera puede generar un par de claves, escribir el Subject DN que se le antoje — incluido `CN = GlobalSign Root CA` — y producir una autofirma matemáticamente válida. Por lo tanto, la firma prueba solamente **consistencia interna y posesión de la clave privada correspondiente**; no transmite ninguna autoridad. La confianza viene enteramente de la **distribución fuera de banda**: el certificado fue colocado en el almacén de confianza de la parte que confía por un administrador (`update-ca-trust`), por el proveedor del SO/navegador tras una auditoría WebTrust/ETSI, o por una política de MDM. El almacén de confianza es el axioma; todo lo demás se deriva por encadenamiento de firmas a partir de él.

**A3.2**
- `index.txt` — la base de datos de la CA: una línea por certificado emitido, que registra estado, vencimiento, fecha y razón de revocación, serial y DN del subject. `openssl ca -gencrl` y `openssl ocsp -index` leen el estado de revocación de **acá**, no de los archivos de certificado.
- `serial` — el próximo número de serie a asignar, en hexadecimal; `openssl ca` lo lee, emite, lo incrementa y lo escribe de vuelta (dejando `serial.old`).
- `crlnumber` — el valor monótonamente creciente de la extensión `CRLNumber` para la próxima CRL.

Restaurar un `index.txt` de hace un día es un **incidente de seguridad**, no una molestia: (a) cualquier certificado revocado en la ventana perdida vuelve silenciosamente al estado `V`, así que la próxima CRL y toda respuesta OCSP declaran `good` una clave comprometida; (b) los certificados emitidos en esa ventana desaparecen de la base de datos, con lo que nunca pueden ser revocados y sus seriales pueden ser **reemitidos**, produciendo dos certificados distintos que comparten un serial bajo un mismo emisor — una violación de la RFC 5280 que vuelve ambigua la revocación por serial. La recuperación implica reconciliar contra `newcerts/` (que guarda una copia de cada certificado emitido, nombrada por serial) y contra tus registros de emisión.

**A3.3** El valor por defecto es `unique_subject = yes`, que hace que `openssl ca` se niegue a emitir un segundo certificado válido para un subject DN que ya tiene uno, con:

```
ERROR:There is already a certificate for /C=AR/.../CN=web01.example.internal
```

El escenario de caída es la **renovación de rutina con solapamiento**. La buena práctica es emitir el certificado de reemplazo días o semanas antes de que expire el viejo, desplegarlo, verificarlo, y recién después dejar que el viejo caduque. Con `unique_subject = yes` esa segunda emisión se rechaza mientras la primera siga siendo válida, así que el operador se ve forzado a revocar primero el certificado en producción (una ventana sin certificado válido, y un certificado revocado todavía desplegado) o a editar `index.txt` a mano bajo presión de tiempo. Lo mismo muerde a cualquier CA que emita certificados por nodo donde un nodo se reconstruye y se vuelve a inscribir bajo el mismo DN. Configurá `unique_subject = no` en cualquier CA emisora.

**A3.4** Coincidir contra el campo correspondiente del **Subject del propio certificado de la CA** — es decir, el DN en `[ CA_default ] certificate`. Con `organizationName = match`, un CSR se acepta solo si su `O` es idéntico byte a byte al `O` de la root (`Example Internal Ltd`). Los tres verbos de política son:
- `match` — debe ser igual al valor de la CA para ese campo;
- `supplied` — debe estar presente en el CSR, con cualquier valor;
- `optional` — puede estar ausente.

Notá el filo cortante: la coincidencia es una comparación de cadenas, así que `Example Internal Ltd` versus `Example Internal Ltd.` falla. Por eso las CAs emisoras usan normalmente `policy_loose` y hacen cumplir la nomenclatura mediante un front-end de inscripción real.

**A3.5** `keyCertSign` es el bit que autoriza a firmar **certificados**; `cRLSign` autoriza a firmar **CRLs**. Son bits independientes del BIT STRING `KeyUsage` y un validador debe chequear `keyCertSign` en cada CA de la ruta (RFC 5280 §6.1.4). `digitalSignature` no es requerido para ninguno de los dos — está acá por generalidad (por ejemplo, si la clave de la CA alguna vez firma una respuesta OCSP directamente en lugar de delegar en un certificado de responder). Un certificado de CA al que le falta `keyCertSign` mientras `basicConstraints` dice `CA:TRUE` produce `error 24: invalid CA certificate` en los certificados que emite.

---

### Bloque 4 — CA intermedia y cadenas

**A4.1** `pathlen:0` fija `pathLenConstraint = 0`, lo que significa que **cero certificados de CA adicionales pueden aparecer por debajo de este en una ruta válida**. *No* cuenta a la intermedia misma, y no cuenta al certificado de entidad final. Así que esta intermedia puede emitir certificados hoja, pero no puede emitir otro certificado de CA. `pathlen:1` permitiría exactamente un nivel de CA más por debajo. Dos reglas más que vale conocer: `pathLenConstraint` solo tiene sentido cuando `CA:TRUE` y `keyCertSign` están afirmados, y un certificado de CA sin `pathLenConstraint` alguno no impone ningún límite de profundidad.

**A4.2** Con `nameConstraints = permitted;DNS:.example.internal`, un cliente que aplica name constraints (Windows/Schannel, macOS, OpenSSL, NSS, Java — la aplicación está muy extendida y es exigida por los Baseline Requirements) va a rechazar cualquier certificado bajo esta intermedia cuya SAN caiga fuera de los subárboles permitidos. Así que el atacante que tenga la clave robada **puede** acuñar certificados válidos para `cualquiercosa.example.internal` — suplantación total dentro de tu espacio de nombres — y **no puede** acuñar un certificado utilizable para `www.google.com`, `example.com`, ni ninguna IP literal (las entradas `excluded;IP` cierran el subárbol de IP). Esta es la mitigación estándar para el cross-signing de la CA de un cliente o subsidiaria, y la razón por la que una root privada que se va a distribuir a las laptops de los empleados debería llevar name constraints: acota el radio de daño de la pérdida de tu propia clave a tu propio espacio de nombres.

Dos salvedades para decir con honestidad: las constraints las aplica la *parte que confía*, así que un cliente que las ignora (algunos stacks embebidos, Android viejo) no gana protección alguna; y las constraints sobre `DNS` no restringen automáticamente `IP`, `email` ni `directoryName` — tenés que excluir esos subárboles explícitamente, que es exactamente lo que hacen las líneas `excluded;IP`.

**A4.3** `openssl ca` se diferencia de `req -x509` en que:
1. **Mantiene estado** — asigna el serial desde `serial`, agrega una fila a `index.txt`, y escribe una copia del certificado en `new_certs_dir` con el nombre `<serial>.pem`. `req -x509` escribe un archivo y no recuerda nada, así que el certificado resultante nunca podrá ser revocado por esa CA.
2. **Firma un CSR proveniente de una clave separada** — la clave pública del subject viene de la solicitud PKCS#10 y la clave firmante es la de la CA. `req -x509` autofirma: una sola clave juega ambos roles.
3. **Aplica una política de nombres** (`policy_strict` / `policy_loose`) y pide confirmación antes de comprometer el cambio, dándole al operador una instancia de revisión.

Además, solo `openssl ca` soporta `-revoke`, `-gencrl`, `-status` y `-crl_reason`, y solo él respeta `copy_extensions`. Corolario para el examen: un certificado raíz producido por `req -x509` no aparece en su propio `index.txt`, y eso es correcto — una CA nunca emite su propio certificado a través de su propia base de datos.

**A4.4** Prueba la **posesión de la clave**: quienquiera que produjo el CSR tenía la clave privada correspondiente a la clave pública que contiene, en el momento de firmar. Eso impide que un atacante envíe *tu* clave pública bajo *su* nombre y obtenga un certificado que no puede usar — y, más sutilmente, que obtenga un certificado que ate tu clave a un nombre que no controlás.

**No** prueba nada sobre identidad ni autorización: ni que el solicitante sea dueño de `example.internal`, ni que el DN sea veraz, ni que la solicitud no haya sido reenviada por un tercero que la interceptó (el CSR no está ligado a un transporte ni a un nonce). La validación de control del dominio, los controles de identidad corporativa, o un canal de inscripción autenticado deben proveer eso por separado — que es precisamente el trabajo que automatiza ACME en el Ejercicio 9.

**A4.5** Con `copy_extensions = copy`, `openssl ca` trasplanta las extensiones solicitadas dentro del CSR al certificado emitido. Como un CSR está enteramente bajo el control del atacante (está autofirmado por el solicitante, y esa firma no atestigua nada sobre el contenido), un solicitante puede incrustar:

```
subjectAltName = DNS:login.corp.example.com, DNS:*.example.internal
basicConstraints = critical, CA:TRUE
keyUsage = critical, keyCertSign, cRLSign
```

Si el operador lo firma tras revisar únicamente el Subject DN — que es todo lo que resalta el prompt de confirmación de `openssl ca`, y todo lo que restringe la `policy` de nombres — la CA emite un certificado válido para hosts que el solicitante no controla, o peor, un **certificado de CA subordinada** que le permite al solicitante emitir certificados arbitrarios bajo tu root. Las `nameConstraints` en la intermedia acotan el daño pero no lo eliminan.

Los patrones seguros, en orden de preferencia: mantener `copy_extensions = none` y suministrar las extensiones desde un `-extfile` controlado por la CA, como en el Ejercicio 5; o usar `copy_extensions = copyall` **solo** detrás de un front-end de inscripción que parsee y ponga en lista blanca las SANs solicitadas contra una base de datos de autorización antes de invocar `openssl ca`. Notá que OpenSSL viene con `copy_extensions` comentado (efectivamente `none`) precisamente por esto.

---

### Bloque 5 — Certificados de servidor

**A5.1** Por defecto `openssl verify` construye y valida criptográficamente la ruta y chequea las fechas de validez — y ahí se detiene. Un navegador además realiza al menos:
1. **Verificación de hostname** contra la SAN (RFC 6125 / `X509_check_host`) — `openssl verify` hace esto solo con `-verify_hostname`, y `s_client` solo con `-verify_hostname` o `-verify_ip`.
2. **Chequeo de propósito/EKU** — que la hoja afirme `serverAuth`; agregá `-purpose sslserver`.

Otros chequeos del lado del navegador que vale nombrar: revocación (CRLSets/OCSP), presencia de SCT de Certificate Transparency para certificados de confianza pública, política de vida máxima, y rechazo de algoritmos de firma débiles (SHA-1) o claves cortas.

**A5.2**
- **Error 2, `unable to get issuer certificate`** — reportado a una profundidad distinta de cero: OpenSSL subió parte de la cadena y después no pudo encontrar el emisor de una *intermedia*, es decir, **falta el trust anchor**. En el paso 7 el segundo comando pasó la intermedia como `-CAfile`, así que la root no estaba por ningún lado.
- **Error 20, `unable to get local issuer certificate`** — reportado en profundidad 0: no se pudo ubicar el emisor de la **hoja misma**, es decir, **falta la intermedia**.

El error 20 es la firma del "el servidor se olvidó de enviar la intermedia". Su hermano del lado del cliente es el error 21, `unable to verify the first certificate`, que `s_client` reporta para la misma condición subyacente.

**A5.3** Las CAs públicas no pueden validar el control de una dirección RFC 1918, y los Baseline Requirements del CA/Browser Forum prohíben los certificados para nombres internos y direcciones IP reservadas desde 2016 (todos esos certificados fueron revocados en el fin de vida de 2015–2016). Una dirección IP *pública* sí puede certificarse, pero requiere un método específico de validación de IP y es poco frecuente.

Para una PKI interna el cálculo cambia por completo: vos sos la autoridad de tu propio espacio de direcciones, así que las SANs `IP:` son legítimas y a menudo necesarias — los health checkers, service meshes, balanceadores de carga y agentes de arranque se conectan con frecuencia por dirección antes de que haya DNS disponible. Siguen aplicando dos reglas: la SAN debe usar el tipo de GeneralName `iPAddress` (que es lo que produce `subjectAltName = IP:10.20.30.41` — poner `DNS:10.20.30.41` en su lugar es un bug común que la mayoría de los clientes rechaza), y si tu intermedia lleva name constraints `excluded;IP` como en el Ejercicio 4, una SAN `IP:` será **rechazada** — tenés que ampliar la constraint para permitir la subred específica, p. ej. `permitted;IP:10.20.30.0/255.255.255.0`.

**A5.4** `-x509_strict` deshabilita los workarounds de compatibilidad que OpenSSL normalmente aplica y hace cumplir la RFC 5280 al pie de la letra. Concretamente rechaza, entre otros:
- un certificado de CA al que le falta `basicConstraints` por completo (de lo contrario OpenSSL recurriría a heurísticas para certificados antiquísimos);
- un certificado versión 1 o versión 2 usado como CA;
- un certificado de CA cuyo `keyUsage` omite `keyCertSign`;
- certificados a los que les falta `subjectKeyIdentifier`/`authorityKeyIdentifier` donde son requeridos;
- un certificado que no es de CA y que afirma `keyCertSign`.

Un ejemplo concreto: un certificado autofirmado legacy de un appliance emitido como X.509 v1 (y por lo tanto sin extensión alguna) verifica bien como su propio trust anchor bajo las reglas por defecto, pero falla con `-x509_strict` porque un certificado v1 no puede expresar `CA:TRUE`.

**A5.5** `-servername` completa la extensión TLS **SNI (Server Name Indication)** en el ClientHello (RFC 6066). El servidor la lee *antes* de elegir un certificado, que es lo que hace posible el hosting virtual sobre TLS en una única IP.

Si el cliente la omite, el servidor no tiene manera de saber qué virtual host se quiere en el momento de seleccionar el certificado y recurre a su bloque `server` **por defecto/primero**. El usuario entonces típicamente ve un certificado de un hostname no relacionado y un error de desajuste de nombre. Por eso `openssl s_client -connect host:443` sin `-servername` tantas veces devuelve "el certificado equivocado" en un balanceador de carga compartido — y por eso siempre deberías pasar ambos, o usar la forma abreviada `-connect host:443 -servername host`. Notá que SNI se envía en texto claro incluso en TLS 1.3 (en ausencia de Encrypted Client Hello), que es por lo que es un blanco habitual del filtrado a nivel de red.

---

### Bloque 6 — CRLs

**A6.1** `nextUpdate` es la promesa del emisor sobre cuándo estará disponible una CRL más nueva; **no** es un vencimiento de los hechos de revocación. La RFC 5280 §6.3.3 requiere que un cliente estricto trate una CRL pasada de `nextUpdate` como **no suficientemente fresca** y por lo tanto falle el chequeo de revocación, lo que bajo una política de hard-fail significa rechazar el certificado.

El compromiso es brutal y es por lo que las CRLs se temen operativamente: si tu punto de distribución de CRL se cae, o simplemente no se regenera una CRL según lo previsto, entonces al llegar `nextUpdate` **todos los certificados bajo esa CA dejan de validar de golpe** — una caída autoinfligida sin ningún atacante involucrado. Por eso `default_crl_days = 7` en una CA emisora necesita una tarea de regeneración corriendo mucho más seguido que semanalmente (diaria es lo típico), con monitoreo sobre la antigüedad del archivo publicado. La elección opuesta — soft-fail, ignorar una CRL vieja — restaura la disponibilidad pero vuelve inaplicable la revocación frente a cualquier atacante que pueda bloquear la descarga, que es la misma crítica que se le hace al OCSP soft-fail.

**A6.2**
- `-crl_check` — chequea la revocación **solo del certificado hoja** (profundidad 0).
- `-crl_check_all` — chequea **cada certificado de la cadena**, es decir, la hoja y cada CA por encima hasta el trust anchor sin incluirlo, y por lo tanto exige una CRL válida y vigente de cada CA emisora de la ruta.

El paso 7 falla con `error 3 at 1 depth` precisamente porque la CRL de la root — necesaria para probar que la *intermedia* no está revocada — todavía no había sido generada. `-crl_check_all` es la configuración correcta para una validación de alta garantía, pero multiplica tus obligaciones de disponibilidad de CRLs por la profundidad de la jerarquía.

**A6.3** 
- `keyCompromise` (razón 1) — se cree que la clave privada está en manos no autorizadas. Permanente, y la más seria; un validador debería tratar el certificado como inválido **desde el momento del compromiso**, no meramente desde la fecha de revocación.
- `cessationOfOperation` (razón 5) — el certificado simplemente ya no se usa (host dado de baja, dominio transferido). Permanente, pero sin implicancia de compromiso.
- `certificateHold` (razón 6) — una suspensión **temporal y reversible**, usada mientras se investiga un incidente.

`certificateHold` es la reversible. Se deshace **quitando la entrada de la CRL** y publicando una CRL nueva; el mecanismo es una delta-CRL o una entrada de CRL completa que lleva el código de razón `removeFromCRL` (8), que le dice a los clientes que tienen una CRL vieja que descarten el hold. En OpenSSL colocás el hold con `openssl ca -revoke <cert> -crl_reason certificateHold` y lo levantás con `openssl ca -valid <cert>`, que resetea la fila de `index.txt` de vuelta a `V`. Advertencia práctica: el soporte de `certificateHold` en clientes del mundo real es irregular, y el CA/Browser Forum lo prohíbe para certificados TLS de confianza pública — tratalo como una herramienta exclusivamente de PKI interna.

**A6.4** 
1. **Tamaño y crecimiento.** Una CRL es una única lista monolítica de todos los certificados revocados no vencidos bajo esa CA. A escala llega a los megabytes; cada cliente tiene que descargar la cosa entera para responder una pregunta de sí/no sobre un serial. El costo cae tanto sobre el ancho de banda de distribución de la CA como sobre cada cliente, incluidos los móviles y los enlaces medidos.
2. **Frescura versus carga, en conflicto directo.** La ventana de revocación está acotada por el intervalo de publicación de la CRL. Acortarlo a horas significa republicar un artefacto de varios megabytes esa hora, y que cada caché del mundo lo revalide — una estampida sincronizada contra la CDN. Alargarlo deja certificados comprometidos aceptados durante toda esa ventana. No hay ajuste que sea a la vez fresco y barato.

Mitigaciones con nombre propio, que vale conocer: **delta CRLs** (publicar solo los cambios respecto de una CRL base), **particionado de CRLs** vía múltiples `crlDistributionPoints` / **Issuing Distribution Points** de modo que cada certificado mapee a un shard chico, y la respuesta moderna de los navegadores — **listas agregadas propietarias distribuidas por push** (los CRLSets de Chrome, CRLite de Mozilla) que comprimen el conjunto de revocaciones globalmente relevante en algo distribuible con el navegador, esquivando por completo las descargas por conexión.

**A6.5** `crlDistributionPoints` con una URI `http://` está definido para servir una CRL **codificada en DER** (`application/pkix-crl`, RFC 5280 §4.2.1.13 y RFC 2585). La mayoría de los clientes — Windows/Schannel, macOS, Java, y el propio `X509_load_crl_file` de OpenSSL en modo DER — no aceptarán un cuerpo base64/PEM desde esa URI y reportarán la CRL como irrecuperable o malformada, produciendo `error 3: unable to get certificate CRL` y, bajo hard-fail, una caída. PEM es la forma cómoda local/de intercambio; DER es la forma de cable. La misma regla aplica a la URI `caIssuers` de AIA, que debe servir un certificado DER (`application/pkix-cert`) — publicar un PEM ahí es la razón más común de que el AIA chasing del navegador no logre reparar una cadena rota.

---

### Bloque 7 — OCSP y stapling

**A7.1** Sin ella: para confiar en una respuesta OCSP, el cliente debe validar el certificado del responder. Validar cualquier certificado incluye chequear si fue revocado. Chequear la revocación significa consultar OCSP. Consultar OCSP devuelve una respuesta firmada por el responder, cuyo certificado debe ser validado… — una recursión sin terminación, y en la práctica un deadlock, ya que el responder no puede responder una consulta sobre su propio estado sin ser confiado primero.

`id-pkix-ocsp-nocheck` (RFC 6960 §4.2.2.2.1) rompe el bucle: le indica al cliente que **omita por completo el chequeo de revocación para este certificado**. El argumento de seguridad son los controles compensatorios — esos certificados se emiten con vidas deliberadamente cortas (de días a unos pocos meses), así que un compromiso expira por sí solo en lugar de necesitar revocación. Notá el intercambio que esto hace explícito: una clave robada de firma OCSP con `nocheck` no puede revocarse de ninguna manera que los clientes respeten, así que el único remedio es esperar a que pase el período de validez o revocar la CA emisora. Por eso las claves de responder merecen protección con HSM y por eso la extensión se marca como no crítica pero el EKU `OCSPSigning` se marca como crítico.

**A7.2** El **nonce** es un valor aleatorio elegido por el cliente y colocado en la solicitud; un responder conforme lo devuelve en la respuesta firmada. Ata criptográficamente la respuesta a *esta* solicitud, derrotando el **replay**: sin él, un atacante que capturó una respuesta `good` firmada antes de un compromiso puede reservir esa respuesta indefinidamente (hasta `nextUpdate`) para suprimir la revocación, y la firma igual verifica.

Los responders públicos rechazan los nonces porque un nonce hace que cada respuesta sea **única y por lo tanto no cacheable**. Let's Encrypt, DigiCert y el resto sirven respuestas desde cachés de borde de CDN con validez de varios días, prefirmadas en lote; honrar nonces forzaría una operación de firma en línea por consulta a escala de internet — exactamente el perfil de carga que la infraestructura OCSP no puede sostener y que ha causado varias caídas notorias de responders. La RFC 8954 revisó la extensión de nonce en parte como respuesta a esta tensión. Así que en la web pública tenés una exposición a ventana de replay acotada por `nextUpdate`; en una PKI interna como la de este laboratorio podés y deberías mantener los nonces activos (sacá `-no_nonce`), porque tu volumen de consultas es trivial.

**A7.3** Con las **CRLs**, el cliente descarga una lista grande que cubre todos los certificados bajo la CA. La CA se entera de que algún cliente descargó la CRL, pero no de qué certificado le importaba a ese cliente — la lista es el conjunto de anonimato. El caché hace que la mayoría de las conexiones no generen descarga alguna.

Con **OCSP en vivo**, el cliente envía el número de serie específico que le interesa, por HTTP en texto plano, a un responder operado por la CA. La CA — y todo observador de red en el camino, ya que OCSP no está cifrado por diseño para poder ser cacheado — se entera de *qué sitio está visitando esta dirección IP, y cuándo*. Eso es un canal lateral del historial de navegación, en manos de un tercero con el que el usuario nunca eligió hablar. Fue uno de los argumentos más fuertes contra el OCSP obligatorio y una motivación directa tanto del stapling (la consulta se muda al servidor, que ya sabe que lo estás visitando) como del abandono del OCSP en vivo por parte de Chrome/Firefox en favor de listas agregadas distribuidas por push.

**A7.4** El stapling resuelve:
1. **Latencia y disponibilidad** — el cliente no hace ninguna conexión extra a un tercero, así que un responder lento o muerto ya no demora ni rompe los handshakes. El servidor descarga la respuesta según su propio cronograma y la cachea.
2. **Privacidad** — la CA ya no se entera de qué clientes visitan qué sitio; el servidor, que ya lo sabe, es el que pregunta.

**No** resuelve la **supresión**. Un `status_request` es una *solicitud* del cliente; un servidor que simplemente omite el mensaje `CertificateStatus` hace que el cliente caiga en soft-fail y acepte el certificado. Así que un atacante que tenga una clave robada puede simplemente negarse a hacer stapling, y la revocación se elude en silencio — el stapling tal como está desplegado es una optimización, no un mecanismo de aplicación.

El arreglo previsto era el flag **must-staple** de `status_request`: la extensión TLS Feature (RFC 7633), configurada con `tlsfeature = status_request` en el certificado, que le dice a los clientes que un staple faltante es fatal. La adopción es pobre y es operativamente peligroso — una sola falla de stapling en tu servidor hace fallar en duro cada conexión — así que sigue siendo raro. TLS 1.3 mejora la plomería (el estado se transporta dentro del mensaje `Certificate`, y el estado multi-certificado es nativo) pero no cambia el análisis de la supresión.

**A7.5** `ssl_trusted_certificate` le da a nginx la **cadena de emisores más la root** necesaria para verificar la *firma de la respuesta OCSP que recibió*. Antes de cachear y servir un staple a los clientes, nginx chequea que la respuesta haya sido firmada por una clave que legítimamente habla en nombre de la CA emisora — es decir, por la CA misma o por un certificado de responder delegado que lleve `OCSPSigning` y encadene a esa CA. Sin esto, nginx retransmitiría a ciegas lo que sea que devuelva la URI del responder.

No es el mismo archivo que `ssl_certificate` por dos razones. Primero, `ssl_certificate` en nginx debería contener **hoja + intermedias y ninguna root** (enviar la root desperdicia bytes en cada handshake y no agrega nada, ya que un cliente al que le falta la root no va a confiar en ella de todos modos); verificar una respuesta OCSP requiere que la cadena termine en un **trust anchor**, así que `ssl_trusted_certificate` debe *incluir* la root. Segundo, `ssl_trusted_certificate` nunca se envía a los clientes — es un almacén de verificación local — así que su contenido se elige por completitud de validación, no por economía de cable. En este laboratorio eso es `ca-chain.cert.pem` (intermedia + root), mientras que `ssl_certificate` es `web01-fullchain.pem` (hoja + intermedia).

---

### Bloque 8 — Formatos y almacenes de confianza

**A8.1** En Debian/Ubuntu, `update-ca-certificates` escanea `/usr/local/share/ca-certificates/` buscando archivos que coincidan **solo** con `*.crt`, y su contenido debe ser PEM. Una extensión `.pem` se omite en silencio — sin advertencia, y `update-ca-certificates` igual reporta éxito, lo que hace de esto una falla genuinamente confusa. Renombralo a `.crt` (el contenido no necesita cambiar; es PEM de cualquier manera). La familia RHEL es la imagen espejo: `/etc/pki/ca-trust/source/anchors/` acepta PEM o DER sin importar la extensión, y ejecutás `update-ca-trust extract`. Llevar un archivo `.pem` de un runbook de RHEL a un host Debian es exactamente cómo esto muerde.

**A8.2**
- **`-CAfile`** apunta a un único archivo que contiene uno o más certificados PEM concatenados. OpenSSL los carga todos en memoria al arrancar y busca linealmente. Simple, pero el bundle entero se parsea en cada arranque de proceso.
- **`-CApath`** apunta a un directorio en el que cada trust anchor se busca **bajo demanda** mediante un hash de su **nombre de subject**. OpenSSL computa el hash del subject del emisor que está buscando y abre `<hash>.0`, `<hash>.1`, … hasta encontrar una coincidencia. Esto escala a miles de anchors sin costo de parseo inicial — es como funciona `/etc/ssl/certs` en Debian.

`openssl rehash` (el reemplazo moderno del script Perl `c_rehash`) computa **`X509_NAME_hash()` del subject DN del certificado** — un SHA-1 truncado de la codificación DER canónica del nombre —, lo representa como 8 dígitos hexadecimales en minúscula, y crea un symlink `<hash>.<n>`, donde `<n>` desambigua múltiples certificados que comparten un subject (una CA y su gemela cross-signed, o una generación vieja y una nueva de la misma root). Dos trampas: tenés que volver a correr `rehash` después de agregar o quitar cualquier archivo, o las búsquedas fallan en silencio; y el algoritmo de hash cambió entre OpenSSL 0.9.8 y 1.0.0, así que los directorios de enlaces no son portables a través de esa frontera — `openssl rehash` regenera correctamente para la versión instalada.

**A8.3** `update-ca-trust extract` consume los anchors y emite varios artefactos bajo `/etc/pki/ca-trust/extracted/` porque distintos consumidores quieren cosas distintas:
- **`pem/tls-ca-bundle.pem`** y el symlink de compatibilidad `/etc/pki/tls/certs/ca-bundle.crt` — un bundle PEM concatenado para OpenSSL, curl, Python, y cualquier cosa que tome un `-CAfile`.
- **`openssl/ca-bundle.trust.crt`** — el formato *extendido* BEGIN TRUSTED CERTIFICATE, que lleva flags de **propósito de confianza** por certificado (este anchor es confiable para servidores TLS pero no para correo, este otro está explícitamente desconfiado). Un bundle PEM plano no puede expresar eso; es todo o nada por certificado.
- **`java/cacerts`** — un keystore JKS/PKCS#12, porque la JVM no lee bundles PEM.
- **`edk2/cacerts.bin`** — para consumidores UEFI/firmware.
- La **base de datos compartida de NSS** que consumen Firefox/Thunderbird vía `p11-kit`.

El punto de diseño es que `p11-kit` es la única fuente de verdad y los formatos extraídos son vistas generadas; editás anchors, nunca los archivos extraídos, que se sobrescriben en cada ejecución. La capacidad de flags de confianza es también por lo que RHEL puede *desconfiar* de un certificado (`/etc/pki/ca-trust/source/blocklist/`) en lugar de solamente agregar confianza.

**A8.4** Defienden contra adversarios distintos:
- El **cifrado derivado de la passphrase** (PBES2/PBKDF2 sobre el `shroudedKeyBag`) protege la **confidencialidad de la clave privada** frente a cualquiera que obtenga el archivo — de una cinta de backup, un bucket S3, un adjunto de correo. Sin la passphrase, el material de la clave es texto cifrado.
- El **MAC** (un HMAC sobre todo el `AuthenticatedSafe` de PKCS#12, con clave derivada de la misma passphrase) protege la **integridad y autenticidad del contenedor en su conjunto** — incluidos los *certificados*, que frecuentemente se almacenan sin cifrar en el archivo. Sin él, un atacante podría sustituir o agregar un certificado en el bundle — por ejemplo, inyectando un certificado de CA malicioso en la bolsa `-cacerts` en la que el sistema importador después confía — sin tocar en absoluto la clave cifrada.

Notá la debilidad compartida: ambos se derivan de una única passphrase mediante un KDF cuyo conteo de iteraciones (`2048` en la salida de arriba) es bajo para los estándares modernos. Para cualquier cosa de larga vida, subilo con `-iter` / `-macsaltlen` y elegí una passphrase de alta entropía; PKCS#12 es un formato de transporte, no una bóveda.

**A8.5** OpenSSL 3.0 movió los algoritmos viejos y débiles — RC2-40, RC2-128, DES, y los esquemas PBE basados en SHA-1 de PKCS#12 v1 — al **provider legacy**, que no se carga por defecto. En consecuencia `openssl pkcs12 -export` ahora usa por defecto PBES2 moderno (AES-256-CBC, PBKDF2-HMAC-SHA256) y un MAC SHA-256. Los appliances, Java 8 y anteriores, y los importadores viejos de Windows frecuentemente entienden solo el cifrado legacy `pbeWithSHA1And3-KeyTripleDES-CBC` y un MAC SHA-1, y rechazan el archivo moderno con "unsupported algorithm" o un error de parseo escueto.

Arreglo mínimo — reexportar con la codificación vieja:

```bash
openssl pkcs12 -export -legacy \
  -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 \
  -inkey private/web01.key.pem -in certs/web01.cert.pem \
  -certfile certs/ca-chain.cert.pem -out certs/web01-legacy.p12
```

`-legacy` activa el provider legacy (debe estar presente como `legacy.so` en `MODULESDIR`; en algunas imágenes mínimas es un paquete separado). Si solo necesitás degradar el *MAC*, `-macalg sha1` por sí solo suele alcanzar, ya que Java 8u301+ maneja PBES2 pero la verificación de MAC más vieja es más estricta. Tratá esto como un parche de compatibilidad con un ticket de deprecación adjunto, no como una configuración permanente — 3DES y SHA-1 están ahí porque el otro extremo es obsoleto.

---

### Bloque 9 — ACME y Let's Encrypt

**A9.1**
- **Seguridad.** La revocación no funciona de manera confiable — las CRLs están vencidas o no se descargan, OCSP es soft-fail y suprimible, y los navegadores se replegaron en gran medida a listas agregadas por push con cobertura limitada. Por lo tanto, una vida corta es el único mecanismo de revocación que está garantizado que surta efecto: una clave comprometida que no puede revocarse en la práctica igualmente resulta inútil en a lo sumo 90 días. El mismo argumento acota el daño de una emisión errónea y del cambio de dueño de un dominio después de la validación.
- **Operativo.** Una vida de 90 días vuelve insostenible la renovación manual, lo que **fuerza la automatización** — y la automatización es el punto. Las renovaciones anuales las hace una persona que se olvidó del procedimiento, a las 3 de la mañana, durante la caída que causó el vencimiento; una renovación que corre dos veces por día se ejercita continuamente y falla de forma visible cuando todavía queda un mes de margen. El proyecto lo ha dicho explícitamente: las vidas cortas son una función forzante para tener herramientas correctas.

La industria continuó en esa dirección — el CA/Browser Forum votó reducir las vidas máximas de los certificados TLS en etapas hasta 47 días para 2029 — así que la premisa de la automatización se está volviendo universal en lugar de específica de Let's Encrypt.

**A9.2** Tenés que usar **`dns-01`**. La razón es estructural: `http-01` prueba el control de un *hostname específico* sirviendo un token en `http://<ese-host-exacto>/.well-known/acme-challenge/<token>`. Un wildcard `*.internal.example.com` afirma autoridad sobre un **conjunto no acotado** de hostnames, y no existe un único endpoint HTTP cuyo control pudiera demostrar eso — la CA tendría que enumerar infinitos nombres. `dns-01` en cambio prueba el control de la **zona DNS** colocando un registro TXT en `_acme-challenge.internal.example.com`, y el control de la zona *es* precisamente la autoridad para crear cualquier nombre por debajo de ella. `tls-alpn-01` falla por la misma razón que `http-01`. Para nombres internos hay un segundo bloqueo independiente: ninguna CA de confianza pública puede emitir para un espacio de nombres no público en absoluto, así que `internal.example.com` necesita tu propia CA ACME (step-ca, Boulder, Pebble) o la PKI privada de los Ejercicios 3–5.

**A9.3**
- **`--pre-hook`** — corre **antes** de cada intento de renovación, una vez por invocación de certbot que tenga trabajo por hacer. Usalo para liberar el puerto 80 para el plugin `standalone` (`systemctl stop nginx`).
- **`--post-hook`** — corre **después** del intento, una vez por invocación, **haya o no** habido renovación. Usalo para deshacer el pre-hook (`systemctl start nginx`).
- **`--deploy-hook`** — corre **solo cuando un certificado efectivamente se renovó**, una vez **por certificado renovado**, con `$RENEWED_LINEAGE` y `$RENEWED_DOMAINS` seteados en el entorno.

Tu `systemctl reload nginx` va en **`--deploy-hook`**. Ponerlo en `--post-hook` significa recargar el servidor web dos veces por día para siempre sin razón (y enmascarar un cambio de configuración roto en un momento impredecible); ponerlo en `--pre-hook` recarga *antes* de que existan los archivos nuevos, así que el servidor sigue sirviendo el certificado viejo hasta que otra cosa lo reinicie — el clásico incidente de "certbot dice renovado, los navegadores siguen mostrando el certificado vencido". Los hooks registrados en el momento de la emisión se persisten en `renewalparams` (como `renew_hook`) y son reproducidos por `certbot renew`, que es por lo que vale la pena leer el archivo de configuración del paso 8.

**A9.4** `certbot renew` escribe el certificado nuevo en `archive/` como `certN+1.pem` y **reapunta los symlinks de `live/`**. La ruta `/etc/letsencrypt/live/example.com/fullchain.pem` por lo tanto siempre resuelve al certificado actual, y nginx — que resuelve el symlink al recargar — lo toma.

Si la gestión de configuración **copia el contenido del archivo** a `/etc/nginx/ssl/fullchain.pem` en el momento de la instalación, esa copia es una instantánea congelada. La renovación actualiza el destino del symlink, la copia queda intacta, y el servidor sigue sirviendo el certificado viejo hasta que vence — mientras `certbot certificates` reporta alegremente un certificado fresco con 89 días restantes, y tu monitoreo de `notAfter` (si lee `live/`) coincide. Es una divergencia silenciosa que aflora como una caída de producción el día del vencimiento, con todos los diagnósticos apuntando a "renovado exitosamente".

Los arreglos, en orden de preferencia: referenciar las rutas de `live/` directamente en la configuración del servidor (son estables por diseño — ese es el propósito entero de la indirección de `live/`); o, si la copia es inevitable, hacer la copia en un `--deploy-hook` para que se rehaga en cada renovación y sea seguida por la recarga. Nunca hagas `cp -L` una sola vez en el aprovisionamiento. Una trampa relacionada: `live/` y `archive/` son propiedad de root y con permisos restringidos, así que un servicio que no corre como root y necesita leer `privkey.pem` necesita un deploy-hook que copie y reasigne permisos, no un aflojamiento de permisos sobre `/etc/letsencrypt`.

**A9.5** **No.** Un wildcard coincide con **exactamente una etiqueta**, y solo en la posición más a la izquierda. `*.example.com` coincide con `a.example.com` y `www.example.com`, pero no con `a.b.example.com` (dos etiquetas debajo del wildcard) ni con el `example.com` pelado (cero etiquetas — que es por lo que el comando de certbot del paso 9 solicita `-d '*.example.com' -d example.com` explícitamente).

Las reglas precisas de la RFC 6125 §6.4.3 y de los Baseline Requirements del CA/Browser Forum: el carácter wildcard debe ser la **etiqueta completa más a la izquierda** (`*.example.com` es válido; las formas de etiqueta parcial como `w*.example.com` alguna vez fueron permitidas y hoy son rechazadas por los navegadores), puede aparecer **solo** en esa posición (`a.*.example.com` es inválido), nunca coincide con un punto, y no puede colocarse de modo que abarque un sufijo público (`*.com`, `*.co.uk`). Para cubrir `a.b.example.com` necesitás o bien una SAN explícita para él, o un segundo wildcard `*.b.example.com`.

---

### Bloque 10 — Diagnóstico

**A10.1**
- **Error 20, `unable to get local issuer certificate`** — reportado por `openssl verify` operando sobre archivos, en profundidad 0: el emisor de la hoja no está ni en el almacén de confianza ni en el conjunto `-untrusted`.
- **Error 21, `unable to verify the first certificate`** — reportado por `openssl s_client` y por los clientes TLS en general: el *primer* certificado de la cadena que envió el par (la hoja) no pudo verificarse porque la cadena se corta ahí.

Ambos describen la misma condición subyacente desde puntos de vista distintos — verificación basada en archivos versus un handshake en vivo. El único arreglo del lado del servidor es **servir la cadena completa**: concatenar hoja + intermedia(s) (root opcional y normalmente omitida) y apuntar `ssl_certificate` (nginx) o `SSLCertificateFile` (httpd ≥ 2.4.8) a ese archivo — `fullchain.pem`, no `cert.pem`.

**A10.2**
- **Error 18, `self-signed certificate`** — el certificado que se está verificando *es en sí mismo* el autofirmado en profundidad 0; no hay cadena alguna. Típico de un appliance o un certificado de prueba hecho con `req -x509` presentado directamente, sin el anchor correspondiente instalado.
- **Error 19, `self-signed certificate in certificate chain`** — se construyó una cadena genuina de múltiples niveles y terminó en una root autofirmada **que no está en el almacén de confianza**. La jerarquía está bien; el anchor simplemente no es confiable acá. Esto es lo que obtenés de una PKI privada correctamente construida antes de que se haya corrido `update-ca-trust` en el cliente — exactamente el paso 5 del Ejercicio 8.

**A10.3** Chrome implementa **AIA chasing**: al encontrarse con una cadena que no puede completar, lee la extensión `authorityInfoAccess` de la hoja, descarga el certificado del emisor codificado en DER desde la URI `caIssuers`, y repara la cadena por su cuenta. Safari, Windows/Schannel y macOS hacen lo mismo. `curl`/OpenSSL, Go, Java y el módulo `ssl` de Python deliberadamente **no** — no se espera que un cliente TLS haga solicitudes HTTP salientes en medio del handshake, y hacerlo sería un costo de latencia y privacidad en cada conexión. Así que el navegador enmascara una mala configuración del servidor con la que tropieza cada cliente automatizado: monitoreo, CI, webhooks y SDKs móviles fallan mientras el navegador del operador muestra un candado verde.

El arreglo **del lado del servidor** es enviar la(s) intermedia(s): construir `fullchain.pem` y referenciarlo. Verificá desde la perspectiva del propio servidor con

```bash
openssl s_client -connect host:443 -servername host -showcerts </dev/null 2>/dev/null | grep -c 'BEGIN CERTIFICATE'
```

que debe devolver al menos 2 para una cadena pública normal. Los workarounds del lado del cliente con `-CAfile`/`--cacert` ocultan el defecto en lugar de arreglarlo.

**A10.4** Dos mecanismos, ambos comunes:
1. **El chequeo leyó el archivo equivocado.** Parseó `notAfter` de un certificado renovado en disco (`/etc/letsencrypt/live/...`) mientras el servidor en ejecución todavía tiene el certificado **viejo** en memoria, porque nada lo recargó — el `--deploy-hook` faltante de A9.3, o el problema de la copia congelada de A9.4. El arreglo es monitorear el certificado **tal como se sirve**, por la red: `openssl s_client -connect host:443 -servername host | openssl x509 -noout -enddate`, no un archivo en disco.
2. **Expiró una intermedia o una root, no la hoja.** `openssl verify` reporta el error 10 para *cualquier* profundidad, y la línea de diagnóstico nombra al certificado culpable — leé el `notAfter=` que acompaña al error. El precedente de la industria es el vencimiento en 2021 del cross-sign de DST Root CA X3, que rompió incontables clientes cuyos certificados hoja estaban perfectamente vigentes. Un chequeo de monitoreo que inspecciona solo la profundidad 0 es ciego a esto; chequeá la cadena entera.

Una tercera variante, menos común, que vale nombrar: **desfase de reloj del lado del cliente** (un dispositivo sin RTC o con la sincronización NTP fallada) hace que un certificado válido parezca vencido o aún no válido solo en ese cliente — ver A10.5.

**A10.5** `-attime <unix-epoch>` le dice al verificador que evalúe **todos los chequeos dependientes del tiempo** — `notBefore`/`notAfter` del certificado, `lastUpdate`/`nextUpdate` de la CRL, frescura de la respuesta OCSP — como si la hora actual fuera ese valor. Su alcance es la única invocación de `openssl`.

Es más confiable que cambiar el reloj del sistema porque mover el reloj del host es una acción **global y con efectos secundarios**: va a pelearse con NTP (que puede retrocederlo en medio de la prueba, produciendo resultados irreproducibles), corrompe timestamps de logs y mtimes de archivos, puede romper tickets Kerberos, TOTP, sesiones TLS y replicación de bases de datos en ese host, y en un sistema compartido o en contenedores afecta a procesos que no tienen nada que ver con tu prueba. `-attime` es determinista, reproducible, no requiere privilegios, es seguro en una máquina de producción, y es trivialmente automatizable a lo largo de muchos timestamps — por ejemplo, para encontrar la fecha exacta en la que una cadena va a empezar a fallar:

```bash
for d in '+29 days' '+60 days' '+91 days'; do
  printf '%s: ' "$d"
  openssl verify -CAfile root-ca.cert.pem -untrusted int-ca.cert.pem \
    -attime "$(date -d "$d" +%s)" web01.cert.pem 2>&1 | tail -1
done
```

El equivalente en `s_client` es también `-attime` (acepta las mismas opciones de verificación), así que podés ensayar un handshake con fecha futura contra un servidor en vivo sin tocar el reloj de ninguna de las dos máquinas.

</details>