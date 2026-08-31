# 108.4 — Manage Printers and Printing

**Certification:** LPIC-1 (101-500 / 102-500), version 5.0
**Exam weight in this syllabus snapshot:** 0
**Profile:** Principal Platform Architect / Senior SRE

---

## 1. Motivation and the production architecture problem

Printing is the one subsystem where a Linux platform stops being software and becomes **physical, irreversible output**. Everything else in your stack is idempotent by construction: you can re-run a job, re-apply a manifest, replay a Kafka partition. You cannot un-print a shipping label. That asymmetry is what makes the print path an SRE problem rather than a desktop nuisance.

Three production shapes keep this stack alive long after "the office went paperless":

| Shape | Example | Failure cost |
|---|---|---|
| **Logistics label printing** | ZPL to Zebra ZT411 over `socket://…:9100` at a warehouse pick station | A stalled queue halts fulfilment; a duplicated label ships two parcels against one order |
| **Regulated document output** | Lab results, prescriptions, customs declarations rendered to PDF then spooled | Compliance breach; a lost job is a lost audit trail |
| **Archival / rendering pipelines** | `cups-pdf` or `file://` backends used as a headless PDF renderer inside batch jobs | Silent corruption of an archive nobody reads until the audit |

The architectural problem is that **CUPS is a queueing system that most teams treat as a device driver.** It has all the properties of a message broker — a durable spool, a retry policy, a dead-letter behaviour, per-destination backpressure, an accounting log — and almost none of the operational tooling. Concretely:

1. **The spool is state, and it is node-local.** `/var/spool/cups` holds control files (`c00412`) and data files (`d00412-001`). Losing it loses accepted-but-unprinted work. Any "scale the print server to 2 replicas" plan, without shared coordination, is a duplicate-output generator: each replica has its own spool and its own idea of job IDs, and both will happily push bytes at port 9100 of the same physical device.
2. **Delivery semantics are configurable and almost always wrong by default.** `printer-error-policy` decides whether a device timeout means *retry forever*, *retry N times then stop the queue*, or *abort the job*. On a label printer, `retry-job` after a paper-out event is correct. On a nightly 4000-page batch, `retry-job` against an offline device is how you discover on Monday that the queue has been re-attempting since Friday.
3. **The failure surface is a chain of processes, not a call stack.** `cupsd` → MIME conversion chain (`pdftopdf` → `pdftoraster` → `rastertoXXX`) → backend (`socket`/`ipp`/`usb`). Each link is a separate exec'd binary with its own exit code. A filter that exits 1 produces a job in state `stopped` and a one-line `error_log` entry; nothing else in your observability stack notices.
4. **Discovery does not survive network segmentation.** mDNS/DNS-SD (`dnssd://`) is link-local by design. It works on the office LAN and silently stops working the moment the print server moves into a Kubernetes pod network or a different VLAN. Production print servers must use **explicit device URIs**, not discovery.

The engineering target, then: treat each queue as a **named, declaratively-configured delivery channel with an explicit URI, an explicit error policy, an SLO, and an exported metric** — and treat the spool as the durable, single-writer volume it actually is.

### Service-level model for a print path

| SLI | Definition | Source of truth | Typical objective |
|---|---|---|---|
| Job acceptance latency | `lp` submit → job in `pending` | `access_log` (`POST /printers/x HTTP/1.1" 200`) | p99 < 500 ms |
| Print completion latency | `pending` → `completed` | `page_log` timestamp − `access_log` timestamp | p95 < 20 s for single-label ZPL |
| Queue availability | fraction of scrapes where `printer-state != stopped` and `printer-is-accepting-jobs = true` | IPP `Get-Printer-Attributes` | 99.5 % |
| Spool backlog | count of jobs in `pending` + `processing` | `lpstat -o` / IPP | < 5 sustained |
| Duplicate-output rate | pages in `page_log` ÷ pages requested | `page_log` | 0 — alert on any excess |

---

## 2. Anatomy of the stack

### 2.1 Process and data flow

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

Backend exit codes are the contract between the transport and the scheduler, and they are worth memorising because they are what the error policy acts on:

