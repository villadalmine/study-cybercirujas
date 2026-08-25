# 332.2 Host Intrusion Detection

> **LPIC-3 303-300 (v3.0.0) — Tópico 332: Host Security**
> Peso en el examen: **8.33**
> Utilidades y ficheros clave: `auditd`, `auditctl`, `ausearch`, `aureport`, `autrace`, `/etc/audit/auditd.conf`, `/etc/audit/audit.rules`, `/etc/audit/rules.d/`, `aide`, `/etc/aide/aide.conf`, `rkhunter`, `/etc/rkhunter.conf`, `chkrootkit`, `maldet`, `conf.maldet`, `oscap`, SCAP datastreams.

---

## 1. Motivación: el problema arquitectónico de producción

### 1.1 La asimetría fundamental

Un NIDS (Network Intrusion Detection System) observa el tráfico; un HIDS (Host Intrusion Detection System) observa el **estado y el comportamiento del sistema operativo**. La diferencia no es de gusto, es de posición en la kill chain:

| Fase (MITRE ATT&CK) | Visible en NIDS | Visible en HIDS |
|---|---|---|
| Initial Access (exploit remoto) | Sí, si no está cifrado | Parcial (crash, syscall anómala) |
| Execution (`sh -c curl \| bash`) | Solo la descarga | **Sí** (`execve` con auid, ppid, cwd) |
| Persistence (unit file, cron, `authorized_keys`) | **No** | **Sí** (FIM + audit watch) |
| Privilege Escalation (setuid, capability, `pkexec`) | No | **Sí** (syscall rule) |
| Defense Evasion (borrado de logs, `LD_PRELOAD` rootkit) | No | **Sí** (audit + rootkit hunter) |
| C2 sobre TLS 443 con SNI legítimo | Muy débil | Parcial (proceso que abre el socket) |
| Exfiltración vía DNS | Sí | Parcial |

El HIDS no reemplaza al NIDS: **cubre exactamente lo que el cifrado ubicuo le quitó al NIDS**. Desde que TLS 1.3 con ESNI/ECH es el default y el tráfico este-oeste dentro del cluster va por mTLS, el punto de observación con mejor relación señal/ruido volvió a ser el kernel del host.

### 1.2 Los cuatro pilares del host intrusion detection en Linux

El objetivo 332.2 agrupa herramientas que en producción cumplen funciones **complementarias, no redundantes**:

```
                        ┌──────────────────────────────────────────┐
                        │        DETECCIÓN EN EL HOST              │
                        └──────────────────────────────────────────┘
                                        │
   ┌──────────────┬─────────────────────┼─────────────────────┬──────────────┐
   │              │                     │                     │              │
┌──▼───────┐  ┌───▼────────┐     ┌──────▼──────┐      ┌───────▼──────┐  ┌────▼──────┐
│  FIM     │  │  Auditoría │     │  Rootkit /  │      │  Compliance  │  │ Runtime   │
│ (estado) │  │ (conducta) │     │  Malware    │      │  (postura)   │  │ (eBPF)    │
│          │  │            │     │             │      │              │  │           │
│  AIDE    │  │  Linux     │     │  rkhunter   │      │  OpenSCAP    │  │  Falco    │
│ Tripwire │  │  Audit     │     │  chkrootkit │      │  SSG / CIS   │  │  Tetragon │
│ Samhain  │  │  (auditd)  │     │  maldet     │      │  OVAL/XCCDF  │  │ (fuera de │
│          │  │            │     │  ClamAV     │      │              │  │  LPIC-3)  │
└──────────┘  └────────────┘     └─────────────┘      └──────────────┘  └───────────┘
  "¿cambió?"    "¿quién lo         "¿hay algo        "¿está como        "¿qué está
                 cambió y            conocido            debería           pasando
                 con qué?"           y malo?"            estar?"           ahora?"
```

- **FIM (File Integrity Monitoring)** — AIDE. Detección **diferida** por comparación contra un baseline criptográfico. Responde *qué* cambió, nunca *quién*.
- **Auditoría del kernel** — Linux Audit. Detección **en tiempo real** por interceptación de syscalls y accesos a inodos. Responde *quién, cuándo, desde qué sesión y con qué proceso padre*, pero no sabe si eso es malo.
- **Antirootkit / antimalware** — rkhunter, chkrootkit, maldet. Detección **por firma y heurística conocida**. Cobertura estrecha, alto valor cuando pega.
- **Compliance / postura** — OpenSCAP. No detecta intrusiones: detecta **la superficie que las permite** y la deriva de configuración. Es el único de los cuatro que es preventivo y auditable frente a un tercero (CIS, STIG, PCI-DSS, ANSSI-BP-028).

### 1.3 Los tres errores arquitectónicos que anulan un HIDS

Un HIDS mal desplegado da **falsa confianza**, que es peor que no tenerlo. Los tres modos de fallo que aparecen en toda auditoría real:

1. **El baseline vive en el host que protege.** Si `/var/lib/aide/aide.db` es escribible por root y el atacante es root, corre `aide --update` y el FIM queda "limpio" para siempre. Lo mismo con `rkhunter --propupd`: es el primer comando que ejecuta un atacante con experiencia. **La base de datos debe salir del host** (pull desde un colector, medio de solo lectura, o firma GPG verificada fuera de banda).
2. **Los logs de audit se quedan en el host.** `/var/log/audit/audit.log` es un fichero local; borrarlo o truncarlo es trivial con privilegios. El plugin `au-remote` a un colector con `auditd` en modo `tcp_listen_port` es obligatorio en cualquier entorno regulado.
3. **Se monitorea todo y no se lee nada.** Un ruleset de audit copiado sin criterio genera 40 000 eventos/min en un nodo de Kubernetes, desborda el `backlog_limit`, el kernel empieza a descartar (`lost`), y con `failure=2` puede incluso provocar un panic. La regla es: **cada regla debe tener un `-k` con nombre, un dueño y una acción esperada.**

### 1.4 El caso particular de flotas efímeras y Kubernetes

En infraestructura inmutable (nodos que viven horas, contenedores que viven minutos) el modelo cambia:

| Supuesto clásico | Realidad en flota efímera | Consecuencia de diseño |
|---|---|---|
| El baseline se construye una vez y dura años | El nodo se recrea con cada AMI/imagen | El baseline se genera **en la build**, se firma y se distribuye en la imagen |
| El FIM detecta persistencia | La persistencia en disco no sobrevive al reciclado | El FIM se vuelve detector de *drift* y de compromiso *en curso*, no de persistencia |
| `auditd` corre por host | El kernel audit es **global**, no tiene namespaces | Un solo `auditd` en el host ve syscalls de todos los contenedores; los contenedores **no** pueden correr `auditd` propio |
| Los logs rotan en disco | El disco del nodo desaparece | `au-remote` o `audisp-syslog` → journald → agente de logs, siempre |
| El scan de compliance es manual | Cientos de nodos | OpenSCAP en CI sobre la imagen + Compliance Operator en runtime |

> **Punto crítico y frecuente en entrevistas:** el subsistema audit del kernel **no está namespaced**. Existe el campo experimental `contid` (audit container ID) y trabajo upstream de Richard Guy Briggs, pero en kernels de producción la única forma de atribuir un evento a un contenedor es correlacionar `pid`/`ppid` con el runtime, o usar el `subj` de SELinux. Las capabilities `CAP_AUDIT_CONTROL` y `CAP_AUDIT_WRITE`/`CAP_AUDIT_READ` están fuera del set por defecto de Docker/containerd precisamente por esto.

---

## 2. Comparativas técnicas y trade-offs

### 2.1 File Integrity Monitoring: AIDE vs. alternativas

| Criterio | **AIDE** | **Tripwire (OSS)** | **Samhain** | **`rpm -Va` / `dpkg --verify`** | **osquery + FIM** | **Falco / Tetragon (eBPF)** |
|---|---|---|---|---|---|---|
| Modelo | Snapshot + diff | Snapshot + diff | Snapshot + diff, con daemon | Verifica contra metadatos del paquete | Consulta SQL + eventos inotify | Eventos de kernel en vivo |
| Momento de detección | Diferido (cron/timer) | Diferido | Diferido o continuo (daemon) | Diferido | Continuo | Continuo (µs) |
| Base de datos | Fichero plano binario/gzip | Fichero firmado (site/local key) | Fichero, opcionalmente en servidor Yule | La DB de paquetes (`/var/lib/rpm`) | SQLite local | Sin estado |
| Firma nativa del baseline | **No** (requiere GPG externo) | **Sí** (ElGamal site/local key) | **Sí** (firma + baseline remoto) | Solo por firma del paquete | No | N/A |
| Centralización | No (hay que construirla) | Solo en la edición comercial | **Sí** (Yule server, nativo) | No | Sí (fleet manager) | Sí |
| Coste de CPU/IO | Alto en el scan (hash de todo) | Alto | Alto | Bajo | Bajo | Muy bajo (per-event) |
| Detecta ficheros **añadidos** | **Sí** | Sí | Sí | **No** (solo lo que pertenece a un paquete) | Sí | Sí |
| Detecta ficheros no empaquetados | Sí | Sí | Sí | **No** | Sí | Sí |
| Presente en LPIC-3 303 | **Sí (objetivo)** | Mención | Mención | No | No | No |
| Empaquetado en RHEL/Debian/SUSE | Sí, base | Parcial | Parcial (EPEL/Debian) | Nativo | Repo externo | Repo externo |

**Trade-off central de AIDE:** es simple, está en todas las distros y no tiene dependencias de red — a cambio, **no protege su propia base de datos** ni tiene canal de reporte. Toda la ingeniería de producción alrededor de AIDE consiste en compensar esas dos carencias.

**`rpm -Va` es complementario, no sustituto:** verifica firma, permisos, tamaño, mtime y hash contra el manifiesto del paquete, pero es ciego a `/usr/local/bin/backdoor`, a `~/.ssh/authorized_keys` y a cualquier fichero no empaquetado. AIDE ve todo el filesystem. Un pipeline serio corre **ambos**.

### 2.2 Detección de conducta: Linux Audit vs. alternativas

| Criterio | **Linux Audit (auditd)** | **eBPF (Falco/Tetragon)** | **`syslog` de aplicaciones** | **`sysdig` (kmod)** |
|---|---|---|---|---|
| Punto de intercepción | `audit_syscall_entry/exit`, LSM hooks, inode watch | tracepoints / kprobes / LSM BPF | userspace | kmod propio |
| Overhead con ruleset amplio | **Alto** (serializa a texto, cola global) | Bajo-medio | Nulo | Medio |
| Filtrado en kernel | Sí (campos `-F`), limitado | Sí, programable y rico | N/A | Sí |
| Namespace-aware | **No** | **Sí** (cgroup/pid ns) | N/A | Sí |
| Requerido por normativa | **Sí** (CC, STIG, PCI-DSS 10.x) | Rara vez aceptado solo | No | No |
| Riesgo de pérdida de eventos | `backlog_limit` desbordado → `lost` | Ring buffer perdido | N/A | Ring buffer |
| Puede detener el sistema ante fallo | **Sí** (`failure=2` → panic) | No | No | No |
| Estabilidad de API | Muy alta (décadas) | Depende del kernel/CO-RE | Alta | Media |

**Cuándo elegir cuál:** si hay una obligación de cumplimiento (CC/PCI/STIG), `auditd` **no es opcional** — es el mecanismo que el auditor sabe leer. eBPF es superior técnicamente para detección en flota grande y contenedores, y en la práctica moderna se corren los dos: `auditd` con un ruleset **mínimo y normativo**, eBPF con la detección conductual pesada.

### 2.3 Antirootkit y antimalware

| Criterio | **rkhunter** | **chkrootkit** | **Linux Malware Detect (maldet)** | **ClamAV** |
|---|---|---|---|---|
| Método | Firmas de rootkits, propiedades de ficheros, chequeos de red/local, comparación con DB propia | Firmas + binarios propios (`chklastlog`, `chkproc`, `chkwtmp`) | Firmas HEX/MD5 de malware web + heurística, integrable con ClamAV | Motor AV genérico con firmas |
| Base de datos actualizable | `rkhunter --update` (mirrors HTTP) | **No** (se actualiza con la versión) | `maldet -u` (rfxn.com) | `freshclam` |
| Detecta LKM rootkits | Parcial (`chkproc` equivalente) | Sí (`chkproc`, comparación `/proc` vs `ps`) | No | No |
| Modo continuo | No (cron) | No (cron) | **Sí** (`-m`, inotify) | `clamonacc` (fanotify) |
| Cuarentena automática | No | No | **Sí** (`quarantine_hits`) | Sí |
| Falsos positivos típicos | Muy altos tras actualizaciones de paquetes | Medios (`bindshell` con portmap/rpcbind) | Medios en `/home` con webshells legítimos de test | Bajos |
| Caso de uso real | Servidores estáticos, verificación post-incidente | Verificación rápida desde medio externo | Hosting compartido / directorios de upload web | Correo, uploads, ficheros compartidos |

**El punto ciego compartido:** las tres herramientas dependen de que el sistema base sobre el que corren no esté ya comprometido. Un rootkit en kernel-space que hookea `getdents64` esconde los ficheros de `rkhunter` **y** de AIDE. Por eso la verificación forense seria se hace desde **medio externo** (live USB, snapshot del disco montado read-only en otra máquina) — y por eso `chkrootkit -p /mnt/rescue/bin` existe.

### 2.4 OpenSCAP: dónde encaja

| Componente SCAP | Qué es | Fichero típico |
|---|---|---|
| **XCCDF** | Checklist: reglas, perfiles, severidad, texto de remediación | `ssg-rhel9-xccdf.xml` |
| **OVAL** | Lógica de evaluación declarativa (¿qué comprobar y cómo?) | `ssg-rhel9-oval.xml` |
| **CPE** | Identificación de plataforma (aplicabilidad de la regla) | `ssg-rhel9-cpe-dictionary.xml` |
| **OCIL** | Comprobaciones que requieren intervención humana | `ssg-rhel9-ocil.xml` |
| **SDS (Source DataStream)** | Contenedor único con todo lo anterior | `ssg-rhel9-ds.xml` |
| **ARF (Result DataStream)** | Resultados completos, archivables y firmables | `arf.xml` |

| Criterio | **OpenSCAP** | **Lynis** | **CIS-CAT** | **Ansible + `assert`** |
|---|---|---|---|---|
| Contenido estándar | **Sí** (SCAP 1.3, NIST-validado) | Propio | Propio (CIS oficial) | Propio |
| Perfiles CIS/STIG/PCI/ANSSI | **Sí** (via SSG) | Parcial | Sí (CIS) | Manual |
| Remediación generada | **Sí** (bash, Ansible, Puppet, Kickstart, Ignition) | No | Parcial | Es la herramienta |
| Escaneo offline (imagen/VM) | **Sí** (`oscap-podman`, `oscap-vm`, `--chroot`) | No | No | No |
| Resultado archivable/firmable | **Sí** (ARF) | Texto | HTML/CSV | No |
| Licencia | LGPL | GPL | Requiere membresía CIS | GPL |

---

## 3. Linux Audit: arquitectura interna

### 3.1 El camino de un evento

```
   userspace                    │            kernel space
                                │
 ┌──────────────┐               │      ┌───────────────────────────────┐
 │  proceso     │  syscall      │      │  audit_syscall_entry()        │
 │  (passwd)    │──────────────────────▶  ├─ ¿regla en lista TASK?     │
 └──────────────┘               │      │  ├─ ¿regla en lista EXIT?     │
                                │      │  └─ ¿watch sobre el inodo?    │
                                │      │                               │
                                │      │  audit_log_exit() → skb       │
                                │      └───────────┬───────────────────┘
                                │                  │
                                │      ┌───────────▼───────────────────┐
                                │      │  kauditd (kthread)            │
                                │      │  cola: audit_backlog_limit    │
                                │      └───────────┬───────────────────┘
                                │                  │ netlink NETLINK_AUDIT
 ┌──────────────────────────────┼──────────────────▼───────────────────┐
 │  auditd (PID único, se registra con AUDIT_SET pid)                  │
 │    ├─ escribe /var/log/audit/audit.log  (write_logs=yes)            │
 │    └─ cola interna (q_depth) → plugins de /etc/audit/plugins.d/     │
 │            ├─ au-remote  → colector remoto (TCP/Kerberos)           │
 │            ├─ audisp-syslog → journald/rsyslog                      │
 │            └─ af_unix    → socket para agentes (ej. SIEM)           │
 └─────────────────────────────────────────────────────────────────────┘
```

Puntos que hay que tener claros:

- **Un solo proceso puede ser el receptor.** El kernel guarda un `audit_pid`; si `auditd` no corre y `audit=1` está en la línea de comandos del kernel, los eventos van a `printk` → `dmesg`/journald. Si `audit=0`, el subsistema se deshabilita al arranque.
- **Las reglas viven en el kernel, no en un fichero.** `/etc/audit/rules.d/*.rules` son solo la fuente que `augenrules` compila a `/etc/audit/audit.rules` y `auditctl -R` carga. `auditctl -l` muestra la verdad.
- **Listas de filtro:** `task` (en `fork`/`clone`, campos limitados), `exit` (al retornar de la syscall, es la útil), `user` (mensajes de userspace, 1100–1199), `exclude` (descartar por `msgtype`), `filesystem` (por `fstype`, desde audit 3.x).
- **Acciones:** `always` (registrar), `never` (descartar). El orden importa: la **primera** regla que matchea gana.

### 3.2 `auditd.conf` de producción, completo

```ini
# /etc/audit/auditd.conf — audit 3.1.x
# Perfil: nodo de producción con envío a colector central.

# --- Origen y formato -------------------------------------------------------
local_events = yes
write_logs = yes
log_file = /var/log/audit/audit.log
log_group = adm
log_format = ENRICHED
# ENRICHED resuelve uid/gid/syscall/arch EN EL MOMENTO del evento y añade los
# campos con sufijo. Es OBLIGATORIO cuando los logs se envían a otro host:
# sin él, el colector resolvería los UID contra SU propio /etc/passwd.

# --- Durabilidad ------------------------------------------------------------
flush = INCREMENTAL_ASYNC
freq = 50
# NONE < INCREMENTAL < INCREMENTAL_ASYNC < DATA < SYNC.
# DATA/SYNC llaman fsync() por evento: correcto para Common Criteria,
# devastador para el rendimiento. INCREMENTAL_ASYNC + freq=50 es el
# compromiso habitual.

# --- Rotación ---------------------------------------------------------------
max_log_file = 64
num_logs = 10
max_log_file_action = ROTATE
# 64 MB x 10 = 640 MB de techo. Dimensionar /var/log/audit como partición
# propia: si audit llena / , el sistema entero cae.

# --- Comportamiento ante falta de espacio -----------------------------------
space_left = 512
space_left_action = SYSLOG
admin_space_left = 128
admin_space_left_action = SINGLE
disk_full_action = SUSPEND
disk_error_action = SUSPEND
verify_email = yes
action_mail_acct = soc@example.net
# Acciones posibles: IGNORE, SYSLOG, ROTATE, EMAIL, EXEC, SUSPEND, SINGLE, HALT.
# HALT/SINGLE cumplen la normativa "no operar sin auditoría" — y son también
# la forma más elegante de auto-infligirse un incidente Sev1. Decisión de
# negocio, documentada, no default silencioso.

# --- Prioridad y colas ------------------------------------------------------
priority_boost = 4
q_depth = 1200
overflow_action = SYSLOG
max_restarts = 10
plugin_dir = /etc/audit/plugins.d
end_of_event_timeout = 2

# --- Identidad en el evento -------------------------------------------------
name_format = HOSTNAME
##name = nodo-01.prod.example.net
# NONE | HOSTNAME | FQD | NUMERIC | USER. Con envío remoto, HOSTNAME o FQD.

# --- Recepción remota (solo en el COLECTOR: descomentar allí) ---------------
##tcp_listen_port = 60
tcp_listen_queue = 5
tcp_max_per_addr = 1
##tcp_client_ports = 1024-65535
tcp_client_max_idle = 0
transport = KRB5
krb5_principal = auditd
##krb5_key_file = /etc/audit/audit.key
use_libwrap = yes
distribute_network = no
```

### 3.3 Plugin de envío remoto

```ini
# /etc/audit/plugins.d/au-remote.conf
active = yes
direction = out
path = /sbin/audisp-remote
type = always
format = string
```

```ini
# /etc/audit/audisp-remote.conf
remote_server = audit-collector.prod.example.net
port = 60
local_port = any
transport = KRB5
mode = immediate
queue_file = /var/spool/audit/remote.q
queue_depth = 20480
format = ascii
network_retry_time = 1
max_tries_per_record = 3
max_time_per_record = 5
heartbeat_timeout = 60

# --- Qué hacer cuando el colector no responde ------------------------------
network_failure_action = syslog
disk_low_action = ignore
disk_full_action = warn_once
disk_error_action = warn_once
remote_ending_action = reconnect
generic_error_action = syslog
generic_warning_action = syslog
queue_error_action = stop
overflow_action = syslog
```

> **Trade-off que hay que decidir explícitamente:** `network_failure_action = halt` cumple "ningún evento se pierde jamás" y apaga el nodo cuando el colector se cae. `= syslog` conserva disponibilidad y pierde eventos. En un cluster de producción, la respuesta correcta casi siempre es `syslog` + `queue_file` grande en disco local + alerta sobre el heartbeat perdido.

### 3.4 Ruleset de producción completo

Los ficheros en `/etc/audit/rules.d/` se concatenan por orden lexicográfico. Esta es la convención que evita el 90 % de los problemas:

```bash
/etc/audit/rules.d/
├── 10-base-config.rules      # control: buffers, failure mode
├── 20-dont-audit.rules       # reglas 'never' (ruido) — DEBEN ir antes
├── 30-identity.rules         # cuentas, sudo, PAM
├── 31-privilege.rules        # setuid/setgid, capabilities, escalada
├── 32-access.rules           # accesos denegados, cambios de permisos
├── 33-modules.rules          # LKM
├── 34-execution.rules        # execve
├── 35-persistence.rules      # cron, systemd, ssh keys
├── 40-mac-policy.rules       # SELinux/AppArmor
└── 99-finalize.rules         # -e 2 (inmutable) — SIEMPRE el último
```

**`10-base-config.rules`**

```bash
## Vaciar reglas previas (idempotencia)
-D

## Tamaño del backlog del kernel. 8192 es el mínimo razonable en un host
## con carga; en nodos de Kubernetes con muchos execve, 32768.
-b 32768

## Tiempo (ms) que el generador espera si el backlog está lleno, antes de
## descartar. 60000 = 60 s. Con 0, se descarta de inmediato.
--backlog_wait_time 60000

## Sin límite de tasa; el control se hace con reglas 'never', no estrangulando.
-r 0

## Modo de fallo: 0=silencioso 1=printk 2=panic.
## 2 solo en sistemas donde perder auditoría es peor que perder el servicio.
-f 1
```

**`20-dont-audit.rules`** — reglas `never`, primero para que ganen:

```bash
## El propio auditd y sus herramientas generan ruido circular.
-a never,exit -F arch=b64 -F exe=/usr/sbin/auditd
-a never,exit -F arch=b64 -F exe=/usr/sbin/auditctl

## Actividad de sistemas de ficheros virtuales — nunca es interesante.
-a never,exit -F arch=b64 -F dir=/proc
-a never,exit -F arch=b64 -F dir=/sys/fs/cgroup

## VMware/QEMU tools, agentes de monitorización de alto volumen.
-a never,exit -F arch=b64 -F exe=/usr/bin/node_exporter
-a never,exit -F arch=b64 -F exe=/usr/bin/containerd-shim-runc-v2

## Ruido de /dev/null y /dev/zero en pipelines.
-a never,exit -F arch=b64 -F path=/dev/null
-a never,exit -F arch=b64 -F path=/dev/zero
```

**`30-identity.rules`**

```bash
## Modificación de cuentas locales.
-w /etc/group      -p wa -k identity
-w /etc/passwd     -p wa -k identity
-w /etc/gshadow    -p wa -k identity
-w /etc/shadow     -p wa -k identity
-w /etc/security/opasswd -p wa -k identity
-w /etc/subuid     -p wa -k identity
-w /etc/subgid     -p wa -k identity

## sudo y su política.
-w /etc/sudoers    -p wa -k scope
-w /etc/sudoers.d/ -p wa -k scope
-w /var/log/sudo.log -p wa -k actions

## PAM y NSS.
-w /etc/pam.d/          -p wa -k pam
-w /etc/security/       -p wa -k pam
-w /etc/nsswitch.conf   -p wa -k pam

## Uso efectivo de sudo/su por usuarios no privilegiados.
-a always,exit -F arch=b64 -F path=/usr/bin/sudo -F perm=x -F auid>=1000 -F auid!=unset -k privileged-sudo
-a always,exit -F arch=b64 -F path=/usr/bin/su   -F perm=x -F auid>=1000 -F auid!=unset -k privileged-su
```

**`31-privilege.rules`**

```bash
## Cambios de identidad efectiva.
-a always,exit -F arch=b64 -S setuid,setreuid,setresuid,setgid,setregid,setresgid -F auid>=1000 -F auid!=unset -k privilege-change
-a always,exit -F arch=b32 -S setuid,setreuid,setresuid,setgid,setregid,setresgid -F auid>=1000 -F auid!=unset -k privilege-change

## Manipulación de capabilities y de ficheros setuid/setgid.
-a always,exit -F arch=b64 -S capset -k capabilities
-a always,exit -F arch=b64 -S chmod,fchmod,fchmodat -F auid>=1000 -F auid!=unset -k perm-mod
-a always,exit -F arch=b64 -S chown,fchown,fchownat,lchown -F auid>=1000 -F auid!=unset -k perm-mod
-a always,exit -F arch=b64 -S setxattr,lsetxattr,fsetxattr,removexattr,lremovexattr,fremovexattr -F auid>=1000 -F auid!=unset -k perm-mod

## El clásico: usuario cuyo auid != uid efectivo (escalada consumada).
-a always,exit -F arch=b64 -S execve -C uid!=euid -F euid=0 -k setuid-exec
-a always,exit -F arch=b32 -S execve -C uid!=euid -F euid=0 -k setuid-exec

## Acceso a memoria de otros procesos (inyección, dumpeo de credenciales).
-a always,exit -F arch=b64 -S ptrace -k tracing
-a always,exit -F arch=b64 -S process_vm_readv,process_vm_writev -k tracing
```

**`32-access.rules`**

```bash
## Accesos denegados: EACCES y EPERM. Alta señal, bajo volumen.
-a always,exit -F arch=b64 -S open,openat,openat2,creat,truncate,ftruncate -F exit=-EACCES -F auid>=1000 -F auid!=unset -k access-denied
-a always,exit -F arch=b64 -S open,openat,openat2,creat,truncate,ftruncate -F exit=-EPERM  -F auid>=1000 -F auid!=unset -k access-denied

## Borrado y renombrado por usuarios reales (anti-forense).
-a always,exit -F arch=b64 -S unlink,unlinkat,rename,renameat,renameat2 -F auid>=1000 -F auid!=unset -k delete

## Montajes.
-a always,exit -F arch=b64 -S mount,umount2 -F auid>=1000 -F auid!=unset -k mounts
```

**`33-modules.rules`**

```bash
-w /usr/bin/kmod -p x -k modules
-a always,exit -F arch=b64 -S init_module,finit_module,delete_module -k modules
-a always,exit -F arch=b32 -S init_module,finit_module,delete_module -k modules
-w /etc/modprobe.d/ -p wa -k modules
-w /etc/modules-load.d/ -p wa -k modules
```

**`34-execution.rules`**

```bash
## execve de usuarios reales. ALTO VOLUMEN: medir antes de habilitar en
## nodos de contenedores. Con -F auid!=unset se excluye lo que arranca el
## kernel/systemd sin sesión de login.
-a always,exit -F arch=b64 -S execve -F auid>=1000 -F auid!=unset -k exec
-a always,exit -F arch=b32 -S execve -F auid>=1000 -F auid!=unset -k exec

## Binarios de shell y de descarga usados en la fase de execution.
-w /usr/bin/wget  -p x -k recon
-w /usr/bin/curl  -p x -k recon
-w /usr/bin/nc    -p x -k recon
-w /usr/bin/ncat  -p x -k recon
-w /usr/bin/socat -p x -k recon
```

**`35-persistence.rules`**

```bash
-w /etc/crontab      -p wa -k cron
-w /etc/cron.d/      -p wa -k cron
-w /etc/cron.daily/  -p wa -k cron
-w /etc/cron.hourly/ -p wa -k cron
-w /var/spool/cron/  -p wa -k cron
-w /etc/at.allow     -p wa -k cron
-w /etc/at.deny      -p wa -k cron

-w /etc/systemd/system/ -p wa -k systemd-units
-w /usr/lib/systemd/system/ -p wa -k systemd-units
-w /etc/systemd/user/   -p wa -k systemd-units

-w /root/.ssh/         -p wa -k ssh-keys
-w /etc/ssh/sshd_config -p wa -k sshd
-w /etc/ssh/sshd_config.d/ -p wa -k sshd

-w /etc/ld.so.conf     -p wa -k libpath
-w /etc/ld.so.conf.d/  -p wa -k libpath
-w /etc/ld.so.preload  -p wa -k libpath

## Tiempo del sistema (anti-forense por desalineación de timestamps).
-a always,exit -F arch=b64 -S adjtimex,settimeofday,clock_settime -k time-change
-w /etc/localtime -p wa -k time-change
```

**`40-mac-policy.rules`**

```bash
-w /etc/selinux/     -p wa -k MAC-policy
-w /usr/share/selinux/ -p wa -k MAC-policy
-w /etc/apparmor/    -p wa -k MAC-policy
-w /etc/apparmor.d/  -p wa -k MAC-policy
```

**`99-finalize.rules`**

```bash
## Modo inmutable: ninguna regla puede añadirse, borrarse ni modificarse
## hasta el próximo reinicio. Los intentos generan CONFIG_CHANGE res=failed.
-e 2
```

> **Consecuencia operativa de `-e 2`:** cualquier cambio de reglas requiere reinicio del nodo. En una flota inmutable eso es correcto (el nodo se recicla igual). En un servidor pet, documentarlo o usar `-e 1` (habilitado, mutable). `-e 0` deshabilita la auditoría.

### 3.5 Carga y verificación de reglas

```console
$ sudo augenrules --check
/usr/sbin/augenrules: Rules have changed and should be updated

$ sudo augenrules --load
No rules
enabled 1
failure 1
pid 0
rate_limit 0
backlog_limit 32768
lost 0
backlog 0
backlog_wait_time 60000
backlog_wait_time_actual 0
enabled 2
failure 1
pid 1284
rate_limit 0
backlog_limit 32768
lost 0
backlog 4
backlog_wait_time 60000
backlog_wait_time_actual 0
loginuid_immutable 1 locked

$ sudo auditctl -s
enabled 2
failure 1
pid 1284
rate_limit 0
backlog_limit 32768
lost 0
backlog 0
backlog_wait_time 60000
backlog_wait_time_actual 0
loginuid_immutable 1 locked
```

Lectura de esa salida — es el diagnóstico de salud principal del subsistema:

| Campo | Significado | Valor sano |
|---|---|---|
| `enabled` | 0=off, 1=on, 2=inmutable | `2` en producción endurecida |
| `failure` | Acción ante fallo interno del kernel | `1` (printk) o `2` (panic) |
| `pid` | PID de `auditd`. **`0` significa que nadie está escuchando** | ≠ 0 |
| `rate_limit` | Mensajes/segundo máximos (0 = sin límite) | `0` |
| `backlog_limit` | Tamaño de la cola de `kauditd` | ≥ 8192 |
| `lost` | **Eventos descartados desde el arranque** | `0` — cualquier otro valor es un incidente |
| `backlog` | Ocupación instantánea de la cola | cercano a 0 |
| `backlog_wait_time_actual` | ns acumulados que procesos esperaron | crecer aquí = impacto en latencia |
| `loginuid_immutable` | El `auid` no puede reescribirse | `1 locked` |

```console
$ sudo auditctl -l | head -20
-a never,exit -F arch=b64 -S all -F exe=/usr/sbin/auditd
-a never,exit -F arch=b64 -S all -F dir=/proc
-w /etc/group -p wa -k identity
-w /etc/passwd -p wa -k identity
-w /etc/shadow -p wa -k identity
-a always,exit -F arch=b64 -S setuid,setgid,setreuid,setregid,setresuid,setresgid -F auid>=1000 -F auid!=-1 -k privilege-change
-a always,exit -F arch=b64 -S ptrace -F key=tracing
-a always,exit -F arch=b64 -S execve -F auid>=1000 -F auid!=-1 -k exec
```

> Nótese que `auid!=unset` se muestra como `auid!=-1` (antes `4294967295`). Las tres formas son equivalentes.

### 3.6 Análisis: `ausearch`, `aureport`, `autrace`

**Evento crudo, correlacionado e interpretado:**

