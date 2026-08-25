# 332.2 — Host Intrusion Detection · Ejercicios guiados

> **Peso en el examen:** 8.33 · **Examen:** 303-300 v3.0.0
> **Objetivos oficiales:** <https://www.lpi.org/our-certifications/exam-303-objectives/>

---

## Entorno de laboratorio

Todo lo que sigue se ejecuta como `root` en una **VM descartable con snapshot previo**. Varios ejercicios modifican reglas del kernel, dejan artefactos setuid y activan modos de fallo que pueden dejar el sistema inoperable si se copian a producción sin entenderlos.

| Requisito | Debian 12 / Ubuntu 24.04 | RHEL 9 / Rocky 9 |
|---|---|---|
| Audit | `apt install auditd audispd-plugins` | `dnf install audit` |
| AIDE | `apt install aide aide-common` | `dnf install aide` |
| rkhunter | `apt install rkhunter` | EPEL: `dnf install rkhunter` |
| chkrootkit | `apt install chkrootkit` | EPEL: `dnf install chkrootkit` |
| ClamAV (motor para LMD) | `apt install clamav clamav-daemon` | EPEL: `dnf install clamav` |
| OpenSCAP | `apt install openscap-scanner` | `dnf install openscap-scanner scap-security-guide` |
| LMD (maldet) | instalación manual desde rfxn.com (Ej. 8) | ídem |

Verificá la versión de cada herramienta antes de empezar: la sintaxis de AIDE cambió entre 0.16 y 0.17, y la de auditd entre 2.x y 3.x.

```bash
auditctl -v ; aide -v 2>&1 | head -1 ; rkhunter --version | head -1 ; oscap -V | head -2
```

```
auditctl version 3.1.2
Aide 0.17.4
Rootkit Hunter 1.4.6
OpenSCAP command line tool (oscap) 1.3.10
```

---

## Ejercicio 1 — Arquitectura del subsistema de auditoría del kernel

El Linux Audit System **no es un demonio que espía**: es un subsistema del kernel que emite registros por un socket **netlink** de la familia `NETLINK_AUDIT`. El hilo del kernel `kauditd` los entrega al único proceso userspace registrado (normalmente `auditd`). Si no hay nadie registrado, los eventos van a `printk` (o se pierden). Entender esta cadena es la diferencia entre configurar auditd y diagnosticarlo.

### Pasos

1. Confirmá que el kernel se compiló con soporte de auditoría y con auditoría de syscalls:

   ```bash
   grep -E 'CONFIG_AUDIT(SYSCALL)?=' /boot/config-$(uname -r)
   ```

   ```
   CONFIG_AUDIT=y
   CONFIG_AUDITSYSCALL=y
   ```

2. Identificá el hilo del kernel y el proceso userspace:

   ```bash
   ps -eo pid,comm | grep -E 'kauditd|auditd'
   ```

   ```
       78 kauditd
      812 auditd
   ```

3. Consultá el estado del subsistema (esto lo responde el **kernel**, no el demonio):

   ```bash
   auditctl -s
   ```

   ```
   enabled 1
   failure 1
   pid 812
   rate_limit 0
   backlog_limit 8192
   lost 0
   backlog 0
   backlog_wait_time 60000
   backlog_wait_time_actual 0
   loginuid_immutable 0 unlocked
   ```

4. Revisá si la auditoría está habilitada desde el arranque:

   ```bash
   cat /proc/cmdline
   ```

   ```
   BOOT_IMAGE=/vmlinuz-6.1.0-18-amd64 root=/dev/mapper/vg0-root ro quiet
   ```

5. Habilitala desde el arranque y ampliá la cola. En GRUB2:

   ```bash
   # /etc/default/grub
   GRUB_CMDLINE_LINUX="audit=1 audit_backlog_limit=8192"
   ```

   ```bash
   grub2-mkconfig -o /boot/grub2/grub.cfg   # RHEL
   update-grub                              # Debian
   ```

6. Probá los modos de fallo y de cola **sin reiniciar** (efímero):

   ```bash
   auditctl -f 1          # 0=silencioso 1=printk 2=panic
   auditctl -b 16384      # backlog_limit
   auditctl --backlog_wait_time 0
   auditctl -s | grep -E 'failure|backlog_limit|backlog_wait_time '
   ```

   ```
   failure 1
   backlog_limit 16384
   backlog_wait_time 0
   ```

7. Intentá detener el demonio con systemd:

   ```bash
   systemctl stop auditd
   ```

   En RHEL 9:

   ```
   Failed to stop auditd.service: Operation refused, unit auditd.service may be requested by dependency only (it is configured to refuse manual start/stop).
   ```

   ```bash
   service auditd stop      # usa /usr/libexec/initscripts/legacy-actions/auditd/
   service auditd start
   ```

### Preguntas de verificación

**1.1** ¿Qué diferencia hay entre `enabled 1` y `enabled 2` en la salida de `auditctl -s`, y cómo se sale de `enabled 2`?
**1.2** El contador `lost` sube constantemente y `backlog` está pegado al límite. Enumerá tres causas plausibles y la métrica que distingue cada una.
**1.3** ¿Por qué `failure 2` puede ser un requisito de cumplimiento y a la vez un vector de denegación de servicio?
**1.4** ¿Qué se pierde exactamente si **no** se pasa `audit=1` en la línea de comandos del kernel?
**1.5** ¿Por qué RHEL configura `RefuseManualStop=yes` en `auditd.service`?

---

## Ejercicio 2 — Reglas: control, sistema de archivos y llamadas al sistema

Hay tres clases de reglas: **de control** (`-b`, `-f`, `-e`, `-r`), **de sistema de archivos** (`-w`, los *watches*) y **de syscall** (`-a lista,acción`). Las dos últimas se compilan a la misma estructura en el kernel: un *watch* es azúcar sintáctico sobre una regla de la lista `exit`.

### Pasos

1. Partí de un estado limpio y mirá qué hay cargado:

   ```bash
   auditctl -D
   auditctl -l
   ```

   ```
   No rules
   ```

2. Cargá un *watch* sobre los archivos de identidad:

   ```bash
   auditctl -w /etc/passwd -p wa -k identity
   auditctl -w /etc/shadow -p wa -k identity
   auditctl -w /etc/sudoers -p wa -k scope
   auditctl -w /etc/sudoers.d/ -p wa -k scope
   auditctl -l
   ```

   ```
   -w /etc/passwd -p wa -k identity
   -w /etc/shadow -p wa -k identity
   -w /etc/sudoers -p wa -k scope
   -w /etc/sudoers.d -p wa -k scope
   ```

3. Comprobá la equivalencia exacta entre un *watch* y una regla de syscall:

   ```bash
   auditctl -D
   auditctl -a always,exit -F path=/etc/passwd -F perm=wa -F key=identity
   auditctl -l
   ```

   ```
   -w /etc/passwd -p wa -k identity
   ```

4. Reglas de ejecución por usuario real, en **ambas** arquitecturas:

   ```bash
   auditctl -a always,exit -F arch=b64 -S execve,execveat -F auid>=1000 -F auid!=unset -k exec-user
   auditctl -a always,exit -F arch=b32 -S execve,execveat -F auid>=1000 -F auid!=unset -k exec-user
   ```

5. Detección de escalada: uso exitoso de binarios setuid por usuarios no privilegiados.

   ```bash
   auditctl -a always,exit -F arch=b64 -S execve -C uid!=euid -F euid=0 -k setuid-exec
   ```

6. Reducción de ruido con el filtro `exclude` y con `never`. **El orden importa: gana la primera coincidencia.**

   ```bash
   auditctl -a always,exclude -F msgtype=CWD
   auditctl -A never,exit -F arch=b64 -S execve -F exe=/usr/bin/prometheus-node-exporter
   auditctl -l | head -3
   ```

7. Hacé las reglas persistentes. `augenrules` concatena `/etc/audit/rules.d/*.rules` en orden ASCII y produce `/etc/audit/audit.rules`:

   ```bash
   cat > /etc/audit/rules.d/10-base.rules <<'EOF'
   ## Estado inicial
   -D
   -b 8192
   -f 1
   --backlog_wait_time 60000
   EOF

   cat > /etc/audit/rules.d/30-identity.rules <<'EOF'
   -w /etc/passwd  -p wa -k identity
   -w /etc/group   -p wa -k identity
   -w /etc/shadow  -p wa -k identity
   -w /etc/gshadow -p wa -k identity
   -w /etc/sudoers -p wa -k scope
   -w /etc/sudoers.d -p wa -k scope
   -a always,exit -F arch=b64 -S execve -C uid!=euid -F euid=0 -k setuid-exec
   -w /var/log/audit/ -p wra -k auditlog
   -w /etc/audit/ -p wa -k auditconfig
   EOF

   cat > /etc/audit/rules.d/99-finalize.rules <<'EOF'
   -e 2
   EOF

   augenrules --load
   ```

   ```
   No rules
   enabled 2
   failure 1
   pid 812
   rate_limit 0
   backlog_limit 8192
   lost 0
   backlog 4
   ```

8. Confirmá que quedaron inmutables:

   ```bash
   auditctl -D
   ```

   ```
   Error - nothing to do, no rules to delete
   ```

   o, si había reglas:

   ```
   Error deleting rule (Operation not permitted)
   ```

9. Generá un evento y comprobá que la regla dispara:

   ```bash
   touch /etc/passwd
   ausearch -k identity -i --start recent | head -20
   ```

### Preguntas de verificación

**2.1** ¿Por qué hay que declarar la misma regla de `execve` para `arch=b64` y `arch=b32`? ¿Qué pasa si se omite `b32` en un x86_64?
**2.2** ¿Qué diferencia hay entre `-a` y `-A`, y por qué es determinante para una regla `never`?
**2.3** El archivo watcheado con `-w /etc/passwd` es reemplazado por `usermod` (crea `/etc/passwd.new` y hace `rename`). ¿La regla sigue vigente sobre el archivo nuevo? Justificá con el mecanismo del kernel.
**2.4** ¿Se puede crear un *watch* sobre `/opt/app/config.yml` si ese archivo todavía no existe? ¿Y si `/opt/app` no existe?
**2.5** Excluir `msgtype=CWD` reduce el volumen del log de forma notable. ¿Qué capacidad forense se pierde?
**2.6** ¿Qué significa `-F auid!=unset` y por qué en audit 2.6 o anterior se escribía `-F auid!=4294967295`?
**2.7** El archivo `99-finalize.rules` contiene `-e 2`. ¿Por qué el nombre empieza con `99` y no con `10`?

---

## Ejercicio 3 — Lectura de eventos: `ausearch` y `aureport`

Un evento de auditoría **no es una línea**: es un conjunto de registros que comparten un par `(timestamp, serial)`. `ausearch` reagrupa esos registros; `grep` sobre `audit.log` los corta al medio.

### Pasos

1. Generá un evento con contexto rico:

   ```bash
   useradd -m -s /bin/bash pruebas
   ```

2. Recuperalo por clave, interpretado:

   ```bash
   ausearch -k identity -i --start today | head -40
   ```

   ```
   ----
   type=PROCTITLE msg=audit(08/24/2026 11:04:12.771:1873) : proctitle=useradd -m -s /bin/bash pruebas
   type=PATH msg=audit(08/24/2026 11:04:12.771:1873) : item=1 name=/etc/passwd inode=1835032 dev=fd:00 mode=file,644 ouid=root ogid=root rdev=00:00 nametype=NORMAL
   type=PATH msg=audit(08/24/2026 11:04:12.771:1873) : item=0 name=/etc/ inode=1835009 dev=fd:00 mode=dir,755 ouid=root ogid=root rdev=00:00 nametype=PARENT
   type=CWD msg=audit(08/24/2026 11:04:12.771:1873) : cwd=/root
   type=SYSCALL msg=audit(08/24/2026 11:04:12.771:1873) : arch=x86_64 syscall=openat success=yes exit=5 a0=0xffffff9c a1=0x561b2c0f21a0 a2=O_WRONLY|O_CREAT|O_TRUNC a3=0x180 items=2 ppid=1123 pid=2011 auid=sysadmin uid=root gid=root euid=root suid=root fsuid=root egid=root sgid=root fsgid=root tty=pts0 ses=3 comm=useradd exe=/usr/sbin/useradd key=identity
   ```

