# 331.2 — X.509 Certificates for Encryption, Signing and Authentication
## Guided Exercises: TLS services with Apache HTTPD, nginx and OpenSSL

**Certification:** LPIC-3 Security — exam 303-300, v3.0.0 · **Objective weight:** 6.67

These exercises assume a single Linux host (Debian 12+ / Ubuntu 24.04 or RHEL 9 / Rocky 9) with `root` access, OpenSSL 3.x, Apache HTTPD 2.4.36+ and nginx 1.24+. Everything runs against loopback with the RFC 6761 reserved TLD `.test`, so nothing leaves the machine.

Check your baseline before starting — several steps depend on TLS 1.3 support in **both** the library and the server:

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

> If `openssl version` reports 1.1.0 or older, TLS 1.3, `-enable_pha` and the split `SSLCipherSuite TLSv1.3` syntax will not exist. Stop and upgrade the lab; the exam targets a TLS 1.3-capable stack.

---

## Exercise 0 — Lab PKI and name resolution

Objective 331.2 uses certificates; it does not teach you to make them (that is 331.1). This block builds the minimum PKI the rest of the lab consumes: a root CA, an **intermediate (issuing) CA** with a real `openssl ca` database — needed later for revocation and OCSP — a server certificate per virtual host, a client certificate and a delegated OCSP signer.

**Step 1.** Create the working tree and the host aliases.

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

**Step 2.** Create the root CA (self-signed, offline in real life).

```bash
openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -noenc \
  -keyout ca/root.key -out ca/root.crt \
  -subj "/C=AR/O=Example PKI/CN=Example Root CA" \
  -addext "basicConstraints=critical,CA:TRUE,pathlen:1" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -addext "subjectKeyIdentifier=hash"
chmod 600 ca/root.key
```

**Step 3.** Create the issuing CA and have the root sign it.

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

**Step 4.** Write the CA configuration used by `openssl ca` (this is the "CA/certificate/CRL files and directories" layout the objective names).

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

Note `copy_extensions = none`. Extensions therefore come from an `-extfile`, never from the CSR — a CSR is an *unauthenticated request*, and a CA that blindly copies its extensions can be talked into issuing `CA:TRUE`.

**Step 5.** Issue the two server certificates, the client certificate and the OCSP signer.

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

**Step 6.** Build the file the web servers will actually load, and inspect what you produced.

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

### Check your understanding

**Q1.** In `ca/index.txt`, what do the first column (`V`), the second field and the fourth field mean, and which of them does `openssl ocsp -index` read to answer a status query?

**Q2.** The server certificate carries `extendedKeyUsage = serverAuth` and the client one `clientAuth`. What breaks, concretely, if you swap them and try to use the client certificate as an Apache `SSLCertificateFile`?

**Q3.** Why does the OCSP signer carry `noCheck`, and what recursion problem would exist without it?

---

## Exercise 1 — Reading a real handshake with `openssl s_client`

The objective names `s_client` and `s_server` explicitly. Treat `s_client` as your protocol microscope: it is the only tool that shows you what the server *sent*, as opposed to what the browser *decided*.

**Step 1.** Start a throwaway TLS server so you have a peer before Apache exists.

```bash
cd ~/lab331
openssl s_server -accept 4433 -www \
  -cert srv/www.fullchain.crt -key srv/www.key &
```

**Step 2.** Connect and read the output top to bottom.

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

**Step 3.** Now drop the trust anchor and compare the tail.

```bash
openssl s_client -connect 127.0.0.1:4433 </dev/null 2>/dev/null | grep -E 'Verify|Verification'
```

```
Verification error: unable to get local issuer certificate
    Verify return code: 20 (unable to get local issuer certificate)
```

**Step 4.** Ask for the *wrong* name and observe that nothing complains.

```bash
openssl s_client -connect 127.0.0.1:4433 -servername evil.example.test \
  -CAfile ca/root.crt </dev/null 2>/dev/null | grep -E 'Verification|Verify return'
```

```
Verification: OK
    Verify return code: 0 (ok)
```

**Step 5.** Turn identity checking on explicitly and repeat.

```bash
openssl s_client -connect 127.0.0.1:4433 -CAfile ca/root.crt \
  -verify_hostname evil.example.test -verify_return_error </dev/null 2>&1 | tail -5
```

```
Verification error: Hostname mismatch
140234...:error:0A000086:SSL routines:tls_post_process_server_certificate:certificate verify failed:
    Verify return code: 62 (Hostname mismatch)
```

**Step 6.** Compare a fresh handshake against a resumed one, and pick the protocol version by hand.

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

### Check your understanding

**Q4.** In the `Certificate chain` block, what do the `s:` and `i:` lines mean, and why is the root CA present here but absent from a correctly configured public server?

**Q5.** Distinguish `Verify return code: 20 (unable to get local issuer certificate)` from `21 (unable to verify the first certificate)` and from `19 (self-signed certificate in certificate chain)`. Which one points at a missing intermediate on the *server*, and which at a missing anchor on the *client*?

**Q6.** Step 4 returned `Verification: OK` for a name the certificate does not contain. What did OpenSSL actually verify, what did it not, and why is this the single most misread output in the whole tool?

**Q7.** `Secure Renegotiation IS NOT supported` appeared under TLS 1.3 but would say `IS supported` under TLS 1.2 against the same server. Explain both, and name the CVE-era problem RFC 5746 was written to fix.

---

## Exercise 2 — Protocol versions, downgrade protection and cipher configuration

**Step 1.** Enumerate what your library will even offer.

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

**Step 2.** Restart the test server pinned to TLS 1.2 only and probe the boundary.

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

**Step 3.** Simulate a downgrade attempt. A network attacker who kills TLS 1.3 handshakes forces a retry at TLS 1.2; the client signals "I already tried higher" with the fallback SCSV.

```bash
kill %1; openssl s_server -accept 4433 -www -cert srv/www.fullchain.crt -key srv/www.key &
openssl s_client -connect 127.0.0.1:4433 -tls1_2 -fallback_scsv </dev/null 2>&1 | grep -iE 'alert|error'
```

```
140551...:error:0A000410:SSL routines:ssl3_read_bytes:ssl/tls alert inappropriate fallback:
```

**Step 4.** Force a suite selection on TLS 1.2 and then try the same syntax on TLS 1.3.

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

### Check your understanding

