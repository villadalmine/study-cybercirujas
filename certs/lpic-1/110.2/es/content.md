# 110.2 — Configurar la seguridad del host

**Track:** LPIC-1 (Exámenes 101-500 / 102-500, versión 5.0 del temario) · **Tema 110: Seguridad** · **Objetivo 110.2**

**Lo que este objetivo realmente te pide que sepas hacer:** entender cómo se almacenan las credenciales en un host Unix y por qué se las sacó de `/etc/passwd`; encontrar y apagar todos los servicios de red que el host no necesita; y saber qué son los TCP wrappers, cómo se evalúan sus archivos de control de acceso y dónde siguen aplicando.

**Archivos y utilidades dentro del alcance:** `/etc/passwd`, `/etc/shadow`, `/etc/nologin`, `/etc/inittab`, `/etc/init.d/*`, `/etc/xinetd.conf`, `/etc/xinetd.d/*`, unidades `systemd.socket`, `/etc/hosts.allow`, `/etc/hosts.deny`.

---

## 1. Motivación: el host como unidad de radio de impacto

En un equipo de plataforma, la "seguridad del host" no es una checklist que corrés una sola vez en el momento de construir la imagen. Es la propiedad que determina **hasta dónde llega un incidente**. Todo host gestionado en una flota expone exactamente tres clases de superficie, y este objetivo cubre las tres:

| Superficie | Qué obtiene un atacante | Control en este objetivo |
|---|---|---|
| **Credenciales en reposo** | Cracking offline de todas las contraseñas de la máquina; movimiento lateral hacia hosts donde se reutiliza la misma contraseña | Shadow passwords, algoritmo y costo del hash, permisos de archivo, política de envejecimiento |
| **Sockets a la escucha** | Ejecución remota de código o divulgación de información sin ninguna credencial | Inventario de servicios, disable/mask con `systemd`, activación por socket, legado `xinetd`/`inetd`, restricción de la dirección de bind |
| **Admisión de conexiones** | Alcanzabilidad desde redes que no tienen por qué hablar con el daemon | TCP wrappers (`hosts.allow`/`hosts.deny`), y sus reemplazos modernos: `nftables`, `IPAddressAllow=` de `systemd`, ACLs a nivel de aplicación |

### 1.1 Por qué hubo que partir `/etc/passwd`

El Unix original guardaba el hash de la contraseña en el campo 2 de `/etc/passwd`. Ese archivo es **legible por todo el mundo por diseño** — es la base de datos del servicio de nombres. `ls -l`, `ps`, `finger`, `find -user` y toda biblioteca que resuelve un UID a un nombre lo necesitan. Así que cualquier usuario sin privilegios, cualquier script CGI, cualquier daemon de bajo privilegio comprometido podía leer el hash de `root`.

Eso era tolerable cuando probar un hash DES de `crypt(3)` llevaba tiempo real de reloj. Dejó de serlo en el momento en que el hardware de consumo pudo probar miles de millones de candidatos por segundo. El arreglo fue estructural, no algorítmico: **separar el registro público de identidad del secreto**.

```
/etc/passwd   0644 root:root   ← identity: name, UID, GID, GECOS, home, shell
/etc/shadow   0640 root:shadow ← secret: hash, salt, aging metadata
```

La consecuencia de segundo orden es la que importa operativamente: **cualquier cosa que necesite verificar una contraseña ahora necesita privilegio**. Por eso `passwd`, `su`, `chage`, `chsh` y `chfn` son SUID o SGID, por eso `unix_chkpwd` existe como helper separado para PAM, y por eso un bug de "solo lectura" en un daemon corriendo como `nobody` ya no entrega la flota entera.

### 1.2 El modo de falla en producción que esto previene

Una forma concreta de incidente que vas a ver: una aplicación web con un bug de directory traversal sirve `../../../../etc/passwd`. En un host donde nunca se corrió `pwconv`, o donde una tarea mal escrita de gestión de configuración dejó `/etc/shadow` en `0644`, esa única lectura es un volcado completo de credenciales. En un host correctamente configurado arroja una lista de nombres de usuario y shells — útil para reconocimiento, inútil para autenticarse.

La lección es que las shadow passwords no son "un detalle heredado que LPI todavía pregunta". Son la razón por la que una primitiva de lectura no es un bypass de autenticación.

---

## 2. Shadow passwords: mecánica

### 2.1 Disposición de campos de `/etc/passwd`

```
$ getent passwd deploy
deploy:x:1002:1002:Deployment robot,,,:/srv/deploy:/bin/bash
```

| # | Campo | Valor de arriba | Notas |
|---|---|---|---|
| 1 | Nombre de login | `deploy` | Debe ser único; lo que el kernel hace cumplir es el UID, no esto |
| 2 | Marcador de contraseña | `x` | `x` = "mirá en `/etc/shadow`". Un hash literal acá significa que el shadowing está **apagado**. Vacío significa que **no se requiere contraseña** |
| 3 | UID | `1002` | `0` es root por definición — una segunda cuenta con UID 0 es una puerta trasera |
| 4 | GID | `1002` | Grupo primario |
| 5 | GECOS | `Deployment robot,,,` | Separado por comas: nombre completo, oficina, teléfono laboral, teléfono particular |
| 6 | Directorio home | `/srv/deploy` | |
| 7 | Shell de login | `/bin/bash` | `/usr/sbin/nologin` o `/bin/false` para negar el login interactivo |

La `x` del campo 2 es un centinela, no un hash. Si ves `deploy:$6$...:1002:...` estás en un sistema sin shadow y el hash es legible por todos.

### 2.2 Disposición de campos de `/etc/shadow`

```
$ sudo getent shadow deploy
deploy:$y$j9T$Qs4mEo1hK3rV8dLpN2Xa7.$k9tPz0YwR6cM1sB4jHnQx2FvD8LgT5aUeI3oWm7yZs2:20330:1:90:14:30:20575:
```

| # | Campo | Valor | Significado |
|---|---|---|---|
| 1 | Nombre de login | `deploy` | Clave de unión con `/etc/passwd` |
| 2 | Contraseña cifrada | `$y$j9T$...` | Modular Crypt Format — ver §2.3 |
| 3 | Último cambio | `20330` | Días desde 1970-01-01. `0` fuerza un cambio en el próximo login |
| 4 | Edad mínima | `1` | Días antes de que la contraseña pueda cambiarse de nuevo — impide que un usuario vuelva cíclicamente a la contraseña vieja |
| 5 | Edad máxima | `90` | Días hasta el vencimiento |
| 6 | Período de aviso | `14` | Días de aviso antes del vencimiento |
| 7 | Inactividad | `30` | Días de gracia tras el vencimiento antes de que la cuenta se deshabilite |
| 8 | Fecha de expiración | `20575` | Expiración absoluta de la cuenta, en días desde la época. Independiente de la contraseña |
| 9 | Reservado | *(vacío)* | Sin uso |

Convertir los campos de fecha es un paso diagnóstico de rutina:

```
$ date -u -d "1970-01-01 UTC + 20330 days" +%F
2025-08-14
$ date -u -d @$(( 20575 * 86400 )) +%F
2026-04-16
```

### 2.3 El campo de contraseña es un pequeño lenguaje

El campo es Modular Crypt Format: `$<id>$<params>$<salt>$<hash>`. Pero también transporta **estados** que no son hashes en absoluto — y confundirlos es el error operativo más común en esta área.

| Contenido del campo | Estado | Cómo llegó ahí |
|---|---|---|
| `$y$j9T$salt$hash` | Contraseña yescrypt utilizable | `passwd` en Debian 11+/Fedora 35+ |
| `$6$rounds=100000$salt$hash` | Contraseña sha512crypt utilizable | `passwd` con `ENCRYPT_METHOD SHA512` |
| `$2b$12$salt+hash` | Contraseña bcrypt utilizable | `libxcrypt` con `ENCRYPT_METHOD BCRYPT` |
| `!$y$j9T$salt$hash` | **Bloqueada**, hash preservado | `passwd -l` / `usermod -L` — reversible con `-u` |
| `!!` | Nunca se estableció contraseña, bloqueada | Predeterminado de `useradd` en RHEL |
| `!` | Nunca se estableció contraseña, bloqueada | Predeterminado de `useradd` en Debian |
| `*` | Login con contraseña imposible, no "bloqueada" | Cuentas de sistema que traen los paquetes |
| `*LK*`, `*NP*` | Marcadores de bloqueo específicos del proveedor | Herencia de Solaris; se ven en imágenes migradas |
| *(vacío)* | **Login sin contraseña** | Mala configuración o `passwd -d`. Tratalo como un hallazgo |

Identificadores de algoritmo que tenés que reconocer:

| Prefijo | Algoritmo | Estado |
|---|---|---|
| `$1$` | MD5-crypt | Roto. No usar |
| `$2a$`/`$2b$`/`$2y$` | bcrypt | Aceptable; truncamiento de contraseña a 72 bytes |
| `$5$` | sha256crypt | Aceptable; resistencia débil a GPU |
| `$6$` | sha512crypt | Predeterminado de larga data; solo duro en CPU |
| `$7$` | scrypt | Duro en memoria |
| `$y$` | yescrypt | Predeterminado actual en Debian/Fedora; duro en memoria |
| `$gy$` | gost-yescrypt | Variante GOST rusa |
| *(13 caracteres, sin `$`)* | `crypt` DES tradicional | Roto, límite de 8 caracteres. Bandera roja en cualquier auditoría |

**Por qué importa la dureza en memoria a escala de flota:** sha512crypt es duro en CPU pero barato en memoria, así que una GPU con miles de núcleos lo paraleliza casi perfectamente. yescrypt y scrypt obligan a cada intento a reservar un conjunto de trabajo, lo que hunde el throughput de la GPU. En el mismo hardware, pasar de `$6$` a `$y$` normalmente cuesta unos pocos milisegundos extra por login legítimo y reduce la tasa de cracking offline en dos o tres órdenes de magnitud.

### 2.4 La política vive en `/etc/login.defs`

`/etc/login.defs` lo leen las herramientas de shadow-utils (`useradd`, `passwd`, `chage`, `login`). Fija **valores predeterminados para cuentas nuevas**; no cambia retroactivamente las existentes.

```ini
# /etc/login.defs — hardened excerpt

# --- Password hashing -------------------------------------------------
ENCRYPT_METHOD          YESCRYPT
YESCRYPT_COST_FACTOR    7
# Fallback when the platform's libcrypt lacks yescrypt:
#ENCRYPT_METHOD         SHA512
#SHA_CRYPT_MIN_ROUNDS   100000
#SHA_CRYPT_MAX_ROUNDS   200000

# --- Aging defaults for NEW accounts ----------------------------------
PASS_MAX_DAYS   90
PASS_MIN_DAYS   1
PASS_WARN_AGE   14

# --- UID/GID allocation ranges ----------------------------------------
UID_MIN                  1000
UID_MAX                 60000
SYS_UID_MIN               201
SYS_UID_MAX               999
GID_MIN                  1000
GID_MAX                 60000

# --- Home directory and umask -----------------------------------------
UMASK                    077
HOME_MODE                0700
CREATE_HOME              yes

# --- Login hardening ---------------------------------------------------
FAILLOG_ENAB            yes
LOG_UNKFAIL_ENAB        no
LOGIN_RETRIES             3
LOGIN_TIMEOUT            60
DEFAULT_HOME             no
USERGROUPS_ENAB         yes
```

Dos sutilezas que muerden en producción:

- `LOG_UNKFAIL_ENAB yes` escribe el *nombre de usuario tipeado* en el log ante un fallo. Los usuarios que se equivocan y escriben su contraseña en el prompt de login terminan con su contraseña en `journalctl`. Dejalo en `no`.
- `DEFAULT_HOME no` rechaza el login cuando falta el directorio home en lugar de dejar al usuario silenciosamente en `/`. En una flota con homes por NFS, esto convierte un estado silencioso y confuso en una falla clara.

**Aplicar el nuevo algoritmo de hash no es automático.** Cambiar `ENCRYPT_METHOD` solo afecta a las contraseñas establecidas *después* del cambio. Los hashes `$6$` existentes siguen siendo `$6$` hasta que cada usuario corra `passwd`. Forzá la rotación:

```
$ sudo awk -F: '$2 ~ /^\$6\$/ {print $1}' /etc/shadow
alice
bob
deploy
$ sudo chage -d 0 alice
$ sudo chage -l alice | head -3
Last password change                                    : password must be changed
Password expires                                        : password must be changed
Password inactive                                       : password must be changed
```

### 2.5 Herramientas de consistencia y conversión

| Comando | Propósito | Notas |
|---|---|---|
| `pwconv` | Mueve los hashes de `/etc/passwd` → `/etc/shadow` | Idempotente; agrega las entradas de shadow faltantes |
| `pwunconv` | Lo inverso — fusiona los hashes de vuelta en `/etc/passwd` | Destruye los metadatos de envejecimiento. Solo uso diagnóstico |
| `grpconv` / `grpunconv` | El mismo par para `/etc/group` ↔ `/etc/gshadow` | |
| `pwck` | Verifica la integridad de `passwd`/`shadow` | `-r` = solo lectura, lo correcto para cron y CI |
| `grpck` | Verifica la integridad de `group`/`gshadow` | `-r` igualmente |
| `vipw` / `vigr` | Editar bajo un lock | `-s` edita el archivo shadow. Usá **siempre** estos en lugar de un editor pelado |