```console
$ sudo ausearch -k identity -i -ts today
----
type=PROCTITLE msg=audit(08/24/2026 11:14:02.118:2291) : proctitle=passwd operador
type=PATH msg=audit(08/24/2026 11:14:02.118:2291) : item=0 name=/etc/shadow inode=131 dev=fd:00 mode=file,000 ouid=root ogid=root rdev=00:00 obj=system_u:object_r:shadow_t:s0 nametype=NORMAL cap_fp=none cap_fi=none cap_fe=0 cap_fver=0 cap_frootid=0
type=CWD msg=audit(08/24/2026 11:14:02.118:2291) : cwd=/root
type=SYSCALL msg=audit(08/24/2026 11:14:02.118:2291) : arch=x86_64 syscall=openat success=yes exit=4 a0=0xffffff9c a1=0x55d3c1e2f2a0 a2=O_RDWR|O_CREAT|O_NOFOLLOW a3=0x180 items=1 ppid=1922 pid=2033 auid=fmartinez uid=root gid=root euid=root suid=root fsuid=root egid=root sgid=root fsgid=root tty=pts0 ses=3 comm=passwd exe=/usr/bin/passwd subj=unconfined_u:unconfined_r:passwd_t:s0-s0:c0.c1023 key=identity
```

Los campos que importan en una investigación:

- **`auid=fmartinez`** — el *loginuid*: la identidad **original** de la sesión, inmutable, que sobrevive a `su`/`sudo`. Es el campo que responde "¿quién fue?".
- **`uid=root euid=root`** — identidad efectiva en el momento del syscall. La divergencia `auid ≠ uid` es la firma de una escalada.
- **`ses=3`** — sesión de login; permite reconstruir toda la actividad de una conexión (`ausearch --session 3`).
- **`ppid=1922`** — cadena de ancestros; con `ausearch -p` se pivotea.
- **`subj=`** — contexto SELinux del sujeto.
- **`:2291`** — el *event serial*: todos los registros con el mismo serial pertenecen a un evento atómico.

**Consultas de investigación habituales:**

```console
# Todo lo hecho por una identidad de login, no por su UID efectivo
$ sudo ausearch -ua fmartinez -i -ts 08/24/2026 09:00:00 -te 08/24/2026 12:00:00

# Toda la sesión de login 3
$ sudo ausearch --session 3 -i

# Fallos de autenticación
$ sudo ausearch -m USER_AUTH,USER_ACCT,USER_LOGIN -sv no -i -ts recent

# Ejecuciones bajo una clave concreta, formato crudo para el SIEM
$ sudo ausearch -k exec --format csv -ts today > /tmp/exec.csv

# Un fichero concreto, sin importar la regla que lo capturó
$ sudo ausearch -f /etc/ssh/sshd_config -i

# Un ejecutable concreto
$ sudo ausearch -x /usr/bin/curl -i -ts recent

# Correlación por PID y por PPID
$ sudo ausearch -p 2033 -i
$ sudo ausearch -pp 1922 -i

# Eventos con éxito o fallo del syscall
$ sudo ausearch -sc execve -sv no -i -ts today
```

**Informes agregados:**

```console
$ sudo aureport --summary -i --start this-week

Summary Report
======================
Range of time in logs: 08/17/2026 00:00:03.121 - 08/24/2026 11:52:10.004
Selected time for report: 08/17/2026 00:00:00 - 08/24/2026 11:52:10.004
Number of changes in configuration: 47
Number of changes to accounts, groups, or roles: 12
Number of logins: 214
Number of failed logins: 39
Number of authentications: 1103
Number of failed authentications: 41
Number of users: 9
Number of terminals: 14
Number of host names: 22
Number of executables: 61
Number of commands: 58
Number of files: 3311
Number of AVC's: 4
Number of MAC events: 0
Number of failed syscalls: 892
Number of anomaly events: 0
Number of responses to anomaly events: 0
Number of crypto events: 640
Number of integrity events: 0
Number of virt events: 0
Number of keys: 11
Number of process IDs: 4402
Number of events: 51884
```

```console
$ sudo aureport -au --summary -i --failed --start this-week

Failed Authentication Attempt Summary Report
============================================
total  acct
============================================
21     admin
9      root
5      test
4      oracle
2      fmartinez

$ sudo aureport -k --summary -i --start today

Key Summary Report
===================================
total  key
===================================
18204  exec
2110   identity
604    perm-mod
331    access-denied
94     privileged-sudo
41     modules
7      setuid-exec
2      tracing
```

> **Interpretación operativa:** `exec` con 18 204 eventos en un día en un solo nodo indica que la regla de `execve` está mal filtrada (probablemente un agente automatizado con `auid` asignado). `setuid-exec` con 7 y `tracing` con 2 son las líneas que se leen a mano.

**`autrace` — auditoría dirigida de un proceso:**

```console
$ sudo auditctl -D
No rules

$ sudo autrace /usr/local/bin/agente-desconocido
Waiting to execute: /usr/local/bin/agente-desconocido
Cleaning up...
Trace complete. You can locate the records with 'ausearch -i -p 4471'

$ sudo ausearch -i -p 4471 | grep -E 'syscall=(connect|execve|openat)' | head
type=SYSCALL msg=audit(08/24/2026 12:04:11.882:3901) : arch=x86_64 syscall=execve success=yes exit=0 ... comm=agente-desconocido exe=/usr/local/bin/agente-desconocido
type=SYSCALL msg=audit(08/24/2026 12:04:11.907:3914) : arch=x86_64 syscall=openat success=yes exit=3 ... name=/etc/ld.so.preload
type=SYSCALL msg=audit(08/24/2026 12:04:12.014:3988) : arch=x86_64 syscall=connect success=yes exit=0 ... comm=agente-desconocido
```

> **`autrace` borra todas las reglas** (`auditctl -D`) antes de correr. Nunca se usa en un host de producción con reglas cargadas sin restaurarlas después con `augenrules --load`, y es imposible con `-e 2`.

### 3.7 Watch vs. syscall rule

```bash
# Watch — sintaxis corta, se traduce internamente a una regla de filtro
-w /etc/shadow -p wa -k identity

# Equivalente explícito (aproximado) como syscall rule
-a always,exit -F path=/etc/shadow -F perm=wa -F key=identity
```

| | **Watch (`-w`)** | **Syscall rule (`-a`)** |
|---|---|---|
| Filtrado por `auid`/`uid` | **No** | Sí |
| Filtrado por `arch` | No aplica | Sí (obligatorio con `-S`) |
| Sobre directorios | Sí, recursivo por inodo | `-F dir=` (recursivo) o `-F path=` (exacto) |
| Sobrevive a que el fichero no exista aún | **No** (necesita el inodo) | `-F dir=` sí |
| Coste | Bajo (hook en el inodo) | Mayor si `-S` es amplio |
| Expresividad | `r w x a` | Todos los campos `-F` y comparadores `-C` |

**Trampa clásica:** `-w /etc/shadow` deja de funcionar si `passwd` reemplaza el fichero creando `/etc/shadow+` y haciendo `rename()` — el inodo cambia. Por eso el ruleset serio combina el watch sobre el fichero **y** una regla sobre el directorio o sobre las syscalls de `rename`.

### 3.8 Auditoría temprana en el arranque

```console
$ cat /proc/cmdline
BOOT_IMAGE=(hd0,gpt2)/vmlinuz-6.12.0-55.el9.x86_64 root=/dev/mapper/rhel-root ro \
  audit=1 audit_backlog_limit=32768 selinux=1 enforcing=1

$ sudo grubby --update-kernel=ALL --args="audit=1 audit_backlog_limit=32768"
$ sudo grub2-mkconfig -o /boot/grub2/grub.cfg
```

Sin `audit=1`, el subsistema se activa recién cuando `auditd` arranca; toda la actividad de `initramfs` y del arranque temprano de systemd queda fuera. Es un hallazgo estándar de los perfiles STIG y CIS.

---

## 4. AIDE: File Integrity Monitoring

### 4.1 Modelo de funcionamiento

```
   BUILD / BASELINE                        RUNTIME
 ┌───────────────────┐              ┌────────────────────┐
 │ aide --init       │              │ aide --check       │
 │  lee aide.conf    │              │  lee aide.conf     │
 │  recorre el FS    │   aide.db    │  recorre el FS     │
 │  calcula atributos├─────────────▶│  compara vs DB     │
 │  + hashes         │  (firmada,   │  emite report      │
 │  escribe .db.new  │   fuera del  │  exit code ≠ 0     │
 └───────────────────┘   host)      └────────────────────┘
```

El fichero de configuración define **grupos de atributos** y luego **selection lines** que asocian rutas a grupos.

| Selector | Significado |
|---|---|
| `/ruta GRUPO` | Regla normal: incluir la ruta (regex, anclada al inicio) con esos atributos |
| `=/ruta GRUPO` | *Equals*: solo ese directorio, sin descender |
| `!/ruta` | *Negative*: excluir por completo |
| `@@define VAR val` | Macro |
| `@@include /path` | Incluir otro fichero de configuración |
| `@@x_include /dir` | Incluir salida de ejecutables (0.17+) |

**Atributos disponibles:**

| Letra | Atributo | Notas |
|---|---|---|
| `p` | permisos | |
| `i` | inode | ruidoso con gestores de paquetes |
| `n` | número de links | |
| `u` / `g` | owner / group | |
| `s` | tamaño | |
| `b` | block count | |
| `m` / `a` / `c` | mtime / atime / ctime | `a` es **muy** ruidoso sin `relatime` |
| `S` | comprobar solo si el tamaño **creció** | para logs |
| `l` | link name | |
| `ftype` | tipo de fichero | detecta reemplazo de fichero por symlink |
| `acl` | POSIX ACL | |
| `selinux` | contexto SELinux | |
| `xattrs` | extended attributes | incluye capabilities de fichero |
| `e2fsattrs` | atributos ext2/3/4 (`chattr`) | detecta `+i` puesto por un atacante |
| `md5 sha1 sha256 sha512 rmd160 tiger haval whirlpool gost crc32` | hashes | |

**Grupos predefinidos:** `R` (`p+i+n+u+g+s+m+c+acl+selinux+xattrs+md5`), `L` (`p+i+n+u+g+acl+selinux+xattrs`), `>` (log creciente: `p+u+g+i+n+S+acl+selinux+xattrs`), `E` (vacío), `H` (todos los hashes compilados), `X` (`acl+selinux+xattrs`).

### 4.2 `aide.conf` de producción, completo

```bash
# /etc/aide/aide.conf — AIDE 0.18.x
# Perfil: nodo de producción, baseline generado en build, verificado por timer.

#=============================================================================
# 1. Ubicación de la base de datos
#=============================================================================
# Sintaxis 0.17+ (en 0.16 y anteriores: 'database=' y 'database_out=')
database_in  = file:/var/lib/aide/aide.db.gz
database_out = file:/var/lib/aide/aide.db.new.gz
database_new = file:/var/lib/aide/aide.db.new.gz

gzip_dbout = yes

# Añade el nombre del atributo a la salida — imprescindible para el diff.
database_attrs = sha512

#=============================================================================
# 2. Reporte
#=============================================================================
# 0.17+ reemplazó 'verbose=N' por este par. Si la distro trae 0.16, usar
# 'verbose=6' y 'report_URL' (mayúsculas).
log_level    = warning
report_level = changed_attributes

# Se pueden declarar varios destinos; se escriben todos.
report_url = file:/var/log/aide/aide-check.log
report_url = stdout
# report_url = syslog:LOG_LOCAL0
# report_url = /usr/local/bin/aide-to-siem   (URL 'fd:' o pipe según build)

report_summarize_changes = yes
report_grouped           = yes
report_detailed_init     = no
report_base16            = no
report_quiet             = no
report_append            = yes

#=============================================================================
# 3. Grupos de atributos
#=============================================================================
@@define TOPDIR /

# Binarios y librerías: todo, incluido el hash fuerte y los xattrs
# (los xattrs capturan las file capabilities: security.capability).
BINLIB   = p+i+n+u+g+s+b+m+c+ftype+acl+selinux+xattrs+e2fsattrs+sha512

# Configuración: igual, pero sin inode (los editores reescriben el fichero).
CONF     = p+n+u+g+s+m+c+ftype+acl+selinux+xattrs+e2fsattrs+sha512

# Solo contenido: para ficheros que legítimamente cambian de metadatos.
DATAONLY = p+n+u+g+s+acl+selinux+xattrs+sha512

# Directorios: metadatos, sin hash (un directorio no tiene contenido hashable).
DIR      = p+i+n+u+g+acl+selinux+xattrs

# Solo permisos y propietario.
PERMS    = p+i+u+g+acl+selinux+xattrs

# Logs: solo se admite crecimiento; cualquier truncado se reporta.
LOG      = p+u+g+n+S+acl+selinux+xattrs

# Ficheros que rotan o cambian sin control: presencia y permisos únicamente.
STATIC   = p+u+g+ftype

#=============================================================================
# 4. Selection lines — el orden NO importa, gana la coincidencia más larga
#=============================================================================

# --- Binarios del sistema --------------------------------------------------
/boot/                 BINLIB
/bin/                  BINLIB
/sbin/                 BINLIB
/lib/                  BINLIB
/lib64/                BINLIB
/usr/bin/              BINLIB
/usr/sbin/             BINLIB
/usr/lib/              BINLIB
/usr/lib64/            BINLIB
/usr/libexec/          BINLIB
/usr/local/bin/        BINLIB
/usr/local/sbin/       BINLIB
/usr/local/lib/        BINLIB
/opt/                  BINLIB

# --- Configuración ---------------------------------------------------------
/etc/                  CONF

# --- Módulos del kernel ----------------------------------------------------
/usr/lib/modules/      BINLIB
/etc/modprobe.d/       CONF
/etc/modules-load.d/   CONF

# --- Persistencia ----------------------------------------------------------
/etc/systemd/          CONF
/usr/lib/systemd/system/  CONF
/etc/cron.d/           CONF
/etc/cron.daily/       CONF
/etc/cron.hourly/      CONF
/etc/cron.weekly/      CONF
/etc/cron.monthly/     CONF
/var/spool/cron/       CONF
/etc/crontab           CONF
/root/                 CONF

# --- Logs: crecimiento monótono -------------------------------------------
/var/log/              LOG
/var/log/audit/        LOG

# --- Bases de datos de paquetes: cambian con cada actualización ------------
/var/lib/rpm/          DATAONLY
/var/lib/dpkg/         DATAONLY

#=============================================================================
# 5. Exclusiones — sin ellas el check nunca termina
#=============================================================================
# Pseudo-filesystems
!/proc
!/sys
!/dev
!/run
!/tmp
!/var/tmp

# Volátiles del sistema
!/var/lib/aide/aide\.db.*
!/var/log/aide/.*
!/var/lib/systemd/random-seed$
!/var/lib/systemd/timers/.*
!/var/lib/NetworkManager/.*
!/var/lib/chrony/.*
!/etc/machine-id$
!/etc/mtab$
!/etc/resolv\.conf$
!/etc/adjtime$
!/etc/lvm/archive/.*
!/etc/lvm/backup/.*
!/etc/blkid/.*
!/etc/.*\.swp$
!/etc/.*~$

# Contenedores: overlayfs y estado del runtime (volumen enorme, nulo valor)
!/var/lib/containerd/.*
!/var/lib/docker/.*
!/var/lib/kubelet/.*
!/var/lib/containers/.*
!/run/containerd/.*

# Cachés
!/var/cache/.*
!/usr/share/mime/.*
!/var/lib/sss/.*
```

### 4.3 Ciclo de vida operativo

```console
# 0. Validar la sintaxis SIN tocar el filesystem
$ sudo aide --config-check --config /etc/aide/aide.conf
$ echo $?
0

# 1. Construir el baseline (en la build de la imagen, no en el nodo vivo)
$ sudo aide --init --config /etc/aide/aide.conf
Start timestamp: 2026-08-24 09:02:11 -0300 (AIDE 0.18.6)
AIDE initialized database at /var/lib/aide/aide.db.new.gz

Number of entries:      98431

---------------------------------------------------
The attributes of the (uncompressed) database(s):
---------------------------------------------------

/var/lib/aide/aide.db.new.gz
  SHA512   : 0Q9j2mZ0xr9J3wIYYq2t8m0YXkP3l3aH
             Uq0m2s9hR1ZVxCq7pW9m4nD8sT1yYzQ3
             1kM4b7V2sN8pQ0

End timestamp: 2026-08-24 09:07:48 -0300 (run time: 5m 37s)

# 2. Promover a base de datos activa
$ sudo mv /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz

# 3. Firmar el baseline y sacarlo del host
$ sudo gpg --batch --yes --detach-sign --armor \
      --local-user fim-baseline@example.net \
      /var/lib/aide/aide.db.gz
$ sudo sha256sum /var/lib/aide/aide.db.gz | tee /var/lib/aide/aide.db.sha256
9f4c1a0b6d2e78ff3c5a41b8e097d6a2f13b7c8e05d9a2f4c6b1e3d7a8905c2f  /var/lib/aide/aide.db.gz
$ aws s3 cp /var/lib/aide/aide.db.gz     s3://fim-baselines/$(hostname -f)/
$ aws s3 cp /var/lib/aide/aide.db.gz.asc s3://fim-baselines/$(hostname -f)/
```

