# 2.2 — Using the Command Line to Get Help

**Peso en el examen: 2** · Examen 010-160 (versión 1.6)

## Introducción

Nadie memoriza todas las opciones de todos los comandos de Linux: el sistema incluye su propia documentación integrada, accesible directamente desde la terminal, sin conexión a Internet. Este tema cubre las herramientas principales para consultarla: la opción `--help`, las **man pages**, las **info pages**, los comandos de búsqueda de documentación (`apropos`, `whatis`) y la localización de archivos con `locate`.

---

## 1. La opción `--help`

La forma más rápida de obtener ayuda es pedírsela al propio comando. La gran mayoría de los programas acepta la opción `--help` (y muchos también `-h`), que imprime un resumen de uso y las opciones disponibles:

```bash
$ mkdir --help
Usage: mkdir [OPTION]... DIRECTORY...
Create the DIRECTORY(ies), if they do not already exist.

Mandatory arguments to long options are mandatory for short options too.
  -m, --mode=MODE   set file mode (as in chmod), not a=rwx - umask
  -p, --parents     no error if existing, make parent directories as needed
  -v, --verbose     print a message for each created directory
      --help        display this help and exit
      --version     display version information and exit
```

Es ideal para un recordatorio rápido de la sintaxis, pero no reemplaza a la documentación completa.

---

## 2. Man pages (páginas de manual)

El comando `man` (de *manual*) muestra la documentación oficial de un comando, archivo de configuración o llamada al sistema:

```bash
$ man mkdir
```

La página se abre en un *pager* (normalmente `less`). Teclas útiles dentro del pager:

| Tecla | Acción |
|---|---|
| `Espacio` / `b` | Avanzar / retroceder una página |
| `↑` `↓` | Desplazarse línea por línea |
| `/texto` | Buscar `texto` hacia adelante |
| `n` / `N` | Siguiente / anterior coincidencia |
| `q` | Salir |

### Estructura de una man page

Las páginas siguen un formato estándar. Las secciones internas más comunes son:

- **NAME**: nombre del comando y descripción de una línea.
- **SYNOPSIS**: sintaxis de uso (los corchetes `[ ]` indican elementos opcionales).
- **DESCRIPTION**: explicación detallada.
- **OPTIONS**: cada opción y su significado.
- **EXAMPLES**: ejemplos de uso (no siempre presente).
- **FILES**: archivos relacionados (por ejemplo, de configuración).
- **SEE ALSO**: comandos y páginas relacionadas.

### Las secciones del manual

El manual está dividido en **9 secciones numeradas**, porque un mismo nombre puede existir en varios contextos:

| Sección | Contenido |
|---|---|
| 1 | Comandos de usuario |
| 2 | System calls (llamadas al sistema) |
| 3 | Funciones de bibliotecas de C |
| 4 | Archivos especiales y drivers (p. ej. `/dev`) |
| 5 | Formatos de archivos y archivos de configuración |
| 6 | Juegos |
| 7 | Misceláneas, convenciones y protocolos |
| 8 | Comandos de administración del sistema |
| 9 | Rutinas del kernel |

Por defecto `man` muestra la primera coincidencia que encuentra. Para elegir la sección, se indica el número antes del nombre. El ejemplo clásico es `passwd`, que existe como comando y como archivo de configuración:

```bash
$ man 1 passwd    # el comando para cambiar la contraseña
$ man 5 passwd    # el formato del archivo /etc/passwd
```

Por convención, las páginas se citan con la sección entre paréntesis: `passwd(1)`, `passwd(5)`.

---

## 3. Buscar en la documentación: `apropos` y `whatis`

Cuando no se conoce el nombre exacto del comando, `apropos` busca una palabra clave en los nombres y descripciones cortas de todas las man pages:

```bash
$ apropos compress
bzip2 (1)            - a block-sorting file compressor, v1.0.8
gzip (1)             - compress or expand files
xz (1)               - Compress or decompress .xz and .lzma files
zcat (1)             - compress or expand files
...
```

El comando `man -k` es equivalente a `apropos`:

```bash
$ man -k compress
```

`whatis` (equivalente a `man -f`) hace lo contrario: dado un nombre exacto, muestra su descripción de una línea y en qué secciones existe:

```bash
$ whatis passwd
passwd (1)           - change user password
passwd (5)           - the password file
```

> **Nota:** estas herramientas consultan una base de datos que se regenera periódicamente con el comando `mandb`. En un sistema recién instalado puede ser necesario ejecutarlo (como root) si `apropos` no devuelve resultados.

