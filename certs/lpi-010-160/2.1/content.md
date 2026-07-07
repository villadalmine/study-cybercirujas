# 2.1 Command Line Basics

**Peso en el examen: 3** — Este tema cubre el uso básico del shell, la sintaxis de la línea de comandos, las variables de entorno y el quoting. Es uno de los temas fundamentales del examen 010-160: casi todo lo que sigue en la certificación se apoya en estos conceptos.

---

## 1. ¿Qué es el shell?

El *shell* es un programa que actúa como intermediario entre el usuario y el sistema operativo: lee los comandos que escribís, los interpreta y le pide al kernel que los ejecute. A este tipo de interfaz se la llama **CLI** (*Command Line Interface*), en contraste con la **GUI** (*Graphical User Interface*).

El shell más usado en Linux —y el que asume el examen— es **Bash** (*Bourne Again Shell*), una evolución del Bourne Shell (`sh`) original de Unix. Existen otros shells como `zsh`, `ksh`, `fish` o `dash`, pero Bash es el estándar de facto y el shell por defecto en la mayoría de las distribuciones.

Cuando abrís una terminal, el shell te muestra el **prompt**, que indica que está listo para recibir comandos. Un prompt típico se ve así:

```
usuario@equipo:~$
```

Sus partes son:

- `usuario` — el nombre del usuario con el que iniciaste sesión.
- `equipo` — el *hostname* de la máquina.
- `~` — el directorio actual (la virgulilla es una abreviatura del directorio *home* del usuario).
- `$` — indica que sos un usuario común. Si fueras `root` (el superusuario), verías `#` en su lugar.

Podés saber qué shell estás usando consultando la variable `SHELL`:

```
$ echo $SHELL
/bin/bash
```

## 2. Sintaxis de la línea de comandos

Una línea de comandos sigue una estructura general de tres partes:

```
comando [opciones] [argumentos]
```

- **Comando**: el programa o instrucción a ejecutar (por ejemplo, `ls`).
- **Opciones** (también llamadas *flags* o *switches*): modifican el comportamiento del comando. Suelen empezar con `-` (forma corta, una letra) o `--` (forma larga, una palabra).
- **Argumentos**: los objetos sobre los que actúa el comando, típicamente archivos o directorios.

Ejemplo con el comando `ls` (listar contenido de un directorio):

```
$ ls
documentos  descargas  musica

$ ls -l /tmp
total 4
drwx------ 2 juana juana 4096 jul  6 10:15 ssh-XXXXXX
-rw-r--r-- 1 juana juana   42 jul  6 09:30 notas.txt
```

En el segundo ejemplo, `-l` es una opción (formato largo, con detalles) y `/tmp` es un argumento (el directorio a listar).

Las opciones cortas pueden combinarse: `ls -a -l` es equivalente a `ls -la`. Muchas opciones tienen ambas formas, corta y larga: `ls -a` y `ls --all` hacen lo mismo.

### 2.1 Comandos internos y externos

El shell distingue dos tipos de comandos:

- **Internos** (*builtins*): forman parte del propio shell. Ejemplos: `cd`, `echo`, `export`, `pwd`.
- **Externos**: son programas independientes almacenados en el sistema de archivos (por ejemplo, en `/usr/bin`). Ejemplos: `ls`, `cat`, `man`.

El comando `type` indica de qué tipo es un comando:

```
$ type echo
echo is a shell builtin

$ type ls
ls is aliased to `ls --color=auto`

$ type cat
cat is /usr/bin/cat
```

Notá el caso de `ls`: es un **alias**, un "apodo" que el shell expande antes de ejecutar. Podés crear los tuyos:

```
$ alias verlargo='ls -lh'
$ verlargo
total 8,0K
-rw-r--r-- 1 juana juana 1,2K jul  6 09:30 notas.txt
```

### 2.2 Continuación de línea y varios comandos por línea

