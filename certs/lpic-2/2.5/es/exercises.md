# LPIC-2 (Exámenes 201-450 & 202-450, v4.5) — Tema 2.5: Servicios de E-Mail

**Peso del examen:** 9 (Tema 211 en v4.5: 211.1 Uso de servidores de E-Mail [Peso 4], 211.2 Gestión de entrega de E-Mail [Peso 2], 211.3 Gestión de acceso a buzones [Peso 2])  
**Público objetivo:** SREs, arquitectos de sistemas e ingenieros de infraestructura que gestionan Mail Transfer Agents (MTA) y Mail Delivery Agents (MDA) empresariales.

---

## Visión general técnica y fundamentos de arquitectura

La infraestructura de e-mail empresarial requiere una separación clara entre **Mail Transfer Agents (MTAs)** (ej. Postfix), **Mail Delivery Agents (MDAs)** (ej. Dovecot LDA/LMTP) y **Protocolos de acceso a correo** (IMAP/POP3).

```
 +-----------------------------------------------------------------------------------+
 |                                   POSTFIX MTA                                     |
 |                                                                                   |
 |  [ Network ] ---> ( smtpd ) ---> [ cleanup ] ---> [ incoming queue ]              |
 |                                                       |                           |
 |                                                       v                           |
 |                                                [ qmgr queue ] <---> ( trivial-    |
 |                                                       |              rewrite )    |
 |                                                       v                           |
 |                                             +------------------+                  |
 |                                             | Router / Delivery|                  |
 |                                             +------------------+                  |
 |                                               /              \                    |
 |                                              /                \                   |
 |                                             v                  v                  |
 |                                    ( smtp client )        ( local / lmtp )        |
 +-------------------------------------------|----------------------|----------------+
                                             |                      |
                                             v                      v
                                      [ Remote MTA ]       [ Dovecot MDA / LMTP ]
                                                                    |
                                                                    v
                                                             [ Maildir/Storage ]
                                                                    ^
                                                                    |
                                                           ( dovecot imap/pop3 )
                                                                    ^
                                                                    |
                                                           [ TLS 993/995 / MUA ]
```

### Arquitectura de Postfix y ciclo de vida de la cola
1. **`smtpd`**: Recibe conexiones SMTP entrantes, aplica TLS, SASL, verificaciones HELO/EHLO y restricciones de acceso de clientes.
2. **`cleanup`**: Normaliza encabezados, añade encabezados `Message-Id` o `Date` faltantes, transforma direcciones y escribe mensajes en el directorio de la cola `incoming` (`/var/spool/postfix/incoming`).
3. **`qmgr` (Queue Manager)**: El despachador central. Mueve mensajes entre colas (`incoming`, `active`, `deferred`, `hold`, `corrupt`) y programa intentos de entrega sin bloquear los hilos de ejecución.
4. **`trivial-rewrite`**: Resuelve direcciones de destino contra tablas de búsqueda (`transport`, `virtual_alias_maps`, `virtual_mailbox_maps`) para determinar si el correo está destinado al almacenamiento local, virtual hosting o relay remoto.
5. **Daemons de entrega**:
   - **`smtp`**: Cliente saliente que envía correo a dominios externos a través de registros MX o relayhosts.
   - **`local`**: Entrega correo a cuentas tradicionales del sistema UNIX, archivos `/etc/aliases` y `.forward`.
   - **`virtual`**: Entrega correo a buzones de usuarios virtuales no pertenecientes a UNIX.
   - **`pipe`**: Transfiere mensajes a programas externos (ej. scripts MDA legacy o escáneres de spam).
   - **`lmtp`**: Se conecta mediante Local Mail Transport Protocol a Dovecot para el almacenamiento en buzones y la ejecución de scripts de Sieve.

---

## Ejercicio 1: Configuración de MTA, dominios virtuales y Secure Relay

### Objetivo
Configurar un MTA Postfix para entornos de producción que soporte dominios virtuales, cifrado TLS 1.2/1.3, autenticación SASL vía Dovecot y anulaciones de mapas de transporte (transport map overrides).

