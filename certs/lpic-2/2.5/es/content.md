# LPIC-2 (Exámenes 201-450 y 202-450, v4.5) Guía de Estudio Avanzada
## Tema 211 / 2.5: Servicios de Correo Electrónico (E-Mail Services) (Peso Total del Examen: 9)

---

## 1. Motivación Arquitectónica de Producción y Planteamiento del Problema

En entornos de producción empresariales, una infraestructura de correo electrónico (E-Mail Infrastructure) debe manejar de manera confiable miles de mensajes por segundo al tiempo que satisface estrictos requisitos de seguridad: cero retransmisión (relaying) no autorizada, autenticación estricta (SASL/TLS), verificación de identidad criptográfica (DKIM/SPF/DMARC) y acceso a almacenamiento de baja latencia para Mail User Agents (MUAs) concurrentes.

```
                      +--------------------------------------------------------+
                      |                 INTERNET / EXTERNAL MTAs              |
                      +--------------------------------------------------------+
                                       |                      ^
                             SMTP (Port 25)            SMTP (Port 25)
                                       v                      |
+---------------------------------------------------------------------------------------------------+
| BOUNDARY / MAIL TRANSFER AGENT (MTA) - POSTFIX                                                    |
|                                                                                                   |
|  +--------------------+     +---------------------+     +--------------------+                    |
|  |  smtpd (Port 25)   | --> | smtpd_recipient_   | --> | Milter (Rspamd/    |                    |
|  |  Submission (587)  |     | restrictions        |     | OpenDKIM/SpamAss.) |                    |
|  +--------------------+     +---------------------+     +--------------------+                    |
|                                                                  |                                |
|                                                                  v                                |
|  +--------------------+     +---------------------+     +--------------------+                    |
|  | incoming / active  | <-- | cleanup & trivial-  | <-- | Open Relay &       |                    |
|  | queues             |     | rewrite             |     | Header Check       |                    |
|  +--------------------+     +---------------------+     +--------------------+                    |
|            |                                                                                      |
|            v                                                                                      |
|  +--------------------+                                                                           |
|  | qmgr (Queue Mgr)   | --------------------+                                                     |
|  +--------------------+                     |                                                     |
|            | (Local Delivery)               | (Remote Delivery)                                   |
|            v                                v                                                     |
|  +--------------------+           +-------------------+                                           |
|  | lmtp / pipe driver |           | smtp transport    |                                           |
|  +--------------------+           +-------------------+                                           |
+-------------|-------------------------------+|----------------------------------------------------+
              |                                |
       LMTP (Unix Socket)                   SMTP (Port 25)
              v                                |
+------------------------------------+         |
| MAIL DELIVERY AGENT (MDA) - DOVECOT|         |
|                                    |         v
|  +-------------------------------+ |   External MX
|  | lmtp service                  | |   Destinations
|  +-------------------------------+ |
|                 |                  |
|                 v                  |
|  +-------------------------------+ |
|  | Maildir / mdbox storage       | |
|  | (/var/vmail/domain/user)      | |
|  +-------------------------------+ |
+-----------------|------------------+
                  |
     IMAP/IMAPS (143/993) / POP3S (995)
                  v
+------------------------------------+
| MAIL USER AGENTS (Thunderbird, etc)|
+------------------------------------+
```

### Desglose Arquitectónico de los Componentes:
1. **Mail Submission Agent (MSA - Puerto 587/465):** Recibe mensajes de MUAs autenticados utilizando TLS explícito (`STARTTLS`) o TLS implícito (`SMTPS`), aplicando autenticación SASL (`postfix/smtpd` + Dovecot SASL).
2. **Mail Transfer Agent (MTA - Puerto 25):** Maneja el reenvío entre servidores a través de SMTP. Aplica reglas estrictas de retransmisión (relay) (`smtpd_recipient_restrictions`) para prevenir vulnerabilidades de open relay, aplica milters para escaneo de DKIM/Spam y enruta mensajes en cola.
3. **Mail Delivery Agent (MDA):** Recibe mensajes validados del MTA (a través de socket LMTP o pipe local) y los guarda en almacenamiento no volátil de buzón en disco mientras aplica filtrado del lado del servidor (Sieve o Procmail).
4. **Mail Access Server (IMAP/POP3):** Expone el almacenamiento de buzones a los MUAs sobre protocolos encriptados con TLS (IMAPS/POP3S) con almacenamiento en caché de índices para mantener el rendimiento en buzones masivos.

