# 331.2 — Certificados X.509 para cifrado, firma y autenticación

**Certificación:** LPIC-3 Security — examen 303-300, versión 3.0.0
**Peso del tema:** 6.67
**Prerrequisito:** 331.1 (X.509, PKI, operación de una CA, emisión de CRL/OCSP)

---

## 0. Mapa de objetivos

331.1 enseñaba a *fabricar* certificados. 331.2 trata de *consumirlos* dentro de un protocolo vivo — TLS — y el único servidor que el examen evalúa es Apache HTTPD con `mod_ssl`. Esta tabla es el contrato entre el texto de los objetivos de LPI y lo que realmente tenés que ser capaz de tipear.

| Área de conocimiento (LPI) | Dónde vive en producción | Herramientas principales |
|---|---|---|
| SSL, TLS y versiones del protocolo | `SSLProtocol`, `MinProtocol` de OpenSSL | `openssl s_client -tls1_2`, `nmap --script ssl-enum-ciphers` |
| Amenazas de la capa de transporte (MITM) | HSTS, validación de cadena, CT, CAA, pinning | `openssl s_client`, `curl -v` |
| Autoridades de certificación intermedias | cadena servida por el servidor, no por el cliente | `openssl verify -untrusted` |
| Configuración de cifradores | `SSLCipherSuite`, `SSLHonorCipherOrder`, `SSLOpenSSLConfCmd` | `openssl ciphers -v` |
| HTTPS con `mod_ssl`, incl. SNI y HSTS | `<VirtualHost *:443>`, `Header always set` | `apachectl -S`, `-t` |
| Autenticación por certificado de cliente | `SSLVerifyClient`, `SSLVerifyDepth`, `SSLCACertificateFile` | `openssl s_client -cert/-key` |
| OCSP stapling | `SSLUseStapling`, `SSLStaplingCache` | `openssl s_client -status` |
| Pruebas de cliente/servidor con OpenSSL | `s_client`, `s_server`, `x509`, `verify`, `ocsp` | — |

**Términos y utilidades que se espera que reconozcas:** `httpd.conf`, `mod_ssl`, `openssl`, CAs intermedias, configuración de cifradores (no se requiere detalle interno de los cifradores).

---

## 1. El problema arquitectónico

Operás una plataforma con ~200 servicios HTTP. Llegan tres requisitos en el mismo trimestre:

1. **Regulatorio:** todo el tráfico cifrado en tránsito, incluido el este-oeste dentro del clúster, con prueba auditable de *qué* servicio habló con cuál.
2. **Operativo:** un certificado wildcard se vio comprometido el año pasado; la respuesta al incidente llevó 9 horas porque nadie sabía cuál de los 200 servicios lo portaba. Nunca más.
3. **Disponibilidad:** el vencimiento de un certificado a las 03:00 UTC tiró el checkout durante 40 minutos. El monitoreo vigilaba códigos HTTP 200, y el LB seguía devolviendo 200 sobre una página cacheada rancia mientras cada handshake TLS nuevo fallaba.

Cada uno de esos es un problema de X.509, y cada uno se corresponde con un *uso* distinto del certificado — que es exactamente lo que enumera el título del objetivo:

| Uso | Qué hace el certificado | Dónde en TLS |
|---|---|---|
| **Cifrado** | su clave pública cifra un secreto en tránsito | *solo* en TLS ≤ 1.2 con transporte de clave RSA estático (`TLS_RSA_WITH_*`) — eliminado en TLS 1.3 |
| **Firma** | su clave privada firma material del handshake, probando presencia viva | `ServerKeyExchange` (TLS 1.2 ECDHE/DHE), `CertificateVerify` (TLS 1.3) |
| **Autenticación** | la cadena vincula la clave a un nombre en el que confía la parte que valida | validación de ruta (RFC 5280) + verificación de nombre (RFC 6125) |

El malentendido más común de este tema: *"el certificado cifra el tráfico"*. En un handshake TLS 1.3 moderno el certificado **nunca cifra nada**. El acuerdo de claves es (EC)DHE; el certificado existe únicamente para que el cliente pueda comprobar que quien está haciendo el Diffie–Hellman es el dueño del nombre. Si recordás una sola frase de 331.2, que sea esa — explica por qué el tamaño de clave RSA vs ECDSA afecta la *CPU del handshake* y no la *fortaleza del cifrado en bloque*, y por qué el forward secrecy es siquiera posible.

### 1.1 Dónde terminás el TLS es una decisión arquitectónica

| Punto de terminación | ¿mTLS posible extremo a extremo? | Cantidad de certs | Radio de impacto | Observabilidad | Falla típica |
|---|---|---|---|---|---|
| Solo LB de borde / CDN | No — la identidad del cliente muere en el borde | 1 (wildcard) | Enorme: una clave, todo el parque | Logs L7 completos en el borde | Compromiso del wildcard = rotación de toda la flota |
| Controlador de ingress, recifrado hacia el backend | Parcial (identidad del LB, no del cliente) | 1 de borde + N internos | Medio | L7 en el ingress | Dos almacenes de confianza que mantener sincronizados |
| **Ingress con SSL passthrough → `mod_ssl` en el pod** | **Sí** | N certificados de entidad final | Pequeño, por servicio | L4 en el ingress, L7 en el pod | El ingress no puede enrutar por path, solo por SNI |
| Sidecar de service mesh (SPIFFE) | Sí, automático | N (de vida corta) | Ínfimo (certs de 1 h) | Telemetría del mesh | El mesh es todo otro plano de control |
| TLS dentro del proceso de la app | Sí | N | Pequeño | Depende de la app | Cada lenguaje reimplementa mal la verificación |

Para el examen, y para el laboratorio de §12, la fila interesante es la tercera: passthrough enrutado por SNI con `mod_ssl` haciendo tanto autenticación de servidor como de cliente. Es la única forma en la que todas las directivas de 331.2 son simultáneamente relevantes.

---

## 2. Mecánica del protocolo

### 2.1 Versiones

| Versión | RFC | Año | Estado hoy | Notas para el examen |
|---|---|---|---|---|
| SSL 2.0 | — | 1995 | Prohibido (RFC 6176) | Sin integridad del handshake; no se compila en OpenSSL moderno |
| SSL 3.0 | RFC 6101 | 1996 | Prohibido (RFC 7568) | POODLE; el origen del token `SSLv3` en las configuraciones |
| TLS 1.0 | RFC 2246 | 1999 | Obsoleto (RFC 8996) | BEAST; PCI DSS lo eliminó en 2018 |
| TLS 1.1 | RFC 4346 | 2006 | Obsoleto (RFC 8996) | IV explícito; ninguna otra razón para existir |
| **TLS 1.2** | RFC 5246 | 2008 | Soportado | AEAD, PRF SHA-256, `signature_algorithms` |
| **TLS 1.3** | RFC 8446 | 2018 | Preferido | 1-RTT, handshake cifrado, PFS obligatorio |

`SSLProtocol` usa los nombres históricos de los tokens sin importar cómo se llamen en el cable. `SSLv23` no es una versión — es el método de OpenSSL de "negociar la mejor versión soportada mutuamente", que es la razón por la que `all` se comporta como se comporta.

```apache
# Both forms are legal; the subtractive form is the idiomatic one.
SSLProtocol all -SSLv3 -TLSv1 -TLSv1.1
# Equivalent, and much harder to get wrong when a new version ships:
SSLProtocol -all +TLSv1.2 +TLSv1.3
```

> Trampa: `SSLProtocol` dentro de un `<VirtualHost>` aplica a toda la *conexión*, y el protocolo de la conexión se elige antes de que SNI haya seleccionado un vhost en algunas rutas de código. Las diferencias de `SSLProtocol` por vhost sobre la misma IP:puerto no son confiables. Definí la política de protocolo globalmente; variá los certificados por vhost, no las versiones del protocolo.

### 2.2 Flujo del handshake, y exactamente dónde aparece el certificado

**TLS 1.2, `ECDHE_RSA_WITH_AES_128_GCM_SHA256`:**

```
Client                                               Server
ClientHello (versions, cipher list, SNI, sig_algs)  →
                                     ← ServerHello (chosen suite)
                                     ← Certificate      [leaf + intermediates]
                                     ← ServerKeyExchange[EC params, SIGNED with cert key]
                                     ← CertificateRequest    (only if client auth)
                                     ← ServerHelloDone
Certificate            (only if client auth)        →
ClientKeyExchange      [client EC pubkey]           →
CertificateVerify      [SIGNED with client key]     →
ChangeCipherSpec, Finished                          →
                                     ← ChangeCipherSpec, Finished
        ---- application data ----     2 RTT
```

**TLS 1.3:**

```
Client                                               Server
ClientHello (key_share, sig_algs, SNI, ALPN)        →
                                     ← ServerHello (key_share)
                            {EncryptedExtensions}
                            {CertificateRequest}      (only if client auth)
                            {Certificate}             ← ENCRYPTED
                            {CertificateVerify}       ← signature over transcript
                            {Finished}
{Certificate}, {CertificateVerify}   (client auth)  →
{Finished}                                          →
        ---- application data ----     1 RTT
```

Tres consecuencias sobre las que te van a preguntar, directa o indirectamente:

- **El certificado del servidor va cifrado en TLS 1.3.** Un observador pasivo ve el SNI en el ClientHello, pero no el certificado. Cualquier monitoreo o IDS que identificara servicios raspando el certificado del cable se rompió el día que habilitaste TLS 1.3. (Encrypted Client Hello, RFC 9540 / draft-ietf-tls-esni, también cierra el agujero del SNI — no está en los objetivos de 303-300, pero es la razón por la que el enrutamiento basado en SNI tiene fecha de vencimiento.)
- **La renegociación no existe en TLS 1.3.** Que `openssl s_client` imprima `Secure Renegotiation IS NOT supported` contra un servidor TLS 1.3 es *salida correcta*, no un hallazgo. Este es el falso positivo más frecuente en los informes de los escáneres de vulnerabilidades.
- **La autenticación de cliente por directorio no puede usar renegociación.** Ver §9.3.

### 2.3 Anatomía de una suite de cifrado

```
TLS 1.2:  ECDHE - ECDSA - WITH - AES_128_GCM - SHA256
          │       │             │              └── PRF hash / MAC
          │       │             └── bulk AEAD
          │       └── certificate/authentication algorithm
          └── key exchange

TLS 1.3:  TLS_AES_128_GCM_SHA256
          └── AEAD + hash ONLY. Key exchange and authentication
              are negotiated separately (supported_groups, signature_algorithms).
```

Esa separación es la razón por la que `SSLCipherSuite` incorporó un argumento de protocolo en httpd 2.4.36:

```apache
SSLCipherSuite       ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:...
SSLCipherSuite TLSv1.3 TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:TLS_AES_128_GCM_SHA256
```

La primera línea no puede restringir TLS 1.3 y la segunda no puede restringir TLS 1.2. Configurar una y esperar que cubra ambas es un error de configuración clásico.

| Política | `SSLProtocol` | Suites | Piso de clientes | Usala cuando |
|---|---|---|---|---|
| Modern | `-all +TLSv1.3` | solo los valores por defecto de TLS 1.3 | Firefox 63, Chrome 70, OpenSSL 1.1.1 | APIs internas, productos nuevos |
| Intermediate | `all -SSLv3 -TLSv1 -TLSv1.1` | ECDHE+AEAD, sin kx RSA | Firefox 27, Android 4.4.2, Java 8u31 | Web pública, elección por defecto |
| Old | `all -SSLv3` | + CBC, + kx RSA | IE8/XP, Java 6 | Solo con una fecha de vencimiento documentada |

`SSLHonorCipherOrder on` hace que la lista del servidor sea la autoritativa. La guía actual de Mozilla es `off` para Intermediate, porque cada suite restante es segura y dejar elegir al cliente permite que un teléfono prefiera ChaCha20 (rápido sin AES-NI) por sobre AES-GCM. Ponelo en `on` solo cuando tu lista esté deliberadamente ordenada por una razón que puedas explicar.

### 2.4 Grupos y algoritmos de firma

`mod_ssl` expone directamente los comandos de configuración de OpenSSL:

```apache
SSLOpenSSLConfCmd Groups           X25519:secp256r1:secp384r1
SSLOpenSSLConfCmd SignatureAlgorithms ECDSA+SHA256:ECDSA+SHA384:RSA-PSS+SHA256:RSA+SHA256
SSLOpenSSLConfCmd MinProtocol      TLSv1.2
SSLOpenSSLConfCmd Options          -SessionTicket
```

`Curves` es la grafía previa a 1.1.1 de `Groups`; ambas se aceptan. Notá que quitar `secp256r1` de `Groups` rompe *todos* los clientes que solo ofrecen P-256 en su `key_share`, y la falla es `no shared group` — una alerta 40, no un error de certificado. Una mala configuración de grupos se disfraza de problema de cifradores.

---

## 3. Modelo de amenazas de la capa de transporte

| Amenaza | Mecanismo | Qué la detiene realmente | Perilla de configuración |
|---|---|---|---|
| **MITM en la ruta (activo)** | El atacante termina el TLS con su propio certificado | Validación de cadena + verificación de nombre en el cliente | almacén de confianza del cliente; `SSLProxyVerify` cuando *vos* sos el cliente |
| **CA maliciosa o coaccionada** | Cadena válida hacia una CA en la que confiás, sujeto incorrecto | Certificate Transparency, registros CAA, name constraints en CAs privadas | `CAA` en DNS, `nameConstraints` en la intermedia |
| **SSL stripping** | Degradar `https://` a `http://` antes de que empiece el TLS | **HSTS**, idealmente con preload | `Strict-Transport-Security` |
| **Degradación de versión** | Reintento forzado en una versión menor | `TLS_FALLBACK_SCSV` (RFC 7507); centinela de degradación de TLS 1.3 en el server random | automático en OpenSSL ≥ 1.0.1j |
| **Renegociación insegura** | Inyección de prefijo (CVE-2009-3555) | Renegociación segura RFC 5746 | `SSLInsecureRenegotiation off` (por defecto) |
| **Oráculo de compresión (CRIME)** | La compresión a nivel TLS filtra secretos | Deshabilitar la compresión TLS | `SSLCompression off` (por defecto desde 2.4.3) |
| **BREACH** | gzip a nivel HTTP + secreto reflejado | Enmascarar tokens CSRF; no comprimir respuestas que porten secretos | a nivel de aplicación |
| **POODLE / Lucky13** | Oráculo de padding CBC | Descartar SSLv3, preferir AEAD | `SSLProtocol`, `SSLCipherSuite` |
| **SWEET32** | Cota del cumpleaños en cifradores de bloque de 64 bits | Eliminar 3DES | cadena de cifradores `!3DES` |
| **FREAK / Logjam** | RSA/DH de grado exportación forzados | Eliminar EXPORT, DH ≥ 2048 | `!EXP`, `SSLOpenSSLConfCmd DHParameters` |
| **ROBOT** | Oráculo de padding RSA PKCS#1 v1.5 | Eliminar el intercambio de claves RSA estático | `!kRSA` |
| **Heartbleed** | Lectura fuera de límites del heartbeat de OpenSSL | Parchear; **rotar la clave**, no solo el certificado | higiene de paquetes |
| **Certificado vencido / revocado aceptado** | El cliente omite la verificación de revocación (soft-fail) | **OCSP stapling** + `status_request` must-staple | `SSLUseStapling` |
| **Clave del servidor robada** | El atacante descifra tráfico grabado | Forward secrecy: solo ECDHE | `!kRSA` |

