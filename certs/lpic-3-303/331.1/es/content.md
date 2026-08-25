# 331.1 — Certificados X.509 e infraestructuras de clave pública

**LPIC-3 303 (Security), examen 303-300 v3.0.0 — Tema 331 Criptografía · Peso 8.34**

---

## 1. El problema arquitectónico

Todo sistema distribuido termina, tarde o temprano, teniendo que responder una pregunta en el momento de la conexión: *¿el proceso que está del otro lado de este socket es el que yo pretendía?* Los secretos simétricos no escalan a esa pregunta — `n` servicios que se autentican mutuamente necesitan `n(n-1)/2` claves precompartidas, y cada rotación es un evento de coordinación O(n²). X.509 lo resuelve reemplazando la malla de secretos compartidos por un **árbol de aserciones delegadas**: una cantidad pequeña de anclas de confianza, cada una capaz de responder por una cantidad ilimitada de identidades, y cada acto de respaldo reducido a una estructura de datos firmada y verificable offline.

Ese intercambio — la malla colapsa en un árbol — es toda la razón de existir de X.509, y también es donde vive el dolor operativo:

| Propiedad ganada | Costo incurrido |
|---|---|
| La verificación es offline: ninguna llamada de red a un tercero en el momento del handshake | Las aserciones no se pueden "des-decir". La revocación es un agregado, y es la parte más débil del sistema. |
| Un ancla autentica millones de endpoints | Un ancla comprometida falsifica millones de endpoints. El radio de daño es todo el espacio de nombres. |
| La identidad se ata a una clave pública, no a una ubicación de red | La atadura tiene fecha de vencimiento. Cada certificado es una caída programada salvo que la renovación esté automatizada. |
| La confianza es transitiva a través de intermedios | El verificador debe reconstruir un camino. Las fallas de construcción de cadena son la clase de incidente de TLS más común. |

En producción los modos de falla se agrupan en cuatro categorías, y este material está organizado alrededor de eliminar cada una:

1. **Vencimiento.** Un certificado no renovado es una caída total, simultánea y correlacionada de todos los clientes. Es el único modo de falla 100% predecible de antemano y aun así tira abajo grandes plataformas de manera rutinaria.
2. **Construcción del camino.** El servidor omite un intermedio; el cliente tiene un almacén de confianza distinto al de la laptop del desarrollador; una raíz con firma cruzada vence y un verificador ingenuo sigue la rama muerta.
3. **Sobre-emisión.** Una sub-CA entregada a un equipo puede acuñar `*.anything` si no está restringida. Un CSR se toma al pie de la letra y trae `CA:TRUE`.
4. **Revocación que no revoca.** Una CRL que nadie descarga, un respondedor OCSP que nadie puede alcanzar, un cliente en soft-fail que trata "respondedor caído" como "certificado bien".

La respuesta de ingeniería a las cuatro tiene la misma forma: **vidas cortas, emisión automatizada, alcance impuesto criptográficamente, y verificación que realmente ejecutás en CI.** Certificados de larga vida más renovación manual más revocación-como-red-de-seguridad es el antipatrón; y también es como se ven la mayoría de los parques brownfield.

---

## 2. Anatomía de un certificado X.509v3

Un certificado es un `SEQUENCE` de ASN.1 definido por RFC 5280, codificado en DER, y usualmente envuelto en Base64 con la armadura PEM. Tres campos de nivel superior:

```
Certificate  ::=  SEQUENCE  {
     tbsCertificate       TBSCertificate,      -- everything that is signed
     signatureAlgorithm   AlgorithmIdentifier, -- repeated here, MUST match the inner one
     signatureValue       BIT STRING           -- issuer's signature over DER(tbsCertificate)
}
```

Que el `signatureAlgorithm` aparezca dos veces no es redundancia porque sí: la copia externa no está autenticada y existe solo para que un parser pueda elegir un verificador antes de parsear; RFC 5280 §4.1.1.2 exige que el verificador compruebe que sea igual a la copia interna firmada. Un verificador que confía solo en la copia externa es vulnerable a juegos de sustitución de algoritmo.

### 2.1 Campos de `TBSCertificate`

| Campo | Notas para producción |
|---|---|
| `version` | `2` en el cable significa v3. Cualquier cosa menor no tiene extensiones y debe rechazarse para TLS. |
| `serialNumber` | INTEGER positivo, ≤20 octetos. Los Baseline Requirements del CA/Browser Forum exigen ≥64 bits de entropía de CSPRNG — esto es una defensa contra colisiones de hash de prefijo elegido, no un contador. `openssl ca` lo obtiene de `rand_serial = yes`. |
| `signature` | Identificador de algoritmo interno y firmado. |
| `issuer` | DN de la CA firmante. Debe ser idéntico byte a byte al `subject` del emisor para construir el camino por nombre. |
| `validity` | `notBefore`/`notAfter`. UTCTime hasta 2049, GeneralizedTime después. `notAfter = 99991231235959Z` es la codificación de RFC 5280 para "sin vencimiento bien definido" — legal, y una señal de alerta en una hoja TLS. |
| `subject` | Puede estar vacío (`SEQUENCE {}`) **solo** si `subjectAltName` está presente y marcada como crítica. |
| `subjectPublicKeyInfo` | `AlgorithmIdentifier` + `BIT STRING`. Este es el objeto que hasheás para el pinning de SPKI. |
| `issuerUniqueID` / `subjectUniqueID` | Reliquias de v2. RFC 5280 dice no generarlos. |
| `extensions` | v3. Donde vive toda la política real. |

### 2.2 Las extensiones que deciden el comportamiento

| Extensión | OID | ¿Crítica? | Qué controla realmente |
|---|---|---|---|
| `basicConstraints` | 2.5.29.19 | DEBE ser crítica en un certificado de CA | `CA:TRUE/FALSE` y `pathlen`. `pathlen:0` = puede firmar hojas, no puede firmar más CAs. Una hoja con `CA:TRUE` es una sub-CA. |
| `keyUsage` | 2.5.29.15 | DEBERÍA ser crítica | Operaciones criptográficas permitidas. `keyCertSign` es lo que hace que una CA sea una CA en la práctica; una cadena donde un intermedio no lo tiene falla con error 35. |
| `extendedKeyUsage` | 2.5.29.37 | Opcional | `serverAuth` (1.3.6.1.5.5.7.3.1), `clientAuth` (.2), `codeSigning` (.3), `emailProtection` (.4), `timeStamping` (.8), `OCSPSigning` (.9). EKU en un certificado de CA *restringe* lo que sus descendientes pueden afirmar — esto es "encadenamiento de EKU", respetado por OpenSSL, NSS y Windows. |
| `subjectAltName` | 2.5.29.17 | Crítica solo si el subject está vacío | La **única** fuente de identidad para la coincidencia de nombre de host en TLS. `dNSName`, `iPAddress`, `rfc822Name`, `URI`, `otherName` (SPIFFE IDs, UPNs). |
| `subjectKeyIdentifier` | 2.5.29.14 | No crítica | Hash del SPKI. Pista para construir la cadena. |
| `authorityKeyIdentifier` | 2.5.29.35 | No crítica | Apunta al SKI del emisor. Permite que un verificador elija el emisor correcto cuando una CA se re-encaró con el mismo DN. |
| `crlDistributionPoints` | 2.5.29.31 | No crítica | Dónde vive la CRL. Debe ser HTTP, nunca HTTPS (problema del huevo y la gallina). |
| `authorityInfoAccess` | 1.3.6.1.5.5.7.1.1 | No crítica | URI del respondedor `OCSP` + URI `caIssuers` para el seguimiento de AIA. |
| `nameConstraints` | 2.5.29.30 | DEBE ser crítica | Restringe el espacio de nombres en el que una sub-CA puede emitir. El control más valioso al delegar una CA. |
| `certificatePolicies` | 2.5.29.32 | No crítica | OIDs de política; `anyPolicy` = 2.5.29.32.0. |
| `ct_precert_scts` | 1.3.6.1.4.1.11129.2.4.2 | No crítica | Signed Certificate Timestamps embebidos. |
| `ct_precert_poison` | 1.3.6.1.4.1.11129.2.4.3 | DEBE ser crítica | Marca un precertificado. Su criticidad es lo que hace que los precerts sean inutilizables como certificados reales. |
| `noCheck` | 1.3.6.1.5.5.7.48.1.5 | No crítica | En un firmante OCSP: "no revises mi estado de revocación". |

**La criticidad es el mecanismo de aplicación.** RFC 5280 §4.2 exige que un verificador *rechace* un certificado que contenga una extensión crítica que no entiende. Por eso `nameConstraints` debe ser crítica — un cliente que no puede aplicarla debe rechazar el certificado en lugar de ignorar silenciosamente la restricción.

### 2.3 Codificaciones y formatos de contenedor

| Nombre | Extensión | Contenido | Cuándo lo usás |
|---|---|---|---|
| DER | `.der` `.cer` `.crt` | ASN.1 binario crudo | Keystores de Java, Windows, embebidos, cualquier cosa que hashee el certificado |
| PEM | `.pem` `.crt` `.key` | DER en Base64 + `-----BEGIN X-----` | Todo en Linux |
| PKCS#1 | `.pem` | `BEGIN RSA PRIVATE KEY` | Clave privada heredada, solo RSA |
| PKCS#8 | `.pem` `.key` | `BEGIN PRIVATE KEY` / `BEGIN ENCRYPTED PRIVATE KEY` | Clave privada moderna, agnóstica del algoritmo. Salida por defecto de `openssl genpkey`. |
| PKCS#10 | `.csr` `.req` | `BEGIN CERTIFICATE REQUEST` | CSR |
| PKCS#7 / CMS | `.p7b` `.p7c` | Certificados + CRLs, **sin clave privada** | Distribución de cadena a Windows/Java |
| PKCS#12 / PFX | `.p12` `.pfx` | Clave + certificado + cadena, protegido con contraseña | Entregar una identidad completa a Java, .NET, navegadores |
| PKCS#11 | — | *API*, no un archivo | Acceso a HSM / smartcard / TPM |
| JKS / BCFKS | `.jks` | Keystore nativo de Java | JVM heredada. Preferí PKCS#12 (el default de `keytool` desde Java 9). |

Memorizá los números de PKCS — el examen los pide directamente, y confundir #7 (cadena, sin clave) con #12 (clave incluida) es un error real de clasificación de datos.

```
$ openssl asn1parse -i -in tls-ca.crt.pem | head -24
    0:d=0  hl=4 l= 802 cons: SEQUENCE
    4:d=1  hl=4 l= 722 cons:  SEQUENCE
    8:d=2  hl=2 l=   3 cons:   cont [ 0 ]
   10:d=3  hl=2 l=   1 prim:    INTEGER           :02
   13:d=2  hl=2 l=  16 prim:   INTEGER           :5C7A1E93B0F4462D8AA1C3557E9D0B41
   31:d=2  hl=2 l=  10 cons:   SEQUENCE
   33:d=3  hl=2 l=   8 prim:    OBJECT            :ecdsa-with-SHA384
   43:d=2  hl=2 l=  90 cons:   SEQUENCE
   45:d=3  hl=2 l=  11 cons:    SET
   47:d=4  hl=2 l=   9 cons:     SEQUENCE
   49:d=5  hl=2 l=   3 prim:      OBJECT            :countryName
   54:d=5  hl=2 l=   2 prim:      PRINTABLESTRING   :AR
...
```

`asn1parse` es la herramienta de último recurso cuando un certificado no parsea en absoluto — te muestra dónde el DER deja de tener sentido.

---

## 3. Material de clave: eligiendo el algoritmo

La clave es la identidad. Todo lo demás son metadatos sobre ella.

| Algoritmo | Nivel de seg. | Clave pública | Firma | Costo de firma para la CA | Costo de verificación | Dónde es seguro usarlo |
|---|---|---|---|---|---|---|
| RSA-2048 | ~112 bits | 294 B | 256 B | alto | **muy bajo** | Piso universal. Ideal cuando los verificadores superan ampliamente a los firmantes (CAs raíz, firma de código). |
| RSA-3072 | ~128 bits | 422 B | 384 B | muy alto | bajo | Piso de 128 bits impulsado por cumplimiento sin abandonar RSA. |
| RSA-4096 | ~140 bits | 550 B | 512 B | castigador | bajo | Solo raíces offline. En una hoja TLS no aporta casi nada y cuesta CPU de handshake en cada conexión. |
| ECDSA P-256 | ~128 bits | 91 B | ~71 B | **muy bajo** | bajo | Default para hojas TLS y CAs emisoras. Handshakes ~4× más baratos que RSA-2048 a escala. |
| ECDSA P-384 | ~192 bits | 120 B | ~103 B | bajo | moderado | Raíces e intermedios de larga vida; alineación con FIPS/CNSA. |
| Ed25519 | ~128 bits | 44 B | 64 B | muy bajo | muy bajo | PKI interna, CAs de SSH, service mesh. **No** emitible por CAs públicas de la WebPKI; en la práctica solo TLS 1.3. |

Guía práctica para un parque de plataforma:

- **Raíz: ECDSA P-384, vida de 20 años, offline, en un HSM.** El costo de verificación se paga una vez por cadena y solo en la construcción de camino en frío.
- **CA emisora: ECDSA P-384 o P-256, vida de 10 años, online, respaldada por HSM.**
- **Hoja: ECDSA P-256, ≤90 días, automatizada.**
- **Mantené una jerarquía RSA-2048 en paralelo solo si tenés clientes heredados comprobados** (Java 7, Android viejo, appliances embebidos). No lo hagas "por las dudas" — una jerarquía dual duplica cada procedimiento operativo.

ECDSA arrastra un peligro que RSA no tiene: **la reutilización del nonce es catastrófica**. Dos firmas producidas con el mismo `k` bajo la misma clave filtran la clave privada por álgebra simple. OpenSSL 3.x usa derivación de nonce determinista-más-aleatoria al estilo RFC 6979, pero cualquier firmante ECDSA casero o embebido es un pasivo. Ed25519 es determinista por construcción e inmune a esta clase.

