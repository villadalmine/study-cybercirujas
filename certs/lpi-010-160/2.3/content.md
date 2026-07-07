# Tema 2.3: Using Directories and Listing Files

**Certificación:** LPI Linux Essentials (010-160, versión 1.6) — Peso: 2

---

## 1. Introducción

En Linux, todo se organiza dentro de una única estructura jerárquica de directorios que comienza en la raíz, representada por `/` (*root directory*). No existen "unidades" como `C:` o `D:`: todos los discos, particiones y dispositivos se montan en algún punto de ese árbol único. Para trabajar con eficacia en la línea de comandos necesitás dominar tres cosas: saber dónde estás (`pwd`), moverte (`cd`) y ver qué hay en cada lugar (`ls`).

---

## 2. Archivos y directorios

Un **archivo** (*file*) es una colección de datos con un nombre. Un **directorio** (*directory*) es un tipo especial de archivo que contiene referencias a otros archivos y directorios, formando el árbol jerárquico.

Puntos clave sobre los nombres en Linux:

- Son **case-sensitive**: `Informe.txt`, `informe.txt` e `INFORME.TXT` son tres archivos distintos.
- Las extensiones (`.txt`, `.jpg`) son una convención útil para humanos, pero el sistema no las necesita para saber el tipo de archivo.
- Conviene evitar espacios y caracteres especiales. Si un nombre tiene espacios, hay que citarlo o escaparlo:

```bash
$ cd "Mis Documentos"
$ cd Mis\ Documentos
```

---

## 3. Rutas absolutas y relativas

Una **ruta** (*path*) describe la ubicación de un archivo o directorio en el árbol.

### Ruta absoluta (*absolute path*)

Comienza siempre desde la raíz `/` y es válida sin importar dónde estés parado:

```bash
$ cd /home/carla/Documentos
```

### Ruta relativa (*relative path*)

Se interpreta a partir del **directorio de trabajo actual** (*current working directory*). No empieza con `/`:

```bash
$ cd Documentos/proyectos
```

Regla mnemotécnica: si empieza con `/`, es absoluta; si no, es relativa.

### Los directorios especiales `.` y `..`

Todo directorio contiene dos entradas especiales:

| Entrada | Significado |
|---------|-------------|
| `.` | El directorio actual |
| `..` | El directorio padre (*parent directory*) |

Ejemplos:

```bash
$ cd ..            # subir un nivel
$ cd ../..         # subir dos niveles
$ cd ../fotos      # subir un nivel y entrar en "fotos"
$ ./mi_script.sh   # ejecutar un archivo del directorio actual
```

---

## 4. Saber dónde estoy: `pwd`

El comando `pwd` (*print working directory*) muestra la ruta absoluta del directorio actual:

```bash
$ pwd
/home/carla/Documentos
```

---

## 5. Moverse entre directorios: `cd`

El comando `cd` (*change directory*) cambia el directorio de trabajo:

```bash
$ cd /var/log      # ir a una ruta absoluta
$ cd proyectos     # ir a un subdirectorio (ruta relativa)
$ cd ..            # subir al directorio padre
$ cd -             # volver al directorio anterior
$ cd               # ir al directorio home del usuario
```

El atajo `cd -` es muy práctico: alterna entre los dos últimos directorios visitados y muestra a cuál te movió:

```bash
$ cd -
/home/carla/Documentos
```

### El directorio home y la tilde `~`

Cada usuario tiene un **home directory**, normalmente `/home/usuario` (el de `root` es `/root`). El shell ofrece la tilde `~` como abreviatura:

```bash
$ cd ~             # ir a mi home (equivale a "cd" solo)
$ cd ~/Descargas   # ir a /home/carla/Descargas
$ echo ~
/home/carla
```

También se puede referenciar el home de otro usuario con `~nombre`, por ejemplo `~juan` equivale a `/home/juan`.

---

## 6. Listar archivos: `ls`

`ls` (*list*) muestra el contenido de un directorio. Sin argumentos, lista el directorio actual:

```bash
$ ls
Documentos  Descargas  Imágenes  informe.txt
```

Se le puede pasar una ruta:

```bash
$ ls /var/log
```

### Opción `-l`: formato largo (*long listing*)

```bash
$ ls -l
total 12
drwxr-xr-x 2 carla carla 4096 jun 15 10:30 Documentos
drwxr-xr-x 3 carla carla 4096 jun 20 09:12 Descargas
-rw-r--r-- 1 carla carla  532 jul  1 14:05 informe.txt
```

Lectura de cada columna, de izquierda a derecha:

