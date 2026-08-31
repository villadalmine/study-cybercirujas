# 108.3 — Fundamentos del Mail Transfer Agent (MTA)

**LPIC-1, Examen 102-500 (versión 5.0)**
Cobertura del objetivo: crear alias de correo · configurar el reenvío de correo · conocimiento de los programas MTA habitualmente disponibles (postfix, sendmail, qmail, exim) — *el examen no exige configurarlos, pero la producción sí*.
Archivos y utilidades clave: `~/.forward`, comandos de la capa de emulación de sendmail, `newaliases`, `mail`, `mailq`, `postfix`, `sendmail`, `exim`, `qmail`.

---

## 1. Motivación: el problema arquitectónico detrás de un objetivo "aburrido"

### 1.1 Por qué toda máquina Linux sigue trayendo un camino de correo

El correo electrónico es el bus store-and-forward más antiguo que sigue funcionando en UNIX, y una gran cantidad de señalización de infraestructura todavía viaja sobre él, lea alguien un buzón o no:

| Productor | Mecanismo de entrega | Qué se rompe en silencio si el camino de correo local está muerto |
|---|---|---|
| `cron`/`anacron` | escribe stdout/stderr del job a `sendmail -t` cuando `MAILTO` está definido | Los jobs nocturnos que fallan no producen **ninguna** señal — cron registra la ejecución, no la salida |
| `systemd` `OnFailure=` + `systemd-cron` / unidades propias | canaliza un extracto del journal a `sendmail` | Los fallos de unidades nunca salen del nodo |
| `smartd`, `mdadm --monitor`, `zed` (ZFS Event Daemon) | `/usr/sbin/sendmail -i -t` | Prefallo de discos y degradación de arrays quedan sin reportar |
| `logwatch`, `rkhunter`, `aide`, `unattended-upgrades` | sendmail local | Los informes de cumplimiento/integridad se esfuman |
| `sudo` `mail_badpass`, PAM, `libpam-abl` | sendmail local | Eventos de seguridad perdidos |
| Código de aplicación (`mail()`, `msmtp`, shim de `sendmail`) | sendmail local | Restablecimientos de contraseña, facturas, alertas perdidos |
| Alertmanager, Zabbix, Nagios | SMTP sobre TCP hacia un relay | El paging falla exactamente en el momento en que la plataforma está degradada |

El modo de fallo es la parte peligrosa: **la ausencia de correo es indistinguible de la ausencia de problemas.** Un nodo cuyo MTA lleva seis meses muerto se ve idéntico, desde la silla del operador, a un nodo que lleva seis meses sin fallos. Por eso `mailq` devolviendo una cola no vacía es una señal SRE de primera clase, y por eso "¿es la base de datos de alias más nueva que `/etc/aliases`?" pertenece a tu monitorización a nivel de nodo, no a un runbook que nadie lee.

### 1.2 El modelo de cinco roles — sabé qué rol estás depurando

La RFC 5598 (*Internet Mail Architecture*) divide lo que los usuarios llaman "correo electrónico" en agentes distintos. Casi todo incidente de correo en producción es una atribución errónea de una falla al rol equivocado.

```
  ┌─────────┐   submission    ┌─────────┐   relay (SMTP/25)   ┌─────────┐
  │   MUA   │ ──────────────► │   MSA   │ ──────────────────► │   MTA   │
  │ mail(1) │  SMTP/587,465   │ smtpd   │   MX lookup, TLS    │  remote │
  │ mutt    │  or sendmail(1) │         │                     │         │
  └─────────┘   local pipe    └─────────┘                     └────┬────┘
                                                                   │ final delivery
                                                                   ▼
                                                             ┌─────────┐
                                                             │   MDA   │  local(8), procmail,
                                                             │         │  maildrop, dovecot-lda
                                                             └────┬────┘
                                                                  │ writes mbox / Maildir
                                                                  ▼
   ┌─────────┐    IMAP/143,993     ┌─────────┐            /var/mail/sre
   │   MUA   │ ◄────────────────── │   MRA   │ ◄───────────  ~/Maildir/
   │         │    POP3/110,995     │ dovecot │
   └─────────┘                     └─────────┘
```

| Rol | Nombre completo | Implementación típica | Puertos | Alcance en LPIC-1 108.3 |
|---|---|---|---|---|
| MUA | Mail User Agent | `mail`/`mailx`/`s-nail`, `mutt`, Thunderbird | — | sí (`mail`) |
| MSA | Mail Submission Agent | servicio `submission` de `postfix` | 587 (STARTTLS), 465 (TLS implícito) | periférico |
| MTA | Mail Transfer Agent | postfix, sendmail, exim, qmail | 25 | **sí** |
| MDA | Mail Delivery Agent | `local(8)`, `procmail`, `maildrop`, `dovecot-lda` | — | **sí** (los alias y `.forward` ocurren en tiempo de MDA) |
| MRA | Mail Retrieval Agent | dovecot, courier | 110/143/993/995 | no (ese es el territorio hermano de 108.3) |

**El dato más útil de todo este objetivo:** los alias y `~/.forward` son evaluados por el **MDA en el momento de la entrega final**, no por el MTA en el momento del relay. Un alias en el host A no tiene ningún efecto sobre el correo que el host A simplemente retransmite. Esa sola frase explica la mayoría de los tickets de "mi alias no funciona".

### 1.3 El egress-25 y por qué el MTA local es un *búfer*, no un servidor de correo

Las restricciones modernas hacen inviable el diseño ingenuo — "cada app abre una conexión SMTP a internet":

* AWS EC2, GCP, Azure, Hetzner y la mayoría de los hosters bloquean o limitan el TCP/25 saliente por defecto.
* La entregabilidad requiere alineación de SPF, DKIM y DMARC, lo que requiere un conjunto *pequeño y estable* de IPs de origen con registros PTR correctos. Cincuenta pods con cincuenta IPs de salida efímeras no se pueden autorizar.
* SMTP es un protocolo *con reintentos*. Una aplicación que hace `connect()` + `send()` de forma síncrona no tiene semántica de reintento, ni cola, y bloquea un hilo de request durante el timeout TCP (típicamente 130 s con el `tcp_syn_retries=6` por defecto).

La respuesta clásica es el patrón **null client / satélite**: un MTA local en cada host que acepta correo sólo desde `127.0.0.1`, no hace entrega local, no hace resolución DNS de MX, y reenvía todo a un smarthost. Existe para darte una *cola durable, con reintentos y en disco* a una syscall de distancia de la aplicación.

| Diseño | Durabilidad de la cola | Lógica de reintentos | Radio de impacto de una caída del relay | Superficie de entregabilidad | Costo operativo |
|---|---|---|---|---|---|
| App → MX de internet directamente | ninguna | en el código de la app (normalmente ausente) | toda la app | cada IP de app debe estar en el SPF | poca config, mucho riesgo |
| App → relay central directamente (sin MTA local) | ninguna | en el código de la app | la app bloquea/da error durante la caída del relay | 1 conjunto de IPs | bajo |
| **MTA null-client por host → relay** | **en disco, por host** | **nativa del MTA, backoff exponencial** | **ninguno — el correo se encola localmente** | 1 conjunto de IPs | medio (un MTA por host) |
| MTA sidecar por pod | en disco *si* el volumen es persistente | nativa del MTA | ninguno | 1 conjunto de IPs | alto (N contenedores, N colas que observar) |
| MTA DaemonSet por nodo + `hostPort` | en disco (PVC/hostPath del nodo) | nativa del MTA | ninguno | 1 conjunto de IPs | medio |
| Sólo clúster de relay central, apps usando API HTTP (SES/SendGrid) | del lado del proveedor | del lado del proveedor | visible para la app | gestionada por el proveedor | el más bajo, pero no es SMTP ni es LPIC-1 |

El MTA null-client es el diseño que LPIC-1 enseña implícitamente. Todo en este objetivo — el shim de sendmail, los alias, `.forward`, `mailq` — es la interfaz hacia ese búfer.

---

## 2. El panorama de los MTA

### 2.1 Tabla comparativa

| | **Postfix** | **sendmail** | **Exim** | **qmail** |
|---|---|---|---|---|
| Autor original | Wietse Venema (IBM, 1998, como "VMailer"/"IBM Secure Mailer") | Eric Allman (1981, a partir de `delivermail`, 4.1cBSD) | Philip Hazel (Universidad de Cambridge, 1995) | D. J. Bernstein (1996) |
| Upstream actual | postfix.org | proofpoint/sendmail.org | exim.org | dominio público desde noviembre de 2007; conjunto de parches `netqmail` |
| Licencia | IBM Public License 1.0 / Eclipse Public License 2.0 | Sendmail License (tipo OSI, derivada de BSD) | GPLv2 | Dominio público |
| Modelo de procesos | **Multiproceso, un trabajo por programa**, supervisado por `master(8)`; la mayoría de los componentes en `chroot` y sin privilegios | Históricamente un único binario grande `setuid root`; las versiones modernas se dividen en MSP/MTA | Único binario monolítico, hace fork por entrega y se re-`exec`uta a sí mismo | Multiproceso, muchos programas diminutos, privilegios divididos entre varios UID |
| Diseño de privilegios | mínimo privilegio por construcción; sólo `master`, la frontera `pickup`→`postdrop` y `local(8)` tocan root | gran superficie histórica de CVE (la razón por la que existen Postfix y qmail) | corre como usuario `exim`, conserva algo de root para la entrega | mínimo privilegio, con la afirmación "ningún binario setuid root" (`qmail-queue` es setgid) |
| Configuración | `main.cf` + `master.cf`, `clave = valor` plano, consultado con `postconf` | `sendmail.mc` (m4) → `sendmail.cf` **generado**; el `.cf` en crudo es célebremente ilegible | Único `exim.conf` con bloques de reglas **dirigidos por ACL**; Debian lo divide bajo `/etc/exim4/conf.d/` | Docenas de archivos de una línea bajo `/var/qmail/control/` |
| Validación de la configuración | `postfix check`, `postconf -n` | `make -C /etc/mail` | `exim -bV` (parsea la configuración e informa errores) | ninguna (los archivos son trivialmente pequeños) |
| Spool | `/var/spool/postfix/{maildrop,incoming,active,deferred,hold,corrupt}` | `/var/spool/mqueue` (`qf*` control, `df*` datos) | `/var/spool/exim4/input` (`-H` cabecera, `-D` datos) | `/var/qmail/queue/{mess,todo,intd,info,local,remote,bounce}` |
| Buzón local por defecto | `mbox` `/var/mail/$USER` | `mbox` | `mbox` | **Maildir** (qmail inventó Maildir) |
| Archivo de reenvío por usuario | `~/.forward` (ruta desde `forward_path`) | `~/.forward` | `~/.forward` (vía el router `userforward`) | **`~/.qmail`** — *no* `.forward` |
| Archivo de alias | `/etc/aliases` + `alias_maps` | `/etc/aliases` + `/etc/mail/aliases` | `/etc/aliases` vía el router `system_aliases` | `/var/qmail/alias/.qmail-<name>` |
| Protección contra bucles | cabecera `Delivered-To:` + `hopcount_limit` (por defecto 50) | conteo de saltos a partir de las líneas `Received:`, `MaxHopCount` (25) | conteo de `Received:`, `received_headers_max` (30) | `Delivered-To:` |
| Lenguaje de filtrado | externo (`header_checks`, milter, `smtpd_*_restrictions`) | API milter (inventada aquí), mapa `access` | **filtro Exim integrado + ACLs** — el más expresivo de los cuatro | externo (envoltorios de `qmail-queue`) |
| MTA por defecto en | RHEL/CentOS/Rocky/Alma 8–9, Fedora, Ubuntu Server, SUSE | casi en ningún lado por defecto hoy; RHEL todavía lo distribuye como alternativa | **Debian** (`exim4-daemon-light`) | en ningún lado por defecto |
| Mejor encaje | propósito general, alto volumen, relays, null clients | parques heredados, entornos contractualmente atados a él | política compleja por mensaje en un solo host | histórico/ideológico; núcleo sin mantenimiento |

### 2.2 Qué significan realmente los modelos de procesos cuando estás de guardia

**Postfix** — `ps` en un host Postfix es un mapa del camino del correo, lo que lo vuelve excepcionalmente depurable:

```
$ ps -eo user,pid,ppid,args --sort=ppid | grep -E 'postfix|master' | grep -v grep
root         918      1 /usr/libexec/postfix/master -w
postfix      921    918 pickup -l -t unix -u
postfix      922    918 qmgr -l -t unix -u
postfix     1740    918 tlsmgr -l -t unix -u
postfix     4412    918 smtp -t unix -u
postfix     4413    918 error -n error -t unix -u
```

Cada uno de `pickup`, `cleanup`, `qmgr`, `smtp`, `smtpd`, `local`, `pipe`, `virtual`, `lmtp`, `bounce`, `trivial-rewrite` es un programa separado y de vida corta, con un prefijo de log separado. Una línea de log `postfix/smtp[4412]:` te dice que la falla está en la entrega saliente; `postfix/local[2114]:` te dice que está en la entrega final, es decir, territorio de alias/`.forward`. **Leé el nombre del programa en el prefijo del log antes de leer cualquier otra cosa.**

**sendmail** — la razón por la que se escribieron Postfix y qmail: un único binario `setuid root` parseando entrada no confiable. El sendmail moderno separa el *Mail Submission Program* (`sendmail -Ac`, `submit.cf`, setgid `smmsp`) del demonio, pero la configuración sigue siendo generada:

```
$ ls -l /etc/mail/sendmail.mc /etc/mail/sendmail.cf
-rw-r--r--. 1 root root   6110 Aug 26 08:41 /etc/mail/sendmail.cf
-rw-r--r--. 1 root root   1962 Aug 26 08:40 /etc/mail/sendmail.mc
$ grep -c . /etc/mail/sendmail.cf
1783
```

Editás el `.mc` de 1962 bytes y después regenerás. **Nunca edites `sendmail.cf` a mano** — el siguiente `make` lo sobrescribe.

**Exim** — un único binario cuyo comportamiento es un pipeline de reglas: `ACLs` (aceptar/rechazar en tiempo SMTP) → `routers` (deciden *dónde*) → `transports` (deciden *cómo*). Los alias y `.forward` están implementados como *routers* (`system_aliases`, `userforward`), y por eso `exim -bt` (prueba de dirección) es un diagnóstico tan efectivo: reproduce la cadena de routers e imprime la decisión.

**qmail** — arquitectónicamente elegante, y el origen de Maildir y de la detección de bucles basada en `Delivered-To:`, pero el núcleo no se mantiene upstream desde 1998; usarlo en producción hoy significa `netqmail` más una pila de parches. Para el examen: *reconocelo, sabé que usa `~/.qmail` y Maildir, sabé de `qmail-qstat`/`qmail-qread`.*

### 2.3 La capa de emulación de sendmail — el verdadero contrato de interoperabilidad

Treinta años de software llaman a `/usr/sbin/sendmail`. Por lo tanto, cada MTA distribuye un binario en esa ruta que habla un subconjunto de la CLI de sendmail. **Por eso `mailq` funciona idénticamente en una máquina Postfix y en una Exim.**

| Flag | Significado | Postfix | sendmail | Exim | Notas |
|---|---|---|---|---|---|
| `-t` | leer destinatarios de las cabeceras `To:`/`Cc:`/`Bcc:` | ✔ | ✔ | ✔ | cómo envían cron/smartd/apps |
| `-f addr` | fijar el remitente de **sobre** (`MAIL FROM`) | ✔ | ✔ | ✔ | los rebotes van acá, no al `From:` |
| `-F name` | fijar el nombre completo del remitente | ✔ | ✔ | ✔ | |
| `-i` | **no** tratar un `.` solo como fin de entrada | ✔ | ✔ | ✔ | usalo siempre con `-t` en cuerpos generados |
| `-bp` | imprimir la cola de correo | ✔ | ✔ | ✔ | `mailq` es un sinónimo |
| `-bi` | (re)construir la base de datos de alias | ✔ | ✔ | ✔ | `newaliases` es un sinónimo |
| `-bs` | hablar SMTP por stdin/stdout | ✔ | ✔ | ✔ | envío scriptable sin socket |
| `-bv` | verificar/expandir direcciones, no entregar | ✔ | ✔ | ✔ | *prueba de expansión de alias* |
| `-bd` | correr como demonio | ✖ (usá `postfix start`) | ✔ | ✔ | |
| `-bt` | modo interactivo de prueba de direcciones | ✖ | ✔ | ✖ (`-bt` = prueba de dirección también en Exim, salida distinta) | |
| `-q[time]` | vaciar/procesar la cola | parcial (sólo `-q`) | ✔ | ✔ | Postfix: preferí `postqueue -f` |
| `-v` | verboso | ✔ | ✔ | ✔ | |

Tres enlaces simbólicos presentes universalmente forman el contrato: **`sendmail`, `mailq`, `newaliases`**.

### 2.4 ¿Qué MTA está realmente instalado? (hacé esto primero, siempre)

**Familia Red Hat — el sistema `alternatives`, familia `mta`:**

```
$ alternatives --display mta
mta - status is auto.
 link currently points to /usr/sbin/sendmail.postfix
/usr/sbin/sendmail.postfix - priority 30
 slave mta-mailq: /usr/bin/mailq.postfix
 slave mta-newaliases: /usr/bin/newaliases.postfix
 slave mta-rmail: /usr/bin/rmail.postfix
 slave mta-pam: /etc/pam.d/smtp.postfix
 slave mta-mailqman: /usr/share/man/man1/mailq.postfix.1.gz
 slave mta-newaliasesman: /usr/share/man/man1/newaliases.postfix.1.gz
 slave mta-sendmailman: /usr/share/man/man1/sendmail.postfix.1.gz
 slave mta-aliasesman: /usr/share/man/man5/aliases.postfix.5.gz
Current `best' version is /usr/sbin/sendmail.postfix.

$ ls -l /usr/sbin/sendmail /usr/bin/mailq /usr/bin/newaliases
lrwxrwxrwx. 1 root root 21 Aug 26 08:12 /usr/bin/mailq -> /etc/alternatives/mta-mailq
lrwxrwxrwx. 1 root root 26 Aug 26 08:12 /usr/bin/newaliases -> /etc/alternatives/mta-newaliases
lrwxrwxrwx. 1 root root 21 Aug 26 08:12 /usr/sbin/sendmail -> /etc/alternatives/mta

$ readlink -f /usr/sbin/sendmail
/usr/sbin/sendmail.postfix
```

Cambiar de MTA en RHEL es, por lo tanto, una operación de dos pasos — el paquete y el enlace de alternatives — y olvidarse del segundo paso es una caída post-migración clásica:

```
$ sudo alternatives --set mta /usr/sbin/sendmail.sendmail
$ sudo systemctl disable --now postfix && sudo systemctl enable --now sendmail
```

**Familia Debian — sin alternatives; el paquete virtual `mail-transport-agent` más `Conflicts:`.** Puede haber exactamente un paquete MTA instalado, y es el dueño directo de `/usr/sbin/sendmail`:

```
$ dpkg -S /usr/sbin/sendmail
exim4-daemon-light: /usr/sbin/sendmail

$ dpkg -l | awk '/mail-transport|postfix|exim4-daemon|nullmailer|msmtp-mta/ {print $2, $3}'
exim4-daemon-light 4.96-15+deb12u6

$ apt-cache showpkg mail-transport-agent | sed -n '/Reverse Provides/,+8p'
Reverse Provides:
postfix 3.7.11-0+deb12u2
exim4-daemon-light 4.96-15+deb12u6
exim4-daemon-heavy 4.96-15+deb12u6
nullmailer 1:2.2-3
msmtp-mta 1.8.23-1
ssmtp 2.64-11
```

Reemplazar Exim por Postfix en Debian es una única transacción, porque el `Conflicts:` fuerza el intercambio:

```
$ sudo apt-get install -y postfix
The following packages will be REMOVED:
  exim4-config exim4-daemon-light
The following NEW packages will be installed:
  postfix ssl-cert
...
Postfix is now set up with a default configuration.
```

**Identificación agnóstica del MTA, funciona en todos lados** — el banner SMTP y la herramienta de cola nunca mienten:

```
$ /usr/sbin/sendmail -bv nonexistent-probe@localhost 2>&1 | head -1
sendmail: fatal: nonexistent-probe@localhost: Recipient address rejected: User unknown in local recipient table

$ ss -lntp 'sport = :25'
State  Recv-Q Send-Q Local Address:Port Peer Address:Port Process
LISTEN 0      100        127.0.0.1:25        0.0.0.0:*     users:(("master",pid=918,fd=13))

$ printf 'QUIT\r\n' | nc -q1 127.0.0.1 25
220 edge-01.internal ESMTP Postfix
221 2.0.0 Bye
```

`master` en la salida de `ss` ⇒ Postfix. `exim4` ⇒ Exim. `sendmail-mta: accepting connections` en el banner ⇒ sendmail. `qmail-smtpd` (normalmente bajo `tcpserver`/`supervise`) ⇒ qmail.

---

## 3. Alias

### 3.1 `/etc/aliases` — sintaxis y los cinco tipos de lado derecho

El formato está definido por `aliases(5)` y es idéntico en Postfix, sendmail y Exim:

```
name: value[, value ...]
```

* `name` es **sólo una parte local** — sin `@dominio`. `/etc/aliases` no es un mapa de dominios virtuales; eso es `virtual_alias_maps` (Postfix) / `virtusertable` (sendmail).
* Las búsquedas son **insensibles a mayúsculas** en el lado izquierdo.
* Las líneas de continuación empiezan con espacio en blanco.
* `#` inicia un comentario; las líneas en blanco se ignoran.
* La expansión es **recursiva** — un alias puede apuntar a otro alias.

Las cinco formas legales del lado derecho:

| Forma | Ejemplo | Entregado por | Notas |
|---|---|---|---|
| Usuario local | `oncall: sre` | el MDA al buzón de ese usuario | luego se consulta el propio `~/.forward` del usuario |
| Dirección remota | `oncall: sre-team@example.net` | reinyectado en la cola | cruza la red — implicancias de SPF/DMARC, ver §3.7 |
| Lista de ambos | `oncall: sre, sre-team@example.net` | fan-out | los duplicados se suprimen por mensaje |
| **Archivo** | `logs: /var/mail/archive/logs` | se anexa (formato mbox) | requiere `allow_mail_to_files` |
| **Pipe a un comando** | `bugs: \|/usr/local/bin/file-ticket` | ejecutado por `pipe(8)` | **superficie de ejecución remota de código**, ver §3.6 |
| Archivo `:include:` | `sre-team: :include:/etc/mail/lists/sre-team` | lee los destinatarios de un archivo en el momento de la entrega | se edita sin `newaliases` |
| Suprimir expansión adicional | `sre: \sre, backup@example.net` | entrega localmente a `sre` *sin* volver a ejecutar alias/`.forward` | el rompe-bucles |

Un `/etc/aliases` de producción para un nodo del parque:

```
# /etc/aliases — managed by Ansible, do not edit by hand.
# After any change: newaliases (or postalias /etc/aliases)
#
# RFC 2142 mandatory role accounts ------------------------------------------
postmaster:     root
mailer-daemon:  postmaster
abuse:          root
hostmaster:     root
webmaster:      root
security:       root

# System accounts — never leave these delivering into unread local mboxes ----
bin:            root
daemon:         root
adm:            root
lp:             root
sync:           root
shutdown:       root
halt:           root
mail:           root
operator:       root
games:          root
ftp:            root
nobody:         root
systemd-network: root
dbus:           root
sshd:           root
chrony:         root
postfix:        root
nginx:          root
prometheus:     root

# The single funnel: everything above ends here -----------------------------
# Fan out to a real, monitored destination AND keep a local copy for forensics
root:           sre-oncall, \root

# Team lists ----------------------------------------------------------------
sre-oncall:     :include:/etc/mail/lists/sre-oncall
platform:       :include:/etc/mail/lists/platform
owner-sre-oncall: sre-alias-owner@example.net

# Machine-consumed destinations ---------------------------------------------
cron-archive:   /var/log/mail-archive/cron.mbox
ticket:         |/usr/local/libexec/mail2ticket --queue=infra
```

```
$ cat /etc/mail/lists/sre-oncall
# One address per line; :include: is re-read at delivery time,
# so adding a person here needs NO newaliases run.
sre-team@example.net
pagerduty+infra@example.net
```

Fijate en `root: sre-oncall, \root`. Sin el término `\root` perdés la copia local; con un término `root` pelado creás un bucle infinito. La barra invertida significa *entregá a este usuario local y dejá de expandir*.

### 3.2 La base de datos: `newaliases` y compañía

`/etc/aliases` es un **archivo fuente de texto**. El MDA nunca lo lee en el momento de la entrega — lee una base de datos indexada construida a partir de él. Olvidarse de reconstruirla es *el* bug de alias número uno.

```
$ sudo tee -a /etc/aliases >/dev/null <<'EOF'
noc: sre-oncall
EOF

$ sudo newaliases
$ ls -l /etc/aliases /etc/aliases.db
-rw-r--r--. 1 root root  1487 Aug 26 11:02 /etc/aliases
-rw-r--r--. 1 root root 12288 Aug 26 11:02 /etc/aliases.db
```

`newaliases` es exactamente `sendmail -bi`:

```
$ readlink -f "$(command -v newaliases)"
/usr/bin/newaliases.postfix
$ sudo /usr/sbin/sendmail -bi          # identical effect
```

La herramienta nativa de Postfix, que te deja nombrar el tipo de base de datos explícitamente:

```
$ sudo postalias hash:/etc/aliases
$ postalias -q noc hash:/etc/aliases
sre-oncall
$ postalias -q nonexistent hash:/etc/aliases; echo "exit=$?"
exit=1
```

Los back-ends de base de datos difieren según la distribución e importan cuando copiás un `.db` entre hosts (**no podés** — el formato es específico de la arquitectura y de la versión de la biblioteca; siempre transportá el archivo de texto y reconstruí):

| Tipo | Comando para construirla | Produce | Dónde es el predeterminado |
|---|---|---|---|
| `hash` | `postalias hash:/etc/aliases` | `/etc/aliases.db` (Berkeley DB) | Postfix en Debian/Ubuntu, sendmail |
| `lmdb` | `postalias lmdb:/etc/aliases` | `/etc/aliases.lmdb` | compilaciones de Postfix de Fedora / RHEL 9 |
| `btree` | `postalias btree:/etc/aliases` | `/etc/aliases.db` | raro |
| `cdb` | `postalias cdb:/etc/aliases` | `/etc/aliases.cdb` | estilo qmail, amigable con lo inmutable |
| `texthash` | *(ninguno — se lee al iniciar el proceso)* | nada en disco | contenedores de sólo lectura |
| `dbm`/`sdbm` | `makemap dbm` | `/etc/aliases.pag`, `.dir` | sendmail heredado |

```
$ postconf -d default_database_type          # Fedora / RHEL 9
default_database_type = lmdb

$ postconf -d default_database_type          # Debian 12
default_database_type = hash
```