```bash
# Root key — P-384, encrypted at rest with AES-256, 0400 on a tmpfs during the ceremony
$ openssl genpkey -algorithm EC \
    -pkeyopt ec_paramgen_curve:P-384 \
    -pkeyopt ec_param_enc:named_curve \
    -aes-256-cbc \
    -out /opt/pki/root/ca/private/root-ca.key.pem
Enter PEM pass phrase:
Verifying - Enter PEM pass phrase:

$ chmod 0400 /opt/pki/root/ca/private/root-ca.key.pem

$ openssl pkey -in /opt/pki/root/ca/private/root-ca.key.pem -noout -text_pub
Enter pass phrase for /opt/pki/root/ca/private/root-ca.key.pem:
ED-Public-Key: (384 bit)
pub:
    04:8f:2a:c1:0d:74:9b:33:e0:51:a2:6c:88:d9:14:
    7b:33:0e:c2:59:aa:41:6f:d0:82:b7:3c:95:1e:44:
    ...
ASN1 OID: secp384r1
NIST CURVE: P-384
```

`ec_param_enc:named_curve` importa. La alternativa, `explicit`, embebe los parámetros completos de la curva en cada certificado — infla el certificado, y varios stacks (`crypto/x509` de Go, Java) rechazan de plano las claves EC con parámetros explícitos.

Nunca dejes una clave privada sin cifrar en disco fuera de una ruta de ejecución controlada. Donde la clave *deba* ser legible por un daemon en el arranque, la respuesta son permisos de sistema de archivos más un TPM/HSM, no una passphrase que el operador tipea a las 03:00.

---

## 4. Topología de PKI: cuántos niveles, y por qué

| Topología | Exposición de la raíz | Radio de daño de un compromiso de la CA online | Recuperación | Encaje |
|---|---|---|---|---|
| **Un solo nivel** (la raíz firma hojas directamente) | Clave raíz online, permanentemente | Total. Todos los clientes deben reconstruir su almacén de confianza. | Reconstruir todo el parque. | Labs, clusters descartables, un solo nodo. Nunca producción. |
| **Dos niveles** (raíz offline → CA emisora online) | Raíz offline, encendida solo para ceremonias | Acotado: revocar el intermedio vía la CRL de la raíz, emitir un nuevo intermedio, re-emitir las hojas. Almacén de confianza intacto. | Horas o días, sin cambios en el cliente. | **El default.** La respuesta correcta para ~95% de las plataformas. |
| **Tres niveles** (raíz → CA de política → CAs emisoras) | Raíz offline; CA de política offline | Acotado por CA emisora. La CA de política expresa políticas de certificado / restricciones de nombre distintas por unidad de negocio. | Igual que dos niveles, con alcance más estrecho. | PKI multi-inquilino, entornos regulados, federación entre organizaciones. |
| **Firma cruzada / puente** | Múltiples anclas | Depende del grafo | Complejo — los verificadores pueden construir caminos distintos | Fusiones, rotación de raíz, ventanas de compatibilidad con la WebPKI. |

La economía de dos niveles: la clave privada de la raíz toca una máquina encendida y conectada a la red del orden de una vez por década. La CA emisora está expuesta continuamente, así que asumís que eventualmente será comprometida y diseñás el camino de recuperación de antemano. Ese camino de recuperación — "revocar el intermedio, acuñar uno nuevo desde la raíz offline, re-emitir cada hoja" — debería ser un runbook ensayado con un RTO medido, no una teoría.

**Las restricciones de nombre convierten la delegación de una decisión de confianza en una decisión criptográfica.** Si le entregás una sub-CA a otro equipo, `nameConstraints` es lo que impide que ellos (o su atacante) acuñen `login.yourbank.com`. RFC 5280 exige que sea crítica, así que un verificador conforme que no puede aplicarla rechaza la cadena.

La brecha clásica: **un tipo de nombre ausente de `permittedSubtrees` queda sin restricción.** Restringir `DNS` no hace nada respecto de `iPAddress`, `rfc822Name`, `URI` o `directoryName`. Si una sub-CA nunca debe emitir SANs de IP, tenés que excluir explícitamente todo el espacio IPv4 e IPv6.

---

## 5. Construyendo una CA de dos niveles con OpenSSL — configuración completa

### 5.1 Disposición de directorios

```bash
$ install -d -m 0755 /opt/pki/root/{certs,crl,newcerts,db,ca}
$ install -d -m 0700 /opt/pki/root/ca/private
$ install -d -m 0755 /opt/pki/tls-ca/{certs,crl,newcerts,db,ca}
$ install -d -m 0700 /opt/pki/tls-ca/ca/private

$ for d in /opt/pki/root /opt/pki/tls-ca; do
    : > $d/db/index.txt
    printf 'unique_subject = no\n' > $d/db/index.txt.attr
    printf '1000\n' > $d/db/crlnumber
    openssl rand -hex 16 > $d/db/serial
  done

$ cat /opt/pki/root/db/serial
5c7a1e93b0f4462d8aa1c3557e9d0b41
```

`index.txt.attr` con `unique_subject = no` no es opcional en ningún entorno donde re-emitas para el mismo subject. Si lo omitís, `openssl ca` lo crea con `unique_subject = yes`, y tu segunda emisión para `api.internal.example.io` falla con `TXT_DB error number 2`.

### 5.2 `/opt/pki/root/openssl-root.cnf` — completo

```ini
# =====================================================================
# Offline Root CA — Example Platform Engineering
# OpenSSL 3.x.  Used ONLY to sign intermediate CAs, CRLs and the OCSP
# signer for the intermediate tier.  Never signs an end-entity cert.
# =====================================================================

[ default ]
ca_name                 = root-ca
pki_base_url            = http://pki.example.io
name_opt                = utf8,esc_ctrl,multiline,lname,align
cert_opt                = ca_default

# ---------------------------------------------------------------- req
[ req ]
default_bits            = 4096
default_md              = sha384
string_mask             = utf8only
utf8                    = yes
prompt                  = no
distinguished_name      = root_ca_dn
x509_extensions         = v3_root_ca

[ root_ca_dn ]
countryName             = AR
organizationName        = Example Platform Engineering
organizationalUnitName  = Platform Security
commonName              = Example Platform Root CA R1

# ----------------------------------------------------------------- ca
[ ca ]
default_ca              = CA_default

[ CA_default ]
dir                     = /opt/pki/root
certs                   = $dir/certs
crl_dir                 = $dir/crl
new_certs_dir           = $dir/newcerts
database                = $dir/db/index.txt
serial                  = $dir/db/serial
crlnumber               = $dir/db/crlnumber
rand_serial             = yes
unique_subject          = no

certificate             = $dir/ca/root-ca.crt.pem
private_key             = $dir/ca/private/root-ca.key.pem

default_days            = 3650
default_crl_days        = 180
default_md              = sha384
preserve                = no
email_in_dn             = no
copy_extensions         = none
policy                  = policy_strict
x509_extensions         = v3_intermediate_ca
crl_extensions          = crl_ext
name_opt                = $default::name_opt
cert_opt                = $default::cert_opt

# The root only ever signs CAs that belong to this organisation.
[ policy_strict ]
countryName             = match
stateOrProvinceName     = optional
localityName            = optional
organizationName        = match
organizationalUnitName  = optional
commonName              = supplied
emailAddress            = optional

# --------------------------------------------------------- extensions
[ v3_root_ca ]
basicConstraints        = critical,CA:TRUE
keyUsage                = critical,keyCertSign,cRLSign
subjectKeyIdentifier    = hash
authorityKeyIdentifier  = keyid:always

[ v3_intermediate_ca ]
basicConstraints        = critical,CA:TRUE,pathlen:0
keyUsage                = critical,keyCertSign,cRLSign
extendedKeyUsage        = serverAuth,clientAuth
subjectKeyIdentifier    = hash
authorityKeyIdentifier  = keyid:always,issuer
crlDistributionPoints   = @crl_info
authorityInfoAccess     = @aia_info
certificatePolicies     = @policy_internal
nameConstraints         = critical,@name_constraints

[ ocsp_signer ]
basicConstraints        = critical,CA:FALSE
keyUsage                = critical,digitalSignature
extendedKeyUsage        = critical,OCSPSigning
subjectKeyIdentifier    = hash
authorityKeyIdentifier  = keyid,issuer
noCheck                 = ignored

[ crl_ext ]
authorityKeyIdentifier  = keyid:always
issuerAltName           = issuer:copy

# ------------------------------------------------------------ pointers
[ crl_info ]
URI.0                   = $default::pki_base_url/root-ca.crl

[ aia_info ]
caIssuers;URI.0         = $default::pki_base_url/root-ca.cer
OCSP;URI.0              = $default::pki_base_url/ocsp/root

[ policy_internal ]
policyIdentifier        = 1.3.6.1.4.1.99999.1.1.1
CPS.1                   = $default::pki_base_url/cps/internal-v1.html

# ------------------------------------------------------ name constraints
# DNS is constrained to three suffixes.  IP SANs are forbidden outright:
# RFC 5280 leaves a name type UNCONSTRAINED if it appears in neither
# permittedSubtrees nor excludedSubtrees, so the exclusion is mandatory.
[ name_constraints ]
permitted;DNS.0         = example.io
permitted;DNS.1         = internal.example.io
permitted;DNS.2         = svc.cluster.local
permitted;email.0       = example.io
excluded;IP.0           = 0.0.0.0/0.0.0.0
excluded;IP.1           = 0:0:0:0:0:0:0:0/0:0:0:0:0:0:0:0
```

`pathlen:0` más `nameConstraints` es el par que hace que un intermedio sea seguro de entregar a otro equipo: no puede crear más CAs, y no puede salir de tu espacio de nombres DNS.

### 5.3 Autofirmar la raíz

```bash
$ cd /opt/pki/root
$ openssl req -new -x509 \
    -config openssl-root.cnf \
    -extensions v3_root_ca \
    -key ca/private/root-ca.key.pem \
    -sha384 -days 7305 \
    -out ca/root-ca.crt.pem
Enter pass phrase for ca/private/root-ca.key.pem:

$ openssl x509 -in ca/root-ca.crt.pem -noout -text
Certificate:
    Data:
        Version: 3 (0x2)
        Serial Number:
            4b:1d:9a:0c:33:f7:5e:82:11:c6:04:aa:9d:70:e3:15
        Signature Algorithm: ecdsa-with-SHA384
        Issuer: C=AR, O=Example Platform Engineering, OU=Platform Security, CN=Example Platform Root CA R1
        Validity
            Not Before: Aug 18 09:14:22 2026 GMT
            Not After : Aug 13 09:14:22 2046 GMT
        Subject: C=AR, O=Example Platform Engineering, OU=Platform Security, CN=Example Platform Root CA R1
        Subject Public Key Info:
            Public Key Algorithm: id-ecPublicKey
                Public-Key: (384 bit)
                pub:
                    04:8f:2a:c1:0d:74:9b:33:e0:51:a2:6c:88:d9:14:
                    ...
                ASN1 OID: secp384r1
                NIST CURVE: P-384
        X509v3 extensions:
            X509v3 Basic Constraints: critical
                CA:TRUE
            X509v3 Key Usage: critical
                Certificate Sign, CRL Sign
            X509v3 Subject Key Identifier:
                A1:3F:C0:9E:22:7B:44:D1:08:5A:6E:33:F9:1C:B7:20:4D:8E:11:6A
            X509v3 Authority Key Identifier:
                A1:3F:C0:9E:22:7B:44:D1:08:5A:6E:33:F9:1C:B7:20:4D:8E:11:6A
    Signature Algorithm: ecdsa-with-SHA384
    Signature Value:
        30:65:02:31:00:d4:...
```

> **Nota sobre OpenSSL 3.x:** desde 3.0 el Authority Key Identifier se imprime como una cadena hexadecimal pelada; OpenSSL 1.1.1 imprimía `keyid:A1:3F:...`. Los scripts que hacen grep de `keyid:` se rompen al actualizar.

Una raíz que es su propio emisor y su propio subject, con un AKI autorreferencial, es un *ancla de confianza*: matemáticamente no prueba nada (cualquiera puede autofirmarse), y su autoridad viene enteramente de haber sido colocada en un almacén de confianza fuera de banda.

### 5.4 `/opt/pki/tls-ca/openssl-tls-ca.cnf` — la CA emisora, completo

