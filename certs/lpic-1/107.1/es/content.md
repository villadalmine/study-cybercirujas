# LPIC-1 · Tema 107.1 — Gestionar cuentas de usuario y de grupo y los archivos de sistema relacionados

**Examen:** 102-500 · **Peso del objetivo:** 5 (el valor del blueprint del examen; tratá el `0.0` de los metadatos de generación como no definido)
**Archivos clave:** `/etc/passwd`, `/etc/shadow`, `/etc/group`, `/etc/gshadow`, `/etc/skel`, `/etc/login.defs`, `/etc/default/useradd`, `/etc/subuid`, `/etc/subgid`
**Comandos clave:** `useradd`, `usermod`, `userdel`, `groupadd`, `groupmod`, `groupdel`, `passwd`, `gpasswd`, `chage`, `getent`, `id`, `pwck`, `grpck`, `vipw`, `vigr`, `newgrp`, `sg`

---

## 1. Motivación: el problema arquitectónico que este objetivo realmente resuelve

A nivel LPIC-1 este tema se lee como "cómo agregar un usuario". En producción es el **sustrato de identidad contra el que se resuelve cualquier otro mecanismo de control de acceso**. Tres clases de fallo en flotas reales se remontan directamente a él:

### 1.1 El UID es lo único que el kernel conoce

El kernel de Linux no conoce *nombres* de usuario. Conoce una `struct cred` que contiene `uid`, `gid`, `euid`, `egid`, `fsuid`, `fsgid` y un arreglo `group_info` de GIDs suplementarios. Los inodos del sistema de archivos almacenan un UID de 32 bits y un GID de 32 bits — nunca una cadena. `/etc/passwd` es una capa de *presentación* consultada por las bibliotecas de espacio de usuario para representar `1000` como `deploy`.

Consecuencias que vas a encontrar en un incidente:

- Borrar un usuario no desasigna la propiedad de sus archivos. Una cuenta posterior que caiga en el mismo UID hereda silenciosamente todos y cada uno de ellos.
- Una imagen de contenedor cuyo `USER app` mapea al UID 1000, montada sobre un `hostPath` propiedad del UID 1000 del host (`alice`), le da al contenedor acceso completo de escritura a los datos de Alice. El contenedor no tiene idea, y Alice tampoco.
- Un export NFS compartido entre un nodo donde `postgres` es GID 26 (RHEL) y otro donde `postgres` es GID 999 (Debian) produce fallos de permisos que ningún `ls -l` explica, porque `ls -l` te está mintiendo en al menos una de las dos máquinas (`ls -ln` no).

### 1.2 `/etc/passwd` es una fuente NSS entre varias

`getpwnam(3)` no lee `/etc/passwd`. Le pregunta al **Name Service Switch**, que consulta, en orden, los módulos listados en `/etc/nsswitch.conf`. `files` es apenas la primera y más común de las entradas. En un nodo moderno la misma búsqueda puede ser respondida por `sss` (SSSD → LDAP/AD/IPA), `systemd` (`nss-systemd`, que sintetiza identidades de servicios `DynamicUser=` y usuarios de `systemd-homed`), o `ldap`.

Por eso "el usuario no está en `/etc/passwd`, así que no existe" es una inferencia falsa, y por eso `getent passwd` — que pasa por NSS — es la única forma correcta de responder "¿esta cuenta resuelve en este host?".

### 1.3 El desaprovisionamiento es un problema de *autorización*, no de contraseña

El hallazgo de seguridad más común en las revisiones de acceso: un ingeniero dado de baja cuya contraseña fue bloqueada con `passwd -l` pero que todavía tiene una clave SSH funcionando. El bloqueo de contraseña muta el campo del hash en `/etc/shadow`; la autenticación por clave pública nunca consulta ese campo. La palanca correcta es la **expiración de la cuenta**, aplicada por la pila *account* de PAM, por la que todo método de autenticación debe pasar. La sección 5 lo cubre en detalle; también es una distinción favorita del examen.

### 1.4 Arquitectura de un solo `id alice`

```
       id(1) / login(1) / sshd(8)
                 │
                 ▼
      glibc: getpwnam_r(3), getgrouplist(3)
                 │
                 ▼
    /etc/nsswitch.conf   passwd: files systemd sss
                 │
      ┌──────────┼───────────────┬───────────────┐
      ▼          ▼               ▼               ▼
 libnss_files  libnss_systemd  libnss_sss   (nscd/sssd cache)
   /etc/passwd   varlink IPC     UNIX socket
   /etc/group                    /var/lib/sss/pipes/nss
      │
      ▼
  struct passwd { pw_name, pw_uid, pw_gid, pw_dir, pw_shell }
      │
      ▼
  setgroups(2) / setgid(2) / setuid(2)  ← credentials frozen into the process here
      │
      ▼
  kernel struct cred  ← the ONLY thing checked at open(2)/exec(2)
```

La última flecha es la que la gente olvida: las credenciales se copian al proceso en el login y son **inmutables durante la vida de ese proceso**. Agregar un usuario a un grupo no afecta a ninguna shell ya en ejecución, sesión de usuario de systemd, ni demonio de larga duración. Este es el mecanismo detrás de "me agregué a `docker` y me sigue diciendo permission denied".

---

## 2. Las cuatro bases de datos de cuentas, campo por campo

### 2.1 `/etc/passwd` — 7 campos separados por dos puntos

```
$ getent passwd deploy
deploy:x:1001:1001:Deploy Automation,,,,ticket=OPS-4412:/home/deploy:/bin/bash
```

| # | Campo | Contenido | Notas de producción |
|---|---|---|---|
| 1 | `pw_name` | Nombre de login | Conjunto portable POSIX: `[a-z_][a-z0-9_-]*[$]?`. `useradd` rechaza nombres con `.`, mayúsculas o dígitos iniciales salvo `--badname` (shadow ≥ 4.13). La longitud máxima es `UT_NAMESIZE-1` = 31 para que `utmp` sea correcto. |
| 2 | `pw_passwd` | Slot heredado del hash | `x` = "buscá en `/etc/shadow`". Un campo vacío significa **login sin contraseña**. Un hash literal acá significa que el shadowing está desactivado (`pwunconv`) — un hallazgo, no una configuración. |
| 3 | `pw_uid` | UID de 32 bits | `0` = root sólo por convención; *cualquier* cuenta con UID 0 es root. Múltiples entradas con UID 0 son legales y son una puerta trasera clásica. |
| 4 | `pw_gid` | GID primario | Exactamente uno. Se aplica como el `gid` de los archivos nuevos salvo que el directorio padre sea setgid. |
| 5 | `pw_gecos` | Comentario | Subcampos separados por comas: *Nombre completo, Habitación, Teléfono laboral, Teléfono particular, Otro*. Lo escribe `chfn`. Un dos puntos acá corrompe el archivo; una coma trunca silenciosamente lo que muestra `finger`. Útil para etiquetar ticket/responsable. |
| 6 | `pw_dir` | Directorio home | No es obligatorio que exista. Si no existe, `login` te ubica en `/` (o falla, según la configuración de `pam_lastlog`/`pam_mkhomedir`). |
| 7 | `pw_shell` | Shell de login | Vacío ⇒ `/bin/sh`. `/usr/sbin/nologin` y `/bin/false` *no* son equivalentes (§5.3). |

Permisos: `0644 root:root`. Tiene que ser legible por todo el mundo — cada `ls -l` del sistema depende de eso.

### 2.2 `/etc/shadow` — 9 campos

```
# getent shadow deploy
deploy:$y$j9T$Ck2mQ8yUqz1Vd0Xn3Wb4B/$3JqO7pL2mR9sT1uV5wX8yZ0aB3cD6eF9gH2iJ5kL8mN:20692:1:90:14:30:20908:
```

| # | Campo | Nombre | Significado |
|---|---|---|---|
| 1 | `sp_namp` | Nombre de login | Clave de unión con `/etc/passwd`. Una entrada huérfana acá es lo que reporta `pwck`. |
| 2 | `sp_pwdp` | Hash | `$id$[params]$salt$hash`. Prefijos `!`/`*` y centinelas: ver §3. |
| 3 | `sp_lstchg` | Último cambio | **Días desde 1970-01-01**, no una marca de tiempo. `0` = "debe cambiarla en el próximo login". Vacío = envejecimiento desactivado. |
| 4 | `sp_min` | MIN | Días antes de que la contraseña *pueda* volver a cambiarse. Control anticiclado; bloquea el truco de "la cambio 5 veces para recuperar la vieja" cuando se combina con `pam_pwhistory`. |
| 5 | `sp_max` | MAX | Días antes de que la contraseña *deba* cambiarse. |
| 6 | `sp_warn` | WARN | Días de aviso antes del vencimiento MAX. |
| 7 | `sp_inact` | INACTIVE | Días de gracia **posteriores** al vencimiento de la contraseña durante los cuales el login todavía funciona pero fuerza un cambio. Vacío = sin gracia; la cuenta muere en el momento en que la contraseña vence. |
| 8 | `sp_expire` | EXPIRE | Muerte absoluta de la cuenta, en días desde la época. **Independiente de la contraseña.** Este es el campo del offboarding. |
| 9 | — | Reservado | Sin uso. |