---

## 2. Comparación Técnica y Matrices de Compromiso (Trade-offs)

### Arquitectura de Motores MTA: Postfix vs. Sendmail vs. Exim

| Característica / Dimensión | Postfix | Sendmail | Exim |
| :--- | :--- | :--- | :--- |
| **Modelo de Seguridad** | Diseño modular multiproceso con demonios de menor privilegio (`smtpd`, `cleanup`, `qmgr`, `local`) ejecutándose en chroot. | Binario monolítico (`sendmail`) ejecutando rutas de ejecución históricas con privilegios de root. | Binario único que se ejecuta con privilegios elevados; reduce dinámicamente los permisos según la operación. |
| **Complejidad de Configuración** | Pares clave-valor (`main.cf`) y búsquedas en tablas (`hash:`, `mysql:`, `lmdb:`). Alta legibilidad. | Preprocesador de macros M4 que genera un `sendmail.cf` complejo. Propenso a regresiones por errores de sintaxis. | Archivo de configuración único que soporta scripting en línea y regex. Altamente flexible, alta complejidad sintáctica. |
| **Rendimiento de Cola (Queue)** | Arquitectura de cola dividida highly optimizada (`incoming/`, `active/`, `deferred/`, `corrupt/`). Excelente bajo alta concurrencia. | Modelo de directorio de cola única. Se degrada bajo altas profundidades de cola (>50k mensajes). | Estructura de cola flexible, maneja ejecutores de cola personalizados de forma nativa. Rendimiento (throughput) moderadamente alto. |
| **Extensibilidad** | Protocolo Milter (`smtpd_milters`), Protocolos de Delegación de Políticas (Policy Delegation Protocols) y tablas de búsqueda de scripts externos. | API Milter nativa (creador original del protocolo). | Intérprete Perl embebido y capacidades de ejecución directa mediante pipe de shell. |

### Formatos de Almacenamiento de Buzón: Maildir vs. mbox vs. Dovecot dbox/mdbox

| Métrica | mbox | Maildir | Dovecot mdbox (Multi-dbox) |
| :--- | :--- | :--- | :--- |
| **Estructura** | Archivo de texto monolítico único que contiene todos los mensajes de una carpeta de usuario. | Directorio que contiene tres subdirectorios (`cur`, `new`, `tmp`). Un archivo por mensaje. | Múltiples mensajes empaquetados en archivos de almacenamiento más grandes con archivos de índice de metadatos separados. |
| **Bloqueo de Archivos y Concurrencia** | Requiere bloqueos de archivos obligatorios/recomendados (`fcntl`, `flock`, `.lock`). Alto riesgo de corrupción bajo escrituras concurrentes. | Operación sin bloqueos (lockless). Escrituras atómicas de mensajes mediante el movimiento de directorio de `tmp/` a `new/` (`rename()`). | Sincronización de índices sin bloqueos de alta concurrencia (`dovecot.index`). Cero contención de bloqueos. |
| **Sobrecarga de Almacenamiento** | Uso mínimo de inodos en el sistema de archivos (1 archivo por carpeta). | Alto consumo de inodos (1 inodo por mensaje de correo). | Huella de inodos optimizada (miles de correos por archivo de bloque de almacenamiento). |
| **Rendimiento de E/S y Búsqueda** | Se requiere lectura secuencial para localizar o eliminar mensajes; lento para buzones grandes. | Alta sobrecarga de `stat()` y `readdir()` de directorio en ext4/xfs sin indexación de directorios. | Rendimiento ultrarrápido de anexado (append) y purga (expunge) con cero penalización por recorrido de directorios POSIX. |

### MDA y Mecanismos de Filtrado: Dovecot LMTP + Sieve vs. Procmail Heredado (Legacy)