`vipw` y `vigr` existen porque `passwd`, `useradd` y PAM toman `/etc/.pwd.lock`. Editar `/etc/shadow` directamente con `vim` mientras corre un `useradd` es la forma de obtener un archivo shadow truncado y un host donde nadie puede iniciar sesión.

```
$ sudo pwck -r
user 'ftp': directory '/srv/ftp' does not exist
user 'lp': directory '/var/spool/lpd' does not exist
pwck: no changes
$ echo $?
2
```

El código de salida 2 significa "una o más entradas malas". En CI, tratá el no-cero como fallo de build solo después de poner en lista blanca las cuentas de sistema del proveedor que trae tu imagen base — de lo contrario el chequeo es ruido y se termina deshabilitando, lo cual es peor.

### 2.6 Verificar que el shadowing esté realmente en efecto

```
$ sudo awk -F: 'length($2) > 1 {print "UNSHADOWED: " $1}' /etc/passwd
$ stat -c '%n %a %U:%G' /etc/passwd /etc/shadow /etc/group /etc/gshadow
/etc/passwd 644 root:root
/etc/shadow 640 root:shadow
/etc/group 644 root:root
/etc/gshadow 640 root:shadow
```

Los permisos esperados difieren según la distribución y ambos son correctos:

| Archivo | Debian/Ubuntu | RHEL/Fedora/SUSE |
|---|---|---|
| `/etc/passwd` | `0644 root:root` | `0644 root:root` |
| `/etc/shadow` | `0640 root:shadow` | `0000 root:root` |
| `/etc/group` | `0644 root:root` | `0644 root:root` |
| `/etc/gshadow` | `0640 root:shadow` | `0000 root:root` |

El `0000` de RHEL funciona porque root saltea las comprobaciones de permisos; el helper SGID `unix_chkpwd` es lo que le permite a PAM verificar una contraseña sin abrir el archivo como el usuario llamante. El `0640 root:shadow` de Debian concede lo mismo vía pertenencia al grupo. **Cualquier cosa más permisiva que esto es un hallazgo.** Un `/etc/shadow` en `0644` es una divulgación completa de credenciales a cualquier proceso local.

### 2.7 Dónde ocurre realmente la verificación de la contraseña

Leer `/etc/shadow` es solo el último salto. El camino de resolución es:

```
login / sshd / su
      │
      ├─ NSS  ──> /etc/nsswitch.conf  ──> files | sss | ldap | systemd
      │            (identity: UID, GID, home, shell)
      │
      └─ PAM  ──> /etc/pam.d/<service>
                   auth     pam_unix.so    ──> unix_chkpwd ──> /etc/shadow
                   account  pam_unix.so    ──> aging fields 3–8
                   account  pam_nologin.so ──> /etc/nologin
                   account  pam_access.so  ──> /etc/security/access.conf
```

Esta separación explica una clase de incidentes confusos: `getent passwd alice` tiene éxito (NSS encontró la identidad) mientras que el login falla (PAM rechazó la credencial o el estado de la cuenta). Probá siempre las dos mitades.

```
$ getent passwd alice && echo "identity OK"
alice:x:1001:1001:Alice,,,:/home/alice:/bin/bash
identity OK
$ sudo chage -l alice
Last password change                                    : Aug 14, 2025
Password expires                                        : Nov 12, 2025
Password inactive                                       : Dec 12, 2025
Account expires                                         : never
Minimum number of days between password change          : 1
Maximum number of days between password change          : 90
Number of days of warning before password expires       : 14
```

Con hoy en 2026-08-31, esa contraseña venció y pasó su ventana de inactividad: la cuenta está deshabilitada por envejecimiento aunque nada esté "bloqueado".

```
$ sudo passwd -S alice
alice P 08/14/2025 1 90 14 30
```

El segundo campo es el estado: `P` = contraseña utilizable, `L` = bloqueada, `NP` = sin contraseña.

### 2.8 Bloquear no es una sola cosa

| Objetivo | Comando | Efecto | ¿Detiene las claves SSH? |
|---|---|---|---|
| Bloquear la autenticación por contraseña, conservar el hash | `passwd -l user` / `usermod -L user` | Prefijo `!` en el hash | **No** |
| Restaurar | `passwd -u user` / `usermod -U user` | Quita el `!` | — |
| Borrar la contraseña por completo | `passwd -d user` | Campo vacío — **login sin contraseña** | No |
| Bloquear la shell interactiva | `usermod -s /usr/sbin/nologin user` | La shell rechaza | Detiene shells; **no** `ssh user@host command` ni el reenvío de puertos |
| Deshabilitar la cuenta por completo | `chage -E 0 user` | Campo 8 = 0 → expirada desde la época; el `account` de PAM falla | **Sí** |
| Fijar una fecha de fin | `chage -E 2026-12-31 user` | Expiración absoluta | Sí, después de esa fecha |

**La trampa:** `passwd -l` por sí solo no detiene el SSH por clave. Un contratista al que le bloqueaste la contraseña todavía puede entrar con su clave autorizada. La secuencia completa de baja es:

```
$ sudo usermod -L contractor
$ sudo chage -E 0 contractor
$ sudo usermod -s /usr/sbin/nologin contractor
$ sudo install -m 0000 /dev/null /home/contractor/.ssh/authorized_keys
$ sudo pkill -KILL -u contractor
$ sudo loginctl terminate-user contractor 2>/dev/null || true
```

El paso `pkill`/`loginctl` importa: bloquear una cuenta no hace nada con las sesiones ya abiertas.

---

## 3. Apagar servicios de red

### 3.1 Construí primero el inventario

No podés deshabilitar lo que no enumeraste. La herramienta moderna canónica es `ss`:

```
$ sudo ss -tulpnH
udp   UNCONN 0  0     127.0.0.53%lo:53     0.0.0.0:*  users:(("systemd-resolve",pid=612,fd=14))
udp   UNCONN 0  0           0.0.0.0:68     0.0.0.0:*  users:(("dhclient",pid=901,fd=6))
tcp   LISTEN 0  4096  127.0.0.53%lo:53     0.0.0.0:*  users:(("systemd-resolve",pid=612,fd=15))
tcp   LISTEN 0  128         0.0.0.0:22     0.0.0.0:*  users:(("sshd",pid=1043,fd=3))
tcp   LISTEN 0  128            [::]:22        [::]:*  users:(("sshd",pid=1043,fd=4))
tcp   LISTEN 0  511         0.0.0.0:80      0.0.0.0:* users:(("nginx",pid=1188,fd=6),("nginx",pid=1187,fd=6))
tcp   LISTEN 0  70       127.0.0.1:33060    0.0.0.0:* users:(("mysqld",pid=1402,fd=21))
tcp   LISTEN 0  151      127.0.0.1:3306     0.0.0.0:* users:(("mysqld",pid=1402,fd=23))
tcp   LISTEN 0  4096        0.0.0.0:111     0.0.0.0:* users:(("rpcbind",pid=598,fd=4),("systemd",pid=1,fd=38))
tcp   LISTEN 0  4096           [::]:111       [::]:*  users:(("rpcbind",pid=598,fd=6),("systemd",pid=1,fd=40))
tcp   LISTEN 0  100      127.0.0.1:25       0.0.0.0:* users:(("exim4",pid=1290,fd=3))
```

Flags: `-t` TCP, `-u` UDP, `-l` a la escucha, `-p` proceso, `-n` numérico, `-H` sin encabezado.

Leelo como un auditor:

- `127.0.0.53%lo:53`, `127.0.0.1:3306`, `127.0.0.1:25` — solo loopback, **no alcanzables remotamente**. No son superficie de ataque desde la red.
- `0.0.0.0:22`, `[::]:22` — intencionales.
- `0.0.0.0:80` — intencional para un nodo web.
- `0.0.0.0:111` (`rpcbind`) — **casi nunca intencional.** Es un vector de amplificación UDP/TCP y un prerrequisito de NFS que este host no necesita.

Notá que el socket de `rpcbind` lo sostienen **tanto** `rpcbind` como `systemd` (pid 1). Esa es la firma de la **activación por socket**: `systemd` es dueño del descriptor de archivo a la escucha y lo entrega. Detener `rpcbind.service` no va a cerrar el puerto — `systemd` lo reabre y reinicia el daemon en la próxima conexión. Tenés que deshabilitar `rpcbind.socket`.

Herramientas complementarias:

```
$ sudo lsof -nP -iTCP -sTCP:LISTEN
COMMAND   PID  USER  FD  TYPE DEVICE SIZE/OFF NODE NAME
systemd     1  root  38u  IPv4  18921      0t0  TCP *:111 (LISTEN)
rpcbind   598   _rpc  4u  IPv4  18921      0t0  TCP *:111 (LISTEN)
sshd     1043  root   3u  IPv4  21044      0t0  TCP *:22 (LISTEN)
nginx    1187  root   6u  IPv4  22310      0t0  TCP *:80 (LISTEN)

$ sudo netstat -tulpn        # deprecated; net-tools. Same data, older format
$ systemctl list-sockets --all
LISTEN                          UNIT                        ACTIVATES
/run/dbus/system_bus_socket     dbus.socket                 dbus.service
/run/systemd/journal/stdout     systemd-journald.socket     systemd-journald.service
0.0.0.0:111                     rpcbind.socket              rpcbind.service
[::]:111                        rpcbind.socket              rpcbind.service
```

### 3.2 Socket → proceso → unidad → paquete

La cadena completa de atribución, que es lo que necesitás antes de animarte a deshabilitar cualquier cosa:

```
$ sudo ss -tlpn 'sport = :111'
State  Recv-Q Send-Q Local Address:Port Peer Address:Port Process
LISTEN 0      4096         0.0.0.0:111       0.0.0.0:*     users:(("rpcbind",pid=598,fd=4),("systemd",pid=1,fd=38))

$ systemctl status rpcbind.socket --no-pager
● rpcbind.socket - RPCbind Server Activation Socket
     Loaded: loaded (/lib/systemd/system/rpcbind.socket; enabled; preset: enabled)
     Active: active (running) since Mon 2026-08-31 08:12:04 UTC; 3h 21min ago
   Triggers: ● rpcbind.service
     Listen: /run/rpcbind.sock (Stream)
             0.0.0.0:111 (Stream)
             [::]:111 (Stream)

$ dpkg -S /lib/systemd/system/rpcbind.socket
rpcbind: /lib/systemd/system/rpcbind.socket

$ apt-cache rdepends --installed rpcbind
rpcbind
Reverse Depends:
  nfs-common
```

Ahora sabés: nada salvo `nfs-common` lo quiere, y este host no monta NFS. Es seguro removerlo.

### 3.3 Stop vs disable vs mask — el modelo de tres estados

Esta es la distinción de mayor valor de todo el objetivo.

| Acción | Comando | ¿Corre ahora? | ¿Sobrevive al reinicio? | ¿Puede otra unidad traerlo? | Usar cuando |
|---|---|---|---|---|---|
| **Stop** | `systemctl stop foo.service` | No | **Sí — vuelve** | Sí | Temporal, durante mantenimiento |
| **Disable** | `systemctl disable foo.service` | Sí, sigue corriendo | Sin autoarranque | **Sí** — un `Wants=`/`Requires=` de otra unidad igual lo arranca | "Apagar esto" normal |
| **Disable + stop** | `systemctl disable --now foo.service` | No | Sin autoarranque | Sí | La acción correcta habitual |
| **Mask** | `systemctl mask foo.service` | Solo si ya estaba arriba | No puede arrancar en absoluto | **No** — enlazado simbólicamente a `/dev/null` | Nunca debe correr, ni siquiera como dependencia |
| **Mask + stop** | `systemctl mask --now foo.service` | No | No puede arrancar en absoluto | No | Garantía dura |
| **Remove** | `apt purge` / `dnf remove` | No | Desaparecido | No | Lo mejor de todo — código que no está en disco no puede explotarse |

La falla que todos cometen una vez:

```
$ sudo systemctl disable --now rpcbind.service
Removed "/etc/systemd/system/multi-user.target.wants/rpcbind.service".
$ sudo ss -tlpn 'sport = :111'
State  Recv-Q Send-Q Local Address:Port Peer Address:Port Process
LISTEN 0      4096         0.0.0.0:111       0.0.0.0:*     users:(("systemd",pid=1,fd=38))
```

El puerto sigue abierto. `systemd` sostiene el socket y va a lanzar `rpcbind` en la primera conexión. El servicio fue deshabilitado; el **socket** no.

```
$ sudo systemctl disable --now rpcbind.socket rpcbind.service
Removed "/etc/systemd/system/sockets.target.wants/rpcbind.socket".
$ sudo ss -tlpn 'sport = :111'
$ echo "port 111 closed: $?"
port 111 closed: 1
```

Para un servicio activado por socket, **operá siempre sobre la unidad `.socket` y la unidad `.service` juntas.**

Verificar un mask:

```
$ sudo systemctl mask --now rpcbind.socket rpcbind.service
Created symlink /etc/systemd/system/rpcbind.socket → /dev/null.
Created symlink /etc/systemd/system/rpcbind.service → /dev/null.
$ sudo systemctl start rpcbind.service
Failed to start rpcbind.service: Unit rpcbind.service is masked.
$ systemctl list-unit-files --state=masked
UNIT FILE        STATE  PRESET
rpcbind.service  masked enabled
rpcbind.socket   masked enabled
2 unit files listed.
```

Enumerar todo lo habilitado, que es tu superficie real de cambio:

```
$ systemctl list-unit-files --type=service --state=enabled --no-pager
UNIT FILE                   STATE   PRESET
cron.service                enabled enabled
dbus.service                static  -
nginx.service               enabled enabled
ssh.service                 enabled enabled
systemd-journald.service    static  -
systemd-timesyncd.service   enabled enabled
unattended-upgrades.service enabled enabled
```

### 3.4 Restringí la dirección de bind en lugar de remover

Con frecuencia el servicio se necesita pero no debe ser alcanzable desde la red. Ligarlo a loopback es más fuerte que cualquier regla de firewall, porque lo hace cumplir la capa de sockets del kernel y no puede eludirse con un flush del firewall.

| Servicio | Directiva | Valor |
|---|---|---|
| OpenSSH | `ListenAddress` | `10.20.0.15` (solo la interfaz de gestión) |
| MySQL/MariaDB | `bind-address` | `127.0.0.1` |
| PostgreSQL | `listen_addresses` | `'localhost'` |
| Redis | `bind` | `127.0.0.1 -::1` |
| nginx | `listen` | `127.0.0.1:8080` |
| Exim/Postfix | `dc_local_interfaces` / `inet_interfaces` | `127.0.0.1 ; ::1` / `loopback-only` |

`systemd` puede imponer esto desde afuera, independientemente de la configuración propia del daemon:

```ini
# /etc/systemd/system/redis-server.service.d/10-network-lockdown.conf
[Service]
IPAddressDeny=any
IPAddressAllow=localhost
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
PrivateNetwork=no
```

```
$ sudo systemctl daemon-reload && sudo systemctl restart redis-server
$ systemd-analyze security redis-server.service | tail -5
→ Overall exposure level for redis-server.service: 3.4 OK 🙂
```

`IPAddressDeny=` está implementado con filtros de socket eBPF por cgroup. Se aplica al proceso sin importar lo que diga su archivo de configuración — útil cuando el daemon lo configura un paquete que no controlás.

### 3.5 Las capas heredadas que todavía tenés que reconocer

#### SysV init y `/etc/inittab`

En un sistema `sysvinit` puro, `/etc/inittab` fija el runlevel predeterminado y las acciones por runlevel:

```
# /etc/inittab (sysvinit)
id:3:initdefault:

si::sysinit:/etc/init.d/rcS

l0:0:wait:/etc/init.d/rc 0
l1:1:wait:/etc/init.d/rc 1
l2:2:wait:/etc/init.d/rc 2
l3:3:wait:/etc/init.d/rc 3
l5:5:wait:/etc/init.d/rc 5
l6:6:wait:/etc/init.d/rc 6

ca:12345:ctrlaltdel:/sbin/shutdown -t1 -a -r now

1:2345:respawn:/sbin/getty 38400 tty1
2:23:respawn:/sbin/getty 38400 tty2
```

Formato de línea: `id:runlevels:action:process`. Poner `id:3:initdefault:` arranca en modo texto multiusuario; `id:5:` arranca en modo gráfico. Un paso clásico de endurecimiento era remover la línea `ctrlaltdel` para que una combinación de teclas en la consola no pudiera reiniciar un servidor.

Habilitar y deshabilitar los scripts de arranque por runlevel:

```
$ sudo update-rc.d rsync defaults        # Debian: create symlinks
$ sudo update-rc.d rsync disable         # Debian: switch S→K links
$ sudo chkconfig --list sshd             # RHEL 6
sshd  0:off  1:off  2:on  3:on  4:on  5:on  6:off
$ sudo chkconfig sshd off                # RHEL 6
$ ls /etc/rc3.d/
K01rsync  S01cron  S01ssh  S02nginx
```

`S` = start, `K` = kill, el número es el orden. `/etc/init.d/<name> {start|stop|status|restart}` es la interfaz directa.

Bajo `systemd` todo esto es una capa de compatibilidad: `systemd-sysv-generator` sintetiza una unidad a partir de cada script de `/etc/init.d/`, y los runlevels son alias de targets.

| Runlevel | Target de systemd | Significado |
|---|---|---|
| 0 | `poweroff.target` | Apagado |
| 1 / S | `rescue.target` | Monousuario |
| 2, 3, 4 | `multi-user.target` | Multiusuario, sin GUI |
| 5 | `graphical.target` | Multiusuario + GUI |
| 6 | `reboot.target` | Reinicio |

```
$ systemctl get-default
multi-user.target
$ sudo systemctl set-default multi-user.target
Removed "/etc/systemd/system/default.target".
Created symlink /etc/systemd/system/default.target → /lib/systemd/system/multi-user.target.
$ runlevel
N 5
```

#### `inetd` / `xinetd`

El modelo de superservidor: un daemon escucha en muchos puertos y bifurca el servicio real bajo demanda. Esto ahorraba memoria en 1990 y es el ancestro directo de la activación por socket de `systemd`.

El `/etc/inetd.conf` de `inetd`, una línea por servicio:

```
# service  socket  proto  wait/nowait  user   server           args
ftp        stream  tcp    nowait       root   /usr/sbin/tcpd   in.ftpd -l -a
telnet     stream  tcp    nowait       root   /usr/sbin/tcpd   in.telnetd
```

Notá `/usr/sbin/tcpd` en la columna del servidor — eso son los TCP wrappers insertándose como una capa intermedia (§4). Deshabilitar un servicio significa comentar la línea y recargar `inetd`.

`xinetd` lo reemplazó con una configuración estructurada:

```
# /etc/xinetd.conf
defaults
{
        instances               = 60
        log_type                = SYSLOG authpriv
        log_on_success          = HOST PID DURATION
        log_on_failure          = HOST ATTEMPT
        cps                     = 25 30
        per_source              = 10
        v6only                  = no
        groups                  = yes
        umask                   = 022
}

includedir /etc/xinetd.d
```

Una definición de servicio completa, con forma de producción:

```
# /etc/xinetd.d/rsync
service rsync
{
        disable         = no
        flags           = IPv6
        socket_type     = stream
        wait            = no
        user            = root
        server          = /usr/bin/rsync
        server_args     = --daemon --config=/etc/rsyncd.conf
        log_on_failure  += USERID
        log_on_success  += USERID EXIT

        # --- access control -------------------------------------------
        only_from       = 10.20.0.0/24 192.0.2.7
        no_access       = 10.20.0.99
        access_times    = 06:00-22:00

        # --- resource limits ------------------------------------------
        instances       = 20
        per_source      = 4
        cps             = 10 30
        rlimit_as       = 256M
        rlimit_cpu      = 30

        # --- binding ---------------------------------------------------
        bind            = 10.20.0.15
        nice            = 10
}
```

| Atributo | Significado |
|---|---|
| `disable` | `yes` apaga el servicio. **Esta es la respuesta del examen** para apagar un servicio de `xinetd` |
| `socket_type` | `stream` (TCP), `dgram` (UDP), `raw` |
| `wait` | `no` = multihilo, `xinetd` sigue escuchando (típico de `stream`); `yes` = un solo hilo, el servidor toma el socket (típico de `dgram`) |
| `user` / `group` | Identidad con la que corre el servidor |
| `server` / `server_args` | Binario y sus argumentos |
| `only_from` | Lista de permitidos — IPs, CIDR, nombres de host, `0.0.0.0/0` |
| `no_access` | Lista de denegados. **Gana la coincidencia más específica** entre las dos, no la primera |
| `access_times` | Ventana horaria del día |
| `instances` | Tope global de concurrencia |
| `per_source` | Tope de concurrencia por IP de cliente |
| `cps` | Límite de tasa: `<conexiones-por-segundo> <segundos-a-dormir-al-excederse>` |
| `bind` / `interface` | Ligar a una sola dirección en lugar de todas |
| `redirect` | Proxy hacia otro host:puerto |
| `flags` | `REUSE`, `IPv4`, `IPv6`, `NAMEINARGS` (requerido cuando `server = /usr/sbin/tcpd`) |

```
$ sudo sed -i 's/^\(\s*disable\s*=\s*\).*/\1yes/' /etc/xinetd.d/rsync
$ sudo systemctl reload xinetd
$ sudo grep -H disable /etc/xinetd.d/*
/etc/xinetd.d/chargen:  disable = yes
/etc/xinetd.d/daytime:  disable = yes
/etc/xinetd.d/echo:     disable = yes
/etc/xinetd.d/rsync:    disable = yes
```

En sistemas de la familia RHEL, `chkconfig` edita la línea `disable` por vos:

```
$ sudo chkconfig rsync off
$ sudo chkconfig --list | sed -n '/xinetd based/,$p'
xinetd based services:
        chargen-dgram:  off
        chargen-stream: off
        rsync:          off
```

**Estado:** `xinetd` es legado. Sigue empaquetado en Debian; en RHEL 8 y posteriores no está en los repositorios base. No despliegues servicios nuevos sobre él — pero tenés que poder leerlo y deshabilitarlo en hosts heredados, y LPI lo evalúa.

#### Activación por socket de `systemd` — el equivalente moderno

Dos modos, y la diferencia es lo más útil de entender acá.

**`Accept=no`** (el predeterminado, y la elección correcta): `systemd` abre el socket a la escucha, arranca el servicio **una sola vez** y le pasa el descriptor de archivo a la escucha. El daemon hace su propio bucle de `accept()`. Entorno: `LISTEN_FDS`, `LISTEN_PID`, `LISTEN_FDNAMES`; el primer fd es el número 3.

**`Accept=yes`** (compatibilidad con inetd): `systemd` hace el `accept()` él mismo y arranca **una instancia de una unidad de plantilla por conexión**, con el socket conectado en stdin/stdout. Simple, y caro bajo carga.

Par completo y desplegable — un servicio por conexión con una lista dura de permitidos de red:

```ini
# /etc/systemd/system/metrics-collector.socket
[Unit]
Description=Metrics collector socket (per-connection)
Documentation=man:systemd.socket(5)
PartOf=metrics-collector.service

[Socket]
ListenStream=10.20.0.15:9110
Accept=yes
MaxConnections=64
MaxConnectionsPerSource=4
Backlog=128
NoDelay=yes
KeepAlive=yes
SocketUser=root
SocketGroup=root
SocketMode=0660
IPAddressDeny=any
IPAddressAllow=10.20.0.0/24
IPAddressAllow=localhost

[Install]
WantedBy=sockets.target
```

```ini
# /etc/systemd/system/metrics-collector@.service
[Unit]
Description=Metrics collector connection %i
Documentation=man:systemd.exec(5)
Requires=metrics-collector.socket
After=metrics-collector.socket

[Service]
Type=oneshot
ExecStart=/usr/local/libexec/metrics-collector
StandardInput=socket
StandardOutput=socket
StandardError=journal

User=metrics
Group=metrics
DynamicUser=no

# --- sandboxing -------------------------------------------------------
NoNewPrivileges=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
ProtectProc=invisible
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictNamespaces=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallFilter=~@privileged @resources @obsolete
CapabilityBoundingSet=
AmbientCapabilities=
UMask=0077

# --- resource limits --------------------------------------------------
LimitNOFILE=256
LimitNPROC=32
MemoryMax=128M
TasksMax=16
TimeoutStartSec=30s
```

```
$ sudo systemctl daemon-reload
$ sudo systemctl enable --now metrics-collector.socket
Created symlink /etc/systemd/system/sockets.target.wants/metrics-collector.socket → /etc/systemd/system/metrics-collector.socket.
$ systemctl list-sockets --no-pager | grep metrics
10.20.0.15:9110   metrics-collector.socket   metrics-collector@.service

$ systemd-analyze security metrics-collector@.service | tail -3
→ Overall exposure level for metrics-collector@.service: 1.2 OK 🙂
```

Probar la lista de permitidos desde un origen denegado:

```
$ ssh jump-box 'timeout 3 nc -vz 10.20.0.15 9110'    # 10.30.0.4 — outside the allow-list
nc: connect to 10.20.0.15 port 9110 (tcp) failed: Connection timed out
$ sudo journalctl -u metrics-collector.socket -n 5 --no-pager
Aug 31 11:42:03 web01 systemd[1]: metrics-collector.socket: Refused new connection from 10.30.0.4:51422 (IP address deny list).
```

Podés prototipar la activación por socket sin escribir ninguna unidad:

```
$ sudo systemd-socket-activate -l 9110 --inetd /usr/local/libexec/metrics-collector
Listening on [::]:9110 as 3.
Communication attempt on fd 3.
Spawned /usr/local/libexec/metrics-collector (metrics-collector) as PID 20431.
```

### 3.6 Tabla comparativa: las cuatro generaciones