Calculá los valores en días de época en vez de adivinarlos:

```
$ date -u -d "2026-08-27" +%s | awk '{print int($1/86400)}'
20692
$ date -u -d "@$((20908*86400))" +%F
2027-03-31
```

Los permisos difieren según la distribución, y ambos son correctos:

```
$ stat -c '%A %U:%G %n' /etc/shadow          # Debian/Ubuntu
-rw-r----- root:shadow /etc/shadow

$ stat -c '%A %U:%G %n' /etc/shadow          # RHEL/Fedora/SUSE
---------- root:root /etc/shadow
```

El modo `0000` no es un error: root evita el DAC vía `CAP_DAC_OVERRIDE`, y el archivo se vuelve ilegible para *todo* lo demás, incluido un proceso comprometido que haya obtenido un conjunto de capacidades sin ser root. Debian, en cambio, otorga lectura al grupo `shadow` para que los ayudantes setgid (`unix_chkpwd`) puedan verificar contraseñas sin ser setuid-root.

### 2.3 `/etc/group` — 4 campos

```
$ getent group platform
platform:x:4200:deploy,alice,bob
```

| # | Campo | Significado |
|---|---|---|
| 1 | Nombre del grupo | |
| 2 | Contraseña | `x` ⇒ `/etc/gshadow`. Usada sólo por `newgrp`/`sg` para permitir que se una alguien que no es miembro. Casi siempre sin definir. |
| 3 | GID | |
| 4 | Lista de miembros | Separada por comas, **sólo miembros suplementarios**. |

**La asimetría crítica:** la pertenencia al grupo *primario* de un usuario vive en el campo 4 de `/etc/passwd` y **no** se repite en el campo 4 de `/etc/group`. Así que esto es normal y completo:

```
$ getent passwd alice
alice:x:1000:1000:Alice Ng:/home/alice:/bin/bash
$ getent group alice
alice:x:1000:                     ← empty member list, yet alice IS in group alice
$ id alice
uid=1000(alice) gid=1000(alice) groups=1000(alice),4200(platform),27(sudo)
```

Cualquier script que determine la pertenencia parseando sólo `/etc/group` está equivocado. Usá `id -nG` o `getent initgroups`.

### 2.4 `/etc/gshadow` — 4 campos

```
# getent gshadow platform
platform:!:alice:deploy,alice,bob
```

Campos: *nombre : contraseña cifrada del grupo : administradores del grupo : miembros*. La lista de administradores (campo 3) es lo que fija `gpasswd -A` — un usuario delegado que puede agregar y quitar miembros con `gpasswd` sin tener root. La lista de miembros la mantiene sincronizada con `/etc/group` el propio `gpasswd`; editar uno a mano y el otro no es exactamente lo que detecta `grpck`. En sistemas sin soporte de gshadow el archivo está ausente y `gpasswd -A` falla.

---

## 3. Hashes de contraseña: formato, algoritmos, centinelas

### 3.1 Modular Crypt Format

```
$y$j9T$Ck2mQ8yUqz1Vd0Xn3Wb4B/$3JqO7pL2mR9sT1uV5wX8yZ0aB3cD6eF9gH2iJ5kL8mN
 │  │            │                              │
 │  │            └── salt                       └── hash
 │  └── algorithm parameters (yescrypt cost)
 └── algorithm id
```

| Prefijo | Algoritmo | Ajustable | Estado | Notas |
|---|---|---|---|---|
| *(ninguno)* | DES-crypt | — | **Roto** | Truncamiento de la contraseña a 8 caracteres, salt de 12 bits. Sólo en fósiles. |
| `$1$` | MD5-crypt | ninguno | **Roto** | 1000 iteraciones fijas. Todavía es el valor por defecto en algunos appliances. |
| `$2a$ $2b$ $2y$` | bcrypt | costo 4–31 | Aceptable | Truncamiento de la entrada a 72 bytes. `$2a$` tiene un bug heredado con caracteres de 8 bits; `$2b$` es la variante corregida. |
| `$5$` | SHA-256-crypt | `rounds=` | Aceptable | 5000 rondas por defecto. Amigable con la GPU. |
| `$6$` | SHA-512-crypt | `rounds=` | **Valor por defecto común** | 5000 rondas por defecto; elevalo con `SHA_CRYPT_MIN_ROUNDS`. Sigue siendo barato en GPUs. |
| `$7$` | scrypt | N, r, p | Bueno | Memory-hard. Poco frecuente como valor por defecto de login. |
| `$y$` | **yescrypt** | clase de costo | **Preferido** | Memory-hard; por defecto en Debian 11+, Fedora 35+, RHEL 9. Requiere libxcrypt. |
| `$gy$` | gost-yescrypt | clase de costo | Regional | Núcleo GOST R 34.11-2012 ruso. |

Fijar el valor por defecto de la flota:

```
# grep -E '^(ENCRYPT_METHOD|SHA_CRYPT|YESCRYPT)' /etc/login.defs
ENCRYPT_METHOD YESCRYPT
YESCRYPT_COST_FACTOR 5
SHA_CRYPT_MIN_ROUNDS 100000
SHA_CRYPT_MAX_ROUNDS 100000
```

Cambiar esto **no re-hashea las contraseñas existentes**. Los hashes se actualizan de forma perezosa en la próxima ejecución de `passwd`. Forzá la migración con un barrido de expiración (§7.4).

### 3.2 Valores centinela en el campo 2 — memorizá esta tabla

| Valor | Significado | Auth por contraseña | Auth por clave pública SSH |
|---|---|---|---|
| `$y$...` | Hash válido | ✅ | ✅ |
| `` (vacío) | **No se requiere contraseña** | ✅ *entra sin contraseña* | ✅ |
| `*` | Sin contraseña válida, nunca tuvo una | ❌ | ✅ |
| `!` | Bloqueada (`usermod -L`, `passwd -l`) | ❌ | ✅ **← la trampa del offboarding** |
| `!!` | Bloqueada, nunca establecida (valor por defecto de `useradd` en RHEL) | ❌ | ✅ |
| `!$y$...` | Bloqueada, hash preservado para desbloquear después | ❌ | ✅ |
| `*LK*` | Bloqueada (herencia de Solaris; algunos appliances) | ❌ | ✅ |

Toda la columna de la derecha es la razón por la que existe §5.3.

---

## 4. Política: `login.defs`, `/etc/default/useradd`, `/etc/skel`

### 4.1 `/etc/login.defs` — el archivo de política de toda la flota

```
# grep -Ev '^\s*(#|$)' /etc/login.defs
MAIL_DIR        /var/spool/mail
UID_MIN                  1000
UID_MAX                 60000
SYS_UID_MIN               201
SYS_UID_MAX               999
SUB_UID_MIN            100000
SUB_UID_MAX         600100000
SUB_UID_COUNT           65536
GID_MIN                  1000
GID_MAX                 60000
SYS_GID_MIN               201
SYS_GID_MAX               999
SUB_GID_MIN            100000
SUB_GID_MAX         600100000
SUB_GID_COUNT           65536
PASS_MAX_DAYS   90
PASS_MIN_DAYS   1
PASS_WARN_AGE   14
ENCRYPT_METHOD YESCRYPT
UMASK           077
HOME_MODE       0700
USERGROUPS_ENAB yes
CREATE_HOME     yes
```

Rangos que importan arquitectónicamente:

| Rango | Propósito | Asignación |
|---|---|---|
| `0` | root | Fijo |
| `1–200` | Cuentas de sistema asignadas estáticamente (`bin`, `daemon`, `mail`, `lp`) | Controlado por la distribución, ABI estable entre hosts |
| `201–999` | Cuentas de sistema asignadas dinámicamente (`SYS_UID_MIN..SYS_UID_MAX`) | `useradd -r` elige de arriba hacia abajo. **Específico del host — nunca asumas que coincide entre nodos.** |
| `1000–60000` | Cuentas humanas/regulares | `useradd` elige de abajo hacia arriba |
| `65534` | `nobody`/`nogroup` | Destino del `root_squash` de NFS |
| `100000–600100000` | Rangos de sub-UID para espacios de nombres de usuario | `/etc/subuid` |

La banda dinámica 201–999 es un peligro real en flotas: `useradd -r postgres` en dos nodos recién instalados puede dar UIDs distintos según el orden de instalación de los paquetes. Cualquier almacenamiento compartido entre esos nodos queda entonces desalineado. **Fijá explícitamente los UIDs de sistema en la gestión de configuración** (§6.3).

`USERGROUPS_ENAB yes` es el esquema de **User Private Group**: cada usuario recibe un grupo homónimo como primario, lo que permite que `UMASK 002` sea seguro para directorios setgid colaborativos. Notá el comportamiento acoplado — con `USERGROUPS_ENAB yes`, `userdel` también elimina el grupo primario del usuario si nadie más lo usa.

`HOME_MODE` (shadow ≥ 4.7) fija directamente los permisos del directorio home; sin él, el modo se deriva de `0777 & ~UMASK`.

### 4.2 `/etc/default/useradd` — los valores por defecto propios de `useradd`