```ini
# =====================================================================
# Online Issuing CA — TLS server / client / peer certificates
# =====================================================================

[ default ]
ca_name                 = tls-ca
pki_base_url            = http://pki.example.io
name_opt                = utf8,esc_ctrl,multiline,lname,align

[ req ]
default_bits            = 2048
default_md              = sha384
string_mask             = utf8only
utf8                    = yes
prompt                  = no
distinguished_name      = tls_ca_dn

[ tls_ca_dn ]
countryName             = AR
organizationName        = Example Platform Engineering
organizationalUnitName  = Platform Security
commonName              = Example Platform TLS Issuing CA E1

[ ca ]
default_ca              = CA_default

[ CA_default ]
dir                     = /opt/pki/tls-ca
certs                   = $dir/certs
crl_dir                 = $dir/crl
new_certs_dir           = $dir/newcerts
database                = $dir/db/index.txt
serial                  = $dir/db/serial
crlnumber               = $dir/db/crlnumber
rand_serial             = yes
unique_subject          = no

certificate             = $dir/ca/tls-ca.crt.pem
private_key             = $dir/ca/private/tls-ca.key.pem

default_days            = 90
default_crl_days        = 3
default_md              = sha384
preserve                = no
email_in_dn             = no

# Extensions are NEVER taken from the CSR.  See §6.3.
copy_extensions         = none

policy                  = policy_org
x509_extensions         = server_cert_ec
crl_extensions          = crl_ext

[ policy_org ]
countryName             = match
organizationName        = match
organizationalUnitName  = optional
commonName              = supplied
emailAddress            = optional

# --------------------------------------------------- issuance profiles
# ECDSA server profile.  CA/B Baseline Requirements forbid
# keyEncipherment on an ECC key: there is no RSA key transport to
# authorise, and asserting it is a lint failure.
[ server_cert_ec ]
basicConstraints        = critical,CA:FALSE
keyUsage                = critical,digitalSignature
extendedKeyUsage        = serverAuth
subjectKeyIdentifier    = hash
authorityKeyIdentifier  = keyid,issuer
crlDistributionPoints   = @crl_info
authorityInfoAccess     = @aia_info
certificatePolicies     = @policy_internal
subjectAltName          = ${ENV::SAN}

# RSA server profile — legacy consumers only.
[ server_cert_rsa ]
basicConstraints        = critical,CA:FALSE
keyUsage                = critical,digitalSignature,keyEncipherment
extendedKeyUsage        = serverAuth
subjectKeyIdentifier    = hash
authorityKeyIdentifier  = keyid,issuer
crlDistributionPoints   = @crl_info
authorityInfoAccess     = @aia_info
subjectAltName          = ${ENV::SAN}

# mTLS client identity.  No serverAuth: a stolen client key must not be
# usable to impersonate a service.
[ client_cert ]
basicConstraints        = critical,CA:FALSE
keyUsage                = critical,digitalSignature
extendedKeyUsage        = clientAuth
subjectKeyIdentifier    = hash
authorityKeyIdentifier  = keyid,issuer
crlDistributionPoints   = @crl_info
authorityInfoAccess     = @aia_info
subjectAltName          = ${ENV::SAN}

# Service-mesh peer: both roles, SPIFFE ID in a URI SAN.
[ peer_cert ]
basicConstraints        = critical,CA:FALSE
keyUsage                = critical,digitalSignature,keyAgreement
extendedKeyUsage        = serverAuth,clientAuth
subjectKeyIdentifier    = hash
authorityKeyIdentifier  = keyid,issuer
crlDistributionPoints   = @crl_info
authorityInfoAccess     = @aia_info
subjectAltName          = ${ENV::SAN}

[ ocsp_signer ]
basicConstraints        = critical,CA:FALSE
keyUsage                = critical,digitalSignature
extendedKeyUsage        = critical,OCSPSigning
subjectKeyIdentifier    = hash
authorityKeyIdentifier  = keyid,issuer
noCheck                 = ignored

[ crl_ext ]
authorityKeyIdentifier  = keyid:always

[ crl_info ]
URI.0                   = $default::pki_base_url/tls-ca-e1.crl

[ aia_info ]
caIssuers;URI.0         = $default::pki_base_url/tls-ca-e1.cer
OCSP;URI.0              = $default::pki_base_url/ocsp/tls-e1

[ policy_internal ]
policyIdentifier        = 1.3.6.1.4.1.99999.1.1.1
CPS.1                   = $default::pki_base_url/cps/internal-v1.html
```

### 5.5 Firmar el intermedio desde la raíz offline

```bash
$ cd /opt/pki/tls-ca
$ openssl genpkey -algorithm EC \
    -pkeyopt ec_paramgen_curve:P-384 -pkeyopt ec_param_enc:named_curve \
    -aes-256-cbc -out ca/private/tls-ca.key.pem
$ chmod 0400 ca/private/tls-ca.key.pem

$ openssl req -new -config openssl-tls-ca.cnf \
    -key ca/private/tls-ca.key.pem \
    -out ca/tls-ca.csr.pem

$ openssl req -in ca/tls-ca.csr.pem -noout -verify -subject
Certificate request self-signature verify OK
subject=C=AR, O=Example Platform Engineering, OU=Platform Security, CN=Example Platform TLS Issuing CA E1
```

Transferí el CSR al host de la raíz offline (medio removible, air gap, lo que diga tu script de ceremonia), y después:

```bash
$ cd /opt/pki/root
$ openssl ca -config openssl-root.cnf \
    -extensions v3_intermediate_ca \
    -days 3650 -notext -md sha384 \
    -in /media/ceremony/tls-ca.csr.pem \
    -out certs/tls-ca-e1.crt.pem
Using configuration from openssl-root.cnf
Enter pass phrase for /opt/pki/root/ca/private/root-ca.key.pem:
Check that the request matches the signature
Signature ok
Certificate Details:
        Serial Number:
            5c:7a:1e:93:b0:f4:46:2d:8a:a1:c3:55:7e:9d:0b:41
        Validity
            Not Before: Aug 18 09:22:41 2026 GMT
            Not After : Aug 16 09:22:41 2036 GMT
        Subject:
            countryName               = AR
            organizationName          = Example Platform Engineering
            organizationalUnitName    = Platform Security
            commonName                = Example Platform TLS Issuing CA E1
        X509v3 extensions:
            X509v3 Basic Constraints: critical
                CA:TRUE, pathlen:0
            X509v3 Key Usage: critical
                Certificate Sign, CRL Sign
            X509v3 Extended Key Usage:
                TLS Web Server Authentication, TLS Web Client Authentication
            X509v3 Subject Key Identifier:
                7E:44:B2:19:C0:3D:8F:6A:52:11:E7:9B:04:AC:33:D8:60:12:5F:E1
            X509v3 Authority Key Identifier:
                A1:3F:C0:9E:22:7B:44:D1:08:5A:6E:33:F9:1C:B7:20:4D:8E:11:6A
            X509v3 CRL Distribution Points:
                Full Name:
                  URI:http://pki.example.io/root-ca.crl
            Authority Information Access:
                CA Issuers - URI:http://pki.example.io/root-ca.cer
                OCSP - URI:http://pki.example.io/ocsp/root
            X509v3 Certificate Policies:
                Policy: 1.3.6.1.4.1.99999.1.1.1
                  CPS: http://pki.example.io/cps/internal-v1.html
            X509v3 Name Constraints: critical
                Permitted:
                  DNS:example.io
                  DNS:internal.example.io
                  DNS:svc.cluster.local
                  email:example.io
                Excluded:
                  IP:0.0.0.0/0.0.0.0
                  IP:0:0:0:0:0:0:0:0/0:0:0:0:0:0:0:0
Certificate is to be certified until Aug 16 09:22:41 2036 GMT (3650 days)
Sign the certificate? [y/n]:y


1 out of 1 certificate requests certified, commit? [y/n]y
Write out database with 1 new entries
Database updated
```

Verificá el nuevo intermedio antes de que firme cualquier cosa:

```bash
$ openssl verify -CAfile ca/root-ca.crt.pem -x509_strict certs/tls-ca-e1.crt.pem
certs/tls-ca-e1.crt.pem: OK
```

`-x509_strict` deshabilita los rodeos para violaciones de RFC. Ejecutalo sobre tus propios certificados en CI — es la diferencia entre "OpenSSL tolera esto" y "todos los demás stacks también lo harán".

Construí el archivo de cadena de distribución (**CA emisora primero, raíz al final; la raíz es opcional para servidores TLS y se incluye acá solo para la distribución del almacén de confianza**):

```bash
$ cat certs/tls-ca-e1.crt.pem ca/root-ca.crt.pem > /opt/pki/dist/example-ca-chain.pem
$ openssl crl2pkcs7 -nocrl -certfile /opt/pki/dist/example-ca-chain.pem -out /opt/pki/dist/example-ca-chain.p7b
```

---

## 6. Emitiendo certificados de entidad final

### 6.1 Generación del CSR (en la máquina que será dueña de la clave)

La clave privada nunca debe viajar. Generala donde va a usarse, mandá solo el CSR.

```bash
$ openssl genpkey -algorithm EC \
    -pkeyopt ec_paramgen_curve:P-256 -pkeyopt ec_param_enc:named_curve \
    -out /etc/pki/tls/private/api.key.pem
$ chmod 0640 /etc/pki/tls/private/api.key.pem
$ chown root:nginx /etc/pki/tls/private/api.key.pem

$ openssl req -new -key /etc/pki/tls/private/api.key.pem \
    -subj "/C=AR/O=Example Platform Engineering/OU=Platform/CN=api.internal.example.io" \
    -addext "subjectAltName=DNS:api.internal.example.io,DNS:api.example.io,DNS:api,IP:10.42.7.20" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=serverAuth" \
    -sha384 \
    -out /tmp/api.csr.pem

$ openssl req -in /tmp/api.csr.pem -noout -text -verify
Certificate request self-signature verify OK
Certificate Request:
    Data:
        Version: 1 (0x0)
        Subject: C=AR, O=Example Platform Engineering, OU=Platform, CN=api.internal.example.io
        Subject Public Key Info:
            Public Key Algorithm: id-ecPublicKey
                Public-Key: (256 bit)
                ASN1 OID: prime256v1
                NIST CURVE: P-256
        Attributes:
            Requested Extensions:
                X509v3 Subject Alternative Name:
                    DNS:api.internal.example.io, DNS:api.example.io, DNS:api, IP Address:10.42.7.20
                X509v3 Key Usage: critical
                    Digital Signature
                X509v3 Extended Key Usage:
                    TLS Web Server Authentication
    Signature Algorithm: ecdsa-with-SHA384
```

El CSR está autofirmado con la propia clave privada del subject. Esa firma prueba exactamente una cosa: **que el solicitante posee la clave privada que corresponde a la clave pública del CSR.** No prueba nada sobre los nombres solicitados. Verificar la identidad es tarea de la CA (función de Autoridad de Registro) y queda enteramente fuera del CSR.

### 6.2 Firma

```bash
$ cd /opt/pki/tls-ca
$ SAN="DNS:api.internal.example.io,DNS:api.example.io,IP:10.42.7.20" \
  openssl ca -config openssl-tls-ca.cnf \
    -extensions server_cert_ec \
    -days 90 -notext -md sha384 -batch \
    -in /tmp/api.csr.pem \
    -out certs/api.internal.example.io.crt.pem
Using configuration from openssl-tls-ca.cnf
Enter pass phrase for /opt/pki/tls-ca/ca/private/tls-ca.key.pem:
Check that the request matches the signature
Signature ok
Certificate Details:
        Serial Number:
            2f:88:d1:04:6b:39:ae:57:c2:10:9f:33:44:e8:1b:75
        Validity
            Not Before: Aug 18 09:31:02 2026 GMT
            Not After : Nov 16 09:31:02 2026 GMT
        Subject:
            countryName               = AR
            organizationName          = Example Platform Engineering
            organizationalUnitName    = Platform
            commonName                = api.internal.example.io
        X509v3 extensions:
            X509v3 Basic Constraints: critical
                CA:FALSE
            X509v3 Key Usage: critical
                Digital Signature
            X509v3 Extended Key Usage:
                TLS Web Server Authentication
            X509v3 Subject Alternative Name:
                DNS:api.internal.example.io, DNS:api.example.io, IP Address:10.42.7.20
...
Certificate is to be certified until Nov 16 09:31:02 2026 GMT (90 days)
Write out database with 1 new entries
Database updated
```

Notá que el SAN emitido (tres entradas) difiere del SAN solicitado (cuatro, incluyendo el `api` pelado) — porque el perfil inyectó `$ENV::SAN` desde el entorno del operador de la CA, no desde el CSR. **Esa asimetría es la propiedad de seguridad.**

Notá también que el `IP:10.42.7.20` de la solicitud sobrevivió — lo cual contradice la restricción de nombre `excluded;IP` de la raíz. Este es exactamente el tipo de error que la verificación con `-x509_strict` detecta:

```bash
$ openssl verify -CAfile /opt/pki/root/ca/root-ca.crt.pem \
    -untrusted certs/tls-ca-e1.crt.pem certs/api.internal.example.io.crt.pem
C=AR, O=Example Platform Engineering, OU=Platform, CN=api.internal.example.io
error 47 at 0 depth lookup: permitted subtree violation
error certs/api.internal.example.io.crt.pem: verification failed
```

El certificado existe, la firma es válida, y es inutilizable. Eso son las restricciones de nombre funcionando según diseño. Corregí el SAN, o ampliá la restricción en la raíz — lo primero, siempre.

### 6.3 `copy_extensions`: la trampa

| Valor | Comportamiento | Veredicto |
|---|---|---|
| `copy_extensions = none` (default) | Las extensiones del CSR se ignoran por completo. El perfil de la CA es autoritativo. | **Seguro.** Requiere que la CA obtenga los SANs fuera de banda. |
| `copy_extensions = copy` | Las extensiones del CSR se copian **salvo** que la misma extensión aparezca en el perfil `x509_extensions` de la CA, que gana. | Aceptable solo si el perfil fija explícitamente `basicConstraints`, `keyUsage` y `extendedKeyUsage`, **y** el SAN se valida contra la política antes de firmar. |
| `copy_extensions = copyall` | Todo se copia, incluidas las extensiones que el perfil también define. | **Nunca.** Un CSR que lleve `basicConstraints=critical,CA:TRUE` produce una sub-CA funcional. |

La página de manual de `openssl ca` lo dice claramente, y es un hallazgo estándar en auditorías de PKI. Si habilitás `copy`, tu wrapper de emisión debe parsear el SAN del CSR y rechazar cualquier cosa fuera del espacio de nombres autorizado del solicitante *antes* de invocar `openssl ca`.

### 6.4 `openssl ca` versus `openssl x509 -req`

| | `openssl ca` | `openssl x509 -req` |
|---|---|---|
| Gestión de seriales | Archivo `serial` o `rand_serial` | `-CAserial` / `-CAcreateserial`, arranca en un valor fijo |
| Base de datos de emisión (`index.txt`) | Sí — requerida para CRLs y para el respondedor OCSP | **No** |
| Revocación / generación de CRL | Sí (`-revoke`, `-gencrl`) | No |
| Aplicación de política de DN | Sí (`policy_*`) | No |
| Extensiones | Perfil de configuración, consciente de `copy_extensions` | `-extfile`/`-extensions`, o `-copy_extensions` (OpenSSL 3.0+) |
| Apto para | Cualquier CA cuyos certificados puedan necesitar revocación | Solo certificados de prueba descartables |

Si no podés responder "¿qué certificados emitió alguna vez esta CA?", no tenés una CA, tenés un oráculo de firma. `openssl x509 -req` te da un oráculo de firma.

### 6.5 Empaquetado para consumidores

