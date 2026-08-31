# 108.2 Registro del sistema (System Logging)

**LPIC-1 · Examen 102-500 · Versión 5.0**
*Perfil SRE avanzado / Arquitecto de Plataforma*

> Nota de alcance: este objetivo cubre el modelo de datos clásico de syslog, la configuración de `rsyslog`, el journal de systemd (`systemd-journald` / `journalctl`), los inyectores de mensajes `logger` y `systemd-cat`, y `logrotate`. El material que sigue los trata como un único subsistema de producción y no como cuatro comandos inconexos, porque en una flota real son un único subsistema.

---

## 1. Motivación: el problema arquitectónico que el logging realmente resuelve

Un host Linux produce eventos de diagnóstico desde cuatro productores estructuralmente distintos, y ninguno comparte transporte por casualidad:

| Productor | Sumidero nativo | Mecanismo |
|---|---|---|
| Kernel (`printk`) | Ring buffer | `/dev/kmsg`, `/proc/kmsg`, leídos por `dmesg`, `systemd-journald` o `imklog` |
| Servicios lanzados por systemd | Journal | `stdout`/`stderr` son pipes propiedad de `journald` (`StandardOutput=journal`) |
| Procesos legacy/demonizados | `/dev/log` | Socket `AF_UNIX` `SOCK_DGRAM`, payload RFC 3164 |
| Aplicaciones que escriben archivos directamente | Archivo propio | `nginx`, `mysqld`, `httpd` — el socket de nadie, de ahí `logrotate` |

El problema arquitectónico no es "dónde leo los logs". Es:

1. **Pérdida bajo presión.** Un socket de datagramas descarta en silencio. Un reenviador UDP descarta en silencio. Un disco lleno hace que `journald` deje de almacenar, y una acción `rsyslog` ingenua bloquea todo su ruleset. Cada una de estas es una falla *distinta* con una mitigación *distinta*, y la configuración por defecto de toda distribución elige "descartar en silencio" antes que "bloquear al productor" — el default correcto para disponibilidad, el default equivocado para análisis forense.
2. **El almacenamiento local no es almacenamiento duradero.** El host que registra el incidente es con frecuencia el host que está por desaparecer (instancia spot, OOM, kernel panic, `terraform destroy`). Cualquier log que solo existió en el nodo que falla no vale prácticamente nada a la hora del post-mortem. Por eso "configurar el demonio de syslog" en un objetivo de examen se convierte en "configurar una cadena de relay con entrega garantizada y colas asistidas por disco" en producción.
3. **El crecimiento sin límite es una clase de caída en sí misma.** Que `/var` se llene tumba la máquina mucho más seguido que cualquier bug de aplicación. `logrotate` y el `SystemMaxUse=` de `journald` no son tareas de mantenimiento; son las barandas que evitan que el subsistema de logging se convierta en el incidente.
4. **Pérdida de estructura.** RFC 3164 colapsa todo en una cadena de texto libre. El journal conserva campos clave/valor tipados (`_PID`, `_SYSTEMD_UNIT`, `_UID`, `MESSAGE_ID`) pero es local al host y binario. Todo lo que cruza la red en formato syslog clásico pierde la estructura que hacía útil la consulta local. Elegir dónde pagás ese impuesto es la decisión de diseño central de este tema.

Un pipeline de logging de producción es por lo tanto siempre de tres capas: **recolectar** (entradas de journald / rsyslog) → **bufferear + relayear** (colas, RELP/TLS) → **retener** (rotación local, object store o índice a nivel central). LPIC-1 evalúa la capa 1 y la mitad local de la capa 3; un Arquitecto de Plataforma es dueño de las tres.

---

## 2. El modelo de datos de syslog

### 2.1 Facility y severity

Todo mensaje syslog clásico lleva un valor **PRI** calculado como:

```
PRI = (facility × 8) + severity
```

**Facilities** (RFC 5424 §6.2.1):

| Código | Palabra clave | Productor típico |
|---|---|---|
| 0 | `kern` | Mensajes del kernel (no pueden generarse desde espacio de usuario en la mayoría de los kernels) |
| 1 | `user` | Espacio de usuario genérico — **default de `logger`** |
| 2 | `mail` | MTA (postfix, exim) |
| 3 | `daemon` | Demonios del sistema sin facility dedicada |
| 4 | `auth` | Autenticación/autorización (`login`, `su`) |
| 5 | `syslog` | El propio demonio de syslog |
| 6 | `lpr` | Subsistema de impresión de línea |
| 7 | `news` | NNTP |
| 8 | `uucp` | UUCP |
| 9 | `cron` | `cron`/`at` |
| 10 | `authpriv` | Mensajes de autenticación con datos privados — **`sshd`, `sudo`, PAM** |
| 11 | `ftp` | Demonio FTP |
| 12 | `ntp` | Subsistema NTP |
| 13 | — | Auditoría de logs |
| 14 | — | Alerta de logs |
| 15 | `clock` | Demonio de reloj |
| 16–23 | `local0`–`local7` | Definidas por el sitio — **el único lugar correcto para tus propias aplicaciones** |

**Severities** (RFC 5424 §6.2.1), número más bajo = más severo:

| Código | Palabra clave | Significado | Lectura SRE |
|---|---|---|---|
| 0 | `emerg` (`panic`) | Sistema inutilizable | Paginar de inmediato |
| 1 | `alert` | Acción requerida de inmediato | Paginar de inmediato |
| 2 | `crit` | Condición crítica | Paginar |
| 3 | `err` (`error`) | Condición de error | Ticket / alerta por tasa |
| 4 | `warning` (`warn`) | Advertencia | Solo alerta basada en tasa |
| 5 | `notice` | Normal pero significativo | Retener, no alertar |
| 6 | `info` | Informativo | Retener, muestrear |
| 7 | `debug` | Nivel de depuración | Apagado en producción; habilitar por unidad |

> **Trampa de examen:** las palabras clave obsoletas `error`, `warn` y `panic` son aceptadas por rsyslog, pero no deberían escribirse en configuración nueva. `authpriv` — no `auth` — es donde caen `sshd` y `sudo` en prácticamente toda distribución moderna.

Ejemplo resuelto: un mensaje `authpriv` (10) con severidad `err` (3) lleva `PRI = 10×8 + 3 = 83`, transmitido como `<83>`.

### 2.2 Formatos de cable

| Aspecto | RFC 3164 (BSD) | RFC 5424 |
|---|---|---|
| Estado | Informativo, "tal como se observó" | Standards Track |
| Timestamp | `Mmm dd hh:mm:ss` — **sin año, sin zona horaria, sin sub-segundo** | RFC 3339 con zona horaria y segundos fraccionarios |
| Hostname | Pelado, puede ser una IP | FQDN / IP, se permite `NILVALUE` |
| Tamaño de mensaje | 1024 bytes en total | 2048 mínimo, los receptores pueden aceptar más |
| Datos estructurados | Ninguno | Elemento `STRUCTURED-DATA` (`[origin ip="…"][meta …]`) |
| Nombre de app / PID | Solo por convención (`tag[pid]:`) | Campos dedicados `APP-NAME`, `PROCID`, `MSGID` |
| Transportes | UDP/514 | UDP (RFC 5426), TLS (RFC 5425), framing TCP (RFC 6587) |

La ausencia de año y zona horaria en RFC 3164 es un peligro operativo genuino: un relay en una zona horaria distinta a la del origen produce logs que no pueden correlacionarse sin conocimiento fuera de banda. Preferí siempre RFC 5424 (`RSYSLOG_SyslogProtocol23Format`) o una plantilla RFC 3339 propia cuando controlás ambos extremos.

---

## 3. `systemd-journald`: internals

### 3.1 Qué es en realidad

`journald` es un almacén de logs estructurado, indexado, binario y de solo anexado. Ingesta desde:

- `/run/systemd/journal/dev-log` — el socket de compatibilidad `/dev/log`
- `/run/systemd/journal/socket` — el protocolo nativo (`sd_journal_send()`), que transporta campos clave/valor arbitrarios
- `/run/systemd/journal/stdout` — `stdout`/`stderr` de cada unidad
- `/dev/kmsg` — el ring buffer del kernel
- el socket netlink de auditoría, cuando `Audit=yes`

Cada registro es un conjunto de campos. Los campos cuyo nombre empieza con `_` son **confiables**: los agrega el propio `journald` a partir de las credenciales del emisor vía `SO_PEERCRED`, y no pueden ser falsificados por el proceso emisor. Esta es la propiedad más importante del journal y la razón por la que no es meramente "otro archivo de log".

