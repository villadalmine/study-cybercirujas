# Guía de Estudio LPI 702: Tema 713.2 – Automatizar Tareas de Administración del Sistema Mediante la Programación de Trabajos

**Certificación:** LPI BSD Specialist (Examen 702-100, Versión 1.0)  
**Tema 713:** Administración Básica del Sistema BSD  
**Objetivo:** 713.2 Automatizar Tareas de Administración del Sistema Mediante la Programación de Trabajos  
**Ponderación:** 3.33  

---

## 1. Motivación y Problema Arquitectónico en Producción

### 1.1 El Desafío Operativo en Infraestructura BSD de Misión Crítica
En entornos de producción BSD de nivel empresarial—que van desde routers núcleo FreeBSD y redes de área de almacenamiento (SANs que utilizan ZFS) hasta firewalls perimetrales OpenBSD—se requiere la ejecución desatendida de tareas administrativas para la resiliencia operativa. Los procesos del sistema como la rotación de logs (`newsyslog`), el depurado de pools ZFS (`zpool scrub`), los informes de auditoría de seguridad (`periodic security`), las actualizaciones de paquetes y los respaldos de bases de datos deben ejecutarse de manera determinista sin intervención humana manual.

Sin embargo, la ejecución no coordinada de trabajos asincrónicos introduce severos riesgos arquitectónicos:
1. **Contención de Recursos y Problema de la Manada Desbocada (Thundering Herd Problem):** La ejecución simultánea de trabajos intensivos en E/S (por ejemplo, respaldos completos de disco junto con el scrub de ZFS y mantenimiento de base de datos) durante horas pico de operación degrada la capacidad de respuesta del sistema, causando la saturación de la profundidad de la cola de almacenamiento y la limitación de CPU (throttling).
2. **Falla Silenciosa y Ausencia de Observabilidad:** Los crontabs estándar envían las salidas de falla a través de Agentes de Transferencia de Correo locales (MTA como `sendmail` o `dma`). En entornos de servidores headless que carecen de entrega activa de buzón local, los trabajos cron fallidos terminan silenciosamente, creando una deriva operativa oculta.
3. **Anomalías de Aislamiento de Entorno:** El demonio `cron(8)` inicializa un entorno reducido (`SHELL=/bin/sh`, `PATH=/usr/bin:/bin` restringido). Los scripts administrativos que dependen de perfiles de inicio de sesión interactivos completos (`.bashrc`, `.zshrc`, `/etc/profile`) fallan en tiempo de ejecución debido a rutas de búsqueda de binarios faltantes o variables de entorno no inicializadas.
4. **Condiciones de Carrera y Ejecuciones Superpuestas:** Las tareas programadas de larga duración que exceden su intervalo de invocación corren el riesgo de generar procesos hijo concurrentes. Sin bloqueo de concurrencia (por ejemplo, `lockf(1)` en BSD o archivos de bloqueo atómicos), las tareas duplicadas colisionan en archivos de base de datos bloqueados o descriptores de archivos compartidos, arriesgando la corrupción de datos.

---

### 1.2 Mecánica de la Programación de Trabajos en Sistemas BSD

#### La Arquitectura del Demonio `cron(8)` en BSD
El demonio `cron(8)` de BSD se ejecuta continuamente en segundo plano como un servicio del sistema inicializado durante el procesamiento del runlevel por `/etc/rc.d/cron`. A diferencia de las implementaciones estándar de Linux que se despiertan cada 60 segundos mediante sondeo (polling), el `cron(8)` de BSD calcula el tiempo exacto a esperar hasta el próximo límite de minuto programado, llamando a `sleep()` o `nanosleep()` en consecuencia.

```
                      +-----------------------------+
                      |    /etc/rc.d/cron (Daemon)  |
                      +--------------+--------------+
                                     |
                +--------------------+--------------------+
                |                                         |
    +-----------v-----------+                 +-----------v-----------+
    |  System Crontab File  |                 |     User Spool Tabs   |
    |    /etc/crontab       |                 |   /var/cron/tabs/*    |
    +-----------+-----------+                 +-----------+-----------+
                |                                         |
                | (Includes 'who' field)                  | (No 'who' field)
                +--------------------+--------------------+
                                     |
                             +-------v-------+
                             |   fork() /    |
                             |   setuid()    |
                             +-------+-------+
                                     |
                             +-------v-------+
                             | Exec Command  |
                             | via /bin/sh   |
                             +---------------+
```