**Verificación periódica:**

```console
$ sudo aide --check --config /etc/aide/aide.conf
Start timestamp: 2026-08-24 11:31:07 -0300 (AIDE 0.18.6)
AIDE found differences between database and filesystem!!

Summary:
  Total number of entries:      98432
  Added entries:                1
  Removed entries:              0
  Changed entries:              2

---------------------------------------------------
Added entries:
---------------------------------------------------

f+++++++++++++++++: /usr/local/sbin/.sysupdate

---------------------------------------------------
Changed entries:
---------------------------------------------------

f  ...   . ..C.. .: /etc/ssh/sshd_config
f  ...   . mc..  .: /usr/bin/find

---------------------------------------------------
Detailed information about changes:
---------------------------------------------------

File: /etc/ssh/sshd_config
  SHA512   : Nkq0P2mT1s8Rl9zQ4wYb7C6xVdA0eK3f  | 8Bz1Wq7pR0mL3nT6yF2sX9cV4dH5jK1a
             ...                                | ...
  Size     : 3669                               | 3712
  Ctime    : 2026-06-14 02:11:03 -0300          | 2026-08-24 11:22:41 -0300

File: /usr/bin/find
  SHA512   : Qw3rT7yU1iO9pA2sD5fG8hJ0kL4zX6cV  | Zx1Cv4bN7mQ0wE3rT6yU9iO2pA5sD8fG
             ...                                | ...
  Mtime    : 2025-11-02 07:44:19 -0300          | 2026-08-24 11:19:56 -0300
  Ctime    : 2026-06-14 02:11:03 -0300          | 2026-08-24 11:19:56 -0300

End timestamp: 2026-08-24 11:36:52 -0300 (run time: 5m 45s)

$ echo $?
7
```

**Códigos de salida de `aide --check` — son un campo de bits, esencial para automatización:**

| Bit | Valor | Significado |
|---|---|---|
| 0 | 1 | Se encontraron **new files** |
| 1 | 2 | Se encontraron **removed files** |
| 2 | 4 | Se encontraron **changed files** |
| — | 14 | Error de escritura |
| — | 15 | Error de argumentos inválidos |
| — | 16 | Función no implementada |
| — | 17 | Error de configuración |
| — | 18 | Error de I/O |
| — | 19 | Error de versión |

`exit 7` = `1|2|4` no; en el ejemplo `1 (added) | 4 (changed) = 5`. El `7` aparece cuando además hay removidos. **Nunca escribir `aide --check || alert` sin desglosar los bits**: un error de configuración (17) y un cambio detectado (4) son incidentes distintos.

```bash
#!/usr/bin/env bash
# /usr/local/bin/aide-check-wrapper
set -uo pipefail
out="$(mktemp)"
/usr/sbin/aide --check --config /etc/aide/aide.conf >"$out" 2>&1
rc=$?
case $rc in
  0)  logger -t aide -p auth.info  "FIM clean" ;;
  1|2|4|3|5|6|7)
      logger -t aide -p auth.crit  "FIM DIFF (rc=$rc)"
      logger -t aide -p auth.crit -f "$out" ;;
  *)  logger -t aide -p auth.err   "FIM ERROR rc=$rc"
      logger -t aide -p auth.err  -f "$out" ;;
esac
rm -f "$out"
exit $rc
```

**Actualización controlada tras un cambio legítimo:**

```console
$ sudo aide --update --config /etc/aide/aide.conf
$ sudo mv /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz
```

**Verificación parcial (rápida, para checks frecuentes):**

```console
$ sudo aide --check --limit '^/etc/(ssh|sudoers|pam\.d)' --config /etc/aide/aide.conf
Start timestamp: 2026-08-24 11:58:02 -0300 (AIDE 0.18.6)
Limit: ^/etc/(ssh|sudoers|pam\.d)
AIDE found NO differences between database and filesystem. Looks okay!!

Number of entries: 214

End timestamp: 2026-08-24 11:58:03 -0300 (run time: 0m 1s)
```

**Comparar dos bases de datos (0.17+) — comparar el nodo contra el baseline de la imagen:**

```console
$ sudo aide --compare \
    --config /etc/aide/aide.conf \
    --before 'database_in=file:/var/lib/aide/golden-image.db.gz' \
    --after  'database_in=file:/var/lib/aide/aide.db.gz'
```

### 4.4 Unidades systemd completas

```ini
# /etc/systemd/system/aide-check.service
[Unit]
Description=AIDE file integrity check
Documentation=man:aide(1)
After=local-fs.target auditd.service
ConditionPathExists=/var/lib/aide/aide.db.gz

[Service]
Type=oneshot
ExecStartPre=/usr/local/bin/aide-verify-baseline
ExecStart=/usr/local/bin/aide-check-wrapper
SuccessExitStatus=0 1 2 3 4 5 6 7

# El scan es I/O-bound y compite con la carga productiva.
Nice=19
IOSchedulingClass=idle
CPUSchedulingPolicy=idle
CPUQuota=40%
IOWeight=10

# Endurecimiento del propio servicio.
PrivateTmp=yes
ProtectHome=read-only
ProtectSystem=strict
ReadWritePaths=/var/lib/aide /var/log/aide
NoNewPrivileges=yes
CapabilityBoundingSet=CAP_DAC_READ_SEARCH CAP_SYS_ADMIN
RestrictSUIDSGID=yes
MemoryDenyWriteExecute=yes
SystemCallFilter=@system-service
SystemCallArchitectures=native

TimeoutStartSec=3600

[Install]
WantedBy=multi-user.target
```

```ini
# /etc/systemd/system/aide-check.timer
[Unit]
Description=Run AIDE integrity check daily (randomised)

[Timer]
OnCalendar=*-*-* 03:00:00
RandomizedDelaySec=3600
AccuracySec=1min
Persistent=true
Unit=aide-check.service

[Install]
WantedBy=timers.target
```

```bash
#!/usr/bin/env bash
# /usr/local/bin/aide-verify-baseline
# Rechaza correr el check si la DB no coincide con la firma fuera de banda.
set -euo pipefail

DB=/var/lib/aide/aide.db.gz
SIG=/var/lib/aide/aide.db.gz.asc
KEYRING=/etc/aide/fim-baseline.gpg

if ! gpgv --keyring "$KEYRING" "$SIG" "$DB" 2>/dev/null; then
    logger -t aide -p auth.crit "BASELINE SIGNATURE INVALID — check aborted"
    exit 1
fi
logger -t aide -p auth.info "baseline signature OK"
```

```console
$ sudo systemctl enable --now aide-check.timer
Created symlink /etc/systemd/system/timers.target.wants/aide-check.timer → /etc/systemd/system/aide-check.timer.

$ systemctl list-timers aide-check.timer
NEXT                        LEFT       LAST                        PASSED  UNIT             ACTIVATES
Tue 2026-08-25 03:41:22 -03 15h 44min  Mon 2026-08-24 03:18:07 -03 8h ago  aide-check.timer aide-check.service
```

---

## 5. rkhunter, chkrootkit y Linux Malware Detect

### 5.1 rkhunter

**Configuración de producción (`/etc/rkhunter.conf.local`, que sobreescribe el principal):**

```bash
# /etc/rkhunter.conf.local

#--- Actualización de la base de firmas -------------------------------------
UPDATE_MIRRORS=1
MIRRORS_MODE=0
WEB_CMD=""
# WEB_CMD="" fuerza el uso interno de wget/curl. En Debian el default
# "/bin/false" DESHABILITA --update en silencio: es el fallo número uno.

#--- Reporte ----------------------------------------------------------------
MAIL-ON-WARNING=soc@example.net
MAIL_CMD=mail -s "[rkhunter] Warning on ${HOST_NAME}"
AUTO_X_DETECT=1
COLOR_SET2=0
USE_SYSLOG=authpriv.notice
APPEND_LOG=1
LOGFILE=/var/log/rkhunter.log

#--- Base de datos de propiedades de ficheros -------------------------------
HASH_CMD=SHA256
HASH_FLD_IDX=1
PKGMGR=RPM
# PKGMGR=RPM|DPKG|BSD|SOLARIS|NONE
# Con PKGMGR configurado, rkhunter valida los hashes contra el gestor de
# paquetes en lugar de contra su propia DB: sobrevive a las actualizaciones
# sin generar avalanchas de falsos positivos.

#--- Chequeos habilitados ---------------------------------------------------
DISABLE_TESTS=suspscan hidden_ports deleted_files
ENABLE_TESTS=ALL

#--- Whitelisting justificado (cada línea necesita un ticket) ---------------
# Los scripts de Perl del sistema disparan 'script replacement' de forma
# rutinaria en RHEL; verificado contra rpm -V el 2026-07-02, ticket SEC-4412.
SCRIPTWHITELIST=/usr/bin/egrep
SCRIPTWHITELIST=/usr/bin/fgrep
SCRIPTWHITELIST=/usr/bin/ldd
SCRIPTWHITELIST=/usr/bin/which

# El agente de observabilidad abre un puerto alto y usa un fichero oculto.
ALLOWHIDDENDIR=/etc/.java
ALLOWHIDDENFILE=/usr/share/man/man1/..1.gz
ALLOWDEVFILE=/dev/shm/pulse-shm-*

# Puertos legítimos: puerto/protocolo/comentario
PORT_WHITELIST=TCP:9100
PORT_WHITELIST=TCP:10250

#--- SSH --------------------------------------------------------------------
ALLOW_SSH_ROOT_USER=no
ALLOW_SSH_PROT_V1=0
SSH_CONFIG_DIR=/etc/ssh

#--- Endurecimiento del propio rkhunter -------------------------------------
COPY_LOG_ON_ERROR=1
PHALANX2_DIRTEST=0
INETD_ALLOWED_SVC=
SUPPRESS_DEPRECATION_WARNINGS=1
```

**Operación:**

```console
# Actualizar la base de firmas (requiere red)
$ sudo rkhunter --update
[ Rootkit Hunter version 1.4.6 ]

Checking rkhunter data files...
  Checking file mirrors.dat                                  [ No update ]
  Checking file programs_bad.dat                             [ Updated ]
  Checking file backdoorports.dat                            [ No update ]
  Checking file suspscan.dat                                 [ Updated ]
  Checking file i18n versions                                [ Updated ]

# Comprobar si hay una versión nueva del propio rkhunter
$ sudo rkhunter --versioncheck
[ Rootkit Hunter version 1.4.6 ]

Checking rkhunter version...
  This version  : 1.4.6
  Latest version: 1.4.6

# Inicializar la base de propiedades de ficheros (SOLO en sistema limpio)
$ sudo rkhunter --propupd
[ Rootkit Hunter version 1.4.6 ]
File updated: searched for 178 files, found 152

# Chequeo completo, sin pausas, solo advertencias
$ sudo rkhunter --check --skip-keypress --report-warnings-only
Warning: The file properties have changed:
         File: /usr/bin/lwp-request
         Current hash: 6b4dfd28f77b53bd2e2b4a5f0a2b8c9d1e3f5a7b9c1d3e5f7a9b1c3d5e7f9a1b
         Stored hash : 3a95d0e2c4b6a8f0d2e4c6b8a0f2d4e6c8b0a2f4d6e8c0b2a4f6d8e0c2b4a6f8
         Current inode: 4271933    Stored inode: 4271901
         Current file modification time: 1756033441 (24-Aug-2026 11:04:01)
         Stored file modification time : 1749518402 (09-Jun-2026 22:00:02)
Warning: Suspicious file types found in /dev:
         /dev/shm/.x11-unix: ASCII text
Warning: Hidden directory found: /etc/.hidden

System checks summary
=====================

File properties checks...
    Files checked: 152
    Suspect files: 1

Rootkit checks...
    Rootkits checked : 501
    Possible rootkits: 0

Applications checks...
    All checks skipped

The system checks took: 2 minutes and 14 seconds

All results have been written to the log file: /var/log/rkhunter.log

One or more warnings have been found while checking the system.
Please check the log file (/var/log/rkhunter.log)

$ echo $?
1
```

**Códigos de salida de `rkhunter --check`:** `0` = sin avisos, `1` = uno o más warnings, `2` = error de ejecución (o `--versioncheck` con versión nueva disponible).

> **La trampa de `--propupd`:** ejecutarlo después de un compromiso graba los hashes del backdoor como legítimos y borra la evidencia. Regla operativa: `--propupd` **solo** desde el pipeline de build, o inmediatamente después de una actualización de paquetes verificada con `rpm -Va` / `debsums -c`, y **nunca** desde un cron automático.

### 5.2 chkrootkit

```console
$ sudo chkrootkit -q
/usr/lib/debug/.dwz
/usr/lib/.build-id
eth0: PACKET SNIFFER(/usr/sbin/NetworkManager[912])
Checking `bindshell'... INFECTED (PORTS:  465)

$ sudo chkrootkit | tail -30
Checking `chkutmp'...                                        not infected
Checking `OSX_RSPLUG'...                                     not infected
Checking `asp'...                                            not infected
Checking `bindshell'...                                      INFECTED (PORTS: 465)
Checking `lkm'...                                            chkproc: nothing detected
                                                             chkdirs: nothing detected
Checking `rexedcs'...                                        not found
Checking `sniffer'...                                        eth0: PACKET SNIFFER(/usr/sbin/NetworkManager[912])
Checking `w55808'...                                         not infected
Checking `wted'...                                           chkwtmp: nothing deleted
Checking `scalper'...                                        not infected
Checking `slapper'...                                        not infected
Checking `z2'...                                             chklastlog: nothing deleted
Checking `chkutmp'...                                        chkutmp: nothing deleted
```

**Los dos falsos positivos que aparecen siempre:**

- `bindshell INFECTED (PORTS: 465)` — el puerto 465 (SMTPS) escuchado por Postfix coincide con la lista de puertos de backdoor conocidos. Se descarta con `ss -tlnp sport = :465`.
- `PACKET SNIFFER(...NetworkManager)` — NetworkManager abre un socket `AF_PACKET` para DHCP. Legítimo.

**Modo forense desde medio externo** — la única forma confiable de correrlo sobre un sistema sospechoso:

```console
# Disco sospechoso montado en /mnt/victima desde un live USB
$ sudo chkrootkit -r /mnt/victima -p /bin:/usr/bin -q
```

`-r` cambia la raíz de análisis; `-p` indica desde dónde tomar los binarios **confiables** (`ps`, `ls`, `netstat`, `awk`, `strings`) — el del medio externo, no el de la víctima.

### 5.3 Linux Malware Detect (maldet)

```bash
# /usr/local/maldetect/conf.maldet

# --- Alertas ---------------------------------------------------------------
email_alert="1"
email_addr="soc@example.net"
email_subj="maldet alert on $(hostname)"
email_ignore_clean="1"

# --- Actualización de firmas -----------------------------------------------
autoupdate_signatures="1"
autoupdate_version="1"
autoupdate_version_hashed="1"

# --- Cuarentena ------------------------------------------------------------
quarantine_hits="1"
# 0 = solo alertar (modo de despliegue inicial, siempre empezar así)
# 1 = mover a cuarentena automáticamente
quarantine_clean="0"
# La limpieza automática de webshells inyectadas rompe ficheros legítimos.
quarantine_suspend_user="0"
quarantine_suspend_user_minuid="500"

# --- Motor de escaneo ------------------------------------------------------
scan_max_depth="15"
scan_min_filesize="24"
scan_max_filesize="2048k"
scan_hexdepth="61440"
scan_hexfifo="0"
scan_clamscan="1"
# Con ClamAV instalado, maldet usa clamscan como motor y sus PROPIAS firmas:
# gana ~4x de velocidad y suma la cobertura de ClamAV.
scan_ignore_root="0"
scan_cpunice="19"
scan_ionice="6"
scan_tmpdir="/var/tmp"

# --- Monitorización en tiempo real (inotify) -------------------------------
default_monitor_mode="/home,/var/www,/srv/uploads"
inotify_base_watches="80000"
inotify_stime="30"
inotify_nice="15"
inotify_docroot="public_html"
inotify_webadmin="1"
inotify_webadmin_users_only="0"

# --- Retención -------------------------------------------------------------
quarantine_max_days="60"
scan_export_filelog="1"
```