| Exit | Name | `cupsd` behaviour |
|---|---|---|
| 0 | `CUPS_BACKEND_OK` | Job completes |
| 1 | `CUPS_BACKEND_FAILED` | Apply `printer-error-policy` |
| 2 | `CUPS_BACKEND_AUTH_REQUIRED` | Hold job, request credentials |
| 3 | `CUPS_BACKEND_HOLD` | Hold this job, keep queue running |
| 4 | `CUPS_BACKEND_STOP` | Stop the queue, requeue the job |
| 5 | `CUPS_BACKEND_CANCEL` | Cancel the job (unrecoverable data error) |
| 6 | `CUPS_BACKEND_RETRY` | Retry per `JobRetryInterval` / `JobRetryLimit` |
| 7 | `CUPS_BACKEND_RETRY_CURRENT` | Retry immediately without re-running filters |

### 2.2 The filesystem contract

| Path | Owner | Editable by hand? | Purpose |
|---|---|---|---|
| `/etc/cups/cupsd.conf` | admin | **Yes** | Scheduler behaviour, listeners, policies, `Location` ACLs |
| `/etc/cups/cups-files.conf` | admin | **Yes** | File/dir/user directives, split out since CUPS 1.6 for privilege-escalation hardening |
| `/etc/cups/printers.conf` | `cupsd` | **No** — rewritten on every change | Persisted queue definitions |
| `/etc/cups/classes.conf` | `cupsd` | **No** | Persisted class (printer pool) definitions |
| `/etc/cups/subscriptions.conf` | `cupsd` | **No** | Persisted event subscriptions |
| `/etc/cups/ppd/<queue>.ppd` | `cupsd`/`lpadmin` | Not recommended | Per-queue PostScript Printer Description |
| `/etc/cups/lpoptions`, `~/.cups/lpoptions` | `lpoptions` | Yes | System-wide / per-user default destination and options |
| `/etc/cups/client.conf`, `~/.cups/client.conf` | admin | **Yes** | *Client-side* `ServerName` — points a host at a remote `cupsd` with no local scheduler |
| `/etc/printcap` | `cupsd` | **No** | Legacy compatibility file, regenerated (`Printcap` in `cups-files.conf`) |
| `/var/spool/cups/` | `cupsd` | **No** | Durable job spool |
| `/var/log/cups/{error,access,page}_log` | `cupsd` | n/a | Diagnostics, HTTP/IPP audit, page accounting |
| `/usr/lib/cups/backend/`, `/usr/lib/cups/filter/` | package | n/a | Executables; a backend must be `root`-owned and non-world-writable or `cupsd` refuses to run it |

> **Exam trap.** Directives that name a file, directory, user or group live in `cups-files.conf`; everything else lives in `cupsd.conf`. Putting `ErrorLog` in `cupsd.conf` is a hard startup failure, not a warning.

---

## 3. Technical comparisons and trade-offs

### 3.1 Transport backends

| Backend | Device URI | Wire protocol | Job status back-channel | Accounting | When it is the right answer |
|---|---|---|---|---|---|
| `socket` | `socket://10.42.7.55:9100` | Raw TCP (AppSocket/JetDirect) | None — write-and-pray | Page counts unavailable | ZPL/EPL label printers, lowest latency, no negotiation |
| `ipp` / `ipps` | `ipp://host/ipp/print` | IPP over HTTP/1.1 (+TLS) | Full `job-state`, `printer-state-reasons` | Yes | **Default for anything manufactured after ~2012** |
| `lpd` | `lpd://host/queue` | RFC 1179 | Minimal | Poor | Legacy appliances, print servers on embedded firmware |
| `usb` | `usb://HP/LaserJet%20M404dn?serial=VNC3K12345` | USB printer class | Device-dependent | Partial | Physically attached; **blocks containerisation** |
| `dnssd` | `dnssd://Name._ipp._tcp.local/?uuid=…` | Resolves to `ipp` | Full | Yes | Desktops on a flat LAN; **never** in a routed/pod network |
| `beh` | `beh:/1/3/5/socket://10.42.7.55:9100` | Wrapper (cups-filters) | Inherits | Inherits | Retry/failover wrapper: *don't disable, 3 attempts, 5 s apart* |
| `file` | `file:///var/spool/print-archive/out.prn` | Local write | n/a | n/a | Capture-to-disk for testing; requires `FileDevice Yes` |

Trade-off in one line: **`socket` gives you speed and blindness; `ipp` gives you observability and a TLS/auth surface.** A warehouse that must alert on "printer out of labels" cannot use `socket`, because there is no back-channel to alert from — the SNMP supply query (`snmp://`) or IPP is the only source.