Cuando ocurren cambios en los archivos spool del usuario (`/var/cron/tabs/<username>`), el comando `crontab(1)` actualiza la marca de tiempo de modificación del archivo (`mtime`). El `cron(8)` de BSD verifica la marca de tiempo del directorio cada minuto y recarga dinámicamente las tablas modificadas en memoria sin requerir un reinicio del demonio o una señal `SIGHUP`.

#### La Arquitectura del Subsistema `periodic(8)`
FreeBSD y NetBSD cuentan con una capa de abstracción sobre las entradas crontab puras: el framework de scripts `periodic(8)`. En lugar de dispersar docenas de scripts shell discretos a lo largo de líneas de crontab, el mantenimiento del sistema se modulariza en cuatro niveles de ciclo de vida:
- **`daily`**: Limpia `/tmp`, rota los logs del sistema, verifica el estado del pool ZFS, informa el uso del espacio en disco.
- **`weekly`**: Reconstruye las bases de datos de `locate(1)`, verifica las páginas de `catman`, ejecuta comprobaciones de seguridad.
- **`monthly`**: Audita la expiración de cuentas de usuario, verifica la contabilidad del sistema (`acct`).
- **`security`**: Analiza los logs de auth, valida los checksums de archivos mediante auditorías `setuid`, y verifica el estado de las interfaces de red.

Los valores predeterminados del sistema residen en `/etc/defaults/periodic.conf`. Los operadores configuran anulaciones específicas del sitio strictly dentro de `/etc/periodic.conf` o `/etc/periodic.conf.local`.

---

## 2. Comparativas Técnicas y Tablas de Sopesamiento (Trade-off)

### 2.1 Paradigmas de Programación de Trabajos en BSD y Arquitecturas Cloud-Native

| Métrica / Dimensión | Crontab de Usuario (`crontab -e`) | Crontab del Sistema (`/etc/crontab`) | Framework BSD `periodic(8)` | Ejecución Única (`at(1)` / `batch(1)`) | Cloud-Native (`batch/v1 CronJob`) |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Contexto de Ejecución** | Spool de usuario sin privilegios o privileged user spool | Archivo gestionado por root a nivel de sistema | Framework de mantenimiento del sistema estructurado | Ejecución de cola shell diferida | Motor de Pods contenedorizados |
| **Especificación de Sintaxis** | 5 campos de tiempo + `command` | 5 campos de tiempo + `user` + `command` | Controlado mediante la configuración de `/etc/periodic.conf` | Cadena de tiempo absoluta/relativa (`now + 2 hours`) | Sintaxis Cron + esquema de especificación de Kubernetes |
| **Control de Concurrencia** | Manual (`lockf` / script wrapper) | Manual (`lockf` / script wrapper) | Ejecución serial dentro de las fases periódicas | Integrado mediante límites de promedio de carga (`batch`) | Nativo (`Allow`, `Forbid`, `Replace`) |
| **Manejo del Entorno** | Mínimo básico (`PATH=/usr/bin:/bin`) | Variables de nivel superior declaradas explícitamente | Gestionado por el contexto del shell de `/etc/periodic.conf` | Captura el entorno del shell del invocador actual | Env de imagen de contenedor y ConfigMaps |
| **Notificación de Fallas** | Correo electrónico de MTA local al propietario | Correo electrónico de MTA local a `MAILTO` | Informe agregado generado y enviado por correo | Correo electrónico de MTA local al creador del trabajo | Eventos de K8s, sondas de estado, alertmanager |
| **Control de Acceso** | Restringido por `/var/cron/allow` o `/var/cron/deny` | Restringido a `root` | Restringido a `root` | Restringido por `/var/cron/at.allow` o `at.deny` | RBAC (`Role`/`RoleBinding`) |

