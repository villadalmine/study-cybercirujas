# LPIC-1 — Tema 108.3: Fundamentos del Mail Transfer Agent (MTA)
## Ejercicios guiados (Examen 102-500, versión 5.0)

**Referencia oficial del objetivo:** <https://www.lpi.org/our-certifications/exam-102-objectives/> (el tema 108.3 pertenece al examen 102-500; la lista de objetivos del 101-500 está en <https://www.lpi.org/our-certifications/exam-101-objectives/>).

La propia nota de alcance del objetivo dice *"no configuration of MTAs is required"* — lo que se evalúa son los **aliases**, el **reenvío**, la **capa de comandos compatible con sendmail** y el **conocimiento de los cuatro MTA clásicos**. Estos ejercicios cubren ese núcleo examinable y después avanzan hacia los diagnósticos de producción que un SRE realmente necesita: anatomía de la cola, motivos de diferimiento, detección de bucles y evidencia del agente de entrega en los logs.

---

## Entorno de laboratorio

> **Aviso de seguridad.** Un MTA escuchando en una interfaz pública sin restricciones de destinatario es un **open relay** y será abusado en cuestión de horas. Todos los ejercicios de abajo atan Postfix únicamente a loopback (`inet_interfaces = loopback-only`). No cambies eso en el laboratorio, y no expongas el TCP/25 de tu estación de trabajo.

Usá una VM o un contenedor descartable (se asume Debian 12 / Ubuntu 24.04; las diferencias de RHEL/Fedora se señalan en línea). Necesitás `root`.

```bash
# Debian/Ubuntu
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y postfix mailutils

# RHEL/Rocky/Fedora
sudo dnf install -y postfix s-nail
sudo systemctl enable --now postfix
```

En Debian el instalador ejecuta `debconf`. Si aparece el diálogo interactivo, elegí **"Local only"** y aceptá el nombre de correo del sistema por defecto. Para forzarlo de forma no interactiva:

```bash
sudo debconf-set-selections <<'EOF'
postfix postfix/main_mailer_type select Local only
postfix postfix/mailname string mail.lab.example
EOF
```

Creá dos usuarios sin privilegios que se usan a lo largo de todo el laboratorio:

```bash
sudo useradd -m -s /bin/bash alice
sudo useradd -m -s /bin/bash bob
```

---

## Ejercicio 1 — Identificar el MTA instalado y la capa de compatibilidad con sendmail

**Por qué importa.** En un incidente heredás un host, no una decisión. Antes de tocar nada tenés que responder: *¿cuál* MTA está corriendo, y *¿`/usr/sbin/sendmail` es realmente Sendmail?* En prácticamente todo sistema Linux moderno no lo es — es un binario de compatibilidad que provee Postfix o Exim y que implementa la interfaz de línea de comandos de Sendmail. Los scripts, cron, la función `mail()` de PHP y los agentes de monitoreo llaman a esa ruta.

1. Averiguá qué paquetes de MTA están instalados.

   ```bash
   # Debian/Ubuntu
   dpkg -l | grep -E 'postfix|exim|sendmail|qmail'
   # RHEL family
   rpm -qa | grep -E 'postfix|exim|sendmail|qmail'
   ```

   Salida esperada (Debian, con Postfix instalado):

   ```
   ii  postfix   3.7.11-0+deb12u1  amd64  High-performance mail transport agent
   ```

2. Resolvé a qué apunta realmente `/usr/sbin/sendmail`.

   ```bash
   ls -l /usr/sbin/sendmail /usr/bin/mailq /usr/bin/newaliases
   readlink -f /usr/sbin/sendmail
   ```

   Resultado típico en Debian — los tres nombres son un solo binario:

   ```
   lrwxrwxrwx 1 root root 26 Aug 20 10:11 /usr/sbin/sendmail -> ../sbin/postfix-sendmail
   lrwxrwxrwx 1 root root 21 Aug 20 10:11 /usr/bin/mailq -> ../sbin/sendmail
   lrwxrwxrwx 1 root root 21 Aug 20 10:11 /usr/bin/newaliases -> ../sbin/sendmail
   ```

   En RHEL el mismo trabajo lo hace el sistema `alternatives` bajo la familia `mta`:

   ```bash
   alternatives --display mta
   ```

   ```
   mta - status is auto.
    link currently points to /usr/sbin/sendmail.postfix
   /usr/sbin/sendmail.postfix - priority 30
   ```

3. Preguntale al propio binario qué implementación es.

   ```bash
   /usr/sbin/sendmail -bv root 2>&1 | head -n 3   # generic: validate an address
   postconf mail_version                          # Postfix-specific
   ```

   ```
   mail_version = 3.7.11
   ```

4. Confirmá qué está escuchando realmente, y en qué interfaz.

   ```bash
   sudo ss -lntp '( sport = :25 )'
   postconf -n inet_interfaces mydestination myorigin
   ```

   ```
   State  Recv-Q Send-Q Local Address:Port Peer Address:Port Process
   LISTEN 0      100        127.0.0.1:25        0.0.0.0:*     users:(("master",pid=812,fd=13))

   inet_interfaces = loopback-only
   mydestination = $myhostname, mail.lab.example, localhost.localdomain, localhost
   ```

5. Inspeccioná el árbol de procesos en ejecución — Postfix es un conjunto de demonios que cooperan bajo un supervisor.

   ```bash
   ps -eo pid,ppid,user,comm | grep -E 'master|qmgr|pickup'
   ```

   ```
    812     1 root     master
    815   812 postfix  qmgr
    819   812 postfix  pickup
   ```

**Preguntas de control**

- **Q1.1** — ¿Por qué `mailq` y `newaliases` existen como enlaces simbólicos al binario compatible con Sendmail y no como programas independientes?
- **Q1.2** — Un script de backup heredado llama a `/usr/sbin/sendmail -t`. Postfix está instalado, Sendmail no. ¿Funciona el script? Explicá qué hace `-t`.
- **Q1.3** — `postconf -n` imprime muchos menos parámetros que `postconf -d`. ¿Cuál es la diferencia, y por qué `postconf -n` es lo correcto para pegar en un ticket?
- **Q1.4** — `mydestination` y `myorigin` están ambos definidos. ¿Cuál decide *"este correo es para mí, entregalo localmente"* y cuál decide *"este es el dominio que estampo en el correo local saliente"*?
- **Q1.5** — Dos paquetes de MTA en Debian quieren ambos ser dueños de `/usr/sbin/sendmail`. ¿Qué mecanismo de empaquetado impide que se instalen al mismo tiempo?

---

## Ejercicio 2 — Enviar un mensaje y leer la evidencia de entrega en el log

**Por qué importa.** "El correo no se entregó" nunca es un diagnóstico. El log te dice el **queue ID**, el **agente de entrega** (`relay=local`, `relay=smtp`), el **código DSN** y el **verbo de estado** (`sent`, `deferred`, `bounced`). Aprendé a leer una transacción completa de punta a punta.

1. Abrí un seguidor del log de correo en una segunda terminal.

   ```bash
   # Debian/Ubuntu
   sudo tail -F /var/log/mail.log
   # RHEL family
   sudo tail -F /var/log/maillog
   # systemd-only hosts (no rsyslog)
   sudo journalctl -u postfix@- -f
   ```

2. Enviá un mensaje de `root` a `alice`.

   ```bash
   echo "First lab message body." | mail -s "Lab 108.3 test" alice
   ```

3. Leé las cinco líneas de log que produjo la transacción.

   ```
   Aug 26 09:20:11 mail postfix/pickup[819]:  A1B2C3D4E5: uid=0 from=<root>
   Aug 26 09:20:11 mail postfix/cleanup[830]: A1B2C3D4E5: message-id=<20260826092011.A1B2C3D4E5@mail.lab.example>
   Aug 26 09:20:11 mail postfix/qmgr[815]:    A1B2C3D4E5: from=<root@mail.lab.example>, size=438, nrcpt=1 (queue active)
   Aug 26 09:20:11 mail postfix/local[832]:   A1B2C3D4E5: to=<alice@mail.lab.example>, relay=local, delay=0.05, delays=0.03/0.01/0/0.01, dsn=2.0.0, status=sent (delivered to mailbox)
   Aug 26 09:20:11 mail postfix/qmgr[815]:    A1B2C3D4E5: removed
   ```

