# 331.2 — Certificados X.509 para cifrado, firma y autenticación
## Ejercicios guiados: servicios TLS con Apache HTTPD, nginx y OpenSSL

**Certificación:** LPIC-3 Security — examen 303-300, v3.0.0 · **Peso del objetivo:** 6.67

Estos ejercicios asumen un único host Linux (Debian 12+ / Ubuntu 24.04 o RHEL 9 / Rocky 9) con acceso `root`, OpenSSL 3.x, Apache HTTPD 2.4.36+ y nginx 1.24+. Todo se ejecuta contra loopback con el TLD reservado por RFC 6761 `.test`, así que nada sale de la máquina.

Verificá tu línea base antes de empezar — varios pasos dependen del soporte de TLS 1.3 **tanto** en la biblioteca como en el servidor:

```bash
openssl version -a | head -2
apachectl -v ; apachectl -M 2>/dev/null | grep -E 'ssl|headers|socache'
nginx -V 2>&1 | tr ' ' '\n' | grep -i -E 'openssl|ssl_module'
```

```
OpenSSL 3.0.13 30 Jan 2024 (Library: OpenSSL 3.0.13 30 Jan 2024)
built on: Mon Feb  5 15:22:12 2024 UTC
Server version: Apache/2.4.58 (Debian)
 ssl_module (shared)
 headers_module (shared)
 socache_shmcb_module (shared)
built with: OpenSSL 3.0.13
--with-http_ssl_module
```

> Si `openssl version` informa 1.1.0 o anterior, no existirán TLS 1.3, `-enable_pha` ni la sintaxis separada `SSLCipherSuite TLSv1.3`. Detenete y actualizá el laboratorio; el examen apunta a un stack capaz de TLS 1.3.

---

## Ejercicio 0 — PKI del laboratorio y resolución de nombres

El objetivo 331.2 usa certificados; no te enseña a fabricarlos (eso es 331.1). Este bloque construye la PKI mínima que consume el resto del laboratorio: una CA raíz, una **CA intermedia (emisora)** con una base de datos `openssl ca` real — necesaria más adelante para revocación y OCSP — un certificado de servidor por virtual host, un certificado de cliente y un firmante OCSP delegado.

**Paso 1.** Creá el árbol de trabajo y los alias de host.

```bash
mkdir -p ~/lab331/{ca/newcerts,srv,cli,ocsp}
cd ~/lab331
chmod 700 ca
touch ca/index.txt
echo 1000 > ca/serial
echo 1000 > ca/crlnumber

sudo tee -a /etc/hosts >/dev/null <<'EOF'
127.0.0.1  www.example.test shop.example.test ocsp.example.test crl.example.test
EOF
```

**Paso 2.** Creá la CA raíz (autofirmada, offline en la vida real).

```bash
openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -noenc \
  -keyout ca/root.key -out ca/root.crt \
  -subj "/C=AR/O=Example PKI/CN=Example Root CA" \
  -addext "basicConstraints=critical,CA:TRUE,pathlen:1" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -addext "subjectKeyIdentifier=hash"
chmod 600 ca/root.key
```

**Paso 3.** Creá la CA emisora y hacé que la raíz la firme.

```bash
openssl req -new -newkey rsa:4096 -sha256 -noenc \
  -keyout ca/issuing.key -out ca/issuing.csr \
  -subj "/C=AR/O=Example PKI/CN=Example TLS Issuing CA"

cat > ca/issuing.ext <<'EOF'
basicConstraints       = critical,CA:TRUE,pathlen:0
keyUsage               = critical,keyCertSign,cRLSign
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid:always
EOF

openssl x509 -req -in ca/issuing.csr -CA ca/root.crt -CAkey ca/root.key \
  -CAcreateserial -days 1825 -sha256 -extfile ca/issuing.ext -out ca/issuing.crt
chmod 600 ca/issuing.key

cat ca/issuing.crt ca/root.crt > ca/ca-chain.crt
openssl verify -CAfile ca/root.crt ca/issuing.crt
```

```
ca/issuing.crt: OK
```

**Paso 4.** Escribí la configuración de la CA que usa `openssl ca` (esta es la disposición de "archivos y directorios de CA/certificados/CRL" que nombra el objetivo).

```bash
cat > ca/ca.cnf <<EOF
[ ca ]
default_ca = issuing_ca

[ issuing_ca ]
dir               = $HOME/lab331/ca
database          = \$dir/index.txt
new_certs_dir     = \$dir/newcerts
serial            = \$dir/serial
crlnumber         = \$dir/crlnumber
certificate       = \$dir/issuing.crt
private_key       = \$dir/issuing.key
default_md        = sha256
default_days      = 365
default_crl_days  = 7
policy            = policy_loose
email_in_dn       = no
unique_subject    = no
copy_extensions   = none
x509_extensions   = v3_server

[ policy_loose ]
countryName            = optional
stateOrProvinceName    = optional
organizationName       = optional
organizationalUnitName = optional
commonName             = supplied
emailAddress           = optional
EOF
```

Fijate en `copy_extensions = none`. Las extensiones vienen por lo tanto de un `-extfile`, nunca del CSR — un CSR es una *solicitud no autenticada*, y a una CA que copia ciegamente sus extensiones se la puede convencer de emitir `CA:TRUE`.

**Paso 5.** Emití los dos certificados de servidor, el certificado de cliente y el firmante OCSP.

```bash
# --- reusable extension templates -------------------------------------------
cat > srv/www.ext <<'EOF'
[ v3_server ]
basicConstraints       = critical,CA:FALSE
keyUsage               = critical,digitalSignature,keyEncipherment
extendedKeyUsage       = serverAuth
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid,issuer
subjectAltName         = DNS:www.example.test, DNS:example.test
authorityInfoAccess    = OCSP;URI:http://ocsp.example.test:2560
crlDistributionPoints  = URI:http://crl.example.test/issuing.crl
EOF
sed 's/www\.example\.test/shop.example.test/; s/DNS:example.test/DNS:shop.example.test/' \
    srv/www.ext > srv/shop.ext

cat > cli/client.ext <<'EOF'
[ v3_client ]
basicConstraints       = critical,CA:FALSE
keyUsage               = critical,digitalSignature
extendedKeyUsage       = clientAuth
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid,issuer
EOF

cat > ocsp/signer.ext <<'EOF'
[ v3_ocsp ]
basicConstraints       = critical,CA:FALSE
keyUsage               = critical,digitalSignature
extendedKeyUsage       = critical,OCSPSigning
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid,issuer
noCheck                = ignored
EOF

# --- keys + CSRs + signing ---------------------------------------------------
for h in www shop; do
  openssl req -new -newkey rsa:2048 -sha256 -noenc \
    -keyout srv/$h.key -out srv/$h.csr -subj "/CN=$h.example.test"
  openssl ca -config ca/ca.cnf -batch -notext \
    -extfile srv/$h.ext -extensions v3_server \
    -in srv/$h.csr -out srv/$h.crt
done

openssl req -new -newkey rsa:2048 -sha256 -noenc \
  -keyout cli/alice.key -out cli/alice.csr -subj "/O=Example PKI/CN=alice"
openssl ca -config ca/ca.cnf -batch -notext \
  -extfile cli/client.ext -extensions v3_client -in cli/alice.csr -out cli/alice.crt

openssl req -new -newkey rsa:2048 -sha256 -noenc \
  -keyout ocsp/signer.key -out ocsp/signer.csr -subj "/CN=Example OCSP Responder"
openssl ca -config ca/ca.cnf -batch -notext \
  -extfile ocsp/signer.ext -extensions v3_ocsp -in ocsp/signer.csr -out ocsp/signer.crt
```

**Paso 6.** Construí el archivo que los servidores web van a cargar realmente, e inspeccioná lo que produjiste.

```bash
cat srv/www.crt  ca/issuing.crt > srv/www.fullchain.crt
cat srv/shop.crt ca/issuing.crt > srv/shop.fullchain.crt

openssl x509 -in srv/www.crt -noout -subject -issuer -dates -ext subjectAltName,extendedKeyUsage
cat ca/index.txt
```

```
subject=CN = www.example.test
issuer=C = AR, O = Example PKI, CN = Example TLS Issuing CA
notBefore=Aug 19 12:04:11 2026 GMT
notAfter=Aug 19 12:04:11 2027 GMT
X509v3 Subject Alternative Name:
    DNS:www.example.test, DNS:example.test
X509v3 Extended Key Usage:
    TLS Web Server Authentication

V	270819120411Z		1000	unknown	/CN=www.example.test
V	270819120411Z		1001	unknown	/CN=shop.example.test
V	270819120411Z		1002	unknown	/O=Example PKI/CN=alice
V	270819120411Z		1003	unknown	/CN=Example OCSP Responder
```

### Comprobá tu comprensión

**Q1.** En `ca/index.txt`, ¿qué significan la primera columna (`V`), el segundo campo y el cuarto campo, y cuál de ellos lee `openssl ocsp -index` para responder una consulta de estado?

**Q2.** El certificado de servidor lleva `extendedKeyUsage = serverAuth` y el de cliente `clientAuth`. ¿Qué se rompe, concretamente, si los intercambiás e intentás usar el certificado de cliente como `SSLCertificateFile` de Apache?

**Q3.** ¿Por qué el firmante OCSP lleva `noCheck`, y qué problema de recursión existiría sin él?

---

## Ejercicio 1 — Leer un handshake real con `openssl s_client`

El objetivo nombra `s_client` y `s_server` explícitamente. Tratá a `s_client` como tu microscopio de protocolo: es la única herramienta que te muestra lo que el servidor *envió*, en oposición a lo que el navegador *decidió*.

**Paso 1.** Levantá un servidor TLS descartable para tener un par antes de que exista Apache.

```bash
cd ~/lab331
openssl s_server -accept 4433 -www \
  -cert srv/www.fullchain.crt -key srv/www.key &
```

**Paso 2.** Conectate y leé la salida de arriba abajo.

```bash
openssl s_client -connect 127.0.0.1:4433 -servername www.example.test \
  -CAfile ca/root.crt -showcerts </dev/null 2>/dev/null | head -40
```

```
CONNECTED(00000003)
depth=2 C = AR, O = Example PKI, CN = Example Root CA
verify return:1
depth=1 C = AR, O = Example PKI, CN = Example TLS Issuing CA
verify return:1
depth=0 CN = www.example.test
verify return:1
---
Certificate chain
 0 s:CN = www.example.test
   i:C = AR, O = Example PKI, CN = Example TLS Issuing CA
   a:PKEY: rsaEncryption, 2048 (bit); sigalg: RSA-SHA256
   v:NotBefore: Aug 19 12:04:11 2026 GMT; NotAfter: Aug 19 12:04:11 2027 GMT
-----BEGIN CERTIFICATE-----
[...]
 1 s:C = AR, O = Example PKI, CN = Example TLS Issuing CA
   i:C = AR, O = Example PKI, CN = Example Root CA
[...]
---
SSL handshake has read 3218 bytes and written 403 bytes
Verification: OK
---
New, TLSv1.3, Cipher is TLS_AES_256_GCM_SHA384
Server public key is 2048 bit
Secure Renegotiation IS NOT supported
```

