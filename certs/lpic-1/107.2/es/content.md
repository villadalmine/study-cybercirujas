# LPIC-1 · Tema 107.2 — Automatizar tareas de administración del sistema programando trabajos

> **Examen:** 102-500 (LPIC-1 v5.0), Tema 107 — Tareas administrativas
> **Peso publicado real: 4** (el `0.0` en los metadatos de generación es un artefacto de importación del temario; 107.2 es uno de los objetivos más pesados de 102-500 y acá se trata con profundidad completa).
> **Archivos, términos y utilidades clave (según LPI):** `/usr/bin/crontab`, `/etc/crontab`, `/etc/cron.{d,daily,hourly,monthly,weekly}`, `/var/spool/cron/`, `/etc/cron.allow`, `/etc/cron.deny`, `/etc/at.allow`, `/etc/at.deny`, `at`, `atq`, `atrm`, `crontab`, `systemd-run`, `systemctl` (timers), unidades `.timer` y `.service`.

---

## 1. Motivación: el problema arquitectónico detrás de "que corra todas las noches y listo"

Toda plataforma en producción acumula un plano de control en la sombra hecho de trabajo periódico: renovación de certificados, rotación de logs, snapshots de backup, precalentadores de caché, bucles de reconciliación, agregaciones de métricas, recolección de recursos huérfanos. Ese trabajo no forma parte de ningún camino de request, así que no hay ningún usuario quejándose cuando deja de funcionar en silencio. Esa asimetría es todo el problema.

Un trabajo programado es un **sistema distribuido con un solo nodo y sin observabilidad por defecto**. Pensá en lo que realmente necesita para ser correcto en producción:

| Requisito | Por qué te muerde en producción | Comportamiento ingenuo de cron |
|---|---|---|
| **Entorno determinista** | El trabajo funcionaba en tu shell y falla bajo el planificador | `PATH=/usr/bin:/bin`, `SHELL=/bin/sh`, sin `~/.bashrc`, sin `LANG`, sin agente SSH, sin el `$HOME` que asumiste |
| **Exclusión mutua** | El backup de las 02:00 sigue corriendo cuando dispara el de las 03:00 → dos `rsync` escribiendo un mismo destino | cron arranca instancias solapadas alegremente y para siempre |
| **Recuperación de ejecuciones perdidas** | La laptop/VM estaba apagada a las 03:00; el informe mensual nunca corre | cron clásico: la ejecución simplemente se pierde |
| **Estampida (thundering herd)** | 4.000 nodos haciendo `curl` al mirror de artefactos a las `0 3 * * *` | cada nodo dispara exactamente en el mismo segundo |
| **Visibilidad de fallos** | El trabajo sale con 1 durante 6 semanas y nadie se entera | la salida se envía por correo a un buzón local que nadie lee; el código de salida se descarta |
| **Contención de recursos** | Un trabajo de agregación desbocado provoca OOM en el nodo de base de datos | cron hace fork de un proceso con los límites completos del invocante y sin cgroup |
| **Discontinuidad temporal** | Cambio de hora hacia adelante: las `02:30` no existen; hacia atrás: existen dos veces | Vixie cron tiene heurísticas; no son lo que la mayoría supone |
| **Auditabilidad** | "¿Quién programó esto? ¿Cuándo? ¿A partir de qué cambio?" | `crontab -e` es una mutación no versionada ni revisada de `/var/spool` |

El tema 107.2 es donde aprendés los tres mecanismos de Linux que atacan esto — **cron**, **anacron/at** y **timers de systemd** — y, más importante todavía, *cuál es la elección arquitectónica correcta*. El encuadre relevante para SRE: **cron es un lanzador de procesos de tipo dispará-y-olvidate; los timers de systemd son un frontend de planificación supervisado, confinado en cgroups e instrumentado con journald sobre el gestor de servicios.** No son intercambiables, y el examen espera soltura en ambos.

El análogo en orquestación de contenedores es exacto y conviene tenerlo presente: un `CronJob` de Kubernetes es `.spec.schedule` (una expresión cron) más `concurrencyPolicy` (exclusión mutua), `startingDeadlineSeconds` (política de ejecuciones perdidas), `backoffLimit` (reintento) y `successfulJobsHistoryLimit` (observabilidad). Esos cuatro campos existen precisamente porque cron crudo carece de los cuatro. En un host Linux, los timers de `systemd` son donde conseguís los equivalentes.

---

## 2. El panorama de planificadores: comparación técnica

### 2.1 Matriz de compromisos

| Capacidad | Vixie/`cronie` cron | `anacron` | `at` / `batch` | `systemd.timer` | `CronJob` de Kubernetes |
|---|---|---|---|---|---|
| Modelo de disparo | Calendario de reloj de pared, granularidad de 1 minuto | Días transcurridos desde el último éxito | Único disparo en tiempo absoluto/relativo | Calendario **y** monotónico (`OnBootSec`, `OnUnitActiveSec`) | Calendario de reloj de pared (sondeado por el controlador) |
| Granularidad sub-minuto | ✗ (piso de 1 min) | ✗ | ✗ | ✓ (`OnUnitActiveSec=30s`, `AccuracySec=1s`) | ✗ |
| Recuperación tras caída | ✗ (la ejecución se pierde) | ✓ (propósito central) | ✗ (el trabajo dispara cuando `atd` arranca de nuevo — tarde, pero no se pierde) | ✓ `Persistent=true` | Parcial: `startingDeadlineSeconds` |
| Prevención de solapamiento | ✗ (requiere `flock`) | ✓ (serialización por trabajo) | n/a | ✓ (la unidad ya está activa → el disparo no hace nada) | ✓ `concurrencyPolicy: Forbid` |
| Jitter / control de estampida | ✗ (`sleep $((RANDOM%...))` manual) | ✓ `RANDOM_DELAY` | ✗ | ✓ `RandomizedDelaySec=` | ✗ |
| Límites de recursos | Solo heredados | Solo heredados | Solo heredados | ✓ cgroup completo: `MemoryMax=`, `CPUQuota=`, `IOWeight=` | ✓ recursos del pod |
| Aislamiento (sandboxing) | ✗ | ✗ | ✗ | ✓ `ProtectSystem=`, `PrivateTmp=`, `NoNewPrivileges=`, `CapabilityBoundingSet=` | ✓ securityContext |
| Manejo del código de salida | Descartado (correo por *salida*, no por fallo) | Descartado | Descartado | ✓ registrado, unidad `OnFailure=`, `Restart=` | ✓ `backoffLimit` |
| Registro (logging) | Línea en syslog + correo | syslog | correo | ✓ journald estructurado (`_SYSTEMD_UNIT`, `INVOCATION_ID`) | ✓ logs del pod |
| Orden de dependencias | ✗ | ✗ | ✗ | ✓ `After=`, `Requires=`, `Wants=` | ✗ |
| Diferimiento según carga | ✗ | ✗ | ✓ (`batch`, loadavg < 1.5) | ✗ (aproximable con `ConditionCPUPressure` en systemd nuevo) | ✗ |
| Autoservicio por usuario | ✓ `crontab -e` | ✗ (a nivel de sistema; los anacrontabs de usuario son manuales) | ✓ | ✓ `systemctl --user` (requiere lingering) | n/a |
| Control de zona horaria | TZ del demonio / `CRON_TZ=` | TZ del sistema | TZ del sistema | ✓ `OnCalendar=... ` + `Timezone` en systemd reciente; si no, `TZ=` en Environment | ✓ `.spec.timeZone` |
| Declarativo / apto para GitOps | Vía archivos en `/etc/cron.d` | Vía `/etc/anacrontab` | ✗ (imperativo por naturaleza) | ✓ archivos de unidad | ✓ |
| Presencia en el examen (LPIC-1) | **Alta** | **Moderada** | **Alta** | **Moderada** | ✗ |

**Regla de decisión del arquitecto:**

- **Automatización nueva a nivel de sistema en un host con systemd → escribí un par `.timer` + `.service`.** Obtenés supervisión, cgroups, journald, orden de dependencias y recuperación gratis.
- **Por usuario, de bajo riesgo, portable, o el host no usa systemd (contenedores, entornos tipo BSD, imágenes mínimas) → cron.**
- **La máquina no está siempre encendida (laptops, VMs de desarrollo, nodos de borde con energía intermitente) → anacron, o timers con `Persistent=true`.**
- **Trabajo diferido de un solo disparo (una acción de mantenimiento programada, un "reintentá esto en 20 minutos") → `at` o `systemd-run --on-active=`.**
- **Nunca** edites a mano un crontab en un nodo de la flota. Distribuilo mediante gestión de configuración como archivo en `/etc/cron.d/` o como archivo de unidad, para que sea revisable, comparable y reversible.

### 2.2 Implementaciones de cron con las que te vas a encontrar

| Implementación | Por defecto en | Comportamiento destacable |
|---|---|---|
| `cronie` (fork de Vixie cron) | RHEL/Rocky/Alma/Fedora, openSUSE, Arch | `inotify` sobre el spool → `crontab -e` tiene efecto al instante; consciente de PAM (`/etc/pam.d/crond`); integración con syslog vía `-s`; `/etc/sysconfig/crond` |
| `cron` de Debian (derivado de Vixie) | Debian, Ubuntu | Consulta el mtime del spool cada minuto; reglas estrictas de nombre de archivo en `/etc/cron.d` (nomenclatura `run-parts`: sin puntos); `/etc/default/cron` |
| `bcron`, `fcron`, `dcron` | nicho | `fcron` agrega "ejecutar si el sistema estuvo caído", serialización de trabajos, intervalos `@` de forma nativa |
| `systemd-cron` | opcional | Generador que convierte crontabs en unidades timer transitorias |
| `busybox crond` | embebidos/contenedores | Mínimo; sin `@reboot` en algunas compilaciones; semántica de correo distinta |

Las respuestas del examen deben asumir **sintaxis compatible con Vixie**, que todas las anteriores respetan.

---

## 3. Internals de cron

### 3.1 Arquitectura del demonio

```
                    ┌──────────────────────────────────────────┐
   crontab(1)  ──►  │  /var/spool/cron/crontabs/<user>  (0600) │  ← per-user, no user field
   (setgid crontab) └──────────────────────────────────────────┘
                    ┌──────────────────────────────────────────┐
   package mgr ──►  │  /etc/crontab                            │  ← system, HAS user field
   config mgmt ──►  │  /etc/cron.d/*                           │  ← system, HAS user field
                    └──────────────────────────────────────────┘
                                     │
                                     ▼
                          ┌────────────────────┐
                          │  crond (PID 1 child)│  wakes every 60 s (or on inotify)
                          │  reload if mtime ↑  │
                          └────────┬───────────┘
                                   │ match minute
                                   ▼
                     fork() ─► setgid/setuid(user)  [+ PAM session on cronie]
                            ─► chdir($HOME)
                            ─► exec $SHELL -c "command"
                                   │
                          stdout+stderr ──► sendmail ──► MAILTO / job owner
                          exit status   ──► /dev/null   ← the silent-failure trap
```

Puntos que generan por igual preguntas de examen e incidentes en producción:

1. **`crond` nunca ejecuta un trabajo más de una vez por minuto por línea de crontab.** Programar por debajo del minuto con cron exige un bucle envoltorio — lo cual es un olor a mal diseño; usá un timer.
2. **Se capturan la stdout *y* la stderr del trabajo.** Si el comando produce **cualquier** salida, cron la envía por correo. Un trabajo que imprime una barra de progreso genera un correo en cada ejecución. Un trabajo que falla en silencio no genera nada.
3. **El código de salida se descarta.** `MAILTO` es un notificador de *salida*, no de *fallo*. Este es el hecho operativo más importante de todo el tema.
4. **cron no carga los archivos de login.** Ni `/etc/profile`, ni `~/.bash_profile`, ni `~/.bashrc` (este último porque `/bin/sh` no es interactivo y `BASH_ENV` no está definido).
5. **`crontab` es setgid `crontab`** (Debian) o setuid root (cronie), de modo que usuarios sin privilegios pueden escribir en un directorio de spool propiedad de root sin acceso de escritura directo. Nunca hagas `chmod` sobre el spool.

