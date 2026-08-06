# Examen LPIC-3 303-300 (v3.0): Tema 4.1 - Operations Security

**Dominio de certificación**: LPIC-3 Security (Examen 303-300, Versión 3.0)  
**Tema**: 4.1 Operations Security  
**Peso**: 16.67  
**Fuentes oficiales de referencia**:
- [LPI LPIC-3 303 Overview](https://www.lpi.org/our-certifications/lpic-3-303-overview/)
- [LPI 303 Exam Objectives](https://www.lpi.org/our-certifications/exam-303-objectives)

---

## Mecánica técnica y visión general de la arquitectura

Operations Security (OpSec) a nivel de empresa en producción requiere el hardening de nodos Linux, el establecimiento de una verificación de integridad continua, la aplicación de límites granulares a las llamadas al sistema (system calls) y el mantenimiento de planos de control de auditoría a prueba de manipulaciones (tamper-evident).

```
                  +-------------------------------------------------------------+
                  |                      USERSPACE LINUX                        |
                  |                                                             |
                  |  +------------------------+     +------------------------+  |
                  |  |  systemd Sandboxed     |     |   AIDE & OpenSCAP      |  |
                  |  |  Service (Namespaces)  |     |   Integrity Scanner    |  |
                  |  +-----------+------------+     +-----------+------------+  |
                  |              |                              |               |
                  +--------------|------------------------------|---------------+
                                 | System Calls                 | File Queries /
                                 | (execve, openat)             | Hash Computation
                  ---------------+------------------------------+----------------
                  |                      LINUX KERNEL                           |
                  |                                                             |
                  |  +------------------------+     +------------------------+  |
                  |  |  seccomp / Capabilities|     |   Audit Subsystem      |  |
                  |  |  Enforcement Engine    |     |   (auditd / kauditd)   |  |
                  |  +------------------------+     +-----------+------------+  |
                  |                                             |               |
                  +---------------------------------------------|---------------+
                                                                v
                                                  /var/log/audit/audit.log
```

### 1. Mecánica de aislamiento de procesos y sandboxing del kernel
Las unidades modernas de systemd aprovechan las primitivas del kernel de Linux para implementar una defensa en profundidad operativa:
- **Namespaces (`CLONE_NEWNS`, `CLONE_NEWNET`, `CLONE_NEWPID`)**: `ProtectSystem=strict` y `ProtectHome=yes` vuelven a montar los árboles del sistema con `MS_RDONLY` y crean namespaces de montaje aislados por árbol de procesos.
- **Seccomp Filters (`prctl(PR_SET_SECCOMP)`)**: El filtrado de system calls intercepta syscalls a través de Berkeley Packet Filters (BPF) dentro del kernel antes de su ejecución, ejecutando `SIGSYS` o devolviendo `EPERM` cuando se emiten syscalls que no están en la lista blanca (whitelist).
- **Capabilities Bounding Set (`capset`)**: Elimina privilegios del kernel (tales como `CAP_SYS_ADMIN`, `CAP_NET_RAW`) evitando que los procesos con uid 0 realicen operaciones sin restricciones.

### 2. Ruta de intercepción del subsistema de auditoría
El subsistema de auditoría de Linux (`kauditd`) se engancha (hooks) en los puntos de entrada y salida de las llamadas al sistema dentro del kernel. Cuando un proceso emite un `execve` o modifica un inodo auditado, las reglas de `auditctl` evaluadas en la memoria del kernel envían paquetes netlink directamente al demonio `auditd`, omitiendo las instalaciones de registro estándar (`syslog`) para garantizar el no repudio.

### 3. Verificación criptográfica de la integridad de archivos
Herramientas como AIDE (Advanced Intrusion Detection Environment) calculan resúmenes criptográficos de mensajes (message digests $SHA256$, $SHA512$) y métricas de metadatos de inodos (ctime, mtime, inode, permisos, atributos extendidos) contra una base de datos de línea base (`aide.db.gz`). La detección de degradación de la integridad se basa en comparar los parámetros del estado del sistema de archivos en vivo contra firmas criptográficas precalculadas almacenadas en medios de solo lectura o en almacenamiento inmutable remoto.

---

## Ejercicios guiados

### Ejercicio 1: Análisis de hardening y sandboxing de servicios systemd

En este ejercicio, crearás un script de microservicio vulnerable, lo encapsularás dentro de una unidad de servicio systemd restringida, aplicarás directivas estrictas de sandboxing a nivel del kernel y medirás el perfil de hardening utilizando herramientas de evaluación de seguridad de systemd.

#### Paso 1: Crear un script binario de worker de API simulado
Crea una aplicación de worker simulada en `/usr/local/bin/dummy_worker.sh` que intente realizar escrituras ilegales en archivos e interacciones de red.

```bash
sudo tee /usr/local/bin/dummy_worker.sh > /dev/null << 'EOF'
#!/bin/bash
echo "[+] Starting Dummy Worker PID $$..."
echo "[+] Attempting write to /etc/test_tamper.txt..."
echo "unauthorized_data" > /etc/test_tamper.txt 2>&1 || echo "[-] WRITE FAILED: /etc/test_tamper.txt"

echo "[+] Attempting read from /home..."
ls -la /home 2>&1 || echo "[-] READ FAILED: /home"

sleep 3600
EOF

sudo chmod +x /usr/local/bin/dummy_worker.sh
```

#### Paso 2: Escribir un archivo de unidad systemd totalmente hardened
Crea `/etc/systemd/system/hardened-worker.service` con parámetros estrictos de Operational Security.

```ini
[Unit]
Description=Hardened Production Worker Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/dummy_worker.sh
User=nobody
Group=nogroup

# Operational Security Sandboxing Directives
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
NoNewPrivileges=yes
RestrictRealtime=yes
RestrictNamespaces=yes
CapabilityBoundingSet=

# System Call & Memory Execution Constraints
MemoryDenyWriteExecute=yes
SystemCallFilter=@system-service
SystemCallFilter=~@privileged ~@resources
SystemCallErrorNumber=EPERM

[Install]
WantedBy=multi-user.target
```

#### Paso 3: Recargar el demonio systemd, iniciar el servicio e inspeccionar los logs de stdout
Recarga systemd, inicia el servicio e inspecciona la salida operativa a través de `journalctl`.

```bash
sudo systemctl daemon-reload
sudo systemctl start hardened-worker.service
sudo journalctl -u hardened-worker.service -n 20 --no-pager
```

**Salida esperada:**
```text
-- Logs begin at Thu 2026-08-06 10:00:00 UTC. --
Aug 06 13:30:00 node01 systemd[1]: Started Hardened Production Worker Service.
Aug 06 13:30:00 node01 dummy_worker.sh[12451]: [+] Starting Dummy Worker PID 12451...
Aug 06 13:30:00 node01 dummy_worker.sh[12451]: [+] Attempting write to /etc/test_tamper.txt...
Aug 06 13:30:00 node01 dummy_worker.sh[12453]: /usr/local/bin/dummy_worker.sh: line 4: /etc/test_tamper.txt: Read-only file system
Aug 06 13:30:00 node01 dummy_worker.sh[12451]: [-] WRITE FAILED: /etc/test_tamper.txt
Aug 06 13:30:00 node01 dummy_worker.sh[12451]: [+] Attempting read from /home...
Aug 06 13:30:00 node01 dummy_worker.sh[12454]: ls: cannot open directory '/home': Permission denied
Aug 06 13:30:00 node01 dummy_worker.sh[12451]: [-] READ FAILED: /home
```

#### Paso 4: Evaluar la puntuación de la postura de seguridad usando `systemd-analyze`
Ejecuta la herramienta de puntuación de seguridad integrada de systemd contra el servicio para calcular las métricas de exposición.

```bash
sudo systemd-analyze security hardened-worker.service
```

**Salida esperada (truncada):**
```text
NAME                                  DESCRIPTION                                      EXPOSURE
✔ PrivateTmp=                         Service has a private /tmp dir                   0.0
✔ ProtectSystem=                      Service has strict protection on /usr /boot /etc 0.0
✔ ProtectHome=                        Service protects user home directories           0.0
✔ CapabilityBoundingSet=              Service has no capabilities                      0.0
✔ NoNewPrivileges=                    Service processes cannot gain new privileges     0.0
✔ SystemCallFilter=                   Service has restricted system calls              0.0
✔ MemoryDenyWriteExecute=             Service cannot create writable/executable memory 0.0

→ Overall exposure level for hardened-worker.service: 0.2 OK 🙂
```

---

#### Preguntas de verificación (Ejercicio 1)

1. ¿Por qué la escritura de archivo en `/etc/test_tamper.txt` falló con `Read-only file system` incluso si el proceso se ejecutó como `root` (antes de configurar `User=nobody`)?
2. ¿Qué característica explícita del kernel se habilita con `NoNewPrivileges=yes` y qué vector de ataque de seguridad mitiga completamente?

---

### Ejercicio 2: Implementación del Framework Avanzado de Auditoría de Linux (`auditd`)

En este ejercicio, desplegarás reglas personalizadas de auditoría del kernel para rastrear ejecuciones de shells de root, detectar cambios no autorizados de privilegios en archivos sensibles de identidad y consultar eventos de auditoría utilizando `ausearch` y `aureport`.

#### Paso 1: Configurar reglas persistentes de auditoría del kernel
Edita `/etc/audit/rules.d/audit.rules` (o `/etc/audit/rules.d/operations_security.rules`) para añadir monitores (watches) de Operational Security y rastreo de system calls.

```bash
sudo tee /etc/audit/rules.d/operations_security.rules > /dev/null << 'EOF'
## Delete all existing rules
-D

## Set buffer size (events)
-b 8192

## Failure Mode: 1=log, 2=panic
-f 1

## Watch critical configuration files for writes, executions, and attribute changes
-w /etc/passwd -p wa -k identity_tamper
-w /etc/shadow -p wa -k identity_tamper
-w /etc/sudoers -p wa -k privilege_tamper
-w /etc/sudoers.d/ -p wa -k privilege_tamper

## Monitor privilege escalation syscalls (execve by root/euid 0)
-a always,exit -F arch=b64 -S execve -F euid=0 -k root_command_execution
-a always,exit -F arch=b32 -S execve -F euid=0 -k root_command_execution

## Make rules immutable until reboot
-e 2
EOF
```

#### Paso 2: Cargar las reglas de auditoría en el espacio del kernel y verificar la configuración activa
Reinicia el servicio `auditd` (o ejecuta `augenrules --load`) y confirma las reglas activas cargadas en el kernel.

```bash
sudo augenrules --load
sudo auditctl -l
```

**Salida esperada:**
```text
-w /etc/passwd -p wa -k identity_tamper
-w /etc/shadow -p wa -k identity_tamper
-w /etc/sudoers -p wa -k privilege_tamper
-w /etc/sudoers.d/ -p wa -k privilege_tamper
-a always,exit -F arch=b64 -S execve -F euid=0 -k root_command_execution
-a always,exit -F arch=b32 -S execve -F euid=0 -k root_command_execution
-e 2
```

#### Paso 3: Generar eventos de seguridad y rastrear entradas de log en bruto
Ejecuta comandos que activen tanto monitores de escritura de archivos como la auditoría de `execve`.

```bash
# Trigger privilege_tamper watch
sudo touch /etc/sudoers.d/99_ops_test

# Query raw events using key identity
sudo ausearch -k privilege_tamper --raw | head -n 20
```

**Salida esperada:**
```text
type=PROCTITLE msg=audit(1786109430.123:402): proctitle=746F756368002F6574632F7375646F6572732E642F39395F6F70735F74657374
type=PATH msg=audit(1786109430.123:402): item=1 name="/etc/sudoers.d/99_ops_test" inode=131089 dev=08:01 mode=0100644 ouid=0 ogid=0 rdev=00:00 nametype=CREATE cap_fp=0 cap_fi=0 cap_fe=0 cap_fver=0 cap_fpver=0
type=PATH msg=audit(1786109430.123:402): item=0 name="/etc/sudoers.d/" inode=131075 dev=08:01 mode=040755 ouid=0 ogid=0 rdev=00:00 nametype=PARENT cap_fp=0 cap_fi=0 cap_fe=0 cap_fver=0 cap_fpver=0
type=CWD msg=audit(1786109430.123:402): cwd="/home/administrator"
type=SYSCALL msg=audit(1786109430.123:402): arch=c000003e syscall=257 success=yes exit=3 a0=ffffff9c a1=7ffd2a1b9e84 a2=941 a3=1b6 items=2 ppid=1120 pid=12890 auid=1000 uid=0 gid=0 euid=0 suid=0 fsuid=0 egid=0 sgid=0 fsgid=0 tty=pts0 ses=2 comm="touch" exe="/usr/bin/touch" key="privilege_tamper"
```

#### Paso 4: Generar un informe de auditoría resumido de alto nivel
Ejecuta `aureport` para generar estadísticas de resumen operativo para eventos clave y ejecutables.

```bash
sudo aureport -k --summary
```

**Salida esperada:**
```text
Key Summary Report
===============================================
# date time key rows
===============================================
1. 08/06/2026 13:30:30 privilege_tamper 1
2. 08/06/2026 13:30:30 root_command_execution 14
```

---

#### Preguntas de verificación (Ejercicio 2)

1. ¿Cuál es el impacto operativo de configurar `-e 2` en `/etc/audit/rules.d/operations_security.rules`? ¿Cómo debe realizar un SRE las modificaciones posteriores a las reglas de auditoría?
2. En el log de eventos de auditoría `SYSCALL`, ¿cuál es la distinción precisa entre `uid`, `euid` y `auid`?

---

### Ejercicio 3: Monitoreo de Integridad de Archivos (FIM) con AIDE

En este ejercicio, configurarás AIDE para establecer la línea base de los directorios de binarios del sistema y configuración, construirás la base de datos criptográfica, simularás una modificación no autorizada de archivos del sistema y analizarás los informes de degradación.

#### Paso 1: Instalar y configurar las especificaciones de reglas de AIDE
Instala AIDE y edita `/etc/aide/aide.conf` para establecer definiciones estrictas de escaneo criptográfico.

```bash
# On Debian/Ubuntu systems: sudo apt-get install -y aide
# On RHEL/Rocky Linux: sudo dnf install -y aide

sudo tee -a /etc/aide/aide.conf > /dev/null << 'EOF'

# Custom Operational Security Rule Definitions
# p: permissions, i: inode, n: number of links, u: user, g: group, s: size, m: mtime, c: ctime, md5: md5 checksum, sha512: sha512 checksum
OPS_SEC_STRICT = p+i+n+u+g+s+m+c+sha512

# Watch paths
/usr/bin OPS_SEC_STRICT
/usr/sbin OPS_SEC_STRICT
/etc/pam.d OPS_SEC_STRICT
!/var/log
!/tmp
EOF
```

#### Paso 2: Inicializar la base de datos de línea base y activar la BD de producción
Inicializa la base de datos de hashes criptográficos y muévela al estado operativo de producción.

```bash
sudo aide --init
sudo mv /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz
```

#### Paso 3: Simular la alteración no autorizada de un archivo / inserción de un troyano
Modifica un binario del sistema monitoreado en `/usr/bin/login` o añade una cadena a `/etc/pam.d/common-auth`.

```bash
# Simulate a backdoor comment injection into a core PAM configuration file
echo "# Unauthorized modification by intruder" | sudo tee -a /etc/pam.d/common-auth > /dev/null
```

#### Paso 4: Ejecutar la verificación de integridad y analizar los resultados de las desviaciones
Ejecuta `aide --check` para comparar el estado actual del host con la línea base.

```bash
sudo aide --check
```

**Salida esperada:**
```text
AIDE 0.18 found differences between the database and the filesystems!
Start timestamp: 2026-08-06 13:35:00

Summary:
  Total number of entries: 4521
  Added entries:           0
  Removed entries:         0
  Changed entries:         1

---------------------------------------------------
Changed entries:
---------------------------------------------------

f =...C..a.. : /etc/pam.d/common-auth

---------------------------------------------------
Detailed information about changes:
---------------------------------------------------

File: /etc/pam.d/common-auth
 Size     : 1420                             , 1461
 MTime    : 2026-08-06 12:00:00.000000000    , 2026-08-06 13:34:55.123456789
 CTime    : 2026-08-06 12:00:00.000000000    , 2026-08-06 13:34:55.123456789
 SHA512   : e3b0c44298fc1c149afbf4c8996fb924 , 9b74c2d8292c29c8e8ec434237198e0e
            b2d71597f7481a7b1b369c733ee04746   7730e201b17b2b694b294e339d0c6792
```

---

#### Preguntas de verificación (Ejercicio 3)

1. Si un atacante modifica `/etc/pam.d/common-auth` y luego actualiza el `mtime` del archivo a su marca de tiempo original usando `touch -m -t`, ¿por qué AIDE seguirá marcando el archivo como alterado?
2. ¿Por qué la base de datos de línea base de producción `aide.db.gz` debe transferirse a un medio de solo lectura o a un almacenamiento remoto de escritura única (por ejemplo, AWS S3 Bucket con Object Lock) en entornos de SRE en producción?

---

### Ejercicio 4: Auditoría automatizada de cumplimiento y vulnerabilidades mediante OpenSCAP

En este ejercicio, ejecutarás un escaneo de cumplimiento automatizado de SCAP Security Guide contra el benchmark Center for Internet Security (CIS) / DISA STIG usando `oscap`, generarás un script de remediación en shell y analizarás las métricas de cumplimiento.

#### Paso 1: Instalar herramientas OpenSCAP y contenido de SCAP Security Guide
Asegúrate de que los binarios de la CLI de OpenSCAP y los DataStreams de SSG estén instalados.

```bash
# On RHEL/Rocky Linux: sudo dnf install -y openscap-scanner scap-security-guide
# On Debian/Ubuntu: sudo apt-get install -y libopenscap8 ssg-debian OR ssg-ubuntu

# Locate installed DataStream XML file
DS_PATH="/usr/share/xml/scap/ssg/content/ssg-rhel9-ds.xml"
[ ! -f "$DS_PATH" ] && DS_PATH="/usr/share/xml/scap/ssg/content/ssg-ubuntu2204-ds.xml"
echo "[+] Using DataStream: $DS_PATH"
```

#### Paso 2: Listar los perfiles de seguridad disponibles en el DataStream
Consulta los perfiles soportados por el DataStream instalado.

```bash
oscap info "$DS_PATH" | grep -E "Id: profile"
```

**Salida esperada (truncada):**
```text
        Id: profile_cis
        Id: profile_cis_server_l1
        Id: profile_cis_workstation_l1
        Id: profile_pci_dss
        Id: profile_disa_stig
```

#### Paso 3: Ejecutar el escaneo de evaluación XCCDF y generar un informe HTML
Ejecuta una auditoría automatizada contra el perfil `cis_server_l1` y captura los resultados en XML y un informe HTML interactivo.

```bash
sudo oscap xccdf eval \
  --profile xccdf_org.ssgproject.content_profile_cis_server_l1 \
  --results /tmp/scan_results.xml \
  --report /tmp/security_report.html \
  "$DS_PATH"
```

**Salida esperada (truncada de la salida estándar de CLI):**
```text
Title   Ensure /tmp is Located On a Separate Partition
Rule    xccdf_org.ssgproject.content_rule_mount_option_tmp_separate_partition
Result  fail

Title   Ensure SSH Protocol 2 is Enforced
Rule    xccdf_org.ssgproject.content_rule_sshd_allow_only_protocol2
Result  pass

Title   Ensure Password Expiration 365 Days or Less
Rule    xccdf_org.ssgproject.content_rule_accounts_maximum_age_login_defs
Result  fail

OpenSCAP Evaluation Finished. Results written to /tmp/scan_results.xml.
Report written to /tmp/security_report.html.
```

#### Paso 4: Generar un script de remediación en bash automatizado a partir de los resultados de la evaluación
Genera un script de solución ejecutable que contenga los comandos exactos para remediar las comprobaciones de auditoría fallidas.

```bash
sudo oscap xccdf generate fix \
  --profile xccdf_org.ssgproject.content_profile_cis_server_l1 \
  --fix-type bash \
  --output /tmp/remediate_compliance.sh \
  /tmp/scan_results.xml

head -n 25 /tmp/remediate_compliance.sh
```

**Salida esperada (truncada):**
```bash
#!/bin/bash
# OpenSCAP Automated Fix Script
# Profile: CIS Server Level 1 Benchmark

echo "Applying fix for rule: xccdf_org.ssgproject.content_rule_accounts_maximum_age_login_defs"
if grep -q "^PASS_MAX_DAYS" /etc/login.defs; then
	sed -i 's/^PASS_MAX_DAYS.*/PASS_MAX_DAYS 365/' /etc/login.defs
else
	echo "PASS_MAX_DAYS 365" >> /etc/login.defs
fi
```

---

#### Preguntas de verificación (Ejercicio 4)

1. ¿Cuál es la diferencia fundamental entre las definiciones **OVAL (Open Vulnerability and Assessment Language)** y las estructuras **XCCDF (Extensible Configuration Checklist Description Format)** dentro de un paquete SCAP DataStream?
2. ¿Por qué ejecutar un script de remediación de OpenSCAP generado automáticamente (`remediate_compliance.sh`) directamente en un entorno de producción en vivo se considera un antipatrón y cómo deberían los SRE desplegar las soluciones de manera segura?

---

<details>
<summary><strong>Haz clic aquí para revelar las soluciones y respuestas técnicas detalladas</strong></summary>

### Soluciones del Ejercicio 1

1. **Mecánica de fallo del intento de escritura en modo solo lectura**:  
   Establecer `ProtectSystem=strict` crea un nuevo namespace de montaje para el árbol de procesos del servicio y vuelve a montar `/usr`, `/boot` y `/etc` (más `/sys` y `/proc` en modos hardened) como **Read-Only (`MS_RDONLY`)**. Incluso si un proceso se ejecuta con UID efectivo 0 (root), las operaciones del sistema de archivos del kernel se bloquean en la capa VFS (Virtual File System) antes de que se evalúen las comprobaciones de capacidades (`CAP_DAC_OVERRIDE`). Los privilegios de root no pueden anular una restricción de montaje VFS de solo lectura.

2. **Mecánica del kernel de NoNewPrivileges**:  
   `NoNewPrivileges=yes` establece el flag del kernel `PR_SET_NO_NEW_PRIVS` mediante `prctl()`. Este flag se hereda a través de las llamadas a `execve()` y no se puede desactivar. Garantiza que los procesos hijo no puedan adquirir privilegios elevados a través de bits ejecutables SUID/SGID (por ejemplo, `/usr/bin/sudo` o binarios setuid personalizados) o capabilities de archivos. Esto neutraliza las vulnerabilidades de escalada local de privilegios (LPE) que se basan en el abuso de ejecutables SUID.

---

### Soluciones del Ejercicio 2

1. **Impacto de la inmutabilidad de reglas del kernel (`-e 2`)**:  
   La regla `-e 2` bloquea la configuración de auditoría dentro de la memoria del kernel. Una vez cargadas, las reglas de auditoría ya no se pueden modificar, agregar o eliminar a través de `auditctl` o `augenrules`, ni se puede desactivar el demonio de auditoría sin un reinicio completo del kernel. Para aplicar reglas de auditoría modificadas, un SRE debe actualizar los archivos en `/etc/audit/rules.d/` y realizar un reinicio ordenado del host.

2. **Atributos de identidad de usuario en logs de auditoría**:
   - `uid`: Real User ID del proceso que ejecuta el comando.
   - `euid`: Effective User ID bajo el cual se ejecuta la llamada actual (por ejemplo, `0` al ejecutar mediante `sudo`).
   - `auid` (Audit ID / Login UID): La identidad del usuario original registrada por `pam_loginuid` en el inicio de sesión inicial (SSH, TTY o consola). Incluso si un usuario ejecuta `su` o `sudo` para cambiar de identidad varias veces, el `auid` permanece fijado a su identidad autenticada inicial, garantizando el no repudio durante la investigación de incidentes.

---

### Soluciones del Ejercicio 3

1. **Detección de AIDE más allá de las marcas de tiempo**:  
   AIDE evalúa múltiples campos de metadatos y hashes criptográficos. Modificar un archivo altera su tiempo de cambio de estado de inodo (`ctime`), el cual no se puede manipular con herramientas estándar de espacio de usuario (`touch` solo actualiza `atime` y `mtime`). Además, AIDE comprueba el resumen de contenido criptográfico $SHA512$. Dado que SHA-512 es resistente a colisiones, alterar el contenido del archivo altera el resumen calculado independientemente de la manipulación de la marca de tiempo.

2. **Justificación del hardening de la base de datos**:  
   Si un atacante obtiene acceso de root en un nodo objetivo, puede modificar `/etc/pam.d/common-auth` y, posteriormente, recalcular y sobrescribir `/var/lib/aide/aide.db.gz` para enmascarar sus modificaciones. Transportar la base de datos de línea base a un almacenamiento inmutable/de solo lectura garantiza que la herramienta de verificación de integridad evalúe el estado del host en vivo frente a una fuente de benchmark no manipulada.

---

### Soluciones del Ejercicio 4

1. **Roles de OVAL vs. XCCDF en SCAP**:
   - **XCCDF**: Framework estructurado de alto nivel para especificar listas de verificación de seguridad, benchmarks, reglas legibles por humanos y perfiles de cumplimiento. Define *qué* estados de configuración deberían existir.
   - **OVAL**: El motor técnico de aserción de bajo nivel. OVAL proporciona esquemas XML ejecutables por máquina que comprueban estados específicos del sistema (por ejemplo, comprobar versiones específicas de paquetes, permisos de archivos del sistema o claves de registro a través de sondas del kernel). XCCDF hace referencia a las comprobaciones de OVAL para determinar los estados de aprobado/fallido (pass/fail).

2. **Riesgos operativos del script de remediación**:  
   La ejecución a ciegas de scripts de remediación generados automáticamente puede degradar gravemente los sistemas de producción al alterar parámetros de red (por ejemplo, bloquear interfaces de red activas), cambiar permisos en directorios de datos operativos críticos o romper aplicaciones heredadas (legacy). Las mejores prácticas de SRE requieren traducir los hallazgos de OpenSCAP a código idempotente de Configuration Management (Ansible, Puppet, Terraform) probado dentro de pipelines de CI/CD antes de su despliegue en entornos de producción.

</details>