**Paso 3.** Ahora quitá el anclaje de confianza y compará el final.

```bash
openssl s_client -connect 127.0.0.1:4433 </dev/null 2>/dev/null | grep -E 'Verify|Verification'
```

```
Verification error: unable to get local issuer certificate
    Verify return code: 20 (unable to get local issuer certificate)
```

**Paso 4.** Pedí el nombre *equivocado* y observá que nada se queja.

```bash
openssl s_client -connect 127.0.0.1:4433 -servername evil.example.test \
  -CAfile ca/root.crt </dev/null 2>/dev/null | grep -E 'Verification|Verify return'
```

```
Verification: OK
    Verify return code: 0 (ok)
```

**Paso 5.** Activá la verificación de identidad explícitamente y repetí.

```bash
openssl s_client -connect 127.0.0.1:4433 -CAfile ca/root.crt \
  -verify_hostname evil.example.test -verify_return_error </dev/null 2>&1 | tail -5
```

```
Verification error: Hostname mismatch
140234...:error:0A000086:SSL routines:tls_post_process_server_certificate:certificate verify failed:
    Verify return code: 62 (Hostname mismatch)
```

**Paso 6.** Compará un handshake nuevo contra uno reanudado, y elegí la versión de protocolo a mano.

```bash
openssl s_client -connect 127.0.0.1:4433 -CAfile ca/root.crt -sess_out /tmp/s.pem </dev/null 2>/dev/null | grep -E '^(New|Reused)'
openssl s_client -connect 127.0.0.1:4433 -CAfile ca/root.crt -sess_in  /tmp/s.pem </dev/null 2>/dev/null | grep -E '^(New|Reused)'
openssl s_client -connect 127.0.0.1:4433 -tls1_2 -brief </dev/null 2>&1 | head -8
```

```
New, TLSv1.3, Cipher is TLS_AES_256_GCM_SHA384
Reused, TLSv1.3, Cipher is TLS_AES_256_GCM_SHA384

CONNECTION ESTABLISHED
Protocol version: TLSv1.2
Ciphersuite: ECDHE-RSA-AES256-GCM-SHA384
Peer certificate: CN = www.example.test
Hash used: SHA256
Signature type: RSA
Verification error: unable to get local issuer certificate
Server Temp Key: X25519, 253 bits
```

### Comprobá tu comprensión

**Q4.** En el bloque `Certificate chain`, ¿qué significan las líneas `s:` e `i:`, y por qué la CA raíz está presente acá pero ausente de un servidor público correctamente configurado?

**Q5.** Distinguí `Verify return code: 20 (unable to get local issuer certificate)` de `21 (unable to verify the first certificate)` y de `19 (self-signed certificate in certificate chain)`. ¿Cuál apunta a un intermedio faltante en el *servidor*, y cuál a un anclaje faltante en el *cliente*?

**Q6.** El paso 4 devolvió `Verification: OK` para un nombre que el certificado no contiene. ¿Qué verificó OpenSSL realmente, qué no verificó, y por qué esta es la salida peor interpretada de toda la herramienta?

**Q7.** `Secure Renegotiation IS NOT supported` apareció bajo TLS 1.3 pero diría `IS supported` bajo TLS 1.2 contra el mismo servidor. Explicá ambos casos y nombrá el problema de la era de los CVE que la RFC 5746 se escribió para corregir.

---

## Ejercicio 2 — Versiones de protocolo, protección contra downgrade y configuración de cifrados

**Paso 1.** Enumerá lo que tu biblioteca siquiera va a ofrecer.

```bash
openssl ciphers -s -v -tls1_3
openssl ciphers -s -v -tls1_2 'ECDHE+AESGCM' | head -4
```

```
TLS_AES_256_GCM_SHA384  TLSv1.3 Kx=any      Au=any  Enc=AESGCM(256) Mac=AEAD
TLS_CHACHA20_POLY1305_SHA256 TLSv1.3 Kx=any Au=any  Enc=CHACHA20/POLY1305(256) Mac=AEAD
TLS_AES_128_GCM_SHA256  TLSv1.3 Kx=any      Au=any  Enc=AESGCM(128) Mac=AEAD

ECDHE-ECDSA-AES256-GCM-SHA384 TLSv1.2 Kx=ECDH Au=ECDSA Enc=AESGCM(256) Mac=AEAD
ECDHE-RSA-AES256-GCM-SHA384   TLSv1.2 Kx=ECDH Au=RSA   Enc=AESGCM(256) Mac=AEAD
```

**Paso 2.** Reiniciá el servidor de prueba fijado solo a TLS 1.2 y sondeá el límite.

```bash
kill %1 2>/dev/null
openssl s_server -accept 4433 -www -cert srv/www.fullchain.crt -key srv/www.key \
  -no_tls1_3 &

openssl s_client -connect 127.0.0.1:4433 -tls1_3 -brief </dev/null 2>&1 | head -3
openssl s_client -connect 127.0.0.1:4433 -tls1_2 -brief </dev/null 2>&1 | head -3
```

```
CONNECTED(00000003)
40B7...:error:0A000102:SSL routines:ssl_choose_client_version:unsupported protocol:
CONNECTION ESTABLISHED
Protocol version: TLSv1.2
```

**Paso 3.** Simulá un intento de downgrade. Un atacante de red que mata los handshakes TLS 1.3 fuerza un reintento en TLS 1.2; el cliente señaliza "ya intenté algo más alto" con el fallback SCSV.

```bash
kill %1; openssl s_server -accept 4433 -www -cert srv/www.fullchain.crt -key srv/www.key &
openssl s_client -connect 127.0.0.1:4433 -tls1_2 -fallback_scsv </dev/null 2>&1 | grep -iE 'alert|error'
```

```
140551...:error:0A000410:SSL routines:ssl3_read_bytes:ssl/tls alert inappropriate fallback:
```

**Paso 4.** Forzá una selección de suite en TLS 1.2 y después probá la misma sintaxis en TLS 1.3.

```bash
openssl s_client -connect 127.0.0.1:4433 -tls1_2 -cipher 'ECDHE-RSA-CHACHA20-POLY1305' -brief </dev/null 2>&1 | grep Ciphersuite
openssl s_client -connect 127.0.0.1:4433 -tls1_3 -cipher 'ECDHE-RSA-CHACHA20-POLY1305' -brief </dev/null 2>&1 | grep Ciphersuite
openssl s_client -connect 127.0.0.1:4433 -tls1_3 -ciphersuites 'TLS_CHACHA20_POLY1305_SHA256' -brief </dev/null 2>&1 | grep Ciphersuite
```

```
Ciphersuite: ECDHE-RSA-CHACHA20-POLY1305
Ciphersuite: TLS_AES_256_GCM_SHA384
Ciphersuite: TLS_CHACHA20_POLY1305_SHA256
```

### Comprobá tu comprensión

**Q8.** En el paso 4 el comando del medio pidió una suite ChaCha20 y obtuvo `TLS_AES_256_GCM_SHA384` igual. ¿Por qué `-cipher` no tuvo efecto, y qué directivas de Apache/nginx corresponden a `-cipher` frente a `-ciphersuites`?

**Q9.** ¿Qué probó exactamente la alerta `inappropriate fallback` del paso 3, y por qué TLS_FALLBACK_SCSV es mayormente histórico en un stack TLS 1.3?

**Q10.** La RFC 8996 deprecia TLS 1.0 y 1.1. Escribí la directiva de Apache que permite solo TLS 1.2 y 1.3, y explicá por qué `SSLProtocol -all +TLSv1.2 +TLSv1.3` es más seguro de mantener que `SSLProtocol All -SSLv3 -TLSv1 -TLSv1.1`.

---

## Ejercicio 3 — Man-in-the-middle: qué defienden realmente los certificados

**Paso 1.** Construí la PKI del atacante y un certificado falsificado para un nombre que no te pertenece.

```bash
mkdir -p ~/lab331/evil && cd ~/lab331/evil
openssl req -x509 -newkey rsa:2048 -sha256 -days 365 -noenc \
  -keyout evilca.key -out evilca.crt -subj "/O=Evil Corp/CN=Evil Root CA" \
  -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign"

openssl req -new -newkey rsa:2048 -sha256 -noenc \
  -keyout fake.key -out fake.csr -subj "/CN=www.example.test"
openssl x509 -req -in fake.csr -CA evilca.crt -CAkey evilca.key -CAcreateserial \
  -days 365 -sha256 -out fake.crt \
  -extfile <(printf 'subjectAltName=DNS:www.example.test\nextendedKeyUsage=serverAuth\n')
```

**Paso 2.** Ejecutá el impostor y conectate con el anclaje de confianza *legítimo*.

```bash
kill %1 2>/dev/null
openssl s_server -accept 4433 -www -cert fake.crt -key fake.key &
openssl s_client -connect 127.0.0.1:4433 -CAfile ~/lab331/ca/root.crt \
  -verify_hostname www.example.test </dev/null 2>/dev/null | grep -E 'Verify return|subject='
```

```
    Verify return code: 20 (unable to get local issuer certificate)
```

**Paso 3.** Ahora hacé lo que hace el malware, un proxy corporativo o un agente de gestión de dispositivos comprometido — instalar la CA del atacante como confiable — y repetí.

```bash
# Debian/Ubuntu
sudo cp evilca.crt /usr/local/share/ca-certificates/evilca.crt
sudo update-ca-certificates
# RHEL/Rocky:  sudo cp evilca.crt /etc/pki/ca-trust/source/anchors/ && sudo update-ca-trust extract

openssl s_client -connect 127.0.0.1:4433 -verify_hostname www.example.test \
  </dev/null 2>/dev/null | grep -E 'Verify return'
```

```
    Verify return code: 0 (ok)
```

**Paso 4.** Limpiá inmediatamente — no dejes un anclaje malicioso instalado.

```bash
sudo rm -f /usr/local/share/ca-certificates/evilca.crt && sudo update-ca-certificates --fresh
# RHEL: sudo rm -f /etc/pki/ca-trust/source/anchors/evilca.crt && sudo update-ca-trust extract
openssl s_client -connect 127.0.0.1:4433 </dev/null 2>/dev/null | grep 'Verify return'
kill %1
```

```
    Verify return code: 20 (unable to get local issuer certificate)
```

### Comprobá tu comprensión

**Q11.** Un certificado de par TLS se comprueba a lo largo de dos ejes independientes. Nombrá ambos, y decí cuál falló el paso 2 y cuál satisfizo el paso 3.

**Q12.** Después del paso 3 el MITM es criptográficamente invisible para `s_client` y para un navegador. Nombrá dos mecanismos que todavía podrían exponerlo, y aclará si HSTS es uno de ellos.

**Q13.** ¿Dónde busca OpenSSL los anclajes cuando falta `-CAfile`? Mostrá los dos comandos que revelan la ruta compilada y las variables de entorno que la sobrescriben.

---

## Ejercicio 4 — Apache HTTPD con `mod_ssl`: un vhost HTTPS correcto

**Paso 1.** Instalá los certificados donde el servidor pueda leerlos, y habilitá los módulos.