```
$ useradd -D
GROUP=100
HOME=/home
INACTIVE=30
EXPIRE=
SHELL=/bin/bash
SKEL=/etc/skel
CREATE_MAIL_SPOOL=yes
```

Se escribe de forma no interactiva con `-D`:

```
# useradd -D --inactive 30 --shell /bin/bash --base-dir /home
# grep -E '^(INACTIVE|SHELL)' /etc/default/useradd
SHELL=/bin/bash
INACTIVE=30
```

`GROUP=100` (`users`) sólo aplica cuando `USERGROUPS_ENAB` es `no` y no se pasa `-g`.

### 4.3 `/etc/skel`

Se copia al nuevo directorio home en el momento de la creación — **una sola vez**. No es una plantilla que se mantenga sincronizada; editar `/etc/skel/.bashrc` después no cambia nada para los usuarios existentes. Los dotfiles se copian preservando el modo pero cambiando el propietario al nuevo usuario.

```
# ls -la /etc/skel
total 24
drwxr-xr-x   3 root root 4096 Aug 27 09:12 .
drwxr-xr-x 142 root root 8192 Aug 27 09:10 ..
-rw-r--r--   1 root root  220 Mar 31 03:41 .bash_logout
-rw-r--r--   1 root root 3771 Mar 31 03:41 .bashrc
-rw-r--r--   1 root root  807 Mar 31 03:41 .profile
drwx------   2 root root 4096 Aug 27 09:12 .ssh
```

**No** pongas una clave privada ni un `authorized_keys` compartido en `/etc/skel/.ssh` — toda cuenta creada después lo recibe, y rotarlo retroactivamente es imposible.

---

## 5. Referencia de comandos con semántica de producción

### 5.1 Crear cuentas

```
# useradd --uid 4310 \
          --gid platform \
          --groups docker,adm \
          --comment "Deploy Automation,,,,ticket=OPS-4412" \
          --home-dir /srv/deploy \
          --create-home \
          --shell /bin/bash \
          --expiredate 2027-03-31 \
          --inactive 30 \
          deploy

# getent passwd deploy
deploy:x:4310:4200:Deploy Automation,,,,ticket=OPS-4412:/srv/deploy:/bin/bash
# getent shadow deploy
deploy:!:20692:0:99999:7:30:20908:
```

Notá que el hash es `!` — **`useradd` nunca establece una contraseña**. La cuenta existe y no puede autenticarse por contraseña. Establecé una de forma no interactiva:

```
# printf 'deploy:%s\n' "$(openssl rand -base64 24)" | chpasswd
# passwd --expire deploy          # force change at first login (sets sp_lstchg=0)
# getent shadow deploy
deploy:$y$j9T$Ck2mQ8y...$3JqO7pL...:0:0:99999:7:30:20908:
```

Nunca pases una contraseña en texto plano en la línea de comandos (`useradd -p` espera un *hash*, no texto plano — un error muy común y peligroso; `useradd -p hunter2` guarda `hunter2` literalmente como el "hash" y deja la cuenta imposible de usar mientras parece configurada). Tanto `useradd -p` como cualquier argumento en texto plano terminan en el historial de la shell y en `/proc/<pid>/cmdline`, legible por toda la flota durante la vida del proceso.

**Cuentas de sistema:**

```
# useradd --system --uid 480 --gid 480 \
          --home-dir /var/lib/exporter --no-create-home \
          --shell /usr/sbin/nologin \
          --comment "node_exporter service account" node_exporter
```

`--system` implica: asignar desde `SYS_UID_MIN..SYS_UID_MAX`, no crear home, sin envejecimiento de contraseña (`sp_max` vacío) y — crucialmente — la cuenta **nunca expira** por defecto.

### 5.2 Modificar cuentas — la trampa del `-a` y otros disparos al pie

```
# id alice
uid=1000(alice) gid=1000(alice) groups=1000(alice),27(sudo),4200(platform)

# usermod -G docker alice          ### WRONG — replaces the entire supplementary list
# id alice
uid=1000(alice) gid=1000(alice) groups=1000(alice),135(docker)
                                            ↑ sudo and platform silently destroyed

# usermod -aG docker alice         ### CORRECT — append
```

`-a` sólo es válido junto con `-G`. No hay confirmación, ni advertencia, ni deshacer. Este es el incidente de producción de mayor frecuencia dentro de este objetivo.

| Operación | Comando | ¿Toca archivos existentes? |
|---|---|---|
| Cambiar UID | `usermod -u 4311 deploy` | Hace chown automático de los archivos **dentro del directorio home** solamente. Todo lo demás (`/srv`, `/var/log`, NFS) hay que arreglarlo a mano. |
| Cambiar GID primario | `usermod -g newgrp deploy` | Misma regla: sólo el árbol del home. |
| Cambiar el GID de un grupo | `groupmod -g 4201 platform` | **Nada.** Todo archivo con el GID viejo queda huérfano. |
| Renombrar usuario | `usermod -l newname old` | **No** renombra el directorio home, ni el spool de correo, ni el grupo privado del usuario. |
| Mover el home | `usermod -d /srv/new -m deploy` | `-m` mueve el contenido; sin `-m` sólo cambia el campo y el directorio viejo queda ahí. |

Migración correcta de UID, con el barrido de todo el sistema de archivos:

```
# OLD=1001 NEW=4311
# systemctl stop deploy.service
# loginctl terminate-user deploy 2>/dev/null; pkill -KILL -u "$OLD"
# usermod -u "$NEW" deploy
# find / -xdev \( -path /proc -o -path /sys \) -prune -o \
       -uid "$OLD" -print0 | xargs -0 --no-run-if-empty chown -h "$NEW"
# find / -xdev -uid "$OLD" -print | head
# systemctl start deploy.service
```

`-xdev` por sistema de archivos, `-h` para alcanzar los enlaces simbólicos, `-print0`/`-0` para nombres de archivo patológicos.

### 5.3 Deshabilitar el acceso — las cuatro palancas no son intercambiables

| Mecanismo | Comando | Bloquea login por contraseña | Bloquea login por **clave** SSH | Bloquea `su`/`sudo -u` | Reversible | Aplicado por |
|---|---|---|---|---|---|---|
| Bloquear contraseña | `passwd -l u` / `usermod -L u` | ✅ | ❌ | ❌ | `passwd -u` / `usermod -U` | `pam_unix` (auth) |
| Borrar contraseña | `passwd -d u` | ⚠️ **habilita login sin contraseña** | ❌ | ❌ | — | `pam_unix` (auth) |
| **Expirar la cuenta** | `chage -E 0 u` / `usermod -e 1 u` | ✅ | ✅ | ✅ | `chage -E -1 u` | `pam_unix` (**account**) |
| Shell de no-login | `usermod -s /usr/sbin/nologin u` | ⚠️ parcial | ⚠️ parcial | ✅ interactivo | restaurar la shell | exec de `sshd`/`login` |

Demostración de la trampa:

```
# usermod -L bob
# getent shadow bob
bob:!$y$j9T$Xk1...:20655:1:90:14:30::
$ ssh bob@node01
Enter passphrase for key '/home/bob/.ssh/id_ed25519':
bob@node01:~$ id
uid=1002(bob) gid=1002(bob) groups=1002(bob),27(sudo)      ← still in, still sudo
```

La primitiva correcta de offboarding:

```
# chage -E 0 bob
# chage -l bob
Last password change                                    : Jul 21, 2026
Password expires                                        : Oct 19, 2026
Password inactive                                       : Nov 18, 2026
Account expires                                         : Aug 26, 2026
Minimum number of days between password change          : 1
Maximum number of days between password change          : 90
Number of days of warning before password expires       : 14

$ ssh bob@node01
Enter passphrase for key '/home/bob/.ssh/id_ed25519':
Your account has expired; please contact your system administrator
Connection closed by 10.20.0.11 port 22
```

`chage -E 0` significa "expiró el 1970-01-02" (el día 0 es tratado como "sin expiración" por algunas herramientas, de ahí `usermod -e 1` como equivalente inequívoco). La verificación ocurre en la fase **account** de PAM, que se ejecuta después de que *cualquier* método de autenticación tenga éxito — contraseña, clave, GSSAPI, certificado. Por eso es la única palanca completa.

La salvedad de la shell `nologin`: detiene las shells interactivas y `ssh host command`, pero una sesión que nunca necesita una shell sigue funcionando:

```
$ ssh -N -L 8443:127.0.0.1:8443 svcacct@node01     # tunnel established: no shell is exec'd
```

Así que `nologin` es un control de UX/ergonomía para cuentas de servicio, no una frontera de seguridad. Usá `chage -E`, y además vaciá `authorized_keys` y revocá cualquier certificado de la CA SSH.

Runbook completo de offboarding:

```
# U=bob
# chage -E 0 "$U"                                   # 1. authorization revoked (all methods)
# usermod -L "$U"                                   # 2. defence in depth
# gpasswd -d "$U" sudo; gpasswd -d "$U" wheel       # 3. drop privilege groups
# install -m 0600 -o root -g root /dev/null /home/$U/.ssh/authorized_keys   # 4. keys
# loginctl terminate-user "$U"                      # 5. kill live sessions
# pkill -KILL -u "$U"
# crontab -r -u "$U" 2>/dev/null; rm -f /var/spool/cron/atjobs/*"$U"*
# find / -xdev -user "$U" -perm /4000 -o -user "$U" -perm /2000 | tee /tmp/$U-setxid.txt
# last -F "$U" | head                               # 6. evidence for the ticket
```