Para escribir un comando largo en varias líneas, se termina cada línea con una barra invertida (`\`):

```
$ cp archivo_con_nombre_largo.txt \
> /home/juana/respaldo/
```

El `>` que aparece al inicio de la segunda línea es el *prompt secundario* (variable `PS1` para el principal, `PS2` para el secundario): indica que el shell espera que completes el comando.

Para ejecutar varios comandos en una sola línea, se separan con `;`:

```
$ cd /tmp ; ls ; cd -
```

## 3. Variables

Las variables son nombres que almacenan valores. En Bash hay dos categorías:

- **Variables de shell** (locales): existen solo en la sesión actual del shell.
- **Variables de entorno** (*environment variables*): se "exportan" y son heredadas por los programas y subshells que el shell lanza. Por convención se escriben en MAYÚSCULAS.

### 3.1 Crear y leer variables

Se asignan con `nombre=valor` — **sin espacios alrededor del `=`** — y se leen anteponiendo `$`:

```
$ saludo=hola
$ echo $saludo
hola
```

Un error clásico del examen: `saludo = hola` (con espacios) falla, porque el shell interpreta `saludo` como un comando.

### 3.2 export: convertir una variable en variable de entorno

Una variable local no es visible para los procesos hijos. Para que lo sea, se usa `export`:

```
$ nombre=Juana
$ bash               # abrimos un subshell
$ echo $nombre
                     # (vacío: la variable no se heredó)
$ exit

$ export nombre=Juana
$ bash
$ echo $nombre
Juana
```

Para ver las variables de entorno definidas se usa `env` o `printenv`; para ver todas las variables (incluidas las locales), `set`. Para eliminar una variable, `unset nombre`.

### 3.3 La variable PATH

`PATH` es la variable de entorno más importante para el examen. Contiene una lista de directorios, separados por `:`, donde el shell busca los comandos externos que escribís:

```
$ echo $PATH
/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin
```

Cuando ejecutás `ls`, el shell recorre esos directorios en orden hasta encontrar un ejecutable llamado `ls`. Si un programa no está en ningún directorio del `PATH`, obtenés `command not found`, aunque el archivo exista. Por eso, para ejecutar un script en el directorio actual hay que indicar la ruta explícitamente:

```
$ ./mi_script.sh
```

Para agregar un directorio al `PATH` sin perder el valor actual:

```
$ export PATH=$PATH:/home/juana/scripts
```

El comando `which` muestra qué ejecutable se usaría según el `PATH`:

```
$ which ls
/usr/bin/ls
```

### 3.4 Variables especiales: el código de salida ($?)

Todo comando devuelve al terminar un **exit code** (código de salida): `0` significa éxito y cualquier valor distinto de cero indica error. Se consulta con la variable especial `$?`:

```
$ ls /tmp
notas.txt
$ echo $?
0

$ ls /noexiste
ls: cannot access '/noexiste': No such file or directory
$ echo $?
2
```

## 4. Quoting (uso de comillas)

El shell trata ciertos caracteres de forma especial: `$` (expansión de variables), `*` y `?` (comodines), espacio (separador de argumentos), entre otros. El **quoting** controla cuáles de esas interpretaciones se aplican. Hay tres mecanismos:

### 4.1 Comillas dobles (`"`)

Suprimen la mayoría de los caracteres especiales, **pero permiten la expansión de variables** (`$`) y la sustitución de comandos:

```
$ usuario=Juana
$ echo "Hola, $usuario. Hoy hay 3 * 2 archivos"
Hola, Juana. Hoy hay 3 * 2 archivos
```

El `*` no se expandió como comodín, pero `$usuario` sí se reemplazó por su valor.

### 4.2 Comillas simples (`'`)

Suprimen **toda** interpretación especial; el texto se toma literalmente:

```
$ echo 'Hola, $usuario'
Hola, $usuario
```

### 4.3 Caracter de escape (`\`)

La barra invertida quita el significado especial únicamente al caracter que le sigue:

```
$ echo "El precio es \$100"
El precio es $100
```

### 4.4 ¿Por qué importa? Espacios en nombres de archivo

Sin quoting, el shell interpreta cada espacio como separador de argumentos:

```
$ touch mis notas.txt      # ¡crea DOS archivos: "mis" y "notas.txt"!
$ touch "mis notas.txt"    # crea UN archivo llamado "mis notas.txt"
```

Comparación resumida:

| Mecanismo | Expande `$variable` | Expande comodines (`*`) | Ejemplo | Salida |
|---|---|---|---|---|
| Sin comillas | Sí | Sí | `echo $HOME` | `/home/juana` |
| Comillas dobles `"` | Sí | No | `echo "$HOME *"` | `/home/juana *` |
| Comillas simples `'` | No | No | `echo '$HOME *'` | `$HOME *` |

## 5. Comandos esenciales del tema

### 5.1 echo

Imprime texto en la salida estándar. Es la herramienta habitual para inspeccionar variables:

```
$ echo Hola mundo
Hola mundo

$ echo $USER
juana

$ echo -e "línea 1\nlínea 2"    # -e interpreta secuencias de escape como \n
línea 1
línea 2
```

### 5.2 history

Bash guarda los comandos que ejecutás. `history` los lista numerados:

```
$ history
  501  cd /tmp
  502  ls -l
  503  echo $PATH
```

Formas de reutilizar el historial:

- **Flechas ↑ / ↓**: navegar por los comandos anteriores.
- `!!` — repite el último comando.
- `!503` — ejecuta el comando número 503 del historial.
- `!echo` — ejecuta el comando más reciente que empezaba con `echo`.
- **Ctrl+R** — búsqueda interactiva hacia atrás en el historial.

El historial se guarda en el archivo indicado por la variable `HISTFILE` (por defecto `~/.bash_history`) cuando cerrás la sesión, y la cantidad de entradas se controla con `HISTSIZE`.

### 5.3 pwd y cd

Aunque se profundizan en el tema 2.3, conviene conocerlos ya:

```
$ pwd                # print working directory: muestra dónde estás
/home/juana
$ cd /tmp            # change directory
$ cd -               # volver al directorio anterior
$ cd                 # sin argumentos: ir al home
```

### 5.4 Sustitución de comandos

Permite usar la salida de un comando como parte de otro, con la sintaxis `$(comando)` (o la forma antigua con *backticks* `` `comando` ``):

```
$ echo "Hoy es $(date +%A)"
Hoy es domingo
```

## 6. Puntos clave para el examen

- El prompt `$` indica usuario común; `#` indica `root`.
- Estructura: `comando [opciones] [argumentos]`; opciones cortas con `-`, largas con `--`.
- Asignación de variables **sin espacios**: `VAR=valor`. Lectura con `$VAR`.
- `export` hace que una variable sea heredada por los procesos hijos.
- `PATH` define dónde busca el shell los ejecutables; sus directorios se separan con `:`.
- `$?` contiene el exit code del último comando: `0` = éxito.
- Comillas simples = literal total; comillas dobles = permiten `$`; `\` escapa un solo caracter.
- `type` distingue builtins, alias y comandos externos; `which` localiza ejecutables en el `PATH`.
- `history`, `!!`, `!n` y Ctrl+R para reutilizar comandos.

---

## Referencias

- LPI Learning Materials — Tema 2.1 Command Line Basics: https://learning.lpi.org/en/learning-materials/010-160/2/2.1/
- Objetivos oficiales del examen Linux Essentials (versión 1.6): https://www.lpi.org/our-certifications/exam-010-objectives/
- Manual de referencia de GNU Bash: https://www.gnu.org/software/bash/manual/bash.html
- Bash Reference Manual — Quoting: https://www.gnu.org/software/bash/manual/html_node/Quoting.html
- Bash Reference Manual — Shell Variables: https://www.gnu.org/software/bash/manual/html_node/Shell-Variables.html
- The Linux Documentation Project — Bash Guide for Beginners: https://tldp.org/LDP/Bash-Beginners-Guide/html/