| Campo | ¿Confiable? | Significado |
|---|---|---|
| `MESSAGE` | No | Texto libre |
| `PRIORITY` | No | Severidad 0–7 |
| `SYSLOG_FACILITY` | No | Número de facility |
| `SYSLOG_IDENTIFIER` | No | Tag |
| `MESSAGE_ID` | No | UUID de 128 bits que identifica un *tipo de mensaje* |
| `_PID`, `_UID`, `_GID` | **Sí** | Credenciales del emisor verificadas por el kernel |
| `_COMM`, `_EXE`, `_CMDLINE` | **Sí** | Identidad del proceso |
| `_SYSTEMD_UNIT`, `_SYSTEMD_SLICE`, `_SYSTEMD_CGROUP` | **Sí** | Atribución de unidad derivada del cgroup |
| `_BOOT_ID`, `_MACHINE_ID`, `_HOSTNAME` | **Sí** | Identidad de host/arranque |
| `_TRANSPORT` | **Sí** | `journal`, `stdout`, `syslog`, `kernel`, `audit`, `driver` |
| `__REALTIME_TIMESTAMP`, `__MONOTONIC_TIMESTAMP`, `__CURSOR` | **Sí** | Direccionamiento/ordenamiento |

### 3.2 Layout de almacenamiento y la decisión de persistencia

```
/run/log/journal/<machine-id>/system.journal          ← volatile (tmpfs, lost on reboot)
/var/log/journal/<machine-id>/system.journal          ← persistent, active
/var/log/journal/<machine-id>/system@<seq>-<ts>.journal  ← rotated, sealed
/var/log/journal/<machine-id>/user-1000.journal       ← per-UID split
```

Semántica de `Storage=`:

| Valor | Comportamiento |
|---|---|
| `volatile` | Solo `/run/log/journal`. Se pierde al reiniciar. |
| `persistent` | `/var/log/journal` se crea automáticamente si falta; cae a `/run` hasta que `/var` esté montado. |
| `auto` | **Default.** Persistente *solo si `/var/log/journal/` ya existe como directorio.* |
| `none` | No se almacena nada; el reenvío sigue funcionando. Útil cuando rsyslog es dueño de la retención. |

> **La sorpresa más común del mundo real en imágenes derivadas de Debian/Ubuntu y en imágenes mínimas:** `Storage=auto` más un directorio `/var/log/journal` ausente hace que `journalctl -b -1` devuelva *"Specifying boot ID or boot offset has no effect, no persistent journal was found"*. El arreglo es `mkdir -p /var/log/journal && systemd-tmpfiles --create --prefix /var/log/journal && systemctl restart systemd-journald`, o `journalctl --flush`.

### 3.3 Contabilidad de disco

Los límites de tamaño aplican **por namespace de journal, por ubicación de almacenamiento**, y la rotación es por archivo, no por registro:

| Directiva | Default | Notas |
|---|---|---|
| `SystemMaxUse=` | 10% del filesystem, con tope de 4 GiB | Total sobre todos los archivos persistentes |
| `SystemKeepFree=` | 15% del filesystem | Gana el límite que se alcance primero |
| `SystemMaxFileSize=` | 1/8 de `SystemMaxUse=` | Disparador de rotación de archivo individual |
| `SystemMaxFiles=` | 100 | Techo de cantidad |
| `RuntimeMaxUse=` / `RuntimeKeepFree=` / … | Mismas reglas para `/run` | `/run` es RAM — sé conservador |
| `MaxRetentionSec=` | 0 (apagado) | Expiración por tiempo |
| `MaxFileSec=` | 1 mes | Fuerza la rotación incluso en sistemas ociosos |

### 3.4 Rate limiting — el campo que se come tu incidente en silencio

```
RateLimitIntervalSec=30s
RateLimitBurst=10000
```

Más allá de `RateLimitBurst` mensajes del *mismo servicio* dentro del intervalo, `journald` descarta y emite un marcador `"Suppressed N messages from …"`. Durante un incidente, el servicio más ruidoso es precisamente el que está siendo estrangulado. Sobreescribí por unidad en lugar de globalmente:

```ini
# /etc/systemd/system/payments-api.service.d/10-logging.conf
[Service]
LogRateLimitIntervalSec=0
LogRateLimitBurst=0
LogLevelMax=info
LogNamespace=payments
```

`LogRateLimitIntervalSec=0` desactiva el límite solo para esa unidad. `LogNamespace=` levanta un `systemd-journald@payments.service` dedicado con su propio almacenamiento y su propia cuota — la primitiva de aislamiento correcta para un tenant ruidoso en un host compartido.

---

## 4. `rsyslog`: arquitectura

`rsyslog` es un enrutador modular de mensajes, no un escritor de archivos de log. El pipeline es:

```
input module (im*) ─► parser ─► ruleset ─► [filter] ─► action queue ─► output module (om*)
                                    │
                                    └─► template (formats the outbound message)
```

### 4.1 Módulos que importan

| Módulo | Rol |
|---|---|
| `imuxsock` | Lee `/dev/log` (el socket AF_UNIX) |
| `imjournal` | Lee el journal de systemd directamente, preservando los campos estructurados |
| `imklog` | Lee el ring buffer del kernel |
| `imfile` | Sigue archivos planos (`nginx`, logs de aplicación) hacia el pipeline |
| `imtcp` / `imudp` / `imrelp` | Receptores de red |
| `impstats` | Emite los contadores propios de rsyslog — obligatorio en producción |
| `omfwd` | Reenvía por UDP/TCP (opcionalmente TLS) |
| `omrelp` | Reenvía por RELP (ACK a nivel de aplicación) |
| `omfile` | Escribe archivos |
| `omprog` / `omhttp` / `omelasticsearch` | Sumideros externos |

> **Trampa de duplicación:** habilitar **ambos**, `imjournal` **e** `imuxsock`, mientras `journald` tiene `ForwardToSyslog=yes`, produce cada mensaje dos veces. Elegí una única ruta de ingesta. Las dos configuraciones coherentes son:
> - **journald primero:** solo `imjournal`, y `SysSock.Use="off"` en `imuxsock`. Los campos estructurados sobreviven; algo más de CPU.
> - **socket primero:** solo `imuxsock`, `ForwardToSyslog=yes` en `journald.conf`. Más barato; los campos estructurados se aplanan a texto RFC 3164.

### 4.2 Sintaxis de selectores (legacy, todavía evaluable)

```
facility.priority            action
```

| Expresión | Coincide con |
|---|---|
| `mail.info` | Facility `mail` en `info` **y más severo** (info→emerg) |
| `mail.=info` | `mail` exactamente en `info` |
| `mail.!=info` | `mail` en todo excepto `info` |
| `mail.!info` | `mail` en todo lo *menos severo* que `info` |
| `*.info` | Toda facility en `info` y superior |
| `*.info;mail.none` | …excepto `mail`, que queda excluido por completo |
| `auth,authpriv.*` | Ambas facilities, todas las severidades |
| `*.emerg` | Todo en `emerg` |

Destinos de acción:

| Acción | Significado |
|---|---|
| `/var/log/messages` | Escribir a archivo (sync) |
| `-/var/log/messages` | Escribir a archivo, **omitir `fsync()`** — más rápido, pierde la cola ante un crash |
| `@192.0.2.10:514` | Reenviar por **UDP** |
| `@@192.0.2.10:514` | Reenviar por **TCP** |
| `:omrelp:192.0.2.10:2514` | Reenviar por RELP |
| `\|/var/run/some.pipe` | Named pipe |
| `/dev/console` | Consola |
| `root,ops` | Mensaje estilo `wall` a los usuarios conectados |
| `*` | Todos los usuarios conectados |
| `~` / `stop` | Descartar — `stop` es la grafía moderna |

> **Trampa de examen:** la diferencia entre `@` (UDP) y `@@` (TCP), y el significado del `-` inicial en una ruta de archivo, son preguntas perennes. `mail.none` también.

### 4.3 Garantías de entrega — la tabla de compromisos