Borrá la cuenta sólo después de que cierre la ventana de retención de datos (§5.4).

### 5.4 Borrado

```
# userdel deploy                       # entry removed; home and files remain
# userdel -r deploy                    # also removes home dir + mail spool
# userdel -rf deploy                   # -f: proceed even if logged in / home shared
```

`userdel` se niega si el usuario está conectado en ese momento (salvo con `-f`), pero **no** verifica si hay procesos en ejecución no asociados a una sesión, ni archivos fuera del directorio home. Dos pasos posteriores obligatorios:

```
# find / -xdev -nouser -o -xdev -nogroup 2>/dev/null | head -20
/srv/deploy/artifacts/build-4412.tar.gz
/var/log/deploy/agent.log
/var/spool/cron/crontabs/deploy
```

```
# grep -rn '\bdeploy\b' /etc/sudoers /etc/sudoers.d/ /etc/ssh/sshd_config \
       /etc/ssh/sshd_config.d/ /etc/cron.d/ /etc/systemd/system/ 2>/dev/null
/etc/sudoers.d/10-deploy:1:deploy ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart app
/etc/systemd/system/app.service:8:User=deploy
```

Una línea de `sudoers` que referencia a un usuario borrado es inerte *hasta* que se cree una nueva cuenta con ese nombre — momento en el que se convierte en una concesión de privilegios no intencional. Limpiá sudoers en la misma ventana de cambio.

`-f` también fuerza la eliminación del grupo del usuario incluso cuando es el grupo primario de otro usuario, lo que corrompe a ese usuario. Usá `-f` deliberadamente.

### 5.5 Grupos

```
# groupadd --gid 4200 --system platform
# groupmod --new-name platform-eng platform
# gpasswd --add alice platform-eng
Adding user alice to group platform-eng
# gpasswd --delete bob platform-eng
Removing user bob from group platform-eng
# gpasswd --administrators alice platform-eng      # delegate membership control
# gpasswd --members alice,carol,dan platform-eng   # replace member list wholesale
# groupdel platform-eng
groupdel: cannot remove the primary group of user 'svcapp'
```

| Tarea | `usermod` | `gpasswd` |
|---|---|---|
| Agregar un miembro | `usermod -aG grp user` | `gpasswd -a user grp` |
| Quitar un miembro | *(no hay forma directa)* | `gpasswd -d user grp` |
| Reemplazar todos los grupos de un **usuario** | `usermod -G g1,g2 user` | — |
| Reemplazar todos los miembros de un **grupo** | — | `gpasswd -M u1,u2 grp` |
| Requiere root | sí | sí, o ser administrador del grupo |

`gpasswd -d` es la razón por la que vale la pena aprender `gpasswd`: quitarle un solo grupo a un usuario con `usermod` obliga a reconstruir la lista completa de `-G`, que es exactamente cómo ocurre el accidente de §5.2.

**Cambios de grupo y procesos en ejecución:**

```
$ id -nG
alice platform-eng
# gpasswd -a alice docker
$ id -nG                        # ← NSS lookup: shows the NEW state
alice platform-eng docker
$ docker ps
permission denied while trying to connect to the Docker daemon socket
$ id -nG -- < /dev/null; grep ^Groups /proc/$$/status   # ← the process's ACTUAL creds
Groups:	4200
```

`id` sin argumentos en algunas shells vuelve a consultar NSS; `/proc/self/status` muestra la verdad que aplica el kernel. Las soluciones, en orden de preferencia: cerrar sesión y volver a entrar; `loginctl terminate-user alice`; o arrancar un nuevo conjunto de credenciales en el lugar:

```
$ exec newgrp docker           # new shell, docker becomes the PRIMARY group
$ sg docker -c 'docker ps'     # run one command with docker added
```

`newgrp` cambia el GID *primario* de la nueva shell (afectando la propiedad de grupo de los archivos que cree); `sg` ejecuta un único comando. Ninguno puede otorgar un grupo del que el usuario no sea realmente miembro — a menos que el grupo tenga una contraseña en `/etc/gshadow`, que es el único uso que le queda a ese campo.

### 5.6 Envejecimiento con `chage`

```
# chage -m 1 -M 90 -W 14 -I 30 -E 2027-03-31 deploy
# chage -l deploy
Last password change                                    : Aug 27, 2026
Password expires                                        : Nov 25, 2026
Password inactive                                       : Dec 25, 2026
Account expires                                         : Mar 31, 2027
Minimum number of days between password change          : 1
Maximum number of days between password change          : 90
Number of days of warning before password expires       : 14
```

Modelo mental de dos ejes:

```
 password axis:  lstchg ──MIN──┤ may change  ──────MAX─────▶ expired ──INACT──▶ dead
 account  axis:  ─────────────────────────────────────────────────────▶ EXPIRE ▶ dead
                                                             (independent, absolute)
```

- `PASS_MAX_DAYS` en `login.defs` sólo aplica a cuentas creadas *después* de definirlo. Las cuentas existentes conservan sus valores de `/etc/shadow` — de ahí el barrido de §7.4.
- `chage -d 0 user` fuerza un cambio en el próximo login (idéntico a `passwd -e`). Ojo: `chage -d 0` en una cuenta de *servicio* con `nologin` la deja inservible: `sshd` intentará ejecutar el diálogo de cambio de contraseña, fallará y denegará la conexión.
- Los campos de envejecimiento se ignoran por completo cuando la cuenta resuelve vía SSSD/LDAP; aplica la política del propio directorio. Fijar valores con `chage` en un usuario de AD no hace nada, silenciosamente.

### 5.7 `getent` — la única herramienta de consulta correcta

```
$ getent passwd 4310                       # by UID
deploy:x:4310:4200:Deploy Automation,,,,ticket=OPS-4412:/srv/deploy:/bin/bash

$ getent group docker
docker:x:135:alice,deploy

$ getent initgroups alice                  # the authoritative supplementary list
alice 1000 4200 27 135

$ getent -s files passwd deploy            # bypass NSS order, query files only
deploy:x:4310:4200:...

$ getent -s sss passwd svc-ci              # query SSSD only
svc-ci:*:1802400513:1802400513:CI Service:/home/svc-ci:/bin/bash

$ getent passwd | wc -l
64
```

Ese último conteo es una trampa en hosts respaldados por un directorio: **`getent passwd` sin clave no enumera los usuarios de LDAP/AD** salvo que se defina `enumerate = True` en `sssd.conf` (está desactivado por defecto, y por buenas razones — enumerar un dominio de AD con 200 000 usuarios en cada `ls -l` es una caída autoinfligida). Así que un usuario del dominio puede estar plenamente operativo e invisible en `getent passwd`. Consultá siempre por clave.

---

## 6. Infraestructura como código — manifiestos completos

### 6.1 Ansible: rol completo de aprovisionamiento de cuentas y grupos

```yaml
---
# roles/identity/defaults/main.yml
identity_password_policy:
  pass_max_days: 90
  pass_min_days: 1
  pass_warn_age: 14
  encrypt_method: YESCRYPT
  umask: "077"
  home_mode: "0700"

identity_groups:
  - name: platform-eng
    gid: 4200
    system: false
  - name: sre-oncall
    gid: 4201
    system: false
  - name: node_exporter
    gid: 480
    system: true

identity_users:
  - name: alice
    uid: 4001
    comment: "Alice Ng,SRE,+34-600-000-001,,ticket=IDM-1001"
    primary_group: alice
    groups: [platform-eng, sre-oncall, sudo]
    shell: /bin/bash
    home: /home/alice
    create_home: true
    expires_on: ""                 # empty string => never
    ssh_keys:
      - "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB2n+5m7Qy8vT0aXcZ1oL4pW9sR3fH6kJ2dM8gN1bV0c alice@corp"
    state: present

  - name: bob
    uid: 4002
    comment: "Bob Reyes,SRE,,,ticket=IDM-1002"
    primary_group: bob
    groups: [platform-eng]
    shell: /bin/bash
    home: /home/bob
    create_home: true
    expires_on: "2026-08-26"       # offboarded
    ssh_keys: []
    state: present

  - name: node_exporter
    uid: 480
    comment: "Prometheus node_exporter service account"
    primary_group: node_exporter
    groups: []
    shell: /usr/sbin/nologin
    home: /var/lib/node_exporter
    create_home: false
    system: true
    expires_on: ""
    ssh_keys: []
    state: present
```