---

### 2.2 Matriz de Sopesamiento de Control de Ejecución

| Utilidad | Caso de Uso Principal | Ejecución Sensible a la Carga | Persistente Entre Reinicios | Gestión de Procesos / Señales |
| :--- | :--- | :--- | :--- | :--- |
| **`cron(8)`** | Tareas recurrentes y deterministas | No (Se activa estrictamente según el horario programado) | Sí (Analizado desde archivos crontab al iniciar) | Genera un shell hijo (`/bin/sh -c`) por línea |
| **`at(1)`** | Mantenimiento diferido de una sola vez | No (Se activa strictly a la hora objetivo programada) | Sí (Persistido en `/var/at/jobs/`) | Escribe un archivo spool, ejecutado por `atrun` / `cron` |
| **`batch(1)`** | Compilación en segundo plano, E/S pesada | Sí (Se activa solo cuando el promedio de carga cae por debajo del umbral) | Sí (Persistido en `/var/at/jobs/`) | Monitoreado por el motor de colas de ejecución |

---

## 3. Manifiestos Completos de Infraestructura y Configuración

### 3.1 Crontab del Sistema FreeBSD en Producción (`/etc/crontab`)

Este archivo es sintácticamente válido para sistemas FreeBSD. Note la presencia del 6.º campo que especifica el nombre del usuario ejecutor.

```crontab
# /etc/crontab - System Crontab for FreeBSD
# Shell environment definitions for system-level executions
SHELL=/bin/sh
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin
MAILTO=sysadmin@example.com
HOME=/var/log

# Minute Hour MonthDay Month DayOfWeek User    Command
# ====================================================================================
# Run FreeBSD periodic maintenance suites
0       2       *       *       *       root    periodic daily
30      3       *       *       6       root    periodic weekly
30      5       1       *       *       root    periodic monthly

# ZFS Storage Maintenance: Scrub tank pool on the 1st and 15th of every month
0       1       1,15    *       *       root    /usr/sbin/lockf -s -t 0 /var/run/zfs_scrub.lock /sbin/zpool scrub tank

# Perform hourly log rotation check using newsyslog
0       *       *       *       *       root    /usr/sbin/newsyslog

# Sync system clock against upstream NTP drift every 6 hours if ntpd is inactive
15      */6     *       *       *       root    /usr/sbin/ntpdate -s pool.ntp.org

# Purge expired application cache files safely with concurrency protection
45      4       *       *       *       www     /usr/sbin/lockf -t 0 /var/run/app_cache_purge.lock /usr/local/bin/php /usr/local/www/app/cron.php --purge-cache
```

---

### 3.2 Archivo de Anulación de FreeBSD en Producción `/etc/periodic.conf`

```sh
# /etc/periodic.conf - System periodic configuration overrides
# Maintainer: Platform Infrastructure Engineering

# ------------------------------------------------------------------------------
# Daily System Maintenance Settings
# ------------------------------------------------------------------------------
daily_clean_tmps_enable="YES"                       # Clean /tmp daily
daily_clean_tmps_days="3"                          # Remove files older than 3 days
daily_clean_preserve="system.journal"              # Retain specific system journal files
daily_status_disks_enable="YES"                    # Report disk storage capacity utilization
daily_status_zfs_enable="YES"                      # Detail ZFS pool health status
daily_status_network_enable="YES"                  # Log network interface packet statistics
daily_status_security_enable="YES"                 # Include daily security check output in daily mail

# ------------------------------------------------------------------------------
# Weekly System Maintenance Settings
# ------------------------------------------------------------------------------
weekly_locate_enable="YES"                         # Rebuild locate(1) database
weekly_catman_enable="NO"                          # Disable pre-formatted man pages generation
weekly_status_zfs_enable="YES"                     # Deep weekly ZFS status verification

# ------------------------------------------------------------------------------
# Security Framework Checks
# ------------------------------------------------------------------------------
security_status_chksetuid_enable="YES"             # Audit changes in setuid/setgid binary permissions
security_status_chkmounts_enable="YES"             # Verify changes in file system mount points
security_status_ipfwdenied_enable="YES"           # Report IPFW firewall drop metrics
security_status_loginfailures_enable="YES"         # Report failed authentication attempts from /var/log/auth.log

# Custom Log Output Redirection
daily_output="/var/log/periodic/daily.log"
weekly_output="/var/log/periodic/weekly.log"
monthly_output="/var/log/periodic/monthly.log"
```

