# Guía de estudio para especialista LPI-702 BSD: Tema 713.6 — Manage Printing and Print Jobs

**Certificación:** LPI BSD Specialist (Examen 702-100, Versión 1.0)  
**Tema:** 713.6 Manage Printing and Print Jobs  
**Ponderación:** 1.67  
**Audiencia objetivo:** Senior SREs, Systems Architects y Systems Administrators que operan entornos Unix basados en BSD.

---

## 1. Production Architecture & Operational Motivation

En la infraestructura empresarial UNIX y BSD, el spooling de impresión y la gestión de trabajos (job management) representan un límite crítico entre la generación de documentos a nivel de capa de aplicación, la serialización de red y el procesamiento raster a nivel de hardware. Los subsistemas de impresión deben manejar la concurrencia, los timeouts de red, la inanición de recursos (resource starvation) y la conversión de formatos sin detener los hilos de la aplicación (application threads) ni consumir excesivos buffers del kernel.

Los entornos BSD se basan en dos paradigmas principales de impresión:
1. **Traditional Line Printer Daemon (`lpd`)**: El subsistema histórico de spooling de BSD que cumple con el RFC 1179 (Line Printer Daemon Protocol). Opera a través de un pipeline de spooling ligero impulsado por demonios y gestionado por `/etc/printcap`.
2. **Common Unix Printing System (`CUPS`)**: Un sistema de impresión modular compatible con IPP (Internet Printing Protocol, RFC 2911/8010) que utiliza archivos PPD (PostScript Printer Description), pipelines de filtrado de tipos MIME y autorización RBAC explícita.

### Architectural Breakdown: Classic BSD LPD Spooling Subsystem

```
 +------------------+     lpr     +------------------------+
 | Application / UI | ----------->| /var/spool/output/lpd/ |
 +------------------+             +------------------------+
                                              |
                                      lpd daemon reads
                                    cf* (control) & df* (data)
                                              |
                                              v
                                  +-----------------------+
                                  | Input Filter (/if)    |
                                  | Format Conversion     |
                                  +-----------------------+
                                              |
                                              v
                              +-------------------------------+
                              | Network (TCP 515 / RFC 1179)  |
                              |  OR Direct Device (/dev/lpt0) |
                              +-------------------------------+
```

El demonio `lpd` opera de forma asíncrona monitoreando los directorios de spool definidos en `/etc/printcap`. Cuando se envía un trabajo a través de `lpr`:
1. **Control File (`cfA*`)**: Contiene metadatos (usuario, nombre del trabajo, clase, flags de formato, argumentos de filtro).
2. **Data File (`dfA*`)**: Contiene el payload nativo o sin formato (PostScript, texto plano, PCL).
3. **Lock File (`lock`)**: Evita que múltiples procesos `lpd` escriban en el mismo dispositivo físico simultáneamente.

Comprender la mecánica de `lpd` y `cupsd` es esencial para mantener pipelines de spooling deterministas, asegurar (hardening) los límites de la red de impresión y solucionar bloqueos (deadlocks) de trabajos de impresión en entornos BSD.

---

## 2. Technical Comparisons & Architectural Trade-offs

La selección entre el `lpd` nativo de BSD y el `cupsd` moderno requiere evaluar los recursos del sistema, las restricciones de los drivers y los requerimientos del protocolo de red.

