# 331.1 — X.509 Certificates and Public Key Infrastructures

**LPIC-3 303 (Security), exam 303-300 v3.0.0 — Topic 331 Cryptography · Weight 8.34**

---

## 1. The architectural problem

Every distributed system eventually needs to answer one question at connection time: *is the process on the other end of this socket the one I intended to talk to?* Symmetric secrets do not scale to that question — `n` mutually authenticating services need `n(n-1)/2` pre-shared keys, and every rotation is an O(n²) coordination event. X.509 solves it by replacing the mesh of shared secrets with a **tree of delegated assertions**: a small number of trust anchors, each capable of vouching for an unbounded number of identities, and each vouching act reduced to a signed, offline-verifiable data structure.

That trade — the mesh collapses to a tree — is the whole reason X.509 exists, and it is also where the operational pain lives:

| Property gained | Cost incurred |
|---|---|
| Verification is offline: no network call to a third party at handshake time | Assertions cannot be un-said. Revocation is a bolt-on, and it is the weakest part of the system. |
| One anchor authenticates millions of endpoints | One compromised anchor forges millions of endpoints. Blast radius is the whole namespace. |
| Identity is bound to a public key, not a network location | The binding is time-boxed. Every certificate is a scheduled outage unless renewal is automated. |
| Trust is transitive through intermediates | The verifier must reconstruct a path. Chain-building failures are the single most common TLS incident class. |

In production the failure modes cluster into four buckets, and this material is organised around eliminating each of them:

1. **Expiry.** An unrenewed certificate is a total, simultaneous, correlated outage of every client. It is the only failure mode that is 100% predictable in advance and still routinely takes down large platforms.
2. **Path construction.** The server omits an intermediate; the client has a different trust store than the developer's laptop; a cross-signed root expires and a naive verifier follows the dead branch.
3. **Over-issuance.** A sub-CA handed to a team can mint `*.anything` unless constrained. A CSR is trusted verbatim and carries `CA:TRUE`.
4. **Revocation that does not revoke.** A CRL nobody fetches, an OCSP responder nobody can reach, a soft-fail client that treats "responder down" as "certificate fine".

The engineering answer to all four is the same shape: **short lifetimes, automated issuance, cryptographically enforced scope, and verification you actually run in CI.** Long-lived certificates plus manual renewal plus revocation-as-a-safety-net is the anti-pattern; it is also what most brownfield estates look like.

---

## 2. Anatomy of an X.509v3 certificate

A certificate is an ASN.1 `SEQUENCE` defined by RFC 5280, DER-encoded, and usually wrapped in Base64 with PEM armour. Three top-level fields:

```
Certificate  ::=  SEQUENCE  {
     tbsCertificate       TBSCertificate,      -- everything that is signed
     signatureAlgorithm   AlgorithmIdentifier, -- repeated here, MUST match the inner one
     signatureValue       BIT STRING           -- issuer's signature over DER(tbsCertificate)
}
```

The `signatureAlgorithm` appearing twice is not redundancy for its own sake: the outer copy is unauthenticated and exists only so a parser can select a verifier before it parses; RFC 5280 §4.1.1.2 requires the verifier to check that it equals the inner, signed copy. A verifier that trusts the outer copy alone is vulnerable to algorithm-substitution games.

### 2.1 `TBSCertificate` fields

| Field | Notes for production |
|---|---|
| `version` | `2` on the wire means v3. Anything less has no extensions and must be rejected for TLS. |
| `serialNumber` | Positive INTEGER, ≤20 octets. CA/Browser Forum Baseline Requirements demand ≥64 bits of CSPRNG entropy — this is a defence against chosen-prefix hash collisions, not a counter. `openssl ca` gets this from `rand_serial = yes`. |
| `signature` | Inner, signed algorithm identifier. |
| `issuer` | DN of the signing CA. Must be byte-identical to the issuer's `subject` for path building by name. |
| `validity` | `notBefore`/`notAfter`. UTCTime until 2049, GeneralizedTime after. `notAfter = 99991231235959Z` is the RFC 5280 "no well-defined expiry" encoding — legal, and a red flag in a TLS leaf. |
| `subject` | May be empty (`SEQUENCE {}`) **only** if `subjectAltName` is present and marked critical. |
| `subjectPublicKeyInfo` | `AlgorithmIdentifier` + `BIT STRING`. This is the object you hash for SPKI pinning. |
| `issuerUniqueID` / `subjectUniqueID` | v2 relics. RFC 5280 says do not generate. |
| `extensions` | v3. Where all the actual policy lives. |

### 2.2 The extensions that decide behaviour

| Extension | OID | Critical? | What it actually controls |
|---|---|---|---|
| `basicConstraints` | 2.5.29.19 | MUST be critical in a CA cert | `CA:TRUE/FALSE` and `pathlen`. `pathlen:0` = may sign leaves, may not sign further CAs. A leaf with `CA:TRUE` is a sub-CA. |
| `keyUsage` | 2.5.29.15 | SHOULD be critical | Cryptographic operations permitted. `keyCertSign` is what makes a CA a CA in practice; a chain where an intermediate lacks it fails with error 35. |
| `extendedKeyUsage` | 2.5.29.37 | Optional | `serverAuth` (1.3.6.1.5.5.7.3.1), `clientAuth` (.2), `codeSigning` (.3), `emailProtection` (.4), `timeStamping` (.8), `OCSPSigning` (.9). EKU in a CA cert *constrains* what its descendants may assert — this is "EKU chaining", honoured by OpenSSL, NSS, and Windows. |
| `subjectAltName` | 2.5.29.17 | Critical only if subject is empty | The **only** identity source for TLS hostname matching. `dNSName`, `iPAddress`, `rfc822Name`, `URI`, `otherName` (SPIFFE IDs, UPNs). |
| `subjectKeyIdentifier` | 2.5.29.14 | Non-critical | Hash of the SPKI. Chain-building hint. |
| `authorityKeyIdentifier` | 2.5.29.35 | Non-critical | Points at the issuer's SKI. Lets a verifier pick the right issuer when a CA has re-keyed under the same DN. |
| `crlDistributionPoints` | 2.5.29.31 | Non-critical | Where the CRL lives. Must be HTTP, never HTTPS (chicken-and-egg). |
| `authorityInfoAccess` | 1.3.6.1.5.5.7.1.1 | Non-critical | `OCSP` responder URI + `caIssuers` URI for AIA chasing. |
| `nameConstraints` | 2.5.29.30 | MUST be critical | Restricts the namespace a sub-CA may issue into. The single most valuable control when delegating a CA. |
| `certificatePolicies` | 2.5.29.32 | Non-critical | Policy OIDs; `anyPolicy` = 2.5.29.32.0. |
| `ct_precert_scts` | 1.3.6.1.4.1.11129.2.4.2 | Non-critical | Embedded Signed Certificate Timestamps. |
| `ct_precert_poison` | 1.3.6.1.4.1.11129.2.4.3 | MUST be critical | Marks a precertificate. Its criticality is what makes precerts unusable as real certificates. |
| `noCheck` | 1.3.6.1.5.5.7.48.1.5 | Non-critical | On an OCSP signer: "do not check my revocation status". |

