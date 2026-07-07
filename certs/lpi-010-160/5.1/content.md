# 5.1 Basic Security and Identifying User Types

**Peso en el examen: 2** — Examen 010-160, versión 1.6

---

## Introducción

Linux es un sistema operativo **multiusuario**: varias personas (y procesos) pueden usar el sistema al mismo tiempo, cada una con su propia cuenta, permisos y espacio de trabajo. La base de la seguridad en Linux está en distinguir correctamente los **tipos de usuarios** y en saber quién está haciendo qué en el sistema. Este tema cubre los tres tipos de cuentas (root, usuarios estándar y usuarios de sistema), los archivos donde se define esa información, y los comandos para identificar usuarios y cambiar de identidad de forma segura.

---

## Tipos de usuarios

### 1. El superusuario: `root`

- Es la cuenta administrativa del sistema, con **UID 0** (User ID cero).
- Puede hacer **cualquier cosa**: leer, modificar o borrar cualquier archivo, instalar software, administrar usuarios, cambiar configuraciones del sistema.
- Precisamente por eso es peligroso usarla para el trabajo diario: un error de tipeo como root puede destruir el sistema (por ejemplo, un `rm` mal escrito).
- **Buena práctica de seguridad**: trabajar siempre como usuario estándar y elevar privilegios solo cuando sea necesario, con `su` o `sudo`.

### 2. Usuarios estándar (regular users)

- Son las cuentas de personas reales que inician sesión en el sistema.
- Tienen un **home directory** propio (por ejemplo `/home/carla`) y un **login shell** (por ejemplo `/bin/bash`).
- En la mayoría de las distribuciones modernas sus UID comienzan en **1000** (en algunas más antiguas, como Red Hat/CentOS viejos, en 500).
- Solo pueden modificar sus propios archivos y los que sus permisos les permitan.

### 3. Usuarios de sistema (system users / service accounts)

- Cuentas creadas para que los **servicios y daemons** (servidores web, bases de datos, impresión, etc.) corran con privilegios limitados, no como root.
- Ejemplos típicos: `www-data` (Apache/Nginx en Debian), `mysql`, `daemon`, `mail`, `sshd`.
- Suelen tener UID entre **1 y 999**.
- Normalmente **no pueden iniciar sesión**: su shell es `/usr/sbin/nologin` o `/bin/false`, y muchas veces no tienen password ni home directory real.
- Beneficio de seguridad: si un servicio es comprometido, el atacante queda limitado a los permisos de esa cuenta de sistema, no a los de root.

**Resumen de rangos de UID (convención moderna):**

| Tipo de usuario | UID típico | Ejemplo |
|---|---|---|
| Superusuario | 0 | `root` |
| Usuarios de sistema | 1–999 | `www-data`, `mysql` |
| Usuarios estándar | 1000+ | `carla`, `tux` |

---

## Dónde se define la información de usuarios y grupos

### `/etc/passwd`

Contiene una línea por usuario, con 7 campos separados por `:`

```
$ grep carla /etc/passwd
carla:x:1000:1000:Carla Gomez:/home/carla:/bin/bash
```

Los campos son:

1. **Username**: `carla`
2. **Password**: `x` indica que el password real está en `/etc/shadow`
3. **UID**: `1000`
4. **GID**: grupo primario, `1000`
5. **GECOS**: comentario/nombre completo, `Carla Gomez`
6. **Home directory**: `/home/carla`
7. **Login shell**: `/bin/bash`

A pesar del nombre, `/etc/passwd` **no contiene contraseñas** en los sistemas modernos y es legible por todos los usuarios.

### `/etc/shadow`

Guarda los **hashes de las contraseñas** y la información de expiración. Solo es legible por root, justamente para proteger los hashes de ataques de fuerza bruta:

```
$ sudo head -1 /etc/shadow
root:$6$XxXxXx...$yYyYy...:19750:0:99999:7:::
```

### `/etc/group`

Define los **grupos** del sistema y sus miembros:

```
$ grep sudo /etc/group
sudo:x:27:carla,tux
```

Campos: nombre del grupo, password (en desuso), **GID**, y lista de miembros. Cada usuario tiene un grupo primario (el GID de `/etc/passwd`) y puede pertenecer a grupos suplementarios.

---

## Identificar usuarios: `id`, `whoami`, `who`, `w`, `last`

### `id` — ¿quién soy y a qué grupos pertenezco?

```
$ id
uid=1000(carla) gid=1000(carla) groups=1000(carla),27(sudo),100(users)

$ id tux
uid=1001(tux) gid=1001(tux) groups=1001(tux)
```

Muestra UID, GID primario y todos los grupos del usuario. Es la forma más rápida de verificar si una cuenta es de sistema o estándar (mirando el UID).

### `whoami` — nombre del usuario efectivo actual

```
$ whoami
carla
```

Útil dentro de scripts o después de cambiar de identidad con `su`.

### `who` — ¿quién está conectado?

```
$ who
carla    tty2         2026-07-07 09:15
tux      pts/0        2026-07-07 10:02 (192.168.1.50)
```