sendmail usa `makemap` para sus otros mapas (`access`, `virtusertable`, `mailertable`) pero `newaliases` para los alias:

```
$ sudo makemap hash /etc/mail/access < /etc/mail/access
$ sudo make -C /etc/mail
```

Exim **no** requiere base de datos alguna — el router `system_aliases` lee el archivo de texto plano. `newaliases` en Debian/Exim es, por lo tanto, un script casi vacío que existe puramente para satisfacer el contrato de sendmail:

```
$ readlink -f "$(command -v newaliases)"
/usr/sbin/exim4
$ sudo newaliases           # succeeds silently; Exim reads /etc/aliases directly
```

### 3.3 `alias_maps` vs `alias_database` — la distinción que muerde

Postfix divide un concepto en dos parámetros, y confundirlos produce "el alias existe pero nunca se usa":

| Parámetro | Consultado por | Significado |
|---|---|---|
| `alias_maps` | `local(8)` **en el momento de la entrega** | qué bases de datos *consultar* |
| `alias_database` | `newaliases` / `sendmail -bi` | qué bases de datos *reconstruir* |

```
$ postconf alias_maps alias_database
alias_maps = hash:/etc/aliases
alias_database = hash:/etc/aliases
```

Si agregás un segundo archivo de alias, tenés que extender **ambos**:

```
$ sudo postconf -e 'alias_maps = hash:/etc/aliases, hash:/etc/postfix/aliases-team'
$ sudo postconf -e 'alias_database = hash:/etc/aliases, hash:/etc/postfix/aliases-team'
$ sudo newaliases
$ sudo postfix reload
```

Poné `alias_maps` sólo en `alias_database` y obtenés una base de datos perfectamente construida que nadie lee. Poné el archivo sólo en `alias_maps` y `newaliases` lo ignora en silencio, así que la base de datos falta en la entrega y el correo se difiere con `alias database unavailable`.

### 3.4 Listas de correo, `:include:` y la convención `owner-`

`:include:` es una indirección en tiempo de ejecución: el archivo se lee en cada entrega, así que los cambios de membresía tienen efecto inmediato sin `newaliases`. Este es el mecanismo correcto para listas gestionadas por un sistema de gestión de configuración o por una herramienta de autoservicio.

La convención `owner-<listname>` reescribe el **remitente de sobre** de los mensajes expandidos para que los rebotes de los miembros de la lista vayan al dueño de la lista en lugar de al remitente original:

```
sre-oncall:       :include:/etc/mail/lists/sre-oncall
owner-sre-oncall: sre-alias-owner@example.net
```

```
$ postconf owner_request_special expand_owner_alias
owner_request_special = yes
expand_owner_alias = no
```

Sin `owner-`, una sola dirección muerta en una lista de 200 personas bombardea a quien envió el mensaje con 200 rebotes. Esto no es cosmético: así es como el fan-out de alias termina con toda una IP emisora en una lista de bloqueo.

### 3.5 Protección contra bucles

Los alias son recursivos, y la recursión más un viaje de ida y vuelta por la red es un bucle de correo que puede saturar un relay en minutos.

| MTA | Mecanismo | Ajustable | Por defecto |
|---|---|---|---|
| Postfix | inserta `Delivered-To:` en la entrega local; se niega a reentregar a una dirección ya presente | `hopcount_limit` | 50 |
| Postfix | cuenta las cabeceras `Received:` | `hopcount_limit` | 50 |
| sendmail | cuenta las cabeceras `Received:` | `MaxHopCount` | 25 |
| Exim | cuenta las cabeceras `Received:` | `received_headers_max` | 30 |
| qmail | `Delivered-To:` | `-` | — |

Cómo se ve un bucle en el log — reconocelo al instante:

```
Aug 26 11:14:07 edge-01 postfix/local[7714]: 8C2F41A0D91: to=<noc@edge-01.internal>,
  orig_to=<root@edge-01.internal>, relay=local, delay=0.04, delays=0.02/0/0/0.02,
  dsn=5.4.6, status=bounced (mail forwarding loop for noc@edge-01.internal)
```

y el *otro* bucle, el de MX, que es una falla de configuración más que una falla de alias:

```
Aug 26 11:20:31 edge-01 postfix/smtp[7801]: 91AB41A0E02: to=<sre@example.net>,
  relay=none, delay=0.09, dsn=5.4.6, status=bounced
  (mail for example.net loops back to myself)
```

`loops back to myself` significa que el MX de un dominio resuelve a este host, pero el host no lista ese dominio en `mydestination`/`virtual_alias_domains`/`relay_domains`. No es un problema de alias; no vayas a buscar en `/etc/aliases`.

### 3.6 Seguridad: los alias `|comando` son una primitiva de RCE

Un alias de la forma `name: |/path/to/program` hace que el MDA ejecute un programa con stdin influido por el atacante, disparado por una transacción SMTP remota no autenticada. Los incidentes históricos (alias `decode:`, `|/bin/sh`) son la razón de las barandas que siguen.

**Barandas de Postfix:**

```
$ postconf allow_mail_to_commands allow_mail_to_files default_privs \
           command_execution_directory command_time_limit
allow_mail_to_commands = alias,forward
allow_mail_to_files = alias,forward
default_privs = nobody
command_execution_directory =
command_time_limit = 1000s
```

* `allow_mail_to_commands` / `allow_mail_to_files` aceptan `alias`, `forward`, `include`. Quitar `include` (el valor por defecto) bloquea la escalada del tipo el-archivo-`:include:`-contiene-un-pipe, en la que un usuario que puede escribir un archivo incluido obtiene ejecución de comandos.
* `default_privs = nobody` es el UID usado cuando se llega al pipe vía `/etc/aliases` (propiedad de root, así que no hay un UID natural). Los pipes alcanzados vía el `~/.forward` de un usuario corren como **ese usuario**.

**Baranda de sendmail — `smrsh(8)`, la shell restringida:** sendmail ejecuta los comandos de pipe a través de `/usr/sbin/smrsh`, que sólo ejecuta programas explícitamente enlazados simbólicamente dentro de su directorio:

```
$ grep -n 'FEATURE(.smrsh' /etc/mail/sendmail.mc
14:FEATURE(`smrsh', `/usr/sbin/smrsh')dnl

$ ls -l /etc/smrsh/
total 0
lrwxrwxrwx. 1 root root 16 Aug 26 09:03 procmail -> /usr/bin/procmail
lrwxrwxrwx. 1 root root 39 Aug 26 09:03 mail2ticket -> /usr/local/libexec/mail2ticket
```

Cualquier cosa no enlazada ahí es rechazada, así que `bugs: |/bin/sh -c '...'` falla de forma cerrada.

**Regla práctica de plataforma:** en un parque inmutable/contenerizado, poné `allow_mail_to_commands = ` (vacío) y `allow_mail_to_files = ` (vacío) en cada host que sea un relay puro. Un null client no tiene razón legítima para ejecutar nada, y la comprobación no cuesta nada:

```
$ sudo postconf -e 'allow_mail_to_commands =' -e 'allow_mail_to_files ='
$ sudo postfix reload
```

### 3.7 La trampa de entregabilidad en el reenvío por alias

Un alias que reenvía `alerts@example.net` → `person@gmail.com` **reenvía** el mensaje desde *tu* IP preservando la cabecera `From:` original. El lado receptor evalúa SPF contra tu IP y el dominio del remitente original, y falla. DKIM sobrevive sólo si no cambiaste nada — y el reenvío por alias a través de la mayoría de los MTA agrega cabeceras, así que a menudo no sobrevive.

| Síntoma en el destino | Causa | Mitigación |
|---|---|---|
| `550 5.7.23 SPF validation failed` | reenviado, `MAIL FROM` sigue siendo el dominio original | **SRS** (Sender Rewriting Scheme) — reescribir el remitente de sobre a tu dominio |
| `550 5.7.26 DMARC policy` | SPF falla y DKIM roto por la reescritura de cabeceras | SRS + no modificar cabeceras/cuerpo |
| Los rebotes van al remitente *original*, no a vos | sin alias `owner-` | agregar `owner-<list>` |

```
$ sudo postconf -e 'sender_canonical_maps = tcp:127.0.0.1:10001' \
                -e 'sender_canonical_classes = envelope_sender' \
                -e 'recipient_canonical_maps = tcp:127.0.0.1:10002' \
                -e 'recipient_canonical_classes = envelope_recipient,header_recipient'
$ sudo systemctl enable --now postsrsd
$ sudo postfix reload
```

Esto excede LPIC-1, pero es la diferencia entre un alias que "funciona" en un laboratorio y uno que funciona en producción.

---

## 4. `~/.forward` — reenvío controlado por el usuario

### 4.1 Sintaxis

`~/.forward` es el *lado derecho de una entrada de alias, sin la parte `name:`*, guardado en el directorio home del destinatario. No requiere privilegios de root ni reconstruir base de datos alguna — se lee como texto plano en el momento de la entrega. Todas las formas de lado derecho de §3.1 son legales.

```
$ cat ~/.forward
sre-team@example.net
```

```
$ cat ~/.forward          # fan-out plus a local copy — note the backslash
\sre, sre-team@example.net
```

```
$ cat ~/.forward          # deliver through procmail (classic)
"|IFS=' ' && exec /usr/bin/procmail -f- || exit 75 #sre"
```

Ese one-liner barroco es la receta canónica de procmail segura para sendmail: resetea `IFS` contra ataques por entorno, sale con `75` (`EX_TEMPFAIL`) para que el correo se reintente en lugar de rebotar si procmail no está, y anexa `#sre` porque sendmail basa su supresión de duplicados en la cadena literal — dos usuarios con pipes en `.forward` byte a byte idénticos colisionarían de otro modo.

```
$ cat ~/.forward          # append to a file, no forwarding
/home/sre/mail/archive
```

### 4.2 Las reglas de permisos — donde muere el 90 % de los tickets de `.forward`

Como `.forward` le da a un usuario la capacidad de hacer que el MDA ejecute código, el MDA se niega a honrar un archivo que cualquier otro pudo haber escrito. **Las comprobaciones incluyen el propio directorio home.**

| Requisito | Impuesto por |
|---|---|
| `~/.forward` propiedad del destinatario (o de root) | postfix `local(8)`, sendmail, exim |
| `~/.forward` **no** escribible por el grupo, **no** escribible por todos | todos |
| `$HOME` **no** escribible por el grupo, **no** escribible por todos | sendmail (el más estricto), exim |
| `$HOME` y `.forward` en una ruta sin `nosuid` ni `nodev`, legible por el MDA | todos |
| Directorio home alcanzable (sin NFS con root-squash, sin denegación de SELinux) | todos |

El estado correcto:

```
$ ls -ld ~ ~/.forward
drwx------. 14 sre sre 4096 Aug 26 11:31 /home/sre
-rw-r--r--.  1 sre sre   22 Aug 26 11:31 /home/sre/.forward
```

El estado roto y su firma en el log:

```
$ chmod 775 ~ ; ls -ld ~
drwxrwxr-x. 14 sre sre 4096 Aug 26 11:33 /home/sre
```

sendmail:

```
Aug 26 11:34:02 edge-01 sendmail[8812]: 27QEY2sd008812: SYSERR(root):
  forward /home/sre/.forward: Group writable directory
```

Postfix (menos locuaz; simplemente saltea el archivo y entrega al buzón — **el correo no se pierde, meramente no se reenvía**, lo que es peor para el diagnóstico):

```
Aug 26 11:34:02 edge-01 postfix/local[8814]: warning: not owner or unsafe permissions
  on /home/sre/.forward
Aug 26 11:34:02 edge-01 postfix/local[8814]: A17441A0F03: to=<sre@edge-01.internal>,
  relay=local, delay=0.03, dsn=2.0.0, status=sent (delivered to mailbox)
```

Arreglo:

```
$ chmod 700 ~ && chmod 600 ~/.forward
$ ls -ld ~ ~/.forward
drwx------. 14 sre sre 4096 Aug 26 11:35 /home/sre
-rw-------.  1 sre sre   22 Aug 26 11:31 /home/sre/.forward
```

La escotilla de escape de sendmail es la opción `DontBlameSendmail` (`ForwardFileInUnsafeDirPath`, `GroupWritableForwardFile`, …). Su nombre es deliberado y su uso es un hallazgo en cualquier revisión de seguridad. Arreglá los permisos en su lugar.

Bajo SELinux, el MDA necesita la etiqueta correcta en el archivo; un `.forward` que se ve correcto y aun así se ignora suele ser un AVC:

```
$ ls -Z ~/.forward
unconfined_u:object_r:mail_home_t:s0 /home/sre/.forward
$ sudo ausearch -m AVC -ts recent | grep -i forward
$ restorecon -Rv ~/.forward
```

### 4.3 `forward_path` y extensiones de dirección

Postfix no codifica `~/.forward` de forma fija; evalúa `forward_path`, que admite archivos por extensión:

```
$ postconf forward_path recipient_delimiter
forward_path = $home/.forward${recipient_delimiter}${extension}, $home/.forward
recipient_delimiter =
```

Activá el delimitador y obtenés subdireccionamiento con reglas de reenvío independientes por etiqueta:

```
$ sudo postconf -e 'recipient_delimiter = +'
$ sudo postfix reload
$ printf 'pagerduty+infra@example.net\n' > ~/.forward+alerts
$ chmod 600 ~/.forward+alerts
```

Ahora `sre+alerts@edge-01.internal` es enrutado por `~/.forward+alerts`, mientras que todo lo demás usa `~/.forward`. Si ninguno existe, el delimitador se descarta y la entrega recae en el buzón base — así que las direcciones `+tag` nunca rebotan. El equivalente en Exim es la opción de router `local_part_suffix`; el de sendmail es `FEATURE(subplus)` / `plussed_user`.