**Criticality is the enforcement mechanism.** RFC 5280 §4.2 requires a verifier to *reject* a certificate containing a critical extension it does not understand. That is why `nameConstraints` must be critical — a client that cannot enforce it must refuse the certificate rather than silently ignore the constraint.

### 2.3 Encodings and container formats

| Name | Extension | Content | When you use it |
|---|---|---|---|
| DER | `.der` `.cer` `.crt` | Raw binary ASN.1 | Java keystores, Windows, embedded, anything hashing the cert |
| PEM | `.pem` `.crt` `.key` | Base64 DER + `-----BEGIN X-----` | Everything on Linux |
| PKCS#1 | `.pem` | `BEGIN RSA PRIVATE KEY` | Legacy RSA-only private key |
| PKCS#8 | `.pem` `.key` | `BEGIN PRIVATE KEY` / `BEGIN ENCRYPTED PRIVATE KEY` | Modern, algorithm-agnostic private key. Default output of `openssl genpkey`. |
| PKCS#10 | `.csr` `.req` | `BEGIN CERTIFICATE REQUEST` | CSR |
| PKCS#7 / CMS | `.p7b` `.p7c` | Certs + CRLs, **no private key** | Chain distribution to Windows/Java |
| PKCS#12 / PFX | `.p12` `.pfx` | Key + cert + chain, password-protected | Handing a complete identity to Java, .NET, browsers |
| PKCS#11 | — | *API*, not a file | HSM / smartcard / TPM access |
| JKS / BCFKS | `.jks` | Java-native keystore | Legacy JVM. Prefer PKCS#12 (`keytool` default since Java 9). |

Memorise the PKCS numbers — the exam asks for them directly, and mixing up #7 (chain, no key) with #12 (key included) is a real-world data-classification mistake.

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

`asn1parse` is the tool of last resort when a certificate will not parse at all — it shows you where the DER stops making sense.

---

## 3. Key material: choosing the algorithm

The key is the identity. Everything else is metadata about it.

| Algorithm | Sec. level | Public key | Signature | CA sign cost | Verify cost | Where it is safe to use |
|---|---|---|---|---|---|---|
| RSA-2048 | ~112-bit | 294 B | 256 B | high | **very low** | Universal floor. Best when verifiers vastly outnumber signers (root CAs, code signing). |
| RSA-3072 | ~128-bit | 422 B | 384 B | very high | low | Compliance-driven 128-bit floor without leaving RSA. |
| RSA-4096 | ~140-bit | 550 B | 512 B | punishing | low | Offline roots only. On a TLS leaf it buys ~nothing and costs handshake CPU on every connection. |
| ECDSA P-256 | ~128-bit | 91 B | ~71 B | **very low** | low | Default for TLS leaves and issuing CAs. ~4× cheaper handshakes than RSA-2048 at scale. |
| ECDSA P-384 | ~192-bit | 120 B | ~103 B | low | moderate | Roots and long-lived intermediates; FIPS/CNSA alignment. |
| Ed25519 | ~128-bit | 44 B | 64 B | very low | very low | Internal PKI, SSH CAs, service mesh. **Not** issuable by public WebPKI CAs; TLS 1.3 only in practice. |

Practical guidance for a platform estate:

- **Root: ECDSA P-384, 20-year life, offline, on an HSM.** Verify cost is paid once per chain and only on cold path building.
- **Issuing CA: ECDSA P-384 or P-256, 10-year life, online, HSM-backed.**
- **Leaf: ECDSA P-256, ≤90 days, automated.**
- **Keep an RSA-2048 parallel hierarchy only if you have proven legacy clients** (Java 7, old Android, embedded appliances). Do not do this "just in case" — a dual hierarchy doubles every operational procedure.

ECDSA carries one hazard RSA does not: **nonce reuse is catastrophic**. Two signatures produced with the same `k` under the same key leak the private key by simple algebra. OpenSSL 3.x uses RFC 6979-style deterministic-plus-random nonce derivation, but any home-grown or embedded ECDSA signer is a liability. Ed25519 is deterministic by construction and immune to this class.

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