```bash
# Server bundle: leaf first, then intermediates, root omitted (the client has it).
$ cat certs/api.internal.example.io.crt.pem certs/tls-ca-e1.crt.pem \
    > /etc/pki/tls/certs/api.fullchain.pem

# PKCS#12 for a JVM / .NET consumer, modern algorithms
$ openssl pkcs12 -export \
    -inkey /etc/pki/tls/private/api.key.pem \
    -in certs/api.internal.example.io.crt.pem \
    -certfile /opt/pki/dist/example-ca-chain.pem \
    -name "api.internal.example.io" \
    -keypbe AES-256-CBC -certpbe AES-256-CBC -macalg sha256 \
    -out /tmp/api.p12
Enter Export Password:
Verifying - Enter Export Password:

$ openssl pkcs12 -in /tmp/api.p12 -info -noenc -nokeys
Enter Import Password:
MAC: sha256, Iteration 2048
MAC length: 32, salt length: 8
PKCS7 Encrypted data: PBES2, PBKDF2, AES-256-CBC, Iteration 2048, PRF hmacWithSHA256
Bag Attributes
    friendlyName: api.internal.example.io
    localKeyID: 3E 22 A0 ...
subject=C=AR, O=Example Platform Engineering, OU=Platform, CN=api.internal.example.io
issuer=C=AR, O=Example Platform Engineering, OU=Platform Security, CN=Example Platform TLS Issuing CA E1
```

> `-noenc` es la grafía de OpenSSL 3.x; `-nodes` es el alias obsoleto y sigue funcionando. Si un consumidor viejo de Java 8 o Windows no puede abrir el archivo, quiere RC2/3DES del proveedor legacy: agregá `-legacy` a la exportación. Hacelo solo cuando hayas comprobado que el consumidor no puede actualizarse.

### 6.6 Almacenes de confianza del sistema

| Distribución | Directorio de anclas | Comando de refresco | Consumidores |
|---|---|---|---|
| Fedora / RHEL / CentOS | `/etc/pki/ca-trust/source/anchors/` | `update-ca-trust extract` | OpenSSL, GnuTLS, NSS, Java (vía p11-kit) |
| Debian / Ubuntu | `/usr/local/share/ca-certificates/` (solo `.crt`) | `update-ca-certificates` | OpenSSL, GnuTLS |
| SUSE | `/etc/pki/trust/anchors/` | `update-ca-certificates` | ídem |
| Alpine | `/usr/local/share/ca-certificates/` | `update-ca-certificates` | OpenSSL |
| Cualquiera (por directorio) | arbitrario | `openssl rehash <dir>` | cualquier cosa que use `-CApath` |

```bash
$ sudo cp /opt/pki/root/ca/root-ca.crt.pem /etc/pki/ca-trust/source/anchors/example-root-ca.pem
$ sudo update-ca-trust extract
$ trust list --filter=ca-anchors | grep -A2 'Example Platform Root'
    label: Example Platform Root CA R1
    trust: anchor
    category: authority
```

`openssl rehash` (el reemplazo moderno del script Perl `c_rehash`) crea los enlaces simbólicos `<subject_hash>.<n>` que requiere la búsqueda con `-CApath`:

```bash
$ openssl rehash -v /etc/pki/tls/mytrust
Doing /etc/pki/tls/mytrust
link example-root-ca.pem -> 4f2a1c8e.0
```

Los runtimes de lenguajes **no** usan todos el almacén del sistema: Node.js trae el suyo (`NODE_EXTRA_CA_CERTS`), `requests` de Python usa `certifi` (`REQUESTS_CA_BUNDLE`), Go usa el almacén del sistema en Linux pero tiene los overrides `SSL_CERT_FILE`/`SSL_CERT_DIR`, Java usa `$JAVA_HOME/lib/security/cacerts`. "Funciona con `curl` pero no desde la app" es casi siempre esto.

---

## 7. Revocación

### 7.1 Los mecanismos y sus compromisos honestos

| Mecanismo | Frescura | Costo para el cliente | Privacidad | Cómo falla | Realidad en 2026 |
|---|---|---|---|---|---|
| **CRL** (RFC 5280) | Horas–días | Descarga de la lista completa; varios MB para CAs grandes | Buena (sin consulta por certificado) | Soft-fail o desactualizada | Base. Obligatoria en el programa de Mozilla desde 2024; la WebPKI volvió a las CRLs. |
| **CRL delta** | Misma base + incremento | Incrementos chicos | Buena | Ídem | Rara vez desplegada; la complejidad casi nunca compensa. |
| **OCSP** (RFC 6960) | Minutos–horas | Un round trip por certificado, en el camino del handshake | **Mala** — el respondedor aprende quién visita qué | Soft-fail casi universal ⇒ inefectivo contra un atacante de red | En retirada. Let's Encrypt apagó sus respondedores en 2025 y ya no emite URIs de AIA para OCSP. |
| **OCSP stapling** (RFC 6066 `status_request`) | Controlada por el servidor | Cero round trips extra para el cliente | Buena | El servidor no manda nada ⇒ el cliente cae en soft-fail | Buena práctica; no exigible sin Must-Staple. |
| **Must-Staple** (RFC 7633, `1.3.6.1.5.5.7.1.24`) | La del staple | Cero | Buena | **Hard-fail** — sin staple, sin conexión | Seguridad correcta, operación peligrosa. Una caída del respondedor = una caída. |
| **CRLite / conjuntos empujados al navegador** | Horas | Cero en el handshake | Excelente | N/A | Solo navegadores; no disponible para tus servicios. |
| **Vidas cortas** | ≤ la vida útil | Cero | Excelente | N/A | **La respuesta real.** Un certificado de 6 días no necesita infraestructura de revocación. |

La conclusión estratégica para un equipo de plataforma: **tratá la revocación como un artefacto de cumplimiento y la reducción de la vida útil como el control real.** Publicá una CRL porque los auditores y RFC 5280 la exigen; bajá tu ventana efectiva de revocación emitiendo certificados de 90 días (o menos) con renovación automatizada. Las CAs públicas tomaron la misma decisión — el cronograma de la balota SC-081 del CA/Browser Forum limita la vida de los certificados TLS públicos a 200 días desde el 2026-03-15, 100 días desde el 2027-03-15, y 47 días desde el 2029-03-15.

### 7.2 Revocar, y generar una CRL

```bash
$ cd /opt/pki/tls-ca
$ openssl ca -config openssl-tls-ca.cnf \
    -revoke certs/legacy.internal.example.io.crt.pem \
    -crl_reason keyCompromise
Using configuration from openssl-tls-ca.cnf
Enter pass phrase for /opt/pki/tls-ca/ca/private/tls-ca.key.pem:
Revoking Certificate 2F88D1046B39AE57C2109F334D2A0C13.
Database updated
```

Valores válidos de `-crl_reason`: `unspecified`, `keyCompromise`, `CACompromise`, `affiliationChanged`, `superseded`, `cessationOfOperation`, `certificateHold`, `removeFromCRL`. Usalos con honestidad — `keyCompromise` es el que dispara respuesta a incidentes aguas abajo, y las CAs están obligadas a reaccionar ante él en plazos ajustados.

La base de datos después de la revocación:

```bash
$ cat db/index.txt
V	261116093102Z		2F88D1046B39AE57C2109F334E81B75	unknown	/C=AR/O=Example Platform Engineering/OU=Platform/CN=api.internal.example.io
R	261020081500Z	260818113005Z,keyCompromise	2F88D1046B39AE57C2109F334D2A0C13	unknown	/C=AR/O=Example Platform Engineering/OU=Platform/CN=legacy.internal.example.io
```

Columnas: **estado** (`V`álido / `R`evocado / `E`xpirado), vencimiento (`YYMMDDHHMMSSZ`), fecha y motivo de revocación, serial (hex en mayúsculas), nombre de archivo, DN del subject. Este archivo *es* tu CA — respaldalo con el mismo rigor que la clave privada. Si lo perdés ya no podés emitir una CRL veraz.

```bash
$ openssl ca -config openssl-tls-ca.cnf -gencrl -crldays 3 -out crl/tls-ca-e1.crl.pem
Using configuration from openssl-tls-ca.cnf
Enter pass phrase for /opt/pki/tls-ca/ca/private/tls-ca.key.pem:

$ openssl crl -in crl/tls-ca-e1.crl.pem -noout -text
Certificate Revocation List (CRL):
        Version 2 (0x1)
        Signature Algorithm: ecdsa-with-SHA384
        Issuer: C=AR, O=Example Platform Engineering, OU=Platform Security, CN=Example Platform TLS Issuing CA E1
        Last Update: Aug 18 11:32:14 2026 GMT
        Next Update: Aug 21 11:32:14 2026 GMT
        CRL extensions:
            X509v3 Authority Key Identifier:
                7E:44:B2:19:C0:3D:8F:6A:52:11:E7:9B:04:AC:33:D8:60:12:5F:E1
            X509v3 CRL Number:
                4098
Revoked Certificates:
    Serial Number: 2F88D1046B39AE57C2109F334D2A0C13
        Revocation Date: Aug 18 11:30:05 2026 GMT
        CRL entry extensions:
            X509v3 CRL Reason Code:
                Key Compromise
    Signature Algorithm: ecdsa-with-SHA384

# Verify the CRL's own signature before publishing it
$ openssl crl -in crl/tls-ca-e1.crl.pem -CAfile /opt/pki/dist/example-ca-chain.pem -noout
verify OK

# Publish in DER too — several stacks will not parse PEM CRLs
$ openssl crl -in crl/tls-ca-e1.crl.pem -outform DER -out /srv/pki/www/tls-ca-e1.crl
```

**`nextUpdate` es un plazo duro, no una sugerencia.** Una vez que pasa, un verificador que ejecuta `-crl_check` trata la CRL como inutilizable y falla cerrado con el error 12. Una CRL con `default_crl_days = 3` requiere un trabajo de regeneración *confiable* a un intervalo mucho más corto que 3 días.

```ini
# /etc/systemd/system/pki-crl-refresh.service
[Unit]
Description=Regenerate and publish the Example Platform TLS CA CRL
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=pki
WorkingDirectory=/opt/pki/tls-ca
Environment=OPENSSL_CONF=/opt/pki/tls-ca/openssl-tls-ca.cnf
ExecStart=/usr/bin/openssl ca -config /opt/pki/tls-ca/openssl-tls-ca.cnf \
          -gencrl -crldays 3 -passin file:/run/credentials/pki-crl-refresh.service/ca-pass \
          -out /opt/pki/tls-ca/crl/tls-ca-e1.crl.pem
ExecStart=/usr/bin/openssl crl -in /opt/pki/tls-ca/crl/tls-ca-e1.crl.pem \
          -CAfile /opt/pki/dist/example-ca-chain.pem -noout
ExecStart=/usr/bin/openssl crl -in /opt/pki/tls-ca/crl/tls-ca-e1.crl.pem \
          -outform DER -out /srv/pki/www/tls-ca-e1.crl
LoadCredentialEncrypted=ca-pass:/etc/pki/creds/tls-ca-pass.cred
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/opt/pki/tls-ca /srv/pki/www
NoNewPrivileges=yes
CapabilityBoundingSet=

[Install]
WantedBy=multi-user.target
```

```ini
# /etc/systemd/system/pki-crl-refresh.timer
[Unit]
Description=Refresh the TLS CA CRL every 6 hours

[Timer]
OnBootSec=5min
OnUnitActiveSec=6h
RandomizedDelaySec=10min
Persistent=true
AccuracySec=1min

[Install]
WantedBy=timers.target
```

```bash
$ sudo systemctl enable --now pki-crl-refresh.timer
$ systemctl list-timers pki-crl-refresh.timer
NEXT                        LEFT     LAST                        PASSED  UNIT                    ACTIVATES
Tue 2026-08-18 17:38:22 -03 5h 58min Tue 2026-08-18 11:32:14 -03 6min ago pki-crl-refresh.timer   pki-crl-refresh.service
```

### 7.3 Verificar la revocación como cliente

```bash
# CRL-based, whole chain
$ openssl verify -CAfile /opt/pki/dist/example-ca-chain.pem \
    -crl_check_all -CRLfile crl/tls-ca-e1.crl.pem -CRLfile /opt/pki/root/crl/root-ca.crl.pem \
    certs/legacy.internal.example.io.crt.pem
C=AR, O=Example Platform Engineering, OU=Platform, CN=legacy.internal.example.io
error 23 at 0 depth lookup: certificate revoked
error certs/legacy.internal.example.io.crt.pem: verification failed
```

`-crl_check` verifica solo la hoja; `-crl_check_all` recorre toda la cadena. Usá `-crl_check_all` — una hoja no revocada bajo un intermedio revocado no vale nada.

### 7.4 Un respondedor OCSP

Para trabajo de laboratorio y para el examen, OpenSSL trae uno:

```bash
# Dedicated responder key + delegated signer cert (id-pkix-ocsp-nocheck)
$ openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out ca/private/ocsp-e1.key.pem
$ openssl req -new -key ca/private/ocsp-e1.key.pem \
    -subj "/C=AR/O=Example Platform Engineering/CN=OCSP Responder TLS E1" -out /tmp/ocsp-e1.csr.pem
$ openssl ca -config openssl-tls-ca.cnf -extensions ocsp_signer \
    -days 365 -notext -batch -in /tmp/ocsp-e1.csr.pem -out certs/ocsp-e1.crt.pem

$ openssl ocsp -port 9080 -index db/index.txt \
    -CA ca/tls-ca.crt.pem \
    -rkey ca/private/ocsp-e1.key.pem -rsigner certs/ocsp-e1.crt.pem \
    -nrequest 0 -text
```

Consultalo:

```bash
$ openssl ocsp -issuer ca/tls-ca.crt.pem \
    -cert certs/api.internal.example.io.crt.pem \
    -url http://127.0.0.1:9080 -CAfile /opt/pki/dist/example-ca-chain.pem \
    -resp_text -no_nonce
OCSP Response Data:
    OCSP Response Status: successful (0x0)
    Response Type: Basic OCSP Response
    Version: 1 (0x0)
    Responder Id: CN = OCSP Responder TLS E1, O = Example Platform Engineering, C = AR
    Produced At: Aug 18 11:41:07 2026 GMT
    Responses:
    Certificate ID:
      Hash Algorithm: sha1
      Issuer Name Hash: 9A2C...
      Issuer Key Hash: 7E44B219C03D8F6A5211E79B04AC33D860125FE1
      Serial Number: 2F88D1046B39AE57C2109F334E81B75
    Cert Status: good
    This Update: Aug 18 11:41:07 2026 GMT
...
Response verify OK
certs/api.internal.example.io.crt.pem: good
	This Update: Aug 18 11:41:07 2026 GMT
```