| Aspecto | Dovecot LMTP + Sieve | Legacy Procmail |
| :--- | :--- | :--- |
| **Integración de Protocolos** | Local Mail Transfer Agent (LMTP) nativo ejecutándose como un servicio de socket Unix persistente. | Ejecutado como un proceso hijo generado por mensaje por el agente de entrega `local` del MTA. |
| **Estandarización** | Lenguaje de scripting declarativo compatible con RFC 5228 con extensiones estructuradas. | Sintaxis de reglas regex personalizada (flags `:0 hb`) escrita en sintaxis de macros tipo shell. |
| **Sobrecarga de Recursos** | Baja (reutiliza pools de procesos Dovecot persistentes ya activos). | Alta (sobrecarga del pipeline fork/exec por cada entrega de correo entrante). |
| **UTF-8 / Internacionalización** | Soporte nativo para el análisis (parsing) unicode de encabezado y cuerpo. | Análisis regex limitado/heredado orientado a bytes (requiere soluciones alternativas mediante pipe externo). |

---

## 3. Configuraciones de Producción y Manifiestos de Infraestructura

### 3.1 Configuración Principal de Postfix (`/etc/postfix/main.cf`)

```ini
# =========================================================================
# /etc/postfix/main.cf - Production Enterprise Postfix MTA Configuration
# =========================================================================

# System Identification
smtpd_banner = $myhostname ESMTP $mail_name (Ubuntu/GNU)
biff = no
append_dot_mydomain = no
readme_directory = no
compatibility_level = 3.6

# Global Network Identity
myhostname = mx1.example.com
alias_maps = hash:/etc/aliases
alias_database = hash:/etc/aliases
mydestination = $myhostname, localhost.$mydomain, localhost
relayhost = 
mynetworks = 127.0.0.0/8 [::1]/128 192.168.10.0/24
mailbox_size_limit = 0
recipient_delimiter = +
inet_interfaces = all
inet_protocols = all

# TLS Configuration - Server (Incoming Connections)
smtpd_tls_cert_file = /etc/letsencrypt/live/mx1.example.com/fullchain.pem
smtpd_tls_key_file = /etc/letsencrypt/live/mx1.example.com/privkey.pem
smtpd_tls_security_level = may
smtpd_tls_auth_only = yes
smtpd_tls_protocols = !SSLv2, !SSLv3, !TLSv1, !TLSv1.1
smtpd_tls_ciphers = high
smtpd_tls_mandatory_protocols = !SSLv2, !SSLv3, !TLSv1, !TLSv1.1
smtpd_tls_mandatory_ciphers = high
smtpd_tls_loglevel = 1
smtpd_tls_received_header = yes

# TLS Configuration - Client (Outgoing Relay Connections)
smtp_tls_security_level = dane
smtp_tls_loglevel = 1
smtp_dns_support_level = dnssec
smtp_tls_CAfile = /etc/ssl/certs/ca-certificates.crt

# SASL Authentication Setup (Delegated to Dovecot Unix Socket)
smtpd_sasl_type = dovecot
smtpd_sasl_path = private/auth
smtpd_sasl_auth_enable = yes
smtpd_sasl_security_options = noanonymous
smtpd_sasl_local_domain = $myhostname
broken_sasl_auth_clients = yes

# Virtual Domain & Mailbox Architecture (Mapped to Dovecot MDA via LMTP)
virtual_mailbox_domains = hash:/etc/postfix/vmail_domains
virtual_mailbox_maps = hash:/etc/postfix/vmail_mailbox
virtual_alias_maps = hash:/etc/postfix/virtual_aliases
virtual_transport = lmtp:unix:private/dovecot-lmtp

# Hardened Open Relay Prevention & Access Control Restrictions
smtpd_helo_required = yes
smtpd_helo_restrictions =
    permit_mynetworks,
    permit_sasl_authenticated,
    reject_invalid_helo_hostname,
    reject_non_fqdn_helo_hostname,
    reject_unknown_helo_hostname

smtpd_sender_restrictions =
    permit_mynetworks,
    permit_sasl_authenticated,
    reject_non_fqdn_sender,
    reject_unknown_sender_domain

smtpd_recipient_restrictions =
    permit_mynetworks,
    permit_sasl_authenticated,
    reject_non_fqdn_recipient,
    reject_unknown_recipient_domain,
    reject_unauth_destination,
    reject_rbl_client zen.spamhaus.org,
    reject_rbl_client bl.spamcop.net

smtpd_relay_restrictions =
    permit_mynetworks,
    permit_sasl_authenticated,
    reject_unauth_destination

# Milter Integration (OpenDKIM / Spam scanning)
smtpd_milters = inet:127.0.0.1:8891
non_smtpd_milters = $smtpd_milters
milter_default_action = accept
milter_protocol = 6

# Rate Limiting & Resource Protection
smtpd_client_connection_count_limit = 50
smtpd_client_connection_rate_limit = 100
anvil_rate_time_unit = 60s
```