### 3.2 Driver models

| Model | How the queue is created | PPD on disk? | Coupling to vendor | Lifecycle risk |
|---|---|---|---|---|
| **Classic PPD + filters** | `lpadmin -m foomatic:…ppd` or `-P /path/file.ppd` | Yes | High — a vendor binary filter is often required | PPD support is deprecated in CUPS 2.x and **removed in CUPS 3.x** |
| **IPP Everywhere / driverless** | `lpadmin -m everywhere` | Generated on the fly (2.x), none in 3.x | None — the printer advertises its own capabilities | Requires the device to be reachable *at queue-creation time* |
| **Printer Applications** | An IPP service (often a snap/container) that fronts a legacy device | No | Isolated inside the application | The forward-compatible replacement for vendor filters |
| **Raw queue** (`-m raw`, no filters) | `lpadmin -v socket://… ` with no model | No | None | Application must emit device-ready bytes (ZPL, PCL, PostScript) |

For SRE work the important row is the last one. Label printing is almost always a **raw queue**: the application generates ZPL, and any filter in the path is a corruption risk. You express that with `lp -o raw` or by giving the queue no PPD at all.

### 3.3 Spooling architecture options

| Option | Durability | Duplicate-output risk | Observability | Operational cost |
|---|---|---|---|---|
| App writes straight to `socket://:9100` | None — bytes lost on TCP failure | High (app-level retry re-sends) | Whatever the app logs | Lowest to build, highest to run |
| Local `cupsd` on every node | Per-node spool, no shared view | Low per node, high fleet-wide | `page_log` scattered across nodes | Fleet-wide config drift |
| **Central `cupsd`, clients via `client.conf`** | One durable spool | Low | Single `page_log`, single `access_log` | One stateful service to run |
| Central `cupsd` + message queue in front | Broker-durable | Low, with idempotency keys | Full | Highest; justified only for irreversible high-value output |

The third row is the standard answer, and it is what the manifests in §4 build. It is also the pattern the exam cares about: clients carry `/etc/cups/client.conf` with `ServerName`, run no local scheduler, and every `lp`/`lpstat` transparently targets the central server.

### 3.4 Command lineages — System V vs BSD

Both families ship with CUPS and both are exam material. They are not aliases; the option letters collide.

| Task | System V | BSD | Notes |
|---|---|---|---|
| Submit a job | `lp -d queue file` | `lpr -P queue file` | `lp` prints the job ID to stdout; `lpr` is silent |
| Copies | `lp -n 3` | `lpr -# 3` | |
| List queued jobs | `lpstat -o` | `lpq -P queue` | `lpq -a` = all queues |
| Cancel a job | `cancel 412` | `lprm 412` | `lprm -` cancels the invoking user's jobs |
| Cancel everything on a queue | `cancel -a queue` | — | `cancel -a -x queue` also purges job history |
| Show destinations | `lpstat -p -d` | — | `lpstat -t` = everything |
| Show device URIs | `lpstat -v` | — | |
| Hold / release | `lp -H hold` / `lp -H resume -i 412` | — | |
| Move jobs | `lpmove 412 other` or `lpmove src dst` | — | Drain procedure primitive |

Administrative commands have no BSD twin: `lpadmin`, `lpinfo`, `lpoptions`, `cupsaccept` / `cupsreject`, `cupsenable` / `cupsdisable`, `cupsctl`.

> **The single most-missed distinction:** `cupsaccept`/`cupsreject` control whether the queue **accepts new jobs**; `cupsenable`/`cupsdisable` control whether the queue **sends jobs to the device**. A maintenance drain is `cupsreject` (stop intake) followed by waiting for the spool to empty. A device swap is `cupsdisable` (keep accepting, stop transmitting) so nothing is lost.

---

## 4. Complete infrastructure

### 4.1 `/etc/cups/cupsd.conf` — production scheduler configuration

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

### 4.3 Declarative queue definitions

CUPS has no native declarative layer — `printers.conf` is *output*, not input. The supported way to make queues reproducible is to drive `lpadmin`, which is idempotent for an existing queue.

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

### 4.4 systemd hardening (bare-metal / VM deployment)

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

> `NoNewPrivileges=no` is deliberate: `cupsd` starts as root, then `setuid()`s to `User lp` to exec filters. Setting it to `yes` breaks the filter chain on some distributions. Everything else is tightened around that one requirement.