Dos de estas merecen sección propia porque *son* viñetas explícitas de los objetivos: HSTS (§8) y OCSP stapling (§10).

### 3.1 Por qué la revocación es el eslabón débil

La cadena de custodia de "este certificado ya no es válido" está genuinamente rota en la PKI web pública:

| Mecanismo | Quién lo descarga | Privacidad | Costo de latencia | Modo de falla |
|---|---|---|---|---|
| CRL | cliente → CA | no filtra nada por certificado | descarga grande, cacheada | los navegadores en gran medida dejaron de hacerlo |
| OCSP (dirigido por el cliente) | cliente → responder de la CA | **la CA aprende cada sitio que visitás** | +1 RTT + DNS en la primera visita | soft-fail: responder caído ⇒ se acepta |
| **OCSP stapling** | **servidor → CA, periódicamente** | ninguna | cero para el cliente | el servidor tiene un staple rancio o ausente |
| Must-staple (RFC 7633) | servidor, forzado | ninguna | cero | **hard-fail**: sin staple ⇒ sitio caído |
| CRLite / CRLSets | empuje del fabricante del navegador | ninguna | cero | específico del fabricante, no lo operás vos |

El stapling mueve la descarga de N clientes a 1 servidor, que es por lo que está en los objetivos. Must-staple convierte un soft-fail de seguridad en un hard-fail de disponibilidad; desplegalo solo con monitoreo que alerte sobre la antigüedad del staple.

---

## 4. La cadena de confianza y las CAs intermedias

### 4.1 Por qué existen las intermedias

La clave privada de una CA raíz es la joya de la corona: vive en un HSM, en una caja fuerte, apagada, con actas de ceremonia. No puede estar en línea firmando 40 000 certificados por día. Así que firma exactamente una cosa — una **CA intermedia** — y la intermedia hace el trabajo cotidiano.

Consecuencias operativas, todas las cuales aparecen en incidentes:

- Si la intermedia se ve comprometida, revocás *a ella*, no a la raíz. Los clientes siguen confiando en la raíz; vos emitís una intermedia nueva. El radio de impacto está acotado por lo emitido por la intermedia, no por todo el almacén de confianza.
- Los certificados raíz se propagan a los almacenes de confianza de los clientes a lo largo de *años*. Las intermedias se propagan con una única recarga del servidor. Esa asimetría es todo el diseño.
- `pathlen:0` en la intermedia significa que puede emitir certificados de entidad final pero no más CAs. Ponelo siempre.
- `nameConstraints` en una intermedia privada es el control de mayor apalancamiento de todo este tema: una intermedia restringida a `permitted;DNS:example.internal` no puede acuñar un `google.com` válido ni aunque le roben la clave — siempre que el cliente que valida haga cumplir las name constraints (OpenSSL, NSS y Go lo hacen; algunas pilas embebidas no).

### 4.2 Construcción de la cadena y validación de ruta

La validación (RFC 5280 §6) camina desde la hoja hasta un ancla de confianza, verificando en cada eslabón:

1. El `Issuer` del hijo == el `Subject` del padre (DN comparable byte a byte).
2. La firma del hijo verifica con la clave pública del padre.
3. El `Authority Key Identifier` del hijo coincide con el `Subject Key Identifier` del padre (la vía rápida; la coincidencia de DN es la normativa).
4. El padre tiene `basicConstraints: CA:TRUE` y `keyUsage: keyCertSign`.
5. No se excede `pathlen`; las ventanas de validez están anidadas; se satisfacen las name constraints.
6. El `extendedKeyUsage` de la hoja incluye `serverAuth`; el nombre de host solicitado coincide con un **dNSName** de `subjectAltName` (RFC 6125 — el respaldo por `CN` fue eliminado por Chrome en la versión 58 y por la política por defecto de verificación de host de OpenSSL).

**El trabajo del servidor es enviar la hoja más cada intermedia, en orden, y *no* la raíz.** Enviar la raíz desperdicia bytes en cada handshake; omitir una intermedia produce la falla de TLS más común del mundo:

```
verify error:num=20:unable to get local issuer certificate
```

Notá la asimetría que hace esto tan pernicioso: los navegadores a menudo se recuperan mediante **AIA chasing** (buscan la intermedia faltante en la URL `caIssuers` de la extensión Authority Information Access de la hoja). `openssl s_client`, Java, Go y la mayoría de los clientes HTTP de los lenguajes **no**. Así que el sitio "funciona en mi navegador" y falla en cada llamada servicio a servicio. Probá siempre con `openssl s_client`, nunca con un navegador.

### 4.3 Qué archivo va en qué directiva

| Directiva | Contiene | Dirección | Notas |
|---|---|---|---|
| `SSLCertificateFile` | certificado hoja; desde 2.4.8 puede contener también la cadena **y** la clave | servidor → cliente | Puede repetirse para certificados duales RSA + ECDSA |
| `SSLCertificateKeyFile` | la clave privada | nunca se envía | Omitila solo si la clave está dentro de `SSLCertificateFile` |
| `SSLCertificateChainFile` | intermedias (sin hoja, sin raíz) | servidor → cliente | **Obsoleta en 2.4.8** — concatenala dentro de `SSLCertificateFile` |
| `SSLCACertificateFile` | anclas de confianza para **verificar clientes** | nunca se envía como cadena | Un único PEM concatenado |
| `SSLCACertificatePath` | lo mismo, un certificado por archivo | — | Requiere enlaces simbólicos con hash: `openssl rehash <dir>` |
| `SSLCADNRequestFile` / `Path` | nombres de CA anunciados en el `CertificateRequest` | servidor → cliente | Desacopla "en qué confío" de "qué anuncio" |
| `SSLCARevocationFile` / `Path` | CRLs para certificados de cliente | — | Necesita `SSLCARevocationCheck` |
| `SSLProxyCACertificateFile` | anclas de confianza cuando httpd es el **cliente** | — | Almacén de confianza completamente separado |

El orden de concatenación en `SSLCertificateFile` es **primero la hoja, después cada emisor en orden**. El orden invertido hace que algunos clientes fallen y otros funcionen, que es la peor experiencia de depuración posible.

### 4.4 La lección de las firmas cruzadas

Dos caídas de producción que todo ingeniero de plataforma debería conocer, porque ambas son fallas puras de construcción de cadena:

- **AddTrust External CA Root, 30 de mayo de 2020.** La *raíz* venció. Los servidores seguían haciendo stapling de una cadena que terminaba en ella. Los clientes modernos (que tenían la raíz `USERTrust` más nueva y podían construir una ruta alternativa) estaban bien; OpenSSL 1.0.x y pilas más viejas no — porque OpenSSL 1.0.x construye exactamente una cadena y falla, mientras que OpenSSL 1.1.0+ reintenta rutas alternativas.
- **DST Root CA X3, 30 de septiembre de 2021.** Venció la firma cruzada de Let's Encrypt. Android 7.0 y anteriores sobrevivieron (ignoran el notAfter del ancla de confianza); OpenSSL 1.0.2 murió. El arreglo fue *acortar* la cadena servida, quitando la firma cruzada.

Conclusión: **la cadena que servís es una decisión de configuración en tiempo de ejecución, no una propiedad de tu certificado.** Podés — y a veces debés — servir una cadena distinta de la que te entrega tu CA.

---

## 5. Construir la PKI (completa, reproducible)

Todo lo de abajo corre en una máquina RHEL 9 / Debian 12 estándar con `openssl` 3.x. Las rutas son absolutas para que las configuraciones se puedan copiar y pegar.

### 5.1 Estructura

```bash
$ sudo install -d -m 0755 /opt/pki/{root,sub}/{certs,db} \
                          /opt/pki/{root,sub}/private
$ sudo chmod 0700 /opt/pki/root/private /opt/pki/sub/private
$ for ca in root sub; do
    sudo touch /opt/pki/$ca/db/index
    sudo openssl rand -hex 16 | sudo tee /opt/pki/$ca/db/serial >/dev/null
    echo 1001 | sudo tee /opt/pki/$ca/db/crlnumber >/dev/null
  done
```

### 5.2 `/opt/pki/root/openssl.cnf` — completo

```ini
[ default ]
name                    = root-ca
domain_suffix           = example.net
aia_url                 = http://pki.$domain_suffix/$name.crt
crl_url                 = http://pki.$domain_suffix/$name.crl
default_ca              = ca_default
name_opt                = utf8,esc_ctrl,multiline,lname,align

[ ca_dn ]
countryName             = "AR"
organizationName        = "Example Networks"
commonName              = "Example Networks Root CA R1"

[ ca_default ]
home                    = /opt/pki/root
database                = $home/db/index
serial                  = $home/db/serial
crlnumber               = $home/db/crlnumber
certificate             = $home/$name.crt
private_key             = $home/private/$name.key
new_certs_dir           = $home/certs
unique_subject          = no
copy_extensions         = none
default_days            = 3652
default_crl_days        = 180
default_md              = sha256
policy                  = policy_c_o_match

[ policy_c_o_match ]
countryName             = match
stateOrProvinceName     = optional
organizationName        = match
organizationalUnitName  = optional
commonName              = supplied
emailAddress            = optional

[ req ]
default_bits            = 4096
encrypt_key             = yes
default_md              = sha256
utf8                    = yes
string_mask             = utf8only
prompt                  = no
distinguished_name      = ca_dn
req_extensions          = ca_ext

[ ca_ext ]
basicConstraints        = critical,CA:true
keyUsage                = critical,keyCertSign,cRLSign
subjectKeyIdentifier    = hash

[ sub_ca_ext ]
authorityInfoAccess     = @issuer_info
authorityKeyIdentifier  = keyid:always
basicConstraints        = critical,CA:true,pathlen:0
crlDistributionPoints   = @crl_info
extendedKeyUsage        = clientAuth,serverAuth
keyUsage                = critical,keyCertSign,cRLSign
nameConstraints         = @name_constraints
subjectKeyIdentifier    = hash

[ crl_info ]
URI.0                   = $crl_url

[ issuer_info ]
caIssuers;URI.0         = $aia_url
OCSP;URI.0              = http://ocsp.$domain_suffix

[ name_constraints ]
permitted;DNS.0         = example.net
permitted;DNS.1         = example.internal
excluded;IP.0           = 0.0.0.0/0.0.0.0
excluded;IP.1           = 0:0:0:0:0:0:0:0/0:0:0:0:0:0:0:0
```

El par `excluded;IP` no es decoración: sin él, una CA con name constraints queda sin restricciones para SANs de tipo IP, porque la ausencia de una restricción significa "todo permitido" para ese tipo de nombre.

### 5.3 `/opt/pki/sub/openssl.cnf` — completo

```ini
[ default ]
name                    = sub-ca
domain_suffix           = example.net
aia_url                 = http://pki.$domain_suffix/$name.crt
crl_url                 = http://pki.$domain_suffix/$name.crl
ocsp_url                = http://ocsp.$domain_suffix
default_ca              = ca_default
name_opt                = utf8,esc_ctrl,multiline,lname,align

[ ca_dn ]
countryName             = "AR"
organizationName        = "Example Networks"
commonName              = "Example Networks TLS Issuing CA I1"

[ ca_default ]
home                    = /opt/pki/sub
database                = $home/db/index
serial                  = $home/db/serial
crlnumber               = $home/db/crlnumber
certificate             = $home/$name.crt
private_key             = $home/private/$name.key
new_certs_dir           = $home/certs
unique_subject          = no
copy_extensions         = copy
default_days            = 90
default_crl_days        = 7
default_md              = sha256
policy                  = policy_c_o_match

[ policy_c_o_match ]
countryName             = match
stateOrProvinceName     = optional
organizationName        = match
organizationalUnitName  = optional
commonName              = supplied
emailAddress            = optional

[ req ]
default_bits            = 3072
encrypt_key             = yes
default_md              = sha256
utf8                    = yes
string_mask             = utf8only
prompt                  = no
distinguished_name      = ca_dn
req_extensions          = ca_ext

[ ca_ext ]
basicConstraints        = critical,CA:true
keyUsage                = critical,keyCertSign,cRLSign
subjectKeyIdentifier    = hash

[ server_ext ]
authorityInfoAccess     = @issuer_info
authorityKeyIdentifier  = keyid:always
basicConstraints        = critical,CA:false
crlDistributionPoints   = @crl_info
extendedKeyUsage        = serverAuth,clientAuth
keyUsage                = critical,digitalSignature,keyEncipherment
subjectKeyIdentifier    = hash

[ server_ec_ext ]
authorityInfoAccess     = @issuer_info
authorityKeyIdentifier  = keyid:always
basicConstraints        = critical,CA:false
crlDistributionPoints   = @crl_info
extendedKeyUsage        = serverAuth
keyUsage                = critical,digitalSignature
subjectKeyIdentifier    = hash

[ client_ext ]
authorityInfoAccess     = @issuer_info
authorityKeyIdentifier  = keyid:always
basicConstraints        = critical,CA:false
crlDistributionPoints   = @crl_info
extendedKeyUsage        = clientAuth
keyUsage                = critical,digitalSignature
subjectKeyIdentifier    = hash

[ ocsp_ext ]
authorityKeyIdentifier  = keyid:always
basicConstraints        = critical,CA:false
extendedKeyUsage        = critical,OCSPSigning
keyUsage                = critical,digitalSignature
noCheck                 = yes
subjectKeyIdentifier    = hash

[ crl_info ]
URI.0                   = $crl_url

[ issuer_info ]
caIssuers;URI.0         = $aia_url
OCSP;URI.0              = $ocsp_url
```

`copy_extensions = copy` es lo que permite que el `subjectAltName` de un CSR sobreviva hasta el certificado emitido. También es un arma que se dispara sola — un CSR podría pedir `basicConstraints:CA:true`. La sección `[ server_ext ]` sobreescribe `basicConstraints` explícitamente, y por eso es seguro *acá*. Nunca habilites `copy_extensions` sin fijar las extensiones críticas en el perfil.

`noCheck = yes` en el certificado del responder OCSP es `id-pkix-ocsp-nocheck`: le dice a los clientes que no intenten verificar el estado de revocación del propio responder, lo que sería una regresión infinita.

### 5.4 CA raíz