4. Confirmá el buzón en disco y su formato.

   ```bash
   ls -l /var/mail/alice
   sudo head -n 1 /var/mail/alice
   postconf -n mail_spool_directory home_mailbox
   ```

   ```
   -rw-rw---- 1 alice mail 526 Aug 26 09:20 /var/mail/alice
   From root@mail.lab.example  Wed Aug 26 09:20:11 2026
   ```

   Una salida vacía de `postconf -n home_mailbox` significa que el parámetro está en su valor por defecto (sin definir) y que la entrega es **mbox** dentro de `$mail_spool_directory`.

5. Leé el correo como el usuario.

   ```bash
   sudo -u alice mail
   ```

   ```
   "/var/mail/alice": 1 message 1 new
   >N   1 root               Wed Aug 26 09:20  14/526   Lab 108.3 test
   ? 1
   ? q
   ```

6. Conducí a mano una transacción SMTP contra el listener local — esta es la técnica de diagnóstico de MTA más útil que existe, porque separa *"el MTA lo rechaza"* de *"el cliente está roto"*.

   ```bash
   nc 127.0.0.1 25
   ```

   ```
   220 mail.lab.example ESMTP Postfix (Debian/GNU)
   EHLO test.local
   250-mail.lab.example
   250-PIPELINING
   250-SIZE 10240000
   250-ENHANCEDSTATUSCODES
   250-8BITMIME
   250 SMTPUTF8
   MAIL FROM:<root@mail.lab.example>
   250 2.1.0 Ok
   RCPT TO:<bob@mail.lab.example>
   250 2.1.5 Ok
   DATA
   354 End data with <CR><LF>.<CR><LF>
   Subject: Hand-typed SMTP

   Envelope and header recipients differ on purpose.
   .
   250 2.0.0 Ok: queued as F1E2D3C4B5
   QUIT
   221 2.0.0 Bye
   ```

**Preguntas de control**

- **Q2.1** — En la línea de log de `local`, ¿qué significan `dsn=2.0.0` y `status=sent`, y cómo se vería la misma línea si el destinatario no existiera?
- **Q2.2** — El mensaje que tipeaste a mano en el paso 6 **no tiene cabecera `To:`** y sin embargo se entregó a `bob`. ¿A qué destinatario obedeció Postfix — al del sobre o al de la cabecera — y por qué esa distinción importa para los aliases y las listas de correo?
- **Q2.3** — ¿Qué proceso entregó a la cola el mensaje enviado localmente en el paso 3, y cuál realizó la entrega final? Nombrá ambos y decí qué te informa `relay=local`.
- **Q2.4** — ¿Qué distingue en disco la entrega **mbox** de la **Maildir**, y qué parámetro de Postfix cambia un host a Maildir? ¿Por qué el valor necesita un carácter final?
- **Q2.5** — El campo `delays=0.03/0.01/0/0.01` tiene cuatro números. ¿Cuál es el valor operativo de que el último sea grande mientras los tres primeros están cerca de cero?

---

## Ejercicio 3 — Aliases de todo el sistema: `/etc/aliases` y `newaliases`

**Por qué importa.** `/etc/aliases` es la tabla de redirección controlada por el administrador para los destinatarios **locales**. Su rol más importante en producción es hacer que el correo de `root` — fallas de cron, degradación de RAID, `logwatch`, `smartd` — aterrice en la bandeja de una persona en lugar de pudrirse en `/var/mail/root`.

1. Inspeccioná la tabla de aliases actual y localizala de forma autoritativa.

   ```bash
   postconf alias_maps alias_database
   sudo grep -vE '^\s*#|^\s*$' /etc/aliases
   ```

   ```
   alias_maps = hash:/etc/aliases
   alias_database = hash:/etc/aliases

   mailer-daemon: postmaster
   postmaster: root
   nobody: root
   hostmaster: root
   webmaster: root
   abuse: root
   ```

2. Agregá entradas de alias que cubran los cuatro tipos de destino que soporta el formato.

   ```bash
   sudo tee -a /etc/aliases >/dev/null <<'EOF'

   # --- lab 108.3 ---
   root:        alice
   sre-oncall:  alice, bob
   archive:     /var/mail/archive-drop
   tickets:     |/usr/local/bin/ticket-intake
   platform:    :include:/etc/mail/platform-team
   EOF

   sudo install -d -m 0755 /etc/mail
   printf 'alice\nbob\n' | sudo tee /etc/mail/platform-team >/dev/null
   ```

3. Intentá usar el alias nuevo **antes** de reconstruir la base de datos, y observá que nada cambia.

   ```bash
   echo "before newaliases" | mail -s "stale db" sre-oncall
   ```

   ```
   postfix/local[861]: C4D5E6F7A8: to=<sre-oncall@mail.lab.example>, relay=local, delay=0.04,
     dsn=5.1.1, status=bounced (unknown user: "sre-oncall")
   ```

4. Reconstruí la base de datos indexada y compará las marcas de tiempo.

   ```bash
   ls -l /etc/aliases /etc/aliases.db
   sudo newaliases
   ls -l /etc/aliases /etc/aliases.db
   ```

   ```
   -rw-r--r-- 1 root root   765 Aug 26 09:41 /etc/aliases
   -rw-r--r-- 1 root root 12288 Aug 20 10:11 /etc/aliases.db      <-- older than the source
   ...
   -rw-r--r-- 1 root root 12288 Aug 26 09:42 /etc/aliases.db      <-- rebuilt
   ```

5. Verificá que la entrada esté genuinamente en el mapa compilado, y no solo en el archivo de texto.

   ```bash
   postmap -q sre-oncall hash:/etc/aliases
   postmap -q nosuchalias hash:/etc/aliases; echo "exit=$?"
   ```

   ```
   alice, bob
   exit=1
   ```

6. Enviá de nuevo y observá el fan-out hacia dos destinatarios.

   ```bash
   echo "paging the on-call rotation" | mail -s "after newaliases" sre-oncall
   ```

   ```
   postfix/qmgr[815]:  D5E6F7A8B9: from=<root@mail.lab.example>, size=445, nrcpt=2 (queue active)
   postfix/local[874]: D5E6F7A8B9: to=<alice@mail.lab.example>, orig_to=<sre-oncall@mail.lab.example>,
     relay=local, delay=0.06, dsn=2.0.0, status=sent (delivered to mailbox)
   postfix/local[875]: D5E6F7A8B9: to=<bob@mail.lab.example>, orig_to=<sre-oncall@mail.lab.example>,
     relay=local, delay=0.07, dsn=2.0.0, status=sent (delivered to mailbox)
   ```

7. Comprobá que el correo de `root` ahora llega a `alice`.

   ```bash
   echo "simulated cron failure" | mail -s "cron output" root
   sudo grep -E 'orig_to=<root@' /var/log/mail.log | tail -n 1
   ```

8. Dos formas equivalentes de reconstruir — conocé ambas.

   ```bash
   sudo newaliases                 # sendmail-compatible name
   sudo /usr/sbin/sendmail -bi     # the exact same operation, classic flag
   sudo postalias /etc/aliases     # Postfix-native equivalent
   ```

**Preguntas de control**

- **Q3.1** — ¿Por qué editar `/etc/aliases` no alcanza, y qué produce exactamente `newaliases`? Dá los dos comandos distintos de `newaliases` que hacen el mismo trabajo.
- **Q3.2** — ¿Cuál es la diferencia entre `alias_maps` y `alias_database`? ¿Sobre cuál actúa `newaliases`, y qué se rompe si un administrador define solo uno de los dos?
- **Q3.3** — El alias `tickets: |/usr/local/bin/ticket-intake` canaliza el correo hacia un programa. ¿Bajo qué UID corre ese programa por defecto, y por qué esta entrada es sensible desde el punto de vista de seguridad? Nombrá una alternativa más segura.
- **Q3.4** — Explicá el tipo de destino `:include:` y por qué es preferible a una larga lista separada por comas para una dirección de distribución de equipo.
- **Q3.5** — En el paso 6 el log muestra `orig_to=`. ¿Qué prueba ese campo, y cómo te ayuda a distinguir una expansión de `/etc/aliases` de un envío simplemente mal dirigido?
- **Q3.6** — Un administrador escribe `root: root@backup.example.net` en `/etc/aliases`. ¿Es obligatorio que el destino de un alias sea un usuario local? ¿Qué dependencia adicional introduce esto en un host "local only"?