```bash
sudo install -o root -g root -m 644 ~/lab331/srv/www.fullchain.crt  /etc/ssl/certs/
sudo install -o root -g root -m 644 ~/lab331/srv/shop.fullchain.crt /etc/ssl/certs/
sudo install -o root -g root -m 640 ~/lab331/srv/www.key            /etc/ssl/private/
sudo install -o root -g root -m 640 ~/lab331/srv/shop.key           /etc/ssl/private/
sudo install -o root -g root -m 644 ~/lab331/ca/ca-chain.crt        /etc/ssl/certs/

sudo a2enmod ssl headers socache_shmcb            # Debian family
# RHEL family:  sudo dnf install -y mod_ssl
```

**Paso 2.** Escribí el vhost. En Debian esto es `/etc/apache2/sites-available/www-tls.conf`; en RHEL, `/etc/httpd/conf.d/www-tls.conf`.

```apache
Listen 443 https

# Global, NOT per-vhost: the OCSP staple cache (used in Exercise 8)
SSLStaplingCache "shmcb:/run/httpd-ocsp(128000)"
SSLSessionCache  "shmcb:/run/httpd-sslcache(512000)"
SSLSessionTickets off

<VirtualHost *:443>
    ServerName  www.example.test
    ServerAlias example.test
    DocumentRoot /var/www/www

    SSLEngine on
    # Since httpd 2.4.8 this one file holds leaf + intermediates, in that order.
    SSLCertificateFile    /etc/ssl/certs/www.fullchain.crt
    SSLCertificateKeyFile /etc/ssl/private/www.key

    SSLProtocol            -all +TLSv1.2 +TLSv1.3
    SSLCipherSuite         TLSv1.2 ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305
    SSLCipherSuite         TLSv1.3 TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:TLS_AES_128_GCM_SHA256
    SSLHonorCipherOrder    off
    SSLOpenSSLConfCmd      Groups X25519:secp384r1:prime256v1

    ErrorLog  ${APACHE_LOG_DIR}/www-tls_error.log
    CustomLog ${APACHE_LOG_DIR}/www-tls_access.log combined
</VirtualHost>

<VirtualHost *:80>
    ServerName www.example.test
    Redirect permanent / https://www.example.test/
</VirtualHost>
```

**Paso 3.** Publicá contenido, validá la sintaxis, recargá.

```bash
sudo mkdir -p /var/www/www && echo '<h1>www</h1>' | sudo tee /var/www/www/index.html
sudo a2ensite www-tls && sudo apachectl configtest && sudo systemctl reload apache2
```

```
Syntax OK
```

**Paso 4.** Verificá desde el lado del cliente, no desde el archivo de configuración.

```bash
openssl s_client -connect www.example.test:443 -servername www.example.test \
  -CAfile ~/lab331/ca/root.crt -verify_hostname www.example.test \
  -verify_return_error -brief </dev/null 2>&1
```

```
CONNECTION ESTABLISHED
Protocol version: TLSv1.3
Ciphersuite: TLS_AES_256_GCM_SHA384
Peer certificate: CN = www.example.test
Hash used: SHA256
Signature type: RSA-PSS
Verification: OK
Server Temp Key: X25519, 253 bits
```

**Paso 5.** Rompelo deliberadamente: serví la hoja sin el intermedio.

```bash
sudo sed -i 's#www.fullchain.crt#www.crt#' /etc/apache2/sites-available/www-tls.conf
sudo install -m 644 ~/lab331/srv/www.crt /etc/ssl/certs/
sudo systemctl reload apache2
openssl s_client -connect www.example.test:443 -servername www.example.test \
  -CAfile ~/lab331/ca/root.crt </dev/null 2>/dev/null | grep -E '^ [01] s:|Verify return'
```

```
 0 s:CN = www.example.test
    Verify return code: 20 (unable to get local issuer certificate)
```

Restaurá la fullchain antes de continuar:

```bash
sudo sed -i 's#/etc/ssl/certs/www.crt#/etc/ssl/certs/www.fullchain.crt#' \
     /etc/apache2/sites-available/www-tls.conf
sudo systemctl reload apache2
```

### Comprobá tu comprensión

**Q14.** En el paso 5 el certificado en sí era perfectamente válido y `openssl verify -CAfile ca-chain.crt srv/www.crt` devuelve OK. ¿Por qué falló igual la *conexión*, y por qué algunos clientes (notablemente Firefox, o una segunda visita a otro sitio de la misma CA) a veces tienen éxito de todos modos?

**Q15.** `SSLCertificateChainFile` todavía se parsea en 2.4 pero está depreciada. ¿Qué la reemplazó, y en qué orden deben aparecer los certificados en el archivo de reemplazo?

**Q16.** Pegás la clave privada equivocada junto al certificado. ¿Qué informa `apachectl configtest`, y qué dos comandos prueban el emparejamiento clave/certificado *sin* reiniciar nada — para una clave RSA y, de forma agnóstica al algoritmo, para cualquier clave?

---

## Ejercicio 5 — SNI: muchos certificados, un socket

**Paso 1.** Agregá el segundo vhost en la misma IP y puerto.

```apache
<VirtualHost *:443>
    ServerName shop.example.test
    DocumentRoot /var/www/shop
    SSLEngine on
    SSLCertificateFile    /etc/ssl/certs/shop.fullchain.crt
    SSLCertificateKeyFile /etc/ssl/private/shop.key
</VirtualHost>
```

```bash
sudo mkdir -p /var/www/shop && echo '<h1>shop</h1>' | sudo tee /var/www/shop/index.html
sudo a2ensite shop-tls; sudo apachectl configtest && sudo systemctl reload apache2
```

**Paso 2.** Mostrá que el certificado sigue al valor SNI, no a la IP.

```bash
for n in www.example.test shop.example.test; do
  echo "== SNI: $n"
  openssl s_client -connect 127.0.0.1:443 -servername "$n" \
    -CAfile ~/lab331/ca/root.crt </dev/null 2>/dev/null \
    | openssl x509 -noout -subject -ext subjectAltName
done
```

```
== SNI: www.example.test
subject=CN = www.example.test
X509v3 Subject Alternative Name:
    DNS:www.example.test, DNS:example.test
== SNI: shop.example.test
subject=CN = shop.example.test
X509v3 Subject Alternative Name:
    DNS:shop.example.test
```

**Paso 3.** Conectate **sin** SNI en absoluto, como haría un cliente antiguo.

```bash
openssl s_client -connect 127.0.0.1:443 -noservername </dev/null 2>/dev/null \
  | openssl x509 -noout -subject
```

```
subject=CN = www.example.test
```

**Paso 4.** Convertí la ausencia de SNI en un error en lugar de una respuesta silenciosamente equivocada.

```bash
sudo sed -i '/^Listen 443 https/a SSLStrictSNIVHostCheck on' \
     /etc/apache2/sites-available/www-tls.conf
sudo systemctl reload apache2
openssl s_client -connect 127.0.0.1:443 -noservername </dev/null 2>&1 | grep -iE 'alert|error'
```

```
40B7...:error:0A000410:SSL routines:ssl3_read_bytes:ssl/tls alert handshake failure:
```

**Paso 5.** Observá el SNI viajar en texto claro.

```bash
sudo timeout 5 tcpdump -i lo -n -A 'tcp port 443' 2>/dev/null | grep -a 'example.test' &
openssl s_client -connect 127.0.0.1:443 -servername shop.example.test </dev/null >/dev/null 2>&1
```

```
....shop.example.test.....
```

### Comprobá tu comprensión

**Q17.** ¿Qué vhost respondió el handshake sin SNI del paso 3, y qué regla aplicó Apache para elegirlo?

**Q18.** `SSLStrictSNIVHostCheck on` convirtió un certificado equivocado en una falla de handshake. ¿Bajo qué circunstancia esa es la configuración *incorrecta* para un sitio en producción, y contra qué no protege?

**Q19.** El paso 5 muestra el nombre de host solicitado en el cable antes de que exista cifrado alguno. Nombrá la extensión diseñada para cerrar esa filtración, y decí qué requiere del DNS.

**Q20.** Antes de SNI (RFC 6066), ¿cómo alojaban los operadores múltiples sitios TLS, y qué dos características de certificado son los equivalentes modernos de esa solución alternativa?

---

## Ejercicio 6 — HSTS y el ataque de SSL stripping

**Paso 1.** Comprobá que la superficie de ataque existe. Obtené el punto de entrada por HTTP plano y mirá la redirección de la que depende la primerísima petición de un usuario.

```bash
curl -sSI http://www.example.test/ | head -3
```

```
HTTP/1.1 301 Moved Permanently
Date: Wed, 19 Aug 2026 12:41:02 GMT
Location: https://www.example.test/
```

Un MITM que reescribe esta respuesta — o que simplemente hace de proxy del sitio sobre HTTP plano — nunca toca un certificado. Nada de lo que configuraste hasta ahora lo detiene.

**Paso 2.** Agregá la política HSTS al vhost **HTTPS** solamente.

```apache
    Header always set Strict-Transport-Security "max-age=63072000; includeSubDomains"
```

```bash
sudo apachectl configtest && sudo systemctl reload apache2
curl -sSI --cacert ~/lab331/ca/root.crt https://www.example.test/ | grep -i strict
```

```
strict-transport-security: max-age=63072000; includeSubDomains
```

**Paso 3.** Confirmá que la cabecera también se emite en respuestas de error — esto es lo que te compra `always`.

```bash
curl -sSI --cacert ~/lab331/ca/root.crt https://www.example.test/nope | head -1
curl -sSI --cacert ~/lab331/ca/root.crt https://www.example.test/nope | grep -i strict
```

```
HTTP/1.1 404 Not Found
strict-transport-security: max-age=63072000; includeSubDomains
```

**Paso 4.** Verificá que la cabecera en el puerto 80 es inerte. Agregá temporalmente la misma línea `Header` al vhost `*:80`, recargá, y obtené:

```bash
curl -sSI http://www.example.test/ | grep -i strict
```

```
strict-transport-security: max-age=63072000; includeSubDomains
```

El servidor la envía; un navegador conforme la **descarta**. Quitá la línea de nuevo.

**Paso 5.** Inspeccioná cómo se ve una política apta para preload, sin enviar nada:

```apache
    Header always set Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
```

### Comprobá tu comprensión

**Q21.** ¿Por qué `Header always set` en vez de `Header set`? Dá una respuesta concreta donde la diferencia sea visible.

**Q22.** Un navegador que nunca visitó el sitio sigue siendo vulnerable al stripping incluso con HSTS desplegado. Nombrá esta brecha y el mecanismo que la cierra.

**Q23.** Enunciá los tres requisitos que debe cumplir una política para calificar para la lista de preload, y el riesgo operativo que hace que el preload sea efectivamente irreversible en el corto plazo.

**Q24.** Tu sitio es `www.example.test` e `includeSubDomains` está puesto en él. ¿La política cubre `example.test` e `intranet.example.test`? Explicá.

---

## Ejercicio 7 — Autenticación con certificado de cliente con `mod_ssl`

**Paso 1.** Empaquetá las credenciales de Alice como las quiere un navegador o un almacén de claves del sistema operativo.

