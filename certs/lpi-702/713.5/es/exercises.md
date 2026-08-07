# LPI-702 (Examen 702-100) — Tema 713.5: Fundamentos de Mail Transfer Agents (MTA)

**Ponderación:** 1.67  
**Público objetivo:** SREs, arquitectos de sistemas e ingenieros de plataformas BSD  
**Referencia oficial:** [LPI BSD Specialist Overview](https://www.lpi.org/our-certifications/bsd-specialist-overview/)

---

## 1. Arquitectura técnica profunda y mecánica

### El subsistema BSD Mail Wrapper (`mailer.conf`)
Los sistemas operativos BSD separan la interfaz del Mail User Agent (MUA) orientada al usuario (comandos como `/usr/sbin/sendmail`, `/usr/bin/mailq` y `/usr/bin/newaliases`) del binario subyacente del Mail Transfer Agent (MTA) utilizando [`mailwrapper(8)`](https://man.freebsd.org/cgi/man.cgi?query=mailwrapper&sektion=8).

Cuando un proceso invoca `/usr/sbin/sendmail`, `mailwrapper(8)` intercepta la llamada y consulta [`/etc/mail/mailer.conf`](https://man.freebsd.org/cgi/man.cgi?query=mailer.conf&sektion=5) para determinar qué binario real ejecutar. Esta abstracción permite alternar sin problemas entre Sendmail, Postfix, OpenSMTPD o DragonFly Mail Agent (`dma`).

```
                +-------------------------------------------------+
                |   User / Script / Cron (invokes /usr/sbin/sendmail) |
                +-------------------------------------------------+
                                         |
                                         v
                                +------------------+
                                |  mailwrapper(8)  |
                                +------------------+
                                         |
                       Reads /etc/mail/mailer.conf
                                         |
         +-------------------------------+-------------------------------+
         |                               |                               |
         v                               v                               v
+-------------------+          +-------------------+          +-------------------+
|  Sendmail Binary  |          |  Postfix Binary   |          |  OpenSMTPD / dma  |
| /usr/libexec/     |          | /usr/local/sbin/  |          | /usr/libexec/dma  |
| sendmail/sendmail |          | sendmail          |          |                   |
+-------------------+          +-------------------+          +-------------------+
```

### Modelos de procesos de MTA y compromisos de seguridad

| Característica de arquitectura | Sendmail (Monolítico / Dual-MSP) | Postfix (Multiproceso de menor privilegio) | OpenSMTPD (Motor con separación de privilegios) |
| :--- | :--- | :--- | :--- |
| **Modelo de procesos** | Proceso monolítico (o Mail Submission Program `sendmail` separado + demonio `sendmail`). | Proceso maestro (`master(8)`) que gestiona demonios especializados e aislados (`smtpd`, `cleanup`, `qmgr`, `trivial-rewrite`, `smtp`, `local`). | Proceso de control principal que gestiona procesos hijo sin privilegios a través de tuberías IPC (`smtpd`, `lookup`, `queue`, `scheduler`). |
| **Separación de privilegios**| Requisito histórico de SUID root. El BSD moderno utiliza Mail Submission Program (MSP) con permisos de escritura de grupo `smap` en `/var/spool/clientmqueue`. | Ningún proceso individual lo hace todo. La mayoría de los demonios se ejecutan como un usuario sin privilegios (`postfix`) dentro de una jaula `chroot`. | Aplica una separación estricta de privilegios (usuarios `_smtpd` / `_smtpq`) inspirada en la arquitectura de OpenSSH. |
| **Configuración** | Procesador de macros `m4` que compila archivos `.mc` a `/etc/mail/sendmail.cf`. Alta complejidad. | Formato clave-valor (`main.cf`, `master.cf`). Declarativo y explícito. | Lenguaje específico de dominio (`smtpd.conf`). Sintaxis moderna enfocada en conjuntos de reglas legibles. |
| **Caso de uso principal** | Instalaciones heredadas de FreeBSD y enrutamiento corporativo complejo. | Infraestructura de producción empresarial con altos requisitos de rendimiento. | Entornos nativos de OpenBSD, MTAs Edge ligeros, enrutamiento seguro por defecto. |

---

## 2. Laboratorios guiados de producción

---

### Ejercicio 1: Configuración de BSD `mailwrapper` y cambio de MTAs mediante `mailer.conf`

#### Objetivo
Comprender cómo `mailwrapper(8)` evalúa `/etc/mail/mailer.conf` y reconfigurar el sistema para cambiar el MTA predeterminado del sistema de Sendmail/dma a Postfix sin romper los scripts del sistema que dependen de `/usr/sbin/sendmail`.

#### Pasos

1. Inspeccioná la configuración activa existente de `/etc/mail/mailer.conf` en tu nodo BSD.
   ```bash
   cat /etc/mail/mailer.conf
   ```
   *Salida esperada:*
   ```text
   # $FreeBSD$
   #
   # Execute the Sendmail daemon from /usr/libexec/sendmail
   #
   sendmail	/usr/libexec/sendmail/sendmail
   send-mail	/usr/libexec/sendmail/sendmail
   mailq		/usr/libexec/sendmail/sendmail
   newaliases	/usr/libexec/sendmail/sendmail
   hoststat	/usr/libexec/sendmail/sendmail
   purgestat	/usr/libexec/sendmail/sendmail
   ```

2. Verificá el destino del enlace simbólico del binario `/usr/sbin/sendmail` para comprobar la vinculación con `mailwrapper`.
   ```bash
   ls -la /usr/sbin/sendmail
   ```
   *Salida esperada:*
   ```text
   lrwxr-xr-x  1 root  wheel  21 Aug  6 10:00 /usr/sbin/sendmail -> /usr/sbin/mailwrapper
   ```

3. Creá un archivo `/etc/mail/mailer.conf` de reemplazo válido que mapee los binarios del sistema a Postfix instalado en `/usr/local/sbin/`.
   ```bash
   cat << 'EOF' > /etc/mail/mailer.conf
   # Replaced mailer.conf targeting Postfix binaries
   sendmail        /usr/local/sbin/sendmail
   send-mail       /usr/local/sbin/sendmail
   mailq           /usr/local/sbin/sendmail
   newaliases      /usr/local/sbin/sendmail
   hoststat        /usr/local/sbin/sendmail
   purgestat       /usr/local/sbin/sendmail
   EOF
   ```

4. Verificá que `/usr/bin/mailq` ahora se resuelva correctamente a la interfaz del administrador de colas de Postfix.
   ```bash
   mailq
   ```
   *Salida esperada (si el demonio de Postfix está detenido o vacío):*
   ```text
   Mail queue is empty
   ```

---

#### Preguntas de verificación — Ejercicio 1

1. **¿Qué sucede si un script personalizado ejecuta directamente `/usr/libexec/sendmail/sendmail` en lugar de `/usr/sbin/sendmail` después de que `/etc/mail/mailer.conf` haya sido apuntado a Postfix?**
2. **¿Por qué BSD utiliza enlaces duros o enlaces simbólicos de binarios apuntando a `/usr/sbin/mailwrapper` para `mailq` y `newaliases` en lugar de wrappers de shell independientes?**

---

### Ejercicio 2: Compilación de aliases, hashing de bases de datos y mapeos virtuales

#### Objetivo
Configurar `/etc/mail/aliases`, compilarlo en un formato de base de datos binaria indexada (`aliases.db`) y gestionar pipelines de resolución de aliases de MTA en entornos Sendmail y Postfix.

#### Pasos

1. Visualizá el archivo predeterminado `/etc/mail/aliases` y adjuntá un alias de notificación de seguridad que dirija el correo del sistema para `root`, `security` y `daemon` a una dirección SRE externa y a un archivo de registro local.
   ```bash
   cat << 'EOF' >> /etc/mail/aliases

   # System Administrator Aliases
   devops:          root
   security:        sysadmin@example.com
   audit-logger:    /var/log/mail_audit.log
   root:            sysadmin@example.com, audit-logger
   EOF
   ```

2. Compilá el archivo de texto `/etc/mail/aliases` en la base de datos BerkeleyDB/Hash utilizada por el motor de ejecución del MTA mediante `newaliases`.
   ```bash
   newaliases
   ```
   *Salida esperada:*
   ```text
   /etc/mail/aliases: 38 aliases, longest 31 bytes, 412 bytes total
   ```

3. Verificá que el archivo de base de datos generado exista e inspeccioná su marca de tiempo de modificación.
   ```bash
   ls -la /etc/mail/aliases.db
   ```
   *Salida esperada:*
   ```text
   -rw-r--r--  1 root  wheel  65536 Aug  6 20:45 /etc/mail/aliases.db
   ```

4. Para implementaciones de Postfix que utilicen tablas de búsqueda virtuales distintas, construí un archivo de mapa `/usr/local/etc/postfix/virtual` sintácticamente válido y compilalo utilizando `postmap`.
   ```bash
   cat << 'EOF' > /usr/local/etc/postfix/virtual
   # Postfix Virtual Alias Map
   platform.team@internal.domain    devops@localhost
   alerts@internal.domain           root@localhost
   EOF

   postmap hash:/usr/local/etc/postfix/virtual
   ls -la /usr/local/etc/postfix/virtual.db
   ```
   *Salida esperada:*
   ```text
   -rw-r--r--  1 root  wheel  16384 Aug  6 20:46 /usr/local/etc/postfix/virtual.db
   ```

---

#### Preguntas de verificación — Ejercicio 2

1. **Si un MTA entrega correo a un destino de alias formateado como `/var/log/mail_audit.log`, ¿qué permisos de archivo y propiedad deben existir en la ruta de destino, y qué riesgos de seguridad introduce la entrega a archivos?**
2. **¿Por qué se debe ejecutar explícitamente `newaliases` o `postmap` después de editar archivos de mapa de texto antes de que los cambios surtan efecto en producción?**

---

### Ejercicio 3: Gestión de colas, rastreo de directorios spool y retención de mensajes

#### Objetivo
Realizar operaciones administrativas de cola, incluyendo inspección de colas, vaciado forzado (flushing), congelación/retención de mensajes (holding) y eliminación selectiva de mensajes en diferentes topologías de cola de MTA (`/var/spool/mqueue`, `/var/spool/clientmqueue`, `/var/spool/postfix`).

#### Pasos

1. Inyectá un mensaje de prueba en la cola del MTA local utilizando la utilidad estándar POSIX `mail`.
   ```bash
   echo "Production Alert Test: Unreachable gateway node-04" | mail -s "TEST_QUEUE_EVENT" non-existent-user@invalid.local
   ```

2. Inspeccioná la cola actual utilizando la interfaz de comando unificada `mailq`.
   ```bash
   mailq
   ```
   *Salida esperada:*
   ```text
   -Queue ID- --Size-- ----Arrival Time---- ---------Sender/Recipient--------
   3F0A192B8*     342 Thu Aug  6 20:47:12  root@bsd-node01.internal
                                          non-existent-user@invalid.local
   -- 0 Kbytes in 1 Request.
   ```

3. Rastreá la estructura física del directorio spool de la cola en disco para entornos Sendmail / Postfix.
   *Para Sendmail:*
   ```bash
   ls -la /var/spool/mqueue/
   ls -la /var/spool/clientmqueue/
   ```
   *Para Postfix:*
   ```bash
   ls -la /var/spool/postfix/deferred/
   ls -la /var/spool/postfix/active/
   ```

4. Realizá intervenciones administrativas específicas del MTA en el mensaje en cola (utilizando herramientas de Postfix como referencia empresarial):
   
   a. Retené un mensaje en cola para evitar su eliminación o intentos de reintento durante la investigación de un incidente:
   ```bash
   postsuper -h 3F0A192B8
   ```
   *Salida esperada:*
   ```text
   postsuper: 3F0A192B8: placed on hold
   ```

   b. Liberá el mensaje retenido de vuelta a la cola activa:
   ```bash
   postsuper -r 3F0A192B8
   ```
   *Salida esperada:*
   ```text
   postsuper: 3F0A192B8: requeued
   ```

   c. Forzá un intento de vaciado (flush) inmediato de la cola para todos los mensajes diferidos pendientes:
   ```bash
   postfix flush   # Or postqueue -f
   ```

   d. Eliminá el mensaje de prueba del spool:
   ```bash
   postsuper -d 3F0A192B8
   ```
   *Salida esperada:*
   ```text
   postsuper: 3F0A192B8: removed
   ```

---

#### Preguntas de verificación — Ejercicio 3

1. **En la arquitectura de Sendmail, ¿cuál es la distinción operativa específica entre `/var/spool/mqueue` y `/var/spool/clientmqueue`?**
2. **¿Cuál es la diferencia entre `postqueue -f` (flush queue) y `postfix reload` en un clúster de producción de Postfix de alto volumen?**

---

### Ejercicio 4: Diagnósticos avanzados del protocolo SMTP y análisis de registros en vivo

#### Objetivo
Ejecutar manualmente una sesión SMTP sin formato (raw) completa sobre TLS utilizando utilidades de red de bajo nivel (`nc`, `openssl s_client`), interpretar los códigos de respuesta de RFC 5321 y rastrear el estado de la transacción a través de `/var/log/maillog`.

#### Pasos

1. Abrí una ventana de terminal secundaria y monitoreá el registro de correo del sistema BSD en tiempo real usando `tail`.
   ```bash
   tail -f /var/log/maillog
   ```

2. Ejecutá una sesión SMTP interactiva sin formato mediante TCP contra el puerto local 25 o el puerto de envío remoto 587 usando `openssl s_client` (para admitir la negociación STARTTLS).
   ```bash
   openssl s_client -connect 127.0.0.1:25 -starttls smtp -crlf
   ```
   *Banner del servidor esperado:*
   ```text
   CONNECTED(00000003)
   ---
   220 bsd-node01.internal ESMTP Postfix
   ```

3. Enviá comandos sin formato del protocolo SMTP RFC 5321 secuencialmente en la sesión interactiva:
   ```smtp
   EHLO DiagnosticClient.internal
   MAIL FROM:<sre-audit@domain.com>
   RCPT TO:<root@localhost>
   DATA
   Subject: Raw Protocol Diagnostic Verification

   This mail body was generated manually via OpenSSL interactive session.
   .
   QUIT
   ```

   *Diálogo de respuesta del servidor esperado:*
   ```text
   250-bsd-node01.internal Hello DiagnosticClient.internal [127.0.0.1]
   250-SIZE 10240000
   250-ENHANCEDSTATUSCODES
   250 8BITMIME
   250 2.1.0 Ok
   250 2.1.5 Ok
   354 End data with <CR><LF>.<CR><LF>
   250 2.0.0 Ok: queued as 8A29F4C102
   221 2.0.0 Bye
   ```

4. Verificá la entrada exacta del registro emitida en `/var/log/maillog` durante la transacción sin formato.
   ```bash
   grep "8A29F4C102" /var/log/maillog
   ```
   *Salida esperada:*
   ```text
   Aug  6 20:50:15 bsd-node01 postfix/smtpd[88219]: connect from localhost[127.0.0.1]
   Aug  6 20:50:42 bsd-node01 postfix/smtpd[88219]: 8A29F4C102: client=localhost[127.0.0.1]
   Aug  6 20:50:55 bsd-node01 postfix/cleanup[88224]: 8A29F4C102: message-id=<20260806205042.8A29F4C102@bsd-node01.internal>
   Aug  6 20:50:55 bsd-node01 postfix/qmgr[88100]: 8A29F4C102: from=<sre-audit@domain.com>, size=412, nrcpt=1 (queue active)
   Aug  6 20:50:55 bsd-node01 postfix/local[88225]: 8A29F4C102: to=<sysadmin@example.com>, orig_to=<root@localhost>, relay=local, delay=15, delays=15/0.01/0/0.02, dsn=2.0.0, status=sent (delivered to mailbox)
   Aug  6 20:50:55 bsd-node01 postfix/qmgr[88100]: 8A29F4C102: removed
   ```

---

#### Preguntas de verificación — Ejercicio 4

1. **En la salida del registro RFC 5321 anterior, ¿cuál es el significado de `dsn=2.0.0` y qué indicarían `dsn=4.X.X` frente a `dsn=5.X.X` durante un fallo de entrega?**
2. **¿Por qué se debe transmitir el punto único (`.`) en su propia línea durante la fase `DATA` de una sesión SMTP?**

---

## 3. Soluciones exhaustivas y explicaciones conceptuales

<details>
<summary>Hacé clic para desplegar la clave de respuestas y explicaciones detalladas</summary>

### Soluciones del Ejercicio 1

1. **Bypass por ejecución directa del binario:**
   Si un script llama explícitamente a `/usr/libexec/sendmail/sendmail`, invoca directamente el binario de Sendmail en disco, omitiendo `mailwrapper(8)` e ignorando `/etc/mail/mailer.conf`. `mailwrapper(8)` solo se activa cuando los programas invocan los wrappers estándar ubicados en `/usr/sbin/` (como `/usr/sbin/sendmail` o `/usr/bin/mailq`). En entornos empresariales, las rutas codificadas de forma rígida (hardcoded) a `/usr/libexec/sendmail/sendmail` pueden provocar conflictos de MTA dual (por ejemplo, Sendmail intentando encolar mensajes mientras Postfix está ejecutándose).

2. **Diseño de wrapper binario frente a wrappers de shell:**
   BSD utiliza enlaces duros o simbólicos de binarios apuntando a `/usr/sbin/mailwrapper` para que el contexto ejecutable se establezca de forma instantánea a nivel de tiempo de ejecución de C sin generar subprocesos de shell (`/bin/sh`). Los wrappers de shell agregan sobrecarga por bifurcación (fork) de procesos, posibles errores de análisis sintáctico (parsing) y riesgos de seguridad (como la manipulación de variables de entorno como `IFS` o `PATH`). `mailwrapper` lee `argv[0]` (el nombre de la invocación, como `mailq` o `newaliases`) para buscar el mapeo ejecutable exacto definido en `/etc/mail/mailer.conf`.

---

### Soluciones del Ejercicio 2

1. **Seguridad y permisos de alias a archivos:**
   Cuando un MTA entrega directamente a una ruta de archivo absoluta (`/var/log/mail_audit.log`), el proceso MTA debe abandonar los privilegios de root y ejecutar la entrega local bajo la cuenta de usuario de correo sin privilegios o los permisos del demonio. Si el archivo de destino no existe, el MTA puede crearlo; si existe, el MTA añade contenido al final (append).
   *Riesgos de seguridad:* Si el directorio de registro de destino es de escritura para usuarios sin privilegios, un atacante podría utilizar ataques de enlaces simbólicos (symlinks) o enlaces duros para forzar al MTA a sobrescribir archivos del sistema (`/etc/passwd`, `/etc/master.passwd`). Los MTAs modernos como Postfix validan la propiedad de los directorios (`safe_unlink` / permisos de archivo estrictos) y se niegan a entregar en rutas no seguras.

2. **Requisito de compilación (`newaliases` / `postmap`):**
   Los MTAs manejan altos volúmenes de correo y no pueden darse el lujo de leer y analizar archivos de texto lineales (`/etc/mail/aliases`) línea por línea durante las negociaciones de conexión activas o los bucles de entrega. Compilar archivos de texto en estructuras binarias indexadas (Indexed DB / Hash / BTree) permite un rendimiento de búsqueda en tiempo constante $O(1)$. La ejecución de `newaliases` o `postmap` actualiza el almacén clave-valor `.db` binario; sin la ejecución, el MTA continúa consultando la imagen `.db` precompilada anterior en memoria.

---

### Soluciones del Ejercicio 3

1. **`/var/spool/mqueue` frente a `/var/spool/clientmqueue`:**
   * `/var/spool/clientmqueue`: Utilizado por la porción sin privilegios del Mail Submission Program (MSP) de Sendmail. Cuando los usuarios locales o trabajos de cron ejecutan `/usr/sbin/sendmail`, el binario se ejecuta con set-group-ID `smap` y escribe mensajes en `/var/spool/clientmqueue`.
   * `/var/spool/mqueue`: El spool de salida principal con privilegios gestionado exclusivamente por el demonio MTA Sendmail propiedad de root. El demonio Sendmail barre periódicamente `/var/spool/clientmqueue`, transfiere mensajes a `/var/spool/mqueue` y gestiona la entrega por red a través del puerto 25.

2. **`postqueue -f` frente a `postfix reload`:**
   * `postqueue -f` (o `postfix flush`): Activa el gestor de colas de Postfix (`qmgr(8)`) para procesar inmediatamente todos los mensajes alojados en la cola `deferred`, forzando intentos instantáneos de reentrega independientemente de los temporizadores de espera (back-off) previos.
   * `postfix reload`: Vuelve a leer los archivos de configuración (`main.cf`, `master.cf`) en memoria sin interrumpir las conexiones TCP activas ni detener los demonios. No fuerza intentos de reintento en mensajes diferidos.

---

### Soluciones del Ejercicio 4

1. **Mecánica de los códigos DSN (Delivery Status Notification):**
   Los códigos de estado mejorados (Enhanced Status Codes: RFC 3463 / RFC 5248) definen la disposición exacta de una sesión SMTP:
   * `2.X.X` (por ejemplo, `2.0.0`): **Éxito.** Mensaje aceptado y entregado con éxito o encolado para transferencia.
   * `4.X.X` (Finalización negativa transitoria): **Fallo temporal.** El cliente debe conservar el mensaje en su spool local y reintentar más tarde (por ejemplo, `4.5.1 Mailbox full`, `4.7.1 Rate limit exceeded`).
   * `5.X.X` (Finalización negativa permanente): **Fallo definitivo / Rebote (Bounce).** La entrega no se puede completar y los reintentos no tendrán éxito (por ejemplo, `5.1.1 User unknown`, `5.7.1 Access denied / SPF fail`). El MTA descarta el mensaje o genera un informe de no entrega (NDR).

2. **El punto terminal (`.`) en `DATA`:**
   SMTP es un protocolo de flujo de texto ASCII. La secuencia de bytes `<CR><LF>.<CR><LF>` (un punto único en una línea por sí solo) actúa como el marcador de fin de datos que señala el final de la carga útil (payload) del mensaje RFC 5322. Le indica al servidor SMTP que salga del modo de entrada y vuelva al modo de comando del protocolo y calcule la respuesta de aceptación final (`250 Ok`). Si una línea del cuerpo del mensaje comienza de forma natural con un punto, el MTA emisor utiliza "dot-stuffing" (anteponer un punto adicional) para evitar la terminación prematura.

</details>