**Q8.** In step 4 the middle command asked for a ChaCha20 suite and got `TLS_AES_256_GCM_SHA384` anyway. Why did `-cipher` have no effect, and which Apache/nginx directives correspond to `-cipher` versus `-ciphersuites`?

**Q9.** What exactly did the `inappropriate fallback` alert in step 3 prove, and why is TLS_FALLBACK_SCSV largely historical on a TLS 1.3 stack?

**Q10.** RFC 8996 deprecates TLS 1.0 and 1.1. Write the Apache directive that permits only TLS 1.2 and 1.3, and explain why `SSLProtocol -all +TLSv1.2 +TLSv1.3` is safer to maintain than `SSLProtocol All -SSLv3 -TLSv1 -TLSv1.1`.

---

## Exercise 3 — Man-in-the-middle: what certificates actually defend

**Step 1.** Build the attacker's PKI and a forged certificate for a name you do not own.

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

**Step 2.** Run the impostor and connect with the *legitimate* trust anchor.

```bash
kill %1 2>/dev/null
openssl s_server -accept 4433 -www -cert fake.crt -key fake.key &
openssl s_client -connect 127.0.0.1:4433 -CAfile ~/lab331/ca/root.crt \
  -verify_hostname www.example.test </dev/null 2>/dev/null | grep -E 'Verify return|subject='
```

```
    Verify return code: 20 (unable to get local issuer certificate)
```

**Step 3.** Now do what malware, a corporate proxy or a compromised device management agent does — install the attacker CA as trusted — and repeat.

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

**Step 4.** Clean up immediately — do not leave a rogue anchor installed.

```bash
sudo rm -f /usr/local/share/ca-certificates/evilca.crt && sudo update-ca-certificates --fresh
# RHEL: sudo rm -f /etc/pki/ca-trust/source/anchors/evilca.crt && sudo update-ca-trust extract
openssl s_client -connect 127.0.0.1:4433 </dev/null 2>/dev/null | grep 'Verify return'
kill %1
```

```
    Verify return code: 20 (unable to get local issuer certificate)
```

### Check your understanding

**Q11.** A TLS peer certificate is checked along two independent axes. Name both, and say which one step 2 failed and which one step 3 satisfied.

**Q12.** After step 3 the MITM is cryptographically invisible to `s_client` and to a browser. Name two mechanisms that could still expose it, and state clearly whether HSTS is one of them.

**Q13.** Where does OpenSSL look for anchors when `-CAfile` is absent? Show the two commands that reveal the compiled-in path and the environment variables that override it.

---

## Exercise 4 — Apache HTTPD with `mod_ssl`: a correct HTTPS vhost

**Step 1.** Install the certificates where the server can read them, and enable the modules.

```bash
sudo install -o root -g root -m 644 ~/lab331/srv/www.fullchain.crt  /etc/ssl/certs/
sudo install -o root -g root -m 644 ~/lab331/srv/shop.fullchain.crt /etc/ssl/certs/
sudo install -o root -g root -m 640 ~/lab331/srv/www.key            /etc/ssl/private/
sudo install -o root -g root -m 640 ~/lab331/srv/shop.key           /etc/ssl/private/
sudo install -o root -g root -m 644 ~/lab331/ca/ca-chain.crt        /etc/ssl/certs/

sudo a2enmod ssl headers socache_shmcb            # Debian family
# RHEL family:  sudo dnf install -y mod_ssl
```

**Step 2.** Write the vhost. On Debian this is `/etc/apache2/sites-available/www-tls.conf`; on RHEL, `/etc/httpd/conf.d/www-tls.conf`.

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

**Step 3.** Publish content, validate syntax, reload.

```bash
sudo mkdir -p /var/www/www && echo '<h1>www</h1>' | sudo tee /var/www/www/index.html
sudo a2ensite www-tls && sudo apachectl configtest && sudo systemctl reload apache2
```

```
Syntax OK
```

**Step 4.** Verify from the client side, not from the config file.

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

**Step 5.** Break it deliberately: serve the leaf without the intermediate.

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

Restore the fullchain before continuing:

```bash
sudo sed -i 's#/etc/ssl/certs/www.crt#/etc/ssl/certs/www.fullchain.crt#' \
     /etc/apache2/sites-available/www-tls.conf
sudo systemctl reload apache2
```

### Check your understanding

**Q14.** In step 5 the certificate itself was perfectly valid and `openssl verify -CAfile ca-chain.crt srv/www.crt` returns OK. Why did the *connection* still fail, and why do some clients (notably Firefox, or a second visit to a different site from the same CA) sometimes succeed anyway?

**Q15.** `SSLCertificateChainFile` still parses in 2.4 but is deprecated. What replaced it, and in which order must certificates appear in the replacement file?

**Q16.** You paste the wrong private key next to the certificate. What does `apachectl configtest` report, and which two commands prove key/certificate pairing *without* restarting anything — for an RSA key and, algorithm-agnostically, for any key?

---

## Exercise 5 — SNI: many certificates, one socket

**Step 1.** Add the second vhost on the same IP and port.

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

**Step 2.** Show that the certificate follows the SNI value, not the IP.

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

**Step 3.** Connect with **no** SNI at all, the way an ancient client would.

```bash
openssl s_client -connect 127.0.0.1:443 -noservername </dev/null 2>/dev/null \
  | openssl x509 -noout -subject
```

```
subject=CN = www.example.test
```

**Step 4.** Make the absence of SNI an error instead of a silent wrong answer.

```bash
sudo sed -i '/^Listen 443 https/a SSLStrictSNIVHostCheck on' \
     /etc/apache2/sites-available/www-tls.conf
sudo systemctl reload apache2
openssl s_client -connect 127.0.0.1:443 -noservername </dev/null 2>&1 | grep -iE 'alert|error'
```

```
40B7...:error:0A000410:SSL routines:ssl3_read_bytes:ssl/tls alert handshake failure:
```

**Step 5.** Watch the SNI travel in clear text.

```bash
sudo timeout 5 tcpdump -i lo -n -A 'tcp port 443' 2>/dev/null | grep -a 'example.test' &
openssl s_client -connect 127.0.0.1:443 -servername shop.example.test </dev/null >/dev/null 2>&1
```

```
....shop.example.test.....
```

### Check your understanding

**Q17.** Which vhost answered the SNI-less handshake in step 3, and what rule did Apache apply to choose it?

**Q18.** `SSLStrictSNIVHostCheck on` turned a wrong certificate into a handshake failure. Under what circumstance is that the *wrong* setting for a production site, and what does it not protect against?