### Paso 1: Inspeccionar y configurar `main.cf`
1. Ejecutá el siguiente comando para revisar los parámetros de configuración de Postfix activos que no son por defecto:
   ```bash
   postconf -n
   ```
2. Editá `/etc/postfix/main.cf` para implementar el siguiente manifiesto de producción sintácticamente válido:
   ```ini
   # /etc/postfix/main.cf - Production Core Configuration
   
   # Server Identification & Network Interfaces
   myhostname = mail.prod.infra.net
   mydomain = prod.infra.net
   myorigin = $mydomain
   inet_interfaces = all
   inet_protocols = ipv4, ipv6
   mydestination = $myhostname, localhost.$mydomain, localhost
   
   # TLS Configuration (Inbound and Outbound)
   smtpd_tls_security_level = may
   smtpd_tls_cert_file = /etc/letsencrypt/live/mail.prod.infra.net/fullchain.pem
   smtpd_tls_key_file = /etc/letsencrypt/live/mail.prod.infra.net/privkey.pem
   smtpd_tls_protocols = !SSLv2, !SSLv3, !TLSv1, !TLSv1.1
   smtpd_tls_mandatory_protocols = !SSLv2, !SSLv3, !TLSv1, !TLSv1.1
   smtp_tls_security_level = encrypt
   smtp_tls_loglevel = 1
   
   # SASL Authentication (via Dovecot UNIX Socket)
   smtpd_sasl_type = dovecot
   smtpd_sasl_path = private/auth
   smtpd_sasl_auth_enable = yes
   smtpd_sasl_security_options = noanonymous
   smtpd_sasl_tls_security_options = $smtpd_sasl_security_options
   
   # Access Restrictions (Relay & Anti-Spam Pipeline)
   smtpd_helo_required = yes
   smtpd_relay_restrictions = permit_mynetworks, permit_sasl_authenticated, reject_unauth_destination
   smtpd_recipient_restrictions = permit_mynetworks, permit_sasl_authenticated, reject_unauth_destination, reject_rbl_client zen.spamhaus.org
   
   # Virtual Domain & Maildir Delivery Options
   virtual_mailbox_domains = hash:/etc/postfix/virtual_domains
   virtual_alias_maps = hash:/etc/postfix/virtual_aliases
   virtual_transport = lmtp:unix:private/dovecot-lmtp
   
   # Routing Overrides
   transport_maps = hash:/etc/postfix/transport
   ```

### Paso 2: Configurar dominios virtuales, alias y mapas de transporte
1. Creá `/etc/postfix/virtual_domains`:
   ```text
   example.com         OK
   cloud-ops.org       OK
   ```
2. Creá `/etc/postfix/virtual_aliases`:
   ```text
   postmaster@example.com      admin@prod.infra.net
   devops@example.com          alice@example.com, bob@example.com
   info@cloud-ops.org          support@prod.infra.net
   ```
3. Creá `/etc/postfix/transport` para forzar un enrutamiento específico (ej. enrutar el tráfico interno legacy a través de un gateway interno dedicado):
   ```text
   internal.legacy.net         smtp:[10.240.0.50]:25
   ```
4. Compilá las tablas de búsqueda en archivos Berkley DB (`.db`) indexados usando `postmap`:
   ```bash
   sudo postmap /etc/postfix/virtual_domains
   sudo postmap /etc/postfix/virtual_aliases
   sudo postmap /etc/postfix/transport
   sudo newaliases
   ```
5. Recargá Postfix para aplicar todos los cambios:
   ```bash
   sudo postfix reload
   ```

### Paso 3: Validar las operaciones del MTA mediante CLI
1. Verificá la generación de las bases de datos:
   ```bash
   ls -l /etc/postfix/*.db
   ```
   *Salida esperada:*
   ```text
   -rw-r--r-- 1 root root 12288 Aug  6 10:00 /etc/postfix/transport.db
   -rw-r--r-- 1 root root 12288 Aug  6 10:00 /etc/postfix/virtual_aliases.db
   -rw-r--r-- 1 root root 12288 Aug  6 10:00 /etc/postfix/virtual_domains.db
   ```