### 3.2 El formato de campos del crontab

```
# ┌───────────── minute        (0 - 59)
# │ ┌─────────── hour          (0 - 23)
# │ │ ┌───────── day of month  (1 - 31)
# │ │ │ ┌─────── month         (1 - 12, or jan..dec)
# │ │ │ │ ┌───── day of week   (0 - 7, 0 and 7 = Sunday, or sun..sat)
# │ │ │ │ │
# * * * * *  command to be executed
```

Operadores de campo:

| Operador | Ejemplo | Significado |
|---|---|---|
| `*` | `* * * * *` | todos los valores del campo |
| `,` lista | `0 2,14 * * *` | 02:00 y 14:00 |
| `-` rango | `0 9-17 * * 1-5` | cada hora, 09:00–17:00, lun–vie |
| `/` paso | `*/15 * * * *` | :00, :15, :30, :45 |
| rango + paso | `0 0-23/2 * * *` | cada 2 horas empezando a las 00:00 |
| nombres | `0 4 * * sun` | domingos (los nombres **no** son válidos en rangos/listas en todas las implementaciones — preferí números) |

**La regla OR de DOM/DOW — un ítem de examen garantizado.** Si *ambos*, día del mes y día de la semana, están restringidos (ninguno es `*`), cron ejecuta el trabajo cuando coincide **cualquiera** de los dos, no ambos:

```cron
# Runs on the 13th of every month, AND on every Friday. NOT only Friday the 13th.
0 3 13 * 5   /usr/local/bin/audit.sh
```

Para conseguir un AND real, restringí un campo a `*` y evaluá el otro dentro del comando:

```cron
# Truly only Friday the 13th
0 3 13 * *   [ "$(date +\%u)" -eq 5 ] && /usr/local/bin/audit.sh
```

**La trampa del `%` — el segundo ítem garantizado del examen.** En un comando de crontab, un `%` sin escapar se traduce a un salto de línea; todo lo que va después del *primer* `%` se convierte en la **entrada estándar** del comando. Por eso `date +%F` dentro de un crontab se rompe silenciosamente:

```cron
# WRONG — cron rewrites this to `date +` with "F" fed on stdin
0 1 * * *  /usr/bin/tar czf /backup/etc-$(date +%F).tgz /etc

# RIGHT — escape every percent
0 1 * * *  /usr/bin/tar czf /backup/etc-$(date +\%F).tgz /etc

# BEST — no percent in the crontab at all; put logic in a script
0 1 * * *  /usr/local/sbin/backup-etc
```

Uso deliberado del comportamiento de stdin:

```cron
# Everything after the first % is stdin for mailx
30 6 * * 1 /usr/bin/mailx -s "Weekly capacity" sre@example.com%Disk report follows:%%$(df -h)
```

### 3.3 Cadenas de programación especiales (apodos)

| Apodo | Equivalente | Notas |
|---|---|---|
| `@reboot` | — | Una vez, cuando arranca `crond`. **No** es "en cada arranque" si se reinicia cron; y **no** se ejecuta para `/etc/cron.d` en todas las implementaciones. Preferí una unidad de systemd con `WantedBy=multi-user.target`. |
| `@yearly`, `@annually` | `0 0 1 1 *` | |
| `@monthly` | `0 0 1 * *` | |
| `@weekly` | `0 0 * * 0` | |
| `@daily`, `@midnight` | `0 0 * * *` | |
| `@hourly` | `0 * * * *` | |

### 3.4 Variables de entorno dentro de un crontab

Las asignaciones deben aparecer **antes** de las líneas de programación que las usan; no hay expansión de shell en el lado derecho de una asignación de crontab (`PATH=$PATH:/opt/bin` **no** funciona).

```cron
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MAILTO=sre-oncall@example.com
MAILFROM=cron@web-07.example.com          # cronie only
CRON_TZ=UTC                               # Vixie/cronie: interpret schedules in this TZ
LANG=C.UTF-8
HOME=/var/lib/reporting

# MAILTO="" for this whole crontab would disable mail entirely.
```

Valores por defecto que cron define por su cuenta: `SHELL=/bin/sh`, `HOME` y `LOGNAME`/`USER` tomados de `/etc/passwd`, y un `PATH` mínimo (`/usr/bin:/bin` en el cron de Debian, `/sbin:/bin:/usr/sbin:/usr/bin` en cronie). Todo lo demás está ausente.

### 3.5 `crontab(1)` — los comandos de cara al usuario

| Comando | Efecto |
|---|---|
| `crontab -l` | Lista el crontab del usuario invocante por stdout |
| `crontab -e` | Edita vía `$VISUAL`/`$EDITOR`, verifica sintaxis, instala atómicamente |
| `crontab -r` | **Elimina** el crontab — sin confirmación. Peligrosamente cerca de `-e` en el teclado. |
| `crontab -i -r` | Elimina con confirmación |
| `crontab <file>` | **Reemplaza** el crontab desde un archivo (esta es la forma idempotente y automatizable) |
| `crontab -u alice -l` | Opera sobre el crontab de otro usuario (solo root) |
| `crontab -` | Lee el nuevo crontab desde stdin |

```console
$ crontab -l
no crontab for deploy

$ cat > /tmp/deploy.cron <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
MAILTO=sre-oncall@example.com

# m h dom mon dow  command
*/10 * * * *  /usr/bin/flock -n /run/lock/artifact-sync.lock /usr/local/bin/artifact-sync
17   4 * * *  /usr/local/bin/prune-registry --older-than 30d
EOF

$ crontab /tmp/deploy.cron
$ crontab -l
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
MAILTO=sre-oncall@example.com

# m h dom mon dow  command
*/10 * * * *  /usr/bin/flock -n /run/lock/artifact-sync.lock /usr/local/bin/artifact-sync
17   4 * * *  /usr/local/bin/prune-registry --older-than 30d

$ sudo ls -l /var/spool/cron/crontabs/deploy
-rw------- 1 deploy crontab 331 Aug 27 11:42 /var/spool/cron/crontabs/deploy
```

Fijate en la propiedad: archivo del usuario, grupo `crontab`, modo `0600`. En RHEL la ruta es `/var/spool/cron/deploy` y el grupo es `root`.

La validación de sintaxis ocurre en el momento de la instalación:

```console
$ echo '99 * * * * /bin/true' | crontab -
"/tmp/crontab.Xk29aB":1: bad minute
errors in crontab file, can't install.
```

**Disciplina de respaldo antes de tocar el crontab de un nodo de la flota:**

```console
$ crontab -l > ~/crontab.$(date +%F-%H%M).bak 2>/dev/null || echo "(none)"
$ sudo tar czf /root/crontabs-$(date +%F).tgz /var/spool/cron /etc/crontab /etc/cron.d /etc/cron.*ly
```

### 3.6 Crontabs de sistema: `/etc/crontab` y `/etc/cron.d/`

Estos archivos llevan un **sexto campo adicional — el usuario** — entre la programación y el comando. Esta es la diferencia sintáctica más evaluada de todo 107.2.

```console
$ cat /etc/crontab
SHELL=/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

# m h dom mon dow user  command
17 *    * * *   root    cd / && run-parts --report /etc/cron.hourly
25 6    * * *   root    test -x /usr/sbin/anacron || { cd / && run-parts --report /etc/cron.daily; }
47 6    * * 7   root    test -x /usr/sbin/anacron || { cd / && run-parts --report /etc/cron.weekly; }
52 6    1 * *   root    test -x /usr/sbin/anacron || { cd / && run-parts --report /etc/cron.monthly; }
```

Leelo con atención — codifica el **traspaso cron/anacron**: si `anacron` está instalado, los directorios daily/weekly/monthly *no* los ejecuta cron; anacron es su dueño.

`/etc/cron.d/` es el directorio de drop-in y el destino correcto para la gestión de configuración:

```console
$ sudo tee /etc/cron.d/node-exporter-textfile >/dev/null <<'EOF'
# Managed by Ansible — do not edit by hand.
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MAILTO=""

# m  h  dom mon dow  user       command
*/5  *  *   *   *    node_exp   /usr/local/bin/collect-textfile-metrics.sh
EOF
$ sudo chmod 0644 /etc/cron.d/node-exporter-textfile
$ sudo chown root:root /etc/cron.d/node-exporter-textfile
```

**Reglas de nombre de archivo en `/etc/cron.d` — un clásico de fallo silencioso.** El cron de Debian aplica la nomenclatura de `run-parts`: el nombre debe estar compuesto únicamente por `[A-Za-z0-9_-]`. Un archivo llamado `backup.cron`, `sync.sh` o `job.dpkg-new` es **ignorado sin ningún error**. cronie es más permisivo, pero igual saltea nombres que contienen `.` en algunas configuraciones. Nombrá siempre los drop-ins sin extensión.

Los archivos de `/etc/cron.d` deben ser archivos regulares, propiedad de root y no escribibles por grupo/otros, o cron los rechaza.

### 3.7 `run-parts` y los directorios `cron.{hourly,daily,weekly,monthly}`

```console
$ ls -l /etc/cron.daily/
total 20
-rwxr-xr-x 1 root root  311 Mar 22 09:14 0anacron
-rwxr-xr-x 1 root root 1478 Jan 11 03:02 apt-compat
-rwxr-xr-x 1 root root  123 Feb  2 17:40 dpkg
-rwxr-xr-x 1 root root  377 Apr  9 12:31 logrotate
-rwxr-xr-x 1 root root 1123 May 18 08:55 man-db

$ run-parts --test /etc/cron.daily
/etc/cron.daily/0anacron
/etc/cron.daily/apt-compat
/etc/cron.daily/dpkg
/etc/cron.daily/logrotate
/etc/cron.daily/man-db
```

Requisitos de `run-parts` para que un script se ejecute: **bit de ejecución activo**, **nombre de archivo válido** (solo `[A-Za-z0-9_-]` — por eso `logrotate` funciona y `logrotate.sh` no), y ejecuta los scripts en **orden lexicográfico de locale C** (de ahí el prefijo `0anacron` para forzarlo primero).

```console
$ sudo install -m 0755 /dev/stdin /etc/cron.daily/trim-container-images <<'EOF'
#!/bin/sh
set -eu
# Reclaim overlay2 space nightly; never fail the whole cron.daily run.
/usr/bin/podman image prune --all --force --filter "until=168h" >/dev/null 2>&1 || exit 0
EOF

$ run-parts --test /etc/cron.daily | grep trim
/etc/cron.daily/trim-container-images
```

`--report` (usado por el `/etc/crontab` de Debian) antepone el nombre del script a cualquier salida, así que un correo de `cron.daily` te dice *cuál* script habló.

---

## 4. `anacron` — planificación para máquinas que no están siempre encendidas

cron asume que la máquina está levantada en el instante programado. `anacron` asume que no, y en cambio lleva la cuenta de los **días transcurridos desde el último éxito del trabajo**.

### 4.1 `/etc/anacrontab`

```console
$ cat /etc/anacrontab
# /etc/anacrontab: configuration file for anacron
SHELL=/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
HOME=/root
LOGNAME=root

# These replace cron's entries
RANDOM_DELAY=45
START_HOURS_RANGE=3-22

# period(days)  delay(min)  job-identifier   command
1               5           cron.daily       run-parts --report /etc/cron.daily
7               25          cron.weekly      run-parts --report /etc/cron.weekly
@monthly        45          cron.monthly     run-parts --report /etc/cron.monthly
```

Semántica de los campos:

| Campo | Significado |
|---|---|
| **period** | Días entre ejecuciones. `1`, `7`, `30`, o `@daily`/`@weekly`/`@monthly`/`@yearly` |
| **delay** | Minutos a esperar tras el arranque de anacron antes de lanzar este trabajo — escalona la carga de arranque |
| **job-identifier** | Nombre único; pasa a ser el nombre del archivo de marca temporal bajo `/var/spool/anacron/` y el nombre del lock |
| **command** | Ejecutado vía `SHELL -c` |

`RANDOM_DELAY=45` agrega entre 0 y 45 minutos extra — **jitter incorporado**, el control anti-estampida del que cron carece.
`START_HOURS_RANGE=3-22` impide que los trabajos arranquen entre las 22:00 y las 03:00.

### 4.2 El spool de marcas temporales

```console
$ ls -l /var/spool/anacron/
total 12
-rw------- 1 root root 9 Aug 27 03:11 cron.daily
-rw------- 1 root root 9 Aug 24 03:47 cron.monthly
-rw------- 1 root root 9 Aug 25 03:22 cron.weekly

$ cat /var/spool/anacron/cron.daily
20260827
```

anacron compara la fecha de hoy con esa marca. Si `hoy - marca >= period`, el trabajo está vencido. La marca se escribe **solo al completarse con éxito**, lo que le da a anacron su propiedad de reintentar-hasta-lograrlo.

### 4.3 Ejecutar y probar anacron

```console
$ sudo anacron -T && echo "anacrontab syntax OK"
anacrontab syntax OK

$ sudo anacron -n -d cron.daily          # -n: run now, ignore delays; -d: foreground, log to stderr
Anacron 2.3 started on 2026-08-27
Will run job `cron.daily' in 0 min.
Jobs will be executed sequentially
Job `cron.daily' started
/etc/cron.daily/logrotate:
/etc/cron.daily/man-db:
Job `cron.daily' terminated
Normal exit (1 job run)

$ sudo anacron -u                        # update timestamps WITHOUT running anything
$ sudo anacron -f                        # force: run all jobs regardless of timestamps
$ sudo anacron -s                        # serialise: never run two jobs concurrently
```

En las distribuciones modernas, a anacron lo dispara un timer de systemd en lugar de cron:

```console
$ systemctl list-timers anacron.timer
NEXT                        LEFT       LAST                        PASSED     UNIT          ACTIVATES
Wed 2026-08-27 15:30:00 -03 3h 47min   Wed 2026-08-27 14:30:00 -03 12min ago  anacron.timer anacron.service

$ systemctl cat anacron.timer
# /usr/lib/systemd/system/anacron.timer
[Unit]
Description=Trigger anacron every hour

[Timer]
OnCalendar=*-*-* 00..23:30
RandomizedDelaySec=5m
Persistent=true

[Install]
WantedBy=timers.target
```

### 4.4 anacron vs cron — cuándo corresponde cada uno

| Escenario | Herramienta correcta | Motivo |
|---|---|---|
| Servidor 24×7, ejecutar exactamente a las 02:00 | cron / timer | La precisión importa, la máquina siempre está levantada |
| Laptop o VM de desarrollo, "más o menos a diario" | anacron | Sobrevive a estar apagada |
| Sub-diario (cada 15 min) | cron / timer | El período mínimo de anacron es 1 día |
| El trabajo debe correr como usuario no root | cron / timer | `/etc/anacrontab` no tiene campo de usuario; corre como root |
| Nocturno en toda la flota con jitter | anacron o timer con `RandomizedDelaySec` | Control de estampida |
| Hora del día precisa + recuperación | timer de systemd con `Persistent=true` | anacron no puede fijar una hora del día |

---

## 5. `at`, `batch`, `atq`, `atrm` — ejecución diferida de un solo disparo

### 5.1 El demonio `atd` y el spool de trabajos

```console
$ systemctl status atd
● atd.service - Deferred execution scheduler
     Loaded: loaded (/lib/systemd/system/atd.service; enabled; preset: enabled)
     Active: active (running) since Wed 2026-08-27 08:02:14 -03; 6h ago
       Docs: man:atd(8)
   Main PID: 743 (atd)
      Tasks: 1 (limit: 4653)
     Memory: 452.0K
        CPU: 11ms
     CGroup: /system.slice/atd.service
             └─743 /usr/sbin/atd -f
```

`at` captura el **entorno actual completo** (excepto `TERM`, `DISPLAY` y `_`) más el directorio de trabajo actual y la umask, los escribe en un script de shell bajo el spool y los reproduce en el momento de la ejecución. Esta es la diferencia de comportamiento crucial respecto de cron:

```console
$ sudo ls -l /var/spool/cron/atjobs/          # Debian; RHEL: /var/spool/at/
total 8
-rwx------ 1 deploy deploy 5891 Aug 27 14:41 a0000c01c6f2b1
-rwx------ 1 root   root      0 Aug 27 08:02 .SEQ

$ sudo head -20 /var/spool/cron/atjobs/a0000c01c6f2b1
#!/bin/sh
# atrun uid=1001 gid=1001
# mail deploy 0
umask 22
LANG=en_US.UTF-8; export LANG
PATH=/usr/local/bin:/usr/bin:/bin; export PATH
HOME=/home/deploy; export HOME
LOGNAME=deploy; export LOGNAME
USER=deploy; export USER
SHELL=/bin/bash; export SHELL
PWD=/srv/app; export PWD
cd /srv/app || {
	 echo 'Execution directory inaccessible' >&2
	 exit 1
}
${SHELL:-/bin/sh} << 'marcinDELIMITER0a1b2c3d'
/usr/local/bin/rollback-release --to v4.2.1
marcinDELIMITER0a1b2c3d
```

Fijate en `# mail deploy 0` — el `0` final significa "enviar correo solo si hay salida"; `at -m` lo cambia para que envíe correo incondicionalmente.

### 5.2 Gramática de especificación de tiempo

| Forma | Ejemplo |
|---|---|
| Reloj absoluto | `at 23:45`, `at 4pm`, `at 16:00` |
| Horas con nombre | `at noon`, `at midnight`, `at teatime` (16:00) |
| Reloj + fecha | `at 10:00 Aug 30`, `at 10:00 2026-08-30`, `at 4pm + 3 days` |
| Formatos de fecha | `MMDDYY`, `MM/DD/YY`, `DD.MM.YYYY`, `YYYY-MM-DD` |
| Relativo | `at now + 30 minutes`, `at now + 2 hours`, `at now + 1 week` |
| Unidades relativas | `minutes`, `hours`, `days`, `weeks`, `months`, `years` |
| Sufijos | `at 12:00 today`, `at 12:00 tomorrow`, `at 9am UTC` |
| Desde un archivo | `at -f script.sh 03:00` |
| Selección de cola | `at -q d now + 1 hour` (colas `a`–`z`, `A`–`Z`) |

La letra de la cola determina el nivel de nice: la cola `a` corre con nice 0, la `b` con nice 1, … cada letra posterior un escalón más "amable". Las colas en mayúscula son colas de `batch`. Por defecto: `a` para `at`, `b` para `batch`.

### 5.3 Sesión práctica

```console
$ at now + 15 minutes
warning: commands will be executed using /bin/sh
at> /usr/local/bin/drain-node --node web-07 --grace 300
at> /usr/bin/systemctl stop nginx.service
at> <EOT>
job 12 at Wed Aug 27 15:02:00 2026

$ at -f /usr/local/sbin/quarterly-close.sh 02:00 2026-10-01
job 13 at Thu Oct  1 02:00:00 2026

$ echo '/usr/local/bin/expire-tokens --batch' | at -M 03:30 tomorrow
job 14 at Thu Aug 28 03:30:00 2026
```

`-M` suprime el correo por completo; `-m` fuerza el correo incluso sin salida.

```console
$ atq
13	Thu Oct  1 02:00:00 2026 a deploy
12	Wed Aug 27 15:02:00 2026 a deploy
14	Thu Aug 28 03:30:00 2026 a deploy

$ at -c 12 | tail -5
${SHELL:-/bin/sh} << 'marcinDELIMITER00000001'
/usr/local/bin/drain-node --node web-07 --grace 300
/usr/bin/systemctl stop nginx.service

marcinDELIMITER00000001

$ atrm 12
$ atq
13	Thu Oct  1 02:00:00 2026 a deploy
14	Thu Aug 28 03:30:00 2026 a deploy
```

Root ve los trabajos de todos los usuarios; un usuario normal solo ve los propios. `atq` es `at -l`; `atrm` es `at -d` / `at -r`.

### 5.4 `batch` — ejecución condicionada a la carga media

```console
$ batch
warning: commands will be executed using /bin/sh
at> /usr/local/bin/reindex-search-corpus --full
at> <EOT>
job 15 at Wed Aug 27 14:47:00 2026

$ atq
15	Wed Aug 27 14:47:00 2026 b deploy
```

El trabajo queda elegible de inmediato, pero `atd` no lo va a arrancar mientras la carga media de 1 minuto supere el umbral (por defecto **1.5**, o 0,8 × cantidad de CPUs en algunas compilaciones). Cambialo con `atd -l <loadavg>`:

```console
$ sudo systemctl edit atd.service
### /etc/systemd/system/atd.service.d/override.conf
[Service]
ExecStart=
ExecStart=/usr/sbin/atd -f -l 6.0 -b 120

$ sudo systemctl daemon-reload && sudo systemctl restart atd
$ ps -o args= -C atd
/usr/sbin/atd -f -l 6.0 -b 120
```

`-b` fija el intervalo mínimo en segundos entre el inicio de dos trabajos batch (por defecto 60), serializando el trabajo pesado.

### 5.5 Limitaciones de `at` que hay que contemplar en el diseño

- **No es persistente ante una ventana perdida del modo que esperarías**: si la máquina está apagada a la hora objetivo, `atd` ejecuta el trabajo en su siguiente arranque — arbitrariamente tarde, sin ninguna verificación de plazo.
- **Sin repetición.** Un trabajo `at` que se reprograma a sí mismo (uno que termina con `at now + 1 hour -f "$0"`) es un antipatrón conocido: una sola ejecución fallida corta la cadena para siempre, en silencio.
- **El entorno capturado puede quedar obsoleto.** Un trabajo programado con tres semanas de anticipación reproduce un `PATH` y un `PWD` de hace tres semanas.
- **Los trabajos son scripts planos en el spool.** Cualquiera que pueda leer el spool lee tu línea de comandos; nunca incrustes secretos.

---

## 6. Control de acceso: `cron.allow` / `cron.deny` / `at.allow` / `at.deny`

El orden de evaluación es idéntico para ambos subsistemas y es una pregunta de examen segura.

```
                 ┌──────────────────────────────┐
                 │ Does /etc/cron.allow exist?  │
                 └───────────┬──────────────────┘
                     yes     │      no
              ┌──────────────┘      └──────────────┐
              ▼                                    ▼
   User listed in cron.allow?         ┌──────────────────────────────┐
        yes → ALLOW                   │ Does /etc/cron.deny exist?   │
        no  → DENY                    └────────┬─────────────────────┘
   (cron.deny is IGNORED entirely)      yes    │    no
                                  ┌────────────┘    └──────────────┐
                                  ▼                                ▼
                    User listed in cron.deny?        Site-dependent default:
                         yes → DENY                  Debian/Ubuntu → all users allowed
                         no  → ALLOW                 RHEL/cronie   → root only
```

Reglas para memorizar:

1. **`*.allow` gana.** Si existe, `*.deny` no se consulta en absoluto.
2. **Un nombre de usuario por línea.** Sin comentarios, sin grupos, sin comodines, sin tolerancia a espacios.
3. **`root` normalmente está exento** para `cron` en la mayoría de las implementaciones, pero en cronie root sí queda sujeto a `cron.allow` si ese archivo existe — con lo cual un `/etc/cron.allow` que omita a `root` puede dejar a root afuera de `crontab -e`. Incluí siempre a `root`.
4. Estos archivos controlan los **comandos `crontab`/`at`**, no el demonio. Un crontab ya instalado en el spool sigue ejecutándose aun después de que se le deniegue el acceso a su dueño. Quitar el acceso ≠ quitar el trabajo programado.
5. `/etc/cron.d` y `/etc/crontab` esquivan todo esto por completo — son archivos gestionados por root.

```console
$ sudo tee /etc/cron.allow >/dev/null <<'EOF'
root
deploy
backup
EOF
$ sudo chmod 0600 /etc/cron.allow
$ sudo chown root:root /etc/cron.allow

$ sudo -u www-data crontab -l
You (www-data) are not allowed to use this program (crontab)
See crontab(1) for more information

$ sudo -u deploy crontab -l
SHELL=/bin/bash
...
```

La misma mecánica para `at`:

```console
$ sudo sh -c 'echo www-data >> /etc/at.deny'
$ sudo -u www-data at now + 1 minute
You do not have permission to use at.
```

Postura básica de endurecimiento en un nodo de la flota (denegar por defecto, permitir una lista corta):

```console
$ sudo install -m 0600 -o root -g root /dev/stdin /etc/cron.allow <<'EOF'
root
deploy
EOF
$ sudo install -m 0600 -o root -g root /dev/stdin /etc/at.allow <<'EOF'
root
EOF
$ sudo rm -f /etc/cron.deny /etc/at.deny     # ignored anyway once *.allow exists; remove to avoid confusion
```

Verificación, incluida la salvedad de "el crontab ya instalado sobrevive":

```console
$ for u in $(cut -d: -f1 /etc/passwd); do
>   out=$(sudo crontab -u "$u" -l 2>/dev/null) && [ -n "$out" ] && echo "== $u"
> done
== root
== deploy
== www-data          # ← still scheduled despite being denied. Remove it explicitly.

$ sudo crontab -u www-data -r
```

---

## 7. Timers de systemd — la alternativa supervisada

### 7.1 El modelo de dos unidades

Un timer nunca contiene el comando. Activa una **unidad** — por defecto el `.service` con la misma raíz de nombre.

```console
$ sudo tee /etc/systemd/system/registry-prune.service >/dev/null <<'EOF'
[Unit]
Description=Prune container registry blobs older than 30 days
Documentation=https://internal.example.com/runbooks/registry-prune
After=network-online.target
Wants=network-online.target
# Refuse to run if the registry volume is not mounted.
ConditionPathIsMountPoint=/srv/registry

[Service]
Type=oneshot
User=registry
Group=registry

# Deterministic environment — the thing cron never gives you.
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=LANG=C.UTF-8
Environment=REGISTRY_URL=https://registry.example.com
EnvironmentFile=-/etc/default/registry-prune

WorkingDirectory=/srv/registry
ExecStart=/usr/local/bin/registry-prune --older-than 30d --confirm

# Bound the blast radius.
TimeoutStartSec=45min
Restart=on-failure
RestartSec=5min
StartLimitBurst=3

# cgroup resource containment — no cron equivalent exists.
MemoryMax=2G
MemoryHigh=1500M
CPUQuota=150%
IOWeight=20
Nice=10

# Sandboxing.
NoNewPrivileges=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
ReadWritePaths=/srv/registry
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictNamespaces=yes
LockPersonality=yes
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM
CapabilityBoundingSet=

# Structured logging.
StandardOutput=journal
StandardError=journal
SyslogIdentifier=registry-prune

[Install]
WantedBy=multi-user.target
EOF
```

```console
$ sudo tee /etc/systemd/system/registry-prune.timer >/dev/null <<'EOF'
[Unit]
Description=Nightly registry prune
Documentation=https://internal.example.com/runbooks/registry-prune

[Timer]
# Every day at 03:15 local time.
OnCalendar=*-*-* 03:15:00

# Fleet-wide herd control: spread starts across a 40-minute window.
RandomizedDelaySec=40m

# Let systemd coalesce this with nearby timers to save wakeups.
AccuracySec=1min

# If the machine was off at 03:15, run as soon as it is up again.
Persistent=true

# Belt-and-braces overlap guard (the unit being active already blocks re-trigger).
# Fail loudly if the service is somehow still running after 12 hours.
Unit=registry-prune.service

[Install]
WantedBy=timers.target
EOF
```

Unidad complementaria de notificación de fallos — la pieza que cron estructuralmente no puede aportar:

```console
$ sudo tee /etc/systemd/system/notify-failure@.service >/dev/null <<'EOF'
[Unit]
Description=Alert on failure of %i

[Service]
Type=oneshot
ExecStart=/usr/local/bin/alert-webhook \
    --severity critical \
    --unit "%i" \
    --host "%H" \
    --message "systemd unit %i failed on %H"
EOF

$ sudo mkdir -p /etc/systemd/system/registry-prune.service.d
$ sudo tee /etc/systemd/system/registry-prune.service.d/onfailure.conf >/dev/null <<'EOF'
[Unit]
OnFailure=notify-failure@%n.service
EOF
```

Activar y verificar:

```console
$ sudo systemd-analyze verify /etc/systemd/system/registry-prune.{service,timer}
$ sudo systemctl daemon-reload
$ sudo systemctl enable --now registry-prune.timer
Created symlink /etc/systemd/system/timers.target.wants/registry-prune.timer → /etc/systemd/system/registry-prune.timer.

$ systemctl list-timers registry-prune.timer
NEXT                        LEFT     LAST                        PASSED  UNIT                  ACTIVATES
Thu 2026-08-28 03:15:00 -03 12h left Wed 2026-08-27 03:15:00 -03 11h ago registry-prune.timer  registry-prune.service

1 timers listed.
```

### 7.2 Sintaxis de `OnCalendar` y `systemd-analyze calendar`

Formato: `DayOfWeek Year-Month-Day Hour:Minute:Second [Timezone]`

| Expresión | Significado |
|---|---|
| `hourly` | `*-*-* *:00:00` |
| `daily` | `*-*-* 00:00:00` |
| `weekly` | `Mon *-*-* 00:00:00` |
| `monthly` | `*-*-01 00:00:00` |
| `*-*-* 03:15:00` | Diario a las 03:15 |
| `Mon..Fri *-*-* 09:00` | Días hábiles a las 09:00 |
| `*-*-* *:0/15` | Cada 15 minutos |
| `*-*-* *:*:0/30` | Cada 30 segundos |
| `Mon *-*-1..7 04:00` | Primer lunes del mes |
| `*-01,04,07,10-01 00:00` | Trimestral |
| `2026-12-31 23:59` | Un instante específico |
| `*-*-* 02:00 UTC` | Fijado a UTC, inmune al horario de verano |

Validá siempre antes de desplegar — este es el equivalente en timers a la verificación de sintaxis de `crontab`:

```console
$ systemd-analyze calendar --iterations=5 'Mon *-*-1..7 04:00:00'
  Original form: Mon *-*-1..7 04:00:00
Normalized form: Mon *-*-01..07 04:00:00
    Next elapse: Mon 2026-09-07 04:00:00 -03
       (in UTC): Mon 2026-09-07 07:00:00 UTC
       From now: 1 week 3 days left
       Iter. #2: Mon 2026-10-05 04:00:00 -03
       (in UTC): Mon 2026-10-05 07:00:00 UTC
       From now: 1 month 8 days left
       Iter. #3: Mon 2026-11-02 04:00:00 -03
       (in UTC): Mon 2026-11-02 07:00:00 UTC
       From now: 2 months 6 days left
       Iter. #4: Mon 2026-12-07 04:00:00 -03
       (in UTC): Mon 2026-12-07 07:00:00 UTC
       From now: 3 months 10 days left
       Iter. #5: Mon 2026-01-04 04:00:00 -03
       From now: 4 months 8 days left

$ systemd-analyze calendar 'Mon *-*-* 25:00'
Failed to parse calendar expression: Invalid argument
```

Timers monotónicos (relativos a un evento, no al reloj de pared) — imposibles con cron:

```ini
[Timer]
OnBootSec=15min           # 15 min after boot
OnStartupSec=10min        # 10 min after systemd itself started
OnUnitActiveSec=6h        # 6 h after the unit last ACTIVATED  → true "every 6 hours of uptime"
OnUnitInactiveSec=1h      # 1 h after the unit last DEACTIVATED → true "1 h after it finished"
OnActiveSec=30s           # 30 s after the timer itself was activated
```

`OnUnitActiveSec` frente al `0 */6 * * *` de cron: cron dispara en horas de reloj fijas sin importar si la ejecución anterior tardó cinco horas; `OnUnitActiveSec=6h` mide desde el último inicio real, que es lo que "cada seis horas" significa casi siempre en términos operativos.

### 7.3 `systemd-run` — trabajos transitorios, el reemplazo de `at`

```console
$ sudo systemd-run --on-active=20min --unit=drain-web07 \
>      /usr/local/bin/drain-node --node web-07 --grace 300
Running timer as unit: drain-web07.timer
Will run service as unit: drain-web07.service

$ systemctl list-timers drain-web07.timer
NEXT                        LEFT       LAST PASSED UNIT              ACTIVATES
Wed 2026-08-27 15:09:41 -03 19min left -    -      drain-web07.timer drain-web07.service

$ sudo systemd-run --on-calendar='*-*-* 02:00:00' --unit=nightly-vacuum \
>      --property=MemoryMax=4G --property=Nice=15 \
>      /usr/bin/psql -c 'VACUUM (ANALYZE);'
Running timer as unit: nightly-vacuum.timer
Will run service as unit: nightly-vacuum.service

$ sudo systemctl stop drain-web07.timer          # equivalent of atrm
```

Ejecución ad-hoc, con tope de recursos, de un solo disparo y en primer plano — útil para probar el cuerpo exacto del trabajo que ejecutará un timer:

```console
$ sudo systemd-run --scope --unit=test-prune -p MemoryMax=512M -p CPUQuota=50% \
>      /usr/local/bin/registry-prune --dry-run
Running scope as unit: test-prune.scope
[dry-run] would delete 1,284 blobs (18.4 GiB)
```

### 7.4 Migrar una línea de crontab a un timer, mecánicamente

| crontab | timer |
|---|---|
| `*/10 * * * *` | `OnCalendar=*:0/10` |
| `0 3 * * *` | `OnCalendar=*-*-* 03:00:00` |
| `0 3 * * 1` | `OnCalendar=Mon *-*-* 03:00:00` |
| `0 0 1 * *` | `OnCalendar=*-*-01 00:00:00` |
| `@reboot` | `OnBootSec=1min` (o simplemente `WantedBy=multi-user.target`, sin timer) |
| `MAILTO=x` | `OnFailure=` + una unidad de notificación — y dispara ante un *fallo*, no ante salida |
| `flock -n /run/lock/x` | no hace falta nada: una unidad activa no puede volver a dispararse |
| `sleep $((RANDOM % 1800))` | `RandomizedDelaySec=30m` |
| `nice -n 19 ionice -c3 cmd` | `Nice=19`, `IOSchedulingClass=idle` |

---

## 8. Manifiestos de infraestructura completos

### 8.1 Rol de Ansible — planificación idempotente y declarativa

`roles/scheduling/defaults/main.yml`