**Q19.** Step 5 shows the requested hostname on the wire before any encryption exists. Name the extension designed to close that leak, and state what it requires from DNS.

**Q20.** Before SNI (RFC 6066), how did operators host multiple TLS sites, and which two certificate features are the modern equivalents of that workaround?

---

## Exercise 6 — HSTS and the SSL-stripping attack

**Step 1.** Prove the attack surface exists. Fetch the plain-HTTP entry point and look at the redirect a user's very first request depends on.

```bash
curl -sSI http://www.example.test/ | head -3
```

```
HTTP/1.1 301 Moved Permanently
Date: Wed, 19 Aug 2026 12:41:02 GMT
Location: https://www.example.test/
```

A MITM that rewrites this response — or simply proxies the site over plain HTTP — never touches a certificate at all. Nothing you configured so far stops it.

**Step 2.** Add the HSTS policy to the **HTTPS** vhost only.

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

**Step 3.** Confirm the header is emitted on error responses too — this is what `always` buys you.

```bash
curl -sSI --cacert ~/lab331/ca/root.crt https://www.example.test/nope | head -1
curl -sSI --cacert ~/lab331/ca/root.crt https://www.example.test/nope | grep -i strict
```

```
HTTP/1.1 404 Not Found
strict-transport-security: max-age=63072000; includeSubDomains
```

**Step 4.** Verify that the header on port 80 is inert. Temporarily add the same `Header` line to the `*:80` vhost, reload, and fetch:

```bash
curl -sSI http://www.example.test/ | grep -i strict
```

```
strict-transport-security: max-age=63072000; includeSubDomains
```

The server sends it; a conforming browser **discards** it. Remove the line again.

**Step 5.** Inspect what a preload-eligible policy looks like, without submitting anything:

```apache
    Header always set Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
```

### Check your understanding

**Q21.** Why `Header always set` rather than `Header set`? Give a concrete response where the difference is visible.

**Q22.** A browser that has never visited the site is still strippable even with HSTS deployed. Name this gap and the mechanism that closes it.

**Q23.** State the three requirements a policy must meet to qualify for the preload list, and the operational risk that makes preload effectively irreversible in the short term.

**Q24.** Your site is `www.example.test` and `includeSubDomains` is set on it. Does the policy cover `example.test` and `intranet.example.test`? Explain.

---

## Exercise 7 — Client certificate authentication with `mod_ssl`

**Step 1.** Package Alice's credentials the way a browser or OS keystore wants them.

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

**Step 2.** Require certificates on a subtree of the `www` vhost.

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

**Step 3.** Try without a certificate, then with one.

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

**Step 4.** Reproduce the same exchange with `s_client`, which shows the certificate request itself.

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

**Step 5.** Drop `-enable_pha` under TLS 1.3 and read the failure:

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

**Step 6.** Restrict the CA list advertised in the `CertificateRequest` without changing who is trusted:

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

### Check your understanding

**Q25.** Distinguish `SSLCACertificateFile` from `SSLCADNRequestFile`. If you configure only the second one, what happens to verification?

**Q26.** Explain precisely why step 5 failed under TLS 1.3 while the identical configuration works under TLS 1.2, and name the TLS 1.2 mechanism Apache used there that no longer exists.

**Q27.** `SSLVerifyClient optional` and nginx's `optional_no_ca` sound similar. Describe the security difference and the one legitimate use case for `optional_no_ca`.

**Q28.** `SSLOptions +StdEnvVars` has a measurable cost. What is it, and where would you scope the directive to avoid paying it site-wide?

**Q29.** With `SSLVerifyDepth 2` and the chain in this lab, does a certificate issued directly by the root CA still authenticate? What about one issued by a second-level sub-CA under the issuing CA?

---

## Exercise 8 — OCSP stapling

**Step 1.** Run a responder backed by the CA database you built in Exercise 0.

```bash
cd ~/lab331
openssl ocsp -port 2560 -index ca/index.txt -CA ca/ca-chain.crt \
  -rkey ocsp/signer.key -rsigner ocsp/signer.crt -nrequest 1000 -text &
```

**Step 2.** Query it directly, as a client would if there were no stapling.

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

**Step 3.** Notice where the URL came from — the certificate told you.

```bash
openssl x509 -in srv/www.crt -noout -ext authorityInfoAccess
```

```
X509v3 Authority Information Access:
    OCSP - URI:http://ocsp.example.test:2560
```

**Step 4.** Turn on stapling in Apache. `SSLStaplingCache` is already in the global scope from Exercise 4 — the per-vhost part is small:

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

**Step 5.** Revoke the certificate and watch the staple change meaning.

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

**Step 6.** Generate the CRL that carries the same fact, and check it offline.

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

**Step 7.** Restore a working state: reinstate the certificate by reissuing it, or simply mark the lab as understood and roll `index.txt` back from `ca/index.txt.old`.

**Step 8.** (Optional, read-only) Inspect the OCSP Must-Staple extension in a certificate that has it:

```bash
openssl x509 -in srv/www.crt -noout -ext tlsfeature
```

```
No extensions in certificate
```

To issue one, add `tlsfeature = status_request` to the extension file — but only if you are certain the server will always staple.

### Check your understanding

**Q30.** In step 2 `Response verify OK` appeared. Which key signed that response, and what two properties of the signer certificate authorised it to answer *on behalf of* the issuing CA?

**Q31.** State three benefits stapling delivers versus letting the client fetch OCSP itself, and the one problem it does **not** solve without Must-Staple.

**Q32.** `SSLStaplingCache` must live in the global server configuration. What is the observable symptom if you put it inside a `<VirtualHost>` instead, or omit it while `SSLUseStapling on` is set?

**Q33.** `SSLStaplingReturnResponderErrors` defaults to `on`. Explain what gets sent to clients in that mode when the responder is unreachable, and why `off` is the safer production value.

**Q34.** Why did step 5 need `systemctl restart` rather than `reload` to show the new status, and what is the corresponding real-world delay after an emergency revocation?

---

## Exercise 9 — The same six things in nginx

**Step 1.** Stop Apache so port 443 is free, and lay out a vhost that exercises HTTPS, SNI, HSTS, client auth and stapling in one file.

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

**Step 2.** Validate and start.

```bash
sudo nginx -t && sudo systemctl restart nginx
```

```
nginx: the configuration file /etc/nginx/nginx.conf syntax is ok
nginx: configuration file /etc/nginx/nginx.conf test is successful
```