```console
# Actualizar motor y firmas
$ sudo maldet -d && sudo maldet -u
Linux Malware Detect v1.6.5
            (C) 2002-2024, R-fx Networks <proj@rfxn.com>

maldet(48122): {sigup} performing signature update check...
maldet(48122): {sigup} local signature set is version 2024122115757
maldet(48122): {sigup} new signature set (2025071033112) available
maldet(48122): {sigup} downloaded https://cdn.rfxn.com/downloads/maldet-sigpack.tgz
maldet(48122): {sigup} verified md5sum of maldet-sigpack.tgz
maldet(48122): {sigup} unpacked and installed maldet-sigpack.tgz
maldet(48122): {sigup} signature set update completed
maldet(48122): {sigup} 17162 signatures (13239 MD5 | 3923 HEX | 0 USER)

# Escaneo puntual
$ sudo maldet -a /var/www
Linux Malware Detect v1.6.5

maldet(48310): {scan} signatures loaded: 17162 (13239 MD5 | 3923 HEX | 0 USER)
maldet(48310): {scan} building file list for /var/www, this might take awhile...
maldet(48310): {scan} setting nice scheduler priorities for all operations: cpunice 19, ionice 6
maldet(48310): {scan} file list completed in 4s, found 21894 files...
maldet(48310): {scan} found clamav binary at /usr/bin/clamscan, using clamav scanner engine...
maldet(48310): {scan} scan of /var/www (21894 files) in progress...
maldet(48310): {scan} 21894/21894 files scanned: 2 hits 0 cleaned

maldet(48310): {scan} scan completed on /var/www: files 21894, malware hits 2, cleaned hits 0, time 213s
maldet(48310): {scan} scan report saved, to view run: maldet --report 260824-1142.48310

$ sudo maldet --report 260824-1142.48310
malware detect scan report for nodo-web-03.prod.example.net:
SCAN ID: 260824-1142.48310
TIME: Aug 24 11:45:41 -0300
PATH: /var/www
TOTAL FILES: 21894
TOTAL HITS: 2
TOTAL CLEANED: 0

FILE HIT LIST:
{HEX}php.base64.v23qtp.174 : /var/www/html/wp-content/uploads/2026/07/thumb.php
{MD5}php.cmdshell.unclassed.359 : /var/www/html/vendor/.cache/x.php

# Habilitar el monitor en tiempo real
$ sudo maldet -m /var/www
maldet(48401): {mon} added /var/www to inotify monitoring array
maldet(48401): {mon} starting inotify process, monitoring 1 paths
maldet(48401): {mon} inotify startup successful (pid: 48409)

$ sudo systemctl enable --now maldet
$ sudo systemctl status maldet --no-pager
● maldet.service - Linux Malware Detect Monitoring Service
     Loaded: loaded (/usr/lib/systemd/system/maldet.service; enabled)
     Active: active (running) since Mon 2026-08-24 11:52:03 -03; 12s ago
   Main PID: 48409 (inotifywait)
      Tasks: 3 (limit: 38312)
     Memory: 42.1M
```

> **Dimensionamiento de inotify:** `inotify_base_watches="80000"` requiere que `fs.inotify.max_user_watches` sea al menos ese valor. Cada watch consume ~1 KB de memoria de kernel no paginable. En un servidor con millones de ficheros en `/var/www`, el monitor en tiempo real **no escala**: hay que restringirlo a los directorios de upload.

---

## 6. OpenSCAP: evaluación de postura y compliance

### 6.1 Instalación y contenido

```console
$ sudo dnf install -y openscap-scanner scap-security-guide openscap-utils
$ rpm -ql scap-security-guide | grep '\-ds\.xml$'
/usr/share/xml/scap/ssg/content/ssg-rhel8-ds.xml
/usr/share/xml/scap/ssg/content/ssg-rhel9-ds.xml
/usr/share/xml/scap/ssg/content/ssg-rhel10-ds.xml
/usr/share/xml/scap/ssg/content/ssg-firefox-ds.xml

# Debian/Ubuntu
$ sudo apt install -y libopenscap8 ssg-debian ssg-applications
```

### 6.2 Inspección del contenido

```console
$ oscap info /usr/share/xml/scap/ssg/content/ssg-rhel9-ds.xml
Document type: Source Data Stream
Imported: 2026-05-19T10:22:34

Stream: scap_org.open-scap_datastream_from_xccdf_ssg-rhel9-xccdf-1.2.xml
Generated: (null)
Version: 1.3
Checklists:
	Ref-Id: scap_org.open-scap_cref_ssg-rhel9-xccdf-1.2.xml
		Status: draft
		Generated: 2026-05-19
		Resolved: true
		Profiles:
			Title: ANSSI-BP-028 (enhanced)
				Id: xccdf_org.ssgproject.content_profile_anssi_bp28_enhanced
			Title: ANSSI-BP-028 (high)
				Id: xccdf_org.ssgproject.content_profile_anssi_bp28_high
			Title: CIS Red Hat Enterprise Linux 9 Benchmark for Level 2 - Server
				Id: xccdf_org.ssgproject.content_profile_cis
			Title: CIS Red Hat Enterprise Linux 9 Benchmark for Level 1 - Server
				Id: xccdf_org.ssgproject.content_profile_cis_server_l1
			Title: DISA STIG for Red Hat Enterprise Linux 9
				Id: xccdf_org.ssgproject.content_profile_stig
			Title: PCI-DSS v4.0 Control Baseline for RHEL 9
				Id: xccdf_org.ssgproject.content_profile_pci-dss
			Title: Health Insurance Portability and Accountability Act (HIPAA)
				Id: xccdf_org.ssgproject.content_profile_hipaa
		Referenced check files:
			ssg-rhel9-oval.xml
				system: http://oval.mitre.org/XMLSchema/oval-definitions-5
			ssg-rhel9-ocil.xml
				system: http://scap.nist.gov/schema/ocil/2
Checks:
	Ref-Id: scap_org.open-scap_cref_ssg-rhel9-oval.xml
	Ref-Id: scap_org.open-scap_cref_ssg-rhel9-ocil.xml
	Ref-Id: scap_org.open-scap_cref_ssg-rhel9-cpe-oval.xml
Dictionaries:
	Ref-Id: scap_org.open-scap_cref_ssg-rhel9-cpe-dictionary.xml

$ oscap info --profile xccdf_org.ssgproject.content_profile_cis_server_l1 \
      /usr/share/xml/scap/ssg/content/ssg-rhel9-ds.xml
Document type: Source Data Stream
Imported: 2026-05-19T10:22:34

Profile
	Title: CIS Red Hat Enterprise Linux 9 Benchmark for Level 1 - Server
	Id: xccdf_org.ssgproject.content_profile_cis_server_l1
	Description: This profile defines a baseline that aligns to the "Level 1 - Server"
	             configuration from the Center for Internet Security® Red Hat
	             Enterprise Linux 9 Benchmark™, v2.0.0.
	Selected rules: 274
```

### 6.3 Evaluación

```console
$ sudo oscap xccdf eval \
    --profile xccdf_org.ssgproject.content_profile_cis_server_l1 \
    --results-arf /var/lib/oscap/arf-$(date +%Y%m%d).xml \
    --report      /var/lib/oscap/report-$(date +%Y%m%d).html \
    --oval-results \
    /usr/share/xml/scap/ssg/content/ssg-rhel9-ds.xml

Title   Ensure gpgcheck Enabled In Main dnf Configuration
Rule    xccdf_org.ssgproject.content_rule_ensure_gpgcheck_globally_activated
Ident   CCE-83455-1
Result  pass

Title   Enable auditd Service
Rule    xccdf_org.ssgproject.content_rule_service_auditd_enabled
Ident   CCE-83771-1
Result  pass

Title   Record Events that Modify User/Group Information
Rule    xccdf_org.ssgproject.content_rule_audit_rules_usergroup_modification_shadow
Ident   CCE-83722-4
Result  pass

Title   Install AIDE
Rule    xccdf_org.ssgproject.content_rule_package_aide_installed
Ident   CCE-83438-7
Result  pass

Title   Configure Periodic Execution of AIDE
Rule    xccdf_org.ssgproject.content_rule_aide_periodic_cron_checking
Ident   CCE-83437-9
Result  fail

Title   Disable SSH Root Login
Rule    xccdf_org.ssgproject.content_rule_sshd_disable_root_login
Ident   CCE-83618-4
Result  fail

Title   Set SSH Client Alive Count Max
Rule    xccdf_org.ssgproject.content_rule_sshd_set_keepalive
Ident   CCE-80906-1
Result  notapplicable

Title   Verify Firewalld Enabled
Rule    xccdf_org.ssgproject.content_rule_service_firewalld_enabled
Ident   CCE-80877-4
Result  fail

$ echo $?
2
```

**Códigos de salida de `oscap xccdf eval` — el detalle que rompe los pipelines de CI:**

| Código | Significado |
|---|---|
| `0` | Todas las reglas evaluadas dieron `pass`/`notapplicable`/`notchecked`/`informational` |
| `1` | **Error** del scanner (contenido inválido, perfil inexistente, I/O) |
| `2` | Al menos una regla dio `fail` o `error` |

```bash
# El patrón correcto en CI: distinguir "el scanner falló" de "el host falló"
oscap xccdf eval --profile "$PROFILE" --results-arf arf.xml "$DS"
rc=$?
case $rc in
  0) echo "COMPLIANT" ;;
  2) echo "NON-COMPLIANT"; exit 1 ;;
  *) echo "SCANNER ERROR (rc=$rc)"; exit 99 ;;
esac
```

**Resultados posibles por regla:**

| Resultado | Significado | Acción |
|---|---|---|
| `pass` | Cumple | — |
| `fail` | No cumple | Remediar |
| `error` | El check no pudo ejecutarse | **Investigar** — no es un pass |
| `unknown` | Resultado indeterminado | Investigar |
| `notapplicable` | La plataforma (CPE) no aplica | Normal |
| `notchecked` | Sin check automático definido (típicamente OCIL) | Revisión manual |
| `notselected` | Fuera del perfil | — |
| `informational` | Solo informa | Leer |
| `fixed` | Corregida por `--remediate` | Re-verificar |

### 6.4 Tailoring: adaptar un perfil sin bifurcarlo

**Con `autotailor` (parte de `openscap-utils`), reproducible en Git:**

```console
$ autotailor \
    --title "CIS L1 Server — Perfil corporativo Example" \
    --id-namespace net.example.compliance \
    --profile-id xccdf_org.ssgproject.content_profile_cis_server_l1 \
    --new-profile-id xccdf_net.example.compliance_profile_cis_l1_example \
    --unselect-rule xccdf_org.ssgproject.content_rule_package_telnet_removed \
    --unselect-rule xccdf_org.ssgproject.content_rule_service_firewalld_enabled \
    --var-value var_password_pam_minlen=16 \
    --var-value var_accounts_maximum_age_login_defs=60 \
    --var-value var_auditd_space_left_percentage=10 \
    --output /etc/oscap/tailoring-example.xml \
    /usr/share/xml/scap/ssg/content/ssg-rhel9-ds.xml

$ sudo oscap xccdf eval \
    --profile xccdf_net.example.compliance_profile_cis_l1_example \
    --tailoring-file /etc/oscap/tailoring-example.xml \
    --results-arf /var/lib/oscap/arf.xml \
    --report /var/lib/oscap/report.html \
    /usr/share/xml/scap/ssg/content/ssg-rhel9-ds.xml
```

> **Regla de gobernanza:** cada `--unselect-rule` es una excepción de seguridad. El fichero de tailoring vive en Git, con el ticket de aprobación en el mensaje del commit. Un tailoring sin trazabilidad convierte el informe de compliance en teatro.

### 6.5 Remediación

```console
# 1. Generar el script SIN aplicarlo (siempre revisar antes)
$ oscap xccdf generate fix \
    --profile xccdf_org.ssgproject.content_profile_cis_server_l1 \
    --fix-type bash \
    /usr/share/xml/scap/ssg/content/ssg-rhel9-ds.xml > /tmp/remediate.sh

# 2. Generar un playbook de Ansible (preferible: idempotente y revisable)
$ oscap xccdf generate fix \
    --profile xccdf_org.ssgproject.content_profile_cis_server_l1 \
    --fix-type ansible \
    /usr/share/xml/scap/ssg/content/ssg-rhel9-ds.xml > cis-l1-remediation.yml

# 3. Remediar SOLO lo que falló en un scan concreto (mucho más quirúrgico)
$ oscap xccdf generate fix \
    --result-id "" \
    --fix-type ansible \
    /var/lib/oscap/arf-20260824.xml > cis-fails-only.yml

# 4. Remediación en línea (evaluar → corregir → re-evaluar)
$ sudo oscap xccdf eval --remediate \
    --profile xccdf_org.ssgproject.content_profile_cis_server_l1 \
    --results-arf /var/lib/oscap/arf-remediated.xml \
    /usr/share/xml/scap/ssg/content/ssg-rhel9-ds.xml
...
Title   Disable SSH Root Login
Rule    xccdf_org.ssgproject.content_rule_sshd_disable_root_login
Result  fail

--- Starting Remediation ---

Title   Disable SSH Root Login
Rule    xccdf_org.ssgproject.content_rule_sshd_disable_root_login
Result  fixed
```

> **`--remediate` en un host de producción es una operación destructiva.** Los perfiles STIG deshabilitan servicios, endurecen `sshd_config` y cambian políticas PAM. Ha dejado hosts sin acceso SSH. Flujo correcto: remediar en la **build de la imagen**, verificar en un entorno de staging, promover la imagen. En runtime solo se **evalúa**.

### 6.6 Escaneo offline: imágenes, contenedores y VMs

```console
# Contenedor / imagen (openscap-podman)
$ sudo oscap-podman registry.example.net/base/rhel9:2026.08 \
    xccdf eval \
    --profile xccdf_org.ssgproject.content_profile_cis_server_l1 \
    --report /tmp/image-report.html \
    /usr/share/xml/scap/ssg/content/ssg-rhel9-ds.xml

# Imagen de disco de VM montada (guestfs)
$ sudo oscap-vm image /var/lib/libvirt/images/nodo.qcow2 \
    xccdf eval --profile xccdf_org.ssgproject.content_profile_cis \
    --report /tmp/vm-report.html \
    /usr/share/xml/scap/ssg/content/ssg-rhel9-ds.xml

# Filesystem montado (chroot) — forense sobre un disco sospechoso
$ sudo oscap xccdf eval --chroot /mnt/victima \
    --profile xccdf_org.ssgproject.content_profile_cis \
    --report /tmp/forensic.html \
    /usr/share/xml/scap/ssg/content/ssg-rhel9-ds.xml

# Host remoto por SSH, sin instalar nada allí
$ oscap-ssh root@nodo-14.prod.example.net 22 \
    xccdf eval --profile xccdf_org.ssgproject.content_profile_cis_server_l1 \
    --report /tmp/nodo-14.html \
    /usr/share/xml/scap/ssg/content/ssg-rhel9-ds.xml
```

### 6.7 OVAL puro: detección de vulnerabilidades

XCCDF evalúa **configuración**; OVAL puro se usa para **parches faltantes**:

```console
$ curl -sSLO https://security.access.redhat.com/data/oval/v2/RHEL9/rhel-9.oval.xml.bz2
$ bunzip2 rhel-9.oval.xml.bz2

$ oscap oval eval --results /tmp/oval-results.xml \
      --report /tmp/vulns.html rhel-9.oval.xml
Definition oval:com.redhat.rhsa:def:20264411: true
Definition oval:com.redhat.rhsa:def:20264388: false
Definition oval:com.redhat.rhsa:def:20264301: true
...
Evaluation done.

# 'true' = el sistema ES VULNERABLE a ese RHSA.
$ grep -c 'true$' <(oscap oval eval rhel-9.oval.xml 2>/dev/null)
17
```

```console
# Validación del contenido antes de confiar en él
$ oscap ds sds-validate /usr/share/xml/scap/ssg/content/ssg-rhel9-ds.xml
$ echo $?
0

# Descomponer un datastream en sus componentes
$ oscap ds sds-split /usr/share/xml/scap/ssg/content/ssg-rhel9-ds.xml /tmp/split/
$ ls /tmp/split/
ssg-rhel9-cpe-dictionary.xml  ssg-rhel9-ocil.xml  ssg-rhel9-oval.xml  ssg-rhel9-xccdf.xml
```

---

## 7. Infraestructura completa: despliegue en flota

### 7.1 Ansible role — despliegue de auditd + AIDE