```bash
cd ~/lab331
openssl pkcs12 -export -inkey cli/alice.key -in cli/alice.crt \
  -certfile ca/ca-chain.crt -name "alice@example.test" -out cli/alice.p12
openssl pkcs12 -in cli/alice.p12 -info -nokeys -passin pass: 2>&1 | grep -E 'MAC|PKCS7|subject'
```

```
MAC: sha256, Iteration 2048
MAC length: 32, salt length: 8
PKCS7 Encrypted data: PBES2, PBKDF2, AES-256-CBC, Iteration 2048, PRF hmacWithSHA256
subject=/O=Example PKI/CN=alice
subject=/C=AR/O=Example PKI/CN=Example TLS Issuing CA
subject=/C=AR/O=Example PKI/CN=Example Root CA
```

**Paso 2.** Exigí certificados en un subárbol del vhost `www`.

```apache
    SSLCACertificateFile  /etc/ssl/certs/ca-chain.crt
    SSLVerifyDepth        2
    SSLOptions            +StdEnvVars +ExportCertData

    <Location /secure>
        SSLVerifyClient require
        Require expr "%{SSL_CLIENT_S_DN_CN} in { 'alice', 'bob' }"
    </Location>
```

```bash
sudo mkdir -p /var/www/www/secure
printf '<pre>\nDN: %s\n</pre>\n' '%{SSL_CLIENT_S_DN}e' | sudo tee /var/www/www/secure/index.html
sudo apachectl configtest && sudo systemctl reload apache2
```

**Paso 3.** Probá sin certificado, después con uno.

```bash
curl -sS --cacert ca/root.crt https://www.example.test/secure/ ; echo
curl -sS --cacert ca/root.crt --cert cli/alice.crt --key cli/alice.key \
     https://www.example.test/secure/ ; echo
```

```
curl: (56) OpenSSL SSL_read: error:0A00045C:SSL routines:...:tlsv13 alert certificate required
<pre>
DN: /O=Example PKI/CN=alice
</pre>
```

**Paso 4.** Reproducí el mismo intercambio con `s_client`, que muestra la solicitud de certificado en sí.

```bash
openssl s_client -connect www.example.test:443 -servername www.example.test \
  -CAfile ca/root.crt -cert cli/alice.crt -key cli/alice.key -enable_pha \
  -tls1_3 </dev/null 2>&1 | grep -iE 'Acceptable client|CN =|Verify return'
```

```
Acceptable client certificate CA names
C = AR, O = Example PKI, CN = Example TLS Issuing CA
C = AR, O = Example PKI, CN = Example Root CA
    Verify return code: 0 (ok)
```

**Paso 5.** Quitá `-enable_pha` bajo TLS 1.3 y leé la falla:

```bash
openssl s_client -connect www.example.test:443 -servername www.example.test \
  -CAfile ca/root.crt -cert cli/alice.crt -key cli/alice.key -tls1_3 \
  </dev/null 2>&1 | grep -iE 'alert|403|Forbidden'
sudo tail -2 /var/log/apache2/www-tls_error.log
```

```
[ssl:error] [pid 8123] [client 127.0.0.1:52344] AH10129: verify client post handshake
[ssl:error] [pid 8123] [client 127.0.0.1:52344] AH10130: Client did not enable post-handshake authentication
```

**Paso 6.** Restringí la lista de CA anunciada en el `CertificateRequest` sin cambiar en quién se confía:

```apache
    SSLCADNRequestFile /etc/ssl/certs/issuing-only.crt
```

```bash
sudo install -m 644 ~/lab331/ca/issuing.crt /etc/ssl/certs/issuing-only.crt
sudo systemctl reload apache2
openssl s_client -connect www.example.test:443 -servername www.example.test \
  -CAfile ~/lab331/ca/root.crt </dev/null 2>&1 | grep -A3 'Acceptable client'
```

```
Acceptable client certificate CA names
C = AR, O = Example PKI, CN = Example TLS Issuing CA
```

### Comprobá tu comprensión

**Q25.** Distinguí `SSLCACertificateFile` de `SSLCADNRequestFile`. Si configurás solo la segunda, ¿qué le pasa a la verificación?

**Q26.** Explicá con precisión por qué el paso 5 falló bajo TLS 1.3 mientras que la configuración idéntica funciona bajo TLS 1.2, y nombrá el mecanismo de TLS 1.2 que Apache usaba ahí y que ya no existe.

**Q27.** `SSLVerifyClient optional` y el `optional_no_ca` de nginx suenan parecidos. Describí la diferencia de seguridad y el único caso de uso legítimo de `optional_no_ca`.

**Q28.** `SSLOptions +StdEnvVars` tiene un costo medible. ¿Cuál es, y dónde acotarías la directiva para evitar pagarlo en todo el sitio?

**Q29.** Con `SSLVerifyDepth 2` y la cadena de este laboratorio, ¿un certificado emitido directamente por la CA raíz sigue autenticándose? ¿Y uno emitido por una sub-CA de segundo nivel bajo la CA emisora?

---

## Ejercicio 8 — OCSP stapling

**Paso 1.** Ejecutá un responder respaldado por la base de datos de la CA que construiste en el Ejercicio 0.

```bash
cd ~/lab331
openssl ocsp -port 2560 -index ca/index.txt -CA ca/ca-chain.crt \
  -rkey ocsp/signer.key -rsigner ocsp/signer.crt -nrequest 1000 -text &
```

**Paso 2.** Consultalo directamente, como haría un cliente si no hubiera stapling.

```bash
openssl ocsp -CAfile ca/ca-chain.crt -issuer ca/issuing.crt -cert srv/www.crt \
  -url http://ocsp.example.test:2560 -resp_text -no_nonce 2>/dev/null | \
  grep -E 'Response Status|Cert Status|This Update|Next Update|Response verify'
```

```
    OCSP Response Status: successful (0x0)
    Cert Status: good
    This Update: Aug 19 13:02:44 2026 GMT
    Next Update: Aug 19 13:07:44 2026 GMT
Response verify OK
```

**Paso 3.** Fijate de dónde salió la URL — te la dijo el certificado.

```bash
openssl x509 -in srv/www.crt -noout -ext authorityInfoAccess
```

```
X509v3 Authority Information Access:
    OCSP - URI:http://ocsp.example.test:2560
```

**Paso 4.** Activá el stapling en Apache. `SSLStaplingCache` ya está en el ámbito global desde el Ejercicio 4 — la parte por vhost es pequeña:

```apache
    SSLUseStapling                  on
    SSLStaplingResponderTimeout     5
    SSLStaplingReturnResponderErrors off
    SSLStaplingStandardCacheTimeout 3600
```

```bash
sudo apachectl configtest && sudo systemctl reload apache2
openssl s_client -connect www.example.test:443 -servername www.example.test \
  -CAfile ca/root.crt -status </dev/null 2>/dev/null | \
  grep -E 'OCSP response|Cert Status|Next Update'
```

```
OCSP response:
    Cert Status: good
    Next Update: Aug 19 14:02:44 2026 GMT
```

**Paso 5.** Revocá el certificado y observá cómo cambia de significado el staple.

```bash
openssl ca -config ca/ca.cnf -revoke srv/www.crt -crl_reason keyCompromise
grep '^R' ca/index.txt
kill %1; openssl ocsp -port 2560 -index ca/index.txt -CA ca/ca-chain.crt \
  -rkey ocsp/signer.key -rsigner ocsp/signer.crt -nrequest 1000 &
sudo systemctl restart apache2   # discards the cached "good" staple

openssl s_client -connect www.example.test:443 -servername www.example.test \
  -CAfile ca/root.crt -status </dev/null 2>/dev/null | \
  grep -E 'Cert Status|Revocation'
```

```
    Cert Status: revoked
    Revocation Time: Aug 19 13:15:07 2026 GMT
    Revocation Reason: keyCompromise (0x1)
```

**Paso 6.** Generá la CRL que lleva el mismo hecho, y comprobala offline.

```bash
openssl ca -config ca/ca.cnf -gencrl -out ca/issuing.crl
openssl crl -in ca/issuing.crl -noout -text | head -12
cat ca/ca-chain.crt ca/issuing.crl > /tmp/verify-bundle.pem
openssl verify -crl_check -CAfile ca/root.crt -untrusted ca/issuing.crt \
  -CRLfile ca/issuing.crl srv/www.crt
```

```
Certificate Revocation List (CRL):
        Version 2 (0x1)
        Signature Algorithm: sha256WithRSAEncryption
        Issuer: C = AR, O = Example PKI, CN = Example TLS Issuing CA
        Last Update: Aug 19 13:20:11 2026 GMT
        Next Update: Aug 26 13:20:11 2026 GMT
        CRL extensions:
            X509v3 CRL Number: 1000
Revoked Certificates:
    Serial Number: 1000
        Revocation Date: Aug 19 13:15:07 2026 GMT

CN = www.example.test
error 23 at 0 depth lookup: certificate revoked
error srv/www.crt: verification failed
```

**Paso 7.** Restaurá un estado funcional: reinstaurá el certificado reemitiéndolo, o simplemente marcá el laboratorio como comprendido y revertí `index.txt` desde `ca/index.txt.old`.

**Paso 8.** (Opcional, solo lectura) Inspeccioná la extensión OCSP Must-Staple en un certificado que la tenga:

```bash
openssl x509 -in srv/www.crt -noout -ext tlsfeature
```

```
No extensions in certificate
```

Para emitir uno, agregá `tlsfeature = status_request` al archivo de extensiones — pero solo si estás seguro de que el servidor siempre va a hacer stapling.

### Comprobá tu comprensión

**Q30.** En el paso 2 apareció `Response verify OK`. ¿Qué clave firmó esa respuesta, y qué dos propiedades del certificado firmante lo autorizaron a responder *en nombre de* la CA emisora?

**Q31.** Enunciá tres beneficios que aporta el stapling frente a dejar que el cliente consulte OCSP por su cuenta, y el único problema que **no** resuelve sin Must-Staple.

**Q32.** `SSLStaplingCache` debe vivir en la configuración global del servidor. ¿Cuál es el síntoma observable si la ponés dentro de un `<VirtualHost>`, o si la omitís teniendo `SSLUseStapling on`?

**Q33.** `SSLStaplingReturnResponderErrors` tiene valor por defecto `on`. Explicá qué se les envía a los clientes en ese modo cuando el responder es inalcanzable, y por qué `off` es el valor más seguro en producción.

**Q34.** ¿Por qué el paso 5 necesitó `systemctl restart` en lugar de `reload` para mostrar el nuevo estado, y cuál es la demora correspondiente en el mundo real tras una revocación de emergencia?

---

## Ejercicio 9 — Las mismas seis cosas en nginx

**Paso 1.** Pará Apache para liberar el puerto 443, y armá un vhost que ejercite HTTPS, SNI, HSTS, autenticación de cliente y stapling en un solo archivo.

```bash
sudo systemctl stop apache2
sudo mkdir -p /etc/nginx/ssl && cd ~/lab331
sudo install -m 644 srv/www.fullchain.crt srv/shop.fullchain.crt ca/ca-chain.crt /etc/nginx/ssl/
sudo install -m 640 -g www-data srv/www.key srv/shop.key /etc/nginx/ssl/
```