Legacy RFC 1179 clients (older appliances, embedded scanners) need the LPD shim, socket-activated so it consumes nothing when idle:

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

`-o document-format=application/octet-stream` forces raw pass-through. Without it, `cups-lpd` lets CUPS auto-type the stream, and a ZPL payload that happens to start with printable ASCII gets run through `texttopdf` and destroyed.

### 4.5 Kubernetes: central print server

The honest constraints, stated before the manifests:

- **`replicas: 1`, `strategy: Recreate`.** Two schedulers sharing one physical device duplicate output. There is no leader election in CUPS.
- **USB printers are out of scope in a pod.** Reaching `usb://` needs `/dev/bus/usb` host mounts and node pinning; if you have USB devices, run `cupsd` on that node as a systemd unit (§4.4) and leave the cluster out of it.
- **mDNS does not cross the pod network.** Every queue uses an explicit `ipp://` or `socket://` URI. `Browsing Off` in §4.1 reflects this.
- **`/etc/cups` must be writable and durable** because `cupsd` rewrites `printers.conf`. A ConfigMap cannot be mounted there directly; an init container seeds admin-owned files into the PVC.

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

> The CronJob as written mounts its own `emptyDir` and therefore reads nothing — it is the shape, not a working export, because a `CronJob` pod cannot mount the Deployment's `emptyDir`. In a real deployment, either make `logs` a second RWX PVC, or replace the CronJob with a sidecar in the same pod. Stated plainly rather than left as a silent bug.

### 4.6 Client-side configuration

Clients run **no local scheduler**. This is the piece that most deployments get wrong by installing `cups` everywhere.

```apache
# /etc/cups/client.conf on every client host
ServerName print.internal.example.com:631
Encryption IfRequested
```

Per-invocation override, useful in CI containers and debugging:

```bash
export CUPS_SERVER=print.internal.example.com:631
lpstat -t
```

Per-user defaults land in `~/.cups/lpoptions`, system-wide defaults in `/etc/cups/lpoptions`:

```bash
lpoptions -d hp-lj-m404-floor2
lpoptions -p hp-lj-m404-floor2 -o sides=two-sided-long-edge -o media=A4
```

---

## 5. CLI sessions with real output

### 5.1 Discovering what the host can talk to

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

`lpinfo -v` lists *available devices and schemes*; `lpinfo -m` lists *available drivers/models*:

```console
$ lpinfo -m | head -5
everywhere IPP Everywhere™
raw Raw Queue
drv:///sample.drv/generic.ppd Generic PostScript Printer
drv:///sample.drv/generpcl.ppd Generic PCL Laser Printer
gutenprint.5.3://escp2-p50/expert Epson Stylus Photo 750 - CUPS+Gutenprint v5.3.4
```

Driverless probing before you commit to a queue definition:

```console
$ ippfind --timeout 3
ipp://HP0123AB.local:631/ipp/print

$ driverless list
"driverless:ipp://HP0123AB.local:631/ipp/print" en "HP" "HP LaserJet M404dn, driverless, cups-filters 1.28.17" "MFG:HP;MDL:LaserJet M404dn;CMD:PDF,PWGRaster,PCLm;"
```

### 5.2 Creating and inspecting queues

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

Note the two independent axes reported separately: *accepting requests* (intake) and *enabled/idle* (transmission).

Options the queue actually supports:

```console
$ lpoptions -p hp-lj-m404-floor2 -l
PageSize/Media Size: *A4 Letter Legal Executive A5 Custom.WIDTHxHEIGHT
InputSlot/Media Source: *Auto Tray1 Tray2 Manual
Duplex/2-Sided Printing: DuplexNoTumble DuplexTumble *None
ColorModel/Print Color Mode: *Gray
Resolution/Resolution: 300dpi *600dpi 1200dpi
print-quality/Print Quality: 3 *4 5
```

### 5.3 Submitting, watching, and manipulating jobs

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

Holding, releasing, moving and cancelling:

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

### 5.4 Maintenance: drain vs. isolate

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

### 5.5 Scheduler-level knobs

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

### 5.6 Accounting

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

Enforced quotas, per queue:

```console
$ sudo lpadmin -p hp-lj-m404-floor2 \
    -o job-quota-period=604800 \
    -o job-page-limit=500 \
    -o job-k-limit=51200

$ lpstat -p hp-lj-m404-floor2 --long | grep -i quota
	Quotas: page-limit=500 k-limit=51200 period=604800
```

