# 5.2 – Creating Users and Groups

**Peso en el examen: 2** · Examen 010-160 (versión 1.6)

## Introducción

En Linux, todo proceso y todo archivo pertenece a un usuario. Administrar usuarios y grupos correctamente es la base del modelo de seguridad del sistema: define quién puede iniciar sesión, qué archivos puede leer o modificar y qué comandos puede ejecutar. En este tema vas a aprender a crear usuarios y grupos, dónde se almacena esa información y qué comandos usar para gestionarla.

## Tipos de cuentas de usuario

En un sistema Linux conviven tres tipos de cuentas:

- **root (superuser):** la cuenta administrativa con **UID 0**. Tiene control total sobre el sistema, sin restricciones de permisos. Por seguridad, se recomienda no usarla para el trabajo diario.
- **Cuentas de sistema (system accounts):** las usan servicios y *daemons* (por ejemplo `mail`, `www-data`, `sshd`). Normalmente tienen UID menor a 1000, no tienen contraseña utilizable y su *shell* suele ser `/usr/sbin/nologin` o `/bin/false` para impedir el login interactivo.
- **Cuentas de usuario regulares:** las de las personas que usan el sistema. En la mayoría de las distribuciones reciben UID a partir de 1000.

Cada usuario se identifica internamente por un número: el **UID (User ID)**. De la misma manera, cada grupo tiene un **GID (Group ID)**.

## Grupos

Los grupos permiten asignar permisos a varios usuarios a la vez. Cada usuario tiene:

- Un **grupo primario (primary group):** se asigna a los archivos que el usuario crea. En muchas distribuciones (Debian, Ubuntu, Fedora) se usa el esquema **UPG (User Private Group)**: al crear un usuario se crea automáticamente un grupo con su mismo nombre.
- **Grupos secundarios (secondary/supplementary groups):** membresías adicionales que otorgan permisos extra, por ejemplo el grupo `sudo` (Debian/Ubuntu) o `wheel` (Fedora/CentOS) para tareas administrativas.

Para ver la identidad y los grupos del usuario actual se usa `id`:

```console
$ id
uid=1000(carol) gid=1000(carol) groups=1000(carol),27(sudo),999(docker)
```

También se puede consultar a otro usuario:

```console
$ id emma
uid=1001(emma) gid=1001(emma) groups=1001(emma)
```

## Archivos de configuración

La información de usuarios y grupos se guarda en archivos de texto plano dentro de `/etc`.

### /etc/passwd

Contiene una línea por usuario, con **siete campos** separados por `:`.

```console
$ grep carol /etc/passwd
carol:x:1000:1000:Carol Smith:/home/carol:/bin/bash
```

| Campo | Contenido |
|---|---|
| 1 | Nombre de usuario (login name) |
| 2 | Contraseña — una `x` indica que está en `/etc/shadow` |
| 3 | UID |
| 4 | GID del grupo primario |
| 5 | GECOS: comentario o nombre completo |
| 6 | Directorio home |
| 7 | Shell por defecto |

A pesar de su nombre, `/etc/passwd` ya **no guarda las contraseñas**: es legible por todos los usuarios, por lo que las contraseñas cifradas se movieron a `/etc/shadow`.

### /etc/shadow

Guarda las contraseñas cifradas (*hashed*) y la información de expiración. Solo es legible por `root`:

```console
$ sudo grep carol /etc/shadow
carol:$6$vNy...$hGf1...:20603:0:99999:7:::
```

Campos principales:

| Campo | Contenido |
|---|---|
| 1 | Nombre de usuario |
| 2 | Contraseña cifrada (`!` o `*` indica cuenta bloqueada o sin login) |
| 3 | Fecha del último cambio de contraseña (días desde el 1/1/1970) |
| 4 | Días mínimos entre cambios de contraseña |
| 5 | Días máximos de validez de la contraseña |
| 6 | Días de aviso antes de la expiración |
| 7–9 | Días de gracia, fecha de expiración de la cuenta, reservado |

### /etc/group

Define los grupos, con **cuatro campos** por línea:

```console
$ grep sudo /etc/group
sudo:x:27:carol,dave
```

| Campo | Contenido |
|---|---|
| 1 | Nombre del grupo |
| 2 | Contraseña del grupo (raramente usada; se guarda en `/etc/gshadow`) |
| 3 | GID |
| 4 | Lista de miembros (usuarios que lo tienen como grupo secundario), separados por comas |

## Creación de usuarios: useradd

El comando `useradd` crea una cuenta nueva. Requiere privilegios de `root`:

```console
$ sudo useradd -m -c "Emma Jones" -s /bin/bash emma
```

Opciones más usadas:

- `-m` — crea el directorio home (copiando el contenido de `/etc/skel`, que aporta los archivos de configuración iniciales como `.bashrc`).
- `-c` — establece el comentario/nombre completo (campo GECOS).
- `-s` — define el shell por defecto.
- `-d` — especifica un directorio home distinto del predeterminado.
- `-g` — asigna el grupo primario.
- `-G` — asigna grupos secundarios (lista separada por comas).
- `-u` — fija un UID específico.
- `-D` — muestra (o modifica) los valores por defecto de `useradd`, que también están en `/etc/default/useradd`.

Verificamos el resultado:

```console
$ grep emma /etc/passwd
emma:x:1001:1001:Emma Jones:/home/emma:/bin/bash
```

> **Nota:** en Debian/Ubuntu existe también `adduser`, un *script* interactivo más amigable que llama a `useradd` por debajo. Para el examen, el comando estándar es `useradd`.

La cuenta recién creada está bloqueada hasta que se le asigne una contraseña.

## Asignar contraseñas: passwd

`root` puede establecer la contraseña de cualquier usuario:

```console
$ sudo passwd emma
New password:
Retype new password:
passwd: password updated successfully
```

Un usuario regular puede cambiar **solo su propia** contraseña, y debe ingresar primero la actual:

```console
$ passwd
Changing password for carol.
Current password:
New password:
Retype new password:
passwd: password updated successfully
```

Opciones útiles (solo para root): `-l` bloquea la cuenta (*lock*), `-u` la desbloquea, `-S` muestra el estado de la contraseña.

## Creación de grupos: groupadd

```console
$ sudo groupadd developers
$ grep developers /etc/group
developers:x:1002:
```

Con `-g` se puede fijar un GID específico:

```console
$ sudo groupadd -g 2000 finance
```

Para agregar un usuario existente a un grupo secundario se usa `usermod -aG` (la `-a` de *append* es clave: sin ella se reemplazan todas las membresías secundarias):

```console
$ sudo usermod -aG developers emma
$ id emma
uid=1001(emma) gid=1001(emma) groups=1001(emma),1002(developers)
```

Comandos complementarios que conviene reconocer: `groupmod` (modificar un grupo), `groupdel` (eliminarlo), `userdel` (eliminar un usuario; con `-r` borra también su home) y `usermod` (modificar una cuenta existente).

## Consultar quién está en el sistema

- `who` — lista los usuarios con sesión iniciada, su terminal y hora de login:

```console
$ who
carol    tty2         2026-07-07 09:15
emma     pts/0        2026-07-07 10:02 (192.168.1.20)
```

- `w` — similar a `who`, pero agrega la carga del sistema y qué está ejecutando cada usuario:

```console
$ w
 10:05:33 up  2:11,  2 users,  load average: 0.08, 0.03, 0.01
USER     TTY      FROM             LOGIN@   IDLE   JCPU   PCPU WHAT
carol    tty2     -                09:15    3:10   0.20s  0.05s bash
emma     pts/0    192.168.1.20     10:02    0.00s  0.10s  0.02s w
```

- `last` — muestra el historial de logins leyendo `/var/log/wtmp`.

## Resumen de comandos y archivos clave

| Elemento | Función |
|---|---|
| `useradd` | Crear cuentas de usuario |
| `groupadd` | Crear grupos |
| `passwd` | Asignar o cambiar contraseñas |
| `usermod` / `userdel` | Modificar / eliminar usuarios |
| `id`, `who`, `w` | Consultar identidad y sesiones |
| `/etc/passwd` | Datos de las cuentas (7 campos) |
| `/etc/shadow` | Contraseñas cifradas y expiración (solo root) |
| `/etc/group` | Grupos y sus miembros (4 campos) |
| `/etc/skel` | Plantilla del home de los usuarios nuevos |

## Referencias

- LPI Learning Materials — Topic 5.2, Creating Users and Groups: https://learning.lpi.org/en/learning-materials/010-160/5/5.2/
- Objetivos del examen Linux Essentials 010-160: https://www.lpi.org/our-certifications/exam-010-objectives/
- man page de `useradd`: https://man7.org/linux/man-pages/man8/useradd.8.html
- man page de `groupadd`: https://man7.org/linux/man-pages/man8/groupadd.8.html
- man page de `passwd`: https://man7.org/linux/man-pages/man1/passwd.1.html
- man page de `passwd(5)` (formato de /etc/passwd): https://man7.org/linux/man-pages/man5/passwd.5.html
- man page de `shadow(5)` (formato de /etc/shadow): https://man7.org/linux/man-pages/man5/shadow.5.html
- man page de `group(5)` (formato de /etc/group): https://man7.org/linux/man-pages/man5/group.5.html