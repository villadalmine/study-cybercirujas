# Examen LPIC-3 303-300 (v3.0) — Tema 3.1: Application Security

**Peso del examen:** 16.66 (Aprox. 10 preguntas)  
**Rol objetivo:** Enterprise Linux Security Architect / Senior SRE  
**Referencia principal:** [Linux Professional Institute: LPIC-3 303 Exam Overview](https://www.lpi.org/our-certifications/lpic-3-303-overview/)

---

## Principios de arquitectura y mecánica de Application Security

Application Security en entornos Linux empresariales opera sobre un modelo de **Defense-in-Depth** a lo largo del modelo OSI (principalmente capas 4 a 7) y los límites del kernel del sistema. Asegurar las cargas de trabajo de aplicaciones modernas requiere aplicar restricciones de seguridad a través de cinco límites críticos:

```
                          +---------------------------------------------------+
                          |                 UNTRUSTED NETWORK                 |
                          +---------------------------------------------------+
                                                    |
                                                    v [Layer 7: TLS 1.3 / mTLS]
                          +---------------------------------------------------+
                          |      Edge Reverse Proxy (Nginx / Apache)          |
                          |   - TLS Termination & HSTS                        |
                          |   - Security Headers (CSP, CORS, X-Frame)         |
                          +---------------------------------------------------+
                                                    |
                                                    v [Layer 7: Inspection]
                          +---------------------------------------------------+
                          |  Web Application Firewall (ModSecurity v3 + CRS)  |
                          |   - Protocol Anomaly Detection                    |
                          |   - SQLi / XSS / RCE Signature Inspection         |
                          +---------------------------------------------------+
                                                    |
                                                    v [IPC / Unix Socket]
                          +---------------------------------------------------+
                          |     Application Runtime Sandbox (systemd)         |
                          |   - Namespace Isolation (Mount, Network, PID)     |
                          |   - Linux Capabilities & CapabilityBoundingSet    |
                          |   - Syscall Filtering (seccomp-bpf)               |
                          +---------------------------------------------------+
                                    |                               |
                                    v [PAM / GSSAPI]                v [Encrypted TLS / Socket]
  +--------------------------------------------------+    +----------------------------------+
  | Application Auth Engine (Linux-PAM / pam_faillock) |    | Secure Database Engine (Postgres)|
  +--------------------------------------------------+    +----------------------------------+
```

1. **Transport Layer Hardening:** Estandarización en TLS 1.3 / TLS 1.2 con cipher suites estrictos Ephemeral Diffie-Hellman (`ECDHE-ECDSA-*` / `ECDHE-RSA-*`) para garantizar Perfect Forward Secrecy (PFS). La validación de certificados depende de OCSP Stapling para eliminar la latencia de CAs de terceros y la fuga de privacidad durante los handshakes TLS.
2. **Mecánica de Web Application Firewall (WAF):** Los motores de WAF (como ModSecurity v3 / `libmodsecurity`) analizan los pipelines de solicitudes HTTP antes de pasar los payloads a los servidores de aplicaciones upstream. Utilizando conjuntos de reglas como el OWASP Core Rule Set (CRS), las solicitudes se evalúan utilizando **Anomaly Scoring Mode**, acumulando puntos de riesgo por cada regla que coincida para rechazar ataques de alto riesgo (`403 Forbidden`) mientras se minimizan los falsos positivos.
3. **Kernel System Call & Privilege Sandboxing:** El aislamiento de servicios va más allá de las jaulas `chroot` básicas. Los patrones SRE modernos utilizan filtrado de system calls con `seccomp-bpf` junto con Linux Namespaces (Mount, PID, Network, IPC) y Capability Bounding Sets gestionados a través de `systemd`. Restringir la capacidad de una aplicación para ejecutar `execve`, `ptrace` o escribir en `/usr` limita el impacto del payload incluso si ocurre un remote code execution (RCE).
4. **Arquitectura de Pluggable Authentication Modules (PAM):** Las aplicaciones delegan la verificación de identidad, las comprobaciones de calidad de contraseñas y la mitigación de fuerza bruta a `/etc/pam.d/`. Utilizando módulos como `pam_faillock.so` y `pam_access.so`, los sistemas aplican controles de autenticación a nivel de host de forma independiente del stack de lenguaje subyacente de la aplicación.
5. **Database Transport & Authentication Hardening:** Los microservicios deben autenticarse ante los sistemas de gestión de bases de datos mediante identidad criptográfica (mTLS / SCRAM-SHA-256) sobre conexiones encriptadas con TLS, combinado con listas estrictas de control basadas en host (`pg_hba.conf`).

---

## Technical Trade-offs & Production Impact

| Security Control | Operational Benefit | Performance / Operational Trade-off | Diagnostic Command |
| :--- | :--- | :--- | :--- |
| **Strict WAF Anomaly Scoring** | Bloquea vulnerabilidades zero-day de SQLi, XSS y path traversal. | Añade entre 1.5ms y 5ms de latencia por solicitud; alto riesgo de bloquear tráfico legítimo de APIs (falsos positivos). | `tail -f /var/log/nginx/modsec_audit.log` |
| **systemd Syscall Filtering (`seccomp`)** | Previene la elevación de privilegios y la ejecución de exploits del kernel. | Las malas configuraciones provocan la terminación del proceso con `SIGSYS`; interrumpe la carga de librerías dinámicas o la creación de subprocesos. | `journalctl -u app.service -e -g SIGSYS` |
| **HSTS Preload + Subdomains** | Elimina vectores de SSL Stripping y downgrade de MITM. | Inflexible: Aplica HTTPS en *todos* los subdominios por un período de hasta 2 años; certificados inválidos tiran abajo todos los sitios. | `curl -sI https://example.com \| grep -i strict-transport-security` |
| **PAM Account Lockout (`pam_faillock`)** | Mitiga ataques de diccionario en línea y credential stuffing. | Riesgo de Denial of Service (DoS) donde los atacantes bloquean a usuarios administradores legítimos forjando intentos fallidos. | `faillock --user admin_user` |
| **TLS Client Certificate Auth (mTLS)** | Autenticación service-to-service zero-trust; inmune al robo de credenciales. | Sobrecarga en el ciclo de vida de la PKI: Emisión de certificados, gestión de revocación por CRL/OCSP y complejidad en la renovación automatizada. | `openssl s_client -connect db.internal:5432 -cert client.crt -key client.key` |

---

## Guided Exercise 1: Enterprise Web Server Hardening & TLS 1.3 Enforcement

### Objetivos
Configurar un reverse proxy Nginx para producción que ejecute restricción absoluta a TLS 1.3 / 1.2, HSTS preloading, security headers, OCSP stapling dinámico y hardening explícito de protocolos según la [Guía de configuración SSL de Mozilla](https://wiki.mozilla.org/Security/Server_Side_TLS).

### Paso 1.1: Desplegar una configuración sintácticamente válida de TLS Hardened y Security Headers
Crear `/etc/nginx/conf.d/security_hardened.conf` para forzar cipher suites estrictos, deshabilitar protocolos SSL/TLS vulnerables e inyectar security headers.

```nginx
# /etc/nginx/conf.d/security_hardened.conf

# Hide Nginx version details in server tokens and error pages
server_tokens off;

# SSL Session Cache Configuration
ssl_session_timeout 1d;
ssl_session_cache shared:SSL:10m;
ssl_session_tickets off;

# Protocol & Cipher Suite Hardening (Intermediate / Modern Profile)
ssl_protocols TLSv1.2 TLSv1.3;
ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
ssl_prefer_server_ciphers off;

# OCSP Stapling Settings
ssl_stapling on;
ssl_stapling_verify on;
resolver 1.1.1.1 8.8.8.8 valid=300s;
resolver_timeout 5s;

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name app.secure.internal;

    ssl_certificate /etc/ssl/certs/app_combined.crt;
    ssl_certificate_key /etc/ssl/private/app.key;
    ssl_trusted_certificate /etc/ssl/certs/ca_chain.crt;

    # HTTP Strict Transport Security (HSTS)
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;

    # Defense-in-Depth Security Headers
    add_header X-Frame-Options "DENY" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "0" always; # Disabled in favor of strict CSP
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Content-Security-Policy "default-src 'self'; script-src 'self'; object-src 'none'; frame-ancestors 'none'; base-uri 'self'; form-action 'self';" always;
    add_header Permissions-Policy "geolocation=(), microphone=(), camera=(), payment=()" always;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

### Paso 1.2: Validar y probar la configuración de Nginx
Validar la sintaxis y probar el cumplimiento de TLS utilizando `openssl` y `curl`.

```bash
sudo nginx -t
```
*Resultado esperado:*
```text
nginx: the configuration file /etc/nginx/nginx.conf syntax is ok
nginx: configuration file /etc/nginx/nginx.conf test is successful
```

Recargar el servicio Nginx:
```bash
sudo systemctl reload nginx
```

Verificar la aplicación del protocolo TLS mediante `openssl s_client`:
```bash
openssl s_client -connect localhost:443 -tls1_1
```
*Resultado esperado:*
```text
CONNECTED(00000003)
40579979310848:error:0A000102:SSL routines:ssl_choose_client_version:unsupported protocol:ssl/statem/statem_lib.c:1982:
---
no peer certificate available
---
Server public key is 0 bit
---
```

Verificar la inyección de security headers mediante `curl`:
```bash
curl -Iv https://localhost/ --insecure
```
*Resultado esperado:*
```text
HTTP/2 200 
server: nginx
date: Thu, 06 Aug 2026 13:25:00 GMT
content-type: text/html
strict-transport-security: max-age=63072000; includeSubDomains; preload
x-frame-options: DENY
x-content-type-options: nosniff
referrer-policy: strict-origin-when-cross-origin
content-security-policy: default-src 'self'; script-src 'self'; object-src 'none'; frame-ancestors 'none'; base-uri 'self'; form-action 'self';
permissions-policy: geolocation=(), microphone=(), camera=(), payment=()
```

---

### Preguntas de verificación (Ejercicio 1)
1. **¿Por qué `X-XSS-Protection` se configura en `"0"` en lugar de `"1; mode=block"` en las configuraciones de seguridad modernas?**
2. **¿Qué fallo técnico ocurre si se habilita `ssl_stapling_verify on` sin definir un `ssl_trusted_certificate` explícito o un `resolver` válido?**

---

## Guided Exercise 2: WAF Deployment via ModSecurity v3 & OWASP Core Rule Set (CRS)

### Objetivos
Integrar `libmodsecurity` (ModSecurity v3) en Nginx, cargar el OWASP Core Rule Set (v3.3/v4.0), configurar **Anomaly Scoring Mode** y elaborar rule exclusion overrides para falsos positivos de APIs. Referencia: [Documentación del OWASP ModSecurity Core Rule Set](https://coreruleset.org/docs/).

### Paso 2.1: Habilitar ModSecurity en la configuración principal de Nginx
Editar `/etc/nginx/nginx.conf` o el contexto del servidor principal para cargar el módulo ModSecurity y habilitar la ejecución.

```nginx
# /etc/nginx/nginx.conf snippet
user www-data;
worker_processes auto;
load_module modules/ngx_http_modsecurity_module.so;

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    # Enable ModSecurity globally
    modsecurity on;
    modsecurity_rules_file /etc/nginx/modsec/main.conf;

    include /etc/nginx/conf.d/*.conf;
}
```

### Paso 2.2: Configurar el wrapper principal de reglas de ModSecurity
Crear `/etc/nginx/modsec/main.conf` para ensamblar las dependencias principales, mapeos unicode, reglas CRS y exclusiones personalizadas.

```custom
# /etc/nginx/modsec/main.conf

# Include recommended ModSecurity engine configuration
include /etc/nginx/modsec/modsecurity.conf

# Include OWASP CRS setup parameters
include /etc/nginx/modsec/crs-setup.conf

# Include Custom Rule Exclusions (MUST be loaded BEFORE CRS rules to set variables/skip rules)
include /etc/nginx/modsec/rules/EXCLUSIONS-BEFORE-CRS.conf

# Include OWASP CRS rule set rules
include /etc/nginx/modsec/owasp-crs/rules/*.conf

# Include Custom Post-CRS Rule Overrides
include /etc/nginx/modsec/rules/EXCLUSIONS-AFTER-CRS.conf
```

### Paso 2.3: Configurar el motor y el registro de auditoría (Audit Logging)
Asegurar que `/etc/nginx/modsec/modsecurity.conf` defina `SecRuleEngine` en ejecución activa y configure el registro de auditoría pertinente.

```custom
# /etc/nginx/modsec/modsecurity.conf directives
SecRuleEngine On
SecRequestBodyAccess On
SecRequestBodyLimit 13107200
SecRequestBodyNoFilesLimit 131072
SecResponseBodyAccess Off
SecResponseBodyMimeType text/html text/plain text/xml application/json

# Audit Log Configuration
SecAuditEngine RelevantOnly
SecAuditLogRelevantStatus "^(?:5|(?:4(?!(?:04|03))))"
SecAuditLogParts ABIJDEFHZ
SecAuditLogType Serial
SecAuditLog /var/log/nginx/modsec_audit.log
```

### Paso 2.4: Implementar una regla de exclusión previa a CRS para falsos positivos de API
Crear `/etc/nginx/modsec/rules/EXCLUSIONS-BEFORE-CRS.conf` para incluir en lista blanca activadores legítimos de payload JSON en `/api/v1/telemetry` para la regla `942100` (detección de SQL Injection).

```custom
# /etc/nginx/modsec/rules/EXCLUSIONS-BEFORE-CRS.conf

# Exclude Rule 942100 (SQLi Detection) for the 'payload' parameter on endpoint /api/v1/telemetry
SecRule REQUEST_URI "@beginsWith /api/v1/telemetry" \
    "id:100001,\
    phase:1,\
    pass,\
    nolog,\
    ctl:ruleRemoveTargetById=942100;ARGS:payload"
```

### Paso 2.5: Probar la mitigación de ataques del WAF e inspeccionar los logs de auditoría
Ejecutar un payload simulado de ataque Cross-Site Scripting (XSS) contra Nginx:

```bash
curl -i -s -k "https://localhost/?search=<script>alert('XSS')</script>"
```
*Resultado esperado:*
```text
HTTP/2 403 
server: nginx
date: Thu, 06 Aug 2026 13:27:00 GMT
content-type: text/html
content-length: 153

<html>
<head><title>403 Forbidden</title></head>
<body>
<center><h1>403 Forbidden</h1></center>
<hr><center>nginx</center>
</body>
</html>
```

Inspeccionar `/var/log/nginx/modsec_audit.log` para la verificación de activación de reglas:
```bash
sudo tail -n 35 /var/log/nginx/modsec_audit.log
```
*Fragmento de log esperado:*
```text
---Message: Access denied with code 403 (phase 2). Operator GE matched 5 at TX:anomaly_score. [file "/etc/nginx/modsec/owasp-crs/rules/REQUEST-949-BLOCKING-EVALUATION.conf"] [line "80"] [id "949110"] [msg "Inbound Anomaly Score Exceeded (Total Score: 5)"]
---Message: Warning. Pattern match "(?i)<script" at ARGS:search. [file "/etc/nginx/modsec/owasp-crs/rules/REQUEST-941-APPLICATION-ATTACK-XSS.conf"] [line "68"] [id "941110"] [msg "XSS Filter - Category 1: Script Tag Vector"] [data "Matched Data: <script found within ARGS:search: <script>alert('XSS')</script>"] [severity "CRITICAL"]
```

---

### Preguntas de verificación (Ejercicio 2)
1. **¿Cuál es la diferencia estructural entre el "Self-Contained Mode" y el "Anomaly Scoring Mode" de ModSecurity?**
2. **¿Por qué `ctl:ruleRemoveTargetById` debe ejecutarse en `phase:1` dentro de `EXCLUSIONS-BEFORE-CRS.conf` en lugar de hacerlo después de la inclusión del CRS?**

---

## Guided Exercise 3: Application Isolation via systemd Sandboxing & Linux Namespaces

### Objetivos
Aplicar hardening a un servicio backend vulnerable de Node.js/Python (`payment-processor.service`) utilizando la contención de procesos de systemd, aislamiento de namespaces, eliminación de capabilities y filtrado de system calls con `seccomp-bpf`. Referencia: [Directivas de seguridad de systemd.exec](https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html).

### Paso 3.1: Construir la unidad de servicio sandboxed para producción
Crear `/etc/systemd/system/payment-processor.service` con primitivas de aislamiento estrictas.

```ini
[Unit]
Description=Payment Processor Microservice
After=network.target remote-fs.target
Documentation=https://docs.secure.internal/services/payment-processor

[Service]
Type=simple
User=www-data
Group=www-data
WorkingDirectory=/var/www/payment-processor
ExecStart=/usr/bin/node /var/www/payment-processor/server.js
Restart=on-failure
RestartSec=5s

# Process Execution Restrictions
NoNewPrivileges=true
PrivilegeEscalation=false
CapabilityBoundingSet=

# File System Isolation
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
MountAPIVFS=true
PrivateTmp=true
PrivateDevices=true
ReadWritePaths=/var/log/payment-processor /tmp

# Kernel & Hardware Hardening
ProtectClock=true
ProtectKernelLogs=true
ProtectProc=invisible
ProcSubset=pid
RestrictNamespaces=true
LockPersonality=true
MemoryDenyWriteExecute=true
RestrictRealtime=true
RestrictSUIDSGID=true

# Network & System Call Filtering
ProtectHostname=true
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallFilter=~@clock @cpu-emulation @debug @keyring @module @mount @obsolete @raw-io @reboot @resources @swap

[Install]
WantedBy=multi-user.target
```

### Paso 3.2: Recargar, iniciar y evaluar la puntuación de seguridad
Recargar las unidades de systemd, habilitar e iniciar el servicio:

```bash
sudo systemctl daemon-reload
sudo systemctl restart payment-processor.service
```

Ejecutar `systemd-analyze security` para verificar la reducción del puntaje del perfil de seguridad:

```bash
systemd-analyze security payment-processor.service
```
*Resultado esperado:*
```text
NAME                        PART OF                   EXPOSURE PREDICATE HAPPY SCORE
payment-processor.service   payment-processor.service OK       OK        OK    0.8 UNSAFE -> SAFE
```
*(El desglose detallado de la salida muestra que el puntaje de exposición cae de aproximadamente ~9.6 estándar a < 1.0).*

### Paso 3.3: Diagnosticar infracciones de system calls
Verificar el comportamiento ante violaciones de system calls (`MemoryDenyWriteExecute` o ejecución bloqueada de syscalls). Activar una llamada restringida (por ejemplo, intentar cargar un módulo del kernel o ejecutar la modificación de páginas de memoria) registra un evento del kernel:

```bash
sudo journalctl -u payment-processor.service -g "SIGSYS"
```
*Salida de log esperada:*
```text
Aug 06 13:28:10 app-node-01 systemd[1]: payment-processor.service: Main process exited, code=killed, status=31/SYS
Aug 06 13:28:10 app-node-01 systemd[1]: payment-processor.service: Failed with result 'signal'.
Aug 06 13:28:10 app-node-01 kernel: audit: type=1326 audit(1786022890.124:94): auid=4294967295 uid=33 gid=33 ses=4294967295 pid=14205 comm="node" exe="/usr/bin/node" sig=31 arch=c000003e syscall=165 compat=0 ip=0x7f43b123a107 code=0x0
```

---

### Preguntas de verificación (Ejercicio 3)
1. **¿Cómo evita `NoNewPrivileges=true` que un atacante que logra colocar un binario SUID root en `/tmp` eleve privilegios?**
2. **¿Qué falla funcional ocurre en los runtimes compilados con JIT (como V8 en Node.js o la JVM en Java) si se aplica `MemoryDenyWriteExecute=true` sin configurar las flags de runtime adecuadas?**

---

## Guided Exercise 4: Enterprise Application Authentication via Linux-PAM

### Objetivos
Configurar la autenticación de acceso a aplicaciones a nivel de sistema utilizando Linux Pluggable Authentication Modules (PAM). Aplicar defensa de bloqueo de cuenta contra fuerza bruta con `pam_faillock.so` y restricciones de control de acceso a la red con `pam_access.so`. Referencia: [Guía del administrador de sistemas de Linux-PAM](https://www.linux-pam.org/Linux-PAM-html/Linux-PAM_SAG.html).

### Paso 4.1: Configurar el archivo PAM para el stack de la aplicación
Crear `/etc/pam.d/custom-app` para definir la secuencia de autenticación para una aplicación empresarial de gestión interna.

```pam
# /etc/pam.d/custom-app
# PAM configuration for Custom Enterprise Management Application

# Account Lockout Pre-check
auth      required                    pam_faillock.so preauth silent audit deny=3 unlock_time=900 fail_interval=300

# Host & Network Origin Access Control
auth      required                    pam_access.so accessfile=/etc/security/access-custom-app.conf

# Standard Unix Password Verification
auth      sufficient                  pam_unix.so nullok try_first_pass

# Account Lockout Failure Recording
auth      requisite                   pam_faillock.so authfail audit deny=3 unlock_time=900 fail_interval=300

# Catch-all Authentication Failure
auth      required                    pam_deny.so

# Account Management Controls
account   required                    pam_faillock.so
account   required                    pam_access.so
account   required                    pam_unix.so

# Session Setup Controls
session   required                    pam_limits.so
session   required                    pam_unix.so
```

### Paso 4.2: Configurar el mapa de políticas de acceso a la red
Crear `/etc/security/access-custom-app.conf` para restringir el acceso estrictamente a subredes administrativas y usuarios especificados.

```custom
# /etc/security/access-custom-app.conf
# Format: permission : users : origins

# Allow local root and admin group
+ : root sec-ops : LOCAL

# Allow app-admins from internal management subnet 10.50.0.0/16
+ : app-admin : 10.50.0.0/16

# Deny all other users and origin networks
- : ALL : ALL
```

### Paso 4.3: Simular el bloqueo por fuerza bruta e inspeccionar el estado
Simular intentos de autenticación usando `pamtester` (una utilidad para probar stacks de PAM):

```bash
pamtester custom-app invalid_user authenticate
```
*Resultado esperado:*
```text
pamtester: successfully authenticated user invalid_user
``` *(o fallo si la contraseña falla)*.

Forzar 3 intentos de autenticación inválidos para el usuario `app-admin`:
```bash
for i in {1..3}; do pamtester custom-app app-admin authenticate; done
```

Inspeccionar el estado de bloqueo mediante `faillock`:
```bash
sudo faillock --user app-admin
```
*Resultado esperado:*
```text
app-admin:
When                Type  Source                          Valid
2026-08-06 13:29:01 R     127.0.0.1                       V
2026-08-06 13:29:03 R     127.0.0.1                       V
2026-08-06 13:29:05 R     127.0.0.1                       V
```

Limpiar manualmente el estado de bloqueo de la cuenta:
```bash
sudo faillock --user app-admin --reset
```

---

### Preguntas de verificación (Ejercicio 4)
1. **¿Por qué se debe llamar a `pam_faillock.so` dos veces en el stack `auth` (`preauth` y `authfail`)?**
2. **¿Cuál es el riesgo de seguridad de colocar `pam_access.so` *debajo* de `pam_unix.so` cuando `pam_unix.so` devuelve `sufficient`?**

---

## Guided Exercise 5: Database Application Security & Transport Encrypted Access

### Objetivos
Aplicar hardening a un servidor de base de datos PostgreSQL para forzar mTLS obligatorio para el cliente, requerir un hashing de contraseñas fuerte (`scram-sha-256`) y construir reglas restrictivas de autenticación basadas en host a través de `pg_hba.conf`. Referencia: [Conexiones TCP/IP seguras con SSL en PostgreSQL](https://www.postgresql.org/docs/current/ssl-tcp.html).

### Paso 5.1: Configurar los ajustes SSL/TLS de PostgreSQL
Editar `/etc/postgresql/15/main/postgresql.conf` (ajustar la ruta de la versión según corresponda):

```ini
# /etc/postgresql/15/main/postgresql.conf snippet

# Connection Settings
listen_addresses = '10.50.10.15, 127.0.0.1'
port = 5432
max_connections = 100

# Transport Security (SSL/TLS)
ssl = on
ssl_ca_file = '/etc/ssl/certs/db_root_ca.crt'
ssl_cert_file = '/etc/ssl/certs/postgresql_server.crt'
ssl_key_file = '/etc/ssl/private/postgresql_server.key'
ssl_ciphers = 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384'
ssl_prefer_server_ciphers = on
ssl_min_protocol_version = 'TLSv1.2'

# Authentication Hashing Algorithm
password_encryption = scram-sha-256
```

### Paso 5.2: Configurar el mapa estricto de autenticación por host
Editar `/etc/postgresql/15/main/pg_hba.conf` para aplicar mTLS en las conexiones a la base de datos de microservicios:

```custom
# /etc/postgresql/15/main/pg_hba.conf
# TYPE  DATABASE        USER            ADDRESS                 METHOD

# Local Unix Domain Socket connections (local admin)
local   all             postgres                                peer

# Reject all unencrypted TCP connections
host    all             all             0.0.0.0/0               reject
host    all             all             ::/0                    reject

# Enforce mTLS + SCRAM-SHA-256 for Payment App Subnet
hostssl payment_db      payment_user    10.50.20.0/24           scram-sha-256 clientcert=verify-full

# Enforce mTLS + Client Cert Verification for Analytics Subnet
hostssl analytics_db    analytics_user  10.50.30.0/24           scram-sha-256 clientcert=verify-full
```

### Paso 5.3: Recargar PostgreSQL y validar el cumplimiento de las conexiones
Recargar el servicio PostgreSQL:
```bash
sudo systemctl reload postgresql
```

Verificar los requerimientos de conexión TLS utilizando `psql`:
Intento no cifrado (debería fallar de inmediato):
```bash
psql "host=10.50.10.15 port=5432 dbname=payment_db user=payment_user sslmode=disable"
```
*Resultado esperado:*
```text
psql: error: connection to server at "10.50.10.15", port 5432 failed: FATAL:  no pg_hba.conf entry for host "10.50.20.5", user "payment_user", database "payment_db", no SSL
```

Intento de conexión mTLS válido:
```bash
psql "host=10.50.10.15 port=5432 dbname=payment_db user=payment_user sslmode=verify-full sslcert=/etc/ssl/certs/payment_app.crt sslkey=/etc/ssl/private/payment_app.key sslrootcert=/etc/ssl/certs/db_root_ca.crt" -c "\conninfo"
```
*Resultado esperado:*
```text
You are connected to database "payment_db" as user "payment_user" on host "10.50.10.15" at port "5432".
SSL connection (protocol: TLSv1.3, cipher: TLS_AES_256_GCM_SHA384, bits: 256, compression: off)
```

---

### Preguntas de verificación (Ejercicio 5)
1. **¿Cuál es la diferencia criptográfica entre `clientcert=verify-ca` y `clientcert=verify-full` en el archivo `pg_hba.conf` de PostgreSQL?**
2. **¿Por qué `scram-sha-256` es significativamente más seguro que `md5` para la autenticación en PostgreSQL?**

---

<details>
<summary><strong>Haz clic aquí para revelar las soluciones y explicaciones detalladas</strong></summary>

### Clave de respuestas y justificación técnica del Ejercicio 1

1. **`X-XSS-Protection: 0` vs `"1; mode=block"`:**
   * Las especificaciones modernas de seguridad para navegadores aconsejan explícitamente deshabilitar `X-XSS-Protection` (estableciéndolo en `0`). Los auditores de XSS heredados integrados en navegadores más antiguos (como el XSS Auditor de Chrome) tenían fallos de implementación que podían ser aprovechados por atacantes para bloquear scripts legítimos o filtrar datos entre orígenes (creando vulnerabilidades de side-channel).
   * Las arquitecturas modernas con enfoque de Defense-in-Depth confían totalmente en una **Content Security Policy (CSP)** robusta (`Content-Security-Policy: default-src 'self'`) para eliminar limpiamente los vectores de XSS reflejado y almacenado.

2. **Impacto de la ausencia de `ssl_trusted_certificate` / `resolver` durante la verificación de OCSP Stapling:**
   * Cuando se configura `ssl_stapling_verify on`, Nginx debe verificar de forma independiente la firma criptográfica de la respuesta OCSP recibida del responder OCSP de la CA.
   * Si se omite `ssl_trusted_certificate` (que contiene la cadena intermedia y raíz de la CA) o un `resolver` válido (IP del servidor DNS), Nginx no logra validar la firma de la respuesta OCSP o no logra contactar la URL de OCSP. Esto hace que Nginx descarte por completo las respuestas de OCSP stapling (`OCSP response verification failed`), forzando a los clientes a recurrir a consultas OCSP directas, lo que introduce latencia en el handshake y degradación de la privacidad.

---

### Clave de respuestas y justificación técnica del Ejercicio 2

1. **Self-Contained Mode vs. Anomaly Scoring Mode:**
   * **Self-Contained Mode:** El WAF ejecuta inmediatamente una acción de interrupción (`403 Forbidden` / `500 Error`) ante la primera coincidencia de regla encontrada durante la inspección de la solicitud. Esto puede provocar un número excesivo de falsos positivos en payloads complejos.
   * **Anomaly Scoring Mode (por defecto en OWASP CRS):** Las reglas coincidentes no interrumpen inmediatamente la ejecución. En su lugar, las reglas incrementan una variable transaccional de anomaly score (por ejemplo, Critical = +5, Error = +4, Warning = +2). Al final de la Fase 2 (evaluación del Request Body), una regla de evaluación de umbral (`REQUEST-949-BLOCKING-EVALUATION.conf`) compara el puntaje total acumulado contra los límites configurados (por ejemplo, Inbound Threshold = 5). Si se supera, se toma una sola acción `403`. Esto mejora el contexto de la amenaza y reduce los falsos positivos.

2. **Mecánica del orden de exclusión de reglas en la Fase 1:**
   * ModSecurity opera en 5 fases discretas (1: Request Headers, 2: Request Body, 3: Response Headers, 4: Response Body, 5: Logging).
   * ModSecurity evalúa los archivos de configuración incluidos de forma secuencial. Los objetivos de las reglas (como `ARGS:payload`) deben eliminarse mediante acciones de control (`ctl:ruleRemoveTargetById`) **antes** de que la regla objetivo se ejecute realmente. Dado que las reglas de CRS inspeccionan encabezados en la Fase 1 y parámetros del cuerpo en la Fase 2, las exclusiones deben evaluarse en `phase:1` dentro de archivos incluidos **antes** de `owasp-crs/rules/*.conf`.

---

### Clave de respuestas y justificación técnica del Ejercicio 3

1. **Cómo `NoNewPrivileges=true` previene la elevación de SUID:**
   * Ejecutar un binario con el bit SUID establecido (`-rwsr-xr-x`) normalmente provoca que el kernel de Linux ejecute el binario bajo el contexto de seguridad del propietario del binario (típicamente `root`) en lugar del usuario invocador.
   * `NoNewPrivileges=true` establece la flag `PR_SET_NO_NEW_PRIVS` en el proceso a través de `prctl()`. Esta flag se hereda en las system calls `execve()` e indica explícitamente al kernel que ignore por completo los bits SUID/SGID y las file capabilities, asegurando que el proceso no pueda obtener privilegios más allá de su envolvente de ejecución existente.

2. **Impacto de `MemoryDenyWriteExecute=true` en los runtimes con JIT:**
   * `MemoryDenyWriteExecute=true` bloquea las solicitudes del proceso para crear mapeos de memoria que sean simultáneamente escribibles y ejecutables (`PROT_WRITE | PROT_EXEC`) o para modificar la protección de memoria existente de escribible a ejecutable (`mprotect()` / `pkey_mprotect()`).
   * Los compiladores Just-In-Time (JIT) (como Node.js V8, Java HotSpot y Python PyPy) compilan dinámicamente el bytecode en código de máquina nativo directamente en RAM, escribiendo instrucciones nativas en memoria y ejecutándolas posteriormente. Sin configurar modos que no usen JIT (por ejemplo, `--no-jit` en V8), `MemoryDenyWriteExecute` provoca la caída inmediata del proceso con una señal `SIGBUS` o `SIGSYS`.

---

### Clave de respuestas y justificación técnica del Ejercicio 4

1. **Requerimiento de doble ejecución de `pam_faillock.so`:**
   * **Fase `preauth`:** Se ejecuta *antes* de la evaluación de credenciales (`pam_unix`). Comprueba si la cuenta del usuario solicitante está actualmente bloqueada debido a fallos previos. Si está bloqueada, aborta el intento de autenticación de inmediato, evitando recalcular costosos hashes de contraseña (`argon2`/`sha512`) y protegiendo contra el agotamiento de recursos de CPU.
   * **Fase `authfail`:** Se ejecuta *después* de un intento fallido de autenticación. Incrementa el contador persistente de fallos registrado en `/var/run/faillock/` (o `/var/log/tallylog`) para el usuario.

2. **Riesgo de seguridad de ubicar erróneamente `pam_access.so` por debajo de `pam_unix.so`:**
   * En las flags de control de PAM, si un módulo está marcado como `sufficient` (lo que suele ser el caso de `pam_unix.so`) y devuelve éxito, PAM **omite inmediatamente todos los módulos restantes** en esa sección del stack y concede el acceso.
   * Si `pam_access.so` se ubica después de un `sufficient pam_unix.so` exitoso, sus reglas de acceso a la red (`/etc/security/access.conf`) nunca se evalúan, permitiendo que direcciones IP no autorizadas eludan los controles de acceso por origen de red.

---

### Clave de respuestas y justificación técnica del Ejercicio 5

1. **`clientcert=verify-ca` vs `clientcert=verify-full`:**
   * **`verify-ca`:** PostgreSQL verifica que el certificado de cliente presentado durante la negociación TLS sea válido y esté firmado por una Certificate Authority de confianza (`ssl_ca_file`). **No** contrasta el Common Name (CN) o Subject Alternative Name (SAN) del certificado con el nombre de usuario de la base de datos que se conecta.
   * **`verify-full`:** Aplica una verificación de identidad zero-trust criptográficamente completa: valida la firma de la cadena de CA **y** verifica que el CN/SAN del certificado coincida con el usuario de base de datos solicitado en la cadena de conexión (`user=payment_user`).

2. **Superioridad criptográfica de `scram-sha-256` sobre `md5`:**
   * El esquema heredado de autenticación `md5` de PostgreSQL calcula `md5(password + username)`, haciendo que los hashes sean vulnerables a precomputación de tablas rainbow, colisiones de hash y ataques de fuerza bruta offline si los logs de la base de datos o las tablas del sistema quedan expuestos.
   * `scram-sha-256` (Salted Challenge Response Authentication Mechanism) utiliza la derivación de claves PBKDF2 con SHA-256, salts aleatorios únicos por usuario, nonces criptográficos de cliente/servidor y pruebas de autenticación bidireccional. El hash de contraseña real nunca se transmite a través de la red, y la autenticación mutua previene ataques de suplantación de servidores maliciosos (rogue server impersonation).

</details>