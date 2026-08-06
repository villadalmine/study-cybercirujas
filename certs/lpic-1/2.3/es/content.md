# 2.3 Administrative Tasks

## 1. Motivaci\u00f3n y Problema Arquitect\u00f3nico de Producci\u00f3n

A medida que las plataformas crecen, el paradigma tradicional de administrar usuarios manualmente o programar tareas peri\u00f3dicas conect\u00e1ndose por SSH a cada servidor se vuelve insostenible (y peligroso). Para un Platform Architect o SRE, los "Administrative Tasks" como la gesti\u00f3n de identidades (IAM local), la programaci\u00f3n de *cronjobs* y la localizaci\u00f3n (locales, timezones) son desaf\u00edos de infraestructura inmutable y cumplimiento de auditor\u00edas (compliance).

El problema arquitect\u00f3nico de la gesti\u00f3n de usuarios locales (`/etc/passwd`, `/etc/shadow`) radica en la desincronizaci\u00f3n de credenciales y la proliferaci\u00f3n de claves SSH hu\u00e9rfanas tras la rotaci\u00f3n de personal. Adem\u00e1s, la automatizaci\u00f3n de tareas (como rotaci\u00f3n de logs, backups o health-checks) usando el demonio cl\u00e1sico `cron` presenta un riesgo de visibilidad nula: si un cron falla silenciosamente, el SRE no se entera hasta que el disco se llena o la base de datos se corrompe. Moverse a *systemd timers* provee aislamiento de recursos (cgroups), logs estructurados (journald) y garant\u00edas de ejecuci\u00f3n, resolviendo las deficiencias de `cron` en entornos modernos.

## 2. Comparativas T\u00e9cnicas y Trade-offs

### Automatizaci\u00f3n de Tareas: Cron vs. Systemd Timers

| Caracter\u00edstica | `cron` / `crontab` | `systemd.timer` | Caso de Uso SRE |
| :--- | :--- | :--- | :--- |
| **Arquitectura** | Demonio aislado leyendo archivos texto (spool). | Integrado nativamente en el Init System (`systemd`). | `systemd` para tareas de plataforma; `cron` relegado a legacy. |
| **Logging y Trazabilidad** | Logs b\u00e1sicos en `/var/log/syslog` o e-mails a root (MTA). | Trazabilidad nativa v\u00eda `journalctl -u mi-tarea.service`. | Timers: Indispensables para poder disparar alertas v\u00eda Promtail/Loki basadas en fallos. |
| **Control de Recursos (Cgroups)** | Nulo. Un script de cron puede devorar el 100% de CPU y RAM. | Total. Se pueden imponer l\u00edmites (`MemoryMax`, `CPUQuota`) a la tarea. | Timers: Previenen que un backup programado tire abajo la base de datos de producci\u00f3n. |
| **Granularidad y Eventos** | Restringido al minuto. Basado solo en reloj en tiempo real. | Precisi\u00f3n de milisegundos. Basado en reloj o eventos (ej. 10m tras el boot). | Timers: Manejan dependencias complejas (ej. "esperar que la red levante"). |

### Gesti\u00f3n de Identidad Local vs Centralizada

| Modelo | Definici\u00f3n | Trade-offs en Producci\u00f3n |
| :--- | :--- | :--- |
| **IAM Local** (`useradd`, `/etc/shadow`) | Usuarios definidos est\u00e1ticamente en cada nodo. | Dif\u00edcil de auditar. Ideal solo para usuarios de sistema (daemon users) como `nginx` o `postgres`. |
| **IAM Centralizado** (LDAP / OIDC / Teleport) | Identidad delegada a un proveedor central (SSO). | Punto \u00fanico de fallo (SPOF) solucionable con cach\u00e9s locales (SSSD). Requerido para compliance (SOC2/ISO27001). |

## 3. Manifiestos, Configuraci\u00f3n e Infraestructura

En la ingenier\u00eda de plataforma moderna, las tareas programadas se declaran como unidades de Systemd. A continuaci\u00f3n, definiremos un servicio de backup acoplado a un timer.

### Manifiesto Systemd Service: `/etc/systemd/system/db-backup.service`

```ini
[Unit]
Description=Database Backup Script
Documentation=https://runbooks.company.internal/db-backup
# Requiere que el disco local est\u00e9 montado antes de ejecutarse
Requires=local-fs.target
After=local-fs.target

[Service]
Type=oneshot
# Usuario sin privilegios de root para limitar el impacto (Principio de Menor Privilegio)
User=db-backup-user
Group=db-backup-user
# Evita que el backup sature la I/O y el procesador del nodo
IOSchedulingClass=idle
CPUSchedulingPolicy=idle
ExecStart=/usr/local/bin/execute_pg_dump.sh
# Logs ir\u00e1n directamente al Journal de Systemd
StandardOutput=journal
StandardError=journal
```

### Manifiesto Systemd Timer: `/etc/systemd/system/db-backup.timer`

```ini
[Unit]
Description=Timer for Daily Database Backup

[Timer]
# Ejecutar cada d\u00eda a las 02:00 AM (Timezone del servidor)
OnCalendar=*-*-* 02:00:00
# Si el servidor estaba apagado a las 02:00, ejecuta inmediatamente al prender
Persistent=true
# Retraso aleatorio de hasta 5 minutos para evitar Thundering Herd problem en cl\u00fasters
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
```

## 4. Comandos CLI y Salidas de Terminal Reales

### Gesti\u00f3n de Tareas Programadas (Systemd Timers)