### 3.2 Manifiesto del Demonio del Servicio Maestro de Postfix (`/etc/postfix/master.cf`)

```ini
# ==========================================================================
# /etc/postfix/master.cf - Process Execution and Port Listener Specification
# ==========================================================================
# service type  private unpriv  chroot  wakeup  maxproc command + args
#               (yes)   (yes)   (no)    (never) (100)
# ==========================================================================
smtp       inet  n       -       y       -       -       smtpd
# Standard Submission Service over Explicit TLS (Port 587)
submission inet  n       -       y       -       -       smtpd
  -o syslog_name=postfix/submission
  -o smtpd_tls_security_level=encrypt
  -o smtpd_sasl_auth_enable=yes
  -o smtpd_tls_auth_only=yes
  -o smtpd_reject_unlisted_recipient=no
  -o smtpd_client_restrictions=permit_sasl_authenticated,reject
  -o smtpd_helo_restrictions=permit_sasl_authenticated,reject
  -o smtpd_sender_restrictions=permit_sasl_authenticated,reject
  -o smtpd_recipient_restrictions=permit_sasl_authenticated,reject
  -o milter_macro_daemon_name=ORIGINATING

# Implicit SMTPS Service over Direct SSL/TLS (Port 465)
smtps      inet  n       -       y       -       -       smtpd
  -o syslog_name=postfix/smtps
  -o smtpd_tls_wrappermode=yes
  -o smtpd_sasl_auth_enable=yes
  -o smtpd_reject_unlisted_recipient=no
  -o smtpd_client_restrictions=permit_sasl_authenticated,reject
  -o milter_macro_daemon_name=ORIGINATING

# Core Internal Postfix Pipeline Services
pickup    unix  n       -       y       0       1       pickup
cleanup   unix  n       -       y       -       0       cleanup
qmgr      unix  n       -       n       300     1       qmgr
tlsmgr    unix  -       -       y       1000?   1       tlsmgr
rewrite   unix  -       -       y       -       -       trivial-rewrite
bounce    unix  -       -       y       -       0       bounce
defer     unix  -       -       y       -       0       bounce
trace     unix  -       -       y       -       0       bounce
verify    unix  -       -       y       -       1       verify
flush     unix  n       -       y       1000?   0       flush
proxymap  unix  -       -       n       -       -       proxymap
proxywrite unix -       -       n       -       1       proxymap
smtp      unix  -       -       y       -       -       smtp
relay     unix  -       -       y       -       -       smtp
        -o syslog_name=postfix/$service_name
showq     unix  n       -       y       -       -       showq
error     unix  -       -       y       -       -       error
retry     unix  -       -       y       -       -       error
discard   unix  -       -       y       -       -       discard
local     unix  -       n       n       -       -       local
virtual   unix  -       n       n       -       -       virtual
lmtp      unix  -       -       y       -       -       lmtp
anvil     unix  -       -       y       -       1       anvil
scache    unix  -       -       y       -       1       scache
postlog   unix  -       -       n       -       1       postlogd
```

### 3.3 Archivos de Mapa de Postfix

#### `/etc/postfix/vmail_domains`
```text
example.com     OK
lab.internal    OK
```

#### `/etc/postfix/vmail_mailbox`
```text
admin@example.com    example.com/admin/Maildir/
user01@example.com   example.com/user01/Maildir/
devops@lab.internal  lab.internal/devops/Maildir/
```

