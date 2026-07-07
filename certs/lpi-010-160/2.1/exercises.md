# Ejercicios guiados — Tema 2.1: Command Line Basics
**Certificación:** LPI Linux Essentials (010-160, versión 1.6) · **Peso:** 3

> Material de práctica original. Referencia consultada: [LPI Learning Materials — Lesson 2.1](https://learning.lpi.org/en/learning-materials/010-160/2/2.1/)

Para estos ejercicios necesitás una terminal con **Bash**. Todos los comandos son seguros: no modifican archivos del sistema.

---

## Ejercicio 1 — Anatomía de un comando

La línea de comandos sigue una estructura general: `comando [opciones] [argumentos]`.

1. Abrí una terminal y ejecutá el comando sin nada más:
   ```bash
   ls
   ```
2. Ahora agregale una opción corta:
   ```bash
   ls -l
   ```
3. Agregá una opción larga:
   ```bash
   ls --all
   ```
4. Combiná opciones cortas en un solo bloque:
   ```bash
   ls -la
   ```
5. Sumá un argumento (el directorio sobre el que actúa el comando):
   ```bash
   ls -l /etc
   ```

**Preguntas:**

- **1.a)** En el comando `ls -l /etc`, identificá cuál parte es el *command*, cuál la *option* y cuál el *argument*.
- **1.b)** ¿Qué diferencia de sintaxis hay entre una *short option* y una *long option*?
- **1.c)** ¿`ls -la` y `ls -l -a` producen el mismo resultado? ¿Por qué?

---

## Ejercicio 2 — ¿Qué tipo de comando es? (`type` y `which`)

No todos los comandos son iguales: algunos son programas externos (archivos en disco), otros son *shell builtins* y otros pueden ser *aliases*.

1. Averiguá qué es `echo`:
   ```bash
   type echo
   ```
2. Ahora averiguá qué es `ls`:
   ```bash
   type ls
   ```
3. Localizá el archivo ejecutable de un comando externo:
   ```bash
   which cp
   ```
4. Probá con `cd`:
   ```bash
   type cd
   which cd
   ```

**Preguntas:**

- **2.a)** ¿Qué es un *shell builtin* y en qué se diferencia de un comando externo?
- **2.b)** ¿Por qué `which cd` probablemente no devolvió una ruta (o devolvió un resultado distinto a `which cp`)?
- **2.c)** En muchas distribuciones, `type ls` muestra que es un *alias* (por ejemplo, de `ls --color=auto`). ¿Qué es un *alias*?

---

## Ejercicio 3 — Variables de shell y de entorno

1. Creá una variable local de shell:
   ```bash
   saludo="hola mundo"
   ```
   > Ojo: sin espacios alrededor del `=`.
2. Mostrá su valor con `echo` y el signo `$`:
   ```bash
   echo $saludo
   ```
3. Verificá que una variable local **no** se hereda: abrí una subshell y consultala:
   ```bash
   bash
   echo $saludo
   exit
   ```
4. Ahora exportala para convertirla en *environment variable* y repetí la prueba:
   ```bash
   export saludo
   bash
   echo $saludo
   exit
   ```
5. Inspeccioná algunas variables de entorno estándar:
   ```bash
   echo $USER
   echo $HOME
   echo $PWD
   ```
6. Listá todas las variables de entorno de tu sesión:
   ```bash
   env
   ```

**Preguntas:**

- **3.a)** ¿Qué hace exactamente el comando `export`?
- **3.b)** ¿Por qué en el paso 3 la subshell no mostró el valor de `saludo`, pero en el paso 4 sí?
- **3.c)** ¿Qué error da Bash si escribís `saludo = "hola"` (con espacios)? ¿Por qué?
- **3.d)** ¿Con qué comando podés eliminar una variable que ya no necesitás?

---

## Ejercicio 4 — La variable `PATH`