`job-quota-period` is a sliding window in seconds; `job-page-limit` and `job-k-limit` are the ceilings *per user* within that window. This is the only native rate limit CUPS gives you, and it is the cheapest defence against a runaway loop dumping 40 000 pages overnight.

---

## 6. Verification and failure diagnosis

### 6.1 Ladder of verification, cheapest first

| Rung | Command | What it proves |
|---|---|---|
| 0 | `sudo /usr/sbin/cupsd -t` (`echo $?`) | The config parses. Nothing else. |
| 1 | `systemctl is-active cups && lpstat -r` | The scheduler is running and answering IPP |
| 2 | `lpstat -t` | Queues exist, with the intended URIs, and their two state axes |
| 3 | `nc -vz 10.42.7.55 9100` / `ippfind` | The device is reachable at L4 from *this* host |
| 4 | `ipptool -tv ipp://…/ipp/print get-printer-attributes.test` | The device answers IPP and reports its real state |
| 5 | `lp -d q /usr/share/cups/data/testprint` | The whole chain — filters, backend, device — works end to end |
| 6 | `grep <job-id> /var/log/cups/page_log` | Paper actually moved, and how many sheets |

Rungs 0–4 are free and non-destructive. Rung 5 consumes physical media; do it once, deliberately.

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

`marker-levels 34` is your toner SLI. Scrape it; do not wait for a user ticket.

### 6.2 State vocabulary

**`printer-state`:** `3` = idle, `4` = processing, `5` = stopped.
**`job-state`:** `3` pending, `4` held, `5` processing, `6` stopped, `7` canceled, `8` aborted, `9` completed.

Common `printer-state-reasons` and what they actually mean operationally:

| Reason | Meaning | First action |
|---|---|---|
| `none` | Healthy | — |
| `media-empty-warning` / `media-empty-error` | Tray empty | Load media; the queue self-recovers under `retry-job` |
| `media-jam-error` | Physical jam | Clear; `cupsenable` if the error policy stopped the queue |
| `toner-low-warning` / `toner-empty-error` | Consumable | Replace; alert threshold at `marker-levels < 15` |
| `cups-waiting-for-job-completed` | Backend finished, device has not confirmed | Usually benign on `socket`; if persistent, `-o cups-waiting-for-job-completed=false` |
| `connecting-to-device` (persistent) | Backend cannot open the transport | L3/L4 problem — go to §6.4 |
| `paused` | `cupsdisable` was issued | `cupsenable`; check who paused it and why |

### 6.3 Reading `error_log`

Severity is the first character of every line: `A` alert, `C` critical, `E` error, `W` warning, `N` notice, `I` info, `D` debug, `d` debug2.

```console
$ sudo tail -n 6 /var/log/cups/error_log
W [27/Aug/2026:10:41:25 -0300] [Job 411] The printer is not responding.
E [27/Aug/2026:10:41:55 -0300] [Job 411] Unable to connect to 10.42.7.55:9100: Connection timed out
I [27/Aug/2026:10:42:25 -0300] [Job 411] Retrying job in 30 seconds...
E [27/Aug/2026:10:44:31 -0300] [Job 411] Job stopped due to backend errors; please consult the error_log file for details.
E [27/Aug/2026:10:44:31 -0300] [Job 411] Stopping printer because it is not responding.
I [27/Aug/2026:10:44:31 -0300] Printer "zebra-zt411-dock" stopped.
```

Turning on debug logging for a single reproduction, then turning it back off — debug logging is verbose enough to fill a volume:

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

### 6.4 Failure taxonomy