| Transporte | Pérdida ante falla de red | Pérdida ante reinicio del receptor | Ordenamiento | Costo | Usar cuando |
|---|---|---|---|---|---|
| UDP (`@`) | Silenciosa, total | Silenciosa | Ninguno | El más bajo | Nunca, en producción, por sí solo |
| TCP (`@@`) | Solo buffer del kernel; pérdida a nivel de aplicación al cerrar | Se pierden los mensajes en vuelo — ACK de TCP ≠ escrito | FIFO por conexión | Bajo | Intra-datacenter, no auditoría |
| TCP + TLS | Igual que TCP | Igual que TCP | FIFO | Moderado (handshake, criptografía) | Al cruzar redes no confiables |
| RELP (`omrelp`) | **Ninguna** — el emisor retransmite los lotes sin ACK | **Ninguna** — el ACK se emite después de que el receptor confirmó | FIFO | Moderado | Auditoría, cumplimiento, financiero |
| RELP + TLS | Ninguna | Ninguna | FIFO | El más alto | Multi-región regulado |

Por encima de eso, la **cola** determina qué pasa cuando la acción no puede avanzar:

| Tipo de cola | Respaldo | Sobrevive al reinicio | Throughput | Modo de falla |
|---|---|---|---|---|
| `direct` | Ninguno | n/a | El más alto | Bloquea el ruleset — genera contrapresión sobre los productores |
| `FixedArray` | RAM, preasignada | No | Alto | Descarta o bloquea en `queue.highWatermark` |
| `LinkedList` | RAM, bajo demanda | No | Alto | Igual, con menor piso de memoria |
| `Disk` | Archivos de spool | Sí | Bajo | Acotada por `queue.maxDiskSpace` |
| **`LinkedList` + `queue.filename`** (*asistida por disco*) | RAM, derramando a disco | Sí (`queue.saveOnShutdown="on"`) | Alto | **La respuesta de producción** |

---

## 5. Comparativa: journald vs rsyslog vs syslog-ng

| Dimensión | `systemd-journald` | `rsyslog` | `syslog-ng` |
|---|---|---|---|
| Formato de almacenamiento | Binario, indexado, encadenado por hash | Texto plano (o cualquier sumidero) | Texto plano (o cualquier sumidero) |
| Campos estructurados | Nativos, con campos `_` verificados por el kernel | Vía `imjournal`/plantillas JSON | Pares nombre/valor nativos |
| Lenguaje de consulta | `journalctl FIELD=value`, `-p`, `--since` | `grep`/`awk` sobre archivos | `grep`/`awk` sobre archivos |
| Transporte de red | Solo vía `systemd-journal-upload`/`-remote` (HTTPS) | Rico: UDP/TCP/TLS/RELP/Kafka/HTTP | Rico, comparable |
| Entrega garantizada | No (solo local) | Sí, con RELP + cola en disco | Sí, con buffer en disco + control de flujo |
| Evidencia de manipulación | **FSS** (Forward Secure Sealing) | Ninguna incorporada | Ninguna incorporada |
| Rotación | Incorporada (`SystemMaxUse=`) | Externa (`logrotate`) | Externa (`logrotate`) |
| Lenguaje de configuración | INI | RainerScript (+ selectores legacy) | Declarativo source/filter/destination |
| Aislamiento por servicio | `LogNamespace=` | Rulesets | Múltiples rutas `log {}` |
| Disponibilidad | Toda distro con systemd | Default en RHEL/Debian/SUSE | Default en algunos appliances, opt-in común |
| CPU / mensaje | Más alta (indexado, hashing) | Baja | Baja |

**Recomendación arquitectónica:** ejecutá **ambos**, con una división clara de responsabilidades. `journald` es el buffer local, estructurado y con evidencia de manipulación, con huella acotada y sin exposición de red. `rsyslog` (o Vector/Fluent Bit) lee de él y es dueño del salto de red y de la retención central. `Storage=` en `journald.conf` pasa entonces a ser una decisión deliberada sobre cuánto buffer forense local querés después de que falle el salto de red.

---

## 6. Configuraciones completas

### 6.1 `/etc/systemd/journald.conf` — línea base de producción

```ini
# /etc/systemd/journald.conf
# Local structured forensic buffer. Retention lives centrally; this is the
# window that survives a network partition.
[Journal]
Storage=persistent
Compress=yes
Seal=yes

# ---- disk accounting -------------------------------------------------------
SystemMaxUse=2G
SystemKeepFree=1G
SystemMaxFileSize=128M
SystemMaxFiles=32
MaxRetentionSec=14day
MaxFileSec=1day

# /run is RAM. Keep the volatile fallback small.
RuntimeMaxUse=128M
RuntimeKeepFree=256M
RuntimeMaxFileSize=16M

# ---- rate limiting ---------------------------------------------------------
# Global guardrail; chatty units get a per-unit override in a drop-in.
RateLimitIntervalSec=30s
RateLimitBurst=20000

# ---- forwarding ------------------------------------------------------------
# rsyslog ingests via imjournal, NOT via /run/systemd/journal/syslog.
ForwardToSyslog=no
ForwardToKMsg=no
ForwardToConsole=no
ForwardToWall=yes

# ---- level ceilings --------------------------------------------------------
MaxLevelStore=debug
MaxLevelSyslog=debug
MaxLevelKMsg=notice
MaxLevelConsole=emerg
MaxLevelWall=emerg

# ---- other -----------------------------------------------------------------
SplitMode=uid
Audit=no
LineMax=48K
```

Aplicar y verificar:

```console
# systemctl restart systemd-journald
# systemd-analyze cat-config systemd/journald.conf | grep -E '^(Storage|Seal|SystemMaxUse)'
Storage=persistent
Seal=yes
SystemMaxUse=2G
```

### 6.2 Habilitar Forward Secure Sealing

FSS hace detectable la manipulación retroactiva: `journald` sella periódicamente el log con una clave que evoluciona; la clave de *verificación* se imprime una sola vez y debe guardarse fuera del host.

```console
# journalctl --setup-keys --interval=15min
Generating seed...
Generating key pair...
Generating sealing key...

The new key pair has been generated. The secret sealing key has been written to
the following local file. This key file is automatically updated when the
sealing key is advanced. It should not be used on multiple hosts.

	/var/log/journal/9f2c5c1b7a1e4d0e8b3f6a2d4c9e1b77/fss

Please write down the following secret verification key. It should be stored at
a safe location and should not be saved locally on disk.

	e1a3b9-2c7d40-88f1ae-30b562/1a2b3c-35a4e900

	The sealing key is automatically changed every 15min.

The keys have been generated for host web-01/9f2c5c1b7a1e4d0e8b3f6a2d4c9e1b77.
```

Verificación posterior (`--verify-key` es la clave de *verificación* impresa arriba):

```console
# journalctl --verify --verify-key=e1a3b9-2c7d40-88f1ae-30b562/1a2b3c-35a4e900
PASS: /var/log/journal/9f2c.../system@0006213f.journal
PASS: /var/log/journal/9f2c.../system.journal
```

### 6.3 `/etc/rsyslog.conf` — nodo hoja, journald primero, RELP+TLS asistido por disco