Dos cosas para internalizar. Primero, el `CertID` de OCSP todavía usa **SHA-1** por defecto (RFC 6960 obliga a SHA-1 por interoperabilidad) — es un uso irrelevante para la resistencia a colisiones, pero sorprende a los auditores cada vez. Segundo, `openssl ocsp` como servidor es una **implementación de referencia mono-hilo**; ponerla en un camino de emisión productivo es la forma de convertir una verificación de revocación en un incidente de disponibilidad. Producción significa un respondedor de verdad (Vault PKI, step-ca, EJBCA, o un CDN de respuestas pre-firmadas estáticas).

### 7.5 Stapling en el borde de servicio

```nginx
# /etc/nginx/conf.d/api.internal.example.io.conf
server {
    listen              443 ssl;
    listen              [::]:443 ssl;
    http2               on;
    server_name         api.internal.example.io api.example.io;

    # Leaf first, then intermediate(s). Root MUST NOT be here: it costs
    # bytes on every handshake and adds nothing a client that trusts you
    # does not already have.
    ssl_certificate     /etc/pki/tls/certs/api.fullchain.pem;
    ssl_certificate_key /etc/pki/tls/private/api.key.pem;

    ssl_protocols            TLSv1.2 TLSv1.3;
    ssl_ciphers              ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers off;
    ssl_ecdh_curve           X25519:prime256v1:secp384r1;
    ssl_session_cache        shared:TLS:10m;
    ssl_session_timeout      1d;
    ssl_session_tickets      off;

    # OCSP stapling. ssl_trusted_certificate needs the FULL chain to the
    # root so nginx can verify the responder's signature; it is not used
    # for client authentication.
    ssl_stapling             on;
    ssl_stapling_verify      on;
    ssl_trusted_certificate  /opt/pki/dist/example-ca-chain.pem;
    resolver                 10.42.0.10 valid=300s ipv6=off;
    resolver_timeout         5s;

    # Mutual TLS. ssl_crl must contain a current CRL for EVERY CA in the
    # client chain, otherwise verification fails with
    # "unable to get certificate CRL".
    ssl_client_certificate   /opt/pki/dist/example-ca-chain.pem;
    ssl_crl                  /etc/pki/tls/certs/example-all-crls.pem;
    ssl_verify_client        on;
    ssl_verify_depth         2;

    add_header Strict-Transport-Security "max-age=63072000" always;

    location / {
        proxy_pass         http://127.0.0.1:8080;
        proxy_set_header   X-Client-DN      $ssl_client_s_dn;
        proxy_set_header   X-Client-Serial  $ssl_client_serial;
        proxy_set_header   X-Client-Verify  $ssl_client_verify;
    }
}
```

```bash
$ openssl s_client -connect api.internal.example.io:443 \
    -servername api.internal.example.io -status < /dev/null 2>&1 | head -20
CONNECTED(00000003)
OCSP response:
======================================
OCSP Response Data:
    OCSP Response Status: successful (0x0)
    Response Type: Basic OCSP Response
    ...
    Cert Status: good
    This Update: Aug 18 11:41:07 2026 GMT
    Next Update: Aug 25 11:41:07 2026 GMT
======================================
```

`OCSP response: no response sent by server` significa que el stapling está apagado, que el respondedor no estaba alcanzable la última vez que nginx refrescó, o — la causa más frecuente — que a `ssl_trusted_certificate` le falta la raíz y `ssl_stapling_verify on` está rechazando la respuesta en silencio. nginx lo registra a nivel warn; revisá el log de errores en vez de adivinar.

---

## 8. Certificate Transparency

CT (RFC 6962) aborda el riesgo residual que sobrevive a todo lo anterior: **una CA de confianza emitiendo un certificado que no debería haber emitido.** Las restricciones de nombre frenan a *tus* sub-CAs delegadas; nada impide que una CA pública ajena emita para tu dominio, ya sea por compromiso, coerción o error administrativo. CT hace que esa emisión sea pública e irreversiblemente visible.

El mecanismo:

1. La CA construye un **precertificado**: el certificado que pretende emitir, más una **extensión de veneno** crítica (`1.3.6.1.4.1.11129.2.4.3`). La criticidad garantiza que ningún verificador acepte el precert como un certificado real.
2. Lo envía a logs de CT append-only, respaldados por árboles de Merkle. Cada log devuelve un **Signed Certificate Timestamp** (SCT) — una promesa de incluir la entrada dentro de su Maximum Merge Delay.
3. La CA emite el certificado real con los SCTs embebidos en la extensión `1.3.6.1.4.1.11129.2.4.2`.

Existen alternativas de entrega (la extensión TLS `signed_certificate_timestamp`, o adjuntos en la respuesta OCSP), pero los SCTs embebidos predominan porque no necesitan soporte del servidor.

```bash
$ openssl s_client -connect www.example.org:443 -servername www.example.org < /dev/null 2>/dev/null \
  | openssl x509 -noout -ext ct_precert_scts
CT Precertificate SCTs:
    Signed Certificate Timestamp:
        Version   : v1 (0x0)
        Log ID    : 7D:59:1E:12:E1:78:2A:7B:1C:61:67:7C:5E:FD:F8:D0:
                    87:5C:14:A0:4E:95:9E:B9:03:2F:D9:0E:8C:2E:79:B8
        Timestamp : Aug 18 09:31:03.221 2026 GMT
        Extensions: none
        Signature : ecdsa-with-SHA256
                    30:45:02:20:6B:...
    Signed Certificate Timestamp:
        Version   : v1 (0x0)
        Log ID    : EE:CD:D0:64:D5:DB:1A:CE:C5:5C:B7:9D:B4:CD:13:A2:
                    32:87:46:7C:BC:EC:DE:C3:51:48:59:46:71:1F:B5:9B
        Timestamp : Aug 18 09:31:03.885 2026 GMT
        Extensions: none
        Signature : ecdsa-with-SHA256
                    30:44:02:20:1F:...
```

La política de CT de Chrome exige que los certificados de confianza pública lleven SCTs de múltiples logs calificados operados por **organizaciones diferentes** (con un SCT adicional requerido para certificados de vida más larga); Apple aplica una política comparable. Un certificado público sin SCTs suficientes es rechazado por el navegador sin importar la validez de la cadena.

**Operativamente, CT es un control de detección que deberías estar consumiendo.** Suscribite a feeds de CT para tus dominios — vía `crt.sh`, un monitor comercial, o tu propio observador estilo `certspotter` — y alertá ante cualquier emisión que no provenga de tu propio pipeline. Esa alerta es tu única advertencia de que alguna CA en algún lado acuñó un certificado para tu espacio de nombres.

CT también tiene una consecuencia de privacidad que conviene tener en cuenta al diseñar: **cada nombre de host de un certificado de confianza pública se vuelve público**, permanentemente. Los nombres de host internos se filtran por los logs de CT constantemente. Dos mitigaciones: poner los nombres internos bajo tu PKI privada (§5 de este material), o usar certificados wildcard para hosts de cara interna, de modo que los nombres individuales no queden enumerados.

---

## 9. ACME: la emisión como una API

La PKI manual no sobrevive a vidas de 90 días, mucho menos a las de 47. ACME (RFC 8555) es el estándar que convierte la emisión en un protocolo máquina a máquina.

El flujo: el cliente genera una **clave de cuenta** (distinta de cualquier clave de certificado) y se registra; solicita una **orden** para un conjunto de identificadores; el servidor devuelve **autorizaciones**, cada una con **desafíos**; el cliente aprovisiona la respuesta al desafío y le pide al servidor que valide; al tener éxito la orden pasa a `ready`, el cliente **finaliza** haciendo POST de un CSR, y descarga el certificado.

### 9.1 Tipos de desafío

| Desafío | Superficie de prueba | Puerto / registro | Wildcards | Falla cuando | Ideal para |
|---|---|---|---|---|---|
| **HTTP-01** | `http://<domain>/.well-known/acme-challenge/<token>` devolviendo `<token>.<thumbprint>` | TCP 80 entrante desde la CA | ❌ | El host no es alcanzable desde internet en el :80; un CDN o WAF intercepta la ruta | Un único host expuesto a internet |
| **DNS-01** | Registro TXT en `_acme-challenge.<domain>` con base64url(SHA-256(`<token>.<thumbprint>`)) | DNS | ✅ **única opción para wildcards** | No hay API del proveedor de DNS; propagación lenta; la credencial de la API es un secreto de nivel toma-de-dominio | Wildcards, hosts internos, flotas balanceadas |
| **TLS-ALPN-01** (RFC 8737) | TLS en el :443 con ALPN `acme-tls/1`, certificado autofirmado que lleva `acmeIdentifier` (`1.3.6.1.5.5.7.1.31`) | TCP 443 entrante | ❌ | El proxy que termina TLS no puede hacerse consciente de ALPN | Hosts donde el :80 está cerrado por política |

TLS-SNI-01 y -02 fueron eliminados en 2019: en plataformas de hosting compartido, un atacante que pudiera subir un certificado para un SNI arbitrario podía pasar la validación de un dominio que no controlaba. La lección se generaliza — **un desafío es tan fuerte como la cosa más débil que puede responder por el identificador**, que es exactamente por qué las credenciales de API para DNS-01 deben limitarse solo a registros `_acme-challenge`.

### 9.2 certbot

```bash
$ sudo dnf install -y certbot python3-certbot-nginx python3-certbot-dns-route53

$ sudo certbot certonly --nginx \
    -d api.example.io -d www.example.io \
    --key-type ecdsa --elliptic-curve secp384r1 \
    --rsa-key-size 3072 \
    --agree-tos -m pki@example.io --no-eff-email \
    --non-interactive
Saving debug log to /var/log/letsencrypt/letsencrypt.log
Requesting a certificate for api.example.io and www.example.io
Successfully received certificate.
Certificate is saved at: /etc/letsencrypt/live/api.example.io/fullchain.pem
Key is saved at:         /etc/letsencrypt/live/api.example.io/privkey.pem
This certificate expires on 2026-11-16.
These files will be updated when the certificate renews.
Certbot has set up a scheduled task to automatically renew this certificate in the background.

$ sudo ls -l /etc/letsencrypt/live/api.example.io/
lrwxrwxrwx. 1 root root  40 Aug 18 09:52 cert.pem -> ../../archive/api.example.io/cert1.pem
lrwxrwxrwx. 1 root root  41 Aug 18 09:52 chain.pem -> ../../archive/api.example.io/chain1.pem
lrwxrwxrwx. 1 root root  45 Aug 18 09:52 fullchain.pem -> ../../archive/api.example.io/fullchain1.pem
lrwxrwxrwx. 1 root root  43 Aug 18 09:52 privkey.pem -> ../../archive/api.example.io/privkey1.pem
```

Apuntá siempre tu servidor web a los **symlinks de `live/`**, nunca a `archive/`. La renovación escribe `cert2.pem` y reapunta el symlink; una configuración fijada a `cert1.pem` sigue sirviendo silenciosamente el certificado viejo hasta que vence.

Wildcard vía DNS-01, y un ensayo de la renovación:

```bash
$ sudo certbot certonly --dns-route53 \
    -d 'example.io' -d '*.example.io' \
    --key-type ecdsa --elliptic-curve secp384r1 \
    --dns-route53-propagation-seconds 30 \
    --deploy-hook /usr/local/sbin/reload-tls-consumers \
    --agree-tos -m pki@example.io --non-interactive

$ sudo certbot renew --dry-run
Processing /etc/letsencrypt/renewal/api.example.io.conf
Simulating renewal of an existing certificate for api.example.io and www.example.io
Congratulations, all simulations succeeded. The following certificates have been renewed:
  /etc/letsencrypt/live/api.example.io/fullchain.pem (success)

$ systemctl list-timers certbot.timer
NEXT                        LEFT    LAST                        PASSED  UNIT           ACTIVATES
Wed 2026-08-19 01:14:00 -03 13h     Tue 2026-08-18 09:23:11 -03 2h ago  certbot.timer  certbot.service
```

`--dry-run` pega contra el endpoint de staging y no consume límites de tasa. Ejecutalo en CI. El deploy hook es la pieza que los equipos olvidan: un archivo renovado que nada recarga es un certificado vencido en el cable.

```bash
#!/usr/bin/env bash
# /usr/local/sbin/reload-tls-consumers — invoked by certbot --deploy-hook
# $RENEWED_LINEAGE and $RENEWED_DOMAINS are exported by certbot.
set -euo pipefail

logger -t acme-deploy "renewed: ${RENEWED_DOMAINS:-unknown} -> ${RENEWED_LINEAGE:-unknown}"

# Fail fast if the new material is not internally consistent.
cert="${RENEWED_LINEAGE}/cert.pem"
key="${RENEWED_LINEAGE}/privkey.pem"
c_spki=$(openssl x509 -in "$cert" -pubkey -noout | openssl pkey -pubin -outform DER | sha256sum)
k_spki=$(openssl pkey -in "$key" -pubout -outform DER | sha256sum)
[[ "$c_spki" == "$k_spki" ]] || { logger -t acme-deploy "FATAL: key/cert mismatch"; exit 1; }

install -m 0644 -o root -g root "${RENEWED_LINEAGE}/fullchain.pem" /etc/pki/tls/certs/api.fullchain.pem
install -m 0640 -o root -g nginx "$key"                            /etc/pki/tls/private/api.key.pem

nginx -t
systemctl reload nginx
systemctl reload haproxy 2>/dev/null || true
logger -t acme-deploy "reload complete"
```

### 9.3 Comparación de clientes ACME

