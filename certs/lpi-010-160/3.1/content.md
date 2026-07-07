# Tema 3.1 — Archiving Files on the Command Line

**Certificación:** LPI Linux Essentials (010-160, versión 1.6)
**Peso en el examen:** 2

---

## 1. Conceptos: archiving vs. compression

En Linux, **archivar** y **comprimir** son dos operaciones distintas que suelen usarse juntas:

- **Archiving (archivado):** agrupar varios archivos y directorios en un único archivo contenedor, preservando estructura de directorios, permisos y timestamps. La herramienta clásica es `tar` (*tape archive*).
- **Compression (compresión):** reducir el tamaño de un archivo aplicando un algoritmo. Las herramientas típicas son `gzip`, `bzip2` y `xz`, que comprimen **un solo archivo** cada una.

Por eso el flujo habitual es: `tar` empaqueta → `gzip`/`bzip2`/`xz` comprime el resultado. De ahí vienen las extensiones dobles como `.tar.gz`. La excepción es `zip`, que archiva y comprime en un solo paso (y es el formato más interoperable con Windows).

| Herramienta | Extensión típica | Función |
|---|---|---|
| `tar` | `.tar` | Solo archiva (sin comprimir) |
| `gzip` | `.gz` / `.tar.gz` / `.tgz` | Compresión rápida, la más común |
| `bzip2` | `.bz2` / `.tar.bz2` | Mejor ratio que gzip, más lento |
| `xz` | `.xz` / `.tar.xz` | Mejor ratio de los tres, el más lento |
| `zip` / `unzip` | `.zip` | Archiva + comprime; compatible con Windows |

Regla mnemotécnica de rendimiento: **gzip = rápido**, **xz = comprime más**, **bzip2 = punto intermedio**.

---

## 2. tar: el archivador universal

### Opciones esenciales

Las tres operaciones principales (se usa **una sola** por comando):

- `-c` (*create*): crear un archive.
- `-t` (*list*): listar el contenido sin extraer.
- `-x` (*extract*): extraer.

Modificadores frecuentes:

- `-f archivo`: nombre del archive (casi siempre necesaria; debe ir **última** si se agrupan opciones, porque toma un argumento).
- `-v` (*verbose*): mostrar los archivos procesados.
- `-z`: comprimir/descomprimir con **gzip**.
- `-j`: comprimir/descomprimir con **bzip2**.
- `-J`: comprimir/descomprimir con **xz**.
- `-C directorio`: cambiar al directorio indicado antes de operar (útil al extraer en otra ubicación).

Truco para el examen: la letra de compresión se asocia al nombre — `z` → g**z**ip, `j` → **bz**ip2 (la "j" está al lado de la "b" conceptualmente), `J` mayúscula → xz (el más "grande" en esfuerzo).

### Crear un archive

```console
$ tar -cvf backup.tar Documentos/
Documentos/
Documentos/informe.odt
Documentos/notas.txt
Documentos/fotos/logo.png
```

Con compresión gzip en un solo paso:

```console
$ tar -czvf backup.tar.gz Documentos/
```

Con bzip2 o xz:

```console
$ tar -cjvf backup.tar.bz2 Documentos/
$ tar -cJvf backup.tar.xz Documentos/
```

### Listar el contenido

```console
$ tar -tf backup.tar.gz
Documentos/
Documentos/informe.odt
Documentos/notas.txt
Documentos/fotos/logo.png
```

Con `-tvf` se muestran además permisos, propietario, tamaño y fecha, en un formato similar a `ls -l`:

```console
$ tar -tvf backup.tar.gz
drwxr-xr-x carol/carol       0 2026-07-01 10:32 Documentos/
-rw-r--r-- carol/carol   24576 2026-07-01 10:30 Documentos/informe.odt
-rw-r--r-- carol/carol    1204 2026-06-28 09:15 Documentos/notas.txt
```

### Extraer

```console
$ tar -xvf backup.tar.gz
Documentos/
Documentos/informe.odt
...
```

Las versiones modernas de GNU `tar` detectan la compresión automáticamente al extraer, por lo que `-z`/`-j`/`-J` no son obligatorias en ese caso. Para extraer en otro directorio:

```console
$ tar -xf backup.tar.gz -C /tmp/restauracion/
```

Para extraer solo un archivo específico:

```console
$ tar -xf backup.tar.gz Documentos/notas.txt
```

> **Nota:** en GNU `tar` el guion es opcional (`tar xvf` equivale a `tar -xvf`); en el examen pueden aparecer ambas formas.

---

## 3. gzip, bzip2 y xz: compresores de un solo archivo

Estas herramientas comprimen archivos individuales y, por defecto, **reemplazan el original** por la versión comprimida:

```console
$ ls -l datos.log
-rw-r--r-- 1 carol carol 1048576 jul  7 11:02 datos.log
$ gzip datos.log
$ ls -l datos.log.gz
-rw-r--r-- 1 carol carol   54321 jul  7 11:02 datos.log.gz
```

Para descomprimir:

```console
$ gunzip datos.log.gz        # o: gzip -d datos.log.gz
$ bunzip2 datos.log.bz2      # o: bzip2 -d
$ unxz datos.log.xz          # o: xz -d
```

Opciones útiles comunes a las tres:

- `-d`: descomprimir.
- `-k` (*keep*): conservar el archivo original.
- `-1` a `-9`: nivel de compresión (más alto = más compresión, más lento).

Para inspeccionar archivos comprimidos sin descomprimirlos existen variantes como `zcat`, `bzcat` y `xzcat`:

```console
$ zcat datos.log.gz | head -n 2
2026-07-07 11:00:01 INFO servicio iniciado
2026-07-07 11:00:05 INFO conexión aceptada
```

---

## 4. zip y unzip

`zip` crea archives comprimidos compatibles con prácticamente cualquier sistema operativo. A diferencia de `tar`, hay que usar `-r` para incluir directorios de forma recursiva:

```console
$ zip -r proyecto.zip Documentos/
  adding: Documentos/ (stored 0%)
  adding: Documentos/informe.odt (deflated 62%)
  adding: Documentos/notas.txt (deflated 48%)
```

Listar el contenido sin extraer:

```console
$ unzip -l proyecto.zip
Archive:  proyecto.zip
  Length      Date    Time    Name
---------  ---------- -----   ----
        0  2026-07-01 10:32   Documentos/
    24576  2026-07-01 10:30   Documentos/informe.odt
     1204  2026-06-28 09:15   Documentos/notas.txt
---------                     -------
    25780                     3 files
```

Extraer (todo, o a un directorio específico con `-d`):

```console
$ unzip proyecto.zip
$ unzip proyecto.zip -d /tmp/salida/
```

---

## 5. Resumen para el examen

- `tar -c` crea, `-t` lista, `-x` extrae; `-f` indica el archivo y va al final del grupo de opciones.
- `-z` = gzip (`.tar.gz`/`.tgz`), `-j` = bzip2 (`.tar.bz2`), `-J` = xz (`.tar.xz`).
- `gzip`, `bzip2` y `xz` comprimen **un archivo por vez** y eliminan el original salvo que se use `-k`.
- Descompresores: `gunzip`, `bunzip2`, `unxz` (o la opción `-d` de cada uno).
- Ratio de compresión: `xz` > `bzip2` > `gzip`; velocidad: `gzip` > `bzip2` > `xz`.
- `zip -r` para archivar directorios; `unzip -l` lista, `unzip -d` extrae a otro directorio.
- `tar` preserva permisos y estructura; es el formato estándar para backups en Linux.

---

## Referencias

- LPI Learning Materials — Tema 3.1, Archiving Files on the Command Line: https://learning.lpi.org/en/learning-materials/010-160/3/3.1/
- Objetivos del examen Linux Essentials 010-160: https://www.lpi.org/our-certifications/exam-010-objectives/
- Manual de GNU tar: https://www.gnu.org/software/tar/manual/
- Página oficial de gzip (GNU): https://www.gnu.org/software/gzip/manual/
- Proyecto XZ Utils: https://tukaani.org/xz/
- Info-ZIP (zip/unzip): http://infozip.sourceforge.net/