| | `inetd` | `xinetd` | SysV `/etc/init.d` | Unidades socket de `systemd` |
|---|---|---|---|---|
| Configuración | `/etc/inetd.conf`, una línea | Bloques en `/etc/xinetd.d/<svc>` | Scripts de shell + enlaces simbólicos `rcN.d` | INI de `.socket` + `.service` |
| Modelo | Un proceso por conexión | Un proceso por conexión | Un daemon de larga vida | Cualquiera de los dos modos (`Accept=`) |
| Deshabilitar | Comentar la línea, recargar | `disable = yes`, recargar | `update-rc.d`/`chkconfig` off | `systemctl disable --now` |
| Garantía de no-puede-correr | Quitar la línea | Quitar el archivo | Quitar el script | `systemctl mask` |
| Control de acceso | vía el wrapper `tcpd` | `only_from`, `no_access`, `access_times` | Ninguno (el propio del daemon) | `IPAddressAllow/Deny` (eBPF) |
| Límite de tasa | Ninguno | `cps`, `per_source`, `instances` | Ninguno | `MaxConnections`, `MaxConnectionsPerSource`, `StartLimitBurst` |
| Sandboxing | Ninguno | `rlimit_*`, `nice`, `umask` | Ninguno | Conjunto completo de namespaces/seccomp/capabilities |
| Arranque en paralelo | N/A | N/A | Secuencial, ordenado por número | Paralelo; los sockets se abren antes de que arranquen los daemons |
| Logging | syslog | syslog, `log_on_success/failure` | Lo que haga el script | `journald`, estructurado, por unidad |
| Estado | Obsoleto | Legado; no está en la base de RHEL 8+ | Solo capa de compatibilidad | Actual |

**Por qué la activación por socket resuelve además un problema de dependencias:** como `systemd` abre todos los sockets a la escucha *antes* de arrancar cualquier daemon, el servicio A puede conectarse al socket del servicio B mientras B todavía se está inicializando — la conexión simplemente hace cola en el backlog. Esto elimina la mayoría de las restricciones de orden de arranque y es la razón por la que `systemd` arranca en paralelo donde SysV no podía.

### 3.7 Un procedimiento defendible para deshabilitar

Nunca deshabilites en masa sobre un host vivo. El orden que te mantiene empleado:

```
# 1. Snapshot the current state so you can prove and revert what changed
$ sudo ss -tulpnH | sort > /root/sockets-before.txt
$ systemctl list-unit-files --state=enabled > /root/units-before.txt

# 2. Attribute the socket to a package before touching it
$ dpkg -S "$(readlink -f /lib/systemd/system/rpcbind.socket)"
rpcbind: /lib/systemd/system/rpcbind.socket

# 3. Check what would break
$ apt-cache rdepends --installed rpcbind
rpcbind
Reverse Depends:
  nfs-common

# 4. Stop first, observe, then make it permanent
$ sudo systemctl stop rpcbind.socket rpcbind.service
$ sleep 300 && sudo journalctl -p warning --since "5 min ago" --no-pager | head

# 5. Make it permanent and unstartable
$ sudo systemctl mask --now rpcbind.socket rpcbind.service

# 6. Prove the delta
$ sudo ss -tulpnH | sort > /root/sockets-after.txt
$ diff /root/sockets-before.txt /root/sockets-after.txt
2,3d1
< tcp LISTEN 0 4096 0.0.0.0:111 0.0.0.0:* users:(("rpcbind",pid=598,fd=4),("systemd",pid=1,fd=38))
< tcp LISTEN 0 4096    [::]:111    [::]:* users:(("rpcbind",pid=598,fd=6),("systemd",pid=1,fd=40))
```

El paso 4 — detener, esperar, leer el log — es lo que separa un cambio de una caída de servicio. Enmascarar de inmediato oculta el síntoma de una dependencia que no sabías que existía.

---

## 4. TCP wrappers

### 4.1 Qué son realmente

Los TCP wrappers **no son un firewall**. No hay componente de kernel. Son una biblioteca de espacio de usuario, `libwrap`, cuya función `hosts_access(3)` consulta `/etc/hosts.allow` y `/etc/hosts.deny` y devuelve permitir o denegar. El daemon la llama **después** del `accept()` — el handshake TCP ya se completó y el cliente ya llegó al proceso.

Dos vías de integración:

1. **Capa intermedia `tcpd`** — `inetd`/`xinetd` ejecuta `/usr/sbin/tcpd` en lugar del servidor real. `tcpd` chequea las reglas, registra, y luego hace `exec` del binario real.
2. **Enlazado directamente** — el daemon enlaza `libwrap` y llama a `hosts_access()` él mismo.

La **primera pregunta** en cualquier investigación de TCP wrappers es cuál de estas aplica, o si alguna aplica:

```
$ ldd /usr/sbin/vsftpd | grep -i wrap
        libwrap.so.0 => /lib/x86_64-linux-gnu/libwrap.so.0 (0x00007f2c9a1e4000)

$ ldd /usr/sbin/sshd | grep -i wrap
$ echo "exit=$?  → sshd is NOT wrapped"
exit=1  → sshd is NOT wrapped
```

Ese segundo resultado no es un sistema roto. **OpenSSH eliminó el soporte de `libwrap` en la versión 6.7 (octubre de 2014).** Escribir `sshd: ALL` en `/etc/hosts.deny` en cualquier distribución moderna no hace absolutamente nada, y la gente se deja afuera a sí misma — o, mucho peor, cree que está protegida cuando no lo está.

### 4.2 Orden de evaluación

El algoritmo es corto y no tiene negación ni precedencia explícita más allá del orden:

```
1. Read /etc/hosts.allow top to bottom.
   First matching rule  →  ACCESS GRANTED. Stop.
2. Read /etc/hosts.deny top to bottom.
   First matching rule  →  ACCESS DENIED. Stop.
3. No match in either file  →  ACCESS GRANTED.
```

Consecuencias que hay que internalizar:

- **`hosts.allow` siempre gana.** Una línea permisiva ahí no puede ser anulada por `hosts.deny`.
- **El predeterminado es permitir.** Un `hosts.deny` vacío significa que todo está permitido. La postura clásica de denegar por defecto es `ALL: ALL` en `hosts.deny`, y luego excepciones explícitas en `hosts.allow`.
- **Ambos archivos ausentes = todo permitido.** Sin error, sin advertencia.

### 4.3 Sintaxis de las reglas

```
daemon_list : client_list [ : option : option ... ]
```

`daemon_list` coincide con el **nombre del proceso como el basename de `argv[0]`** — `sshd`, `vsftpd`, `in.telnetd`, `rpcbind` — no con el número de puerto ni con el nombre del servicio en `/etc/services`.

| Comodín | Coincide con |
|---|---|
| `ALL` | Todo, en cualquiera de los dos campos |
| `LOCAL` | Cualquier nombre de host sin punto (mismo dominio) |
| `UNKNOWN` | Cliente cuyo nombre o dirección no puede determinarse |
| `KNOWN` | Cliente cuyo nombre **y** dirección son conocidos |
| `PARANOID` | El DNS directo y el inverso no coinciden. Se evalúa *antes* del procesamiento de reglas |
| `EXCEPT` | Resta de conjuntos: `list1 EXCEPT list2` |

Patrones de cliente:

| Patrón | Coincide con |
|---|---|
| `192.0.2.7` | Una dirección IPv4 |
| `192.0.2.` | Punto final — coincidencia por prefijo sobre `192.0.2.0/24` |
| `192.0.2.0/255.255.255.0` | Dirección/máscara de red |
| `192.0.2.0/24` | CIDR (`libwrap` reciente) |
| `.example.com` | Punto inicial — coincidencia por sufijo de dominio |
| `[2001:db8::1]` | Una dirección IPv6 — los corchetes son obligatorios |
| `[2001:db8::]/64` | Prefijo IPv6 |
| `@engineering` | Netgroup de NIS |
| `/etc/wrappers/admins.list` | Ruta absoluta — lee los patrones desde un archivo |

Par completo y desplegable:

```
# /etc/hosts.deny — default-deny posture.
# Evaluated ONLY if no rule in /etc/hosts.allow matched first.
#
# WARNING: this file is consulted only by daemons that link libwrap.
# Verify with: ldd $(command -v <daemon>) | grep libwrap
# OpenSSH >= 6.7 does NOT link libwrap. See /etc/nftables.conf instead.

ALL: ALL : severity auth.warning

# Log every refusal with the client address, then deny.
# The spawn command must not block: tcpd waits for it.
ALL: ALL : spawn (/usr/bin/logger -p auth.warning -t tcpwrap \
        "DENY %d from %h (%a) user=%u client-info=%c") & : deny
```

```
# /etc/hosts.allow — explicit exceptions. First match wins, then STOP.
#
# Format:  daemon_list : client_list [ : option : option ... ]

# --- Always allow the host to talk to itself ---------------------------
ALL: 127.0.0.1 [::1] LOCAL

# --- Management network: everything except the guest VLAN ---------------
ALL: 10.20.0.0/255.255.255.0 EXCEPT 10.20.0.99

# --- FTP: office network and one partner address ------------------------
vsftpd: 10.20.0.0/24 192.0.2.7 [2001:db8:10::]/64 : \
        severity auth.info

# --- Portmapper: NFS clients only. rpcbind resolves no hostnames, so
#     these MUST be numeric addresses.
rpcbind: 10.20.0.10 10.20.0.11 10.20.0.12

# --- Time-limited contractor access, patterns kept in a separate file ---
vsftpd: /etc/wrappers/contractors.list

# --- Reject anything whose forward and reverse DNS disagree -------------
ALL: PARANOID : deny
```

### 4.4 Opciones: `hosts_options(5)`

La sintaxis extendida (compilada con `PROCESS_OPTIONS`, estándar en Linux) agrega un tercer campo:

| Opción | Efecto |
|---|---|
| `allow` / `deny` | Veredicto explícito — te deja escribir ambas decisiones en un solo archivo |
| `spawn <shell cmd>` | Ejecuta un comando como root, en segundo plano. El acceso continúa |
| `twist <shell cmd>` | **Reemplaza** el servicio por este comando. Se usa para banners y tarpits |
| `severity <facility.level>` | Facility/prioridad de syslog para esta coincidencia |
| `banners <dir>` | Envía `<dir>/<daemon>` al cliente antes de que arranque el servicio |
| `nice <n>` | Cambia la prioridad del servidor lanzado |
| `umask <mask>` | Fija la umask para el servidor |
| `setenv <name> <value>` | Inyecta una variable de entorno |
| `rfc931 [timeout]` | Consulta el `identd` del cliente. **Agrega latencia; evitalo** |
| `keepalive` | Habilita keepalives de TCP |
| `linger <sec>` | Tiempo de espera de `SO_LINGER` |

Caracteres de expansión utilizables dentro de `spawn`/`twist`/`banners`:

| Código | Se expande a |
|---|---|
| `%a` / `%A` | Dirección del cliente / del servidor |
| `%c` | Info del cliente: `user@host`, `user@address`, nombre de host, o dirección |
| `%d` | Nombre del proceso del daemon (`argv[0]`) |
| `%h` / `%H` | Nombre de host o dirección del cliente / del servidor |
| `%n` / `%N` | Nombre de host del cliente / del servidor, o `unknown` / `paranoid` |
| `%p` | PID del daemon |
| `%s` | Info del servidor: `daemon@host`, `daemon@address`, o `daemon` |
| `%u` | Nombre de usuario del cliente, o `unknown` |
| `%%` | Un `%` literal |

Un tarpit para escáneres — `twist` reemplaza el servicio por completo:

```
# /etc/hosts.allow
in.telnetd: ALL : twist /bin/echo "554 Access from %a is logged and denied."
```

**Nota de seguridad sobre `spawn`:** el comando corre **como root** con datos controlados por el cliente (`%h`, `%u`) en sus argumentos. Nunca los interpoles dentro de una construcción de shell que los vuelva a parsear. Pasarlos como argumentos separados de `logger`, como en el `hosts.deny` de arriba, es seguro; incrustarlos en un backtick o en un `eval` es un agujero de inyección de comandos a nivel root.

### 4.5 Probar sin tocar el daemon

El paquete de wrappers trae dos probadores hechos a propósito. Usalos — no pruebes intentando conectarte desde producción.

```
$ sudo tcpdchk -v
Using network configuration file: /etc/inetd.conf

>>> Rule /etc/hosts.allow line 12:
daemons:  vsftpd
clients:  10.20.0.0/24 192.0.2.7 [2001:db8:10::]/64
option:   severity auth.info
access:   granted

>>> Rule /etc/hosts.deny line 8:
daemons:  ALL
clients:  ALL
option:   severity auth.warning
access:   denied

warning: /etc/hosts.allow, line 21: rpcbind: no such process name in /etc/inetd.conf
```

Esa advertencia es esperable e inofensiva para un daemon enlazado directamente como `rpcbind`; `tcpdchk` solo conoce las entradas de `inetd.conf`. Lo que sí detecta de manera confiable son errores de tipeo, reglas inalcanzables y errores de sintaxis.

`tcpdmatch` responde "qué pasaría si este cliente se conectara ahora mismo":