```yaml
---
# Managed scheduled jobs. Every entry is rendered into /etc/cron.d/ or a
# systemd timer pair depending on `scheduling_backend`.
scheduling_backend: systemd          # systemd | cron

scheduling_cron_allow:
  - root
  - deploy

scheduling_at_allow:
  - root

scheduling_jobs:
  - name: registry-prune
    description: Prune container registry blobs older than 30 days
    user: registry
    group: registry
    command: /usr/local/bin/registry-prune --older-than 30d --confirm
    working_directory: /srv/registry
    cron_schedule: "15 3 * * *"
    calendar: "*-*-* 03:15:00"
    randomized_delay: 40m
    persistent: true
    memory_max: 2G
    cpu_quota: 150%
    nice: 10
    timeout: 45min
    read_write_paths:
      - /srv/registry
    environment:
      REGISTRY_URL: https://registry.example.com

  - name: metrics-textfile
    description: Collect node textfile metrics
    user: node_exp
    group: node_exp
    command: /usr/local/bin/collect-textfile-metrics.sh
    working_directory: /var/lib/node_exporter
    cron_schedule: "*/5 * * * *"
    calendar: "*:0/5"
    randomized_delay: 20s
    persistent: false
    memory_max: 256M
    cpu_quota: 25%
    nice: 19
    timeout: 2min
    read_write_paths:
      - /var/lib/node_exporter/textfile_collector
    environment: {}

  - name: cert-renew
    description: Renew ACME certificates and reload nginx
    user: root
    group: root
    command: /usr/local/sbin/renew-certs --reload nginx
    working_directory: /etc/ssl
    cron_schedule: "42 2,14 * * *"
    calendar: "*-*-* 02,14:42:00"
    randomized_delay: 1h
    persistent: true
    memory_max: 512M
    cpu_quota: 50%
    nice: 0
    timeout: 15min
    read_write_paths:
      - /etc/ssl
      - /var/lib/acme
    environment:
      ACME_DIRECTORY: https://acme-v02.api.letsencrypt.org/directory
```

`roles/scheduling/tasks/main.yml`

```yaml
---
- name: Assert a supported backend was selected
  ansible.builtin.assert:
    that:
      - scheduling_backend in ['systemd', 'cron']
    fail_msg: "scheduling_backend must be 'systemd' or 'cron', got '{{ scheduling_backend }}'"

- name: Install scheduling packages
  ansible.builtin.package:
    name: "{{ scheduling_packages }}"
    state: present
  vars:
    scheduling_packages: >-
      {{ ['cronie', 'at'] if ansible_os_family == 'RedHat'
         else ['cron', 'anacron', 'at'] }}

# ------------------------------------------------------------------ access
- name: Deploy cron access allow-list
  ansible.builtin.copy:
    content: "{{ scheduling_cron_allow | join('\n') }}\n"
    dest: /etc/cron.allow
    owner: root
    group: root
    mode: "0600"

- name: Deploy at access allow-list
  ansible.builtin.copy:
    content: "{{ scheduling_at_allow | join('\n') }}\n"
    dest: /etc/at.allow
    owner: root
    group: root
    mode: "0600"

- name: Remove deny files (ignored when allow-lists exist; removed to avoid ambiguity)
  ansible.builtin.file:
    path: "/etc/{{ item }}"
    state: absent
  loop:
    - cron.deny
    - at.deny

# ------------------------------------------------------------------ cron backend
- name: Deploy cron drop-ins
  ansible.builtin.template:
    src: cron.d.j2
    # Filename MUST match run-parts rules: [A-Za-z0-9_-] only, no extension.
    dest: "/etc/cron.d/{{ item.name | regex_replace('[^A-Za-z0-9_-]', '-') }}"
    owner: root
    group: root
    mode: "0644"
    validate: /bin/sh -c 'test -r %s'
  loop: "{{ scheduling_jobs }}"
  loop_control:
    label: "{{ item.name }}"
  when: scheduling_backend == 'cron'

- name: Remove cron drop-ins when the systemd backend is active
  ansible.builtin.file:
    path: "/etc/cron.d/{{ item.name | regex_replace('[^A-Za-z0-9_-]', '-') }}"
    state: absent
  loop: "{{ scheduling_jobs }}"
  loop_control:
    label: "{{ item.name }}"
  when: scheduling_backend == 'systemd'

# ------------------------------------------------------------------ systemd backend
- name: Deploy failure-notification template unit
  ansible.builtin.copy:
    src: notify-failure@.service
    dest: /etc/systemd/system/notify-failure@.service
    owner: root
    group: root
    mode: "0644"
  notify: systemd daemon-reload
  when: scheduling_backend == 'systemd'

- name: Deploy service units
  ansible.builtin.template:
    src: job.service.j2
    dest: "/etc/systemd/system/{{ item.name }}.service"
    owner: root
    group: root
    mode: "0644"
  loop: "{{ scheduling_jobs }}"
  loop_control:
    label: "{{ item.name }}.service"
  notify: systemd daemon-reload
  when: scheduling_backend == 'systemd'

- name: Deploy timer units
  ansible.builtin.template:
    src: job.timer.j2
    dest: "/etc/systemd/system/{{ item.name }}.timer"
    owner: root
    group: root
    mode: "0644"
  loop: "{{ scheduling_jobs }}"
  loop_control:
    label: "{{ item.name }}.timer"
  notify: systemd daemon-reload
  when: scheduling_backend == 'systemd'

- name: Flush unit handlers before enabling timers
  ansible.builtin.meta: flush_handlers

- name: Validate every deployed unit parses
  ansible.builtin.command:
    argv:
      - systemd-analyze
      - verify
      - "/etc/systemd/system/{{ item.name }}.timer"
  loop: "{{ scheduling_jobs }}"
  loop_control:
    label: "{{ item.name }}"
  changed_when: false
  when: scheduling_backend == 'systemd'

- name: Enable and start timers
  ansible.builtin.systemd_service:
    name: "{{ item.name }}.timer"
    enabled: true
    state: started
  loop: "{{ scheduling_jobs }}"
  loop_control:
    label: "{{ item.name }}.timer"
  when: scheduling_backend == 'systemd'

# ------------------------------------------------------------------ daemons
- name: Ensure the cron daemon is running
  ansible.builtin.systemd_service:
    name: "{{ 'crond' if ansible_os_family == 'RedHat' else 'cron' }}"
    enabled: true
    state: started

- name: Ensure atd is running
  ansible.builtin.systemd_service:
    name: atd
    enabled: true
    state: started
```

`roles/scheduling/templates/cron.d.j2`

```jinja
# {{ item.description }}
# Managed by Ansible ({{ ansible_managed }}). Local edits will be overwritten.
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MAILTO=""
{% for k, v in (item.environment | default({})).items() %}
{{ k }}={{ v }}
{% endfor %}

# m h dom mon dow user command
{{ item.cron_schedule }} {{ item.user }} cd {{ item.working_directory }} && /usr/bin/flock -n /run/lock/{{ item.name }}.lock /usr/bin/nice -n {{ item.nice }} /usr/bin/timeout {{ item.timeout | replace('min','m') }} {{ item.command }} 2>&1 | /usr/bin/logger -t {{ item.name }}
```

`roles/scheduling/templates/job.service.j2`

```jinja
# {{ ansible_managed }}
[Unit]
Description={{ item.description }}
After=network-online.target
Wants=network-online.target
OnFailure=notify-failure@%n.service

[Service]
Type=oneshot
User={{ item.user }}
Group={{ item.group }}
WorkingDirectory={{ item.working_directory }}

Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=LANG=C.UTF-8
{% for k, v in (item.environment | default({})).items() %}
Environment={{ k }}={{ v }}
{% endfor %}
EnvironmentFile=-/etc/default/{{ item.name }}

ExecStart={{ item.command }}

TimeoutStartSec={{ item.timeout }}
Restart=on-failure
RestartSec=5min
StartLimitBurst=3

MemoryMax={{ item.memory_max }}
CPUQuota={{ item.cpu_quota }}
Nice={{ item.nice }}
IOSchedulingClass=best-effort
IOWeight=20

NoNewPrivileges=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictNamespaces=yes
LockPersonality=yes
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM
{% for p in item.read_write_paths | default([]) %}
ReadWritePaths={{ p }}
{% endfor %}

StandardOutput=journal
StandardError=journal
SyslogIdentifier={{ item.name }}

[Install]
WantedBy=multi-user.target
```

`roles/scheduling/templates/job.timer.j2`

```jinja
# {{ ansible_managed }}
[Unit]
Description=Timer for {{ item.description }}

[Timer]
OnCalendar={{ item.calendar }}
RandomizedDelaySec={{ item.randomized_delay }}
AccuracySec=1min
Persistent={{ 'true' if item.persistent else 'false' }}
Unit={{ item.name }}.service

[Install]
WantedBy=timers.target
```

`roles/scheduling/handlers/main.yml`

```yaml
---
- name: systemd daemon-reload
  ansible.builtin.systemd_service:
    daemon_reload: true
```

### 8.2 cloud-init — planificación integrada en el primer arranque

```yaml
#cloud-config
# Provisions a node with a hardened, fully declarative scheduling baseline.

package_update: true
package_upgrade: false
packages:
  - cron
  - anacron
  - at
  - util-linux          # provides flock
  - moreutils           # provides chronic (suppresses output unless the job fails)

users:
  - name: registry
    system: true
    shell: /usr/sbin/nologin
    homedir: /srv/registry

write_files:
  # ---------------------------------------------------------------- access control
  - path: /etc/cron.allow
    owner: root:root
    permissions: "0600"
    content: |
      root
      deploy

  - path: /etc/at.allow
    owner: root:root
    permissions: "0600"
    content: |
      root

  # ---------------------------------------------------------------- anacron tuning
  - path: /etc/anacrontab
    owner: root:root
    permissions: "0600"
    content: |
      SHELL=/bin/sh
      PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
      HOME=/root
      LOGNAME=root

      # Spread fleet-wide daily work over 45 minutes; never start after 22:00.
      RANDOM_DELAY=45
      START_HOURS_RANGE=3-22

      # period  delay  job-id         command
      1         5      cron.daily     nice run-parts --report /etc/cron.daily
      7         25     cron.weekly    nice run-parts --report /etc/cron.weekly
      @monthly  45     cron.monthly   nice run-parts --report /etc/cron.monthly

  # ---------------------------------------------------------------- units
  - path: /etc/systemd/system/registry-prune.service
    owner: root:root
    permissions: "0644"
    content: |
      [Unit]
      Description=Prune container registry blobs older than 30 days
      After=network-online.target
      Wants=network-online.target
      ConditionPathIsMountPoint=/srv/registry
      OnFailure=notify-failure@%n.service

      [Service]
      Type=oneshot
      User=registry
      Group=registry
      WorkingDirectory=/srv/registry
      Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
      Environment=LANG=C.UTF-8
      ExecStart=/usr/local/bin/registry-prune --older-than 30d --confirm
      TimeoutStartSec=45min
      Restart=on-failure
      RestartSec=5min
      MemoryMax=2G
      CPUQuota=150%
      Nice=10
      NoNewPrivileges=yes
      PrivateTmp=yes
      ProtectSystem=strict
      ProtectHome=yes
      ReadWritePaths=/srv/registry
      SystemCallFilter=@system-service
      StandardOutput=journal
      StandardError=journal
      SyslogIdentifier=registry-prune

      [Install]
      WantedBy=multi-user.target

  - path: /etc/systemd/system/registry-prune.timer
    owner: root:root
    permissions: "0644"
    content: |
      [Unit]
      Description=Nightly registry prune

      [Timer]
      OnCalendar=*-*-* 03:15:00
      RandomizedDelaySec=40m
      AccuracySec=1min
      Persistent=true

      [Install]
      WantedBy=timers.target

  - path: /etc/systemd/system/notify-failure@.service
    owner: root:root
    permissions: "0644"
    content: |
      [Unit]
      Description=Alert on failure of %i

      [Service]
      Type=oneshot
      ExecStart=/usr/local/bin/alert-webhook --severity critical --unit "%i" --host "%H"

  # ---------------------------------------------------------------- cron drop-in
  # Filename has no extension on purpose: /etc/cron.d honours run-parts naming
  # ([A-Za-z0-9_-] only) and silently ignores anything else.
  - path: /etc/cron.d/node-exporter-textfile
    owner: root:root
    permissions: "0644"
    content: |
      SHELL=/bin/bash
      PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
      MAILTO=""

      # m  h dom mon dow  user      command
      */5  * *   *   *    node_exp  /usr/bin/flock -n /run/lock/textfile.lock /usr/local/bin/collect-textfile-metrics.sh 2>&1 | /usr/bin/logger -t textfile-metrics

  - path: /etc/logrotate.d/scheduled-jobs
    owner: root:root
    permissions: "0644"
    content: |
      /var/log/scheduled-jobs/*.log {
          daily
          rotate 14
          compress
          delaycompress
          missingok
          notifempty
          create 0640 root adm
          sharedscripts
      }

runcmd:
  - [ install, -d, -m, "0755", -o, root, -g, root, /var/log/scheduled-jobs ]
  - [ install, -d, -m, "0750", -o, registry, -g, registry, /srv/registry ]
  - [ rm, -f, /etc/cron.deny, /etc/at.deny ]
  - [ systemctl, daemon-reload ]
  - [ systemctl, enable, --now, cron.service ]
  - [ systemctl, enable, --now, atd.service ]
  - [ systemctl, enable, --now, registry-prune.timer ]
  # Fail the boot loudly if any unit is malformed.
  - [ systemd-analyze, verify, /etc/systemd/system/registry-prune.timer ]

final_message: "Scheduling baseline provisioned after $UPTIME seconds."
```

