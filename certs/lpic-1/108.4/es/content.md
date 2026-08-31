# 108.4 — Gestión de impresoras e impresión

**Certificación:** LPIC-1 (101-500 / 102-500), versión 5.0
**Peso del examen en este snapshot del temario:** 0
**Perfil:** Principal Platform Architect / Senior SRE

---

## 1. Motivación y el problema arquitectónico de producción

La impresión es el único subsistema donde una plataforma Linux deja de ser software y se convierte en **salida física e irreversible**. Todo lo demás en tu stack es idempotente por construcción: podés reejecutar un job, reaplicar un manifiesto, reproducir una partición de Kafka. No podés des-imprimir una etiqueta de envío. Esa asimetría es lo que convierte al camino de impresión en un problema de SRE y no en una molestia de escritorio.

Tres formas de producción mantienen vivo este stack mucho después de que "la oficina se volvió sin papel":

| Forma | Ejemplo | Costo del fallo |
|---|---|---|
| **Impresión de etiquetas logísticas** | ZPL hacia una Zebra ZT411 por `socket://…:9100` en una estación de picking de depósito | Una cola detenida frena el fulfilment; una etiqueta duplicada envía dos paquetes contra un solo pedido |
| **Salida de documentos regulados** | Resultados de laboratorio, recetas, declaraciones aduaneras renderizadas a PDF y luego encoladas | Incumplimiento normativo; un job perdido es un rastro de auditoría perdido |
| **Pipelines de archivado / renderizado** | Backends `cups-pdf` o `file://` usados como renderizador PDF headless dentro de jobs batch | Corrupción silenciosa de un archivo que nadie lee hasta la auditoría |

El problema arquitectónico es que **CUPS es un sistema de colas que la mayoría de los equipos trata como un driver de dispositivo.** Tiene todas las propiedades de un message broker — un spool durable, una política de reintentos, un comportamiento de dead-letter, backpressure por destino, un log de contabilidad — y casi nada del instrumental operativo. Concretamente:

1. **El spool es estado, y es local al nodo.** `/var/spool/cups` contiene archivos de control (`c00412`) y archivos de datos (`d00412-001`). Perderlo significa perder trabajo aceptado pero no impreso. Cualquier plan de "escalar el servidor de impresión a 2 réplicas", sin coordinación compartida, es un generador de salida duplicada: cada réplica tiene su propio spool y su propia idea de los IDs de job, y ambas empujarán alegremente bytes al puerto 9100 del mismo dispositivo físico.
2. **La semántica de entrega es configurable y casi siempre está mal por defecto.** `printer-error-policy` decide si un timeout del dispositivo significa *reintentar para siempre*, *reintentar N veces y luego detener la cola*, o *abortar el job*. En una impresora de etiquetas, `retry-job` después de un evento de papel agotado es lo correcto. En un batch nocturno de 4000 páginas, `retry-job` contra un dispositivo offline es la forma de descubrir el lunes que la cola viene reintentando desde el viernes.
3. **La superficie de fallo es una cadena de procesos, no un call stack.** `cupsd` → cadena de conversión MIME (`pdftopdf` → `pdftoraster` → `rastertoXXX`) → backend (`socket`/`ipp`/`usb`). Cada eslabón es un binario ejecutado por separado con su propio código de salida. Un filtro que sale con 1 produce un job en estado `stopped` y una línea en `error_log`; nada más en tu stack de observabilidad se entera.
4. **El descubrimiento no sobrevive a la segmentación de red.** mDNS/DNS-SD (`dnssd://`) es link-local por diseño. Funciona en la LAN de la oficina y deja de funcionar silenciosamente en el momento en que el servidor de impresión se muda a una red de pods de Kubernetes o a otra VLAN. Los servidores de impresión de producción deben usar **URIs de dispositivo explícitas**, no descubrimiento.

El objetivo de ingeniería, entonces: tratar cada cola como un **canal de entrega con nombre, configurado declarativamente, con URI explícita, política de error explícita, un SLO y una métrica exportada** — y tratar el spool como el volumen durable de escritor único que realmente es.

### Modelo de nivel de servicio para un camino de impresión

| SLI | Definición | Fuente de verdad | Objetivo típico |
|---|---|---|---|
| Latencia de aceptación del job | envío con `lp` → job en `pending` | `access_log` (`POST /printers/x HTTP/1.1" 200`) | p99 < 500 ms |
| Latencia de finalización de impresión | `pending` → `completed` | timestamp de `page_log` − timestamp de `access_log` | p95 < 20 s para ZPL de etiqueta única |
| Disponibilidad de la cola | fracción de scrapes donde `printer-state != stopped` y `printer-is-accepting-jobs = true` | IPP `Get-Printer-Attributes` | 99,5 % |
| Backlog del spool | cantidad de jobs en `pending` + `processing` | `lpstat -o` / IPP | < 5 sostenido |
| Tasa de salida duplicada | páginas en `page_log` ÷ páginas solicitadas | `page_log` | 0 — alertar ante cualquier exceso |

---

## 2. Anatomía del stack

### 2.1 Flujo de procesos y datos

```
lp / lpr / IPP client
        │  HTTP POST (IPP/2.0 over :631)
        ▼
     cupsd  ──► /var/spool/cups/c00412       (control file: IPP attributes)
        │       /var/spool/cups/d00412-001   (payload)
        │
        │  MIME type detection: /etc/cups/mime.types
        │  Conversion chain:    /etc/cups/mime.convs + PPD/IPP attributes
        ▼
  /usr/lib/cups/filter/pdftopdf
        ▼
  /usr/lib/cups/filter/gstoraster  (or driverless: no rasterisation at all)
        ▼
  /usr/lib/cups/filter/rastertopclx
        ▼
  /usr/lib/cups/backend/socket   ──► TCP 10.42.7.55:9100
                                     └─► exit code decides error policy
```

Los códigos de salida del backend son el contrato entre el transporte y el planificador, y vale la pena memorizarlos porque son sobre lo que actúa la política de error:

| Salida | Nombre | Comportamiento de `cupsd` |
|---|---|---|
| 0 | `CUPS_BACKEND_OK` | El job se completa |
| 1 | `CUPS_BACKEND_FAILED` | Aplica `printer-error-policy` |
| 2 | `CUPS_BACKEND_AUTH_REQUIRED` | Retiene el job, solicita credenciales |
| 3 | `CUPS_BACKEND_HOLD` | Retiene este job, mantiene la cola funcionando |
| 4 | `CUPS_BACKEND_STOP` | Detiene la cola, reencola el job |
| 5 | `CUPS_BACKEND_CANCEL` | Cancela el job (error de datos irrecuperable) |
| 6 | `CUPS_BACKEND_RETRY` | Reintenta según `JobRetryInterval` / `JobRetryLimit` |
| 7 | `CUPS_BACKEND_RETRY_CURRENT` | Reintenta inmediatamente sin reejecutar los filtros |

### 2.2 El contrato del sistema de archivos

| Ruta | Propietario | ¿Editable a mano? | Propósito |
|---|---|---|---|
| `/etc/cups/cupsd.conf` | admin | **Sí** | Comportamiento del planificador, listeners, políticas, ACLs de `Location` |
| `/etc/cups/cups-files.conf` | admin | **Sí** | Directivas de archivo/directorio/usuario, separadas desde CUPS 1.6 para endurecer contra escalada de privilegios |
| `/etc/cups/printers.conf` | `cupsd` | **No** — reescrito en cada cambio | Definiciones de colas persistidas |
| `/etc/cups/classes.conf` | `cupsd` | **No** | Definiciones persistidas de clases (pools de impresoras) |
| `/etc/cups/subscriptions.conf` | `cupsd` | **No** | Suscripciones a eventos persistidas |
| `/etc/cups/ppd/<queue>.ppd` | `cupsd`/`lpadmin` | No recomendado | PostScript Printer Description por cola |
| `/etc/cups/lpoptions`, `~/.cups/lpoptions` | `lpoptions` | Sí | Destino y opciones por defecto a nivel sistema / por usuario |
| `/etc/cups/client.conf`, `~/.cups/client.conf` | admin | **Sí** | `ServerName` *del lado cliente* — apunta un host a un `cupsd` remoto sin planificador local |
| `/etc/printcap` | `cupsd` | **No** | Archivo de compatibilidad legacy, regenerado (`Printcap` en `cups-files.conf`) |
| `/var/spool/cups/` | `cupsd` | **No** | Spool durable de jobs |
| `/var/log/cups/{error,access,page}_log` | `cupsd` | n/a | Diagnóstico, auditoría HTTP/IPP, contabilidad de páginas |
| `/usr/lib/cups/backend/`, `/usr/lib/cups/filter/` | paquete | n/a | Ejecutables; un backend debe pertenecer a `root` y no ser escribible por todos, o `cupsd` se niega a ejecutarlo |