```yaml
---
# roles/identity/tasks/main.yml
- name: Enforce fleet-wide password and UID policy in /etc/login.defs
  ansible.builtin.lineinfile:
    path: /etc/login.defs
    regexp: "^\\s*{{ item.key }}\\b"
    line: "{{ item.key }}\t{{ item.value }}"
    state: present
    owner: root
    group: root
    mode: "0644"
    validate: "/usr/bin/test -r %s"
  loop:
    - { key: PASS_MAX_DAYS, value: "{{ identity_password_policy.pass_max_days }}" }
    - { key: PASS_MIN_DAYS, value: "{{ identity_password_policy.pass_min_days }}" }
    - { key: PASS_WARN_AGE, value: "{{ identity_password_policy.pass_warn_age }}" }
    - { key: ENCRYPT_METHOD, value: "{{ identity_password_policy.encrypt_method }}" }
    - { key: UMASK, value: "{{ identity_password_policy.umask }}" }
    - { key: HOME_MODE, value: "{{ identity_password_policy.home_mode }}" }
    - { key: USERGROUPS_ENAB, value: "yes" }
  loop_control:
    label: "{{ item.key }}"
  tags: [identity, policy]

- name: Create groups with pinned GIDs
  ansible.builtin.group:
    name: "{{ item.name }}"
    gid: "{{ item.gid }}"
    system: "{{ item.system | default(false) }}"
    state: present
  loop: "{{ identity_groups }}"
  loop_control:
    label: "{{ item.name }} (gid={{ item.gid }})"
  tags: [identity, groups]

- name: Create user private groups with pinned GIDs
  ansible.builtin.group:
    name: "{{ item.primary_group }}"
    gid: "{{ item.uid }}"
    system: "{{ item.system | default(false) }}"
    state: present
  loop: "{{ identity_users }}"
  when:
    - item.state == 'present'
    - item.primary_group == item.name
  loop_control:
    label: "{{ item.primary_group }}"
  tags: [identity, groups]

- name: Create and configure accounts with pinned UIDs
  ansible.builtin.user:
    name: "{{ item.name }}"
    uid: "{{ item.uid }}"
    group: "{{ item.primary_group }}"
    groups: "{{ item.groups | join(',') }}"
    append: false                       # declarative: the manifest is the truth
    comment: "{{ item.comment }}"
    shell: "{{ item.shell }}"
    home: "{{ item.home }}"
    create_home: "{{ item.create_home }}"
    system: "{{ item.system | default(false) }}"
    expires: >-
      {{ (item.expires_on | to_datetime('%Y-%m-%d')).timestamp()
         if item.expires_on | length > 0 else -1 }}
    password_lock: "{{ item.expires_on | length > 0 }}"
    state: "{{ item.state }}"
    remove: false                       # never auto-delete home data
  loop: "{{ identity_users }}"
  loop_control:
    label: "{{ item.name }} (uid={{ item.uid }})"
  tags: [identity, users]

- name: Install authorized_keys declaratively
  ansible.posix.authorized_key:
    user: "{{ item.name }}"
    key: "{{ item.ssh_keys | join('\n') }}"
    exclusive: true                     # removes any key not in the manifest
    manage_dir: true
    state: present
  loop: "{{ identity_users }}"
  when:
    - item.state == 'present'
    - item.create_home | bool
  loop_control:
    label: "{{ item.name }} ({{ item.ssh_keys | length }} keys)"
  tags: [identity, ssh]

- name: Enforce password ageing on existing accounts
  ansible.builtin.command:
    argv:
      - /usr/bin/chage
      - --mindays
      - "{{ identity_password_policy.pass_min_days }}"
      - --maxdays
      - "{{ identity_password_policy.pass_max_days }}"
      - --warndays
      - "{{ identity_password_policy.pass_warn_age }}"
      - "{{ item.name }}"
  loop: "{{ identity_users }}"
  when:
    - item.state == 'present'
    - not (item.system | default(false))
  changed_when: false
  loop_control:
    label: "{{ item.name }}"
  tags: [identity, ageing]

- name: Verify account database consistency
  ansible.builtin.command:
    argv: [/usr/sbin/pwck, --read-only, --quiet]
  register: identity_pwck
  changed_when: false
  failed_when: identity_pwck.rc not in [0, 2]
  tags: [identity, verify]

- name: Verify group database consistency
  ansible.builtin.command:
    argv: [/usr/sbin/grpck, --read-only]
  register: identity_grpck
  changed_when: false
  failed_when: identity_grpck.rc != 0
  tags: [identity, verify]

- name: Assert no unauthorised UID 0 accounts exist
  ansible.builtin.shell:
    cmd: |
      set -o pipefail
      getent passwd | awk -F: '$3 == 0 { print $1 }' | sort
    executable: /bin/bash
  register: identity_uid0
  changed_when: false
  failed_when: identity_uid0.stdout_lines | reject('eq', 'root') | list | length > 0
  tags: [identity, verify]
```

Ejecución y salida:

```
$ ansible-playbook -i inventories/prod site.yml --tags identity --diff

PLAY [nodes] *******************************************************************

TASK [identity : Create groups with pinned GIDs] *******************************
ok: [node01] => (item=platform-eng (gid=4200))
ok: [node01] => (item=sre-oncall (gid=4201))
changed: [node01] => (item=node_exporter (gid=480))

TASK [identity : Create and configure accounts with pinned UIDs] ****************
ok: [node01] => (item=alice (uid=4001))
changed: [node01] => (item=bob (uid=4002))
changed: [node01] => (item=node_exporter (uid=480))

TASK [identity : Install authorized_keys declaratively] ************************
ok: [node01] => (item=alice (1 keys))
changed: [node01] => (item=bob (0 keys))

TASK [identity : Assert no unauthorised UID 0 accounts exist] ******************
ok: [node01]

PLAY RECAP *********************************************************************
node01   : ok=9    changed=4    unreachable=0    failed=0    skipped=1
```

Fijate en `append: false` en la tarea de usuario. Hace que el manifiesto sea autoritativo: un grupo agregado a mano en el nodo se elimina en la próxima convergencia. Ese es el objetivo de la identidad declarativa — pero significa que el comportamiento destructivo de `-G` de §5.2 ahora es una *característica* de la que tenés que estar al tanto.

### 6.2 cloud-init: identidad en el primer arranque para imágenes inmutables

```yaml
#cloud-config
# /var/lib/cloud/seed/nocloud/user-data
users:
  - name: root
    lock_passwd: true

  - name: ops
    uid: 4000
    primary_group: ops
    groups: [adm, systemd-journal, sudo]
    gecos: "Break-glass operator,,,,ticket=IDM-0001"
    shell: /bin/bash
    homedir: /home/ops
    create_groups: true
    lock_passwd: true                  # no password auth; keys only
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    ssh_authorized_keys:
      - "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHq4vN2wS8xY0bR7tK5mL9cP3fJ6dG1nZ4aQ8sW2eU5v ops@bastion"
    ssh_redirect_user: false

  - name: node_exporter
    uid: 480
    primary_group: node_exporter
    gecos: "Prometheus node_exporter"
    shell: /usr/sbin/nologin
    homedir: /var/lib/node_exporter
    system: true
    no_create_home: true
    lock_passwd: true

groups:
  - ops: []
  - platform-eng: [ops]

write_files:
  - path: /etc/login.defs.d/00-fleet-policy.conf
    owner: root:root
    permissions: "0644"
    content: |
      PASS_MAX_DAYS   90
      PASS_MIN_DAYS   1
      PASS_WARN_AGE   14
      ENCRYPT_METHOD  YESCRYPT
      UMASK           077
      HOME_MODE       0700
      SYS_UID_MIN     201
      SYS_UID_MAX     999
      UID_MIN         1000
      UID_MAX         60000

  - path: /etc/subuid
    owner: root:root
    permissions: "0644"
    content: |
      ops:100000:65536

  - path: /etc/subgid
    owner: root:root
    permissions: "0644"
    content: |
      ops:100000:65536

  - path: /etc/sudoers.d/10-platform-eng
    owner: root:root
    permissions: "0440"
    content: |
      %platform-eng ALL=(ALL) PASSWD: /usr/bin/systemctl, /usr/bin/journalctl

ssh_pwauth: false
disable_root: true

runcmd:
  - [ /usr/sbin/pwck,  --read-only, --quiet ]
  - [ /usr/sbin/grpck, --read-only ]
  - [ /usr/bin/getent, passwd, "4000" ]
  - [ /usr/sbin/visudo, -c, -f, /etc/sudoers.d/10-platform-eng ]
```

`lock_passwd: true` es el valor por defecto de cloud-init y produce `!` en `/etc/shadow` — combinado con `ssh_pwauth: false` esto es correcto para flotas de sólo claves, pero recordá §5.3: no es un mecanismo de desaprovisionamiento.

### 6.3 `systemd-sysusers`: cuentas de sistema empaquetadas, idempotentes y declarativas

Los paquetes no deberían ejecutar `useradd` en un script `%post`. `sysusers.d` es el equivalente declarativo, ejecutado por `systemd-sysusers.service` antes de cualquier unidad que necesite la cuenta.

```
# /usr/lib/sysusers.d/node_exporter.conf
#Type Name           ID       GECOS                          Home                    Shell
u     node_exporter  480:480  "Prometheus node_exporter"     /var/lib/node_exporter  /usr/sbin/nologin
g     metrics-read   481      -                              -                       -
m     node_exporter  metrics-read
r     -              60000-60999
```

| Tipo | Significado |
|---|---|
| `u` | Crear usuario (y el grupo correspondiente). `ID` puede ser `uid`, `uid:gid`, `uid:groupname`, o `-` para automático. |
| `g` | Crear sólo el grupo. |
| `m` | Agregar un usuario existente a un grupo existente. |
| `r` | Reservar un rango de UID/GID para que la asignación automática lo saltee. |