| Symptom | Most likely cause | Confirming check | Fix |
|---|---|---|---|
| `lpstat: Bad file descriptor` / `No destinations added` | Scheduler not running, or `client.conf`/`CUPS_SERVER` points at the wrong host | `systemctl is-active cups`; `lpstat -h host -r` | Start `cups`; correct `ServerName` |
| Queue `disabled since …` with `not responding` | Backend exit 1/4 plus `printer-error-policy=stop-printer` | `error_log` grep for the job id | Fix transport, then `cupsenable` |
| Jobs pile up in `pending`, printer idle | Queue is *disabled* but still *accepting* | `lpstat -p` vs `lpstat -a` | `cupsenable <queue>` |
| `lp` returns "not accepting requests" | `cupsreject` was issued (often by a `preStop` hook that never got reverted) | `lpstat -a` shows the reason string | `cupsaccept <queue>` |
| Job goes to `completed`, nothing prints | Raw data sent to a filtered queue, or wrong page description language | `page_log` shows pages; device shows nothing | Use `-o raw` / a raw queue for ZPL/PCL |
| Label printer emits pages of garbage ASCII | CUPS auto-typed ZPL as text and ran `texttopdf` | `error_log`: `Request file type is text/plain` | Raw queue, or `cups-lpd -o document-format=application/octet-stream` |
| `Unable to connect … Connection timed out` | L3/L4: VLAN, NetworkPolicy egress, printer asleep | `nc -vz host 9100`; `ip route get <host>` | Network path; add the CIDR to the egress rule |
| `Unable to connect … Connection refused` | Right host, wrong port/protocol (`socket` at an IPP-only device) | `nmap -p 515,631,9100 <host>` | Correct the device URI scheme |
| Queue creation with `-m everywhere` fails | Device unreachable *at creation time*, or not IPP Everywhere | `driverless list`; `ipptool …` | Make it reachable first, or use an explicit PPD |
| `cupsd` refuses to start after an edit | A file/dir/user directive placed in `cupsd.conf` instead of `cups-files.conf` | `cupsd -t`; `journalctl -u cups -n 30` | Move the directive |
| `cupsd` starts, but every job dies instantly | Filter or backend not `root`-owned or world-writable | `ls -l /usr/lib/cups/backend/socket` | `chown root:root`, `chmod 0700`/`0755` |
| Everything correct, jobs still fail, no obvious log | MAC policy denial | `ausearch -m avc -c cupsd -ts recent`; `journalctl -k \| grep -i apparmor` | Adjust the SELinux boolean / AppArmor profile |

### 6.5 Isolating the filter chain

When a job fails *before* the backend, run the filter by hand. Filters take a fixed argv (`job-id user title copies options [file]`) and read stdin if no file is given:

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

That two-command sequence tells you exactly which link broke, without consuming paper and without re-reading a debug log. Set `PPD=` in the environment when a filter needs one:

```console
$ PPD=/etc/cups/ppd/hp-lj-m404-floor2.ppd \
    /usr/lib/cups/filter/gstoraster 414 sre "manual test" 1 "" /tmp/out.pdf > /tmp/out.ras
$ ls -l /tmp/out.ras
-rw-r--r--. 1 sre sre 8421376 Aug 27 11:22 /tmp/out.ras
```

And to test a backend in isolation, bypassing the scheduler entirely:

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

### 6.6 Exporting queue health as metrics

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

Alerting rules worth having from day one:

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

`CupsQueueNotAccepting` is the rule that catches the most common real incident: someone ran `cupsreject` for a maintenance window and the window ended without a `cupsaccept`. Jobs are not lost — they are refused at submission, and the submitting application usually swallows the error.

---

## 7. Command and file reference

**Job submission and control:** `lp`, `lpr`, `lpq`, `lprm`, `cancel`, `lpstat`, `lpmove`
**Administration:** `lpadmin`, `lpinfo`, `lpoptions`, `cupsaccept`, `cupsreject`, `cupsenable`, `cupsdisable`, `cupsctl`, `cupsd -t`
**Diagnostics:** `ipptool`, `ippfind`, `driverless`, `cupstestppd`
**Files:** `/etc/cups/cupsd.conf`, `/etc/cups/cups-files.conf`, `/etc/cups/printers.conf`, `/etc/cups/classes.conf`, `/etc/cups/client.conf`, `/etc/cups/lpoptions`, `~/.cups/lpoptions`, `/etc/cups/ppd/`, `/etc/printcap`, `/var/spool/cups/`, `/var/log/cups/{error,access,page}_log`
**Ports:** IPP `631/tcp` (and `631/udp` for legacy CUPS browsing), AppSocket `9100/tcp`, LPD `515/tcp`, mDNS `5353/udp`, SNMP `161/udp`

The two invariants worth carrying out of this topic:

1. **Intake and transmission are separate switches.** `cupsaccept`/`cupsreject` ≠ `cupsenable`/`cupsdisable`. Choosing the wrong one during maintenance either loses work or fails to protect the device.
2. **`printers.conf` is state, `cupsd.conf` is configuration.** Reconcile queues with `lpadmin` from a declaration you keep in version control; never hand-edit the files the scheduler owns.

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