> **Trampa de examen.** Las directivas que nombran un archivo, directorio, usuario o grupo van en `cups-files.conf`; todo lo demás va en `cupsd.conf`. Poner `ErrorLog` en `cupsd.conf` es un fallo duro de arranque, no una advertencia.

---

## 3. Comparaciones técnicas y compromisos

### 3.1 Backends de transporte

| Backend | URI de dispositivo | Protocolo de red | Canal de retorno del estado del job | Contabilidad | Cuándo es la respuesta correcta |
|---|---|---|---|---|---|
| `socket` | `socket://10.42.7.55:9100` | TCP crudo (AppSocket/JetDirect) | Ninguno — escribir y rezar | Conteo de páginas no disponible | Impresoras de etiquetas ZPL/EPL, latencia mínima, sin negociación |
| `ipp` / `ipps` | `ipp://host/ipp/print` | IPP sobre HTTP/1.1 (+TLS) | `job-state`, `printer-state-reasons` completos | Sí | **Por defecto para cualquier cosa fabricada después de ~2012** |
| `lpd` | `lpd://host/queue` | RFC 1179 | Mínimo | Pobre | Appliances legacy, servidores de impresión en firmware embebido |
| `usb` | `usb://HP/LaserJet%20M404dn?serial=VNC3K12345` | Clase USB printer | Depende del dispositivo | Parcial | Conectada físicamente; **bloquea la contenerización** |
| `dnssd` | `dnssd://Name._ipp._tcp.local/?uuid=…` | Resuelve a `ipp` | Completo | Sí | Escritorios en una LAN plana; **nunca** en una red ruteada / de pods |
| `beh` | `beh:/1/3/5/socket://10.42.7.55:9100` | Wrapper (cups-filters) | Hereda | Hereda | Wrapper de reintento/failover: *no deshabilitar, 3 intentos, con 5 s de separación* |
| `file` | `file:///var/spool/print-archive/out.prn` | Escritura local | n/a | n/a | Captura a disco para pruebas; requiere `FileDevice Yes` |

El compromiso en una línea: **`socket` te da velocidad y ceguera; `ipp` te da observabilidad y una superficie de TLS/auth.** Un depósito que debe alertar ante "impresora sin etiquetas" no puede usar `socket`, porque no hay canal de retorno desde el cual alertar — la consulta SNMP de insumos (`snmp://`) o IPP son la única fuente.

### 3.2 Modelos de driver

| Modelo | Cómo se crea la cola | ¿PPD en disco? | Acoplamiento al fabricante | Riesgo de ciclo de vida |
|---|---|---|---|---|
| **PPD clásico + filtros** | `lpadmin -m foomatic:…ppd` o `-P /path/file.ppd` | Sí | Alto — suele requerirse un filtro binario del fabricante | El soporte de PPD está deprecado en CUPS 2.x y **eliminado en CUPS 3.x** |
| **IPP Everywhere / driverless** | `lpadmin -m everywhere` | Generado al vuelo (2.x), ninguno en 3.x | Ninguno — la impresora anuncia sus propias capacidades | Requiere que el dispositivo sea alcanzable *al momento de crear la cola* |
| **Printer Applications** | Un servicio IPP (a menudo un snap/contenedor) que hace de frente a un dispositivo legacy | No | Aislado dentro de la aplicación | El reemplazo compatible hacia adelante de los filtros del fabricante |
| **Cola raw** (`-m raw`, sin filtros) | `lpadmin -v socket://… ` sin modelo | No | Ninguno | La aplicación debe emitir bytes listos para el dispositivo (ZPL, PCL, PostScript) |

Para el trabajo de SRE la fila importante es la última. La impresión de etiquetas es casi siempre una **cola raw**: la aplicación genera ZPL, y cualquier filtro en el camino es un riesgo de corrupción. Eso se expresa con `lp -o raw` o dándole a la cola ningún PPD en absoluto.

### 3.3 Opciones de arquitectura de spooling

| Opción | Durabilidad | Riesgo de salida duplicada | Observabilidad | Costo operativo |
|---|---|---|---|---|
| La app escribe directo a `socket://:9100` | Ninguna — bytes perdidos ante fallo TCP | Alto (el reintento a nivel app reenvía) | Lo que loguee la app | Lo más barato de construir, lo más caro de operar |
| `cupsd` local en cada nodo | Spool por nodo, sin vista compartida | Bajo por nodo, alto a nivel flota | `page_log` disperso entre nodos | Deriva de configuración en toda la flota |
| **`cupsd` central, clientes vía `client.conf`** | Un spool durable | Bajo | Un solo `page_log`, un solo `access_log` | Un servicio con estado que operar |
| `cupsd` central + cola de mensajes al frente | Durable en el broker | Bajo, con claves de idempotencia | Completa | El más alto; justificado solo para salida irreversible de alto valor |

La tercera fila es la respuesta estándar, y es lo que construyen los manifiestos de §4. También es el patrón que le importa al examen: los clientes llevan `/etc/cups/client.conf` con `ServerName`, no corren planificador local, y cada `lp`/`lpstat` apunta transparentemente al servidor central.

### 3.4 Linajes de comandos — System V vs BSD

Ambas familias vienen con CUPS y ambas son material de examen. No son alias; las letras de opción colisionan.

| Tarea | System V | BSD | Notas |
|---|---|---|---|
| Enviar un job | `lp -d queue file` | `lpr -P queue file` | `lp` imprime el ID del job en stdout; `lpr` es silencioso |
| Copias | `lp -n 3` | `lpr -# 3` | |
| Listar jobs encolados | `lpstat -o` | `lpq -P queue` | `lpq -a` = todas las colas |
| Cancelar un job | `cancel 412` | `lprm 412` | `lprm -` cancela los jobs del usuario invocante |
| Cancelar todo en una cola | `cancel -a queue` | — | `cancel -a -x queue` además purga el historial de jobs |
| Mostrar destinos | `lpstat -p -d` | — | `lpstat -t` = todo |
| Mostrar URIs de dispositivo | `lpstat -v` | — | |
| Retener / liberar | `lp -H hold` / `lp -H resume -i 412` | — | |
| Mover jobs | `lpmove 412 other` o `lpmove src dst` | — | Primitiva del procedimiento de drenaje |

Los comandos administrativos no tienen gemelo BSD: `lpadmin`, `lpinfo`, `lpoptions`, `cupsaccept` / `cupsreject`, `cupsenable` / `cupsdisable`, `cupsctl`.

> **La distinción que más se pasa por alto:** `cupsaccept`/`cupsreject` controlan si la cola **acepta jobs nuevos**; `cupsenable`/`cupsdisable` controlan si la cola **envía jobs al dispositivo**. Un drenaje de mantenimiento es `cupsreject` (cortar la entrada) seguido de esperar a que el spool se vacíe. Un cambio de dispositivo es `cupsdisable` (seguir aceptando, dejar de transmitir) para que no se pierda nada.

---

## 4. Infraestructura completa

### 4.1 `/etc/cups/cupsd.conf` — configuración de producción del planificador