**Step 3.** Check SNI, HSTS and client auth in one pass.

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

**Step 4.** Observe the stapling warm-up.

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

**Step 5.** Remove the network dependency entirely with a pre-fetched response — the right answer for air-gapped or high-availability deployments.

```bash
openssl ocsp -CAfile ca/ca-chain.crt -issuer ca/issuing.crt -cert srv/www.crt \
  -url http://ocsp.example.test:2560 -no_nonce -respout /tmp/www.ocsp.der
sudo install -m 644 /tmp/www.ocsp.der /etc/nginx/ssl/
# add to the server block:  ssl_stapling_file /etc/nginx/ssl/www.ocsp.der;
sudo nginx -t && sudo systemctl reload nginx
```

### Check your understanding

**Q35.** nginx has one `ssl_certificate` directive where Apache historically had two. What must the file contain, in what order, and what is the symptom of getting the order backwards?

**Q36.** Why did the first `-status` probe in step 4 return `no response sent by server`, and why does the same probe against Apache (Exercise 8) usually succeed on the first try?

**Q37.** `ssl_stapling on` without `resolver` produces a warning and no staple. Explain the dependency, and say why `ssl_stapling_file` removes it.

**Q38.** The `add_header` line is repeated inside `location /secure/`. Why is that repetition mandatory rather than redundant?

**Q39.** Apache can require a client certificate per-`<Location>`; nginx's `ssl_verify_client` is per-`server`, hence the `if ($ssl_client_verify != SUCCESS)` idiom. What is the privacy/UX cost of nginx's approach, and what does `$ssl_client_verify` contain when a certificate was sent but rejected?

**Q40.** `ssl_ciphers` has no effect on TLS 1.3 in nginx. Which directive covers it, and from which nginx version?

---

## Exercise 10 — Diagnostic drills

Each drill is a symptom. Run the command, read the evidence, name the cause, apply the fix. Do them in order; each one leaves the system clean for the next.

**Drill A — "It works in curl on the server but the browser says untrusted."**

```bash
openssl s_client -connect www.example.test:443 -servername www.example.test \
  -showcerts </dev/null 2>/dev/null | grep -cE '^-----BEGIN CERTIFICATE'
```

```
1
```

**Drill B — "Certificate and key don't match" after a renewal.**

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

**Drill C — "The site went down at 02:00 and nobody deployed."**

```bash
openssl x509 -in srv/www.crt -noout -checkend 0        && echo "valid now"
openssl x509 -in srv/www.crt -noout -checkend 2592000  || echo "expires within 30 days"
echo | openssl s_client -connect www.example.test:443 -servername www.example.test 2>/dev/null \
  | openssl x509 -noout -dates
```

**Drill D — "Only mobile clients fail."**

```bash
openssl s_client -connect www.example.test:443 -servername www.example.test \
  -tls1_2 -brief </dev/null 2>&1 | head -3
sudo grep -R 'SSLProtocol\|ssl_protocols' /etc/apache2 /etc/nginx 2>/dev/null
```

**Drill E — "Stapling stopped working after we moved networks."**

```bash
openssl s_client -connect www.example.test:443 -servername www.example.test \
  -status </dev/null 2>/dev/null | grep -m1 'OCSP response'
openssl x509 -in srv/www.crt -noout -ext authorityInfoAccess
curl -sS -o /dev/null -w '%{http_code}\n' http://ocsp.example.test:2560/
sudo journalctl -u apache2 --since '10 min ago' | grep -i stapl
```

**Drill F — "One vhost serves the wrong certificate to some clients."**

```bash
openssl s_client -connect 127.0.0.1:443 -noservername </dev/null 2>/dev/null \
  | openssl x509 -noout -subject
sudo apachectl -S 2>&1 | sed -n '/VirtualHost configuration/,/^$/p'
```

**Drill G — "Client certificates are refused with no useful log line."**

```bash
openssl verify -CAfile ca/root.crt -untrusted ca/issuing.crt cli/alice.crt
openssl x509 -in cli/alice.crt -noout -ext extendedKeyUsage,keyUsage
openssl s_client -connect www.example.test:443 -servername www.example.test \
  -CAfile ca/root.crt </dev/null 2>/dev/null | grep -A5 'Acceptable client'
```

### Check your understanding

**Q41.** Drill A returned `1`. Name the defect, the fix, and explain why `curl` on the server itself did not reproduce it.

**Q42.** In Drill B, why is the `-pubkey`/`-pubout` comparison strictly better practice than the `-modulus` one, and what does a *mismatch* on the modulus check but a *match* on the pubkey check imply (trick question — answer carefully)?

**Q43.** For Drill E, list the three distinct causes of `no response sent by server` and give the one command that discriminates between them.

**Q44.** In Drill G, `openssl verify` succeeds and the EKU is `clientAuth`, yet the handshake still fails. Give two remaining causes that neither command in the drill would reveal.

---

## Reference sources

- LPI — Exam 303 Objectives (v3.0.0): <https://www.lpi.org/our-certifications/exam-303-objectives/>
- Apache HTTP Server 2.4 — `mod_ssl` directive reference: <https://httpd.apache.org/docs/2.4/mod/mod_ssl.html>
- Apache HTTP Server 2.4 — SSL/TLS How-To and FAQ: <https://httpd.apache.org/docs/2.4/ssl/>
- nginx — `ngx_http_ssl_module`: <https://nginx.org/en/docs/http/ngx_http_ssl_module.html>
- nginx — Configuring HTTPS servers: <https://nginx.org/en/docs/http/configuring_https_servers.html>
- OpenSSL 3.x manuals — `s_client`, `s_server`, `ca`, `ocsp`, `verify`, `x509`, `pkcs12`, `req`, `crl`: <https://docs.openssl.org/master/man1/>
- OpenSSL verification error codes: <https://docs.openssl.org/master/man1/openssl-verification-options/>
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
- Mozilla — Server Side TLS configuration guidance: <https://wiki.mozilla.org/Security/Server_Side_TLS>
- HSTS preload list requirements: <https://hstspreload.org/>

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 0

**A1.** `index.txt` is a tab-separated CA database, one line per issued certificate. Column 1 is the status flag: `V` valid, `R` revoked, `E` expired. Column 2 is the notAfter date in `YYMMDDHHMMSSZ` form; when the status is `R`, column 3 holds the revocation date optionally followed by `,<reason>`. Column 4 is the **serial number in hex**, column 5 the filename (or `unknown`), column 6 the subject DN. `openssl ocsp -index` answers a query by matching the serial number from the request against column 4 and reporting column 1 — which is why a responder is only as correct as the file the CA writes at signing and revocation time. Note also that `openssl ca` keeps `index.txt.attr`; if `unique_subject = yes` there, re-issuing for the same DN fails.

