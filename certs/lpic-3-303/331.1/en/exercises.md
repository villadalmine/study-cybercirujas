# Guided Exercises — Topic 331.1: X.509 Certificates and Public Key Infrastructures

**Certification:** LPIC-3 303 Security (exam 303-300, version 3.0.0) · **Objective weight:** 8.34

---

## 0. Lab environment and ground rules

Everything below runs on a single Linux host. Nothing touches a public CA until Exercise 9, and that exercise uses a staging endpoint.

**Required packages**

| Distribution | Command |
|---|---|
| Debian/Ubuntu | `apt install openssl ca-certificates nginx certbot` |
| RHEL/Rocky/Alma | `dnf install openssl ca-certificates nginx certbot` |
| openSUSE | `zypper install openssl ca-certificates nginx certbot` |

**Version floor:** OpenSSL 3.0 or newer. Several flags used here (`-addext`, `-CRLfile`, `-provider`, `-noenc`) behave differently on 1.1.1 or 1.0.2; the exercises note the differences where they matter.

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

`OPENSSLDIR` is where OpenSSL looks for `openssl.cnf` and for the default `certs/` trust directory when you do not pass `-CAfile`/`-CApath`. On Debian that is `/usr/lib/ssl` (symlinked into `/etc/ssl`); on RHEL it is `/etc/pki/tls`. Memorise this: half of all "it works with `curl` but not with my program" incidents are a wrong `OPENSSLDIR` assumption.

> **Safety rule for the whole lab:** every private key you generate here is a lab key. Never reuse a lab key on a production host, and never commit `private/` to version control.

---

## Exercise 1 — Key material: generation, inspection, and format conversion

X.509 is a container for a **public key** plus a **signed set of assertions** about who owns it. Before touching certificates, you must be fluent in the key layer underneath.

### Steps

1. Create the lab tree and lock down the private directory.

   ```bash
   sudo install -d -m 0755 /opt/pki
   sudo chown "$USER" /opt/pki
   mkdir -p /opt/pki/scratch/private
   chmod 0700 /opt/pki/scratch/private
   cd /opt/pki/scratch
   ```

2. Generate an unencrypted RSA-3072 private key using the modern generic front-end.

   ```bash
   openssl genpkey -algorithm RSA \
     -pkeyopt rsa_keygen_bits:3072 \
     -pkeyopt rsa_keygen_pubexp:65537 \
     -out private/rsa3072.key.pem
   chmod 0600 private/rsa3072.key.pem
   ```

3. Inspect the header. Note what kind of PEM label OpenSSL 3 writes.

   ```bash
   head -1 private/rsa3072.key.pem
   ```

   ```
   -----BEGIN PRIVATE KEY-----
   ```

4. Generate an encrypted EC key on the NIST P-256 curve, and a second one on P-384.

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

5. Dump the structure of both keys. For the encrypted one you must supply the passphrase.

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

6. Extract the public keys. This is the only part of a key pair that ever leaves the host.

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

7. Convert PEM to DER and back, then prove the round-trip is byte-identical.

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

8. Look at the raw ASN.1 of the DER encoding. This is the ground truth that PEM merely base64-wraps.

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

9. Change the passphrase on the EC key, and then strip it entirely (what you must **never** do to a production key on a shared box).

   ```bash
   openssl pkey -in private/ec256.key.pem -passin pass:LabPass331 \
     -aes-256-cbc -passout pass:NewLabPass331 -out private/ec256.newpass.key.pem
   openssl pkey -in private/ec256.key.pem -passin pass:LabPass331 \
     -out private/ec256.plain.key.pem
   chmod 0600 private/ec256.*.pem
   ```

