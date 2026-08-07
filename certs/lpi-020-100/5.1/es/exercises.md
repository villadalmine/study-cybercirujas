# LPI Security Essentials (Exam 020-100) — Topic 5.1: Identity and Privacy

### Documentación Oficial de Referencia
- **LPI Security Essentials Overview**: [https://www.lpi.org/our-certifications/security-essentials-overview/](https://www.lpi.org/our-certifications/security-essentials-overview/)
- **RFC 6238 (TOTP: Time-Based One-Time Password Algorithm)**: [https://datatracker.ietf.org/doc/html/rfc6238](https://datatracker.ietf.org/doc/html/rfc6238)
- **RFC 6749 (The OAuth 2.0 Authorization Framework)**: [https://datatracker.ietf.org/doc/html/rfc6749](https://datatracker.ietf.org/doc/html/rfc6749)
- **OpenID Connect Core 1.0 specification**: [https://openid.net/specs/openid-connect-core-1_0.html](https://openid.net/specs/openid-connect-core-1_0.html)
- **RFC 8484 (DNS Queries over HTTPS - DoH)**: [https://datatracker.ietf.org/doc/html/rfc8484](https://datatracker.ietf.org/doc/html/rfc8484)
- **RFC 7519 (JSON Web Token - JWT)**: [https://datatracker.ietf.org/doc/html/rfc7519](https://datatracker.ietf.org/doc/html/rfc7519)

---

## Arquitectura Técnica y Principios Fundamentales

### 1. Modelo AAA y Mecánica de Autenticación
La arquitectura de seguridad moderna se basa en el modelo AAA:
- **Authentication (AuthN)**: Verificación de declaraciones de identidad.
- **Authorization (AuthZ)**: Validación de concesión de acceso basada en la identidad autenticada y en políticas (RBAC/ABAC).
- **Accounting**: Registro de auditoría (audit logging) de acciones de identidad, marcas de tiempo (timestamps) y consumo de recursos.

Los factores de autenticación se categorizan en tres dominios distintos:
1. **Knowledge Factor** (*Algo que sabes*): Contraseñas, frases de paso (passphrases), PINs. Vulnerable a fuerza bruta (brute-force), credential stuffing e ingeniería social.
2. **Possession Factor** (*Algo que tienes*): Llaves de seguridad de hardware (FIDO2/WebAuthn), autenticadores de software TOTP (RFC 6238), certificados de cliente TLS, tarjetas inteligentes (smart cards).
3. **Inherence Factor** (*Algo que eres*): Marcadores biométricos (escaneo de huella dactilar, reconocimiento facial).

#### Algoritmos de Autenticación de Múltiples Factores (MFA)
- **HOTP (HMAC-Based One-Time Password, RFC 4226)**: Autenticación basada en contador donde $HOTP(K, C) = Truncate(HMAC-SHA-1(K, C))$.
- **TOTP (Time-Based One-Time Password, RFC 6238)**: Utiliza la hora epoch actual $T$ como un factor móvil: $T = \lfloor \frac{CurrentTime - T_0}{X} \rfloor$, donde $X$ es la duración del intervalo de tiempo (por defecto 30s). $TOTP(K, T) = HOTP(K, T)$.

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
En las distribuciones de Linux, PAM desacopla las aplicaciones de los backends de autenticación subyacentes. Los archivos de configuración de PAM residen en `/etc/pam.d/`.

Las reglas de PAM siguen esta sintaxis:
`module_type control_flag module_path module_arguments`

- **Module Types**: `auth` (valida la identidad), `account` (verifica la expiración de contraseñas, restricciones de acceso), `password` (gestiona actualizaciones), `session` (administra el entorno del usuario pre/post login).
- **Control Flags**:
  - `required`: Debe tener éxito. El procesamiento del stack continúa incluso en caso de fallo.
  - `requisite`: Debe tener éxito. Termina inmediatamente el stack en caso de fallo.
  - `sufficient`: Si tiene éxito y ningún módulo `required` previo ha fallado, otorga acceso de inmediato.
  - `optional`: Éxito/fallo ignorado a menos que sea el único módulo en el stack.

---

### 3. Identidad Federada y Protocolos (OAuth 2.0, OIDC, JWT)
- **OAuth 2.0 (RFC 6749)**: Un framework de autorización que permite a una aplicación de terceros obtener acceso limitado a un servicio HTTP en nombre de un propietario de recurso (resource owner).
- **OpenID Connect (OIDC)**: Capa de identidad construida sobre OAuth 2.0. Introduce el `id_token`, un JSON Web Token (JWT) firmado criptográficamente.

#### Estructura de JWT
Un JWT consta de tres cadenas codificadas en Base64URL separadas por puntos:
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

### 4. Comunicaciones Seguras y Protecciones de Privacidad
- **Public Key Infrastructure (PKI) y SSH CAs**: Reemplaza el archivo estático `~/.ssh/authorized_keys` con Autoridades de Certificación (CAs) de SSH dinámicas. Los certificados SSH firmados de corta duración vinculan la identidad del usuario (`principals`) con las claves públicas.
- **OpenPGP y Web of Trust**: Esquema de cifrado asimétrico que combina el cifrado simétrico de la carga útil (payload) (AES-256) con el encapsulamiento de clave asimétrica (RSA o Ed25519/X25519).
- **Privacidad en DNS (DoH y DoT)**:
  - DNS en texto plano (UDP/53) expone los metadatos de búsqueda de dominio a observadores de la red.
  - **DNS-over-TLS (DoT, RFC 7858)**: Encapsula DNS dentro de TLS sobre el puerto TCP 853.
  - **DNS-over-HTTPS (DoH, RFC 8484)**: Encapsula mensajes en formato cable (wire-format) de DNS en solicitudes HTTP/2 o HTTP/3 POST sobre TCP/443, mezclando las consultas DNS en el tráfico web cifrado.

---

## Ejercicios Prácticos Guiados de Laboratorio

### Ejercicio 1: Hardening del Stack PAM de Linux y Motor de Autenticación de Múltiples Factores

#### Paso 1: Auditar la configuración PAM existente de SSH
Inspeccione `/etc/pam.d/sshd` para entender la lógica de procesamiento de módulos.

```bash
sudo cat /etc/pam.d/sshd
```

*Salida esperada:*
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

#### Paso 2: Configurar el Bloqueo de Cuenta PAM y TOTP de Google Authenticator
Cree un manifiesto de configuración del stack PAM de producción para autenticación bloqueada con aplicación de TOTP en `/etc/pam.d/sshd-mfa-secured`.

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

Verifique permisos y sintaxis:
```bash
sudo chmod 644 /etc/pam.d/sshd-mfa-secured
ls -l /etc/pam.d/sshd-mfa-secured
```

*Salida esperada:*
```text
-rw-r--r-- 1 root root 782 Aug  7 00:55 /etc/pam.d/sshd-mfa-secured
```

#### Paso 3: Probar el stack de autenticación PAM usando `pamtester` y logs de auditoría
Simule la autenticación de contraseña y MFA de forma programática utilizando `pamtester` (instálelo si es necesario vía `apt-get install pamtester` o compílelo).

```bash
sudo pamtester sshd-mfa-secured root authenticate
```

*Salida esperada:*
```text
Password: 
Verification code: 
pamtester: successfully authenticated
```

Inspeccione los eventos de seguridad registrados por `pam_faillock` y el subsistema de autenticación:
```bash
sudo faillock --user root
```

*Salida esperada:*
```text
root:
When                Type  Source                           Valid
2026-08-07 00:56:12 R     192.168.1.50                         V
```

---

#### Preguntas de Comprensión — Ejercicio 1
1. ¿Por qué `pam_faillock.so` se declara dos veces en el stack `auth` (primero con `preauth` y segundo con `authfail`)?
2. Si `pam_unix.so` está configurado con `sufficient` en lugar de `required` en un stack PAM, ¿qué impacto tiene esto en los módulos posteriores como `pam_google_authenticator.so`?

---

### Ejercicio 2: Tokens de Identidad OpenID Connect y Verificación Criptográfica

#### Paso 1: Generar un Par de Claves RSA y Construir un Token de Identidad JWT Firmado
Utilice OpenSSL para generar un par de claves RSA de 2048 bits que represente la clave de firma de un Proveedor de Identidad (IdP) OIDC.

```bash
# Generate IdP Private Key
openssl genpkey -algorithm RSA -out idp_private.pem -pkeyopt rsa_keygen_bits:2048

# Extract IdP Public Key
openssl rsa -pubout -in idp_private.pem -out idp_public.pem
```

*Salida esperada:*
```text
:: Generating RSA private key, 2048 bit long modulus (2 primes)
e is 65537 (0x010001)
writing RSA key
```

Cree un archivo de manifiesto no firmado para el header y el payload de JWT llamado `jwt_payload.json`.

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

#### Paso 2: Ensamblar y Firmar el JWT OIDC vía Bash y OpenSSL
Construya la firma del JWT codificada en Base64URL utilizando SHA-256 y la clave privada RSA del IdP.

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

*Salida esperada:*
```text
Constructed ID Token: eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCIsImtpZCI6ImlkcC1rZXktMjAyNiJ9.ZXlKM2RYSnBi...
```

#### Paso 3: Verificar criptográficamente la firma del token con la Clave Pública
Extraiga el payload y verifique la integridad de la firma con respecto a `idp_public.pem`.

```bash
# Extract signature binary from token
echo -n "${SIGNATURE_B64}" | tr '_-' '/+' | awk '{ v=length % 4; if (v==2) print $0"=="; else if (v==3) print $0"="; else print $0; }' | openssl base64 -d -A > token_sig.bin

# Cryptographic Verification
echo -n "${HEADER_B64}.${PAYLOAD_B64}" | openssl dgst -sha256 -verify idp_public.pem -signature token_sig.bin
```

*Salida esperada:*
```text
Verified OK
```

---

#### Preguntas de Comprensión — Ejercicio 2
1. En los flujos de trabajo de OIDC, ¿cuál es la diferencia arquitectónica entre el `id_token` y un `access_token`?
2. ¿Cómo protege el campo de encabezado `kid` (Key ID) en un JWT a un API Gateway o Relying Party durante la rotación de claves de identidad?

---

### Ejercicio 3: Criptografía de Clave Pública, Certificados SSH y Web of Trust de OpenPGP

#### Paso 1: Aprovisionar una Autoridad de Certificación (CA) de SSH y un Par de Claves de Usuario
Genere una clave de CA de SSH aislada y una clave de identidad de usuario de destino.

```bash
# Generate CA Key
ssh-keygen -t ed25519 -f ssh_ca_key -C "Production-SSH-CA" -N ""

# Generate User Identity Keypair
ssh-keygen -t ed25519 -f user_ed25519 -C "devops.engineer@enterprise.internal" -N ""
```

*Salida esperada:*
```text
Generating public/private ed25519 key pair.
Your identification has been saved in ssh_ca_key
Your public key has been saved in ssh_ca_key.pub
Generating public/private ed25519 key pair.
Your identification has been saved in user_ed25519
Your public key has been saved in user_ed25519.pub
```

#### Paso 2: Firmar la Clave de Usuario con la CA de SSH y Aplicar Principales/Restricciones de Validez
Emita un certificado de usuario SSH firmado restringido a `principals` (nombres de usuario permitidos) y válido durante 1 hora (`+1h`).

```bash
ssh-keygen -s ssh_ca_key -I "cert-devops-001" -n "ubuntu,devops" -V +1h user_ed25519.pub
```

*Salida esperada:*
```text
Signed user key user_ed25519-cert.pub: id "cert-devops-001" serial 0 valid forever to primitives
```

Inspeccione los detalles criptográficos del certificado generado:
```bash
ssh-keygen -Lf user_ed25519-cert.pub
```

*Salida esperada:*
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

#### Paso 3: Operaciones del Llavero (Keyring) de OpenPGP y Verificación de Web of Trust
Genere un par de claves GPG de forma no interactiva utilizando un archivo por lotes (batch file) automatizado.

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

*Salida esperada:*
```text
gpg: key E5A89B4C21DF001A marked as ultimately trusted
gpg: revocation certificate stored as '/root/.gnupg/openpgp-revocs.d/E5A89B4C21DF001A.rev'
```

Verifique la generación de claves y liste las huellas digitales (fingerprints) de las claves:
```bash
gpg --list-secret-keys --keyid-format LONG auditor@security.internal
```

*Salida esperada:*
```text
sec   rsa3072/E5A89B4C21DF001A 2026-08-07 [SC] [expires: 2026-09-06]
      Key fingerprint = 4F82 119A C32B E7D9 0081  7721 E5A8 9B4C 21DF 001A
uid                   [ultimate] Security Auditor <auditor@security.internal>
ssb   rsa3072/9C114FDF7A0B2241 2026-08-07 [E]
```

---

#### Preguntas de Comprensión — Ejercicio 3
1. ¿Qué ventaja principal de seguridad ofrecen los Certificados SSH sobre los archivos clásicos `authorized_keys` de SSH en un entorno de infraestructura empresarial?
2. En las arquitecturas de claves de OpenPGP, ¿cuál es la distinción funcional entre una Clave Primaria (master key) y las Subclaves (Subkeys)?

---

### Ejercicio 4: Confidencialidad de Red, DNS Cifrado (DoH) y Diagnósticos de Privacidad

#### Paso 1: Configurar el Cliente de DNS-over-HTTPS (DoH) (`cloudflared`)
Cree un manifiesto de configuración de DoH de producción para el demonio `cloudflared` en `/etc/cloudflared/config.yml`.

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

Verifique los permisos del manifiesto:
```bash
sudo chmod 644 /etc/cloudflared/config.yml
ls -l /etc/cloudflared/config.yml
```

*Salida esperada:*
```text
-rw-r--r-- 1 root root 274 Aug  7 00:58 /etc/cloudflared/config.yml
```

#### Paso 2: Validar la Resolución de DNS-over-HTTPS
Ejecute consultas `dig` enrutadas directamente a través del puerto proxy DoH local `5053`.

```bash
dig @127.0.0.1 -p 5053 lpi.org A +short
```

*Salida esperada:*
```text
198.51.100.42
```

#### Paso 3: Captura Diagnóstica de Paquetes e Inspección de Fugas de SNI
Ejecute la inspección de paquetes con `tshark` para verificar que las solicitudes DNS estén cifradas dentro del tráfico TLS de HTTPS y que no ocurra ninguna fuga en el puerto estándar UDP 53.

```bash
sudo tshark -i any -n -f "udp port 53 or tcp port 443" -c 5
```

*Salida esperada:*
```text
  1   0.000000    192.168.1.15 -> 1.1.1.1      TCP 74 54312 -> 443 [SYN] Seq=0 Win=64240 Len=0 MSS=1460
  2   0.012431      1.1.1.1 -> 192.168.1.15    TCP 74 443 -> 54312 [SYN, ACK] Seq=0 Ack=1 Win=65535 Len=0
  3   0.012502    192.168.1.15 -> 1.1.1.1      TCP 66 54312 -> 443 [ACK] Seq=1 Ack=1 Win=64240 Len=0
  4   0.015820    192.168.1.15 -> 1.1.1.1      TLSv1.3 583 Client Hello
  5   0.031201      1.1.1.1 -> 192.168.1.15    TLSv1.3 1460 Application Data
```

Observe que las consultas aparecen exclusivamente como paquetes `TLSv1.3 Application Data` enviados al puerto `443`, demostrando la confidencialidad de la consulta DNS.

---

#### Preguntas de Comprensión — Ejercicio 4
1. Aunque DNS-over-HTTPS (DoH) cifra el payload de las búsquedas DNS, ¿qué característica de TLS durante la conexión HTTPS posterior a un servidor aún puede filtrar el nombre de dominio solicitado a observadores en la ruta de red?
2. ¿Qué extensión de protocolo se desarrolló para resolver esta fuga específica de metadatos y cómo funciona?

---

<details>
<summary>Answers and Architectural Explanations</summary>

### Answers to Exercise 1
1. **Declaración doble de `pam_faillock.so`**:
   La primera invocación con `preauth` verifica si la cuenta ya está bloqueada debido a intentos fallidos previos *antes* de solicitar credenciales al usuario. Si está bloqueada, deniega la entrada de inmediato, evitando el procesamiento inútil de autenticación y el consumo de CPU. La segunda invocación con `authfail` incrementa el contador de fallos si la validación de la credencial (como `pam_unix.so`) falla.

2. **Impacto de la Control Flag `sufficient`**:
   Si `pam_unix.so` devuelve éxito con una flag `sufficient`, PAM finaliza de inmediato el procesamiento del stack de autenticación y otorga acceso al usuario sin ejecutar ningún módulo posterior. Esto omite por completo `pam_google_authenticator.so`, desactivando la aplicación de MFA.

---

### Answers to Exercise 2
1. **OIDC `id_token` vs OAuth 2.0 `access_token`**:
   Un `id_token` es un artefacto de autenticación destinado a ser consumido por el Cliente/Relying Party. Contiene afirmaciones criptográficas relativas a la identidad del usuario (subject, hora de autenticación, claims). Un `access_token` es una credencial de autorización destinada al consumo de un Servidor de Recursos (API), otorgando acceso restringido por alcance (scope) a endpoints de datos específicos.

2. **Propósito de `kid` (Key ID)**:
   El parámetro de encabezado `kid` identifica la clave pública específica en el endpoint de JSON Web Key Set (`JWKS`) de un Proveedor de Identidad utilizada para firmar el token. Durante la rotación de claves (donde un IdP mantiene múltiples claves activas), el consumidor utiliza `kid` para localizar la clave pública exacta necesaria para la verificación de firma sin necesidad de pruebas y errores.

---

### Answers to Exercise 3
1. **Certificados SSH vs `authorized_keys`**:
   `authorized_keys` requiere desplegar claves públicas estáticas en cada host de destino y gestionar listas de revocación de claves individualmente (complejidad operativa O(N*M)). Los Certificados SSH permiten a los servidores confiar en una sola clave pública de CA de SSH. Los usuarios presentan certificados firmados de corta duración que contienen declaraciones de identidad, validez y permisos, eliminando la gestión de estado en servidores de destino individuales y permitiendo la gestión centralizada del ciclo de vida de las claves.

2. **Clave Maestra vs Subclaves en OpenPGP**:
   La Clave Primaria Maestra (Master Primary Key) se mantiene fuera de línea o altamente protegida y se utiliza estrictamente para acciones de certificación (firmar otras claves, crear subclaves, revocar claves). Las subclaves se emiten para operaciones diarias (cifrado, firma, autenticación). Si una subclave operativa diaria se compromete, se puede revocar individualmente mediante la clave maestra sin invalidar la identidad primaria del propietario ni las firmas de Web of Trust.

---

### Answers to Exercise 4
1. **Fuga de Metadatos de TLS SNI (Server Name Indication)**:
   Los handshakes estándar de TLS 1.3 envían la extensión Server Name Indication (SNI) en texto plano no cifrado dentro del mensaje `Client Hello`. Incluso si las consultas DNS están cifradas vía DoH, un observador en la ruta (ISP o middlebox) puede leer el encabezado SNI para identificar el nombre del dominio de destino al que se accede.

2. **Encrypted Client Hello (ECH)**:
   Encrypted Client Hello (ECH, anteriormente ESNI) cifra los parámetros sensibles de `Client Hello` (incluido SNI) utilizando una clave pública obtenida de los registros DNS del dominio de destino (a través de registros DNS `HTTPS` o `SVCB`). Esto evita que los observadores en la ruta extraigan nombres de dominio de los paquetes de handshake de TLS.

</details>