### 4.4 `.forward` vs `/etc/aliases` — elegir correctamente

| | `/etc/aliases` | `~/.forward` |
|---|---|---|
| Quién puede editarlo | sólo root | el usuario |
| Se aplica a | cualquier parte local, incluidos no-usuarios (`postmaster`, `ticket`) | sólo la propia dirección de ese usuario |
| Requiere reconstruir la BD | **sí** (`newaliases`) — excepto en Exim | no |
| Requiere recargar el MTA | no (la BD se relee) | no |
| Evaluado | antes de `.forward` | después de que la expansión de alias resuelva a un usuario local |
| Sobrevive al borrado del usuario | sí (es un archivo en `/etc`) | no (el home se va con el usuario) |
| Amigable con gestión de configuración | sí | incómodo (vive en `$HOME`, a menudo sobre NFS) |
| Rastro de auditoría | en Git junto con el resto de `/etc` | invisible para el equipo de plataforma |
| Herramienta correcta para | cuentas de rol, embudo de correo del sistema, listas | una persona redirigiendo temporalmente su propio correo |

**Orden de evaluación** — memorizá esta cadena, es examinable y es el orden de depuración:

```
envelope recipient  →  virtual_alias_maps        (Postfix: address@domain rewriting)
                    →  canonical_maps            (rewriting)
                    →  /etc/aliases (alias_maps)  ← recursive, root-controlled
                    →  local user resolved
                    →  ~/.forward                 ← user-controlled
                    →  mailbox_command / mailbox / home_mailbox
                    →  /var/mail/$USER  or  ~/Maildir/
```

Un alias que apunta a un usuario cuyo `.forward` apunta de vuelta al alias es un bucle; la forma `\user` en cualquiera de los dos lados lo rompe.

### 4.5 qmail es la excepción

qmail ignora `~/.forward` por completo. Su archivo de control por usuario es `~/.qmail`, con archivos de extensión `~/.qmail-alerts` para `user-alerts@host`:

```
$ cat ~/.qmail
&sre-team@example.net
./Maildir/
```

`&address` reenvía, `./Maildir/` entrega a un Maildir, `|command` canaliza, y una ruta pelada anexa a un mbox. Los alias de todo el sistema viven como `/var/qmail/alias/.qmail-<name>`:

```
$ ls -l /var/qmail/alias/
-rw-r--r-- 1 alias qmail 22 Aug 26 09:11 .qmail-postmaster
-rw-r--r-- 1 alias qmail 22 Aug 26 09:11 .qmail-root
-rw-r--r-- 1 alias qmail 22 Aug 26 09:11 .qmail-mailer-daemon
$ cat /var/qmail/alias/.qmail-root
&sre-team@example.net
```

---

## 5. La cola: `mailq` y su realidad por MTA

### 5.1 Anatomía de la cola de Postfix

```
$ sudo ls -1 /var/spool/postfix/
active
bounce
corrupt
defer
deferred
flush
hold
incoming
maildrop
pid
private
public
saved
trace
```

| Directorio | Contenido | Quién escribe | Significado para SRE |
|---|---|---|---|
| `maildrop` | correo enviado localmente desde `sendmail(1)`/`postdrop` | setgid `postdrop` | si crece ⇒ `pickup(8)` no está corriendo |
| `incoming` | mensajes aceptados, esperando a `qmgr` | `cleanup(8)` | transitorio |
| `active` | mensajes que `qmgr` está entregando **ahora** | `qmgr(8)` | acotado por `qmgr_message_active_limit` (20000) |
| `deferred` | fallo temporal, se reintentará | `qmgr(8)` | **el número sobre el que alertás** |
| `hold` | congelado manualmente o por política; nunca se reintenta | `postsuper -h` | cuarentena |
| `corrupt` | archivos de cola ilegibles | cualquiera | nunca está vacío en un host sano |
| `defer`, `bounce`, `trace` | logs por mensaje del *porqué* | `bounce(8)` | fuente del texto del DSN |

### 5.2 Leer la cola

```
$ mailq
-Queue ID-  --Size-- ----Arrival Time---- -Sender/Recipient-------
3F2A41A0C4B     1274 Wed Aug 26 09:14:02  alerts@edge-01.internal
(connect to mx1.example.net[203.0.113.25]:25: Connection timed out)
                                         oncall@example.net

8C2F41A0D91*    2148 Wed Aug 26 11:02:44  root@edge-01.internal
                                         sre-team@example.net

91AB41A0E02!    1902 Wed Aug 26 11:20:31  cron@edge-01.internal
(host mx1.example.net[203.0.113.25] refused to talk to me:
 554 5.7.1 Service unavailable; Client host [198.51.100.7] blocked)
                                         sre-team@example.net

-- 5 Kbytes in 3 Requests.
```

El sufijo en el ID de cola es el estado, y es lo primero que hay que leer:

| Sufijo | Estado |
|---|---|
| *(ninguno)* | diferido — se reintentará |
| `*` | **activo** — se está entregando en este momento |
| `!` | **en espera (hold)** — nunca se reintentará hasta que se libere |

Salida legible por máquina (Postfix ≥ 3.1) — esto es lo que raspás para métricas:

```
$ postqueue -j | jq -c '{id: .queue_id, q: .queue_name, r: .recipients[0].address, why: .recipients[0].delay_reason}'
{"id":"3F2A41A0C4B","q":"deferred","r":"oncall@example.net","why":"connect to mx1.example.net[203.0.113.25]:25: Connection timed out"}
{"id":"8C2F41A0D91","q":"active","r":"sre-team@example.net","why":null}
{"id":"91AB41A0E02","q":"hold","r":"sre-team@example.net","why":"host mx1.example.net[203.0.113.25] refused to talk to me: 554 5.7.1 Service unavailable"}
```

Distribución de antigüedad de la cola — `qshape` es la mejor herramienta de triaje que trae Postfix (paquete `postfix-perl-scripts`):

```
$ sudo qshape deferred
                        T  5 10 20 40 80 160 320 640 1280 1280+
                 TOTAL 47  0  0  2  6 11  14   9   5    0     0
       example.net     41  0  0  1  5 10  13   7   5    0     0
     partner.example    6  0  0  1  1  1   1   2   0    0     0

$ sudo qshape -s deferred          # by sender instead of recipient domain
                        T  5 10 20 40 80 160 320 640 1280 1280+
                 TOTAL 47  0  0  2  6 11  14   9   5    0     0
   edge-01.internal    47  0  0  2  6 11  14   9   5    0     0
```

Las columnas son cubetas de antigüedad en minutos. **Un dominio dominando** ⇒ el MX de ese dominio está caído o te está rechazando. **Todos los dominios subiendo uniformemente** ⇒ tu propia salida está rota (puerto 25 bloqueado, ruta por defecto muerta, fallo de DNS).

Inspeccionar un único mensaje, sobre y cabeceras incluidos:

```
$ sudo postcat -vq 3F2A41A0C4B | head -30
postcat: name_mask: all
*** ENVELOPE RECORDS deferred/3/3F2A41A0C4B ***
message_size:            1274             274               1               0            1274               0
message_arrival_time: Wed Aug 26 09:14:02 2026
create_time: Wed Aug 26 09:14:02 2026
named_attribute: rewrite_context=local
sender_fullname: Alerting
sender: alerts@edge-01.internal
*** MESSAGE CONTENTS deferred/3/3F2A41A0C4B ***
Received: by edge-01.internal (Postfix, from userid 0)
	id 3F2A41A0C4B; Wed, 26 Aug 2026 09:14:02 +0000 (UTC)
Subject: [FIRING:2] NodeFilesystemAlmostOutOfSpace
To: oncall@example.net
Date: Wed, 26 Aug 2026 09:14:02 +0000
From: Alerting <alerts@edge-01.internal>
Message-Id: <20260826091402.3F2A41A0C4B@edge-01.internal>
...
*** HEADER EXTRACTED deferred/3/3F2A41A0C4B ***
*** MESSAGE FILE END deferred/3/3F2A41A0C4B ***
```

Cirugía sobre la cola — `postsuper` es la única forma segura de tocar el spool. **Nunca hagas `rm` de un archivo de cola**; el gestor de cola cachea el estado y lo vas a corromper.

```
$ sudo postqueue -f                            # flush the whole deferred queue now
$ sudo postqueue -i 3F2A41A0C4B                # flush one message
$ sudo postqueue -s example.net                # flush one destination

$ sudo postsuper -h 91AB41A0E02                # put on hold (stop retrying)
$ sudo postsuper -H 91AB41A0E02                # release from hold
$ sudo postsuper -r 8C2F41A0D91                # requeue: re-run cleanup, re-apply aliases
$ sudo postsuper -d 3F2A41A0C4B                # delete one
$ sudo postsuper -d ALL deferred               # delete every deferred message
postsuper: Deleted: 41 messages
$ sudo postsuper -r ALL                        # requeue everything (after fixing aliases!)
postsuper: Requeued: 47 messages
```

`postsuper -r ALL` es la acción correcta después de arreglar `/etc/aliases`: reencolar vuelve a ejecutar `cleanup(8)`, que reaplica la reescritura de direcciones y la expansión de alias. `postqueue -f` meramente reintenta la entrega con la expansión *vieja* y volverá a fallar.

### 5.3 Vida útil de la cola — cuánto tiempo antes de darse por vencido con un correo

```
$ postconf maximal_queue_lifetime bounce_queue_lifetime queue_run_delay \
           minimal_backoff_time maximal_backoff_time delay_warning_time
maximal_queue_lifetime = 5d
bounce_queue_lifetime = 5d
queue_run_delay = 300s
minimal_backoff_time = 300s
maximal_backoff_time = 4000s
delay_warning_time = 0h
```

Para el correo de alertas, cinco días de reintentos está mal — un aviso que llega cuatro días tarde es ruido. Valores de producción para un null client que transporta alertas:

```
$ sudo postconf -e 'maximal_queue_lifetime = 4h' \
                -e 'bounce_queue_lifetime = 1h' \
                -e 'delay_warning_time = 15m' \
                -e 'minimal_backoff_time = 60s' \
                -e 'maximal_backoff_time = 900s'
$ sudo postfix reload
postfix/postfix-script: refreshing the Postfix mail system
```

`delay_warning_time = 15m` hace que el propio MTA te avise que está atascado, a los 15 minutos, en vez de 4 horas después cuando el mensaje se descarta.

### 5.4 Comandos de cola en los cuatro MTA

| Tarea | Postfix | sendmail | Exim | qmail |
|---|---|---|---|---|
| Listar la cola | `mailq` / `postqueue -p` | `mailq` / `sendmail -bp` | `exim -bp` / `mailq` | `qmail-qread` |
| Resumen de la cola | `qshape` | `mailq \| tail -1` | `exim -bp \| exiqsumm` | `qmail-qstat` |
| Contar mensajes | `postqueue -p \| tail -1` | `mailq \| tail -1` | `exim -bpc` | `qmail-qstat` |
| Vaciar la cola | `postqueue -f` | `sendmail -q -v` | `exim -qff` | `svc -a /service/qmail-send` |
| Entregar un mensaje | `postqueue -i ID` | `sendmail -qI<ID>` | `exim -M ID` | — |
| Borrar un mensaje | `postsuper -d ID` | `rm /var/spool/mqueue/{q,d}f<ID>` | `exim -Mrm ID` | `rm`, y después reiniciar `qmail-send` |
| Borrar todo | `postsuper -d ALL` | `rm -f /var/spool/mqueue/*` | `exim -bp \| exiqgrep -i \| xargs exim -Mrm` | — |
| Congelar / descongelar | `postsuper -h` / `-H` | — | `exim -Mf` / `-Mt` | — |
| Mostrar un mensaje | `postcat -q ID` | `cat /var/spool/mqueue/df<ID>` | `exim -Mvb ID` / `-Mvh ID` | `cat /var/qmail/queue/mess/...` |
| Filtrar la cola | `postqueue -j \| jq` | — | `exiqgrep -f '@old\.example$' -i` | — |

```
$ exim -bp
26h  2.4K 1rTqLm-000ABc-1H <alerts@edge-01.internal>
          oncall@example.net

 3h  1.9K 1rTuZp-000C1d-9K <root@edge-01.internal>
          *** frozen ***
          sre-team@example.net

$ exim -bpc
2
$ exiqgrep -f '^root@' -i
1rTuZp-000C1d-9K
$ exiqgrep -z -i | xargs -r exim -Mrm      # remove all frozen messages
Message 1rTuZp-000C1d-9K has been removed
```

```
$ qmail-qstat
messages in queue: 3
messages in queue but not yet preprocessed: 0
$ qmail-qread
26 Aug 2026 09:14:02 GMT  #2318921  1274  <alerts@edge-01.internal>
 remote  oncall@example.net
```

---

## 6. Puesta en producción — configuraciones completas, sin abreviar

### 6.1 Null client en bare-metal / VM (satélite Postfix)

`/etc/postfix/main.cf` — una configuración completa de null client. Cada parámetro no predeterminado está presente y comentado; no se omite nada.