---

## Ejercicio 4 — Reenvío controlado por el usuario: `~/.forward`

**Por qué importa.** `/etc/aliases` necesita root. `~/.forward` le permite a un usuario sin privilegios redirigir su propio correo — y sus **requisitos de permisos son la razón número uno de que no haga nada en silencio**. Tanto Postfix como Exim se niegan a honrar un `.forward` que sea escribible por el grupo o por todos, o que viva en un directorio home en el que cualquier otro pueda escribir. Fallan de forma *segura*, lo que significa *silenciosa*.

1. Creá un reenvío para `bob` que apunte a `alice`.

   ```bash
   sudo -u bob bash -c 'echo "alice@mail.lab.example" > ~/.forward'
   sudo -u bob ls -l ~bob/.forward
   ```

   ```
   -rw-r--r-- 1 bob bob 25 Aug 26 10:02 /home/bob/.forward
   ```

2. Enviá a `bob` y confirmá la redirección.

   ```bash
   echo "should land in alice's mailbox" | mail -s "forward test" bob
   ```

   ```
   postfix/local[901]: E6F7A8B9C0: to=<alice@mail.lab.example>, orig_to=<bob@mail.lab.example>,
     relay=local, delay=0.05, dsn=2.0.0, status=sent (delivered to mailbox)
   ```

3. Conservá una **copia local mientras reenviás** — la forma con barra invertida suprime el procesamiento posterior de `.forward` para esa entrada.

   ```bash
   sudo -u bob bash -c 'printf "\\\\bob\nalice@mail.lab.example\n" > ~/.forward'
   sudo -u bob cat ~bob/.forward
   ```

   ```
   \bob
   alice@mail.lab.example
   ```

   ```bash
   echo "copy plus forward" | mail -s "dual delivery" bob
   ```

   ```
   postfix/local[912]: F7A8B9C0D1: to=<bob@mail.lab.example>, relay=local, dsn=2.0.0, status=sent (delivered to mailbox)
   postfix/local[913]: F7A8B9C0D1: to=<alice@mail.lab.example>, orig_to=<bob@mail.lab.example>, relay=local, dsn=2.0.0, status=sent (delivered to mailbox)
   ```

4. **Rompelo a propósito** — hacé el archivo escribible por todos y observá el modo de falla.

   ```bash
   sudo chmod 666 ~bob/.forward
   echo "insecure forward" | mail -s "perm test" bob
   ```

   ```
   postfix/local[925]: warning: not owner or unsafe permissions on /home/bob/.forward
   postfix/local[925]: A8B9C0D1E2: to=<bob@mail.lab.example>, relay=local, delay=0.06,
     dsn=2.0.0, status=sent (delivered to mailbox)
   ```

   Fijate bien: el mensaje fue **entregado localmente, no reenviado**, y el estado sigue siendo `sent`. No hay rebote. Restaurá:

   ```bash
   sudo chmod 644 ~bob/.forward
   ```

5. Ahora construí un **bucle de correo** y mirá cómo el MTA se defiende.

   ```bash
   sudo -u alice bash -c 'echo "bob@mail.lab.example" > ~/.forward'
   sudo -u bob   bash -c 'echo "alice@mail.lab.example" > ~/.forward'
   echo "loop probe" | mail -s "loop" alice
   ```

   ```
   postfix/local[940]: B9C0D1E2F3: to=<bob@mail.lab.example>, orig_to=<alice@mail.lab.example>,
     relay=local, delay=0.09, dsn=5.4.6, status=bounced (mail forwarding loop for bob@mail.lab.example)
   ```

6. Limpiá antes del siguiente ejercicio.

   ```bash
   sudo rm -f ~alice/.forward ~bob/.forward
   ```

7. Como contraste, anotá el mecanismo equivalente en los otros MTA:

   | MTA | Archivo de reenvío por usuario | Notas |
   |---|---|---|
   | Postfix | `~/.forward` | Sintaxis compatible con Sendmail; controlado por `forward_path` |
   | Sendmail | `~/.forward` | La implementación original |
   | Exim | `~/.forward` | Modo opcional de filtro estilo Sieve en el mismo archivo |
   | qmail | `~/.qmail` | Sintaxis completamente distinta; es un archivo dot-qmail, no un `.forward` |

**Preguntas de control**

- **Q4.1** — Enumerá las tres condiciones de propiedad/permisos que deben cumplirse para que `~/.forward` sea honrado, y decí con precisión qué le pasa a un mensaje cuando no se cumplen.
- **Q4.2** — ¿Qué significa una barra invertida inicial (`\bob`) dentro de `~/.forward`, y por qué *no* es lo mismo que escribir `bob`?
- **Q4.3** — Compará `/etc/aliases` y `~/.forward` en cuatro ejes: quién puede editarlo, si hace falta un paso de reconstrucción, a quién le afecta el correo, y dónde se almacena.
- **Q4.4** — La falla del paso 4 no produjo **ningún rebote ni error al remitente**. Explicá por qué negarse a reenviar — en lugar de rebotar — es la decisión de seguridad correcta.
- **Q4.5** — `dsn=5.4.6` en el paso 5: ¿qué clase de error es un código 5.x.x, y qué habría implicado 4.x.x en su lugar?
- **Q4.6** — Un usuario en un host qmail copia su `~/.forward` que funciona desde un host Postfix. ¿Qué pasa, y qué debería haber creado en su lugar?

---

## Ejercicio 5 — Anatomía, inspección y diferimiento de la cola

**Por qué importa.** La cola es donde va el correo cuando no puede entregarse *en este momento*. Una cola `deferred` que crece es un indicador temprano de una caída aguas abajo; una cola `active` que crece es un problema de capacidad; una cola `hold` que crece suele ser una intervención manual que alguien se olvidó. Leer con fluidez la salida de `mailq` es lo mínimo indispensable.

1. Confirmá que la cola está vacía, usando tanto el comando compatible como el nativo.

   ```bash
   mailq
   postqueue -p
   /usr/sbin/sendmail -bp
   ```

   ```
   Mail queue is empty
   ```

2. Mirá la estructura del directorio de cola en disco.

   ```bash
   postconf queue_directory
   sudo ls -l /var/spool/postfix/
   ```

   ```
   queue_directory = /var/spool/postfix
   drwx------  2 postfix root  active
   drwx------ 18 postfix root  bounce
   drwx------ 18 postfix root  deferred
   drwx------  2 postfix root  hold
   drwx------  2 postfix root  incoming
   drwx-wx---  2 postfix postdrop maildrop
   ```

3. Forzá un diferimiento: dirigí un mensaje a un dominio inalcanzable desde el laboratorio.

   ```bash
   echo "bound for nowhere" | mail -s "deferred probe" someone@invalid.example.test
   sleep 5
   mailq
   ```

   ```
   -Queue ID-  --Size-- ----Arrival Time---- -Sender/Recipient-------
   C0D1E2F3A4      438 Wed Aug 26 10:31:02  root@mail.lab.example
        (Host or domain name not found. Name service error for name=invalid.example.test
         type=A: Host not found)
                                            someone@invalid.example.test

   -- 0 Kbytes in 1 Request.
   ```

4. Inspeccioná el mensaje encolado en sí — cabeceras, sobre y cuerpo, sin tocar a mano los archivos del spool.

   ```bash
   sudo postcat -q C0D1E2F3A4 | head -n 20
   ```

   ```
   *** ENVELOPE RECORDS deferred/C/C0D1E2F3A4 ***
   message_arrival_time: Wed Aug 26 10:31:02 2026
   named_attribute: rewrite_context=local
   sender: root@mail.lab.example
   *** MESSAGE CONTENTS deferred/C/C0D1E2F3A4 ***
   Received: by mail.lab.example (Postfix, from userid 0)
       id C0D1E2F3A4; Wed, 26 Aug 2026 10:31:02 +0000
   To: someone@invalid.example.test
   Subject: deferred probe
   ...
   *** HEADERS EXTRACTED deferred/C/C0D1E2F3A4 ***
   *** MESSAGE FILE END deferred/C/C0D1E2F3A4 ***
   ```