`ec_param_enc:named_curve` matters. The alternative, `explicit`, embeds the full curve parameters in every certificate — it bloats the cert, and several stacks (Go's `crypto/x509`, Java) refuse explicit-parameter EC keys outright.

Never leave a private key unencrypted on disk outside a controlled runtime path. Where the key *must* be readable by a daemon at boot, the answer is filesystem permissions plus a TPM/HSM, not a passphrase the operator types at 03:00.

---

## 4. PKI topology: how many tiers, and why

| Topology | Root exposure | Blast radius of an online-CA compromise | Recovery | Fit |
|---|---|---|---|---|
| **Single-tier** (root signs leaves directly) | Root key online, permanently | Total. Every client must have its trust store rebuilt. | Rebuild the entire estate. | Labs, throwaway clusters, single-node. Never production. |
| **Two-tier** (offline root → online issuing CA) | Root offline, powered on only for ceremonies | Bounded: revoke the intermediate via the root's CRL, issue a new intermediate, re-issue leaves. Trust store untouched. | Hours to days, no client change. | **The default.** Correct answer for ~95% of platforms. |
| **Three-tier** (root → policy CA → issuing CAs) | Root offline; policy CA offline | Bounded per issuing CA. Policy CA expresses distinct certificate policies / name constraints per business unit. | Same as two-tier, scoped narrower. | Multi-tenant PKI, regulated environments, cross-org federation. |
| **Cross-signed / bridge** | Multiple anchors | Depends on the graph | Complex — verifiers may build different paths | Mergers, root rollover, WebPKI compatibility windows. |

The economics of two-tier: the root's private key touches a powered-on, networked machine on the order of once a decade. The issuing CA is exposed continuously, so you assume it will eventually be compromised and you design the recovery path in advance. That recovery path — "revoke intermediate, mint a new one from the offline root, re-issue every leaf" — should be a rehearsed runbook with a measured RTO, not a theory.

**Name constraints turn delegation from a trust decision into a cryptographic one.** If you hand a sub-CA to another team, `nameConstraints` is what stops them (or their attacker) from minting `login.yourbank.com`. RFC 5280 requires it to be critical, so a compliant verifier that cannot enforce it refuses the chain.

The classic gap: **a name type absent from `permittedSubtrees` is unconstrained.** Constraining `DNS` does nothing to `iPAddress`, `rfc822Name`, `URI`, or `directoryName`. If a sub-CA should never issue IP SANs, you must explicitly exclude the entire IPv4 and IPv6 space.

---

## 5. Building a two-tier CA with OpenSSL — complete configuration

### 5.1 Directory layout

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

`index.txt.attr` with `unique_subject = no` is not optional in any environment where you re-issue for the same subject. Omit it and `openssl ca` creates it with `unique_subject = yes`, and your second issuance for `api.internal.example.io` fails with `TXT_DB error number 2`.

### 5.2 `/opt/pki/root/openssl-root.cnf` — complete

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

`pathlen:0` plus `nameConstraints` is the pair that makes an intermediate safe to hand to another team: it cannot create further CAs, and it cannot leave your DNS namespace.

### 5.3 Self-sign the root

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

> **OpenSSL 3.x note:** since 3.0 the Authority Key Identifier prints as a bare hex string; OpenSSL 1.1.1 printed `keyid:A1:3F:...`. Scripts that grep for `keyid:` break on upgrade.

A root that is its own issuer and its own subject, with a self-referential AKI, is a *trust anchor*: mathematically it proves nothing (anyone can self-sign), and its authority comes entirely from having been placed in a trust store out-of-band.

### 5.4 `/opt/pki/tls-ca/openssl-tls-ca.cnf` — the issuing CA, complete

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

### 5.5 Sign the intermediate from the offline root

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

Transfer the CSR to the offline root host (removable media, air gap, whatever your ceremony script says), then:

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

Verify the new intermediate before it ever signs anything:

```bash
$ openssl verify -CAfile ca/root-ca.crt.pem -x509_strict certs/tls-ca-e1.crt.pem
certs/tls-ca-e1.crt.pem: OK
```

`-x509_strict` disables RFC-violation workarounds. Run it on your own certificates in CI — it is the difference between "OpenSSL tolerates this" and "every other stack will too".

Build the distribution chain file (**issuing CA first, root last; the root is optional for TLS servers and included here only for trust-store distribution**):

```bash
$ cat certs/tls-ca-e1.crt.pem ca/root-ca.crt.pem > /opt/pki/dist/example-ca-chain.pem
$ openssl crl2pkcs7 -nocrl -certfile /opt/pki/dist/example-ca-chain.pem -out /opt/pki/dist/example-ca-chain.p7b
```

---

## 6. Issuing end-entity certificates

### 6.1 CSR generation (on the machine that will own the key)

The private key must never travel. Generate it where it will be used, send only the CSR.

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

The CSR is self-signed with the subject's own private key. That signature proves exactly one thing: **the requester possesses the private key matching the public key in the CSR.** It proves nothing about the requested names. Verifying identity is the CA's job (Registration Authority function) and is entirely outside the CSR.

### 6.2 Signing

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

Note the SAN issued (three entries) differs from the SAN requested (four, including the bare `api`) — because the profile injected `$ENV::SAN` from the CA operator's environment, not from the CSR. **That asymmetry is the security property.**

Also note the request's `IP:10.42.7.20` survived — which contradicts the root's `excluded;IP` name constraint. This is exactly the kind of mistake `-x509_strict` verification catches:

```bash
$ openssl verify -CAfile /opt/pki/root/ca/root-ca.crt.pem \
    -untrusted certs/tls-ca-e1.crt.pem certs/api.internal.example.io.crt.pem
C=AR, O=Example Platform Engineering, OU=Platform, CN=api.internal.example.io
error 47 at 0 depth lookup: permitted subtree violation
error certs/api.internal.example.io.crt.pem: verification failed
```

The certificate exists, the signature is valid, and it is unusable. That is name constraints working as designed. Fix the SAN, or widen the constraint at the root — the former, always.

### 6.3 `copy_extensions`: the trap

| Setting | Behaviour | Verdict |
|---|---|---|
| `copy_extensions = none` (default) | CSR extensions ignored entirely. CA profile is authoritative. | **Safe.** Requires the CA to source SANs out-of-band. |
| `copy_extensions = copy` | CSR extensions copied **unless** the same extension appears in the CA's `x509_extensions` profile, which wins. | Acceptable only if the profile explicitly pins `basicConstraints`, `keyUsage` and `extendedKeyUsage`, **and** the SAN is validated against policy before signing. |
| `copy_extensions = copyall` | Everything copied, including extensions the profile also defines. | **Never.** A CSR carrying `basicConstraints=critical,CA:TRUE` yields a working sub-CA. |

The `openssl ca` man page states this plainly, and it is a standard finding in PKI audits. If you enable `copy`, your issuance wrapper must parse the CSR's SAN and reject anything outside the requester's authorised namespace *before* invoking `openssl ca`.

### 6.4 `openssl ca` versus `openssl x509 -req`

| | `openssl ca` | `openssl x509 -req` |
|---|---|---|
| Serial management | `serial` file or `rand_serial` | `-CAserial` / `-CAcreateserial`, starts at a fixed value |
| Issuance database (`index.txt`) | Yes — required for CRLs and the OCSP responder | **No** |
| Revocation / CRL generation | Yes (`-revoke`, `-gencrl`) | No |
| DN policy enforcement | Yes (`policy_*`) | No |
| Extensions | Config profile, `copy_extensions` aware | `-extfile`/`-extensions`, or `-copy_extensions` (OpenSSL 3.0+) |
| Suitable for | Any CA whose certificates might need revoking | Throwaway test certs only |

If you cannot answer "which certificates has this CA ever issued?" you do not have a CA, you have a signing oracle. `openssl x509 -req` gives you a signing oracle.

### 6.5 Packaging for consumers

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

> `-noenc` is the OpenSSL 3.x spelling; `-nodes` is the deprecated alias and still works. If an old Java 8 or Windows consumer cannot open the file, it wants RC2/3DES from the legacy provider: add `-legacy` to the export. Do that only when you have proven the consumer cannot be upgraded.

### 6.6 System trust stores

| Distribution | Anchor directory | Refresh command | Consumers |
|---|---|---|---|
| Fedora / RHEL / CentOS | `/etc/pki/ca-trust/source/anchors/` | `update-ca-trust extract` | OpenSSL, GnuTLS, NSS, Java (via p11-kit) |
| Debian / Ubuntu | `/usr/local/share/ca-certificates/` (`.crt` only) | `update-ca-certificates` | OpenSSL, GnuTLS |
| SUSE | `/etc/pki/trust/anchors/` | `update-ca-certificates` | as above |
| Alpine | `/usr/local/share/ca-certificates/` | `update-ca-certificates` | OpenSSL |
| Any (per-directory) | arbitrary | `openssl rehash <dir>` | anything using `-CApath` |

```bash
$ sudo cp /opt/pki/root/ca/root-ca.crt.pem /etc/pki/ca-trust/source/anchors/example-root-ca.pem
$ sudo update-ca-trust extract
$ trust list --filter=ca-anchors | grep -A2 'Example Platform Root'
    label: Example Platform Root CA R1
    trust: anchor
    category: authority
```

`openssl rehash` (the modern replacement for the `c_rehash` Perl script) creates the `<subject_hash>.<n>` symlinks that `-CApath` lookup requires:

```bash
$ openssl rehash -v /etc/pki/tls/mytrust
Doing /etc/pki/tls/mytrust
link example-root-ca.pem -> 4f2a1c8e.0
```

Language runtimes do **not** all use the system store: Node.js bundles its own (`NODE_EXTRA_CA_CERTS`), Python `requests` uses `certifi` (`REQUESTS_CA_BUNDLE`), Go uses the system store on Linux but has `SSL_CERT_FILE`/`SSL_CERT_DIR` overrides, Java uses `$JAVA_HOME/lib/security/cacerts`. "It works with `curl` but not from the app" is nearly always this.

---

## 7. Revocation

### 7.1 The mechanisms and their honest trade-offs

| Mechanism | Freshness | Client cost | Privacy | Fails how | Reality in 2026 |
|---|---|---|---|---|---|
| **CRL** (RFC 5280) | Hours–days | Full list download; multi-MB for large CAs | Good (no per-cert query) | Soft-fail or stale | Baseline. Mandatory in Mozilla's program since 2024; the WebPKI has swung back to CRLs. |
| **Delta CRL** | Same base + increment | Small increments | Good | Same | Rarely deployed; complexity rarely pays. |
| **OCSP** (RFC 6960) | Minutes–hours | One round trip per cert, on the handshake path | **Poor** — responder learns who visits what | Soft-fail almost universally ⇒ ineffective against a network attacker | Being retired. Let's Encrypt shut down its responders in 2025 and no longer emits OCSP AIA URIs. |
| **OCSP stapling** (RFC 6066 `status_request`) | Server-controlled | Zero extra client round trips | Good | Server sends nothing ⇒ client falls back to soft-fail | Good practice; not enforceable without Must-Staple. |
| **Must-Staple** (RFC 7633, `1.3.6.1.5.5.7.1.24`) | As stapled | Zero | Good | **Hard-fail** — no staple, no connection | Correct security, dangerous ops. One responder outage = one outage. |
| **CRLite / browser push sets** | Hours | Zero at handshake | Excellent | N/A | Browser-only; not available to your services. |
| **Short lifetimes** | ≤ lifetime | Zero | Excellent | N/A | **The actual answer.** A 6-day certificate needs no revocation infrastructure. |

The strategic conclusion for a platform team: **treat revocation as a compliance artefact and lifetime reduction as the real control.** Publish a CRL because auditors and RFC 5280 require it; get your effective revocation window down by issuing 90-day (or shorter) certificates with automated renewal. Public CAs have made the same call — the CA/Browser Forum's ballot SC-081 schedule caps public TLS certificate lifetimes at 200 days from 2026-03-15, 100 days from 2027-03-15, and 47 days from 2029-03-15.

### 7.2 Revoking, and generating a CRL

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

Valid `-crl_reason` values: `unspecified`, `keyCompromise`, `CACompromise`, `affiliationChanged`, `superseded`, `cessationOfOperation`, `certificateHold`, `removeFromCRL`. Use them honestly — `keyCompromise` is the one that triggers incident response downstream, and CAs are required to react to it within tight deadlines.

The database after revocation:

```bash
$ cat db/index.txt
V	261116093102Z		2F88D1046B39AE57C2109F334E81B75	unknown	/C=AR/O=Example Platform Engineering/OU=Platform/CN=api.internal.example.io
R	261020081500Z	260818113005Z,keyCompromise	2F88D1046B39AE57C2109F334D2A0C13	unknown	/C=AR/O=Example Platform Engineering/OU=Platform/CN=legacy.internal.example.io
```

Columns: **status** (`V`alid / `R`evoked / `E`xpired), expiry (`YYMMDDHHMMSSZ`), revocation date and reason, serial (uppercase hex), filename, subject DN. This file *is* your CA — back it up with the same rigour as the private key. Lose it and you can no longer issue a truthful CRL.

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

**`nextUpdate` is a hard deadline, not a hint.** Once it passes, a verifier running `-crl_check` treats the CRL as unusable and fails closed with error 12. A CRL with `default_crl_days = 3` requires a *reliable* regeneration job at a much shorter interval than 3 days.

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

### 7.3 Checking revocation as a client

```bash
# CRL-based, whole chain
$ openssl verify -CAfile /opt/pki/dist/example-ca-chain.pem \
    -crl_check_all -CRLfile crl/tls-ca-e1.crl.pem -CRLfile /opt/pki/root/crl/root-ca.crl.pem \
    certs/legacy.internal.example.io.crt.pem
C=AR, O=Example Platform Engineering, OU=Platform, CN=legacy.internal.example.io
error 23 at 0 depth lookup: certificate revoked
error certs/legacy.internal.example.io.crt.pem: verification failed
```

`-crl_check` verifies only the leaf; `-crl_check_all` walks the entire chain. Use `-crl_check_all` — an unrevoked leaf under a revoked intermediate is worthless.

### 7.4 An OCSP responder

For lab work and for the exam, OpenSSL ships one:

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

Query it:

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

Two things to internalise. First, the OCSP `CertID` still uses **SHA-1** by default (RFC 6960 mandates SHA-1 for interoperability) — this is a collision-resistance-irrelevant use, but it surprises auditors every time. Second, `openssl ocsp` as a server is a **single-threaded reference implementation**; putting it on a production issuance path is how you turn a revocation check into an availability incident. Production means a real responder (Vault PKI, step-ca, EJBCA, or a static pre-signed-response CDN).

### 7.5 Stapling on the serving edge

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

`OCSP response: no response sent by server` means stapling is off, the responder was unreachable when nginx last refreshed, or — the most frequent cause — `ssl_trusted_certificate` is missing the root and `ssl_stapling_verify on` is silently rejecting the response. nginx logs it at warn level; check the error log rather than guessing.

---

## 8. Certificate Transparency

CT (RFC 6962) addresses the residual risk that survives everything above: **a trusted CA issuing a certificate it should not have.** Name constraints stop *your* delegated sub-CAs; nothing stops an unrelated public CA from issuing for your domain, whether by compromise, coercion, or clerical error. CT makes such issuance publicly and irreversibly visible.

The mechanism:

1. The CA builds a **precertificate**: the certificate it intends to issue, plus a critical **poison extension** (`1.3.6.1.4.1.11129.2.4.3`). Criticality guarantees no verifier will accept the precert as a real certificate.
2. It submits the precert to append-only, Merkle-tree-backed CT logs. Each log returns a **Signed Certificate Timestamp** (SCT) — a promise to include the entry within its Maximum Merge Delay.
3. The CA issues the real certificate with the SCTs embedded in extension `1.3.6.1.4.1.11129.2.4.2`.

Delivery alternatives exist (TLS `signed_certificate_timestamp` extension, or stapled in the OCSP response), but embedded SCTs dominate because they need no server support.

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

Chrome's CT policy requires publicly trusted certificates to carry SCTs from multiple qualified logs operated by **different organisations** (with an additional SCT required for longer-lived certificates); Apple enforces a comparable policy. A public certificate without adequate SCTs is rejected by the browser regardless of chain validity.

**Operationally, CT is a detection control you should be consuming.** Subscribe to CT feeds for your domains — via `crt.sh`, a commercial monitor, or your own `certspotter`-style watcher — and alert on any issuance not originating from your own pipeline. That alert is your only warning that a CA somewhere has minted a certificate for your namespace.

CT also has a privacy consequence worth designing around: **every hostname in a publicly trusted certificate becomes public**, permanently. Internal hostnames leak through CT logs constantly. Two mitigations: put internal names under your private PKI (this material's §5), or use wildcard certificates for internal-facing hosts so individual names are not enumerated.

---

## 9. ACME: issuance as an API

Manual PKI does not survive 90-day lifetimes, let alone 47-day ones. ACME (RFC 8555) is the standard that makes issuance a machine-to-machine protocol.

The flow: the client generates an **account key** (distinct from any certificate key) and registers; it requests an **order** for a set of identifiers; the server returns **authorizations**, each with **challenges**; the client provisions the challenge response and asks the server to validate; on success the order becomes `ready`, the client **finalizes** by POSTing a CSR, and downloads the certificate.

### 9.1 Challenge types

| Challenge | Proof surface | Port / record | Wildcards | Fails when | Best for |
|---|---|---|---|---|---|
| **HTTP-01** | `http://<domain>/.well-known/acme-challenge/<token>` returning `<token>.<thumbprint>` | TCP 80 inbound from the CA | ❌ | Host is not internet-reachable on :80; CDN or WAF intercepts the path | Single internet-facing host |
| **DNS-01** | TXT record at `_acme-challenge.<domain>` containing base64url(SHA-256(`<token>.<thumbprint>`)) | DNS | ✅ **only option for wildcards** | No DNS provider API; slow propagation; the API credential is a domain-takeover-grade secret | Wildcards, internal hosts, load-balanced fleets |
| **TLS-ALPN-01** (RFC 8737) | TLS on :443 with ALPN `acme-tls/1`, self-signed cert carrying `acmeIdentifier` (`1.3.6.1.5.5.7.1.31`) | TCP 443 inbound | ❌ | Terminating proxy cannot be made ALPN-aware | Hosts where :80 is closed by policy |

TLS-SNI-01 and -02 were killed in 2019: on shared-hosting platforms an attacker who could upload a certificate for an arbitrary SNI could pass validation for a domain they did not control. The lesson generalises — **a challenge is only as strong as the weakest thing that can answer for the identifier**, which is exactly why DNS-01 API credentials must be scoped to `_acme-challenge` records only.

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

Always point your web server at the **`live/` symlinks**, never at `archive/`. Renewal writes `cert2.pem` and re-points the symlink; a config pinned to `cert1.pem` silently keeps serving the old certificate until it expires.

Wildcard via DNS-01, and a rehearsal of renewal:

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

`--dry-run` hits the staging endpoint and does not consume rate limits. Run it in CI. The deploy hook is the piece teams forget: a renewed file that nothing reloads is an expired certificate on the wire.

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

### 9.3 ACME client comparison

| Client | Language / deps | Runs as root? | DNS providers | Strong point |
|---|---|---|---|---|
| **certbot** | Python, plugins | usually | ~30 via plugins | Reference implementation; distro-packaged; best documented |
| **acme.sh** | POSIX shell | no (can run unprivileged) | 150+ | Zero runtime deps; ideal for containers and appliances |
| **lego** | Go, single binary | no | 100+ | Library + CLI; embeds cleanly into Go services |
| **cert-manager** | Go, Kubernetes controller | n/a | via solvers | Declarative; the Kubernetes-native answer |
| **step-cli / step-ca** | Go | no | own ACME server | Lets you run *your own* ACME server for internal PKI |
| **Caddy** | Go webserver | no | built-in | Automatic HTTPS with no separate client at all |

For an enterprise CA speaking ACME, **External Account Binding** ties an ACME account to a pre-existing enterprise identity:

```bash
$ certbot register \
    --server https://acme.corp-ca.example.io/directory \
    --eab-kid 'kid-4f2a1c8e' \
    --eab-hmac-key 'zWmNq2...base64url...' \
    -m pki@example.io --agree-tos
```

### 9.4 An internal ACME server — step-ca

The best of both worlds for a private PKI: your own root, and ACME automation.

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

A one-week default lifetime with fully automated renewal makes CRL and OCSP infrastructure operationally irrelevant for that tier — which is the whole point.

---

## 10. Declarative PKI in Kubernetes

### 10.1 cert-manager — complete manifests

Bootstrap your existing offline-root hierarchy into the cluster as a CA issuer:

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

### 10.2 The Kubernetes CertificateSigningRequest API

Kubernetes has a native CA of its own, driven by `certificates.k8s.io/v1`. It is how kubelets bootstrap and rotate their credentials, and it is a legitimate way to mint operator kubeconfigs.

```bash
$ openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out sre-alice.key.pem
$ openssl req -new -key sre-alice.key.pem \
    -subj "/O=platform-sre/O=readonly/CN=alice" -out sre-alice.csr.pem
$ base64 -w0 sre-alice.csr.pem
LS0tLS1CRUdJTiBDRVJUSUZJQ0FURSBSRVFVRVNULS0tLS0KTUlIcU1JR1JBZ0VBTURB...
```

`O=` becomes the group and `CN=` becomes the username in Kubernetes RBAC. That mapping is why a CA trusted by the API server is equivalent to cluster-admin unless it is name-constrained or scoped.

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

| `signerName` | Signed by | Permitted usages | Purpose |
|---|---|---|---|
| `kubernetes.io/kube-apiserver-client` | cluster CA | `client auth` | Human and controller kubeconfigs |
| `kubernetes.io/kube-apiserver-client-kubelet` | cluster CA | `client auth` | Kubelet bootstrap and rotation (auto-approved by a controller) |
| `kubernetes.io/kubelet-serving` | cluster CA | `server auth` | Kubelet HTTPS serving certs; **never auto-approved** |
| `kubernetes.io/legacy-unknown` | cluster CA | any | Deprecated; disabled by default in modern releases |

**These certificates cannot be revoked.** Kubernetes has no CRL and no OCSP; a leaked client certificate is valid until `notAfter`. The only remediations are rotating the entire cluster CA (disruptive) or making the identity's RBAC bindings inert. Keep `expirationSeconds` short and treat client certs as second choice to OIDC for human access.

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

One-year control-plane certificates renewed only by `kubeadm upgrade` are the most common cause of "the cluster went away overnight" on long-lived clusters. Put a calendar-independent alert on this output.

### 10.3 Vault PKI as the issuing tier

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

The role is the policy object: it enforces the namespace, the algorithm, the key usages and the TTL ceiling **server-side**, so a compromised application credential still cannot mint `*.example.io` or a 10-year certificate. That is the same control as `nameConstraints`, expressed at the API layer instead of in the certificate.

---

## 11. Verification and failure diagnosis

### 11.1 The verification ladder — run all of it in CI

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

A healthy `s_client`:

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

`Verification: OK` is what you assert on. Note also `Certificate chain` listing exactly two entries — leaf and intermediate. If entry 2 is the root, you are wasting bytes on every handshake; if entry 1 is missing, you have an error-20 incident waiting for the first client with a cold cache.

**`-servername` is not optional.** Without it OpenSSL sends no SNI and a virtual-hosted server returns its default certificate — producing a "hostname mismatch" that does not exist for real clients, and hiding a real one that does.

### 11.2 `openssl verify` error codes — the field reference

| # | Symbol / message | Root cause | Fix |
|---|---|---|---|
| 2 | `unable to get issuer certificate` | Issuer of an intermediate is absent from `-CAfile`/`-CApath` | Add the missing CA |
| 3 | `unable to get certificate CRL` | `-crl_check` on, no CRL supplied for some CA in the chain | Supply every CA's CRL (concatenate them) |
| 7 | `certificate signature failure` | Signature does not verify — corrupted file, or a forgery | Re-fetch; if it persists, escalate |
| 9 | `certificate is not yet valid` | `notBefore` in the future — almost always **client clock skew** | Fix NTP before touching the PKI |
| 10 | `certificate has expired` | `notAfter` passed | Renew. Then fix why renewal did not happen. |
| 12 | `CRL has expired` | `nextUpdate` passed | Regenerate and republish the CRL |
| 18 | `self-signed certificate` | The leaf itself is self-signed | Issue from a CA, or add it as an anchor deliberately |
| 19 | `self-signed certificate in certificate chain` | The server sent its root and the verifier does not trust it | Install the root in the trust store; stop sending it |
| 20 | `unable to get local issuer certificate` | **The server did not send the intermediate.** The #1 real-world TLS bug. | Serve leaf + intermediate (`fullchain.pem`) |
| 21 | `unable to verify the first certificate` | Only the leaf was sent and no path exists | Same as 20 |
| 23 | `certificate revoked` | It is revoked. | Issue a new one; investigate why it was revoked |
| 24 | `invalid CA certificate` | An issuer lacks `basicConstraints CA:TRUE` | Re-issue the intermediate with the right profile |
| 26 | `unsupported certificate purpose` | EKU does not permit the requested role (`-purpose sslserver` against a `clientAuth`-only cert) | Correct the issuance profile |
| 32 | `key usage does not include certificate signing` | Intermediate lacks `keyCertSign` | Re-issue the intermediate |
| 47 | `permitted subtree violation` | A SAN falls outside the CA's `nameConstraints` | Correct the SAN, or widen the constraint at the root |
| 48 | `excluded subtree violation` | A SAN falls inside an excluded subtree | Same |
| 62 | `hostname mismatch` | No SAN entry matches the name; CN alone no longer counts | Add the name to the SAN and re-issue |

### 11.3 Six incidents and their signatures

**Missing intermediate (error 20).** Works in your browser (which cached the intermediate from another site, or chased AIA), fails in `curl`, Go, and Java.

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
Fix: `ssl_certificate` must point at `fullchain.pem`, not `cert.pem`. This is the single most common consequence of pointing nginx at certbot's `cert.pem`.

**Chain in the wrong order.** RFC 8446 requires the sender's certificate first, each subsequent one certifying the previous. Some stacks reorder; many do not.
```bash
$ awk '/BEGIN CERT/{n++} {print > ("/tmp/c" n ".pem")}' fullchain.pem
$ for f in /tmp/c*.pem; do openssl x509 -in $f -noout -subject -issuer; done
subject=CN=Example Platform TLS Issuing CA E1     # <- CA first: WRONG
issuer=CN=Example Platform Root CA R1
subject=CN=api.internal.example.io
issuer=CN=Example Platform TLS Issuing CA E1
```

**Clock skew (error 9).** Before diagnosing a PKI, check the clock:
```bash
$ timedatectl status | grep -E 'System clock|NTP service'
         System clock synchronized: no
              NTP service: inactive
```
Every "certificate is not yet valid" on a freshly imaged host is this.

**Fedora/RHEL crypto-policies rejecting a legacy CA.** The system-wide policy, not OpenSSL, is refusing SHA-1 signatures or sub-2048-bit RSA:
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
This is a temporary bridge. Log the exception with an expiry date; do not let it become the permanent posture.

**`openssl ca` refusing to issue.**
```bash
$ openssl ca -config openssl-tls-ca.cnf -in dup.csr.pem -out dup.crt.pem
...
ERROR:There is already a certificate for /C=AR/O=Example Platform Engineering/CN=api.internal.example.io
```
→ `db/index.txt.attr` says `unique_subject = yes`. Set it to `no`.

```bash
The organizationName field is different between
CA certificate (Example Platform Engineering) and the request (Example Platform Eng.)
```
→ `policy_strict` requires `match` on `organizationName`. Either fix the CSR's DN or relax the policy — never edit `index.txt` by hand to work around it.

```bash
$ openssl ca -config openssl-tls-ca.cnf -gencrl -out crl.pem
...
unable to load CRL number
```
→ `db/crlnumber` is missing or malformed. It must contain an even-length hex string, e.g. `1000`.

**mTLS failing with CRLs enabled in nginx.**
```
SSL_do_handshake() failed (SSL: error:0A000418:SSL routines::tlsv1 alert unknown ca)
... client SSL certificate verify error: (3:unable to get certificate CRL)
```
→ `ssl_crl` must contain a **current, unexpired** CRL for *every* CA in the client's chain, including the root. Concatenate them and rebuild the file from the same timer that regenerates the CRLs.

### 11.4 Expiry monitoring is non-negotiable

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

A quick fleet-wide sweep without any exporter:

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

## 12. Securing the CA itself

The certificates a CA issues are only as trustworthy as the CA's own operational security. Ranked by effectiveness:

| Control | What it stops | Cost |
|---|---|---|
| **Root key in an HSM / offline** | Key exfiltration; undetectable forgery | Hardware + ceremony discipline |
| **Two-tier with a `pathlen:0`, name-constrained intermediate** | An online-CA compromise becoming a namespace-wide compromise | Design effort only |
| **Short leaf lifetimes + automation** | Expiry outages *and* makes revocation gaps irrelevant | Automation build-out |
| **Issuance profiles as code, `copy_extensions = none`** | Privilege escalation via a crafted CSR | Config discipline |
| **Append-only, monitored issuance log** | Silent rogue issuance | Log pipeline |
| **CT monitoring for your own domains** | Third-party CA mis-issuance | Feed subscription |
| **Separated roles (RA approves ≠ CA signs)** | Single-operator compromise | Process |

Private-key protection in practice, weakest to strongest:

1. Passphrase-encrypted PEM on disk — the passphrase must be typed. Only defensible for a genuinely offline root.
2. `systemd-creds` encrypted credentials bound to the TPM — usable for an unattended intermediate on a single host.
3. PKCS#11 token (YubiHSM 2, Nitrokey HSM, SoftHSM for lab work) — the key is non-exportable.
4. Network HSM or cloud KMS (Thales/Luna, AWS CloudHSM, GCP Cloud KMS) — non-exportable, audited, quorum-controlled.

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

`CKA_NEVER_EXTRACTABLE` is the property the whole design rests on: the key has never existed outside the module, so "back up the root key" is replaced by "provision a quorum of key custodians" — a different, and better, problem.

**Key ceremony minimum viable script:** two operators present, an air-gapped machine booted from read-only media, video record, generate on the HSM, print and split the recovery shares (Shamir, k-of-n), sign the intermediate, verify the signature on a second machine, log serial numbers and SHA-256 fingerprints in a tamper-evident record, power down. If your root is not in an HSM, at minimum the key material and the passphrase must be held by different people in different safes.

---

## 13. Objective coverage — 331.1 checklist

| Objective element | Section | Commands you must be able to produce from memory |
|---|---|---|
| X.509 certificate structure, fields, v3 extensions | §2 | `openssl x509 -in c.pem -noout -text -ext subjectAltName`, `openssl asn1parse` |
| Certificate lifecycle | §5–§7, §9 | `openssl req`, `openssl ca`, `openssl ca -revoke`, `openssl ca -gencrl` |
| Trust chains and PKI | §4, §5, §11 | `openssl verify -CAfile -untrusted`, `openssl s_client -showcerts` |
| Certificate Transparency | §8 | `openssl x509 -noout -ext ct_precert_scts` |
| Generate and manage keys | §3 | `openssl genpkey`, `openssl rsa/ec/pkey`, `openssl pkey -pubout` |
| Create, operate, secure a CA | §5, §12 | full `openssl.cnf`, `index.txt`, `serial`, `crlnumber` semantics |
| Request, sign, manage server & client certs | §6 | `openssl req -new -addext`, `openssl ca -extensions`, `openssl pkcs12 -export` |
| Revoke certificates and CAs | §7 | `openssl ca -revoke -crl_reason`, `openssl crl`, `openssl ocsp` |
| PEM / DER / PKCS formats | §2.3 | `openssl x509 -inform DER -outform PEM`, `openssl pkcs12`, `openssl crl2pkcs7` |
| ACME awareness | §9 | `certbot certonly`, `certbot renew --dry-run`, challenge types |
| OpenSSL configuration | §5.2, §5.4 | `[ca]`, `[CA_default]`, `[req]`, `policy_*`, `copy_extensions`, `x509_extensions` |

Format conversions worth drilling:

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

Inspection one-liners:

```bash
$ openssl x509 -in c.pem -noout -fingerprint -sha256
sha256 Fingerprint=3A:6F:...:D2
$ openssl x509 -in c.pem -noout -serial -subject -issuer -dates -purpose
$ openssl x509 -in c.pem -noout -modulus | openssl sha256      # RSA key matching
$ openssl x509 -in c.pem -pubkey -noout | openssl pkey -pubin -outform DER \
    | openssl dgst -sha256 -binary | base64                    # SPKI pin (any algorithm)
```

---

## 14. Consolidated decision guide

| Situation | Do this | Not this |
|---|---|---|
| Internet-facing TLS | Public CA via ACME, ≤90 days, automated renewal + deploy hook, CT-monitored | A manually renewed 1-year certificate |
| Service-to-service inside a cluster | Private two-tier CA driven by cert-manager or SPIFFE/SPIRE, hours-to-days lifetime | Self-signed certs with verification disabled |
| Handing a CA to another team | Name-constrained, `pathlen:0` intermediate, or a Vault role with `allowed_domains` | An unconstrained sub-CA |
| Client authentication | Short-lived `clientAuth`-only certs, or OIDC where the platform supports it | Long-lived client certs with no revocation path |
| Legacy appliance requiring RSA-2048/SHA-256 | Isolated parallel hierarchy with a documented sunset date | Downgrading the whole estate's crypto policy |
| Revocation requirement from audit | Publish CRLs on a timer, hard-fail where you control both ends, and reduce lifetime | OCSP soft-fail and calling it a control |
| Root key storage | HSM, offline, quorum-controlled, ceremony-recorded | Encrypted PEM on the CI runner |

The through-line: **X.509 is not hard because the cryptography is hard — it is hard because it encodes long-lived, delegated authority in a distributed system where nothing can be taken back.** Every good practice above is a variation on one principle: shrink the window during which a mistake stays true, and cryptographically bound what any single mistake can assert.

---

## 15. References

**LPI**
- Exam 303-300 objectives (LPIC-3 Security): https://www.lpi.org/our-certifications/exam-303-objectives/
- LPIC-3 Security overview: https://www.lpi.org/our-certifications/lpic-3-303-overview/

**IETF standards**
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

**OpenSSL 3.x manual pages**
- `openssl-req`: https://docs.openssl.org/master/man1/openssl-req/
- `openssl-ca`: https://docs.openssl.org/master/man1/openssl-ca/
- `openssl-x509`: https://docs.openssl.org/master/man1/openssl-x509/
- `openssl-verify` and verification errors: https://docs.openssl.org/master/man1/openssl-verify/
- `openssl-genpkey`: https://docs.openssl.org/master/man1/openssl-genpkey/
- `openssl-crl` / `openssl-ocsp`: https://docs.openssl.org/master/man1/openssl-crl/ · https://docs.openssl.org/master/man1/openssl-ocsp/
- `openssl-pkcs12`: https://docs.openssl.org/master/man1/openssl-pkcs12/
- `openssl-s_client`: https://docs.openssl.org/master/man1/openssl-s_client/
- `x509v3_config` (extension syntax): https://docs.openssl.org/master/man5/x509v3_config/
- `config` (OpenSSL configuration file format): https://docs.openssl.org/master/man5/config/

**CA/Browser Forum and CA policy**
- Baseline Requirements for TLS Server Certificates: https://cabforum.org/working-groups/server/baseline-requirements/documents/
- Ballot SC-081v3 (validity-period reduction schedule): https://cabforum.org/2025/04/11/ballot-sc081v3-introduce-schedule-of-reducing-validity-and-data-reuse-periods/
- Mozilla Root Store Policy: https://www.mozilla.org/en-US/about/governance/policies/security-group/certs/policy/
- Chromium Certificate Transparency Policy: https://googlechrome.github.io/CertificateTransparency/ct_policy.html

**ACME and clients**
- Let's Encrypt — how it works: https://letsencrypt.org/how-it-works/
- Let's Encrypt — challenge types: https://letsencrypt.org/docs/challenge-types/
- Let's Encrypt — ending OCSP support: https://letsencrypt.org/2024/07/23/replacing-ocsp-with-crls/
- Certbot documentation: https://eff-certbot.readthedocs.io/en/stable/
- acme.sh: https://github.com/acmesh-official/acme.sh
- lego: https://go-acme.github.io/lego/
- step-ca (private ACME server): https://smallstep.com/docs/step-ca/

**Kubernetes and platform tooling**
- Managing TLS Certificates in a Cluster: https://kubernetes.io/docs/tasks/tls/managing-tls-in-a-cluster/
- Certificate Signing Requests (`certificates.k8s.io`): https://kubernetes.io/docs/reference/access-authn-authz/certificate-signing-requests/
- Certificate Management with kubeadm: https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-certs/
- cert-manager documentation: https://cert-manager.io/docs/
- HashiCorp Vault PKI secrets engine: https://developer.hashicorp.com/vault/docs/secrets/pki

**Distribution trust stores**
- Fedora/RHEL shared system certificates: https://docs.fedoraproject.org/en-US/quick-docs/using-shared-system-certificates/
- Red Hat system-wide crypto policies: https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/security_hardening/using-the-system-wide-cryptographic-policies_security-hardening
- Debian `update-ca-certificates`: https://manpages.debian.org/stable/ca-certificates/update-ca-certificates.8.en.html
- p11-kit trust module: https://p11-glue.github.io/p11-glue/p11-kit.html

**Server configuration**
- nginx `ngx_http_ssl_module`: https://nginx.org/en/docs/http/ngx_http_ssl_module.html
- Mozilla SSL Configuration Generator: https://ssl-config.mozilla.org/

**Certificate Transparency ecosystem**
- Certificate Transparency project: https://certificate.transparency.dev/
- crt.sh log search: https://crt.sh/