| Metric / Dimension | Classic BSD `lpd` | Modern `CUPS` (`cupsd`) |
| :--- | :--- | :--- |
| **Primary Protocol** | LPR/LPD (RFC 1179 sobre puerto TCP 515) | IPP/IPPS (RFC 2911 / RFC 8010 sobre puerto TCP 631) |
| **Configuration Model** | Archivo único `/etc/printcap` (capacidades clave-valor delimitadas por dos puntos) | Directorio modular (`/usr/local/etc/cups/cupsd.conf`, `printers.conf`, directorio PPD) |
| **Memory Footprint** | Micro (< 5 MB RAM idle), cero dependencias | Moderada (20-80 MB RAM), depende de `dbus`, `avahi`, `libcups` |
| **Authentication & TLS** | Verificación de IP basada en host (`/etc/hosts.lpd`), sin TLS nativo | Aplicación de TLS/SSL, autenticación HTTP Basic/Digest, integración PAM |
| **Filtering Mechanism** | Ejecutable monolítico/scripts de shell definidos por capacidad (`if`, `of`, `xf`) | Grafo dinámico de conversión de tipos MIME (`pstoraster`, `rastertoepson`, filtros CUPS) |
| **Dynamic Discovery** | Configuración manual o endpoints IP fijos | Difusión automática de colas mDNS / DNS-SD / Avahi |
| **Fault Isolation** | Alto — modelo de proceso simple con locks de spool aislados por impresora | Moderado — proceso de servidor HTTP compartido que aloja pipelines de filtrado internos |

---

## 3. Production Infrastructure & Complete Configurations

### A. Production `/etc/printcap` (BSD Classic LPD)