```
$ tcpdmatch vsftpd 10.20.0.42
client:   hostname build01.corp.example.com
client:   address  10.20.0.42
server:   process  vsftpd
matched:  /etc/hosts.allow line 9
option:   severity auth.info
access:   granted

$ tcpdmatch vsftpd 203.0.113.9
client:   hostname unknown
client:   address  203.0.113.9
server:   process  vsftpd
matched:  /etc/hosts.deny line 8
option:   severity auth.warning
access:   denied

$ tcpdmatch sshd 203.0.113.9
client:   hostname unknown
client:   address  203.0.113.9
server:   process  sshd
matched:  /etc/hosts.deny line 8
access:   denied
```

**Leé ese último resultado con atención.** `tcpdmatch` dice "denegado" — pero `sshd` no enlaza `libwrap`, así que nunca pregunta. `tcpdmatch` evalúa los archivos de reglas en aislamiento; no sabe qué daemons los consultan. Esta es exactamente la falsa sensación de seguridad que hace peligrosos a los TCP wrappers hoy.

Observar una denegación real en el log:

```
$ sudo journalctl -t vsftpd -t tcpwrap --since "10 min ago" --no-pager
Aug 31 12:14:07 ftp01 vsftpd[24188]: refused connect from 203.0.113.9 (203.0.113.9)
Aug 31 12:14:07 ftp01 tcpwrap: DENY vsftpd from 203.0.113.9 (203.0.113.9) user=unknown client-info=203.0.113.9
```

### 4.6 Estado, y qué usar en su lugar

| Componente | Soporte de libwrap |
|---|---|
| OpenSSH | **Eliminado en 6.7** (2014) |
| `systemd` | **Eliminado en v212** (2014); las unidades `.socket` nunca lo tuvieron |
| RHEL / CentOS 8+ | El paquete `tcp_wrappers` fue **eliminado** de la distribución |
| Fedora 29+ | Eliminado |
| Debian / Ubuntu | `libwrap0` y `tcpd` siguen empaquetados; varía según el daemon |
| `vsftpd` | Soportado cuando se compila con él y se fija `tcp_wrappers=YES` |
| `rpcbind`, `nfs-utils` | Soportado en las compilaciones de Debian; varía en otros lados |
| `xinetd`, `inetd` | Soportado vía la capa intermedia `tcpd` |

Tabla de compromisos sobre qué debería hacer cumplir realmente tu política de admisión:

| Mecanismo | Capa | Lo hace cumplir | ¿Se completa el handshake TCP? | Granularidad por daemon | Sobrevive a una recompilación del daemon | Mejor para |
|---|---|---|---|---|---|---|
| `hosts.allow`/`hosts.deny` | Biblioteca de espacio de usuario | El daemon, voluntariamente | **Sí** | Sí, por nombre de proceso | **No** — deja de funcionar silenciosamente | Solo hosts heredados con `xinetd`/`vsftpd` |
| `nftables` / `iptables` | netfilter del kernel | El kernel, obligatorio | **No** (`drop`) | Por puerto, no por proceso | Sí | Admisión en el borde de red — **la opción por defecto** |
| Reglas rich de `firewalld` | Kernel (backend nft) | El kernel, obligatorio | No | Por definición de servicio | Sí | Hosts de la familia RHEL con semántica de zonas |
| `IPAddressAllow=` de `systemd` | Filtro eBPF de cgroup | El kernel, obligatorio | El handshake se completa, se rechaza el `accept()` | **Por unidad** — exacta | Sí | Cerrar un servicio sin tocar el firewall global |
| `Match Address` + `AllowUsers` de `sshd` | Aplicación | El daemon | Sí | Por usuario + dirección | La configuración se versiona junto al daemon | SSH específicamente |
| `pam_access` (`access.conf`) | PAM, al iniciar sesión | La pila de PAM | Sí | Por usuario + origen | Sí | Quién puede iniciar sesión, no quién puede conectarse |

**Recomendación:** tratá los TCP wrappers como una habilidad de leer-y-reconocer. Hacé cumplir con `nftables` en el límite de red, con `IPAddressAllow=` de `systemd` por unidad, y con la ACL propia de la aplicación como capa más interna. Mantené `hosts.deny: ALL: ALL` en su lugar en hosts heredados como defensa en profundidad barata — pero nunca como único control.

El equivalente en `nftables` de la política expresada arriba, completo y cargable:

```
#!/usr/sbin/nft -f
# /etc/nftables.conf — mandatory, kernel-enforced admission control.
# Load: sudo nft -f /etc/nftables.conf
# Persist: sudo systemctl enable --now nftables

flush ruleset

table inet filter {
    set admin_v4 {
        type ipv4_addr
        flags interval
        comment "management network + jump host"
        elements = { 10.20.0.0/24, 192.0.2.7 }
    }

    set admin_v6 {
        type ipv6_addr
        flags interval
        elements = { 2001:db8:10::/64 }
    }

    set ssh_bruteforce {
        type ipv4_addr
        flags dynamic, timeout
        timeout 1h
        size 65535
    }

    chain input {
        type filter hook input priority filter; policy drop;

        iif "lo" accept comment "loopback is trusted"
        ct state established,related accept
        ct state invalid drop comment "no conntrack entry: malformed or spoofed"

        ip protocol icmp icmp type { echo-request, destination-unreachable, \
            time-exceeded, parameter-problem } accept
        ip6 nexthdr icmpv6 icmpv6 type { echo-request, destination-unreachable, \
            packet-too-big, time-exceeded, parameter-problem, nd-neighbor-solicit, \
            nd-neighbor-advert, nd-router-advert } accept

        # SSH: management sources only, rate limited, offenders quarantined 1h.
        tcp dport 22 ip saddr @ssh_bruteforce drop
        tcp dport 22 ip saddr @admin_v4 ct state new \
            add @ssh_bruteforce { ip saddr timeout 1h limit rate over 10/minute } drop
        tcp dport 22 ip saddr @admin_v4 accept
        tcp dport 22 ip6 saddr @admin_v6 accept

        # Public HTTP/HTTPS.
        tcp dport { 80, 443 } ct state new accept

        # Everything else is dropped by policy. Sample the drops.
        limit rate 5/minute burst 10 packets \
            log prefix "nft-input-drop: " level info flags all
        counter comment "unmatched input"
    }

    chain forward {
        type filter hook forward priority filter; policy drop;
        counter comment "this host is not a router"
    }

    chain output {
        type filter hook output priority filter; policy accept;
    }
}
```

```
$ sudo nft -c -f /etc/nftables.conf && echo "syntax OK"
syntax OK
$ sudo nft -f /etc/nftables.conf
$ sudo nft list chain inet filter input | head -8
table inet filter {
        chain input {
                type filter hook input priority filter; policy drop;
                iif "lo" accept comment "loopback is trusted"
                ct state established,related accept
                ct state invalid drop comment "no conntrack entry: malformed or spoofed"
                ip protocol icmp icmp type { destination-unreachable, time-exceeded, parameter-problem, echo-request } accept
$ sudo nft list set inet filter ssh_bruteforce
table inet filter {
        set ssh_bruteforce {
                type ipv4_addr
                size 65535
                flags dynamic,timeout
                timeout 1h
                elements = { 203.0.113.9 expires 58m12s344ms }
        }
}
```

---

## 5. `/etc/nologin` y la admisión de inicio de sesión

### 5.1 El archivo

Si `/etc/nologin` existe, `pam_nologin.so` deniega el inicio de sesión a **todos los usuarios salvo root** e imprime el contenido del archivo como motivo. Que tenga longitud cero es legal — el usuario recibe entonces un rechazo genérico.

```
$ sudo tee /etc/nologin <<'EOF'
================================================================
  MAINTENANCE WINDOW — CHG-2026-0831-014
  Storage controller firmware upgrade.
  Logins disabled until 2026-08-31 16:00 UTC.
  Escalation: #sre-oncall  /  oncall@corp.example.com
================================================================
EOF
$ sudo chmod 0644 /etc/nologin
```

```
$ ssh alice@web01
================================================================
  MAINTENANCE WINDOW — CHG-2026-0831-014
  Storage controller firmware upgrade.
  Logins disabled until 2026-08-31 16:00 UTC.
  Escalation: #sre-oncall  /  oncall@corp.example.com
================================================================
Connection closed by 10.20.0.15 port 22

$ ssh root@web01
Linux web01 6.1.0-23-amd64 #1 SMP Debian 6.1.99-1 x86_64
root@web01:~#
```

Borrarlo rehabilita el inicio de sesión de inmediato — sin reiniciar ningún daemon:

```
$ sudo rm -f /etc/nologin
```

`systemd` usa este mecanismo para los apagados programados: escribe `/run/nologin` y enlaza simbólicamente `/etc/nologin` a él, de modo que el bloqueo se limpia automáticamente al reiniciar.

```
$ sudo shutdown -h +30 "Storage firmware upgrade"
Shutdown scheduled for Mon 2026-08-31 12:55:00 UTC, use 'shutdown -c' to cancel.
$ ls -l /etc/nologin /run/nologin
lrwxrwxrwx 1 root root  12 Aug 31 12:25 /etc/nologin -> /run/nologin
-rw-r--r-- 1 root root  62 Aug 31 12:25 /run/nologin
$ cat /run/nologin
System is going down. Unprivileged users are not permitted to log in anymore. For technical details, see pam_nologin(8).
$ sudo shutdown -c
$ ls -l /etc/nologin
ls: cannot access '/etc/nologin': No such file or directory
```

Para que `pam_nologin` funcione, el módulo tiene que estar en la pila de PAM del servicio:

```
$ grep -rn nologin /etc/pam.d/
/etc/pam.d/login:account  requisite  pam_nologin.so
/etc/pam.d/sshd:account   required   pam_nologin.so
```

Si a `/etc/pam.d/sshd` le falta esa línea, crear `/etc/nologin` va a bloquear los inicios de sesión por consola y no va a hacer nada con SSH. Verificá por servicio, no globalmente.

### 5.2 `/etc/nologin` vs `/sbin/nologin` — cosas distintas, nombres parecidos

| | `/etc/nologin` | `/usr/sbin/nologin` (`/sbin/nologin`) |
|---|---|---|
| Tipo | Un **archivo cuya existencia** es una bandera | Un **ejecutable** usado como shell de login |
| Alcance | **Todos los usuarios no root**, en todo el host | **Una cuenta** |
| Mecanismo | `pam_nologin.so` | Campo 7 de `/etc/passwd` |
| Persistencia | Hasta que se borra el archivo | Hasta que se cambia la shell |
| Origen del mensaje | Contenido de `/etc/nologin` | Contenido de `/etc/nologin.txt`, si no el texto incorporado |
| Uso típico | Ventanas de mantenimiento | Cuentas de servicio |

```
$ sudo usermod -s /usr/sbin/nologin backupsvc
$ su - backupsvc
This account is currently not available.
$ echo $?
1

$ echo "Service account. Interactive login is not permitted." | sudo tee /etc/nologin.txt
$ su - backupsvc
Service account. Interactive login is not permitted.
```

`/bin/false` logra la misma denegación pero no imprime nada, lo que hace más difícil clasificar los reportes de los usuarios. Preferí `nologin`.

Ninguna de las dos shells bloquea por sí sola el SSH no interactivo en toda configuración, así que para las cuentas de servicio asegurate además de que no haya un `authorized_keys` utilizable y de que el campo de contraseña sea `*` o `!`.

### 5.3 `pam_access` — la capa de grano fino

`/etc/security/access.conf` controla *quién* puede iniciar sesión y *desde dónde*, evaluado por primera coincidencia:

```
# /etc/security/access.conf
# permission : users/groups : origins
#   +  = allow      -  = deny
# First matching line wins. Terminate with a catch-all deny.

+ : root       : 10.20.0.0/24 LOCAL
+ : sre        : 10.20.0.0/24 2001:db8:10::/64
+ : deploy     : 10.20.0.10 10.20.0.11
+ : (wheel)    : LOCAL
- : ALL        : ALL
```

Habilitalo para el servicio correspondiente:

```
$ grep -n pam_access /etc/pam.d/sshd
44:account  required  pam_access.so
```

### 5.4 Checklist de cierre completo

```
# Prevent NEW logins host-wide (reversible in one command)
$ sudo systemctl stop sshd.socket 2>/dev/null; sudo touch /etc/nologin

# Per-account, permanent
$ sudo usermod -L        contractor          # lock password
$ sudo chage  -E 0       contractor          # expire the account (also blocks keys)
$ sudo usermod -s /usr/sbin/nologin contractor
$ sudo crontab -r -u     contractor 2>/dev/null || true
$ sudo pkill -KILL -u    contractor

# Verify
$ sudo passwd -S contractor
contractor L 08/31/2026 1 90 14 30
$ sudo chage -l contractor | grep -i 'account expires'
Account expires                                         : Jan 01, 1970
```

---

## 6. Manifiestos completos de infraestructura

### 6.1 Rol de Ansible — el objetivo completo, hecho cumplir

```yaml
---
# roles/host_security/defaults/main.yml
host_security_encrypt_method: YESCRYPT
host_security_yescrypt_cost: 7
host_security_pass_max_days: 90
host_security_pass_min_days: 1
host_security_pass_warn_age: 14
host_security_umask: "077"

host_security_masked_units:
  - rpcbind.socket
  - rpcbind.service
  - avahi-daemon.socket
  - avahi-daemon.service
  - cups.socket
  - cups.service
  - bluetooth.service

host_security_removed_packages:
  - telnetd
  - rsh-server
  - rsh-client
  - nis
  - talk
  - talkd
  - xinetd

host_security_allowed_listen_ports:
  - 22
  - 80
  - 443

host_security_wrappers_allow:
  - "10.20.0.0/255.255.255.0"
  - "192.0.2.7"

host_security_manage_wrappers: true
```