```nginx
# /etc/nginx/conf.d/tls.conf
server {
    listen 443 ssl default_server;
    http2 on;                                   # nginx >= 1.25.1; before: listen 443 ssl http2;
    server_name www.example.test example.test;
    root /var/www/www;

    ssl_certificate     /etc/nginx/ssl/www.fullchain.crt;   # leaf FIRST, then intermediates
    ssl_certificate_key /etc/nginx/ssl/www.key;

    ssl_protocols             TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_ciphers               ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_conf_command          Ciphersuites TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256;
    ssl_session_cache         shared:SSL:10m;
    ssl_session_timeout       1d;
    ssl_session_tickets       off;

    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;

    ssl_stapling            on;
    ssl_stapling_verify     on;
    ssl_trusted_certificate /etc/nginx/ssl/ca-chain.crt;
    resolver                127.0.0.53 valid=300s ipv6=off;

    ssl_client_certificate /etc/nginx/ssl/ca-chain.crt;
    ssl_verify_client      optional;             # requested for every connection
    ssl_verify_depth       2;

    location /secure/ {
        if ($ssl_client_verify != SUCCESS) { return 403; }
        add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;
        default_type text/plain;
        return 200 "DN=$ssl_client_s_dn\nverify=$ssl_client_verify\nsni=$ssl_server_name\n";
    }
}

server {
    listen 443 ssl;
    server_name shop.example.test;
    root /var/www/shop;
    ssl_certificate     /etc/nginx/ssl/shop.fullchain.crt;
    ssl_certificate_key /etc/nginx/ssl/shop.key;
}

server { listen 80 default_server; return 301 https://$host$request_uri; }
```

**Paso 2.** Validá y arrancá.

```bash
sudo nginx -t && sudo systemctl restart nginx
```

```
nginx: the configuration file /etc/nginx/nginx.conf syntax is ok
nginx: configuration file /etc/nginx/nginx.conf test is successful
```

**Paso 3.** Comprobá SNI, HSTS y autenticación de cliente en una sola pasada.

```bash
openssl s_client -connect 127.0.0.1:443 -servername shop.example.test \
  -CAfile ca/root.crt </dev/null 2>/dev/null | openssl x509 -noout -subject
curl -sSI --cacert ca/root.crt https://www.example.test/ | grep -i strict
curl -sS  --cacert ca/root.crt https://www.example.test/secure/ ; echo
curl -sS  --cacert ca/root.crt --cert cli/alice.crt --key cli/alice.key \
     https://www.example.test/secure/
```

```
subject=CN = shop.example.test
strict-transport-security: max-age=63072000; includeSubDomains
<html>...403 Forbidden...</html>
DN=O=Example PKI,CN=alice
verify=SUCCESS
sni=www.example.test
```

**Paso 4.** Observá el calentamiento del stapling.

```bash
openssl s_client -connect www.example.test:443 -servername www.example.test \
  -status -CAfile ca/root.crt </dev/null 2>/dev/null | grep -m1 'OCSP response'
sleep 3
openssl s_client -connect www.example.test:443 -servername www.example.test \
  -status -CAfile ca/root.crt </dev/null 2>/dev/null | grep -E 'OCSP response|Cert Status'
```

```
OCSP response: no response sent by server

OCSP response:
    Cert Status: good
```

**Paso 5.** Eliminá la dependencia de red por completo con una respuesta pre-obtenida — la respuesta correcta para despliegues air-gapped o de alta disponibilidad.

```bash
openssl ocsp -CAfile ca/ca-chain.crt -issuer ca/issuing.crt -cert srv/www.crt \
  -url http://ocsp.example.test:2560 -no_nonce -respout /tmp/www.ocsp.der
sudo install -m 644 /tmp/www.ocsp.der /etc/nginx/ssl/
# add to the server block:  ssl_stapling_file /etc/nginx/ssl/www.ocsp.der;
sudo nginx -t && sudo systemctl reload nginx
```

### Comprobá tu comprensión

**Q35.** nginx tiene una única directiva `ssl_certificate` donde Apache históricamente tenía dos. ¿Qué debe contener el archivo, en qué orden, y cuál es el síntoma de invertir el orden?

**Q36.** ¿Por qué el primer sondeo `-status` del paso 4 devolvió `no response sent by server`, y por qué el mismo sondeo contra Apache (Ejercicio 8) suele tener éxito al primer intento?

**Q37.** `ssl_stapling on` sin `resolver` produce una advertencia y ningún staple. Explicá la dependencia, y decí por qué `ssl_stapling_file` la elimina.

**Q38.** La línea `add_header` se repite dentro de `location /secure/`. ¿Por qué esa repetición es obligatoria en lugar de redundante?

**Q39.** Apache puede exigir un certificado de cliente por `<Location>`; el `ssl_verify_client` de nginx es por `server`, de ahí el idioma `if ($ssl_client_verify != SUCCESS)`. ¿Cuál es el costo de privacidad/UX del enfoque de nginx, y qué contiene `$ssl_client_verify` cuando se envió un certificado pero fue rechazado?

**Q40.** `ssl_ciphers` no tiene efecto sobre TLS 1.3 en nginx. ¿Qué directiva lo cubre, y desde qué versión de nginx?

---

## Ejercicio 10 — Ejercicios de diagnóstico

Cada ejercicio es un síntoma. Ejecutá el comando, leé la evidencia, nombrá la causa, aplicá el arreglo. Hacelos en orden; cada uno deja el sistema limpio para el siguiente.

**Ejercicio A — "Funciona con curl en el servidor pero el navegador dice no confiable".**

```bash
openssl s_client -connect www.example.test:443 -servername www.example.test \
  -showcerts </dev/null 2>/dev/null | grep -cE '^-----BEGIN CERTIFICATE'
```

```
1
```

**Ejercicio B — "El certificado y la clave no coinciden" después de una renovación.**

```bash
# RSA-specific, the classic:
openssl x509 -noout -modulus -in srv/www.crt | openssl sha256
openssl rsa  -noout -modulus -in srv/www.key | openssl sha256
# Algorithm-agnostic — works for EC, Ed25519, RSA alike:
openssl x509 -in srv/www.crt -noout -pubkey | openssl sha256
openssl pkey -in srv/www.key -pubout      | openssl sha256
```

```
SHA2-256(stdin)= 4f2b...c19a
SHA2-256(stdin)= 4f2b...c19a
SHA2-256(stdin)= 9d70...ee31
SHA2-256(stdin)= 9d70...ee31
```

**Ejercicio C — "El sitio se cayó a las 02:00 y nadie desplegó nada".**

```bash
openssl x509 -in srv/www.crt -noout -checkend 0        && echo "valid now"
openssl x509 -in srv/www.crt -noout -checkend 2592000  || echo "expires within 30 days"
echo | openssl s_client -connect www.example.test:443 -servername www.example.test 2>/dev/null \
  | openssl x509 -noout -dates
```

**Ejercicio D — "Solo fallan los clientes móviles".**

```bash
openssl s_client -connect www.example.test:443 -servername www.example.test \
  -tls1_2 -brief </dev/null 2>&1 | head -3
sudo grep -R 'SSLProtocol\|ssl_protocols' /etc/apache2 /etc/nginx 2>/dev/null
```

**Ejercicio E — "El stapling dejó de funcionar después de que cambiamos de red".**

```bash
openssl s_client -connect www.example.test:443 -servername www.example.test \
  -status </dev/null 2>/dev/null | grep -m1 'OCSP response'
openssl x509 -in srv/www.crt -noout -ext authorityInfoAccess
curl -sS -o /dev/null -w '%{http_code}\n' http://ocsp.example.test:2560/
sudo journalctl -u apache2 --since '10 min ago' | grep -i stapl
```

**Ejercicio F — "Un vhost sirve el certificado equivocado a algunos clientes".**

```bash
openssl s_client -connect 127.0.0.1:443 -noservername </dev/null 2>/dev/null \
  | openssl x509 -noout -subject
sudo apachectl -S 2>&1 | sed -n '/VirtualHost configuration/,/^$/p'
```

**Ejercicio G — "Los certificados de cliente son rechazados sin ninguna línea de log útil".**

```bash
openssl verify -CAfile ca/root.crt -untrusted ca/issuing.crt cli/alice.crt
openssl x509 -in cli/alice.crt -noout -ext extendedKeyUsage,keyUsage
openssl s_client -connect www.example.test:443 -servername www.example.test \
  -CAfile ca/root.crt </dev/null 2>/dev/null | grep -A5 'Acceptable client'
```

### Comprobá tu comprensión

**Q41.** El ejercicio A devolvió `1`. Nombrá el defecto, el arreglo, y explicá por qué `curl` en el propio servidor no lo reprodujo.

**Q42.** En el ejercicio B, ¿por qué la comparación `-pubkey`/`-pubout` es estrictamente mejor práctica que la de `-modulus`, y qué implica una *discrepancia* en la comprobación del módulo pero una *coincidencia* en la de pubkey (pregunta capciosa — respondé con cuidado)?

**Q43.** Para el ejercicio E, enumerá las tres causas distintas de `no response sent by server` y dá el único comando que discrimina entre ellas.

**Q44.** En el ejercicio G, `openssl verify` tiene éxito y el EKU es `clientAuth`, pero el handshake falla igual. Dá dos causas restantes que ninguno de los comandos del ejercicio revelaría.

---

## Fuentes de referencia

- LPI — Objetivos del examen 303 (v3.0.0): <https://www.lpi.org/our-certifications/exam-303-objectives/>
- Apache HTTP Server 2.4 — referencia de directivas de `mod_ssl`: <https://httpd.apache.org/docs/2.4/mod/mod_ssl.html>
- Apache HTTP Server 2.4 — SSL/TLS How-To y FAQ: <https://httpd.apache.org/docs/2.4/ssl/>
- nginx — `ngx_http_ssl_module`: <https://nginx.org/en/docs/http/ngx_http_ssl_module.html>
- nginx — Configuración de servidores HTTPS: <https://nginx.org/en/docs/http/configuring_https_servers.html>
- Manuales de OpenSSL 3.x — `s_client`, `s_server`, `ca`, `ocsp`, `verify`, `x509`, `pkcs12`, `req`, `crl`: <https://docs.openssl.org/master/man1/>
- Códigos de error de verificación de OpenSSL: <https://docs.openssl.org/master/man1/openssl-verification-options/>
- RFC 8446 — The Transport Layer Security (TLS) Protocol Version 1.3: <https://www.rfc-editor.org/rfc/rfc8446>
- RFC 8996 — Deprecating TLS 1.0 and TLS 1.1: <https://www.rfc-editor.org/rfc/rfc8996>
- RFC 6066 — TLS Extensions: Extension Definitions (SNI, `status_request`): <https://www.rfc-editor.org/rfc/rfc6066>
- RFC 6797 — HTTP Strict Transport Security (HSTS): <https://www.rfc-editor.org/rfc/rfc6797>
- RFC 6960 — X.509 Internet PKI Online Certificate Status Protocol: <https://www.rfc-editor.org/rfc/rfc6960>
- RFC 7633 — X.509v3 TLS Feature Extension (Must-Staple): <https://www.rfc-editor.org/rfc/rfc7633>
- RFC 5280 — X.509 Certificate and CRL Profile: <https://www.rfc-editor.org/rfc/rfc5280>
- RFC 6125 — Representation and Verification of Application Service Identity: <https://www.rfc-editor.org/rfc/rfc6125>
- RFC 5746 — TLS Renegotiation Indication Extension: <https://www.rfc-editor.org/rfc/rfc5746>
- RFC 7507 — TLS Fallback Signaling Cipher Suite Value: <https://www.rfc-editor.org/rfc/rfc7507>
- RFC 9345 / draft ECH — TLS Encrypted Client Hello: <https://datatracker.ietf.org/doc/draft-ietf-tls-esni/>
- Mozilla — Guía de configuración TLS del lado del servidor: <https://wiki.mozilla.org/Security/Server_Side_TLS>
- Requisitos de la lista de preload de HSTS: <https://hstspreload.org/>