Cuando escribís un comando, el shell busca el ejecutable en los directorios listados en la variable `PATH`, en orden.

1. Mostrá el contenido de tu `PATH`:
   ```bash
   echo $PATH
   ```
2. Comprobá dónde encuentra el shell al comando `date`:
   ```bash
   which date
   ```
3. Intentá ejecutar un programa que **no** está en el `PATH`, escribiendo solo su nombre. Primero creá uno:
   ```bash
   cd ~
   echo 'echo "funciono"' > miscript.sh
   chmod +x miscript.sh
   miscript.sh
   ```
4. Ahora ejecutalo indicando la ruta explícita:
   ```bash
   ./miscript.sh
   ```
5. Agregá temporalmente tu directorio *home* al `PATH` y probá de nuevo:
   ```bash
   PATH="$PATH:$HOME"
   miscript.sh
   ```

**Preguntas:**

- **4.a)** ¿Qué separa las entradas dentro de la variable `PATH`?
- **4.b)** ¿Por qué en el paso 3 el shell respondió `command not found` aunque el archivo existe y es ejecutable?
- **4.c)** ¿Qué significa el prefijo `./` en `./miscript.sh`?
- **4.d)** El cambio del paso 5, ¿sobrevive si cerrás la terminal y abrís una nueva? ¿Por qué?

---

## Ejercicio 5 — Quoting: comillas dobles, simples y backslash

El *quoting* controla cómo el shell interpreta los caracteres especiales (`$`, `*`, espacios, etc.).

1. Definí una variable para las pruebas:
   ```bash
   fruta=manzana
   ```
2. Probá con *double quotes*:
   ```bash
   echo "Tengo una $fruta"
   ```
3. Probá con *single quotes*:
   ```bash
   echo 'Tengo una $fruta'
   ```
4. Probá el *escape character* (backslash):
   ```bash
   echo "El precio es \$100"
   ```
5. Observá qué pasa con los espacios sin comillas y con comillas:
   ```bash
   echo Hola      mundo
   echo "Hola      mundo"
   ```
6. Intentá crear una variable con espacios, primero mal y después bien:
   ```bash
   frase=hola mundo
   frase="hola mundo"
   echo $frase
   ```

**Preguntas:**

- **5.a)** ¿Cuál es la diferencia clave entre *double quotes* (`"`) y *single quotes* (`'`)?
- **5.b)** En el paso 4, ¿qué habría impreso el comando sin el backslash?
- **5.c)** En el paso 5, ¿por qué el primer `echo` muestra un solo espacio entre las palabras?
- **5.d)** ¿Qué error produce la primera línea del paso 6 y por qué?

---

## Ejercicio 6 — Globbing (comodines)

Antes de ejecutar un comando, el shell expande los *wildcards* a los nombres de archivo que coinciden.

1. Creá un directorio de prueba con varios archivos:
   ```bash
   mkdir ~/practica-glob
   cd ~/practica-glob
   touch nota1.txt nota2.txt nota10.txt informe.pdf datos.csv
   ```
2. Listá solo los archivos `.txt`:
   ```bash
   ls *.txt
   ```
3. Usá `?` para coincidir con exactamente un carácter:
   ```bash
   ls nota?.txt
   ```
4. Usá corchetes para un conjunto de caracteres:
   ```bash
   ls nota[12].txt
   ```
5. Comprobá que es el **shell** quien expande, no el comando:
   ```bash
   echo *.txt
   echo "*.txt"
   ```
6. Limpiá el directorio de práctica:
   ```bash
   cd ~
   rm -r ~/practica-glob
   ```

**Preguntas:**

- **6.a)** ¿Qué diferencia hay entre `*` y `?`?
- **6.b)** En el paso 3, ¿por qué `nota10.txt` no apareció en el resultado?
- **6.c)** En el paso 5, ¿por qué la segunda línea imprime literalmente `*.txt`?
- **6.d)** ¿Quién realiza la expansión de los comodines: el comando (`ls`, `echo`) o el shell? ¿Qué implica eso?