2. Probá la resolución de direcciones de destino utilizando `postmap -q`:
   ```bash
   postmap -q "devops@example.com" hash:/etc/postfix/virtual_aliases
   ```
   *Salida esperada:*
   ```text
   alice@example.com, bob@example.com
   ```

---

### Preguntas de verificación — Ejercicio 1

#### Pregunta 1.1
¿Cuál es el riesgo arquitectónico preciso de configurar `smtpd_relay_restrictions = permit_mynetworks, permit_sasl_authenticated` *sin* incluir `reject_unauth_destination` al final de la cadena de evaluación?

#### Pregunta 1.2
¿Cómo maneja el daemon `cleanup` de Postfix los mensajes entrantes en comparación con `qmgr`? ¿Qué sucede si `cleanup` se bloquea (crashea) mientras recibe un mensaje de `smtpd`?

---

## Ejercicio 2: Gestión de colas, resolución de problemas operacionales y diagnóstico avanzado de MTA

### Objetivo
Dominar la inspección de la estructura de la cola de Postfix, la manipulación de mensajes, el vaciado de la cola y el rastreo de logs de bajo nivel utilizando utilidades nativas (`postqueue`, `postsuper`, `postcat`).

```
 Queue Lifecycle Path:
 [ incoming ] ---> [ active ] ---> [ deferred ] (Retries via exponential backoff)
                       |                  |
                       v                  v
                   (Delivered)     [ hold ] (Manual Admin Intervention)
```

### Paso 1: Inspeccionar el estado y la estructura de la cola
1. Listá todos los mensajes actualmente en cola a través de los directorios del spool de correo `active`, `incoming` y `deferred`:
   ```bash
   postqueue -p
   ```
   *Salida esperada:*
   ```text
   -Queue ID-  --Size-- ----Arrival Time---- -Sender/Recipient-------
   4Vxy9L12zZz*    1420 Thu Aug  6 09:12:01  bounce-service@cloud-ops.org
                                            unreachable-user@external-partner.com

   4VxyDF56xYy     2851 Thu Aug  6 09:30:44  alert@prod.infra.net
   (connect to mail.external-partner.com[198.51.100.25]:25: Connection timed out)
                                            sysadmin@external-partner.com

   -- 4 Kbytes in 2 Requests.
   ```
   *(Nota: Un Queue ID seguido de `*` indica que el mensaje se encuentra actualmente en la cola `active`; un Queue ID seguido de `!` indica que el mensaje está en `hold`.)*

### Paso 2: Inspección profunda de archivos de cola vía `postcat`
1. Inspeccioná los metadatos del envelope, los encabezados del mensaje y el cuerpo sin formato (raw body) del Queue ID `4VxyDF56xYy`:
   ```bash
   sudo postcat -q 4VxyDF56xYy
   ```
   *Fragmento de la salida esperada:*
   ```text
   *** QUEUE FILE HEADER ***
   rec_type: V  min_attr: 0
   sender: alert@prod.infra.net
   recipient: sysadmin@external-partner.com
   *** HEADER EXTRACTED FROM MESSAGE FILE ***
   Subject: CRITICAL: High CPU Utilization on node-04
   From: alert@prod.infra.net
   To: sysadmin@external-partner.com
   Date: Thu, 06 Aug 2026 09:30:44 -0400
   *** MESSAGE CONTENTS ***
   Node node-04 exceeded 95% CPU threshold for 15 consecutive minutes.
   *** MESSAGE FILE END ***
   ```
2. Para extraer *únicamente* los registros del envelope (sender, recipient, client IP) para scripts de auditoría automatizados:
   ```bash
   sudo postcat -q -e 4VxyDF56xYy
   ```