---

<details>
<summary><strong>Respuestas</strong></summary>

### Ejercicio 0

**A1.** `index.txt` es una base de datos de CA separada por tabuladores, una línea por certificado emitido. La columna 1 es el indicador de estado: `V` válido, `R` revocado, `E` expirado. La columna 2 es la fecha notAfter en formato `YYMMDDHHMMSSZ`; cuando el estado es `R`, la columna 3 contiene la fecha de revocación, opcionalmente seguida de `,<reason>`. La columna 4 es el **número de serie en hexadecimal**, la columna 5 el nombre de archivo (o `unknown`), la columna 6 el DN del sujeto. `openssl ocsp -index` responde una consulta haciendo coincidir el número de serie de la petición con la columna 4 e informando la columna 1 — razón por la cual un responder es solo tan correcto como el archivo que la CA escribe al momento de firmar y revocar. Notá también que `openssl ca` mantiene `index.txt.attr`; si ahí `unique_subject = yes`, reemitir para el mismo DN falla.

**A2.** Nada falla al arrancar Apache — `mod_ssl` carga el certificado y lo sirve. La falla es del lado del cliente: un cliente TLS conforme comprueba que el extendedKeyUsage del certificado de servidor contenga `id-kp-serverAuth` (1.3.6.1.5.5.7.3.1). Con solo `clientAuth` presente, el cliente lo rechaza con una alerta `unsupported certificate` / `certificate unknown`, y `openssl verify -purpose sslserver` informa `unsupported certificate purpose`. El EKU es una *restricción aditiva*: extensión ausente significa sin restricción; extensión presente significa solo los propósitos listados.

**A3.** `noCheck` (id-pkix-ocsp-nocheck, RFC 6960 §4.2.2.2.1) le dice a los clientes que no comprueben el estado de revocación del propio certificado del responder OCSP. Sin él, un cliente que valida una respuesta OCSP debe validar el certificado del firmante, lo que requiere comprobar *su* estado de revocación, lo que requiere una consulta OCSP, cuya respuesta está firmada por ese mismo certificado — recursión infinita. La contrapartida es que el certificado del responder no puede revocarse de forma significativa, así que se emite de vida corta.

### Ejercicio 1

**A4.** `s:` es el DN del Subject del certificado en esa posición, `i:` el DN del Issuer. La posición 0 es la hoja; cada entrada siguiente debería ser el emisor de la anterior. La raíz aparece acá solo porque a `s_server` se le pasó un archivo que casualmente la contiene — un servidor público correctamente configurado envía hoja + intermedios y **omite** la raíz, porque la raíz ya debe estar en el almacén de confianza del cliente para que se confíe en ella; enviarla desperdicia bytes de handshake y no prueba nada.

**A5.**
- **20 — unable to get local issuer certificate**: la cadena que envió el servidor termina en un certificado cuyo emisor no está en el almacén de confianza del cliente *y* no fue suministrado. Lo más común es un **intermedio faltante en el servidor** (el emisor de la hoja no aparece por ningún lado), a veces una raíz genuinamente desconocida.
- **21 — unable to verify the first certificate**: la firma de la hoja no pudo verificarse porque no había emisor disponible específicamente para ella — en la práctica, el mismo síntoma del lado del servidor, informado cuando la cadena tiene longitud 1.
- **19 — self-signed certificate in certificate chain**: se construyó una cadena hasta una raíz autofirmada, pero esa raíz **no es de confianza para el cliente** — es decir, falta el anclaje del lado del cliente, típicamente una CA privada no instalada.

Regla práctica: 20/21 → arreglá el bundle `ssl_certificate` / `SSLCertificateFile` del servidor. 19/18 → instalá la CA en el almacén de confianza del cliente.

**A6.** OpenSSL verificó la **validez de la cadena**: firmas hacia arriba en la cadena, fechas de validez, basicConstraints/pathlen, usos de clave, y que se alcanzó un anclaje de confianza. **No** verificó la **identidad** — que el nombre que el cliente pretendía alcanzar aparezca en el `subjectAltName` del certificado. En términos de biblioteca, nunca se llamó a `X509_VERIFY_PARAM_set1_host()`. `s_client` deja esto deliberadamente desactivado a menos que pases `-verify_hostname`, `-verify_ip` o `-verify_email`. Esto se malinterpreta constantemente porque los navegadores y `curl` hacen ambas comprobaciones e informan un veredicto único; `s_client` informa solo la primera. Cualquier script de monitoreo que haga grep de `Verify return code: 0 (ok)` y nada más va a aprobar felizmente un certificado para el dominio equivocado.

**A7.** La renegociación no existe en TLS 1.3 — fue eliminada y reemplazada por key update y autenticación post-handshake — así que el campo informa `IS NOT supported` y eso es correcto y seguro. Bajo TLS 1.2 el mismo servidor informa `IS supported`, lo que significa que implementa la extensión `renegotiation_info` de la RFC 5746. La RFC 5746 existe por la falla de inyección de prefijo en la renegociación TLS de 2009 (CVE-2009-3555): un atacante podía completar un handshake propio con el servidor, empalmar el handshake de la víctima encima como una renegociación, y lograr que su texto plano elegido quedara antepuesto a la petición autenticada de la víctima. `IS NOT supported` en una conexión TLS 1.2 es una bandera roja; en TLS 1.3 no significa nada.

### Ejercicio 2

**A8.** TLS 1.3 redefinió la ciphersuite como un único par AEAD+hash, desacoplado del intercambio de claves y la autenticación, y usa un **espacio de nombres separado y una lista de configuración separada** en OpenSSL. `-cipher` puebla solo la lista de TLS ≤1.2; `-ciphersuites` puebla la lista de TLS 1.3. Correspondencia:
- Apache: `SSLCipherSuite <suites>` (heredado) frente a `SSLCipherSuite TLSv1.3 <suites>` (la forma con prefijo de versión, httpd 2.4.36+ con OpenSSL 1.1.1+).
- nginx: `ssl_ciphers` (solo heredado, sin directiva equivalente para TLS 1.3) frente a `ssl_conf_command Ciphersuites ...` (nginx 1.19.4+).

**A9.** Probó que el servidor soporta una versión de protocolo **más alta** que la que el cliente acababa de ofrecer, y por lo tanto concluyó que el cliente había sido degradado por algo en el camino — así que abortó con `inappropriate_fallback` (alerta 86, RFC 7507). Es histórico porque TLS 1.3 embebe la protección contra downgrade en el propio ServerHello: un servidor capaz de TLS 1.3 que negocia 1.2 o menos escribe un centinela fijo (`DOWNGRD\x01`/`\x00`) en los últimos 8 bytes de `server_random`, que un cliente capaz de TLS 1.3 comprueba y rechaza. La defensa contra downgrade pasó de ser un hack opcional del cliente a estar en el protocolo.

**A10.** `SSLProtocol -all +TLSv1.2 +TLSv1.3`. Es más seguro porque es **deniega por defecto**: `-all` limpia todo, y después enumerás exactamente qué se permite. La forma sustractiva es permite por defecto — cuando la biblioteca gane más adelante TLS 1.4, o cuando una distro haga backport de un protocolo viejo, la lista sustractiva lo permite en silencio porque nunca lo listaste como excluido. El mismo principio aplica a `ssl_protocols` en nginx, que es enumerativa por diseño.

### Ejercicio 3

**A11.** (i) **Validación de cadena/ruta** — firmas criptográficas hasta un anclaje de confianza, más fechas, basicConstraints, pathlen, keyUsage y estado de revocación. (ii) **Vinculación de identidad/nombre** — el nombre de host solicitado coincide con una entrada de `subjectAltName` (RFC 6125; el CN como fallback está depreciado y es ignorado por los navegadores modernos). El paso 2 falló la *validación de cadena* — el certificado falsificado encadenaba a un anclaje no confiable. El paso 3 satisfizo la validación de cadena, y la identidad estuvo satisfecha todo el tiempo porque el atacante simplemente puso el nombre real en el SAN. **Cualquiera puede poner cualquier nombre en un certificado; lo único que hace significativo a un nombre es quién lo firmó.**

**A12.** Dos mecanismos que todavía funcionan:
1. **Certificate Transparency** — el certificado falsificado nunca fue registrado, así que un cliente que exige CT (Chrome requiere SCTs para cadenas de confianza pública) o el monitoreo de CT del dueño del dominio lo notaría. Notá que la exigencia de CT típicamente se omite para anclajes instalados localmente, que es exactamente por qué funcionan los proxies MITM corporativos.
2. **Pinning de clave pública a nivel de aplicación** (apps móviles, `curl --pinnedpubkey`, o DANE/TLSA con DNSSEC) — la app compara el hash del SPKI presentado con un valor compilado, así que una clave distinta falla sin importar quién la firmó.

**HSTS no es uno de ellos.** HSTS fuerza *HTTPS*, no *un certificado en particular*. Contra un atacante que posee una cadena en la que el cliente confía, HSTS no cambia nada — defiende contra el stripping, no contra la suplantación.

**A13.** `openssl version -d` imprime el OPENSSLDIR (típicamente `/usr/lib/ssl` en Debian, `/etc/pki/tls` en RHEL), cuyo subdirectorio `certs/` es el `-CApath` por defecto; el `-CAfile` por defecto es el `cert.pem` de ese directorio. Las variables de entorno que lo sobrescriben son `SSL_CERT_FILE` y `SSL_CERT_DIR`. Inspeccioná el bundle con `openssl storeutl -noout -certs /etc/ssl/certs/ca-certificates.crt | grep -c Subject`, y acordate de que un directorio `-CApath` se consulta mediante enlaces simbólicos por hash del nombre de sujeto, mantenidos por `openssl rehash` (`c_rehash`).

### Ejercicio 4