```apache
# /etc/cups/cupsd.conf — central print server, CUPS 2.4.x
# Scheduler behaviour only. File/user/group directives live in cups-files.conf.

LogLevel warn
LogTimeFormat standard
PageLogFormat %p %u %j %T %P %C %{job-billing} %{job-originating-host-name} %{job-name} %{media} %{sides}
MaxLogSize 0                       # 0 = never self-rotate; logrotate owns this

# --- Lifetime -------------------------------------------------------------
# 0 disables the on-demand idle exit. A server started by systemd .socket
# activation would otherwise exit between jobs and lose in-memory subscriptions.
IdleExitTimeout 0

# --- Listeners ------------------------------------------------------------
Listen 0.0.0.0:631
Listen /run/cups/cups.sock
ServerName print.internal.example.com
ServerAlias print.internal.example.com
ServerAdmin sre@example.com
ServerTokens Minor                 # "CUPS/2.4 IPP/2.1" — no OS/patch disclosure

# --- Discovery ------------------------------------------------------------
# Advertise nothing: clients are configured explicitly via client.conf.
Browsing Off
BrowseLocalProtocols
DefaultShared No

# --- Transport security ---------------------------------------------------
DefaultEncryption Required
SSLOptions MinTLS1.2 DenyTLS1.0 DenyTLS1.1 DenyCBC
DefaultAuthType Basic

# --- Capacity and backpressure -------------------------------------------
MaxClients 200
MaxClientsPerHost 20
MaxJobs 2000                       # scheduler-wide ceiling; 0 = unlimited
MaxJobsPerPrinter 200
MaxJobsPerUser 100
MaxCopies 50
MaxHoldTime 0
Timeout 300
KeepAlive On

# --- Retry semantics ------------------------------------------------------
# Applies where a queue does not override printer-error-policy.
JobRetryInterval 30
JobRetryLimit 5
JobKillDelay 30
MaxJobTime 10800                   # 3 h ceiling on a single job

# --- Job history ----------------------------------------------------------
# Keep metadata for accounting, discard payloads immediately after printing.
PreserveJobHistory 7d
PreserveJobFiles No

WebInterface Yes

# --- Access control -------------------------------------------------------
<Location />
  Order allow,deny
  Allow from 10.42.0.0/16
</Location>

<Location /printers>
  Order allow,deny
  Allow from 10.42.0.0/16
</Location>

<Location /admin>
  AuthType Default
  Require user @SYSTEM
  Encryption Required
  Order allow,deny
  Allow from 10.42.1.0/24          # jump hosts only
</Location>

<Location /admin/conf>
  AuthType Default
  Require user @SYSTEM
  Encryption Required
  Order allow,deny
  Allow from 10.42.1.0/24
</Location>

<Location /admin/log>
  AuthType Default
  Require user @SYSTEM
  Order allow,deny
  Allow from 10.42.1.0/24
</Location>

# --- Policies -------------------------------------------------------------
<Policy default>
  JobPrivateAccess default
  JobPrivateValues default
  SubscriptionPrivateAccess default
  SubscriptionPrivateValues default

  <Limit Create-Job Print-Job Print-URI Validate-Job>
    Order deny,allow
  </Limit>

  <Limit Send-Document Send-URI Hold-Job Release-Job Restart-Job Purge-Jobs \
         Set-Job-Attributes Create-Job-Subscription Renew-Subscription \
         Cancel-Subscription Get-Notifications Reprocess-Job Cancel-Current-Job \
         Suspend-Current-Job Resume-Job Cancel-My-Jobs Close-Job CUPS-Move-Job \
         CUPS-Get-Document>
    Require user @OWNER @SYSTEM
    Order deny,allow
  </Limit>

  <Limit CUPS-Add-Modify-Printer CUPS-Delete-Printer CUPS-Add-Modify-Class \
         CUPS-Delete-Class CUPS-Set-Default CUPS-Get-Devices>
    AuthType Default
    Require user @SYSTEM
    Order deny,allow
  </Limit>

  <Limit Pause-Printer Resume-Printer Enable-Printer Disable-Printer \
         Pause-Printer-After-Current-Job Hold-New-Jobs Release-Held-New-Jobs \
         Deactivate-Printer Activate-Printer Restart-Printer Shutdown-Printer \
         Startup-Printer Promote-Job Schedule-Job-After Cancel-Jobs \
         CUPS-Accept-Jobs CUPS-Reject-Jobs>
    AuthType Default
    Require user @SYSTEM
    Order deny,allow
  </Limit>

  <Limit Cancel-Job CUPS-Authenticate-Job>
    Require user @OWNER @SYSTEM
    Order deny,allow
  </Limit>

  <Limit All>
    Order deny,allow
  </Limit>
</Policy>
```

### 4.2 `/etc/cups/cups-files.conf`

```apache
# /etc/cups/cups-files.conf — file, directory, user and group directives.
# Split from cupsd.conf since CUPS 1.6: a remote admin with /admin/conf access
# must not be able to redirect ErrorLog at a setuid target.

User lp
Group lp
SystemGroup lpadmin

# FatalErrors config: refuse to start on a bad config rather than degrade.
FatalErrors config
SyncOnClose Yes

ConfigFilePerm 0640
LogFilePerm 0640
LogFileGroup adm

AccessLog /var/log/cups/access_log
ErrorLog  /var/log/cups/error_log
PageLog   /var/log/cups/page_log

CacheDir     /var/cache/cups
DataDir      /usr/share/cups
DocumentRoot /usr/share/cups/doc-root
RequestRoot  /var/spool/cups
ServerBin    /usr/lib/cups
ServerRoot   /etc/cups
StateDir     /run/cups
TempDir      /var/spool/cups/tmp

# Legacy compatibility file, regenerated by cupsd. BSD format.
Printcap /etc/printcap
PrintcapFormat bsd

# file:// backend disabled: a queue pointing at /etc/shadow is a write primitive.
FileDevice No

# Remote root is mapped to an unprivileged account.
RemoteRoot remroot
```

### 4.3 Definiciones declarativas de colas

CUPS no tiene una capa declarativa nativa — `printers.conf` es *salida*, no entrada. La forma soportada de hacer las colas reproducibles es manejar `lpadmin`, que es idempotente para una cola existente.

```text
# /etc/cups/queues.decl
# name|device-uri|model|location|description
hp-lj-m404-floor2|ipp://10.42.7.31/ipp/print|everywhere|Floor 2 East|HP LaserJet M404dn
hp-lj-m404-floor3|ipp://10.42.7.32/ipp/print|everywhere|Floor 3 West|HP LaserJet M404dn
zebra-zt411-dock|socket://10.42.7.55:9100|raw|Dock A|Zebra ZT411 203dpi ZPL
zebra-zt411-pack|socket://10.42.7.56:9100|raw|Packing 1|Zebra ZT411 203dpi ZPL
```

```bash
#!/bin/sh
# /usr/local/bin/bootstrap-queues.sh
# Idempotent reconciliation of /etc/cups/queues.decl against the running
# scheduler. Safe to re-run: lpadmin -p on an existing queue modifies it.
set -eu

CUPS_HOST="${CUPS_HOST:-localhost:631}"
DECL="${DECL:-/etc/cups/queues.decl}"

# Wait for the scheduler to answer IPP before touching anything.
attempt=0
until lpstat -h "$CUPS_HOST" -r >/dev/null 2>&1; do
    attempt=$((attempt + 1))
    if [ "$attempt" -gt 60 ]; then
        echo "bootstrap-queues: scheduler did not become ready" >&2
        exit 1
    fi
    sleep 1
done

while IFS='|' read -r name uri model location description; do
    case "$name" in
        ''|\#*) continue ;;
    esac

    set -- -h "$CUPS_HOST" -p "$name" -E -v "$uri" \
           -L "$location" -D "$description" \
           -o printer-is-shared=false \
           -o printer-error-policy=retry-job

    case "$model" in
        raw) ;;                       # no filters: application emits device bytes
        *)   set -- "$@" -m "$model" ;;
    esac

    if lpadmin "$@"; then
        echo "bootstrap-queues: reconciled $name -> $uri"
    else
        echo "bootstrap-queues: FAILED to reconcile $name -> $uri" >&2
    fi
done < "$DECL"

# Label queues must never block the pipeline on a jam: abort and alert instead.
for q in zebra-zt411-dock zebra-zt411-pack; do
    lpadmin -h "$CUPS_HOST" -p "$q" -o printer-error-policy=abort-job || true
done

lpadmin -h "$CUPS_HOST" -d hp-lj-m404-floor2
```

### 4.4 Endurecimiento con systemd (despliegue bare-metal / VM)

```ini
# /etc/systemd/system/cups.service.d/10-hardening.conf
[Service]
NoNewPrivileges=no
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/etc/cups /var/spool/cups /var/log/cups /var/cache/cups /run/cups
PrivateTmp=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
RestrictNamespaces=yes
LockPersonality=yes
MemoryDenyWriteExecute=no
SystemCallArchitectures=native
CapabilityBoundingSet=CAP_CHOWN CAP_DAC_OVERRIDE CAP_FOWNER CAP_SETGID CAP_SETUID CAP_NET_BIND_SERVICE
Restart=on-failure
RestartSec=5s
```

> `NoNewPrivileges=no` es deliberado: `cupsd` arranca como root, y luego hace `setuid()` a `User lp` para ejecutar los filtros. Ponerlo en `yes` rompe la cadena de filtros en algunas distribuciones. Todo lo demás está ajustado alrededor de ese único requisito.

Los clientes RFC 1179 legacy (appliances viejos, escáneres embebidos) necesitan el shim LPD, activado por socket para que no consuma nada mientras está ocioso:

```ini
# /etc/systemd/system/cups-lpd.socket
[Unit]
Description=CUPS LPD Protocol Compatibility Socket

[Socket]
ListenStream=515
Accept=yes
MaxConnections=64

[Install]
WantedBy=sockets.target
```