```
# systemd-sysusers --dry-run /usr/lib/sysusers.d/node_exporter.conf
Creating group 'node_exporter' with GID 480.
Creating user 'node_exporter' (Prometheus node_exporter) with UID 480 and GID 480.
Creating group 'metrics-read' with GID 481.
Adding user 'node_exporter' to group 'metrics-read'.

# systemd-sysusers
# getent passwd node_exporter
node_exporter:x:480:480:Prometheus node_exporter:/var/lib/node_exporter:/usr/sbin/nologin
```

El archivo es idempotente por construcción: nunca modifica una cuenta que ya existe, así que volver a ejecutarlo después de un cambio manual no pisa la intención del operador — la compensación opuesta a la del `append: false` de Ansible.

### 6.4 Dónde colisiona esto con Kubernetes: el UID como contrato entre fronteras

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: log-shipper
  namespace: observability
spec:
  replicas: 3
  selector:
    matchLabels: { app: log-shipper }
  template:
    metadata:
      labels: { app: log-shipper }
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 480             # MUST equal the host UID that owns /var/log/pods
        runAsGroup: 480
        fsGroup: 481               # kubelet chowns emptyDir/PVC volumes to this GID
        fsGroupChangePolicy: OnRootMismatch
        supplementalGroups: [4]     # host 'adm' — grants read on /var/log on Debian
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: shipper
          image: registry.internal/log-shipper:2.14.0
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: varlog
              mountPath: /var/log
              readOnly: true
            - name: state
              mountPath: /var/lib/shipper
          resources:
            requests: { cpu: 100m, memory: 128Mi }
            limits:   { cpu: 500m, memory: 256Mi }
      volumes:
        - name: varlog
          hostPath:
            path: /var/log
            type: Directory
        - name: state
          emptyDir: {}
```

`runAsUser: 480` es una **afirmación numérica sobre el `/etc/passwd` del host**. El contenedor tiene su propio `/etc/passwd` (a menudo ninguno), y el kernel resuelve `open("/var/log/pods/...")` puramente contra el UID 480 y la lista de GIDs suplementarios. Si las imágenes de nodo las construyen dos pipelines distintos y uno asignó `node_exporter` desde la banda dinámica 201–999 mientras el otro fijó 480, el mismo manifiesto lee logs en la mitad de la flota y recibe `EACCES` en la otra mitad. Precisamente por eso §4.1 insiste en fijar los UIDs de sistema.

`supplementalGroups: [4]` es `adm` en hosts de la familia Debian y no existe en RHEL — otra razón por la que `getent group` en el nodo real es un prerrequisito de despliegue, no un detalle.

### 6.5 Espacios de nombres de usuario: `/etc/subuid` y `/etc/subgid`

```
$ cat /etc/subuid
ops:100000:65536
alice:165536:65536
$ cat /etc/subgid
ops:100000:65536
alice:165536:65536
```

Formato: `owner:first_subordinate_id:count`. Esto delega un rango de IDs *sin privilegios* que el propietario puede mapear dentro de un espacio de nombres de usuario — el mecanismo detrás de Podman rootless y Docker rootless. Dentro del espacio de nombres el proceso es UID 0; afuera, el kernel ve el UID 100000.

```
$ podman unshare cat /proc/self/uid_map
         0       4000          1
         1     100000      65536

$ podman run --rm -it alpine sh -c 'id; touch /tmp/f; stat -c %u /tmp/f'
uid=0(root) gid=0(root) groups=0(root),1(bin),2(daemon),3(sys),4(adm),6(disk),10(wheel),11(floppy),20(dialout),26(tape),27(video)
0

$ podman unshare stat -c '%u %U' ~/.local/share/containers/storage/overlay
0 root
$ stat -c '%u %U' ~/.local/share/containers/storage/overlay
100000 UNKNOWN
```

`usermod --add-subuids 200000-265535 --add-subgids 200000-265535 alice` gestiona estos rangos; `useradd` los asigna automáticamente cuando `SUB_UID_MIN`/`SUB_UID_COUNT` están definidos en `login.defs`. Los rangos no deben solaparse entre usuarios — rangos de subuid solapados significan que dos usuarios "rootless" pueden leer los sistemas de archivos de contenedor del otro, anulando silenciosamente el aislamiento.

---

## 7. Verificación y diagnóstico de fallos

### 7.1 Verificadores de consistencia

```
# pwck --read-only
user 'lp': directory '/var/spool/lpd' does not exist
user 'news': directory '/var/spool/news' does not exist
user 'olduser': no group 4998
pwck: no changes

# echo $?
2
```

Códigos de salida de `pwck`: `0` ok · `1` no puede abrir · `2` **una o más entradas incorrectas** · `3` no puede bloquear · `4` no puede reescribir · `5` no puede ordenar. "directory does not exist" para cuentas de sistema es ruido normal; "no group NNNN" es una referencia colgante real — el GID primario de ese usuario no resuelve a nada, y cada archivo que cree muestra un número pelado.

```
# grpck --read-only
'platform-eng' is a member of the 'ghostuser' group in /etc/gshadow but not in /etc/group
grpck: no changes
# echo $?
2
```

`pwck` y `grpck` también detectan: nombres duplicados, UIDs/GIDs duplicados, cantidades de campos incorrectas, campos UID no numéricos, entradas de `/etc/shadow` sin contraparte en `/etc/passwd`, y viceversa. Ejecutá ambos en CI sobre las imágenes doradas y en el pipeline de convergencia (§6.1).

Convertir entre con y sin shadow:

```
# pwconv     # /etc/passwd  → /etc/shadow   (moves hashes out, writes 'x')
# pwunconv   # /etc/shadow  → /etc/passwd   (DANGEROUS: hashes become world-readable)
# grpconv    # /etc/group   → /etc/gshadow
# grpunconv  # /etc/gshadow → /etc/group
```

### 7.2 Edición segura y el archivo de bloqueo

Nunca abras `/etc/passwd` directamente en un editor. `useradd`, `usermod` y `passwd` toman un bloqueo consultivo vía `/etc/.pwd.lock`; un editor común no lo hace, así que una ejecución de convergencia y tu sesión de `vim` pueden intercalar escrituras y truncar el archivo.

```
# vipw            # edits /etc/passwd  with locking, then offers /etc/shadow
# vipw -s         # edits /etc/shadow  with locking
# vigr            # edits /etc/group   with locking
# vigr -s         # edits /etc/gshadow with locking
```

`vipw` ejecuta una validación al estilo `pwck` al guardar y se niega a instalar un archivo sintácticamente roto. También deja copias de respaldo `/etc/passwd-`, `/etc/shadow-` (modo `0600`) — que son en sí mismas un hallazgo si terminan siendo legibles por todo el mundo:

```
# stat -c '%a %U:%G %n' /etc/shadow /etc/shadow- /etc/gshadow /etc/gshadow-
0 root:root /etc/shadow
0 root:root /etc/shadow-
0 root:root /etc/gshadow
0 root:root /etc/gshadow-
```

### 7.3 Diagnosticar "el usuario no existe"

**Paso 1 — ¿es un problema de NSS o de archivos?**

```
$ getent passwd svc-ci                    # full NSS chain
$ echo $?
2                                          # 2 = key not found