| Cliente | Lenguaje / dependencias | ¿Corre como root? | Proveedores de DNS | Punto fuerte |
|---|---|---|---|---|
| **certbot** | Python, plugins | usualmente | ~30 vía plugins | Implementación de referencia; empaquetada por las distros; la mejor documentada |
| **acme.sh** | Shell POSIX | no (puede correr sin privilegios) | 150+ | Cero dependencias en runtime; ideal para contenedores y appliances |
| **lego** | Go, binario único | no | 100+ | Librería + CLI; se embebe limpiamente en servicios Go |
| **cert-manager** | Go, controlador de Kubernetes | n/a | vía solvers | Declarativo; la respuesta nativa de Kubernetes |
| **step-cli / step-ca** | Go | no | servidor ACME propio | Te permite correr *tu propio* servidor ACME para PKI interna |
| **Caddy** | Servidor web en Go | no | integrado | HTTPS automático sin ningún cliente separado |

Para una CA empresarial que habla ACME, **External Account Binding** ata una cuenta ACME a una identidad empresarial preexistente:

```bash
$ certbot register \
    --server https://acme.corp-ca.example.io/directory \
    --eab-kid 'kid-4f2a1c8e' \
    --eab-hmac-key 'zWmNq2...base64url...' \
    -m pki@example.io --agree-tos
```

### 9.4 Un servidor ACME interno — step-ca

Lo mejor de los dos mundos para una PKI privada: tu propia raíz, y automatización ACME.

```bash
$ step ca init --deployment-type standalone \
    --name "Example Platform Internal CA" \
    --dns ca.internal.example.io --address :8443 \
    --provisioner platform@example.io \
    --acme

$ step ca provisioner add acme-internal --type ACME \
    --x509-min-dur 24h --x509-default-dur 168h --x509-max-dur 336h

$ sudo certbot certonly --standalone \
    --server https://ca.internal.example.io:8443/acme/acme-internal/directory \
    -d worker-07.internal.example.io \
    --key-type ecdsa --agree-tos -m pki@example.io --non-interactive
```

Una vida por defecto de una semana con renovación totalmente automatizada vuelve la infraestructura de CRL y OCSP operativamente irrelevante para ese nivel — que es todo el punto.

---

## 10. PKI declarativa en Kubernetes

### 10.1 cert-manager — manifiestos completos

Incorporá tu jerarquía existente con raíz offline al cluster como un issuer de CA:

```yaml
---
# The issuing CA's key and certificate, delivered to the cluster.
# In production this Secret is populated by an External Secrets Operator
# pull from Vault/KMS, never committed.
apiVersion: v1
kind: Secret
metadata:
  name: tls-ca-e1-keypair
  namespace: cert-manager
type: kubernetes.io/tls
stringData:
  tls.crt: |
    -----BEGIN CERTIFICATE-----
    MIIC9zCCAn2gAwIBAgIQXHoek7D0Ri2KocNVfp0LQTAKBggqhkjOPQQDAzBrMQsw
    ...
    -----END CERTIFICATE-----
  tls.key: |
    -----BEGIN PRIVATE KEY-----
    MIG2AgEAMBAGByqGSM49AgEGBSuBBAAiBIGeMIGbAgEBBDDVn7lQ...
    -----END PRIVATE KEY-----
  ca.crt: |
    -----BEGIN CERTIFICATE-----
    MIICzDCCAlKgAwIBAgIQSx2aDDP3XoIRxgSqnXDjFTAKBggqhkjOPQQDAzBrMQsw
    ...
    -----END CERTIFICATE-----
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: platform-tls-ca
spec:
  ca:
    secretName: tls-ca-e1-keypair
    crlDistributionPoints:
      - http://pki.example.io/tls-ca-e1.crl
    ocspServers:
      - http://pki.example.io/ocsp/tls-e1
    issuingCertificateURLs:
      - http://pki.example.io/tls-ca-e1.cer
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: api-internal-tls
  namespace: platform-api
spec:
  secretName: api-internal-tls
  secretTemplate:
    annotations:
      reloader.stakater.com/match: "true"
  # Renew at 2/3 of lifetime: 90d issued, renewed at day 60.
  duration: 2160h      # 90d
  renewBefore: 720h    # 30d
  commonName: api.internal.example.io
  subject:
    organizations: ["Example Platform Engineering"]
    organizationalUnits: ["Platform"]
    countries: ["AR"]
  dnsNames:
    - api.internal.example.io
    - api.platform-api.svc.cluster.local
    - api.platform-api.svc
  usages:
    - digital signature
    - server auth
  privateKey:
    algorithm: ECDSA
    size: 256
    encoding: PKCS8
    # Rotate the key on every renewal. "Never" reuses the key forever and
    # turns a single key compromise into a permanent one.
    rotationPolicy: Always
  issuerRef:
    name: platform-tls-ca
    kind: ClusterIssuer
    group: cert-manager.io
---
# Public-facing certificate via ACME + DNS-01 (wildcards need DNS-01).
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: pki@example.io
    privateKeySecretRef:
      name: letsencrypt-prod-account-key
    solvers:
      - selector:
          dnsZones: ["example.io"]
        dns01:
          route53:
            region: sa-east-1
            hostedZoneID: Z0123456789ABCDEFGHIJ
            role: arn:aws:iam::111122223333:role/cert-manager-dns01
      - http01:
          ingress:
            ingressClassName: nginx
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: public-wildcard-tls
  namespace: edge
spec:
  secretName: public-wildcard-tls
  duration: 2160h
  renewBefore: 720h
  dnsNames:
    - example.io
    - "*.example.io"
  privateKey:
    algorithm: ECDSA
    size: 384
    rotationPolicy: Always
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
---
# Deny-by-default network policy for the issuing-CA keypair's consumer.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: cert-manager-egress
  namespace: cert-manager
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: cert-manager
  policyTypes: ["Egress"]
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except: ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.169.254/32"]
      ports:
        - protocol: TCP
          port: 443
```

```bash
$ kubectl -n platform-api get certificate api-internal-tls
NAME               READY   SECRET             AGE
api-internal-tls   True    api-internal-tls   3m18s

$ kubectl -n platform-api describe certificate api-internal-tls | tail -8
Events:
  Type    Reason     Age    From                                       Message
  ----    ------     ----   ----                                       -------
  Normal  Issuing    3m22s  cert-manager-certificates-trigger          Issuing certificate as Secret does not exist
  Normal  Generated  3m21s  cert-manager-certificates-key-manager      Stored new private key in temporary Secret "api-internal-tls-hb4kx"
  Normal  Requested  3m21s  cert-manager-certificates-request-manager  Created new CertificateRequest resource "api-internal-tls-1"
  Normal  Issuing    3m19s  cert-manager-certificates-issuing          The certificate has been successfully issued

$ kubectl -n platform-api get secret api-internal-tls -o jsonpath='{.data.tls\.crt}' \
  | base64 -d | openssl x509 -noout -subject -issuer -dates -ext subjectAltName
subject=C=AR, O=Example Platform Engineering, OU=Platform, CN=api.internal.example.io
issuer=C=AR, O=Example Platform Engineering, OU=Platform Security, CN=Example Platform TLS Issuing CA E1
notBefore=Aug 18 12:04:11 2026 GMT
notAfter=Nov 16 12:04:11 2026 GMT
X509v3 Subject Alternative Name:
    DNS:api.internal.example.io, DNS:api.platform-api.svc.cluster.local, DNS:api.platform-api.svc
```

### 10.2 La API CertificateSigningRequest de Kubernetes

Kubernetes tiene una CA nativa propia, manejada por `certificates.k8s.io/v1`. Es así como los kubelets arrancan y rotan sus credenciales, y es una forma legítima de acuñar kubeconfigs de operadores.

```bash
$ openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out sre-alice.key.pem
$ openssl req -new -key sre-alice.key.pem \
    -subj "/O=platform-sre/O=readonly/CN=alice" -out sre-alice.csr.pem
$ base64 -w0 sre-alice.csr.pem
LS0tLS1CRUdJTiBDRVJUSUZJQ0FURSBSRVFVRVNULS0tLS0KTUlIcU1JR1JBZ0VBTURB...
```

`O=` se convierte en el grupo y `CN=` en el nombre de usuario dentro de RBAC de Kubernetes. Ese mapeo es la razón por la cual una CA en la que confía el API server equivale a cluster-admin salvo que esté restringida por nombre o acotada.

```yaml
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: sre-alice
spec:
  request: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURSBSRVFVRVNULS0tLS0KTUlIcU1JR1JBZ0VBTURB...
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: 2592000   # 30 days; the signer may cap this lower
  usages:
    - client auth
```

```bash
$ kubectl apply -f sre-alice-csr.yaml
certificatesigningrequest.certificates.k8s.io/sre-alice created

$ kubectl get csr sre-alice
NAME        AGE   SIGNERNAME                            REQUESTOR         REQUESTEDDURATION   CONDITION
sre-alice   8s    kubernetes.io/kube-apiserver-client   kubernetes-admin  30d                 Pending

$ kubectl certificate approve sre-alice
certificatesigningrequest.certificates.k8s.io/sre-alice approved

$ kubectl get csr sre-alice -o jsonpath='{.status.certificate}' | base64 -d > sre-alice.crt.pem
$ openssl x509 -in sre-alice.crt.pem -noout -subject -issuer -dates -ext extendedKeyUsage
subject=O=readonly + O=platform-sre, CN=alice
issuer=CN=kubernetes
notBefore=Aug 18 12:11:00 2026 GMT
notAfter=Sep 17 12:11:00 2026 GMT
X509v3 Extended Key Usage:
    TLS Web Client Authentication
```

| `signerName` | Firmado por | Usos permitidos | Propósito |
|---|---|---|---|
| `kubernetes.io/kube-apiserver-client` | CA del cluster | `client auth` | Kubeconfigs de humanos y controladores |
| `kubernetes.io/kube-apiserver-client-kubelet` | CA del cluster | `client auth` | Bootstrap y rotación del kubelet (auto-aprobado por un controlador) |
| `kubernetes.io/kubelet-serving` | CA del cluster | `server auth` | Certificados de servicio HTTPS del kubelet; **nunca auto-aprobados** |
| `kubernetes.io/legacy-unknown` | CA del cluster | cualquiera | Obsoleto; deshabilitado por defecto en versiones modernas |

**Estos certificados no se pueden revocar.** Kubernetes no tiene CRL ni OCSP; un certificado de cliente filtrado es válido hasta su `notAfter`. Las únicas remediaciones son rotar la CA completa del cluster (disruptivo) o dejar inertes los bindings de RBAC de esa identidad. Mantené `expirationSeconds` corto y tratá los certificados de cliente como segunda opción frente a OIDC para el acceso humano.

```bash
$ sudo kubeadm certs check-expiration
CERTIFICATE                EXPIRES                  RESIDUAL TIME   CERTIFICATE AUTHORITY   EXTERNALLY MANAGED
admin.conf                 Aug 18, 2027 09:14 UTC   364d            ca                      no
apiserver                  Aug 18, 2027 09:14 UTC   364d            ca                      no
apiserver-etcd-client      Aug 18, 2027 09:14 UTC   364d            etcd-ca                 no
apiserver-kubelet-client   Aug 18, 2027 09:14 UTC   364d            ca                      no
controller-manager.conf    Aug 18, 2027 09:14 UTC   364d            ca                      no
etcd-healthcheck-client    Aug 18, 2027 09:14 UTC   364d            etcd-ca                 no
etcd-peer                  Aug 18, 2027 09:14 UTC   364d            etcd-ca                 no
etcd-server                Aug 18, 2027 09:14 UTC   364d            etcd-ca                 no
front-proxy-client         Aug 18, 2027 09:14 UTC   364d            front-proxy-ca          no
scheduler.conf             Aug 18, 2027 09:14 UTC   364d            ca                      no

CERTIFICATE AUTHORITY   EXPIRES                  RESIDUAL TIME   EXTERNALLY MANAGED
ca                      Aug 15, 2036 09:14 UTC   9y              no
etcd-ca                 Aug 15, 2036 09:14 UTC   9y              no
front-proxy-ca          Aug 15, 2036 09:14 UTC   9y              no
```

Los certificados del plano de control de un año renovados únicamente por `kubeadm upgrade` son la causa más común de "el cluster desapareció de un día para el otro" en clusters de larga vida. Poné una alerta sobre esta salida que no dependa del calendario.

### 10.3 Vault PKI como el nivel emisor

```hcl
# Enable a mount per issuing tier, with a TTL ceiling enforced by the engine.
vault secrets enable -path=pki_tls -max-lease-ttl=87600h pki

# Vault generates the intermediate key internally; it never leaves the barrier.
vault write -format=json pki_tls/intermediate/generate/internal \
    common_name="Example Platform TLS Issuing CA E1" \
    key_type=ec key_bits=384 \
    | jq -r '.data.csr' > /tmp/vault-tls-ca.csr.pem

# ... sign it with the offline root (§5.5), then:
vault write pki_tls/intermediate/set-signed certificate=@/opt/pki/dist/vault-chain.pem

vault write pki_tls/config/urls \
    issuing_certificates="http://pki.example.io/v1/pki_tls/ca" \
    crl_distribution_points="http://pki.example.io/v1/pki_tls/crl" \
    ocsp_servers="http://pki.example.io/v1/pki_tls/ocsp"

vault write pki_tls/roles/internal-server \
    allowed_domains="internal.example.io,svc.cluster.local" \
    allow_subdomains=true allow_bare_domains=false allow_glob_domains=false \
    allow_ip_sans=false allow_wildcard_certificates=false \
    enforce_hostnames=true \
    key_type=ec key_bits=256 \
    server_flag=true client_flag=false \
    ext_key_usage="ServerAuth" \
    key_usage="DigitalSignature" \
    ttl=168h max_ttl=336h \
    no_store=false

vault write pki_tls/config/auto-tidy enabled=true \
    tidy_cert_store=true tidy_revoked_certs=true \
    safety_buffer=72h interval_duration=12h
```

El rol es el objeto de política: impone el espacio de nombres, el algoritmo, los usos de clave y el techo de TTL **del lado del servidor**, así que una credencial de aplicación comprometida sigue sin poder acuñar `*.example.io` ni un certificado de 10 años. Ese es el mismo control que `nameConstraints`, expresado en la capa de API en lugar de en el certificado.