---

## Ejercicio 7 — Historial y trucos de productividad

1. Mostrá los últimos comandos que ejecutaste:
   ```bash
   history
   ```
2. Repetí el último comando:
   ```bash
   !!
   ```
3. Repetí un comando específico por su número (reemplazá `N` por un número que veas en tu `history`):
   ```bash
   !N
   ```
4. Presioná la **flecha arriba** varias veces para navegar el historial, y **Ctrl+R** para buscar interactivamente un comando anterior (escribí, por ejemplo, `echo` y mirá qué aparece).
5. Escribí `ec` y presioná **Tab** dos veces para ver el *tab completion* en acción.
6. Averiguá en qué archivo se guarda el historial:
   ```bash
   echo $HISTFILE
   ```

**Preguntas:**

- **7.a)** ¿Qué hace `!!` y en qué situación típica resulta útil combinado con `sudo`?
- **7.b)** ¿En qué archivo se guarda habitualmente el historial de Bash y en qué momento se escribe?
- **7.c)** ¿Para qué sirve el *tab completion* además de escribir menos?

---

## Ejercicio 8 — Varios comandos en una línea

1. Ejecutá dos comandos en secuencia, separados por `;`:
   ```bash
   cd /tmp; ls
   ```
2. Ejecutá un comando que falla seguido de otro, con `;`:
   ```bash
   ls /noexiste; echo "esto se imprime igual"
   ```
3. Repetí la prueba con `&&`:
   ```bash
   ls /noexiste && echo "esto NO se imprime"
   ```
4. Volvé a tu directorio home:
   ```bash
   cd
   ```

**Preguntas:**

- **8.a)** ¿Qué diferencia de comportamiento hay entre `;` y `&&` como separadores de comandos?
- **8.b)** En el paso 3, ¿por qué el `echo` no se ejecutó?

---

<details>
<summary><strong>✅ Respuestas</strong></summary>

### Ejercicio 1
- **1.a)** *Command*: `ls` — el programa que se ejecuta. *Option*: `-l` — modifica el comportamiento (listado largo). *Argument*: `/etc` — el objeto sobre el que actúa el comando.
- **1.b)** Las *short options* usan un solo guion y una sola letra (`-l`, `-a`); las *long options* usan doble guion y una palabra (`--all`). Las largas son más legibles; las cortas, más rápidas de escribir.
- **1.c)** Sí, producen el mismo resultado. Las opciones cortas pueden agruparse detrás de un solo guion: `-la` equivale a `-l -a`.

### Ejercicio 2
- **2.a)** Un *builtin* es una funcionalidad incorporada dentro del propio shell (no existe como archivo ejecutable separado). Un comando externo es un programa en disco (por ejemplo, en `/usr/bin`) que el shell debe localizar y ejecutar.
- **2.b)** Porque `cd` es un *builtin* de Bash: no hay un ejecutable `cd` en el `PATH` (y no podría haberlo, porque cambiar de directorio debe ocurrir dentro del propio proceso del shell). `which` solo busca archivos ejecutables en el `PATH`.
- **2.c)** Un *alias* es un atajo definido en el shell que sustituye un nombre por otro comando (con o sin opciones). Por ejemplo, `alias ls='ls --color=auto'` hace que cada `ls` incluya color automáticamente.

### Ejercicio 3
- **3.a)** `export` marca una variable para que se copie al *environment* de los procesos hijos: la convierte de variable local de shell en *environment variable*.
- **3.b)** Las variables locales existen solo en el shell donde se definieron. Al ejecutar `bash` se crea un proceso hijo que no las hereda. Tras `export`, la variable pasa al entorno y sí se copia a los hijos.
- **3.c)** Da algo como `saludo: command not found`. Con espacios, Bash interpreta `saludo` como un comando a ejecutar, con `=` y `"hola"` como argumentos, en lugar de una asignación.
- **3.d)** Con `unset`, por ejemplo: `unset saludo`.