### Paso 3: Manipular el estado de la cola vía `postsuper`
1. Poner un elemento de la cola atascado o sospechoso en estado `hold` para detener los intentos de entrega:
   ```bash
   sudo postsuper -h 4VxyDF56xYy
   ```
   *Salida esperada:*
   ```text
   postsuper: 4VxyDF56xYy: placed on hold
   ```

2. Liberar un mensaje retenido (held) de vuelta a la cola `incoming` para su reevaluación:
   ```bash
   sudo postsuper -H 4VxyDF56xYy
   ```
   *Salida esperada:*
   ```text
   postsuper: 4VxyDF56xYy: released from hold
   ```

3. Forzar el encolamiento inmediato (re-parsing de encabezados y mapas de transporte):
   ```bash
   sudo postsuper -r 4VxyDF56xYy
   ```
   *Salida esperada:*
   ```text
   postsuper: 4VxyDF56xYy: requeued
   ```

4. Forzar un intento de purga de la cola (queue flush) para todos los mensajes diferidos (deferred):
   ```bash
   sudo postqueue -f
   ```

5. Eliminar un mensaje específico de la cola de forma permanente:
   ```bash
   sudo postsuper -d 4VxyDF56xYy
   ```
   *Salida esperada:*
   ```text
   postsuper: 4VxyDF56xYy: removed
   ```

6. *Production Guardrail:* Eliminar TODOS los mensajes diferidos (deferred) de forma segura utilizando `postsuper` y pipelines estándar de Unix:
   ```bash
   sudo postsuper -d ALL deferred
   ```

---

### Preguntas de verificación — Ejercicio 2

#### Pregunta 2.1
¿Cuál es la diferencia funcional entre `postqueue -f` (flush queue) y `postsuper -r ALL` (requeue all messages)? ¿Cuándo elegiría un SRE uno sobre el otro durante una interrupción del servicio (outage)?

#### Pregunta 2.2
Un e-mail enviado a `user@remote.org` permanece atascado en la cola `deferred` con el código de error `451 4.4.0 DNS query failed`. ¿Qué secuencia de comandos de diagnóstico deberías ejecutar para verificar si el problema proviene de la resolución DNS local, de una mala configuración del mapa de transporte o del filtrado de la red remota?

---

## Ejercicio 3: Entrega de correo local y remota (MDA, Dovecot, Sieve y Seguridad)

### Objetivo
Configurar Dovecot para una entrega segura en buzones de correo (IMAPS/LMTP), aplicar cuotas, mapear Dovecot SASL a Postfix y desplegar filtrado automatizado del lado del usuario utilizando scripts de Sieve.

### Paso 1: Configurar Dovecot LMTP y el motor de almacenamiento
1. Editá `/etc/dovecot/dovecot.conf` para habilitar los protocolos requeridos:
   ```ini
   # /etc/dovecot/dovecot.conf
   protocols = imap lmtp pop3
   listen = *, ::
   dict {
     # Dictionary bindings if using SQL quotas
   }
   !include conf.d/*.conf
   ```

2. Configurar el diseño de Maildir y las rutas de almacenamiento en `/etc/dovecot/conf.d/10-mail.conf`:
   ```ini
   mail_location = maildir:/var/vmail/%d/%n/Maildir
   mail_uid = 5000
   mail_gid = 5000
   first_valid_uid = 5000
   last_valid_uid = 5000
   ```

3. Configurar el intercambio de sockets de autenticación en `/etc/dovecot/conf.d/10-master.conf` para que Postfix pueda autenticar usuarios vía Dovecot SASL y enviar correo directamente vía LMTP:
   ```ini
   service lmtp {
     unix_listener /var/spool/postfix/private/dovecot-lmtp {
       mode = 0600
       user = postfix
       group = postfix
     }
   }

   service auth {
     unix_listener /var/spool/postfix/private/auth {
       mode = 0660
       user = postfix
       group = postfix
     }
   }
   ```

