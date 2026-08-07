# LPI 702-100 (BSD Specialist v1.0) — Guía de Ingeniería de Producción y SRE
## Tema 713.2: Automatización de Tareas de Administración del Sistema Mediante la Programación de Trabajos (Peso: 3.33)

---

### Referencias Oficiales y Documentación Técnica
* **LPI BSD Specialist Certification Overview**: [https://www.lpi.org/our-certifications/bsd-specialist-overview/](https://www.lpi.org/our-certifications/bsd-specialist-overview/)
* **FreeBSD `cron(8)` Manual**: [https://man.freebsd.org/cgi/man.cgi?query=cron&sektion=8](https://man.freebsd.org/cgi/man.cgi?query=cron&sektion=8)
* **FreeBSD `crontab(5)` Manual**: [https://man.freebsd.org/cgi/man.cgi?query=crontab&sektion=5](https://man.freebsd.org/cgi/man.cgi?query=crontab&sektion=5)
* **FreeBSD `periodic(8)` Manual**: [https://man.freebsd.org/cgi/man.cgi?query=periodic&sektion=8](https://man.freebsd.org/cgi/man.cgi?query=periodic&sektion=8)
* **FreeBSD `periodic.conf(5)` Manual**: [https://man.freebsd.org/cgi/man.cgi?query=periodic.conf&sektion=5](https://man.freebsd.org/cgi/man.cgi?query=periodic.conf&sektion=5)
* **FreeBSD `at(1)` Manual**: [https://man.freebsd.org/cgi/man.cgi?query=at&sektion=1](https://man.freebsd.org/cgi/man.cgi?query=at&sektion=1)

---

### Visión General de la Arquitectura y Mecánica Interna

```
                             +-------------------------------------------------------+
                             |                     cron(8) Daemon                    |
                             |  - Wakes up every 60s at minute boundary (sleep(60))  |
                             |  - Parses system /etc/crontab & user /var/cron/tabs/*  |
                             +---------------------------+---------------------------+
                                                         |
                   +-------------------------------------+-------------------------------------+
                   |                                                                           |
                   v                                                                           v
     +---------------------------+                                               +---------------------------+
     |   System Crontab (7-col)  |                                               |    User Crontab (6-col)    |
     |   /etc/crontab            |                                               |    /var/cron/tabs/<user>  |
     +-------------+-------------+                                               +-------------+-------------+
                   |                                                                           |
                   | (Invokes periodic scripts)                                                | (Direct command)
                   v                                                                           v
     +---------------------------+                                               +---------------------------+
     |        periodic(8)        |                                               |  Non-interactive Shell    |
     |  /usr/sbin/periodic       |                                               |  (SHELL=/bin/sh, HOME)    |
     +-------------+-------------+                                               +---------------------------+
                   |
     +-------------+-------------+-------------+
     |             |             |             |
     v             v             v             v
  daily        weekly        monthly       atrun(8)
(/etc/periodic/ /etc/periodic/ /etc/periodic/    |
 daily/*)       weekly/*)      monthly/*)        v
                                          Processes queued jobs in
                                          /var/at/jobs/
```

#### 1. Arquitectura del Subsistema Cron de BSD (`cron(8)` y `crontab(5)`)
La arquitectura de programación de trabajos en BSD se centra en `cron(8)`, un daemon en segundo plano iniciado durante el arranque del sistema por `rc(8)`. 
* **Bucle de Ejecución**: `cron(8)` calcula el intervalo de suspensión (`sleep`) para despertarse exactamente en el segundo cero del siguiente minuto. Al despertarse, verifica las marcas de tiempo de modificación (`mtime`) de `/etc/crontab`, `/etc/cron.d` (si está habilitado) y `/var/cron/tabs/` para refrescar sus tablas de tareas en memoria sin requerir un reinicio del daemon.
* **Crontabs del Sistema vs del Usuario**:
  * **Crontab del Sistema (`/etc/crontab`)**: Contiene **7 campos**. El campo 6 especifica explícitamente el **nombre de usuario** (*username*) bajo el cual se ejecutará el comando (campo 7).
    $$\text{Format: } \langle\text{min}\rangle \quad \langle\text{hour}\rangle \quad \langle\text{mday}\rangle \quad \langle\text{month}\rangle \quad \langle\text{wday}\rangle \quad \mathbf{\langle\text{username}\rangle} \quad \langle\text{command}\rangle$$
  * **Crontabs de Usuario (`/var/cron/tabs/<user>`)**: Contiene **6 campos**. El contexto de ejecución está estrictamente bloqueado al propietario del archivo crontab.
    $$\text{Format: } \langle\text{min}\rangle \quad \langle\text{hour}\rangle \quad \langle\text{mday}\rangle \quad \langle\text{month}\rangle \quad \langle\text{wday}\rangle \quad \langle\text{command}\rangle$$
* **Contexto de Ejecución del Entorno**: `cron(8)` ejecuta los trabajos en un shell no interactivo mínimo. Variables de entorno predeterminadas pobladas en tiempo de ejecución:
  * `PATH=/usr/bin:/bin` (FreeBSD utiliza por defecto una ruta restrictiva; las rutas explícitas a binarios son obligatorias en scripts de producción).
  * `SHELL=/bin/sh`
  * `HOME=<home_directory_of_target_user>`
  * `LOGNAME=<target_user>` / `USER=<target_user>`
  * `MAILTO=<target_user>` (La salida estándar y la salida de error estándar se capturan y se envían a través del MTA local a `MAILTO`. Si `MAILTO=""`, las notificaciones por correo electrónico se suprimen).

#### 2. El Framework de Mantenimiento `periodic(8)` en BSD
A diferencia de los sistemas Linux que suelen depender de `anacron` o unidades de `systemd.timer`, los sistemas BSD utilizan `periodic(8)` para orquestar las tareas de mantenimiento habituales.
* **Invocación**: Ejecutado por `cron(8)` desde `/etc/crontab` en ventanas de tiempo específicas (diario, semanal, mensual).
* **Jerarquía de Directorios y Precedencia**:
  1. Scripts del sistema base: `/etc/periodic/daily/`, `/etc/periodic/weekly/`, `/etc/periodic/monthly/`, `/etc/periodic/security/`
  2. Ports/Paquetes de terceros: `/usr/local/etc/periodic/daily/`, `/usr/local/etc/periodic/weekly/`, etc.
* **Cascada de Configuración**:
  * Configuración predeterminada: `/etc/defaults/periodic.conf` (NO DEBE editarse directamente).
  * Sobrescribir opciones a nivel del sistema: `/etc/periodic.conf`
  * Sobrescribir opciones locales: `/etc/periodic.conf.local`
* **Flujo de Ejecución**: `periodic` analiza el directorio de destino, ordena los scripts lexicográficamente (p. ej., `100.clean-disks`, `200.backup`), evalúa las variables de control correspondientes en `/etc/periodic.conf` (p. ej., `daily_clean_disks_enable="YES"`), ejecuta los scripts habilitados y recopila la salida en un archivo de registro (*log*) o informe por correo electrónico.
* **Códigos de Retorno Estándar para Scripts de Periodic**:
  * `0`: Éxito, no se generó salida relevante.
  * `1`: Tarea ejecutada, se generó salida informativa (incluida en el informe).
  * `2`: Advertencia / se encontró un error no fatal.
  * `3`: Se encontró un error fatal.

#### 3. Programación de Trabajos de Única Ejecución (`at(1)` y `atrun(8)`)
* **Arquitectura**: La utilidad `at(1)` pone en cola comandos de shell para ser ejecutados en un momento futuro específico.
* **Mecanismo de Spool en BSD**: Los trabajos se almacenan como scripts de shell en `/var/at/jobs/` (o `/var/at/spool/`), con un prefijo basado en máscaras de bits de marca de tiempo de ejecución.
* **Motor de Ejecución (`atrun(8)`)**: A diferencia de los sistemas que ejecutan un daemon `atd` persistente, el BSD clásico ejecuta `/usr/libexec/atrun` periódicamente a través de `/etc/crontab` (típicamente `*/5 * * * * root /usr/libexec/atrun`). `atrun(8)` comprueba `/var/at/jobs/` en busca de trabajos cuya marca de tiempo de ejecución sea igual o anterior a la época (*epoch*) actual, los ejecuta bajo `setuid` al propietario y elimina el archivo del trabajo.

#### 4. Arquitectura de Control de Acceso
* **Control de Acceso a Cron**:
  * `/var/cron/allow`: Si está presente, solo los usuarios listados aquí pueden usar `crontab -e`.
  * `/var/cron/deny`: Se evalúa ÚNICAMENTE si `/var/cron/allow` NO existe. Los usuarios listados aquí tienen prohibido el acceso.
  * Si ninguno de los dos archivos existe, solo `root` (o todos los usuarios, según la configuración del sistema) puede enviar crontabs de usuario.
* **Control de Acceso a At**:
  * `/etc/at.allow` (o `/var/at/at.allow` según la distribución BSD): Lista blanca (*whitelist*) para el uso de `at(1)`.
  * `/etc/at.deny` (o `/var/at/at.deny`): Lista negra (*blacklist*) evaluada únicamente cuando el archivo *allow* está ausente.

---

### Ejercicios Prácticos Guiados

#### Ejercicio 1: Crontabs del Sistema vs de Usuario, Trampas del Entorno y Bloqueo de Concurrencia

##### Objetivo
Configurar tanto un `/etc/crontab` del sistema como un crontab a nivel de usuario. Diagnosticar discrepancias en las variables de entorno y prevenir la concurrencia de trabajos utilizando `lockf(1)` de FreeBSD.

##### Paso 1: Inspeccionar y verificar la sintaxis de `/etc/crontab`
Inspeccionar la estructura existente de `/etc/crontab` para verificar el formato de 7 campos.

```bash
cat /etc/crontab
```

###### Salida Esperada
```text
# /etc/crontab - root's crontab for FreeBSD
#
SHELL=/bin/sh
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin
#
#minute	hour	mday	month	wday	who	command
#
*/5	*	*	*	*	root	usr/libexec/atrun
# Perform daily/weekly/monthly maintenance.
1	3	*	*	*	root	periodic daily
15	4	*	*	1	root	periodic weekly
30	5	1	*	*	root	periodic monthly
```

##### Paso 2: Crear un escenario de fallo debido a la falta de coincidencia en la variable de entorno PATH
Crear un script en `/usr/local/bin/db_backup.sh` que dependa de binarios no estándar en `/bin`.

```bash
sudo mkdir -p /usr/local/bin
sudo tee /usr/local/bin/db_backup.sh > /dev/null << 'EOF'
#!/bin/sh
echo "=== Execution timestamp: $(date) ==="
echo "PATH inside cron is: $PATH"
which zfs > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo "ERROR: zfs executable not found in PATH!" >&2
    exit 100
fi
echo "ZFS binary detected successfully at $(which zfs)"
EOF

sudo chmod +x /usr/local/bin/db_backup.sh
```

##### Paso 3: Instalar un crontab de usuario con un PATH explícito y restrictivo
Editar el crontab del usuario actual usando `crontab -e` (o canalizarlo mediante `crontab -` para automatización).

```bash
(
cat << 'EOF'
PATH=/bin:/usr/bin
MAILTO=""
* * * * * /usr/local/bin/db_backup.sh >> /tmp/cron_test.log 2>&1
EOF
) | crontab -
```

Verificar la instalación del archivo crontab:

```bash
crontab -l
```

###### Salida Esperada
```text
PATH=/bin:/usr/bin
MAILTO=""
* * * * * /usr/local/bin/db_backup.sh >> /tmp/cron_test.log 2>&1
```

##### Paso 4: Validar la ejecución de cron y diagnosticar la salida del log
Esperar 60 segundos para que `cron(8)` ejecute el trabajo, luego inspeccionar `/tmp/cron_test.log`.

```bash
sleep 65
cat /tmp/cron_test.log
```

###### Salida Esperada
```text
=== Execution timestamp: Thu Aug  6 20:45:00 UTC 2026 ===
PATH inside cron is: /bin:/usr/bin
ERROR: zfs executable not found in PATH!
```

##### Paso 5: Corregir el PATH y aplicar control de bloqueo en producción (`lockf(1)`)
Actualizar el crontab para incluir `/sbin` en `PATH` y utilizar `lockf(1)` para garantizar que, si un trabajo de respaldo tarda más de 60 segundos, las instancias concurrentes sean bloqueadas.

```bash
(
cat << 'EOF'
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin
MAILTO="admin@example.com"
* * * * * lockf -t 0 /tmp/db_backup.lock /usr/local/bin/db_backup.sh >> /tmp/cron_test.log 2>&1
EOF
) | crontab -
```

Esperar a la ejecución y verificar la salida:

```bash
sleep 65
tail -n 5 /tmp/cron_test.log
```

###### Salida Esperada
```text
=== Execution timestamp: Thu Aug  6 20:46:00 UTC 2026 ===
PATH inside cron is: /sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin
ZFS binary detected successfully at /sbin/zfs
```

---

##### Preguntas de Verificación — Ejercicio 1

**Pregunta 1.1**: ¿Cuál es la diferencia estructural entre una línea en `/etc/crontab` y una línea en el crontab de un usuario editado mediante `crontab -e`?
1. Los crontabs de usuario contienen una columna de entorno adicional para `MAILTO`.
2. `/etc/crontab` contiene 7 columnas (especificando el contexto del usuario ejecutor de destino), mientras que los crontabs de usuario contienen 6 columnas.
3. Los crontabs de usuario utilizan 7 columnas (especificando el contexto de ejecución del usuario), mientras que `/etc/crontab` utiliza 5 columnas.
4. `/etc/crontab` no admite declaraciones de variables de entorno como `PATH` o `SHELL`.

**Pregunta 1.2**: En el Paso 5, ¿cuál es la función exacta del envoltorio del comando `lockf -t 0 /tmp/db_backup.lock`?
1. Cifra la salida estándar (*stdout*) de `/usr/local/bin/db_backup.sh` antes de anexarla a `/tmp/cron_test.log`.
2. Espera hasta 0 segundos (falla inmediatamente sin ejecutar la nueva instancia) si otro proceso mantiene un bloqueo exclusivo sobre `/tmp/db_backup.lock`.
3. Limita el tiempo de ejecución de `/usr/local/bin/db_backup.sh` a 0 segundos antes de enviar `SIGKILL`.
4. Cambia la propiedad del proceso de `/usr/local/bin/db_backup.sh` al usuario `lockf`.

**Pregunta 1.3**: ¿Dónde se almacenan los archivos crontab de usuario en un sistema FreeBSD estándar?
1. `/etc/cron.d/<username>`
2. `/var/spool/cron/crontabs/<username>`
3. `/var/cron/tabs/<username>`
4. `/usr/local/etc/cron/tabs/<username>`

---

#### Ejercicio 2: Ingeniería Avanzada de `periodic(8)` en BSD y Desarrollo de Scripts Personalizados

##### Objetivo
Comprender el motor de ejecución `periodic(8)`, crear un script de mantenimiento personalizado sintácticamente válido en `/usr/local/etc/periodic/daily/`, registrar su configuración en `/etc/periodic.conf` y realizar ejecuciones manuales de validación.

##### Paso 1: Inspeccionar la configuración predeterminada de periodic del sistema base
Examinar el archivo maestro de configuración predeterminada `/etc/defaults/periodic.conf` para comprender cómo se definen las tareas de periodic.

```bash
grep -E "daily_clean|daily_show" /etc/defaults/periodic.conf | head -n 10
```

###### Salida Esperada
```text
daily_clean_disks_enable="NO"
daily_clean_disks_days=3
daily_clean_disks_show_scanned="YES"
daily_clean_tmps_enable="NO"
daily_clean_tmps_days="3"
daily_clean_tmps_ignore="Quota.user Quota.group .snap"
daily_clean_preserve_enable="YES"
daily_clean_preserve_days=7
daily_clean_msgs_enable="YES"
```

##### Paso 2: Desarrollar un script de periodic personalizado para BSD
Crear un script diario personalizado llamado `999.zfs-snapshot-audit` en `/usr/local/etc/periodic/daily/`. El script debe respetar la configuración de `/etc/periodic.conf` y adherirse a las convenciones de códigos de retorno de periodic en BSD.

```bash
sudo mkdir -p /usr/local/etc/periodic/daily

sudo tee /usr/local/etc/periodic/daily/999.zfs-snapshot-audit > /dev/null << 'EOF'
#!/bin/sh

# If source periodic config files exist, read them.
if [ -r /etc/defaults/periodic.conf ]; then
    . /etc/defaults/periodic.conf
fi

# Define local override default if not set in /etc/periodic.conf
: ${daily_zfs_snapshot_audit_enable:="NO"}
: ${daily_zfs_snapshot_audit_pools:="zroot"}

rc=0

case "$daily_zfs_snapshot_audit_enable" in
    [Yy][Ee][Ss])
        echo ""
        echo "Checking ZFS snapshot compliance..."
        for pool in $daily_zfs_snapshot_audit_pools; do
            zfs list -t snapshot -r "$pool" > /dev/null 2>&1
            if [ $? -eq 0 ]; then
                snap_count=$(zfs list -t snapshot -H -o name -r "$pool" | wc -l | tr -d ' ')
                echo "  Pool '$pool': $snap_count snapshots present."
            else
                echo "  WARNING: Pool '$pool' does not exist or has no datasets."
                rc=2
            fi
        done
        ;;
    *)
        # Disabled - exit cleanly without output
        rc=0
        ;;
esac

exit $rc
EOF

sudo chmod 755 /usr/local/etc/periodic/daily/999.zfs-snapshot-audit
```

##### Paso 3: Probar el script de periodic en estado deshabilitado
Ejecutar `periodic` manualmente para la cola `daily` y verificar que nuestro script NO produzca salida porque está deshabilitado por defecto.

```bash
sudo periodic daily
```

###### Salida Esperada
*(No se devuelve salida, o solo la salida de las tareas base habilitadas por defecto, porque `daily_zfs_snapshot_audit_enable` tiene como valor predeterminado `"NO"`).*

##### Paso 4: Habilitar el script de periodic personalizado en `/etc/periodic.conf`
Anexar las directivas de activación a `/etc/periodic.conf`.

```bash
sudo tee -a /etc/periodic.conf > /dev/null << 'EOF'
# Enable custom ZFS snapshot audit script
daily_zfs_snapshot_audit_enable="YES"
daily_zfs_snapshot_audit_pools="zroot non_existent_pool"
EOF
```

##### Paso 5: Ejecutar una corrida manual de periodic y verificar los códigos de salida y la salida
Ejecutar `periodic daily` manualmente para ejecutar todas las tareas diarias habilitadas, incluyendo nuestro nuevo módulo de auditoría personalizado.

```bash
sudo periodic daily
```

###### Salida Esperada
```text
Checking ZFS snapshot compliance...
  Pool 'zroot': 12 snapshots present.
  WARNING: Pool 'non_existent_pool' does not exist or has no datasets.
```

Verificar que el código de salida de `periodic daily` refleje la advertencia (`rc=2` devuelto por nuestro módulo personalizado):

```bash
echo "Periodic execution exit code: $?"
```

###### Salida Esperada
```text
Periodic execution exit code: 2
```

---

##### Preguntas de Verificación — Ejercicio 2

**Pregunta 2.1**: ¿Por qué un administrador NUNCA debe editar `/etc/defaults/periodic.conf` directamente para modificar el comportamiento de los trabajos de periodic?
1. `/etc/defaults/periodic.conf` se almacena en un ramdisk del kernel de solo lectura.
2. Las actualizaciones del sistema (p. ej., `freebsd-update`) sobrescriben `/etc/defaults/periodic.conf`. Las configuraciones personalizadas deben declararse en `/etc/periodic.conf` o `/etc/periodic.conf.local`.
3. Editar `/etc/defaults/periodic.conf` corrompe la firma digital comprobada por `cron(8)` al arrancar.
4. `periodic(8)` solo lee `/etc/defaults/periodic.conf` si `/etc/periodic.conf` no existe en absoluto.

**Pregunta 2.2**: ¿Dónde se deben colocar los scripts de mantenimiento del sistema de terceros instalados mediante FreeBSD Ports o herramientas de administración personalizadas para que sean ejecutados por `periodic daily`?
1. `/etc/periodic/daily/`
2. `/var/cron/periodic/daily/`
3. `/usr/local/etc/periodic/daily/`
4. `/usr/libexec/periodic/daily/`

**Pregunta 2.3**: ¿Cuál es el significado del código de retorno `1` emitido por un script que se ejecuta dentro del framework `periodic(8)`?
1. El script falló con un error fatal; `periodic` aborta la ejecución posterior de scripts de inmediato.
2. El script finalizó correctamente y generó salida informativa que debe incluirse en el informe de resumen de periodic.
3. El script se omitió porque su variable de control en `/etc/periodic.conf` estaba configurada en `NO`.
4. El script encontró un error de sintaxis durante su ejecución.

---

#### Ejercicio 3: Automatización de Trabajos de Única Ejecución a través de `at(1)`, Inspección del Spool y Seguridad del Control de Acceso

##### Objetivo
Programar trabajos de única ejecución inmediatos y diferidos utilizando `at(1)`, inspeccionar archivos de spool en `/var/at/jobs/`, administrar colas mediante `atq(1)` y `atrm(1)`, y configurar controles de acceso de seguridad estrictos utilizando `/var/cron/allow` y `/etc/at.allow`.

##### Paso 1: Programar una tarea diferida usando `at(1)`
Programar un comando sintético de mantenimiento del sistema para ejecutarse 15 minutos en el futuro.

```bash
echo "logger -t AT_TEST 'Executing scheduled one-off task'" | at now + 15 minutes
```

###### Salida Esperada
```text
Job 1 will be executed using /bin/sh
```

##### Paso 2: Consultar la cola de trabajos de `at` mediante `atq(1)`
Listar todos los trabajos en cola pendientes de ejecución.

```bash
atq
```

###### Salida Esperada
```text
Date                    Queue   Job#    User
Thu Aug  6 21:05:00 2026  c      1      root
```

##### Paso 3: Inspeccionar la representación interna del spool en `/var/at/jobs/`
Examinar el archivo de spool subyacente creado por `at(1)`. El archivo de spool contiene el estado del entorno capturado en el momento del envío.

```bash
sudo ls -l /var/at/jobs/
```

###### Salida Esperada
```text
total 4
-rwx------  1 root  wheel  2648 Aug  6 20:50 01a52029.00
```

Inspeccionar el contenido del archivo de spool generado para ver cómo se encapsulan las variables de entorno y los comandos:

```bash
sudo head -n 20 /var/at/jobs/01a52029.00
```

###### Salida Esperada
```text
#!/bin/sh
# atrun job 1
# mail root 0
umask 022
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin; export PATH
USER=root; export USER
HOME=/root; export HOME
SHELL=/bin/sh; export SHELL
cd /root || exit 1
logger -t AT_TEST 'Executing scheduled one-off task'
```

##### Paso 4: Eliminar un trabajo en cola usando `atrm(1)`
Eliminar el trabajo programado utilizando su número de trabajo.

```bash
atrm 1
atq
```

###### Salida Esperada
```text
(No output returned; queue is now empty)
```

##### Paso 5: Aplicar políticas de control de acceso estrictas para `crontab` y `at`
Configurar el control de acceso para restringir el uso de `crontab` al usuario `webadmin` y a `root`.

Crear `/var/cron/allow`:

```bash
sudo tee /var/cron/allow > /dev/null << 'EOF'
root
webadmin
EOF
```

Crear `/etc/at.allow` para restringir el uso de `at(1)`:

```bash
sudo tee /etc/at.allow > /dev/null << 'EOF'
root
webadmin
EOF
```

Verificar la aplicación de la seguridad intentando ejecutar `crontab` como un usuario no autorizado (p. ej., `nobody`):

```bash
sudo -u nobody crontab -l
```

###### Salida Esperada
```text
crontab: You (nobody) are not allowed to use this program.
```

---

##### Preguntas de Verificación — Ejercicio 3

**Pregunta 3.1**: En FreeBSD, ¿cómo se activan y ejecutan realmente los trabajos programados con `at(1)` a la hora de ejecución especificada?
1. Un daemon persistente llamado `atd(8)` se ejecuta continuamente en segundo plano y ejecuta los trabajos a través de temporizadores de `kqueue(2)`.
2. El kernel ejecuta directamente los trabajos en cola cuando se alcanza la marca de tiempo de la época (*epoch*).
3. La utilidad `atrun(8)` se invoca periódicamente (típicamente cada 5 minutos) por `/etc/crontab` como `root` para procesar archivos de spool pendientes.
4. `periodic daily` analiza `/var/at/jobs/` una vez al día.

**Pregunta 3.2**: Si existen tanto `/var/cron/allow` como `/var/cron/deny` en un sistema FreeBSD, ¿qué archivo de política de seguridad tiene precedencia?
1. `/var/cron/deny` tiene precedencia; cualquier usuario listado en `/var/cron/deny` es bloqueado incluso si está listado en `/var/cron/allow`.
2. `/var/cron/allow` tiene precedencia; solo se permiten los usuarios listados en `/var/cron/allow`, y `/var/cron/deny` se ignora por completo.
3. Ambos archivos se combinan; los usuarios deben aparecer en ambos archivos para obtener acceso.
4. Se concede acceso a todos los usuarios que no sean `root` por defecto.

**Pregunta 3.3**: ¿Qué comando elimina el trabajo número `42` de la cola de ejecución de `at`?
1. `at --delete 42`
2. `crontab -r 42`
3. `atrm 42` (o `at -r 42`)
4. `periodic --remove 42`

---

### Soluciones y Explicaciones Detalladas

<details>
<summary><strong>Haz clic para expandir las Soluciones y Explicaciones Detalladas</strong></summary>

#### Soluciones del Ejercicio 1

* **Pregunta 1.1**: **Respuesta Correcta: 2**
  * **Explicación**: El crontab del sistema (`/etc/crontab`) utiliza 7 campos: `minute hour mday month wday username command`. El campo 6 establece explícitamente el contexto de la cuenta de usuario (p. ej., `root`, `www`, `nobody`) bajo la cual `cron` ejecuta el proceso. Los crontabs de usuario creados mediante `crontab -e` tienen 6 campos (`minute hour mday month wday command`) porque el contexto del usuario está implícitamente definido por el propietario del archivo crontab almacenado en `/var/cron/tabs/<username>`.

* **Pregunta 1.2**: **Respuesta Correcta: 2**
  * **Explicación**: `lockf(1)` es la utilidad estándar de gestión de bloqueos de BSD para la exclusión mutua. La flag `-t 0` especifica un tiempo de espera de 0 segundos. Si `/tmp/db_backup.lock` ya está bloqueado por una instancia previa del script en ejecución, `lockf` finaliza inmediatamente con un código de salida distinto de cero sin ejecutar el comando de destino. Esto evita la superposición de trabajos y el agotamiento de recursos cuando `cron` invoca procesos de respaldo de larga duración.

* **Pregunta 1.3**: **Respuesta Correcta: 3**
  * **Explicación**: En FreeBSD, los archivos crontab de usuario administrados por `crontab(1)` se almacenan en `/var/cron/tabs/<username>`. El acceso a este directorio está strictly restringido para evitar la lectura no autorizada de credenciales confidenciales almacenadas dentro de los crontabs de los usuarios.

---

#### Soluciones del Ejercicio 2

* **Pregunta 2.1**: **Respuesta Correcta: 2**
  * **Explicación**: `/etc/defaults/periodic.conf` define los valores predeterminados del sistema base proporcionados por la distribución del SO FreeBSD. Las actualizaciones a través de `freebsd-update` o la compilación desde código fuente (`make installworld`) sobrescribirán este archivo. Los administradores deben declarar modificaciones locales en `/etc/periodic.conf` o `/etc/periodic.conf.local`, las cuales sobrescriben a `/etc/defaults/periodic.conf` sin perderse durante las actualizaciones del SO.

* **Pregunta 2.2**: **Respuesta Correcta: 3**
  * **Explicación**: Siguiendo el diseño de la jerarquía del sistema de archivos de FreeBSD (`hier(7)`), los archivos del sistema base residen en `/etc/periodic/`, mientras que las aplicaciones de terceros, ports y scripts de administración personalizados pertenecen a `/usr/local/etc/periodic/<daily|weekly|monthly|security>/`.

* **Pregunta 2.3**: **Respuesta Correcta: 2**
  * **Explicación**: En el framework `periodic(8)`, los códigos de retorno controlan los informes de logs:
    * `0`: Éxito sin salida (silencioso).
    * `1`: Éxito con salida (la salida estándar/salida de error capturada se anexa al correo electrónico del informe de periodic).
    * `2`: Mensaje de advertencia encontrado.
    * `3`: Error fatal encontrado.

---

#### Soluciones del Ejercicio 3

* **Pregunta 3.1**: **Respuesta Correcta: 3**
  * **Explicación**: A diferencia de los sistemas Linux que utilizan un daemon continuo `atd` en segundo plano, los sistemas BSD estándar ejecutan `/usr/libexec/atrun` cada 5 minutos a través de una entrada en el `/etc/crontab` del sistema:
    `*/5 * * * * root /usr/libexec/atrun`
    Al ser invocado, `atrun(8)` escanea `/var/at/jobs/`, identifica los trabajos cuya hora de ejecución ha pasado, los ejecuta bajo las credenciales del propietario y limpia el archivo del spool.

* **Pregunta 3.2**: **Respuesta Correcta: 2**
  * **Explicación**: La seguridad de `cron(8)` en BSD utiliza una estricta precedencia de lista de permitidos (*allow-list*):
    1. Si existe `/var/cron/allow`, SOLO los usuarios explícitamente nombrados dentro de `/var/cron/allow` tienen permitido usar `crontab`. El archivo `/var/cron/deny` se ignora.
    2. Si `/var/cron/allow` NO existe, se comprueba `/var/cron/deny`. Los usuarios listados en `deny` son bloqueados.
    3. Si ninguno de los dos archivos existe, se aplican las restricciones de seguridad predeterminadas (en FreeBSD, solo `root` está permitido a menos que se configure de otro modo).

* **Pregunta 3.3**: **Respuesta Correcta: 3**
  * **Explicación**: `atrm(1)` (o su alias `at -r`) elimina trabajos del directorio de spool de `at` utilizando el identificador de trabajo mostrado por `atq(1)`.

</details>