3. Distinguí `auid` de `uid`:

   ```bash
   ausearch -k identity --start today --format csv | cut -d, -f1,4,7,9 | head -5
   ```

4. Filtros habituales:

   ```bash
   ausearch -m USER_LOGIN -sv no --start today        # logins fallidos
   ausearch -ua 1000 --start today -i | tail -30       # todo lo hecho por auid 1000
   ausearch -ts 08/24/2026 09:00:00 -te 08/24/2026 10:00:00 -k exec-user -i
   ausearch -x /usr/bin/passwd -i
   ausearch -f /etc/shadow -i
   ausearch -p 2011 -i
   ```

5. Reportes agregados:

   ```bash
   aureport --start today --summary
   ```

   ```
   Summary Report
   ======================
   Range of time in logs: 08/24/2026 00:00:01.002 - 08/24/2026 11:31:02.117
   Selected time for report: 08/24/2026 00:00:00 - 08/24/2026 11:31:02.117
   Number of changes in configuration: 12
   Number of changes to accounts, groups, or roles: 4
   Number of logins: 6
   Number of failed logins: 2
   Number of authentications: 9
   Number of failed authentications: 3
   Number of users: 3
   Number of terminals: 5
   Number of host names: 2
   Number of executables: 41
   Number of commands: 38
   Number of files: 219
   Number of AVC's: 0
   Number of MAC events: 0
   Number of failed syscalls: 187
   Number of anomaly events: 0
   Number of responses to anomaly events: 0
   Number of crypto events: 18
   Number of integrity events: 0
   Number of virt events: 0
   Number of keys: 6
   Number of process IDs: 402
   Number of events: 1974
   ```

   ```bash
   aureport -au -i --summary      # autenticaciones por cuenta
   aureport -k --summary          # eventos por clave de regla
   aureport -x --summary          # ejecutables
   aureport -f -i --failed        # accesos a archivos fallidos
   aureport --tty                 # pulsaciones capturadas por pam_tty_audit
   ```

6. Analizá logs rotados o de otro host:

   ```bash
   ausearch -if /var/log/audit/audit.log.3 -k identity -i
   aureport -if /mnt/evidencia/audit.log --summary
   ```

7. Mirá cómo se exportan los eventos a un colector remoto:

   ```bash
   ls /etc/audit/plugins.d/            # audit 3.x  (2.x: /etc/audisp/plugins.d/)
   ```

   ```
   af_unix.conf  au-remote.conf  syslog.conf
   ```

   ```bash
   cat /etc/audit/plugins.d/syslog.conf
   ```

   ```
   active = no
   direction = out
   path = /sbin/audisp-syslog
   type = always
   args = LOG_INFO
   format = string
   ```

### Preguntas de verificación

**3.1** ¿Qué representa exactamente `1873` en `msg=audit(08/24/2026 11:04:12.771:1873)` y por qué no se debe asumir monotonía global entre reinicios?
**3.2** Un incidente muestra `auid=sysadmin uid=root`. ¿Qué afirmación forense permite y cuál no?
**3.3** ¿Por qué `grep /etc/shadow /var/log/audit/audit.log` puede dar cero resultados aun cuando `ausearch -f /etc/shadow` sí encuentra el evento?
**3.4** ¿Para qué sirven los registros `PATH` con `nametype=PARENT` además del `nametype=NORMAL`?
**3.5** ¿Qué ventaja concreta aporta `log_format = ENRICHED` cuando los eventos se envían a un SIEM remoto?

---

## Ejercicio 4 — `auditd.conf`: retención, espacio y modos de fallo

Este archivo no configura *qué* se audita (eso son las reglas) sino *qué hace el demonio* con lo que recibe. Los parámetros de espacio son controles de disponibilidad: mal puestos, apagan el host.

### Pasos

1. Inspeccioná la configuración vigente:

   ```bash
   grep -vE '^\s*(#|$)' /etc/audit/auditd.conf
   ```

   ```
   local_events = yes
   write_logs = yes
   log_file = /var/log/audit/audit.log
   log_group = root
   log_format = ENRICHED
   flush = INCREMENTAL_ASYNC
   freq = 50
   max_log_file = 8
   num_logs = 5
   priority_boost = 4
   name_format = HOSTNAME
   max_log_file_action = ROTATE
   space_left = 75
   space_left_action = SYSLOG
   verify_email = yes
   action_mail_acct = root
   admin_space_left = 50
   admin_space_left_action = SUSPEND
   disk_full_action = SUSPEND
   disk_error_action = SUSPEND
   use_libwrap = yes
   ```

2. Configuración para un host con requisito de no-pérdida de evidencia:

   ```bash
   cat > /etc/audit/auditd.conf <<'EOF'
   local_events = yes
   write_logs = yes
   log_file = /var/log/audit/audit.log
   log_group = root
   log_format = ENRICHED
   flush = INCREMENTAL_ASYNC
   freq = 50
   max_log_file = 64
   num_logs = 10
   max_log_file_action = KEEP_LOGS
   space_left = 20%
   space_left_action = EMAIL
   action_mail_acct = soc@example.com
   verify_email = yes
   admin_space_left = 10%
   admin_space_left_action = SINGLE
   disk_full_action = HALT
   disk_error_action = SINGLE
   priority_boost = 4
   name_format = HOSTNAME
   overflow_action = SYSLOG
   EOF

   service auditd restart
   ```

3. Verificá que la partición de auditoría está separada (si no lo está, los valores de arriba son una bomba de tiempo):

   ```bash
   findmnt -T /var/log/audit -o TARGET,SOURCE,FSTYPE,SIZE,USE%
   ```

   ```
   TARGET           SOURCE                  FSTYPE SIZE USE%
   /var/log/audit   /dev/mapper/vg0-audit   xfs     10G   7%
   ```

4. Forzá una rotación y observá:

   ```bash
   service auditd rotate      # RHEL;  o: kill -USR1 $(pidof auditd)
   ls -l /var/log/audit/
   ```

   ```
   -rw-------. 1 root root 12582912 Aug 24 11:44 audit.log
   -rw-------. 1 root root 67108864 Aug 24 11:44 audit.log.1
   -rw-------. 1 root root 67108864 Aug 24 09:12 audit.log.2
   ```

5. Recargá la configuración sin reiniciar:

   ```bash
   kill -HUP $(pidof auditd)
   ```

### Preguntas de verificación

**4.1** Con `max_log_file = 64`, `num_logs = 10` y `max_log_file_action = ROTATE`, ¿cuál es el consumo máximo de disco y qué pasa con el registro más antiguo?
**4.2** ¿En qué se diferencian `space_left_action` y `admin_space_left_action`, y por qué existen los dos umbrales?
**4.3** Un auditor exige "ningún evento puede perderse". ¿`flush = SYNC` alcanza? ¿Qué costo tiene y qué otro parámetro hay que tocar además?
**4.4** ¿Qué efecto tiene `local_events = no` y en qué topología se usa?
**4.5** ¿Por qué `disk_full_action = HALT` es defendible en un servidor de certificados y suicida en un nodo de ingreso público?

---

## Ejercicio 5 — AIDE: integridad de archivos

AIDE construye una base de datos con los atributos elegidos de cada archivo y compara contra ella. Su punto débil no es criptográfico sino operativo: **la base y el binario viven en el mismo host que el atacante puede tener comprometido**.

### Pasos

1. Localizá la configuración según distribución:

   ```bash
   ls /etc/aide.conf /etc/aide/aide.conf /etc/aide/aide.conf.d/ 2>/dev/null
   ```

   * RHEL: `/etc/aide.conf` monolítico, DB en `/var/lib/aide/aide.db.gz`.
   * Debian: `/etc/aide/aide.conf` **generado** por `update-aide.conf` a partir de `/etc/aide/aide.conf.d/`; nunca se edita a mano. La DB queda en `/var/lib/aide/aide.db`.

2. Escribí una política propia (sintaxis AIDE ≥ 0.17):

   ```bash
   cat > /etc/aide/aide.conf.d/99-lpic-lab <<'EOF'
   #  ---- ubicación de las bases ------------------------------------------
   database_in  = file:/var/lib/aide/aide.db
   database_out = file:/var/lib/aide/aide.db.new
   database_new = file:/var/lib/aide/aide.db.new
   gzip_dbout   = yes

   #  ---- salida ----------------------------------------------------------
   log_level    = warning
   report_level = changed_attributes
   report_url   = file:/var/log/aide/aide.log
   report_url   = stdout

   #  ---- grupos de atributos --------------------------------------------
   #  p permisos      i inode        n nlinks      u uid        g gid
   #  s tamaño        b bloques      m mtime       c ctime      a atime
   #  S tamaño creciente             ftype tipo    l destino del symlink
   #  acl selinux xattrs e2fsattrs   md5 sha256 sha512 rmd160 ...
   BIN_STRICT = p+i+n+u+g+s+b+m+c+ftype+acl+selinux+xattrs+sha256+sha512
   CONF_FILE  = p+i+n+u+g+s+m+c+ftype+acl+selinux+xattrs+sha256
   LOG_GROW   = p+u+g+n+S+ftype+acl+selinux+xattrs
   DEV_NODE   = p+u+g+ftype+acl+selinux+xattrs

   #  ---- selección -------------------------------------------------------
   /boot          BIN_STRICT
   /bin           BIN_STRICT
   /sbin          BIN_STRICT
   /usr/bin       BIN_STRICT
   /usr/sbin      BIN_STRICT
   /usr/lib       BIN_STRICT
   /usr/local     BIN_STRICT
   /etc           CONF_FILE
   /root          CONF_FILE
   /var/spool/cron  CONF_FILE
   /etc/cron.d      CONF_FILE

   #  excepciones (regex sobre la ruta completa)
   !/etc/mtab$
   !/etc/adjtime$
   !/etc/machine-id$
   !/etc/resolv\.conf$
   !/etc/.*~$
   !/var/lib/aide

   #  directorio sin recursión
   =/home         DEV_NODE

   /var/log       LOG_GROW
   !/var/log/journal
   !/var/log/audit
   EOF

   update-aide.conf                 # Debian: regenera /etc/aide/aide.conf
   aide --config-check -c /etc/aide/aide.conf && echo "config OK"
   ```

3. Inicializá la base:

   ```bash
   aideinit -y -f                          # Debian (envuelve aide --init)
   # RHEL:
   # aide --init && mv /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz
   ```

   ```
   Running aide --init...
   Start timestamp: 2026-08-24 12:03:11 -0300 (AIDE 0.17.4)
   AIDE initialized database at /var/lib/aide/aide.db.new
   Number of entries:      68143
   ---------------------------------------------------
   The attributes of the (uncompressed) database(s):
   ---------------------------------------------------
   /var/lib/aide/aide.db.new
     SHA256    : 6uJmZ+Lp1w9lXqK0kOe5m0hQ1oQvL0m3o6b3l+PZ0aE=
     SHA512    : Hn5H0k4h8p3M...
   End timestamp: 2026-08-24 12:05:02 -0300 (run time: 1m 51s)
   ```

4. Anotá el hash de la base y **sacala del host**:

   ```bash
   sha256sum /var/lib/aide/aide.db | tee /root/aide.db.sha256
   gpg --detach-sign --armor /var/lib/aide/aide.db
   scp /var/lib/aide/aide.db{,.asc} bastion:/srv/aide-baselines/$(hostname)/
   chattr +i /var/lib/aide/aide.db
   ```