4. Aplicar una configuración estricta de TLS en `/etc/dovecot/conf.d/10-ssl.conf`:
   ```ini
   ssl = required
   ssl_cert = </etc/letsencrypt/live/mail.prod.infra.net/fullchain.pem
   ssl_key = </etc/letsencrypt/live/mail.prod.infra.net/privkey.pem
   ssl_min_protocol = TLSv1.2
   ssl_cipher_list = PROFILE=SYSTEM
   ```

### Paso 2: Implementar reglas de filtrado con Sieve
1. Asegurate de que el plugin Dovecot Pigeonhole Sieve esté activo en `/etc/dovecot/conf.d/20-lmtp.conf`:
   ```ini
   protocol lmtp {
     mail_plugins = $mail_plugins sieve
   }
   ```

2. Creá un filtro Sieve de usuario en `/var/vmail/example.com/alice/default.sieve`:
   ```sieve
   require ["fileinto", "mailbox", "subaddress"];

   # Rule 1: Redirect Automated Alerts
   if header :contains "Subject" ["CRITICAL", "ALERT", "FATAL"] {
     fileinto :create "INBOX.Alerts";
     stop;
   }

   # Rule 2: Move Marketing / Newsletters
   if header :contains "List-Unsubscribe" "http" {
     fileinto :create "INBOX.Newsletters";
     stop;
   }

   # Default Rule: Keep in Inbox
   keep;
   ```

3. Compilá el script de Sieve en formato bytecode binario (`.svbin`):
   ```bash
   sudo sievec /var/vmail/example.com/alice/default.sieve
   ```
4. Verificá el contenido del directorio para comprobar el bytecode generado:
   ```bash
   ls -la /var/vmail/example.com/alice/default.svbin
   ```
   *Salida esperada:*
   ```text
   -rw-r--r-- 1 vmail vmail 482 Aug  6 10:15 /var/vmail/example.com/alice/default.svbin
   ```

### Paso 3: Validar la autenticación de Dovecot y las operaciones de IMAP/LMTP
1. Recargá Dovecot:
   ```bash
   sudo systemctl restart dovecot
   ```

2. Validá la autenticación del usuario local a través de `doveadm`:
   ```bash
   sudo doveadm auth test alice@example.com SecretPassword123
   ```
   *Salida esperada:*
   ```text
   passdb: alice@example.com auth succeeded
   extra fields:
     user=alice@example.com
   ```

3. Probá la conexión IMAPS segura en el puerto TCP 993 usando `openssl s_client`:
   ```bash
   openssl s_client -connect mail.prod.infra.net:993 -crlf
   ```
   *Respuesta esperada del servidor:*
   ```text
   CONNECTED(00000003)
   depth=2 C = US, O = Internet Security Research Group, CN = ISRG Root X1
   ...
   * OK [CAPABILITY IMAP4rev1 SASL-IR LOGIN-REFERRALS ID ENABLE IDLE LITERAL+ AUTH=PLAIN] Dovecot ready.
   ```
4. Autenticate manualmente a través del estado de comandos IMAP:
   ```text
   A01 LOGIN alice@example.com SecretPassword123
   A02 LIST "" "*"
   A03 LOGOUT
   ```
   *Respuesta esperada del servidor:*
   ```text
   A01 OK [/CAPABILITY ...] Logged in
   * LIST (\HasNoChildren) "." INBOX
   * LIST (\HasNoChildren) "." INBOX.Alerts
   A02 OK List completed (0.001 secs).
   * BYE Logging out
   A03 OK Logout completed.
   ```

---

### Preguntas de verificación — Ejercicio 3

#### Pregunta 3.1
¿Por qué se prefiere LMTP (`lmtp:unix:private/dovecot-lmtp`) sobre los scripts locales pipe de MDA tradicionales (`pipe` o anexado directo de archivos) en sistemas de correo empresariales de alto rendimiento?

#### Pregunta 3.2
Si un usuario modifica su archivo `.sieve` directamente vía SSH sin compilarlo con `sievec`, ¿cómo reacciona Dovecot al recibir un mensaje vía LMTP? ¿Cómo es el manejo del estado de falla?

---