---

### 3.3 Script Periódico Personalizado de BSD en Producción (`/usr/local/etc/periodic/daily/999.backup-zfs`)

```sh
#!/bin/sh
#
# /usr/local/etc/periodic/daily/999.backup-zfs
# Production script for daily automated ZFS snapshot creation and retention
#

# If source file exists, load system periodic configuration defaults
if [ -r /etc/defaults/periodic.conf ]; then
    . /etc/defaults/periodic.conf
fi

# Define defaults for custom variables
daily_backup_zfs_enable="${daily_backup_zfs_enable:-NO}"
daily_backup_zfs_pools="${daily_backup_zfs_pools:-tank}"
daily_backup_zfs_keep_days="${daily_backup_zfs_keep_days:-7}"

# Evaluate activation flag
case "$daily_backup_zfs_enable" in
    [Yy][Ee][Ss])
        echo ""
        echo "Running Daily ZFS Snapshot Maintenance:"

        TODAY=$(date -u +%Y%m%d)
        
        for POOL in $daily_backup_zfs_pools; do
            SNAPSHOT_NAME="${POOL}@auto-daily-${TODAY}"
            echo "  --> Creating snapshot: ${SNAPSHOT_NAME}"
            /sbin/zfs snapshot -r "${SNAPSHOT_NAME}"
            if [ $? -eq 0 ]; then
                echo "      [SUCCESS] Snapshot created successfully."
            else
                echo "      [ERROR] Failed to create ZFS snapshot ${SNAPSHOT_NAME}." >&2
            fi
        done
        ;;
    *)
        ;;
esac

exit 0
```

---

### 3.4 Manifiesto Híbrido Cloud-Native de Kubernetes `CronJob` (`cronjob-zfs-sync.yaml`)

Al extender los patrones de gestión de estado de BSD a plataformas empresariales híbridas, la programación cloud-native equivalente se codifica utilizando manifiestos estándar de la API de Kubernetes:

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: zfs-offsite-backup-sync
  namespace: infrastructure
  labels:
    app.kubernetes.io/name: zfs-sync
    app.kubernetes.io/component: storage-backup
spec:
  schedule: "0 4 * * *"
  timeZone: "Etc/UTC"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 5
  startingDeadlineSeconds: 300
  jobTemplate:
    spec:
      backoffLimit: 2
      activeDeadlineSeconds: 3600
      template:
        metadata:
          labels:
            app.kubernetes.io/name: zfs-sync
        spec:
          restartPolicy: OnFailure
          containers:
            - name: zfs-sync-agent
              image: registry.enterprise.internal/sysops/zfs-tools:v1.4.2
              imagePullPolicy: IfNotPresent
              command:
                - /usr/local/bin/zfs-replication.sh
              args:
                - --source-pool=tank/production
                - --remote-target=backup-node.internal.net
                - --retention-days=14
              env:
                - name: LOG_LEVEL
                  value: "INFO"
                - name: METRICS_GATEWAY
                  value: "http://prometheus-pushgateway.monitoring.svc:9091"
              resources:
                requests:
                  cpu: "250m"
                  memory: "256Mi"
                limits:
                  cpu: "1000m"
                  memory: "1Gi"
              securityContext:
                allowPrivilegeEscalation: false
                readOnlyRootFilesystem: true
                runAsNonRoot: true
                runAsUser: 10001
                capabilities:
                  drop:
                    - ALL