```rsyslog
#### /etc/rsyslog.conf — leaf node ####
#### rsyslog 8.24+ / RainerScript syntax ####

#### GLOBAL DIRECTIVES ####
global(
  workDirectory="/var/spool/rsyslog"
  maxMessageSize="64k"
  defaultNetstreamDriver="gtls"
  defaultNetstreamDriverCAFile="/etc/pki/rsyslog/ca.pem"
  defaultNetstreamDriverCertFile="/etc/pki/rsyslog/web-01.pem"
  defaultNetstreamDriverKeyFile="/etc/pki/rsyslog/web-01.key"
)

module(load="builtin:omfile"
       fileOwner="root" fileGroup="adm"
       fileCreateMode="0640" dirCreateMode="0755")

#### INPUTS ####
# journald is the single ingestion path. Do NOT also read /dev/log.
module(load="imjournal"
       StateFile="/var/lib/rsyslog/imjournal.state"
       Ratelimit.Interval="0"          # journald already rate-limits
       Ratelimit.Burst="0"
       IgnorePreviousMessages="off"
       UsePid="system")

# Application files that never learned to use syslog.
module(load="imfile" mode="inotify")
input(type="imfile"
      File="/var/log/nginx/access.log"
      Tag="nginx-access"
      Severity="info"
      Facility="local6"
      PersistStateInterval="200"
      reopenOnTruncate="on"
      ruleset="ship")

input(type="imfile"
      File="/var/log/nginx/error.log"
      Tag="nginx-error"
      Severity="error"
      Facility="local6"
      PersistStateInterval="200"
      reopenOnTruncate="on"
      ruleset="ship")

# Self-monitoring: emit rsyslog's own counters every 60 s as JSON.
module(load="impstats"
       interval="60"
       severity="7"
       log.syslog="on"
       resetCounters="off"
       format="cee"
       ruleset="ship")

#### TEMPLATES ####
template(name="RFC5424Plus" type="list") {
  constant(value="<")   property(name="pri")
  constant(value=">1 ") property(name="timereported" dateFormat="rfc3339")
  constant(value=" ")   property(name="hostname")
  constant(value=" ")   property(name="app-name" caseConversion="lower")
  constant(value=" ")   property(name="procid")
  constant(value=" ")   property(name="msgid")
  constant(value=" [origin software=\"rsyslog\" swVersion=\"8\"]")
  constant(value=" ")   property(name="msg" droplastlf="on")
  constant(value="\n")
}

template(name="DynLocalPath" type="string"
         string="/var/log/remote/%HOSTNAME%/%$YEAR%-%$MONTH%-%$DAY%.log")

#### RULESET: local retention (short window) ####
ruleset(name="localfiles") {
  auth,authpriv.*                     action(type="omfile" file="/var/log/secure")
  *.info;mail.none;authpriv.none;cron.none
                                      action(type="omfile" file="/var/log/messages")
  mail.*                              action(type="omfile" file="/var/log/maillog")
  cron.*                              action(type="omfile" file="/var/log/cron")
  *.emerg                             action(type="omusrmsg" users="*")
  local7.*                            action(type="omfile" file="/var/log/boot.log")
}

#### RULESET: ship to the aggregator ####
ruleset(name="ship"
        queue.type="LinkedList"
        queue.size="200000"
        queue.dequeueBatchSize="1024"
        queue.workerThreads="2"
        queue.workerThreadMinimumMessages="20000") {

  action(type="omrelp"
         target="logs.internal.example.com"
         port="2514"
         tls="on"
         tls.caCert="/etc/pki/rsyslog/ca.pem"
         tls.myCert="/etc/pki/rsyslog/web-01.pem"
         tls.myPrivKey="/etc/pki/rsyslog/web-01.key"
         tls.authMode="name"
         tls.permittedPeer=["logs.internal.example.com"]
         template="RFC5424Plus"

         # ---- disk-assisted queue: survives restarts and outages ----
         queue.type="LinkedList"
         queue.filename="ship_relp"
         queue.spoolDirectory="/var/spool/rsyslog"
         queue.maxDiskSpace="4g"
         queue.maxFileSize="128m"
         queue.size="500000"
         queue.highWatermark="400000"
         queue.lowWatermark="200000"
         queue.discardMark="480000"
         queue.discardSeverity="6"     # shed info/debug before err/crit
         queue.saveOnShutdown="on"
         queue.timeoutShutdown="10000"
         queue.checkpointInterval="1000"

         # ---- never give up on the remote side ----
         action.resumeRetryCount="-1"
         action.resumeInterval="10"
         action.reportSuspension="on")
}

#### MAIN ####
*.* call localfiles
*.* call ship
```

### 6.4 Colector central `/etc/rsyslog.d/10-collector.conf`

```rsyslog
#### Central aggregator: RELP over TLS in, per-host files out ####

module(load="imrelp"
       ruleset="fromremote")
input(type="imrelp"
      port="2514"
      tls="on"
      tls.caCert="/etc/pki/rsyslog/ca.pem"
      tls.myCert="/etc/pki/rsyslog/logs.pem"
      tls.myPrivKey="/etc/pki/rsyslog/logs.key"
      tls.authMode="name"
      tls.permittedPeer=["*.internal.example.com"]
      maxDataSize="64k")

# Legacy appliances that only speak UDP — firewalled to a management VLAN.
module(load="imudp" threads="2" timeRequery="8")
input(type="imudp" port="514" address="10.20.0.5" ruleset="fromremote")

template(name="PerHostFile" type="string"
         string="/srv/logs/%$YEAR%/%$MONTH%/%$DAY%/%FROMHOST-IP%/%PROGRAMNAME%.log")

ruleset(name="fromremote"
        queue.type="LinkedList"
        queue.filename="q_fromremote"
        queue.spoolDirectory="/var/spool/rsyslog"
        queue.maxDiskSpace="16g"
        queue.saveOnShutdown="on"
        queue.size="1000000") {

  # Drop anything whose hostname we do not recognise, before it costs disk.
  if not ($fromhost-ip startswith "10.20.") then {
      stop
  }

  action(type="omfile"
         dynaFile="PerHostFile"
         dynaFileCacheSize="200"
         template="RSYSLOG_FileFormat"
         ioBufferSize="64k"
         flushOnTXEnd="off"
         asyncWriting="on"
         fileOwner="root" fileGroup="adm" fileCreateMode="0640")
}
```

### 6.5 `logrotate` — archivo principal y un drop-in real

```
# /etc/logrotate.conf
weekly
rotate 4
create
dateext
dateformat -%Y%m%d
compress
delaycompress
notifempty
missingok
su root adm
tabooext + .rpmsave .rpmnew .dpkg-dist .swp

include /etc/logrotate.d

/var/log/wtmp {
    monthly
    create 0664 root utmp
    minsize 1M
    rotate 1
}

/var/log/btmp {
    missingok
    monthly
    create 0600 root utmp
    rotate 1
}
```

```
# /etc/logrotate.d/nginx
/var/log/nginx/*.log {
    daily
    rotate 14
    maxsize 512M
    minsize 1M
    compress
    compresscmd /usr/bin/zstd
    compressoptions -19 -T2 --rm
    compressext .zst
    uncompresscmd /usr/bin/unzstd
    delaycompress
    missingok
    notifempty
    create 0640 nginx adm
    su root adm
    olddir /var/log/nginx/archive
    createolddir 0750 nginx adm
    sharedscripts
    postrotate
        if [ -f /run/nginx.pid ]; then
            /bin/kill -USR1 "$(cat /run/nginx.pid)"
        fi
    endscript
}
```

```
# /etc/logrotate.d/rsyslog
/var/log/messages
/var/log/secure
/var/log/maillog
/var/log/cron
/var/log/boot.log
{
    daily
    rotate 30
    dateext
    compress
    delaycompress
    missingok
    notifempty
    sharedscripts
    su root adm
    postrotate
        /usr/bin/systemctl -s HUP kill rsyslog.service >/dev/null 2>&1 || true
    endscript
}
```

**Referencia de directivas:**

| Directiva | Efecto |
|---|---|
| `daily` / `weekly` / `monthly` / `yearly` | Disparador basado en tiempo |
| `size 100M` | Rotar cuando sea más grande — **anula** la programación por tiempo |
| `maxsize 100M` | Rotar en el horario programado **o** antes si es más grande |
| `minsize 1M` | Rotar en el horario programado **solo si** es más grande |
| `rotate N` | Conservar N generaciones |
| `maxage N` | Borrar logs rotados con más de N días |
| `compress` / `nocompress` | gzip (o `compresscmd`) sobre los archivos rotados |
| `delaycompress` | Comprimir en la *siguiente* ejecución — requerido cuando el escritor mantiene el fd abierto |
| `missingok` | Sin error si el archivo no existe |
| `notifempty` / `ifempty` | Omitir / permitir la rotación de un archivo vacío |
| `create MODE OWNER GROUP` | Recrear el archivo tras el renombrado |
| `copytruncate` | Copiar y luego truncar en el lugar — **inodo preservado** |
| `dateext` / `dateformat` | Sufijo con fecha en lugar de `.1`, `.2` |
| `olddir` / `createolddir` | Mover los archivos rotados a otro lado |
| `sharedscripts` | Ejecutar `pre/postrotate` **una vez** para todo el glob, no por archivo |
| `su USER GROUP` | Bajar privilegios al rotar un directorio escribible por grupo |
| `prerotate` / `postrotate` … `endscript` | Hooks; el nombre del log es `$1` salvo con `sharedscripts` |
| `firstaction` / `lastaction` | Ejecutar una vez antes/después de todo lo del bloque |

**`create` vs `copytruncate` — la decisión que rompe producción:**

| | `create` (renombrar + recrear) | `copytruncate` |
|---|---|---|
| Mecanismo | `rename()` viejo → nombre nuevo, crear archivo fresco | `cp` del contenido, luego `truncate()` del original |
| Inodo | Cambia | Se preserva |
| El escritor debe | Reabrir el archivo (`SIGHUP`/`SIGUSR1`) o sigue escribiendo en el inodo rotado | Nada |
| Ventana de pérdida de datos | Ninguna | **Sí** — se pierden las escrituras entre `cp` y `truncate()` |
| Pico de disco | Ninguno | 2× el tamaño del archivo durante la copia |
| Usar cuando | La aplicación soporta reapertura (nginx, rsyslog, httpd) | La aplicación no puede reabrir ni ser parcheada |

