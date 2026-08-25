# 333.2 — Mandatory Access Control

**LPIC-3 303 (Security), examen 303-300, versión 3.0.0**
**Peso del tema: 4 → 8.33 % del examen**
**Alcance: conceptos TE / RBAC / MAC / DAC · SELinux en profundidad · AppArmor y Smack a nivel operativo**

---

## 1. El problema arquitectónico: por qué DAC es insuficiente en producción

### 1.1 El modo de fallo para el que nadie diseña

El control de acceso clásico de UNIX es **Discrecional**: el *dueño* del objeto decide quién puede acceder a él, y cualquier proceso que corra como ese dueño hereda toda su autoridad. Tres consecuencias estructurales vuelven inutilizable este modelo como única defensa en un parque de producción:

1. **Autoridad ambiente.** Un proceso no es un principal de seguridad — su UID sí lo es. `nginx` corriendo como `root` durante los primeros 100 ms de su vida, o `postgres` corriendo como UID 26, puede tocar *todos* los objetos que ese UID puede tocar, no solo los objetos que su tarea requiere. Una ejecución remota de código en `nginx` entrega entonces "todo lo que `nginx` podría haber hecho alguna vez", no "todo lo que `nginx` estaba haciendo".
2. **La discreción es delegable.** `chmod 777` es una operación DAC legítima. Cualquier proceso comprometido puede ampliar permisos sobre los objetos que posee; una política que escribió una persona puede ser deshecha por código que controla el atacante.
3. **`root` es el terminador del modelo.** El UID 0 evita DAC por completo. Las capabilities (`CAP_DAC_OVERRIDE`, `CAP_SETUID`, …) subdividen a root pero no lo *acotan*: `CAP_DAC_OVERRIDE` es "ignorar todos los permisos de archivo", no "ignorar los permisos de archivo bajo `/var/lib/myapp`".

El escenario concreto de producción que motiva MAC:

> Un servidor web expuesto a internet es comprometido mediante una falla a nivel de aplicación. Solo con DAC, la shell del atacante — corriendo como `apache` — puede leer `/home/*/`, los archivos de `/etc` legibles por todos, conectarse hacia afuera a cualquier host y puerto, escribir en cualquier directorio propiedad de `apache` incluido el document root (persistencia), y leer cada archivo de backup cuyos permisos se relajaron para una migración hace tres años. Nada en el sistema distingue "el servidor web haciendo cosas de servidor web" de "el servidor web haciendo cosas de atacante", porque ambos son UID 48.

### 1.2 Qué cambia MAC

El **Mandatory Access Control** saca la decisión de las manos del dueño del objeto y la lleva a una **política de todo el sistema** aplicada por el kernel:

- La política la carga el administrador/proveedor, no los procesos.
- La decisión se toma sobre **etiquetas de seguridad** adosadas a sujetos (procesos) y objetos (archivos, sockets, puertos, IPC, keys, capabilities…), no sobre la propiedad.
- **MAC es aditivo a DAC, nunca un reemplazo.** Todo acceso debe pasar DAC *y* MAC. Si DAC deniega, MAC nunca se consulta (y la capa MAC no audita ninguna denegación) — un hecho que hace tropezar al 90 % de los diagnósticos primerizos.

El mismo compromiso bajo una política MAC: la shell corre como `httpd_t`. Puede leer `httpd_sys_content_t`, agregar a `httpd_log_t`, hacer bind de `http_port_t`. Leer `/etc/shadow` (`shadow_t`), escribir en el document root (a menos que sea `httpd_sys_rw_content_t`), o conectarse a un puerto TCP arbitrario están todos denegados — sin importar el UID, sin importar `root`, sin importar los permisos del archivo.

### 1.3 Taxonomía de modelos

| Modelo | Dueño de la decisión | Adosado a | Revocable por un proceso comprometido | Implementación típica en Linux |
|---|---|---|---|---|
| **DAC** — Discrecional | Dueño del objeto | UID/GID + bits de modo, ACLs POSIX | Sí (`chmod`, `chown`, `setfacl`) | Chequeos de permisos del VFS, `CAP_DAC_OVERRIDE` |
| **MAC** — Mandatorio | Política del sistema | Etiquetas de seguridad en sujeto y objeto | No | SELinux, Smack, (AppArmor: MAC basado en rutas) |
| **TE** — Type Enforcement | Política del sistema | *Tipo* del dominio sujeto y tipo del objeto | No | Reglas `allow` de SELinux — el caballo de batalla de la política targeted |
| **RBAC** — Basado en roles | Política del sistema | Roles ligados a usuarios, roles autorizados para tipos | No | Usuarios/roles de SELinux + `newrole`; acotado por TE |
| **MLS/MCS** — Multinivel / Multicategoría | Política del sistema | Niveles de sensibilidad + categorías (Bell–LaPadula) | No | Política MLS de SELinux; MCS es el subconjunto de sensibilidad única usado para aislar contenedores |

**Cómo se componen en SELinux (el orden importa):**

```
DAC check  ──► passes ──►  TE check (allow rules)  ──►  RBAC/constraint check  ──►  MLS/MCS check  ──►  ACCESS
   │                              │                             │                          │
   └─ EACCES, no AVC              └─ AVC denied                 └─ AVC denied (constraint)  └─ AVC denied
```

TE se evalúa primero y es donde vive esencialmente toda la política real. RBAC en SELinux no es un modelo independiente — los roles restringen qué *tipos* puede asumir un usuario, y las reglas TE deciden después qué pueden hacer esos tipos. MCS es un chequeo de *retículo* aplicado al final: dos procesos de contenedor etiquetados `s0:c12,c803` y `s0:c44,c91` comparten el tipo `container_t` y siguen mutuamente aislados porque ninguno de los conjuntos de categorías domina al otro.

### 1.4 Aplicación basada en etiquetas vs basada en rutas

| Dimensión | Basado en etiquetas (SELinux, Smack) | Basado en rutas (AppArmor) |
|---|---|---|
| Dónde vive el atributo de seguridad | Atributo extendido en el inodo (`security.selinux`, `security.SMACK64`) | En ningún lado — el perfil hace match con el nombre de ruta usado al abrir |
| Sobrevive a `mv`, hardlink, bind mount | Sí (la etiqueta viaja con el inodo) | No — una ruta distinta es un match de regla distinto; los hardlinks pueden eludir la intención |
| Sobrevive a restaurar el filesystem / `rsync` sin `-X` | **No** — este es el incidente operativo #1 | N/A |
| Soporte de filesystem requerido | Soporte de xattr (`ext4`, `xfs`, `btrfs`); si no, opción de montaje `context=` | Ninguno |
| Cubre objetos que no son archivos (puertos, IPC, keys, capabilities, netlink) | Sí, exhaustivamente | Parcialmente (red de grano grueso, capabilities, señales, dbus, mount, sockets unix) |
| Esfuerzo de autoría de política | Alto (refpolicy, macros, compilación de módulos) | Bajo (perfiles legibles por binario) |
| Modo de fallo cuando la política está mal | Denegación, auditable, granular | Denegación, auditable, pero el aliasing de rutas puede sub-aplicar silenciosamente |
| Aislamiento multi-tenant de binarios idénticos | Nativo (categorías MCS) | Requiere un perfil por instancia o `change_profile` |

**Regla práctica del arquitecto:** si el modelo de amenazas incluye *contenedores o tenants corriendo la misma imagen*, necesitás aislamiento por etiqueta + categoría (SELinux/MCS) o necesitás un perfil distinto por tenant. El MAC basado en rutas no expresa nativamente "estos dos procesos idénticos no deben ver los datos del otro".

---

## 2. Dónde vive MAC en el kernel: el framework LSM

SELinux, AppArmor y Smack no son subsistemas independientes — los tres son **Linux Security Modules**. El framework LSM ubica hooks en cada punto de decisión del kernel relevante para la seguridad, *después* de los chequeos DAC estándar.

```
  syscall (open, connect, execve, ptrace, ...)
        │
        ▼
  ┌──────────────────────┐
  │ capability + DAC      │  ── denies ──► EACCES / EPERM  (no MAC audit record!)
  └──────────┬───────────┘
             │ allows
             ▼
  ┌──────────────────────┐
  │ security_file_open()  │   LSM hook
  │  → call chain          │
  └──────────┬───────────┘
             │
   ┌─────────┴──────────┬─────────────┬──────────────┐
   ▼                    ▼             ▼              ▼
capability          landlock        yama         selinux  ◄── "major" LSM (exclusive)
  (stacked minor LSMs run in CONFIG_LSM order)
             │
             ▼
     AVC cache hit? ── yes ──► decision
             │ no
             ▼
     Security Server evaluates loaded policy → cache → decision + optional audit
```

Verificá qué está realmente activo — nunca lo asumas a partir de la distribución:

```console
$ cat /sys/kernel/security/lsm
capability,landlock,lockdown,yama,integrity,selinux,bpf

$ cat /proc/cmdline
BOOT_IMAGE=(hd0,gpt2)/vmlinuz-6.11.5-300.fc41.x86_64 root=/dev/mapper/vg0-root ro rhgb quiet

$ zgrep -E 'CONFIG_(LSM|SECURITY_SELINUX|SECURITY_APPARMOR|SECURITY_SMACK)=' /proc/config.gz
CONFIG_SECURITY_SELINUX=y
CONFIG_SECURITY_SMACK=y
CONFIG_SECURITY_APPARMOR=y
CONFIG_LSM="landlock,lockdown,yama,integrity,bpf"
```

**Hecho operativo crítico:** SELinux, AppArmor y Smack son LSM mayores *exclusivos* — el kernel activa como máximo uno de ellos. Los LSM menores (`capability`, `yama`, `lockdown`, `landlock`, `bpf`, `integrity`) se apilan libremente en paralelo. Selección en el arranque:

```console
# Boot with a specific LSM set (overrides CONFIG_LSM):
lsm=capability,landlock,yama,bpf,apparmor

# Legacy per-module switches still honoured:
selinux=0        # SELinux off entirely (recommended way to disable on RHEL 9+)
apparmor=0
security=smack   # legacy exclusive selector
```

| Parámetro del kernel | Efecto | Notas |
|---|---|---|
| `selinux=0` / `selinux=1` | Deshabilita/habilita SELinux en el kernel | La **única** forma limpia de deshabilitarlo por completo en RHEL 9+ |
| `enforcing=0` | Arranca SELinux en modo permissive | La palanca de recuperación; tenela en tus notas de rescate de GRUB |
| `autorelabel=1` (o `touch /.autorelabel`) | Reetiqueta todo el filesystem en el próximo arranque | Reinicia una vez más automáticamente |
| `apparmor=0` / `apparmor=1` | Deshabilita/habilita AppArmor | |
| `lsm=...` | Lista LSM explícita y ordenada | Reemplaza `CONFIG_LSM` por completo — si omitís un LSM, queda apagado |

---

## 3. Arquitectura de SELinux

### 3.1 Componentes

| Componente | Vive en | Responsabilidad |
|---|---|---|
| **Security Server** | Kernel | Evalúa la política binaria cargada; responde "¿puede `scontext` hacer `perm` sobre `tcontext:tclass`?" |
| **AVC (Access Vector Cache)** | Kernel | Cachea decisiones; tasa de aciertos > 99,99 % en régimen estable — por esto el overhead de SELinux es despreciable |
| **Object Managers** | Kernel (VFS, red, IPC) y espacio de usuario | Etiquetan objetos y consultan al Security Server. OMs de espacio de usuario: `systemd`, `dbus-daemon`, `sshd`, `xorg`, `postgresql` (vía `sepgsql`), runtimes de contenedores |
| **selinuxfs** | `/sys/fs/selinux` | Interfaz kernel↔espacio de usuario: modo, carga de política, booleanos, estadísticas del AVC |
| **Policy store** | `/etc/selinux/<type>/` | Módulos fuente de verdad, más la `policy.<ver>` compilada y las bases de datos `file_contexts` |
| **libselinux / libsemanage / libsepol** | Espacio de usuario | La API detrás de cada herramienta que vas a tipear |

```console
$ ls /sys/fs/selinux/
access     class            context           disable      enforce
avc        commit_pending_bools  create       deny_unknown  initial_contexts
booleans   checkreqprot     member            mls          null
policy     policy_capabilities   policyvers   reject_unknown  relabel
status     user             validatetrans

$ cat /sys/fs/selinux/enforce
1
$ cat /sys/fs/selinux/policyvers
33
```

### 3.2 El contexto de seguridad

Todo sujeto y objeto lleva un contexto con cuatro campos:

```
   user       role        type            level (sensitivity[:categories])
     │          │           │                 │
unconfined_u:unconfined_r:unconfined_t:s0-s0:c0.c1023
system_u    :system_r    :httpd_t      :s0
system_u    :object_r    :httpd_sys_content_t:s0
system_u    :system_r    :container_t  :s0:c214,c802
```

- **Usuario SELinux** (`_u`): una identidad a nivel de política, *no* un usuario UNIX. Se mapea desde logins POSIX vía `semanage login`.
- **Rol** (`_r`): un conjunto de tipos que un usuario puede asumir. Los archivos siempre llevan `object_r` (los roles carecen de sentido para los objetos).
- **Tipo** (`_t`): el campo que carga con ~toda la aplicación de la política. Sobre un sujeto se lo llama **dominio**.
- **Nivel**: `s0` (sensibilidad) más categorías opcionales `c0,c15` o rangos `c0.c1023`. En la política targeted solo se usa MCS; la política MLS usa el retículo de sensibilidad completo `s0`–`s15`.

Leé contextos en todos lados con `-Z`:

```console
$ ps -eZ | grep -E 'httpd|sshd'
system_u:system_r:sshd_t:s0-s0:c0.c1023    1187 ?  00:00:00 sshd
system_u:system_r:httpd_t:s0               2914 ?  00:00:03 httpd
system_u:system_r:httpd_t:s0               2915 ?  00:00:00 httpd

$ ls -Z /var/www/html/
unconfined_u:object_r:httpd_sys_content_t:s0 index.html
system_u:object_r:httpd_sys_rw_content_t:s0  uploads

$ id -Z
unconfined_u:unconfined_r:unconfined_t:s0-s0:c0.c1023

$ ss -ltnZ | head -3
State  Recv-Q Send-Q Local:Port  Peer:Port  Process
LISTEN 0      511    *:80        *:*        users:(("httpd",pid=2914,proc_ctx=system_u:system_r:httpd_t:s0))

$ cat /proc/self/attr/current
unconfined_u:unconfined_r:unconfined_t:s0-s0:c0.c1023

$ getfattr -n security.selinux -d /etc/shadow
# file: etc/shadow
security.selinux="system_u:object_r:shadow_t:s0"
```

### 3.3 Modos y configuración

```console
$ getenforce
Enforcing

$ selinuxenabled; echo "exit=$?"
exit=0                       # 0 = SELinux is enabled in the kernel (scriptable predicate)

$ sudo setenforce 0          # or: setenforce Permissive  — runtime only, NOT persistent
$ getenforce
Permissive

$ sudo sestatus -v
SELinux status:                 enabled
SELinuxfs mount:                /sys/fs/selinux
SELinux root directory:         /etc/selinux
Loaded policy name:             targeted
Current mode:                   permissive
Mode from config file:          enforcing
Policy MLS status:              enabled
Policy deny_unknown status:     allowed
Memory protection checking:     actual (secure)
Max kernel policy version:      33

Process contexts:
Current context:                unconfined_u:unconfined_r:unconfined_t:s0-s0:c0.c1023
Init context:                   system_u:system_r:init_t:s0
/usr/sbin/sshd                  system_u:system_r:sshd_t:s0-s0:c0.c1023

File contexts:
Controlling terminal:           unconfined_u:object_r:user_devpts_t:s0
/etc/passwd                     system_u:object_r:passwd_file_t:s0
/etc/shadow                     system_u:object_r:shadow_t:s0
/bin/bash                       system_u:object_r:shell_exec_t:s0
/bin/login                      system_u:object_r:login_exec_t:s0
/sbin/init                      system_u:object_r:bin_t:s0 -> system_u:object_r:init_exec_t:s0
/usr/sbin/sshd                  system_u:object_r:sshd_exec_t:s0
```

`/etc/selinux/config` — la configuración persistente:

```ini
# /etc/selinux/config
#
# This file controls the state of SELinux on the system.
# SELINUX= can take one of these three values:
#     enforcing  - SELinux security policy is enforced.
#     permissive - SELinux prints warnings instead of enforcing.
#     disabled   - No SELinux policy is loaded.
# NOTE: On RHEL 9 / Fedora, disabling via this file is deprecated;
#       use selinux=0 on the kernel command line instead.
SELINUX=enforcing
#
# SELINUXTYPE= can take one of these values:
#     targeted - Targeted processes are protected,
#     minimum  - Modification of targeted policy. Only selected processes are protected.
#     mls      - Multi Level Security protection.
SELINUXTYPE=targeted
```

| Modo | ¿El kernel aplica? | ¿Se auditan las denegaciones? | Caso de uso |
|---|---|---|---|
| **enforcing** | Sí | Sí | Producción. No negociable para cargas reguladas |
| **permissive** | No | Sí (todas, no solo la primera) | Desarrollo de política, migración, triage de incidentes |
| **disabled** | No | No | Solo con `selinux=0`; requiere un reetiquetado completo para rehabilitarlo |

**La sutileza del modo permissive que le cuesta a la gente una segunda caída:** en modo enforcing, una operación que dispararía cinco denegaciones suele abortar en la primera, así que solo ves un AVC. En modo permissive la operación continúa y se registran *las cinco*. Nunca declares completa una política tras una única denegación en modo enforcing — corré en permissive, ejercitá la carga de trabajo completa, y recién ahí recolectá.

**La trampa de deshabilitar/rehabilitar:** mientras SELinux está deshabilitado, los archivos nuevos y modificados **no** reciben el xattr `security.selinux`. Rehabilitarlo sin un reetiquetado completo produce un sistema donde `init` no puede transicionar y el arranque se cuelga. La secuencia segura:

```console
$ sudo touch /.autorelabel && sudo reboot
# ... boot shows: *** Warning -- SELinux targeted policy relabel is required.
# ... *** Relabeling could take a very long time, depending on file
# ... system size and speed of hard drives.
```

La disposición de directorios que los objetivos referencian como `/etc/selinux/*`:

```console
$ tree -L 2 /etc/selinux
/etc/selinux
├── config
├── semanage.conf
├── targeted
│   ├── active            # the compiled, active policy store (do not edit by hand)
│   ├── contexts          # userspace object-manager context mappings
│   ├── policy            # policy.33 — the binary policy the kernel loads
│   ├── setrans.conf      # MLS/MCS label ↔ human-readable translation (mcstransd)
│   └── tmp
└── final

$ ls /etc/selinux/targeted/contexts/
customizable_types  dbus_contexts  default_contexts  default_type  failsafe_context
files/              lxc_contexts   openssh_contexts  removable_context  securetty_types
sepgsql_contexts    snapperd_contexts  userhelper_context  users/  virtual_domain_context

$ ls /etc/selinux/targeted/contexts/files/
file_contexts            file_contexts.homedirs      file_contexts.local
file_contexts.bin        file_contexts.homedirs.bin  file_contexts.local.bin
media
```

| Ruta | Qué es | ¿Editarla? |
|---|---|---|
| `/etc/selinux/config` | Modo + tipo de política en el arranque | **Sí**, a mano |
| `/etc/selinux/semanage.conf` | Comportamiento de `semanage`: raíz del store, compilador de módulos, compresión `bzip`, `expand-check` | Rara vez |
| `/etc/selinux/targeted/policy/policy.33` | Política binaria cargada en el kernel | **Nunca** — es generada |
| `/etc/selinux/targeted/contexts/files/file_contexts` | Regex de contextos de archivo por defecto del proveedor | **Nunca** — pertenece al paquete |
| `/etc/selinux/targeted/contexts/files/file_contexts.local` | Tus entradas de `semanage fcontext -a` | Nunca a mano — usá `semanage` |
| `/etc/selinux/targeted/active/modules/<priority>/` | Módulos de política instalados por prioridad (100 = proveedor, 400 = override local) | Nunca a mano |
| `/etc/selinux/targeted/setrans.conf` | Mapea `s0:c1,c2` → `Internal`, etc. | Sí, para despliegues MLS |

---

## 4. Type Enforcement en profundidad

### 4.1 Anatomía de una regla

```
allow  httpd_t  httpd_sys_content_t : file  { getattr open read ioctl lock map } ;
  │       │              │             │              │
  │       │              │             │              └── permission set (access vector)
  │       │              │             └── object class
  │       │              └── target type
  │       └── source type (domain)
  └── rule kind: allow | dontaudit | auditallow | neverallow
```

| Tipo de regla | Otorga acceso | Escribe registro de auditoría | Propósito |
|---|---|---|---|
| `allow` | Sí | No (salvo `auditallow`) | El caso por defecto: lista blanca |
| `dontaudit` | No | **No** — suprime el log de la denegación | Silenciar ruido conocido e inofensivo (p. ej. sondeos `getattr`) |
| `auditallow` | Sí | Sí | Registrar una acción permitida pero sensible |
| `neverallow` | Aserción en tiempo de compilación | — | Hace fallar la compilación de la política si un módulo la otorgara |

`dontaudit` es la mayor fuente individual de "la herramienta funciona pero no hay ninguna denegación en el log". Desactivalo durante el triage:

```console
$ sudo semodule -DB                   # rebuild policy with all dontaudit rules DISABLED
$ # ... reproduce the failure, collect AVCs ...
$ sudo semodule -B                    # rebuild, dontaudit restored
```

### 4.2 Consultar la política cargada (SETools)

`seinfo` y `sesearch` vienen de `setools-console`; la herramienta gráfica de análisis de política `apol` viene de `setools-gui` / `setools-console-analyses`.

```console
$ sudo dnf install -y setools-console setools-gui policycoreutils-devel

$ seinfo

Statistics for policy file: /sys/fs/selinux/policy
Policy Version:             33 (MLS enabled)
Target Policy:              selinux
Handle unknown classes:     allow

  Classes:             135    Permissions:         463
  Sensitivities:         1    Categories:         1024
  Types:              5203    Attributes:          256
  Users:                 8    Roles:                15
  Booleans:            343    Cond. Expr.:         387
  Allow:            121846    Neverallow:            0
  Auditallow:          166    Dontaudit:          9843
  Type_trans:        22071    Type_change:          38
  Role allow:           40    Role_trans:          451
  Constraints:         101    Validatetrans:         0

$ seinfo -t | grep -c .
5204

$ seinfo -rsystem_r -x
  system_r
    Dominated Roles:
       system_r
    Types:
       abrt_t
       accountsd_t
       ...
       httpd_t
       sshd_t

$ seinfo --user -x
  users: 8
    system_u
      default level: s0
      range: s0 - s0:c0.c1023
      roles:
         object_r
         system_r
    unconfined_u
      default level: s0
      range: s0 - s0:c0.c1023
      roles:
         object_r
         system_r
         unconfined_r
    ...

$ seinfo -b | grep httpd | head -5
   httpd_anon_write
   httpd_builtin_scripting
   httpd_can_check_spam
   httpd_can_connect_ftp
   httpd_can_connect_ldap
```

**`sesearch` es cómo respondés "¿esto está realmente permitido?" sin prueba y error:**

```console
$ sesearch -A -s httpd_t -t httpd_sys_content_t -c file
allow httpd_t httpd_sys_content_t:file { getattr ioctl lock map open read };
allow httpd_t httpdcontent:file { append create ... }; [ httpd_unified ]:True

$ sesearch -A -s httpd_t -t shadow_t
# (no output) -> httpd_t has NO access to shadow_t. That is the point.

$ sesearch -A -s httpd_t -c tcp_socket -p name_connect
allow httpd_t http_cache_port_t:tcp_socket name_connect; [ httpd_can_network_relay ]:False
allow httpd_t port_type:tcp_socket name_connect; [ httpd_can_network_connect ]:False
allow httpd_t postgresql_port_t:tcp_socket name_connect; [ httpd_can_network_connect_db ]:False

# Domain transitions: which domains can httpd_t enter, and via which entrypoint?
$ sesearch -T -s httpd_t -c process
type_transition httpd_t httpd_sys_script_exec_t:process httpd_sys_script_t;
type_transition httpd_t httpd_php_exec_t:process httpd_php_t;
```

El sufijo entre corchetes `[ boolean ]:False` es el detalle crucial: la regla existe pero es **condicional** y actualmente está inactiva.

### 4.3 Transiciones de dominio

Una transición de dominio es el mecanismo por el cual `init_t` se convierte en `httpd_t` cuando ejecuta `/usr/sbin/httpd`. Tres permisos deben otorgarse todos, o el proceso conserva silenciosamente el dominio de su padre (y después falla de formas confusas):

```
allow init_t     httpd_exec_t : file    { getattr open read execute };   # 1. may execute the file
allow init_t     httpd_t      : process transition;                      # 2. may transition to the domain
allow httpd_t    httpd_exec_t : file    entrypoint;                      # 3. the file is a valid entrypoint
type_transition  init_t httpd_exec_t : process httpd_t;                  # 4. do it automatically
```

Analizá un camino de transición sin leer el fuente de la política:

```console
$ sepolicy transition -s init_t -t httpd_t
init_t @ httpd_exec_t --> httpd_t

$ sepolicy transition -s httpd_t
httpd_t @ abrt_helper_exec_t --> abrt_helper_t
httpd_t @ antivirus_exec_t --> antivirus_t
httpd_t @ httpd_php_exec_t --> httpd_php_t
httpd_t @ httpd_suexec_exec_t --> httpd_suexec_t
httpd_t @ httpd_sys_script_exec_t --> httpd_sys_script_t
...

$ sepolicy network -d httpd_t
httpd_t: tcp name_connect to 80,81,443,488,8008,8009,8443,9000
httpd_t: tcp name_bind to 80,81,443,488,8008,8009,8443,9000
httpd_t: udp name_bind to 0

$ sepolicy network -p 9713
9713: tcp unreserved_port_t 9713
```

**La interacción con `NoNewPrivileges`** — un tropiezo real de producción cuando SELinux se cruza con el endurecimiento de systemd. Bajo `no_new_privs`, el kernel rechaza las transiciones de dominio de SELinux salvo que la política otorgue explícitamente los permisos de la clase `process2`:

```console
$ sesearch -A -s init_t -t metricsd_t -c process2
allow init_t metricsd_t:process2 { nnp_transition nosuid_transition };
```

Si un servicio con `NoNewPrivileges=yes` en su unit se queda en `init_t` en lugar de entrar a su propio dominio, esta es la razón. La solución es una regla de política (`init_nnp_daemon_domain(metricsd_t, metricsd_exec_t)` en refpolicy), no deshabilitar el endurecimiento.

---

## 5. Etiquetas: asignarlas, repararlas, y las tres formas de equivocarse

### 5.1 La matriz de herramientas

| Herramienta | Persistencia | Alcance | Cuándo usarla |
|---|---|---|---|
| `chcon` | **Temporal** — se pierde al reetiquetar | Una ruta | Nunca en producción. Solo para depurar |
| `semanage fcontext -a` + `restorecon` | Permanente (guardado en `file_contexts.local`) | Regex sobre rutas | **La forma correcta**, siempre |
| `restorecon` | Aplica el valor por defecto almacenado | Ruta/árbol | Después de crear archivos, después de `mv`, después de restaurar |
| `setfiles` | Aplica contextos de un archivo de especificación *indicado* | Ruta/árbol | Reetiquetado por script/offline; es lo que `restorecon` envuelve |
| `fixfiles` | Aplica los valores por defecto almacenados | Todo el FS, un paquete RPM, o un diff | Reparación masiva, reparación de paquetes, reetiquetado en el arranque |
| Opciones de montaje (`context=`) | Por montaje, sin escribir xattrs | Todo el montaje | NFS, vfat, e imágenes de solo lectura |