```

---

### 3.5 Infraestructura como Código: Playbook de Ansible (`deploy_cron_policy.yml`)

```yaml
---
- name: Deploy BSD Job Automation & Cron Access Controls
  hosts: bsd_servers
  gather_facts: true
  become: true

  tasks:
    - name: Ensure /var/cron/allow contains authorized administrative users
      ansible.builtin.copy:
        dest: /var/cron/allow
        owner: root
        group: wheel
        mode: '0600'
        content: |
          root
          deploy
          sre_automation

    - name: Ensure /var/cron/deny is absent when allow-list policy is enforced
      ansible.builtin.file:
        path: /var/cron/deny
        state: absent

    - name: Configure periodic.conf overrides for ZFS and system checks
      ansible.builtin.blockinfile:
        path: /etc/periodic.conf
        create: true
        owner: root
        group: wheel
        mode: '0644'
        block: |
          daily_clean_tmps_enable="YES"
          daily_status_zfs_enable="YES"
          daily_backup_zfs_enable="YES"
          daily_backup_zfs_pools="tank"

    - name: Deploy custom daily ZFS snapshot periodic script
      ansible.builtin.copy:
        src: files/999.backup-zfs
        dest: /usr/local/etc/periodic/daily/999.backup-zfs
        owner: root
        group: wheel
        mode: '0755'
```

---

## 4. Comandos Reales de la CLI y Salida de Terminal ($)

### 4.1 Administración de Crontabs de Usuario con `crontab(1)`

#### Inspección y Modificación del Crontab Activo
Para editar o listar archivos crontab para el usuario activo o el usuario objetivo (`-u`), se utilizan las flags estándar:

```console
$ crontab -l
# Active User Crontab for user: sre_automation
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin
MAILTO=sre-alerts@example.com

# Check application status every 15 minutes
*/15 * * * * /usr/local/bin/healthcheck.sh > /dev/null
```

```console
$ sudo crontab -u www -l
# Crontab for user: www
0 2 * * * /usr/local/bin/php /usr/local/www/app/artisan schedule:run >> /var/log/www/cron.log 2>&1
```

#### Aplicación del Control de Acceso de Usuario (`/var/cron/allow` vs `/var/cron/deny`)
Cuando un usuario no autorizado intenta invocar `crontab(1)` mientras `/var/cron/allow` está presente:

```console
$ whoami
developer

$ crontab -e
crontab: you (developer) are not allowed to use this program.
```

Verificación de archivos de control de acceso en FreeBSD:

```console
$ ls -la /var/cron/allow /var/cron/deny
ls: /var/cron/deny: No such file or directory
-rw-------  1 root  wheel  28 Aug 6 20:30 /var/cron/allow

$ sudo cat /var/cron/allow
root
sre_automation
deploy
```

---

### 4.2 Administración de Trabajos de Ejecución Única con `at(1)`, `atq(1)`, `atrm(1)` y `batch(1)`

#### Envío de Trabajos Diferidos con `at(1)`
Programación de una tarea para ejecutarse en una marca de tiempo futura específica:

```console
$ at 03:00 tomorrow
at> /sbin/zpool scrub tank
at> /usr/local/bin/notify_slack.sh "Scheduled midnight scrub initiated"
at> <EOT>
Job 14 will be executed using /bin/sh at Fri Aug  7 03:00:00 2026
```

Envío de un trabajo utilizando la notación de tiempo relativo:

```console
$ echo "/usr/local/sbin/pkg upgrade -y" | at now + 2 hours
Job 15 will be executed using /bin/sh at Thu Aug  6 22:37:43 2026
```

#### Envío de Tareas Dependientes de la Carga con `batch(1)`
`batch(1)` programa un trabajo que se ejecuta cuando el promedio de carga del sistema cae por debajo del umbral del sistema (típicamente `1.5` en sistemas BSD):

```console
$ batch
at> /usr/home/sre_automation/build_kernel.sh
at> <EOT>
Job 16 will be executed using /bin/sh
```

#### Inspección y Eliminación de Trabajos (`atq` y `atrm`)
Visualización de la cola de ejecución de trabajos pendientes:

```console
$ atq
Date                    Owner           Queue   Job#
Fri Aug  7 03:00:00 2026 root            c       14
Thu Aug  6 22:37:43 2026 sre_automation  c       15
Thu Aug  6 20:45:00 2026 sre_automation  b       16
```

Eliminación de un trabajo en cola antes de su ejecución:

```console
$ atrm 15
15: removed