5. Pedí un reintento inmediato, después poné el mensaje en hold y liberalo.

   ```bash
   sudo postqueue -f              # flush: retry the whole deferred queue now
   sudo postsuper -h C0D1E2F3A4   # hold
   mailq | head -n 3
   ```

   ```
   -Queue ID-  --Size-- ----Arrival Time---- -Sender/Recipient-------
   C0D1E2F3A4!     438 Wed Aug 26 10:31:02  root@mail.lab.example
   ```

   ```bash
   sudo postsuper -H C0D1E2F3A4   # release from hold
   sudo postsuper -r C0D1E2F3A4   # requeue (re-run through cleanup, new queue ID)
   ```

6. Resumí la cola como lo harías durante un incidente, y después vaciala.

   ```bash
   qshape deferred 2>/dev/null | head -n 5     # if postfix-doc/qshape is installed
   mailq | awk '/^[A-F0-9]/ {n++} END {print n+0, "queued"}'
   sudo postsuper -d ALL deferred              # delete every deferred message
   ```

   ```
   postsuper: Deleted: 1 message
   ```

7. Conocé la política de reintentos que gobierna cuánto sobrevive un mensaje.

   ```bash
   postconf -d maximal_queue_lifetime bounce_queue_lifetime \
               minimal_backoff_time maximal_backoff_time queue_run_delay
   ```

   ```
   maximal_queue_lifetime = 5d
   bounce_queue_lifetime = 5d
   minimal_backoff_time = 300s
   maximal_backoff_time = 4000s
   queue_run_delay = 300s
   ```

**Preguntas de control**

- **Q5.1** — Nombrá los tres comandos que imprimen la cola de correo en un host Postfix y explicá por qué existen tres nombres para una sola función.
- **Q5.2** — En la salida de `mailq`, ¿qué significan los sufijos `*` y `!` después de un queue ID, y qué indica un ID completamente pelado (sin sufijo)?
- **Q5.3** — Distinguí los directorios de cola `incoming`, `active`, `deferred` y `hold` por la condición que pone un mensaje en cada uno.
- **Q5.4** — Un mensaje muestra `(connect to mx.example.net[203.0.113.25]:25: Connection timed out)`. ¿Es una falla permanente o temporal, qué hará el MTA a continuación, y cuándo se da finalmente por vencido?
- **Q5.5** — ¿Cuál es la diferencia operativa entre `postsuper -r` y `postqueue -f`? ¿Cuál cambia el queue ID, y por qué querrías eso alguna vez?
- **Q5.6** — ¿Por qué nunca deberías editar o borrar archivos de `/var/spool/postfix/deferred/` directamente con `rm`?
- **Q5.7** — `/var/spool/postfix/maildrop` tiene modo `drwx-wx---` y pertenece a `postfix:postdrop`. Explicá cómo un usuario sin privilegios puede enviar correo a un directorio que no puede leer.

---

## Ejercicio 6 — Reconocer los cuatro MTA por sus huellas

**Por qué importa.** El objetivo nombra explícitamente **postfix, sendmail, exim y qmail**. No vas a configurarlos en el examen, pero tenés que reconocer un host por sus rutas de configuración, su comando de cola nativo y sus nombres de proceso — con frecuencia antes de tener historial de shell o documentación.

1. Construí un script de reconocimiento que funcione sin importar cuál MTA esté presente.

   ```bash
   cat <<'EOF' | sudo tee /usr/local/bin/whichmta >/dev/null
   #!/bin/sh
   for p in /etc/postfix/main.cf /etc/mail/sendmail.cf /etc/exim4/exim4.conf.template \
            /etc/exim/exim.conf /var/qmail/control/me; do
       [ -e "$p" ] && echo "config present: $p"
   done
   command -v postconf   >/dev/null && echo "native: postconf (Postfix)"
   command -v exim       >/dev/null && echo "native: exim (Exim)"
   command -v qmail-qstat>/dev/null && echo "native: qmail-qstat (qmail)"
   [ -d /etc/mail/m4 ]   && echo "native: m4 macro tree (Sendmail)"
   EOF
   sudo chmod +x /usr/local/bin/whichmta
   whichmta
   ```

   ```
   config present: /etc/postfix/main.cf
   native: postconf (Postfix)
   ```

2. Memorizá la tabla de huellas.

   | | **Postfix** | **Sendmail** | **Exim** | **qmail** |
   |---|---|---|---|---|
   | Config principal | `/etc/postfix/main.cf`, `master.cf` | `/etc/mail/sendmail.cf` (generado desde `sendmail.mc` con `m4`) | `/etc/exim4/` (config dividida de Debian) o `/etc/exim/exim.conf` | `/var/qmail/control/*` (un archivo por parámetro) |
   | Ver la cola | `postqueue -p` / `mailq` | `sendmail -bp` / `mailq` | `exim -bp` / `mailq` | `qmail-qstat`, `qmail-qread` |
   | Forzar la cola (flush) | `postqueue -f` | `sendmail -q` | `exim -qff` | `qmail-tcpok` + SIGALRM a `qmail-send` |
   | Borrar un mensaje | `postsuper -d <id>` | `rm` en `/var/spool/mqueue` | `exim -Mrm <id>` | `qmail-remove` (de terceros) |
   | Probar el ruteo de direcciones | `postmap -q`, `sendmail -bv` | `sendmail -bt` | `exim -bt <addr>` | — |
   | Reconstruir la base de aliases | `newaliases` / `postalias` | `newaliases` / `makemap` | (Debian) `update-exim4.conf` | — (usa `~/.qmail`) |
   | Reenvío por usuario | `~/.forward` | `~/.forward` | `~/.forward` | `~/.qmail` |
   | Arquitectura | múltiples demonios pequeños de mínimo privilegio | un único binario monolítico grande | un binario, configuración de router/transport en múltiples fases | múltiples demonios pequeños, supervisión con `daemontools` |
   | Cadena de versión | `postconf mail_version` | `sendmail -d0.1 -bt </dev/null` | `exim -bV` | `/var/qmail/bin/qmail-send` (sin `--version`) |

3. Ejercitá las banderas compatibles con sendmail que **todos** implementan — son las portables, y las que vale la pena memorizar.

   ```bash
   /usr/sbin/sendmail -bp                       # print the queue
   printf 'To: alice\nSubject: via -t\n\nbody\n' | /usr/sbin/sendmail -t
   /usr/sbin/sendmail -f noreply@lab.example -- alice   # set the envelope sender
   /usr/sbin/sendmail -bv alice                 # verify without delivering
   ```

   ```
   Mail queue is empty
   ...
   alice... deliverable: mailer local, user alice
   ```

4. Si tenés Exim disponible en un segundo contenedor, contrastá un comando directamente:

   ```bash
   exim -bt bob@mail.lab.example
   ```

   ```
   bob@mail.lab.example
     router = localuser, transport = mail_spool
   ```

**Preguntas de control**

- **Q6.1** — Caés en un host desconocido. `mailq` funciona, `postconf` no se encuentra, y `/etc/exim4/` existe. ¿Cuál MTA es, y qué comando nativo muestra su cola?
- **Q6.2** — ¿Cuál de los cuatro MTA *no* usa `~/.forward`, y qué usa en su lugar?
- **Q6.3** — ¿Por qué existe un archivo `sendmail.cf` junto a un `sendmail.mc`, y cuál de los dos debería editar un administrador?
- **Q6.4** — Nombrá las banderas compatibles con sendmail para: imprimir la cola, leer los destinatarios desde las cabeceras del mensaje, definir el remitente del sobre, correr como demonio, y reconstruir la base de datos de aliases.
- **Q6.5** — Tanto Postfix como qmail se describen como "múltiples demonios cooperantes", mientras que Sendmail es un único binario `setuid root`. Enunciá el argumento de seguridad que hace esta arquitectura.

---

## Ejercicio 7 — Escenarios de diagnóstico (sin pistas)

**Por qué importa.** Cada uno de estos es una forma real de falla. Reproducila, y después explicala antes de leer la respuesta.

1. **El alias que no hace nada.**

   ```bash
   sudo sed -i 's/^root:.*/root: bob/' /etc/aliases
   echo "scenario 1" | mail -s "s1" root
   sudo grep -E 'orig_to' /var/log/mail.log | tail -n 1
   ```

   El correo sigue llegando para `alice`, no para `bob`. **¿Por qué?**