```ini
# /etc/systemd/system/cups-lpd@.service
[Unit]
Description=CUPS LPD Protocol Compatibility Server
After=cups.service
Requires=cups.service

[Service]
ExecStart=/usr/lib/cups/daemon/cups-lpd -o document-format=application/octet-stream
StandardInput=socket
StandardError=journal
```

`-o document-format=application/octet-stream` fuerza el paso crudo. Sin eso, `cups-lpd` deja que CUPS autodetecte el tipo del stream, y una carga ZPL que casualmente empieza con ASCII imprimible pasa por `texttopdf` y queda destruida.

### 4.5 Kubernetes: servidor de impresión central

Las restricciones honestas, enunciadas antes de los manifiestos:

- **`replicas: 1`, `strategy: Recreate`.** Dos planificadores compartiendo un dispositivo físico duplican la salida. No hay elección de líder en CUPS.
- **Las impresoras USB quedan fuera de alcance en un pod.** Alcanzar `usb://` requiere montajes de host de `/dev/bus/usb` y fijación a nodo; si tenés dispositivos USB, corré `cupsd` en ese nodo como unidad systemd (§4.4) y dejá al clúster fuera de esto.
- **mDNS no cruza la red de pods.** Cada cola usa una URI `ipp://` o `socket://` explícita. `Browsing Off` en §4.1 refleja esto.
- **`/etc/cups` debe ser escribible y durable** porque `cupsd` reescribe `printers.conf`. Un ConfigMap no puede montarse ahí directamente; un init container siembra archivos propiedad del admin dentro del PVC.

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: printing
  labels:
    pod-security.kubernetes.io/enforce: baseline
    pod-security.kubernetes.io/audit: baseline
    pod-security.kubernetes.io/warn: baseline
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: cups
  namespace: printing
automountServiceAccountToken: false
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: cups-config
  namespace: printing
data:
  cupsd.conf: |
    LogLevel warn
    LogTimeFormat standard
    PageLogFormat %p %u %j %T %P %C %{job-billing} %{job-originating-host-name} %{job-name} %{media} %{sides}
    MaxLogSize 0
    IdleExitTimeout 0

    Listen 0.0.0.0:631
    ServerName print.internal.example.com
    ServerAlias *
    ServerAdmin sre@example.com
    ServerTokens Minor

    Browsing Off
    BrowseLocalProtocols
    DefaultShared No

    DefaultEncryption IfRequested
    DefaultAuthType Basic

    MaxClients 200
    MaxClientsPerHost 20
    MaxJobs 2000
    MaxJobsPerPrinter 200
    MaxJobsPerUser 100
    MaxCopies 50
    Timeout 300
    KeepAlive On

    JobRetryInterval 30
    JobRetryLimit 5
    JobKillDelay 30
    MaxJobTime 10800

    PreserveJobHistory 7d
    PreserveJobFiles No

    WebInterface Yes

    <Location />
      Order allow,deny
      Allow from all
    </Location>

    <Location /printers>
      Order allow,deny
      Allow from all
    </Location>

    <Location /admin>
      AuthType Default
      Require user @SYSTEM
      Order allow,deny
      Allow from all
    </Location>

    <Location /admin/conf>
      AuthType Default
      Require user @SYSTEM
      Order allow,deny
      Allow from all
    </Location>

    <Policy default>
      JobPrivateAccess default
      JobPrivateValues default
      SubscriptionPrivateAccess default
      SubscriptionPrivateValues default

      <Limit Create-Job Print-Job Print-URI Validate-Job>
        Order deny,allow
      </Limit>

      <Limit Send-Document Send-URI Hold-Job Release-Job Restart-Job Purge-Jobs \
             Set-Job-Attributes Create-Job-Subscription Renew-Subscription \
             Cancel-Subscription Get-Notifications Reprocess-Job \
             Cancel-Current-Job Suspend-Current-Job Resume-Job Cancel-My-Jobs \
             Close-Job CUPS-Move-Job CUPS-Get-Document>
        Require user @OWNER @SYSTEM
        Order deny,allow
      </Limit>

      <Limit CUPS-Add-Modify-Printer CUPS-Delete-Printer CUPS-Add-Modify-Class \
             CUPS-Delete-Class CUPS-Set-Default CUPS-Get-Devices>
        AuthType Default
        Require user @SYSTEM
        Order deny,allow
      </Limit>

      <Limit Pause-Printer Resume-Printer Enable-Printer Disable-Printer \
             Pause-Printer-After-Current-Job Hold-New-Jobs Release-Held-New-Jobs \
             Deactivate-Printer Activate-Printer Restart-Printer \
             Shutdown-Printer Startup-Printer Promote-Job Schedule-Job-After \
             Cancel-Jobs CUPS-Accept-Jobs CUPS-Reject-Jobs>
        AuthType Default
        Require user @SYSTEM
        Order deny,allow
      </Limit>

      <Limit Cancel-Job CUPS-Authenticate-Job>
        Require user @OWNER @SYSTEM
        Order deny,allow
      </Limit>

      <Limit All>
        Order deny,allow
      </Limit>
    </Policy>
  cups-files.conf: |
    User lp
    Group lp
    SystemGroup lpadmin
    FatalErrors config
    SyncOnClose Yes
    ConfigFilePerm 0640
    LogFilePerm 0640
    AccessLog /var/log/cups/access_log
    ErrorLog  /var/log/cups/error_log
    PageLog   /var/log/cups/page_log
    CacheDir     /var/cache/cups
    DataDir      /usr/share/cups
    DocumentRoot /usr/share/cups/doc-root
    RequestRoot  /var/spool/cups
    ServerBin    /usr/lib/cups
    ServerRoot   /etc/cups
    StateDir     /run/cups
    TempDir      /var/spool/cups/tmp
    Printcap /etc/printcap
    PrintcapFormat bsd
    FileDevice No
  queues.decl: |
    hp-lj-m404-floor2|ipp://10.42.7.31/ipp/print|everywhere|Floor 2 East|HP LaserJet M404dn
    hp-lj-m404-floor3|ipp://10.42.7.32/ipp/print|everywhere|Floor 3 West|HP LaserJet M404dn
    zebra-zt411-dock|socket://10.42.7.55:9100|raw|Dock A|Zebra ZT411 203dpi ZPL
    zebra-zt411-pack|socket://10.42.7.56:9100|raw|Packing 1|Zebra ZT411 203dpi ZPL
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: cups-scripts
  namespace: printing
data:
  seed-config.sh: |
    #!/bin/sh
    # Init container: seed admin-managed files into the durable ServerRoot.
    # cupsd rewrites printers.conf/classes.conf in this same directory, so the
    # directory itself must be a PVC and cannot be a ConfigMap mount.
    set -eu
    install -d -m 0755 -o root -g lp /etc/cups
    install -d -m 0755 -o root -g lp /etc/cups/ppd
    install -m 0640 -o root -g lp /config/cupsd.conf       /etc/cups/cupsd.conf
    install -m 0640 -o root -g lp /config/cups-files.conf  /etc/cups/cups-files.conf
    install -m 0644 -o root -g lp /config/queues.decl      /etc/cups/queues.decl
    install -d -m 0710 -o root -g lp /var/spool/cups
    install -d -m 1770 -o root -g lp /var/spool/cups/tmp
    install -d -m 0755 -o root -g lp /var/log/cups
    install -d -m 0775 -o root -g lp /var/cache/cups
    # Fail the pod here, not three restarts later, if the config is invalid.
    /usr/sbin/cupsd -t -c /etc/cups/cupsd.conf -s /etc/cups/cups-files.conf
    echo "seed-config: configuration validated"
  entrypoint.sh: |
    #!/bin/sh
    set -eu
    /usr/local/bin/bootstrap-queues.sh &
    exec /usr/sbin/cupsd -f -c /etc/cups/cupsd.conf -s /etc/cups/cups-files.conf
  bootstrap-queues.sh: |
    #!/bin/sh
    set -eu
    CUPS_HOST="${CUPS_HOST:-localhost:631}"
    DECL="${DECL:-/etc/cups/queues.decl}"
    attempt=0
    until lpstat -h "$CUPS_HOST" -r >/dev/null 2>&1; do
        attempt=$((attempt + 1))
        if [ "$attempt" -gt 60 ]; then
            echo "bootstrap-queues: scheduler did not become ready" >&2
            exit 1
        fi
        sleep 1
    done
    while IFS='|' read -r name uri model location description; do
        case "$name" in
            ''|\#*) continue ;;
        esac
        set -- -h "$CUPS_HOST" -p "$name" -E -v "$uri" \
               -L "$location" -D "$description" \
               -o printer-is-shared=false \
               -o printer-error-policy=retry-job
        case "$model" in
            raw) ;;
            *)   set -- "$@" -m "$model" ;;
        esac
        if lpadmin "$@"; then
            echo "bootstrap-queues: reconciled $name -> $uri"
        else
            echo "bootstrap-queues: FAILED to reconcile $name -> $uri" >&2
        fi
    done < "$DECL"
    for q in zebra-zt411-dock zebra-zt411-pack; do
        lpadmin -h "$CUPS_HOST" -p "$q" -o printer-error-policy=abort-job || true
    done
    lpadmin -h "$CUPS_HOST" -d hp-lj-m404-floor2
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: cups-serverroot
  namespace: printing
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: local-path
  resources:
    requests:
      storage: 512Mi
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: cups-spool
  namespace: printing
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: local-path
  resources:
    requests:
      storage: 20Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cups
  namespace: printing
  labels:
    app.kubernetes.io/name: cups
