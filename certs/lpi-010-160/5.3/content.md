# 5.3 Managing File Permissions and Ownership

**Peso en el examen:** 2
**Examen:** LPI Linux Essentials 010-160 (versión 1.6)

---

## Introducción

Linux es un sistema operativo multiusuario: varias personas (y servicios del sistema) pueden trabajar sobre los mismos archivos. Para controlar quién puede leer, modificar o ejecutar cada archivo, Linux asocia a cada archivo y directorio un **propietario (owner)**, un **grupo (group)** y un conjunto de **permisos (permissions)**. Este tema cubre cómo interpretar esa información y cómo modificarla con los comandos `chmod`, `chown` y `chgrp`.

---

## Usuarios, grupos y las tres categorías de acceso

Cada archivo pertenece a **un usuario** y a **un grupo**. A partir de eso, Linux evalúa los permisos según tres categorías:

| Categoría | Símbolo | Quién es |
|-----------|---------|----------|
| **user** (owner) | `u` | El usuario propietario del archivo |
| **group** | `g` | Los usuarios que pertenecen al grupo del archivo |
| **others** | `o` | Todos los demás usuarios del sistema |

El usuario **root** es la excepción: puede acceder a cualquier archivo sin importar los permisos.

Para saber quién sos y a qué grupos pertenecés:

```console
$ id
uid=1000(carla) gid=1000(carla) groups=1000(carla),10(wheel),972(docker)
```

---

## Leer los permisos: `ls -l`

El comando `ls -l` muestra los permisos en la primera columna:

```console
$ ls -l
-rwxr-xr--  1 carla developers  4096 jul  7 10:30 script.sh
drwxr-xr-x  2 carla developers  4096 jul  7 09:15 docs
lrwxrwxrwx  1 carla developers     9 jul  7 09:20 enlace -> script.sh
```

La primera columna tiene **10 caracteres**. Desglosemos `-rwxr-xr--`:

```
- rwx r-x r--
│  │   │   └── others: solo lectura
│  │   └────── group:  lectura y ejecución
│  └────────── user:   lectura, escritura y ejecución
└───────────── tipo de archivo
```

**Primer carácter — tipo de archivo:**

| Carácter | Tipo |
|----------|------|
| `-` | Archivo regular |
| `d` | Directorio |
| `l` | Symbolic link (enlace simbólico) |
| `b` | Block device (p. ej. discos) |
| `c` | Character device (p. ej. terminales) |
| `s` | Socket |
| `p` | Named pipe (FIFO) |

**Los 9 caracteres restantes** son tres tríos (user, group, others), cada uno con:

- `r` — **read** (lectura)
- `w` — **write** (escritura)
- `x` — **execute** (ejecución)
- `-` — permiso ausente

### Significado según archivo o directorio

Los mismos permisos significan cosas distintas:

| Permiso | En un archivo | En un directorio |
|---------|---------------|------------------|
| `r` | Leer el contenido | Listar los nombres de los archivos que contiene |
| `w` | Modificar el contenido | Crear, renombrar y borrar archivos dentro (requiere también `x`) |
| `x` | Ejecutarlo como programa | Entrar al directorio (`cd`) y acceder a sus archivos |

Un detalle que suele aparecer en el examen: **para borrar un archivo no hace falta permiso de escritura sobre el archivo, sino sobre el directorio que lo contiene**, porque borrar es modificar el contenido del directorio.

---

## Modificar permisos: `chmod`

`chmod` (change mode) acepta dos notaciones: **simbólica** y **octal (numérica)**.

### Notación simbólica

Se compone de: *a quién* (`u`, `g`, `o`, `a` = all) + *operación* (`+` agregar, `-` quitar, `=` fijar exactamente) + *permiso* (`r`, `w`, `x`).

```console
$ chmod u+x script.sh        # agrega ejecución al owner
$ chmod g-w informe.txt      # quita escritura al grupo
$ chmod o=r datos.csv        # others queda solo con lectura
$ chmod a+r README.md        # todos pueden leer
$ chmod u+rwx,g+rx,o-rwx app # varias reglas separadas por coma
```

Verificación:

```console
$ ls -l script.sh
-rwxr--r-- 1 carla developers 512 jul  7 11:02 script.sh
```

### Notación octal

Cada permiso tiene un valor numérico: `r = 4`, `w = 2`, `x = 1`. Se suman por categoría y se escriben tres dígitos (user, group, others):

| Octal | Permisos | Significado |
|-------|----------|-------------|
| `7` | `rwx` | 4+2+1 |
| `6` | `rw-` | 4+2 |
| `5` | `r-x` | 4+1 |
| `4` | `r--` | 4 |
| `0` | `---` | sin permisos |

Ejemplos típicos:

```console
$ chmod 755 script.sh   # rwxr-xr-x — típico de scripts y directorios
$ chmod 644 nota.txt    # rw-r--r-- — típico de archivos de datos
$ chmod 600 secreto.key # rw------- — solo el owner
$ chmod 777 compartido  # rwxrwxrwx — todos todo (¡evitar en general!)
```