```bash
$ cd /opt/pki/root
$ sudo openssl req -new -config openssl.cnf -out root-ca.csr \
      -keyout private/root-ca.key
Enter PEM pass phrase:
Verifying - Enter PEM pass phrase:
-----

$ sudo openssl ca -selfsign -config openssl.cnf -in root-ca.csr \
      -out root-ca.crt -extensions ca_ext -days 3652 -batch
Using configuration from openssl.cnf
Enter pass phrase for /opt/pki/root/private/root-ca.key:
Check that the request matches the signature
Signature ok
Certificate Details:
        Serial Number:
            5c:3f:1a:9e:44:7b:20:d1:8f:6a:cc:03:19:be:77:52
        Validity
            Not Before: Aug 18 09:00:11 2026 GMT
            Not After : Aug 16 09:00:11 2036 GMT
        Subject:
            countryName               = AR
            organizationName          = Example Networks
            commonName                = Example Networks Root CA R1
        X509v3 extensions:
            X509v3 Basic Constraints: critical
                CA:TRUE
            X509v3 Key Usage: critical
                Certificate Sign, CRL Sign
            X509v3 Subject Key Identifier:
                A4:1B:0E:C7:52:9D:6F:33:8A:11:CE:04:77:B9:20:E5:6C:D1:3F:88
Certificate is to be certified until Aug 16 09:00:11 2036 GMT (3652 days)
Write out database with 1 new entries
Database updated
```

### 5.5 CA intermedia

```bash
$ cd /opt/pki/sub
$ sudo openssl req -new -config openssl.cnf -out sub-ca.csr \
      -keyout private/sub-ca.key
Enter PEM pass phrase:
Verifying - Enter PEM pass phrase:
-----

$ sudo openssl ca -config /opt/pki/root/openssl.cnf \
      -in sub-ca.csr -out sub-ca.crt \
      -extensions sub_ca_ext -days 1826 -batch
Using configuration from /opt/pki/root/openssl.cnf
Enter pass phrase for /opt/pki/root/private/root-ca.key:
Check that the request matches the signature
Signature ok
Certificate Details:
        Serial Number:
            5c:3f:1a:9e:44:7b:20:d1:8f:6a:cc:03:19:be:77:53
        Subject:
            countryName               = AR
            organizationName          = Example Networks
            commonName                = Example Networks TLS Issuing CA I1
        X509v3 extensions:
            X509v3 Basic Constraints: critical
                CA:TRUE, pathlen:0
            X509v3 Name Constraints:
                Permitted:
                  DNS:example.net
                  DNS:example.internal
                Excluded:
                  IP:0.0.0.0/0.0.0.0
                  IP:0:0:0:0:0:0:0:0/0:0:0:0:0:0:0:0
            X509v3 Key Usage: critical
                Certificate Sign, CRL Sign
            X509v3 Extended Key Usage:
                TLS Web Client Authentication, TLS Web Server Authentication
Certificate is to be certified until Aug 17 09:03:42 2031 GMT (1826 days)
Write out database with 1 new entries
Database updated
```

### 5.6 Certificado de servidor con SANs

```bash
$ sudo openssl genpkey -algorithm EC \
      -pkeyopt ec_paramgen_curve:P-256 \
      -out /etc/pki/example/private/www.key
$ sudo chmod 0600 /etc/pki/example/private/www.key

$ cat > /tmp/www.cnf <<'EOF'
[ req ]
prompt             = no
distinguished_name = dn
req_extensions     = san

[ dn ]
C  = AR
O  = Example Networks
CN = www.example.net

[ san ]
subjectAltName = DNS:www.example.net, DNS:example.net, DNS:static.example.net
EOF

$ sudo openssl req -new -config /tmp/www.cnf \
      -key /etc/pki/example/private/www.key -out /tmp/www.csr

$ sudo openssl ca -config /opt/pki/sub/openssl.cnf \
      -in /tmp/www.csr -out /etc/pki/example/certs/www.crt \
      -extensions server_ec_ext -days 90 -batch
Using configuration from /opt/pki/sub/openssl.cnf
Enter pass phrase for /opt/pki/sub/private/sub-ca.key:
Check that the request matches the signature
Signature ok
Certificate Details:
        Subject:
            countryName               = AR
            organizationName          = Example Networks
            commonName                = www.example.net
        X509v3 extensions:
            X509v3 Subject Alternative Name:
                DNS:www.example.net, DNS:example.net, DNS:static.example.net
            X509v3 Extended Key Usage:
                TLS Web Server Authentication
            Authority Information Access:
                CA Issuers - URI:http://pki.example.net/sub-ca.crt
                OCSP - URI:http://ocsp.example.net
Certificate is to be certified until Nov 16 09:07:55 2026 GMT (90 days)
Write out database with 1 new entries
Database updated
```

**Construí la cadena servida — primero la hoja, sin la raíz:**

```bash
$ sudo sh -c 'cat /etc/pki/example/certs/www.crt /opt/pki/sub/sub-ca.crt \
    > /etc/pki/example/certs/www-fullchain.crt'
$ sudo cp /opt/pki/root/root-ca.crt /etc/pki/example/root-ca.crt
```

### 5.7 Certificado de cliente

```bash
$ openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 \
      -out alice.key
$ openssl req -new -key alice.key -out alice.csr \
      -subj "/C=AR/O=Example Networks/OU=platform/CN=alice@example.net"
$ sudo openssl ca -config /opt/pki/sub/openssl.cnf \
      -in alice.csr -out alice.crt -extensions client_ext -days 30 -batch
```

Empaquetalo como PKCS#12 para navegadores y para `curl --cert-type P12`:

```bash
$ openssl pkcs12 -export -out alice.p12 \
      -inkey alice.key -in alice.crt \
      -certfile /opt/pki/sub/sub-ca.crt \
      -name "alice@example.net"
Enter Export Password:
Verifying - Enter Export Password:
```

### 5.8 Verificá antes de desplegar

```bash
$ openssl verify -CAfile /opt/pki/root/root-ca.crt \
      -untrusted /opt/pki/sub/sub-ca.crt \
      /etc/pki/example/certs/www.crt
/etc/pki/example/certs/www.crt: OK

$ openssl verify -CAfile /opt/pki/root/root-ca.crt \
      -untrusted /opt/pki/sub/sub-ca.crt \
      -purpose sslserver -verify_hostname www.example.net \
      /etc/pki/example/certs/www.crt
/etc/pki/example/certs/www.crt: OK
```

`-purpose sslserver -verify_hostname` es la verificación que casi todo el mundo se saltea. Sin ella, `OK` solo significa "la cadena se construye", no "un navegador lo va a aceptar".

---

## 6. Apache HTTPD + `mod_ssl`: configuración de producción completa

### 6.1 Carga del módulo y política global — `/etc/httpd/conf.modules.d/00-ssl.conf` y `/etc/httpd/conf.d/ssl-global.conf`

```apache
# /etc/httpd/conf.modules.d/00-ssl.conf
LoadModule ssl_module modules/mod_ssl.so
LoadModule socache_shmcb_module modules/mod_socache_shmcb.so
LoadModule headers_module modules/mod_headers.so
```

```apache
# /etc/httpd/conf.d/ssl-global.conf
# ---------------------------------------------------------------------------
# Server-scope only. These directives are NOT per-virtual-host and mod_ssl
# will either ignore or reject them inside <VirtualHost>.
# ---------------------------------------------------------------------------

Listen 443 https

# Entropy for the PRNG. Modern OpenSSL seeds itself; this remains for
# compatibility and for platforms without a usable getrandom(2).
SSLRandomSeed startup  file:/dev/urandom 512
SSLRandomSeed connect  builtin

# ---- Session resumption ---------------------------------------------------
# Server-side session cache (TLS 1.2 session IDs, and TLS 1.3 stateful tickets).
SSLSessionCache         shmcb:/run/httpd/sslcache(512000)
SSLSessionCacheTimeout  300

# Stateless session tickets. Keys are regenerated on restart unless a key file
# is configured; a static key file across a fleet enables cross-node resumption
# but BREAKS FORWARD SECRECY if the file is never rotated.
SSLSessionTickets       on
# SSLSessionTicketKeyFile /etc/pki/example/private/ticket.key   # rotate daily!

# ---- OCSP stapling cache (MUST be server scope) ---------------------------
SSLStaplingCache        shmcb:/run/httpd/stapling-cache(256000)

# ---- Protocol and cipher policy (Mozilla "Intermediate") ------------------
SSLProtocol             all -SSLv3 -TLSv1 -TLSv1.1
SSLCipherSuite          ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:\
ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:\
ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:\
DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:DHE-RSA-CHACHA20-POLY1305
SSLCipherSuite TLSv1.3  TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:TLS_AES_128_GCM_SHA256
SSLHonorCipherOrder     off
SSLCompression          off
SSLInsecureRenegotiation off
SSLOpenSSLConfCmd       Groups X25519:secp256r1:secp384r1

# Reject connections whose SNI does not match any ServerName/ServerAlias
# instead of silently serving the first vhost's certificate.
SSLStrictSNIVHostCheck  on

# ---- Logging: make TLS auditable -----------------------------------------
LogFormat "%h %l %u %t \"%r\" %>s %b \
proto=%{SSL_PROTOCOL}x cipher=%{SSL_CIPHER}x sni=%{SSL_TLS_SNI}x \
resumed=%{SSL_SESSION_RESUMED}x cvfy=%{SSL_CLIENT_VERIFY}x \
cdn=\"%{SSL_CLIENT_S_DN}x\"" tls_combined
```

Notá que `SSLStaplingCache` y `SSLSessionCache` viven acá y *solo* acá. Poner `SSLStaplingCache` dentro de un `<VirtualHost>` produce una falla de arranque — una trampa muy común y muy cercana al examen.

### 6.2 Vhost HTTPS público con SNI, HSTS y stapling — `/etc/httpd/conf.d/www.example.net.conf`

```apache
# ---------------------------------------------------------------------------
# Port 80: redirect only. No content, no HSTS header (HSTS over plain HTTP is
# ignored by clients per RFC 6797 §7.2 — sending it there is a nop, not a fix).
# ---------------------------------------------------------------------------
<VirtualHost *:80>
    ServerName  www.example.net
    ServerAlias example.net static.example.net

    # ACME http-01 must stay reachable in cleartext.
    Alias /.well-known/acme-challenge/ /var/www/acme/.well-known/acme-challenge/
    <Directory "/var/www/acme/.well-known/acme-challenge">
        Require all granted
        Options -Indexes
    </Directory>

    RewriteEngine On
    RewriteCond %{REQUEST_URI} !^/\.well-known/acme-challenge/
    RewriteRule ^/?(.*)$ https://%{SERVER_NAME}/$1 [R=308,L]

    ErrorLog  /var/log/httpd/www.example.net-http-error.log
    CustomLog /var/log/httpd/www.example.net-http-access.log combined
</VirtualHost>

# ---------------------------------------------------------------------------
# Port 443: the real service. Selected by SNI.
# ---------------------------------------------------------------------------
<VirtualHost *:443>
    ServerName  www.example.net
    ServerAlias example.net static.example.net
    DocumentRoot /var/www/www.example.net

    Protocols h2 http/1.1

    SSLEngine on

    # Leaf + intermediates, leaf first, root omitted.
    SSLCertificateFile      /etc/pki/example/certs/www-fullchain.crt
    SSLCertificateKeyFile   /etc/pki/example/private/www.key

    # Dual-certificate deployment: an ECDSA leaf for modern clients and an RSA
    # leaf for the long tail. mod_ssl picks per handshake from the client's
    # signature_algorithms. Repeat the pair, do not use a second vhost.
    SSLCertificateFile      /etc/pki/example/certs/www-rsa-fullchain.crt
    SSLCertificateKeyFile   /etc/pki/example/private/www-rsa.key

    # ---- OCSP stapling ----------------------------------------------------
    SSLUseStapling                  on
    SSLStaplingResponderTimeout     5
    SSLStaplingReturnResponderErrors off
    SSLStaplingStandardCacheTimeout 3600
    SSLStaplingErrorCacheTimeout    120
    SSLStaplingFakeTryLater         on

    # ---- HSTS -------------------------------------------------------------
    # "always" is mandatory: without it the header is omitted on 4xx/5xx,
    # which are exactly the responses an attacker can provoke.
    Header always set Strict-Transport-Security "max-age=63072000; includeSubDomains; preload"

    # Companion hardening headers (not on the objectives, but expected of you)
    Header always set X-Content-Type-Options "nosniff"
    Header always set Referrer-Policy "strict-origin-when-cross-origin"
    Header always set Content-Security-Policy "default-src 'self'; frame-ancestors 'none'"

    <Directory "/var/www/www.example.net">
        Options -Indexes +FollowSymLinks
        AllowOverride None
        Require all granted
    </Directory>

    # Expose TLS variables to the application (CGI/FastCGI/proxy).
    <FilesMatch "\.(cgi|shtml|php)$">
        SSLOptions +StdEnvVars
    </FilesMatch>

    ErrorLog  /var/log/httpd/www.example.net-error.log
    CustomLog /var/log/httpd/www.example.net-access.log tls_combined
    LogLevel  warn ssl:info
</VirtualHost>
```

### 6.3 Referencia de directivas

| Directiva | Contexto | Por defecto | Qué controla realmente |
|---|---|---|---|
| `SSLEngine` | vhost | `off` | Si este vhost habla TLS o no |
| `SSLCertificateFile` | vhost | — | Hoja (+cadena, +clave desde 2.4.8); repetible para RSA/ECDSA |
| `SSLCertificateKeyFile` | vhost | — | Clave privada; no debe ser legible por todo el mundo |
| `SSLCertificateChainFile` | vhost | — | **Obsoleta en 2.4.8**; usá un archivo fullchain |
| `SSLCACertificateFile` | vhost | — | Anclas de confianza para verificar certificados de *cliente* |
| `SSLCACertificatePath` | vhost | — | Lo mismo, directorio con hashes (`openssl rehash`) |
| `SSLCADNRequestFile` | vhost | = `SSLCACertificateFile` | DNs de CA anunciados en el `CertificateRequest` |
| `SSLVerifyClient` | server/vhost/dir/.htaccess | `none` | `none`/`optional`/`require`/`optional_no_ca` |
| `SSLVerifyDepth` | server/vhost/dir | `1` | Máximo de intermedias **entre** la hoja y un ancla de confianza |
| `SSLProtocol` | server/vhost | `all -SSLv3` | Versiones habilitadas |
| `SSLCipherSuite [proto]` | server/vhost/dir | `DEFAULT` | Lista de suites; TLS 1.3 necesita el argumento `TLSv1.3` |
| `SSLHonorCipherOrder` | server/vhost | `off` | La lista del servidor gana sobre la preferencia del cliente |
| `SSLOpenSSLConfCmd` | server/vhost | — | Comandos de configuración crudos de OpenSSL (`Groups`, `SignatureAlgorithms`, …) |
| `SSLSessionCache` | **solo server** | `none` | Almacén de reanudación del lado del servidor |
| `SSLSessionTickets` | server/vhost | `on` | Tickets sin estado RFC 5077 |
| `SSLStaplingCache` | **solo server** | — | Obligatoria antes de cualquier `SSLUseStapling on` |
| `SSLUseStapling` | server/vhost | `off` | Descargar y adjuntar la respuesta OCSP |
| `SSLOCSPEnable` | server/vhost | `off` | Verificación OCSP del certificado **del cliente** |
| `SSLCARevocationCheck` | server/vhost | `none` | `none`/`leaf`/`chain` [+`no_crl_for_cert_ok`] |
| `SSLStrictSNIVHostCheck` | server/vhost | `off` | Rechazar clientes sin SNI o con SNI que no coincide |
| `SSLOptions` | server/vhost/dir | — | `+StdEnvVars`, `+FakeBasicAuth`, `+ExportCertData`, `+StrictRequire`, `+OptRenegotiate`, `+LegacyDNStringFormat` |
| `SSLRequireSSL` | dir | — | Denegar el acceso sin TLS a esta ubicación |
| `SSLRequire` | dir | — | Expresión booleana sobre las variables SSL_* |
| `SSLUserName` | server/dir | — | Qué variable SSL_* se convierte en `REMOTE_USER` |