spec:
  # Exactly one scheduler. Two replicas printing to one device duplicate output;
  # CUPS has no leader election and no shared-spool coordination.
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app.kubernetes.io/name: cups
  template:
    metadata:
      labels:
        app.kubernetes.io/name: cups
    spec:
      serviceAccountName: cups
      terminationGracePeriodSeconds: 120
      securityContext:
        seccompProfile:
          type: RuntimeDefault
      initContainers:
        - name: seed-config
          image: ghcr.io/example/cups:2.4.7-r3
          command: ["/bin/sh", "/scripts/seed-config.sh"]
          securityContext:
            runAsUser: 0
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
              add: ["CHOWN", "DAC_OVERRIDE", "FOWNER"]
          volumeMounts:
            - { name: config,      mountPath: /config,          readOnly: true }
            - { name: scripts,     mountPath: /scripts,         readOnly: true }
            - { name: serverroot,  mountPath: /etc/cups }
            - { name: spool,       mountPath: /var/spool/cups }
            - { name: logs,        mountPath: /var/log/cups }
            - { name: cache,       mountPath: /var/cache/cups }
      containers:
        - name: cupsd
          image: ghcr.io/example/cups:2.4.7-r3
          command: ["/bin/sh", "/scripts/entrypoint.sh"]
          ports:
            - { name: ipp, containerPort: 631, protocol: TCP }
          env:
            - { name: CUPS_HOST, value: "localhost:631" }
          securityContext:
            # cupsd starts as root and setuid()s to `lp` to exec filters.
            # allowPrivilegeEscalation=false sets no_new_privs, which blocks
            # setuid *binaries* but not a root process calling setuid().
            runAsUser: 0
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
              add: ["CHOWN", "DAC_OVERRIDE", "FOWNER", "SETGID", "SETUID"]
          resources:
            requests: { cpu: "100m", memory: "128Mi" }
            limits:   { cpu: "2",    memory: "1Gi" }
          startupProbe:
            exec:
              command: ["lpstat", "-h", "localhost:631", "-r"]
            periodSeconds: 3
            failureThreshold: 20
          livenessProbe:
            exec:
              command: ["lpstat", "-h", "localhost:631", "-r"]
            periodSeconds: 30
            timeoutSeconds: 10
            failureThreshold: 3
          readinessProbe:
            exec:
              command: ["lpstat", "-h", "localhost:631", "-r"]
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 2
          lifecycle:
            preStop:
              exec:
                # Stop intake, then let terminationGracePeriodSeconds drain the
                # in-flight job rather than truncating it mid-page.
                command:
                  - /bin/sh
                  - -c
                  - "cupsreject -h localhost:631 -r 'shutting down' $(lpstat -h localhost:631 -a | awk '{print $1}') || true; sleep 15"
          volumeMounts:
            - { name: scripts,    mountPath: /scripts,        readOnly: true }
            - { name: serverroot, mountPath: /etc/cups }
            - { name: spool,      mountPath: /var/spool/cups }
            - { name: logs,       mountPath: /var/log/cups }
            - { name: cache,      mountPath: /var/cache/cups }
            - { name: run,        mountPath: /run/cups }
            - { name: tmp,        mountPath: /tmp }
      volumes:
        - name: config
          configMap: { name: cups-config }
        - name: scripts
          configMap: { name: cups-scripts, defaultMode: 0555 }
        - name: serverroot
          persistentVolumeClaim: { claimName: cups-serverroot }
        - name: spool
          persistentVolumeClaim: { claimName: cups-spool }
        - name: logs
          emptyDir: {}
        - name: cache
          emptyDir: {}
        - name: run
          emptyDir: {}
        - name: tmp
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: cups
  namespace: printing
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: cups
  ports:
    - { name: ipp, port: 631, targetPort: ipp, protocol: TCP }
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: cups
  namespace: printing
spec:
  maxUnavailable: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: cups
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: cups
  namespace: printing
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: cups
  policyTypes: ["Ingress", "Egress"]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels: { kubernetes.io/metadata.name: fulfilment }
        - namespaceSelector:
            matchLabels: { kubernetes.io/metadata.name: reporting }
      ports:
        - { protocol: TCP, port: 631 }
  egress:
    # DNS
    - to:
        - namespaceSelector:
            matchLabels: { kubernetes.io/metadata.name: kube-system }
      ports:
        - { protocol: UDP, port: 53 }
        - { protocol: TCP, port: 53 }
    # Printer VLAN only: IPP (631), AppSocket (9100), LPD (515), SNMP (161).
    - to:
        - ipBlock: { cidr: 10.42.7.0/24 }
      ports:
        - { protocol: TCP, port: 631 }
        - { protocol: TCP, port: 9100 }
        - { protocol: TCP, port: 515 }
        - { protocol: UDP, port: 161 }
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: cups-page-accounting
  namespace: printing
spec:
  schedule: "5 * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 2
      template:
        spec:
          restartPolicy: OnFailure
          containers:
            - name: accounting
              image: ghcr.io/example/cups:2.4.7-r3
              command:
                - /bin/sh
                - -c
                - |
                  set -eu
                  # page_log fields:
                  #   printer user job-id timestamp page-number copies
                  #   billing hostname job-name media sides
                  awk '{ pages[$1] += $6 } END { for (p in pages)
                        printf "cups_pages_printed_total{printer=\"%s\"} %d\n", p, pages[p] }' \
                      /var/log/cups/page_log
              volumeMounts:
                - { name: logs, mountPath: /var/log/cups, readOnly: true }
          volumes:
            - name: logs
              emptyDir: {}
```

> El CronJob tal como está escrito monta su propio `emptyDir` y por lo tanto no lee nada — es la forma, no una exportación funcional, porque un pod de `CronJob` no puede montar el `emptyDir` del Deployment. En un despliegue real, o bien hacé de `logs` un segundo PVC RWX, o reemplazá el CronJob por un sidecar en el mismo pod. Se dice explícitamente en vez de dejarlo como un bug silencioso.

### 4.6 Configuración del lado cliente

Los clientes no corren **ningún planificador local**. Esta es la pieza que la mayoría de los despliegues hace mal instalando `cups` en todos lados.

```apache
# /etc/cups/client.conf on every client host
ServerName print.internal.example.com:631
Encryption IfRequested
```

Override por invocación, útil en contenedores de CI y para depurar:

```bash
export CUPS_SERVER=print.internal.example.com:631
lpstat -t
```

Los valores por defecto por usuario van en `~/.cups/lpoptions`, los de sistema en `/etc/cups/lpoptions`:

```bash
lpoptions -d hp-lj-m404-floor2
lpoptions -p hp-lj-m404-floor2 -o sides=two-sided-long-edge -o media=A4
```

---

## 5. Sesiones de CLI con salida real

### 5.1 Descubrir con qué puede hablar el host

```console
$ lpinfo -v
network beh
network socket
network ipps
network lpd
network ipp
network https
network http
network snmp
direct usb://HP/LaserJet%20M404dn?serial=VNC3K12345
network dnssd://HP%20LaserJet%20M404dn%20%5B0123AB%5D._ipp._tcp.local/?uuid=1c8ac5a1-3f5e-4d2b-91aa-0f2b8c93d001
network socket://10.42.7.55:9100
```

`lpinfo -v` lista *dispositivos y esquemas disponibles*; `lpinfo -m` lista *drivers/modelos disponibles*:

```console
$ lpinfo -m | head -5
everywhere IPP Everywhere™
raw Raw Queue
drv:///sample.drv/generic.ppd Generic PostScript Printer
drv:///sample.drv/generpcl.ppd Generic PCL Laser Printer
gutenprint.5.3://escp2-p50/expert Epson Stylus Photo 750 - CUPS+Gutenprint v5.3.4
```

Sondeo driverless antes de comprometerte con una definición de cola:

```console
$ ippfind --timeout 3
ipp://HP0123AB.local:631/ipp/print

