# LPIC-3 Security (Exam 303-300 v3.0): Topic 333 - Control de Acceso (Laboratorios Guiados de Producción y Diagnóstico Avanzado)

## 1. Arquitectura Técnica y Mecánica Interna

### 1.1 Control de Acceso Discrecional (DAC), ACLs POSIX y Atributos Extendidos

El Control de Acceso Discrecional (DAC) en Linux se basa en la propiedad (*ownership*): el propietario de un objeto (archivo, directorio, *socket*) determina los permisos de acceso asignados a otros sujetos (usuarios, grupos).

```
   +-----------------------------------------------------------------------+
   |                            VFS Layer (Inodes)                         |
   +-----------------------------------------------------------------------+
        |                                   |                         |
        v                                   v                         v
+------------------+             +--------------------+     +-------------------+
|  Traditional DAC |             |     POSIX ACLs     |     | Extended Attrs    |
| (mode_t: rwxrwxrwx|             | (Default & Access) |     |   (xattr: user,   |
|   + SUID/SGID/   |             | (system.posix_acl) |     |  trusted, sec)    |
|   Sticky Bit)    |             +--------------------+     +-------------------+
+------------------+                       |                          |
        |                                  v                          v
        |                        +--------------------+     +-------------------+
        +----------------------->| Effective Permission|----->| Kernel Permission |
                                 | Calculation (Mask) |     | Enforcement Check |
                                 +--------------------+     +-------------------+
```

#### Permisos DAC Tradicionales y Bits Especiales
- **Bits Estándar (`rwx`)**: Lectura (`4`), Escritura (`2`), Ejecución (`1`) mapeados entre Propietario (User), Grupo (Group) y Otros (Others).
- **SUID (`setuid`, bit `4000`)**: Cuando se establece en un ejecutable, el proceso se ejecuta con el UID efectivo (`eUID`) del propietario del archivo en lugar del usuario que lo invoca (por ejemplo, `/usr/bin/passwd`).
- **SGID (`setgid`, bit `2000`)**: En ejecutables, se ejecuta con el GID efectivo (`eGID`) del grupo propietario. En directorios, los archivos recién creados heredan el grupo propietario del directorio en lugar del grupo primario del usuario creador.
- **Sticky Bit (`1000`)**: En directorios, restringe la eliminación o el renombrado de archivos dentro del directorio al propietario del archivo, al propietario del directorio o a `root` (por ejemplo, `/tmp`).

#### Listas de Control de Acceso POSIX (POSIX ACLs)
Las ACLs POSIX extienden los permisos estándar de 3 niveles permitiendo la asignación granular de permisos a usuarios o grupos específicos.
- **Access ACLs**: Evaluadas durante los intentos de acceso a archivos/directorios.
- **Default ACLs**: Aplicadas únicamente a directorios. Heredadas por los subdirectorios y archivos recién creados dentro de ese directorio.
- **La Máscara ACL (`mask::`)**: Define los permisos máximos permitidos para todos los usuarios nombrados, el grupo propietario y los grupos nombrados. Cuando se aplica una ACL a un archivo, los bits de permisos tradicionales de "grupo" (`rwx`) representan la **máscara** ACL, NO los permisos del grupo propietario. Cualquier cambio a través de `chmod g-w` modifica la máscara ACL, restringiendo los permisos en todas las entradas ACL.

#### Atributos Extendidos (`xattr`)
Los atributos extendidos asocian pares arbitrarios `nombre:valor` con los *inodes* de archivos fuera de los metadatos estándar. Están estructurados en cuatro espacios de nombres (*namespaces*) principales del *kernel*:
1. `user`: Accesible por usuarios no privilegiados, sujeto a los permisos de archivo DAC estándar.
2. `trusted`: Restringido a procesos con `CAP_SYS_ADMIN`. Utilizado para metadatos a nivel de sistema.
3. `security`: Utilizado por los Módulos de Seguridad del Kernel (LSM) como SELinux (por ejemplo, `security.selinux`).
4. `system`: Utilizado por el *kernel* para Listas de Control de Acceso (`system.posix_acl_access`, `system.posix_acl_default`).

---