#### `/etc/postfix/virtual_aliases`
```text
info@example.com     admin@example.com
support@example.com  admin@example.com, user01@example.com
```

### 3.4 Configuración Principal Maestro y Autenticación de Dovecot

#### `/etc/dovecot/dovecot.conf`
```ini
# Dovecot 2.3+ Production Configuration
protocols = imap pop3 lmtp
listen = *, [::]
base_dir = /var/run/dovecot/
instance_name = dovecot
dict {
}
!include conf.d/*.conf
```

#### `/etc/dovecot/conf.d/10-mail.conf`
```ini
mail_location = maildir:/var/vmail/%d/%n/Maildir
mail_uid = 5000
mail_gid = 5000
mail_privileged_group = vmail
first_valid_uid = 500
last_valid_uid = 0
```

#### `/etc/dovecot/conf.d/10-auth.conf`
```ini
disable_plaintext_auth = yes
auth_mechanisms = plain login
!include auth-sql.conf.ext
```

#### `/etc/dovecot/conf.d/auth-sql.conf.ext`
```ini
passdb {
  driver = static
  args = scheme=ARGON2ID password={ARGON2ID}$v=19$m=65536,t=3,p=4$c29tZXNhbHQ$W245...
}

userdb {
  driver = static
  args = uid=vmail gid=vmail home=/var/vmail/%d/%n
}
```

#### `/etc/dovecot/conf.d/10-master.conf`
```ini
service imap-login {
  inet_listener imap {
    port = 143
  }
  inet_listener imaps {
    port = 993
    ssl = yes
  }
}

service lmtp {
  unix_listener /var/spool/postfix/private/dovecot-lmtp {
    mode = 0660
    user = postfix
    group = postfix
  }
}

service auth {
  # Exposed to Postfix smtpd daemon for SASL
  unix_listener /var/spool/postfix/private/auth {
    mode = 0660
    user = postfix
    group = postfix
  }

  # Auth listener for internal Dovecot processes
  unix_listener auth-userdb {
    mode = 0600
    user = vmail
    group = vmail
  }
}

service auth-worker {
  user = root
}
```

#### `/etc/dovecot/conf.d/20-lmtp.conf`
```ini
protocol lmtp {
  postmaster_address = postmaster@example.com
  mail_plugins = $mail_plugins sieve
}
```

### 3.5 Manifiestos de Filtrado de Entrega

#### Filtro Global Dovecot Sieve (`/var/lib/dovecot/sieve/default.sieve`)
```sieve
require ["fileinto", "mailbox", "envelope", "subaddress"];

# Automatically route incoming spam headers into Junk folder
if header :contains "X-Spam-Flag" "YES" {
    fileinto :create "Junk";
    stop;
}

# Subaddressing logic (e.g. user+alerts@example.com -> Alerts folder)
if envelope :detail "recipient" "alerts" {
    fileinto :create "Alerts";
    stop;
}
```

#### Configuración Heredada de Procmail (`/etc/procmailrc`)
```procmail
# Global Procmail Configuration
SHELL=/bin/sh
PATH=/usr/bin:/bin
MAILDIR=$HOME/Maildir
DEFAULT=$MAILDIR/
LOGFILE=/var/log/procmail.log
VERBOSE=off

# Rule 1: Quarantine High Score Spam
:0:
* ^X-Spam-Status: Yes
.Junk/

# Rule 2: Automatically file system notification alerts
:0:
* ^Subject:.*\[CRITICAL ALERT\]
.Alerts/
```

---

## 4. Ejecución Real en CLI y Salida Realista de Terminal

### 4.1 Compilación y Verificación de Mapas de Postfix (`postmap`, `newaliases`, `postconf`)

```bash
$ sudo postmap /etc/postfix/vmail_domains
$ sudo postmap /etc/postfix/vmail_mailbox
$ sudo postmap /etc/postfix/virtual_aliases
$ sudo newaliases
```

#### Consulta de la Configuración Activa en Tiempo de Ejecución de Postfix:
```bash
$ postconf -n myhostname smtpd_recipient_restrictions virtual_transport
```
```text
myhostname = mx1.example.com
smtpd_recipient_restrictions = permit_mynetworks, permit_sasl_authenticated, reject_non_fqdn_recipient, reject_unknown_recipient_domain, reject_unauth_destination, reject_rbl_client zen.spamhaus.org, reject_rbl_client bl.spamcop.net
virtual_transport = lmtp:unix:private/dovecot-lmtp
```

