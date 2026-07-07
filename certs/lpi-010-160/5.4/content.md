# 5.4 Special Directories and Files

**Peso en el examen:** 1
**Objetivos clave:** archivos y directorios temporales, permisos especiales (*sticky bit*), enlaces simbólicos y enlaces duros (*symbolic links* y *hard links*).

---

## 1. Directorios temporales: /tmp, /var/tmp y /run

Linux ofrece directorios especiales donde cualquier usuario y programa puede escribir archivos temporales:

| Directorio | Propósito | Persistencia |
|---|---|---|
| `/tmp` | Archivos temporales de uso general | Se borra normalmente al reiniciar (en muchas distros es un *tmpfs* en RAM) |
| `/var/tmp` | Archivos temporales que deben sobrevivir a un reinicio | Persistente entre reinicios |
| `/run` | Información volátil de procesos en ejecución (PID files, sockets) | Siempre en RAM, se vacía en cada arranque |

La regla práctica: si el archivo puede desaparecer al reiniciar, va en `/tmp`; si debe conservarse un tiempo más largo (por ejemplo, la sesión de un editor que se recupera tras un corte de energía), va en `/var/tmp`.

```bash
$ ls -ld /tmp /var/tmp /run
drwxrwxrwt 15 root root  360 jul  7 09:12 /tmp
drwxrwxrwt  8 root root 4096 jul  6 22:40 /var/tmp
drwxr-xr-x 32 root root  920 jul  7 08:01 /run
```

Fijate en la `t` al final de los permisos de `/tmp` y `/var/tmp`: es el *sticky bit*, que vemos a continuación.

## 2. El sticky bit

`/tmp` tiene permisos `rwxrwxrwx` (todos pueden escribir). Sin protección adicional, cualquier usuario podría borrar los archivos de otro, porque borrar un archivo depende de los permisos del **directorio**, no del archivo.

El *sticky bit* (representado como `t` en la posición de ejecución de "others") resuelve esto: en un directorio con sticky bit, **solo el dueño del archivo (o root) puede borrarlo o renombrarlo**, aunque el directorio sea escribible por todos.

```bash
# Crear un directorio compartido con sticky bit
$ mkdir /shared
$ chmod 1777 /shared      # el "1" inicial activa el sticky bit
$ ls -ld /shared
drwxrwxrwt 2 root root 4096 jul  7 10:30 /shared
```

En notación simbólica: `chmod +t /shared`. Si el directorio no tuviera permiso de ejecución para "others", el bit se mostraría como `T` mayúscula.

## 3. Enlaces (links)

En Linux, un nombre de archivo es solo una referencia a un *inode* (la estructura que contiene los datos y metadatos reales). Esto permite que un mismo contenido tenga varios nombres, mediante dos tipos de enlaces.

### 3.1 Hard links (enlaces duros)

Un *hard link* es un segundo nombre que apunta **al mismo inode**. Se crea con `ln` (sin opciones):

```bash
$ echo "contenido" > original.txt
$ ln original.txt copia.txt
$ ls -li original.txt copia.txt
5253048 -rw-r--r-- 2 carol carol 10 jul  7 10:45 copia.txt
5253048 -rw-r--r-- 2 carol carol 10 jul  7 10:45 original.txt
```

Observaciones importantes:
- Ambos archivos comparten el **mismo número de inode** (5253048) — son literalmente el mismo archivo con dos nombres.
- El `2` después de los permisos es el **contador de enlaces** (*link count*).
- Borrar uno de los nombres **no borra los datos**: el contenido se elimina recién cuando el contador llega a 0.
- Limitaciones: no pueden cruzar sistemas de archivos (particiones) y no pueden apuntar a directorios.

### 3.2 Symbolic links (enlaces simbólicos o soft links)

Un *symbolic link* (symlink) es un archivo especial que contiene la **ruta** de otro archivo. Se crea con `ln -s`:

```bash
$ ln -s original.txt enlace.txt
$ ls -l enlace.txt
lrwxrwxrwx 1 carol carol 12 jul  7 10:50 enlace.txt -> original.txt
```

Características:
- El primer carácter de los permisos es `l` (link) y la salida muestra `nombre -> destino`.
- Sus permisos siempre aparecen como `rwxrwxrwx`, pero **no aplican**: rigen los permisos del archivo destino.
- **Pueden** cruzar sistemas de archivos y apuntar a directorios.
- Si se borra o mueve el destino, el enlace queda "roto" (*dangling link*) y apunta a la nada.

Para ver a dónde apunta un enlace:

```bash
$ readlink enlace.txt
original.txt
$ readlink -f enlace.txt     # ruta absoluta resuelta
/home/carol/original.txt
```

Un uso muy común en el sistema son los enlaces a bibliotecas y binarios:

```bash
$ ls -l /usr/bin/vi
lrwxrwxrwx 1 root root 20 mar  3 12:00 /usr/bin/vi -> /etc/alternatives/vi
```

### 3.3 Comparación rápida

| Característica | Hard link | Symbolic link |
|---|---|---|
| Comando | `ln origen destino` | `ln -s origen destino` |
| Inode | El mismo que el original | Inode propio |
| Cruza particiones | No | Sí |
| Apunta a directorios | No | Sí |
| Si se borra el original | Los datos siguen existiendo | El enlace queda roto |

**Consejo práctico:** al crear symlinks con rutas relativas, la ruta se interpreta desde la ubicación **del enlace**, no desde donde ejecutás el comando. Ante la duda, usá rutas absolutas o creá el enlace parado en el directorio destino.

## 4. Puntos clave para el examen

- `/tmp` y `/var/tmp` son escribibles por todos; la diferencia es la persistencia tras reiniciar.
- El sticky bit (`t`, valor octal `1000`, ej. `chmod 1777`) impide borrar archivos ajenos en directorios compartidos.
- `ln` crea hard links; `ln -s` crea symlinks.
- El link count en `ls -l` cuenta los hard links de un inode; `ls -i` muestra el número de inode.
- Un symlink roto apunta a un destino que ya no existe.

---

## Referencias

- LPI Learning Materials — Topic 5.4 Special Directories and Files: https://learning.lpi.org/en/learning-materials/010-160/5/5.4/
- Objetivos del examen Linux Essentials 010-160 v1.6: https://www.lpi.org/our-certifications/exam-010-objectives/
- Manual de `ln` (GNU coreutils): https://www.gnu.org/software/coreutils/manual/html_node/ln-invocation.html
- Filesystem Hierarchy Standard (FHS 3.0): https://refspecs.linuxfoundation.org/FHS_3.0/fhs/index.html
- Página de manual de `chmod`: https://man7.org/linux/man-pages/man1/chmod.1.html