### 1.2 Arquitectura de Control de Acceso Obligatorio (MAC): SELinux, AppArmor y SMACK

El Control de Acceso Obligatorio (MAC) aplica políticas de acceso a nivel de todo el sistema definidas por un administrador. Bajo MAC, los propietarios de recursos no pueden flexibilizar los permisos de seguridad sobre sus objetos; el *kernel* del sistema impone las decisiones de política independientemente de la configuración de DAC.

```
                              User Space Application / Process
                                             |
                                             v
                                  System Call Interface
                                             |
                                             v
                                        VFS / DAC
                                  (File Mode / POSIX ACLs)
                                             |
                                             v (If DAC Passes)
 +----------------------------------------------------------------------------------+
 | Linux Security Module (LSM) Framework                                            |
 |                                                                                  |
 |   +--------------------------------------------------------------------------+   |
 |   |                              SELinux Architecture                        |   |
 |   |                                                                          |   |
 |   |   Subject Context                  Object Context                        |   |
 |   | (system_u:system_r:httpd_t)     (system_u:object_r:httpd_sys_content_t)  |   |
 |   |              \                           /                               |   |
 |   |               v                         v                                |   |
 |   |             +-------------------------------+                            |   |
 |   |             |     Access Vector Cache (AVC) |                            |   |
 |   |             +-------------------------------+                            |   |
 |   |               /                           \                              |   |
 |   |        (Cache Miss)                   (Cache Hit)                        |   |
 |   |             v                              v                             |   |
 |   |   +-------------------+          +-------------------+                   |   |
 |   |   |   Security Server |          | Direct Enforcement|                   |   |
 |   |   | (Policy Database) |          | (Allow / Deny)    |                   |   |
 |   |   +-------------------+          +-------------------+                   |   |
 |   +--------------------------------------------------------------------------+   |
 |                                                                                  |
 |   +--------------------------------------------------------------------------+   |
 |   |                              AppArmor Architecture                       |   |
 |   |  Path-based containment: Profile enforcement matching full pathnames     |   |
 |   |  e.g., /usr/bin/nginx { /var/www/html/ r, /var/log/nginx/* w }           |   |
 |   +--------------------------------------------------------------------------+   |
 +----------------------------------------------------------------------------------+
                                             |
                                             v
                                   Hardware / Resource Access
```

#### SELinux (Security-Enhanced Linux)
SELinux implementa Type Enforcement (TE), Control de Acceso Basado en Roles (RBAC) y Seguridad Multinivel (MLS) / Seguridad Multicategoría (MCS) a través de la arquitectura Flask.

- **Sintaxis del Contexto de Seguridad de SELinux**: `user:role:type:sensitivity:category`
  - **User (`user_u`, `system_u`)**: Mapea usuarios de Linux a identidades de SELinux.
  - **Role (`object_r`, `httpd_roles`)**: Define los tipos permitidos que una identidad puede adoptar (RBAC).
  - **Type (`httpd_t`, `httpd_sys_content_t`)**: El elemento central de Type Enforcement (TE). Para los procesos, este es el dominio; para los objetos, este es el tipo.
  - **MLS/MCS (`s0-s0:c0.c1023`)**: Niveles de sensibilidad (`s0`) y categorías (`c0-c1023`) utilizados para la contención multi-inquilino (*multi-tenant*) (por ejemplo, contenedores, máquinas virtuales).
- **Access Vector Cache (AVC)**: Almacena en caché las decisiones de política en el espacio del *kernel* para búsquedas de alto rendimiento. Si una regla no está presente en el AVC, el Security Server consulta la base de datos de políticas cargada y almacena la decisión en caché.
- **Modos de Operación de SELinux**:
  - `Enforcing`: Las violaciones de políticas son bloqueadas y auditadas.
  - `Permissive`: Las violaciones de políticas se permiten pero se auditan (crítico para depuración/generación de políticas).
  - `Disabled`: Los *hooks* del *kernel* de SELinux están desinstalados; se ignora el etiquetado del contexto de seguridad.