$ driverless list
"driverless:ipp://HP0123AB.local:631/ipp/print" en "HP" "HP LaserJet M404dn, driverless, cups-filters 1.28.17" "MFG:HP;MDL:LaserJet M404dn;CMD:PDF,PWGRaster,PCLm;"
```

### 5.2 Crear e inspeccionar colas

```console
$ sudo lpadmin -p hp-lj-m404-floor2 -E \
    -v ipp://10.42.7.31/ipp/print \
    -m everywhere \
    -L "Floor 2 East" \
    -D "HP LaserJet M404dn" \
    -o printer-error-policy=retry-job \
    -o printer-is-shared=false

$ sudo lpadmin -p zebra-zt411-dock -E \
    -v socket://10.42.7.55:9100 \
    -L "Dock A" \
    -D "Zebra ZT411 203dpi ZPL" \
    -o printer-error-policy=abort-job

$ sudo lpadmin -d hp-lj-m404-floor2

$ lpstat -t
scheduler is running
system default destination: hp-lj-m404-floor2
device for hp-lj-m404-floor2: ipp://10.42.7.31/ipp/print
device for hp-lj-m404-floor3: ipp://10.42.7.32/ipp/print
device for zebra-zt411-dock: socket://10.42.7.55:9100
hp-lj-m404-floor2 accepting requests since Thu 27 Aug 2026 09:12:03 AM -03
hp-lj-m404-floor3 accepting requests since Thu 27 Aug 2026 09:12:03 AM -03
zebra-zt411-dock accepting requests since Thu 27 Aug 2026 09:12:04 AM -03
printer hp-lj-m404-floor2 is idle.  enabled since Thu 27 Aug 2026 09:12:03 AM -03
printer hp-lj-m404-floor3 is idle.  enabled since Thu 27 Aug 2026 09:12:03 AM -03
printer zebra-zt411-dock is idle.  enabled since Thu 27 Aug 2026 09:12:04 AM -03
```

Notá los dos ejes independientes que se reportan por separado: *accepting requests* (entrada) y *enabled/idle* (transmisión).

Opciones que la cola realmente soporta:

```console
$ lpoptions -p hp-lj-m404-floor2 -l
PageSize/Media Size: *A4 Letter Legal Executive A5 Custom.WIDTHxHEIGHT
InputSlot/Media Source: *Auto Tray1 Tray2 Manual
Duplex/2-Sided Printing: DuplexNoTumble DuplexTumble *None
ColorModel/Print Color Mode: *Gray
Resolution/Resolution: 300dpi *600dpi 1200dpi
print-quality/Print Quality: 3 *4 5
```

### 5.3 Enviar, observar y manipular jobs

```console
$ lp -d hp-lj-m404-floor2 -n 2 -o media=A4 -o sides=two-sided-long-edge \
     -o job-billing=CC-4471 quarterly-report.pdf
request id is hp-lj-m404-floor2-412 (1 file(s))

$ lpr -P zebra-zt411-dock -o raw label-88213.zpl

$ lpstat -o
hp-lj-m404-floor2-412   sre            30720   Thu 27 Aug 2026 11:02:41 AM -03
zebra-zt411-dock-413    fulfilment      1024   Thu 27 Aug 2026 11:02:44 AM -03

$ lpq -P hp-lj-m404-floor2
hp-lj-m404-floor2 is ready and printing
Rank    Owner   Job     File(s)                         Total Size
active  sre     412     quarterly-report.pdf            30720 bytes

$ lpstat -W completed -o hp-lj-m404-floor2
hp-lj-m404-floor2-410   ops            12288   Thu 27 Aug 2026 10:41:02 AM -03
hp-lj-m404-floor2-411   ops             8192   Thu 27 Aug 2026 10:44:17 AM -03
```

Retener, liberar, mover y cancelar:

```console
$ lp -i 412 -H hold
$ lpstat -o
hp-lj-m404-floor2-412   sre            30720   Thu 27 Aug 2026 11:02:41 AM -03

$ lp -i 412 -H resume

$ sudo lpmove 412 hp-lj-m404-floor3

$ cancel 413
$ lprm -                       # cancel all jobs owned by the invoking user
$ sudo cancel -a hp-lj-m404-floor3
$ sudo cancel -a -x hp-lj-m404-floor3   # also purge the job history
```

### 5.4 Mantenimiento: drenar vs. aislar

```console
# Drain for a firmware upgrade: stop intake, let the spool empty.
$ sudo cupsreject -r "firmware upgrade window 11:30-12:00" hp-lj-m404-floor2
$ lpstat -a hp-lj-m404-floor2
hp-lj-m404-floor2 not accepting requests since Thu 27 Aug 2026 11:26:10 AM -03 -
	firmware upgrade window 11:30-12:00

# Device swap: keep accepting, stop transmitting. Nothing is lost.
$ sudo cupsdisable -r "swapping fuser unit" hp-lj-m404-floor3
$ lpstat -p hp-lj-m404-floor3
printer hp-lj-m404-floor3 disabled since Thu 27 Aug 2026 11:27:44 AM -03 -
	swapping fuser unit

# Restore both axes.
$ sudo cupsaccept hp-lj-m404-floor2
$ sudo cupsenable hp-lj-m404-floor3
```

### 5.5 Perillas a nivel del planificador

```console
$ cupsctl
_debug_logging=0
_remote_admin=0
_remote_any=0
_share_printers=0
_user_cancel_any=0
BrowseLocalProtocols=
DefaultAuthType=Basic
JobPrivateAccess=default
JobPrivateValues=default
MaxLogSize=0
PreserveJobHistory=7d
SubscriptionPrivateAccess=default
SubscriptionPrivateValues=default
WebInterface=Yes

$ sudo cupsctl --debug-logging
$ sudo cupsctl --no-debug-logging
$ sudo cupsctl --remote-admin --remote-any     # do not do this on a print server
```

### 5.6 Contabilidad

```console
$ sudo tail -3 /var/log/cups/page_log
hp-lj-m404-floor2 sre 412 [27/Aug/2026:11:02:47 -0300] 1 2 CC-4471 10.42.9.14 quarterly-report.pdf A4 two-sided-long-edge
hp-lj-m404-floor2 sre 412 [27/Aug/2026:11:02:49 -0300] 2 2 CC-4471 10.42.9.14 quarterly-report.pdf A4 two-sided-long-edge
zebra-zt411-dock fulfilment 413 [27/Aug/2026:11:02:51 -0300] 1 1 - 10.42.9.31 label-88213.zpl - -

$ awk '{ p[$1] += $6 } END { for (q in p) printf "%-24s %8d pages\n", q, p[q] }' \
      /var/log/cups/page_log | sort
hp-lj-m404-floor2            41822 pages
hp-lj-m404-floor3            18104 pages
zebra-zt411-dock            203551 pages
```

Cuotas aplicadas, por cola:

```console
$ sudo lpadmin -p hp-lj-m404-floor2 \
    -o job-quota-period=604800 \
    -o job-page-limit=500 \
    -o job-k-limit=51200

$ lpstat -p hp-lj-m404-floor2 --long | grep -i quota
	Quotas: page-limit=500 k-limit=51200 period=604800
```

`job-quota-period` es una ventana deslizante en segundos; `job-page-limit` y `job-k-limit` son los techos *por usuario* dentro de esa ventana. Este es el único límite de tasa nativo que te da CUPS, y es la defensa más barata contra un bucle descontrolado volcando 40 000 páginas de un día para el otro.

---

## 6. Verificación y diagnóstico de fallos

### 6.1 Escalera de verificación, de lo más barato a lo más caro

| Peldaño | Comando | Qué prueba |
|---|---|---|
| 0 | `sudo /usr/sbin/cupsd -t` (`echo $?`) | Que la configuración parsea. Nada más. |
| 1 | `systemctl is-active cups && lpstat -r` | Que el planificador corre y responde IPP |
| 2 | `lpstat -t` | Que las colas existen, con las URIs previstas, y sus dos ejes de estado |
| 3 | `nc -vz 10.42.7.55 9100` / `ippfind` | Que el dispositivo es alcanzable en L4 desde *este* host |
| 4 | `ipptool -tv ipp://…/ipp/print get-printer-attributes.test` | Que el dispositivo responde IPP y reporta su estado real |
| 5 | `lp -d q /usr/share/cups/data/testprint` | Que toda la cadena — filtros, backend, dispositivo — funciona de punta a punta |
| 6 | `grep <job-id> /var/log/cups/page_log` | Que el papel realmente se movió, y cuántas hojas |