$ atq
Date                    Owner           Queue   Job#
Fri Aug  7 03:00:00 2026 root            c       14
Thu Aug  6 20:45:00 2026 sre_automation  b       16
```

---

### 4.3 Ejecución Manual del Mantenimiento del Sistema a través de `periodic(8)`

Para ejecutar scripts periódicos del sistema manualmente para pruebas o ejecución a demanda:

```console
$ sudo periodic daily
Running Daily System Maintenance:
  --> Cleaning /tmp directory...
  --> Rotating log files via newsyslog...
  --> Checking ZFS storage pool health:
  all pools are healthy
  --> Running Security Checks:
  No setuid changes detected.
  --> Completed daily maintenance phase.
```

Para ejecutar un script objetivo específico dentro de la estructura de directorios periódicos:

```console
$ sudo /usr/local/etc/periodic/daily/999.backup-zfs

Running Daily ZFS Snapshot Maintenance:
  --> Creating snapshot: tank@auto-daily-20260806
      [SUCCESS] Snapshot created successfully.
```

---

## 5. Guía de Verificación y Resolución de Problemas / Diagnóstico

### 5.1 Árbol de Decisión de Diagnóstico para Fallas en Trabajos

```
                    +---------------------------------------+
                    | Scheduled Task Failed / Did Not Run   |
                    +-------------------+-------------------+
                                        |
                 +----------------------+----------------------+
                 |                                             |
     +-----------v-----------+                     +-----------v-----------+
     | Check System Cron Log |                     |  Check Access Rules   |
     |  grep cron /var/log/  |                     |  /var/cron/allow|deny |
     +-----------+-----------+                     +-----------+-----------+
                 |                                             |
        +--------+--------+                           +--------+--------+
        |                 |                           |                 |
 +------v------+   +------v------+             +------v------+   +------v------+
 | Job Executed|   | Job Never   |             | Permission  |   | Environment |
 | But Errored |   | Invoked     |             | Denied      |   | Variable    |
 | (Exit != 0) |   | (No Log)    |             | Error       |   | Mismatch    |
 +------+------+   +------+------+             +------+------+   +------+------+
        |                 |                           |                 |
        |                 |                           |                 |
  Check Mail /     Check Timezone /            Verify User in    Set PATH & SHELL
 Redirect stderr   Check Syntax                /var/cron/allow   In Crontab Header