---

## 4. Info pages

El proyecto GNU mantiene un segundo sistema de documentación, generalmente más extenso y didáctico que las man pages: las **info pages**. Se organizan como documentos con nodos enlazados entre sí (similar a hipertexto):

```bash
$ info mkdir
```

Navegación básica dentro de `info`:

| Tecla | Acción |
|---|---|
| `Espacio` | Avanzar |
| `n` / `p` | Nodo siguiente / anterior |
| `u` | Subir al nodo padre |
| `Enter` | Seguir el enlace bajo el cursor |
| `q` | Salir |

Ejecutar `info` sin argumentos muestra el índice general de toda la documentación instalada. Para muchos comandos GNU (como los de *coreutils*), la info page es la documentación de referencia más completa.

---

## 5. Documentación en `/usr/share/doc/`

Muchos paquetes instalan documentación adicional (README, changelogs, ejemplos de configuración, licencias) en un subdirectorio de `/usr/share/doc/` con el nombre del paquete:

```bash
$ ls /usr/share/doc/bash/
CHANGES  COMPAT  INTRO  NEWS  README  RESTART  examples/
```

Es un buen lugar para buscar ejemplos y notas del desarrollador que no aparecen en las man pages.

---

## 6. Localizar archivos y comandos

Aunque el foco del tema es la documentación, el objetivo incluye herramientas para encontrar archivos y programas en el sistema.

### `locate`

Busca nombres de archivo en una base de datos precompilada, por lo que es muy rápido:

```bash
$ locate crontab
/etc/crontab
/usr/bin/crontab
/usr/share/man/man1/crontab.1.gz
/usr/share/man/man5/crontab.5.gz
```

La base de datos se actualiza con `updatedb` (normalmente ejecutado a diario de forma automática; se puede forzar como root). Un archivo creado hace instantes puede no aparecer hasta la próxima actualización. Opciones útiles: `locate -i` (ignora mayúsculas/minúsculas) y `locate -c` (solo cuenta las coincidencias).

### `find`

A diferencia de `locate`, `find` recorre el sistema de archivos en tiempo real (más lento, pero siempre actualizado) y permite criterios más ricos:

```bash
$ find /usr/share/doc -name "README*"
```

### `which`, `whereis` y `type`

- **`which`** muestra la ruta del ejecutable que se ejecutaría, buscando en los directorios de la variable `PATH`:

  ```bash
  $ which mkdir
  /usr/bin/mkdir
  ```

- **`whereis`** además del binario localiza sus man pages y archivos fuente:

  ```bash
  $ whereis mkdir
  mkdir: /usr/bin/mkdir /usr/share/man/man1/mkdir.1.gz
  ```

- **`type`** (built-in del shell) indica cómo interpreta el shell un nombre: comando externo, built-in, alias o función:

  ```bash
  $ type cd
  cd is a shell builtin
  $ type mkdir
  mkdir is /usr/bin/mkdir
  ```

---

## Resumen para el examen

- `comando --help`: ayuda rápida integrada en el propio programa.
- `man comando`: documentación de referencia; el manual tiene 9 secciones (`man 5 passwd` para el archivo, `man 1 passwd` para el comando).
- `apropos` / `man -k`: buscar por palabra clave cuando no se sabe el nombre del comando.
- `whatis` / `man -f`: descripción breve de un nombre exacto.
- `info`: documentación GNU extendida, organizada en nodos navegables.
- `/usr/share/doc/`: documentación adicional de los paquetes instalados.
- `locate` (rápido, usa base de datos actualizada por `updatedb`) vs. `find` (búsqueda en tiempo real).
- `which`, `whereis`, `type`: localizar ejecutables y saber cómo los resuelve el shell.

---

## Referencias

- LPI Learning Materials — Lección 2.2, Using the Command Line to Get Help: https://learning.lpi.org/en/learning-materials/010-160/2/2.2/
- Objetivos oficiales del examen Linux Essentials 010-160 (v1.6): https://www.lpi.org/our-certifications/exam-010-objectives/
- man-pages — proyecto de documentación del kernel y userspace de Linux: https://www.kernel.org/doc/man-pages/
- GNU Coreutils Manual (info pages en línea): https://www.gnu.org/software/coreutils/manual/
- Documentación de GNU Texinfo (sistema de info pages): https://www.gnu.org/software/texinfo/