Muestra usuarios con sesión activa, la terminal que usan, y desde dónde se conectaron.

### `w` — ¿quién está conectado y qué está haciendo?

```
$ w
 10:15:33 up  3:02,  2 users,  load average: 0.12, 0.09, 0.05
USER     TTY      FROM             LOGIN@   IDLE   JCPU   PCPU WHAT
carla    tty2     -                09:15    5:00   0.20s  0.05s vim notas.txt
tux      pts/0    192.168.1.50     10:02    0.00s  0.10s  0.02s w
```

Como `who`, pero agrega uptime, carga del sistema y el comando que cada usuario está ejecutando.

### `last` — historial de logins

```
$ last
tux      pts/0    192.168.1.50     Tue Jul  7 10:02   still logged in
carla    tty2                      Tue Jul  7 09:15   still logged in
reboot   system boot 6.8.0-generic Tue Jul  7 07:13   still running
```

Lee el archivo `/var/log/wtmp` y muestra el historial de inicios de sesión y reinicios. Existe también `lastb` (solo root), que muestra los **intentos fallidos** de login desde `/var/log/btmp` — muy útil para detectar intentos de intrusión.

---

## Cambiar de identidad: `su` y `sudo`

### `su` (substitute user)

Abre una sesión como otro usuario. Sin argumentos, cambia a root y pide **la contraseña de root**:

```
$ su -
Password:
# whoami
root
```

El guion (`su -` o `su - usuario`) inicia un **login shell** completo, cargando el entorno del usuario destino. Para salir, `exit` o `Ctrl+D`.

### `sudo` (superuser do)

Ejecuta **un solo comando** con privilegios elevados, pidiendo **la contraseña del propio usuario** (no la de root):

```
$ sudo apt update
[sudo] password for carla:
...
```

Ventajas de `sudo` sobre `su`:

- No hace falta compartir la contraseña de root.
- Cada comando queda **registrado en los logs** (auditoría: quién ejecutó qué y cuándo).
- Los privilegios se otorgan de forma granular en `/etc/sudoers`, que se edita **siempre con `visudo`** (valida la sintaxis antes de guardar y evita dejar el sistema sin acceso administrativo).
- En muchas distribuciones (Debian/Ubuntu) el acceso se controla por pertenencia a un grupo: `sudo` en Debian/Ubuntu, `wheel` en Fedora/RHEL.

En Ubuntu, de hecho, la cuenta root viene **bloqueada por defecto** y toda la administración se hace vía `sudo`.

Para obtener una shell de root vía sudo:

```
$ sudo -i
# whoami
root
```

---

## Buenas prácticas de seguridad básicas

- **Principio de menor privilegio**: usar la cuenta con los mínimos permisos necesarios para cada tarea; elevar privilegios solo cuando haga falta y por el menor tiempo posible.
- **No iniciar sesión como root** para el trabajo cotidiano; preferir `sudo` para tareas administrativas puntuales.
- **Una cuenta por persona**: nunca compartir cuentas ni contraseñas, para mantener la trazabilidad de las acciones.
- **Contraseñas fuertes**: largas, únicas por servicio, y cambiadas si se sospecha compromiso. Se cambian con `passwd` (root puede cambiar la de cualquier usuario con `passwd usuario`).
- **Bloquear la pantalla o cerrar sesión** al dejar la máquina desatendida.
- **Revisar logins** periódicamente con `last` y `lastb` para detectar accesos sospechosos.

---

## Comandos clave para el examen

| Comando | Función |
|---|---|
| `id` | Mostrar UID, GID y grupos de un usuario |
| `whoami` | Mostrar el usuario efectivo actual |
| `who` | Listar usuarios con sesión iniciada |
| `w` | Como `who`, más carga del sistema y actividad |
| `last` / `lastb` | Historial de logins / intentos fallidos |
| `su -` | Cambiar de usuario (pide el password del destino) |
| `sudo comando` | Ejecutar un comando con privilegios (pide tu propio password) |
| `visudo` | Editar `/etc/sudoers` de forma segura |
| `passwd` | Cambiar contraseña |

Archivos clave: `/etc/passwd` (cuentas), `/etc/shadow` (hashes de passwords, solo root), `/etc/group` (grupos), `/etc/sudoers` (configuración de sudo).

---

## Referencias

- LPI Learning Materials — Tema 5.1, Basic Security and Identifying User Types: https://learning.lpi.org/en/learning-materials/010-160/5/5.1/
- Objetivos del examen Linux Essentials 010-160 (v1.6): https://www.lpi.org/our-certifications/exam-010-objectives/
- Manual de `sudo`: https://www.sudo.ws/docs/man/sudo.man/
- Documentación de `passwd(5)` (formato de /etc/passwd): https://man7.org/linux/man-pages/man5/passwd.5.html
- Documentación de `shadow(5)`: https://man7.org/linux/man-pages/man5/shadow.5.html
- Documentación de `id(1)`: https://man7.org/linux/man-pages/man1/id.1.html
- Documentación de `last(1)`: https://man7.org/linux/man-pages/man1/last.1.html