#### Consulta de Búsqueda en Tablas a través de `postmap`:
```bash
$ postmap -q "admin@example.com" hash:/etc/postfix/vmail_mailbox
```
```text
example.com/admin/Maildir/
```

---

### 4.2 Inspección y Gestión de la Cola (`postqueue`, `postsuper`, `mailq`)

#### Inspección de la Cola de Correo Actual:
```bash
$ mailq
```
```text
-Queue ID- --Size-- ----Arrival Time---- -Sender/Recipient-------
4Sy3kL09zZz10A    1420 Thu Aug  6 10:15:02  deployer@example.com
(connect to mail.remote-domain.org[203.0.113.50]:25: Connection refused)
                                         recipient@remote-domain.org

4Sy3mN42xYz10B    2048 Thu Aug  6 10:18:44  alert@example.com
                                         oncall@example.com

-- 3 Kbytes in 2 Requests.
```

#### Vaciado (Flushing) de la Cola (Forzando Intento de Entrega Inmediato):
```bash
$ sudo postqueue -f
```

#### Eliminación de un Mensaje Específico de la Cola por Queue ID:
```bash
$ sudo postsuper -d 4Sy3kL09zZz10A
```
```text
postsuper: 4Sy3kL09zZz10A: removed
```

#### Purga de Todos los Mensajes Diferidos de la Cola:
```bash
$ sudo postsuper -d ALL deferred
```
```text
postsuper: Deleted: 1 message
```

---

### 4.3 Verificación Interactiva de Protocolo a Bajo Nivel

#### Prueba de SMTP MSA (Puerto 587) con STARTTLS y Autenticación SASL PLAIN en Base64
```bash
$ openssl s_client -connect mx1.example.com:587 -starttls smtp -crlf
```
```text
CONNECTED(00000003)
---
Certificate chain
 0 s:CN = mx1.example.com
   i:C = US, O = Let's Encrypt, CN = R3
---
220 mx1.example.com ESMTP Postfix
EHLO client.example.com
250-mx1.example.com
250-PIPELINING
250-SIZE 104857600
250-VRFY
250-ETRN
250-AUTH PLAIN LOGIN
250-ENHANCEDSTATUSCODES
250-8BITMIME
250 DSN
AUTH PLAIN dXNlcjAxQGV4YW1wbGUuY29tAHVzZXIwMUBleGFtcGxlLmNvbQBTZWNyZXRQYXNzMTIzIQ==
235 2.7.0 Authentication successful
MAIL FROM:<user01@example.com>
250 2.1.0 Ok
RCPT TO:<admin@example.com>
250 2.1.5 Ok
DATA
354 End data with <CR><LF>.<CR><LF>
Subject: Production System Test

Testing Postfix SMTP submission pipeline.
.
250 2.0.0 Ok: queued as 4Sy4bM11xZz10C
QUIT
221 2.0.0 Bye
closed
```

#### Prueba de Dovecot IMAP sobre SSL (Puerto 993) mediante `openssl s_client`
```bash
$ openssl s_client -connect mx1.example.com:993 -crlf
```
```text
CONNECTED(00000003)
* OK [CAPABILITY IMAP4rev1 SASL-IR LOGIN-REFERRALS ID ENABLE IDLE LITERAL+ AUTH=PLAIN] Dovecot ready.
A01 LOGIN user01@example.com SecretPass123!
A01 OK [CAPABILITY IMAP4rev1 SASL-IR LOGIN-REFERRALS ID ENABLE IDLE LITERAL+ SPECIAL-USE] Logged in
A02 SELECT INBOX
* FLAGS (\Answered \Flagged \Deleted \Seen \Draft)
* OK [PERMANENTFLAGS (\Answered \Flagged \Deleted \Seen \Draft \*)] Flags permitted.
* 1 EXISTS
* 0 RECENT
* OK [UNSEEN 1] First unseen.
* OK [UIDVALIDITY 1691234567] UIDs valid
* OK [UIDNEXT 2] Predicted next UID
A02 OK [READ-WRITE] Select completed (0.001 secs).
A03 FETCH 1 BODY[TEXT]
* 1 FETCH (BODY[TEXT] {43}
Testing Postfix SMTP submission pipeline.
)
A03 OK Fetch completed (0.001 secs).
A04 LOGOUT
* BYE Logging out
A04 OK Logout completed.
closed
```