```ini
# =============================================================================
# /etc/postfix/main.cf — NULL CLIENT (satellite) profile
# Role: accept mail from this host only, deliver nothing locally,
#       forward everything to the smarthost, queue durably on failure.
# Managed by Ansible: roles/mta/templates/main.cf.j2 — do not edit in place.
# =============================================================================

# --- Paths (distribution defaults; keep explicit for reproducibility) --------
queue_directory        = /var/spool/postfix
command_directory      = /usr/sbin
daemon_directory       = /usr/libexec/postfix
data_directory         = /var/lib/postfix
mail_owner             = postfix
setgid_group           = postdrop

# --- Identity ----------------------------------------------------------------
# myhostname MUST be a FQDN with a matching PTR record on the egress IP,
# otherwise many receivers reject with 450 4.7.1 / 550 5.7.1.
myhostname             = edge-01.internal.example.net
mydomain               = example.net
# Rewrite bare local addresses (root, cron) to @example.net so replies work.
myorigin               = $mydomain
append_dot_mydomain    = no
append_at_myorigin     = yes

# --- Listening ---------------------------------------------------------------
# A null client accepts submissions from loopback ONLY. Nothing on the wire.
inet_interfaces        = loopback-only
inet_protocols         = ipv4
mynetworks             = 127.0.0.0/8 [::ffff:127.0.0.0]/104 [::1]/128
mynetworks_style       = host

# --- No local delivery -------------------------------------------------------
# Empty mydestination + error transport = this host is not a mail destination.
# Any attempt to deliver locally fails loudly rather than filling /var/mail.
mydestination          =
local_transport        = error:5.1.1 Mailbox unavailable — this host is a null client
local_recipient_maps   =
alias_maps             = hash:/etc/aliases
alias_database         = hash:/etc/aliases
# Hard-disable the code-execution surface: a relay never pipes to a program.
allow_mail_to_commands =
allow_mail_to_files    =
default_privs          = nobody

# --- Relay -------------------------------------------------------------------
# Square brackets suppress the MX lookup: connect to this A/AAAA record directly.
relayhost              = [mail-relay.observability.svc.cluster.local]:587
# Never accept relaying from anyone: this host originates, it does not forward.
smtpd_relay_restrictions = permit_mynetworks, reject
smtpd_recipient_restrictions = permit_mynetworks, reject_unauth_destination, reject

# --- Outbound authentication -------------------------------------------------
smtp_sasl_auth_enable         = yes
smtp_sasl_password_maps       = hash:/etc/postfix/sasl_passwd
smtp_sasl_security_options    = noanonymous
smtp_sasl_tls_security_options = noanonymous
smtp_sender_dependent_authentication = no

# --- Outbound TLS: mandatory, verified. `may` is silent-downgrade bait. -------
smtp_tls_security_level       = verify
smtp_tls_mandatory_protocols  = >=TLSv1.2
smtp_tls_protocols            = >=TLSv1.2
smtp_tls_mandatory_ciphers    = high
smtp_tls_CAfile               = /etc/pki/tls/certs/ca-bundle.crt
smtp_tls_loglevel             = 1
smtp_tls_session_cache_database = btree:${data_directory}/smtp_scache

# --- Queue behaviour: alert mail must fail fast, not linger for days ----------
maximal_queue_lifetime = 4h
bounce_queue_lifetime  = 1h
delay_warning_time     = 15m
minimal_backoff_time   = 60s
maximal_backoff_time   = 900s
queue_run_delay        = 60s
# One concurrent connection to the relay is plenty for a single node and
# avoids tripping the relay's per-client concurrency limits.
default_destination_concurrency_limit = 2
smtp_connect_timeout   = 10s
smtp_helo_timeout      = 10s
smtp_data_done_timeout = 120s

# --- Size and hygiene --------------------------------------------------------
message_size_limit     = 20480000
mailbox_size_limit     = 0
biff                   = no
readme_directory       = no
html_directory         = no
compatibility_level    = 3.6
# Strip the internal hostname and local usernames from outbound headers.
smtp_header_checks     = regexp:/etc/postfix/header_checks_out
masquerade_domains     = $mydomain
masquerade_classes     = envelope_sender, header_sender
```

```
$ sudo cat /etc/postfix/header_checks_out
# Remove headers that leak internal topology to external recipients.
/^Received:.*edge-[0-9]+\.internal/    IGNORE
/^X-Originating-IP:/                   IGNORE
/^User-Agent:/                         IGNORE
```

```
$ sudo install -m 0600 /dev/stdin /etc/postfix/sasl_passwd <<'EOF'
[mail-relay.observability.svc.cluster.local]:587    edge-01:S3cr3tFromVault
EOF
$ sudo postmap hash:/etc/postfix/sasl_passwd
$ sudo chmod 0600 /etc/postfix/sasl_passwd /etc/postfix/sasl_passwd.db
$ ls -l /etc/postfix/sasl_passwd*
-rw-------. 1 root root    76 Aug 26 12:02 /etc/postfix/sasl_passwd
-rw-------. 1 root root 12288 Aug 26 12:02 /etc/postfix/sasl_passwd.db
```

El drop-in de systemd que hace al null client observable y auto-reparable:

```ini
# /etc/systemd/system/postfix.service.d/10-hardening.conf
[Unit]
# The relay lives in the cluster; do not start before the network is truly up.
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Restart=on-failure
RestartSec=5s
# Refuse to start on a broken config rather than starting half-deaf.
ExecStartPre=/usr/sbin/postfix check
ExecStartPre=/usr/sbin/postconf -e "myhostname=%H.internal.example.net"
# Filesystem hardening: Postfix needs root, so constrain what root can reach.
ProtectSystem=full
ProtectHome=read-only
PrivateTmp=true
NoNewPrivileges=false
ReadWritePaths=/var/spool/postfix /var/lib/postfix /etc/postfix
```

Un watchdog de profundidad de cola como timer — esta es la pieza que le falta a la mayoría de los parques:

```ini
# /etc/systemd/system/mailq-watch.service
[Unit]
Description=Alert when the local mail queue is not draining
After=postfix.service

[Service]
Type=oneshot
ExecStart=/usr/local/libexec/mailq-watch
```

```ini
# /etc/systemd/system/mailq-watch.timer
[Unit]
Description=Run the mail queue watchdog every 5 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min
AccuracySec=30s

[Install]
WantedBy=timers.target
```

```bash
#!/usr/bin/env bash
# /usr/local/libexec/mailq-watch — export queue depth for node_exporter textfile collector.
set -euo pipefail

OUT=/var/lib/node_exporter/textfile_collector/postfix_queue.prom
TMP="${OUT}.$$"

count_queue() {
    local q=$1
    find "/var/spool/postfix/${q}" -type f 2>/dev/null | wc -l
}

{
    echo '# HELP postfix_queue_length Number of messages per Postfix queue directory.'
    echo '# TYPE postfix_queue_length gauge'
    for q in maildrop incoming active deferred hold corrupt; do
        printf 'postfix_queue_length{queue="%s"} %d\n' "$q" "$(count_queue "$q")"
    done

    echo '# HELP postfix_aliases_db_stale 1 if /etc/aliases is newer than its database.'
    echo '# TYPE postfix_aliases_db_stale gauge'
    stale=0
    for db in /etc/aliases.db /etc/aliases.lmdb; do
        [ -e "$db" ] || continue
        [ /etc/aliases -nt "$db" ] && stale=1
    done
    printf 'postfix_aliases_db_stale %d\n' "$stale"

    echo '# HELP postfix_up 1 if the Postfix master process is running.'
    echo '# TYPE postfix_up gauge'
    if postfix status >/dev/null 2>&1; then echo 'postfix_up 1'; else echo 'postfix_up 0'; fi
} > "$TMP"

mv -f "$TMP" "$OUT"
```

### 6.2 Relay central en Kubernetes — conjunto completo de manifiestos

La contraparte de los null clients: un relay SMTP durable y observable para todo el clúster.

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: observability
  labels:
    kubernetes.io/metadata.name: observability
    pod-security.kubernetes.io/enforce: baseline
    # Postfix's master(8) must start as root to spawn its unprivileged
    # children under distinct UIDs; `restricted` is therefore not achievable
    # without a rootless rebuild. `baseline` + a tight capability set is the
    # honest trade-off, documented rather than silently worked around.
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: postfix-relay-config
  namespace: observability