#### AppArmor
AppArmor utiliza reglas basadas en rutas (*path-based*) vinculadas a perfiles binarios en lugar de etiquetado de *inodes* basado en etiquetas.
- **Modos de Perfil**:
  - `Enforce`: Aplica las reglas del perfil y registra las violaciones.
  - `Complain`: Permite comportamientos no conformes mientras registra eventos de auditoría (utilizado para la generación de perfiles).
  - `Unconfined`: El proceso se ejecuta sin restricciones del perfil AppArmor.
- **Transiciones de Ejecución**:
  - `px` (Discrete Profile Execute): Ejecuta el binario bajo un perfil AppArmor nombrado específico.
  - `cx` (Child Profile Execute): Transiciona el proceso a un perfil hijo anidado dentro del perfil padre.
  - `ix` (Inherit Execute): Ejecuta el binario reteniendo las restricciones del perfil del proceso padre.
  - `ux` (Unconfined Execute): Ejecuta el binario sin ninguna contención de perfil (alto riesgo).

#### SMACK (Simplified Mandatory Access Control Kernel)
SMACK es una implementación de MAC ligera que se basa en matrices de reglas simples y explícitas formateadas como `Sujeto Objeto Acceso`. Los atributos se almacenan en el espacio de nombres de atributos extendidos `security.smack`.

---

### 1.3 Comparación de Arquitecturas y Compromisos de Producción

| Mecanismo de Seguridad | Paradigma | Granularidad | Sobrecarga de Almacenamiento | Complejidad Administrativa | Impacto en el Rendimiento |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **POSIX ACLs** | DAC | Por Usuario/Grupo por archivo | Baja (`system.posix_acl` xattr) | Baja | Despreciable |
| **SELinux** | MAC Basado en Etiquetas (TE/MLS) | Etiqueta de *Inode* y Dominio de Proceso | Media (`security.selinux` xattr) | Alta (Requiere compilación de políticas y gestión de contextos) | Bajo (Optimizado vía búsqueda AVC en el *kernel*) |
| **AppArmor** | MAC Basado en Rutas | Rutas absolutas del sistema de archivos por ejecutable | Baja (Perfiles almacenados en `/etc/apparmor.d/`) | Media (Creación intuitiva de perfiles) | Muy bajo |
| **SMACK** | MAC Basado en Etiquetas | Coincidencia simple de cadenas Sujeto/Objeto | Baja (`security.smack` xattr) | Baja a Media | Muy bajo |

---