#### Prueba de Diagnósticos CLI de Dovecot con `doveadm`
```bash
$ sudo doveadm user "user01@example.com"
```
```text
field   value
uid     5000
gid     5000
home    /var/vmail/example.com/user01
mail    maildir:/var/vmail/example.com/user01/Maildir
```

```bash
$ sudo doveadm mailbox status -u user01@example.com all INBOX
```
```text
mailbox messages unseen recent messages.mailbox uidnext uidvalidity
INBOX   1        1      0      1                2       1691234567
```

---

## 5. Guía (Playbook) de Verificación y Diagnóstico de Fallas

### 5.1 Diagrama de Flujo Diagnóstico

```
                 [Mail Delivery Issue Reported]
                               |
                               v
                     Inspect Mail Logs:
          /var/log/mail.log or journalctl -u postfix
                               |
            +------------------+------------------+
            |                                     |
    (SMTP Connect Error)                 (SASL / TLS Failure)
            |                                     |
            v                                     v
 1. Check Listening Ports:            1. Verify Certificate Validity:
    `ss -tulpn | grep -E ':25|:587'`     `openssl x509 -in cert.pem -text`
 2. Verify Firewall/Security:        2. Check Dovecot Socket Perms:
    `nft list ruleset`                  `ls -la /var/spool/postfix/private/auth`
 3. Test HELO/EHLO explicitly.        3. Test SASL via `testsaslauthd`.
            |                                     |
            +------------------+------------------+
                               |
                               v
                     (LMTP / MDA Delivery Error)
                               |
                               v
                    1. Check Dovecot LMTP Socket:
                       `ls -la /var/spool/postfix/private/dovecot-lmtp`
                    2. Check Maildir Ownership:
                       `chown -R vmail:vmail /var/vmail`
                    3. Validate Sieve Compiler Syntax:
                       `sievec /path/to/script.sieve`
```

---

### 5.2 Escenarios de Falla y Remediación Dirigida

#### Escenario 1: Intento de Open Relay Rechazado (454 / 554 Relay Access Denied)
* **Patrón de Log (`/var/log/mail.log`):**
  ```text
  postfix/smtpd[14210]: NOQUEUE: reject: RCPT from unknown[198.51.100.44]: 554 5.7.1 <victim@external.org>: Relay access denied; from=<spammer@external.org> proto=ESMTP helo=<badactor.com>
  ```
* **Causa Raíz:** Un host externo intentó retransmitir correo a través del puerto 25 sin coincidir con `mynetworks` ni proporcionar credenciales SASL válidas.
* **Comando de Verificación:**
  ```bash
  $ postconf -d smtpd_relay_restrictions
  ```
* **Remediación:** Asegurar que `smtpd_relay_restrictions = permit_mynetworks, permit_sasl_authenticated, reject_unauth_destination` esté configurado explícitamente en `main.cf`.

#### Escenario 2: Permiso Denegado en Dovecot LMTP (`connect to private/dovecot-lmtp failed`)
* **Patrón de Log (`/var/log/mail.log`):**
  ```text
  postfix/lmtp[14533]: 4Sy4yN11xZz10D: to=<user01@example.com>, relay=none, delay=0.03, delays=0.01/0.01/0.01/0, status=deferred (cannot connect to private/dovecot-lmtp: Permission denied)
  ```
* **Causa Raíz:** El proceso `lmtp` de Postfix ejecutado bajo el usuario `postfix` no puede acceder al socket de dominio Unix `/var/spool/postfix/private/dovecot-lmtp`.
* **Chequeo Diagnóstico:**
  ```bash
  $ ls -la /var/spool/postfix/private/dovecot-lmtp
  ```
  *Salida:* `srwxrwxrwx 1 root root 0 Aug 6 10:00 /var/spool/postfix/private/dovecot-lmtp` (Propiedad incorrecta).