---

## 11. Verificación y diagnóstico de fallas

### 11.1 La escalera de verificación — ejecutala entera en CI

```bash
# 1. Does the private key match the certificate? (algorithm-independent)
$ diff <(openssl x509 -in api.crt.pem -pubkey -noout | openssl pkey -pubin -outform DER | sha256sum) \
       <(openssl pkey -in api.key.pem -pubout -outform DER | sha256sum) \
  && echo "key/cert MATCH"
key/cert MATCH

# 2. Is the chain complete, correctly ordered and trusted?
$ openssl verify -CAfile /opt/pki/root/ca/root-ca.crt.pem \
    -untrusted /opt/pki/dist/example-ca-chain.pem \
    -x509_strict -purpose sslserver api.crt.pem
api.crt.pem: OK

# 3. Does the certificate actually cover the name we will serve?
$ openssl verify -CAfile /opt/pki/dist/example-ca-chain.pem \
    -verify_hostname api.internal.example.io api.crt.pem
api.crt.pem: OK

# 4. Will it still be valid in 30 days?  (-attime takes a Unix timestamp)
$ openssl verify -CAfile /opt/pki/dist/example-ca-chain.pem \
    -attime $(date -d '+30 days' +%s) api.crt.pem
api.crt.pem: OK

# 5. Not revoked, anywhere in the chain?
$ openssl verify -CAfile /opt/pki/dist/example-ca-chain.pem \
    -crl_check_all -CRLfile /etc/pki/tls/certs/example-all-crls.pem api.crt.pem
api.crt.pem: OK

# 6. What is on the wire right now?
$ openssl s_client -connect api.internal.example.io:443 \
    -servername api.internal.example.io \
    -verify_hostname api.internal.example.io \
    -CAfile /opt/pki/dist/example-ca-chain.pem \
    -verify_return_error -showcerts < /dev/null
```

Un `s_client` sano:

```
CONNECTED(00000003)
depth=2 C=AR, O=Example Platform Engineering, OU=Platform Security, CN=Example Platform Root CA R1
verify return:1
depth=1 C=AR, O=Example Platform Engineering, OU=Platform Security, CN=Example Platform TLS Issuing CA E1
verify return:1
depth=0 C=AR, O=Example Platform Engineering, OU=Platform, CN=api.internal.example.io
verify return:1
---
Certificate chain
 0 s:C=AR, O=Example Platform Engineering, OU=Platform, CN=api.internal.example.io
   i:C=AR, O=Example Platform Engineering, OU=Platform Security, CN=Example Platform TLS Issuing CA E1
   a:PKEY: id-ecPublicKey, 256 (bit); sigalg: ecdsa-with-SHA384
   v:NotBefore: Aug 18 09:31:02 2026 GMT; NotAfter: Nov 16 09:31:02 2026 GMT
-----BEGIN CERTIFICATE-----
MIICVjCCAdygAwIBAgIQL4jRBGs5rlfCEJ8zROgbdTAKBggqhkjOPQQDAzBrMQsw
...
-----END CERTIFICATE-----
 1 s:C=AR, O=Example Platform Engineering, OU=Platform Security, CN=Example Platform TLS Issuing CA E1
   i:C=AR, O=Example Platform Engineering, OU=Platform Security, CN=Example Platform Root CA R1
   a:PKEY: id-ecPublicKey, 384 (bit); sigalg: ecdsa-with-SHA384
   v:NotBefore: Aug 18 09:22:41 2026 GMT; NotAfter: Aug 16 09:22:41 2036 GMT
-----BEGIN CERTIFICATE-----
MIIC9zCCAn2gAwIBAgIQXHoek7D0Ri2KocNVfp0LQTAKBggqhkjOPQQDAzBrMQsw
...
-----END CERTIFICATE-----
---
Server certificate
subject=C=AR, O=Example Platform Engineering, OU=Platform, CN=api.internal.example.io
issuer=C=AR, O=Example Platform Engineering, OU=Platform Security, CN=Example Platform TLS Issuing CA E1
---
Peer signing digest: SHA384
Peer signature type: ECDSA
Server Temp Key: X25519, 253 bits
---
SSL handshake has read 2318 bytes and written 401 bytes
Verification: OK
---
New, TLSv1.3, Cipher is TLS_AES_256_GCM_SHA384
```

`Verification: OK` es sobre lo que afirmás. Notá también que `Certificate chain` lista exactamente dos entradas — hoja e intermedio. Si la entrada 2 es la raíz, estás desperdiciando bytes en cada handshake; si falta la entrada 1, tenés un incidente de error 20 esperando al primer cliente con caché fría.

**`-servername` no es opcional.** Sin él OpenSSL no envía SNI y un servidor con hosts virtuales devuelve su certificado por defecto — produciendo una "discordancia de nombre de host" que no existe para clientes reales, y ocultando una real que sí existe.

### 11.2 Códigos de error de `openssl verify` — la referencia de campo

| # | Símbolo / mensaje | Causa raíz | Solución |
|---|---|---|---|
| 2 | `unable to get issuer certificate` | El emisor de un intermedio no está en `-CAfile`/`-CApath` | Agregar la CA faltante |
| 3 | `unable to get certificate CRL` | `-crl_check` activo, sin CRL provista para alguna CA de la cadena | Proveer la CRL de cada CA (concatenarlas) |
| 7 | `certificate signature failure` | La firma no verifica — archivo corrupto, o una falsificación | Volver a descargar; si persiste, escalar |
| 9 | `certificate is not yet valid` | `notBefore` en el futuro — casi siempre **desfasaje del reloj del cliente** | Arreglar NTP antes de tocar la PKI |
| 10 | `certificate has expired` | Pasó el `notAfter` | Renovar. Después arreglar por qué no se renovó. |
| 12 | `CRL has expired` | Pasó el `nextUpdate` | Regenerar y republicar la CRL |
| 18 | `self-signed certificate` | La hoja misma está autofirmada | Emitir desde una CA, o agregarla como ancla deliberadamente |
| 19 | `self-signed certificate in certificate chain` | El servidor envió su raíz y el verificador no confía en ella | Instalar la raíz en el almacén de confianza; dejar de enviarla |
| 20 | `unable to get local issuer certificate` | **El servidor no envió el intermedio.** El bug de TLS #1 en el mundo real. | Servir hoja + intermedio (`fullchain.pem`) |
| 21 | `unable to verify the first certificate` | Solo se envió la hoja y no existe camino | Igual que el 20 |
| 23 | `certificate revoked` | Está revocado. | Emitir uno nuevo; investigar por qué fue revocado |
| 24 | `invalid CA certificate` | Un emisor carece de `basicConstraints CA:TRUE` | Re-emitir el intermedio con el perfil correcto |
| 26 | `unsupported certificate purpose` | El EKU no permite el rol solicitado (`-purpose sslserver` contra un certificado solo de `clientAuth`) | Corregir el perfil de emisión |
| 32 | `key usage does not include certificate signing` | Al intermedio le falta `keyCertSign` | Re-emitir el intermedio |
| 47 | `permitted subtree violation` | Un SAN cae fuera de las `nameConstraints` de la CA | Corregir el SAN, o ampliar la restricción en la raíz |
| 48 | `excluded subtree violation` | Un SAN cae dentro de un subárbol excluido | Ídem |
| 62 | `hostname mismatch` | Ninguna entrada de SAN coincide con el nombre; el CN solo ya no cuenta | Agregar el nombre al SAN y re-emitir |

### 11.3 Seis incidentes y sus firmas

**Intermedio faltante (error 20).** Funciona en tu navegador (que cacheó el intermedio de otro sitio, o siguió el AIA), falla en `curl`, Go y Java.

```bash
$ openssl s_client -connect api.example.io:443 -servername api.example.io < /dev/null 2>&1 | grep -E 'depth|Verification'
depth=0 CN=api.example.io
verify error:num=20:unable to get local issuer certificate
verify error:num=21:unable to verify the first certificate
Verification error: unable to get local issuer certificate

# Confirm what was actually sent
$ openssl s_client -connect api.example.io:443 -servername api.example.io -showcerts < /dev/null 2>/dev/null \
  | grep -c 'BEGIN CERTIFICATE'
1                      # <- should be 2 or more
```
Solución: `ssl_certificate` debe apuntar a `fullchain.pem`, no a `cert.pem`. Esta es la consecuencia más común de apuntar nginx al `cert.pem` de certbot.

**Cadena en el orden equivocado.** RFC 8446 exige que el certificado del emisor vaya primero, y que cada uno siguiente certifique al anterior. Algunos stacks reordenan; muchos no.
```bash
$ awk '/BEGIN CERT/{n++} {print > ("/tmp/c" n ".pem")}' fullchain.pem
$ for f in /tmp/c*.pem; do openssl x509 -in $f -noout -subject -issuer; done
subject=CN=Example Platform TLS Issuing CA E1     # <- CA first: WRONG
issuer=CN=Example Platform Root CA R1
subject=CN=api.internal.example.io
issuer=CN=Example Platform TLS Issuing CA E1
```

**Desfasaje del reloj (error 9).** Antes de diagnosticar una PKI, revisá el reloj:
```bash
$ timedatectl status | grep -E 'System clock|NTP service'
         System clock synchronized: no
              NTP service: inactive
```
Todo "certificate is not yet valid" en un host recién imageado es esto.

**Las crypto-policies de Fedora/RHEL rechazando una CA heredada.** Es la política del sistema, no OpenSSL, la que rechaza firmas SHA-1 o RSA de menos de 2048 bits:
```bash
$ curl -sS https://legacy.vendor.example/
curl: (35) OpenSSL/3.2.1: error:0A00018E:SSL routines::ca md too weak

$ update-crypto-policies --show
DEFAULT

# Scoped, reversible workaround while the vendor re-issues:
$ sudo update-crypto-policies --set DEFAULT:SHA1
Setting system policy to DEFAULT:SHA1
Note: System-wide crypto policies are applied on application start-up.
```
Este es un puente temporal. Registrá la excepción con fecha de vencimiento; no dejes que se vuelva la postura permanente.

**`openssl ca` negándose a emitir.**
```bash
$ openssl ca -config openssl-tls-ca.cnf -in dup.csr.pem -out dup.crt.pem
...
ERROR:There is already a certificate for /C=AR/O=Example Platform Engineering/CN=api.internal.example.io
```
→ `db/index.txt.attr` dice `unique_subject = yes`. Ponelo en `no`.

```bash
The organizationName field is different between
CA certificate (Example Platform Engineering) and the request (Example Platform Eng.)
```
→ `policy_strict` requiere `match` en `organizationName`. O arreglás el DN del CSR o relajás la política — nunca edites `index.txt` a mano para evitarlo.

```bash
$ openssl ca -config openssl-tls-ca.cnf -gencrl -out crl.pem
...
unable to load CRL number
```
→ `db/crlnumber` falta o está malformado. Debe contener una cadena hexadecimal de longitud par, por ejemplo `1000`.

**mTLS fallando con CRLs habilitadas en nginx.**
```
SSL_do_handshake() failed (SSL: error:0A000418:SSL routines::tlsv1 alert unknown ca)
... client SSL certificate verify error: (3:unable to get certificate CRL)
```
→ `ssl_crl` debe contener una CRL **vigente y no vencida** de *cada* CA de la cadena del cliente, incluida la raíz. Concatenalas y reconstruí el archivo desde el mismo timer que regenera las CRLs.

### 11.4 El monitoreo de vencimientos no es negociable

```yaml
# prometheus/rules/tls-expiry.yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: tls-certificate-expiry
  namespace: monitoring
  labels:
    prometheus: platform
    role: alert-rules
spec:
  groups:
    - name: tls-expiry
      rules:
        - alert: TLSCertificateExpiringSoon
          expr: |
            (probe_ssl_earliest_cert_expiry - time()) / 86400 < 21
            and
            (probe_ssl_earliest_cert_expiry - time()) / 86400 >= 7
          for: 30m
          labels:
            severity: warning
          annotations:
            summary: "TLS cert for {{ $labels.instance }} expires in {{ $value | humanizeDuration }}"
            runbook_url: "https://runbooks.example.io/pki/expiry"

        - alert: TLSCertificateExpiringCritical
          expr: (probe_ssl_earliest_cert_expiry - time()) / 86400 < 7
          for: 10m
          labels:
            severity: critical
            page: "true"
          annotations:
            summary: "TLS cert for {{ $labels.instance }} expires in under 7 days"
            description: "Automated renewal has not run. Investigate the ACME client or cert-manager before this becomes an outage."

        - alert: CertManagerCertificateNotReady
          expr: |
            certmanager_certificate_ready_status{condition="False"} == 1
          for: 15m
          labels:
            severity: warning
          annotations:
            summary: "cert-manager Certificate {{ $labels.namespace }}/{{ $labels.name }} is not Ready"

        - alert: CertManagerRenewalStalled
          expr: |
            (certmanager_certificate_expiration_timestamp_seconds - time()) / 86400 < 14
          for: 1h
          labels:
            severity: critical
          annotations:
            summary: "cert-manager cert {{ $labels.namespace }}/{{ $labels.name }} within 14d of expiry and not renewed"

        - alert: PKICRLStale
          expr: (pki_crl_next_update_timestamp_seconds - time()) < 86400
          for: 30m
          labels:
            severity: warning
          annotations:
            summary: "CRL for {{ $labels.ca }} expires within 24h — the refresh timer is not running"
```

Un barrido rápido de toda la flota sin ningún exporter:

```bash
$ for h in api.internal.example.io grafana.internal.example.io vault.internal.example.io; do
    exp=$(openssl s_client -connect "$h:443" -servername "$h" </dev/null 2>/dev/null \
          | openssl x509 -noout -enddate | cut -d= -f2)
    days=$(( ( $(date -d "$exp" +%s) - $(date +%s) ) / 86400 ))
    printf '%-38s %-32s %4d days\n' "$h" "$exp" "$days"
  done
api.internal.example.io                Nov 16 09:31:02 2026 GMT           90 days
grafana.internal.example.io            Sep  2 14:02:55 2026 GMT           15 days
vault.internal.example.io              Aug 24 08:00:00 2026 GMT            5 days
```