`copytruncate` además rompe a los escritores `O_APPEND` menos de lo que uno pensaría, pero rompe el seguimiento de estado de `imfile` más de lo que uno pensaría — de ahí `reopenOnTruncate="on"` en la configuración del nodo hoja de arriba.

**Programación:** en distribuciones con systemd, `logrotate` corre desde un timer, no desde cron.

```console
$ systemctl cat logrotate.timer
# /usr/lib/systemd/system/logrotate.timer
[Unit]
Description=Daily rotation of log files
Documentation=man:logrotate(8) man:logrotate.conf(5)

[Timer]
OnCalendar=daily
AccuracySec=1h
Persistent=true

[Install]
WantedBy=timers.target

$ systemctl list-timers logrotate.timer
NEXT                        LEFT       LAST                        PASSED     UNIT            ACTIVATES
Fri 2026-08-28 00:00:00 UTC 8h left    Thu 2026-08-27 00:00:11 UTC 15h ago    logrotate.timer logrotate.service
```

### 6.6 Despliegue de flota (Ansible, completo)

```yaml
---
# roles/logging/tasks/main.yml
- name: Ensure logging packages are present
  ansible.builtin.package:
    name:
      - rsyslog
      - rsyslog-relp
      - rsyslog-gnutls
      - logrotate
    state: present

- name: Create persistent journal directory
  ansible.builtin.file:
    path: /var/log/journal
    state: directory
    owner: root
    group: systemd-journal
    mode: "2755"

- name: Apply journald configuration
  ansible.builtin.template:
    src: journald.conf.j2
    dest: /etc/systemd/journald.conf
    owner: root
    group: root
    mode: "0644"
    validate: "systemd-analyze verify %s || true"
  notify: restart journald

- name: Per-unit journald overrides for chatty services
  ansible.builtin.copy:
    dest: "/etc/systemd/system/{{ item.unit }}.d/10-logging.conf"
    owner: root
    group: root
    mode: "0644"
    content: |
      [Service]
      LogRateLimitIntervalSec={{ item.interval | default('0') }}
      LogRateLimitBurst={{ item.burst | default('0') }}
      LogLevelMax={{ item.level | default('info') }}
  loop: "{{ logging_unit_overrides }}"
  loop_control:
    label: "{{ item.unit }}"
  notify: daemon reload

- name: Install rsyslog TLS material
  ansible.builtin.copy:
    src: "pki/{{ item.src }}"
    dest: "/etc/pki/rsyslog/{{ item.dest }}"
    owner: root
    group: root
    mode: "{{ item.mode }}"
  loop:
    - { src: "ca.pem",                     dest: "ca.pem",   mode: "0644" }
    - { src: "{{ inventory_hostname }}.pem",  dest: "{{ inventory_hostname }}.pem", mode: "0644" }
    - { src: "{{ inventory_hostname }}.key",  dest: "{{ inventory_hostname }}.key", mode: "0600" }
  no_log: true
  notify: restart rsyslog

- name: Create rsyslog spool directory
  ansible.builtin.file:
    path: /var/spool/rsyslog
    state: directory
    owner: root
    group: root
    mode: "0700"

- name: Apply rsyslog configuration
  ansible.builtin.template:
    src: rsyslog.conf.j2
    dest: /etc/rsyslog.conf
    owner: root
    group: root
    mode: "0644"
    backup: true
    validate: "rsyslogd -N1 -f %s"
  notify: restart rsyslog

- name: Apply logrotate drop-ins
  ansible.builtin.template:
    src: "logrotate/{{ item }}.j2"
    dest: "/etc/logrotate.d/{{ item }}"
    owner: root
    group: root
    mode: "0644"
  loop: "{{ logging_logrotate_dropins }}"

- name: Validate the whole logrotate configuration set
  ansible.builtin.command:
    argv: [/usr/sbin/logrotate, --debug, /etc/logrotate.conf]
  register: lr_debug
  changed_when: false
  failed_when: "'error:' in lr_debug.stderr"

- name: Enable and start the logging stack
  ansible.builtin.systemd:
    name: "{{ item }}"
    enabled: true
    state: started
    daemon_reload: true
  loop:
    - systemd-journald.service
    - rsyslog.service
    - logrotate.timer

- name: Emit an end-to-end probe message
  ansible.builtin.command:
    argv:
      - logger
      - --priority
      - local5.notice
      - --tag
      - ansible-probe
      - "logging pipeline probe {{ ansible_date_time.iso8601 }}"
  changed_when: false
```

```yaml
---
# roles/logging/handlers/main.yml
- name: daemon reload
  ansible.builtin.systemd:
    daemon_reload: true

- name: restart journald
  ansible.builtin.systemd:
    name: systemd-journald.service
    state: restarted

- name: restart rsyslog
  ansible.builtin.systemd:
    name: rsyslog.service
    state: restarted
```

```yaml
---
# roles/logging/defaults/main.yml
logging_collector_host: logs.internal.example.com
logging_collector_port: 2514
logging_journal_max_use: 2G
logging_journal_retention: 14day

logging_unit_overrides:
  - unit: payments-api.service
    interval: "0"
    burst: "0"
    level: info
  - unit: chatty-batch.service
    interval: "60s"
    burst: "500"
    level: warning

logging_logrotate_dropins:
  - nginx
  - rsyslog
  - application
```

### 6.7 Un sumidero alternativo moderno (Vector, YAML) leyendo el journal directamente

```yaml
# /etc/vector/vector.yaml
data_dir: /var/lib/vector

sources:
  journal:
    type: journald
    current_boot_only: false
    since_now: false
    journal_directory: /var/log/journal
    include_units: []
    exclude_units:
      - vector.service
    batch_size: 256

  nginx_files:
    type: file
    include:
      - /var/log/nginx/*.log
    read_from: beginning
    fingerprint:
      strategy: checksum
      ignored_header_bytes: 0

transforms:
  normalise:
    type: remap
    inputs: [journal, nginx_files]
    source: |
      .host        = get!(., ["host"]) ?? .["_HOSTNAME"] ?? "unknown"
      .unit        = .["_SYSTEMD_UNIT"] ?? "n/a"
      .severity    = to_int(.PRIORITY) ?? 6
      .facility    = to_int(.SYSLOG_FACILITY) ?? 1
      .severity_name = {
        "0": "emerg", "1": "alert", "2": "crit",  "3": "err",
        "4": "warning", "5": "notice", "6": "info", "7": "debug"
      }[to_string(.severity)] ?? "info"
      del(.["__CURSOR"])
      del(.["_CMDLINE"])

  drop_debug:
    type: filter
    inputs: [normalise]
    condition: '.severity <= 6'

sinks:
  central:
    type: socket
    inputs: [drop_debug]
    mode: tcp
    address: logs.internal.example.com:6514
    encoding:
      codec: json
    tls:
      enabled: true
      ca_file: /etc/pki/vector/ca.pem
      crt_file: /etc/pki/vector/host.pem
      key_file: /etc/pki/vector/host.key
      verify_hostname: true
    buffer:
      type: disk
      max_size: 4294967296
      when_full: block
```

---

## 7. Línea de comandos: sesiones reales

### 7.1 Inyectar mensajes: `logger` y `systemd-cat`

```console
$ logger "plain message, defaults to user.notice"
$ logger -p local4.err -t deploy-agent "rollout 7f31c2 failed: image pull backoff"
$ logger -p authpriv.warning --id=$$ -t custom-pam "unexpected auth path"
$ echo "from a pipe" | logger -t pipeline -p local4.info
$ logger --rfc5424=notime -p local4.info -t app5424 "structured-ish"
$ logger --journald <<'EOF'
MESSAGE=order rejected by risk engine
PRIORITY=3
SYSLOG_IDENTIFIER=risk-engine
ORDER_ID=A-99213
TENANT=acme
EOF
```