**A2.** Nothing fails at Apache startup — `mod_ssl` loads the certificate and serves it. The failure is client-side: a conforming TLS client checks that the server certificate's extendedKeyUsage contains `id-kp-serverAuth` (1.3.6.1.5.5.7.3.1). With only `clientAuth` present, the client rejects it with an `unsupported certificate` / `certificate unknown` alert, and `openssl verify -purpose sslserver` reports `unsupported certificate purpose`. EKU is an *additive restriction*: absent extension means unrestricted; present extension means only the listed purposes.

**A3.** `noCheck` (id-pkix-ocsp-nocheck, RFC 6960 §4.2.2.2.1) tells clients not to check the revocation status of the OCSP responder's own certificate. Without it, a client validating an OCSP response must validate the signer's certificate, which requires checking *its* revocation status, which requires an OCSP query, whose response is signed by that same certificate — infinite recursion. The trade-off is that the responder certificate cannot be meaningfully revoked, so it is issued short-lived.

### Exercise 1

**A4.** `s:` is the Subject DN of the certificate at that position, `i:` the Issuer DN. Position 0 is the leaf; each subsequent entry should be the issuer of the one before it. The root appears here only because `s_server` was handed a file that happens to contain it — a correctly configured public server sends leaf + intermediates and **omits** the root, because the root must already be in the client's trust store to be trusted at all; sending it wastes handshake bytes and proves nothing.

**A5.**
- **20 — unable to get local issuer certificate**: the chain the server sent ends at a certificate whose issuer is not in the client's trust store *and* was not supplied. Most often a **missing intermediate on the server** (the leaf's issuer is nowhere to be found), sometimes a genuinely unknown root.
- **21 — unable to verify the first certificate**: the leaf's signature could not be verified because no issuer was available for it specifically — in practice the same server-side symptom, reported when the chain has length 1.
- **19 — self-signed certificate in certificate chain**: a chain was built all the way to a self-signed root, but that root is **not trusted by the client** — i.e. the anchor is missing client-side, typically a private CA not installed.

Rule of thumb: 20/21 → fix the server's `ssl_certificate` / `SSLCertificateFile` bundle. 19/18 → install the CA in the client trust store.

**A6.** OpenSSL verified **chain validity**: signatures up the chain, validity dates, basicConstraints/pathlen, key usages, and that a trusted anchor was reached. It did **not** verify **identity** — that the name the client intended to reach appears in the certificate's `subjectAltName`. In library terms, `X509_VERIFY_PARAM_set1_host()` was never called. `s_client` deliberately leaves this off unless you pass `-verify_hostname`, `-verify_ip` or `-verify_email`. This is misread constantly because browsers and `curl` do both checks and report one verdict; `s_client` reports only the first. Any monitoring script that greps for `Verify return code: 0 (ok)` and nothing else will happily approve a certificate for the wrong domain.

**A7.** Renegotiation does not exist in TLS 1.3 — it was removed and replaced by key update and post-handshake authentication — so the field reports `IS NOT supported` and that is correct and safe. Under TLS 1.2 the same server reports `IS supported`, meaning it implements the RFC 5746 `renegotiation_info` extension. RFC 5746 exists because of the 2009 TLS renegotiation prefix-injection flaw (CVE-2009-3555): an attacker could complete a handshake of their own with the server, splice the victim's handshake on top as a renegotiation, and have their attacker-chosen plaintext prepended to the victim's authenticated request. `IS NOT supported` on a TLS 1.2 connection is a red flag; on TLS 1.3 it is meaningless.

### Exercise 2

**A8.** TLS 1.3 redefined the ciphersuite as a single AEAD+hash pair, decoupled from key exchange and authentication, and it uses a **separate namespace and separate configuration list** in OpenSSL. `-cipher` populates the TLS ≤1.2 list only; `-ciphersuites` populates the TLS 1.3 list. Correspondence:
- Apache: `SSLCipherSuite <suites>` (legacy) versus `SSLCipherSuite TLSv1.3 <suites>` (the version-prefixed form, httpd 2.4.36+ with OpenSSL 1.1.1+).
- nginx: `ssl_ciphers` (legacy only, no TLS 1.3 equivalent directive) versus `ssl_conf_command Ciphersuites ...` (nginx 1.19.4+).

**A9.** It proved the server supports a protocol version **higher** than the one the client just offered, and therefore concluded the client had been downgraded by something on the path — so it aborted with `inappropriate_fallback` (alert 86, RFC 7507). It is historical because TLS 1.3 embeds downgrade protection in the ServerHello itself: a TLS 1.3-capable server negotiating 1.2 or lower writes a fixed sentinel (`DOWNGRD\x01`/`\x00`) into the last 8 bytes of `server_random`, which a TLS 1.3-capable client checks and rejects. Downgrade defence moved from an opt-in client hack into the protocol.

**A10.** `SSLProtocol -all +TLSv1.2 +TLSv1.3`. It is safer because it is **default-deny**: `-all` clears everything, then you enumerate exactly what is permitted. The subtractive form is default-allow — when the library later gains TLS 1.4, or when a distro backports an old protocol, the subtractive list silently permits it because you never listed it as excluded. The same principle applies to `ssl_protocols` in nginx, which is enumerative by design.

### Exercise 3

**A11.** (i) **Chain/path validation** — cryptographic signatures up to a trusted anchor, plus dates, basicConstraints, pathlen, keyUsage, and revocation status. (ii) **Identity/name binding** — the requested hostname matches a `subjectAltName` entry (RFC 6125; CN as a fallback is deprecated and ignored by modern browsers). Step 2 failed *chain validation* — the forged certificate chained to an untrusted anchor. Step 3 satisfied chain validation, and identity was satisfied all along because the attacker simply put the real name in the SAN. **Anyone can put any name in a certificate; the only thing that makes a name meaningful is who signed it.**

**A12.** Two mechanisms that still work:
1. **Certificate Transparency** — the forged certificate was never logged, so a CT-enforcing client (Chrome requires SCTs for publicly-trusted chains) or the domain owner's CT monitoring would notice. Note that CT enforcement is typically skipped for locally-installed anchors, which is exactly why corporate MITM proxies work.
2. **Public-key pinning at the application layer** (mobile apps, `curl --pinnedpubkey`, or DANE/TLSA with DNSSEC) — the app compares the presented SPKI hash to a compiled-in value, so a different key fails regardless of who signed it.