```

---

### 5.2 Modos de Falla Comunes y Protocolos de Resolución

#### Problema 1: El Comando Ejecutado Manualmente Funciona, Pero Falla Bajo Cron
- **Causa Raíz:** Disparidad en las variables de entorno. Los inicios de sesión interactivos cargan `/etc/profile`, `~/.profile` o `~/.zshrc`, agregando directorios personalizados a `$PATH` (por ejemplo, `/usr/local/bin`, `/opt/bin`). El `cron` de BSD establece un `$PATH` predeterminado de `/usr/bin:/bin`.
- **Procedimiento de Diagnóstico:**

```console
$ grep -i "PATH" /etc/crontab
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin
```

- **Solución:** Definir explícitamente las variables de entorno obligatorias en la parte superior del archivo `crontab` u script objetivo:

```crontab
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin
SHELL=/bin/sh
```

---

#### Problema 2: Ejecuciones Superpuestas que Causan Contención de Bloqueo
- **Causa Raíz:** Un script de respaldo ejecutado cada hora tarda 75 minutos en finalizar, lo que resulta en una ejecución concurrente.
- **Procedimiento de Diagnóstico:** Verificar el árbol de procesos activos en busca de instancias duplicadas en ejecución:

```console
$ pgrep -fl "backup"
10423 /bin/sh /usr/local/bin/backup.sh
14589 /bin/sh /usr/local/bin/backup.sh
```

- **Solución:** Envolver el comando en `lockf(1)` para garantizar un bloqueo de ejecución estricto y no bloqueante:

```crontab
0 * * * * root /usr/sbin/lockf -s -t 0 /var/run/backup_job.lock /usr/local/bin/backup.sh
```
*Nota:* La flag `-t 0` especifica un tiempo de espera de cero segundos, indicando a `lockf` que salga inmediatamente con el estado 0 si no se puede adquirir el bloqueo, evitando el apilamiento de procesos duplicados.

---

#### Problema 3: Trabajos de At Obsoletos o Retrasos en la Cola de `atd`
- **Causa Raíz:** El proceso demonio `atrun(8)`, que procesa `/var/at/jobs/`, está deshabilitado o no programado en `/etc/crontab`.
- **Procedimiento de Diagnóstico:** En sistemas BSD, `atrun` es invocado por el cron del sistema cada 5 minutos:

```console
$ grep "atrun" /etc/crontab
*/5     *       *       *       *       root    /usr/libexec/atrun
```

Si `atrun` falta en `/etc/crontab`, los trabajos enviados a través de `at(1)` permanecen en la cola indefinidamente sin procesarse.

---

### 5.3 Comandos de Diagnóstico e Inspección de Logs del Sistema

#### Inspección de Logs del Demonio Cron
En FreeBSD, las acciones de cron se registran a través de `syslogd(8)` en `/var/log/cron`:

```console
$ sudo tail -n 20 /var/log/cron
Aug  6 20:00:00 bsd-host cron[84201]: (root) CMD (periodic daily)
Aug  6 20:15:00 bsd-host cron[84512]: (root) CMD (/usr/sbin/ntpdate -s pool.ntp.org)
Aug  6 20:30:00 bsd-host cron[85100]: (sre_automation) CMD (/usr/local/bin/healthcheck.sh > /dev/null)
Aug  6 20:30:00 bsd-host cron[85101]: (CRON) ERROR (cannot set uid to 1005): Operation not permitted
```

#### Rastreando la Ejecución con `ktrace(1)` / `kdump(1)`
Para rastrear las llamadas al sistema ejecutadas por `cron(8)` o un script periódico que falla:

```console
$ sudo ktrace -i -p $(pgrep cron)
# Let cron fire the job, then attach and decode
$ sudo kdump -f ktrace.out | grep -E "(NAMI|RET)" | head -n 15
 84201 cron     NAMI  "/etc/crontab"
 84201 cron     RET   open 3
 84201 cron     NAMI  "/var/cron/tabs/root"
 84201 cron     RET   open 4
 84201 cron     NAMI  "/usr/local/bin/healthcheck.sh"
 84201 cron     RET   execve 0
```

---

## 6. Referencias

* **Resumen de la Certificación LPI BSD Specialist:**  
  [https://www.lpi.org/our-certifications/bsd-specialist-overview/](https://www.lpi.org/our-certifications/bsd-specialist-overview/)

* **Manual del Administrador del Sistema FreeBSD – `cron(8)`:**  
  [https://man.freebsd.org/cgi/man.cgi?query=cron&sektion=8](https://man.freebsd.org/cgi/man.cgi?query=cron&sektion=8)

* **Manual de Formatos de Archivos FreeBSD – `crontab(5)`:**  
  [https://man.freebsd.org/cgi/man.cgi?query=crontab&sektion=5](https://man.freebsd.org/cgi/man.cgi?query=crontab&sektion=5)

* **Manual del Administrador del Sistema FreeBSD – `periodic(8)`:**  
  [https://man.freebsd.org/cgi/man.cgi?query=periodic&sektion=8](https://man.freebsd.org/cgi/man.cgi?query=periodic&sektion=8)

* **Manual de Comandos Generales FreeBSD – `at(1)`:**  
  [https://man.freebsd.org/cgi/man.cgi?query=at&sektion=1](https://man.freebsd.org/cgi/man.cgi?query=at&sektion=1)

* **Manual de Formatos de Archivos OpenBSD – `crontab(5)`:**  
  [https://man.openbsd.org/crontab.5](https://man.openbsd.org/crontab.5)