* **Remediación:** Actualizar `/etc/dovecot/conf.d/10-master.conf`:
  ```ini
  service lmtp {
    unix_listener /var/spool/postfix/private/dovecot-lmtp {
      mode = 0660
      user = postfix
      group = postfix
    }
  }
  ```
  Luego recargar Dovecot: `sudo systemctl reload dovecot`.

#### Escenario 3: Falla de Autenticación SASL (`SASL authentication failed: invalid parameter`)
* **Patrón de Log (`/var/log/mail.log`):**
  ```text
  postfix/smtpd[14890]: warning: SASL authentication failure: cannot connect to Dovecot authentication socket /var/spool/postfix/private/auth: No such file or directory
  postfix/smtpd[14890]: warning: client.example.com[192.0.2.15]: SASL PLAIN authentication failed: generic failure
  ```
* **Causa Raíz:** El `main.cf` de Postfix apunta `smtpd_sasl_path` a `private/auth`, pero el listener de socket de autenticación de Dovecot está deshabilitado o la ruta no coincide.
* **Remediación:** Asegurar que la ruta del socket en `/etc/dovecot/conf.d/10-master.conf` bajo `service auth` coincida con la ruta relativa del chroot jail de Postfix:
  ```ini
  service auth {
    unix_listener /var/spool/postfix/private/auth {
      mode = 0660
      user = postfix
      group = postfix
    }
  }
  ```

#### Escenario 4: Bloqueo de Inodos/Permisos en Maildir (`Permission denied` en entrega)
* **Patrón de Log (`/var/log/mail.log`):**
  ```text
  dovecot: lmtp(15102): Error: maildir_storage: open(/var/vmail/example.com/user01/Maildir/tmp/16912345.M123P15102.mx1) failed: Permission denied (euid=5000(vmail) egid=5000(vmail) missing +w perm on /var/vmail/example.com/user01/Maildir/tmp)
  ```
* **Causa Raíz:** La estructura de directorios `/var/vmail/` fue creada por root u otro usuario, impidiendo que `vmail` (UID 5000) escriba nuevos archivos de mensaje.
* **Comando de Remediación:**
  ```bash
  $ sudo chown -R 5000:5000 /var/vmail
  $ sudo chmod -R 770 /var/vmail
  ```

---

## 6. Referencias

* **Objetivos Oficiales de LPI LPIC-2 v4.5:**  
  [https://wiki.lpi.org/wiki/LPIC-2_Objectives_V4.5](https://wiki.lpi.org/wiki/LPIC-2_Objectives_V4.5)

* **Parámetros de Configuración y Documentación de Postfix:**  
  [https://www.postfix.org/postconf.5.html](https://www.postfix.org/postconf.5.html)

* **Readme de SASL de Postfix e Integración con Dovecot:**  
  [https://www.postfix.org/SASL_README.html](https://www.postfix.org/SASL_README.html)

* **Documentación Principal de Dovecot v2.3:**  
  [https://doc.dovecot.org/](https://doc.dovecot.org/)

* **Pigeonhole Sieve para Dovecot:**  
  [https://doc.dovecot.org/configuration_manual/sieve/](https://doc.dovecot.org/configuration_manual/sieve/)

* **RFC 5321 - Simple Mail Transfer Protocol (SMTP):**  
  [https://datatracker.ietf.org/doc/html/rfc5321](https://datatracker.ietf.org/doc/html/rfc5321)

* **RFC 7208 - Sender Policy Framework (SPF):**  
  [https://datatracker.ietf.org/doc/html/rfc7208](https://datatracker.ietf.org/doc/html/rfc7208)

* **RFC 6376 - DomainKeys Identified Mail (DKIM) Signatures:**  
  [https://datatracker.ietf.org/doc/html/rfc6376](https://datatracker.ietf.org/doc/html/rfc6376)

* **RFC 7489 - Domain-based Message Authentication, Reporting, and Conformance (DMARC):**  
  [https://datatracker.ietf.org/doc/html/rfc7489](https://datatracker.ietf.org/doc/html/rfc7489)