### 5.2 El flujo de trabajo canónico

```console
# Symptom: a web app served from a non-default document root returns 403.
$ ls -Zd /srv/www/app
unconfined_u:object_r:var_t:s0 /srv/www/app          # <- wrong type

# 1. Record the intended context in the policy store (persistent, regex-based)
$ sudo semanage fcontext -a -t httpd_sys_content_t "/srv/www(/.*)?"
$ sudo semanage fcontext -a -t httpd_sys_rw_content_t "/srv/www/app/var/uploads(/.*)?"

# 2. Verify what WOULD be applied before touching anything
$ sudo restorecon -Rvn /srv/www
Would relabel /srv/www from unconfined_u:object_r:var_t:s0 to system_u:object_r:httpd_sys_content_t:s0
Would relabel /srv/www/app from unconfined_u:object_r:var_t:s0 to system_u:object_r:httpd_sys_content_t:s0
Would relabel /srv/www/app/var/uploads from unconfined_u:object_r:var_t:s0 to system_u:object_r:httpd_sys_rw_content_t:s0

# 3. Apply
$ sudo restorecon -Rv /srv/www
Relabeled /srv/www from unconfined_u:object_r:var_t:s0 to system_u:object_r:httpd_sys_content_t:s0
Relabeled /srv/www/app from unconfined_u:object_r:var_t:s0 to system_u:object_r:httpd_sys_content_t:s0
...

# 4. Confirm
$ ls -Z /srv/www/app | head -3
system_u:object_r:httpd_sys_content_t:s0 index.php
system_u:object_r:httpd_sys_content_t:s0 lib
system_u:object_r:httpd_sys_rw_content_t:s0 var

# Inspect / remove local entries
$ sudo semanage fcontext -l -C
SELinux fcontext                       type       Context

/srv/www(/.*)?                         all files  system_u:object_r:httpd_sys_content_t:s0
/srv/www/app/var/uploads(/.*)?         all files  system_u:object_r:httpd_sys_rw_content_t:s0

$ sudo semanage fcontext -d "/srv/www(/.*)?"
```

**Regla de ordenamiento:** las entradas de `semanage fcontext` se resuelven **primero por la regex más específica** dentro de `file_contexts.local`, y las entradas locales tienen precedencia sobre las del proveedor. Agregá siempre la regla amplia *y* la excepción angosta; no confíes en el orden de inserción.

### 5.3 `fixfiles` y `setfiles`

```console
# Repair every file owned by an RPM (surgical, fast)
$ sudo fixfiles -R httpd restore
$ sudo fixfiles -R httpd,mod_ssl check          # report only, do not change

# Repair a directory tree
$ sudo fixfiles -R '' restore /var/lib/pgsql

# Relabel only files whose context differs from the policy default,
# using a diff against the previous policy (fast post-upgrade repair)
$ sudo fixfiles -C /var/lib/selinux/targeted/active/commit_num restore

# Schedule a full relabel at next boot (equivalent to touch /.autorelabel)
$ sudo fixfiles onboot
System will relabel on next boot

# Full immediate relabel (expensive: hours on large filesystems)
$ sudo fixfiles -f relabel

# setfiles: apply an explicit spec file — used by fixfiles and by image builders
$ sudo setfiles -v /etc/selinux/targeted/contexts/files/file_contexts /srv/www
$ sudo setfiles -n -v /etc/selinux/targeted/contexts/files/file_contexts /srv/www   # dry run
$ sudo setfiles -r /mnt/rootfs /etc/selinux/targeted/contexts/files/file_contexts /mnt/rootfs
```

La forma `-r <root>` es la que usás para reetiquetar una imagen o una raíz montada en rescate: quita el prefijo de raíz alternativa antes de hacer match con las regex.

### 5.4 Puertos, red y otras clases de objeto mediante `semanage`

```console
$ sudo semanage port -l | grep -E '^(http|ssh)_port_t'
http_port_t                    tcp      80, 81, 443, 488, 8008, 8009, 8443, 9000
ssh_port_t                     tcp      22

# Let httpd bind an extra port
$ sudo semanage port -a -t http_port_t -p tcp 8081
$ sudo semanage port -m -t http_port_t -p tcp 8081     # modify an existing definition
$ sudo semanage port -d -t http_port_t -p tcp 8081

$ sudo semanage port -l -C                              # local modifications only
SELinux Port Type              Proto    Port Number
http_port_t                    tcp      8081

# Other manageable object classes
$ sudo semanage interface -l
$ sudo semanage node -l
$ sudo semanage login -l
Login Name           SELinux User         MLS/MCS Range        Service
__default__          unconfined_u         s0-s0:c0.c1023       *
root                 unconfined_u         s0-s0:c0.c1023       *

$ sudo semanage user -l
SELinux User    Prefix    MCS Level  MCS Range           SELinux Roles
guest_u         user      s0         s0                  guest_r
staff_u         user      s0         s0-s0:c0.c1023      staff_r sysadm_r system_r unconfined_r
sysadm_u        user      s0         s0-s0:c0.c1023      sysadm_r
unconfined_u    user      s0         s0-s0:c0.c1023      system_r unconfined_r
user_u          user      s0         s0                  user_r
xguest_u        user      s0         s0                  xguest_r

# Export every local customisation — this is your reproducible configuration artifact
$ sudo semanage export -f /root/selinux-local.txt
$ cat /root/selinux-local.txt
boolean -D
login -D
port -D
fcontext -D
boolean -m -1 httpd_can_network_connect_db
port -a -t http_port_t -p tcp 8081
fcontext -a -f a -t httpd_sys_content_t -r 's0' '/srv/www(/.*)?'

# Re-import on a rebuilt host
$ sudo semanage import -f /root/selinux-local.txt
```

`semanage export | import` es la forma correcta de llevar la personalización de SELinux a imágenes doradas y a recuperación ante desastres — no copiar `file_contexts.local` a mano.

### 5.5 Etiquetado en el montaje (sistemas de archivos sin xattrs)

| Opción | Efecto |
|---|---|
| `context=CTX` | **Todos** los archivos del montaje presentan `CTX`. Anula los xattrs en disco. Para NFS/vfat/iso9660 |
| `fscontext=CTX` | Etiqueta el *objeto filesystem en sí*; los archivos individuales conservan sus propias etiquetas |
| `defcontext=CTX` | Etiqueta por defecto para archivos recién creados que no tienen un valor derivado de la política |
| `rootcontext=CTX` | Etiqueta solo del inodo raíz del montaje (muy usada por los runtimes de contenedores) |

```console
$ sudo mount -t nfs -o context="system_u:object_r:httpd_sys_content_t:s0" \
      nfs01.prod:/export/web /srv/www

$ grep /srv/www /proc/mounts
nfs01.prod:/export/web /srv/www nfs4 rw,relatime,context=system_u:object_r:httpd_sys_content_t:s0,... 0 0
```

El equivalente en `/etc/fstab`:

```
nfs01.prod:/export/web  /srv/www  nfs4  rw,_netdev,context="system_u:object_r:httpd_sys_content_t:s0",hard,noatime  0 0
```

---

## 6. Booleanos: interruptores de política sin compilar política

Los booleanos son sentencias `if` precompiladas dentro de la política. Son lo *primero* a chequear ante cualquier denegación, porque un caso de uso soportado casi siempre ya tiene un interruptor.

```console
$ getsebool -a | wc -l
343

$ getsebool -a | grep httpd_can_network
httpd_can_network_connect --> off
httpd_can_network_connect_cobbler --> off
httpd_can_network_connect_db --> off
httpd_can_network_memcache --> off
httpd_can_network_relay --> off

$ getsebool httpd_can_network_connect_db
httpd_can_network_connect_db --> off

# Runtime only (lost on reboot) — good for testing
$ sudo setsebool httpd_can_network_connect_db on

# Persistent: -P rewrites the policy store. Slow (seconds), survives reboot.
$ sudo setsebool -P httpd_can_network_connect_db on

# Multiple at once — -P applies to all of them, one policy rebuild
$ sudo setsebool -P httpd_can_network_connect_db=1 httpd_use_nfs=1

# togglesebool: flip runtime state, print the result (policycoreutils)
$ sudo togglesebool httpd_enable_homedirs
httpd_enable_homedirs: active

# Descriptions and default vs current state
$ sudo semanage boolean -l | grep httpd_can_network_connect_db
httpd_can_network_connect_db   (off  ,  on)  Allow httpd to can network connect db
                                ^      ^
                             default  current

$ sudo semanage boolean -l -C            # only booleans changed from default
SELinux boolean                State  Default Description

httpd_can_network_connect_db   (on   ,   on)  Allow httpd to can network connect db

# Which rules does a boolean actually gate?
$ sesearch -A -b httpd_can_network_connect_db
allow httpd_t mysqld_port_t:tcp_socket name_connect; [ httpd_can_network_connect_db ]:True
allow httpd_t postgresql_port_t:tcp_socket name_connect; [ httpd_can_network_connect_db ]:True
```

| Enfoque | Radio de impacto | Correcto cuando |
|---|---|---|
| `setsebool -P <specific>` | Exactamente las reglas que ese booleano controla | Existe un caso de uso soportado por el proveedor — **preferí esto** |
| Módulo propio desde `audit2allow` | Exactamente las reglas revisadas | Ningún booleano lo cubre y el acceso es legítimo |
| `semanage permissive -a <domain>` | Ese dominio queda sin confinar | Temporal, acotado en el tiempo, solo durante una migración |
| `setenforce 0` | Todo el sistema | Solo recuperación de incidentes, nunca un estado estable |
| `SELINUX=disabled` | Todo, para siempre | Nunca |

**Cuidado con el booleano ancho.** `httpd_can_network_connect=on` otorga `name_connect` a *todos* los tipos de puerto. Si el requisito es "llegar a PostgreSQL", `httpd_can_network_connect_db` es un orden de magnitud más angosto, y un módulo propio que nombre `postgresql_port_t` es dos.

---

## 7. RBAC en SELinux: usuarios, roles, `newrole`, `runcon`

La política targeted deja los logins interactivos en `unconfined_t` por defecto. RBAC se vuelve real cuando mapeás logins a usuarios SELinux confinados.

```console
# Map a POSIX login to a confined SELinux user
$ sudo semanage login -a -s staff_u -r s0-s0:c0.c1023 alice
$ sudo semanage login -a -s user_u  -r s0 contractor
$ sudo semanage login -l
Login Name    SELinux User    MLS/MCS Range     Service
__default__   unconfined_u    s0-s0:c0.c1023    *
alice         staff_u         s0-s0:c0.c1023    *
contractor    user_u          s0                *
root          unconfined_u    s0-s0:c0.c1023    *

# Relabel the home directory to match the new user identity
$ sudo genhomedircon
$ sudo restorecon -R -F /home/alice

# alice logs in:
alice$ id -Z
staff_u:staff_r:staff_t:s0-s0:c0.c1023

alice$ sudo systemctl restart httpd     # DAC allows via sudoers, but staff_t cannot manage services
sudo: PERM_SUDOERS: setresuid(-1, 1, -1): Operation not permitted
```

`newrole` realiza una **transición de rol** autenticada dentro de la misma sesión de login (reautentica al usuario y reejecuta la shell en el nuevo contexto):

```console
alice$ newrole -r sysadm_r -t sysadm_t
Password:
alice$ id -Z
staff_u:sysadm_r:sysadm_t:s0-s0:c0.c1023

# Full four-field form, including a level
alice$ newrole -r sysadm_r -t sysadm_t -l s0:c0.c1023

# Which role transitions are legal?
$ seinfo --role_allow | grep staff_r
   allow staff_r sysadm_r;
   allow staff_r unconfined_r;
   allow staff_r system_r;
```

`runcon` ejecuta **un comando** en un contexto especificado (sin reautenticación — la transición ya debe estar permitida por la política, si no `execve` falla):

```console
$ runcon -t container_t -l s0:c42,c917 -- /usr/bin/id -Z
system_u:system_r:container_t:s0:c42,c917

$ runcon -u system_u -r system_r -t httpd_t /usr/sbin/httpd -DFOREGROUND

$ runcon system_u:system_r:httpd_t:s0 /bin/bash
runcon: /bin/bash: Permission denied     # policy has no entrypoint for bash into httpd_t

# Test an MCS-isolated read
$ runcon -l s0:c1,c2 cat /srv/tenant-a/data.db
cat: /srv/tenant-a/data.db: Permission denied      # file is s0:c3,c4 — categories do not dominate
```

| Herramienta | Reautentica | Cambia | Uso típico |
|---|---|---|---|
| `newrole` | Sí (contraseña) | Rol y/o tipo/nivel de la *sesión* | Escalamiento administrativo bajo RBAC |
| `runcon` | No | Contexto de *un* comando ejecutado | Scripts/pruebas; asignación de categorías MCS |
| `sudo -r <role> -t <type>` | Sí (política de sudo) | Rol/tipo para el comando bajo sudo | El reemplazo moderno de `newrole` en la mayoría de los parques |

---

## 8. Escribir y distribuir política

### 8.1 De la denegación al módulo — el ciclo seguro