```yaml
---
# roles/host_security/tasks/main.yml
- name: Gather package facts
  ansible.builtin.package_facts:
    manager: auto

# ---------------------------------------------------------------------
# 1. Shadow passwords
# ---------------------------------------------------------------------
- name: Ensure shadow passwords are enabled
  ansible.builtin.command:
    cmd: pwconv
  changed_when: false
  check_mode: false

- name: Ensure group shadow file is enabled
  ansible.builtin.command:
    cmd: grpconv
  changed_when: false
  check_mode: false

- name: Assert that no hash remains in /etc/passwd
  ansible.builtin.shell:
    cmd: "awk -F: 'length($2) > 1 {print $1}' /etc/passwd"
  register: hs_unshadowed
  changed_when: false
  failed_when: hs_unshadowed.stdout | length > 0

- name: Enforce permissions on the account databases
  ansible.builtin.file:
    path: "{{ item.path }}"
    owner: root
    group: "{{ item.group }}"
    mode: "{{ item.mode }}"
  loop:
    - { path: /etc/passwd,  group: root,   mode: "0644" }
    - { path: /etc/group,   group: root,   mode: "0644" }
    - { path: /etc/shadow,  group: "{{ 'shadow' if ansible_os_family == 'Debian' else 'root' }}",
        mode: "{{ '0640' if ansible_os_family == 'Debian' else '0000' }}" }
    - { path: /etc/gshadow, group: "{{ 'shadow' if ansible_os_family == 'Debian' else 'root' }}",
        mode: "{{ '0640' if ansible_os_family == 'Debian' else '0000' }}" }

- name: Configure password policy in /etc/login.defs
  ansible.builtin.lineinfile:
    path: /etc/login.defs
    regexp: "^\\s*#?\\s*{{ item.key }}\\s+"
    line: "{{ item.key }}\t{{ item.value }}"
    state: present
    create: false
    backup: true
  loop:
    - { key: ENCRYPT_METHOD,       value: "{{ host_security_encrypt_method }}" }
    - { key: YESCRYPT_COST_FACTOR, value: "{{ host_security_yescrypt_cost }}" }
    - { key: PASS_MAX_DAYS,        value: "{{ host_security_pass_max_days }}" }
    - { key: PASS_MIN_DAYS,        value: "{{ host_security_pass_min_days }}" }
    - { key: PASS_WARN_AGE,        value: "{{ host_security_pass_warn_age }}" }
    - { key: UMASK,                value: "{{ host_security_umask }}" }
    - { key: HOME_MODE,            value: "0700" }
    - { key: LOG_UNKFAIL_ENAB,     value: "no" }
    - { key: DEFAULT_HOME,         value: "no" }
    - { key: LOGIN_RETRIES,        value: "3" }

- name: Report accounts still using a legacy hash
  ansible.builtin.shell:
    cmd: "awk -F: '$2 ~ /^\\$(1|5)\\$/ {print $1}' /etc/shadow"
  register: hs_legacy_hashes
  changed_when: false
  become: true

- name: Warn about legacy hashes
  ansible.builtin.debug:
    msg: >-
      Accounts still on md5crypt/sha256crypt: {{ hs_legacy_hashes.stdout_lines | join(', ') }}.
      Force rotation with: chage -d 0 <user>
  when: hs_legacy_hashes.stdout_lines | length > 0

- name: Find UID 0 accounts other than root
  ansible.builtin.shell:
    cmd: "awk -F: '$3 == 0 && $1 != \"root\" {print $1}' /etc/passwd"
  register: hs_uid0
  changed_when: false
  failed_when: hs_uid0.stdout | length > 0

- name: Find accounts with an empty password field
  ansible.builtin.shell:
    cmd: "awk -F: '$2 == \"\" {print $1}' /etc/shadow"
  register: hs_empty_pw
  changed_when: false
  become: true
  failed_when: hs_empty_pw.stdout | length > 0

- name: Run pwck and grpck in read-only mode
  ansible.builtin.command:
    cmd: "{{ item }} -r"
  loop:
    - pwck
    - grpck
  register: hs_ck
  changed_when: false
  failed_when: hs_ck.rc not in [0, 2]

# ---------------------------------------------------------------------
# 2. Network services
# ---------------------------------------------------------------------
- name: Remove obsolete cleartext network services
  ansible.builtin.package:
    name: "{{ host_security_removed_packages }}"
    state: absent
    purge: "{{ true if ansible_pkg_mgr == 'apt' else omit }}"

- name: Mask units that must never start
  ansible.builtin.systemd_service:
    name: "{{ item }}"
    state: stopped
    enabled: false
    masked: true
    daemon_reload: true
  loop: "{{ host_security_masked_units }}"
  failed_when: false

- name: Collect the current listening sockets
  ansible.builtin.command:
    cmd: ss -tlnH
  register: hs_listen
  changed_when: false

- name: Compute non-loopback listening ports
  ansible.builtin.set_fact:
    hs_public_ports: >-
      {{ hs_listen.stdout_lines
         | map('regex_replace', '^\\S+\\s+\\d+\\s+\\d+\\s+(\\S+)\\s+.*$', '\\1')
         | reject('search', '^127\\.')
         | reject('search', '^\\[::1\\]')
         | map('regex_replace', '^.*:(\\d+)$', '\\1')
         | map('int')
         | unique | sort }}

- name: Fail on any unexpected public listener
  ansible.builtin.assert:
    that:
      - hs_public_ports | difference(host_security_allowed_listen_ports) | length == 0
    fail_msg: >-
      Unexpected public listeners: {{ hs_public_ports | difference(host_security_allowed_listen_ports) }}.
      Allowed: {{ host_security_allowed_listen_ports }}
    success_msg: "Listening sockets match policy: {{ hs_public_ports }}"

- name: Disable every xinetd service present on the host
  ansible.builtin.replace:
    path: "{{ item }}"
    regexp: '^(\s*disable\s*=\s*).*$'
    replace: '\1yes'
  loop: "{{ query('fileglob', '/etc/xinetd.d/*') }}"
  when: "'xinetd' in ansible_facts.packages"
  notify: reload xinetd

# ---------------------------------------------------------------------
# 3. TCP wrappers (legacy defence in depth)
# ---------------------------------------------------------------------
- name: Deploy /etc/hosts.deny
  ansible.builtin.copy:
    dest: /etc/hosts.deny
    owner: root
    group: root
    mode: "0644"
    backup: true
    content: |
      # Managed by Ansible - role host_security. Do not edit by hand.
      # Consulted only by daemons linked against libwrap.
      # Verify: ldd $(command -v <daemon>) | grep libwrap
      ALL: ALL : severity auth.warning
  when: host_security_manage_wrappers | bool

- name: Deploy /etc/hosts.allow
  ansible.builtin.copy:
    dest: /etc/hosts.allow
    owner: root
    group: root
    mode: "0644"
    backup: true
    content: |
      # Managed by Ansible - role host_security. Do not edit by hand.
      # First match wins, then evaluation stops.
      ALL: 127.0.0.1 [::1] LOCAL
      {% for net in host_security_allowed_wrappers_nets | default(host_security_wrappers_allow) %}
      ALL: {{ net }}
      {% endfor %}
  when: host_security_manage_wrappers | bool

- name: Validate the wrapper rule files
  ansible.builtin.command:
    cmd: tcpdchk
  register: hs_tcpdchk
  changed_when: false
  failed_when: "'error' in hs_tcpdchk.stderr | lower"
  when:
    - host_security_manage_wrappers | bool
    - "'tcpd' in ansible_facts.packages"

# ---------------------------------------------------------------------
# 4. Login admission
# ---------------------------------------------------------------------
- name: Ensure /etc/nologin is absent during normal operation
  ansible.builtin.file:
    path: /etc/nologin
    state: absent

- name: Ensure pam_nologin is in the sshd account stack
  ansible.builtin.lineinfile:
    path: /etc/pam.d/sshd
    line: "account    required     pam_nologin.so"
    regexp: '^account\s+\S+\s+pam_nologin\.so'
    insertafter: '^account'
    state: present

- name: Give every system account a non-interactive shell
  ansible.builtin.user:
    name: "{{ item }}"
    shell: /usr/sbin/nologin
  loop: "{{ ansible_facts.getent_passwd | default({}) | dict2items
            | selectattr('value.1', 'defined')
            | selectattr('value.1', 'match', '^[0-9]+$')
            | selectattr('value.1', 'int', '<', 1000)
            | map(attribute='key') | reject('equalto', 'root')
            | reject('equalto', 'sync') | list }}"
  when: ansible_facts.getent_passwd is defined
  failed_when: false
```

```yaml
---
# roles/host_security/handlers/main.yml
- name: reload xinetd
  ansible.builtin.systemd_service:
    name: xinetd
    state: reloaded
```

```yaml
---
# site.yml
- name: Apply host security baseline
  hosts: linux_fleet
  become: true
  gather_facts: true
  vars:
    host_security_allowed_listen_ports: [22, 80, 443]
  roles:
    - role: host_security
  post_tasks:
    - name: Emit the final listening socket inventory
      ansible.builtin.command:
        cmd: ss -tulpnH
      register: hs_final
      changed_when: false
    - name: Show it
      ansible.builtin.debug:
        var: hs_final.stdout_lines
```

```
$ ansible-playbook -i inventory/prod site.yml --limit web01 --diff

PLAY [Apply host security baseline] ********************************************

TASK [host_security : Assert that no hash remains in /etc/passwd] **************
ok: [web01]

TASK [host_security : Enforce permissions on the account databases] ************
changed: [web01] => (item={'path': '/etc/shadow', 'group': 'shadow', 'mode': '0640'})
--- before
+++ after
@@ -1,4 +1,4 @@
 {
-    "mode": "0644",
+    "mode": "0640",
     "path": "/etc/shadow"
 }

TASK [host_security : Configure password policy in /etc/login.defs] ************
changed: [web01] => (item={'key': 'ENCRYPT_METHOD', 'value': 'YESCRYPT'})
ok: [web01] => (item={'key': 'PASS_MAX_DAYS', 'value': 90})

TASK [host_security : Mask units that must never start] ***********************
changed: [web01] => (item=rpcbind.socket)
changed: [web01] => (item=rpcbind.service)
ok: [web01] => (item=cups.socket)

TASK [host_security : Fail on any unexpected public listener] *****************
ok: [web01] => {
    "changed": false,
    "msg": "Listening sockets match policy: [22, 80, 443]"
}

PLAY RECAP *********************************************************************
web01  : ok=19  changed=4  unreachable=0  failed=0  skipped=2  rescued=0  ignored=0
```

### 6.2 cloud-init — la línea base en el primer arranque

```yaml
#cloud-config
# Applied at first boot. Everything here is enforced before the instance
# is reachable, which closes the window between provisioning and hardening.

hostname: web02
fqdn: web02.corp.example.com
manage_etc_hosts: true

users:
  - name: root
    lock_passwd: true
    ssh_authorized_keys: []
  - name: sre
    gecos: SRE on-call
    groups: [sudo, adm, systemd-journal]
    shell: /bin/bash
    lock_passwd: true
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    ssh_authorized_keys:
      - "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKq9F3n2sT8vX1oB7dYzR4mWpQ0jH6cLeN5aVuG8kTsP sre@bastion"
  - name: metrics
    system: true
    shell: /usr/sbin/nologin
    lock_passwd: true

write_files:
  - path: /etc/login.defs.d/99-hardening.conf
    permissions: "0644"
    owner: root:root
    content: |
      ENCRYPT_METHOD          YESCRYPT
      YESCRYPT_COST_FACTOR    7
      PASS_MAX_DAYS           90
      PASS_MIN_DAYS           1
      PASS_WARN_AGE           14
      UMASK                   077
      HOME_MODE               0700
      LOG_UNKFAIL_ENAB        no
      DEFAULT_HOME            no

  - path: /etc/hosts.deny
    permissions: "0644"
    owner: root:root
    content: |
      # Default deny for libwrap-linked daemons only.
      ALL: ALL : severity auth.warning

  - path: /etc/hosts.allow
    permissions: "0644"
    owner: root:root
    content: |
      ALL: 127.0.0.1 [::1] LOCAL
      ALL: 10.20.0.0/255.255.255.0

  - path: /etc/ssh/sshd_config.d/99-hardening.conf
    permissions: "0600"
    owner: root:root
    content: |
      PermitRootLogin no
      PasswordAuthentication no
      KbdInteractiveAuthentication no
      PermitEmptyPasswords no
      AuthenticationMethods publickey
      AllowGroups sudo
      ListenAddress 10.20.0.16
      MaxAuthTries 3
      MaxSessions 4
      LoginGraceTime 30
      ClientAliveInterval 300
      ClientAliveCountMax 2
      X11Forwarding no
      AllowAgentForwarding no
      AllowTcpForwarding no
      UsePAM yes

  - path: /etc/systemd/system/metrics-collector.socket
    permissions: "0644"
    owner: root:root
    content: |
      [Unit]
      Description=Metrics collector socket

      [Socket]
      ListenStream=10.20.0.16:9110
      Accept=yes
      MaxConnectionsPerSource=4
      IPAddressDeny=any
      IPAddressAllow=10.20.0.0/24
      IPAddressAllow=localhost

      [Install]
      WantedBy=sockets.target

packages:
  - nftables
  - auditd
  - libpam-pwquality

package_update: true
package_upgrade: true

runcmd:
  - [ pwconv ]
  - [ grpconv ]
  - [ chmod, "0640", /etc/shadow ]
  - [ chgrp, shadow, /etc/shadow ]
  - [ systemctl, mask, --now, rpcbind.socket, rpcbind.service ]
  - [ systemctl, mask, --now, avahi-daemon.socket, avahi-daemon.service ]
  - [ systemctl, daemon-reload ]
  - [ systemctl, enable, --now, nftables.service ]
  - [ systemctl, enable, --now, metrics-collector.socket ]
  - [ systemctl, restart, ssh ]
  - [ sh, -c, "ss -tulpnH > /var/log/first-boot-sockets.txt" ]

power_state:
  mode: reboot
  message: "Rebooting after security baseline"
  timeout: 60
  condition: true
```