**A14.** La construcción de la ruta TLS ocurre en el cliente, y el cliente solo puede construir una ruta a partir de (a) lo que el servidor envió y (b) lo que ya tiene por confiable. Con solo la hoja enviada, un cliente cuyo almacén contiene la raíz pero no el intermedio no puede salvar la brecha. Algunos clientes tienen éxito igual por dos razones: **cachean intermedios** vistos en conexiones anteriores (Firefox es famoso por esto, razón por la cual "funciona en mi laptop" no vale como evidencia), o **descargan el emisor** desde la URI `caIssuers` del `authorityInfoAccess` de la hoja (Windows/Schannel y macOS hacen esto; OpenSSL no). Probá siempre con `openssl s_client` desde un host limpio — no hace ninguna de las dos cosas.

**A15.** `SSLCertificateFile`, desde httpd 2.4.8, acepta la hoja seguida de la cadena de intermedios en un solo archivo PEM. El orden es significativo: **la hoja primero**, después cada emisor en orden ascendente, la raíz opcional y normalmente omitida. `SSLCertificateChainFile` todavía se parsea pero está depreciada y no puede combinarse limpiamente con múltiples tipos de certificado (configuraciones de doble certificado RSA + ECDSA).

**A16.** `apachectl configtest` informa algo como `AH02565: Certificate and private key www.example.test:443:0 from /etc/ssl/certs/www.crt and /etc/ssl/private/other.key do not match` y el servidor se niega a arrancar. Sin tocar el servicio:

```bash
# RSA only
diff <(openssl x509 -noout -modulus -in cert.crt) <(openssl rsa -noout -modulus -in key.pem)
# any algorithm (RSA, EC, Ed25519)
diff <(openssl x509 -in cert.crt -noout -pubkey) <(openssl pkey -in key.pem -pubout)
```

Salida idéntica significa que se emparejan. La segunda forma es la que hay que memorizar — `openssl rsa -modulus` simplemente da error con una clave EC, y los despliegues modernos son cada vez más ECDSA.

### Ejercicio 5

**A17.** El **primer** vhost listado para esa dirección:puerto — el vhost por defecto de Apache para ese socket. Es lo que recibe cualquier cliente que omite SNI, y también es el certificado usado para el handshake inicial antes de que Apache pueda consultar la cabecera Host. En Debian el orden sigue los nombres de los symlinks en `sites-enabled` (razón por la cual `000-default` se llama así); `apachectl -S` imprime la resolución explícitamente y marca el que es por defecto.

**A18.** Está mal donde haya que servir a clientes reales sin SNI — Java 6 antiguo, Windows XP/IE, algunos stacks HTTP embebidos y de IoT, o un agente interno de monitoreo que se conecta por dirección IP. Esos clientes reciben una falla dura de handshake en lugar de una advertencia de certificado, lo que es más difícil de diagnosticar. Además no protege de nada relevante para la seguridad: previene el caso *confuso* donde la cabecera Host y el certificado no coinciden, pero un atacante no gana nada omitiendo SNI. Tratalo como un ajuste de corrección/higiene, no como un control.

**A19.** **Encrypted Client Hello (ECH)**, el sucesor de ESNI. Cifra todo el ClientHello interno — incluyendo SNI y ALPN — bajo una clave pública que el cliente obtiene del registro de recurso DNS `HTTPS`/`SVCB` (parámetro `ech=`) del nombre destino. Así que requiere la publicación de la configuración ECH en DNS y, para ser significativo contra un atacante en la ruta, DNSSEC o transporte DNS cifrado (DoH/DoT); si no, el atacante simplemente lee o falsifica la consulta DNS. El soporte requiere ambos extremos; el soporte en Apache y nginx sigue siendo limitado/mediante parches al momento de escribir esto.

**A20.** Una dirección IP por sitio TLS — el certificado se elegía por la dirección local del socket, ya que debe seleccionarse antes de que llegue cualquier dato de capa de aplicación. Los equivalentes modernos son (i) **subjectAltName con múltiples entradas DNS** (un certificado "SAN"/UCC que cubre varios nombres) y (ii) **certificados wildcard** (`DNS:*.example.test`, que coincide con exactamente una etiqueta y no con el dominio desnudo). Ambos permiten que un solo certificado sirva varios nombres sin SNI, al costo de acoplar su material de clave.

### Ejercicio 6

**A21.** `Header set` opera sobre la tabla de cabeceras `onsuccess` y se omite para muchas respuestas generadas internamente — redirecciones 301/302, 401, 403, 404, 500 y cualquier cosa producida antes del manejo de contenido. `Header always set` apunta a la tabla `always`, que aplica a toda respuesta. Concretamente: con `set` a secas, `curl -I https://www.example.test/nope` (404) **no** devuelve cabecera `Strict-Transport-Security`, así que un usuario cuya primera respuesta HTTPS es una página de error nunca recibe la política. Con `always`, el paso 3 la muestra presente en el 404.

**A22.** La **brecha de arranque por confianza en el primer uso (TOFU)**: la política solo existe en el navegador después de al menos una respuesta HTTPS exitosa de ese host, así que la primerísima visita — o la primera después de que caduca el `max-age`, o desde un perfil nuevo — es vulnerable al stripping. Se cierra con la **lista de preload de HSTS**: un conjunto de nombres de host compilados dentro de los binarios de los navegadores, de modo que la política se aplica antes de que se haga conexión alguna.

**A23.** (i) un certificado válido; (ii) redirigir todo HTTP a HTTPS en el mismo host, y servir la cabecera sobre HTTPS con un `max-age` de **al menos 31536000** (un año); (iii) las directivas `includeSubDomains` y `preload` ambas presentes. El riesgo: como la lista se envía dentro de los binarios de los navegadores, la eliminación tarda meses en propagarse por los canales de release. `includeSubDomains` cubre cada subdominio, incluidos los que olvidaste — un `legacy.example.test` interno en HTTP plano, un `cdn.example.test` operado por un socio, una caja de gestión de dispositivos — y todos quedan inalcanzables, sin ninguna anulación que el usuario pueda clickear. Hacé preload después de auditar cada subdominio, no antes.

**A24.** Cubre `www.example.test` y todo lo que esté **por debajo** (`a.www.example.test`), pero **no** `example.test` ni `intranet.example.test`, porque esos no son subdominios de `www.example.test` — la política se almacena contra el host que la envió. Para cubrir toda la zona, serví la cabecera desde `example.test` mismo (típicamente en el vhost de redirección del ápex, que por lo tanto debe ser HTTPS).

### Ejercicio 7

**A25.** `SSLCACertificateFile` (y `SSLCACertificatePath`) definen las CAs en las que Apache **realmente va a confiar** al validar un certificado de cliente presentado. `SSLCADNRequestFile`/`SSLCADNRequestPath` definen solamente la lista de nombres distinguidos de CA anunciada en el mensaje TLS `CertificateRequest`, que los navegadores usan para filtrar cuál de los certificados del usuario ofrecer. Si configurás solo `SSLCADNRequestFile`, la verificación no tiene anclajes de confianza: todo certificado de cliente falla con `unable to get local issuer certificate` aunque el navegador haya ofrecido exactamente el correcto. Las dos existen por separado porque los despliegues grandes confían en cientos de CAs pero no deben hacer explotar el handshake — la lista de DN se envía en claro y puede llegar a kilobytes, y además filtra tus relaciones de confianza a todo cliente que se conecte.

**A26.** Bajo TLS 1.2, un `SSLVerifyClient` por directorio se implementaba mediante **renegociación**: Apache leía la petición, veía que el `<Location>` coincidía, y disparaba un segundo handshake en el que pedía un certificado. TLS 1.3 eliminó la renegociación por completo. Su reemplazo es la **autenticación post-handshake (PHA)**, a la que el cliente debe adherirse enviando la extensión `post_handshake_auth` **en su ClientHello inicial** — el servidor no puede solicitarla retroactivamente. `openssl s_client` envía esa extensión solo con `-enable_pha`, así que sin la bandera Apache registra `AH10130: Client did not enable post-handshake authentication` y devuelve 403. Los navegadores generalmente no implementan PHA, razón por la cual la autenticación de cliente por `<Location>` es frágil en la era de TLS 1.3; el patrón robusto es exigir el certificado a nivel de vhost (un `ServerName` separado para la app protegida) en lugar de por directorio.

**A27.** `SSLVerifyClient optional` (Apache) y `ssl_verify_client optional` de nginx ambos **solicitan** un certificado y, si se presenta uno, lo **validan por completo** contra las CAs configuradas — uno inválido hace fallar el handshake o pone `$ssl_client_verify` en `FAILED:<reason>`. El `optional_no_ca` de nginx solicita un certificado y **no realiza validación alguna**: ni firma, ni expiración, ni emisor, ni revocación, nada. Cualquier cosa autofirmada se acepta y se exporta a la aplicación. Su uso legítimo es delegar la validación a un upstream que tiene la lógica de confianza real — por ejemplo, una aplicación o un servicio de autorización que recibe `$ssl_client_escaped_cert`, lo compara contra un registro de dispositivos o un esquema DID/prueba de posesión, y donde nginx deliberadamente no es el punto de decisión de política. Tratá a `optional_no_ca` como "capturar, no autenticar".

**A28.** `+StdEnvVars` hace que Apache pueble unas dos docenas de variables de entorno `SSL_*` (protocolo, cifrado, ambos DNs, validez, número de serie…) para **cada** petición, incluyendo archivos estáticos. Eso es formateo de cadenas y memoria por petición que la enorme mayoría de las respuestas nunca lee. La práctica documentada es acotarlo a los handlers que lo necesitan:

```apache
<FilesMatch "\.(cgi|shtml|phtml|php)$">
    SSLOptions +StdEnvVars
</FilesMatch>
<Directory /usr/lib/cgi-bin>
    SSLOptions +StdEnvVars
</Directory>
```

`+ExportCertData` es aún más pesado — exporta el PEM completo de los certificados de cliente y de servidor (`SSL_CLIENT_CERT`, `SSL_SERVER_CERT`) — así que acotalo a la única ubicación que los parsea.

**A29.** La profundidad cuenta el número de CAs **intermedias** entre el certificado de cliente y un anclaje de confianza, así que `SSLVerifyDepth 2` permite: profundidad 0, un certificado que *es* una CA de confianza; profundidad 1, uno emitido directamente por una CA de confianza; profundidad 2, uno emitido por un intermedio bajo una CA de confianza. Así que sí — un certificado emitido directamente por la raíz valida cómodamente (profundidad 1), y un certificado bajo una sub-CA de segundo nivel (raíz → emisora → sub → hoja) tiene profundidad 3 y es **rechazado** con `certificate chain too long`. El valor por defecto es 1, que es la causa clásica de "los certificados de nuestra nueva sub-CA dejaron de funcionar" tras una reorganización de la PKI.

### Ejercicio 8

**A30.** La respuesta fue firmada por `ocsp/signer.key`, cuyo certificado es un certificado de **responder OCSP delegado**. Dos propiedades lo autorizaron: (i) fue **emitido por la misma CA** sobre cuyos certificados informa (la RFC 6960 exige que el responder sea la propia CA emisora, un firmante delegado emitido por esa CA, o un responder de confianza configurado fuera de banda), y (ii) lleva `extendedKeyUsage = OCSPSigning` (id-kp-OCSPSigning, 1.3.6.1.5.5.7.3.9), marcado crítico acá. `noCheck` está presente para que los clientes no recursen. Si faltara cualquiera de las dos propiedades, `openssl ocsp` imprimiría `Response Verify Failure` con `unsupported certificate purpose` o `unable to get local issuer certificate` — y los clientes ignorarían el staple.