### 8.3 `CronJob` de Kubernetes — el mismo problema, una capa más arriba

Se incluye porque vuelve concreta la tabla de compromisos: cada campo de abajo existe para reparar una deficiencia de cron listada en §1.

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: registry-prune
  namespace: platform
  labels:
    app.kubernetes.io/name: registry-prune
    app.kubernetes.io/component: maintenance
spec:
  # Same five-field cron expression the exam tests.
  schedule: "15 3 * * *"
  # Explicit timezone — the cron equivalent is CRON_TZ= or a UTC-pinned daemon.
  timeZone: "Etc/UTC"
  # Overlap prevention: the `flock` of the cluster world.
  concurrencyPolicy: Forbid
  # Missed-run policy: if the controller was down, only start if <10 min late.
  startingDeadlineSeconds: 600
  suspend: false
  # Observability: keep history instead of discarding exit codes like cron does.
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 5
  jobTemplate:
    spec:
      backoffLimit: 2
      activeDeadlineSeconds: 2700          # 45 min, mirrors TimeoutStartSec
      ttlSecondsAfterFinished: 86400
      template:
        metadata:
          labels:
            app.kubernetes.io/name: registry-prune
        spec:
          restartPolicy: Never
          serviceAccountName: registry-prune
          securityContext:
            runAsNonRoot: true
            runAsUser: 65534
            runAsGroup: 65534
            fsGroup: 65534
            seccompProfile:
              type: RuntimeDefault
          containers:
            - name: prune
              image: registry.example.com/platform/registry-prune:v1.8.3
              imagePullPolicy: IfNotPresent
              args: ["--older-than", "30d", "--confirm"]
              env:
                - name: REGISTRY_URL
                  value: https://registry.example.com
                - name: REGISTRY_TOKEN
                  valueFrom:
                    secretKeyRef:
                      name: registry-prune-credentials
                      key: token
              resources:
                requests:
                  cpu: 100m
                  memory: 256Mi
                limits:
                  cpu: 1500m
                  memory: 2Gi
              securityContext:
                allowPrivilegeEscalation: false
                readOnlyRootFilesystem: true
                capabilities:
                  drop: ["ALL"]
              volumeMounts:
                - name: tmp
                  mountPath: /tmp
          volumes:
            - name: tmp
              emptyDir:
                sizeLimit: 512Mi
```

Tabla de correspondencias:

| Control a nivel de host (107.2) | Equivalente en Kubernetes |
|---|---|
| `flock -n` | `concurrencyPolicy: Forbid` |
| `Persistent=true` | `startingDeadlineSeconds` (acotado, no recuperación ilimitada) |
| `TimeoutStartSec=` | `activeDeadlineSeconds` |
| `Restart=on-failure` + `StartLimitBurst` | `backoffLimit` |
| `MemoryMax=` / `CPUQuota=` | `resources.limits` |
| `ProtectSystem=strict` | `readOnlyRootFilesystem: true` |
| `CapabilityBoundingSet=` | `capabilities.drop: ["ALL"]` |
| `RandomizedDelaySec=` | **sin equivalente** — implementá el jitter en el entrypoint del contenedor |
| journald + `OnFailure=` | logs del pod + alerta sobre `kube_cronjob_status_last_successful_time` |

---

## 9. Patrones de producción que todo trabajo programado debería usar

### 9.1 Exclusión mutua con `flock`

```cron
# -n : fail immediately if the lock is held (do not queue up)
# -E 0 : exit 0 when the lock is busy, so the "skipped" case is not an alert
*/10 * * * * /usr/bin/flock -n -E 0 /run/lock/artifact-sync.lock /usr/local/bin/artifact-sync
```

```console
$ flock -n /tmp/demo.lock -c 'sleep 60' &
[1] 20913
$ flock -n /tmp/demo.lock -c 'echo ran'; echo "exit=$?"
exit=1
$ flock -n -E 0 /tmp/demo.lock -c 'echo ran'; echo "exit=$?"
exit=0
```

Usá `-w <seconds>` cuando querés que la segunda instancia espere un rato en vez de saltearse.

### 9.2 Silenciar el éxito, hacer visible el fallo

El contrato por defecto de cron ("mandame por correo toda la salida") produce fatiga de alertas. Invertilo con `chronic` (de `moreutils`), que almacena la salida en un búfer y la emite **solo** ante un código de salida distinto de cero:

```cron
MAILTO=sre-oncall@example.com
0 3 * * * /usr/bin/chronic /usr/local/bin/nightly-report
```

O enviá al journal y alertá explícitamente según el código de salida:

```cron
MAILTO=""
0 3 * * * /usr/local/bin/nightly-report 2>&1 | /usr/bin/logger -t nightly-report -p cron.info; \
          [ ${PIPESTATUS[0]} -eq 0 ] || /usr/local/bin/alert-webhook --unit nightly-report
```

(`PIPESTATUS` requiere `SHELL=/bin/bash` en el crontab.)

### 9.3 Monitoreo tipo dead-man's switch — la única solución real al fallo silencioso

Un trabajo que nunca corre no emite nada, así que no podés alertar sobre sus logs. Alertá sobre la **ausencia** de un latido de éxito:

```bash
#!/bin/bash
# /usr/local/bin/job-wrapper — run a job, emit Prometheus textfile metrics either way.
set -uo pipefail

JOB_NAME="$1"; shift
TEXTFILE_DIR=/var/lib/node_exporter/textfile_collector
OUT="${TEXTFILE_DIR}/job_${JOB_NAME}.prom"
START=$(date +%s)

"$@"
RC=$?

END=$(date +%s)

# Atomic write: node_exporter must never read a half-written file.
cat > "${OUT}.$$" <<EOF
# HELP scheduled_job_last_run_timestamp_seconds Unix time of the last completed run.
# TYPE scheduled_job_last_run_timestamp_seconds gauge
scheduled_job_last_run_timestamp_seconds{job="${JOB_NAME}"} ${END}
# HELP scheduled_job_last_exit_code Exit code of the last run.
# TYPE scheduled_job_last_exit_code gauge
scheduled_job_last_exit_code{job="${JOB_NAME}"} ${RC}
# HELP scheduled_job_duration_seconds Wall-clock duration of the last run.
# TYPE scheduled_job_duration_seconds gauge
scheduled_job_duration_seconds{job="${JOB_NAME}"} $((END - START))
EOF
mv -f "${OUT}.$$" "${OUT}"

exit "$RC"
```

```cron
0 3 * * * /usr/local/bin/job-wrapper registry-prune /usr/local/bin/registry-prune --older-than 30d
```

Regla de alerta correspondiente:

```yaml
groups:
  - name: scheduled-jobs
    rules:
      - alert: ScheduledJobNotRunning
        expr: |
          time() - scheduled_job_last_run_timestamp_seconds > 129600
        for: 15m
        labels:
          severity: warning
        annotations:
          summary: "Job {{ $labels.job }} has not completed in 36h on {{ $labels.instance }}"

      - alert: ScheduledJobFailing
        expr: scheduled_job_last_exit_code != 0
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "Job {{ $labels.job }} exited {{ $value }} on {{ $labels.instance }}"
```

### 9.4 Disciplina de zona horaria y horario de verano

El horario de verano es la fuente de los dos bugs más feos de cron:

- **Adelanto de reloj** (los relojes saltan de 02:00 → 03:00): un trabajo en `0 2 * * *` — esa hora de reloj de pared nunca ocurre. Vixie cron ejecuta una sola vez los trabajos programados dentro del intervalo salteado, inmediatamente después del salto; los trabajos con hora comodín no se repiten.
- **Atraso de reloj** (las 02:00 ocurren dos veces): un trabajo en `0 2 * * *` — Vixie cron suprime la segunda ocurrencia para trabajos de hora fija, pero los trabajos con hora comodín (`0 * * * *`) sí corren dos veces.

Reglas de producción:

1. **Corré los hosts de infraestructura en UTC.** `timedatectl set-timezone UTC`.
2. Si la hora local es obligatoria, programá fuera del rango 01:00–04:00.
3. Fijala explícitamente donde la herramienta lo permita: `CRON_TZ=UTC` (Vixie/cronie), `OnCalendar=*-*-* 03:15:00 UTC` (systemd).
4. Hacé que el trabajo sea **idempotente**, para que una ejecución duplicada sea inofensiva. Esta es la única defensa que funciona siempre.

```console
$ timedatectl
               Local time: Wed 2026-08-27 14:52:31 -03
           Universal time: Wed 2026-08-27 17:52:31 UTC
                 RTC time: Wed 2026-08-27 17:52:31
                Time zone: America/Argentina/Buenos_Aires (-03, -0300)
System clock synchronized: yes
              NTP service: active
          RTC in local TZ: no
```

`RTC in local TZ: no` importa: un RTC en hora local vuelve no determinista la planificación en el arranque a través de las transiciones de horario de verano.

---

## 10. Verificación y diagnóstico de fallos

### 10.1 Escalera de verificación por capas

Ejecutá esto en orden; cada peldaño asume que el anterior pasó.

**Peldaño 1 — ¿el demonio siquiera está corriendo?**

```console
$ systemctl is-active cron.service atd.service          # Debian/Ubuntu
active
active

$ systemctl is-active crond.service atd.service         # RHEL family
active
active

$ pgrep -a cron
612 /usr/sbin/cron -f -P
```

**Peldaño 2 — ¿la programación está instalada donde creés?**

```console
$ sudo crontab -l -u deploy
$ cat /etc/crontab
$ ls -la /etc/cron.d/
$ sudo run-parts --test /etc/cron.daily

$ systemctl list-timers --all
NEXT                        LEFT       LAST                        PASSED    UNIT                         ACTIVATES
Wed 2026-08-27 15:00:00 -03 7min left  Wed 2026-08-27 14:00:00 -03 52min ago anacron.timer                anacron.service
Wed 2026-08-27 18:07:12 -03 3h 14min   Wed 2026-08-27 06:07:12 -03 8h ago    apt-daily.timer              apt-daily.service
Thu 2026-08-28 00:00:00 -03 9h left    Wed 2026-08-27 00:00:14 -03 14h ago   logrotate.timer              logrotate.service
Thu 2026-08-28 03:15:00 -03 12h left   Wed 2026-08-27 03:41:22 -03 11h ago   registry-prune.timer         registry-prune.service
-                           -          -                           -         systemd-tmpfiles-clean.timer systemd-tmpfiles-clean.service

