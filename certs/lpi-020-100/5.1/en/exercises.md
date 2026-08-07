# LPI Security Essentials (Exam 020-100) — Topic 5.1: Identity and Privacy

### Official Reference Documentation
- **LPI Security Essentials Overview**: [https://www.lpi.org/our-certifications/security-essentials-overview/](https://www.lpi.org/our-certifications/security-essentials-overview/)
- **RFC 6238 (TOTP: Time-Based One-Time Password Algorithm)**: [https://datatracker.ietf.org/doc/html/rfc6238](https://datatracker.ietf.org/doc/html/rfc6238)
- **RFC 6749 (The OAuth 2.0 Authorization Framework)**: [https://datatracker.ietf.org/doc/html/rfc6749](https://datatracker.ietf.org/doc/html/rfc6749)
- **OpenID Connect Core 1.0 specification**: [https://openid.net/specs/openid-connect-core-1_0.html](https://openid.net/specs/openid-connect-core-1_0.html)
- **RFC 8484 (DNS Queries over HTTPS - DoH)**: [https://datatracker.ietf.org/doc/html/rfc8484](https://datatracker.ietf.org/doc/html/rfc8484)
- **RFC 7519 (JSON Web Token - JWT)**: [https://datatracker.ietf.org/doc/html/rfc7519](https://datatracker.ietf.org/doc/html/rfc7519)

---

## Technical Architecture & Core Principles

### 1. AAA Framework & Authentication Mechanics
Modern security architecture relies on the AAA model:
- **Authentication (AuthN)**: Verification of identity claims.
- **Authorization (AuthZ)**: Access grant validation based on authenticated identity and policies (RBAC/ABAC).
- **Accounting**: Audit logging of identity actions, timestamps, and resource consumption.

Authentication factors are categorized into three distinct domains:
1. **Knowledge Factor** (*Something you know*): Passwords, passphrases, PINs. Vulnerable to brute-force, credential stuffing, and social engineering.
2. **Possession Factor** (*Something you have*): Hardware security keys (FIDO2/WebAuthn), TOTP software authenticators (RFC 6238), TLS client certificates, smart cards.
3. **Inherence Factor** (*Something you are*): Biometric markers (fingerprint scan, facial recognition).

#### Multi-Factor Authentication (MFA) Algorithms
- **HOTP (HMAC-Based One-Time Password, RFC 4226)**: Counter-based authentication where $HOTP(K, C) = Truncate(HMAC-SHA-1(K, C))$.
- **TOTP (Time-Based One-Time Password, RFC 6238)**: Uses current epoch time $T$ as a moving factor: $T = \lfloor \frac{CurrentTime - T_0}{X} \rfloor$, where $X$ is the time step duration (default 30s). $TOTP(K, T) = HOTP(K, T)$.

```
+-----------------------------------------------------------------------------------+
|                                 TOTP Generation                                  |
|                                                                                   |
|  [ Current Unix Time (T) ] ---> [ Slice into 30s Windows ] ---> T = floor(T/30)   |
|                                                                        |          |
|  [ Shared Secret Key (K) ] --------------------------------------------+          |
|                                                                        v          |
|                                                          [ HMAC-SHA-1 Engine ]    |
|                                                                        |          |
|                                                                        v          |
|  [ 6-Digit Output Code ] <--- [ Dynamic Truncation (Mod 10^6) ] <------+          |
+-----------------------------------------------------------------------------------+
```

---

### 2. Enterprise Linux Pluggable Authentication Modules (PAM)
In Linux distributions, PAM decouples applications from underlying authentication backends. PAM configuration files reside in `/etc/pam.d/`.

PAM rules follow this syntax:
`module_type control_flag module_path module_arguments`

- **Module Types**: `auth` (validates identity), `account` (checks password expiration, access restrictions), `password` (handles updates), `session` (manages user environment pre/post login).
- **Control Flags**:
  - `required`: Must succeed. Stack processing continues even on failure.
  - `requisite`: Must succeed. Immediately terminates stack on failure.
  - `sufficient`: If succeeded and no prior `required` modules failed, immediately grants access.
  - `optional`: Success/failure ignored unless it is the only module in the stack.

---

### 3. Federated Identity & Protocols (OAuth 2.0, OIDC, JWT)
- **OAuth 2.0 (RFC 6749)**: An authorization framework enabling a third-party application to obtain limited access to an HTTP service on behalf of a resource owner.
- **OpenID Connect (OIDC)**: Identity layer built on top of OAuth 2.0. Introduces the `id_token`, a cryptographically signed JSON Web Token (JWT).

#### JWT Structure
A JWT consists of three Base64URL-encoded strings separated by dots:
$$\text{JWT} = \text{Base64URL}(\text{Header}) \,.\, \text{Base64URL}(\text{Payload}) \,.\, \text{Base64URL}(\text{Signature})$$

```
+-----------------------------------------------------------------------------------+
|                                 JWT Anatomy                                       |
|                                                                                   |
|  eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9  <-- Header (Algorithm & Token Type)       |
|  .                                                                                |
|  eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IC... <-- Payload (Claims: sub, iss, exp)   |
|  .                                                                                |
|  SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQ... <-- Signature (RS256 Private Key Sign)  |
+-----------------------------------------------------------------------------------+
```

---

### 4. Secure Communication & Privacy Protections
- **Public Key Infrastructure (PKI) & SSH CAs**: Replaces static `~/.ssh/authorized_keys` with dynamic SSH Certificate Authorities. Short-lived signed SSH certificates bind user identity (`principals`) to public keys.
- **OpenPGP & Web of Trust**: Asymmetric encryption scheme combining symmetric payload encryption (AES-256) with asymmetric key encapsulation (RSA or Ed25519/X25519).
- **DNS Privacy (DoH & DoT)**:
  - Plaintext DNS (UDP/53) exposes domain lookup metadata to network observers.
  - **DNS-over-TLS (DoT, RFC 7858)**: Encapsulates DNS inside TLS over TCP port 853.
  - **DNS-over-HTTPS (DoH, RFC 8484)**: Encapsulates DNS wire-format messages in HTTP/2 or HTTP/3 POST requests over TCP/443, blending DNS queries into encrypted web traffic.

---

## Hands-On Guided Lab Exercises

### Exercise 1: Linux PAM Stack Hardening & Multi-Factor Authentication Engine

#### Step 1: Audit existing PAM SSH configuration
Inspect `/etc/pam.d/sshd` to understand module processing logic.

```bash
sudo cat /etc/pam.d/sshd
```

*Expected Output:*
```text
#%PAM-1.0
auth       subscribed   pam_env.so
auth       requisite    pam_faillock.so preauth audit deny=3 unlock_time=900
auth       sufficient   pam_unix.so nullok try_first_pass
auth       required     pam_faillock.so authfail audit deny=3 unlock_time=900
auth       required     pam_deny.so
account    required     pam_nologin.so
account    include      common-account
password   include      common-password
session    optional     pam_motd.so prepare
session    include      common-session
```

#### Step 2: Configure PAM Account Lockout & Google Authenticator TOTP
Create a production PAM stack configuration manifest for locked authentication with TOTP enforcement in `/etc/pam.d/sshd-mfa-secured`.

```bash
sudo tee /etc/pam.d/sshd-mfa-secured > /dev/null <<'EOF'
# /etc/pam.d/sshd-mfa-secured - Production Multi-Factor Authentication Stack
# Type      Control     Module Path                  Arguments

# Phase 1: Account Lockout Check (Pre-auth)
auth        requisite   pam_faillock.so              preauth dir=/var/log/faillock deny=3 unlock_time=600 audit

# Phase 2: Primary Unix Password Verification
auth        required    pam_unix.so                  try_first_pass nullok

# Phase 3: Secondary Factor (TOTP RFC 6238) Verification
auth        required    pam_google_authenticator.so   secret=/var/lib/google-authenticator/${USER}/.google_authenticator echo_verification_code nullok

# Phase 4: Account Status Verification
account     required    pam_faillock.so
account     required    pam_unix.so

# Phase 5: Session Management
session     required    pam_limits.so
session     required    pam_unix.so
EOF
```

Verify permissions and syntax:
```bash
sudo chmod 644 /etc/pam.d/sshd-mfa-secured
ls -l /etc/pam.d/sshd-mfa-secured
```

*Expected Output:*
```text
-rw-r--r-- 1 root root 782 Aug  7 00:55 /etc/pam.d/sshd-mfa-secured
```

#### Step 3: Test PAM authentication stack using `pamtester` and audit logs
Simulate password and MFA authentication programmatically using `pamtester` (install if needed via `apt-get install pamtester` or compile).

```bash
sudo pamtester sshd-mfa-secured root authenticate
```

*Expected Output:*
```text
Password: 
Verification code: 
pamtester: successfully authenticated
```

Inspect security events logged by `pam_faillock` and the auth subsystem:
```bash
sudo faillock --user root
```

*Expected Output:*
```text
root:
When                Type  Source                           Valid
2026-08-07 00:56:12 R     192.168.1.50                         V
```

---

#### Comprehension Questions — Exercise 1
1. Why is `pam_faillock.so` declared twice in the `auth` stack (first with `preauth` and second with `authfail`)?
2. If `pam_unix.so` is configured with `sufficient` instead of `required` in a PAM stack, what impact does this have on subsequent modules like `pam_google_authenticator.so`?

---

### Exercise 2: OpenID Connect Identity Tokens & Cryptographic Verification

#### Step 1: Generate an RSA Keypair and Construct a Signed JWT Identity Token
Use OpenSSL to generate an RSA 2048-bit keypair representing an OIDC Identity Provider (IdP) signing key.

```bash
# Generate IdP Private Key
openssl genpkey -algorithm RSA -out idp_private.pem -pkeyopt rsa_keygen_bits:2048

# Extract IdP Public Key
openssl rsa -pubout -in idp_private.pem -out idp_public.pem
```

*Expected Output:*
```text
:: Generating RSA private key, 2048 bit long modulus (2 primes)
e is 65537 (0x010001)
writing RSA key
```

Create an un-signed JWT header and payload manifest file named `jwt_payload.json`.

```json
{
  "iss": "https://auth.enterprise.internal/auth/realms/production",
  "sub": "usr-8f92a411-b0e2-4a7b-a119-9c8827da481f",
  "aud": "sre-platform-api",
  "exp": 1786147200,
  "iat": 1786143600,
  "preferred_username": "sre.admin",
  "email": "sre.admin@enterprise.internal",
  "roles": [
    "platform-admin",
    "security-auditor"
  ]
}
```

#### Step 2: Assemble and Sign the OIDC JWT via Bash & OpenSSL
Construct the Base64URL-encoded JWT signature using SHA-256 and the IdP RSA private key.

```bash
# Encode Header
HEADER_B64=$(echo -n '{"alg":"RS256","typ":"JWT","kid":"idp-key-2026"}' | openssl base64 -e -A | tr -d '=' | tr '/+' '_-')

# Encode Payload
PAYLOAD_B64=$(cat jwt_payload.json | openssl base64 -e -A | tr -d '=' | tr '/+' '_-')

# Create Signature
SIGNATURE_B64=$(echo -n "${HEADER_B64}.${PAYLOAD_B64}" | openssl dgst -sha256 -sign idp_private.pem | openssl base64 -e -A | tr -d '=' | tr '/+' '_-')

# Assemble full OIDC Token
ID_TOKEN="${HEADER_B64}.${PAYLOAD_B64}.${SIGNATURE_B64}"
echo "Constructed ID Token: ${ID_TOKEN}"
```

*Expected Output:*
```text
Constructed ID Token: eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCIsImtpZCI6ImlkcC1rZXktMjAyNiJ9.ZXlKM2RYSnBi...
```

#### Step 3: Cryptographically verify token signature with the Public Key
Extract payload and verify signature integrity against `idp_public.pem`.

```bash
# Extract signature binary from token
echo -n "${SIGNATURE_B64}" | tr '_-' '/+' | awk '{ v=length % 4; if (v==2) print $0"=="; else if (v==3) print $0"="; else print $0; }' | openssl base64 -d -A > token_sig.bin

# Cryptographic Verification
echo -n "${HEADER_B64}.${PAYLOAD_B64}" | openssl dgst -sha256 -verify idp_public.pem -signature token_sig.bin
```

*Expected Output:*
```text
Verified OK
```

---

#### Comprehension Questions — Exercise 2
1. In OIDC workflows, what is the architectural difference between the `id_token` and an `access_token`?
2. How does the `kid` (Key ID) header field in a JWT protect an API Gateway or Relying Party during identity key rotation?

---

### Exercise 3: Public-Key Cryptography, SSH Certificates, and OpenPGP Web of Trust

#### Step 1: Provision an SSH Certificate Authority (CA) and User Keypair
Generate an isolated SSH CA key and a target user identity key.

```bash
# Generate CA Key
ssh-keygen -t ed25519 -f ssh_ca_key -C "Production-SSH-CA" -N ""

# Generate User Identity Keypair
ssh-keygen -t ed25519 -f user_ed25519 -C "devops.engineer@enterprise.internal" -N ""
```

*Expected Output:*
```text
Generating public/private ed25519 key pair.
Your identification has been saved in ssh_ca_key
Your public key has been saved in ssh_ca_key.pub
Generating public/private ed25519 key pair.
Your identification has been saved in user_ed25519
Your public key has been saved in user_ed25519.pub
```

#### Step 2: Sign User Key with SSH CA and Apply Principals/Validity Constraints
Issue a signed SSH user certificate restricted to `principals` (allowed usernames) and valid for 1 hour (`+1h`).

```bash
ssh-keygen -s ssh_ca_key -I "cert-devops-001" -n "ubuntu,devops" -V +1h user_ed25519.pub
```

*Expected Output:*
```text
Signed user key user_ed25519-cert.pub: id "cert-devops-001" serial 0 valid forever to primitives
```

Inspect the cryptographic details of the generated certificate:
```bash
ssh-keygen -Lf user_ed25519-cert.pub
```

*Expected Output:*
```text
user_ed25519-cert.pub:
        Type: ssh-ed25519-cert-v01@openssh.com user certificate
        Public key: ED25519-CERT SHA256:8sK9x...
        Signing CA: ED25519 SHA256:pQ3vX... (Production-SSH-CA)
        Key ID: "cert-devops-001"
        Serial: 0
        Valid: from 2026-08-07T00:50:00 to 2026-08-07T01:50:00
        Principals: 
                ubuntu
                devops
        Critical Options: (none)
        Extensions: 
                permit-X11-forwarding
                permit-agent-forwarding
                permit-port-forwarding
                permit-pty
                permit-user-rc
```

#### Step 3: OpenPGP Keyring Operations & Web of Trust Verification
Generate a non-interactive GPG keypair using an automated batch file.

```bash
cat <<EOF > gpg_batch.txt
Key-Type: RSA
Key-Length: 3072
Subkey-Type: RSA
Subkey-Length: 3072
Name-Real: Security Auditor
Name-Email: auditor@security.internal
Expire-Date: 30d
%no-protection
%commit
EOF

gpg --batch --generate-key gpg_batch.txt
rm gpg_batch.txt
```

*Expected Output:*
```text
gpg: key E5A89B4C21DF001A marked as ultimately trusted
gpg: revocation certificate stored as '/root/.gnupg/openpgp-revocs.d/E5A89B4C21DF001A.rev'
```

Verify key generation and list key fingerprints:
```bash
gpg --list-secret-keys --keyid-format LONG auditor@security.internal
```

*Expected Output:*
```text
sec   rsa3072/E5A89B4C21DF001A 2026-08-07 [SC] [expires: 2026-09-06]
      Key fingerprint = 4F82 119A C32B E7D9 0081  7721 E5A8 9B4C 21DF 001A
uid                   [ultimate] Security Auditor <auditor@security.internal>
ssb   rsa3072/9C114FDF7A0B2241 2026-08-07 [E]
```

---

#### Comprehension Questions — Exercise 3
1. What major security advantage do SSH Certificates provide over classic SSH `authorized_keys` files in an enterprise infrastructure environment?
2. In OpenPGP key architectures, what is the functional distinction between a Primary Key (master key) and Subkeys?

---

### Exercise 4: Network Confidentiality, Encrypted DNS (DoH), and Privacy Diagnostics

#### Step 1: Configure DNS-over-HTTPS (DoH) Client (`cloudflared`)
Create a production DoH configuration manifest for `cloudflared` daemon in `/etc/cloudflared/config.yml`.

```bash
sudo mkdir -p /etc/cloudflared
sudo tee /etc/cloudflared/config.yml > /dev/null <<'EOF'
# /etc/cloudflared/config.yml - Production DNS-over-HTTPS Proxy Configuration
proxy-dns: true
proxy-dns-port: 5053
proxy-dns-upstream:
  - https://1.1.1.1/dns-query
  - https://1.0.0.1/dns-query
  - https://9.9.9.9/dns-query
proxy-dns-max-upstream-conns: 20
proxy-dns-bootstrap:
  - 1.1.1.1:53
  - 9.9.9.9:53
EOF
```

Verify manifest permissions:
```bash
sudo chmod 644 /etc/cloudflared/config.yml
ls -l /etc/cloudflared/config.yml
```

*Expected Output:*
```text
-rw-r--r-- 1 root root 274 Aug  7 00:58 /etc/cloudflared/config.yml
```

#### Step 2: Validate DNS-over-HTTPS Resolution
Execute `dig` queries routed directly through the local DoH proxy port `5053`.

```bash
dig @127.0.0.1 -p 5053 lpi.org A +short
```

*Expected Output:*
```text
198.51.100.42
```

#### Step 3: Diagnostic Packet Capture & SNI Leak Inspection
Execute `tshark` packet inspection to verify that DNS requests are encrypted inside HTTPS TLS traffic and no standard UDP port 53 leakage occurs.

```bash
sudo tshark -i any -n -f "udp port 53 or tcp port 443" -c 5
```

*Expected Output:*
```text
  1   0.000000    192.168.1.15 -> 1.1.1.1      TCP 74 54312 -> 443 [SYN] Seq=0 Win=64240 Len=0 MSS=1460
  2   0.012431      1.1.1.1 -> 192.168.1.15    TCP 74 443 -> 54312 [SYN, ACK] Seq=0 Ack=1 Win=65535 Len=0
  3   0.012502    192.168.1.15 -> 1.1.1.1      TCP 66 54312 -> 443 [ACK] Seq=1 Ack=1 Win=64240 Len=0
  4   0.015820    192.168.1.15 -> 1.1.1.1      TLSv1.3 583 Client Hello
  5   0.031201      1.1.1.1 -> 192.168.1.15    TLSv1.3 1460 Application Data
```

Notice that queries appear exclusively as `TLSv1.3 Application Data` packets sent to port `443`, proving DNS query confidentiality.

---

#### Comprehension Questions — Exercise 4
1. Although DNS-over-HTTPS (DoH) encrypts the payload of DNS lookups, what TLS feature during the subsequent HTTPS connection to a server can still leak the requested domain name to on-path network observers?
2. What protocol extension was developed to solve this specific metadata leak, and how does it function?

---

<details>
<summary>Answers and Architectural Explanations</summary>

### Answers to Exercise 1
1. **Double Declaration of `pam_faillock.so`**:
   The first invocation with `preauth` checks whether the account is already locked due to prior failed attempts *before* asking the user for a credential. If locked, it denies entry immediately, preventing unnecessary authentication processing and CPU consumption. The second invocation with `authfail` increments the failure counter if the credential validation (such as `pam_unix.so`) fails.

2. **Impact of `sufficient` Control Flag**:
   If `pam_unix.so` returns success with a `sufficient` flag, PAM immediately terminates auth stack processing and grants access to the user without executing any subsequent modules. This completely bypasses `pam_google_authenticator.so`, disabling MFA enforcement.

---

### Answers to Exercise 2
1. **OIDC `id_token` vs OAuth 2.0 `access_token`**:
   An `id_token` is an authentication artifact intended for consumption by the Client/Relying Party. It contains cryptographic assertions regarding the user's identity (subject, authentication time, claims). An `access_token` is an authorization credential intended for consumption by a Resource Server (API), granting scope-restricted access to specific data endpoints.

2. **Purpose of `kid` (Key ID)**:
   The `kid` header parameter identifies the specific public key in an Identity Provider's JSON Web Key Set (`JWKS`) endpoint used to sign the token. During key rotation (where an IdP maintains multiple active keys), the consumer uses `kid` to locate the exact public key needed for signature verification without trial-and-error parsing.

---

### Answers to Exercise 3
1. **SSH Certificates vs `authorized_keys`**:
   `authorized_keys` requires deploying static public keys to every target host and managing key revocation lists individually (O(N*M) operational complexity). SSH Certificates allow servers to trust a single SSH CA public key. Users present short-lived, signed certificates containing identity claims, validities, and permissions, eliminating state management on individual target servers and enabling centralized key lifecycle management.

2. **Master Key vs Subkeys in OpenPGP**:
   The Master Primary Key is kept offline or heavily protected and is strictly used for certification actions (signing other keys, creating subkeys, revoking keys). Subkeys are issued for daily operations (encryption, signing, authentication). If a daily operational subkey is compromised, it can be individually revoked using the master key without invalidating the owner's primary identity and Web of Trust signatures.

---

### Answers to Exercise 4
1. **TLS SNI (Server Name Indication) Metadata Leak**:
   Standard TLS 1.3 handshakes send the Server Name Indication (SNI) extension in unencrypted plaintext inside the `Client Hello` message. Even if DNS queries are encrypted via DoH, an on-path eavesdropper (ISP or middlebox) can read the SNI header to identify the target domain name being accessed.

2. **Encrypted Client Hello (ECH)**:
   Encrypted Client Hello (ECH, previously ESNI) encrypts the sensitive `Client Hello` parameters (including SNI) using a public key retrieved from the target domain's DNS records (via `HTTPS` or `SVCB` DNS records). This prevents on-path observers from extracting domain names from TLS handshake packets.

</details>