Los peldaños 0–4 son gratuitos y no destructivos. El peldaño 5 consume papel físico; hacelo una vez, deliberadamente.

```console
$ sudo /usr/sbin/cupsd -t
$ echo $?
0

$ sudo /usr/sbin/cupsd -t
/etc/cups/cupsd.conf:34: Unknown directive "Lisen" on line 34 of /etc/cups/cupsd.conf.
$ echo $?
1
```

```console
$ ipptool -tv ipp://10.42.7.31/ipp/print get-printer-attributes.test
"/usr/share/cups/ipptool/get-printer-attributes.test":
    Get printer attributes using get-printer-attributes               [PASS]
        RECEIVED: 4924 bytes in response
        status-code = successful-ok (successful-ok)
        printer-state (enum) = idle
        printer-state-reasons (keyword) = none
        printer-is-accepting-jobs (boolean) = true
        printer-uri-supported (uri) = ipps://10.42.7.31:443/ipp/print,ipp://10.42.7.31:631/ipp/print
        document-format-supported (mimeMediaType) = application/pdf,image/pwg-raster,application/octet-stream
        marker-levels (integer) = 34
        marker-names (name) = Black Cartridge HP CF259A
```

`marker-levels 34` es tu SLI de tóner. Scrapealo; no esperes a un ticket de usuario.

### 6.2 Vocabulario de estados

**`printer-state`:** `3` = idle, `4` = processing, `5` = stopped.
**`job-state`:** `3` pending, `4` held, `5` processing, `6` stopped, `7` canceled, `8` aborted, `9` completed.

`printer-state-reasons` comunes y qué significan operativamente:

| Razón | Significado | Primera acción |
|---|---|---|
| `none` | Sano | — |
| `media-empty-warning` / `media-empty-error` | Bandeja vacía | Cargar papel; la cola se recupera sola bajo `retry-job` |
| `media-jam-error` | Atasco físico | Despejar; `cupsenable` si la política de error detuvo la cola |
| `toner-low-warning` / `toner-empty-error` | Insumo | Reemplazar; umbral de alerta en `marker-levels < 15` |
| `cups-waiting-for-job-completed` | El backend terminó, el dispositivo no confirmó | Normalmente benigno en `socket`; si persiste, `-o cups-waiting-for-job-completed=false` |
| `connecting-to-device` (persistente) | El backend no puede abrir el transporte | Problema de L3/L4 — ir a §6.4 |
| `paused` | Se ejecutó `cupsdisable` | `cupsenable`; averiguar quién la pausó y por qué |

### 6.3 Leer `error_log`

La severidad es el primer carácter de cada línea: `A` alert, `C` critical, `E` error, `W` warning, `N` notice, `I` info, `D` debug, `d` debug2.

```console
$ sudo tail -n 6 /var/log/cups/error_log
W [27/Aug/2026:10:41:25 -0300] [Job 411] The printer is not responding.
E [27/Aug/2026:10:41:55 -0300] [Job 411] Unable to connect to 10.42.7.55:9100: Connection timed out
I [27/Aug/2026:10:42:25 -0300] [Job 411] Retrying job in 30 seconds...
E [27/Aug/2026:10:44:31 -0300] [Job 411] Job stopped due to backend errors; please consult the error_log file for details.
E [27/Aug/2026:10:44:31 -0300] [Job 411] Stopping printer because it is not responding.
I [27/Aug/2026:10:44:31 -0300] Printer "zebra-zt411-dock" stopped.
```

Activar el logging de depuración para una sola reproducción, y luego apagarlo — el logging de depuración es lo bastante verboso como para llenar un volumen:

```console
$ sudo cupsctl --debug-logging
$ lp -d zebra-zt411-dock label-88213.zpl
request id is zebra-zt411-dock-414 (1 file(s))
$ sudo grep -F '[Job 414]' /var/log/cups/error_log | head -8
D [27/Aug/2026:11:14:02 -0300] [Job 414] Adding start banner page "none".
D [27/Aug/2026:11:14:02 -0300] [Job 414] Auto-typing file...
D [27/Aug/2026:11:14:02 -0300] [Job 414] Request file type is application/octet-stream.
D [27/Aug/2026:11:14:02 -0300] [Job 414] Started backend /usr/lib/cups/backend/socket (PID 3312)
D [27/Aug/2026:11:14:02 -0300] [Job 414] backendRunLoop(print_fd=8, device_fd=9, snmp_fd=-1, ...)
D [27/Aug/2026:11:14:02 -0300] [Job 414] Connecting to 10.42.7.55:9100
D [27/Aug/2026:11:14:03 -0300] [Job 414] Connected to 10.42.7.55:9100 (IPv4)
D [27/Aug/2026:11:14:03 -0300] [Job 414] Sent 1024 bytes...
$ sudo cupsctl --no-debug-logging
```

### 6.4 Taxonomía de fallos

| Síntoma | Causa más probable | Chequeo confirmatorio | Solución |
|---|---|---|---|
| `lpstat: Bad file descriptor` / `No destinations added` | El planificador no corre, o `client.conf`/`CUPS_SERVER` apunta al host equivocado | `systemctl is-active cups`; `lpstat -h host -r` | Arrancar `cups`; corregir `ServerName` |
| Cola `disabled since …` con `not responding` | Salida 1/4 del backend más `printer-error-policy=stop-printer` | grep del id del job en `error_log` | Arreglar el transporte, luego `cupsenable` |
| Los jobs se acumulan en `pending`, la impresora ociosa | La cola está *disabled* pero sigue *accepting* | `lpstat -p` vs `lpstat -a` | `cupsenable <queue>` |
| `lp` devuelve "not accepting requests" | Se ejecutó `cupsreject` (a menudo por un hook `preStop` que nunca se revirtió) | `lpstat -a` muestra la cadena de motivo | `cupsaccept <queue>` |
| El job pasa a `completed`, no imprime nada | Datos crudos enviados a una cola con filtros, o lenguaje de descripción de página equivocado | `page_log` muestra páginas; el dispositivo no muestra nada | Usar `-o raw` / una cola raw para ZPL/PCL |
| La impresora de etiquetas emite páginas de ASCII basura | CUPS autodetectó ZPL como texto y ejecutó `texttopdf` | `error_log`: `Request file type is text/plain` | Cola raw, o `cups-lpd -o document-format=application/octet-stream` |
| `Unable to connect … Connection timed out` | L3/L4: VLAN, egress de NetworkPolicy, impresora dormida | `nc -vz host 9100`; `ip route get <host>` | Camino de red; agregar el CIDR a la regla de egress |
| `Unable to connect … Connection refused` | Host correcto, puerto/protocolo equivocado (`socket` contra un dispositivo solo-IPP) | `nmap -p 515,631,9100 <host>` | Corregir el esquema de la URI de dispositivo |
| La creación de cola con `-m everywhere` falla | Dispositivo inalcanzable *al momento de crearla*, o no es IPP Everywhere | `driverless list`; `ipptool …` | Hacerlo alcanzable primero, o usar un PPD explícito |
| `cupsd` se niega a arrancar tras una edición | Una directiva de archivo/directorio/usuario puesta en `cupsd.conf` en vez de `cups-files.conf` | `cupsd -t`; `journalctl -u cups -n 30` | Mover la directiva |
| `cupsd` arranca, pero cada job muere al instante | Filtro o backend que no pertenece a `root` o es escribible por todos | `ls -l /usr/lib/cups/backend/socket` | `chown root:root`, `chmod 0700`/`0755` |
| Todo correcto, los jobs igual fallan, sin log evidente | Denegación de política MAC | `ausearch -m avc -c cupsd -ts recent`; `journalctl -k \| grep -i apparmor` | Ajustar el booleano de SELinux / el perfil de AppArmor |

### 6.5 Aislar la cadena de filtros

Cuando un job falla *antes* del backend, ejecutá el filtro a mano. Los filtros toman un argv fijo (`job-id user title copies options [file]`) y leen stdin si no se les da archivo:

```console
$ /usr/lib/cups/filter/pdftopdf 414 sre "manual test" 1 "" quarterly-report.pdf > /tmp/out.pdf
DEBUG: pdftopdf: Page 1 of 12
$ echo $?
0

$ /usr/lib/cups/filter/gstoraster 414 sre "manual test" 1 "" /tmp/out.pdf > /tmp/out.ras
ERROR: Unable to open PPD file: /etc/cups/ppd/hp-lj-m404-floor2.ppd
$ echo $?
1
```

