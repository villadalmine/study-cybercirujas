# 2.4 Creating, Moving and Deleting Files

**Peso en el examen: 2** — Objetivo: crear, mover y eliminar archivos y directorios desde la línea de comandos, incluyendo el uso de *globbing* (comodines) y el manejo de nombres con espacios o caracteres especiales.

---

## Conceptos previos

### Nombres de archivo en Linux

- Linux es **case-sensitive**: `Informe.txt`, `informe.txt` e `INFORME.TXT` son tres archivos distintos.
- Los archivos cuyo nombre comienza con un punto (`.bashrc`, `.config`) son **archivos ocultos**: no aparecen con `ls` a menos que se use `ls -a`.
- Un nombre puede contener espacios y caracteres especiales, pero hay que protegerlos con comillas o con la barra invertida (*escape*):

```bash
$ touch "mis notas.txt"
$ touch mis\ notas\ 2.txt
$ rm 'mis notas.txt'
```

Sin las comillas, el shell interpretaría `mis` y `notas.txt` como dos argumentos separados.

---

## Crear archivos y directorios

### `touch` — crear archivos vacíos

`touch` crea un archivo vacío si no existe; si ya existe, actualiza su fecha de modificación (*timestamp*).

```bash
$ touch informe.txt
$ ls -l informe.txt
-rw-r--r-- 1 carol carol 0 jul  7 10:15 informe.txt
```

El tamaño `0` confirma que el archivo está vacío. Se pueden crear varios a la vez:

```bash
$ touch nota1.txt nota2.txt nota3.txt
```

### `mkdir` — crear directorios

```bash
$ mkdir proyectos
$ mkdir -p proyectos/2026/julio
```

La opción `-p` (*parents*) crea toda la ruta intermedia si no existe, y no da error si el directorio ya existe. Sin `-p`, intentar crear `proyectos/2026/julio` fallaría si `proyectos/2026` no existiera:

```bash
$ mkdir informes/2026
mkdir: cannot create directory 'informes/2026': No such file or directory
```

---

## Copiar: `cp`

Sintaxis general: `cp origen destino`.

```bash
$ cp informe.txt copia.txt          # copia con otro nombre
$ cp informe.txt proyectos/         # copia dentro de un directorio
$ cp nota1.txt nota2.txt proyectos/ # varios archivos → el destino debe ser un directorio
```

Para copiar directorios completos se necesita `-r` (*recursive*):

```bash
$ cp proyectos respaldo
cp: -r not specified; omitting directory 'proyectos'
$ cp -r proyectos respaldo
```

Opciones útiles:

| Opción | Efecto |
|---|---|
| `-r` / `-R` | Copia recursiva (directorios y su contenido) |
| `-i` | Pregunta antes de sobrescribir (*interactive*) |
| `-v` | Muestra cada archivo copiado (*verbose*) |

**Cuidado:** por defecto `cp` sobrescribe el destino sin avisar. Con `-i`:

```bash
$ cp -i informe.txt copia.txt
cp: overwrite 'copia.txt'? y
```

---

## Mover y renombrar: `mv`

`mv` cumple dos funciones: **mover** archivos/directorios a otra ubicación y **renombrarlos** (en Linux renombrar es un caso particular de mover).

```bash
$ mv informe.txt informe_final.txt   # renombrar
$ mv informe_final.txt proyectos/    # mover
$ mv proyectos trabajos              # renombrar un directorio (no necesita -r)
```

A diferencia de `cp`, `mv` mueve directorios sin ninguna opción adicional. También acepta `-i` (preguntar antes de sobrescribir) y `-v` (mostrar lo que hace):

```bash
$ mv -v nota1.txt trabajos/
renamed 'nota1.txt' -> 'trabajos/nota1.txt'
```

---

## Eliminar: `rm` y `rmdir`

### `rm` — eliminar archivos

```bash
$ rm copia.txt
$ rm -i nota2.txt
rm: remove regular file 'nota2.txt'? y
```

Para eliminar directorios con todo su contenido, `-r`:

```bash
$ rm respaldo
rm: cannot remove 'respaldo': Is a directory
$ rm -r respaldo
```

**Advertencia importante:** en la línea de comandos **no hay papelera**. Lo que se borra con `rm` no se recupera. Combinaciones como `rm -rf` (forzar y recursivo) son especialmente peligrosas — verificá siempre la ruta antes de ejecutar.

### `rmdir` — eliminar directorios vacíos

`rmdir` solo funciona si el directorio está **vacío**, lo que lo hace más seguro que `rm -r`:

```bash
$ rmdir trabajos
rmdir: failed to remove 'trabajos': Directory not empty
$ rmdir directorio_vacio
```

También acepta `-p` para eliminar una cadena de directorios vacíos:

```bash
$ rmdir -p proyectos/2026/julio
```

---

## Globbing: comodines del shell

El *globbing* permite referirse a varios archivos con un patrón. El shell expande el patrón **antes** de ejecutar el comando.

| Comodín | Significado | Ejemplo |
|---|---|---|
| `*` | Cero o más caracteres cualesquiera | `*.txt` → todos los `.txt` |
| `?` | Exactamente un carácter | `nota?.txt` → `nota1.txt`, `notaB.txt` |
| `[abc]` | Un carácter del conjunto | `nota[12].txt` → `nota1.txt`, `nota2.txt` |
| `[a-z]` | Un carácter del rango | `[a-c]*` → archivos que empiezan con a, b o c |
| `[!abc]` | Un carácter que **no** esté en el conjunto | `nota[!1].txt` → `nota2.txt` pero no `nota1.txt` |

Ejemplos en acción:

```bash
$ ls
informe1.txt  informe2.txt  informe10.txt  resumen.pdf

$ ls informe?.txt
informe1.txt  informe2.txt

$ ls informe*.txt
informe1.txt  informe2.txt  informe10.txt

$ cp *.txt respaldo/       # copia todos los .txt
$ rm informe[12].txt       # borra informe1.txt e informe2.txt
```

Notá la diferencia entre `?` (un solo carácter, no coincide con `informe10.txt`) y `*` (cualquier cantidad).

**Precaución:** un patrón mal escrito con `rm` puede borrar más de lo esperado. Un buen hábito es probar primero el patrón con `ls` y recién después usarlo con `rm`.

---

## Resumen de comandos

| Comando | Función | Opción clave |
|---|---|---|
| `touch` | Crear archivo vacío / actualizar timestamp | — |
| `mkdir` | Crear directorio | `-p` (crea rutas intermedias) |
| `cp` | Copiar | `-r` (directorios), `-i`, `-v` |
| `mv` | Mover / renombrar | `-i`, `-v` |
| `rm` | Eliminar archivos | `-r` (directorios), `-i`, `-f` |
| `rmdir` | Eliminar directorios **vacíos** | `-p` |

---

## Referencias

- LPI Learning Materials — Tema 2.4, Creating, Moving and Deleting Files: https://learning.lpi.org/en/learning-materials/010-160/2/2.4/
- Objetivos del examen Linux Essentials 010-160 (v1.6): https://wiki.lpi.org/wiki/LinuxEssentials_Objectives_V1.6
- GNU Coreutils Manual (`cp`, `mv`, `rm`, `mkdir`, `rmdir`, `touch`): https://www.gnu.org/software/coreutils/manual/coreutils.html
- Bash Reference Manual — Filename Expansion (globbing): https://www.gnu.org/software/bash/manual/html_node/Filename-Expansion.html