```yaml
---
# roles/hids/defaults/main.yml
hids_audit_backlog_limit: 32768
hids_audit_failure_mode: 1
hids_audit_immutable: true
hids_audit_remote_server: audit-collector.prod.example.net
hids_audit_remote_port: 60

hids_aide_enabled: true
hids_aide_baseline_source: "s3://fim-baselines"
hids_aide_check_oncalendar: "*-*-* 03:00:00"
hids_aide_randomized_delay: 3600

hids_oscap_profile: xccdf_org.ssgproject.content_profile_cis_server_l1
hids_oscap_datastream: /usr/share/xml/scap/ssg/content/ssg-rhel9-ds.xml
hids_oscap_scan_oncalendar: "Sun *-*-* 04:00:00"

hids_rkhunter_enabled: true
```

```yaml
---
# roles/hids/tasks/main.yml
- name: Install host intrusion detection packages
  ansible.builtin.package:
    name:
      - audit
      - audispd-plugins
      - aide
      - rkhunter
      - openscap-scanner
      - openscap-utils
      - scap-security-guide
    state: present
  tags: [hids, packages]

- name: Ensure early-boot auditing is enabled on the kernel command line
  ansible.builtin.command:
    cmd: >-
      grubby --update-kernel=ALL
      --args="audit=1 audit_backlog_limit={{ hids_audit_backlog_limit }}"
  register: hids_grubby
  changed_when: hids_grubby.rc == 0
  notify: reboot required
  tags: [hids, auditd]

# ---------------------------------------------------------------- auditd ----
- name: Deploy auditd.conf
  ansible.builtin.template:
    src: auditd.conf.j2
    dest: /etc/audit/auditd.conf
    owner: root
    group: root
    mode: "0640"
    validate: "/usr/sbin/auditd -f -c %s"
  notify: restart auditd
  tags: [hids, auditd]

- name: Remove distro-shipped rule fragments we do not manage
  ansible.builtin.file:
    path: "/etc/audit/rules.d/{{ item }}"
    state: absent
  loop:
    - audit.rules
    - 30-nispom.rules
    - 30-ospp-v42.rules
    - 30-pci-dss-v31.rules
    - 30-stig.rules
  notify: regenerate audit rules
  tags: [hids, auditd]

- name: Deploy managed audit rule fragments
  ansible.builtin.copy:
    src: "rules.d/{{ item }}"
    dest: "/etc/audit/rules.d/{{ item }}"
    owner: root
    group: root
    mode: "0600"
  loop:
    - 10-base-config.rules
    - 20-dont-audit.rules
    - 30-identity.rules
    - 31-privilege.rules
    - 32-access.rules
    - 33-modules.rules
    - 34-execution.rules
    - 35-persistence.rules
    - 40-mac-policy.rules
  notify: regenerate audit rules
  tags: [hids, auditd]

- name: Deploy immutability fragment last
  ansible.builtin.copy:
    content: "-e 2\n"
    dest: /etc/audit/rules.d/99-finalize.rules
    owner: root
    group: root
    mode: "0600"
  when: hids_audit_immutable | bool
  notify: regenerate audit rules
  tags: [hids, auditd]

- name: Configure remote audit shipping
  ansible.builtin.template:
    src: audisp-remote.conf.j2
    dest: /etc/audit/audisp-remote.conf
    owner: root
    group: root
    mode: "0640"
  notify: restart auditd
  tags: [hids, auditd]

- name: Enable the au-remote plugin
  ansible.builtin.copy:
    dest: /etc/audit/plugins.d/au-remote.conf
    owner: root
    group: root
    mode: "0640"
    content: |
      active = yes
      direction = out
      path = /sbin/audisp-remote
      type = always
      format = string
  notify: restart auditd
  tags: [hids, auditd]

- name: Enable auditd
  ansible.builtin.service:
    name: auditd
    enabled: true
    state: started
    # NOTE: auditd cannot be restarted via systemctl on RHEL; the handler
    # uses `service auditd restart`, which is the supported path.
    use: service
  tags: [hids, auditd]

# ------------------------------------------------------------------ AIDE ----
- name: Deploy aide.conf
  ansible.builtin.template:
    src: aide.conf.j2
    dest: /etc/aide/aide.conf
    owner: root
    group: root
    mode: "0600"
    validate: "/usr/sbin/aide --config-check --config %s"
  notify: rebuild aide database
  when: hids_aide_enabled | bool
  tags: [hids, aide]

- name: Create AIDE directories
  ansible.builtin.file:
    path: "{{ item }}"
    state: directory
    owner: root
    group: root
    mode: "0700"
  loop:
    - /var/lib/aide
    - /var/log/aide
  when: hids_aide_enabled | bool
  tags: [hids, aide]

- name: Install the baseline verification wrapper
  ansible.builtin.copy:
    src: aide-verify-baseline
    dest: /usr/local/bin/aide-verify-baseline
    owner: root
    group: root
    mode: "0750"
  when: hids_aide_enabled | bool
  tags: [hids, aide]

- name: Install the AIDE check wrapper
  ansible.builtin.copy:
    src: aide-check-wrapper
    dest: /usr/local/bin/aide-check-wrapper
    owner: root
    group: root
    mode: "0750"
  when: hids_aide_enabled | bool
  tags: [hids, aide]

- name: Deploy AIDE systemd units
  ansible.builtin.template:
    src: "{{ item }}.j2"
    dest: "/etc/systemd/system/{{ item }}"
    owner: root
    group: root
    mode: "0644"
  loop:
    - aide-check.service
    - aide-check.timer
  notify: daemon-reload
  when: hids_aide_enabled | bool
  tags: [hids, aide]

- name: Enable the AIDE timer
  ansible.builtin.systemd_service:
    name: aide-check.timer
    enabled: true
    state: started
    daemon_reload: true
  when: hids_aide_enabled | bool
  tags: [hids, aide]

# --------------------------------------------------------------- OpenSCAP ---
- name: Deploy the corporate tailoring file
  ansible.builtin.copy:
    src: tailoring-example.xml
    dest: /etc/oscap/tailoring-example.xml
    owner: root
    group: root
    mode: "0644"
  tags: [hids, oscap]

- name: Deploy the OpenSCAP scan units
  ansible.builtin.template:
    src: "{{ item }}.j2"
    dest: "/etc/systemd/system/{{ item }}"
    owner: root
    group: root
    mode: "0644"
  loop:
    - oscap-scan.service
    - oscap-scan.timer
  notify: daemon-reload
  tags: [hids, oscap]

- name: Enable the OpenSCAP timer
  ansible.builtin.systemd_service:
    name: oscap-scan.timer
    enabled: true
    state: started
    daemon_reload: true
  tags: [hids, oscap]

# --------------------------------------------------------------- rkhunter ---
- name: Deploy rkhunter local configuration
  ansible.builtin.template:
    src: rkhunter.conf.local.j2
    dest: /etc/rkhunter.conf.local
    owner: root
    group: root
    mode: "0640"
    validate: "/usr/bin/rkhunter --config-check --configfile %s"
  when: hids_rkhunter_enabled | bool
  tags: [hids, rkhunter]

- name: Initialise the rkhunter properties database (build time only)
  ansible.builtin.command:
    cmd: /usr/bin/rkhunter --propupd --nocolors
  when:
    - hids_rkhunter_enabled | bool
    - ansible_local.build_phase | default('runtime') == 'image-build'
  changed_when: true
  tags: [hids, rkhunter]
```

```yaml
---
# roles/hids/handlers/main.yml
- name: daemon-reload
  ansible.builtin.systemd_service:
    daemon_reload: true

- name: regenerate audit rules
  ansible.builtin.command:
    cmd: /usr/sbin/augenrules --load
  register: hids_augenrules
  changed_when: true
  failed_when:
    - hids_augenrules.rc != 0
    - "'Rules are immutable' not in hids_augenrules.stderr"
  notify: reboot required

- name: restart auditd
  ansible.builtin.command:
    cmd: /usr/sbin/service auditd restart
  changed_when: true

- name: rebuild aide database
  ansible.builtin.shell:
    cmd: |
      set -euo pipefail
      /usr/sbin/aide --init --config /etc/aide/aide.conf
      mv -f /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz
    executable: /bin/bash
  changed_when: true

- name: reboot required
  ansible.builtin.file:
    path: /var/run/reboot-required
    state: touch
    mode: "0644"
```

```yaml
---
# playbooks/hids.yml
- name: Deploy host intrusion detection baseline
  hosts: linux_production
  become: true
  serial: "10%"
  max_fail_percentage: 5

  pre_tasks:
    - name: Assert the fleet is on a supported distribution
      ansible.builtin.assert:
        that:
          - ansible_facts['os_family'] in ['RedHat', 'Debian']
          - ansible_facts['distribution_major_version'] | int >= 9
        fail_msg: >-
          Unsupported platform {{ ansible_facts['distribution'] }}
          {{ ansible_facts['distribution_version'] }}

    - name: Assert /var/log/audit lives on its own filesystem
      ansible.builtin.assert:
        that:
          - ansible_facts['mounts']
            | selectattr('mount', 'equalto', '/var/log/audit')
            | list | length > 0
        fail_msg: >-
          /var/log/audit is not a separate mount point; a full audit log
          would fill the root filesystem and take the node down.

  roles:
    - role: hids

  post_tasks:
    - name: Verify the audit subsystem is healthy
      ansible.builtin.command:
        cmd: /usr/sbin/auditctl -s
      register: hids_status
      changed_when: false

    - name: Fail if the kernel is dropping audit events
      ansible.builtin.assert:
        that:
          - (hids_status.stdout_lines
             | select('match', '^lost ') | first).split()[1] | int == 0
        fail_msg: "Kernel reports lost audit events: {{ hids_status.stdout }}"

    - name: Fail if auditd is not registered with the kernel
      ansible.builtin.assert:
        that:
          - (hids_status.stdout_lines
             | select('match', '^pid ') | first).split()[1] | int != 0
        fail_msg: "No userspace process is receiving audit events."
```

### 7.2 Kubernetes: DaemonSet de auditoría a nivel de nodo

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: node-security
  labels:
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/audit: privileged
    pod-security.kubernetes.io/warn: privileged
---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
value: 1000000
globalDefault: false
metadata:
  name: node-security-critical