### 6.3 Compuerta de CI — que falle el build, no la revisión del incidente

```bash
#!/usr/bin/env bash
# scripts/verify-host-security.sh
# Exit 0 = compliant. Any non-zero = a specific, named violation.
set -euo pipefail

fail=0
report() { printf 'FAIL: %s\n' "$1" >&2; fail=1; }
pass()   { printf 'ok  : %s\n' "$1"; }

# --- 1. Shadow passwords ----------------------------------------------
if awk -F: 'length($2) > 1 {exit 1}' /etc/passwd; then
    pass "no password hash in /etc/passwd"
else
    report "/etc/passwd contains hashes - run pwconv"
fi

shadow_mode=$(stat -c '%a' /etc/shadow)
case "$shadow_mode" in
    0|000|400|600|640) pass "/etc/shadow mode $shadow_mode" ;;
    *) report "/etc/shadow is mode $shadow_mode (expected 0000, 0400, 0600 or 0640)" ;;
esac

if [ "$(awk -F: '$3 == 0 && $1 != "root"' /etc/passwd | wc -l)" -eq 0 ]; then
    pass "root is the only UID 0"
else
    report "extra UID 0 account(s): $(awk -F: '$3==0 && $1!="root"{print $1}' /etc/passwd | tr '\n' ' ')"
fi

if [ "$(awk -F: '$2 == ""' /etc/shadow | wc -l)" -eq 0 ]; then
    pass "no empty password fields"
else
    report "empty password field: $(awk -F: '$2==""{print $1}' /etc/shadow | tr '\n' ' ')"
fi

legacy=$(awk -F: '$2 ~ /^\$(1|5)\$/ {print $1}' /etc/shadow | tr '\n' ' ')
[ -z "$legacy" ] && pass "no md5crypt/sha256crypt hashes" \
                 || report "legacy hashes: $legacy"

grep -qE '^\s*ENCRYPT_METHOD\s+(YESCRYPT|SHA512|BCRYPT)\b' /etc/login.defs \
    && pass "ENCRYPT_METHOD is modern" \
    || report "ENCRYPT_METHOD is weak or unset in /etc/login.defs"

pwck -r >/dev/null 2>&1 && pass "pwck clean" || echo "warn: pwck reported issues"

# --- 2. Listening sockets ---------------------------------------------
allowed_ports="22 80 443"
public=$(ss -tlnH \
    | awk '{print $4}' \
    | grep -Ev '^(127\.|\[::1\])' \
    | sed -E 's/.*:([0-9]+)$/\1/' \
    | sort -un)

for p in $public; do
    case " $allowed_ports " in
        *" $p "*) pass "listener on $p is expected" ;;
        *)        report "unexpected public listener on port $p" ;;
    esac
done

if systemctl is-enabled rpcbind.socket >/dev/null 2>&1; then
    report "rpcbind.socket is enabled"
else
    pass "rpcbind.socket not enabled"
fi

# --- 3. xinetd ---------------------------------------------------------
if [ -d /etc/xinetd.d ]; then
    enabled=$(grep -lE '^\s*disable\s*=\s*no' /etc/xinetd.d/* 2>/dev/null || true)
    [ -z "$enabled" ] && pass "no xinetd service enabled" \
                      || report "xinetd services enabled: $enabled"
else
    pass "xinetd not installed"
fi

# --- 4. TCP wrappers ---------------------------------------------------
if [ -f /etc/hosts.deny ]; then
    grep -qE '^\s*ALL\s*:\s*ALL' /etc/hosts.deny \
        && pass "hosts.deny has a default-deny rule" \
        || report "hosts.deny lacks 'ALL: ALL'"
else
    report "/etc/hosts.deny missing (wrappers default to permit)"
fi

command -v tcpdchk >/dev/null 2>&1 && { tcpdchk 2>&1 | grep -i '^error' && report "tcpdchk reported errors" || pass "tcpdchk clean"; }

# --- 5. Login admission ------------------------------------------------
[ -e /etc/nologin ] && report "/etc/nologin present - logins are blocked" \
                    || pass "/etc/nologin absent"

grep -q 'pam_nologin.so' /etc/pam.d/sshd \
    && pass "pam_nologin in sshd stack" \
    || report "pam_nologin missing from /etc/pam.d/sshd"

exit "$fail"
```

```
$ sudo ./scripts/verify-host-security.sh
ok  : no password hash in /etc/passwd
ok  : /etc/shadow mode 640
ok  : root is the only UID 0
ok  : no empty password fields
ok  : no md5crypt/sha256crypt hashes
ok  : ENCRYPT_METHOD is modern
ok  : pwck clean
ok  : listener on 22 is expected
ok  : listener on 80 is expected
ok  : listener on 443 is expected
ok  : rpcbind.socket not enabled
ok  : no xinetd service enabled
ok  : hosts.deny has a default-deny rule
ok  : tcpdchk clean
ok  : /etc/nologin absent
ok  : pam_nologin in sshd stack
$ echo $?
0
```

---

## 7. Verificación y diagnóstico de fallas

### 7.1 Síntoma → causa → comando

| Síntoma | Causa probable | Confirmar con |
|---|---|---|
| Un usuario no puede iniciar sesión, sin mensaje | La shell es `/bin/false` | `getent passwd user \| cut -d: -f7` |
| "This account is currently not available." | La shell es `/usr/sbin/nologin` | `getent passwd user \| cut -d: -f7` |
| "Your account has expired" | El campo 8 de `/etc/shadow` ya pasó | `chage -l user` |
| "You are required to change your password immediately" | El campo 3 es `0`, o se superó la edad máxima | `chage -l user` |
| Contraseña rechazada, pero es correcta | Cuenta bloqueada (prefijo `!`) | `passwd -S user` |
| Todos menos root son rechazados | Existe `/etc/nologin` | `ls -l /etc/nologin; cat /etc/nologin` |
| El login por consola funciona, el de SSH no | `pam_nologin`/`pam_access` solo en una pila | `grep -rn 'pam_nologin\|pam_access' /etc/pam.d/` |
| El puerto sigue abierto tras `systemctl disable` | Activado por socket | `systemctl list-sockets \| grep <port>` |
| El servicio se reinicia tras el `stop` | Otra unidad lo tiene en `Wants=` | `systemctl list-dependencies --reverse <unit>` |
| `hosts.deny` parece ignorado | El daemon no enlaza `libwrap` | `ldd $(command -v <daemon>) \| grep libwrap` |
| `hosts.deny` ignorado a pesar de `libwrap` | Una regla de `hosts.allow` coincidió primero | `tcpdmatch <daemon> <client>` |
| Una regla de wrapper no coincide con nada | Nombre de daemon equivocado — necesita `argv[0]`, no el puerto | `ps -eo comm,args \| grep <svc>` |
| Un usuario bloqueado sigue entrando por SSH | La autenticación por clave ignora el bloqueo de contraseña | `chage -E 0 user`, `authorized_keys` vacío |
| Cambio de contraseña rechazado: "must wait" | No transcurrió `PASS_MIN_DAYS` | `chage -l user` |
| `useradd` sigue creando hashes `$6$` | `ENCRYPT_METHOD` no aplicado, o a `libcrypt` le falta yescrypt | `grep ENCRYPT /etc/login.defs; ldd $(which login) \| grep crypt` |
| Editar `hosts.allow` no surte efecto | Solo se chequean las conexiones nuevas | Reconectate; `libwrap` lee los archivos por conexión |

### 7.2 Recorrido: "puse `sshd: ALL` en hosts.deny y no pasó nada"

```
$ sudo grep -n sshd /etc/hosts.deny
3:sshd: ALL

$ tcpdmatch sshd 203.0.113.9
client:   hostname unknown
client:   address  203.0.113.9
server:   process  sshd
matched:  /etc/hosts.deny line 3
access:   denied

$ ssh -o ConnectTimeout=5 test@10.20.0.15 'echo CONNECTED'
CONNECTED
```

`tcpdmatch` dice denegado; la conexión tiene éxito. Resolvé la contradicción preguntándote si `sshd` alguna vez consulta las reglas:

```
$ ldd "$(command -v sshd)" | grep -ci wrap
0
$ sshd -V 2>&1 | head -1
OpenSSH_9.2p1 Debian-2+deb12u3, OpenSSL 3.0.14 4 Jun 2024
$ dpkg -s openssh-server | grep -i '^Version'
Version: 1:9.2p1-2+deb12u3
```

OpenSSH 9.2 ≫ 6.7, así que el soporte de `libwrap` ya no está. La regla es inerte. Hacé cumplir en el kernel en su lugar:

```
$ sudo nft add rule inet filter input tcp dport 22 ip saddr != @admin_v4 counter drop
$ sudo nft list ruleset | grep -A1 'dport 22'
                tcp dport 22 ip saddr != @admin_v4 counter packets 0 bytes 0 drop
$ ssh -o ConnectTimeout=5 test@10.20.0.15 'echo CONNECTED'
ssh: connect to host 10.20.0.15 port 22: Connection timed out
```

**Antes de agregar cualquier regla de firewall para SSH, abrí una segunda sesión y mantenela viva.** Una red de seguridad que salvó a mucha gente:

```
$ sudo systemd-run --on-active=300 --timer-property=AccuracySec=1s \
      /usr/sbin/nft flush ruleset
Running timer as unit: run-r7f3c1b2a.timer
Will run service as unit: run-r7f3c1b2a.service
```

Si te dejás afuera, el ruleset se vacía en cinco minutos. Si el cambio está bien, cancelalo:

```
$ sudo systemctl stop run-r7f3c1b2a.timer
```

### 7.3 Recorrido: "el puerto se sigue reabriendo"

```
$ sudo systemctl stop cups.service
$ sudo ss -tlpn 'sport = :631'
State  Recv-Q Send-Q Local Address:Port Peer Address:Port Process
LISTEN 0      4096       127.0.0.1:631       0.0.0.0:*     users:(("systemd",pid=1,fd=51))

$ systemctl list-sockets --all | grep 631
127.0.0.1:631   cups.socket   cups.service

$ systemctl list-dependencies --reverse cups.socket
cups.socket
● └─sockets.target
●   └─basic.target

$ sudo systemctl disable --now cups.socket cups.path cups.service
Removed "/etc/systemd/system/sockets.target.wants/cups.socket".
Removed "/etc/systemd/system/multi-user.target.wants/cups.path".
$ sudo ss -tlpn 'sport = :631'
$ echo "closed"
closed
```

`cups` trae **tres** unidades — `.service`, `.socket` y `.path`. Cualquiera de ellas puede reiniciar el daemon. `systemctl list-unit-files 'cups*'` muestra el conjunto completo antes de que decidas.

### 7.4 Recorrido: "¿qué paquete abrió este puerto?"

```
$ sudo ss -tlpn 'sport = :8125'
LISTEN 0 4096 0.0.0.0:8125 0.0.0.0:* users:(("statsd-proxy",pid=3311,fd=7))

$ readlink -f /proc/3311/exe
/opt/observability/bin/statsd-proxy
$ dpkg -S /opt/observability/bin/statsd-proxy 2>/dev/null || echo "not from a package"
not from a package

$ cat /proc/3311/cgroup
0::/system.slice/statsd-proxy.service
$ systemctl cat statsd-proxy.service | head -12
# /etc/systemd/system/statsd-proxy.service
[Unit]
Description=StatsD UDP/TCP proxy
After=network-online.target

[Service]
ExecStart=/opt/observability/bin/statsd-proxy --listen 0.0.0.0:8125
User=statsd
$ stat -c '%y %U' /etc/systemd/system/statsd-proxy.service
2026-07-19 14:03:22.114 root
```

No empaquetado, instalado a mano, escuchando en todas las interfaces. La remediación correcta no es enmascararlo — presumiblemente se necesita — sino reducir su exposición sin editar un archivo del que otro es dueño:

```
$ sudo systemctl edit statsd-proxy.service
```
```ini
# /etc/systemd/system/statsd-proxy.service.d/override.conf
[Service]
IPAddressDeny=any
IPAddressAllow=10.20.0.0/24
IPAddressAllow=localhost
```
```
$ sudo systemctl daemon-reload && sudo systemctl restart statsd-proxy
$ systemd-analyze security statsd-proxy.service | grep -E 'IPAddress|Overall'
✓ IPAddressDeny=                                       Service blocks all IP address ranges
→ Overall exposure level for statsd-proxy.service: 6.1 MEDIUM 🙁
```

### 7.5 Verificación continua

```
$ sudo lynis audit system --tests-from-group authentication,networking --quiet
[+] Authentication
  - Checking presence /etc/shadow                             [ OK ]
  - Checking password hashing methods                         [ OK ]
  - Checking PASS_MAX_DAYS option in /etc/login.defs          [ OK ]
  - Checking accounts with UID zero                           [ OK ]
[+] Networking
  - Checking listening ports (TCP/UDP)                        [ DONE ]
      * 0.0.0.0:22 (sshd)
      * 0.0.0.0:80 (nginx)
      * 0.0.0.0:443 (nginx)

$ sudo aureport --auth --summary -i --start today
Authentication Summary Report
=============================
total  acct
88     sre
14     root
7      unknown(203.0.113.9)

$ sudo journalctl -p warning --facility=auth,authpriv --since today --no-pager | tail -5
Aug 31 12:14:07 ftp01 vsftpd[24188]: refused connect from 203.0.113.9
Aug 31 12:31:52 web01 sshd[24310]: Invalid user admin from 203.0.113.9 port 51992
Aug 31 12:31:52 web01 sshd[24310]: Connection closed by invalid user admin 203.0.113.9 port 51992 [preauth]
```

Conectá el script de CI de la §6.3 a un timer para que la deriva se detecte entre auditorías:

```ini
# /etc/systemd/system/host-security-audit.service
[Unit]
Description=Host security baseline audit
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/verify-host-security.sh
StandardOutput=journal
StandardError=journal
```
```ini
# /etc/systemd/system/host-security-audit.timer
[Unit]
Description=Daily host security baseline audit
[Timer]
OnCalendar=daily
RandomizedDelaySec=30m
Persistent=true
[Install]
WantedBy=timers.target
```
```
$ sudo systemctl enable --now host-security-audit.timer
$ systemctl list-timers host-security-audit.timer --no-pager
NEXT                        LEFT     LAST                       PASSED  UNIT                       ACTIVATES
Tue 2026-09-01 00:17:41 UTC 11h left Mon 2026-08-31 00:22:09 UTC 12h ago host-security-audit.timer  host-security-audit.service
```

---

## 8. Resumen orientado al examen

| Archivo | Propósito | Lo que te van a preguntar |
|---|---|---|
| `/etc/passwd` | Identidad; legible por todos | `x` en el campo 2 = shadowing activo. 7 campos, separados por `:` |
| `/etc/shadow` | Hashes + envejecimiento; solo root | 9 campos. Los campos 3, 5 y 8 son **días desde 1970-01-01** |
| `/etc/group`, `/etc/gshadow` | Identidad y secretos de grupo | `grpconv`/`grpunconv`, `gpasswd` |
| `/etc/login.defs` | Predeterminados para cuentas **nuevas** | `PASS_MAX_DAYS`, `PASS_MIN_DAYS`, `PASS_WARN_AGE`, `ENCRYPT_METHOD`, `UMASK` |
| `/etc/nologin` | Bloquea todos los inicios de sesión no root mientras exista | Root está exento; su contenido se le muestra al usuario |
| `/etc/inittab` | Runlevel predeterminado y acciones de SysV | `id:3:initdefault:` |
| `/etc/init.d/*` | Scripts de servicio de SysV | `update-rc.d` (Debian), `chkconfig` (RHEL), enlaces `S`/`K` en `rcN.d` |
| `/etc/inetd.conf` | Superservidor heredado | Comentar la línea para deshabilitar |
| `/etc/xinetd.conf` | `defaults { }` + `includedir /etc/xinetd.d` | Límites globales |
| `/etc/xinetd.d/*` | Un archivo por servicio | **`disable = yes`** deshabilita. `only_from`, `no_access` |
| Unidades `systemd.socket` | Activación por socket moderna | Deshabilitá el **`.socket`**, no solo el `.service` |
| `/etc/hosts.allow` | Reglas de permitir de los wrappers | Se lee **primero**; la primera coincidencia concede y detiene |
| `/etc/hosts.deny` | Reglas de denegar de los wrappers | Se lee **segundo**; `ALL: ALL` para denegar por defecto |

Referencia de comandos:

| Comando | Uso |
|---|---|
| `pwconv` / `pwunconv` | Habilitar / deshabilitar shadow passwords |
| `grpconv` / `grpunconv` | Lo mismo para grupos |
| `pwck -r` / `grpck -r` | Verificar la consistencia de la base de datos |
| `vipw` / `vigr` (`-s`) | Editar los archivos de cuentas bajo lock |
| `chage -l user` | Mostrar el envejecimiento; `-E 0` deshabilita la cuenta; `-d 0` fuerza un cambio |
| `passwd -S user` | Estado: `P` utilizable, `L` bloqueada, `NP` ninguna |
| `passwd -l` / `-u` / `-d` | Bloquear / desbloquear / **borrar** la contraseña |
| `usermod -L` / `-U` / `-s` | Bloquear / desbloquear / cambiar la shell |
| `getent passwd\|shadow\|group` | Consultar a través de NSS, no solo el archivo plano |
| `ss -tulpn` | Sockets a la escucha con el proceso dueño |
| `lsof -nP -iTCP -sTCP:LISTEN` | Lo mismo, vista alternativa |
| `systemctl list-sockets --all` | Unidades socket y qué activan |
| `systemctl disable --now` / `mask --now` | Apagar / hacer inarrancable |
| `systemctl list-unit-files --state=enabled` | Todo lo que arranca automáticamente |
| `chkconfig` / `update-rc.d` | Habilitar/deshabilitar en SysV y `xinetd` |
| `tcpdchk [-v]` | Validar la sintaxis de las reglas de los wrappers |
| `tcpdmatch <daemon> <client>` | Simular una decisión de acceso |
| `ldd $(command -v d) \| grep libwrap` | **¿Este daemon usa wrappers, siquiera?** |
| `systemd-analyze security <unit>` | Puntuar el sandboxing de una unidad |
| `nft -c -f file` / `nft list ruleset` | Chequear / mostrar el firewall |

Los tres hechos que más se pasan por alto:

1. **`hosts.allow` se evalúa primero y gana la primera coincidencia.** Ninguna regla de `hosts.deny` puede anularla.
2. **Deshabilitar un `.service` no cierra un puerto activado por socket.** Deshabilitá el `.socket`.
3. **Los campos de fecha de shadow son días desde la época, no timestamps.** `date -d "1970-01-01 + N days"`.

---

## 9. Referencias

**Objetivos de certificación de LPI**
- Objetivos del examen LPIC-1 101-500 — https://www.lpi.org/our-certifications/exam-101-objectives/
- Objetivos del examen LPIC-1 102-500 (el Tema 110 vive acá) — https://www.lpi.org/our-certifications/exam-102-objectives/
- Panorama de la certificación LPIC-1 — https://www.lpi.org/our-certifications/lpic-1-overview/

**Cuentas, shadow passwords y envejecimiento**
- `shadow(5)` — https://man7.org/linux/man-pages/man5/shadow.5.html
- `passwd(5)` — https://man7.org/linux/man-pages/man5/passwd.5.html
- `gshadow(5)` — https://man7.org/linux/man-pages/man5/gshadow.5.html
- `login.defs(5)` — https://man7.org/linux/man-pages/man5/login.defs.5.html
- `crypt(5)` — identificadores de formato de hash — https://man7.org/linux/man-pages/man5/crypt.5.html
- `chage(1)` — https://man7.org/linux/man-pages/man1/chage.1.html
- `passwd(1)` — https://man7.org/linux/man-pages/man1/passwd.1.html
- `pwconv(8)` / `pwunconv(8)` / `grpconv(8)` — https://man7.org/linux/man-pages/man8/pwconv.8.html
- `pwck(8)` — https://man7.org/linux/man-pages/man8/pwck.8.html
- `vipw(8)` / `vigr(8)` — https://man7.org/linux/man-pages/man8/vipw.8.html
- shadow-utils upstream — https://github.com/shadow-maint/shadow
- libxcrypt (la implementación de `libcrypt` en Linux moderno) — https://github.com/besser82/libxcrypt
- Especificación de yescrypt — https://www.openwall.com/yescrypt/
- NIST SP 800-63B, Digital Identity Guidelines: Authenticators — https://pages.nist.gov/800-63-3/sp800-63b.html

**Admisión de inicio de sesión**
- `nologin(5)` — el archivo `/etc/nologin` — https://man7.org/linux/man-pages/man5/nologin.5.html
- `nologin(8)` — la shell — https://man7.org/linux/man-pages/man8/nologin.8.html
- `pam_nologin(8)` — https://man7.org/linux/man-pages/man8/pam_nologin.8.html
- `pam_access(8)` y `access.conf(5)` — https://man7.org/linux/man-pages/man8/pam_access.8.html
- Guía de administradores de sistema de Linux-PAM — https://github.com/linux-pam/linux-pam/blob/master/doc/sag/Linux-PAM_SAG.xml

**Servicios, init y activación por socket**
- `systemd.socket(5)` — https://www.freedesktop.org/software/systemd/man/latest/systemd.socket.html
- `systemd.service(5)` — https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html
- `systemd.exec(5)` — directivas de sandboxing — https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html
- `systemctl(1)` — https://www.freedesktop.org/software/systemd/man/latest/systemctl.html
- `daemon(7)`, "Socket-Based Activation" — https://www.freedesktop.org/software/systemd/man/latest/daemon.html
- `sd_listen_fds(3)` — el protocolo `LISTEN_FDS` — https://www.freedesktop.org/software/systemd/man/latest/sd_listen_fds.html
- `systemd-socket-activate(1)` — https://www.freedesktop.org/software/systemd/man/latest/systemd-socket-activate.html
- `systemd-analyze(1)` — el verbo `security` — https://www.freedesktop.org/software/systemd/man/latest/systemd-analyze.html
- `inittab(5)` — https://man7.org/linux/man-pages/man5/inittab.5.html
- `init(8)` (sysvinit) — https://man7.org/linux/man-pages/man8/init.8.html
- `xinetd.conf(5)` — https://linux.die.net/man/5/xinetd.conf
- `xinetd(8)` — https://linux.die.net/man/8/xinetd
- `inetd.conf(5)` — https://man7.org/linux/man-pages/man5/inetd.conf.5.html
- `update-rc.d(8)` (Debian) — https://manpages.debian.org/stable/init-system-helpers/update-rc.d.8.en.html
- `chkconfig(8)` — https://linux.die.net/man/8/chkconfig
- `ss(8)` — https://man7.org/linux/man-pages/man8/ss.8.html
- `lsof(8)` — https://man7.org/linux/man-pages/man8/lsof.8.html

**TCP wrappers y sus reemplazos**
- `hosts_access(5)` — sintaxis de las reglas — https://man7.org/linux/man-pages/man5/hosts_access.5.html
- `hosts_options(5)` — el campo de opciones — https://man7.org/linux/man-pages/man5/hosts_options.5.html
- `tcpd(8)` — https://man7.org/linux/man-pages/man8/tcpd.8.html
- `tcpdchk(8)` — https://man7.org/linux/man-pages/man8/tcpdchk.8.html
- `tcpdmatch(8)` — https://man7.org/linux/man-pages/man8/tcpdmatch.8.html
- Notas de la versión OpenSSH 6.7 — eliminación del soporte de `libwrap` — https://www.openssh.com/txt/release-6.7
- NEWS de `systemd`, v212 — eliminación del soporte de tcpwrap — https://github.com/systemd/systemd/blob/main/NEWS
- Consideraciones al adoptar RHEL 8 — eliminación de `tcp_wrappers` — https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/8/html/considerations_in_adopting_rhel_8/
- Paquete `tcpd` de Debian — https://packages.debian.org/stable/tcpd
- Wiki de nftables — https://wiki.nftables.org/wiki-nftables/index.php/Main_Page
- `nft(8)` — https://www.netfilter.org/projects/nftables/manpage.html
- Documentación de firewalld — https://firewalld.org/documentation/
- `sshd_config(5)` — `Match`, `AllowGroups`, `ListenAddress` — https://man.openbsd.org/sshd_config

**Automatización y auditoría**
- Módulo `systemd_service` de Ansible — https://docs.ansible.com/ansible/latest/collections/ansible/builtin/systemd_service_module.html
- Módulo `user` de Ansible — https://docs.ansible.com/ansible/latest/collections/ansible/builtin/user_module.html
- Referencia de módulos de cloud-init — https://cloudinit.readthedocs.io/en/latest/reference/modules.html
- Linux Audit (`auditd`, `aureport`) — https://github.com/linux-audit/audit-userspace
- Lynis — https://cisofy.com/documentation/lynis/
- CIS Benchmarks — https://www.cisecurity.org/cis-benchmarks