---

## 7. SNI

### 7.1 El problema que resuelve

TLS empieza antes que HTTP. El servidor debe elegir un certificado antes de haber visto una cabecera `Host:`. Antes de SNI, el hosting virtual por nombre sobre HTTPS era imposible: una IP:puerto, un certificado. **Server Name Indication** (RFC 6066 §3) pone el nombre de host solicitado en una extensión del ClientHello, en texto claro, para que el servidor pueda elegir.

```
ClientHello
  extension: server_name (0)
    server_name_list
      server_name_type: host_name (0)
      HostName: "www.example.net"
```

### 7.2 Cómo lo usa `mod_ssl`

1. La conexión llega a `*:443`. mod_ssl lee el SNI en el ClientHello.
2. Compara el SNI contra cada `ServerName`/`ServerAlias` de esa IP:puerto.
3. Coincidencia → el certificado de ese vhost. Sin coincidencia, o sin SNI en absoluto → **el primer vhost definido para esa dirección:puerto**, y su certificado.

El paso 3 es la falla silenciosa. Un cliente sin SNI recibe el certificado de `www.example.net` para una petición a `api.example.net`, la verificación de nombre falla, y el error que ve el usuario es una discrepancia de certificado que no tiene nada que ver con el certificado. `SSLStrictSNIVHostCheck on` convierte eso en un honesto `unrecognized_name` (alerta 112) / HTTP 403.

Hay una segunda verificación de consistencia, realizada después de parsear la línea de petición: si el SNI y la cabecera HTTP `Host:` no coinciden, httpd devuelve **400 Bad Request** y registra `AH02032: Hostname %s provided via SNI and hostname %s provided via HTTP are different`. Esto no es configurable y es correcto — una discrepancia significa que la conexión se enrutó por un nombre y la petición por otro.

### 7.3 Probar SNI

```bash
# With SNI — the expected case.
$ openssl s_client -connect 203.0.113.10:443 -servername api.example.net \
      </dev/null 2>&1 | grep -E '^(subject|issuer)'
subject=C=AR, O=Example Networks, CN=api.example.net
issuer=C=AR, O=Example Networks, CN=Example Networks TLS Issuing CA I1

# Without SNI — you get the default vhost.  -noservername is OpenSSL 1.1.1+.
$ openssl s_client -connect 203.0.113.10:443 -noservername \
      </dev/null 2>&1 | grep -E '^subject'
subject=C=AR, O=Example Networks, CN=www.example.net
```

> `openssl s_client -connect host:443` **sí** envía el SNI derivado del argumento de `-connect` en OpenSSL 1.1.1 y posteriores, pero **no** en 1.0.2 y anteriores. La mitad de los tickets de "el servidor manda el certificado equivocado" en jump boxes viejos son esto. Pasá siempre `-servername` explícitamente; no cuesta nada y elimina la ambigüedad.

Confirmá el mapa de vhosts que httpd realmente construyó:

```bash
$ apachectl -S
VirtualHost configuration:
*:80                   is a NameVirtualHost
         default server www.example.net (/etc/httpd/conf.d/www.example.net.conf:5)
         port 80 namevhost www.example.net (/etc/httpd/conf.d/www.example.net.conf:5)
                 alias example.net
                 alias static.example.net
*:443                  is a NameVirtualHost
         default server www.example.net (/etc/httpd/conf.d/www.example.net.conf:29)
         port 443 namevhost www.example.net (/etc/httpd/conf.d/www.example.net.conf:29)
                 alias example.net
                 alias static.example.net
         port 443 namevhost mtls.example.net (/etc/httpd/conf.d/mtls.example.net.conf:6)
ServerRoot: "/etc/httpd"
Main DocumentRoot: "/var/www/html"
Main ErrorLog: "/var/log/httpd/error_log"
Mutex ssl-stapling: using_defaults
Mutex ssl-cache: using_defaults
PidFile: "/run/httpd/httpd.pid"
User: name="apache" id=48
Group: name="apache" id=48
```

`default server` en `*:443` te dice exactamente qué certificado recibe un cliente sin SNI.

---

## 8. HSTS

### 8.1 Qué hace

HTTP Strict Transport Security (RFC 6797) le dice a un navegador: *durante los próximos `max-age` segundos, nunca hables HTTP plano con este host; actualizá internamente, y no dejes que el usuario se salte los errores de certificado.* Cierra la ventana de SSL stripping que existe en la primerísima navegación, y convierte una advertencia blanda de certificado en una falla dura.

```
Strict-Transport-Security: max-age=63072000; includeSubDomains; preload
```

| Directiva | Significado | Riesgo operativo |
|---|---|---|
| `max-age=<sec>` | Duración del anclaje, refrescado en cada respuesta HTTPS | Los valores altos son difíciles de deshacer — hay que servir `max-age=0` sobre HTTPS funcionando durante toda la vida anterior para alcanzar a todos los clientes |
| `includeSubDomains` | Aplica a todos los subdominios, recursivamente | **Cualquier** subdominio sin certificado válido queda inalcanzable, incluidos los de uso interno bajo el mismo ápice |
| `preload` | Consentimiento para ser incluido en la lista que embarcan los navegadores | Prácticamente permanente; la eliminación lleva ciclos de release del navegador |

### 8.2 Reglas con las que la gente tropieza

- La cabecera se **ignora en respuestas HTTP planas**. Configurarla en el vhost del puerto 80 no logra nada.
- La cabecera se **ignora si la conexión tuvo cualquier error de certificado**. No podés arrancar HSTS desde un despliegue roto.
- Aplica a un **host**, no a un esquema+puerto. HSTS en `example.net` actualiza `http://example.net:8080` a `https://example.net:8080`.
- `Header set` sin `always` coloca la cabecera en la tabla `onsuccess`, con lo cual se descarta en las respuestas de error. Usá `Header always set`.

### 8.3 Escalera de despliegue

```apache
# Week 1 — 5 minutes. Cheap to undo.
Header always set Strict-Transport-Security "max-age=300"

# Week 2 — 1 day.
Header always set Strict-Transport-Security "max-age=86400"

# Week 4 — 1 week, after auditing every subdomain.
Header always set Strict-Transport-Security "max-age=604800; includeSubDomains"

# Week 8 — 2 years + preload submission at hstspreload.org
Header always set Strict-Transport-Security "max-age=63072000; includeSubDomains; preload"
```

```bash
$ curl -sI https://www.example.net/ | grep -i strict
strict-transport-security: max-age=63072000; includeSubDomains; preload

# Verify it survives an error response — this is what "always" buys you.
$ curl -sI https://www.example.net/does-not-exist | grep -iE '^(HTTP|strict)'
HTTP/2 404
strict-transport-security: max-age=63072000; includeSubDomains; preload
```

---

## 9. Autenticación por certificado de cliente (mTLS)

### 9.1 Semántica de `SSLVerifyClient`

| Valor | ¿El servidor envía `CertificateRequest`? | Certificado ausente | Certificado presente pero no verificable | `SSL_CLIENT_VERIFY` |
|---|---|---|---|---|
| `none` | no | — | — | `NONE` |
| `optional` | sí | la conexión continúa | **el handshake falla** | `NONE` o `SUCCESS` |
| `require` | sí | **el handshake falla** | **el handshake falla** | `SUCCESS` |
| `optional_no_ca` | sí | continúa | **continúa** — validación delegada a la app | `GENEROUS` |

`optional_no_ca` es el que hay que entender: mod_ssl acepta cualquier certificado sintácticamente válido y se lo entrega a la aplicación en `SSL_CLIENT_CERT`. Es la forma de construir una confianza controlada por la aplicación (por ejemplo, un registro de dispositivos indexado por la huella de la clave pública) — y es un agujero enorme si la aplicación se olvida de verificar.

`SSLVerifyDepth` cuenta las CAs **intermedias** entre la hoja del cliente y un certificado de tu almacén de confianza. Con la PKI de dos niveles de §5, donde `SSLCACertificateFile` contiene solo la raíz, la cadena del cliente es `alice → sub-ca → root`, así que necesitás `SSLVerifyDepth 2`. El valor por defecto `1` la rechaza con la alerta 48 (`unknown ca`) y la confusa línea de log `Certificate Verification: Error (20): unable to get local issuer certificate`. Si en cambio ponés la *intermedia* en `SSLCACertificateFile`, alcanza con profundidad 1 — pero entonces delegaste la confianza directamente en la intermedia, y una intermedia reemplazada deja de funcionar en silencio.

### 9.2 Vhost mTLS completo — `/etc/httpd/conf.d/mtls.example.net.conf`

```apache
<VirtualHost *:443>
    ServerName mtls.example.net
    DocumentRoot /var/www/mtls.example.net

    # HTTP/2 forbids TLS renegotiation. Because per-directory client auth
    # historically relied on renegotiation, pin this vhost to HTTP/1.1 unless
    # every client is known to support TLS 1.3 post-handshake auth (RFC 8740).
    Protocols http/1.1

    SSLEngine on
    SSLCertificateFile    /etc/pki/example/certs/mtls-fullchain.crt
    SSLCertificateKeyFile /etc/pki/example/private/mtls.key

    # ---- Client authentication -------------------------------------------
    # Trust anchors used to verify CLIENT certificates. Distinct from the
    # chain we serve; a separate CA here would be even better hygiene.
    SSLCACertificateFile  /etc/pki/example/client-ca/root-ca.crt
    # Alternative, one file per CA + `openssl rehash`:
    # SSLCACertificatePath /etc/pki/example/client-ca/hashed

    # Advertise only ONE CA DN in the CertificateRequest even though we trust
    # several — keeps the handshake small and gives browsers a clean picker.
    SSLCADNRequestFile    /etc/pki/example/client-ca/advertised.pem

    SSLVerifyClient       require
    SSLVerifyDepth        2

    # ---- Revocation of client certificates --------------------------------
    # CRL path: files must be hashed with `openssl rehash`.
    SSLCARevocationPath   /etc/pki/example/client-ca/crl
    SSLCARevocationCheck  chain

    # OCSP path (alternative or complement). Requires the client cert to carry
    # an AIA OCSP URI, or set a default responder.
    # SSLOCSPEnable            leaf
    # SSLOCSPDefaultResponder  http://ocsp.example.net
    # SSLOCSPOverrideResponder off
    # SSLOCSPResponderTimeout  5
    # SSLOCSPUseRequestNonce   on

    # ---- Identity mapping --------------------------------------------------
    # Publish SSL_* into the CGI/proxy environment and make REMOTE_USER the
    # client certificate CN.
    SSLOptions +StdEnvVars +ExportCertData +StrictRequire
    SSLUserName SSL_CLIENT_S_DN_CN

    <Location "/">
        SSLRequireSSL
        # Fine-grained authorisation on certificate contents. Everything here
        # is evaluated AFTER a successful chain validation.
        SSLRequire %{SSL_CLIENT_VERIFY} eq "SUCCESS" \
                   and %{SSL_CLIENT_I_DN_CN} eq "Example Networks TLS Issuing CA I1" \
                   and %{SSL_CLIENT_S_DN_OU} in {"platform", "sre"}
        Require all granted
    </Location>

    # Health endpoint reachable without a client certificate is NOT possible
    # in this vhost — SSLVerifyClient require is enforced at handshake time.
    # Put the health check on a separate vhost/port. This is a real constraint.

    # ---- Pass the verified identity to the backend ------------------------
    RequestHeader set X-Client-DN     "%{SSL_CLIENT_S_DN}s"
    RequestHeader set X-Client-Serial "%{SSL_CLIENT_M_SERIAL}s"
    RequestHeader set X-Client-Verify "%{SSL_CLIENT_VERIFY}s"
    # Defensive: strip anything the client tried to inject.
    RequestHeader unset X-Client-Trusted early
    RequestHeader set   X-Client-Trusted "1"

    ProxyPreserveHost On
    ProxyPass        /api/ http://127.0.0.1:8080/
    ProxyPassReverse /api/ http://127.0.0.1:8080/

    ErrorLog  /var/log/httpd/mtls.example.net-error.log
    CustomLog /var/log/httpd/mtls.example.net-access.log tls_combined
    LogLevel  warn ssl:info
</VirtualHost>
```

`RequestHeader unset ... early` antes de establecerla no es paranoia: sin eso, un cliente manda él mismo `X-Client-Trusted: 1` y tu backend le cree. Eliminar cabeceras en el límite de confianza es obligatorio siempre que conviertas identidad TLS en identidad HTTP.

### 9.3 El problema de la renegociación, y por qué está ahí `Protocols http/1.1`

Si `SSLVerifyClient require` aparece a **nivel de vhost**, el `CertificateRequest` forma parte del handshake inicial. Simple, robusto, funciona en todos lados.

Si aparece a **nivel de directorio** (`<Location /admin>`), el servidor no sabía que iba a necesitar un certificado cuando ocurrió el handshake. Históricamente lo resolvía con **renegociación**: un segundo handshake a mitad de la conexión. Ese mecanismo tiene tres problemas:

1. Fue el vector de CVE-2009-3555; el RFC 5746 lo arregló, pero sigue siendo mal visto.
2. **HTTP/2 prohíbe la renegociación por completo** (RFC 9113 §9.2.1). Con `Protocols h2`, la autenticación de cliente a nivel de directorio simplemente no puede funcionar sobre una conexión h2.
3. **TLS 1.3 eliminó la renegociación.** Su reemplazo es la autenticación posterior al handshake (RFC 8446 §4.6.2), permitida con HTTP/2 por el RFC 8740 solo cuando el cliente anunció `post_handshake_auth`. El soporte de los clientes es inconsistente.

La regla de producción: **hacé la autenticación de cliente a nivel de vhost, en un nombre de host o puerto dedicado.** Usá `SSLRequire` / `Require` para una autorización más fina *dentro* de una conexión ya autenticada. Si necesitás un sitio mixto público/autenticado, dividilo en dos vhosts y enlazá entre ellos.

### 9.4 Las variables SSL del certificado de cliente