```bash
# Habilitar e iniciar el timer (no el servicio directamente)
$ sudo systemctl enable --now db-backup.timer
Created symlink /etc/systemd/system/timers.target.wants/db-backup.timer -> /etc/systemd/system/db-backup.timer.

# Listar todos los timers activos y cu\u00e1ndo es su pr\u00f3xima ejecuci\u00f3n
$ systemctl list-timers
NEXT                         LEFT          LAST                         PASSED       UNIT                         ACTIVATES
Thu 2023-10-26 02:02:15 UTC  4h 12m left   Wed 2023-10-25 02:04:10 UTC  19h ago      db-backup.timer              db-backup.service
Thu 2023-10-26 06:14:48 UTC  8h left       Wed 2023-10-25 06:14:48 UTC  15h ago      apt-daily-upgrade.timer      apt-daily-upgrade.service

# Inspeccionar los logs estructurados espec\u00edficamente de esa ejecuci\u00f3n (Troubleshooting)
$ journalctl -u db-backup.service --since "1 day ago"
Oct 25 02:04:10 node-01 systemd[1]: Starting Database Backup Script...
Oct 25 02:04:45 node-01 execute_pg_dump.sh[4523]: Backup completed successfully. Size: 14GB.
Oct 25 02:04:45 node-01 systemd[1]: db-backup.service: Succeeded.
```

### Gesti\u00f3n de Usuarios, Grupos y Configuraci\u00f3n de Auditor\u00eda

```bash
# Crear un usuario de sistema (sin home, sin shell interactivo) para correr una aplicaci\u00f3n
$ sudo useradd --system --no-create-home --shell /usr/sbin/nologin prometheus

# Modificar un usuario existente, a\u00f1adi\u00e9ndolo al grupo suplementario 'docker' sin remover otros
$ sudo usermod -aG docker juan

# Bloquear (Lock) una cuenta de emergencia ante compromiso de seguridad (pone un ! en /etc/shadow)
$ sudo passwd -l juan
passwd: password expiry information changed.

# Auditar la expiraci\u00f3n de contrase\u00f1as (pol\u00edticas de seguridad chage)
$ sudo chage -l root
Last password change                                    : Oct 10, 2023
Password expires                                        : never
Password inactive                                       : never
Account expires                                         : never
Minimum number of days between password change          : 0
Maximum number of days between password change          : 99999
Number of days of warning before password expires       : 7
```

### Localizaci\u00f3n e Internacionalizaci\u00f3n (Locales & Timezones)

Para garantizar consistencia en logs de microservicios, los SRE fuerzan UTC universalmente.

```bash
# Ver el estado del reloj y la zona horaria del host
$ timedatectl status
               Local time: Wed 2023-10-25 21:55:10 UTC
           Universal time: Wed 2023-10-25 21:55:10 UTC
                 RTC time: Wed 2023-10-25 21:55:11
                Time zone: Etc/UTC (UTC, +0000)
System clock synchronized: yes
              NTP service: active
          RTC in local TZ: no

# Cambiar forzosamente la zona horaria a UTC (cr\u00edtico en servidores)
$ sudo timedatectl set-timezone Etc/UTC

# Verificar la configuraci\u00f3n de locale actual (el idioma y formato regional)
$ locale
LANG=en_US.UTF-8
LANGUAGE=
LC_CTYPE="en_US.UTF-8"
LC_ALL=
```

## 5. Gu\u00eda de Verificaci\u00f3n y Diagn\u00f3stico de Fallas

1. **Timer de Systemd no dispara el Script**:
   Si tu `systemctl list-timers` dice que pas\u00f3 el tiempo pero no ocurri\u00f3 nada.
   *Diagn\u00f3stico:* Revisa si existe el archivo `.service` hom\u00f3nimo. Un `db-backup.timer` busca autom\u00e1ticamente ejecutar `db-backup.service`. Si el nombre del servicio difiere, debes especificarlo en el timer bajo `[Timer]` con `Unit=otro-nombre.service`. Verifica tambi\u00e9n que el `.timer` est\u00e9 habilitado (enabled).
   
2. **Cronjob falla silenciosamente o devuelve comandos "not found"**:
   Un script bash corre perfecto cuando lo ejecutas t\u00fa en la consola, pero falla desde `/etc/crontab`.
   *Causa:* `cron` ejecuta los scripts con un entorno (variables de entorno) extremadamente limitado. Su `$PATH` suele ser solo `/usr/bin:/bin`, omitiendo rutas como `/usr/local/bin` o binarios en `/opt`.
   *Resoluci\u00f3n:* Dentro de todo script dise\u00f1ado para ser invocado por `cron`, define rutas absolutas a los binarios (`/usr/local/bin/kubectl` en lugar de `kubectl`) o sobrescribe la variable `$PATH` en el crontab o al inicio del script.

3. **Incapacidad de cambiar a un usuario temporalmente (`su`)**:
   Un administrador intenta usar `su - appuser` y obtiene `This account is currently not available.`
   *Diagn\u00f3stico:* El usuario fue creado como usuario de sistema con el shell configurado a `/bin/false` o `/usr/sbin/nologin` por razones de seguridad.
   *Resoluci\u00f3n:* Para debuggear como ese usuario de forma temporal (y leg\u00edtima para un SRE), debes forzar el shell al invocar el comando: `sudo su -s /bin/bash appuser`.

## 6. Referencias

* LPIC-1 Objetivos (Topic 107): [https://www.lpi.org/our-certifications/exam-101-objectives](https://www.lpi.org/our-certifications/exam-101-objectives)
* Systemd Timers Manual: [https://www.freedesktop.org/software/systemd/man/systemd.timer.html](https://www.freedesktop.org/software/systemd/man/systemd.timer.html)
* Managing Users and Groups (Red Hat): [https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/configuring_basic_system_settings/managing-users-and-groups](https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/configuring_basic_system_settings/managing-users-and-groups)