2. **El reenvío que se esfumó.**

   ```bash
   sudo -u alice bash -c 'echo "bob@mail.lab.example" > ~/.forward'
   sudo chmod 777 /home/alice
   echo "scenario 2" | mail -s "s2" alice
   sudo grep -iE 'warning.*forward' /var/log/mail.log | tail -n 1
   ```

   El archivo tiene modo `0644` y pertenece a `alice`, y sin embargo el reenvío se ignora. **¿Por qué?**
   (Restaurá después: `sudo chmod 755 /home/alice; sudo rm -f ~alice/.forward`)

3. **La cola que nunca se vacía.**

   ```bash
   mailq
   ```

   ```
   -Queue ID-  --Size-- ----Arrival Time---- -Sender/Recipient-------
   D1E2F3A4B5!    1204 Mon Aug 24 03:12:41  monitoring@mail.lab.example
                                            pager@example.net
   ```

   `postqueue -f` no tiene efecto sobre esta entrada. **¿Por qué, y cuál es la solución?**

4. **La aplicación que no puede enviar.** Una app PHP llama a `mail()`; no se encola nada y el log está mudo. `ls -l /usr/sbin/sendmail` devuelve *No such file or directory*, pero Exim está instalado y corriendo. **¿Cuál es el diagnóstico y la solución?**

5. **La tormenta de rebotes.** El correo de root está aliasado a `oncall@corp.example`, cuyo MX está inalcanzable desde hace seis horas. `mailq` muestra 900 mensajes diferidos provenientes de `cron`. **¿Cuáles son los dos riesgos en conflicto, y qué perilla tocarías primero?**

**Preguntas de control**

- **Q7.1** hasta **Q7.5** — una por cada escenario de arriba.

---

## Limpieza

```bash
sudo postsuper -d ALL
sudo sed -i '/# --- lab 108.3 ---/,$d' /etc/aliases
sudo newaliases
sudo rm -f ~alice/.forward ~bob/.forward /etc/mail/platform-team /usr/local/bin/whichmta
sudo userdel -r alice; sudo userdel -r bob
```

---

<details>
<summary><strong>Clave de respuestas — clic para expandir</strong></summary>

### Ejercicio 1 — Identificación del MTA

**A1.1** — Sendmail definió la interfaz de facto de envío de correo en UNIX mucho antes de que existieran Postfix o Exim, y miles de programas (cron, `logrotate`, `smartd`, PHP, agentes de monitoreo, scripts de shell) tienen hardcodeados `/usr/sbin/sendmail`, `mailq` y `newaliases`. Por eso todo MTA moderno provee una **capa de compatibilidad** que implementa esos nombres de comando y sus banderas clásicas. En Postfix los tres nombres son el *mismo binario*, que elige su comportamiento a partir de `argv[0]`: invocado como `mailq` hace `sendmail -bp`; invocado como `newaliases` hace `sendmail -bi`. Un binario, tres puntos de entrada.

**A1.2** — Sí, funciona. `-t` le indica al programa de envío que **lea la lista de destinatarios desde las propias cabeceras del mensaje** (`To:`, `Cc:`, `Bcc:`) en lugar de desde la línea de comandos, y que quite `Bcc:` antes de encolar. El binario de compatibilidad de Postfix implementa `-t` de forma idéntica, así que el script heredado no se ve afectado por el cambio de MTA. Esa portabilidad es exactamente el punto de la capa de compatibilidad.

**A1.3** — `postconf -d` imprime los **valores por defecto integrados** (cientos de parámetros); `postconf -n` imprime solo los parámetros cuyos valores **difieren del default**, es decir lo que realmente está en `main.cf`. `postconf -n` es lo correcto para pegar en un ticket porque es corto, es el conjunto completo de decisiones locales, y no puede inducir al lector a creer que un valor por defecto fue elegido deliberadamente. `postconf -n` es además el artefacto estándar que se pide en la lista de correo postfix-users.

**A1.4** — `mydestination` es la decisión **entrante**: una lista de dominios para los cuales este host se considera el destino final y realiza entrega local (vía el agente de entrega `local` y `/etc/aliases`). `myorigin` es la decisión **saliente**: el dominio que se agrega a las direcciones enviadas localmente que no tienen parte de dominio, de modo que `root` se vuelve `root@mail.lab.example`. Poner en `mydestination` un dominio que en realidad no servís hace que te tragues su correo; poner ahí un dominio que también aparece en `relay_domains` o `virtual_mailbox_domains` es una mala configuración clásica.

**A1.5** — El mecanismo de paquetes virtuales de Debian. Cada paquete de MTA declara `Provides: mail-transport-agent, default-mta` junto con `Conflicts: mail-transport-agent` y `Replaces: mail-transport-agent`. El `Conflicts` mutuo sobre el paquete virtual garantiza que haya como máximo un MTA instalado a la vez, de modo que la propiedad de `/usr/sbin/sendmail` no es ambigua. La familia RHEL resuelve el mismo problema de otra manera, permitiendo la coexistencia y arbitrando con `alternatives --config mta`.

---

### Ejercicio 2 — Evidencia de entrega

**A2.1** — `dsn=` es el código de estado extendido de **Delivery Status Notification** (RFC 3463): `2.0.0` = éxito, clase 2 = finalización positiva. `status=sent` es el veredicto de Postfix para ese destinatario, y el paréntesis `(delivered to mailbox)` nombra el mecanismo. Para un destinatario inexistente, la misma línea se convierte en:

```
dsn=5.1.1, status=bounced (unknown user: "nosuchuser")
```

`5.1.1` es *falla permanente, direccionamiento, dirección de buzón de destino incorrecta*. Los tres verbos de estado que hay que conocer son **sent**, **deferred** (temporal, se reintentará) y **bounced** (permanente, se genera un informe de no entrega).

**A2.2** — Postfix obedeció al destinatario del **sobre**, indicado en `RCPT TO:`. Las cabeceras `To:`/`Cc:` son *contenido* del mensaje y no tienen incidencia en el ruteo. Esta distinción es fundamental:

- Es la razón por la que **Bcc** funciona en absoluto — destinatarios de sobre que no aparecen en ninguna cabecera.
- Es la razón por la que funcionan los **aliases y las listas de correo**: el destinatario del sobre se reescribe a la expansión mientras las cabeceras siguen diciendo `sre-oncall@…`, que es exactamente lo que el lector humano debe ver.
- Es la razón por la que los rebotes van al **remitente del sobre** (`MAIL FROM`, el `Return-Path`), y no a la cabecera `From:`.

**A2.3** — `postfix/pickup` recogió el mensaje enviado localmente desde el directorio `maildrop` y se lo pasó a `cleanup`, que normalizó las cabeceras y lo escribió en `incoming`; `qmgr` lo movió a `active` y lo despachó; el agente de entrega `postfix/local` realizó la entrega final. `relay=local` te dice que lo manejó el **agente de entrega local** — no hubo ninguna conversación SMTP con un host remoto, así que el mensaje nunca salió de la máquina. (Una entrega remota diría `relay=mx.example.net[203.0.113.25]:25`.)

**A2.4** — **mbox** es un único archivo plano por usuario (`/var/mail/alice`) que contiene todos los mensajes concatenados, cada uno comenzando con una línea separadora `From `; requiere bloqueo de archivo y un escritor concurrente puede corromperlo. **Maildir** es un árbol de directorios (`~/Maildir/{new,cur,tmp}/`) con **un archivo por mensaje** y nombres de archivo únicos, de modo que la entrega no requiere bloqueos y es segura sobre NFS. Postfix cambia con `home_mailbox = Maildir/`. La **barra final es obligatoria** — es precisamente así como Postfix distingue "entregar en formato Maildir dentro de este directorio" de "agregar a este archivo mbox". La misma regla aplica a `mail_spool_directory`.

**A2.5** — Los cuatro números son: tiempo en las etapas **previas al gestor de cola** (`pickup`/`cleanup`), tiempo en el **gestor de cola** antes del traspaso, tiempo **conectando/enviando** al siguiente salto, y tiempo de la **transmisión más el acuse de recibo remoto**. Un cuarto valor grande con los tres primeros cerca de cero significa que el host local fue rápido y que el **lado remoto/destino tardó en aceptar y acusar recibo** de los datos — un problema aguas abajo (escáner de contenido lento, almacén de correo sobrecargado, receptor aplicando throttling), no local. Este único campo dirige un escalamiento correctamente en segundos.