| Variable | Ejemplo |
|---|---|
| `SSL_CLIENT_VERIFY` | `SUCCESS`, `NONE`, `GENEROUS`, `FAILED:certificate has expired` |
| `SSL_CLIENT_S_DN` | `CN=alice@example.net,OU=platform,O=Example Networks,C=AR` |
| `SSL_CLIENT_S_DN_CN` | `alice@example.net` |
| `SSL_CLIENT_S_DN_OU` | `platform` |
| `SSL_CLIENT_I_DN_CN` | `Example Networks TLS Issuing CA I1` |
| `SSL_CLIENT_M_SERIAL` | `5C3F1A9E447B20D18F6ACC0319BE7761` |
| `SSL_CLIENT_V_START` / `_V_END` | `Aug 18 09:20:00 2026 GMT` |
| `SSL_CLIENT_SAN_DNS_0`, `SSL_CLIENT_SAN_Email_0` | entradas SAN por índice |
| `SSL_CLIENT_CERT` | el PEM completo (requiere `+ExportCertData`) |
| `SSL_PROTOCOL`, `SSL_CIPHER`, `SSL_SESSION_RESUMED` | hechos de la conexión |

Desde httpd 2.4, los DNs se representan en formato **RFC 2253** (separados por comas, del más específico al menos específico). El código heredado que parseaba el viejo formato oneline `/C=AR/O=...` de OpenSSL se rompe; `SSLOptions +LegacyDNStringFormat` lo restaura como muleta de migración.

### 9.5 `+FakeBasicAuth`

```apache
SSLOptions +FakeBasicAuth
AuthType Basic
AuthName "Certificate DN"
AuthBasicProvider file
AuthUserFile /etc/httpd/conf/dn-users
Require valid-user
```

mod_ssl sintetiza una cabecera `Authorization: Basic` cuyo nombre de usuario es el DN del cliente y cuya contraseña es la cadena fija `password`, pre-hasheada como el conocido valor de crypt:

```bash
$ printf '%s:xxj31ZMTZzkVA\n' \
    'CN=alice@example.net,OU=platform,O=Example Networks,C=AR' \
    | sudo tee -a /etc/httpd/conf/dn-users
```

Existe para que los módulos de autorización escritos para Basic auth sigan funcionando. No es un control de seguridad adicional — cualquiera que pueda completar el handshake mTLS ya está autenticado.

### 9.6 Probar mTLS

```bash
# Server rejects a connection with no client certificate.
$ openssl s_client -connect mtls.example.net:443 -servername mtls.example.net \
      -CAfile /etc/pki/example/root-ca.crt </dev/null
CONNECTED(00000003)
depth=1 C=AR, O=Example Networks, CN=Example Networks TLS Issuing CA I1
verify return:1
depth=0 C=AR, O=Example Networks, CN=mtls.example.net
verify return:1
---
Acceptable client certificate CA names
C=AR, O=Example Networks, CN=Example Networks Root CA R1
Requested Signature Algorithms: ECDSA+SHA256:RSA-PSS+SHA256:RSA+SHA256
---
40D7A1B2C47F0000:error:0A00045C:SSL routines:ssl3_read_bytes:tlsv13 alert certificate required:ssl/record/rec_layer_s3.c:1584:SSL alert number 116

# With a valid client certificate.
$ openssl s_client -connect mtls.example.net:443 -servername mtls.example.net \
      -CAfile /etc/pki/example/root-ca.crt \
      -cert alice.crt -key alice.key -tls1_3 </dev/null 2>/dev/null \
      | grep -E 'Verification|Cipher is|Protocol'
    Protocol  : TLSv1.3
    Cipher    : TLS_AES_256_GCM_SHA384
Verification: OK
New, TLSv1.3, Cipher is TLS_AES_256_GCM_SHA384

# End-to-end with curl, checking the identity the app receives.
$ curl -s --cacert /etc/pki/example/root-ca.crt \
       --cert alice.crt --key alice.key \
       https://mtls.example.net/api/whoami
{"dn":"CN=alice@example.net,OU=platform,O=Example Networks,C=AR","verify":"SUCCESS"}

# Revoke and confirm enforcement.
$ sudo openssl ca -config /opt/pki/sub/openssl.cnf -revoke alice.crt \
       -crl_reason keyCompromise
Revoking Certificate 5C3F1A9E447B20D18F6ACC0319BE7761.
Data Base Updated

$ sudo openssl ca -config /opt/pki/sub/openssl.cnf -gencrl \
       -out /etc/pki/example/client-ca/crl/sub-ca.crl
$ sudo openssl rehash /etc/pki/example/client-ca/crl
$ sudo apachectl graceful

$ curl -s --cacert /etc/pki/example/root-ca.crt \
       --cert alice.crt --key alice.key https://mtls.example.net/api/whoami
curl: (56) OpenSSL SSL_read: OpenSSL/3.0.7: error:0A000418:SSL routines:ssl3_read_bytes:tlsv1 alert unknown ca, errno 0
```

Del lado del servidor:

```
[ssl:info] [pid 2214:tid 2277] [client 198.51.100.20:51512] AH02275: Certificate Verification: Error (23): certificate revoked
```

> `SSLCARevocationPath` requiere nombres de archivo con hash. Dejar `sub-ca.crl` en el directorio sin `openssl rehash` significa que httpd nunca lo lee y la revocación no hace nada, en silencio — un fail-open trivialmente fácil de pasar por alto. Preferí `SSLCARevocationFile` con una única CRL concatenada si podés, y probá siempre con un certificado genuinamente revocado.

---

## 10. OCSP stapling

### 10.1 Mecánica

El cliente envía una extensión `status_request` en su ClientHello. El servidor, que ya obtuvo una respuesta OCSP firmada de la CA (fuera de banda, con su propio calendario), adjunta esa respuesta al handshake en un mensaje `CertificateStatus` (TLS 1.2) o como una extensión `status_request` sobre el mensaje `Certificate` (TLS 1.3). La respuesta está firmada por la CA, así que el servidor no puede falsificarla, y lleva `thisUpdate`/`nextUpdate`, así que no puede reproducirse indefinidamente.

Resultado: estado de revocación con **cero** latencia adicional para el cliente, **cero** fuga de privacidad hacia la CA, y sin dependencia de que el responder de la CA sea alcanzable desde la red del cliente.

### 10.2 Configuración

```apache
# server scope — MANDATORY, and must come before any SSLUseStapling
SSLStaplingCache shmcb:/run/httpd/stapling-cache(256000)

# vhost scope
SSLUseStapling                   on
SSLStaplingResponderTimeout      5      # seconds before giving up on the CA
SSLStaplingReturnResponderErrors off    # never forward "unknown"/errors to clients
SSLStaplingStandardCacheTimeout  3600   # cap on caching a good response
SSLStaplingErrorCacheTimeout     120    # retry sooner after a failure
SSLStaplingFakeTryLater          on     # send tryLater instead of nothing on timeout
SSLStaplingResponseMaxAge        -1     # -1 = accept whatever nextUpdate says
SSLStaplingResponseTimeSkew      300
# SSLStaplingForceURL http://ocsp.example.net   # override the AIA OCSP URI
```

| Directiva | Por defecto | Cuándo la cambiás |
|---|---|---|
| `SSLStaplingCache` | ninguna | Siempre — omitirla es un error de arranque |
| `SSLUseStapling` | `off` | Siempre encendida para certificados públicos |
| `SSLStaplingReturnResponderErrors` | `on` | Ponela en `off`: un estado `unknown` reenviado a un cliente must-staple es una caída |
| `SSLStaplingResponderTimeout` | `10` | Bajala; un bloqueo de 10 s en el primer handshake tras el vencimiento de la caché es visible para el usuario |
| `SSLStaplingErrorCacheTimeout` | `600` | Bajala cuando el responder de la CA es inestable |
| `SSLStaplingForceURL` | — | La URI AIA de la CA es inalcanzable desde tu red; operás un proxy OCSP |
| `SSLStaplingFakeTryLater` | `on` | Dejala encendida |

Tres requisitos duros que causan la mayoría de las fallas de stapling:

1. La **hoja debe llevar una URI OCSP en AIA**. Los certificados de una CA privada sin `OCSP;URI` en `authorityInfoAccess` no pueden ser stapleados — no hay URL de donde descargar.
2. httpd debe poder **construir la cadena del emisor en memoria**, porque la petición OCSP identifica el certificado por hashes del nombre y la clave *del emisor*. Si `SSLCertificateFile` contiene solo la hoja, obtenés `AH02217: ssl_stapling_init_cert: Can't retrieve issuer certificate!` en el arranque y el stapling queda deshabilitado en silencio para ese certificado.
3. httpd debe tener **acceso de red saliente** al responder, incluido cualquier proxy (`SSLOCSPProxyURL` cubre el OCSP del certificado de cliente; el stapling respeta la configuración de proxy estándar del cliente HTTP de OpenSSL).

### 10.3 Verificar el staple

```bash
$ openssl s_client -connect www.example.net:443 -servername www.example.net \
      -status -CAfile /etc/pki/example/root-ca.crt </dev/null 2>/dev/null \
      | sed -n '/OCSP response/,/Next Update/p'
OCSP response:
======================================
OCSP Response Data:
    OCSP Response Status: successful (0x0)
    Response Type: Basic OCSP Response
    Version: 1 (0x0)
    Responder Id: C = AR, O = Example Networks, CN = Example Networks OCSP Responder
    Produced At: Aug 18 06:00:00 2026 GMT
    Responses:
    Certificate ID:
      Hash Algorithm: sha1
      Issuer Name Hash: 7B5B45CFAFCECB7B0353A55B99A2E3E2E1F4C0AA
      Issuer Key Hash: 0F80611C823161D52F28E78D4638B42CE1C6D9E2
      Serial Number: 5C3F1A9E447B20D18F6ACC0319BE7754
    Cert Status: good
    This Update: Aug 18 06:00:00 2026 GMT
    Next Update: Aug 25 06:00:00 2026 GMT
```

**Sin staple** se ve así — y es fácil pasarlo por alto porque el handshake igual tiene éxito:

```bash
$ openssl s_client -connect www.example.net:443 -servername www.example.net \
      -status </dev/null 2>/dev/null | grep -A2 'OCSP response'
OCSP response: no response sent
```

Una verificación de monitoreo que solo hace grep de `Cert Status: good` va a pasar con un certificado *revocado* cuyo staple está ausente, porque no hay nada que grepear. Verificá **tanto** la presencia como el estado:

```bash
#!/bin/bash
# /usr/local/bin/check-staple — exit 2 if absent, 1 if stale, 0 if fresh+good
set -euo pipefail
host="$1"
out=$(openssl s_client -connect "${host}:443" -servername "$host" \
        -status </dev/null 2>/dev/null)

grep -q 'OCSP Response Status: successful' <<<"$out" || {
    echo "CRITICAL: no OCSP staple from $host"; exit 2; }
grep -q 'Cert Status: good'                 <<<"$out" || {
    echo "CRITICAL: staple reports non-good status for $host"; exit 2; }

next=$(sed -n 's/^ *Next Update: //p' <<<"$out" | head -1)
secs=$(( $(date -u -d "$next" +%s) - $(date -u +%s) ))
(( secs < 86400 )) && { echo "WARNING: staple expires in $((secs/3600))h"; exit 1; }
echo "OK: staple good, valid for $((secs/3600))h"
```

### 10.4 Obtener una respuesta OCSP a mano

Esencial cuando el stapling no funciona y necesitás saber si el problema es httpd o la CA:

```bash
$ openssl ocsp \
      -issuer /opt/pki/sub/sub-ca.crt \
      -cert   /etc/pki/example/certs/www.crt \
      -url    http://ocsp.example.net \
      -header "Host=ocsp.example.net" \
      -no_nonce -text
OCSP Request Data:
    Version: 1 (0x0)
    Requestor List:
        Certificate ID:
          Hash Algorithm: sha1
          Issuer Name Hash: 7B5B45CFAFCECB7B0353A55B99A2E3E2E1F4C0AA
          Issuer Key Hash: 0F80611C823161D52F28E78D4638B42CE1C6D9E2
          Serial Number: 5C3F1A9E447B20D18F6ACC0319BE7754
...
/etc/pki/example/certs/www.crt: good
	This Update: Aug 18 06:00:00 2026 GMT
	Next Update: Aug 25 06:00:00 2026 GMT
```

`-header "Host=..."` hace falta siempre que el responder esté detrás de un host virtual por nombre; sin él, OpenSSL no envía cabecera `Host:` en algunas versiones y el responder devuelve HTTP 400. `-no_nonce` se corresponde con lo que la mayoría de las CAs públicas soporta realmente (pre-firman las respuestas y no pueden incluir un nonce).

### 10.5 Must-staple

```ini
# add to [ server_ext ] to make stapling mandatory
tlsfeature = status_request
```

```bash
$ openssl x509 -in www.crt -noout -text | grep -A1 'TLS Feature'
            TLS Feature:
                status_request
```

Un cliente conforme que no recibe staple para un certificado must-staple **falla de forma dura**. Esa es la ganancia de seguridad y el riesgo de disponibilidad en una sola frase. Prerrequisitos antes de habilitarlo: alertas sobre la antigüedad del staple (§10.3), un `SSLStaplingErrorCacheTimeout` lo bastante corto como para recuperarse rápido, y un rollback documentado que no requiera reemitir el certificado — lo cual, dado que `tlsfeature` está horneado dentro del certificado, significa **tener listo un certificado sin must-staple para intercambiar**.

---

## 11. Recetario de `openssl s_client` / `s_server`

### 11.1 La inspección canónica