1. **Tipo y permisos**: el primer carácter indica el tipo (`d` = directorio, `-` = archivo regular, `l` = enlace simbólico); los nueve siguientes son los permisos.
2. **Número de enlaces** (*link count*).
3. **Usuario propietario** (*owner*).
4. **Grupo propietario** (*group*).
5. **Tamaño** en bytes.
6. **Fecha y hora** de última modificación.
7. **Nombre** del archivo o directorio.

### Opción `-a`: archivos ocultos (*hidden files*)

En Linux, todo archivo cuyo nombre empieza con un punto (`.`) está **oculto**: `ls` no lo muestra por defecto. Se usan típicamente para archivos de configuración en el home del usuario (por eso se los llama *dotfiles*), como `.bashrc` o `.profile`.

```bash
$ ls -a
.  ..  .bashrc  .profile  Documentos  Descargas  informe.txt
```

Notá que también aparecen `.` y `..`. La variante `-A` (*almost all*) muestra los ocultos pero omite esas dos entradas.

### Opción `-h`: tamaños legibles (*human-readable*)

Combinada con `-l`, muestra los tamaños en unidades cómodas (K, M, G):

```bash
$ ls -lh
-rw-r--r-- 1 carla carla 1,5M jul  1 14:05 video_corto.mp4
-rw-r--r-- 1 carla carla  532 jul  1 14:05 informe.txt
```

### Opción `-R`: listado recursivo (*recursive*)

Lista el directorio indicado y todos sus subdirectorios:

```bash
$ ls -R proyectos
proyectos:
web  scripts

proyectos/web:
index.html  estilos.css

proyectos/scripts:
backup.sh
```

### Otras opciones útiles

| Opción | Efecto |
|--------|--------|
| `-t` | Ordena por fecha de modificación (más reciente primero) |
| `-r` | Invierte el orden del listado (*reverse*) |
| `-S` | Ordena por tamaño (más grande primero) |
| `-d` | Muestra el directorio en sí, no su contenido (ej.: `ls -ld /etc`) |

Las opciones se combinan libremente: `ls -lath` lista todo (incluidos ocultos), en formato largo, ordenado por fecha y con tamaños legibles.

---

## 7. Globbing: comodines en los nombres

El shell expande ciertos caracteres comodín (*wildcards*) antes de ejecutar el comando, lo que permite trabajar con grupos de archivos:

| Comodín | Significado | Ejemplo |
|---------|-------------|---------|
| `*` | Cualquier cadena, incluso vacía | `ls *.txt` |
| `?` | Exactamente un carácter | `ls foto?.jpg` |
| `[...]` | Un carácter del conjunto | `ls informe[123].txt` |

```bash
$ ls *.txt
informe.txt  notas.txt

$ ls foto?.jpg
foto1.jpg  foto2.jpg
```

---

## 8. Resumen de comandos del tema

| Comando | Función |
|---------|---------|
| `pwd` | Mostrar el directorio de trabajo actual |
| `cd ruta` | Cambiar de directorio |
| `cd ..` / `cd -` / `cd ~` | Padre / anterior / home |
| `ls` | Listar contenido |
| `ls -l` | Formato largo |
| `ls -a` | Incluir archivos ocultos |
| `ls -lh` | Tamaños legibles |
| `ls -R` | Listado recursivo |

---

## 9. Ejercicio de autoevaluación

1. ¿Cuál es la diferencia entre `cd /tmp` y `cd tmp`?
2. ¿Qué comando muestra todos los archivos del home, incluidos los ocultos, con sus tamaños en formato legible?
3. Estando en `/home/carla/Documentos/proyectos`, ¿qué ruta relativa te lleva a `/home/carla/Descargas`?

<details>
<summary>Respuestas</summary>

1. `cd /tmp` usa una ruta absoluta (siempre va a `/tmp`); `cd tmp` usa una ruta relativa (va a un subdirectorio `tmp` dentro del directorio actual, si existe).
2. `ls -lah ~`
3. `cd ../../Descargas`

</details>

---

## Referencias

- LPI Learning Materials — Topic 2.3: Using Directories and Listing Files: https://learning.lpi.org/en/learning-materials/010-160/2/2.3/
- GNU Coreutils Manual — `ls`: https://www.gnu.org/software/coreutils/manual/html_node/ls-invocation.html
- GNU Coreutils Manual — `pwd`: https://www.gnu.org/software/coreutils/manual/html_node/pwd-invocation.html
- GNU Bash Manual — Builtin `cd` y expansión de tilde: https://www.gnu.org/software/bash/manual/bash.html
- Objetivos oficiales del examen 010-160: https://www.lpi.org/our-certifications/exam-010-objectives/