---

### Ejercicio 3 — `/etc/aliases`

**A3.1** — `/etc/aliases` es un archivo fuente de texto plano; el agente de entrega nunca lo lee en tiempo de ejecución. `newaliases` lo compila en una **base de datos indexada** — `/etc/aliases.db` (hash Berkeley DB) en Debian/RHEL, `/etc/aliases.lmdb` donde LMDB es el tipo de mapa por defecto — de modo que las búsquedas son O(1) en lugar de un barrido lineal de un archivo que puede tener miles de entradas. Comandos equivalentes: `sendmail -bi` (la bandera clásica de la que `newaliases` es un atajo) y `postalias /etc/aliases` (nativo de Postfix). Olvidarse de esta reconstrucción es el error más común de `/etc/aliases`, y falla como `status=bounced (unknown user: …)`.

**A3.2** — `alias_maps` es la lista de tablas de búsqueda que **el agente de entrega `local` consulta al momento de la entrega**. `alias_database` es la lista de tablas que **`newaliases` reconstruye**. Están separadas porque un sitio puede consultar mapas que no le pertenecen (LDAP, NIS, un hash compartido de solo lectura) y no debe intentar reconstruirlos. Modos de falla: definir solo `alias_maps` y `newaliases` no reconstruye nada, así que las ediciones nunca surten efecto; definir solo `alias_database` y la reconstrucción funciona pero el mapa jamás se consulta, así que los aliases se ignoran por completo. En un host normal ambos deberían referenciar el mismo `hash:/etc/aliases`.

**A3.3** — El comando corre como el usuario de **`default_privs`** (`nobody` por defecto en Postfix), *no* como root — Postfix deliberadamente se niega a ejecutar con privilegios los comandos canalizados desde aliases. Es sensible desde el punto de vista de seguridad porque hace que un programa arbitrario sea **alcanzable por cualquiera que pueda enviar correo a esa dirección**, con datos controlados por el atacante en stdin: metacaracteres de shell, tamaño de mensaje ilimitado y cabeceras diseñadas a medida se vuelven todos superficie de inyección. Alternativas más seguras: entregar a un buzón y tener un consumidor que lo **sondee** y lo lea fuera de banda; o usar un transporte de entrega local específico y aislado en `master.cf` con un UID sin privilegios explícito y restricciones de `flags=`. Nótese además que el **código de salida** de un destino de tipo pipe importa — `EX_TEMPFAIL` (75) provoca un reintento, otros valores distintos de cero provocan un rebote.

**A3.4** — `:include:/path/to/file` le indica a la expansión de aliases que lea la **lista de destinatarios desde un archivo externo**, una dirección por línea. Es preferible para una dirección de equipo porque: la lista de miembros puede ser editada por un responsable delegado con acceso de escritura únicamente a ese archivo (sin root, sin acceso a `/etc/aliases`); **no requiere ejecutar `newaliases`** tras un cambio, ya que el archivo se lee al momento de la entrega; mantiene `/etc/aliases` legible en lugar de tener líneas de 200 caracteres; y puede generarse desde gestión de configuración o exportarse desde un sistema de RR. HH. de forma independiente de la configuración del MTA.

**A3.5** — `orig_to=` registra la **dirección del destinatario tal como era antes de la expansión de alias o `.forward`**, mientras que `to=` muestra el destinatario final resuelto. Su presencia es prueba directa de que **se disparó un mecanismo de redirección**. Si el correo para `sre-oncall@` aterriza en el buzón de Alice con `orig_to=<sre-oncall@…>`, el alias funcionó. Si aterriza ahí **sin ningún campo `orig_to`**, no hubo expansión — el remitente simplemente le escribió a Alice, o un cliente de correo reescribió la dirección. Este único campo separa "el alias está mal configurado" de "el remitente está confundido".

**A3.6** — No, el destino de un alias no necesita ser local; puede ser cualquier dirección válida, una ruta de archivo, un pipe o un `:include:`. Apuntar `root` a una dirección remota introduce una fuerte **dependencia de entrega saliente justo para el correo que informa que el host está roto**: si el DNS está caído, la red está particionada o el relay es inalcanzable, la notificación de falla de RAID queda diferida en la cola local y nadie recibe el aviso. El patrón resiliente es la entrega dual — `root: \root, oncall@corp.example` — que conserva una copia local que sobrevive a cualquier falla de red y a la vez reenvía a una persona.

---

### Ejercicio 4 — `~/.forward`

**A4.1** — Las tres deben cumplirse:
1. El archivo **pertenece al usuario** cuyo correo se está entregando (o a root).
2. El archivo **no es escribible por el grupo ni por todos** (modo `0644`/`0600`, nunca `g+w`/`o+w`).
3. El **propio directorio home** no es escribible por el grupo ni por todos, y tampoco ningún directorio padre en la ruta.

Cuando alguna condición falla, el MTA **registra una advertencia e ignora el archivo en silencio**, entregando al buzón local normal del usuario. **No hay rebote ni notificación al remitente ni al usuario** — la entrega informa `status=sent`. Por eso las investigaciones de "mi reenvío dejó de funcionar" tienen que empezar por `ls -ld ~ ~/.forward`, no por el contenido del archivo.

**A4.2** — Una barra invertida inicial significa **"entregá al buzón de este usuario local directamente, y no expandas más esta dirección"** — el procesamiento de aliases y `.forward` queda suprimido para esa entrada. Escribir `bob` a secas dentro del propio `~/.forward` de `bob` reingresaría al procesamiento de reenvío para `bob`, leería el mismo archivo otra vez y produciría un bucle infinito que el MTA aborta con `dsn=5.4.6, status=bounced (mail forwarding loop)`. Por lo tanto `\bob` es la **única** forma correcta de expresar "conservar una copia local y a la vez reenviar a otro lado". La misma convención de barra invertida funciona en `/etc/aliases` (`root: \root, oncall@corp.example`).

**A4.3** —

| Eje | `/etc/aliases` | `~/.forward` |
|---|---|---|
| Quién puede editarlo | solo root | el dueño del buzón, sin privilegios |
| Reconstrucción requerida | **sí** — `newaliases` / `postalias` / `sendmail -bi` | **no** — se lee al momento de la entrega |
| Alcance | cualquier nombre de destinatario local del host, incluidos nombres sin cuenta UNIX asociada | exactamente un usuario: el dueño del archivo |
| Almacenamiento | un archivo de sistema, compilado a un `.db` indexado | un archivo de texto plano por directorio home |
| Tipos de destino adicionales | `:include:`, archivos, pipes, múltiples destinatarios | archivos, pipes, múltiples destinatarios (sin `:include:`) |

**A4.4** — Porque la verificación de permisos es una verificación de **autorización**, no de sintaxis. Un `.forward` (o un directorio home) escribible por el grupo o por todos significa que *alguien distinto del dueño puede decidir adónde va el correo de ese usuario* — un atacante con acceso de escritura podría exfiltrar el correo de un colega hacia una dirección externa, o apuntar el archivo a un pipe `|command` y obtener ejecución de código en cada mensaje entrante. Rebotar filtraría la existencia de la mala configuración a cualquier remitente externo que la sondee, y rompería la entrega por una condición que el *remitente* no puede arreglar. Ignorar el archivo **falla cerrado en la redirección mientras sigue entregando el correo**: no se pierden datos, no se divulgan datos, y la evidencia queda en el log para el administrador.

**A4.5** — `5.x.x` es una falla **permanente** (clase 5 del RFC 3463): el MTA no reintentará, el mensaje sale de la cola y se envía un informe de no entrega al remitente del sobre. `4.x.x` habría sido una falla **transitoria** — el mensaje queda en la cola `deferred` y se reintenta según el calendario de backoff hasta que expire `maximal_queue_lifetime`. Las subpartes de `5.4.6` son *clase 5 = permanente, asunto 4 = red/ruteo, detalle 6 = bucle de ruteo detectado*. La regla práctica: 4.x.x significa esperar, 5.x.x significa arreglar algo.