```bash
$ openssl s_client -connect www.example.net:443 -servername www.example.net \
      -CAfile /etc/pki/example/root-ca.crt -showcerts </dev/null 2>/dev/null
CONNECTED(00000003)
depth=2 C=AR, O=Example Networks, CN=Example Networks Root CA R1
verify return:1
depth=1 C=AR, O=Example Networks, CN=Example Networks TLS Issuing CA I1
verify return:1
depth=0 C=AR, O=Example Networks, CN=www.example.net
verify return:1
---
Certificate chain
 0 s:C=AR, O=Example Networks, CN=www.example.net
   i:C=AR, O=Example Networks, CN=Example Networks TLS Issuing CA I1
   a:PKEY: id-ecPublicKey, 256 (bit); sigalg: ecdsa-with-SHA256
   v:NotBefore: Aug 18 09:07:55 2026 GMT; NotAfter: Nov 16 09:07:55 2026 GMT
-----BEGIN CERTIFICATE-----
MIIC4zCCAougAwIBAgIQXD8ankR7INGPasw...
-----END CERTIFICATE-----
 1 s:C=AR, O=Example Networks, CN=Example Networks TLS Issuing CA I1
   i:C=AR, O=Example Networks, CN=Example Networks Root CA R1
   a:PKEY: rsaEncryption, 3072 (bit); sigalg: RSA-SHA256
   v:NotBefore: Aug 18 09:03:42 2026 GMT; NotAfter: Aug 17 09:03:42 2031 GMT
-----BEGIN CERTIFICATE-----
MIIFXzCCA0egAwIBAgIQXD8ankR7INGPasw...
-----END CERTIFICATE-----
---
Server certificate
subject=C=AR, O=Example Networks, CN=www.example.net
issuer=C=AR, O=Example Networks, CN=Example Networks TLS Issuing CA I1
---
No client certificate CA names sent
Peer signing digest: SHA256
Peer signature type: ECDSA
Negotiated TLS1.3 group: X25519
---
SSL handshake has read 2841 bytes and written 383 bytes
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

Leelo en este orden: las líneas `depth=` (cadena construida y confiable), `Certificate chain` (**exactamente lo que envió el servidor** — notá que hay dos entradas y ninguna raíz: correcto), `Verify return code: 0 (ok)`, y después protocolo y cifrador.

`</dev/null` no es cosmético: sin eso, `s_client` espera en stdin para siempre y tu script se cuelga.

### 11.2 Los flags que importan

| Flag | Propósito |
|---|---|
| `-servername <n>` | Enviar SNI explícitamente. Siempre. |
| `-noservername` | Suprimir SNI, para probar el comportamiento del vhost por defecto |
| `-showcerts` | Imprimir la cadena completa tal como la envía el servidor |
| `-status` | Solicitar e imprimir el staple OCSP |
| `-CAfile` / `-CApath` | Anclas de confianza para la verificación |
| `-verify_return_error` | **Abortar** ante una falla de verificación en lugar de continuar |
| `-verify_hostname <n>` | Forzar la verificación de nombre RFC 6125 |
| `-cert` / `-key` | Certificado de cliente para mTLS |
| `-tls1_2` / `-tls1_3` / `-no_tls1_3` | Forzar o excluir una versión |
| `-cipher <list>` | Lista de suites para TLS ≤ 1.2 |
| `-ciphersuites <list>` | Lista de suites de TLS 1.3 |
| `-groups <list>` | Ofrecer solo estos grupos de intercambio de claves |
| `-sigalgs <list>` | Ofrecer solo estos algoritmos de firma |
| `-alpn h2,http/1.1` | Negociar ALPN |
| `-reconnect` | Reconectar 5× para probar la reanudación de sesión |
| `-sess_out` / `-sess_in` | Persistir y reutilizar una sesión entre invocaciones |
| `-starttls smtp\|imap\|ftp\|xmpp\|postgres\|ldap` | Actualización TLS oportunista |
| `-brief` | Resumen condensado |
| `-msg` / `-trace` / `-state` / `-debug` | Trazado a nivel de handshake |

### 11.3 Sondas dirigidas

```bash
# Is TLS 1.0 still accepted? (Expect failure.)
$ openssl s_client -connect www.example.net:443 -servername www.example.net \
      -tls1 </dev/null 2>&1 | tail -3
40E7B21C7F000000:error:0A0000BF:SSL routines:tls_setup_handshake:no protocols available:ssl/statem/statem_lib.c:104:

# Does the server still offer 3DES? (Expect failure.)
$ openssl s_client -connect www.example.net:443 -servername www.example.net \
      -cipher '3DES' -no_tls1_3 </dev/null 2>&1 | grep -m1 error
40F7C31D7F000000:error:0A000410:SSL routines:ssl3_read_bytes:sslv3 alert handshake failure:ssl/record/rec_layer_s3.c:1584:SSL alert number 40

# Which named group actually got used?
$ openssl s_client -connect www.example.net:443 -servername www.example.net \
      </dev/null 2>/dev/null | grep 'Negotiated TLS1.3 group'
Negotiated TLS1.3 group: X25519

# Session resumption working? "Reused" on connections 2..5 is the goal.
$ openssl s_client -connect www.example.net:443 -servername www.example.net \
      -reconnect </dev/null 2>/dev/null | grep -E '^(New|Reused)'
New, TLSv1.3, Cipher is TLS_AES_256_GCM_SHA384
Reused, TLSv1.3, Cipher is TLS_AES_256_GCM_SHA384
Reused, TLSv1.3, Cipher is TLS_AES_256_GCM_SHA384
Reused, TLSv1.3, Cipher is TLS_AES_256_GCM_SHA384
Reused, TLSv1.3, Cipher is TLS_AES_256_GCM_SHA384

# ALPN — confirm h2 is really on.
$ openssl s_client -connect www.example.net:443 -servername www.example.net \
      -alpn h2,http/1.1 </dev/null 2>/dev/null | grep ALPN
ALPN protocol: h2

# Days until expiry, scriptable.
$ openssl s_client -connect www.example.net:443 -servername www.example.net \
      </dev/null 2>/dev/null | openssl x509 -noout -enddate
notAfter=Nov 16 09:07:55 2026 GMT

# Hard fail on any verification problem — use THIS in monitoring.
$ openssl s_client -connect www.example.net:443 -servername www.example.net \
      -verify_return_error -verify_hostname www.example.net \
      -CAfile /etc/pki/example/root-ca.crt </dev/null >/dev/null 2>&1
$ echo $?
0
```

### 11.4 `s_server` como implementación de referencia

Cuando necesitás demostrar que el que está mal es el *cliente*, levantá un servidor cuya configuración controlás por completo:

```bash
# Plain TLS server with a web page showing the connection details.
$ openssl s_server -accept 4433 \
      -cert /etc/pki/example/certs/www-fullchain.crt \
      -key  /etc/pki/example/private/www.key \
      -www
Using default temp DH parameters
ACCEPT

# Demand and verify a client certificate. -Verify (capital V) = require;
# -verify (lowercase) = request but continue if absent.
$ openssl s_server -accept 4433 \
      -cert  /etc/pki/example/certs/mtls-fullchain.crt \
      -key   /etc/pki/example/private/mtls.key \
      -CAfile /etc/pki/example/root-ca.crt \
      -Verify 2 -www
verify depth is 2, must return a certificate
Using default temp DH parameters
ACCEPT
depth=1 C=AR, O=Example Networks, CN=Example Networks TLS Issuing CA I1
verify return:1
depth=0 C=AR, O=Example Networks, CN=alice@example.net
verify return:1
```

```bash
$ curl -sk --cert alice.crt --key alice.key https://127.0.0.1:4433/ | head -12
<HTML><BODY BGCOLOR="#ffffff">
<pre>

s_server -accept 4433 -cert ... -Verify 2 -www
Ciphers supported in s_server binary
TLSv1.3    :TLS_AES_256_GCM_SHA384    TLSv1.3    :TLS_CHACHA20_POLY1305_SHA256
...
Client certificate
Certificate:
    Data:
        Version: 3 (0x2)
        Serial Number:
            5c:3f:1a:9e:44:7b:20:d1:8f:6a:cc:03:19:be:77:61
```

### 11.5 Leer la lista local de cifradores

```bash
$ openssl ciphers -v 'ECDHE+AESGCM:ECDHE+CHACHA20:!aNULL' | column -t
TLS_AES_256_GCM_SHA384         TLSv1.3  Kx=any    Au=any    Enc=AESGCM(256)      Mac=AEAD
TLS_CHACHA20_POLY1305_SHA256   TLSv1.3  Kx=any    Au=any    Enc=CHACHA20/POLY1305(256) Mac=AEAD
TLS_AES_128_GCM_SHA256         TLSv1.3  Kx=any    Au=any    Enc=AESGCM(128)      Mac=AEAD
ECDHE-ECDSA-AES256-GCM-SHA384  TLSv1.2  Kx=ECDH   Au=ECDSA  Enc=AESGCM(256)      Mac=AEAD
ECDHE-RSA-AES256-GCM-SHA384    TLSv1.2  Kx=ECDH   Au=RSA    Enc=AESGCM(256)      Mac=AEAD
ECDHE-ECDSA-CHACHA20-POLY1305  TLSv1.2  Kx=ECDH   Au=ECDSA  Enc=CHACHA20/POLY1305(256) Mac=AEAD
ECDHE-RSA-CHACHA20-POLY1305    TLSv1.2  Kx=ECDH   Au=RSA    Enc=CHACHA20/POLY1305(256) Mac=AEAD
ECDHE-ECDSA-AES128-GCM-SHA256  TLSv1.2  Kx=ECDH   Au=ECDSA  Enc=AESGCM(128)      Mac=AEAD
ECDHE-RSA-AES128-GCM-SHA256    TLSv1.2  Kx=ECDH   Au=RSA    Enc=AESGCM(128)      Mac=AEAD
```

Notá que las suites de TLS 1.3 aparecen sin importar la cadena de filtro: no son seleccionables mediante la gramática de listas de cifradores de TLS ≤ 1.2. Es la misma asimetría que `SSLCipherSuite` vs `SSLCipherSuite TLSv1.3`.

---

## 12. Infraestructura de contenedores y Kubernetes

Los manifiestos de abajo despliegan la configuración de §6 como un servicio `mod_ssl` enrutado por SNI con terminación por passthrough y mTLS, con certificados emitidos por cert-manager desde la misma CA de dos niveles.

### 12.1 `Dockerfile`

```dockerfile
FROM registry.access.redhat.com/ubi9/ubi-minimal:9.4

RUN microdnf install -y httpd mod_ssl openssl shadow-utils \
    && microdnf clean all \
    && rm -f /etc/httpd/conf.d/ssl.conf /etc/httpd/conf.d/welcome.conf \
    && sed -i 's/^Listen 80$/Listen 8080/' /etc/httpd/conf/httpd.conf \
    && install -d -o apache -g apache -m 0755 /run/httpd /var/log/httpd

# Run unprivileged: ports are 8080/8443, not 80/443.
USER 1001

EXPOSE 8080 8443
STOPSIGNAL SIGWINCH

HEALTHCHECK --interval=15s --timeout=5s --start-period=10s --retries=3 \
  CMD /usr/bin/openssl s_client -connect 127.0.0.1:8443 \
        -servername mtls.example.net -verify_return_error \
        -CAfile /etc/pki/example/root-ca.crt \
        -cert /etc/pki/example/probe/tls.crt \
        -key  /etc/pki/example/probe/tls.key </dev/null >/dev/null 2>&1