10. Compare traditional (PKCS#1 / SEC1) output with PKCS#8. Legacy tooling frequently demands the former.

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

### Check your understanding — Block 1

- **Q1.1** `-----BEGIN PRIVATE KEY-----`, `-----BEGIN RSA PRIVATE KEY-----` and `-----BEGIN ENCRYPTED PRIVATE KEY-----` are three different PEM labels. What ASN.1 structure sits behind each, and which one can hold an EC, RSA or Ed25519 key without changing the label?
- **Q1.2** A colleague states that PEM and DER are "two different certificate formats". Correct the statement precisely.
- **Q1.3** Why does `openssl pkey -pubout` on a private key succeed instantly, while deriving a private key from a public key is impossible?
- **Q1.4** You set `ec_param_enc:named_curve`. What is the alternative, and why does the alternative break interoperability with most TLS stacks?
- **Q1.5** An RSA-3072 key and an EC P-256 key are often described as offering "comparable" security. Which one is comparable to P-256, and what is the operational cost difference at TLS handshake time?

---

## Exercise 2 — Reading a real certificate down to the ASN.1

### Steps

1. Fetch a live certificate chain from a public site and save it.

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

2. Split the chain into individual files.

   ```bash
   csplit -z -f lpi-cert- -b '%02d.pem' lpi-chain.pem '/BEGIN CERTIFICATE/' '{*}'
   ls lpi-cert-*
   ```

   ```
   lpi-cert-00.pem  lpi-cert-01.pem
   ```

3. Print the human-readable form of the leaf, suppressing the noisy hex dumps.

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

4. Extract single fields — this is what you script in monitoring checks.

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

5. Ask the expiry question the way a Nagios/Prometheus check does.

   ```bash
   openssl x509 -in lpi-cert-00.pem -noout -checkend $((30*24*3600)) \
     && echo "OK: valid for at least 30 more days" \
     || echo "WARN: expires within 30 days"
   ```

6. Read the certificate as pure ASN.1 and locate the TBSCertificate — the region that is actually hashed and signed.

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

7. Compute the SPKI pin (SHA-256 of the DER-encoded `SubjectPublicKeyInfo`), the value used by HPKP-style and mobile-app pinning.

   ```bash
   openssl x509 -in lpi-cert-00.pem -noout -pubkey \
     | openssl pkey -pubin -outform DER \
     | openssl dgst -sha256 -binary \
     | openssl enc -base64
   ```

   ```
   Ku1c+3vTz0S9Xg7yQ2fFq0mR8bWnJ4pO1lYc6hT2sVo=
   ```

8. Verify that a private key and a certificate actually belong together — the single most useful five-second check in TLS troubleshooting.

   ```bash
   # Algorithm-agnostic (works for RSA, EC, Ed25519):
   openssl x509 -in lpi-cert-00.pem -noout -pubkey | openssl sha256
   # Compare against, on your own server:
   #   openssl pkey -in /etc/ssl/private/server.key -pubout | openssl sha256
   ```

### Check your understanding — Block 2

- **Q2.1** In the ASN.1 dump, the outer `SEQUENCE` at offset 0 has three children. Name them, and state which bytes the CA's signature is computed over.
- **Q2.2** The certificate carries both `Subject: CN = www.lpi.org` and a `subjectAltName` with `DNS:www.lpi.org`. Which of the two does a modern TLS client use for hostname matching, and what does RFC 6125 / the CA/Browser Forum say about the other?
- **Q2.3** `X509v3 Basic Constraints: critical / CA:FALSE`. What is a "critical" extension, and what must a conforming client do if it encounters a critical extension it does not recognise?
- **Q2.4** The Authority Information Access extension lists both `OCSP` and `CA Issuers` URIs. What is each one used for, and which one can rescue a server that has been misconfigured to send an incomplete chain?
- **Q2.5** Why is the SPKI pin in step 7 more durable than a pin of the certificate fingerprint?

---

## Exercise 3 — Build a Root CA with `openssl ca`

You now become the CA. The point of this exercise is the *state* a CA keeps, not just the commands.

### Steps

1. Create the root CA directory structure and its state files.

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

2. Write the root CA configuration. Save as `/opt/pki/root-ca/openssl-root.cnf`.

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

3. Generate the root private key. It is encrypted; in production this key lives offline or in an HSM.

   ```bash
   openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 \
     -aes-256-cbc -pass pass:RootLabPass331 \
     -out private/root-ca.key.pem
   chmod 0400 private/root-ca.key.pem
   ```

4. Self-sign the root certificate. Note that `req -x509` produces a certificate without touching `index.txt` — the root's own certificate is not "issued" by the CA database.

   ```bash
   openssl req -config openssl-root.cnf \
     -key private/root-ca.key.pem -passin pass:RootLabPass331 \
     -new -x509 -days 7300 -sha256 -extensions v3_root_ca \
     -out certs/root-ca.cert.pem
   chmod 0444 certs/root-ca.cert.pem
   ```

5. Verify the result and confirm it is self-signed.

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

6. Confirm that Subject == Issuer and SKI == AKI programmatically.

   ```bash
   openssl x509 -in certs/root-ca.cert.pem -noout -subject -issuer \
     | awk -F'=' '{ $1=""; print }' | uniq -c
   ```

   ```
         2   C = AR, ST = Buenos Aires, ...
   ```

### Check your understanding — Block 3

- **Q3.1** The root certificate is self-signed. Explain, in terms of cryptography alone, why that signature proves nothing about trustworthiness — and where the trust actually comes from.
- **Q3.2** What are `index.txt`, `serial`, and `crlnumber` for? What breaks if you restore `index.txt` from a backup that is one day old?
- **Q3.3** `unique_subject = no` was set. What is the default, and give a concrete operational scenario in which the default causes an outage.
- **Q3.4** `policy_strict` sets `organizationName = match`. Match against *what*, exactly?
- **Q3.5** The root has `keyUsage = critical, digitalSignature, cRLSign, keyCertSign`. Which of those three is strictly required for it to sign subordinate certificates, and which for it to sign CRLs?

---

## Exercise 4 — Intermediate CA and the chain of trust

### Steps

1. Create the intermediate CA tree.

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

2. Write `/opt/pki/int-ca/openssl-int.cnf`.

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

3. Generate the intermediate key and its CSR.

   ```bash
   openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 \
     -aes-256-cbc -pass pass:IntLabPass331 \
     -out private/int-ca.key.pem
   chmod 0400 private/int-ca.key.pem

   openssl req -config openssl-int.cnf -new -sha256 \
     -key private/int-ca.key.pem -passin pass:IntLabPass331 \
     -out csr/int-ca.csr.pem
   ```

4. Inspect the CSR and — critically — verify its self-signature. A CSR is signed by the requesting key, which proves possession of the private key.

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

5. Sign the intermediate with the **root** CA, applying the `v3_intermediate_ca` extension block.

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

6. Look at what the CA database recorded.

   ```bash
   cat /opt/pki/root-ca/index.txt
   ```

   ```
   V	360816112203Z		1000	unknown	/C=AR/ST=Buenos Aires/O=Example Internal Ltd/OU=Platform Engineering/CN=Example Internal Issuing CA I1
   ```

   Columns: **status** (`V`alid / `R`evoked / `E`xpired) · expiry (`YYMMDDHHMMSSZ`) · revocation date[,reason] · serial · filename · subject DN.

7. Verify the intermediate against the root.

   ```bash
   openssl verify -CAfile /opt/pki/root-ca/certs/root-ca.cert.pem \
     /opt/pki/int-ca/certs/int-ca.cert.pem
   ```

   ```
   /opt/pki/int-ca/certs/int-ca.cert.pem: OK
   ```

8. Build the chain file that servers will present. **Order matters: leaf first, then each issuer upward. The root is normally omitted.**

   ```bash
   cat /opt/pki/int-ca/certs/int-ca.cert.pem \
       /opt/pki/root-ca/certs/root-ca.cert.pem \
       > /opt/pki/int-ca/certs/ca-chain.cert.pem
   chmod 0444 /opt/pki/int-ca/certs/ca-chain.cert.pem
   ```

### Check your understanding — Block 4

- **Q4.1** The intermediate has `pathlen:0`. Precisely what does that forbid, and does it count the intermediate itself?
- **Q4.2** The intermediate carries `nameConstraints` restricted to `.example.internal`. If this intermediate key were stolen, what could and could not the attacker do with it against a client that enforces name constraints?
- **Q4.3** `openssl req -x509` in Exercise 3 and `openssl ca` here both produced certificates. List three concrete behaviours `openssl ca` has that `req -x509` does not.
- **Q4.4** In step 4, `Certificate request self-signature verify OK` was printed. What property does that prove, and what does it *not* prove?
- **Q4.5** The config sets `copy_extensions = none`. Describe the attack that becomes possible with `copy_extensions = copy` if the CA operator does not review CSRs.

---

## Exercise 5 — Issue a server certificate with SANs, and verify it properly

### Steps

1. Generate the server key (EC P-256 — cheaper handshakes, smaller certificates).

   ```bash
   cd /opt/pki/int-ca
   openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 \
     -pkeyopt ec_param_enc:named_curve \
     -out private/web01.key.pem
   chmod 0400 private/web01.key.pem
   ```

2. Create the CSR with SANs embedded via `-addext` (OpenSSL ≥ 1.1.1).

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

3. Because the CA config uses `copy_extensions = none`, the SANs in the CSR are **discarded**. Supply them from a CA-controlled extension file instead — this is the correct production pattern.

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

   > `keyEncipherment` was dropped: an ECDSA key never encrypts a TLS pre-master secret. Including it is a common copy-paste error that some strict validators flag.

4. Sign it.

   ```bash
   mkdir -p ext
   openssl ca -config openssl-int.cnf \
     -extfile ext/web01.ext -days 90 -notext -md sha256 \
     -passin pass:IntLabPass331 \
     -in csr/web01.csr.pem -out certs/web01.cert.pem
   chmod 0444 certs/web01.cert.pem
   ```

5. Verify against the chain, showing the path that was built.

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

6. Now verify **purpose** and **hostname** — `openssl verify` does neither by default.

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

7. Deliberately break the chain to see the classic error codes.

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

8. Serve it and test end-to-end with `s_server` / `s_client`.

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

### Check your understanding — Block 5

- **Q5.1** `openssl verify certs/web01.cert.pem` returned `OK` in step 5 but the same certificate is rejected by a browser. Name two checks `openssl verify` skipped by default that the browser performs.
- **Q5.2** What is the difference between error 20 and error 2 in step 7, and which one corresponds to "the server forgot to send the intermediate"?
- **Q5.3** The SAN includes `IP:10.20.30.41`. Why do public CAs almost never issue this, and what changes when the certificate is for an internal PKI?
- **Q5.4** What does `-x509_strict` add, and give one example of a certificate that passes normal verification but fails under it.
- **Q5.5** In step 8, `-servername` was passed. What TLS extension does that populate, and what happens on a multi-tenant server if the client omits it?

---

## Exercise 6 — Revocation part 1: CRLs

### Steps

1. Issue a second server certificate that you will then revoke.

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

2. Generate a CRL **before** revoking anything, so you have a baseline.

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

3. Revoke `web02` with an explicit reason code.

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

4. Look at `index.txt` again — the status flag flipped.

   ```bash
   cat index.txt
   ```

   ```
   V	261116112203Z		2000	unknown	/C=AR/ST=Buenos Aires/O=Example Internal Ltd/CN=web01.example.internal
   R	261116114512Z	260818120730Z,keyCompromise	2001	unknown	/C=AR/O=Example Internal Ltd/CN=web02.example.internal
   ```

5. Regenerate the CRL and inspect it.

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

6. Verify with CRL checking enabled.

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

7. Now demand a CRL for **every** level of the chain and observe the failure — a very common surprise.

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

8. Fix it by producing the root's CRL as well and concatenating both.

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

9. Convert the CRL to DER — the form actually published at a `crlDistributionPoints` URI.

   ```bash
   openssl crl -in /opt/pki/int-ca/crl/int-ca.crl.pem \
     -outform DER -out /opt/pki/int-ca/crl/int-ca.crl
   ls -l /opt/pki/int-ca/crl/
   ```

### Check your understanding — Block 6

- **Q6.1** A CRL has `Last Update` and `Next Update`. What must a strict client do when it reaches a CRL whose `Next Update` is in the past, and what is the availability trade-off of that behaviour?
- **Q6.2** `-crl_check` versus `-crl_check_all`: which certificates in the chain does each one test?
- **Q6.3** Reason code `keyCompromise` versus `cessationOfOperation` versus `certificateHold`. Which one is reversible, and by what mechanism?
- **Q6.4** State the two structural scaling problems that make CRLs unattractive for a CA with ten million active certificates.
- **Q6.5** The CRL was published in DER, not PEM. Why does that matter for `crlDistributionPoints` interoperability?

---

## Exercise 7 — Revocation part 2: OCSP and OCSP stapling

### Steps

1. Create a dedicated OCSP responder certificate. It must carry `OCSPSigning` EKU and the `id-pkix-ocsp-nocheck` extension.

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

2. Start the responder in the foreground (Terminal A). It reads revocation status directly from `index.txt`.

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

3. Query the status of the **good** certificate (Terminal B).

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

4. Query the **revoked** certificate.

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

5. Query an unknown serial to see the third possible status.

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

6. Configure OCSP stapling in nginx. Add to the `server` block:

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

   The Apache httpd equivalent:

   ```apache
   SSLUseStapling            On
   SSLStaplingCache          "shmcb:/var/run/ocsp(128000)"
   SSLStaplingResponderTimeout 5
   SSLStaplingReturnResponderErrors Off
   ```

7. Confirm the staple is actually being sent.

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

   If stapling is off or the responder is unreachable you get instead:

   ```
   OCSP response: no response sent
   ```

### Check your understanding — Block 7

- **Q7.1** The responder certificate carries `id-pkix-ocsp-nocheck`. Explain why that extension exists — what infinite regress would occur without it?
- **Q7.2** The client was invoked with `-no_nonce`. What is the OCSP nonce for, what attack does it prevent, and why do most public responders refuse it?
- **Q7.3** Compare the privacy properties of CRL fetching versus live OCSP querying, from the end user's perspective.
- **Q7.4** OCSP stapling moves the query from the client to the server. Name the two problems it solves and the one it does *not* solve (hint: what if the server simply omits the staple?).
- **Q7.5** In nginx, `ssl_stapling_verify on` requires `ssl_trusted_certificate`. What exactly is nginx verifying with that file, and why is it not the same file as `ssl_certificate`?

---

## Exercise 8 — Formats, bundles, and system trust stores

### Steps

1. Bundle key + certificate + chain into a PKCS#12 container (what Java keystores, Windows, and many appliances consume).

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

2. Inspect the container without extracting anything sensitive to disk.

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

3. Extract the pieces back out.

   ```bash
   openssl pkcs12 -in certs/web01.p12 -passin pass:P12LabPass331 \
     -nocerts -noenc -out /tmp/web01.key.extracted.pem
   openssl pkcs12 -in certs/web01.p12 -passin pass:P12LabPass331 \
     -clcerts -nokeys -out /tmp/web01.cert.extracted.pem
   openssl pkcs12 -in certs/web01.p12 -passin pass:P12LabPass331 \
     -cacerts -nokeys -out /tmp/web01.chain.extracted.pem
   ```

   > On OpenSSL 3, `-noenc` replaced `-nodes` (the old name still works as an alias). If an old Java 8 or Windows XP-era consumer rejects the file, re-export with `-legacy -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1`; that requires the `legacy` provider to be loadable.

4. Convert the certificate between the four encodings you will meet in the wild.

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

5. Install the root CA into the **system** trust store.

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

6. Prove the trust took effect by verifying with **no** `-CAfile`.

   ```bash
   openssl verify -untrusted /opt/pki/int-ca/certs/int-ca.cert.pem \
     /opt/pki/int-ca/certs/web01.cert.pem
   ```

   ```
   /opt/pki/int-ca/certs/web01.cert.pem: OK
   ```

7. Build a hashed `CApath` directory — the alternative to a single concatenated `CAfile`.

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

8. Clean up the system trust store when you finish the lab.

   ```bash
   sudo rm -f /usr/local/share/ca-certificates/example-internal-root-ca.crt \
              /etc/pki/ca-trust/source/anchors/example-internal-root-ca.pem
   sudo update-ca-certificates --fresh 2>/dev/null || sudo update-ca-trust extract
   ```

### Check your understanding — Block 8

- **Q8.1** You placed a `.pem` file in `/usr/local/share/ca-certificates/` and `update-ca-certificates` ignored it. Why?
- **Q8.2** `-CAfile` versus `-CApath`: what is the lookup mechanism in each case, and what does `openssl rehash` compute the filename from?
- **Q8.3** `update-ca-trust` on RHEL writes several output bundles. Why does it produce more than one format, and which consumers need which?
- **Q8.4** A PKCS#12 file protects the private key with a passphrase and also carries a MAC. What is each of those two protections defending against?
- **Q8.5** A vendor appliance rejects your `.p12` with "unsupported algorithm". What changed in OpenSSL 3.0 that causes this, and what is the minimal fix?

---

## Exercise 9 — ACME and Let's Encrypt with certbot

**Do not run step 4 against the production Let's Encrypt endpoint during practice.** The rate limits are strict and the failure counter is per-domain.

### Steps

1. Inspect what certbot knows about this host.

   ```bash
   certbot certificates
   certbot --version
   ```

   ```
   Saving debug log to /var/log/letsencrypt/letsencrypt.log
   No certificates found.
   certbot 2.9.0
   ```

2. Understand the two challenge types before choosing one.

   | Challenge | What the CA checks | Requires | Wildcards |
   |---|---|---|---|
   | `http-01` | `http://<domain>/.well-known/acme-challenge/<token>` returns the key authorization | inbound TCP/80 reachable from the internet | **No** |
   | `dns-01` | TXT record at `_acme-challenge.<domain>` equals base64url(SHA-256(key authorization)) | API-driven DNS provider | **Yes** |
   | `tls-alpn-01` | TLS handshake on 443 with ALPN `acme-tls/1` presenting a special self-signed cert | inbound TCP/443, no HTTP redirect needed | No |

3. Run a **dry run** against the staging environment using the webroot plugin. This exercises the full protocol without consuming production quota.

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

4. Issue for real (only if you actually control the domain). Note the deploy hook — reloading the server is *your* responsibility, not certbot's.

   ```bash
   sudo certbot certonly \
     --webroot -w /var/www/html \
     -d example.com -d www.example.com \
     --key-type ecdsa --elliptic-curve secp256r1 \
     --agree-tos -m admin@example.com --no-eff-email \
     --deploy-hook 'systemctl reload nginx'
   ```

5. Examine the resulting layout. Understand that `live/` holds **symlinks** into `archive/`.

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

   | File | Contents | Use in nginx/httpd |
   |---|---|---|
   | `cert.pem` | leaf only | `SSLCertificateFile` (httpd ≥2.4.8 can take fullchain) |
   | `chain.pem` | intermediate(s) only | `SSLCertificateChainFile` (legacy), `ssl_trusted_certificate` for stapling |
   | `fullchain.pem` | leaf + intermediate(s) | `ssl_certificate` in nginx — **this is the one you want** |
   | `privkey.pem` | private key, mode 0600 | `ssl_certificate_key` |

6. Verify the renewal timer is active. Modern packages ship a systemd timer; do not add a cron job on top of it.

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

7. Exercise renewal without actually renewing.

   ```bash
   sudo certbot renew --dry-run
   ```

   ```
   Processing /etc/letsencrypt/renewal/example.com.conf
   Simulating renewal of an existing certificate for example.com and www.example.com
   Congratulations, all simulated renewals succeeded:
     /etc/letsencrypt/live/example.com/fullchain.pem (success)
   ```

8. Read the renewal configuration — this is what `certbot renew` replays.

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

9. For a wildcard, `dns-01` is mandatory. With the manual plugin:

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

   In production use a DNS-plugin instead (`certbot-dns-cloudflare`, `-route53`, `-rfc2136`) so renewal is unattended.

### Check your understanding — Block 9

- **Q9.1** Let's Encrypt certificates are valid for 90 days. Give the two arguments — one security, one operational — that the project uses to justify such a short lifetime.
- **Q9.2** You must issue for `*.internal.example.com`. Which challenge type must you use and why is the other one structurally incapable of it?
- **Q9.3** `--deploy-hook` versus `--post-hook` versus `--pre-hook`: when does each fire, and which one must carry your `systemctl reload`?
- **Q9.4** `live/fullchain.pem` is a symlink into `archive/`. What breaks if your configuration management copies the *file contents* into `/etc/nginx/ssl/` at install time?
- **Q9.5** A wildcard certificate for `*.example.com` is presented for the host `a.b.example.com`. Does it match? State the rule.

---

## Exercise 10 — Diagnostics: reproduce and read the six classic failures

For each scenario, reproduce it, capture the exact error, and state the fix.

### Steps

1. **Incomplete chain.** Start `s_server` presenting only the leaf.

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

   This is the failure that "works in Chrome but not in curl": browsers silently repair the chain via the AIA `caIssuers` URI; `openssl`, `curl` and most language runtimes do not.

2. **Expired certificate.** Issue one that is already dead using `-startdate`/`-enddate`.

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

3. **Wrong purpose.** Present a client certificate to a server-auth check.

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

4. **Key/certificate mismatch.** Compare public keys.

   ```bash
   openssl x509 -in certs/web01.cert.pem -noout -pubkey | openssl sha256
   openssl pkey -in private/web02.key.pem -pubout | openssl sha256
   ```

   ```
   SHA2-256(stdin)= 5c8a1f...e3
   SHA2-256(stdin)= 91bd47...0a
   ```

   Two different digests ⇒ nginx will refuse to start with `SSL_CTX_use_PrivateKey_file(...) failed ... key values mismatch`.

5. **Hostname mismatch through a real handshake.**

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

6. **Clock skew.** Verify a valid certificate at a simulated past date.

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

7. **Reference table — memorise these codes.**

   | Code | Message | Usual root cause |
   |---|---|---|
   | 2 | unable to get issuer certificate | trust anchor missing from `-CAfile`/store |
   | 3 | unable to get certificate CRL | `-crl_check_all` without a CRL for every level |
   | 9 | certificate is not yet valid | clock skew, or freshly issued with future `notBefore` |
   | 10 | certificate has expired | renewal failed / hook never reloaded the service |
   | 18 | self-signed certificate | self-signed leaf offered as if CA-issued |
   | 19 | self-signed certificate in certificate chain | private root not installed in the client's store |
   | 20 | unable to get local issuer certificate | **server sent an incomplete chain** |
   | 21 | unable to verify the first certificate | intermediate missing, seen from the client side |
   | 23 | certificate revoked | listed on the CRL / OCSP says `revoked` |
   | 24 | invalid CA certificate | `basicConstraints` says `CA:FALSE` on an issuer |
   | 26 | unsupported certificate purpose | EKU / keyUsage does not permit the operation |
   | 62 | hostname mismatch | name not in SAN |

8. A ready-to-use one-liner for on-call: dump everything about a live endpoint.

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

### Check your understanding — Block 10

- **Q10.1** Error 20 and error 21 both mean "the issuer could not be found". From which vantage point is each normally reported, and what single server-side change fixes both?
- **Q10.2** Explain, in one sentence each, why errors 18 and 19 are distinct.
- **Q10.3** Chrome loads the page; `curl` fails with error 20 against the same server. Explain the mechanism precisely, and give the *server-side* fix (not a client workaround).
- **Q10.4** A monitoring check based on `notAfter` reported the certificate as valid, yet clients got error 10. Name two ways that can happen.
- **Q10.5** What does `-attime` do, and why is it more reliable than changing the system clock to reproduce a validity-window bug?

---

## Sources

- LPI — Exam 303 objectives (303-300, v3.0.0): <https://www.lpi.org/our-certifications/exam-303-objectives/>
- RFC 5280 — *Internet X.509 PKI Certificate and CRL Profile*: <https://www.rfc-editor.org/rfc/rfc5280>
- RFC 6960 — *X.509 Internet PKI Online Certificate Status Protocol (OCSP)*: <https://www.rfc-editor.org/rfc/rfc6960>
- RFC 6125 — *Representation and Verification of Domain-Based Application Service Identity*: <https://www.rfc-editor.org/rfc/rfc6125>
- RFC 8446 — *TLS 1.3* (§4.4.2.1, certificate status extension): <https://www.rfc-editor.org/rfc/rfc8446>
- RFC 8555 — *Automatic Certificate Management Environment (ACME)*: <https://www.rfc-editor.org/rfc/rfc8555>
- RFC 7292 — *PKCS #12 Personal Information Exchange Syntax v1.1*: <https://www.rfc-editor.org/rfc/rfc7292>
- OpenSSL 3.x manual — `openssl-ca`: <https://docs.openssl.org/3.0/man1/openssl-ca/>
- OpenSSL 3.x manual — `openssl-verify` and verification options: <https://docs.openssl.org/3.0/man1/openssl-verification-options/>
- OpenSSL 3.x manual — `x509v3_config` (extension syntax): <https://docs.openssl.org/3.0/man5/x509v3_config/>
- OpenSSL 3.x manual — `openssl-ocsp`: <https://docs.openssl.org/3.0/man1/openssl-ocsp/>
- OpenSSL 3.x manual — `config` (`openssl.cnf` syntax): <https://docs.openssl.org/3.0/man5/config/>
- CA/Browser Forum — Baseline Requirements for TLS Server Certificates: <https://cabforum.org/working-groups/server/baseline-requirements/documents/>
- Let's Encrypt — Challenge Types: <https://letsencrypt.org/docs/challenge-types/>
- Let's Encrypt — Rate Limits and the staging environment: <https://letsencrypt.org/docs/rate-limits/> · <https://letsencrypt.org/docs/staging-environment/>
- Certbot user guide: <https://eff-certbot.readthedocs.io/en/stable/using.html>
- nginx — `ngx_http_ssl_module` (`ssl_stapling`): <https://nginx.org/en/docs/http/ngx_http_ssl_module.html>
- Apache httpd — `mod_ssl` (`SSLUseStapling`): <https://httpd.apache.org/docs/2.4/mod/mod_ssl.html>

---

<details>
<summary><strong>Answers</strong> — expand only after you have attempted every block</summary>

### Block 1 — Key material

**A1.1**
- `-----BEGIN PRIVATE KEY-----` → a PKCS#8 `PrivateKeyInfo` (RFC 5208/5958): version, an `AlgorithmIdentifier` naming the algorithm, and the algorithm-specific key blob wrapped in an `OCTET STRING`. Because the algorithm is named inside, **this label carries RSA, EC, Ed25519, X25519, DSA — anything — without changing**. This is what `openssl genpkey` writes by default and what you should standardise on.
- `-----BEGIN RSA PRIVATE KEY-----` → the legacy PKCS#1 `RSAPrivateKey` (modulus, exponents, primes, CRT coefficients) with no algorithm identifier. The label *is* the type declaration. The EC analogue is `-----BEGIN EC PRIVATE KEY-----`, a SEC1 `ECPrivateKey`. `openssl rsa -traditional` / `openssl ec` emit these.
- `-----BEGIN ENCRYPTED PRIVATE KEY-----` → a PKCS#8 `EncryptedPrivateKeyInfo`: a KDF+cipher `AlgorithmIdentifier` (typically PBES2 with PBKDF2 and AES-256-CBC) plus the ciphertext of the `PrivateKeyInfo`. Note that legacy encrypted PEMs instead keep the `RSA PRIVATE KEY` label and put `Proc-Type:` / `DEK-Info:` headers in the PEM preamble — a far weaker scheme (MD5-based KDF, one iteration) that you should migrate away from.

**A1.2** Neither is a *format* in the sense of "what fields exist" — that is fixed by the ASN.1 schema (X.509 for certificates, PKCS#8 for keys, PKCS#10 for CSRs). **DER** (Distinguished Encoding Rules) is the canonical binary serialisation of that ASN.1. **PEM** is DER, base64-encoded, wrapped in `-----BEGIN x-----`/`-----END x-----` armour. So: PEM is an envelope around DER, and the same certificate in PEM and DER is bit-for-bit the same certificate. This matters practically: a signature is computed over the DER bytes, which is why the round-trip in step 7 is lossless, and why `openssl asn1parse` sees the same tree either way.

**A1.3** The public key is a *component* of the private key structure — for RSA the private key file literally contains `n` and `e` alongside `d`, `p`, `q`; for EC it contains `d` and (usually) the encoded point `Q = d·G`. So `-pubout` is extraction, not computation. Going the other way requires solving the underlying hard problem: integer factorisation of `n` for RSA, or the elliptic-curve discrete logarithm (recovering `d` from `Q = d·G`) for EC. Both are believed intractable at these key sizes with classical hardware; that asymmetry *is* the security of the system.

**A1.4** The alternative is `ec_param_enc:explicit`, which serialises the full curve definition (field, `a`, `b`, generator, order, cofactor) into every key and certificate instead of a single curve OID. It breaks interoperability because (a) it bloats the encoding by hundreds of bytes; (b) many TLS libraries — and the CA/Browser Forum Baseline Requirements — mandate `namedCurve` and will reject explicit parameters outright; and (c) explicit parameters have historically enabled invalid-curve and parameter-substitution attacks, since the verifier is asked to trust curve parameters supplied by the untrusted side. Always use `named_curve`.

**A1.5** **P-256** is comparable to **RSA-3072** — both target roughly the 128-bit security level. (P-384 ≈ RSA-7680; RSA-2048 ≈ ~112-bit, which is why NIST set its 2030 sunset.) Operationally, on the *server* the direction that matters is signing: ECDSA P-256 signing is roughly an order of magnitude faster than RSA-3072 private-key operations, so an EC certificate materially raises handshake throughput on a busy TLS terminator. The trade-off inverts on the client: RSA *verification* (small public exponent 65537) is very fast, while ECDSA verification is slower than ECDSA signing. Since servers sign once per handshake and clients verify once, EC is the right default for server certificates. Certificates are also much smaller, which reduces the bytes in the first round trip.

---

### Block 2 — Reading a certificate

**A2.1** The three children of the outer `SEQUENCE` (the `Certificate` structure of RFC 5280 §4.1) are:
1. `tbsCertificate` — a `SEQUENCE` holding version, serial, signature algorithm, issuer, validity, subject, `SubjectPublicKeyInfo`, and extensions. In the dump this is the child at offset 4 (`hl=4 l=686`).
2. `signatureAlgorithm` — an `AlgorithmIdentifier` (offset 694), which must equal the algorithm named *inside* `tbsCertificate`; a mismatch is a signature-substitution red flag.
3. `signatureValue` — a `BIT STRING` (offset 706) holding the CA's signature.

The signature is computed over the **DER encoding of `tbsCertificate` only** — bytes 4 through 689 inclusive in this dump, i.e. including its own `SEQUENCE` tag and length header. Nothing outside that range is protected, which is exactly why `signatureAlgorithm` is duplicated inside the signed region.

**A2.2** A modern client uses **`subjectAltName` exclusively**. RFC 6125 deprecated CN-as-hostname, and the CA/Browser Forum Baseline Requirements have prohibited relying on the `commonName` for identity since 2017; Chrome removed the CN fallback in version 58, and Firefox, Go's `crypto/tls`, and current OpenSSL `X509_check_host()` behave the same way. The CN is retained only as a human-readable label — and if present it must duplicate a name that also appears in the SAN. Practical consequence: a certificate with a correct CN and **no** SAN extension fails in every modern client, which is the single most common cause of "it used to work" after a client upgrade.

**A2.3** The `critical` boolean in an `Extension` is the issuer's declaration that this extension is essential to safely interpreting the certificate. RFC 5280 §4.2 requires that a client which encounters a **critical extension whose OID it does not recognise MUST reject the certificate**. Non-critical unknown extensions may be ignored. This is the mechanism that lets the ecosystem deploy new semantics safely: marking `basicConstraints` critical means an old client that does not understand CA-vs-leaf distinctions refuses the certificate rather than mistaking a leaf for a CA — historically the root of the "any leaf can sign" attacks of the 2000s.

**A2.4**
- **`OCSP` URI** — where a client sends an OCSP request to learn the revocation status of *this* certificate (Exercise 7).
- **`CA Issuers` URI** — where to download the **issuer's** certificate, in DER.

**`CA Issuers` is the rescue mechanism.** When a server sends only its leaf, a client that implements "AIA chasing" (Chrome, Safari, Windows/Schannel, macOS) fetches the intermediate from that URI and repairs the chain itself. `openssl s_client`, `curl`, Go, Java and Python's `ssl` module do **not** chase AIA, which produces exactly the "works in the browser, fails in my code" split you reproduce in Exercise 10.

**A2.5** A certificate fingerprint changes on **every renewal**, because the serial, validity dates and signature all change — so a fingerprint pin breaks every 60–90 days. An SPKI pin is a hash of the `SubjectPublicKeyInfo` only, so it survives any renewal that **reuses the key pair** (or that uses a pre-generated backup key). That is why RFC 7469 and every mobile-pinning guide specify SPKI pins, and why you pin at least two values: the key in production and a cold backup key held offline. Pin an intermediate or root SPKI for even longer durability, at the cost of a broader trust surface.

---

### Block 3 — Root CA

**A3.1** The self-signature is verifiable with the public key contained in the very same certificate. Anyone can generate a key pair, write any Subject DN they like — including `CN = GlobalSign Root CA` — and produce a mathematically valid self-signature. Therefore the signature proves only **internal consistency and proof-of-possession of the corresponding private key**; it conveys zero authority. Trust comes entirely from **out-of-band distribution**: the certificate was placed into the relying party's trust store by an administrator (`update-ca-trust`), by an OS/browser vendor after a WebTrust/ETSI audit, or by an MDM policy. The trust store is the axiom; everything else is derived by signature chaining from it.

**A3.2**
- `index.txt` — the CA database: one line per issued certificate, recording status, expiry, revocation date and reason, serial, and subject DN. `openssl ca -gencrl` and `openssl ocsp -index` read revocation status from **here**, not from the certificate files.
- `serial` — the next serial number to assign, in hex; `openssl ca` reads it, issues, increments it, and writes it back (leaving `serial.old`).
- `crlnumber` — the monotonically increasing `CRLNumber` extension value for the next CRL.

Restoring a day-old `index.txt` is a **security incident**, not an inconvenience: (a) any certificate revoked in the lost window silently returns to status `V`, so the next CRL and every OCSP response declare a compromised key `good`; (b) certificates issued in that window vanish from the database, so they can never be revoked and their serials may be **re-issued**, producing two distinct certificates sharing one serial under one issuer — a violation of RFC 5280 that makes revocation-by-serial ambiguous. Recovery means reconciling against `newcerts/` (which holds a copy of every issued certificate, named by serial) and against your issuance logs.

**A3.3** The default is `unique_subject = yes`, which makes `openssl ca` refuse to issue a second valid certificate for a subject DN that already has one, with:

```
ERROR:There is already a certificate for /C=AR/.../CN=web01.example.internal
```

The outage scenario is **routine renewal with overlap**. Good practice is to issue the replacement certificate days or weeks before the old one expires, deploy it, verify it, and only then let the old one lapse. With `unique_subject = yes` that second issuance is refused while the first is still valid, so the operator is forced either to revoke the live certificate first (a window with no valid cert, and a revoked cert still deployed) or to hand-edit `index.txt` under time pressure. The same bites any CA issuing per-node certificates where a node is rebuilt and re-enrols under the same DN. Set `unique_subject = no` on any issuing CA.

**A3.4** Match against the corresponding field of the **CA's own certificate Subject** — i.e. the DN in `[ CA_default ] certificate`. With `organizationName = match`, a CSR is accepted only if its `O` is byte-identical to the root's `O` (`Example Internal Ltd`). The three policy verbs are:
- `match` — must equal the CA's value for that field;
- `supplied` — must be present in the CSR, any value;
- `optional` — may be absent.

Note the sharp edge: matching is a string comparison, so `Example Internal Ltd` versus `Example Internal Ltd.` fails. This is why issuing CAs normally use `policy_loose` and enforce naming through a real enrolment front-end instead.

**A3.5** `keyCertSign` is the bit that authorises signing **certificates**; `cRLSign` authorises signing **CRLs**. They are independent bits in the `KeyUsage` BIT STRING and a validator must check `keyCertSign` on every CA in the path (RFC 5280 §6.1.4). `digitalSignature` is required for neither — it is present here for generality (e.g. if the CA key ever signs an OCSP response directly rather than delegating to a responder certificate). A CA certificate lacking `keyCertSign` while `basicConstraints` says `CA:TRUE` produces `error 24: invalid CA certificate` on the certificates it issues.

---

### Block 4 — Intermediate CA and chains

**A4.1** `pathlen:0` sets `pathLenConstraint = 0`, meaning **zero further CA certificates may appear below this one in a valid path**. It does *not* count the intermediate itself, and it does not count the end-entity certificate. So this intermediate may issue leaf certificates, but may not issue another CA certificate. `pathlen:1` would allow exactly one further CA level beneath it. Two more rules worth knowing: `pathLenConstraint` is meaningful only when `CA:TRUE` and `keyCertSign` is asserted, and a CA certificate with no `pathLenConstraint` at all imposes no depth limit.

**A4.2** With `nameConstraints = permitted;DNS:.example.internal`, a client that enforces name constraints (Windows/Schannel, macOS, OpenSSL, NSS, Java — enforcement is broad and mandated by the Baseline Requirements) will reject any certificate under this intermediate whose SAN falls outside the permitted subtrees. So the attacker holding the stolen key **can** mint valid certificates for `anything.example.internal` — full impersonation inside your namespace — and **cannot** mint a usable certificate for `www.google.com`, `example.com`, or any IP literal (the `excluded;IP` entries close the IP subtree). This is the standard mitigation for cross-signing a customer's or subsidiary's CA, and the reason a private root that will be pushed to employee laptops should carry name constraints: it bounds the blast radius of your own key loss to your own namespace.

Two caveats to state honestly: constraints are enforced by the *relying party*, so a client that ignores them (some embedded stacks, old Android) gains no protection; and constraints on `DNS` do not automatically constrain `IP`, `email` or `directoryName` — you must exclude those subtrees explicitly, which is exactly what the `excluded;IP` lines do.

**A4.3** `openssl ca` differs from `req -x509` in that it:
1. **Maintains state** — allocates the serial from `serial`, appends a row to `index.txt`, and writes a copy of the certificate to `new_certs_dir` named `<serial>.pem`. `req -x509` writes one file and remembers nothing, so the resulting certificate can never be revoked by that CA.
2. **Signs a CSR from a separate key** — the subject's public key comes from the PKCS#10 request and the signing key is the CA's. `req -x509` self-signs: one key plays both roles.
3. **Applies a naming policy** (`policy_strict` / `policy_loose`) and prompts for confirmation before committing, giving the operator a review gate.

Additionally, only `openssl ca` supports `-revoke`, `-gencrl`, `-status` and `-crl_reason`, and only it honours `copy_extensions`. Corollary for the exam: a root certificate produced by `req -x509` does not appear in its own `index.txt`, and that is correct — a CA never issues its own certificate through its own database.

**A4.4** It proves **proof of possession**: whoever produced the CSR held the private key matching the public key inside it at the moment of signing. That stops an attacker from submitting *your* public key under *their* name and obtaining a certificate they cannot use — and, more subtly, from obtaining a certificate that binds your key to a name you do not control.

It proves **nothing about identity or authorisation**: not that the requester owns `example.internal`, not that the DN is truthful, not that the request was not replayed by a third party who intercepted it (the CSR is not bound to a transport or a nonce). Domain control validation, corporate identity checks, or an authenticated enrolment channel must supply that separately — which is precisely the job ACME automates in Exercise 9.

**A4.5** With `copy_extensions = copy`, `openssl ca` transplants the extensions requested inside the CSR into the issued certificate. Because a CSR is entirely attacker-controlled (it is self-signed by the requester, and that signature attests nothing about content), a requester can embed:

```
subjectAltName = DNS:login.corp.example.com, DNS:*.example.internal
basicConstraints = critical, CA:TRUE
keyUsage = critical, keyCertSign, cRLSign
```

If the operator signs it after reviewing only the Subject DN — which is all `openssl ca`'s confirmation prompt highlights, and all that the naming `policy` constrains — the CA emits a certificate valid for hosts the requester does not control, or worse, a **subordinate CA certificate** that lets the requester issue arbitrary certificates under your root. The `nameConstraints` on the intermediate bound the damage but do not eliminate it.

The safe patterns, in order of preference: keep `copy_extensions = none` and supply extensions from a CA-controlled `-extfile` as in Exercise 5; or use `copy_extensions = copyall` **only** behind an enrolment front-end that parses and whitelists the requested SANs against an authorisation database before invoking `openssl ca`. Note that OpenSSL ships with `copy_extensions` commented out (effectively `none`) precisely because of this.

---

### Block 5 — Server certificates

**A5.1** By default `openssl verify` builds and cryptographically validates the path and checks validity dates — and stops there. A browser additionally performs at least:
1. **Hostname verification** against the SAN (RFC 6125 / `X509_check_host`) — `openssl verify` does this only with `-verify_hostname`, and `s_client` only with `-verify_hostname` or `-verify_ip`.
2. **Purpose/EKU checking** — that the leaf asserts `serverAuth`; add `-purpose sslserver`.

Other browser-side checks worth naming: revocation (CRLSets/OCSP), Certificate Transparency SCT presence for publicly-trusted certificates, maximum-lifetime policy, and rejection of weak signature algorithms (SHA-1) or short keys.

**A5.2**
- **Error 2, `unable to get issuer certificate`** — reported at a non-zero depth: OpenSSL climbed part of the chain and then could not find the issuer of an *intermediate*, i.e. **the trust anchor is missing**. In step 7 the second command passed the intermediate as the `-CAfile`, so the root was nowhere to be found.
- **Error 20, `unable to get local issuer certificate`** — reported at depth 0: the issuer of the **leaf itself** could not be located, i.e. **the intermediate is missing**.

Error 20 is the "server forgot to send the intermediate" signature. Its client-side sibling is error 21, `unable to verify the first certificate`, which `s_client` reports for the same underlying condition.

**A5.3** Public CAs cannot validate control of an RFC 1918 address, and the CA/Browser Forum Baseline Requirements have prohibited certificates for internal names and reserved IP addresses since 2016 (all such certificates were revoked in the 2015–2016 sunset). A public IP address *can* be certified, but requires a specific IP-address validation method and is rare.

For an internal PKI the calculus changes completely: you are the authority for your own address space, so `IP:` SANs are legitimate and often necessary — health checkers, service meshes, load balancers and bootstrapping agents frequently connect by address before DNS is available. Two rules still apply: the SAN must use the `iPAddress` GeneralName type (which `subjectAltName = IP:10.20.30.41` produces — putting `DNS:10.20.30.41` instead is a common bug that most clients reject), and if your intermediate carries `excluded;IP` name constraints as in Exercise 4, an `IP:` SAN will be **rejected** — you must widen the constraint to permit the specific subnet, e.g. `permitted;IP:10.20.30.0/255.255.255.0`.

**A5.4** `-x509_strict` disables the compatibility workarounds OpenSSL normally applies and enforces RFC 5280 literally. Concretely it rejects, among others:
- a CA certificate that lacks `basicConstraints` entirely (OpenSSL would otherwise fall back to heuristics for ancient certificates);
- a version 1 or version 2 certificate used as a CA;
- a CA certificate whose `keyUsage` omits `keyCertSign`;
- certificates missing `subjectKeyIdentifier`/`authorityKeyIdentifier` where required;
- a non-CA certificate that asserts `keyCertSign`.

A concrete example: a legacy self-signed appliance certificate issued as X.509 v1 (hence carrying no extensions at all) verifies fine as its own trust anchor under default rules, but fails under `-x509_strict` because a v1 certificate cannot express `CA:TRUE`.

**A5.5** `-servername` populates the TLS **SNI (Server Name Indication)** extension in the ClientHello (RFC 6066). The server reads it *before* choosing a certificate, which is what makes virtual hosting over TLS possible on a single IP.

If the client omits it, the server has no way to know which virtual host is wanted at certificate-selection time and falls back to its **default/first** `server` block. The user then typically sees a certificate for an unrelated hostname and a name-mismatch error. This is why `openssl s_client -connect host:443` without `-servername` so often returns "the wrong certificate" on a shared load balancer — and why you should always pass both, or use the shorthand `-connect host:443 -servername host`. Note that SNI is sent in cleartext even in TLS 1.3 (absent Encrypted Client Hello), which is why it is a routine target for network-level filtering.

---

### Block 6 — CRLs

**A6.1** `nextUpdate` is the issuer's promise of when a newer CRL will be available; it is **not** an expiry of the revocation facts. RFC 5280 §6.3.3 requires a strict client to treat a CRL past `nextUpdate` as **not sufficiently fresh** and therefore to fail the revocation check, which under a hard-fail policy means rejecting the certificate.

The trade-off is stark and is why CRLs are operationally feared: if your CRL distribution point goes down, or a CRL is simply not regenerated on schedule, then at `nextUpdate` **every certificate under that CA stops validating at once** — a self-inflicted outage with no attacker involved. That is why `default_crl_days = 7` on an issuing CA needs a regeneration job running far more often than weekly (daily is typical), with monitoring on the age of the published file. The opposite choice — soft-fail, ignore a stale CRL — restores availability but makes revocation unenforceable against any attacker who can block the fetch, which is the same critique levelled at soft-fail OCSP.

**A6.2**
- `-crl_check` — checks revocation for the **leaf certificate only** (depth 0).
- `-crl_check_all` — checks **every certificate in the chain**, i.e. the leaf and every CA above it up to but excluding the trust anchor, and therefore demands a valid, current CRL from each issuing CA in the path.

Step 7 fails with `error 3 at 1 depth` precisely because the root's CRL — needed to prove the *intermediate* is not revoked — had not been generated yet. `-crl_check_all` is the correct setting for high-assurance validation, but it multiplies your CRL availability obligations by the depth of the hierarchy.

**A6.3** 
- `keyCompromise` (reason 1) — the private key is believed to be in unauthorised hands. Permanent, and the most serious; a validator should treat the certificate as invalid **from the moment of compromise**, not merely from the revocation date.
- `cessationOfOperation` (reason 5) — the certificate is simply no longer used (host decommissioned, domain transferred). Permanent, but carries no implication of compromise.
- `certificateHold` (reason 6) — a **temporary, reversible** suspension, used while an incident is under investigation.

`certificateHold` is the reversible one. It is undone by **removing the entry from the CRL** and publishing a new CRL; the mechanism is a delta-CRL or full-CRL entry carrying reason code `removeFromCRL` (8), which tells clients holding an older CRL to drop the hold. In OpenSSL you place the hold with `openssl ca -revoke <cert> -crl_reason certificateHold` and lift it with `openssl ca -valid <cert>`, which resets the row in `index.txt` back to `V`. Practical warning: `certificateHold` support in real-world clients is patchy, and the CA/Browser Forum forbids it for publicly-trusted TLS certificates — treat it as an internal-PKI tool only.

**A6.4** 
1. **Size and growth.** A CRL is a single monolithic list of every unexpired revoked certificate under that CA. At scale it reaches megabytes; every client must download the whole thing to answer one yes/no question about one serial. The cost falls on both the CA's distribution bandwidth and on every client, including mobile and metered links.
2. **Freshness versus load, in direct conflict.** The revocation window is bounded by the CRL publication interval. Shortening it to hours means re-publishing a multi-megabyte artefact that hour, and every cache in the world revalidating it — a synchronised thundering herd against the CDN. Lengthening it leaves compromised certificates accepted for that whole window. There is no setting that is both fresh and cheap.

Named mitigations, which are worth knowing: **delta CRLs** (publish only changes since a base CRL), **CRL partitioning** via multiple `crlDistributionPoints` / **Issuing Distribution Points** so each certificate maps to a small shard, and the modern browser answer — **proprietary aggregated push lists** (Chrome's CRLSets, Mozilla's CRLite) that compress the globally relevant revocation set into something shippable with the browser, sidestepping per-connection fetches entirely.

**A6.5** `crlDistributionPoints` with an `http://` URI is defined to serve a **DER-encoded** CRL (`application/pkix-crl`, RFC 5280 §4.2.1.13 and RFC 2585). Most clients — Windows/Schannel, macOS, Java, and OpenSSL's own `X509_load_crl_file` in DER mode — will not accept a base64/PEM body from that URI and will report the CRL as unretrievable or malformed, producing `error 3: unable to get certificate CRL` and, under hard-fail, an outage. PEM is the convenient local/interchange form; DER is the wire form. The same rule applies to the `caIssuers` AIA URI, which must serve a DER certificate (`application/pkix-cert`) — publishing a PEM there is the single most common reason browser AIA chasing fails to repair a broken chain.

---

### Block 7 — OCSP and stapling

**A7.1** Without it: to trust an OCSP response, the client must validate the responder's certificate. Validating any certificate includes checking whether it has been revoked. Checking revocation means querying OCSP. Querying OCSP returns a response signed by the responder, whose certificate must be validated… — an unterminated recursion, and in practice a deadlock, since the responder cannot answer a query about its own status without first being trusted.

`id-pkix-ocsp-nocheck` (RFC 6960 §4.2.2.2.1) breaks the loop: it instructs the client to **skip revocation checking for this certificate entirely**. The safety argument is compensating controls — such certificates are issued with deliberately short lifetimes (days to a few months), so a compromise expires on its own rather than needing revocation. Note the trade this makes explicit: a stolen OCSP-signing key with `nocheck` cannot be revoked in any way clients will honour, so the only remedy is waiting out the validity period or revoking the issuing CA. That is why responder keys deserve HSM protection and why the extension is marked non-critical but the EKU `OCSPSigning` is marked critical.

**A7.2** The **nonce** is a client-chosen random value placed in the request; a conforming responder echoes it in the signed response. It cryptographically binds the response to *this* request, defeating **replay**: without it, an attacker who captured a signed `good` response before a compromise can re-serve that response indefinitely (up to `nextUpdate`) to suppress the revocation, and the signature still verifies.

Public responders refuse nonces because a nonce makes every response **unique and therefore uncacheable**. Let's Encrypt, DigiCert and the rest serve responses from CDN edge caches with multi-day validity, pre-signed in bulk; honouring nonces would force an online signing operation per query at internet scale — the exact load profile that OCSP infrastructure cannot sustain and that has caused several high-profile responder outages. RFC 8954 revised the nonce extension partly in response to this tension. So on the public web you get replay-window exposure bounded by `nextUpdate`; on an internal PKI like this lab you can and should keep nonces on (drop `-no_nonce`), because your query volume is trivial.

**A7.3** With **CRLs**, the client downloads one large list covering all certificates under the CA. The CA learns that some client fetched the CRL, but not which certificate that client cared about — the list is the anonymity set. Caching means most connections generate no fetch at all.

With **live OCSP**, the client sends the specific serial number it is interested in, over plaintext HTTP, to a responder operated by the CA. The CA — and every network observer on the path, since OCSP is unencrypted by design so it can be cached — learns *which site this IP address is visiting, and when*. That is a browsing-history side channel, held by a third party the user never chose to talk to. It was one of the strongest arguments against mandatory OCSP and a direct motivation for both stapling (the query moves to the server, which already knows you are visiting it) and for Chrome/Firefox abandoning live OCSP in favour of pushed aggregated lists.

**A7.4** Stapling solves:
1. **Latency and availability** — the client makes no extra connection to a third party, so a slow or dead responder no longer stalls or breaks handshakes. The server fetches the response on its own schedule and caches it.
2. **Privacy** — the CA no longer learns which clients visit which site; the server, which already knows, does the asking.

It does **not** solve **suppression**. A `status_request` is a client *request*; a server that simply omits the `CertificateStatus` message causes the client to fall back to soft-fail and accept the certificate. So an attacker holding a stolen key can just decline to staple, and revocation is silently bypassed — stapling as deployed is an optimisation, not an enforcement mechanism.

The intended fix was the `status_request` **must-staple** flag: the TLS Feature extension (RFC 7633), set with `tlsfeature = status_request` in the certificate, tells clients that a missing staple is fatal. Adoption is poor and it is operationally dangerous — a single stapling failure on your server hard-fails every connection — so it remains rare. TLS 1.3 improves the plumbing (the status is carried inside the `Certificate` message, and multi-certificate status is native) but does not change the suppression analysis.

**A7.5** `ssl_trusted_certificate` gives nginx the **issuer chain plus root** needed to verify the *signature on the OCSP response it received*. Before caching and serving a staple to clients, nginx checks that the response was signed by a key that legitimately speaks for the issuing CA — i.e. by the CA itself or by a delegated responder certificate bearing `OCSPSigning` and chaining to that CA. Without this, nginx would blindly relay whatever the responder URI returned.

It is not the same file as `ssl_certificate` for two reasons. First, `ssl_certificate` in nginx should contain **leaf + intermediates and no root** (sending the root wastes bytes on every handshake and adds nothing, since a client that lacks the root will not trust it anyway); verifying an OCSP response requires the chain to terminate at a **trust anchor**, so `ssl_trusted_certificate` must *include* the root. Second, `ssl_trusted_certificate` is never sent to clients — it is a local verification store — so its contents are chosen for validation completeness, not wire economy. In this lab that is `ca-chain.cert.pem` (intermediate + root), while `ssl_certificate` is `web01-fullchain.pem` (leaf + intermediate).

---

### Block 8 — Formats and trust stores

**A8.1** On Debian/Ubuntu, `update-ca-certificates` scans `/usr/local/share/ca-certificates/` for files matching **`*.crt`** only, and their contents must be PEM. A `.pem` extension is silently skipped — no warning, and `update-ca-certificates` still reports success, which makes this a genuinely confusing failure. Rename to `.crt` (the content need not change; it is PEM either way). The RHEL family is the mirror image: `/etc/pki/ca-trust/source/anchors/` accepts PEM or DER regardless of extension, and you run `update-ca-trust extract`. Carrying a `.pem` file from a RHEL runbook to a Debian host is exactly how this bites.

**A8.2**
- **`-CAfile`** points at a single file containing one or more concatenated PEM certificates. OpenSSL loads them all into memory at startup and searches linearly. Simple, but the whole bundle is parsed on every process start.
- **`-CApath`** points at a directory in which each trust anchor is looked up **on demand** by a hash of its **subject name**. OpenSSL computes the subject hash of the issuer it is looking for and opens `<hash>.0`, `<hash>.1`, … until it finds a match. This scales to thousands of anchors with no upfront parse cost — it is how `/etc/ssl/certs` works on Debian.

`openssl rehash` (the modern replacement for the `c_rehash` Perl script) computes **`X509_NAME_hash()` of the certificate's subject DN** — a truncated SHA-1 of the canonical DER encoding of the name — renders it as 8 lowercase hex digits, and creates a symlink `<hash>.<n>`, where `<n>` disambiguates multiple certificates sharing a subject (a CA and its cross-signed twin, or an old and new generation of the same root). Two traps: you must re-run `rehash` after adding or removing any file, or lookups silently miss; and the hash algorithm changed between OpenSSL 0.9.8 and 1.0.0, so link directories are not portable across that boundary — `openssl rehash` regenerates correctly for the installed version.

**A8.3** `update-ca-trust extract` consumes the anchors and emits several artefacts under `/etc/pki/ca-trust/extracted/` because different consumers want different things:
- **`pem/tls-ca-bundle.pem`** and the compatibility symlink `/etc/pki/tls/certs/ca-bundle.crt` — a concatenated PEM bundle for OpenSSL, curl, Python, and anything taking a `-CAfile`.
- **`openssl/ca-bundle.trust.crt`** — the *extended* BEGIN TRUSTED CERTIFICATE format, which carries per-certificate **trust purpose** flags (this anchor is trusted for TLS servers but not for e-mail, this one is explicitly distrusted). A plain PEM bundle cannot express that; it is all-or-nothing per certificate.
- **`java/cacerts`** — a JKS/PKCS#12 keystore, because the JVM does not read PEM bundles.
- **`edk2/cacerts.bin`** — for UEFI/firmware consumers.
- The **NSS shared database** consumed by Firefox/Thunderbird via `p11-kit`.

The design point is that `p11-kit` is the single source of truth and the extracted formats are generated views; you edit anchors, never the extracted files, which are overwritten on every run. The trust-flag capability is also why RHEL can *distrust* a certificate (`/etc/pki/ca-trust/source/blocklist/`) rather than only add trust.

**A8.4** They defend against different adversaries:
- The **passphrase-derived encryption** (PBES2/PBKDF2 over the `shroudedKeyBag`) protects **confidentiality of the private key** against anyone who obtains the file — from a backup tape, an S3 bucket, an e-mail attachment. Without the passphrase the key material is ciphertext.
- The **MAC** (an HMAC over the whole PKCS#12 `AuthenticatedSafe`, keyed from the same passphrase) protects **integrity and authenticity of the container as a whole** — including the *certificates*, which are frequently stored unencrypted in the file. Without it, an attacker could substitute or add a certificate in the bundle — for instance injecting a rogue CA certificate into the `-cacerts` bag that the importing system then trusts — without touching the encrypted key at all.

Note the shared weakness: both are derived from one passphrase via a KDF whose iteration count (`2048` in the output above) is low by modern standards. For anything long-lived, raise it with `-iter` / `-macsaltlen` and choose a high-entropy passphrase; PKCS#12 is a transport format, not a vault.

**A8.5** OpenSSL 3.0 moved the old, weak algorithms — RC2-40, RC2-128, DES, and the SHA-1-based PBE schemes of PKCS#12 v1 — into the **legacy provider**, which is not loaded by default. Consequently `openssl pkcs12 -export` now defaults to modern PBES2 (AES-256-CBC, PBKDF2-HMAC-SHA256) and an SHA-256 MAC. Appliances, Java 8 and earlier, and older Windows importers frequently understand only the legacy `pbeWithSHA1And3-KeyTripleDES-CBC` encryption and an SHA-1 MAC, and reject the modern file with "unsupported algorithm" or a bare parse error.

Minimal fix — re-export in the old encoding:

```bash
openssl pkcs12 -export -legacy \
  -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 \
  -inkey private/web01.key.pem -in certs/web01.cert.pem \
  -certfile certs/ca-chain.cert.pem -out certs/web01-legacy.p12
```

`-legacy` activates the legacy provider (it must be present as `legacy.so` in `MODULESDIR`; on some minimal images it is a separate package). If you only need the *MAC* downgraded, `-macalg sha1` alone is often enough, since Java 8u301+ handles PBES2 but older MAC verification is stricter. Treat this as a compatibility shim with a deprecation ticket attached, not a permanent configuration — 3DES and SHA-1 are there because the far end is obsolete.

---

### Block 9 — ACME and Let's Encrypt

**A9.1**
- **Security.** Revocation does not work reliably — CRLs are stale or unfetched, OCSP is soft-fail and suppressible, and browsers have largely retreated to aggregated push lists with limited coverage. A short lifetime is therefore the only revocation mechanism that is guaranteed to take effect: a compromised key that cannot be revoked in practice is nonetheless useless in at most 90 days. The same argument bounds the damage from mis-issuance and from domain ownership changing hands after validation.
- **Operational.** A 90-day lifetime makes manual renewal untenable, which **forces automation** — and automation is the point. Yearly renewals are performed by a human who has forgotten the procedure, at 3 a.m., during the outage the expiry caused; a renewal that runs twice a day is exercised continuously and fails visibly while there is still a month of slack. The project has stated this explicitly: short lifetimes are a forcing function for correct tooling.

The industry has continued in this direction — the CA/Browser Forum has voted to reduce maximum TLS certificate lifetimes in stages toward 47 days by 2029 — so the automation assumption is becoming universal rather than Let's Encrypt-specific.

**A9.2** You must use **`dns-01`**. The reason is structural: `http-01` proves control of a *specific hostname* by serving a token at `http://<that-exact-host>/.well-known/acme-challenge/<token>`. A wildcard `*.internal.example.com` asserts authority over an **unbounded set** of hostnames, and there is no single HTTP endpoint whose control could demonstrate that — the CA would have to enumerate infinitely many names. `dns-01` instead proves control of the **DNS zone** by placing a TXT record at `_acme-challenge.internal.example.com`, and control of the zone *is* precisely the authority to create any name beneath it. `tls-alpn-01` fails for the same reason as `http-01`. For internal names there is a second, independent blocker: no publicly-trusted CA may issue for a non-public namespace at all, so `internal.example.com` needs your own ACME CA (step-ca, Boulder, Pebble) or the private PKI of Exercises 3–5.

**A9.3**
- **`--pre-hook`** — runs **before** each renewal attempt, once per certbot invocation that has work to do. Use it to free port 80 for the `standalone` plugin (`systemctl stop nginx`).
- **`--post-hook`** — runs **after** the attempt, once per invocation, **whether or not** anything was renewed. Use it to undo the pre-hook (`systemctl start nginx`).
- **`--deploy-hook`** — runs **only when a certificate was actually renewed**, once **per renewed certificate**, with `$RENEWED_LINEAGE` and `$RENEWED_DOMAINS` set in the environment.

Your `systemctl reload nginx` belongs in **`--deploy-hook`**. Putting it in `--post-hook` means reloading the web server twice a day forever for no reason (and masking a broken config change at an unpredictable time); putting it in `--pre-hook` reloads *before* the new files exist, so the server keeps serving the old certificate until something else restarts it — the classic "certbot says renewed, browsers still show the expired cert" incident. Hooks recorded at issuance are persisted into `renewalparams` (as `renew_hook`) and replayed by `certbot renew`, which is why step 8's config file is worth reading.

**A9.4** `certbot renew` writes the new certificate into `archive/` as `certN+1.pem` and **repoints the `live/` symlinks**. The path `/etc/letsencrypt/live/example.com/fullchain.pem` therefore always resolves to the current certificate, and nginx — which resolves the symlink at reload — picks it up.

If configuration management **copies the file contents** to `/etc/nginx/ssl/fullchain.pem` at install time, that copy is a frozen snapshot. Renewal updates the symlink target, the copy is untouched, and the server keeps serving the old certificate until it expires — while `certbot certificates` cheerfully reports a fresh certificate with 89 days remaining, and your `notAfter` monitoring (if it reads `live/`) agrees. It is a silent divergence that surfaces as a production outage on expiry day, with every diagnostic pointing at "renewed successfully".

The fixes, in order of preference: reference the `live/` paths directly in the server config (they are stable by design — that is the entire purpose of the `live/` indirection); or, if a copy is unavoidable, do the copy in a `--deploy-hook` so it re-runs on every renewal and is followed by the reload. Never `cp -L` once at provisioning time. A related trap: `live/` and `archive/` are root-owned and mode-restricted, so a non-root service reading `privkey.pem` needs a deploy-hook that copies and re-permissions, not a permission loosening on `/etc/letsencrypt`.

**A9.5** **No.** A wildcard matches **exactly one label** in the leftmost position only. `*.example.com` matches `a.example.com` and `www.example.com`, but not `a.b.example.com` (two labels below the wildcard) and not the bare `example.com` (zero labels — which is why the certbot command in step 9 requests `-d '*.example.com' -d example.com` explicitly).

The precise rules from RFC 6125 §6.4.3 and the CA/Browser Forum Baseline Requirements: the wildcard character must be the **entire leftmost label** (`*.example.com` is valid; partial-label forms like `w*.example.com` were once permitted and are now rejected by browsers), it may appear **only** in that position (`a.*.example.com` is invalid), it never matches a dot, and it may not be placed such that it spans a public suffix (`*.com`, `*.co.uk`). To cover `a.b.example.com` you need either an explicit SAN for it or a second wildcard `*.b.example.com`.

---

### Block 10 — Diagnostics

**A10.1**
- **Error 20, `unable to get local issuer certificate`** — reported by `openssl verify` operating on files, at depth 0: the issuer of the leaf is in neither the trust store nor the `-untrusted` set.
- **Error 21, `unable to verify the first certificate`** — reported by `openssl s_client` and by TLS clients generally: the *first* certificate in the chain the peer sent (the leaf) could not be verified because the chain stops there.

Both describe the same underlying condition from different vantage points — file-based verification versus a live handshake. The single server-side fix is to **serve the complete chain**: concatenate leaf + intermediate(s) (root optional and normally omitted) and point `ssl_certificate` (nginx) or `SSLCertificateFile` (httpd ≥ 2.4.8) at that file — `fullchain.pem`, not `cert.pem`.

**A10.2**
- **Error 18, `self-signed certificate`** — the certificate being verified *is itself* the self-signed one at depth 0; there is no chain at all. Typical of an appliance or a `req -x509` test certificate presented directly, with no matching anchor installed.
- **Error 19, `self-signed certificate in certificate chain`** — a genuine multi-level chain was built and terminated at a self-signed root **that is not in the trust store**. The hierarchy is fine; the anchor is simply not trusted here. This is what you get from a correctly built private PKI before `update-ca-trust` has been run on the client — exactly Exercise 8 step 5.

**A10.3** Chrome implements **AIA chasing**: on encountering a chain it cannot complete, it reads the leaf's `authorityInfoAccess` extension, fetches the DER-encoded issuer certificate from the `caIssuers` URI, and repairs the chain itself. Safari, Windows/Schannel and macOS do the same. `curl`/OpenSSL, Go, Java and Python's `ssl` module deliberately do **not** — a TLS client is not expected to make outbound HTTP requests mid-handshake, and doing so would be a latency and privacy cost on every connection. So the browser masks a server misconfiguration that every automated client trips over: monitoring, CI, webhooks and mobile SDKs fail while the operator's browser shows a green padlock.

The **server-side** fix is to send the intermediate(s): build `fullchain.pem` and reference it. Verify from the server's own perspective with

```bash
openssl s_client -connect host:443 -servername host -showcerts </dev/null 2>/dev/null | grep -c 'BEGIN CERTIFICATE'
```

which must return at least 2 for a normal public chain. Client-side `-CAfile`/`--cacert` workarounds hide the defect rather than fixing it.

**A10.4** Two mechanisms, both common:
1. **The check read the wrong file.** It parsed `notAfter` from a renewed certificate on disk (`/etc/letsencrypt/live/...`) while the running server still holds the **old** certificate in memory, because nothing reloaded it — the missing `--deploy-hook` of A9.3, or the frozen-copy problem of A9.4. The fix is to monitor the certificate **as served**, over the network: `openssl s_client -connect host:443 -servername host | openssl x509 -noout -enddate`, not a file on disk.
2. **An intermediate or root expired, not the leaf.** `openssl verify` reports error 10 for *any* depth, and the diagnostic line names the offending certificate — read the `notAfter=` that accompanies the error. The industry precedent is the 2021 expiry of the DST Root CA X3 cross-sign, which broke countless clients whose leaf certificates were perfectly current. A monitoring check that inspects only depth 0 is blind to this; check the whole chain.

A third, less common variant worth naming: **client-side clock skew** (a device with no RTC or a failed NTP sync) makes a valid certificate appear expired or not-yet-valid on that client only — see A10.5.

**A10.5** `-attime <unix-epoch>` tells the verifier to evaluate **all time-dependent checks** — certificate `notBefore`/`notAfter`, CRL `lastUpdate`/`nextUpdate`, OCSP response freshness — as if the current time were that value. It is scoped to the single `openssl` invocation.

It is more reliable than changing the system clock because moving the host clock is a **global, side-effectful** action: it will fight NTP (which may step it back mid-test, producing irreproducible results), it corrupts log timestamps and file mtimes, it can break Kerberos tickets, TOTP, TLS sessions and database replication on that host, and on a shared or containerised system it affects processes that have nothing to do with your test. `-attime` is deterministic, reproducible, requires no privileges, is safe on a production box, and is trivially scriptable across many timestamps — for example, to find the exact date on which a chain will start failing:

```bash
for d in '+29 days' '+60 days' '+91 days'; do
  printf '%s: ' "$d"
  openssl verify -CAfile root-ca.cert.pem -untrusted int-ca.cert.pem \
    -attime "$(date -d "$d" +%s)" web01.cert.pem 2>&1 | tail -1
done
```

The `s_client` equivalent is `-attime` as well (it accepts the same verification options), so you can rehearse a future-dated handshake against a live server without touching either machine's clock.

</details>