5 timers listed.
```

Un `NEXT` con `-` significa que el timer está cargado pero nunca va a dispararse — habitualmente un `OnCalendar` mal escrito o un timer que nunca se arrancó con `start`.

**Peldaño 3 — inventario completo de crontabs de la máquina**

```console
$ sudo sh -c '
  echo "### user crontabs"
  for f in /var/spool/cron/crontabs/* /var/spool/cron/*; do
    [ -f "$f" ] || continue
    echo "--- $f"; grep -Ev "^\s*(#|$)" "$f"
  done
  echo "### /etc/crontab";      grep -Ev "^\s*(#|$)" /etc/crontab
  echo "### /etc/cron.d";       grep -rEv "^\s*(#|$)" /etc/cron.d/ 2>/dev/null
  echo "### run-parts dirs";    ls /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly
  echo "### at queue";          atq
'
```

**Peldaño 4 — ¿la programación significa lo que creés?**

```console
$ systemd-analyze calendar --iterations=3 '*-*-* 03:15:00'
  Original form: *-*-* 03:15:00
Normalized form: *-*-* 03:15:00
    Next elapse: Thu 2026-08-28 03:15:00 -03
       (in UTC): Thu 2026-08-28 06:15:00 UTC
       From now: 12h left
       Iter. #2: Fri 2026-08-29 03:15:00 -03
       Iter. #3: Sat 2026-08-30 03:15:00 -03
```

Para expresiones cron, `systemd-analyze calendar` también acepta la forma clásica una vez traducida, y `crontab -l | crontab -` revalida la sintaxis de forma no destructiva.

**Peldaño 5 — ¿realmente corrió?**

```console
# Debian / Ubuntu
$ sudo journalctl -u cron.service --since "24 hours ago" --no-pager | tail -20
Aug 27 03:15:01 web-07 CRON[19204]: (deploy) CMD (/usr/local/bin/registry-prune --older-than 30d)
Aug 27 03:15:01 web-07 CRON[19203]: (CRON) info (No MTA installed, discarding output)
Aug 27 03:17:01 web-07 CRON[19288]: (root) CMD (cd / && run-parts --report /etc/cron.hourly)

# RHEL family
$ sudo tail -20 /var/log/cron
Aug 27 03:15:01 web-07 CROND[19204]: (deploy) CMD (/usr/local/bin/registry-prune --older-than 30d)
Aug 27 03:15:01 web-07 CROND[19203]: (deploy) CMDOUT (pruned 1284 blobs)
Aug 27 03:15:02 web-07 CROND[19203]: (deploy) CMDEND (/usr/local/bin/registry-prune --older-than 30d)

# systemd timers — this is where the difference shows
$ journalctl -u registry-prune.service --since today --no-pager
Aug 27 03:41:22 web-07 systemd[1]: Starting registry-prune.service - Prune container registry blobs...
Aug 27 03:41:23 web-07 registry-prune[19311]: scanning 41,882 manifests
Aug 27 03:44:07 web-07 registry-prune[19311]: deleted 1,284 blobs, reclaimed 18.4 GiB
Aug 27 03:44:07 web-07 systemd[1]: registry-prune.service: Deactivated successfully.
Aug 27 03:44:07 web-07 systemd[1]: Finished registry-prune.service - Prune container registry blobs.
Aug 27 03:44:07 web-07 systemd[1]: registry-prune.service: Consumed 2min 41.203s CPU time, 812.4M memory peak.
```

Esa última línea — contabilidad de CPU y memoria por invocación — sale gratis con un timer y es inalcanzable con cron.

```console
$ systemctl show registry-prune.service -p Result -p ExecMainStatus -p ExecMainStartTimestamp -p ExecMainExitTimestamp
Result=success
ExecMainStatus=0
ExecMainStartTimestamp=Wed 2026-08-27 03:41:22 -03
ExecMainExitTimestamp=Wed 2026-08-27 03:44:07 -03
```

**Peldaño 6 — reproducí el entorno real del trabajo.** Acá se resuelve el 80 % de los incidentes de "en mi shell funciona".

```cron
# Temporary diagnostic line
* * * * * /usr/bin/env > /tmp/cron-env.txt 2>&1; /usr/bin/id >> /tmp/cron-env.txt
```

```console
$ cat /tmp/cron-env.txt
LANG=en_US.UTF-8
HOME=/home/deploy
LOGNAME=deploy
PATH=/usr/bin:/bin
SHELL=/bin/sh
PWD=/home/deploy
uid=1001(deploy) gid=1001(deploy) groups=1001(deploy)
```

`PATH=/usr/bin:/bin` — sin `/usr/local/bin`, sin `/sbin`. Esa sola línea explica la mayoría de los fallos de `command not found`.

Después reproducilo exactamente:

```console
$ env -i \
>   HOME=/home/deploy LOGNAME=deploy USER=deploy \
>   PATH=/usr/bin:/bin SHELL=/bin/sh \
>   /bin/sh -c '/usr/local/bin/registry-prune --older-than 30d'
/bin/sh: 1: /usr/local/bin/registry-prune: not found
```

Reproducido. Para una unidad de systemd el equivalente es un arranque manual de un solo disparo, que usa el entorno y el sandboxing reales de la unidad:

```console
$ sudo systemctl start registry-prune.service
$ systemctl status registry-prune.service --no-pager
× registry-prune.service - Prune container registry blobs older than 30 days
     Loaded: loaded (/etc/systemd/system/registry-prune.service; enabled)
     Active: failed (Result: exit-code) since Wed 2026-08-27 14:58:03 -03; 4s ago
   Duration: 118ms
    Process: 21044 ExecStart=/usr/local/bin/registry-prune --older-than 30d --confirm (code=exited, status=13)
   Main PID: 21044 (code=exited, status=13)
        CPU: 96ms

Aug 27 14:58:03 web-07 registry-prune[21044]: error: cannot write /srv/registry/.lock: Read-only file system
Aug 27 14:58:03 web-07 systemd[1]: registry-prune.service: Main process exited, code=exited, status=13
```

`Read-only file system` bajo `ProtectSystem=strict` → la solución es una entrada `ReadWritePaths=` faltante, no un cambio de permisos. Los fallos inducidos por el sandbox son diagnosticables porque nombran el mecanismo.

### 10.2 Árbol de decisión ante fallos

| Síntoma | Causa probable | Confirmar con | Solución |
|---|---|---|---|
| Nada en el log, nunca | Demonio no corriendo / no habilitado | `systemctl is-enabled cron` | `systemctl enable --now cron` |
| Archivo de `/etc/cron.d` ignorado, sin error | El nombre tiene un `.` u otro carácter ilegal | `run-parts --test /etc/cron.d` | Renombrar usando solo `[A-Za-z0-9_-]` |
| Archivo de `/etc/cron.d` ignorado | Permisos/dueño erróneos, o escribible por el grupo | `ls -l /etc/cron.d/` | `chown root:root`, `chmod 0644` |
| `command not found` en el correo | `PATH` mínimo | Volcar `env` desde una línea de cron | Definir `PATH=` en el crontab, o usar rutas absolutas |
| Funciona como root, falla para el usuario | Falta el sexto campo en `/etc/cron.d`, o se usó el tipo de crontab equivocado | `head` del archivo | `/etc/cron.d` y `/etc/crontab` necesitan campo de usuario; los crontabs de usuario no deben tenerlo |
| Comando truncado en un `%` | Porcentaje sin escapar | `crontab -l \| cat -A` | Escapar como `\%` o mover la lógica a un script |
| Corre en los días equivocados | Regla OR de DOM/DOW | `systemd-analyze calendar` sobre la expresión traducida | Poner un campo en `*` y evaluar el otro en el comando |
| Dos instancias solapadas | Sin bloqueo | `pgrep -af <job>` | `flock -n` o un timer de systemd |
| Corre una hora antes/después dos veces al año | Horario de verano | `timedatectl` | Host en UTC, `CRON_TZ=UTC`, o `OnCalendar=... UTC` |
| Corrió a las 03:15 ayer, hoy no | La máquina estaba apagada | `journalctl --list-boots` | `Persistent=true`, o anacron |
| Dispara en ráfaga al arrancar | `Persistent=true` en muchos timers | `systemctl list-timers` | Agregar `RandomizedDelaySec=` |
| El trabajo se cuelga para siempre y bloquea el siguiente | Sin timeout | `systemctl status` muestra una `Duration` larga | `timeout` en cron, `TimeoutStartSec=` en una unidad |
| `You are not allowed to use this program` | `cron.allow` / `cron.deny` | `ls -l /etc/cron.allow /etc/cron.deny` | Agregar el usuario a `cron.allow` |
| `crontab -e` abre el editor equivocado | `EDITOR`/`VISUAL` sin definir | `echo $VISUAL $EDITOR` | `export EDITOR=vim`, o `update-alternatives --config editor` |
| El trabajo `at` nunca dispara | `atd` no está corriendo | `systemctl is-active atd` | `systemctl enable --now atd` |
| El trabajo `batch` queda en la cola | Carga media por encima del umbral | `uptime`, `ps -o args= -C atd` | Elevarlo con `atd -l` |
| Timer cargado, `NEXT` muestra `-` | `OnCalendar` inválido o timer no arrancado | `systemd-analyze verify`, `systemctl status <t>.timer` | Corregir la expresión, `systemctl start` |
| La unidad falla solo bajo el planificador | Sandboxing (`ProtectSystem`, `PrivateTmp`) | El error nombra el mecanismo | Agregar `ReadWritePaths=` / relajar la directiva puntual |
| `(CRON) info (No MTA installed, discarding output)` | Hubo salida, no hay agente de correo | `journalctl -u cron` | Instalar un MTA, o poner `MAILTO=""` y registrar con `logger` |
| Corrió, pero el resultado es incorrecto | Suposición equivocada sobre `HOME`/`PWD` | Volcar `pwd` desde una línea de cron | Hacer `cd` explícito, o usar `WorkingDirectory=` |

### 10.3 Auditar toda la superficie de trabajo programado de una máquina

Los trabajos programados sin revisar son tanto un mecanismo de persistencia como un riesgo operativo. Vale la pena correr este inventario como control de cumplimiento:

```bash
#!/bin/bash
# /usr/local/sbin/audit-scheduled-work
set -uo pipefail
echo "=== Scheduled work inventory: $(hostname -f) $(date -Is) ==="

echo -e "\n--- Daemons"
systemctl is-active cron crond atd 2>/dev/null | paste -d' ' <(echo -e "cron\ncrond\natd") -

echo -e "\n--- Per-user crontabs"
for d in /var/spool/cron/crontabs /var/spool/cron; do
  [ -d "$d" ] || continue
  for f in "$d"/*; do
    [ -f "$f" ] || continue
    echo "[$(basename "$f")] owner=$(stat -c '%U:%G %a' "$f")"
    grep -Ev '^\s*(#|$)' "$f" | sed 's/^/    /'
  done
done

echo -e "\n--- /etc/crontab"
grep -Ev '^\s*(#|$)' /etc/crontab 2>/dev/null | sed 's/^/    /'

echo -e "\n--- /etc/cron.d (flagging names run-parts will reject)"
for f in /etc/cron.d/*; do
  [ -f "$f" ] || continue
  b=$(basename "$f")
  case "$b" in
    *[!A-Za-z0-9_-]*) echo "    !! IGNORED BY CRON (illegal filename): $b" ;;
    *) echo "[$b] $(stat -c '%U:%G %a' "$f")"
       grep -Ev '^\s*(#|$)' "$f" | sed 's/^/    /' ;;
  esac
done

echo -e "\n--- run-parts directories"
for d in hourly daily weekly monthly; do
  echo "[cron.$d]"; run-parts --test "/etc/cron.$d" 2>/dev/null | sed 's/^/    /'
done

echo -e "\n--- anacron"
grep -Ev '^\s*(#|$)' /etc/anacrontab 2>/dev/null | sed 's/^/    /'
ls -l /var/spool/anacron/ 2>/dev/null | sed 's/^/    /'

echo -e "\n--- at queue (all users)"
atq 2>/dev/null | sed 's/^/    /'

echo -e "\n--- systemd timers"
systemctl list-timers --all --no-pager | sed 's/^/    /'

echo -e "\n--- Access control"
for f in /etc/cron.allow /etc/cron.deny /etc/at.allow /etc/at.deny; do
  if [ -e "$f" ]; then echo "[$f] $(stat -c '%U:%G %a' "$f")"; sed 's/^/    /' "$f"
  else echo "[$f] absent"; fi
done
```

```console
$ sudo /usr/local/sbin/audit-scheduled-work | head -40
=== Scheduled work inventory: web-07.example.com 2026-08-27T15:01:44-03:00 ===

--- Daemons
cron active
crond inactive
atd active

--- Per-user crontabs
[deploy] owner=deploy:crontab 600
    SHELL=/bin/bash
    PATH=/usr/local/bin:/usr/bin:/bin
    MAILTO=sre-oncall@example.com
    */10 * * * * /usr/bin/flock -n /run/lock/artifact-sync.lock /usr/local/bin/artifact-sync
    17 4 * * * /usr/local/bin/prune-registry --older-than 30d