5. Provocá cambios y comprobá:

   ```bash
   echo "# comentario de prueba" >> /etc/hosts
   cp /bin/dash /usr/local/bin/dash-copia
   rm -f /etc/cron.d/e2scrub_all
   aide --check -c /etc/aide/aide.conf ; echo "exit=$?"
   ```

   ```
   Start timestamp: 2026-08-24 12:11:44 -0300 (AIDE 0.17.4)
   AIDE found differences between database and filesystem!!

   Summary:
     Total number of entries:      68144
     Added entries:                1
     Removed entries:              1
     Changed entries:              2

   ---------------------------------------------------
   Added entries:
   ---------------------------------------------------
   f+++++++++++++++++: /usr/local/bin/dash-copia

   ---------------------------------------------------
   Removed entries:
   ---------------------------------------------------
   f-----------------: /etc/cron.d/e2scrub_all

   ---------------------------------------------------
   Changed entries:
   ---------------------------------------------------
   f  ...    .C... ..: /etc/hosts
   d  ...    .C... ..: /etc/

   ---------------------------------------------------
   Detailed information about changes:
   ---------------------------------------------------
   File: /etc/hosts
     Size     : 221                              | 245
     Mtime    : 2026-06-03 10:02:17 -0300        | 2026-08-24 12:11:40 -0300
     Ctime    : 2026-06-03 10:02:17 -0300        | 2026-08-24 12:11:40 -0300
     SHA256   : 9wA1n...                         | Kd82p...
   exit=7
   ```

6. Interpretá los códigos de salida:

   ```bash
   aide --check ; ec=$?
   (( ec & 1 )) && echo "hay archivos nuevos"
   (( ec & 2 )) && echo "hay archivos eliminados"
   (( ec & 4 )) && echo "hay archivos modificados"
   ```

7. Actualizá la base tras un cambio legítimo (parche del sistema):

   ```bash
   chattr -i /var/lib/aide/aide.db
   aide --update -c /etc/aide/aide.conf
   mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db
   chattr +i /var/lib/aide/aide.db
   ```

8. Limitá una verificación a una rama concreta (mucho más rápido para chequeos horarios):

   ```bash
   aide --check --limit '^/etc/(cron|sudoers)' -c /etc/aide/aide.conf
   ```

### Preguntas de verificación

**5.1** En `f  ...    .C... ..`, ¿qué codifica cada columna y qué significa la `C`?
**5.2** ¿Por qué el directorio `/etc/` aparece como *changed* cuando sólo se modificó `/etc/hosts`? ¿Y por qué **no** aparecería si sólo se hubiera editado el contenido sin crear ni borrar nada?
**5.3** Un atacante con root instala un backdoor y corre `aide --update`. ¿Qué control detecta esa maniobra y cuál no?
**5.4** ¿Cuál es la diferencia semántica entre `/home DEV_NODE` y `=/home DEV_NODE`?
**5.5** ¿Por qué se excluye `/var/log/audit` de AIDE, si es justamente el directorio más sensible?
**5.6** El mismo `aide.conf` funciona en Debian 12 y falla en RHEL 9 con `Error in configuration line: database_in`. ¿Por qué?
**5.7** Incluir `a` (atime) en un grupo de atributos parece más completo. ¿Qué problema práctico genera?

---

## Ejercicio 6 — rkhunter

`rkhunter` combina cuatro familias de test: firmas de rootkits conocidos, propiedades de archivos contra una línea base, comprobaciones de configuración (SSH, `/etc/passwd`) y detección de anomalías locales (puertos ocultos, LKM). La línea base es su talón de Aquiles y la integración con el gestor de paquetes es la respuesta.

### Pasos

1. Revisá la configuración y validala antes de nada:

   ```bash
   rkhunter --config-check | tail -5
   grep -nE '^(WEB_CMD|PKGMGR|UPDATE_MIRRORS|MIRRORS_MODE|DBDIR|LOGFILE|MAIL-ON-WARNING)' /etc/rkhunter.conf
   ```

   ```
   19:LOGFILE=/var/log/rkhunter.log
   34:DBDIR=/var/lib/rkhunter/db
   112:UPDATE_MIRRORS=1
   118:MIRRORS_MODE=0
   331:WEB_CMD="/bin/false"
   ```

2. Habilitá la actualización de firmas (Debian la bloquea por defecto) y creá un override local:

   ```bash
   cat > /etc/rkhunter.conf.local <<'EOF'
   # Debian fija WEB_CMD=/bin/false; sin esto, --update no descarga nada
   WEB_CMD=""

   UPDATE_MIRRORS=1
   MIRRORS_MODE=0
   ROTATE_MIRRORS=1

   # Verificar hashes contra el gestor de paquetes, no contra la base local
   PKGMGR=DPKG            # RHEL: PKGMGR=RPM
   HASH_FUNC=SHA256

   MAIL-ON-WARNING=soc@example.com
   MAIL_CMD=mail -s "[rkhunter] warning en ${HOST_NAME}"

   ALLOW_SSH_ROOT_USER=no
   ALLOW_SSH_PROT_V1=0

   # Falsos positivos habituales de este host (justificar cada línea)
   ALLOWHIDDENDIR=/etc/.java
   ALLOWHIDDENDIR=/dev/.lxc
   SCRIPTWHITELIST=/usr/bin/egrep
   SCRIPTWHITELIST=/usr/bin/fgrep
   SCRIPTWHITELIST=/usr/bin/ldd
   SCRIPTWHITELIST=/usr/bin/which

   DISABLE_TESTS=suspscan hidden_ports deleted_files packet_cap_apps
   EOF

   rkhunter --config-check && echo "config OK"
   ```

3. Actualizá las bases de datos de firmas:

   ```bash
   rkhunter --update
   ```

   ```
   [ Rootkit Hunter version 1.4.6 ]

   Checking rkhunter data files...
     Checking file mirrors.dat                                  [ No update ]
     Checking file programs_bad.dat                             [ Updated ]
     Checking file backdoorports.dat                            [ No update ]
     Checking file suspscan.dat                                 [ No update ]
     Checking file i18n versions                                [ Updated ]
   ```

   ```bash
   rkhunter --versioncheck
   ```

4. Generá la línea base de propiedades de archivos:

   ```bash
   rkhunter --propupd
   ```

   ```
   [ Rootkit Hunter version 1.4.6 ]
   File updated: searched for 179 files, found 143
   ```

   ```bash
   ls -l /var/lib/rkhunter/db/rkhunter.dat
   ```

5. Ejecutá un chequeo completo:

   ```bash
   rkhunter --check --sk --rwo
   ```

   ```
   Warning: The file properties have changed:
            File: /usr/bin/ssh
            Current hash: 3f1c9a...  Stored hash: b70e12...
            Current inode: 264519  Stored inode: 264410
   Warning: Suspicious file types found in /dev:
            /dev/shm/pulse-shm-2214332812: data
   ```

6. Leé el reporte completo y el resumen:

   ```bash
   tail -40 /var/log/rkhunter.log
   grep -c '\[ Warning \]' /var/log/rkhunter.log
   ```

7. Revisá qué tests existen y desactivá los ruidosos con criterio:

   ```bash
   rkhunter --list tests
   rkhunter --list rootkits | head
   rkhunter --list propfiles | head
   ```

8. Automatización en Debian:

   ```bash
   cat /etc/default/rkhunter
   ```

   ```
   CRON_DAILY_RUN="true"
   CRON_DB_UPDATE="true"
   DB_UPDATE_EMAIL="true"
   REPORT_EMAIL="root"
   APT_AUTOGEN="true"
   NICE="0"
   RUN_CHECK_ON_BATTERY="false"
   ```

9. Comprobá el código de salida:

   ```bash
   rkhunter --check --sk --rwo --nocolors >/dev/null 2>&1 ; echo "exit=$?"
   ```

### Preguntas de verificación

**6.1** ¿Cuál es la diferencia funcional entre `--update` y `--propupd`, y cuál de los dos jamás debe correrse en un cron automático?
**6.2** ¿Qué cambia exactamente al poner `PKGMGR=DPKG`, y por qué mitiga el riesgo de la pregunta anterior?
**6.3** Tras `apt upgrade` aparecen 40 warnings de *file properties changed*. ¿Cuál es el procedimiento correcto y cuál es el atajo peligroso?
**6.4** ¿Por qué Debian entrega `WEB_CMD="/bin/false"` y qué implica para un host sin salida a internet?
**6.5** ¿Qué ventaja tiene `/etc/rkhunter.conf.local` frente a editar `/etc/rkhunter.conf`?
**6.6** `APT_AUTOGEN="true"` en `/etc/default/rkhunter`: ¿qué hace y qué riesgo introduce?

---

## Ejercicio 7 — chkrootkit

`chkrootkit` es un conjunto de scripts de shell y unos pocos binarios (`chkproc`, `chkdirs`, `chkutmp`, `chklastlog`, `chkwtmp`, `strings-static`) que buscan firmas de rootkits conocidos y discrepancias entre vistas del sistema. Depende de binarios del sistema: si el sistema está comprometido, sus resultados también.

### Pasos