description: >-
  Host intrusion detection agents. Must not be evicted ahead of workloads;
  a node without detection is a node without evidence.
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: node-hids
  namespace: node-security
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: node-hids
rules:
  - apiGroups: [""]
    resources: ["nodes"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["create", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: node-hids
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: node-hids
subjects:
  - kind: ServiceAccount
    name: node-hids
    namespace: node-security
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: node-audit-rules
  namespace: node-security
data:
  10-base-config.rules: |
    -D
    -b 32768
    --backlog_wait_time 60000
    -r 0
    -f 1
  20-dont-audit.rules: |
    -a never,exit -F arch=b64 -F exe=/usr/sbin/auditd
    -a never,exit -F arch=b64 -F dir=/proc
    -a never,exit -F arch=b64 -F dir=/sys/fs/cgroup
    -a never,exit -F arch=b64 -F exe=/usr/bin/containerd-shim-runc-v2
  30-kubernetes.rules: |
    # Kubelet and container runtime configuration.
    -w /etc/kubernetes/            -p wa -k k8s-config
    -w /var/lib/kubelet/config.yaml -p wa -k k8s-config
    -w /etc/containerd/config.toml -p wa -k runtime-config
    -w /etc/crio/crio.conf         -p wa -k runtime-config
    # Static pod manifests are the classic node-persistence vector.
    -w /etc/kubernetes/manifests/  -p wa -k k8s-static-pods
    # Kubelet credentials and the cluster CA.
    -w /var/lib/kubelet/pki/       -p wa -k k8s-credentials
    -w /etc/kubernetes/pki/        -p wa -k k8s-credentials
    # Container runtime sockets: anyone writing here owns the node.
    -w /run/containerd/containerd.sock -p wa -k runtime-socket
    -w /var/run/docker.sock            -p wa -k runtime-socket
    # Kernel module loading from a container is always an escape attempt.
    -a always,exit -F arch=b64 -S init_module,finit_module,delete_module -k modules
    # Namespace and mount manipulation.
    -a always,exit -F arch=b64 -S setns,unshare -k namespace-change
    -a always,exit -F arch=b64 -S mount,umount2 -k mounts
  99-finalize.rules: |
    -e 2
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-audit-rules
  namespace: node-security
  labels:
    app.kubernetes.io/name: node-audit-rules
    app.kubernetes.io/component: hids
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: node-audit-rules
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 10%
  template:
    metadata:
      labels:
        app.kubernetes.io/name: node-audit-rules
      annotations:
        # Force a rollout whenever the rules change.
        checksum/rules: "REPLACED_BY_CI"
    spec:
      serviceAccountName: node-hids
      priorityClassName: node-security-critical
      hostPID: true
      hostNetwork: false
      dnsPolicy: ClusterFirst
      tolerations:
        - operator: Exists
      nodeSelector:
        kubernetes.io/os: linux

      # The init container writes the rules onto the host and asks the
      # host's auditd to reload them. auditd itself stays on the host:
      # the kernel audit netlink socket has a single userspace owner and
      # is not namespaced.
      initContainers:
        - name: install-rules
          image: registry.example.net/security/audit-tools:3.1.2
          imagePullPolicy: IfNotPresent
          command:
            - /bin/sh
            - -c
            - |
              set -eu
              install -d -m 0750 /host/etc/audit/rules.d
              for f in /rules/*.rules; do
                install -m 0600 "$f" "/host/etc/audit/rules.d/$(basename "$f")"
              done
              echo "rules installed; requesting reload via nsenter"
              nsenter --target 1 --mount --uts --ipc --net --pid -- \
                /usr/sbin/augenrules --load || {
                  rc=$?
                  # rc 1 with immutable rules loaded means a reboot is needed;
                  # that is expected on a hardened node, not a failure.
                  echo "augenrules exited $rc (immutable ruleset likely active)"
                }
              nsenter --target 1 --mount --uts --ipc --net --pid -- \
                /usr/sbin/auditctl -s
          securityContext:
            privileged: true
            runAsUser: 0
          volumeMounts:
            - name: host-etc
              mountPath: /host/etc
            - name: rules
              mountPath: /rules
              readOnly: true

      containers:
        # Long-lived sidecar: exports audit health as log lines so the
        # cluster's log pipeline alerts on lost events.
        - name: audit-health
          image: registry.example.net/security/audit-tools:3.1.2
          command:
            - /bin/sh
            - -c
            - |
              set -eu
              while true; do
                nsenter --target 1 --mount --uts --ipc --net --pid -- \
                  /usr/sbin/auditctl -s \
                  | awk -v node="${NODE_NAME}" '
                      {kv[$1]=$2}
                      END {
                        printf "{\"node\":\"%s\",\"enabled\":%s,\"pid\":%s,",
                               node, kv["enabled"], kv["pid"]
                        printf "\"lost\":%s,\"backlog\":%s,\"backlog_limit\":%s}\n",
                               kv["lost"], kv["backlog"], kv["backlog_limit"]
                      }'
                sleep 60
              done
          env:
            - name: NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
          securityContext:
            privileged: true
            runAsUser: 0
          resources:
            requests:
              cpu: 10m
              memory: 32Mi
            limits:
              memory: 64Mi
          volumeMounts:
            - name: host-proc
              mountPath: /host/proc
              readOnly: true

      volumes:
        - name: host-etc
          hostPath:
            path: /etc
            type: Directory
        - name: host-proc
          hostPath:
            path: /proc
            type: Directory
        - name: rules
          configMap:
            name: node-audit-rules
            defaultMode: 0600
```

### 7.3 Kubernetes: CronJob de verificación FIM por nodo

```yaml
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: node-fim-check
  namespace: node-security
spec:
  schedule: "17 3 * * *"
  timeZone: "America/Argentina/Buenos_Aires"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 7
  startingDeadlineSeconds: 3600
  jobTemplate:
    spec:
      backoffLimit: 0
      activeDeadlineSeconds: 5400
      template:
        spec:
          restartPolicy: Never
          serviceAccountName: node-hids
          priorityClassName: node-security-critical
          tolerations:
            - operator: Exists
          containers:
            - name: aide
              image: registry.example.net/security/aide:0.18.6
              command:
                - /bin/sh
                - -c
                - |
                  set -u
                  # Pull the signed baseline for THIS node from object
                  # storage; never trust a baseline that lives on the host.
                  aws s3 cp "s3://fim-baselines/${NODE_NAME}/aide.db.gz" \
                        /tmp/aide.db.gz
                  aws s3 cp "s3://fim-baselines/${NODE_NAME}/aide.db.gz.asc" \
                        /tmp/aide.db.gz.asc
                  gpgv --keyring /keys/fim-baseline.gpg \
                       /tmp/aide.db.gz.asc /tmp/aide.db.gz || {
                    echo '{"severity":"critical","event":"baseline_signature_invalid"}'
                    exit 90
                  }
                  aide --check \
                       --config /etc/aide/aide.conf \
                       --before 'database_in=file:/tmp/aide.db.gz'
                  rc=$?
                  echo "{\"node\":\"${NODE_NAME}\",\"event\":\"fim_check\",\"rc\":${rc}}"
                  # Exit 0 for clean, non-zero for any difference so the Job
                  # is marked Failed and the alerting pipeline fires.
                  exit "${rc}"
              env:
                - name: NODE_NAME
                  valueFrom:
                    fieldRef:
                      fieldPath: spec.nodeName
              securityContext:
                runAsUser: 0
                readOnlyRootFilesystem: false
                capabilities:
                  drop: ["ALL"]
                  add: ["DAC_READ_SEARCH"]
              resources:
                requests:
                  cpu: 100m
                  memory: 256Mi
                limits:
                  cpu: "1"
                  memory: 512Mi
              volumeMounts:
                - name: host-root
                  mountPath: /hostfs
                  readOnly: true
                - name: aide-config
                  mountPath: /etc/aide
                  readOnly: true
                - name: gpg-keys
                  mountPath: /keys
                  readOnly: true
          volumes:
            - name: host-root
              hostPath:
                path: /
                type: Directory
            - name: aide-config
              configMap:
                name: node-aide-config
            - name: gpg-keys
              secret:
                secretName: fim-baseline-pubkey
                defaultMode: 0444
```

### 7.4 OpenShift/Kubernetes: Compliance Operator (OpenSCAP gestionado)

```yaml
---
apiVersion: compliance.openshift.io/v1alpha1
kind: ScanSetting
metadata:
  name: prod-scan-setting
  namespace: openshift-compliance
rawResultStorage:
  size: "5Gi"
  rotation: 10
  storageClassName: gp3-csi
roles:
  - worker
  - master
scanTolerations:
  - operator: Exists
schedule: "0 4 * * 0"
showNotApplicable: false
strictNodeScan: true
autoApplyRemediations: false
autoUpdateRemediations: false
---
apiVersion: compliance.openshift.io/v1alpha1
kind: TailoredProfile
metadata:
  name: cis-node-example
  namespace: openshift-compliance
spec:
  extends: ocp4-cis-node
  title: CIS OCP4 node profile, Example Corp tailoring
  description: >-
    CIS Level 1 node profile with two documented exceptions
    (SEC-4412, SEC-4530) and a corporate value for the audit log retention.
  disableRules:
    - name: ocp4-cis-node-kubelet-enable-protect-kernel-sysctl
      rationale: >-
        Conflicts with the tuned profile required by the storage vendor.
        Approved in SEC-4412, expires 2027-01-31.
    - name: ocp4-cis-node-kubelet-enable-streaming-connections
      rationale: >-
        Long-running exec sessions are required by the DBA runbook.
        Approved in SEC-4530, expires 2026-12-31.
  setValues:
    - name: ocp4-var-role-master
      value: master
      rationale: Default control plane role label.
---
apiVersion: compliance.openshift.io/v1alpha1
kind: ScanSettingBinding
metadata:
  name: prod-compliance
  namespace: openshift-compliance
profiles:
  - apiGroup: compliance.openshift.io/v1alpha1
    kind: TailoredProfile
    name: cis-node-example
  - apiGroup: compliance.openshift.io/v1alpha1
    kind: Profile
    name: ocp4-cis
settingsRef:
  apiGroup: compliance.openshift.io/v1alpha1
  kind: ScanSetting
  name: prod-scan-setting
```

```console
$ kubectl get compliancesuite -n openshift-compliance
NAME              PHASE   RESULT
prod-compliance   DONE    NON-COMPLIANT

$ kubectl get compliancecheckresult -n openshift-compliance \
      -l compliance.openshift.io/check-status=FAIL \
      -o custom-columns=NAME:.metadata.name,SEVERITY:.severity
NAME                                                     SEVERITY
cis-node-example-worker-audit-rules-immutable            medium
cis-node-example-worker-file-permissions-kubelet-conf    medium
ocp4-cis-api-server-encryption-provider-cipher           medium
```

### 7.5 Pipeline de CI: la imagen no se promueve si no cumple

```yaml
---
# .gitlab-ci.yml (fragmento)
stages: [build, harden, verify, publish]

variables:
  SSG_DS: /usr/share/xml/scap/ssg/content/ssg-rhel9-ds.xml
  PROFILE: xccdf_org.ssgproject.content_profile_cis_server_l1

build:image:
  stage: build
  script:
    - buildah bud -t "${CI_REGISTRY_IMAGE}:${CI_COMMIT_SHA}" .

harden:remediate:
  stage: harden
  script:
    - >
      oscap-podman "${CI_REGISTRY_IMAGE}:${CI_COMMIT_SHA}"
      xccdf eval --remediate --profile "${PROFILE}"
      --results-arf arf-pre.xml "${SSG_DS}" || true
    - buildah commit "${CI_REGISTRY_IMAGE}:${CI_COMMIT_SHA}-hardened"

verify:compliance:
  stage: verify
  script:
    - |
      set +e
      oscap-podman "${CI_REGISTRY_IMAGE}:${CI_COMMIT_SHA}-hardened" \
        xccdf eval --profile "${PROFILE}" \
        --results-arf arf.xml --report report.html "${SSG_DS}"
      rc=$?
      set -e
      case "$rc" in
        0) echo "COMPLIANT" ;;
        2) echo "NON-COMPLIANT — rules failed"; exit 1 ;;
        *) echo "SCANNER ERROR rc=$rc"; exit 99 ;;
      esac
  artifacts:
    when: always
    paths: [arf.xml, report.html]
    expire_in: 1 year

verify:fim-baseline:
  stage: verify
  script:
    # The baseline is built here, in the pipeline — never on a live node.
    - podman run --rm -v "$PWD:/out:z" "${CI_REGISTRY_IMAGE}:${CI_COMMIT_SHA}-hardened"
      sh -c 'aide --init --config /etc/aide/aide.conf &&
             cp /var/lib/aide/aide.db.new.gz /out/aide.db.gz'
    - gpg --batch --yes --detach-sign --armor --local-user "${FIM_KEY}" aide.db.gz
    - aws s3 cp aide.db.gz     "s3://fim-baselines/images/${CI_COMMIT_SHA}/"
    - aws s3 cp aide.db.gz.asc "s3://fim-baselines/images/${CI_COMMIT_SHA}/"
  artifacts:
    paths: [aide.db.gz, aide.db.gz.asc]
```

---

## 8. Verificación y diagnóstico de fallas

### 8.1 Verificación funcional: probar que la detección detecta

No basta con que el servicio esté `active (running)`. Hay que **generar el evento y confirmar que aparece**.

```console
# ---- 1. Verificar que el kernel entrega eventos a auditd ------------------
$ sudo auditctl -s | grep -E '^(enabled|pid|lost)'
enabled 2
pid 1284
lost 0

# ---- 2. Prueba activa de un watch ----------------------------------------
$ sudo touch -a /etc/shadow
$ sudo ausearch -k identity -i -ts recent | tail -12
----
type=PROCTITLE msg=audit(08/24/2026 12:31:04.221:4102) : proctitle=touch -a /etc/shadow
type=PATH msg=audit(08/24/2026 12:31:04.221:4102) : item=0 name=/etc/shadow inode=131 ...
type=SYSCALL msg=audit(08/24/2026 12:31:04.221:4102) : arch=x86_64 syscall=utimensat success=yes exit=0 ... auid=fmartinez uid=root comm=touch exe=/usr/bin/touch key=identity

# ---- 3. Prueba activa de una syscall rule --------------------------------
$ cat /etc/shadow > /dev/null   # como usuario sin privilegios
cat: /etc/shadow: Permission denied
$ sudo ausearch -k access-denied -i -ts recent | grep -m1 SYSCALL
type=SYSCALL msg=audit(08/24/2026 12:32:11.004:4118) : arch=x86_64 syscall=openat success=no exit=EACCES(Permission denied) ... auid=fmartinez uid=fmartinez comm=cat exe=/usr/bin/cat key=access-denied

# ---- 4. Verificar que los eventos LLEGAN AL COLECTOR ---------------------
# En el colector:
$ sudo ausearch -i -ts recent --node nodo-01.prod.example.net | head -5
# Si esto está vacío mientras el nodo sí registra, el problema es la
# entrega remota, no la detección.

# ---- 5. Prueba activa de AIDE --------------------------------------------
$ sudo install -m 0755 /bin/true /usr/local/sbin/.canary
$ sudo aide --check --limit '^/usr/local/sbin' --config /etc/aide/aide.conf
Start timestamp: 2026-08-24 12:34:19 -0300 (AIDE 0.18.6)
Limit: ^/usr/local/sbin
AIDE found differences between database and filesystem!!

Summary:
  Total number of entries:      12
  Added entries:                1

---------------------------------------------------
Added entries:
---------------------------------------------------

f+++++++++++++++++: /usr/local/sbin/.canary

$ echo $?
1
$ sudo rm -f /usr/local/sbin/.canary

# ---- 6. Prueba activa de OpenSCAP ----------------------------------------
$ sudo sed -i 's/^PermitRootLogin no/PermitRootLogin yes/' /etc/ssh/sshd_config
$ sudo oscap xccdf eval \
    --rule xccdf_org.ssgproject.content_rule_sshd_disable_root_login \
    --profile "$PROFILE" "$SSG_DS"
Title   Disable SSH Root Login
Rule    xccdf_org.ssgproject.content_rule_sshd_disable_root_login
Result  fail
$ sudo sed -i 's/^PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config
```

### 8.2 Matriz de diagnóstico — Linux Audit

| Síntoma | Causa raíz probable | Comando de verificación | Remedio |
|---|---|---|---|
| `auditctl -s` muestra `pid 0` | `auditd` no corre o perdió el registro con el kernel | `systemctl status auditd`, `ss -f netlink -p` | `service auditd restart` (nunca `systemctl restart auditd` en RHEL: el unit tiene `RefuseManualStop`) |
| `lost` crece continuamente | `backlog_limit` insuficiente para el volumen de eventos | `auditctl -s`, `aureport -k --summary` | Subir `-b`, y sobre todo **añadir reglas `never`** para el ruido dominante |
| `dmesg`: `audit: backlog limit exceeded` | Igual que arriba, ya con descarte activo | `dmesg -T \| grep audit` | `auditctl -b 65536` + revisión del ruleset |
| `dmesg`: `audit: rate limit exceeded` | `-r N` con N demasiado bajo | `auditctl -s \| grep rate_limit` | `auditctl -r 0` y controlar por reglas |
| Los procesos se ponen lentos al escribir ficheros | `--backlog_wait_time` alto con backlog lleno: el kernel **bloquea** al generador | `auditctl -s \| grep backlog_wait_time_actual` | Reducir el ruleset; en emergencia `auditctl --backlog_wait_time 0` |
| `auditctl -R` → `Error sending add rule request (Operation not permitted)` | Reglas en modo inmutable (`-e 2`) | `auditctl -s \| grep enabled` → `enabled 2` | Reiniciar el nodo; el cambio solo se aplica en el arranque |
| `auid=unset` / `auid=4294967295` en todos los eventos | El proceso no tiene sesión de login (servicio de systemd, contenedor) | `cat /proc/<pid>/loginuid` | Es esperado; usar `-F auid!=unset` para separar actividad humana de la de sistema |
| El `auid` cambia dentro de una sesión | `loginuid_immutable` deshabilitado | `auditctl -s \| grep loginuid_immutable` | Compilar/configurar el kernel con `CONFIG_AUDIT_LOGINUID_IMMUTABLE`, o `auditctl --loginuid-immutable` |
| No hay eventos del arranque temprano | Falta `audit=1` en la línea de comandos del kernel | `cat /proc/cmdline` | `grubby --update-kernel=ALL --args="audit=1"` + reboot |
| El colector no recibe nada | `au-remote` inactivo, cortafuegos, o Kerberos mal | `systemctl status auditd`, `journalctl -u auditd \| grep audisp`, `ss -tnp state established '( dport = :60 )'` | Revisar `/etc/audit/plugins.d/au-remote.conf` `active = yes` y la cola en `queue_file` |
| `journalctl`: `audisp-remote: queue is full - dropping event` | El colector está caído y `queue_depth` se agotó | `ls -l /var/spool/audit/remote.q` | Subir `queue_depth`, arreglar el colector, revisar `network_failure_action` |
| Los UID aparecen como números en el colector | `log_format` no es `ENRICHED` | `grep log_format /etc/audit/auditd.conf` | `log_format = ENRICHED` y reiniciar |
| El disco de `/var/log/audit` se llena | `max_log_file_action = KEEP_LOGS` o rotación mal dimensionada | `df -h /var/log/audit`, `ls -l /var/log/audit/` | `ROTATE` + `num_logs`, y `/var/log/audit` en su propio filesystem |
| El sistema entró en single-user solo | `admin_space_left_action = SINGLE` disparado | `journalctl -b -1 -u auditd` | Liberar espacio; reconsiderar la acción |
| Eventos de contenedores sin atribución | El subsistema audit no tiene namespaces | `ausearch -i \| grep -o 'ppid=[0-9]*'` | Correlacionar `pid`/`ppid` con el runtime, o usar `subj=` SELinux; para atribución nativa hace falta eBPF |

**Diagnóstico de volumen — encontrar la regla que ahoga al nodo:**

```console
$ sudo aureport -k --summary -i --start today | head
Key Summary Report
===================================
total  key
===================================
487211 exec
1204   identity

$ sudo ausearch -k exec -i --start today --format csv \
    | awk -F, '{print $NF}' | sort | uniq -c | sort -rn | head -5
 481093 exe=/usr/lib/systemd/systemd-cgroups-agent
   3211 exe=/usr/bin/bash
   1440 exe=/usr/bin/python3
    ...

# Remedio: excluir el generador dominante
$ sudo tee -a /etc/audit/rules.d/20-dont-audit.rules <<'EOF'
-a never,exit -F arch=b64 -F exe=/usr/lib/systemd/systemd-cgroups-agent
EOF
$ sudo augenrules --load
```

### 8.3 Matriz de diagnóstico — AIDE

| Síntoma | Causa raíz | Verificación | Remedio |
|---|---|---|---|
| `Couldn't open file /var/lib/aide/aide.db.gz for reading` | Nunca se hizo `--init`, o la DB no se promovió desde `.new` | `ls -l /var/lib/aide/` | `aide --init && mv aide.db.new.gz aide.db.gz` |
| `Error: db_in and db_out cannot be the same` | `database_in` == `database_out` en la config | `aide --config-check` | Separar las rutas |
| Miles de entradas cambiadas tras un `dnf update` | Normal: los binarios cambiaron | `rpm -Va \| head` para confirmar que son de paquetes | `aide --update` tras verificar, y automatizarlo como paso posterior al parcheo |
| Miles de cambios de `atime` | Grupo con atributo `a` y filesystem sin `relatime` | `mount \| grep ' / '` | Quitar `a` de los grupos; usar `relatime`/`noatime` |
| Ruido constante en `/var/lib/*`, `/run` | Faltan exclusiones | Leer el reporte | Añadir líneas `!` |
| El check nunca termina / consume todo el I/O | Se está hasheando `/proc`, `/sys`, `/var/lib/containerd` | `pidstat -d -p $(pgrep aide) 1` | Exclusiones + `IOSchedulingClass=idle` en el unit |
| `--check` dice "no differences" en un host comprometido | La DB fue regenerada por el atacante | Verificar firma GPG y comparar con la copia off-host | Baseline firmado y externo; ver §4.4 |
| El reporte está vacío pero el exit code es ≠ 0 | `report_level` demasiado bajo | `grep report_level /etc/aide/aide.conf` | `report_level = changed_attributes` |
| `verbose` no reconocido | AIDE ≥ 0.17 eliminó `verbose` | `aide --version` | Usar `log_level` + `report_level` |
| Cambios en `/etc/ssh/ssh_host_*_key` en cada arranque | Regeneración de claves de host en imágenes cloud | `journalctl -u sshd-keygen@` | Generarlas en la build, o excluirlas con justificación |

```console
$ aide --version
Aide 0.18.6

Compiled with the following options:

WITH_MMAP
WITH_PCRE2
WITH_POSIX_ACL
WITH_SELINUX
WITH_XATTR
WITH_E2FSATTRS
WITH_ZLIB
WITH_CURL
CONFIG_FILE = "/etc/aide/aide.conf"

Available hashsum groups (and their underlying hash algorithms):
  md5: md5
  sha1: sha1
  sha256: sha256
  sha512: sha512
  rmd160: rmd160
  tiger: tiger
  haval: haval
  crc32: crc32
  crc32b: crc32b
  whirlpool: whirlpool
  gostr3411_94: gost
  stribog256: stribog256
  stribog512: stribog512

Default compound groups:
  R: p+ftype+i+l+n+u+g+s+m+c+acl+selinux+xattrs+sha512
  L: p+ftype+i+l+n+u+g+acl+selinux+xattrs
  >: p+ftype+l+u+g+i+n+S+acl+selinux+xattrs
```

> **Comprobar `WITH_...` antes de escribir la configuración:** si el binario de la distro no trae `WITH_E2FSATTRS`, la línea `e2fsattrs` provoca un error de configuración, no un aviso.

### 8.4 Matriz de diagnóstico — rkhunter / chkrootkit / maldet

| Síntoma | Causa | Remedio |
|---|---|---|
| `rkhunter --update`: `Invalid WEB_CMD configuration option: Relative pathname` | El default de Debian es `WEB_CMD="/bin/false"` | `WEB_CMD=""` en `rkhunter.conf.local` |
| Avalancha de `file properties have changed` tras cada actualización | La DB de propiedades no se refresca | Configurar `PKGMGR=RPM`/`DPKG`, y correr `--propupd` como paso posterior al parcheo en la build |
| `Warning: Hidden directory found: /etc/.java` | Falso positivo de software legítimo | `ALLOWHIDDENDIR=/etc/.java` con justificación |
| `Warning: Suspicious file types found in /dev` | `/dev/shm` con ficheros de aplicaciones | `ALLOWDEVFILE=` con patrón acotado |
| `rkhunter` no detecta nada en un host comprometido | Rootkit en kernel-space ocultando ficheros y procesos | Analizar desde medio externo: `chkrootkit -r /mnt -p /bin` |
| `chkrootkit`: `bindshell INFECTED (PORTS: 465)` | Puerto legítimo (SMTPS) en la lista de backdoors | `ss -tlnp sport = :465` para confirmar el proceso; documentar |
| `chkrootkit`: `PACKET SNIFFER(NetworkManager)` | `AF_PACKET` para DHCP | Falso positivo conocido |
| `maldet -u` falla | Sin salida a `cdn.rfxn.com` | Espejar el sigpack internamente y servirlo desde el repo local |
| `maldet -m` no arranca | `fs.inotify.max_user_watches` insuficiente | `sysctl -w fs.inotify.max_user_watches=524288` y persistir en `/etc/sysctl.d/` |
| `maldet` pone en cuarentena ficheros de producción | `quarantine_hits="1"` desde el día uno | Desplegar con `quarantine_hits="0"` (solo alerta) durante 2–4 semanas |

### 8.5 Matriz de diagnóstico — OpenSCAP

| Síntoma | Causa | Verificación | Remedio |
|---|---|---|---|
| Todas las reglas dan `notapplicable` | El CPE de la plataforma no coincide con el datastream | `oscap info $DS`, `cat /etc/os-release` | Usar el `ssg-<distro><ver>-ds.xml` correcto |
| `E: oscap: Could not parse the XML file` | Datastream corrupto o versión de OpenSCAP muy vieja | `oscap ds sds-validate $DS`, `oscap --version` | Reinstalar `scap-security-guide`, actualizar `openscap-scanner` |
| Reglas con `Result error` | El check OVAL no pudo ejecutarse (falta un binario, SELinux bloquea) | `--oval-results` y leer el XML; `ausearch -m AVC -ts recent` | Instalar la dependencia; revisar denegaciones SELinux |
| `notchecked` masivo | El perfil usa OCIL (revisión manual) | `oscap info --profile ... $DS` | Documentar la revisión manual; no es un fallo del scanner |
| `--remediate` deja el host sin SSH | Los perfiles STIG endurecen `sshd_config` agresivamente | Consola serie / IPMI | Remediar en la build, nunca en runtime; probar en staging |
| Resultado inconsistente entre ejecuciones | Contenido remoto no descargado | Mensaje `WARNING: Skipping ... remote resource` | Añadir `--fetch-remote-resources` (y decidir si eso es aceptable en producción) |
| El scan tarda horas | Reglas de búsqueda en todo el filesystem (world-writable files, unowned files) | `--rule` para aislar la lenta | Aceptar el coste o desactivar esas reglas vía tailoring, documentando |
| El pipeline de CI pasa siempre en verde | `oscap ... || true`, o no se distingue rc=1 de rc=2 | Leer el script | Manejar los tres códigos por separado (§6.3) |
| `oscap-podman` falla con `permission denied` | Se ejecuta sin privilegios sobre el almacenamiento de imágenes | `sudo oscap-podman ...` | Ejecutar como root o con el almacenamiento correcto |

### 8.6 Checklist de verificación de despliegue

```bash
#!/usr/bin/env bash
# /usr/local/bin/hids-selfcheck — ejecutar tras cada despliegue.
set -uo pipefail
fail=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }

echo "== Linux Audit =="
st=$(auditctl -s)
[[ $(awk '/^enabled/{print $2}' <<<"$st") -ge 1 ]] \
  && ok "audit subsystem enabled" || bad "audit subsystem disabled"
[[ $(awk '/^pid/{print $2}' <<<"$st") -ne 0 ]] \
  && ok "auditd registered with the kernel" || bad "no userspace consumer (pid 0)"
[[ $(awk '/^lost/{print $2}' <<<"$st") -eq 0 ]] \
  && ok "no lost events" || bad "kernel dropped events: $(awk '/^lost/{print $2}' <<<"$st")"
[[ $(awk '/^backlog_limit/{print $2}' <<<"$st") -ge 8192 ]] \
  && ok "backlog_limit >= 8192" || bad "backlog_limit too small"
[[ $(auditctl -l | wc -l) -gt 10 ]] \
  && ok "$(auditctl -l | wc -l) rules loaded" || bad "rules not loaded"
grep -q 'audit=1' /proc/cmdline \
  && ok "early-boot auditing enabled" || bad "audit=1 missing from /proc/cmdline"
grep -q '^log_format *= *ENRICHED' /etc/audit/auditd.conf \
  && ok "log_format=ENRICHED" || bad "log_format is not ENRICHED"
mountpoint -q /var/log/audit \
  && ok "/var/log/audit is a separate mount" || bad "/var/log/audit shares a filesystem"
[[ -f /etc/audit/plugins.d/au-remote.conf ]] \
  && grep -q '^active *= *yes' /etc/audit/plugins.d/au-remote.conf \
  && ok "remote shipping active" || bad "audit events are not shipped off-host"

echo "== AIDE =="
[[ -s /var/lib/aide/aide.db.gz ]] \
  && ok "baseline present" || bad "no AIDE baseline"
[[ -s /var/lib/aide/aide.db.gz.asc ]] \
  && ok "baseline signature present" || bad "baseline is not signed"
gpgv --keyring /etc/aide/fim-baseline.gpg \
     /var/lib/aide/aide.db.gz.asc /var/lib/aide/aide.db.gz 2>/dev/null \
  && ok "baseline signature valid" || bad "baseline signature INVALID"
systemctl is-enabled --quiet aide-check.timer \
  && ok "aide-check.timer enabled" || bad "aide-check.timer not enabled"
aide --config-check --config /etc/aide/aide.conf 2>/dev/null \
  && ok "aide.conf parses" || bad "aide.conf has errors"

echo "== OpenSCAP =="
command -v oscap >/dev/null \
  && ok "oscap installed ($(oscap --version | head -1))" || bad "oscap missing"
[[ -r /usr/share/xml/scap/ssg/content ]] \
  && ok "SSG content present" || bad "scap-security-guide missing"

echo "== rkhunter =="
[[ -s /var/lib/rkhunter/db/rkhunter.dat ]] \
  && ok "rkhunter file-properties DB initialised" || bad "run rkhunter --propupd at build time"

echo
[[ $fail -eq 0 ]] && echo "ALL CHECKS PASSED" || echo "$fail CHECK(S) FAILED"
exit $fail
```

```console
$ sudo /usr/local/bin/hids-selfcheck
== Linux Audit ==
  PASS  audit subsystem enabled
  PASS  auditd registered with the kernel
  PASS  no lost events
  PASS  backlog_limit >= 8192
  PASS  61 rules loaded
  PASS  early-boot auditing enabled
  PASS  log_format=ENRICHED
  PASS  /var/log/audit is a separate mount
  PASS  remote shipping active
== AIDE ==
  PASS  baseline present
  PASS  baseline signature present
  PASS  baseline signature valid
  PASS  aide-check.timer enabled
  PASS  aide.conf parses
== OpenSCAP ==
  PASS  oscap installed (OpenSCAP command line tool (oscap) 1.4.1)
  PASS  SSG content present
== rkhunter ==
  PASS  rkhunter file-properties DB initialised

ALL CHECKS PASSED
```

### 8.7 Runbook: sospecha de compromiso en un host

```
1. NO REINICIAR. NO CORRER `aide --update`. NO CORRER `rkhunter --propupd`.
   Cada uno destruye evidencia irrecuperable.

2. Aislar en red (security group / NetworkPolicy / cordon+drain), manteniendo
   el host encendido.

3. Capturar volátil ANTES de tocar disco:
   $ sudo ss -tunap            > /evidence/sockets.txt
   $ sudo ps auxfww            > /evidence/ps.txt
   $ sudo lsof -n -P           > /evidence/lsof.txt
   $ sudo cat /proc/modules    > /evidence/modules.txt
   $ sudo auditctl -s          > /evidence/audit-status.txt

4. Extraer la ventana de auditoría al colector (no al host):
   $ ausearch -ts 08/23/2026 00:00:00 -te now --format raw \
       > /evidence/audit-window.log
   $ ausearch --format csv -ts 08/23/2026 -k exec,privilege-change,setuid-exec,modules \
       > /evidence/audit-highvalue.csv

5. Comparar el filesystem contra el baseline EXTERNO, no contra el local:
   $ aws s3 cp s3://fim-baselines/$(hostname -f)/aide.db.gz /evidence/
   $ gpgv --keyring /etc/aide/fim-baseline.gpg /evidence/aide.db.gz.asc /evidence/aide.db.gz
   $ aide --check --before 'database_in=file:/evidence/aide.db.gz' \
          --config /etc/aide/aide.conf > /evidence/fim-diff.txt

6. Verificación cruzada por gestor de paquetes:
   $ rpm -Va --nofiles --nodigest > /evidence/rpm-verify.txt   # o debsums -c

7. Snapshot del disco. El análisis de rootkit se hace sobre el snapshot,
   montado read-only en un host limpio:
   $ sudo chkrootkit -r /mnt/snapshot -p /bin:/usr/bin -q
   $ sudo rkhunter --check --sk --rwo --rootdir /mnt/snapshot

8. Reconstruir el host desde imagen. Nunca "limpiar" un host comprometido:
   la única garantía es un rebuild desde artefacto conocido.
```

---

## 9. Puntos de examen frecuentemente confundidos

| Confusión | Realidad |
|---|---|
| `auditctl -e 2` se puede revertir con `auditctl -e 1` | **No.** Solo un reinicio libera el modo inmutable |
| `systemctl restart auditd` funciona en RHEL | **No.** El unit lleva `RefuseManualStop=yes`; se usa `service auditd restart` |
| `/etc/audit/audit.rules` se edita a mano | Es **generado** por `augenrules` desde `/etc/audit/rules.d/*.rules` |
| `auid` es el UID del proceso | Es el **loginuid**: la identidad original de la sesión, inmutable |
| `aide --init` deja la base activa | Escribe `aide.db.new`; hay que **moverla** a la ruta de `database_in` |
| `aide --check` devuelve 0 con diferencias | Devuelve un **campo de bits** (1 added, 2 removed, 4 changed) |
| `rkhunter --update` actualiza el programa | Actualiza las **bases de datos**; el programa se comprueba con `--versioncheck` |
| `rkhunter --propupd` es parte del chequeo rutinario | Es el paso que **borra la evidencia** si el sistema ya está comprometido |
| `oscap xccdf eval` devuelve 1 cuando hay fallos | Devuelve **2** cuando fallan reglas; **1** es error del scanner |
| XCCDF hace las comprobaciones | XCCDF es el checklist; **OVAL** contiene la lógica de evaluación |
| `chkrootkit` se actualiza con firmas nuevas | **No tiene** mecanismo de actualización de firmas: se actualiza con la versión |
| `-w /etc/passwd -p wa` filtra por usuario | Los watches **no admiten** filtros `-F`; para eso hace falta `-a always,exit` |
| Un contenedor puede correr su propio `auditd` | El netlink de audit **no está namespaced** y tiene un solo dueño en el host |

---

## 10. Referencias

**Objetivos oficiales de la certificación**
- LPI — Exam 303: Security, Objectives v3.0.0: https://www.lpi.org/our-certifications/exam-303-objectives/
- LPI — LPIC-3 Security overview: https://www.lpi.org/our-certifications/lpic-3-303-overview/

**Linux Audit**
- linux-audit (upstream, Steve Grubb): https://github.com/linux-audit/audit-userspace
- Documentación y wiki del proyecto: https://github.com/linux-audit/audit-documentation/wiki
- `auditd(8)`, `auditd.conf(5)`, `auditctl(8)`, `ausearch(8)`, `aureport(8)`, `autrace(8)`, `audit.rules(7)`, `augenrules(8)`, `audisp-remote.conf(5)` — páginas de manual del paquete `audit`
- Red Hat Enterprise Linux 9 — Security hardening, "Auditing the system": https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/security_hardening/auditing-the-system_security-hardening
- SUSE Linux Enterprise Server — Security and Hardening Guide, "Understanding Linux Audit": https://documentation.suse.com/sles/15-SP6/html/SLES-all/part-audit.html
- Kernel audit subsystem (código y `Documentation/`): https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/kernel/audit.c

**AIDE**
- Sitio del proyecto: https://aide.github.io/
- Repositorio y manual: https://github.com/aide/aide
- `aide(1)` y `aide.conf(5)`: https://aide.github.io/doc/
- Red Hat Enterprise Linux 9 — "Checking integrity with AIDE": https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/security_hardening/checking-integrity-with-aide_security-hardening

**Rootkit y malware**
- Rootkit Hunter (rkhunter): https://rkhunter.sourceforge.net/
- chkrootkit: https://www.chkrootkit.org/
- Linux Malware Detect (R-fx Networks): https://www.rfxn.com/projects/linux-malware-detect/
- Repositorio de maldet: https://github.com/rfxn/linux-malware-detect
- ClamAV: https://docs.clamav.net/

**OpenSCAP y SCAP**
- OpenSCAP — sitio y documentación: https://www.open-scap.org/
- Guía de usuario de OpenSCAP: https://www.open-scap.org/resources/documentation/
- Repositorio de OpenSCAP: https://github.com/OpenSCAP/openscap
- ComplianceAsCode / SCAP Security Guide: https://github.com/ComplianceAsCode/content
- Documentación del SSG: https://complianceascode.readthedocs.io/
- NIST — SCAP (Security Content Automation Protocol): https://csrc.nist.gov/projects/security-content-automation-protocol
- NIST SP 800-126 Rev. 3 — The Technical Specification for SCAP 1.3: https://csrc.nist.gov/publications/detail/sp/800-126/rev-3/final
- NIST IR 7275 Rev. 4 — XCCDF specification: https://csrc.nist.gov/publications/detail/nistir/7275/rev-4/final
- OVAL — repositorio y esquemas (CIS): https://github.com/CISecurity/OVAL
- Red Hat Enterprise Linux 9 — "Scanning the system for configuration compliance and vulnerabilities": https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/security_hardening/scanning-the-system-for-configuration-compliance-and-vulnerabilities_security-hardening
- Red Hat OVAL v2 feed: https://security.access.redhat.com/data/oval/v2/
- OpenShift Compliance Operator: https://docs.redhat.com/en/documentation/openshift_container_platform/4.16/html/security_and_compliance/compliance-operator

**Benchmarks y perfiles**
- CIS Benchmarks: https://www.cisecurity.org/cis-benchmarks
- DISA STIGs: https://public.cyber.mil/stigs/
- ANSSI — Recommandations de configuration d'un système GNU/Linux (BP-028): https://cyber.gouv.fr/publications/recommandations-de-securite-relatives-un-systeme-gnulinux

**Referencia complementaria**
- MITRE ATT&CK — Matriz para Linux: https://attack.mitre.org/matrices/enterprise/linux/
- systemd — `systemd.exec(5)` (directivas de endurecimiento de servicio): https://www.freedesktop.org/software/systemd/man/systemd.exec.html
- systemd — `systemd.timer(5)`: https://www.freedesktop.org/software/systemd/man/systemd.timer.html