**A31.** Beneficios del stapling:
1. **Privacidad** — el cliente nunca contacta a la CA, así que la CA no se entera de qué sitio visita cada dirección IP.
2. **Latencia y fiabilidad** — sin una consulta DNS extra más un viaje HTTP de ida y vuelta a un tercero en la ruta crítica del handshake; el staple llega dentro del handshake al que pertenece.
3. **Desacople de disponibilidad** — un responder de CA sobrecargado o inalcanzable ya no degrada ni rompe las conexiones de tu sitio, y la respuesta se obtiene una vez por servidor en lugar de una vez por cliente.

Lo que **no** resuelve: un atacante que robó la clave y está suplantando al servidor simplemente **no hace stapling**. Como los clientes fallan de forma blanda ante un estado faltante, la revocación es invisible. Solo la extensión TLS Feature **Must-Staple** (RFC 7633) horneada en el certificado lo cierra, al hacer de un staple faltante un error fatal — al precio de que cualquier caída del stapling tira el sitio abajo de forma dura.

**A32.** `SSLStaplingCache` es una directiva **global**: ponerla dentro de `<VirtualHost>` es un error de sintaxis y `apachectl configtest` falla con `SSLStaplingCache not allowed here`. Omitirla teniendo `SSLUseStapling on` hace que el arranque falle con un mensaje que dice que el stapling requiere una caché configurada. Una falla relacionada y más desagradable es silenciosa: si Apache no puede encontrar el certificado **emisor** de una hoja (porque cargaste la hoja sola en lugar de la fullchain), registra `AH02217: ssl_stapling_init_cert: Can't retrieve issuer certificate!` a nivel error, **arranca igual**, y simplemente nunca hace stapling para ese certificado. El stapling depende, por lo tanto, de la misma cadena completa que necesitan los clientes.

**A33.** Con `SSLStaplingReturnResponderErrors on` (el valor por defecto), Apache reenvía las fallas del responder — `tryLater`, `unauthorized`, respuestas malformadas — a los clientes dentro de la extensión TLS. Los clientes generalmente las ignoran, pero un cliente que exige Must-Staple puede tratar un estado de error como una falla dura, y convertiste "el responder de la CA está teniendo un mal día" en "nuestro sitio está caído". Ponerlo en `off` hace que Apache **no** envíe extensión de estado cuando no tiene una respuesta buena, ante lo cual los clientes fallan de forma blanda. `off` es el valor de producción; combinalo con `SSLStaplingFakeTryLater off` y monitoreo del log de errores de stapling, para que la caída sea visible para vos y no para los usuarios.

**A34.** `reload` (graceful) conserva la caché `shmcb` de stapling existente, y la respuesta `good` cacheada seguía dentro de su ventana de `SSLStaplingStandardCacheTimeout`, así que Apache siguió sirviéndola. `restart` descarta el segmento de memoria compartida. En producción el mismo efecto aparece como latencia de revocación acumulada de tres fuentes: la caché de staple del servidor (`SSLStaplingStandardCacheTimeout`, por defecto 3600 s), el propio `nextUpdate` de la respuesta OCSP (de horas a días en CAs públicas), y la respuesta cacheada del cliente. Una revocación no es, por lo tanto, efectiva en el cable durante horas — que es precisamente por qué la rotación de claves y los certificados de vida corta desplazaron a la revocación como respuesta primaria ante un compromiso.

### Ejercicio 9

**A35.** Un archivo PEM que contenga la **hoja primero**, después los intermedios en orden de emisión, la raíz omitida. Si el orden se invierte, nginx usa el primer certificado del archivo como certificado de servidor y falla al arrancar con `SSL_CTX_use_PrivateKey_file(... ) failed (SSL: error:...:key values mismatch)`, porque la clave privada se empareja con la hoja, no con el intermedio. Si un certificado espurio se *añade al final* en lugar de al principio, nginx arranca perfecto y los clientes ven una cadena rota — el modo de falla es silencioso y solo `s_client -showcerts` lo revela.

**A36.** nginx obtiene la respuesta OCSP de forma **perezosa**: inicia la descarga cuando el primer cliente pide un estado, y responde ese primer handshake sin ella. El `mod_ssl` de Apache prepara el staple al momento de cargar el certificado y lo mantiene en `SSLStaplingCache`, así que un servidor recién recargado normalmente hace stapling en la primera conexión. Por esto el monitoreo del stapling en nginx siempre debe sondear dos veces, y por esto `ssl_stapling_file` es preferible donde importa el determinismo.

**A37.** nginx debe resolver el nombre de host de la URI OCSP del `authorityInfoAccess` del certificado, y lo hace con su propio resolver interno en lugar del stub del sistema — `/etc/resolv.conf` no se consulta para esto. Sin `resolver` registra `no resolver defined to resolve ocsp.example.test` y el stapling nunca se activa. `ssl_stapling_file` elimina la dependencia porque la respuesta codificada en DER se lee del disco; nginx no hace ninguna petición de red. El costo es que tenés que refrescar ese archivo antes de su `nextUpdate` — un cron/timer de systemd que ejecute `openssl ocsp -respout` más `nginx -s reload`.

**A38.** En nginx, las directivas `add_header` se heredan del nivel envolvente **solo si el nivel actual no define ninguna propia**. En el momento en que `location /secure/` contiene un solo `add_header`, todo `add_header` heredado del bloque `server` se descarta para esa location. Omitir la repetición dejaría caer silenciosamente la cabecera HSTS — y cualquier CSP, `X-Frame-Options`, etc. — exactamente en las páginas que más importan. La misma regla de reemplazar-no-fusionar aplica a `add_header` dentro de bloques `if`, razón por la cual las cabeceras de seguridad suelen centralizarse en un snippet `include` repetido en cada nivel.

**A39.** Costo: como `ssl_verify_client optional` (o `on`) debe decidirse durante el handshake, nginx envía un `CertificateRequest` en **cada** conexión a ese bloque server, incluidas las visitas anónimas a la parte pública del sitio. Los navegadores entonces muestran un diálogo de selección de certificado a usuarios que no necesitaban autenticarse, y la lista de CAs aceptables se revela a todo el mundo. La mitigación habitual es un bloque `server` separado con un `server_name` (o puerto) distinto para la app autenticada. `$ssl_client_verify` contiene `SUCCESS`, `NONE` (no se envió certificado), o `FAILED:<reason>` donde la razón es el texto de verificación de OpenSSL, p. ej. `FAILED:certificate has expired`, `FAILED:unable to get local issuer certificate` — con `ssl_verify_client optional` la conexión sobrevive para que tu `if` pueda devolver 403 con una línea de log útil, razón por la cual `optional` + comprobación explícita suele ser mejor operativamente que `on`.

**A40.** `ssl_conf_command Ciphersuites TLS_AES_256_GCM_SHA384:...`, disponible desde **nginx 1.19.4** (expone la interfaz `SSL_CONF_cmd` de OpenSSL y requiere OpenSSL 1.0.2+; el comando `Ciphersuites` en sí necesita OpenSSL 1.1.1+). `ssl_ciphers` mapea solo a la lista de TLS ≤1.2, y las dos no interactúan.

### Ejercicio 10

**A41.** El servidor está enviando un único certificado — la hoja sin su intermedio. Arreglo: apuntá `SSLCertificateFile`/`ssl_certificate` al archivo fullchain (hoja + intermedio) y recargá. `curl` en el servidor no lo reprodujo porque el almacén de confianza local, poblado durante el laboratorio, ya contenía el intermedio como `-CAfile`/anclaje; el `curl` local pudo completar la ruta con material que el cliente remoto no tiene. La lección general: **nunca valides una cadena desde un host que participa en la PKI.**

**A42.** La comparación `-pubkey`/`-pubout` hashea el SubjectPublicKeyInfo DER completo, así que funciona idénticamente para RSA, ECDSA y Ed25519 y captura el algoritmo y los parámetros, no solo un entero. La forma `-modulus` es solo para RSA (`openssl rsa` da error con `Expecting: ANY PRIVATE KEY` en una clave EC, lo que se lee como archivo corrupto y manda a la gente por el camino equivocado) y compara solo *n*, ignorando el exponente público. La trampa: **una discrepancia de módulo con una coincidencia de pubkey no puede ocurrir** en un par genuino — si la observás, comparaste los archivos equivocados, o ejecutaste `openssl rsa` contra una clave de otro algoritmo y hasheaste un mensaje de error. Dos hashes idénticos de salida vacía o de error también "coinciden"; confirmá siempre que el hash no sea el SHA-256 de la cadena vacía (`e3b0c442...`).

**A43.** Tres causas:
1. **El servidor todavía no obtuvo una respuesta** — la primera descarga perezosa de nginx, o Apache recién reiniciado. Discriminador: reintentar unos segundos después.
2. **El servidor no puede alcanzar o autorizar al responder** — responder caído, sin `resolver` en nginx, firewall de egreso, o el certificado no tiene ninguna URI OCSP en `authorityInfoAccess`. Discriminador: `openssl x509 -noout -ext authorityInfoAccess` para verificar presencia, y después consultar la URL a mano.
3. **El servidor no puede construir la petición** — el certificado emisor no está cargado, así que Apache registra `AH02217: Can't retrieve issuer certificate!` y deshabilita el stapling para ese certificado.

El comando más discriminante es la consulta manual, porque ejercita URL, alcanzabilidad, emisor y autorización del firmante a la vez:

```bash
openssl ocsp -issuer ca/issuing.crt -cert srv/www.crt -CAfile ca/ca-chain.crt \
  -url "$(openssl x509 -in srv/www.crt -noout -ocsp_uri)" -resp_text
```

Si eso funciona y el servidor sigue sin hacer stapling, la falla está en la configuración del servidor (cadena o caché faltante), no en la PKI.

**A44.** Dos causas que ninguno de los comandos revela:
1. **Profundidad**. `SSLVerifyDepth` / `ssl_verify_depth` es demasiado baja para la cadena, o el cliente envió solo su hoja mientras el servidor no tiene copia del intermedio en `SSLCACertificateFile`. `openssl verify` tuvo éxito solo porque le pasaste `-untrusted ca/issuing.crt` en la línea de comandos — al servidor nunca se le dio ese certificado.
2. **El cliente nunca ofreció el certificado.** Bajo TLS 1.3 sin PHA (Q26), o porque la lista de CAs aceptables del `CertificateRequest` no incluía al emisor del certificado, así que el navegador lo filtró y envió un mensaje Certificate vacío. `openssl s_client -state -msg` mostrando un Certificate de cliente vacío lo confirma.

Dos candidatos adicionales que vale la pena revisar: **revocación** — el certificado de cliente está listado en una CRL cargada vía `SSLCARevocationFile` con `SSLCARevocationCheck chain`, lo que hace fallar el handshake con `certificate revoked` — y **fechas de validez**, ya que `openssl verify` usa el reloj actual mientras que un servidor con el reloj desfasado no.

</details>