**HSTS is not one of them.** HSTS forces *HTTPS*, not *a particular certificate*. Against an attacker holding a chain the client trusts, HSTS changes nothing — it defends against stripping, not impersonation.

**A13.** `openssl version -d` prints the OPENSSLDIR (typically `/usr/lib/ssl` on Debian, `/etc/pki/tls` on RHEL), whose `certs/` subdirectory is the default `-CApath`; the default `-CAfile` is that directory's `cert.pem`. The environment overrides are `SSL_CERT_FILE` and `SSL_CERT_DIR`. Inspect the bundle with `openssl storeutl -noout -certs /etc/ssl/certs/ca-certificates.crt | grep -c Subject`, and remember that a `-CApath` directory is looked up by subject-name hash symlinks maintained by `openssl rehash` (`c_rehash`).

### Exercise 4

**A14.** TLS path building happens at the client, and the client can only build a path from (a) what the server sent and (b) what it already trusts. With only the leaf sent, a client whose store contains the root but not the intermediate cannot bridge the gap. Some clients succeed anyway for two reasons: they **cache intermediates** seen on previous connections (Firefox is famous for this, which is why "it works on my laptop" is worthless evidence), or they **fetch the issuer** from the leaf's `authorityInfoAccess` `caIssuers` URI (Windows/Schannel and macOS do this; OpenSSL does not). Always test with `openssl s_client` from a clean host — it does neither.

**A15.** `SSLCertificateFile`, since httpd 2.4.8, accepts the leaf followed by the intermediate chain in one PEM file. Order is significant: **leaf first**, then each issuer in ascending order, root optional and normally omitted. `SSLCertificateChainFile` still parses but is deprecated and cannot be combined cleanly with multiple certificate types (RSA + ECDSA dual-cert setups).

**A16.** `apachectl configtest` reports something like `AH02565: Certificate and private key www.example.test:443:0 from /etc/ssl/certs/www.crt and /etc/ssl/private/other.key do not match` and the server refuses to start. Without touching the service:

```bash
# RSA only
diff <(openssl x509 -noout -modulus -in cert.crt) <(openssl rsa -noout -modulus -in key.pem)
# any algorithm (RSA, EC, Ed25519)
diff <(openssl x509 -in cert.crt -noout -pubkey) <(openssl pkey -in key.pem -pubout)
```

Identical output means they pair. The second form is the one to memorise — `openssl rsa -modulus` simply errors out on an EC key, and modern deployments are increasingly ECDSA.

### Exercise 5

**A17.** The **first** vhost listed for that address:port — Apache's default vhost for the socket. It is what any client that omits SNI receives, and it is also the certificate used for the initial handshake before Apache can consult the Host header. On Debian the ordering follows the symlink names in `sites-enabled` (which is why `000-default` is named that way); `apachectl -S` prints the resolution explicitly and marks the default.

**A18.** It is wrong wherever real non-SNI clients must be served — legacy Java 6, Windows XP/IE, some embedded and IoT HTTP stacks, or an internal monitoring agent connecting by IP address. Those clients get a hard handshake failure instead of a certificate warning, which is harder to diagnose. It also protects against nothing security-relevant: it prevents the *confusing* case where the Host header and the certificate disagree, but an attacker gains nothing from omitting SNI. Treat it as a correctness/hygiene setting, not a control.

**A19.** **Encrypted Client Hello (ECH)**, the successor to ESNI. It encrypts the entire ClientHello inner — including SNI and ALPN — under a public key that the client obtains from the DNS `HTTPS`/`SVCB` resource record (`ech=` parameter) for the target name. So it requires DNS publication of the ECH config and, to be meaningful against an on-path attacker, DNSSEC or encrypted DNS transport (DoH/DoT); otherwise the attacker just reads or forges the DNS lookup. Support requires both endpoints; Apache and nginx support is still limited/patched at the time of writing.

**A20.** One IP address per TLS site — the certificate was chosen by the local socket address, since it must be selected before any application-layer data arrives. The modern equivalents are (i) **subjectAltName with multiple DNS entries** (a "SAN"/UCC certificate covering several names) and (ii) **wildcard certificates** (`DNS:*.example.test`, which matches exactly one label and not the bare domain). Both let a single certificate serve several names without SNI, at the cost of coupling their key material.

### Exercise 6

**A21.** `Header set` runs against the `onsuccess` header table and is skipped for many internally generated responses — 301/302 redirects, 401, 403, 404, 500 and anything produced before content handling. `Header always set` targets the `always` table, which applies to every response. Concretely: with plain `set`, `curl -I https://www.example.test/nope` (404) returns **no** `Strict-Transport-Security` header, so a user whose first HTTPS response is an error page never receives the policy. With `always`, step 3 shows it present on the 404.

**A22.** The **trust-on-first-use bootstrap gap**: the policy only exists in the browser after at least one successful HTTPS response from that host, so the very first visit — or the first after the `max-age` lapses, or from a fresh profile — is strippable. It is closed by the **HSTS preload list**: a set of hostnames compiled into browser binaries so the policy is enforced before any connection is made.

**A23.** (i) a valid certificate; (ii) redirect all HTTP to HTTPS on the same host, and serve the header over HTTPS with `max-age` of **at least 31536000** (one year); (iii) the directives `includeSubDomains` and `preload` both present. The risk: because the list ships inside browser binaries, removal takes months to propagate through release channels. `includeSubDomains` covers every subdomain including ones you forgot — an internal `legacy.example.test` on plain HTTP, a partner-run `cdn.example.test`, a device management box — and they all become unreachable, with no override the user can click. Preload after you have audited every subdomain, not before.

**A24.** It covers `www.example.test` and everything **under** it (`a.www.example.test`), but **not** `example.test` and **not** `intranet.example.test`, because those are not subdomains of `www.example.test` — the policy is stored against the host that sent it. To cover the whole zone, serve the header from `example.test` itself (typically on the apex redirect vhost, which must therefore be HTTPS).

### Exercise 7