La base de datos `/etc/printcap` utiliza pares clave-valor separados por dos puntos al estilo termcap. Las líneas se continúan utilizando barras invertidas al final (`\`).

```ini
# /etc/printcap - Production BSD LPD Configuration
# Default local queue with input filtering and strict accounting
lp|laser_floor2|Floor 2 HP LaserJet Pro:\
        :lp=/dev/ulpt0:\
        :sd=/var/spool/output/lpd/laser_floor2:\
        :lf=/var/log/lpd-errs:\
        :af=/var/backups/printer_acct:\
        :if=/usr/local/libexec/ps2pdf_filter.sh:\
        :mx#0:\
        :sh:

# Network-attached LPD print queue (RFC 1179 passthrough)
net_eng|engineering_plotter|HP DesignJet Network:\
        :lp=:\
        :rm=10.0.20.50:\
        :rp=raw:\
        :sd=/var/spool/output/lpd/net_eng:\
        :lf=/var/log/lpd-errs:\
        :mx#0:\
        :sh:
```

### B. Complete Custom Input Filter (`/usr/local/libexec/ps2pdf_filter.sh`)

Los filtros de entrada en `lpd` reciben opciones pasadas a través de switches estándar (`-c`, `-w`, `-l`, `-n`, `-h`) y manejan el streaming de `stdin` a `stdout`.

```bash
#!/bin/sh
# /usr/local/libexec/ps2pdf_filter.sh
# Production LPD Input Filter for ASCII to PostScript / Pass-through conversion
set -eu

LOGFILE="/var/log/lpd-filter.log"
DATE_STAMP=$(date '+%Y-%m-%d %H:%M:%S')

# Parse stdin first 4 bytes to check for PostScript magic bytes (%!PS)
HEADER=$(head -c 4)

exec 3>&1

{
    echo "[${DATE_STAMP}] Processing print job for filter..." >> "${LOGFILE}"

    if [ "${HEADER}" = "%!PS" ]; then
        # Direct PostScript pass-through: concatenate header and remaining stream
        echo "[${DATE_STAMP}] Format detected: PostScript raw pass-through" >> "${LOGFILE}"
        { printf "%s" "${HEADER}"; cat; }
    else
        # Plain text: convert ASCII to PostScript via enscript or text2ps
        echo "[${DATE_STAMP}] Format detected: Plain Text (converting via enscript)" >> "${LOGFILE}"
        { printf "%s" "${HEADER}"; cat; } | /usr/local/bin/enscript -B -p - 2>> "${LOGFILE}"
    fi
}

exit 0
```

Asegúrese de configurar los permisos de ejecución y el directorio de spool correctamente:

```bash
# Set appropriate owner and access control on spool and filter
chown -R daemon:daemon /var/spool/output/lpd/laser_floor2 /var/spool/output/lpd/net_eng
chmod 755 /usr/local/libexec/ps2pdf_filter.sh
chmod 770 /var/spool/output/lpd/*
```

### C. Hardened CUPS Configuration (`/usr/local/etc/cups/cupsd.conf`)

A continuación se muestra un archivo `/usr/local/etc/cups/cupsd.conf` completo de nivel de producción, adaptado para seguridad e aislamiento de subredes empresariales.

```apache
# /usr/local/etc/cups/cupsd.conf - Enterprise Hardened Configuration
LogLevel info
PageLogFormat %p %u %j %T %P %C %{job-billing} %{job-originating-host-name} %{job-name} %{media} %{sides}
MaxLogSize 1m

# Network Listening Configuration
Listen 127.0.0.1:631
Listen 10.0.10.5:631
Listen /var/run/cups.sock

# Encryption Settings
ServerAlias *
DefaultEncryption IfRequested

# Security and Policy Controls
<Location />
  Order allow,deny
  Allow from 127.0.0.1
  Allow from 10.0.10.0/24
</Location>

<Location /admin>
  Order allow,deny
  Allow from 10.0.10.0/24
  Require user @SYSTEM
  Encryption Required
</Location>

<Location /admin/conf>
  AuthType Default
  Require user @SYSTEM
  Order allow,deny
  Allow from 10.0.10.250
</Location>

<Policy default>
  JobPrivateAccess default
  JobPrivateValues default
  SubscriptionPrivateAccess default
  SubscriptionPrivateValues default

  <Limit Create-Job Print-Job Print-URI Validate-Job>
    Order allow,deny
    Allow from 10.0.10.0/24
  </Limit>

  <Limit Send-Document Send-URI Cancel-Job Hold-Job Release-Job Restart-Job Purge-Jobs Set-Job-Attributes Create-Job-Subscription Renew-Subscription Close-Job Get-Notifications Reprocess-Job Cancel-Current-Job Suspend-Current-Job Resume-Job Cancel-My-Jobs Get-Notifications Get-Job-Attributes>
    Require user @OWNER @SYSTEM
    Order allow,deny
    Allow from 10.0.10.0/24
  </Limit>

  <Limit CUPS-Add-Modify-Printer CUPS-Delete-Printer CUPS-Add-Modify-Class CUPS-Delete-Class CUPS-Set-Default CUPS-Pause-Printer CUPS-Resume-Printer>
    AuthType Default
    Require user @SYSTEM
    Order allow,deny
  </Limit>
</Policy>
```

### D. OpenBSD / FreeBSD Packet Filter (`/etc/pf.conf`) Snippet

```pf
# /etc/pf.conf - Print Services Firewall Enforcement
ext_if = "em0"
admin_net = "10.0.10.0/24"

# Table of allowed print clients
table <print_clients> { 10.0.10.0/24, 10.0.20.0/24 }

# Block unapproved inbound traffic to print ports
block in log on $ext_if proto tcp from any to any port { 515, 631 }

# Pass legitimate LPD and IPP requests
pass in quick on $ext_if proto tcp from <print_clients> to $ext_if port { 515, 631 } flags S/SA keep state
```

### E. System Initialization (`/etc/rc.conf`)

Habilite los servicios nativos LPD o CUPS en `/etc/rc.conf` de FreeBSD/NetBSD:

```sh
# /etc/rc.conf
# Enable classic LPD
lpd_enable="YES"
lpd_flags="-l"    # Log incoming requests via syslog

# Alternatively, enable CUPS (disable lpd if cupsd is used)
cupsd_enable="YES"
```

---

## 4. Real-world CLI Operations & Expected Terminal Outputs

### A. Classic BSD Print Management (`lpc`, `lpr`, `lpq`, `lprm`)

#### 1. Checking Spool Status (`lpc status`)
```bash
$ lpc status
laser_floor2:
        queuing is enabled
        printing is enabled
        1 entry in spool area
        printer is ready and printing
net_eng:
        queuing is enabled
        printing is disabled
        0 entries in spool area
        daemon present
```

#### 2. Controlling Print Queues (`lpc`)
El comando `lpc` se puede ejecutar de forma interactiva o no interactiva para deshabilitar el encolado (queuing), detener la impresión o reordenar la prioridad de los trabajos.

```bash
# Disable queuing for maintenance and stop the active spooler daemon
$ sudo lpc disable net_eng
net_eng:
        queuing disabled

$ sudo lpc stop net_eng
net_eng:
        printing disabled
        daemon killed
```

#### 3. Submitting Jobs (`lpr`)
Envíe un trabajo PostScript a una impresora específica con propiedad de trabajo y metadatos personalizados:

```bash
$ lpr -P laser_floor2 -J "Q3_Financial_Report" -#2 /usr/local/share/docs/report.ps
```

#### 4. Inspecting Queue Details (`lpq`)
```bash
$ lpq -P laser_floor2
Rank   Owner      Job  Files                                 Total Size
active dbrown     42   report.ps                             1048576 bytes
1st    jdoe       43   (standard input)                      51200 bytes
```

#### 5. Removing Print Jobs (`lprm`)
Elimine un trabajo activo por ID, o limpie todos los trabajos de un usuario específico:

```bash
# Remove specific job 42
$ sudo lprm -P laser_floor2 42
dfA042host1 dequeued
cfA042host1 dequeued

# Remove all jobs owned by current user
$ lprm -P laser_floor2 -
```

---

### B. CUPS Management CLI (`lpadmin`, `lpstat`, `cupsenable`, `cupsaccept`)

#### 1. Provisioning a CUPS Queue (`lpadmin`)
Agregue una nueva impresora de red IPP utilizando un archivo de driver PPD existente:

```bash
$ sudo lpadmin -p Eng_LaserJet \
    -E \
    -v ipp://10.0.20.50/ipp/print \
    -m raw \
    -L "Building B, Room 302" \
    -D "HP LaserJet Engineering Queue"
```

#### 2. Querying Queue Status and Defaults (`lpstat`)
```bash
$ lpstat -p Eng_LaserJet -d -o
system default destination: Eng_LaserJet
printer Eng_LaserJet is idle.  enabled since Thu Aug  6 14:22:10 2026
Eng_LaserJet-101      sysadmin          20480   Thu Aug  6 14:30:00 2026
```

#### 3. Enabling Queues and Accepting Jobs
```bash
$ sudo cupsaccept Eng_LaserJet
destination "Eng_LaserJet" is now accepting jobs.

$ sudo cupsenable Eng_LaserJet
printer "Eng_LaserJet" is now enabled.
```

---

## 5. Production Verification & Diagnostics Guide

Cuando los trabajos de impresión fallan, se estancan o se corrompen, los SREs deben seguir una metodología de diagnóstico sistemática para rastrear los vectores de falla a través del spooler del SO, los ejecutables de filtro, los permisos del sistema y los sockets de red.

```
       Print Job Submitted (lpr / lp)
                     |
                     v
   [ Step 1: Daemon Verification ]
     Is lpd / cupsd process running?
             /               \
          (No)               (Yes)
           |                   |
    Start Daemon               v
   (service lpd start)   [ Step 2: Spool Directory Audit ]
                         Check lock files, permissions (daemon:daemon)
                         & disk space (/var/spool/output/lpd/)
                               |
                               v
                         [ Step 3: Filter Pipeline Execution ]
                         Test filter script manually on input file:
                         cat file.ps | /path/to/filter > /tmp/out.raw
                               |
                               v
                         [ Step 4: Network & Socket Testing ]
                         Test TCP 515/631 via nc / tcpdump:
                         nc -zv <printer_ip> 515
```

### Troubleshooting Workflow

#### Step 1: Daemon & Process Verification
Verifique que el proceso `lpd` o `cupsd` esté ejecutándose:

```bash
$ pgrep -lf lpd
9821 /usr/sbin/lpd -l

$ service lpd status
lpd is running as pid 9821.
```

Si el demonio no está ejecutándose, revise `/var/log/messages` o la salida de syslog en busca de errores de inicialización:

```bash
$ tail -n 20 /var/log/messages | grep lpd
```

#### Step 2: Spool Directory and Lock File Inspection
Los trabajos estancados en el `lpd` clásico a menudo se deben a archivos lock huérfanos (stale lock files) que quedan tras un apagado no limpio del sistema o un script de filtro que colapsó.

```bash
$ ls -la /var/spool/output/lpd/laser_floor2/
total 16
drwxrwx---  2 daemon  daemon  512 Aug  6 14:00 .
drwxr-xr-x  4 root    daemon  512 Aug  6 13:30 ..
-rw-r--r--  1 daemon  daemon    4 Aug  6 14:00 cfA042host1
-rw-r--r--  1 daemon  daemon  1048576 Aug  6 14:00 dfA042host1
-rw-r--r--  1 daemon  daemon   19 Aug  6 14:00 lock
```

Inspeccione el contenido del archivo `lock` (contiene el PID activo y el archivo de control actual):

```bash
$ cat /var/spool/output/lpd/laser_floor2/lock
9822 cfA042host1
```

Si el PID 9822 no existe (`kill -0 9822` no devuelve dicho proceso), elimine el lock huérfano:

```bash
$ sudo lpc stop laser_floor2
$ sudo rm /var/spool/output/lpd/laser_floor2/lock
$ sudo lpc restart laser_floor2
```

#### Step 3: Filter Pipeline Debugging
Para aislar los problemas del filtro de entrada de los problemas de spooling, ejecute el filtro definido directamente desde la línea de comandos con el usuario `daemon`:

```bash
$ sudo -u daemon /usr/local/libexec/ps2pdf_filter.sh < /tmp/test_document.ps > /tmp/filtered_output.raw
$ echo $?
0
```

Inspeccione la salida de registro (log output) generada por el script del filtro:

```bash
$ cat /var/log/lpd-filter.log
[2026-08-06 14:05:12] Processing print job for filter...
[2026-08-06 14:05:12] Format detected: PostScript raw pass-through
```

#### Step 4: Network & Socket Diagnostic Tracing
Si la impresión remota en red a través de LPR (parámetro `rm` en `/etc/printcap`) o CUPS IPP falla, verifique la alcanzabilidad de la red en la capa 4 y realice un rastreo de paquetes (packet tracing):

```bash
# Check connectivity to destination printer on port 515 (LPD) or 631 (IPP)
$ nc -zv 10.0.20.50 515
Connection to 10.0.20.50 515 port [tcp/printer] succeeded!

# Monitor raw LPR traffic using tcpdump
$ sudo tcpdump -ni em0 -s 0 -A 'host 10.0.20.50 and tcp port 515'
14:10:00.123456 IP 10.0.10.5.1023 > 10.0.20.50.515: Flags [P.], seq 1:3, ack 1, win 65535, length 2
E..a..@.@..v...n...r...s...#...P..W.....\002raw\n
```

---

## 6. References

* **LPI BSD Specialist Certification Overview**:  
  [https://www.lpi.org/our-certifications/bsd-specialist-overview/](https://www.lpi.org/our-certifications/bsd-specialist-overview/)

* **FreeBSD Handbook: Chapter 9, Printing**:  
  [https://docs.freebsd.org/en/books/handbook/printing/](https://docs.freebsd.org/en/books/handbook/printing/)

* **OpenBSD `lpd(8)` Manual Page**:  
  [https://man.openbsd.org/lpd.8](https://man.openbsd.org/lpd.8)

* **OpenBSD `printcap(5)` Manual Page**:  
  [https://man.openbsd.org/printcap.5](https://man.openbsd.org/printcap.5)

* **CUPS System Administrator Documentation**:  
  [https://www.cups.org/doc/overview.html](https://www.cups.org/doc/overview.html)

* **RFC 1179 — Line Printer Daemon Protocol**:  
  [https://datatracker.ietf.org/doc/html/rfc1179](https://datatracker.ietf.org/doc/html/rfc1179)

* **RFC 2911 — Internet Printing Protocol/1.1: Model and Semantics**:  
  [https://datatracker.ietf.org/doc/html/rfc2911](https://datatracker.ietf.org/doc/html/rfc2911)