### 1.4 Referencias Oficiales y Estándares
- [Objetivos Detallados de LPIC-3 Examen 303-300 v3.0](https://www.lpi.org/our-certifications/lpic-3-303-overview/)
- [LPI Wiki: LPIC-3 Tema 333 (Control de Acceso)](https://wiki.lpi.org/wiki/LPIC-3_303_Objectives_V3.0)
- [Documentación del Módulo de Seguridad del Kernel de Linux (LSM)](https://www.kernel.org/doc/html/latest/admin-guide/LSM/index.html)
- [Documentación del Proyecto SELinux y Política de Referencia](https://github.com/SELinuxProject/selinux)
- [Proyecto de Documentación de AppArmor](https://gitlab.com/apparmor/apparmor/-/wikis/Documentation)

---

## 2. Laboratorios Guiados de Producción

### Lab 1: Herencia Avanzada de ACL POSIX, Recálculo de Máscara y Atributos Extendidos

#### Escenario
Estás reforzando (*hardening*) un almacén de datos empresarial multi-inquilino ubicado en `/srv/finance_data`. El directorio debe admitir acceso para auditores financieros (`auditor1`) y gerentes financieros (`mgr1`), aplicar la herencia de permisos predeterminada para subdirectorios/archivos recién creados y almacenar *hashes* de auditoría de seguridad utilizando atributos extendidos `trusted` y `user`.

#### Pasos Guiados

##### Paso 1: Crear la estructura de directorios y establecer permisos base
```bash
sudo mkdir -p /srv/finance_data/reports
sudo groupadd finance_audit
sudo groupadd finance_mgr
sudo useradd -g finance_audit auditor1
sudo useradd -g finance_mgr mgr1

# Set strict DAC permissions
sudo chown root:finance_mgr /srv/finance_data
sudo chmod 770 /srv/finance_data
```

##### Paso 2: Configurar ACLs de Acceso explícitas y ACLs Predeterminadas (Default)
Asigna acceso de lectura/ejecución a `auditor1` y acceso de lectura/escritura/ejecución al grupo `finance_mgr`. Asegúrate de que todos los subdirectorios futuros hereden estos permisos automáticamente.

```bash
# Assign Access ACLs
sudo setfacl -m u:auditor1:rx /srv/finance_data
sudo setfacl -m g:finance_mgr:rwx /srv/finance_data

# Assign Default ACLs for automatic inheritance
sudo setfacl -d -m u:auditor1:rx /srv/finance_data
sudo setfacl -d -m g:finance_mgr:rwx /srv/finance_data
sudo setfacl -d -m m::rwx /srv/finance_data
```

##### Paso 3: Inspeccionar la configuración de ACL y probar la herencia
```bash
getfacl /srv/finance_data
```

*Salida Esperada:*
```text
# file: srv/finance_data
# owner: root
# group: finance_mgr
user::rwx
user:auditor1:r-x
group::rwx
group:finance_mgr:rwx
mask::rwx
other::---
default:user::rwx
default:user:auditor1:r-x
default:group::rwx
default:group:finance_mgr:rwx
default:mask::rwx
default:other::---
```

##### Paso 4: Verificar el comportamiento de la Máscara bajo `chmod`
Ejecuta un `chmod` tradicional en el directorio y observa cómo las ACLs POSIX manejan el recálculo de la máscara.

```bash
sudo touch /srv/finance_data/q4_ledger.txt
sudo chmod g-w /srv/finance_data/q4_ledger.txt
getfacl /srv/finance_data/q4_ledger.txt
```

*Salida Esperada:*
```text
# file: srv/finance_data/q4_ledger.txt
# owner: root
# group: root
user::rw-
user:auditor1:r-x		#effective:r--
group::rwx			#effective:r--
group:finance_mgr:rwx		#effective:r--
mask::r--
other::---
```

> **Nota**: La aplicación de `chmod g-w` redujo la `mask::` de la ACL a `r--`. En consecuencia, los permisos efectivos para `group:finance_mgr` y `user:auditor1` se limitan a `r--`.

##### Paso 5: Restaurar la máscara explícitamente
```bash
sudo setfacl -m m::rwx /srv/finance_data/q4_ledger.txt
getfacl /srv/finance_data/q4_ledger.txt | grep mask
```

*Salida Esperada:*
```text
mask::rwx
```

##### Paso 6: Gestionar Atributos Extendidos (espacios de nombres `user` vs `trusted`)
Establece un *hash* de cumplimiento personalizado en el espacio de nombres `user` y una firma de integridad interna en el espacio de nombres `trusted`.

```bash
# Set user attribute
sudo setfattr -n user.audit_hash -v "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" /srv/finance_data/q4_ledger.txt

# Set trusted attribute (Requires root privileges)
sudo setfattr -n trusted.integrity_sig -v "sec_v4_ok" /srv/finance_data/q4_ledger.txt

# Read attributes back
getfattr -d -m "-" /srv/finance_data/q4_ledger.txt
```

*Salida Esperada:*
```text
# file: srv/finance_data/q4_ledger.txt
trusted.integrity_sig="sec_v4_ok"
user.audit_hash="sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
```

---

#### Verificación de Comprensión: Lab 1

**Pregunta 1.1**: Si un usuario ejecuta `chmod 755 file.txt` en un archivo que contiene ACLs POSIX explícitas para tres usuarios individuales, ¿cómo afecta esto a los permisos efectivos de esos usuarios nombrados?
**Pregunta 1.2**: ¿Por qué un usuario sin privilegios que no es root recibe `Operation not permitted` al intentar ejecutar `getfattr -n trusted.integrity_sig file.txt`, incluso si los permisos DAC le otorgan acceso `rwx` a `file.txt`?

---

### Lab 2: Análisis Profundo de SELinux — Vinculación de Puertos de Contexto, Depuración de Auditoría AVC y Creación de Módulos de Política Personalizados

#### Escenario
Un binario de microservicio personalizado `/usr/local/bin/secure_app` necesita vincularse al puerto TCP `8888` y leer la configuración operativa desde `/var/custom_app/config.json`. Actualmente, SELinux bloquea estas acciones porque el puerto `8888` no está etiquetado para servicios web/personalizados y `/var/custom_app` carece del etiquetado de contexto SELinux adecuado. Debes diagnosticar las denegaciones AVC, vincular contextos de archivos/puertos usando `semanage` y compilar un módulo de política de Type Enforcement personalizado a partir de registros de auditoría sin procesar.

#### Pasos Guiados

##### Paso 1: Preparar el entorno de prueba y generar la denegación inicial
```bash
sudo mkdir -p /var/custom_app
echo '{"status": "production"}' | sudo tee /var/custom_app/config.json
sudo chmod 644 /var/custom_app/config.json

# Check current SELinux context of the new directory
ls -Z /var/custom_app/config.json
```

*Salida Esperada:*
```text
unconfined_u:object_r:var_t:s0 /var/custom_app/config.json
```

##### Paso 2: Configurar rutas de contexto personalizadas usando `semanage fcontext`
Vincular `/var/custom_app` a `httpd_sys_content_t` de forma persistente a través de reetiquetados (*relabels*) del sistema.

```bash
# Add file context rule to SELinux database
sudo semanage fcontext -a -t httpd_sys_content_t "/var/custom_app(/.*)?"

# Relabel filesystem hierarchy
sudo restorecon -Rv /var/custom_app
```

*Salida Esperada:*
```text
Relabeled /var/custom_app from unconfined_u:object_r:var_t:s0 to unconfined_u:object_r:httpd_sys_content_t:s0
Relabeled /var/custom_app/config.json from unconfined_u:object_r:var_t:s0 to unconfined_u:object_r:httpd_sys_content_t:s0
```

##### Paso 3: Configurar Contextos de Puertos de SELinux
Permitir que los procesos web (`httpd_t`) se vinculen al puerto TCP no estándar `8888`.

```bash
# Query existing HTTP port bindings
sudo semanage port -l | grep http_port_t

# Assign TCP port 8888 to http_port_t context
sudo semanage port -a -t http_port_t -p tcp 8888

# Verify new binding
sudo semanage port -l | grep 8888
```

*Salida Esperada:*
```text
http_port_t                    tcp      8888, 80, 81, 443, 488, 8008, 8009, 8443, 9000
```

##### Paso 4: Simular una Denegación AVC e Inspeccionar los Registros de Auditoría
Desencadenar un conflicto de contexto de proceso simulado probando el acceso bajo un dominio confinado (`system_cronjob_t` intentando leer `/var/custom_app/config.json`).

```bash
# Query AVC logs for recent access violations
sudo ausearch -m AVC,USER_AVC -ts recent
```

*Salida Esperada:*
```text
type=AVC msg=audit(1722950000.412:982): avc:  denied  { read } for  pid=4102 comm="secure_app" name="config.json" dev="dm-0" ino=134912 scontext=system_u:system_r:system_cronjob_t:s0 tcontext=unconfined_u:object_r:httpd_sys_content_t:s0 tclass=file permissive=0
```

##### Paso 5: Diseñar un Módulo de Type Enforcement (`.te`) Personalizado de SELinux
En lugar de configurar SELinux en modo `Permissive`, genera un módulo de política personalizado utilizando `audit2allow` para otorgar el permiso específico de `read` sobre `httpd_sys_content_t` a `system_cronjob_t`.

```bash
# Extract AVC denial and generate Policy Source (.te)
sudo ausearch -m AVC -c "secure_app" | audit2allow -m custom_secure_app > custom_secure_app.te

# Inspect the generated Type Enforcement manifest
cat custom_secure_app.te
```

*Salida Sintácticamente Válida (`custom_secure_app.te`):*
```text
module custom_secure_app 1.0;

require {
	type system_cronjob_t;
	type httpd_sys_content_t;
	class file { open read getattr };
}

#============= system_cronjob_t ==============
allow system_cronjob_t httpd_sys_content_t:file { open read getattr };
```

##### Paso 6: Compilar, Empaquetar e Instalar el Módulo de Política de SELinux
Compila el archivo `.te` sin procesar en un módulo binario del *kernel* `.mod`, construye el paquete de política `.pp` y cárgalo en el almacén de políticas activo de SELinux.

```bash
# Step A: Compile module definition
checkmodule -M -m -o custom_secure_app.mod custom_secure_app.te

# Step B: Build policy package
semodule_package -o custom_secure_app.pp -m custom_secure_app.mod

# Step C: Install policy module into kernel store
sudo semodule -i custom_secure_app.pp

# Step D: Verify loaded policy module
sudo semodule -l | grep custom_secure_app
```

*Salida Esperada:*
```text
custom_secure_app
```

##### Paso 7: Gestionar Booleanos de SELinux
Habilitar las capacidades de conexión de red del proceso HTTP globalmente a través de un booleano de SELinux.

```bash
# Query boolean state
getsebool httpd_can_network_connect

# Enable boolean persistently (-P flag writes to persistent policy store)
sudo setsebool -P httpd_can_network_connect on

# Re-verify boolean state
getsebool httpd_can_network_connect
```

*Salida Esperada:*
```text
httpd_can_network_connect --> on
```

---

#### Verificación de Comprensión: Lab 2

**Pregunta 2.1**: ¿Cuál es el riesgo estructural de seguridad de ejecutar `audit2allow -a -M mymodule` directamente contra todas las denegaciones AVC sin revisar primero el archivo `.te` resultante?
**Pregunta 2.2**: ¿Cuál es la diferencia clave entre usar `chcon` para establecer un contexto de archivo en comparación con usar `semanage fcontext` seguido de `restorecon`?

---

### Lab 3: Construcción de Perfiles AppArmor, Modos de Transición y Auditoría de Diagnóstico

#### Escenario
Estás aislando un proceso demonio (*daemon*) no confiable ubicado en `/usr/sbin/custom_daemon`. Debes construir un perfil completo de AppArmor que aplique límites strictly de acceso a archivos, bloquee la ejecución de *shells* externas, configure transiciones de ejecución de perfil y verifique el estado de la política utilizando herramientas de administración de AppArmor.

#### Pasos Guiados

##### Paso 1: Verificar el estado operativo y los perfiles de AppArmor
```bash
sudo aa-status
```

*Salida Esperada:*
```text
apparmor module is loaded.
42 profiles are loaded.
40 profiles are in enforce mode.
   /usr/bin/evince
   /usr/sbin/tcpdump
2 profiles are in complain mode.
   /usr/bin/identisk
0 processes have profiles defined.
```

##### Paso 2: Crear un Perfil de AppArmor completo y sintácticamente válido
Crea un archivo de definición de perfil en `/etc/apparmor.d/usr.sbin.custom_daemon`.

```bash
sudo bash -c 'cat << "EOF" > /etc/apparmor.d/usr.sbin.custom_daemon
#include <tunables/global>

/usr/sbin/custom_daemon {
  #include <abstractions/base>
  #include <abstractions/nameservice>

  # Capability restrictions
  capability net_bind_service,
  capability setuid,
  capability setgid,

  # File Access Controls
  /usr/sbin/custom_daemon r,
  /etc/custom_daemon/*.conf r,
  /var/log/custom_daemon/*.log w,
  /var/run/custom_daemon.pid rw,

  # Explicit execution restrictions (ix = inherit execution profile)
  /usr/bin/helper_tool ix,

  # Prevent execution of command shells (Deny rules override allow rules)
  deny /usr/bin/bash x,
  deny /usr/bin/sh x,

  # Network Restrictions
  network inet stream,
  network inet6 stream,
}
EOF'
```

##### Paso 3: Cargar el perfil en el motor de AppArmor en Modo Complain
```bash
# Parse and load profile into complain mode
sudo aa-complain /etc/apparmor.d/usr.sbin.custom_daemon

# Verify complain mode state
sudo aa-status | grep custom_daemon
```

*Salida Esperada:*
```text
   /usr/sbin/custom_daemon
```

##### Paso 4: Analizar los registros de auditoría y transicionar el perfil a Modo Enforce
Aplica el perfil usando `apparmor_parser` y verifica la contención.

```bash
# Reload profile in enforcing mode
sudo apparmor_parser -r -W /etc/apparmor.d/usr.sbin.custom_daemon
sudo aa-enforce /usr/sbin/custom_daemon

# Verify enforce status
sudo aa-status | grep custom_daemon
```

*Salida Esperada:*
```text
   /usr/sbin/custom_daemon
```

##### Paso 5: Probar la Aplicación de Reglas de Transición de Ejecución
Inspecciona las entradas de denegación de AppArmor en syslog / dmesg cuando `/usr/sbin/custom_daemon` intente una escritura no autorizada o una invocación de *shell*.

```bash
sudo dmesg | grep -i apparmor | tail -n 5
```

*Salida Esperada:*
```text
[ 4123.891024] audit: type=1400 audit(1722950500.100:102): apparmor="DENIED" operation="exec" profile="/usr/sbin/custom_daemon" name="/usr/bin/bash" pid=5120 comm="custom_daemon" requested_mask="x" denied_mask="x" fsuid=0 ouid=0
```

---

#### Verificación de Comprensión: Lab 3

**Pregunta 3.1**: En la sintaxis de perfiles de AppArmor, ¿cuál es la diferencia operativa entre los *flags* de ejecución `px` (Discrete Profile Execute) y `ux` (Unconfined Execute)?
**Pregunta 3.2**: Si tanto una regla `allow` de AppArmor como una regla `deny` explícita coinciden exactamente con la misma ruta (por ejemplo, `deny /usr/bin/bash x`), ¿qué regla tiene prioridad según el motor de evaluación de AppArmor?

---

<details>
<summary><b>Hacé clic para expandir las Soluciones y Explicaciones Técnicas Detalladas</b></summary>

### Clave de Respuestas Completa y Explicaciones Profundas

#### Soluciones del Lab 1: ACLs POSIX y Atributos Extendidos

##### Solución 1.1
- **Respuesta**: Establecer permisos de archivo explícitos a través de `chmod` estándar (por ejemplo, `chmod 755 file.txt`) modifica la **máscara** POSIX ACL (`mask::`), NO los permisos base del grupo propietario.
- **Explicación Detallada**: Cuando existen ACLs POSIX en un archivo, los bits de permisos del 4.º al 6.º mostrados por `ls -l` (el campo tradicional de grupo) representan la Máscara ACL. El permiso efectivo de cualquier usuario nombrado (`u:username:rwx`) o grupo nombrado (`g:groupname:rwx`) es la unión AND a nivel de bits de su permiso asignado explícitamente y la máscara ACL actual:
  $$\text{Permiso Efectivo} = \text{Permiso ACL Asignado} \land \text{Máscara ACL}$$
  La ejecución de `chmod 755` establece el campo de permisos de grupo (y por lo tanto la máscara) en `r-x` (`5`). Si un usuario nombrado tenía permisos `rw-`, su acceso efectivo se convierte en `r--` (`rw-` $\land$ `r-x` = `r--`).
- **Consejo para el Examen (LPIC-3 303)**: Para restaurar los permisos efectivos completos después de una operación `chmod`, recalcula o vuelve a asignar la máscara explícitamente usando `setfacl -m m::rwx file.txt` o `setfacl -b file.txt` para eliminar completamente las entradas ACL extendidas.

##### Solución 1.2
- **Respuesta**: Los atributos extendidos bajo el espacio de nombres `trusted` están restringidos por la capa VFS del *kernel* de Linux a procesos que posean la capacidad `CAP_SYS_ADMIN` (típicamente root).
- **Explicación Detallada**: Los atributos extendidos se dividen en espacios de nombres distintos (`user`, `trusted`, `security`, `system`). Mientras que los atributos en el espacio de nombres `user.` obedecen los permisos DAC normales (el acceso de lectura permite leer atributos `user.*`), los atributos en el espacio de nombres `trusted.` omiten las comprobaciones DAC estándar y requieren estrictamente la capacidad de Linux `CAP_SYS_ADMIN`. Incluso si los permisos DAC son `0777`, los usuarios que no sean root sin `CAP_SYS_ADMIN` fallarán las verificaciones de seguridad de VFS con `EPERM` (`Operation not permitted`).

---

#### Soluciones del Lab 2: Mecánica y Diagnósticos de SELinux

##### Solución 2.1
- **Respuesta**: Ejecutar `audit2allow -a -M mymodule` a ciegas genera reglas de política para CADA denegación registrada en todo el sistema, lo que potencialmente otorga privilegios excesivos a procesos comprometidos o mal configurados.
- **Explicación Detallada**: `audit2allow` analiza los eventos de denegación AVC en el registro de auditoría y sintetiza las sentencias `allow` correspondientes. Ejecutarlo de forma global (`-a`) sin filtrar por un proceso o contexto específico toma todas las denegaciones recientes a nivel del sistema —incluidos los bloqueos de seguridad legítimos desencadenados por actividad maliciosa o malas configuraciones— y las autoriza automáticamente en un módulo de política compilado.
- **Mejores Prácticas en Producción**:
  1. Filtrar las entradas de auditoría por nombre de proceso o contexto de demonio usando `ausearch -c "nombre_proceso"` o `ausearch -m AVC -ts recent`.
  2. Inspeccionar manualmente el archivo fuente `.te` (Type Enforcement) resultante para garantizar que las reglas se alineen con los principios de mínimo privilegio.
  3. Resolver primero los problemas de etiquetado usando `semanage fcontext` / `restorecon` antes de crear módulos de política `allow` personalizados. Muchas denegaciones AVC se deben a etiquetas de contexto de objeto incorrectas en lugar de reglas de política TE faltantes.

##### Solución 2.2
- **Respuesta**: `chcon` cambia el contexto SELinux de un archivo de forma **temporal** en los metadatos del archivo, mientras que `semanage fcontext` actualiza la **base de datos de contextos de archivos de la política del sistema** (`/etc/selinux/targeted/contexts/files/file_contexts`).
- **Explicación Detallada**:
  - `chcon` (Change Context): Modifica directamente el atributo extendido `security.selinux` de un *inode* de archivo. Sin embargo, NO registra el mapeo en los almacenes de políticas de SELinux. Si se ejecuta `restorecon`, o si ocurre un reetiquetado del sistema (`fixfiles` o `touch /.autorelabel`), todos los cambios aplicados mediante `chcon` se borran y se restablecen a las definiciones de política predeterminadas.
  - `semanage fcontext`: Escribe reglas de expresión de ruta persistentes en la base de datos de políticas de SELinux. Ejecutar `restorecon -v filename` lee estas reglas persistentes de la base de datos y aplica el contexto correcto a los atributos del archivo objetivo.

---

#### Soluciones del Lab 3: Contención de Perfiles AppArmor

##### Solución 3.1
- **Respuesta**:
  - `px` (Discrete Profile Execute): Instruye a AppArmor a transicionar la ejecución del binario objetivo a un perfil de AppArmor separado y dedicado que coincida con la ruta del ejecutable. Si no existe un perfil coincidente, la ejecución se bloquea.
  - `ux` (Unconfined Execute): Ejecuta el binario objetivo completamente sin confinamiento, renunciando a todas las restricciones de AppArmor para ese proceso hijo.
- **Impacto en la Seguridad**: El uso de `ux` crea una ruptura en el límite de privilegios. Si una aplicación confinada ejecuta un binario bajo `ux`, cualquier compromiso de ese binario hijo omite por completo la contención de AppArmor. Se debe usar `px` o `ix` (heredar perfil padre) en perfiles de producción.

##### Solución 3.2
- **Respuesta**: En la sintaxis de perfiles de AppArmor, las **reglas `deny` explícitas siempre tienen prioridad sobre las reglas `allow`**, independientemente del orden de las reglas dentro de la definición del perfil.
- **Explicación Detallada**: AppArmor evalúa las reglas de seguridad utilizando un motor de prioridad estricto:
  $$\text{Prioridad} = \text{Reglas Deny} > \text{Reglas Allow Específicas} > \text{Reglas Allow Abstraídas}$$
  Incluso si `#include <abstractions/base>` o una regla comodín amplia otorga acceso/ejecución a `/usr/bin/*`, una declaración explícita de `deny /usr/bin/bash x,` garantiza que la ejecución de `/usr/bin/bash` será bloqueada y auditada bajo cualquier circunstancia.

</details>