data:
  main.cf: |
    # =========================================================================
    # Central SMTP relay — accepts from in-cluster null clients, authenticates
    # to the upstream provider, owns the only IP that appears in our SPF record.
    # =========================================================================
    compatibility_level    = 3.6
    queue_directory        = /var/spool/postfix
    command_directory      = /usr/sbin
    daemon_directory       = /usr/libexec/postfix
    data_directory         = /var/lib/postfix
    mail_owner             = postfix
    setgid_group           = postdrop

    # --- Identity ---------------------------------------------------------
    myhostname             = mail-relay.example.net
    mydomain               = example.net
    myorigin               = $mydomain
    append_dot_mydomain    = no

    # --- Listening: cluster-wide, on all interfaces inside the pod ---------
    inet_interfaces        = all
    inet_protocols         = ipv4
    # The cluster pod CIDR. Ingress is additionally constrained by
    # NetworkPolicy — defence in depth, because mynetworks alone is a
    # source-IP ACL and pod IPs are recycled.
    mynetworks             = 10.42.0.0/16 127.0.0.0/8

    # --- No local delivery: this is a relay, full stop ---------------------
    mydestination          =
    local_transport        = error:5.1.1 No local delivery on the relay
    local_recipient_maps   =
    alias_maps             = texthash:/etc/postfix/aliases
    # texthash is read into memory at process start and needs NO postalias
    # run and NO writable filesystem — the correct map type for a container
    # whose /etc/postfix is a read-only ConfigMap mount.
    alias_database         =
    allow_mail_to_commands =
    allow_mail_to_files    =

    # --- Relay policy: authenticated cluster senders only ------------------
    smtpd_relay_restrictions =
        permit_mynetworks,
        reject_unauth_destination
    smtpd_recipient_restrictions =
        permit_mynetworks,
        reject_unauth_destination,
        reject_non_fqdn_recipient,
        reject_unknown_recipient_domain,
        reject
    smtpd_client_restrictions   = permit_mynetworks, reject
    smtpd_helo_required         = yes
    smtpd_helo_restrictions     = permit_mynetworks, reject_invalid_helo_hostname
    smtpd_sender_restrictions   = permit_mynetworks, reject_non_fqdn_sender
    disable_vrfy_command        = yes
    smtpd_discard_ehlo_keywords = chunking

    # --- Rate limits: one runaway CronJob must not exhaust the provider ----
    smtpd_client_connection_count_limit    = 20
    smtpd_client_connection_rate_limit     = 60
    smtpd_client_message_rate_limit        = 300
    smtpd_error_sleep_time                 = 5s
    smtpd_soft_error_limit                 = 10
    smtpd_hard_error_limit                 = 20
    anvil_rate_time_unit                   = 60s

    # --- Upstream ---------------------------------------------------------
    relayhost                     = [smtp.provider.example]:587
    smtp_sasl_auth_enable         = yes
    smtp_sasl_password_maps       = texthash:/etc/postfix/sasl/sasl_passwd
    smtp_sasl_security_options    = noanonymous
    smtp_tls_security_level       = verify
    smtp_tls_mandatory_protocols  = >=TLSv1.2
    smtp_tls_CAfile               = /etc/ssl/certs/ca-certificates.crt
    smtp_tls_loglevel             = 1

    # --- Envelope hygiene: every message leaves as our domain -------------
    sender_canonical_maps    = texthash:/etc/postfix/sender_canonical
    sender_canonical_classes = envelope_sender
    smtp_header_checks       = regexp:/etc/postfix/header_checks_out

    # --- Queue: alerting SLO, not archival ---------------------------------
    maximal_queue_lifetime = 6h
    bounce_queue_lifetime  = 2h
    delay_warning_time     = 20m
    minimal_backoff_time   = 60s
    maximal_backoff_time   = 1200s
    queue_run_delay        = 60s
    default_destination_concurrency_limit = 10
    message_size_limit     = 26214400

    # --- Logging to stdout so kubectl logs / Loki see it -------------------
    maillog_file           = /dev/stdout
    maillog_file_permissions = 0644

  master.cf: |
    # service  type  private unpriv  chroot  wakeup  maxproc  command + args
    smtp       inet  n       -       n       -       -        smtpd
    pickup     unix  n       -       n       60      1        pickup
    cleanup    unix  n       -       n       -       0        cleanup
    qmgr       unix  n       -       n       300     1        qmgr
    tlsmgr     unix  -       -       n       1000?   1        tlsmgr
    rewrite    unix  -       -       n       -       -        trivial-rewrite
    bounce     unix  -       -       n       -       0        bounce
    defer      unix  -       -       n       -       0        bounce
    trace      unix  -       -       n       -       0        bounce
    verify     unix  -       -       n       -       1        verify
    flush      unix  n       -       n       1000?   0        flush
    proxymap   unix  -       -       n       -       -        proxymap
    proxywrite unix  -       -       n       -       1        proxymap
    smtp       unix  -       -       n       -       -        smtp
    relay      unix  -       -       n       -       -        smtp
    showq      unix  n       -       n       -       -        showq
    error      unix  -       -       n       -       -        error
    retry      unix  -       -       n       -       -        error
    discard    unix  -       -       n       -       -        discard
    anvil      unix  -       -       n       -       1        anvil
    scache     unix  -       -       n       -       1        scache
    postlog    unix-dgram n  -       n       -       1        postlogd

  aliases: |
    # texthash: no database, read at process start. `postfix reload` re-reads.
    postmaster:      sre-team@example.net
    mailer-daemon:   postmaster
    abuse:           security@example.net
    root:            sre-team@example.net

  sender_canonical: |
    # Everything leaving the cluster claims a single, SPF-authorised domain.
    /^root@.*/                      noreply@example.net
    /^alerts@.*\.internal$/         alerts@example.net
    /^cron@.*\.internal$/           cron-reports@example.net
    /^.*@.*\.svc\.cluster\.local$/  noreply@example.net

  header_checks_out: |
    /^Received:.*\.svc\.cluster\.local/   IGNORE
    /^Received:.*\[10\.42\./              IGNORE
    /^X-Originating-IP:/                 IGNORE
---
apiVersion: v1
kind: Secret
metadata:
  name: postfix-relay-sasl
  namespace: observability
type: Opaque
stringData:
  # Rendered by External Secrets Operator from Vault at kv/observability/smtp.
  # texthash reads this plain file directly — no postmap, no writable mount.
  sasl_passwd: |
    [smtp.provider.example]:587    apikey:REPLACED_BY_EXTERNAL_SECRETS
---
apiVersion: v1
kind: Service
metadata:
  name: mail-relay
  namespace: observability
  labels:
    app.kubernetes.io/name: postfix-relay
spec:
  type: ClusterIP
  # Headless is required for stable per-pod DNS so a null client can be
  # pinned to one relay pod and its queue for the duration of an incident.
  clusterIP: None
  selector:
    app.kubernetes.io/name: postfix-relay
  ports:
    - name: smtp
      port: 25
      targetPort: smtp
      protocol: TCP
    - name: metrics
      port: 9154
      targetPort: metrics
      protocol: TCP
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postfix-relay
  namespace: observability
  labels:
    app.kubernetes.io/name: postfix-relay
spec:
  serviceName: mail-relay
  replicas: 2
  podManagementPolicy: Parallel
  selector:
    matchLabels:
      app.kubernetes.io/name: postfix-relay
  template:
    metadata:
      labels:
        app.kubernetes.io/name: postfix-relay
      annotations:
        # Force a rollout when main.cf changes; Postfix does not watch files.
        checksum/config: "REPLACED_BY_HELM_SHA256SUM"
    spec:
      terminationGracePeriodSeconds: 120   # let the active queue drain
      securityContext:
        fsGroup: 89                        # postfix group; makes the PVC writable
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: postfix-relay
      containers:
        - name: postfix
          image: registry.example.net/platform/postfix:3.8.6-r2
          imagePullPolicy: IfNotPresent
          # start-fg (Postfix >= 3.0) runs master(8) in the foreground:
          # PID 1 semantics without a supervisor, correct SIGTERM handling.
          command: ["/usr/sbin/postfix", "start-fg"]
          lifecycle:
            preStop:
              exec:
                # Attempt one queue flush before the pod goes away, so the
                # deferred backlog is not stranded on a PVC nobody watches.
                command: ["/bin/sh", "-c", "postqueue -f; sleep 10"]
          ports:
            - name: smtp
              containerPort: 25
              protocol: TCP
          securityContext:
            # master(8) needs root to bind :25 and to fork children as the
            # postfix/nobody UIDs. Everything else is dropped.
            runAsUser: 0
            runAsNonRoot: false
            allowPrivilegeEscalation: true
            readOnlyRootFilesystem: false
            capabilities:
              drop: ["ALL"]
              add:
                - CHOWN            # postfix set-permissions on the queue
                - DAC_OVERRIDE     # queue file access across UIDs
                - FOWNER
                - SETGID           # spawn smtpd as postfix
                - SETUID
                - NET_BIND_SERVICE # bind TCP/25
                - KILL             # master reaping its children
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: "1"
              memory: 512Mi
          startupProbe:
            exec:
              command: ["/bin/sh", "-c", "postfix status"]
            initialDelaySeconds: 5
            periodSeconds: 5
            failureThreshold: 12
          livenessProbe:
            exec:
              command: ["/bin/sh", "-c", "postfix status"]
            periodSeconds: 30
            timeoutSeconds: 10
            failureThreshold: 3
          readinessProbe:
            # A real SMTP handshake, not a bare tcpSocket: master(8) can be
            # listening while smtpd is wedged, and tcpSocket cannot tell.
            exec:
              command:
                - /bin/sh
                - -c
                - "printf 'QUIT\\r\\n' | timeout 5 nc 127.0.0.1 25 | grep -q '^220 '"
            periodSeconds: 10
            timeoutSeconds: 6
            failureThreshold: 3
          volumeMounts:
            - name: config
              mountPath: /etc/postfix/main.cf
              subPath: main.cf
              readOnly: true
            - name: config
              mountPath: /etc/postfix/master.cf
              subPath: master.cf
              readOnly: true
            - name: config
              mountPath: /etc/postfix/aliases
              subPath: aliases
              readOnly: true
            - name: config
              mountPath: /etc/postfix/sender_canonical
              subPath: sender_canonical
              readOnly: true
            - name: config
              mountPath: /etc/postfix/header_checks_out
              subPath: header_checks_out
              readOnly: true
            - name: sasl
              mountPath: /etc/postfix/sasl
              readOnly: true
            - name: spool
              mountPath: /var/spool/postfix
            - name: lib
              mountPath: /var/lib/postfix

        - name: exporter
          image: registry.example.net/platform/postfix-exporter:0.4.0
          args:
            - --postfix.showq_path=/var/spool/postfix/public/showq
            - --web.listen-address=:9154
            - --systemd.enable=false
          ports:
            - name: metrics
              containerPort: 9154
          securityContext:
            runAsUser: 89                 # postfix uid: enough to read showq
            runAsNonRoot: true
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          resources:
            requests: {cpu: 10m, memory: 24Mi}
            limits:   {cpu: 100m, memory: 64Mi}
          volumeMounts:
            - name: spool
              mountPath: /var/spool/postfix
              readOnly: true

      volumes:
        - name: config
          configMap:
            name: postfix-relay-config
            defaultMode: 0644
        - name: sasl
          secret:
            secretName: postfix-relay-sasl
            defaultMode: 0600
        - name: lib
          emptyDir: {}

  volumeClaimTemplates:
    - metadata:
        name: spool
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: local-nvme
        resources:
          requests:
            storage: 5Gi
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: postfix-relay
  namespace: observability
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: postfix-relay
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: postfix-relay
  namespace: observability
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: postfix-relay
  policyTypes: [Ingress, Egress]
  ingress:
    # Only namespaces explicitly labelled as mail senders may submit.
    - from:
        - namespaceSelector:
            matchLabels:
              example.net/may-send-mail: "true"
      ports:
        - protocol: TCP
          port: 25
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: monitoring
      ports:
        - protocol: TCP
          port: 9154
  egress:
    # DNS
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - {protocol: UDP, port: 53}
        - {protocol: TCP, port: 53}
    # Upstream submission only. Note: NOT port 25 outbound — the relay
    # authenticates on 587 and never speaks to arbitrary MX hosts.
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except:
              - 10.0.0.0/8
              - 172.16.0.0/12
              - 192.168.0.0/16
              - 169.254.0.0/16
      ports:
        - {protocol: TCP, port: 587}
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: postfix-relay
  namespace: observability
  labels:
    release: kube-prometheus-stack
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: postfix-relay
  endpoints:
    - port: metrics
      interval: 30s
      scrapeTimeout: 10s
---
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: postfix-relay
  namespace: observability
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: mta.rules
      rules:
        - alert: PostfixDeferredQueueGrowing
          expr: postfix_showq_message_size_bytes_count{queue="deferred"} > 50
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "Postfix deferred queue on {{ $labels.pod }} above 50 messages"
            description: >-
              Mail is not leaving the cluster. Run `kubectl exec -n observability
              {{ $labels.pod }} -c postfix -- qshape deferred` to see which
              destination domain is failing.
            runbook_url: https://runbooks.example.net/mta/deferred-queue

        - alert: PostfixQueueStalled
          # Age of the oldest message, not its count: 5 messages stuck for an
          # hour is a worse signal than 500 that drain in 30 seconds.
          expr: postfix_showq_message_age_seconds{quantile="0.99"} > 1800
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "Oldest queued message on {{ $labels.pod }} exceeds 30 minutes"
            runbook_url: https://runbooks.example.net/mta/queue-stalled

        - alert: PostfixDown
          expr: up{job="postfix-relay"} == 0
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "Postfix relay {{ $labels.pod }} is not scraping"

        - alert: PostfixNoMailDelivered
          # The dead-man's switch: silence is the failure mode of an MTA.
          expr: rate(postfix_smtp_delivery_delay_seconds_count[30m]) == 0
          for: 1h
          labels:
            severity: warning
          annotations:
            summary: "No mail delivered by {{ $labels.pod }} in the last hour"
            description: >-
              Either genuinely no traffic, or the submission path is broken
              upstream. Verify with a synthetic probe before dismissing.
```

**Por qué `StatefulSet` y no `Deployment`** — esta es la decisión de diseño que vale la pena defender en una revisión:

| | Deployment + `emptyDir` | Deployment + PVC RWX compartido | **StatefulSet + PVC RWO por pod** |
|---|---|---|---|
| La cola diferida sobrevive al reinicio del pod | **no — se descarta en silencio** | sí | **sí** |
| Dos instancias de Postfix sobre un mismo spool | n/a | **corrupción: `qmgr` asume propiedad exclusiva** | nunca ocurre |
| DNS estable por pod para inspeccionar la cola de *este* pod | no | no | **sí** (`postfix-relay-0.mail-relay`) |
| Costo de almacenamiento | cero | un volumen | un volumen por réplica |
| Elección correcta | sólo si la pérdida de correo es aceptable y el alertado es idempotente | **nunca** | por defecto |

La opción RWX compartida es la trampa: `qmgr(8)` mantiene estado en memoria sobre `active/` y no toma ningún bloqueo entre hosts. Dos pods sobre un mismo spool NFS entregarán por duplicado y corromperán archivos de cola. La propia documentación de Postfix es explícita en que un directorio de cola pertenece a exactamente una instancia en ejecución.

### 6.3 Conectar Alertmanager al relay

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: alertmanager-config
  namespace: monitoring
stringData:
  alertmanager.yaml: |
    global:
      # The in-cluster relay. No auth needed: NetworkPolicy + mynetworks
      # already constrain who may submit.
      smtp_smarthost: 'mail-relay.observability.svc.cluster.local:25'
      smtp_from: 'alerts@example.net'
      smtp_require_tls: false
      resolve_timeout: 5m

    route:
      receiver: sre-email
      group_by: ['alertname', 'cluster', 'namespace']
      group_wait: 30s
      group_interval: 5m
      repeat_interval: 4h

    receivers:
      - name: sre-email
        email_configs:
          - to: 'oncall@example.net'
            send_resolved: true
            headers:
              Subject: '[{{ .Status | toUpper }}:{{ .Alerts.Firing | len }}] {{ .CommonLabels.alertname }}'
```

Fijate en `smtp_require_tls: false` en el salto *interno*: el tráfico nunca sale de la red del clúster, la NetworkPolicy restringe quién puede enviar, y el relay impone `smtp_tls_security_level = verify` en el salto que sí cruza internet. Terminar TLS dos veces dentro del mismo par veth del nodo no aporta nada y le agrega un modo de fallo por rotación de certificados a tu camino de paging.

---

## 7. Verificación y diagnóstico de fallos

### 7.1 La escalera de verificación — primero la prueba más barata

Ejecutá estas en orden. Cada peldaño aísla una capa; detenerte en el primer fallo te ahorra depurar la capa 5 cuando la rota es la capa 1.

```
$ # ── Rung 1: is an MTA installed, and which one? ────────────────────────────
$ readlink -f "$(command -v sendmail)"
/usr/sbin/sendmail.postfix

$ # ── Rung 2: is it running and listening? ───────────────────────────────────
$ systemctl is-active postfix && postfix status
active
postfix/postfix-script: the Postfix mail system is running: PID: 918

$ ss -lntp 'sport = :25'
State  Recv-Q Send-Q Local Address:Port Peer Address:Port Process
LISTEN 0      100        127.0.0.1:25        0.0.0.0:*     users:(("master",pid=918,fd=13))

$ # ── Rung 3: does the configuration parse? ──────────────────────────────────
$ sudo postfix check; echo "exit=$?"
exit=0

$ postconf -n | head -12
alias_database = hash:/etc/aliases
alias_maps = hash:/etc/aliases
allow_mail_to_commands =
allow_mail_to_files =
bounce_queue_lifetime = 1h
compatibility_level = 3.6
delay_warning_time = 15m
inet_interfaces = loopback-only
inet_protocols = ipv4
local_recipient_maps =
local_transport = error:5.1.1 Mailbox unavailable — this host is a null client
mail_owner = postfix

$ # ── Rung 4: is the alias database current? ─────────────────────────────────
$ [ /etc/aliases -nt /etc/aliases.db ] && echo "STALE — run newaliases" || echo "current"
current

$ # ── Rung 5: does alias expansion resolve as intended? ──────────────────────
$ postalias -q root hash:/etc/aliases
sre-oncall, \root
$ postalias -q sre-oncall hash:/etc/aliases
:include:/etc/mail/lists/sre-oncall

$ # ── Rung 6: what does the MTA itself think the address expands to? ─────────
$ sendmail -bv root
$ sleep 2 && sudo tail -3 /var/log/maillog
Aug 26 12:41:07 edge-01 postfix/cleanup[9912]: C41A31A1102: message-id=<20260826124107.C41A31A1102@edge-01.internal>
Aug 26 12:41:07 edge-01 postfix/qmgr[922]: C41A31A1102: from=<>, size=298, nrcpt=1 (queue active)
Aug 26 12:41:07 edge-01 postfix/verify[9915]: cache btree:/var/lib/postfix/verify full cleanup: retained=0 dropped=0 entries=0

$ # ── Rung 7: end-to-end, with the envelope sender set explicitly ────────────
$ printf 'Subject: mta smoke test %s\n\nsent from %s at %s\n' \
      "$(date +%s)" "$(hostname -f)" "$(date -Is)" \
  | sendmail -i -f "smoke@$(hostname -f)" oncall@example.net

$ # ── Rung 8: did it leave? ──────────────────────────────────────────────────
$ mailq
Mail queue is empty
$ sudo grep -E 'status=(sent|bounced|deferred)' /var/log/maillog | tail -1
Aug 26 12:41:33 edge-01 postfix/smtp[9931]: D18B41A1105: to=<oncall@example.net>,
  relay=mail-relay.observability.svc.cluster.local[10.43.7.19]:587, delay=0.42,
  delays=0.05/0.01/0.19/0.17, dsn=2.0.0, status=sent (250 2.0.0 Ok: queued as 4Wq2Xz1TzZz)
```

`status=sent` más un ID de cola remoto es la única prueba de entrega al siguiente salto. Un `mailq` vacío por sí solo no prueba nada — es igualmente consistente con "entregado" y con "rebotado y descartado".

### 7.2 Leer una línea de log de Postfix

Cada intento de entrega produce una línea cuyos campos son el diagnóstico completo:

```
Aug 26 12:41:33 edge-01 postfix/smtp[9931]: D18B41A1105: to=<oncall@example.net>,
  orig_to=<root@edge-01.internal>, relay=mail-relay[10.43.7.19]:587,
  conn_use=2, delay=0.42, delays=0.05/0.01/0.19/0.17, dsn=2.0.0,
  status=sent (250 2.0.0 Ok: queued as 4Wq2Xz1TzZz)
```

| Campo | Significado | Qué te dice |
|---|---|---|
| `postfix/smtp[9931]` | el **componente** | `smtp`=saliente, `smtpd`=entrante, `local`=entrega final/alias, `pipe`=comando de alias, `qmgr`=planificación, `cleanup`=reescritura |
| `D18B41A1105` | ID de cola | une todas las líneas de este mensaje: `grep <id> /var/log/maillog` |
| `to=` / `orig_to=` | destinatario final / original | **que `orig_to` difiera prueba que se disparó un alias o un `.forward`** |
| `relay=` | siguiente salto | `local` ⇒ MDA; `none` ⇒ nunca se conectó |
| `delay=0.42` | segundos totales | |
| `delays=a/b/c/d` | **antes de qmgr / en cola / conexión+HELO / datos+respuesta** | un 2.º campo grande = acumulación en cola; 3.º grande = red/DNS; 4.º grande = receptor lento |
| `dsn=2.0.0` | estado según RFC 3463 | `2.x.x` éxito, `4.x.x` **transitorio** (reintento), `5.x.x` **permanente** (rebote) |
| `status=` | resultado | `sent`, `deferred`, `bounced`, `expired` |
| `(...)` | respuesta literal del servidor remoto | **leé esto primero cuando no sea `sent`** |

Unir todas las líneas de un mensaje:

```
$ sudo grep D18B41A1105 /var/log/maillog
Aug 26 12:41:33 edge-01 postfix/pickup[921]: D18B41A1105: uid=0 from=<root>
Aug 26 12:41:33 edge-01 postfix/cleanup[9928]: D18B41A1105: message-id=<20260826124133.D18B41A1105@edge-01.internal>
Aug 26 12:41:33 edge-01 postfix/qmgr[922]: D18B41A1105: from=<root@edge-01.internal>, size=412, nrcpt=1 (queue active)
Aug 26 12:41:33 edge-01 postfix/smtp[9931]: D18B41A1105: to=<oncall@example.net>, orig_to=<root@edge-01.internal>, relay=mail-relay[10.43.7.19]:587, delay=0.42, delays=0.05/0.01/0.19/0.17, dsn=2.0.0, status=sent (250 2.0.0 Ok: queued as 4Wq2Xz1TzZz)
Aug 26 12:41:33 edge-01 postfix/qmgr[922]: D18B41A1105: removed
```

En hosts con systemd y logging sólo en journald:

```
$ sudo journalctl -u postfix --since '10 min ago' -o cat --no-pager
$ sudo journalctl -t postfix/smtp -f
$ kubectl logs -n observability postfix-relay-0 -c postfix -f | grep -E 'status=(deferred|bounced)'
```

### 7.3 Tabla de firmas de fallo

| Firma en log / terminal | Causa raíz | Comando que lo confirma | Arreglo |
|---|---|---|---|
| `warning: database /etc/aliases.db is older than source file /etc/aliases` | se editó la fuente de alias, no se reconstruyó la BD | `ls -l /etc/aliases*` | `newaliases` |
| `fatal: open database /etc/aliases.db: No such file or directory` | la BD nunca se construyó | `postconf alias_database` | `newaliases` |
| `status=deferred (alias database unavailable)` | `alias_maps` apunta a un mapa faltante o ilegible | `postalias -q root hash:/etc/aliases` | construila; revisá la etiqueta SELinux |
| Alias agregado pero nunca usado | está sólo en `alias_database`, no en `alias_maps` | `postconf alias_maps alias_database` | agregalo a **ambos**, `newaliases`, `postfix reload` |
| `status=bounced (User unknown in local recipient table)` | el destino del alias no es un usuario local y `local_recipient_maps` está definido | `getent passwd <target>` | creá el usuario, arreglá el alias, o vaciá `local_recipient_maps` |
| `.forward` ignorado, el correo cae en el mbox | permisos de `$HOME` o del archivo | `ls -ld ~ ~/.forward` | `chmod 700 ~; chmod 600 ~/.forward` |
| `SYSERR(root): forward /home/x/.forward: Group writable directory` | lo mismo, con sendmail siendo explícito | `ls -ld /home/x` | `chmod 700 /home/x` |
| `.forward` correcto y permisos correctos, y aun así ignorado | etiqueta SELinux, o root-squash de NFS | `ausearch -m AVC -ts recent`, `mount \| grep home` | `restorecon`; `no_root_squash` o `local(8)` corriendo como el destinatario |
| `status=bounced (mail forwarding loop for x@y)` | ciclo de alias/`.forward` | rastreá `postalias -q` recursivamente | insertá `\user` para terminar |
| `status=bounced (mail for X loops back to myself)` | el MX apunta acá, el dominio no está en `mydestination` | `dig +short MX X` vs `postconf mydestination` | agregalo a `mydestination`/`relay_domains`, o arreglá el DNS |
| `status=deferred (connect to X[IP]:25: Connection timed out)` | egress 25 bloqueado por la nube/el firewall | `nc -vz X 25` | relay vía 587 con autenticación |
| `status=deferred (connect to X[IP]:25: Connection refused)` | nada escuchando en el par | `ss -lntp` en el par | arrancá el MTA del par |
| `status=deferred (Host or domain name not found. Name service error ... type=MX)` | DNS roto o el dominio no tiene MX | `dig MX X`, `cat /etc/resolv.conf` | arreglá el resolver / agregá el MX |
| `status=deferred (Server certificate not verified)` | `smtp_tls_security_level = verify` y falta el bundle de CA o está desactualizado | `openssl s_client -starttls smtp -connect X:587` | instalá el bundle de CA; arreglá `smtp_tls_CAfile` |
| `554 5.7.1 Service unavailable; Client host blocked` | IP de origen en una lista de bloqueo | consultá la IP en la RBL nombrada | retransmitir por un emisor autorizado |
| `550 5.7.23 SPF validation failed` | reenvío sin SRS, o IP fuera del SPF | `dig +short TXT example.net \| grep spf` | agregá la IP del relay al SPF; activá SRS |
| `450 4.7.1 Client host rejected: cannot find your reverse hostname` | sin PTR para la IP de salida | `dig -x <egress-ip>` | poné el PTR en el hoster; o usá un relay |
| `postdrop: warning: unable to look up public/pickup: No such file or directory` | Postfix no está corriendo, o permisos de chroot/cola mal | `postfix status` | `postfix start`; `postfix set-permissions` |
| `maildrop/` creciendo, `incoming/` vacío | `pickup(8)` muerto o `pickup` deshabilitado en `master.cf` | `ps -ef \| grep pickup` | `postfix reload`; revisá `master.cf` |
| Todo `sent`, el destinatario no ve nada | entregado a un buzón *distinto* por un `.forward` que no sabías que existía | mirá `orig_to=` en el log | seguí la cadena |
| `mailq` vacío pero no llega correo, sin líneas de log | la app no está llamando a sendmail en absoluto | `strace -f -e trace=execve -p <pid>` | arreglá la app / `MAILTO` |

### 7.4 Transcripciones a nivel de red

**SMTP crudo contra el relay** — lee la lista de capacidades, que te dice qué va a aceptar el par:

```
$ telnet mail-relay.observability.svc.cluster.local 25
Trying 10.43.7.19...
Connected to mail-relay.observability.svc.cluster.local.
Escape character is '^]'.
220 mail-relay.example.net ESMTP Postfix
EHLO edge-01.internal.example.net
250-mail-relay.example.net
250-PIPELINING
250-SIZE 26214400
250-ETRN
250-STARTTLS
250-ENHANCEDSTATUSCODES
250-8BITMIME
250-DSN
250 SMTPUTF8
MAIL FROM:<smoke@edge-01.internal.example.net>
250 2.1.0 Ok
RCPT TO:<oncall@example.net>
250 2.1.5 Ok
DATA
354 End data with <CR><LF>.<CR><LF>
Subject: manual smtp probe
From: smoke@edge-01.internal.example.net
To: oncall@example.net

This message was injected by hand to prove the relay accepts submissions.
.
250 2.0.0 Ok: queued as 7Kj2Lm4NpQ
QUIT
221 2.0.0 Bye
Connection closed by foreign host.
```

Fijate en la **ausencia de `250-AUTH`**: este relay no ofrece SASL porque autoriza por red, exactamente como especifica `smtpd_relay_restrictions = permit_mynetworks, reject`. Si *esperás* `AUTH` y no está, la causa habitual es que `smtpd_tls_auth_only = yes` y todavía no emitiste `STARTTLS` — el servidor oculta `AUTH` hasta que el canal esté cifrado.

**Verificación de TLS contra el proveedor upstream:**

```
$ openssl s_client -starttls smtp -crlf -connect smtp.provider.example:587 \
      -servername smtp.provider.example 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates
subject=CN=smtp.provider.example
issuer=C=US, O=Let's Encrypt, CN=R11
notBefore=Aug  1 04:12:07 2026 GMT
notAfter=Oct 30 04:12:06 2026 GMT
```

```
$ openssl s_client -starttls smtp -crlf -connect smtp.provider.example:587 \
      -servername smtp.provider.example </dev/null 2>&1 \
  | grep -E 'Verify return code|Protocol|Cipher'
Protocol  : TLSv1.3
Cipher    : TLS_AES_256_GCM_SHA384
Verify return code: 0 (ok)
```

`Verify return code: 0 (ok)` es lo que exige `smtp_tls_security_level = verify`. Cualquier otra cosa y todos los mensajes se van a diferir con `Server certificate not verified` — un modo de fallo que se presenta como "el correo dejó de andar una mañana" cuando rotó una CA intermedia.

**MX y SPF desde el host emisor — resolvé siempre desde el host que va a enviar:**

```
$ dig +short MX example.net
10 mx1.example.net.
20 mx2.example.net.
$ dig +short A mx1.example.net
203.0.113.25
$ dig +short -x 198.51.100.7
mail-relay.example.net.
$ dig +short TXT example.net | tr -d '"' | grep -i spf
v=spf1 ip4:198.51.100.7 include:_spf.provider.example -all
$ dig +short TXT _dmarc.example.net | tr -d '"'
v=DMARC1; p=quarantine; rua=mailto:dmarc@example.net; pct=100
```

Tres cosas deben coincidir: el PTR de tu IP de salida, el `myhostname` que enviás en el `EHLO`, y la entrada `ip4:` del SPF. Cualquier desacuerdo produce rechazos intermitentes y dependientes del receptor — la clase de bug de correo más difícil, porque funciona contra tu destinatario de prueba y falla contra el del cliente.

### 7.5 Modo de prueba de direcciones (sendmail y Exim)

Ambos ofrecen un rastreo interactivo del conjunto de reglas, que es la forma más rápida de responder "¿a dónde iría realmente esta dirección?" sin enviar nada.

**sendmail** — el ruleset `3,0` es canonicalización más selección de mailer:

```
$ sudo /usr/sbin/sendmail -bt
ADDRESS TEST MODE (ruleset 3 NOT automatically invoked)
Enter <ruleset> <address>
> 3,0 oncall@example.net
canonify           input: oncall @ example . net
Canonify2          input: oncall < @ example . net >
Canonify2        returns: oncall < @ example . net . >
canonify         returns: oncall < @ example . net . >
parse              input: oncall < @ example . net . >
Parse0             input: oncall < @ example . net . >
Parse0           returns: oncall < @ example . net . >
ParseLocal         input: oncall < @ example . net . >
ParseLocal       returns: oncall < @ example . net . >
Parse1             input: oncall < @ example . net . >
Parse1           returns: $# esmtp $@ example . net . $: oncall < @ example . net . >
parse            returns: $# esmtp $@ example . net . $: oncall < @ example . net . >
> /quit
```

`$# esmtp` es el mailer seleccionado; `$@ example.net.` es el host al que se lo va a entregar. Si esperabas `$# local`, la dirección no está siendo tratada como local y ningún alias se va a disparar para ella.

**Exim** — `-bt` reproduce la cadena de routers e imprime el ganador:

```
$ exim -bt root
root@edge-01.internal
  <-- root@edge-01.internal
  router = system_aliases, transport = remote_smtp
  host mail-relay.observability.svc.cluster.local [10.43.7.19]

$ exim -bt sre@edge-01.internal
sre@edge-01.internal
  <-- sre@edge-01.internal
  router = userforward, transport = remote_smtp
  sre-team@example.net

$ exim -bV
Exim version 4.96 #2 built 26-Aug-2026 08:11:02
Copyright (c) University of Cambridge, 1995 - 2018
...
Configuration file is /var/lib/exim4/config.autogenerated
```

`exim -bV` parsea la configuración e informa errores de sintaxis — el equivalente en Exim de `postfix check`, y la compuerta correcta antes de reiniciar en Debian.

### 7.6 La sonda sintética — el único monitor honesto de un MTA

La profundidad de la cola es un indicador rezagado: un relay que descarta correo en silencio tiene la cola vacía. El interruptor de hombre muerto es un mensaje enviado según una programación a una dirección cuya llegada se monitorea a su vez.

```bash
#!/usr/bin/env bash
# /usr/local/libexec/mail-canary — inject one traceable message per interval.
set -euo pipefail

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
HOST="$(hostname -f)"
TARGET="${MAIL_CANARY_TARGET:?set MAIL_CANARY_TARGET}"

/usr/sbin/sendmail -i -f "canary@${HOST}" "$TARGET" <<EOF
Subject: mail-canary ${HOST} ${STAMP}
From: canary@${HOST}
To: ${TARGET}
X-Mail-Canary-Host: ${HOST}
X-Mail-Canary-Stamp: ${STAMP}

Automated liveness probe. If this stops arriving, the mail path is broken
even though every queue on every host may look empty.
EOF

logger -t mail-canary "injected ${STAMP} for ${TARGET}"
```

El lado receptor (un buzón consultado por un pequeño consumidor, o un webhook del proveedor) exporta `mail_canary_last_seen_timestamp_seconds`, y la alerta es `time() - mail_canary_last_seen_timestamp_seconds > 3600`. Esta es la única comprobación que cubre toda la cadena — el shim de sendmail, los alias, la cola, el relay, TLS, SPF y el proveedor — y es la que atrapa el modo de fallo que ninguna otra atrapa: correo que es aceptado y luego descartado en silencio.

---

## 8. Referencia rápida orientada al examen

### 8.1 Los comandos que aparecen en el examen

| Comando | Efecto |
|---|---|
| `newaliases` | reconstruir la base de datos de alias desde `/etc/aliases`; idéntico a `sendmail -bi` |
| `sendmail -bi` | lo mismo |
| `postalias /etc/aliases` | construcción nativa de Postfix de la base de datos de alias |
| `postalias -q <key> hash:/etc/aliases` | consultar un solo alias |
| `mailq` | imprimir la cola de correo; idéntico a `sendmail -bp` |
| `sendmail -bp` | lo mismo |
| `postqueue -p` | listado de la cola nativo de Postfix |
| `postqueue -f` | vaciar la cola de diferidos |
| `postsuper -d <id>` / `-d ALL` | borrar mensaje(s) encolado(s) |
| `postsuper -r ALL` | reencolar todo (reaplica los alias) |
| `exim -bp` / `-bpc` / `-M <id>` / `-Mrm <id>` | Exim: listar / contar / forzar / eliminar |
| `qmail-qstat`, `qmail-qread` | estado y listado de la cola de qmail |
| `mail -s "subject" user@host` | enviar desde stdin |
| `mail` (sin argumentos) | leer `/var/mail/$USER` |
| `sendmail -t < file` | enviar, tomando los destinatarios de las cabeceras |
| `sendmail -f addr recipient` | enviar con un remitente de sobre explícito |
| `sendmail -bv addr` | expandir/verificar una dirección sin entregar |
| `postconf -n` | mostrar los ajustes no predeterminados de Postfix |
| `postconf -d <param>` | mostrar un valor por defecto interno |
| `postconf -e 'p = v'` | editar `main.cf` de forma segura |
| `postfix check` / `reload` / `start` / `stop` / `status` | ciclo de vida de Postfix |
| `postcat -q <id>` | volcar un mensaje encolado |
| `alternatives --config mta` | cambiar el MTA en la familia Red Hat |

### 8.2 Enviar y leer con `mail(1)`

```
$ echo "disk 92% on /var" | mail -s "edge-01 disk pressure" oncall@example.net

$ mail -s "report" -r "reports@example.net" sre-team@example.net < /tmp/report.txt

$ printf 'Subject: nightly\nTo: sre@example.net\n\nbody line\n' | sendmail -t -i
```

Leer un buzón local:

```
$ mail
"/var/mail/sre": 2 messages 2 new
>N  1 root@edge-01.inter  Wed Aug 26 09:14   18/612   "Cron <root@edge-01> /usr/local/bin/backup"
 N  2 root@edge-01.inter  Wed Aug 26 11:02   22/748   "smartd: Device: /dev/sda [SAT]"
& 1
Message 1:
From root@edge-01.internal  Wed Aug 26 09:14:02 2026
Subject: Cron <root@edge-01> /usr/local/bin/backup
...
& d 1
& q
Held 1 message in /var/mail/sre
```

Comandos del prompt `&`: `<n>` leer, `d <n>` borrar, `s <n> file` guardar, `r` responder, `h` cabeceras, `q` salir (aplica los borrados), `x` salir (descarta los borrados). `-a` significa "adjuntar un archivo" en el `mailx` de BSD y en `s-nail`, pero GNU mailutils usa `-A` para adjuntos y `-a` para agregar una cabecera — **verificá qué implementación está instalada antes de scriptear `-a`**:

```
$ readlink -f "$(command -v mail)"
/usr/bin/s-nail
$ dpkg -S "$(readlink -f "$(command -v mail)")" 2>/dev/null || rpm -qf "$(readlink -f "$(command -v mail)")"
s-nail: /usr/bin/s-nail
```

### 8.3 Trampas que atrapan a ingenieros con experiencia

1. **Editar `/etc/aliases` sin ejecutar `newaliases`.** El MDA lee `/etc/aliases.db`, nunca el archivo de texto. Exim es la excepción — lee el texto directamente, que es exactamente por qué el hábito no se transfiere entre Debian y RHEL.
2. **Creer que hace falta un `postfix reload` después de `newaliases`.** No hace falta — la base de datos se abre en cada entrega. Un reload *sí* hace falta después de editar `main.cf`.
3. **Poner `@dominio` a la izquierda en `/etc/aliases`.** Los alias se indexan sólo por la parte local. La reescritura calificada por dominio es `virtual_alias_maps` / `virtusertable`.
4. **Suponer que un alias afecta al correo retransmitido.** Los alias se disparan sólo en la entrega final *local*. Un null client con `mydestination =` nunca expande `/etc/aliases` para nada, por más correcto que esté.
5. **Confundir `alias_maps` con `alias_database`.** Ver §3.3 — definí ambos.
6. **`.forward` ignorado porque `$HOME` es escribible por el grupo.** Revisá el *directorio*, no sólo el archivo.
7. **Omitir `\user` cuando un `.forward` también guarda una copia local.** `sre: sre, remote@x` es un bucle infinito; `sre: \sre, remote@x` es lo correcto.
8. **Copiar `/etc/aliases.db` entre hosts.** El formato de Berkeley DB/LMDB no es portable entre arquitecturas ni versiones de biblioteca. Transportá el texto y reconstruí.
9. **Confundir el remitente de sobre con la cabecera `From:`.** Los rebotes van al remitente de *sobre* (`sendmail -f`, `MAIL FROM`). `From:` es sólo texto de visualización.
10. **`mailq` vacío ⇒ todo está bien.** Vacío es también como se ve un mensaje descartado, rebotado, o nunca enviado. Confirmá con `status=sent` en el log o con una sonda sintética.
11. **qmail no lee `~/.forward`.** Lee `~/.qmail`.
12. **`rm` sobre `/var/spool/mqueue` o `/var/spool/postfix/*`.** Usá `postsuper -d` / `exim -Mrm`. Eliminar un archivo `df` sin su `qf` deja una entrada de cola permanentemente rota.

---

## 9. Referencias

**Objetivos oficiales de LPI**

* Objetivos del Examen 102 de LPIC-1 (102-500), incluido 108.3 *Mail Transfer Agent (MTA) basics* — https://www.lpi.org/our-certifications/exam-102-objectives/
* Objetivos del Examen 101 de LPIC-1 (101-500) — https://www.lpi.org/our-certifications/exam-101-objectives/
* Descripción general de la certificación LPIC-1 — https://www.lpi.org/our-certifications/lpic-1-overview/

**Postfix**

* Índice de la documentación de Postfix — https://www.postfix.org/documentation.html
* `aliases(5)` — https://www.postfix.org/aliases.5.html
* `local(8)` (procesamiento de alias y `~/.forward`) — https://www.postfix.org/local.8.html
* `postalias(1)` — https://www.postfix.org/postalias.1.html
* `postqueue(1)` — https://www.postfix.org/postqueue.1.html
* `postsuper(1)` — https://www.postfix.org/postsuper.1.html
* `postcat(1)` — https://www.postfix.org/postcat.1.html
* `postconf(5)` — referencia de parámetros — https://www.postfix.org/postconf.5.html
* Interfaz de compatibilidad `sendmail(1)` — https://www.postfix.org/sendmail.1.html
* Arquitectura `master(5)` / `master(8)` — https://www.postfix.org/master.5.html
* QSHAPE_README — diagnóstico de la cola — https://www.postfix.org/QSHAPE_README.html
* STANDARD_CONFIGURATION_README — perfiles de null client y satélite — https://www.postfix.org/STANDARD_CONFIGURATION_README.html
* TLS_README — https://www.postfix.org/TLS_README.html
* SASL_README — https://www.postfix.org/SASL_README.html
* DATABASE_README — tipos de mapa (`hash`, `lmdb`, `texthash`, `cdb`) — https://www.postfix.org/DATABASE_README.html
* Panorama de la arquitectura de Postfix — https://www.postfix.org/OVERVIEW.html

**Sendmail**

* Proyecto Sendmail — https://www.sendmail.org/
* Sendmail Operations Guide (`doc/op/op.me`) — https://www.sendmail.org/documentation
* Shell restringida `smrsh(8)` — https://www.sendmail.org/~ca/email/doc8.12/op-sh-4.html

**Exim**

* Documentación de Exim — https://www.exim.org/docs.html
* Especificación de Exim, capítulo sobre routers (`redirect`, `system_aliases`, `userforward`) — https://www.exim.org/exim-html-current/doc/html/spec_html/ch-the_redirect_router.html
* Opciones de línea de comandos de Exim (`-bp`, `-bt`, `-bV`, `-M`) — https://www.exim.org/exim-html-current/doc/html/spec_html/ch-the_exim_command_line.html
* Configuración de Exim4 en Debian — https://wiki.debian.org/Exim

**qmail**

* Página principal de qmail (D. J. Bernstein) — https://cr.yp.to/qmail.html
* `dot-qmail(5)` — https://cr.yp.to/qmail/man/dot-qmail.5.html
* `qmail-qstat(8)` / `qmail-qread(8)` — https://cr.yp.to/qmail/man/qmail-qread.8.html
* Especificación de Maildir — https://cr.yp.to/proto/maildir.html
* netqmail — https://www.qmail.org/

**Estándares**

* RFC 5321 — Simple Mail Transfer Protocol — https://www.rfc-editor.org/rfc/rfc5321
* RFC 5322 — Internet Message Format — https://www.rfc-editor.org/rfc/rfc5322
* RFC 5598 — Internet Mail Architecture (el modelo MUA/MSA/MTA/MDA/MRA) — https://www.rfc-editor.org/rfc/rfc5598
* RFC 6409 — Message Submission for Mail (puerto 587) — https://www.rfc-editor.org/rfc/rfc6409
* RFC 8314 — Cleartext Considered Obsolete: TLS para envío y acceso — https://www.rfc-editor.org/rfc/rfc8314
* RFC 3463 — Enhanced Mail System Status Codes (`dsn=x.y.z`) — https://www.rfc-editor.org/rfc/rfc3463
* RFC 3464 — Delivery Status Notifications — https://www.rfc-editor.org/rfc/rfc3464
* RFC 2142 — Nombres de buzón para servicios comunes (`postmaster`, `abuse`, `security`) — https://www.rfc-editor.org/rfc/rfc2142
* RFC 7208 — Sender Policy Framework (SPF) — https://www.rfc-editor.org/rfc/rfc7208
* RFC 6376 — DomainKeys Identified Mail (DKIM) — https://www.rfc-editor.org/rfc/rfc6376
* RFC 7489 — DMARC — https://www.rfc-editor.org/rfc/rfc7489

**Documentación de distribuciones**

* Red Hat Enterprise Linux 9 — *Deploying mail transport agents* — https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/deploying_different_types_of_servers/deploying-mail-transport-agent_deploying-different-types-of-servers
* `update-alternatives(1)` de Debian — https://manpages.debian.org/stable/dpkg/update-alternatives.1.en.html
* Debian Policy §11.6, agentes de transporte de correo — https://www.debian.org/doc/debian-policy/ch-customized-programs.html#mail-transport-delivery-and-user-agents

**Herramientas operativas referenciadas**

* Configuración del receptor de correo electrónico de Prometheus Alertmanager — https://prometheus.io/docs/alerting/latest/configuration/#email_config
* Kubernetes StatefulSet — https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/
* Kubernetes NetworkPolicy — https://kubernetes.io/docs/concepts/services-networking/network-policies/
* Kubernetes Pod Security Standards — https://kubernetes.io/docs/concepts/security/pod-security-standards/