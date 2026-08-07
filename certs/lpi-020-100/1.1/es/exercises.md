# LPI Security Essentials (Exam 020-100) — Topic 1.1: Security Concepts

**Objetivo del examen:** LPI Security Essentials (Código de examen: 020-100, Versión 1.0)  
**Peso del tema:** 20  
**Referencia oficial:** [LPI Security Essentials Overview & Objectives](https://www.lpi.org/our-certifications/security-essentials-overview/)  
**Rol objetivo:** Senior SRE / Platform Security Architect  

---

## Technical Overview & Core Architecture

El Topic 1.1 establece los principios fundamentales de seguridad requeridos para diseñar y operar entornos Linux robustecidos (hardened) en sistemas de producción modernos. Este módulo se enfoca en operacionalizar los marcos de trabajo principales (core frameworks) en lugar de tratarlos como teoría abstracta:

1. **The CIA Triad (Confidentiality, Integrity, Availability):**
   - **Confidentiality:** Restringir el acceso a los principales autorizados mediante permisos DAC/MAC, encryption at rest (LUKS/dm-crypt) y encryption in transit (TLS 1.3, SSH).
   - **Integrity:** Garantizar que los datos permanezcan sin corrupción ni manipulación. Gestionado mediante hashes criptográficos (SHA-256/512), firmas digitales (GPG/PGP) y flags de archivos inmutables (`chattr +i`).
   - **Availability:** Garantizar que los sistemas y servicios permanezcan operacionales bajo carga o ataque. Implementado usando límites de recursos de cgroups v2, límites de reinicio de systemd, balanceo de carga HA y Rate Limiting (algoritmos leaky bucket de `iptables`/`nftables`).

2. **The AAA Framework & Non-Repudiation:**
   - **Authentication (¿Quién eres?):** PAM (`pam_unix`, `pam_faillock`), SSH Public Key Auth (ED25519), FIDO2/WebAuthn.
   - **Authorization (¿Qué puedes hacer?):** Permisos de archivos de Linux (Linux file modes), POSIX ACLs (`setfacl`), control de acceso de grano fino en sudoers, políticas MAC de SELinux/AppArmor.
   - **Accounting / Auditing (¿Qué hiciste?):** Subsistema de auditoría de Linux (`auditd`), registro estructurado de `journald` (structured logging), envío centralizado de logs sobre TLS (rsyslog/fluentbit).
   - **Non-Repudiation:** Garantizar que una acción no pueda ser negada por el actor que la realizó mediante firmas criptográficas (firma GPG) y logs de auditoría de solo anexado (append-only) a prueba de manipulaciones (`auditd` kernel rules vinculadas a almacenamiento inmutable).

3. **Defense in Depth & Least Privilege:**
   - **Least Privilege:** Postura de denegación por defecto (default-deny). Restringir los procesos a las Linux capabilities mínimas (eliminación de `CAP_NET_BIND_SERVICE`, `CAP_SYS_ADMIN`) y permisos de archivos necesarios para la ejecución.
   - **Attack Surface Reduction:** Minimizar los sockets de red abiertos, eliminar paquetes binarios innecesarios, desactivar módulos del kernel sin usar (`/etc/modprobe.d/`), y delimitar el alcance (scoping) de las unidades de servicio de systemd con parámetros de aislamiento estrictos (`ProtectSystem=strict`, `PrivateTmp=yes`, `NoNewPrivileges=yes`).

---

## Guided Laboratory Exercises

---

### Exercise 1: Demonstrating Integrity, Confidentiality, and Non-Repudiation with Cryptographic Controls

En este ejercicio, crearás un activo confidencial, generarás un checksum criptográfico de integridad, implementarás inmutabilidad de archivos de solo anexado (append-only) y verificarás el Non-Repudiation digital utilizando GnuPG.

#### Step 1: Create a Secure Confidential Asset and Verify Permissions
Crea un directorio `/etc/secure_app/` restringido a `root` con permisos `0700`. Genera un archivo de configuración que contenga credenciales sensibles de base de datos.

```bash
sudo mkdir -p /etc/secure_app
sudo chmod 0700 /etc/secure_app
sudo tee /etc/secure_app/db.conf > /dev/null << 'EOF'
DB_HOST=127.0.0.1
DB_USER=app_prod
DB_PASS=u8F#kL2$mN9!vP0q
EOF
sudo chmod 0600 /etc/secure_app/db.conf
ls -la /etc/secure_app/db.conf
```

**Expected Output:**
```text
-rw------- 1 root root 64 Aug  7 00:40 /etc/secure_app/db.conf
```

#### Step 2: Establish an Integrity Baseline using SHA-256
Genera una línea base (baseline) de hash criptográfico del archivo para satisfacer el componente de Integrity de la tríada CIA.

```bash
sha256sum /etc/secure_app/db.conf | sudo tee /etc/secure_app/db.conf.sha256
cat /etc/secure_app/db.conf.sha256
```

**Expected Output:**
```text
e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  /etc/secure_app/db.conf
```

#### Step 3: Enforce System-Level File Immutability
Utiliza los atributos de archivo ext4/xfs de Linux (`chattr`) para hacer que la línea base sea inmutable, evitando su manipulación incluso por la cuenta `root`.

```bash
sudo chattr +i /etc/secure_app/db.conf.sha256
lsattr /etc/secure_app/db.conf.sha256
```

**Expected Output:**
```text
----i---------e------- /etc/secure_app/db.conf.sha256
```

Prueba modificar el archivo inmutable con privilegios de `root`:
```bash
sudo rm -f /etc/secure_app/db.conf.sha256
```

**Expected Output:**
```text
rm: cannot remove '/etc/secure_app/db.conf.sha256': Operation not permitted
```

#### Step 4: Digital Signature Generation for Non-Repudiation
Genera un par de claves GPG en modo batch para una cuenta de administrador y crea una firma digital separada (detached signature, `.sig`) para el archivo de configuración.

```bash
gpg --batch --generate-key << 'EOF'
Key-Type: RSA
Key-Length: 3072
Subkey-Type: RSA
Subkey-Length: 3072
Name-Real: Security Auditor
Name-Email: auditor@production.local
Expire-Date: 0
%no-protection
%commit
EOF

gpg --detach-sign --armor /etc/secure_app/db.conf
ls -la /etc/secure_app/db.conf.asc
```

**Expected Output:**
```text
-rw-r--r-- 1 user user 838 Aug  7 00:41 /etc/secure_app/db.conf.asc
```

Verifica la integridad de la firma para Non-Repudiation:
```bash
gpg --verify /etc/secure_app/db.conf.asc /etc/secure_app/db.conf
```

**Expected Output:**
```text
gpg: Signature made Fri 07 Aug 2026 00:41:00 AM UTC
gpg:                using RSA key 4F8A9B2C3D4E5F6A7B8C9D0E1F2A3B4C5D6E7F8A
gpg: Good signature from "Security Auditor <auditor@production.local>" [ultimate]
```

---

#### Comprehension Check: Exercise 1

1. **Question 1.1:** Un atacante obtiene acceso completo a la shell como `root` en el servidor a través de una vulnerabilidad de ejecución remota de código (RCE). Intenta modificar `/etc/secure_app/db.conf.sha256` para ocultar una configuración de base de datos modificada. ¿Por qué falla `rm -f` y qué secuencia de comandos debe ejecutar el atacante para eludir este control?
2. **Question 1.2:** En términos del marco AAA y Non-Repudiation, ¿cuál es la diferencia técnica crítica entre verificar un archivo usando un hash SHA-256 en comparación con verificarlo con una firma separada (detached signature) de GPG?

---

### Exercise 2: AAA Implementation — Least Privilege Authorization and Audit Logging

En este ejercicio, aplicarás el principio de Least Privilege utilizando reglas granulares de `sudoers` e implementarás la rama de Accounting de AAA utilizando el subsistema de auditoría de Linux (`auditd`).

#### Step 1: Create a Restricted Service Administrator Role
Crea un usuario llamado `deployer` sin acceso de superusuario.

```bash
sudo useradd -m -s /bin/bash deployer
sudo id deployer
```

**Expected Output:**
```text
uid=1001(deployer) gid=1001(deployer) groups=1001(deployer)
```

#### Step 2: Write a Granular Sudoers Policy (Least Privilege)
Configura `/etc/sudoers.d/99-deployer` para permitir que `deployer` recargue y verifique el estado de `nginx.service` **únicamente**, sin requerir contraseña, mientras se niega explícitamente la ejecución arbitraria de comandos o la creación de shells del sistema.

```bash
sudo tee /etc/sudoers.d/99-deployer > /dev/null << 'EOF'
Cmnd_Alias NGINX_MGMT = /bin/systemctl status nginx, /bin/systemctl reload nginx
deployer ALL=(root) NOPASSWD: NGINX_MGMT
EOF
sudo chmod 0440 /etc/sudoers.d/99-deployer
sudo visudo -c -f /etc/sudoers.d/99-deployer
```

**Expected Output:**
```text
/etc/sudoers.d/99-deployer: parsed OK
```

Valida los permisos como el usuario `deployer`:
```bash
sudo -u deployer sudo systemctl status nginx || true
sudo -u deployer sudo systemctl restart nginx
```

**Expected Output:**
```text
[sudo] password for deployer is required
# OR:
Sorry, user deployer is not allowed to execute '/bin/systemctl restart nginx' as root on hostname.
```

#### Step 3: Configure Kernel-Level Accounting via Auditd
Agrega una regla de auditoría activa orientada a los cambios en los directorios `/etc/sudoers` y `/etc/sudoers.d/`.

```bash
sudo tee /etc/audit/rules.d/sudoers.rules > /dev/null << 'EOF'
-w /etc/sudoers -p wa -k privilege_escalation_changes
-w /etc/sudoers.d/ -p wa -k privilege_escalation_changes
EOF
sudo augenrules --load
sudo auditctl -l
```

**Expected Output:**
```text
-w /etc/sudoers -p wa -k privilege_escalation_changes
-w /etc/sudoers.d/ -p wa -k privilege_escalation_changes
```

#### Step 4: Trigger and Query Accounting Logs
Ejecuta `touch` sobre un archivo temporal dentro de `/etc/sudoers.d/` para activar el hook de auditoría del kernel, luego analiza (parse) la entrada del log usando `ausearch`.

```bash
sudo touch /etc/sudoers.d/.test_audit_trigger
sudo rm -f /etc/sudoers.d/.test_audit_trigger
sudo ausearch -k privilege_escalation_changes --raw | ausearch -m PATH -i
```

**Expected Output:**
```text
type=PROCTITLE msg=audit(08/07/2026 00:43:12.104:482) : proctitle=touch /etc/sudoers.d/.test_audit_trigger 
type=PATH msg=audit(08/07/2026 00:43:12.104:482) : item=0 name=/etc/sudoers.d/.test_audit_trigger inode=262145 dev=08:01 mode=file,644 ouid=root ogid=root rdev=00:00 nametype=CREATE cap_fp=none cap_fi=none cap_fe=0 cap_fver=0 cap_innermost_rootuid=-1
type=SYSCALL msg=audit(08/07/2026 00:43:12.104:482) : arch=x86_64 syscall=openat success=yes exit=3 a0=AT_FDCWD a1=0x7ffe92a1b090 a2=O_CREAT|O_WRONLY|O_NOCTTY|O_NONBLOCK a3=0666 items=2 ppid=1234 pid=5678 auid=admin uid=root gid=root euid=root suid=root fsuid=root egid=root sgid=root fsgid=root tty=pts0 ses=1 comm=touch exe=/usr/bin/touch key=privilege_escalation_changes
```

---

#### Comprehension Check: Exercise 2

1. **Question 2.1:** Observa la salida de `ausearch` anterior. Identifica el campo que garantiza el Non-Repudiation al mostrar el usuario original que inició sesión, a pesar de que el comando se ejecutó con `euid=root`.
2. **Question 2.2:** Un administrador junior modifica `/etc/sudoers.d/99-deployer` a:  
   `deployer ALL=(ALL) NOPASSWD: /bin/systemctl *`  
   Explica por qué esto viola el principio de Least Privilege y describe cómo un atacante puede aprovechar esta regla específica con comodín (wildcard) para obtener una shell interactiva como `root`.

---

### Exercise 3: Attack Surface Reduction & Defense in Depth via Systemd Sandboxing

En este ejercicio, analizarás la superficie de ataque (attack surface) de un servicio del sistema, auditarás su puntuación de seguridad e implementarás propiedades de hardening de systemd para aplicar Defense in Depth.

#### Step 1: Analyze Service Attack Surface using systemd-analyze
Ejecuta una evaluación de seguridad contra una instancia sin hardening de un servicio de ejemplo (por ejemplo, `systemd-journal-upload.service` o un servicio web personalizado).

```bash
systemd-analyze security systemd-journal-upload.service | head -n 15
```

**Expected Output:**
```text
NAME                                  PART DESCRIPTION                              EXPOSURE
✔ PrivateNetwork=                     Service has access to network
❌ User=/Group=                        Service runs as root user                         9.2
❌ CapabilityBoundingSet=              Service has all capabilities                      0.2
❌ ProtectSystem=                      Service has full access to OS file system         0.2
❌ ProtectHome=                        Service has full access to home directories       0.2
...
OVERALL EXPOSURE LEVEL: 8.6 UNSAFE 🔴
```

#### Step 2: Implement Hardening Controls via Systemd Drop-in
Crea una configuración de sobrescritura drop-in en `/etc/systemd/system/systemd-journal-upload.service.d/override.conf` aplicando parámetros estrictos de sandboxing.

```bash
sudo mkdir -p /etc/systemd/system/systemd-journal-upload.service.d/
sudo tee /etc/systemd/system/systemd-journal-upload.service.d/override.conf > /dev/null << 'EOF'
[Service]
# Reduce filesystem exposure (Integrity & Confidentiality)
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
ReadOnlyPaths=/

# Reduce privilege escalation vectors (Least Privilege)
NoNewPrivileges=yes
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX

# Kernel and System Isolation (Defense in Depth)
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
MemoryDenyWriteExecute=yes
RestrictRealtime=yes
EOF

sudo systemctl daemon-reload
```

#### Step 3: Re-evaluate Service Exposure Score
Vuelve a evaluar la calificación de seguridad del servicio para verificar la reducción de la superficie de ataque.

```bash
systemd-analyze security systemd-journal-upload.service | head -n 15
```

**Expected Output:**
```text
NAME                                  PART DESCRIPTION                              EXPOSURE
✔ PrivateTmp=                         Service has private /tmp directory
✔ ProtectSystem=                      Service has strict access to OS file system
✔ ProtectHome=                        Service has no access to home directories
✔ NoNewPrivileges=                    Service cannot elevate privileges
✔ CapabilityBoundingSet=              Service capabilities strictly bounded
...
OVERALL EXPOSURE LEVEL: 2.1 OK 🟢
```

---

#### Comprehension Check: Exercise 3

1. **Question 3.1:** ¿Qué mecanismo de vulnerabilidad bloquea `NoNewPrivileges=yes` a nivel del kernel de Linux y cómo respalda esto el principio de Least Privilege?
2. **Question 3.2:** Contrasta los mecanismos de defensa de `ProtectSystem=strict` y `ProtectKernelTunables=yes`. ¿Qué características del kernel de Linux restringen estas configuraciones?

---

<details>
<summary><strong>Click to expand Answer Key & Technical Explanations</strong></summary>

### Exercise 1 Answer Key

* **1.1:** 
  - `rm -f` falla porque el atributo `+i` (inmutable) establecido por `chattr` configura el flag `FS_IMMUTABLE_FL` en el inode dentro del controlador del sistema de archivos subyacente (ext4/xfs). La capa VFS rechaza las operaciones de escritura, desvinculación (unlink), renombrado y enlace para este inode independientemente del EUID `0` (root).
  - Para eludir esto, una cuenta `root` comprometida debe borrar explícitamente el atributo primero ejecutando:
    `sudo chattr -i /etc/secure_app/db.conf.sha256`
    seguido del comando de modificación/eliminación. *(Nota: Si las capabilities del kernel están restringidas mediante `CapabilityBoundingSet=~CAP_LINUX_IMMUTABLE` o política de SELinux, ni siquiera root puede eliminar el flag inmutable).*

* **1.2:** 
  - **SHA-256 Hash:** Proporciona únicamente verificación de **Integrity**. Demuestra si el contenido del archivo ha cambiado, pero no ofrece prueba de origen porque cualquier persona con acceso de escritura puede volver a calcular y reemplazar el digest SHA-256.
  - **GPG Detached Signature:** Proporciona **Integrity**, **Authentication** y **Non-Repudiation**. El digest del archivo se cifra utilizando la Private Key asimétrica del autor. Solo el poseedor de la Private Key correspondiente podría haber generado la firma. Por lo tanto, el firmante no puede denegar la autoría del documento (Non-Repudiation) y los consumidores pueden verificar la autenticidad utilizando la Public Key.

---

### Exercise 2 Answer Key

* **2.1:**
  - El campo `auid` (Audit User ID / loginuid).
  - Cuando un usuario inicia sesión (por ejemplo, `auid=1000`), el kernel fija `auid` dentro de la estructura de tareas del proceso. Incluso si el usuario ejecuta `su`, `sudo` o explota un binario setuid cambiando su `uid`/`euid` operativo a `0` (root), `auid` permanece fijado en `1000`. Esto garantiza **Accounting** y **Non-Repudiation** deterministas en los logs del sistema.

* **2.2:**
  - **Violación de Least Privilege:** `systemctl *` otorga acceso a todos los comandos del administrador de systemd, no solo al estado/recargas del ciclo de vida del servicio.
  - **Vector de explotación:** Un atacante puede utilizar características de `systemctl` para elevar privilegios a root de múltiples maneras:
    1. Ejecutando `sudo systemctl edit service_name --full`, lo que invoca un editor interactivo (por ejemplo, `SYSTEMD_EDITOR=/bin/bash sudo systemctl edit`), cayendo instantáneamente en una shell de root.
    2. Creando/ejecutando una unidad transitoria personalizada mediante `sudo systemctl run` o cargando una unidad de servicio maliciosa que contenga `ExecStart=/bin/bash -c "chmod +s /bin/bash"`.

---

### Exercise 3 Answer Key

* **3.1:**
  - `NoNewPrivileges=yes` establece el bit `PR_SET_NO_NEW_PRIVS` en el estado del proceso del servicio mediante `prctl()`.
  - Una vez configurado, los procesos hijo creados a través de `execve()` no pueden adquirir privilegios de ejecución que el proceso padre no poseyera de antemano. Esto deshabilita de manera efectiva la ejecución de binarios **SUID/SGID** (como `/usr/bin/sudo` o `/usr/bin/gpasswd`) y evita que las File System Capabilities (`setcap`) otorguen privilegios elevados durante la ejecución.

* **3.2:**
  - **`ProtectSystem=strict`:** Utiliza Mount Namespaces (`CLONE_NEWNS`) para montar todo el árbol del sistema de archivos del host (`/`, `/usr`, `/boot`, `/etc`) como solo lectura (`MS_RDONLY`) para el proceso del servicio, aislando los binarios y archivos de configuración de la aplicación de modificaciones no autorizadas.
  - **`ProtectKernelTunables=yes`:** Monta los directorios virtuales del sistema procfs y sysfs (`/proc/sys`, `/sys`, `/proc/sysrq-trigger`, `/proc/latency_stats`) como solo lectura. Esto evita que un servicio comprometido altere los parámetros en tiempo de ejecución del kernel (por ejemplo, variables sysctl como `net.ipv4.ip_forward` o configuraciones de gestión de memoria).

</details>