| Flag de `logger` | Significado |
|---|---|
| `-p, --priority facility.severity` | Default `user.notice` |
| `-t, --tag TAG` | `SYSLOG_IDENTIFIER`; por defecto el nombre de login |
| `-i` / `--id[=ID]` | Incluir el PID (o un ID explícito) |
| `-s, --stderr` | También replicar a stderr |
| `-f, --file FILE` | Enviar el contenido de un archivo, un mensaje por línea |
| `-u, --socket SOCK` | Usar un socket UNIX alternativo |
| `-n, --server HOST` `-P, --port` | Enviar directamente por la red |
| `-T` / `-d` | Forzar TCP / UDP |
| `--rfc3164` / `--rfc5424[=opts]` | Formato de cable |
| `--journald[=FILE]` | Enviar campos nativos del journal desde stdin |
| `--size N` | Tamaño máximo de mensaje |

`systemd-cat` enruta el stdout/stderr completo de un comando hacia el journal — la forma correcta de capturar un trabajo de cron o un script de una sola ejecución:

```console
$ systemd-cat -t nightly-reindex -p info -- /usr/local/bin/reindex.sh --full
$ echo "hello journal" | systemd-cat -t adhoc -p warning
$ journalctl -t nightly-reindex -n 3 -o short-precise
Aug 27 03:00:01.442119 web-01 nightly-reindex[41288]: starting full reindex (shards=8)
Aug 27 03:14:52.910773 web-01 nightly-reindex[41288]: shard 8/8 complete
Aug 27 03:14:52.913004 web-01 nightly-reindex[41288]: done in 891s
```

Verificar el registro estructurado inyectado:

```console
$ journalctl -t risk-engine -n 1 -o json-pretty
{
	"__CURSOR" : "s=9f2c5c1b7a1e4d0e8b3f6a2d4c9e1b77;i=1a2f9;b=4c7e...;m=8f2b1c;t=63c9a1d;x=2b1f",
	"__REALTIME_TIMESTAMP" : "1787913601442119",
	"__MONOTONIC_TIMESTAMP" : "9382771442",
	"_BOOT_ID" : "4c7e1f0b9a2d4e6f8091a2b3c4d5e6f7",
	"PRIORITY" : "3",
	"MESSAGE" : "order rejected by risk engine",
	"SYSLOG_IDENTIFIER" : "risk-engine",
	"ORDER_ID" : "A-99213",
	"TENANT" : "acme",
	"_UID" : "0",
	"_GID" : "0",
	"_COMM" : "logger",
	"_EXE" : "/usr/bin/logger",
	"_CMDLINE" : "logger --journald",
	"_TRANSPORT" : "journal",
	"_MACHINE_ID" : "9f2c5c1b7a1e4d0e8b3f6a2d4c9e1b77",
	"_HOSTNAME" : "web-01",
	"_SYSTEMD_UNIT" : "session-3.scope",
	"_SYSTEMD_SLICE" : "user-1000.slice"
}
```

Notá que `ORDER_ID` y `TENANT` sobrevivieron como campos de primera clase — y por lo tanto son indexables: `journalctl ORDER_ID=A-99213`.

### 7.2 `journalctl` en el fragor

```console
# Follow a unit, with microsecond timestamps
$ journalctl -u nginx.service -f -o short-precise

# Errors and worse since 09:00, this boot
$ journalctl -b -p err --since 09:00 --no-pager

# Previous boot, kernel only
$ journalctl -b -1 -k

# Two-field intersection: this binary, this UID
$ journalctl _COMM=sshd _UID=0 --since "2 hours ago"

# OR across values of the same field; + is a logical OR across groups
$ journalctl _SYSTEMD_UNIT=nginx.service + _SYSTEMD_UNIT=php-fpm.service

# A time window with an explicit end
$ journalctl --since "2026-08-27 14:00:00" --until "2026-08-27 14:15:00"

# Full-text grep, case-insensitive, with 5 lines of context is NOT available;
# journalctl grep is regex over MESSAGE only:
$ journalctl -u payments-api -g 'timeout|refused' --case-sensitive=false

# Who owns the disk?
$ journalctl --disk-usage
Archived and active journals take up 1.8G in the file system.

# What field values exist? (indispensable for building queries)
$ journalctl -F _SYSTEMD_UNIT | sort | head
NetworkManager.service
auditd.service
chronyd.service
crond.service
dbus-broker.service
nginx.service
payments-api.service
rsyslog.service
sshd.service
systemd-journald.service

# Explain the fields of the last 5 records in full
$ journalctl -n 5 -o verbose
```

| Opción de `journalctl` | Propósito |
|---|---|
| `-u UNIT` / `--user-unit` | Filtrar por unidad de systemd |
| `-b [ID\|±N]` | Arranque: `-b` actual, `-b -1` anterior, `--list-boots` para enumerar |
| `-k` / `--dmesg` | Solo mensajes del kernel |
| `-p LEVEL` / `-p A..B` | Techo o rango de severidad |
| `-S/--since`, `-U/--until` | Absoluto (`YYYY-MM-DD HH:MM:SS`) o relativo (`-1h`, `yesterday`) |
| `-f`, `-n N` | Seguir, cola |
| `-g PATTERN` | Regex sobre `MESSAGE` |
| `-o FORMAT` | `short`, `short-precise`, `short-iso`, `verbose`, `json`, `json-pretty`, `cat`, `export` |
| `-F FIELD` / `-N` | Listar valores de un campo / listar todos los nombres de campo |
| `--disk-usage` | Bytes consumidos |
| `--vacuum-size=`, `--vacuum-time=`, `--vacuum-files=` | Poda manual |
| `--rotate`, `--sync`, `--flush`, `--relinquish-var` | Control del ciclo de vida |
| `--verify [--verify-key=]` | Chequeo de integridad / FSS |
| `--list-boots` | Índice de arranques con timestamps |
| `-D DIR` / `--file GLOB` / `-M CONTAINER` | Leer journals desde otro lugar |
| `--no-pager` | Obligatorio en scripts |

Leer un journal recuperado de un host muerto — la razón por la que el formato binario es un activo, no un lastre:

```console
$ journalctl -D /mnt/rescue/var/log/journal --since "2026-08-26 22:00" -p warning -o short-iso
2026-08-26T22:41:03+0000 db-03 kernel: Out of memory: Killed process 2291 (postgres) total-vm:8912344kB
2026-08-26T22:41:03+0000 db-03 systemd[1]: postgresql.service: A process of this unit has been killed by the OOM killer.
2026-08-26T22:41:04+0000 db-03 systemd[1]: postgresql.service: Failed with result 'oom-kill'.
```

### 7.3 Operación de `rsyslog`

```console
# Syntax check WITHOUT touching the running daemon — always do this first
$ sudo rsyslogd -N1
rsyslogd: version 8.2402.0, config validation run (level 1), master config /etc/rsyslog.conf
rsyslogd: End of config validation run. Bye.

# Validate a candidate file before installing it
$ sudo rsyslogd -N1 -f /tmp/rsyslog.conf.new

# Reload after a config change (rsyslog re-reads on SIGHUP)
$ sudo systemctl reload rsyslog

# What is the daemon actually doing?
$ systemctl status rsyslog --no-pager
● rsyslog.service - System Logging Service
     Loaded: loaded (/usr/lib/systemd/system/rsyslog.service; enabled; preset: enabled)
     Active: active (running) since Thu 2026-08-27 06:12:41 UTC; 9h ago
       Docs: man:rsyslogd(8)
             https://www.rsyslog.com/doc/
   Main PID: 1043 (rsyslogd)
      Tasks: 8 (limit: 4587)
     Memory: 41.2M
        CPU: 3min 12.884s
     CGroup: /system.slice/rsyslog.service
             └─1043 /usr/sbin/rsyslogd -n

Aug 27 06:12:41 web-01 systemd[1]: Starting System Logging Service...
Aug 27 06:12:41 web-01 rsyslogd[1043]: imjournal: journal files changed, reloading... [v8.2402.0]
Aug 27 06:12:41 web-01 systemd[1]: Started System Logging Service.
```

Leer la salida de `impstats` — los contadores de cola son la señal de salud que importa:

```console
$ journalctl -t rsyslogd -g impstats -n 4 -o cat
{"name":"ship_relp","origin":"core.queue","size":0,"enqueued":184213,"full":0,"discarded.full":0,"discarded.nf":0,"maxqsize":9821}
{"name":"action-0-omrelp","origin":"core.action","processed":184213,"failed":0,"suspended":0,"resumed":0}
{"name":"imuxsock","origin":"imuxsock","submitted":0,"ratelimit.discarded":0}
{"name":"resource-usage","origin":"impstats","utime":190312000,"stime":41220000,"maxrss":42128,"openfiles":37}
```