$ getent -s files passwd svc-ci           # files only
$ getent -s sss   passwd svc-ci           # SSSD only
svc-ci:*:1802400513:1802400513:CI Service:/home/svc-ci:/bin/bash
```

Si `-s sss` responde y la consulta sin calificar no, el orden de NSS o el módulo están rotos.

```
$ cat /etc/nsswitch.conf | grep -E '^(passwd|group|shadow)'
passwd:     files systemd sss
group:      files systemd sss
shadow:     files sss
```

**Paso 2 — rastreá las llamadas al sistema reales:**

```
# strace -f -e trace=openat,connect,read -o /tmp/getent.trace getent passwd svc-ci
# grep -E 'nss|sss|passwd' /tmp/getent.trace
openat(AT_FDCWD, "/etc/nsswitch.conf", O_RDONLY|O_CLOEXEC) = 3
openat(AT_FDCWD, "/lib/x86_64-linux-gnu/libnss_files.so.2", O_RDONLY|O_CLOEXEC) = 3
openat(AT_FDCWD, "/etc/passwd", O_RDONLY|O_CLOEXEC) = 3
openat(AT_FDCWD, "/lib/x86_64-linux-gnu/libnss_sss.so.2", O_RDONLY|O_CLOEXEC) = 3
connect(3, {sa_family=AF_UNIX, sun_path="/var/lib/sss/pipes/nss"}, 110) = -1 ENOENT
```

`ENOENT` en el socket de SSSD: el módulo está configurado pero el demonio está caído. `systemctl status sssd`.

**Paso 3 — caché obsoleta.** Tanto `nscd` como `sssd` cachean las búsquedas negativas:

```
# sss_cache -u svc-ci          # invalidate one user
# sss_cache -E                 # invalidate everything
# nscd -i passwd; nscd -i group
# systemctl restart nscd
```

Una entrada de caché negativa es la explicación estándar de "creé la cuenta y sigue diciendo que no existe tal usuario" en un host unido a un directorio.

### 7.4 Catálogo de fallos

| Síntoma | Causa probable | Diagnóstico | Solución |
|---|---|---|---|
| `ls -l` muestra números pelados en vez de nombres | El UID/GID no tiene entrada en NSS | `ls -ln`; `getent passwd <n>` | Restaurar la entrada, o aceptarlo para archivos de un espacio de nombres ajeno |
| El usuario perdió `sudo` tras un cambio de grupo | `usermod -G` sin `-a` | `id -nG user`; `getent group sudo` | `usermod -aG sudo user`; auditar el historial git de la convergencia |
| Una nueva pertenencia a grupo "no se aplica" | Credenciales congeladas en los procesos en ejecución | `grep ^Groups /proc/$$/status` vs `id -nG` | Volver a iniciar sesión, `loginctl terminate-user`, o `exec newgrp` |
| Un usuario bloqueado sigue entrando por SSH | `passwd -l` no afecta la auth por clave | `getent shadow u`; `ls -l ~u/.ssh/authorized_keys` | `chage -E 0 u` + vaciar `authorized_keys` |
| `Your account has expired` para un usuario activo | `sp_expire` en el pasado | `chage -l u` | `chage -E -1 u` |
| `useradd: UID 480 is not unique` | UID ya asignado | `getent passwd 480` | Elegir otro, o `--non-unique` (deliberadamente, rara vez) |
| `useradd: cannot lock /etc/passwd; try again later` | `/etc/.pwd.lock` obsoleto tras un kill | `fuser /etc/.pwd.lock`; `ls -l /etc/*.lock` | Matar al que lo retiene; si no hay ninguno, borrar `/etc/passwd.lock`, `/etc/.pwd.lock` |
| `groupdel: cannot remove the primary group of user 'x'` | El grupo es el `pw_gid` de alguien | `awk -F: -v g=$GID '$4==g{print $1}' /etc/passwd` | Reasignar con `usermod -g` y luego borrar |
| Falta el directorio home tras el login | `CREATE_HOME no` o sin `pam_mkhomedir` | `grep pam_mkhomedir /etc/pam.d/*` | Agregar `session optional pam_mkhomedir.so skel=/etc/skel umask=0077` |
| Archivos tras el borrado con propietario nobody | Inodos huérfanos | `find / -xdev -nouser -o -nogroup` | Cambiar el propietario a una cuenta de archivo o borrar según la política de retención |
| Un usuario nuevo puede leer el home de otro | `HOME_MODE`/`UMASK` demasiado permisivos | `stat -c %a /home/*` | Fijar `HOME_MODE 0700`; `chmod 700` retroactivo |
| `passwd: Authentication token manipulation error` para root | `/etc/shadow` inmutable o FS de sólo lectura | `lsattr /etc/shadow`; `mount | grep ' / '` | `chattr -i /etc/shadow`; remontar rw |
| Cambio de contraseña rechazado: "must wait" | `sp_min` no transcurrido | `chage -l u` | `chage -m 0 u` (temporalmente) |
| La política de envejecimiento no se aplica a cuentas viejas | `login.defs` sólo afecta a cuentas nuevas | Barrido abajo | `chage` por lotes |

Barrido de envejecimiento por lotes para cuentas preexistentes:

```
# getent passwd \
  | awk -F: -v min="$(awk '/^UID_MIN/{print $2}' /etc/login.defs)" \
            -v max="$(awk '/^UID_MAX/{print $2}' /etc/login.defs)" \
        '$3 >= min && $3 <= max && $7 !~ /(nologin|false)$/ { print $1 }' \
  | while read -r u; do
      chage --mindays 1 --maxdays 90 --warndays 14 "$u"
      printf '%-16s %s\n' "$u" "$(chage -l "$u" | awk -F': *' '/Password expires/{print $2}')"
    done
alice            Nov 25, 2026
carol            Nov 25, 2026
deploy           Nov 25, 2026
```

### 7.5 Consultas de auditoría permanentes

```
# --- UID 0 accounts other than root -------------------------------------
$ getent passwd | awk -F: '$3 == 0 && $1 != "root" { print "UID0: " $0 }'

# --- Accounts with an empty password field ------------------------------
# getent shadow | awk -F: '$2 == "" { print "EMPTY-PASSWD: " $1 }'

# --- Duplicate UIDs ------------------------------------------------------
$ getent passwd | cut -d: -f3 | sort -n | uniq -d

# --- Duplicate login names ----------------------------------------------
$ cut -d: -f1 /etc/passwd | sort | uniq -d

# --- Interactive shells among system accounts (UID < 1000) ---------------
$ getent passwd | awk -F: '$3 < 1000 && $7 !~ /(nologin|false|sync)$/ { print $1 " -> " $7 }'
root -> /bin/bash
sync -> /bin/sync

# --- Passwords older than the policy maximum ----------------------------
# today=$(( $(date -u +%s) / 86400 ))
# getent shadow | awk -F: -v t="$today" \
      '$3 != "" && $5 != "" && $5 != 99999 && (t - $3) > $5 { print $1, "overdue by", (t-$3-$5), "days" }'

# --- Accounts with no expiry that are not system accounts ---------------
# join -t: -1 1 -2 1 \
       <(getent passwd | awk -F: '$3>=1000 && $3<60000 {print $1}' | sort) \
       <(getent shadow | awk -F: '$8=="" {print $1}' | sort)

# --- Group membership drift vs the manifest ------------------------------
$ for g in sudo wheel docker platform-eng; do
    printf '%-14s %s\n' "$g" "$(getent group "$g" | cut -d: -f4)"
  done
sudo           alice,ops
wheel
docker         alice,deploy
platform-eng   alice,bob,carol

# --- Who is actually logged in, and from where ---------------------------
$ who -H
NAME     LINE         TIME             COMMENT
alice    pts/0        2026-08-27 09:14 (10.20.4.88)
deploy   pts/1        2026-08-27 09:31 (10.20.0.5)

$ last -F -n 5 alice
alice    pts/0   10.20.4.88   Thu Aug 27 09:14:02 2026   still logged in
alice    pts/2   10.20.4.88   Wed Aug 26 17:02:41 2026 - Wed Aug 26 18:44:12 2026 (01:41)

$ lastb -n 5                    # failed attempts, from /var/log/btmp (root only)
root     ssh:notty  203.0.113.9  Thu Aug 27 04:11:07 2026 - Thu Aug 27 04:11:07 2026 (00:00)

$ lastlog | awk 'NR==1 || $0 !~ /Never logged in/'
Username         Port     From             Latest
root             pts/0    10.20.4.88       Mon Aug 24 08:02:11 +0000 2026
alice            pts/0    10.20.4.88       Thu Aug 27 09:14:02 +0000 2026
```

### 7.6 Límites en la cantidad de grupos — una mina de la era NFS

```
$ getconf NGROUPS_MAX
65536
$ id -G alice | wc -w
17
```

El kernel permite 65 536 grupos suplementarios, pero **NFSv3 con `AUTH_SYS` transmite como máximo 16 GIDs** en la credencial RPC. Un usuario en 17 grupos va a tener uno descartado silenciosamente en cada acceso NFS, produciendo errores de permisos que dependen de qué grupos se envíen. Mitigaciones: mantener a los usuarios por debajo de 16 grupos, habilitar `rpc.mountd --manage-gids` (el servidor busca los grupos localmente en vez de confiar en lo que viene por la red), o pasar a NFSv4 con Kerberos.

---

## 8. Matriz consolidada de comandos

| Tarea | Comando |
|---|---|
| Crear usuario regular con home | `useradd -m -s /bin/bash -c "Name" alice` |
| Crear cuenta de sistema | `useradd -r -s /usr/sbin/nologin -d /var/lib/svc -M svc` |
| Mostrar los valores por defecto de `useradd` | `useradd -D` |
| Cambiar los valores por defecto de `useradd` | `useradd -D -s /bin/bash -f 30` |
| Establecer contraseña interactivamente | `passwd alice` |
| Establecer contraseña desde una tubería | `echo 'alice:S3cr3t' \| chpasswd` |
| Forzar cambio en el próximo login | `passwd -e alice` / `chage -d 0 alice` |
| Bloquear / desbloquear contraseña | `passwd -l alice` / `passwd -u alice` |
| Borrar contraseña (**peligroso**) | `passwd -d alice` |
| Mostrar el estado de la contraseña | `passwd -S alice` |
| Expirar la cuenta | `chage -E 0 alice` / `usermod -e 1 alice` |
| Des-expirar la cuenta | `chage -E -1 alice` |
| Mostrar el envejecimiento | `chage -l alice` |
| Configurar el envejecimiento | `chage -m 1 -M 90 -W 14 -I 30 alice` |
| Agregar grupos suplementarios | `usermod -aG docker,adm alice` |
| Reemplazar los grupos suplementarios | `usermod -G docker alice` |
| Cambiar el grupo primario | `usermod -g platform alice` |
| Cambiar el UID | `usermod -u 4311 alice` |
| Renombrar el login | `usermod -l bob alice` |
| Mover el home | `usermod -d /srv/alice -m alice` |
| Cambiar la shell | `usermod -s /usr/sbin/nologin alice` / `chsh -s ... alice` |
| Cambiar el GECOS | `chfn -f "Alice Ng" -r "Room 4" alice` |
| Borrar usuario | `userdel alice` |
| Borrar usuario + home + correo | `userdel -r alice` |
| Crear grupo | `groupadd -g 4200 platform` |
| Renombrar grupo | `groupmod -n platform-eng platform` |
| Cambiar el GID | `groupmod -g 4201 platform-eng` |
| Borrar grupo | `groupdel platform-eng` |
| Agregar a un grupo | `gpasswd -a alice platform-eng` |
| Quitar de un grupo | `gpasswd -d alice platform-eng` |
| Fijar los miembros del grupo | `gpasswd -M alice,bob platform-eng` |
| Fijar los administradores del grupo | `gpasswd -A alice platform-eng` |
| Mostrar la identidad | `id alice`, `id -nG alice`, `groups alice` |
| Consultar NSS | `getent passwd\|group\|shadow\|gshadow\|initgroups <key>` |
| Cambiar el grupo primario | `newgrp docker` |
| Ejecutar un comando con un grupo | `sg docker -c 'docker ps'` |
| Validar las bases de datos | `pwck`, `grpck` |
| Editar de forma segura | `vipw`, `vipw -s`, `vigr`, `vigr -s` |
| Conversión de shadow | `pwconv`, `pwunconv`, `grpconv`, `grpunconv` |
| Rangos de sub-ID | `usermod --add-subuids 200000-265535 alice` |

---

## 9. Distinciones de examen que conviene sobre-aprender

1. **`useradd` vs `adduser`.** `useradd` es el binario de bajo nivel, cuasi-POSIX, neutral respecto a la distribución, proveniente de shadow-utils, y es lo que evalúa el examen. `adduser` es un envoltorio en Perl de Debian (interactivo, lee `/etc/adduser.conf`); en RHEL es simplemente un enlace simbólico a `useradd`, así que el mismo comando se comporta de forma completamente distinta según la familia. Lo mismo para `groupadd`/`addgroup`, `userdel`/`deluser`.
2. **El campo 2 de `/etc/passwd` = `x`** significa que el shadowing está habilitado. Vacío significa sin contraseña.
3. **El campo 3 de `/etc/shadow` son días desde 1970-01-01**, no segundos ni una cadena de fecha.
4. **El grupo primario de un usuario no aparece en el campo de miembros de `/etc/group`.**
5. **`usermod -aG`** — `-a` sólo con `-G`, y olvidarlo es destructivo.
6. **`chage -E` ≠ `passwd -l`.** Expiración de cuenta vs bloqueo de contraseña; sólo la primera detiene el SSH por clave.
7. **`userdel` sin `-r`** deja el directorio home atrás.
8. **`useradd -p`** toma un *hash*, nunca texto plano.
9. **`gpasswd -d`** es el único comando para quitar a un solo usuario de un grupo.
10. **`getent`, no `cat /etc/passwd`**, es como respondés si una cuenta resuelve.

---

## 10. Referencias

**LPI**
- Exam 101-500 objectives — https://www.lpi.org/our-certifications/exam-101-objectives/
- Exam 102-500 objectives (el Tema 107 vive acá) — https://www.lpi.org/our-certifications/exam-102-objectives/
- LPIC-1 certification overview — https://www.lpi.org/our-certifications/lpic-1-overview/

**shadow-utils (proyecto upstream y páginas de manual)**
- Proyecto — https://github.com/shadow-maint/shadow
- `useradd(8)` — https://man7.org/linux/man-pages/man8/useradd.8.html
- `usermod(8)` — https://man7.org/linux/man-pages/man8/usermod.8.html
- `userdel(8)` — https://man7.org/linux/man-pages/man8/userdel.8.html
- `groupadd(8)` — https://man7.org/linux/man-pages/man8/groupadd.8.html
- `groupmod(8)` — https://man7.org/linux/man-pages/man8/groupmod.8.html
- `groupdel(8)` — https://man7.org/linux/man-pages/man8/groupdel.8.html
- `passwd(1)` — https://man7.org/linux/man-pages/man1/passwd.1.html
- `gpasswd(1)` — https://man7.org/linux/man-pages/man1/gpasswd.1.html
- `chage(1)` — https://man7.org/linux/man-pages/man1/chage.1.html
- `chpasswd(8)` — https://man7.org/linux/man-pages/man8/chpasswd.8.html
- `newgrp(1)` — https://man7.org/linux/man-pages/man1/newgrp.1.html
- `sg(1)` — https://man7.org/linux/man-pages/man1/sg.1.html
- `pwck(8)` — https://man7.org/linux/man-pages/man8/pwck.8.html
- `grpck(8)` — https://man7.org/linux/man-pages/man8/grpck.8.html
- `vipw(8)` / `vigr(8)` — https://man7.org/linux/man-pages/man8/vipw.8.html
- `pwconv(8)` — https://man7.org/linux/man-pages/man8/pwconv.8.html

**Formatos de archivo**
- `passwd(5)` — https://man7.org/linux/man-pages/man5/passwd.5.html
- `shadow(5)` — https://man7.org/linux/man-pages/man5/shadow.5.html
- `group(5)` — https://man7.org/linux/man-pages/man5/group.5.html
- `gshadow(5)` — https://man7.org/linux/man-pages/man5/gshadow.5.html
- `login.defs(5)` — https://man7.org/linux/man-pages/man5/login.defs.5.html
- `subuid(5)` — https://man7.org/linux/man-pages/man5/subuid.5.html
- `subgid(5)` — https://man7.org/linux/man-pages/man5/subgid.5.html
- `nsswitch.conf(5)` — https://man7.org/linux/man-pages/man5/nsswitch.conf.5.html
- `crypt(5)` (Modular Crypt Format, libxcrypt) — https://man7.org/linux/man-pages/man5/crypt.5.html

**Bibliotecas y búsquedas**
- `getent(1)` — https://man7.org/linux/man-pages/man1/getent.1.html
- `getpwnam(3)` — https://man7.org/linux/man-pages/man3/getpwnam.3.html
- `getgrouplist(3)` — https://man7.org/linux/man-pages/man3/getgrouplist.3.html
- `setgroups(2)` — https://man7.org/linux/man-pages/man2/setgroups.2.html
- `credentials(7)` — https://man7.org/linux/man-pages/man7/credentials.7.html
- `user_namespaces(7)` — https://man7.org/linux/man-pages/man7/user_namespaces.7.html
- GNU C Library, *Users and Groups* — https://www.gnu.org/software/libc/manual/html_node/Users-and-Groups.html
- libxcrypt (yescrypt, bcrypt, SHA-crypt) — https://github.com/besser82/libxcrypt

**systemd**
- `sysusers.d(5)` — https://www.freedesktop.org/software/systemd/man/latest/sysusers.d.html
- `systemd-sysusers(8)` — https://www.freedesktop.org/software/systemd/man/latest/systemd-sysusers.html
- Users, Groups, UIDs and GIDs on systemd systems — https://systemd.io/UIDS-GIDS/
- `nss-systemd(8)` — https://www.freedesktop.org/software/systemd/man/latest/nss-systemd.html
- `loginctl(1)` — https://www.freedesktop.org/software/systemd/man/latest/loginctl.html

**PAM**
- Linux-PAM System Administrators' Guide — http://www.linux-pam.org/Linux-PAM-html/Linux-PAM_SAG.html
- `pam_unix(8)` — https://man7.org/linux/man-pages/man8/pam_unix.8.html
- `pam_mkhomedir(8)` — https://man7.org/linux/man-pages/man8/pam_mkhomedir.8.html
- `pam_nologin(8)` — https://man7.org/linux/man-pages/man8/pam_nologin.8.html

**Automatización y plataforma**
- Ansible `ansible.builtin.user` — https://docs.ansible.com/ansible/latest/collections/ansible/builtin/user_module.html
- Ansible `ansible.builtin.group` — https://docs.ansible.com/ansible/latest/collections/ansible/builtin/group_module.html
- Ansible `ansible.posix.authorized_key` — https://docs.ansible.com/ansible/latest/collections/ansible/posix/authorized_key_module.html
- Módulo `users_groups` de cloud-init — https://cloudinit.readthedocs.io/en/latest/reference/modules.html#users-and-groups
- Kubernetes, *Configure a Security Context for a Pod or Container* — https://kubernetes.io/docs/tasks/configure-pod-container/security-context/
- Configuración rootless de Podman (subuid/subgid) — https://github.com/containers/podman/blob/main/docs/tutorials/rootless_tutorial.md
- SSSD `sssd.conf(5)` (incluyendo `enumerate`) — https://man.sssd.io/latest/man/sssd.conf.5.html

**Estándares**
- POSIX.1-2024 (Open Group Base Specifications), *Base Definitions §3, User Database* — https://pubs.opengroup.org/onlinepubs/9799919799/
- Filesystem Hierarchy Standard 3.0 (`/home`, `/etc`, `/var/spool`) — https://refspecs.linuxfoundation.org/FHS_3.0/fhs/index.html