1. Ejecutá el chequeo silencioso (sólo lo anómalo):

   ```bash
   chkrootkit -q
   ```

   ```
   /usr/lib/debug/.build-id
   /usr/lib/.build-id
   eth0: PACKET SNIFFER(/usr/sbin/NetworkManager[854])
   Checking `bindshell'... INFECTED (PORTS:  465)
   ```

2. Ejecutá el chequeo completo y filtrá:

   ```bash
   chkrootkit | grep -vE 'not found|not infected|nothing found|nothing detected|no suspect files'
   ```

3. Listá los tests disponibles y corré uno solo:

   ```bash
   chkrootkit -l | tr ' ' '\n' | head -20
   chkrootkit bindshell lkm
   ```

4. Modo experto — muestra la evidencia cruda en lugar del veredicto:

   ```bash
   chkrootkit -x lkm 2>&1 | head -20
   ```

5. **Ejecución desde binarios de confianza** (la única forma defendible sobre un host sospechoso):

   ```bash
   mkdir -p /mnt/rescate
   mount -o ro /dev/sr0 /mnt/rescate          # medio de sólo lectura
   chkrootkit -p /mnt/rescate/bin:/mnt/rescate/usr/bin -q
   ```

6. Analizá un sistema de archivos montado desde un LiveCD:

   ```bash
   chkrootkit -r /mnt/victima -q
   ```

7. Configuración de la ejecución diaria en Debian:

   ```bash
   cat /etc/chkrootkit/chkrootkit.conf     # bookworm; antes: /etc/chkrootkit.conf
   ```

   ```
   RUN_DAILY="true"
   RUN_DAILY_OPTS="-q"
   DIFF_MODE="true"
   ```

8. Reproducí el mecanismo de `DIFF_MODE` a mano:

   ```bash
   chkrootkit -q > /var/lib/chkrootkit/log.today 2>&1
   diff -u /var/lib/chkrootkit/log.expected /var/lib/chkrootkit/log.today
   ```

### Preguntas de verificación

**7.1** `Checking 'bindshell'... INFECTED (PORTS: 465)` en un servidor de correo. ¿Es un rootkit? Justificá y proponé la verificación que lo confirma o descarta.
**7.2** `chkproc` reporta `Possible LKM Trojan installed`. Explicá el mecanismo del test y por qué produce falsos positivos en hosts con mucha creación de procesos.
**7.3** ¿Qué garantiza y qué **no** garantiza `chkrootkit -p /mnt/rescate/bin`?
**7.4** Enumerá tres diferencias de diseño entre `chkrootkit` y `rkhunter` que justifiquen correr los dos.
**7.5** ¿Por qué `DIFF_MODE="true"` es lo que hace usable la ejecución diaria?

---

## Ejercicio 8 — Linux Malware Detect (maldet)

LMD apunta a un problema distinto del de AIDE o rkhunter: **contenido malicioso subido por usuarios** (webshells, backdoors PHP/Perl) en árboles compartidos. Sus firmas provienen de datos de honeypots y de feeds de la comunidad; el motor de escaneo puede delegarse a ClamAV por rendimiento.

### Pasos

1. Instalación (no está empaquetado en distribuciones):

   ```bash
   cd /usr/local/src
   curl -fSLO https://www.rfxn.com/downloads/maldetect-current.tar.gz
   curl -fSLO https://www.rfxn.com/downloads/maldetect-current.tar.gz.sha256
   sha256sum -c maldetect-current.tar.gz.sha256
   tar -xzf maldetect-current.tar.gz
   cd maldetect-*/
   ./install.sh
   ```

   ```
   Linux Malware Detect v1.6.5
              (C) 2002-2023, R-fx Networks <proj@rfxn.com>
   installation completed to /usr/local/maldetect
   config file: /usr/local/maldetect/conf.maldet
   exec file: /usr/local/maldetect/maldet
   exec link: /usr/local/sbin/maldet
   exec link: /usr/local/sbin/lmd
   cron.daily: /etc/cron.daily/maldet
   ```

2. Configurá `/usr/local/maldetect/conf.maldet`:

   ```bash
   cat > /usr/local/maldetect/conf.maldet <<'EOF'
   email_alert="1"
   email_addr="soc@example.com"
   email_subj="maldet alert de $(hostname)"
   email_ignore_clean="1"

   # 0 = sólo alertar | 1 = mover a cuarentena | 2 = cuarentena + suspender usuario
   quarantine_hits="1"
   quarantine_clean="0"
   quarantine_suspend_user="0"
   quarantine_suspend_user_minuid="500"

   # motor: usar clamscan si está disponible (mucho más rápido)
   scan_clamscan="1"
   scan_ignore_root="0"
   scan_max_depth="15"
   scan_min_filesize="24"
   scan_max_filesize="2048k"
   scan_cpunice="19"
   scan_ionice="6"

   autoupdate_signatures="1"
   autoupdate_version="1"
   autoupdate_version_hashed="1"

   # monitoreo inotify
   default_monitor_mode="/usr/local/maldetect/monitor_paths"
   inotify_base_watches="16384"
   inotify_stime="30"
   inotify_nice="19"
   EOF
   ```

3. Actualizá firmas y versión:

   ```bash
   maldet -u
   ```

   ```
   Linux Malware Detect v1.6.5
   (*) {sigup} performing signature update check...
   (*) {sigup} local signature set is version 2024022315709
   (*) {sigup} new signature set (2026081118843) available
   (*) {sigup} downloaded https://cdn.rfxn.com/downloads/maldet-sigpack.tgz
   (*) {sigup} verified md5sum of maldet-sigpack.tgz
   (*) {sigup} unpacked and installed maldet-sigpack.tgz
   (*) {sigup} signature set update completed
   (*) {sigup} 17262 signatures (13445 MD5 | 3782 HEX | 35 YARA | 0 USER)
   ```

4. Verificá **cómo** invoca LMD a ClamAV — no confíes en la documentación, leé el código:

   ```bash
   grep -n 'clamscan' /usr/local/maldetect/internals/functions | head -10
   ```

   Prestá atención a los parámetros `-d` de esa invocación.

5. Escaneo puntual:

   ```bash
   maldet -a /var/www
   ```

   ```
   Linux Malware Detect v1.6.5
   (*) Using clamav scanner engine...
   (*) Scan of /var/www complete (2841 files)
   (*) TOTAL HITS: 0
   (*) Scan id: 260824-1421.24188
   (*) Report: maldet --report 260824-1421.24188
   ```

6. Escaneo incremental (sólo lo modificado en los últimos 2 días) y en segundo plano:

   ```bash
   maldet -b -r /home/?/public_html 2
   maldet --report list | head
   maldet --report 260824-1421.24188
   ```

7. Prueba del motor con el archivo de test estándar **EICAR** (no es malware, es una cadena de prueba):

   ```bash
   printf 'X5O!P%%@AP[4\\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*' \
     > /var/www/eicar.com
   clamscan --infected /var/www/eicar.com ; echo "exit=$?"
   maldet -a /var/www ; echo "exit=$?"
   ```

   Compará ambos resultados y explicá la diferencia a partir de lo que viste en el paso 4.

8. Cuarentena y restauración:

   ```bash
   maldet -q 260824-1421.24188          # poner en cuarentena los hits del reporte
   ls -l /usr/local/maldetect/quarantine/
   maldet -s 260824-1421.24188          # restaurar desde cuarentena
   ```

9. Monitoreo en tiempo real con inotify:

   ```bash
   maldet -m /var/www
   tail -5 /usr/local/maldetect/logs/inotify_log
   maldet --monitor reload
   maldet -k                            # detener el monitor
   ```

   ```
   Linux Malware Detect v1.6.5
   (*) Inotify startup successful (pid: 30112)
   (*) Inotify monitoring 1 paths (2841 files)
   ```

10. Revisá el cron instalado:

    ```bash
    cat /etc/cron.daily/maldet | head -30
    ```

11. Limpieza del laboratorio:

    ```bash
    rm -f /var/www/eicar.com
    ```

### Preguntas de verificación

**8.1** Según lo observado en el paso 4, ¿por qué `clamscan` detecta EICAR y `maldet -a` puede no hacerlo, aun con `scan_clamscan="1"`?
**8.2** ¿Qué diferencia hay entre `quarantine_hits="1"` y `quarantine_clean="1"`, y por qué el segundo es peligroso sin backups?
**8.3** ¿Qué límite del kernel impone `inotify_base_watches` y qué síntoma tiene agotarlo?
**8.4** ¿Por qué `maldet -r ruta 2` es preferible a `maldet -a ruta` en un servidor de hosting con 400 GB de contenido?
**8.5** LMD no detecta ningún archivo en un host donde AIDE sí reporta binarios modificados en `/usr/sbin`. ¿Contradicción? Explicá los dominios de detección.
**8.6** ¿Qué implica `scan_min_filesize="24"` desde el punto de vista de la evasión?

---

## Ejercicio 9 — Automatización de escaneos con cron

Un HIDS que nadie mira no es un control. La automatización tiene tres requisitos: ejecutarse, **reportar sólo lo relevante**, y dejar rastro verificable de que se ejecutó.

### Pasos

1. Escribí un wrapper que agregue los tres motores y comunique por código de salida:

   ```bash
   cat > /usr/local/sbin/hids-daily <<'EOF'
   #!/bin/bash
   # HIDS aggregate run: AIDE + rkhunter + chkrootkit.
   # Exit: 0 clean, 1 findings, 2 execution failure.
   set -u
   PATH=/usr/sbin:/usr/bin:/sbin:/bin
   TAG=hids
   REPORT=$(mktemp /tmp/hids.XXXXXX)
   trap 'rm -f "$REPORT"' EXIT
   rc=0

   run() {   # run <label> <cmd...>
     local label=$1; shift
     local out ec
     out=$("$@" 2>&1); ec=$?
     printf '### %s (exit=%d)\n%s\n\n' "$label" "$ec" "$out" >>"$REPORT"
     logger -t "$TAG" -p security.notice "$label finished exit=$ec"
     return $ec
   }

   run aide /usr/sbin/aide --check -c /etc/aide/aide.conf
   case $? in
     0) : ;;
     1|2|3|4|5|6|7) rc=1 ;;
     *) rc=2 ;;
   esac

   run rkhunter /usr/bin/rkhunter --check --sk --rwo --nocolors --cronjob
   [ $? -ne 0 ] && rc=$(( rc == 2 ? 2 : 1 ))

   run chkrootkit /usr/sbin/chkrootkit -q
   grep -qE 'INFECTED|Vulnerable' "$REPORT" && rc=$(( rc == 2 ? 2 : 1 ))

   if [ "$rc" -ne 0 ]; then
     mail -s "[$TAG][$(hostname -f)] rc=$rc $(date -Is)" soc@example.com <"$REPORT"
     logger -t "$TAG" -p security.warning "findings present rc=$rc"
   else
     logger -t "$TAG" -p security.info "clean run"
   fi
   exit "$rc"
   EOF
   chmod 750 /usr/local/sbin/hids-daily
   ```

2. Programalo con cron, con silencio en caso de éxito:

   ```bash
   cat > /etc/cron.d/hids <<'EOF'
   SHELL=/bin/bash
   PATH=/usr/sbin:/usr/bin:/sbin:/bin
   MAILTO=""
   RANDOM_DELAY=25
   # m   h  dom mon dow  user  command
     17  3   *   *   *   root  /usr/local/sbin/hids-daily
   EOF
   chmod 644 /etc/cron.d/hids
   ```

3. Alternativa con systemd (preferible: da estado, reintento y jitter nativo):

   ```bash
   cat > /etc/systemd/system/hids-daily.service <<'EOF'
   [Unit]
   Description=Daily host intrusion detection sweep
   After=network-online.target

   [Service]
   Type=oneshot
   ExecStart=/usr/local/sbin/hids-daily
   Nice=19
   IOSchedulingClass=idle
   SuccessExitStatus=0 1
   EOF

   cat > /etc/systemd/system/hids-daily.timer <<'EOF'
   [Unit]
   Description=Run hids-daily every night

   [Timer]
   OnCalendar=*-*-* 03:17:00
   RandomizedDelaySec=1800
   Persistent=true

   [Install]
   WantedBy=timers.target
   EOF

   systemctl daemon-reload
   systemctl enable --now hids-daily.timer
   systemctl list-timers hids-daily.timer
   ```

   ```
   NEXT                        LEFT       LAST PASSED UNIT             ACTIVATES
   Tue 2026-08-25 03:29:41 -03 15h        n/a  n/a    hids-daily.timer hids-daily.service
   ```

4. Verificá que efectivamente corrió, sin depender del correo:

   ```bash
   systemctl start hids-daily.service
   systemctl status hids-daily.service --no-pager
   journalctl -u hids-daily.service -n 20 --no-pager
   journalctl -t hids -p security.warning --since today
   ```

5. Auditá el propio mecanismo de automatización:

   ```bash
   auditctl -w /etc/cron.d/ -p wa -k cronconfig
   auditctl -w /usr/local/sbin/hids-daily -p wa -k hidsbin
   auditctl -w /etc/systemd/system/ -p wa -k unitconfig
   ```

### Preguntas de verificación

**9.1** ¿Por qué `MAILTO=""` en el `cron.d` y el envío de correo dentro del script, en lugar de dejar que cron mande la salida?
**9.2** ¿Qué aporta `SuccessExitStatus=0 1` en la unit, y qué pasaría sin esa línea?
**9.3** ¿Cuál es el argumento a favor y en contra de `RandomizedDelaySec=1800` en un control de detección?
**9.4** El script escribe a syslog con `logger -t hids` incluso cuando no hay hallazgos. ¿Qué detecta esa línea "inútil"?
**9.5** ¿Por qué `/etc/cron.daily/` no es un buen lugar para un escaneo AIDE en un host con muchos servicios?
**9.6** ¿Qué debilidad tiene todo este esquema si el atacante ya tiene root, y qué arquitectura la corrige?

---

## Ejercicio 10 — OpenSCAP (conocimiento general)

OpenSCAP no es un HIDS: es un **scanner de cumplimiento y de vulnerabilidades** que evalúa el host contra contenido SCAP estandarizado (XCCDF para los checklists, OVAL para las definiciones de estado, CPE para plataformas, ARF para resultados). El objetivo del examen es reconocerlo y saber invocarlo.

### Pasos

1. Verificá qué contenido hay instalado:

   ```bash
   rpm -ql scap-security-guide | grep ds.xml     # RHEL
   apt-cache search '^ssg-'                      # Debian: ssg-debian / ssg-debderived
   ls /usr/share/xml/scap/ssg/content/
   ```

   ```
   ssg-rhel9-ds.xml  ssg-rhel9-xccdf.xml  ssg-rhel9-oval.xml  ssg-rhel9-cpe-dictionary.xml
   ```

2. Inspeccioná el data stream y sus perfiles:

   ```bash
   oscap info /usr/share/xml/scap/ssg/content/ssg-rhel9-ds.xml
   ```

   ```
   Document type: Source Data Stream
   Imported: 2026-05-14T08:11:22

   Stream: scap_org.open-scap_datastream_from_xccdf_ssg-rhel9-xccdf.xml
   Generated: (null)
   Version: 1.3
   Checklists:
       Ref-Id: scap_org.open-scap_cref_ssg-rhel9-xccdf.xml
           Status: draft
           Profiles:
               Title: CIS Red Hat Enterprise Linux 9 Benchmark for Level 1 - Server
                   Id: xccdf_org.ssgproject.content_profile_cis_server_l1
               Title: DISA STIG for Red Hat Enterprise Linux 9
                   Id: xccdf_org.ssgproject.content_profile_stig
               Title: PCI-DSS v4.0 Control Baseline
                   Id: xccdf_org.ssgproject.content_profile_pci-dss
           Referenced check files:
               ssg-rhel9-oval.xml  (system: http://oval.mitre.org/XMLSchema/oval-definitions-5)
   ```

3. Evaluá un perfil y generá reporte navegable:

   ```bash
   oscap xccdf eval \
     --profile xccdf_org.ssgproject.content_profile_cis_server_l1 \
     --results-arf /root/scap-arf.xml \
     --report /root/scap-report.html \
     /usr/share/xml/scap/ssg/content/ssg-rhel9-ds.xml
   echo "exit=$?"
   ```

   ```
   Title   Ensure auditd Service Is Enabled
   Rule    xccdf_org.ssgproject.content_rule_service_auditd_enabled
   Ident   CCE-83757-8
   Result  pass

   Title   Enable Kernel Auditing at Boot
   Rule    xccdf_org.ssgproject.content_rule_grub2_audit_argument
   Ident   CCE-80943-7
   Result  fail

   Title   Install AIDE
   Rule    xccdf_org.ssgproject.content_rule_package_aide_installed
   Result  pass
   exit=2
   ```

4. Filtrá los hallazgos desde el ARF:

   ```bash
   oscap xccdf generate report /root/scap-arf.xml > /root/scap-report.html
   xmllint --xpath 'count(//*[local-name()="result"][text()="fail"])' /root/scap-arf.xml
   ```

5. Generá remediación (revisala antes de ejecutarla, nunca a ciegas):

   ```bash
   oscap xccdf generate fix \
     --fix-type bash \
     --profile xccdf_org.ssgproject.content_profile_cis_server_l1 \
     --output /root/remediate.sh \
     /root/scap-arf.xml
   less /root/remediate.sh

   oscap xccdf generate fix --fix-type ansible \
     --profile xccdf_org.ssgproject.content_profile_cis_server_l1 \
     --output /root/remediate.yml \
     /root/scap-arf.xml
   ```

6. Evaluación de vulnerabilidades con OVAL (CVE):

   ```bash
   curl -fSLO https://security.access.redhat.com/data/oval/v2/RHEL9/rhel-9.oval.xml.bz2
   bunzip2 rhel-9.oval.xml.bz2
   oscap oval eval --results /root/cve-results.xml --report /root/cve.html rhel-9.oval.xml
   ```

7. Escaneo remoto y de contenedores:

   ```bash
   oscap-ssh root@10.0.0.21 22 xccdf eval \
     --profile xccdf_org.ssgproject.content_profile_stig \
     --report /root/remoto.html \
     /usr/share/xml/scap/ssg/content/ssg-rhel9-ds.xml

   oscap-podman <image-id> xccdf eval --profile ... ssg-rhel9-ds.xml
   ```

### Preguntas de verificación

**10.1** `oscap xccdf eval` devuelve `2`. ¿Falló la herramienta? Explicá los tres códigos de salida.
**10.2** Distinguí los roles de XCCDF, OVAL, CPE y ARF dentro de un data stream SCAP.
**10.3** ¿Por qué `oscap xccdf eval --remediate` es riesgoso en un host en producción y cuál es el flujo recomendado?
**10.4** ¿En qué se diferencia conceptualmente OpenSCAP de AIDE? ¿Cuál detectaría un binario troyanizado y cuál un `sshd_config` que permite root?
**10.5** ¿Qué identificador de la salida (`CCE-83757-8`) sirve para trazabilidad de cumplimiento, y en qué se diferencia de un CVE?

---

## Ejercicio 11 — Integrador: simulacro de compromiso y detección

Se simula la fase de persistencia de un atacante que ya obtuvo root, y se verifica qué control lo detecta. **Sólo en la VM de laboratorio.** Cada artefacto es inocuo y se elimina al final.

### Pasos

1. Asegurate de que la línea base está fresca y las reglas cargadas:

   ```bash
   aide --check -c /etc/aide/aide.conf ; echo "baseline exit=$?"   # esperado: 0
   auditctl -l | wc -l
   ```

2. Sembrá cuatro artefactos de persistencia:

   ```bash
   # (a) shell setuid escondida
   install -o root -g root -m 4755 /bin/dash /usr/local/sbin/.systemd-hostnamed

   # (b) cuenta UID 0 alternativa
   useradd -o -u 0 -g 0 -M -d /root -s /bin/bash -c "System Monitor" svcmon

   # (c) persistencia por cron
   printf '*/7 * * * * root /usr/local/sbin/.systemd-hostnamed -c "true"\n' \
     > /etc/cron.d/systemd-hostname-sync

   # (d) clave SSH añadida
   mkdir -p /root/.ssh && chmod 700 /root/.ssh
   ssh-keygen -q -t ed25519 -N '' -f /tmp/lab-key -C 'lab@detect'
   cat /tmp/lab-key.pub >> /root/.ssh/authorized_keys
   ```

3. Detección con el Audit System (en tiempo real, con atribución):

   ```bash
   ausearch -k identity -i --start recent | grep -E 'comm=|proctitle' | tail
   ausearch -k scope -i --start recent | tail -20
   ausearch -k setuid-exec -i --start recent | tail
   aureport -k --summary --start today
   ```

   ```
   Key Summary Report
   ===========================
   total  key
   ===========================
   14  identity
   6   auditconfig
   3   scope
   ```

4. Detección con AIDE (a posteriori, con alcance completo):

   ```bash
   aide --check -c /etc/aide/aide.conf ; echo "exit=$?"
   ```

   ```
   Added entries:
   f+++++++++++++++++: /usr/local/sbin/.systemd-hostnamed
   f+++++++++++++++++: /etc/cron.d/systemd-hostname-sync

   Changed entries:
   f  ...    .C... ..: /etc/passwd
   f  ...    .C... ..: /etc/shadow
   d  ...    .C... ..: /etc/cron.d
   exit=5
   ```

5. Detección con rkhunter:

   ```bash
   rkhunter --check --sk --rwo --enable passwd_changes,group_changes,hidden_procs,filesystem,suspscan
   ```

   ```
   Warning: Found passwd file changes:
            User 'svcmon' has been added to the passwd file.
   Warning: Hidden file found: /usr/local/sbin/.systemd-hostnamed
   Warning: Found the following UID 0 accounts other than root: svcmon
   ```

6. Verificaciones manuales que ninguna herramienta reemplaza:

   ```bash
   awk -F: '$3==0 {print $1}' /etc/passwd
   find / -xdev \( -perm -4000 -o -perm -2000 \) -type f -printf '%M %u %p\n' 2>/dev/null
   find /etc/cron* /var/spool/cron -type f -newermt '-1 day' -ls 2>/dev/null
   find / -xdev -name '.*' -type f -newermt '-1 day' 2>/dev/null | head
   ```

7. Limpieza:

   ```bash
   userdel svcmon
   rm -f /usr/local/sbin/.systemd-hostnamed /etc/cron.d/systemd-hostname-sync /tmp/lab-key*
   sed -i '/lab@detect/d' /root/.ssh/authorized_keys
   chattr -i /var/lib/aide/aide.db
   aide --update -c /etc/aide/aide.conf && mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db
   chattr +i /var/lib/aide/aide.db
   rkhunter --propupd
   ```

### Preguntas de verificación

**11.1** ¿Cuál de los cuatro artefactos **no** aparece en la salida de AIDE de la política del Ejercicio 5, y qué línea de selección habría que agregar?
**11.2** Ordená los tres controles (auditd, AIDE, rkhunter) por *latencia de detección* y por *capacidad de atribución*. ¿Coincide el orden?
**11.3** El artefacto (a) se llama `.systemd-hostnamed`. ¿Qué dos tests de rkhunter dispara ese nombre y qué opción de configuración podría un administrador descuidado usar para silenciarlos?
**11.4** ¿Por qué `useradd -o -u 0` genera eventos de auditoría con clave `identity` aunque no exista ninguna regla sobre `useradd`?
**11.5** Después de la limpieza se corre `rkhunter --propupd` y `aide --update`. Describí en qué orden deben hacerse respecto de la verificación de que el sistema quedó limpio, y por qué el orden inverso destruye evidencia.

---

<details>
<summary><strong>Respuestas</strong></summary>

### Ejercicio 1

**1.1** `enabled 1` significa que la auditoría está activa y las reglas se pueden agregar, modificar y borrar. `enabled 2` es el **modo inmutable**: las reglas quedan congeladas y cualquier intento de `auditctl -D`, `-a` o `-w` devuelve `Operation not permitted`. También se bloquea el cambio del propio flag. La única salida de `enabled 2` es **reiniciar el host** — de ahí que `-e 2` sea siempre la última línea del último archivo de reglas y que los cambios de política requieran una ventana de reboot.

**1.2** Tres causas y su discriminante:
1. **Volumen de reglas excesivo** (típicamente `-S all` o watches sobre `/usr` o `/var/lib`): `aureport -k --summary` o `aureport -x --summary` muestra una clave o un ejecutable dominando el conteo.
2. **Backlog demasiado chico para picos legítimos**: `backlog` toca `backlog_limit` sólo en ráfagas y baja después; subir `-b` y `audit_backlog_limit` en la línea de comandos del kernel lo resuelve.
3. **auditd no consume** — está detenido, colgado en escritura por disco lleno, o el disco es lento: `pid 0` en `auditctl -s`, o `pid` válido pero `/var/log/audit` sin crecer. `iostat`/`journalctl -u auditd` distinguen entre demonio muerto y disco saturado.
Cualquier valor de `lost` distinto de cero significa evidencia perdida de forma no recuperable. Se reinicia el contador con `auditctl --reset_lost`.

**1.3** `failure 2` provoca un **kernel panic** cuando el subsistema no puede registrar un evento. Es exigible en entornos donde la regla es "sin registro no hay operación" (CAPP/LSPP, ciertos perfiles de defensa), porque garantiza que ningún acto queda sin rastro. Es un vector de DoS porque un atacante sin privilegios que genere suficientes eventos auditables (bucle de `execve` o de aperturas fallidas sobre una ruta watcheada) puede desbordar la cola y **apagar el host**. Sólo es defendible con `backlog_limit` amplio, `rate_limit` configurado, partición de auditoría dedicada y reglas acotadas.

**1.4** Sin `audit=1` el subsistema arranca deshabilitado y sólo se habilita cuando `auditd` se inicia. Todo lo que ocurre antes — initramfs, arranque temprano de systemd, montajes iniciales, primeras unidades — **no genera registros**, o queda encolado y se descarta si el backlog inicial (128 por defecto) se llena. Esa ventana es exactamente donde vive el malware de arranque temprano. `audit=1 audit_backlog_limit=8192` cierra el hueco.

**1.5** Porque `systemctl stop auditd` mataría al proceso registrado en el kernel dejando los eventos sin destino, y porque systemd registraría el `stop` como una operación de servicio normal, lo que un atacante podría usar para cegar la auditoría con un comando legítimo. RHEL fuerza el uso de las *legacy actions* (`/usr/libexec/initscripts/legacy-actions/auditd/`), que aplican la secuencia correcta y quedan registradas. Como efecto adicional, cambiar reglas se hace con `augenrules --load` y no reiniciando el demonio.

---

### Ejercicio 2

**2.1** El campo `arch` selecciona la **tabla de syscalls**: los números de llamada difieren entre `b32` (i386) y `b64` (x86_64). Una regla `arch=b64` sólo se aplica a procesos que entran por la ABI de 64 bits. En un x86_64 con soporte multilib, un binario de 32 bits — o un proceso de 64 bits que use `int 0x80` — ejecuta por la tabla de 32 bits y **evade la regla por completo**. Es una técnica de evasión trivial y documentada; por eso toda regla de syscall se declara en ambas arquitecturas. Si el kernel no tiene `CONFIG_IA32_EMULATION`, la regla `b32` simplemente no matchea nada, pero no molesta.

**2.2** `-a` **añade** la regla al final de la lista; `-A` la **antepone**. El kernel evalúa las reglas de una lista en orden y se detiene en la primera coincidencia. Como una regla `never` sólo sirve para suprimir, tiene que evaluarse **antes** que la regla `always` que la cubriría; si se agrega con `-a` después de la `always`, no se alcanza nunca y la exclusión no tiene efecto. Con archivos en `rules.d`, el orden lo determina el nombre del archivo (orden ASCII), así que las exclusiones van en un archivo con prefijo numérico menor.

**2.3** **Sí, sigue vigente.** El *watch* de audit no es un watch de inotify sobre el inode: el kernel crea una estructura `audit_parent` con un mark fsnotify sobre el **directorio padre** y un `audit_watch` con el nombre del último componente. Cuando aparece un inode nuevo con ese nombre, el watch se reasocia automáticamente al inode nuevo. Esto es una diferencia deliberada con inotify, que sí seguiría al inode viejo, y es lo que hace confiable el watch sobre archivos que se reescriben por `rename` (`/etc/passwd`, `/etc/shadow`, `/etc/sudoers`).

**2.4** Se puede si **el directorio padre existe**. El kernel resuelve la ruta padre con `kern_path_locked`, que acepta un dentry negativo para el último componente; el watch queda armado y se activa cuando el archivo se cree. Si el padre no existe, la carga falla con `Error sending add rule data request (No such file or directory)`. En la práctica: watchear `/opt/app/config.yml` antes de instalar la app funciona si `/opt/app` ya está creado.

**2.5** El registro `CWD` guarda el directorio de trabajo del proceso en el momento del syscall. Sin él, todo registro `PATH` con una ruta **relativa** queda irresoluble: `name="config.yml"` deja de poder mapearse a un archivo concreto. También se pierde la señal de contexto sobre desde dónde operaba el atacante. La exclusión de `CWD` es una optimización de volumen legítima cuando las reglas usan rutas absolutas y `exe=` es suficiente para la investigación, pero degrada la reconstrucción forense de operaciones lanzadas con rutas relativas.

**2.6** `auid` (audit UID o *loginuid*) es la identidad de login original del proceso, inmutable a través de `su`/`sudo`. Los procesos del sistema que nunca tuvieron un login (demonios arrancados por systemd) tienen `auid` sin asignar, representado por `(uid_t)-1`, es decir `4294967295`. `-F auid!=unset` excluye a esos procesos para que la regla capture sólo actividad de usuarios reales. `unset` es un alias legible introducido en audit userspace 2.7; con versiones anteriores hay que escribir el número. La forma numérica es portable a cualquier versión.

**2.7** Porque `augenrules` concatena los archivos de `rules.d` en **orden ASCII** y `-e 2` congela la configuración. Si estuviera en `10-*.rules`, todas las reglas de los archivos siguientes fallarían al cargarse con `Operation not permitted`, dejando el sistema con auditoría inmutable y prácticamente vacía. El flag inmutable siempre va en el último archivo y en la última línea.

---

### Ejercicio 3

**3.1** El valor tras los dos puntos es el **número de serie del evento**, un contador del kernel que agrupa todos los registros producidos por un mismo syscall. El par `(timestamp, serial)` es lo que identifica un evento; el serial solo no es único. Se reinicia en cada boot y **puede repetirse** entre reinicios o entre hosts distintos, por lo que nunca debe usarse como identificador global en un SIEM sin combinarlo con timestamp y `node`/`HOSTNAME` (de ahí `name_format = HOSTNAME`).

**3.2** Permite afirmar que la sesión se inició como `sysadmin` y que en el momento del evento el proceso tenía privilegios de root — es decir, hubo una escalada legítima vía `su`/`sudo` y la cuenta responsable es `sysadmin`. **No** permite afirmar que la persona detrás de la cuenta `sysadmin` sea el titular: el `auid` acredita la sesión, no al ser humano. Tampoco distingue si la escalada fue autorizada; para eso hay que correlacionar con los eventos `USER_AUTH`/`USER_CMD` de la misma sesión (`ses=`).

**3.3** Porque en el registro `SYSCALL` la ruta no aparece: aparece en registros `PATH` separados, y ahí el campo puede estar como `name="/etc/shadow"` pero también como ruta relativa, o el nombre puede venir codificado en hexadecimal cuando contiene caracteres no imprimibles o espacios (`name=2F6574632F736861646F77`). `ausearch -f` normaliza y decodifica, y además reagrupa el evento completo. `grep` sobre el log crudo falla en los tres casos.

**3.4** El `PATH` con `nametype=PARENT` registra el directorio contenedor con su inode, permisos y contexto, y es lo que permite reconstruir la ruta absoluta cuando el `NORMAL` es relativo, además de documentar sobre qué directorio se tenía permiso de escritura. En operaciones de creación, borrado o `rename` hay varios registros `PATH` (`PARENT`, `CREATE`, `DELETE`, `NORMAL`) y sólo el conjunto describe la operación real.

**3.5** Con `ENRICHED`, auditd resuelve **en el momento de escribir** los identificadores numéricos a nombres (`UID`, `GID`, `AUID`, `SYSCALL`, `ARCH`) y los agrega como campos adicionales al registro. En un SIEM remoto, la máquina que analiza no tiene el `/etc/passwd`, el `/etc/group` ni la tabla de syscalls del host origen, así que un `uid=1017` es ininterpretable — o peor, se resuelve contra el mapa equivocado. `ENRICHED` hace el registro autocontenido. El costo es mayor tamaño de log.

---

### Ejercicio 4

**4.1** El consumo máximo es `max_log_file × num_logs` = 64 MB × 10 = **640 MB**, más el `audit.log` activo que puede llegar a otros 64 MB antes de rotar. Con `ROTATE`, al alcanzar `num_logs` el archivo más antiguo (`audit.log.10`) se **elimina** cuando entra uno nuevo. Es decir, `ROTATE` implica pérdida de registros antiguos por diseño; si el requisito es retención, hay que usar `KEEP_LOGS` (que no borra, deja crecer indefinidamente el número de archivos y transfiere el riesgo al espacio en disco) más un envío externo.

**4.2** `space_left` es el umbral de **advertencia temprana**, pensado para que un operador reaccione — su acción típica es `SYSLOG` o `EMAIL`. `admin_space_left` es el umbral **crítico**, más bajo, y su acción es disruptiva (`SUSPEND`, `SINGLE`, `HALT`). Existen los dos porque una acción disruptiva a la primera señal de disco lleno convierte un problema de capacidad en una caída de servicio, mientras que sólo advertir deja el sistema llegando a disco lleno sin salvaguarda. Ambos aceptan MB absolutos o porcentaje (`20%`) desde audit 2.8.1.

**4.3** No alcanza. `flush = SYNC` fuerza un `fsync()` por cada registro, lo que garantiza durabilidad **de lo que auditd ya recibió**, con un costo de rendimiento que puede llegar a un orden de magnitud en hosts con carga de syscalls. Pero la pérdida típica no ocurre en el disco sino **en la cola del kernel**: hay que ajustar además `backlog_limit` (`-b`), `audit_backlog_limit` en la línea de comandos del kernel y `backlog_wait_time` (dejarlo distinto de 0 hace que el kernel bloquee al proceso emisor en lugar de descartar), y decidir el `failure mode`. El compromiso habitual es `INCREMENTAL_ASYNC` con `freq = 50` más una partición dedicada.

**4.4** `local_events = no` hace que auditd **no procese eventos del kernel local**; el demonio queda funcionando sólo como receptor de eventos remotos vía `audisp-remote`. Se usa en el **nodo agregador central** de una topología de auditoría distribuida, donde ese host recolecta los logs de muchos servidores y no debe mezclar los propios. En un host normal desactiva la auditoría en la práctica.

**4.5** En un servidor de certificados (CA, KDC, HSM frontend) el valor está en la **integridad y la trazabilidad**: operar sin registro es peor que no operar, porque una emisión de certificado sin rastro es indefendible ante una auditoría. Detener el host es la respuesta correcta. En un nodo de ingreso público, el mismo parámetro convierte "el disco se llenó" —una condición que un atacante puede provocar generando tráfico auditable— en una **caída total del servicio**: es un DoS remoto de un solo paso. Ahí corresponde `SYSLOG` o `EMAIL` en `space_left`, envío remoto de los eventos, y partición dedicada para que el llenado no arrastre a `/`.

---

### Ejercicio 5

**5.1** La primera columna es el **tipo de entrada** (`f` archivo, `d` directorio, `l` symlink, `c`/`b` dispositivo, `p` FIFO, `s` socket). Le siguen posiciones fijas, una por atributo verificado, en el orden `p i n u g s ... acl xattrs selinux e2fsattrs` y luego los hashes; un `.` significa "sin cambio", un `+` "atributo agregado", un `-` "atributo eliminado", una `:` "no verificado", un espacio "no disponible", y una letra mayúscula el atributo que cambió. La `C` indica que **cambió el contenido**, es decir, al menos un hash difiere. Una línea de sólo `+` (`f+++++++++++++++++`) es una entrada nueva, y de sólo `-` una entrada eliminada.

**5.2** El directorio aparece como *changed* porque en el laboratorio se **borró** `/etc/cron.d/e2scrub_all` y se creó un archivo en `/usr/local/bin`: crear o eliminar una entrada modifica el `mtime` y el `ctime` del directorio contenedor y, según el sistema de archivos, su tamaño. Editar el contenido de un archivo existente **no** toca el directorio, sólo el inode del archivo; en ese caso el directorio no aparecería. Esta propiedad es útil: un directorio marcado como cambiado sin ningún archivo nuevo o eliminado reportado significa que se creó y borró algo entre el evento y el escaneo.

**5.3** No lo detecta **nada dentro del host**. AIDE no tiene defensa contra un root que reescriba la base: `chattr +i` se revierte con `chattr -i`, y los permisos no aplican a root. Lo que sí lo detecta es la **verificación externa de la base**: comparar el hash de `aide.db` (o su firma GPG) contra la copia guardada en un host separado, o directamente correr la comparación fuera del host — montar el sistema de archivos desde un LiveCD o un snapshot y ejecutar AIDE contra la base de referencia offline. Ese es el motivo por el que la base y el binario deben vivir en medio de sólo lectura o fuera del host; sin eso, AIDE detecta atacantes descuidados, no atacantes informados.

**5.4** Sin prefijo, `/home DEV_NODE` es una regla **recursiva**: aplica a `/home` y a todo lo que cuelga debajo, a cualquier profundidad. Con el prefijo `=`, `=/home DEV_NODE` es una regla de **coincidencia exacta**: aplica sólo a la entrada `/home` misma y no desciende. Se usa para vigilar los permisos y la propiedad de un punto de montaje o de un directorio raíz sin incorporar su contenido —volátil y enorme— a la base.

**5.5** Porque `/var/log/audit` cambia continuamente por diseño: cada evento escribe. Incluirlo produciría un reporte de cambios en cada ejecución, con ruido que oculta los hallazgos reales, y una base que envejece en segundos. La integridad de esos logs se protege con otros controles, que sí son adecuados al problema: la regla de auditoría `-w /var/log/audit/ -p wra -k auditlog` (que registra quién los toca), permisos `0600` con `log_group`, `-e 2`, y sobre todo **envío en tiempo real a un host remoto** vía `audisp-remote`, que es la única defensa real contra un root que borre el log local.

**5.6** Porque AIDE **0.17 renombró directivas de configuración**. `database` pasó a `database_in`, se agregó `database_new`, `verbose` se dividió en `log_level` y `report_level`, y `summarize_changes`/`grouped` pasaron a `report_summarize_changes`/`report_grouped`. Debian 12 trae 0.17.x y RHEL 9 trae 0.16.x, así que un `aide.conf` no es portable entre ambos sin ajuste. Regla práctica: comprobar `aide -v` antes de escribir la configuración y validar siempre con `aide --config-check`.

**5.7** El `atime` cambia con cada **lectura**. Incluirlo hace que la mera ejecución de un binario, o el propio escaneo de AIDE en sistemas montados sin `relatime`/`noatime`, marque el archivo como modificado — el reporte se llena de cambios que no significan nada y se pierde la señal. Además, en sistemas con `noatime` el atributo ni siquiera se actualiza, con lo cual el control es inconsistente. Para binarios interesa `mtime`, `ctime` y los hashes; `atime` sólo es útil en investigaciones puntuales y siempre montando la evidencia en sólo lectura.

---

### Ejercicio 6

**6.1** `--update` descarga desde los mirrors las **bases de datos de firmas** de rkhunter (`programs_bad.dat`, `backdoorports.dat`, `suspscan.dat`, `mirrors.dat`, `i18n`): es lo que mantiene actualizado el conocimiento sobre rootkits. `--propupd` regenera `/var/lib/rkhunter/db/rkhunter.dat` con las **propiedades actuales de los archivos del host** (hash, inode, permisos, tamaño, fechas), es decir, redefine la línea base como "lo que hay ahora es correcto". `--propupd` **nunca** debe correrse automáticamente: si el host ya está comprometido, bendice el binario troyanizado como estado legítimo y el control queda anulado permanentemente. `--update` sí puede automatizarse.

**6.2** Con `PKGMGR=DPKG` (o `RPM`), rkhunter deja de comparar contra su propia base local y valida los hashes y las propiedades contra la **base de datos del gestor de paquetes** — que a su vez está firmada por el repositorio y se corresponde con el contenido publicado por el distribuidor. Eso mitiga el problema de `--propupd`: aunque un atacante regenere la base local, el hash del paquete no coincide y el warning persiste. También elimina el aluvión de falsos positivos después de cada actualización, porque el gestor de paquetes conoce el hash nuevo. Su límite: sólo cubre archivos que pertenecen a un paquete.

**6.3** El procedimiento correcto es: (1) confirmar que los archivos reportados corresponden a paquetes que efectivamente se actualizaron — `dpkg -S`/`rpm -qf` sobre cada ruta y contraste con `/var/log/apt/history.log` o `dnf history`; (2) verificar la integridad contra el gestor (`debsums -c`, `rpm -Va`); (3) recién entonces `rkhunter --propupd`. El atajo peligroso es correr `--propupd` directamente porque "son de la actualización": si entre medio hubo un archivo modificado por otra causa, queda incorporado a la línea base sin haber sido mirado nunca. Con `PKGMGR` configurado el problema desaparece en gran medida.

**6.4** Debian aplica una política de "sin acceso a red por defecto" a las herramientas del sistema: `WEB_CMD="/bin/false"` impide que rkhunter descargue nada por su cuenta, dejando la actualización de firmas al mantenedor del paquete y al ciclo de `apt`. Para un host sin salida a internet la consecuencia práctica es que hay que actualizar por otro camino: replicar los mirrors internamente y apuntar `MIRRORS_MODE`/`UPDATE_MIRRORS` a ellos, o distribuir `/var/lib/rkhunter/db/` desde un host que sí tenga salida, con verificación de integridad. Dejar `WEB_CMD` en `/bin/false` sin ningún reemplazo significa firmas congeladas en la fecha del paquete.

**6.5** `/etc/rkhunter.conf` pertenece al paquete: una actualización puede sobrescribirlo o disparar un conflicto de configuración (`ucf`/`.rpmnew`), y los cambios locales se pierden o quedan huérfanos. `/etc/rkhunter.conf.local` se lee **después** del principal, no lo toca el paquete y sobrescribe cualquier directiva. Además concentra en un solo archivo todo lo que es decisión del sitio —whitelists, destinatario de correo, tests desactivados—, lo que hace auditable el conjunto de excepciones. Cada línea de whitelist debería llevar el comentario que la justifica.

**6.6** `APT_AUTOGEN="true"` hace que un hook de APT ejecute `rkhunter --propupd` automáticamente después de cada instalación o actualización de paquetes, para evitar la avalancha de warnings de la pregunta 6.3. El riesgo es exactamente el de `--propupd` automático: cualquier archivo modificado en la ventana de la actualización —incluido un binario troyanizado plantado por un atacante que espere el próximo `apt upgrade`— queda incorporado a la línea base sin revisión humana. La alternativa segura es `APT_AUTOGEN="false"` con `PKGMGR=DPKG`, que resuelve el ruido sin ceder la línea base.

---

### Ejercicio 7

**7.1** Es un **falso positivo**. El test `bindshell` busca puertos en escucha que históricamente usaron backdoors conocidos; el 465 está en esa lista (lo usó un backdoor antiguo) y es también el puerto estándar de SMTPS. La verificación: identificar el proceso que escucha y su procedencia — `ss -tlnp 'sport = :465'`, luego `dpkg -S`/`rpm -qf` sobre el ejecutable, y confirmar que el binario coincide con el paquete (`debsums -c postfix`, `rpm -V postfix`). Si el listener es `master`/`postfix` provisto por el paquete y verificado, se documenta la excepción. Nunca se "silencia" sin esa comprobación.

**7.2** `chkproc` compara la lista de PIDs que devuelve `readdir()` sobre `/proc` contra la que obtiene recorriendo el espacio de PIDs con `chdir()` a `/proc/<pid>` directamente (y contra la salida de `ps`). Un rootkit LKM que engancha `getdents` para ocultar procesos aparece como discrepancia: el PID responde pero no se lista. El falso positivo surge porque las dos enumeraciones **no son atómicas**: si un proceso nace o muere entre una y otra —lo habitual en un host con muchos forks, contenedores o hilos—, aparece en una lista y no en la otra. Se distingue repitiendo el test y verificando el PID reportado con `ls -l /proc/<pid>/exe`.

**7.3** Garantiza que los comandos auxiliares que `chkrootkit` invoca (`ps`, `ls`, `netstat`, `find`, `strings`, `awk`, `sed`, `egrep`…) provienen del medio de confianza y no de los binarios potencialmente troyanizados del host, eliminando la clase de evasión en la que el rootkit reemplaza `ps` o `ls`. **No** garantiza nada frente a un rootkit en **espacio de kernel**: si el LKM engancha `getdents`, `read` o la tabla de syscalls, los binarios limpios reciben datos ya falsificados y el resultado es igualmente engañoso. Contra esa clase de compromiso la única respuesta confiable es analizar el disco desde un sistema arrancado externamente.

**7.4** (1) *Fuente de verdad*: chkrootkit compara contra firmas y contra vistas cruzadas del sistema en el momento; rkhunter mantiene además una **línea base persistente** de propiedades de archivos, lo que le permite detectar cambios sin conocer la firma del atacante. (2) *Integración con el sistema*: rkhunter puede validar contra el gestor de paquetes (`PKGMGR`) y revisa configuración (SSH, `passwd`, cuentas UID 0); chkrootkit no. (3) *Alcance y conjunto de firmas*: los catálogos de rootkits de ambos proyectos son distintos y se solapan sólo parcialmente, y chkrootkit incluye comprobaciones específicas de `wtmp`/`lastlog`/`utmp` (`chkwtmp`, `chklastlog`, `chkutmp`) que rkhunter no replica. Sus falsos positivos también son distintos, lo que hace que la coincidencia entre ambos sea señal fuerte.

**7.5** Porque `chkrootkit -q` sigue emitiendo un conjunto estable de líneas informativas y falsos positivos propios de cada host (rutas `.build-id`, el sniffer de NetworkManager, el puerto de SMTPS). Enviadas por correo cada día, esas líneas entrenan al operador a ignorar el mensaje, y el hallazgo real pasa desapercibido. `DIFF_MODE` compara la salida contra la de la ejecución anterior y sólo notifica **la diferencia**, con lo que un correo significa "algo cambió" — que es la señal accionable. Es el mismo principio que `--rwo` en rkhunter y que `report_level` en AIDE.

---

### Ejercicio 8

**8.1** Porque LMD no le pasa a ClamAV su base de firmas: invoca `clamscan` con parámetros `-d` que apuntan **exclusivamente a los conjuntos de firmas propios de LMD** (`sigs/rfxn.hdb`, `sigs/rfxn.ndb` y, en versiones recientes, las reglas YARA). ClamAV aporta el **motor** —rápido, en C— pero no su `main.cvd`/`daily.cvd`. EICAR es una firma de ClamAV, no de LMD, así que `clamscan` sin `-d` la detecta y `maldet` no. Consecuencia operativa: LMD y ClamAV son complementarios, no sustitutos; si se quiere cobertura de malware genérico hay que correr también `clamscan`/`clamdscan` con las firmas de ClamAV.

**8.2** `quarantine_hits="1"` **mueve** el archivo detectado al directorio de cuarentena (`/usr/local/maldetect/quarantine`), preservándolo íntegro y registrándolo en la sesión del escaneo, de donde se puede restaurar con `maldet -s <SCANID>`. `quarantine_clean="1"` intenta además **limpiar** el archivo, es decir, remover la porción maliciosa inyectada y devolverlo a su lugar. Es peligroso porque la limpieza es heurística: sobre un archivo de aplicación legítimo con código inyectado puede dejar un archivo corrupto o funcionalmente distinto, y sobre un falso positivo modifica contenido legítimo. Además destruye evidencia forense del artefacto original. Sin backups verificados no debe activarse.

**8.3** `inotify_base_watches` ajusta `fs.inotify.max_user_watches`, el número máximo de inodes que un usuario puede vigilar simultáneamente. Cada archivo y directorio monitoreado consume un watch y memoria de kernel no paginable. Al agotarse, `inotifywait` falla al armar los watches y el monitor **deja de cubrir parte del árbol en silencio**: no hay error visible en el escaneo, simplemente los eventos de esas rutas nunca llegan. El síntoma se ve en `/usr/local/maldetect/logs/inotify_log` y comparando el conteo de rutas monitoreadas contra el real. Es la falla más traicionera de LMD en modo monitor, porque se presenta como "todo limpio".

**8.4** Porque `-a` escanea **todo** el árbol en cada corrida: sobre 400 GB, eso significa horas de CPU y de E/S diarias, presión sobre la caché de página y un ciclo de detección tan lento que pierde valor. `-r ruta 2` limita el escaneo a los archivos **modificados en los últimos 2 días**, que es exactamente la población donde puede haber aparecido una webshell nueva, y reduce el trabajo en órdenes de magnitud. La combinación habitual es `-r` diario y `-a` completo semanal o mensual, más el monitor inotify para cobertura en tiempo real. La limitación de `-r` es que depende de `mtime`, que un atacante con permisos puede falsificar con `touch` — de ahí que no reemplace al escaneo completo periódico.

**8.5** No hay contradicción: cubren **dominios distintos**. LMD busca contenido malicioso conocido —webshells, backdoors en scripts, inyecciones— en árboles de datos de usuario, comparando contra firmas; no tiene línea base del sistema ni firmas de los binarios de la distribución. AIDE no sabe nada de "malicioso": detecta que un archivo **cambió respecto de una línea base**, sin importar la causa. Un binario de sistema troyanizado a medida no tiene firma en ningún catálogo y LMD no lo verá jamás; AIDE lo detecta al primer chequeo. A la inversa, una webshell PHP nueva en `/var/www` es un archivo agregado que AIDE reporta sólo si esa ruta está en la política, y sin decir qué es. Los tres controles del tema —integridad, firmas, auditoría de syscalls— se solapan poco a propósito.

**8.6** `scan_min_filesize="24"` hace que LMD ignore archivos menores a 24 bytes. Es una optimización razonable, pero define un umbral conocido y trivialmente explotable: un *dropper* o un *stager* de menos de 24 bytes —`<?php eval($_GET[0]);` cabe holgadamente— pasa sin ser examinado. Cualquier umbral de tamaño mínimo o máximo (`scan_max_filesize`) es una superficie de evasión documentada; hay que fijarlos entendiendo que son un compromiso de rendimiento explícito, no un ajuste neutro, y compensarlos con controles que no dependan del tamaño (integridad del árbol, permisos de escritura, auditoría de creación de archivos).

---

### Ejercicio 9

**9.1** Cron envía por correo **toda** salida estándar y de error del comando, sin distinguir hallazgo de ruido. Eso genera un correo diario aunque no pase nada —que el operador aprende a borrar sin leer— y, peor, mezcla mensajes de progreso con hallazgos reales. Con `MAILTO=""` la salida de cron se descarta y el script decide: manda correo **sólo si `rc != 0`**, con un asunto que ya contiene host, código y fecha, y siempre deja registro en syslog. La señal queda binaria y accionable.

**9.2** Le indica a systemd que los códigos de salida `0` y `1` son ejecuciones **exitosas**. El script usa `1` para "corrió bien, encontró hallazgos", que es un resultado legítimo, no una falla de ejecución. Sin esa línea, cada día con hallazgos dejaría la unidad en estado `failed`, que es indistinguible de "el script no pudo correr": se pierde la capacidad de detectar que el control dejó de funcionar. Con ella, `systemctl is-failed hids-daily.service` responde exclusivamente por fallas reales (código `2`, o el binario ausente) y puede alimentar el monitoreo.

**9.3** A favor: un horario exacto y publicado permite a un atacante con presencia en el host programar su actividad alrededor de la ventana de escaneo —plantar el artefacto después del chequeo y retirarlo antes del siguiente—, y en una flota, hace que todos los hosts golpeen el almacenamiento compartido a la misma hora. El jitter elimina ambas cosas. En contra: introduce incertidumbre sobre cuándo se ejecutó y complica la correlación entre hosts y con otros procesos batch, y si el retraso es grande frente a la frecuencia, la separación entre ejecuciones consecutivas varía mucho. Media hora sobre una cadencia diaria es un compromiso razonable; lo importante es que el momento real quede registrado (`journalctl`), no que sea predecible.

**9.4** Detecta que el **control dejó de ejecutarse**. La ausencia de hallazgos y la ausencia del control producen exactamente el mismo silencio si sólo se notifican los hallazgos; un atacante que deshabilite el timer, borre el `cron.d` o rompa el script obtiene silencio permanente y nadie lo nota. La línea de "clean run" convierte esa condición en observable: una alerta de monitoreo del tipo "no hubo evento `hids` en las últimas 26 horas" detecta tanto la sabotaje como la falla operativa. Es el patrón de *heartbeat* / *dead man's switch*, y aplica a todo control de seguridad automatizado.

**9.5** Porque `/etc/cron.daily/` se ejecuta a través de `run-parts`, típicamente bajo `anacron`, con un retraso arbitrario tras el arranque y en **serie con todos los demás jobs diarios** — `logrotate`, `apt`, `updatedb`, `man-db`. Un escaneo AIDE de varios minutos con E/S intensa atrasa toda la cadena, y a la inversa, un `updatedb` o un `apt upgrade` corriendo justo antes hace que AIDE reporte cambios provocados por el propio mantenimiento. Además no hay control fino del horario, ni código de salida útil, ni jitter. Un `cron.d` con horario propio, o mejor un timer de systemd, resuelve las cuatro cosas.

**9.6** La debilidad es que **todo corre en el host que se está evaluando**: el atacante con root puede modificar `hids-daily`, borrar el `cron.d`, desactivar el timer, reescribir `aide.db`, correr `rkhunter --propupd` y editar el syslog local. Los tres controles quedan bajo su control. La arquitectura que lo corrige separa la evaluación del sujeto evaluado: **envío inmediato de los eventos de auditoría a un colector remoto** (`audisp-remote`) para que el registro salga del host antes de que puedan borrarlo; **base de AIDE y binario en medio de sólo lectura o fuera del host**, con la comparación ejecutada desde un snapshot o un LiveCD; y **monitoreo externo del heartbeat**, para que el silencio sea una alerta y no un éxito aparente. Ningún HIDS puramente local sobrevive a un adversario con root informado — su valor es detectar al descuidado y elevar el costo del sigiloso.

---

### Ejercicio 10

**10.1** No falló. `oscap xccdf eval` usa tres códigos: **0** = todas las reglas evaluadas pasaron; **1** = error de ejecución (contenido inválido, archivo ausente, error de sintaxis); **2** = la evaluación se completó correctamente pero **al menos una regla resultó `fail`**. Es la convención inversa a la intuitiva y rompe cualquier `set -e` o pipeline de CI que trate distinto de cero como error: hay que distinguir explícitamente `1` de `2`.

**10.2**
- **XCCDF** (*Extensible Configuration Checklist Description Format*): el **checklist**. Define reglas, perfiles, títulos, severidades, referencias a normativa y qué hay que comprobar — pero no cómo.
- **OVAL** (*Open Vulnerability and Assessment Language*): las **definiciones de estado**. Describe de forma declarativa cómo se determina si una condición del sistema se cumple (que un paquete esté instalado, que un parámetro tenga un valor). Es lo que el motor ejecuta.
- **CPE** (*Common Platform Enumeration*): la **identificación de plataforma**. Permite que una regla se aplique sólo a la plataforma correcta.
- **ARF** (*Asset Reporting Format*): el formato de **resultados**, que empaqueta el contenido evaluado junto con los resultados y la identificación del activo, de modo que el reporte sea reproducible y auditable a posteriori.
El **source data stream** (SDS) es el contenedor único que agrupa XCCDF, OVAL, CPE y CVE en un solo archivo (`ssg-*-ds.xml`).

**10.3** Porque `--remediate` ejecuta los *fixes* del perfil **sin revisión previa**, y esos fixes modifican configuración del sistema en bloque: pueden endurecer parámetros de SSH y dejar afuera al administrador, cambiar montajes, deshabilitar servicios de los que dependen aplicaciones, reescribir reglas de firewall o de auditoría. Un perfil como STIG contiene cientos de reglas pensadas para una construcción desde cero, no para un host en servicio. El flujo recomendado es: evaluar y guardar el ARF → `oscap xccdf generate fix` para producir el script bash o el playbook Ansible → **revisar el diff regla por regla** → aplicar en un entorno equivalente de prueba → aplicar en producción por ventana de cambio con rollback → **reevaluar** para confirmar. La remediación por Ansible es preferible porque es idempotente y revisable como código.

**10.4** OpenSCAP evalúa **cumplimiento de configuración y exposición a vulnerabilidades conocidas** contra un estándar declarado: responde "¿está el sistema configurado como debe?" y "¿tiene paquetes con CVEs abiertos?". AIDE evalúa **integridad respecto de una línea base propia del host**: responde "¿cambió algo desde la última vez?". Un binario troyanizado lo detecta **AIDE** (cambia el hash; OpenSCAP no tiene ninguna regla sobre el contenido de ese archivo). Un `sshd_config` que permite login de root lo detecta **OpenSCAP** (es una regla del benchmark), mientras que AIDE sólo diría que el archivo cambió — y si el archivo vino así desde la instalación, ni eso. Son controles de fase distinta: OpenSCAP es preventivo y de cumplimiento, AIDE es detectivo.

**10.5** **CCE** (*Common Configuration Enumeration*) identifica de forma unívoca un **ítem de configuración** — "auditd debe estar habilitado" — y es lo que permite trazar una regla del escaneo hasta el control de una normativa (CIS, STIG, PCI-DSS) de forma estable entre versiones del contenido. **CVE** (*Common Vulnerabilities and Exposures*) identifica una **vulnerabilidad concreta en un software concreto**. La diferencia práctica: un CCE nunca se "parchea", se cumple o no se cumple según la configuración; un CVE se remedia actualizando el paquete. En un data stream, las reglas XCCDF llevan CCE y el contenido OVAL de vulnerabilidades lleva CVE.

---

### Ejercicio 11

**11.1** El artefacto **(d)**, la clave SSH agregada a `/root/.ssh/authorized_keys`, sí queda cubierto porque la política incluye `/root CONF_FILE`. El que **no** aparece bajo esa política es el artefacto **(a)** si se hubiera colocado fuera de las rutas listadas — con la política del Ejercicio 5, `/usr/local BIN_STRICT` sí lo cubre. El hueco real de esa política es `/tmp`, `/var/tmp`, `/dev/shm` y `/home` (que está declarado con `=`, sin recursión): un binario setuid en `/home/usuario/.cache/` o en `/var/tmp` no genera ninguna entrada. La corrección no es agregar `/home` recursivo —demasiado volátil— sino combinar una regla acotada al problema con un control complementario:
```
/var/tmp    DEV_NODE
/dev/shm    DEV_NODE
```
más un barrido periódico `find / -xdev -perm -4000 -type f` contra una lista blanca, y montar esos directorios con `nosuid,nodev,noexec`, que **elimina** la clase de ataque en vez de detectarla.

**11.2**
- *Latencia de detección*: **auditd** (tiempo real, el registro se emite en el syscall) → **rkhunter** y **AIDE** (ambos por ejecución programada, típicamente diaria; iguales en latencia, determinada por el cron, no por la herramienta).
- *Capacidad de atribución*: **auditd** (`auid`, `ses`, `pid`, `ppid`, `exe`, `tty` — dice **quién**, **desde dónde** y **con qué**) → muy por encima de **AIDE** y **rkhunter**, que sólo constatan el estado resultante y no tienen ninguna información sobre el actor ni el momento exacto.
Los órdenes **coinciden**, y no por casualidad: auditd observa la acción, los otros dos observan el efecto. Por eso auditd no es opcional en un esquema de respuesta a incidentes — es el único de los tres que produce evidencia atribuible. Su contrapartida es el costo: volumen de log, impacto en rendimiento y necesidad de envío remoto.

**11.3** Dispara el test de **archivos y directorios ocultos** (`hidden_files` / la comprobación de nombres que empiezan con punto en directorios del sistema) y el test de **propiedades de archivos** en tanto binario no perteneciente a ningún paquete, además del de **archivos setuid** al comparar contra la lista conocida. El administrador descuidado los silencia con `ALLOWHIDDENFILE=/usr/local/sbin/.systemd-hostnamed` o desactivando el test con `DISABLE_TESTS=hidden_files` en `rkhunter.conf.local`. Es el motivo por el que **cada línea de whitelist debe llevar el comentario que la justifica y una fecha**: las whitelists son la superficie por la que un HIDS se degrada silenciosamente, y son el primer lugar donde mira un revisor.

**11.4** Porque las reglas no vigilan el **programa**, vigilan los **archivos**. `-w /etc/passwd -p wa -k identity` dispara en cualquier `open` con intención de escritura sobre esa ruta, sin importar qué proceso la haga: `useradd`, `vipw`, `vim`, un script Python o un binario del atacante. Esa es la propiedad que hace útiles los watches y la razón por la que se vigilan objetos y no ejecutables: una regla `-F exe=/usr/sbin/useradd` se evadiría escribiendo el archivo con cualquier otra herramienta, mientras que la regla sobre la ruta no tiene rodeo — salvo montando el archivo en otro lado o escribiendo el dispositivo de bloque directamente, que son operaciones que a su vez se vigilan aparte.

**11.5** El orden correcto es: **primero verificar y documentar que el sistema quedó limpio**, y sólo después regenerar las líneas base. En concreto: eliminar los artefactos → correr `aide --check` y `rkhunter --check` y confirmar que los únicos hallazgos son exactamente los cambios de la limpieza esperados → registrar esa salida como evidencia → recién entonces `aide --update` y `rkhunter --propupd`. El orden inverso —regenerar primero— **destruye la evidencia**: la nueva línea base pasa a describir el estado actual sea cual sea, de modo que si quedó un artefacto no advertido (un archivo que no se recordaba, una modificación colateral, un segundo mecanismo de persistencia), queda incorporado como legítimo y **ningún chequeo futuro volverá a reportarlo**. Es el mismo error que corregir `--propupd` automático en cron, aplicado al procedimiento manual: la línea base sólo se actualiza sobre un estado que fue verificado, nunca sobre un estado que se asume.

</details>

---

## Fuentes

- LPI — Exam 303 Objectives (303-300, v3.0): <https://www.lpi.org/our-certifications/exam-303-objectives/>
- Linux Audit — documentación del proyecto: <https://github.com/linux-audit/audit-documentation/wiki>
- `auditctl(8)`: <https://man7.org/linux/man-pages/man8/auditctl.8.html>
- `auditd.conf(5)`: <https://man7.org/linux/man-pages/man5/auditd.conf.5.html>
- `ausearch(8)`: <https://man7.org/linux/man-pages/man8/ausearch.8.html> · `aureport(8)`: <https://man7.org/linux/man-pages/man8/aureport.8.html>
- AIDE — sitio y manual: <https://aide.github.io/> · <https://aide.github.io/doc/>
- Rootkit Hunter: <https://rkhunter.sourceforge.net/>
- chkrootkit: <https://www.chkrootkit.org/>
- Linux Malware Detect (R-fx Networks): <https://www.rfxn.com/projects/linux-malware-detect/>
- OpenSCAP — manual de usuario de `oscap`: <https://static.open-scap.org/openscap-1.3/oscap_user_manual.html>
- SCAP Security Guide (ComplianceAsCode): <https://complianceascode.github.io/content-pages/>
- NIST — SCAP specifications: <https://csrc.nist.gov/projects/security-content-automation-protocol>