```console
# 1. Reproduce with dontaudit disabled and the domain permissive
$ sudo semodule -DB
$ sudo semanage permissive -a metricsd_t
$ sudo systemctl restart metricsd && sleep 60 && curl -s localhost:9713/metrics >/dev/null

# 2. Explain WHY, before deciding what to allow
$ sudo ausearch -m AVC -c metricsd -ts recent -i | audit2why
type=AVC msg=audit(08/24/2026 11:23:19.441:1907) : avc:  denied  { name_connect } for
  pid=48117 comm=metricsd dest=5432
  scontext=system_u:system_r:metricsd_t:s0
  tcontext=system_u:object_r:postgresql_port_t:s0 tclass=tcp_socket permissive=1

	Was caused by:
	Missing type enforcement (TE) allow rule.

	You can use audit2allow to generate a loadable module to allow this access.

# 3. Generate a REVIEWABLE module (never pipe blindly into semodule)
$ sudo ausearch -m AVC -c metricsd -ts recent -r > /tmp/metricsd.avc
$ audit2allow -i /tmp/metricsd.avc

#============= metricsd_t ==============
allow metricsd_t postgresql_port_t:tcp_socket name_connect;
allow metricsd_t proc_net_t:file { getattr open read };
allow metricsd_t self:capability dac_read_search;

# 4. Review each line. Reject anything that looks like a symptom of a mislabel.
#    'dac_read_search' here means the daemon is reading something it should not —
#    fix the label, do not grant the capability.

# 5. Build and install the reviewed module
$ audit2allow -i /tmp/metricsd.avc -M metricsd_local
******************** IMPORTANT ***********************
To make this policy package active, execute:

semodule -i metricsd_local.pp

$ cat metricsd_local.te
module metricsd_local 1.0;

require {
	type metricsd_t;
	type postgresql_port_t;
	type proc_net_t;
	class tcp_socket name_connect;
	class file { getattr open read };
}

#============= metricsd_t ==============
allow metricsd_t postgresql_port_t:tcp_socket name_connect;
allow metricsd_t proc_net_t:file { getattr open read };

$ sudo semodule -i metricsd_local.pp

# 6. Undo the temporary loosening and re-verify in enforcing
$ sudo semanage permissive -d metricsd_t
$ sudo semodule -B
$ sudo semanage permissive -l
Builtin Permissive Types

Customized Permissive Types
(none)
```

> **`audit2allow` es un generador de código, no un oráculo.** Convierte "esto fue denegado" en "permitir esto". Si la denegación la causa una etiqueta equivocada, una asignación de puerto equivocada, o una intrusión real, `audit2allow` escribirá fielmente una regla que la legitime. El paso de revisión obligatorio es: *para cada regla, ¿el tipo objetivo es el que este servicio se supone que debe tocar?*

### 8.2 Un módulo de política completo, con forma de producción

Tres archivos fuente más una compilación. Esta es la forma de política que se distribuye con un producto, no un parche encima de denegaciones.

**`metricsd.te`**

```
policy_module(metricsd, 1.0.0)

########################################
#
# Declarations
#

## <desc>
##	<p>
##	Allow metricsd to connect to any network port.
##	</p>
## </desc>
gen_tunable(metricsd_connect_any, false)

type metricsd_t;
type metricsd_exec_t;
init_daemon_domain(metricsd_t, metricsd_exec_t)

type metricsd_conf_t;
files_config_file(metricsd_conf_t)

type metricsd_var_lib_t;
files_type(metricsd_var_lib_t)

type metricsd_log_t;
logging_log_file(metricsd_log_t)

type metricsd_runtime_t alias metricsd_var_run_t;
files_runtime_file(metricsd_runtime_t)

type metricsd_unit_t;
systemd_unit_file(metricsd_unit_t)

type metricsd_port_t;
corenet_port(metricsd_port_t)

########################################
#
# Local policy
#

allow metricsd_t self:capability { setgid setuid };
allow metricsd_t self:process { getsched setsched signal signull };
allow metricsd_t self:fifo_file rw_fifo_file_perms;
allow metricsd_t self:tcp_socket { create_stream_socket_perms accept listen };
allow metricsd_t self:unix_dgram_socket create_socket_perms;
allow metricsd_t self:netlink_route_socket r_netlink_socket_perms;

# Configuration: read-only
read_files_pattern(metricsd_t, metricsd_conf_t, metricsd_conf_t)
read_lnk_files_pattern(metricsd_t, metricsd_conf_t, metricsd_conf_t)
list_dirs_pattern(metricsd_t, metricsd_conf_t, metricsd_conf_t)

# State directory: read/write, with automatic labelling of new objects
manage_dirs_pattern(metricsd_t, metricsd_var_lib_t, metricsd_var_lib_t)
manage_files_pattern(metricsd_t, metricsd_var_lib_t, metricsd_var_lib_t)
files_var_lib_filetrans(metricsd_t, metricsd_var_lib_t, { dir file })

# Logs: append-only from the daemon's point of view
create_files_pattern(metricsd_t, metricsd_log_t, metricsd_log_t)
append_files_pattern(metricsd_t, metricsd_log_t, metricsd_log_t)
setattr_files_pattern(metricsd_t, metricsd_log_t, metricsd_log_t)
logging_log_filetrans(metricsd_t, metricsd_log_t, file)

# Runtime directory (/run/metricsd)
manage_dirs_pattern(metricsd_t, metricsd_runtime_t, metricsd_runtime_t)
manage_files_pattern(metricsd_t, metricsd_runtime_t, metricsd_runtime_t)
manage_sock_files_pattern(metricsd_t, metricsd_runtime_t, metricsd_runtime_t)
files_runtime_filetrans(metricsd_t, metricsd_runtime_t, { dir file sock_file })

# Network: bind only the assigned port
corenet_all_recvfrom_netlabel(metricsd_t)
corenet_tcp_sendrecv_generic_if(metricsd_t)
corenet_tcp_sendrecv_generic_node(metricsd_t)
corenet_tcp_bind_generic_node(metricsd_t)
allow metricsd_t metricsd_port_t:tcp_socket name_bind;

# Minimum viable system access
kernel_read_system_state(metricsd_t)
kernel_read_network_state(metricsd_t)
files_read_etc_files(metricsd_t)
files_read_usr_files(metricsd_t)
miscfiles_read_localization(metricsd_t)
miscfiles_read_generic_certs(metricsd_t)
sysnet_dns_name_resolve(metricsd_t)
auth_use_nsswitch(metricsd_t)

optional_policy(`
	systemd_read_fifo_file_passwd_run(metricsd_t)
	systemd_use_fds_logind(metricsd_t)
')