CMD ["/usr/sbin/httpd", "-DFOREGROUND"]
```

### 12.2 Paquete completo de Kubernetes

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: edge
  labels:
    pod-security.kubernetes.io/enforce: restricted
---
# ---------------------------------------------------------------------------
# PKI: bootstrap self-signed -> root CA -> issuing CA -> leaf certificates.
# Mirrors the openssl two-tier hierarchy from section 5.
# ---------------------------------------------------------------------------
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-bootstrap
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: example-root-ca
  namespace: cert-manager
spec:
  isCA: true
  commonName: Example Networks Root CA R1
  subject:
    countries: ["AR"]
    organizations: ["Example Networks"]
  secretName: example-root-ca
  duration: 87600h    # 10 years
  renewBefore: 8760h  # 1 year
  privateKey:
    algorithm: RSA
    size: 4096
    encoding: PKCS8
    rotationPolicy: Never
  usages:
    - cert sign
    - crl sign
  issuerRef:
    name: selfsigned-bootstrap
    kind: ClusterIssuer
    group: cert-manager.io
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: example-root-ca
spec:
  ca:
    secretName: example-root-ca
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: example-issuing-ca
  namespace: cert-manager
spec:
  isCA: true
  commonName: Example Networks TLS Issuing CA I1
  subject:
    countries: ["AR"]
    organizations: ["Example Networks"]
  secretName: example-issuing-ca
  duration: 43800h    # 5 years
  renewBefore: 4380h
  privateKey:
    algorithm: RSA
    size: 3072
    encoding: PKCS8
    rotationPolicy: Never
  usages:
    - cert sign
    - crl sign
  issuerRef:
    name: example-root-ca
    kind: ClusterIssuer
    group: cert-manager.io
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: example-issuing-ca
spec:
  ca:
    secretName: example-issuing-ca
---
# ---------------------------------------------------------------------------
# Leaf certificates. tls.crt from a CA issuer already contains leaf+intermediate
# (cert-manager appends the issuer chain), which is exactly what
# SSLCertificateFile wants. ca.crt holds the root — the CLIENT trust anchor.
# ---------------------------------------------------------------------------
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: www-tls
  namespace: edge
spec:
  secretName: www-tls
  commonName: www.example.net
  dnsNames:
    - www.example.net
    - example.net
    - static.example.net
  duration: 2160h      # 90 days
  renewBefore: 720h    # 30 days
  privateKey:
    algorithm: ECDSA
    size: 256
    rotationPolicy: Always
  usages:
    - digital signature
    - server auth
  issuerRef:
    name: example-issuing-ca
    kind: ClusterIssuer
    group: cert-manager.io
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: mtls-tls
  namespace: edge
spec:
  secretName: mtls-tls
  commonName: mtls.example.net
  dnsNames:
    - mtls.example.net
  duration: 2160h
  renewBefore: 720h
  privateKey:
    algorithm: ECDSA
    size: 256
    rotationPolicy: Always
  usages:
    - digital signature
    - server auth
  issuerRef:
    name: example-issuing-ca
    kind: ClusterIssuer
    group: cert-manager.io
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: probe-client
  namespace: edge
spec:
  secretName: probe-client
  commonName: probe@example.net
  subject:
    organizationalUnits: ["platform"]
  duration: 2160h
  renewBefore: 720h
  privateKey:
    algorithm: ECDSA
    size: 256
    rotationPolicy: Always
  usages:
    - digital signature
    - client auth
  issuerRef:
    name: example-issuing-ca
    kind: ClusterIssuer
    group: cert-manager.io
---
# ---------------------------------------------------------------------------
# httpd configuration
# ---------------------------------------------------------------------------
apiVersion: v1
kind: ConfigMap
metadata:
  name: httpd-tls-config
  namespace: edge
data:
  00-ssl-global.conf: |
    Listen 8443 https

    SSLRandomSeed startup file:/dev/urandom 512
    SSLRandomSeed connect builtin

    SSLSessionCache        shmcb:/run/httpd/sslcache(512000)
    SSLSessionCacheTimeout 300
    SSLSessionTickets      on
    SSLStaplingCache       shmcb:/run/httpd/stapling-cache(256000)

    SSLProtocol            -all +TLSv1.2 +TLSv1.3
    SSLCipherSuite         ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305
    SSLCipherSuite TLSv1.3 TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:TLS_AES_128_GCM_SHA256
    SSLHonorCipherOrder    off
    SSLCompression         off
    SSLOpenSSLConfCmd      Groups X25519:secp256r1:secp384r1
    SSLStrictSNIVHostCheck on

    LogFormat "%h %t \"%r\" %>s %b proto=%{SSL_PROTOCOL}x cipher=%{SSL_CIPHER}x sni=%{SSL_TLS_SNI}x cvfy=%{SSL_CLIENT_VERIFY}x cdn=\"%{SSL_CLIENT_S_DN}x\"" tls_combined
    ErrorLogFormat "[%{u}t] [%-m:%l] [pid %P] %F: %E: [client %a] %M"

  10-www.conf: |
    <VirtualHost *:8443>
        ServerName  www.example.net
        ServerAlias example.net static.example.net
        DocumentRoot /var/www/html
        Protocols h2 http/1.1

        SSLEngine on
        SSLCertificateFile    /etc/pki/example/www/tls.crt
        SSLCertificateKeyFile /etc/pki/example/www/tls.key

        SSLUseStapling                   on
        SSLStaplingResponderTimeout      5
        SSLStaplingReturnResponderErrors off
        SSLStaplingErrorCacheTimeout     120

        Header always set Strict-Transport-Security "max-age=63072000; includeSubDomains"
        Header always set X-Content-Type-Options "nosniff"

        <Directory "/var/www/html">
            Options -Indexes
            Require all granted
        </Directory>

        CustomLog /dev/stdout tls_combined
        ErrorLog  /dev/stderr
        LogLevel  warn ssl:info
    </VirtualHost>

  20-mtls.conf: |
    <VirtualHost *:8443>
        ServerName mtls.example.net
        DocumentRoot /var/www/html
        Protocols http/1.1

        SSLEngine on
        SSLCertificateFile    /etc/pki/example/mtls/tls.crt
        SSLCertificateKeyFile /etc/pki/example/mtls/tls.key

        SSLCACertificateFile  /etc/pki/example/mtls/ca.crt
        SSLVerifyClient       require
        SSLVerifyDepth        2
        SSLOptions            +StdEnvVars +ExportCertData +StrictRequire
        SSLUserName           SSL_CLIENT_S_DN_CN

        <Location "/">
            SSLRequireSSL
            SSLRequire %{SSL_CLIENT_VERIFY} eq "SUCCESS" \
                       and %{SSL_CLIENT_S_DN_OU} in {"platform", "sre"}
            Require all granted
        </Location>

        RequestHeader unset X-Client-DN early
        RequestHeader set   X-Client-DN "%{SSL_CLIENT_S_DN}s"

        CustomLog /dev/stdout tls_combined
        ErrorLog  /dev/stderr
        LogLevel  warn ssl:info
    </VirtualHost>
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: httpd-tls
  namespace: edge
  annotations:
    # Restart pods when any mounted Secret/ConfigMap changes. Without this,
    # kubelet updates the files on disk but httpd keeps the OLD certificate
    # in memory until the process is reloaded. This is the #1 cause of
    # "cert-manager renewed it but the server still serves the expired one".
    reloader.stakater.com/auto: "true"
spec:
  replicas: 3
  revisionHistoryLimit: 3
  selector:
    matchLabels:
      app.kubernetes.io/name: httpd-tls
  template:
    metadata:
      labels:
        app.kubernetes.io/name: httpd-tls
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1001
        fsGroup: 1001
        seccompProfile:
          type: RuntimeDefault
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: httpd-tls
      containers:
        - name: httpd
          image: registry.example.net/edge/httpd-tls:1.4.2
          imagePullPolicy: IfNotPresent
          ports:
            - name: https
              containerPort: 8443
              protocol: TCP
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          resources:
            requests: {cpu: "100m", memory: "128Mi"}
            limits:   {cpu: "1",    memory: "512Mi"}
          volumeMounts:
            - {name: httpd-config, mountPath: /etc/httpd/conf.d, readOnly: true}
            - {name: www-tls,      mountPath: /etc/pki/example/www,   readOnly: true}
            - {name: mtls-tls,     mountPath: /etc/pki/example/mtls,  readOnly: true}
            - {name: probe-client, mountPath: /etc/pki/example/probe, readOnly: true}
            - {name: root-ca,      mountPath: /etc/pki/example,       readOnly: true}
            - {name: run,          mountPath: /run/httpd}
            - {name: docroot,      mountPath: /var/www/html, readOnly: true}
          startupProbe:
            tcpSocket: {port: https}
            failureThreshold: 12
            periodSeconds: 5
          readinessProbe:
            # TCP only: an httpGet probe cannot present a client certificate,
            # and this port requires one on the mtls vhost. The real TLS check
            # is the container HEALTHCHECK / the external synthetic monitor.
            tcpSocket: {port: https}
            periodSeconds: 10
          livenessProbe:
            tcpSocket: {port: https}
            periodSeconds: 20
            failureThreshold: 3
          lifecycle:
            preStop:
              exec:
                command: ["/usr/sbin/httpd", "-k", "graceful-stop"]
      terminationGracePeriodSeconds: 45
      volumes:
        - name: httpd-config
          configMap: {name: httpd-tls-config}
        - name: www-tls
          secret: {secretName: www-tls, defaultMode: 0400}
        - name: mtls-tls
          secret: {secretName: mtls-tls, defaultMode: 0400}
        - name: probe-client
          secret: {secretName: probe-client, defaultMode: 0400}
        - name: root-ca
          secret:
            secretName: example-root-ca
            items: [{key: ca.crt, path: root-ca.crt}]
            defaultMode: 0444
        - name: run
          emptyDir: {medium: Memory}
        - name: docroot
          configMap: {name: httpd-docroot, optional: true}
---
apiVersion: v1
kind: Service
metadata:
  name: httpd-tls
  namespace: edge
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: httpd-tls
  ports:
    - name: https
      port: 443
      targetPort: https
      protocol: TCP
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: httpd-tls
  namespace: edge
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: httpd-tls
---
# ---------------------------------------------------------------------------
# SSL passthrough. The ingress routes on SNI at L4 and does NOT terminate TLS,
# which is the only way the client certificate reaches mod_ssl. The cost:
# no path-based routing, no L7 logs, no WAF at the edge for this host.
# ---------------------------------------------------------------------------
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: httpd-tls
  namespace: edge
  annotations:
    nginx.ingress.kubernetes.io/ssl-passthrough: "true"
    nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
spec:
  ingressClassName: nginx
  rules:
    - host: www.example.net
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: httpd-tls
                port: {name: https}
    - host: mtls.example.net
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: httpd-tls
                port: {name: https}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: httpd-tls
  namespace: edge
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: httpd-tls
  policyTypes: [Ingress, Egress]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels: {kubernetes.io/metadata.name: ingress-nginx}
      ports:
        - {protocol: TCP, port: 8443}
  egress:
    # DNS
    - to:
        - namespaceSelector:
            matchLabels: {kubernetes.io/metadata.name: kube-system}
      ports:
        - {protocol: UDP, port: 53}
        - {protocol: TCP, port: 53}
    # OCSP responder — WITHOUT this rule, SSLUseStapling silently fails and
    # the server serves no staple. Must-staple certs would break outright.
    - to:
        - ipBlock: {cidr: 0.0.0.0/0, except: ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]}
      ports:
        - {protocol: TCP, port: 80}
```

Dos notas que vale la pena internalizar:

- **`reloader.stakater.com/auto`** (o un equivalente: un sidecar que vigile cambios de inodo, o pods de vida corta) no es opcional. Que cert-manager renueve un `Secret` no reinicia `httpd`, y `httpd` lee los certificados una sola vez al arrancar. Todo incidente de "la renovación no surtió efecto" se remonta a esto.
- La **regla de egress al puerto 80** existe únicamente para OCSP. Cerrar el egress sin ella produce una falla de stapling que ningún `apachectl configtest` va a detectar jamás.

---

## 13. Verificación y diagnóstico de fallas

### 13.1 Orden de operaciones

```
1. apachectl -t                     → config syntax
2. apachectl -S                     → which vhost owns which name:port
3. openssl x509 -noout -text        → is the certificate what I think it is?
4. openssl verify -untrusted        → does the chain build, locally?
5. openssl s_client -showcerts      → does the SERVER send that chain?
6. openssl s_client -status         → is there a staple, and is it good?
7. curl -v with real trust store    → does a real client accept it?
8. LogLevel ssl:trace3 + error log  → why not
```

### 13.2 Fallas de configuración y arranque

| Síntoma | Causa | Solución |
|---|---|---|
| `AH00526: Syntax error ... Invalid command 'SSLEngine'` | `mod_ssl` no está cargado | `LoadModule ssl_module modules/mod_ssl.so`; en Debian `a2enmod ssl` |
| `AH02572: Failed to configure at least one certificate and key for <vhost>` | La clave no coincide con el certificado, el archivo no es legible, o el tipo de clave no está soportado | §13.3 |
| `AH02565: Certificate and private key ... do not match` | Archivo de clave equivocado | §13.3 |
| `AH01909: server certificate does NOT include an ID which matches the server name` | `ServerName` no está en el SAN | Reemitir con los SANs correctos |
| `AH01906: server certificate is a CA certificate` | Configuraste el certificado de la CA como hoja | Apuntá `SSLCertificateFile` a la hoja |
| `AH02217: ssl_stapling_init_cert: Can't retrieve issuer certificate!` | Falta la intermedia en `SSLCertificateFile` | Construí un archivo fullchain |
| Error de `SSLStaplingCache` al arrancar | Directiva ubicada dentro de `<VirtualHost>` | Movela al ámbito de servidor |
| `Init: Private key not found` | Clave cifrada, sin fuente de passphrase | Descifrá la clave, o configurá `SSLPassPhraseDialog` |
| Permiso denegado sobre la clave | modo/propietario, o SELinux | §13.6 |

### 13.3 ¿La clave coincide con el certificado?

La receta clásica solo funciona para RSA:

```bash
# RSA only
$ openssl x509 -noout -modulus -in www-rsa.crt | openssl sha256
SHA2-256(stdin)= 4b1c0e77a9f2ee1d8c33b7d5906a41f88c2e5b09ad7431f6ee20cd9a4f7b8123
$ openssl rsa  -noout -modulus -in www-rsa.key | openssl sha256
SHA2-256(stdin)= 4b1c0e77a9f2ee1d8c33b7d5906a41f88c2e5b09ad7431f6ee20cd9a4f7b8123
```

La versión **agnóstica del algoritmo** — usá siempre esta, funciona para RSA, ECDSA y Ed25519, y también funciona contra un CSR:

```bash
$ openssl x509 -in www.crt -noout -pubkey | openssl pkey -pubin -outform DER | openssl sha256
SHA2-256(stdin)= 9d2f4a771c05e8b3116ae0d47f2c9b80a3e6157dc4b98021ff7e3a6c50d1b774
$ openssl pkey -in www.key -pubout -outform DER | openssl sha256
SHA2-256(stdin)= 9d2f4a771c05e8b3116ae0d47f2c9b80a3e6157dc4b98021ff7e3a6c50d1b774
$ openssl req  -in www.csr -noout -pubkey | openssl pkey -pubin -outform DER | openssl sha256
SHA2-256(stdin)= 9d2f4a771c05e8b3116ae0d47f2c9b80a3e6157dc4b98021ff7e3a6c50d1b774
```

Tres digests idénticos significan que el certificado, la clave y el CSR son una misma terna. Cualquier otra cosa es `AH02572`.

### 13.4 Fallas de handshake, decodificadas

| Error visible para el cliente | Alerta TLS | Causa raíz | Dónde mirar |
|---|---|---|---|
| `unable to get local issuer certificate` (verify 20) | — | El servidor no envió la intermedia | `s_client -showcerts`: contá los certificados |
| `unable to verify the first certificate` (21) | — | Lo mismo, desde el ángulo del cliente | Construí un archivo fullchain |
| `self-signed certificate in certificate chain` (19) | — | La raíz privada no está en el almacén de confianza del cliente | `-CAfile`, o instalá la raíz |
| `certificate has expired` (10) | 45 `certificate_expired` | Vencimiento — o desfasaje del reloj del cliente | `openssl x509 -noout -dates`; `timedatectl` |
| `Hostname mismatch` (62) | — | El nombre no está en el SAN; o no se envió SNI | `-servername`, después verificá los SANs |
| `tlsv1 alert unknown ca` | 48 | El certificado **del cliente** no es verificable por el servidor | `SSLVerifyDepth`, `SSLCACertificateFile`, CRL |
| `tlsv13 alert certificate required` | 116 | `SSLVerifyClient require`, no se ofreció certificado | Proporcioná `-cert`/`-key` |
| `sslv3 alert handshake failure` | 40 | Sin cifrador / grupo / sigalg compartido | `SSLCipherSuite`, `Groups`, tipo de clave del certificado |
| `no protocols available` | — | Del lado del cliente: versión excluida localmente | `SSLProtocol`/`MinProtocol` del cliente |
| `tlsv1 alert protocol version` | 70 | Ninguna versión de TLS habilitada mutuamente | `SSLProtocol` en ambos extremos |
| `unrecognized name` | 112 | `SSLStrictSNIVHostCheck on`, SNI desconocido | Agregá `ServerAlias`, o enviá el SNI correcto |
| `wrong version number` | — | **Hablaste TLS a un puerto en texto plano** | Verificá el puerto; verificá `SSLEngine on` |
| `certificate revoked` | 44 | CRL/OCSP dicen que sí | Es lo esperado — o una CRL rancia |
| `decrypt_error` | 51 | La firma de `CertificateVerify` falló | Discrepancia entre clave y certificado del lado del cliente |

`wrong version number` merece énfasis porque parece un problema de negociación de protocolo y nunca lo es. Significa que los bytes que volvieron no eran un registro TLS en absoluto — normalmente una respuesta HTTP, porque te conectaste al puerto 80 o llegaste a un vhost sin `SSLEngine on`.

### 13.5 Trazado del lado del servidor

```bash
# Per-module log level; do NOT set LogLevel trace globally in production.
$ sudo sed -i 's/^LogLevel .*/LogLevel warn ssl:trace3/' /etc/httpd/conf/httpd.conf
$ sudo apachectl graceful
$ sudo tail -f /var/log/httpd/error_log
[ssl:info] [pid 2214] [client 198.51.100.20:51512] AH01964: Connection to child 0 established (server mtls.example.net:443)
[ssl:trace3] [pid 2214] ssl_engine_kernel.c(2263): [client 198.51.100.20:51512] OpenSSL: Handshake: start
[ssl:trace3] [pid 2214] ssl_engine_kernel.c(2272): [client 198.51.100.20:51512] OpenSSL: Loop: before SSL initialization
[ssl:trace3] [pid 2214] ssl_engine_kernel.c(2247): [client 198.51.100.20:51512] OpenSSL: read finished A
[ssl:info]  [pid 2214] [client 198.51.100.20:51512] AH02275: Certificate Verification: Error (20): unable to get local issuer certificate
[ssl:info]  [pid 2214] [client 198.51.100.20:51512] AH02008: SSL library error 1 in handshake (server mtls.example.net:443)
[ssl:info]  [pid 2214] SSL Library Error: error:0A000086:SSL routines::certificate verify failed
```

`Error (20)` sobre un certificado *de cliente* casi siempre significa que `SSLVerifyDepth` es demasiado chico o que la intermedia está ausente del bundle de CAs de cliente del servidor. Acordate de volver a poner `LogLevel` como estaba.

### 13.6 Permisos de archivos y SELinux