### Recursividad

La opción `-R` aplica el cambio a un directorio y todo su contenido:

```console
$ chmod -R 755 /srv/www
```

---

## Cambiar propietario y grupo: `chown` y `chgrp`

### `chown` (change owner)

Cambia el propietario, el grupo, o ambos. **Cambiar el propietario requiere ser root** (normalmente vía `sudo`):

```console
$ sudo chown maria informe.txt          # cambia solo el owner
$ sudo chown maria:developers informe.txt  # cambia owner y grupo
$ sudo chown :developers informe.txt    # cambia solo el grupo
$ sudo chown -R maria:developers /home/maria/proyecto  # recursivo
```

Verificación:

```console
$ ls -l informe.txt
-rw-r--r-- 1 maria developers 2048 jul  7 11:30 informe.txt
```

### `chgrp` (change group)

Cambia solo el grupo. Un usuario común puede usarlo si es el owner del archivo **y** pertenece al grupo destino:

```console
$ chgrp developers informe.txt
$ chgrp -R developers /srv/proyecto
```

---

## Permisos especiales

Además de `rwx`, existen tres bits especiales que conviene reconocer para el examen:

### SUID (Set User ID) — octal `4xxx`

En un ejecutable, hace que el programa corra con los permisos del **owner** del archivo, no de quien lo ejecuta. Se muestra como `s` en la posición de `x` del usuario. Ejemplo clásico: `passwd`, que necesita privilegios de root para modificar `/etc/shadow`:

```console
$ ls -l /usr/bin/passwd
-rwsr-xr-x 1 root root 32648 jul  7 08:00 /usr/bin/passwd
```

### SGID (Set Group ID) — octal `2xxx`

En un ejecutable, corre con los permisos del **grupo** del archivo. En un **directorio**, los archivos nuevos heredan el grupo del directorio (útil en carpetas compartidas de equipos):

```console
$ sudo chmod g+s /srv/proyecto
$ ls -ld /srv/proyecto
drwxrwsr-x 2 root developers 4096 jul  7 11:45 /srv/proyecto
```

### Sticky bit — octal `1xxx`

En un directorio, impide que un usuario borre archivos de otros aunque tenga permiso de escritura sobre el directorio. Se muestra como `t` en la posición de `x` de others. El ejemplo canónico es `/tmp`:

```console
$ ls -ld /tmp
drwxrwxrwt 18 root root 4096 jul  7 12:00 /tmp
```

Aplicación con octal de cuatro dígitos:

```console
$ chmod 1777 /compartido   # sticky bit + rwx para todos
$ chmod 2775 /srv/proyecto # SGID en directorio de equipo
```

---

## Archivos ocultos

En Linux, un archivo cuyo nombre empieza con punto (`.`) es **oculto**: `ls` no lo muestra por defecto. No es un permiso, sino una convención, pero se relaciona con la visibilidad de archivos:

```console
$ ls -a ~
.  ..  .bashrc  .profile  documentos  script.sh
```

---

## Resumen de comandos

| Comando | Función | Ejemplo |
|---------|---------|---------|
| `ls -l` | Ver permisos y propietarios | `ls -l archivo` |
| `id` | Ver usuario y grupos propios | `id` |
| `chmod` | Cambiar permisos | `chmod 644 archivo` |
| `chown` | Cambiar owner (y grupo) | `sudo chown user:grupo archivo` |
| `chgrp` | Cambiar grupo | `chgrp grupo archivo` |

**Puntos clave para el examen:**

- Orden de los tríos: **user, group, others**.
- Valores octales: `r=4`, `w=2`, `x=1` (memorizar `755` y `644`).
- En directorios, `x` significa "entrar", `r` significa "listar", `w` significa "crear/borrar dentro".
- Solo root puede cambiar el owner de un archivo.
- SUID = `s` en user, SGID = `s` en group, sticky bit = `t` en others.

---

## Referencias

- LPI Learning Materials — Tema 5.3, Managing File Permissions and Ownership: https://learning.lpi.org/en/learning-materials/010-160/5/5.3/
- Página de manual de `chmod` (GNU coreutils): https://www.gnu.org/software/coreutils/manual/html_node/chmod-invocation.html
- Página de manual de `chown` (GNU coreutils): https://www.gnu.org/software/coreutils/manual/html_node/chown-invocation.html
- Página de manual de `chgrp` (GNU coreutils): https://www.gnu.org/software/coreutils/manual/html_node/chgrp-invocation.html
- Página de manual de `ls` (GNU coreutils): https://www.gnu.org/software/coreutils/manual/html_node/ls-invocation.html
- Objetivos del examen LPI Linux Essentials 010-160 v1.6: https://www.lpi.org/our-certifications/exam-010-objectives/