| Contador | Saludable | Significado cuando se mueve |
|---|---|---|
| `size` | ≈0 | Profundidad actual de la cola; crecimiento sostenido = el downstream es más lento que la ingesta |
| `maxqsize` | ≪ `queue.size` | Marca de máximo; acercarse a `discardMark` significa que el descarte es inminente |
| `discarded.full` | 0 | Mensajes destruidos porque la cola alcanzó `discardMark` — **pérdida de datos** |
| `discarded.nf` | 0 | Descartados porque no estaba llena pero por debajo de la severidad de descarte |
| `failed` / `suspended` | 0 | La acción está fallando; revisá el remoto |
| `ratelimit.discarded` | 0 | La *entrada* descartó mensajes |

### 7.4 Operación de `logrotate`

```console
# Dry run: shows exactly what WOULD happen, changes nothing.
$ sudo logrotate --debug /etc/logrotate.conf
WARNING: logrotate in debug mode does nothing except printing debug messages!

Handling 12 logs
rotating pattern: /var/log/nginx/*.log  after 1 days (14 rotations)
empty log files are not rotated, old logs are removed
considering log /var/log/nginx/access.log
  Now: 2026-08-27 15:22
  Last rotated at 2026-08-27 00:00
  log does not need rotating (log has already been rotated)
considering log /var/log/nginx/error.log
  Now: 2026-08-27 15:22
  Last rotated at 2026-08-27 00:00
  log does not need rotating (log has already been rotated)

rotating pattern: /var/log/messages  after 1 days (30 rotations)
considering log /var/log/messages
  Now: 2026-08-27 15:22
  Last rotated at 2026-08-26 00:00
  log needs rotating
rotating log /var/log/messages, log->rotateCount is 30
dateext suffix '-20260827'
glob pattern '-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]'
renaming /var/log/messages to /var/log/messages-20260827
running postrotate script
```

```console
# Force rotation of a single definition, verbosely
$ sudo logrotate -vf /etc/logrotate.d/nginx

# Use an alternate state file — mandatory when testing so you do not
# poison the production schedule
$ sudo logrotate -v --state /tmp/lr.status /etc/logrotate.d/nginx

# Inspect the real state file
$ sudo head -8 /var/lib/logrotate/logrotate.status
logrotate state -- version 2
"/var/log/btmp" 2026-8-1-0:0:0
"/var/log/cron" 2026-8-27-0:0:0
"/var/log/maillog" 2026-8-27-0:0:0
"/var/log/messages" 2026-8-27-0:0:0
"/var/log/nginx/access.log" 2026-8-27-0:0:0
"/var/log/nginx/error.log" 2026-8-27-0:0:0
"/var/log/secure" 2026-8-27-0:0:0
```

> La ubicación del archivo de estado difiere según la distribución: `/var/lib/logrotate/logrotate.status` (familia RHEL) vs `/var/lib/logrotate/status` (familia Debian). `logrotate` decide "necesita rotarse" **únicamente** comparando este archivo con la programación — borrarlo hace que todo rote en la siguiente ejecución, y un timestamp obsoleto es la razón más común por la que una configuración que parece correcta aparenta no hacer nada.

---

## 8. `/var/log`: qué vive dónde

| Ruta | Escrito por | Formato |
|---|---|---|
| `/var/log/messages` (RHEL) / `/var/log/syslog` (Debian) | rsyslog | Texto, general |
| `/var/log/secure` (RHEL) / `/var/log/auth.log` (Debian) | rsyslog (`authpriv`) | Texto |
| `/var/log/maillog` / `/var/log/mail.log` | rsyslog (`mail`) | Texto |
| `/var/log/cron` | rsyslog (`cron`) | Texto |
| `/var/log/boot.log` | rsyslog (`local7`) / plymouth | Texto |
| `/var/log/wtmp` | `login`, `init` | **Binario** — leer con `last` |
| `/var/log/btmp` | PAM | **Binario** — leer con `lastb` (root) |
| `/var/run/utmp` | sesiones de login | **Binario** — leer con `who`, `w` |
| `/var/log/lastlog` | PAM | **Binario** — leer con `lastlog` |
| `/var/log/journal/` | journald | **Binario** — leer con `journalctl` |
| `/var/log/dmesg` | script de arranque (no siempre presente) | Instantánea en texto del ring buffer |

```console
$ last -5 -F
alice    pts/1        10.20.3.44       Thu Aug 27 14:02:11 2026   still logged in
bob      pts/0        10.20.3.51       Thu Aug 27 09:41:03 2026 - Thu Aug 27 12:10:55 2026  (02:29)
reboot   system boot  6.6.0-31-generic Thu Aug 27 06:12:33 2026   still running

$ sudo lastb -3
attacker ssh:notty    203.0.113.44     Thu Aug 27 03:11:19 2026 - Thu Aug 27 03:11:19 2026  (00:00)
attacker ssh:notty    203.0.113.44     Thu Aug 27 03:11:17 2026 - Thu Aug 27 03:11:17 2026  (00:00)
```

---

## 9. Verificación y diagnóstico de fallas

### 9.1 Sonda de punta a punta (ejecutala después de cada cambio)

```console
# 1. Emit a uniquely identifiable message
$ MARK="probe-$(date +%s)-$$"
$ logger -p local5.notice -t pipeline-probe "$MARK"

# 2. Did journald accept it?
$ journalctl -t pipeline-probe -n 1 -o short-iso --no-pager
2026-08-27T15:33:41+0000 web-01 pipeline-probe[52011]: probe-1787931221-52011

# 3. Did rsyslog route it locally?
$ sudo grep -F "$MARK" /var/log/messages
Aug 27 15:33:41 web-01 pipeline-probe[52011]: probe-1787931221-52011

# 4. Did it reach the aggregator? (from the collector)
collector$ sudo grep -rF "probe-1787931221" /srv/logs/2026/08/27/
/srv/logs/2026/08/27/10.20.1.14/pipeline-probe.log:2026-08-27T15:33:41.902113+00:00 web-01 pipeline-probe 52011 - [origin ...] probe-1787931221-52011
```

Si el paso 4 falla pero el paso 3 tiene éxito, la falla está en el salto de red; si el paso 3 falla pero el paso 2 tiene éxito, está en `rsyslog`; si el paso 2 falla, está en `journald` o en el socket.

### 9.2 Síntoma → causa → verificación

| Síntoma | Causa probable | Comando que lo prueba |
|---|---|---|
| `journalctl -b -1` dice "no persistent journal" | `Storage=auto` y falta `/var/log/journal` | `ls -ld /var/log/journal; systemd-analyze cat-config systemd/journald.conf \| grep ^Storage` |
| Los mensajes aparecen dos veces en `/var/log/messages` | `imjournal` **e** `imuxsock` activos a la vez, o `ForwardToSyslog=yes` junto con `imjournal` | `grep -rE 'imjournal\|imuxsock\|SysSock' /etc/rsyslog.conf /etc/rsyslog.d/`; `grep ForwardToSyslog /etc/systemd/journald.conf` |
| "Suppressed N messages from …" en el journal | Límite de tasa de journald | `journalctl -u systemd-journald -g Suppressed`; se arregla con un drop-in `LogRateLimitBurst=` |
| No llega nada al colector, sin error local | Acción UDP + descarte del firewall | `ss -lunp \| grep 514` en el colector; `tcpdump -ni eth0 udp port 514` |
| rsyslog registra "action suspended" repetidamente | Remoto inalcanzable o peer TLS rechazado | `journalctl -u rsyslog -g suspended -n 20`; `openssl s_client -connect logs:2514 -CAfile /etc/pki/rsyslog/ca.pem` |
| La cola en disco crece sin límite | `queue.maxDiskSpace` sin definir o demasiado grande; downstream caído | `du -sh /var/spool/rsyslog`; `size`/`maxqsize` de impstats |
| El archivo de log fue rotado pero sigue creciendo con el nombre viejo | El escritor retiene el fd y no hay señal de reapertura en `postrotate` | `sudo lsof -p $(pidof nginx \| cut -d' ' -f1) \| grep '\.log'` → buscar `(deleted)` |
| `logrotate` "no hace nada" | Archivo de estado obsoleto, o `notifempty` con un log vacío, o permisos de archivo incorrectos | `logrotate --debug /etc/logrotate.conf`; `grep messages /var/lib/logrotate/logrotate.status` |
| logrotate: "Ignoring … because of bad file mode / bad owner" | Directorio o archivo escribible por un dueño distinto de root y `su` no declarado | Agregar `su root adm`; `stat -c '%A %U:%G' /var/log/nginx` |
| `/var` lleno a pesar de la rotación | El journal no está contabilizado en el presupuesto de rotación | `journalctl --disk-usage`; `du -sh /var/log/* \| sort -h \| tail` |
| Los timestamps del almacén central están corridos varias horas | RFC 3164 no tiene zona horaria; relay en otra TZ | Cambiar la plantilla a `RSYSLOG_SyslogProtocol23Format` / RFC 3339 |
| El journal reporta corrupción después de un crash | Apagado sucio a mitad de una escritura | `journalctl --verify`; rotar el archivo malo con `journalctl --rotate` |