## Enlaces de referencia oficiales y documentación

- **LPIC-2 Exam Overview & Objectives**: [https://www.lpi.org/our-certifications/lpic-2-overview/](https://www.lpi.org/our-certifications/lpic-2-overview/)
- **Postfix Official Documentation & Architecture**: [http://www.postfix.org/documentation.html](http://www.postfix.org/documentation.html)
- **Postfix Queue Management Architecture**: [http://www.postfix.org/QSHAPE_README.html](http://www.postfix.org/QSHAPE_README.html)
- **Dovecot Core Administration Manual**: [https://doc.dovecot.org/](https://doc.dovecot.org/)
- **Pigeonhole Sieve Documentation**: [https://doc.dovecot.org/configuration_manual/sieve/](https://doc.dovecot.org/configuration_manual/sieve/)

---

<details>
<summary>Respuestas y explicaciones detalladas</summary>

### Soluciones del Ejercicio 1

#### Respuesta a la Pregunta 1.1
**Explicación:** Si se omite `reject_unauth_destination` de `smtpd_relay_restrictions` (o `smtpd_recipient_restrictions`), Postfix por defecto acepta todas las direcciones de destino. A menos que se implemente una lógica personalizada restrictiva en otra parte, el servidor se convierte en un **Open Relay**. Clientes externos maliciosos pueden conectarse al puerto 25 y enviar spam saliente a cualquier dominio de destino externo en todo el mundo. Esto da como resultado que la dirección IP del servidor sea incluida inmediatamente en listas negras por bases de datos RBL (ej. Spamhaus, Barracuda). Incluir `reject_unauth_destination` garantiza que Postfix rechace cualquier dominio de destino que NO esté definido en `$mydestination`, `$virtual_alias_domains` o `$virtual_mailbox_domains`, a menos que el cliente esté autenticado mediante bloques de red de confianza (`permit_mynetworks`) o SASL (`permit_sasl_authenticated`).

#### Respuesta a la Pregunta 1.2
**Explicación:** El daemon `cleanup` actúa como la capa de procesamiento intermedia entre los daemons de interfaz de entrada (`smtpd`, `pickup`) y la estructura de la cola. `cleanup` normaliza la estructura del envelope, inserta campos de encabezado estándar faltantes (`Message-Id`, `Date`), ejecuta la reescritura de direcciones (`canonical`, `masquerade_domains`) y evalúa las verificaciones de encabezado/cuerpo (`header_checks`). Una vez estructurado, `cleanup` escribe el mensaje en el directorio `incoming` y notifica a `qmgr`. 

Si `cleanup` se bloquea (crashea) durante la transmisión, el daemon `smtpd` recibe un error de terminación anormal de pipe, devuelve un código SMTP `421 4.3.0 Local server error` al MUA/MTA remitente y cierra la conexión del socket. El archivo parcial no confirmado en `/var/spool/postfix/incoming` se descarta o se mueve a `/var/spool/postfix/corrupt` durante las tareas de barrido de recuperación. `qmgr` nunca recibe la notificación de escrituras incompletas en la cola, evitando que mensajes parciales o corruptos entren en el flujo de entrega de correo.

---

### Soluciones del Ejercicio 2

#### Respuesta a la Pregunta 2.1
- **`postqueue -f` (Flush Queue):** Solicita a `qmgr` que programe inmediatamente los intentos de entrega para todos los mensajes que se encuentran actualmente en la cola `deferred`. **No** vuelve a procesar (re-parse) las configuraciones ni altera los archivos de mensajes; simplemente anula el cronograma del temporizador de backoff.
- **`postsuper -r ALL` (Requeue All):** Fuerza a los mensajes a salir de su estado de cola actual y los mueve de nuevo a la cola `incoming`. Cada envelope de mensaje es reevaluado completamente por el daemon `cleanup`. 

**Contexto operacional del SRE:** 
- Un SRE utiliza `postqueue -f` después de resolver una falla en la conexión de red (ej. se solucionó una regla de firewall en el upstream o finalizó una interrupción del ISP) para vaciar rápidamente el acumulado (backlog) sin alterar las estructuras del envelope.
- Un SRE utiliza `postsuper -r` cuando la lógica de configuración, los mapas de alias virtuales o las reglas de enrutamiento de transporte se actualizaron *después* de que los mensajes se atascaran. Un vaciado de cola por sí solo (`postqueue -f`) intentaría la entrega utilizando metadatos de rutas en caché; volver a encolar (`postsuper -r`) fuerza a Postfix a aplicar las reglas de enrutamiento y los mapas de tablas de búsqueda recientemente actualizados a todo el correo en cola.

#### Respuesta a la Pregunta 2.2
**Flujo de trabajo de comandos de diagnóstico:**
1. **Verificar la resolución DNS local:** Probar la resolución de registros MX y A directamente utilizando utilidades del sistema:
   ```bash
   dig +short MX remote.org
   dig +short A mail.remote.org
   ```
2. **Verificar el enrutamiento de la tabla de transporte:** Confirmar que las reglas de búsqueda de Postfix no estén forzando anulaciones de transporte (transport overrides) inválidas:
   ```bash
   postmap -q "remote.org" hash:/etc/postfix/transport
   ```
3. **Rastrear la conectividad a nivel de socket y la negociación TLS:** Probar la conectividad TCP saliente al puerto 25/587 del servidor MX de destino:
   ```bash
   nc -zv mail.remote.org 25
   openssl s_client -connect mail.remote.org:25 -starttls smtp
   ```
4. **Examinar los logs operacionales:** Hacer seguimiento (tail) de los logs del sistema durante un vaciado manual de la cola para el Queue ID específico:
   ```bash
   sudo postqueue -i <QUEUE_ID>
   sudo journalctl -u postfix -n 50 --no-pager
   ```

---

### Soluciones del Ejercicio 3

#### Respuesta a la Pregunta 3.1
**Explicación:** 
- **Pipe / Script MDAs:** La mecánica de entrega tradicional implica que los daemons `local` o `pipe` generen (fork/exec) un nuevo proceso (ej. `/usr/bin/procmail` o el binario LDA de Dovecot `/usr/libexec/dovecot/dovecot-lmtp`) por cada e-mail entrante. La sobrecarga de esta generación de procesos causa un alto consumo de CPU, sobrecarga de memoria (memory thrashing) y agotamiento de procesos bajo altos volúmenes de correo.
- **LMTP (Local Mail Transport Protocol):** LMTP se ejecuta como un servicio daemon de larga duración que escucha en un socket de dominio UNIX persistente o en un puerto TCP. Postfix mantiene conexiones de socket persistentes directamente con el grupo de trabajadores (worker pool) LMTP de Dovecot. Esto elimina la sobrecarga de creación de procesos, ofrece respuestas estructuradas de protocolo al estilo SMTP (2xx/4xx/5xx) directamente a Postfix, permite la reversión (rollback) instantánea de transacciones y maneja de forma segura entregas a múltiples destinatarios dentro de una sola sesión de transmisión.

#### Respuesta a la Pregunta 3.2
**Explicación:** Dovecot Pigeonhole verifica las marcas de tiempo (timestamps) de los archivos entre el archivo de origen `.sieve` y el archivo de bytecode compilado `.svbin`. 
1. Si `.sieve` se modifica manualmente y su timestamp es más reciente que el de `.svbin` (or si `.svbin` no existe), Dovecot recompila automáticamente el archivo `.sieve` sobre la marcha (on-the-fly) durante la transacción de entrega por LMTP.
2. Si el script `.sieve` contiene errores de sintaxis, la compilación automática falla. Dovecot registra el error de sintaxis exacto de la línea en `/var/log/dovecot.log` (o `journalctl`), recurre a ejecutar el script Sieve global de respaldo por defecto (si está definido en `sieve_default`) y entrega el mensaje directamente a la `INBOX` estándar del usuario sin descartar ni rebotar el correo.

</details>