optional_policy(`
	# Scrape the local PostgreSQL exporter socket
	postgresql_stream_connect(metricsd_t)
')

tunable_policy(`metricsd_connect_any',`
	corenet_tcp_connect_all_ports(metricsd_t)
	corenet_tcp_sendrecv_all_ports(metricsd_t)
')
```

**`metricsd.fc`**

```
/usr/bin/metricsd                            --  gen_context(system_u:object_r:metricsd_exec_t,s0)
/usr/lib/systemd/system/metricsd\.service    --  gen_context(system_u:object_r:metricsd_unit_t,s0)
/etc/metricsd(/.*)?                              gen_context(system_u:object_r:metricsd_conf_t,s0)
/var/lib/metricsd(/.*)?                          gen_context(system_u:object_r:metricsd_var_lib_t,s0)
/var/log/metricsd(/.*)?                          gen_context(system_u:object_r:metricsd_log_t,s0)
/run/metricsd(/.*)?                              gen_context(system_u:object_r:metricsd_runtime_t,s0)
```

**`metricsd.if`** — el archivo de interfaz que otros módulos van a invocar

```
## <summary>Prometheus-compatible metrics exporter.</summary>

########################################
## <summary>
##	Allow the specified domain to read metricsd state files.
## </summary>
## <param name="domain">
##	<summary>Domain allowed access.</summary>
## </param>
#
interface(`metricsd_read_state_files',`
	gen_require(`
		type metricsd_var_lib_t;
	')

	files_search_var_lib($1)
	read_files_pattern($1, metricsd_var_lib_t, metricsd_var_lib_t)
')

########################################
## <summary>
##	Connect to metricsd over its TCP port.
## </summary>
## <param name="domain">
##	<summary>Domain allowed access.</summary>
## </param>
#
interface(`metricsd_tcp_connect',`
	gen_require(`
		type metricsd_port_t;
	')

	allow $1 metricsd_port_t:tcp_socket name_connect;
')
```

**Compilar, instalar, verificar:**

```console
$ sudo dnf install -y selinux-policy-devel policycoreutils-devel

$ make -f /usr/share/selinux/devel/Makefile metricsd.pp
Compiling targeted metricsd module
Creating targeted metricsd.pp policy package
rm tmp/metricsd.mod.fc tmp/metricsd.mod

# Or the low-level path the Makefile wraps:
$ checkmodule -M -m -o metricsd.mod metricsd.te
$ semodule_package -o metricsd.pp -m metricsd.mod -f metricsd.fc

$ sudo semodule -i metricsd.pp
$ sudo semodule -l | grep metricsd
metricsd

$ sudo semodule --list-modules=full | grep -E 'metricsd|^400'
400 metricsd          pp
100 metricsd          pp

$ sudo semanage port -a -t metricsd_port_t -p tcp 9713
$ sudo restorecon -RvF /usr/bin/metricsd /etc/metricsd /var/lib/metricsd /var/log/metricsd
$ sudo systemctl restart metricsd

$ ps -eZ | grep metricsd
system_u:system_r:metricsd_t:s0   48302 ?  00:00:00 metricsd

$ sepolicy manpage -d metricsd_t -p /usr/share/man/man8
/usr/share/man/man8/metricsd_selinux.8

# Bootstrapping a skeleton for a new daemon (generates .te/.fc/.if/.sh)
$ sepolicy generate --init /usr/bin/metricsd
Created the following files:
/root/policy/metricsd.te     # Type Enforcement file
/root/policy/metricsd.if     # Interface file
/root/policy/metricsd.fc     # File Contexts file
/root/policy/metricsd_selinux.spec  # Spec file
/root/policy/metricsd.sh     # Setup Script
```

### 8.3 Prioridades de módulo y CIL

`semodule` soporta prioridades: para módulos con el mismo nombre, gana la prioridad más alta. La prioridad **100** es la de la distribución por defecto; **400** es la ranura convencional para overrides locales.

```console
# Override a vendor module without editing it
$ sudo semodule -X 400 -i my-httpd-override.pp

# Ship a tiny CIL module (no compilation toolchain needed — semodule ingests CIL directly)
$ cat > local_metricsd.cil <<'EOF'
(allow metricsd_t postgresql_port_t (tcp_socket (name_connect)))
(allow metricsd_t node_t (tcp_socket (node_bind)))
EOF
$ sudo semodule -X 400 -i local_metricsd.cil

$ sudo semodule -d unconfineduser          # disable a module
$ sudo semodule -e unconfineduser          # enable it again
$ sudo semodule -r metricsd                # remove (from priority 400 if -X 400 given)
$ sudo semodule -B                         # rebuild + reload policy from the store
$ sudo semodule --checksum metricsd
metricsd sha256:5f1c...c2a9
```

Para contenedores, `udica` genera una política CIL a medida a partir de la salida de inspect de un contenedor en ejecución — el camino pragmático hacia el confinamiento por carga de trabajo:

```console
$ sudo podman inspect metrics-exporter > /tmp/ctr.json
$ udica -j /tmp/ctr.json metrics_exporter
Policy metrics_exporter created!

Please load these modules using:
# semodule -i metrics_exporter.cil /usr/share/udica/templates/{base_container.cil,net_container.cil}

Restart the container with: "--security-opt label=type:metrics_exporter.process"
```

---

## 9. Diagnóstico: leer denegaciones como un ingeniero de sistemas

### 9.1 Anatomía de un registro AVC

```
type=AVC msg=audit(1755980412.317:1043): avc:  denied  { name_connect } for
  pid=2914 comm="httpd" dest=5432
  scontext=system_u:system_r:httpd_t:s0
  tcontext=system_u:object_r:postgresql_port_t:s0
  tclass=tcp_socket permissive=0
```

| Campo | Significado | Qué hacer con él |
|---|---|---|
| `audit(1755980412.317:1043)` | epoch.ms : serial | Correlacionar con el resto del grupo de eventos (`SYSCALL`, `PATH`, `CWD`) por el serial |
| `denied { name_connect }` | El o los permisos rechazados | Alimentar `sesearch -p` para ver si un booleano lo controla |
| `pid` / `comm` | Proceso infractor | Confirmar que es el proceso que creés que es |
| `scontext` | Contexto del sujeto (proceso) | Si esto es `unconfined_t`, tu daemon nunca transicionó — ese es el bug real |
| `tcontext` | Contexto del objeto | Si esto es `default_t`, `var_t` o `admin_home_t`, tenés un **etiquetado incorrecto**, no una regla faltante |
| `tclass` | Clase del objeto | `file` vs `dir` vs `lnk_file` vs `tcp_socket` — la clase es parte de la regla |
| `permissive=0/1` | Si se aplicó | `1` significa que la operación tuvo éxito y esto es informativo |

**La regla de decisión que evita el 80 % de las políticas malas:**

```
tcontext is a *_t belonging to another service, or default_t / var_t / admin_home_t / user_home_t
        └──► MISLABEL. Fix with semanage fcontext + restorecon. Do NOT audit2allow.

tcontext is the correct type, and sesearch shows a rule gated by [ boolean ]:False
        └──► setsebool -P <boolean> on

tcontext is correct, no boolean exists, access is genuinely required
        └──► custom module (reviewed)

scontext is unconfined_t / init_t for a daemon that should be confined
        └──► the binary has the wrong label, or NoNewPrivileges blocks the transition
```

### 9.2 La cadena de herramientas

```console
# Full event group: AVC + SYSCALL + PATH + PROCTITLE, human-readable
$ sudo ausearch -m AVC,USER_AVC,SELINUX_ERR,USER_SELINUX_ERR -ts recent -i
----
type=PROCTITLE msg=audit(08/24/2026 11:23:19.441:1907) : proctitle=/usr/sbin/httpd -DFOREGROUND
type=SOCKADDR msg=audit(08/24/2026 11:23:19.441:1907) : saddr={ saddr_fam=inet laddr=10.42.0.7 lport=5432 }
type=SYSCALL msg=audit(08/24/2026 11:23:19.441:1907) : arch=x86_64 syscall=connect
  success=no exit=EACCES(Permission denied) a0=0xd a1=0x7ffd2f1c a2=0x10 a3=0x0 items=0
  ppid=1 pid=2914 auid=unset uid=apache gid=apache euid=apache suid=apache fsuid=apache
  egid=apache sgid=apache fsgid=apache tty=(none) ses=unset comm=httpd exe=/usr/sbin/httpd
  subj=system_u:system_r:httpd_t:s0 key=(null)
type=AVC msg=audit(08/24/2026 11:23:19.441:1907) : avc:  denied  { name_connect } for
  pid=2914 comm=httpd dest=5432 scontext=system_u:system_r:httpd_t:s0
  tcontext=system_u:object_r:postgresql_port_t:s0 tclass=tcp_socket permissive=0

# Narrow by time, process, or subject context
$ sudo ausearch -m AVC -ts today -c nginx -i
$ sudo ausearch -m AVC -ts 11:00 -te 11:30 -i
$ sudo ausearch -m AVC --subject system_u:system_r:httpd_t:s0 -i
$ sudo ausearch -m AVC -ts boot -i | grep -c denied

# Aggregate: what is actually noisy?
$ sudo aureport -a --summary

AVC Summary Report
===================================
total  comm
===================================
   412  httpd
    37  metricsd
     4  sshd

# journald path (when auditd is not running, AVCs land in the journal via kaudit)
$ sudo journalctl -t setroubleshoot --since "-1h"
$ sudo journalctl _TRANSPORT=audit --since today | grep AVC

# Human-readable analysis with remediation hints (setroubleshoot-server)
$ sudo sealert -a /var/log/audit/audit.log
SELinux is preventing /usr/sbin/httpd from name_connect access on the tcp_socket port 5432.

*****  Plugin catchall_boolean (89.3 confidence) suggests  ********************

If you want to allow httpd to can network connect db
Then you must tell SELinux about this by enabling the 'httpd_can_network_connect_db' boolean.

Do
setsebool -P httpd_can_network_connect_db 1

*****  Plugin catchall (11.6 confidence) suggests  ***************************

If you believe that httpd should be allowed name_connect access on the port 5432
  tcp_socket by default.
Then you should report this as a bug.
...

Additional Information:
Source Context                system_u:system_r:httpd_t:s0
Target Context                system_u:object_r:postgresql_port_t:s0
Target Objects                port 5432 [ tcp_socket ]
Source                        httpd
Source Path                   /usr/sbin/httpd
Policy RPM                    selinux-policy-40.13.13-1.fc41.noarch
Enforcing Mode                Enforcing
Local ID                      3a9b71c2-1c88-4b1c-9a41-3c02a2f6f101

# Per-alert detail
$ sudo sealert -l 3a9b71c2-1c88-4b1c-9a41-3c02a2f6f101

# AVC cache health — a low hit ratio means the cache is thrashing (rare; usually a policy bug)
$ sudo avcstat 5
   lookups       hits     misses     allocs    reclaims      frees
  73282516   73280109       2407       2407        1728       1789
      5187       5187          0          0           0          0
      4903       4903          0          0           0          0
```

**Nota sobre `seaudit`.** Los objetivos del examen listan `seaudit` (y `seaudit-report`), la GUI de SETools 3 para navegar logs de auditoría contra una política. **SETools 4 eliminó `seaudit`, `seaudit-report`, `sediffx` y `sechecker`.** En cualquier distribución actual el flujo equivalente es `ausearch` + `audit2why`/`audit2allow` + `sealert`, quedando `apol` como la herramienta gráfica de análisis de *política*. Conocé el nombre y su propósito para el examen; usá las herramientas modernas en producción.

```console
$ apol /sys/fs/selinux/policy &        # Qt GUI: type/attribute queries, information-flow and
                                        # domain-transition analysis, TE/RBAC/MLS rule browsing
$ apol /etc/selinux/targeted/policy/policy.33 &
```

### 9.3 Catálogo de fallos

| Síntoma | Causa probable | Diagnóstico | Solución |
|---|---|---|---|
| El servicio devuelve 403/EACCES, **sin AVC en el log** | DAC denegó primero, o una regla `dontaudit` | `ls -l`, luego `semodule -DB` y reintentar | Corregir los permisos POSIX; o leer el AVC recién visible |
| Funciona después de `setenforce 0` | Denegación MAC genuina | `ausearch -m AVC -ts recent` | Booleano, o módulo revisado |
| Los archivos quedaron inaccesibles tras un restore/`rsync` | Los xattrs no se preservaron | `ls -Z`, `restorecon -Rvn` | `restorecon -Rv`; usar `rsync -aAX` / `tar --xattrs --selinux` |
| El daemon corre como `unconfined_t` o `init_t` | El binario tiene la etiqueta equivocada, o `NoNewPrivileges` bloquea la transición | `ls -Z /usr/bin/x`; `ps -eZ` | `restorecon` sobre el binario; agregar `process2 { nnp_transition }` |
| El servicio no puede hacer bind de un puerto no estándar | El puerto no está en el tipo de puerto de la política | `semanage port -l \| grep <n>` | `semanage port -a -t <type> -p tcp <n>` |
| El arranque se cuelga tras rehabilitar SELinux | Filesystem sin etiquetar | Arrancar con `enforcing=0` | `touch /.autorelabel && reboot` |
| Una unit de systemd falla con `Failed at step SELINUX` | `SELinuxContext=` nombra un contexto que la política no permitirá | `journalctl -u <unit> -b` | Corregir el contexto, o quitar la directiva y confiar en el `type_transition` |
| El contenedor no puede leer un directorio del host montado por bind | El directorio del host no es `container_file_t` | `ls -Zd <dir>` | `podman run -v /data:/data:Z`, o `semanage fcontext -a -t container_file_t` |
| Dos contenedores ven los datos montados del otro | Categorías MCS deshabilitadas o idénticas | `ps -eZ \| grep container_t` | Asegurar que el runtime asigne `s0:cX,cY` distintos; no usar `label=disable` |
| `setsebool -P` tarda 30 s y dispara la CPU | Reconstrucción completa del policy store | esperado | Agrupar varios booleanos en una sola invocación con `-P` |
| `semanage` falla: `SELinux policy is not managed or store cannot be accessed` | Se ejecuta contra un store en el que la herramienta no puede escribir, o SELinux deshabilitado en el arranque | `sestatus`, `ls /etc/selinux/targeted/active` | Rehabilitar SELinux; revisar `store-root` en `/etc/selinux/semanage.conf` |

### 9.4 La palanca de recuperación que tenés que memorizar

```
# At the GRUB menu, press 'e', append to the linux line:
enforcing=0

# After boot, from a shell:
$ sudo ausearch -m AVC -ts boot -i > /root/boot-avcs.txt
$ sudo restorecon -Rv /etc /var /usr        # or: touch /.autorelabel && reboot
$ sudo setenforce 1
```

Nunca uses `selinux=0` como primera respuesta: detiene el mantenimiento de xattrs y convierte una solución de cinco minutos en un reetiquetado de todo el filesystem.

---

## 10. Integración en producción

### 10.1 systemd

```ini
# /etc/systemd/system/metricsd.service
[Unit]
Description=Prometheus metrics exporter
Documentation=https://example.internal/docs/metricsd
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStart=/usr/bin/metricsd --config /etc/metricsd/metricsd.yaml --listen 0.0.0.0:9713
User=metricsd
Group=metricsd

# --- MAC ---------------------------------------------------------------
# SELinux: normally omit this and let the policy's type_transition do the work.
# Set it explicitly only when the unit must run in a non-default domain.
SELinuxContext=system_u:system_r:metricsd_t:s0
# AppArmor equivalent (ignored on SELinux systems, and vice versa):
#AppArmorProfile=metricsd
# Smack equivalent:
#SmackProcessLabel=Metrics

# --- Classic hardening (composes with, does not replace, MAC) -----------
NoNewPrivileges=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictNamespaces=yes
RestrictSUIDSGID=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
SystemCallFilter=@system-service
SystemCallArchitectures=native
CapabilityBoundingSet=
AmbientCapabilities=

StateDirectory=metricsd
LogsDirectory=metricsd
RuntimeDirectory=metricsd
ReadWritePaths=/var/lib/metricsd /var/log/metricsd

Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
```

```console
$ sudo systemctl daemon-reload && sudo systemctl restart metricsd
$ systemctl show metricsd -p SELinuxContext -p NoNewPrivileges
SELinuxContext=system_u:system_r:metricsd_t:s0
NoNewPrivileges=yes

$ sudo systemd-analyze security metricsd
NAME                                          DESCRIPTION                            EXPOSURE
✓ SELinuxContext=                             Service has an SELinux label
✓ NoNewPrivileges=                            Service processes cannot acquire new privileges
✓ CapabilityBoundingSet=~CAP_SYS_ADMIN        Service has no administrator privileges
...
→ Overall exposure level for metricsd.service: 1.8 OK 🙂
```

**Trampa:** `AppArmorProfile=` combinado con `NoNewPrivileges=yes` rompe las transiciones de perfil disparadas por exec dentro del servicio, porque el kernel rechaza transiciones que podrían otorgar privilegio a una tarea con `no_new_privs`. Si un binario auxiliar dentro del servicio debe correr bajo un perfil distinto, el perfil tiene que apilarse (`px -> child` con `Cx`/`stack`) en lugar de transicionar, o hay que relajar `NoNewPrivileges=` para esa unit.

### 10.2 Contenedores (Podman / CRI-O)

```console
$ sudo podman run -d --name web -p 8080:80 \
    -v /srv/www:/usr/share/nginx/html:ro,Z \
    docker.io/library/nginx:1.27

$ ps -eZ | grep nginx
system_u:system_r:container_t:s0:c214,c802  51234 ?  00:00:00 nginx

$ ls -Zd /srv/www
system_u:object_r:container_file_t:s0:c214,c802 /srv/www
```

| Flag de volumen | Efecto | Usarlo cuando |
|---|---|---|
| `:z` | Reetiqueta a `container_file_t` **sin** categorías MCS — compartido por todos los contenedores | Varios contenedores deben compartir el volumen |
| `:Z` | Reetiqueta a `container_file_t` con las categorías **privadas de este contenedor** | Datos privados de un solo contenedor — **preferí esto** |
| *(ninguno)* | Sin reetiquetar; el contenedor recibe una denegación salvo que la etiqueta del host ya coincida | La etiqueta del host ya es correcta |

```console
# Run in a custom, udica-generated domain
$ sudo podman run --security-opt label=type:metrics_exporter.process ...

# Pin the MCS level explicitly (stable across restarts — needed for shared PVs)
$ sudo podman run --security-opt label=level:s0:c100,c200 ...

# The escape hatch — audit any use of it
$ sudo podman run --security-opt label=disable ...
$ ps -eZ | grep nginx
system_u:system_r:spc_t:s0   51999 ?  00:00:00 nginx        # spc_t = "super privileged container": unconfined
```

**`:z` vs `:Z` es un control real de multi-tenancy.** `:z` elimina las categorías, lo que significa que todo proceso `container_t` en el host puede leer ese volumen. En un nodo compartido esto convierte silenciosamente el aislamiento por contenedor en compartición a nivel de todo el host.

### 10.3 Kubernetes: carga de trabajo confinada por SELinux

```yaml
# selinux-confined-workload.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: tenant-a
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: metrics-exporter
  namespace: tenant-a
automountServiceAccountToken: false
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: metricsd-config
  namespace: tenant-a
data:
  metricsd.yaml: |
    listen: 0.0.0.0:9713
    scrape_interval: 15s
    targets:
      - name: postgres
        dsn: postgresql://exporter@db.tenant-a.svc:5432/appdb?sslmode=verify-full
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: metrics-exporter
  namespace: tenant-a
  labels:
    app.kubernetes.io/name: metrics-exporter
    app.kubernetes.io/part-of: observability
spec:
  replicas: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: metrics-exporter
  template:
    metadata:
      labels:
        app.kubernetes.io/name: metrics-exporter
    spec:
      serviceAccountName: metrics-exporter
      automountServiceAccountToken: false
      # Pod-level security context: SELinux label applies to the whole pod
      # (all containers AND the volumes the kubelet relabels for it).
      securityContext:
        runAsNonRoot: true
        runAsUser: 10113
        runAsGroup: 10113
        fsGroup: 10113
        seccompProfile:
          type: RuntimeDefault
        seLinuxOptions:
          # user/role are normally left to the runtime defaults (system_u:system_r).
          # 'type' selects the confinement domain; 'level' provides MCS isolation.
          type: container_t
          level: "s0:c101,c201"
      containers:
        - name: metricsd
          image: registry.internal/observability/metricsd:1.8.2
          imagePullPolicy: IfNotPresent
          args:
            - --config=/etc/metricsd/metricsd.yaml
          ports:
            - name: metrics
              containerPort: 9713
              protocol: TCP
          securityContext:
            allowPrivilegeEscalation: false
            privileged: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
            # Container-level seLinuxOptions override the pod-level value
            # for this container's process (but not for volume relabelling).
            seLinuxOptions:
              type: container_t
              level: "s0:c101,c201"
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 500m
              memory: 256Mi
          volumeMounts:
            - name: config
              mountPath: /etc/metricsd
              readOnly: true
            - name: state
              mountPath: /var/lib/metricsd
            - name: tmp
              mountPath: /tmp
          livenessProbe:
            httpGet:
              path: /-/healthy
              port: metrics
            initialDelaySeconds: 10
            periodSeconds: 20
          readinessProbe:
            httpGet:
              path: /-/ready
              port: metrics
            initialDelaySeconds: 5
            periodSeconds: 10
      volumes:
        - name: config
          configMap:
            name: metricsd-config
            defaultMode: 0444
        - name: state
          emptyDir:
            sizeLimit: 128Mi
        - name: tmp
          emptyDir:
            medium: Memory
            sizeLimit: 32Mi
---
apiVersion: v1
kind: Service
metadata:
  name: metrics-exporter
  namespace: tenant-a
spec:
  selector:
    app.kubernetes.io/name: metrics-exporter
  ports:
    - name: metrics
      port: 9713
      targetPort: metrics
      protocol: TCP
```

Verificación en el nodo:

```console
$ kubectl -n tenant-a get pod -o jsonpath='{.items[*].spec.securityContext.seLinuxOptions}' | jq
{
  "level": "s0:c101,c201",
  "type": "container_t"
}

$ kubectl -n tenant-a exec deploy/metrics-exporter -- cat /proc/self/attr/current
system_u:system_r:container_t:s0:c101,c201

# On the node itself:
[node]$ sudo crictl ps --name metricsd -q | xargs -I{} sudo crictl inspect {} \
          | jq -r '.info.runtimeSpec.linux.mountLabel, .status.labels'
system_u:object_r:container_file_t:s0:c101,c201

[node]$ ps -eZ | grep metricsd
system_u:system_r:container_t:s0:c101,c201  84211 ?  00:00:01 metricsd
```

> **Nota sobre el reetiquetado de volúmenes.** Históricamente el kubelet hacía un `chcon` *recursivo* sobre los volúmenes con una etiqueta específica del pod, lo cual es O(archivos) y puede demorar el arranque del pod durante minutos en PVs grandes. Las versiones recientes de Kubernetes pasan la etiqueta como opción de montaje `-o context=` en su lugar (feature gates alrededor de `SELinuxMountReadWriteOncePod` / `SELinuxMount`, más el campo `spec.securityContext.seLinuxChangePolicy` con los valores `MountOption` y `Recursive`). Revisá `kubectl explain pod.spec.securityContext.seLinuxChangePolicy` en la versión de tu clúster antes de depender de cualquiera de los dos comportamientos.

### 10.4 Kubernetes: carga de trabajo confinada por AppArmor

```yaml
# apparmor-confined-workload.yaml
apiVersion: v1
kind: Pod
metadata:
  name: hardened-nginx
  namespace: tenant-a
spec:
  securityContext:
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: nginx
      image: registry.internal/base/nginx:1.27
      securityContext:
        # GA field since Kubernetes 1.30. Replaces the deprecated annotation
        # container.apparmor.security.beta.kubernetes.io/<container>: localhost/<profile>
        appArmorProfile:
          type: Localhost              # RuntimeDefault | Localhost | Unconfined
          localhostProfile: k8s-nginx-hardened
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
          add: ["NET_BIND_SERVICE"]
      ports:
        - containerPort: 80
```

Los perfiles deben existir en todos los nodos antes de que el pod se programe. El mecanismo estándar de distribución:

```yaml
# apparmor-loader-daemonset.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: apparmor-profiles
  namespace: kube-system
data:
  k8s-nginx-hardened: |
    #include <tunables/global>

    profile k8s-nginx-hardened flags=(attach_disconnected,mediate_deleted) {
      #include <abstractions/base>
      #include <abstractions/nameservice>
      #include <abstractions/openssl>

      capability net_bind_service,
      capability setuid,
      capability setgid,

      network inet  stream,
      network inet6 stream,

      /usr/sbin/nginx        mr,
      /etc/nginx/**          r,
      /usr/share/nginx/**    r,
      /var/log/nginx/*.log   w,
      /var/cache/nginx/**    rw,
      /run/nginx.pid         rw,
      /dev/urandom           r,
      /proc/sys/kernel/ngroups_max r,

      # Explicit denials: audited even though nothing would have granted them
      deny /etc/shadow             rwklx,
      deny /root/**                rwklx,
      deny /home/**                rwklx,
      deny /var/run/secrets/**     rwklx,
      deny /**                     wl,
      deny /bin/**                 x,
      deny /usr/bin/**             x,
      deny mount,
      deny ptrace,
    }
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: apparmor-loader
  namespace: kube-system
  labels:
    app.kubernetes.io/name: apparmor-loader
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: apparmor-loader
  template:
    metadata:
      labels:
        app.kubernetes.io/name: apparmor-loader
    spec:
      hostPID: true
      tolerations:
        - operator: Exists
      containers:
        - name: loader
          image: registry.internal/base/apparmor-loader:1.2.0
          args: ["-poll", "60s", "/profiles"]
          securityContext:
            privileged: true              # apparmor_parser requires CAP_MAC_ADMIN on the host
          volumeMounts:
            - name: profiles
              mountPath: /profiles
              readOnly: true
            - name: apparmorfs
              mountPath: /sys/kernel/security
            - name: apparmor-includes
              mountPath: /etc/apparmor.d
          resources:
            requests: { cpu: 10m, memory: 32Mi }
            limits:   { cpu: 100m, memory: 128Mi }
      volumes:
        - name: profiles
          configMap:
            name: apparmor-profiles
        - name: apparmorfs
          hostPath:
            path: /sys/kernel/security
            type: Directory
        - name: apparmor-includes
          hostPath:
            path: /etc/apparmor.d
            type: Directory
```

### 10.5 Línea base de Ansible (configuración idempotente de SELinux)

```yaml
# roles/selinux-baseline/tasks/main.yml
---
- name: Ensure SELinux tooling is present
  ansible.builtin.package:
    name:
      - policycoreutils
      - policycoreutils-python-utils
      - selinux-policy-targeted
      - setools-console
      - setroubleshoot-server
      - libselinux-python3
    state: present

- name: Enforce targeted policy at boot
  ansible.posix.selinux:
    policy: targeted
    state: enforcing
  register: selinux_state

- name: Report that a reboot is required to reach the configured state
  ansible.builtin.debug:
    msg: "SELinux state change requires reboot: {{ selinux_state.reboot_required }}"
  when: selinux_state.reboot_required | default(false)

- name: Set required booleans persistently
  ansible.posix.seboolean:
    name: "{{ item }}"
    state: true
    persistent: true
  loop:
    - httpd_can_network_connect_db
    - httpd_use_nfs
    - nis_enabled

- name: Declare file contexts for application data
  community.general.sefcontext:
    target: "{{ item.target }}"
    setype: "{{ item.setype }}"
    ftype: a
    state: present
  loop:
    - { target: '/srv/www(/.*)?',                 setype: httpd_sys_content_t }
    - { target: '/srv/www/app/var/uploads(/.*)?', setype: httpd_sys_rw_content_t }
    - { target: '/var/lib/metricsd(/.*)?',        setype: metricsd_var_lib_t }
  notify: restore application contexts

- name: Assign non-standard ports
  community.general.seport:
    ports: "{{ item.port }}"
    proto: tcp
    setype: "{{ item.setype }}"
    state: present
  loop:
    - { port: '8081', setype: http_port_t }
    - { port: '9713', setype: metricsd_port_t }

- name: Assert no permissive domains remain in production
  ansible.builtin.command: semanage permissive -l -n
  register: permissive_domains
  changed_when: false
  failed_when: permissive_domains.stdout | trim | length > 0

# roles/selinux-baseline/handlers/main.yml
---
- name: restore application contexts
  ansible.builtin.command: restorecon -Rv /srv/www /var/lib/metricsd
```

---

## 11. AppArmor

### 11.1 Arquitectura y postura

AppArmor es **MAC basado en rutas**: los perfiles se adosan a los ejecutables por nombre de ruta, y las reglas median el acceso por patrón de ruta. No interviene ningún metadato del filesystem, lo que lo hace dramáticamente más fácil de escribir y dramáticamente más débil para expresar la identidad de un objeto.

Por defecto en Debian, Ubuntu y SUSE. Los perfiles viven en `/etc/apparmor.d/`, nombrados escapando la ruta del binario (`/usr/sbin/nginx` → `usr.sbin.nginx`).

```console
$ sudo aa-status
apparmor module is loaded.
57 profiles are loaded.
49 profiles are in enforce mode.
   /usr/bin/man
   /usr/lib/NetworkManager/nm-dhcp-client.action
   /usr/sbin/nginx
   /usr/sbin/sshd
   docker-default
   lsb_release
   man_filter
   man_groff
   ...
6 profiles are in complain mode.
   /usr/bin/metricsd
   ...
2 profiles are in kill mode.
0 profiles are in unconfined mode.
9 processes have profiles defined.
7 processes are in enforce mode.
   /usr/sbin/nginx (1204)
   /usr/sbin/nginx (1205)
   /usr/sbin/sshd (988)
   ...
2 processes are in complain mode.
   /usr/bin/metricsd (48302)
0 processes are unconfined but have a profile defined.
0 processes are in mixed mode.
0 processes are in kill mode.

$ sudo aa-status --json | jq '.profiles | to_entries | group_by(.value) | map({mode: .[0].value, count: length})'
[
  { "mode": "complain", "count": 6 },
  { "mode": "enforce",  "count": 49 },
  { "mode": "kill",     "count": 2 }
]

$ sudo aa-unconfined --paranoid
988 /usr/sbin/sshd confined by '/usr/sbin/sshd (enforce)'
1204 /usr/sbin/nginx confined by '/usr/sbin/nginx (enforce)'
2311 /usr/bin/redis-server not confined
2450 /usr/local/bin/legacy-agent not confined

$ cat /proc/1204/attr/current
/usr/sbin/nginx (enforce)

$ sudo cat /sys/kernel/security/apparmor/profiles | head -5
/usr/bin/man (enforce)
/usr/sbin/nginx (enforce)
/usr/sbin/sshd (enforce)
docker-default (enforce)
/usr/bin/metricsd (complain)
```

`aa-unconfined` escanea los procesos que escuchan en la red e informa cuáles no tienen perfil — el comando más útil para responder "¿cuál es mi brecha de cobertura?" en un parque con AppArmor.

### 11.2 Modos de perfil y ciclo de vida

| Modo | Comportamiento | Comando |
|---|---|---|
| **enforce** | Deniega y registra | `aa-enforce /etc/apparmor.d/usr.sbin.nginx` |
| **complain** | Permite y registra (modo de aprendizaje) | `aa-complain /etc/apparmor.d/usr.sbin.nginx` |
| **kill** | Deniega y hace `SIGKILL` a la tarea | `flags=(kill)` en el perfil |
| **unconfined** | Perfil cargado pero inerte | `flags=(unconfined)` |
| **disabled** | Perfil no cargado; symlink en `disable/` | `aa-disable /etc/apparmor.d/usr.sbin.nginx` |

```console
$ sudo aa-complain /usr/sbin/nginx
Setting /etc/apparmor.d/usr.sbin.nginx to complain mode.

$ sudo aa-enforce /usr/sbin/nginx
Setting /etc/apparmor.d/usr.sbin.nginx to enforce mode.

$ sudo aa-disable /usr/sbin/nginx
Disabling /etc/apparmor.d/usr.sbin.nginx.
$ ls -l /etc/apparmor.d/disable/
lrwxrwxrwx 1 root root 31 Aug 24 11:42 usr.sbin.nginx -> /etc/apparmor.d/usr.sbin.nginx

# Low-level parser operations
$ sudo apparmor_parser -r /etc/apparmor.d/usr.sbin.nginx     # replace (reload)
$ sudo apparmor_parser -R /etc/apparmor.d/usr.sbin.nginx     # remove from kernel
$ sudo apparmor_parser -Q /etc/apparmor.d/usr.sbin.nginx     # syntax check only, do not load
$ sudo apparmor_parser -a /etc/apparmor.d/usr.sbin.nginx     # add
$ sudo systemctl reload apparmor                             # reload every profile

# Run a command under a chosen profile without a systemd unit
$ aa-exec -p /usr/bin/metricsd -- /usr/bin/metricsd --config /etc/metricsd/metricsd.yaml
```

### 11.3 Sintaxis de perfil — un perfil completo, de calidad de producción

```
# /etc/apparmor.d/usr.sbin.nginx
abi <abi/3.0>,

include <tunables/global>

@{NGINX_PREFIX}=/usr/share/nginx
@{NGINX_DATA}=/srv/www

profile nginx /usr/sbin/nginx flags=(attach_disconnected,mediate_deleted) {
  include <abstractions/base>
  include <abstractions/nameservice>
  include <abstractions/openssl>
  include <abstractions/ssl_certs>

  # ---- Capabilities: exactly what the master process needs ----------------
  capability net_bind_service,
  capability setuid,
  capability setgid,
  capability dac_override,
  capability chown,

  # ---- Network ------------------------------------------------------------
  network inet  stream,
  network inet6 stream,
  network inet  dgram,
  network inet6 dgram,
  network netlink raw,
  deny network inet  raw,
  deny network packet,

  # ---- Executables --------------------------------------------------------
  /usr/sbin/nginx                       mr,
  /usr/lib/nginx/modules/*.so           mr,

  # ---- Configuration: read-only ------------------------------------------
  /etc/nginx/                           r,
  /etc/nginx/**                         r,
  /etc/ssl/private/nginx-*.key          r,

  # ---- Content ------------------------------------------------------------
  @{NGINX_PREFIX}/**                    r,
  @{NGINX_DATA}/                        r,
  @{NGINX_DATA}/**                      r,
  @{NGINX_DATA}/uploads/**              rw,

  # ---- Runtime state ------------------------------------------------------
  /var/log/nginx/                       r,
  /var/log/nginx/*.log                  w,
  /var/lib/nginx/**                     rw,
  /var/cache/nginx/**                   rwk,
  /run/nginx.pid                        rw,
  /run/nginx/**                         rw,
  owner /tmp/nginx-*                    rw,

  # ---- /proc and /sys: minimum viable -------------------------------------
  @{PROC}/@{pid}/status                 r,
  @{PROC}/sys/kernel/ngroups_max        r,
  @{PROC}/sys/kernel/random/boot_id     r,
  /sys/devices/system/cpu/online        r,

  # ---- Signals and IPC ----------------------------------------------------
  signal (send,receive) peer=nginx,
  signal (receive) peer=unconfined,
  unix (bind,listen,accept,send,receive) type=stream,

  # ---- Child execution: transition, never inherit -------------------------
  /usr/bin/openssl                      Px -> nginx//openssl,
  /bin/dash                             ix,

  # ---- Explicit denials (audited, and they win over any allow) ------------
  deny /etc/shadow                      rwklx,
  deny /etc/gshadow                     rwklx,
  deny /root/**                         rwklx,
  deny /home/**                         rwklx,
  deny @{PROC}/*/mem                    rwklx,
  deny /sys/kernel/security/**          rwklx,
  audit deny /etc/nginx/**              w,

  # ---- Child profile ------------------------------------------------------
  profile openssl /usr/bin/openssl {
    include <abstractions/base>
    include <abstractions/openssl>

    /usr/bin/openssl        mr,
    /etc/ssl/**             r,
    /etc/nginx/**           r,
    owner /tmp/**           rw,
  }
}
```

**Caracteres de permisos de archivo:**

| Char | Significado | Char | Significado |
|---|---|---|---|
| `r` | lectura | `w` | escritura (implica borrar/crear en el directorio) |
| `a` | solo append (mutuamente excluyente con `w`) | `k` | bloqueo de archivos |
| `l` | enlace | `m` | mapear en memoria como ejecutable (`PROT_EXEC`) |
| `ix` | ejecutar, heredar (**i**nherit) el perfil actual | `px` | ejecutar bajo el **p**erfil propio del objetivo (falla si no tiene) |
| `Px` | como `px`, con limpieza del entorno | `cx` | ejecutar bajo un perfil hijo (**c**hild) |
| `ux` | ejecutar sin confinar (**u**nconfined) (peligroso) | `Ux` | `ux` con limpieza del entorno | 
| `Cx` | `cx` con limpieza del entorno | `pix`/`cix` | intentar perfil/hijo, con fallback a heredar |

**Regla práctica:** nunca escribas `ux`. Le entrega al hijo toda la autoridad ambiente y es la vía de escape estándar de AppArmor. `Px` con un perfil hijo apropiado, o `Cx` con un bloque `profile {}` en línea, es la construcción correcta.

Globbing de rutas:

| Patrón | Coincide con |
|---|---|
| `*` | Cualquier carácter **excepto** `/` |
| `**` | Cualquier carácter **incluyendo** `/` (recursivo) |
| `?` | Un carácter excepto `/` |
| `[abc]` / `[a-z]` | Clase de caracteres |
| `{one,two}` | Alternancia |
| Prefijo `owner` | Solo si el fsuid de la tarea coincide con el dueño del archivo |
| `@{VAR}` | Expansión de tunable desde `/etc/apparmor.d/tunables/` |

Disposición de `/etc/apparmor.d/` (el `/etc/apparmor/*` de los objetivos):

```console
$ ls /etc/apparmor.d/
abi/                     local/                   usr.bin.man
abstractions/            lsb_release              usr.sbin.nginx
apache2.d/               nvidia_modprobe          usr.sbin.sshd
disable/                 samba/                   tunables/
force-complain/          sbin.dhclient            
$ ls /etc/apparmor.d/tunables/
alias  apparmorfs  dovecot  etc  global  home  home.d/  kernelvars  multiarch
multiarch.d/  ntpd  proc  run  securityfs  share  sys  xdg-user-dirs  xdg-user-dirs.d/
$ ls /etc/apparmor/
logprof.conf  notify.conf  parser.conf  severity.db  subdomain.conf
```

| Ruta | Propósito |
|---|---|
| `/etc/apparmor.d/<escaped.path>` | Archivos de perfil (cargados en el arranque por `apparmor.service`) |
| `/etc/apparmor.d/abstractions/` | Fragmentos de reglas reutilizables (`base`, `nameservice`, `python`, `ssl_certs`) |
| `/etc/apparmor.d/tunables/` | Definiciones de `@{VARIABLE}` — sobrescribí acá, no en el perfil |
| `/etc/apparmor.d/local/<profile>` | Agregados locales del sitio, incluidos con `include` por los perfiles del proveedor — **el lugar seguro ante actualizaciones para agregar reglas** |
| `/etc/apparmor.d/disable/` | Symlinks a perfiles que no deben cargarse |
| `/etc/apparmor.d/force-complain/` | Symlinks a perfiles forzados a modo complain |
| `/etc/apparmor/parser.conf` | Valores por defecto de `apparmor_parser` (directorio de caché, optimizaciones) |
| `/etc/apparmor/logprof.conf` | Comportamiento de `aa-logprof` y rutas de búsqueda de directorios de perfiles |
| `/etc/apparmor/severity.db` | Ranking de severidad usado por `aa-logprof` al ordenar sugerencias |

### 11.4 Ciclo de desarrollo de perfiles

```console
$ sudo apt install -y apparmor-utils apparmor-profiles apparmor-notify

# 1. Interactive generation while exercising the application
$ sudo aa-genprof /usr/bin/metricsd
Writing updated profile for /usr/bin/metricsd.
Setting /usr/bin/metricsd to complain mode.

Before you begin, you may wish to check if a
profile already exists for the application you
wish to confine. See the following wiki page for
more information:
https://gitlab.com/apparmor/apparmor/wikis/Profiles

Please start the application to be profiled in
another window and exercise its functionality now.
...
Profiling: /usr/bin/metricsd

[(S)can system log for AppArmor events] / (F)inish
S

Reading log entries from /var/log/audit/audit.log.

Profile:  /usr/bin/metricsd
Path:     /etc/metricsd/metricsd.yaml
New Mode: owner r
Severity: 3

 [1 - #include <abstractions/base>]
  2 - owner /etc/metricsd/metricsd.yaml r,
  3 - owner /etc/metricsd/*.yaml r,
  4 - owner /etc/metricsd/** r,

(A)llow / [(D)eny] / (I)gnore / (G)lob / Glob with (E)xtension / (N)ew /
Audi(t) / (O)wner permissions off / Abo(r)t / (F)inish
A

Adding /etc/metricsd/** r, to profile.
...
= Changed Local Profiles =
The following local profiles were changed. Would you like to save them?
 [1 - /usr/bin/metricsd]
(S)ave Changes / Save Selec(t)ed Profile / [(V)iew Changes] / Abo(r)t
S
Writing updated profile for /usr/bin/metricsd.

# 2. Iterate: re-scan the log after more exercise
$ sudo aa-logprof
Reading log entries from /var/log/audit/audit.log.
Updating AppArmor profiles in /etc/apparmor.d.
...

# 3. Promote to enforce, then verify
$ sudo aa-enforce /usr/bin/metricsd
Setting /etc/apparmor.d/usr.bin.metricsd to enforce mode.
$ sudo aa-status | grep -A1 'enforce mode'
```

### 11.5 Leer denegaciones de AppArmor

```console
$ sudo ausearch -m AVC -ts recent -i | grep apparmor
type=AVC msg=audit(08/24/2026 12:07:52.883:2214) : apparmor="DENIED" operation="open"
  profile="/usr/sbin/nginx" name="/srv/secrets/db.pass" pid=4471 comm="nginx"
  requested_mask="r" denied_mask="r" fsuid=33 ouid=0

$ sudo dmesg | grep -i apparmor | tail -3
[ 8712.331245] audit: type=1400 audit(1755993272.883:2214): apparmor="DENIED"
  operation="open" profile="/usr/sbin/nginx" name="/srv/secrets/db.pass" pid=4471
  comm="nginx" requested_mask="r" denied_mask="r" fsuid=33 ouid=0

$ sudo journalctl -k --since "-10m" | grep apparmor=

# Desktop/interactive notifier
$ aa-notify -s 1 -v
Profile: /usr/sbin/nginx
Operation: open
Name: /srv/secrets/db.pass
Denied: r
Logfile: /var/log/audit/audit.log
```

| Campo de AppArmor | Equivalente en SELinux | Significado |
|---|---|---|
| `apparmor="DENIED"` | `avc: denied` | El veredicto |
| `profile=` | `scontext=` | Perfil confinante / contexto del sujeto |
| `name=` | `path=` + `tcontext=` | Objeto — solo ruta, sin etiqueta |
| `requested_mask` / `denied_mask` | `{ perms }` | Bits de permiso solicitados vs rechazados |
| `operation=` | syscall + `tclass` | Nombre grueso de la operación |
| `apparmor="ALLOWED"` | `permissive=1` | Registro de aprendizaje en modo complain |

---

## 12. Smack (Simplified Mandatory Access Control Kernel)

Smack es un LSM MAC basado en etiquetas diseñado para la simplicidad y para embebidos/IoT (es la capa MAC de Tizen y AGL). Las reglas son tripletas: `subject-label object-label access`.

### 12.1 Modelo

- Todo proceso y objeto lleva una única **etiqueta**: una cadena arbitraria de hasta 255 caracteres.
- El acceso se deniega salvo que una regla (o un cortocircuito incorporado) lo permita.
- La etiqueta por defecto para todo lo no etiquetado es `_` (floor).

**Etiquetas incorporadas y sus cortocircuitos:**

| Etiqueta | Nombre | Semántica |
|---|---|---|
| `_` | floor | Todos pueden **leerla** y **ejecutarla**; solo `^`/privilegiados pueden escribir |
| `^` | hat | Puede **leer** todo; no puede escribir nada |
| `*` | star | Cualquiera puede accederla (lectura/escritura) — se usa para `/tmp`, `/dev/null` |
| `?` | huh | Nadie puede accederla salvo mediante reglas explícitas; escritura solo hacia `_` |
| `@` | web | Etiqueta de red sin restricciones (comodín CIPSO) |

**Modos de acceso:** `r` lectura, `w` escritura, `x` ejecución, `a` append, `t` transmute, `l` lock, `b` bring-up. `-` significa "no otorgado" en la forma de ancho fijo.

`t` (transmute) es el rasgo distintivo: un objeto nuevo creado en un directorio transmutante hereda la etiqueta *del directorio* en lugar de la del proceso creador — el mecanismo para los buzones compartidos.

### 12.2 Interfaces y herramientas

```console
$ mount | grep smack
smackfs on /sys/fs/smackfs type smackfs (rw,nosuid,nodev,noexec,relatime)

$ ls /sys/fs/smackfs/
access        change-rule  direct       load          logging      onlycap
access2       cipso        doi          load2         netlabel     ptrace
ambient       cipso2       ipv6host     load-self     nltype       relabel-self
                                        load-self2                 revoke-subject
                                                                   syslog
                                                                   unconfined

$ cat /sys/fs/smackfs/ambient
_
$ cat /proc/self/attr/current
_

# Label a file (smack-utils / libsmack-utils)
$ sudo chsmack -a Web /srv/www/index.html
$ chsmack /srv/www/index.html
/srv/www/index.html access="Web"

$ sudo chsmack -a Metrics -e Metrics -t /var/lib/metricsd
$ chsmack -r /var/lib/metricsd
/var/lib/metricsd access="Metrics" execute="Metrics" transmute="TRUE"

$ getfattr -d -m security /srv/www/index.html
# file: srv/www/index.html
security.SMACK64="Web"
```

| xattr | Significado |
|---|---|
| `security.SMACK64` | La etiqueta de acceso del objeto |
| `security.SMACK64EXEC` | Etiqueta que toma un proceso cuando hace exec de este archivo (transición de dominio) |
| `security.SMACK64MMAP` | Etiqueta requerida para hacer `mmap` de este archivo |
| `security.SMACK64TRANSMUTE` | `TRUE` en un directorio → los hijos nuevos heredan la etiqueta del directorio |
| `security.SMACK64IPIN` / `IPOUT` | Etiquetas aplicadas al tráfico de red entrante/saliente en un socket |

Cargar reglas:

```console
# Rule format:  <subject-label> <object-label> <access-string>
$ cat > /etc/smack/accesses.d/metrics <<'EOF'
Metrics  System   r--
Metrics  Web      r--
Metrics  Metrics  rwxat
Web      Metrics  ---
System   Metrics  rw--
EOF

$ sudo smackload < /etc/smack/accesses.d/metrics
# equivalently:
$ echo -n "Metrics System r" | sudo tee /sys/fs/smackfs/load2

$ sudo cat /sys/fs/smackfs/load2 | grep Metrics
Metrics System rx---
Metrics Web rx---
Metrics Metrics rwxat
System Metrics rw---

# Query a single decision without triggering it
$ echo -n "Metrics System r" | sudo tee /sys/fs/smackfs/access2 >/dev/null
$ sudo cat /sys/fs/smackfs/access2
1                            # 1 = permitted, 0 = denied

# Apply / manage the ruleset at boot
$ sudo smackctl apply
$ sudo smackctl status

# Run a process under a label
$ echo -n "Metrics" | sudo tee /proc/self/attr/current
$ sudo smackenable
```

Las denegaciones de Smack aparecen en el log de auditoría con `lsm=SMACK`:

```
type=AVC msg=audit(1755993901.117:2291): lsm=SMACK fn=smack_inode_permission
  action=denied subject="Web" object="Metrics" requested=r
  pid=5140 comm="nginx" name="state.db" dev="dm-0" ino=1180213
```

### 12.3 Dónde encaja Smack

| | SELinux | AppArmor | Smack |
|---|---|---|---|
| Base de la aplicación | Etiquetas (contexto de 4 campos) | Nombres de ruta | Etiquetas (una sola cadena) |
| Tamaño típico de la política | ~120 000 reglas, ~5 000 tipos | Decenas de reglas por perfil | Decenas a cientos de tripletas |
| Curva de aprendizaje | Empinada | Suave | Suave |
| Expresividad | Muy alta (TE + RBAC + MLS/MCS + constraints) | Media | Baja–media (más etiquetado CIPSO para redes) |
| Aislamiento multi-tenant de binarios idénticos | Nativo (MCS) | Un perfil por instancia | Una etiqueta por tenant (nativo) |
| Etiquetado de red | Etiquetas de par, NetLabel/CIPSO, `secmark` | Reglas `network` gruesas | CIPSO/NetLabel de primera clase |
| Por defecto en | RHEL/Fedora/CentOS Stream, Android | Debian/Ubuntu/SUSE | Tizen, AGL, embebidos |
| Soporte en runtimes de contenedores | Podman, CRI-O, containerd, Docker | Docker, containerd, CRI-O, K8s | Raro |
| Huella de memoria | La mayor | Media | La menor |
| Veredicto | Elegilo para entornos regulados, multi-tenant, hosts de contenedores | Elegilo para llegar rápido al confinamiento en servicios de un solo tenant | Elegilo para embebidos/IoT con un conjunto pequeño y cerrado de sujetos |

Mecanismos complementarios (apilables) — sabé que estos *no* son alternativas a MAC:

| Mecanismo | Qué aplica | Se compone con MAC |
|---|---|---|
| `seccomp-bpf` | Qué syscalls puede emitir un proceso | Sí — eje ortogonal |
| **Landlock** | Sandbox de filesystem/red por proceso, sin privilegios, declarado por la propia aplicación | Sí — se apila como LSM menor |
| **Capabilities** | Subdivisión de root | Sí — MAC puede restringir aún más la clase `capability` |
| **Namespaces / cgroups** | Visibilidad y límites de recursos, no autorización | Sí |
| **IMA/EVM** | Integridad de archivos e integridad de xattrs (protege las etiquetas SELinux de manipulación offline) | Sí — la respuesta correcta a "las etiquetas se pueden editar offline" |

---

## 13. Manual de verificación

### 13.1 Compuerta de preproducción

```bash
#!/usr/bin/env bash
# selinux-gate.sh — fail the pipeline if the host's MAC posture regresses.
set -euo pipefail

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok()   { printf 'OK:   %s\n' "$*"; }

# 1. SELinux enabled and enforcing, both at runtime and in the config file
selinuxenabled || fail "SELinux is not enabled in the kernel"
[[ "$(getenforce)" == "Enforcing" ]] || fail "runtime mode is $(getenforce), expected Enforcing"
grep -qE '^SELINUX=enforcing$' /etc/selinux/config \
  || fail "/etc/selinux/config would not boot into enforcing"
ok "SELinux enforcing at runtime and at boot"

# 2. No permissive domains
if [[ -n "$(semanage permissive -l -n 2>/dev/null | tr -d '[:space:]')" ]]; then
  fail "permissive domains present: $(semanage permissive -l -n | tr '\n' ' ')"
fi
ok "no customised permissive domains"

# 3. No label drift anywhere that matters
drift="$(restorecon -Rn -v /etc /usr /var/www /srv /var/lib 2>/dev/null | wc -l)"
[[ "$drift" -eq 0 ]] || fail "$drift path(s) have contexts that differ from policy"
ok "no file-context drift"

# 4. No denials since boot
denials="$(ausearch -m AVC,USER_AVC,SELINUX_ERR -ts boot 2>/dev/null | grep -c 'denied' || true)"
[[ "$denials" -eq 0 ]] || fail "$denials denial(s) since boot; run: ausearch -m AVC -ts boot -i"
ok "zero denials since boot"

# 5. Every listening service runs in a confined domain
while read -r ctx; do
  [[ "$ctx" == *:unconfined_t:* ]] && fail "a listening process runs unconfined: $ctx"
done < <(ss -ltnpZ | grep -oP 'proc_ctx=\K[^,)]+' | sort -u)
ok "all listening processes are confined"

# 6. Local customisation is captured and reproducible
semanage export -f /dev/stdout | grep -q . \
  && ok "local customisation exported (capture this in configuration management)"
```

### 13.2 Secuencia de triage post-incidente

```console
# 1. Is MAC actually the cause?
$ getenforce
Enforcing
$ sudo setenforce 0 && <retry the failing operation>     # if it now works, MAC is involved
$ sudo setenforce 1                                       # restore IMMEDIATELY

# 2. Make everything visible
$ sudo semodule -DB
$ sudo semanage permissive -a <domain_t>

# 3. Reproduce and collect the full picture
$ sudo ausearch -m AVC,USER_AVC,SELINUX_ERR -ts recent -i | tee /tmp/avc.txt

# 4. Classify: mislabel, boolean, or missing rule
$ grep -oP 'tcontext=\K\S+' /tmp/avc.txt | sort | uniq -c | sort -rn
     11 system_u:object_r:default_t:s0            # <- mislabel; fix labels
      3 system_u:object_r:postgresql_port_t:s0    # <- check booleans
$ audit2why < /tmp/avc.txt

# 5. Apply the narrowest correct remedy, then revert every loosening
$ sudo semanage permissive -d <domain_t>
$ sudo semodule -B
$ sudo setenforce 1

# 6. Prove it
$ sudo ausearch -m AVC -ts recent | grep -c denied
0
```

---

## 14. Referencia de comandos para el examen

| Comando | Propósito | ¿Persistente? |
|---|---|---|
| `getenforce` | Imprimir el modo actual | — |
| `setenforce 0\|1` | Cambiar el modo en tiempo de ejecución | No |
| `selinuxenabled` | Sale con 0 si SELinux está habilitado | — |
| `sestatus [-v] [-b]` | Estado completo, contextos, estado de los booleanos | — |
| `getsebool [-a] <bool>` | Leer el estado de un booleano | — |
| `setsebool [-P] <bool> on\|off` | Fijar un booleano (`-P` = persistente) | Con `-P` |
| `togglesebool <bool>` | Invertir un booleano en tiempo de ejecución | No |
| `restorecon [-Rvn] <path>` | Aplicar los contextos por defecto almacenados | Sí (xattrs) |
| `setfiles [-nrv] <spec> <path>` | Aplicar contextos desde un archivo de especificación indicado | Sí |
| `fixfiles {check\|restore\|relabel\|onboot} [-R pkg]` | Reetiquetado masivo / verificación | Sí |
| `chcon [-Rt type] <path>` | Cambiar el contexto directamente (temporal) | Hasta el reetiquetado |
| `matchpathcon <path>` | Mostrar el contexto por defecto de la política para una ruta (obsoleto → `restorecon -n -v`) | — |
| `semanage {fcontext,port,login,user,boolean,permissive,module,export,import}` | Administrar la configuración de la política | Sí |
| `semodule {-i,-r,-l,-B,-D,-e,-d,-X}` | Administrar módulos de política | Sí |
| `runcon [-u -r -t -l] CMD` | Ejecutar un comando en un contexto | No |
| `newrole -r ROLE [-t TYPE] [-l LEVEL]` | Transición de rol autenticada | Sesión |
| `seinfo [-t -r -b --user -x]` | Estadísticas de la política y consultas de componentes | — |
| `sesearch {-A,-T,-D} [-s -t -c -p -b]` | Consultar reglas de la política | — |
| `apol [policy]` | Análisis gráfico de la política (SETools) | — |
| `seaudit` | Navegador de logs de auditoría de SETools 3 (**eliminado en SETools 4**) | — |
| `audit2why` | Explicar por qué ocurrió una denegación | — |
| `audit2allow [-i F] [-M name] [-R]` | Generar política a partir de denegaciones | — |
| `sealert -a <log>` / `-l <id>` | Análisis de setroubleshoot con remediación | — |
| `ausearch -m AVC -ts recent -i` | Buscar registros de auditoría | — |
| `sepolicy {generate,transition,network,manpage}` | Ayudantes de autoría/análisis de política | — |
| `avcstat [interval]` | Estadísticas de la caché AVC | — |
| `aa-status [--json]` | Estado de perfiles y procesos de AppArmor | — |
| `aa-enforce <profile>` | Poner en modo enforce | Sí |
| `aa-complain <profile>` | Poner en modo complain (aprendizaje) | Sí |
| `aa-disable <profile>` | Descargar y crear symlink en `disable/` | Sí |
| `aa-unconfined [--paranoid]` | Listar procesos de red sin perfil | — |
| `aa-genprof <binary>` | Generación interactiva de perfiles | Sí |
| `aa-logprof` | Actualizar perfiles a partir de eventos registrados | Sí |
| `aa-exec -p <profile> -- CMD` | Ejecutar un comando bajo un perfil | No |
| `apparmor_parser {-r,-R,-a,-Q}` | Cargar / quitar / verificar un perfil | Sí |
| `chsmack [-a L] [-e L] [-t] <path>` | Leer/fijar etiquetas Smack | Sí (xattrs) |
| `smackload` | Cargar reglas Smack en `/sys/fs/smackfs/load2` | No (hasta reaplicar) |
| `smackctl {apply,status}` | Aplicar el conjunto de reglas Smack persistente | Sí |

---

## Referencias

**Certificación**
- LPI — Exam 303 Objectives (303-300, version 3.0.0): https://www.lpi.org/our-certifications/exam-303-objectives/
- LPI — LPIC-3 Security certification overview: https://www.lpi.org/our-certifications/lpic-3-security-overview/

**Kernel y framework LSM**
- Linux Kernel — Linux Security Modules admin guide: https://www.kernel.org/doc/html/latest/admin-guide/LSM/index.html
- Linux Kernel — SELinux: https://www.kernel.org/doc/html/latest/admin-guide/LSM/SELinux.html
- Linux Kernel — AppArmor: https://www.kernel.org/doc/html/latest/admin-guide/LSM/apparmor.html
- Linux Kernel — Smack: https://www.kernel.org/doc/html/latest/admin-guide/LSM/Smack.html
- Linux Kernel — Landlock (userspace API): https://www.kernel.org/doc/html/latest/userspace-api/landlock.html
- Linux Kernel — Kernel parameters (`lsm=`, `selinux=`, `apparmor=`): https://www.kernel.org/doc/html/latest/admin-guide/kernel-parameters.html

**SELinux**
- The SELinux Project: https://selinuxproject.org/page/Main_Page
- SELinux Notebook (el texto de referencia sobre el lenguaje de política y sus internals): https://github.com/SELinuxProject/selinux-notebook
- SELinux userspace tools and libraries: https://github.com/SELinuxProject/selinux
- Reference Policy (refpolicy) source and interface documentation: https://github.com/SELinuxProject/refpolicy
- SETools (`seinfo`, `sesearch`, `apol`, `sediff`): https://github.com/SELinuxProject/setools
- Red Hat Enterprise Linux 9 — Using SELinux: https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/using_selinux/index
- Fedora Documentation — SELinux: https://docs.fedoraproject.org/en-US/quick-docs/selinux-getting-started/
- Gentoo Wiki — SELinux (administración de política neutral respecto de la distribución): https://wiki.gentoo.org/wiki/SELinux
- `man 5 selinux_config`: https://man7.org/linux/man-pages/man5/selinux_config.5.html
- `man 8 semanage`: https://man7.org/linux/man-pages/man8/semanage.8.html
- `man 8 semodule`: https://man7.org/linux/man-pages/man8/semodule.8.html
- `man 8 restorecon`: https://man7.org/linux/man-pages/man8/restorecon.8.html
- `man 8 setfiles`: https://man7.org/linux/man-pages/man8/setfiles.8.html
- `man 8 fixfiles`: https://man7.org/linux/man-pages/man8/fixfiles.8.html
- `man 1 runcon`: https://man7.org/linux/man-pages/man1/runcon.1.html
- `man 1 newrole`: https://man7.org/linux/man-pages/man1/newrole.1.html
- `man 1 audit2allow`: https://man7.org/linux/man-pages/man1/audit2allow.1.html

**AppArmor**
- AppArmor project wiki (índice de documentación): https://gitlab.com/apparmor/apparmor/-/wikis/home
- AppArmor — Documentation and profile language: https://gitlab.com/apparmor/apparmor/-/wikis/Documentation
- AppArmor source repository: https://gitlab.com/apparmor/apparmor
- Ubuntu Server documentation — AppArmor: https://documentation.ubuntu.com/server/how-to/security/apparmor/
- Debian Wiki — AppArmor: https://wiki.debian.org/AppArmor
- `man 8 aa-status`: https://man7.org/linux/man-pages/man8/aa-status.8.html
- `man 8 apparmor_parser`: https://man7.org/linux/man-pages/man8/apparmor_parser.8.html
- `man 5 apparmor.d`: https://man7.org/linux/man-pages/man5/apparmor.d.5.html

**Smack**
- Smack project (documentación del kernel): https://docs.kernel.org/admin-guide/LSM/Smack.html
- Smack userspace utilities (`libsmack`, `chsmack`, `smackload`): https://github.com/smack-team/smack
- Tizen — Security architecture and Smack usage: https://docs.tizen.org/platform/porting/security/

**Subsistema de auditoría**
- Linux Audit userspace (`ausearch`, `aureport`, `auditctl`): https://github.com/linux-audit/audit-userspace
- `man 8 ausearch`: https://man7.org/linux/man-pages/man8/ausearch.8.html
- Red Hat Enterprise Linux 9 — Auditing the system: https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/security_hardening/auditing-the-system_security-hardening

**Contenedores y Kubernetes**
- Kubernetes — Configure a Security Context for a Pod or Container (`seLinuxOptions`): https://kubernetes.io/docs/tasks/configure-pod-container/security-context/
- Kubernetes — Restrict a Container's Access to Resources with AppArmor: https://kubernetes.io/docs/tutorials/security/apparmor/
- Kubernetes — Pod Security Standards: https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Podman — `podman-run(1)`, flags `--security-opt` y `:z`/`:Z` de volumen: https://docs.podman.io/en/latest/markdown/podman-run.1.html
- `container-selinux` policy module: https://github.com/containers/container-selinux
- `udica` — generate SELinux policies for containers: https://github.com/containers/udica

**systemd**
- `man 5 systemd.exec` (`SELinuxContext=`, `AppArmorProfile=`, `SmackProcessLabel=`, `NoNewPrivileges=`): https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html
- `systemd-analyze security`: https://www.freedesktop.org/software/systemd/man/latest/systemd-analyze.html