### Ejercicio 4
- **4.a)** Los dos puntos (`:`), por ejemplo: `/usr/local/bin:/usr/bin:/bin`.
- **4.b)** Porque el shell solo busca comandos en los directorios del `PATH`. El *home* del usuario normalmente no está incluido, así que el shell nunca mira ahí, aunque el archivo tenga permiso de ejecución.
- **4.c)** `./` indica una ruta explícita: "el archivo `miscript.sh` en el directorio actual (`.`)". Al dar una ruta, el shell no consulta el `PATH`.
- **4.d)** No sobrevive. La asignación solo afecta a la sesión actual. Para hacerla permanente habría que agregarla a un archivo de inicialización del shell, como `~/.bashrc` o `~/.bash_profile`.

### Ejercicio 5
- **5.a)** Las *double quotes* suprimen la mayoría de los caracteres especiales pero **permiten** la expansión de variables (`$var`) y la sustitución de comandos. Las *single quotes* suprimen **todo**: el contenido se toma literalmente. Por eso el paso 2 imprime `Tengo una manzana` y el paso 3 imprime `Tengo una $fruta`.
- **5.b)** Sin el backslash, `$100` se interpretaría como la variable `$1` (probablemente vacía) seguida de `00`, imprimiendo `El precio es 00`. El `\` anula el significado especial del `$`.
- **5.c)** Sin comillas, el shell divide la línea en palabras usando los espacios como separadores y le pasa a `echo` dos argumentos (`Hola` y `mundo`); `echo` los imprime separados por un único espacio. Con comillas, los espacios se preservan porque todo es un solo argumento.
- **5.d)** `mundo: command not found` (o similar). Sin comillas, Bash interpreta `frase=hola` como una asignación válida solo para el comando `mundo`, que intenta ejecutar y no existe. Las comillas hacen que `hola mundo` sea un único valor.

### Ejercicio 6
- **6.a)** `*` coincide con cero o más caracteres cualesquiera; `?` coincide con exactamente un carácter.
- **6.b)** Porque `?` representa un solo carácter: `nota?.txt` coincide con `nota1.txt` y `nota2.txt`, pero `nota10.txt` tiene dos caracteres entre `nota` y `.txt`.
- **6.c)** Porque las comillas (dobles o simples) impiden el *globbing*: el shell no expande `*.txt` y `echo` recibe la cadena literal.
- **6.d)** La expansión la hace el **shell**, antes de ejecutar el comando. El comando nunca ve el comodín (salvo que no haya coincidencias o esté entre comillas): recibe la lista de nombres ya expandida como argumentos. Por eso el quoting puede desactivar la expansión sin que el comando cambie.

### Ejercicio 7
- **7.a)** `!!` repite el último comando ejecutado. El caso típico: escribiste un comando que falló por falta de privilegios y lo repetís con `sudo !!`.
- **7.b)** En el archivo apuntado por `$HISTFILE`, habitualmente `~/.bash_history`. Se escribe al cerrar la sesión del shell (por eso los comandos de una sesión abierta pueden no verse todavía en el archivo).
- **7.c)** Además de ahorrar tecleo, evita errores de tipeo en nombres de comandos, archivos y rutas, y sirve para descubrir qué comandos o archivos existen (al presionar Tab dos veces se listan las coincidencias posibles).

### Ejercicio 8
- **8.a)** Con `;` los comandos se ejecutan en secuencia sin importar si el anterior falló. Con `&&` el segundo comando se ejecuta **solo si** el primero terminó con éxito (exit status 0).
- **8.b)** Porque `ls /noexiste` falla (devuelve un exit status distinto de 0) y `&&` corta la cadena: el segundo comando solo corre tras un éxito.

</details>