### 9.3 Demostrar el bug de rotación por descriptor de archivo

El incidente de "los logs se detuvieron" más común de todos. Tras la rotación, una aplicación que nunca reabrió sigue escribiendo en el inodo desenlazado:

```console
$ sudo lsof -p 2291 | grep -E 'access\.log'
nginx   2291 nginx    5w   REG  253,1  1073741824  132876 /var/log/nginx/access.log-20260827 (deleted)

$ ls -l /var/log/nginx/access.log
-rw-r----- 1 nginx adm 0 Aug 27 00:00 /var/log/nginx/access.log

$ df -h /var
Filesystem      Size  Used Avail Use% Mounted on
/dev/mapper/vg-var   20G   19G  1.0G  95% /var
```

El archivo nuevo tiene 0 bytes, el inodo borrado tiene 1 GiB y sigue creciendo, y el espacio no se recupera hasta que el proceso cierre el fd. Resolución: enviar la señal de reapertura (`kill -USR1` para nginx, `systemctl reload rsyslog`, `SIGHUP` para la mayoría de los demonios) y agregar el bloque `postrotate` de forma permanente.

### 9.4 Runbook de presión de disco

```console
# Immediate reclamation, ordered from safest to most destructive
$ sudo journalctl --vacuum-time=2d
Deleted archived journal /var/log/journal/9f2c.../system@0006213f-...journal (128.0M).
Vacuuming done, freed 768.0M of archived journals from /var/log/journal/9f2c...

$ sudo journalctl --vacuum-size=500M
$ sudo journalctl --rotate && sudo journalctl --vacuum-files=5

# Force a rotation cycle across everything logrotate manages
$ sudo logrotate -f /etc/logrotate.conf

# Find the actual consumer — remember deleted-but-open files
$ sudo du -xh --max-depth=2 /var/log | sort -h | tail -10
$ sudo lsof -nP +L1 /var | awk '$7 > 100000000'
```

Hacé permanentes los límites después (`SystemMaxUse=`, `maxsize`, `maxage`) — un vaciado manual que no va seguido de un cambio de configuración garantiza la misma página a la misma hora el mes que viene.

### 9.5 Diagnóstico en tiempo de arranque

```console
$ journalctl --list-boots
IDX BOOT ID                          FIRST ENTRY                 LAST ENTRY
 -2 8a1c4f2e7b3d4c5e9f0a1b2c3d4e5f60 Tue 2026-08-25 07:03:11 UTC Wed 2026-08-26 22:41:09 UTC
 -1 4c7e1f0b9a2d4e6f8091a2b3c4d5e6f7 Wed 2026-08-26 22:44:02 UTC Thu 2026-08-27 06:11:58 UTC
  0 b7d3e9a1c5f24608bb1d7e3f9a0c2d48 Thu 2026-08-27 06:12:33 UTC Thu 2026-08-27 15:41:20 UTC

# The unclean boundary: -2 ends at 22:41:09, -1 starts at 22:44:02 → not a clean reboot.
$ journalctl -b -2 -p err -n 20 --no-pager
Aug 26 22:41:03 db-03 kernel: Out of memory: Killed process 2291 (postgres) ...
Aug 26 22:41:07 db-03 kernel: EXT4-fs error (device dm-1): ext4_journal_check_start:83: Detected aborted journal
```

---

## 10. Checklist orientado al examen

- `PRI = facility × 8 + severity`; `authpriv` es 10, `local0`–`local7` son 16–23; `emerg`=0 … `debug`=7.
- `mail.info` significa info **y superior**; `mail.=info` es exacto; `mail.none` excluye.
- `@host` es UDP, `@@host` es TCP; un `-` antes de un nombre de archivo omite `fsync()`.
- `rsyslogd -N1` valida la configuración sin reiniciar.
- `logger -p local0.err -t mytag "msg"` — la prioridad por defecto es `user.notice`.
- `systemd-cat` envuelve un comando; `logger --journald` envía campos nativos.
- `journalctl -u`, `-b`, `-k`, `-p`, `-f`, `--since`, `--disk-usage`, `--vacuum-size`, `--verify`.
- El journal persistente requiere que `/var/log/journal` exista (o `Storage=persistent`).
- `logrotate` se maneja con `/etc/logrotate.conf` + `/etc/logrotate.d/`, lo programa `logrotate.timer` (o `cron.daily`), y recuerda el estado en `/var/lib/logrotate/`.
- `copytruncate` preserva el inodo y pierde una ventana pequeña; `create` + una señal de reapertura en `postrotate` no pierde nada.
- `sharedscripts` ejecuta `postrotate` una vez por bloque en lugar de una vez por archivo coincidente.
- `/var/log/wtmp`, `btmp`, `lastlog` y el journal son **binarios** — `cat` nunca es la respuesta.

---

## Referencias

- LPI — Exam 101-500 Objectives: https://www.lpi.org/our-certifications/exam-101-objectives/
- LPI — Exam 102-500 Objectives (el tema 108.2 vive acá): https://www.lpi.org/our-certifications/exam-102-objectives/
- RFC 5424 — The Syslog Protocol: https://www.rfc-editor.org/rfc/rfc5424
- RFC 3164 — The BSD Syslog Protocol: https://www.rfc-editor.org/rfc/rfc3164
- RFC 5425 — TLS Transport Mapping for Syslog: https://www.rfc-editor.org/rfc/rfc5425
- RFC 5426 — Transmission of Syslog Messages over UDP: https://www.rfc-editor.org/rfc/rfc5426
- RFC 6587 — Transmission of Syslog Messages over TCP: https://www.rfc-editor.org/rfc/rfc6587
- RFC 3195 — Reliable Delivery for Syslog: https://www.rfc-editor.org/rfc/rfc3195
- Documentación de rsyslog (configuración, módulos, colas): https://www.rsyslog.com/doc/
- rsyslog — Understanding rsyslog Queues: https://www.rsyslog.com/doc/concepts/queues.html
- rsyslog — módulo `imjournal`: https://www.rsyslog.com/doc/configuration/modules/imjournal.html
- rsyslog — módulo `omrelp`: https://www.rsyslog.com/doc/configuration/modules/omrelp.html
- rsyslog — módulo `impstats`: https://www.rsyslog.com/doc/configuration/modules/impstats.html
- rsyslog — TLS con GnuTLS: https://www.rsyslog.com/doc/tutorials/tls.html
- systemd — `systemd-journald.service(8)`: https://www.freedesktop.org/software/systemd/man/latest/systemd-journald.service.html
- systemd — `journald.conf(5)`: https://www.freedesktop.org/software/systemd/man/latest/journald.conf.html
- systemd — `journalctl(1)`: https://www.freedesktop.org/software/systemd/man/latest/journalctl.html
- systemd — `systemd.journal-fields(7)`: https://www.freedesktop.org/software/systemd/man/latest/systemd.journal-fields.html
- systemd — `systemd-cat(1)`: https://www.freedesktop.org/software/systemd/man/latest/systemd-cat.html
- systemd — `systemd.exec(5)` (`LogNamespace=`, `LogRateLimit*=`, `LogLevelMax=`): https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html
- systemd — Journal File Format: https://systemd.io/JOURNAL_FILE_FORMAT/
- systemd — `systemd-journal-remote(8)` / `systemd-journal-upload(8)`: https://www.freedesktop.org/software/systemd/man/latest/systemd-journal-remote.html
- logrotate — proyecto upstream y manual: https://github.com/logrotate/logrotate
- util-linux — `logger(1)`: https://man7.org/linux/man-pages/man1/logger.1.html
- Documentación de syslog-ng Open Source Edition: https://www.syslog-ng.com/technical-documents/list/syslog-ng-open-source-edition
- Documentación de Vector — fuente `journald`: https://vector.dev/docs/reference/configuration/sources/journald/
- Linux man-pages — `syslog(3)`, `syslog(2)`: https://man7.org/linux/man-pages/man3/syslog.3.html