```bash
$ sudo ls -lZ /etc/pki/example/private/
-rw-------. 1 root root system_u:object_r:cert_t:s0 241 Aug 18 09:07 www.key

$ sudo restorecon -Rv /etc/pki/example
Relabeled /etc/pki/example/private/www.key from unconfined_u:object_r:user_home_t:s0 to system_u:object_r:cert_t:s0

# Non-standard path? Label it, do not disable SELinux.
$ sudo semanage fcontext -a -t cert_t '/opt/tls(/.*)?'
$ sudo restorecon -Rv /opt/tls

# Non-standard port? Same principle.
$ sudo semanage port -a -t http_port_t -p tcp 8443

$ sudo ausearch -m avc -ts recent | audit2why
```

httpd lee la clave como root antes de bajar privilegios, así que `0600 root:root` es lo correcto. Una clave legible por el usuario `apache` es un hallazgo, no una comodidad.

### 13.7 Cuando tenés que ver los bytes

```bash
# Handshake only; the rest is encrypted anyway.
$ sudo tshark -i any -f 'tcp port 443' -Y 'tls.handshake' \
      -T fields -e ip.src -e tls.handshake.type \
      -e tls.handshake.extensions_server_name -e tls.handshake.version
198.51.100.20  1   www.example.net  0x0303
203.0.113.10   2                    0x0303
203.0.113.10   11
203.0.113.10   15

# Decrypt application data in a lab: point the client at a key log file and
# hand the file to Wireshark (Preferences > Protocols > TLS > Pre-Master-Secret
# log filename). Works for TLS 1.3 too, where the server key alone cannot
# decrypt anything because of forward secrecy.
$ SSLKEYLOGFILE=/tmp/keys.log curl -s https://www.example.net/ >/dev/null
$ head -2 /tmp/keys.log
SERVER_HANDSHAKE_TRAFFIC_SECRET 3f7a...  9b21...
CLIENT_HANDSHAKE_TRAFFIC_SECRET 3f7a...  4c88...
```

Ese último punto vale la pena enunciarlo explícitamente para el examen: con ECDHE (y por lo tanto con todo TLS 1.3), poseer la clave privada del servidor **no** te permite descifrar tráfico capturado. Eso es forward secrecy, y es la razón operativa por la que `!kRSA` está en toda cadena de cifradores moderna.

### 13.8 Auditoría de vencimientos en toda la flota

```bash
#!/bin/bash
# /usr/local/bin/tls-audit — one line per endpoint, sorted by urgency
set -uo pipefail
printf '%-32s %-10s %-26s %-8s %s\n' HOST DAYS ISSUER STAPLE PROTO
while read -r host port; do
  out=$(timeout 8 openssl s_client -connect "${host}:${port}" \
          -servername "$host" -status </dev/null 2>/dev/null) || {
        printf '%-32s %-10s %s\n' "$host" "-" "CONNECT FAILED"; continue; }

  end=$(openssl x509 -noout -enddate <<<"$out" 2>/dev/null | cut -d= -f2)
  days=$(( ( $(date -u -d "$end" +%s) - $(date -u +%s) ) / 86400 ))
  iss=$(openssl x509 -noout -issuer <<<"$out" 2>/dev/null | sed 's/.*CN *= *//')
  proto=$(sed -n 's/^ *Protocol *: *//p' <<<"$out" | head -1)
  if grep -q 'Cert Status: good' <<<"$out"; then staple=good
  elif grep -q 'OCSP response: no response sent' <<<"$out"; then staple=ABSENT
  else staple=BAD; fi

  printf '%-32s %-10s %-26s %-8s %s\n' "$host" "$days" "${iss:0:26}" "$staple" "$proto"
done < /etc/tls-audit.targets | (read -r h; echo "$h"; sort -k2 -n)
```

```bash
$ tls-audit
HOST                             DAYS       ISSUER                     STAPLE   PROTO
mtls.example.net                 11         Example Networks TLS Issu  ABSENT   TLSv1.3
api.example.net                  34         Example Networks TLS Issu  good     TLSv1.3
www.example.net                  89         Example Networks TLS Issu  good     TLSv1.3
legacy.example.net               412        Example Networks Root CA   ABSENT   TLSv1.2
```

Dos hallazgos son visibles de un vistazo: a `mtls` le quedan 11 días y no tiene staple, y `legacy` está firmado **directamente por la raíz** con una vida de 412 días — un certificado que evita por completo la intermedia y por lo tanto evita tus name constraints y tu proceso de revocación.

---

## 14. Renovación, rotación y recarga

### 14.1 Semántica de la recarga

| Comando | Efecto sobre las conexiones en vuelo | Relee los certificados |
|---|---|---|
| `apachectl graceful` / `httpd -k graceful` | Termina las peticiones en curso, después salen los hijos | **sí** |
| `apachectl restart` | ¿Igual que graceful en 2.4 para `-k restart`? No — un reinicio duro corta las conexiones | sí |
| `systemctl reload httpd` | mapea a `graceful` | sí |
| `systemctl restart httpd` | corta las conexiones | sí |
| `apachectl -k graceful-stop` | drenar y después parar, para despliegues rodantes | n/a |

**Siempre `graceful` para la rotación de certificados.** Un reinicio duro durante una renovación convierte una operación rutinaria en un corte visible.

### 14.2 `mod_md` — ACME dentro de httpd

httpd 2.4.30+ incluye un cliente ACME. Sin cron, sin certbot externo, sin hook de recarga:

```apache
LoadModule md_module modules/mod_md.so

MDCertificateAgreement accepted
MDContactEmail         platform@example.net
MDCertificateAuthority https://acme-v02.api.letsencrypt.org/directory
MDStoreDir             /var/www/md
MDPrivateKeys          secp384r1 rsa3072      # dual-cert, automatically
MDRenewWindow          33%
MDStapling             on                    # mod_md's own stapling, replaces mod_ssl's
MDMessageCmd           /usr/local/bin/md-notify

MDomain www.example.net example.net static.example.net

<VirtualHost *:443>
    ServerName  www.example.net
    ServerAlias example.net static.example.net
    SSLEngine on
    # No SSLCertificateFile / SSLCertificateKeyFile: mod_md supplies them.
    Header always set Strict-Transport-Security "max-age=63072000; includeSubDomains"
</VirtualHost>
```

```bash
$ sudo apachectl -M | grep md_
 md_module (shared)

$ curl -s http://localhost/.httpd/certificate-status | python3 -m json.tool
{
    "valid": {"from": "2026-08-18T09:07:55Z", "until": "2026-11-16T09:07:55Z"},
    "serial": "5C3F1A9E447B20D18F6ACC0319BE7754",
    "sha256-fingerprint": "9d2f4a77...",
    "renewal": {"finished": false, "notified": false, "last-run": "2026-08-18T09:07:55Z"}
}
```

`MDStapling on` reemplaza a `SSLUseStapling` para los dominios gestionados por `mod_md`, con su propia caché y política de reintentos. No configures ambos para el mismo vhost.

### 14.3 `certbot` con un hook de recarga

```bash
$ sudo certbot certonly --webroot -w /var/www/acme \
      -d www.example.net -d example.net -d static.example.net \
      --key-type ecdsa --elliptic-curve secp256r1 \
      --deploy-hook '/usr/bin/apachectl graceful'
Saving debug log to /var/log/letsencrypt/letsencrypt.log
Requesting a certificate for www.example.net and 2 more domains
Successfully received certificate.
Certificate is saved at: /etc/letsencrypt/live/www.example.net/fullchain.pem
Key is saved at:         /etc/letsencrypt/live/www.example.net/privkey.pem
This certificate expires on 2026-11-16.

$ sudo certbot renew --dry-run
Congratulations, all simulated renewals succeeded:
  /etc/letsencrypt/live/www.example.net/fullchain.pem (success)
```

`--deploy-hook` se ejecuta **solo cuando realmente se renovó un certificado**; `--post-hook` se ejecuta en cada intento. Usar `--post-hook` para la recarga significa un reinicio graceful cada doce horas para siempre.

| Estrategia | Dónde vive la clave privada | Disparador de recarga | Mejor para |
|---|---|---|---|
| `mod_md` | el `MDStoreDir` de httpd | interno, sin reinicio | Apache en un solo host |
| `certbot --deploy-hook` | `/etc/letsencrypt/live` | hook | VMs clásicas, gestión de configuración |
| cert-manager + reloader | `Secret` de Kubernetes | reinicio del pod | Kubernetes |
| Vault PKI + plantilla del agente | tmpfs, TTL corto | el agente señaliza `SIGWINCH`/recarga | flotas dinámicas, certificados de 24 h |

---

## 15. Resumen orientado al examen

**Directivas que tenés que ser capaz de escribir de memoria:** `SSLEngine`, `SSLCertificateFile`, `SSLCertificateKeyFile`, `SSLCertificateChainFile` (y por qué está obsoleta), `SSLCACertificateFile`/`Path`, `SSLProtocol`, `SSLCipherSuite`, `SSLHonorCipherOrder`, `SSLVerifyClient`, `SSLVerifyDepth`, `SSLUseStapling`, `SSLStaplingCache`, `SSLOptions`, `SSLRequire`, `SSLStrictSNIVHostCheck`.

**Las ocho trampas:**

1. `SSLStaplingCache` y `SSLSessionCache` son **solo de ámbito de servidor**.
2. La cadena servida es **hoja → intermedias**, nunca la raíz, y el orden importa.
3. `SSLVerifyDepth` cuenta las intermedias *entre* la hoja y el ancla; el valor por defecto `1` es demasiado chico para una PKI de dos niveles anclada en la raíz.
4. `SSLCipherSuite` sin el argumento `TLSv1.3` no toca las suites de TLS 1.3.
5. `SSLCACertificatePath` y `SSLCARevocationPath` necesitan `openssl rehash`; sin él fallan **abiertas**.
6. Sin SNI, o con SNI no coincidente, se sirve el **primer** vhost de esa dirección:puerto — salvo con `SSLStrictSNIVHostCheck on`.
7. HSTS en una respuesta HTTP plana se ignora; `Header set` sin `always` la descarta de las respuestas de error.
8. `Secure Renegotiation IS NOT supported` en TLS 1.3 es correcto, no una vulnerabilidad.

**El modelo mental de una línea:** en TLS 1.3 el certificado X.509 no cifra — **firma** la transcripción del handshake para que el acuerdo efímero de claves quede **autenticado**. Cifrado, firma, autenticación: tres palabras en el título del objetivo, y solo dos de ellas siguen describiendo lo que hace el certificado en una conexión moderna.

---

## Referencias

**LPI**
- Objetivos del examen 303-300 (LPIC-3 Security): https://www.lpi.org/our-certifications/exam-303-objectives/
- Descripción general de la certificación LPIC-3 Security: https://www.lpi.org/our-certifications/lpic-3-security-overview/

**Apache HTTPD**
- Referencia de directivas de `mod_ssl`: https://httpd.apache.org/docs/2.4/mod/mod_ssl.html
- SSL/TLS Strong Encryption: How-To: https://httpd.apache.org/docs/2.4/ssl/ssl_howto.html
- SSL/TLS Strong Encryption: FAQ: https://httpd.apache.org/docs/2.4/ssl/ssl_faq.html
- SSL/TLS Strong Encryption: Compatibility: https://httpd.apache.org/docs/2.4/ssl/ssl_compat.html
- Soporte de hosts virtuales por nombre (SNI): https://httpd.apache.org/docs/2.4/vhosts/name-based.html
- `mod_md` (ACME / Let's Encrypt): https://httpd.apache.org/docs/2.4/mod/mod_md.html
- `mod_headers`: https://httpd.apache.org/docs/2.4/mod/mod_headers.html
- `apachectl`: https://httpd.apache.org/docs/2.4/programs/apachectl.html

**OpenSSL**
- `s_client`: https://docs.openssl.org/master/man1/openssl-s_client/
- `s_server`: https://docs.openssl.org/master/man1/openssl-s_server/
- `x509`: https://docs.openssl.org/master/man1/openssl-x509/
- `verify` y códigos de error de verificación: https://docs.openssl.org/master/man1/openssl-verify/
- `ca`: https://docs.openssl.org/master/man1/openssl-ca/
- `ocsp`: https://docs.openssl.org/master/man1/openssl-ocsp/
- `ciphers` y gramática de listas de cifradores: https://docs.openssl.org/master/man1/openssl-ciphers/
- `x509v3_config` (sintaxis de extensiones): https://docs.openssl.org/master/man5/x509v3_config/

**Estándares IETF**
- RFC 5280 — Perfil de certificados y CRL de PKI X.509: https://www.rfc-editor.org/rfc/rfc5280
- RFC 5246 — TLS 1.2: https://www.rfc-editor.org/rfc/rfc5246
- RFC 8446 — TLS 1.3: https://www.rfc-editor.org/rfc/rfc8446
- RFC 6066 — Extensiones de TLS (SNI, `status_request`): https://www.rfc-editor.org/rfc/rfc6066
- RFC 6960 — OCSP: https://www.rfc-editor.org/rfc/rfc6960
- RFC 6961 — Extensión de estado de múltiples certificados: https://www.rfc-editor.org/rfc/rfc6961
- RFC 7633 — Extensión TLS Feature (must-staple): https://www.rfc-editor.org/rfc/rfc7633
- RFC 6797 — HTTP Strict Transport Security: https://www.rfc-editor.org/rfc/rfc6797
- RFC 6125 — Identidad de servicio en X.509: https://www.rfc-editor.org/rfc/rfc6125
- RFC 5746 — Indicación de renegociación en TLS: https://www.rfc-editor.org/rfc/rfc5746
- RFC 7507 — TLS Fallback SCSV: https://www.rfc-editor.org/rfc/rfc7507
- RFC 8996 — Obsolescencia de TLS 1.0 y 1.1: https://www.rfc-editor.org/rfc/rfc8996
- RFC 7568 — Obsolescencia de SSLv3: https://www.rfc-editor.org/rfc/rfc7568
- RFC 8740 — Uso de TLS 1.3 con HTTP/2: https://www.rfc-editor.org/rfc/rfc8740
- RFC 9113 — HTTP/2: https://www.rfc-editor.org/rfc/rfc9113
- RFC 6844 / 8659 — CAA en DNS: https://www.rfc-editor.org/rfc/rfc8659
- RFC 6962 — Certificate Transparency: https://www.rfc-editor.org/rfc/rfc6962

**Referencias operativas**
- Generador de configuración SSL de Mozilla: https://ssl-config.mozilla.org/
- Guías de TLS del lado del servidor de Mozilla: https://wiki.mozilla.org/Security/Server_Side_TLS
- Envío a la lista de preload de HSTS: https://hstspreload.org/
- Baseline Requirements del CA/Browser Forum: https://cabforum.org/baseline-requirements-documents/
- Documentación de cert-manager: https://cert-manager.io/docs/
- Guía de usuario de Certbot: https://eff-certbot.readthedocs.io/en/stable/using.html
- NIST SP 800-52 Rev. 2 — Guías de TLS: https://csrc.nist.gov/pubs/sp/800/52/r2/final