**A25.** `SSLCACertificateFile` (and `SSLCACertificatePath`) define the CAs Apache will **actually trust** when validating a presented client certificate. `SSLCADNRequestFile`/`SSLCADNRequestPath` define only the list of CA distinguished names advertised in the TLS `CertificateRequest` message, which browsers use to filter which of the user's certificates to offer. If you set only `SSLCADNRequestFile`, verification has no trust anchors: every client certificate fails with `unable to get local issuer certificate` even though the browser offered exactly the right one. The two exist separately because large deployments trust hundreds of CAs but must not blow up the handshake — the DN list is sent in the clear and can run to kilobytes, and it also leaks your trust relationships to every connecting client.

**A26.** Under TLS 1.2, a per-directory `SSLVerifyClient` was implemented by **renegotiation**: Apache read the request, saw the `<Location>` matched, and triggered a second handshake in which it asked for a certificate. TLS 1.3 removed renegotiation entirely. Its replacement is **post-handshake authentication (PHA)**, which the client must opt into by sending the `post_handshake_auth` extension **in its initial ClientHello** — the server cannot request it retroactively. `openssl s_client` sends that extension only with `-enable_pha`, so without the flag Apache logs `AH10130: Client did not enable post-handshake authentication` and returns 403. Browsers generally do not implement PHA, which is why per-`<Location>` client auth is fragile in the TLS 1.3 era; the robust pattern is to require the certificate at the vhost level (a separate `ServerName` for the protected app) rather than per-directory.

**A27.** `SSLVerifyClient optional` (Apache) and nginx `ssl_verify_client optional` both **request** a certificate and, if one is presented, **validate it fully** against the configured CAs — an invalid one fails the handshake or sets `$ssl_client_verify` to `FAILED:<reason>`. nginx's `optional_no_ca` requests a certificate and performs **no validation at all**: signature, expiry, issuer, revocation, none of it. Anything self-signed is accepted and exported to the application. Its legitimate use is delegating validation to an upstream that has the real trust logic — for example, an application or an authorisation service that receives `$ssl_client_escaped_cert`, checks it against a device registry or a DID/proof-of-possession scheme, and where nginx is deliberately not the policy decision point. Treat `optional_no_ca` as "capture, don't authenticate".

**A28.** `+StdEnvVars` makes Apache populate roughly two dozen `SSL_*` environment variables (protocol, cipher, both DNs, validity, serial…) for **every** request, including static files. That is per-request string formatting and memory the vast majority of responses never read. The documented practice is to scope it to the handlers that need it:

```apache
<FilesMatch "\.(cgi|shtml|phtml|php)$">
    SSLOptions +StdEnvVars
</FilesMatch>
<Directory /usr/lib/cgi-bin>
    SSLOptions +StdEnvVars
</Directory>
```

`+ExportCertData` is heavier still — it exports the full PEM of the client and server certificates (`SSL_CLIENT_CERT`, `SSL_SERVER_CERT`) — so scope it to the single location that parses them.

**A29.** Depth counts the number of **intermediate** CAs between the client certificate and a trusted anchor, so `SSLVerifyDepth 2` permits: depth 0, a certificate that *is* a trusted CA; depth 1, one issued directly by a trusted CA; depth 2, one issued by an intermediate under a trusted CA. So yes — a certificate issued directly by the root validates comfortably (depth 1), and a certificate under a second-level sub-CA (root → issuing → sub → leaf) is depth 3 and is **rejected** with `certificate chain too long`. The default is 1, which is the classic cause of "our new sub-CA's certificates stopped working" after a PKI reorganisation.

### Exercise 8

**A30.** The response was signed by `ocsp/signer.key`, whose certificate is a **delegated OCSP responder** certificate. Two properties authorised it: (i) it was **issued by the same CA** whose certificates it reports on (RFC 6960 requires the responder to be the issuing CA itself, a delegated signer issued by that CA, or a trusted responder configured out of band), and (ii) it carries `extendedKeyUsage = OCSPSigning` (id-kp-OCSPSigning, 1.3.6.1.5.5.7.3.9), marked critical here. `noCheck` is present so clients do not recurse. If either property were missing, `openssl ocsp` would print `Response Verify Failure` with `unsupported certificate purpose` or `unable to get local issuer certificate` — and clients would ignore the staple.

**A31.** Benefits of stapling:
1. **Privacy** — the client never contacts the CA, so the CA does not learn which site each IP address visits.
2. **Latency and reliability** — no extra DNS lookup plus HTTP round trip to a third party on the critical path of the handshake; the staple arrives inside the handshake it belongs to.
3. **Availability decoupling** — an overloaded or unreachable CA responder no longer degrades or breaks your site's connections, and the response is fetched once per server rather than once per client.

What it does **not** solve: an attacker who has stolen the key and is impersonating the server simply **does not staple**. Since clients soft-fail on a missing status, the revocation is invisible. Only the **Must-Staple** TLS Feature extension (RFC 7633) baked into the certificate closes it, by making a missing staple a fatal error — at the price that any stapling outage takes the site down hard.

**A32.** `SSLStaplingCache` is a **global** directive: placing it inside `<VirtualHost>` is a syntax error and `apachectl configtest` fails with `SSLStaplingCache not allowed here`. Omitting it while `SSLUseStapling on` is set makes startup fail with a message stating that stapling requires a configured cache. A related and nastier failure is silent: if Apache cannot find the **issuer** certificate for a leaf (because you loaded the leaf alone instead of the fullchain), it logs `AH02217: ssl_stapling_init_cert: Can't retrieve issuer certificate!` at error level, **starts anyway**, and simply never staples for that certificate. Stapling therefore depends on the same complete chain that clients need.

**A33.** With `SSLStaplingReturnResponderErrors on` (the default), Apache forwards responder failures — `tryLater`, `unauthorized`, malformed responses — to clients inside the TLS extension. Clients generally ignore them, but a client enforcing Must-Staple may treat an error status as a hard failure, and you have converted "CA responder is having a bad day" into "our site is down". Setting it `off` makes Apache send **no** status extension when it has no good response, which clients soft-fail on. `off` is the production value; combine it with `SSLStaplingFakeTryLater off` and monitoring of the stapling error log, so the outage is visible to you rather than to users.

**A34.** `reload` (graceful) keeps the existing `shmcb` stapling cache, and the cached `good` response was still inside its `SSLStaplingStandardCacheTimeout` window, so Apache kept serving it. `restart` discards the shared memory segment. In production the same effect appears as revocation latency stacked from three sources: the server's staple cache (`SSLStaplingStandardCacheTimeout`, default 3600 s), the OCSP response's own `nextUpdate` (hours to days at public CAs), and the client's cached response. A revocation is therefore not effective on the wire for hours — which is precisely why key rotation and short-lived certificates have displaced revocation as the primary compromise response.