**A4.6** — No pasa nada — qmail no lee `~/.forward` en absoluto, así que el correo se entrega normalmente al buzón local del usuario y el reenvío queda inerte en silencio. qmail usa **`~/.qmail`** (y archivos `~/.qmail-extension` para extensiones de dirección), con una sintaxis distinta: una línea que empieza con `&` reenvía a una dirección (`&alice@example.net`), una línea que empieza con `|` canaliza a un programa, una línea que empieza con `/` o `.` entrega a un archivo o Maildir, y un **archivo `~/.qmail` vacío** significa "descartar". El concepto se traslada; el nombre del archivo y la sintaxis no.

---

### Ejercicio 5 — La cola

**A5.1** — `mailq`, `postqueue -p` y `sendmail -bp`. Los tres producen salida idéntica porque `mailq` es un enlace simbólico al binario compatible con Sendmail, que traduce `-bp` en una petición `postqueue -p`. Existen tres nombres por razones de compatibilidad: `mailq` y `sendmail -bp` son las interfaces históricas de Sendmail que los scripts y los administradores ya conocen, mientras que `postqueue` es el comando propio de Postfix con opciones nativas adicionales (`-f` flush, `-s <site>`, `-j` salida JSON). Nótese que `postqueue` es `setgid postdrop`, que es la forma en que a un usuario sin privilegios se le permite leer la cola.

**A5.2** — `*` marca un mensaje en la cola **active** — el gestor de cola lo tiene en mano y la entrega está en curso o es inminente. `!` marca un mensaje **en hold** — un administrador ejecutó `postsuper -h`, y no se entregará hasta que se lo libere explícitamente con `postsuper -H`. Un ID pelado sin sufijo significa que el mensaje está **diferido**: un intento anterior falló temporalmente y espera su próximo reintento programado. En un host sano, `mailq` está vacío o muestra un puñado de entradas `*`; una lista larga de IDs pelados es un problema de diferimiento, y las entradas `!` que nadie recuerda haber creado son correo trabado.

**A5.3** —
- **`incoming`** — mensajes que `cleanup` terminó de escribir pero que el gestor de cola aún no recogió. Estado transitorio normal.
- **`active`** — mensajes con los que el gestor de cola está trabajando en este momento. Esta cola está deliberadamente **acotada** (`qmgr_message_active_limit`, por defecto 20 000) para que el uso de memoria se mantenga plano sin importar cuánto correo esté acumulado.
- **`deferred`** — mensajes cuya entrega falló con un error **transitorio** (4.x.x), a la espera de reintento con backoff exponencial entre `minimal_backoff_time` y `maximal_backoff_time`.
- **`hold`** — mensajes que un administrador o una regla de política congeló. Nada de lo que está en `hold` se intenta jamás, y nada expira de ahí; es una cola de intervención manual.

(También existen: `maildrop` para envíos locales que esperan a `pickup`, `bounce`/`defer` que guardan los registros de falla por mensaje, y `corrupt` para archivos ilegibles.)

**A5.4** — **Temporal.** Un timeout de conexión es una condición de clase 4.x.x: el destino puede estar simplemente caído o aplicando throttling, así que declarar la dirección permanentemente inentregable destruiría correo legítimo. El MTA deja el mensaje en la cola `deferred` y reintenta con **backoff exponencial**, empezando en `minimal_backoff_time` (300 s) y duplicando hasta `maximal_backoff_time` (4000 s). Después de `maximal_queue_lifetime` (por defecto **5 días**) se da por vencido y devuelve un informe permanente de no entrega al remitente del sobre. Un `bounce_queue_lifetime` separado gobierna cuánto tiempo sigue el MTA intentando entregar el *mensaje de rebote en sí*.

**A5.5** — `postqueue -f` (**flush**) le pide al gestor de cola que **reintente inmediatamente cada mensaje diferido**, ignorando los temporizadores de backoff. Los mensajes quedan intactos — mismos queue IDs, mismo contenido, mismas cabeceras. `postsuper -r` (**requeue**) hace pasar el mensaje otra vez por `cleanup`, lo que significa que la reescritura de cabeceras, el mapeo de direcciones `canonical`/`virtual` y los `header_checks` se **vuelven a aplicar**, y el mensaje recibe un **nuevo queue ID** (más una cabecera `Received:` adicional). Querés el camino de requeue cuando el diferimiento fue causado por un error de *configuración* que ya corregiste — un `relayhost` equivocado, un mapa canonical malo, una regla de header_checks — porque un flush a secas reentregaría el mensaje con la reescritura vieja y equivocada todavía incorporada.

**A5.6** — Porque la cola es una **estructura de datos viva y transaccional** que pertenece a demonios en ejecución, no un directorio de archivos inertes. Un mensaje consiste en registros de sobre, contenido y cabeceras extraídas escritos en un formato específico, y su presencia está coordinada con el estado en memoria del gestor de cola y con los libros de registro `defer`/`bounce` por mensaje en directorios hermanos. Eliminar archivos por debajo de un `qmgr` en ejecución puede dejar registros de rebote huérfanos, disparar errores de "file not found" en medio de una entrega, o mover un mensaje a la cola `corrupt`. Además, la disposición de subdirectorios con hash (`deferred/C/C0D1E2F3A4`) hace que un `rm` ingenuo en el directorio de arriba no encuentre nada. Usá siempre `postsuper` (`-d`, `-h`, `-H`, `-r`), que está escrito para manipular la cola de forma segura contra un demonio vivo.

**A5.7** — El directorio tiene modo `drwx-wx---`, dueño `postfix`, grupo `postdrop`. El `-wx` para el grupo otorga **escritura y ejecución (atravesar) pero no lectura**: un miembro de `postdrop` puede *crear* un archivo en el directorio y atravesarlo, pero no puede hacerle `ls` ni enumerar los envíos de otros usuarios. El comando `postdrop` se instala **`setgid postdrop`**, así que cualquier usuario que lo ejecute gana temporalmente ese grupo y puede depositar un mensaje. Este es el camino de envío de mínimo privilegio — sin `setuid root` en ninguna parte, sin capacidad de leer el correo encolado de otras personas, y los demonios de Postfix nunca corren con los privilegios del usuario que envía. Es la expresión concreta del argumento arquitectónico de A6.5.

---

### Ejercicio 6 — Los cuatro MTA

**A6.1** — **Exim.** `mailq` funciona porque Exim también provee una capa de compatibilidad con Sendmail; la ausencia de `postconf` descarta Postfix; `/etc/exim4/` es el directorio de configuración dividida de Debian para Exim 4. El comando de cola nativo es **`exim -bp`** (con `exiqgrep` para filtrar, `exim -bpc` para un conteo pelado, `exim -M <id>` para forzar un mensaje, y `exim -Mrm <id>` para eliminar uno).

**A6.2** — **qmail**. Usa **`~/.qmail`** con su propia sintaxis: `&address` para reenviar, `|command` para canalizar, `/path/` o `./Maildir/` para entregar a un archivo o Maildir, y un archivo vacío para descartar. Las extensiones de dirección se soportan con archivos adicionales (`~/.qmail-lists`, que corresponde a `user-lists@…`), que es la característica distintiva de ruteo por usuario de qmail.

**A6.3** — `sendmail.cf` es la configuración de ejecución real de Sendmail: un lenguaje denso de conjuntos de reglas con líneas `S`/`R` y rulesets de reescritura, famoso por lo difícil que es escribirlo correctamente a mano. `sendmail.mc` es la **fuente de macros `m4`** — un archivo corto y legible de directivas `define()`/`FEATURE()`/`MAILER()` — desde el cual se genera `sendmail.cf` (`m4 /etc/mail/sendmail.mc > /etc/mail/sendmail.cf`, o `make -C /etc/mail`). Un administrador edita **`sendmail.mc`** y regenera; editar `sendmail.cf` a mano produce cambios que se pierden en la siguiente regeneración y que son muy fáciles de equivocar sutilmente.

**A6.4** —
- **`-bp`** — imprimir la cola de correo (lo que invoca `mailq`).
- **`-t`** — leer la lista de destinatarios desde las propias cabeceras `To:`/`Cc:`/`Bcc:` del mensaje, quitando `Bcc:`.
- **`-f <address>`** — definir el remitente del **sobre** (`MAIL FROM`, el `Return-Path` al que van los rebotes). No confundir con `-F`, que define el *nombre* completo en la cabecera `From:`.
- **`-bd`** — correr como demonio en segundo plano escuchando SMTP.
- **`-bi`** — reconstruir la base de datos de aliases (lo que invoca `newaliases`).