--- /etc/crontab
    SHELL=/bin/sh
    PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
    17 * * * * root cd / && run-parts --report /etc/cron.hourly

--- /etc/cron.d (flagging names run-parts will reject)
    !! IGNORED BY CRON (illegal filename): backup.sh
[node-exporter-textfile] root:root 644
    SHELL=/bin/bash
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    MAILTO=""
    */5 * * * * node_exp /usr/bin/flock -n /run/lock/textfile.lock /usr/local/bin/collect-textfile-metrics.sh
```

Esa línea `!! IGNORED BY CRON` es una clase real de incidente: alguien dejó `backup.sh` en `/etc/cron.d`, `ls` lo muestra, y no se ejecutó ni una sola vez.

---

## 11. Resumen orientado al examen

### 11.1 Ubicaciones de archivos por familia de distribución

| Propósito | Debian/Ubuntu | RHEL/Fedora/SUSE |
|---|---|---|
| Spool de crontabs de usuario | `/var/spool/cron/crontabs/<user>` | `/var/spool/cron/<user>` |
| Crontab de sistema | `/etc/crontab` | `/etc/crontab` |
| Directorio de drop-in | `/etc/cron.d/` | `/etc/cron.d/` |
| Directorios periódicos | `/etc/cron.{hourly,daily,weekly,monthly}` | igual |
| Configuración de anacron | `/etc/anacrontab` | `/etc/anacrontab` |
| Marcas de anacron | `/var/spool/anacron/` | `/var/spool/anacron/` |
| Spool de `at` | `/var/spool/cron/atjobs/` | `/var/spool/at/` |
| Log de cron | `/var/log/syslog`, `journalctl -u cron` | `/var/log/cron`, `journalctl -u crond` |
| Nombre del servicio | `cron.service` | `crond.service` |
| Valores por defecto del demonio | `/etc/default/cron` | `/etc/sysconfig/crond` |
| Paquete | `cron`, `anacron`, `at` | `cronie`, `cronie-anacron`, `at` |

### 11.2 Referencia de comandos

| Comando | Propósito |
|---|---|
| `crontab -e` / `-l` / `-r` / `-i -r` | Editar / listar / eliminar / eliminar con confirmación |
| `crontab -u <user> ...` | Operar sobre el crontab de otro usuario (root) |
| `crontab <file>` / `crontab -` | Reemplazar el crontab desde archivo / stdin (la forma automatizable) |
| `at <time>` | Programar un trabajo de un solo disparo |
| `at -f <file> <time>` | Programar desde un archivo de script |
| `at -c <jobid>` | Imprimir el script completo del trabajo, entorno incluido |
| `at -l` / `atq` | Listar trabajos pendientes |
| `at -d <id>` / `atrm <id>` | Borrar un trabajo pendiente |
| `at -m` / `at -M` | Forzar correo / suprimir correo |
| `at -q <letter>` | Seleccionar cola (afecta el nivel de nice) |
| `batch` | Ejecutar cuando la carga media baje del umbral |
| `anacron -T` | Validar `/etc/anacrontab` |
| `anacron -n -d <job>` | Ejecutar ahora, en primer plano, ignorando demoras |
| `anacron -u` | Actualizar marcas temporales sin ejecutar |
| `anacron -f` | Forzar todos los trabajos sin importar las marcas |
| `anacron -s` | Serializar trabajos |
| `run-parts --test <dir>` | Mostrar qué scripts *se ejecutarían* |
| `run-parts --report <dir>` | Ejecutar, anteponiendo a la salida el nombre del script |
| `systemctl list-timers [--all]` | Mostrar timers, último y próximo disparo |
| `systemctl enable --now <x>.timer` | Habilitar y arrancar un timer |
| `systemctl cat <unit>` | Mostrar el contenido efectivo de la unidad, drop-ins incluidos |
| `systemd-analyze calendar '<expr>'` | Validar y previsualizar una expresión `OnCalendar` |
| `systemd-analyze verify <unit>` | Validación estática de la unidad |
| `systemd-run --on-active=<t> <cmd>` | Trabajo transitorio de un solo disparo (el análogo de `at`) |
| `systemd-run --on-calendar='<expr>' <cmd>` | Timer transitorio recurrente |
| `journalctl -u <unit>` | Logs estructurados de una unidad programada |

### 11.3 Los nueve hechos que más probablemente se evalúen

1. `/etc/crontab` y `/etc/cron.d/*` tienen **campo de usuario**; los crontabs de usuario **no**.
2. El orden de campos es **minuto hora día-del-mes mes día-de-la-semana**; en DOW, `0` y `7` son ambos domingo.
3. Cuando **ambos**, DOM y DOW, están restringidos, el trabajo corre cuando coincide **cualquiera** de los dos (OR, no AND).
4. Si existe `cron.allow`, `cron.deny` es **ignorado por completo**.
5. Si no existe ninguno de los dos archivos, el comportamiento por defecto **depende del sitio** — habitualmente "todos los usuarios" en Debian, "solo root" en RHEL.
6. Un `%` en un comando de crontab se convierte en un **salto de línea**; el texto posterior al primer `%` pasa a ser **stdin**. Se escapa con `\%`.
7. cron envía por correo la **salida**, no los fallos; el **código de salida se descarta**.
8. anacron mide **días transcurridos**, tiene un período mínimo de **un día**, ejecuta todo como **root** y escribe sus marcas temporales en `/var/spool/anacron/`.
9. `run-parts` exige el **bit de ejecución** y un nombre de archivo compuesto solo por `[A-Za-z0-9_-]` — una extensión `.sh` significa que el script se saltea en silencio.

---

## 12. Referencias

**Oficiales de LPI**

- LPIC-1 Exam 101-500 Objectives — https://www.lpi.org/our-certifications/exam-101-objectives/
- LPIC-1 Exam 102-500 Objectives (el tema 107.2 está acá) — https://www.lpi.org/our-certifications/exam-102-objectives/
- LPIC-1 Certification Overview — https://www.lpi.org/our-certifications/lpic-1-overview/
- LPI Learning Materials, LPIC-1 102 — https://learning.lpi.org/en/learning-materials/102-500/

**cron, anacron, at — proyectos upstream y páginas de manual**

- Proyecto `cronie` (cron de RHEL/Fedora/Arch/openSUSE) — https://github.com/cronie-crond/cronie
- `crontab(5)` — https://man7.org/linux/man-pages/man5/crontab.5.html
- `crontab(1)` — https://man7.org/linux/man-pages/man1/crontab.1.html
- `cron(8)` — https://man7.org/linux/man-pages/man8/cron.8.html
- `anacron(8)` — https://man7.org/linux/man-pages/man8/anacron.8.html
- `anacrontab(5)` — https://man7.org/linux/man-pages/man5/anacrontab.5.html
- `at(1)` (incluye `batch`, `atq`, `atrm`) — https://man7.org/linux/man-pages/man1/at.1.html
- `atd(8)` — https://man7.org/linux/man-pages/man8/atd.8.html
- Upstream de `at` (`at` / `atd`, mantenido por Debian) — https://salsa.debian.org/debian/at
- `run-parts(8)` — https://manpages.debian.org/stable/debianutils/run-parts.8.en.html
- `flock(1)` (util-linux) — https://man7.org/linux/man-pages/man1/flock.1.html
- Proyecto util-linux — https://github.com/util-linux/util-linux

**systemd**

- Proyecto systemd — https://systemd.io/
- `systemd.timer(5)` — https://www.freedesktop.org/software/systemd/man/latest/systemd.timer.html
- `systemd.time(7)` (gramática de eventos de calendario) — https://www.freedesktop.org/software/systemd/man/latest/systemd.time.html
- `systemd.service(5)` — https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html
- `systemd.exec(5)` (directivas de sandboxing) — https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html
- `systemd.resource-control(5)` (límites de cgroups) — https://www.freedesktop.org/software/systemd/man/latest/systemd.resource-control.html
- `systemd-run(1)` — https://www.freedesktop.org/software/systemd/man/latest/systemd-run.html
- `systemd-analyze(1)` — https://www.freedesktop.org/software/systemd/man/latest/systemd-analyze.html
- `timedatectl(1)` — https://www.freedesktop.org/software/systemd/man/latest/timedatectl.html
- `journalctl(1)` — https://www.freedesktop.org/software/systemd/man/latest/journalctl.html

**Documentación de distribuciones**

- Debian Administrator's Handbook, Scheduling Tasks — https://debian-handbook.info/browse/stable/sect.task-scheduling-cron-atd.html
- Red Hat Enterprise Linux 9, Automating system tasks — https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/automating_system_administration_by_using_rhel_system_roles/index
- Ubuntu Server Documentation — https://documentation.ubuntu.com/server/
- openSUSE, timers de `cron` y `systemd` — https://doc.opensuse.org/documentation/leap/reference/html/book-reference/cha-tuning-cron.html
- Arch Wiki, systemd/Timers — https://wiki.archlinux.org/title/Systemd/Timers
- Arch Wiki, cron — https://wiki.archlinux.org/title/Cron

**Infraestructura como código y orquestación**

- Módulo `ansible.builtin.cron` de Ansible — https://docs.ansible.com/ansible/latest/collections/ansible/builtin/cron_module.html
- Módulo `ansible.builtin.systemd_service` de Ansible — https://docs.ansible.com/ansible/latest/collections/ansible/builtin/systemd_service_module.html
- Documentación de cloud-init — https://cloudinit.readthedocs.io/en/latest/
- Kubernetes CronJob — https://kubernetes.io/docs/concepts/workloads/controllers/cron-job/
- Referencia de la API CronJob de Kubernetes (`batch/v1`) — https://kubernetes.io/docs/reference/kubernetes-api/workload-resources/cron-job-v1/
- Colector textfile de node_exporter de Prometheus — https://github.com/prometheus/node_exporter#textfile-collector
- Google SRE Workbook, *Distributed Periodic Scheduling with Cron* — https://sre.google/sre-book/distributed-periodic-scheduling/

**Estándares**

- Utilidad `crontab` de POSIX.1-2024 — https://pubs.opengroup.org/onlinepubs/9799919799/utilities/crontab.html
- Utilidad `at` de POSIX.1-2024 — https://pubs.opengroup.org/onlinepubs/9799919799/utilities/at.html
- IANA Time Zone Database — https://www.iana.org/time-zones