### Exercise 9

**A35.** One PEM file containing the **leaf first**, then intermediates in issuing order, root omitted. If the order is reversed, nginx uses the first certificate in the file as the server certificate and fails at startup with `SSL_CTX_use_PrivateKey_file(... ) failed (SSL: error:...:key values mismatch)`, because the private key pairs with the leaf, not with the intermediate. If a bogus certificate is *appended* rather than prepended, nginx starts fine and clients see a broken chain — the failure mode is silent and only `s_client -showcerts` reveals it.

**A36.** nginx fetches the OCSP response **lazily**: it starts the fetch when the first client requests a status, and answers that first handshake without one. Apache's `mod_ssl` primes the staple at certificate-load time and keeps it in `SSLStaplingCache`, so a freshly reloaded server usually staples on the first connection. This is why nginx stapling monitoring must always probe twice, and why `ssl_stapling_file` is preferred where determinism matters.

**A37.** nginx must resolve the hostname in the certificate's `authorityInfoAccess` OCSP URI, and it does so with its own internal resolver rather than the system stub — `/etc/resolv.conf` is not consulted for this. Without `resolver` it logs `no resolver defined to resolve ocsp.example.test` and stapling never activates. `ssl_stapling_file` removes the dependency because the DER-encoded response is read from disk; nginx makes no network request at all. The cost is that you must refresh that file before its `nextUpdate` — a cron/systemd timer running `openssl ocsp -respout` plus `nginx -s reload`.

**A38.** In nginx, `add_header` directives are inherited from the enclosing level **only if the current level defines none of its own**. The moment `location /secure/` contains a single `add_header`, every inherited `add_header` from the `server` block is discarded for that location. Omitting the repetition would silently drop the HSTS header — and any CSP, `X-Frame-Options`, etc. — from exactly the pages that matter most. The same replace-not-merge rule applies to `add_header` inside `if` blocks, which is why security headers are usually centralised in an `include` snippet repeated at each level.

**A39.** Cost: because `ssl_verify_client optional` (or `on`) must be decided during the handshake, nginx sends a `CertificateRequest` on **every** connection to that server block, including anonymous visits to the public part of the site. Browsers then show a certificate-selection dialog to users who did not need to authenticate, and the acceptable-CA list is disclosed to everyone. The usual mitigation is a separate `server` block on a distinct `server_name` (or port) for the authenticated app. `$ssl_client_verify` holds `SUCCESS`, `NONE` (no certificate sent), or `FAILED:<reason>` where the reason is the OpenSSL verification text, e.g. `FAILED:certificate has expired`, `FAILED:unable to get local issuer certificate` — with `ssl_verify_client optional` the connection survives so your `if` can return 403 with a useful log line, which is why `optional` + explicit check is often better operationally than `on`.

**A40.** `ssl_conf_command Ciphersuites TLS_AES_256_GCM_SHA384:...`, available since **nginx 1.19.4** (it exposes OpenSSL's `SSL_CONF_cmd` interface and requires OpenSSL 1.0.2+; the `Ciphersuites` command itself needs OpenSSL 1.1.1+). `ssl_ciphers` maps to the TLS ≤1.2 list only, and the two do not interact.

### Exercise 10

**A41.** The server is sending a single certificate — the leaf without its intermediate. Fix: point `SSLCertificateFile`/`ssl_certificate` at the fullchain file (leaf + intermediate) and reload. `curl` on the server did not reproduce it because the local trust store, populated during the lab, already contained the intermediate as a `-CAfile`/anchor; local `curl` could complete the path from material the remote client does not have. The general lesson: **never validate a chain from a host that participates in the PKI.**

**A42.** The `-pubkey`/`-pubout` comparison hashes the full DER SubjectPublicKeyInfo, so it works identically for RSA, ECDSA and Ed25519 and captures the algorithm and parameters, not just one integer. The `-modulus` form is RSA-only (`openssl rsa` errors with `Expecting: ANY PRIVATE KEY` on an EC key, which reads like a corrupt file and sends people down the wrong path) and compares only *n*, ignoring the public exponent. The trick: **a modulus mismatch with a pubkey match cannot happen** for a genuine pair — if you observe it you have compared the wrong files, or run `openssl rsa` against a key of a different algorithm and hashed an error message. Two identical hashes of empty or error output also "match"; always confirm the hash is not the SHA-256 of the empty string (`e3b0c442...`).

**A43.** Three causes:
1. **The server has not fetched a response yet** — nginx's lazy first fetch, or Apache just after a restart. Discriminator: retry a few seconds later.
2. **The server cannot reach or authorise the responder** — responder down, no `resolver` in nginx, egress firewall, or the certificate has no `authorityInfoAccess` OCSP URI at all. Discriminator: `openssl x509 -noout -ext authorityInfoAccess` for presence, then query the URL by hand.
3. **The server cannot build the request** — the issuer certificate is not loaded, so Apache logs `AH02217: Can't retrieve issuer certificate!` and disables stapling for that certificate.

The single most discriminating command is the manual query, because it exercises URL, reachability, issuer and signer authorisation at once:

```bash
openssl ocsp -issuer ca/issuing.crt -cert srv/www.crt -CAfile ca/ca-chain.crt \
  -url "$(openssl x509 -in srv/www.crt -noout -ocsp_uri)" -resp_text
```

If that succeeds and the server still does not staple, the fault is in the server's configuration (missing chain or cache), not in the PKI.

**A44.** Two causes neither command surfaces:
1. **Depth**. `SSLVerifyDepth` / `ssl_verify_depth` is too low for the chain, or the client sent only its leaf while the server has no copy of the intermediate in `SSLCACertificateFile`. `openssl verify` succeeded only because you supplied `-untrusted ca/issuing.crt` on the command line — the server was never given that certificate.
2. **The client never offered the certificate.** Under TLS 1.3 without PHA (Q26), or because the `CertificateRequest`'s acceptable-CA list did not include the certificate's issuer, so the browser filtered it out and sent an empty Certificate message. `openssl s_client -state -msg` showing an empty client Certificate confirms it.

Two further candidates worth checking: **revocation** — the client certificate is listed in a CRL loaded via `SSLCARevocationFile` with `SSLCARevocationCheck chain`, which fails the handshake with `certificate revoked` — and **validity dates**, since `openssl verify` uses the current clock while a server with a skewed clock does not.

</details>