También vale la pena conocer: **`-q`** para forzar la cola, **`-bs`** para hablar SMTP por stdin/stdout, **`-bv`** para verificar una dirección sin entregar, y **`-v`** para una transcripción detallada.

**A6.5** — El argumento es la **separación de privilegios y el mínimo privilegio**. Históricamente Sendmail corría como un único binario grande `setuid root` que parseaba entrada de red no confiable y provista por el atacante (comandos SMTP, cabeceras, direcciones) en el mismo espacio de direcciones que contenía el privilegio root — de modo que cualquier bug de parseo era directamente un compromiso remoto de root, que es exactamente la historia que produjo su historial de CVE. Postfix y qmail descomponen el mismo trabajo en muchos programas pequeños de propósito único (`smtpd`, `cleanup`, `qmgr`, `local`, `smtp`, `pickup`, `trivial-rewrite`), cada uno corriendo **sin privilegios**, cada uno haciendo una sola cosa, comunicándose por interfaces internas bien definidas, y supervisados por un pequeño proceso `master`. Los componentes que tocan la red no tienen privilegio, los componentes que tienen privilegio nunca tocan la red, y a la cola solo se llega por el camino de envío `setgid postdrop` (A5.7). El compromiso de un componente rinde por lo tanto solo los privilegios de ese componente, no los de la máquina.

---

### Ejercicio 7 — Diagnósticos

**A7.1** — Se editó `/etc/aliases` pero **nunca se ejecutó `newaliases`**, así que `/etc/aliases.db` todavía contiene el mapeo viejo `root: alice`. El agente de entrega lee la base de datos compilada, no el archivo de texto, así que la edición no tuvo efecto. Confirmá el diagnóstico sin adivinar: `ls -l /etc/aliases /etc/aliases.db` muestra el `.db` más viejo que la fuente, y `postmap -q root hash:/etc/aliases` devuelve el valor *obsoleto*. Solución: `sudo newaliases`. (El agente `local` de Postfix también cachea handles de mapas de alias, así que en un host con carga un `postfix reload` después de la reconstrucción elimina cualquier duda.)

**A7.2** — Los permisos propios del archivo `.forward` están bien, pero `/home/alice` tiene modo `0777` — **escribible por todos**. Cualquier usuario del sistema podría reemplazar o reescribir el `.forward` que hay adentro, así que el MTA trata toda la ruta como no confiable y se niega a honrar el archivo, registrando `warning: not owner or unsafe permissions on /home/alice/.forward` (o `unsafe directory`) y entregando localmente en su lugar. **La verificación abarca la cadena de directorios, no solo el archivo.** Solución: `chmod 755 /home/alice`. Causa del mundo real: el instalador de una aplicación o un `chmod -R 777` descuidado sobre un directorio home.

**A7.3** — El sufijo `!` significa que el mensaje está **en hold**. Los mensajes en hold quedan excluidos por definición de las pasadas de cola, así que `postqueue -f` — que solo reintenta el correo *diferido* — no puede tocarlo. Alguien ejecutó `postsuper -h` (o una acción de política de `header_checks`/`smtpd` devolvió `HOLD`) y nunca lo liberó; la hora de llegada de hace cuatro días es coherente con eso. Solución: inspeccionalo primero con `postcat -q D1E2F3A4B5` para ver si todavía debe salir, y después o bien `sudo postsuper -H D1E2F3A4B5` para liberarlo a la cola diferida, o `sudo postsuper -d D1E2F3A4B5` para descartarlo. Después averiguá *por qué* quedó en hold — revisá `header_checks`/`body_checks` en busca de una acción `HOLD`, o mañana vas a estar de vuelta acá.

**A7.4** — La función `mail()` de PHP ejecuta el programa indicado por el ajuste ini `sendmail_path`, que por defecto es `/usr/sbin/sendmail -t -i`. Esa ruta no existe, así que el exec falla dentro de PHP; el mensaje nunca llega al MTA, que es precisamente por qué el **log de correo está mudo** — un log de correo vacío con una aplicación que se queja es la firma de una falla de *envío*, no de entrega. La instalación de Exim está incompleta o se eliminó el enlace simbólico de compatibilidad. Solución: instalar el paquete de compatibilidad (`exim4-daemon-light` provee `/usr/sbin/sendmail`; en Debian confirmá con `dpkg -S /usr/sbin/sendmail`), o restaurar el enlace simbólico a `/usr/sbin/exim4`. Verificá de forma independiente de PHP: `printf 'To: root\nSubject: t\n\nx\n' | /usr/sbin/sendmail -t` y revisá el log. Revisá también el log de errores de PHP — la falla del exec suele quedar registrada ahí.

**A7.5** — Los dos riesgos en conflicto son **perder las notificaciones** y **amplificar la falla**. Si acortás la ventana de reintentos o borrás la cola, se destruyen seis horas de salida de cron y monitoreo — incluyendo potencialmente la alerta que explica la caída original. Si dejás 900 mensajes reintentando, cada pasada de cola consume búsquedas DNS, slots de conexión y capacidad de la cola `active`, y cuando el MX vuelva, 900 mensajes llegarán de golpe y pueden hacer saltar los límites de tasa del receptor o un filtro de spam, retrasando justamente las alertas que necesitás. Además, si alguno llega a expirar, los rebotes se generan **de vuelta hacia la cola local** y pueden duplicar el problema.

Primera perilla: **hacer `postsuper -h` a los mensajes del destinatario afectado** para sacarlos de la rotación de reintentos sin borrar nada (`mailq | grep -B1 oncall@corp.example` para identificarlos, o `postsuper -h ALL deferred` si la cola es homogénea), y después liberarlos en lotes controlados una vez confirmado que el MX está sano. Eso detiene la amplificación, preserva todos los mensajes y es totalmente reversible — las tres propiedades que querés bajo presión de tiempo. **No** empieces subiendo `maximal_queue_lifetime` ni borrando la cola.

La solución duradera es estructural y pertenece a la revisión post-incidente: hacer que el alias de root sea de entrega dual — `root: \root, oncall@corp.example` — para que una copia local siempre sobreviva sin importar la condición de la red (ver A3.6), y encaminar el paging por un canal que no dependa de que la ruta de correo esté sana.

</details>

---

## Fuentes oficiales

- LPI, *Exam 102-500 Objectives* (LPIC-1 v5.0), tema 108.3 — <https://www.lpi.org/our-certifications/exam-102-objectives/>
- LPI, *Exam 101-500 Objectives* (LPIC-1 v5.0) — <https://www.lpi.org/our-certifications/exam-101-objectives/>
- Postfix, *Postfix Basic Configuration Readme* — <https://www.postfix.org/BASIC_CONFIGURATION_README.html>
- Postfix, *página de manual `aliases(5)`* — <https://www.postfix.org/aliases.5.html>
- Postfix, *página de manual del agente de entrega `local(8)`* (manejo de `.forward` y reglas de permisos) — <https://www.postfix.org/local.8.html>
- Postfix, *páginas de manual `postsuper(1)` y `postqueue(1)`* — <https://www.postfix.org/postsuper.1.html> · <https://www.postfix.org/postqueue.1.html>
- Postfix, *Queue Scheduler* — <https://www.postfix.org/QSHAPE_README.html>
- Postfix, *Architecture Overview* — <https://www.postfix.org/OVERVIEW.html>
- Exim, *The Exim Specification, capítulo 5: The Exim command line* — <https://www.exim.org/exim-html-current/doc/html/spec_html/ch-the_exim_command_line.html>
- Sendmail Consortium, *Sendmail Operations Guide* — <https://www.sendmail.org/>
- qmail, *página de manual `dot-qmail(5)`* — <https://cr.yp.to/qmail/man/dot-qmail.5.html>
- IETF, *RFC 5321 — Simple Mail Transfer Protocol* — <https://www.rfc-editor.org/rfc/rfc5321>
- IETF, *RFC 3463 — Enhanced Mail System Status Codes* — <https://www.rfc-editor.org/rfc/rfc3463>