Esa secuencia de dos comandos te dice exactamente qué eslabón se rompió, sin consumir papel y sin releer un log de depuración. Definí `PPD=` en el entorno cuando un filtro lo necesite:

```console
$ PPD=/etc/cups/ppd/hp-lj-m404-floor2.ppd \
    /usr/lib/cups/filter/gstoraster 414 sre "manual test" 1 "" /tmp/out.pdf > /tmp/out.ras
$ ls -l /tmp/out.ras
-rw-r--r--. 1 sre sre 8421376 Aug 27 11:22 /tmp/out.ras
```

Y para probar un backend en aislamiento, salteando por completo el planificador:

```console
$ DEVICE_URI=socket://10.42.7.55:9100 \
    /usr/lib/cups/backend/socket 414 sre "manual test" 1 "" label-88213.zpl
INFO: Connecting to 10.42.7.55:9100
INFO: Connected to 10.42.7.55:9100...
INFO: Sending print file, 1024 bytes...
INFO: Print file sent.
$ echo $?
0
```

### 6.6 Exportar la salud de las colas como métricas

```bash
#!/usr/bin/env bash
# /usr/local/bin/cups-textfile-collector.sh
# node_exporter textfile collector. Run from a systemd timer, every 30 s.
# Written against `lpstat` for portability; where the device speaks IPP,
# prefer ipptool + Get-Printer-Attributes, which is a stable contract
# rather than localised prose.
set -euo pipefail

OUT="/var/lib/node_exporter/textfile_collector/cups.prom"
tmp="$(mktemp "${OUT}.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

{
  echo '# HELP cups_scheduler_up Whether cupsd answers an IPP request.'
  echo '# TYPE cups_scheduler_up gauge'
  if lpstat -r >/dev/null 2>&1; then echo 'cups_scheduler_up 1'
  else echo 'cups_scheduler_up 0'; printf '' > "$tmp"; fi

  echo '# HELP cups_printer_enabled Queue is transmitting to the device.'
  echo '# TYPE cups_printer_enabled gauge'
  echo '# HELP cups_printer_accepting Queue is accepting new jobs.'
  echo '# TYPE cups_printer_accepting gauge'

  lpstat -p 2>/dev/null | awk '
    $1 == "printer" {
      q = $2
      state = ($3 == "disabled") ? 0 : 1
      printf "cups_printer_enabled{printer=\"%s\"} %d\n", q, state
    }'

  lpstat -a 2>/dev/null | awk '
    {
      q = $1
      state = ($2 == "accepting") ? 1 : 0
      printf "cups_printer_accepting{printer=\"%s\"} %d\n", q, state
    }'

  echo '# HELP cups_queue_backlog Jobs pending or processing per queue.'
  echo '# TYPE cups_queue_backlog gauge'
  lpstat -o 2>/dev/null | awk '
    { n = split($1, parts, "-"); q = ""
      for (i = 1; i < n; i++) q = (i == 1 ? parts[i] : q "-" parts[i])
      backlog[q]++ }
    END { for (q in backlog)
            printf "cups_queue_backlog{printer=\"%s\"} %d\n", q, backlog[q] }'
} > "$tmp"

chmod 0644 "$tmp"
mv "$tmp" "$OUT"
trap - EXIT
```

Reglas de alerta que vale la pena tener desde el primer día:

```yaml
groups:
  - name: cups
    rules:
      - alert: CupsSchedulerDown
        expr: cups_scheduler_up == 0
        for: 2m
        labels: { severity: critical }
        annotations:
          summary: "cupsd is not answering IPP on {{ $labels.instance }}"

      - alert: CupsQueueDisabled
        expr: cups_printer_enabled == 0
        for: 10m
        labels: { severity: warning }
        annotations:
          summary: "Queue {{ $labels.printer }} has been disabled for 10 minutes"

      - alert: CupsQueueNotAccepting
        expr: cups_printer_accepting == 0
        for: 30m
        labels: { severity: warning }
        annotations:
          summary: "Queue {{ $labels.printer }} rejecting jobs — a drain that was never reverted?"

      - alert: CupsBacklogGrowing
        expr: cups_queue_backlog > 5
        for: 15m
        labels: { severity: warning }
        annotations:
          summary: "{{ $labels.printer }} backlog {{ $value }} jobs for 15 minutes"
```

`CupsQueueNotAccepting` es la regla que atrapa el incidente real más común: alguien ejecutó `cupsreject` para una ventana de mantenimiento y la ventana terminó sin un `cupsaccept`. Los jobs no se pierden — se rechazan al enviarlos, y la aplicación que envía normalmente se traga el error.

---

## 7. Referencia de comandos y archivos

**Envío y control de jobs:** `lp`, `lpr`, `lpq`, `lprm`, `cancel`, `lpstat`, `lpmove`
**Administración:** `lpadmin`, `lpinfo`, `lpoptions`, `cupsaccept`, `cupsreject`, `cupsenable`, `cupsdisable`, `cupsctl`, `cupsd -t`
**Diagnóstico:** `ipptool`, `ippfind`, `driverless`, `cupstestppd`
**Archivos:** `/etc/cups/cupsd.conf`, `/etc/cups/cups-files.conf`, `/etc/cups/printers.conf`, `/etc/cups/classes.conf`, `/etc/cups/client.conf`, `/etc/cups/lpoptions`, `~/.cups/lpoptions`, `/etc/cups/ppd/`, `/etc/printcap`, `/var/spool/cups/`, `/var/log/cups/{error,access,page}_log`
**Puertos:** IPP `631/tcp` (y `631/udp` para el browsing legacy de CUPS), AppSocket `9100/tcp`, LPD `515/tcp`, mDNS `5353/udp`, SNMP `161/udp`

Los dos invariantes que vale la pena llevarse de este tema:

1. **Entrada y transmisión son interruptores separados.** `cupsaccept`/`cupsreject` ≠ `cupsenable`/`cupsdisable`. Elegir el equivocado durante un mantenimiento o bien pierde trabajo o bien no protege al dispositivo.
2. **`printers.conf` es estado, `cupsd.conf` es configuración.** Reconciliá las colas con `lpadmin` a partir de una declaración que mantengas bajo control de versiones; nunca edites a mano los archivos que el planificador posee.

---

## Referencias

- LPI — Exam 101-500 Objectives: https://www.lpi.org/our-certifications/exam-101-objectives/
- LPI — Exam 102-500 Objectives (Topic 108, Essential System Services): https://www.lpi.org/our-certifications/exam-102-objectives/
- OpenPrinting CUPS — Documentation index: https://openprinting.github.io/cups/
- CUPS — `cupsd.conf(5)` man page: https://openprinting.github.io/cups/doc/man-cupsd.conf.html
- CUPS — `cups-files.conf(5)` man page: https://openprinting.github.io/cups/doc/man-cups-files.conf.html
- CUPS — `lpadmin(8)` man page: https://openprinting.github.io/cups/doc/man-lpadmin.html
- CUPS — `lpstat(1)` man page: https://openprinting.github.io/cups/doc/man-lpstat.html
- CUPS — `lp(1)` man page: https://openprinting.github.io/cups/doc/man-lp.html
- CUPS — `lpr(1)` man page: https://openprinting.github.io/cups/doc/man-lpr.html
- CUPS — `cupsctl(8)` man page: https://openprinting.github.io/cups/doc/man-cupsctl.html
- CUPS — `cups-lpd(8)` man page: https://openprinting.github.io/cups/doc/man-cups-lpd.html
- CUPS — Command-Line Printing and Options: https://openprinting.github.io/cups/doc/options.html
- CUPS — Filter and Backend Programming (exit codes, argv contract): https://openprinting.github.io/cups/doc/api-filter.html
- CUPS — Server Security: https://openprinting.github.io/cups/doc/security.html
- OpenPrinting — cups-filters project: https://github.com/OpenPrinting/cups-filters
- OpenPrinting — Printer Applications (the post-PPD driver model): https://openprinting.github.io/achievements/#printer-applications
- IETF RFC 8010 — IPP/1.1: Encoding and Transport: https://www.rfc-editor.org/rfc/rfc8010
- IETF RFC 8011 — IPP/1.1: Model and Semantics: https://www.rfc-editor.org/rfc/rfc8011
- IETF RFC 1179 — Line Printer Daemon Protocol: https://www.rfc-editor.org/rfc/rfc1179
- PWG 5100.14 — IPP Everywhere: https://ftp.pwg.org/pub/pwg/candidates/cs-ippeve11-20200515-5100.14.pdf
- PWG — IANA IPP Registrations (`printer-state-reasons`, `job-state`): https://www.iana.org/assignments/ipp-registrations/ipp-registrations.xhtml