---

## 12. Asegurando la CA misma

Los certificados que emite una CA son tan confiables como la seguridad operativa de la propia CA. Ordenados por efectividad:

| Control | Qué detiene | Costo |
|---|---|---|
| **Clave raíz en un HSM / offline** | Exfiltración de la clave; falsificación indetectable | Hardware + disciplina de ceremonia |
| **Dos niveles con un intermedio `pathlen:0` y restringido por nombre** | Que un compromiso de la CA online se vuelva un compromiso de todo el espacio de nombres | Solo esfuerzo de diseño |
| **Vidas cortas de las hojas + automatización** | Caídas por vencimiento *y* vuelve irrelevantes las brechas de revocación | Construcción de la automatización |
| **Perfiles de emisión como código, `copy_extensions = none`** | Escalada de privilegios mediante un CSR manipulado | Disciplina de configuración |
| **Log de emisión append-only y monitoreado** | Emisión maliciosa silenciosa | Pipeline de logs |
| **Monitoreo de CT para tus propios dominios** | Mis-emisión por una CA de terceros | Suscripción al feed |
| **Roles separados (la RA aprueba ≠ la CA firma)** | Compromiso de un único operador | Proceso |

Protección de la clave privada en la práctica, de más débil a más fuerte:

1. PEM cifrado con passphrase en disco — la passphrase debe tipearse. Solo defendible para una raíz genuinamente offline.
2. Credenciales cifradas de `systemd-creds` atadas al TPM — usable para un intermedio desatendido en un solo host.
3. Token PKCS#11 (YubiHSM 2, Nitrokey HSM, SoftHSM para laboratorio) — la clave es no exportable.
4. HSM de red o KMS en la nube (Thales/Luna, AWS CloudHSM, GCP Cloud KMS) — no exportable, auditado, controlado por quórum.

```bash
# OpenSSL 3.x reaching an HSM through the pkcs11 provider
$ openssl req -new -x509 \
    -provider pkcs11 -provider default \
    -key "pkcs11:token=PlatformRoot;object=root-ca-key;type=private" \
    -config openssl-root.cnf -extensions v3_root_ca \
    -sha384 -days 7305 -out ca/root-ca.crt.pem

$ p11tool --list-all --login "pkcs11:token=PlatformRoot"
Object 0:
	URL: pkcs11:model=YubiHSM;manufacturer=Yubico;serial=0002468;token=PlatformRoot;id=%01%00;object=root-ca-key;type=private
	Type: Private key (EC/ECDSA-SECP384R1)
	Label: root-ca-key
	Flags: CKA_PRIVATE; CKA_NEVER_EXTRACTABLE; CKA_SENSITIVE;
```

`CKA_NEVER_EXTRACTABLE` es la propiedad sobre la que descansa todo el diseño: la clave nunca existió fuera del módulo, así que "respaldar la clave raíz" se reemplaza por "aprovisionar un quórum de custodios de clave" — un problema distinto, y mejor.

**Guion mínimo viable de ceremonia de claves:** dos operadores presentes, una máquina aislada arrancada desde medio de solo lectura, grabación en video, generación en el HSM, impresión y división de las partes de recuperación (Shamir, k-de-n), firma del intermedio, verificación de la firma en una segunda máquina, registro de números de serie y huellas SHA-256 en un acta a prueba de manipulación, apagado. Si tu raíz no está en un HSM, como mínimo el material de clave y la passphrase deben estar en manos de personas distintas en cajas fuertes distintas.

---

## 13. Cobertura del objetivo — checklist de 331.1

| Elemento del objetivo | Sección | Comandos que tenés que poder producir de memoria |
|---|---|---|
| Estructura, campos y extensiones v3 de un certificado X.509 | §2 | `openssl x509 -in c.pem -noout -text -ext subjectAltName`, `openssl asn1parse` |
| Ciclo de vida del certificado | §5–§7, §9 | `openssl req`, `openssl ca`, `openssl ca -revoke`, `openssl ca -gencrl` |
| Cadenas de confianza y PKI | §4, §5, §11 | `openssl verify -CAfile -untrusted`, `openssl s_client -showcerts` |
| Certificate Transparency | §8 | `openssl x509 -noout -ext ct_precert_scts` |
| Generar y gestionar claves | §3 | `openssl genpkey`, `openssl rsa/ec/pkey`, `openssl pkey -pubout` |
| Crear, operar y asegurar una CA | §5, §12 | `openssl.cnf` completo, semántica de `index.txt`, `serial`, `crlnumber` |
| Solicitar, firmar y gestionar certificados de servidor y cliente | §6 | `openssl req -new -addext`, `openssl ca -extensions`, `openssl pkcs12 -export` |
| Revocar certificados y CAs | §7 | `openssl ca -revoke -crl_reason`, `openssl crl`, `openssl ocsp` |
| Formatos PEM / DER / PKCS | §2.3 | `openssl x509 -inform DER -outform PEM`, `openssl pkcs12`, `openssl crl2pkcs7` |
| Conocimiento de ACME | §9 | `certbot certonly`, `certbot renew --dry-run`, tipos de desafío |
| Configuración de OpenSSL | §5.2, §5.4 | `[ca]`, `[CA_default]`, `[req]`, `policy_*`, `copy_extensions`, `x509_extensions` |

Conversiones de formato que vale la pena practicar:

```bash
$ openssl x509 -in cert.pem -outform DER -out cert.der          # PEM -> DER
$ openssl x509 -inform DER -in cert.der -out cert.pem           # DER -> PEM
$ openssl pkcs12 -export -inkey k.pem -in c.pem -certfile ch.pem -out b.p12
$ openssl pkcs12 -in b.p12 -nokeys -out certs.pem               # P12 -> certs
$ openssl pkcs12 -in b.p12 -nocerts -noenc -out key.pem         # P12 -> key
$ openssl crl2pkcs7 -nocrl -certfile ch.pem -out ch.p7b         # PEM -> PKCS#7
$ openssl pkcs7 -in ch.p7b -print_certs -out ch.pem             # PKCS#7 -> PEM
$ openssl pkey -in pkcs1.pem -out pkcs8.pem                     # PKCS#1 -> PKCS#8
$ openssl crl -in crl.pem -outform DER -out crl.crl             # CRL PEM -> DER
```

Comandos de inspección de una línea:

```bash
$ openssl x509 -in c.pem -noout -fingerprint -sha256
sha256 Fingerprint=3A:6F:...:D2
$ openssl x509 -in c.pem -noout -serial -subject -issuer -dates -purpose
$ openssl x509 -in c.pem -noout -modulus | openssl sha256      # RSA key matching
$ openssl x509 -in c.pem -pubkey -noout | openssl pkey -pubin -outform DER \
    | openssl dgst -sha256 -binary | base64                    # SPKI pin (any algorithm)
```

---

## 14. Guía de decisión consolidada

| Situación | Hacé esto | No esto |
|---|---|---|
| TLS de cara a internet | CA pública vía ACME, ≤90 días, renovación automatizada + deploy hook, monitoreado con CT | Un certificado de 1 año renovado a mano |
| Servicio a servicio dentro de un cluster | CA privada de dos niveles manejada por cert-manager o SPIFFE/SPIRE, vida de horas a días | Certificados autofirmados con la verificación deshabilitada |
| Entregar una CA a otro equipo | Intermedio restringido por nombre, `pathlen:0`, o un rol de Vault con `allowed_domains` | Una sub-CA sin restricciones |
| Autenticación de clientes | Certificados solo de `clientAuth` de vida corta, u OIDC donde la plataforma lo soporte | Certificados de cliente de larga vida sin camino de revocación |
| Appliance heredado que requiere RSA-2048/SHA-256 | Jerarquía paralela aislada con fecha de retiro documentada | Degradar la política criptográfica de todo el parque |
| Requisito de revocación de una auditoría | Publicar CRLs con un timer, hard-fail donde controlás ambas puntas, y reducir la vida útil | OCSP en soft-fail y llamarlo un control |
| Almacenamiento de la clave raíz | HSM, offline, controlada por quórum, ceremonia registrada | PEM cifrado en el runner de CI |

El hilo conductor: **X.509 no es difícil porque la criptografía sea difícil — es difícil porque codifica autoridad delegada y de larga vida en un sistema distribuido donde nada se puede retirar.** Cada buena práctica de arriba es una variación de un solo principio: achicá la ventana durante la cual un error sigue siendo verdadero, y acotá criptográficamente lo que cualquier error individual puede afirmar.

---

## 15. Referencias

**LPI**
- Objetivos del examen 303-300 (LPIC-3 Security): https://www.lpi.org/our-certifications/exam-303-objectives/
- Panorama de LPIC-3 Security: https://www.lpi.org/our-certifications/lpic-3-303-overview/

**Estándares del IETF**
- RFC 5280 — Internet X.509 PKI Certificate and CRL Profile: https://www.rfc-editor.org/rfc/rfc5280
- RFC 6960 — Online Certificate Status Protocol (OCSP): https://www.rfc-editor.org/rfc/rfc6960
- RFC 6962 — Certificate Transparency: https://www.rfc-editor.org/rfc/rfc6962
- RFC 8555 — Automatic Certificate Management Environment (ACME): https://www.rfc-editor.org/rfc/rfc8555
- RFC 8737 — ACME TLS-ALPN-01 Challenge Extension: https://www.rfc-editor.org/rfc/rfc8737
- RFC 7633 — X.509 TLS Feature Extension (Must-Staple): https://www.rfc-editor.org/rfc/rfc7633
- RFC 6125 — Identity Verification in PKIX-based TLS: https://www.rfc-editor.org/rfc/rfc6125
- RFC 8446 — TLS 1.3: https://www.rfc-editor.org/rfc/rfc8446
- RFC 2986 — PKCS #10 Certification Request Syntax: https://www.rfc-editor.org/rfc/rfc2986
- RFC 5208 / RFC 5958 — PKCS #8 Private-Key Information Syntax: https://www.rfc-editor.org/rfc/rfc5958
- RFC 7292 — PKCS #12 Personal Information Exchange Syntax: https://www.rfc-editor.org/rfc/rfc7292
- RFC 5652 — Cryptographic Message Syntax (PKCS #7): https://www.rfc-editor.org/rfc/rfc5652

**Páginas de manual de OpenSSL 3.x**
- `openssl-req`: https://docs.openssl.org/master/man1/openssl-req/
- `openssl-ca`: https://docs.openssl.org/master/man1/openssl-ca/
- `openssl-x509`: https://docs.openssl.org/master/man1/openssl-x509/
- `openssl-verify` y errores de verificación: https://docs.openssl.org/master/man1/openssl-verify/
- `openssl-genpkey`: https://docs.openssl.org/master/man1/openssl-genpkey/
- `openssl-crl` / `openssl-ocsp`: https://docs.openssl.org/master/man1/openssl-crl/ · https://docs.openssl.org/master/man1/openssl-ocsp/
- `openssl-pkcs12`: https://docs.openssl.org/master/man1/openssl-pkcs12/
- `openssl-s_client`: https://docs.openssl.org/master/man1/openssl-s_client/
- `x509v3_config` (sintaxis de extensiones): https://docs.openssl.org/master/man5/x509v3_config/
- `config` (formato del archivo de configuración de OpenSSL): https://docs.openssl.org/master/man5/config/

**CA/Browser Forum y política de CAs**
- Baseline Requirements for TLS Server Certificates: https://cabforum.org/working-groups/server/baseline-requirements/documents/
- Balota SC-081v3 (cronograma de reducción del período de validez): https://cabforum.org/2025/04/11/ballot-sc081v3-introduce-schedule-of-reducing-validity-and-data-reuse-periods/
- Mozilla Root Store Policy: https://www.mozilla.org/en-US/about/governance/policies/security-group/certs/policy/
- Chromium Certificate Transparency Policy: https://googlechrome.github.io/CertificateTransparency/ct_policy.html

**ACME y clientes**
- Let's Encrypt — cómo funciona: https://letsencrypt.org/how-it-works/
- Let's Encrypt — tipos de desafío: https://letsencrypt.org/docs/challenge-types/
- Let's Encrypt — fin del soporte de OCSP: https://letsencrypt.org/2024/07/23/replacing-ocsp-with-crls/
- Documentación de Certbot: https://eff-certbot.readthedocs.io/en/stable/
- acme.sh: https://github.com/acmesh-official/acme.sh
- lego: https://go-acme.github.io/lego/
- step-ca (servidor ACME privado): https://smallstep.com/docs/step-ca/

**Kubernetes y herramientas de plataforma**
- Managing TLS Certificates in a Cluster: https://kubernetes.io/docs/tasks/tls/managing-tls-in-a-cluster/
- Certificate Signing Requests (`certificates.k8s.io`): https://kubernetes.io/docs/reference/access-authn-authz/certificate-signing-requests/
- Certificate Management with kubeadm: https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-certs/
- Documentación de cert-manager: https://cert-manager.io/docs/
- Motor de secretos PKI de HashiCorp Vault: https://developer.hashicorp.com/vault/docs/secrets/pki

**Almacenes de confianza de las distribuciones**
- Certificados compartidos del sistema en Fedora/RHEL: https://docs.fedoraproject.org/en-US/quick-docs/using-shared-system-certificates/
- Políticas criptográficas de todo el sistema en Red Hat: https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/security_hardening/using-the-system-wide-cryptographic-policies_security-hardening
- `update-ca-certificates` de Debian: https://manpages.debian.org/stable/ca-certificates/update-ca-certificates.8.en.html
- Módulo de confianza p11-kit: https://p11-glue.github.io/p11-glue/p11-kit.html

**Configuración del servidor**
- `ngx_http_ssl_module` de nginx: https://nginx.org/en/docs/http/ngx_http_ssl_module.html
- Mozilla SSL Configuration Generator: https://ssl-config.mozilla.org/

**Ecosistema de Certificate Transparency**
- Proyecto Certificate Transparency: https://certificate.transparency.dev/
- Búsqueda en logs de crt.sh: https://crt.sh/